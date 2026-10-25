#requires -Version 5.1
param(
    [Parameter(Position=0)][string]$Root,
    [ValidateSet('Keep', 'Remove', 'Folders')][string]$Mode,
    [ValidateSet('Zip','Loose','Folders')][string]$Storage,
    [ValidateSet('Keep','Remove')][string]$SourcePolicy,
    [ValidateSet('Ask', 'Overwrite', 'Skip')][string]$Existing = 'Ask',
    [switch]$NoPause,
    [switch]$NoAnimation,
    [string]$OnionRoot,
    [switch]$NoColor,
    [ValidateSet('CRT','Smooth')][string]$DisplayEffect='CRT'
)

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'application_entry.ps1')
if (-not (Test-ApplicationWorker)) {
    exit (Enter-ApplicationHost -ApplicationRoot (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -Entry C64 -Arguments $PSBoundParameters)
}
$script:ConverterVersion = '2.1'
$script:AppVersion = '0.0.9'

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'
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

# Shared OptiMiyoo display; conversion and transaction functions stay below.
function Write-C64Text {
    [CmdletBinding()]
    param([Parameter(Position=0,ValueFromRemainingArguments=$true)][object[]]$Object,
          [switch]$NoNewline,[ConsoleColor]$ForegroundColor,[ConsoleColor]$BackgroundColor)
    if ($script:UiRows -gt 0) {
        # Legacy notices already have explicit log entries. Never clear the
        # live panel merely to print a line; prompts suspend it explicitly.
        Write-Notice 'NOTE' (($Object -join ' ').Trim())
        return
    }
    if ($NoColor -or -not $script:UiInteractive) {
        [void]$PSBoundParameters.Remove('ForegroundColor')
        [void]$PSBoundParameters.Remove('BackgroundColor')
    }
    if ($PSBoundParameters.ContainsKey('Object')) {
        $PSBoundParameters['Object']=@($Object | ForEach-Object {ConvertTo-SafeExternalText ([string]$_)})
    }
    Write-Host @PSBoundParameters
}

function Get-C64SourceInputs([string]$Directory) {
    $pending=New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Directory); [long]$found=0
    while ($pending.Count -gt 0) {
        $directoryPath=$pending.Pop()
        Show-PreparationProgress 'Scanning SRC' $directoryPath $found -1 'inputs'
        foreach ($item in @(Get-ChildItem -LiteralPath $directoryPath -Force | Sort-Object Name)) {
            Show-PreparationProgress 'Scanning SRC' $item.Name $found -1 'inputs'
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Write-Event 'WARNING' ('IGNORED LINK: '+$item.FullName)
                continue
            }
            if ($item.PSIsContainer) {$pending.Push($item.FullName)}
            elseif ($item.Extension -in '.zip','.nib','.nbz','.g64') {$found++; $item}
        }
    }
}

function Get-C64OutputPlan([string]$RelativeZip,[string]$Storage,[string]$DestinationRoot) {
    $relative=$RelativeZip.Replace('\','/')
    $stem=$relative.Substring(0,$relative.Length-[IO.Path]::GetExtension($relative).Length)
    $loose=[IO.Path]::GetExtension($relative) -ine '.zip'
    $looseOutput=$loose -and $Storage -eq 'Folders'
    $folder=$Storage -eq 'Folders' -and -not $loose
    $relativeData=$stem
    if ($looseOutput) {$relativeData+='.g64'}
    elseif (-not $folder) {$relativeData+='.zip'}
    $target=[pscustomobject]@{Name=$relativeData;Folder=$folder;Role='Visible';
        Destination=[IO.Path]::GetFullPath((Join-Path $DestinationRoot $relativeData.Replace('/',[IO.Path]::DirectorySeparatorChar)))}
    return [pscustomobject]@{Stem=$stem;Destination=$target.Destination;RelativeData=$relativeData;
        Targets=@($target);Retired=@();Folder=$folder;Loose=$looseOutput}
}

function Set-C64OutputConflicts([object[]]$Jobs,[string]$SourcePrefix,[string]$DestinationRoot,[string]$Storage) {
    # Reserve actual conversion destinations before processing any source.
    $owners=@{}; $planned=0
    Show-PreparationProgress 'Planning game outputs' 'Collecting conversion destinations.' 0 $Jobs.Count 'inputs'
    foreach ($job in $Jobs) {
        $relative=$job.Zip.FullName.Substring($SourcePrefix.Length).Replace('\','/')
        $job.Plan=Get-C64OutputPlan $relative $Storage $DestinationRoot
        $planned++; Show-PreparationProgress 'Planning game outputs' $relative $planned $Jobs.Count 'inputs'
        if ($job.Images -eq 0 -and -not $job.ScanError) {continue}
        foreach ($part in $job.Plan.Stem.Split('/')) {
            if ($part.StartsWith('.')) {$job.ScanError='A game or collection name starts with a dot and would be hidden. Rename that input folder/file.'}
            if ($part.EndsWith('.') -or $part.EndsWith(' ')) {$job.ScanError='A game or collection name ends in a dot or space and aliases another Windows output path. Rename that input folder/file.'}
        }
        foreach ($target in $job.Plan.Targets) {
            $key=($target.Destination.Replace('\','/').Split('/') | ForEach-Object {$_.TrimEnd(' ','.')}) -join '/'
            if (-not $owners.ContainsKey($key)) {$owners[$key]=New-Object 'System.Collections.Generic.List[object]'}
            $owners[$key].Add($job)
        }
    }
    $keys=@($owners.Keys); $checked=0
    Show-PreparationProgress 'Checking output path conflicts' 'Checking shared paths and parent collections.' 0 $keys.Count 'paths'
    foreach ($key in $keys) {
        $participants=$owners[$key]
        if ($participants.Count -gt 1) {
            foreach ($job in $participants) {$job.ScanError='Source inputs share an output path. Rename the conflicting game or collection; no conflicting outputs were written.'}
        }
        $parent=$key
        while ($parent.Contains('/')) {
            $parent=$parent.Substring(0,$parent.LastIndexOf('/'))
            if ($owners.ContainsKey($parent)) {
                foreach ($job in @($participants.ToArray())+@($owners[$parent].ToArray())) {
                    $job.ScanError='A game output overlaps another game or collection. Rename the conflicting input; no conflicting outputs were written.'
                }
            }
        }
        $checked++; Show-PreparationProgress 'Checking output path conflicts' $key $checked $keys.Count 'paths'
    }
}

function Assert-C64MediaName([string]$Name) {
    if ($Name.IndexOfAny([char[]]":`r`n") -ge 0) {throw 'Unsafe existing media path; output left alone.'}
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Contains('\') -or [IO.Path]::IsPathRooted($Name)) {throw 'Unsafe existing media path; output left alone.'}
    foreach ($part in $Name.Split('/')) {
        if ($part -in '', '.', '..') {throw 'Unsafe existing media path; output left alone.'}
    }
}

function Read-C64PlaylistLines([string]$Path,[string]$Root) {
    $text=Read-OptiTextFile $Path 1MB 'Existing playlist' $Root
    $lines=@($text -split '\r\n|\n|\r')
    # A trailing newline is not an extra playlist entry.
    if ($lines.Count -gt 0 -and $lines[-1] -eq '') {$lines=@($lines | Select-Object -First ($lines.Count-1))}
    if ($lines.Count -gt 20000) {throw 'Existing playlist exceeds the entry limit; output left alone.'}
    foreach ($line in $lines) {if ($line.Length -gt 8192) {throw 'Existing playlist exceeds the line limit; output left alone.'}}
    return ,$lines
}

function Assert-C64OutputUnreferenced($Plan,[string]$DestinationRoot) {
    if (-not (Test-Path -LiteralPath $Plan.Destination)) {return}
    $pending=New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($DestinationRoot);$count=0
    while ($pending.Count -gt 0) {
        foreach ($file in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            if (++$count -gt 100000) {throw 'Playlist ownership inspection exceeds its entry limit; output left alone.'}
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if ($file.PSIsContainer -or $file.Extension -in '.m3u','.m3u8') {throw 'An output link prevents checking playlist references; output left alone.'}
                continue
            }
            if ($file.PSIsContainer) {$pending.Push($file.FullName);continue}
            if ($file.Extension -notin '.m3u','.m3u8') {continue}
            foreach ($line in (Read-C64PlaylistLines $file.FullName $DestinationRoot)) {
                $reference=$line.Trim()
                if (-not $reference -or $reference.StartsWith('#')) {continue}
                $reference=($reference -split '#',2)[0].Replace('\',[IO.Path]::DirectorySeparatorChar).Replace('/',[IO.Path]::DirectorySeparatorChar)
                try {
                    if ([IO.Path]::IsPathRooted($reference)) {$full=[IO.Path]::GetFullPath($reference)}
                    else {$full=[IO.Path]::GetFullPath((Join-Path $file.DirectoryName $reference))}
                } catch {throw ('Cannot verify an existing playlist reference: '+$file.FullName)}
                if ($full.Equals($Plan.Destination,[StringComparison]::OrdinalIgnoreCase) -or
                    ($Plan.Folder -and $full.StartsWith($Plan.Destination+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))) {
                    throw ('An existing playlist uses this output: '+$file.FullName+'. Output left alone; use a separate DST.')
                }
            }
        }
    }
}

function Get-C64ExistingMedia($Target,[string[]]$ExpectedFiles=@()) {
    $names=New-Object 'System.Collections.Generic.List[string]'
    if ($Target.Folder) {
        $prefix=$Target.Destination.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        $pending=New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($Target.Destination)
        while ($pending.Count -gt 0) {
            foreach ($entry in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Existing output contains a link; output left alone.'}
                if ($entry.PSIsContainer) {$pending.Push($entry.FullName);continue}
                $name=$entry.FullName.Substring($prefix.Length).Replace('\','/')
                Assert-C64MediaName $name
                if ($entry.Extension -in '.m3u','.m3u8','.zip' -and $name -notin $ExpectedFiles) {throw 'Existing output may be another game collection; output left alone.'}
                if ($entry.Extension -in '.g64','.nib','.nbz') {$names.Add($name)}
            }
        }
    } elseif ([IO.Path]::GetExtension($Target.Destination) -ieq '.g64') {
        $names.Add([IO.Path]::GetFileName($Target.Destination))
    } else {
        $archive=(Open-ArchiveWithBudget -Path $Target.Destination -Profile Floppy)
        try {
            foreach ($entry in $archive.Entries) {
                $name=$entry.FullName.Replace('\','/')
                if ($name.EndsWith('/')) {$name=$name.TrimEnd('/');if ($name) {Assert-C64MediaName $name};continue}
                Assert-C64MediaName $name
                $extension=[IO.Path]::GetExtension($name)
                if ($extension -in '.m3u','.m3u8','.zip' -and $name -notin $ExpectedFiles) {throw 'Existing output may be another game collection; output left alone.'}
                if ($extension -in '.g64','.nib','.nbz') {$names.Add($name)}
            }
        } finally {$archive.Dispose()}
    }
    return ,$names.ToArray()
}

function Assert-C64OwnedOutputs($Plan,[string[]]$IncomingNames,[string]$DestinationRoot,[string[]]$IncomingFiles=@()) {
    foreach ($target in $Plan.Targets) {
        Assert-PlainOutputParents $target.Destination $DestinationRoot
        if (-not (Test-Path -LiteralPath $target.Destination)) {continue}
        $item=Get-Item -LiteralPath $target.Destination -Force
        if ([bool]$item.PSIsContainer -ne [bool]$target.Folder -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw ('Existing output is a link or has the wrong type: '+$target.Destination)}
        $names=Get-C64ExistingMedia $target $IncomingFiles
        foreach ($name in $names) {
            # An approved replacement may change top-level disk names, but must
            # not adopt nested media belonging to another game or collection.
            if ($name.Contains('/') -and $name -notin $IncomingNames) {
                throw ('Existing output contains media outside this game layout; output left alone: '+$target.Destination)
            }
        }
    }
    Assert-C64OutputUnreferenced $Plan $DestinationRoot
    $folderPath=$null;if ($Plan.Folder) {$folderPath=$Plan.Destination}
    Assert-C64CollectionOutput $folderPath $Plan.Destination $DestinationRoot $IncomingNames
}

function Assert-C64CollectionOutput([string]$CollectionPath,[string]$OutputPath,[string]$DestinationRoot,[string[]]$ExpectedMedia) {
    # Never replace a collection containing another game's playlist or media.
    if ($CollectionPath -and (Test-Path -LiteralPath $CollectionPath -PathType Container)) {
        $prefix=$CollectionPath.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        $pending=New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($CollectionPath)
        while ($pending.Count -gt 0) {
            foreach ($entry in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw ('Existing output contains a link. Output left alone: '+$entry.FullName)
                }
                if ($entry.PSIsContainer) {$pending.Push($entry.FullName)}
                elseif ($entry.Extension -in '.m3u','.m3u8') {
                    throw ('This output name also belongs to a collection containing another playlist. Rename the game or collection; existing files were left alone: '+$entry.FullName)
                }
                elseif ($ExpectedMedia -and $entry.Extension -in '.g64','.nib','.nbz') {
                    $relative=$entry.FullName.Substring($prefix.Length).Replace('\','/')
                    if ($relative.Contains('/') -and $relative -notin $ExpectedMedia) {
                        throw ('This output contains nested disk files outside the incoming game layout. It may be a collection. Rename the game or collection; existing files were left alone: '+$entry.FullName)
                    }
                }
            }
        }
    }
    if ($OutputPath) {
        # A child output must not be written inside another game's media.
        $parent=[IO.Path]::GetDirectoryName($OutputPath)
        while ($parent -and -not $parent.Equals($DestinationRoot,[StringComparison]::OrdinalIgnoreCase)) {
            $parentPlaylist=$parent+'.m3u'
            if (Test-Path -LiteralPath $parentPlaylist -PathType Leaf) {
                throw ('This collection is already used by another game playlist. Rename the game or collection; existing files were left alone: '+$parentPlaylist)
            }
            # Sibling disk files are not part of this replacement. Mixed loose
            # and ZIP inputs may safely share a collection directory; only the
            # exact approved target is installed or replaced.
            $parent=[IO.Path]::GetDirectoryName($parent)
        }
    }
}

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

function Copy-WithProgress {
    param([IO.Stream]$InputStream, [IO.Stream]$OutputStream,
          [long]$Before, [long]$TotalBytes, [double]$Base, [double]$Weight,
          [string]$Stage, [string]$Name, [object]$ExpectedCrc=$null, [long]$ExpectedLength=-1)
    $crc=$null; if ($null -ne $ExpectedCrc) {$crc=New-Object OptiMiyoo.ZipCrc32}
    $buffer = New-Object byte[] 262144
    [long]$copied = 0
    while (($read = $InputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        if ($ExpectedLength -ge 0 -and $read -gt $ExpectedLength-$copied) {throw 'ZIP entry expanded beyond its declared size; source kept.'}
        $OutputStream.Write($buffer, 0, $read)
        if ($crc) {$crc.Update($buffer,$read)}
        $copied += $read
        $ratio = [Math]::Min(1, ($Before + $copied) / [double][Math]::Max(1, $TotalBytes))
        Show-Progress ($Base + $Weight * $ratio) $Stage `
            ('{0} | {1:N1}/{2:N1} MiB' -f $Name, (($Before + $copied) / 1MB), ($TotalBytes / 1MB)) `
            ([int][Math]::Floor(100 * $ratio))
    }
    if ($crc) {$crc.Verify([uint32]$ExpectedCrc,$Name)}
    return $copied
}

function Expand-ZipWithProgress([string]$ZipPath,[string]$Directory) {
    $archive=Open-ArchiveWithBudget -Path $ZipPath -Profile Floppy
    try {
        Show-Progress 0 'Extracting ZIP in sandbox' ([IO.Path]::GetFileName($ZipPath)) 0 -Force
        $null=Invoke-ArchiveSandbox -ZipPath $ZipPath -Archive $archive -Profile Floppy -Operation Extract -Destination $Directory -Progress {param($index,$count,$done,$length) Show-Progress (0.15*($index+$done/[Math]::Max(1,$length))/[Math]::Max(1,$count)) 'Extracting ZIP in sandbox' ('Entry {0}/{1}' -f ($index+1),$count) (100*$done/[Math]::Max(1,$length))}
    } finally {$archive.Dispose()}
    Show-Progress 0.15 'Extracting ZIP' 'Sandbox extraction complete' 100 -Force
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

function Get-C64StagingTree([string]$Directory) {
    # One traversal collects both kinds; large collections need not walk each directory twice.
    $files=New-Object 'System.Collections.Generic.List[IO.FileInfo]'
    $dirs=New-Object 'System.Collections.Generic.List[IO.DirectoryInfo]'
    foreach ($entry in @(Get-ChildItem -LiteralPath $Directory -Recurse -Force)) {
        if ($entry.PSIsContainer) {$dirs.Add($entry)} else {$files.Add($entry)}
    }
    return [pscustomobject]@{Files=$files;Directories=$dirs}
}

function New-ZipWithProgress([string]$Directory, [string]$Destination) {
    $tree = Get-C64StagingTree $Directory
    $files = $tree.Files; $dirs = $tree.Directories
    $prefixLength = $Directory.TrimEnd([IO.Path]::DirectorySeparatorChar).Length + 1
    [long]$totalBytes = 0
    foreach ($file in $files) { $totalBytes += $file.Length }
    $expected = @{}
    $archive = [IO.Compression.ZipFile]::Open($Destination, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($dir in $dirs) {
            $name = $dir.FullName.Substring($prefixLength).Replace('\', '/') + '/'
            [void]$archive.CreateEntry($name)
            $expected[$name] = @{ Length = 0; Hash = $null }
        }
        [long]$done = 0
        foreach ($file in $files) {
            $name = $file.FullName.Substring($prefixLength).Replace('\', '/')
            $entry = $archive.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
            if ($file.LastWriteTime.Year -ge 1980 -and $file.LastWriteTime.Year -le 2107) { $entry.LastWriteTime = $file.LastWriteTime }
            $source = $null; $dest = $null
            try {
                $source = $file.OpenRead(); $dest = $entry.Open()
                $done += Copy-WithProgress $source $dest $done $totalBytes 0.80 0.15 'Re-zipping (standard ZIP / Deflate)' $name
            } finally {
                if ($dest) { $dest.Dispose() }; if ($source) { $source.Dispose() }
            }
            $expected[$name] = @{ Length = $file.Length; Hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
        }
    } finally { $archive.Dispose() }
    Show-Progress 0.95 'Re-zipping' 'Output ZIP created; verifying contents' 100 -Force
    $archive=Open-ArchiveWithBudget -Path $Destination -Profile Floppy
    try {
        if($archive.Entries.Count -ne $expected.Count){throw 'Output ZIP entry count mismatch.'}
        $actual=Invoke-ArchiveSandbox -ZipPath $Destination -Archive $archive -Profile Floppy -Operation Hash -Progress {param($index,$count,$done,$length) Show-Progress (0.95+0.04*($index+$done/[Math]::Max(1,$length))/[Math]::Max(1,$count)) 'Verifying output ZIP in sandbox' ('Entry {0}/{1}' -f ($index+1),$count) (100*$done/[Math]::Max(1,$length))}
        foreach($entry in $archive.Entries) {
            if(-not $expected.ContainsKey($entry.FullName)){throw 'Unexpected ZIP entry.'}
            $item=$expected[$entry.FullName]
            if($entry.Length -ne $item.Length){throw 'ZIP length mismatch.'}
            if($null -ne $item.Hash -and (-not $actual.ContainsKey($entry.FullName) -or $actual[$entry.FullName].Hash -cne $item.Hash)){throw 'ZIP content mismatch.'}
        }
    } finally {$archive.Dispose()}
}

function New-FolderWithProgress([string]$Directory, [string]$Destination) {
    $tree = Get-C64StagingTree $Directory
    $files = $tree.Files; $dirs = $tree.Directories
    $prefixLength = $Directory.TrimEnd([IO.Path]::DirectorySeparatorChar).Length + 1
    [long]$totalBytes = 0
    foreach ($file in $files) { $totalBytes += $file.Length }
    if (Test-Path -LiteralPath $Destination) { throw 'Temporary output folder already exists.' }
    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($dir in $dirs) {
        [void][IO.Directory]::CreateDirectory((Join-Path $Destination $dir.FullName.Substring($prefixLength)))
    }
    $expected = @{}
    [long]$done = 0
    foreach ($file in $files) {
        $name = $file.FullName.Substring($prefixLength)
        $target = Join-Path $Destination $name
        $source = $null; $dest = $null
        try {
            $source = $file.OpenRead()
            $dest = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
            $copied = Copy-WithProgress $source $dest $done $totalBytes 0.80 0.15 'Saving files to folder' $name
            if ($copied -ne $file.Length) { throw "Incomplete copy: $name" }
            $done += $copied
        } finally {
            if ($dest) { $dest.Dispose() }; if ($source) { $source.Dispose() }
        }
        [IO.File]::SetLastWriteTimeUtc($target, $file.LastWriteTimeUtc)
        $expected[$name] = @{ Length = $file.Length; Hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
    }
    Show-Progress 0.95 'Saving files to folder' 'Files copied; verifying contents' 100 -Force
    $outputTree = Get-C64StagingTree $Destination
    if ($outputTree.Files.Count -ne $files.Count -or $outputTree.Directories.Count -ne $dirs.Count) {
        throw 'Output folder entry count mismatch.'
    }
    [long]$done = 0
    foreach ($file in $files) {
        $name = $file.FullName.Substring($prefixLength)
        $target = Join-Path $Destination $name
        $source = $null; $sha = $null; $hashStream = $null
        try {
            $source = [IO.File]::OpenRead($target)
            if ($source.Length -ne $expected[$name].Length) { throw "Folder file length mismatch: $name" }
            $sha = [Security.Cryptography.SHA256]::Create()
            $hashStream = New-Object Security.Cryptography.CryptoStream([IO.Stream]::Null, $sha, [Security.Cryptography.CryptoStreamMode]::Write)
            $done += Copy-WithProgress $source $hashStream $done $totalBytes 0.95 0.04 'Verifying output folder' $name
            $hashStream.FlushFinalBlock()
            $actual = [BitConverter]::ToString($sha.Hash).Replace('-', '')
            if ($actual -ne $expected[$name].Hash) { throw "Folder content mismatch: $name" }
        } finally {
            if ($hashStream) { $hashStream.Dispose() }; if ($sha) { $sha.Dispose() }; if ($source) { $source.Dispose() }
        }
    }
    Show-Progress 0.99 'Verifying output folder' 'All files verified' 100 -Force
    return $expected
}

function Confirm-Overwrite([string]$Destination, [bool]$Folder) {
    if ($script:ExistingPolicy -eq 'Overwrite') { return $true }
    if ($script:ExistingPolicy -eq 'Skip') { return $false }
    foreach ($id in 2, 1, 0) { Write-Progress -Id $id -Activity 'Waiting for overwrite choice' -Completed }
    $paths=@($Destination -split '\r?\n *')
    $warnings=@('Skip: no conversion or comparison.', 'Skipped originals stay in SRC.')
    if ($Folder) {$warnings+='Replacing this folder replaces ALL contents.'}
    $choices=@(Get-OverwriteChoiceRows)
    $invalid=$false
    $script:Clock.Stop()
    try {
        do {
            $shownWarnings=$warnings
            if ($invalid) {$shownWarnings+='Please enter Y, N, A or S.'}
            $choice=ConvertFrom-OverwriteAnswer (Read-OverwriteChoice 'Commodore 64 / existing output' $paths $shownWarnings $choices (Get-OverwriteInputPrompt))
            switch ($choice) {
                'Overwrite' { return $true }
                'Skip' { return $false }
                'OverwriteAll' { $script:ExistingPolicy = 'Overwrite'; return $true }
                'SkipAll' { $script:ExistingPolicy = 'Skip'; return $false }
                default { $invalid=$true }
            }
        } while ($true)
    } finally { $script:Clock.Start() }
}

function Remove-VerifiedSource([string]$SourcePath, [string]$ExpectedHash, [string]$DisplayName) {
    try {
        Remove-VerifiedSourceFile $SourcePath $ExpectedHash $sourceRoot {
            param($stage,$detail,$done,$total)
            Show-SourceCleanupProgress $stage $detail $done $total
        }
        $script:Removed++
        Write-Log ('REMOVED: original input from SRC after verified destination: ' + $SourcePath)
    } catch {
        $script:RemoveFailed++
        Write-Log ('DESTINATION VERIFIED, BUT ORIGINAL KEPT: ' + $_.Exception.Message)
        Write-C64Text ('  ORIGINAL KEPT: {0} - {1}' -f $DisplayName, $_.Exception.Message) -ForegroundColor Yellow
        return $_.Exception.Message
    }
}

function Remove-C64WorkPath([string]$Path,[string]$Root) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {return}
    try {Remove-SourcePolicyOwnedPath -Path $Path -Root $Root}
    catch {
        Write-Log ('Temporary output left in place: '+$Path+' / '+$_.Exception.Message)
        Write-C64Text ('  Temporary output left in place: '+$Path) -ForegroundColor Yellow
    }
}

function Move-OutputPath([string]$Source, [string]$Destination, [bool]$Folder) {
    if ($Folder) { [IO.Directory]::Move($Source, $Destination) }
    else { [IO.File]::Move($Source, $Destination) }
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

function Install-PlaylistSet([object[]]$Items, [string]$LegacyPath, [bool]$LegacyFolder, [bool]$Overwrite, [object[]]$Retired=@()) {
    # Verify replacement outputs as one transaction and restore previous bytes
    # if installation or verification fails.
    $backups = New-Object 'System.Collections.Generic.List[object]'
    $installed = New-Object 'System.Collections.Generic.List[object]'
    $locks = New-Object 'System.Collections.Generic.List[System.IDisposable]'
    $targets = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $Items) { $targets.Add($item) }
    # Only retire paths that actually exist at transaction start. A previously
    # absent obsolete path appearing later must not be adopted and deleted.
    foreach ($item in $Retired) {if (Test-Path -LiteralPath $item.Destination) {$targets.Add($item)}}
    if ($LegacyPath -and (Test-Path -LiteralPath $LegacyPath)) { $targets.Add([pscustomobject]@{ Destination = $LegacyPath; Folder = $LegacyFolder }) }
    $parentLocks=New-Object 'System.Collections.Generic.List[System.IDisposable]'
    try {
        $parents=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($item in $targets) {[void]$parents.Add([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($item.Destination)))}
        foreach ($item in $Items) {[void]$parents.Add([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($item.Staged)))}
        foreach ($parent in $parents) {$parentLocks.Add((Open-SourcePolicyDirectoryLease -Path $parent))}
    try {
        # Validate every existing path before moving anything.
        foreach ($item in $targets) {
            if (Test-Path -LiteralPath $item.Destination) {
                if (-not $Overwrite) { throw 'An output appeared during processing. Original kept; rerun to choose overwrite.' }
                $old = Get-Item -LiteralPath $item.Destination -Force
                if ([bool]$old.PSIsContainer -ne [bool]$item.Folder) { throw "Output has the wrong type: $($item.Destination)" }
                if ($old.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Output is a link: $($item.Destination)" }
            }
        }
        foreach ($item in $targets) {
            if (Test-Path -LiteralPath $item.Destination) {
                $backup = Join-Path ([IO.Path]::GetDirectoryName($item.Destination)) ('.ppg_' + [Guid]::NewGuid().ToString('N') + '.backup')
                Move-OutputPath $item.Destination $backup ([bool]$item.Folder)
                $backups.Add([pscustomobject]@{ Path = $item.Destination; Backup = $backup; Folder = [bool]$item.Folder })
                Write-Log ('BACKUP: {0} -> {1}' -f $item.Destination, $backup)
            }
        }
        foreach ($item in $Items) {
            Move-OutputPath $item.Staged $item.Destination ([bool]$item.Folder)
            $installed.Add($item)
        }
        # Native verification leases pin the destination's parent directories.
        # Install all staged paths before taking them, so a verification lease
        # cannot block a remaining rename. Verify every installed hash with those
        # same leases before returning; any failure still rolls back the set.
        foreach ($lock in (Open-SourcePolicyOutputs $Items {
            param($stage,$detail,$done,$total)
            Show-SourceCleanupProgress $stage $detail $done $total
        })) {$locks.Add($lock)}
    } catch {
        $message = $_.Exception.Message
        foreach ($lock in $locks) { $lock.Dispose() }
        $locks.Clear()
        for ($i = $installed.Count - 1; $i -ge 0; $i--) {
            $item = $installed[$i]
            # Verification failed, so the current destination might have been
            # replaced by another process. Preserve its bytes even after rollback.
            $item | Add-Member -NotePropertyName PreserveStaging -NotePropertyValue $true -Force
            try {
                Move-OutputPath $item.Destination $item.Staged ([bool]$item.Folder)
                $message += " Unverified output kept at: $($item.Staged)."
            }
            catch { $message += " Could not move back new output: $($item.Destination)." }
        }
        for ($i = $backups.Count - 1; $i -ge 0; $i--) {
            $item = $backups[$i]
            try { Move-OutputPath $item.Backup $item.Path ([bool]$item.Folder) }
            catch { $message += " Previous output preserved at: $($item.Backup)." }
        }
        throw $message
    }
    foreach ($item in $backups) {
        try { Remove-SourcePolicyOwnedPath -Path $item.Backup -Root ([IO.Path]::GetDirectoryName($item.Backup)) }
        catch {
            Write-Log ('Previous output backup could not be removed: ' + $item.Backup)
            Write-C64Text ('  Previous output backup remains at: ' + $item.Backup) -ForegroundColor Yellow
        }
    }
    return [pscustomobject]@{ Locks = $locks; Replaced = ($backups.Count -gt 0) }
    } finally {foreach ($parentLock in $parentLocks) {$parentLock.Dispose()}}
}

$script:ExistingPolicy = $Existing
$script:Log = $null; $script:ReportProblem=$false; $exitCode = 0
$script:Clock=[Diagnostics.Stopwatch]::StartNew()
$script:Total=0; $script:Processed=0; $script:Ok=0; $script:Skipped=0; $script:Failed=0
. (Join-Path $ScriptDir 'display.ps1')
. (Join-Path $ScriptDir 'core_support.ps1')
try {
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $ScriptDir }
    $Root = (Resolve-Path -LiteralPath $Root).ProviderPath
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw 'Root must be the folder containing SRC and DST.' }
    $sourceRoot = Join-Path $Root 'SRC'
    $destinationRoot = Join-Path $Root 'DST'
    Assert-PlainOutputParents (Join-Path $sourceRoot 'placeholder') $Root
    Assert-PlainOutputParents (Join-Path $destinationRoot 'placeholder') $Root
    [void][IO.Directory]::CreateDirectory($sourceRoot)
    [void][IO.Directory]::CreateDirectory($destinationRoot)
    $sourcePrefix = [IO.Path]::GetFullPath($sourceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $destinationPrefix = [IO.Path]::GetFullPath($destinationRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    Initialize-Display
    $script:UiSystem='Commodore 64 / NIB -> G64'
    Write-Event 'MODE' ('OptiMiyoo / Commodore 64 / converter workflow v'+$script:ConverterVersion)
    Write-Event 'SOURCE' $sourceRoot
    Write-Event 'OUTPUT' $destinationRoot
    if ($Storage) {
        if (-not $SourcePolicy) {$SourcePolicy='Keep';if ($Mode -eq 'Remove') {$SourcePolicy='Remove'}}
        exit (Invoke-C64ExplicitOutputs $Root $Storage $SourcePolicy $Existing)
    }
    if ([string]::IsNullOrWhiteSpace($Mode)) {throw 'Output choice is missing. Start OptiMiyoo again and choose ZIPs, loose files or folders.'}
    if (-not $SourcePolicy) {$SourcePolicy='Keep'; if ($Mode -eq 'Remove') {$SourcePolicy='Remove'}}
    $removeOriginals=($SourcePolicy -eq 'Remove')
    if (Test-ApplicationWorker) {Write-C64Text '  Working on staged copies. Originals are handled after verification.' -ForegroundColor Cyan}
    else {
        Write-C64Text ('  Source policy: '+$SourcePolicy.ToUpperInvariant()) -ForegroundColor Cyan
        if ($removeOriginals) {Write-C64Text '  Originals are removed only after ALL their outputs are verified in DST.' -ForegroundColor Magenta}
        else {Write-C64Text '  Originals stay in SRC.' -ForegroundColor Cyan}
    }
    Write-C64Text '  Loose inputs become G64 files or one ZIP each; game ZIPs keep their layout.' -ForegroundColor Cyan
    Write-C64Text '  Already-converted G64 images are supported; nibconv is needed only for NIB/NBZ.'
    Write-C64Text '  Existing outputs: Yes / No / Yes to all / No to all (all modes).'
    Write-C64Text '  No / No to all always keeps the original in SRC; no conversion or comparison.'
    Write-C64Text '  Queue progress counts completed inputs. Copy/verify progress measures bytes.'
    Write-C64Text '  NIB conversion shows current phase/track activity while the engine runs.'
    Write-C64Text '  Ctrl+C stops the run. All completed outputs remain in DST.'
    Write-C64Text ''
    $script:Clock = [Diagnostics.Stopwatch]::StartNew()
    Show-ConversionStart 'Commodore 64 / NIB -> G64'
    $zips = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    Get-C64SourceInputs $sourceRoot | ForEach-Object {$zips.Add($_)}
    Show-PreparationProgress 'Scanning SRC' 'Source input list collected.' $zips.Count $zips.Count 'inputs' -Force
    $script:Total = $zips.Count; $script:TotalImages = 0
    $jobs = New-Object 'System.Collections.Generic.List[object]'
    Show-PreparationProgress 'Counting disk images' 'Checking loose files and ZIP directories.' 0 $zips.Count 'inputs'
    for ($i = 0; $i -lt $zips.Count; $i++) {
        Show-PreparationProgress 'Counting disk images' $zips[$i].Name $i $zips.Count 'inputs'
        $archive = $null; $count = 0; $nibCount = 0; $scanError = $null
        $isArchive=$zips[$i].Extension -ieq '.zip'
        try {
            if ($isArchive) {
                $archive = (Open-ArchiveWithBudget -Path $zips[$i].FullName -Profile Floppy)
                foreach ($entry in $archive.Entries) {
                    if (-not ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\'))) {
                        $extension = [IO.Path]::GetExtension($entry.FullName)
                        if ($extension -in '.nib', '.nbz', '.g64') { $count++ }
                        if ($extension -in '.nib', '.nbz') { $nibCount++ }
                    } elseif ($entry.Length -ne 0) {throw ('ZIP directory entry contains data: '+$entry.FullName)}
                }
            } else {
                if ($zips[$i].Length -gt 512MB) {throw 'Disk image exceeds the 512 MiB input limit; original kept.'}
                $count=1
                if ($zips[$i].Extension -in '.nib','.nbz') {$nibCount=1}
            }
        } catch { $scanError = $_.Exception.Message }
        finally { if ($archive) { $archive.Dispose() } }
        $script:TotalImages += $count
        $jobs.Add([pscustomobject]@{ Zip = $zips[$i]; IsArchive = $isArchive; Images = $count; NibImages = $nibCount; ScanError = $scanError; Plan = $null })
        Show-PreparationProgress 'Counting disk images' $zips[$i].Name ($i+1) $zips.Count 'inputs'
    }

    Set-C64OutputConflicts $jobs.ToArray() $sourcePrefix $destinationRoot $Mode
    Complete-PreparationProgress
    Write-Event 'FOUND' ('{0:N0} inputs and {1:N0} NIB/NBZ/G64 disk images.' -f $script:Total, $script:TotalImages)
    if ($script:Total -gt 0) {
        $logName = 'OptiMiyoo_C64_{0}_{1}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), $PID
        try { $logPath = Join-Path $Root $logName; $logStream=[IO.File]::Open($logPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read); $script:Log=New-Object IO.StreamWriter($logStream,[Text.Encoding]::UTF8) }
        catch { $logPath = Join-Path ([IO.Path]::GetTempPath()) $logName; $logStream=[IO.File]::Open($logPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read); $script:Log=New-Object IO.StreamWriter($logStream,[Text.Encoding]::UTF8) }
        $script:Log.AutoFlush = $true
        Write-Log ('OptiMiyoo v{0} | Commodore 64 workflow v{1} | Mode: {2}' -f $script:AppVersion,$script:ConverterVersion,$Mode)
    Write-Log ('Source policy: '+$SourcePolicy)
        $script:Processed = 0; $script:Ok = 0; $script:Skipped = 0; $script:Failed = 0; $script:SavedImages = 0
        $script:Removed = 0; $script:RemoveFailed = 0
        $script:Overwritten = 0
        $script:NoImages = 0; $script:Declined = 0
        $results = New-Object 'System.Collections.Generic.List[object]'
        $script:LastDraw = -1000
        $script:Clock.Restart()
        foreach ($job in $jobs) {
            $zip = $job.Zip
            $relativeZip = $zip.FullName.Substring($sourcePrefix.Length)
            Set-ApplicationCurrentJob $relativeZip
            $plan=$job.Plan
            $relativeOutput=$plan.RelativeData
            $destination=$plan.Destination
            $script:ZipName = $relativeZip; $script:ZipFraction = 0
            $script:UiLastStage=''
            Write-Event 'GAME' ('{0}/{1} | {2}' -f ($script:Processed+1),$script:Total,$relativeZip)
            $tempBase = $null; $newZip = $null; $newFolder = $null; $outputCommit = $null
            $sourceLease=$null; $installItems=@()
            $overwrite = $false; $existingOutput = $false
            $removedBefore = $script:Removed
            $result = [pscustomobject]@{
                Source = $relativeZip; Destination = $relativeOutput; DiskImages = $job.Images
                Result = 'Failed'; Original = 'Kept in SRC'; Detail = ''
            }
            try {
                Show-Progress 0 'Opening input' $zip.FullName -1 -Force
                Write-Log ('INPUT: ' + $zip.FullName)
                if (-not $destination.StartsWith($destinationPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Destination leaves DST.' }
                if ($job.ScanError) { throw $job.ScanError }
                if ($job.Images -eq 0) {
                    $script:Skipped++; $script:NoImages++
                    $result.Result = 'Skipped'; $result.Detail = 'No NIB/NBZ/G64 images; original kept.'
                    Write-Log ('SKIPPED: no NIB/NBZ/G64 images; original kept: ' + $relativeZip)
                    Write-Event 'SKIP' ('{0} - no NIB/NBZ/G64 images; original kept in SRC.' -f $relativeZip)
                    continue
                }
                Assert-PlainOutputParents $destination $destinationRoot
                $conflicts=@($plan.Targets | Where-Object {Test-Path -LiteralPath $_.Destination} | ForEach-Object {$_.Destination})
                $existingOutput = $conflicts.Count -gt 0
                if ($existingOutput) {
                    $overwrite = Confirm-Overwrite ($conflicts -join "`n                  ") $plan.Folder
                    Write-Log ('EXISTING OUTPUT: overwrite={0}; policy={1}; path={2}' -f $overwrite, $script:ExistingPolicy, $destination)
                    if (-not $overwrite) {
                        $script:Skipped++
                        $script:Declined++
                        $result.Result = 'Skipped'; $result.Detail = 'Overwrite declined; original kept.'
                        Write-Log ('SKIPPED: overwrite declined; no conversion or comparison; original kept in SRC: ' + $relativeZip)
                        Write-Event 'SKIP' ('{0} - overwrite declined; original kept in SRC.' -f $relativeZip)
                        continue
                    }
                }
                if ($job.NibImages -gt 0 -and -not (Test-ApplicationWorker) -and -not (Test-Path -LiteralPath $NibConv -PathType Leaf)) {
                    throw 'This input contains NIB/NBZ images. Restore app/tools/nibconv.exe, then retry. Original kept.'
                }
                $zip.Refresh(); $sourceLength = $zip.Length; $sourceTime = $zip.LastWriteTimeUtc
                $sourceHash = $null
                if ($removeOriginals -or -not $job.IsArchive) {
                    $sourceLease=Open-SourcePolicyReadLease $zip.FullName $sourceRoot
                    $zip.Refresh()
                    if ($zip.Length -ne $sourceLength -or $zip.LastWriteTimeUtc -ne $sourceTime) {throw 'Source input changed before staging; original kept.'}
                    if (-not $job.IsArchive -and $zip.Length -gt 512MB) {throw 'Disk image exceeds the 512 MiB input limit; original kept.'}
                    $sourceHash = (Get-FileHash -LiteralPath $zip.FullName -Algorithm SHA256).Hash
                }
                $tempBase = Join-Path ([IO.Path]::GetTempPath()) ('ppg_' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
                $extractDir = Join-Path $tempBase 'extract'
                [void][IO.Directory]::CreateDirectory($extractDir)
                if ($job.IsArchive) {
                    Expand-ZipWithProgress $zip.FullName $extractDir
                } else {
                    if ($sourceLength -gt 512MB) {throw 'Disk image exceeds the 512 MiB input limit; original kept.'}
                    $stagedInput=Join-Path $extractDir $zip.Name
                    [IO.File]::Copy($zip.FullName,$stagedInput)
                    if ((Get-FileHash -LiteralPath $stagedInput -Algorithm SHA256).Hash -ne $sourceHash) {throw 'Staged disk image differs from source; original kept.'}
                }
                $nibs = @(Get-ChildItem -LiteralPath $extractDir -Recurse -File -Force |
                    Where-Object { $_.Extension -in '.nib', '.nbz' } | Sort-Object FullName)
                if ($nibs.Count -ne $job.NibImages) { throw 'Input changed since scanning; run again.' }
                $outputs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                foreach ($nib in $nibs) {
                    $g64 = [IO.Path]::ChangeExtension($nib.FullName, '.g64')
                    if ((Test-Path -LiteralPath $g64) -or -not $outputs.Add($g64)) { throw "Conflicting G64 filename: $($nib.Name). Original preserved." }
                }
                for ($i = 0; $i -lt $nibs.Count; $i++) {
                    $nib = $nibs[$i]
                    Assert-NibSource $nib.FullName
                    # Short arguments avoid nibconv's legacy filename buffers.
                    $shortInput = Join-Path $tempBase ('input' + $nib.Extension)
                    $shortOutput = Join-Path $tempBase 'output.g64'
                    [IO.File]::Copy($nib.FullName, $shortInput)
                    $nativeInputLease=$null
                    try {
                        $nativeInputLease=Open-SourcePolicyReadLease $shortInput $tempBase
                        Assert-NibSource $shortInput
                        Invoke-NibConversion $shortInput $shortOutput $i $nibs.Count $nib.Name
                    }
                    catch {throw ('Conversion failed for {0}: {1}' -f $nib.Name, $_.Exception.Message)}
                    finally {if ($nativeInputLease) {$nativeInputLease.Dispose()}}
                    [IO.File]::Move($shortOutput, [IO.Path]::ChangeExtension($nib.FullName, '.g64'))
                    Remove-SourcePolicyOwnedPath -Path $shortInput -Root $tempBase
                }
                foreach ($nib in $nibs) { Remove-SourcePolicyOwnedPath -Path $nib.FullName -Root $extractDir }
                $g64s = @(Get-ChildItem -LiteralPath $extractDir -Recurse -File -Force | Where-Object { $_.Extension -eq '.g64' })
                if ($g64s.Count -ne $job.Images) { throw 'Disk image count changed since scanning; output cancelled.' }
                foreach ($g64 in $g64s) { Assert-G64 $g64.FullName }
                $extractPrefix=$extractDir.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
                $expectedMedia=@($g64s | ForEach-Object {$_.FullName.Substring($extractPrefix.Length).Replace('\','/')})
                $expectedFiles=@(Get-ChildItem -LiteralPath $extractDir -Recurse -File -Force | ForEach-Object {$_.FullName.Substring($extractPrefix.Length).Replace('\','/')})
                Assert-C64OwnedOutputs $plan $expectedMedia $destinationRoot $expectedFiles
                $zip.Refresh()
                if ($zip.Length -ne $sourceLength -or $zip.LastWriteTimeUtc -ne $sourceTime) { throw 'Source input changed during processing; save cancelled.' }
                $destinationDirectory = [IO.Path]::GetDirectoryName($destination)
                [void][IO.Directory]::CreateDirectory($destinationDirectory)
                if ($plan.Loose) {
                    $newZip = Join-Path $destinationDirectory ('.ppg_' + [Guid]::NewGuid().ToString('N') + '.tmp')
                    [IO.File]::Copy($g64s[0].FullName,$newZip)
                    $newZipHash = (Get-FileHash -LiteralPath $newZip -Algorithm SHA256).Hash
                    if ($newZipHash -ne (Get-FileHash -LiteralPath $g64s[0].FullName -Algorithm SHA256).Hash) {throw 'Staged G64 differs from converted disk; original kept.'}
                } elseif ($plan.Folder) {
                    $newFolder = Join-Path $destinationDirectory ('.ppg_' + [Guid]::NewGuid().ToString('N') + '.tmp')
                    $folderManifest=New-FolderWithProgress $extractDir $newFolder
                } else {
                    $newZip = Join-Path $destinationDirectory ('.ppg_' + [Guid]::NewGuid().ToString('N') + '.tmp')
                    New-ZipWithProgress $extractDir $newZip
                    $newZipHash = (Get-FileHash -LiteralPath $newZip -Algorithm SHA256).Hash
                }
                $zip.Refresh()
                if ($zip.Length -ne $sourceLength -or $zip.LastWriteTimeUtc -ne $sourceTime) { throw 'Source input changed during processing; save cancelled.' }
                if ($plan.Folder) {
                    Show-Progress 0.99 'Saving verified folder to DST' $relativeOutput -1 -Force
                    $folderItem=[pscustomobject]@{Staged=$newFolder;Destination=$destination;Folder=$true;Manifest=$folderManifest}
                    Assert-C64OwnedOutputs $plan $expectedMedia $destinationRoot $expectedFiles
                    $installItems=@($folderItem)
                    $outputCommit=Install-PlaylistSet $installItems $null $false $overwrite
                } else {
                    Show-Progress 0.99 'Saving verified file to DST' $relativeOutput -1 -Force
                    $fileItem=[pscustomobject]@{Staged=$newZip;Destination=$destination;Folder=$false;Hash=$newZipHash}
                    Assert-C64OwnedOutputs $plan $expectedMedia $destinationRoot $expectedFiles
                    $installItems=@($fileItem)
                    $outputCommit=Install-PlaylistSet $installItems $null $false $overwrite
                }
                Complete-ApplicationCurrentJob
                $didOverwrite = $outputCommit -and $outputCommit.Replaced
                if ($didOverwrite) { $script:Overwritten++ }
                $result.Result = 'Written'
                $result.Detail = 'New output saved and verified.'
                if ($didOverwrite) { $result.Result = 'Overwritten'; $result.Detail = 'Existing output replaced with verified output.' }
                $script:Ok++; $script:SavedImages += $g64s.Count
                Write-Log ('OK: saved {0} G64 image(s) to {1}' -f $g64s.Count, $destination)
                if ($removeOriginals) {
                    # Release the read lease only when the verified output is held.
                    # Removal acquires its own handle and rechecks the initial hash.
                    $sourceLease.Dispose(); $sourceLease=$null
                    $removeError = Remove-VerifiedSource $zip.FullName $sourceHash $relativeZip
                    if ($removeError) { $result.Detail += ' Original not removed: ' + $removeError }
                } else { Write-Log 'KEPT: original input in SRC' }
                Show-Progress 1 'Complete - saved to DST' $relativeOutput 100 -Force
            } catch {
                $script:Failed++
                $result.Result = 'Failed'; $result.Detail = $_.Exception.Message
                Write-Log ('FAILED: ' + $_.Exception.Message)
                Write-Notice 'FAILED' ('{0} - {1}' -f $zip.Name, $_.Exception.Message)
            } finally {
                if ($sourceLease) {$sourceLease.Dispose()}
                if ($outputCommit) { foreach ($lock in $outputCommit.Locks) { $lock.Dispose() } }
                $preserved=@($installItems | Where-Object {$_.PSObject.Properties['PreserveStaging'] -and $_.PreserveStaging} | ForEach-Object {$_.Staged})
                if ($newZip -notin $preserved) {Remove-C64WorkPath $newZip $destinationRoot}
                if ($newFolder -notin $preserved) {Remove-C64WorkPath $newFolder $destinationRoot}
                Remove-C64WorkPath $tempBase ([IO.Path]::GetTempPath())
                if ($script:Removed -gt $removedBefore) { $result.Original = 'Removed from SRC' }
                $results.Add($result)
                $script:Processed++
            }
        }
        $script:Clock.Stop()
        $reportPath = [IO.Path]::ChangeExtension($logPath, '.csv')
        $reportSaved=$false
        $reportParentLease=$null
        try {
            $reportParentLease=Open-SourcePolicyDirectoryLease ([IO.Path]::GetDirectoryName($reportPath))
            $results | ConvertTo-SafeReportRow | Export-Csv -LiteralPath $reportPath -NoClobber -NoTypeInformation -Encoding UTF8
            $reportSaved=$true
        } catch {
            $script:ReportProblem=$true
            Write-Notice 'WARNING' ('Could not save CSV report: '+$_.Exception.Message)
        } finally {if ($reportParentLease) {$reportParentLease.Dispose()}}
        Show-ClosingPanel -RemovalFailures $script:RemoveFailed
        foreach ($id in 2, 1, 0) { Write-Progress -Id $id -Activity 'Complete' -Completed }
        Write-C64Text ''
        Write-RetroStripe
        Write-C64Text '  FINISHED - 100% of inputs processed' -ForegroundColor Cyan
        Write-C64Text ('  Total source inputs: {0:N0}' -f $script:Total) -ForegroundColor White
        Write-C64Text ('  Outputs written: {0:N0} (new: {1:N0}, overwritten: {2:N0})' -f $script:Ok, ($script:Ok - $script:Overwritten), $script:Overwritten) -ForegroundColor Cyan
        Write-C64Text ('  Skipped: {0:N0} (no disk images: {1:N0}; overwrite declined: {2:N0})' -f $script:Skipped, $script:NoImages, $script:Declined) -ForegroundColor Yellow
        Write-C64Text ('  Failed: {0:N0}' -f $script:Failed) -ForegroundColor Magenta
        Write-C64Text ('  Disk images saved: {0:N0}/{1:N0}   Elapsed: {2}' -f $script:SavedImages, $script:TotalImages, (Format-Duration $script:Clock.Elapsed.TotalSeconds)) -ForegroundColor Gray
        if (-not (Test-ApplicationWorker)) {
            Write-C64Text ('  Source policy: '+$SourcePolicy.ToUpperInvariant())
            Write-C64Text ('  Originals removed from SRC: {0:N0}   Kept in SRC: {1:N0}   Removal failures: {2:N0}' -f $script:Removed, ($script:Total - $script:Removed), $script:RemoveFailed) -ForegroundColor White
        }
        $attention = @($results | Where-Object { $_.Result -in 'Skipped', 'Failed' -or ($removeOriginals -and $_.Original -eq 'Kept in SRC') })
        if ($attention.Count -gt 0) {
            Write-C64Text "`n  SKIPPED / FAILED / ORIGINALS KEPT:" -ForegroundColor Yellow
            foreach ($item in @($attention | Select-Object -First 25)) {
                $resultColor = 'Yellow'
                if ($item.Result -eq 'Failed') { $resultColor = 'Magenta' }
                Write-C64Text ('  [{0}] {1}' -f $item.Result, $item.Source) -ForegroundColor $resultColor
                Write-C64Text ('    {0} | {1}' -f $item.Detail, $item.Original) -ForegroundColor Gray
            }
            if ($attention.Count -gt 25) { Write-C64Text ('  ...and {0:N0} more; see the CSV report.' -f ($attention.Count - 25)) }
        }
        if (-not (Test-ApplicationWorker) -and $reportSaved) {Write-C64Text "`n  Results for EVERY source input: $reportPath" -ForegroundColor Cyan}
        if ($script:ReportProblem) {Write-C64Text '  Reporting failed. Conversion results above may be incomplete in the log or CSV.' -ForegroundColor Yellow}
        Write-C64Text "  Output: $destinationRoot"
        if (-not (Test-ApplicationWorker)) {Write-C64Text "  Log: $logPath"} else {Write-C64Text '  Waiting for independent verification and publication.'}
        if ($script:Failed -gt 0) { $exitCode = 1; Write-C64Text '  Failed conversions keep their original inputs. See the report for details.' -ForegroundColor Magenta }
        if ($script:RemoveFailed -gt 0 -or $script:ReportProblem) { $exitCode = 1 }
    } else {
        Show-ClosingPanel -RemovalFailures $script:RemoveFailed
        Write-Event 'EMPTY' ("No NIB/NBZ/G64 files or ZIPs found in SRC. Put your inputs in: $sourceRoot")
    }
} catch {
    $exitCode = 1
    Write-Notice 'ERROR' $_.Exception.Message
} finally {
    Restore-Display
    foreach ($id in 2, 1, 0) { Write-Progress -Id $id -Activity 'Complete' -Completed }
    if ($script:Log) { $script:Log.Dispose() }
}
if (-not $NoPause) { [void](Read-Host "`nPress Enter to exit") }
exit $exitCode
