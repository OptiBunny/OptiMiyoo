#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Root,
    [ValidateSet('Zip','Loose','Folders')][string]$Storage,
    [ValidateSet('Keep','Remove')][string]$SourcePolicy='Keep',
    [ValidateSet('Ask','Overwrite','Skip')][string]$Existing='Ask',
    [switch]$NoAnimation,
    [switch]$NoColor,
    [ValidateSet('CRT','Smooth')][string]$DisplayEffect='CRT'
)

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'application_entry.ps1')
if (-not (Test-ApplicationWorker)) {
    exit (Enter-ApplicationHost -ApplicationRoot (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -Entry C64 -Arguments $PSBoundParameters)
}
$script:AppVersion = '0.0.9'

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$NibConv = Join-Path $ScriptDir 'tools/nibconv.exe'
. (Join-Path $ScriptDir 'source_policy.ps1')
. (Join-Path $ScriptDir 'overwrite_prompt.ps1')
. (Join-Path $ScriptDir 'media_validation.ps1')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

. (Join-Path $ScriptDir 'archive_limits.ps1')
. (Join-Path $ScriptDir 'zip_integrity.ps1')
. (Join-Path $ScriptDir 'native_process.ps1')
. (Join-Path $ScriptDir 'archive_sandbox.ps1')
. (Join-Path $ScriptDir 'conversion_layout.ps1')
Initialize-NativeTextCapture

function Get-C64ConversionGroups([string]$SourceRoot,[string]$DestinationRoot,[string]$Storage) {
    Get-ConversionSourceGroups $SourceRoot $DestinationRoot $Storage 'C64'
}

function Invoke-C64ExplicitOutputs([string]$Root,[string]$Storage,[string]$SourcePolicy,[string]$Existing) {
    $groups=@(Get-C64ConversionGroups (Join-Path $Root 'SRC') (Join-Path $Root 'DST') $Storage)
    Show-ConversionStart 'Commodore 64 / NIB -> G64'
    Invoke-ConversionGroupBatch $groups 'C64' $Root $SourcePolicy $Existing {
        param($item,$source,$target,$temp,$index,$count)
        if ($item.Converter -eq 'Nib') {
            Assert-NibSource $source
            $shortInput=Join-Path $temp ('input'+[IO.Path]::GetExtension($source));$shortOutput=Join-Path $temp 'output.g64'
            [IO.File]::Copy($source,$shortInput)
            $lease=$null
            try {$lease=Open-SourcePolicyReadLease $shortInput $temp;Invoke-NibConversion $shortInput $shortOutput $index $count $item.Name}
            finally {if ($lease) {$lease.Dispose()}}
            [IO.File]::Move($shortOutput,$target);Remove-SourcePolicyOwnedPath -Path $shortInput -Root $temp
        } else {[IO.File]::Copy($source,$target)}
        if ($item.Media) {Assert-G64 $target}
    }
}

function Format-Duration([double]$Seconds) {
    if ($Seconds -lt 0 -or [double]::IsInfinity($Seconds)) { return 'calculating...' }
    $span = [TimeSpan]::FromSeconds([Math]::Max(0, $Seconds))
    return ('{0:00}:{1:00}:{2:00}' -f [Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds)
}

# Converter-specific validation and progress helpers.

function Show-Progress {
    param([double]$Fraction,[string]$Stage,[string]$Detail,[int]$StagePercent=-1,[switch]$Force)
    $script:UiGame=$script:ZipName
    # Only byte measurements or a completed stage are shown as a percentage.
    Show-Stage $Fraction $Stage $Detail $StagePercent
    if ($Force) {Draw-DisplayPanel -Force}
}

function Write-Log([string]$Message) {
    $Message=ConvertTo-SafeExternalText $Message
    if ($script:Log) {
        try { $script:Log.WriteLine(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message)) }
        catch {
            $script:ReportProblem=$true
            Write-Notice 'WARNING' 'Log could not be written; conversion will continue and the run will report an error.'
            try { $script:Log.Dispose() } catch { }
            $script:Log = $null
        }
    }
}

function Assert-G64([string]$Path) {
    # Some nibconv failures return exit code zero: validate actual output too.
    $stream = [IO.File]::OpenRead($Path)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -gt 64MB) {throw 'G64 output exceeds the supported image-size limit.'}
        if ($stream.Length -lt 12 -or [Text.Encoding]::ASCII.GetString($reader.ReadBytes(8)) -ne 'GCR-1541') { throw 'nibconv did not produce a G64 image.' }
        if ($reader.ReadByte() -ne 0) { throw 'Unsupported G64 version.' }
        $tracks = [int]$reader.ReadByte()
        $maxLength = [int]$reader.ReadUInt16()
        $dataStart = 12 + 8 * $tracks
        if ($tracks -eq 0 -or $stream.Length -lt $dataStart) { throw 'Truncated G64 tables.' }
        $offsets = @(); $speeds = @()
        for ($i = 0; $i -lt $tracks; $i++) { $offsets += $reader.ReadUInt32() }
        for ($i = 0; $i -lt $tracks; $i++) { $speeds += $reader.ReadUInt32() }
        for ($i = 0; $i -lt $tracks; $i++) {
            if ($offsets[$i] -eq 0) { continue }
            if ($offsets[$i] -lt $dataStart -or ($offsets[$i] + 2) -gt $stream.Length) { throw 'Invalid G64 track offset.' }
            $stream.Position = $offsets[$i]
            $length = [int]$reader.ReadUInt16()
            if ($length -gt $maxLength -or ($offsets[$i] + 2 + $length) -gt $stream.Length) { throw 'Truncated G64 track.' }
            if ($speeds[$i] -gt 3 -and ($speeds[$i] -lt $dataStart -or
                    ($speeds[$i] + [Math]::Ceiling($length / 4.0)) -gt $stream.Length)) { throw 'Invalid G64 speed map.' }
        }
    } finally { $reader.Dispose() }
}

function Invoke-NibConversion([string]$InputPath, [string]$OutputPath, [int]$Index, [int]$Count, [string]$DisplayName) {
    $capture = New-NativeNibCapture $NibConv $InputPath $OutputPath
    $phase = 'Starting'; [double]$fraction = 0; $trackDetail = 'waiting for nibconv output'
    $conversionProblem = $null
    $diskClock = [Diagnostics.Stopwatch]::StartNew()
    try {
        do {
            $finished = $capture.Child.HasExited
            if ($diskClock.Elapsed.TotalSeconds -gt 120) {throw 'nibconv exceeded its 120-second time limit. Original kept.'}
            if ($capture.LimitExceeded) {throw 'nibconv diagnostic-output limit exceeded. Original kept.'}
            if ($finished -and -not $capture.WaitOutput(5000)) {throw 'nibconv diagnostic capture did not complete. Original kept.'}
            if ($capture.CaptureFailed) {throw 'nibconv diagnostic capture failed. Original kept.'}
            while ($null -ne ($line = $capture.NextLine())) {
                Write-Log ('nibconv: ' + $line)
                if ($line -match 'Not valid NIB data') { $conversionProblem = $line.Trim() }
                if ($line -match 'Aligning tracks') { $phase = 'Aligning'; $fraction = [Math]::Max($fraction, 0.02) }
                elseif ($line -match 'Searching for fat tracks') { $phase = 'Checking tracks'; $fraction = [Math]::Max($fraction, 0.75) }
                elseif ($line -match 'Writing G64 file') { $phase = 'Writing G64'; $fraction = [Math]::Max($fraction, 0.80) }
                elseif ($line -match '^\s*(\d+\.\d+)\s*:') {
                    $track = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
                    $trackDetail = 'track ' + $Matches[1]
                    if ($phase -eq 'Aligning') { $fraction = [Math]::Max($fraction, 0.02 + 0.70 * [Math]::Min(1, $track / 42)) }
                    elseif ($phase -eq 'Writing G64') { $fraction = [Math]::Max($fraction, 0.80 + 0.18 * [Math]::Min(1, $track / 42.5)) }
                }
            }
            $detail = ('{0} | {1}, {2} | Disk elapsed {3}' -f $DisplayName, $phase, $trackDetail,
                (Format-Duration $diskClock.Elapsed.TotalSeconds))
            Show-Progress (0.15 + 0.65 * (($Index + $fraction) / $Count)) `
                ('Converting disk {0}/{1}' -f ($Index + 1), $Count) `
                $detail -1 -Force
            if (-not $finished) { Start-Sleep -Milliseconds 125 }
        } while (-not $finished)
        if ($capture.LimitExceeded) {throw 'nibconv diagnostic-output limit exceeded. Original kept.'}
        if ($capture.Child.ExitCode -ne 0) { throw "nibconv exit code $($capture.Child.ExitCode)." }
        if ($conversionProblem) { throw $conversionProblem }
        $capture.Export()
        if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { throw 'nibconv produced no G64 output. See the log for its messages.' }
        Assert-G64 $OutputPath
        Show-Progress (0.15 + 0.65 * (($Index + 1) / $Count)) 'Converting disk images' `
            ('Disk {0}/{1} complete: {2}' -f ($Index + 1), $Count, $DisplayName) 100 -Force
    } finally { $capture.Dispose() }
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

$script:Log=$null; $script:ReportProblem=$false; $exitCode=0
$script:Clock=[Diagnostics.Stopwatch]::StartNew()
$script:Total=0; $script:Processed=0; $script:Ok=0; $script:Skipped=0; $script:Failed=0
. (Join-Path $ScriptDir 'display.ps1')
try {
    if (-not $Storage) {throw 'Output choice is missing. Choose ZIPs, folders or loose files.'}
    if ([string]::IsNullOrWhiteSpace($Root)) {$Root=Split-Path -Parent $ScriptDir}
    $Root=(Resolve-Path -LiteralPath $Root).ProviderPath
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {throw 'Root must be the folder containing SRC and DST.'}
    $sourceRoot=Join-Path $Root 'SRC';$destinationRoot=Join-Path $Root 'DST'
    Assert-PlainOutputParents (Join-Path $sourceRoot 'placeholder') $Root
    Assert-PlainOutputParents (Join-Path $destinationRoot 'placeholder') $Root
    [void][IO.Directory]::CreateDirectory($sourceRoot)
    [void][IO.Directory]::CreateDirectory($destinationRoot)
    Initialize-Display
    $script:UiSystem='Commodore 64 / NIB -> G64'
    Write-Event 'MODE' 'OptiMiyoo / Commodore 64 / NIB/NBZ -> G64'
    Write-Event 'SOURCE' $sourceRoot
    Write-Event 'OUTPUT' $destinationRoot
    $exitCode=Invoke-C64ExplicitOutputs $Root $Storage $SourcePolicy $Existing
    if ($script:ReportProblem -and $exitCode -eq 0) {$exitCode=1}
} catch {
    $exitCode=1
    Write-Notice 'ERROR' $_.Exception.Message
} finally {
    Restore-Display
    if ($script:Log) {$script:Log.Dispose()}
}
exit $exitCode
