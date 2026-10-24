import io

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app import main
from app.config import load_settings
from app.models import Detection, ObjectResult, Quote

ROW_FIELDS = {
    "ts", "label", "yolo_conf", "jev", "item", "description", "tag", "low", "high",
    "confidence", "source", "sources", "decision", "reason", "line",
}


def jpeg_bytes():
    buf = io.BytesIO()
    Image.new("RGB", (64, 48), (90, 90, 90)).save(buf, "JPEG")
    return buf.getvalue()


class FakePipeline:
    def __init__(self, line, results):
        self.line, self.results = line, results
        self.frames = []

    async def process_frame(self, img):
        self.frames.append(img)
        return self.line, self.results


@pytest.fixture
def client():
    main.log.clear()
    yield TestClient(main.app)
    main.app.dependency_overrides.clear()
    main.log.clear()


def use(pipeline):
    main.app.dependency_overrides[main.get_pipeline] = lambda: pipeline


LAMP = Quote("brass lamp", "brass desk lamp", 80, 120, 0.9, "search", [{"url": "https://a", "title": "A"}])
SPOKE = ObjectResult(Detection("vase", 0.71, (0, 0, 0.5, 0.5)), 0.93, LAMP, 10, "spoke", "resale beats tag",
                     "80 to 120 dollars, brass desk lamp.")
JUNK = ObjectResult(Detection("chair", 0.55, (0.5, 0.5, 1, 1)), 0.08, None, None, "quiet", "not resalable", "")


def test_frame_returns_speak_and_logs_each_object(client):
    fake = FakePipeline("80 to 120 dollars, brass desk lamp.", [SPOKE, JUNK])
    use(fake)
    r = client.post("/api/frame", content=jpeg_bytes(), headers={"Content-Type": "image/jpeg"})
    assert r.status_code == 200
    assert r.json() == {"speak": "80 to 120 dollars, brass desk lamp."}
    assert fake.frames[0].mode == "RGB"

    rows = client.get("/api/log").json()
    assert len(rows) == 2
    assert all(set(row) == ROW_FIELDS for row in rows)
    first, second = rows
    assert (first["label"], first["yolo_conf"], first["jev"], first["item"], first["description"]) == (
        "vase", 0.71, 0.93, "brass lamp", "brass desk lamp")
    assert (first["tag"], first["low"], first["high"], first["confidence"], first["source"]) == (10, 80, 120, 0.9, "search")
    assert (first["decision"], first["reason"], first["line"]) == ("spoke", "resale beats tag", SPOKE.line)
    assert first["sources"] == [{"url": "https://a", "title": "A"}]
    assert (second["label"], second["decision"], second["item"], second["low"]) == ("chair", "quiet", None, None)


def test_newer_frames_log_first(client):
    use(FakePipeline("", [JUNK]))
    client.post("/api/frame", content=jpeg_bytes())
    use(FakePipeline("x", [SPOKE]))
    client.post("/api/frame", content=jpeg_bytes())
    assert [row["label"] for row in client.get("/api/log").json()] == ["vase", "chair"]


def test_non_image_body_returns_400(client):
    use(FakePipeline("", []))
    r = client.post("/api/frame", content=b"definitely not a jpeg")
    assert r.status_code == 400


def test_empty_body_returns_400(client):
    use(FakePipeline("", []))
    assert client.post("/api/frame", content=b"").status_code == 400


def test_empty_frame_returns_empty_speak_and_no_log(client):
    use(FakePipeline("", []))
    r = client.post("/api/frame", content=jpeg_bytes())
    assert r.json() == {"speak": ""}
    assert client.get("/api/log").json() == []


def test_detect_non_image_returns_400(client):
    assert client.post("/api/detect", content=b"nope").status_code == 400


def test_frame_without_keys_returns_503(client, monkeypatch):
    monkeypatch.setattr(main, "settings", load_settings({}))
    main.get_pipeline.cache_clear()
    r = client.post("/api/frame", content=jpeg_bytes())
    assert r.status_code == 503
    assert "GEMINI_API_KEY" in r.json()["detail"]
