from app.cache import ItemCache
from app.decide import decide, quote_for, tag_for

ITEMS = {
    "pyrex-bowl": {
        "keywords": {"pyrex", "bowl"},
        "tag": 5,
        "low": 40,
        "high": 60,
        "sources": [{"title": "eBay sold", "url": "https://example.com/1"}],
    },
}
PYREX = {"item": "Pyrex mixing bowl", "maker": "Pyrex", "wear": "light"}
LAMP = {"item": "Brass desk lamp", "maker": "", "wear": "worn"}
SEARCH_QUOTE = {
    "low": 20,
    "high": 30,
    "confidence": 0.7,
    "sources": [{"title": "search", "url": "https://example.com/2"}],
}


def fake_price(calls):
    def price(item):
        calls.append(item)
        return dict(SEARCH_QUOTE)
    return price


def quote(low=40, high=60, confidence=0.9):
    return {"low": low, "high": high, "confidence": confidence}


# quote_for


def test_comps_override_skips_search():
    calls = []
    key, q = quote_for(PYREX, fake_price(calls), ItemCache(), ITEMS)
    assert key == "pyrex-bowl"
    assert (q["low"], q["high"], q["source"]) == (40, 60, "comps")
    assert q["sources"] == ITEMS["pyrex-bowl"]["sources"]
    assert calls == []


def test_comps_quote_is_fully_confident():
    _, q = quote_for(PYREX, fake_price([]), ItemCache(), ITEMS)
    assert q["confidence"] == 1.0


def test_new_item_goes_to_search():
    calls = []
    _, q = quote_for(LAMP, fake_price(calls), ItemCache(), ITEMS)
    assert q["source"] == "search"
    assert q["low"] == 20
    assert calls == [LAMP]


def test_repeat_item_served_from_cache():
    calls, cache = [], ItemCache()
    quote_for(LAMP, fake_price(calls), cache, ITEMS)
    _, q = quote_for({"item": "brass desk lamp"}, fake_price(calls), cache, ITEMS)
    assert q["source"] == "cache"
    assert q["low"] == 20
    assert len(calls) == 1


def test_unidentified_item_is_unknown_without_search():
    calls = []
    key, q = quote_for({"item": ""}, fake_price(calls), ItemCache(), ITEMS)
    assert key == ""
    assert q["low"] is None
    assert calls == []


# tag_for


def test_tag_from_comps():
    assert tag_for(PYREX, ITEMS) == 5


def test_no_tag_for_non_demo_item():
    assert tag_for(LAMP, ITEMS) is None


# decide


def test_speaks_when_resale_clearly_beats_tag():
    assert decide("k", 5, quote(), ItemCache(), now=0) == (True, "resale beats tag")


def test_quiet_on_unknown_price():
    assert decide("k", 5, quote(low=None), ItemCache(), now=0) == (False, "unknown price")


def test_quiet_on_low_confidence():
    assert decide("k", 5, quote(confidence=0.5), ItemCache(), now=0) == (False, "low confidence")


def test_quiet_without_tag():
    assert decide("k", None, quote(), ItemCache(), now=0) == (False, "no tag price")


def test_quiet_when_profit_too_small():
    # 2x the tag, but only $10 of margin.
    assert decide("k", 10, quote(low=20), ItemCache(), now=0) == (False, "resale does not beat tag")


def test_quiet_when_multiple_too_small():
    # $20 of margin, but under 2x a $30 tag.
    assert decide("k", 30, quote(low=50), ItemCache(), now=0) == (False, "resale does not beat tag")


def test_quiet_on_repeat_within_window():
    cache = ItemCache()
    decide("k", 5, quote(), cache, now=0)
    assert decide("k", 5, quote(), cache, now=10) == (False, "said it already")


def test_speaks_again_after_window():
    cache = ItemCache()
    decide("k", 5, quote(), cache, now=0)
    assert decide("k", 5, quote(), cache, now=31) == (True, "resale beats tag")


def test_quiet_decision_does_not_start_repeat_window():
    cache = ItemCache()
    decide("k", 5, quote(confidence=0.1), cache, now=0)
    assert decide("k", 5, quote(), cache, now=1) == (True, "resale beats tag")
