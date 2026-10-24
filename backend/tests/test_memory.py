from app.memory import Memory


class FakeClock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def test_quote_roundtrip_is_case_insensitive(make_quote):
    m = Memory(30, FakeClock())
    q = make_quote(name="Milk Glass Bowl")
    m.put_quote("Milk  Glass Bowl", q)
    assert m.get_quote("milk glass   bowl") == q
    assert m.get_quote("pyrex") is None


def test_recently_spoken_true_within_cooldown():
    clock = FakeClock()
    m = Memory(30, clock)
    assert not m.recently_spoken("lamp")
    m.mark_spoken("Lamp")
    clock.t += 29
    assert m.recently_spoken(" lamp ")


def test_recently_spoken_false_after_cooldown():
    clock = FakeClock()
    m = Memory(30, clock)
    m.mark_spoken("lamp")
    clock.t += 31
    assert not m.recently_spoken("lamp")


def test_look_maps_similar_crop_to_name():
    m = Memory(30, FakeClock())
    look = bytes([100] * 192)
    m.remember_look("vase", look, "brass lamp")
    nearby = bytes([104] * 192)
    assert m.name_for_look("vase", nearby) == "brass lamp"


def test_look_ignores_other_label_and_different_crop():
    m = Memory(30, FakeClock())
    m.remember_look("vase", bytes([100] * 192), "brass lamp")
    assert m.name_for_look("cup", bytes([100] * 192)) is None
    assert m.name_for_look("vase", bytes([200] * 192)) is None


def test_memory_clear_forgets_quotes_cooldown_and_looks(make_quote):
    m = Memory(30, FakeClock())
    m.put_quote("lamp", make_quote(name="lamp"))
    m.mark_spoken("lamp")
    m.remember_look("vase", bytes([100] * 192), "lamp")
    m.clear()
    assert m.get_quote("lamp") is None
    assert not m.recently_spoken("lamp")
    assert m.name_for_look("vase", bytes([100] * 192)) is None
