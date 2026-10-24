"""Thrift Lens backend: frame in, spoken line out. Pipeline steps are stubs for now."""
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.staticfiles import StaticFiles

from .cache import ItemCache
from .decide import decide, quote_for, tag_for

WEB_DIR = Path(__file__).resolve().parents[2] / "web"
LOG_SIZE = 200

app = FastAPI(title="Thrift Lens")
log: deque[dict] = deque(maxlen=LOG_SIZE)  # newest first
cache = ItemCache()


def identify(jpeg: bytes) -> dict:
    """Stub for the Gemini identify call (no search)."""
    return {"item": "Pyrex mixing bowl", "maker": "Pyrex", "wear": "light"}


def price(item: dict) -> dict:
    """Stub for the search-grounded price call. Only called for new items with no demo comps."""
    return {
        "low": 40,
        "high": 60,
        "confidence": 0.8,
        "source": "comps",
        "sources": [{"title": "demo comps", "url": "https://example.com"}],
    }


def say(item: dict, quote: dict) -> str:
    return f"{quote['low']} to {quote['high']} dollars. {item['item']}."


@app.post("/api/frame")
async def frame(request: Request) -> dict:
    jpeg = await request.body()
    item = identify(jpeg)
    key, quote = quote_for(item, price, cache)
    tag = tag_for(item)
    speak, reason = decide(key, tag, quote, cache, time.monotonic())
    line = say(item, quote) if speak else ""
    log.appendleft(
        {
            "ts": datetime.now(timezone.utc).isoformat(),
            **item,
            "tag": tag,
            **quote,
            "decision": "spoke" if speak else "quiet",
            "reason": reason,
            "line": line,
        }
    )
    return {"speak": line}


@app.get("/api/log")
def get_log() -> list[dict]:
    return list(log)


# Registered last so /api routes win.
app.mount("/", StaticFiles(directory=WEB_DIR, html=True), name="web")
