// Main page (local, laptop webcam): steady-frame check -> POST JPEG -> speak the reply.
// The backend holds the keys and decides. D toggles the debug view: live YOLO boxes, how each
// object was decided, timing, controls and the decision log.
(() => {
  const FRAME_PX = 640;          // downscaled JPEG edge
  const JPEG_QUALITY = 0.7;
  const TICK_MS = 250;           // steady-check cadence
  const STEADY_MS = 1000;        // view must hold this long before we send
  const STEADY_DIFF = 6;         // mean abs luma diff (0-255) under which we call it steady
  const DETECT_PX = 320;         // YOLO input edge
  const DETECT_MS = 100;         // pause between detect calls
  const SAMPLE = 32;             // tiny grayscale grid for motion compare
  const CAPTION_MS = 6000;       // whisper caption stays this long
  const OVERLAY_MS = 5000;       // decision boxes stay this long (or until the view moves)
  const COLORS = { spoke: '#3c6', quiet: '#999', error: '#e55' };

  const $ = (id) => document.getElementById(id);
  const store = {
    get: (k) => { try { return localStorage.getItem(k); } catch (_) { return null; } },
    set: (k, v) => { try { localStorage.setItem(k, v); } catch (_) { /* private mode */ } },
  };
  const el = (tag, text, cls) => {
    const e = document.createElement(tag);
    if (text != null) e.textContent = text;
    if (cls) e.className = cls;
    return e;
  };

  const video = $('video');
  const canvas = $('canvas');
  const preview = $('preview');
  const boxes = $('boxes');
  const decisions = $('decisions');
  const startBtn = $('start');
  const statusEl = $('status');
  const captionEl = $('caption');
  const debugBtn = $('debug-toggle');
  const muteBtn = $('mute');
  const cameraSel = $('camera');
  const statsEl = $('stats');
  const small = document.createElement('canvas');
  small.width = small.height = SAMPLE;

  let live = false;
  let stream = null;
  let prev = null;
  let lastDiff = 0;
  let steadySince = 0;
  let inFlight = false;
  let sentForThisHold = false;
  let debug = false;
  let muted = false;
  let lastLine = '';
  let captionTimer = null;
  let overlayTimer = null;
  const stats = { sent: 0, spoke: 0, errors: 0, rtt: null, lastError: '' };

  const setStatus = (msg) => { statusEl.textContent = msg; };

  // ---- Speech and caption ----

  function speakNow(text) {
    if (!text) return;
    speechSynthesis.cancel();
    const u = new SpeechSynthesisUtterance(text);
    u.rate = 1.1;
    speechSynthesis.speak(u);
  }

  const speak = (text) => { if (!muted) speakNow(text); };

  // Browsers only allow speech after a user gesture; a silent utterance on Start unlocks it.
  function unlockSpeech() {
    const u = new SpeechSynthesisUtterance(' ');
    u.volume = 0;
    speechSynthesis.speak(u);
  }

  function showCaption(text) {
    captionEl.textContent = text;
    captionEl.classList.add('show');
    clearTimeout(captionTimer);
    captionTimer = setTimeout(() => captionEl.classList.remove('show'), CAPTION_MS);
  }

  // ---- Frames ----

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

  function frameBlob(px = FRAME_PX) {
    const { sx, sy, s } = squareCrop(video.videoWidth, video.videoHeight);
    canvas.width = canvas.height = px;
    canvas.getContext('2d').drawImage(video, sx, sy, s, s, 0, 0, px, px);
    return new Promise((res) => canvas.toBlob(res, 'image/jpeg', JPEG_QUALITY));
  }

  // ---- Send ----

  async function sendFrame() {
    if (inFlight || !live) return;
    inFlight = true;
    stats.sent++;
    setStatus('sending');
    clearCanvas(boxes);
    renderStats();
    const t0 = performance.now();
    try {
      const r = await fetch('/api/frame', {
        method: 'POST',
        headers: { 'Content-Type': 'image/jpeg' },
        body: await frameBlob(),
      });
      const reply = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(reply.detail || 'HTTP ' + r.status);
      stats.rtt = Math.round(performance.now() - t0);
      const objects = reply.objects || [];
      if (reply.speak) {
        lastLine = reply.speak;
        stats.spoke++;
        showCaption(reply.speak);
        speak(reply.speak);
      }
      setStatus(reply.speak ? 'spoke' : objects.length + ' object(s), quiet');
      drawDecisions(objects);
      if (debug) LogView.refresh();
    } catch (e) {
      stats.errors++;
      stats.lastError = e.message;
      setStatus('error: ' + e.message);
    } finally {
      inFlight = false;
      renderStats();
    }
  }

  // ---- Steady check ----

  function tick() {
    if (video.readyState < 2) return;
    const cur = lumaGrid();
    const now = performance.now();
    lastDiff = prev ? meanDiff(prev, cur) : Infinity;
    const steady = lastDiff < STEADY_DIFF;
    prev = cur;
    if (!steady) {
      steadySince = now;
      sentForThisHold = false;
      clearDecisions();
    } else if (!inFlight && !sentForThisHold && now - steadySince >= STEADY_MS) {
      // One send per steady hold, and never while a reply is still pending.
      sentForThisHold = true;
      sendFrame();
    }
    if (debug) renderMeters(steady, now);
  }

  // ---- Overlays (drawn on the sent center square) ----

  function fit(c) {
    c.width = c.clientWidth;
    c.height = c.clientHeight;
    return c.getContext('2d');
  }

  function clearCanvas(c) { c.getContext('2d').clearRect(0, 0, c.width, c.height); }

  function clearDecisions() {
    clearTimeout(overlayTimer);
    clearCanvas(decisions);
  }

  function drawBox(ctx, [x1, y1, x2, y2], text, color, width) {
    const { width: w, height: h } = ctx.canvas;
    ctx.lineWidth = width;
    ctx.strokeStyle = color;
    ctx.strokeRect(x1 * w, y1 * h, (x2 - x1) * w, (y2 - y1) * h);
    ctx.font = '13px system-ui, sans-serif';
    ctx.textBaseline = 'top';
    const tw = Math.min(ctx.measureText(text).width + 8, w);
    const tx = Math.max(0, Math.min(x1 * w, w - tw));
    const ty = y1 * h > 18 ? y1 * h - 18 : y1 * h;
    ctx.fillStyle = color;
    ctx.fillRect(tx, ty, tw, 18);
    ctx.fillStyle = '#000';
    ctx.fillText(text, tx + 4, ty + 3);
  }

  function drawBoxes(dets) {
    const ctx = fit(boxes);
    for (const d of dets) drawBox(ctx, d.box, d.label + ' ' + Math.round(d.conf * 100) + '%', '#6cf', 1);
  }

  function drawDecisions(objects) {
    clearDecisions();
    if (!debug || !objects.length) return;
    const ctx = fit(decisions);
    for (const o of objects) {
      if (!o.box) continue;
      // Errors read "jev error: <Type>: <msg>"; the log has the detail, the frame only needs the stage.
      const reason = o.decision === 'error' ? o.reason.split(':')[0] : o.reason;
      let text = (o.item || o.label) + ' · ' + reason;
      if (o.decision === 'spoke') text += ' · $' + Math.round(o.low) + '–$' + Math.round(o.high);
      drawBox(ctx, o.box, text, COLORS[o.decision] || COLORS.quiet, 3);
    }
    overlayTimer = setTimeout(() => clearCanvas(decisions), OVERLAY_MS);
  }

  // YOLO preview boxes, only in debug mode and never while a frame is being priced.
  let detecting = false;
  async function detectLoop() {
    if (!detecting && live && debug && !inFlight && video.readyState >= 2) {
      detecting = true;
      try {
        const r = await fetch('/api/detect', {
          method: 'POST',
          headers: { 'Content-Type': 'image/jpeg' },
          body: await frameBlob(DETECT_PX),
        });
        if (r.ok && debug && !inFlight) drawBoxes(await r.json());
      } catch (_) { /* backend busy; next loop */ }
      detecting = false;
    }
    setTimeout(detectLoop, DETECT_MS);
  }

  // ---- Debug panel ----

  function renderMeters(steady, now) {
    const motion = Number.isFinite(lastDiff) ? lastDiff / STEADY_DIFF : 1;
    const bar = $('steady-bar');
    bar.style.width = Math.min(100, motion * 100) + '%';
    bar.classList.toggle('over', !steady);
    const hold = steady ? (now - steadySince) / STEADY_MS : 0;
    $('hold-bar').style.width = Math.min(100, hold * 100) + '%';
  }

  function renderStats() {
    const rows = [
      ['State', inFlight ? 'sending' : live ? 'listening' : 'stopped'],
      ['Round trip', stats.rtt == null ? '–' : stats.rtt + ' ms'],
      ['Frames sent', stats.sent],
      ['Whispers', stats.spoke],
      ['Request errors', stats.errors],
      ['Last error', stats.lastError || '–'],
    ];
    statsEl.replaceChildren(...rows.flatMap(([k, v]) => [el('dt', k), el('dd', String(v))]));
  }

  function initialDebug() {
    const q = new URLSearchParams(location.search).get('debug');
    if (q !== null) return q !== '0';
    return store.get('tl-debug') === '1';
  }

  function setDebug(on) {
    debug = on;
    document.body.classList.toggle('debug', on);
    debugBtn.setAttribute('aria-pressed', String(on));
    store.set('tl-debug', on ? '1' : '0');
    LogView.setActive(on);
    if (!on) {
      clearCanvas(boxes);
      clearDecisions();
    }
    renderStats();
  }

  function setMuted(on) {
    muted = on;
    if (on) speechSynthesis.cancel();
    muteBtn.textContent = on ? 'Unmute' : 'Mute';
    muteBtn.setAttribute('aria-pressed', String(on));
  }

  async function resetMemory() {
    try {
      const r = await fetch('/api/memory', { method: 'DELETE' });
      setStatus(r.ok ? 'memory cleared: cached quotes and cooldowns forgotten' : 'reset failed: HTTP ' + r.status);
    } catch (e) {
      setStatus('reset failed: ' + e.message);
    }
  }

  // ---- Camera ----

  async function startCamera(deviceId) {
    if (stream) stream.getTracks().forEach((t) => t.stop());
    stream = await navigator.mediaDevices.getUserMedia({
      video: deviceId ? { deviceId: { exact: deviceId } } : true,
      audio: false,
    });
    video.srcObject = stream;
    await video.play();
    preview.style.aspectRatio = video.videoWidth + ' / ' + video.videoHeight;
    preview.classList.toggle('portrait', video.videoHeight > video.videoWidth);
    prev = null;
  }

  async function listCameras() {
    const cams = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === 'videoinput');
    cameraSel.replaceChildren(...cams.map((d, i) => {
      const o = el('option', d.label || 'Camera ' + (i + 1));
      o.value = d.deviceId;
      return o;
    }));
    const current = stream && stream.getVideoTracks()[0].getSettings().deviceId;
    if (current) cameraSel.value = current;
  }

  cameraSel.addEventListener('change', async () => {
    try {
      await startCamera(cameraSel.value);
      store.set('tl-camera', cameraSel.value);
      setStatus('listening');
    } catch (e) {
      setStatus('camera failed: ' + e.message);
    }
  });

  // ---- Controls ----

  const blurAfter = (btn, fn) => btn.addEventListener('click', () => { btn.blur(); fn(); });
  blurAfter(debugBtn, () => setDebug(!debug));
  blurAfter($('send-now'), sendFrame);
  blurAfter(muteBtn, () => setMuted(!muted));
  blurAfter($('replay'), () => speakNow(lastLine));
  blurAfter($('reset-memory'), resetMemory);

  document.addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey || e.target.closest('select, input, textarea')) return;
    switch (e.key.toLowerCase()) {
      case 'd': setDebug(!debug); break;
      case ' ': e.preventDefault(); sendFrame(); break;
      case 'm': setMuted(!muted); break;
      case 'r': speakNow(lastLine); break;
      default: return;
    }
  });

  async function keepAwake() {
    try { await navigator.wakeLock?.request('screen'); } catch (_) { /* best effort */ }
  }

  startBtn.addEventListener('click', async () => {
    unlockSpeech();
    if (!navigator.mediaDevices?.getUserMedia) {
      setStatus('no camera access: open http://localhost:8080 in Chrome, Safari or Firefox');
      return;
    }
    try {
      const saved = store.get('tl-camera');
      try {
        await startCamera(saved);
      } catch (e) {
        if (!saved) throw e;
        await startCamera(); // saved camera unplugged: fall back to the default
      }
    } catch (e) {
      setStatus('camera failed: ' + e.message);
      return;
    }
    live = true;
    startBtn.hidden = true;
    document.body.classList.add('live');
    setStatus('listening');
    listCameras();
    keepAwake();
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') keepAwake();
    });
    setInterval(tick, TICK_MS);
    detectLoop();
    renderStats();
  });

  LogView.mount($('log'), { active: false });
  setDebug(initialDebug());
})();
