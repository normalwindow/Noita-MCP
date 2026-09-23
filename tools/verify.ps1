# verify.ps1 -- check an installation without needing a running game
#
# Reports what is present and what is missing, so a broken setup is diagnosable
# without guessing. Everything here is read-only.

[CmdletBinding()]
param(
    [string]$NoitaDir,
    [string]$McpServer
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot

function Line($label, $ok, $detail) {
    $mark = if ($ok -eq $true) { '[ ok ]' } elseif ($ok -eq $false) { '[FAIL]' } else { '[info]' }
    Write-Host ("{0} {1,-34} {2}" -f $mark, $label, $detail)
}

Write-Host ''
Write-Host 'Noita MCP -- installation check'
Write-Host ('=' * 62)

# ---------------------------------------------------------------- node
$nodeOk = $false
try {
    $v = (& node --version) 2>$null
    if ($v) { $nodeOk = $true; Line 'Node.js' $true $v }
} catch { }
if (-not $nodeOk) { Line 'Node.js' $false 'not found on PATH -- required to run the MCP server' }

# ---------------------------------------------------------------- server file
if (-not $McpServer) {
    foreach ($c in @(
        (Join-Path $root 'base\mcp_server\server.js'),
        (Join-Path $root 'full\mcp_server\server.js'),
        (Join-Path $root 'mcp_server\server.js')
    )) { if (Test-Path $c) { $McpServer = $c; break } }
}
if ($McpServer -and (Test-Path $McpServer)) {
    Line 'MCP server' $true $McpServer
    if ($nodeOk) {
        $tools = (& node $McpServer --list 2>$null | Measure-Object).Count
        if ($tools -gt 0) { Line 'MCP tools' $true "$tools registered" }
        else { Line 'MCP tools' $false 'server did not list any tools -- check for a syntax error' }
    }
} else {
    Line 'MCP server' $false 'server.js not found'
}

# ---------------------------------------------------------------- game
if (-not $NoitaDir) {
    foreach ($c in @($env:NOITA_DIR, $env:NOITA_PATH)) { if ($c) { $NoitaDir = $c; break } }
}
if (-not $NoitaDir) {
    # Only real drives are probed. Hardcoding E: and F: produced a wall of
    # "Cannot find drive" errors on machines that do not have them, which buried the
    # actual result -- a check tool that is noisy when nothing is wrong is worse than
    # no check tool.
    $drives = (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name
    foreach ($d in $drives) {
        foreach ($sub in @('Program Files (x86)\Steam\steamapps\common\Noita',
                           'Program Files\Steam\steamapps\common\Noita',
                           'Steam\steamapps\common\Noita',
                           'SteamLibrary\steamapps\common\Noita',
                           'Games\Steam\steamapps\common\Noita',
                           'Sware\Steam\steamapps\common\Noita')) {
            $p = "${d}:\$sub"
            try {
                if (Test-Path -LiteralPath (Join-Path $p 'noita.exe') -ErrorAction SilentlyContinue) {
                    $NoitaDir = $p; break
                }
            } catch { }
        }
        if ($NoitaDir) { break }
    }
}
if ($NoitaDir -and (Test-Path (Join-Path $NoitaDir 'noita.exe'))) {
    Line 'Noita install' $true $NoitaDir
} else {
    Line 'Noita install' $false 'not found; pass -NoitaDir or set NOITA_DIR'
    $NoitaDir = $null
}

# ---------------------------------------------------------------- mod
if ($NoitaDir) {
    $mod = Join-Path $NoitaDir 'mods\noita_agent'
    if (Test-Path (Join-Path $mod 'mod.xml')) {
        $files = (Get-ChildItem $mod -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
        Line 'mod installed' $true "$files files"

        $dll = Join-Path $mod 'extensions\xinput_hook.dll'
        if (Test-Path $dll) {
            Line 'input extension DLL' $true 'present (loads inert until noita_input_install)'
        } else {
            Line 'input extension DLL' $null 'absent -- input forging unavailable, base tools still work'
        }

        $cfg = Join-Path $env:USERPROFILE 'AppData\LocalLow\Nolla_Games_Noita\save00\mod_config.xml'
        if (Test-Path $cfg) {
            $m = Select-String -Path $cfg -Pattern 'name="noita_agent"' -ErrorAction SilentlyContinue
            if ($m -and $m.Line -match 'enabled="1"') {
                Line 'mod enabled' $true 'enabled="1" in mod_config.xml'
            } elseif ($m) {
                Line 'mod enabled' $false 'disabled -- enable it in the in-game mods menu'
            } else {
                Line 'mod enabled' $false 'not listed in mod_config.xml'
            }
        } else {
            Line 'mod_config.xml' $null 'not found; the game creates it on first launch'
        }
    } else {
        Line 'mod installed' $false "no mod.xml at $mod"
    }

    # ------------------------------------------------------------ game data
    $ents = Join-Path $NoitaDir 'data\entities'
    if (Test-Path $ents) {
        $n = (Get-ChildItem $ents -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
        Line 'game data unpacked' $true "$n files in data\entities"
    } else {
        Line 'game data unpacked' $null 'run tools\unpack-data.ps1 (only noita_entity_blueprint needs it)'
    }
}

# ---------------------------------------------------------------- bridge
$run = if ($NoitaDir) { Join-Path $NoitaDir 'mods\noita_agent\run' } else { $null }
if ($run -and (Test-Path $run)) {
    $state = Join-Path $run 'state.json'
    if (Test-Path $state) {
        $age = (New-TimeSpan -Start (Get-Item $state).LastWriteTime -End (Get-Date)).TotalSeconds
        if ($age -lt 5) { Line 'bridge' $true ("alive (state written {0}s ago)" -f [int]$age) }
        else { Line 'bridge' $null ("state is {0}s old -- the bridge only runs inside a run" -f [int]$age) }
    } else {
        Line 'bridge' $null 'no state.json yet -- start a run'
    }
    $portFile = Join-Path $run 'port.json'
    if (Test-Path $portFile) { Line 'transport' $true (Get-Content $portFile -Raw).Trim() }
} else {
    Line 'bridge' $null 'run folder not created yet -- start the game with the mod enabled'
}

Write-Host ('=' * 62)
Write-Host 'The mod only initialises inside a run, so a "bridge" info line before you start one is expected.'
Write-Host ''
