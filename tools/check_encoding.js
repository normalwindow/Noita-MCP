// Verifies encoding integrity across a tree: no UTF-8 BOM, no mojibake.
//
// Both failure modes have occurred in this project. PowerShell 5.1's
// `Set-Content -Encoding utf8` writes a BOM, and reading a UTF-8 file as ANSI (CP936
// here) and writing it back as UTF-8 turns Chinese into mojibake -- damage that is lossy
// and was not reversible when it happened to the Chinese READMEs.
//
// Run this before committing documentation.
const fs = require('fs');
const path = require('path');

const root = process.argv[2];
if (!root) {
  console.error('usage: node check_encoding.js <dir>');
  process.exit(1);
}

const TEXT = new Set(['.md', '.txt', '.js', '.lua', '.py', '.ps1', '.json', '.xml', '.csv', '.ts']);

// Sequences that only appear when UTF-8 has been through an ANSI round-trip.
const MOJIBAKE = /[\uFFFD\u9225\u951F\u9422\u6D93\u20AC\u93C8\uFFFD]|\u9225\u003F|\u951F\u003F/;

function walk(d) {
  return fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => {
    if (e.name === '.git') return [];
    const p = path.join(d, e.name);
    return e.isDirectory() ? walk(p) : [p];
  });
}

let checked = 0;
const problems = [];
for (const f of walk(root)) {
  if (!TEXT.has(path.extname(f).toLowerCase())) continue;
  checked++;
  const b = fs.readFileSync(f);
  const rel = path.relative(root, f);
  if (b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf) {
    problems.push(rel + ': UTF-8 BOM');
  }
  const text = b.toString('utf8');
  const lines = text.split('\n');
  lines.forEach((l, i) => {
    if (MOJIBAKE.test(l)) problems.push(`${rel}:${i + 1}: ${l.trim().slice(0, 80)}`);
  });
}

console.log(`checked ${checked} text files`);
if (problems.length) {
  console.log(`${problems.length} problem(s):`);
  for (const p of problems) console.log('  ' + p);
  process.exit(1);
}
console.log('no BOMs, no mojibake');
