import json
from types import SimpleNamespace

import pytest

from app.gemini import GeminiError, GenResult, genai_generate, price_item
from app.models import Quote

JPEG = b"\xff\xd8fake\xff\xd9"
BOWL = {
    "name": "milk glass mixing bowl",
    "description": "white milk glass mixing bowl with a floral band",
    "low": 40,
    "high": 60,
    "confidence": 0.8,
}
CITES = [{"url": "https://ebay.example/sold/1", "title": "eBay sold"}]


class FakeGenerate:
    def __init__(self, *texts, citations=CITES):
        self.texts = list(texts)
        self.citations = citations
        self.calls = []

    async def __call__(self, prompt, *, image=None, search=False, schema=None):
        self.calls.append({"prompt": prompt, "image": image, "search": search, "schema": schema})
        return GenResult(self.texts.pop(0), list(self.citations))


async def test_parses_json_into_quote():
    gen = FakeGenerate(json.dumps(BOWL))
    q = await price_item(JPEG, gen)
    assert q == Quote(
        name="milk glass mixing bowl",
        description="white milk glass mixing bowl with a floral band",
        low=40,
        high=60,
        confidence=0.8,
        source="search",
        sources=CITES,
    )


async def test_extracts_json_from_code_fence():
    gen = FakeGenerate("Here you go:\n```json\n" + json.dumps(BOWL) + "\n```\nHope that helps.")
    assert (await price_item(JPEG, gen)).low == 40


async def test_raises_gemini_error_on_non_json():
    with pytest.raises(GeminiError):
        await price_item(JPEG, FakeGenerate("I can't tell what this is."))


async def test_raises_gemini_error_on_missing_field():
    partial = {k: v for k, v in BOWL.items() if k != "low"}
    with pytest.raises(GeminiError):
        await price_item(JPEG, FakeGenerate(json.dumps(partial)))


async def test_swaps_reversed_range():
    q = await price_item(JPEG, FakeGenerate(json.dumps({**BOWL, "low": 60, "high": 40})))
    assert (q.low, q.high) == (40, 60)


async def test_prompt_asks_for_used_sold_prices():
    gen = FakeGenerate(json.dumps(BOWL))
    await price_item(JPEG, gen)
    prompt = gen.calls[-1]["prompt"].lower()
    assert "sold" in prompt and "used" in prompt


async def test_send_image_makes_one_grounded_call_with_the_image():
    gen = FakeGenerate(json.dumps(BOWL))
    await price_item(JPEG, gen, send_image=True)
    assert [(c["search"], c["image"]) for c in gen.calls] == [(True, JPEG)]


async def test_without_image_identifies_first_then_searches_by_name():
    ident = {"name": "milk glass mixing bowl", "description": "white milk glass bowl, floral band"}
    gen = FakeGenerate(json.dumps(ident), json.dumps(BOWL))
    q = await price_item(JPEG, gen, send_image=False)
    first, second = gen.calls
    assert (first["search"], first["image"]) == (False, JPEG)
    assert (second["search"], second["image"]) == (True, None)
    assert "milk glass mixing bowl" in second["prompt"]
    assert q.name == "milk glass mixing bowl"


async def test_schema_mode_passes_a_schema_and_prompt_mode_does_not():
    gen = FakeGenerate(json.dumps(BOWL), json.dumps(BOWL))
    await price_item(JPEG, gen, json_mode="schema")
    await price_item(JPEG, gen, json_mode="prompt")
    assert gen.calls[0]["schema"]["required"] == ["name", "description", "low", "high", "confidence"]
    assert gen.calls[1]["schema"] is None


class FakeModels:
    def __init__(self, response):
        self.response = response
        self.kwargs = None

    async def generate_content(self, **kwargs):
        self.kwargs = kwargs
        return self.response


def fake_client(text, chunks=()):
    web = [SimpleNamespace(web=SimpleNamespace(uri=u, title=t)) for u, t in chunks]
    cand = SimpleNamespace(grounding_metadata=SimpleNamespace(grounding_chunks=web))
    models = FakeModels(SimpleNamespace(text=text, candidates=[cand]))
    return SimpleNamespace(aio=SimpleNamespace(models=models)), models


async def test_genai_generate_sends_image_and_search_tool_and_returns_citations():
    client, models = fake_client("{}", [("https://a", "A"), ("https://a", "A"), ("https://b", None)])
    result = await genai_generate("price it", image=JPEG, search=True, client=client, model="m")
    assert result == GenResult("{}", [{"url": "https://a", "title": "A"}, {"url": "https://b", "title": "https://b"}])
    assert models.kwargs["model"] == "m"
    image_part, text = models.kwargs["contents"]
    assert image_part.inline_data.data == JPEG and image_part.inline_data.mime_type == "image/jpeg"
    assert text == "price it"
    (tool,) = models.kwargs["config"].tools
    assert tool.google_search is not None
    assert models.kwargs["config"].response_mime_type is None


async def test_genai_generate_without_search_has_no_tools_and_honors_schema():
    client, models = fake_client("{}")
    schema = {"type": "object"}
    await genai_generate("identify", image=None, search=False, schema=schema, client=client, model="m")
    config = models.kwargs["config"]
    assert not config.tools
    assert models.kwargs["contents"] == ["identify"]
    assert config.response_mime_type == "application/json"
    assert config.response_json_schema == schema
