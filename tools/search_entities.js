// Searches the entity index directly, bypassing shell quoting entirely.
// Usage: node search_entities.js <terms...> [--kind=K] [--limit=N]
const fs = require('fs');
const path = require('path');

const idxPath = path.join(__dirname, '..', '..', 'dist', 'mcp_server', 'entity_index.json');
const idx = JSON.parse(fs.readFileSync(idxPath, 'utf8'));

const argv = process.argv.slice(2);
let kind = null, limit = 10;
const terms = [];
for (const a of argv) {
  if (a.startsWith('--kind=')) kind = a.slice(7);
  else if (a.startsWith('--limit=')) limit = parseInt(a.slice(8), 10);
  else terms.push(a.toLowerCase());
}

let rows = idx.entities;
if (kind) rows = rows.filter((e) => e.kind === kind);
if (terms.length) {
  rows = rows.filter((e) => {
    const hay = `${e.path} ${e.file} ${e.tags} ${e.name}`.toLowerCase();
    return terms.every((t) => hay.includes(t));
  });
}

console.log(`catalog ${idx.total} entities; kinds: ${JSON.stringify(idx.kinds)}`);
console.log(`matched ${rows.length}${kind ? ` (kind=${kind})` : ''}${terms.length ? ` for [${terms.join(' ')}]` : ''}`);
for (const e of rows.slice(0, limit)) {
  console.log(`  ${e.kind.padEnd(11)} ${e.path}${e.name ? '   ' + e.name : ''}`);
}
