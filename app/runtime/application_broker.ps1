# The host keeps publication authority. No function in this file is an RPC verb
# accepting an arbitrary host pathname, script, command, or deletion request.
# Installed planning/ownership helpers remain trusted, bounded parsing code.
. (Join-Path $PSScriptRoot '../shared/source_policy.ps1')
. (Join-Path $PSScriptRoot '../onion/core_support.ps1')
. (Join-Path $PSScriptRoot '../shared/archive_limits.ps1')
. (Join-Path $PSScriptRoot '../shared/native_process.ps1')
. (Join-Path $PSScriptRoot '../shared/archive_sandbox.ps1')

if (-not (Get-Variable ApplicationBrokerStates -Scope Script -ErrorAction SilentlyContinue)) {$script:ApplicationBrokerStates=@{}}
if (-not (Get-Variable ApplicationBrokerModules -Scope Script -ErrorAction SilentlyContinue)) {$script:ApplicationBrokerModules=@{}}
$script:ApplicationBrokerCodeRoot=Split-Path -Parent $PSScriptRoot

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
        [StructLayout(LayoutKind.Sequential)] struct Disposition {public byte Delete;}
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetFileInformationByHandle(SafeFileHandle handle,int kind,ref Disposition value,uint size);
        readonly List<SafeFileHandle> handles=new List<SafeFileHandle>();
        private static string NativePath(string path) {
            string full=Path.GetFullPath(path);
            if(full.StartsWith(@"\\?\",StringComparison.Ordinal)||full.StartsWith(@"\\.\",StringComparison.Ordinal))throw new IOException("Device paths are not supported.");
            return full.StartsWith(@"\\",StringComparison.Ordinal)?@"\\?\UNC\"+full.Substring(2):@"\\?\"+full;
        }
        public static void CreatePrivateDirectory(string path) {
            string sid=System.Security.Principal.WindowsIdentity.GetCurrent().User.Value;
            IntPtr descriptor;uint size;
            if(!ConvertStringSecurityDescriptorToSecurityDescriptorW("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;"+sid+")",1,out descriptor,out size))throw new Win32Exception(Marshal.GetLastWin32Error());
            try {SecurityAttributes attributes=new SecurityAttributes();attributes.Length=Marshal.SizeOf(typeof(SecurityAttributes));attributes.Descriptor=descriptor;
                if(!CreateDirectoryW(NativePath(path),ref attributes))throw new Win32Exception(Marshal.GetLastWin32Error(),"Could not create private broker publication staging.");
            } finally {LocalFree(descriptor);}
        }
        public static ApplicationBrokerLease Directory(string path) {
            ApplicationBrokerLease lease=new ApplicationBrokerLease();
            try {
                List<string> names=new List<string>(); string current=Path.GetFullPath(path);
                while(!String.IsNullOrEmpty(current)) {names.Add(current);DirectoryInfo p=System.IO.Directory.GetParent(current);current=p==null?null:p.FullName;}
                names.Reverse();
                foreach(string name in names) {
                    SafeFileHandle handle=CreateFileW(NativePath(name),0x81,1,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
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
        // A moved old output stays bound to its approved bytes until rollback or
        // deletion. Deletion uses these same verified handles, never a new walk.
        public sealed class Backup : IDisposable {
            sealed class Entry : IDisposable {
                internal SafeFileHandle Handle;internal FileStream Stream;
                public void Dispose(){if(Stream!=null){Stream.Dispose();Stream=null;}if(Handle!=null){Handle.Dispose();Handle=null;}}
            }
            readonly List<Entry> entries=new List<Entry>();
            IDisposable parents;
            static IDisposable PinParent(string path) {
                foreach(System.Reflection.Assembly assembly in AppDomain.CurrentDomain.GetAssemblies()) {
                    Type policy=assembly.GetType("OptiMiyoo.SourceRemovalLeaseV128",false);
                    if(policy!=null) {
                        try{return (IDisposable)policy.GetMethod("OpenDirectory").Invoke(null,new object[]{path});}
                        catch(System.Reflection.TargetInvocationException error){throw error.InnerException??error;}
                    }
                }
                throw new IOException("Verified output directory helper is unavailable.");
            }
            internal static Backup Open(string path,bool folder,string[] names,long[] lengths,string[] hashes,string[] directories) {
                Backup result=new Backup();
                try {
                    if(names.Length!=lengths.Length||names.Length!=hashes.Length)throw new IOException("Invalid approved backup manifest.");
                    Dictionary<string,int> files=new Dictionary<string,int>(StringComparer.OrdinalIgnoreCase);
                    HashSet<string> dirs=new HashSet<string>(directories,StringComparer.OrdinalIgnoreCase);
                    for(int i=0;i<names.Length;i++)files.Add(names[i],i);
                    string root=Path.GetFullPath(path),prefix=root+Path.DirectorySeparatorChar;
                    result.parents=PinParent(Path.GetDirectoryName(root));
                    Queue<string> pending=new Queue<string>();pending.Enqueue(root);int fileCount=0,dirCount=0;
                    while(pending.Count>0) {
                        string current=pending.Dequeue();bool isRoot=String.Equals(current,root,StringComparison.OrdinalIgnoreCase);
                        string relative=isRoot?"":current.Substring(prefix.Length).Replace('\\','/');
                        SafeFileHandle handle=CreateFileW(NativePath(current),0x80010000,1,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
                        if(handle.IsInvalid){int error=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(error,"Could not freeze previous output backup.");}
                        Entry entry=new Entry{Handle=handle};result.entries.Add(entry);Info info;
                        if(!GetFileInformationByHandle(handle,out info))throw new Win32Exception(Marshal.GetLastWin32Error());
                        bool directory=(info.Attributes&0x10)!=0;
                        if((info.Attributes&0x400)!=0||(isRoot&&directory!=folder))throw new IOException("Previous output backup changed type or contains a link.");
                        if(directory) {
                            if(!isRoot&&!dirs.Contains(relative))throw new IOException("Previous output gained an unapproved directory; previous output kept.");
                            dirCount++;if(dirCount>directories.Length+1)throw new IOException("Previous output directory inventory changed.");
                            foreach(string child in System.IO.Directory.EnumerateFileSystemEntries(NativePath(current))) {
                                if(pending.Count+result.entries.Count>=names.Length+directories.Length+1)throw new IOException("Previous output gained an unapproved entry; previous output kept.");
                                pending.Enqueue(Path.Combine(current,Path.GetFileName(child)));
                            }
                        } else {
                            int index;if(!files.TryGetValue(relative,out index)||info.Links!=1||(info.Attributes&1)!=0)throw new IOException("Previous output is unapproved, linked, or read-only; previous output kept.");
                            entry.Stream=new FileStream(handle,FileAccess.Read);fileCount++;
                            if(entry.Stream.Length!=lengths[index])throw new IOException("Previous output changed since approval; previous output kept.");
                            using(System.Security.Cryptography.SHA256 sha=System.Security.Cryptography.SHA256.Create()) {
                                string hash=BitConverter.ToString(sha.ComputeHash(entry.Stream)).Replace("-","");
                                if(!String.Equals(hash,hashes[index],StringComparison.Ordinal))throw new IOException("Previous output changed since approval; previous output kept.");
                            }
                        }
                    }
                    if(fileCount!=names.Length||dirCount!=(folder?directories.Length+1:0))throw new IOException("Previous output inventory changed since approval; previous output kept.");
                    return result;
                } catch {result.Dispose();throw;}
            }
            public void Remove() {
                for(int i=entries.Count-1;i>=0;i--) {
                    Disposition disposition=new Disposition{Delete=1};
                    if(!SetFileInformationByHandle(entries[i].Handle,4,ref disposition,1))throw new Win32Exception(Marshal.GetLastWin32Error(),"Verified previous output backup retained.");
                    entries[i].Dispose();
                }
            }
            public void Dispose(){for(int i=entries.Count-1;i>=0;i--)entries[i].Dispose();entries.Clear();if(parents!=null){parents.Dispose();parents=null;}}
        }
        public static Backup OpenBackup(string path,bool folder,string[] names,long[] lengths,string[] hashes,string[] directories){return Backup.Open(path,folder,names,lengths,hashes,directories);}
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

function Get-ApplicationBrokerTree([string]$Root,[string]$CopyTo,[switch]$RequireSingleLink,[int]$MaximumEntries=100000,[switch]$MetadataOnly,[hashtable]$ExpectedFiles,[hashtable]$BorrowedSourceLeases,[scriptblock]$CancellationCheck=$null) {
    if($CancellationCheck){& $CancellationCheck}
    Initialize-ApplicationBrokerNative
    $files=@{};$directories=New-Object 'System.Collections.Generic.List[string]';$bytes=0L;$entryCount=0;$buffer=$null
    if($MaximumEntries -lt 1 -or $MaximumEntries -gt 1000000){throw 'Invalid broker snapshot entry limit.'}
    if($MetadataOnly -and $CopyTo){throw 'A metadata-only inventory cannot copy file data.'}
    Assert-OptiPathBudget -Path $Root -Directory
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
            if($CancellationCheck){& $CancellationCheck}
            $directory=$pending.Dequeue();$directoryLease=[OptiMiyoo.ApplicationBrokerLease]::Directory($directory)
            try {
                Assert-OptiPathBudget -Path $directory -Directory
                foreach($entryPath in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
                    if($CancellationCheck){& $CancellationCheck}
                    $entryCount++;if($entryCount -gt $MaximumEntries){throw 'Broker snapshot entry limit exceeded; originals kept.'}
                    Assert-OptiPathBudget -Path $entryPath
                    $entry=Get-Item -LiteralPath $entryPath -Force -ErrorAction Stop
                    if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Broker snapshot contains a link; originals kept.'}
                    $relative=Get-ApplicationBrokerRelative $entry.FullName $Root
                    if($entry.PSIsContainer){$directories.Add($relative);$pending.Enqueue($entry.FullName);if($CopyTo){[void][IO.Directory]::CreateDirectory((Join-Path $CopyTo $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)))};continue}
                    if($files.ContainsKey($relative)){throw 'Broker snapshot has colliding names.'}
                    # Final cleanup already owns eligible CUE deletion handles.
                    # A second read handle would conflict with their DELETE access.
                    $borrowed=$BorrowedSourceLeases -and $BorrowedSourceLeases.ContainsKey($entry.FullName)
                    $lease=$null;if($borrowed){$lease=$BorrowedSourceLeases[$entry.FullName]}else{$lease=Open-SourcePolicyReadLease $entry.FullName $Root}
                    $output=$null;$sha=$null
                    try {
                        if($borrowed){$lease.Stream.Position=0}
                        $links=[OptiMiyoo.ApplicationBrokerLease]::LinkCount($lease.Stream.SafeFileHandle)
                        if($RequireSingleLink -and $links -ne 1){throw 'Broker output contains a hard link.'}
                        if($null -ne $ExpectedFiles -and (-not $ExpectedFiles.ContainsKey($relative) -or $ExpectedFiles[$relative].Length -ne $lease.Stream.Length)){throw 'Staged snapshot has unexpected file names or lengths.'}
                        if($MetadataOnly){$files[$relative]=[pscustomobject]@{Hash='';Length=$lease.Stream.Length;Links=$links;LastWriteTimeUtc=$entry.LastWriteTimeUtc};$bytes+=$lease.Stream.Length;continue}
                        if($CopyTo){$target=Join-Path $CopyTo $relative.Replace('/',[IO.Path]::DirectorySeparatorChar);$output=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)}
                        $sha=[Security.Cryptography.SHA256]::Create();if($null -eq $buffer){$buffer=New-Object byte[] 1048576};$length=0L
                        while($true){
                            if($CancellationCheck){& $CancellationCheck}
                            $count=$lease.Stream.Read($buffer,0,$buffer.Length);if($count -le 0){break}
                            if($output){$output.Write($buffer,0,$count)};[void]$sha.TransformBlock($buffer,0,$count,$null,0);$length+=$count
                        }
                        [void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0)
                        if($length -ne $lease.Stream.Length){throw 'Broker snapshot changed while being copied.'}
                        $hash=[BitConverter]::ToString($sha.Hash).Replace('-','')
                        if($output){$output.Flush($true);$output.Dispose();$output=$null;[IO.File]::SetLastWriteTimeUtc($target,$entry.LastWriteTimeUtc)}
                        $files[$relative]=[pscustomobject]@{Hash=$hash;Length=$length;Links=$links;LastWriteTimeUtc=$entry.LastWriteTimeUtc}
                        $bytes+=$length
                    } finally {if($output){$output.Dispose()};if($sha){$sha.Dispose()};if($borrowed){$lease.Stream.Position=0}else{$lease.Dispose()}}
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

function Assert-ApplicationBrokerInventory($Expected,$Actual,[string]$Description) {
    if($null -eq $Expected -or $null -eq $Actual -or $Expected.Exists -isnot [bool] -or $Actual.Exists -isnot [bool] -or $Expected.Files -isnot [hashtable] -or $Actual.Files -isnot [hashtable] -or $null -eq $Expected.Directories -or $null -eq $Actual.Directories){throw 'Invalid broker snapshot inventory.'}
    if($Expected.Exists -ne $Actual.Exists -or $Expected.Files.Count -ne $Actual.Files.Count -or @($Expected.Directories).Count -ne @($Actual.Directories).Count){throw ($Description+' changed since the batch started.')}
    foreach($name in $Expected.Files.Keys){if(-not $Actual.Files.ContainsKey($name) -or $null -eq $Expected.Files[$name] -or $null -eq $Actual.Files[$name] -or $null -eq $Expected.Files[$name].Length -or $null -eq $Actual.Files[$name].Length -or $Expected.Files[$name].Length -lt 0 -or $Actual.Files[$name].Length -lt 0 -or $Expected.Files[$name].Length -ne $Actual.Files[$name].Length){throw ($Description+' changed since the batch started.')}}
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
    $relative=@{Playlist='playlists/make_playlists.ps1';C64='C64/convert_c64.ps1';ZX='ZX/convert_zx.ps1'}[$Operation]
    $module=New-Module -Name ('OptiMiyooBroker'+$Operation) -ArgumentList @($script:ApplicationBrokerCodeRoot,$relative) -ScriptBlock {
        param($codeRoot,$relative)
        foreach($helper in 'shared/compile_support.ps1','shared/source_policy.ps1','onion/core_support.ps1','shared/archive_limits.ps1','shared/zip_integrity.ps1','shared/native_process.ps1','shared/archive_sandbox.ps1','shared/media_validation.ps1','shared/conversion_layout.ps1'){. (Join-Path $codeRoot $helper)}
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
    param([Parameter(Mandatory=$true)][string]$OriginalRoot,[Parameter(Mandatory=$true)][string]$WorkRoot)
    $original=[IO.Path]::GetFullPath($OriginalRoot).TrimEnd('\','/');$work=[IO.Path]::GetFullPath($WorkRoot).TrimEnd('\','/')
    if(-not [IO.Directory]::Exists($original)){throw 'Application input root must exist.'}
    foreach($name in 'SRC','DST') {
        $media=[IO.Path]::GetFullPath((Join-Path $original $name)).TrimEnd('\','/')
        if($media.Equals($work,[StringComparison]::OrdinalIgnoreCase) -or $work.StartsWith($media+'\',[StringComparison]::OrdinalIgnoreCase) -or $media.StartsWith($work+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Application broker staging must be separate from SRC and DST.'}
    }
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
        # Reuse the inventory to reject unworkable staging paths before copying.
        foreach($snapshot in @(@{Name='SRC';Tree=$sourceInventory},@{Name='DST';Tree=$destinationInventory})) {
            $targetRoot=Join-Path $work $snapshot.Name
            Assert-OptiPathBudget -Path $targetRoot -Directory
            foreach($relative in $snapshot.Tree.Directories){Assert-OptiPathBudget -Path (Join-Path $targetRoot $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)) -Directory}
            foreach($relative in $snapshot.Tree.Files.Keys){
                $target=Join-Path $targetRoot $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
                Assert-OptiPathBudget -Path $target
                Assert-OptiPathBudget -Path ([IO.Path]::GetDirectoryName($target)) -Directory
            }
        }
        $source=Get-ApplicationBrokerTree (Join-Path $original 'SRC') (Join-Path $work 'SRC') -MaximumEntries ([Math]::Max(1,$sourceCount)) -ExpectedFiles $sourceInventory.Files
        $destination=Get-ApplicationBrokerTree (Join-Path $original 'DST') (Join-Path $work 'DST') -MaximumEntries ([Math]::Max(1,$destinationCount)) -ExpectedFiles $destinationInventory.Files
        if($source.Files.Count+$source.Directories.Count+$destination.Files.Count+$destination.Directories.Count -gt 100000){throw 'SRC or DST grew beyond the snapshot entry limit; originals kept.'}
    } finally {$workLease.Dispose()}
    $id=[Guid]::NewGuid().ToString('N')+[Guid]::NewGuid().ToString('N')
    $handle=[pscustomobject]@{Id=$id;OriginalRoot=$original;WorkRoot=$work;SourceSnapshot=[pscustomobject]@{FileCount=$source.Files.Count;Bytes=$source.Bytes};DestinationSnapshot=[pscustomobject]@{FileCount=$destination.Files.Count;Bytes=$destination.Bytes};ActiveBatch=$null}
    $script:ApplicationBrokerStates[$id]=[pscustomobject]@{Handle=$handle;Id=$id;OriginalRoot=$original;WorkRoot=$work;SourceSnapshot=$source;DestinationSnapshot=$destination;DestinationTree=$null;Batch=$null;Closed=$false}
    return $handle
}

function Get-ApplicationBrokerFile([string]$Path,[string]$Root,[string]$CopyTo,[switch]$SingleLink,[long[]]$AllowedLengths,[switch]$ArchiveBudget) {
    Initialize-ApplicationBrokerNative
    $lease=Open-SourcePolicyReadLease $Path $Root;$output=$null;$sha=$null
    try {
        if($SingleLink -and [OptiMiyoo.ApplicationBrokerLease]::LinkCount($lease.Stream.SafeFileHandle) -ne 1){throw 'Sandbox output is a hard link; originals kept.'}
        if($null -ne $AllowedLengths -and $AllowedLengths.Count -gt 0 -and $lease.Stream.Length -notin $AllowedLengths){throw 'Sandbox output length does not match the independently verified content.'}
        if($ArchiveBudget){Assert-ArchiveBudget -Stream $lease.Stream -Profile Media}
        if($CopyTo){
            $output=[IO.File]::Open($CopyTo,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $sha=[Security.Cryptography.SHA256]::Create();$buffer=New-Object byte[] 1048576;$length=0L
            # Hash the exact bytes copied while the same native read lease is held.
            while(($count=$lease.Stream.Read($buffer,0,$buffer.Length)) -gt 0){
                $output.Write($buffer,0,$count);[void]$sha.TransformBlock($buffer,0,$count,$buffer,0);$length+=$count
            }
            [void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0)
            if($length -ne $lease.Stream.Length){throw 'Sandbox output verification read was incomplete; originals kept.'}
            $hash=[BitConverter]::ToString($sha.Hash).Replace('-','')
            $output.Flush($true);$output.Dispose();$output=$null
        }else{$hash=[OptiMiyoo.SourceRemovalLeaseV128]::HashStream($lease.Stream,$null)}
        return [pscustomobject]@{Hash=$hash;Length=$lease.Stream.Length}
    } finally {
        try{if($output){$output.Dispose()}}finally{try{if($sha){$sha.Dispose()}}finally{$lease.Dispose()}}
    }
}

function Get-ApplicationBrokerArchive($Module,[string]$Path,[ValidateSet('','C64','ZX')][string]$InspectMedia='',$RenamedNames=$null) {
    return (& $Module {param($path,$inspectMedia,$renamedNames)
        $profile='Media';$inspection=@{}
        if($inspectMedia){
            $profile='Floppy';$extension='.g64';if($inspectMedia -eq 'ZX'){$extension='.dsk'}
            $extensions=@($extension);if($renamedNames -and $renamedNames.Count){$extensions+=@('.m3u','.m3u8','.cue')}
            $inspection=@{InspectExtensions=$extensions;InspectPayload={param($stream,$length,$name)
                if([IO.Path]::GetExtension($name) -in '.m3u','.m3u8','.cue'){
                    Assert-ConversionDescriptorStream $stream $length $name $renamedNames;return $true
                }
                if([IO.Path]::GetExtension($name) -ieq '.g64'){Assert-G64 -InputStream $stream;return $true}
                return (Test-DskStream $stream $length)
            }}
        }
        $archive=Open-ArchiveWithBudget -Path $path -Profile $profile
        try {return Invoke-ArchiveSandbox -ZipPath $path -Archive $archive -Profile $profile -Operation Hash @inspection}
        finally {$archive.Dispose()}
    } $Path $InspectMedia $RenamedNames)
}

function Assert-ApplicationBrokerPassthroughMedia($Module,$Lease,[string]$Operation) {
    if(-not $Lease -or -not $Lease.Stream -or -not $Lease.Stream.CanRead){throw 'Verified source lease is unavailable for media validation.'}
    $position=$Lease.Stream.Position
    try {
        $Lease.Stream.Position=0
        $valid=& $Module {param($stream,$kind)
            if($kind -eq 'C64'){Assert-G64 -InputStream $stream;return $true}
            return (Test-DskStream $stream $stream.Length)
        } $Lease.Stream $Operation
        if($valid -isnot [bool] -or -not $valid){throw 'Existing disk image structure is invalid; original kept.'}
    } finally {$Lease.Stream.Position=$position}
}

function Add-ApplicationBrokerExpectedFile([hashtable]$Manifest,[string]$Name,$File,[string]$Converter='') {
    Assert-ApplicationBrokerRelative $Name
    if($Manifest.ContainsKey($Name)){
        if($Manifest[$Name].Name -cne $Name){throw 'Required output files differ only by letter case.'}
        if($Manifest[$Name].Hash -cne $File.Hash -or $Manifest[$Name].Length -ne $File.Length){throw 'Two source files map to different content at the same output name.'}
        return
    }
    $Manifest[$Name]=[pscustomobject]@{Name=$Name;Hash=[string]$File.Hash;Length=[long]$File.Length;Converter=$Converter;InputHash=[string]$File.Hash}
}

function Assert-ApplicationBrokerFileNames([hashtable]$Files,[string]$DataKind) {
    if($DataKind -eq 'Zip'){return}
    # The child is not authoritative for CUE spelling checks. Windows merges
    # differently cased parents, leaving at least one reference broken on Linux.
    $directories=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($name in $Files.Keys){
        $parts=$name.Split('/')
        for($i=1;$i -lt $parts.Length;$i++){
            $parent=$parts[0..($i-1)] -join '/'
            if($Files.ContainsKey($parent)){throw 'An output file is also required as a folder.'}
            if($directories.ContainsKey($parent)){
                if($directories[$parent] -cne $parent){throw 'Required output folders differ only by letter case.'}
            }else{$directories.Add($parent,$parent)}
        }
    }
}

function Set-ApplicationBrokerParentCaseConflicts($State,[object[]]$Jobs) {
    $destination=Join-Path $State.OriginalRoot 'DST'
    $existing=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($relative in $State.DestinationSnapshot.Directories){$existing.Add($relative,$relative)}
    $planned=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($job in $Jobs){
        if($job.BlockedReason){continue}
        foreach($write in $job.Writes){
            $relative=Get-ApplicationBrokerRelative $write.Destination $destination
            $parts=$relative.Split('/');$count=$parts.Length-1
            if($write.Folder){$count=$parts.Length}
            $prefix=''
            for($i=0;$i -lt $count;$i++){
                if($prefix){$prefix+='/'};$prefix+=$parts[$i]
                # A whole replacement folder gets its own requested leaf spelling.
                # Only its untouched ancestors must match the existing tree.
                $replacementLeaf=$write.Folder -and $i -eq $parts.Length-1
                if(-not $replacementLeaf -and $existing.ContainsKey($prefix) -and $existing[$prefix] -cne $prefix){
                    $job.BlockedReason='An existing output parent folder uses different letter case; use matching folder spelling or a separate DST.'
                }
                if(-not $planned.ContainsKey($prefix)){$planned.Add($prefix,[pscustomobject]@{Name=$prefix;Jobs=@{};Conflict=$false})}
                $directory=$planned[$prefix];$directory.Jobs[$job.JobId]=$job
                $reason='Planned output parent folders differ only by letter case; use consistent folder spelling.'
                if($directory.Conflict){$job.BlockedReason=$reason}
                elseif($directory.Name -cne $prefix){
                    $directory.Conflict=$true
                    foreach($owner in $directory.Jobs.Values){$owner.BlockedReason=$reason}
                }
            }
        }
    }
}

function Assert-ApplicationBrokerOutputParentCase([string]$Parent,[string]$Root,$Verified) {
    $current=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if($current.Equals([IO.Path]::GetFullPath($Parent).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)){return}
    $relative=Get-ApplicationBrokerRelative $Parent $Root
    foreach($part in $relative.Split('/')){
        $next=Join-Path $current $part
        if(-not $Verified.Contains($next)){
            $actual=$null;$matches=0
            # Filter at the filesystem boundary, then reject short-name aliases.
            # The caller holds this parent and its ancestors throughout sealing.
            foreach($entry in [IO.Directory]::EnumerateDirectories($current,$part,[IO.SearchOption]::TopDirectoryOnly)){
                $name=[IO.Path]::GetFileName($entry)
                if($name.Equals($part,[StringComparison]::OrdinalIgnoreCase)){$actual=$name;$matches++}
            }
            if($matches -ne 1 -or $actual -cne $part){throw 'An output parent folder has different letter case; original kept. Use matching folder spelling or a separate DST.'}
            [void]$Verified.Add($next)
        }
        $current=$next
    }
}

function Get-ApplicationBrokerExpectedFiles($State,$Module,$Job) {
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
                foreach($sbi in @(Get-SbiCompanions $disk.Path)){[pscustomobject]@{Name=(Get-SbiMemberName $disk.Name);Path=$sbi.FullName}}
            } $disk)
            foreach($source in $sources){
                $key=Get-ApplicationBrokerRelative $source.Path $sourceRoot
                if(-not $State.SourceSnapshot.Files.ContainsKey($key)){throw 'A required source file was not present in the frozen snapshot.'}
                # Enforce the worker's required-file check before authorizing output or source removal.
                if($State.SourceSnapshot.Files[$key].Length -eq 0){throw ('Empty file: '+$source.Name)}
                Add-ApplicationBrokerExpectedFile $manifest $source.Name $State.SourceSnapshot.Files[$key]
            }
        }
    }
    return $manifest
}

function New-ApplicationBrokerJob([string]$SourceKey,$SourceJob,$Plan) {
    return [pscustomobject]@{JobId=[Guid]::NewGuid().ToString('N');SourceKey=$SourceKey;ConflictId='';SourceJob=$SourceJob;Plan=$Plan;BlockedReason='';BlockedResult='Failed';Paths=@();SourceHashes=@{};Files=@{};DiskNames=@();Writes=@();Retired=@();Conflicts=@();Decision='Write';PlaylistText=$null;DataKind='';SourceBlockReason='';ContainerHash=''}
}

function Assert-ApplicationBrokerJobPaths($State,[string]$Operation,$Job,[hashtable]$ArchiveFiles) {
    function Assert-PlannedPath([string]$Path,[switch]$Directory) {
        Assert-OptiPathBudget -Path $Path -Directory:$Directory
        Assert-OptiPathBudget -Path ([IO.Path]::GetDirectoryName($Path)) -Directory
    }
    $dst=Join-Path $State.OriginalRoot 'DST';$workDst=Join-Path $State.WorkRoot 'DST'
    # These placeholders match the generated names' lengths; no files are created.
    $hostName='.app_'+('0'*16)+'.tmp'
    foreach($write in $Job.Writes) {
        $relative=Get-ApplicationBrokerRelative $write.Destination $dst
        $childPath=Join-Path $workDst $relative
        Assert-PlannedPath $write.Destination -Directory:([bool]$write.Folder)
        Assert-PlannedPath $childPath -Directory:([bool]$write.Folder)
        $hostData=Join-Path (Join-Path ([IO.Path]::GetDirectoryName($write.Destination)) $hostName) 'data'
        Assert-PlannedPath $hostData -Directory:([bool]$write.Folder)
        if($write.Folder) {
            foreach($name in $Job.Files.Keys) {
                foreach($root in @($write.Destination,$childPath,$hostData)) {Assert-PlannedPath (Join-Path $root $name)}
            }
        }
        if($Operation -in 'C64','ZX') {
            $workerData=Join-Path (Join-Path ([IO.Path]::GetDirectoryName($childPath)) ('.ppg_'+('0'*12)+'.tmp')) 'data'
            Assert-PlannedPath $workerData -Directory:([bool]$write.Folder)
            if($write.Folder){foreach($name in $Job.Files.Keys){Assert-PlannedPath (Join-Path $workerData $name)}}
        }
    }
    # Replacement moves the old tree too. Its members can be longer than the
    # new ones, especially when a short game folder gets a generated backup name.
    Get-ApplicationBrokerBackupManifest $State '' -IndexOnly
    $checkedTargets=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($target in @($Job.Writes)+@($Job.Retired)) {
        $relative=Get-ApplicationBrokerRelative $target.Destination $dst
        if(-not $checkedTargets.Add($relative)){continue}
        $folder=$State.DestinationTree.ContainsKey($relative)
        if(-not $folder -and -not $State.DestinationSnapshot.Files.ContainsKey($relative)){continue}
        $hostBackup=Join-Path ([IO.Path]::GetDirectoryName($target.Destination)) ('.m3u_'+('0'*12)+'.backup')
        $workerName='.m3u_'+('0'*12)+'.backup'
        if($Operation -in 'C64','ZX'){$workerName='.ppg_'+('0'*12)+'.backup'}
        $workerBackup=Join-Path ([IO.Path]::GetDirectoryName((Join-Path $workDst $relative))) $workerName
        $manifest=$null;if($folder){$manifest=Get-ApplicationBrokerBackupManifest $State $relative}
        foreach($backup in @($hostBackup,$workerBackup)) {
            Assert-PlannedPath $backup -Directory:$folder
            if($folder) {
                foreach($name in $manifest.Directories){Assert-PlannedPath (Join-Path $backup $name) -Directory}
                foreach($name in $manifest.Names){Assert-PlannedPath (Join-Path $backup $name)}
            }
        }
    }
    if($Operation -eq 'Playlist') {
        $container=Join-Path $workDst ('.m3u_'+('0'*16)+'.tmp')
        $data=Join-Path $container 'data'
        Assert-PlannedPath $data -Directory:(-not [bool]$Job.Plan.PreserveZip)
        if(-not $Job.Plan.PreserveZip){foreach($name in $Job.Files.Keys){Assert-PlannedPath (Join-Path $data $name)}}
        if($Job.Plan.ZipMode -and -not $Job.Plan.PreserveZip){Assert-PlannedPath (Join-Path $container 'media.zip')}
        if($Job.Plan.HasPlaylist){Assert-PlannedPath (Join-Path $container 'playlist')}
    } else {
        $scratch=Join-Path $State.WorkRoot ('ppg_'+('0'*12))
        $input=Join-Path $scratch 'i';$output=Join-Path $scratch 'o'
        Assert-PlannedPath $input -Directory;Assert-PlannedPath $output -Directory
        foreach($item in $Job.SourceJob.Items) {
            Assert-PlannedPath (Join-Path $input $item.InputName)
            Assert-PlannedPath (Join-Path $output $item.Name)
        }
        # ZIP extraction also writes non-media members, so include their names.
        foreach($zip in @($Job.SourceJob.Items | Where-Object {$_.Type -eq 'Zip'} | Select-Object -ExpandProperty InputPath -Unique)) {
            foreach($name in $ArchiveFiles[$zip].Keys){Assert-PlannedPath (Join-Path $input $name)}
        }
    }
}

function Start-ApplicationBrokerBatch {
    param([Parameter(Mandatory=$true)]$Session,[ValidateSet('Playlist','C64','ZX','SD')][string]$Operation,
          [string]$System,[ValidateSet('Auto','Zip','Loose','Folders')][string]$Storage='Zip',
          [ValidateSet('Keep','Remove')][string]$SourcePolicy='Keep',[ValidateSet('Ask','Overwrite','Skip')][string]$Existing='Ask',
          [ValidateSet('Auto','Zip','Loose','Folders')][string]$SingleStorage='Auto',[scriptblock]$CancellationCheck=$null)
    if(-not $CancellationCheck){
        # Direct startup has no live console session yet. Observe engine Stop
        # inside native verification, before transferring the file lease.
        $batchCommand=$PSCmdlet
        $CancellationCheck={
            if($batchCommand.Stopping){throw [Management.Automation.PipelineStoppedException]::new()}
        }.GetNewClosure()
    }
    if($CancellationCheck){& $CancellationCheck}
    $state=Get-ApplicationBrokerState $Session
    if($state.Batch){throw 'The previous application batch is still active.'}
    if($Operation -eq 'SD'){throw 'SD operations require the dedicated configuration broker.'}
    $src=Join-Path $state.OriginalRoot 'SRC';$dst=Join-Path $state.OriginalRoot 'DST'
    # Check names and lengths here; each original is hash-verified again through
    # its retained read lease below, before any trusted planning reads begin.
    Assert-ApplicationBrokerInventory $state.SourceSnapshot (Get-ApplicationBrokerTree $src -MetadataOnly -CancellationCheck $CancellationCheck) 'Original source tree'
    Assert-ApplicationBrokerInventory $state.DestinationSnapshot (Get-ApplicationBrokerTree $dst -MetadataOnly -CancellationCheck $CancellationCheck) 'Original output tree'
    Assert-ApplicationBrokerSnapshot $state.SourceSnapshot (Get-ApplicationBrokerTree (Join-Path $state.WorkRoot 'SRC') -MaximumEntries ([Math]::Max(1,$state.SourceSnapshot.Files.Count+$state.SourceSnapshot.Directories.Count)) -ExpectedFiles $state.SourceSnapshot.Files -CancellationCheck $CancellationCheck) 'Staged source tree'
    Assert-ApplicationBrokerSnapshot $state.DestinationSnapshot (Get-ApplicationBrokerTree (Join-Path $state.WorkRoot 'DST') -MaximumEntries ([Math]::Max(1,$state.DestinationSnapshot.Files.Count+$state.DestinationSnapshot.Directories.Count)) -ExpectedFiles $state.DestinationSnapshot.Files -CancellationCheck $CancellationCheck) 'Staged output tree'
    $sourcePins=New-Object 'System.Collections.Generic.Dictionary[string,IDisposable]' ([StringComparer]::OrdinalIgnoreCase)
    try {
    # Bind all trusted parsing to the initial copied bytes. Rehashing before and
    # after parsing alone would permit a change-and-revert race during a ZIP or
    # CUE read, producing a plan unrelated to the source-removal baseline.
    foreach($relative in $state.SourceSnapshot.Files.Keys){
        $path=Join-Path $src $relative
        $sourcePins.Add([IO.Path]::GetFullPath($path),(Open-VerifiedSourcePolicyFile -Path $path -ExpectedHash $state.SourceSnapshot.Files[$relative].Hash -Root $src -ReadOnly -CancellationCheck $CancellationCheck))
    }
    foreach($relative in $state.DestinationSnapshot.Files.Keys){
        $path=Join-Path $dst $relative
        $sourcePins.Add([IO.Path]::GetFullPath($path),(Open-VerifiedSourcePolicyFile -Path $path -ExpectedHash $state.DestinationSnapshot.Files[$relative].Hash -Root $dst -ReadOnly -CancellationCheck $CancellationCheck))
    }
    if($CancellationCheck){& $CancellationCheck}
    $module=Get-ApplicationBrokerModule $Operation;$sourceModule=Get-ApplicationBrokerModule 'Playlist'
    $jobs=New-Object 'System.Collections.Generic.List[object]';$profile=$null;$archives=@{}
    if($Operation -eq 'Playlist'){
        $profiles=Get-Content -LiteralPath (Join-Path $script:ApplicationBrokerCodeRoot 'systems.json') -Raw | ConvertFrom-Json
        $selected=@($profiles | Where-Object {$_.Folder -eq $System})
        if($selected.Count -ne 1){throw 'Unknown application system profile.'};$profile=$selected[0]
        $raw=@(& $module {param($src,$profile) $script:DiskExtensions=@($profile.Extensions);Get-Jobs $src $profile} $src $profile)
        if($raw.Count -gt 20000){throw 'This batch contains more than 20,000 jobs. Split the collection into smaller batches.'}
        foreach($sourceJob in $raw){
            if($CancellationCheck){& $CancellationCheck}
            $sourceJob | Add-Member NoteProperty Profile $profile
            $sourceJob | Add-Member NoteProperty OutputPlan $null
            $job=New-ApplicationBrokerJob $sourceJob.SourceKey $sourceJob $null
            try {
                if($sourceJob.Error){throw $sourceJob.Error}
                & $module {param($stem)Assert-GameStem $stem} $sourceJob.Stem
                $media=& $module {param($job,$storage,$singleStorage)Get-GameMediaNames $job $storage $singleStorage} $sourceJob $Storage $SingleStorage
                if(@($media.DiskNames).Count -eq 0){$job.BlockedResult='Skipped';throw 'No supported media images for this system.'}
                $plan=& $module {param($job,$src,$dst,$storage,$media,$singleStorage)Get-PlaylistOutputPlan $job $src $dst $storage $media $singleStorage} $sourceJob $src $dst $Storage $media $SingleStorage
                $sourceJob.OutputPlan=$plan;$job.Plan=$plan;$job.Writes=@($plan.Writes);$job.Retired=@($plan.Retired)
                $job.Files=Get-ApplicationBrokerExpectedFiles $state $module $sourceJob
                if($plan.PreserveZip){$job.ContainerHash=$state.SourceSnapshot.Files[(Get-ApplicationBrokerRelative $sourceJob.Zip $src)].Hash}
                $job.DiskNames=@($media.DiskNames)
                $job.DataKind='Folder';if($plan.ZipMode){$job.DataKind='Zip'}elseif($plan.LooseFiles){$job.DataKind='Files'}
                if($plan.HasPlaylist){$job.PlaylistText=$plan.PlaylistText}
                $job.Conflicts=@(@($plan.Writes)+@($plan.Retired)+@($plan.VisibleCandidates) | Where-Object {Test-Path -LiteralPath $_.Destination})
            } catch {$job.BlockedReason=$_.Exception.Message}
            try {$job.Paths=@(& $module {param($job)Get-JobSourcePaths $job} $sourceJob)} catch {$job.Paths=@($sourceJob.Disks | ForEach-Object {$_.Path});if($sourceJob.Zip){$job.Paths=@($sourceJob.Zip)};$job.SourceBlockReason='Source references could not be resolved.'}
            $jobs.Add($job)
        }
        & $module {param($raw)Set-PlaylistOutputConflicts $raw} $raw
        foreach($job in $jobs){if($job.SourceJob.Error){$job.BlockedReason=$job.SourceJob.Error}}
    } elseif($Operation -in 'C64','ZX'){
        $System=@{C64='COMMODORE';ZX='ZXS'}[$Operation]
        $raw=@(& $module {param($src,$dst,$storage,$operation)Get-ConversionSourceGroups $src $dst $storage $operation} $src $dst $Storage $Operation)
        if($raw.Count -gt 20000){throw 'This batch contains more than 20,000 jobs. Split the collection into smaller batches.'}
        foreach($group in $raw){
            if($CancellationCheck){& $CancellationCheck}
            $plan=$group.Plan;$job=New-ApplicationBrokerJob $group.SourceKey $group $plan
            $job.Paths=@($group.Paths);$job.SourceBlockReason=$group.SourceBlockReason;$job.BlockedReason=$group.Error
            try {
                if($group.Error){if($group.Error -eq 'No supported disk images in this input.'){$job.BlockedResult='Skipped'};throw $group.Error}
                # This map comes from the pinned source inventory, never worker
                # completion claims. Companion bytes remain exact source hashes.
                $renamedNames=& $module {param($items)Get-ConversionRenameMap $items} $group.Items
                foreach($member in $group.Items){
                    $key=Get-ApplicationBrokerRelative $member.InputPath $src
                    if(-not $state.SourceSnapshot.Files.ContainsKey($key)){throw 'Converter input was not present in the frozen source manifest.'}
                    $input=$state.SourceSnapshot.Files[$key]
                    if($member.Type -eq 'Zip'){
                        if(-not $archives.ContainsKey($member.InputPath)){$archives[$member.InputPath]=Get-ApplicationBrokerArchive $module $member.InputPath -InspectMedia $Operation -RenamedNames $renamedNames}
                        $input=$archives[$member.InputPath][$member.EntryName]
                    }
                    if(-not $input){throw 'Converter archive member was not present in the frozen source manifest.'}
                    if($input.Length -gt 512MB){throw 'Disk image exceeds the 512 MiB input limit; original kept.'}
                    if($member.Media -and -not $member.Converter -and $member.Type -ne 'Zip'){Assert-ApplicationBrokerPassthroughMedia $module $sourcePins[[IO.Path]::GetFullPath($member.InputPath)] $Operation}
                    Add-ApplicationBrokerExpectedFile $job.Files $member.Name $input
                    if($member.Converter){$job.Files[$member.Name].Converter=$member.Converter;$job.Files[$member.Name].Hash='';$job.Files[$member.Name].Length=-1L}
                }
                if(-not $job.Files.Count){$job.BlockedResult='Skipped';throw 'No supported disk images.'}
                $job.DiskNames=@($group.Items | Where-Object {$_.Media} | ForEach-Object {$_.Name} | Sort-Object)
                $job.Writes=@($plan.DataWrites);$job.Retired=@()
                $job.DataKind='Zip';if($plan.LooseFiles){$job.DataKind='Files'}elseif($plan.DataWrites[0].Folder){$job.DataKind='Folder'}
                $job.Conflicts=@($plan.DataWrites | Where-Object {Test-Path -LiteralPath $_.Destination})
            } catch {$job.BlockedReason=$_.Exception.Message}
            $jobs.Add($job)
        }
    }
    if($CancellationCheck){& $CancellationCheck}
    if($jobs.Count -gt 20000){throw 'This batch contains more than 20,000 jobs. Split the collection into smaller batches.'}
    $descriptorSnapshot=$null
    if($SourcePolicy -eq 'Remove') {
        $descriptorSnapshot=@{}
        foreach($relative in $state.SourceSnapshot.Files.Keys) {
            if([IO.Path]::GetExtension($relative) -in @('.cue','.m3u','.m3u8')){$descriptorSnapshot[(Join-Path $src $relative)]=$state.SourceSnapshot.Files[$relative]}
        }
    }
    $sourcePlan=& $sourceModule {param($src,$policy,$descriptors)New-SourcePolicyPlan $src $policy -DescriptorSnapshot $descriptors} $src $SourcePolicy $descriptorSnapshot
    foreach($job in $jobs){
        if($CancellationCheck){& $CancellationCheck}
        if(-not $job.BlockedReason){try{Assert-ApplicationBrokerFileNames $job.Files $job.DataKind;Assert-ApplicationBrokerJobPaths $state $Operation $job $archives}catch{$job.BlockedReason=$_.Exception.Message}}
    }
    Set-ApplicationBrokerParentCaseConflicts $state $jobs.ToArray()
    $jobMap=@{};$conflicts=@{}
    foreach($job in $jobs){
        if($CancellationCheck){& $CancellationCheck}
        $jobMap[$job.JobId]=$job
        foreach($path in $job.Paths){$key=Get-ApplicationBrokerRelative $path $src;if($state.SourceSnapshot.Files.ContainsKey($key)){$job.SourceHashes[[IO.Path]::GetFullPath($path)]=$state.SourceSnapshot.Files[$key].Hash}}
        & $sourceModule {param($plan,$job)Add-SourcePolicyJob $plan $job.JobId $job.Paths $job.SourceBlockReason} $sourcePlan $job
        if($Operation -eq 'Playlist' -and $job.SourceBlockReason){$sourcePlan.BlockReason=$job.SourceBlockReason}
        if($job.Conflicts.Count){$job.ConflictId=[Guid]::NewGuid().ToString('N');$conflicts[$job.ConflictId]=$job;$job.Decision=@{Ask='Pending';Overwrite='Overwrite';Skip='Skip'}[$Existing]}
    }
    Assert-ApplicationBrokerSnapshot $state.SourceSnapshot (Get-ApplicationBrokerTree $src -CancellationCheck $CancellationCheck) 'Original source tree'
    Assert-ApplicationBrokerSnapshot $state.DestinationSnapshot (Get-ApplicationBrokerTree $dst -CancellationCheck $CancellationCheck) 'Original output tree'
    if($CancellationCheck){& $CancellationCheck}
    $batch=[pscustomobject]@{BatchId=[Guid]::NewGuid().ToString('N');WorkRoot=$state.WorkRoot;Operation=$Operation;System=$System;Storage=$Storage;SingleStorage=$SingleStorage;SourcePolicy=$SourcePolicy;Existing=$Existing;Module=$module;SourceModule=$sourceModule;SourcePlan=$sourcePlan;Profile=$profile;Jobs=$jobMap;Conflicts=$conflicts;Completed=$false;OverwriteAll=''}
    $state.Batch=$batch
    $view=[pscustomobject]@{BatchId=$batch.BatchId;WorkRoot=$state.WorkRoot;Operation=$Operation;System=$System;Storage=$Storage;SingleStorage=$SingleStorage;SourcePolicy=$SourcePolicy;Existing=$Existing;Jobs=@($jobs | ForEach-Object {[pscustomobject]@{JobId=$_.JobId;SourceKey=$_.SourceKey;ConflictId=$_.ConflictId;BlockedReason=$_.BlockedReason}})}
    $Session.ActiveBatch=$view
    return $view
    } finally {foreach($sourcePin in $sourcePins.Values){$sourcePin.Dispose()}}
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

function New-ApplicationBrokerReceiptIndex($Batch,$ReceiptStore) {
    # Publication starts after native work ends. Copy receipt values into a
    # private snapshot; never attach a stale cache to the mutable live store.
    $kinds=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach($receipt in $ReceiptStore.NativeReceipts) {
        if($receipt.Success -ne $true -or $receipt.BatchId -cne $Batch.BatchId){continue}
        if($receipt.Kind -isnot [string] -or $receipt.InputHash -isnot [string] -or $receipt.OutputHash -isnot [string]){throw 'Invalid host-owned native receipt.'}
        $length=[long]$receipt.Length
        if(-not $kinds.ContainsKey($receipt.Kind)){$kinds.Add($receipt.Kind,(New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)))}
        $inputs=$kinds[$receipt.Kind]
        if(-not $inputs.ContainsKey($receipt.InputHash)) {
            $inputs.Add($receipt.InputHash,[pscustomobject]@{
                Lengths=(New-Object 'Collections.Generic.List[long]');SeenLengths=(New-Object 'Collections.Generic.HashSet[long]')
                Outputs=(New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal))
            })
        }
        $bucket=$inputs[$receipt.InputHash]
        if($bucket.SeenLengths.Add($length)){$bucket.Lengths.Add($length)}
        if(-not $bucket.Outputs.ContainsKey($receipt.OutputHash)){$bucket.Outputs.Add($receipt.OutputHash,(New-Object 'Collections.Generic.HashSet[long]'))}
        [void]$bucket.Outputs[$receipt.OutputHash].Add($length)
    }
    foreach($inputs in $kinds.Values){foreach($bucket in $inputs.Values){$bucket.Lengths=$bucket.Lengths.ToArray();$bucket.PSObject.Properties.Remove('SeenLengths')}}
    $index=[pscustomobject]@{BatchId=[string]$Batch.BatchId;Kinds=$kinds}
    $index.PSObject.TypeNames.Insert(0,'OptiMiyoo.ApplicationBrokerReceiptIndex')
    return $index
}

function Get-ApplicationBrokerReceiptBucket($Expected,$Batch,$Index) {
    if($Index.BatchId -cne $Batch.BatchId -or $Expected.Converter -isnot [string] -or $Expected.InputHash -isnot [string]){return $null}
    if(-not $Index.Kinds.ContainsKey($Expected.Converter)){return $null}
    $inputs=$Index.Kinds[$Expected.Converter]
    if(-not $inputs.ContainsKey($Expected.InputHash)){return $null}
    return $inputs[$Expected.InputHash]
}

function Assert-ApplicationBrokerManifest([hashtable]$Expected,[hashtable]$Actual,$Batch,$ReceiptStore,[switch]$ExactNames) {
    if($Expected.Count -ne $Actual.Count){throw 'Staged output file count does not match the independent source plan.'}
    $actualNames=$null
    if($ExactNames){
        # ZIP member names survive publication verbatim. CUE and playlist
        # references must still resolve on the case-sensitive destination.
        $actualNames=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach($name in $Actual.Keys){[void]$actualNames.Add($name)}
    }
    foreach($name in $Expected.Keys){
        if(-not $Actual.ContainsKey($name)){throw 'Staged output is missing an expected member.'}
        if($ExactNames -and -not $actualNames.Contains($name)){throw 'Staged ZIP member spelling does not match the independent source plan.'}
        $expectedFile=$Expected[$name];$actualFile=$Actual[$name]
        if($expectedFile.Converter){
            $matched=$false
            if($ReceiptStore.PSObject.TypeNames[0] -ceq 'OptiMiyoo.ApplicationBrokerReceiptIndex') {
                $bucket=Get-ApplicationBrokerReceiptBucket $expectedFile $Batch $ReceiptStore
                $matched=$null -ne $bucket -and $actualFile.Hash -is [string] -and $bucket.Outputs.ContainsKey($actualFile.Hash) -and $bucket.Outputs[$actualFile.Hash].Contains([long]$actualFile.Length)
            } else {
                $matching=@($ReceiptStore.NativeReceipts | Where-Object {
                    $_.Success -eq $true -and $_.BatchId -ceq $Batch.BatchId -and $_.Kind -ceq $expectedFile.Converter -and
                    $_.InputHash -ceq $expectedFile.InputHash -and $_.OutputHash -ceq $actualFile.Hash -and [long]$_.Length -eq [long]$actualFile.Length
                })
                $matched=$matching.Count -gt 0
            }
            if(-not $matched){throw 'Converted output has no matching host-owned converter receipt; original kept.'}
        } elseif($expectedFile.Hash -cne $actualFile.Hash -or $expectedFile.Length -ne $actualFile.Length){throw 'Staged output differs from the frozen original content.'}
    }
}

function Get-ApplicationBrokerExpectedLengths($Expected,$Batch,$ReceiptStore) {
    if(-not $Expected.Converter){return ,([long[]]@($Expected.Length))}
    $lengths=@()
    if($ReceiptStore.PSObject.TypeNames[0] -ceq 'OptiMiyoo.ApplicationBrokerReceiptIndex') {
        $bucket=Get-ApplicationBrokerReceiptBucket $Expected $Batch $ReceiptStore
        if($null -ne $bucket){$lengths=$bucket.Lengths}
    } else {
        $lengths=@($ReceiptStore.NativeReceipts | Where-Object {$_.Success -eq $true -and $_.BatchId -ceq $Batch.BatchId -and $_.Kind -ceq $Expected.Converter -and $_.InputHash -ceq $Expected.InputHash} | ForEach-Object {[long]$_.Length} | Select-Object -Unique)
    }
    if(-not $lengths.Count){throw 'Converted output has no matching host-owned receipt.'}
    return ,([long[]]$lengths.Clone())
}

function Assert-ApplicationBrokerOwnership($Batch,$Job,[string]$DestinationRoot,$ReferenceIndex=$null) {
    if($Batch.Operation -eq 'Playlist'){
        & $Batch.Module {param($job,$profile,$dst,$references)
            $script:DiskExtensions=@($profile.Extensions)
            $names=@($job.Plan.ContentNames)+@($job.Files.Keys)
            Assert-NoMediaNesting $job.SourceJob $dst $job.Plan.ZipMode
            Assert-PlaylistOutputOwnership $job.Plan $names $references
        } $Job $Batch.Profile $DestinationRoot $ReferenceIndex
    } elseif($Batch.Operation -in 'C64','ZX'){
        & $Batch.Module {param($group,$dst,$references)Assert-ConversionGroupOwnership $group $dst $references} $Job.SourceJob $DestinationRoot $ReferenceIndex
    } else {throw 'Unknown application operation.'}
}

function Reset-ApplicationBrokerReferences($Batch,$ReferenceIndex,[object[]]$Targets) {
    if(-not $ReferenceIndex){return}
    if($Batch.Operation -eq 'Playlist'){
        & $Batch.Module {param($index,$targets)Reset-PlaylistReferenceIndexTargets $index $targets} $ReferenceIndex $Targets
    } else {
        & $Batch.Module {param($index,$targets)Reset-ConversionDescriptorCacheTargets $index $targets} $ReferenceIndex $Targets
    }
}

function Copy-ApplicationBrokerOutput($State,$Batch,$Job,$ReceiptStore,$ReferenceIndex=$null) {
    $dst=Join-Path $State.OriginalRoot 'DST';$workDst=Join-Path $State.WorkRoot 'DST'
    $items=New-Object 'System.Collections.Generic.List[object]';$owned=New-Object 'System.Collections.Generic.List[string]';$locks=New-Object 'System.Collections.Generic.List[IDisposable]'
    $verifiedParents=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $resourcesTransferred=$false
    try {
        Assert-ApplicationBrokerOwnership $Batch $Job $dst $ReferenceIndex
        foreach($write in $Job.Writes){
            $relative=Get-ApplicationBrokerRelative $write.Destination $dst
            $childPath=Join-Path $workDst $relative
            $parent=[IO.Path]::GetDirectoryName($write.Destination);$anchor=$parent
            while(-not [IO.Directory]::Exists($anchor)){$anchor=[IO.Path]::GetDirectoryName($anchor)}
            $locks.Add((Open-SourcePolicyDirectoryLease $anchor))
            [void][IO.Directory]::CreateDirectory($parent)
            if($parent -ne $anchor){$locks.Add((Open-SourcePolicyDirectoryLease $parent))}
            Assert-ApplicationBrokerOutputParentCase $parent $dst $verifiedParents
            $container=Join-Path $parent ('.app_'+[Guid]::NewGuid().ToString('N').Substring(0,16)+'.tmp')
            # Supply the protected DACL in CreateDirectory itself: there is no
            # interval where this folder inherits a broad application ACL.
            [OptiMiyoo.ApplicationBrokerLease]::CreatePrivateDirectory($container)
            $owned.Add($container)
            $stage=Join-Path $container 'data'
            $playlist=($write.PSObject.Properties['Role'] -and $write.Role -eq 'Playlist')
            $expected=$Job.Files
            if($Job.DataKind -eq 'Files' -and -not $playlist){
                if(-not $write.PSObject.Properties['MemberName'] -or -not $Job.Files.ContainsKey($write.MemberName)){throw 'Loose output has no independently planned source member.'}
                $expected=@{};$expected[$write.MemberName]=$Job.Files[$write.MemberName]
            }
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
                if($Job.DataKind -eq 'Files'){
                    if($expected.Count -ne 1){throw 'Single-file output plan has multiple members.'}
                    $lengths=Get-ApplicationBrokerExpectedLengths $expected[@($expected.Keys)[0]] $Batch $ReceiptStore
                }
                elseif($Job.ContainerHash){$lengths=@($State.SourceSnapshot.Files[(Get-ApplicationBrokerRelative $Job.SourceJob.Zip (Join-Path $State.OriginalRoot 'SRC'))].Length)}
                $copied=Get-ApplicationBrokerFile $childPath $workDst $stage -SingleLink -AllowedLengths $lengths -ArchiveBudget:($Job.DataKind -eq 'Zip')
                if($Job.ContainerHash -and $copied.Hash -cne $Job.ContainerHash){throw 'Archive that required no conversion differs from the original ZIP.'}
                $actual=@{}
                if($Job.DataKind -eq 'Zip'){$actual=Get-ApplicationBrokerArchive $Batch.Module $stage}
                else {
                    if($expected.Count -ne 1){throw 'Single-file output plan has multiple members.'}
                    $name=@($expected.Keys)[0];$actual[$name]=$copied
                }
                Assert-ApplicationBrokerManifest $expected $actual $Batch $ReceiptStore -ExactNames:($Job.DataKind -eq 'Zip')
                $items.Add([pscustomobject]@{Staged=$stage;Destination=$write.Destination;Folder=$false;Hash=$copied.Hash})
            }
        }
        $sealed=[pscustomobject]@{Items=$items.ToArray();Owned=$owned.ToArray();Locks=$locks}
        $resourcesTransferred=$true
        return $sealed
    } finally {
        # Engine Stop bypasses catch. Before return, this function still owns
        # every private copy and directory lease; the caller has no sealed set.
        if(-not $resourcesTransferred){
            try {
                foreach($path in $owned){if(Test-Path -LiteralPath $path){try{Remove-SourcePolicyOwnedPath $path ([IO.Path]::GetDirectoryName($path))}catch{Write-Warning ('Unpublished broker staging retained: '+(ConvertTo-SafeExternalText $path))}}}
            } finally {foreach($lock in $locks){$lock.Dispose()}}
        }
    }
}

function Get-ApplicationBrokerBackupManifest($State,[string]$Relative,[switch]$IndexOnly) {
    # Each snapshot entry is indexed once. A folder replacement then visits only
    # its descendants, rather than rescanning the entire DST for every game.
    if($null -eq $State.DestinationTree) {
        $tree=@{}
        foreach($name in @('')+@($State.DestinationSnapshot.Directories)){$tree[$name]=[pscustomobject]@{Files=(New-Object 'Collections.Generic.List[string]');Children=(New-Object 'Collections.Generic.List[string]')}}
        foreach($name in $State.DestinationSnapshot.Directories){$cut=$name.LastIndexOf('/');$parent='';if($cut -ge 0){$parent=$name.Substring(0,$cut)};$tree[$parent].Children.Add($name)}
        foreach($name in $State.DestinationSnapshot.Files.Keys){$cut=$name.LastIndexOf('/');$parent='';if($cut -ge 0){$parent=$name.Substring(0,$cut)};$tree[$parent].Files.Add($name)}
        $State.DestinationTree=$tree
    }
    if($IndexOnly){return}
    if(-not $State.DestinationTree.ContainsKey($Relative)){throw 'An unapproved output directory appeared during publication; previous output kept.'}
    $names=New-Object 'Collections.Generic.List[string]';$lengths=New-Object 'Collections.Generic.List[long]';$hashes=New-Object 'Collections.Generic.List[string]';$directories=New-Object 'Collections.Generic.List[string]'
    $prefix=$Relative+'/'
    $pending=New-Object 'Collections.Generic.Queue[string]';$pending.Enqueue($Relative)
    while($pending.Count){
        $node=$State.DestinationTree[$pending.Dequeue()]
        foreach($name in $node.Files){$file=$State.DestinationSnapshot.Files[$name];$names.Add($name.Substring($prefix.Length));$lengths.Add($file.Length);$hashes.Add($file.Hash)}
        foreach($name in $node.Children){$directories.Add($name.Substring($prefix.Length));$pending.Enqueue($name)}
    }
    return [pscustomobject]@{Names=$names.ToArray();Lengths=$lengths.ToArray();Hashes=$hashes.ToArray();Directories=$directories.ToArray()}
}

function Open-ApplicationBrokerBackup($State,[string]$Destination,[string]$Backup,[bool]$Folder,[scriptblock]$FolderManifest) {
    $prefix=[IO.Path]::GetFullPath((Join-Path $State.OriginalRoot 'DST')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $full=[IO.Path]::GetFullPath($Destination)
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Backup destination is outside the approved output root.'}
    $relative=$full.Substring($prefix.Length).Replace('\','/')
    if($Folder) {
        if(-not $FolderManifest){throw 'Approved folder manifest provider is unavailable.'}
        $manifest=& $FolderManifest $State $relative
    } else {
        if(-not $State.DestinationSnapshot.Files.ContainsKey($relative)){throw 'An unapproved output file appeared during publication; previous output kept.'}
        $file=$State.DestinationSnapshot.Files[$relative]
        $manifest=[pscustomobject]@{Names=[string[]]@('');Lengths=[long[]]@($file.Length);Hashes=[string[]]@($file.Hash);Directories=[string[]]@()}
    }
    return [OptiMiyoo.ApplicationBrokerLease]::OpenBackup($Backup,$Folder,$manifest.Names,$manifest.Lengths,$manifest.Hashes,$manifest.Directories)
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
    $referenceIndex=$null;$sourceInventoryGuard=$null;$sourceCleanupContext=$null
    try {
        Assert-ApplicationBrokerSnapshot $state.SourceSnapshot (Get-ApplicationBrokerTree $src) 'Original source tree'
        Assert-ApplicationBrokerSnapshot $state.DestinationSnapshot (Get-ApplicationBrokerTree $dst) 'Original output tree'
        $receiptIndex=New-ApplicationBrokerReceiptIndex $batch $ReceiptStore
        if($batch.Operation -eq 'Playlist'){$referenceIndex=& $batch.Module {param($root)New-PlaylistReferenceIndex $root} $dst}
        else {$referenceIndex=& $batch.Module {param($root)New-ConversionDescriptorCache $root} $dst}
        foreach($id in $CompletedJobIds){
            $job=$batch.Jobs[$id];$sealed=$null;$commit=$null
            try {
                $sealed=Copy-ApplicationBrokerOutput $state $batch $job $receiptIndex $referenceIndex
                Assert-ApplicationBrokerOwnership $batch $job $dst $referenceIndex
                # Reuse the verified publication and rollback logic for all output layouts.
                $backupFactory=(Get-Command Open-ApplicationBrokerBackup).ScriptBlock
                $folderManifest=(Get-Command Get-ApplicationBrokerBackupManifest).ScriptBlock
                $validateBackup={param($destination,$backup,$folder)& $backupFactory $state $destination $backup $folder $folderManifest}.GetNewClosure()
                $validatePublication=$null
                if($batch.Operation -eq 'Playlist'){
                    # These private paths come from host sealing and captured
                    # transaction backups, never a worker-supplied exclusion.
                    $publicationPrivate=@($sealed.Owned | ForEach-Object {[pscustomobject]@{Destination=$_;Folder=$true}})
                    $validatePublication={param($capturedTargets,$capturedBackups)
                        & $batch.Module {param($plan,$targets,$references,$privateTargets)Assert-NoForeignPlaylistReferences $plan $targets $references -ProtectedPublication -PrivateTargets $privateTargets} $job.Plan $capturedTargets $referenceIndex (@($publicationPrivate)+@($capturedBackups))
                    }.GetNewClosure()
                }else{
                    $publicationPrivate=@($sealed.Owned | ForEach-Object {[pscustomobject]@{Destination=$_;Folder=$true}})
                    $validatePublication={param($capturedTargets,$capturedBackups)
                        & $batch.Module {param($group,$root,$references,$targets,$privateTargets)Assert-ConversionGroupOwnership $group $root $references -ProtectedPublication -CapturedTargets $targets -PrivateTargets $privateTargets} $job.SourceJob $dst $referenceIndex $capturedTargets (@($publicationPrivate)+@($capturedBackups))
                    }.GetNewClosure()
                }
                Reset-ApplicationBrokerReferences $batch $referenceIndex (@($job.Writes)+@($job.Retired)+@($sealed.Owned | ForEach-Object {[pscustomobject]@{Destination=$_;Folder=$true}}))
                $commit=& $batch.SourceModule {param($items,$overwrite,$retired,$validator,$publicationValidator)Install-PlaylistSet $items $overwrite $retired -ValidateBackup $validator -ValidatePublication $publicationValidator} $sealed.Items ($job.Decision -eq 'Overwrite') $job.Retired $validateBackup $validatePublication
                & $batch.SourceModule {param($plan,$job,$items)Complete-SourcePolicyJob $plan $job.JobId $job.SourceHashes $items} $batch.SourcePlan $job $sealed.Items
                $writtenResult='Written';if($commit.Replaced){$writtenResult='Overwritten'}
                $results.Add([pscustomobject]@{JobId=$id;SourceKey=$job.SourceKey;Result=$writtenResult;Detail='Output independently verified and published.'})
            } catch {$results.Add([pscustomobject]@{JobId=$id;SourceKey=$job.SourceKey;Result='Failed';Detail=$_.Exception.Message})}
            finally {
                if($commit){foreach($lock in $commit.Locks){$lock.Dispose()}}
                if($sealed){
                    foreach($path in $sealed.Owned){
                        Reset-ApplicationBrokerReferences $batch $referenceIndex @([pscustomobject]@{Destination=$path;Folder=$true})
                        $preserve=@($sealed.Items | Where-Object {$_.PreserveStaging -and $_.Staged.StartsWith($path,[StringComparison]::OrdinalIgnoreCase)}).Count -gt 0
                        if(-not $preserve -and (Test-Path -LiteralPath $path)){try{Remove-SourcePolicyOwnedPath $path ([IO.Path]::GetDirectoryName($path))}catch{Write-Warning ('Broker staging retained: '+(ConvertTo-SafeExternalText $path))}}
                    }
                    foreach($lock in $sealed.Locks){$lock.Dispose()}
                }
            }
        }
        # Hold every frozen descriptor before the final inventory. Notifications
        # cover namespace changes; verified leases prevent delayed CUE writes.
        # Cleanup borrows this context without reopening tracked deletion leases.
        if($batch.SourcePolicy -eq 'Remove' -and -not $batch.SourcePlan.BlockReason){
            try {
                $sourceInventoryGuard=Open-SourcePolicyInventoryGuard $src
                $sourceCleanupContext=& $batch.SourceModule {param($plan,$guard)Open-SourcePolicyCleanupContext $plan -InventoryGuard $guard} $batch.SourcePlan $sourceInventoryGuard
            } catch {$batch.SourcePlan.BlockReason='Source inventory or CUE descriptors could not be protected; all originals kept. '+$_.Exception.Message}
        }
        if(-not $batch.SourcePlan.BlockReason){
            try {
                $descriptorLeases=$null;if($sourceCleanupContext){$descriptorLeases=$sourceCleanupContext.ReferenceLeases}
                Assert-ApplicationBrokerSnapshot $state.SourceSnapshot (Get-ApplicationBrokerTree $src -BorrowedSourceLeases $descriptorLeases) 'Original source tree'
            }
            catch {$batch.SourcePlan.BlockReason='Original source inventory changed; all originals kept.'}
        }
        & $batch.SourceModule {param($plan,$context)Invoke-SourcePolicyCleanup $plan {param($label,$message)if($label -eq 'WARNING'){Write-Warning (ConvertTo-SafeExternalText $message)}} -CleanupContext $context} $batch.SourcePlan $sourceCleanupContext
        foreach($job in $batch.Jobs.Values){
            if(-not $ids.Contains($job.JobId)){
                $detail='The worker did not complete this input; original kept.'
                $uncompletedResult='Failed'
                if($job.BlockedReason){$detail=$job.BlockedReason;$uncompletedResult=$job.BlockedResult}elseif($job.Decision -eq 'Skip'){$detail='Overwrite declined; original kept.';$uncompletedResult='Skipped'}
                $results.Add([pscustomobject]@{JobId=$job.JobId;SourceKey=$job.SourceKey;Result=$uncompletedResult;Detail=$detail})
            }
        }
        foreach($result in $results){
            $job=$batch.Jobs[$result.JobId];$playlist='';$destination='';$diskImages=0;$sourceName=$job.SourceKey
            if($batch.Operation -in 'Playlist','C64','ZX'){$sourceName=$job.SourceJob.Source}
            if($job.Plan){
                if($batch.Operation -eq 'Playlist'){
                    $diskImages=@($job.Plan.DiskNames).Count;$destination=$job.Plan.RelativeData
                    if($job.Plan.HasPlaylist){$playlist=Get-ApplicationBrokerRelative $job.Plan.M3uPath $dst}
                }
                else {$diskImages=@($job.SourceJob.Items | Where-Object {$_.Media}).Count;$destination=$job.Plan.RelativeData}
            }
            $result | Add-Member NoteProperty System $batch.System
            $result | Add-Member NoteProperty Source $sourceName
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
    } finally {
        try {if($sourceCleanupContext){$sourceCleanupContext.Dispose()}}
        finally {
            try {if($sourceInventoryGuard){$sourceInventoryGuard.Dispose()}}
            finally {
                try {if($referenceIndex){
                    if($batch.Operation -eq 'Playlist'){& $batch.Module {param($index)Close-PlaylistReferenceIndex $index} $referenceIndex}
                    else {& $batch.Module {param($index)Close-ConversionDescriptorCache $index} $referenceIndex}
                }}
                finally {$Session.ActiveBatch=$null}
            }
        }
    }
}

function Close-ApplicationBrokerSession($Session) {
    $state=Get-ApplicationBrokerState $Session
    $state.Closed=$true;$state.Batch=$null;$Session.ActiveBatch=$null
    $script:ApplicationBrokerStates.Remove($state.Id)
    # Session owner, not an untrusted completion message, owns scratch cleanup.
}
