<#
    Build-CppMod.ps1 -- compile the RunningTrainTwitchTabletNative C++ mod
    (background chat producers + a thread-safe queue, exposed to the Lua mod).

    Produces:  Mods\RunningTrainTwitchTabletNative\dlls\main.dll
    (the layout UE4SS loads C++ mods from; enabled.txt next to dlls\ starts it)

    Recipe taken over from the sibling HeadTracking repo (HEADTRACKING_REFERENCE.md):
      1. Locate MSVC via vswhere and import the x64 developer environment.
      2. Synthesise UE4SS.lib from the shipped UE4SS.dll's export table, because we
         cannot build UE4SS from source (private UEPseudo submodule).
      3. Compile every src\Native\*.cpp and link.

    IMPORTANT (from CppUserModBase.hpp itself): "C++ mods will break if UE4SS and
    the mod don't use the same C Runtime library version. This includes them being
    compiled in different configurations (Debug/Release)." The installed UE4SS is
    Game__Shipping__Win64 built with MSVC, so we build Release with the dynamic CRT
    (/MD) and never /MDd.
#>

[CmdletBinding()]
param(
    [switch] $Clean
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

Write-Host '=== Building RunningTrainTwitchTabletNative ===' -ForegroundColor Cyan

# ------------------------------------------------------------ locate toolchain
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "vswhere not found. Install 'Build Tools for Visual Studio 2022' with the C++ workload."
}
# A still-installing instance reports isComplete=false and is hidden from the
# default query, so fall back to -all and just check for vcvars64.bat.
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) {
    $vsPath = & $vswhere -all -prerelease -products * -property installationPath |
              Where-Object { Test-Path (Join-Path $_ 'VC\Auxiliary\Build\vcvars64.bat') } |
              Select-Object -First 1
}
if (-not $vsPath) {
    throw "No MSVC C++ toolset found. Install 'Build Tools for Visual Studio 2022' with the C++ workload."
}
$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found under $vsPath" }
Write-Host "MSVC: $vsPath"

# ------------------------------------------------------------------- inputs
$game = & (Join-Path $repo 'scripts\Find-RunningTrain.ps1')
$ue4ssDll = Join-Path $game.GameExeDir 'ue4ss\UE4SS.dll'
if (-not (Test-Path $ue4ssDll)) {
    throw "UE4SS.dll not found at $ue4ssDll. Install UE4SS (e.g. the HeadTracking release) first."
}

# UE4SS keeps main.dll loaded while the game runs; the link would fail late with
# an unhelpful LNK1104, so check for the lock up front. (A first build, before
# the game ever loaded the DLL, works with the game running.)
$lockedDll = Join-Path $repo 'Mods\RunningTrainTwitchTabletNative\dlls\main.dll'
if (Test-Path $lockedDll) {
    try {
        $fs = [IO.File]::Open($lockedDll, 'Open', 'ReadWrite', 'None')
        $fs.Close()
    } catch {
        throw 'main.dll is in use (the game has it loaded). Close the game, then build.'
    }
}

$third = Join-Path $repo 'third_party'
if (-not (Test-Path (Join-Path $third 'RE-UE4SS\UE4SS\include'))) {
    Write-Host 'Build dependencies missing, fetching...' -ForegroundColor Yellow
    & (Join-Path $repo 'scripts\Get-BuildDeps.ps1')
}

$build = Join-Path $repo 'build'
if ($Clean -and (Test-Path $build)) { Remove-Item $build -Recurse -Force }
$objDir = Join-Path $build 'obj'
New-Item -ItemType Directory -Force -Path $build, $objDir | Out-Null
Get-ChildItem $objDir -Filter *.obj -ErrorAction SilentlyContinue | Remove-Item -Force

# ------------------------------------------------- import library from exports
$defFile = Join-Path $build 'UE4SS.def'
Write-Host 'Generating UE4SS.def from the shipped DLL export table...'
& python (Join-Path $repo 'scripts\gen_ue4ss_def.py') $ue4ssDll $defFile
if ($LASTEXITCODE -ne 0) { throw 'Failed to generate UE4SS.def' }

# --------------------------------------------------------------- include set
$ue4ssRoot = Join-Path $third 'RE-UE4SS'
$srcDir = Join-Path $repo 'src\Native'
$includes = @(
    (Join-Path $third 'shim')                                  # trimmed CppUserModBase.hpp must win
    $srcDir
    (Join-Path $ue4ssRoot 'UE4SS\include')
    (Join-Path $ue4ssRoot 'deps\first\File\include')
    (Join-Path $ue4ssRoot 'deps\first\String\include')
    (Join-Path $ue4ssRoot 'deps\first\Input\include')
    (Join-Path $ue4ssRoot 'deps\first\LuaMadeSimple\include')
    (Join-Path $ue4ssRoot 'deps\first\LuaRaw\include')
    (Join-Path $ue4ssRoot 'deps\first\Constructs\include')
    (Join-Path $ue4ssRoot 'deps\first\Helpers\include')
    (Join-Path $ue4ssRoot 'deps\first\DynamicOutput\include')
    (Join-Path $ue4ssRoot 'deps\first\Function\include')
    (Join-Path $third 'fmt\include')
)
foreach ($i in $includes) {
    if (-not (Test-Path $i)) { Write-Host "  (missing include dir, continuing) $i" -ForegroundColor DarkYellow }
}
$incArgs = ($includes | ForEach-Object { "/I`"$_`"" }) -join ' '

$sources = Get-ChildItem $srcDir -Filter *.cpp | ForEach-Object { "`"$($_.FullName)`"" }
if (-not $sources) { throw "No .cpp files in $srcDir" }
$srcArgs = $sources -join ' '

$outDir = Join-Path $repo 'Mods\RunningTrainTwitchTabletNative\dlls'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$outDll = Join-Path $outDir 'main.dll'

# ------------------------------------------------------------------- compile
$bat = Join-Path $build 'build.bat'
@"
@echo off
call "$vcvars" >nul
if errorlevel 1 exit /b 1

echo --- creating import library ---
lib /nologo /def:"$defFile" /machine:x64 /out:"$build\UE4SS.lib"
if errorlevel 1 exit /b 1

echo --- compiling ---
cl /nologo /c /EHsc /MD /O2 /W4 /std:c++20 /permissive- /utf-8 /D_WIN32_WINNT=0x0601 /DNOMINMAX /DWIN32_LEAN_AND_MEAN ^
   $incArgs ^
   /Fo"$objDir\\" $srcArgs
if errorlevel 1 exit /b 1

echo --- linking ---
link /nologo /DLL /MACHINE:X64 ^
   /OUT:"$outDll" /IMPLIB:"$build\main.lib" ^
   "$objDir\*.obj" "$build\UE4SS.lib" ws2_32.lib winhttp.lib secur32.lib
if errorlevel 1 exit /b 1

echo --- done ---
"@ | Set-Content -Path $bat -Encoding ASCII

& cmd.exe /c "`"$bat`""
if ($LASTEXITCODE -ne 0) { throw "Build failed (exit $LASTEXITCODE). See output above." }

if (-not (Test-Path $outDll)) { throw "Build reported success but $outDll is missing." }
$info = Get-Item $outDll
Write-Host ''
Write-Host ("Built: {0} ({1:N0} bytes)" -f $outDll, $info.Length) -ForegroundColor Green
