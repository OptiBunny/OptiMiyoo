#requires -Version 5.1
[CmdletBinding()]
param([string]$OnionRoot,[switch]$NoAnimation,[switch]$NoColor,
      [ValidateSet('CRT','Smooth')][string]$DisplayEffect='CRT',
      [Parameter(DontShow=$true)][switch]$PlainProgress,
      [Parameter(DontShow=$true)][switch]$SelectionOnly,
      [Parameter(DontShow=$true)][string[]]$EnableSystems,
      [Parameter(DontShow=$true)][string[]]$DisableSystems)
$ErrorActionPreference='Stop'
if (-not $SelectionOnly -and ($PSBoundParameters.ContainsKey('EnableSystems') -or $PSBoundParameters.ContainsKey('DisableSystems'))) {throw 'SD system selections require SelectionOnly.'}
. (Join-Path $PSScriptRoot '../runtime/application_entry.ps1')
if (-not (Test-ApplicationWorker)) {
    exit (Enter-ApplicationHost -ApplicationRoot (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -Entry SD -Arguments $PSBoundParameters)
}
$exitCode=0
$script:AppVersion='0.0.9'
$ScriptDir=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $ScriptDir 'onion/core_support.ps1')
. (Join-Path $ScriptDir 'shared/compile_support.ps1')
. (Join-Path $ScriptDir 'shared/output_safety.ps1')
. (Join-Path $ScriptDir 'ui/display.ps1')
$script:OnionCompleted=0;$script:OnionTotal=-1;$script:OnionStage='Preparing selected changes'
$script:OnionErrors=New-Object 'System.Collections.Generic.List[string]'
if ($PlainProgress) {$script:UiVT=$false}
function Write-OnionText([string]$Text,[switch]$Failure) {
    $text=ConvertTo-SafeExternalText $Text
    if ($script:UiVT) {
        if ($Failure) {$script:OnionErrors.Add($text)}
        Show-OnionProgress -Stage $script:OnionStage -Detail $text -Completed $script:OnionCompleted -Total $script:OnionTotal -Unit systems
    } else {Write-Host $text}
}
function Initialize-OnionPathLease {
    if ('OptiMiyoo.OnionPathLease' -as [type]) {return}
    Add-OptiMiyooType -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace OptiMiyoo {
    public sealed class OnionPathLease : IDisposable {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInformation {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime, AccessTime, WriteTime;
            public uint VolumeSerial, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateDirectoryW(string name, IntPtr security);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);
        private readonly List<SafeFileHandle> directories = new List<SafeFileHandle>();
        private FileStream stream;
        public FileStream Stream { get { return stream; } }
        public string DirectoryPath { get; private set; }
        private static string NativePath(string path) {
            string full = Path.GetFullPath(path);
            if (full.StartsWith(@"\\?\", StringComparison.Ordinal) || full.StartsWith(@"\\.\", StringComparison.Ordinal)) throw new IOException("Device paths are not supported.");
            return full.StartsWith(@"\\", StringComparison.Ordinal) ? @"\\?\UNC\" + full.Substring(2) : @"\\?\" + full;
        }
        private static SafeFileHandle OpenHandle(string path, bool directory, bool write, bool create) {
            uint access = directory ? 0x81U : (write ? 0xC0000000U : 0x80000000U);
            uint flags = 0x00200000U | (directory ? 0x02000000U : 0U);
            SafeFileHandle handle = CreateFileW(NativePath(path), access, 1, IntPtr.Zero, create ? 1U : 3U, flags, IntPtr.Zero);
            if (handle.IsInvalid) {
                int error = Marshal.GetLastWin32Error(); handle.Dispose();
                throw new Win32Exception(error, "SD path could not be locked safely.");
            }
            try {
                FileInformation information;
                if (!GetFileInformationByHandle(handle, out information)) throw new Win32Exception(Marshal.GetLastWin32Error());
                if ((information.Attributes & 0x400U) != 0 || ((information.Attributes & 0x10U) != 0) != directory)
                    throw new IOException("SD path is linked or has the wrong type; left unchanged.");
                if (!directory && write && information.Links > 1)
                    throw new IOException("SD config has multiple hard links; left unchanged.");
                return handle;
            } catch { handle.Dispose(); throw; }
        }
        public static OnionPathLease Open(string path, string root, bool directory, bool write, bool create) {
            string full = Path.GetFullPath(path);
            string boundary = Path.GetFullPath(root).TrimEnd('\\', '/');
            if (!full.Equals(boundary, StringComparison.OrdinalIgnoreCase) &&
                !full.StartsWith(boundary + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new IOException("SD path is outside the selected root.");
            OnionPathLease lease = new OnionPathLease();
            try {
                List<string> ancestors = new List<string>();
                string parent = Path.GetDirectoryName(full);
                while (!String.IsNullOrEmpty(parent)) {
                    ancestors.Add(parent);
                    DirectoryInfo next = Directory.GetParent(parent);
                    parent = next == null ? null : next.FullName;
                }
                ancestors.Reverse();
                // LIST_DIRECTORY plus share-read only pins parents against rename
                // and replacement, while OPEN_REPARSE_POINT rejects junctions.
                foreach (string ancestor in ancestors) lease.directories.Add(OpenHandle(ancestor, true, false, false));
                SafeFileHandle handle = OpenHandle(full, directory, write, create);
                if (directory) lease.directories.Add(handle);
                else {
                    try { lease.stream = new FileStream(handle, write ? FileAccess.ReadWrite : FileAccess.Read, 4096, false); }
                    catch { handle.Dispose(); throw; }
                }
                return lease;
            } catch { lease.Dispose(); throw; }
        }
        public static OnionPathLease CreateDirectory(string path, string root) {
            string full = Path.GetFullPath(path).TrimEnd('\\', '/');
            string boundary = Path.GetFullPath(root).TrimEnd('\\', '/');
            if (!full.Equals(boundary, StringComparison.OrdinalIgnoreCase) &&
                !full.StartsWith(boundary + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new IOException("SD directory is outside the selected root.");
            // Validate device-path syntax before any filesystem mutation. Preserve
            // the separator on a drive root instead of opening drive-relative C:.
            string volumeRoot = Path.GetPathRoot(Path.GetFullPath(root));
            string rootPath = boundary.Length < volumeRoot.Length ? volumeRoot : boundary;
            NativePath(full.Equals(boundary, StringComparison.OrdinalIgnoreCase) ? rootPath : full);
            OnionPathLease lease = Open(rootPath, rootPath, true, false, false);
            try {
                if (full.Equals(boundary, StringComparison.OrdinalIgnoreCase)) return lease;
                string current = rootPath;
                foreach (string part in full.Substring(boundary.Length + 1).Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)) {
                    if (String.IsNullOrEmpty(part) || part == "." || part == "..") throw new IOException("Invalid SD directory component.");
                    current = Path.Combine(current, part);
                    // Each parent is already pinned. Never recursively create
                    // through an unverified intermediate directory or junction.
                    if (!CreateDirectoryW(NativePath(current), IntPtr.Zero)) {
                        int error = Marshal.GetLastWin32Error();
                        if (error != 183) throw new Win32Exception(error, "SD backup directory could not be created safely.");
                    }
                    // An existing or newly created entry is acceptable only
                    // after no-follow validation and a share-read-only pin.
                    lease.directories.Add(OpenHandle(current, true, false, false));
                }
                return lease;
            } catch { lease.Dispose(); throw; }
        }
        public static OnionPathLease CreateBackupSet(string root) {
            string fullRoot = Path.GetFullPath(root);
            string parent = Path.Combine(fullRoot, "Backups");
            OnionPathLease lease = CreateDirectory(parent, fullRoot);
            try {
                var timer = System.Diagnostics.Stopwatch.StartNew();
                string previous = null;
                while (timer.ElapsedMilliseconds < 5000) {
                    string id = DateTime.Now.ToString("yyyy-MM-dd-HH-mm-ss", System.Globalization.CultureInfo.InvariantCulture);
                    if (id == previous) { System.Threading.Thread.Sleep(50); continue; }
                    previous = id;
                    string candidate = Path.Combine(parent, "OptiMiyoo_" + id);
                    // Reserve a new set atomically. A same-second collision must
                    // never merge this run's originals into an existing backup.
                    if (!CreateDirectoryW(NativePath(candidate), IntPtr.Zero)) {
                        int error = Marshal.GetLastWin32Error();
                        if (error == 183) continue;
                        throw new Win32Exception(error, "SD backup set could not be created safely.");
                    }
                    lease.directories.Add(OpenHandle(candidate, true, false, false));
                    lease.DirectoryPath = candidate;
                    return lease;
                }
                throw new IOException("A new timestamped SD backup folder could not be reserved. Retry SD setup.");
            } catch { lease.Dispose(); throw; }
        }
        public void Dispose() {
            try { if (stream != null) { stream.Dispose(); stream = null; } }
            finally {
                for (int i = directories.Count - 1; i >= 0; i--) directories[i].Dispose();
                directories.Clear();
            }
        }
    }
}
'@
}
function Write-OnionBytesVerified([IO.FileStream]$Stream,[byte[]]$Bytes,[string]$Description) {
    $Stream.Position=0
    $Stream.Write($Bytes,0,$Bytes.Length); $Stream.SetLength($Bytes.Length); $Stream.Flush($true)
    $Stream.Position=0
    $memory=New-Object IO.MemoryStream
    try {$Stream.CopyTo($memory); $checked=$memory.ToArray()} finally {$memory.Dispose()}
    if ([Convert]::ToBase64String($checked) -cne [Convert]::ToBase64String($Bytes)) {throw ($Description+' verification failed.')}
}

$rootLease=$null;$backupSetLease=$null;$backupRoot=$null;$display=$false
try {
    # ConPTY looks interactive to the worker even when its parent is redirected.
    # The trusted host forwards its own mode so scripted runs retain plain text.
    if (-not $PlainProgress) {
        Initialize-Display;$display=$true
        Show-OnionProgress -Stage 'Preparing selected changes' -Detail 'Preparing your choices in temporary config copies.' -Force
    }
    $profiles=@(Get-OnionSetupProfiles $ScriptDir)
    $knownSystems=@{};$enabledSystems=@{};$disabledSystems=@{}
    foreach ($profile in $profiles) {$knownSystems[[string]$profile.Folder]=$true}
    if (@($EnableSystems).Count -gt $profiles.Count -or @($DisableSystems).Count -gt $profiles.Count) {throw 'Too many SD system selections.'}
    foreach ($system in $EnableSystems) {
        if ([string]::IsNullOrWhiteSpace($system) -or -not $knownSystems.ContainsKey($system)) {throw 'Unknown SD system selection.'}
        if ($enabledSystems.ContainsKey($system)) {throw 'Duplicate SD system selection.'}
        $enabledSystems[$system]=$true
    }
    foreach ($system in $DisableSystems) {
        if ([string]::IsNullOrWhiteSpace($system) -or -not $knownSystems.ContainsKey($system)) {throw 'Unknown SD system selection.'}
        if ($disabledSystems.ContainsKey($system)) {throw 'Duplicate SD system selection.'}
        if ($enabledSystems.ContainsKey($system)) {throw 'SD system cannot be enabled and disabled together.'}
        $disabledSystems[$system]=$true
    }
    if ([string]::IsNullOrWhiteSpace($OnionRoot)) {throw 'SD setup requires the staged SD root supplied by the application host.'}
    $OnionRoot=(Resolve-Path -LiteralPath $OnionRoot).ProviderPath
    Assert-PlainOnionPath $OnionRoot $OnionRoot
    Initialize-OnionPathLease
    $rootLease=[OptiMiyoo.OnionPathLease]::Open($OnionRoot,$OnionRoot,$true,$false,$false)
    $script:OnionTotal=$profiles.Count
    $changed=0; $unverified=0
    Write-OnionText 'Checking installed system configs. Setup only changes managed file-list extensions in config.json.'
    for ($profileIndex=0;$profileIndex -lt $profiles.Count;$profileIndex++) {
        $profile=$profiles[$profileIndex]
        # The count advances only after a profile's config assessment and
        # preparation have returned.
        $script:OnionCompleted=$profileIndex;$script:OnionStage='Preparing selected changes'
        if (-not $PlainProgress) {Show-OnionProgress -Stage $script:OnionStage -Detail $profile.Name -Completed $script:OnionCompleted -Total $script:OnionTotal -Unit systems -Force}
        if ($SelectionOnly -and -not $enabledSystems.ContainsKey([string]$profile.Folder) -and -not $disabledSystems.ContainsKey([string]$profile.Folder)) {continue}
        $disable=$disabledSystems.ContainsKey([string]$profile.Folder)
        $action='enable';if ($disable) {$action='disable'}
        $folder=$profile.Folder; $emuFolder=$folder
        if ($profile.EmuFolder) {$emuFolder=$profile.EmuFolder}
        $stream=$null; $configLease=$null; $backupLease=$null; $backupDirectoryLease=$null; $original=$null; $writeStarted=$false
        try {
            # Assess and prepare from one bounded capture, keeping the same
            # native read lease until a real edit requires a writable handle.
            try {
                $extensions=@(Get-OnionSetupExtensions $profile)
                $configPath=Join-Path (Join-Path (Join-Path $OnionRoot 'Emu') $emuFolder) 'config.json'
                Assert-PlainOnionPath $configPath $OnionRoot
                if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {continue}
                $configLease=[OptiMiyoo.OnionPathLease]::Open($configPath,$OnionRoot,$false,$false,$false)
                $stream=$configLease.Stream
                if ($stream.Length -gt 1MB) {throw 'config.json exceeds the supported 1 MiB text limit.'}
                $memory=New-Object IO.MemoryStream
                try {$stream.CopyTo($memory); $original=$memory.ToArray()} finally {$memory.Dispose()}
                $null=Get-OnionConfigExtensionData $original
            } catch {
                # Invalid or inaccessible configs remain unverified skips.
                # Patch/write failures below still fail the whole preparation.
                $unverified++
                Write-OnionText ('UNVERIFIED: '+$folder+' - '+$_.Exception.Message)
                continue
            }
            try {
                if ($disable) {$newBytes=Get-OnionConfigPatch -Original $original -Extensions @() -RemoveExtensions $extensions}
                else {$newBytes=Get-OnionConfigPatch -Original $original -Extensions $extensions}
            } catch [IO.InvalidDataException] {
                # Only the helper's bounded-output rejection is an unverified
                # skip. Other patch failures still fail the preparation.
                $outputLimit=$_.Exception.Data['OptiMiyoo.SdConfigOutputLimit']
                if($outputLimit -isnot [bool] -or -not $outputLimit){throw}
                $unverified++
                Write-OnionText ('UNVERIFIED: '+$folder+' - '+$_.Exception.Message)
                continue
            }
            if ([Convert]::ToBase64String($newBytes) -ceq [Convert]::ToBase64String($original)) {Write-OnionText ('READY: '+$folder+' / '+($extensions -join ', ')+' already '+$action+'d'); continue}
            # An already prepared config only needs read access. Upgrade to a
            # writable handle only for a real edit, then recheck the bytes from
            # that handle so a change during the reopen cannot be overwritten.
            $configLease.Dispose(); $configLease=$null; $stream=$null
            $configLease=[OptiMiyoo.OnionPathLease]::Open($configPath,$OnionRoot,$false,$true,$false)
            $stream=$configLease.Stream
            if ($stream.Length -gt 1MB) {throw 'config.json exceeds the supported 1 MiB text limit.'}
            $memory=New-Object IO.MemoryStream
            try {$stream.CopyTo($memory); $current=$memory.ToArray()} finally {$memory.Dispose()}
            if ([Convert]::ToBase64String($current) -cne [Convert]::ToBase64String($original)) {throw 'Config changed during setup. Run the check again.'}
            if (-not $backupRoot) {
                $backupSetLease=[OptiMiyoo.OnionPathLease]::CreateBackupSet($OnionRoot)
                $backupRoot=$backupSetLease.DirectoryPath
            }
            $backup=Join-Path (Join-Path $backupRoot 'Emu') $emuFolder
            Assert-PlainOnionPath $backup $OnionRoot
            $backupDirectoryLease=[OptiMiyoo.OnionPathLease]::CreateDirectory($backup,$OnionRoot)
            $backupLease=[OptiMiyoo.OnionPathLease]::Open((Join-Path $backup 'config.json'),$OnionRoot,$false,$true,$true)
            # Verify the saved original before changing the live config. Both
            # checks use the held handles, including any subsequent restoration.
            Write-OnionBytesVerified $backupLease.Stream $original 'SD backup'
            $writeStarted=$true
            Write-OnionBytesVerified $stream $newBytes 'Updated config'
            $changed++
            Write-OnionText ('PREPARED: '+$folder+' / '+($extensions -join ', ')+' to '+$action)
        } catch {
            $exitCode=1
            if ($writeStarted -and $stream -and $null -ne $original) {
                try {
                    Write-OnionBytesVerified $stream $original 'Restored config'
                } catch {Write-OnionText ('RESTORE FAILED: temporary config copy could not be restored; SD changes will not be applied. '+$_.Exception.Message) -Failure}
            }
            Write-OnionText ('SKIPPED: '+$folder+' - '+$_.Exception.Message) -Failure
        } finally {
            try {if ($backupLease) {$backupLease.Dispose()}}
            finally {
                try {if ($backupDirectoryLease) {$backupDirectoryLease.Dispose()}}
                finally {if ($configLease) {$configLease.Dispose()}}
            }
        }
    }
    $script:OnionCompleted=$profiles.Count;$script:OnionStage='Preparing selected changes'
    Write-OnionText ("$changed system setup change(s) prepared; $unverified config(s) could not be verified.")
    if ($exitCode -eq 0) {
        Write-OnionText 'Waiting for verification before updating the SD config file lists.'
    } else {
        $script:OnionStage='Setup could not finish'
        Write-OnionText 'SD changes will not be applied because setup failed.' -Failure
    }
} catch {
    $exitCode=1;$script:OnionStage='Setup could not finish'
    Write-OnionText ('ERROR: '+$_.Exception.Message) -Failure
} finally {
    try {
        try {if ($backupSetLease) {$backupSetLease.Dispose()}}
        finally {if ($rootLease) {$rootLease.Dispose()}}
    }
    finally {
        try {if ($display) {Restore-Display}}
        finally {
            # A failed worker has no publication report. Keep its diagnostics
            # visible after the live panel is removed and its console closes.
            foreach ($message in $script:OnionErrors) {Write-Host $message}
        }
    }
}
exit $exitCode
