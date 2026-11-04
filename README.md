# Thrift Lens

A hands-free pricing assistant for thrift-store resellers. A chest-mounted phone camera watches what you look at, and an earbud tells you what it's worth. It stays quiet on the junk and speaks up only when an item is worth flipping.

Built at the **cOmpiled-16 / UCSD hackathon** in San Diego, October 2026, for the No App track: the user never looks at a screen.

**[Watch the demo](https://www.youtube.com/watch?v=-nqxK2U75vo)**

## How it works

```
camera frame
   │
   ▼
YOLO11 ──► pick one object (nearest the middle, bigger wins, people ignored)
   │        wait until it holds steady
   ▼
crop ──► Jev: "could someone resell this?" ──► no ──► stay quiet
   │                                           yes
   ▼
seen it before? (perceptual cache) ──► yes ──► reuse the cached quote
   │ no
   ▼
Gemini + Google Search: name it, price it from used/sold listings
   │
   ▼
demo comps override on a name match
   │
   ▼
decide: confident, resale beats the tag, not spoken in the last 30 s?
   │
   ├── yes ──► whisper "40 to 60 dollars, white milk glass mixing bowl."
   └── no  ──► stay quiet, log the reason
```

- **Detect:** YOLO11 (`yolo11n`) finds objects in each frame. The client tracks the one nearest the center and sends it only once it has stayed put, so you price the lamp, not the shelf.
- **Filter:** each crop goes to [Jev](https://docs.typesafe.ai) (TypeSafe), which scores how likely it is to be something resalable. Walls, fixtures and other junk stop here, before any pricing call.
- **Price:** Gemini identifies the item and, with Google Search grounding, returns a used or sold price range with a confidence score and sources. Hand-collected comps in `backend/comps.json` override search for known demo items.
- **Decide:** the line is spoken only if confidence clears the threshold, the low end of the range beats the tag price, and the same item wasn't spoken in the last 30 seconds. Price comes first, item second.
- **Log:** every object gets a row (detection, Jev score, quote, decision, reason) shown on a judge view on a laptop, so the audience can see why it spoke or stayed quiet.

### Backend design notes

- **Concurrent, isolated AI calls.** Each object's Jev and Gemini calls run with `asyncio.gather(..., return_exceptions=True)`, so one failed or slow call is recorded as an `error` row for that object and the others still finish.
- **Perceptual cache.** Gemini only tells you an item's name after you pay for the call. To skip it on repeat sightings, the backend keeps an 8×8 thumbnail "look" of each priced crop under its YOLO label and matches new crops against it by mean pixel difference. A match reuses the cached quote, which cuts Gemini calls, latency and cost when you pick the same item up twice.
- **Contracts first.** The per-object request and response shapes (`/api/frame`, `/api/log`) were fixed at the start, so the web client, iOS client and backend were built against stubs in parallel. See [`web/README.md`](web/README.md#backend-contract).

## Repo layout

| Path | What's there |
| --- | --- |
| [`backend/`](backend/) | Python/FastAPI service: YOLO, crops, Jev and Gemini clients, cache, decision rule, judge log, server-side TTS |
| [`web/`](web/) | Static capture page (camera, stabilizer, speech), debug view, judge log and object feed. No build step. See [`web/README.md`](web/README.md) |
| [`mobile/ios/`](mobile/ios/) | Native iOS client. Runs YOLO on-device with Core ML and can run the whole pipeline on the phone, no laptop needed. See [`mobile/ios/README.md`](mobile/ios/README.md) |
| [`docs/`](docs/) | Setup guide and the detection pipeline design spec and plan |
| [`Plan.md`](Plan.md) | The original hackathon plan: pitch, demo rules, roles, timeline, risks |

## Run it

You need Python 3.12+, a Gemini API key and a TypeSafe API key. Full setup, including how to test the keys, is in [`docs/setup.md`](docs/setup.md).

```bash
cp backend/.env.example backend/.env   # add GEMINI_API_KEY and TYPESAFE_API_KEY
make install                           # venv + deps (pulls torch for ultralytics)
make run                               # http://localhost:8080
```

Open `http://localhost:8080` on the laptop, press **Start**, allow the camera, and press **D** for the debug view. `judge.html` is the standalone decision log for a second screen.

The phone camera needs HTTPS. Either run `make tunnel` (cloudflared, falls back to ngrok) and open the printed URL, or run `make dev-https` with a local mkcert certificate. For the native app, see [`mobile/ios/README.md`](mobile/ios/README.md).

| Variable | Default | Purpose |
| --- | --- | --- |
| `GEMINI_API_KEY` | | Identify and price calls |
| `TYPESAFE_API_KEY` | | Jev resalable filter |
| `GEMINI_MODEL` | `gemini-3.8-flash` | Must be a model your key can use |
| `GEMINI_JSON_MODE` | `prompt` | `schema` for structured output, `prompt` when search and schema can't be combined |
| `GEMINI_SEND_IMAGE` | `1` | `0` names the item with a quick call first and sends only the name to the grounded call |
| `JEV_THRESHOLD` | `0.5` | Minimum resalable score before pricing |

Keys stay in `backend/.env` on the server. The web pages never see them.

## Tests

```bash
make test   # backend pytest + web node --test
```

The backend has 87 pytest tests covering cropping and target ranking, the decision rule, the quote and look cache, comps matching, the Jev and Gemini clients (with fakes), the pipeline's error isolation, and the HTTP API. The web stabilizer has its own `node --test` suite.

## API

| Endpoint | Does |
| --- | --- |
| `POST /api/frame?box=x1,y1,x2,y2&label=cup&conf=0.84` | Price one object in a JPEG. Returns `{ "speak": "...", "objects": [...] }` |
| `POST /api/detect` | YOLO boxes for the preview overlay |
| `GET /api/log` | Decision log, newest first |
| `GET /api/seen` | Feed of detected objects for `objects.html` |
| `GET /api/tts?text=...` | Spoken line as WAV (macOS `say`), for iOS browsers that mute speech synthesis |
| `DELETE /api/log`, `DELETE /api/memory` | Clear the log, or forget cached quotes and cooldowns |

Field-by-field details are in [`web/README.md`](web/README.md#backend-contract).

## Team

Brandon Shin, Mason, and Asher Chok.
