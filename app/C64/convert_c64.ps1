#requires -Version 5.1
param(
    [Parameter(Position=0)][string]$Root,
    [ValidateSet('Keep', 'Remove', 'Folders')][string]$Mode,
    [ValidateSet('Keep','Remove')][string]$SourcePolicy,
    [ValidateSet('Ask', 'Overwrite', 'Skip')][string]$Existing = 'Ask',
    [switch]$NoPause,
    [switch]$NoAnimation,
    [string]$OnionRoot,
    [switch]$NoColor,
    [ValidateSet('CRT','Smooth')][string]$DisplayEffect='CRT'
)

$script:ConverterVersion = '2.1'
$script:AppVersion = '1.0.0'

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'
$ScriptDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$NibConv = Join-Path $ScriptDir 'tools/nibconv.exe'
. (Join-Path $ScriptDir 'source_policy.ps1')
. (Join-Path $ScriptDir 'overwrite_prompt.ps1')
. (Join-Path $ScriptDir 'media_validation.ps1')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Native output callbacks run in C#, with no PowerShell runspace dependency.
if (-not ('PpNibProgress.Capture' -as [type])) {
    Add-OptiMiyooType -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Concurrent;
using System.Diagnostics;
namespace PpNibProgress {
    public sealed class Capture : IDisposable {
        public readonly ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
        public readonly Process Child = new Process();
        public Capture(string exe, string input, string output) {
            string directory = Path.GetDirectoryName(Path.GetFullPath(input));
            if (!String.Equals(directory, Path.GetDirectoryName(Path.GetFullPath(output)), StringComparison.OrdinalIgnoreCase))
                throw new IOException("Native NIB input and output must share the isolated staging directory.");
            Child.StartInfo = new ProcessStartInfo {
                FileName = exe, WorkingDirectory = directory,
                Arguments = "-v \"" + Path.GetFileName(input) + "\" \"" + Path.GetFileName(output) + "\"",
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true,
                RedirectStandardInput = true
            };
            Child.OutputDataReceived += (s, e) => { if (e.Data != null) Lines.Enqueue(e.Data); };
            Child.ErrorDataReceived += (s, e) => { if (e.Data != null) Lines.Enqueue(e.Data); };
            try {
                if (!Child.Start()) throw new Exception("Could not start nibconv.");
                Child.StandardInput.Close();
                Child.BeginOutputReadLine(); Child.BeginErrorReadLine();
            } catch { Dispose(); throw; }
        }
        public string NextLine() { string line; return Lines.TryDequeue(out line) ? line : null; }
        public void Dispose() {
            try { if (!Child.HasExited) { Child.Kill(); Child.WaitForExit(); } } catch { }
            Child.Dispose();
        }
    }
}
'@
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
    Write-Host @PSBoundParameters
}

function Get-C64SourceZips([string]$Directory) {
    $pending=New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Directory); [long]$found=0
    while ($pending.Count -gt 0) {
        $directoryPath=$pending.Pop()
        Show-PreparationProgress 'Scanning SRC' $directoryPath $found -1 'ZIPs'
        foreach ($item in @(Get-ChildItem -LiteralPath $directoryPath -Force | Sort-Object Name)) {
            Show-PreparationProgress 'Scanning SRC' $item.Name $found -1 'ZIPs'
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Write-Event 'WARNING' ('IGNORED LINK: '+$item.FullName)
                continue
            }
            if ($item.PSIsContainer) {$pending.Push($item.FullName)}
            elseif ($item.Extension -ieq '.zip') {$found++; $item}
        }
    }
}

function Get-C64OutputPlan([string]$RelativeZip,[int]$Images,[string]$Storage,[string]$DestinationRoot) {
    $relative=$RelativeZip.Replace('\','/')
    $stem=$relative.Substring(0,$relative.Length-[IO.Path]::GetExtension($relative).Length)
    $multi=$Images -gt 1
    $folder=$Storage -eq 'Folders'
    $relativeData=$stem
    if ($multi) {$relativeData='.hidden/'+$stem}
    if (-not $folder) {$relativeData+='.zip'}
    $targets=@(
        [pscustomobject]@{Name=$stem+'.zip';Folder=$false;Role='Visible'}
        [pscustomobject]@{Name=$stem;Folder=$true;Role='Visible'}
        [pscustomobject]@{Name=$stem+'.m3u';Folder=$false;Role='Playlist'}
        [pscustomobject]@{Name='.hidden/'+$stem+'.zip';Folder=$false;Role='Hidden'}
        [pscustomobject]@{Name='.hidden/'+$stem;Folder=$true;Role='Hidden'}
    )
    foreach ($target in $targets) {
        $target | Add-Member NoteProperty Destination ([IO.Path]::GetFullPath((Join-Path $DestinationRoot $target.Name.Replace('/',[IO.Path]::DirectorySeparatorChar))))
    }
    $data=@($targets | Where-Object {$_.Name -eq $relativeData})[0]
    $playlist=@($targets | Where-Object {$_.Role -eq 'Playlist'})[0]
    $retired=@($targets | Where-Object {$_.Name -ne $relativeData -and (-not $multi -or $_.Role -ne 'Playlist')})
    $depth=@($stem.Split('/')).Count-1
    return [pscustomobject]@{Stem=$stem;Destination=$data.Destination;Playlist=$playlist.Destination;
        RelativeData=$relativeData;RelativePlaylist=($stem+'.m3u');MediaPath=(('../'*$depth)+$relativeData);
        Targets=$targets;Retired=$retired;Multi=$multi;Folder=$folder}
}

function Set-C64OutputConflicts([object[]]$Jobs,[string]$SourcePrefix,[string]$DestinationRoot,[string]$Storage) {
    # Reserve installation AND retirement paths before processing any source.
    # A hidden-data collision must never be resolved by processing order.
    $owners=@{}; $planned=0
    Show-PreparationProgress 'Planning game outputs' 'Collecting installation and retirement paths.' 0 $Jobs.Count 'ZIPs'
    foreach ($job in $Jobs) {
        $relative=$job.Zip.FullName.Substring($SourcePrefix.Length).Replace('\','/')
        $job.Plan=Get-C64OutputPlan $relative $job.Images $Storage $DestinationRoot
        $planned++; Show-PreparationProgress 'Planning game outputs' $relative $planned $Jobs.Count 'ZIPs'
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
            foreach ($job in $participants) {$job.ScanError='Source ZIPs share an output or obsolete-output path. Rename the conflicting game or collection; no conflicting outputs were written.'}
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

function Get-C64OwnedPlaylist([string]$Path,[string]$Stem) {
    $names=New-Object 'System.Collections.Generic.List[string]'
    if (-not (Test-Path -LiteralPath $Path)) {return ,$names.ToArray()}
    $item=Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Existing playlist is a link or has the wrong type; output left alone.'}
    $depth=@($Stem.Split('/')).Count-1
    $prefix=('../'*$depth)+'.hidden/'+$Stem
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) {continue}
        if ($line.StartsWith($prefix+'/',[StringComparison]::Ordinal)) {$name=$line.Substring($prefix.Length+1)}
        elseif ($line.StartsWith($prefix+'.zip#',[StringComparison]::Ordinal)) {$name=$line.Substring($prefix.Length+5)}
        else {throw 'Existing playlist does not belong exclusively to this game; output left alone.'}
        Assert-C64MediaName $name
        Assert-PlaylistName $name
        if ([IO.Path]::GetExtension($name) -ne '.g64') {throw 'Existing playlist contains unexpected media; output left alone.'}
        $names.Add($name)
    }
    if ($names.Count -eq 0) {throw 'Existing playlist is empty; output left alone.'}
    return ,$names.ToArray()
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
    } else {
        $archive=[IO.Compression.ZipFile]::OpenRead($Target.Destination)
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
        if (Test-Path -LiteralPath $target.Destination) {
            $item=Get-Item -LiteralPath $target.Destination -Force
            if ([bool]$item.PSIsContainer -ne [bool]$target.Folder -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw ('Existing output is a link or has the wrong type: '+$target.Destination)}
        }
    }
    $oldNames=Get-C64OwnedPlaylist $Plan.Playlist $Plan.Stem
    $allowed=@($IncomingNames)+@($oldNames)
    foreach ($target in $Plan.Targets) {
        if ($target.Role -eq 'Playlist' -or -not (Test-Path -LiteralPath $target.Destination)) {continue}
        $names=Get-C64ExistingMedia $target $IncomingFiles
        $retiring=-not $target.Destination.Equals($Plan.Destination,[StringComparison]::OrdinalIgnoreCase)
        if ($retiring -and $names.Count -eq 0) {throw ('Cannot establish ownership of obsolete output; output left alone: '+$target.Destination)}
        foreach ($name in $names) {
            # Direct overwrite may replace a game's top-level disk names. An
            # inferred retirement or nested disk must match known game media.
            if (($retiring -or $name.Contains('/')) -and $name -notin $allowed) {
                throw ('Existing output contains media outside this game layout; output left alone: '+$target.Destination)
            }
        }
    }
    # A collection cannot be written underneath another game's media folder.
    Assert-C64CollectionOutput $null $Plan.Playlist $DestinationRoot
}

function Assert-C64CollectionOutput([string]$CollectionPath,[string]$PlaylistPath,[string]$DestinationRoot,[string[]]$ExpectedMedia) {
    # Older releases could put another game's playlist inside the directory
    # treated as this game's legacy output. Never migrate/delete a collection.
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
    if ($PlaylistPath) {
        # In folder mode, a child set would be written inside an existing
        # parent game's hidden media. Block that case before either is touched.
        $parent=[IO.Path]::GetDirectoryName($PlaylistPath)
        while ($parent -and -not $parent.Equals($DestinationRoot,[StringComparison]::OrdinalIgnoreCase)) {
            $parentPlaylist=$parent+'.m3u'
            if (Test-Path -LiteralPath $parentPlaylist -PathType Leaf) {
                throw ('This collection is already used by another game playlist. Rename the game or collection; existing files were left alone: '+$parentPlaylist)
            }
            if (Test-Path -LiteralPath $parent -PathType Container) {
                foreach ($entry in @(Get-ChildItem -LiteralPath $parent -Force)) {
                    if (-not $entry.PSIsContainer -and $entry.Extension -in '.g64','.nib','.nbz') {
                        throw ('This collection already contains a parent game disk. Rename the game or collection; existing files were left alone: '+$entry.FullName)
                    }
                }
            }
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

function Copy-WithProgress {
    param([IO.Stream]$InputStream, [IO.Stream]$OutputStream,
          [long]$Before, [long]$TotalBytes, [double]$Base, [double]$Weight,
          [string]$Stage, [string]$Name, [object]$ExpectedCrc=$null)
    $crc=$null; if ($null -ne $ExpectedCrc) {$crc=New-Object OptiMiyoo.ZipCrc32}
    $buffer = New-Object byte[] 262144
    [long]$copied = 0
    while (($read = $InputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
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

function Expand-ZipWithProgress([string]$ZipPath, [string]$Directory) {
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $checksums=Get-ZipChecksums $ZipPath $archive.Entries.Count
        $entryIndex=0
        $prefix = [IO.Path]::GetFullPath($Directory) + [IO.Path]::DirectorySeparatorChar
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [long]$totalBytes = 0
        foreach ($entry in $archive.Entries) { $totalBytes += $entry.Length }
        [long]$done = 0
        foreach ($entry in $archive.Entries) {
            $expectedCrc=$checksums[$entryIndex]; $entryIndex++
            $relative = $entry.FullName.Replace('\', '/').Replace('/', [IO.Path]::DirectorySeparatorChar)
            if ($relative.Contains(':') -or [IO.Path]::IsPathRooted($relative)) { throw 'Unsafe ZIP entry path.' }
            $target = [IO.Path]::GetFullPath((Join-Path $Directory $relative))
            if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'ZIP entry leaves temporary folder.' }
            if (-not $seen.Add($target)) { throw "Duplicate ZIP entry: $($entry.FullName)" }
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                if ($entry.Length -ne 0 -or $expectedCrc -ne 0) {throw ('ZIP directory entry contains data or an invalid checksum: '+$entry.FullName)}
                [void][IO.Directory]::CreateDirectory($target)
                continue
            }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            $source = $null; $dest = $null
            try {
                $source = $entry.Open()
                $dest = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
                $copied = Copy-WithProgress $source $dest $done $totalBytes 0 0.15 'Extracting ZIP' $entry.FullName $expectedCrc
                if ($copied -ne $entry.Length) { throw "Incomplete extraction: $($entry.FullName)" }
                $done += $copied
            } finally {
                if ($dest) { $dest.Dispose() }; if ($source) { $source.Dispose() }
            }
            [IO.File]::SetLastWriteTimeUtc($target, $entry.LastWriteTime.UtcDateTime)
        }
    } finally { $archive.Dispose() }
    Show-Progress 0.15 'Extracting ZIP' 'Extraction complete' 100 -Force
}

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
    $capture = New-Object PpNibProgress.Capture($NibConv, $InputPath, $OutputPath)
    $phase = 'Starting'; [double]$fraction = 0; $trackDetail = 'waiting for nibconv output'
    $conversionProblem = $null
    $diskClock = [Diagnostics.Stopwatch]::StartNew()
    try {
        do {
            $finished = $capture.Child.HasExited
            if ($finished) { $capture.Child.WaitForExit() }
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
        if ($capture.Child.ExitCode -ne 0) { throw "nibconv exit code $($capture.Child.ExitCode)." }
        if ($conversionProblem) { throw $conversionProblem }
        if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { throw 'nibconv produced no G64 output. See the log for its messages.' }
        Assert-G64 $OutputPath
        Show-Progress (0.15 + 0.65 * (($Index + 1) / $Count)) 'Converting disk images' `
            ('Disk {0}/{1} complete: {2}' -f ($Index + 1), $Count, $DisplayName) 100 -Force
    } finally { $capture.Dispose() }
}

function New-ZipWithProgress([string]$Directory, [string]$Destination) {
    $files = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force)
    $dirs = @(Get-ChildItem -LiteralPath $Directory -Recurse -Directory -Force)
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
    $archive = [IO.Compression.ZipFile]::OpenRead($Destination)
    try {
        $checksums=Get-ZipChecksums $Destination $archive.Entries.Count
        $entryIndex=0
        if ($archive.Entries.Count -ne $expected.Count) { throw 'Output ZIP entry count mismatch.' }
        [long]$done = 0
        foreach ($entry in $archive.Entries) {
            $expectedCrc=$checksums[$entryIndex]; $entryIndex++
            if (-not $expected.ContainsKey($entry.FullName)) { throw 'Unexpected ZIP entry.' }
            $item = $expected[$entry.FullName]
            if ($entry.Length -ne $item.Length) { throw "ZIP length mismatch: $($entry.FullName)" }
            if ($null -eq $item.Hash) {
                if ($expectedCrc -ne 0) {throw ('ZIP directory CRC mismatch: '+$entry.FullName)}
                continue
            }
            $source = $null; $sha = $null; $hashStream = $null
            try {
                $source = $entry.Open(); $sha = [Security.Cryptography.SHA256]::Create()
                $hashStream = New-Object Security.Cryptography.CryptoStream([IO.Stream]::Null, $sha, [Security.Cryptography.CryptoStreamMode]::Write)
                $done += Copy-WithProgress $source $hashStream $done $totalBytes 0.95 0.04 'Verifying output ZIP' $entry.FullName $expectedCrc
                $hashStream.FlushFinalBlock()
                $actual = [BitConverter]::ToString($sha.Hash).Replace('-', '')
                if ($actual -ne $item.Hash) { throw "ZIP content mismatch: $($entry.FullName)" }
            } finally {
                if ($hashStream) { $hashStream.Dispose() }; if ($sha) { $sha.Dispose() }; if ($source) { $source.Dispose() }
            }
        }
    } finally { $archive.Dispose() }
}

function New-FolderWithProgress([string]$Directory, [string]$Destination) {
    $files = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force)
    $dirs = @(Get-ChildItem -LiteralPath $Directory -Recurse -Directory -Force)
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
    if (@(Get-ChildItem -LiteralPath $Destination -Recurse -File -Force).Count -ne $files.Count -or
        @(Get-ChildItem -LiteralPath $Destination -Recurse -Directory -Force).Count -ne $dirs.Count) {
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

function Confirm-Overwrite([string]$Destination, [bool]$Folder, [bool]$PlaylistSet=$false) {
    if ($script:ExistingPolicy -eq 'Overwrite') { return $true }
    if ($script:ExistingPolicy -eq 'Skip') { return $false }
    foreach ($id in 2, 1, 0) { Write-Progress -Id $id -Activity 'Waiting for overwrite choice' -Completed }
    $paths=@($Destination -split '\r?\n *')
    $warnings=@('Skip: no conversion or comparison.', 'Skipped originals stay in SRC.')
    if ($Folder) {$warnings+='Replacing this folder replaces ALL contents.'}
    if ($PlaylistSet) {
        $warnings+='Replaces playlist + hidden media together.'
        $warnings+='Replaces obsolete outputs; avoids duplicates.'
    }
    $choices=@('Y Overwrite | N Skip [Enter = N]', 'A Overwrite all | S Skip all | B/Q Cancel')
    $invalid=$false
    $script:Clock.Stop()
    try {
        do {
            $shownWarnings=$warnings
            if ($invalid) {$shownWarnings+='Please enter Y, N, A or S.'}
            $answer=([string](Read-OverwriteChoice 'Commodore 64 / existing output' $paths $shownWarnings $choices 'Overwrite? [Enter = N]')).Trim().ToUpperInvariant()
            switch ($answer) {
                'Y' { return $true }
                'N' { return $false }
                ''  { return $false }
                'B' { return $false }
                'Q' { return $false }
                'A' { $script:ExistingPolicy = 'Overwrite'; return $true }
                'S' { $script:ExistingPolicy = 'Skip'; return $false }
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
        Write-Log ('REMOVED: original ZIP from SRC after verified destination: ' + $SourcePath)
    } catch {
        $script:RemoveFailed++
        Write-Log ('DESTINATION VERIFIED, BUT ORIGINAL KEPT: ' + $_.Exception.Message)
        Write-C64Text ('  ORIGINAL KEPT: {0} - {1}' -f $DisplayName, $_.Exception.Message) -ForegroundColor Yellow
        return $_.Exception.Message
    }
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

function Assert-PlaylistName([string]$Name) {
    # These characters are VICE playlist syntax, not literal filename characters.
    if ($Name.IndexOfAny([char[]]"#|:`r`n") -ge 0) {
        throw "Cannot safely reference this name in a VICE M3U: $Name. Rename it without #, |, colon or line breaks. Original kept."
    }
}

function New-GamePlaylist([string]$Directory, [string]$MediaPath, [string]$Destination, [bool]$Folder) {
    Assert-PlaylistName $MediaPath
    $prefixLength = $Directory.TrimEnd([IO.Path]::DirectorySeparatorChar).Length + 1
    $names = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force |
        Where-Object { $_.Extension -eq '.g64' } |
        ForEach-Object { $_.FullName.Substring($prefixLength).Replace('\', '/') } |
        Sort-Object @{ Expression = { Get-NaturalDiskKey $_ } }, @{ Expression = { $_ } })
    if ($names.Count -lt 2) { throw 'A multi-disk playlist must contain at least two disk images.' }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $names) {
        Assert-PlaylistName $name
        if ($Folder) { $line = $MediaPath + '/' + $name }
        else { $line = $MediaPath + '#' + $name }
        if ([Text.Encoding]::UTF8.GetByteCount($line) -gt 1000) { throw "Playlist path is too long for VICE: $name" }
        $lines.Add($line)
    }
    # UTF-8 without BOM, forward slashes, LF endings, no quotes around spaces.
    [IO.File]::WriteAllText($Destination, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    Write-Log ('PLAYLIST ORDER: ' + ($names -join ' -> '))
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

function Install-PlaylistSet([object[]]$Items, [string]$LegacyPath, [bool]$LegacyFolder, [bool]$Overwrite, [object[]]$Retired=@()) {
    # A playlist and its disk data are one replacement. Roll back both if either
    # install fails; never leave a new playlist pointing at missing/old data.
    $backups = New-Object 'System.Collections.Generic.List[object]'
    $installed = New-Object 'System.Collections.Generic.List[object]'
    $locks = New-Object 'System.Collections.Generic.List[System.IDisposable]'
    $targets = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $Items) { $targets.Add($item) }
    foreach ($item in $Retired) { $targets.Add($item) }
    if ($LegacyPath) { $targets.Add([pscustomobject]@{ Destination = $LegacyPath; Folder = $LegacyFolder }) }
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
        # Install the whole set before taking them, so a data lease cannot block
        # its playlist's rename. Verify every installed hash while holding those
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
            try { Move-OutputPath $item.Destination $item.Staged ([bool]$item.Folder) }
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
        try { Remove-Item -LiteralPath $item.Backup -Recurse -Force -ErrorAction Stop }
        catch {
            Write-Log ('Previous output backup could not be removed: ' + $item.Backup)
            Write-C64Text ('  Previous output backup remains at: ' + $item.Backup) -ForegroundColor Yellow
        }
    }
    return [pscustomobject]@{ Locks = $locks; Replaced = ($backups.Count -gt 0) }
}


$script:ExistingPolicy = $Existing
$script:Log = $null; $script:ReportProblem=$false; $exitCode = 0
$script:Clock=[Diagnostics.Stopwatch]::StartNew()
$script:Total=0; $script:Processed=0; $script:Ok=0; $script:Skipped=0; $script:Failed=0
. (Join-Path $ScriptDir 'display.ps1')
. (Join-Path $ScriptDir 'core_support.ps1')
try {
    $profileData=Get-Content -LiteralPath (Join-Path $ScriptDir 'systems.json') -Raw | ConvertFrom-Json
    $profile=@($profileData) | Where-Object {$_.Folder -eq 'COMMODORE'}
    $support=Get-PlaylistSupport $profile $OnionRoot
    if (-not $support.CanBuild) {Write-C64Text ('UNSUPPORTED: '+$support.Reason); exit 2}
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
    if ([string]::IsNullOrWhiteSpace($Mode)) {
        do {
            $choice=Read-DisplayInput 'Choose 1, 2, 3 or 4 [Enter = 1]' 'Commodore 64' @(
                '1. ZIP output / KEEP originals in SRC',
                '2. ZIP output / REMOVE originals only after verified success',
                '3. Folder output / KEEP originals in SRC',
                '4. Folder output / REMOVE originals after verified success',
                'B. Back (return to caller)     Q. Exit')
            if ($choice -in 'B','Q') {exit 0}
            if ($choice -in '','1') {$Mode='Keep'}
            elseif ($choice -eq '2') {$Mode='Remove'}
            elseif ($choice -eq '3') {$Mode='Folders'}
            elseif ($choice -eq '4') {$Mode='Folders'; $SourcePolicy='Remove'}
            else {Write-C64Text '  Choose 1, 2, 3, 4, B or Q.'}
        } while ([string]::IsNullOrWhiteSpace($Mode))
    }
    if (-not $SourcePolicy) {$SourcePolicy='Keep'; if ($Mode -eq 'Remove') {$SourcePolicy='Remove'}}
    $removeOriginals=($SourcePolicy -eq 'Remove')
    Write-C64Text ('  Source policy: '+$SourcePolicy.ToUpperInvariant()) -ForegroundColor Cyan
    if ($removeOriginals) {Write-C64Text '  Originals are removed only after ALL their outputs are verified in DST.' -ForegroundColor Magenta}
    else {Write-C64Text '  Originals stay in SRC.' -ForegroundColor Cyan}
    Write-C64Text '  Multi-disk: Game.m3u + .hidden/Game.zip (or a folder in options 3/4).' -ForegroundColor Cyan
    Write-C64Text '  Already-converted G64 ZIPs are supported; nibconv is needed only for NIB/NBZ.'
    Write-C64Text '  Existing outputs: Yes / No / Yes to all / No to all (all modes).'
    Write-C64Text '  No / No to all always keeps the original in SRC; no conversion or comparison.'
    Write-C64Text '  Queue progress counts completed ZIPs. Copy/verify progress measures bytes.'
    Write-C64Text '  NIB conversion shows current phase/track activity while the engine runs.'
    Write-C64Text '  Ctrl+C stops the run. All completed outputs remain in DST.'
    Write-C64Text ''
    $script:Clock = [Diagnostics.Stopwatch]::StartNew()
    Show-ConversionStart 'Commodore 64 / NIB -> G64'
    $zips = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    Get-C64SourceZips $sourceRoot | ForEach-Object {$zips.Add($_)}
    Show-PreparationProgress 'Scanning SRC' 'Source ZIP list collected.' $zips.Count $zips.Count 'ZIPs' -Force
    $script:Total = $zips.Count; $script:TotalImages = 0
    $jobs = New-Object 'System.Collections.Generic.List[object]'
    Show-PreparationProgress 'Counting disk images inside ZIPs' 'Reading archive directories.' 0 $zips.Count 'ZIPs'
    for ($i = 0; $i -lt $zips.Count; $i++) {
        Show-PreparationProgress 'Counting disk images inside ZIPs' $zips[$i].Name $i $zips.Count 'ZIPs'
        $archive = $null; $count = 0; $nibCount = 0; $scanError = $null
        try {
            $archive = [IO.Compression.ZipFile]::OpenRead($zips[$i].FullName)
            foreach ($entry in $archive.Entries) {
                if (-not ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\'))) {
                    $extension = [IO.Path]::GetExtension($entry.FullName)
                    if ($extension -in '.nib', '.nbz', '.g64') { $count++ }
                    if ($extension -in '.nib', '.nbz') { $nibCount++ }
                } elseif ($entry.Length -ne 0) {throw ('ZIP directory entry contains data: '+$entry.FullName)}
            }
        } catch { $scanError = $_.Exception.Message }
        finally { if ($archive) { $archive.Dispose() } }
        $script:TotalImages += $count
        $jobs.Add([pscustomobject]@{ Zip = $zips[$i]; Images = $count; NibImages = $nibCount; ScanError = $scanError; Plan = $null })
        Show-PreparationProgress 'Counting disk images inside ZIPs' $zips[$i].Name ($i+1) $zips.Count 'ZIPs'
    }

    Set-C64OutputConflicts $jobs.ToArray() $sourcePrefix $destinationRoot $Mode
    Complete-PreparationProgress
    Write-Event 'FOUND' ('{0:N0} ZIP files and {1:N0} NIB/NBZ/G64 disk images.' -f $script:Total, $script:TotalImages)
    if ($script:Total -gt 0) {
        $logName = 'OptiMiyoo_C64_{0}_{1}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), $PID
        try { $logPath = Join-Path $Root $logName; $script:Log = New-Object IO.StreamWriter($logPath, $false, [Text.Encoding]::UTF8) }
        catch { $logPath = Join-Path ([IO.Path]::GetTempPath()) $logName; $script:Log = New-Object IO.StreamWriter($logPath, $false, [Text.Encoding]::UTF8) }
        $script:Log.AutoFlush = $true
        Write-Log ('OptiMiyoo v{0} | Commodore 64 workflow v{1} | Mode: {2}' -f $script:AppVersion,$script:ConverterVersion,$Mode)
    Write-Log ('Source policy: '+$SourcePolicy)
        $script:Processed = 0; $script:Ok = 0; $script:Skipped = 0; $script:Failed = 0; $script:SavedImages = 0
        $script:Removed = 0; $script:RemoveFailed = 0
        $script:Overwritten = 0; $script:Playlists = 0
        $script:NoImages = 0; $script:Declined = 0
        $results = New-Object 'System.Collections.Generic.List[object]'
        $script:LastDraw = -1000
        $script:Clock.Restart()
        foreach ($job in $jobs) {
            $zip = $job.Zip
            $relativeZip = $zip.FullName.Substring($sourcePrefix.Length)
            $plan=$job.Plan
            $relativeOutput=$plan.RelativeData
            $isMulti=$plan.Multi
            $destination=$plan.Destination
            $playlistPath=$null; $relativePlaylist=''; $mediaPath=$plan.MediaPath
            if ($isMulti) {$playlistPath=$plan.Playlist; $relativePlaylist=$plan.RelativePlaylist}
            $script:ZipName = $relativeZip; $script:ZipFraction = 0
            $script:UiLastStage=''
            Write-Event 'GAME' ('{0}/{1} | {2}' -f ($script:Processed+1),$script:Total,$relativeZip)
            $tempBase = $null; $newZip = $null; $newFolder = $null; $newM3u = $null; $playlistCommit = $null
            $sourceLease=$null
            $overwrite = $false; $existingOutput = $false
            $removedBefore = $script:Removed
            $result = [pscustomobject]@{
                Source = $relativeZip; Destination = $relativeOutput; Playlist = $relativePlaylist; DiskImages = $job.Images
                Result = 'Failed'; Original = 'Kept in SRC'; Detail = ''
            }
            try {
                Show-Progress 0 'Opening ZIP' $zip.FullName -1 -Force
                Write-Log ('ZIP: ' + $zip.FullName)
                if (-not $destination.StartsWith($destinationPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Destination leaves DST.' }
                if ($playlistPath -and -not $playlistPath.StartsWith($destinationPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Playlist leaves DST.' }
                if ($job.ScanError) { throw $job.ScanError }
                if ($job.Images -eq 0) {
                    $script:Skipped++; $script:NoImages++
                    $result.Result = 'Skipped'; $result.Detail = 'No NIB/NBZ/G64 images; original kept.'
                    Write-Log ('SKIPPED: no NIB/NBZ/G64 images; original kept: ' + $relativeZip)
                    Write-Event 'SKIP' ('{0} - no NIB/NBZ/G64 images; original kept in SRC.' -f $relativeZip)
                    continue
                }
                Assert-PlainOutputParents $destination $destinationRoot
                if ($playlistPath) { Assert-PlainOutputParents $playlistPath $destinationRoot }
                $conflicts=@($plan.Targets | Where-Object {Test-Path -LiteralPath $_.Destination} | ForEach-Object {$_.Destination})
                $existingOutput = $conflicts.Count -gt 0
                if ($existingOutput) {
                    $overwrite = Confirm-Overwrite ($conflicts -join "`n                  ") ($Mode -eq 'Folders') $isMulti
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
                if ($job.NibImages -gt 0 -and -not (Test-Path -LiteralPath $NibConv -PathType Leaf)) {
                    throw 'This ZIP contains NIB/NBZ images. Restore app/tools/nibconv.exe, then retry. Original kept.'
                }
                $zip.Refresh(); $sourceLength = $zip.Length; $sourceTime = $zip.LastWriteTimeUtc
                $sourceHash = $null
                if ($removeOriginals) {
                    $sourceLease=Open-SourcePolicyReadLease $zip.FullName $sourceRoot
                    $sourceHash = (Get-FileHash -LiteralPath $zip.FullName -Algorithm SHA256).Hash
                }
                $tempBase = Join-Path ([IO.Path]::GetTempPath()) ('ppg_' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
                $extractDir = Join-Path $tempBase 'extract'
                [void][IO.Directory]::CreateDirectory($extractDir)
                Expand-ZipWithProgress $zip.FullName $extractDir
                $nibs = @(Get-ChildItem -LiteralPath $extractDir -Recurse -File -Force |
                    Where-Object { $_.Extension -in '.nib', '.nbz' } | Sort-Object FullName)
                if ($nibs.Count -ne $job.NibImages) { throw 'ZIP changed since scanning; run again.' }
                $outputs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                foreach ($nib in $nibs) {
                    $g64 = [IO.Path]::ChangeExtension($nib.FullName, '.g64')
                    if ((Test-Path -LiteralPath $g64) -or -not $outputs.Add($g64)) { throw "Conflicting G64 filename: $($nib.Name). Source ZIP preserved." }
                }
                for ($i = 0; $i -lt $nibs.Count; $i++) {
                    $nib = $nibs[$i]
                    Assert-NibSource $nib.FullName
                    # Short arguments avoid nibconv's legacy filename buffers.
                    $shortInput = Join-Path $tempBase ('input' + $nib.Extension)
                    $shortOutput = Join-Path $tempBase 'output.g64'
                    [IO.File]::Copy($nib.FullName, $shortInput)
                    try { Invoke-NibConversion $shortInput $shortOutput $i $nibs.Count $nib.Name }
                    catch { throw ('Conversion failed for {0}: {1}' -f $nib.Name, $_.Exception.Message) }
                    [IO.File]::Move($shortOutput, [IO.Path]::ChangeExtension($nib.FullName, '.g64'))
                    [IO.File]::Delete($shortInput)
                }
                foreach ($nib in $nibs) { [IO.File]::Delete($nib.FullName) }
                $g64s = @(Get-ChildItem -LiteralPath $extractDir -Recurse -File -Force | Where-Object { $_.Extension -eq '.g64' })
                if ($g64s.Count -ne $job.Images) { throw 'Disk image count changed since scanning; output cancelled.' }
                foreach ($g64 in $g64s) { Assert-G64 $g64.FullName }
                $extractPrefix=$extractDir.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
                $expectedMedia=@($g64s | ForEach-Object {$_.FullName.Substring($extractPrefix.Length).Replace('\','/')})
                $expectedFiles=@(Get-ChildItem -LiteralPath $extractDir -Recurse -File -Force | ForEach-Object {$_.FullName.Substring($extractPrefix.Length).Replace('\','/')})
                Assert-C64OwnedOutputs $plan $expectedMedia $destinationRoot $expectedFiles
                $zip.Refresh()
                if ($zip.Length -ne $sourceLength -or $zip.LastWriteTimeUtc -ne $sourceTime) { throw 'Source ZIP changed during processing; save cancelled.' }
                $destinationDirectory = [IO.Path]::GetDirectoryName($destination)
                [void][IO.Directory]::CreateDirectory($destinationDirectory)
                if ($Mode -eq 'Folders') {
                    $newFolder = Join-Path $destinationDirectory ('.ppg_' + [Guid]::NewGuid().ToString('N') + '.tmp')
                    $folderManifest=New-FolderWithProgress $extractDir $newFolder
                } else {
                    $newZip = Join-Path $destinationDirectory ('.ppg_' + [Guid]::NewGuid().ToString('N') + '.tmp')
                    New-ZipWithProgress $extractDir $newZip
                    $newZipHash = (Get-FileHash -LiteralPath $newZip -Algorithm SHA256).Hash
                }
                $zip.Refresh()
                if ($zip.Length -ne $sourceLength -or $zip.LastWriteTimeUtc -ne $sourceTime) { throw 'Source ZIP changed during processing; save cancelled.' }
                if ($isMulti) {
                    $playlistDirectory = [IO.Path]::GetDirectoryName($playlistPath)
                    [void][IO.Directory]::CreateDirectory($playlistDirectory)
                    $newM3u = Join-Path $playlistDirectory ('.ppg_' + [Guid]::NewGuid().ToString('N') + '.tmp')
                    New-GamePlaylist $extractDir $mediaPath $newM3u ($Mode -eq 'Folders')
                    $m3uHash = (Get-FileHash -LiteralPath $newM3u -Algorithm SHA256).Hash
                    $stagedData = $newZip; $dataHash = $null
                    if ($Mode -eq 'Folders') { $stagedData = $newFolder }
                    else { $dataHash = $newZipHash }
                    $installItems = @(
                        [pscustomobject]@{ Staged = $stagedData; Destination = $destination; Folder = ($Mode -eq 'Folders'); Hash = $dataHash; Manifest = $folderManifest }
                        [pscustomobject]@{ Staged = $newM3u; Destination = $playlistPath; Folder = $false; Hash = $m3uHash }
                    )
                    Show-Progress 0.99 'Saving verified playlist and hidden disks' $relativePlaylist -1 -Force
                    Assert-C64OwnedOutputs $plan $expectedMedia $destinationRoot $expectedFiles
                    $playlistCommit = Install-PlaylistSet $installItems $null $false $overwrite $plan.Retired
                }
                # Single-disk outputs keep the existing ZIP/folder layout.
                elseif ($Mode -eq 'Folders') {
                    Show-Progress 0.99 'Saving verified folder to DST' $relativeOutput -1 -Force
                    $folderItem=[pscustomobject]@{Staged=$newFolder;Destination=$destination;Folder=$true;Manifest=$folderManifest}
                    Assert-C64OwnedOutputs $plan $expectedMedia $destinationRoot $expectedFiles
                    $playlistCommit=Install-PlaylistSet @($folderItem) $null $false $overwrite $plan.Retired
                } else {
                    Show-Progress 0.99 'Saving verified ZIP to DST' $relativeOutput -1 -Force
                    $fileItem=[pscustomobject]@{Staged=$newZip;Destination=$destination;Folder=$false;Hash=$newZipHash}
                    Assert-C64OwnedOutputs $plan $expectedMedia $destinationRoot $expectedFiles
                    $playlistCommit=Install-PlaylistSet @($fileItem) $null $false $overwrite $plan.Retired
                }
                $didOverwrite = $playlistCommit -and $playlistCommit.Replaced
                if ($didOverwrite) { $script:Overwritten++ }
                $result.Result = 'Written'
                $result.Detail = 'New output saved and verified.'
                if ($didOverwrite) { $result.Result = 'Overwritten'; $result.Detail = 'Existing output replaced with verified output.' }
                $script:Ok++; $script:SavedImages += $g64s.Count
                Write-Log ('OK: saved {0} G64 image(s) to {1}' -f $g64s.Count, $destination)
                if ($isMulti) {
                    $script:Playlists++
                    $result.Detail += ' M3U created; disk data in .hidden.'
                    Write-Log ('PLAYLIST: ' + $playlistPath)
                    Write-Event 'READY' ('M3U READY: {0} - {1} disk sides in .hidden.' -f $relativePlaylist, $g64s.Count)
                }
                if ($removeOriginals) {
                    # Release the read lease only when the verified output is held.
                    # Removal acquires its own handle and rechecks the initial hash.
                    $sourceLease.Dispose(); $sourceLease=$null
                    $removeError = Remove-VerifiedSource $zip.FullName $sourceHash $relativeZip
                    if ($removeError) { $result.Detail += ' Original not removed: ' + $removeError }
                } else { Write-Log 'KEPT: original ZIP in SRC' }
                Show-Progress 1 'Complete - saved to DST' $relativeOutput 100 -Force
            } catch {
                $script:Failed++
                $result.Result = 'Failed'; $result.Detail = $_.Exception.Message
                Write-Log ('FAILED: ' + $_.Exception.Message)
                Write-Notice 'FAILED' ('{0} - {1}' -f $zip.Name, $_.Exception.Message)
            } finally {
                if ($sourceLease) {$sourceLease.Dispose()}
                if ($playlistCommit) { foreach ($lock in $playlistCommit.Locks) { $lock.Dispose() } }
                if ($newM3u -and (Test-Path -LiteralPath $newM3u)) { Remove-Item -LiteralPath $newM3u -Force -ErrorAction SilentlyContinue }
                if ($newZip -and (Test-Path -LiteralPath $newZip)) { Remove-Item -LiteralPath $newZip -Force -ErrorAction SilentlyContinue }
                if ($newFolder -and (Test-Path -LiteralPath $newFolder)) { Remove-Item -LiteralPath $newFolder -Recurse -Force -ErrorAction SilentlyContinue }
                if ($tempBase -and (Test-Path -LiteralPath $tempBase)) { Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue }
                if ($script:Removed -gt $removedBefore) { $result.Original = 'Removed from SRC' }
                $results.Add($result)
                $script:Processed++
            }
        }
        $script:Clock.Stop()
        $reportPath = [IO.Path]::ChangeExtension($logPath, '.csv')
        $reportSaved=$false
        try {
            $results | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
            $reportSaved=$true
        } catch {
            $script:ReportProblem=$true
            Write-Notice 'WARNING' ('Could not save CSV report: '+$_.Exception.Message)
        }
        Show-ClosingPanel -RemovalFailures $script:RemoveFailed
        foreach ($id in 2, 1, 0) { Write-Progress -Id $id -Activity 'Complete' -Completed }
        Write-C64Text ''
        Write-RetroStripe
        Write-C64Text '  FINISHED - 100% of ZIPs processed' -ForegroundColor Cyan
        Write-C64Text ('  Total source ZIPs: {0:N0}' -f $script:Total) -ForegroundColor White
        Write-C64Text ('  Outputs written: {0:N0} (new: {1:N0}, overwritten: {2:N0})' -f $script:Ok, ($script:Ok - $script:Overwritten), $script:Overwritten) -ForegroundColor Cyan
        Write-C64Text ('  Skipped: {0:N0} (no disk images: {1:N0}; overwrite declined: {2:N0})' -f $script:Skipped, $script:NoImages, $script:Declined) -ForegroundColor Yellow
        Write-C64Text ('  Multi-disk M3U playlists written: {0:N0}' -f $script:Playlists) -ForegroundColor Cyan
        Write-C64Text ('  Failed: {0:N0}' -f $script:Failed) -ForegroundColor Magenta
        Write-C64Text ('  Disk images saved: {0:N0}/{1:N0}   Elapsed: {2}' -f $script:SavedImages, $script:TotalImages, (Format-Duration $script:Clock.Elapsed.TotalSeconds)) -ForegroundColor Gray
        Write-C64Text ('  Source policy: '+$SourcePolicy.ToUpperInvariant())
        Write-C64Text ('  Originals removed from SRC: {0:N0}   Kept in SRC: {1:N0}   Removal failures: {2:N0}' -f $script:Removed, ($script:Total - $script:Removed), $script:RemoveFailed) -ForegroundColor White
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
        if ($reportSaved) {Write-C64Text "`n  Results for EVERY source ZIP: $reportPath" -ForegroundColor Cyan}
        if ($script:ReportProblem) {Write-C64Text '  Reporting failed. Conversion results above may be incomplete in the log or CSV.' -ForegroundColor Yellow}
        Write-C64Text "  Output: $destinationRoot"
        Write-C64Text "  Log: $logPath"
        if ($script:Failed -gt 0) { $exitCode = 1; Write-C64Text '  Failed conversions keep their original ZIPs. See the report for details.' -ForegroundColor Magenta }
        if ($script:RemoveFailed -gt 0 -or $script:ReportProblem) { $exitCode = 1 }
    } else {
        Show-ClosingPanel -RemovalFailures $script:RemoveFailed
        Write-Event 'EMPTY' ("No ZIP files found in SRC. Put your ZIPs in: $sourceRoot")
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
