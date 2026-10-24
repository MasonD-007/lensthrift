from app.comps import item_key, match

ITEMS = {
    "pyrex-butterprint": {
        "keywords": {"pyrex", "bowl"},
        "tag": 5,
        "low": 40,
        "high": 60,
        "sources": [{"title": "eBay sold", "url": "https://example.com/1"}],
    },
    "pyrex-butterprint-lid": {
        "keywords": {"pyrex", "bowl", "lid"},
        "tag": 8,
        "low": 55,
        "high": 70,
        "sources": [],
    },
    "mug": {"keywords": {"mug"}, "tag": 2, "low": 1, "high": 3, "sources": []},
}


def test_matches_when_all_keywords_in_name():
    assert match({"item": "Pyrex mixing bowl"}, ITEMS) == "pyrex-butterprint"


def test_match_ignores_case_and_punctuation():
    assert match({"item": "PYREX, Mixing-Bowl!"}, ITEMS) == "pyrex-butterprint"


def test_match_uses_maker_field():
    assert match({"item": "Mixing bowl", "maker": "Pyrex"}, ITEMS) == "pyrex-butterprint"


def test_match_prefers_most_specific_entry():
    assert match({"item": "Pyrex bowl with lid"}, ITEMS) == "pyrex-butterprint-lid"


def test_no_match_when_a_keyword_is_missing():
    assert match({"item": "Glass mixing bowl"}, ITEMS) is None


def test_no_match_for_empty_name():
    assert match({"item": ""}, ITEMS) is None


def test_item_key_uses_comps_id_on_match():
    assert item_key({"item": "vintage Pyrex bowl"}, ITEMS) == "pyrex-butterprint"


def test_item_key_collapses_name_variants():
    a = item_key({"item": "Vintage brass candle holder"}, ITEMS)
    b = item_key({"item": "brass candle holder, vintage"}, ITEMS)
    assert a == b


def test_item_key_empty_for_unknown_item():
    assert item_key({"item": "unknown"}, ITEMS) == ""
