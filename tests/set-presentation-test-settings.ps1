param(
    [ValidateSet('default','followStart','topLeft','topCenter','topRight','centerLeft','center','centerRight','bottomLeft','bottomCenter','bottomRight','custom')]
    [string]$Position = 'default',
    [ValidateRange(0,1)][int]$Instant = 1,
    [switch]$Restore
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Position $Position -Instant $Instant"
    if ($Restore) { $arguments += ' -Restore' }
    $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru
    exit $p.ExitCode
}
$key = 'HKLM:\SOFTWARE\Windhawk\Engine\Mods\replace-windows-search-with-app'
$settings = "$key\Settings"
$backup = Join-Path $root 'build\presentation-settings-backup.json'
$names = @('commandPalettePosition','instantStartDismiss')
if (-not (Test-Path -LiteralPath $backup)) {
    $saved = @{}
    $current = Get-ItemProperty -LiteralPath $settings
    foreach ($name in $names) { $saved[$name] = $current.$name }
    $saved | ConvertTo-Json | Set-Content -LiteralPath $backup
}
if ($Restore) {
    $saved = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
    Set-ItemProperty -LiteralPath $settings -Name commandPalettePosition -Value ([string]$saved.commandPalettePosition)
    Set-ItemProperty -LiteralPath $settings -Name instantStartDismiss -Value ([int]$saved.instantStartDismiss)
} else {
    Set-ItemProperty -LiteralPath $settings -Name commandPalettePosition -Value $Position
    Set-ItemProperty -LiteralPath $settings -Name instantStartDismiss -Value $Instant
}
Set-ItemProperty -LiteralPath $key -Name SettingsChangeTime -Value ([int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
