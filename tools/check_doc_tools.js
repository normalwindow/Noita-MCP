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

// Names that look like tool calls but are not tools. Keeping this list explicit stops the check
// from drowning in false positives, which is how a check like this gets ignored: noita_agent is the
// MOD's name, noita_db is a file, and the others were deliberately removed or renamed and are only
// mentioned as such -- in the CHANGELOG entry that recorded the change, which must keep naming
// them or the history stops making sense.
const NOT_TOOLS = new Set([
  'noita_agent',            // the mod's name
  'noita_db',               // noita_db.json, the fact database file
  'noita_input_aim',        // removed: aiming goes through noita_input_click
  'noita_input_clear',      // removed: use noita_input_release
  'noita_input_move',       // replaced below only if the server disagrees
  'noita_entity_blueprint', // superseded by noita_db_query
  'noita_seed_find',        // replaced by noita_seed, which needs no arguments
  'noita_seed_verify',      // replaced by the agreement check inside noita_seed
]);

// A CHANGELOG is a record of what the tool set WAS, so its older sections necessarily name tools
// that no longer exist. Only the newest version's section is treated as describing the present.
// Without this the check reports every rename twice -- once when it happens and forever after, in
// the entry that explains it -- and a check that always complains is one nobody reads.
function currentChangelogSection(text) {
  const lines = text.split(/\r?\n/);
  const out = [];
  let inCurrent = false;
  for (const line of lines) {
    const version = /^##\s*\[(\d+\.\d+\.\d+)\]/.exec(line);
    if (version) {
      if (inCurrent) break;    // reached the next version: stop
      inCurrent = true;        // the first version heading is the newest
      continue;
    }
    if (inCurrent) out.push(line);
  }
  return out.join('\n');
}

// Tool names are only counted when they appear in a code span or a table cell, which is where a
// real tool reference lives. Prose like "noita-wand-editing" or a bare mention of the mod is not a
// call.
const TOOL_REF = /`(noita_[a-z0-9_]+)`|^\|\s*`?(noita_[a-z0-9_]+)`?/gm;

let total = 0;
const bad = [];
const seen = new Set();
for (const f of walk(root).filter((f) => f.endsWith('.md'))) {
  const raw = fs.readFileSync(f, 'utf8');
  // The CHANGELOG's older sections describe what the tool set USED to be, so they are not checked.
  // Only the newest section is, because that is the one describing the present.
  const text = path.basename(f) === 'CHANGELOG.md' ? currentChangelogSection(raw) : raw;
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
