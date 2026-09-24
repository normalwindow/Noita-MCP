// Compares the base and full packages, so the split between them is explicit rather than
// assumed. Anything that needs the DLL must be in full; anything pure Lua belongs in base.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const root = process.argv[2];
if (!root) { console.error('usage: node compare_packages.js <release-root>'); process.exit(1); }

function list(dir, base) {
  const out = new Map();
  const walk = (p) => {
    for (const e of fs.readdirSync(p, { withFileTypes: true })) {
      const f = path.join(p, e.name);
      if (e.isDirectory()) walk(f);
      else {
        const rel = path.relative(base, f).replace(/\\/g, '/');
        out.set(rel, crypto.createHash('sha1').update(fs.readFileSync(f)).digest('hex').slice(0, 10));
      }
    }
  };
  walk(dir);
  return out;
}

const b = list(path.join(root, 'base'), path.join(root, 'base'));
const f = list(path.join(root, 'full'), path.join(root, 'full'));

console.log('only in full:');
for (const [k] of f) if (!b.has(k)) console.log('  ' + k);

console.log('');
console.log('only in base:');
for (const [k] of b) if (!f.has(k)) console.log('  ' + k);

console.log('');
console.log('differing content:');
let diff = 0;
for (const [k, hv] of b) {
  if (f.has(k) && f.get(k) !== hv) { console.log('  ' + k); diff++; }
}
if (!diff) console.log('  (none)');
