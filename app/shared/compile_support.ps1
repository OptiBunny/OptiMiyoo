# Windows PowerShell 5.1's CodeDOM compiler cannot write to some Unicode paths.
# Bootstrap only the few file APIs needed here; compiling source_policy would
# recursively call this helper. Reflection.Emit creates no temporary files.
function Get-OptiCompilerFileApi {
    $type='OptiMiyoo.CompilerFilesV1' -as [type]
    if ($type) {return $type}
    $name=New-Object Reflection.AssemblyName('OptiMiyoo.CompilerFilesV1')
    $assembly=[AppDomain]::CurrentDomain.DefineDynamicAssembly($name,[Reflection.Emit.AssemblyBuilderAccess]::Run)
    $module=$assembly.DefineDynamicModule($name.Name)
    $builder=$module.DefineType($name.Name,[Reflection.TypeAttributes]'Public, Abstract, Sealed')
    $safe=[Microsoft.Win32.SafeHandles.SafeFileHandle]
    $definitions=@(
        @('CreateFileW',$safe,[type[]]@([string],[uint32],[uint32],[IntPtr],[uint32],[uint32],[IntPtr])),
        @('GetFileInformationByHandle',[bool],[type[]]@($safe,[IntPtr])),
        @('SetFileInformationByHandle',[bool],[type[]]@($safe,[int],[IntPtr],[uint32]))
    )
    $import=[Runtime.InteropServices.DllImportAttribute]
    $attribute=[Reflection.Emit.CustomAttributeBuilder]::new($import.GetConstructor([type[]]@([string])),[object[]]@('kernel32.dll'),[Reflection.FieldInfo[]]@($import.GetField('SetLastError'),$import.GetField('ExactSpelling')),[object[]]@($true,$true))
    foreach ($definition in $definitions) {
        $method=$builder.DefinePInvokeMethod($definition[0],'kernel32.dll',[Reflection.MethodAttributes]'Public, Static, PinvokeImpl',[Reflection.CallingConventions]::Standard,$definition[1],$definition[2],[Runtime.InteropServices.CallingConvention]::Winapi,[Runtime.InteropServices.CharSet]::Unicode)
        $method.SetCustomAttribute($attribute)
        $method.SetImplementationFlags($method.GetMethodImplementationFlags() -bor [Reflection.MethodImplAttributes]::PreserveSig)
    }
    return $builder.CreateType()
}

function Get-OptiScratchRoot {
    # GetTempPath adds an AppContainer Packages/session/AC/Temp suffix. The
    # broker already supplied a private writable root; use its captured path.
    $client='OptiMiyoo.ApplicationRpcClient' -as [type]
    if ($null -ne $client -and $client::IsIsolated) {return $client::WorkPath}
    return [IO.Path]::GetTempPath()
}

# The shipped Windows PowerShell runtime still uses legacy limits for managed
# file operations, even when native handle operations accept extended paths.
function Assert-OptiPathBudget {
    param([Parameter(Mandatory=$true)][string]$Path,[switch]$Directory)
    $full=[IO.Path]::GetFullPath($Path)
    $limit=259;if ($Directory) {$limit=247}
    if ($full.Length -gt $limit) {
        throw 'A working path is too long for Windows PowerShell. Move OptiMiyoo to a shorter folder or shorten the game folders and names, then retry. Originals kept.'
    }
}

function Open-OptiCompilerFile([string]$Path,[uint32]$Access,[uint32]$Share,[uint32]$Creation,[switch]$Directory) {
    $api=Get-OptiCompilerFileApi
    $flags=[uint32]0x00200000 # OPEN_REPARSE_POINT: inspect the entry itself.
    if ($Directory) {$flags=$flags -bor 0x02000000}
    $native=[IO.Path]::GetFullPath($Path)
    if ($native.StartsWith('\\?\',[StringComparison]::Ordinal) -or $native.StartsWith('\\.\',[StringComparison]::Ordinal)) {throw 'Device paths are not supported.'}
    $native=if ($native.StartsWith('\\',[StringComparison]::Ordinal)) {'\\?\UNC\'+$native.Substring(2)} else {'\\?\'+$native}
    $handle=$api::CreateFileW($native,$Access,$Share,[IntPtr]::Zero,$Creation,$flags,[IntPtr]::Zero)
    if ($handle.IsInvalid) {
        $errorCode=[Runtime.InteropServices.Marshal]::GetLastWin32Error();$handle.Dispose()
        throw [ComponentModel.Win32Exception]::new($errorCode,'Compiler scratch file could not be opened safely.')
    }
    return $handle
}

function Get-OptiCompilerFileIdentity($Handle,[switch]$Directory) {
    $api=Get-OptiCompilerFileApi
    # BY_HANDLE_FILE_INFORMATION: attributes, volume serial, links, file index.
    $buffer=[Runtime.InteropServices.Marshal]::AllocHGlobal(52)
    try {
        if (-not $api::GetFileInformationByHandle($Handle,$buffer)) {throw 'Could not inspect compiler scratch ownership.'}
        $attributes=[Runtime.InteropServices.Marshal]::ReadInt32($buffer,0)
        if (($attributes -band 0x400) -or ([bool]($attributes -band 0x10) -ne [bool]$Directory)) {throw 'Compiler scratch entry is linked or has the wrong type; keeping it.'}
        if (-not $Directory -and [Runtime.InteropServices.Marshal]::ReadInt32($buffer,40) -ne 1) {throw 'Compiler scratch file has multiple links; keeping it.'}
        return ((28,44,48 | ForEach-Object {[Runtime.InteropServices.Marshal]::ReadInt32($buffer,$_).ToString('X8')}) -join ':')
    } finally {[Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)}
}

function Remove-OptiCompilerReservation($Entry) {
    $identityHandle=$null;$removal=$null;$buffer=[IntPtr]::Zero
    try {
        # An identity-only handle does not deny deletion, but keeps the original
        # object alive so its file ID cannot be recycled during the reopen gap.
        if ($Entry.Pin) {$identityHandle=Open-OptiCompilerFile $Entry.Path 0 7 3}
        else {$identityHandle=$Entry.IdentityHandle;$Entry.IdentityHandle=$null}
        if ($Entry.Pin) {$Entry.Pin.Dispose();$Entry.Pin=$null}
        $removal=Open-OptiCompilerFile $Entry.Path 2147549184 1 3 # GENERIC_READ | DELETE
        if (-not $Entry.Identity -or (Get-OptiCompilerFileIdentity $removal) -cne $Entry.Identity -or (Get-OptiCompilerFileIdentity $identityHandle) -cne $Entry.Identity) {throw 'Compiler scratch ownership changed; replacement kept.'}
        $api=Get-OptiCompilerFileApi
        $buffer=[Runtime.InteropServices.Marshal]::AllocHGlobal(1)
        [Runtime.InteropServices.Marshal]::WriteByte($buffer,1)
        if (-not $api::SetFileInformationByHandle($removal,4,$buffer,1)) {throw 'Could not remove verified compiler scratch file; keeping it.'}
    } finally {
        if ($buffer -ne [IntPtr]::Zero) {[Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)}
        if ($removal) {$removal.Dispose()}
        if ($identityHandle) {$identityHandle.Dispose()}
        if ($Entry.Pin) {$Entry.Pin.Dispose();$Entry.Pin=$null}
        if ($Entry.IdentityHandle) {$Entry.IdentityHandle.Dispose();$Entry.IdentityHandle=$null}
    }
}

# Keep the caller's environment/cwd intact and give csc relative ASCII names.
function Add-OptiMiyooType {
    param([Parameter(Mandatory=$true)][string]$TypeDefinition)
    $temporary=Get-OptiScratchRoot
    Assert-OptiPathBudget -Path $temporary -Directory
    Assert-OptiPathBudget -Path (Join-Path $temporary ('CSC'+('0'*32)+'.TMP'))
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or $temporary -notmatch '[^\x00-\x7F]') {
        Add-Type -TypeDefinition $TypeDefinition -ErrorAction Stop
        return
    }
    $compiler=Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
    if (-not [IO.File]::Exists($compiler)) {throw 'Windows C# compiler is unavailable; cannot initialize OptiMiyoo helpers.'}
    $id=[Guid]::NewGuid().ToString('N')
    $sourceName='s_'+$id+'.cs';$source=Join-Path $temporary $sourceName
    $assemblyName='h_'+$id+'.dll';$assembly=Join-Path $temporary $assemblyName
    $process=$null;$started=$false;$failure=$null;$sourceStream=$null;$assemblyStream=$null
    $parents=New-Object 'System.Collections.Generic.List[object]'
    $entries=New-Object 'System.Collections.Generic.List[object]'
    try {
        $chain=New-Object 'System.Collections.Generic.List[string]'
        for ($directory=[IO.DirectoryInfo]::new($temporary);$null -ne $directory;$directory=$directory.Parent) {$chain.Insert(0,$directory.FullName)}
        foreach ($path in $chain) {
            # LIST_DIRECTORY participates in sharing, unlike attribute-only opens.
            $parent=Open-OptiCompilerFile $path 129 1 3 -Directory
            $parents.Add($parent);[void](Get-OptiCompilerFileIdentity $parent -Directory)
        }
        foreach ($path in @($source,$assembly)) {
            $isSource=$path -ceq $source
            $access=if ($isSource) {2147483648} else {0}
            $handle=Open-OptiCompilerFile $path $access 3 1 # CREATE_NEW never adopts an existing entry.
            $entry=[pscustomobject]@{Path=$path;Pin=$null;IdentityHandle=$null;Identity=$null}
            if ($isSource) {$entry.Pin=$handle} else {$entry.IdentityHandle=$handle}
            $entries.Add($entry);$entry.Identity=Get-OptiCompilerFileIdentity $handle
        }
        $sourceStream=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $encoding=New-Object Text.UTF8Encoding($true)
        $preamble=$encoding.GetPreamble();$bytes=$encoding.GetBytes($TypeDefinition)
        $sourceStream.Write($preamble,0,$preamble.Length);$sourceStream.Write($bytes,0,$bytes.Length);$sourceStream.Flush($true)
        $sourceStream.Dispose();$sourceStream=$null
        # Seal the source against modification without releasing its rename pin.
        $sealed=Open-OptiCompilerFile $source 2147483648 1 3
        $entries[0].Pin.Dispose();$entries[0].Pin=$sealed
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=$compiler;$start.WorkingDirectory=$temporary
        $start.Arguments='/nologo /noconfig /utf8output /optimize+ /warnaserror+ /target:library /out:'+$assemblyName+' /reference:System.dll /reference:System.Core.dll '+$sourceName
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
        $start.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
        $process=New-Object Diagnostics.Process;$process.StartInfo=$start
        $started=$process.Start()
        if (-not $started) {throw 'Could not start the Windows C# compiler.'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {throw 'Windows C# helper compilation timed out.'}
        $diagnostics=($stdout.Result+[Environment]::NewLine+$stderr.Result).Trim()
        if ($process.ExitCode -ne 0) {throw ('Could not compile OptiMiyoo helper: '+$diagnostics)}
        # csc requires exclusive output access, so this identity-only lease does
        # not prevent another same-user process modifying the output. Refuse any
        # replacement or hardlink, and hold the verified read handle while loading.
        $readHandle=Open-OptiCompilerFile $assembly 2147483648 1 3
        try {
            if ((Get-OptiCompilerFileIdentity $readHandle) -cne $entries[1].Identity -or (Get-OptiCompilerFileIdentity $entries[1].IdentityHandle) -cne $entries[1].Identity) {throw 'Compiler output ownership changed; replacement kept.'}
            $assemblyStream=[IO.FileStream]::new($readHandle,[IO.FileAccess]::Read)
            $memory=New-Object IO.MemoryStream
            try {$assemblyStream.CopyTo($memory);[void][Reflection.Assembly]::Load($memory.ToArray())} finally {$memory.Dispose()}
        } finally {if ($assemblyStream) {$assemblyStream.Dispose();$assemblyStream=$null};$readHandle.Dispose()}
    } catch {$failure=$_;throw} finally {
        $cleanupFailure=$null
        if ($sourceStream) {try {$sourceStream.Dispose()} catch {$cleanupFailure=$_}}
        if ($process) {
            try {if ($started -and -not $process.HasExited) {$process.Kill();[void]$process.WaitForExit(5000)}}
            catch {$cleanupFailure=$_}
            finally {$process.Dispose()}
        }
        try {
            foreach ($entry in $entries) {
                try {Remove-OptiCompilerReservation $entry} catch {if (-not $cleanupFailure) {$cleanupFailure=$_}}
            }
        } finally {for ($index=$parents.Count-1;$index -ge 0;$index--) {$parents[$index].Dispose()}}
        if ($cleanupFailure) {
            if ($failure) {Write-Warning ('Compiler scratch cleanup failed: '+$cleanupFailure.Exception.Message)} else {throw $cleanupFailure}
        }
    }
}
