from app.decide import compose, decide, phrase


def test_decide_speaks_when_low_beats_tag(make_quote):
    assert decide(5, make_quote(low=40, confidence=0.8), 0.6) == (True, "resale beats tag")


def test_decide_quiet_below_confidence(make_quote):
    assert decide(5, make_quote(low=40, confidence=0.5), 0.6) == (False, "low confidence")


def test_decide_quiet_when_not_beating_tag(make_quote):
    assert decide(40, make_quote(low=40), 0.6) == (False, "resale does not beat tag")


def test_phrase_price_first(make_quote):
    q = make_quote(low=40.0, high=60.0, description="white milk glass mixing bowl")
    assert phrase(q) == "40 to 60 dollars, white milk glass mixing bowl."


def test_compose_orders_by_profit(make_quote):
    small = make_quote(name="mug", low=12, high=15, description="stoneware mug")
    big = make_quote(name="lamp", low=80, high=120, description="brass desk lamp")
    # mug profit 12 - 2 = 10; lamp profit 80 - 50 = 30
    assert compose([(2, small), (50, big)]) == (
        "80 to 120 dollars, brass desk lamp. 12 to 15 dollars, stoneware mug."
    )


def test_compose_empty_is_silent():
    assert compose([]) == ""
