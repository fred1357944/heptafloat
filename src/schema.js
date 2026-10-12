// ProseMirror schema mirroring Heptabase's card content schema.
//
// Saving replaces the whole journal, so round-tripping must be lossless. Every attr defaults to
// `undefined` (dropped by JSON.stringify), attr keys found in the incoming document are added to
// the schema, and node types we don't know are kept verbatim as opaque atoms.

import { Schema } from 'prosemirror-model';

const UNSET = { default: undefined };
const attrs = (keys) => Object.fromEntries(keys.map((k) => [k, UNSET]));

export const LIST_ITEMS = ['bullet_list_item', 'numbered_list_item', 'todo_list_item', 'toggle_list_item'];
const TEXTBLOCKS = new Set(['paragraph', 'heading']);

export const titles = {}; // id → title, filled in by the host for mention chips

// `kind` doubles as the deep-link route: heptabase://<kind>/<id>
const chip = (kind, label, id) =>
  ['span', { class: `chip ${kind}`, 'data-kind': kind, 'data-id': id ?? '', contenteditable: 'false' }, label];

export function formatDate(iso) {
  const [y, m, d] = String(iso).split('-').map(Number);
  if (!y || !m || !d) return String(iso);
  return new Date(y, m - 1, d).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}
const inlineAtom = (keys, toDOM) => ({ group: 'inline', inline: true, atom: true, attrs: attrs(keys), toDOM });
const blockAtom = (keys, toDOM) => ({ group: 'block', atom: true, selectable: true, attrs: attrs(keys), toDOM });
const listItem = (name, keys, first = 'paragraph') => ({
  group: 'block', content: `${first} block*`, defining: true, attrs: attrs(['id', ...keys]),
  toDOM: () => ['div', { class: `li ${name}` }, ['span', { class: 'mk', contenteditable: 'false' }], ['div', { class: 'bd' }, 0]],
});
const mediaChip = (icon, label) => (n) =>
  n.attrs.url ? ['a', { class: 'block-chip', href: n.attrs.url }, `${icon} ${n.attrs.url}`] : ['div', { class: 'block-chip' }, `${icon} ${label}`];

const BASE_NODES = {
  doc: { content: 'block+' },
  text: { group: 'inline' },
  paragraph: { group: 'block', content: 'inline*', attrs: attrs(['id']), toDOM: () => ['p', 0] },
  heading: { group: 'block', content: 'inline*', defining: true, attrs: attrs(['id', 'level']),
    toDOM: (n) => [`h${n.attrs.level || 1}`, 0] },
  blockquote: { group: 'block', content: 'block+', defining: true, attrs: attrs(['id']), toDOM: () => ['blockquote', 0] },
  horizontal_rule: { group: 'block', attrs: attrs(['id']), toDOM: () => ['div', { class: 'hr' }, ['hr']] },
  code_block: { group: 'block', content: 'text*', marks: '', code: true, defining: true, attrs: attrs(['id', 'params']),
    toDOM: () => ['pre', ['code', 0]] },
  math_display: { group: 'block', content: 'text*', marks: '', code: true, attrs: attrs(['id']), toDOM: () => ['div', { class: 'math' }, 0] },
  bullet_list_item: listItem('bullet', ['folded', 'format']),
  numbered_list_item: listItem('numbered', ['order', 'format']),
  todo_list_item: listItem('todo', ['checked', 'dueDate', 'lastCheckedTime', 'lastUpdatedTime']),
  toggle_list_item: listItem('toggle', ['folded'], '(paragraph | heading)'),
  table: { group: 'block', content: 'table_row+', isolating: true, attrs: attrs(['id', 'hasRowHeader', 'hasColumnHeader']),
    toDOM: () => ['table', ['tbody', 0]] },
  table_row: { content: '(table_cell | table_header)*', attrs: attrs(['id']), toDOM: () => ['tr', 0] },
  table_cell: { content: 'block+', isolating: true,
    attrs: attrs(['id', 'colspan', 'rowspan', 'colwidth', 'backgroundColor', 'textColor']),
    toDOM: (n) => ['td', { colspan: n.attrs.colspan ?? 1, rowspan: n.attrs.rowspan ?? 1 }, 0] },
  table_header: { content: 'block+', isolating: true,
    attrs: attrs(['id', 'colspan', 'rowspan', 'colwidth', 'backgroundColor', 'textColor']),
    toDOM: (n) => ['th', { colspan: n.attrs.colspan ?? 1, rowspan: n.attrs.rowspan ?? 1 }, 0] },
  image: blockAtom(['id', 'src', 'fileId', 'alt', 'title', 'width', 'originalHeight', 'originalWidth', 'alignment', 'reference'],
    (n) => (n.attrs.src ? ['img', { src: n.attrs.src }] : ['div', { class: 'block-chip' }, '🖼 Image'])),
  video: blockAtom(['id', 'fileId', 'url', 'width', 'alignment', 'originalWidth', 'originalHeight', 'reference', 'source'], mediaChip('▶', 'Video')),
  audio: blockAtom(['id', 'url', 'fileId', 'reference'], mediaChip('♪', 'Audio')),
  file: blockAtom(['id', 'fileId', 'url', 'reference'], mediaChip('📎', 'File')),
  bookmark: blockAtom(['id', 'url', 'title', 'description', 'thumbnailUrl', 'faviconUrl', 'siteName', 'lastUpdatedTime'],
    (n) => ['a', { class: 'block-chip', href: n.attrs.url }, n.attrs.title || n.attrs.url]),
  embed: blockAtom(['id', 'objectType', 'objectId', 'originalWidth', 'originalHeight', 'width', 'alignment'],
    (n) => ['div', { class: 'block-chip' }, chip('card', titles[n.attrs.objectId] || (n.attrs.objectType === 'journal' ? formatDate(n.attrs.objectId) : n.attrs.objectType), n.attrs.objectId)]),
  mention: blockAtom(['id', 'objectType', 'objectId'],
    (n) => ['p', chip('card', titles[n.attrs.objectId] || (n.attrs.objectType === 'journal' ? formatDate(n.attrs.objectId) : n.attrs.objectType), n.attrs.objectId)]),
  hard_break: { group: 'inline', inline: true, selectable: false, toDOM: () => ['br'] },
  math_inline: { group: 'inline', inline: true, content: 'text*', marks: '', toDOM: () => ['code', { class: 'math-inline' }, 0] },
  date: inlineAtom(['date'], (n) => chip('date', formatDate(n.attrs.date), n.attrs.date)),
  web: inlineAtom(['url', 'title'], (n) => ['a', { href: n.attrs.url, class: 'chip' }, n.attrs.title || n.attrs.url]),
  card: inlineAtom(['cardId'], (n) => chip('card', titles[n.attrs.cardId] || 'Card', n.attrs.cardId)),
  image_card: inlineAtom(['cardId'], (n) => chip('card', titles[n.attrs.cardId] || 'Image', n.attrs.cardId)),
  video_card: inlineAtom(['cardId'], (n) => chip('card', titles[n.attrs.cardId] || 'Video', n.attrs.cardId)),
  audio_card: inlineAtom(['cardId'], (n) => chip('card', titles[n.attrs.cardId] || 'Audio', n.attrs.cardId)),
  pdf_card: inlineAtom(['pdfCardId'], (n) => chip('card', titles[n.attrs.pdfCardId] || 'PDF', n.attrs.pdfCardId)),
  whiteboard: inlineAtom(['whiteboardId'], (n) => chip('whiteboard', titles[n.attrs.whiteboardId] || 'Whiteboard', n.attrs.whiteboardId)),
  section: inlineAtom(['sectionId'], (n) => chip('section', 'Section', n.attrs.sectionId)),
  tag: inlineAtom(['tagId'], (n) => chip('tag', titles[n.attrs.tagId] || 'Tag', n.attrs.tagId)),
  highlight_element: inlineAtom(['highlightElementId'], (n) => chip('card', titles[n.attrs.highlightElementId] || 'Highlight', n.attrs.highlightElementId)),
  web_card: inlineAtom(['webCardId'], (n) => chip('card', titles[n.attrs.webCardId] || 'Web card', n.attrs.webCardId)),
  chat: inlineAtom(['chatId', 'chatMessageId', 'quotedChatMessageId'], (n) => chip('chat', 'Chat', n.attrs.chatId)),
};

const BASE_MARKS = {
  link: { attrs: attrs(['href', 'title', 'data-internal-href', 'edited']), inclusive: false,
    toDOM: (m) => ['a', { href: m.attrs.href, title: m.attrs.href }, 0] },
  strong: { toDOM: () => ['strong', 0] },
  em: { toDOM: () => ['em', 0] },
  underline: { toDOM: () => ['u', 0] },
  strike: { toDOM: () => ['s', 0] },
  code: { toDOM: () => ['code', 0] },
  color: { attrs: attrs(['type', 'color']),
    toDOM: (m) => ['span', { class: `c-${m.attrs.type || 'text'}-${m.attrs.color}` }, 0] },
};

const RAW = '__raw';

/** Builds a schema that can hold `docJSON` exactly; returns it with the doc prepared for parsing. */
export function schemaFor(docJSON) {
  const nodeKeys = {}, markKeys = {}, unknown = {};
  const prepare = (n, parentType) => {
    if (!n || typeof n !== 'object') return n;
    if (!BASE_NODES[n.type]) {
      unknown[n.type] = TEXTBLOCKS.has(parentType) ? 'inline' : 'block';
      return { type: n.type, attrs: { [RAW]: n } };
    }
    for (const k of Object.keys(n.attrs || {})) (nodeKeys[n.type] ||= new Set()).add(k);
    for (const m of n.marks || []) {
      markKeys[m.type] ||= new Set();
      for (const k of Object.keys(m.attrs || {})) markKeys[m.type].add(k);
    }
    return n.content ? { ...n, content: n.content.map((c) => prepare(c, n.type)) } : n;
  };
  const prepared = prepare(docJSON);

  const nodes = {};
  for (const [name, spec] of Object.entries(BASE_NODES)) {
    const extra = [...(nodeKeys[name] || [])].filter((k) => !(spec.attrs && k in spec.attrs));
    nodes[name] = extra.length ? { ...spec, attrs: { ...spec.attrs, ...attrs(extra) } } : spec;
  }
  for (const [name, where] of Object.entries(unknown)) {
    const spec = where === 'inline' ? inlineAtom([RAW], () => chip('raw', name)) : blockAtom([RAW], () => ['div', { class: 'block-chip' }, name]);
    nodes[name] = spec;
  }
  const marks = {};
  for (const [name, spec] of Object.entries(BASE_MARKS)) {
    const extra = [...(markKeys[name] || [])].filter((k) => !(spec.attrs && k in spec.attrs));
    marks[name] = extra.length ? { ...spec, attrs: { ...spec.attrs, ...attrs(extra) } } : spec;
  }
  for (const [name, keys] of Object.entries(markKeys)) {
    if (!marks[name]) marks[name] = { attrs: attrs([...keys]), toDOM: () => ['span', 0] };
  }
  const schema = new Schema({ nodes, marks });
  schema.signature = JSON.stringify([Object.keys(nodes).map((n) => [n, Object.keys(nodes[n].attrs || {})]),
    Object.keys(marks).map((m) => [m, Object.keys(marks[m].attrs || {})])]);
  return { schema, prepared };
}

/** Whether `schema` can represent `docJSON` without changes. */
export function schemaCovers(schema, docJSON) {
  return schemaFor(docJSON).schema.signature === schema.signature;
}

/** Serializes a ProseMirror doc back into Heptabase JSON. */
export function serialize(doc) {
  const seen = new Set();
  const restore = (n) => {
    if (n.attrs && RAW in n.attrs) return n.attrs[RAW];
    if (n.attrs && typeof n.attrs.id === 'string') {
      // Splitting a block copies its id; the CLI backfills ids we leave null.
      if (seen.has(n.attrs.id)) n.attrs = { ...n.attrs, id: null };
      else seen.add(n.attrs.id);
    }
    if (n.content) n.content = n.content.map(restore);
    return n;
  };
  return restore(doc.toJSON());
}
