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
# Detection pipeline design: YOLO → Jev → Gemini

## Intent

Thrift Lens whispers the resale value of items worth flipping and stays silent on junk. A steady frame can hold several objects, so each one is found, filtered and priced on its own. The wearer must be able to tell which object each whisper is about.

## Goals

- Check every object YOLO finds in a steady frame, not just the one nearest the center.
- Run Gemini (the expensive, search-grounded call) only on objects Jev judges to be resalable.
- Whisper every object whose resale value clearly beats its tag price, each with a short description of the object.
- Show every stage per object in the judge log, so judges can see why something stayed quiet.

## Non-goals

- Inventory mode, voice tag prices and glasses support (see Plan.md).
- Replacing YOLO with Jev's Box question or with SAM 3.
- Production accuracy. Jev's image support is documented as prototype-grade.

## Anti-goals

- Speaking about junk, people or fixtures. Silence on junk is the demo.
- A whisper the wearer can't tie to an object ("forty to sixty dollars" with no noun).
- A cluttered shelf pushing latency past about 3 seconds.

## Pipeline

1. **Frame.** The phone sends a steady, center-cropped 640px JPEG to `POST /api/frame` (existing behavior).
2. **YOLO.** `yolo11n` returns boxes for the frame.
3. **Crop.** Each box is cut from the frame. Jev rejects images with a side under 280px or over 1568px or under 78,400 total pixels, so crops are upscaled or padded to meet the minimum. Only the 5 largest boxes are kept per frame (a default chosen by the designer, not the user).
4. **Jev** (TypeSafe, `jev-latest`, `POST https://api.typesafe.ai/v1/systemone`). One request per crop, all in parallel. The state is the crop alone. One narrow `noul` question: whether the item is a physical thing someone could resell secondhand, not a person, a wall, or a fixture. Requests need the `TypeSafe-Danger-Zone-Images: true` header. Crops scoring below a threshold (tuned on the demo table) stop here and are logged as quiet.
5. **Gemini.** Each passing crop gets a search-grounded call, in parallel, that returns a short item name with one distinguishing detail, a sold-price range, confidence and sources. Demo comps override the price on a name match.
6. **Decide.** Per object: speak only if confidence clears the threshold and the low end of the range beats the tag price.
7. **Speak.** All objects that pass Decide are spoken, ordered by profit, one phrase each, price first and description second, e.g. "Forty to sixty dollars, milk glass mixing bowl. Twenty to thirty, brass candlestick." The description is what ties the price to the object.
8. **Log.** One row per object per frame: YOLO label and confidence, Jev score, Gemini result and sources, decision and reason.

## Gemini grounding (researched 2026-10-24)

Source: ai.google.dev/gemini-api/docs/google-search and the pricing page.

- **Search works through the API.** Add the `google_search` tool to the request. The model decides when to search. The response carries the queries it ran and `url_citation` annotations (`url`, `title`, text span), which feed the judge log's price sources.
- **Cost.** On Gemini 3 and newer, each search query is billed: the first 5,000 per month are free (shared across 3.x models), then $14 per 1,000. Older models (2.5 and earlier) bill per prompt. Token costs are extra. At one grounded call per new object, the free tier covers a hackathon.
- **Unconfirmed, must be tested before building on them:**
  1. Whether grounding can be combined with enforced JSON output (response schema). The docs page doesn't say. Fallback: ask for JSON in the prompt and validate it ourselves, or use two calls (search, then format).
  2. Whether a grounded request accepts an image input (the crop). The docs page doesn't say. Fallback: identify the crop with a non-search call first, then send only the text name to the grounded call.
  3. Which model names the API key can actually use. The docs list names such as "Gemini 3.8 Flash"; check what the key sees.
- The two-call structure (identify without search, then grounded price call) from Plan.md is the fallback for both 1 and 2, so the pipeline design holds either way.

## Dedupe

The cache is per object, keyed by item name once Gemini names it, so repeats skip the Gemini call. A YOLO box has no identity across frames, so Jev still runs on every crop; it is the cheap step. An item already spoken about stays silent for 30 seconds, per Plan.md.

## Constraints

- Backend is the existing FastAPI app in `backend/app/main.py`. `/api/detect` (preview boxes) already exists; `/api/frame` is where the pipeline lives, replacing the current stubs.
- API keys (`TYPESAFE_API_KEY`, Gemini) stay on the backend, read from the environment.
- Judge log schema in `web/README.md` gains per-object rows and Jev/YOLO fields.
- Cut order from Plan.md still applies: if behind, skip Gemini search and price from cached comps only.

## Left to the builder

Exact Jev question wording and threshold, Gemini prompt and JSON schema, the crop-padding method, the speech phrasing details, and the log schema additions.

## Open risks

- YOLO's COCO classes miss many thrift items, so some resalable objects never reach Jev. A fallback is to also send the whole frame to Jev, not decided here.
- Jev image accuracy is unproven on our items; test on the demo table first.
