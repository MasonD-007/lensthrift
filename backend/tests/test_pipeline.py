import dataclasses
import io

from PIL import Image, ImageDraw

from app.config import load_settings
from app.decide import phrase
from app.memory import Memory
from app.models import Detection, Quote
from app.pipeline import Pipeline

W, H = 640, 480
PALETTE = {
    "red": (220, 30, 30),
    "blue": (30, 30, 220),
    "green": (30, 180, 30),
    "yellow": (230, 220, 30),
    "purple": (140, 30, 160),
    "cyan": (30, 200, 210),
    "white": (250, 250, 250),
}


class JevError(Exception):
    pass


def scene(*items):
    """items: (color, label, (x0, y0, x1, y1) px). Returns frame + YOLO-style detections."""
    img = Image.new("RGB", (W, H), (128, 128, 128))
    draw = ImageDraw.Draw(img)
    dets = []
    for color, label, (x0, y0, x1, y1) in items:
        draw.rectangle((x0, y0, x1, y1), fill=PALETTE[color])
        dets.append(Detection(label, 0.9, (x0 / W, y0 / H, x1 / W, y1 / H)))
    return img, dets


def color_of(jpeg):
    img = Image.open(io.BytesIO(jpeg)).convert("RGB")
    px = img.getpixel((img.width // 2, img.height // 2))
    return min(PALETTE, key=lambda c: sum((a - b) ** 2 for a, b in zip(PALETTE[c], px)))


def quote(name, low, high=None, confidence=0.8):
    return Quote(name, f"{name} description", low, high or low + 20, confidence, "search", [])


class Fakes:
    def __init__(self, dets, scores, quotes):
        self.dets = dets
        self.scores = scores  # color -> float | Exception
        self.quotes = quotes  # color -> Quote | Exception
        self.jev_calls = []
        self.gemini_calls = []

    def detect(self, img):
        return list(self.dets)

    async def jev(self, jpeg):
        color = color_of(jpeg)
        self.jev_calls.append(color)
        value = self.scores[color]
        if isinstance(value, Exception):
            raise value
        return value

    async def gemini(self, jpeg):
        color = color_of(jpeg)
        self.gemini_calls.append(color)
        value = self.quotes[color]
        if isinstance(value, Exception):
            raise value
        return value


def build(fakes, comps=None, memory=None, max_boxes=5):
    """Multi-object tests opt into several boxes; the app default is one object per frame."""
    return Pipeline(
        detect=fakes.detect,
        jev=fakes.jev,
        gemini=fakes.gemini,
        comps=comps or {},
        memory=memory or Memory(30),
        settings=dataclasses.replace(load_settings({}), max_boxes=max_boxes),
    )


LAMP = ("red", "vase", (40, 40, 240, 240))
MUG = ("blue", "cup", (360, 200, 520, 360))


async def test_no_detections_returns_empty():
    img, _ = scene()
    fakes = Fakes([], {}, {})
    assert await build(fakes).process_frame(img) == ("", [])
    assert fakes.jev_calls == []


async def test_junk_stops_at_jev():
    img, dets = scene(LAMP)
    fakes = Fakes(dets, {"red": 0.1}, {"red": quote("brass lamp", 80)})
    line, results = await build(fakes).process_frame(img)
    assert line == ""
    assert [(r.decision, r.jev) for r in results] == [("quiet", 0.1)]
    assert results[0].reason == "not resalable"
    assert fakes.gemini_calls == []


async def test_two_winners_whispered_in_profit_order():
    img, dets = scene(MUG, LAMP)
    mug, lamp = quote("stoneware mug", 30), quote("brass lamp", 80)
    fakes = Fakes(dets, {"red": 0.9, "blue": 0.9}, {"red": lamp, "blue": mug})
    line, results = await build(fakes).process_frame(img)
    assert line == f"{phrase(lamp)} {phrase(mug)}"
    assert [r.decision for r in results] == ["spoke", "spoke"]
    assert {r.line for r in results} == {phrase(lamp), phrase(mug)}
    assert all(r.tag == 10 for r in results)  # default tag


async def test_same_item_in_two_boxes_spoken_once():
    img, dets = scene(LAMP, ("green", "vase", (360, 200, 520, 360)))
    lamp = quote("brass lamp", 80)
    other = quote("Brass  Lamp", 80)
    fakes = Fakes(dets, {"red": 0.9, "green": 0.9}, {"red": lamp, "green": other})
    line, results = await build(fakes).process_frame(img)
    assert line in (phrase(lamp), phrase(other))  # whichever box ranks first; spoken once either way
    assert sorted((r.decision, r.reason) for r in results) == [
        ("quiet", "duplicate in frame"),
        ("spoke", "resale beats tag"),
    ]


async def test_recently_spoken_item_stays_quiet():
    img, dets = scene(LAMP)
    fakes = Fakes(dets, {"red": 0.9}, {"red": quote("brass lamp", 80)})
    pipeline = build(fakes)
    first, _ = await pipeline.process_frame(img)
    assert first
    line, results = await pipeline.process_frame(img)
    assert line == ""
    assert [(r.decision, r.reason) for r in results] == [("quiet", "spoken recently")]


async def test_one_crop_error_does_not_block_others():
    img, dets = scene(LAMP, MUG)
    lamp = quote("brass lamp", 80)
    fakes = Fakes(dets, {"red": 0.9, "blue": JevError("jev 500")}, {"red": lamp})
    line, results = await build(fakes).process_frame(img)
    assert line == phrase(lamp)
    by_label = {r.detection.label: r for r in results}
    assert by_label["vase"].decision == "spoke"
    assert by_label["cup"].decision == "error"
    assert "jev 500" in by_label["cup"].reason


async def test_gemini_error_does_not_block_others():
    img, dets = scene(LAMP, MUG)
    lamp = quote("brass lamp", 80)
    fakes = Fakes(dets, {"red": 0.9, "blue": 0.9}, {"red": lamp, "blue": ValueError("bad json")})
    line, results = await build(fakes).process_frame(img)
    assert line == phrase(lamp)
    by_label = {r.detection.label: r for r in results}
    assert by_label["cup"].decision == "error"
    assert by_label["cup"].jev == 0.9


async def test_cached_quote_skips_gemini():
    img, dets = scene(LAMP)
    fakes = Fakes(dets, {"red": 0.9}, {"red": quote("brass lamp", 80)})
    pipeline = build(fakes)
    await pipeline.process_frame(img)
    _, results = await pipeline.process_frame(img)
    assert fakes.gemini_calls == ["red"]
    assert results[0].quote.name == "brass lamp"


async def test_low_confidence_quote_stays_quiet():
    img, dets = scene(LAMP)
    fakes = Fakes(dets, {"red": 0.9}, {"red": quote("brass lamp", 80, confidence=0.4)})
    line, results = await build(fakes).process_frame(img)
    assert line == ""
    assert [(r.decision, r.reason) for r in results] == [("quiet", "low confidence")]


async def test_comps_override_price_and_tag():
    img, dets = scene(LAMP)
    comps = {"brass lamp": {"tag": 90, "low": 85, "high": 100, "sources": []}}
    fakes = Fakes(dets, {"red": 0.9}, {"red": quote("brass lamp", 200)})
    line, results = await build(fakes, comps=comps).process_frame(img)
    assert line == ""
    r = results[0]
    assert (r.tag, r.quote.low, r.quote.source) == (90, 85, "comps")
    assert r.reason == "resale does not beat tag"


async def test_only_five_boxes_processed():
    colors = list(PALETTE)
    items = [(c, f"obj{i}", (10 + 90 * i, 100, 10 + 90 * i + 40 + 5 * i, 300)) for i, c in enumerate(colors)]
    img, dets = scene(*items)
    fakes = Fakes(dets, {c: 0.1 for c in colors}, {})
    _, results = await build(fakes).process_frame(img)
    assert len(results) == 5
    assert len(fakes.jev_calls) == 5


async def test_default_settings_price_one_object_nearest_the_middle():
    assert load_settings({}).max_boxes == 1
    img, dets = scene(("red", "vase", (20, 20, 160, 160)), ("blue", "cup", (260, 180, 380, 300)),
                      ("green", "person", (200, 0, 440, 480)))
    fakes = Fakes(dets, {"blue": 0.1, "red": 0.1}, {})
    _, results = await build(fakes, max_boxes=1).process_frame(img)
    assert [r.detection.label for r in results] == ["cup"]


async def test_given_detection_skips_yolo():
    img, dets = scene(LAMP, MUG)
    fakes = Fakes([], {"red": 0.9}, {"red": quote("brass lamp", 80)})
    fakes.detect = lambda img: (_ for _ in ()).throw(AssertionError("YOLO should not run"))
    line, results = await build(fakes, max_boxes=1).process_frame(img, dets=[dets[0]])
    assert [r.detection.label for r in results] == ["vase"]
    assert line == phrase(quote("brass lamp", 80))
