"""One frame in, one whisper out: YOLO -> crop -> Jev -> Gemini -> comps -> decide, per object."""
from __future__ import annotations

import asyncio
from typing import Awaitable, Callable, List, Optional, Tuple, Union

from PIL import Image

from .comps import apply_comps, tag_for
from .config import Settings
from .crops import look, make_crop, rank_targets
from .decide import compose, decide, phrase
from .memory import Memory, normalize
from .models import Detection, ObjectResult, Quote

Detect = Callable[[Image.Image], List[Detection]]
Jev = Callable[[bytes], Awaitable[float]]
Gemini = Callable[[bytes], Awaitable[Quote]]


def _error(stage: str, exc: BaseException) -> str:
    return f"{stage} error: {type(exc).__name__}: {exc}"


class Pipeline:
    def __init__(self, detect: Detect, jev: Jev, gemini: Gemini, comps: dict, memory: Memory, settings: Settings):
        self.detect = detect
        self.jev = jev
        self.gemini = gemini
        self.comps = comps
        self.memory = memory
        self.settings = settings

    async def process_frame(
        self, img: Image.Image, dets: Optional[List[Detection]] = None
    ) -> Tuple[str, List[ObjectResult]]:
        """`dets` is the box the page already stabilized on; without it, YOLO runs and picks the best."""
        if dets is None:
            dets = rank_targets(self.detect(img))[: self.settings.max_boxes]
        if not dets:
            return "", []
        crops = [make_crop(img, d) for d in dets]
        looks = [look(img, d) for d in dets]

        scores = await asyncio.gather(*(self.jev(c) for c in crops), return_exceptions=True)
        quotes = await self._quotes(dets, crops, looks, scores)

        results: List[ObjectResult] = []
        winners: List[Tuple[float, Quote]] = []
        claimed = set()
        for det, score, quote in zip(dets, scores, quotes):
            if isinstance(score, BaseException):
                results.append(ObjectResult(det, None, None, None, "error", _error("jev", score), ""))
            elif score < self.settings.jev_threshold:
                results.append(ObjectResult(det, score, None, None, "quiet", "not resalable", ""))
            elif isinstance(quote, BaseException):
                results.append(ObjectResult(det, score, None, None, "error", _error("gemini", quote), ""))
            else:
                tag = tag_for(quote.name, self.comps, self.settings.default_tag)
                speak, reason = decide(tag, quote, self.settings.gemini_min_confidence)
                key = normalize(quote.name)
                if speak and self.memory.recently_spoken(key):
                    speak, reason = False, "spoken recently"
                elif speak and key in claimed:
                    speak, reason = False, "duplicate in frame"
                if speak:
                    claimed.add(key)
                    winners.append((tag, quote))
                line = phrase(quote) if speak else ""
                results.append(ObjectResult(det, score, quote, tag, "spoke" if speak else "quiet", reason, line))

        for _, quote in winners:
            self.memory.mark_spoken(quote.name)
        return compose(winners), results

    async def _quotes(
        self, dets: List[Detection], crops: List[bytes], looks: List[bytes], scores: list
    ) -> List[Optional[Union[Quote, BaseException]]]:
        """Cached quote by look when we have one; otherwise one Gemini call per passing crop."""
        quotes: List[Optional[Union[Quote, BaseException]]] = [None] * len(dets)
        pending = []
        for i, (det, score) in enumerate(zip(dets, scores)):
            if isinstance(score, BaseException) or score < self.settings.jev_threshold:
                continue
            name = self.memory.name_for_look(det.label, looks[i])
            cached = self.memory.get_quote(name) if name else None
            if cached is not None:
                quotes[i] = cached
            else:
                pending.append(i)

        fresh = await asyncio.gather(*(self.gemini(crops[i]) for i in pending), return_exceptions=True)
        for i, quote in zip(pending, fresh):
            if not isinstance(quote, BaseException):
                quote = apply_comps(quote, self.comps)
                self.memory.put_quote(quote.name, quote)
                self.memory.remember_look(dets[i].label, looks[i], quote.name)
            quotes[i] = quote
        return quotes
