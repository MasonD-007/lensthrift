# Thrift Lens: Hackathon Action Plan

Oct 23, 2026 · Mason

## Concept and pitch

Thrift Lens is a hands-free pricing assistant for resellers: a wearable camera watches what you look at and an earbud tells you what it's worth, with no screen in the loop. We enter the **No App** track.

**One-line pitch:** "It stays quiet on the junk and whispers when you've found something worth flipping."

| Mode | User | Behavior | Output |
| --- | --- | --- | --- |
| Hunt (hero demo) | Thrift, estate sale, and garage sale flippers | Silent by default; speaks only when an item's resale value clearly beats its tag price | Short whisper: price first, item second |
| Inventory | Small sellers, consignment, people clearing a garage | Logs everything it sees and confirms briefly | Priced item list, ready to turn into listings |

Both modes share one pipeline. Only the decide and speak steps differ. With a 5-hour build, Hunt mode is the deliverable and Inventory mode is a stretch goal; pitch it as the next step if it isn't built.

**Why it isn't just Google Lens:** Lens answers "what is this?" when you stop and point. Thrift Lens runs passively, prices against real sold comps, knows the tag price, and decides whether you should care. The value is the filtering, not the lookup.

## Demo setup and rules

Nobody on the team has Ray-Ban Metas, so a chest-mounted phone stands in for the glasses. The rule that keeps us in the track: **the user never looks at a screen.**

- **Camera:** phone in a chest mount, lanyard, or shirt pocket with the lens exposed. It sees roughly what the wearer sees.
- **Output:** earbuds only. Mirror the audio to room speakers on stage so judges hear it.
- **Input:** passive capture; voice tag prices are a stretch goal ("what's this worth?", "it's five bucks"). One tap on Start unlocks camera and audio; tag prices are hardcoded per demo item for the build.
- **Screen:** dimmed to minimum and facing inward. iOS stops the camera if the phone locks, so set Auto-Lock to Never.
- **Judge view:** a separate laptop showing a live log (item, comps, confidence, spoke or stayed quiet). It explains the system to judges and is not part of the user experience.
- **Glasses story:** "The same pipeline drops onto Ray-Ban Metas through Meta's Device Access Toolkit (camera in, audio out). There's no UI to port."

**The demo table:** 5 or 6 pre-picked items, mostly junk plus 2 genuine finds with clear sold comps. Put realistic tag prices on each. The audience should hear silence on the junk and a whisper on the finds.

## Architecture

A mobile web page posts JPEG frames to a Go backend, which calls Gemini and returns the line to speak. The API key stays on the backend; the phone does no thinking.

**Decision: browser, not a Swift app.** Capture runs as a web page in the phone's browser, so there's no Xcode, no app signing, and anyone's phone works. Streaming libraries like HaishinKit are unnecessary because the backend needs about one still frame per second, not continuous video.

| Piece | Runs on | Built with |
| --- | --- | --- |
| Camera capture | Phone browser | `getUserMedia` with `facingMode: "environment"`, video drawn to a canvas, downscaled JPEG around 640px |
| Frame upload | Phone browser | HTTP POST; next frame only after the previous reply returns |
| Speech | Phone browser | `speechSynthesis`, unlocked by one tap on Start |
| HTTPS | Laptop | ngrok or cloudflared tunnel (the camera won't open over plain HTTP on a LAN IP) |
| Backend | Laptop | Go service holding the Gemini API key, item cache, demo comps, decide logic, judge log |
| Identify and price | Google | Gemini API: identify without search, then search-grounded price for new items |

**Pipeline (shared by both modes; only Decide differs):**

1. **Capture:** phone web page over HTTPS sends a JPEG about once per second, only when the view is steady.
2. **Identify:** Gemini call without search returns structured JSON (name, maker, wear).
3. **Dedupe:** cache by item name so repeats answer fast.
4. **Price:** Gemini call with Google Search returns a range with sources; demo comps override on a name match.
5. **Decide:** Hunt mode speaks only if the price beats the tag; Inventory mode always logs.
6. **Speak:** browser speech, price first, or stay silent.
7. **Log:** judge laptop view, with price sources for every item.

Two Gemini calls keep it fast: a quick identify call without search on each steady frame, then a search-grounded price call only for items not already cached. Cached sold comps override search prices for demo items, and every price carries its sources into the judge log. Object detection is a stretch goal, not part of the core loop.

## Team roles

Four owners, one per seam in the pipeline. With three people, merge Demo into Pricing.

| Role | Owns | First deliverable | Owner |
| --- | --- | --- | --- |
| Capture and speech | Mobile web page: rear camera, frame upload, browser speech | Page on the phone, over HTTPS, posts a frame and speaks the reply | Asher |
| Gemini and dedupe | Gemini identify and search-grounded price calls, prompts, structured output, "seen this already" memory | Frame in, JSON item and price with sources out | |
| Cache and decision | Demo comps override, item cache, confidence, speak or stay quiet | Gemini JSON in, speak-or-silent decision out | Brandon |
| Backend and demo | Go service tying the steps together, judge log view, demo table, pitch | End-to-end stub with fake data flowing through every step | Mason |

Agree on the JSON contracts between steps in the first 10 minutes so everyone can build against stubs in parallel.

## Before the event

With only 5 hours, all of this must be done before the clock starts. If the rules allow it, pre-cache comps for the demo items in advance.

- [ ] Build the demo comps cache: real sold prices for each demo item, used to override search prices.
- [ ] Test Gemini in AI Studio: a thrift photo with Google Search on returns a grounded price with sources, and JSON output works with search enabled. (Team note: SAM 3, https://github.com/facebookresearch/sam3)
- [ ] Confirm browser speech plays on iOS after one tap of a Start button; measure round-trip latency on a hotspot.
- [ ] Capture is a mobile web page: set up an HTTPS tunnel (ngrok or cloudflared) and confirm the camera opens on the phone.
- [ ] Buy or borrow a chest or head mount and a pair of earbuds.
- [ ] Buy the demo items: 5 or 6 cheap thrift pieces, including 2 with strong resale value.
- [ ] Write the JSON contracts between pipeline steps.
- [ ] Confirm the hackathon's rules on pre-built code, API keys, and pre-cached data.

## Timeline (5 hours)

Four hours of building, one hour of demo prep. To fit, **Gemini with Google Search prices items, and pre-cached sold comps override it for demo items**. A working loop on 5 items beats a half-built general system.

**0:00 to 0:30: Wire it up**

- [ ] Lock the JSON contracts between steps (10 minutes, no longer)
- [ ] Go backend with stubbed steps returning fake data
- [ ] Phone web page posts a frame over the HTTPS tunnel; browser speech plays the reply
- Check: a fake item flows from frame to spoken audio

**0:30 to 2:00: Real identify and price**

- [ ] Gemini identify call (no search) returns structured JSON for each demo item
- [ ] Search-grounded Gemini call returns a price range with sources; demo comps override on a name match
- [ ] Speak the price, price first
- Check: point at one demo item, hear a real price

**2:00 to 3:00: Hunt mode**

- [ ] Steady-frame sampling, about 1 frame per second
- [ ] Cache by item name: repeats answer instantly, and the same item within 30 seconds stays silent
- [ ] Hardcode tag prices per demo item; voice input is a stretch goal
- [ ] Speak or stay quiet rule plus a confidence threshold
- [ ] Judge log: a plain web page or terminal tailing the decisions
- Check: walk the demo table, silence on junk, whisper on finds

**3:00 to 4:00: Harden**

- [ ] Run the full demo three times; fix whatever breaks
- [ ] Trim latency: smaller frames, shorter phrases
- [ ] Record a backup video on the first clean run
- Check: three clean runs in a row

**4:00 to 5:00: Code freeze and pitch**

- [ ] No new features after 4:00
- [ ] Rehearse the pitch at least three times with the live demo

**Stretch, only if ahead of schedule:** Inventory mode, voice tag prices, dwell batching (several frames when the wearer picks an item up), on-device object detection.

**Cut order if behind:** skip the search call and price from cached comps only, then make the judge log plain terminal output. Never cut the silence-on-junk behavior; it is the demo.

## Risks and fallbacks

| Risk | Why it hurts | Fallback |
| --- | --- | --- |
| Search prices skew to retail and asking prices | Numbers run high, and resellers in the audience will notice | Prompt for used or sold prices; demo comps override; show sources in the judge log |
| Gemini returns a confident but wrong price | Undercuts the core claim | Require search-grounded prices with sources; return "unknown" below a confidence threshold |
| Latency over about 3 seconds | Wearer has already walked past the item | Identify without search first; search only new items; cache by item name; short phrases |
| Venue Wi-Fi is bad | Whole pipeline stalls on stage | Phone hotspot, local cache, recorded backup video |
| Wrong item in frame | Prices the shelf, not the lamp | Center-crop frames; only act after the view holds steady for about a second |
| Judges say "that's a phone app" | Disqualifies the track fit | Screen off, mounted phone, glasses-ready framing in the first 30 seconds |

## Pitch and judge Q&A

Aim for a 3-minute pitch with the live demo in the middle, not the end.

1. **Problem (30s):** Resellers scan hundreds of items per sale to find the few worth buying. Phones slow them down and they miss things.
2. **Live demo (90s):** Wearer walks the demo table. Silence, silence, whisper. Judge log on the laptop shows why.
3. **Inventory mode (20s):** If built, show the priced list. If not, one sentence: the same pipeline logs everything for sellers pricing inventory.
4. **How it works (20s):** Camera in, Gemini identifies, search-grounded price with sources, decide, audio out. No screen anywhere.
5. **Where it goes (20s):** Ray-Ban Metas via Meta's toolkit; the same loop serves any seller pricing physical inventory.

**Questions to prepare for**

- How is this different from Google Lens? *Passive, filtered, tag-aware, and grounded in sold prices.*
- How accurate are the prices? *Have one honest number from testing, and show the confidence logic.*
- What happens when it doesn't know? *It says so, or stays quiet. Demo this on purpose.*
- Why isn't the phone a screen? *The user never looks at it; it's a camera and a compute box.*
- What does it cost to run per hour? *Rough per-frame model cost times frames sampled.*
