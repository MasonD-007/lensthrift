// Objects feed: polls the backend for newly detected objects and appends them, oldest first.
(() => {
  const POLL_MS = 500;
  const list = document.getElementById('objects');
  const empty = document.getElementById('empty');
  const count = document.getElementById('count');
  let lastId = 0;
  let boot = '';
  let total = 0;

  function append(entries) {
    for (const e of entries) {
      const chip = document.createElement('span');
      chip.className = 'object fresh';
      chip.textContent = e.label;
      chip.title = new Date(e.ts).toLocaleTimeString() + ' · ' + Math.round(e.conf * 100) + '%';
      list.append(chip);
      setTimeout(() => chip.classList.remove('fresh'), 1500);
      lastId = e.id;
      total++;
    }
    if (entries.length) {
      list.hidden = false;
      empty.hidden = true;
      count.textContent = total + ' so far.';
      window.scrollTo(0, document.body.scrollHeight);
    }
  }

  async function poll() {
    try {
      const r = await fetch('/api/seen?after=' + lastId + '&boot=' + encodeURIComponent(boot));
      if (r.ok) {
        const serverBoot = r.headers.get('X-Seen-Boot') || '';
        if (serverBoot !== boot) { // the server restarted: its ids start over, so drop what we showed
          boot = serverBoot;
          lastId = 0;
          total = 0;
          list.replaceChildren();
          list.hidden = true;
          empty.hidden = false;
          count.textContent = '';
        }
        append(await r.json());
      }
    } catch (_) { /* backend restarting; try again */ }
    setTimeout(poll, POLL_MS);
  }
  poll();
})();
