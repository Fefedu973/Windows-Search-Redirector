param([switch]$RestoreLogging)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($RestoreLogging) { $arguments += ' -RestoreLogging' }
    $process = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru
    exit $process.ExitCode
}
$key = 'HKLM:\SOFTWARE\Windhawk\Engine\Mods\replace-windows-search-with-app'
New-Item -ItemType Directory -Path (Join-Path $root 'build') -Force | Out-Null
$backup = Join-Path $root 'build\runtime-settings-backup.json'
if ($RestoreLogging) {
    $saved = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
    Set-ItemProperty -LiteralPath $key -Name LoggingEnabled -Value ([int]$saved.LoggingEnabled)
    Set-ItemProperty -LiteralPath "$key\Settings" -Name log -Value ([int]$saved.log)
} else {
    if (-not (Test-Path -LiteralPath $backup)) {
        $config = Get-ItemProperty -LiteralPath $key
        $settings = Get-ItemProperty -LiteralPath "$key\Settings"
        @{ LoggingEnabled = $config.LoggingEnabled; log = $settings.log; textCaptureDelayMs = $settings.textCaptureDelayMs;
           LibraryFileName = $config.LibraryFileName; Version = $config.Version } | ConvertTo-Json | Set-Content -LiteralPath $backup
    }
    & (Join-Path $root 'tools\wh-tool.ps1') install -EnableAfterBuild -NoUac *> (Join-Path $root 'build\runtime-install.log')
    Set-ItemProperty -LiteralPath $key -Name LoggingEnabled -Value 1
    Set-ItemProperty -LiteralPath "$key\Settings" -Name log -Value 1
    Set-ItemProperty -LiteralPath "$key\Settings" -Name textCaptureDelayMs -Value 0
}
Set-ItemProperty -LiteralPath $key -Name SettingsChangeTime -Value ([int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
