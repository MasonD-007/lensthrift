// Judge view: polls the backend log and renders one row per detected object, spoken, quiet or error.
(() => {
  const POLL_MS = 1000;
  const rows = document.getElementById('rows');
  const table = document.getElementById('table');
  const empty = document.getElementById('empty');

  const money = (n) => (n == null ? '–' : '$' + Math.round(n));
  const pct = (p) => Math.round(p * 100) + '%';
  const safeUrl = (u) => /^https?:\/\//i.test(u || '');
  const el = (tag, text, cls) => {
    const e = document.createElement(tag);
    if (text != null) e.textContent = text;
    if (cls) e.className = cls;
    return e;
  };

  function render(entries) {
    rows.replaceChildren();
    for (const e of entries) {
      const tr = el('tr', null, e.decision === 'spoke' ? 'spoke' : 'quiet');

      tr.append(el('td', new Date(e.ts).toLocaleTimeString()));

      const seen = el('td', e.label || '–');
      if (e.yolo_conf != null) seen.append(el('div', 'YOLO ' + pct(e.yolo_conf), 'sub'));
      tr.append(seen);

      tr.append(el('td', e.jev == null ? '–' : pct(e.jev)));

      const item = el('td', e.item || '–');
      if (e.description) item.append(el('div', e.description, 'sub'));
      tr.append(item);

      tr.append(el('td', money(e.tag)));
      tr.append(el('td', e.low == null ? '–' : money(e.low) + '–' + money(e.high)));
      tr.append(el('td', e.confidence == null ? '–' : pct(e.confidence), 'hide-sm'));

      const dec = el('td');
      dec.append(el('span', e.decision, 'pill'));
      if (e.reason) dec.append(el('div', e.reason, 'sub'));
      if (e.line) dec.append(el('div', '“' + e.line + '”', 'line'));
      tr.append(dec);

      const src = el('td', null, 'src hide-sm');
      if (e.source) src.append(el('div', e.source));
      for (const s of e.sources || []) {
        if (!safeUrl(s.url)) continue;
        const a = el('a', s.title || s.url);
        a.href = s.url;
        a.target = '_blank';
        a.rel = 'noreferrer';
        src.append(a);
      }
      tr.append(src);
      rows.append(tr);
    }
    table.hidden = entries.length === 0;
    empty.hidden = entries.length > 0;
  }

  const statusEl = document.getElementById('status');

  function renderStatus(s) {
    if (!s || !s.ts) { statusEl.textContent = 'No frames received yet. Is the capture page open and steady?'; return; }
    const age = Math.round((Date.now() - new Date(s.ts)) / 1000);
    statusEl.textContent = s.error
      ? 'Last frame ' + age + 's ago: pipeline error (see the backend terminal).'
      : 'Last frame ' + age + 's ago: ' + s.objects + ' object(s) found, ' + s.ms + ' ms'
        + (s.speak ? ', spoke: "' + s.speak + '"' : ', stayed quiet') + '.';
  }

  async function poll() {
    try {
      const [log, status] = await Promise.all([fetch('/api/log'), fetch('/api/status')]);
      if (status.ok) renderStatus(await status.json());
      if (log.ok) render(await log.json());
    } catch (_) { /* backend restarting; try again */ }
    setTimeout(poll, POLL_MS);
  }
  poll();
})();
