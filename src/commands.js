// Editing commands for Heptabase's flat list items: each item holds its line plus nested blocks.

import { TextSelection } from 'prosemirror-state';
import { setBlockType, wrapIn } from 'prosemirror-commands';
import { LIST_ITEMS } from './schema.js';

export const isItem = (n) => LIST_ITEMS.includes(n.type.name);

/** Cursor is in the first child (the "line") of a list item. Returns the item depth or -1. */
export function itemLineDepth($pos) {
  return $pos.depth >= 2 && isItem($pos.node(-1)) && $pos.index(-1) === 0 ? $pos.depth - 1 : -1;
}

function freshAttrs(type, from) {
  switch (type.name) {
    case 'todo_list_item': return { checked: false };
    case 'toggle_list_item': return { folded: false };
    default: return { format: from?.type === type ? from.attrs.format : undefined };
  }
}

export function sink(state, dispatch) {
  const { $from, $to } = state.selection;
  const d = itemLineDepth($from);
  if (d < 0) return false;
  const idx = $from.index(d - 1);
  const prev = idx > 0 && $from.node(d - 1).child(idx - 1);
  if (!prev || !isItem(prev)) return false;
  if (dispatch) {
    const start = $from.before(d), end = $from.after(d), item = $from.node(d);
    const tr = state.tr.delete(start, end).insert(start - 1, item);
    if (prev.attrs.folded) tr.setNodeAttribute(start - prev.nodeSize, 'folded', false);
    tr.setSelection(TextSelection.create(tr.doc, $from.pos - 1, $to.pos - 1));
    dispatch(tr.scrollIntoView());
  }
  return true;
}

export function lift(state, dispatch) {
  const { $from, $to } = state.selection;
  const d = itemLineDepth($from);
  if (d < 2 || !isItem($from.node(d - 1))) return false;
  if (dispatch) {
    const parent = $from.node(d - 1), idx = $from.index(d - 1), item = $from.node(d);
    const start = $from.before(d), parentEnd = $from.after(d - 1);
    // Later siblings become children of the lifted item, as in an outliner.
    let afterItem = 0;
    for (let i = 0; i <= idx; i++) afterItem += parent.child(i).nodeSize;
    const lifted = item.copy(item.content.append(parent.content.cut(afterItem)));
    const tr = state.tr.delete(start, parentEnd - 1);
    const insertAt = tr.mapping.map(parentEnd);
    tr.insert(insertAt, lifted);
    tr.setSelection(TextSelection.create(tr.doc, insertAt + ($from.pos - start), insertAt + ($to.pos - start)));
    dispatch(tr.scrollIntoView());
  }
  return true;
}

/** Turns a top-level item back into its plain blocks. */
export function unwrap(state, dispatch) {
  const { $from } = state.selection;
  const d = itemLineDepth($from);
  if (d < 0) return false;
  if (dispatch) {
    const start = $from.before(d), item = $from.node(d);
    const tr = state.tr.replaceWith(start, $from.after(d), item.content);
    tr.setSelection(TextSelection.create(tr.doc, start + 1 + $from.parentOffset));
    dispatch(tr.scrollIntoView());
  }
  return true;
}

export function backspaceAtItemStart(state, dispatch) {
  const { $from, empty } = state.selection;
  if (!empty || $from.parentOffset > 0 || itemLineDepth($from) < 0) return false;
  return lift(state, dispatch) || unwrap(state, dispatch);
}

export function enterInItem(state, dispatch) {
  const { $from, empty } = state.selection;
  const d = itemLineDepth($from);
  if (!empty || d < 0) return false;
  const item = $from.node(d), line = $from.parent;
  if (line.content.size === 0 && item.childCount === 1) return lift(state, dispatch) || unwrap(state, dispatch);
  if (dispatch) {
    const off = $from.parentOffset;
    const newLine = (line.type.name === 'heading' ? state.schema.nodes.paragraph : line.type).create(null, line.content.cut(off));
    const newItem = item.type.create(freshAttrs(item.type, item), newLine);
    const lineStart = $from.before(), lineEnd = $from.after();
    const tr = state.tr.replaceWith(lineStart, lineEnd, line.copy(line.content.cut(0, off)));
    // With visible children, the new line becomes the first child; otherwise the next sibling.
    const asChild = item.childCount > 1 && !item.attrs.folded;
    const at = asChild ? tr.mapping.map(lineEnd) : tr.mapping.map($from.after(d));
    tr.insert(at, newItem);
    tr.setSelection(TextSelection.create(tr.doc, at + 2));
    dispatch(tr.scrollIntoView());
  }
  return true;
}

export function setChecked(tr, pos, node, checked) {
  const now = new Date().toISOString();
  return tr.setNodeMarkup(pos, null, { ...node.attrs, checked, lastCheckedTime: checked ? now : null, lastUpdatedTime: now });
}

export function toggleTodo(state, dispatch) {
  const { $from } = state.selection;
  for (let d = $from.depth; d > 0; d--) {
    const n = $from.node(d);
    if (n.type.name === 'todo_list_item') {
      if (dispatch) dispatch(setChecked(state.tr, $from.before(d), n, !n.attrs.checked));
      return true;
    }
  }
  return false;
}

/**
 * Converts the block at the cursor into `name` (paragraph, heading, code_block, a list item, or
 * blockquote), the way Heptabase's "/" menu does. Runs as a sequence of view dispatches.
 */
export function turnInto(view, name, attrs = null) {
  const run = (cmd) => cmd(view.state, view.dispatch);
  const { schema } = view.state;
  const type = schema.nodes[name];
  const d = itemLineDepth(view.state.selection.$from);

  if (LIST_ITEMS.includes(name)) {
    if (d >= 0) {
      const $from = view.state.selection.$from, item = $from.node(d);
      if (name !== 'toggle_list_item' && $from.parent.type.name !== 'paragraph') run(setBlockType(schema.nodes.paragraph));
      view.dispatch(view.state.tr.setNodeMarkup($from.before(d), type, { ...freshAttrs(type, item), ...attrs, id: item.attrs.id }));
    } else {
      if (view.state.selection.$from.parent.type.name !== 'paragraph') run(setBlockType(schema.nodes.paragraph));
      run(wrapIn(type, { ...freshAttrs(type), ...attrs }));
    }
    return;
  }
  if (name === 'blockquote') { run(wrapIn(type)); return; }
  if (d >= 0) run(unwrap);
  run(setBlockType(type, attrs));
}

export function insertBlock(view, name) {
  const { schema, selection } = view.state;
  const $from = selection.$from;
  const node = schema.nodes[name].create();
  const tr = view.state.tr;
  if ($from.parent.content.size === 0 && $from.depth === 1) {
    tr.replaceWith($from.before(), $from.after(), [node, schema.nodes.paragraph.create()]);
    tr.setSelection(TextSelection.create(tr.doc, $from.before() + node.nodeSize + 1));
  } else {
    tr.insert($from.after(1), [node, schema.nodes.paragraph.create()]);
    tr.setSelection(TextSelection.create(tr.doc, $from.after(1) + node.nodeSize + 1));
  }
  view.dispatch(tr.scrollIntoView());
}
