# Detection Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the stubs in `/api/frame` with YOLO → crop → Jev → Gemini → decide → speak → log, handling every object in a frame.

**Architecture:** `/api/frame` calls `pipeline.process_frame`, which runs YOLO, crops up to 5 boxes, runs one Jev request per crop in parallel, then one Gemini grounded call per passing crop in parallel, decides per object, and returns one whisper line joining all winners ordered by profit. External clients (Jev, Gemini) sit behind small async functions so tests inject fakes.

**Tech Stack:** FastAPI, ultralytics (`yolo11n`), httpx (Jev multipart), `google-genai` (Gemini with `google_search`), Pillow, pytest + pytest-asyncio.

**Spec:** `docs/superpowers/specs/2026-10-24-detection-pipeline-design.md` (setup steps in `docs/setup.md`)

## Global Constraints

- Backend stays the FastAPI app in `backend/app/`; `/api/detect` (preview boxes) is unchanged.
- At most **5** boxes per frame, largest first.
- Jev image limits: each side **280 to 1568 px**, total pixels **78,400 to 2,458,624**; PNG or JPEG; header `TypeSafe-Danger-Zone-Images: true`; endpoint `POST https://api.typesafe.ai/v1/systemone`, model `jev-latest`, Bearer `TYPESAFE_API_KEY`.
- One Jev `noul` question per crop; crops below the Jev threshold stop and are logged `quiet`.
- Speak only if Gemini confidence >= **0.6** and the low end of the range beats the tag price.
- Whispers: price first, description second, ordered by profit, all winners in one reply. A spoken item stays silent for **30 s**.
- Keys come from env (`GEMINI_API_KEY`, `TYPESAFE_API_KEY`) loaded from `backend/.env`; never sent to the web pages.
- Cut order from Plan.md: if behind, skip the Gemini search and price from `comps.json` only.

## Review Focus

- A frame with zero YOLO detections returns `{"speak": ""}` and logs nothing, without error.
- One crop's Jev or Gemini call failing (timeout, 4xx, bad JSON) logs that object as `error` and still processes the others.
- Two boxes naming the same item in one frame produce one whisper.
- A crop smaller than 280 px a side is padded or upscaled instead of being rejected by Jev.
- A body that is not a decodable image returns HTTP 400, not a 500.

## File Structure

| File | Responsibility |
| --- | --- |
| `backend/app/config.py` | Env + constants (thresholds, limits, model names) |
| `backend/app/models.py` | Dataclasses passed between steps |
| `backend/app/crops.py` | Pick top boxes, cut and size crops |
| `backend/app/jev.py` | Jev client |
| `backend/app/gemini.py` | Gemini grounded price client |
| `backend/app/comps.py` + `backend/comps.json` | Demo comps override and tag prices |
| `backend/app/decide.py` | Decide rule and whisper phrasing |
| `backend/app/memory.py` | Per-item cache and 30 s cooldown |
| `backend/app/pipeline.py` | Orchestration |
| `backend/app/main.py` | Wiring, log, HTTP |
| `backend/tests/` | One test file per module |
| `web/judge.js`, `web/README.md` | Per-object log rows and schema |

---

### Task 0: Pre-flight checks (manual gate)

**Files:**
- Modify: `docs/superpowers/specs/2026-10-24-detection-pipeline-design.md` ("Unconfirmed" list)

- [ ] **Step 1:** Follow `docs/setup.md` sections 1-4: keys in `backend/.env`, AI Studio tests, one Jev call on a real crop.
- [ ] **Step 2:** Record in the spec: the Gemini model name; whether search + JSON schema work together (yes/no); whether a grounded request accepts an image (yes/no); the Jev scores for one junk and one good crop.
- [ ] **Step 3:** Set `GEMINI_MODEL`, `GEMINI_JSON_MODE` (`schema` or `prompt`), `GEMINI_SEND_IMAGE` (`1` or `0`), and `JEV_THRESHOLD` values from those results in `backend/.env`. Tasks 1 and 4 read them.
- [ ] **Step 4: Commit** the spec update.

### Task 1: Config, models and test setup

**Files:**
- Create: `backend/app/config.py`, `backend/app/models.py`, `backend/tests/conftest.py`, `backend/pytest.ini`
- Modify: `backend/requirements.txt` (add `httpx`, `google-genai`, `python-dotenv`, `pytest`, `pytest-asyncio`)
- Test: `backend/tests/test_config.py`

**Interfaces:**
- Produces: `config.settings` (frozen dataclass: `gemini_api_key`, `typesafe_api_key`, `gemini_model`, `gemini_json_mode: Literal["schema","prompt"]`, `gemini_send_image: bool`, `jev_threshold: float = 0.5`, `gemini_min_confidence: float = 0.6`, `max_boxes: int = 5`, `cooldown_s: float = 30`, `default_tag: float = 10`), `config.load_settings(env: Mapping) -> Settings`.
- Produces dataclasses in `models.py`: `Detection(label: str, conf: float, box: tuple[float,float,float,float])` (normalized xyxy), `Crop(detection: Detection, jpeg: bytes)`, `Quote(name: str, description: str, low: float, high: float, confidence: float, source: str, sources: list[dict])`, `ObjectResult(detection: Detection, jev: float | None, quote: Quote | None, tag: float | None, decision: Literal["spoke","quiet","error"], reason: str, line: str)`.

- [ ] **Step 1:** Test `test_load_settings_reads_env_and_defaults`: given `{"GEMINI_API_KEY":"g","TYPESAFE_API_KEY":"t"}`, assert `jev_threshold == 0.5`, `max_boxes == 5`, `gemini_json_mode == "prompt"`; given `JEV_THRESHOLD=0.7`, assert `0.7`.
- [ ] **Step 2:** Run `cd backend && .venv/bin/python -m pytest tests/test_config.py -v`; expect FAIL (module missing).
- [ ] **Step 3:** Implement `load_settings` and the dataclasses; `settings` loads `backend/.env` via `python-dotenv`. `pytest.ini` sets `asyncio_mode = auto`.
- [ ] **Step 4:** Run `make install` then the test; expect PASS.
- [ ] **Step 5: Commit** `feat: config and pipeline models`.

### Task 2: Crops

**Files:**
- Create: `backend/app/crops.py`
- Test: `backend/tests/test_crops.py`

**Interfaces:**
- Consumes: `Detection` (Task 1).
- Produces: `top_detections(dets: list[Detection], limit: int) -> list[Detection]` (largest box area first); `make_crop(img: PIL.Image.Image, det: Detection) -> bytes` (JPEG that satisfies the Jev limits).

- [ ] **Step 1:** Tests: `test_top_detections_keeps_largest_five` (7 boxes of increasing area, expect the 5 biggest in descending order); `test_make_crop_pads_small_box_to_280` (a 40x40 px box from a 640 frame returns a JPEG whose decoded size is at least 280x280); `test_make_crop_caps_at_1568` (a 3000x3000 source box returns a side <= 1568); `test_make_crop_total_pixels_in_range` (result area between 78,400 and 2,458,624).
- [ ] **Step 2:** Run the tests; expect FAIL.
- [ ] **Step 3:** Implement. Crop with a small context margin (10% each side, clamped to the frame), scale up (keeping aspect ratio) so the shorter side is at least 280, scale down so the longer side is at most 1568, then pad to satisfy the minimum side on the other axis. Output baseline JPEG at quality 90, RGB.
- [ ] **Step 4:** Run; expect PASS.
- [ ] **Step 5: Commit** `feat: crop selection and sizing for Jev`.

### Task 3: Jev client

**Files:**
- Create: `backend/app/jev.py`
- Test: `backend/tests/test_jev.py`

**Interfaces:**
- Produces: `async def resalable_score(jpeg: bytes, client: httpx.AsyncClient, api_key: str) -> float` returning the `noul` value (0-1); raises `JevError(Exception)` on non-2xx or a missing answer.

- [ ] **Step 1:** Tests using `httpx.MockTransport`: `test_sends_multipart_with_header_and_asset` (assert header `TypeSafe-Danger-Zone-Images: true`, `Authorization: Bearer k`, a `request` part with `model == "jev-latest"`, a question named `resalable` of type `noul`, and an image file part named by the asset's `part`); `test_returns_noul_value` (response `{"answers":{"resalable":{"type":"noul","noul":0.83}}}` gives `0.83`); `test_raises_jev_error_on_400`; `test_raises_jev_error_when_answer_missing`.
- [ ] **Step 2:** Run; expect FAIL.
- [ ] **Step 3:** Implement per the multipart format in the Jev Images docs: state `{"item": "<uuid>"}`, `assets` mapping the uuid to `{"type":"image","part":"item-photo"}`, question instructions exactly: "Is `item` a physical object someone could resell secondhand, not a person, a wall, a shelf or another fixture?". Per-request timeout 10 s.
- [ ] **Step 4:** Run; expect PASS.
- [ ] **Step 5: Commit** `feat: Jev resalable-score client`.

### Task 4: Gemini client

**Files:**
- Create: `backend/app/gemini.py`
- Test: `backend/tests/test_gemini.py`

**Interfaces:**
- Consumes: `Quote` (Task 1), `settings.gemini_json_mode`, `settings.gemini_send_image`.
- Produces: `async def price_item(jpeg: bytes, generate: Callable[..., Awaitable[GenResult]]) -> Quote` where `GenResult` has `.text: str` and `.citations: list[dict]` (`url`, `title`); `async def genai_generate(...)` is the real `google-genai` wrapper with the `google_search` tool, returning that shape. Raises `GeminiError` on unparseable output.

- [ ] **Step 1:** Tests with a fake `generate`: `test_parses_json_into_quote` (text `{"name":"milk glass mixing bowl","description":"white milk glass mixing bowl with a floral band","low":40,"high":60,"confidence":0.8}` gives that `Quote`, `sources` copied from citations, `source == "search"`); `test_extracts_json_from_code_fence`; `test_raises_gemini_error_on_non_json`; `test_prompt_asks_for_used_sold_prices` (the prompt passed to `generate` contains "sold" and "used").
- [ ] **Step 2:** Run; expect FAIL.
- [ ] **Step 3:** Implement the prompt (identify the item, name it with one distinguishing detail, give a used/sold resale range in USD, return only JSON with the fields above). When `gemini_send_image` is false, make a non-search identify call first and send only the name to the grounded call (the spec's fallback); in `schema` mode pass the response schema, in `prompt` mode parse and validate with Pydantic.
- [ ] **Step 4:** Run; expect PASS.
- [ ] **Step 5: Commit** `feat: Gemini grounded price client`.

### Task 5: Comps, decide and phrasing

**Files:**
- Create: `backend/app/comps.py`, `backend/comps.json`, `backend/app/decide.py`
- Test: `backend/tests/test_comps.py`, `backend/tests/test_decide.py`

**Interfaces:**
- Produces: `apply_comps(quote: Quote, comps: dict) -> Quote` (name match is a case-insensitive substring either way; overrides `low`, `high`, `sources`, sets `source="comps"`); `tag_for(name: str, comps: dict, default: float) -> float`; `decide(tag: float, quote: Quote, min_conf: float) -> tuple[bool, str]`; `phrase(quote: Quote) -> str` giving `"{low} to {high} dollars, {description}."`; `compose(winners: list[tuple[float, Quote]]) -> str` joining phrases ordered by profit (`quote.low - tag`) descending.

- [ ] **Step 1:** Tests: `test_apply_comps_overrides_on_name_match`; `test_apply_comps_leaves_unmatched_quote`; `test_decide_speaks_when_low_beats_tag`; `test_decide_quiet_below_confidence` (reason `"low confidence"`); `test_decide_quiet_when_not_beating_tag` (reason `"resale does not beat tag"`); `test_phrase_price_first` (`"40 to 60 dollars, white milk glass mixing bowl."`); `test_compose_orders_by_profit`.
- [ ] **Step 2:** Run; expect FAIL.
- [ ] **Step 3:** Implement. `comps.json` entries: `{"<item name>": {"tag": n, "low": n, "high": n, "sources": [{"title","url"}]}}`; seed with two placeholder items you replace with real sold comps (Task 9). Digits in `phrase` are a designer call; the speech engine reads them aloud.
- [ ] **Step 4:** Run; expect PASS.
- [ ] **Step 5: Commit** `feat: comps override, decide rule and whisper phrasing`.

### Task 6: Memory (cache and cooldown)

**Files:**
- Create: `backend/app/memory.py`
- Test: `backend/tests/test_memory.py`

**Interfaces:**
- Produces: `class Memory` with `__init__(cooldown_s: float, clock: Callable[[], float] = time.monotonic)`, `get_quote(name: str) -> Quote | None`, `put_quote(name: str, quote: Quote) -> None`, `recently_spoken(name: str) -> bool`, `mark_spoken(name: str) -> None`. Names are normalized (lowercase, collapsed whitespace).

- [ ] **Step 1:** Tests with a fake clock: `test_quote_roundtrip_is_case_insensitive`; `test_recently_spoken_true_within_cooldown`; `test_recently_spoken_false_after_cooldown` (advance 31 s).
- [ ] **Step 2:** Run; expect FAIL.
- [ ] **Step 3:** Implement with two dicts.
- [ ] **Step 4:** Run; expect PASS.
- [ ] **Step 5: Commit** `feat: item cache and spoken cooldown`.

### Task 7: Pipeline

**Files:**
- Create: `backend/app/pipeline.py`
- Test: `backend/tests/test_pipeline.py`

**Interfaces:**
- Consumes: Tasks 1-6.
- Produces: `class Pipeline` with `__init__(detect: Callable[[Image], list[Detection]], jev: Callable[[bytes], Awaitable[float]], gemini: Callable[[bytes], Awaitable[Quote]], comps: dict, memory: Memory, settings: Settings)` and `async def process_frame(self, img: PIL.Image.Image) -> tuple[str, list[ObjectResult]]` returning the combined whisper and one `ObjectResult` per kept box.

- [ ] **Step 1:** Tests with fakes (name each test after the behavior): `test_no_detections_returns_empty` (`("", [])`); `test_junk_stops_at_jev` (Jev 0.1 gives `quiet`, Gemini fake never called); `test_two_winners_whispered_in_profit_order` (two crops passing, both beat tag, line has both phrases, bigger profit first); `test_same_item_in_two_boxes_spoken_once`; `test_recently_spoken_item_stays_quiet` (second frame within cooldown gives quiet, reason `"spoken recently"`); `test_one_crop_error_does_not_block_others` (Jev raises `JevError` for one crop, the other still spoken, the failing one `decision == "error"`); `test_cached_quote_skips_gemini` (second frame reuses the cache, Gemini fake called once); `test_only_five_boxes_processed`.
- [ ] **Step 2:** Run; expect FAIL.
- [ ] **Step 3:** Implement with `asyncio.gather(..., return_exceptions=True)` for the Jev stage and the Gemini stage; apply comps, then decide; skip items in cooldown and duplicates by normalized name; mark spoken after composing.
- [ ] **Step 4:** Run; expect PASS.
- [ ] **Step 5: Commit** `feat: multi-object pipeline orchestration`.

### Task 8: Wire into FastAPI and the log

**Files:**
- Modify: `backend/app/main.py` (remove the stub `identify`/`price`/`tag_price`/`decide`/`say`)
- Test: `backend/tests/test_api.py`

**Interfaces:**
- Consumes: `Pipeline` (Task 7). Log rows: `{ts, label, yolo_conf, jev, item, description, tag, low, high, confidence, source, sources, decision, reason, line}`, one per object, newest first.

- [ ] **Step 1:** Tests with `TestClient` and a pipeline override: `test_frame_returns_speak_and_logs_each_object` (two objects give two log rows and `speak` equals the composed line); `test_non_image_body_returns_400`; `test_empty_frame_returns_empty_speak_and_no_log`.
- [ ] **Step 2:** Run; expect FAIL.
- [ ] **Step 3:** Build the real `Pipeline` at startup (real YOLO, `httpx.AsyncClient`, `genai_generate`, `comps.json`); `/api/frame` decodes with Pillow (400 on failure), calls `process_frame`, appends rows to the existing deque. Keep `/api/detect` and `/api/log`.
- [ ] **Step 4:** Run the full suite `cd backend && .venv/bin/python -m pytest -v`; expect PASS.
- [ ] **Step 5: Commit** `feat: wire pipeline into /api/frame`.

### Task 9: Judge UI and README schema

**Files:**
- Modify: `web/judge.js`, `web/judge.html`, `web/README.md`

- [ ] **Step 1:** Update the README log schema to the Task 8 row fields.
- [ ] **Step 2:** Update `judge.js` to render YOLO label + confidence, Jev score, item and description, price range, and decision/reason; `error` rows styled like `quiet`. Keep rendering with `textContent` only.
- [ ] **Step 3:** Verify: `node --check web/judge.js`; with `make run`, post a test JPEG to `/api/frame` and confirm rows appear at `/judge.html`.
- [ ] **Step 4: Commit** `feat: judge log shows each pipeline stage`.

### Task 10: Demo data and tuning (manual)

**Files:**
- Modify: `backend/comps.json`, `backend/.env`

- [ ] **Step 1:** Replace placeholders in `comps.json` with real sold comps and tag prices for your 5-6 demo items.
- [ ] **Step 2:** Walk the demo table with `make run`; set `JEV_THRESHOLD` so junk stops at Jev and both finds pass.
- [ ] **Step 3:** Run it three times in a row; time `/api/frame` and confirm replies arrive in about 3 s or less. If over, apply the cut order from Global Constraints.
- [ ] **Step 4: Commit** `chore: demo comps and tuned thresholds`.

---

## Self-Review

- **Spec coverage:** YOLO → crop (Task 2), Jev (3), Gemini incl. fallbacks (4), decide/phrase/profit order (5), dedupe and cooldown (6), parallel multi-object and 5-box cap (7), per-object log (8, 9), pre-flight unknowns (0), tuning and cut order (10).
- **Types:** `Quote`, `Detection`, `ObjectResult`, `Memory` signatures match across Tasks 1-8.
- **Calls made by the planner:** 10-second Jev timeout; digits instead of spelled-out numbers in whispers; unknown items use `default_tag` (10); cropping margin of 10%; `httpx` instead of the TypeSafe SDK.
