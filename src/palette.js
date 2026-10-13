// ⌘O / ⌘P card pickers, in the style of Raycast Notes' note switcher.
//   ⌘P  Recent: cards opened in HeptaFloat (HeptaFloat's own history, not Heptabase's)
//   ⌘O  Search: any card in Heptabase, through the CLI

const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

const TYPE_LABEL = { journal: 'Journal', note: 'Note', pdf: 'PDF', highlightElement: 'Highlight', image: 'Image', video: 'Video', audio: 'Audio', web: 'Web' };

export function relativeTime(iso) {
  if (!iso) return '';
  const s = (Date.now() - new Date(iso)) / 1000;
  if (s < 60) return 'just now';
  const units = [[60, 'minute'], [3600, 'hour'], [86400, 'day'], [604800, 'week'], [2592000, 'month'], [31536000, 'year']];
  let [size, name] = units[0];
  for (const u of units) if (s >= u[0]) [size, name] = u;
  const n = Math.floor(s / size);
  if (name === 'day' && n === 1) return 'yesterday';
  if (name === 'week' && n === 1) return 'last week';
  if (name === 'month' && n === 1) return 'last month';
  return `${n} ${name}${n === 1 ? '' : 's'} ago`;
}

const ICONS = {
  pin: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10 2l4 4-2.5 1-2.5 2.5.5 3-1 1L3.5 8.5l1-1 3 .5L10 5.5z"/><path d="M5.5 10.5L2 14"/></svg>',
  remove: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M4.5 4.5l7 7M11.5 4.5l-7 7"/></svg>',
  heptabase: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M9 3h4v4M13 3L7.5 8.5M11.5 9.5V12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V5.5a1 1 0 0 1 1-1h2.5"/></svg>',
};

/**
 * host: {
 *   recents(): Promise<[{ id, objectType, title, openedAt, chars, pinned, current }]>,
 *   search(q): Promise<[{ id, objectType, title, lastEditedTime }]>,
 *   open(card), openInHeptabase(card), pin(card, on), forget(card)
 * }
 */
export function createPalette(host) {
  const root = document.createElement('div');
  root.className = 'palette-overlay';
  root.innerHTML = `
    <div class="palette-panel" role="dialog">
      <input class="palette-input" spellcheck="false" autocomplete="off">
      <div class="palette-list"></div>
      <div class="palette-hints"></div>
    </div>`;
  document.body.append(root);
  const input = root.querySelector('.palette-input');
  const list = root.querySelector('.palette-list');
  const hints = root.querySelector('.palette-hints');

  let mode = null, items = [], index = 0, seq = 0, timer = null, all = [];

  function render(sections) {
    items = sections.flatMap((s) => s.items);
    index = Math.min(index, Math.max(0, items.length - 1));
    let i = 0;
    list.innerHTML = sections.filter((s) => s.items.length).map((s) => `
      ${s.title ? `<div class="palette-section">${esc(s.title)}</div>` : ''}
      ${s.items.map((it) => {
        const n = i++;
        return `<div class="palette-row${n === index ? ' sel' : ''}" data-i="${n}">
          <div class="palette-text">
            <div class="palette-title">${esc(it.title || 'Untitled')}</div>
            <div class="palette-sub">${it.current ? '<span class="dot"></span>' : ''}${esc(it.sub)}</div>
          </div>
          <div class="palette-actions">${it.actions.map((a) => `<button data-act="${a.act}" title="${esc(a.title)}" class="${a.on ? 'on' : ''}">${ICONS[a.icon]}</button>`).join('')}</div>
        </div>`;
      }).join('')}`).join('')
      || `<div class="palette-empty">${mode === 'search' && input.value ? 'No cards found' : mode === 'search' ? 'Type to search your Heptabase cards' : 'No recent cards yet'}</div>`;
    list.querySelector('.palette-row.sel')?.scrollIntoView({ block: 'nearest' });
  }

  function recentItem(c) {
    const parts = [c.current ? 'Current' : `Opened ${relativeTime(c.openedAt)}`, TYPE_LABEL[c.objectType] || 'Card'];
    if (c.chars != null) parts.push(`${c.chars.toLocaleString()} characters`);
    return { ...c, card: c, sub: parts.join(' • '),
      actions: [{ act: 'pin', icon: 'pin', title: c.pinned ? 'Unpin (⌘.)' : 'Pin (⌘.)', on: c.pinned }, { act: 'forget', icon: 'remove', title: 'Remove from recents' }] };
  }
  function searchItem(c) {
    return { card: c, title: c.title, sub: [TYPE_LABEL[c.objectType] || 'Card', c.lastEditedTime && `Edited ${relativeTime(c.lastEditedTime)}`].filter(Boolean).join(' • '),
      actions: [{ act: 'heptabase', icon: 'heptabase', title: 'Open in Heptabase (⌘↵)' }] };
  }

  function showRecents() {
    const q = input.value.trim().toLowerCase();
    const match = all.filter((c) => !q || (c.title || '').toLowerCase().includes(q)).map(recentItem);
    render([
      { title: '', items: match.filter((c) => c.current) },
      { title: 'Pinned', items: match.filter((c) => c.pinned && !c.current) },
      { title: 'Recent', items: match.filter((c) => !c.pinned && !c.current) },
    ]);
  }

  function runSearch() {
    clearTimeout(timer);
    const q = input.value.trim(), mySeq = ++seq;
    if (!q) { render([]); return; }
    timer = setTimeout(async () => {
      const results = await host.search(q);
      if (mySeq === seq && mode === 'search') render([{ title: 'Cards', items: results.map(searchItem) }]);
    }, 140);
  }

  async function open(which) {
    mode = which;
    index = 0;
    input.value = '';
    input.placeholder = which === 'search' ? 'Search cards in Heptabase…' : 'Search recent cards…';
    hints.innerHTML = `<span><kbd>↑</kbd><kbd>↓</kbd> Navigate</span><span><kbd>↵</kbd> Open</span>`
      + (which === 'search' ? '<span><kbd>⌘</kbd><kbd>↵</kbd> Heptabase</span>' : '<span><kbd>⌘</kbd><kbd>⌫</kbd> Remove</span>')
      + '<span><kbd>esc</kbd> Close</span>';
    root.classList.add('show');
    input.focus();
    if (which === 'recent') { all = await host.recents(); showRecents(); } else render([]);
  }

  function close() {
    mode = null;
    root.classList.remove('show');
    host.onClose?.();
  }

  async function act(act, item) {
    if (!item) return;
    if (act === 'open') { close(); host.open(item.card); }
    else if (act === 'heptabase') { close(); host.openInHeptabase(item.card); }
    else if (act === 'pin') { await host.pin(item.card, !item.card.pinned); all = await host.recents(); showRecents(); }
    else if (act === 'forget') { await host.forget(item.card); all = await host.recents(); showRecents(); }
  }

  function move(d) {
    if (!items.length) return;
    index = (index + d + items.length) % items.length;
    list.querySelectorAll('.palette-row').forEach((r, j) => r.classList.toggle('sel', j === index));
    list.querySelector('.palette-row.sel')?.scrollIntoView({ block: 'nearest' });
  }

  input.addEventListener('input', () => { index = 0; mode === 'search' ? runSearch() : showRecents(); });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown' || (e.ctrlKey && e.key === 'n')) { e.preventDefault(); move(1); }
    else if (e.key === 'ArrowUp' || (e.ctrlKey && e.key === 'p')) { e.preventDefault(); move(-1); }
    else if (e.key === 'Enter') { e.preventDefault(); act(e.metaKey ? 'heptabase' : 'open', items[index]); }
    else if (e.key === 'Backspace' && e.metaKey && mode === 'recent') { e.preventDefault(); act('forget', items[index]); }
    else if (e.key === 'Escape') { e.preventDefault(); close(); }
    else if (mode === 'recent' && host.isPinKey?.(e)) { e.preventDefault(); act('pin', items[index]); } // ⌘. pins the highlighted card
    else {
      const which = host.pickerFor?.(e); // the user's ⌘P / ⌘O keys switch pickers or close
      if (which) { e.preventDefault(); which === mode ? close() : open(which); }
    }
  });
  list.addEventListener('mousemove', (e) => {
    const row = e.target.closest('.palette-row');
    if (row && Number(row.dataset.i) !== index) { index = Number(row.dataset.i); list.querySelectorAll('.palette-row').forEach((r, j) => r.classList.toggle('sel', j === index)); }
  });
  list.addEventListener('mousedown', (e) => {
    e.preventDefault();
    const row = e.target.closest('.palette-row');
    if (!row) return;
    const btn = e.target.closest('[data-act]');
    act(btn ? btn.dataset.act : 'open', items[Number(row.dataset.i)]);
  });
  root.addEventListener('mousedown', (e) => { if (e.target === root) close(); });

  return {
    open, close,
    /** ⌘. while the Recent list is open: pin / unpin the highlighted card. */
    pinSelected() { if (mode !== 'recent') return false; act('pin', items[index]); return true; },
    /** Re-reads the Recent list if it's showing (e.g. after trashed cards were removed). */
    async reload() { if (mode === 'recent') { all = await host.recents(); showRecents(); } },
    toggle(which) { which === mode ? close() : open(which); },
    get isOpen() { return !!mode; },
  };
}
