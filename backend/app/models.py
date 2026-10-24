"""Dataclasses passed between pipeline steps."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal, Optional, Tuple


@dataclass(frozen=True)
class Detection:
    label: str
    conf: float
    box: Tuple[float, float, float, float]  # normalized xyxy, 0-1 of the frame


@dataclass(frozen=True)
class Crop:
    detection: Detection
    jpeg: bytes


@dataclass(frozen=True)
class Quote:
    name: str
    description: str
    low: float
    high: float
    confidence: float
    source: str  # "search" or "comps"
    sources: list = field(default_factory=list)  # [{"title", "url"}]


@dataclass(frozen=True)
class ObjectResult:
    detection: Detection
    jev: Optional[float]
    quote: Optional[Quote]
    tag: Optional[float]
    decision: Literal["spoke", "quiet", "error"]
    reason: str
    line: str
