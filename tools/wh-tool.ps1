<# 
Windhawk command-line toolchain for local mod development.

This script intentionally mirrors the relevant parts of Windhawk's VSCode
extension and engine behavior:
- compile with the bundled clang++ and windhawk.lib
- write compiled DLLs to ProgramData\Windhawk\Engine\Mods\<arch>
- write mod config to HKLM\SOFTWARE\Windhawk\Engine\Mods\<mod id>
- trigger reloads through the registry watcher used by the injected engine
- read Windhawk's VSCode/output logs without opening the editor UI
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'build', 'install', 'enable', 'disable', 'reload', 'restart', 'logs', 'tail')]
    [string]$Action = 'status',

    [string]$Source,
    [string]$ModId,
    [string]$WindhawkRoot = 'C:\Program Files\Windhawk',
    [switch]$EnableAfterBuild,
    [switch]$DisableAfterBuild,
    [switch]$DebugLogging,
    [switch]$NoSourceSync,
    [string]$BuildOutputPath,
    [int]$Tail = 160,
    [ValidateSet('all', 'windhawk', 'compiler', 'clangd', 'json')]
    [string]$LogKind = 'windhawk',
    [switch]$Follow,
    [switch]$NoUac,
    [string]$ElevatedArgsPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$toolScriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($PSCommandPath) {
    Split-Path -Parent $PSCommandPath
} else {
    Get-Location
}
$projectRoot = Split-Path -Parent $toolScriptRoot

if ([string]::IsNullOrWhiteSpace($Source)) {
    $Source = Join-Path $projectRoot 'src\replace-windows-search.wh.cpp'
}

if ([string]::IsNullOrWhiteSpace($BuildOutputPath)) {
    $BuildOutputPath = Join-Path $projectRoot 'build\Engine\Mods'
}

if ($ElevatedArgsPath) {
    try {
        if (-not (Test-Path -LiteralPath $ElevatedArgsPath)) {
            throw "Elevated argument file not found: $ElevatedArgsPath"
        }

        $payload = Get-Content -LiteralPath $ElevatedArgsPath -Raw | ConvertFrom-Json
    } finally {
        Remove-Item -LiteralPath $ElevatedArgsPath -Force -ErrorAction SilentlyContinue
    }

    $allowedActions = @('status', 'build', 'install', 'enable', 'disable', 'reload', 'restart', 'logs', 'tail')
    $allowedLogKinds = @('all', 'windhawk', 'compiler', 'clangd', 'json')

    if ($allowedActions -notcontains [string]$payload.Action) {
        throw "Invalid elevated action: $($payload.Action)"
    }

    if ($allowedLogKinds -notcontains [string]$payload.LogKind) {
        throw "Invalid elevated log kind: $($payload.LogKind)"
    }

    $Action = [string]$payload.Action
    $Source = if ($null -ne $payload.Source) { [string]$payload.Source } else { $null }
    $ModId = if ($null -ne $payload.ModId) { [string]$payload.ModId } else { $null }
    $WindhawkRoot = [string]$payload.WindhawkRoot
    $EnableAfterBuild = [System.Management.Automation.SwitchParameter][bool]$payload.EnableAfterBuild
    $DisableAfterBuild = [System.Management.Automation.SwitchParameter][bool]$payload.DisableAfterBuild
    $DebugLogging = [System.Management.Automation.SwitchParameter][bool]$payload.DebugLogging
    $NoSourceSync = [System.Management.Automation.SwitchParameter][bool]$payload.NoSourceSync
    $BuildOutputPath = [string]$payload.BuildOutputPath
    $Tail = [int]$payload.Tail
    $LogKind = [string]$payload.LogKind
    $Follow = [System.Management.Automation.SwitchParameter][bool]$payload.Follow
    $NoUac = [System.Management.Automation.SwitchParameter][bool]$payload.NoUac
}

function Read-IniFile {
    param([Parameter(Mandatory)][string]$Path)

    $result = @{}
    $section = ''

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) {
            continue
        }

        if ($trimmed -match '^\[(.+)\]$') {
            $section = $Matches[1]
            if (-not $result.ContainsKey($section)) {
                $result[$section] = @{}
            }
            continue
        }

        $equals = $trimmed.IndexOf('=')
        if ($equals -lt 0) {
            continue
        }

        if (-not $result.ContainsKey($section)) {
            $result[$section] = @{}
        }

        $key = $trimmed.Substring(0, $equals).Trim()
        $value = $trimmed.Substring($equals + 1).Trim()
        $result[$section][$key] = $value
    }

    return $result
}

function Resolve-WindhawkPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $Root $expanded))
}

function Get-WindhawkPaths {
    param([Parameter(Mandatory)][string]$Root)

    $iniPath = Join-Path $Root 'windhawk.ini'
    if (-not (Test-Path -LiteralPath $iniPath)) {
        throw "Windhawk config not found: $iniPath"
    }

    $ini = Read-IniFile -Path $iniPath
    if (-not $ini.ContainsKey('Storage')) {
        throw "Invalid Windhawk config, missing [Storage]: $iniPath"
    }

    $storage = $ini['Storage']
    $portable = ([int]$storage['Portable']) -ne 0
    $appDataPath = Resolve-WindhawkPath -Root $Root -Path $storage['AppDataPath']

    [pscustomobject]@{
        Root = $Root
        Portable = $portable
        CompilerPath = Resolve-WindhawkPath -Root $Root -Path $storage['CompilerPath']
        EnginePath = Resolve-WindhawkPath -Root $Root -Path $storage['EnginePath']
        AppDataPath = $appDataPath
        ModsSourcePath = Join-Path $appDataPath 'ModsSource'
        EngineModsPath = Join-Path $appDataPath 'Engine\Mods'
        RegistryKey = $storage['RegistryKey']
        WindhawkExe = Join-Path $Root 'windhawk.exe'
    }
}

function Copy-WindhawkPathsForBuildOutput {
    param(
        [Parameter(Mandatory)][object]$Paths,
        [Parameter(Mandatory)][string]$EngineModsPath
    )

    $clone = $Paths | Select-Object *
    $clone.EngineModsPath = [System.IO.Path]::GetFullPath($EngineModsPath)
    return $clone
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-StartProcessArgument {
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Argument)

    if ($Argument.Length -eq 0) {
        return '""'
    }

    return '"' + ($Argument -replace '"', '\"') + '"'
}

function New-ElevationPayloadFile {
    $payloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("windhawk-tool-elevate-{0}-{1}.json" -f $PID, [Guid]::NewGuid().ToString('N'))
    $resolvedSource = $null
    if ($Source) {
        $resolvedSource = [System.IO.Path]::GetFullPath($Source)
    }

    $payload = [ordered]@{
        Action = $Action
        Source = $resolvedSource
        ModId = $ModId
        WindhawkRoot = $WindhawkRoot
        EnableAfterBuild = [bool]$EnableAfterBuild
        DisableAfterBuild = [bool]$DisableAfterBuild
        DebugLogging = [bool]$DebugLogging
        NoSourceSync = [bool]$NoSourceSync
        BuildOutputPath = $BuildOutputPath
        Tail = $Tail
        LogKind = $LogKind
        Follow = [bool]$Follow
        NoUac = $true
    }

    $payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $payloadPath -Encoding UTF8
    return $payloadPath
}

function Invoke-SelfElevated {
    param([Parameter(Mandatory)][string]$Operation)

    if (Test-IsElevated) {
        return
    }

    if ($NoUac) {
        throw "$Operation requires an elevated PowerShell because Windhawk stores active mods in HKLM and ProgramData. Re-run without -NoUac to open a UAC prompt, or run as Administrator."
    }

    if (-not $PSCommandPath) {
        throw "$Operation requires elevation, but the script path cannot be determined for UAC relaunch."
    }

    $payloadPath = New-ElevationPayloadFile
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File {0} -ElevatedArgsPath {1}' -f `
        (ConvertTo-StartProcessArgument -Argument $PSCommandPath),
        (ConvertTo-StartProcessArgument -Argument $payloadPath)

    Write-Host "$Operation requires administrator rights; opening UAC prompt..."

    try {
        $process = Start-Process `
            -FilePath 'powershell.exe' `
            -ArgumentList $arguments `
            -Verb RunAs `
            -WorkingDirectory (Get-Location).Path `
            -Wait `
            -PassThru
    } catch {
        Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        throw "UAC elevation for $Operation was cancelled or failed: $($_.Exception.Message)"
    }

    if ($null -ne $process.ExitCode) {
        exit $process.ExitCode
    }

    exit 0
}

function Assert-ElevatedForWindhawkWrite {
    param([Parameter(Mandatory)][string]$Operation)

    Invoke-SelfElevated -Operation $Operation
}

function Split-CompilerOptions {
    param([string]$InputString)

    if ([string]::IsNullOrWhiteSpace($InputString)) {
        return @()
    }

    $result = New-Object System.Collections.Generic.List[string]
    $buffer = New-Object System.Text.StringBuilder
    $singleQuote = $false
    $doubleQuote = $false

    foreach ($ch in $InputString.ToCharArray()) {
        if ($ch -eq "'" -and -not $doubleQuote) {
            $singleQuote = -not $singleQuote
            continue
        }

        if ($ch -eq '"' -and -not $singleQuote) {
            $doubleQuote = -not $doubleQuote
            continue
        }

        if ([char]::IsWhiteSpace($ch) -and -not $singleQuote -and -not $doubleQuote) {
            if ($buffer.Length -gt 0) {
                $result.Add($buffer.ToString())
                [void]$buffer.Clear()
            }
        } else {
            [void]$buffer.Append($ch)
        }
    }

    if ($buffer.Length -gt 0) {
        $result.Add($buffer.ToString())
    }

    return @($result)
}

function Get-WindhawkModMetadata {
    param([Parameter(Mandatory)][string]$SourcePath)

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        throw "Source file not found: $SourcePath"
    }

    $sourceText = Get-Content -LiteralPath $SourcePath -Raw
    $block = [regex]::Match(
        $sourceText,
        '(?ms)^//\s*==WindhawkMod==\s*(.*?)^//\s*==/WindhawkMod=='
    )

    if (-not $block.Success) {
        throw "Missing // ==WindhawkMod== metadata block in $SourcePath"
    }

    $meta = @{
        include = New-Object System.Collections.Generic.List[string]
        exclude = New-Object System.Collections.Generic.List[string]
        architecture = New-Object System.Collections.Generic.List[string]
        compilerOptions = ''
    }

    foreach ($line in ($block.Groups[1].Value -split "`r?`n")) {
        if ($line -notmatch '^\s*//\s*@([A-Za-z0-9_-]+)\s*(.*)$') {
            continue
        }

        $key = $Matches[1]
        $value = $Matches[2].Trim()

        switch ($key) {
            'id' { $meta.id = $value }
            'name' { $meta.name = $value }
            'version' { $meta.version = $value }
            'include' { $meta.include.Add($value) }
            'exclude' { $meta.exclude.Add($value) }
            'architecture' { $meta.architecture.Add($value) }
            'compilerOptions' { $meta.compilerOptions = $value }
        }
    }

    if (-not $meta.id) {
        throw "Missing @id in $SourcePath"
    }

    if (-not $meta.version) {
        throw "Missing @version in $SourcePath"
    }

    [pscustomobject]@{
        Id = [string]$meta.id
        SourceId = [string]$meta.id
        Name = [string]$meta.name
        Version = [string]$meta.version
        Include = @($meta.include)
        Exclude = @($meta.exclude)
        Architecture = @($meta.architecture)
        CompilerOptions = [string]$meta.compilerOptions
        SourceText = $sourceText
    }
}

function Get-SourceStemModId {
    param([Parameter(Mandatory)][string]$SourcePath)

    $name = [System.IO.Path]::GetFileName($SourcePath)
    if ($name.EndsWith('.wh.cpp', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $name.Substring(0, $name.Length - '.wh.cpp'.Length)
    }

    return [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
}

function Resolve-EffectiveModId {
    param(
        [Parameter(Mandatory)][object]$Metadata,
        [Parameter(Mandatory)][string]$SourcePath
    )

    if ($ModId) {
        return $ModId
    }

    $stem = Get-SourceStemModId -SourcePath $SourcePath
    if ($stem.StartsWith('local@')) {
        return $stem
    }

    $localId = 'local@' + $Metadata.SourceId
    if (Test-Path -Path (Get-ModRegistryPath -Id $localId)) {
        return $localId
    }

    $fullSource = [System.IO.Path]::GetFullPath($SourcePath)
    $editorSource = [System.IO.Path]::GetFullPath('C:\ProgramData\Windhawk\EditorWorkspace\mod.wh.cpp')
    if ([string]::Equals($fullSource, $editorSource, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $localId
    }

    return $Metadata.SourceId
}

function Convert-SettingValue {
    param([string]$Value)

    $v = $Value.Trim()
    if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
        return $v.Substring(1, $v.Length - 2)
    }

    if ($v -match '^(true|yes)$') {
        return 1
    }

    if ($v -match '^(false|no)$') {
        return 0
    }

    $number = 0
    if ([int]::TryParse($v, [ref]$number)) {
        return $number
    }

    return $v
}

function Get-InitialSettings {
    param([Parameter(Mandatory)][string]$SourceText)

    $settings = @{}
    $block = [regex]::Match(
        $SourceText,
        '(?ms)^//\s*==WindhawkModSettings==\s*/\*\s*(.*?)\s*\*/\s*^//\s*==/WindhawkModSettings=='
    )

    if (-not $block.Success) {
        return $settings
    }

    foreach ($line in ($block.Groups[1].Value -split "`r?`n")) {
        if ($line -match '^\s*-\s*([A-Za-z0-9_.\[\]-]+)\s*:\s*(.*?)\s*$') {
            $settings[$Matches[1]] = Convert-SettingValue -Value $Matches[2]
        }
    }

    return $settings
}

function Get-CompilationTargets {
    param([string[]]$Architectures)

    if (-not $Architectures -or $Architectures.Count -eq 0) {
        $Architectures = @('x86', 'x86-64')
    }

    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($arch in $Architectures) {
        switch ($arch.ToLowerInvariant()) {
            'x86' { $targets.Add('i686-w64-mingw32') }
            'x86-64' { $targets.Add('x86_64-w64-mingw32') }
            'amd64' { $targets.Add('x86_64-w64-mingw32') }
            'arm64' { $targets.Add('aarch64-w64-mingw32') }
            default { throw "Unsupported @architecture value: $arch" }
        }
    }

    return @($targets | Select-Object -Unique)
}

function Get-TargetSubfolder {
    param([Parameter(Mandatory)][string]$Target)

    switch ($Target) {
        'i686-w64-mingw32' { return '32' }
        'x86_64-w64-mingw32' { return '64' }
        'aarch64-w64-mingw32' { return 'arm64' }
        default { throw "Unsupported target: $Target" }
    }
}

function New-TargetDllName {
    param(
        [Parameter(Mandatory)][object]$Metadata,
        [Parameter(Mandatory)][object]$Paths
    )

    while ($true) {
        $suffix = Get-Random -Minimum 100000 -Maximum 1000000
        $name = '{0}_{1}_{2}.dll' -f $Metadata.Id, $Metadata.Version, $suffix
        $exists = $false
        foreach ($subfolder in @('32', '64', 'arm64')) {
            if (Test-Path -LiteralPath (Join-Path (Join-Path $Paths.EngineModsPath $subfolder) $name)) {
                $exists = $true
                break
            }
        }

        if (-not $exists) {
            return $name
        }
    }
}

function Copy-WindhawkRuntimeLibraries {
    param(
        [Parameter(Mandatory)][object]$Paths,
        [Parameter(Mandatory)][string]$Target
    )

    $subfolder = Get-TargetSubfolder -Target $Target
    $libsDir = Join-Path (Join-Path $Paths.CompilerPath $Target) 'bin'
    $targetModsDir = Join-Path $Paths.EngineModsPath $subfolder
    New-Item -ItemType Directory -Force -Path $targetModsDir | Out-Null

    $files = @(
        @('libc++.dll', 'libc++.whl'),
        @('libunwind.dll', 'libunwind.whl'),
        @('windhawk-mod-shim.dll', 'windhawk-mod-shim.dll')
    )

    foreach ($pair in $files) {
        $from = Join-Path $libsDir $pair[0]
        $to = Join-Path $targetModsDir $pair[1]
        if (-not (Test-Path -LiteralPath $from)) {
            throw "Runtime library not found: $from"
        }

        try {
            Copy-Item -LiteralPath $from -Destination $to -Force
        } catch {
            if (Test-Path -LiteralPath $to) {
                Write-Verbose "Runtime library already exists and could not be overwritten: $to"
            } else {
                throw
            }
        }
    }
}

function Invoke-WindhawkCompile {
    param(
        [Parameter(Mandatory)][object]$Paths,
        [Parameter(Mandatory)][object]$Metadata,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$TargetDllName
    )

    $clang = Join-Path $Paths.CompilerPath 'bin\clang++.exe'
    if (-not (Test-Path -LiteralPath $clang)) {
        throw "clang++ not found: $clang"
    }

    $compilerOptions = Split-CompilerOptions -InputString $Metadata.CompilerOptions
    $targets = Get-CompilationTargets -Architectures $Metadata.Architecture
    $built = New-Object System.Collections.Generic.List[object]

    foreach ($target in $targets) {
        $subfolder = Get-TargetSubfolder -Target $target
        $engineLib = Join-Path (Join-Path $Paths.EnginePath $subfolder) 'windhawk.lib'
        if (-not (Test-Path -LiteralPath $engineLib)) {
            throw "windhawk.lib not found: $engineLib"
        }

        $outDir = Join-Path $Paths.EngineModsPath $subfolder
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        Copy-WindhawkRuntimeLibraries -Paths $Paths -Target $target

        $outDll = Join-Path $outDir $TargetDllName
        $args = @(
            '-std=c++23',
            '-O2',
            '-shared',
            '-DUNICODE',
            '-D_UNICODE',
            '-DWINVER=0x0A00',
            '-D_WIN32_WINNT=0x0A00',
            '-D_WIN32_IE=0x0A00',
            '-DNTDDI_VERSION=0x0A000008',
            '-D__USE_MINGW_ANSI_STDIO=0',
            '-DWH_MOD',
            ('-DWH_MOD_ID=L"{0}"' -f ($Metadata.Id -replace '"', '\"')),
            ('-DWH_MOD_VERSION=L"{0}"' -f ($Metadata.Version -replace '"', '\"')),
            $engineLib,
            '-x',
            'c++',
            $SourcePath,
            '-include',
            'windhawk_api.h',
            '-target',
            $target,
            '-Wl,--export-all-symbols',
            '-o',
            $outDll
        ) + $compilerOptions

        Push-Location $Paths.CompilerPath
        $responseFile = Join-Path $env:TEMP ("windhawk-clang-{0}-{1}.rsp" -f $PID, ($target -replace '[^A-Za-z0-9_.-]', '_'))
        try {
            Write-Host "Compiling $($Metadata.Id) $($Metadata.Version) for $target..."
            $responseContent = $args | ForEach-Object { ConvertTo-ClangResponseFileArg -Argument $_ }
            Set-Content -LiteralPath $responseFile -Value $responseContent -Encoding ASCII

            $oldErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $output = & $clang "@$responseFile" 2>&1
                $exitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $oldErrorActionPreference
            }
        } finally {
            Remove-Item -LiteralPath $responseFile -Force -ErrorAction SilentlyContinue
            Pop-Location
        }

        if ($output) {
            $output | ForEach-Object { Write-Host $_ }
        }

        if ($exitCode -ne 0) {
            throw "clang++ failed for $target with exit code $exitCode"
        }

        $built.Add([pscustomobject]@{
            Target = $target
            ArchitectureFolder = $subfolder
            DllPath = $outDll
        })
    }

    return $built.ToArray()
}

function ConvertTo-ClangResponseFileArg {
    param([Parameter(Mandatory)][string]$Argument)

    $escaped = $Argument -replace '\\', '\\'
    $escaped = $escaped -replace '"', '\"'
    return '"' + $escaped + '"'
}

function Get-ModRegistryPath {
    param([Parameter(Mandatory)][string]$Id)
    return "HKLM:\SOFTWARE\Windhawk\Engine\Mods\$Id"
}

function Get-ModSettingsRegistryPath {
    param([Parameter(Mandatory)][string]$Id)
    return "HKLM:\SOFTWARE\Windhawk\Engine\Mods\$Id\Settings"
}

function Get-UnixTimeSeconds32 {
    return [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -band 0x7fffffff)
}

function Set-RegString {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][string]$Value
    )

    if ($null -eq $Value) {
        $Value = ''
    }

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

function Set-RegDword {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value
    )

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Get-ModConfig {
    param([Parameter(Mandatory)][string]$Id)

    $path = Get-ModRegistryPath -Id $Id
    if (-not (Test-Path -Path $path)) {
        return $null
    }

    return Get-ItemProperty -Path $path
}

function Get-ObjectPropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Set-ModConfigFromBuild {
    param(
        [Parameter(Mandatory)][object]$Metadata,
        [Parameter(Mandatory)][string]$TargetDllName
    )

    $path = Get-ModRegistryPath -Id $Metadata.Id
    $existing = Get-ModConfig -Id $Metadata.Id

    $disabled = [int](Get-ObjectPropertyValue -Object $existing -Name 'Disabled' -DefaultValue 0)

    if ($EnableAfterBuild) {
        $disabled = 0
    }

    if ($DisableAfterBuild) {
        $disabled = 1
    }

    $logging = [int](Get-ObjectPropertyValue -Object $existing -Name 'LoggingEnabled' -DefaultValue 1)

    $debugLoggingValue = [int](Get-ObjectPropertyValue -Object $existing -Name 'DebugLoggingEnabled' -DefaultValue 0)

    if ($DebugLogging) {
        $debugLoggingValue = 1
    }

    Set-RegString -Path $path -Name 'LibraryFileName' -Value $TargetDllName
    Set-RegDword -Path $path -Name 'Disabled' -Value $disabled
    Set-RegDword -Path $path -Name 'LoggingEnabled' -Value $logging
    Set-RegDword -Path $path -Name 'DebugLoggingEnabled' -Value $debugLoggingValue
    Set-RegString -Path $path -Name 'Include' -Value (($Metadata.Include) -join '|')
    Set-RegString -Path $path -Name 'Exclude' -Value (($Metadata.Exclude) -join '|')
    Set-RegString -Path $path -Name 'IncludeCustom' -Value ''
    Set-RegString -Path $path -Name 'ExcludeCustom' -Value ''
    Set-RegDword -Path $path -Name 'IncludeExcludeCustomOnly' -Value 0
    Set-RegDword -Path $path -Name 'PatternsMatchCriticalSystemProcesses' -Value 0
    Set-RegString -Path $path -Name 'Architecture' -Value (($Metadata.Architecture) -join '|')
    Set-RegString -Path $path -Name 'Version' -Value $Metadata.Version
    Set-RegDword -Path $path -Name 'SettingsChangeTime' -Value (Get-UnixTimeSeconds32)
}

function Merge-InitialSettings {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][hashtable]$InitialSettings
    )

    if ($InitialSettings.Count -eq 0) {
        return
    }

    $path = Get-ModSettingsRegistryPath -Id $Id
    if (-not (Test-Path -Path $path)) {
        New-Item -Path $path -Force | Out-Null
    }
    $existing = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue

    foreach ($key in $InitialSettings.Keys) {
        if ($existing -and ($existing.PSObject.Properties.Name -contains $key)) {
            continue
        }

        $value = $InitialSettings[$key]
        if ($value -is [int]) {
            Set-RegDword -Path $path -Name $key -Value $value
        } else {
            Set-RegString -Path $path -Name $key -Value ([string]$value)
        }
    }
}

function Sync-ModSource {
    param(
        [Parameter(Mandatory)][object]$Paths,
        [Parameter(Mandatory)][object]$Metadata,
        [Parameter(Mandatory)][string]$SourcePath
    )

    if ($NoSourceSync) {
        return
    }

    New-Item -ItemType Directory -Force -Path $Paths.ModsSourcePath | Out-Null
    $destination = Join-Path $Paths.ModsSourcePath ($Metadata.Id + '.wh.cpp')
    Copy-Item -LiteralPath $SourcePath -Destination $destination -Force
    Write-Host "Synced source: $destination"
}

function Set-ModEnabledState {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][bool]$Enabled
    )

    $path = Get-ModRegistryPath -Id $Id
    if (-not (Test-Path -Path $path)) {
        throw "Mod config not found: $path"
    }

    Set-RegDword -Path $path -Name 'Disabled' -Value ($(if ($Enabled) { 0 } else { 1 }))
    Set-RegDword -Path $path -Name 'SettingsChangeTime' -Value (Get-UnixTimeSeconds32)
}

function Invoke-ModReload {
    param([Parameter(Mandatory)][string]$Id)

    $config = Get-ModConfig -Id $Id
    if (-not $config) {
        throw "Mod config not found for $Id"
    }

    if ([int]$config.Disabled -ne 0) {
        Write-Host "Mod $Id is disabled; use 'enable' or 'install -EnableAfterBuild' to load it."
        return
    }

    Write-Host "Temporarily disabling $Id..."
    Set-ModEnabledState -Id $Id -Enabled:$false
    Start-Sleep -Milliseconds 800
    Write-Host "Re-enabling $Id..."
    Set-ModEnabledState -Id $Id -Enabled:$true
}

function Restart-Windhawk {
    param([Parameter(Mandatory)][object]$Paths)

    if (-not (Test-Path -LiteralPath $Paths.WindhawkExe)) {
        throw "windhawk.exe not found: $($Paths.WindhawkExe)"
    }

    & $Paths.WindhawkExe -restart -tray-only
}

function Get-ResolvedModId {
    param([object]$Metadata)

    if ($ModId) {
        return $ModId
    }

    if ($Metadata) {
        return $Metadata.Id
    }

    throw "Pass -ModId or use -Source with a valid Windhawk metadata block."
}

function Get-LatestWindhawkLogFiles {
    param(
        [Parameter(Mandatory)][object]$Paths,
        [Parameter(Mandatory)][string]$Kind
    )

    $root = Join-Path $Paths.AppDataPath 'UIData\user-data\logs'
    if (-not (Test-Path -LiteralPath $root)) {
        throw "Windhawk log root not found: $root"
    }

    $files = Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.log' |
        Sort-Object LastWriteTime -Descending

    switch ($Kind) {
        'windhawk' { $files = $files | Where-Object { ($_.Name -like '*Windhawk Log.log') -or (($_.Name -like '*Windhawk*.log') -and ($_.Name -notlike '*Compiler*')) } }
        'compiler' { $files = $files | Where-Object { $_.Name -like '*Compiler*' } }
        'clangd' { $files = $files | Where-Object { $_.Name -like '*clangd*' } }
        'json' { $files = $files | Where-Object { $_.Name -like '*JSON*' } }
    }

    return @($files | Select-Object -First 5)
}

function Show-Logs {
    param(
        [Parameter(Mandatory)][object]$Paths,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][int]$TailCount,
        [Parameter(Mandatory)][bool]$Wait
    )

    $files = Get-LatestWindhawkLogFiles -Paths $Paths -Kind $Kind
    if ($files.Count -eq 0) {
        Write-Host "No log files found for kind '$Kind'."
        return
    }

    $file = $files[0]
    Write-Host "Log: $($file.FullName)"
    if ($Wait) {
        Get-Content -LiteralPath $file.FullName -Tail $TailCount -Wait
    } else {
        Get-Content -LiteralPath $file.FullName -Tail $TailCount
    }
}

function Show-Status {
    param(
        [Parameter(Mandatory)][object]$Paths,
        [object]$Metadata
    )

    $id = $null
    if ($ModId) {
        $id = $ModId
    } elseif ($Metadata) {
        $id = $Metadata.Id
    }

    Write-Host "Windhawk root: $($Paths.Root)"
    Write-Host "AppData:       $($Paths.AppDataPath)"
    Write-Host "Compiler:      $($Paths.CompilerPath)"
    Write-Host "Engine:        $($Paths.EnginePath)"

    if ($Metadata) {
        Write-Host "Source:        $Source"
        Write-Host "Source mod:    $($Metadata.SourceId) $($Metadata.Version)"
        if ($Metadata.Id -ne $Metadata.SourceId) {
            Write-Host "Effective id:  $($Metadata.Id)"
        }
    }

    if ($id) {
        $config = Get-ModConfig -Id $id
        if ($config) {
            Write-Host "Registry mod:  $id"
            Write-Host "Library:       $(Get-ObjectPropertyValue -Object $config -Name 'LibraryFileName' -DefaultValue '<missing>')"
            Write-Host "Disabled:      $(Get-ObjectPropertyValue -Object $config -Name 'Disabled' -DefaultValue '<missing>')"
            Write-Host "Logging:       $(Get-ObjectPropertyValue -Object $config -Name 'LoggingEnabled' -DefaultValue '<missing>')"
            Write-Host "DebugLogging:  $(Get-ObjectPropertyValue -Object $config -Name 'DebugLoggingEnabled' -DefaultValue '<missing>')"
            Write-Host "Include:       $(Get-ObjectPropertyValue -Object $config -Name 'Include' -DefaultValue '<missing>')"
            Write-Host "Architecture:  $(Get-ObjectPropertyValue -Object $config -Name 'Architecture' -DefaultValue '<missing>')"
            Write-Host "Version:       $(Get-ObjectPropertyValue -Object $config -Name 'Version' -DefaultValue '<missing>')"
        } else {
            Write-Host "Registry mod:  $id is not installed"
        }
    }

    $windhawkProcesses = Get-Process -Name windhawk -ErrorAction SilentlyContinue
    if ($windhawkProcesses) {
        Write-Host "windhawk.exe:  running (pid: $((@($windhawkProcesses.Id)) -join ', '))"
    } else {
        Write-Host "windhawk.exe:  not running"
    }
}

$paths = Get-WindhawkPaths -Root $WindhawkRoot
$metadata = $null
if (Test-Path -LiteralPath $Source) {
    $metadata = Get-WindhawkModMetadata -SourcePath $Source
    $metadata.Id = Resolve-EffectiveModId -Metadata $metadata -SourcePath $Source
}

switch ($Action) {
    'status' {
        Show-Status -Paths $paths -Metadata $metadata
    }

    'build' {
        if (-not $metadata) {
            throw "Cannot build without a valid -Source."
        }

        $buildPaths = Copy-WindhawkPathsForBuildOutput -Paths $paths -EngineModsPath $BuildOutputPath
        $dllName = New-TargetDllName -Metadata $metadata -Paths $buildPaths
        $built = Invoke-WindhawkCompile -Paths $buildPaths -Metadata $metadata -SourcePath ([System.IO.Path]::GetFullPath($Source)) -TargetDllName $dllName
        $built | Format-Table Target, ArchitectureFolder, DllPath -AutoSize
    }

    'install' {
        if (-not $metadata) {
            throw "Cannot install without a valid -Source."
        }

        Assert-ElevatedForWindhawkWrite -Operation 'install'
        $dllName = New-TargetDllName -Metadata $metadata -Paths $paths
        $built = Invoke-WindhawkCompile -Paths $paths -Metadata $metadata -SourcePath ([System.IO.Path]::GetFullPath($Source)) -TargetDllName $dllName
        Sync-ModSource -Paths $paths -Metadata $metadata -SourcePath ([System.IO.Path]::GetFullPath($Source))
        Set-ModConfigFromBuild -Metadata $metadata -TargetDllName $dllName
        Merge-InitialSettings -Id $metadata.Id -InitialSettings (Get-InitialSettings -SourceText $metadata.SourceText)
        $built | Format-Table Target, ArchitectureFolder, DllPath -AutoSize
        Show-Status -Paths $paths -Metadata $metadata
    }

    'enable' {
        Assert-ElevatedForWindhawkWrite -Operation 'enable'
        Set-ModEnabledState -Id (Get-ResolvedModId -Metadata $metadata) -Enabled:$true
        Show-Status -Paths $paths -Metadata $metadata
    }

    'disable' {
        Assert-ElevatedForWindhawkWrite -Operation 'disable'
        Set-ModEnabledState -Id (Get-ResolvedModId -Metadata $metadata) -Enabled:$false
        Show-Status -Paths $paths -Metadata $metadata
    }

    'reload' {
        Assert-ElevatedForWindhawkWrite -Operation 'reload'
        Invoke-ModReload -Id (Get-ResolvedModId -Metadata $metadata)
    }

    'restart' {
        Restart-Windhawk -Paths $paths
    }

    'logs' {
        Show-Logs -Paths $paths -Kind $LogKind -TailCount $Tail -Wait:$false
    }

    'tail' {
        Show-Logs -Paths $paths -Kind $LogKind -TailCount $Tail -Wait:$true
    }
}
