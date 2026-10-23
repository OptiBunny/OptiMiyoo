#requires -Version 5.1
param([string]$Root,[switch]$CurrentTerminal)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'terminal_effects.ps1')

function New-OptiTerminalCommand([string]$EntryPoint,[string]$Root,[switch]$CrtHost) {
    # Keep paths out of Windows Terminal's semicolon-delimited command syntax.
    $command="& '"+$EntryPoint.Replace("'","''")+"'"
    if ($Root) {$command+=" -Root '"+$Root.Replace("'","''")+"'"}
    if ($CrtHost) {$command="`$env:OPTIMIYOO_CRT_HOST='1'; "+$command}
    $command+='; exit $LASTEXITCODE'
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
}

function Start-OptiTerminalWindow([string]$EntryPoint,[string]$Root) {
    $terminal=Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $terminal -or -not $env:LOCALAPPDATA) {return $false}
    try {
        if ($Root) {$Root=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)}
        $profileId='{062ba315-bc8f-42eb-a971-d0eb828209dd}'
        $powerShell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $prefix='"'+$powerShell+'" -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand '
        $shader=''
        if (Test-OptiTerminalShaderSupport $terminal.Source) {
            $shader=Install-OptiTerminalShader (Join-Path (Split-Path -Parent $EntryPoint) 'shaders/crt.hlsl')
        }
        $profile=[ordered]@{
            guid=$profileId
            name='OptiMiyoo'
            commandline=$prefix+(New-OptiTerminalCommand $EntryPoint '' -CrtHost:([bool]$shader))
            startingDirectory=(Split-Path -Parent (Split-Path -Parent $EntryPoint))
            font=@{face='Consolas';size=12;weight='bold'}
            antialiasingMode='grayscale'
            opacity=100
            useAcrylic=$false
            'experimental.retroTerminalEffect'=$false
            'experimental.pixelShaderPath'=$shader
        }
        $fragment=Join-Path $env:LOCALAPPDATA 'Microsoft/Windows Terminal/Fragments/OptiMiyoo/profile.json'
        $json=@{profiles=@($profile)} | ConvertTo-Json -Depth 5
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $fragment))
        if (-not [IO.File]::Exists($fragment) -or [IO.File]::ReadAllText($fragment) -cne $json) {
            [IO.File]::WriteAllText($fragment,$json,(New-Object Text.UTF8Encoding($false)))
            [void](Update-OptiTerminalSettings)
            Start-Sleep -Milliseconds 500
        }
        $arguments='-w new --size 100,34 new-tab --profile '+$profileId+' --title OptiMiyoo --suppressApplicationTitle '+$prefix+(New-OptiTerminalCommand $EntryPoint $Root -CrtHost:([bool]$shader))
        $client=Start-Process -FilePath $terminal.Source -ArgumentList $arguments -WindowStyle Normal -PassThru
        try {
            if ($client.WaitForExit(3000) -and $client.ExitCode -ne 0) {return $false}
        } finally {$client.Dispose()}
        return $true
    } catch {
        # A missing/disabled Terminal or an unwritable profile must never stop
        # the application from opening in its ordinary console host.
        Write-Verbose ('Windows Terminal launch unavailable: '+$_.Exception.Message)
        return $false
    }
}

$entryPoint=Join-Path $PSScriptRoot 'make_playlists.ps1'
$interactive=($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected)
$inOptiProfile=($env:WT_PROFILE_ID -eq '{062ba315-bc8f-42eb-a971-d0eb828209dd}')
if ($interactive -and -not $CurrentTerminal -and -not $inOptiProfile -and (Start-OptiTerminalWindow $entryPoint $Root)) {exit 0}
$parameters=@{}
if ($Root) {$parameters.Root=$Root}
& $entryPoint @parameters
exit $LASTEXITCODE
