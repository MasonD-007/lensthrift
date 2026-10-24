// Pick one object to scan and wait until it has been held steady for about 2 seconds.
// Works in the browser (window.Stabilize) and in Node for tests (module.exports).
(() => {
  const HOLD_MS = 2000;          // object must stay put this long before the frame is sent
  const MIN_IOU = 0.5;           // overlap with where the object was first seen; less means it moved
  const MAX_GAP_MS = 500;        // YOLO can miss a frame or two; longer than this means it left
  const SWITCH_MARGIN = 0.1;     // another object must score this much better to take over
  const MOVED_DIST = 0.35;       // same label this close to where it was: the object moved, not a new one
  const CENTER_WEIGHT = 0.6;     // "ideally in the middle"
  const SIZE_WEIGHT = 0.4;       // "closer wins": closer objects are bigger in the frame
  const IGNORE = new Set(['person']); // the hand and body holding the item

  // Boxes are [x1, y1, x2, y2], normalized 0-1 to the sent square.
  function score([x1, y1, x2, y2]) {
    const dist = Math.hypot((x1 + x2) / 2 - 0.5, (y1 + y2) / 2 - 0.5) / Math.SQRT1_2;
    const size = Math.sqrt(Math.max(0, x2 - x1) * Math.max(0, y2 - y1));
    return CENTER_WEIGHT * (1 - Math.min(1, dist)) + SIZE_WEIGHT * size;
  }

  function candidates(dets) {
    return dets.filter((d) => !IGNORE.has(d.label)).sort((a, b) => score(b.box) - score(a.box));
  }

  function pickTarget(dets) {
    return candidates(dets)[0] || null;
  }

  function iou(a, b) {
    const w = Math.min(a[2], b[2]) - Math.max(a[0], b[0]);
    const h = Math.min(a[3], b[3]) - Math.max(a[1], b[1]);
    if (w <= 0 || h <= 0) return 0;
    const inter = w * h;
    const area = (r) => (r[2] - r[0]) * (r[3] - r[1]);
    return inter / (area(a) + area(b) - inter);
  }

  const center = ([x1, y1, x2, y2]) => [(x1 + x2) / 2, (y1 + y2) / 2];
  const centerDist = (a, b) => Math.hypot(center(a)[0] - center(b)[0], center(a)[1] - center(b)[1]);

  function createStabilizer() {
    let track = null; // { anchor, target, since, lastSeen, sent }

    function update(dets, now) {
      const ranked = candidates(dets);
      const best = ranked[0] || null;
      const same = track && ranked.find((d) => iou(track.anchor, d.box) >= MIN_IOU);
      const moved = track && !same && ranked.find((d) =>
        d.label === track.target.label && centerDist(d.box, track.target.box) < MOVED_DIST);
      const start = (d) => { track = { anchor: d.box, target: d, since: now, lastSeen: now, sent: false }; };

      if (same && !(best !== same && score(best.box) - score(same.box) > SWITCH_MARGIN)) {
        track.target = same; // keep the newest box and label (YOLO labels flicker)
        track.lastSeen = now;
      } else if (moved) {
        start(moved);
      } else if (track && !same && now - track.lastSeen <= MAX_GAP_MS) {
        // brief miss: keep counting on the last box we saw
      } else if (best) {
        start(best);
      } else {
        track = null;
      }

      if (!track) return { phase: 'searching', target: null, progress: 0 };
      const progress = Math.min(1, (now - track.since) / HOLD_MS);
      const seen = track.lastSeen === now; // never send on a frame where the object wasn't detected
      const phase = track.sent ? 'sent' : progress >= 1 && seen ? 'stabilized' : 'stabilizing';
      return { phase, target: track.target, progress };
    }

    return {
      update,
      markSent() { if (track) track.sent = true; },
      reset() { track = null; },
    };
  }

  const api = { HOLD_MS, pickTarget, iou, score, createStabilizer };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else window.Stabilize = api;
})();
