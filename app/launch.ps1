#requires -Version 5.1
param([string]$Root,[switch]$CurrentTerminal,[switch]$NoAnimation)
$ErrorActionPreference='Stop'
$env:PSModuleAnalysisCachePath='NUL'

function New-OptiTerminalCommand([string]$EntryPoint,[string]$Root,[switch]$NoAnimation) {
    # Keep paths out of Windows Terminal's semicolon-delimited command syntax.
    $application=Split-Path -Parent (Split-Path -Parent $EntryPoint)
    $command="`$env:PSModuleAnalysisCachePath='NUL'; Set-Location -LiteralPath '"+$application.Replace("'","''")+"'; & '"+$EntryPoint.Replace("'","''")+"' -DisplayEffect CRT"
    if ($NoAnimation) {$command+=' -NoAnimation'}
    if ($Root) {$command+=" -Root '"+$Root.Replace("'","''")+"'"}
    $command+='; exit $LASTEXITCODE'
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
}

function Start-OptiTerminalWindow([string]$EntryPoint,[string]$Root,[switch]$NoAnimation) {
    $terminal=Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $terminal) {return $false}
    try {
        if ($Root) {$Root=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)}
        $powerShell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $prefix='"'+$powerShell+'" -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand '
        # Use the user's existing default profile without creating registration
        # files or changing its font, theme, shader, or saved preferences.
        $arguments='-w new --size 100,34 new-tab --title OptiMiyoo --suppressApplicationTitle '+$prefix+(New-OptiTerminalCommand $EntryPoint $Root -NoAnimation:$NoAnimation)
        $client=Start-Process -FilePath $terminal.Source -ArgumentList $arguments -WindowStyle Normal -PassThru
        try {
            if ($client.WaitForExit(3000) -and $client.ExitCode -ne 0) {return $false}
        } finally {$client.Dispose()}
        return $true
    } catch {
        Write-Verbose ('Windows Terminal launch unavailable: '+$_.Exception.Message)
        return $false
    }
}

$entryPoint=Join-Path $PSScriptRoot 'make_playlists.ps1'
$interactive=($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected)
if ($interactive -and -not $CurrentTerminal -and (Start-OptiTerminalWindow $entryPoint $Root -NoAnimation:$NoAnimation)) {exit 0}
$parameters=@{DisplayEffect='CRT';NoAnimation=[bool]$NoAnimation}
if ($Root) {$parameters.Root=$Root}
& $entryPoint @parameters
exit $LASTEXITCODE
