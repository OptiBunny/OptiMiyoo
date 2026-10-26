#requires -Version 5.1
[CmdletBinding()]
param([string]$Root,
      [ValidateSet('Zip','Loose','Folders')][string]$Storage,
      [ValidateSet('Ask','Overwrite','Skip')][string]$Existing='Ask',
      [ValidateSet('Keep','Remove')][string]$SourcePolicy='Keep',
      [switch]$NoAnimation,[switch]$NoColor,
      [ValidateSet('CRT','Smooth')][string]$DisplayEffect='CRT')
# ZX conversion uses the shared output layouts and source policy.
# Windows PowerShell 5.1 compatible. No GUI. Keep originals is the default.

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'application_entry.ps1')
if (-not (Test-ApplicationWorker)) {
    exit (Enter-ApplicationHost -ApplicationRoot (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -Entry ZX -Arguments $PSBoundParameters)
}
$ErrorActionPreference = 'Stop'

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
$script:Skipped = 0
$script:Failed = 0
$script:Total = 0
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
Initialize-Display
$script:UiSystem='ZXS / IPF -> DSK'
function Write-Log([string]$Message) {Write-LogFile $Message}
function Format-Duration([double]$Seconds) {
    $t=[TimeSpan]::FromSeconds([Math]::Max(0,$Seconds))
    return ('{0:00}:{1:00}:{2:00}' -f [Math]::Floor($t.TotalHours),$t.Minutes,$t.Seconds)
}

function Invoke-ZXExplicitOutputs([string]$Root,[string]$Storage,[string]$SourcePolicy,[string]$Existing) {
    $groups=@(Get-ConversionSourceGroups (Join-Path $Root 'SRC') (Join-Path $Root 'DST') $Storage 'ZX')
    $script:ExplicitEngineReady=$false
    Show-ConversionStart 'ZX Spectrum / IPF -> DSK'
    Invoke-ConversionGroupBatch $groups $Root $SourcePolicy $Existing {
        param($item,$source,$target,$temp,$index,$count)
        if ($item.Converter -eq 'HxC') {
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
        } else {
            [IO.File]::Copy($source,$target)
            if ($item.Media -and -not (Test-DSK $target)) {throw 'Existing DSK structure is invalid; original kept.'}
        }
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
    Write-Event 'MODE' 'OptiMiyoo / ZX Spectrum / IPF -> DSK'
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
    Write-LogFile ('OptiMiyoo v' + $script:AppVersion + ' / ZX Spectrum / IPF -> DSK')
    Write-LogFile ('Date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-LogFile ('Source: ' + $script:SourceRoot)
    Write-LogFile ('Destination: ' + $script:DestinationRoot)
    Write-LogFile ('Output storage: ' + $Storage)
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
        Write-Notice 'WARNING' 'Could not write the temporary log. Conversion will continue; review the final results.'
    }
}

function Write-Status([string]$Kind,[string]$Text) {
    $label=$Kind
    switch ($Kind) {'OK' {$label='READY'} 'FAIL' {$label='FAILED'} 'WARN' {$label='NOTE'}}
    $script:Processed=$script:Ok+$script:Skipped+$script:Failed
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
    foreach ($name in @('libhxcfe.dll','libusbhxcfe.dll','config.script','CAPSImg.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir $name) -PathType Leaf)) { return $false }
    }
    return $true
}

function Invoke-EngineText([string]$EnginePath, [string]$Arguments, [int]$TimeoutMs) {
    if ((Get-Command Test-ApplicationWorker -ErrorAction SilentlyContinue) -and (Test-ApplicationWorker)) {return (Invoke-ApplicationEngineText $EnginePath $Arguments)}
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
                       'libgcc_s_dw2-1.dll','libstdc++-6.dll','libwinpthread-1.dll')) {
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
            Show-Stage 'Running isolated HxC / waiting for engine output' $detail
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
    if ($arch -eq 'x86') { return @('libstdc++-6.dll', 'libgcc_s_dw2-1.dll', 'libwinpthread-1.dll') }
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
        return [PSCustomObject]@{ Success=$false; CapsLoadFailure=$false; Detail=($label + ' could not load the IPF image.') }
    }
    return [PSCustomObject]@{ Success=$false; CapsLoadFailure=$false; Detail=($label + ' did not recognize the probe file as an IPF image.') }
}

function Ensure-CapsIPFReady($ProbeItem) {
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
            Write-Status 'WARN' 'CAPSImg.dll or one of its dependencies could not load.'
            Write-Status 'WARN' 'Restore the complete bundled converter files, then retry.'
        }

        if ($working.Count -eq 0) {
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

function Remove-ZXWorkPath([string]$Path,[string]$Root) {
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
        if ($input.Length -gt 512MB) {throw 'Disk image exceeds the supported 512 MiB size limit; original kept.'}
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
        if($matches.Count -ne 1){throw 'Missing or duplicate disk entry in ZIP.'}
        Show-Stage 'Preparing disk from ZIP in sandbox' $EntryName 0
        $tempFile=Join-Path $tempRoot 'disk.ipf'
        $null=Invoke-ArchiveSandbox -ZipPath $ZipPath -Archive $zip -Profile Floppy -Operation File -EntryIndex $matches[0] -MaximumBytes 512MB -Destination $tempFile -Progress {param($index,$count,$done,$length) Show-Stage 'Reading ZIP payload in sandbox' 'Checking decompressed disk bytes' (100*$done/[Math]::Max(1,$length))}
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

function Invoke-HxCOnce([string]$EnginePath, [string]$InputPath, [string]$OutputPath) {
    if (Test-Path -LiteralPath $OutputPath) {Remove-SourcePolicyOwnedPath -Path $OutputPath -Root ([IO.Path]::GetDirectoryName($InputPath))}
    $arguments = ('-verbose -finput:"{0}" -conv:AMSTRADCPC_DSK -foutput:"{1}"' -f $InputPath, $OutputPath)
    $label = Get-EngineLabel $EnginePath
    $run = Invoke-IPFEngineText $EnginePath $arguments $InputPath 120000
    Show-Stage 'Verifying DSK output' ([IO.Path]::GetFileName($InputPath))
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
        return [PSCustomObject]@{ Success=$false; Detail='HxC timed out after 120 seconds.'; Engine=$label }
    }
    if ($valid) {
        return [PSCustomObject]@{ Success=$true; Detail=''; Engine=$label }
    }

    $infoArguments = ('-verbose -finput:"{0}" -infos' -f $InputPath)
    $info = Invoke-IPFEngineText $EnginePath $infoArguments $InputPath 30000
    Write-Diagnostic ('===== INPUT INFO AFTER FAILURE: ' + $label + ' =====')
    Write-Diagnostic ('Arguments: ' + $infoArguments)
    Write-Diagnostic ('Exit code: ' + $info.ExitCode)
    Write-Diagnostic $info.Output
    Write-Diagnostic '===== END INPUT INFO ====='
    if (-not [string]::IsNullOrWhiteSpace($info.Output)) { $detail += "`r`n--- input-info ---`r`n" + $info.Output }
    return [PSCustomObject]@{ Success=$false; Detail=$detail; Engine=$label }
}

function Invoke-HxCAttempt([string]$EnginePath,[string]$InputPath,[string]$OutputPath) {
    try {return (Invoke-HxCOnce $EnginePath $InputPath $OutputPath)}
    catch {
        $detail='Engine execution failed: '+$_.Exception.Message
        Write-Diagnostic ((Get-EngineLabel $EnginePath)+' | '+$detail)
        return [pscustomobject]@{Success=$false;Detail=$detail;Engine=(Get-EngineLabel $EnginePath)}
    }
}

function Invoke-HxCConversion([string]$InputPath, [string]$OutputPath) {
    $first = Invoke-HxCAttempt $script:HxCExe $InputPath $OutputPath
    if ($first.Success) { return $first }
    if ($script:HxCFallback) {
        Write-Status 'WARN' ('Primary engine failed; retrying with ' + (Get-EngineLabel $script:HxCFallback) + '.')
        $second = Invoke-HxCAttempt $script:HxCFallback $InputPath $OutputPath
        if ($second.Success) {
            return $second
        }
        return [PSCustomObject]@{
            Success=$false
            Detail=("PRIMARY ({0}):`r`n{1}`r`n`r`nFALLBACK ({2}):`r`n{3}" -f $first.Engine, $first.Detail, $second.Engine, $second.Detail)
            Engine=($first.Engine + ' + ' + $second.Engine)
        }
    }
    return $first
}

function Get-UsefulFailureSummary([string]$Detail) {
    if ([string]::IsNullOrWhiteSpace($Detail)) { return 'HxC returned no diagnostic text; original kept.' }
    if ($Detail -match "(?i)Can't load CAPSImg\.dll|No Caps lib available|Failed to load CAPS library") {
        return 'CAPSImg.dll or one of its dependencies could not load. Restore the complete bundled converter files, then retry.'
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
    if ($lines.Count -eq 0) { return 'HxC failed without a usable diagnostic message; original kept.' }
    $start = [Math]::Max(0, $lines.Count - 3)
    $summary = [string]::Join(' | ', @($lines[$start..($lines.Count - 1)]))
    if ($summary.Length -gt 500) { $summary = $summary.Substring(0, 500) + '...' }
    return $summary
}

function Main {
    if (-not $Storage) {throw 'Output choice is missing. Choose ZIPs, folders or loose files.'}
    Write-Banner
    Start-Log
    return (Invoke-ZXExplicitOutputs $Root $Storage $SourcePolicy $Existing)
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
        $script:Failed++
        Write-Status 'FAIL' ('Fatal error: ' + $_.Exception.Message)
        Write-Diagnostic ('FATAL EXCEPTION: ' + ($_ | Out-String))
        Show-ClosingPanel
    } catch {}
    exit 99
} finally {if ($script:LogWriter) {$script:LogWriter.Dispose()};Restore-Display}
