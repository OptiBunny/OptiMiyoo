#requires -Version 5.1
param([string]$OnionRoot,[switch]$NoPause)
$ErrorActionPreference='Stop'
$exitCode=0
$ScriptDir=Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir 'core_support.ps1')
. (Join-Path $ScriptDir 'compile_support.ps1')
. (Join-Path $ScriptDir 'output_safety.ps1')
function Write-OnionText([string]$Text) {Write-Host (ConvertTo-SafeExternalText $Text)}
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
        private static SafeFileHandle OpenHandle(string path, bool directory, bool write, bool create) {
            uint access = directory ? 0x81U : (write ? 0xC0000000U : 0x80000000U);
            uint flags = 0x00200000U | (directory ? 0x02000000U : 0U);
            SafeFileHandle handle = CreateFileW(path, access, 1, IntPtr.Zero, create ? 1U : 3U, flags, IntPtr.Zero);
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

$rootLease=$null
try {
    if (-not $OnionRoot) {$OnionRoot=([string](Read-Host 'SD card root, for example E:\')).Trim().Trim('"')}
    $OnionRoot=(Resolve-Path -LiteralPath $OnionRoot).ProviderPath
    Assert-PlainOnionPath $OnionRoot $OnionRoot
    Initialize-OnionPathLease
    $rootLease=[OptiMiyoo.OnionPathLease]::Open($OnionRoot,$OnionRoot,$true,$false,$false)
    $cores=Join-Path $OnionRoot 'RetroArch/.retroarch/cores'
    Assert-PlainOnionPath $cores $OnionRoot
    if (-not (Test-Path -LiteralPath $cores -PathType Container)) {throw 'This does not look like an Onion SD card root: RetroArch cores folder not found.'}
    $profileData=Get-Content -LiteralPath (Join-Path $ScriptDir 'systems.json') -Raw | ConvertFrom-Json
    $profiles=@($profileData)
    $backupRoot=Join-Path $OnionRoot ('OptiMiyoo_Backup_'+[Guid]::NewGuid().ToString('N'))
    $changed=0; $unsupported=0
    Write-OnionText 'Checking selected cores. Setup only adds supported file-list extensions to config.json.'
    foreach ($profile in $profiles) {
        $support=Get-PlaylistSupport $profile $OnionRoot
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
            # Hold the launcher read-only while editing its config. A concurrent
            # core change must not race the eligibility check on Windows.
            $launchLock=[OptiMiyoo.OnionPathLease]::Open($support.LaunchPath,$OnionRoot,$false,$false,$false)
            $coreLock=[OptiMiyoo.OnionPathLease]::Open((Join-Path $cores $support.Core),$OnionRoot,$false,$false,$false)
            $fresh=Get-PlaylistSupport $profile $OnionRoot
            if (-not $fresh.CanBuild -or $fresh.Core -ne $support.Core) {throw 'Selected core changed during setup. Run the check again.'}
            $configLease=[OptiMiyoo.OnionPathLease]::Open($configPath,$OnionRoot,$false,$false,$false)
            $stream=$configLease.Stream
            if ($stream.Length -gt 1MB) {throw 'config.json exceeds the supported 1 MiB text limit.'}
            $memory=New-Object IO.MemoryStream
            try {$stream.CopyTo($memory); $original=$memory.ToArray()} finally {$memory.Dispose()}
            $utf8=New-Object Text.UTF8Encoding($false,$true)
            $raw=$utf8.GetString($original)
            $config=$raw.TrimStart([char]0xFEFF) | ConvertFrom-Json
            if ($config.launch -ne 'launch.sh') {throw 'Config launcher changed during setup. Run the check again.'}
            if (-not $config.extlist -or $config.extlist -isnot [string]) {throw 'Config has no valid extlist string.'}
            $extensions=@($profile.Playlist.TrimStart('.'))
            if ($profile.Folder -eq 'COMMODORE') {
                $tapeSupport=Get-TapeSwapSupport $profile $OnionRoot $fresh
                if ($tapeSupport.CanBuild) {$extensions+=@($tapeSupport.Extensions | ForEach-Object {$_.TrimStart('.')})}
            }
            $missing=@($extensions | Where-Object {$_ -notin @($config.extlist -split '\|')})
            if ($missing.Count -eq 0) {Write-OnionText ('READY: '+$folder+' / '+$support.Core); continue}
            $rx=New-Object regex('("extlist"\s*:\s*")((?:[^"\\]|\\.)*)(")')
            if ($rx.Matches($raw).Count -ne 1) {throw 'Ambiguous extlist in config.'}
            $newRaw=$rx.Replace($raw,('${1}${2}|'+($missing -join '|')+'${3}'))
            $null=($newRaw.TrimStart([char]0xFEFF) | ConvertFrom-Json)
            $newBytes=$utf8.GetBytes($newRaw)
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
            Write-OnionText ('UPDATED: '+$folder+' / '+$support.Core+' / '+($missing -join ', ')+' visible')
        } catch {
            $exitCode=1
            if ($writeStarted -and $stream -and $null -ne $original) {
                try {
                    Write-OnionBytesVerified $stream $original 'Restored config'
                } catch {Write-OnionText ('RESTORE FAILED: restore config.json from '+$backupRoot+' / '+$_.Exception.Message)}
            }
            Write-OnionText ('SKIPPED: '+$folder+' - '+$_.Exception.Message)
        } finally {
            if ($backupLease) {$backupLease.Dispose()}
            if ($configLease) {$configLease.Dispose()}
            if ($coreLock) {$coreLock.Dispose()}
            if ($launchLock) {$launchLock.Dispose()}
        }
    }
    Write-OnionText ("$changed system setup(s) updated; $unsupported unsupported/unverified. Selected cores preserved.")
    if ($changed -gt 0) {Write-OnionText ('Original config.json files: '+$backupRoot); Write-OnionText 'Refresh the Onion game list.'}
} catch {$exitCode=1; Write-OnionText ('ERROR: '+$_.Exception.Message)} finally {if ($rootLease) {$rootLease.Dispose()}}
if (-not $NoPause) {[void](Read-Host 'Press Enter to exit')}
exit $exitCode
