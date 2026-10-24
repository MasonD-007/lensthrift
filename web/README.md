# web

Static pages served by the Go backend. No build step.

- `index.html` + `capture.js`: phone page. Tap Start, rear camera runs, a center-cropped 640px JPEG is sent once the view holds steady for about a second. Speaks the reply; stays silent when `speak` is empty.
- `judge.html` + `judge.js`: laptop view of every decision.

## Backend contract

`POST /api/frame` (body: `image/jpeg`) returns:

```json
{ "speak": "Forty to sixty dollars. Vintage Pyrex bowl." }
```

`speak` is empty or missing when the item isn't worth a whisper.

`GET /api/log` returns an array, newest first:

```json
[{
  "ts": "2026-10-23T14:02:11Z",
  "item": "Pyrex mixing bowl", "maker": "Pyrex", "wear": "light",
  "tag": 5, "low": 40, "high": 60, "confidence": 0.82,
  "source": "comps",
  "sources": [{ "title": "eBay sold", "url": "https://..." }],
  "decision": "spoke",
  "reason": "resale beats tag",
  "line": "Forty to sixty dollars. Vintage Pyrex bowl."
}]
```

`decision` is `spoke` or `quiet`. `source` is `comps`, `search`, or `cache`.

## Run

The camera needs HTTPS. Serve `web/` from the backend, then tunnel:

```
ngrok http 8080    # or: cloudflared tunnel --url http://localhost:8080
```

Open the tunnel URL on the phone, set Auto-Lock to Never, tap Start. Open `/judge.html` on the laptop.
