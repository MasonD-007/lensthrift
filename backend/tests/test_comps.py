from app.comps import apply_comps, load_comps, tag_for

COMPS = {
    "Pyrex Mixing Bowl": {
        "tag": 5,
        "low": 35,
        "high": 55,
        "sources": [{"title": "eBay sold", "url": "https://example.com/pyrex"}],
    }
}


def test_apply_comps_overrides_on_name_match(make_quote):
    q = apply_comps(make_quote(name="vintage pyrex mixing bowl, turquoise", low=10, high=20), COMPS)
    assert (q.low, q.high) == (35, 55)
    assert q.source == "comps"
    assert q.sources == COMPS["Pyrex Mixing Bowl"]["sources"]
    assert q.name == "vintage pyrex mixing bowl, turquoise"


def test_apply_comps_matches_when_quote_name_is_shorter(make_quote):
    q = apply_comps(make_quote(name="pyrex"), COMPS)
    assert q.source == "comps"


def test_apply_comps_leaves_unmatched_quote(make_quote):
    original = make_quote(name="cast iron skillet")
    assert apply_comps(original, COMPS) == original


def test_tag_for_uses_comps_then_default():
    assert tag_for("PYREX mixing bowl", COMPS, 10) == 5
    assert tag_for("cast iron skillet", COMPS, 10) == 10


def test_load_comps_reads_seed_file():
    comps = load_comps()
    assert comps
    for entry in comps.values():
        assert {"tag", "low", "high", "sources"} <= entry.keys()
