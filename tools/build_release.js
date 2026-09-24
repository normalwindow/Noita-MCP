// Builds the downloadable release archives.
//
// WHY THIS EXISTS SEPARATELY FROM THE REPOSITORY
//
// The repository keeps its source: it is an Apache-2.0 project, the C is the honest record of
// how the clock hook and the input hook work, and hiding it would be worse for anyone trying to
// understand or fix them. But a repository is not a download. A player who wants the full tier
// should get the mod, the prebuilt DLL and the server -- not a C file, a build script and a
// linker invocation they have to reason about.
//
// So the archives are assembled here, from a whitelist. Nothing is included by default; a file
// has to be named. That direction matters: with a blacklist, a new source file silently ships
// until someone notices. With a whitelist, it silently does not ship -- which is the failure
// that costs nothing.
//
// The runtime layout is deliberate:
//
//   extension/xinput_hook.dll      found directly by install.ps1 and by the mod
//
// install.ps1 already probes `extension\xinput_hook.dll` before the built tree, so the archive
// needs no changes to the installer -- only the path it looks at first.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const root = process.argv[2];
const version = process.argv[3];
const outDir = process.argv[4];
if (!root || !version || !outDir) {
  console.error('usage: node build_release.js <release-root> <version> <out-dir>');
  process.exit(1);
}

const MOD = 'mod/noita_agent';

// Whitelists. Paths are relative to the tier directory, except the ROOT_DOCS below, which live
// at the repository root because they describe the project rather than a tier.
const COMMON = [
  'install.ps1',
  'README.md',
  'README.en.md',
  'mcp_server/server.js',
  'mcp_server/noita_db.json',
  'mcp_server/entity_index.json',
];

// Copied from the repository root into every archive: the licence has to travel with the code,
// and the changelog and engine notes are what make the archive self-contained -- someone
// hitting a limitation can read why it exists without cloning anything.
//
// CONTRIBUTING.md is deliberately NOT here. It is a development document: templates for adding
// a module, the release procedure, the check list. It belongs in the repository, where people
// who are going to change the code are already looking, not in a download someone took to play.
const ROOT_DOCS = [
  'LICENSE',
  'NOTICE',
  'CHANGELOG.md',
  'ENGINE-NOTES.md',
];

// The agent skill, from the repository root. install.ps1 looks for it at
// `<archive>/mcp-skill/SKILL.md` -- one level ABOVE the tier directory, because in the
// development tree a tier lives one level down from the skill. Shipping it inside the tier
// instead would mean the installer silently found nothing, which is exactly what the first
// archive did.
const ROOT_SKILL = [
  'mcp-skill/SKILL.md',
  'mcp-skill/README.md',
  'mcp-skill/README.en.md',
];

const FULL_EXTRA = [
  'extension/xinput_hook.dll',
  'extension/README.md',
];

function walk(dir, base, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, base, out);
    else out.push(path.relative(base, p).replace(/\\/g, '/'));
  }
  return out;
}

function copyInto(srcRoot, rel, destRoot) {
  const src = path.join(srcRoot, rel);
  const dst = path.join(destRoot, rel);
  if (!fs.existsSync(src)) {
    console.log(`    MISSING ${rel}`);
    return false;
  }
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.copyFileSync(src, dst);
  return true;
}

function build(tier, extras, zipName) {
  const tierDir = path.join(root, tier);
  const stage = path.join(outDir, `${tier}-stage`);
  fs.rmSync(stage, { recursive: true, force: true });
  fs.mkdirSync(stage, { recursive: true });

  // Every mod file is runtime, so the whole tree ships -- but it is enumerated rather than
  // assumed, so a stray probe left in the tree shows up in the count below.
  const modFiles = walk(path.join(tierDir, MOD), path.join(tierDir, MOD), [])
    .map((p) => `${MOD}/${p}`);

  let copied = 0;
  const wanted = COMMON.concat(extras, modFiles);
  console.log(`  ${tier}: ${wanted.length} files from the tier`);
  for (const rel of wanted) if (copyInto(tierDir, rel, stage)) copied++;
  for (const rel of ROOT_DOCS) if (copyInto(root, rel, stage)) copied++;
  // The skill goes to `<archive>/mcp-skill/`, matching where install.ps1 looks.
  for (const rel of ROOT_SKILL) if (copyInto(root, rel, stage)) copied++;

  // Assert the archive cannot carry source, rather than trusting the two lists above.
  //
  // install.ps1 is NOT source in this sense: it is what the player runs to install, and the
  // first version of this check rejected it along with the C. Only build INPUTS are refused --
  // .c/.h, the build tree, the build script, the layout notes and the standalone injector.
  const shipped = walk(stage, stage, []);
  const forbidden = shipped.filter((p) =>
    /\.(c|h|cpp)$/i.test(p) ||
    /(^|\/)build\//.test(p) ||
    /(^|\/)build\.ps1$/i.test(p) ||
    /SDL_EVENT_LAYOUT/.test(p) ||
    /(^|\/)injector/i.test(p));
  if (forbidden.length) {
    console.log('    REFUSING TO SHIP build inputs:');
    for (const f of forbidden) console.log('      ' + f);
    process.exit(1);
  }

  const zipPath = path.join(outDir, zipName);
  fs.rmSync(zipPath, { force: true });
  execFileSync('powershell', ['-NoProfile', '-Command',
    `Compress-Archive -Path '${stage}\\*' -DestinationPath '${zipPath}' -Force`],
    { stdio: 'inherit' });

  const size = (fs.statSync(zipPath).size / 1024 / 1024).toFixed(2);
  console.log(`    -> ${zipName}  (${copied} files, ${size} MB)`);
  fs.rmSync(stage, { recursive: true, force: true });
  return zipPath;
}

fs.mkdirSync(outDir, { recursive: true });
console.log(`building v${version}`);

build('base', [], `Noita-MCP-Agent-Bridge-base-v${version}.zip`);
build('full', FULL_EXTRA, `Noita-MCP-Agent-Bridge-full-v${version}.zip`);

// The full archive's DLL has to be the one the mod actually loads, so record which build it
// is. A mismatched DLL is the most likely way for this release to be wrong.
const dll = path.join(root, 'full', 'extension', 'xinput_hook.dll');
if (!fs.existsSync(dll)) {
  console.log('');
  console.log('PROBLEM: full/extension/xinput_hook.dll is absent, so the full archive has no DLL.');
  process.exit(1);
}
console.log('');
console.log(`full archive DLL: ${fs.statSync(dll).size} bytes`);
console.log('done');
