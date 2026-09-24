// Verifies the built release archives, by opening them rather than trusting the builder.
//
// The builder has a whitelist and a refusal check, but a whitelist can be wrong in the same
// way it can be right -- so this reads the finished archives and asserts what a user will
// actually receive. In particular it checks the two claims that matter:
//
//   * full contains a working DLL, and base contains none
//   * neither contains build INPUTS (.c, build.ps1, the layout notes, the injector)
//
// and one that is easy to get wrong: the DLL must be the same bytes as the one the mod was
// tested against. A release that ships a stale DLL fails in a way nobody can debug.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

const releaseDir = process.argv[2];
const repoRoot = process.argv[3];
const version = process.argv[4];
if (!releaseDir || !repoRoot || !version) {
  console.error('usage: node verify_release.js <release-dir> <repo-root> <version>');
  process.exit(1);
}

const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');

// Extract with PowerShell and list, so this uses the same tool that made the archive.
//
// PowerShell's ZipFileEntry.FullName uses backslashes on Windows, so entries are normalised to
// forward slashes here. The first version compared against forward-slash paths and reported
// every required file as missing -- the archive was fine and the check was wrong, which is a
// good reminder to print what was actually found when a check fails.
function listZip(zip) {
  const out = execFileSync('powershell', ['-NoProfile', '-Command',
    `Add-Type -A System.IO.Compression.FileSystem; ` +
    `$z=[IO.Compression.ZipFile]::OpenRead('${zip}'); ` +
    `$z.Entries | ForEach-Object { $_.FullName }; $z.Dispose()`],
    { encoding: 'utf8' });
  return out.split(/\r?\n/)
    .map((s) => s.trim().replace(/\\/g, '/'))
    .filter(Boolean);
}

function readZipEntry(zip, name, dest) {
  // match on the normalised name, since the archive stores backslashes
  const pattern = name.replace(/\//g, '\\');
  execFileSync('powershell', ['-NoProfile', '-Command',
    `Add-Type -A System.IO.Compression.FileSystem; ` +
    `$z=[IO.Compression.ZipFile]::OpenRead('${zip}'); ` +
    `$e=$z.Entries | Where-Object { $_.FullName -eq '${pattern}' }; ` +
    `if($e){ [IO.Compression.ZipFileExtensions]::ExtractToFile($e,'${dest}',$true) }; $z.Dispose()`],
    { stdio: 'inherit' });
  return fs.existsSync(dest);
}

const problems = [];
const notes = [];

function check(tier, zip) {
  console.log('');
  console.log('='.repeat(70));
  console.log(path.basename(zip));
  console.log('='.repeat(70));

  const entries = listZip(zip);
  console.log(`  ${entries.length} entries`);

  // ---- nothing that only a developer needs
  const buildInputs = entries.filter((p) =>
    /\.(c|h|cpp)$/i.test(p) ||
    /(^|\/)build\//.test(p) ||
    /(^|\/)build\.ps1$/i.test(p) ||
    /SDL_EVENT_LAYOUT/i.test(p) ||
    /injector/i.test(p));
  if (buildInputs.length) {
    problems.push(`${tier}: ships build inputs: ${buildInputs.join(', ')}`);
  } else {
    notes.push(`${tier}: no build inputs`);
  }

  // ---- the pieces a user needs to actually run it
  const need = [
    'install.ps1',
    'mod/noita_agent/mod.xml',
    'mod/noita_agent/init.lua',
    'mcp_server/server.js',
    'LICENSE',
    'README.md',
  ];
  const missing = need.filter((n) => !entries.includes(n));
  if (missing.length) {
    problems.push(`${tier}: missing ${missing.join(', ')}`);
    // print what IS there, so a path-format mistake is visible instead of looking like a
    // missing file
    console.log('    entries present:');
    for (const e of entries.slice(0, 12)) console.log('      ' + e);
    if (entries.length > 12) console.log(`      ... ${entries.length - 12} more`);
  }

  // ---- the tier difference
  const dlls = entries.filter((p) => /\.dll$/i.test(p));
  if (tier === 'full') {
    if (dlls.length !== 1) {
      problems.push(`full: expected exactly one DLL, found ${dlls.length} [${dlls.join(', ')}]`);
    } else if (dlls[0] !== 'extension/xinput_hook.dll') {
      // install.ps1 probes this path first; anywhere else and the extension will not be found
      problems.push(`full: the DLL is at ${dlls[0]}, which install.ps1 does not probe first`);
    } else {
      // byte-compare against the build the mod was tested with
      const tmp = path.join(releaseDir, '.__dll_check');
      if (readZipEntry(zip, 'extension/xinput_hook.dll', tmp)) {
        const shipped = sha(fs.readFileSync(tmp));
        const built = sha(fs.readFileSync(
          path.join(repoRoot, 'full', 'extension', 'xinput_hook.dll')));
        if (shipped !== built) {
          problems.push('full: the DLL in the archive differs from the one in the repository');
        } else {
          notes.push(`full: DLL matches the repository build (${fs.statSync(tmp).size} bytes, ` +
            `sha ${shipped.slice(0, 12)})`);
        }
        fs.rmSync(tmp, { force: true });
      } else {
        problems.push('full: could not read the DLL out of the archive');
      }
    }
  } else if (dlls.length) {
    // base is pure Lua by definition; a DLL here means the tier split has been broken
    problems.push(`base: must not contain a DLL, found [${dlls.join(', ')}]`);
  } else {
    notes.push('base: no DLL, as intended');
  }

  // ---- the rename reached the archive
  const install = entries.find((p) => p === 'install.ps1');
  if (install) {
    const tmp = path.join(releaseDir, '.__install_check');
    if (readZipEntry(zip, 'install.ps1', tmp)) {
      const text = fs.readFileSync(tmp, 'utf8');
      if (/Noita AI Agent/i.test(text)) {
        problems.push(`${tier}: install.ps1 still uses the old mod name`);
      }
      fs.rmSync(tmp, { force: true });
    }
  }
}

// The version is an argument, not a constant: hardcoding it meant the check silently looked for
// the previous release's archives and reported them missing, which reads like a broken build
// rather than a stale script.
const baseZip = path.join(releaseDir, `Noita-MCP-Agent-Bridge-base-v${version}.zip`);
const fullZip = path.join(releaseDir, `Noita-MCP-Agent-Bridge-full-v${version}.zip`);
for (const z of [baseZip, fullZip]) {
  if (!fs.existsSync(z)) { console.error('missing archive: ' + z); process.exit(1); }
}
check('base', baseZip);
check('full', fullZip);

console.log('');
for (const n of notes) console.log('  ok   ' + n);
if (problems.length) {
  console.log('');
  for (const p of problems) console.log('  FAIL ' + p);
  process.exit(1);
}
console.log('');
console.log('both archives are correct');
