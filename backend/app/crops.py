"""Pick the biggest YOLO boxes and cut them into JPEGs that fit Jev's image limits."""
from __future__ import annotations

import io
import math
from typing import List, Tuple

from PIL import Image

from .models import Detection

MIN_SIDE = 280
MAX_SIDE = 1568
MARGIN = 0.10  # context around the box, each side
PAD_COLOR = (128, 128, 128)
LOOK_SIZE = 8


def _area(det: Detection) -> float:
    x0, y0, x1, y1 = det.box
    return max(0.0, x1 - x0) * max(0.0, y1 - y0)


def top_detections(dets: List[Detection], limit: int) -> List[Detection]:
    return sorted(dets, key=_area, reverse=True)[:limit]


def _pixel_box(size: Tuple[int, int], det: Detection, margin: float) -> Tuple[int, int, int, int]:
    w, h = size
    x0, y0, x1, y1 = det.box[0] * w, det.box[1] * h, det.box[2] * w, det.box[3] * h
    mx, my = (x1 - x0) * margin, (y1 - y0) * margin
    left = min(max(0, math.floor(x0 - mx)), w - 1)
    top = min(max(0, math.floor(y0 - my)), h - 1)
    right = max(min(w, math.ceil(x1 + mx)), left + 1)
    bottom = max(min(h, math.ceil(y1 + my)), top + 1)
    return left, top, right, bottom


def make_crop(img: Image.Image, det: Detection) -> bytes:
    crop = img.convert("RGB").crop(_pixel_box(img.size, det, MARGIN))
    w, h = crop.size
    scale = 1.0
    if min(w, h) < MIN_SIDE:
        scale = MIN_SIDE / min(w, h)
    if max(w, h) * scale > MAX_SIDE:
        scale = MAX_SIDE / max(w, h)
    if scale != 1.0:
        size = (min(MAX_SIDE, max(1, round(w * scale))), min(MAX_SIDE, max(1, round(h * scale))))
        crop = crop.resize(size, Image.LANCZOS)
    if min(crop.size) < MIN_SIDE:  # extreme aspect ratio: pad the short side
        canvas = Image.new("RGB", (max(crop.width, MIN_SIDE), max(crop.height, MIN_SIDE)), PAD_COLOR)
        canvas.paste(crop, ((canvas.width - crop.width) // 2, (canvas.height - crop.height) // 2))
        crop = canvas
    buf = io.BytesIO()
    crop.save(buf, "JPEG", quality=90)
    return buf.getvalue()


def look(img: Image.Image, det: Detection) -> bytes:
    """Tiny RGB thumbnail of the box: a pre-Gemini key for recognizing the same item across frames."""
    crop = img.convert("RGB").crop(_pixel_box(img.size, det, 0.0))
    return crop.resize((LOOK_SIZE, LOOK_SIZE), Image.BILINEAR).tobytes()
