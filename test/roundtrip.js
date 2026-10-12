// Checks parse → serialize is lossless for real journals: bun test/roundtrip.js <dir-of-json>
import { readdirSync, readFileSync } from 'fs';
import { Node } from 'prosemirror-model';
import { schemaFor, serialize } from '../src/schema.js';

const norm = (v) => {
  if (Array.isArray(v)) return v.map(norm);
  if (v && typeof v === 'object') {
    const o = {};
    for (const k of Object.keys(v).sort()) {
      if (v[k] === undefined) continue;
      if (k === 'attrs' && Object.keys(v[k]).length === 0) continue;
      o[k] = k === 'marks' ? norm(v[k]).sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b))) : norm(v[k]);
    }
    return o;
  }
  return v;
};

const dir = process.argv[2];
let ok = 0, bad = 0;
for (const f of readdirSync(dir).filter((f) => f.endsWith('.json'))) {
  const json = JSON.parse(readFileSync(`${dir}/${f}`, 'utf8'));
  const { schema, prepared } = schemaFor(json);
  const doc = Node.fromJSON(schema, prepared);
  doc.check();
  const out = JSON.parse(JSON.stringify(serialize(doc)));
  const a = JSON.stringify(norm(json)), b = JSON.stringify(norm(out));
  if (a === b) ok++;
  else {
    bad++;
    let i = 0; while (a[i] === b[i]) i++;
    console.log(f, '\n  in :', a.slice(i - 120, i + 120), '\n  out:', b.slice(i - 120, i + 120));
  }
}
console.log({ ok, bad });
