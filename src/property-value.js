// Heptabase property values are not all plain strings. The CLI's set-property command wants a
// string via --value, or JSON via --json-value: numbers are numeric strings, selects are option
// ids, multi-selects are arrays of option ids, checkboxes are booleans, dates are { start, end },
// and text is a ProseMirror node (or null when cleared).

const TEXT_TYPES = new Set(['text', 'url', 'phone', 'email', 'title']);

export function textOf(value) {
  if (value == null) return '';
  if (typeof value === 'string') return value;
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  const parts = [];
  const walk = (n) => {
    if (!n || typeof n !== 'object') return;
    if (typeof n.text === 'string') parts.push(n.text);
    (n.content || []).forEach(walk);
  };
  walk(value);
  return parts.join('');
}

/** What the field should show. */
export function fromWire(type, value) {
  if (type === 'checkbox') return value === true;
  if (type === 'multiSelect') return Array.isArray(value) ? value.filter((v) => typeof v === 'string') : [];
  if (type === 'select') return typeof value === 'string' ? value : '';
  if (type === 'number') return value == null ? '' : String(value);
  if (type === 'date') {
    const start = value && typeof value === 'object' ? value.start : typeof value === 'string' ? value : '';
    if (!start) return '';
    const d = new Date(start);
    if (Number.isNaN(d.getTime())) return String(start).slice(0, 10);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  }
  if (type === 'relation') {
    if (!Array.isArray(value)) return '';
    return value.map((v) => v?.id).filter(Boolean);
  }
  if (TEXT_TYPES.has(type)) return textOf(value);
  return textOf(value);
}

/**
 * Encodes a field edit for `card set-property`.
 * Returns { value } or { json } — exactly one — or null when this type isn't edited here.
 */
export function toWire(type, raw) {
  if (type === 'text' || type === 'title') {
    const text = String(raw ?? '').trim();
    if (!text) return { json: 'null' };
    return { json: JSON.stringify({ type: 'paragraph', content: [{ type: 'text', text }] }) };
  }
  if (type === 'url' || type === 'phone' || type === 'email') {
    const text = String(raw ?? '').trim();
    return text ? { value: text } : { json: 'null' };
  }
  if (type === 'number') {
    const text = String(raw ?? '').trim();
    if (!text) return { json: 'null' };
    if (Number.isNaN(Number(text))) return null;
    return { json: JSON.stringify(text) };
  }
  if (type === 'select') {
    return raw ? { value: String(raw) } : { json: 'null' };
  }
  if (type === 'multiSelect') {
    const ids = (Array.isArray(raw) ? raw : []).filter(Boolean);
    return { json: JSON.stringify(ids) };
  }
  if (type === 'checkbox') return { json: raw ? 'true' : 'false' };
  if (type === 'date') {
    if (!raw) return { json: 'null' };
    // Noon UTC keeps the calendar day stable on either side of the date line.
    return { json: JSON.stringify({ start: `${raw}T12:00:00.000Z`, end: null }) };
  }
  return null;
}

export const EDITABLE = new Set(['text', 'title', 'number', 'select', 'multiSelect', 'checkbox', 'date', 'url', 'phone', 'email']);
