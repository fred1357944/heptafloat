// Stand-in for the Swift host: serves a demo journal, keeps saves in memory, and answers card
// searches, so the editor runs in a normal browser without Heptabase.
(() => {
  const TITLES = {
    'aaaaaaaa-0000-4000-8000-000000000001': 'Product strategy 2027',
    'aaaaaaaa-0000-4000-8000-000000000002': 'How to Take Smart Notes',
  };
  const ago = (h) => new Date(Date.now() - h * 3600e3).toISOString();
  let RECENTS = [
    { id: new Date().toLocaleDateString('sv'), objectType: 'journal', title: '', chars: 358, openedAt: ago(0) },
    { id: 'aaaaaaaa-0000-4000-8000-000000000010', objectType: 'note', title: 'Weekly review template', chars: 1204, pinned: true, openedAt: ago(30) },
    { id: 'aaaaaaaa-0000-4000-8000-000000000002', objectType: 'note', title: 'How to Take Smart Notes', chars: 2841, openedAt: ago(2) },
    { id: 'aaaaaaaa-0000-4000-8000-000000000001', objectType: 'note', title: 'Product strategy 2027', chars: 967, openedAt: ago(26) },
    { id: '2026-10-11', objectType: 'journal', title: 'Oct 11, 2026', chars: 1412, openedAt: ago(28) },
    { id: 'aaaaaaaa-0000-4000-8000-000000000004', objectType: 'pdf', title: 'The Mom Test.pdf', openedAt: ago(24 * 8) },
    { id: 'aaaaaaaa-0000-4000-8000-000000000011', objectType: 'note', title: 'Onboarding interview notes', chars: 3310, openedAt: ago(24 * 16) },
  ];
  const CARDS = [
    { id: 'aaaaaaaa-0000-4000-8000-000000000002', objectType: 'note', title: 'How to Take Smart Notes', lastEditedTime: ago(5) },
    { id: 'aaaaaaaa-0000-4000-8000-000000000003', objectType: 'note', title: 'Smart defaults in onboarding', lastEditedTime: ago(24 * 3) },
    { id: 'aaaaaaaa-0000-4000-8000-000000000001', objectType: 'note', title: 'Product strategy 2027', lastEditedTime: ago(26) },
    { id: 'aaaaaaaa-0000-4000-8000-000000000004', objectType: 'pdf', title: 'The Mom Test.pdf', lastEditedTime: ago(24 * 40) },
    { id: '2026-10-11', objectType: 'journal', title: 'Oct 11, 2026', lastEditedTime: ago(28) },
    { id: 'aaaaaaaa-0000-4000-8000-000000000012', objectType: 'note', title: 'Smart pricing experiments', lastEditedTime: ago(24 * 12) },
  ];
  let content = null, md5 = 'demo-0', saves = 0;
  // Other cards you can open with ⌘P / ⌘O or from a mention.
  const NOTES = {
    'aaaaaaaa-0000-4000-8000-000000000002': { title: 'How to Take Smart Notes', content: { type: 'doc', content: [
      { type: 'heading', attrs: { level: 1 }, content: [{ type: 'text', text: 'How to Take Smart Notes' }] },
      { type: 'paragraph', content: [{ type: 'text', text: 'Sönke Ahrens — notes on building a slip-box.' }] },
      { type: 'bullet_list_item', content: [{ type: 'paragraph', content: [{ type: 'text', text: 'Write ' }, { type: 'text', marks: [{ type: 'strong' }], text: 'one idea per card' }, { type: 'text', text: ', in your own words.' }] }] },
      { type: 'bullet_list_item', content: [{ type: 'paragraph', content: [{ type: 'text', text: 'Always link a new card to something you already have.' }] }] },
      { type: 'bullet_list_item', content: [{ type: 'paragraph', content: [{ type: 'text', text: 'Related: ' }, { type: 'card', attrs: { cardId: 'aaaaaaaa-0000-4000-8000-000000000001' } }] }] },
    ] } },
    'aaaaaaaa-0000-4000-8000-000000000001': { title: 'Product strategy 2027', content: { type: 'doc', content: [
      { type: 'heading', attrs: { level: 1 }, content: [{ type: 'text', text: 'Product strategy 2027' }] },
      { type: 'paragraph', content: [{ type: 'text', text: 'Fewer steps, not more features.' }] },
    ] } },
    'aaaaaaaa-0000-4000-8000-000000000010': { title: 'Weekly review template', content: { type: 'doc', content: [
      { type: 'heading', attrs: { level: 1 }, content: [{ type: 'text', text: 'Weekly review template' }] },
      { type: 'todo_list_item', attrs: { checked: false }, content: [{ type: 'paragraph', content: [{ type: 'text', text: 'Clear inbox' }] }] },
    ] } },
  };
  const docs = {};
  const title = new Date().toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
  const postMessage = async (m) => {
    if (!content) {
      const d = new Date(), iso = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
      content = (await (await fetch('demo-journal.json')).text()).replaceAll('__TODAY__', iso);
    }
    const reply = (r) => setTimeout(() => window.hf.reply(m.requestId, r), 15);
    switch (m.action) {
      case 'read': {
        const note = NOTES[m.id];
        if (m.kind === 'note' && note) {
          docs[m.id] ??= JSON.stringify(note.content);
          reply({ kind: 'note', id: m.id, title: note.title, content: docs[m.id], contentMd5: `${m.id}-${docs[m.id].length}` });
        } else {
          const d = m.id.split('-').map(Number);
          const t = new Date(d[0], d[1] - 1, d[2]).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
          reply({ kind: 'journal', id: m.id, title: t, content: m.id === new Date().toLocaleDateString('sv') ? content : '{"type":"doc","content":[{"type":"paragraph"}]}', contentMd5: md5 });
        }
        setTimeout(() => window.hf.titles(TITLES), 40);
        break;
      }
      case 'createNote': {
        const id = `aaaaaaaa-0000-4000-8000-${String(Date.now()).slice(-12)}`;
        NOTES[id] = { title: m.title, content: JSON.parse(m.content) };
        docs[id] = m.content;
        reply({ current: { kind: 'note', id, title: m.title, content: m.content, contentMd5: `${id}-${m.content.length}` } });
        break;
      }
      case 'cardType':
        reply({ cardType: NOTES[m.id] ? 'note' : 'pdfCard', title: NOTES[m.id]?.title });
        break;
      case 'touchRecent': {
        const i = RECENTS.findIndex((c) => c.id === m.id);
        const old = i >= 0 ? RECENTS.splice(i, 1)[0] : {};
        RECENTS.unshift({ ...old, id: m.id, objectType: m.objectType, title: m.title, chars: m.chars, openedAt: new Date().toISOString() });
        break;
      }
      case 'save':
        if (m.kind === 'note') {
          docs[m.id] = m.content;
          reply({ current: { kind: 'note', id: m.id, title: NOTES[m.id]?.title, content: m.content, contentMd5: `${m.id}-${m.content.length}` } });
        } else {
          content = m.content; md5 = `demo-${++saves}`;
          reply({ current: { kind: 'journal', id: m.id, title, content, contentMd5: md5 } });
        }
        break;
      case 'search': {
        const q = (m.query || '').toLowerCase();
        reply({ results: CARDS.filter((c) => !q || c.title.toLowerCase().includes(q)) });
        break;
      }
      case 'recents':
        reply({ cards: RECENTS.map((c) => (c.title ? c : { ...c, title })) });
        break;
      case 'pinCard':
        RECENTS = RECENTS.map((c) => (c.id === m.id ? { ...c, pinned: m.pinned } : c));
        reply({});
        break;
      case 'forgetCard':
        RECENTS = RECENTS.filter((c) => c.id !== m.id);
        reply({});
        break;
      default: console.log('host', m);
    }
  };
  // Some browsers predefine a read-only `window.webkit`, so define it rather than assign it.
  Object.defineProperty(window, 'webkit', { value: { messageHandlers: { hf: { postMessage } } }, configurable: true });
})();
