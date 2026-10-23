# ZIP payloads run in a separate AppContainer. The trusted host keeps planning,
# names, destination transactions and original-file removal outside the worker.
. (Join-Path $PSScriptRoot 'native_process.ps1')

function Test-ArchiveSandboxSharingFailure($Failure) {
    $exception=$Failure.Exception
    while($exception) {
        if($exception -is [ComponentModel.Win32Exception] -and $exception.NativeErrorCode -in 32,33) {return $true}
        $exception=$exception.InnerException
    }
    return $false
}

function Remove-ArchiveSandboxScratch([string]$Path,[string]$Root) {
    $failure=$null
    for($attempt=0;$attempt -lt 20;$attempt++) {
        try {if([IO.Directory]::Exists($Path)){Remove-SourcePolicyOwnedPath $Path $Root};return}
        catch {$failure=$_;if(-not (Test-ArchiveSandboxSharingFailure $_)){break};Start-Sleep -Milliseconds 50}
    }
    Write-Warning ('Temporary archive helper files were kept at '+$Path+'. '+$failure.Exception.Message)
}

function Get-ArchiveSandboxExecutableBytes {
    if ($script:ArchiveSandboxExecutableBytes) {return ,$script:ArchiveSandboxExecutableBytes}
    $source=@'
using System;
using System.IO;
using System.IO.Compression;
using System.Globalization;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;
internal static class ArchivePayloadWorker {
    private static readonly uint[] Table=MakeTable();
    private static uint[] MakeTable() {uint[] t=new uint[256];for(uint i=0;i<256;i++){uint c=i;for(int b=0;b<8;b++)c=(c>>1)^((c&1)==0?0:0xedb88320U);t[i]=c;}return t;}
    private sealed class Request {internal long Length;internal uint Crc;internal bool Directory;}
    private static int Main(string[] args) {
        try {
            if(args.Length!=1) throw new InvalidDataException("Invalid archive worker arguments.");
            long handle=long.Parse(args[0],CultureInfo.InvariantCulture);
            string[] lines=File.ReadAllLines("request.txt",Encoding.ASCII);
            if(lines.Length<3 || lines.Length>20003 || lines[0]!="OptiMiyooArchive1") throw new InvalidDataException("Invalid archive request.");
            string mode=lines[1];if(mode!="hash" && mode!="extract" && mode!="read") throw new InvalidDataException("Invalid archive operation.");
            int selected=int.Parse(lines[2],CultureInfo.InvariantCulture);Request[] requests=new Request[lines.Length-3];
            if(selected < -1 || selected>=requests.Length || (mode=="read" && selected<0)) throw new InvalidDataException("Invalid archive selection.");
            long declaredTotal=0;
            for(int i=0;i<requests.Length;i++) {
                string[] p=lines[i+3].Split('|');if(p.Length!=3) throw new InvalidDataException("Invalid archive entry request.");
                long length=long.Parse(p[0],CultureInfo.InvariantCulture);uint crc=uint.Parse(p[1],NumberStyles.HexNumber,CultureInfo.InvariantCulture);
                if(length<0 || length>17179869184L || declaredTotal>68719476736L-length || (p[2]!="D" && p[2]!="F")) throw new InvalidDataException("Archive limits exceeded.");
                declaredTotal+=length;requests[i]=new Request{Length=length,Crc=crc,Directory=p[2]=="D"};
            }
            using(FileStream input=new FileStream(new SafeFileHandle(new IntPtr(handle),true),FileAccess.Read))
            using(ZipArchive archive=new ZipArchive(input,ZipArchiveMode.Read,false))
            using(StreamWriter report=new StreamWriter(new FileStream("result.txt",FileMode.CreateNew,FileAccess.Write),new UTF8Encoding(false))) {
                if(archive.Entries.Count!=requests.Length) throw new InvalidDataException("Archive entry count changed.");
                byte[] buffer=new byte[65536];int completed=0;Stopwatch progress=Stopwatch.StartNew();
                for(int index=0;index<requests.Length;index++) {
                    Request request=requests[index];ZipArchiveEntry entry=archive.Entries[index];
                    bool directory=entry.FullName.EndsWith("/",StringComparison.Ordinal)||entry.FullName.EndsWith("\\",StringComparison.Ordinal);
                    if(entry.Length!=request.Length || directory!=request.Directory) throw new InvalidDataException("Archive metadata changed.");
                    if(directory) {if(entry.Length!=0 || request.Crc!=0) throw new InvalidDataException("Invalid ZIP directory data or CRC.");continue;}
                    if(selected>=0 && selected!=index) continue;
                    string output="payload-"+index.ToString("D5",CultureInfo.InvariantCulture)+".bin";
                    long total=0;uint crc=0xffffffffU;
                    using(Stream contents=entry.Open())
                    using(Stream destination=mode=="hash"?Stream.Null:new FileStream(output,FileMode.CreateNew,FileAccess.Write))
                    using(SHA256 sha=SHA256.Create()) {
                        int count;while((count=contents.Read(buffer,0,buffer.Length))>0) {
                            if(count>request.Length-total) throw new InvalidDataException("ZIP entry expanded beyond its declared length.");
                            destination.Write(buffer,0,count);sha.TransformBlock(buffer,0,count,buffer,0);
                            for(int j=0;j<count;j++)crc=Table[(crc^buffer[j])&255]^(crc>>8);
                            total+=count;
                            if(progress.ElapsedMilliseconds>=250) {Console.WriteLine("PROGRESS "+index+" "+total+" "+request.Length);progress.Restart();}
                        }
                        sha.TransformFinalBlock(new byte[0],0,0);
                        if(total!=request.Length || (crc^0xffffffffU)!=request.Crc) throw new InvalidDataException("ZIP entry length or CRC mismatch; original kept.");
                        report.WriteLine(index.ToString(CultureInfo.InvariantCulture)+"|"+total.ToString(CultureInfo.InvariantCulture)+"|"+BitConverter.ToString(sha.Hash).Replace("-",""));
                    }
                    completed++;
                }
                report.WriteLine("DONE|"+completed.ToString(CultureInfo.InvariantCulture));
            }
            return 0;
        } catch(Exception error) {Console.Error.WriteLine("Archive sandbox: "+error.Message);return 1;}
    }
}
'@
    $folder=Join-Path ([IO.Path]::GetTempPath()) ('oa_'+[Guid]::NewGuid().ToString('N').Substring(0,16))
    $process=$null;$started=$false;$parentLease=$null;$folderLease=$null
    try {
        $parentLease=Open-SourcePolicyDirectoryLease ([IO.Path]::GetTempPath())
        [void][IO.Directory]::CreateDirectory($folder)
        $folderLease=Open-SourcePolicyDirectoryLease $folder
        [IO.File]::WriteAllText((Join-Path $folder 'worker.cs'),$source,(New-Object Text.UTF8Encoding($true)))
        $compiler=Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
        if(-not [IO.File]::Exists($compiler)) {$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'}
        if(-not [IO.File]::Exists($compiler)) {throw 'The Windows C# compiler is unavailable; archive sandbox cannot start.'}
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=$compiler;$start.WorkingDirectory=$folder
        $start.Arguments='/nologo /noconfig /optimize+ /target:exe /out:worker.exe /reference:System.dll /reference:System.Core.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll worker.cs'
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $process=New-Object Diagnostics.Process;$process.StartInfo=$start
        $started=$process.Start();if(-not $started) {throw 'Could not compile archive sandbox helper.'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(60000)) {$process.Kill();throw 'Archive sandbox helper compilation timed out.'}
        if($process.ExitCode -ne 0) {throw ('Archive sandbox helper compilation failed: '+$stdout.Result+$stderr.Result)}
        $script:ArchiveSandboxExecutableBytes=[IO.File]::ReadAllBytes((Join-Path $folder 'worker.exe'))
        return ,$script:ArchiveSandboxExecutableBytes
    } finally {
        if($process) {try {if($started -and -not $process.HasExited){$process.Kill();[void]$process.WaitForExit(5000)}}finally{$process.Dispose()}}
        if($folderLease){$folderLease.Dispose()}
        try {Remove-ArchiveSandboxScratch $folder ([IO.Path]::GetTempPath())}finally{if($parentLease){$parentLease.Dispose()}}
    }
}

function Invoke-ArchiveSandbox {
    param([Parameter(Mandatory=$true)][string]$ZipPath,
          [Parameter(Mandatory=$true)][IO.Compression.ZipArchive]$Archive,
          [ValidateSet('Media','Floppy')][string]$Profile='Media',
          [ValidateSet('Hash','Extract','Read','File')][string]$Operation='Hash',
          [int]$EntryIndex=-1,[string]$Destination,[long]$MaximumBytes=16777216,[scriptblock]$Progress=$null)
    if ((Get-Command Test-ApplicationWorker -ErrorAction SilentlyContinue) -and (Test-ApplicationWorker)) {return (Invoke-ApplicationArchive @PSBoundParameters)}
    Initialize-NativeSandbox;Initialize-NativeTextCapture
    $exeBytes=Get-ArchiveSandboxExecutableBytes
    $toolRoot=Join-Path ([IO.Path]::GetTempPath()) ('oas_'+[Guid]::NewGuid().ToString('N').Substring(0,16))
    $job=$null;$readLease=$null;$stdout=$null;$stderr=$null;$destinationLease=$null;$toolParentLease=$null;$toolLease=$null
    try {
        $toolParentLease=Open-SourcePolicyDirectoryLease ([IO.Path]::GetTempPath())
        [void][IO.Directory]::CreateDirectory($toolRoot)
        $toolLease=Open-SourcePolicyDirectoryLease $toolRoot
        $exe=Join-Path $toolRoot 'archive.exe';[IO.File]::WriteAllBytes($exe,$exeBytes)
        $readLease=Open-SourcePolicyReadLease $ZipPath ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ZipPath)))
        Assert-ArchiveBudget -Stream $readLease.Stream -Profile $Profile
        $checksums=Get-ZipChecksums $ZipPath $Archive.Entries.Count
        if($EntryIndex -lt -1 -or $EntryIndex -ge $Archive.Entries.Count) {throw 'Invalid ZIP entry selection.'}
        if($Operation -in 'Read','File' -and ($EntryIndex -lt 0 -or $MaximumBytes -lt 1 -or $Archive.Entries[$EntryIndex].Length -gt $MaximumBytes)) {throw 'ZIP entry exceeds its supported size limit.'}
        if($Operation -eq 'Read' -and $Archive.Entries[$EntryIndex].Length -gt 16MB) {throw 'ZIP text entry exceeds the bounded in-memory read limit.'}
        $job=[OptiMiyoo.NativeSandboxJob]::Create($exe,[string[]]@(),$null,$null,$false)
        $job.CpuTimeLimitSeconds=1800
        $job.WallTimeLimitSeconds=1800
        $inherited=$job.AddReadHandle($readLease.Stream.SafeFileHandle)
        $request=New-Object 'System.Collections.Generic.List[string]'
        $workerOperation=$Operation.ToLowerInvariant();if($Operation -eq 'File'){$workerOperation='extract'}
        $request.Add('OptiMiyooArchive1');$request.Add($workerOperation);$request.Add([string]$EntryIndex)
        foreach($entry in $Archive.Entries) {
            $directory=$entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')
            $kind='F';if($directory){$kind='D'}
            $request.Add(('{0}|{1:X8}|{2}' -f $entry.Length,$checksums[$request.Count-3],$kind))
        }
        [IO.File]::WriteAllLines((Join-Path $job.WorkPath 'request.txt'),$request,[Text.Encoding]::ASCII)
        $job.Start([string]$inherited)
        $stdout=New-Object OptiMiyoo.NativeTextCapture($job.StandardOutput,1048576)
        $stderr=New-Object OptiMiyoo.NativeTextCapture($job.StandardError,1048576)
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while(-not $job.WaitForExit(100)) {
            while($null -ne ($line=$stdout.NextLine())) {
                if($Progress -and $line -match '^PROGRESS ([0-9]{1,5}) ([0-9]{1,11}) ([0-9]{1,11})$') {
                    $progressIndex=[int]$Matches[1];$progressBytes=[long]$Matches[2];$progressLength=[long]$Matches[3]
                    if($progressIndex -lt $Archive.Entries.Count -and $progressBytes -le $progressLength -and $progressLength -le 17179869184) {& $Progress $progressIndex $Archive.Entries.Count $progressBytes $progressLength | Out-Null}
                }
            }
            while($null -ne $stderr.NextLine()) {}
            if($clock.Elapsed.TotalMinutes -gt 30) {throw 'Archive sandbox exceeded its 30-minute time limit.'}
            if($stdout.LimitExceeded -or $stderr.LimitExceeded) {throw 'Archive sandbox diagnostic limit exceeded.'}
        }
        if(-not $stdout.Wait(5000) -or -not $stderr.Wait(5000) -or $stdout.Failure -or $stderr.Failure -or $stdout.LimitExceeded -or $stderr.LimitExceeded) {throw 'Archive sandbox diagnostic capture failed.'}
        if($job.ExitCode -ne 0) {throw ('Archive sandbox failed: '+$stderr.Text())}
        $report=Join-Path $job.WorkPath 'result.txt'
        $reportLease=Open-SourcePolicyReadLease $report $job.WorkPath
        $rows=New-Object 'System.Collections.Generic.Dictionary[int,object]'
        try {
            if($reportLease.Stream.Length -gt 2097152) {throw 'Archive sandbox result exceeded its limit.'}
            $reader=New-Object IO.StreamReader($reportLease.Stream,[Text.Encoding]::UTF8,$true,4096,$true)
            try {
                $done=$false
                while($null -ne ($line=$reader.ReadLine())) {
                    if($done) {throw 'Archive sandbox returned trailing results.'}
                    if($line -match '^DONE\|([0-9]{1,5})$') {if([int]$Matches[1] -ne $rows.Count){throw 'Archive sandbox result count mismatch.'};$done=$true;continue}
                    if($line -notmatch '^([0-9]{1,5})\|([0-9]{1,11})\|([0-9A-F]{64})$') {throw 'Archive sandbox returned an invalid result.'}
                    $index=[int]$Matches[1];$length=[long]$Matches[2];$hash=$Matches[3]
                    if($index -ge $Archive.Entries.Count -or ($EntryIndex -ge 0 -and $index -ne $EntryIndex) -or $rows.ContainsKey($index)) {throw 'Archive sandbox returned an unexpected entry.'}
                    $entry=$Archive.Entries[$index]
                    if($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\') -or $entry.Length -ne $length) {throw 'Archive sandbox returned mismatched entry metadata.'}
                    $rows.Add($index,[pscustomobject]@{Length=$length;Hash=$hash})
                }
                if(-not $done) {throw 'Archive sandbox result was incomplete.'}
            } finally {$reader.Dispose()}
        } finally {$reportLease.Dispose()}
        $expected=@($Archive.Entries | Where-Object {-not $_.FullName.EndsWith('/') -and -not $_.FullName.EndsWith('\')}).Count
        if($EntryIndex -ge 0) {$expected=1}
        if($rows.Count -ne $expected) {throw 'Archive sandbox did not verify all requested payloads.'}
        if($Operation -eq 'Extract') {
            if([string]::IsNullOrWhiteSpace($Destination)) {throw 'An extraction destination is required.'}
            [void][IO.Directory]::CreateDirectory($Destination)
            $destinationLease=Open-SourcePolicyDirectoryLease $Destination
            $prefix=[IO.Path]::GetFullPath($Destination).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
            $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            $directoryNames=New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach($entry in $Archive.Entries) {
                $normalized=$entry.FullName.Replace('\','/').TrimEnd('/')
                $parts=$normalized.Split('/')
                foreach($part in $parts) {
                    if([string]::IsNullOrEmpty($part) -or $part -in '.','..' -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '[<>:"|?*\x00-\x1f]' -or $part -match '^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(?:\.|$)') {throw 'ZIP entry has an unsafe Windows path component.'}
                }
                $directoryCount=$parts.Length-1;if($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')){$directoryCount=$parts.Length}
                for($partIndex=1;$partIndex -le $directoryCount;$partIndex++) {
                    $directoryName=$parts[0..($partIndex-1)] -join '/'
                    if($directoryNames.ContainsKey($directoryName)) {if($directoryNames[$directoryName] -cne $directoryName){throw 'ZIP directory names differ only by letter case.'}}
                    else {$directoryNames.Add($directoryName,$directoryName)}
                }
                $relative=$normalized.Replace('/',[IO.Path]::DirectorySeparatorChar)
                $target=[IO.Path]::GetFullPath((Join-Path $Destination $relative))
                if([IO.Path]::IsPathRooted($relative) -or $relative.Contains(':') -or -not $target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or -not $seen.Add($target)) {throw 'Unsafe or duplicate ZIP entry path.'}
                Assert-PlainOutputParents $target $Destination
                if($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {[void][IO.Directory]::CreateDirectory($target)}
            }
        }
        if($Operation -eq 'File') {
            $destinationParent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Destination))
            $destinationLease=Open-SourcePolicyDirectoryLease $destinationParent
            Assert-PlainOutputParents $Destination $destinationParent
        }
        $manifest=@{};$readBytes=$null
        foreach($index in $rows.Keys) {
            $entry=$Archive.Entries[$index];$row=$rows[$index]
            if($Operation -ne 'Hash') {
                $payload=Join-Path $job.WorkPath ('payload-{0:D5}.bin' -f $index)
                $payloadLease=Open-SourcePolicyReadLease $payload $job.WorkPath
                try {
                    if($payloadLease.Stream.Length -ne $row.Length) {throw 'Archive sandbox payload length mismatch.'}
                    $actual=[OptiMiyoo.SourceRemovalLeaseV128]::HashStream($payloadLease.Stream,$null)
                    if($actual -cne $row.Hash) {throw 'Archive sandbox payload hash mismatch.'}
                    $payloadLease.Stream.Position=0
                    if($Operation -eq 'Read') {
                        $memory=New-Object IO.MemoryStream
                        try {$payloadLease.Stream.CopyTo($memory);$readBytes=$memory.ToArray()} finally {$memory.Dispose()}
                    } else {
                        if([string]::IsNullOrWhiteSpace($Destination)) {throw 'An extraction destination is required.'}
                        if($Operation -eq 'File') {$target=[IO.Path]::GetFullPath($Destination)} else {
                            $name=$entry.FullName.Replace('\','/');$relative=$name.Replace('/',[IO.Path]::DirectorySeparatorChar)
                            $prefix=[IO.Path]::GetFullPath($Destination).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
                            $target=[IO.Path]::GetFullPath((Join-Path $Destination $relative))
                            if([IO.Path]::IsPathRooted($relative) -or $relative.Contains(':') -or -not $target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'ZIP entry leaves its extraction folder.'}
                            Assert-PlainOutputParents $target $Destination
                        }
                        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                        $targetParentLease=Open-SourcePolicyDirectoryLease ([IO.Path]::GetDirectoryName($target));$output=$null
                        try {
                            $output=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                            $buffer=New-Object byte[] 1048576;$copied=0L;$copyClock=[Diagnostics.Stopwatch]::StartNew()
                            while(($count=$payloadLease.Stream.Read($buffer,0,$buffer.Length)) -gt 0) {
                                $output.Write($buffer,0,$count);$copied+=$count
                                if($Progress -and $copyClock.ElapsedMilliseconds -ge 250){& $Progress $index $Archive.Entries.Count $copied $row.Length | Out-Null;$copyClock.Restart()}
                            }
                            if($copied -ne $row.Length){throw 'Archive sandbox payload import was incomplete.'}
                            $output.Dispose();$output=$null
                            [IO.File]::SetLastWriteTimeUtc($target,$entry.LastWriteTime.UtcDateTime)
                        } finally {if($output){$output.Dispose()};$targetParentLease.Dispose()}
                    }
                } finally {$payloadLease.Dispose()}
            }
            $manifest[$entry.FullName.TrimEnd('/','\')]=[pscustomobject]@{Length=$row.Length;Hash=$row.Hash}
        }
        if($Operation -eq 'Read') {return ,$readBytes}
        return $manifest
    } finally {
        if($job) {Close-NativeSandboxJob $job}
        if($stdout) {$stdout.Dispose()};if($stderr) {$stderr.Dispose()}
        if($readLease) {$readLease.Dispose()}
        if($destinationLease) {$destinationLease.Dispose()}
        if($toolLease){$toolLease.Dispose()}
        try {Remove-ArchiveSandboxScratch $toolRoot ([IO.Path]::GetTempPath())}finally{if($toolParentLease){$toolParentLease.Dispose()}}
    }
}

function Read-SandboxedZipText([string]$ZipPath,[IO.Compression.ZipArchive]$Archive,[IO.Compression.ZipArchiveEntry]$Entry,[long]$MaximumBytes=1048576) {
    if($MaximumBytes -lt 1 -or $Entry.Length -gt $MaximumBytes) {throw 'ZIP text entry exceeds its supported size limit.'}
    $index=$Archive.Entries.IndexOf($Entry)
    if(-not [object]::ReferenceEquals($script:ArchiveTextCacheArchive,$Archive)) {
        $script:ArchiveTextCacheArchive=$Archive;$script:ArchiveTextCache=@{};$script:ArchiveTextCacheBytes=0L
    }
    if($script:ArchiveTextCache.ContainsKey($index)) {return $script:ArchiveTextCache[$index]}
    $bytes=Invoke-ArchiveSandbox -ZipPath $ZipPath -Archive $Archive -Operation Read -EntryIndex $index -MaximumBytes $MaximumBytes
    $memory=New-Object IO.MemoryStream(,$bytes)
    try {
        $text=Read-OptiBoundedText $memory $MaximumBytes ('CUE '+$Entry.FullName) $Entry.Length
        if(($script:ArchiveTextCacheBytes+2L*$text.Length) -le 16MB) {$script:ArchiveTextCache[$index]=$text;$script:ArchiveTextCacheBytes+=2L*$text.Length}
        return $text
    }
    finally {$memory.Dispose()}
}
