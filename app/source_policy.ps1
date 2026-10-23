. (Join-Path $PSScriptRoot 'compile_support.ps1')
# Shared source-retention checks. Windows PowerShell 5.1 compatible.
# A source can be removed only when every job using it has verified output.
function Read-SourcePolicy([string]$Title) {
    while ($true) {
        $answer=Read-DisplayInput 'Choose originals [Enter = 1, Keep]' ($Title+' / originals') @(
            '1. KEEP originals in SRC (default)',
            '2. REMOVE originals after verified success',
            'Skipped or failed items always keep their originals.',
            'B. Back to output settings     Q. Exit')
        switch ($answer) {
            '' {return 'Keep'}
            '1' {return 'Keep'}
            '2' {return 'Remove'}
            'B' {return 'Back'}
            'Q' {return 'Exit'}
        }
    }
}

function Assert-SourcePolicyPath([string]$Path,[string]$Root) {
    $full=[IO.Path]::GetFullPath($Path)
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'Source is outside SRC; original kept.'}
    $item=Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Source is not a regular file; original kept.'}
    Assert-PlainOutputParents $full ([IO.Path]::GetPathRoot($full))
}

function Get-SourcePolicyHash([string]$Path,[scriptblock]$Progress=$null) {
    $stream=$null; $sha=$null
    try {
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if ($Progress) {
            Initialize-SourcePolicyNative
            $callback={param([long]$done,[long]$total) try {& $Progress $done $total | Out-Null} catch {}}.GetNewClosure()
            return [OptiMiyoo.SourceRemovalLeaseV128]::HashStream($stream,[Action[long,long]]$callback)
        }
        $sha=[Security.Cryptography.SHA256]::Create()
        return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')
    } finally {
        if ($sha) {$sha.Dispose()}
        if ($stream) {$stream.Dispose()}
    }
}

# The deletion handle is also the verification handle. No pathname delete fallback.
# API references: learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-createfilew
# and nf-fileapi-setfileinformationbyhandle; FileDispositionInfo is available since Vista.
function Initialize-SourcePolicyNative {
    if ('OptiMiyoo.SourceRemovalLeaseV128' -as [type]) {return}
    Add-OptiMiyooType -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
namespace OptiMiyoo {
    public sealed class SourceRemovalLeaseV128 : IDisposable {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInformation {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime, AccessTime, WriteTime;
            public uint VolumeSerial, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct FileDisposition { public byte DeleteFile; }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int informationClass, ref FileDisposition information, uint size);
        private readonly List<SafeFileHandle> parents = new List<SafeFileHandle>();
        private FileStream stream;
        private bool verified;
        private bool canDelete;
        public FileStream Stream { get { return stream; } }
        private bool disposed;
        private SourceRemovalLeaseV128() {}
        private static FileInformation Inspect(SafeFileHandle handle) {
            FileInformation information;
            if (!GetFileInformationByHandle(handle, out information)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return information;
        }
        private static SafeFileHandle OpenHandle(string path, bool directory, bool removal) {
            // Share-read only: deny competing writes and delete/rename handles.
            // Attribute-only opens are exempt from share checks: LIST_DIRECTORY
            // is required for an ancestor handle to participate in sharing.
            uint access = directory ? 0x81U : (removal ? 0x80010000U : 0x80000000U); // LIST_DIRECTORY | READ_ATTRIBUTES, or file read (+ DELETE)
            uint flags = 0x00200000U | (directory ? 0x02000000U : 0U); // OPEN_REPARSE_POINT | BACKUP_SEMANTICS
            SafeFileHandle handle = CreateFileW(path, access, 1, IntPtr.Zero, 3, flags, IntPtr.Zero);
            if (handle.IsInvalid) {
                int error = Marshal.GetLastWin32Error(); handle.Dispose();
                throw new Win32Exception(error, "File could not be locked safely: " + path + " (" + error + ": " + new Win32Exception(error).Message + ")");
            }
            try {
                FileInformation information = Inspect(handle);
                if ((information.Attributes & 0x400U) != 0 || ((information.Attributes & 0x10U) != 0) != directory)
                    throw new IOException("Source path is linked or has the wrong file type; keeping it: " + path);
                if (!directory && removal && (information.Attributes & 1U) != 0)
                    throw new IOException("Original is read-only; keeping it: " + path);
                return handle;
            } catch { handle.Dispose(); throw; }
        }
        public static SourceRemovalLeaseV128 Open(string path, string root) { return OpenCore(path, root, true); }
        public static SourceRemovalLeaseV128 OpenRead(string path) { return OpenCore(path, Path.GetPathRoot(Path.GetFullPath(path)), false); }
        private static SourceRemovalLeaseV128 OpenCore(string path, string root, bool removal) {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT)
                throw new PlatformNotSupportedException("Verified original removal requires Windows; original kept on this platform.");
            string full = Path.GetFullPath(path);
            string prefix = Path.GetFullPath(root).TrimEnd('\\', '/') + Path.DirectorySeparatorChar;
            if (!full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new IOException("Source is outside SRC; original kept.");
            if (full.Substring(prefix.Length).IndexOf(':') >= 0) throw new IOException("Alternate source streams are not removable; original kept.");
            SourceRemovalLeaseV128 lease = new SourceRemovalLeaseV128();
            lease.canDelete = removal;
            try {
                // Pin and inspect each ancestor from the filesystem root down. This
                // prevents a parent being renamed/replaced with a junction after checking.
                List<string> ancestors = new List<string>();
                string parent = Path.GetDirectoryName(full);
                while (!String.IsNullOrEmpty(parent)) {
                    ancestors.Add(parent);
                    DirectoryInfo next = Directory.GetParent(parent);
                    parent = next == null ? null : next.FullName;
                }
                ancestors.Reverse();
                foreach (string ancestor in ancestors) lease.parents.Add(OpenHandle(ancestor, true, false));
                SafeFileHandle file = OpenHandle(full, false, removal);
                try { lease.stream = new FileStream(file, FileAccess.Read, 1048576, false); }
                catch { file.Dispose(); throw; }
                return lease;
            } catch { lease.Dispose(); throw; }
        }
        public static string HashStream(Stream input, Action<long,long> progress) {
            long length = input.Length, total = 0;
            byte[] buffer = new byte[1048576];
            Stopwatch clock = Stopwatch.StartNew();
            if (progress != null) progress(0, length);
            using (SHA256 sha = SHA256.Create()) {
                int read;
                while ((read = input.Read(buffer, 0, buffer.Length)) > 0) {
                    sha.TransformBlock(buffer, 0, read, buffer, 0); total += read;
                    if (progress != null && clock.ElapsedMilliseconds >= 150) { progress(total, length); clock.Restart(); }
                }
                sha.TransformFinalBlock(new byte[0], 0, 0);
                if (total != length) throw new IOException("Original verification read was incomplete; original kept.");
                if (progress != null) progress(total, length);
                return BitConverter.ToString(sha.Hash).Replace("-", "");
            }
        }
        public void Verify(string expected, Action<long,long> progress) {
            if (disposed) throw new ObjectDisposedException("SourceRemovalLease");
            verified = false;
            if (String.IsNullOrEmpty(expected)) throw new IOException("Expected source hash is missing; original kept.");
            stream.Position = 0;
            if (!String.Equals(HashStream(stream, progress), expected, StringComparison.OrdinalIgnoreCase))
                throw new IOException("Original changed during processing; keeping its complete source set.");
            verified = true;
        }
        public void Delete() {
            if (disposed || !verified || !canDelete) throw new IOException("Source was not verified through its deletion handle; original kept.");
            FileDisposition disposition = new FileDisposition(); disposition.DeleteFile = 1;
            // The structure contains a Windows BOOLEAN (one byte), not a BOOL.
            if (!SetFileInformationByHandle(stream.SafeFileHandle, 4, ref disposition, 1)) {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(error, "Original could not be removed; keeping it. (" + error + ": " + new Win32Exception(error).Message + ")");
            }
            Dispose();
        }
        public void Dispose() {
            if (disposed) return;
            disposed = true;
            try { if (stream != null) { stream.Dispose(); stream = null; } }
            finally {
                for (int i = parents.Count - 1; i >= 0; i--) parents[i].Dispose();
                parents.Clear();
            }
        }
    }
}
'@
}

function Get-SourcePolicyProgressAction([scriptblock]$Progress,[string]$Stage,[string]$Detail) {
    if (-not $Progress) {return $null}
    # A progress renderer must not change the outcome of verified file operations.
    $callback={param([long]$done,[long]$total) try {& $Progress $Stage $Detail $done $total | Out-Null} catch {}}.GetNewClosure()
    return [Action[long,long]]$callback
}

function Open-SourcePolicyRemovalLease([string]$Path,[string]$Root) {
    # Deliberate test boundary. Production never falls back to pathname deletion.
    Initialize-SourcePolicyNative
    return [OptiMiyoo.SourceRemovalLeaseV128]::Open($Path,$Root)
}

function Open-SourcePolicyReadLease([string]$Path,[string]$Root) {
    Assert-SourcePolicyPath $Path $Root
    Initialize-SourcePolicyNative
    return [OptiMiyoo.SourceRemovalLeaseV128]::OpenRead($Path)
}

function Open-VerifiedSourcePolicyFile([string]$Path,[string]$ExpectedHash,[string]$Root,[scriptblock]$Progress=$null,[switch]$ReadOnly) {
    Assert-SourcePolicyPath $Path $Root
    $lease=$null
    try {
        if ($ReadOnly) {$lease=Open-SourcePolicyReadLease $Path $Root}
        else {$lease=Open-SourcePolicyRemovalLease $Path $Root}
        $lease.Verify($ExpectedHash,(Get-SourcePolicyProgressAction $Progress 'Checking originals' $Path))
        return $lease
    } catch {if ($lease) {$lease.Dispose()}; throw}
}

function Remove-SourcePolicyFile([string]$Path,$Lease) {
    if (-not $Lease) {throw 'Verified deletion handle is missing; original kept.'}
    $Lease.Delete()
    if (Test-Path -LiteralPath $Path) {throw 'An original is still present at this path; it was not deleted by pathname.'}
}

function Remove-VerifiedSourceFile([string]$Path,[string]$ExpectedHash,[string]$Root,[scriptblock]$Progress=$null) {
    $lease=$null
    try {
        $lease=Open-VerifiedSourcePolicyFile $Path $ExpectedHash $Root $Progress
        if ($Progress) {try {& $Progress 'Removing verified originals' $Path 0 0 | Out-Null} catch {}}
        Remove-SourcePolicyFile $Path $lease
    } finally {if ($lease) {$lease.Dispose()}}
}

function Open-SourcePolicyOutputs([object[]]$Outputs,[scriptblock]$Progress=$null) {
    $locks=New-Object 'System.Collections.Generic.List[System.IDisposable]'
    try {
        foreach ($output in $Outputs) {
            $files=@()
            Assert-PlainOutputParents $output.Destination ([IO.Path]::GetPathRoot($output.Destination))
            $item=Get-Item -LiteralPath $output.Destination -Force -ErrorAction Stop
            if ([bool]$item.PSIsContainer -ne [bool]$output.Folder -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Verified output was replaced or linked; original kept.'}
            if ($output.Folder) {
                if ($null -eq $output.Manifest -or $output.Manifest.Count -eq 0) {throw 'Output manifest is missing; original kept.'}
                # Enumerate without following directory links.
                $pending=New-Object 'System.Collections.Generic.Stack[string]'
                $pending.Push($output.Destination); $count=0
                while ($pending.Count -gt 0) {
                    foreach ($entry in @(Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop)) {
                        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Output contains a link; original kept.'}
                        if ($entry.PSIsContainer) {$pending.Push($entry.FullName)} else {$count++}
                    }
                }
                if ($count -ne $output.Manifest.Count) {throw 'Output file count changed; original kept.'}
                foreach ($name in $output.Manifest.Keys) {
                    $files+=@{Path=(Join-Path $output.Destination $name); Hash=$output.Manifest[$name].Hash}
                }
            } else {$files+=@{Path=$output.Destination; Hash=$output.Hash}}
            foreach ($file in $files) {
                if (-not $file.Hash) {throw 'Expected output hash is missing; original kept.'}
                Initialize-SourcePolicyNative
                if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                    $lock=[OptiMiyoo.SourceRemovalLeaseV128]::OpenRead($file.Path); $stream=$lock.Stream
                } else {
                    $lock=[IO.File]::Open($file.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read); $stream=$lock
                }
                $locks.Add($lock)
                $hash=[OptiMiyoo.SourceRemovalLeaseV128]::HashStream($stream,(Get-SourcePolicyProgressAction $Progress 'Checking installed outputs' $file.Path))
                if ($hash -ne $file.Hash) {throw ('Output changed after verification; original kept: '+$file.Path)}
            }
        }
        return ,$locks
    } catch {
        foreach ($lock in $locks) {$lock.Dispose()}
        throw
    }
}

function New-SourcePolicyPlan([string]$Root,[string]$Policy) {
    return [pscustomobject]@{Root=$Root; Policy=$Policy; Files=@{}; Jobs=@{}; References=@{}; ReferenceHashes=@{}; BlockReason=''}
}

function Add-SourcePolicyJob($Plan,[string]$Id,[string[]]$Paths,[string]$BlockReason='') {
    $unique=@{}; $declared=@{}
    foreach ($path in $Paths) {
        $full=[IO.Path]::GetFullPath($path)
        if ($declared.ContainsKey($full)) {continue}
        $declared[$full]=$true
        # Preserve ownership even when a track is currently missing. If it appears
        # before a later job is planned, the earlier failed/skipped owner still protects it.
        if (-not $Plan.References.ContainsKey($full)) {$Plan.References[$full]=New-Object 'System.Collections.Generic.List[string]'}
        $Plan.References[$full].Add($Id)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {continue}
        $unique[$full]=$true
        if (-not $Plan.Files.ContainsKey($full)) {
            $Plan.Files[$full]=[pscustomobject]@{Path=$full; Owners=$Plan.References[$full]; State='Kept'; Reason='Not processed successfully.'}
        }
    }
    $Plan.Jobs[$Id]=[pscustomobject]@{Paths=@($unique.Keys); Hashes=@{}; Outputs=@(); Succeeded=$false; BlockReason=$BlockReason}
    if ($Plan.Policy -ne 'Remove') {return}
    foreach ($full in @($unique.Keys | Where-Object {[IO.Path]::GetExtension($_) -ieq '.cue'})) {
        $snapshot=$null; $sha=$null
        try {
            Assert-SourcePolicyPath $full $Plan.Root
            $snapshot=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            # Re-read while held: the reference list must describe the same CUE
            # whose starting hash will guard the ownership graph during cleanup.
            if (Get-Command Get-CueFiles -ErrorAction SilentlyContinue) {
                foreach ($name in @(Get-CueFiles $full)) {
                    $reference=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($full)) $name))
                    if (-not $declared.ContainsKey($reference)) {throw 'CUE references changed during planning.'}
                }
            }
            $sha=[Security.Cryptography.SHA256]::Create()
            $hash=[BitConverter]::ToString($sha.ComputeHash($snapshot)).Replace('-','')
            if ($Plan.ReferenceHashes.ContainsKey($full) -and $Plan.ReferenceHashes[$full] -ne $hash) {throw 'A shared CUE changed during planning.'}
            $Plan.ReferenceHashes[$full]=$hash
        } catch {$Plan.BlockReason='Source references could not be frozen safely; originals kept for this batch. '+$_.Exception.Message}
        finally {if ($sha) {$sha.Dispose()}; if ($snapshot) {$snapshot.Dispose()}}
    }
}

function Complete-SourcePolicyJob($Plan,[string]$Id,[hashtable]$Hashes,[object[]]$Outputs) {
    $job=$Plan.Jobs[$Id]
    $job.Hashes=$Hashes; $job.Outputs=$Outputs; $job.Succeeded=$true
}

function Invoke-SourcePolicyCleanup($Plan,[scriptblock]$Report,[scriptblock]$Progress=$null) {
    if ($Plan.Policy -ne 'Remove') {return}
    if ($Plan.BlockReason) {
        foreach ($file in $Plan.Files.Values) {
            $file.Reason=$Plan.BlockReason
            if (@($file.Owners | Where-Object {$Plan.Jobs[$_].Succeeded}).Count -gt 0) {$file.State='Failed'}
        }
        & $Report 'WARNING' $Plan.BlockReason
        return
    }
    foreach ($file in $Plan.Files.Values) {
        $expected=$null; $eligible=$true
        foreach ($id in $file.Owners) {
            $job=$Plan.Jobs[$id]
            if (-not $job.Succeeded -or $job.BlockReason) {
                $eligible=$false; $file.Reason='A dependent output was skipped or failed.'
                if ($job.BlockReason) {$file.Reason=$job.BlockReason}
                break
            }
            if (-not $job.Hashes.ContainsKey($file.Path) -or -not $job.Hashes[$file.Path]) {
                $eligible=$false; $file.Reason='Source copy was not verified.'; break
            }
            if ($expected -and $expected -ne $job.Hashes[$file.Path]) {
                $eligible=$false; $file.State='Failed'; $file.Reason='Source changed between dependent jobs.'; break
            }
            $expected=$job.Hashes[$file.Path]
        }
        if ($eligible) {$file.State='Ready'}
    }
    if (@($Plan.Files.Values | Where-Object {$_.State -eq 'Ready'}).Count -eq 0) {
        foreach ($file in @($Plan.Files.Values | Sort-Object Path)) {
            $kind='KEPT'; if ($file.State -eq 'Failed') {$kind='WARNING'}
            & $Report $kind ($file.Path+' | '+$file.Reason)
        }
        return
    }
    $referenceLeases=@{}
    try {
        # CUEs describe shared dependencies, including those of skipped jobs.
        # Hold all of these small descriptors until cleanup ends so the ownership
        # graph cannot change between otherwise independent source components.
        foreach ($path in @($Plan.ReferenceHashes.Keys | Sort-Object)) {
            try {$referenceLeases[$path]=Open-VerifiedSourcePolicyFile $path $Plan.ReferenceHashes[$path] $Plan.Root $Progress -ReadOnly:($Plan.Files[$path].State -ne 'Ready')}
            catch {
                $reason='A CUE changed or could not be locked; all originals kept to preserve source references. '+$_.Exception.Message
                foreach ($file in $Plan.Files.Values) {if ($file.State -eq 'Ready') {$file.State='Kept'}; $file.Reason=$reason}
                if ($Plan.Files.ContainsKey($path)) {$Plan.Files[$path].State='Failed'}
                $Plan.BlockReason=$reason
                break
            }
        }
        if (-not $Plan.BlockReason) {
            # Validate connected ownership components together. A changed source
            # must not leave a retained CUE without its unchanged tracks. Independent
            # games use bounded sets of source/output handles, not whole-batch locks.
            $visited=@{}
            foreach ($start in @($Plan.Files.Keys | Sort-Object)) {
                if ($visited.ContainsKey($start)) {continue}
                $pending=New-Object 'System.Collections.Generic.Queue[string]'
                $component=New-Object 'System.Collections.Generic.List[object]'
                $pending.Enqueue($start); $visited[$start]=$true
                while ($pending.Count -gt 0) {
                    $file=$Plan.Files[$pending.Dequeue()]; $component.Add($file)
                    foreach ($id in $file.Owners) {
                        foreach ($path in $Plan.Jobs[$id].Paths) {
                            if ($Plan.Files.ContainsKey($path) -and -not $visited.ContainsKey($path)) {$visited[$path]=$true; $pending.Enqueue($path)}
                        }
                    }
                }
                $candidates=@($component | Where-Object {$_.State -eq 'Ready'})
                if ($candidates.Count -eq 0) {continue}
                # A snapshot mismatch already discovered between dependent jobs
                # protects the complete connected set, just like a final hash mismatch.
                if (@($component | Where-Object {$_.State -eq 'Failed'}).Count -gt 0) {
                    foreach ($file in $candidates) {$file.State='Kept'; $file.Reason='A dependent original changed; complete source set kept.'}
                    continue
                }
                $owners=@{}; $outputs=@(); $locks=$null; $leases=@{}; $bad=$false
                foreach ($file in $candidates) {foreach ($id in $file.Owners) {$owners[$id]=$true}}
                foreach ($id in $owners.Keys) {$outputs+=@($Plan.Jobs[$id].Outputs)}
                try {
                    if ($outputs.Count -eq 0) {throw 'Verified outputs are missing; originals kept.'}
                    $locks=Open-SourcePolicyOutputs $outputs $Progress
                    foreach ($file in $candidates) {
                        try {
                            $expected=$Plan.Jobs[$file.Owners[0]].Hashes[$file.Path]
                            if ($referenceLeases.ContainsKey($file.Path)) {
                                $lease=$referenceLeases[$file.Path]
                                # The copied CUE must also match the frozen planning snapshot.
                                $lease.Verify($expected,(Get-SourcePolicyProgressAction $Progress 'Checking originals' $file.Path))
                            } else {$lease=Open-VerifiedSourcePolicyFile $file.Path $expected $Plan.Root $Progress}
                            $leases[$file.Path]=$lease
                        } catch {$file.State='Failed'; $file.Reason=$_.Exception.Message; $bad=$true}
                    }
                    if ($bad) {
                        foreach ($file in $candidates) {if ($file.State -eq 'Ready') {$file.State='Kept'; $file.Reason='A dependent original changed or could not be verified; complete source set kept.'}}
                        continue
                    }
                    $descriptorFailed=$false
                    # Remove CUE descriptors first. If one must remain, retain all
                    # its tracks even when deletion (not verification) is denied.
                    foreach ($file in @($candidates | Sort-Object @{Expression={if ([IO.Path]::GetExtension($_.Path) -ieq '.cue') {0} else {1}}},Path)) {
                        if ($descriptorFailed) {$file.State='Kept'; $file.Reason='A CUE could not be removed; its remaining source set was kept.'; continue}
                        try {
                            if ($Progress) {try {& $Progress 'Removing verified originals' $file.Path 0 0 | Out-Null} catch {}}
                            Remove-SourcePolicyFile $file.Path $leases[$file.Path]
                            $file.State='Removed'; $file.Reason='All dependent outputs verified; original removed.'
                        } catch {
                            $file.State='Failed'; $file.Reason=$_.Exception.Message
                            if ([IO.Path]::GetExtension($file.Path) -ieq '.cue') {$descriptorFailed=$true}
                        }
                    }
                } catch {foreach ($file in $candidates) {$file.State='Failed'; $file.Reason=$_.Exception.Message}}
                finally {
                    foreach ($path in $leases.Keys) {if (-not $referenceLeases.ContainsKey($path)) {$leases[$path].Dispose()}}
                    if ($locks) {foreach ($lock in $locks) {$lock.Dispose()}}
                }
            }
        }
    } finally {foreach ($lease in $referenceLeases.Values) {$lease.Dispose()}}
    foreach ($file in @($Plan.Files.Values | Sort-Object Path)) {
        $kind='KEPT'; if ($file.State -eq 'Removed') {$kind='REMOVED'} elseif ($file.State -eq 'Failed') {$kind='WARNING'}
        & $Report $kind ($file.Path+' | '+$file.Reason)
    }
}

function Get-SourcePolicySummary($Plan,[string]$Id='') {
    $files=@($Plan.Files.Values)
    if ($Id) {$files=@($Plan.Jobs[$Id].Paths | ForEach-Object {$Plan.Files[$_]})}
    $removed=@($files | Where-Object {$_.State -eq 'Removed'}).Count
    $failed=@($files | Where-Object {$_.State -eq 'Failed'}).Count
    $kept=$files.Count-$removed
    $label='Kept in SRC'
    if ($removed -gt 0) {
        $label='Removed from SRC'
        if ($kept -gt 0) {$label='Partly removed; some files kept in SRC'}
    }
    return [pscustomobject]@{Removed=$removed; Kept=$kept; Failed=$failed; Label=$label}
}
