# ============================================================================
# build.ps1 -- builds the 32-bit input-forge DLL and the 32-bit injector
# ============================================================================
#
#   pwsh -File build.ps1            build both (default)
#   pwsh -File build.ps1 -Clean     delete build output first
#   pwsh -File build.ps1 -DllOnly   skip the injector
#   pwsh -File build.ps1 -DebugBuild  /Od /Zi instead of /O2
#
# NOTE: the switch is -DebugBuild, not -Debug, because -Debug is a reserved
# common parameter in both Windows PowerShell 5.1 and PowerShell 7 and
# redeclaring it is a parse-time error.
#
# Works on Windows PowerShell 5.1 and PowerShell 7+. No PS7-only syntax is
# used (no ternary operator, no ?? / ?. , no -Parallel).
#
# Everything is built for x86 ONLY. The script proves that afterwards by
# reading the PE COFF header of each artefact and asserting Machine == 0x014C.
# It fails loudly, printing the full compiler/linker output, on any error.
# ============================================================================

[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$DllOnly,
    [switch]$DebugBuild
)

$ErrorActionPreference = 'Stop'

$Root      = $PSScriptRoot
$BuildDir  = Join-Path $Root 'build'
$DllSource = Join-Path $Root 'xinput_hook.c'
$DllOut    = Join-Path $BuildDir 'xinput_hook.dll'
$InjSource = Join-Path $Root 'injector.c'
$InjOut    = Join-Path $BuildDir 'injector.exe'

function Fail([string]$Message) {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host ' BUILD FAILED' -ForegroundColor Red
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host $Message -ForegroundColor Red
    Write-Host ''
    exit 1
}

# ---------------------------------------------------------------- 0. sanity
if (-not (Test-Path -LiteralPath $DllSource)) { Fail "missing source: $DllSource" }
if (-not $DllOnly -and -not (Test-Path -LiteralPath $InjSource)) { Fail "missing source: $InjSource" }

if ($Clean -and (Test-Path -LiteralPath $BuildDir)) {
    Write-Host "cleaning $BuildDir"
    Remove-Item -LiteralPath $BuildDir -Recurse -Force
}
if (-not (Test-Path -LiteralPath $BuildDir)) {
    New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
}

# --------------------------------------------------------- 1. find vcvars32
function Find-VcVars32 {
    if ($env:VCVARS32 -and (Test-Path -LiteralPath $env:VCVARS32)) { return $env:VCVARS32 }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $roots = & $vswhere -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                            -property installationPath 2>$null
        foreach ($r in @($roots)) {
            if ([string]::IsNullOrWhiteSpace($r)) { continue }
            $cand = Join-Path $r.Trim() 'VC\Auxiliary\Build\vcvars32.bat'
            if (Test-Path -LiteralPath $cand) { return $cand }
        }
    }
    foreach ($v in @('Community','Professional','Enterprise','BuildTools')) {
        $cand = "C:\Program Files\Microsoft Visual Studio\2022\$v\VC\Auxiliary\Build\vcvars32.bat"
        if (Test-Path -LiteralPath $cand) { return $cand }
        $cand = "C:\Program Files (x86)\Microsoft Visual Studio\2022\$v\VC\Auxiliary\Build\vcvars32.bat"
        if (Test-Path -LiteralPath $cand) { return $cand }
    }
    return $null
}

$vcvars = Find-VcVars32
if (-not $vcvars) {
    Fail @"
Could not locate vcvars32.bat.

Looked for vswhere.exe under Program Files (x86)\Microsoft Visual Studio\Installer and
the usual C:\Program Files\Microsoft Visual Studio\2022\<edition>\VC\Auxiliary\Build paths.

Install the "Desktop development with C++" workload (Visual Studio Build Tools are enough),
or point the script at your own copy:

    `$env:VCVARS32 = 'D:\path\to\vcvars32.bat'; pwsh -File build.ps1
"@
}
Write-Host "vcvars32 : $vcvars"

# ---------------------------------------------------------- 2. build recipe
# /MT  -> static CRT, no vcruntime redist dependency inside the game process
# /GS- on the DLL: no __security_cookie in a module we inject
# /guard:cf- : no Control Flow Guard metadata requirement on the injected image
# /LD  -> DLL
$commonFlags = @('/nologo', '/W3', '/MT', '/D_CRT_SECURE_NO_WARNINGS')
if ($DebugBuild) {
    $optFlags = @('/Od', '/Zi', '/D_DEBUG')
} else {
    $optFlags = @('/O2', '/GS-', '/guard:cf-', '/DNDEBUG')
}

$dllCl = @('cl', '/LD') + $commonFlags + $optFlags + @(
    ('"' + $DllSource + '"'),
    '/link', '/INCREMENTAL:NO', '/MACHINE:X86',
    ('/OUT:"' + $DllOut + '"')
)

$injCl = @('cl') + $commonFlags + $optFlags + @(
    ('"' + $InjSource + '"'),
    '/link', '/INCREMENTAL:NO', '/MACHINE:X86',
    ('/OUT:"' + $InjOut + '"'),
    'kernel32.lib', 'user32.lib', 'advapi32.lib'
)

function Invoke-Cl([string]$Label, [string[]]$ClArgs) {
    $cmdLine = ($ClArgs -join ' ')

    Write-Host ''
    Write-Host "--- $Label ---"
    Write-Host "$cmdLine"
    Write-Host ''

    # Why a generated .bat instead of `cmd /c "..."`:
    #   cmd.exe strips the outermost pair of quotes from a /c argument, which
    #   destroys the quotes around "C:\Program Files\...\vcvars32.bat" and
    #   produces the notorious `'C:\Program' is not recognized` error. Trying to
    #   out-escape it from PowerShell is fragile across PS 5.1 and PS 7.
    #   Writing a two-line batch file has no quoting problem at all.
    $bat = Join-Path $BuildDir "$Label.cmd"
    $batLines = @(
        '@echo off',
        "call `"$vcvars`" >nul 2>&1",
        "if errorlevel 1 echo ERROR: vcvars32.bat failed to initialise & exit /b 9009",
        "$cmdLine",
        'exit /b %errorlevel%'
    )
    Set-Content -LiteralPath $bat -Value $batLines -Encoding ASCII

    $outFile = Join-Path $BuildDir "$Label.log"
    $errFile = Join-Path $BuildDir "$Label.err"
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue

    Write-Host '--- output ---'
    # Run the batch file through cmd explicitly (a .cmd is not directly
    # executable from PowerShell without the extension being patched in).
    & "$env:SystemRoot\System32\cmd.exe" /c $bat > $outFile 2> $errFile
    $code = $LASTEXITCODE

    $stdout = ''
    $stderr = ''
    if (Test-Path -LiteralPath $outFile) { $stdout = Get-Content -LiteralPath $outFile -Raw }
    if (Test-Path -LiteralPath $errFile) { $stderr = Get-Content -LiteralPath $errFile -Raw }

    if ($stdout) { Write-Host ($stdout.TrimEnd()) }
    if ($stderr) { Write-Host ($stderr.TrimEnd()) }
    Write-Host '--- end output ---'

    if ($code -eq 9009) {
        Fail "$Label could not start: vcvars32.bat did not initialise (exit 9009)."
    }
    if ($code -ne 0) {
        Fail "$Label failed with exit code $code. Compiler output above."
    }
    # cl can report errors yet still exit 0 in odd cases; check the text too.
    if ($stdout -match '(?m)(error|fatal error)\s+[A-Z]+\d+' -or
        $stderr -match '(?m)(error|fatal error)\s+[A-Z]+\d+') {
        Fail "$Label reported errors in its output (see above) despite exit code 0."
    }
}

# ------------------------------------------------------------- 3. run builds
Invoke-Cl 'dll' $dllCl
if (-not $DllOnly) { Invoke-Cl 'injector' $injCl }

# ------------------------------------------------- 4. assert it is really x86
function Get-PeMachine([string]$Path) {
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $lfanew = $br.ReadInt32()
        $fs.Position = $lfanew
        $sig = $br.ReadUInt32()
        if ($sig -ne 0x00004550) { throw "$Path is not a PE image (bad signature 0x$($sig.ToString('X8')))" }
        return $br.ReadUInt16()   # IMAGE_FILE_HEADER.Machine
    } finally {
        $fs.Dispose()
    }
}

Write-Host ''
Write-Host '--- verification ---'

$artifacts = @($DllOut)
if (-not $DllOnly) { $artifacts += $InjOut }

foreach ($a in $artifacts) {
    if (-not (Test-Path -LiteralPath $a)) { Fail "expected artefact missing: $a" }
    $m = Get-PeMachine $a
    $name = if ($m -eq 0x014C) { 'i386 (32-bit) OK' } else { "UNEXPECTED (0x$($m.ToString('X4')))" }
    Write-Host ("  {0,-22} machine=0x{1:X4}  {2}" -f (Split-Path $a -Leaf), $m, $name)
    if ($m -ne 0x014C) {
        Fail "$a is not a 32-bit (i386) image -- machine=0x$($m.ToString('X4')). Noita is 32-bit; this DLL could never be injected."
    }
}

# Check the DLL's export table actually contains what we promised.
function Get-PeExports([string]$Path) {
    # Uses dumpbin from the same toolchain; falls back to nothing if absent.
    $full = "`"$vcvars`" >nul 2>&1 && dumpbin /nologo /exports `"$Path`""
    $o = & cmd.exe /c $full 2>$null
    $names = @()
    foreach ($line in $o) {
        if ($line -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]{8}\s+(\S+)') { $names += $Matches[1] }
    }
    return $names
}

$required = @('xh_ping','xh_set_key_forge','xh_clear_forges','xh_set_mouse_forge',
              'xh_forge_frames_left','xh_set_ttl')
try {
    $exports = Get-PeExports $DllOut
    if ($exports.Count -gt 0) {
        $missing = @($required | Where-Object { $exports -notcontains $_ })
        if ($missing.Count -gt 0) {
            Fail "DLL is missing required exports: $($missing -join ', ')"
        }
        Write-Host ("  exports               {0} found, all {1} required ones present" -f `
                    $exports.Count, $required.Count)
    } else {
        Write-Host '  exports               (dumpbin unavailable; skipped export check)'
    }
} catch {
    Write-Host "  exports               (export check skipped: $($_.Exception.Message))"
}

Write-Host ''
Write-Host 'BUILD OK' -ForegroundColor Green
Write-Host "  DLL      : $DllOut"
if (-not $DllOnly) { Write-Host "  INJECTOR : $InjOut" }
Write-Host ''
