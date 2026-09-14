<#
    Dev-Install.ps1 -- point the game's existing UE4SS at this repo's Mods folder.

    It does NOT install UE4SS. UE4SS (with the UE 5.7 FName signature override) is
    already in the game from the HeadTracking release; see HEADTRACKING_REFERENCE.md.

    The only change to the game folder is one line in ue4ss\UE4SS-settings.ini:

        +ModsFolderPaths = <this repo>/Mods

    so the mod runs straight from the working tree and nothing is copied into the
    game. The original file is backed up to backup\ first, and the exact line added
    is recorded in notes\dev-install-manifest.json for Dev-Uninstall.ps1.

    Usage:  powershell -ExecutionPolicy Bypass -File .\scripts\Dev-Install.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

Write-Host '=== TwitchTablet :: dev install ===' -ForegroundColor Cyan

$game = & (Join-Path $repo 'scripts\Find-RunningTrain.ps1')
$settings = Join-Path $game.GameExeDir 'ue4ss\UE4SS-settings.ini'
if (-not (Test-Path $settings)) {
    throw "UE4SS is not installed in the game ($settings missing). Install the HeadTracking release or UE4SS first."
}

$procName = [IO.Path]::GetFileNameWithoutExtension($game.ShippingExe)
if (Get-Process -Name $procName -ErrorAction SilentlyContinue) {
    throw 'The game is running. Close it first: UE4SS reads its settings only at startup.'
}

$modsPath = (Join-Path $repo 'Mods') -replace '\\', '/'
$line = "+ModsFolderPaths = $modsPath"
$marker = '; --- added by TwitchTablet Dev-Install.ps1 ---'

# Byte-exact read so the file keeps its encoding (currently ASCII, no BOM) and
# line endings.
$bytes = [IO.File]::ReadAllBytes($settings)
$hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
$text = [Text.Encoding]::UTF8.GetString($bytes, ($(if ($hasBom) { 3 } else { 0 })), $bytes.Length - ($(if ($hasBom) { 3 } else { 0 })))
$nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }

if ($text.Contains($line)) {
    Write-Host "Already registered: $modsPath" -ForegroundColor Green
    return
}

$anchor = [regex]::Match($text, '(?m)^ControllingModsTxt\s*=.*$')
if (-not $anchor.Success) {
    throw "Could not find the 'ControllingModsTxt' line in [Overrides] of $settings -- refusing to guess where to insert."
}

$backupDir = Join-Path $repo 'backup'
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $backupDir "UE4SS-settings.ini.$stamp"
Copy-Item $settings $backup -Force
Write-Host "Backup: $backup"

$insert = $nl + $nl + $marker + $nl + $line
$newText = $text.Insert($anchor.Index + $anchor.Length, $insert)

$enc = New-Object Text.UTF8Encoding($hasBom)
[IO.File]::WriteAllText($settings, $newText, $enc)

$manifest = [PSCustomObject]@{
    installedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    settingsFile   = $settings
    backup         = $backup
    marker         = $marker
    line           = $line
}
New-Item -ItemType Directory -Force -Path (Join-Path $repo 'notes') | Out-Null
$manifestPath = Join-Path $repo 'notes\dev-install-manifest.json'
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))

Write-Host "Registered mods folder: $modsPath" -ForegroundColor Green
Write-Host "Manifest: $manifestPath"
Write-Host 'Undo with scripts\Dev-Uninstall.ps1.'
