# App-owned scratch stays beside the installed application. Only process-scoped
# TEMP/TMP are changed; callers regain their exact environment on scope exit.
function Assert-OptiPortableDirectory([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    $drive=[IO.Path]::GetPathRoot($full)
    if ($full.StartsWith('\\',[StringComparison]::Ordinal) -or $drive -notmatch '^[A-Za-z]:\\$') {
        throw 'Keep OptiMiyoo on a writable local NTFS drive.'
    }
    if ((New-Object IO.DriveInfo($drive)).DriveFormat -ine 'NTFS') {
        throw 'Keep OptiMiyoo on a writable local NTFS drive.'
    }
    $chain=New-Object 'System.Collections.Generic.List[string]'
    $current=$full.TrimEnd('\','/')
    while ($current.Length -gt $drive.Length) {
        $chain.Add($current)
        $current=[IO.Path]::GetDirectoryName($current)
    }
    $chain.Add($drive)
    for ($index=$chain.Count-1;$index -ge 0;$index--) {
        $attributes=[IO.File]::GetAttributes($chain[$index])
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -or -not ($attributes -band [IO.FileAttributes]::Directory)) {
            throw 'OptiMiyoo and its data folder must use ordinary folders, not linked paths.'
        }
    }
    return $full
}

function Open-OptiPortableTempScope([Parameter(Mandatory=$true)][string]$ApplicationRoot) {
    $scope=[pscustomobject]@{
        Temp=[Environment]::GetEnvironmentVariable('TEMP','Process')
        Tmp=[Environment]::GetEnvironmentVariable('TMP','Process')
        Path=$null;Lease=$null;Changed=$false;Closed=$false
    }
    try {
        $application=Assert-OptiPortableDirectory $ApplicationRoot
        $folder=$application
        foreach ($name in 'data','temp') {
            # Inspect existing entries directly: Directory.Exists returns false
            # for both absent entries and some broken links.
            $parent=Assert-OptiPortableDirectory $folder
            $folder=Join-Path $parent $name
            $entries=@([IO.Directory]::EnumerateFileSystemEntries($parent,$name))
            if ($entries.Count -eq 0) {[void][IO.Directory]::CreateDirectory($folder)}
            $null=Assert-OptiPortableDirectory $folder
        }
        # CreateNew cannot replace a user's file. DeleteOnClose removes only
        # this invocation's probe, even when a later bootstrap step fails.
        $probe=Join-Path $folder ('.write-'+[Guid]::NewGuid().ToString('N'))
        $stream=New-Object IO.FileStream($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,1,[IO.FileOptions]::DeleteOnClose)
        try {$stream.WriteByte(0);$stream.Flush($true)} finally {$stream.Dispose()}
        $scope.Path=$folder;$scope.Changed=$true
        [Environment]::SetEnvironmentVariable('TEMP',$folder,'Process')
        [Environment]::SetEnvironmentVariable('TMP',$folder,'Process')
        $actual=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        if ($actual -ine $folder.TrimEnd('\','/')) {throw 'Windows did not select OptiMiyoo''s local temporary folder.'}
        # The bootstrap compiler now uses this local folder. Its completed
        # native helper pins every ancestor for the entire application session.
        . (Join-Path $PSScriptRoot 'source_policy.ps1')
        $scope.Lease=Open-SourcePolicyDirectoryLease $folder
        return $scope
    } catch {
        Close-OptiPortableTempScope $scope
        throw
    }
}

function Close-OptiPortableTempScope($Scope) {
    if (-not $Scope -or $Scope.Closed) {return}
    $Scope.Closed=$true
    try {if ($Scope.Lease) {$Scope.Lease.Dispose();$Scope.Lease=$null}}
    finally {
        if ($Scope.Changed) {
            [Environment]::SetEnvironmentVariable('TEMP',$Scope.Temp,'Process')
            [Environment]::SetEnvironmentVariable('TMP',$Scope.Tmp,'Process')
        }
    }
}
