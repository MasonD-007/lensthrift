# web

Static pages served by the FastAPI backend. No build step.

- `index.html` + `capture.js`: phone page. Tap Start, rear camera runs, a center-cropped 640px JPEG is sent once the view holds steady for about a second. Speaks the reply; stays silent when `speak` is empty.
- `judge.html` + `judge.js`: laptop view of every decision.

## Backend contract

`POST /api/frame` (body: `image/jpeg`) returns:

```json
{ "speak": "40 to 60 dollars, white milk glass mixing bowl. 25 to 35 dollars, milk glass vase." }
```

`speak` joins every item worth a whisper in the frame, biggest profit first, and is empty when nothing is. A body that isn't an image returns `400`; missing API keys return `503`.

`GET /api/log` returns an array with one row per detected object (up to 5 per frame), newest first:

```json
[{
  "ts": "2026-10-24T14:02:11+00:00",
  "label": "bowl", "yolo_conf": 0.71,
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

- `label`, `yolo_conf`: the YOLO box. `jev`: Jev's resalable probability (`null` if the Jev call failed).
- `item` through `sources` are `null` (or `[]`) when the object stopped before pricing: junk at Jev, or an error.
- `decision` is `spoke`, `quiet`, or `error`. `source` is `search` or `comps`.
- `reason` is one of `resale beats tag`, `not resalable`, `low confidence`, `resale does not beat tag`, `spoken recently`, `duplicate in frame`, or `jev error: ...` / `gemini error: ...`.

## Run

The camera needs HTTPS. Serve `web/` from the backend, then tunnel:

```
ngrok http 8080    # or: cloudflared tunnel --url http://localhost:8080
```

Open the tunnel URL on the phone, set Auto-Lock to Never, tap Start. Open `/judge.html` on the laptop.
