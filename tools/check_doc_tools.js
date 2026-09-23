// Checks that every noita_* tool named in the release docs actually exists.
//
// Documentation that references a tool nobody implemented is worse than no
// documentation: an agent reads it, calls the tool, and gets "unknown tool" with no
// way to tell whether the feature is missing or the docs are stale.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const root = process.argv[2];
if (!root) {
  console.error('usage: node check_doc_tools.js <release-root>');
  process.exit(1);
}

const serverJs = path.join(root, 'base', 'mcp_server', 'server.js');
const listing = execFileSync(process.execPath, [serverJs, '--list'], { encoding: 'utf8' });
const tools = new Set(
  listing.split('\n').map((l) => l.split('\t')[0].trim()).filter((s) => s.startsWith('noita_'))
);

function walk(d) {
  return fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => {
    if (e.name === '.git') return [];
    const p = path.join(d, e.name);
    return e.isDirectory() ? walk(p) : [p];
  });
}

// Names that look like tool calls but are not tools. Keeping this list explicit
// stops the check from drowning in false positives, which is how a check like this
// gets ignored: noita_agent is the MOD's name, noita_db is a file, and the other two
// are tools that were deliberately removed and are only mentioned as such.
const NOT_TOOLS = new Set([
  'noita_agent',            // the mod's name
  'noita_db',               // noita_db.json, the fact database file
  'noita_input_aim',        // removed: aiming goes through noita_input_click
  'noita_input_clear',      // removed: use noita_input_release
  'noita_input_move',       // replaced below only if the server disagrees
  'noita_entity_blueprint', // superseded by noita_db_query
]);

// Tool names are only counted when they appear in a code span or a table cell, which
// is where a real tool reference lives. Prose like "noita-wand-editing" or a bare
// mention of the mod is not a call.
const TOOL_REF = /`(noita_[a-z0-9_]+)`|^\|\s*`?(noita_[a-z0-9_]+)`?/gm;

let total = 0;
const bad = [];
const seen = new Set();
for (const f of walk(root).filter((f) => f.endsWith('.md'))) {
  const text = fs.readFileSync(f, 'utf8');
  for (const m of text.matchAll(TOOL_REF)) {
    const name = m[1] || m[2];
    if (!name) continue;
    total++;
    if (!tools.has(name) && !NOT_TOOLS.has(name)) {
      bad.push(`${path.relative(root, f)}: ${name}`);
    } else if (tools.has(name)) {
      seen.add(name);
    }
  }
}

console.log(`server registers ${tools.size} tools`);
console.log(`docs reference ${total} tool names (${seen.size} distinct, valid)`);
if (bad.length) {
  console.log(`${bad.length} reference(s) name a tool that does not exist:`);
  for (const b of bad) console.log('  ' + b);
  process.exit(1);
}
console.log('all referenced tools exist');
