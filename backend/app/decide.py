"""Cache and decision: pick the quote (comps, cache, or search) and decide whether to speak."""
from __future__ import annotations

from typing import Callable

from .cache import ItemCache
from .comps import DEMO_ITEMS, item_key, match

# Tune these during hardening.
CONF_MIN = 0.6      # below this, the price is treated as unknown
MIN_PROFIT = 15     # dollars the low resale estimate must clear the tag by
MIN_MULTIPLE = 2    # and the low estimate must be at least this many times the tag
REPEAT_S = 30       # the same item stays silent for this long after speaking

UNKNOWN = {"low": None, "high": None, "confidence": 0.0, "sources": []}


def quote_for(
    item: dict,
    price_fn: Callable[[dict], dict],
    cache: ItemCache,
    items: dict[str, dict] = DEMO_ITEMS,
) -> tuple[str, dict]:
    """Return (key, quote) with quote["source"] set to comps, cache, or search."""
    key = item_key(item, items)
    if not key:
        return key, {**UNKNOWN, "source": "search"}

    comp_id = match(item, items)
    if comp_id:
        e = items[comp_id]
        return key, {"low": e["low"], "high": e["high"], "confidence": 1.0,
                     "sources": e["sources"], "source": "comps"}

    cached = cache.get(key)
    if cached is not None:
        return key, {**cached, "source": "cache"}

    quote = price_fn(item)
    cache.put(key, quote)
    return key, {**quote, "source": "search"}


def tag_for(item: dict, items: dict[str, dict] = DEMO_ITEMS) -> float | None:
    """Hardcoded tag price for demo items; None for anything else."""
    comp_id = match(item, items)
    return items[comp_id]["tag"] if comp_id else None


def decide(key: str, tag: float | None, quote: dict, cache: ItemCache, now: float) -> tuple[bool, str]:
    """Hunt mode: speak only when resale clearly beats the tag, once per item per REPEAT_S."""
    low = quote.get("low")
    if low is None:
        return False, "unknown price"
    if quote.get("confidence", 0) < CONF_MIN:
        return False, "low confidence"
    if tag is None:
        return False, "no tag price"
    if low - tag < MIN_PROFIT or low < MIN_MULTIPLE * tag:
        return False, "resale does not beat tag"
    if cache.spoke_recently(key, now, REPEAT_S):
        return False, "said it already"
    cache.mark_spoken(key, now)
    return True, "resale beats tag"
