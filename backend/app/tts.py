"""Server-side speech: macOS `say` renders a WAV the phone plays through an <audio> element.

iOS can mute speechSynthesis (silent switch, unlock quirks) but reliably plays a gesture-unlocked
<audio>, so the phone asks for the audio instead of synthesizing it.
"""
import asyncio
import tempfile
from collections import OrderedDict
from pathlib import Path

MAX_CHARS = 300
CACHE_SIZE = 64
WORDS_PER_MIN = 190

_cache: "OrderedDict[str, bytes]" = OrderedDict()


class TTSError(Exception):
    pass


async def synthesize(text: str) -> bytes:
    """WAV bytes for `text`; repeated phrases come from a small cache."""
    if text in _cache:
        _cache.move_to_end(text)
        return _cache[text]
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "speech.wav"
        try:
            proc = await asyncio.create_subprocess_exec(
                "say", "-r", str(WORDS_PER_MIN), "-o", str(out), "--data-format=LEI16@22050", "--", text,
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE,
            )
        except FileNotFoundError as e:
            raise TTSError("macOS `say` not found") from e
        _, err = await proc.communicate()
        if proc.returncode != 0 or not out.exists():
            raise TTSError(err.decode(errors="replace").strip() or "say failed")
        audio = out.read_bytes()
    _cache[text] = audio
    if len(_cache) > CACHE_SIZE:
        _cache.popitem(last=False)
    return audio
