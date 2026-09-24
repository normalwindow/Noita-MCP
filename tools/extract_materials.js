// Extracts the material catalogue from the game's own materials.xml.
//
// THE FORMAT
//
// The file is NOT a tree of elements. Each material is a run of `key="value"` lines beginning
// with `name="..."` and separated by blank lines, inside a single <Materials> wrapper. A tag-level
// scan finds nothing, which is why the first attempt reported zero definitions while the file
// plainly contained them.
//
// WHAT THIS IS FOR
//
// The AI needs to know what each material IS -- its class, whether it burns, what it freezes to,
// what it is dangerous as. That is a lookup table, and it is buildable offline from this file.
//
// What it is NOT: a way to know which material occupies a given cell. The engine cannot report
// that from Lua (no GetMaterial/GetCell), so runtime perception has to work by BEHAVIOUR -- see
// the terrain and material-class tools. This catalogue is the other half: given a material name,
// what does it mean.
const fs = require('fs');
const path = require('path');

const src = process.argv[2];
if (!src) { console.error('usage: node extract_materials.js <materials.xml> [out.json]'); process.exit(1); }
const outPath = process.argv[3];

const lines = fs.readFileSync(src, 'utf8').split(/\r?\n/);

const ATTR = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]*)"\s*$/;

const materials = [];
let cur = null;

for (const line of lines) {
  const m = ATTR.exec(line);
  if (!m) {
    // A blank line or a comment ends the current definition. Comments matter: the file's header
    // block contains `* fire` and `* water` as prose, which would otherwise parse as materials.
    if (cur && (line.trim() === '' || line.trim().startsWith('<!--') || line.trim().startsWith('*'))) {
      if (cur.name) materials.push(cur);
      cur = null;
    }
    continue;
  }
  const key = m[1];
  const value = m[2];

  if (key === 'name') {
    // a new definition starts here, so close the previous one
    if (cur && cur.name) materials.push(cur);
    cur = { name: value };
  } else if (cur) {
    cur[key] = value;
  }
}
if (cur && cur.name) materials.push(cur);

// ---- report
const byType = {};
for (const mat of materials) {
  const t = mat.cell_type || '(none)';
  byType[t] = (byType[t] || 0) + 1;
}

// Which attributes are worth carrying, and how many definitions actually have them. Coverage
// matters: a field present on 12 of 223 materials is a footnote, not a column.
const coverage = {};
for (const mat of materials) {
  for (const k of Object.keys(mat)) coverage[k] = (coverage[k] || 0) + 1;
}

console.log(`  ${materials.length} materials from ${path.basename(src)}`);
console.log('');
console.log('  by cell_type -- the coarse class:');
for (const [t, n] of Object.entries(byType).sort((a, b) => b[1] - a[1])) {
  console.log(`    ${t.padEnd(14)} ${n}`);
}
console.log('');
console.log('  attribute coverage (present on at least half):');
for (const [k, n] of Object.entries(coverage).sort((a, b) => b[1] - a[1])) {
  if (n >= materials.length / 2) console.log(`    ${k.padEnd(30)} ${n}`);
}
console.log('');
console.log('  dangerous materials, by what they are dangerous as:');
for (const kind of ['danger_fire', 'danger_acid', 'danger_radioactive', 'danger_poison']) {
  const list = materials.filter((x) => x[kind] && x[kind] !== '0' && x[kind] !== '');
  if (list.length) {
    console.log(`    ${kind.replace('danger_', '').padEnd(12)} ${list.length}: ` +
      list.slice(0, 8).map((x) => x.name).join(', ') + (list.length > 8 ? ', ...' : ''));
  }
}

if (outPath) {
  // A trimmed shape for the shipped database: the fields that describe what a material IS, with
  // the long tail of rendering and stain parameters dropped. Those matter to the engine's
  // graphics, not to anything an agent decides.
  const KEEP = [
    'name', 'ui_name', 'cell_type', 'tags', 'liquid', 'burnable', 'density',
    'danger_fire', 'danger_acid', 'danger_radioactive', 'danger_poison',
    'temperature_of_fire', 'generates_smoke', 'requires_oxygen',
    'cold_freezes_to_material', 'warmth_melts_to_material', 'on_fire',
    'liquid_gravity', 'liquid_sand', 'liquid_stains', 'status_effects',
  ];
  const trimmed = materials.map((mat) => {
    const o = {};
    for (const k of KEEP) if (mat[k] !== undefined) o[k] = mat[k];
    // tags come through as "[a],[b],[c]" -- a list is easier to use than a string to re-split
    if (typeof o.tags === 'string') {
      o.tags = o.tags.split(',').map((s) => s.replace(/^\[|\]$/g, '').trim()).filter(Boolean);
    }
    return o;
  });

  fs.writeFileSync(outPath, JSON.stringify({
    source: path.basename(src),
    counts: { total: materials.length, by_cell_type: byType },
    materials: trimmed,
  }, null, 1), 'utf8');
  console.log('');
  console.log(`  wrote ${outPath} (${(fs.statSync(outPath).size / 1024).toFixed(0)} KB, ` +
    `${trimmed.length} materials)`);
}
