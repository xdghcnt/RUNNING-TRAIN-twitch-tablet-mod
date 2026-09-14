<#
    Dev-Uninstall.ps1 -- remove exactly the lines Dev-Install.ps1 added to
    ue4ss\UE4SS-settings.ini. Everything else in the file is left as it is now
    (the backup is not restored wholesale, so later edits made by hand or by other
    mods survive).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$manifestPath = Join-Path $repo 'notes\dev-install-manifest.json'

Write-Host '=== TwitchTablet :: dev uninstall ===' -ForegroundColor Cyan

if (-not (Test-Path $manifestPath)) {
    Write-Host 'No dev-install manifest -- nothing to undo.' -ForegroundColor Yellow
    return
}
$m = Get-Content $manifestPath -Raw | ConvertFrom-Json

$procName = 'RunningTrain-Win64-Shipping'
if (Get-Process -Name $procName -ErrorAction SilentlyContinue) {
    throw 'The game is running. Close it first.'
}

$bytes = [IO.File]::ReadAllBytes($m.settingsFile)
$hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
$skip = if ($hasBom) { 3 } else { 0 }
$text = [Text.Encoding]::UTF8.GetString($bytes, $skip, $bytes.Length - $skip)
$nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }

$block = $nl + $nl + $m.marker + $nl + $m.line
if ($text.Contains($block)) {
    $text = $text.Replace($block, '')
} else {
    # Fall back to removing the two lines individually.
    $lines = $text -split "`r?`n"
    $lines = $lines | Where-Object { $_ -ne $m.marker -and $_ -ne $m.line }
    $text = $lines -join $nl
}

[IO.File]::WriteAllText($m.settingsFile, $text, (New-Object Text.UTF8Encoding($hasBom)))
Remove-Item $manifestPath -Force
Write-Host "Removed '$($m.line)' from $($m.settingsFile)" -ForegroundColor Green
