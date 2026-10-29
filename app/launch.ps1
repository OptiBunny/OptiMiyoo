#requires -Version 5.1
param([string]$Root,[switch]$CurrentTerminal,[switch]$NoAnimation)
$ErrorActionPreference='Stop'
$env:PSModuleAnalysisCachePath='NUL'

function New-OptiTerminalCommand([string]$EntryPoint,[string]$Root,[switch]$NoAnimation) {
    # Keep paths out of Windows Terminal's semicolon-delimited command syntax.
    $application=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $EntryPoint))
    $command="`$env:PSModuleAnalysisCachePath='NUL'; Set-Location -LiteralPath '"+$application.Replace("'","''")+"'; & '"+$EntryPoint.Replace("'","''")+"' -DisplayEffect CRT"
    if ($NoAnimation) {$command+=' -NoAnimation'}
    if ($Root) {$command+=" -Root '"+$Root.Replace("'","''")+"'"}
    $command+='; exit $LASTEXITCODE'
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
}

function Get-OptiTerminalPackages {
    # Query current-user registration directly; PATH and module discovery are
    # not executable authority. Hosts without WinRT simply keep this console.
    $manager=[Windows.Management.Deployment.PackageManager,Windows.Management.Deployment,ContentType=WindowsRuntime]::new()
    $publisher='CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    foreach($name in 'Microsoft.WindowsTerminal','Microsoft.WindowsTerminalPreview') {
        foreach($package in $manager.FindPackagesForUser('',$name,$publisher)) {$package}
    }
}

function Resolve-OptiTerminalExecutable {
    $publisher='CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    try {$packages=@(Get-OptiTerminalPackages)} catch {return $null}
    foreach($package in $packages) {
        try {
            $identity=$package.Id;$name=[string]$identity.Name
            if($name -cnotin 'Microsoft.WindowsTerminal','Microsoft.WindowsTerminalPreview' -or
               [string]$identity.Publisher -cne $publisher -or [string]$identity.PublisherId -cne '8wekyb3d8bbwe' -or
               [string]$identity.FamilyName -cne ($name+'_8wekyb3d8bbwe') -or
               [string]$identity.FullName -cnotmatch ('^'+[regex]::Escape($name)+'_[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+_(?:x64|x86|arm64|neutral)__8wekyb3d8bbwe$')) {continue}
            # Publisher text alone cannot authenticate a sideloaded package.
            if([string]$package.SignatureKind -cnotin 'Store','System') {continue}
            $ordinary=$true
            foreach($flag in 'IsDevelopmentMode','IsFramework','IsResourcePackage','IsBundle') {
                if($package.$flag -isnot [bool] -or $package.$flag) {$ordinary=$false;break}
            }
            if(-not $ordinary) {continue}
            $healthy=$package.Status.VerifyIsOK()
            if($healthy -isnot [bool] -or -not $healthy) {continue}
            $location=[string]$package.InstalledLocation.Path
            if($location -notmatch '^[A-Za-z]:\\' -or $location -match '[\x00-\x1f]') {continue}
            $location=$location.TrimEnd('\')
            $full=[IO.Path]::GetFullPath($location)
            if(-not $full.Equals($location,[StringComparison]::OrdinalIgnoreCase) -or
               [IO.Path]::GetFileName($full) -cne [string]$identity.FullName) {continue}
            $linked=$false
            for($folder=[IO.DirectoryInfo]::new($full);$null -ne $folder;$folder=$folder.Parent) {
                $attributes=[IO.File]::GetAttributes($folder.FullName)
                if(($attributes -band [IO.FileAttributes]::ReparsePoint) -or -not ($attributes -band [IO.FileAttributes]::Directory)) {$linked=$true;break}
            }
            if($linked) {continue}
            $executable=Join-Path $full 'wt.exe'
            $attributes=[IO.File]::GetAttributes($executable)
            if($attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Directory)) {continue}
            return $executable
        } catch {continue}
    }
    return $null
}

function Start-OptiTerminalWindow([string]$EntryPoint,[string]$Root,[switch]$NoAnimation) {
    $terminal=Resolve-OptiTerminalExecutable
    if (-not $terminal) {return $false}
    try {
        if ($Root) {$Root=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)}
        $powerShell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $prefix='"'+$powerShell+'" -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand '
        # Use the user's existing default profile without creating registration
        # files or changing its font, theme, shader, or saved preferences.
        $arguments='-w new --size 100,35 new-tab --title OptiMiyoo --suppressApplicationTitle '+$prefix+(New-OptiTerminalCommand $EntryPoint $Root -NoAnimation:$NoAnimation)
        $client=Start-Process -FilePath $terminal -ArgumentList $arguments -WindowStyle Normal -PassThru
        try {
            if ($client.WaitForExit(3000) -and $client.ExitCode -ne 0) {return $false}
        } finally {$client.Dispose()}
        return $true
    } catch {
        Write-Verbose ('Windows Terminal launch unavailable: '+$_.Exception.Message)
        return $false
    }
}

$entryPoint=Join-Path $PSScriptRoot 'playlists/make_playlists.ps1'
$interactive=($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected)
# Default-console handoff does not set WT_SESSION. Reuse a capable current
# host instead of leaving an exited launcher window behind during startup.
if ($interactive -and -not $CurrentTerminal -and -not $Host.UI.SupportsVirtualTerminal -and (Start-OptiTerminalWindow $entryPoint $Root -NoAnimation:$NoAnimation)) {exit 0}
$parameters=@{DisplayEffect='CRT';NoAnimation=[bool]$NoAnimation}
if ($Root) {$parameters.Root=$Root}
& $entryPoint @parameters
exit $LASTEXITCODE
