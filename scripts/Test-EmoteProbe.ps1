<#
    Test-EmoteProbe.ps1 -- build and run tests\native\emote_probe.cpp: the mod's
    EmoteFetcher against the real Twitch CDN, outside the game.

    Checks: two known emotes download as PNG files, a missing one fails, a bad
    id is refused without a request, and a fresh fetcher treats the files as a
    cache. Exit code 0 = all good.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw 'No MSVC C++ toolset found.' }
$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'

$out = Join-Path $repo 'build\probe'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$src = Join-Path $repo 'src\Native'
$exe = Join-Path $out 'emote_probe.exe'

$bat = Join-Path $out 'build_emote.bat'
@"
@echo off
call "$vcvars" >nul
if errorlevel 1 exit /b 1
cl /nologo /EHsc /MD /O2 /W4 /std:c++20 /utf-8 /DNOMINMAX /DWIN32_LEAN_AND_MEAN /I"$src" ^
   /Fo"$out\\" /Fe"$exe" "$repo\tests\native\emote_probe.cpp" "$src\EmoteFetcher.cpp" winhttp.lib
"@ | Set-Content -Path $bat -Encoding ASCII

& cmd.exe /c "`"$bat`""
if ($LASTEXITCODE -ne 0) { throw "Probe build failed (exit $LASTEXITCODE)." }

& $exe (Join-Path $out 'emote_cache')
exit $LASTEXITCODE
