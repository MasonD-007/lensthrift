"""Gemini price client: identify the crop and price it from used/sold listings via Google Search grounding.

`price_item` takes an injected `generate` so tests use fakes; `genai_generate` is the real
google-genai call. With GEMINI_SEND_IMAGE=0 (grounded calls that refuse images), a quick
identify call without search names the item first and only the name goes to the grounded call.
"""
from __future__ import annotations

import asyncio
import json
import re
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, List, Optional

from google.genai import types
from pydantic import BaseModel, Field, ValidationError

from .models import Quote

TIMEOUT_S = 15.0

PRICE_SCHEMA = {
    "type": "object",
    "properties": {
        "name": {"type": "string"},
        "description": {"type": "string"},
        "low": {"type": "number"},
        "high": {"type": "number"},
        "confidence": {"type": "number"},
    },
    "required": ["name", "description", "low", "high", "confidence"],
}
IDENTIFY_SCHEMA = {
    "type": "object",
    "properties": {"name": {"type": "string"}, "description": {"type": "string"}},
    "required": ["name", "description"],
}

_FIELDS = (
    "name (a few words with one distinguishing detail such as maker, material, pattern or era), "
    "description (a short phrase that is spoken aloud right after the price)"
)
_PRICE_RULES = (
    "Search for recent used or sold prices (sold listings on eBay, Etsy, Poshmark and similar), "
    "not retail, new or asking prices, and give a realistic secondhand resale range in USD. "
    f"Return only JSON with these fields: {_FIELDS}, low (number, USD), high (number, USD), "
    "confidence (0 to 1: how sure you are of both the identification and the price)."
)
PRICE_PROMPT = "You price items for a thrift-store reseller. Identify the item in the photo. " + _PRICE_RULES
PRICE_BY_NAME_PROMPT = "You price items for a thrift-store reseller. The item is: {name} ({description}). " + _PRICE_RULES
IDENTIFY_PROMPT = f"Identify the item in the photo. Return only JSON with these fields: {_FIELDS}."


class GeminiError(Exception):
    pass


@dataclass(frozen=True)
class GenResult:
    text: str
    citations: List[dict] = field(default_factory=list)  # [{"url", "title"}]


Generate = Callable[..., Awaitable[GenResult]]


class _Identity(BaseModel):
    name: str = Field(min_length=1)
    description: str


class _Price(_Identity):
    low: float
    high: float
    confidence: float = Field(ge=0, le=1)


_FENCE = re.compile(r"```(?:json)?\s*(\{.*?\})\s*```", re.DOTALL)


def _parse(text: str, model: type) -> Any:
    candidates = [text.strip()]
    candidates += _FENCE.findall(text)
    if "{" in text and "}" in text:
        candidates.append(text[text.index("{") : text.rindex("}") + 1])
    for candidate in candidates:
        try:
            return model.model_validate(json.loads(candidate))
        except (ValueError, ValidationError):
            continue
    raise GeminiError(f"unparseable Gemini output: {text[:200]!r}")


async def price_item(
    jpeg: bytes, generate: Generate, *, json_mode: str = "prompt", send_image: bool = True
) -> Quote:
    schema_mode = json_mode == "schema"
    if send_image:
        result = await generate(PRICE_PROMPT, image=jpeg, search=True, schema=PRICE_SCHEMA if schema_mode else None)
    else:
        ident = await generate(IDENTIFY_PROMPT, image=jpeg, search=False, schema=IDENTIFY_SCHEMA if schema_mode else None)
        who = _parse(ident.text, _Identity)
        prompt = PRICE_BY_NAME_PROMPT.format(name=who.name, description=who.description)
        result = await generate(prompt, image=None, search=True, schema=PRICE_SCHEMA if schema_mode else None)
    p = _parse(result.text, _Price)
    low, high = sorted((p.low, p.high))
    return Quote(p.name, p.description, low, high, p.confidence, "search", list(result.citations))


def _citations(response: Any) -> List[dict]:
    seen, out = set(), []
    for cand in getattr(response, "candidates", None) or []:
        meta = getattr(cand, "grounding_metadata", None)
        for chunk in getattr(meta, "grounding_chunks", None) or []:
            web = getattr(chunk, "web", None)
            uri = getattr(web, "uri", None)
            if uri and uri not in seen:
                seen.add(uri)
                out.append({"url": uri, "title": getattr(web, "title", None) or uri})
    return out


async def genai_generate(
    prompt: str,
    *,
    image: Optional[bytes] = None,
    search: bool = False,
    schema: Optional[dict] = None,
    client: Any,
    model: str,
) -> GenResult:
    """One google-genai call. `client` is a genai.Client; bind it and `model` with functools.partial."""
    contents: list = [types.Part.from_bytes(data=image, mime_type="image/jpeg")] if image is not None else []
    contents.append(prompt)
    config = types.GenerateContentConfig(
        tools=[types.Tool(google_search=types.GoogleSearch())] if search else None,
        response_mime_type="application/json" if schema else None,
        response_json_schema=schema,
        temperature=0.2,
    )
    response = await asyncio.wait_for(
        client.aio.models.generate_content(model=model, contents=contents, config=config), TIMEOUT_S
    )
    return GenResult(response.text or "", _citations(response))
