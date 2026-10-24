"""Thrift Lens backend: frame in, spoken line out. Pipeline steps are stubs for now."""
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.staticfiles import StaticFiles

WEB_DIR = Path(__file__).resolve().parents[2] / "web"
LOG_SIZE = 200

app = FastAPI(title="Thrift Lens")
log: deque[dict] = deque(maxlen=LOG_SIZE)  # newest first


def identify(jpeg: bytes) -> dict:
    """Stub for the Gemini identify call (no search)."""
    return {"item": "Pyrex mixing bowl", "maker": "Pyrex", "wear": "light"}


def price(item: dict) -> dict:
    """Stub for the search-grounded price call; demo comps override on a name match."""
    return {
        "low": 40,
        "high": 60,
        "confidence": 0.8,
        "source": "comps",
        "sources": [{"title": "demo comps", "url": "https://example.com"}],
    }


def tag_price(item: dict) -> float:
    """Hardcoded per demo item."""
    return 5


def decide(tag: float, quote: dict) -> tuple[bool, str]:
    if quote["confidence"] < 0.6:
        return False, "low confidence"
    if quote["low"] <= tag:
        return False, "resale does not beat tag"
    return True, "resale beats tag"


def say(item: dict, quote: dict) -> str:
    return f"{quote['low']} to {quote['high']} dollars. {item['item']}."


@app.post("/api/frame")
async def frame(request: Request) -> dict:
    jpeg = await request.body()
    item = identify(jpeg)
    quote = price(item)
    tag = tag_price(item)
    speak, reason = decide(tag, quote)
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
