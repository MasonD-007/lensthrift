import io

import pytest
from PIL import Image

from app.crops import look, make_crop, top_detections
from app.models import Detection


def frame(w, h):
    return Image.new("RGB", (w, h), (200, 120, 40))


def decoded_size(jpeg):
    img = Image.open(io.BytesIO(jpeg))
    assert img.format == "JPEG"
    return img.size


def det_px(x0, y0, x1, y1, w, h):
    return Detection("cup", 0.9, (x0 / w, y0 / h, x1 / w, y1 / h))


def test_top_detections_keeps_largest_five():
    dets = [Detection(f"d{i}", 0.5, (0, 0, 0.1 * i, 0.1 * i)) for i in range(1, 8)]
    top = top_detections(dets, 5)
    assert [d.label for d in top] == ["d7", "d6", "d5", "d4", "d3"]


def test_make_crop_pads_small_box_to_280():
    w, h = decoded_size(make_crop(frame(640, 480), det_px(300, 200, 340, 240, 640, 480)))
    assert w >= 280 and h >= 280


def test_make_crop_caps_at_1568():
    w, h = decoded_size(make_crop(frame(3200, 3200), det_px(100, 100, 3100, 3100, 3200, 3200)))
    assert max(w, h) <= 1568


@pytest.mark.parametrize(
    "size,box",
    [
        ((640, 480), (300, 200, 340, 240)),  # tiny
        ((3200, 3200), (100, 100, 3100, 3100)),  # huge
        ((640, 640), (310, 0, 330, 640)),  # tall sliver
        ((4000, 300), (0, 140, 4000, 160)),  # wide sliver
    ],
)
def test_make_crop_total_pixels_in_range(size, box):
    w, h = decoded_size(make_crop(frame(*size), det_px(*box, *size)))
    assert 280 <= w <= 1568 and 280 <= h <= 1568
    assert 78_400 <= w * h <= 2_458_624


def test_look_is_small_thumbnail_that_tracks_color():
    det = det_px(100, 100, 300, 300, 640, 480)
    red = look(frame(640, 480), det)
    blue = look(Image.new("RGB", (640, 480), (30, 30, 220)), det)
    assert len(red) == 8 * 8 * 3
    assert red == look(frame(640, 480), det)
    assert red != blue
