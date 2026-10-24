import json
from email import message_from_bytes
from email.policy import HTTP

import httpx
import pytest

from app.jev import JEV_URL, QUESTION, JevError, resalable_score

JPEG = b"\xff\xd8\xff\xe0fake-jpeg\xff\xd9"


def multipart_parts(request: httpx.Request):
    """Parse a multipart/form-data body into [(name, filename, content_type, payload)] in order."""
    raw = b"Content-Type: " + request.headers["content-type"].encode() + b"\r\n\r\n" + request.read()
    msg = message_from_bytes(raw, policy=HTTP)
    return [
        (p.get_param("name", header="content-disposition"), p.get_filename(), p.get_content_type(), p.get_payload(decode=True))
        for p in msg.iter_parts()
    ]


def client_returning(status=200, body=None, seen=None):
    def handler(request):
        if seen is not None:
            seen.append(request)
        return httpx.Response(status, json=body if body is not None else {})

    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


OK = {"model": "jev-1.14.0", "answers": {"resalable": {"type": "noul", "noul": 0.83}}}


async def test_sends_multipart_with_header_and_asset():
    seen = []
    async with client_returning(body=OK, seen=seen) as client:
        await resalable_score(JPEG, client, "k")
    (req,) = seen
    assert str(req.url) == JEV_URL
    assert req.method == "POST"
    assert req.headers["TypeSafe-Danger-Zone-Images"] == "true"
    assert req.headers["Authorization"] == "Bearer k"

    parts = multipart_parts(req)
    name, _, ctype, payload = parts[0]
    assert (name, ctype) == ("request", "application/json")  # JSON body must be the first part
    body = json.loads(payload)
    assert body["model"] == "jev-latest"
    ref = body["state"]["item"]
    asset = body["assets"][ref]
    assert asset["type"] == "image"
    assert body["questions"]["resalable"] == {"type": "noul", "instructions": QUESTION}

    image_parts = [p for p in parts[1:] if p[0] == asset["part"]]
    assert len(image_parts) == 1
    assert image_parts[0][2] == "image/jpeg"
    assert image_parts[0][3] == JPEG


async def test_uses_a_fresh_reference_per_request():
    seen = []
    async with client_returning(body=OK, seen=seen) as client:
        await resalable_score(JPEG, client, "k")
        await resalable_score(JPEG, client, "k")
    refs = [json.loads(multipart_parts(r)[0][3])["state"]["item"] for r in seen]
    assert refs[0] != refs[1]


async def test_returns_noul_value():
    async with client_returning(body=OK) as client:
        assert await resalable_score(JPEG, client, "k") == 0.83


async def test_raises_jev_error_on_400():
    async with client_returning(400, {"error": "image too small"}) as client:
        with pytest.raises(JevError, match="400"):
            await resalable_score(JPEG, client, "k")


async def test_raises_jev_error_when_answer_missing():
    async with client_returning(body={"answers": {}}) as client:
        with pytest.raises(JevError):
            await resalable_score(JPEG, client, "k")


async def test_raises_jev_error_on_timeout():
    def handler(request):
        raise httpx.ReadTimeout("slow", request=request)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(JevError, match="ReadTimeout"):
            await resalable_score(JPEG, client, "k")
