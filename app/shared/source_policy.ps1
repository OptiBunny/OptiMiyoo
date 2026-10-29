. (Join-Path $PSScriptRoot 'compile_support.ps1')
# Shared source-retention checks. Windows PowerShell 5.1 compatible.
# A source can be removed only when every job using it has verified output.
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
using System.Threading;
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
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern bool CreateDirectoryW(string path, IntPtr security);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int informationClass, ref FileDisposition information, uint size);
        private readonly List<SafeFileHandle> parents = new List<SafeFileHandle>();
        private SafeFileHandle directoryGuard;
        private FileStream stream;
        private bool verified;
        private bool canDelete;
        public FileStream Stream { get { return stream; } }
        public string DirectoryIdentity { get; private set; }
        private bool disposed;
        private SourceRemovalLeaseV128() {}
        private static string NativePath(string path) {
            // Keep canonical ordinary paths for all boundary comparisons. Only
            // the Win32 call receives extended syntax, after normalization.
            string full = Path.GetFullPath(path);
            if (full.StartsWith(@"\\?\", StringComparison.Ordinal) || full.StartsWith(@"\\.\", StringComparison.Ordinal))
                throw new IOException("Device paths are not supported.");
            return full.StartsWith(@"\\", StringComparison.Ordinal) ? @"\\?\UNC\" + full.Substring(2) : @"\\?\" + full;
        }
        private static FileInformation Inspect(SafeFileHandle handle) {
            FileInformation information;
            if (!GetFileInformationByHandle(handle, out information)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return information;
        }
        private static SafeFileHandle OpenHandle(string path, bool directory, bool removal, uint share = 1) {
            // Share-read only: deny competing writes and delete/rename handles.
            // Attribute-only opens are exempt from share checks: LIST_DIRECTORY
            // is required for an ancestor handle to participate in sharing.
            uint access = directory ? (removal ? 0x10081U : 0x81U) : (removal ? 0x80010000U : 0x80000000U); // LIST_DIRECTORY | READ_ATTRIBUTES, or file read (+ DELETE)
            uint flags = 0x00200000U | (directory ? 0x02000000U : 0U); // OPEN_REPARSE_POINT | BACKUP_SEMANTICS
            SafeFileHandle handle = CreateFileW(NativePath(path), access, share, IntPtr.Zero, 3, flags, IntPtr.Zero);
            if (handle.IsInvalid) {
                int error = Marshal.GetLastWin32Error(); handle.Dispose();
                throw new Win32Exception(error, "File could not be locked safely: " + path + " (" + error + ": " + new Win32Exception(error).Message + ")");
            }
            try {
                FileInformation information = Inspect(handle);
                if ((information.Attributes & 0x400U) != 0 || ((information.Attributes & 0x10U) != 0) != directory)
                    throw new IOException("Path is linked or has the wrong file type; keeping it: " + path);
                if (!directory && removal && (information.Attributes & 1U) != 0)
                    throw new IOException("File is read-only; keeping it: " + path);
                return handle;
            } catch { handle.Dispose(); throw; }
        }
        public static SourceRemovalLeaseV128 Open(string path, string root) { return OpenCore(path, root, true); }
        public static SourceRemovalLeaseV128 OpenRead(string path) { return OpenCore(path, Path.GetPathRoot(Path.GetFullPath(path)), false); }
        public static SourceRemovalLeaseV128 OpenReadForPublication(string path) {
            // Hold the descriptor before relaxing its ancestor share modes.
            // Its locked directory entry keeps each ancestor nonempty, so none
            // can become a junction; no-delete sharing pins the ancestry while
            // write sharing allows unrelated sibling outputs to be published.
            SourceRemovalLeaseV128 lease = OpenRead(path);
            List<SafeFileHandle> relaxed = new List<SafeFileHandle>();
            try {
                foreach (string ancestor in Ancestors(Path.GetFullPath(path))) relaxed.Add(OpenHandle(ancestor, true, false, 3));
                for (int i = lease.parents.Count - 1; i >= 0; i--) lease.parents[i].Dispose();
                lease.parents.Clear(); lease.parents.AddRange(relaxed); relaxed.Clear();
                return lease;
            } catch { foreach (SafeFileHandle handle in relaxed) handle.Dispose(); lease.Dispose(); throw; }
        }
        public static SourceRemovalLeaseV128 OpenDirectoryRead(string path) {
            RequireWindows();
            SourceRemovalLeaseV128 lease = new SourceRemovalLeaseV128();
            try {
                string full = Path.GetFullPath(path);
                List<string> chain = Ancestors(full); chain.Add(full);
                // Enumeration needs strict read sharing only. Unlike a transaction
                // directory lease, it must not create a watched marker file.
                foreach (string ancestor in chain) lease.parents.Add(OpenHandle(ancestor, true, false));
                lease.DirectoryIdentity = Identity(Inspect(lease.parents[lease.parents.Count - 1]));
                return lease;
            } catch { lease.Dispose(); throw; }
        }
        public static SourceRemovalLeaseV128 OpenDirectory(string path) {
            RequireWindows();
            SourceRemovalLeaseV128 lease = new SourceRemovalLeaseV128();
            List<SafeFileHandle> strict = new List<SafeFileHandle>();
            try {
                string full = Path.GetFullPath(path);
                List<string> chain = Ancestors(full); chain.Add(full);
                foreach (string ancestor in chain) strict.Add(OpenHandle(ancestor, true, false));
                // A write-sharing directory lease permits child moves, but alone
                // permits turning an empty directory into a junction in place.
                // Create a locked delete-on-close guard before relaxing sharing.
                // Ancestors remain nonempty because their child directory is pinned.
                string guard = Path.Combine(full, ".optimiyoo-" + Guid.NewGuid().ToString("N") + ".lease");
                lease.directoryGuard = CreateFileW(NativePath(guard), 0x80010000U, 1, IntPtr.Zero, 1, 0x04000102U, IntPtr.Zero);
                if (lease.directoryGuard.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not protect transaction directory.");
                foreach (string ancestor in chain) lease.parents.Add(OpenHandle(ancestor, true, false, 3));
                lease.DirectoryIdentity = Identity(Inspect(lease.parents[lease.parents.Count - 1]));
                return lease;
            } catch { lease.Dispose(); throw; }
            finally { for (int i = strict.Count - 1; i >= 0; i--) strict[i].Dispose(); }
        }
        private static void RequireWindows() {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT)
                throw new PlatformNotSupportedException("Verified file removal requires Windows; files kept on this platform.");
        }
        private static List<string> Ancestors(string full) {
            List<string> ancestors = new List<string>();
            string parent = Path.GetDirectoryName(full);
            while (!String.IsNullOrEmpty(parent)) {
                ancestors.Add(parent);
                DirectoryInfo next = Directory.GetParent(parent);
                parent = next == null ? null : next.FullName;
            }
            ancestors.Reverse();
            return ancestors;
        }
        // Observe the long verification window without scanning or hashing the
        // collection before each removal. This is a change detector, not an
        // atomic lock against every possible last-instant namespace mutation.
        public sealed class InventoryGuard : IDisposable {
            [StructLayout(LayoutKind.Sequential)]
            private struct Overlapped {
                public IntPtr Internal, InternalHigh;
                public uint Offset, OffsetHigh;
                public IntPtr Event;
            }
            [DllImport("kernel32.dll", SetLastError=true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            private static extern bool ReadDirectoryChangesW(SafeFileHandle directory, IntPtr buffer, uint length,
                [MarshalAs(UnmanagedType.Bool)] bool subtree, uint filter, IntPtr bytes, IntPtr overlapped, IntPtr completion);
            [DllImport("kernel32.dll", SetLastError=true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            private static extern bool GetOverlappedResult(SafeFileHandle directory, IntPtr overlapped, out uint bytes,
                [MarshalAs(UnmanagedType.Bool)] bool wait);
            [DllImport("kernel32.dll", SetLastError=true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            private static extern bool CancelIoEx(SafeFileHandle directory, IntPtr overlapped);
            private const int BufferSize = 65536;
            private readonly List<SafeFileHandle> parents = new List<SafeFileHandle>();
            private SafeFileHandle directory;
            private ManualResetEvent ready;
            private IntPtr buffer, overlapped;
            private bool pending, disposed;
            private string failure;
            internal static InventoryGuard Open(string path) {
                RequireWindows();
                string full = Path.GetFullPath(path);
                if (full.StartsWith(@"\\", StringComparison.Ordinal) || new DriveInfo(Path.GetPathRoot(full)).DriveType == DriveType.Network)
                    throw new IOException("Source inventory notifications require a local drive; originals kept.");
                InventoryGuard guard = new InventoryGuard();
                try {
                    foreach (string parent in Ancestors(full)) guard.parents.Add(OpenHandle(parent, true, false));
                    // Share-read pins the source directory while allowing normal
                    // child creation/removal, whose names the notification tracks.
                    guard.directory = CreateFileW(NativePath(full), 0x81, 1, IntPtr.Zero, 3, 0x42200000, IntPtr.Zero);
                    if (guard.directory.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not monitor the source inventory; originals kept.");
                    if ((Inspect(guard.directory).Attributes & 0x410U) != 0x10U)
                        throw new IOException("Source inventory root is linked or is not a directory; originals kept.");
                    guard.ready = new ManualResetEvent(false);
                    guard.buffer = Marshal.AllocHGlobal(BufferSize);
                    guard.overlapped = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Overlapped)));
                    guard.Arm();
                    return guard;
                } catch { guard.Dispose(); throw; }
            }
            private void Arm() {
                ready.Reset();
                Marshal.StructureToPtr(new Overlapped { Event = ready.SafeWaitHandle.DangerousGetHandle() }, overlapped, false);
                // FILE_NAME | DIR_NAME for the whole subtree. Descriptor bytes
                // are held through verified leases, not delayed write notices.
                if (!ReadDirectoryChangesW(directory, buffer, BufferSize, true, 0x3, IntPtr.Zero, overlapped, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Source inventory notifications are unavailable; originals kept.");
                pending = true;
            }
            public void AssertUnchanged() {
                if (disposed) throw new ObjectDisposedException("Source inventory guard");
                if (failure != null) throw new IOException(failure);
                try {
                    // Drain only completed kernel operations, never delayed
                    // PowerShell/.NET callbacks. Bound a continuously busy tree.
                    for (int batch = 0; batch < 8; batch++) {
                        uint bytes;
                        if (!GetOverlappedResult(directory, overlapped, out bytes, false)) {
                            int error = Marshal.GetLastWin32Error();
                            if (error == 996) return; // ERROR_IO_INCOMPLETE: no names changed.
                            pending = false;
                            throw new Win32Exception(error, "Source inventory monitoring failed; originals kept.");
                        }
                        pending = false;
                        if (bytes == 0 || bytes > BufferSize)
                            throw new IOException("Source inventory notifications overflowed; originals kept.");
                        int offset = 0;
                        while (true) {
                            if (offset < 0 || offset > (int)bytes - 12) throw new IOException("Invalid source inventory notification; originals kept.");
                            uint next = unchecked((uint)Marshal.ReadInt32(buffer, offset));
                            uint action = unchecked((uint)Marshal.ReadInt32(buffer, offset + 4));
                            uint nameBytes = unchecked((uint)Marshal.ReadInt32(buffer, offset + 8));
                            if (nameBytes == 0 || (nameBytes & 1) != 0 || nameBytes > bytes - (uint)offset - 12)
                                throw new IOException("Invalid source inventory notification; originals kept.");
                            // Deletions and parent metadata updates are expected.
                            // A directory named Collection.cue is not a descriptor;
                            // all actual descriptor contents are pinned separately.
                            if (action != 2 && action != 3)
                                throw new IOException("Source files or directories were added or renamed during verification; originals kept.");
                            if (next == 0) break;
                            if ((next & 3) != 0 || next < 12 + nameBytes || next > bytes - (uint)offset - 12)
                                throw new IOException("Invalid source inventory notification; originals kept.");
                            offset += (int)next;
                        }
                        // Windows retains changes between reads in this handle's
                        // kernel buffer; a zero-byte/failed read is never accepted.
                        Arm();
                    }
                    throw new IOException("Source inventory kept changing during verification; originals kept.");
                } catch (Exception error) { failure = error.Message; throw; }
            }
            public void Dispose() {
                if (disposed) return;
                disposed = true;
                if (pending && directory != null && !directory.IsInvalid) {
                    CancelIoEx(directory, overlapped);
                    uint ignored;
                    // Native memory must remain alive until cancellation completes.
                    GetOverlappedResult(directory, overlapped, out ignored, true);
                    pending = false;
                }
                if (directory != null) directory.Dispose();
                if (ready != null) ready.Dispose();
                if (overlapped != IntPtr.Zero) Marshal.FreeHGlobal(overlapped);
                if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                for (int i = parents.Count - 1; i >= 0; i--) parents[i].Dispose();
                parents.Clear();
            }
        }
        public static InventoryGuard WatchInventory(string root) { return InventoryGuard.Open(root); }
        private sealed class OwnedEntry : IDisposable {
            internal string Path;
            internal bool Directory;
            internal SafeFileHandle Handle;
            public void Dispose() { if (Handle != null) { Handle.Dispose(); Handle = null; } }
        }
        public static void CreateOwnedDirectory(string path) {
            RequireWindows();
            // Unlike Directory.CreateDirectory, this never adopts an existing
            // directory. Callers may claim cleanup ownership only after success.
            string full = Path.GetFullPath(path);
            using (SourceRemovalLeaseV128 parent = OpenDirectory(Path.GetDirectoryName(full))) {
                if (!CreateDirectoryW(NativePath(full), IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create a new private scratch directory.");
            }
        }
        private static string Identity(FileInformation information) {
            return information.VolumeSerial.ToString("X8") + ":" + information.IndexHigh.ToString("X8") + information.IndexLow.ToString("X8");
        }
        public static void DeleteOwned(string path, string root) { DeleteOwnedCore(path, root, null, 0); }
        public static void DeleteOwnedVerified(string path, string root, string identity, int maximumEntries) {
            if (String.IsNullOrEmpty(identity)) throw new IOException("Scratch ownership was not captured; files retained.");
            if (maximumEntries < 1) throw new ArgumentOutOfRangeException("maximumEntries");
            DeleteOwnedCore(path, root, identity, maximumEntries);
        }
        private static void DeleteOwnedCore(string path, string root, string identity, int maximumEntries) {
            RequireWindows();
            string full = Path.GetFullPath(path).TrimEnd('\\', '/');
            string prefix = Path.GetFullPath(root).TrimEnd('\\', '/') + Path.DirectorySeparatorChar;
            if (!full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) || full.Substring(prefix.Length).IndexOf(':') >= 0)
                throw new IOException("Cleanup path is outside its owned directory; files kept.");
            List<SafeFileHandle> ancestors = new List<SafeFileHandle>();
            List<OwnedEntry> entries = new List<OwnedEntry>();
            try {
                foreach (string ancestor in Ancestors(full)) ancestors.Add(OpenHandle(ancestor, true, false));
                Queue<string> pending = new Queue<string>(); pending.Enqueue(full);
                while (pending.Count > 0) {
                    string current = pending.Dequeue();
                    FileAttributes attributes = File.GetAttributes(current);
                    if ((attributes & FileAttributes.ReparsePoint) != 0)
                        throw new IOException("Cleanup contains a link; files kept: " + current);
                    bool directory = (attributes & FileAttributes.Directory) != 0;
                    // The handle rechecks type and links after the pathname inspection.
                    // Keep every handle until preflight completes: a failed scan removes nothing.
                    OwnedEntry entry = new OwnedEntry { Path = current, Directory = directory, Handle = OpenHandle(current, directory, true) };
                    entries.Add(entry);
                    if (entries.Count == 1 && identity != null && !String.Equals(identity, Identity(Inspect(entry.Handle)), StringComparison.Ordinal))
                        throw new IOException("Scratch directory was replaced; all files retained.");
                    if (directory) foreach (string child in System.IO.Directory.EnumerateFileSystemEntries(current)) {
                        if (maximumEntries > 0 && entries.Count + pending.Count >= maximumEntries)
                            throw new IOException("Scratch cleanup entry limit exceeded; all files retained.");
                        pending.Enqueue(child);
                    }
                }
                // Children precede parents. A concurrently created untracked child makes
                // its parent deletion fail; no pathname traversal/delete fallback is used.
                for (int i = entries.Count - 1; i >= 0; i--) {
                    MarkForDeletion(entries[i].Handle);
                    entries[i].Dispose();
                }
            } finally {
                for (int i = entries.Count - 1; i >= 0; i--) entries[i].Dispose();
                for (int i = ancestors.Count - 1; i >= 0; i--) ancestors[i].Dispose();
            }
        }
        private static void MarkForDeletion(SafeFileHandle handle) {
            FileDisposition disposition = new FileDisposition(); disposition.DeleteFile = 1;
            if (!SetFileInformationByHandle(handle, 4, ref disposition, 1)) {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(error, "File could not be removed safely. (" + error + ": " + new Win32Exception(error).Message + ")");
            }
        }
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
                foreach (string ancestor in Ancestors(full)) lease.parents.Add(OpenHandle(ancestor, true, false));
                SafeFileHandle file = OpenHandle(full, false, removal);
                try {
                    if (removal && Inspect(file).Links > 1)
                        throw new IOException("Original has multiple hardlinks; keeping it and its complete source set.");
                    lease.stream = new FileStream(file, FileAccess.Read, 1048576, false);
                }
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
            try {
                if (stream != null) { stream.Dispose(); stream = null; }
                if (directoryGuard != null) { directoryGuard.Dispose(); directoryGuard = null; }
            }
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

function Open-SourcePolicyInventoryGuard([string]$Root) {
    # Explicit test boundary, like the source/output lease factories. Production
    # refuses removal if the real source tree cannot be monitored safely.
    Initialize-SourcePolicyNative
    return [OptiMiyoo.SourceRemovalLeaseV128]::WatchInventory($Root)
}

function Assert-SourcePolicyInventoryGuard($Plan,$Guard) {
    try {
        if (-not $Guard) {throw 'Source inventory guard is unavailable.'}
        $Guard.AssertUnchanged()
    } catch {
        $Plan.BlockReason='Source inventory changed or could not be monitored during final verification; remaining originals kept. '+$_.Exception.Message
        throw $Plan.BlockReason
    }
}

function Open-SourcePolicyDirectoryLease([string]$Path) {
    Initialize-SourcePolicyNative
    return [OptiMiyoo.SourceRemovalLeaseV128]::OpenDirectory($Path)
}

function Open-SourcePolicyReadDirectoryLease([string]$Path) {
    Initialize-SourcePolicyNative
    return [OptiMiyoo.SourceRemovalLeaseV128]::OpenDirectoryRead($Path)
}

function Remove-SourcePolicyOwnedPath([string]$Path,[string]$Root,[string]$Identity,[int]$MaximumEntries=0) {
    # Only callers that created/own a staging or backup entry may use this API.
    # The strict root boundary is mandatory; never use it for source originals.
    Initialize-SourcePolicyNative
    if($PSBoundParameters.ContainsKey('Identity')) {
        [OptiMiyoo.SourceRemovalLeaseV128]::DeleteOwnedVerified($Path,$Root,$Identity,$MaximumEntries)
    } else {[OptiMiyoo.SourceRemovalLeaseV128]::DeleteOwned($Path,$Root)}
}

function New-SourcePolicyOwnedDirectory([string]$Path) {
    Initialize-SourcePolicyNative
    [OptiMiyoo.SourceRemovalLeaseV128]::CreateOwnedDirectory($Path)
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

function Open-SourcePolicyOutputs([object[]]$Outputs,[scriptblock]$Progress=$null) {
    $locks=New-Object 'System.Collections.Generic.List[System.IDisposable]'
    try {
        foreach ($output in $Outputs) {
            $files=New-Object 'System.Collections.Generic.List[object]'
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
                $prefix=[IO.Path]::GetFullPath($output.Destination).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
                $seen=@{}
                foreach ($name in $output.Manifest.Keys) {
                    if ([string]::IsNullOrWhiteSpace($name) -or [IO.Path]::IsPathRooted($name)) {throw 'Output manifest has an unsafe path; originals kept.'}
                    foreach ($part in ($name -split '[\\/]')) {
                        if ($part -in '', '.', '..' -or $part -match '[<>:"|?*\x00-\x1f]' -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {throw 'Output manifest has an unsafe path; originals kept.'}
                    }
                    $path=[IO.Path]::GetFullPath((Join-Path $output.Destination $name))
                    if (-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or $seen.ContainsKey($path)) {throw 'Output manifest escapes its folder or repeats a file; originals kept.'}
                    $seen[$path]=$true
                    $files.Add(@{Path=$path; Hash=$output.Manifest[$name].Hash})
                }
            } else {$files.Add(@{Path=$output.Destination; Hash=$output.Hash})}
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

function Get-SourcePolicyDescriptorPaths([string]$Root) {
    # One bounded inventory per planning/final-protection boundary, never per
    # candidate. Inspect directories as directories, regardless of their suffix.
    $rootLease=Open-SourcePolicyReadDirectoryLease $Root
    $pending=New-Object 'System.Collections.Generic.Queue[string]'
    $paths=New-Object 'System.Collections.Generic.List[string]'
    $pending.Enqueue([IO.Path]::GetFullPath($Root));$entries=0
    try {
        while($pending.Count) {
            $directory=$pending.Dequeue();$lease=Open-SourcePolicyReadDirectoryLease $directory
            try {
                foreach($path in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
                    if(++$entries -gt 100000){throw 'Source descriptor inventory exceeds the 100,000-entry limit. Split the collection and retry; originals kept.'}
                    $entry=Get-Item -LiteralPath $path -Force -ErrorAction Stop
                    if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Source descriptor inventory contains a link; originals kept.'}
                    if($entry.PSIsContainer){$pending.Enqueue($entry.FullName)}
                    elseif($entry.Extension -ieq '.cue') {
                        if($paths.Count -ge 1024){throw 'Source descriptor inventory exceeds the 1,024-CUE limit. Split the collection and retry; originals kept.'}
                        $paths.Add($entry.FullName)
                    }
                }
            } finally {$lease.Dispose()}
        }
        return ,$paths.ToArray()
    } finally {$rootLease.Dispose()}
}

function Assert-SourcePolicyDescriptorBudget([string]$Root,[hashtable]$Snapshot) {
    if($Snapshot.Count -gt 1024){throw 'Source descriptor inventory exceeds the 1,024-CUE limit. Split the collection and retry; originals kept.'}
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $bytes=0L;$ancestors=0L
    foreach($path in $Snapshot.Keys) {
        $full=[IO.Path]::GetFullPath($path);$record=$Snapshot[$path]
        if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($full) -ine '.cue'){throw 'Invalid source descriptor snapshot path; originals kept.'}
        if($record.Length -lt 0 -or $record.Length -gt 1048576 -or [string]$record.Hash -cnotmatch '^[0-9A-Fa-f]{64}$'){throw 'Source descriptor snapshot is invalid or exceeds the 1 MiB CUE limit; originals kept.'}
        $bytes+=[long]$record.Length
        if($bytes -gt 67108864){throw 'Source descriptors exceed the 64 MiB combined limit. Split the collection and retry; originals kept.'}
        $parent=[IO.Path]::GetDirectoryName($full)
        while($parent) {
            if(++$ancestors -gt 16384){throw 'Source descriptors exceed the 16,384 ancestor-handle limit. Shorten the folders or split the collection; originals kept.'}
            $next=[IO.Directory]::GetParent($parent);$parent=$null;if($next){$parent=$next.FullName}
        }
    }
}

function Get-SourcePolicyDescriptorSnapshot([string]$Root) {
    # Deliberate filesystem boundary for planning-only tests. Direct callers must
    # freeze untracked descriptors too; an unknown descriptor at cleanup is unsafe.
    $snapshot=@{};$totalBytes=0L
    foreach($path in (Get-SourcePolicyDescriptorPaths $Root)) {
        $lease=Open-SourcePolicyReadLease $path $Root
        try {
            if($lease.Stream.Length -gt 1048576){throw 'CUE exceeds the supported 1 MiB text limit; originals kept.'}
            $totalBytes+=$lease.Stream.Length
            if($totalBytes -gt 67108864){throw 'Source descriptors exceed the 64 MiB combined limit. Split the collection and retry; originals kept.'}
            $hash=[OptiMiyoo.SourceRemovalLeaseV128]::HashStream($lease.Stream,$null)
            $snapshot[$path]=[pscustomobject]@{Hash=$hash;Length=$lease.Stream.Length}
        } finally {$lease.Dispose()}
    }
    Assert-SourcePolicyDescriptorBudget $Root $snapshot
    return $snapshot
}

function New-SourcePolicyPlan([string]$Root,[string]$Policy,[hashtable]$DescriptorSnapshot=$null) {
    $plan=[pscustomobject]@{Root=$Root; Policy=$Policy; Files=@{}; Jobs=@{}; References=@{}; ReferenceHashes=@{}; DescriptorSnapshot=@{}; BlockReason=''}
    if($Policy -eq 'Remove') {
        try {
            if($null -eq $DescriptorSnapshot){$DescriptorSnapshot=Get-SourcePolicyDescriptorSnapshot $Root}
            Assert-SourcePolicyDescriptorBudget $Root $DescriptorSnapshot
            foreach($path in $DescriptorSnapshot.Keys){$record=$DescriptorSnapshot[$path];$plan.DescriptorSnapshot[$path]=[pscustomobject]@{Hash=[string]$record.Hash;Length=[long]$record.Length}}
        } catch {$plan.BlockReason='Source descriptors could not be frozen safely; originals kept. '+$_.Exception.Message}
    }
    return $plan
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
            if ($snapshot.Length -gt 1048576) {throw 'CUE exceeds the supported 1 MiB text limit.'}
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
            if ($Plan.DescriptorSnapshot.ContainsKey($full)) {
                if($Plan.DescriptorSnapshot[$full].Hash -cne $hash -or $Plan.DescriptorSnapshot[$full].Length -ne $snapshot.Length){throw 'A source CUE changed from the frozen descriptor baseline.'}
            } else {
                $Plan.DescriptorSnapshot[$full]=[pscustomobject]@{Hash=$hash;Length=$snapshot.Length}
                Assert-SourcePolicyDescriptorBudget $Plan.Root $Plan.DescriptorSnapshot
            }
            $Plan.ReferenceHashes[$full]=$hash
        } catch {$Plan.BlockReason='Source references could not be frozen safely; originals kept for this batch. '+$_.Exception.Message}
        finally {if ($sha) {$sha.Dispose()}; if ($snapshot) {$snapshot.Dispose()}}
    }
}

function Complete-SourcePolicyJob($Plan,[string]$Id,[hashtable]$Hashes,[object[]]$Outputs) {
    $job=$Plan.Jobs[$Id]
    $job.Hashes=$Hashes; $job.Outputs=$Outputs; $job.Succeeded=$true
}

function Set-SourcePolicyCleanupEligibility($Plan) {
    $invalidJobs=@{}
    foreach ($id in $Plan.Jobs.Keys) {
        $job=$Plan.Jobs[$id]
        if (-not $job.Succeeded -or $job.BlockReason) {continue}
        if ($null -eq $job.Outputs -or @($job.Outputs).Count -eq 0) {$invalidJobs[$id]='Verified outputs are missing; complete source set kept.'; continue}
        foreach ($path in $job.Paths) {
            if ($null -eq $job.Hashes -or -not $job.Hashes.ContainsKey($path) -or -not $job.Hashes[$path]) {$invalidJobs[$id]='Source verification is incomplete; complete source set kept.'; break}
        }
    }
    foreach ($file in $Plan.Files.Values) {
        $expected=$null; $eligible=$true
        foreach ($id in $file.Owners) {
            $job=$Plan.Jobs[$id]
            if ($invalidJobs.ContainsKey($id)) {$eligible=$false; $file.State='Failed'; $file.Reason=$invalidJobs[$id]; break}
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
}

function Open-SourcePolicyCleanupContext($Plan,[scriptblock]$Progress=$null,$InventoryGuard=$null) {
    if($Plan.Policy -ne 'Remove'){throw 'A cleanup context requires Remove policy.'}
    if($Plan.BlockReason){throw $Plan.BlockReason}
    $context=[pscustomobject]@{Plan=$Plan;InventoryGuard=$InventoryGuard;OwnsInventoryGuard=($null -eq $InventoryGuard);ReferenceLeases=@{};Disposed=$false}
    $context | Add-Member ScriptMethod Dispose {
        if($this.Disposed){return};$this.Disposed=$true;$failure=$null
        foreach($lease in $this.ReferenceLeases.Values){try{$lease.Dispose()}catch{if(-not $failure){$failure=$_}}}
        $this.ReferenceLeases.Clear()
        if($this.OwnsInventoryGuard -and $this.InventoryGuard){try{$this.InventoryGuard.Dispose()}catch{if(-not $failure){$failure=$_}}}
        if($failure){throw $failure}
    }
    $transferred=$false
    try {
        if(-not $context.InventoryGuard){$context.InventoryGuard=Open-SourcePolicyInventoryGuard $Plan.Root}
        Set-SourcePolicyCleanupEligibility $Plan
        Assert-SourcePolicyDescriptorBudget $Plan.Root $Plan.DescriptorSnapshot
        $actual=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach($path in (Get-SourcePolicyDescriptorPaths $Plan.Root)){[void]$actual.Add($path)}
        if($actual.Count -ne $Plan.DescriptorSnapshot.Count){throw 'Source CUE inventory changed since planning; retry with the updated source collection. Originals kept.'}
        foreach($path in @($Plan.DescriptorSnapshot.Keys | Sort-Object)) {
            if(-not $actual.Contains($path)){throw 'Source CUE inventory changed since planning; retry with the updated source collection. Originals kept.'}
            $record=$Plan.DescriptorSnapshot[$path]
            $removable=$Plan.Files.ContainsKey($path) -and $Plan.Files[$path].State -eq 'Ready'
            $lease=Open-VerifiedSourcePolicyFile $path $record.Hash $Plan.Root $Progress -ReadOnly:(-not $removable)
            $context.ReferenceLeases[$path]=$lease
            if($lease.Stream.Length -ne $record.Length){throw 'Source CUE length differs from its frozen descriptor baseline; originals kept.'}
        }
        # A retained or untracked descriptor is not automatically represented in
        # job ownership. Reject any overlooked dependency while its bytes are held.
        foreach($path in $context.ReferenceLeases.Keys) {
            if($Plan.Files.ContainsKey($path) -and $Plan.Files[$path].State -eq 'Ready'){continue}
            if(-not (Get-Command Get-CueFiles -ErrorAction SilentlyContinue)){throw 'CUE reference validation is unavailable; originals kept.'}
            foreach($name in @(Get-CueFiles $path)) {
                $reference=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($path)) $name))
                if($Plan.Files.ContainsKey($reference) -and $Plan.Files[$reference].State -eq 'Ready'){throw 'A retained or untracked CUE still references an original selected for removal; include its complete source set before retrying. Originals kept.'}
            }
        }
        Assert-SourcePolicyInventoryGuard $Plan $context.InventoryGuard
        $transferred=$true
        return $context
    } finally {
        # Engine Stop bypasses catch before the caller receives this context.
        # Dispose releases its descriptors while preserving a borrowed guard.
        if(-not $transferred){$context.Dispose()}
    }
}

function Invoke-SourcePolicyCleanup($Plan,[scriptblock]$Report,[scriptblock]$Progress=$null,$InventoryGuard=$null,$CleanupContext=$null) {
    if ($Plan.Policy -ne 'Remove') {return}
    if ($Plan.BlockReason) {
        foreach ($file in $Plan.Files.Values) {
            $file.Reason=$Plan.BlockReason
            if (@($file.Owners | Where-Object {$Plan.Jobs[$_].Succeeded}).Count -gt 0) {$file.State='Failed'}
        }
        & $Report 'WARNING' $Plan.BlockReason
        return
    }
    if(-not $CleanupContext){Set-SourcePolicyCleanupEligibility $Plan}
    elseif($CleanupContext.Disposed -or -not [object]::ReferenceEquals($Plan,$CleanupContext.Plan)){throw 'Source cleanup context is closed or belongs to another plan.'}
    if (@($Plan.Files.Values | Where-Object {$_.State -eq 'Ready'}).Count -eq 0) {
        foreach ($file in @($Plan.Files.Values | Sort-Object Path)) {
            $kind='KEPT'; if ($file.State -eq 'Failed') {$kind='WARNING'}
            & $Report $kind ($file.Path+' | '+$file.Reason)
        }
        return
    }
    $referenceLeases=@{}; $ownsCleanupContext=$false
    try {
        try {
            # The host holds the complete context across its final snapshot.
            # Direct callers capture and own the same protection here.
            if(-not $CleanupContext){$CleanupContext=Open-SourcePolicyCleanupContext $Plan $Progress -InventoryGuard $InventoryGuard;$ownsCleanupContext=$true}
            $InventoryGuard=$CleanupContext.InventoryGuard;$referenceLeases=$CleanupContext.ReferenceLeases
            Assert-SourcePolicyInventoryGuard $Plan $InventoryGuard
        } catch {
            if (-not $Plan.BlockReason) {$Plan.BlockReason='Source inventory or CUE descriptors could not be protected; remaining originals kept. '+$_.Exception.Message}
        }
        if (-not $Plan.BlockReason) {
            # Validate connected ownership components together. A changed source
            # must not leave a retained CUE without its unchanged tracks. Independent
            # games use bounded sets of source/output handles, not whole-batch locks.
            $visited=@{}; $expandedJobs=@{}
            foreach ($start in @($Plan.Files.Keys | Sort-Object)) {
                if ($Plan.BlockReason) {break}
                if ($visited.ContainsKey($start)) {continue}
                $pending=New-Object 'System.Collections.Generic.Queue[string]'
                $component=New-Object 'System.Collections.Generic.List[object]'
                $pending.Enqueue($start); $visited[$start]=$true
                while ($pending.Count -gt 0) {
                    $file=$Plan.Files[$pending.Dequeue()]; $component.Add($file)
                    foreach ($id in $file.Owners) {
                        # Each job connects its whole source set. Expanding that
                        # same set for every track makes a large job quadratic.
                        if ($expandedJobs.ContainsKey($id)) {continue}
                        $expandedJobs[$id]=$true
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
                $owners=@{}; $outputs=New-Object 'System.Collections.Generic.List[object]'; $locks=$null; $leases=@{}; $bad=$false
                foreach ($file in $candidates) {foreach ($id in $file.Owners) {$owners[$id]=$true}}
                foreach ($id in $owners.Keys) {foreach ($output in $Plan.Jobs[$id].Outputs) {$outputs.Add($output)}}
                try {
                    if ($outputs.Count -eq 0) {throw 'Verified outputs are missing; originals kept.'}
                    $locks=Open-SourcePolicyOutputs $outputs $Progress
                    Assert-SourcePolicyInventoryGuard $Plan $inventoryGuard
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
                    Assert-SourcePolicyInventoryGuard $Plan $inventoryGuard
                    $descriptorFailed=$false
                    # Remove CUE descriptors first. If one must remain, retain all
                    # its tracks even when deletion (not verification) is denied.
                    foreach ($file in @($candidates | Sort-Object @{Expression={if ([IO.Path]::GetExtension($_.Path) -ieq '.cue') {0} else {1}}},Path)) {
                        if ($descriptorFailed) {$file.State='Kept'; $file.Reason='A CUE could not be removed; its remaining source set was kept.'; continue}
                        try {
                            if ($Progress) {try {& $Progress 'Removing verified originals' $file.Path 0 0 | Out-Null} catch {}}
                            Assert-SourcePolicyInventoryGuard $Plan $inventoryGuard
                            Remove-SourcePolicyFile $file.Path $leases[$file.Path]
                            $file.State='Removed'; $file.Reason='All dependent outputs verified; original removed.'
                        } catch {
                            $file.State='Failed'; $file.Reason=$_.Exception.Message
                            if ($Plan.BlockReason) {break}
                            if ([IO.Path]::GetExtension($file.Path) -ieq '.cue') {$descriptorFailed=$true}
                        }
                    }
                } catch {foreach ($file in $candidates) {if ($file.State -ne 'Removed') {$file.State='Failed'; $file.Reason=$_.Exception.Message}}}
                finally {
                    foreach ($path in $leases.Keys) {if (-not $referenceLeases.ContainsKey($path)) {$leases[$path].Dispose()}}
                    if ($locks) {foreach ($lock in $locks) {$lock.Dispose()}}
                }
            }
        }
        if ($Plan.BlockReason) {
            foreach ($file in $Plan.Files.Values) {if ($file.State -eq 'Ready') {$file.State='Failed'; $file.Reason=$Plan.BlockReason}}
        }
    } finally {
        if ($ownsCleanupContext -and $CleanupContext) {$CleanupContext.Dispose()}
    }
    foreach ($file in @($Plan.Files.Values | Sort-Object Path)) {
        $kind='KEPT'; if ($file.State -eq 'Removed') {$kind='REMOVED'} elseif ($file.State -eq 'Failed') {$kind='WARNING'}
        & $Report $kind ($file.Path+' | '+$file.Reason)
    }
}

function Get-SourcePolicySummary($Plan,[string]$Id='') {
    if ($Id) {$files=@($Plan.Jobs[$Id].Paths | ForEach-Object {$Plan.Files[$_]})}
    else {$files=@($Plan.Files.Values)}
    $removed=0; $failed=0
    foreach ($file in $files) {
        if ($file.State -eq 'Removed') {$removed++}
        elseif ($file.State -eq 'Failed') {$failed++}
    }
    $kept=$files.Count-$removed
    $label='Kept in SRC'
    if ($removed -gt 0) {
        $label='Removed from SRC'
        if ($kept -gt 0) {$label='Partly removed; some files kept in SRC'}
    }
    return [pscustomobject]@{Removed=$removed; Kept=$kept; Failed=$failed; Label=$label}
}
