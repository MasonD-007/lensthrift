import io
from functools import lru_cache

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app import main
from app.config import load_settings
from app.models import Detection, ObjectResult, Quote

ROW_FIELDS = {
    "ts", "label", "yolo_conf", "box", "jev", "item", "description", "tag", "low", "high",
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
    assert r.json()["speak"] == "80 to 120 dollars, brass desk lamp."
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
    assert r.json() == {"speak": "", "objects": []}
    assert client.get("/api/log").json() == []


def test_detect_non_image_returns_400(client):
    assert client.post("/api/detect", content=b"nope").status_code == 400


def test_frame_without_keys_returns_503(client, monkeypatch):
    monkeypatch.setattr(main, "settings", load_settings({}))
    main.get_pipeline.cache_clear()
    r = client.post("/api/frame", content=jpeg_bytes())
    assert r.status_code == 503
    assert "GEMINI_API_KEY" in r.json()["detail"]


def test_frame_returns_objects_with_boxes(client):
    use(FakePipeline(SPOKE.line, [SPOKE, JUNK]))
    body = client.post("/api/frame", content=jpeg_bytes()).json()
    assert body["speak"] == SPOKE.line
    objects = body["objects"]
    assert [o["label"] for o in objects] == ["vase", "chair"]
    assert all(set(o) == ROW_FIELDS for o in objects)
    assert objects[0]["box"] == [0, 0, 0.5, 0.5]
    assert objects == client.get("/api/log").json()


def test_delete_log_clears_rows(client):
    use(FakePipeline("", [JUNK]))
    client.post("/api/frame", content=jpeg_bytes())
    assert client.delete("/api/log").status_code == 204
    assert client.get("/api/log").json() == []


class FakeMemory:
    def __init__(self):
        self.cleared = 0

    def clear(self):
        self.cleared += 1


def test_delete_memory_clears_built_pipeline(client, monkeypatch):
    fake = FakePipeline("", [])
    fake.memory = FakeMemory()
    built = lru_cache(maxsize=None)(lambda: fake)
    built()  # a frame has already built the pipeline
    monkeypatch.setattr(main, "get_pipeline", built)
    assert client.delete("/api/memory").status_code == 204
    assert fake.memory.cleared == 1


def test_delete_memory_without_pipeline_does_not_build_one(client, monkeypatch):
    calls = []
    monkeypatch.setattr(main, "get_pipeline", lru_cache(maxsize=None)(lambda: calls.append(1)))
    assert client.delete("/api/memory").status_code == 204
    assert calls == []


def test_status_reports_last_frame_count_and_line(client):
    use(FakePipeline(SPOKE.line, [SPOKE, JUNK]))
    client.post("/api/frame", content=jpeg_bytes())
    status = client.get("/api/status").json()
    assert (status["objects"], status["speak"], status["error"]) == (2, SPOKE.line, False)
