// Decision log: one row per detected object, newest frame first, spoken, quiet or error.
// Mounted in the main page's debug panel and in judge.html. Exposes window.LogView.
(() => {
  const POLL_MS = 1000;
  const FILTERS = { all: 'All', spoke: 'Spoke', 'no-errors': 'Hide errors' };
  const FILTER_KEY = 'tl-log-filter';

  const store = {
    get: (k) => { try { return localStorage.getItem(k); } catch (_) { return null; } },
    set: (k, v) => { try { localStorage.setItem(k, v); } catch (_) { /* private mode */ } },
  };
  const money = (n) => (n == null ? '–' : '$' + Math.round(n));
  const pct = (p) => Math.round(p * 100) + '%';
  const safeUrl = (u) => /^https?:\/\//i.test(u || '');
  const el = (tag, text, cls) => {
    const e = document.createElement(tag);
    if (text != null) e.textContent = text;
    if (cls) e.className = cls;
    return e;
  };

  let rowsEl, tableEl, emptyEl, pauseBtn, statusEl;
  const filterBtns = {};
  let filter = FILTERS[store.get(FILTER_KEY)] ? store.get(FILTER_KEY) : 'all';
  let entries = [];
  let lastText = null;
  let active = false;
  let paused = false;
  let timer = null;

  const visible = (e) =>
    filter === 'spoke' ? e.decision === 'spoke' : filter === 'no-errors' ? e.decision !== 'error' : true;

  function row(e, frameStart) {
    const decision = ['spoke', 'quiet', 'error'].includes(e.decision) ? e.decision : 'quiet';
    const junk = e.reason === 'not resalable' ? ' junk' : '';
    const tr = el('tr', null, decision + junk + (frameStart ? ' frame-start' : ''));

    tr.append(el('td', new Date(e.ts).toLocaleTimeString()));

    const seen = el('td', e.label || '–');
    if (e.yolo_conf != null) seen.append(el('div', 'YOLO ' + pct(e.yolo_conf), 'sub'));
    tr.append(seen);

    tr.append(el('td', e.jev == null ? '–' : pct(e.jev)));

    const item = el('td', e.item || '–');
    if (e.description) item.append(el('div', e.description, 'sub'));
    tr.append(item);

    tr.append(el('td', money(e.tag), 'opt'));
    tr.append(el('td', e.low == null ? '–' : money(e.low) + '–' + money(e.high)));
    tr.append(el('td', e.confidence == null ? '–' : pct(e.confidence), 'opt'));

    const dec = el('td');
    dec.append(el('span', e.decision, 'pill'));
    if (e.reason) dec.append(el('div', e.reason, 'sub'));
    if (e.line) dec.append(el('div', '“' + e.line + '”', 'line'));
    tr.append(dec);

    const src = el('td', null, 'src opt');
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
    return tr;
  }

  function render() {
    const shown = entries.filter(visible);
    rowsEl.replaceChildren(...shown.map((e, i) => row(e, i > 0 && shown[i - 1].ts !== e.ts)));
    tableEl.hidden = shown.length === 0;
    emptyEl.hidden = shown.length > 0;
    emptyEl.textContent = entries.length ? 'No rows match this filter.' : 'Waiting for the first frame…';
  }

  function renderStatus(st) {
    if (!st || !st.ts) {
      statusEl.textContent = 'No frames received yet. Is the camera running and the view steady?';
      return;
    }
    const age = Math.round((Date.now() - new Date(st.ts)) / 1000);
    statusEl.textContent = st.error
      ? 'Last frame ' + age + 's ago: pipeline error (see the backend terminal).'
      : 'Last frame ' + age + 's ago: ' + st.objects + ' object(s) found, ' + st.ms + ' ms'
        + (st.speak ? ', spoke: "' + st.speak + '"' : ', stayed quiet') + '.';
  }

  async function refresh() {
    try {
      const [r, st] = await Promise.all([fetch('/api/log'), fetch('/api/status')]);
      if (st.ok) renderStatus(await st.json());
      if (!r.ok) return;
      const text = await r.text();
      if (text === lastText) return; // unchanged: keep scroll position and selection
      lastText = text;
      entries = JSON.parse(text);
      render();
    } catch (_) { /* backend restarting; try again */ }
  }

  function schedule() {
    clearTimeout(timer);
    if (!active || paused) return;
    timer = setTimeout(async () => {
      await refresh();
      schedule();
    }, POLL_MS);
  }

  function setActive(on) {
    active = on;
    if (active && !paused) refresh();
    schedule();
  }

  function setFilter(f) {
    filter = f;
    store.set(FILTER_KEY, f);
    for (const [k, b] of Object.entries(filterBtns)) b.setAttribute('aria-pressed', String(k === f));
    render();
  }

  async function clearLog() {
    try { await fetch('/api/log', { method: 'DELETE' }); } catch (_) { /* offline */ }
    lastText = null;
    await refresh();
  }

  function mount(container, { active: startActive = true } = {}) {
    const bar = el('div', null, 'log-bar');
    const group = el('div', null, 'seg');
    for (const [k, label] of Object.entries(FILTERS)) {
      const b = el('button', label);
      b.type = 'button';
      b.addEventListener('click', () => setFilter(k));
      filterBtns[k] = b;
      group.append(b);
    }
    pauseBtn = el('button', 'Pause');
    pauseBtn.type = 'button';
    pauseBtn.setAttribute('aria-pressed', 'false');
    pauseBtn.addEventListener('click', () => {
      paused = !paused;
      pauseBtn.textContent = paused ? 'Resume' : 'Pause';
      pauseBtn.setAttribute('aria-pressed', String(paused));
      if (!paused) refresh();
      schedule();
    });
    const clearBtn = el('button', 'Clear log');
    clearBtn.type = 'button';
    clearBtn.addEventListener('click', clearLog);
    bar.append(group, pauseBtn, clearBtn);

    tableEl = el('table');
    tableEl.hidden = true;
    const head = el('tr');
    for (const [label, cls] of [['Time'], ['Seen'], ['Jev'], ['Item'], ['Tag', 'opt'], ['Resale'],
                                ['Conf.', 'opt'], ['Decision'], ['Sources', 'opt']]) {
      head.append(el('th', label, cls));
    }
    const thead = el('thead');
    thead.append(head);
    rowsEl = el('tbody');
    tableEl.append(thead, rowsEl);
    emptyEl = el('div', 'Waiting for the first frame…', 'log-empty');
    statusEl = el('p', 'No frames received yet.', 'log-status');

    container.append(bar, statusEl, emptyEl, tableEl);
    setFilter(filter);
    setActive(startActive);
  }

  window.LogView = { mount, setActive, refresh };
})();
