# Detection Pipeline Design

Implementation plan: `docs/superpowers/plans/2026-10-24-detection-pipeline.md`. Setup steps: `docs/setup.md`.

## Flow

`/api/frame` → YOLO (`yolo11n`, up to 5 boxes, largest first) → crop each box (10% margin, sized to Jev's 280-1568 px limits) → one Jev `noul` question per crop ("could someone resell this?") → for crops at or above `JEV_THRESHOLD`, one search-grounded Gemini call for name, description and a used/sold price range → demo comps override on a name match → decide → one whisper joining every winner, biggest profit first → one judge-log row per object.

- **Decide:** speak only if Gemini confidence ≥ 0.6 and the low end of the range beats the tag price. Unknown items use a default tag of $10.
- **Silence:** a spoken item stays quiet for 30 s; two boxes naming the same item speak once.
- **Cache:** a repeat sighting (same YOLO label, near-identical 8x8 thumbnail) reuses the cached quote and skips Gemini.
- **Failures:** a Jev or Gemini failure on one crop logs that object as `error`; the others still run.
- **Fallbacks:**
  - If grounded calls refuse images, set `GEMINI_SEND_IMAGE=0`: a quick identify call without search names the item, and only the name goes to the grounded call.
  - If search and a JSON schema can't be combined, set `GEMINI_JSON_MODE=prompt`: the prompt asks for JSON and the backend validates it.
- **Cut order if behind:** skip the Gemini search and price from `comps.json` only.

## Unconfirmed

Fill these in from `docs/setup.md` sections 3-4 (#11), then copy the values into `backend/.env`.

| Question | Result | Env var |
| --- | --- | --- |
| Gemini model name the key offers | _TBD_ | `GEMINI_MODEL` (default `gemini-2.5-flash`) |
| Search + JSON schema work together? | _TBD (yes/no)_ | `GEMINI_JSON_MODE` = `schema` if yes, `prompt` if no (default `prompt`) |
| Grounded request accepts an image? | _TBD (yes/no)_ | `GEMINI_SEND_IMAGE` = `1` if yes, `0` if no (default `1`) |
| Jev score on a junk crop | _TBD_ | |
| Jev score on a good crop | _TBD_ | `JEV_THRESHOLD`: between the two (default `0.5`) |
