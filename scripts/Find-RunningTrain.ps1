<#
    Find-RunningTrain.ps1
    Locates the RUNNING TRAIN (Steam AppID 4630570) installation without hardcoding paths.

    Returns a PSCustomObject:
        AppId, GameDir, GameExeDir, ShippingExe, UeVersion, Arch
#>

[CmdletBinding()]
param(
    [int] $AppId = 4630570
)

$ErrorActionPreference = 'Stop'

function Get-SteamRoot {
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
                     'HKLM:\SOFTWARE\Valve\Steam',
                     'HKCU:\SOFTWARE\Valve\Steam') {
        if (Test-Path $key) {
            $p = (Get-ItemProperty $key)
            foreach ($v in @($p.InstallPath, $p.SteamPath)) {
                if ($v -and (Test-Path $v)) { return (Resolve-Path $v).Path }
            }
        }
    }
    throw 'Steam installation not found in registry.'
}

function Get-SteamLibraries {
    param([string] $SteamRoot)
    $libs = @($SteamRoot)
    $vdf = Join-Path $SteamRoot 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        $text = Get-Content $vdf -Raw
        foreach ($m in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
            $libs += $m.Groups[1].Value -replace '\\\\', '\'
        }
    }
    return ($libs | Sort-Object -Unique | Where-Object { Test-Path $_ })
}

$steam = Get-SteamRoot
$found = $null

foreach ($lib in (Get-SteamLibraries -SteamRoot $steam)) {
    $acf = Join-Path $lib "steamapps\appmanifest_$AppId.acf"
    if (-not (Test-Path $acf)) { continue }

    $text = Get-Content $acf -Raw
    $installDir = [regex]::Match($text, '"installdir"\s+"([^"]+)"').Groups[1].Value
    if (-not $installDir) { continue }

    $gameDir = Join-Path $lib "steamapps\common\$installDir"
    if (-not (Test-Path $gameDir)) { continue }

    # Locate the real Shipping executable. Do not guess the project name.
    $shipping = Get-ChildItem -Path $gameDir -Recurse -Filter '*-Win64-Shipping.exe' `
                              -ErrorAction SilentlyContinue |
                Sort-Object Length -Descending | Select-Object -First 1

    if (-not $shipping) {
        throw "Found game at '$gameDir' but no *-Win64-Shipping.exe inside it."
    }

    # PE machine type straight out of the header.
    $arch = 'unknown'
    $fs = [IO.File]::OpenRead($shipping.FullName)
    try {
        $br = New-Object IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $peOff = $br.ReadInt32()
        $fs.Position = $peOff + 4
        $machine = $br.ReadUInt16()
        if     ($machine -eq 0x8664) { $arch = 'x64' }
        elseif ($machine -eq 0xAA64) { $arch = 'arm64' }
        elseif ($machine -eq 0x014C) { $arch = 'x86' }
        else                         { $arch = ('0x{0:X4}' -f $machine) }
    } finally { $fs.Close() }

    $found = [PSCustomObject]@{
        AppId       = $AppId
        GameDir     = $gameDir
        GameExeDir  = $shipping.DirectoryName
        ShippingExe = $shipping.FullName
        UeVersion   = $shipping.VersionInfo.FileVersion
        Arch        = $arch
    }
    break
}

if (-not $found) { throw "Steam AppID $AppId (RUNNING TRAIN) is not installed in any Steam library." }

return $found
