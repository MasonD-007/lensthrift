import pytest

from app.models import Quote


@pytest.fixture
def make_quote():
    def make(name="milk glass mixing bowl", low=40, high=60, confidence=0.8, **kw):
        kw.setdefault("description", name)
        kw.setdefault("source", "search")
        kw.setdefault("sources", [])
        return Quote(name=name, low=low, high=high, confidence=confidence, **kw)

    return make
