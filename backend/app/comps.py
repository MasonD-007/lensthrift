"""Demo comps: real sold prices and tag prices for the items on the demo table.

A comps entry overrides the search price whenever every one of its keywords
appears in the identified name or maker. Fill these in with real eBay *sold*
listings before the event; the values below are placeholders.
"""
from __future__ import annotations

import re

# Words Gemini adds or drops between frames; ignoring them keeps keys stable.
FILLER = {"a", "an", "the", "and", "of", "with", "vintage", "antique", "retro", "old", "unknown"}

# id -> keywords (all must match), tag (hardcoded tag price), low/high (sold comps), sources
DEMO_ITEMS: dict[str, dict] = {
    # TODO: replace with the real demo finds and their sold listings.
    "pyrex-bowl": {
        "keywords": {"pyrex", "bowl"},
        "tag": 5,
        "low": 40,
        "high": 60,
        "sources": [],
    },
    # Junk gets an entry too, so it has a tag and stays quiet without a search call.
    "mug": {
        "keywords": {"mug"},
        "tag": 2,
        "low": 1,
        "high": 4,
        "sources": [],
    },
}


def tokens(text: str) -> set[str]:
    return set(re.findall(r"[a-z0-9]+", text.lower())) - FILLER


def match(item: dict, items: dict[str, dict] = DEMO_ITEMS) -> str | None:
    """Return the id of the most specific comps entry matching the item, if any."""
    words = tokens(f"{item.get('item', '')} {item.get('maker', '')}")
    hits = [k for k, e in items.items() if e["keywords"] <= words]
    return max(hits, key=lambda k: len(items[k]["keywords"]), default=None)


def item_key(item: dict, items: dict[str, dict] = DEMO_ITEMS) -> str:
    """Cache key: the comps id on a match, else the name's words in sorted order.

    Empty when the item couldn't be identified.
    """
    return match(item, items) or " ".join(sorted(tokens(item.get("item", ""))))
