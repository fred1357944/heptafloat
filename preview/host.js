// Stand-in for the Swift host: serves a demo journal, keeps saves in memory, and answers card
// searches, so the editor runs in a normal browser without Heptabase.
(() => {
  const TITLES = {
    'aaaaaaaa-0000-4000-8000-000000000001': 'Product strategy 2027',
    'aaaaaaaa-0000-4000-8000-000000000002': 'How to Take Smart Notes',
  };
  const CARDS = [
    { id: 'aaaaaaaa-0000-4000-8000-000000000002', objectType: 'note', title: 'How to Take Smart Notes' },
    { id: 'aaaaaaaa-0000-4000-8000-000000000003', objectType: 'note', title: 'Smart defaults in onboarding' },
    { id: 'aaaaaaaa-0000-4000-8000-000000000001', objectType: 'note', title: 'Product strategy 2027' },
    { id: 'aaaaaaaa-0000-4000-8000-000000000004', objectType: 'pdf', title: 'The Mom Test.pdf' },
    { id: '2026-10-11', objectType: 'journal', title: 'Oct 11, 2026' },
  ];
  let content = null, md5 = 'demo-0', saves = 0;
  const title = new Date().toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
  const postMessage = async (m) => {
    if (!content) {
      const d = new Date(), iso = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
      content = (await (await fetch('demo-journal.json')).text()).replaceAll('__TODAY__', iso);
    }
    const reply = (r) => setTimeout(() => window.hf.reply(m.requestId, r), 15);
    switch (m.action) {
      case 'read':
        reply({ date: m.date, title, content, contentMd5: md5 });
        setTimeout(() => window.hf.titles(TITLES), 40);
        break;
      case 'save':
        content = m.content; md5 = `demo-${++saves}`;
        reply({ current: { date: m.date, title, content, contentMd5: md5 } });
        break;
      case 'search': {
        const q = (m.query || '').toLowerCase();
        reply({ results: CARDS.filter((c) => !q || c.title.toLowerCase().includes(q)) });
        break;
      }
      default: console.log('host', m);
    }
  };
  // Some browsers predefine a read-only `window.webkit`, so define it rather than assign it.
  Object.defineProperty(window, 'webkit', { value: { messageHandlers: { hf: { postMessage } } }, configurable: true });
})();
