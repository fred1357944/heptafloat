// Tags and the property fields that belong to them, in one panel.
// ⌘T opens it on the tag field; the title-bar info button opens it on the fields.
// Heptabase properties live on tags, so picking a tag is what makes the fields appear.

import { EDITABLE, fromWire, toWire } from './property-value.js';

const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

/**
 * host: {
 *   ensureCard(): Promise<{id}|null>,
 *   tags(): Promise<[{id, name}]>,
 *   properties(id): Promise<{tags: [{tagId, tagName, properties}]}> ,
 *   tagProperties(tagId): Promise<{properties: [{id, name, type, options}]}> ,
 *   addTag(cardId, name), removeTag(cardId, tagId),
 *   setProperty(cardId, propertyId, wire),
 * }
 */
export function createPropsPanel(host) {
  const root = document.createElement('div');
  root.className = 'props-overlay';
  root.innerHTML = `
    <div class="props-panel" role="dialog" aria-label="Tags and properties">
      <div class="props-head"><span>Tags</span><button type="button" class="props-x" title="Close">×</button></div>
      <div class="props-tags"></div>
      <input class="props-input" spellcheck="false" autocomplete="off" placeholder="Add a tag…">
      <div class="props-suggest"></div>
      <div class="props-fields"></div>
    </div>`;
  document.body.append(root);
  const tagsEl = root.querySelector('.props-tags');
  const input = root.querySelector('.props-input');
  const suggest = root.querySelector('.props-suggest');
  const fieldsEl = root.querySelector('.props-fields');

  let cardId = null;
  let allTags = [];
  let applied = [];
  let suggestItems = [];
  let suggestIndex = 0;
  let focusMode = 'tags';
  const timers = new Map();

  function close() {
    root.classList.remove('show');
    suggest.innerHTML = '';
    input.value = '';
    host.onClose?.();
  }

  function renderTags() {
    tagsEl.innerHTML = applied.map((t) =>
      `<button type="button" class="tag-chip" data-id="${esc(t.tagId)}">${esc(t.tagName)}<span class="tag-x" title="Remove tag">×</span></button>`,
    ).join('') || '<span class="props-empty">No tags yet</span>';
  }

  function fieldControl(prop) {
    const value = fromWire(prop.type, prop.value);
    const id = esc(prop.id);
    if (prop.type === 'checkbox') {
      return `<label class="prop-check"><input type="checkbox" data-prop="${id}" ${value ? 'checked' : ''}> ${esc(prop.name)}</label>`;
    }
    if (prop.type === 'select') {
      const options = prop.options || [];
      return `<label class="prop-field"><span>${esc(prop.name)}</span><select data-prop="${id}" data-type="select">
        <option value="">—</option>
        ${options.map((o) => `<option value="${esc(o.id)}" ${o.id === value ? 'selected' : ''}>${esc(o.name)}</option>`).join('')}
      </select></label>`;
    }
    if (prop.type === 'multiSelect') {
      const chosen = new Set(value);
      const options = prop.options || [];
      return `<fieldset class="prop-field" data-prop="${id}" data-type="multiSelect"><legend>${esc(prop.name)}</legend>
        ${options.map((o) => `<label class="prop-check"><input type="checkbox" value="${esc(o.id)}" ${chosen.has(o.id) ? 'checked' : ''}> ${esc(o.name)}</label>`).join('') || '<span class="props-muted">No options</span>'}
      </fieldset>`;
    }
    if (prop.type === 'date') {
      return `<label class="prop-field"><span>${esc(prop.name)}</span><input type="date" data-prop="${id}" data-type="date" value="${esc(value)}"></label>`;
    }
    if (prop.type === 'number') {
      return `<label class="prop-field"><span>${esc(prop.name)}</span><input data-prop="${id}" data-type="number" inputmode="decimal" value="${esc(value)}"></label>`;
    }
    if (prop.type === 'relation' || !EDITABLE.has(prop.type)) {
      const shown = Array.isArray(value) ? `${value.length} linked` : (value || '—');
      return `<label class="prop-field"><span>${esc(prop.name)}</span><input value="${esc(shown)}" disabled></label>`;
    }
    const kind = prop.type === 'url' || prop.type === 'email' ? prop.type : 'text';
    return `<label class="prop-field"><span>${esc(prop.name)}</span><input type="${kind === 'email' ? 'email' : 'text'}" data-prop="${id}" data-type="${esc(prop.type)}" value="${esc(value)}"></label>`;
  }

  function renderFields() {
    const blocks = [];
    for (const tag of applied) {
      const props = tag.properties || [];
      if (!props.length) continue;
      blocks.push(`<div class="prop-group"><div class="prop-tag">${esc(tag.tagName)}</div>${props.map(fieldControl).join('')}</div>`);
    }
    fieldsEl.innerHTML = blocks.join('') || (applied.length ? '<div class="props-muted">This tag has no property fields.</div>' : '');
    if (focusMode === 'fields') fieldsEl.querySelector('input, select')?.focus();
  }

  function renderSuggest() {
    const q = input.value.trim();
    const qLow = q.toLowerCase();
    const have = new Set(applied.map((t) => t.tagId));
    const matches = allTags.filter((t) => !have.has(t.id) && (!qLow || t.name.toLowerCase().includes(qLow))).slice(0, 8);
    suggestItems = matches.map((t) => ({ name: t.name, create: false }));
    const exact = q && allTags.some((t) => t.name.toLowerCase() === qLow);
    if (q && !exact) suggestItems.push({ name: q, create: true });
    suggestIndex = 0;
    suggest.innerHTML = suggestItems.map((it, i) =>
      `<button type="button" class="props-row${i === 0 ? ' sel' : ''}" data-i="${i}">${it.create ? `Create “${esc(it.name)}”` : esc(it.name)}</button>`,
    ).join('');
  }

  async function reload() {
    if (!cardId) return;
    const card = await host.properties(cardId);
    if (card?.error) { fieldsEl.innerHTML = `<div class="props-muted">${esc(card.error)}</div>`; return; }
    const tags = card?.tags || [];
    const merged = [];
    for (const tag of tags) {
      const schema = await host.tagProperties(tag.tagId);
      const cols = new Map((tag.properties || []).map((p) => [p.id, { ...p }]));
      for (const col of schema?.properties || []) {
        const cur = cols.get(col.id) || { id: col.id, name: col.name, type: col.type, value: null };
        cur.options = col.options || cur.options || [];
        cur.type = col.type || cur.type;
        cur.name = col.name || cur.name;
        cols.set(col.id, cur);
      }
      merged.push({ tagId: tag.tagId, tagName: tag.tagName, properties: [...cols.values()] });
    }
    applied = merged;
    renderTags();
    renderFields();
  }

  async function open(focus) {
    focusMode = focus || 'tags';
    const card = await host.ensureCard();
    if (!card) return;
    cardId = card.id;
    root.classList.add('show');
    fieldsEl.innerHTML = '<div class="props-muted">Loading…</div>';
    const listed = await host.tags();
    allTags = listed?.error || !Array.isArray(listed?.tags) ? [] : listed.tags;
    await reload();
    if (focusMode === 'tags') { input.focus(); renderSuggest(); }
  }

  function toggle(focus) {
    if (root.classList.contains('show') && focusMode === (focus || 'tags')) close();
    else open(focus);
  }

  function schedule(propId, type, raw) {
    clearTimeout(timers.get(propId));
    timers.set(propId, setTimeout(async () => {
      const wire = toWire(type, raw);
      if (!cardId) return;
      if (!wire) { if (type === 'number') host.status?.('Enter a number'); return; }
      const r = await host.setProperty(cardId, propId, wire);
      if (r?.error) host.status?.(r.error);
    }, type === 'text' || type === 'title' || type === 'number' || type === 'url' || type === 'phone' || type === 'email' ? 400 : 0));
  }

  async function addNamed(name) {
    const trimmed = name.trim();
    if (!trimmed || !cardId) return;
    input.value = '';
    suggest.innerHTML = '';
    const r = await host.addTag(cardId, trimmed);
    if (r?.error) { host.status?.(r.error); return; }
    await reload();
    input.focus();
  }

  root.querySelector('.props-x').onclick = close;
  root.addEventListener('mousedown', (e) => { if (e.target === root) close(); });
  input.addEventListener('input', renderSuggest);
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); suggestIndex = Math.min(suggestItems.length - 1, suggestIndex + 1); markSuggest(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); suggestIndex = Math.max(0, suggestIndex - 1); markSuggest(); }
    else if (e.key === 'Enter') { e.preventDefault(); const it = suggestItems[suggestIndex]; if (it) addNamed(it.name); }
  });
  suggest.addEventListener('mousedown', (e) => {
    const row = e.target.closest('.props-row');
    if (!row) return;
    e.preventDefault();
    addNamed(suggestItems[Number(row.dataset.i)]?.name || '');
  });
  tagsEl.addEventListener('mousedown', async (e) => {
    const chip = e.target.closest('.tag-chip');
    if (!chip || !cardId) return;
    e.preventDefault();
    const r = await host.removeTag(cardId, chip.dataset.id);
    if (r?.error) { host.status?.(r.error); return; }
    await reload();
  });
  fieldsEl.addEventListener('input', (e) => {
    const multi = e.target.closest('[data-type="multiSelect"]');
    if (multi) {
      const ids = [...multi.querySelectorAll('input:checked')].map((i) => i.value);
      schedule(multi.dataset.prop, 'multiSelect', ids);
      return;
    }
    const el = e.target.closest('[data-prop]');
    if (!el || el.disabled) return;
    const type = el.dataset.type || (el.type === 'checkbox' ? 'checkbox' : 'text');
    const raw = el.type === 'checkbox' ? el.checked : el.value;
    schedule(el.dataset.prop, type, raw);
  });
  fieldsEl.addEventListener('change', (e) => {
    const el = e.target.closest('[data-prop]');
    if (!el) return;
    if (el.dataset.type === 'select' || el.dataset.type === 'date' || el.type === 'checkbox') {
      const type = el.dataset.type || 'checkbox';
      schedule(el.dataset.prop, type, el.type === 'checkbox' ? el.checked : el.value);
    }
  });

  function markSuggest() {
    suggest.querySelectorAll('.props-row').forEach((r, i) => r.classList.toggle('sel', i === suggestIndex));
  }

  return {
    open, close, toggle, reload,
    get isOpen() { return root.classList.contains('show'); },
  };
}
