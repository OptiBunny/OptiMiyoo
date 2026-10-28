#requires -Version 5.1
[CmdletBinding()]
param([string]$OnionRoot,[switch]$NoAnimation,[switch]$NoColor,
      [ValidateSet('CRT','Smooth')][string]$DisplayEffect='CRT',
      [Parameter(DontShow=$true)][switch]$PlainProgress)
$ErrorActionPreference='Stop'
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
$script:OnionCompleted=0;$script:OnionTotal=-1;$script:OnionStage='Checking selected cores'
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
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);
        private readonly List<SafeFileHandle> directories = new List<SafeFileHandle>();
        private FileStream stream;
        public FileStream Stream { get { return stream; } }
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

$rootLease=$null;$display=$false
try {
    # ConPTY looks interactive to the worker even when its parent is redirected.
    # The trusted host forwards its own mode so scripted runs retain plain text.
    if (-not $PlainProgress) {
        Initialize-Display;$display=$true
        Show-OnionProgress -Stage 'Reading SD configuration' -Detail 'Checking the selected emulator settings.' -Force
    }
    if ([string]::IsNullOrWhiteSpace($OnionRoot)) {throw 'SD setup requires the staged SD root supplied by the application host.'}
    $OnionRoot=(Resolve-Path -LiteralPath $OnionRoot).ProviderPath
    Assert-PlainOnionPath $OnionRoot $OnionRoot
    Initialize-OnionPathLease
    $rootLease=[OptiMiyoo.OnionPathLease]::Open($OnionRoot,$OnionRoot,$true,$false,$false)
    $cores=Join-Path $OnionRoot 'RetroArch/.retroarch/cores'
    Assert-PlainOnionPath $cores $OnionRoot
    if (-not (Test-Path -LiteralPath $cores -PathType Container)) {throw 'This does not look like an Onion SD card root: RetroArch cores folder not found.'}
    $profiles=@(Get-OnionSetupProfiles $ScriptDir)
    $script:OnionTotal=$profiles.Count
    $backupRoot=Join-Path $OnionRoot ('OptiMiyoo_Backup_'+[Guid]::NewGuid().ToString('N'))
    $changed=0; $unsupported=0
    Write-OnionText 'Checking selected cores. Setup only adds supported file-list extensions to config.json.'
    for ($profileIndex=0;$profileIndex -lt $profiles.Count;$profileIndex++) {
        $profile=$profiles[$profileIndex]
        # The count advances only after a profile's assessment/preparation has
        # returned. A slow core check never receives an invented percentage.
        $script:OnionCompleted=$profileIndex;$script:OnionStage='Checking selected cores'
        if (-not $PlainProgress) {Show-OnionProgress -Stage $script:OnionStage -Detail $profile.Name -Completed $script:OnionCompleted -Total $script:OnionTotal -Unit systems -Force}
        $support=Get-OnionSetupSupport $profile $OnionRoot
        if ($support.Status -eq 'NOT INSTALLED') {continue}
        if ($profile.Folder -eq 'COMMODORE') {
            $tapeSupport=Get-TapeSwapSupport $profile $OnionRoot $support
            Write-OnionText ('TAPES '+$tapeSupport.Status+': COMMODORE / '+$tapeSupport.Core+' - '+$tapeSupport.Reason)
        }
        if (-not $support.CanBuild) {
            $unsupported++
            Write-OnionText ($support.Status+': '+$profile.Folder+' / '+$support.Core+' - '+$support.Reason)
            continue
        }
        $folder=$profile.Folder; $configPath=$support.ConfigPath
        $stream=$null; $configLease=$null; $launchLock=$null; $coreLock=$null; $backupLease=$null; $original=$null; $writeStarted=$false
        try {
            $script:OnionStage='Preparing file types'
            if (-not $PlainProgress) {Show-OnionProgress -Stage $script:OnionStage -Detail $profile.Name -Completed $script:OnionCompleted -Total $script:OnionTotal -Unit systems -Force}
            # Hold the launcher read-only while editing its config. A concurrent
            # core change must not race the eligibility check on Windows.
            $launchLock=[OptiMiyoo.OnionPathLease]::Open($support.LaunchPath,$OnionRoot,$false,$false,$false)
            $coreLock=[OptiMiyoo.OnionPathLease]::Open((Join-Path $cores $support.Core),$OnionRoot,$false,$false,$false)
            $fresh=Get-OnionSetupSupport $profile $OnionRoot
            if (-not $fresh.CanBuild -or $fresh.Core -ne $support.Core) {throw 'Selected core changed during setup. Run the check again.'}
            $configLease=[OptiMiyoo.OnionPathLease]::Open($configPath,$OnionRoot,$false,$false,$false)
            $stream=$configLease.Stream
            if ($stream.Length -gt 1MB) {throw 'config.json exceeds the supported 1 MiB text limit.'}
            $memory=New-Object IO.MemoryStream
            try {$stream.CopyTo($memory); $original=$memory.ToArray()} finally {$memory.Dispose()}
            $extensions=@(Get-OnionSetupExtensions $profile $OnionRoot $fresh)
            $newBytes=Get-OnionConfigPatch -Original $original -Extensions $extensions
            if ([Convert]::ToBase64String($newBytes) -ceq [Convert]::ToBase64String($original)) {Write-OnionText ('READY: '+$folder+' / '+$support.Core); continue}
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
            $backup=Join-Path $backupRoot $support.EmuFolder
            Assert-PlainOnionPath $backup $OnionRoot
            [void][IO.Directory]::CreateDirectory($backup)
            $backupLease=[OptiMiyoo.OnionPathLease]::Open((Join-Path $backup 'config.json'),$OnionRoot,$false,$true,$true)
            # Verify the saved original before changing the live config. Both
            # checks use the held handles, including any subsequent restoration.
            Write-OnionBytesVerified $backupLease.Stream $original 'SD backup'
            $writeStarted=$true
            Write-OnionBytesVerified $stream $newBytes 'Updated config'
            $changed++
            Write-OnionText ('PREPARED: '+$folder+' / '+$support.Core+' / '+($extensions -join ', ')+' to enable')
        } catch {
            $exitCode=1
            if ($writeStarted -and $stream -and $null -ne $original) {
                try {
                    Write-OnionBytesVerified $stream $original 'Restored config'
                } catch {Write-OnionText ('RESTORE FAILED: temporary config copy could not be restored; SD changes will not be applied. '+$_.Exception.Message) -Failure}
            }
            Write-OnionText ('SKIPPED: '+$folder+' - '+$_.Exception.Message) -Failure
        } finally {
            if ($backupLease) {$backupLease.Dispose()}
            if ($configLease) {$configLease.Dispose()}
            if ($coreLock) {$coreLock.Dispose()}
            if ($launchLock) {$launchLock.Dispose()}
        }
    }
    $script:OnionCompleted=$profiles.Count;$script:OnionStage='Core checks finished'
    Write-OnionText ("$changed system setup change(s) prepared; $unsupported unsupported/unverified.")
    if ($exitCode -eq 0) {
        $script:OnionStage='Verification pending'
        Write-OnionText 'Waiting for verification before updating the SD card. Selected cores are preserved.'
    } else {
        $script:OnionStage='Setup could not finish'
        Write-OnionText 'SD changes will not be applied because setup failed.' -Failure
    }
} catch {
    $exitCode=1;$script:OnionStage='Setup could not finish'
    Write-OnionText ('ERROR: '+$_.Exception.Message) -Failure
} finally {
    try {if ($rootLease) {$rootLease.Dispose()}}
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
