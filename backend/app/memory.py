"""Per-item quote cache and the spoken cooldown, keyed by normalized item name.

The item name only arrives with Gemini's answer, so a "look" (crops.look thumbnail under its
YOLO label) maps back to a name we've already priced. That lets a repeat sighting skip Gemini.
"""
from __future__ import annotations

import time
from collections import defaultdict, deque
from typing import Callable, Deque, Dict, Optional, Tuple

from .models import Quote

LOOK_TOLERANCE = 12  # mean absolute difference per channel, 0-255
LOOKS_PER_LABEL = 50


def normalize(name: str) -> str:
    return " ".join(name.lower().split())


def _distance(a: bytes, b: bytes) -> float:
    if len(a) != len(b) or not a:
        return float("inf")
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a)


class Memory:
    def __init__(self, cooldown_s: float, clock: Callable[[], float] = time.monotonic):
        self.cooldown_s = cooldown_s
        self.clock = clock
        self._quotes: Dict[str, Quote] = {}
        self._spoken: Dict[str, float] = {}
        self._looks: Dict[str, Deque[Tuple[bytes, str]]] = defaultdict(lambda: deque(maxlen=LOOKS_PER_LABEL))

    def get_quote(self, name: str) -> Optional[Quote]:
        return self._quotes.get(normalize(name))

    def put_quote(self, name: str, quote: Quote) -> None:
        self._quotes[normalize(name)] = quote

    def recently_spoken(self, name: str) -> bool:
        at = self._spoken.get(normalize(name))
        return at is not None and self.clock() - at < self.cooldown_s

    def mark_spoken(self, name: str) -> None:
        self._spoken[normalize(name)] = self.clock()

    def remember_look(self, label: str, look: bytes, name: str) -> None:
        self._looks[label].append((look, normalize(name)))

    def name_for_look(self, label: str, look: bytes) -> Optional[str]:
        best = min(self._looks.get(label, ()), key=lambda seen: _distance(seen[0], look), default=None)
        if best is None or _distance(best[0], look) > LOOK_TOLERANCE:
            return None
        return best[1]
