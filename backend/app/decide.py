"""Speak-or-stay-quiet rule and whisper phrasing: price first, item second."""
from __future__ import annotations

from typing import List, Tuple

from .models import Quote


def decide(tag: float, quote: Quote, min_conf: float) -> Tuple[bool, str]:
    if quote.confidence < min_conf:
        return False, "low confidence"
    if quote.low <= tag:
        return False, "resale does not beat tag"
    return True, "resale beats tag"


def _dollars(x: float) -> str:
    return str(int(round(x)))


def phrase(quote: Quote) -> str:
    return f"{_dollars(quote.low)} to {_dollars(quote.high)} dollars, {quote.description}."


def compose(winners: List[Tuple[float, Quote]]) -> str:
    """winners: (tag, quote) pairs. Biggest profit (low end minus tag) first."""
    ordered = sorted(winners, key=lambda w: w[1].low - w[0], reverse=True)
    return " ".join(phrase(q) for _, q in ordered)
