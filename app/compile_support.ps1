# Windows PowerShell 5.1's CodeDOM compiler cannot write to some Unicode paths.
# Keep the caller's environment/cwd intact and give csc only relative ASCII names.
function Add-OptiMiyooType {
    param([Parameter(Mandatory=$true)][string]$TypeDefinition)
    $temporary=[IO.Path]::GetTempPath()
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or $temporary -notmatch '[^\x00-\x7F]') {
        Add-Type -TypeDefinition $TypeDefinition -ErrorAction Stop
        return
    }
    $compiler=Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
    if (-not [IO.File]::Exists($compiler)) {throw 'Windows C# compiler is unavailable; cannot initialize OptiMiyoo helpers.'}
    $id=[Guid]::NewGuid().ToString('N')
    $folder=Join-Path $temporary ('oc_'+$id)
    $source=Join-Path $folder 'source.cs'
    $assemblyName='h_'+$id+'.dll'
    $assembly=Join-Path $folder $assemblyName
    $process=$null; $started=$false; $created=$false; $failure=$null
    try {
        [void][IO.Directory]::CreateDirectory($folder); $created=$true
        [IO.File]::WriteAllText($source,$TypeDefinition,(New-Object Text.UTF8Encoding($true)))
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=$compiler
        $start.WorkingDirectory=$folder
        $start.Arguments='/nologo /noconfig /utf8output /optimize+ /warnaserror+ /target:library /out:'+$assemblyName+' /reference:System.dll /reference:System.Core.dll source.cs'
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        $start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
        $start.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
        $process=New-Object Diagnostics.Process; $process.StartInfo=$start
        $started=$process.Start()
        if (-not $started) {throw 'Could not start the Windows C# compiler.'}
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {throw 'Windows C# helper compilation timed out.'}
        $diagnostics=($stdout.Result+[Environment]::NewLine+$stderr.Result).Trim()
        if ($process.ExitCode -ne 0) {throw ('Could not compile OptiMiyoo helper: '+$diagnostics)}
        # Loading bytes keeps the temporary DLL deletable and the assembly alive.
        [void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assembly))
    } catch {$failure=$_; throw} finally {
      try {
        if ($process) {
            try {if ($started -and -not $process.HasExited) {$process.Kill(); [void]$process.WaitForExit(5000)}}
            finally {$process.Dispose()}
        }
        if ($created) {
            # Only these two files belong to this invocation; never recursively
            # remove the caller's TEMP or an unexpected entry in the scratch dir.
            [IO.File]::Delete($source)
            [IO.File]::Delete($assembly)
            [IO.Directory]::Delete($folder,$false)
        }
      } catch {
        if ($failure) {Write-Warning ('Compiler scratch cleanup failed: '+$_.Exception.Message)}
        else {throw}
      }
    }
}
