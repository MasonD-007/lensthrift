from app.cache import ItemCache


def test_get_missing_returns_none():
    assert ItemCache().get("lamp") is None


def test_put_then_get_returns_quote():
    c = ItemCache()
    c.put("lamp", {"low": 10})
    assert c.get("lamp") == {"low": 10}


def test_not_spoken_until_marked():
    assert not ItemCache().spoke_recently("lamp", now=100)


def test_spoke_recently_inside_window():
    c = ItemCache()
    c.mark_spoken("lamp", now=100)
    assert c.spoke_recently("lamp", now=129, window=30)


def test_not_spoke_recently_after_window():
    c = ItemCache()
    c.mark_spoken("lamp", now=100)
    assert not c.spoke_recently("lamp", now=131, window=30)
