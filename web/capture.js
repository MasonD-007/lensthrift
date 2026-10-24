// Capture page: rear camera -> steady-frame check -> POST JPEG -> speak the reply.
// The phone does no thinking; the Go backend holds the Gemini key and decides.
(() => {
  const FRAME_PX = 640;          // downscaled JPEG edge
  const JPEG_QUALITY = 0.7;
  const TICK_MS = 250;           // steady-check cadence
  const STEADY_MS = 1000;        // view must hold this long before we send
  const STEADY_DIFF = 6;         // mean abs luma diff (0-255) under which we call it steady
  const SAMPLE = 32;             // tiny grayscale grid for motion compare

  const video = document.getElementById('video');
  const canvas = document.getElementById('canvas');
  const startBtn = document.getElementById('start');
  const statusEl = document.getElementById('status');
  const small = document.createElement('canvas');
  small.width = small.height = SAMPLE;

  let prev = null;
  let steadySince = 0;
  let inFlight = false;
  let sentForThisHold = false;

  const setStatus = (msg) => { statusEl.textContent = msg; };

  function speak(text) {
    if (!text) return;
    speechSynthesis.cancel();
    const u = new SpeechSynthesisUtterance(text);
    u.rate = 1.1;
    speechSynthesis.speak(u);
  }

  // iOS only allows speech after a user gesture; a silent utterance on Start unlocks it.
  function unlockSpeech() {
    const u = new SpeechSynthesisUtterance(' ');
    u.volume = 0;
    speechSynthesis.speak(u);
  }

  // Center-crop to a square so we price what's in the middle, not the shelf.
  function squareCrop(w, h) {
    const s = Math.min(w, h);
    return { sx: (w - s) / 2, sy: (h - s) / 2, s };
  }

  function lumaGrid() {
    const { sx, sy, s } = squareCrop(video.videoWidth, video.videoHeight);
    const ctx = small.getContext('2d', { willReadFrequently: true });
    ctx.drawImage(video, sx, sy, s, s, 0, 0, SAMPLE, SAMPLE);
    const d = ctx.getImageData(0, 0, SAMPLE, SAMPLE).data;
    const out = new Uint8Array(SAMPLE * SAMPLE);
    for (let i = 0; i < out.length; i++) {
      out[i] = (d[i * 4] * 77 + d[i * 4 + 1] * 150 + d[i * 4 + 2] * 29) >> 8;
    }
    return out;
  }

  function meanDiff(a, b) {
    let sum = 0;
    for (let i = 0; i < a.length; i++) sum += Math.abs(a[i] - b[i]);
    return sum / a.length;
  }

  function frameBlob() {
    const { sx, sy, s } = squareCrop(video.videoWidth, video.videoHeight);
    canvas.width = canvas.height = FRAME_PX;
    canvas.getContext('2d').drawImage(video, sx, sy, s, s, 0, 0, FRAME_PX, FRAME_PX);
    return new Promise((res) => canvas.toBlob(res, 'image/jpeg', JPEG_QUALITY));
  }

  async function sendFrame() {
    inFlight = true;
    try {
      const body = await frameBlob();
      const r = await fetch('/api/frame', {
        method: 'POST',
        headers: { 'Content-Type': 'image/jpeg' },
        body,
      });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      const reply = await r.json();
      speak(reply.speak);
      setStatus(reply.speak ? 'spoke' : 'quiet');
    } catch (e) {
      setStatus('error: ' + e.message);
    } finally {
      inFlight = false;
    }
  }

  function tick() {
    if (video.readyState < 2) return;
    const cur = lumaGrid();
    const now = performance.now();
    const steady = prev && meanDiff(prev, cur) < STEADY_DIFF;
    prev = cur;
    if (!steady) {
      steadySince = now;
      sentForThisHold = false;
      return;
    }
    // One send per steady hold, and never while a reply is still pending.
    if (!inFlight && !sentForThisHold && now - steadySince >= STEADY_MS) {
      sentForThisHold = true;
      sendFrame();
    }
  }

  async function keepAwake() {
    try { await navigator.wakeLock?.request('screen'); } catch (_) { /* best effort */ }
  }

  startBtn.addEventListener('click', async () => {
    unlockSpeech();
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment' },
        audio: false,
      });
      video.srcObject = stream;
      await video.play();
    } catch (e) {
      setStatus('camera failed: ' + e.message + ' (needs HTTPS)');
      return;
    }
    startBtn.hidden = true;
    setStatus('listening');
    keepAwake();
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') keepAwake();
    });
    setInterval(tick, TICK_MS);
  });
})();
