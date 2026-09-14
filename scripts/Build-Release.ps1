<#
    Build-Release.ps1 -- assemble the distributable zip.

    A plain drag-and-drop archive, laid out like the HeadTracking release: the
    player extracts it into the game's Win64 folder and is done.

        dwmapi.dll, ue4ss\...                         standard UE4SS, unmodified
        ue4ss\UE4SS_Signatures\FName_Constructor.lua  UE 5.7 signature override
        ue4ss\Mods\RunningTrainTwitchTablet\          Lua mod + TwitchTablet.default.ini
        ue4ss\Mods\RunningTrainTwitchTabletNative\    C++ mod (Twitch client)

    Both mods start through enabled.txt, and mods.txt stays stock. So this
    archive and the HeadTracking one can be extracted over each other in any
    order: the UE4SS files are byte-identical, and neither overwrites what the
    other one needs.

    TwitchTablet.ini (the player's own settings) is NOT shipped: the mod creates
    it on first start, so extracting an update never wipes a channel or a
    calibration.

    Inputs: ue4ss-release\ (scripts\Get-UE4SS.ps1) and the built C++ mod
    (scripts\Build-CppMod.ps1).
#>

[CmdletBinding()]
param(
    [string] $Version = '1.0'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

Write-Host '=== TwitchTablet :: building release package ===' -ForegroundColor Cyan

$base    = Join-Path $repo 'ue4ss-release'
$staging = Join-Path $repo "build\release-$Version"
$outZip  = Join-Path $repo "dist\RunningTrain-TwitchTablet-$Version.zip"

if (-not (Test-Path (Join-Path $base 'ue4ss\UE4SS.dll'))) {
    throw "Standard UE4SS build not found at '$base'. Run scripts\Get-UE4SS.ps1 first."
}
$nativeDll = Join-Path $repo 'Mods\RunningTrainTwitchTabletNative\dlls\main.dll'
if (-not (Test-Path $nativeDll)) {
    throw 'Native main.dll not built. Run scripts\Build-CppMod.ps1 first.'
}

# Lua must compile and pass the smoke run before anything is packaged.
& python (Join-Path $repo 'scripts\check_lua.py')
if ($LASTEXITCODE -ne 0) { throw 'check_lua.py failed' }
& python (Join-Path $repo 'scripts\smoke_lua.py') | Select-Object -Last 1
if ($LASTEXITCODE -ne 0) { throw 'smoke_lua.py failed' }

# ------------------------------------------------------------------ staging
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path $staging | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $outZip) | Out-Null

Write-Host 'Copying UE4SS...'
Copy-Item (Join-Path $base '*') $staging -Recurse -Force

Write-Host 'Adding FName signature override...'
$sigDest = Join-Path $staging 'ue4ss\UE4SS_Signatures'
New-Item -ItemType Directory -Force -Path $sigDest | Out-Null
Copy-Item (Join-Path $repo 'signatures\FName_Constructor.lua') $sigDest -Force

Write-Host 'Adding mods...'
$modsDest = Join-Path $staging 'ue4ss\Mods'

$luaSrc = Join-Path $repo 'Mods\RunningTrainTwitchTablet'
$luaMod = Join-Path $modsDest 'RunningTrainTwitchTablet'
New-Item -ItemType Directory -Force -Path (Join-Path $luaMod 'scripts\tt') | Out-Null
Copy-Item (Join-Path $luaSrc 'scripts\main.lua') (Join-Path $luaMod 'scripts') -Force
# recon.lua is the M0 research probe: nothing requires it.
Get-ChildItem (Join-Path $luaSrc 'scripts\tt') -Filter '*.lua' |
    Where-Object { $_.Name -ne 'recon.lua' } |
    ForEach-Object { Copy-Item $_.FullName (Join-Path $luaMod 'scripts\tt') -Force }
Copy-Item (Join-Path $luaSrc 'TwitchTablet.default.ini') $luaMod -Force
New-Item -ItemType File -Force -Path (Join-Path $luaMod 'enabled.txt') | Out-Null

$cppMod = Join-Path $modsDest 'RunningTrainTwitchTabletNative'
New-Item -ItemType Directory -Force -Path (Join-Path $cppMod 'dlls') | Out-Null
Copy-Item $nativeDll (Join-Path $cppMod 'dlls') -Force
New-Item -ItemType File -Force -Path (Join-Path $cppMod 'enabled.txt') | Out-Null

# The shipped defaults must not carry a development channel.
$defaults = Get-Content (Join-Path $luaMod 'TwitchTablet.default.ini')
if ($defaults | Where-Object { $_ -match '^\s*Channel\s*=\s*\S' }) {
    throw 'TwitchTablet.default.ini has a Channel set; the release default must be empty.'
}

# --------------------------------------------------------------- docs at root
Copy-Item (Join-Path $repo 'release-files\README.txt') (Join-Path $staging 'TwitchTablet-README.txt') -Force
Copy-Item (Join-Path $repo 'LICENSE') (Join-Path $staging 'TwitchTablet-LICENSE.txt') -Force

# -------------------------------------------------------------------- package
if (Test-Path $outZip) { Remove-Item $outZip -Force }
Write-Host 'Compressing...'
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $outZip -CompressionLevel Optimal

$zip = Get-Item $outZip
Write-Host ''
Write-Host ("Release built: {0}" -f $zip.FullName) -ForegroundColor Green
Write-Host ("Size: {0:N2} MB" -f ($zip.Length / 1MB))
Write-Host ("SHA256: {0}" -f (Get-FileHash $outZip -Algorithm SHA256).Hash)
Write-Host ''
Write-Host 'Our files:'
Get-ChildItem $staging -Recurse -File |
    ForEach-Object { $_.FullName.Substring($staging.Length + 1) } |
    Where-Object { $_ -match 'TwitchTablet|UE4SS_Signatures' } |
    ForEach-Object { '   ' + $_ }
