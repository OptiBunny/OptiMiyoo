#requires -Version 5.1
# Windows Terminal appearance is kept in OptiMiyoo's own fragment. Never change
# another profile, global renderer preferences, or settings.json contents here.

function Test-OptiTerminalShaderSupport([string]$TerminalPath) {
    if (-not $TerminalPath -or -not [IO.File]::Exists($TerminalPath)) {return $false}
    try {
        $minimum=[version]'1.24'
        $fileVersion=$null
        try {$fileVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($TerminalPath).FileVersion} catch {}
        $version=$null
        if ($fileVersion -and [version]::TryParse($fileVersion.Trim(),[ref]$version) -and $version.Major -gt 0) {
            return ($version -ge $minimum)
        }
        # App execution aliases carry no PE version resource. Only infer their
        # target when one installed Terminal package makes that unambiguous.
        if (-not $env:LOCALAPPDATA) {return $false}
        $aliasPath=Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/wt.exe'
        if ([IO.Path]::GetFullPath($TerminalPath) -ine [IO.Path]::GetFullPath($aliasPath)) {return $false}
        if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {return $false}
        $packages=@(Get-AppxPackage -Name 'Microsoft.WindowsTerminal*' -ErrorAction Stop)
        if ($packages.Count -ne 1) {return $false}
        $version=$null
        if (-not [version]::TryParse([string]$packages[0].Version,[ref]$version)) {return $false}
        return ($version -ge $minimum)
    } catch {
        Write-Verbose ('Windows Terminal shader support could not be determined: '+$_.Exception.Message)
        return $false
    }
}

function Write-OptiTerminalOwnedBytes([string]$Path,[byte[]]$Bytes) {
    if ([IO.File]::Exists($Path)) {
        $current=[IO.File]::ReadAllBytes($Path)
        if ($current.Length -eq $Bytes.Length -and
            [Convert]::ToBase64String($current) -ceq [Convert]::ToBase64String($Bytes)) {return $false}
    }
    $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllBytes($temporary,$Bytes)
        if ([IO.File]::Exists($Path)) {[IO.File]::Replace($temporary,$Path,[NullString]::Value)}
        else {[IO.File]::Move($temporary,$Path)}
    } finally {
        if ([IO.File]::Exists($temporary)) {[IO.File]::Delete($temporary)}
    }
    return $true
}

function Install-OptiTerminalShader([string]$SourcePath) {
    if (-not $SourcePath -or -not [IO.File]::Exists($SourcePath) -or -not $env:LOCALAPPDATA) {return ''}
    try {
        $folder=Join-Path $env:LOCALAPPDATA 'Microsoft/Windows Terminal/Fragments/OptiMiyoo'
        [void][IO.Directory]::CreateDirectory($folder)
        $dynamicPath=Join-Path $folder 'crt.hlsl'
        $staticPath=Join-Path $folder 'crt-static.hlsl'
        $encoding=New-Object Text.UTF8Encoding($false)
        $source=[IO.File]::ReadAllText($SourcePath)
        [void](Write-OptiTerminalOwnedBytes $dynamicPath $encoding.GetBytes($source))
        $staticSource="#define OPTIMIYOO_STATIC_TIME 1`r`n"+$source
        [void](Write-OptiTerminalOwnedBytes $staticPath $encoding.GetBytes($staticSource))
        return $dynamicPath
    } catch {
        Write-Verbose ('OptiMiyoo CRT shader installation unavailable: '+$_.Exception.Message)
        return ''
    }
}

function Update-OptiTerminalSettings {
    if (-not $env:LOCALAPPDATA) {return $false}
    $updated=$false
    foreach ($relative in @(
        'Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json',
        'Packages/Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe/LocalState/settings.json',
        'Microsoft/Windows Terminal/settings.json'
    )) {
        try {
            $settings=Join-Path $env:LOCALAPPDATA $relative
            if ([IO.File]::Exists($settings)) {
                # Terminal watches settings.json, not fragment files. A timestamp
                # nudge reloads the fragment without rewriting user preferences.
                [IO.File]::SetLastWriteTimeUtc($settings,[DateTime]::UtcNow)
                $updated=$true
            }
        } catch {
            Write-Verbose ('Windows Terminal settings refresh unavailable: '+$_.Exception.Message)
        }
    }
    return $updated
}

function Set-OptiTerminalCrtMode([ValidateSet('CRT','Smooth','Paused')][string]$Mode) {
    $profileId='{062ba315-bc8f-42eb-a971-d0eb828209dd}'
    if ($env:WT_PROFILE_ID -ne $profileId -or $env:OPTIMIYOO_CRT_HOST -cne '1' -or -not $env:LOCALAPPDATA) {return $false}
    try {
        $folder=Join-Path $env:LOCALAPPDATA 'Microsoft/Windows Terminal/Fragments/OptiMiyoo'
        $fragment=Join-Path $folder 'profile.json'
        if (-not [IO.File]::Exists($fragment)) {return $false}
        $document=[IO.File]::ReadAllText($fragment) | ConvertFrom-Json
        $profiles=@($document.profiles | Where-Object {$_.guid -eq $profileId})
        if ($profiles.Count -ne 1) {return $false}
        $profile=$profiles[0]
        $shaderPath=''
        if ($Mode -eq 'CRT') {$shaderPath=Join-Path $folder 'crt.hlsl'}
        elseif ($Mode -eq 'Paused') {$shaderPath=Join-Path $folder 'crt-static.hlsl'}
        if ($shaderPath -and -not [IO.File]::Exists($shaderPath)) {return $false}
        $property=$profile.PSObject.Properties['experimental.pixelShaderPath']
        $currentPath=''
        if ($property) {$currentPath=[string]$property.Value}
        if ($currentPath -cne $shaderPath) {
            if ($property) {$property.Value=$shaderPath}
            else {$profile | Add-Member NoteProperty 'experimental.pixelShaderPath' $shaderPath}
            $json=$document | ConvertTo-Json -Depth 100
            $encoding=New-Object Text.UTF8Encoding($false)
            if (Write-OptiTerminalOwnedBytes $fragment $encoding.GetBytes($json)) {
                [void](Update-OptiTerminalSettings)
            }
        }
        # Smooth returns false even after a successful update: callers use this
        # result to decide whether the terminal is providing the CRT effect.
        return ($Mode -ne 'Smooth')
    } catch {
        Write-Verbose ('OptiMiyoo CRT effect unavailable: '+$_.Exception.Message)
        return $false
    }
}
