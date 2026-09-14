<#
    Get-UE4SS.ps1 -- put the standard UE4SS build that the release bundles into
    ue4ss-release\.

    The release must carry exactly the UE4SS.dll our C++ mod was linked against
    (experimental v3.0.1-1021-g1c1a1497, the one the game already runs), so the
    extracted UE4SS.dll is checked by hash.

    The asset came from the rolling 'experimental-latest' GitHub release, which
    has since moved on (the URL answers 404), so a local copy of the zip is the
    normal source:

        scripts\Get-UE4SS.ps1 -Zip ..\HeadTracking\downloads\UE4SS-standard.zip

    Standard build, not zDEV: zDEV opens console windows by default. The
    UE4SS.dll inside both is byte-identical.
#>

[CmdletBinding()]
param(
    [string] $Zip = '',
    [string] $Url = 'https://github.com/UE4SS-RE/RE-UE4SS/releases/download/experimental-latest/UE4SS_v3.0.1-1021-g1c1a1497.zip'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# UE4SS.dll v3.0.1-1021-g1c1a1497 (same file in the game, in the HeadTracking
# release, and the one scripts\Build-CppMod.ps1 linked against).
$expectedDllHash = 'F31188D59B34A812AFC32DB4B6FF0C74E1B44861D1ED7967452EE4B3B6635BE1'

$dest = Join-Path $repo 'ue4ss-release'

if (-not $Zip) {
    $Zip = Join-Path $repo 'downloads\UE4SS-standard.zip'
    if (-not (Test-Path $Zip)) {
        New-Item -ItemType Directory -Force -Path (Split-Path $Zip) | Out-Null
        Write-Host "Downloading $Url"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Zip -UseBasicParsing
        } catch {
            if (Test-Path $Zip) { Remove-Item $Zip -Force }
            throw "Download failed ($($_.Exception.Message)). Pass a local copy: -Zip <path to UE4SS standard zip>"
        }
    }
}
if (-not (Test-Path $Zip)) { throw "Not found: $Zip" }

if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
Expand-Archive -Path $Zip -DestinationPath $dest -Force

$dll = Join-Path $dest 'ue4ss\UE4SS.dll'
if (-not (Test-Path $dll)) { throw "No ue4ss\UE4SS.dll in $Zip" }
$hash = (Get-FileHash $dll -Algorithm SHA256).Hash
if ($hash -ne $expectedDllHash) {
    Remove-Item $dest -Recurse -Force
    throw "UE4SS.dll hash $hash is not the build the C++ mod is linked against ($expectedDllHash)."
}
if (Test-Path (Join-Path $dest 'ue4ss\Mods\ConsoleEnablerMod') -PathType Container) {
    Write-Host 'Standard UE4SS layout confirmed.'
}
Write-Host "UE4SS ready in $dest (UE4SS.dll hash matches)" -ForegroundColor Green
