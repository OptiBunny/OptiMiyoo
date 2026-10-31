# The host compiles only literal helper sources from this fixed installed file list.
# Child leases stop at its private work root; host leases retain the full path chain.
function Get-ApplicationLiteralHelper {
    param([string]$Text,[string]$FunctionName)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if ($errors.Count) {throw 'Installed application code could not be parsed.'}
    $functions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $FunctionName},$true))
    if ($functions.Count -ne 1) {throw ('Installed helper function is missing or ambiguous: '+$FunctionName)}
    $commands=@($functions[0].Body.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Add-OptiMiyooType'},$true))
    if ($commands.Count -ne 1) {throw ('Installed helper source is missing or ambiguous: '+$FunctionName)}
    $elements=$commands[0].CommandElements
    if ($elements.Count -ne 3 -or $elements[1] -isnot [Management.Automation.Language.CommandParameterAst] -or $elements[1].ParameterName -cne 'TypeDefinition' -or $elements[2] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or $elements[2].StringConstantType -ne 'SingleQuotedHereString') {throw 'Application helpers must be fixed literal C# sources.'}
    return $elements[2].Value
}

function ConvertTo-ApplicationWorkLease {
    param([string]$Source,[string]$WorkRoot)
    $escaped=$WorkRoot.Replace('\','\\').Replace('"','\"')
    $scope=@'
                string scope = "__WORK__";
                string checkedPath = Path.GetFullPath(full).TrimEnd('\\', '/');
                if (!checkedPath.Equals(scope, StringComparison.OrdinalIgnoreCase) &&
                    !checkedPath.StartsWith(scope + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Child lease is outside its isolated work directory.");
                string parent = checkedPath.Equals(scope, StringComparison.OrdinalIgnoreCase) ? null : Path.GetDirectoryName(checkedPath);
                while (!String.IsNullOrEmpty(parent)) {
                    ancestors.Add(parent);
                    if (parent.Equals(scope, StringComparison.OrdinalIgnoreCase)) break;
                    parent = Path.GetDirectoryName(parent);
                }
'@.Replace('__WORK__',$escaped)
    # Match the complete audited ancestor walk once. Fail closed after source changes.
    $pattern='(?s)string parent = Path\.GetDirectoryName\(full\);\s*while \(!String\.IsNullOrEmpty\(parent\)\) \{\s*ancestors\.Add\(parent\);\s*DirectoryInfo next = Directory\.GetParent\(parent\);\s*parent = next == null \? null : next\.FullName;\s*\}'
    $matches=[regex]::Matches($Source,$pattern)
    if ($matches.Count -ne 1) {throw 'The child path-lease source no longer matches its reviewed scope adapter.'}
    return $Source.Substring(0,$matches[0].Index)+$scope+$Source.Substring($matches[0].Index+$matches[0].Length)
}

function New-ApplicationStagedCode {
    param([Parameter(Mandatory=$true)][string]$ApplicationRoot,[Parameter(Mandatory=$true)]$Session)
    . (Join-Path $PSScriptRoot '../shared/compile_support.ps1')
    Initialize-ApplicationSession
    if ($Session.ProcessId -ne 0) {throw 'Application code must be staged before process startup.'}
    $application=[IO.Path]::GetFullPath($ApplicationRoot).TrimEnd('\','/')
    $code=[IO.Path]::GetFullPath($Session.CodePath)
    $work=[IO.Path]::GetFullPath($Session.WorkPath).TrimEnd('\','/')
    $files=@(
        'app/playlists/make_playlists.ps1','app/C64/convert_c64.ps1','app/ZX/convert_zx.ps1','app/onion/prepare_onion.ps1',
        'app/ui/display.ps1','app/shared/compile_support.ps1','app/onion/core_support.ps1','app/shared/overwrite_prompt.ps1',
        'app/ui/mio_idle_library.ps1','app/ui/mio_idle_scheduler.ps1','app/ui/menu_models.ps1',
        'app/shared/output_safety.ps1','app/shared/source_policy.ps1','app/shared/archive_limits.ps1','app/shared/zip_integrity.ps1','app/shared/media_validation.ps1',
        'app/shared/native_process.ps1','app/shared/native_sandbox.ps1','app/shared/archive_sandbox.ps1','app/shared/conversion_layout.ps1',
        'app/runtime/application_session.ps1','app/runtime/application_entry.ps1','app/runtime/application_jobs.ps1','app/runtime/application_archive.ps1',
        'app/systems.json')
    $build=Join-Path $Session.RootPath 'b'
    $helpers=Join-Path $code 'helpers'
    $control=Join-Path $Session.RootPath 'p'
    foreach ($directory in @($Session.RootPath,$code,$work,$build,$helpers,$control)) {Assert-OptiPathBudget -Path $directory -Directory}
    # Check the complete fixed code layout before copying any installed files.
    foreach ($relative in @($files)+@('helpers/application.dll','boot.ps1')) {
        $destination=Join-Path $code $relative
        Assert-OptiPathBudget -Path $destination
        Assert-OptiPathBudget -Path ([IO.Path]::GetDirectoryName($destination)) -Directory
    }
    foreach ($name in 'start.ps1','rpc-handles.txt') {Assert-OptiPathBudget -Path (Join-Path $control $name)}
    Assert-OptiPathBudget -Path (Join-Path $build 'a.dll')
    Assert-OptiPathBudget -Path (Join-Path $build ('CSC'+('0'*32)+'.TMP'))
    $texts=@{};$encoding=New-Object Text.UTF8Encoding($true)
    foreach ($relative in $files) {
        $path=Join-Path $application $relative;$destination=Join-Path $code $relative
        $lease=$null;$buffer=$null
        try {
            $lease=[OptiMiyoo.SourceRemovalLeaseV128]::OpenRead($path)
            if ($lease.Stream.Length -gt 4194304) {throw 'An installed application code file exceeds its staging limit.'}
            $buffer=New-Object IO.MemoryStream;$lease.Stream.CopyTo($buffer);$bytes=$buffer.ToArray()
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
            $target=New-Object IO.FileStream($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try {$target.Write($bytes,0,$bytes.Length)} finally {$target.Dispose()}
            if ($relative.EndsWith('.ps1',[StringComparison]::OrdinalIgnoreCase)) {$texts[$relative]=[Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xfeff)}
        } finally {if($buffer){$buffer.Dispose()};if($lease){$lease.Dispose()}}
    }
    $sources=New-Object Collections.Generic.List[string]
    foreach ($pair in @(
        @('app/ui/display.ps1','Initialize-Display'),@('app/ui/display.ps1','Initialize-FrameTimer'),
        @('app/shared/archive_limits.ps1','Initialize-ArchiveLimits'),@('app/shared/media_validation.ps1','Initialize-NibValidation'),
        @('app/shared/native_process.ps1','Initialize-NativeTextCapture'))) {
        $sources.Add((Get-ApplicationLiteralHelper $texts[$pair[0]] $pair[1]))
    }
    $sourceLease=Get-ApplicationLiteralHelper $texts['app/shared/source_policy.ps1'] 'Initialize-SourcePolicyNative'
    $sources.Add((ConvertTo-ApplicationWorkLease $sourceLease $work))
    $sources.Add((Get-ApplicationLiteralHelper $texts['app/shared/zip_integrity.ps1'] 'Initialize-ZipIntegrity'))
    $onion=Get-ApplicationLiteralHelper $texts['app/onion/prepare_onion.ps1'] 'Initialize-OnionPathLease'
    $sources.Add((ConvertTo-ApplicationWorkLease $onion $work))
    $sources.Add((Get-ApplicationRpcClientSource))
    # The generated assembly is loaded before any app script; attempted new compilation is an error.
    $childSupport="function Add-OptiMiyooType {param([string]`$TypeDefinition) throw 'The isolated application cannot compile additional code.'}`r`n"+
        "function Get-OptiScratchRoot {return [OptiMiyoo.ApplicationRpcClient]::WorkPath}`r`n"
    [IO.File]::WriteAllText((Join-Path $code 'app/shared/compile_support.ps1'),$childSupport,$encoding)
    [void][IO.Directory]::CreateDirectory($build);[void][IO.Directory]::CreateDirectory($helpers)
    $compiler=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    if (-not [IO.File]::Exists($compiler)) {throw 'The Windows .NET Framework compiler is required to prepare the isolated application.'}
    $process=$null;$started=$false;$names=New-Object Collections.Generic.List[string]
    try {
        for($index=0;$index -lt $sources.Count;$index++) {$name='s'+$index+'.cs';$names.Add($name);$sourcePath=Join-Path $build $name;Assert-OptiPathBudget -Path $sourcePath;[IO.File]::WriteAllText($sourcePath,$sources[$index],$encoding)}
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=$compiler;$start.WorkingDirectory=$build
        $start.Arguments='/nologo /noconfig /utf8output /optimize+ /warnaserror+ /target:library /out:a.dll /reference:System.dll /reference:System.Core.dll '+($names -join ' ')
        $start.EnvironmentVariables['TEMP']='.';$start.EnvironmentVariables['TMP']='.';
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
        $start.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
        $process=New-Object Diagnostics.Process;$process.StartInfo=$start;$started=$process.Start()
        if (-not $started) {throw 'The application helper compiler did not start.'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {throw 'The application helper compiler timed out.'}
        if ($process.ExitCode -ne 0) {throw ('The installed application helpers could not be compiled: '+($stdout.Result+$stderr.Result))}
        [IO.File]::Move((Join-Path $build 'a.dll'),(Join-Path $helpers 'application.dll'))
    } finally {
        if ($process) {try {if($started -and -not $process.HasExited){$process.Kill();[void]$process.WaitForExit(5000)}}finally{$process.Dispose()}}
        if ([IO.Directory]::Exists($build)) {[OptiMiyoo.SourceRemovalLeaseV128]::DeleteOwned($build,$Session.RootPath)}
    }
    return [pscustomobject]@{Assemblies=[string[]]@('helpers/application.dll');HelperCount=$sources.Count}
}
