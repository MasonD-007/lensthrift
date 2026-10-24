// Main page (local, laptop webcam): YOLO tracks what's in view, one object is picked (nearest the
// middle, closer wins), and once it has been held still for about 2 s the frame and that object's
// box go to the backend, which prices only that object. The reply is spoken.
// D toggles the debug view: every YOLO box, timing, controls and the decision log.
(() => {
  const FRAME_PX = 640;          // downscaled JPEG edge
  const JPEG_QUALITY = 0.7;
  const DETECT_PX = 320;         // YOLO input edge
  const DETECT_MS = 100;         // pause between detect calls
  const CAPTION_MS = 6000;       // whisper caption stays this long
  // Result colors: red means Jev judged it not resalable; errors are purple so they don't read as junk.
  const COLORS = { spoke: '#3c6', quiet: '#999', junk: '#e33', error: '#b7f' };
  const NOT_RESALABLE = 'not resalable'; // the pipeline's reason when Jev stops an object
  const PHASE_COLORS = { stabilizing: '#fb3', stabilized: '#3c6', sent: '#3c6' };
  const HOLD_S = (Stabilize.HOLD_MS / 1000).toFixed(1);

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
  const pct = (p) => Math.round(p * 100) + '%';

  const video = $('video');
  const canvas = $('canvas');
  const preview = $('preview');
  const boxes = $('boxes');
  const decisions = $('decisions');
  const phaseEl = $('phase');
  const startBtn = $('start');
  const statusEl = $('status');
  const captionEl = $('caption');
  const debugBtn = $('debug-toggle');
  const muteBtn = $('mute');
  const cameraSel = $('camera');
  const statsEl = $('stats');

  const stabilizer = Stabilize.createStabilizer();
  let live = false;
  let stream = null;
  let inFlight = false;
  let debug = false;
  let muted = false;
  let lastLine = '';
  let lastResult = '';           // what the backend said about the object just sent
  let result = null;             // { kind, name, reason } for the badge: spoke | quiet | junk | error
  let captionTimer = null;
  let scan = { phase: 'searching', target: null, progress: 0 };
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

  // Center-crop to a square: YOLO boxes and the sent frame share these coordinates.
  function squareCrop(w, h) {
    const s = Math.min(w, h);
    return { sx: (w - s) / 2, sy: (h - s) / 2, s };
  }

  function frameBlob(px = FRAME_PX) {
    const { sx, sy, s } = squareCrop(video.videoWidth, video.videoHeight);
    canvas.width = canvas.height = px;
    canvas.getContext('2d').drawImage(video, sx, sy, s, s, 0, 0, px, px);
    return new Promise((res) => canvas.toBlob(res, 'image/jpeg', JPEG_QUALITY));
  }

  // ---- Send ----

  function frameUrl(target) {
    if (!target) return '/api/frame'; // no target: the backend runs YOLO and picks one itself
    const q = new URLSearchParams({
      box: target.box.map((v) => Math.min(1, Math.max(0, v)).toFixed(4)).join(','),
      label: target.label,
      conf: target.conf.toFixed(3),
    });
    return '/api/frame?' + q;
  }

  async function sendFrame(target) {
    if (inFlight || !live) return;
    inFlight = true;
    stats.sent++;
    lastResult = '';
    result = null;
    setStatus('Stabilized: ' + (target ? target.label : 'frame') + ', pricing…');
    renderStats();
    const t0 = performance.now();
    try {
      const r = await fetch(frameUrl(target), {
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
      const o = objects[0];
      result = o ? { kind: outcome(o), name: o.item || o.label, reason: o.reason } : null;
      lastResult = reply.speak ? 'spoke: ' + reply.speak
        : !o ? 'nothing to price'
          : result.kind === 'junk' ? result.name + ': not resalable'
            : result.name + ': ' + o.decision + ' (' + o.reason + ')';
      drawDecisions(objects);
      if (debug) LogView.refresh();
    } catch (e) {
      stats.errors++;
      stats.lastError = e.message;
      lastResult = 'error: ' + e.message;
      result = { kind: 'error', name: target ? target.label : 'frame', reason: e.message };
    } finally {
      inFlight = false;
      setStatus(lastResult);
      renderStats();
    }
  }

  // Space / Send now: price the current target right away (or let the backend pick).
  function sendNow() {
    if (scan.target) stabilizer.markSent();
    sendFrame(scan.target);
  }

  // ---- Tracking: every YOLO result feeds the stabilizer ----

  function onDetections(dets, now) {
    const wasSent = scan.phase === 'sent';
    scan = stabilizer.update(dets, now);
    if (wasSent && scan.phase !== 'sent') { // a new object (or none): drop the old result
      clearDecisions();
      result = null;
    }
    if (scan.phase === 'stabilized' && !inFlight) {
      stabilizer.markSent();
      sendFrame(scan.target);
      scan = { ...scan, phase: 'sent' };
    }
    drawTracking(dets);
    renderPhase();
    if (!inFlight) setStatus(statusText());
    if (debug) renderStats();
  }

  function statusText() {
    const t = scan.target;
    switch (scan.phase) {
      case 'stabilizing': return 'Stabilizing ' + t.label + '… ' + (scan.progress * Stabilize.HOLD_MS / 1000).toFixed(1) + ' / ' + HOLD_S + ' s';
      case 'stabilized': return 'Stabilized: ' + t.label;
      case 'sent': return lastResult || 'Stabilized: ' + t.label + ', sent';
      default: return 'Hold an item up to the camera';
    }
  }

  const RESULT_TEXT = {
    spoke: (r) => 'Worth it: ' + r.name,
    junk: (r) => 'Not resalable: ' + r.name,
    quiet: (r) => r.name + ': ' + r.reason,
    error: (r) => 'Error: ' + r.name,
  };

  function renderPhase() {
    const { phase, target, progress } = scan;
    phaseEl.hidden = !live;
    const done = phase === 'sent' && !inFlight && result;
    phaseEl.dataset.phase = phase;
    phaseEl.dataset.result = done ? result.kind : '';
    $('phase-text').textContent =
      phase === 'searching' ? 'Searching'
        : phase === 'stabilizing' ? 'Stabilizing ' + target.label + ' ' + pct(progress)
          : !done ? 'Stabilized: ' + target.label + (inFlight || phase === 'stabilized' ? ' · pricing…' : ' · sent')
            : RESULT_TEXT[result.kind](result);
    $('phase-fill').style.width = pct(phase === 'searching' ? 0 : progress);
  }

  async function detectLoop() {
    if (live && !inFlight && video.readyState >= 2) {
      try {
        const r = await fetch('/api/detect', {
          method: 'POST',
          headers: { 'Content-Type': 'image/jpeg' },
          body: await frameBlob(DETECT_PX),
        });
        if (r.ok) onDetections(await r.json(), performance.now());
      } catch (_) {
        onDetections([], performance.now()); // backend busy or restarting: the object counts as unseen
      }
    }
    setTimeout(detectLoop, DETECT_MS);
  }

  // ---- Overlays (drawn on the sent center square) ----

  function fit(c) {
    c.width = c.clientWidth;
    c.height = c.clientHeight;
    return c.getContext('2d');
  }

  function clearCanvas(c) { c.getContext('2d').clearRect(0, 0, c.width, c.height); }

  function clearDecisions() {
    clearCanvas(decisions);
    decisions.dataset.drawn = '';
  }

  function drawBox(ctx, [x1, y1, x2, y2], text, color, width, progress) {
    const { width: w, height: h } = ctx.canvas;
    ctx.lineWidth = width;
    ctx.strokeStyle = color;
    ctx.strokeRect(x1 * w, y1 * h, (x2 - x1) * w, (y2 - y1) * h);
    if (progress != null) { // countdown bar along the bottom edge of the box
      ctx.fillStyle = color;
      ctx.fillRect(x1 * w, y2 * h - 6, (x2 - x1) * w * progress, 6);
    }
    if (!text) return;
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

  // Debug shows every YOLO box; both modes show the one target and its countdown.
  function drawTracking(dets) {
    const ctx = fit(boxes);
    if (debug) {
      for (const d of dets) {
        if (scan.target && d.box === scan.target.box) continue;
        drawBox(ctx, d.box, d.label + ' ' + pct(d.conf), '#6cf', 1);
      }
    }
    const t = scan.target;
    if (!t || scan.phase === 'searching') return;
    if (scan.phase === 'sent' && !inFlight && decisions.dataset.drawn === '1') return; // result box shows instead
    const label = scan.phase === 'stabilizing' ? t.label + ' · stabilizing ' + pct(scan.progress)
      : t.label + ' · stabilized';
    drawBox(ctx, t.box, label, PHASE_COLORS[scan.phase], 3, scan.progress);
  }

  function outcome(o) {
    if (o.decision === 'spoke' || o.decision === 'error') return o.decision;
    return o.reason === NOT_RESALABLE ? 'junk' : 'quiet';
  }

  function drawDecisions(objects) {
    const ctx = fit(decisions);
    decisions.dataset.drawn = objects.length ? '1' : '';
    for (const o of objects) {
      if (!o.box) continue;
      // Errors read "jev error: <Type>: <msg>"; the log has the detail, the frame only needs the stage.
      const reason = o.decision === 'error' ? o.reason.split(':')[0] : o.reason;
      let text = (o.item || o.label) + ' · ' + reason;
      if (o.decision === 'spoke') text += ' · $' + Math.round(o.low) + '–$' + Math.round(o.high);
      drawBox(ctx, o.box, text, COLORS[outcome(o)], outcome(o) === 'junk' ? 4 : 3);
    }
  }

  // ---- Debug panel ----

  function renderStats() {
    const t = scan.target;
    const rows = [
      ['Phase', inFlight ? 'stabilized, pricing' : scan.phase === 'sent' ? 'stabilized, sent' : scan.phase],
      ['Target', t ? t.label + ' (YOLO ' + pct(t.conf) + ')' : '–'],
      ['Hold', t ? (scan.progress * Stabilize.HOLD_MS / 1000).toFixed(1) + ' / ' + HOLD_S + ' s' : '–'],
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
      stabilizer.reset(); // also lets the item in view be scanned again
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
    stabilizer.reset();
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
    } catch (e) {
      setStatus('camera failed: ' + e.message);
    }
  });

  // ---- Controls ----

  const blurAfter = (btn, fn) => btn.addEventListener('click', () => { btn.blur(); fn(); });
  blurAfter(debugBtn, () => setDebug(!debug));
  blurAfter($('send-now'), sendNow);
  blurAfter(muteBtn, () => setMuted(!muted));
  blurAfter($('replay'), () => speakNow(lastLine));
  blurAfter($('reset-memory'), resetMemory);

  document.addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey || e.target.closest('select, input, textarea')) return;
    switch (e.key.toLowerCase()) {
      case 'd': setDebug(!debug); break;
      case ' ': e.preventDefault(); sendNow(); break;
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
    setStatus(statusText());
    renderPhase();
    listCameras();
    keepAwake();
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') keepAwake();
    });
    detectLoop();
    renderStats();
  });

  LogView.mount($('log'), { active: false });
  setDebug(initialDebug());
})();
