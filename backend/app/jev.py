"""Jev (TypeSafe System One) client: one noul question per crop, "could someone resell this?".

Request format: https://docs.typesafe.ai/images.md (multipart, JSON body first as `request`).
"""
from __future__ import annotations

import json
import uuid

import httpx

JEV_URL = "https://api.typesafe.ai/v1/systemone"
JEV_MODEL = "jev-latest"
TIMEOUT_S = 10.0
IMAGE_PART = "item-photo"
QUESTION = (
    "Is `item` a physical object someone could resell secondhand, "
    "not a person, a wall, a shelf or another fixture?"
)


class JevError(Exception):
    pass


async def resalable_score(jpeg: bytes, client: httpx.AsyncClient, api_key: str) -> float:
    """Probability (0-1) that the crop shows something resalable."""
    ref = f"{uuid.uuid4()}-item"  # fresh reference so it can't collide with text
    body = {
        "model": JEV_MODEL,
        "state": {"item": ref},
        "assets": {ref: {"type": "image", "part": IMAGE_PART}},
        "questions": {"resalable": {"type": "noul", "instructions": QUESTION}},
    }
    try:
        resp = await client.post(
            JEV_URL,
            headers={"Authorization": f"Bearer {api_key}", "TypeSafe-Danger-Zone-Images": "true"},
            files={
                "request": (None, json.dumps(body), "application/json"),
                IMAGE_PART: ("item.jpg", jpeg, "image/jpeg"),
            },
            timeout=TIMEOUT_S,
        )
    except httpx.HTTPError as exc:
        raise JevError(f"{type(exc).__name__}: {exc}") from exc
    if not resp.is_success:
        raise JevError(f"jev {resp.status_code}: {resp.text[:200]}")
    try:
        return float(resp.json()["answers"]["resalable"]["noul"])
    except (ValueError, KeyError, TypeError) as exc:
        raise JevError(f"jev answer missing: {resp.text[:200]}") from exc
