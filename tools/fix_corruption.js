// Repairs two specific corruption sites, and nothing else.
//
// Both are the same root cause: a UTF-8 file was read as ANSI (CP936) and written back as
// UTF-8, which turns non-ASCII bytes into mojibake. The damage is lossy, so this does not
// "decode" anything -- it restores the intended text, which is known for both sites.
//
//   1. server.js  parseSimWarnings: the regex prefix became mojibake, so the parser could
//      not match the simulator's warning and the cross-check silently never fired. The
//      intended text is the literal prefix the simulator writes:
//        "[警告] 未收录的法术 'NAME'，按中性投射物处理（0 蓝耗、不改延迟）。"
//      The replacement matches on that literal prefix rather than a Unicode escape, so it
//      stays readable and diffable.
//
//   2. The English READMEs: every em dash became the two-character sequence U+9225 U+003F
//      (or U+9225 alone at a line end).
//
// Run with --check to report without writing.
const fs = require('fs');
const path = require('path');

const root = process.argv[2];
const checkOnly = process.argv.includes('--check');
if (!root) {
  console.error('usage: node fix_corruption.js <dir> [--check]');
  process.exit(1);
}

const TEXT = new Set(['.md', '.js', '.txt', '.lua', '.ps1', '.py', '.json', '.xml']);

function walk(d) {
  return fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => {
    if (e.name === '.git') return [];
    const p = path.join(d, e.name);
    return e.isDirectory() ? walk(p) : [p];
  });
}

// The simulator writes:  [警告] 未收录的法术 'NAME'，按中性投射物处理（0 蓝耗、不改延迟）。
// Match the literal prefix and capture the quoted token.
const SIM_REGEX_OLD = /const m = line\.match\(\/.*?'\(\[\^'\]\+\)'\/\);/;
const SIM_REGEX_NEW =
  "const m = line.match(/\\[警告\\] 未收录的法术 '([^']+)'/);";

// Em dash, as written by both corrupted forms. Written as escapes rather than literals
// so this file does not itself contain mojibake -- otherwise the encoding checker flags
// its own repair table.
const EMDASH_PATTERNS = [
  [/\u9225\u003F/g, '\u2014'],     // the two-character form, with the trailing "?"
  [/\u9225(?!\u003F)/g, '\u2014'], // the single-character form at a line end
];

let changed = 0;
const report = [];

for (const f of walk(root)) {
  if (!TEXT.has(path.extname(f).toLowerCase())) continue;
  const rel = path.relative(root, f);
  let text = fs.readFileSync(f, 'utf8');
  const before = text;

  // 1. the simulator warning regex
  if (rel.endsWith('server.js') && SIM_REGEX_OLD.test(text)) {
    text = text.replace(SIM_REGEX_OLD, SIM_REGEX_NEW);
    report.push(rel + ': restored the simulator warning regex');
  }

  // 2. em dashes in the English docs
  if (rel.endsWith('.md') && !rel.endsWith('.zh.md')) {
    for (const [pat, rep] of EMDASH_PATTERNS) {
      if (pat.test(text)) {
        const n = (text.match(pat) || []).length;
        text = text.replace(pat, rep);
        report.push(`${rel}: ${n} em dash(es)`);
      }
    }
  }

  if (text !== before) {
    changed++;
    if (!checkOnly) fs.writeFileSync(f, text, 'utf8');
  }
}

for (const r of report) console.log('  ' + r);
console.log(`${changed} file(s) ${checkOnly ? 'would change' : 'changed'}`);
