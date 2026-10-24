# Setup: accounts, keys and local environment

What you need before the pipeline can run end to end. Tick these off in order.

## 1. Accounts and keys

| What | Where | Why | Env var |
| --- | --- | --- | --- |
| Gemini API key | https://aistudio.google.com/apikey (sign in with a Google account, "Create API key") | Identify and search-grounded price calls | `GEMINI_API_KEY` |
| TypeSafe API key | TypeSafe console (linked from https://docs.typesafe.ai) | Jev filter calls | `TYPESAFE_API_KEY` |
| Hugging Face token | https://huggingface.co/settings/tokens | Only for SAM 3, which we dropped for YOLO. Skip. | none |

Notes:
- AI Studio is Google's web playground, not something installed locally. The "local" part is your backend calling the same API with the same key.
- Free tier is enough to start. Grounding with Google Search gives 5,000 free queries a month on Gemini 3+ models, then $14 per 1,000. If your key hits rate limits, enable billing on the project.
- Jev image input needs the request header `TypeSafe-Danger-Zone-Images: true`. The backend sets it; you don't.

## 2. Put the keys in `.env`

Create `backend/.env` (already gitignored via `.env`):

```
GEMINI_API_KEY=...
TYPESAFE_API_KEY=...
```

Never paste keys into the web pages or commit them. The phone never sees them.

## 3. Test Gemini in AI Studio before writing code

Go to https://aistudio.google.com, open a new chat prompt, and check each of these with one of your thrift photos:

1. Pick the model your key lists (the docs name Gemini 3.x Flash models; use whatever the dropdown offers). Write that name down: it goes in the backend config.
2. Turn on the "Grounding with Google Search" tool. Upload a photo of an item. Ask for a used or sold price range with sources. Confirm sources appear.
3. With search on, also turn on structured output (JSON mode with a schema). Record whether AI Studio lets you enable both together. If it refuses, we use the fallback in the spec.
4. Check the price is a used or sold price, not retail. If it skews high, note the prompt wording that fixed it.
5. Click "Get code" and save the Python snippet. It shows the exact tool config your key accepts.

Write the results into the spec's "Unconfirmed" list.

## 4. Test Jev on a crop

Take one real crop (about 300 to 600 px a side, JPEG or PNG) and send it with the multipart curl example from https://docs.typesafe.ai (the Images page), asking a `noul` question such as "Is this a physical item someone could resell secondhand?". Run it on one junk item and one good item and note the two scores. They set the threshold.

## 5. Local environment

```
make install        # venv, fastapi, ultralytics (large: pulls torch)
make run            # http://localhost:8080
```

- Python 3.12+ and a webcam. The M2 runs YOLO on CPU or MPS fine.
- First start downloads `yolo11n.pt`.
- Camera works on `http://localhost:8080` on the laptop. For the phone you need HTTPS: `brew install cloudflared`, then `make tunnel` (or use ngrok), and open the printed `https://` URL on the phone.
- On the phone: Auto-Lock to Never, earbuds in, tap Start once.

## 6. Demo prep (from Plan.md)

- Real sold comps for each demo item in a comps file.
- 5 or 6 demo items with hardcoded tag prices.
- Phone mount and earbuds.

## Checklist

- [ ] Gemini key works in AI Studio with search on
- [ ] Search plus JSON output tested, result recorded
- [ ] Search plus image input tested, result recorded
- [ ] Model name recorded
- [ ] TypeSafe key works on one crop
- [ ] Jev threshold candidates recorded
- [ ] `backend/.env` created
- [ ] `make run` works on the laptop webcam
- [ ] Tunnel works on the phone
