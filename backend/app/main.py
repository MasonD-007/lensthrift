"""Thrift Lens backend: frame in, spoken line out."""
from collections import deque
from datetime import datetime, timezone
from functools import lru_cache, partial
from pathlib import Path

import io
import logging
import json
import time
from logging.handlers import RotatingFileHandler

import httpx
from fastapi import Depends, FastAPI, HTTPException, Request
from google import genai
from PIL import Image
from ultralytics import YOLO
from fastapi.staticfiles import StaticFiles

from .comps import load_comps
from .config import settings
from .gemini import genai_generate, price_item
from .jev import resalable_score
from .memory import Memory
from .models import Detection, ObjectResult
from .pipeline import Pipeline

LOG_DIR = Path(__file__).resolve().parents[1] / "logs"

logger = logging.getLogger("lensthrift")
if not logger.handlers:
    # Console shows the summary; the file also keeps one JSON line per object for later review.
    LOG_DIR.mkdir(exist_ok=True)
    fmt = logging.Formatter("%(asctime)s %(message)s", "%H:%M:%S")
    console = logging.StreamHandler()
    console.setLevel(logging.INFO)
    console.setFormatter(fmt)
    to_file = RotatingFileHandler(LOG_DIR / "lensthrift.log", maxBytes=5_000_000, backupCount=3)
    to_file.setFormatter(logging.Formatter("%(asctime)s %(message)s", "%Y-%m-%d %H:%M:%S"))
    logger.addHandler(console)
    logger.addHandler(to_file)
    logger.setLevel(logging.DEBUG)

WEB_DIR = Path(__file__).resolve().parents[2] / "web"
LOG_SIZE = 200

YOLO_MODEL = "yolo11n.pt"  # downloaded on first use
yolo = YOLO(YOLO_MODEL)

app = FastAPI(title="Thrift Lens")
log: deque[dict] = deque(maxlen=LOG_SIZE)  # newest first
last_frame: dict = {}  # most recent /api/frame outcome, shown on the judge page


def decode(body: bytes) -> Image.Image:
    try:
        img = Image.open(io.BytesIO(body))
        img.load()
        return img.convert("RGB")
    except Exception:
        raise HTTPException(400, "body is not a decodable image")


def yolo_detect(img: Image.Image) -> list[Detection]:
    """YOLO boxes normalized to 0-1 of the frame."""
    result = yolo.predict(img, imgsz=320, conf=0.3, verbose=False)[0]
    return [
        Detection(result.names[int(c)], float(p), tuple(float(v) for v in xyxyn))
        for c, p, xyxyn in zip(result.boxes.cls, result.boxes.conf, result.boxes.xyxyn)
    ]


@lru_cache(maxsize=None)
def get_pipeline() -> Pipeline:
    """Built on the first frame so the server still starts (and /api/detect works) without keys."""
    missing = [k for k, v in (("GEMINI_API_KEY", settings.gemini_api_key),
                              ("TYPESAFE_API_KEY", settings.typesafe_api_key)) if not v]
    if missing:
        raise HTTPException(503, f"set {', '.join(missing)} in backend/.env")
    jev = partial(resalable_score, client=httpx.AsyncClient(), api_key=settings.typesafe_api_key)
    generate = partial(genai_generate, client=genai.Client(api_key=settings.gemini_api_key),
                       model=settings.gemini_model)
    gemini = partial(price_item, generate=generate, json_mode=settings.gemini_json_mode,
                     send_image=settings.gemini_send_image)
    return Pipeline(yolo_detect, jev, gemini, load_comps(), Memory(settings.cooldown_s), settings)


def log_row(ts: str, r: ObjectResult) -> dict:
    q = r.quote
    return {
        "ts": ts,
        "label": r.detection.label,
        "yolo_conf": r.detection.conf,
        "jev": r.jev,
        "item": q.name if q else None,
        "description": q.description if q else None,
        "tag": r.tag,
        "low": q.low if q else None,
        "high": q.high if q else None,
        "confidence": q.confidence if q else None,
        "source": q.source if q else None,
        "sources": q.sources if q else [],
        "decision": r.decision,
        "reason": r.reason,
        "line": r.line,
    }


def describe(r: ObjectResult) -> str:
    jev = "-" if r.jev is None else f"{r.jev:.2f}"
    price = f" ${r.quote.low:.0f}-{r.quote.high:.0f} '{r.quote.name}'" if r.quote else ""
    return f"  {r.detection.label} {r.detection.conf:.2f} | jev {jev}{price} | {r.decision}: {r.reason}"


@app.post("/api/frame")
async def frame(request: Request, pipeline: Pipeline = Depends(get_pipeline)) -> dict:
    started = time.monotonic()
    img = decode(await request.body())
    try:
        line, results = await pipeline.process_frame(img)
    except Exception:
        logger.exception("frame failed")
        last_frame.update(ts=datetime.now(timezone.utc).isoformat(), objects=0, speak="", error=True)
        raise
    ms = round((time.monotonic() - started) * 1000)
    ts = datetime.now(timezone.utc).isoformat()
    logger.info("frame %dx%d: %d object(s) in %d ms%s", img.width, img.height, len(results), ms,
                f' -> SPEAK "{line}"' if line else "")
    for r in results:
        logger.info(describe(r))
        logger.debug("row %s", json.dumps(log_row(ts, r), default=str))
    last_frame.update(ts=ts, objects=len(results), speak=line, ms=ms, error=False)
    for r in reversed(results):  # keep the frame's own order at the top of the log
        log.appendleft(log_row(ts, r))
    return {"speak": line, "objects": len(results)}


@app.post("/api/detect")
async def detect(request: Request) -> list[dict]:
    """YOLO boxes for the preview overlay, normalized to 0-1 of the sent frame."""
    img = decode(await request.body())
    return [{"label": d.label, "conf": d.conf, "box": list(d.box)} for d in yolo_detect(img)]


@app.get("/api/status")
def get_status() -> dict:
    return last_frame


@app.get("/api/log")
def get_log() -> list[dict]:
    return list(log)


# Registered last so /api routes win.
app.mount("/", StaticFiles(directory=WEB_DIR, html=True), name="web")
