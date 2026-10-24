"""In-memory item cache: quotes by item key, plus when each item was last spoken."""
from __future__ import annotations


class ItemCache:
    def __init__(self) -> None:
        self._quotes: dict[str, dict] = {}
        self._spoken: dict[str, float] = {}

    def get(self, key: str) -> dict | None:
        return self._quotes.get(key)

    def put(self, key: str, quote: dict) -> None:
        self._quotes[key] = quote

    def mark_spoken(self, key: str, now: float) -> None:
        self._spoken[key] = now

    def spoke_recently(self, key: str, now: float, window: float = 30) -> bool:
        last = self._spoken.get(key)
        return last is not None and now - last <= window
