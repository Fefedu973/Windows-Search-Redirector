param(
    [ValidateRange(1, 10)][int]$Passes = 1,
    [switch]$NativeOnly
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root 'build'
New-Item -ItemType Directory -Path $build -Force | Out-Null
$exe = Join-Path $build 'runtime-regression.exe'
& g++ -std=c++17 -O2 -municode -static -DUNICODE -D_UNICODE (Join-Path $PSScriptRoot 'runtime-regression.cpp') -luser32 -lgdi32 -ldwmapi -lshlwapi -lole32 -loleaut32 -luuid -o $exe
if ($LASTEXITCODE -ne 0) { throw 'Regression harness compilation failed.' }

if ($NativeOnly) {
    if (Get-Process Microsoft.CmdPal.UI -ErrorAction SilentlyContinue) {
        throw 'NativeOnly requires Command Palette to be stopped first. This script does not stop it.'
    }
    $cases = @(
        @{ mode = 'native-wins'; text = 'nativeAzerty123' },
        @{ mode = 'native-typing'; text = 'nativeStart123' },
        @{ mode = 'native-click'; text = '' }
    )
} else {
    $cases = @(
        @{ mode = 'start'; text = '' },
        @{ mode = 'ctrlesc'; text = '' },
        @{ mode = 'startbutton'; text = '' },
        @{ mode = 'click'; text = '' },
        @{ mode = 'typing'; text = 'ABC123azerty' },
        @{ mode = 'wins'; text = 'azertyAbC1234567890' },
        @{ mode = 'typing'; text = "$([char]0xe9)$([char]0xe8)$([char]0xe0)&123AZ" },
        @{ mode = 'typing'; text = '0123456789abcdefghijklmnopqrstuv' },
        @{ mode = 'wins'; text = 'AZaz1234567890' },
        @{ mode = 'typing'; text = 'ABC123azerty' },
        @{ mode = 'click'; text = '' }
    )
}
Write-Host 'Desktop input tests start in 3 seconds. Do not use the keyboard or mouse.'
Start-Sleep -Seconds 3
$results = @()
Push-Location $root
try {
    for ($pass = 1; $pass -le $Passes; $pass++) {
        foreach ($case in $cases) {
            $output = & $exe $case.mode $case.text 2>&1
            $code = $LASTEXITCODE
            $output | Write-Host
            $results += [pscustomobject]@{
                pass = $pass; mode = $case.mode; query = $case.text
                exitCode = $code; output = ($output -join "`n")
            }
        }
    }
} finally {
    $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $build 'runtime-regression-results.json') -Encoding utf8
    Pop-Location
}
$failed = @($results | Where-Object exitCode -ne 0).Count
Write-Host "SUITE total=$($results.Count) failed=$failed"
if ($failed) { exit 1 }
