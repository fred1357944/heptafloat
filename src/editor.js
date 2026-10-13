// Floating card editor. The Swift host exposes `hf` messages for reading, saving, and searching
// through the Heptabase CLI; this file owns the editor, autosave, polling, and which card is shown:
// today's journal by default (rolling over at midnight), or any note/journal opened with ⌘O / ⌘P.

import { Node } from 'prosemirror-model';
import { EditorState, Plugin, Selection, TextSelection } from 'prosemirror-state';
import { EditorView } from 'prosemirror-view';
import { history, undo, redo } from 'prosemirror-history';
import { keymap } from 'prosemirror-keymap';
import { baseKeymap, toggleMark, setBlockType } from 'prosemirror-commands';
import { inputRules, wrappingInputRule, textblockTypeInputRule, InputRule } from 'prosemirror-inputrules';
import { dropCursor } from 'prosemirror-dropcursor';
import { gapCursor } from 'prosemirror-gapcursor';
import { LIST_ITEMS, schemaFor, schemaCovers, serialize, titles, formatDate } from './schema.js';
import { backspaceAtItemStart, enterInItem, lift, setChecked, sink, toggleTodo } from './commands.js';
import { caretPlugin, placeholderPlugin, suggestPlugin, toggleHighlight, toolbarPlugin } from './menus.js';
import { createPalette } from './palette.js';

const SAVE_DELAY = 600;
const POLL_INTERVAL = 3000;

// MARK: host bridge

let nextRequest = 1;
const waiting = new Map();
function call(action, payload = {}) {
  const id = nextRequest++;
  return new Promise((resolve) => {
    waiting.set(id, resolve);
    window.webkit.messageHandlers.hf.postMessage({ ...payload, action, requestId: id });
  });
}
const post = (m) => window.webkit.messageHandlers.hf.postMessage(m);

async function searchCards(query) {
  const r = await call('search', { query });
  return r.results || [];
}

// MARK: which card is shown

const el = (id) => document.getElementById(id);
let view = null;
let current = null;       // { kind: 'journal' | 'note', id }
let followToday = true;   // showing today's journal: switch to the new day at midnight
let baseMd5 = null;       // md5 of the last version we know Heptabase has
let dirty = false;        // local edits not yet saved
let saving = null;        // in-flight save promise
let saveTimer = null;
let lastEdit = 0;
let loadingRemote = false; // set while applying Heptabase's version, so it isn't saved back

function today() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

const isDate = (id) => /^\d{4}-\d{2}-\d{2}$/.test(id || '');

/** Heptabase's card types that HeptaFloat can edit, mapped to how the CLI reads them. */
function editableKind(objectType, id) {
  if (objectType === 'journal' || isDate(id)) return 'journal';
  if (objectType === 'note') return 'note';
  return null;
}

function openInHeptabase(id) {
  if (id) post({ action: 'openURL', url: `heptabase://card/${id}` });
}

/** Opens a card in the floating card if it's a note or journal, otherwise in Heptabase. */
async function openHere(card) {
  let kind = editableKind(card.objectType, card.id);
  if (!kind && !card.objectType) {
    const info = await call('cardType', { id: card.id });
    kind = editableKind(info.cardType, card.id);
  }
  if (!kind) { openInHeptabase(card.id); return; }
  await show({ kind, id: card.id });
}

/** Switches the editor to another card, saving the current one first. */
async function show(target, { focusEnd = true } = {}) {
  if (current && target.kind === current.kind && target.id === current.id) { view?.focus(); return; }
  if (target.kind === 'draft' && current?.kind === 'draft' && !dirty) { view?.focus(); return; }
  if (dirty) await save();
  else if (saving) await saving;
  const r = target.kind === 'draft' ? newDraft() : await call('read', target);
  if (r.error) { status(r.error, { error: true }); return; }
  clearError();
  followToday = target.kind === 'journal' && target.id === today();
  applyRemote(r, { keepSelection: false });
  if (r.kind === 'draft') {
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, 1))); // in the title line
  } else if (focusEnd) {
    view.dispatch(view.state.tr.setSelection(endOfText(view.state.doc)).scrollIntoView());
    el('main').scrollTop = 0;
  }
  view.focus();
  if (r.kind !== 'draft') touchRecent(r);
}

/**
 * ⌘N: a blank card with an empty title line, like Raycast Notes. Nothing is created in Heptabase
 * until you type — the first save creates the note — so leaving it empty leaves no trace.
 */
function newDraft() {
  return {
    kind: 'draft', id: `draft-${Date.now()}`, title: '', contentMd5: null,
    content: JSON.stringify({ type: 'doc', content: [{ type: 'heading', attrs: { level: 1 } }] }),
  };
}

function touchRecent(r) {
  post({
    action: 'touchRecent', id: current.id, objectType: current.kind, title: r.title || '',
    chars: view ? [...view.state.doc.textContent].length : 0,
  });
}

// MARK: shortcuts (remappable; the Swift host sends the user's choices)

const bindings = {
  bold: 'Mod-b', italic: 'Mod-i', underline: 'Mod-u', strike: 'Mod-Shift-x', code: 'Mod-e', link: 'Mod-k',
  highlight: 'Mod-Shift-h', toggleTodo: 'Mod-Enter', paragraph: 'Mod-Alt-0',
  heading1: 'Mod-Alt-1', heading2: 'Mod-Alt-2', heading3: 'Mod-Alt-3',
  newCard: 'Mod-n', search: 'Mod-o', recent: 'Mod-p', today: 'Mod-t', openInHeptabase: 'Mod-Shift-o',
};

/** Named commands, run from the keymap here or from the app's menus. */
function commandFor(name, schema) {
  const n = schema.nodes, m = schema.marks;
  const run = (fn) => () => { fn(); return true; };
  return {
    bold: toggleMark(m.strong), italic: toggleMark(m.em), underline: toggleMark(m.underline),
    strike: toggleMark(m.strike), code: toggleMark(m.code), highlight: toggleHighlight, toggleTodo,
    link: run(() => document.dispatchEvent(new CustomEvent('hf-link'))),
    paragraph: setBlockType(n.paragraph),
    heading1: setBlockType(n.heading, { level: 1 }), heading2: setBlockType(n.heading, { level: 2 }),
    heading3: setBlockType(n.heading, { level: 3 }),
    search: run(() => palette.toggle('search')), recent: run(() => palette.toggle('recent')),
    newCard: run(() => show({ kind: 'draft' })),
    today: run(() => show({ kind: 'journal', id: today() })),
    openInHeptabase: run(() => { if (current?.kind !== 'draft') openInHeptabase(current?.id); }),
  }[name];
}

// MARK: card pickers (⌘P recent, ⌘O search)

const palette = createPalette({
  recents: async () => {
    const cards = (await call('recents')).cards || [];
    const list = cards.map((c) => ({ ...c, title: c.title || (isDate(c.id) ? formatDate(c.id) : 'Untitled'), current: c.id === current?.id }));
    // Today's journal is always one keystroke away, even before it's in the history.
    if (!list.some((c) => c.id === today())) list.push({ id: today(), objectType: 'journal', title: `${formatDate(today())} · Today` });
    return list.sort((a, b) => (b.current ? 1 : 0) - (a.current ? 1 : 0));
  },
  search: searchCards,
  open: (card) => openHere(card),
  openInHeptabase: (card) => openInHeptabase(card.id),
  pin: (card, on) => call('pinCard', { id: card.id, pinned: on }),
  forget: (card) => call('forgetCard', { id: card.id }),
  onClose: () => view?.focus(),
  pickerFor: (e) => {
    const key = keyName(e);
    return key === normalize(bindings.search) ? 'search' : key === normalize(bindings.recent) ? 'recent' : null;
  },
});

/** "Mod-Shift-o" in a fixed modifier order, so keys typed and keys bound compare equal. */
function normalize(name) {
  const parts = name.split('-'), key = parts.pop().toLowerCase();
  return [...parts.sort(), key].join('-');
}
function keyName(e) {
  const mods = [e.altKey && 'Alt', e.ctrlKey && 'Ctrl', e.metaKey && 'Mod', e.shiftKey && 'Shift'].filter(Boolean);
  const key = e.key === 'Enter' ? 'enter' : e.code?.startsWith('Key') ? e.code.slice(3).toLowerCase()
    : e.code?.startsWith('Digit') ? e.code.slice(5) : e.key.toLowerCase();
  return [...mods.sort(), key].join('-');
}

// MARK: mention popup — choose where to open a linked card

const mentionPopup = (() => {
  const pop = document.createElement('div');
  pop.className = 'popup mention-pop';
  document.body.append(pop);
  let chip = null, hideTimer = null, showTimer = null, pinned = false;

  function place(target) {
    const r = target.getBoundingClientRect();
    pop.style.display = 'block';
    const w = pop.offsetWidth, h = pop.offsetHeight;
    pop.style.left = `${Math.max(8, Math.min(r.left, window.innerWidth - w - 8))}px`;
    pop.style.top = `${r.bottom + 6 + h < window.innerHeight - 8 ? r.bottom + 6 : r.top - h - 6}px`;
  }

  function open(target, pin = false) {
    clearTimeout(hideTimer);
    chip = target;
    pinned = pin;
    const { kind, id } = target.dataset;
    const here = kind === 'card' || kind === 'date';
    const label = target.textContent || 'Card';
    pop.innerHTML = `<div class="mp-title">${label.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]))}</div>`
      + (here ? '<button data-where="here"><span>Open here</span><kbd>↵</kbd></button>' : '')
      + '<button data-where="heptabase"><span>Open in Heptabase</span><kbd>⌘ click</kbd></button>';
    place(target);
    pop.dataset.id = id;
    pop.dataset.kind = kind;
  }

  function close() { pop.style.display = 'none'; chip = null; pinned = false; }
  function hideSoon() { clearTimeout(hideTimer); if (!pinned) hideTimer = setTimeout(close, 220); }

  pop.addEventListener('mousedown', (e) => {
    e.preventDefault();
    const b = e.target.closest('[data-where]');
    if (!b) return;
    const { id, kind } = pop.dataset;
    close();
    if (b.dataset.where === 'heptabase') openInHeptabase(id);
    else openHere({ id, objectType: kind === 'date' ? 'journal' : undefined });
  });
  pop.addEventListener('mouseenter', () => clearTimeout(hideTimer));
  pop.addEventListener('mouseleave', hideSoon);

  document.addEventListener('mouseover', (e) => {
    const target = e.target.closest?.('.ProseMirror .chip[data-id]');
    if (!target || !target.dataset.id) return;
    clearTimeout(hideTimer);
    clearTimeout(showTimer);
    if (chip !== target) showTimer = setTimeout(() => open(target), 350);
    target.addEventListener('mouseleave', () => { clearTimeout(showTimer); hideSoon(); }, { once: true });
  });
  document.addEventListener('mousedown', (e) => { if (pinned && !pop.contains(e.target) && e.target !== chip) close(); });
  document.addEventListener('keydown', (e) => {
    if (!pinned || pop.style.display === 'none') return;
    if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); pop.querySelector('[data-where]')?.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })); }
    else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); }
  }, true);

  return { open, close };
})();

// MARK: plugins

function buildPlugins(schema) {
  const n = schema.nodes;
  const rules = [
    wrappingInputRule(/^\s*[-*]\s$/, n.bullet_list_item),
    wrappingInputRule(/^(\d+)\.\s$/, n.numbered_list_item),
    wrappingInputRule(/^\[( |x)?\]\s$/, n.todo_list_item, (match) => ({ checked: match[1] === 'x' })),
    wrappingInputRule(/^\+\s$/, n.toggle_list_item, { folded: false }),
    wrappingInputRule(/^>\s$/, n.blockquote),
    textblockTypeInputRule(/^(#{1,6})\s$/, n.heading, (match) => ({ level: match[1].length })),
    textblockTypeInputRule(/^```$/, n.code_block, { params: '' }),
    new InputRule(/^---$/, (state, _match, start) => {
      const $s = state.doc.resolve(start);
      return state.tr.replaceRangeWith($s.before(), $s.after(), n.horizontal_rule.create())
        .insert($s.before() + 1, n.paragraph.create());
    }),
  ];
  const remappable = Object.fromEntries(Object.entries(bindings).map(([name, key]) => [key, commandFor(name, schema)]));
  return [
    suggestPlugin(searchCards),
    toolbarPlugin((url) => post({ action: 'openURL', url })),
    inputRules({ rules }),
    keymap({
      ...remappable,
      'Mod-z': undo, 'Shift-Mod-z': redo, 'Mod-y': redo,
      Enter: enterInItem,
      Backspace: backspaceAtItemStart,
      Tab: sink, 'Shift-Tab': lift,
      Escape: () => { post({ action: 'hide' }); return true; },
    }),
    keymap({ ...baseKeymap, Tab: () => true, 'Shift-Tab': () => true }),
    history(),
    dropCursor({ color: 'var(--active-item)', width: 2 }),
    gapCursor(),
    placeholderPlugin(),
    caretPlugin(el('main')),
    new Plugin({ view: () => ({ update: (v, prev) => { if (!v.state.doc.eq(prev.doc)) onLocalChange(); } }) }),
  ];
}

// Marker clicks: tick todos, fold toggles and bullets with children.
class ItemView {
  constructor(node, view, getPos) {
    this.dom = document.createElement('div');
    this.marker = document.createElement('span');
    this.marker.className = 'mk';
    this.marker.contentEditable = 'false';
    this.contentDOM = document.createElement('div');
    this.contentDOM.className = 'bd';
    this.due = document.createElement('span');
    this.due.className = 'due';
    this.due.contentEditable = 'false';
    this.dom.append(this.marker, this.contentDOM, this.due);
    this.marker.addEventListener('mousedown', (e) => {
      e.preventDefault();
      const pos = getPos(), cur = view.state.doc.nodeAt(pos);
      if (!cur) return;
      if (cur.type.name === 'todo_list_item') view.dispatch(setChecked(view.state.tr, pos, cur, !cur.attrs.checked));
      else if (cur.childCount > 1 || cur.type.name === 'toggle_list_item') view.dispatch(view.state.tr.setNodeAttribute(pos, 'folded', !cur.attrs.folded));
    });
    this.update(node);
  }
  update(node) {
    if (this.node && node.type !== this.node.type) return false;
    this.node = node;
    const kind = node.type.name.replace('_list_item', '');
    const due = kind === 'todo' && node.attrs.dueDate ? dueLabel(node.attrs.dueDate) : null;
    this.dom.className = `li ${kind}${node.attrs.checked ? ' done' : ''}${node.attrs.folded ? ' folded' : ''}${node.childCount > 1 ? ' parent' : ''}${due ? ' has-due' : ''}`;
    this.dom.dataset.format = node.attrs.format ?? 0;
    this.due.textContent = due?.text ?? '';
    this.due.classList.toggle('overdue', !!due?.overdue && !node.attrs.checked);
    return true;
  }
  ignoreMutation(m) { return [this.marker, this.due].some((d) => m.target === d || d.contains(m.target)); }
}

/** "Today", "Tomorrow", "Yesterday", or "Oct 14", the way Heptabase labels to-do due dates. */
function dueLabel(iso) {
  const [y, m, d] = iso.split('-').map(Number);
  if (!y) return null;
  const due = new Date(y, m - 1, d), now = new Date();
  const days = Math.round((due - new Date(now.getFullYear(), now.getMonth(), now.getDate())) / 864e5);
  const text = days === 0 ? 'Today' : days === 1 ? 'Tomorrow' : days === -1 ? 'Yesterday'
    : due.toLocaleDateString('en-US', { month: 'short', day: 'numeric', ...(y !== now.getFullYear() && { year: 'numeric' }) });
  return { text, overdue: days < 0 };
}

/** Cursor at the end of the last line of text, rather than selecting a trailing embed or image. */
function endOfText(doc) {
  return Selection.findFrom(doc.resolve(doc.content.size), -1, true) ?? Selection.atEnd(doc);
}

// MARK: chrome

/** Footer status. Errors stay until things work again; the full text is in the tooltip. */
function status(text, { sticky = false, error = false } = {}) {
  const s = el('status');
  s.textContent = text;
  s.title = text;
  s.classList.toggle('show', !!text);
  s.classList.toggle('error', error);
  clearTimeout(status.t);
  if (text && !sticky && !error) status.t = setTimeout(() => s.classList.remove('show'), 1600);
}
function clearError() {
  if (el('status').classList.contains('error')) status('');
}

function updateCount() {
  const doc = view?.state.doc;
  const chars = doc ? [...doc.textContent].length : 0;
  el('count').textContent = `${chars.toLocaleString()} characters`;
  let open = 0;
  doc?.descendants((n) => { if (n.type.name === 'todo_list_item' && !n.attrs.checked) open++; });
  el('todocount').textContent = `${open} todo${open === 1 ? '' : 's'}`;
  el('todos').classList.toggle('show', open > 0);
}

/** Journals get Heptabase's weekday + date title. Notes show their title only when it isn't
 *  already the first line (web clips keep it separately). */
function setTitle(result, json) {
  const title = result.title || (isDate(result.id) ? formatDate(result.id) : 'Untitled');
  el('title').textContent = title;
  if (result.kind === 'draft') {
    el('weekday').textContent = '';
    el('jtitle').hidden = true; // the title line is in the card itself
  } else if (result.kind === 'journal') {
    const [y, m, d] = result.id.split('-').map(Number);
    el('weekday').textContent = new Date(y, m - 1, d).toLocaleDateString('en-US', { weekday: 'long' });
    el('bigtitle').textContent = title;
    el('jtitle').hidden = false;
  } else {
    const first = json.content?.[0];
    const firstText = (function text(n) { return n?.text ?? (n?.content || []).map(text).join(''); })(first).trim();
    const duplicate = first?.type === 'heading' && firstText === title.trim();
    el('weekday').textContent = '';
    el('bigtitle').textContent = title;
    el('jtitle').hidden = duplicate;
  }
  document.body.dataset.kind = result.kind;
}

// MARK: load / save / sync

function load(result, { keepSelection } = {}) {
  current = { kind: result.kind, id: result.id };
  baseMd5 = result.contentMd5;
  let json;
  try { json = JSON.parse(result.content); } catch { json = { type: 'doc', content: [{ type: 'paragraph' }] }; }
  if (!json.content?.length) json.content = [{ type: 'paragraph' }];
  setTitle(result, json);

  if (view && keepSelection && schemaCovers(view.state.schema, json)) {
    const { prepared } = schemaFor(json);
    const doc = Node.fromJSON(view.state.schema, prepared);
    const tr = view.state.tr.replaceWith(0, view.state.doc.content.size, doc.content).setMeta('addToHistory', false);
    const max = tr.doc.content.size;
    const { from, to } = view.state.selection;
    try { tr.setSelection(TextSelection.create(tr.doc, Math.min(from, max), Math.min(to, max))); } catch { /* keep mapped selection */ }
    view.dispatch(tr);
  } else {
    const { schema, prepared } = schemaFor(json);
    const state = EditorState.create({ doc: Node.fromJSON(schema, prepared), plugins: buildPlugins(schema) });
    if (view) view.updateState(state);
    else view = new EditorView(el('main'), {
      state,
      nodeViews: Object.fromEntries(LIST_ITEMS.map((t) => [t, (n, v, g) => new ItemView(n, v, g)])),
      // Keep the caret clear of the faded header and footer.
      scrollThreshold: { top: 64, bottom: 72, left: 0, right: 0 },
      scrollMargin: { top: 64, bottom: 72, left: 0, right: 0 },
      // Pasted or dropped images are imported into Heptabase, then inserted like Heptabase does.
      handlePaste(_v, event) {
        const files = [...(event.clipboardData?.items || [])].filter((i) => i.kind === 'file' && i.type.startsWith('image/')).map((i) => i.getAsFile());
        if (!files.length) return false;
        event.preventDefault();
        files.forEach((f) => insertImage(f));
        return true;
      },
      handleDrop(_v, event) {
        const files = [...(event.dataTransfer?.files || [])].filter((f) => f.type.startsWith('image/'));
        if (!files.length) return false;
        event.preventDefault();
        const pos = view.posAtCoords({ left: event.clientX, top: event.clientY })?.pos;
        files.forEach((f) => insertImage(f, pos));
        return true;
      },
      handleClickOn(_v, _pos, _node, _nodePos, event) {
        const chip = event.target.closest('.chip[data-id]');
        if (chip && chip.dataset.id) {
          if (event.metaKey) openInHeptabase(chip.dataset.id);
          else mentionPopup.open(chip, true);
          return true;
        }
        const bookmark = event.target.closest('a.bookmark[href]');
        if (bookmark) { post({ action: 'openURL', url: bookmark.href }); return true; }
        return false;
      },
    });
  }
  dirty = false;
  updateCount();
}

/** Uploads an image file to Heptabase (via the CLI) and inserts an image block that points to it. */
async function insertImage(file, pos) {
  status('Adding image…', { sticky: true });
  const data = await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(',')[1]);
    reader.onerror = reject;
    reader.readAsDataURL(file);
  });
  const ext = (file.type.split('/')[1] || 'png').replace('jpeg', 'jpg');
  const name = file.name && file.name !== 'image.png' ? file.name : `Pasted image ${new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-')}.${ext}`;
  const r = await call('importImage', { data, name });
  if (r.error || !r.fileId) { status(`Couldn't add image — ${r.error || 'unknown error'}`, { error: true }); return; }
  const node = view.state.schema.nodes.image.create({
    src: null, fileId: r.fileId, originalWidth: r.width ?? null, originalHeight: r.height ?? null, alignment: 'center',
  });
  let tr;
  if (pos == null) tr = view.state.tr.replaceSelectionWith(node);
  else {
    const $pos = view.state.doc.resolve(Math.min(pos, view.state.doc.content.size));
    tr = view.state.tr.insert($pos.depth >= 1 ? $pos.after(1) : $pos.pos, node); // dropped: after the block under the pointer
  }
  view.dispatch(tr.scrollIntoView());
  status('Image added');
}

function onLocalChange() {
  updateCount();
  if (loadingRemote) return;
  dirty = true;
  lastEdit = Date.now();
  clearTimeout(saveTimer);
  saveTimer = setTimeout(save, SAVE_DELAY);
}

async function save() {
  clearTimeout(saveTimer);
  if (saving) { await saving; if (!dirty) return; }
  if (!dirty || !view || !current) return;
  const doc = view.state.doc, target = { ...current };
  const content = JSON.stringify(serialize(doc));
  dirty = false;
  status('Saving…', { sticky: true });
  // A ⌘N draft becomes a real note on its first save.
  const request = target.kind === 'draft'
    ? call('createNote', { title: doc.firstChild?.textContent.trim() || 'Untitled', content })
    : call('save', { ...target, content, md5: baseMd5 });
  saving = request.then((r) => {
    saving = null;
    const stillShown = current && current.id === target.id;
    if (!r.error) {
      if (stillShown && target.kind === 'draft') {
        current = { kind: 'note', id: r.current.id };
        el('title').textContent = r.current.title || 'Untitled';
        document.body.dataset.kind = 'note';
      }
      if (stillShown) { baseMd5 = r.current.contentMd5; adoptIds(doc, r.current); touchRecent(r.current); }
      clearError();
      status('Saved');
    } else if (!r.current) {
      // Heptabase unreachable: keep the edit and try again.
      dirty = stillShown;
      status(`Not saved — ${r.error}`, { error: true });
      if (stillShown) saveTimer = setTimeout(save, 3000);
    } else if (stillShown && r.current.contentMd5 !== baseMd5) {
      // Edited in Heptabase meanwhile. Take their version unless we've typed since.
      baseMd5 = r.current.contentMd5;
      if (dirty) save();
      else { status('Changed in Heptabase — reloaded'); applyRemote(r.current); }
    } else {
      dirty = stillShown;
      status(`Not saved — ${r.error}`, { error: true });
    }
  });
  return saving;
}

/** After a save the CLI assigns ids to new blocks; copy them in so later saves keep them. */
function adoptIds(savedDoc, cur) {
  if (!view || !view.state.doc.eq(savedDoc)) return;
  let remote;
  try { remote = JSON.parse(cur.content); } catch { return; }
  const tr = view.state.tr;
  const walk = (node, json, pos) => {
    if (!json || json.type !== node.type.name) return;
    if ('id' in node.attrs && node.attrs.id == null && json.attrs?.id) tr.setNodeAttribute(pos, 'id', json.attrs.id);
    if (node.isTextblock || (json.content || []).length !== node.childCount) return;
    node.forEach((child, off, i) => walk(child, json.content[i], pos + 1 + off));
  };
  savedDoc.forEach((child, off, i) => walk(child, remote.content?.[i], off));
  if (tr.docChanged) {
    loadingRemote = true;
    view.dispatch(tr.setMeta('addToHistory', false));
    loadingRemote = false;
  }
}

function applyRemote(result, opts = { keepSelection: true }) {
  if (!result) return;
  loadingRemote = true;
  load(result, opts);
  loadingRemote = false;
}

async function poll() {
  if (!current || current.kind === 'draft' || dirty || saving || Date.now() - lastEdit < 1500) return;
  // Showing today's journal: follow the date across midnight.
  if (followToday && current.id !== today()) { show({ kind: 'journal', id: today() }); return; }
  const target = { ...current };
  const r = await call('read', target);
  if (r.error) { status(r.error, { error: true }); return; }
  clearError();
  if (dirty || saving || current.id !== target.id) return;
  if (r.contentMd5 !== baseMd5) applyRemote(r);
}

window.hf = {
  reply(requestId, result) { waiting.get(requestId)?.(result); waiting.delete(requestId); },
  setScale(s) { document.documentElement.style.setProperty('--scale', s); if (view) view.dispatch(view.state.tr); },
  setPinned(on) { document.body.classList.toggle('pinned', on); },
  shown() { view?.focus(); poll(); },
  async flush() { if (dirty) await save(); else if (saving) await saving; return true; },
  undo() { if (view) { undo(view.state, view.dispatch); view.focus(); } },
  redo() { if (view) { redo(view.state, view.dispatch); view.focus(); } },
  titles(map) {
    Object.assign(titles, map);
    for (const c of document.querySelectorAll('.chip[data-id]')) if (map[c.dataset.id]) c.textContent = map[c.dataset.id];
  },
  /** { bold: "Mod-b", … } from Settings → Shortcuts. */
  setShortcuts(map) {
    Object.assign(bindings, map);
    if (view) view.updateState(view.state.reconfigure({ plugins: buildPlugins(view.state.schema) }));
  },
  /** Runs a named command from the app menus. */
  command(name) {
    if (!view) return;
    const cmd = commandFor(name, view.state.schema);
    if (cmd) cmd(view.state, view.dispatch, view);
    if (!palette.isOpen) view.focus();
  },
};

el('close').onclick = () => post({ action: 'hide' });
el('pin').onclick = () => post({ action: 'togglePin' });
el('open').onclick = () => openInHeptabase(current?.id);

(async () => {
  const r = await call('read', { kind: 'journal', id: today() });
  if (r.error) {
    status(r.error, { error: true });
    // Keep trying until Heptabase is reachable, then start normally.
    setTimeout(() => location.reload(), POLL_INTERVAL * 2);
    return;
  }
  followToday = true;
  applyRemote(r, { keepSelection: false });
  view.dispatch(view.state.tr.setSelection(endOfText(view.state.doc)));
  view.focus();
  touchRecent(r);
  // Start at the end of the journal, ready to write; wait for Inter so the measurement holds.
  document.fonts.ready.then(() => view.dispatch(view.state.tr.scrollIntoView()));
  setInterval(poll, POLL_INTERVAL);
  window.addEventListener('focus', poll);
  // Mark images Heptabase couldn't hand over (e.g. not synced to this Mac yet) instead of a broken icon.
  document.addEventListener('error', (e) => {
    if (e.target.tagName === 'IMG' && e.target.closest('.ProseMirror')) e.target.classList.add('missing');
  }, true);
})();
