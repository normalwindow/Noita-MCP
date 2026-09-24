// Checks that the base and full packages differ only in the ways they are meant to.
//
// Why this needs to distinguish: the two packages legitimately carry different prose (each
// README describes its own tier) and a different installer. Reporting those as differences
// alongside "a file only full has" would drown the signal -- and a check that cries wolf is
// one nobody reads, which is worse than no check.
//
// So the assertion is about STRUCTURE: the only files that may exist in one package and not
// the other are the extension's, and the only files whose contents may differ are the ones
// that describe or install a tier.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const root = process.argv[2];
if (!root) { console.error('usage: node compare_packages.js <release-root>'); process.exit(1); }

// Content differences that are correct by design: each names and installs its own tier.
const EXPECTED_CONTENT_DIFF = new Set([
  'README.md',
  'README.en.md',
  'install.ps1',
]);

// Files that belong to exactly one package. Anything else appearing on this list is a mistake.
const EXPECTED_ONLY_IN_FULL = [
  'extension/build/xinput_hook.dll',
  'extension/build.ps1',
  'extension/injector.c',
  'extension/README.md',
  'extension/SDL_EVENT_LAYOUT.txt',
  'extension/xinput_hook.c',
];

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

const problems = [];
const notes = [];

// ---- structure: which files exist where
const onlyFull = [...f.keys()].filter((k) => !b.has(k)).sort();
const onlyBase = [...b.keys()].filter((k) => !f.has(k)).sort();

const unexpectedOnlyFull = onlyFull.filter((k) => !EXPECTED_ONLY_IN_FULL.includes(k));
const unexpectedOnlyBase = onlyBase.filter(() => true);   // nothing belongs only in base

if (unexpectedOnlyFull.length) {
  problems.push('only in full, and not part of the extension:\n    ' + unexpectedOnlyFull.join('\n    '));
}
if (unexpectedOnlyBase.length) {
  problems.push('only in base -- nothing is meant to be base-only:\n    ' + unexpectedOnlyBase.join('\n    '));
}

const missingFromFull = EXPECTED_ONLY_IN_FULL.filter((k) => !f.has(k));
if (missingFromFull.length) {
  problems.push('expected in full but absent:\n    ' + missingFromFull.join('\n    '));
}

// ---- content: identical except where a tier describes itself
const differing = [];
for (const [k, hv] of b) {
  if (f.has(k) && f.get(k) !== hv) differing.push(k);
}
differing.sort();

const unexpectedDiff = differing.filter((k) => !EXPECTED_CONTENT_DIFF.has(k));
if (unexpectedDiff.length) {
  problems.push('content differs, and should not:\n    ' + unexpectedDiff.join('\n    '));
}

const expectedButSame = [...EXPECTED_CONTENT_DIFF].filter((k) => b.has(k) && !differing.includes(k));
if (expectedButSame.length) {
  notes.push('these are allowed to differ but are identical, which may mean a tier doc was not updated: ' +
    expectedButSame.join(', '));
}

// ---- report
console.log(`base: ${b.size} files, full: ${f.size} files`);
console.log(`only in full: ${onlyFull.length ? onlyFull.join(', ') : '(none)'}`);
console.log(`content differs: ${differing.length ? differing.join(', ') : '(none)'}`);
for (const n of notes) console.log('note: ' + n);

if (problems.length) {
  console.log('');
  console.log('PROBLEMS:');
  for (const p of problems) console.log('  ' + p);
  process.exit(1);
}
console.log('');
console.log('split is correct: base differs from full only by the extension and by the tier docs');
