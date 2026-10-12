// Floating journal editor. The Swift host exposes `hf` messages for reading, saving, and searching
// through the Heptabase CLI; this file owns the editor, autosave, polling, and day rollover.

import { Node } from 'prosemirror-model';
import { EditorState, Plugin, Selection, TextSelection } from 'prosemirror-state';
import { EditorView } from 'prosemirror-view';
import { history, undo, redo } from 'prosemirror-history';
import { keymap } from 'prosemirror-keymap';
import { baseKeymap, toggleMark, setBlockType } from 'prosemirror-commands';
import { inputRules, wrappingInputRule, textblockTypeInputRule, InputRule } from 'prosemirror-inputrules';
import { dropCursor } from 'prosemirror-dropcursor';
import { gapCursor } from 'prosemirror-gapcursor';
import { LIST_ITEMS, schemaFor, schemaCovers, serialize, titles } from './schema.js';
import { backspaceAtItemStart, enterInItem, lift, setChecked, sink, toggleTodo } from './commands.js';
import { placeholderPlugin, suggestPlugin, toolbarPlugin } from './menus.js';

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

/** Opens a mention in Heptabase. Journals live at heptabase://card/<date>. */
function openInHeptabase(kind, id) {
  if (!id) return;
  const route = kind === 'date' ? 'card' : kind;
  post({ action: 'openURL', url: `heptabase://${route}/${id}` });
}

// MARK: plugins

function buildPlugins(schema) {
  const n = schema.nodes, m = schema.marks;
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
  return [
    suggestPlugin(searchCards),
    toolbarPlugin((url) => post({ action: 'openURL', url })),
    inputRules({ rules }),
    keymap({
      'Mod-z': undo, 'Shift-Mod-z': redo, 'Mod-y': redo,
      'Mod-b': toggleMark(m.strong), 'Mod-i': toggleMark(m.em), 'Mod-u': toggleMark(m.underline),
      'Mod-Shift-x': toggleMark(m.strike), 'Mod-e': toggleMark(m.code),
      'Mod-Enter': toggleTodo,
      'Mod-Alt-0': setBlockType(n.paragraph),
      'Mod-Alt-1': setBlockType(n.heading, { level: 1 }),
      'Mod-Alt-2': setBlockType(n.heading, { level: 2 }),
      'Mod-Alt-3': setBlockType(n.heading, { level: 3 }),
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
    this.dom.append(this.marker, this.contentDOM);
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
    this.dom.className = `li ${kind}${node.attrs.checked ? ' done' : ''}${node.attrs.folded ? ' folded' : ''}${node.childCount > 1 ? ' parent' : ''}`;
    this.dom.dataset.format = node.attrs.format ?? 0;
    return true;
  }
  ignoreMutation(m) { return m.target === this.marker || this.marker.contains(m.target); }
}

// MARK: state

const el = (id) => document.getElementById(id);
let view = null;
let date = null;          // journal date being shown
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

function status(text, sticky = false) {
  const s = el('status');
  s.textContent = text;
  s.classList.toggle('show', !!text);
  clearTimeout(status.t);
  if (text && !sticky) status.t = setTimeout(() => s.classList.remove('show'), 1600);
}

function updateCount() {
  const chars = view ? [...view.state.doc.textContent].length : 0;
  el('count').textContent = `${chars.toLocaleString()} characters`;
}

function load(result, { keepSelection } = {}) {
  date = result.date;
  baseMd5 = result.contentMd5;
  el('title').textContent = result.title || date;
  let json;
  try { json = JSON.parse(result.content); } catch { json = { type: 'doc', content: [{ type: 'paragraph' }] }; }
  if (!json.content?.length) json.content = [{ type: 'paragraph' }];

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
      handleClickOn(_v, _pos, _node, _nodePos, event) {
        const chip = event.target.closest('.chip[data-id]');
        if (chip && chip.dataset.id) { openInHeptabase(chip.dataset.kind, chip.dataset.id); return true; }
        return false;
      },
    });
  }
  dirty = false;
  updateCount();
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
  if (!dirty || !view) return;
  const doc = view.state.doc;
  const content = JSON.stringify(serialize(doc));
  dirty = false;
  status('Saving…', true);
  saving = call('save', { date, content, md5: baseMd5 }).then((r) => {
    saving = null;
    if (!r.error) {
      baseMd5 = r.current.contentMd5;
      adoptIds(doc, r.current);
      status('Saved');
    } else if (!r.current) {
      // Heptabase unreachable: keep the edit and try again.
      dirty = true;
      status('Not saved — is Heptabase running?', true);
      saveTimer = setTimeout(save, 3000);
    } else if (r.current.contentMd5 !== baseMd5) {
      // Edited in Heptabase meanwhile. Take their version unless we've typed since.
      baseMd5 = r.current.contentMd5;
      if (dirty) save();
      else { status('Changed in Heptabase — reloaded'); applyRemote(r.current); }
    } else {
      dirty = true;
      status(`Not saved: ${r.error}`, true);
    }
  });
  return saving;
}

/** After a save the CLI assigns ids to new blocks; copy them in so later saves keep them. */
function adoptIds(savedDoc, current) {
  if (!view || !view.state.doc.eq(savedDoc)) return;
  let remote;
  try { remote = JSON.parse(current.content); } catch { return; }
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
  const want = today();
  if (dirty || saving || Date.now() - lastEdit < 1500) return;
  const r = await call('read', { date: want });
  if (r.error) { status(r.error, true); return; }
  if (dirty || saving) return;
  if (want !== date) {
    applyRemote(r, { keepSelection: false });
    view.dispatch(view.state.tr.setSelection(Selection.atEnd(view.state.doc)));
  } else if (r.contentMd5 !== baseMd5) applyRemote(r);
}

window.hf = {
  reply(requestId, result) { waiting.get(requestId)?.(result); waiting.delete(requestId); },
  setScale(s) { document.documentElement.style.setProperty('--scale', s); },
  setPinned(on) { document.body.classList.toggle('pinned', on); },
  shown() { view?.focus(); poll(); },
  async flush() { if (dirty) await save(); else if (saving) await saving; return true; },
  titles(map) {
    Object.assign(titles, map);
    for (const c of document.querySelectorAll('.chip[data-id]')) if (map[c.dataset.id]) c.textContent = map[c.dataset.id];
  },
};

el('close').onclick = () => post({ action: 'hide' });
el('pin').onclick = () => post({ action: 'togglePin' });
el('open').onclick = () => openInHeptabase('card', date);

(async () => {
  const r = await call('read', { date: today() });
  if (r.error) { status(r.error, true); el('main').innerHTML = `<div class="error">${r.error}</div>`; return; }
  applyRemote(r, { keepSelection: false });
  view.dispatch(view.state.tr.setSelection(Selection.atEnd(view.state.doc)));
  view.focus();
  // Start at the end of the journal, ready to write; wait for Inter so the measurement holds.
  document.fonts.ready.then(() => view.dispatch(view.state.tr.scrollIntoView()));
  setInterval(poll, POLL_INTERVAL);
  window.addEventListener('focus', poll);
})();
