// Renames the mod's display name wherever it appears as prose.
//
// The mod's name in mod.xml was already correct; what was stale was the prose across the docs,
// the server, the Lua comments and the installer -- 23 occurrences across 8 files.
//
// Written in Node rather than PowerShell on purpose. ENGINE-NOTES.md records that
// Get-Content/Set-Content round-trips non-ASCII text lossily on this machine, and several of
// these files are UTF-8 Chinese. A rename that corrupts the documentation is worse than the
// wrong name.
//
// The mod's DIRECTORY stays `noita_agent`. That is its identity to the game, it appears in
// every `mods/noita_agent/...` path in the Lua, and renaming it would break installed copies
// for no benefit the player can see.
const fs = require('fs');
const path = require('path');

const root = process.argv[2];
if (!root) { console.error('usage: node rename_mod.js <release-root>'); process.exit(1); }

const FROM = 'Noita AI Agent Bridge';
const TO = 'Noita MCP Agent Bridge';

const EXTS = new Set(['.md', '.js', '.lua', '.xml', '.ps1', '.json', '.py', '.txt']);

const walk = (d) => fs.readdirSync(d, { withFileTypes: true })
  .flatMap((e) => {
    const p = path.join(d, e.name);
    if (e.isDirectory()) {
      if (e.name === '.git') return [];
      return walk(p);
    }
    return [p];
  });

let files = 0, hits = 0;
for (const f of walk(root)) {
  if (!EXTS.has(path.extname(f).toLowerCase())) continue;

  const raw = fs.readFileSync(f);
  // a BOM would be preserved by writing the same buffer back, but check first so this never
  // introduces or removes one silently
  const hasBom = raw[0] === 0xEF && raw[1] === 0xBB && raw[2] === 0xBF;
  const text = raw.toString('utf8');
  if (!text.includes(FROM)) continue;

  const count = text.split(FROM).length - 1;
  const out = text.split(FROM).join(TO);
  const buf = Buffer.from(out, 'utf8');
  fs.writeFileSync(f, hasBom ? Buffer.concat([Buffer.from([0xEF, 0xBB, 0xBF]), buf]) : buf);

  console.log(`  ${path.relative(root, f)}  ${count} occurrence(s)`);
  files++; hits += count;
}
console.log(`  ${hits} occurrences in ${files} file(s)`);

// Anything left is a spelling this script does not know about, so say so rather than
// reporting success on a partial rename.
const leftovers = [];
for (const f of walk(root)) {
  if (!EXTS.has(path.extname(f).toLowerCase())) continue;
  const text = fs.readFileSync(f, 'utf8');
  if (/Noita AI Agent/i.test(text)) leftovers.push(path.relative(root, f));
}
if (leftovers.length) {
  console.log('');
  console.log('STILL CONTAINS "Noita AI Agent":');
  for (const l of leftovers) console.log('  ' + l);
  process.exit(1);
}
console.log('  no remaining "Noita AI Agent" spellings');
