param(
    [Parameter(Mandatory)][string]$Label,
    [ValidateSet('animation-typing','animation-click')][string]$Mode = 'animation-typing',
    [int]$Left = 0, [int]$Top = 0, [int]$Width = 0, [int]$Height = 0
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
if ($Label -notmatch '^[a-zA-Z0-9-]+$') { throw 'Use a simple recording label.' }
$directory = Join-Path (Get-Location) "build\dismiss-$Label"
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$video = Join-Path $directory 'capture.mkv'
$region = ''
if ($Width -gt 0 -and $Height -gt 0) {
    $region = "-offset_x $Left -offset_y $Top -video_size $($Width)x$Height"
}
$arguments = "-y -hide_banner -loglevel warning -f gdigrab -framerate 60 -draw_mouse 0 $region -i desktop -t 7 -c:v ffv1 `"$video`""
$capture = Start-Process $ffmpeg -WindowStyle Hidden -ArgumentList $arguments -PassThru -RedirectStandardError "$directory\capture.log"
try {
    Start-Sleep -Milliseconds 750
    & .\build\runtime-regression.exe $Mode 'azertyAbC1234567890' | Tee-Object "$directory\runtime.txt"
    $testExit = $LASTEXITCODE
    $capture.WaitForExit()
    if ($capture.ExitCode -ne 0) { throw "Recording failed; see $directory\capture.log" }
    if ($testExit -ne 0) { throw "Input regression failed; see $directory\runtime.txt" }
} finally {
    if (-not $capture.HasExited) { $capture.Kill(); $capture.WaitForExit() }
    $capture.Dispose()
}
Write-Output $video
