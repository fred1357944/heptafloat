// Saves a journal back unchanged through our serializer, to check the CLI accepts it: bun test/save-noop.js YYYY-MM-DD
import { execFileSync } from 'child_process';
import { writeFileSync } from 'fs';
import { Node } from 'prosemirror-model';
import { schemaFor, serialize } from '../src/schema.js';

const date = process.argv[2];
const r = JSON.parse(execFileSync('heptabase', ['journal', 'read', date]));
const { schema, prepared } = schemaFor(JSON.parse(r.content));
const out = JSON.stringify(serialize(Node.fromJSON(schema, prepared)));
writeFileSync('/tmp/heptafloat-noop.json', out);
console.log(execFileSync('heptabase', ['journal', 'save', date, '--content-md5', r.contentMd5, '--content-file', '/tmp/heptafloat-noop.json']).toString());
const after = JSON.parse(execFileSync('heptabase', ['journal', 'read', date]));
console.log({ before: r.contentMd5, after: after.contentMd5, sameText: after.content.length === r.content.length || 'length differs' });
