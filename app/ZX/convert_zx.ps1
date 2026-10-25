#requires -Version 5.1
param([string]$Root,[ValidateSet('Ask','LooseDSK','ZipDSK')][string]$Format='Ask',
      [ValidateSet('Zip','Loose','Folders')][string]$Storage,
      [ValidateSet('Ask','Overwrite','Skip')][string]$Existing='Ask',
      [ValidateSet('Keep','Remove')][string]$SourcePolicy='Keep',
      [switch]$NoAnimation,[switch]$NoColor,
      [ValidateSet('CRT','Smooth')][string]$DisplayEffect='CRT')
# Based on ZX converter v2.3; OptiMiyoo integration keeps its conversion engine.
# ZX IPF / ZIP -> DSK Converter v2.3 - console edition
# Windows PowerShell 5.1 compatible. No GUI. Keep originals is the default.

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'application_entry.ps1')
if (-not (Test-ApplicationWorker)) {
    exit (Enter-ApplicationHost -ApplicationRoot (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -Entry ZX -Arguments $PSBoundParameters)
}
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
$script:OverwriteMode = 'Ask'   # Ask | OverwriteAll | SkipAll
$script:OutputMode = 'LooseDSK' # LooseDSK | ZipDSK
$script:Converted = 0
$script:Skipped = 0
$script:Failed = 0
$script:Total = 0
$script:ScanFailures = @()
$script:LogPath = $null; $script:LogWriter=$null
$script:LogDisabled=$false
$script:ReportProblem=$false
$script:AppVersion='0.0.9'
$script:Processed=0; $script:Ok=0
$script:Clock=[Diagnostics.Stopwatch]::StartNew()
. (Join-Path (Split-Path -Parent $script:AppRoot) 'display.ps1')
. (Join-Path (Split-Path -Parent $script:AppRoot) 'source_policy.ps1')
. (Join-Path (Split-Path -Parent $script:AppRoot) 'archive_limits.ps1')
. (Join-Path (Split-Path -Parent $script:AppRoot) 'zip_integrity.ps1')
. (Join-Path (Split-Path -Parent $script:AppRoot) 'native_process.ps1')
. (Join-Path (Split-Path -Parent $script:AppRoot) 'archive_sandbox.ps1')
. (Join-Path (Split-Path -Parent $script:AppRoot) 'overwrite_prompt.ps1')
. (Join-Path (Split-Path -Parent $script:AppRoot) 'conversion_layout.ps1')
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

function Get-ZXConversionGroups([string]$SourceRoot,[string]$DestinationRoot,[string]$Storage) {
    Get-ConversionSourceGroups $SourceRoot $DestinationRoot $Storage 'ZX'
}

function Invoke-ZXExplicitOutputs([string]$Root,[string]$Storage,[string]$SourcePolicy,[string]$Existing) {
    $groups=@(Get-ZXConversionGroups (Join-Path $Root 'SRC') (Join-Path $Root 'DST') $Storage)
    $script:ExplicitEngineReady=$false
    Show-ConversionStart 'ZX Spectrum / IPF -> DSK'
    Invoke-ConversionGroupBatch $groups 'ZX' $Root $SourcePolicy $Existing {
        param($item,$source,$target,$temp,$index,$count)
        if (-not $script:ExplicitEngineReady) {
            if (-not (Ensure-HxC)) {throw 'Bundled HxC engine could not start.'}
            $item | Add-Member NoteProperty DisplayName $item.Name -Force
            if (-not (Ensure-CapsIPFReady $item)) {throw 'CAPS/IPF preflight failed; original kept.'}
            $script:ExplicitEngineReady=$true
        }
        $shortInput=Join-Path $temp 'disk.ipf';$shortOutput=Join-Path $temp 'disk.dsk'
        [IO.File]::Copy($source,$shortInput)
        $result=Invoke-HxCConversion $shortInput $shortOutput
        if (-not $result.Success) {throw ('DSK conversion failed: '+(Get-UsefulFailureSummary $result.Detail))}
        [IO.File]::Move($shortOutput,$target);Remove-SourcePolicyOwnedPath -Path $shortInput -Root $temp
    }
}


function Assert-PlainOutputParents([string]$Path, [string]$Root) {
    if (Get-Command Get-ApplicationValidationRoot -ErrorAction SilentlyContinue) {$Root=Get-ApplicationValidationRoot $Path $Root}
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
    $stamp=(Get-Date -Format 'yyyyMMdd_HHmmss_fff')+'_'+$PID+'_'+[Guid]::NewGuid().ToString('N').Substring(0,8)
    $script:LogPath = Join-Path $script:DestinationRoot ("ZX_IPF_conversion_{0}.log" -f $stamp)
    $utf8Bom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true
    $logStream=[IO.File]::Open($script:LogPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $script:LogWriter=New-Object IO.StreamWriter($logStream,$utf8Bom)
    $script:LogWriter.AutoFlush=$true
    Write-LogFile ('ZX IPF -> DSK Converter v' + $script:Version)
    Write-LogFile ('Date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-LogFile ('Source: ' + $script:SourceRoot)
    Write-LogFile ('Destination: ' + $script:DestinationRoot)
    Write-LogFile ('Output mode: ' + $script:OutputMode)
    Write-LogFile ('Source policy: ' + $SourcePolicy)
    Write-LogFile ''
}

function Write-LogFile([string]$Text) {
    $Text=ConvertTo-SafeExternalText $Text
    if (-not $script:LogPath -or $script:LogDisabled) {return}
    try {
        if (-not $script:LogWriter) {throw 'Log writer is unavailable.'}
        $script:LogWriter.WriteLine($Text)
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
    if ((Get-Command Test-ApplicationWorker -ErrorAction SilentlyContinue) -and (Test-ApplicationWorker)) {return $true}
    if (-not (Test-Path -LiteralPath $EnginePath -PathType Leaf)) { return $false }
    $dir = Split-Path -Parent $EnginePath
    foreach ($name in @('libhxcfe.dll','config.script','CAPSImg.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir $name) -PathType Leaf)) { return $false }
    }
    return $true
}

function Invoke-EngineText([string]$EnginePath, [string]$Arguments, [int]$TimeoutMs) {
    if ((Get-Command Test-ApplicationWorker -ErrorAction SilentlyContinue) -and (Test-ApplicationWorker)) {return (Invoke-ApplicationEngineText $EnginePath $Arguments $TimeoutMs)}
    Initialize-NativeTextCapture
    Initialize-NativeSandbox
    $engineDirectory=Split-Path -Parent $EnginePath
    $inputPath=$null;$outputPath=$null;$outputName=$null
    $inputArgument=[regex]::Match($Arguments,'(?i)(?:^|\s)-finput:"([^"]+)"')
    if ($inputArgument.Success) {
        $inputPath=$inputArgument.Groups[1].Value
        $outputArgument=[regex]::Match($Arguments,'(?i)(?:^|\s)-foutput:"([^"]+)"')
        if ($outputArgument.Success) {
            $outputPath=$outputArgument.Groups[1].Value
            $inputDirectory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($inputPath))
            $outputDirectory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($outputPath))
            if (-not $outputDirectory.Equals($inputDirectory,[StringComparison]::OrdinalIgnoreCase)) {
                throw 'Native HxC input and output must share the staging directory.'
            }
            $outputName='output.dsk'
        }
    }
    # Copy only the selected engine's known runtime files. The converter gets
    # read access to these copies, never to the installed application or PATH.
    $runtimeFiles=New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @('libhxcfe.dll','libusbhxcfe.dll','CAPSImg.dll','config.script',
                       'libgcc_s_dw2-1.dll','libgcc_s_seh-1.dll','libstdc++-6.dll','libwinpthread-1.dll')) {
        $candidate=Join-Path $engineDirectory $name
        if (-not [IO.File]::Exists($candidate) -and $script:EngineRuntimeDirs.ContainsKey($EnginePath)) {
            $candidate=Join-Path ([string]$script:EngineRuntimeDirs[$EnginePath]) $name
        }
        if ([IO.File]::Exists($candidate)) {$runtimeFiles.Add($candidate)}
    }
    $process=$null;$stdoutCapture=$null;$stderrCapture=$null
    try {
        # WOW64 cannot initialize this engine in LPAC. Select ordinary
        # AppContainer for the bundled x86 engine before launch; it still has
        # zero capabilities, read-only inputs, and no child-process permission.
        $useLpac=([IO.Path]::GetFileName($engineDirectory) -ine 'x86')
        $process=[OptiMiyoo.NativeSandboxJob]::Create($EnginePath,$runtimeFiles.ToArray(),$inputPath,$outputName,$useLpac)
        $nativeArguments=$Arguments
        if ($inputPath) {
            $nativeArguments=$nativeArguments.Replace(('-finput:"'+$inputPath+'"'),('-finput:"'+$process.InputRelativePath+'"'))
        }
        if ($outputPath) {
            $nativeArguments=$nativeArguments.Replace(('-foutput:"'+$outputPath+'"'),('-foutput:"'+$process.OutputName+'"'))
        }
        $process.Start($nativeArguments)
        $stdoutCapture=New-Object OptiMiyoo.NativeTextCapture($process.StandardOutput,1048576)
        $stderrCapture=New-Object OptiMiyoo.NativeTextCapture($process.StandardError,1048576)
        $timer=[Diagnostics.Stopwatch]::StartNew()
        do {
            $finished=$process.WaitForExit(125)
            # HxC uses the bounded full diagnostic text below, not progress lines.
            # Consume the queue so ordinary verbose output does not fill it.
            while ($null -ne $stdoutCapture.NextLine()) {}
            while ($null -ne $stderrCapture.NextLine()) {}
            $detail=Get-EngineLabel $EnginePath
            if ($script:CurrentZXItem) {$detail=$script:CurrentZXItem}
            Show-Stage 0 'Running isolated HxC / waiting for engine output' $detail
        } while (-not $finished -and $timer.ElapsedMilliseconds -lt $TimeoutMs -and -not $stdoutCapture.LimitExceeded -and -not $stderrCapture.LimitExceeded)
        if (-not $finished) {$process.Kill();[void]$process.WaitForExit(5000)}
        $stdoutReady=$stdoutCapture.Wait(5000);$stderrReady=$stderrCapture.Wait(5000)
        if ($stdoutCapture.LimitExceeded -or $stderrCapture.LimitExceeded) {throw 'HxC diagnostic-output limit exceeded; original kept.'}
        if (-not $stdoutReady -or -not $stderrReady) {throw 'HxC diagnostic capture did not finish; original kept.'}
        if ($stdoutCapture.Failure -or $stderrCapture.Failure) {throw 'HxC diagnostic capture failed; original kept.'}
        $stdout=$stdoutCapture.Text();$stderr=$stderrCapture.Text()
        $exitCode = if ($finished) { $process.ExitCode } else { -999 }
        if ($finished -and $exitCode -eq 0 -and $outputPath) {$process.Export($outputPath)}
        return [PSCustomObject]@{
            ExitCode = $exitCode
            Output = (($stdout + "`r`n" + $stderr).Trim())
            TimedOut = (-not $finished)
        }
    } finally {
        # Killing the Job closes every isolated process before scratch cleanup.
        try {if ($process) {Close-NativeSandboxJob $process}} finally {
            if ($stdoutCapture) {$stdoutCapture.Dispose()};if ($stderrCapture) {$stderrCapture.Dispose()}
        }
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

function Invoke-IPFEngineText([string]$EnginePath,[string]$Arguments,[string]$InputPath,[int]$TimeoutMs) {
    # HxC auto-detects several formats. Require the CAPS/IPF header before its
    # native parser runs, and pin the validated input until the child exits.
    $lease=Open-SourcePolicyReadLease $InputPath ([IO.Path]::GetDirectoryName($InputPath))
    $input=$null
    try {
        $input=[IO.File]::Open($InputPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if ($input.Length -lt 108 -or $input.Length -gt 512MB) {throw 'IPF input has an unsupported size; original kept.'}
        $header=New-Object byte[] 12
        $expected=[byte[]]@(0x43,0x41,0x50,0x53,0,0,0,12,0x1c,0xd5,0x73,0xba)
        if ($input.Read($header,0,12) -ne 12) {throw 'IPF header is truncated; original kept.'}
        for ($i=0;$i -lt 12;$i++) {
            if ($header[$i] -ne $expected[$i]) {throw 'Input does not have a valid CAPS/IPF header; original kept.'}
        }
        $input.Dispose();$input=$null
        return (Invoke-EngineText $EnginePath $Arguments $TimeoutMs)
    } finally {
        if ($input) {$input.Dispose()}
        $lease.Dispose()
    }
}

function Test-CapsIPFEngine([string]$EnginePath, [string]$InputPath) {
    $label = Get-EngineLabel $EnginePath
    $arguments = ('-verbose -finput:"{0}" -infos' -f $InputPath)
    $run = Invoke-IPFEngineText $EnginePath $arguments $InputPath 30000
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
    if ((Get-Command Test-ApplicationWorker -ErrorAction SilentlyContinue) -and (Test-ApplicationWorker)) {Write-Status 'WARN' 'Restore the complete bundled converter files, then retry.';return $null}
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
    # A user-selected runtime is used only for this run.
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
            Remove-ZXWorkPath $probeTempRoot ([IO.Path]::GetTempPath())
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
        $zip = (Open-ArchiveWithBudget -Path $ZipPath -Profile Floppy)
        $entries = New-Object 'System.Collections.Generic.List[string]'
        $extraCount=0
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrWhiteSpace($entry.Name)) {continue}
            if ([IO.Path]::GetExtension($entry.FullName) -ieq '.ipf') {$entries.Add($entry.FullName)}
            else {$extraCount++}
        }
        $hash=$null
        if ($SourcePolicy -eq 'Remove') {
            $onHash={param($done,$total) Show-PreparationProgress 'Reading source ZIP' ([IO.Path]::GetFileName($ZipPath)) $done $total 'bytes'}.GetNewClosure()
            $hash=Get-SourcePolicyHash $ZipPath $onHash
        }
        return [PSCustomObject]@{ Success=$true; Entries=$entries.ToArray(); OtherFiles=$extraCount; Hash=$hash; Error='' }
    } catch {
        return [PSCustomObject]@{ Success=$false; Entries=@(); Error=$_.Exception.Message }
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

function Get-ConversionItems {
    $script:ScanFailures = New-Object 'System.Collections.Generic.List[object]'
    $script:UntouchedSources = New-Object 'System.Collections.Generic.List[object]'
    # Appending to PowerShell arrays recopies every prior job. Grow lists instead.
    $results = New-Object 'System.Collections.Generic.List[object]'
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
                $results.Add([PSCustomObject]@{
                    Type='Loose'; InputPath=$file.FullName; EntryName=$null; SourceBlockReason=''; SourceHash=$null
                    RelativeOutput=[IO.Path]::ChangeExtension($relative, '.dsk')
                    DisplayName=$relative
                })
                continue
            }

            $zipResult = Get-ZipIPFEntryNames $file.FullName
            if (-not $zipResult.Success) {
                $script:ScanFailures.Add([PSCustomObject]@{ DisplayName=$relative; InputPath=$file.FullName; Error=$zipResult.Error })
                continue
            }
            $entries = @($zipResult.Entries)
            if ($entries.Count -eq 0) {
                $script:UntouchedSources.Add([pscustomobject]@{InputPath=$file.FullName; Reason='ZIP has no IPF images; original kept.'})
                continue
            }
            $sourceBlockReason=''
            if ($zipResult.OtherFiles -gt 0) {$sourceBlockReason='ZIP includes files that are not converted to DSK; original kept to preserve them.'}

            if ($entries.Count -eq 1) {
                $results.Add([PSCustomObject]@{
                    Type='Zip'; InputPath=$file.FullName; EntryName=$entries[0]; SourceBlockReason=$sourceBlockReason; SourceHash=$zipResult.Hash
                    RelativeOutput=[IO.Path]::ChangeExtension($relative, '.dsk')
                    DisplayName=($relative + ' :: ' + $entries[0])
                })
            } else {
                $relativeDir = Split-Path -Parent $relative
                if ($relativeDir -eq '.') { $relativeDir = '' }
                $archiveFolder = [IO.Path]::GetFileNameWithoutExtension($file.Name)
                $base = Join-RelativePath $relativeDir $archiveFolder
                foreach ($entry in $entries) {
                    $safeEntry = Get-SafeZipRelativePath $entry
                    $results.Add([PSCustomObject]@{
                        Type='Zip'; InputPath=$file.FullName; EntryName=$entry; SourceBlockReason=$sourceBlockReason; SourceHash=$zipResult.Hash
                        RelativeOutput=(Join-RelativePath $base ([IO.Path]::ChangeExtension($safeEntry, '.dsk')))
                        DisplayName=($relative + ' :: ' + $entry)
                    })
                }
            }
        } finally {
            $checked++; Show-PreparationProgress 'Reading IPF inputs' $file.Name $checked $sourceFiles.Count 'inputs'
        }
    }
    return $results.ToArray()
}

function Get-FinalRelativeOutput([string]$RelativeDsk) {
    if ($script:OutputMode -eq 'ZipDSK') {
        return [IO.Path]::ChangeExtension($RelativeDsk, '.zip')
    }
    return $RelativeDsk
}

function Get-OutputCollisions([object[]]$Items) {
    $seen = @{}
    $collisions = New-Object 'System.Collections.Generic.List[object]'; $checked=0
    Show-PreparationProgress 'Checking output path conflicts' 'Checking converted-image destinations.' 0 $Items.Count 'images'
    foreach ($item in $Items) {
        $key = Get-FinalRelativeOutput ([string]$item.RelativeOutput)
        if ($seen.ContainsKey($key)) {
            $collisions.Add([PSCustomObject]@{ RelativeOutput=$key; First=[string]$seen[$key]; Second=[string]$item.DisplayName })
        } else {
            $seen[$key] = [string]$item.DisplayName
        }
        $checked++; Show-PreparationProgress 'Checking output path conflicts' $item.DisplayName $checked $Items.Count 'images'
    }
    return $collisions.ToArray()
}

function Remove-ZXWorkPath([string]$Path,[string]$Root) {
    # A failed verification cannot identify a replacement file safely. Keep
    # anything returned to staging during rollback for the user to recover.
    if ($Path -and $Path -eq $script:PreservedZXWorkPath) {return}
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {return}
    try {Remove-SourcePolicyOwnedPath -Path $Path -Root $Root}
    catch {
        Write-Diagnostic ('Temporary output left in place: '+$Path+' / '+$_.Exception.Message)
        Write-Status 'WARN' ('Temporary output left in place: '+$Path)
    }
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
        Initialize-ArchiveLimits
        if ($input.Length -gt 512MB) {throw 'IPF input exceeds the supported 512 MiB size limit; original kept.'}
        [void][OptiMiyoo.ArchiveLimits]::CopyBounded($input,$output,512MB)
        $output.Flush()
        $complete=$true
        return [PSCustomObject]@{ Path=$tempFile; TempRoot=$tempRoot }
    } finally {
        if ($output) { $output.Dispose() }
        if ($input) { $input.Dispose() }
        if (-not $complete -and (Test-Path -LiteralPath $tempRoot)) {
            Remove-ZXWorkPath $tempRoot ([IO.Path]::GetTempPath())
        }
    }
}


function Expand-OneZipIPF([string]$ZipPath,[string]$EntryName) {
    $tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('ZX_IPF_'+[Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($tempRoot)
    $zip=$null;$complete=$false
    try {
        $zip=Open-ArchiveWithBudget -Path $ZipPath -Profile Floppy
        $matches=@();for($i=0;$i -lt $zip.Entries.Count;$i++){if($zip.Entries[$i].FullName -ceq $EntryName){$matches+=,$i}}
        if($matches.Count -ne 1){throw 'Missing or duplicate IPF entry in ZIP.'}
        Show-Stage 0 'Preparing IPF from ZIP in sandbox' $EntryName 0
        $tempFile=Join-Path $tempRoot 'disk.ipf'
        $null=Invoke-ArchiveSandbox -ZipPath $ZipPath -Archive $zip -Profile Floppy -Operation File -EntryIndex $matches[0] -MaximumBytes 512MB -Destination $tempFile -Progress {param($index,$count,$done,$length) Show-Stage 0 'Reading ZIP payload in sandbox' 'Checking decompressed disk bytes' (100*$done/[Math]::Max(1,$length))}
        $complete=$true;return [pscustomobject]@{Path=$tempFile;TempRoot=$tempRoot}
    } finally {
        if($zip){$zip.Dispose()}
        if(-not $complete -and (Test-Path -LiteralPath $tempRoot)){Remove-ZXWorkPath $tempRoot ([IO.Path]::GetTempPath())}
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
        if ($Length -lt 256 -or $Length -gt 64MB) {return $false}
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

function Test-ZipDskPackage([string]$ZipPath,[string]$ExpectedEntryName) {
    $zip=$null;$stream=$null;$tempRoot=$null
    try {
        if(-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)){return $false}
        $zip=Open-ArchiveWithBudget -Path $ZipPath -Profile Floppy
        $entries=@($zip.Entries | Where-Object {-not [string]::IsNullOrWhiteSpace($_.Name)})
        if($entries.Count -ne 1){return $false}
        $entry=$entries[0]
        if($entry.Name -ne $ExpectedEntryName -or [IO.Path]::GetExtension($entry.Name) -ine '.dsk'){return $false}
        $tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('ZX_CHECK_'+[Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($tempRoot)
        $tempFile=Join-Path $tempRoot 'disk.dsk'
        $null=Invoke-ArchiveSandbox -ZipPath $ZipPath -Archive $zip -Profile Floppy -Operation File -EntryIndex $zip.Entries.IndexOf($entry) -MaximumBytes 512MB -Destination $tempFile -Progress {param($index,$count,$done,$length) Show-Stage 0 'Reading ZIP payload in sandbox' 'Checking decompressed disk bytes' (100*$done/[Math]::Max(1,$length))}
        $stream=[IO.File]::OpenRead($tempFile)
        return (Test-DskStream $stream $entry.Length)
    } catch {return $false}
    finally {
        if($stream){$stream.Dispose()};if($zip){$zip.Dispose()}
        if($tempRoot -and (Test-Path -LiteralPath $tempRoot)){Remove-ZXWorkPath $tempRoot ([IO.Path]::GetTempPath())}
    }
}

function New-DskZipPackage([string]$DskPath, [string]$ZipPath, [string]$EntryName) {
    if (-not (Test-DSK $DskPath)) { throw 'Refusing to ZIP output because DSK validation failed.' }
    $zipStream=$null; $archive=$null; $source=$null; $entryStream=$null; $created=$false
    try {
        # Reserve a new file exclusively. An unexpectedly occupied staging name
        # belongs to somebody else and must never be deleted or overwritten.
        $zipStream=[IO.File]::Open($ZipPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
        $created=$true
        $archive=New-Object IO.Compression.ZipArchive($zipStream,[IO.Compression.ZipArchiveMode]::Create,$true)
        $entry=$archive.CreateEntry($EntryName,[IO.Compression.CompressionLevel]::Optimal)
        $source=[IO.File]::OpenRead($DskPath); $entryStream=$entry.Open()
        $source.CopyTo($entryStream)
        $entryStream.Dispose(); $entryStream=$null; $source.Dispose(); $source=$null
        $archive.Dispose(); $archive=$null; $zipStream.Flush()
        $zipStream.Dispose(); $zipStream=$null
        if (-not (Test-ZipDskPackage $ZipPath $EntryName)) {throw 'ZIP package validation failed.'}
    } catch {
        if ($entryStream) {$entryStream.Dispose();$entryStream=$null}
        if ($source) {$source.Dispose();$source=$null}
        if ($archive) {$archive.Dispose();$archive=$null}
        if ($zipStream) {$zipStream.Dispose();$zipStream=$null}
        if ($created) {Remove-ZXWorkPath $ZipPath ([IO.Path]::GetDirectoryName($ZipPath))}
        throw
    } finally {
        if ($entryStream) {$entryStream.Dispose()}; if ($source) {$source.Dispose()}
        if ($archive) {$archive.Dispose()}; if ($zipStream) {$zipStream.Dispose()}
    }
}

function Commit-FileSafely([string]$WorkPath, [string]$FinalPath, [string]$Kind) {
    $backupPath = $null
    $installed=$false
    $parentLocks=New-Object 'System.Collections.Generic.List[System.IDisposable]'
    try {
        $parents=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [void]$parents.Add([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($WorkPath)))
        [void]$parents.Add([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($FinalPath)))
        foreach ($parent in $parents) {$parentLocks.Add((Open-SourcePolicyDirectoryLease -Path $parent))}
        $hadPrevious=Test-Path -LiteralPath $FinalPath
        if ($hadPrevious) {
            $old=Get-Item -LiteralPath $FinalPath -Force
            if ($old.PSIsContainer -or ($old.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Destination is not a regular file; output left alone.'}
        }
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
            try {Remove-SourcePolicyOwnedPath -Path $backupPath -Root ([IO.Path]::GetDirectoryName($backupPath))}
            catch {Write-Status 'WARN' ('Previous output backup remains at: '+$backupPath)}
        }
        return $expectedHash
    } catch {
        $commitError = $_.Exception.Message
        if ($backupPath -and (Test-Path -LiteralPath $backupPath)) {
            try {
                if (Test-Path -LiteralPath $FinalPath) {
                    if (-not $installed) {throw 'A different file appeared at the destination; it was left alone.'}
                    # Return only an installed output to staging. Never delete a
                    # destination merely because an attempted install failed.
                    $script:PreservedZXWorkPath=$WorkPath
                    [IO.File]::Move($FinalPath,$WorkPath)
                }
                [IO.File]::Move($backupPath, $FinalPath)
            } catch {
                throw ("New {0} install failed and old output restore also failed. Backup kept at: {1}. Commit: {2}. Restore: {3}" -f $Kind, $backupPath, $commitError, $_.Exception.Message)
            }
            throw ("New {0} install failed; previous output was restored. Unverified output kept at: {1}. {2}" -f $Kind, $WorkPath, $commitError)
        }
        if ($installed -and (Test-Path -LiteralPath $FinalPath)) {
            $script:PreservedZXWorkPath=$WorkPath
            try {[IO.File]::Move($FinalPath,$WorkPath)}
            catch {throw ("New {0} install failed and incomplete output could not be returned to staging: {1}. Commit: {2}. Cleanup: {3}" -f $Kind,$FinalPath,$commitError,$_.Exception.Message)}
        }
        throw ("New {0} install failed; no previous destination file was changed. Unverified output kept at: {1}. {2}" -f $Kind, $WorkPath, $commitError)
    }
    } finally {foreach ($parentLock in $parentLocks) {$parentLock.Dispose()}}
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
    if (Test-Path -LiteralPath $OutputPath) {Remove-SourcePolicyOwnedPath -Path $OutputPath -Root ([IO.Path]::GetDirectoryName($InputPath))}
    $arguments = ('-verbose -finput:"{0}" -conv:AMSTRADCPC_DSK -foutput:"{1}"' -f $InputPath, $OutputPath)
    $label = Get-EngineLabel $EnginePath
    $run = Invoke-IPFEngineText $EnginePath $arguments $InputPath 120000
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
    Write-Diagnostic '--- HxC stdout/stderr (bounded capture) ---'
    Write-Diagnostic $detail
    Write-Diagnostic '===== END CONVERSION ATTEMPT ====='

    if ($run.TimedOut) {
        return [PSCustomObject]@{ Success=$false; Detail='HxC timed out after 120 seconds.'; Engine=$label; NonZeroExit=$false }
    }
    if ($valid) {
        return [PSCustomObject]@{ Success=$true; Detail=''; Engine=$label; NonZeroExit=($run.ExitCode -ne 0) }
    }

    $infoArguments = ('-verbose -finput:"{0}" -infos' -f $InputPath)
    $info = Invoke-IPFEngineText $EnginePath $infoArguments $InputPath 30000
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
    $warnings=@('Skipped originals stay in SRC.')
    $choices=@(Get-OverwriteChoiceRows)
    $invalid=$false
    while ($true) {
        $shownWarnings=$warnings
        if ($invalid) {$shownWarnings+='Please enter Y, N, A or S.'}
        $choice=ConvertFrom-OverwriteAnswer (Read-OverwriteChoice 'ZX Spectrum / existing output' @($RelativeOutput) $shownWarnings $choices (Get-OverwriteInputPrompt))
        if ($choice) {return $choice}
        $invalid=$true
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
    if (-not (Test-ApplicationWorker)) {
        Write-Host ('  Source policy: '+$SourcePolicy.ToUpperInvariant())
        Write-Host ('  Originals in this batch: {0} removed | {1} kept | {2} removal failures' -f $sourceSummary.Removed,$sourceSummary.Kept,$sourceSummary.Failed)
    }
    Write-LogFile ('Originals: {0} removed; {1} kept; {2} removal failures' -f $sourceSummary.Removed,$sourceSummary.Kept,$sourceSummary.Failed)
    Write-Host '  +-----------------------------------------------------+' -ForegroundColor Cyan
    if (-not (Test-ApplicationWorker)) {Write-Host ('  Log: ' + $script:LogPath) -ForegroundColor DarkGray} else {Write-Host '  Waiting for independent verification and publication.'}
    Write-Host ''
    Write-LogFile ''
    Write-LogFile ('Converted: ' + $script:Converted)
    Write-LogFile ('Skipped: ' + $script:Skipped)
    Write-LogFile ('Failed: ' + $script:Failed)
    Write-LogFile ('Total: ' + $script:Total)
}

function Main {
    Write-Banner
    if ($Storage) {Start-Log;return (Invoke-ZXExplicitOutputs $Root $Storage $SourcePolicy $Existing)}
    if ($Format -eq 'Ask') {throw 'Output choice is missing. Start OptiMiyoo again and choose ZIPs, folders or loose files.'}
    $script:OutputMode=$Format
    $script:SourcePlan=New-SourcePolicyPlan $script:SourceRoot $SourcePolicy
    $script:Clock.Restart()
    Start-Log
    if (Test-ApplicationWorker) {Write-Status 'INFO' 'Working on staged copies. Originals are handled after verification.'}
    else {Write-Status 'INFO' ('Source policy: '+$SourcePolicy.ToUpperInvariant()+'. Skipped/failed inputs stay in SRC.')}
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
        Set-ApplicationCurrentJob $item.DisplayName
        $index++
        $tempRoot=$null; $workOutPath=$null; $workZipPath=$null; $sourceLease=$null
        $script:PreservedZXWorkPath=$null
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
                    if (Test-Path -LiteralPath $workOutPath) { Remove-ZXWorkPath $workOutPath $script:DestinationRoot }
                } else {
                    Show-Stage 0 'Verifying and installing DSK output' $relativeOutput
                    $outputHash=Commit-DskSafely $workOutPath $outPath
                }
                Complete-SourcePolicyJob $script:SourcePlan $item.SourceId $sourceHashes @([pscustomobject]@{Destination=$outPath;Folder=$false;Hash=$outputHash})
                Complete-ApplicationCurrentJob
                $script:Converted++
                $note = ''
                if ($result.PSObject.Properties['UsedFallback'] -and $result.UsedFallback) { $note = ' (fallback engine succeeded)' }
                elseif ($result.NonZeroExit) { $note = ' (valid DSK; HxC returned a warning exit code)' }
                Write-Status 'OK' ($item.DisplayName + ' -> ' + $relativeOutput + $note)
            } else {
                $script:Failed++
                if (Test-Path -LiteralPath $workOutPath) { Remove-ZXWorkPath $workOutPath $script:DestinationRoot }
                Write-Status 'FAIL' ($item.DisplayName + ' | ' + (Get-UsefulFailureSummary $result.Detail))
            }
        } catch {
            $script:Failed++
            if ($workOutPath -and (Test-Path -LiteralPath $workOutPath)) { Remove-ZXWorkPath $workOutPath $script:DestinationRoot }
            if ($workZipPath -and (Test-Path -LiteralPath $workZipPath)) { Remove-ZXWorkPath $workZipPath $script:DestinationRoot }
            Write-Status 'FAIL' ($item.DisplayName + ' | processing error: ' + ($_.Exception.Message -replace '[\r\n]+', ' '))
            Write-Diagnostic ('PROCESSING EXCEPTION: ' + ($_ | Out-String))
        } finally {
            if ($sourceLease) {$sourceLease.Dispose()}
            if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
                Remove-ZXWorkPath $tempRoot ([IO.Path]::GetTempPath())
            }
            if ($workOutPath -and (Test-Path -LiteralPath $workOutPath)) {
                Remove-ZXWorkPath $workOutPath $script:DestinationRoot
            }
            if ($workZipPath -and (Test-Path -LiteralPath $workZipPath)) {
                Remove-ZXWorkPath $workZipPath $script:DestinationRoot
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
} finally {if ($script:LogWriter) {$script:LogWriter.Dispose()};Restore-Display}
