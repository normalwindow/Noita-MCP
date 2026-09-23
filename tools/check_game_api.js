// Verifies that every Gui* function the Lua code calls actually exists.
//
// An earlier version of the panel offset its panes with GuiTranslateSet, which is not in
// Noita's GUI API. The call sat inside a pcall, so it failed silently and every pane drew
// at (0,0) -- the content area looked empty and nothing pointed at the cause. Inventing an
// API is not a mistake to catch by eye; it is one to catch mechanically.
//
// The reference list is the game's own tools_modding/lua_api_documentation.txt.
const fs = require('fs');
const path = require('path');

const noitaDir = process.env.NOITA_DIR || process.argv[3];
const scanDir = process.argv[2];
if (!scanDir || !noitaDir) {
  console.error('usage: node check_game_api.js <lua-dir> <noita-dir>');
  process.exit(1);
}

const docPath = path.join(noitaDir, 'tools_modding', 'lua_api_documentation.txt');
if (!fs.existsSync(docPath)) {
  console.error('API documentation not found at ' + docPath);
  process.exit(1);
}
const doc = fs.readFileSync(docPath, 'utf8');

// Every global function the game documents, by name.
const documented = new Set();
for (const m of doc.matchAll(/^([A-Za-z_]\w*)\s*\(/gm)) documented.add(m[1]);
// The Gui* family is what matters most, but the list is complete so check everything.
const documentedAnywhere = new Set(documented);
for (const m of doc.matchAll(/\b([A-Z][A-Za-z0-9_]*)\s*\(/g)) documentedAnywhere.add(m[1]);

function walk(d) {
  return fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => {
    if (e.name === '.git') return [];
    const p = path.join(d, e.name);
    return e.isDirectory() ? walk(p) : [p];
  });
}

// Names the game provides that the documentation misses, verified by other means.
const KNOWN_EXTRA = new Set(['dofile_once']);

let checked = 0;
const missing = [];
for (const f of walk(scanDir).filter((f) => f.endsWith('.lua'))) {
  const text = fs.readFileSync(f, 'utf8');
  for (const m of text.matchAll(/\b(Gui[A-Za-z0-9_]+)\s*\(/g)) {
    checked++;
    const name = m[1];
    if (!documentedAnywhere.has(name)) {
      missing.push(`${path.relative(scanDir, f)}: ${name}`);
    }
  }
}

console.log(`checked ${checked} Gui* call sites against ${documentedAnywhere.size} documented names`);
if (missing.length) {
  console.log(`${missing.length} call(s) use a Gui function the game does not document:`);
  for (const m of [...new Set(missing)]) console.log('  ' + m);
  process.exit(1);
}
console.log('every Gui call site names a real function');
