// Turns a paste into Heptabase's document JSON.
//
// Plain text that looks like Markdown (or contains a URL or a {{card id}} mention) becomes real
// blocks, marks, links, and card mentions. HTML from a web page, and Heptabase's own clipboard
// (<hepta-card data-card-id="…">Title</hepta-card>), is walked the same way. Titles written next
// to a mention are returned beside the doc so the chip can show them before the app looks them up.

const MENTION_KINDS = {
  card: ['card', 'cardId'],
  pdf_card: ['pdf_card', 'pdfCardId'],
  image_card: ['image_card', 'cardId'],
  video_card: ['video_card', 'cardId'],
  audio_card: ['audio_card', 'cardId'],
  web_card: ['web_card', 'webCardId'],
  highlight_element: ['highlight_element', 'highlightElementId'],
  whiteboard: ['whiteboard', 'whiteboardId'],
  tag: ['tag', 'tagId'],
  date: ['date', 'date'],
  journal: ['card', 'cardId'], // a journal's id is its date; the card chip opens it
};

const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const DATE = '\\d{4}-\\d{2}-\\d{2}';
const MENTION_RE = new RegExp(`\\{\\{\\s*(${Object.keys(MENTION_KINDS).join('|')})\\s+(${UUID}|${DATE})\\s*\\}\\}`, 'gi');
const DEEP_RE = new RegExp(`heptabase://card/(${UUID}|${DATE})`, 'gi');
const URL_RE = /https?:\/\/[^\s<>)\]]+/gi;

const HTML_TAGS = {
  'hepta-card': ['card', 'data-card-id'],
  'hepta-image-card': ['image_card', 'data-card-id'],
  'hepta-video-card': ['video_card', 'data-card-id'],
  'hepta-audio-card': ['audio_card', 'data-card-id'],
  'hepta-pdf-card': ['pdf_card', 'data-pdf-card-id'],
  'hepta-highlight-element': ['highlight_element', 'data-highlight-element-id'],
  'hepta-web-card': ['web_card', 'data-web-card-id'],
  'hepta-whiteboard': ['whiteboard', 'data-whiteboard-id'],
  'hepta-tag': ['tag', 'data-tag-id'],
  'hepta-date': ['date', 'data-date'],
  'hepta-web': ['web', 'data-url'],
};

/** True when plain text should be parsed instead of inserted as-is. */
export function plainLooksRich(text) {
  if (!text || !text.trim()) return false;
  if (MENTION_RE.test(text)) { MENTION_RE.lastIndex = 0; return true; }
  MENTION_RE.lastIndex = 0;
  if (DEEP_RE.test(text)) { DEEP_RE.lastIndex = 0; return true; }
  DEEP_RE.lastIndex = 0;
  if (/https?:\/\/\S+/.test(text)) return true;
  if (/^#{1,6} \S/m.test(text)) return true;
  if (/^(\s*[-*+] |\s*\d+\. |\s*> |\s*\[( |x|X)?\] )/m.test(text)) return true;
  if (/^```/m.test(text) || /^---\s*$/m.test(text)) return true;
  if (/\[[^\]]+\]\(https?:\/\//.test(text)) return true;
  if (/(\*\*|~~)[^\n]+?\1/.test(text)) return true;
  return false;
}

/** HTML that already carries structure (a web page, or Heptabase's own clipboard). */
export function htmlIsRich(html) {
  return !!html && /<(p|h1|h2|h3|h4|div|ul|ol|li|a|strong|b|em|i|u|s|del|blockquote|pre|code|br|img|hr|table|hepta-)\b/i.test(html);
}

function textNode(text, marks) {
  if (!text) return null;
  const n = { type: 'text', text };
  if (marks?.length) n.marks = marks;
  return n;
}

function mentionNode(kind, id, titles, title) {
  const spec = MENTION_KINDS[kind];
  if (!spec || !id) return null;
  const [type, attr] = spec;
  if (title && title !== id) titles[id] = title;
  if (type === 'web') return { type: 'web', attrs: { url: id, title: title || undefined } };
  return { type, attrs: { [attr]: id } };
}

/** Inline marks and mentions inside one line of Markdown. */
export function parseInlines(text, titles = {}) {
  if (!text) return [];
  const re = new RegExp(
    [
      '`([^`]+)`',
      '\\*\\*([^*]+)\\*\\*',
      '~~([^~]+)~~',
      '\\*([^*]+)\\*',
      '\\[([^\\]]+)\\]\\((https?:\\/\\/[^\\s)]+)\\)',
      `\\{\\{\\s*(${Object.keys(MENTION_KINDS).join('|')})\\s+(${UUID}|${DATE})\\s*\\}\\}`,
      `heptabase:\\/\\/card\\/(${UUID}|${DATE})`,
      'https?:\\/\\/[^\\s<>)\\]]+',
    ].join('|'),
    'gi',
  );
  const out = [];
  let at = 0;
  for (let m; (m = re.exec(text));) {
    if (m.index > at) out.push(textNode(text.slice(at, m.index)));
    if (m[1] != null) out.push(textNode(m[1], [{ type: 'code' }]));
    else if (m[2] != null) out.push(textNode(m[2], [{ type: 'strong' }]));
    else if (m[3] != null) out.push(textNode(m[3], [{ type: 'strike' }]));
    else if (m[4] != null) out.push(textNode(m[4], [{ type: 'em' }]));
    else if (m[5] != null) out.push(textNode(m[5], [{ type: 'link', attrs: { href: m[6] } }]));
    else if (m[7] != null) {
      const node = mentionNode(m[7].toLowerCase(), m[8], titles);
      if (node) out.push(node);
    } else if (m[9] != null) {
      const node = mentionNode('card', m[9], titles);
      if (node) out.push(node);
    } else if (m[0]) {
      const href = m[0].replace(/[.,;:!?]+$/, '');
      const rest = m[0].slice(href.length);
      out.push(textNode(href, [{ type: 'link', attrs: { href } }]));
      if (rest) out.push(textNode(rest));
    }
    at = m.index + m[0].length;
  }
  if (at < text.length) out.push(textNode(text.slice(at)));
  return out.filter(Boolean);
}

function isBlockStart(line) {
  return /^(#{1,6} |```|---\s*$|>\s?|\[( |x|X)?\] |\d+\. |[-*+] )/.test(line);
}

/** Markdown, URLs, and {{card id}} mentions → a ProseMirror doc plus any titles we already know. */
export function markdownToDoc(src) {
  const lines = String(src).replace(/\r\n/g, '\n').split('\n');
  const content = [];
  const titles = {};
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }
    if (line.startsWith('```')) {
      const buf = [];
      i++;
      while (i < lines.length && !lines[i].startsWith('```')) buf.push(lines[i++]);
      if (i < lines.length) i++;
      content.push({ type: 'code_block', content: buf.length ? [{ type: 'text', text: buf.join('\n') }] : [] });
      continue;
    }
    if (/^---\s*$/.test(line)) { content.push({ type: 'horizontal_rule' }); i++; continue; }
    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    if (heading) {
      content.push({ type: 'heading', attrs: { level: heading[1].length }, content: parseInlines(heading[2], titles) });
      i++;
      continue;
    }
    if (/^>\s?/.test(line)) {
      const quoted = [];
      while (i < lines.length && /^>\s?/.test(lines[i])) quoted.push(lines[i++].replace(/^>\s?/, ''));
      content.push({ type: 'blockquote', content: quoted.map((t) => ({ type: 'paragraph', content: parseInlines(t, titles) })) });
      continue;
    }
    const todo = /^\[( |x|X)?\]\s+(.*)$/.exec(line);
    if (todo) {
      content.push({ type: 'todo_list_item', attrs: { checked: (todo[1] || '').toLowerCase() === 'x' }, content: [{ type: 'paragraph', content: parseInlines(todo[2], titles) }] });
      i++;
      continue;
    }
    const num = /^\d+\.\s+(.*)$/.exec(line);
    if (num) {
      content.push({ type: 'numbered_list_item', content: [{ type: 'paragraph', content: parseInlines(num[1], titles) }] });
      i++;
      continue;
    }
    const bullet = /^[-*+]\s+(.*)$/.exec(line);
    if (bullet) {
      content.push({ type: 'bullet_list_item', content: [{ type: 'paragraph', content: parseInlines(bullet[1], titles) }] });
      i++;
      continue;
    }
    const buf = [line];
    i++;
    while (i < lines.length && lines[i].trim() && !isBlockStart(lines[i])) buf.push(lines[i++]);
    content.push({ type: 'paragraph', content: parseInlines(buf.join(' '), titles) });
  }
  if (!content.length) content.push({ type: 'paragraph' });
  return { doc: { type: 'doc', content }, titles };
}

function attr(el, name) {
  return el.getAttribute?.(name) || '';
}

function elementMention(el, titles) {
  const spec = HTML_TAGS[el.tagName?.toLowerCase()];
  if (!spec) return null;
  const [type, attrName] = spec;
  if (type === 'web') {
    const url = attr(el, 'data-url');
    if (!url) return null;
    return { type: 'web', attrs: { url, title: attr(el, 'data-title') || el.textContent.trim() || undefined } };
  }
  const id = attr(el, attrName);
  if (!id) return null;
  const title = el.textContent.replace(/\s+/g, ' ').trim();
  if (title && title !== id) titles[id] = title;
  const key = type === 'date' ? 'date' : type === 'pdf_card' ? 'pdfCardId' : type === 'web_card' ? 'webCardId'
    : type === 'highlight_element' ? 'highlightElementId' : type === 'whiteboard' ? 'whiteboardId'
      : type === 'tag' ? 'tagId' : 'cardId';
  return { type, attrs: { [key]: id } };
}

const MARK_OF = { strong: 'strong', b: 'strong', em: 'em', i: 'em', u: 'underline', s: 'strike', del: 'strike', strike: 'strike', code: 'code' };

function inlineFrom(node, marks, titles, out) {
  if (node.nodeType === 3) {
    const text = node.textContent.replace(/\u00a0/g, ' ');
    if (text) parseInlines(text, titles).forEach((n) => {
      if (n.type === 'text' && marks.length) n = { ...n, marks: [...marks, ...(n.marks || [])] };
      out.push(n);
    });
    return;
  }
  if (node.nodeType !== 1) return;
  const tag = node.tagName.toLowerCase();
  const mention = elementMention(node, titles);
  if (mention) { out.push(mention); return; }
  if (tag === 'br') { out.push({ type: 'hard_break' }); return; }
  if (tag === 'a') {
    const href = attr(node, 'href');
    const next = href ? [...marks, { type: 'link', attrs: { href } }] : marks;
    node.childNodes.forEach((c) => inlineFrom(c, next, titles, out));
    return;
  }
  const mark = MARK_OF[tag];
  const next = mark ? [...marks, { type: mark }] : marks;
  node.childNodes.forEach((c) => inlineFrom(c, next, titles, out));
}

function inlinesOf(el, titles) {
  const out = [];
  el.childNodes.forEach((c) => inlineFrom(c, [], titles, out));
  return out.filter((n) => n.type !== 'text' || n.text);
}

const BLOCK_TAGS = new Set(['p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'blockquote', 'pre', 'hr', 'table', 'li', 'section', 'article']);

function pushBlocks(node, titles, out) {
  if (node.nodeType === 3) {
    if (node.textContent.trim()) out.push({ type: 'paragraph', content: parseInlines(node.textContent.trim(), titles) });
    return;
  }
  if (node.nodeType !== 1) return;
  const tag = node.tagName.toLowerCase();
  if (tag === 'script' || tag === 'style' || tag === 'meta' || tag === 'title') return;
  const mention = elementMention(node, titles);
  if (mention) { out.push({ type: 'paragraph', content: [mention] }); return; }
  if (/^h[1-6]$/.test(tag)) {
    out.push({ type: 'heading', attrs: { level: Number(tag[1]) }, content: inlinesOf(node, titles) });
    return;
  }
  if (tag === 'pre') {
    const text = node.textContent.replace(/\n$/, '');
    out.push({ type: 'code_block', content: text ? [{ type: 'text', text }] : [] });
    return;
  }
  if (tag === 'hr') { out.push({ type: 'horizontal_rule' }); return; }
  if (tag === 'img') {
    const src = attr(node, 'src');
    if (src && !src.startsWith('data:')) out.push({ type: 'image', attrs: { src, alignment: 'center' } });
    return;
  }
  if (tag === 'ul' || tag === 'ol') {
    const type = tag === 'ol' ? 'numbered_list_item' : 'bullet_list_item';
    [...node.children].forEach((li) => {
      if (li.tagName.toLowerCase() !== 'li') return;
      const nested = [...li.children].filter((c) => c.tagName && /^(ul|ol)$/i.test(c.tagName));
      out.push({ type, content: [{ type: 'paragraph', content: inlinesOf(li, titles) }] });
      nested.forEach((n) => pushBlocks(n, titles, out));
    });
    return;
  }
  if (tag === 'blockquote') {
    const inner = [];
    [...node.childNodes].forEach((c) => pushBlocks(c, titles, inner));
    out.push({ type: 'blockquote', content: inner.length ? inner : [{ type: 'paragraph' }] });
    return;
  }
  if (tag === 'table') {
    const rows = [...node.querySelectorAll('tr')];
    if (!rows.length) return;
    out.push({
      type: 'table',
      content: rows.map((tr) => ({
        type: 'table_row',
        content: [...tr.children].filter((c) => /^(td|th)$/i.test(c.tagName)).map((cell) => ({
          type: cell.tagName.toLowerCase() === 'th' ? 'table_header' : 'table_cell',
          content: [{ type: 'paragraph', content: inlinesOf(cell, titles) }],
        })),
      })),
    });
    return;
  }
  const kids = [...node.children];
  if (tag === 'p' || (tag === 'div' && !kids.some((c) => BLOCK_TAGS.has(c.tagName.toLowerCase()) || c.tagName.toLowerCase().startsWith('hepta-')))) {
    const content = inlinesOf(node, titles);
    if (content.length) out.push({ type: 'paragraph', content });
    return;
  }
  [...node.childNodes].forEach((c) => pushBlocks(c, titles, out));
}

/** Rich HTML → the same doc shape. Needs DOMParser (the editor's web view has it). */
export function htmlToDoc(html) {
  if (typeof DOMParser === 'undefined') return null;
  const titles = {};
  const parsed = new DOMParser().parseFromString(html, 'text/html');
  const content = [];
  [...parsed.body.childNodes].forEach((n) => pushBlocks(n, titles, content));
  if (!content.length) return null;
  return { doc: { type: 'doc', content }, titles };
}
