from app.config import load_settings


def test_load_settings_reads_env_and_defaults():
    s = load_settings({"GEMINI_API_KEY": "g", "TYPESAFE_API_KEY": "t"})
    assert s.gemini_api_key == "g"
    assert s.typesafe_api_key == "t"
    assert s.jev_threshold == 0.5
    assert s.max_boxes == 1
    assert s.gemini_json_mode == "prompt"

    s = load_settings({"GEMINI_API_KEY": "g", "TYPESAFE_API_KEY": "t", "JEV_THRESHOLD": "0.7"})
    assert s.jev_threshold == 0.7


def test_load_settings_parses_gemini_flags():
    s = load_settings({"GEMINI_JSON_MODE": "schema", "GEMINI_SEND_IMAGE": "0", "GEMINI_MODEL": "m"})
    assert s.gemini_json_mode == "schema"
    assert s.gemini_send_image is False
    assert s.gemini_model == "m"
