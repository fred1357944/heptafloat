// bun test/paste.js — paste conversion and property wire values.
import { Node } from 'prosemirror-model';
import { schemaFor } from '../src/schema.js';
import { htmlToDoc, markdownToDoc, plainLooksRich } from '../src/paste.js';
import { fromWire, toWire } from '../src/property-value.js';

let failed = 0;
function assert(cond, msg) {
  if (!cond) { failed++; console.error('FAIL', msg); }
}

function parse(src) {
  const parsed = markdownToDoc(src);
  const { schema, prepared } = schemaFor(parsed.doc);
  const node = Node.fromJSON(schema, prepared);
  node.check();
  return { ...parsed, node };
}

const id = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

assert(plainLooksRich('hello https://example.com'), 'a sentence with a URL is rich');
assert(!plainLooksRich('just a sentence'), 'plain prose stays plain');
assert(plainLooksRich(`see {{card ${id}}}`), 'a card mention is rich');

const mixed = parse(`# Hello\n\nSee {{card ${id}}} and https://example.com/a.\n\n- one\n- **two**\n\n1. three\n\n[ ] todo\n[x] done`);
const types = [];
mixed.node.descendants((n) => { if (n.isBlock || n.type.name === 'card') types.push(n.type.name + (n.attrs?.cardId ? ':' + n.attrs.cardId : '')); });
assert(types.includes('heading'), 'heading');
assert(types.includes('bullet_list_item'), 'bullet');
assert(types.includes('numbered_list_item'), 'numbered');
assert(types.includes('todo_list_item'), 'todo');
assert(types.includes(`card:${id}`), 'card mention');
let linked = false;
mixed.node.descendants((n) => { if (n.isText && n.marks.some((m) => m.type.name === 'link' && m.attrs.href === 'https://example.com/a')) linked = true; });
assert(linked, 'bare URL becomes a link');

const deep = parse(`open heptabase://card/${id} now`);
let deepCard = false;
deep.node.descendants((n) => { if (n.type.name === 'card' && n.attrs.cardId === id) deepCard = true; });
assert(deepCard, 'heptabase:// card link');

const titled = markdownToDoc(`{{card ${id}}}`);
assert(titled.doc.content[0].content[0].type === 'card', 'mention is a card node');

if (typeof DOMParser === 'undefined') {
  assert(htmlToDoc('<p>hi</p>') == null, 'htmlToDoc waits for DOMParser');
} else {
  const html = htmlToDoc(`<p>Hi <hepta-card data-card-id="${id}">Strategy</hepta-card></p>`);
  assert(html.titles[id] === 'Strategy', 'HTML mention keeps its title');
  const { schema, prepared } = schemaFor(html.doc);
  Node.fromJSON(schema, prepared).check();
}

const text = toWire('text', 'hi');
assert(fromWire('text', JSON.parse(text.json)) === 'hi', 'text round-trip');
assert(toWire('text', '  ').json === 'null', 'blank text clears');

const num = toWire('number', '1.5');
assert(num.json === JSON.stringify('1.5'), 'number is a JSON string');
assert(fromWire('number', JSON.parse(num.json)) === '1.5', 'number reads back');
assert(toWire('number', 'nope') == null, 'bad number is refused');

assert(toWire('select', 'opt-1').value === 'opt-1', 'select is an option id');
assert(toWire('select', '').json === 'null', 'empty select clears');
assert(toWire('multiSelect', ['a', 'b']).json === '["a","b"]', 'multiSelect is a JSON array');
assert(toWire('checkbox', true).json === 'true', 'checkbox true');
assert(toWire('checkbox', false).json === 'false', 'checkbox false');

const date = toWire('date', '2026-10-17');
const wireDate = JSON.parse(date.json);
assert(wireDate.start === '2026-10-17T12:00:00.000Z' && wireDate.end == null, 'date is noon UTC');
assert(fromWire('date', wireDate) === '2026-10-17', 'date stays on that calendar day');
assert(toWire('relation', ['x']) == null, 'relation is not edited here');

if (failed) {
  console.error(`${failed} failed`);
  process.exit(1);
}
console.log('paste ok');
