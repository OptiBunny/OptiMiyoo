#requires -Version 5.1
param([string]$Root,[ValidateSet('Ask','LooseDSK','ZipDSK')][string]$Format='Ask',
      [ValidateSet('Ask','Overwrite','Skip')][string]$Existing='Ask',
      [ValidateSet('Keep','Remove')][string]$SourcePolicy='Keep',
      [switch]$NoAnimation,[switch]$NoColor,
      [ValidateSet('CRT','Smooth')][string]$DisplayEffect='CRT')
# Based on ZX converter v2.3; OptiMiyoo v1.0 integration keeps its conversion engine.
# ZX IPF / ZIP -> DSK Converter v2.3 - console edition
# Windows PowerShell 5.1 compatible. No GUI. Keep originals is the default.

$ErrorActionPreference = 'Stop'

$script:Version = '2.3'
$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) {$Root=Split-Path -Parent (Split-Path -Parent $script:AppRoot)}
$Root=(Resolve-Path -LiteralPath $Root).ProviderPath
$script:SourceRoot = Join-Path $Root 'SRC'
$script:DestinationRoot = Join-Path $Root 'DST'
$script:ToolsRoot = Join-Path $script:AppRoot 'tools\hxc'
$script:HxCX64 = Join-Path $script:ToolsRoot 'x64\hxcfe.exe'
$script:HxCX86 = Join-Path $script:ToolsRoot 'x86\hxcfe.exe'
$script:HxCExe = $null
$script:HxCFallback = $null
$script:EngineRuntimeDirs = @{}
$script:RuntimeHintPath = Join-Path $script:AppRoot 'runtime-path.txt'
$script:OverwriteMode = 'Ask'   # Ask | OverwriteAll | SkipAll
$script:OutputMode = 'LooseDSK' # LooseDSK | ZipDSK
$script:Converted = 0
$script:Skipped = 0
$script:Failed = 0
$script:Total = 0
$script:ScanFailures = @()
$script:LogPath = $null
$script:LogDisabled=$false
$script:ReportProblem=$false
$script:AppVersion='1.0.0'
$script:Processed=0; $script:Ok=0
$script:Clock=[Diagnostics.Stopwatch]::StartNew()
. (Join-Path (Split-Path -Parent $script:AppRoot) 'display.ps1')
. (Join-Path (Split-Path -Parent $script:AppRoot) 'source_policy.ps1')
. (Join-Path (Split-Path -Parent $script:AppRoot) 'overwrite_prompt.ps1')
$script:ChooseSourcePolicy=($Format -eq 'Ask' -and -not $PSBoundParameters.ContainsKey('SourcePolicy'))
$script:SourcePlan=New-SourcePolicyPlan $script:SourceRoot $SourcePolicy
Initialize-Display
$script:UiSystem='ZXS / IPF -> DSK'
if ($Existing -eq 'Overwrite') {$script:OverwriteMode='OverwriteAll'}
elseif ($Existing -eq 'Skip') {$script:OverwriteMode='SkipAll'}
function Write-Log([string]$Message) {Write-LogFile $Message}
function Format-Duration([double]$Seconds) {
    $t=[TimeSpan]::FromSeconds([Math]::Max(0,$Seconds))
    return ('{0:00}:{1:00}:{2:00}' -f [Math]::Floor($t.TotalHours),$t.Minutes,$t.Seconds)
}


function Assert-PlainOutputParents([string]$Path, [string]$Root) {
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    while ($parent -and $parent.Length -ge $rootFull.Length) {
        if (Test-Path -LiteralPath $parent) {
            $item = Get-Item -LiteralPath $parent -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Output parent is a link or not a directory: $parent"
            }
        }
        if ($parent.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
}


Assert-PlainOutputParents (Join-Path $script:SourceRoot 'placeholder') $Root
Assert-PlainOutputParents (Join-Path $script:DestinationRoot 'placeholder') $Root
New-Item -ItemType Directory -Path $script:SourceRoot -Force | Out-Null
New-Item -ItemType Directory -Path $script:DestinationRoot -Force | Out-Null

function Write-Banner {
    Write-Event 'MODE' 'OptiMiyoo / ZX IPF-to-DSK / engine workflow v2.3'
    Write-Event 'SOURCE' $script:SourceRoot
    Write-Event 'OUTPUT' $script:DestinationRoot
    Write-Event 'ORIGINALS' 'Keep is the default. Remove requires every output from a source to verify successfully.'
}

function Start-Log {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $script:LogPath = Join-Path $script:DestinationRoot ("ZX_IPF_conversion_{0}.log" -f $stamp)
    $utf8Bom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true
    [IO.File]::WriteAllText($script:LogPath, '', $utf8Bom)
    Write-LogFile ('ZX IPF -> DSK Converter v' + $script:Version)
    Write-LogFile ('Date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-LogFile ('Source: ' + $script:SourceRoot)
    Write-LogFile ('Destination: ' + $script:DestinationRoot)
    Write-LogFile ('Output mode: ' + $script:OutputMode)
    Write-LogFile ('Source policy: ' + $SourcePolicy)
    Write-LogFile ''
}

function Write-LogFile([string]$Text) {
    if (-not $script:LogPath -or $script:LogDisabled) {return}
    try {
        [IO.File]::AppendAllText($script:LogPath,$Text+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))
    } catch {
        $script:LogDisabled=$true
        $script:ReportProblem=$true
        Write-Notice 'WARNING' 'Could not write the log. Conversion will continue; review the on-screen results.'
    }
}

function Write-Status([string]$Kind,[string]$Text) {
    $label=$Kind
    switch ($Kind) {'OK' {$label='READY'} 'FAIL' {$label='FAILED'} 'WARN' {$label='NOTE'}}
    $script:Ok=$script:Converted
    $script:Processed=$script:Converted+$script:Skipped+$script:Failed
    Write-Event $label $Text
}

function Write-Diagnostic([string]$Text) {
    Write-LogFile ('[' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $Text)
}

function Get-EngineLabel([string]$Path) {
    if ($Path -match '[\\/]x64[\\/]') { return 'HxC x64' }
    if ($Path -match '[\\/]x86[\\/]') { return 'HxC x86' }
    return ('HxC ' + (Split-Path -Leaf $Path))
}

function Test-BundledEngine([string]$EnginePath) {
    if (-not (Test-Path -LiteralPath $EnginePath -PathType Leaf)) { return $false }
    $dir = Split-Path -Parent $EnginePath
    foreach ($name in @('libhxcfe.dll','config.script','CAPSImg.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir $name) -PathType Leaf)) { return $false }
    }
    return $true
}

function Invoke-EngineText([string]$EnginePath, [string]$Arguments, [int]$TimeoutMs) {
    $psi = New-Object -TypeName System.Diagnostics.ProcessStartInfo
    $psi.FileName = $EnginePath
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = Split-Path -Parent $EnginePath
    # HxC's file APIs use narrow strings on Windows. Staged media have ASCII
    # names; use those names relative to a Unicode-capable process working
    # directory, so neither user filenames nor a Unicode TEMP path reach fopen.
    $inputArgument=[regex]::Match($Arguments,'(?i)(?:^|\s)-finput:"([^"]+)"')
    if ($inputArgument.Success) {
        $inputPath=$inputArgument.Groups[1].Value
        $workDirectory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($inputPath))
        $psi.WorkingDirectory=$workDirectory
        $psi.Arguments=$psi.Arguments.Replace(('-finput:"'+$inputPath+'"'),('-finput:"'+[IO.Path]::GetFileName($inputPath)+'"'))
        $outputArgument=[regex]::Match($Arguments,'(?i)(?:^|\s)-foutput:"([^"]+)"')
        if ($outputArgument.Success) {
            $outputPath=$outputArgument.Groups[1].Value
            $outputDirectory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($outputPath))
            if (-not $outputDirectory.Equals($workDirectory,[StringComparison]::OrdinalIgnoreCase)) {
                throw 'Native HxC input and output must share the isolated staging directory.'
            }
            $psi.Arguments=$psi.Arguments.Replace(('-foutput:"'+$outputPath+'"'),('-foutput:"'+[IO.Path]::GetFileName($outputPath)+'"'))
        }
        # Preserve the bundled engine's configuration when changing its cwd.
        $config=Join-Path (Split-Path -Parent $EnginePath) 'config.script'
        if (Test-Path -LiteralPath $config -PathType Leaf) {
            [IO.File]::Copy($config,(Join-Path $workDirectory 'config.script'),$true)
        }
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    # The x86 CAPSImg fallback depends on the bundled MinGW runtime DLLs.
    # If a runtime directory was resolved for this engine, prepend it only for
    # the child HxC process; the user's global PATH is not modified.
    if ($script:EngineRuntimeDirs.ContainsKey($EnginePath)) {
        $runtimeDir = [string]$script:EngineRuntimeDirs[$EnginePath]
        if (-not [string]::IsNullOrWhiteSpace($runtimeDir)) {
            $basePath = [string]$env:Path
            if ([string]::IsNullOrWhiteSpace($basePath)) { $basePath = '' }
            $psi.EnvironmentVariables['PATH'] = $runtimeDir + ';' + $basePath
        }
    }

    $process = New-Object -TypeName System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timer=[Diagnostics.Stopwatch]::StartNew()
        do {
            $finished=$process.WaitForExit(125)
            $detail=Get-EngineLabel $EnginePath
            if ($script:CurrentZXItem) {$detail=$script:CurrentZXItem}
            Show-Stage 0 'Running HxC / waiting for engine output' $detail
        } while (-not $finished -and $timer.ElapsedMilliseconds -lt $TimeoutMs)
        if (-not $finished) {
            try { $process.Kill() } catch {}
            try { [void]$process.WaitForExit(5000) } catch {}
        } else {
            try { $process.WaitForExit() } catch {}
        }

        $stdout = ''
        $stderr = ''
        try {
            if ($stdoutTask.Wait(5000)) { $stdout = [string]$stdoutTask.Result }
            else { $stdout = '(stdout capture timed out after process termination)' }
        } catch { $stdout = '(stdout capture failed: ' + $_.Exception.Message + ')' }
        try {
            if ($stderrTask.Wait(5000)) { $stderr = [string]$stderrTask.Result }
            else { $stderr = '(stderr capture timed out after process termination)' }
        } catch { $stderr = '(stderr capture failed: ' + $_.Exception.Message + ')' }

        $exitCode = if ($finished) { $process.ExitCode } else { -999 }
        return [PSCustomObject]@{
            ExitCode = $exitCode
            Output = (($stdout + "`r`n" + $stderr).Trim())
            TimedOut = (-not $finished)
        }
    } finally {
        # Dispose releases handles; explicitly stop a running engine on any
        # exit path, including an interrupted run or a display/log exception.
        try {
            if (-not $process.HasExited) {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            }
        } catch {}
        try { $process.Dispose() } catch {}
    }
}

function Test-HxCEngine([string]$EnginePath) {
    $label = Get-EngineLabel $EnginePath
    try {
        $check = Invoke-EngineText $EnginePath '-modulelist' 20000
        Write-Diagnostic ('===== ENGINE CHECK: ' + $label + ' =====')
        Write-Diagnostic ('Path: ' + $EnginePath)
        Write-Diagnostic ('Exit code: ' + $check.ExitCode)
        Write-Diagnostic ('Timed out: ' + $check.TimedOut)
        Write-Diagnostic $check.Output
        Write-Diagnostic '===== END ENGINE CHECK ====='
        if ($check.TimedOut) { throw ($label + ' timed out while listing modules.') }
        if ($check.Output -notmatch 'SPS_IPF') { throw ($label + ' does not report the SPS_IPF loader.') }
        if ($check.Output -notmatch 'AMSTRADCPC_DSK') { throw ($label + ' does not report the AMSTRADCPC_DSK writer.') }
        return $true
    } catch {
        Write-Status 'WARN' ($label + ' unavailable: ' + $_.Exception.Message)
        Write-Diagnostic ('ENGINE ERROR: ' + ($_ | Out-String))
        return $false
    }
}

function Get-EngineArchitecture([string]$EnginePath) {
    if ($EnginePath -match '[\\/]x64[\\/]') { return 'x64' }
    if ($EnginePath -match '[\\/]x86[\\/]') { return 'x86' }
    return ''
}

function Get-PeMachine([string]$FilePath) {
    $stream = $null
    try {
        $stream = [IO.File]::Open($FilePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        if ($stream.Length -lt 64) { return 0 }
        $buf4 = New-Object byte[] 4
        [void]$stream.Seek(60, [IO.SeekOrigin]::Begin)
        if ($stream.Read($buf4, 0, 4) -ne 4) { return 0 }
        $peOffset = [BitConverter]::ToInt32($buf4, 0)
        if ($peOffset -lt 0 -or ($peOffset + 6) -gt $stream.Length) { return 0 }
        [void]$stream.Seek([int64]($peOffset + 4), [IO.SeekOrigin]::Begin)
        $buf2 = New-Object byte[] 2
        if ($stream.Read($buf2, 0, 2) -ne 2) { return 0 }
        return [int][BitConverter]::ToUInt16($buf2, 0)
    } catch {
        return 0
    } finally {
        if ($stream) { try { $stream.Dispose() } catch {} }
    }
}

function Test-PeArchitecture([string]$FilePath, [string]$Architecture) {
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return $false }
    $machine = Get-PeMachine $FilePath
    if ($Architecture -eq 'x64') { return ($machine -eq 0x8664) }
    if ($Architecture -eq 'x86') { return ($machine -eq 0x014c) }
    return $false
}

function Get-CapsRuntimeRequirements([string]$EnginePath) {
    $arch = Get-EngineArchitecture $EnginePath
    if ($arch -eq 'x64') { return @('libstdc++-6.dll') }
    if ($arch -eq 'x86') { return @('libstdc++-6.dll', 'libgcc_s_dw2-1.dll') }
    return @()
}

function Test-CapsRuntimeDirectory([string]$EnginePath, [string]$Directory) {
    if ([string]::IsNullOrWhiteSpace($Directory)) { return $false }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return $false }
    $arch = Get-EngineArchitecture $EnginePath
    foreach ($name in @(Get-CapsRuntimeRequirements $EnginePath)) {
        $candidate = Join-Path $Directory $name
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $false }
        if (-not (Test-PeArchitecture $candidate $arch)) { return $false }
    }
    return $true
}

function Add-RuntimeCandidate([System.Collections.ArrayList]$List, [hashtable]$Seen, [string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $candidate = $Path.Trim().Trim([char]34)
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidate = Split-Path -Parent $candidate }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { return }
    try { $candidate = [IO.Path]::GetFullPath($candidate) } catch { return }
    $key = $candidate.ToLowerInvariant()
    if (-not $Seen.ContainsKey($key)) {
        $Seen[$key] = $true
        [void]$List.Add($candidate)
    }
}

function Get-CapsRuntimeCandidateDirectories([string]$EnginePath) {
    $list = New-Object System.Collections.ArrayList
    $seen = @{}

    Add-RuntimeCandidate $list $seen (Split-Path -Parent $EnginePath)
    $arch = Get-EngineArchitecture $EnginePath
    if (-not [string]::IsNullOrWhiteSpace($arch)) {
        Add-RuntimeCandidate $list $seen (Join-Path $script:AppRoot ('resources\caps-runtime\' + $arch))
    }

    if (Test-Path -LiteralPath $script:RuntimeHintPath -PathType Leaf) {
        try {
            $hint = ([IO.File]::ReadAllText($script:RuntimeHintPath)).Trim()
            Add-RuntimeCandidate $list $seen $hint
        } catch {}
    }

    foreach ($part in @(([string]$env:Path) -split ';')) {
        Add-RuntimeCandidate $list $seen $part
    }

    $common = @()
    if ($env:ProgramFiles) {
        $common += (Join-Path $env:ProgramFiles 'RetroArch')
        $common += (Join-Path $env:ProgramFiles 'RetroArch-Win64')
    }
    if (${env:ProgramFiles(x86)}) {
        $common += (Join-Path ${env:ProgramFiles(x86)} 'RetroArch')
        $common += (Join-Path ${env:ProgramFiles(x86)} 'RetroArch-Win32')
    }
    if ($env:LOCALAPPDATA) {
        $common += (Join-Path $env:LOCALAPPDATA 'RetroArch')
        $common += (Join-Path $env:LOCALAPPDATA 'Programs\RetroArch')
    }
    if ($env:USERPROFILE) {
        $common += (Join-Path $env:USERPROFILE 'RetroArch')
        $common += (Join-Path $env:USERPROFILE 'RetroArch-Win64')
        $common += (Join-Path $env:USERPROFILE 'Desktop\RetroArch')
    }
    $common += 'C:\RetroArch'
    $common += 'C:\RetroArch-Win64'
    foreach ($candidate in $common) { Add-RuntimeCandidate $list $seen $candidate }

    foreach ($registryPath in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        try {
            foreach ($app in @(Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '(?i)RetroArch' })) {
                if ($app.InstallLocation) { Add-RuntimeCandidate $list $seen ([string]$app.InstallLocation) }
                if ($app.DisplayIcon) {
                    $icon = ([string]$app.DisplayIcon).Trim().Trim([char]34)
                    $icon = $icon -replace ',\d+$', ''
                    Add-RuntimeCandidate $list $seen $icon
                }
            }
        } catch {}
    }

    return $list.ToArray()
}

function Find-CapsRuntimeDirectory([string]$EnginePath) {
    foreach ($candidate in @(Get-CapsRuntimeCandidateDirectories $EnginePath)) {
        if (Test-CapsRuntimeDirectory $EnginePath $candidate) { return $candidate }
    }
    return $null
}

function Set-CapsRuntimeDirectory([string]$EnginePath, [string]$Directory) {
    if ([string]::IsNullOrWhiteSpace($Directory)) { return }
    $script:EngineRuntimeDirs[$EnginePath] = $Directory
    Write-Diagnostic ((Get-EngineLabel $EnginePath) + ' runtime PATH prefix: ' + $Directory)
}

function Test-CapsIPFEngine([string]$EnginePath, [string]$InputPath) {
    $label = Get-EngineLabel $EnginePath
    $arguments = ('-verbose -finput:"{0}" -infos' -f $InputPath)
    $run = Invoke-EngineText $EnginePath $arguments 30000
    $output = [string]$run.Output
    $capsLoadFailure = ($output -match "(?i)Can't load CAPSImg\.dll|Failed to load CAPS library|No Caps lib available")
    $ipfDetected = ($output -match '(?i)IPF_libIsValidDiskFile\s*:\s*IPF file')
    $sourceLoadFailure = ($output -match "(?i)No loader support the file|Can't open/load source image")

    Write-Diagnostic ('===== CAPS/IPF PREFLIGHT: ' + $label + ' =====')
    Write-Diagnostic ('Input: ' + $InputPath)
    Write-Diagnostic ('Runtime prefix: ' + $(if ($script:EngineRuntimeDirs.ContainsKey($EnginePath)) { [string]$script:EngineRuntimeDirs[$EnginePath] } else { '(none)' }))
    Write-Diagnostic ('Exit code: ' + $run.ExitCode)
    Write-Diagnostic ('Timed out: ' + $run.TimedOut)
    Write-Diagnostic ('IPF detected: ' + $ipfDetected)
    Write-Diagnostic ('CAPS load failure: ' + $capsLoadFailure)
    Write-Diagnostic ('Source load failure: ' + $sourceLoadFailure)
    Write-Diagnostic $output
    Write-Diagnostic '===== END CAPS/IPF PREFLIGHT ====='

    if ($run.TimedOut) {
        return [PSCustomObject]@{ Success=$false; CapsLoadFailure=$false; Detail=($label + ' timed out during IPF preflight.') }
    }
    if ($capsLoadFailure) {
        return [PSCustomObject]@{ Success=$false; CapsLoadFailure=$true; Detail=($label + ' cannot load CAPSImg.dll or one of its runtime dependencies.') }
    }
    if ($ipfDetected -and -not $sourceLoadFailure) {
        return [PSCustomObject]@{ Success=$true; CapsLoadFailure=$false; Detail='' }
    }
    if ($sourceLoadFailure) {
        return [PSCustomObject]@{ Success=$false; CapsLoadFailure=$false; Detail=($label + ' recognized IPF but could not load the probe image.') }
    }
    return [PSCustomObject]@{ Success=$false; CapsLoadFailure=$false; Detail=($label + ' did not recognize the probe file as an IPF image.') }
}

function Prompt-CapsRuntimeDirectory {
    $answer=Read-DisplayInput 'MinGW runtime folder' 'ZX Spectrum / runtime setup' @(
        'The 32-bit CAPSImg fallback needs libstdc++-6.dll,',
        'libgcc_s_dw2-1.dll and libwinpthread-1.dll.',
        'These files are included in the complete OptiMiyoo download.',
        'To use another compatible set, drag its folder into this window.',
        'A 32-bit RetroArch installation may also contain these libraries.',
        'Enter without a path, B or Q stops safely.') 'wait'
    if ($null -eq $answer) { return $null }
    $answer = $answer.Trim().Trim([char]34)
    if ([string]::IsNullOrWhiteSpace($answer) -or $answer -in 'B','Q') { return $null }
    if (Test-Path -LiteralPath $answer -PathType Leaf) { $answer = Split-Path -Parent $answer }
    if (-not (Test-Path -LiteralPath $answer -PathType Container)) {
        Write-Status 'WARN' 'That folder does not exist.'
        return $null
    }
    try {
        [IO.File]::WriteAllText($script:RuntimeHintPath, [IO.Path]::GetFullPath($answer), (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
    } catch {}
    return $answer
}

function Ensure-CapsIPFReady($ProbeItem) {
    $script:CapsPreflightGlobalFailure=$false
    $probePath = [string]$ProbeItem.InputPath
    $probeTempRoot = $null
    try {
        Write-Status 'INFO' ('CAPS preflight using staged copy: ' + $ProbeItem.DisplayName)
        if ($ProbeItem.Type -eq 'Zip') {
            $expanded = Expand-OneZipIPF $ProbeItem.InputPath $ProbeItem.EntryName
        } else {
            $expanded = Stage-LooseIPF $ProbeItem.InputPath
        }
        $probePath = $expanded.Path
        $probeTempRoot = $expanded.TempRoot

        $engines = @($script:HxCExe)
        if ($script:HxCFallback) { $engines += $script:HxCFallback }

        foreach ($engine in $engines) {
            $runtimeDir = Find-CapsRuntimeDirectory $engine
            if ($runtimeDir) {
                Set-CapsRuntimeDirectory $engine $runtimeDir
                Write-Status 'ENGINE' ((Get-EngineLabel $engine) + ' found compatible CAPS runtime in: ' + $runtimeDir)
            }
        }

        $working = @()
        $capsRuntimeProblem = $false
        foreach ($engine in $engines) {
            try {$probe = Test-CapsIPFEngine $engine $probePath}
            catch {$probe=[pscustomobject]@{Success=$false;CapsLoadFailure=$false;Detail=((Get-EngineLabel $engine)+' probe failed: '+$_.Exception.Message)}}
            if ($probe.Success) { $working += $engine }
            elseif ($probe.CapsLoadFailure) { $capsRuntimeProblem = $true }
            else { Write-Status 'WARN' $probe.Detail }
        }

        if ($working.Count -eq 0 -and $capsRuntimeProblem) {
            Write-Status 'WARN' 'CAPSImg was found, but Windows could not load its MinGW runtime dependency.'
            $manualDir = Prompt-CapsRuntimeDirectory
            if ($manualDir) {
                foreach ($engine in $engines) {
                    if (Test-CapsRuntimeDirectory $engine $manualDir) {
                        Set-CapsRuntimeDirectory $engine $manualDir
                    }
                }
                $working = @()
                foreach ($engine in $engines) {
                    try {$probe = Test-CapsIPFEngine $engine $probePath}
                    catch {$probe=[pscustomobject]@{Success=$false;CapsLoadFailure=$false;Detail=((Get-EngineLabel $engine)+' probe failed: '+$_.Exception.Message)}}
                    if ($probe.Success) { $working += $engine }
                    else { Write-Status 'WARN' $probe.Detail }
                }
            }
        }

        if ($working.Count -eq 0) {
            $script:CapsPreflightGlobalFailure=$capsRuntimeProblem
            Write-Status 'WARN' 'This source did not pass CAPS/IPF preflight.'
            return $false
        }

        $script:HxCExe = $working[0]
        $script:HxCFallback = $null
        if ($working.Count -gt 1) { $script:HxCFallback = $working[1] }
        if ($script:HxCFallback) {
            Write-Status 'ENGINE' ((Get-EngineLabel $script:HxCExe) + ' passed CAPS/IPF preflight; ' + (Get-EngineLabel $script:HxCFallback) + ' also passed.')
        } else {
            Write-Status 'ENGINE' ((Get-EngineLabel $script:HxCExe) + ' passed CAPS/IPF preflight.')
        }
        return $true
    } finally {
        if ($probeTempRoot -and (Test-Path -LiteralPath $probeTempRoot)) {
            Remove-Item -LiteralPath $probeTempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Ensure-HxC {
    $script:HxCExe = $null
    $script:HxCFallback = $null
    $candidates = @()
    if ([Environment]::Is64BitOperatingSystem) {
        $candidates += $script:HxCX64
        $candidates += $script:HxCX86
    } else {
        $candidates += $script:HxCX86
    }

    $valid = @()
    foreach ($candidate in $candidates) {
        if (-not (Test-BundledEngine $candidate)) {
            Write-Status 'WARN' ('Bundled engine files are missing for ' + $candidate)
            continue
        }
        if (Test-HxCEngine $candidate) { $valid += $candidate }
    }

    if ($valid.Count -eq 0) {
        Write-Status 'FAIL' 'Neither bundled HxC engine passed the module check.'
        return $false
    }
    $script:HxCExe = $valid[0]
    if ($valid.Count -gt 1) { $script:HxCFallback = $valid[1] }

    if ($script:HxCFallback) {
        Write-Status 'ENGINE' ((Get-EngineLabel $script:HxCExe) + ' ready; ' + (Get-EngineLabel $script:HxCFallback) + ' available as fallback.')
    } else {
        Write-Status 'ENGINE' ((Get-EngineLabel $script:HxCExe) + ' ready.')
    }
    return $true
}

function Get-RelativePathCompat([string]$BaseDirectory,[string]$TargetPath) {
    $prefix=[IO.Path]::GetFullPath($BaseDirectory).TrimEnd([char]92,[char]47)+[IO.Path]::DirectorySeparatorChar
    $full=[IO.Path]::GetFullPath($TargetPath)
    if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'Source is outside SRC.'}
    return $full.Substring($prefix.Length).Replace([char]92,[char]47)
}

function Join-RelativePath([string]$Left, [string]$Right) {
    if ([string]::IsNullOrWhiteSpace($Left)) { return $Right }
    if ([string]::IsNullOrWhiteSpace($Right)) { return $Left }
    return (($Left -replace '[\\/]+$', '') + '/' + ($Right -replace '^[\\/]+', ''))
}

function Get-SafeZipRelativePath([string]$EntryName) {
    $normalized = $EntryName.Replace('\', '/')
    $parts = @()
    $invalidChars = [IO.Path]::GetInvalidFileNameChars()
    foreach ($part in ($normalized -split '/')) {
        if ([string]::IsNullOrWhiteSpace($part) -or $part -eq '.' -or $part -eq '..') { continue }
        $clean = $part
        foreach ($bad in $invalidChars) { $clean = $clean.Replace([string]$bad, '_') }
        $clean = ($clean -replace '[. ]+$', '')
        if ([string]::IsNullOrWhiteSpace($clean)) { $clean = '_' }
        $stem = [IO.Path]::GetFileNameWithoutExtension($clean)
        if ($stem -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { $clean = '_' + $clean }
        $parts += $clean
    }
    if ($parts.Count -eq 0) { return 'disk.ipf' }
    return [string]::Join('/', $parts)
}

function Get-ZipIPFEntryNames([string]$ZipPath) {
    $zip = $null
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
        $entries = @($zip.Entries |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) -and ([IO.Path]::GetExtension($_.FullName) -ieq '.ipf') } |
            ForEach-Object { $_.FullName })
        $extraCount=@($zip.Entries | Where-Object {-not [string]::IsNullOrWhiteSpace($_.Name) -and ([IO.Path]::GetExtension($_.FullName) -ine '.ipf')}).Count
        $hash=$null
        if ($SourcePolicy -eq 'Remove') {
            $onHash={param($done,$total) Show-PreparationProgress 'Reading source ZIP' ([IO.Path]::GetFileName($ZipPath)) $done $total 'bytes'}.GetNewClosure()
            $hash=Get-SourcePolicyHash $ZipPath $onHash
        }
        return [PSCustomObject]@{ Success=$true; Entries=$entries; OtherFiles=$extraCount; Hash=$hash; Error='' }
    } catch {
        return [PSCustomObject]@{ Success=$false; Entries=@(); Error=$_.Exception.Message }
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

function Get-ConversionItems {
    $script:ScanFailures = @(); $script:UntouchedSources=@()
    $results = @()
    [long]$discovered=0
    $sourceFiles = @(Get-ChildItem -LiteralPath $script:SourceRoot -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            if (-not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and ($_.Extension -ieq '.ipf' -or $_.Extension -ieq '.zip')) {
                $discovered++; $_
            }
            Show-PreparationProgress 'Scanning SRC' $_.Name $discovered -1 'inputs'
        } | Sort-Object FullName)
    Show-PreparationProgress 'Scanning SRC' 'Source input list collected.' $sourceFiles.Count $sourceFiles.Count 'inputs' -Force
    $checked=0
    Show-PreparationProgress 'Reading IPF inputs' 'Reading loose files and archive directories.' 0 $sourceFiles.Count 'inputs'

    foreach ($file in $sourceFiles) {
        Show-PreparationProgress 'Reading IPF inputs' $file.Name $checked $sourceFiles.Count 'inputs'
        try {
            $relative = Get-RelativePathCompat $script:SourceRoot $file.FullName
            if ($file.Extension -ieq '.ipf') {
                $results += [PSCustomObject]@{
                    Type='Loose'; InputPath=$file.FullName; EntryName=$null; SourceBlockReason=''; SourceHash=$null
                    RelativeOutput=[IO.Path]::ChangeExtension($relative, '.dsk')
                    DisplayName=$relative
                }
                continue
            }

            $zipResult = Get-ZipIPFEntryNames $file.FullName
            if (-not $zipResult.Success) {
                $script:ScanFailures += [PSCustomObject]@{ DisplayName=$relative; InputPath=$file.FullName; Error=$zipResult.Error }
                continue
            }
            $entries = @($zipResult.Entries)
            if ($entries.Count -eq 0) {
                $script:UntouchedSources+=[pscustomobject]@{InputPath=$file.FullName; Reason='ZIP has no IPF images; original kept.'}
                continue
            }
            $sourceBlockReason=''
            if ($zipResult.OtherFiles -gt 0) {$sourceBlockReason='ZIP includes files that are not converted to DSK; original kept to preserve them.'}

            if ($entries.Count -eq 1) {
                $results += [PSCustomObject]@{
                    Type='Zip'; InputPath=$file.FullName; EntryName=$entries[0]; SourceBlockReason=$sourceBlockReason; SourceHash=$zipResult.Hash
                    RelativeOutput=[IO.Path]::ChangeExtension($relative, '.dsk')
                    DisplayName=($relative + ' :: ' + $entries[0])
                }
            } else {
                $relativeDir = Split-Path -Parent $relative
                if ($relativeDir -eq '.') { $relativeDir = '' }
                $archiveFolder = [IO.Path]::GetFileNameWithoutExtension($file.Name)
                $base = Join-RelativePath $relativeDir $archiveFolder
                foreach ($entry in $entries) {
                    $safeEntry = Get-SafeZipRelativePath $entry
                    $results += [PSCustomObject]@{
                        Type='Zip'; InputPath=$file.FullName; EntryName=$entry; SourceBlockReason=$sourceBlockReason; SourceHash=$zipResult.Hash
                        RelativeOutput=(Join-RelativePath $base ([IO.Path]::ChangeExtension($safeEntry, '.dsk')))
                        DisplayName=($relative + ' :: ' + $entry)
                    }
                }
            }
        } finally {
            $checked++; Show-PreparationProgress 'Reading IPF inputs' $file.Name $checked $sourceFiles.Count 'inputs'
        }
    }
    return $results
}

function Ask-OutputMode {
    while ($true) {
        $answer=Read-DisplayInput 'Choose output [Enter = 2]' 'ZX Spectrum' @(
            'Convert IPF to DSK. Keep or Remove originals is chosen next.',
            '1. Loose DSK files', '2. One ZIP per DSK', 'B. Back (return to caller)     Q. Exit')
        switch ($answer) {
            '1' {return 'LooseDSK'}
            '2' {return 'ZipDSK'}
            '' {return 'ZipDSK'}
            'B' {return 'Back'}
            'Q' {return 'Back'}
            default {Write-Host '  Choose 1, 2, B or Q.'}
        }
    }
}

function Get-FinalRelativeOutput([string]$RelativeDsk) {
    if ($script:OutputMode -eq 'ZipDSK') {
        return [IO.Path]::ChangeExtension($RelativeDsk, '.zip')
    }
    return $RelativeDsk
}

function Get-OutputCollisions([object[]]$Items) {
    $seen = @{}
    $collisions = @(); $checked=0
    Show-PreparationProgress 'Checking output path conflicts' 'Checking converted-image destinations.' 0 $Items.Count 'images'
    foreach ($item in $Items) {
        $key = Get-FinalRelativeOutput ([string]$item.RelativeOutput)
        if ($seen.ContainsKey($key)) {
            $collisions += [PSCustomObject]@{ RelativeOutput=$key; First=[string]$seen[$key]; Second=[string]$item.DisplayName }
        } else {
            $seen[$key] = [string]$item.DisplayName
        }
        $checked++; Show-PreparationProgress 'Checking output path conflicts' $item.DisplayName $checked $Items.Count 'images'
    }
    return $collisions
}

function Stage-LooseIPF([string]$InputPath) {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ZX_IPF_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $input = $null
    $output = $null
    $complete=$false
    try {
        $tempFile = Join-Path $tempRoot 'disk.ipf'
        # Open the preservation source explicitly read-only, then give HxC only the staged copy.
        $input = [IO.File]::Open($InputPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $output = [IO.File]::Create($tempFile)
        $input.CopyTo($output)
        $output.Flush()
        $complete=$true
        return [PSCustomObject]@{ Path=$tempFile; TempRoot=$tempRoot }
    } finally {
        if ($output) { $output.Dispose() }
        if ($input) { $input.Dispose() }
        if (-not $complete -and (Test-Path -LiteralPath $tempRoot)) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ZIP CRCs are read from the central directory, including ZIP64 metadata.
# .NET Framework's ZipArchive does not expose or enforce these checksums.
# Format reference: https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
# This helper is embedded in each worker; it needs no extra runtime or DLL.
function Initialize-ZipIntegrity {
    if ('OptiMiyoo.ZipCrc32' -as [type]) {return}
    Add-OptiMiyooType -TypeDefinition @'
using System;
using System.IO;
namespace OptiMiyoo {
    public sealed class ZipCrc32 {
        private uint state = 0xffffffffU;
        private static readonly uint[] table = MakeTable();
        private static uint[] MakeTable() {
            uint[] result = new uint[256];
            for (uint i = 0; i < 256; i++) {
                uint c = i;
                for (int b = 0; b < 8; b++) c = (c >> 1) ^ ((c & 1) == 0 ? 0 : 0xedb88320U);
                result[i] = c;
            }
            return result;
        }
        public void Update(byte[] bytes, int count) {
            if (count < 0 || count > bytes.Length) throw new ArgumentOutOfRangeException("count");
            uint c = state;
            for (int i = 0; i < count; i++) c = table[(c ^ bytes[i]) & 255] ^ (c >> 8);
            state = c;
        }
        public void Verify(uint expected, string name) {
            uint actual = state ^ 0xffffffffU;
            if (actual != expected) throw new InvalidDataException(
                "ZIP CRC mismatch: " + name + " (expected " + expected.ToString("X8") +
                ", read " + actual.ToString("X8") + "). Archive is damaged; source kept.");
        }
        private static byte[] ReadBytes(BinaryReader reader, int count) {
            byte[] bytes = reader.ReadBytes(count);
            if (bytes.Length != count) throw new InvalidDataException("Truncated ZIP directory.");
            return bytes;
        }
        private static ushort U16(byte[] bytes, int pos) { return BitConverter.ToUInt16(bytes, pos); }
        private static uint U32(byte[] bytes, int pos) { return BitConverter.ToUInt32(bytes, pos); }
        private static ulong U64(byte[] bytes, int pos) { return BitConverter.ToUInt64(bytes, pos); }
        public static uint[] ReadChecksums(string path, int expectedCount) {
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (BinaryReader reader = new BinaryReader(stream)) {
                int tailLength = (int)Math.Min(stream.Length, 65557L);
                stream.Position = stream.Length - tailLength;
                byte[] tail = ReadBytes(reader, tailLength);
                int end = -1;
                for (int i = tail.Length - 22; i >= 0; i--) {
                    if (U32(tail, i) == 0x06054b50U && i + 22 + U16(tail, i + 20) == tail.Length) {
                        end = i; break;
                    }
                }
                if (end < 0) throw new InvalidDataException("ZIP end record is missing or truncated.");
                long endPosition = stream.Length - tailLength + end;
                if (U16(tail, end + 4) != 0 || U16(tail, end + 6) != 0)
                    throw new InvalidDataException("Split ZIP archives are unsupported. Combine the parts first.");
                ulong count = U16(tail, end + 10), onDisk = U16(tail, end + 8);
                ulong size = U32(tail, end + 12), offset = U32(tail, end + 16);
                long directoryLimit = endPosition;
                bool zip64 = false;
                if (endPosition >= 20) {
                    stream.Position = endPosition - 20;
                    byte[] locator = ReadBytes(reader, 20);
                    if (U32(locator, 0) == 0x07064b50U) {
                        zip64 = true;
                        if (U32(locator, 4) != 0 || U32(locator, 16) != 1)
                            throw new InvalidDataException("Split ZIP64 archives are unsupported.");
                        ulong position = U64(locator, 8);
                        if (position > (ulong)(endPosition - 20) || (ulong)(endPosition - 20) - position < 56)
                            throw new InvalidDataException("Invalid ZIP64 directory location.");
                        stream.Position = (long)position;
                        byte[] record = ReadBytes(reader, 56);
                        ulong recordSize = U64(record, 4);
                        if (U32(record, 0) != 0x06064b50U || recordSize < 44 ||
                            recordSize != (ulong)(endPosition - 20) - position - 12)
                            throw new InvalidDataException("Invalid ZIP64 end record.");
                        if (U32(record, 16) != 0 || U32(record, 20) != 0)
                            throw new InvalidDataException("Split ZIP64 archives are unsupported.");
                        onDisk = U64(record, 24); count = U64(record, 32);
                        size = U64(record, 40); offset = U64(record, 48);
                        directoryLimit = (long)position;
                    }
                }
                if (!zip64 && (size == 0xffffffffU || offset == 0xffffffffU))
                    throw new InvalidDataException("ZIP64 directory locator is missing.");
                if (onDisk != count || count != (ulong)expectedCount || count > size / 46 ||
                    offset > (ulong)directoryLimit || size > (ulong)directoryLimit - offset)
                    throw new InvalidDataException("ZIP directory count or bounds mismatch.");
                long directoryEnd = (long)(offset + size);
                stream.Position = (long)offset;
                uint[] checksums = new uint[expectedCount];
                for (int i = 0; i < expectedCount; i++) {
                    if (directoryEnd - stream.Position < 46) throw new InvalidDataException("Truncated ZIP directory entry.");
                    byte[] header = ReadBytes(reader, 46);
                    if (U32(header, 0) != 0x02014b50U) throw new InvalidDataException("Invalid ZIP directory entry.");
                    if ((U16(header, 8) & 0x2041) != 0) throw new InvalidDataException("Encrypted ZIP entries are unsupported.");
                    if (U16(header, 34) != 0) throw new InvalidDataException("Split ZIP entries are unsupported.");
                    checksums[i] = U32(header, 16);
                    int remaining = U16(header, 28) + U16(header, 30) + U16(header, 32);
                    if (remaining > directoryEnd - stream.Position) throw new InvalidDataException("Truncated ZIP entry metadata.");
                    stream.Position += remaining;
                }
                return checksums;
            }
        }
    }
}
'@
}
function Get-ZipChecksums([string]$Path,[int]$EntryCount) {
    Initialize-ZipIntegrity
    return ,([OptiMiyoo.ZipCrc32]::ReadChecksums($Path,$EntryCount))
}

function Expand-OneZipIPF([string]$ZipPath, [string]$EntryName) {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ZX_IPF_' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($tempRoot)
    $zip=$null; $inputStream=$null; $output=$null; $complete=$false
    try {
        $zip=[IO.Compression.ZipFile]::OpenRead($ZipPath)
        $checksums=Get-ZipChecksums $ZipPath $zip.Entries.Count
        $entry=$null; $entryIndex=-1
        for ($i=0; $i -lt $zip.Entries.Count; $i++) {
            if ($zip.Entries[$i].FullName -ceq $EntryName) {
                if ($entry) {throw ('Duplicate IPF entry inside ZIP: '+$EntryName)}
                $entry=$zip.Entries[$i]; $entryIndex=$i
            }
        }
        if (-not $entry) {throw ('IPF entry not found inside ZIP: '+$EntryName)}
        $tempFile=Join-Path $tempRoot 'disk.ipf'
        $inputStream=$entry.Open(); $output=[IO.File]::Create($tempFile)
        $crc=New-Object OptiMiyoo.ZipCrc32
        $buffer=New-Object byte[] 1048576; [long]$total=0
        while (($n=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
            $output.Write($buffer,0,$n); $crc.Update($buffer,$n); $total+=$n
            Show-Stage 0 'Preparing IPF from ZIP' $EntryName (100*$total/[Math]::Max(1,$entry.Length))
        }
        if ($total -ne $entry.Length) {throw ('Incomplete ZIP entry: '+$EntryName)}
        $crc.Verify($checksums[$entryIndex],$EntryName)
        $output.Flush(); $output.Dispose(); $output=$null
        $complete=$true
        return [PSCustomObject]@{Path=$tempFile; TempRoot=$tempRoot}
    } finally {
        # Release file handles before removing a failed staging directory on Windows.
        if ($output) {$output.Dispose()}
        if ($inputStream) {$inputStream.Dispose()}
        if ($zip) {$zip.Dispose()}
        if (-not $complete -and (Test-Path -LiteralPath $tempRoot)) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# DSK/EDSK layout: 256-byte disk header, then declared track blocks.
# EDSK Rev.5: https://simonowen.com/mirror/extdsk.html
# HxC writer: libhxcfe/sources/loaders/cpcdsk_loader/cpcdsk_writer.c
# Validate storage boundaries only: protected sector IDs, FDC error flags,
# weak-sector copies, empty tracks and padding are valid format features.
function Read-DskBlock([IO.Stream]$Stream,[byte[]]$Buffer) {
    $offset=0
    while ($offset -lt $Buffer.Length) {
        $read=$Stream.Read($Buffer,$offset,$Buffer.Length-$offset)
        if ($read -le 0) {return $false}
        $offset+=$read
    }
    return $true
}

function Test-DskStream([IO.Stream]$Stream,[long]$Length) {
    try {
        if ($Length -lt 256) {return $false}
        $disk=New-Object byte[] 256
        if (-not (Read-DskBlock $Stream $disk)) {return $false}
        $signature=[Text.Encoding]::ASCII.GetString($disk,0,34)
        $extended=$signature -ceq "EXTENDED CPC DSK File`r`nDisk-Info`r`n"
        if (-not $extended -and $signature -cne "MV - CPCEMU Disk-File`r`nDisk-Info`r`n") {return $false}
        $tracks=[int]$disk[0x30]; $sides=[int]$disk[0x31]
        if ($tracks -lt 1 -or $sides -lt 1 -or $sides -gt 2) {return $false}
        $trackSides=$tracks*$sides
        if ($extended -and (0x34+$trackSides) -gt 256) {return $false}
        $standardSize=[int]$disk[0x32]+256*[int]$disk[0x33]
        if (-not $extended -and $standardSize -lt 256) {return $false}
        [long]$position=256
        $track=New-Object byte[] 256
        $scratch=New-Object byte[] 65536
        for ($i=0; $i -lt $trackSides; $i++) {
            $size=$standardSize
            if ($extended) {$size=256*[int]$disk[0x34+$i]}
            # A zero EDSK size has no track header or data.
            if ($extended -and $size -eq 0) {continue}
            if ($size -lt 256 -or $size -gt ($Length-$position)) {return $false}
            if (-not (Read-DskBlock $Stream $track)) {return $false}
            if ([Text.Encoding]::ASCII.GetString($track,0,12) -cne "Track-Info`r`n") {return $false}
            $sectors=[int]$track[0x15]
            if ((0x18+8*$sectors) -gt 256) {return $false}
            [long]$dataSize=0
            if ($extended) {
                for ($j=0; $j -lt $sectors; $j++) {
                    $offset=0x18+8*$j
                    # Explicit EDSK lengths include all weak-sector copies;
                    # zero length can describe a sector without a data field.
                    $dataSize+=[int]$track[$offset+6]+256*[int]$track[$offset+7]
                }
            } elseif ($sectors -gt 0) {
                $sizeCode=[int]$track[0x14] -band 7
                [long]$sectorSize=128 -shl $sizeCode
                # Original DSK convention stores at least 6144 bytes for N=6.
                # Full 8192-byte sectors and track padding remain accepted.
                if ($sizeCode -eq 6) {$sectorSize=6144}
                $dataSize=$sectorSize*$sectors
            }
            if ($dataSize -gt ($size-256)) {return $false}
            [long]$remaining=$size-256
            while ($remaining -gt 0) {
                $read=$Stream.Read($scratch,0,[int][Math]::Min($scratch.Length,$remaining))
                if ($read -le 0) {return $false}
                $remaining-=$read
            }
            $position+=$size
        }
        return $true
    } catch {return $false}
}

function Test-DSK([string]$Path) {
    $stream=$null
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {return $false}
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        return (Test-DskStream $stream $stream.Length)
    } catch {return $false}
    finally {if ($stream) {$stream.Dispose()}}
}

function Test-ZipDskPackage([string]$ZipPath, [string]$ExpectedEntryName) {
    $zip = $null
    $stream = $null
    try {
        if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { return $false }
        $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
        $entries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
        if ($entries.Count -ne 1) { return $false }
        $entry = $entries[0]
        if ($entry.Name -ne $ExpectedEntryName) { return $false }
        if ([IO.Path]::GetExtension($entry.Name) -ine '.dsk') { return $false }
        $stream=$entry.Open()
        if (-not (Test-DskStream $stream $entry.Length)) {return $false}
        $stream.Dispose(); $stream=$entry.Open()

        $checksums=Get-ZipChecksums $ZipPath $zip.Entries.Count
        $entryIndex=$zip.Entries.IndexOf($entry)
        $crc=New-Object OptiMiyoo.ZipCrc32
        # Validate all bytes, including corruption that still decompresses normally.
        $scratch = New-Object -TypeName byte[] -ArgumentList 65536
        [long]$total = 0
        while (($n = $stream.Read($scratch, 0, $scratch.Length)) -gt 0) {$crc.Update($scratch,$n); $total += $n}
        $crc.Verify($checksums[$entryIndex],$entry.FullName)
        return ($total -eq $entry.Length)
    } catch {
        return $false
    } finally {
        if ($stream) { try { $stream.Dispose() } catch {} }
        if ($zip) { try { $zip.Dispose() } catch {} }
    }
}

function New-DskZipPackage([string]$DskPath, [string]$ZipPath, [string]$EntryName) {
    if (-not (Test-DSK $DskPath)) { throw 'Refusing to ZIP output because DSK validation failed.' }
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue }
    $zipDir = Split-Path -Parent $ZipPath
    $tempPackDir = Join-Path $zipDir ('.zxpack_' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tempPackDir -Force | Out-Null
        $stagedDsk = Join-Path $tempPackDir $EntryName
        [IO.File]::Copy($DskPath, $stagedDsk, $true)
        [IO.Compression.ZipFile]::CreateFromDirectory($tempPackDir, $ZipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
        if (-not (Test-ZipDskPackage $ZipPath $EntryName)) {
            throw 'ZIP package validation failed.'
        }
    } catch {
        if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue }
        throw
    } finally {
        if (Test-Path -LiteralPath $tempPackDir) { Remove-Item -LiteralPath $tempPackDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Commit-FileSafely([string]$WorkPath, [string]$FinalPath, [string]$Kind) {
    $backupPath = $null
    $installed=$false
    $hadPrevious = Test-Path -LiteralPath $FinalPath
    $expectedHash=Get-SourcePolicyHash $WorkPath
    try {
        if ($hadPrevious) {
            $outDir = Split-Path -Parent $FinalPath
            $ext = [IO.Path]::GetExtension($FinalPath)
            if ([string]::IsNullOrWhiteSpace($ext)) { $ext = '.bak' }
            $backupPath = Join-Path $outDir ('.zxbackup_' + [Guid]::NewGuid().ToString('N') + $ext)
            [IO.File]::Move($FinalPath, $backupPath)
        }
        [IO.File]::Move($WorkPath, $FinalPath)
        $installed=$true
        $locks=Open-SourcePolicyOutputs @([pscustomobject]@{Destination=$FinalPath;Folder=$false;Hash=$expectedHash})
        foreach ($lock in $locks) {$lock.Dispose()}
        if ($backupPath -and (Test-Path -LiteralPath $backupPath)) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
        return $expectedHash
    } catch {
        $commitError = $_.Exception.Message
        if ($backupPath -and (Test-Path -LiteralPath $backupPath)) {
            try {
                if (Test-Path -LiteralPath $FinalPath) { Remove-Item -LiteralPath $FinalPath -Force -ErrorAction SilentlyContinue }
                [IO.File]::Move($backupPath, $FinalPath)
            } catch {
                throw ("New {0} install failed and old output restore also failed. Backup kept at: {1}. Commit: {2}. Restore: {3}" -f $Kind, $backupPath, $commitError, $_.Exception.Message)
            }
            throw ("New {0} install failed; previous output was restored. {1}" -f $Kind, $commitError)
        }
        if ($installed -and (Test-Path -LiteralPath $FinalPath)) {
            try {Remove-Item -LiteralPath $FinalPath -Force -ErrorAction Stop}
            catch {throw ("New {0} install failed and incomplete output could not be removed: {1}. Commit: {2}. Cleanup: {3}" -f $Kind,$FinalPath,$commitError,$_.Exception.Message)}
        }
        throw ("New {0} install failed; no previous destination file was changed. {1}" -f $Kind, $commitError)
    }
}

function Commit-DskSafely([string]$WorkPath, [string]$FinalPath) {
    if (-not (Test-DSK $WorkPath)) { throw 'Refusing to install output because DSK validation failed.' }
    Commit-FileSafely $WorkPath $FinalPath 'DSK'
}

function Commit-ZipSafely([string]$WorkPath, [string]$FinalPath, [string]$ExpectedEntryName) {
    if (-not (Test-ZipDskPackage $WorkPath $ExpectedEntryName)) { throw 'Refusing to install output because ZIP validation failed.' }
    Commit-FileSafely $WorkPath $FinalPath 'ZIP'
}

function Invoke-HxCOnce([string]$EnginePath, [string]$InputPath, [string]$OutputPath) {
    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue }
    $arguments = ('-verbose -finput:"{0}" -conv:AMSTRADCPC_DSK -foutput:"{1}"' -f $InputPath, $OutputPath)
    $label = Get-EngineLabel $EnginePath
    $run = Invoke-EngineText $EnginePath $arguments 120000
    Show-Stage 0 'Verifying DSK output' ([IO.Path]::GetFileName($InputPath))
    $valid = Test-DSK $OutputPath
    $detail = $run.Output
    if ([string]::IsNullOrWhiteSpace($detail)) { $detail = '(no stdout/stderr text)' }

    Write-Diagnostic ('===== CONVERSION ATTEMPT: ' + $label + ' =====')
    Write-Diagnostic ('Input: ' + $InputPath)
    Write-Diagnostic ('Output: ' + $OutputPath)
    try { Write-Diagnostic ('Input bytes: ' + (Get-Item -LiteralPath $InputPath).Length) } catch {}
    Write-Diagnostic ('Arguments: ' + $arguments)
    Write-Diagnostic ('Exit code: ' + $run.ExitCode)
    Write-Diagnostic ('Timed out: ' + $run.TimedOut)
    Write-Diagnostic ('Output DSK valid: ' + $valid)
    Write-Diagnostic '--- HxC stdout/stderr (FULL, NOT TRUNCATED) ---'
    Write-Diagnostic $detail
    Write-Diagnostic '===== END CONVERSION ATTEMPT ====='

    if ($run.TimedOut) {
        return [PSCustomObject]@{ Success=$false; Detail='HxC timed out after 120 seconds.'; Engine=$label; NonZeroExit=$false }
    }
    if ($valid) {
        return [PSCustomObject]@{ Success=$true; Detail=''; Engine=$label; NonZeroExit=($run.ExitCode -ne 0) }
    }

    $infoArguments = ('-verbose -finput:"{0}" -infos' -f $InputPath)
    $info = Invoke-EngineText $EnginePath $infoArguments 30000
    Write-Diagnostic ('===== INPUT INFO AFTER FAILURE: ' + $label + ' =====')
    Write-Diagnostic ('Arguments: ' + $infoArguments)
    Write-Diagnostic ('Exit code: ' + $info.ExitCode)
    Write-Diagnostic $info.Output
    Write-Diagnostic '===== END INPUT INFO ====='
    if (-not [string]::IsNullOrWhiteSpace($info.Output)) { $detail += "`r`n--- input-info ---`r`n" + $info.Output }
    return [PSCustomObject]@{ Success=$false; Detail=$detail; Engine=$label; NonZeroExit=$false }
}

function Invoke-HxCAttempt([string]$EnginePath,[string]$InputPath,[string]$OutputPath) {
    try {return (Invoke-HxCOnce $EnginePath $InputPath $OutputPath)}
    catch {
        $detail='Engine execution failed: '+$_.Exception.Message
        Write-Diagnostic ((Get-EngineLabel $EnginePath)+' | '+$detail)
        return [pscustomobject]@{Success=$false;Detail=$detail;Engine=(Get-EngineLabel $EnginePath);NonZeroExit=$false}
    }
}

function Invoke-HxCConversion([string]$InputPath, [string]$OutputPath) {
    $first = Invoke-HxCAttempt $script:HxCExe $InputPath $OutputPath
    if ($first.Success) { return $first }
    if ($script:HxCFallback) {
        Write-Status 'WARN' ('Primary engine failed; retrying with ' + (Get-EngineLabel $script:HxCFallback) + '.')
        $second = Invoke-HxCAttempt $script:HxCFallback $InputPath $OutputPath
        if ($second.Success) {
            $second | Add-Member -NotePropertyName UsedFallback -NotePropertyValue $true -Force
            return $second
        }
        return [PSCustomObject]@{
            Success=$false
            Detail=("PRIMARY ({0}):`r`n{1}`r`n`r`nFALLBACK ({2}):`r`n{3}" -f $first.Engine, $first.Detail, $second.Engine, $second.Detail)
            Engine=($first.Engine + ' + ' + $second.Engine)
            NonZeroExit=$false
        }
    }
    return $first
}

function Get-UsefulFailureSummary([string]$Detail) {
    if ([string]::IsNullOrWhiteSpace($Detail)) { return 'HxC returned no diagnostic text. See the log.' }
    if ($Detail -match "(?i)Can't load CAPSImg\.dll|No Caps lib available|Failed to load CAPS library") {
        return 'CAPSImg.dll could not load its MinGW runtime dependency. See the CAPS preflight section in the log.'
    }
    $lines = @($Detail -split '[\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object {
        $_ -and
        $_ -notmatch '^HxC Floppy Emulator' -and
        $_ -notmatch '^Copyright ' -and
        $_ -notmatch '^This program comes with' -and
        $_ -notmatch '^This is free software' -and
        $_ -notmatch '^under certain conditions' -and
        $_ -notmatch '^libhxcfe version' -and
        $_ -notmatch '^Input file\s*:'
    })
    if ($lines.Count -eq 0) { return 'HxC failed. See the full log for details.' }
    $start = [Math]::Max(0, $lines.Count - 3)
    $summary = [string]::Join(' | ', @($lines[$start..($lines.Count - 1)]))
    if ($summary.Length -gt 500) { $summary = $summary.Substring(0, 500) + '...' }
    return $summary
}

function Ask-Overwrite([string]$RelativeOutput) {
    $warnings=@('B / Q keeps ALL existing outputs.')
    $choices=@('1 Overwrite | 2 Skip', '3 Overwrite all | 4 Skip all | B/Q Cancel')
    $invalid=$false
    while ($true) {
        $shownWarnings=$warnings
        if ($invalid) {$shownWarnings+='Please enter 1, 2, 3, or 4.'}
        $answer=([string](Read-OverwriteChoice 'ZX Spectrum / existing output' @($RelativeOutput) $shownWarnings $choices 'Choose 1, 2, 3, or 4')).Trim()
        switch ($answer) {
            '1' { return 'Overwrite' }
            '2' { return 'Skip' }
            '3' { return 'OverwriteAll' }
            '4' { return 'SkipAll' }
            'B' { return 'SkipAll' }
            'Q' { return 'SkipAll' }
            default { $invalid=$true }
        }
    }
}

function Show-Summary {
    $script:Processed=$script:Total; $script:Ok=$script:Converted
    $sourceSummary=Get-SourcePolicySummary $script:SourcePlan
    Show-ClosingPanel -RemovalFailures $sourceSummary.Failed
    Write-Host ''
    Write-Host '  +---------------------- RESULTS ----------------------+' -ForegroundColor Cyan
    Write-Host ('  Converted : {0}' -f $script:Converted) -ForegroundColor Cyan
    Write-Host ('  Skipped   : {0}' -f $script:Skipped) -ForegroundColor Yellow
    Write-Host ('  Failed    : {0}' -f $script:Failed) -ForegroundColor Magenta
    Write-Host ('  Total     : {0}' -f $script:Total) -ForegroundColor White
    Write-Host ('  Source policy: '+$SourcePolicy.ToUpperInvariant())
    Write-Host ('  Originals in this batch: {0} removed | {1} kept | {2} removal failures' -f $sourceSummary.Removed,$sourceSummary.Kept,$sourceSummary.Failed)
    Write-LogFile ('Originals: {0} removed; {1} kept; {2} removal failures' -f $sourceSummary.Removed,$sourceSummary.Kept,$sourceSummary.Failed)
    Write-Host '  +-----------------------------------------------------+' -ForegroundColor Cyan
    Write-Host ('  Log: ' + $script:LogPath) -ForegroundColor DarkGray
    Write-Host ''
    Write-LogFile ''
    Write-LogFile ('Converted: ' + $script:Converted)
    Write-LogFile ('Skipped: ' + $script:Skipped)
    Write-LogFile ('Failed: ' + $script:Failed)
    Write-LogFile ('Total: ' + $script:Total)
}

function Main {
    Write-Banner
    while ($true) {
        if ($Format -eq 'Ask') {$script:OutputMode=Ask-OutputMode} else {$script:OutputMode=$Format}
        if ($script:OutputMode -eq 'Back') {return 0}
        if ($script:ChooseSourcePolicy) {
            $policyChoice=Read-SourcePolicy 'ZX Spectrum'
            if ($policyChoice -eq 'Back') {continue}
            if ($policyChoice -eq 'Exit') {return 0}
            $script:SourcePolicy=$policyChoice
        }
        break
    }
    $script:SourcePlan=New-SourcePolicyPlan $script:SourceRoot $SourcePolicy
    $script:Clock.Restart()
    Start-Log
    Write-Status 'INFO' ('Source policy: '+$SourcePolicy.ToUpperInvariant()+'. Skipped/failed inputs stay in SRC.')
    if ($script:OutputMode -eq 'ZipDSK') {
        Write-Status 'INFO' 'Output mode: one ZIP per converted DSK.'
    } else {
        Write-Status 'INFO' 'Output mode: loose DSK files.'
    }

    Write-Status 'INFO' ('Scanning ' + $script:SourceRoot)
    Show-ConversionStart 'ZX Spectrum / IPF -> DSK'
    $items = @(Get-ConversionItems)
    $sourceIndex=0
    $sourceTotal=$items.Count+$script:ScanFailures.Count+$script:UntouchedSources.Count
    Show-PreparationProgress 'Checking source dependencies' 'Recording input ownership.' 0 $sourceTotal 'inputs'
    foreach ($item in $items) {
        $item | Add-Member -NotePropertyName SourceId -NotePropertyValue ([string]$sourceIndex)
        Add-SourcePolicyJob $script:SourcePlan ([string]$sourceIndex) @($item.InputPath) $item.SourceBlockReason
        $sourceIndex++
        Show-PreparationProgress 'Checking source dependencies' $item.InputPath $sourceIndex $sourceTotal 'inputs'
    }
    foreach ($item in $script:ScanFailures) {
        Add-SourcePolicyJob $script:SourcePlan ('scan-'+$sourceIndex) @($item.InputPath) 'Unreadable ZIP; original kept.'
        $sourceIndex++
        Show-PreparationProgress 'Checking source dependencies' $item.InputPath $sourceIndex $sourceTotal 'inputs'
    }
    foreach ($item in $script:UntouchedSources) {
        Add-SourcePolicyJob $script:SourcePlan ('untouched-'+$sourceIndex) @($item.InputPath) $item.Reason
        $sourceIndex++
        Show-PreparationProgress 'Checking source dependencies' $item.InputPath $sourceIndex $sourceTotal 'inputs'
    }

    foreach ($scanFailure in $script:ScanFailures) {
        $script:Failed++
        Write-Status 'FAIL' ($scanFailure.DisplayName + ' | ZIP could not be read: ' + $scanFailure.Error)
    }

    if ($items.Count -eq 0 -and $script:ScanFailures.Count -gt 0) {
        $script:Total=$script:ScanFailures.Count
        Write-Status 'WARN' 'No readable IPF inputs remain. The conversion engine was not started.'
        Show-Summary
        return 1
    }
    if ($items.Count -eq 0 -and $script:ScanFailures.Count -eq 0) {
        Write-Status 'WARN' 'No .IPF files were found, loose or inside ZIP archives.'
        Write-Status 'INFO' 'Put your files in SRC and run the BAT again.'
        $script:Total = 0
        Show-Summary
        return 0
    }

    $collisions = @(Get-OutputCollisions $items)
    Complete-PreparationProgress
    if ($collisions.Count -gt 0) {
        Write-Status 'FAIL' 'Two or more source images would map to the same destination output. Nothing was converted.'
        foreach ($collision in $collisions) {
            Write-Status 'FAIL' ('Collision: ' + $collision.RelativeOutput + ' <= [' + $collision.First + '] / [' + $collision.Second + ']')
        }
        $script:Failed += $items.Count
        $script:Total = $items.Count + $script:ScanFailures.Count
        Show-Summary
        return 2
    }

    $script:Total = $items.Count + $script:ScanFailures.Count
    $looseCount = @($items | Where-Object { $_.Type -eq 'Loose' }).Count
    $zipCount = @($items | Where-Object { $_.Type -eq 'Zip' }).Count
    Write-Status 'INFO' ("Found {0} IPF image(s): {1} loose, {2} inside ZIP(s)." -f $items.Count, $looseCount, $zipCount)
    if ($script:OutputMode -eq 'ZipDSK') {
        Write-Status 'INFO' 'ZIP inputs are extracted temporarily; each validated DSK is re-packed as its own ZIP in DST.'
    } else {
        Write-Status 'INFO' 'ZIP inputs are extracted temporarily; DST receives loose .DSK files.'
    }

    $probeItems=@($items)
    if ($script:OverwriteMode -eq 'SkipAll') {
        $probeItems=@($items | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $script:DestinationRoot (Get-FinalRelativeOutput $_.RelativeOutput)))
        })
    }
    if ($probeItems.Count -gt 0) {
        if (-not (Ensure-HxC)) {
            Write-Status 'FAIL' 'Bundled HxC engine could not start. See the full log.'
            $script:Failed += $probeItems.Count
            $script:Skipped += $items.Count-$probeItems.Count
            Show-Summary
            return 3
        }

        $capsReady=$false
        foreach ($probeItem in $probeItems) {
            try {
                if (Ensure-CapsIPFReady $probeItem) {$capsReady=$true; break}
                if ($script:CapsPreflightGlobalFailure) {break}
            } catch {
                Write-Status 'WARN' ($probeItem.DisplayName+' | preflight input failed: '+$_.Exception.Message)
                Write-Diagnostic ('PREFLIGHT EXCEPTION: '+($_ | Out-String))
            }
        }
        if (-not $capsReady) {
            Write-Status 'FAIL' 'No input passed CAPS/IPF preflight. Originals were kept.'
            $script:Failed += $probeItems.Count
            $script:Skipped += $items.Count-$probeItems.Count
            Show-Summary
            return 4
        }
    }

    $index = 0
    foreach ($item in $items) {
        $index++
        $tempRoot=$null; $workOutPath=$null; $workZipPath=$null; $sourceLease=$null
        try {
            $relativeDsk = [string]$item.RelativeOutput
            $relativeOutput = Get-FinalRelativeOutput $relativeDsk
            $outPath = Join-Path $script:DestinationRoot $relativeOutput
            Assert-PlainOutputParents $outPath $Root
            if ((Test-Path -LiteralPath $outPath) -and ((Get-Item -LiteralPath $outPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Destination is a link; output left alone.'}
            $outDir = Split-Path -Parent $outPath
            if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

            $script:CurrentZXItem=$item.DisplayName; $script:UiGame=$item.DisplayName
            Write-Event 'GAME' ('{0}/{1} | {2}' -f $index,$items.Count,$item.DisplayName)

            if (Test-Path -LiteralPath $outPath) {
                $choice = $script:OverwriteMode
                if ($choice -eq 'Ask') { $choice = Ask-Overwrite $relativeOutput }
                if ($choice -eq 'OverwriteAll') { $script:OverwriteMode = 'OverwriteAll'; $choice = 'Overwrite' }
                if ($choice -eq 'SkipAll') { $script:OverwriteMode = 'SkipAll'; $choice = 'Skip' }
                if ($choice -eq 'Skip') {
                    $script:Skipped++
                    Write-Status 'SKIP' ($item.DisplayName + ' -> output already exists')
                    continue
                }
            }

            $inputPath = [string]$item.InputPath
            $tempRoot = $null
            $workOutPath = Join-Path $outDir ('.zxconv_' + [Guid]::NewGuid().ToString('N') + '.dsk')
            $workZipPath = $null
            $sourceHashes=@{}
            if ($SourcePolicy -eq 'Remove') {
                # Keep one pinned read handle across hashing and staging, so a
                # source cannot be swapped out and restored between those reads.
                $sourceLease=Open-SourcePolicyReadLease $item.InputPath $script:SourceRoot
                Assert-SourcePolicyPath $item.InputPath $script:SourceRoot
                $sourceHash=Get-SourcePolicyHash $item.InputPath
                if ($item.Type -eq 'Zip' -and $sourceHash -ne $item.SourceHash) {throw 'Source ZIP changed since scanning; original kept.'}
                $sourceHashes[[IO.Path]::GetFullPath($item.InputPath)]=$sourceHash
            }
            if ($item.Type -eq 'Zip') {
                Write-Status 'INFO' ('Extracting temporarily: ' + $item.DisplayName)
                Show-Stage 0 'Preparing IPF from ZIP' $item.DisplayName
                $expanded = Expand-OneZipIPF $item.InputPath $item.EntryName
            } else {
                Write-Status 'INFO' ('Staging source read-only: ' + $item.DisplayName)
                Show-Stage 0 'Preparing a read-only IPF copy' $item.DisplayName
                $expanded = Stage-LooseIPF $item.InputPath
            }
            $inputPath = $expanded.Path
            $tempRoot = $expanded.TempRoot
            if ($SourcePolicy -eq 'Remove') {
                if ((Get-SourcePolicyHash $item.InputPath) -ne $sourceHash) {throw 'Source changed during staging; original kept.'}
                if ($item.Type -eq 'Loose' -and (Get-SourcePolicyHash $inputPath) -ne $sourceHash) {throw 'Staged IPF differs from source; original kept.'}
                $sourceLease.Dispose(); $sourceLease=$null
            }

            Write-Diagnostic ('##### SOURCE ITEM: ' + $item.DisplayName + ' #####')
            Write-Diagnostic ('Source container: ' + $item.InputPath)
            if ($item.EntryName) { Write-Diagnostic ('ZIP entry: ' + $item.EntryName) }
            Write-Diagnostic ('Final destination: ' + $outPath)
            Write-Diagnostic ('Output mode: ' + $script:OutputMode)
            Write-Diagnostic ('Transactional DSK work output: ' + $workOutPath)

            # Native tools never receive the user's destination path. Copy the
            # validated native result through .NET into the existing transaction
            # staging file, which remains on the destination volume for commit.
            $engineOutPath=Join-Path $tempRoot 'disk.dsk'
            $result = Invoke-HxCConversion $inputPath $engineOutPath
            if ($result.Success) {
                [IO.File]::Copy($engineOutPath,$workOutPath)
                if ((Get-SourcePolicyHash $engineOutPath) -ne (Get-SourcePolicyHash $workOutPath)) {
                    throw 'Staged DSK differs from native output; original kept.'
                }
                if ($script:OutputMode -eq 'ZipDSK') {
                    $entryName = [IO.Path]::GetFileName($relativeDsk)
                    $workZipPath = Join-Path $outDir ('.zxconv_' + [Guid]::NewGuid().ToString('N') + '.zip')
                    Show-Stage 0 'Packaging verified DSK as ZIP' $relativeOutput
                    New-DskZipPackage $workOutPath $workZipPath $entryName
                    Show-Stage 0 'Verifying and installing ZIP output' $relativeOutput
                    $outputHash=Commit-ZipSafely $workZipPath $outPath $entryName
                    if (Test-Path -LiteralPath $workOutPath) { Remove-Item -LiteralPath $workOutPath -Force -ErrorAction SilentlyContinue }
                } else {
                    Show-Stage 0 'Verifying and installing DSK output' $relativeOutput
                    $outputHash=Commit-DskSafely $workOutPath $outPath
                }
                Complete-SourcePolicyJob $script:SourcePlan $item.SourceId $sourceHashes @([pscustomobject]@{Destination=$outPath;Folder=$false;Hash=$outputHash})
                $script:Converted++
                $note = ''
                if ($result.PSObject.Properties['UsedFallback'] -and $result.UsedFallback) { $note = ' (fallback engine succeeded)' }
                elseif ($result.NonZeroExit) { $note = ' (valid DSK; HxC returned a warning exit code)' }
                Write-Status 'OK' ($item.DisplayName + ' -> ' + $relativeOutput + $note)
            } else {
                $script:Failed++
                if (Test-Path -LiteralPath $workOutPath) { Remove-Item -LiteralPath $workOutPath -Force -ErrorAction SilentlyContinue }
                Write-Status 'FAIL' ($item.DisplayName + ' | ' + (Get-UsefulFailureSummary $result.Detail))
            }
        } catch {
            $script:Failed++
            if ($workOutPath -and (Test-Path -LiteralPath $workOutPath)) { Remove-Item -LiteralPath $workOutPath -Force -ErrorAction SilentlyContinue }
            if ($workZipPath -and (Test-Path -LiteralPath $workZipPath)) { Remove-Item -LiteralPath $workZipPath -Force -ErrorAction SilentlyContinue }
            Write-Status 'FAIL' ($item.DisplayName + ' | processing error: ' + ($_.Exception.Message -replace '[\r\n]+', ' '))
            Write-Diagnostic ('PROCESSING EXCEPTION: ' + ($_ | Out-String))
        } finally {
            if ($sourceLease) {$sourceLease.Dispose()}
            if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if ($workOutPath -and (Test-Path -LiteralPath $workOutPath)) {
                Remove-Item -LiteralPath $workOutPath -Force -ErrorAction SilentlyContinue
            }
            if ($workZipPath -and (Test-Path -LiteralPath $workZipPath)) {
                Remove-Item -LiteralPath $workZipPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Invoke-SourcePolicyCleanup $script:SourcePlan {param($kind,$message) Write-Status $kind $message} {param($stage,$detail,$done,$total) Show-SourceCleanupProgress $stage $detail $done $total}
    Show-Summary
    if ($script:Failed -gt 0 -or (Get-SourcePolicySummary $script:SourcePlan).Failed -gt 0 -or $script:ReportProblem) { return 1 }
    return 0
}

try {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $exitCode = Main
    if ($script:ReportProblem -and $exitCode -eq 0) {$exitCode=1}
    exit $exitCode
} catch {
    try {
        if (-not $script:LogPath) { Start-Log }
        Write-Status 'FAIL' ('Fatal error: ' + $_.Exception.Message)
        Write-Diagnostic ('FATAL EXCEPTION: ' + ($_ | Out-String))
        Show-Summary
    } catch {}
    exit 99
} finally {Restore-Display}
