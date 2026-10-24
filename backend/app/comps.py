"""Demo comps: sold prices and tag prices for the demo items, overriding search on a name match."""
from __future__ import annotations

import dataclasses
import json
from pathlib import Path
from typing import Optional

from .models import Quote

COMPS_FILE = Path(__file__).resolve().parents[1] / "comps.json"


def load_comps(path: Path = COMPS_FILE) -> dict:
    return json.loads(path.read_text())


def _match(name: str, comps: dict) -> Optional[dict]:
    """Case-insensitive substring match either way."""
    name = name.lower().strip()
    for key, entry in comps.items():
        key = key.lower().strip()
        if key and name and (key in name or name in key):
            return entry
    return None


def apply_comps(quote: Quote, comps: dict) -> Quote:
    entry = _match(quote.name, comps)
    if entry is None:
        return quote
    return dataclasses.replace(
        quote, low=entry["low"], high=entry["high"], sources=entry["sources"], source="comps"
    )


def tag_for(name: str, comps: dict, default: float) -> float:
    entry = _match(name, comps)
    return entry["tag"] if entry is not None else default
