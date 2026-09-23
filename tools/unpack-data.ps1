# unpack-data.ps1 -- get the game's entity definitions onto disk (opt-in)
#
# WHAT THIS IS FOR
# ----------------
# Only one MCP tool needs unpacked game data: noita_entity_blueprint, which reads an
# entity's components and values (enemy hp and attacks, wand templates, chest
# contents). Everything else -- the catalogs, spawning, wands, the map, input -- works
# without it.
#
# WHY THE DATA IS NOT BUNDLED
# ---------------------------
# The Noita Modding Agreement says a mod "must not distribute a substantial part of
# our copyrightable code, content, assets or any other parts of the Software", so the
# ~10 MB of entity/script definitions are deliberately not in this repository.
#
# WHY THIS SCRIPT DOES NOT RUN THE GAME
# -------------------------------------
# The documented switch is `noita.exe -wizard_unpak`, and tools_modding\
# data_wak_unpack.bat is exactly that one line. On the current build (Jan 2025) that
# switch no longer writes the unpacked tree: it opens a FILE MANAGER window at
# %USERPROFILE%\AppData\LocalLow\Nolla_Games_Noita and exits with code 0, producing
# nothing. An earlier version of this script launched it unattended, which on that
# build means a game process starting and an Explorer window appearing for no reason.
# That is a bad thing for an installer to do, so it is not done automatically any
# more. This script only reports and instructs.

[CmdletBinding()]
param(
    [string]$NoitaDir,
    [switch]$OpenFolder
)

$ErrorActionPreference = 'Stop'

function Find-NoitaDir {
    param([string]$Hint)
    $candidates = @()
    if ($Hint) { $candidates += $Hint }
    foreach ($v in @($env:NOITA_DIR, $env:NOITA_PATH)) { if ($v) { $candidates += $v } }

    $drives = (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name
    foreach ($d in $drives) {
        foreach ($sub in @('Program Files (x86)\Steam\steamapps\common\Noita',
                           'Program Files\Steam\steamapps\common\Noita',
                           'Steam\steamapps\common\Noita',
                           'SteamLibrary\steamapps\common\Noita',
                           'Games\Steam\steamapps\common\Noita',
                           'Sware\Steam\steamapps\common\Noita')) {
            $candidates += "${d}:\$sub"
        }
    }
    foreach ($c in $candidates) {
        try {
            if ($c -and (Test-Path -LiteralPath (Join-Path $c 'noita.exe') -ErrorAction SilentlyContinue)) { return $c }
        } catch { }
    }
    return $null
}

$dir = Find-NoitaDir -Hint $NoitaDir
if (-not $dir) {
    Write-Host 'Could not find Noita. Pass the path explicitly:' -ForegroundColor Yellow
    Write-Host '  .\unpack-data.ps1 -NoitaDir "D:\Steam\steamapps\common\Noita"'
    exit 1
}

$entities = Join-Path $dir 'data\entities'
$wak = Join-Path $dir 'data\data.wak'

Write-Host ''
Write-Host 'Noita MCP -- game data status'
Write-Host ('=' * 62)
Write-Host "Noita        : $dir"

if (Test-Path $entities) {
    $files = Get-ChildItem $entities -Recurse -File -ErrorAction SilentlyContinue
    $mb = [math]::Round((($files | Measure-Object -Property Length -Sum).Sum / 1MB), 1)
    Write-Host "data\entities: unpacked, $($files.Count) files ($mb MB)" -ForegroundColor Green
    Write-Host ''
    Write-Host 'Nothing to do. noita_entity_blueprint will find it automatically'
    Write-Host '(it checks NOITA_DIR\data first). To rebuild the searchable index from'
    Write-Host 'your own copy:'
    Write-Host '  python tools\build_index.py'
    exit 0
}

Write-Host "data\entities: NOT present" -ForegroundColor Yellow
if (Test-Path $wak) { Write-Host "data\data.wak: present (this is where the definitions are packed)" }
Write-Host ('=' * 62)
Write-Host ''
Write-Host 'The definitions are packed inside data.wak. To get them on disk:'
Write-Host ''
Write-Host '  1. Copy the contents of  <Noita>\tools_modding\  into  <Noita>\  (the game'
Write-Host '     root, next to noita.exe) if they are not already there.'
Write-Host '  2. Run  data_wak_unpack.bat  from the game root, OR run'
Write-Host '     noita.exe -wizard_unpak  yourself, in a terminal, and watch what it says.'
Write-Host '  3. When data\entities exists, re-run this script to confirm.'
Write-Host ''
Write-Host 'Note: on the current build that switch may only open a file manager window'
Write-Host 'instead of unpacking. If so, the unpacked tree has to come from another'
Write-Host 'source -- the community maintains extractors, and older installs often still'
Write-Host 'have the folder. This tool is OPTIONAL either way:'
Write-Host ''
Write-Host '  everything except noita_entity_blueprint works without it.'
Write-Host ''
Write-Host 'If you have the data somewhere else, point the MCP server at it:'
Write-Host '  $env:NOITA_REF_DATA = "<folder containing entities>"'
Write-Host ''

if ($OpenFolder) {
    Write-Host "Opening $dir ..."
    Start-Process explorer.exe $dir
}
