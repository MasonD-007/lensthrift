"""Live smoke test: send one image to Jev and Gemini with the real keys.

Usage: .venv/bin/python scripts/live_check.py path/to/photo.jpg
"""
import asyncio
import io
import sys
from functools import partial

import httpx
from google import genai
from PIL import Image

from app.config import settings
from app.gemini import genai_generate, price_item
from app.jev import resalable_score


def prepare(path: str) -> bytes:
    img = Image.open(path).convert("RGB")
    img.thumbnail((1568, 1568))
    if min(img.size) < 280:
        scale = 280 / min(img.size)
        img = img.resize((round(img.width * scale), round(img.height * scale)))
    out = io.BytesIO()
    img.save(out, "JPEG", quality=90)
    return out.getvalue()


async def main(path: str) -> None:
    jpeg = prepare(path)
    async with httpx.AsyncClient() as http:
        try:
            print("jev  :", await resalable_score(jpeg, http, settings.typesafe_api_key))
        except Exception as e:
            print("jev  : FAILED", repr(e))
    generate = partial(
        genai_generate, client=genai.Client(api_key=settings.gemini_api_key), model=settings.gemini_model
    )
    try:
        q = await price_item(
            jpeg, generate, json_mode=settings.gemini_json_mode, send_image=settings.gemini_send_image
        )
        print("gemini:", q)
    except Exception as e:
        print("gemini: FAILED", repr(e))


asyncio.run(main(sys.argv[1]))
