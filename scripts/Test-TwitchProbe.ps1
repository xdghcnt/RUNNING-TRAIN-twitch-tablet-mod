<#
    Test-TwitchProbe.ps1 -- build and run tests\native\twitch_probe.cpp: the mod's
    TwitchClient + ChatQueue against the real Twitch, outside the game.

    Checks: connect + join, messages with display-name and colour, a simulated
    network drop halfway through followed by an automatic reconnect, and a
    prompt stop(). Exit code 0 = all good.

    Usage:  powershell -ExecutionPolicy Bypass -File .\scripts\Test-TwitchProbe.ps1 -Channel <some live channel> -Seconds 40
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Channel,
    [int] $Seconds = 40
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw 'No MSVC C++ toolset found.' }
$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'

$out = Join-Path $repo 'build\probe'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$src = Join-Path $repo 'src\Native'
$exe = Join-Path $out 'twitch_probe.exe'

$bat = Join-Path $out 'build.bat'
@"
@echo off
call "$vcvars" >nul
if errorlevel 1 exit /b 1
cl /nologo /EHsc /MD /O2 /W4 /std:c++20 /utf-8 /DNOMINMAX /DWIN32_LEAN_AND_MEAN /I"$src" ^
   /Fo"$out\\" /Fe"$exe" "$repo\tests\native\twitch_probe.cpp" "$src\TwitchClient.cpp" "$src\TlsStream.cpp" "$src\ChatQueue.cpp" ws2_32.lib secur32.lib
"@ | Set-Content -Path $bat -Encoding ASCII

& cmd.exe /c "`"$bat`""
if ($LASTEXITCODE -ne 0) { throw "Probe build failed (exit $LASTEXITCODE)." }

# UTF-8 console output so Cyrillic / Japanese chat reads correctly.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
& $exe $Channel $Seconds
exit $LASTEXITCODE
