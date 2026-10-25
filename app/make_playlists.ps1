#requires -Version 5.1
param(
    [Parameter(Position=0)][string]$Root,
    [string]$System,
    [ValidateSet('Auto','Folders')][string]$Storage='Auto',
    [ValidateSet('Keep','Remove')][string]$SourcePolicy='Keep',
    [ValidateSet('Ask','Overwrite','Skip')][string]$Existing='Ask',
    [string]$OnionRoot,
    [switch]$PrepareOnion,
    [switch]$NoPause,
    [switch]$NoAnimation,
    [switch]$IdleAnimations,
    [switch]$NoColor,
    [ValidateSet('CRT','Smooth')][string]$DisplayEffect='CRT',
    [switch]$Preview,
    [ValidateSet('Tour','C64','ZX','Playlists','Results','Bunny','Setup')][string]$PreviewSection='Tour',
    [switch]$ZXConvert,
    [switch]$C64Convert,
    [ValidateSet('Keep','Remove','Folders')][string]$C64Mode='Keep',
    [ValidateSet('Ask','LooseDSK','ZipDSK')][string]$ZXFormat='Ask',
    [ValidateSet('Main','C64','ZX')][string]$StartPage='Main'
)
. (Join-Path $PSScriptRoot 'application_entry.ps1')
if (-not (Test-ApplicationWorker)) {
    exit (Enter-ApplicationHost -ApplicationRoot (Split-Path -Parent $PSScriptRoot) -Entry Playlist -Arguments $PSBoundParameters)
}
$script:AppVersion='0.0.9'
$ErrorActionPreference='Stop'
$ScriptDir=Split-Path -Parent $MyInvocation.MyCommand.Path
$NibConv=Join-Path $ScriptDir 'tools/nibconv.exe'
. (Join-Path $ScriptDir 'source_policy.ps1')
. (Join-Path $ScriptDir 'archive_limits.ps1')
. (Join-Path $ScriptDir 'native_process.ps1')
. (Join-Path $ScriptDir 'archive_sandbox.ps1')
. (Join-Path $ScriptDir 'overwrite_prompt.ps1')
. (Join-Path $ScriptDir 'media_validation.ps1')
. (Join-Path $ScriptDir 'core_support.ps1')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Initialize-NativeTextCapture

function Assert-G64([string]$Path) {
    # Some nibconv failures return exit code zero: validate actual output too.
    $stream = [IO.File]::OpenRead($Path)
    $reader = New-Object IO.BinaryReader($stream)
    try {
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
            Show-Stage (0.15 + 0.65 * (($Index + $fraction) / $Count)) ('Converting disk {0}/{1}' -f ($Index+1),$Count) $detail
            if (-not $finished) { Start-Sleep -Milliseconds 125 }
        } while (-not $finished)
        if ($capture.LimitExceeded) {throw 'nibconv diagnostic-output limit exceeded. Original kept.'}
        if ($capture.Child.ExitCode -ne 0) { throw "nibconv exit code $($capture.Child.ExitCode)." }
        if ($conversionProblem) { throw $conversionProblem }
        $capture.Export()
        if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { throw 'nibconv produced no G64 output. See the log for its messages.' }
        Assert-G64 $OutputPath
        Show-Stage 0.8 'Converted disk' $DisplayName
    } finally { $capture.Dispose() }
}


function Format-Duration([double]$Seconds) {
    if ($Seconds -lt 0 -or [double]::IsInfinity($Seconds)) { return 'calculating...' }
    $span = [TimeSpan]::FromSeconds([Math]::Max(0, $Seconds))
    return ('{0:00}:{1:00}:{2:00}' -f [Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds)
}

function Confirm-Overwrite([string]$Destination, [bool]$Folder) {
    if ($script:ExistingPolicy -eq 'Overwrite') { return $true }
    if ($script:ExistingPolicy -eq 'Skip') { return $false }
    foreach ($id in 2, 1, 0) { Write-Progress -Id $id -Activity 'Waiting for overwrite choice' -Completed }
    $paths=@($Destination -split '\r?\n *')
    $warnings=@('Skip: no copying or comparison.', 'Skipped originals stay in SRC.')
    if ($Folder) {$warnings+='Replacing this folder replaces ALL contents.'}
    $choices=@(Get-OverwriteChoiceRows)
    $invalid=$false
    $script:Clock.Stop()
    try {
        do {
            $shownWarnings=$warnings
            if ($invalid) {$shownWarnings+='Please enter Y, N, A or S.'}
            $choice=ConvertFrom-OverwriteAnswer (Read-OverwriteChoice 'Existing playlist output' $paths $shownWarnings $choices (Get-OverwriteInputPrompt))
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

function Move-OutputPath([string]$Source, [string]$Destination, [bool]$Folder) {
    if ($Folder) { [IO.Directory]::Move($Source, $Destination) }
    else { [IO.File]::Move($Source, $Destination) }
}

function Get-NaturalDiskKey([string]$Name) {
    # Compare numbers numerically: Disk 2 sorts before Disk 10.
    return [regex]::Replace($Name.ToLowerInvariant(), '\d+', {
        param($match)
        $match.Value.TrimStart('0').PadLeft(20, '0')
    })
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

function Install-PlaylistSet([object[]]$Items, [string]$LegacyPath, [bool]$LegacyFolder, [bool]$Overwrite, [object[]]$Retired=@(), [scriptblock]$ValidateBackup=$null) {
    # A playlist and its disk data are one replacement. Roll back both if either
    # install fails; never leave a new playlist pointing at missing/old data.
    $backups = New-Object 'System.Collections.Generic.List[object]'
    $installed = New-Object 'System.Collections.Generic.List[object]'
    $locks = New-Object 'System.Collections.Generic.List[System.IDisposable]'
    $targets = New-Object 'System.Collections.Generic.List[object]'
    $replaceTargets = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $Items) { $targets.Add($item) }
    foreach ($item in $Retired) { $targets.Add($item) }
    if ($LegacyPath) { $targets.Add([pscustomobject]@{ Destination = $LegacyPath; Folder = $LegacyFolder }) }
    $directoryLocks=New-Object 'System.Collections.Generic.List[System.IDisposable]'
    try {
        try {
            $parents=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($item in $targets) {[void]$parents.Add([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($item.Destination)))}
            foreach ($item in $Items) {[void]$parents.Add([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($item.Staged)))}
            foreach ($parent in $parents) {
                # Missing retired outputs have no directory to change. Pin the nearest
                # existing ancestor so it cannot be redirected during the transaction.
                $parentAnchor=$parent
                while (-not (Test-Path -LiteralPath $parentAnchor)) {$parentAnchor=[IO.Path]::GetDirectoryName($parentAnchor)}
                $directoryLocks.Add((Open-SourcePolicyDirectoryLease $parentAnchor))
            }
            # Validate every existing path before moving anything.
            foreach ($item in $targets) {
                if (Test-Path -LiteralPath $item.Destination) {
                    if (-not $Overwrite) { throw 'An output appeared during processing. Original kept; rerun to choose overwrite.' }
                    $old = Get-Item -LiteralPath $item.Destination -Force
                    if ([bool]$old.PSIsContainer -ne [bool]$item.Folder) { throw "Output has the wrong type: $($item.Destination)" }
                    if ($old.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Output is a link: $($item.Destination)" }
                    $replaceTargets.Add($item)
                }
            }
            # Only retire paths that were present and validated above. A newly
            # appearing retired output belongs to someone else until checked.
            foreach ($item in $replaceTargets) {
                if (Test-Path -LiteralPath $item.Destination) {
                    $backup = Join-Path ([IO.Path]::GetDirectoryName($item.Destination)) ('.m3u_' + [Guid]::NewGuid().ToString('N') + '.backup')
                    Move-OutputPath $item.Destination $backup ([bool]$item.Folder)
                    $captured=[pscustomobject]@{ Path = $item.Destination; Backup = $backup; Folder = [bool]$item.Folder; Guard=$null }
                    $backups.Add($captured)
                    if($ValidateBackup){$captured.Guard=& $ValidateBackup $captured.Path $captured.Backup $captured.Folder;if($null -eq $captured.Guard){throw 'Previous output verification did not return a guard.'}}
                    Write-Log ('BACKUP: {0} -> {1}' -f $item.Destination, $backup)
                }
            }
            foreach ($item in $Items) {
                Move-OutputPath $item.Staged $item.Destination ([bool]$item.Folder)
                $installed.Add($item)
                if ($item.Folder) { Assert-FolderManifest $item.Destination $item.Manifest }
                if (-not $item.Folder) {
                    $lock = [IO.File]::Open($item.Destination, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                    $locks.Add($lock)
                    $hash=Get-StreamHash $lock ([IO.Path]::GetFileName($item.Destination))
                    if ($hash -ne $item.Hash) { throw "Installed file did not match verified output: $($item.Destination)" }
                }
            }
        } catch {
            $message = $_.Exception.Message
            foreach ($lock in $locks) { $lock.Dispose() }
            $locks.Clear()
            foreach($backup in $backups){if($backup.Guard){$backup.Guard.Dispose();$backup.Guard=$null}}
            for ($i = $installed.Count - 1; $i -ge 0; $i--) {
                $item = $installed[$i]
                # A failed verification may mean another program replaced the
                # installed path. Retain anything moved back; cleanup must not
                # delete unverified data merely because it now has a temp name.
                $item | Add-Member -NotePropertyName PreserveStaging -NotePropertyValue $true -Force
                try {
                    Move-OutputPath $item.Destination $item.Staged ([bool]$item.Folder)
                    $message += " Recovery output retained at: $($item.Staged)."
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
            try {if($item.Guard){$item.Guard.Remove()}else{Remove-SourcePolicyOwnedPath $item.Backup ([IO.Path]::GetDirectoryName($item.Backup))}}
            catch {
                Write-Log ('Previous output backup could not be removed: ' + $item.Backup)
                Write-Notice 'WARNING' ('Previous output backup remains at: ' + $item.Backup)
            }
        }
        return [pscustomobject]@{ Locks = $locks; Replaced = ($backups.Count -gt 0) }
    } finally {foreach($backup in $backups){if($backup.Guard){$backup.Guard.Dispose()}};foreach ($directoryLock in $directoryLocks) {$directoryLock.Dispose()}}
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

function Write-Log([string]$Message) {
    $Message=ConvertTo-SafeExternalText $Message
    if ($script:Log) {
        try { $script:Log.WriteLine(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message)) }
        catch {
            $script:ReportProblem=$true
            try {$script:Log.Dispose()} catch {}; $script:Log=$null
            Write-Notice 'WARNING' 'Could not write the log. Processing will continue; review the CSV report.'
        }
    }
}
function Assert-RelativeName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.StartsWith('/') -or $Name.Contains('\')) { throw "Unsupported relative path: $Name" }
    foreach ($part in $Name.Split('/')) {
        if ($part -eq '' -or $part -eq '.' -or $part -eq '..' -or $part -match '[<>:"|?*\x00-\x1f]' -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw "Unsafe or Windows-incompatible path: $Name"
        }
    }
}
function Assert-PlaylistName([string]$Name) {
    Assert-RelativeName $Name
    if ($Name.Contains('#') -or $Name.Contains('|') -or $Name.Contains(';')) { throw "Playlist name contains #, | or semicolon: $Name. Rename the file or ZIP member." }
}
function Get-SourceFiles([string]$Directory) {
    $pending=New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Directory); [long]$found=0
    while ($pending.Count -gt 0) {
        $dir=$pending.Pop()
        Show-PreparationProgress 'Scanning SRC' $dir $found -1 'files'
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force | Sort-Object Name)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Write-Event 'WARNING' ('IGNORED LINK: '+$item.FullName)
                continue
            }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            else { $found++; Show-PreparationProgress 'Scanning SRC' $item.Name $found -1 'files'; $item }
        }
    }
}
function Get-StreamHash([IO.Stream]$Stream,[string]$Name='Disk data') {
    $sha=[Security.Cryptography.SHA256]::Create()
    $buffer=New-Object byte[] 1048576
    [long]$total=0; [long]$length=$Stream.Length-$Stream.Position
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Show-Stage 0 'Verifying SHA-256' $Name 0
    try {
        while (($n=$Stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock($buffer,0,$n,$buffer,0); $total+=$n
            if ($watch.ElapsedMilliseconds -ge 125) {
                Show-Stage 0 'Verifying SHA-256' ('{0} | {1:N1}/{2:N1} MiB' -f $Name,($total/1MB),($length/1MB)) (100*$total/[Math]::Max(1,$length))
                $watch.Restart()
            }
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0)
        if ($total -ne $length) {throw "Hash read was incomplete: $Name"}
        Show-Stage 0 'Verifying SHA-256' $Name 100
        return [BitConverter]::ToString($sha.Hash).Replace('-','')
    }
    finally { $sha.Dispose() }
}
function Get-VerifiedHash([string]$LiteralPath,[string]$Algorithm='SHA256') {
    $stream=[IO.File]::Open($LiteralPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $label=[IO.Path]::GetFileName($LiteralPath)
    if ($label.StartsWith('.m3u_')) {$label='New output for '+$script:UiGame}
    try {return [pscustomobject]@{Hash=(Get-StreamHash $stream $label)}}
    finally {$stream.Dispose()}
}
function Copy-Stream([IO.Stream]$InputStream,[IO.Stream]$OutputStream,[long]$Length,[string]$Name,[double]$Base,[double]$Weight,[object]$ExpectedCrc=$null) {
    $buffer=New-Object byte[] 1048576
    $sha=[Security.Cryptography.SHA256]::Create()
    $crc=$null; if ($null -ne $ExpectedCrc) {$crc=New-Object OptiMiyoo.ZipCrc32}
    [long]$total=0; $watch=[Diagnostics.Stopwatch]::StartNew()
    $action='Copying disk data'; if ($OutputStream -eq [IO.Stream]::Null) {$action='Reading archive contents'}
    Write-Event 'FILE' ('{0} / {1:N2} MiB / {2}' -f $Name,($Length/1MB),$action)
    Show-Stage 0 $action $Name 0
    try {
        while (($n=$InputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
            if ($n -gt $Length-$total) {throw "Stream exceeds its declared size: $Name"}
            $OutputStream.Write($buffer,0,$n)
            [void]$sha.TransformBlock($buffer,0,$n,$buffer,0)
            if ($crc) {$crc.Update($buffer,$n)}
            $total+=$n
            if ($watch.ElapsedMilliseconds -ge 125) {
                Show-Stage 0 $action ('{0} | {1:N1}/{2:N1} MiB' -f $Name,($total/1MB),($Length/1MB)) (100*$total/[Math]::Max(1,$Length))
                $watch.Restart()
            }
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0)
        if ($total -ne $Length) { throw "Incomplete stream: $Name" }
        if ($crc) {$crc.Verify([uint32]$ExpectedCrc,$Name)}
        Show-Stage 0 $action $Name 100
        return [BitConverter]::ToString($sha.Hash).Replace('-','')
    } finally { $sha.Dispose() }
}
function Copy-FileVerified([string]$Source,[string]$Destination,[string]$Name) {
    $inputStream=$null; $outputStream=$null
    try {
        $inputStream=[IO.File]::Open($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if ($inputStream.Length -eq 0) { throw "Empty file: $Name" }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))
        $outputStream=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $hash=Copy-Stream $inputStream $outputStream $inputStream.Length $Name 0.15 0.65
        $outputStream.Dispose(); $outputStream=$null
        if ((Get-VerifiedHash -LiteralPath $Destination -Algorithm SHA256).Hash -ne $hash) { throw "Copied file does not match source: $Name" }
        $inputStream.Position=0
        if ((Get-StreamHash $inputStream) -ne $hash) { throw "Source changed during copying: $Name" }
        Write-Event 'CHECK' ($Name+' / copy and source hashes match')
        return [pscustomobject]@{Hash=$hash; Length=$inputStream.Length}
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
    }
}
function Get-ZipDisks([IO.Compression.ZipArchive]$Archive,[string]$ZipPath) {
    $seen=New-Object 'System.Collections.Generic.Dictionary[string,bool]' ([StringComparer]::OrdinalIgnoreCase)
    $disks=New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $Archive.Entries) {
        $directory=$entry.FullName.EndsWith('/')
        if ($directory -and $entry.Length -ne 0) {throw 'A ZIP directory entry contains data. Archive is malformed; source kept.'}
        $name=$entry.FullName.TrimEnd('/')
        Assert-RelativeName $name
        if ($seen.ContainsKey($name)) { throw "Duplicate ZIP path (including letter case): $name" }
        $seen.Add($name,$directory)
        if (-not $directory -and [IO.Path]::GetExtension($name) -in $script:DiskExtensions) {
            Assert-PlaylistName $name
            if ($entry.Length -eq 0) { throw "Empty disk image: $name" }
            $disks.Add($name)
        }
    }
    foreach ($name in @($seen.Keys)) {
        $parts=$name.Split('/')
        for ($i=1; $i -lt $parts.Length; $i++) {
            $parent=($parts[0..($i-1)] -join '/')
            if ($seen.ContainsKey($parent) -and -not $seen[$parent]) { throw "ZIP path is both a file and a folder: $parent" }
        }
    }
    $tracks=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($disks | Where-Object {[IO.Path]::GetExtension($_) -eq '.cue'})) {
        $entry=$Archive.GetEntry($name); $cueStream=$null
        try {
            $text=Read-SandboxedZipText $ZipPath $Archive $entry 1MB
            $lines=[regex]::Split($text,'\r\n|\r|\n')
            $parent=([string][IO.Path]::GetDirectoryName($name)).Replace('\','/')
            foreach ($track in @(Get-CueReferences @($lines) $name)) {
                $relative=$track; if ($parent) {$relative=$parent+'/'+$track}
                [void]$tracks.Add($relative)
            }
        } finally {if ($cueStream) {$cueStream.Dispose()}}
    }
    $disks=@($disks | Where-Object {-not $tracks.Contains($_)})
    $stems=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($disk in $disks) {
        if (-not $stems.Add([IO.Path]::ChangeExtension($disk,$null))) {throw "Multiple formats of the same disk in one ZIP: $disk. Keep one playable version per disk."}
    }
    return @($disks | Sort-Object @{Expression={Get-NaturalDiskKey $_}}, @{Expression={$_}})
}
function Assert-ZipExtractionNames([IO.Compression.ZipArchive]$Archive) {
    # Windows merges directory spellings such as Disks/ and disks/. A playlist
    # retaining both spellings would then fail on the case-sensitive handheld.
    # Include implicit parents, not just explicit ZIP directory entries.
    $directories=New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $Archive.Entries) {
        $parts=$entry.FullName.TrimEnd('/').Split('/')
        $count=$parts.Length-1
        if ($entry.FullName.EndsWith('/')) {$count=$parts.Length}
        for ($i=1; $i -le $count; $i++) {
            $name=$parts[0..($i-1)] -join '/'
            if ($directories.ContainsKey($name)) {
                if (-not $directories[$name].Equals($name,[StringComparison]::Ordinal)) {
                    throw "ZIP folders differ only by letter case: $($directories[$name]) / $name. Use identical folder spelling before extracting on Windows. Original kept."
                }
            } else {$directories.Add($name,$name)}
        }
    }
}
function Read-ZipContents([IO.Compression.ZipArchive]$Archive,[string]$Destination,[string]$ZipPath) {
    if($Destination) {Assert-ZipExtractionNames $Archive}
    Show-Stage 0.05 'Checking ZIP contents in sandbox' ([IO.Path]::GetFileName($ZipPath))
    $operation='Hash';if($Destination){$operation='Extract'}
    $manifest=Invoke-ArchiveSandbox -ZipPath $ZipPath -Archive $Archive -Profile Media -Operation $operation -Destination $Destination -Progress {param($index,$count,$done,$length) Show-Stage (0.05+0.55*($index+$done/[Math]::Max(1,$length))/[Math]::Max(1,$count)) 'Checking ZIP contents in sandbox' ('Entry {0}/{1}' -f ($index+1),$count) (100*$done/[Math]::Max(1,$length))}
    Show-Stage 0.6 'Checking ZIP contents' 'Sandbox verification complete'
    return $manifest
}

function Assert-FolderManifest([string]$Directory,[hashtable]$Manifest) {
    $files=@(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force)
    if ($files.Count -ne $Manifest.Count) { throw 'Output folder file count does not match source.' }
    foreach ($name in $Manifest.Keys) {
        $path=Join-Path $Directory $name.Replace('/',[IO.Path]::DirectorySeparatorChar)
        $item=Get-Item -LiteralPath $path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $item.Length -ne $Manifest[$name].Length -or (Get-VerifiedHash -LiteralPath $path -Algorithm SHA256).Hash -ne $Manifest[$name].Hash) {
            throw "Output folder content mismatch: $name"
        }
    }
}
function New-Playlist([string[]]$DiskNames,[string]$RelativeStem,[string]$Destination,[bool]$ZipMode) {
    Assert-PlaylistName $RelativeStem
    $parent=[IO.Path]::GetDirectoryName($RelativeStem.Replace('/',[IO.Path]::DirectorySeparatorChar))
    $depth=0; if ($parent) { $depth=@($parent -split '[\\/]').Count }
    $media=('../'*$depth)+'.hidden/'+$RelativeStem
    if ($ZipMode) { $media+='.zip#' } else { $media+='/' }
    $lines=New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $DiskNames) {
        Assert-PlaylistName $name
        $line=$media+$name
        if ([Text.Encoding]::UTF8.GetByteCount($line) -gt 1000) { throw "Playlist path is too long: $name" }
        $lines.Add($line)
    }
    if ($lines.Count -lt 2) { throw 'A playlist requires at least two playable media images.' }
    [IO.File]::WriteAllText($Destination,(($lines -join "`n")+"`n"),(New-Object Text.UTF8Encoding($false)))
    Write-Log ('PLAYLIST ORDER: '+($DiskNames -join ' -> '))
    Write-Event 'ORDER' ('{0} disk image(s) in this playlist:' -f $DiskNames.Count)
    for ($i=0;$i -lt $DiskNames.Count;$i++) {Write-Event ('DISK '+($i+1)) $DiskNames[$i]}
}

function New-OutputZip([string]$Directory,[string]$Destination) {
    Write-Event 'PACK' 'Building a ZIP from the converted disk set and its companion files.'
    $prefix=$Directory.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $zip=[IO.Compression.ZipFile]::Open($Destination,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entry in @(Get-ChildItem -LiteralPath $Directory -Recurse -Force | Sort-Object FullName)) {
            $name=$entry.FullName.Substring($prefix.Length).Replace('\','/')
            if ($entry.PSIsContainer) {[void]$zip.CreateEntry($name+'/'); continue}
            $member=$zip.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal)
            $inputStream=$null; $outputStream=$null
            try {
                $inputStream=[IO.File]::OpenRead($entry.FullName); $outputStream=$member.Open()
                $null=Copy-Stream $inputStream $outputStream $inputStream.Length $name 0 1
            } finally {if ($outputStream) {$outputStream.Dispose()}; if ($inputStream) {$inputStream.Dispose()}}
        }
    } finally {$zip.Dispose()}
}

function Get-TapeGrouping([string]$Title) {
    $pattern='(?i)\s*[\(\[]\s*(?:(?:tape|cassette)\s*(?<tape>\d+[a-z]?|[a-z])(?:\s*(?:of|/)\s*\d+)?(?:\s+side\s*(?<side>\d+|[a-z]))?|side\s*(?<side>\d+|[a-z]))\s*[\)\]]'
    $found=[regex]::Matches($Title,$pattern)
    $tapes=@($found | Where-Object {$_.Groups['tape'].Success})
    $sides=@($found | Where-Object {$_.Groups['side'].Success})
    if ($found.Count -eq 0) {return $null}
    $errorText=$null
    if ($tapes.Count -gt 1 -or $sides.Count -gt 1) {$errorText='Ambiguous tape/side tags. Keep one release per set or put it in a game ZIP.'}
    $tag=''; if ($tapes.Count) {$tag=$tapes[0].Groups['tape'].Value}
    if ($sides.Count) {$tag+='.'+$sides[0].Groups['side'].Value}
    $name=[regex]::Replace([regex]::Replace($Title,$pattern,''),'\s{2,}',' ').Trim()
    [pscustomobject]@{Title=$name; Tag=$tag; Error=$errorText}
}

function Get-TapeSupportIssue([string[]]$Names,$Support) {
    $tapes=@($Names | Where-Object {[IO.Path]::GetExtension($_) -in '.tap','.t64'})
    if ($tapes.Count -eq 0) {return $null}
    if ($null -eq $Support -or -not $Support.CanBuild) {
        if ($null -eq $Support) {return 'Tape swapping UNVERIFIED for this system.'}
        return ('Tape swapping '+$Support.Status+': '+$Support.Reason)
    }
    foreach ($name in $tapes) {
        if ([IO.Path]::GetExtension($name) -notin $Support.Extensions) {
            return ('Tape swapping UNSUPPORTED for '+[IO.Path]::GetExtension($name)+' in the selected build.')
        }
    }
    return $null
}

function Get-Jobs([string]$SourceRoot, $Profile) {
    $prefix=$SourceRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $files=@(Get-SourceFiles $SourceRoot)
    Show-PreparationProgress 'Scanning SRC' 'Source file list collected.' $files.Count $files.Count 'files' -Force
    $zipFiles=@($files | Where-Object {$_.Extension -eq '.zip'} | Sort-Object FullName); $queued=0
    Show-PreparationProgress 'Grouping ZIP inputs' 'Each archive forms one input set.' 0 $zipFiles.Count 'ZIPs'
    foreach ($file in $zipFiles) {
        Show-PreparationProgress 'Grouping ZIP inputs' $file.Name $queued $zipFiles.Count 'ZIPs'
        $relative=$file.FullName.Substring($prefix.Length).Replace('\','/')
        [pscustomobject]@{System=$Profile.Folder; Source=$relative; Stem=$relative.Substring(0,$relative.Length-4); Zip=$file.FullName; Disks=@(); Error=$null}
        $queued++; Show-PreparationProgress 'Grouping ZIP inputs' $file.Name $queued $zipFiles.Count 'ZIPs'
    }
    $cueTracks=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ('.cue' -in $Profile.Extensions) {
        $cues=@($files | Where-Object {$_.Extension -eq '.cue'}); $checkedCues=0
        Show-PreparationProgress 'Reading CUE references' 'Finding companion tracks.' 0 $cues.Count 'CUEs'
        foreach ($cue in $cues) {
            Show-PreparationProgress 'Reading CUE references' $cue.Name $checkedCues $cues.Count 'CUEs'
            try {
                foreach ($track in @(Get-CueFiles $cue.FullName)) {
                    [void]$cueTracks.Add([IO.Path]::GetFullPath((Join-Path $cue.DirectoryName $track)))
                }
            } catch {Write-Log ('CUE will be checked while processing: '+$cue.FullName)}
            $checkedCues++; Show-PreparationProgress 'Reading CUE references' $cue.Name $checkedCues $cues.Count 'CUEs'
        }
    }
    $groups=@{}
    $looseFiles=@($files | Where-Object {$_.Extension -in $Profile.Extensions -and -not $cueTracks.Contains($_.FullName)} | Sort-Object FullName); $grouped=0
    Show-PreparationProgress 'Grouping loose media' 'Matching disk and tape labels.' 0 $looseFiles.Count 'files'
    foreach ($file in $looseFiles) {
        $relative=$file.FullName.Substring($prefix.Length).Replace('\','/')
        $parent=([string][IO.Path]::GetDirectoryName($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))).Replace('\','/')
        $title=$file.BaseName; $tag=''; $tagged=$false
        $tapeGrouping=$null
        if ($file.Extension -in '.tap','.t64') {$tapeGrouping=Get-TapeGrouping $title}
        $pattern='(?i)\s*[\(\[]\s*(?:disc|disk|side)\s*(\d+[a-z]?|[a-z])(?:\s*(?:of|/)\s*\d+)?\s*[\)\]]'
        $found=[regex]::Matches($title,$pattern)
        if ($null -ne $tapeGrouping) {
            $tag=$tapeGrouping.Tag; $tagged=$true; $title=$tapeGrouping.Title
        } elseif ($found.Count -eq 1) {
            $tag=$found[0].Groups[1].Value.ToLowerInvariant(); $tagged=$true
            $title=[regex]::Replace($title,$pattern,'').Trim()
            $title=[regex]::Replace($title,'\s{2,}',' ')
        } elseif ($parent -and $title -match '^(?i:disc|disk|side)\s*(\d+[a-z]?|[a-z])$') {
            $tag=$Matches[1].ToLowerInvariant(); $tagged=$true
            $title=[IO.Path]::GetFileName($parent)
            $parent=([string][IO.Path]::GetDirectoryName($parent)).Replace('\','/')
        }
        $stem=$title; if ($parent) {$stem=$parent+'/'+$title}
        if (-not $groups.ContainsKey($stem)) {
            $groups[$stem]=[pscustomobject]@{System=$Profile.Folder; Source=$stem; Stem=$stem; Zip=$null; Disks=(New-Object 'System.Collections.Generic.List[object]'); Error=$null}
        }
        $group=$groups[$stem]
        $group.Disks.Add([pscustomobject]@{Path=$file.FullName; Name=($file.BaseName+$file.Extension.ToLowerInvariant()); Tag=$tag; Tagged=$tagged})
        if ($null -ne $tapeGrouping) {if ($tapeGrouping.Error) {$group.Error=$tapeGrouping.Error}}
        elseif ($found.Count -gt 1) {$group.Error='Multiple disk tags in a loose filename. Put the complete game in one ZIP to specify its grouping.'}
        $grouped++; Show-PreparationProgress 'Grouping loose media' $file.Name $grouped $looseFiles.Count 'files'
    }
    $orderedGroups=@($groups.Values | Sort-Object Stem); $ordered=0
    Show-PreparationProgress 'Ordering disk sets' 'Checking disk labels and natural order.' 0 $orderedGroups.Count 'sets'
    foreach ($group in $orderedGroups) {
        $tags=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        if ($group.Disks.Count -gt 1) {
            foreach ($disk in $group.Disks) {
                if (-not $disk.Tagged -or -not $tags.Add((Get-NaturalDiskKey $disk.Tag))) {$group.Error='Ambiguous set: repeated disk number or mixed numbered/unnumbered files. Separate alternate releases.'}
            }
        }
        $group.Disks=@($group.Disks | Sort-Object @{Expression={Get-NaturalDiskKey $_.Tag}},@{Expression={Get-NaturalDiskKey $_.Name}})
        $group
        $ordered++; Show-PreparationProgress 'Ordering disk sets' $group.Stem $ordered $orderedGroups.Count 'sets'
    }
}

function Assert-GameStem([string]$Stem) {
    Assert-PlaylistName $Stem
    foreach ($part in $Stem.Split('/')) {
        if ($part.StartsWith('.')) {throw 'A game or collection name starts with a dot and would be hidden. Rename that input folder/file.'}
    }
}

function Add-CopiedFile([string]$Source,[string]$Name,[string]$Directory,[hashtable]$Manifest,[hashtable]$SourceHashes=@{}) {
    Assert-RelativeName $Name
    $sourceItem=Get-Item -LiteralPath $Source -Force
    if ($sourceItem.PSIsContainer -or ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw "Missing regular source file: $Source"}
    Assert-PlainOutputParents $Source ([IO.Path]::GetPathRoot($Source))
    if ($Manifest.ContainsKey($Name)) {
        if ((Get-VerifiedHash -LiteralPath $Source -Algorithm SHA256).Hash -ne $Manifest[$Name].Hash) {throw "Two source files collide: $Name"}
    } else {
        $Manifest[$Name]=Copy-FileVerified $Source (Join-Path $Directory $Name.Replace('/',[IO.Path]::DirectorySeparatorChar)) $Name
    }
    $SourceHashes[[IO.Path]::GetFullPath($Source)]=$Manifest[$Name].Hash
}

function Get-SbiCompanions([string]$DiskPath) {
    # Ask the filesystem for this disc's sidecar rather than materializing every
    # sibling for every disc. -Filter uses filesystem wildcards (brackets are
    # literal); the exact check also rejects any legacy short-name matches.
    # Query afresh at each planning/copy boundary so changes are still detected.
    $parent=[IO.Path]::GetDirectoryName($DiskPath)
    $stem=[IO.Path]::GetFileNameWithoutExtension($DiskPath)
    foreach ($item in @(Get-ChildItem -LiteralPath $parent -File -Force -Filter ($stem+'.sbi'))) {
        if ($item.Extension -eq '.sbi' -and $item.BaseName -eq $stem) {$item}
    }
}

function Get-CueReferences([string[]]$Lines,[string]$CuePath) {
    if ($Lines.Count -gt 16384) {throw "CUE has more than 16,384 lines: $CuePath"}
    $found=New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $Lines) {
        if ($line.Length -gt 8192) {throw "CUE line exceeds 8,192 characters: $CuePath"}
        if ($line -match '^\s*FILE\s+(?:"([^"]+)"|(\S+))\s+\S+\s*$') {
            $name=$Matches[1]; if (-not $name) {$name=$Matches[2]}
            # Paths are copied unchanged. Backslashes and parent traversal are
            # rejected because the target is a Linux handheld.
            Assert-RelativeName $name
            if ($found.Count -ge 1024) {throw "CUE has more than 1,024 FILE references: $CuePath"}
            $found.Add($name)
        } elseif ($line -match '^\s*FILE\b') {throw "Unrecognized CUE FILE line in $CuePath"}
    }
    if ($found.Count -eq 0) {throw "CUE contains no FILE entries: $CuePath"}
    return @($found)
}

function Get-CueFiles([string]$CuePath) {
    $text=Read-OptiTextFile $CuePath 1MB ('CUE '+$CuePath)
    return @(Get-CueReferences ([regex]::Split($text,'\r\n|\r|\n')) $CuePath)
}

function Assert-GameOutputFolder([string]$Directory,[string[]]$ExpectedNames) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {return}
    $prefix=$Directory.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $pending=New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Directory)
    while ($pending.Count -gt 0) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Existing game output contains a link; output left alone.'}
            if ($entry.PSIsContainer) {$pending.Push($entry.FullName); continue}
            $relative=$entry.FullName.Substring($prefix.Length).Replace('\','/')
            if ($entry.Extension -in '.m3u','.m3u8' -or
                $relative -notin $ExpectedNames) {
                throw 'Existing output may contain another game or collection. Use an empty DST or rename the conflicting game; output left alone.'
            }
        }
    }
}

function Read-PlaylistLines([string]$Path) {
    $text=Read-OptiTextFile $Path 1MB 'Existing playlist'
    $lines=[regex]::Split($text,'\r\n|\r|\n')
    if ($lines.Count -gt 16384) {throw 'Existing playlist exceeds the supported line count; output left alone.'}
    foreach ($line in $lines) {
        if ($line.Length -gt 8192) {throw 'Existing playlist contains an overlong line; output left alone.'}
    }
    return ,$lines
}

function Assert-OwnedPlaylist([string]$Path,[string]$Stem,[string[]]$Lines=$null) {
    # Only retire a playlist generated for this exact game's hidden media.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {return}
    $depth=@($Stem.Split('/')).Count-1
    $prefix=('../'*$depth)+'.hidden/'+$Stem
    $count=0
    if ($null -eq $Lines) {$Lines=Read-PlaylistLines $Path}
    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {continue}
        if ($line.StartsWith($prefix+'/',[StringComparison]::Ordinal)) {$member=$line.Substring($prefix.Length+1)}
        elseif ($line.StartsWith($prefix+'.zip#',[StringComparison]::Ordinal)) {$member=$line.Substring($prefix.Length+5)}
        else {throw 'Existing playlist does not point exclusively to this game. Output left alone; use an empty DST.'}
        Assert-RelativeName $member
        $count++
    }
    if ($count -eq 0) {throw 'Existing playlist is empty; output left alone.'}
}

function Get-GameMediaNames($Job,[string]$Storage='Auto') {
    $diskNames=@(); $contentNames=@()
    if ($Job.Zip) {
        $archive=Open-ArchiveWithBudget -Path $Job.Zip -Profile Media
        try {
            $diskNames=@(Get-ZipDisks $archive $job.Zip)
            $hasNib=@($diskNames | Where-Object {[IO.Path]::GetExtension($_) -in '.nib','.nbz'}).Count -gt 0
            if (-not $Job.Profile.Zip -or $Storage -eq 'Folders' -or $hasNib) {Assert-ZipExtractionNames $archive}
            $contentNames=@($archive.Entries | Where-Object {-not $_.FullName.EndsWith('/')} | ForEach-Object {$_.FullName})
        } finally {$archive.Dispose()}
    } else {
        $diskNames=@($Job.Disks | ForEach-Object {$_.Name})
        $contentNames=@($diskNames)
        foreach ($disk in $Job.Disks) {
            $parent=[IO.Path]::GetDirectoryName($disk.Path)
            if ([IO.Path]::GetExtension($disk.Name) -eq '.cue') {$contentNames+=@(Get-CueFiles $disk.Path)}
            $contentNames+=@(Get-SbiCompanions $disk.Path | ForEach-Object {$_.Name})
        }
    }
    return [pscustomobject]@{DiskNames=$diskNames;ContentNames=$contentNames}
}

function Test-OutputPathOverlap([string]$First,[string]$Second) {
    $a=[IO.Path]::GetFullPath($First).TrimEnd('\','/')
    $b=[IO.Path]::GetFullPath($Second).TrimEnd('\','/')
    return ($a.Equals($b,[StringComparison]::OrdinalIgnoreCase) -or
        $a.StartsWith($b+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
        $b.StartsWith($a+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))
}

function Set-PlaylistOutputConflicts([object[]]$Jobs) {
    # Index each actual write/retirement once. Case-insensitive equality and
    # ancestor lookups preserve the pairwise overlap rules without O(n^2) scans.
    $owners=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    Show-PreparationProgress 'Indexing output paths' 'Collecting installation and retirement paths.' 0 $Jobs.Count 'sets'
    for ($i=0;$i -lt $Jobs.Count;$i++) {
        if ($Jobs[$i].OutputPlan) {
            $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($target in (@($Jobs[$i].OutputPlan.Writes)+@($Jobs[$i].OutputPlan.Retired))) {
                $key=[IO.Path]::GetFullPath($target.Destination).TrimEnd('\','/')
                if (-not $seen.Add($key)) {continue}
                if (-not $owners.ContainsKey($key)) {$owners[$key]=New-Object 'System.Collections.Generic.List[int]'}
                $owners[$key].Add($i)
            }
        }
        Show-PreparationProgress 'Indexing output paths' $Jobs[$i].Stem ($i+1) $Jobs.Count 'sets'
    }
    $keys=@($owners.Keys); $checked=0
    $message='Several input games write or retire overlapping output paths. Separate or rename the inputs; no conflicting game was written.'
    Show-PreparationProgress 'Checking output path conflicts' 'Checking shared paths and parent collections.' 0 $keys.Count 'paths'
    foreach ($key in $keys) {
        $participants=$owners[$key]
        if ($participants.Count -gt 1) {foreach ($i in $participants) {$Jobs[$i].Error=$message}}
        $parent=[IO.Path]::GetDirectoryName($key)
        while ($parent) {
            if ($owners.ContainsKey($parent)) {
                $ancestors=$owners[$parent]
                if ($participants.Count -gt 1 -or $ancestors.Count -gt 1 -or $participants[0] -ne $ancestors[0]) {
                    foreach ($i in $participants) {$Jobs[$i].Error=$message}
                    foreach ($i in $ancestors) {$Jobs[$i].Error=$message}
                }
            }
            $parent=[IO.Path]::GetDirectoryName($parent)
        }
        $checked++; Show-PreparationProgress 'Checking output path conflicts' $key $checked $keys.Count 'paths'
    }
}

function Get-PlaylistOutputPlan($Job,[string]$SourceRoot,[string]$DestinationRoot,[string]$Storage,$Media) {
    $profile=$Job.Profile
    $zipMode=([bool]$profile.Zip -and $Storage -eq 'Auto' -and [bool]$Job.Zip)
    $isMulti=$Media.DiskNames.Count -gt 1
    $singleFile=(-not $isMulti -and -not $zipMode -and $Media.ContentNames.Count -eq 1)
    $dataFolder=(-not $zipMode -and -not $singleFile)
    $relativeData=$Job.Stem
    if ($isMulti) {$relativeData='.hidden/'+$Job.Stem}
    if ($zipMode) {$relativeData+='.zip'}
    elseif ($singleFile) {
        if ($Job.Zip) {$relativeData=$Job.Stem+[IO.Path]::GetExtension($Media.DiskNames[0])}
        else {$relativeData=$Job.Disks[0].Path.Substring($SourceRoot.TrimEnd('\','/').Length+1).Replace('\','/')}
        if ([IO.Path]::GetExtension($relativeData) -in '.nib','.nbz') {$relativeData=[IO.Path]::ChangeExtension($relativeData,'.g64')}
    }
    Assert-RelativeName $relativeData
    $dataPath=Join-Path $DestinationRoot $relativeData.Replace('/',[IO.Path]::DirectorySeparatorChar)
    $m3uPath=Join-Path $DestinationRoot ($Job.Stem+$profile.Playlist).Replace('/',[IO.Path]::DirectorySeparatorChar)
    $retired=New-Object 'System.Collections.Generic.List[object]'
    if (-not $isMulti) {$retired.Add([pscustomobject]@{Destination=$m3uPath;Folder=$false})}
    foreach ($suffix in '', '.zip') {
        $oldPath=Join-Path $DestinationRoot ('.hidden/'+$Job.Stem+$suffix).Replace('/',[IO.Path]::DirectorySeparatorChar)
        if (-not $oldPath.Equals($dataPath,[StringComparison]::OrdinalIgnoreCase)) {$retired.Add([pscustomobject]@{Destination=$oldPath;Folder=($suffix -eq '')})}
    }
    $writes=@([pscustomobject]@{Destination=$dataPath;Folder=$dataFolder})
    if ($isMulti) {$writes+=[pscustomobject]@{Destination=$m3uPath;Folder=$false}}
    # Previous visible single-media layouts have no ownership record. Detect
    # them rather than silently leaving duplicate entries or guessing deletion.
    $visible=New-Object 'System.Collections.Generic.List[object]'
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $relativeCandidates=@($Job.Stem,($Job.Stem+'.zip'))
    foreach ($ext in $profile.Extensions) {
        if ($ext -in '.nib','.nbz') {$ext='.g64'}
        $relativeCandidates+=($Job.Stem+$ext)
    }
    if (-not $Job.Zip) {
        foreach ($disk in $Job.Disks) {
            $relative=$disk.Path.Substring($SourceRoot.TrimEnd('\','/').Length+1).Replace('\','/')
            if ([IO.Path]::GetExtension($relative) -in '.nib','.nbz') {$relative=[IO.Path]::ChangeExtension($relative,'.g64')}
            $relativeCandidates+=$relative
        }
    }
    foreach ($relative in $relativeCandidates) {
        $candidate=Join-Path $DestinationRoot $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
        if ($candidate.Equals($dataPath,[StringComparison]::OrdinalIgnoreCase) -or
            $dataPath.StartsWith($candidate+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {continue}
        if ($seen.Add($candidate)) {$visible.Add([pscustomobject]@{Destination=$candidate;Folder=($relative -eq $Job.Stem)})}
    }
    return [pscustomobject]@{DiskNames=$Media.DiskNames;ContentNames=$Media.ContentNames;IsMulti=$isMulti;ZipMode=$zipMode;
        SingleFile=$singleFile;DataFolder=$dataFolder;RelativeData=$relativeData;DataPath=$dataPath;M3uPath=$m3uPath;
        Stem=$Job.Stem;Root=$DestinationRoot;Writes=$writes;Retired=$retired.ToArray();VisibleCandidates=$visible.ToArray()}
}

function Get-PlaylistOwnedMedia([string]$Path,[string]$Stem,[string]$Root) {
    $owned=@{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {return $owned}
    $lines=Read-PlaylistLines $Path
    Assert-OwnedPlaylist $Path $Stem $lines
    $depth=@($Stem.Split('/')).Count-1
    $prefix=('../'*$depth)+'.hidden/'+$Stem
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {continue}
        $suffix='';$offset=$prefix.Length+1
        if ($line.StartsWith($prefix+'.zip#',[StringComparison]::Ordinal)) {$suffix='.zip';$offset=$prefix.Length+5}
        $target=Join-Path $Root ('.hidden/'+$Stem+$suffix).Replace('/',[IO.Path]::DirectorySeparatorChar)
        if (-not $owned.ContainsKey($target)) {$owned[$target]=@()}
        $member=$line.Substring($offset)
        if ([IO.Path]::GetExtension($member) -notin $script:DiskExtensions) {throw 'Existing playlist references media outside the selected system profile; output left alone.'}
        $owned[$target]+=$member
    }
    return $owned
}

function Assert-NoForeignPlaylistReferences($Plan,[object[]]$Targets) {
    $existing=@($Targets | Where-Object {Test-Path -LiteralPath $_.Destination})
    if ($existing.Count -eq 0) {return}
    $pending=New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Plan.Root)
    while ($pending.Count -gt 0) {
        foreach ($file in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if ($file.PSIsContainer -or $file.Extension -in '.m3u','.m3u8') {throw 'An output link prevents checking playlist ownership. Output left alone.'}
                continue
            }
            if ($file.PSIsContainer) {$pending.Push($file.FullName);continue}
            if ($file.Extension -notin '.m3u','.m3u8' -or $file.FullName.Equals($Plan.M3uPath,[StringComparison]::OrdinalIgnoreCase)) {continue}
            foreach ($line in (Read-PlaylistLines $file.FullName)) {
                $reference=$line.Trim()
                if (-not $reference -or $reference.StartsWith('#')) {continue}
                $reference=($reference -split '#',2)[0].Replace('\',[IO.Path]::DirectorySeparatorChar).Replace('/',[IO.Path]::DirectorySeparatorChar)
                try {
                    if ([IO.Path]::IsPathRooted($reference)) {$full=[IO.Path]::GetFullPath($reference)}
                    else {$full=[IO.Path]::GetFullPath((Join-Path $file.DirectoryName $reference))}
                } catch {throw ('Cannot verify an existing playlist reference: '+$file.FullName)}
                foreach ($target in $existing) {
                    if ($full.Equals($target.Destination,[StringComparison]::OrdinalIgnoreCase) -or
                        ($target.Folder -and $full.StartsWith($target.Destination+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))) {
                        throw ('Another playlist uses this output: '+$file.FullName+'. Output left alone; use a separate DST.')
                    }
                }
            }
        }
    }
}

function Assert-PlaylistOutputOwnership($Plan,[string[]]$ExpectedNames) {
    $owned=Get-PlaylistOwnedMedia $Plan.M3uPath $Plan.Stem $Plan.Root
    foreach ($candidate in $Plan.VisibleCandidates) {
        if (Test-Path -LiteralPath $candidate.Destination) {
            throw ('A previous or unrelated visible output may conflict: '+$candidate.Destination+'. Use a clean/separate DST, or review and move the old output before rerunning; output left alone.')
        }
    }
    $targets=@($Plan.Writes)+@($Plan.Retired)
    $hiddenRoot=(Join-Path $Plan.Root '.hidden')+[IO.Path]::DirectorySeparatorChar
    foreach ($target in $targets) {
        Assert-PlainOutputParents $target.Destination $Plan.Root
        if (-not (Test-Path -LiteralPath $target.Destination)) {continue}
        $item=Get-Item -LiteralPath $target.Destination -Force
        if ([bool]$item.PSIsContainer -ne [bool]$target.Folder -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'An existing output is a link or has the wrong file/folder type.'}
        $expected=@($ExpectedNames)
        if ($target.Destination.StartsWith($hiddenRoot,[StringComparison]::OrdinalIgnoreCase)) {
            if (-not $owned.ContainsKey($target.Destination)) {throw ('Existing hidden media has no matching owning playlist: '+$target.Destination+'. Use a clean/separate DST; output left alone.')}
            $expected+=@($owned[$target.Destination])
            $oldArchive=$null
            try {
                if (-not $target.Folder) {
                    $oldArchive=Open-ArchiveWithBudget -Path $target.Destination -Profile Media
                    $null=Get-ZipDisks $oldArchive $target.Destination
                }
                foreach ($name in $owned[$target.Destination]) {
                    if ([IO.Path]::GetExtension($name) -eq '.cue') {
                        if ($target.Folder) {
                            $cue=Join-Path $target.Destination $name.Replace('/',[IO.Path]::DirectorySeparatorChar)
                            $tracks=@(Get-CueFiles $cue)
                        } else {
                            $cueEntry=$oldArchive.GetEntry($name)
                            if ($null -eq $cueEntry) {throw 'An existing playlist references a missing CUE; output left alone.'}
                            $cueStream=$null
                            try {
                                $text=Read-SandboxedZipText $target.Destination $oldArchive $cueEntry 1MB
                                $tracks=@(Get-CueReferences ([regex]::Split($text,'\r\n|\r|\n')) $name)
                            } finally {if($cueStream){$cueStream.Dispose()}}
                        }
                        foreach ($track in $tracks) {
                            $parent=([string][IO.Path]::GetDirectoryName($name)).Replace('\','/')
                            if ($parent) {$track=$parent+'/'+$track}
                            $expected+=$track
                        }
                    }
                    $expected+=[IO.Path]::ChangeExtension($name,'.sbi')
                }
                if ($oldArchive) {
                    foreach ($entry in $oldArchive.Entries) {
                        if ($entry.FullName.EndsWith('/')) {continue}
                        if ([IO.Path]::GetExtension($entry.FullName) -in '.m3u','.m3u8' -or $entry.FullName -notin $expected) {
                            throw 'Existing hidden ZIP may contain another game or unowned files. Use a clean/separate DST; output left alone.'
                        }
                    }
                }
            } finally {if ($oldArchive) {$oldArchive.Dispose()}}
        }
        if ($target.Folder) {Assert-GameOutputFolder $target.Destination $expected}
    }
    Assert-NoForeignPlaylistReferences $Plan $targets
}

function Copy-LooseSet($Job,[string]$Directory,[hashtable]$SourceHashes=@{}) {
    $manifest=@{}
    foreach ($disk in $Job.Disks) {
        Assert-PlaylistName $disk.Name
        Add-CopiedFile $disk.Path $disk.Name $Directory $manifest $SourceHashes
        $parent=[IO.Path]::GetDirectoryName($disk.Path)
        if ([IO.Path]::GetExtension($disk.Name) -eq '.cue') {
            foreach ($name in @(Get-CueFiles $disk.Path)) {
                Add-CopiedFile (Join-Path $parent $name.Replace('/',[IO.Path]::DirectorySeparatorChar)) $name $Directory $manifest $SourceHashes
            }
        }
        $sbiFiles=@(Get-SbiCompanions $disk.Path)
        if ($sbiFiles.Count -gt 1) {throw 'Several SBI sidecars match one disc.'}
        foreach ($sbi in $sbiFiles) {Add-CopiedFile $sbi.FullName ([IO.Path]::GetFileNameWithoutExtension($disk.Name)+'.sbi') $Directory $manifest $SourceHashes}
    }
    return $manifest
}

function Get-JobSourcePaths($Job) {
    if ($Job.Zip) {return $Job.Zip}
    foreach ($disk in $Job.Disks) {
        $disk.Path
        $parent=[IO.Path]::GetDirectoryName($disk.Path)
        if ([IO.Path]::GetExtension($disk.Name) -eq '.cue') {
            foreach ($name in @(Get-CueFiles $disk.Path)) {Join-Path $parent $name.Replace('/',[IO.Path]::DirectorySeparatorChar)}
        }
        foreach ($sbi in @(Get-SbiCompanions $disk.Path)) {$sbi.FullName}
    }
}

function Assert-CueTargets([string[]]$Names,[string]$Directory) {
    foreach ($name in $Names) {
        if ([IO.Path]::GetExtension($name) -ne '.cue') {continue}
        $cue=Join-Path $Directory $name.Replace('/',[IO.Path]::DirectorySeparatorChar)
        foreach ($track in @(Get-CueFiles $cue)) {
            $path=Join-Path ([IO.Path]::GetDirectoryName($cue)) $track.Replace('/',[IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {throw "Missing CUE track: $track"}
            # Linux is case-sensitive; even Windows must verify the spelling.
            $partPath=[IO.Path]::GetDirectoryName($cue)
            foreach ($part in $track.Split('/')) {
                if (@(Get-ChildItem -LiteralPath $partPath -Force | Where-Object {$_.Name -ceq $part}).Count -ne 1) {throw "CUE track spelling/case does not match: $track"}
                $partPath=Join-Path $partPath $part
            }
        }
    }
}

function Get-FolderManifest([string]$Directory) {
    $prefix=$Directory.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $manifest=@{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -File -Force -Recurse)) {
        $name=$file.FullName.Substring($prefix.Length).Replace('\','/')
        $manifest[$name]=[pscustomobject]@{Length=$file.Length; Hash=(Get-VerifiedHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
    }
    return $manifest
}

function Convert-NibSet([string[]]$Names,[string]$Directory) {
    $nibs=@($Names | Where-Object {[IO.Path]::GetExtension($_) -in '.nib','.nbz'})
    if ($nibs.Count -eq 0) {return $Names}
    if (-not (Test-ApplicationWorker) -and -not (Test-Path -LiteralPath $NibConv -PathType Leaf)) {throw 'nibconv.exe is missing. Extract the complete release ZIP.'}
    $targets=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $nibs) {
        $target=[IO.Path]::ChangeExtension($name,'.g64')
        if ((Test-Path -LiteralPath (Join-Path $Directory $target)) -or -not $targets.Add($target)) {throw "NIB conversion conflicts with an existing G64: $name"}
    }
    $temp=Join-Path ([IO.Path]::GetTempPath()) ('m3un_'+[Guid]::NewGuid().ToString('N').Substring(0,12))
    $tempParentLock=Open-SourcePolicyDirectoryLease ([IO.Path]::GetDirectoryName($temp))
    $tempLock=$null
    try {
        [void][IO.Directory]::CreateDirectory($temp)
        $tempLock=Open-SourcePolicyDirectoryLease $temp
        for ($i=0;$i -lt $nibs.Count;$i++) {
            $name=$nibs[$i]; $path=Join-Path $Directory $name
            $inputPath=Join-Path $temp ('input'+[IO.Path]::GetExtension($name).ToLowerInvariant())
            $outputPath=Join-Path $temp 'output.g64'
            $mediaParentLock=Open-SourcePolicyDirectoryLease ([IO.Path]::GetDirectoryName($path))
            try {
                Assert-NibSource $path
                [IO.File]::Copy($path,$inputPath)
                $nativeInputLease=$null
                try {
                    $nativeInputLease=Open-SourcePolicyReadLease $inputPath $temp
                    Assert-NibSource $inputPath
                    Invoke-NibConversion $inputPath $outputPath $i $nibs.Count $name
                } finally {if ($nativeInputLease) {$nativeInputLease.Dispose()}}
                [IO.File]::Move($outputPath,[IO.Path]::ChangeExtension($path,'.g64'))
                Remove-SourcePolicyOwnedPath $path $Directory
                Remove-SourcePolicyOwnedPath $inputPath $temp
            } finally {$mediaParentLock.Dispose()}
        }
    } finally {
        if ($tempLock) {$tempLock.Dispose()}
        try {if (Test-Path -LiteralPath $temp) {Remove-SourcePolicyOwnedPath $temp ([IO.Path]::GetDirectoryName($temp))}}
        catch {Write-Event 'WARNING' ('Conversion temporary files retained: '+$temp+' / '+$_.Exception.Message)}
        finally {$tempParentLock.Dispose()}
    }
    foreach ($name in $Names) {
        if ([IO.Path]::GetExtension($name) -in '.nib','.nbz') {[IO.Path]::ChangeExtension($name,'.g64')}
        else {$name}
    }
}

function Assert-NoMediaNesting($Job,[string]$DestinationRoot,[bool]$ZipMode,[string]$PlaylistExtension) {
    # An older run may have produced a game where this run wants a collection.
    # Never replace a folder containing another game's media.
    $parts=$Job.Stem.Split('/')
    for ($i=1;$i -lt $parts.Length;$i++) {
        $ancestor=($parts[0..($i-1)] -join '/')
        foreach ($ext in '.m3u','.m3u8') {
            if (Test-Path -LiteralPath (Join-Path $DestinationRoot ($ancestor+$ext)) -PathType Leaf) {throw "A parent collection is already a game: $ancestor"}
        }
    }
    $visibleChild=Join-Path $DestinationRoot $Job.Stem
    if (-not $ZipMode -and (Test-Path -LiteralPath $visibleChild -PathType Container)) {
        if (@(Get-ChildItem -LiteralPath $visibleChild -File -Recurse -Force | Where-Object {$_.Extension -in '.m3u','.m3u8'}).Count -gt 0) {throw 'This output game overlaps an existing collection. Rename the input game or collection.'}
    }
}

# All workers share the same display and cleanup reporting.
. (Join-Path $ScriptDir 'display.ps1')

# The launcher owns navigation; workers run in a fresh script scope for each batch.
# Back never starts a worker or touches SRC/DST.
function Read-MenuChoice([string]$Prompt) {
    if ($script:UiMenuActive) {
        try {return Read-DisplayInput $Prompt $script:UiMenuTitle $script:UiMenuLines.ToArray() $script:UiMenuMood}
        finally {$script:UiMenuActive=$false}
    }
    Clear-DisplayPanel
    try {[Console]::CursorVisible=$true} catch {}
    if ([Console]::IsInputRedirected) {
        Write-Host ($Prompt+': ') -NoNewline
        $line=[Console]::ReadLine()
        if ($null -eq $line) {return 'Q'}
        return $line.Trim()
    }
    return ([string](Read-Host $Prompt)).Trim()
}

function Show-MenuTitle([string]$Path) {
    [void](Update-DisplaySize)
    $script:UiMenuActive=$script:UiVT
    $script:UiMenuTitle=$Path; $script:UiMenuMood='idle'
    $script:UiMenuLines=New-Object 'System.Collections.Generic.List[string]'
    if ($script:UiMenuActive) {return}
    Write-Host ''
    Write-RetroStripe
    Write-Host ('  '+(Color-Text ('OptiMiyoo / '+$Path) '249;172;204'))
    Write-Host '  SRC -> DST | One system per batch'
    Write-Host ''
}

function Write-MenuLine([string]$Text='', [string]$Compact='') {
    if ($script:UiMenuActive) {
        if ($Compact) {$Text=$Compact}
        $script:UiMenuLines.Add($Text)
    } else {Write-Host (ConvertTo-SafeExternalText $Text)}
}

function Invoke-MenuWorker([string]$Path,[hashtable]$Arguments) {
    if (Test-ApplicationWorker) {return (Invoke-ApplicationMenuWorker $Path $Arguments)}
    # Restore before handing over so the child captures the real console state.
    Restore-Display
    $code=1
    try {
        & $Path @Arguments | Out-Host
        $code=$LASTEXITCODE
    } catch {Write-Host (ConvertTo-SafeExternalText ('  ERROR: '+$_.Exception.Message))}
    finally {Initialize-Display}
    return [int]$code
}

function Read-RunNavigation([string]$Page,[int]$Code) {
    if ($NoPause) {return 'Exit'}
    $invalid=$false
    while ($true) {
        Show-MenuTitle ($Page+' / task complete')
        if ($Code -ne 0) {$script:UiMenuMood='oops'} else {$script:UiMenuMood='happy'}
        Write-MenuLine ''
        Write-MenuLine ('  Task finished. Exit code: '+$Code)
        Write-MenuLine ('  [Enter / M] Main menu   [B] Back to '+$Page+'   [Q] Exit')
        if ($invalid) {Write-MenuLine '  Press Enter for the main menu, or choose B, M or Q.'}
        $answer=Read-MenuChoice 'Choose navigation [Enter = Main menu]'
        if ($answer -in '','M') {return 'Main'}
        if ($answer -eq 'B') {return 'Back'}
        if ($answer -eq 'Q') {return 'Exit'}
        $invalid=$true
    }
}

function Invoke-OptiMenu([object[]]$Profiles) {
    $page=$StartPage; $profile=$null; $lastCode=0
    $menuOnionRoot=$OnionRoot
    $common=@{Root=$Root; Existing=$Existing; NoAnimation=$NoAnimation; IdleAnimations=$IdleAnimations; NoColor=$NoColor; DisplayEffect=$DisplayEffect}
    while ($true) {
        $worker=$null; $workerArgs=$null; $pageName=$page
        if ($page -eq 'Main') {
            Show-MenuTitle 'Main menu'
            Write-MenuLine '  S. Onion SD setup: playlist visibility / preserve selected cores' 'S. Onion SD setup / cores preserved'
            Write-MenuLine '  D. Demo / interactive walkthrough' 'D. Demo / interactive walkthrough'
            Write-MenuLine ('  F. Display effect: '+$script:DisplayEffect+' / toggle')
            Write-MenuLine '  Z. ZX Spectrum: convert IPF to DSK (loose files or ZIPs)' 'Z. ZX Spectrum / IPF -> DSK'
            Write-MenuLine '  C. Commodore 64: convert NIB/NBZ to G64' 'C. Commodore 64 / NIB -> G64'
            Write-MenuLine '  Q. Exit'
            if ($menuOnionRoot) {Write-MenuLine ('  Support: selected cores on '+$menuOnionRoot) 'Support: selected cores on your SD'}
            else {Write-MenuLine '  Support: standard Onion cores. S checks a connected SD card.' 'Support: standard Onion cores'}
            for ($i=0;$i -lt $Profiles.Count;$i++) {
                $support=Get-PlaylistSupport $Profiles[$i] $menuOnionRoot
                $label=''; if (-not $support.CanBuild) {$label=' [PLAYLIST '+$support.Status+']'}
                $shortNames=@{AMIGA='Amiga'; COMMODORE='Commodore 64'; PS='PlayStation'; SEGACD='Sega CD / Mega-CD'; CPC='Amstrad CPC'; MSX='MSX / MSX2'; VIC20='VIC-20'; PCECD='PC Engine CD'; DOS='MS-DOS'; ZXS='ZX Spectrum'}
                $shortLabel=''; if (-not $support.CanBuild) {$shortLabel=' ['+$support.Status.ToLowerInvariant()+']'}
                $compact=('{0,2}. {1,-9} {2}{3}' -f ($i+1),$Profiles[$i].Folder,$shortNames[$Profiles[$i].Folder],$shortLabel)
                Write-MenuLine ('  {0,2}. {1,-11} {2}{3}' -f ($i+1),$Profiles[$i].Folder,$Profiles[$i].Name,$label) $compact
            }
            $answer=Read-MenuChoice 'Choose a system number or letter [Enter = 1, Amiga]'
            if ($answer -eq 'Q') {return $lastCode}
            if ($answer -eq 'C') {$page='C64'; continue}
            if ($answer -eq 'Z') {$page='ZX'; continue}
            if ($answer -eq 'S') {$page='SD'; continue}
            if ($answer -eq 'D') {$page='Demo'; continue}
            if ($answer -eq 'F') {
                Switch-DisplayEffect
                $common.DisplayEffect=$script:DisplayEffect
                continue
            }
            if ($answer -eq '') {$answer='1'}
            $number=0
            if ([int]::TryParse($answer,[ref]$number) -and $number -ge 1 -and $number -le $Profiles.Count) {
                $profile=$Profiles[$number-1]; $page='Storage'; continue
            }
            Write-MenuLine '  Choose one of the numbers or letters shown.'
            continue
        }
        if ($page -eq 'Demo') {
            Show-MenuTitle 'Demo / walkthrough'
            Write-MenuLine '  Demonstration only. No source, output or SD files are touched.'
            Write-MenuLine '  1. Full walkthrough / every stage'
            Write-MenuLine '  2. Commodore 64 / NIB, G64 and verification'
            Write-MenuLine '  3. ZX Spectrum / IPF, DSK and ZIP output'
            Write-MenuLine '  4. Playlists / hidden media and disk order'
            Write-MenuLine '  5. Results / overwrite, skip and error handling'
            Write-MenuLine '  6. Bunny animation gallery'
            Write-MenuLine '  7. Core support and Onion SD setup'
            Write-MenuLine '  B. Back to main menu     Q. Exit'
            $answer=Read-MenuChoice 'Choose demo [Enter = 1]'
            if ($answer -eq 'B') {$page='Main'; continue}
            if ($answer -eq 'Q') {return $lastCode}
            if ($answer -eq '') {$answer='1'}
            $sections=@{'1'='Tour';'2'='C64';'3'='ZX';'4'='Playlists';'5'='Results';'6'='Bunny';'7'='Setup'}
            if (-not $sections.ContainsKey($answer)) {Write-MenuLine '  Choose 1 to 7, B or Q.'; continue}
            Show-MioPreview $sections[$answer]
            $common.DisplayEffect=$script:DisplayEffect
            continue
        }
        if ($page -eq 'C64') {
            $pageName='Commodore 64'
            Show-MenuTitle $pageName
            Write-MenuLine '  Convert NIB/NBZ to G64. Existing G64 images keep their bytes.'
            Write-MenuLine '  Multi-disk ZIPs receive a playlist and media inside .hidden.'
            Write-MenuLine '  1. ZIP output / KEEP originals in SRC'
            Write-MenuLine '  2. ZIP output / REMOVE originals only after verified success'
            Write-MenuLine '  3. Folder output / KEEP originals in SRC'
            Write-MenuLine '  4. Folder output / REMOVE originals after verified success'
            Write-MenuLine '  B. Back to main menu     Q. Exit'
            if (Test-ApplicationWorker) {$answer=[string](Invoke-ApplicationRpc -Operation Policy.C64 -Payload @{}).Answer}
            else {$answer=Read-MenuChoice 'Choose mode [Enter = 1]'}
            if ($answer -eq 'B') {$page='Main'; continue}
            if ($answer -eq 'Q') {return $lastCode}
            if ($answer -eq '') {$answer='1'}
            if ($answer -notin '1','2','3','4') {Write-MenuLine '  Choose 1, 2, 3, 4, B or Q.'; continue}
            $mode=@{'1'='Keep';'2'='Remove';'3'='Folders';'4'='Folders'}[$answer]
            $worker=Join-Path $ScriptDir 'C64/convert_c64.ps1'
            $workerArgs=$common.Clone(); $workerArgs.Mode=$mode; $workerArgs.NoPause=$true; $workerArgs.OnionRoot=$menuOnionRoot
            $workerArgs.SourcePolicy='Keep'; if ($answer -in '2','4') {$workerArgs.SourcePolicy='Remove'}
        } elseif ($page -eq 'ZX') {
            $pageName='ZX Spectrum'
            Show-MenuTitle $pageName
            Write-MenuLine '  Convert IPF to DSK. Choose Keep or Remove on the next screen.'
            Write-MenuLine '  1. Loose DSK files'
            Write-MenuLine '  2. One ZIP per DSK'
            Write-MenuLine '  B. Back to main menu     Q. Exit'
            $answer=Read-MenuChoice 'Choose output [Enter = 2]'
            if ($answer -eq 'B') {$page='Main'; continue}
            if ($answer -eq 'Q') {return $lastCode}
            if ($answer -eq '') {$answer='2'}
            if ($answer -notin '1','2') {Write-MenuLine '  Choose 1, 2, B or Q.'; continue}
            $format='ZipDSK'; if ($answer -eq '1') {$format='LooseDSK'}
            $worker=Join-Path $ScriptDir 'ZX/convert_zx.ps1'
            $workerArgs=$common.Clone(); $workerArgs.Format=$format
        } elseif ($page -eq 'Storage') {
            $pageName=$profile.Name+' / playlist storage'
            Show-MenuTitle $pageName
            $support=Get-PlaylistSupport $profile $menuOnionRoot
            Write-MenuLine ('  '+$profile.Folder+' / '+$support.Core+' / '+$support.Status)
            if ($profile.Folder -eq 'COMMODORE') {
                $tapeSupport=Get-TapeSwapSupport $profile $menuOnionRoot $support
                $tapeFormats='TAP, T64'
                if ($tapeSupport.CanBuild) {$tapeFormats=(@($tapeSupport.Extensions | ForEach-Object {$_.TrimStart('.').ToUpperInvariant()}) -join ', ')}
                Write-MenuLine ('  Tape swapping: '+$tapeSupport.Status+' / '+$tapeFormats)
                if (-not $tapeSupport.CanBuild) {Write-MenuLine ('  '+$tapeSupport.Reason)}
            }
            Write-MenuLine ('  '+$profile.Note)
            if (-not $support.CanBuild) {
                Write-MenuLine ('  '+$support.Reason)
                Write-MenuLine '  Playlist creation is unavailable for this core.'
                Write-MenuLine '  B. Back to main menu     Q. Exit'
                $answer=Read-MenuChoice 'Choose navigation [Enter = Back]'
                if ($answer -eq 'Q') {return $lastCode}
                $page='Main'; continue
            }
            Write-MenuLine '  Single media stays visible; playlists need 2+ images.'
            Write-MenuLine '  Choose Keep or Remove originals on the next screen.'
            Write-MenuLine '  1. Auto: keep supported Amiga/VICE ZIPs'
            Write-MenuLine '  2. Loose folders: suitable when games write to their disks'
            Write-MenuLine '  B. Back to main menu     Q. Exit'
            $answer=Read-MenuChoice 'Choose storage [Enter = 1]'
            if ($answer -eq 'B') {$page='Main'; continue}
            if ($answer -eq 'Q') {return $lastCode}
            if ($answer -eq '') {$answer='1'}
            if ($answer -notin '1','2') {Write-MenuLine '  Choose 1, 2, B or Q.'; continue}
            $storageChoice='Auto'; if ($answer -eq '2') {$storageChoice='Folders'}
            $worker=Join-Path $ScriptDir 'make_playlists.ps1'
            $workerArgs=$common.Clone(); $workerArgs.System=$profile.Folder
            $workerArgs.Storage=$storageChoice; $workerArgs.NoPause=$true
            $workerArgs.OnionRoot=$menuOnionRoot
        } elseif ($page -eq 'SD') {
            if (Test-ApplicationWorker) {
                $selected=Invoke-ApplicationRpc -Operation SD.Select -Payload @{}
                if ($selected.Cancelled) {$page='Main';continue}
                return 0
            }
            $pageName='Onion SD setup'
            Show-MenuTitle $pageName
            Write-MenuLine '  Enter the SD card root (for example E:\).'
            Write-MenuLine '  Only config.json file-list extensions are edited. Selected cores are preserved.'
            Write-MenuLine '  Commodore tapes and PP disks share the same config and M3U extension.'
            Write-MenuLine '  B. Back to main menu     Q. Exit'
            $prompt='SD card root'
            if ($menuOnionRoot) {$prompt+=' [Enter = '+$menuOnionRoot+']'}
            $answer=Read-MenuChoice $prompt
            if ($answer -eq 'B') {$page='Main'; continue}
            if ($answer -eq 'Q') {return $lastCode}
            if ($answer -eq '') {$answer=$menuOnionRoot}
            if (-not $answer) {Write-MenuLine '  Enter a path, B or Q.'; continue}
            $worker=Join-Path $ScriptDir 'prepare_onion.ps1'
            $workerArgs=@{OnionRoot=$answer.Trim('"');NoPause=$true}
            if (Test-Path -LiteralPath (Join-Path $workerArgs.OnionRoot 'RetroArch/.retroarch/cores') -PathType Container) {$menuOnionRoot=$workerArgs.OnionRoot}
        }
        if ($page -in 'Storage','ZX') {
            if (Test-ApplicationWorker) {
                $operation='Playlist';$chosenFormat='LooseDSK';$chosenStorage='Auto'
                if ($page -eq 'ZX') {$operation='ZX';$chosenFormat=$workerArgs.Format}
                else {$chosenStorage=$workerArgs.Storage}
                $policyChoice=Read-ApplicationSourcePolicy $operation $workerArgs.System $chosenStorage $chosenFormat
            } else {$policyChoice=Read-SourcePolicy $pageName}
            if ($policyChoice -eq 'Back') {continue}
            if ($policyChoice -eq 'Exit') {return $lastCode}
            $workerArgs.SourcePolicy=$policyChoice
        }
        $lastCode=Invoke-MenuWorker $worker $workerArgs
        if (Test-ApplicationWorker) {return $lastCode}
        $next=Read-RunNavigation $pageName $lastCode
        if ($next -eq 'Exit') {return $lastCode}
        if ($next -eq 'Main') {$page='Main'}
        # Back leaves the page selected and redraws its choices for another run.
    }
}

$script:ExistingPolicy=$Existing
$script:Log=$null; $script:ReportProblem=$false; $exitCode=0
$script:Clock=[Diagnostics.Stopwatch]::StartNew()
$script:Total=0; $script:Processed=0; $script:Ok=0; $script:Skipped=0; $script:Failed=0
$results=New-Object 'System.Collections.Generic.List[object]'
try {
    if ([string]::IsNullOrWhiteSpace($Root)) {$Root=Split-Path -Parent $ScriptDir}
    $Root=(Resolve-Path -LiteralPath $Root).ProviderPath
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {throw 'Root must be a folder.'}
    # Windows PowerShell may emit the JSON array as one pipeline object.
    # Assign it first so the outer array contains individual system profiles.
    $profileData=Get-Content -LiteralPath (Join-Path $ScriptDir 'systems.json') -Raw | ConvertFrom-Json
    $profiles=@($profileData)
    Show-Header
    if ($Preview) {Show-MioPreview $PreviewSection; Restore-Display; exit 0}
    if ($C64Convert) {
        Restore-Display
        $policyArgs=@{}; if ($PSBoundParameters.ContainsKey('SourcePolicy')) {$policyArgs.SourcePolicy=$SourcePolicy}
        & (Join-Path $ScriptDir 'C64/convert_c64.ps1') @policyArgs -Root $Root -Mode $C64Mode -OnionRoot $OnionRoot -Existing $Existing -NoPause:$NoPause -NoAnimation:$NoAnimation -IdleAnimations:$IdleAnimations -NoColor:$NoColor -DisplayEffect $DisplayEffect
        exit $LASTEXITCODE
    }
    if ($ZXConvert) {
        Restore-Display
        $policyArgs=@{}; if ($PSBoundParameters.ContainsKey('SourcePolicy')) {$policyArgs.SourcePolicy=$SourcePolicy}
        & (Join-Path $ScriptDir 'ZX/convert_zx.ps1') @policyArgs -Root $Root -Format $ZXFormat -Existing $Existing -NoAnimation:$NoAnimation -IdleAnimations:$IdleAnimations -NoColor:$NoColor -DisplayEffect $DisplayEffect
        $resultCode=$LASTEXITCODE
        if (-not $NoPause) {[void](Read-Host 'Press Enter to exit')}
        exit $resultCode
    }
    if ($PrepareOnion) {
        Restore-Display
        & (Join-Path $ScriptDir 'prepare_onion.ps1') -OnionRoot $OnionRoot -NoPause:$NoPause
        exit $LASTEXITCODE
    }
    if (-not $System) {
        $exitCode=Invoke-OptiMenu $profiles
        exit $exitCode
    }
    $selected=@($profiles | Where-Object {$_.Folder -eq $System})
    if ($System -eq 'All') {throw 'Choose one system for this SRC folder. The same SRC and DST folders are used for every system.'}
    if ($selected.Count -eq 0) {throw "Unknown system: $System"}
    $script:Clock.Restart()
    $stamp='{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'),$PID
    $logPath=Join-Path $Root ('OptiMiyoo_'+$stamp+'.log')
    $logParentLease=Open-SourcePolicyDirectoryLease ([IO.Path]::GetDirectoryName($logPath))
    $logHandle=$null
    try {
        $logHandle=[IO.File]::Open($logPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $script:Log=New-Object IO.StreamWriter($logHandle,[Text.Encoding]::UTF8)
        $logHandle=$null
    } finally {
        if ($logHandle) {$logHandle.Dispose()}
        $logParentLease.Dispose()
    }
    $script:Log.AutoFlush=$true
    Write-Log ('OptiMiyoo v{0} | System: {1} | Storage: {2}' -f $script:AppVersion,$System,$Storage)
    Write-Log ('Source policy: '+$SourcePolicy)
    Write-Event 'SOURCE' (Join-Path $Root 'SRC')
    Write-Event 'OUTPUT' (Join-Path $Root 'DST')
    Write-Host '  Existing outputs: Y / N / A / S. Skipping keeps the original.'
    Write-Host '  Single media stays visible in DST. Playlists require 2+ images.'
    if (Test-ApplicationWorker) {Write-Host '  Working on staged copies. Originals are handled after verification.'}
    else {Write-Host ('  Source policy: '+$SourcePolicy.ToUpperInvariant()+' originals. Skipped/failed inputs stay in SRC.')}
    Write-Host '  Auto storage keeps Amiga/VICE ZIPs; other systems use loose images.'
    Write-Host '  Support follows Onion defaults or the selected core on the supplied SD card.' -ForegroundColor Yellow
    Show-ConversionStart $System
    $jobs=New-Object 'System.Collections.Generic.List[object]'
    foreach ($profile in $selected) {
        Show-PreparationProgress 'Checking selected core' $profile.Folder 0 -1 'profiles' -Force
        $support=Get-PlaylistSupport $profile $OnionRoot
        Write-Event 'CORE' ($support.Basis+' / '+$support.Core+' / '+$support.Status)
        if (-not $support.CanBuild) {Write-Event 'UNSUPPORTED' $support.Reason}
        $tapeSupport=$null
        if ($profile.Folder -eq 'COMMODORE') {
            $tapeSupport=Get-TapeSwapSupport $profile $OnionRoot $support
            Write-Event 'TAPES' ($tapeSupport.Status+' / '+$support.Basis+' / '+$tapeSupport.Reason)
        }
        $sourceRoot=Join-Path $Root 'SRC'
        $destRoot=Join-Path $Root 'DST'
        foreach ($dir in @($sourceRoot,$destRoot)) {
            Assert-PlainOutputParents (Join-Path $dir 'placeholder') $Root
            [void][IO.Directory]::CreateDirectory($dir)
        }
        $systemJobs=@(Get-Jobs $sourceRoot $profile)
        if ($systemJobs.Count -gt 0) {
            Write-Event 'FOUND' ('{0}: {1} input set(s) | {2}' -f $profile.Folder,$systemJobs.Count,$profile.Core)
            Write-Event 'NOTE' $profile.Note
        }
        foreach ($job in $systemJobs) {
            $job | Add-Member -NotePropertyName Profile -NotePropertyValue $profile
            $job | Add-Member -NotePropertyName TapeSupport -NotePropertyValue $tapeSupport
            $unsupportedReason=$null
            if (-not $support.CanBuild) {$unsupportedReason=$support.Reason}
            $job | Add-Member -NotePropertyName Unsupported -NotePropertyValue $unsupportedReason
            $jobs.Add($job)
        }
    }
    $script:Total=$jobs.Count
    Write-Event 'QUEUE' ('{0} input set(s) found. Checking grouping and output paths.' -f $script:Total)
    $targets=@{}; $checked=0
    Show-PreparationProgress 'Checking game names' 'Checking grouping and output paths.' 0 $jobs.Count 'sets' -Force
    foreach ($job in $jobs) {
        try {Assert-GameStem $job.Stem} catch {$job.Error=$_.Exception.Message}
        $key=$job.System+'/'+$job.Stem
        if ($targets.ContainsKey($key)) {$targets[$key].Error='Several inputs map to the same game.'; $job.Error='Several inputs map to the same game.'}
        else {$targets[$key]=$job}
        $checked++; Show-PreparationProgress 'Checking game names' $job.Source $checked $jobs.Count 'sets'
    }
    $checked=0
    Show-PreparationProgress 'Checking game collections' 'Checking nested game names.' 0 $jobs.Count 'sets'
    foreach ($job in $jobs) {
        $key=$job.System+'/'+$job.Stem
        $parent=$key
        while ($parent.Contains('/')) {
            $parent=$parent.Substring(0,$parent.LastIndexOf('/'))
            $candidates=@($parent)
            foreach ($suffix in '.m3u','.m3u8','.zip') {
                if ($parent.EndsWith($suffix,[StringComparison]::OrdinalIgnoreCase)) {$candidates+=$parent.Substring(0,$parent.Length-$suffix.Length)}
            }
            foreach ($otherKey in $candidates) {
                if ($targets.ContainsKey($otherKey)) {
                    $job.Error='A game output overlaps another game/collection. Rename the input game or collection.'; $targets[$otherKey].Error=$job.Error
                }
            }
        }
        $checked++; Show-PreparationProgress 'Checking game collections' $job.Source $checked $jobs.Count 'sets'
    }
    $checked=0
    Show-PreparationProgress 'Planning game outputs' 'Reading archive directories and media names.' 0 $jobs.Count 'sets'
    foreach ($job in $jobs) {
        $job | Add-Member -NotePropertyName OutputPlan -NotePropertyValue $null
        if ($job.Error -or $job.Unsupported) {
            $checked++; Show-PreparationProgress 'Planning game outputs' $job.Source $checked $jobs.Count 'sets'; continue
        }
        Show-PreparationProgress 'Planning game outputs' $job.Source $checked $jobs.Count 'sets'
        try {
            $script:DiskExtensions=@($job.Profile.Extensions)
            $media=Get-GameMediaNames $job $Storage
            if ($media.DiskNames.Count -gt 0) {$job.OutputPlan=Get-PlaylistOutputPlan $job $sourceRoot $destRoot $Storage $media}
        } catch {$job.Error=$_.Exception.Message}
        $checked++; Show-PreparationProgress 'Planning game outputs' $job.Source $checked $jobs.Count 'sets'
    }
    Set-PlaylistOutputConflicts $jobs.ToArray()
    $sourcePlan=New-SourcePolicyPlan (Join-Path $Root 'SRC') $SourcePolicy
    $sourceIndex=0
    Show-PreparationProgress 'Checking source dependencies' 'Recording originals and shared tracks.' 0 $jobs.Count 'sets'
    foreach ($job in $jobs) {
        $job | Add-Member -NotePropertyName SourceId -NotePropertyValue ([string]$sourceIndex)
        $sourceIndex++
        try {$sourcePaths=@(Get-JobSourcePaths $job)}
        catch {
            $sourcePaths=@($job.Disks | ForEach-Object {$_.Path})
            if ($job.Zip) {$sourcePaths=@($job.Zip)}
            $sourcePlan.BlockReason='Source references could not all be resolved; originals kept for this batch. '+$_.Exception.Message
        }
        Add-SourcePolicyJob $sourcePlan $job.SourceId $sourcePaths
        Show-PreparationProgress 'Checking source dependencies' $job.Source $sourceIndex $jobs.Count 'sets'
    }
    Complete-PreparationProgress
    foreach ($job in $jobs) {
        Set-ApplicationCurrentJob $job.Source
        $profile=$job.Profile; $script:DiskExtensions=@($profile.Extensions)
        $script:UiGame=$job.Stem; $script:UiSystem=$job.System; $script:UiLastStage=''
        Write-Event 'GAME' ('{0}/{1} | {2}/{3}' -f ($script:Processed+1),$script:Total,$job.System,$job.Source)
        $destinationRoot=Join-Path $Root 'DST'
        $stageData=$null; $stageM3u=$null; $workData=$null; $commit=$null; $archive=$null; $sourceLock=$null; $items=@()
        $outputDirectoryLocks=New-Object 'System.Collections.Generic.List[System.IDisposable]'
        $zipMode=([bool]$profile.Zip -and $Storage -eq 'Auto' -and [bool]$job.Zip)
        $result=[pscustomobject]@{System=$job.System; Source=$job.Source; Playlist=($job.Stem+$profile.Playlist); DiskImages=0; Result='Failed'; Original='Kept in SRC'; RemovedFiles=0; KeptFiles=0; RemovalFailures=0; Detail=''}
        if ($job.OutputPlan) {
            $result.DiskImages=$job.OutputPlan.DiskNames.Count
            if (-not $job.OutputPlan.IsMulti) {$result.Playlist=''}
        }
        try {
            if ($job.Unsupported) {
                $script:Skipped++; $result.Result='Unsupported'; $result.Detail=$job.Unsupported
                Write-Event 'SKIP' ('NOT BUILT: '+$job.System+'/'+$job.Source+' - '+$result.Detail)
                continue
            }
            if ($job.Error) {throw $job.Error}
            # Inspect names first, before reading/hashing image contents or asking
            # to replace anything. One playable image never needs a playlist.
            $diskNames=@(); $contentNames=@(); $manifest=@{}; $dataHash=$null; $sourceHashes=@{}
            Show-Stage 0.01 'Inspecting game media' ($job.System+'/'+$job.Source)
            if ($job.Zip) {
                $sourceLock=[IO.File]::Open($job.Zip,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                Assert-ArchiveBudget -Stream $sourceLock -Profile Media
                $archive=New-Object IO.Compression.ZipArchive($sourceLock,[IO.Compression.ZipArchiveMode]::Read,$true)
                $diskNames=@(Get-ZipDisks $archive $job.Zip)
                $contentNames=@($archive.Entries | Where-Object {-not $_.FullName.EndsWith('/')} | ForEach-Object {$_.FullName})
            } else {
                $diskNames=@($job.Disks | ForEach-Object {$_.Name})
                $contentNames=@($diskNames)
                foreach ($disk in $job.Disks) {
                    $parent=[IO.Path]::GetDirectoryName($disk.Path)
                    if ([IO.Path]::GetExtension($disk.Name) -eq '.cue') {$contentNames+=@(Get-CueFiles $disk.Path)}
                    $contentNames+=@(Get-SbiCompanions $disk.Path | ForEach-Object {$_.Name})
                }
            }
            $result.DiskImages=$diskNames.Count
            if ($diskNames.Count -eq 0) {
                $script:Skipped++; $result.Result='Skipped'; $result.Playlist=''; $result.Detail='No supported media images for this system. Use one game per ZIP.'
                Write-Event 'SKIP' ($job.System+'/'+$job.Source+' - no supported media images.'); continue
            }
            $isMulti=$diskNames.Count -gt 1
            if ($isMulti) {
                $tapeIssue=Get-TapeSupportIssue $diskNames $job.TapeSupport
                if ($tapeIssue) {
                    $script:Skipped++; $result.Result='Unsupported'; $result.Detail=$tapeIssue
                    Write-Event 'UNSUPPORTED' ($job.Source+' / '+$tapeIssue); continue
                }
            } else {$result.Playlist=''}
            $plan=$job.OutputPlan
            if ($null -eq $plan -or
                [string]::Join([char]0,[string[]]$diskNames) -cne [string]::Join([char]0,[string[]]$plan.DiskNames) -or
                [string]::Join([char]0,[string[]]$contentNames) -cne [string]::Join([char]0,[string[]]$plan.ContentNames)) {
                throw 'Source media names changed after output planning. Original kept; rerun the batch.'
            }
            $singleFile=$plan.SingleFile;$dataFolder=$plan.DataFolder;$relativeData=$plan.RelativeData
            $dataPath=$plan.DataPath;$m3uPath=$plan.M3uPath;$retired=@($plan.Retired)
            $paths=@($plan.Writes)+@($plan.Retired)+@($plan.VisibleCandidates)
            foreach ($target in $paths) {Assert-PlainOutputParents $target.Destination $destinationRoot}
            Assert-NoMediaNesting $job $destinationRoot $zipMode $profile.Playlist
            Write-Log ('GAME: '+$job.System+'/'+$job.Source)
            $conflicts=@($paths | Where-Object {Test-Path -LiteralPath $_.Destination})
            $overwrite=$false
            if ($conflicts.Count -gt 0) {
                $overwrite=Confirm-Overwrite (($conflicts | ForEach-Object {$_.Destination}) -join "`n                  ") (@($conflicts | Where-Object {$_.Folder}).Count -gt 0)
                if (-not $overwrite) {
                    $result.Result='Skipped'; $result.Detail='Overwrite declined; no media content copied or compared.'; $script:Skipped++
                    Write-Event 'SKIP' ($job.System+'/'+$job.Source+' - original kept; output not compared or copied.'); continue
                }
            }
            $expectedNames=@($contentNames)+@($contentNames | ForEach-Object {if ([IO.Path]::GetExtension($_) -in '.nib','.nbz') {[IO.Path]::ChangeExtension($_,'.g64')}})
            Assert-PlaylistOutputOwnership $plan $expectedNames
            foreach ($path in @($dataPath,$m3uPath)) {
                $parent=[IO.Path]::GetDirectoryName($path); $parentAnchor=$parent
                while (-not (Test-Path -LiteralPath $parentAnchor)) {$parentAnchor=[IO.Path]::GetDirectoryName($parentAnchor)}
                $outputDirectoryLocks.Add((Open-SourcePolicyDirectoryLease $parentAnchor))
                [void][IO.Directory]::CreateDirectory($parent)
                if ($parent -ne $parentAnchor) {$outputDirectoryLocks.Add((Open-SourcePolicyDirectoryLease $parent))}
            }
            $stageData=Join-Path ([IO.Path]::GetDirectoryName($dataPath)) ('.m3u_'+[Guid]::NewGuid().ToString('N')+'.tmp')
            if ($isMulti) {$stageM3u=Join-Path ([IO.Path]::GetDirectoryName($m3uPath)) ('.m3u_'+[Guid]::NewGuid().ToString('N')+'.tmp')}
            Write-Event 'MEDIA COUNT' ('{0} playable image(s); {1}' -f $diskNames.Count,$(if ($isMulti) {'multi-media playlist'} else {'single-media game; no playlist'}))
            if ($job.Zip) {
                $sourceLock.Position=0; $sourceHash=Get-StreamHash $sourceLock $job.Source
                $sourceHashes[[IO.Path]::GetFullPath($job.Zip)]=$sourceHash
                $hasNib=@($diskNames | Where-Object {[IO.Path]::GetExtension($_) -in '.nib','.nbz'}).Count -gt 0
                if ($zipMode -and -not $hasNib) {
                    $manifest=Read-ZipContents $archive '' $job.Zip
                    $archive.Dispose(); $archive=$null; $sourceLock.Position=0
                    $dest=$null
                    try {
                        $dest=[IO.File]::Open($stageData,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
                        $dataHash=Copy-Stream $sourceLock $dest $sourceLock.Length $job.Source 0.60 0.25
                    } finally {if ($dest) {$dest.Dispose()}}
                    if ($dataHash -ne $sourceHash -or (Get-VerifiedHash -LiteralPath $stageData -Algorithm SHA256).Hash -ne $sourceHash) {throw 'ZIP copy differs from source.'}
                } else {
                    $workData=$stageData
                    if ($zipMode) {$workData=$stageData+'.folder'}
                    [void][IO.Directory]::CreateDirectory($workData)
                    $manifest=Read-ZipContents $archive $workData $job.Zip
                    $archive.Dispose(); $archive=$null
                    Assert-FolderManifest $workData $manifest
                    if ($hasNib) {
                        $diskNames=@(Convert-NibSet $diskNames $workData)
                        $manifest=Get-FolderManifest $workData
                    }
                    Assert-CueTargets $diskNames $workData
                    if ($zipMode) {
                        New-OutputZip $workData $stageData
                        $checkZip=Open-ArchiveWithBudget -Path $stageData -Profile Media
                        try {
                            $checkManifest=Read-ZipContents $checkZip '' $stageData
                            if ($checkManifest.Count -ne $manifest.Count) {throw 'Repacked ZIP file count mismatch.'}
                            foreach ($name in $manifest.Keys) {if (-not $checkManifest.ContainsKey($name) -or $manifest[$name].Hash -ne $checkManifest[$name].Hash) {throw "Repacked ZIP content mismatch: $name"}}
                        } finally {$checkZip.Dispose()}
                        $dataHash=(Get-VerifiedHash -LiteralPath $stageData -Algorithm SHA256).Hash
                    }
                }
                $sourceLock.Position=0
                if ((Get-StreamHash $sourceLock $job.Source) -ne $sourceHash) {throw 'Source ZIP changed during processing.'}
                Write-Event 'CHECK' 'Source ZIP is unchanged; verified against its starting SHA-256.'
            } else {
                [void][IO.Directory]::CreateDirectory($stageData)
                $manifest=Copy-LooseSet $job $stageData $sourceHashes
                Assert-FolderManifest $stageData $manifest
                $diskNames=@($job.Disks | ForEach-Object {$_.Name})
                if (@($diskNames | Where-Object {[IO.Path]::GetExtension($_) -in '.nib','.nbz'}).Count -gt 0) {
                    $diskNames=@(Convert-NibSet $diskNames $stageData)
                    $manifest=Get-FolderManifest $stageData
                }
                Assert-CueTargets $diskNames $stageData
            }
            $result.DiskImages=$diskNames.Count
            if ($singleFile) {
                $stagedFile=Join-Path $stageData $diskNames[0].Replace('/',[IO.Path]::DirectorySeparatorChar)
                $items=@([pscustomobject]@{Staged=$stagedFile;Destination=$dataPath;Folder=$false;Hash=$manifest[$diskNames[0]].Hash})
            } else {
                $items=@([pscustomobject]@{Staged=$stageData;Destination=$dataPath;Folder=$dataFolder;Hash=$dataHash;Manifest=$manifest})
            }
            if ($isMulti) {
                New-Playlist $diskNames $job.Stem $stageM3u $zipMode
                $items+=[pscustomobject]@{Staged=$stageM3u;Destination=$m3uPath;Folder=$false;Hash=(Get-VerifiedHash -LiteralPath $stageM3u -Algorithm SHA256).Hash}
            }
            # Recheck folder boundaries immediately before the transaction.
            Assert-PlaylistOutputOwnership $plan $expectedNames
            Show-Stage 0.95 'Installing verified game output' $job.Source
            $commit=Install-PlaylistSet $items $null $false $overwrite $retired
            Complete-SourcePolicyJob $sourcePlan $job.SourceId $sourceHashes $items
            Complete-ApplicationCurrentJob
            $result.Result='Written'; if ($commit.Replaced) {$result.Result='Overwritten'}
            $script:Ok++; $script:UiMood='happy'; $script:UiPercent=100
            if ($isMulti) {
                $result.Detail='Playlist and hidden media verified.'
                $script:UiSay='Playlist and disk images installed. Verification complete.'; $script:UiStage='Playlist ready'
                Write-Event 'READY' ('{0}/{1}{2} - {3} image(s)' -f $job.System,$job.Stem,$profile.Playlist,$diskNames.Count)
            } else {
                $result.Detail='Single-media game verified and installed visibly in DST; no playlist.'
                $script:UiSay='Single-media game installed. No playlist needed.'; $script:UiStage='Game ready'
                Write-Event 'READY' ($job.System+'/'+$relativeData+' - single-media game; no playlist')
            }
            Draw-DisplayPanel -Force
            Write-Event 'MEDIA' $relativeData
        } catch {
            $script:Failed++; $result.Result='Failed'; $result.Detail=$_.Exception.Message
            $script:UiMood='oops'; $script:UiSay='Processing failed. Source files are preserved.'
            Write-Event 'FAILED' ('{0}/{1} - {2}' -f $job.System,$job.Source,$result.Detail)
        } finally {
            if ($archive) {$archive.Dispose()}
            if ($sourceLock) {$sourceLock.Dispose()}
            if ($commit) {foreach ($lock in $commit.Locks) {$lock.Dispose()}}
            foreach ($path in @($stageData,$stageM3u,$workData)) {
                if ($path -and (Test-Path -LiteralPath $path)) {
                    $retain=$false
                    foreach ($item in $items) {
                        if ($item.PreserveStaging -and (Test-OutputPathOverlap $path $item.Staged)) {$retain=$true; break}
                    }
                    if ($retain) {Write-Event 'WARNING' ('Recovery output retained: '+$path); continue}
                    try {Remove-SourcePolicyOwnedPath $path ([IO.Path]::GetDirectoryName($path))}
                    catch {Write-Event 'WARNING' ('Temporary output retained: '+$path+' / '+$_.Exception.Message)}
                }
            }
            foreach ($directoryLock in $outputDirectoryLocks) {$directoryLock.Dispose()}
            Write-Log ('{0}: {1}/{2} | {3}' -f $result.Result,$job.System,$job.Source,$result.Detail)
            $results.Add($result); $script:Processed++
        }
    }
    if ($SourcePolicy -eq 'Remove') {Write-Event 'CLEANUP' 'Rechecking installed outputs and original hashes before removal.'}
    Invoke-SourcePolicyCleanup $sourcePlan {param($kind,$message) Write-Event $kind $message} {param($stage,$detail,$done,$total) Show-SourceCleanupProgress $stage $detail $done $total}
    $sourceSummary=Get-SourcePolicySummary $sourcePlan
    for ($i=0; $i -lt $jobs.Count; $i++) {
        $status=Get-SourcePolicySummary $sourcePlan $jobs[$i].SourceId
        $results[$i].Original=$status.Label; $results[$i].RemovedFiles=$status.Removed
        $results[$i].KeptFiles=$status.Kept; $results[$i].RemovalFailures=$status.Failed
        if ($SourcePolicy -eq 'Remove' -and $status.Kept -gt 0) {
            $reasons=@($sourcePlan.Jobs[$jobs[$i].SourceId].Paths | ForEach-Object {$sourcePlan.Files[$_]} | Where-Object {$_.State -ne 'Removed'} | ForEach-Object {$_.Reason} | Sort-Object -Unique)
            if ($reasons.Count -gt 0) {$results[$i].Detail+=' Originals kept: '+($reasons -join ' | ')}
        }
    }
    $reportSaved=$false
    if ($results.Count -gt 0) {
        $reportPath=[IO.Path]::ChangeExtension($logPath,'.csv')
        $reportParentLease=$null
        try {
            $reportParentLease=Open-SourcePolicyDirectoryLease ([IO.Path]::GetDirectoryName($reportPath))
            $results | ConvertTo-SafeReportRow | Export-Csv -LiteralPath $reportPath -NoClobber -NoTypeInformation -Encoding UTF8
            $reportSaved=$true
        } catch {$script:ReportProblem=$true; Write-Event 'WARNING' ('Report could not be saved: '+$_.Exception.Message)}
        finally {if ($reportParentLease) {$reportParentLease.Dispose()}}
    }
    $script:Clock.Stop()
    Show-ClosingPanel -RemovalFailures $sourceSummary.Failed
    foreach ($id in 1,0) {Write-Progress -Id $id -Activity 'Complete' -Completed}
    Write-RetroStripe
    Write-Event 'DONE' ('{0} written | {1} skipped/unsupported | {2} failed' -f $script:Ok,$script:Skipped,$script:Failed)
    if ($script:Failed -eq 0 -and $sourceSummary.Failed -eq 0 -and -not $script:ReportProblem -and $script:Ok -gt 0) {Write-Host ('  '+(Color-Text 'MIO > Processing complete. All queued sets were handled.' '249;172;204'))}
    if (-not (Test-ApplicationWorker)) {
        Write-Host ('  Source policy: '+$SourcePolicy.ToUpperInvariant())
        Write-Host ('  Originals in this batch: {0} removed | {1} kept | {2} removal failures' -f $sourceSummary.Removed,$sourceSummary.Kept,$sourceSummary.Failed)
    }
    Write-Host ('  Elapsed: '+(Format-Duration $script:Clock.Elapsed.TotalSeconds))
    if ($jobs.Count -eq 0) {Write-Host '  No matching input images/ZIPs found in the selected SRC folders.' -ForegroundColor Yellow}
    if (-not (Test-ApplicationWorker) -and $reportSaved) {Write-Host ('  Report: '+$reportPath)}
    if (-not (Test-ApplicationWorker)) {Write-Host ('  Log: '+$logPath)} else {Write-Host '  Waiting for independent verification and publication.'}
    Write-Host ('  Copy the CONTENTS of DST into the SD card Roms/'+$System+' folder.')
    Write-Host '  Include .hidden, then refresh the game list in Onion.'
    if ($script:Failed -gt 0 -or $script:ReportProblem -or $sourceSummary.Failed -gt 0) {$exitCode=1}
    elseif (-not $support.CanBuild -or @($results | Where-Object {$_.Result -eq 'Unsupported'}).Count -gt 0) {$exitCode=2}
} catch {
    $exitCode=1
    Write-Event 'ERROR' $_.Exception.Message
} finally {
    Restore-Display
    foreach ($id in 1,0) {Write-Progress -Id $id -Activity 'Complete' -Completed}
    if ($script:Log) {try {$script:Log.Dispose()} catch {$exitCode=1}}
}
if (-not $NoPause) {[void](Read-Host 'Press Enter to exit')}
exit $exitCode
