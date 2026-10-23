# The host keeps publication authority. No function in this file is an RPC verb
# accepting an arbitrary host pathname, script, command, or deletion request.
# Installed planning/ownership helpers remain trusted, bounded parsing code.
. (Join-Path $PSScriptRoot 'source_policy.ps1')
. (Join-Path $PSScriptRoot 'core_support.ps1')
. (Join-Path $PSScriptRoot 'archive_limits.ps1')
. (Join-Path $PSScriptRoot 'native_process.ps1')
. (Join-Path $PSScriptRoot 'archive_sandbox.ps1')

if (-not (Get-Variable ApplicationBrokerStates -Scope Script -ErrorAction SilentlyContinue)) {$script:ApplicationBrokerStates=@{}}
if (-not (Get-Variable ApplicationBrokerModules -Scope Script -ErrorAction SilentlyContinue)) {$script:ApplicationBrokerModules=@{}}
$script:ApplicationBrokerCodeRoot=$PSScriptRoot

function Assert-PlainOutputParents([string]$Path,[string]$Root) {
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    while($parent -and $parent.Length -ge $rootFull.Length){
        if(Test-Path -LiteralPath $parent){$item=Get-Item -LiteralPath $parent -Force;if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Broker path parent is a link or is not a directory.'}}
        if($parent.Equals($rootFull,[StringComparison]::OrdinalIgnoreCase)){break}
        $parent=[IO.Path]::GetDirectoryName($parent)
    }
}

function Initialize-ApplicationBrokerNative {
    if ('OptiMiyoo.ApplicationBrokerLease' -as [type]) {return}
    Add-OptiMiyooType -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace OptiMiyoo {
    public sealed class ApplicationBrokerLease : IDisposable {
        [StructLayout(LayoutKind.Sequential)] struct Info {
            public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation,Access,Write;
            public uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;
        }
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
        static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr sa,uint disposition,uint flags,IntPtr template);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle handle,out Info info);
        [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes {public int Length;public IntPtr Descriptor;public int Inherit;}
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl,uint revision,out IntPtr descriptor,out uint size);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateDirectoryW(string path,ref SecurityAttributes attributes);
        [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr pointer);
        readonly List<SafeFileHandle> handles=new List<SafeFileHandle>();
        public static void CreatePrivateDirectory(string path) {
            string sid=System.Security.Principal.WindowsIdentity.GetCurrent().User.Value;
            IntPtr descriptor;uint size;
            if(!ConvertStringSecurityDescriptorToSecurityDescriptorW("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;"+sid+")",1,out descriptor,out size))throw new Win32Exception(Marshal.GetLastWin32Error());
            try {SecurityAttributes attributes=new SecurityAttributes();attributes.Length=Marshal.SizeOf(typeof(SecurityAttributes));attributes.Descriptor=descriptor;
                if(!CreateDirectoryW(path,ref attributes))throw new Win32Exception(Marshal.GetLastWin32Error(),"Could not create private broker publication staging.");
            } finally {LocalFree(descriptor);}
        }
        public static ApplicationBrokerLease Directory(string path) {
            ApplicationBrokerLease lease=new ApplicationBrokerLease();
            try {
                List<string> names=new List<string>(); string current=Path.GetFullPath(path);
                while(!String.IsNullOrEmpty(current)) {names.Add(current);DirectoryInfo p=System.IO.Directory.GetParent(current);current=p==null?null:p.FullName;}
                names.Reverse();
                foreach(string name in names) {
                    SafeFileHandle handle=CreateFileW(name,0x81,1,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
                    if(handle.IsInvalid) {int error=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(error,"Could not pin broker snapshot directory.");}
                    lease.handles.Add(handle);Info info;
                    if(!GetFileInformationByHandle(handle,out info))throw new Win32Exception(Marshal.GetLastWin32Error());
                    if((info.Attributes&0x410)!=0x10)throw new IOException("Broker snapshots do not follow directory links.");
                }
                return lease;
            } catch {lease.Dispose();throw;}
        }
        public static uint LinkCount(SafeFileHandle handle) {Info info;if(!GetFileInformationByHandle(handle,out info))throw new Win32Exception(Marshal.GetLastWin32Error());return info.Links;}
        public void Dispose(){for(int i=handles.Count-1;i>=0;i--)handles[i].Dispose();handles.Clear();}
    }
}
'@
}

function Assert-ApplicationBrokerRelative([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 4096 -or [IO.Path]::IsPathRooted($Name) -or $Name.Contains('\') -or $Name.IndexOfAny([char[]]":`r`n`0") -ge 0) {throw 'Invalid broker relative path.'}
    foreach($part in $Name.Split('/')) {
        if($part -in '', '.', '..' -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') {throw 'Invalid broker relative path component.'}
    }
}

function Get-ApplicationBrokerRelative([string]$Path,[string]$Root) {
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $full=[IO.Path]::GetFullPath($Path)
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Broker path is outside its selected root.'}
    $relative=$full.Substring($prefix.Length).Replace('\','/')
    Assert-ApplicationBrokerRelative $relative
    return $relative
}

function Get-ApplicationBrokerTree([string]$Root,[string]$CopyTo,[switch]$RequireSingleLink,[int]$MaximumEntries=100000,[switch]$MetadataOnly,[hashtable]$ExpectedFiles) {
    Initialize-ApplicationBrokerNative
    $files=@{};$directories=New-Object 'System.Collections.Generic.List[string]';$bytes=0L;$entryCount=0
    if($MaximumEntries -lt 1 -or $MaximumEntries -gt 1000000){throw 'Invalid broker snapshot entry limit.'}
    if($MetadataOnly -and $CopyTo){throw 'A metadata-only inventory cannot copy file data.'}
    if(-not [IO.Directory]::Exists($Root)) {
        if(Test-Path -LiteralPath $Root){throw 'Broker root is not a directory.'}
        if($CopyTo){[void][IO.Directory]::CreateDirectory($CopyTo)}
        return [pscustomobject]@{Exists=$false;Files=$files;Directories=@();Bytes=0L}
    }
    $rootLease=[OptiMiyoo.ApplicationBrokerLease]::Directory($Root)
    $pending=New-Object 'System.Collections.Generic.Queue[string]';$pending.Enqueue([IO.Path]::GetFullPath($Root))
    try {
        if($CopyTo){[void][IO.Directory]::CreateDirectory($CopyTo)}
        while($pending.Count -gt 0) {
            $directory=$pending.Dequeue();$directoryLease=[OptiMiyoo.ApplicationBrokerLease]::Directory($directory)
            try {
                foreach($entryPath in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
                    $entryCount++;if($entryCount -gt $MaximumEntries){throw 'Broker snapshot entry limit exceeded; originals kept.'}
                    $entry=Get-Item -LiteralPath $entryPath -Force -ErrorAction Stop
                    if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Broker snapshot contains a link; originals kept.'}
                    $relative=Get-ApplicationBrokerRelative $entry.FullName $Root
                    if($entry.PSIsContainer){$directories.Add($relative);$pending.Enqueue($entry.FullName);if($CopyTo){[void][IO.Directory]::CreateDirectory((Join-Path $CopyTo $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)))};continue}
                    if($files.ContainsKey($relative)){throw 'Broker snapshot has colliding names.'}
                    $lease=Open-SourcePolicyReadLease $entry.FullName $Root;$output=$null;$sha=$null
                    try {
                        $links=[OptiMiyoo.ApplicationBrokerLease]::LinkCount($lease.Stream.SafeFileHandle)
                        if($RequireSingleLink -and $links -ne 1){throw 'Broker output contains a hard link.'}
                        if($null -ne $ExpectedFiles -and (-not $ExpectedFiles.ContainsKey($relative) -or $ExpectedFiles[$relative].Length -ne $lease.Stream.Length)){throw 'Staged snapshot has unexpected file names or lengths.'}
                        if($MetadataOnly){$files[$relative]=[pscustomobject]@{Hash='';Length=$lease.Stream.Length;Links=$links;LastWriteTimeUtc=$entry.LastWriteTimeUtc};$bytes+=$lease.Stream.Length;continue}
                        if($CopyTo){$target=Join-Path $CopyTo $relative.Replace('/',[IO.Path]::DirectorySeparatorChar);$output=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)}
                        $sha=[Security.Cryptography.SHA256]::Create();$buffer=New-Object byte[] 1048576;$length=0L
                        while(($count=$lease.Stream.Read($buffer,0,$buffer.Length)) -gt 0){if($output){$output.Write($buffer,0,$count)};[void]$sha.TransformBlock($buffer,0,$count,$null,0);$length+=$count}
                        [void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0)
                        if($length -ne $lease.Stream.Length){throw 'Broker snapshot changed while being copied.'}
                        $hash=[BitConverter]::ToString($sha.Hash).Replace('-','')
                        if($output){$output.Flush($true);$output.Dispose();$output=$null;[IO.File]::SetLastWriteTimeUtc($target,$entry.LastWriteTimeUtc)}
                        $files[$relative]=[pscustomobject]@{Hash=$hash;Length=$length;Links=$links;LastWriteTimeUtc=$entry.LastWriteTimeUtc}
                        $bytes+=$length
                    } finally {if($output){$output.Dispose()};if($sha){$sha.Dispose()};$lease.Dispose()}
                }
            } finally {$directoryLease.Dispose()}
        }
    } finally {$rootLease.Dispose()}
    return [pscustomobject]@{Exists=$true;Files=$files;Directories=@($directories.ToArray() | Sort-Object);Bytes=$bytes}
}

function Assert-ApplicationBrokerSnapshot($Expected,$Actual,[string]$Description) {
    if($Expected.Exists -ne $Actual.Exists -or $Expected.Files.Count -ne $Actual.Files.Count -or @($Expected.Directories).Count -ne @($Actual.Directories).Count){throw ($Description+' changed since the batch started.')}
    foreach($name in $Expected.Files.Keys){if(-not $Actual.Files.ContainsKey($name) -or $Expected.Files[$name].Hash -cne $Actual.Files[$name].Hash -or $Expected.Files[$name].Length -ne $Actual.Files[$name].Length){throw ($Description+' changed since the batch started.')}}
    for($i=0;$i -lt @($Expected.Directories).Count;$i++){if($Expected.Directories[$i] -cne $Actual.Directories[$i]){throw ($Description+' directory names changed since the batch started.')}}
}

function Get-ApplicationBrokerState($Session) {
    if($null -eq $Session -or -not $script:ApplicationBrokerStates.ContainsKey([string]$Session.Id)){throw 'Unknown application broker session.'}
    $state=$script:ApplicationBrokerStates[[string]$Session.Id]
    if(-not [object]::ReferenceEquals($state.Handle,$Session) -or $state.Closed){throw 'Application broker session is closed or forged.'}
    return $state
}

function Get-ApplicationBrokerModule([ValidateSet('Playlist','C64','ZX')][string]$Operation) {
    if($script:ApplicationBrokerModules.ContainsKey($Operation)){return $script:ApplicationBrokerModules[$Operation]}
    $relative=@{Playlist='make_playlists.ps1';C64='C64/convert_c64.ps1';ZX='ZX/convert_zx.ps1'}[$Operation]
    $module=New-Module -Name ('OptiMiyooBroker'+$Operation) -ArgumentList @($script:ApplicationBrokerCodeRoot,$relative) -ScriptBlock {
        param($codeRoot,$relative)
        foreach($helper in 'compile_support.ps1','source_policy.ps1','core_support.ps1','archive_limits.ps1','native_process.ps1','archive_sandbox.ps1','media_validation.ps1'){. (Join-Path $codeRoot $helper)}
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $codeRoot $relative),[ref]$tokens,[ref]$errors)
        if($errors.Count){throw 'Installed broker planning helpers failed syntax validation.'}
        # Only top-level definitions from fixed installed paths, never child data.
        foreach($statement in $ast.EndBlock.Statements){if($statement -is [Management.Automation.Language.FunctionDefinitionAst]){. ([scriptblock]::Create($statement.Extent.Text))}}
        function Write-Log {param($Message)}
        function Write-LogFile {param($Message)}
        function Write-Event {param($Label,$Message)}
        function Write-Notice {param($Label,$Message)}
        function Write-Status {param($Kind,$Text)}
        function Write-Diagnostic {param($Text)}
        function Show-PreparationProgress {param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Rest,[switch]$Force)}
        function Show-Stage {param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Rest,[switch]$Force)}
        function Show-Progress {param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Rest,[switch]$Force)}
        function Complete-PreparationProgress {}
        function Draw-DisplayPanel {param([switch]$Force)}
        $script:Clock=[Diagnostics.Stopwatch]::StartNew()
    }
    $script:ApplicationBrokerModules[$Operation]=$module
    return $module
}

function New-ApplicationBrokerSession {
    param([Parameter(Mandatory=$true)][string]$OriginalRoot,[Parameter(Mandatory=$true)][string]$WorkRoot,[string]$OnionRoot)
    $original=[IO.Path]::GetFullPath($OriginalRoot).TrimEnd('\','/');$work=[IO.Path]::GetFullPath($WorkRoot).TrimEnd('\','/')
    if(-not [IO.Directory]::Exists($original)){throw 'Application input root must exist.'}
    if($original.Equals($work,[StringComparison]::OrdinalIgnoreCase) -or $work.StartsWith($original+'\',[StringComparison]::OrdinalIgnoreCase) -or $original.StartsWith($work+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Application broker staging must be separate from the original root.'}
    if(-not [IO.Directory]::Exists($work)){throw 'Application broker staging must be created by the session owner.'}
    Initialize-ApplicationBrokerNative
    $workLease=[OptiMiyoo.ApplicationBrokerLease]::Directory($work)
    try {
        foreach($name in 'SRC','DST'){if(Test-Path -LiteralPath (Join-Path $work $name)){throw 'Application broker needs fresh SRC and DST staging directories.'}}
        $originalLease=[OptiMiyoo.ApplicationBrokerLease]::Directory($original)
        try {foreach($name in 'SRC','DST'){[void][IO.Directory]::CreateDirectory((Join-Path $original $name))}} finally {$originalLease.Dispose()}
        # Inventory before any copy so the accepted snapshot fits the session's
        # bounded cleanup budget, including files and empty directories.
        $sourceInventory=Get-ApplicationBrokerTree (Join-Path $original 'SRC') -MetadataOnly -MaximumEntries 100000
        $sourceCount=$sourceInventory.Files.Count+$sourceInventory.Directories.Count
        $destinationInventory=Get-ApplicationBrokerTree (Join-Path $original 'DST') -MetadataOnly -MaximumEntries ([Math]::Max(1,100000-$sourceCount))
        $destinationCount=$destinationInventory.Files.Count+$destinationInventory.Directories.Count
        if($sourceCount+$destinationCount -gt 100000){throw 'SRC and DST contain more than 100,000 entries. Split this collection into smaller batches.'}
        $source=Get-ApplicationBrokerTree (Join-Path $original 'SRC') (Join-Path $work 'SRC') -MaximumEntries ([Math]::Max(1,$sourceCount)) -ExpectedFiles $sourceInventory.Files
        $destination=Get-ApplicationBrokerTree (Join-Path $original 'DST') (Join-Path $work 'DST') -MaximumEntries ([Math]::Max(1,$destinationCount)) -ExpectedFiles $destinationInventory.Files
        if($source.Files.Count+$source.Directories.Count+$destination.Files.Count+$destination.Directories.Count -gt 100000){throw 'SRC or DST grew beyond the snapshot entry limit; originals kept.'}
    } finally {$workLease.Dispose()}
    $id=[Guid]::NewGuid().ToString('N')+[Guid]::NewGuid().ToString('N')
    $handle=[pscustomobject]@{Id=$id;OriginalRoot=$original;WorkRoot=$work;OnionRoot=$OnionRoot;SourceSnapshot=[pscustomobject]@{FileCount=$source.Files.Count;Bytes=$source.Bytes};DestinationSnapshot=[pscustomobject]@{FileCount=$destination.Files.Count;Bytes=$destination.Bytes};ActiveBatch=$null}
    $script:ApplicationBrokerStates[$id]=[pscustomobject]@{Handle=$handle;Id=$id;OriginalRoot=$original;WorkRoot=$work;OnionRoot=$OnionRoot;SourceSnapshot=$source;DestinationSnapshot=$destination;Batch=$null;Closed=$false}
    return $handle
}

function Get-ApplicationBrokerFile([string]$Path,[string]$Root,[string]$CopyTo,[switch]$SingleLink,[long[]]$AllowedLengths,[switch]$ArchiveBudget) {
    Initialize-ApplicationBrokerNative
    $lease=Open-SourcePolicyReadLease $Path $Root;$output=$null
    try {
        if($SingleLink -and [OptiMiyoo.ApplicationBrokerLease]::LinkCount($lease.Stream.SafeFileHandle) -ne 1){throw 'Sandbox output is a hard link; originals kept.'}
        if($null -ne $AllowedLengths -and $AllowedLengths.Count -gt 0 -and $lease.Stream.Length -notin $AllowedLengths){throw 'Sandbox output length does not match the independently verified content.'}
        if($ArchiveBudget){Assert-ArchiveBudget -Stream $lease.Stream -Profile Media}
        if($CopyTo){$output=[IO.File]::Open($CopyTo,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$lease.Stream.CopyTo($output);$output.Flush($true);$output.Dispose();$output=$null;$lease.Stream.Position=0}
        $hash=[OptiMiyoo.SourceRemovalLeaseV128]::HashStream($lease.Stream,$null)
        return [pscustomobject]@{Hash=$hash;Length=$lease.Stream.Length}
    } finally {if($output){$output.Dispose()};$lease.Dispose()}
}

function Get-ApplicationBrokerArchive($Module,[string]$Path) {
    return (& $Module {param($path)
        $archive=Open-ArchiveWithBudget -Path $path -Profile Media
        try {return Invoke-ArchiveSandbox -ZipPath $path -Archive $archive -Profile Media -Operation Hash}
        finally {$archive.Dispose()}
    } $Path)
}

function Add-ApplicationBrokerExpectedFile([hashtable]$Manifest,[string]$Name,$File,[string]$Converter='') {
    Assert-ApplicationBrokerRelative $Name
    if($Manifest.ContainsKey($Name)){
        if($Manifest[$Name].Hash -cne $File.Hash -or $Manifest[$Name].Length -ne $File.Length){throw 'Two source files map to different content at the same output name.'}
        return
    }
    $Manifest[$Name]=[pscustomobject]@{Hash=[string]$File.Hash;Length=[long]$File.Length;Converter=$Converter;InputHash=[string]$File.Hash}
}

function Get-ApplicationBrokerExpectedFiles($State,$Module,$Job,[switch]$ConvertAllNib) {
    $manifest=@{};$sourceRoot=Join-Path $State.OriginalRoot 'SRC'
    if($Job.Zip){
        $archiveFiles=Get-ApplicationBrokerArchive $Module ([string]$Job.Zip)
        foreach($name in $archiveFiles.Keys){Add-ApplicationBrokerExpectedFile $manifest $name $archiveFiles[$name]}
    } else {
        foreach($disk in $Job.Disks){
            $sources=@([pscustomobject]@{Name=$disk.Name;Path=$disk.Path})
            $sources+=@(& $Module {param($disk)
                $parent=[IO.Path]::GetDirectoryName($disk.Path)
                if([IO.Path]::GetExtension($disk.Name) -eq '.cue'){foreach($name in @(Get-CueFiles $disk.Path)){[pscustomobject]@{Name=$name;Path=(Join-Path $parent $name)}}}
                foreach($sbi in @(Get-SbiCompanions $disk.Path)){[pscustomobject]@{Name=$sbi.Name;Path=$sbi.FullName}}
            } $disk)
            foreach($source in $sources){
                $key=Get-ApplicationBrokerRelative $source.Path $sourceRoot
                if(-not $State.SourceSnapshot.Files.ContainsKey($key)){throw 'A required source file was not present in the frozen snapshot.'}
                Add-ApplicationBrokerExpectedFile $manifest $source.Name $State.SourceSnapshot.Files[$key]
            }
        }
    }
    $toConvert=@($manifest.Keys | Where-Object {[IO.Path]::GetExtension($_) -in '.nib','.nbz'})
    foreach($name in $toConvert){
        if(-not $ConvertAllNib -and $name -notin $Job.OutputPlan.DiskNames){continue}
        $target=[IO.Path]::ChangeExtension($name,'.g64').Replace('\','/')
        if($manifest.ContainsKey($target)){throw 'Converted media would replace another archive member.'}
        $file=$manifest[$name];$manifest.Remove($name);$file.Converter='Nib';$file.Hash='';$file.Length=-1;$manifest[$target]=$file
    }
    return $manifest
}

function New-ApplicationBrokerJob([string]$SourceKey,$SourceJob,$Plan) {
    return [pscustomobject]@{JobId=[Guid]::NewGuid().ToString('N');SourceKey=$SourceKey;ConflictId='';SourceJob=$SourceJob;Plan=$Plan;BlockedReason='';BlockedResult='Failed';Paths=@();SourceHashes=@{};Files=@{};DiskNames=@();Writes=@();Retired=@();Conflicts=@();Decision='Write';PlaylistText=$null;DataKind='';SourceBlockReason='';ContainerHash=''}
}

function Start-ApplicationBrokerBatch {
    param([Parameter(Mandatory=$true)]$Session,[ValidateSet('Playlist','C64','ZX','SD')][string]$Operation,
          [string]$System,[ValidateSet('Auto','Folders')][string]$Storage='Auto',
          [ValidateSet('LooseDSK','ZipDSK')][string]$Format='ZipDSK',
          [ValidateSet('Keep','Remove')][string]$SourcePolicy='Keep',[ValidateSet('Ask','Overwrite','Skip')][string]$Existing='Ask')
    $state=Get-ApplicationBrokerState $Session
    if($state.Batch){throw 'The previous application batch is still active.'}
    if($Operation -eq 'SD'){throw 'SD operations require the dedicated configuration broker.'}
    $src=Join-Path $state.OriginalRoot 'SRC';$dst=Join-Path $state.OriginalRoot 'DST'
    Assert-ApplicationBrokerSnapshot $state.SourceSnapshot (Get-ApplicationBrokerTree $src) 'Original source tree'
    Assert-ApplicationBrokerSnapshot $state.DestinationSnapshot (Get-ApplicationBrokerTree $dst) 'Original output tree'
    Assert-ApplicationBrokerSnapshot $state.SourceSnapshot (Get-ApplicationBrokerTree (Join-Path $state.WorkRoot 'SRC') -MaximumEntries ([Math]::Max(1,$state.SourceSnapshot.Files.Count+$state.SourceSnapshot.Directories.Count)) -ExpectedFiles $state.SourceSnapshot.Files) 'Staged source tree'
    Assert-ApplicationBrokerSnapshot $state.DestinationSnapshot (Get-ApplicationBrokerTree (Join-Path $state.WorkRoot 'DST') -MaximumEntries ([Math]::Max(1,$state.DestinationSnapshot.Files.Count+$state.DestinationSnapshot.Directories.Count)) -ExpectedFiles $state.DestinationSnapshot.Files) 'Staged output tree'
    $sourcePins=New-Object 'System.Collections.Generic.List[IDisposable]'
    try {
    # Bind all trusted parsing to the initial copied bytes. Rehashing before and
    # after parsing alone would permit a change-and-revert race during a ZIP or
    # CUE read, producing a plan unrelated to the source-removal baseline.
    foreach($relative in $state.SourceSnapshot.Files.Keys){
        $path=Join-Path $src $relative
        $sourcePins.Add((Open-VerifiedSourcePolicyFile -Path $path -ExpectedHash $state.SourceSnapshot.Files[$relative].Hash -Root $src -ReadOnly))
    }
    foreach($relative in $state.DestinationSnapshot.Files.Keys){
        $path=Join-Path $dst $relative
        $sourcePins.Add((Open-VerifiedSourcePolicyFile -Path $path -ExpectedHash $state.DestinationSnapshot.Files[$relative].Hash -Root $dst -ReadOnly))
    }
    $module=Get-ApplicationBrokerModule $Operation;$sourceModule=Get-ApplicationBrokerModule 'Playlist'
    $jobs=New-Object 'System.Collections.Generic.List[object]';$profile=$null
    if($Operation -eq 'Playlist'){
        $profiles=Get-Content -LiteralPath (Join-Path $script:ApplicationBrokerCodeRoot 'systems.json') -Raw | ConvertFrom-Json
        $selected=@($profiles | Where-Object {$_.Folder -eq $System})
        if($selected.Count -ne 1){throw 'Unknown application system profile.'};$profile=$selected[0]
        $support=Get-PlaylistSupport $profile $state.OnionRoot
        $tapeSupport=$null;if($System -eq 'COMMODORE'){$tapeSupport=Get-TapeSwapSupport $profile $state.OnionRoot $support}
        $raw=@(& $module {param($src,$profile) $script:DiskExtensions=@($profile.Extensions);Get-Jobs $src $profile} $src $profile)
        if($raw.Count -gt 20000){throw 'This batch contains more than 20,000 jobs. Split the collection into smaller batches.'}
        foreach($sourceJob in $raw){
            $sourceJob | Add-Member NoteProperty Profile $profile
            $sourceJob | Add-Member NoteProperty OutputPlan $null
            $job=New-ApplicationBrokerJob $sourceJob.Source $sourceJob $null
            try {
                if($sourceJob.Error){throw $sourceJob.Error};if(-not $support.CanBuild){$job.BlockedResult='Unsupported';throw $support.Reason}
                & $module {param($stem)Assert-GameStem $stem} $sourceJob.Stem
                $media=& $module {param($job,$storage)Get-GameMediaNames $job $storage} $sourceJob $Storage
                if(@($media.DiskNames).Count -eq 0){$job.BlockedResult='Skipped';throw 'No supported media images for this system.'}
                if(@($media.DiskNames).Count -gt 1){$issue=& $module {param($names,$support)Get-TapeSupportIssue $names $support} $media.DiskNames $tapeSupport;if($issue){$job.BlockedResult='Unsupported';throw $issue}}
                $plan=& $module {param($job,$src,$dst,$storage,$media)Get-PlaylistOutputPlan $job $src $dst $storage $media} $sourceJob $src $dst $Storage $media
                $sourceJob.OutputPlan=$plan;$job.Plan=$plan;$job.Writes=@($plan.Writes);$job.Retired=@($plan.Retired)
                $job.Files=Get-ApplicationBrokerExpectedFiles $state $module $sourceJob
                if($plan.ZipMode -and @($job.Files.Values | Where-Object {$_.Converter}).Count -eq 0){$job.ContainerHash=$state.SourceSnapshot.Files[(Get-ApplicationBrokerRelative $sourceJob.Zip $src)].Hash}
                $job.DiskNames=@($media.DiskNames | ForEach-Object {if([IO.Path]::GetExtension($_) -in '.nib','.nbz'){[IO.Path]::ChangeExtension($_,'.g64').Replace('\','/')}else{$_}})
                $job.DataKind='Folder';if($plan.ZipMode){$job.DataKind='Zip'}elseif($plan.SingleFile){$job.DataKind='File'}
                if($plan.IsMulti){
                    $prefix=('../'*(@($sourceJob.Stem.Split('/')).Count-1))+'.hidden/'+$sourceJob.Stem
                    if($plan.ZipMode){$prefix+='.zip#'}else{$prefix+='/'}
                    $lines=@($job.DiskNames | ForEach-Object {$prefix+$_})
                    foreach($line in $lines){if([Text.Encoding]::UTF8.GetByteCount($line) -gt 1000){throw 'Playlist line exceeds the supported length.'}}
                    $job.PlaylistText=($lines -join "`n")+"`n"
                }
                $job.Conflicts=@(@($plan.Writes)+@($plan.Retired)+@($plan.VisibleCandidates) | Where-Object {Test-Path -LiteralPath $_.Destination})
            } catch {$job.BlockedReason=$_.Exception.Message}
            try {$job.Paths=@(& $module {param($job)Get-JobSourcePaths $job} $sourceJob)} catch {$job.Paths=@($sourceJob.Disks | ForEach-Object {$_.Path});if($sourceJob.Zip){$job.Paths=@($sourceJob.Zip)};$job.SourceBlockReason='Source references could not be resolved.'}
            $jobs.Add($job)
        }
        & $module {param($raw)Set-PlaylistOutputConflicts $raw} $raw
        foreach($job in $jobs){if($job.SourceJob.Error){$job.BlockedReason=$job.SourceJob.Error}}
    } elseif($Operation -eq 'C64'){
        $System='COMMODORE';$raw=New-Object 'System.Collections.Generic.List[object]'
        $sourceZips=@(& $module {param($src)Get-C64SourceZips $src} $src)
        if($sourceZips.Count -gt 20000){throw 'This batch contains more than 20,000 jobs. Split the collection into smaller batches.'}
        foreach($zip in $sourceZips){
            $sourceJob=[pscustomobject]@{Zip=$zip;Images=0;NibImages=0;ScanError='';Plan=$null;Files=@{}}
            try {$sourceJob.Files=Get-ApplicationBrokerArchive $module $zip.FullName;$sourceJob.Images=@($sourceJob.Files.Keys | Where-Object {[IO.Path]::GetExtension($_) -in '.nib','.nbz','.g64'}).Count;$sourceJob.NibImages=@($sourceJob.Files.Keys | Where-Object {[IO.Path]::GetExtension($_) -in '.nib','.nbz'}).Count}
            catch {$sourceJob.ScanError=$_.Exception.Message}
            $raw.Add($sourceJob)
        }
        & $module {param($raw,$src,$dst,$storage)Set-C64OutputConflicts $raw ($src.TrimEnd('\','/')+'\') $dst $storage} $raw.ToArray() $src $dst $Storage
        foreach($sourceJob in $raw){
            $plan=$sourceJob.Plan;$job=New-ApplicationBrokerJob (Get-ApplicationBrokerRelative $sourceJob.Zip.FullName $src) $sourceJob $plan
            $job.Paths=@($sourceJob.Zip.FullName);$job.BlockedReason=$sourceJob.ScanError
            if($sourceJob.Images -eq 0 -and -not $sourceJob.ScanError){$job.BlockedReason='No NIB/NBZ/G64 images.';$job.BlockedResult='Skipped'}
            try {
                foreach($name in $sourceJob.Files.Keys){Add-ApplicationBrokerExpectedFile $job.Files $name $sourceJob.Files[$name]}
                foreach($name in @($job.Files.Keys | Where-Object {[IO.Path]::GetExtension($_) -in '.nib','.nbz'})){
                    $target=[IO.Path]::ChangeExtension($name,'.g64').Replace('\','/');if($job.Files.ContainsKey($target)){throw 'Converted media name collides with existing image.'}
                    $file=$job.Files[$name];$job.Files.Remove($name);$file.Converter='Nib';$file.Hash='';$file.Length=-1;$job.Files[$target]=$file
                }
                $job.DiskNames=@(& $module {param($names)$names | Where-Object {[IO.Path]::GetExtension($_) -eq '.g64'} | Sort-Object @{Expression={Get-NaturalDiskKey $_}},@{Expression={$_}}} @($job.Files.Keys))
                $job.Writes=@([pscustomobject]@{Destination=$plan.Destination;Folder=$plan.Folder})
                if($plan.Multi){$job.Writes+=[pscustomobject]@{Destination=$plan.Playlist;Folder=$false};$separator='#';if($plan.Folder){$separator='/'};$lines=@($job.DiskNames | ForEach-Object {$plan.MediaPath+$separator+$_});foreach($line in $lines){if([Text.Encoding]::UTF8.GetByteCount($line) -gt 1000){throw 'Playlist line exceeds the supported length.'}};$job.PlaylistText=($lines -join "`n")+"`n"}
                $job.Retired=@($plan.Retired);$job.DataKind='Zip';if($plan.Folder){$job.DataKind='Folder'}
                $job.Conflicts=@($plan.Targets | Where-Object {Test-Path -LiteralPath $_.Destination})
            } catch {$job.BlockedReason=$_.Exception.Message}
            $jobs.Add($job)
        }
    } else {
        $System='ZXS';$rawResult=& $module {param($src,$policy,$format)$script:SourceRoot=$src;$script:SourcePolicy=$policy;$script:OutputMode=$format;$items=@(Get-ConversionItems);[pscustomobject]@{Items=$items;Failures=$script:ScanFailures.ToArray();Untouched=$script:UntouchedSources.ToArray();Collisions=@(Get-OutputCollisions $items)}} $src $SourcePolicy $Format
        if(@($rawResult.Items).Count+@($rawResult.Failures).Count+@($rawResult.Untouched).Count -gt 20000){throw 'This batch contains more than 20,000 jobs. Split the collection into smaller batches.'}
        $archives=@{}
        foreach($sourceJob in $rawResult.Items){
            $relative=$sourceJob.RelativeOutput.Replace('\','/');if($Format -eq 'ZipDSK'){$relative=[IO.Path]::ChangeExtension($relative,'.zip').Replace('\','/')}
            Assert-ApplicationBrokerRelative $relative
            $plan=[pscustomobject]@{Destination=(Join-Path $dst $relative);RelativeData=$relative;Folder=$false}
            $job=New-ApplicationBrokerJob $sourceJob.DisplayName $sourceJob $plan;$job.Paths=@($sourceJob.InputPath);$job.SourceBlockReason=$sourceJob.SourceBlockReason
            try {
                $key=Get-ApplicationBrokerRelative $sourceJob.InputPath $src
                $input=$state.SourceSnapshot.Files[$key]
                if($sourceJob.Type -eq 'Zip'){if(-not $archives.ContainsKey($sourceJob.InputPath)){$archives[$sourceJob.InputPath]=Get-ApplicationBrokerArchive $module $sourceJob.InputPath};$input=$archives[$sourceJob.InputPath][$sourceJob.EntryName]}
                if(-not $input){throw 'IPF input was not present in the frozen source manifest.'}
                $name=[IO.Path]::GetFileName($sourceJob.RelativeOutput)
                $job.Files[$name]=[pscustomobject]@{Hash='';Length=-1L;Converter='HxC';InputHash=$input.Hash}
                $job.Writes=@([pscustomobject]@{Destination=$plan.Destination;Folder=$false});$job.DataKind='File';if($Format -eq 'ZipDSK'){$job.DataKind='Zip'}
                if(Test-Path -LiteralPath $plan.Destination){$job.Conflicts=@($job.Writes)}
                if(@($rawResult.Collisions | Where-Object {$_.First -eq $sourceJob.DisplayName -or $_.Second -eq $sourceJob.DisplayName}).Count){throw 'Several IPF inputs share one output destination.'}
            } catch {$job.BlockedReason=$_.Exception.Message}
            $jobs.Add($job)
        }
        foreach($skipped in @($rawResult.Failures)+@($rawResult.Untouched)){$job=New-ApplicationBrokerJob (Get-ApplicationBrokerRelative $skipped.InputPath $src) $skipped $null;$job.Paths=@($skipped.InputPath);$job.BlockedReason='Input was not converted.';if($skipped.PSObject.Properties['Reason']){$job.BlockedReason=$skipped.Reason;$job.BlockedResult='Skipped'}else{$job.BlockedReason=$skipped.Error};$job.SourceBlockReason=$job.BlockedReason;$jobs.Add($job)}
    }
    if($jobs.Count -gt 20000){throw 'This batch contains more than 20,000 jobs. Split the collection into smaller batches.'}
    $sourcePlan=& $sourceModule {param($src,$policy)New-SourcePolicyPlan $src $policy} $src $SourcePolicy
    $jobMap=@{};$conflicts=@{}
    foreach($job in $jobs){
        $jobMap[$job.JobId]=$job
        foreach($path in $job.Paths){$key=Get-ApplicationBrokerRelative $path $src;if($state.SourceSnapshot.Files.ContainsKey($key)){$job.SourceHashes[[IO.Path]::GetFullPath($path)]=$state.SourceSnapshot.Files[$key].Hash}}
        & $sourceModule {param($plan,$job)Add-SourcePolicyJob $plan $job.JobId $job.Paths $job.SourceBlockReason} $sourcePlan $job
        if($Operation -eq 'Playlist' -and $job.SourceBlockReason){$sourcePlan.BlockReason=$job.SourceBlockReason}
        if($job.Conflicts.Count){$job.ConflictId=[Guid]::NewGuid().ToString('N');$conflicts[$job.ConflictId]=$job;$job.Decision=@{Ask='Pending';Overwrite='Overwrite';Skip='Skip'}[$Existing]}
    }
    Assert-ApplicationBrokerSnapshot $state.SourceSnapshot (Get-ApplicationBrokerTree $src) 'Original source tree'
    Assert-ApplicationBrokerSnapshot $state.DestinationSnapshot (Get-ApplicationBrokerTree $dst) 'Original output tree'
    $batch=[pscustomobject]@{BatchId=[Guid]::NewGuid().ToString('N');WorkRoot=$state.WorkRoot;Operation=$Operation;System=$System;Storage=$Storage;Format=$Format;SourcePolicy=$SourcePolicy;Existing=$Existing;Module=$module;SourceModule=$sourceModule;SourcePlan=$sourcePlan;Profile=$profile;Jobs=$jobMap;Conflicts=$conflicts;Completed=$false;OverwriteAll=''}
    $state.Batch=$batch
    $view=[pscustomobject]@{BatchId=$batch.BatchId;WorkRoot=$state.WorkRoot;Operation=$Operation;System=$System;Storage=$Storage;Format=$Format;SourcePolicy=$SourcePolicy;Existing=$Existing;Jobs=@($jobs | ForEach-Object {[pscustomobject]@{JobId=$_.JobId;SourceKey=$_.SourceKey;ConflictId=$_.ConflictId;BlockedReason=$_.BlockedReason}})}
    $Session.ActiveBatch=$view
    return $view
    } finally {foreach($sourcePin in $sourcePins){$sourcePin.Dispose()}}
}

function Get-ApplicationBrokerBatch($Session,[string]$BatchId) {
    $state=Get-ApplicationBrokerState $Session
    if(-not $state.Batch -or $state.Batch.Completed -or $state.Batch.BatchId -cne $BatchId){throw 'Unknown, completed, or replayed application batch.'}
    return $state.Batch
}

function Get-ApplicationBrokerConflict($Session,[string]$BatchId,[string]$ConflictId) {
    $batch=Get-ApplicationBrokerBatch $Session $BatchId
    if(-not $batch.Conflicts.ContainsKey($ConflictId)){throw 'Unknown application conflict capability.'}
    $job=$batch.Conflicts[$ConflictId]
    return [pscustomobject]@{ConflictId=$ConflictId;JobId=$job.JobId;Paths=@($job.Conflicts | ForEach-Object {$_.Destination});Folder=(@($job.Conflicts | Where-Object {$_.Folder}).Count -gt 0);Decision=$job.Decision}
}

function Set-ApplicationBrokerOverwrite {
    param($Session,[string]$BatchId,[string]$ConflictId,[ValidateSet('Overwrite','Skip','OverwriteAll','SkipAll')][string]$Choice)
    $batch=Get-ApplicationBrokerBatch $Session $BatchId
    if(-not $batch.Conflicts.ContainsKey($ConflictId)){throw 'Unknown application conflict capability.'}
    $job=$batch.Conflicts[$ConflictId]
    if($job.Decision -ne 'Pending'){throw 'Application conflict choice is already fixed.'}
    if($Choice -in 'OverwriteAll','SkipAll'){$decision=$Choice.Replace('All','');$batch.OverwriteAll=$decision;foreach($pending in $batch.Conflicts.Values){if($pending.Decision -eq 'Pending'){$pending.Decision=$decision}}}
    else {$job.Decision=$Choice}
}

function Assert-ApplicationBrokerManifest([hashtable]$Expected,[hashtable]$Actual,$Batch,$ReceiptStore) {
    if($Expected.Count -ne $Actual.Count){throw 'Staged output file count does not match the independent source plan.'}
    foreach($name in $Expected.Keys){
        if(-not $Actual.ContainsKey($name)){throw 'Staged output is missing an expected member.'}
        $expectedFile=$Expected[$name];$actualFile=$Actual[$name]
        if($expectedFile.Converter){
            $matching=@($ReceiptStore.NativeReceipts | Where-Object {
                $_.Success -eq $true -and $_.BatchId -ceq $Batch.BatchId -and $_.Kind -ceq $expectedFile.Converter -and
                $_.InputHash -ceq $expectedFile.InputHash -and $_.OutputHash -ceq $actualFile.Hash -and [long]$_.Length -eq [long]$actualFile.Length
            })
            if($matching.Count -eq 0){throw 'Converted output has no matching host-owned converter receipt; original kept.'}
        } elseif($expectedFile.Hash -cne $actualFile.Hash -or $expectedFile.Length -ne $actualFile.Length){throw 'Staged output differs from the frozen original content.'}
    }
}

function Get-ApplicationBrokerExpectedLengths($Expected,$Batch,$ReceiptStore) {
    if(-not $Expected.Converter){return ,([long[]]@($Expected.Length))}
    $lengths=@($ReceiptStore.NativeReceipts | Where-Object {$_.Success -eq $true -and $_.BatchId -ceq $Batch.BatchId -and $_.Kind -ceq $Expected.Converter -and $_.InputHash -ceq $Expected.InputHash} | ForEach-Object {[long]$_.Length} | Select-Object -Unique)
    if(-not $lengths.Count){throw 'Converted output has no matching host-owned receipt.'}
    return ,([long[]]$lengths)
}

function Assert-ApplicationBrokerOwnership($Batch,$Job,[string]$DestinationRoot) {
    if($Batch.Operation -eq 'Playlist'){
        & $Batch.Module {param($job,$profile,$dst)
            $script:DiskExtensions=@($profile.Extensions)
            $names=@($job.Plan.ContentNames)+@($job.Files.Keys)
            Assert-NoMediaNesting $job.SourceJob $dst $job.Plan.ZipMode $profile.Playlist
            Assert-PlaylistOutputOwnership $job.Plan $names
        } $Job $Batch.Profile $DestinationRoot
    } elseif($Batch.Operation -eq 'C64'){
        & $Batch.Module {param($job,$dst)Assert-C64OwnedOutputs $job.Plan $job.DiskNames $dst @($job.Files.Keys)} $Job $DestinationRoot
    } else {
        & $Batch.SourceModule {param($path,$dst)Assert-PlainOutputParents $path $dst} $Job.Plan.Destination $DestinationRoot
        if(Test-Path -LiteralPath $Job.Plan.Destination){$item=Get-Item -LiteralPath $Job.Plan.Destination -Force;if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Existing converter output is not a regular file.'}}
    }
}

function Copy-ApplicationBrokerOutput($State,$Batch,$Job,$ReceiptStore) {
    $dst=Join-Path $State.OriginalRoot 'DST';$workDst=Join-Path $State.WorkRoot 'DST'
    $items=New-Object 'System.Collections.Generic.List[object]';$owned=New-Object 'System.Collections.Generic.List[string]';$locks=New-Object 'System.Collections.Generic.List[IDisposable]'
    try {
        Assert-ApplicationBrokerOwnership $Batch $Job $dst
        foreach($write in $Job.Writes){
            $relative=Get-ApplicationBrokerRelative $write.Destination $dst
            $childPath=Join-Path $workDst $relative
            $parent=[IO.Path]::GetDirectoryName($write.Destination);$anchor=$parent
            while(-not [IO.Directory]::Exists($anchor)){$anchor=[IO.Path]::GetDirectoryName($anchor)}
            $locks.Add((Open-SourcePolicyDirectoryLease $anchor))
            [void][IO.Directory]::CreateDirectory($parent)
            if($parent -ne $anchor){$locks.Add((Open-SourcePolicyDirectoryLease $parent))}
            $container=Join-Path $parent ('.app_'+[Guid]::NewGuid().ToString('N').Substring(0,16)+'.tmp')
            # Supply the protected DACL in CreateDirectory itself: there is no
            # interval where this folder inherits a broad application ACL.
            [OptiMiyoo.ApplicationBrokerLease]::CreatePrivateDirectory($container)
            $owned.Add($container)
            $stage=Join-Path $container 'data'
            $playlist=($null -ne $Job.PlaylistText -and $items.Count -gt 0)
            if($playlist){
                # Generate trusted playlist bytes, and require the child to have
                # produced exactly the independently planned layout as well.
                $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($Job.PlaylistText)
                $sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}
                $child=Get-ApplicationBrokerFile $childPath $workDst -SingleLink -AllowedLengths @($bytes.Length)
                if($child.Hash -cne $hash -or $child.Length -ne $bytes.Length){throw 'Staged playlist does not match the independent output plan.'}
                $stream=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
                $items.Add([pscustomobject]@{Staged=$stage;Destination=$write.Destination;Folder=$false;Hash=$hash})
                continue
            }
            if($Job.DataKind -eq 'Folder'){
                [void][IO.Directory]::CreateDirectory($stage)
                # Copy only independently named members. The private copy is
                # never writable by the child; each source handle denies writes
                # and deletion while its bytes are copied and hashed.
                $actual=@{}
                $inventory=Get-ApplicationBrokerTree $childPath -RequireSingleLink -MaximumEntries 50000 -MetadataOnly
                if($inventory.Files.Count -ne $Job.Files.Count){throw 'Staged output contains extra or missing files.'}
                foreach($name in $Job.Files.Keys){
                    if(-not $inventory.Files.ContainsKey($name)){throw 'Staged output member is missing.'}
                    $target=Join-Path $stage $name;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                    $lengths=Get-ApplicationBrokerExpectedLengths $Job.Files[$name] $Batch $ReceiptStore
                    $actual[$name]=Get-ApplicationBrokerFile (Join-Path $childPath $name) $workDst $target -SingleLink -AllowedLengths $lengths
                }
                Assert-ApplicationBrokerManifest $Job.Files $actual $Batch $ReceiptStore
                $items.Add([pscustomobject]@{Staged=$stage;Destination=$write.Destination;Folder=$true;Manifest=$actual;Hash=$null})
            } else {
                $lengths=$null
                if($Job.DataKind -eq 'File'){$lengths=Get-ApplicationBrokerExpectedLengths $Job.Files[@($Job.Files.Keys)[0]] $Batch $ReceiptStore}
                elseif($Job.ContainerHash){$lengths=@($State.SourceSnapshot.Files[(Get-ApplicationBrokerRelative $Job.SourceJob.Zip (Join-Path $State.OriginalRoot 'SRC'))].Length)}
                $copied=Get-ApplicationBrokerFile $childPath $workDst $stage -SingleLink -AllowedLengths $lengths -ArchiveBudget:($Job.DataKind -eq 'Zip')
                if($Job.ContainerHash -and $copied.Hash -cne $Job.ContainerHash){throw 'Archive that required no conversion differs from the original ZIP.'}
                $actual=@{}
                if($Job.DataKind -eq 'Zip'){$actual=Get-ApplicationBrokerArchive $Batch.Module $stage}
                else {
                    if($Job.Files.Count -ne 1){throw 'Single-file output plan has multiple members.'}
                    $name=@($Job.Files.Keys)[0];$actual[$name]=$copied
                }
                Assert-ApplicationBrokerManifest $Job.Files $actual $Batch $ReceiptStore
                if($Batch.Operation -eq 'ZX'){
                    $valid=& $Batch.Module {param($path,$kind,$name)if($kind -eq 'Zip'){Test-ZipDskPackage $path $name}else{Test-DSK $path}} $stage $Job.DataKind @($Job.Files.Keys)[0]
                    if(-not $valid){throw 'Converted DSK structure is invalid.'}
                }
                $items.Add([pscustomobject]@{Staged=$stage;Destination=$write.Destination;Folder=$false;Hash=$copied.Hash})
            }
        }
        return [pscustomobject]@{Items=$items.ToArray();Owned=$owned.ToArray();Locks=$locks}
    } catch {
        foreach($path in $owned){if(Test-Path -LiteralPath $path){try{Remove-SourcePolicyOwnedPath $path ([IO.Path]::GetDirectoryName($path))}catch{Write-Warning ('Unpublished broker staging retained: '+$path)}}}
        foreach($lock in $locks){$lock.Dispose()}
        throw
    }
}

function Complete-ApplicationBrokerBatch {
    param([Parameter(Mandatory=$true)]$Session,[Parameter(Mandatory=$true)][string]$BatchId,
          [string[]]$CompletedJobIds=@(),[Parameter(Mandatory=$true)]$ReceiptStore)
    $state=Get-ApplicationBrokerState $Session;$batch=Get-ApplicationBrokerBatch $Session $BatchId
    $ids=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($id in $CompletedJobIds){if(-not $ids.Add($id) -or -not $batch.Jobs.ContainsKey($id)){throw 'Unknown, duplicate, or forged completed job capability.'}}
    # Validate the whole request before any publication. A child cannot use a
    # partial request to consume another job's overwrite or removal authority.
    foreach($id in $ids){$job=$batch.Jobs[$id];if($job.BlockedReason -or $job.Decision -in 'Pending','Skip'){throw 'The child reported completion for an unauthorized or blocked job.'}}
    $batch.Completed=$true
    $src=Join-Path $state.OriginalRoot 'SRC';$dst=Join-Path $state.OriginalRoot 'DST'
    $results=New-Object 'System.Collections.Generic.List[object]'
    try {
        Assert-ApplicationBrokerSnapshot $state.SourceSnapshot (Get-ApplicationBrokerTree $src) 'Original source tree'
        Assert-ApplicationBrokerSnapshot $state.DestinationSnapshot (Get-ApplicationBrokerTree $dst) 'Original output tree'
        foreach($id in $CompletedJobIds){
            $job=$batch.Jobs[$id];$sealed=$null;$commit=$null
            try {
                $sealed=Copy-ApplicationBrokerOutput $state $batch $job $ReceiptStore
                Assert-ApplicationBrokerOwnership $batch $job $dst
                # Reuse the established two-part transaction and rollback logic
                # for all formats, including ZX's single-file output.
                $commit=& $batch.SourceModule {param($items,$overwrite,$retired)Install-PlaylistSet $items $null $false $overwrite $retired} $sealed.Items ($job.Decision -eq 'Overwrite') $job.Retired
                & $batch.SourceModule {param($plan,$job,$items)Complete-SourcePolicyJob $plan $job.JobId $job.SourceHashes $items} $batch.SourcePlan $job $sealed.Items
                $writtenResult='Written';if($commit.Replaced){$writtenResult='Overwritten'}
                $results.Add([pscustomobject]@{JobId=$id;SourceKey=$job.SourceKey;Result=$writtenResult;Detail='Output independently verified and published.'})
            } catch {$results.Add([pscustomobject]@{JobId=$id;SourceKey=$job.SourceKey;Result='Failed';Detail=$_.Exception.Message})}
            finally {
                if($commit){foreach($lock in $commit.Locks){$lock.Dispose()}}
                if($sealed){
                    foreach($path in $sealed.Owned){
                        $preserve=@($sealed.Items | Where-Object {$_.PreserveStaging -and $_.Staged.StartsWith($path,[StringComparison]::OrdinalIgnoreCase)}).Count -gt 0
                        if(-not $preserve -and (Test-Path -LiteralPath $path)){try{Remove-SourcePolicyOwnedPath $path ([IO.Path]::GetDirectoryName($path))}catch{Write-Warning ('Broker staging retained: '+$path)}}
                    }
                    foreach($lock in $sealed.Locks){$lock.Dispose()}
                }
            }
        }
        # A new or changed CUE/input during the batch can change shared ownership.
        # Reject cleanup for the entire batch before considering any removals.
        try {Assert-ApplicationBrokerSnapshot $state.SourceSnapshot (Get-ApplicationBrokerTree $src) 'Original source tree'}
        catch {$batch.SourcePlan.BlockReason='Original source inventory changed; all originals kept.'}
        & $batch.SourceModule {param($plan)Invoke-SourcePolicyCleanup $plan {param($label,$message)if($label -eq 'WARNING'){Write-Warning $message}}} $batch.SourcePlan
        foreach($job in $batch.Jobs.Values){
            if(-not $ids.Contains($job.JobId)){
                $detail='The worker did not complete this input; original kept.'
                $uncompletedResult='Failed'
                if($job.BlockedReason){$detail=$job.BlockedReason;$uncompletedResult=$job.BlockedResult}elseif($job.Decision -eq 'Skip'){$detail='Overwrite declined; original kept.';$uncompletedResult='Skipped'}
                $results.Add([pscustomobject]@{JobId=$job.JobId;SourceKey=$job.SourceKey;Result=$uncompletedResult;Detail=$detail})
            }
        }
        foreach($result in $results){
            $job=$batch.Jobs[$result.JobId];$playlist='';$destination='';$diskImages=0
            if($job.Plan){
                if($batch.Operation -eq 'Playlist'){$diskImages=@($job.Plan.DiskNames).Count;$destination=$job.Plan.RelativeData;if($job.Plan.IsMulti){$playlist=Get-ApplicationBrokerRelative $job.Plan.M3uPath $dst}}
                elseif($batch.Operation -eq 'C64'){$diskImages=$job.SourceJob.Images;$destination=$job.Plan.RelativeData;if($job.Plan.Multi){$playlist=$job.Plan.RelativePlaylist}}
                else {$diskImages=1;$destination=$job.Plan.RelativeData}
            }
            $result | Add-Member NoteProperty System $batch.System
            $result | Add-Member NoteProperty Source $job.SourceKey
            $result | Add-Member NoteProperty Playlist $playlist
            $result | Add-Member NoteProperty Destination $destination
            $result | Add-Member NoteProperty DiskImages $diskImages
            $summary=& $batch.SourceModule {param($plan,$id)Get-SourcePolicySummary $plan $id} $batch.SourcePlan $result.JobId
            $result | Add-Member NoteProperty Original $summary.Label
            $result | Add-Member NoteProperty RemovedFiles $summary.Removed
            $result | Add-Member NoteProperty KeptFiles $summary.Kept
            $result | Add-Member NoteProperty RemovalFailures $summary.Failed
        }
        $sourceStates=@($batch.SourcePlan.Files.Values | ForEach-Object {
            $reason=$_.Reason;if($batch.SourcePolicy -eq 'Keep'){$reason='Keep policy selected.'}
            [pscustomobject]@{State=$_.State;Reason=$reason}
        })
        return [pscustomobject]@{BatchId=$BatchId;Operation=$batch.Operation;SourcePolicy=$batch.SourcePolicy;Results=$results.ToArray();Sources=$sourceStates;Written=@($results | Where-Object {$_.Result -in 'Written','Overwritten'}).Count;Failed=@($results | Where-Object {$_.Result -eq 'Failed'}).Count;Removed=@($sourceStates | Where-Object {$_.State -eq 'Removed'}).Count;Kept=@($sourceStates | Where-Object {$_.State -ne 'Removed'}).Count;RemovalFailures=@($sourceStates | Where-Object {$_.State -eq 'Failed'}).Count}
    } finally {$Session.ActiveBatch=$null}
}

function Close-ApplicationBrokerSession($Session) {
    $state=Get-ApplicationBrokerState $Session
    $state.Closed=$true;$state.Batch=$null;$Session.ActiveBatch=$null
    $script:ApplicationBrokerStates.Remove($state.Id)
    # Session owner, not an untrusted completion message, owns scratch cleanup.
}
