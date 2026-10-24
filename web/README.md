# web

Static pages served by the FastAPI backend. No build step.

- `index.html` + `capture.js` + `stabilize.js`: the main page, run locally on the laptop at `http://localhost:8080`. Press Start. YOLO tracks what's in view and picks **one** object: the one nearest the middle, with closer (bigger) objects winning ties. People are ignored, since the hand and body holding the item would always be the biggest box. When that object has stayed put for **2 seconds**, the frame and its box go to `/api/frame`, and only that object is priced. The reply is spoken and shown as a caption.
  - The badge on the camera shows each stage: **Searching**, then **Stabilizing cup 45%** (amber, filling with the countdown bar on the box), then **Stabilized: cup · pricing…**, then **Stabilized: cup · sent** (green). The result box then replaces the target box.
  - A held item is sent once. It's scanned again when it leaves and comes back, or when a different object takes the middle. Moving it restarts the countdown, and a missed YOLO frame (under 0.5 s) doesn't.
- **Debug view** (the Debug button, or **D**; remembered per browser, and `?debug=1` / `?debug=0` override it):
  - every YOLO box (blue), plus the phase, target, hold time, round-trip time and counters
  - controls: Send now, Mute, Replay, Reset memory, and a camera picker
  - the decision log beside the camera
- Keys: **D** debug, **Space** send now, **M** mute, **R** replay.
- `log.js`: the decision log view (filters, pause, clear), used by the debug panel and by `judge.html`, a standalone copy for a second window.

## Backend contract

`POST /api/frame?box=x1,y1,x2,y2&label=cup&conf=0.84` (body: `image/jpeg`) prices just that box (normalized 0-1 to the sent square). Without `box`, the backend runs YOLO itself and keeps the single best object by the same rule. It returns:

```json
{ "speak": "40 to 60 dollars, white milk glass mixing bowl.", "objects": [ /* one log row per object, as below */ ] }
```

`speak` joins every item worth a whisper in the frame, biggest profit first, and is empty when nothing is. A body that isn't an image returns `400`; missing API keys return `503`.

`GET /api/log` returns an array with one row per detected object (up to 5 per frame), newest first:

```json
[{
  "ts": "2026-10-24T14:02:11+00:00",
  "label": "bowl", "yolo_conf": 0.71, "box": [0.31, 0.22, 0.68, 0.71],
  "jev": 0.93,
  "item": "milk glass mixing bowl", "description": "white milk glass mixing bowl",
  "tag": 5, "low": 40, "high": 60, "confidence": 0.82,
  "source": "comps",
  "sources": [{ "title": "eBay sold", "url": "https://..." }],
  "decision": "spoke",
  "reason": "resale beats tag",
  "line": "40 to 60 dollars, white milk glass mixing bowl."
}]
```

- `label`, `yolo_conf`, `box`: the YOLO box (normalized xyxy, 0-1 of the sent square). `jev`: Jev's resalable probability (`null` if the Jev call failed).
- `item` through `sources` are `null` (or `[]`) when the object stopped before pricing: junk at Jev, or an error.
- `decision` is `spoke`, `quiet`, or `error`. `source` is `search` or `comps`.
- `reason` is one of `resale beats tag`, `not resalable`, `low confidence`, `resale does not beat tag`, `spoken recently`, `duplicate in frame`, or `jev error: ...` / `gemini error: ...`.

`DELETE /api/log` empties the log. `DELETE /api/memory` forgets cached quotes and the 30 s spoken cooldown, so an item can be re-tested right away. Both return `204`.

## Run

```
make run    # then open http://localhost:8080
```

Press Start, allow the camera, and press **D** for the debug view.
