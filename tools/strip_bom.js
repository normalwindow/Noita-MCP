// Strips UTF-8 BOMs from text files.
//
// PowerShell 5.1's `Set-Content -Encoding utf8` writes a BOM, which some tools and
// diff views treat as content. Node is used to do the removal because PowerShell is
// what added them, and because editing these files from PowerShell risks the
// ANSI round-trip that already corrupted the Chinese docs once.
const fs = require('fs');
const path = require('path');

const root = process.argv[2];
if (!root) {
  console.error('usage: node strip_bom.js <dir>');
  process.exit(1);
}
const TEXT = new Set(['.md', '.js', '.py', '.ps1', '.lua', '.xml', '.txt', '.json', '.csv']);

function walk(d) {
  return fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => {
    if (e.name === '.git') return [];
    const p = path.join(d, e.name);
    return e.isDirectory() ? walk(p) : [p];
  });
}

let stripped = 0;
for (const f of walk(root)) {
  if (!TEXT.has(path.extname(f).toLowerCase())) continue;
  const b = fs.readFileSync(f);
  if (b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf) {
    fs.writeFileSync(f, b.subarray(3));
    console.log('stripped ' + path.relative(root, f));
    stripped++;
  }
}
console.log(stripped + ' file(s) stripped');
