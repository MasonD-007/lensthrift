import sys
import threading

import pytest
from fastapi.testclient import TestClient

from app import main
from app.models import Detection


@pytest.fixture
def client():
    main.seen.clear()
    main.last_seen.clear()
    yield TestClient(main.app)
    main.seen.clear()
    main.last_seen.clear()


@pytest.fixture
def clock(monkeypatch):
    now = [100.0]
    monkeypatch.setattr(main.time, "monotonic", lambda: now[0])
    return now


def mug(conf=0.8):
    return Detection("mug", conf, (0, 0, 1, 1))


def labels(client, **params):
    return [s["label"] for s in client.get("/api/seen", params=params).json()]


def test_object_held_in_view_is_recorded_once(client, clock):
    for _ in range(5):
        main.record_seen([mug()])
        clock[0] += 0.5
    assert labels(client) == ["mug"]


def test_object_returning_after_a_gap_is_recorded_again(client, clock):
    main.record_seen([mug()])
    clock[0] += main.SEEN_GAP_S + 0.5
    main.record_seen([mug()])
    assert labels(client) == ["mug", "mug"]


def test_after_returns_only_newer_entries(client, clock):
    main.record_seen([mug()])
    clock[0] += 5
    main.record_seen([Detection("lamp", 0.6, (0, 0, 1, 1))])
    first = client.get("/api/seen").json()[0]["id"]
    assert labels(client, after=first) == ["lamp"]


def test_stale_boot_token_replays_the_whole_feed(client, clock):
    """A server restart restarts the ids; a client holding the old boot token must start over."""
    main.record_seen([mug()])
    r = client.get("/api/seen", params={"after": 999, "boot": "old-server"})
    assert [s["label"] for s in r.json()] == ["mug"]
    assert r.headers["x-seen-boot"] == main.BOOT_ID


def test_current_boot_token_is_honored(client, clock):
    main.record_seen([mug()])
    last = client.get("/api/seen").json()[-1]["id"]
    r = client.get("/api/seen", params={"after": last, "boot": main.BOOT_ID})
    assert r.json() == []


def test_reading_while_detections_arrive_does_not_crash(client):
    """get_seen runs in a worker thread while detect appends on the event loop."""
    stop = threading.Event()
    interval = sys.getswitchinterval()
    sys.setswitchinterval(1e-6)  # switch threads constantly so an unsafe read would be caught

    def writer():
        i = 0
        while not stop.is_set():
            main.seen.append({"id": i, "ts": "t", "label": "x", "conf": 0.5})
            i += 1

    t = threading.Thread(target=writer)
    t.start()
    try:
        for _ in range(100):
            assert client.get("/api/seen", params={"after": 10**9, "boot": main.BOOT_ID}).status_code == 200
    finally:
        stop.set()
        t.join()
        sys.setswitchinterval(interval)
