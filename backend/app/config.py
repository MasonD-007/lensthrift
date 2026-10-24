"""Env + constants for the detection pipeline. Keys load from backend/.env and stay server-side."""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Mapping

from dotenv import dotenv_values

ENV_FILE = Path(__file__).resolve().parents[1] / ".env"


@dataclass(frozen=True)
class Settings:
    gemini_api_key: str
    typesafe_api_key: str
    gemini_model: str
    gemini_json_mode: Literal["schema", "prompt"]
    gemini_send_image: bool
    jev_threshold: float = 0.5
    gemini_min_confidence: float = 0.6
    max_boxes: int = 5
    cooldown_s: float = 30
    default_tag: float = 10


def load_settings(env: Mapping[str, str | None]) -> Settings:
    def get(key: str, default: str) -> str:
        return env.get(key) or default

    json_mode = get("GEMINI_JSON_MODE", "prompt")
    if json_mode not in ("schema", "prompt"):
        raise ValueError(f"GEMINI_JSON_MODE must be 'schema' or 'prompt', got {json_mode!r}")
    return Settings(
        gemini_api_key=get("GEMINI_API_KEY", ""),
        typesafe_api_key=get("TYPESAFE_API_KEY", ""),
        gemini_model=get("GEMINI_MODEL", "gemini-2.5-flash"),
        gemini_json_mode=json_mode,
        gemini_send_image=get("GEMINI_SEND_IMAGE", "1") not in ("0", "false", "False"),
        jev_threshold=float(get("JEV_THRESHOLD", "0.5")),
    )


# Process env wins over backend/.env.
settings = load_settings({**dotenv_values(ENV_FILE), **os.environ})
