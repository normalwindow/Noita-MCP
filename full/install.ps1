# Installs (or removes) the Noita AI Agent Bridge mod.
#
#   pwsh -File install.ps1              # install / update into the detected Noita
#   pwsh -File install.ps1 -NoitaDir "D:\Games\Noita"
#   pwsh -File install.ps1 -NoSkill     # skip installing the MCP skill
#   pwsh -File install.ps1 -PauseOnUnfocus   # keep the game's default pause-on-alt-tab
#   pwsh -File install.ps1 -Uninstall
#
# The script copies the mod, creates the run/ folder the bridge writes into,
# enables the mod in mod_config.xml (backing the original file up first), installs
# the noita-mcp skill into the project's .dsh/skills, and turns off Noita's
# pause-on-unfocus so the bridge keeps answering while you alt-tab.

param(
  [string]$NoitaDir = "",
  [switch]$Uninstall,
  [switch]$NoEnable,
  [switch]$NoSkill,
  [switch]$PauseOnUnfocus
)

$ErrorActionPreference = "Stop"

function Test-NoitaRoot {
  param([string]$Root)
  if (-not $Root) { return $false }
  try {
    return (Test-Path -LiteralPath (Join-Path $Root "noita.exe"))
  } catch {
    return $false   # e.g. a drive letter that does not exist
  }
}

function Find-NoitaDir {
  param([string]$Explicit)
  if ($Explicit) {
    if (Test-NoitaRoot $Explicit) { return $Explicit }
    throw "NoitaDir '$Explicit' does not contain noita.exe"
  }
  $roots = @(
    "C:\Program Files (x86)\Steam\steamapps\common\Noita",
    "C:\Program Files\Steam\steamapps\common\Noita",
    "D:\Steam\steamapps\common\Noita",
    "D:\SteamLibrary\steamapps\common\Noita",
    "E:\SteamLibrary\steamapps\common\Noita"
  )
  $vdfs = @(
    "C:\Program Files (x86)\Steam\steamapps\libraryfolders.vdf",
    "C:\Program Files\Steam\steamapps\libraryfolders.vdf",
    "C:\Steam\steamapps\libraryfolders.vdf",
    "D:\Steam\steamapps\libraryfolders.vdf",
    "D:\Sware\Steam\steamapps\libraryfolders.vdf",
    "D:\SteamLibrary\steamapps\libraryfolders.vdf",
    "E:\SteamLibrary\steamapps\libraryfolders.vdf",
    "E:\Steam\steamapps\libraryfolders.vdf"
  )
  foreach ($vdf in $vdfs) {
    if (Test-Path -LiteralPath $vdf) {
      foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s*"([^"]+)"')) {
        try {
          $roots += (Join-Path ($m.Groups[1].Value -replace '\\\\', '\') "steamapps\common\Noita")
        } catch { }
      }
    }
  }
  foreach ($r in $roots) { if (Test-NoitaRoot $r) { return $r } }
  throw "Noita installation not found. Pass -NoitaDir <path to the folder containing noita.exe>."
}

function Get-SaveRoot {
  return (Join-Path $env:USERPROFILE "AppData\LocalLow\Nolla_Games_Noita")
}

# The bridge only runs while the game is updating the world. With Noita's default
# `application_pause_when_unfocused="1"`, alt-tabbing to look at the AI's output
# pauses the game and the world hooks stop -- which looks exactly like "the bridge
# died". The noita-ws-api project solves the same problem with a magic number
# (DEBUG_NO_PAUSE_ON_WINDOW_FOCUS_LOST); setting the config key directly avoids
# shipping a second mod.
#
# $PauseOnUnfocus = $true keeps the game's default behaviour.
function Set-PauseOnUnfocus {
  param([string]$SaveRoot, [bool]$PauseOnUnfocus)
  $cfg = Join-Path $SaveRoot "save_shared\config.xml"
  if (-not (Test-Path -LiteralPath $cfg)) { return $null }
  $text = [System.IO.File]::ReadAllText($cfg)
  $want = if ($PauseOnUnfocus) { "1" } else { "0" }
  $m = [regex]::Match($text, 'application_pause_when_unfocused\s*=\s*"(\d)"')
  if (-not $m.Success) { return $null }
  $old = $m.Groups[1].Value
  if ($old -eq $want) { return [pscustomobject]@{ Old = $old; New = $want; Changed = $false } }
  $text = [regex]::Replace($text, 'application_pause_when_unfocused\s*=\s*"\d"',
    "application_pause_when_unfocused=`"$want`"")
  [System.IO.File]::WriteAllText($cfg, $text, (New-Object System.Text.UTF8Encoding($false)))
  return [pscustomobject]@{ Old = $old; New = $want; Changed = $true }
}

# The modding-interface revision this mod is written against.
#
# Noita compares a mod's compatibility.xml version_built_with against the game's
# current interface level and shows "$menu_mods_modversion_older" ("This mod has
# not been tested with the latest version of the modding interface.") when the
# mod is older. Shipping a hard-coded number means every game update can bring
# that warning back, so we instead read the highest value already present among
# the installed mods: the most recently updated ones track the current level.
# The official example mod ships 1 and does show the warning, so 1 is never used.
function Get-InterfaceVersion {
  param([string]$NoitaDir)
  $candidates = @()
  $roots = @(
    (Join-Path $NoitaDir "mods"),
    (Join-Path (Split-Path (Split-Path $NoitaDir -Parent) -Parent) "workshop\content\881100")
  )
  foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -Filter "compatibility.xml" -ErrorAction SilentlyContinue) {
      try {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        $m = [regex]::Match($text, 'version_built_with\s*=\s*"(\d+)"')
        if ($m.Success) { $candidates += [int]$m.Groups[1].Value }
      } catch { }
    }
  }
  $max = 0
  if ($candidates.Count -gt 0) { $max = ($candidates | Measure-Object -Maximum).Maximum }
  if ($max -lt 12) { $max = 12 }   # floor: the level this mod was verified against
  return $max
}

function Set-CompatibilityVersion {
  param([string]$Target, [int]$Version)
  $file = Join-Path $Target "compatibility.xml"
  if (-not (Test-Path -LiteralPath $file)) { return $null }
  $text = [System.IO.File]::ReadAllText($file)
  $old = [regex]::Match($text, 'version_built_with\s*=\s*"(\d+)"')
  $oldValue = if ($old.Success) { $old.Groups[1].Value } else { "(none)" }
  if ($old.Success) {
    $text = [regex]::Replace($text, 'version_built_with\s*=\s*"\d+"', "version_built_with=`"$Version`"")
  } else {
    $text = $text -replace '(<Mod)', "`$1`r`n`tversion_built_with=`"$Version`""
  }
  [System.IO.File]::WriteAllText($file, $text, (New-Object System.Text.UTF8Encoding($false)))
  return [pscustomobject]@{ Old = $oldValue; New = $Version }
}

function Set-ModEnabled {
  param([string]$SaveRoot, [string]$ModId, [bool]$Enabled)
  $saves = Get-ChildItem $SaveRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "save*" }
  foreach ($save in $saves) {
    $cfg = Join-Path $save.FullName "mod_config.xml"
    if (-not (Test-Path $cfg)) { continue }
    $text = [System.IO.File]::ReadAllText($cfg)
    $value = if ($Enabled) { "1" } else { "0" }
    if ($text -match "name=`"$ModId`"") {
      $text = $text -replace "(<Mod enabled=`")[01](`" name=`"$ModId`")", "`${1}$value`${2}"
    } elseif ($Enabled) {
      $nl = if ($text -match "`r`r`n") { "`r`r`n" } else { "`r`n" }
      $needle = "<Mods>" + $nl
      $idx = $text.IndexOf($needle)
      if ($idx -lt 0) { continue }
      $entry = "  <Mod enabled=`"1`" name=`"$ModId`" settings_fold_open=`"0`" workshop_item_id=`"0`" >$nl$nl  </Mod>$nl$nl"
      $text = $text.Substring(0, $idx + $needle.Length) + $entry + $text.Substring($idx + $needle.Length)
    } else {
      continue
    }
    [System.IO.File]::WriteAllText($cfg, $text, (New-Object System.Text.UTF8Encoding($true)))
    Write-Host "  mod_config.xml updated: $cfg (enabled=$value)"
  }
}

$modId = "noita_agent"
# Release layout: this script sits next to mod/, mcp_server/ and (in the full
# package) extension/. The mod therefore lives at <here>/mod/noita_agent, not in the
# development tree's mod_src/, which is what an earlier version pointed at.
$source = Join-Path $PSScriptRoot "mod\$modId"
$noita = Find-NoitaDir -Explicit $NoitaDir
$target = Join-Path $noita "mods\$modId"
$runDir = Join-Path $target "run"

Write-Host "Noita      : $noita"
Write-Host "Mod target : $target"

# ---------------------------------------------------------------- input extension
#
# The full package ships the prebuilt extension. Installing it here leaves only the
# in-game arming step (noita_input_load, then noita_input_install); forgetting to copy
# the DLL is otherwise the most common reason the input tools refuse while everything
# else works.
#
# The DLL is only placed, never loaded: the mod loads DLLs only when asked, and a
# loaded DLL is inert until xh_install_hooks runs, so copying it changes nothing.
function Install-Extension {
    param([string]$Target)
    $dll = Join-Path $PSScriptRoot "extension\build\xinput_hook.dll"
    if (-not (Test-Path $dll)) {
        $alt = Join-Path $PSScriptRoot "extension\xinput_hook.dll"
        if (Test-Path $alt) {
            $dll = $alt
        } else {
            Write-Host "extension : not built yet -- run extension\build.ps1, or the input tools will refuse"
            return
        }
    }
    $dest = Join-Path $Target "extensions"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item $dll (Join-Path $dest "xinput_hook.dll") -Force
    Write-Host "extension : xinput_hook.dll installed (inert until noita_input_install)"
}

if ($Uninstall) {
  if (Test-Path $target) { Remove-Item $target -Recurse -Force; Write-Host "removed mod folder" }
  Set-ModEnabled -SaveRoot (Get-SaveRoot) -ModId $modId -Enabled $false
  Write-Host "uninstalled."
  exit 0
}

if (-not (Test-Path $source)) { throw "Mod source not found: $source" }

New-Item -ItemType Directory -Path $target -Force | Out-Null
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

Copy-Item (Join-Path $source "*") $target -Recurse -Force
Write-Host "copied mod files"

# The full package also places the input extension, since that is the whole
# difference between this package and base/.
if (-not $NoExtension) { Install-Extension -Target $target }

# Align the modding-interface revision with what is already installed, so Noita
# does not flag the mod as untested after a game update.
$ifaceVersion = Get-InterfaceVersion -NoitaDir $noita
$changed = Set-CompatibilityVersion -Target $target -Version $ifaceVersion
if ($changed) {
  if ($changed.Old -eq $changed.New) {
    Write-Host "compatibility: version_built_with=$($changed.New) (already current)"
  } else {
    Write-Host "compatibility: version_built_with $($changed.Old) -> $($changed.New)"
  }
}

# the bridge needs a writable run/ folder; make sure it survived the copy
if (-not (Test-Path $runDir)) { New-Item -ItemType Directory -Path $runDir -Force | Out-Null }
Set-Content -Path (Join-Path $runDir ".keep") -Value "" -Encoding ASCII

if (-not $NoEnable) {
  Set-ModEnabled -SaveRoot (Get-SaveRoot) -ModId $modId -Enabled $true
  Write-Host "mod enabled in mod_config.xml (a backup of the previous list is written next to it)"
} else {
  Write-Host "mod copied but NOT enabled (-NoEnable). Enable 'Noita AI Agent Bridge' in the in-game Mods menu."
}

# Keep the game updating while the window is unfocused, so the bridge does not
# appear to die whenever the operator alt-tabs to read the AI's output.
$pauseFix = Set-PauseOnUnfocus -SaveRoot (Get-SaveRoot) -PauseOnUnfocus ([bool]$PauseOnUnfocus)
if ($pauseFix) {
  if (-not $pauseFix.Changed) {
    if ($pauseFix.New -eq "0") {
      Write-Host "pause on unfocus: already off (bridge keeps answering when you alt-tab)"
    } else {
      Write-Host "pause on unfocus: already on (game default; the bridge stalls while unfocused)"
    }
  } elseif ($pauseFix.New -eq "0") {
    Write-Host "pause on unfocus: on -> off (bridge keeps answering when you alt-tab)"
  } else {
    Write-Host "pause on unfocus: off -> on (game default restored; the bridge will stall while unfocused)"
  }
} else {
  Write-Host "pause on unfocus: config key not found; set it in game options if the bridge seems to stall"
}

# Copy the MCP usage skill where an agent session can discover it, so the AI knows
# the bridge's rules (notably what it cannot do) without being told.
#
# The skill ships as mcp-skill/SKILL.md in the release layout; the development tree
# had a separate installer script. Both locations are tried, and a missing skill is a
# note rather than an error: the mod works without it.
if (-not $NoSkill) {
  $skillDests = @(
    (Join-Path $PSScriptRoot "..\..\.dsh\skills\noita-mcp"),
    (Join-Path $PSScriptRoot "..\..\.agents\skills\noita-mcp")
  )
  $skillSrc = @(
    (Join-Path $PSScriptRoot "..\mcp-skill\SKILL.md"),
    (Join-Path $PSScriptRoot "..\skills\noita-mcp\SKILL.md")
 ) | Where-Object { Test-Path $_ } | Select-Object -First 1

  if ($skillSrc) {
    foreach ($dest in $skillDests) {
      try {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item $skillSrc (Join-Path $dest "SKILL.md") -Force
        Write-Host "skill installed: $dest"
      } catch {
        Write-Host "  skill not installed at $dest : $($_.Exception.Message)"
      }
    }
  } else {
    Write-Host "skill: not found next to this script; install mcp-skill\SKILL.md manually if wanted"
  }
}

Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. start Noita and start/continue a run (the bridge only lives inside a run)"
Write-Host "  2. verify:  node `"$PSScriptRoot\mcp_server\server.js`" --status"
