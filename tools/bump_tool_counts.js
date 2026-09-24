// Updates the tool counts across the release docs.
//
// Separate from the shell because the replacements contain quotes and non-ASCII text, and
// PowerShell mangles both: the previous attempt died on a missing string terminator rather
// than doing anything.
const fs = require('fs');
const path = require('path');

const root = process.argv[2];
if (!root) { console.error('usage: node bump_tool_counts.js <release-root> <from> <to>'); process.exit(1); }
const from = process.argv[3] || '76';
const to = process.argv[4] || '80';

const walk = (d) => fs.readdirSync(d, { withFileTypes: true })
  .flatMap((e) => (e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]));

const pairs = [
  [`${from} MCP tools`, `${to} MCP tools`],
  [`${from} tools`, `${to} tools`],
  [`${from} 个工具`, `${to} 个工具`],
  [`**${from} 个**`, `**${to} 个**`],
  ['67 个可直接使用', '71 个可直接使用'],
  ["tier's 67 tools", "tier's 71 tools"],
  ['67 tools', '71 tools'],
  ['基础版 67 个工具', '基础版 71 个工具'],
];

let changed = 0;
for (const f of walk(root).filter((f) => f.endsWith('.md'))) {
  let t = fs.readFileSync(f, 'utf8');
  const before = t;
  for (const [a, b] of pairs) t = t.split(a).join(b);
  if (t !== before) {
    fs.writeFileSync(f, t, 'utf8');
    console.log('  ' + path.relative(root, f));
    changed++;
  }
}
console.log(`  ${changed} file(s) updated (${from} -> ${to})`);
