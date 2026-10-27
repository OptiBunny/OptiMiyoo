#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Root,
    [string]$System,
    [ValidateSet('Auto','Zip','Loose','Folders')][string]$Storage='Zip',
    [ValidateSet('Auto','Zip','Loose','Folders')][string]$SingleStorage='Auto',
    [ValidateSet('Keep','Remove')][string]$SourcePolicy='Keep',
    [ValidateSet('Ask','Overwrite','Skip')][string]$Existing='Ask',
    [string]$OnionRoot,
    [switch]$PrepareOnion,
    [switch]$NoPause,
    [switch]$NoAnimation,
    [switch]$NoColor,
    [ValidateSet('CRT','Smooth')][string]$DisplayEffect='CRT',
    [switch]$Preview,
    [ValidateSet('Tour','C64','ZX','Playlists','Results','Bunny','Setup')][string]$PreviewSection='Tour',
    [switch]$ZXConvert,
    [switch]$C64Convert,
    [ValidateSet('Main','C64','ZX')][string]$StartPage='Main'
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../runtime/application_entry.ps1')
if (-not (Test-ApplicationWorker)) {
    exit (Enter-ApplicationHost -ApplicationRoot (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -Entry Playlist -Arguments $PSBoundParameters)
}
$script:AppVersion='0.0.9'
$ScriptDir=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $ScriptDir 'shared/source_policy.ps1')
. (Join-Path $ScriptDir 'shared/archive_limits.ps1')
. (Join-Path $ScriptDir 'shared/zip_integrity.ps1')
. (Join-Path $ScriptDir 'shared/archive_sandbox.ps1')
. (Join-Path $ScriptDir 'shared/overwrite_prompt.ps1')
. (Join-Path $ScriptDir 'onion/core_support.ps1')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Format-Duration([double]$Seconds) {
    if ($Seconds -lt 0 -or [double]::IsInfinity($Seconds)) { return 'calculating...' }
    $span = [TimeSpan]::FromSeconds([Math]::Max(0, $Seconds))
    return ('{0:00}:{1:00}:{2:00}' -f [Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds)
}

function Confirm-Overwrite {
    if ($script:ExistingPolicy -eq 'Overwrite') { return $true }
    if ($script:ExistingPolicy -eq 'Skip') { return $false }
    foreach ($id in 2, 1, 0) { Write-Progress -Id $id -Activity 'Waiting for overwrite choice' -Completed }
    $script:Clock.Stop()
    try {
        do {
            $choice=ConvertFrom-OverwriteAnswer (Read-ApplicationOverwriteChoice)
            switch ($choice) {
                'Overwrite' { return $true }
                'Skip' { return $false }
                'OverwriteAll' { $script:ExistingPolicy = 'Overwrite'; return $true }
                'SkipAll' { $script:ExistingPolicy = 'Skip'; return $false }
            }
        } while ($true)
    } finally { $script:Clock.Start() }
}

function Move-OutputPath([string]$Source, [string]$Destination, [bool]$Folder) {
    if ($Folder) { [IO.Directory]::Move($Source, $Destination) }
    else { [IO.File]::Move($Source, $Destination) }
}

function Get-NaturalDiskKey([string]$Name) {
    # Compare numbers numerically: Disk 2 sorts before Disk 10.
    return [regex]::Replace($Name.ToLowerInvariant(), '\d+', {
        param($match)
        $match.Value.TrimStart('0').PadLeft(20, '0')
    })
}

function Assert-PlainOutputParents([string]$Path, [string]$Root) {
    if (Get-Command Get-ApplicationValidationRoot -ErrorAction SilentlyContinue) {$Root=Get-ApplicationValidationRoot $Path $Root}
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    while ($parent -and $parent.Length -ge $rootFull.Length) {
        if (Test-Path -LiteralPath $parent) {
            $item = Get-Item -LiteralPath $parent -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Output parent is a link or not a directory: $parent"
            }
        }
        if ($parent.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
}

function Install-PlaylistSet([object[]]$Items, [bool]$Overwrite, [object[]]$Retired=@(), [scriptblock]$ValidateBackup=$null) {
    # A playlist and its disk data are one replacement. Roll back both if either
    # install fails; never leave a new playlist pointing at missing/old data.
    $backups = New-Object 'System.Collections.Generic.List[object]'
    $installed = New-Object 'System.Collections.Generic.List[object]'
    $locks = New-Object 'System.Collections.Generic.List[System.IDisposable]'
    $targets = New-Object 'System.Collections.Generic.List[object]'
    $replaceTargets = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $Items) { $targets.Add($item) }
    foreach ($item in $Retired) { $targets.Add($item) }
    $directoryLocks=New-Object 'System.Collections.Generic.List[System.IDisposable]'
    try {
        try {
            $parents=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($item in $targets) {[void]$parents.Add([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($item.Destination)))}
            foreach ($item in $Items) {[void]$parents.Add([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($item.Staged)))}
            foreach ($parent in $parents) {
                # Missing retired outputs have no directory to change. Pin the nearest
                # existing ancestor so it cannot be redirected during the transaction.
                $parentAnchor=$parent
                while (-not (Test-Path -LiteralPath $parentAnchor)) {$parentAnchor=[IO.Path]::GetDirectoryName($parentAnchor)}
                $directoryLocks.Add((Open-SourcePolicyDirectoryLease $parentAnchor))
            }
            # Validate every existing path before moving anything.
            foreach ($item in $targets) {
                if (Test-Path -LiteralPath $item.Destination) {
                    if (-not $Overwrite) { throw 'An output appeared during processing. Original kept; rerun to choose overwrite.' }
                    $old = Get-Item -LiteralPath $item.Destination -Force
                    if ([bool]$old.PSIsContainer -ne [bool]$item.Folder) { throw "Output has the wrong type: $($item.Destination)" }
                    if ($old.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Output is a link: $($item.Destination)" }
                    $replaceTargets.Add($item)
                }
            }
            # Only retire paths that were present and validated above. A newly
            # appearing retired output belongs to someone else until checked.
            foreach ($item in $replaceTargets) {
                if (Test-Path -LiteralPath $item.Destination) {
                    # Keep the temporary name short enough for valid deep output paths.
                    $backup = Join-Path ([IO.Path]::GetDirectoryName($item.Destination)) ('.m3u_' + [Guid]::NewGuid().ToString('N').Substring(0,12) + '.backup')
                    Move-OutputPath $item.Destination $backup ([bool]$item.Folder)
                    $captured=[pscustomobject]@{ Path = $item.Destination; Backup = $backup; Folder = [bool]$item.Folder; Guard=$null }
                    $backups.Add($captured)
                    if($ValidateBackup){$captured.Guard=& $ValidateBackup $captured.Path $captured.Backup $captured.Folder;if($null -eq $captured.Guard){throw 'Previous output verification did not return a guard.'}}
                    Write-Log ('BACKUP: {0} -> {1}' -f $item.Destination, $backup)
                }
            }
            foreach ($item in $Items) {
                Move-OutputPath $item.Staged $item.Destination ([bool]$item.Folder)
                $installed.Add($item)
                if ($item.Folder) { Assert-FolderManifest $item.Destination $item.Manifest }
                if (-not $item.Folder) {
                    $lock = [IO.File]::Open($item.Destination, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                    $locks.Add($lock)
                    $hash=Get-StreamHash $lock ([IO.Path]::GetFileName($item.Destination))
                    if ($hash -ne $item.Hash) { throw "Installed file did not match verified output: $($item.Destination)" }
                }
            }
        } catch {
            $message = $_.Exception.Message
            foreach ($lock in $locks) { $lock.Dispose() }
            $locks.Clear()
            foreach($backup in $backups){if($backup.Guard){$backup.Guard.Dispose();$backup.Guard=$null}}
            for ($i = $installed.Count - 1; $i -ge 0; $i--) {
                $item = $installed[$i]
                # A failed verification may mean another program replaced the
                # installed path. Retain anything moved back; cleanup must not
                # delete unverified data merely because it now has a temp name.
                $item | Add-Member -NotePropertyName PreserveStaging -NotePropertyValue $true -Force
                try {
                    Move-OutputPath $item.Destination $item.Staged ([bool]$item.Folder)
                    $message += " New output moved back to: $($item.Staged)."
                }
                catch { $message += " Could not move back new output: $($item.Destination)." }
            }
            for ($i = $backups.Count - 1; $i -ge 0; $i--) {
                $item = $backups[$i]
                try { Move-OutputPath $item.Backup $item.Path ([bool]$item.Folder) }
                catch { $message += " Could not restore previous output from: $($item.Backup)." }
            }
            throw $message
        }
        foreach ($item in $backups) {
            try {if($item.Guard){$item.Guard.Remove()}else{Remove-SourcePolicyOwnedPath $item.Backup ([IO.Path]::GetDirectoryName($item.Backup))}}
            catch {
                Write-Log ('Previous output backup could not be removed: ' + $item.Backup)
                Write-Notice 'WARNING' ('Could not remove previous output backup: ' + $item.Backup)
            }
        }
        return [pscustomobject]@{ Locks = $locks; Replaced = ($backups.Count -gt 0) }
    } finally {foreach($backup in $backups){if($backup.Guard){$backup.Guard.Dispose()}};foreach ($directoryLock in $directoryLocks) {$directoryLock.Dispose()}}
}



function Write-Log([string]$Message) {
    $Message=ConvertTo-SafeExternalText $Message
    if ($script:Log) {
        try { $script:Log.WriteLine(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message)) }
        catch {
            $script:ReportProblem=$true
            try {$script:Log.Dispose()} catch {}; $script:Log=$null
            Write-Notice 'WARNING' 'Could not write the temporary log. Processing will continue; review the final results.'
        }
    }
}
function Assert-RelativeName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.StartsWith('/') -or $Name.Contains('\')) { throw "Unsupported relative path: $Name" }
    foreach ($part in $Name.Split('/')) {
        if ($part -eq '' -or $part -eq '.' -or $part -eq '..' -or $part -match '[<>:"|?*\x00-\x1f]' -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw "Unsafe or Windows-incompatible path: $Name"
        }
    }
}
function Assert-PlaylistName([string]$Name) {
    Assert-RelativeName $Name
    if ($Name.Contains('#') -or $Name.Contains('|') -or $Name.Contains(';')) { throw "Playlist name contains #, | or semicolon: $Name. Rename the file or ZIP member." }
}
function Get-SourceFiles([string]$Directory) {
    $pending=New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Directory); [long]$found=0
    while ($pending.Count -gt 0) {
        $dir=$pending.Pop()
        Show-PreparationProgress 'Scanning SRC' $dir $found -1 'files'
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force | Sort-Object Name)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Write-Event 'WARNING' ('IGNORED LINK: '+$item.FullName)
                continue
            }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            else { $found++; Show-PreparationProgress 'Scanning SRC' $item.Name $found -1 'files'; $item }
        }
    }
}
function Get-StreamHash([IO.Stream]$Stream,[string]$Name='Disk data') {
    $sha=[Security.Cryptography.SHA256]::Create()
    $buffer=New-Object byte[] 1048576
    [long]$total=0; [long]$length=$Stream.Length-$Stream.Position
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Show-Stage 'Verifying SHA-256' $Name 0
    try {
        while (($n=$Stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock($buffer,0,$n,$buffer,0); $total+=$n
            if ($watch.ElapsedMilliseconds -ge 125) {
                Show-Stage 'Verifying SHA-256' ('{0} | {1:N1}/{2:N1} MiB' -f $Name,($total/1MB),($length/1MB)) (100*$total/[Math]::Max(1,$length))
                $watch.Restart()
            }
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0)
        if ($total -ne $length) {throw "Hash read was incomplete: $Name"}
        Show-Stage 'Verifying SHA-256' $Name 100
        return [BitConverter]::ToString($sha.Hash).Replace('-','')
    }
    finally { $sha.Dispose() }
}
function Get-VerifiedHash([string]$LiteralPath) {
    $stream=[IO.File]::Open($LiteralPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $label=[IO.Path]::GetFileName($LiteralPath)
    if ($label.StartsWith('.m3u_')) {$label='New output for '+$script:UiGame}
    try {return [pscustomobject]@{Hash=(Get-StreamHash $stream $label)}}
    finally {$stream.Dispose()}
}
function Copy-Stream([IO.Stream]$InputStream,[IO.Stream]$OutputStream,[long]$Length,[string]$Name) {
    $buffer=New-Object byte[] 1048576
    $sha=[Security.Cryptography.SHA256]::Create()
    [long]$total=0; $watch=[Diagnostics.Stopwatch]::StartNew()
    $action='Copying disk data'; if ($OutputStream -eq [IO.Stream]::Null) {$action='Reading archive contents'}
    Write-Event 'FILE' ('{0} / {1:N2} MiB / {2}' -f $Name,($Length/1MB),$action)
    Show-Stage $action $Name 0
    try {
        while (($n=$InputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
            if ($n -gt $Length-$total) {throw "Stream exceeds its declared size: $Name"}
            $OutputStream.Write($buffer,0,$n)
            [void]$sha.TransformBlock($buffer,0,$n,$buffer,0)
            $total+=$n
            if ($watch.ElapsedMilliseconds -ge 125) {
                Show-Stage $action ('{0} | {1:N1}/{2:N1} MiB' -f $Name,($total/1MB),($Length/1MB)) (100*$total/[Math]::Max(1,$Length))
                $watch.Restart()
            }
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0)
        if ($total -ne $Length) { throw "Incomplete stream: $Name" }
        Show-Stage $action $Name 100
        return [BitConverter]::ToString($sha.Hash).Replace('-','')
    } finally { $sha.Dispose() }
}
function Copy-FileVerified([string]$Source,[string]$Destination,[string]$Name) {
    $inputStream=$null; $outputStream=$null
    try {
        $inputStream=[IO.File]::Open($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if ($inputStream.Length -eq 0) { throw "Empty file: $Name" }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))
        $outputStream=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $hash=Copy-Stream $inputStream $outputStream $inputStream.Length $Name
        $outputStream.Dispose(); $outputStream=$null
        if ((Get-VerifiedHash -LiteralPath $Destination).Hash -ne $hash) { throw "Copied file does not match source: $Name" }
        $inputStream.Position=0
        if ((Get-StreamHash $inputStream) -ne $hash) { throw "Source changed during copying: $Name" }
        Write-Event 'CHECK' ($Name+' / copy and source hashes match')
        return [pscustomobject]@{Hash=$hash; Length=$inputStream.Length}
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
    }
}
function Get-ZipDisks([IO.Compression.ZipArchive]$Archive,[string]$ZipPath) {
    $seen=New-Object 'System.Collections.Generic.Dictionary[string,bool]' ([StringComparer]::OrdinalIgnoreCase)
    $disks=New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $Archive.Entries) {
        $directory=$entry.FullName.EndsWith('/')
        if ($directory -and $entry.Length -ne 0) {throw 'A ZIP directory entry contains data. Archive is malformed; source kept.'}
        $name=$entry.FullName.TrimEnd('/')
        Assert-RelativeName $name
        if ($seen.ContainsKey($name)) { throw "Duplicate ZIP path (including letter case): $name" }
        $seen.Add($name,$directory)
        if (-not $directory -and [IO.Path]::GetExtension($name) -in $script:DiskExtensions) {
            Assert-PlaylistName $name
            if ($entry.Length -eq 0) { throw "Empty media file: $name" }
            $disks.Add($name)
        }
    }
    foreach ($name in @($seen.Keys)) {
        $parts=$name.Split('/')
        for ($i=1; $i -lt $parts.Length; $i++) {
            $parent=($parts[0..($i-1)] -join '/')
            if ($seen.ContainsKey($parent) -and -not $seen[$parent]) { throw "ZIP path is both a file and a folder: $parent" }
        }
    }
    $tracks=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($disks | Where-Object {[IO.Path]::GetExtension($_) -eq '.cue'})) {
        $entry=$Archive.GetEntry($name)
        $text=Read-SandboxedZipText $ZipPath $Archive $entry 1MB
        $lines=[regex]::Split($text,'\r\n|\r|\n')
        $parent=([string][IO.Path]::GetDirectoryName($name)).Replace('\','/')
        foreach ($track in @(Get-CueReferences @($lines) $name)) {
            $relative=$track; if ($parent) {$relative=$parent+'/'+$track}
            $trackEntry=$Archive.GetEntry($relative)
            if ($null -eq $trackEntry -or $trackEntry.FullName.EndsWith('/')) {throw ('Missing CUE track or spelling/case mismatch: '+$relative)}
            [void]$tracks.Add($relative)
        }
    }
    $disks=@($disks | Where-Object {-not $tracks.Contains($_)})
    $stems=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($disk in $disks) {
        if (-not $stems.Add([IO.Path]::ChangeExtension($disk,$null))) {throw "Multiple formats of the same game file in one ZIP: $disk. Keep one playable version."}
    }
    return @($disks | Sort-Object @{Expression={Get-NaturalDiskKey $_}}, @{Expression={$_}})
}
function Assert-ZipExtractionNames([IO.Compression.ZipArchive]$Archive) {
    # Windows merges directory spellings such as Disks/ and disks/. A playlist
    # retaining both spellings would then fail on the case-sensitive handheld.
    # Include implicit parents, not just explicit ZIP directory entries.
    $directories=New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $Archive.Entries) {
        $parts=$entry.FullName.TrimEnd('/').Split('/')
        $count=$parts.Length-1
        if ($entry.FullName.EndsWith('/')) {$count=$parts.Length}
        for ($i=1; $i -le $count; $i++) {
            $name=$parts[0..($i-1)] -join '/'
            if ($directories.ContainsKey($name)) {
                if (-not $directories[$name].Equals($name,[StringComparison]::Ordinal)) {
                    throw "ZIP folders differ only by letter case: $($directories[$name]) / $name. Use identical folder spelling before extracting on Windows. Original kept."
                }
            } else {$directories.Add($name,$name)}
        }
    }
}
function Read-ZipContents([IO.Compression.ZipArchive]$Archive,[string]$Destination,[string]$ZipPath) {
    if($Destination) {Assert-ZipExtractionNames $Archive}
    Show-Stage 'Checking ZIP contents in sandbox' ([IO.Path]::GetFileName($ZipPath))
    $operation='Hash';if($Destination){$operation='Extract'}
    $manifest=Invoke-ArchiveSandbox -ZipPath $ZipPath -Archive $Archive -Profile Media -Operation $operation -Destination $Destination -Progress {param($index,$count,$done,$length) Show-Stage 'Checking ZIP contents in sandbox' ('Entry {0}/{1}' -f ($index+1),$count) (100*$done/[Math]::Max(1,$length))}
    Show-Stage 'Checking ZIP contents' 'Sandbox verification complete'
    return $manifest
}

function Assert-FolderManifest([string]$Directory,[hashtable]$Manifest) {
    $files=@(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force)
    if ($files.Count -ne $Manifest.Count) { throw 'Output folder file count does not match source.' }
    foreach ($name in $Manifest.Keys) {
        $path=Join-Path $Directory $name.Replace('/',[IO.Path]::DirectorySeparatorChar)
        $item=Get-Item -LiteralPath $path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $item.Length -ne $Manifest[$name].Length -or (Get-VerifiedHash -LiteralPath $path).Hash -ne $Manifest[$name].Hash) {
            throw "Output folder content mismatch: $name"
        }
    }
}
function Get-PlaylistLines([string[]]$DiskNames,[string]$RelativeStem,[bool]$ZipMode,[bool]$LooseFiles=$false) {
    Assert-PlaylistName $RelativeStem
    $parent=([string][IO.Path]::GetDirectoryName($RelativeStem.Replace('/',[IO.Path]::DirectorySeparatorChar))).Replace('\','/')
    $depth=0; if ($parent) {$depth=@($parent -split '/').Count}
    $media=('../'*$depth)+'.hidden/'+$RelativeStem
    if ($LooseFiles) {$media=('../'*$depth)+'.hidden/';if($parent){$media+=$parent+'/'}}
    elseif ($ZipMode) {$media+='.zip#'} else {$media+='/'}
    foreach ($name in $DiskNames) {
        Assert-PlaylistName $name
        $line=$media+$name
        if ([Text.Encoding]::UTF8.GetByteCount($line) -gt 1000) {throw "Playlist path is too long: $name"}
        $line
    }
}
function New-Playlist([string[]]$DiskNames,[string]$RelativeStem,[string]$Destination,[bool]$ZipMode,[bool]$LooseFiles=$false,[string[]]$OutputLines=$null) {
    $lines=@($OutputLines)
    if ($null -eq $OutputLines) {$lines=@(Get-PlaylistLines $DiskNames $RelativeStem $ZipMode $LooseFiles)}
    if ($lines.Count -lt 2) {throw 'A playlist requires at least two playable media files.'}
    if ($lines.Count -ne $DiskNames.Count) {throw 'Playlist paths do not match the planned media count.'}
    [IO.File]::WriteAllText($Destination,(($lines -join "`n")+"`n"),(New-Object Text.UTF8Encoding($false)))
    Write-Log ('PLAYLIST ORDER: '+($DiskNames -join ' -> '))
    Write-Event 'ORDER' ('{0} media file(s) in this playlist:' -f $DiskNames.Count)
    for ($i=0;$i -lt $DiskNames.Count;$i++) {Write-Event ('MEDIA '+($i+1)) $DiskNames[$i]}
}

function Get-TapeGrouping([string]$Title) {
    $pattern='(?i)\s*[\(\[]\s*(?:(?:tape|cassette)\s*(?<tape>\d+[a-z]?|[a-z])(?:\s*(?:of|/)\s*\d+)?(?:\s+side\s*(?<side>\d+|[a-z]))?|side\s*(?<side>\d+|[a-z]))\s*[\)\]]'
    $found=[regex]::Matches($Title,$pattern)
    $tapes=@($found | Where-Object {$_.Groups['tape'].Success})
    $sides=@($found | Where-Object {$_.Groups['side'].Success})
    if ($found.Count -eq 0) {return $null}
    $errorText=$null
    if ($tapes.Count -gt 1 -or $sides.Count -gt 1) {$errorText='Ambiguous tape/side tags. Keep one release per set or put it in a game ZIP.'}
    $tag=''; if ($tapes.Count) {$tag=$tapes[0].Groups['tape'].Value}
    if ($sides.Count) {$tag+='.'+$sides[0].Groups['side'].Value}
    $name=[regex]::Replace([regex]::Replace($Title,$pattern,''),'\s{2,}',' ').Trim()
    [pscustomobject]@{Title=$name; Tag=$tag; Error=$errorText}
}

function Get-TapeSupportIssue([string[]]$Names,$Support) {
    $tapes=@($Names | Where-Object {[IO.Path]::GetExtension($_) -in '.tap','.t64'})
    if ($tapes.Count -eq 0) {return $null}
    if ($null -eq $Support -or -not $Support.CanBuild) {
        if ($null -eq $Support) {return 'Tape swapping UNVERIFIED for this system.'}
        return ('Tape swapping '+$Support.Status+': '+$Support.Reason)
    }
    foreach ($name in $tapes) {
        if ([IO.Path]::GetExtension($name) -notin $Support.Extensions) {
            return ('Tape swapping UNSUPPORTED for '+[IO.Path]::GetExtension($name)+' in the selected build.')
        }
    }
    return $null
}

function Get-Jobs([string]$SourceRoot, $Profile) {
    $prefix=$SourceRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $files=@(Get-SourceFiles $SourceRoot)
    Show-PreparationProgress 'Scanning SRC' 'Source file list collected.' $files.Count $files.Count 'files' -Force
    $zipFiles=@($files | Where-Object {$_.Extension -eq '.zip'} | Sort-Object FullName); $queued=0
    Show-PreparationProgress 'Grouping ZIP inputs' 'Each archive forms one input set.' 0 $zipFiles.Count 'ZIPs'
    foreach ($file in $zipFiles) {
        Show-PreparationProgress 'Grouping ZIP inputs' $file.Name $queued $zipFiles.Count 'ZIPs'
        $relative=$file.FullName.Substring($prefix.Length).Replace('\','/')
        [pscustomobject]@{System=$Profile.Folder; Source=$relative; Stem=$relative.Substring(0,$relative.Length-4); Zip=$file.FullName; Disks=@(); Error=$null}
        $queued++; Show-PreparationProgress 'Grouping ZIP inputs' $file.Name $queued $zipFiles.Count 'ZIPs'
    }
    $cueTracks=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ('.cue' -in $Profile.Extensions) {
        $cues=@($files | Where-Object {$_.Extension -eq '.cue'}); $checkedCues=0
        Show-PreparationProgress 'Reading CUE references' 'Finding companion tracks.' 0 $cues.Count 'CUEs'
        foreach ($cue in $cues) {
            Show-PreparationProgress 'Reading CUE references' $cue.Name $checkedCues $cues.Count 'CUEs'
            try {
                foreach ($track in @(Get-CueFiles $cue.FullName)) {
                    [void]$cueTracks.Add([IO.Path]::GetFullPath((Join-Path $cue.DirectoryName $track)))
                }
            } catch {Write-Log ('CUE will be checked while processing: '+$cue.FullName)}
            $checkedCues++; Show-PreparationProgress 'Reading CUE references' $cue.Name $checkedCues $cues.Count 'CUEs'
        }
    }
    $groups=@{}
    $looseFiles=@($files | Where-Object {$_.Extension -in $Profile.Extensions -and -not $cueTracks.Contains($_.FullName)} | Sort-Object FullName); $grouped=0
    Show-PreparationProgress 'Grouping loose media' 'Matching disk and tape labels.' 0 $looseFiles.Count 'files'
    foreach ($file in $looseFiles) {
        $relative=$file.FullName.Substring($prefix.Length).Replace('\','/')
        $parent=([string][IO.Path]::GetDirectoryName($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))).Replace('\','/')
        $title=$file.BaseName; $tag=''; $tagged=$false; $usedFolderTitle=$false
        $tapeGrouping=$null
        if ($file.Extension -in '.tap','.t64') {$tapeGrouping=Get-TapeGrouping $title}
        $pattern='(?i)\s*[\(\[]\s*(?:disc|disk|side)\s*(\d+[a-z]?|[a-z])(?:\s*(?:of|/)\s*\d+)?\s*[\)\]]'
        $found=[regex]::Matches($title,$pattern)
        if ($null -ne $tapeGrouping) {
            $tag=$tapeGrouping.Tag; $tagged=$true; $title=$tapeGrouping.Title
        } elseif ($found.Count -eq 1) {
            $tag=$found[0].Groups[1].Value.ToLowerInvariant(); $tagged=$true
            $title=[regex]::Replace($title,$pattern,'').Trim()
            $title=[regex]::Replace($title,'\s{2,}',' ')
        } elseif ($parent -and $title -match '^(?i:disc|disk|side)\s*(\d+[a-z]?|[a-z])$') {
            $tag=$Matches[1].ToLowerInvariant(); $tagged=$true
            $title=[IO.Path]::GetFileName($parent);$usedFolderTitle=$true
            $parent=([string][IO.Path]::GetDirectoryName($parent)).Replace('\','/')
        }
        if(-not $usedFolderTitle -and $parent -and [IO.Path]::GetFileName($parent).Equals($title,[StringComparison]::OrdinalIgnoreCase)){
            $title=[IO.Path]::GetFileName($parent)
            $parent=([string][IO.Path]::GetDirectoryName($parent)).Replace('\','/')
        }
        $stem=$title; if ($parent) {$stem=$parent+'/'+$title}
        if (-not $groups.ContainsKey($stem)) {
            $groups[$stem]=[pscustomobject]@{System=$Profile.Folder; Source=$stem; Stem=$stem; Zip=$null; Disks=(New-Object 'System.Collections.Generic.List[object]'); Error=$null}
        }
        $group=$groups[$stem]
        $group.Disks.Add([pscustomobject]@{Path=$file.FullName; Name=($file.BaseName+$file.Extension.ToLowerInvariant()); Tag=$tag; Tagged=$tagged})
        if ($null -ne $tapeGrouping) {if ($tapeGrouping.Error) {$group.Error=$tapeGrouping.Error}}
        elseif ($found.Count -gt 1) {$group.Error='Multiple disk tags in a loose filename. Put the complete game in one ZIP to specify its grouping.'}
        $grouped++; Show-PreparationProgress 'Grouping loose media' $file.Name $grouped $looseFiles.Count 'files'
    }
    $orderedGroups=@($groups.Values | Sort-Object Stem); $ordered=0
    Show-PreparationProgress 'Ordering game files' 'Checking file labels and playback order.' 0 $orderedGroups.Count 'sets'
    foreach ($group in $orderedGroups) {
        $tags=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        if ($group.Disks.Count -gt 1) {
            foreach ($disk in $group.Disks) {
                if (-not $disk.Tagged -or -not $tags.Add((Get-NaturalDiskKey $disk.Tag))) {$group.Error='Ambiguous set: repeated disk number or mixed numbered/unnumbered files. Separate alternate releases.'}
            }
        }
        $group.Disks=@($group.Disks | Sort-Object @{Expression={Get-NaturalDiskKey $_.Tag}},@{Expression={Get-NaturalDiskKey $_.Name}})
        $group
        $ordered++; Show-PreparationProgress 'Ordering game files' $group.Stem $ordered $orderedGroups.Count 'sets'
    }
}

function Assert-GameStem([string]$Stem) {
    Assert-PlaylistName $Stem
    foreach ($part in $Stem.Split('/')) {
        if ($part.StartsWith('.')) {throw 'A game or collection name starts with a dot and would be hidden. Rename that input folder/file.'}
    }
}

function Add-CopiedFile([string]$Source,[string]$Name,[string]$Directory,[hashtable]$Manifest,[hashtable]$SourceHashes=@{}) {
    Assert-RelativeName $Name
    $sourceItem=Get-Item -LiteralPath $Source -Force
    if ($sourceItem.PSIsContainer -or ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw "Missing regular source file: $Source"}
    Assert-PlainOutputParents $Source ([IO.Path]::GetPathRoot($Source))
    if ($Manifest.ContainsKey($Name)) {
        if ((Get-VerifiedHash -LiteralPath $Source).Hash -ne $Manifest[$Name].Hash) {throw "Two source files collide: $Name"}
    } else {
        $Manifest[$Name]=Copy-FileVerified $Source (Join-Path $Directory $Name.Replace('/',[IO.Path]::DirectorySeparatorChar)) $Name
    }
    $SourceHashes[[IO.Path]::GetFullPath($Source)]=$Manifest[$Name].Hash
}

function Get-SbiCompanions([string]$DiskPath) {
    # Ask the filesystem for this disc's sidecar rather than materializing every
    # sibling for every disc. -Filter uses filesystem wildcards (brackets are
    # literal); the exact check also rejects any legacy short-name matches.
    # Query afresh at each planning/copy boundary so changes are still detected.
    $parent=[IO.Path]::GetDirectoryName($DiskPath)
    $stem=[IO.Path]::GetFileNameWithoutExtension($DiskPath)
    foreach ($item in @(Get-ChildItem -LiteralPath $parent -File -Force -Filter ($stem+'.sbi'))) {
        if ($item.Extension -eq '.sbi' -and $item.BaseName -eq $stem) {$item}
    }
}

function Get-CueReferences([string[]]$Lines,[string]$CuePath) {
    if ($Lines.Count -gt 16384) {throw "CUE has more than 16,384 lines: $CuePath"}
    $found=New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $Lines) {
        if ($line.Length -gt 8192) {throw "CUE line exceeds 8,192 characters: $CuePath"}
        if ($line -match '^\s*FILE\s+(?:"([^"]+)"|(\S+))\s+\S+\s*$') {
            $name=$Matches[1]; if (-not $name) {$name=$Matches[2]}
            # Paths are copied unchanged. Backslashes and parent traversal are
            # rejected because the target is a Linux handheld.
            Assert-RelativeName $name
            if ($found.Count -ge 1024) {throw "CUE has more than 1,024 FILE references: $CuePath"}
            $found.Add($name)
        } elseif ($line -match '^\s*FILE\b') {throw "Unrecognized CUE FILE line in $CuePath"}
    }
    if ($found.Count -eq 0) {throw "CUE contains no FILE entries: $CuePath"}
    return @($found)
}

function Get-CueFiles([string]$CuePath) {
    $text=Read-OptiTextFile $CuePath 1MB ('CUE '+$CuePath)
    return @(Get-CueReferences ([regex]::Split($text,'\r\n|\r|\n')) $CuePath)
}

function Assert-GameOutputFolder([string]$Directory,[string[]]$ExpectedNames) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {return}
    $prefix=$Directory.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $allowedFiles=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $allowedFolders=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($name in $ExpectedNames){
        [void]$allowedFiles.Add($name)
        $parts=$name.Split('/')
        for($i=1;$i -lt $parts.Length;$i++){[void]$allowedFolders.Add(($parts[0..($i-1)] -join '/'))}
    }
    $pending=New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Directory)
    while ($pending.Count -gt 0) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Existing game output contains a link; output left alone.'}
            $relative=$entry.FullName.Substring($prefix.Length).Replace('\','/')
            if ($entry.PSIsContainer) {
                if(-not $allowedFolders.Contains($relative)){throw 'Existing game output contains an unowned folder; output left alone.'}
                $pending.Push($entry.FullName);continue
            }
            if ($entry.Extension -in '.m3u','.m3u8' -or
                -not $allowedFiles.Contains($relative)) {
                throw 'Existing output may contain another game or collection. Use an empty DST or rename the conflicting game; output left alone.'
            }
        }
    }
}

function Read-PlaylistLines([string]$Path) {
    $text=Read-OptiTextFile $Path 1MB 'Existing playlist'
    $lines=[regex]::Split($text,'\r\n|\r|\n')
    if ($lines.Count -gt 16384) {throw 'Existing playlist exceeds the supported line count; output left alone.'}
    foreach ($line in $lines) {
        if ($line.Length -gt 8192) {throw 'Existing playlist contains an overlong line; output left alone.'}
    }
    return ,$lines
}

function Assert-OwnedPlaylist([string]$Path,[string]$Stem,[string[]]$Lines=$null,[string[]]$FlatLines=@()) {
    # Only retire a playlist generated for this exact game's hidden media.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {return}
    $depth=@($Stem.Split('/')).Count-1
    $prefix=('../'*$depth)+'.hidden/'+$Stem
    $count=0
    $flatSet=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($flatLine in $FlatLines){[void]$flatSet.Add($flatLine)}
    if ($null -eq $Lines) {$Lines=Read-PlaylistLines $Path}
    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {continue}
        if ($line.StartsWith($prefix+'/',[StringComparison]::Ordinal)) {$member=$line.Substring($prefix.Length+1)}
        elseif ($line.StartsWith($prefix+'.zip#',[StringComparison]::Ordinal)) {$member=$line.Substring($prefix.Length+5)}
        elseif ($flatSet.Contains($line)) {$count++;continue}
        else {throw 'Existing playlist does not point exclusively to this game. Output left alone; use an empty DST.'}
        Assert-RelativeName $member
        $count++
    }
    if ($count -eq 0) {throw 'Existing playlist is empty; output left alone.'}
}

function Get-GameMediaNames($Job,[ValidateSet('Auto','Zip','Loose','Folders')][string]$Storage='Zip',[ValidateSet('Auto','Zip','Loose','Folders')][string]$SingleStorage='Auto') {
    $diskNames=@(); $contentNames=@()
    if ($Job.Zip) {
        $archive=Open-ArchiveWithBudget -Path $Job.Zip -Profile Media
        try {
            $diskNames=@(Get-ZipDisks $archive $job.Zip)
            $effectiveStorage=if ($diskNames.Count -gt 1) {$Storage} else {$SingleStorage}
            if ($effectiveStorage -in 'Loose','Folders') {Assert-ZipExtractionNames $archive}
            $contentNames=@($archive.Entries | Where-Object {-not $_.FullName.EndsWith('/')} | ForEach-Object {$_.FullName})
        } finally {$archive.Dispose()}
    } else {
        $diskNames=@($Job.Disks | ForEach-Object {$_.Name})
        $contentNames=@($diskNames)
        foreach ($disk in $Job.Disks) {
            if ([IO.Path]::GetExtension($disk.Name) -eq '.cue') {$contentNames+=@(Get-CueFiles $disk.Path)}
            $contentNames+=@(Get-SbiCompanions $disk.Path | ForEach-Object {$_.Name})
        }
    }
    return [pscustomobject]@{DiskNames=$diskNames;ContentNames=$contentNames}
}

function Get-PreservedMediaWrites($Job,$Media,[string]$SourceRoot,[string]$DestinationRoot) {
    $sourcePrefix=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $sources=@{}
    foreach ($disk in $Job.Disks) {
        $members=@([pscustomobject]@{Name=$disk.Name;Path=$disk.Path})
        $parent=[IO.Path]::GetDirectoryName($disk.Path)
        if ([IO.Path]::GetExtension($disk.Name) -eq '.cue') {
            foreach ($name in @(Get-CueFiles $disk.Path)) {
                $members+=[pscustomobject]@{Name=$name;Path=(Join-Path $parent $name.Replace('/',[IO.Path]::DirectorySeparatorChar))}
            }
        }
        foreach ($sbi in @(Get-SbiCompanions $disk.Path)) {$members+=[pscustomobject]@{Name=$sbi.Name;Path=$sbi.FullName}}
        foreach ($member in $members) {
            $sourcePath=[IO.Path]::GetFullPath($member.Path)
            if (-not $sourcePath.StartsWith($sourcePrefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'Auto source file is outside SRC.'}
            if ($sources.ContainsKey($member.Name) -and -not $sources[$member.Name].Equals($sourcePath,[StringComparison]::OrdinalIgnoreCase)) {
                throw ('Auto cannot preserve different source paths with the same media name: '+$member.Name+'. Put each complete game in one folder or ZIP.')
            }
            $sources[$member.Name]=$sourcePath
        }
    }
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Media.ContentNames) {
        if (-not $seen.Add($name)) {continue}
        if (-not $sources.ContainsKey($name)) {throw 'An Auto output has no matching source file.'}
        $relative='.hidden/'+$sources[$name].Substring($sourcePrefix.Length).Replace('\','/')
        Assert-RelativeName $relative
        [pscustomobject]@{Destination=(Join-Path $DestinationRoot $relative.Replace('/',[IO.Path]::DirectorySeparatorChar));Folder=$false;Role='Data';MemberName=$name}
    }
}

function Get-PreservedPlaylistLines([string[]]$DiskNames,[string]$Stem,[string]$Root,[object[]]$Writes,[string]$ZipPath='') {
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $depth=@($Stem.Split('/')).Count-1
    $paths=@{};foreach ($write in $Writes) {if ($write.MemberName) {$paths[$write.MemberName]=$write.Destination}}
    foreach ($name in $DiskNames) {
        Assert-PlaylistName $name
        $path=$ZipPath
        if (-not $path) {
            if (-not $paths.ContainsKey($name)) {throw 'A playlist image has no preserved output path.'}
            $path=$paths[$name]
        }
        $full=[IO.Path]::GetFullPath($path)
        if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'Preserved playlist media is outside DST.'}
        $relative=$full.Substring($prefix.Length).Replace('\','/')
        Assert-PlaylistName $relative
        $line=('../'*$depth)+$relative
        if ($ZipPath) {$line+='#'+$name}
        if ([Text.Encoding]::UTF8.GetByteCount($line) -gt 1000) {throw "Playlist path is too long: $name"}
        $line
    }
}

function Set-PlaylistOutputConflicts([object[]]$Jobs) {
    # Index each actual write/retirement once. Case-insensitive equality and
    # ancestor lookups preserve the pairwise overlap rules without O(n^2) scans.
    $owners=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    Show-PreparationProgress 'Indexing output paths' 'Collecting installation and retirement paths.' 0 $Jobs.Count 'sets'
    for ($i=0;$i -lt $Jobs.Count;$i++) {
        if ($Jobs[$i].OutputPlan) {
            $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($target in (@($Jobs[$i].OutputPlan.Writes)+@($Jobs[$i].OutputPlan.Retired))) {
                $key=[IO.Path]::GetFullPath($target.Destination).TrimEnd('\','/')
                if (-not $seen.Add($key)) {continue}
                if (-not $owners.ContainsKey($key)) {$owners[$key]=New-Object 'System.Collections.Generic.List[int]'}
                $owners[$key].Add($i)
            }
        }
        Show-PreparationProgress 'Indexing output paths' $Jobs[$i].Stem ($i+1) $Jobs.Count 'sets'
    }
    $keys=@($owners.Keys); $checked=0
    $message='Several input games write or retire overlapping output paths. Separate or rename the inputs; no conflicting game was written.'
    Show-PreparationProgress 'Checking output path conflicts' 'Checking shared paths and parent collections.' 0 $keys.Count 'paths'
    foreach ($key in $keys) {
        $participants=$owners[$key]
        if ($participants.Count -gt 1) {foreach ($i in $participants) {$Jobs[$i].Error=$message}}
        $parent=[IO.Path]::GetDirectoryName($key)
        while ($parent) {
            if ($owners.ContainsKey($parent)) {
                $ancestors=$owners[$parent]
                if ($participants.Count -gt 1 -or $ancestors.Count -gt 1 -or $participants[0] -ne $ancestors[0]) {
                    foreach ($i in $participants) {$Jobs[$i].Error=$message}
                    foreach ($i in $ancestors) {$Jobs[$i].Error=$message}
                }
            }
            $parent=[IO.Path]::GetDirectoryName($parent)
        }
        $checked++; Show-PreparationProgress 'Checking output path conflicts' $key $checked $keys.Count 'paths'
    }
}

function Get-PlaylistOutputPlan($Job,[string]$SourceRoot,[string]$DestinationRoot,[string]$Storage,$Media,[string]$SingleStorage='Auto') {
    if ($Storage -notin 'Auto','Zip','Loose','Folders' -or $SingleStorage -notin 'Auto','Zip','Loose','Folders') {throw 'Unknown output storage choice.'}
    $profile=$Job.Profile
    $isMulti=$Media.DiskNames.Count -gt 1
    # Visible single games and hidden playlist media have independent layouts.
    if (-not $isMulti) {$Storage=$SingleStorage}
    $autoLayout=$Storage -eq 'Auto'
    if ($autoLayout) {$Storage=if ($Job.Zip) {'Zip'} else {'Loose'}}
    $zipMode=$Storage -eq 'Zip'
    $looseFiles=$Storage -eq 'Loose'
    $hasPlaylist=$isMulti
    $dataFolder=$Storage -eq 'Folders'
    $relativeData=$Job.Stem
    if ($hasPlaylist) {$relativeData='.hidden/'+$Job.Stem}
    if ($zipMode) {$relativeData+='.zip'}
    $sourcePrefix=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if ($Job.Zip -and $zipMode -and (-not $isMulti -or $autoLayout)) {
        $sourceZip=[IO.Path]::GetFullPath($Job.Zip)
        if (-not $sourceZip.StartsWith($sourcePrefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'Source ZIP is outside SRC.'}
        $relativeData=$sourceZip.Substring($sourcePrefix.Length).Replace('\','/')
        if ($isMulti) {$relativeData='.hidden/'+$relativeData}
    }
    $flatBase=([string][IO.Path]::GetDirectoryName($Job.Stem.Replace('/',[IO.Path]::DirectorySeparatorChar))).Replace('\','/')
    if ($flatBase) {$flatBase+='/'}
    $flatBase='.hidden/'+$flatBase
    $flatWrites=New-Object 'System.Collections.Generic.List[object]'
    $members=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Media.ContentNames) {
        Assert-RelativeName $name
        if (-not $members.Add($name)) {continue}
        $relative=$flatBase+$name
        Assert-RelativeName $relative
        $flatWrites.Add([pscustomobject]@{Destination=(Join-Path $DestinationRoot $relative.Replace('/',[IO.Path]::DirectorySeparatorChar));Folder=$false;Role='Data';MemberName=$name})
    }
    # Keep exact source-derived paths available when switching away from Auto.
    # They authorize only known media, never arbitrary old playlist references.
    $preservedWrites=@();$preservedZipPath='';$preservedLines=@()
    if ($Job.Zip) {
        $sourceZip=[IO.Path]::GetFullPath($Job.Zip)
        if (-not $sourceZip.StartsWith($sourcePrefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'Source ZIP is outside SRC.'}
        $preservedZipPath=Join-Path $DestinationRoot ('.hidden/'+$sourceZip.Substring($sourcePrefix.Length)).Replace('/',[IO.Path]::DirectorySeparatorChar)
    } else {
        try {$preservedWrites=@(Get-PreservedMediaWrites $Job $Media $SourceRoot $DestinationRoot)}
        catch {if ($autoLayout) {throw}}
    }
    if ($preservedZipPath -or $preservedWrites.Count) {
        try {$preservedLines=@(Get-PreservedPlaylistLines $Media.DiskNames $Job.Stem $DestinationRoot $preservedWrites $preservedZipPath)}
        catch {if ($isMulti -and $autoLayout) {throw}}
    }
    Assert-RelativeName $relativeData
    $dataPath=Join-Path $DestinationRoot $relativeData.Replace('/',[IO.Path]::DirectorySeparatorChar)
    $m3uPath=Join-Path $DestinationRoot ($Job.Stem+$profile.Playlist).Replace('/',[IO.Path]::DirectorySeparatorChar)
    if ($looseFiles) {
        if ($flatWrites.Count -eq 0) {throw 'No files were found for loose output.'}
        $dataWrites=@($flatWrites.ToArray())
        if ($autoLayout) {
            $dataWrites=@($preservedWrites)
            if (-not $isMulti) {
                $hiddenPrefix=(Join-Path $DestinationRoot '.hidden')+[IO.Path]::DirectorySeparatorChar
                $dataWrites=@(foreach ($write in $preservedWrites) {
                    $relative=$write.Destination.Substring($hiddenPrefix.Length)
                    [pscustomobject]@{Destination=(Join-Path $DestinationRoot $relative);Folder=$false;Role='Data';MemberName=$write.MemberName}
                })
            }
        } elseif (-not $isMulti) {
            # Visible loose files share the collection folder, not a new game folder.
            # Historical flat ownership remains in .hidden via FlatDataWrites.
            $visibleBase=$flatBase.Substring('.hidden/'.Length)
            $dataWrites=@(foreach ($write in $flatWrites) {
                $relative=$visibleBase+$write.MemberName
                [pscustomobject]@{Destination=(Join-Path $DestinationRoot $relative.Replace('/',[IO.Path]::DirectorySeparatorChar));Folder=$false;Role='Data';MemberName=$write.MemberName}
            })
        }
        $dataPath=$dataWrites[0].Destination
        $relativeData=$dataPath.Substring($DestinationRoot.TrimEnd('\','/').Length+1).Replace('\','/')
    } else {
        $dataWrites=@([pscustomobject]@{Destination=$dataPath;Folder=$dataFolder;Role='Data';MemberName=$null})
    }
    $dataTargets=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $dataParents=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($write in $dataWrites){
        [void]$dataTargets.Add($write.Destination)
        $parent=[IO.Path]::GetDirectoryName($write.Destination)
        while($parent -and $parent.Length -ge $DestinationRoot.TrimEnd('\','/').Length){
            if(-not $dataParents.Add($parent)){break}
            $parent=[IO.Path]::GetDirectoryName($parent)
        }
    }
    $retired=New-Object 'System.Collections.Generic.List[object]'
    if (-not $hasPlaylist) {$retired.Add([pscustomobject]@{Destination=$m3uPath;Folder=$false})}
    foreach ($suffix in '', '.zip') {
        $oldPath=Join-Path $DestinationRoot ('.hidden/'+$Job.Stem+$suffix).Replace('/',[IO.Path]::DirectorySeparatorChar)
        if (-not $dataTargets.Contains($oldPath) -and -not $dataParents.Contains($oldPath)) {$retired.Add([pscustomobject]@{Destination=$oldPath;Folder=($suffix -eq '')})}
    }
    $lines=@();$playlistText=$null
    if ($hasPlaylist) {
        if ($autoLayout) {$lines=@($preservedLines)}
        else {$lines=@(Get-PlaylistLines $Media.DiskNames $Job.Stem $zipMode $looseFiles)}
        $playlistText=($lines -join "`n")+"`n"
    }
    $flatLines=@(Get-PlaylistLines $Media.DiskNames $Job.Stem $false $true)
    $writes=@($dataWrites)
    if ($hasPlaylist) {$writes+=[pscustomobject]@{Destination=$m3uPath;Folder=$false;Role='Playlist';MemberName=$null}}
    $visible=New-Object 'System.Collections.Generic.List[object]'
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $relativeCandidates=@($Job.Stem,($Job.Stem+'.zip'))
    foreach ($ext in $profile.Extensions) {$relativeCandidates+=($Job.Stem+$ext)}
    if (-not $Job.Zip) {foreach ($disk in $Job.Disks) {$relativeCandidates+=$disk.Path.Substring($SourceRoot.TrimEnd('\','/').Length+1).Replace('\','/')}}
    foreach ($relative in $relativeCandidates) {
        $candidate=Join-Path $DestinationRoot $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
        if ($dataTargets.Contains($candidate) -or $dataParents.Contains($candidate)) {continue}
        if ($dataFolder -and $candidate.StartsWith($dataPath+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {continue}
        if ($seen.Add($candidate)) {$visible.Add([pscustomobject]@{Destination=$candidate;Folder=($relative -eq $Job.Stem)})}
    }
    $plan=[pscustomobject]@{DiskNames=$Media.DiskNames;ContentNames=$Media.ContentNames;IsMulti=$isMulti;ZipMode=$zipMode;
        Storage=$Storage;LooseFiles=$looseFiles;PreserveZip=($zipMode -and [bool]$Job.Zip);DataWrites=$dataWrites;
        HasPlaylist=$hasPlaylist;
        PlaylistLines=$lines;PlaylistText=$playlistText;FlatPlaylistLines=$flatLines;FlatDataWrites=@($flatWrites.ToArray());
        PreservedPlaylistLines=$preservedLines;PreservedDataWrites=$preservedWrites;PreservedZipPath=$preservedZipPath;
        DataFolder=$dataFolder;RelativeData=$relativeData;DataPath=$dataPath;M3uPath=$m3uPath;
        Stem=$Job.Stem;Root=$DestinationRoot;Writes=$writes;Retired=@();VisibleCandidates=$visible.ToArray()}
    # Only an owning playlist can authorize retirement of old loose media.
    # Unknown side files and outputs with changed names are left alone.
    $writeTargets=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($write in $writes) {[void]$writeTargets.Add($write.Destination)}
    if (Test-Path -LiteralPath $m3uPath -PathType Leaf) {
        $owned=@{}
        try {$owned=Get-PlaylistOwnedMedia $m3uPath $Job.Stem $DestinationRoot $plan} catch {
            # Ownership is checked after an overwrite choice. Skip never needs
            # to parse or validate an unrelated existing playlist.
        }
        $folderTargets=@(@($writes)+@($retired.ToArray()) | Where-Object {$_.Folder})
        $retiredTargets=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($old in $retired) {[void]$retiredTargets.Add($old.Destination)}
        foreach ($old in (@($flatWrites.ToArray())+@($preservedWrites))) {
            if ($writeTargets.Contains($old.Destination) -or $retiredTargets.Contains($old.Destination) -or -not $owned.ContainsKey($old.Destination)) {continue}
            $covered=$false
            foreach ($target in $folderTargets) {
                if ($old.Destination.StartsWith($target.Destination+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {$covered=$true;break}
            }
            if (-not $covered) {
                $retired.Add([pscustomobject]@{Destination=$old.Destination;Folder=$false})
                [void]$retiredTargets.Add($old.Destination)
            }
        }
    }
    $plan.Retired=@($retired.ToArray() | Where-Object {-not $writeTargets.Contains($_.Destination)})
    return $plan
}

function Get-PlaylistOwnedMedia([string]$Path,[string]$Stem,[string]$Root,$Plan=$null) {
    $owned=@{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {return $owned}
    $lines=Read-PlaylistLines $Path
    $depth=@($Stem.Split('/')).Count-1
    $prefix=('../'*$depth)+'.hidden/'+$Stem
    $references=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $knownFiles=@{}
    if ($Plan) {
        $layouts=@([pscustomobject]@{Lines=$Plan.FlatPlaylistLines;Writes=$Plan.FlatDataWrites;ZipPath=''})
        if ($Plan.PSObject.Properties['PreservedPlaylistLines']) {
            $layouts+=[pscustomobject]@{Lines=$Plan.PreservedPlaylistLines;Writes=$Plan.PreservedDataWrites;ZipPath=$Plan.PreservedZipPath}
        }
        foreach ($layout in $layouts) {
            $members=@{}
            foreach ($item in $layout.Writes) {$members[$item.MemberName]=$item.Destination;$knownFiles[$item.Destination]=$item.MemberName}
            for ($i=0;$i -lt $layout.Lines.Count;$i++) {
                $member=$Plan.DiskNames[$i]
                $target=$layout.ZipPath;if (-not $target) {$target=$members[$member]}
                $references[$layout.Lines[$i]]=[pscustomobject]@{Destination=$target;MemberName=$member;Archive=[bool]$layout.ZipPath}
            }
        }
    }
    Assert-OwnedPlaylist $Path $Stem $lines @($references.Keys)
    $looseMedia=New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {continue}
        if ($references.ContainsKey($line)) {
            $reference=$references[$line];$member=$reference.MemberName;$target=$reference.Destination
            if ([IO.Path]::GetExtension($member) -notin $script:DiskExtensions) {throw 'Existing loose playlist references media outside the selected system profile; output left alone.'}
            if (-not $owned.ContainsKey($target)) {$owned[$target]=@()}
            $owned[$target]+=$member
            if (-not $reference.Archive) {$looseMedia.Add($reference)}
            # A preserved file may also be part of the legacy per-game folder.
            # Keep that container ownership only for its normal exact stem;
            # replacement still verifies every file before retiring the folder.
            if ($reference.Archive -or -not $line.StartsWith($prefix+'/',[StringComparison]::Ordinal)) {continue}
        }
        $suffix='';$offset=$prefix.Length+1
        if ($line.StartsWith($prefix+'.zip#',[StringComparison]::Ordinal)) {$suffix='.zip';$offset=$prefix.Length+5}
        $target=Join-Path $Root ('.hidden/'+$Stem+$suffix).Replace('/',[IO.Path]::DirectorySeparatorChar)
        if (-not $owned.ContainsKey($target)) {$owned[$target]=@()}
        $member=$line.Substring($offset)
        if ([IO.Path]::GetExtension($member) -notin $script:DiskExtensions) {throw 'Existing playlist references media outside the selected system profile; output left alone.'}
        $owned[$target]+=$member
    }
    foreach ($reference in $looseMedia) {
        $companions=@([IO.Path]::ChangeExtension($reference.Destination,'.sbi'))
        if ([IO.Path]::GetExtension($reference.MemberName) -eq '.cue' -and (Test-Path -LiteralPath $reference.Destination -PathType Leaf)) {
            $parent=[IO.Path]::GetDirectoryName($reference.Destination)
            foreach ($track in @(Get-CueFiles $reference.Destination)) {
                $companions+=[IO.Path]::GetFullPath((Join-Path $parent $track.Replace('/',[IO.Path]::DirectorySeparatorChar)))
            }
        }
        foreach ($target in $companions) {if ($knownFiles.ContainsKey($target)) {$owned[$target]=@($knownFiles[$target])}}
    }
    return $owned
}

function New-PlaylistReferenceIndex([string]$Root) {
    # Explicit batch lifetime, never a module/global cache. Cached descriptors
    # remain read-locked; names and links are inventoried again on every check.
    return [pscustomobject]@{Root=[IO.Path]::GetFullPath($Root).TrimEnd('\','/');Playlists=@{};Cues=@{};Exact=@{};Folders=@{};Guarded=@{};
        MaximumDescriptors=4096;MaximumReferences=100000;MaximumReferenceCharacters=16777216;ReferenceCount=0;ReferenceCharacters=0;LimitReached=$false;Disabled=$false;Closed=$false}
}

function Assert-PlaylistReferenceCapacity($Index,[int]$AdditionalDescriptors) {
    if($Index.Playlists.Count+$Index.Cues.Count+$AdditionalDescriptors -gt $Index.MaximumDescriptors){
        $Index.LimitReached=$true;throw 'Playlist reference cache descriptor budget reached.'
    }
}

function Add-PlaylistReferenceKey($Index,$Entry,[string]$Kind,[string]$Path) {
    if($Entry.$Kind.Add($Path)){
        $Entry.ReferenceCount++;$Entry.ReferenceCharacters+=$Path.Length
        if($Index.ReferenceCount+$Entry.ReferenceCount -gt $Index.MaximumReferences -or
           $Index.ReferenceCharacters+$Entry.ReferenceCharacters -gt $Index.MaximumReferenceCharacters){
            $Index.LimitReached=$true;throw 'Playlist reference cache memory budget reached.'
        }
    }
}

function Open-PlaylistReferenceDescriptor([string]$Path,[string]$Root) {
    Assert-SourcePolicyPath $Path $Root
    Initialize-SourcePolicyNative
    return [OptiMiyoo.SourceRemovalLeaseV128]::OpenReadForPublication($Path)
}

function Close-PlaylistReferenceDescriptor($Descriptor) {
    if($Descriptor){$Descriptor.Dispose()}
}

function Remove-PlaylistReferenceEntry($Index,[string]$Path) {
    if(-not $Index.Playlists.ContainsKey($Path)){return}
    $entry=$Index.Playlists[$Path]
    foreach($kind in 'Exact','Folders','Guarded'){
        foreach($key in $entry.$kind){
            [void]$Index.$kind[$key].Remove($Path)
            if(-not $Index.$kind[$key].Count){$Index.$kind.Remove($key)}
        }
    }
    foreach($cue in $entry.Cues){
        if($Index.Cues.ContainsKey($cue)){
            [void]$Index.Cues[$cue].Users.Remove($Path)
            if(-not $Index.Cues[$cue].Users.Count){Close-PlaylistReferenceDescriptor $Index.Cues[$cue].Descriptor;$Index.Cues.Remove($cue)}
        }
    }
    $Index.ReferenceCount-=$entry.ReferenceCount;$Index.ReferenceCharacters-=$entry.ReferenceCharacters
    $Index.Playlists.Remove($Path)
    Close-PlaylistReferenceDescriptor $entry.Descriptor
}

function Reset-PlaylistReferenceIndexTargets($Index,[object[]]$Targets) {
    if($null -eq $Index -or $Index.Disabled){return}
    if($Index.Closed){throw 'Playlist reference index is closed.'}
    # Release only the paths about to change, including descendants of retired
    # folders. The next check opens their new bytes and reconstructs references.
    $affected=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($path in @($Index.Playlists.Keys)+@($Index.Cues.Keys)){
        foreach($target in $Targets){
            if($path.Equals($target.Destination,[StringComparison]::OrdinalIgnoreCase) -or
               ($target.Folder -and $path.StartsWith($target.Destination.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))){[void]$affected.Add($path);break}
        }
    }
    foreach($path in $affected){
        if($Index.Cues.ContainsKey($path)){
            $cue=$Index.Cues[$path]
            foreach($owner in @($cue.Users)){Remove-PlaylistReferenceEntry $Index $owner}
            Close-PlaylistReferenceDescriptor $cue.Descriptor
            $Index.Cues.Remove($path)
        }
        Remove-PlaylistReferenceEntry $Index $path
    }
}

function Close-PlaylistReferenceIndex($Index) {
    if($null -eq $Index -or $Index.Closed){return}
    $Index.Closed=$true
    foreach($entry in $Index.Playlists.Values){Close-PlaylistReferenceDescriptor $entry.Descriptor}
    foreach($cue in $Index.Cues.Values){Close-PlaylistReferenceDescriptor $cue.Descriptor}
    foreach($kind in 'Playlists','Cues','Exact','Folders','Guarded'){$Index.$kind.Clear()}
    $Index.ReferenceCount=0;$Index.ReferenceCharacters=0
}

function Add-PlaylistReferenceEntry($Index,[string]$Path) {
    $entry=[pscustomobject]@{Descriptor=$null;ReferenceCount=0;ReferenceCharacters=0;Exact=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase));Folders=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase));Guarded=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase));Cues=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))}
    try {
        Assert-PlaylistReferenceCapacity $Index 1
        $entry.Descriptor=Open-PlaylistReferenceDescriptor $Path $Index.Root
        foreach($line in (Read-PlaylistLines $Path)){
            $reference=$line.Trim()
            if(-not $reference -or $reference.StartsWith('#')){continue}
            $reference=($reference -split '#',2)[0].Replace('\',[IO.Path]::DirectorySeparatorChar).Replace('/',[IO.Path]::DirectorySeparatorChar)
            try {
                if([IO.Path]::IsPathRooted($reference)){$full=[IO.Path]::GetFullPath($reference)}
                else{$full=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($Path)) $reference))}
            } catch {throw ('Cannot verify an existing playlist reference: '+$Path)}
            Add-PlaylistReferenceKey $Index $entry Exact $full
            if([IO.Path]::GetExtension($full) -eq '.cue' -and $full.StartsWith($Index.Root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
                Add-PlaylistReferenceKey $Index $entry Cues $full
                if(-not $Index.Cues.ContainsKey($full)){
                    Assert-PlaylistReferenceCapacity $Index 2
                    $cue=[pscustomobject]@{Descriptor=$null;Tracks=@();Users=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))}
                    try {
                        if(Test-Path -LiteralPath $full -PathType Leaf){
                            $cue.Descriptor=Open-PlaylistReferenceDescriptor $full $Index.Root
                            $cue.Tracks=@(foreach($track in @(Get-CueFiles $full)){
                                $trackPath=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($full)) $track.Replace('/',[IO.Path]::DirectorySeparatorChar)))
                                Assert-PlainOutputParents $trackPath $Index.Root
                                if((Test-Path -LiteralPath $trackPath) -and ((Get-Item -LiteralPath $trackPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'A linked CUE track prevents checking another playlist dependency; outputs left alone.'}
                                $trackPath
                            })
                        }
                        $Index.Cues[$full]=$cue
                    } catch {Close-PlaylistReferenceDescriptor $cue.Descriptor;throw}
                }
                Add-PlaylistReferenceKey $Index $entry Guarded $full
                foreach($track in $Index.Cues[$full].Tracks){Add-PlaylistReferenceKey $Index $entry Exact $track;Add-PlaylistReferenceKey $Index $entry Guarded $track}
            }
        }
        foreach($dependency in $entry.Exact){
            $parent=[IO.Path]::GetDirectoryName($dependency)
            while($parent){Add-PlaylistReferenceKey $Index $entry Folders $parent;$parent=[IO.Path]::GetDirectoryName($parent)}
        }
        foreach($kind in 'Exact','Folders','Guarded'){
            foreach($key in $entry.$kind){
                if(-not $Index.$kind.ContainsKey($key)){$Index.$kind[$key]=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)}
                [void]$Index.$kind[$key].Add($Path)
            }
        }
        foreach($cue in $entry.Cues){[void]$Index.Cues[$cue].Users.Add($Path)}
        $Index.Playlists[$Path]=$entry
        $Index.ReferenceCount+=$entry.ReferenceCount;$Index.ReferenceCharacters+=$entry.ReferenceCharacters
    } catch {
        Close-PlaylistReferenceDescriptor $entry.Descriptor
        foreach($cuePath in @($Index.Cues.Keys)){
            if(-not $Index.Cues[$cuePath].Users.Count){Close-PlaylistReferenceDescriptor $Index.Cues[$cuePath].Descriptor;$Index.Cues.Remove($cuePath)}
        }
        throw
    }
}

function Update-PlaylistReferenceIndex($Index,[string]$OwnPlaylist) {
    if($Index.Closed){throw 'Playlist reference index is closed.'}
    $playlists=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $cueFiles=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $links=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $pending=New-Object 'Collections.Generic.Stack[string]';$pending.Push($Index.Root)
    # Directory metadata or a watcher cannot prove that no new foreign playlist
    # appeared. Keep this fresh traversal, including links and hidden folders.
    while($pending.Count){
        $directory=$pending.Pop();Assert-PlainOutputParents (Join-Path $directory '_') $Index.Root
        foreach($file in (New-Object IO.DirectoryInfo($directory)).GetFileSystemInfos()){
            $folder=[bool]($file.Attributes -band [IO.FileAttributes]::Directory)
            if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){
                if($folder -or $file.Extension -in '.m3u','.m3u8'){throw 'An output link prevents checking playlist ownership. Output left alone.'}
                [void]$links.Add($file.FullName);continue
            }
            if($folder){$pending.Push($file.FullName);continue}
            if($file.Extension -in '.m3u','.m3u8'){[void]$playlists.Add($file.FullName)}
            elseif($file.Extension -eq '.cue'){[void]$cueFiles.Add($file.FullName)}
        }
    }
    foreach($path in @($Index.Playlists.Keys)){if(-not $playlists.Contains($path)){Remove-PlaylistReferenceEntry $Index $path}}
    foreach($path in @($Index.Cues.Keys)){
        # A reference to a missing CUE must gain its tracks when that CUE appears.
        if(-not $Index.Cues[$path].Descriptor -and $cueFiles.Contains($path)){
            foreach($owner in @($Index.Cues[$path].Users)){Remove-PlaylistReferenceEntry $Index $owner}
            $Index.Cues.Remove($path)
        }
    }
    foreach($path in $playlists){
        if(-not $path.Equals($OwnPlaylist,[StringComparison]::OrdinalIgnoreCase) -and -not $Index.Playlists.ContainsKey($path)){Add-PlaylistReferenceEntry $Index $path}
    }
    foreach($path in $links){
        if($Index.Guarded.ContainsKey($path)){
            foreach($owner in $Index.Guarded[$path]){if(-not $owner.Equals($OwnPlaylist,[StringComparison]::OrdinalIgnoreCase)){throw 'A linked CUE or CUE track prevents checking another playlist dependency; outputs left alone.'}}
        }
    }
}

function Assert-NoForeignPlaylistReferences($Plan,[object[]]$Targets,$ReferenceIndex=$null) {
    $existing=@($Targets | Where-Object {Test-Path -LiteralPath $_.Destination})
    if ($existing.Count -eq 0) {return}
    if($null -ne $ReferenceIndex -and -not $ReferenceIndex.Disabled){
        if(-not $ReferenceIndex.Root.Equals([IO.Path]::GetFullPath($Plan.Root).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)){throw 'Playlist reference index belongs to a different destination.'}
        try {Update-PlaylistReferenceIndex $ReferenceIndex $Plan.M3uPath}
        catch {
            if(-not $ReferenceIndex.LimitReached){throw}
            # Retained handles, keys, and path text are bounded. Large trees
            # keep the original scanner for the remainder of this batch.
            Close-PlaylistReferenceIndex $ReferenceIndex;$ReferenceIndex.Disabled=$true
        }
        if(-not $ReferenceIndex.Disabled){
            foreach($target in $existing){
                $tables=@($ReferenceIndex.Exact);if($target.Folder){$tables+=,$ReferenceIndex.Folders}
                foreach($table in $tables){
                    if($table.ContainsKey($target.Destination)){
                        foreach($owner in $table[$target.Destination]){if(-not $owner.Equals($Plan.M3uPath,[StringComparison]::OrdinalIgnoreCase)){throw ('Another playlist uses this output: '+$owner+'. Output left alone; use a separate DST.')}}
                    }
                }
            }
            return
        }
    }
    $exactTargets=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $folderTargets=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($target in $existing){[void]$exactTargets.Add($target.Destination);if($target.Folder){[void]$folderTargets.Add($target.Destination)}}
    $pending=New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Plan.Root)
    while ($pending.Count -gt 0) {
        foreach ($file in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if ($file.PSIsContainer -or $file.Extension -in '.m3u','.m3u8') {throw 'An output link prevents checking playlist ownership. Output left alone.'}
                continue
            }
            if ($file.PSIsContainer) {$pending.Push($file.FullName);continue}
            if ($file.Extension -notin '.m3u','.m3u8' -or $file.FullName.Equals($Plan.M3uPath,[StringComparison]::OrdinalIgnoreCase)) {continue}
            foreach ($line in (Read-PlaylistLines $file.FullName)) {
                $reference=$line.Trim()
                if (-not $reference -or $reference.StartsWith('#')) {continue}
                $reference=($reference -split '#',2)[0].Replace('\',[IO.Path]::DirectorySeparatorChar).Replace('/',[IO.Path]::DirectorySeparatorChar)
                try {
                    if ([IO.Path]::IsPathRooted($reference)) {$full=[IO.Path]::GetFullPath($reference)}
                    else {$full=[IO.Path]::GetFullPath((Join-Path $file.DirectoryName $reference))}
                } catch {throw ('Cannot verify an existing playlist reference: '+$file.FullName)}
                $references=@($full)
                if([IO.Path]::GetExtension($full) -eq '.cue' -and $full.StartsWith($Plan.Root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full -PathType Leaf)){
                    Assert-PlainOutputParents $full $Plan.Root
                    if((Get-Item -LiteralPath $full -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'A linked CUE prevents checking another playlist dependency; outputs left alone.'}
                    foreach($track in @(Get-CueFiles $full)){
                        $trackPath=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($full)) $track.Replace('/',[IO.Path]::DirectorySeparatorChar)))
                        Assert-PlainOutputParents $trackPath $Plan.Root
                        if((Test-Path -LiteralPath $trackPath) -and ((Get-Item -LiteralPath $trackPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'A linked CUE track prevents checking another playlist dependency; outputs left alone.'}
                        $references+=$trackPath
                    }
                }
                foreach($dependency in $references){
                    $used=$exactTargets.Contains($dependency)
                    $parent=[IO.Path]::GetDirectoryName($dependency)
                    while(-not $used -and $parent){$used=$folderTargets.Contains($parent);$parent=[IO.Path]::GetDirectoryName($parent)}
                    if($used){throw ('Another playlist uses this output: '+$file.FullName+'. Output left alone; use a separate DST.')}
                }
            }
        }
    }
}

function Assert-PlaylistOutputOwnership($Plan,[string[]]$ExpectedNames,$ReferenceIndex=$null) {
    foreach($old in $Plan.Retired){
        if(-not $old.Folder -or -not (Test-Path -LiteralPath $old.Destination)){continue}
        foreach($write in $Plan.Writes){
            if($write.Destination.StartsWith($old.Destination+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
                throw 'This output layout overlaps an existing game folder. Use a clean/separate DST or move that old output first; existing files are left alone.'
            }
        }
    }
    $owned=Get-PlaylistOwnedMedia $Plan.M3uPath $Plan.Stem $Plan.Root $Plan
    foreach ($candidate in $Plan.VisibleCandidates) {
        if (Test-Path -LiteralPath $candidate.Destination) {
            throw ('A previous or unrelated visible output may conflict: '+$candidate.Destination+'. Use a clean/separate DST, or review and move the old output before rerunning; output left alone.')
        }
    }
    $targets=@($Plan.Writes)+@($Plan.Retired)
    $flatTargets=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($flat in $Plan.FlatDataWrites){[void]$flatTargets.Add($flat.Destination)}
    if ($Plan.PSObject.Properties['PreservedDataWrites']) {foreach ($preserved in $Plan.PreservedDataWrites) {[void]$flatTargets.Add($preserved.Destination)}}
    $hiddenRoot=(Join-Path $Plan.Root '.hidden')+[IO.Path]::DirectorySeparatorChar
    foreach ($target in $targets) {
        Assert-PlainOutputParents $target.Destination $Plan.Root
        if (-not (Test-Path -LiteralPath $target.Destination)) {continue}
        $item=Get-Item -LiteralPath $target.Destination -Force
        if ([bool]$item.PSIsContainer -ne [bool]$target.Folder -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'An existing output is a link or has the wrong file/folder type.'}
        $expected=@($ExpectedNames)
        if ($target.Destination.StartsWith($hiddenRoot,[StringComparison]::OrdinalIgnoreCase)) {
            if (-not $owned.ContainsKey($target.Destination)) {throw ('Existing hidden media has no matching owning playlist: '+$target.Destination+'. Use a clean/separate DST; output left alone.')}
            $expected+=@($owned[$target.Destination])
            if($flatTargets.Contains($target.Destination) -and -not $target.Folder){continue}
            $oldArchive=$null
            try {
                if (-not $target.Folder) {
                    $oldArchive=Open-ArchiveWithBudget -Path $target.Destination -Profile Media
                    $null=Get-ZipDisks $oldArchive $target.Destination
                }
                foreach ($name in $owned[$target.Destination]) {
                    if ([IO.Path]::GetExtension($name) -eq '.cue') {
                        if ($target.Folder) {
                            $cue=Join-Path $target.Destination $name.Replace('/',[IO.Path]::DirectorySeparatorChar)
                            $tracks=@(Get-CueFiles $cue)
                        } else {
                            $cueEntry=$oldArchive.GetEntry($name)
                            if ($null -eq $cueEntry) {throw 'An existing playlist references a missing CUE; output left alone.'}
                            $text=Read-SandboxedZipText $target.Destination $oldArchive $cueEntry 1MB
                            $tracks=@(Get-CueReferences ([regex]::Split($text,'\r\n|\r|\n')) $name)
                        }
                        foreach ($track in $tracks) {
                            $parent=([string][IO.Path]::GetDirectoryName($name)).Replace('\','/')
                            if ($parent) {$track=$parent+'/'+$track}
                            $expected+=$track
                        }
                    }
                    $expected+=[IO.Path]::ChangeExtension($name,'.sbi')
                }
                if ($oldArchive) {
                    foreach ($entry in $oldArchive.Entries) {
                        if ($entry.FullName.EndsWith('/')) {continue}
                        if ([IO.Path]::GetExtension($entry.FullName) -in '.m3u','.m3u8' -or $entry.FullName -notin $expected) {
                            throw 'Existing hidden ZIP may contain another game or unowned files. Use a clean/separate DST; output left alone.'
                        }
                    }
                }
            } finally {if ($oldArchive) {$oldArchive.Dispose()}}
        }
        if ($target.Folder) {Assert-GameOutputFolder $target.Destination $expected}
    }
    Assert-NoForeignPlaylistReferences $Plan $targets $ReferenceIndex
}

function Copy-LooseSet($Job,[string]$Directory,[hashtable]$SourceHashes=@{}) {
    $manifest=@{}
    foreach ($disk in $Job.Disks) {
        Assert-PlaylistName $disk.Name
        Add-CopiedFile $disk.Path $disk.Name $Directory $manifest $SourceHashes
        $parent=[IO.Path]::GetDirectoryName($disk.Path)
        if ([IO.Path]::GetExtension($disk.Name) -eq '.cue') {
            foreach ($name in @(Get-CueFiles $disk.Path)) {
                Add-CopiedFile (Join-Path $parent $name.Replace('/',[IO.Path]::DirectorySeparatorChar)) $name $Directory $manifest $SourceHashes
            }
        }
        $sbiFiles=@(Get-SbiCompanions $disk.Path)
        if ($sbiFiles.Count -gt 1) {throw 'Several SBI sidecars match one disc.'}
        foreach ($sbi in $sbiFiles) {Add-CopiedFile $sbi.FullName ([IO.Path]::GetFileNameWithoutExtension($disk.Name)+'.sbi') $Directory $manifest $SourceHashes}
    }
    return $manifest
}

function New-PlaylistZip([string]$Directory,[string]$Destination,[hashtable]$Manifest) {
    $stream=$null;$archive=$null
    try {
        $stream=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $archive=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
        foreach ($name in @($Manifest.Keys | Sort-Object)) {
            Assert-RelativeName $name
            $source=$null;$output=$null
            try {
                $source=[IO.File]::Open((Join-Path $Directory $name.Replace('/',[IO.Path]::DirectorySeparatorChar)),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                $entry=$archive.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal)
                $output=$entry.Open()
                $hash=Copy-Stream $source $output $source.Length $name
                if($source.Length -ne $Manifest[$name].Length -or $hash -cne $Manifest[$name].Hash){throw 'Staged media changed while creating the ZIP.'}
            } finally {if($output){$output.Dispose()};if($source){$source.Dispose()}}
        }
    } finally {if($archive){$archive.Dispose()};if($stream){$stream.Dispose()}}
    $archive=Open-ArchiveWithBudget -Path $Destination -Profile Media
    try {
        $actual=Read-ZipContents $archive '' $Destination
        if($actual.Count -ne $Manifest.Count){throw 'Created ZIP file count differs from the source.'}
        foreach($name in $Manifest.Keys){if(-not $actual.ContainsKey($name) -or $actual[$name].Length -ne $Manifest[$name].Length -or $actual[$name].Hash -cne $Manifest[$name].Hash){throw ('Created ZIP content mismatch: '+$name)}}
    } finally {$archive.Dispose()}
    return (Get-VerifiedHash -LiteralPath $Destination).Hash
}

function Get-JobSourcePaths($Job) {
    if ($Job.Zip) {return $Job.Zip}
    foreach ($disk in $Job.Disks) {
        $disk.Path
        $parent=[IO.Path]::GetDirectoryName($disk.Path)
        if ([IO.Path]::GetExtension($disk.Name) -eq '.cue') {
            foreach ($name in @(Get-CueFiles $disk.Path)) {Join-Path $parent $name.Replace('/',[IO.Path]::DirectorySeparatorChar)}
        }
        foreach ($sbi in @(Get-SbiCompanions $disk.Path)) {$sbi.FullName}
    }
}

function Assert-CueTargets([string[]]$Names,[string]$Directory) {
    foreach ($name in $Names) {
        if ([IO.Path]::GetExtension($name) -ne '.cue') {continue}
        $cue=Join-Path $Directory $name.Replace('/',[IO.Path]::DirectorySeparatorChar)
        foreach ($track in @(Get-CueFiles $cue)) {
            $path=Join-Path ([IO.Path]::GetDirectoryName($cue)) $track.Replace('/',[IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {throw "Missing CUE track: $track"}
            # Linux is case-sensitive; even Windows must verify the spelling.
            $partPath=[IO.Path]::GetDirectoryName($cue)
            foreach ($part in $track.Split('/')) {
                if (@(Get-ChildItem -LiteralPath $partPath -Force | Where-Object {$_.Name -ceq $part}).Count -ne 1) {throw "CUE track spelling/case does not match: $track"}
                $partPath=Join-Path $partPath $part
            }
        }
    }
}

function Assert-NoMediaNesting($Job,[string]$DestinationRoot,[bool]$ZipMode) {
    # An older run may have produced a game where this run wants a collection.
    # Never replace a folder containing another game's media.
    $parts=$Job.Stem.Split('/')
    for ($i=1;$i -lt $parts.Length;$i++) {
        $ancestor=($parts[0..($i-1)] -join '/')
        foreach ($ext in '.m3u','.m3u8') {
            if (Test-Path -LiteralPath (Join-Path $DestinationRoot ($ancestor+$ext)) -PathType Leaf) {throw "A parent collection is already a game: $ancestor"}
        }
    }
    $visibleChild=Join-Path $DestinationRoot $Job.Stem
    if (-not $ZipMode -and (Test-Path -LiteralPath $visibleChild -PathType Container)) {
        if (@(Get-ChildItem -LiteralPath $visibleChild -File -Recurse -Force | Where-Object {$_.Extension -in '.m3u','.m3u8'}).Count -gt 0) {throw 'This output game overlaps an existing collection. Rename the input game or collection.'}
    }
}

# All workers share the same display and cleanup reporting.
. (Join-Path $ScriptDir 'ui/display.ps1')

# The launcher owns navigation; workers run in a fresh script scope for each batch.
# Back never starts a worker or touches SRC/DST.
function Read-MenuChoice([string]$Prompt) {
    if ($script:UiMenuActive) {
        try {return Read-DisplayInput $Prompt $script:UiMenuTitle $script:UiMenuLines.ToArray() $script:UiMenuMood}
        finally {$script:UiMenuActive=$false}
    }
    Clear-DisplayPanel
    try {[Console]::CursorVisible=$true} catch {}
    if ([Console]::IsInputRedirected) {
        Write-Host ($Prompt+': ') -NoNewline
        $line=[Console]::ReadLine()
        if ($null -eq $line) {return 'Q'}
        return $line.Trim()
    }
    return ([string](Read-Host $Prompt)).Trim()
}

function Show-MenuTitle([string]$Path) {
    [void](Update-DisplaySize)
    $script:UiMenuActive=$script:UiVT
    $script:UiMenuTitle=$Path; $script:UiMenuMood='idle'
    $script:UiMenuLines=New-Object 'System.Collections.Generic.List[string]'
    if ($script:UiMenuActive) {return}
    Write-Host ''
    Write-RetroStripe
    Write-Host ('  '+(Color-Text ('OptiMiyoo / '+$Path) '249;172;204'))
    Write-Host '  SRC -> DST | One system per batch'
    Write-Host ''
}

function Write-MenuLine([string]$Text='', [string]$Compact='') {
    if ($script:UiMenuActive) {
        if ($Compact) {$Text=$Compact}
        $script:UiMenuLines.Add($Text)
    } else {Write-Host (ConvertTo-SafeExternalText $Text)}
}

function Invoke-OptiMenu([object[]]$Profiles) {
    $page=$StartPage; $profile=$null; $lastCode=0
    $common=@{Root=$Root; Existing=$Existing; NoAnimation=$NoAnimation; NoColor=$NoColor; DisplayEffect=$DisplayEffect}
    while ($true) {
        $worker=$null; $workerArgs=$null; $pageName=$page
        if ($page -eq 'Main') {
            Show-MenuTitle 'Main menu'
            $crtState=if ($script:DisplayEffect -eq 'CRT') {'On'} else {'Off'}
            Write-MenuLine '  S. Onion SD setup: enable supported file types / preserve selected cores' 'S. Onion SD setup / cores preserved'
            Write-MenuLine '  C. Commodore 64: convert NIB/NBZ to G64' 'C. Commodore 64 / NIB/NBZ -> G64'
            Write-MenuLine '  Z. ZX Spectrum: convert IPF to DSK' 'Z. ZX Spectrum / IPF -> DSK'
            Write-MenuLine '  Support: standard Onion cores'
            for ($i=0;$i -lt $Profiles.Count;$i++) {
                $support=Get-PlaylistSupport $Profiles[$i] ''
                $label=Get-PlaylistFeatureLabel $support
                if ($label) {$label=' '+$label}
                $shortNames=@{AMIGA='Amiga'; COMMODORE='Commodore 64'; PS='PlayStation'; SEGACD='Sega CD / Mega-CD'; CPC='Amstrad CPC'; MSX='MSX / MSX2'; VIC20='VIC-20'; DOS='MS-DOS'; ZXS='ZX Spectrum'}
                $shortLabel=$label
                $compact=('{0,2}. {1,-9} {2}{3}' -f ($i+1),$Profiles[$i].Folder,$shortNames[$Profiles[$i].Folder],$shortLabel)
                Write-MenuLine ('  {0,2}. {1,-11} {2}{3}' -f ($i+1),$Profiles[$i].Folder,$Profiles[$i].Name,$label) $compact
            }
            Write-MenuLine '  D. Demo / interactive walkthrough' 'D. Demo / interactive walkthrough'
            Write-MenuLine ('  E. CRT effect: '+$crtState+' / turn on or off')
            Write-MenuLine '  Q. Exit'
            $answer=Read-MenuChoice 'Choose a system number or letter [Enter = 1, Amiga]'
            if ($answer -eq 'Q') {return $lastCode}
            if ($answer -eq 'C') {$page='C64'; continue}
            if ($answer -eq 'Z') {$page='ZX'; continue}
            if ($answer -eq 'S') {$page='SD'; continue}
            if ($answer -eq 'D') {$page='Demo'; continue}
            if ($answer -eq 'E') {
                Switch-DisplayEffect
                $common.DisplayEffect=$script:DisplayEffect
                continue
            }
            if ($answer -eq '') {$answer='1'}
            $number=0
            if ([int]::TryParse($answer,[ref]$number) -and $number -ge 1 -and $number -le $Profiles.Count) {
                $profile=$Profiles[$number-1]
                $singleOutput='2'; if ($profile.Folder -in 'CPC','PS','SEGACD') {$singleOutput='4'}
                $hiddenOutput='2'; if ($profile.Folder -in 'DOS','MSX','PS','SEGACD','CPC','ZXS') {$hiddenOutput='3'}
                $page='SingleStorage'; continue
            }
            Write-MenuLine '  Choose one of the numbers or letters shown.'
            continue
        }
        if ($page -eq 'Demo') {
            Show-MenuTitle 'Demo / walkthrough'
            Write-MenuLine '  Demonstration only. No source, output or SD files are touched.'
            Write-MenuLine '  1. Full walkthrough / every stage'
            Write-MenuLine '  2. Commodore 64 / NIB, NBZ and G64 output'
            Write-MenuLine '  3. ZX Spectrum / IPF, DSK and output choices'
            Write-MenuLine '  4. Playlists / hidden media and disk order'
            Write-MenuLine '  5. Results / overwrite, skip and error handling'
            Write-MenuLine '  6. Bunny animation gallery'
            Write-MenuLine '  7. Core support and Onion SD setup'
            Write-MenuLine '  B. Back to main menu     Q. Exit'
            $answer=Read-MenuChoice 'Choose demo [Enter = 1]'
            if ($answer -eq 'B') {$page='Main'; continue}
            if ($answer -eq 'Q') {return $lastCode}
            if ($answer -eq '') {$answer='1'}
            $sections=@{'1'='Tour';'2'='C64';'3'='ZX';'4'='Playlists';'5'='Results';'6'='Bunny';'7'='Setup'}
            if (-not $sections.ContainsKey($answer)) {Write-MenuLine '  Choose 1 to 7, B or Q.'; continue}
            Show-MioPreview $sections[$answer]
            $common.DisplayEffect=$script:DisplayEffect
            continue
        }
        if ($page -in 'C64','ZX') {
            $pageName='Commodore 64';$outputName='G64'
            if ($page -eq 'ZX') {$pageName='ZX Spectrum';$outputName='DSK'}
            Show-MenuTitle $pageName
            if ($page -eq 'C64') {Write-MenuLine '  Convert NIB/NBZ to G64.'}
            else {Write-MenuLine '  Convert IPF to DSK.'}
            Write-MenuLine '  Conversion only. Choose Keep or Remove on the next screen.'
            $converterSystem='COMMODORE'; if ($page -eq 'ZX') {$converterSystem='ZXS'}
            $converterProfile=@($Profiles | Where-Object {$_.Folder -eq $converterSystem})[0]
            $defaultOutput='2'
            $zipNotice=Get-ZipOutputNotice $converterProfile -GameOutput
            $zipLabel=''; if ($zipNotice.Label) {$zipLabel=' '+$zipNotice.Label}
            $zipDefault=if ($defaultOutput -eq '2') {' (default)'} else {''}
            $folderDefault=if ($defaultOutput -eq '3') {' (default)'} else {''}
            $looseDefault=if ($defaultOutput -eq '4') {' (default)'} else {''}
            Write-MenuLine '  1. Auto / keep input layout'
            Write-MenuLine ('  2. ZIPs'+$zipDefault+' / one per game'+$zipLabel) ('2. ZIPs'+$zipDefault+$zipLabel)
            Write-MenuLine ('  3. Folders'+$folderDefault+' / one per game')
            Write-MenuLine ('  4. Loose '+$outputName+' files'+$looseDefault)
            if ($zipNotice.Hint) {Write-MenuLine ('  '+$zipNotice.Hint)}
            Write-MenuLine '  B. Back to main menu     Q. Exit'
            $answer=Read-MenuChoice ('Choose output [Enter = '+$defaultOutput+']')
            if ($answer -eq 'B') {$page='Main'; continue}
            if ($answer -eq 'Q') {return $lastCode}
            if ($answer -eq '') {$answer=$defaultOutput}
            if ($answer -notin '1','2','3','4') {Write-MenuLine '  Choose 1, 2, 3, 4, B or Q.'; continue}
            $workerArgs=$common.Clone()
            $workerArgs.Storage=@{'1'='Auto';'2'='Zip';'3'='Folders';'4'='Loose'}[$answer]
            if ($page -eq 'C64') {
                $worker=Join-Path $ScriptDir 'C64/convert_c64.ps1'
            } else {
                $worker=Join-Path $ScriptDir 'ZX/convert_zx.ps1'
            }
        } elseif ($page -in 'SingleStorage','Storage') {
            $singlePage=$page -eq 'SingleStorage'
            $pageName=$profile.Name+' / playlist media'
            if ($singlePage) {$pageName=$profile.Name+' / single games'}
            Show-MenuTitle $pageName
            $support=Get-PlaylistSupport $profile ''
            $coreName=$support.Core; if ($support.Core -eq $profile.DefaultCore) {$coreName=$profile.Core}
            Write-MenuLine ('  '+$profile.Folder+' / '+$coreName)
            if ($singlePage) {
                Write-MenuLine '  Games with one disc or tape side stay visible in DST.'
                Write-MenuLine '  Choose how to store them.'
            } else {
                $playlistLabel=Get-PlaylistFeatureLabel $support
                if ($playlistLabel) {Write-MenuLine ('  '+$playlistLabel)}
                if ($profile.Folder -eq 'COMMODORE') {
                    $tapeSupport=Get-TapeSwapSupport $profile '' $support
                    $tapeFormats='TAP, T64'
                    if ($tapeSupport.CanBuild) {$tapeFormats=(@($tapeSupport.Extensions | ForEach-Object {$_.TrimStart('.').ToUpperInvariant()}) -join ', ')}
                    $tapeLabel=''; if (-not $tapeSupport.CanBuild) {$tapeLabel=' ['+$tapeSupport.Status.ToLowerInvariant()+']'}
                    Write-MenuLine ('  Tape swapping: '+$tapeFormats+$tapeLabel)
                    if (-not $tapeSupport.CanBuild) {Write-MenuLine ('  '+$tapeSupport.Reason)}
                }
                Write-MenuLine ('  Single games: '+@{'1'='Auto / keep input layout';'2'='ZIPs';'3'='Folders';'4'='Loose files'}[$singleOutput])
                Write-MenuLine '  Choose how playlist media is stored in .hidden.'
                Write-MenuLine '  Playlists stay outside .hidden.'
            }
            $defaultOutput=if ($singlePage) {$singleOutput} else {$hiddenOutput}
            $zipNotice=Get-ZipOutputNotice $profile -GameOutput:$singlePage
            $zipLabel=''; if ($zipNotice.Label) {$zipLabel=' '+$zipNotice.Label}
            $autoDefault=if ($defaultOutput -eq '1') {' (default)'} else {''}
            Write-MenuLine ('  1. Auto'+$autoDefault+' / keep input layout')
            $zipChoice='2'; $folderChoice='3'; $looseChoice='4'
            $zipDefault=if ($defaultOutput -eq $zipChoice) {' (default)'} else {''}
            $folderDefault=if ($defaultOutput -eq $folderChoice) {' (default)'} else {''}
            $looseDefault=if ($defaultOutput -eq $looseChoice) {' (default)'} else {''}
            Write-MenuLine ('  '+$zipChoice+'. ZIPs'+$zipDefault+' / one per game'+$zipLabel) ($zipChoice+'. ZIPs'+$zipDefault+$zipLabel)
            Write-MenuLine ('  '+$folderChoice+'. Folders'+$folderDefault+' / one per game')
            Write-MenuLine ('  '+$looseChoice+'. Loose files'+$looseDefault)
            if ($zipNotice.Hint) {Write-MenuLine ('  '+$zipNotice.Hint)}
            if ($singlePage) {
                Write-MenuLine '  Next: storage for playlist media in .hidden.'
                Write-MenuLine '  B. Back to main menu     Q. Exit'
                $prompt='Choose single-game storage'
            } else {
                if ($support.Status -eq 'UNSUPPORTED') {Write-MenuLine ('  '+$coreName+' cannot load playlists.')}
                elseif ($zipNotice.Label -and $support.CanBuild) {Write-MenuLine '  Choose Folders or Loose files for playlists.'}
                Write-MenuLine '  Next: choose Keep or Remove originals.'
                Write-MenuLine '  B. Back to single games     Q. Exit'
                $prompt='Choose storage in .hidden'
            }
            $answer=Read-MenuChoice ($prompt+' [Enter = '+$defaultOutput+']')
            if ($answer -eq 'B') {$page=if ($singlePage) {'Main'} else {'SingleStorage'}; continue}
            if ($answer -eq 'Q') {return $lastCode}
            if ($answer -eq '') {$answer=$defaultOutput}
            if ($answer -notin '1','2','3','4') {Write-MenuLine '  Choose 1, 2, 3, 4, B or Q.'; continue}
            if ($singlePage) {$singleOutput=$answer; $page='Storage'; continue}
            $hiddenOutput=$answer
            $worker=Join-Path $ScriptDir 'playlists/make_playlists.ps1'
            $workerArgs=$common.Clone(); $workerArgs.System=$profile.Folder
            $workerArgs.SingleStorage=@{'1'='Auto';'2'='Zip';'3'='Folders';'4'='Loose'}[$singleOutput]
            $workerArgs.Storage=@{'1'='Auto';'2'='Zip';'3'='Folders';'4'='Loose'}[$hiddenOutput]
        } elseif ($page -eq 'SD') {
            $selected=Invoke-ApplicationRpc -Operation SD.Select -Payload @{}
            if ($selected.Cancelled) {$page='Main';continue}
            return 0
        }
        if ($page -in 'Storage','C64','ZX') {
            $operation='Playlist';$chosenStorage=$workerArgs.Storage
            if ($page -eq 'ZX') {$operation='ZX'}
            elseif ($page -eq 'C64') {$operation='C64'}
            if ($operation -eq 'Playlist') {$policyChoice=Read-ApplicationSourcePolicy $operation $workerArgs.System $chosenStorage $workerArgs.SingleStorage}
            else {$policyChoice=Read-ApplicationSourcePolicy $operation $workerArgs.System $chosenStorage}
            if ($policyChoice -eq 'Back') {continue}
            if ($policyChoice -eq 'Exit') {return $lastCode}
            $workerArgs.SourcePolicy=$policyChoice
        }
        return (Invoke-ApplicationMenuWorker $worker $workerArgs)
    }
}

$script:ExistingPolicy=$Existing
$script:Log=$null; $script:ReportProblem=$false; $exitCode=0
$script:Clock=[Diagnostics.Stopwatch]::StartNew()
$script:Total=0; $script:Processed=0; $script:Ok=0; $script:Skipped=0; $script:Failed=0
$results=New-Object 'System.Collections.Generic.List[object]'
$playlistReferenceIndex=$null
try {
    if ([string]::IsNullOrWhiteSpace($Root)) {$Root=Split-Path -Parent $ScriptDir}
    $Root=(Resolve-Path -LiteralPath $Root).ProviderPath
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {throw 'Root must be a folder.'}
    # Windows PowerShell may emit the JSON array as one pipeline object.
    # Assign it first so the outer array contains individual system profiles.
    $profileData=Get-Content -LiteralPath (Join-Path $ScriptDir 'systems.json') -Raw | ConvertFrom-Json
    $profiles=@($profileData)
    Show-Header
    if ($Preview) {Show-MioPreview $PreviewSection; Restore-Display; exit 0}
    if (-not $System) {
        $exitCode=Invoke-OptiMenu $profiles
        exit $exitCode
    }
    $selected=@($profiles | Where-Object {$_.Folder -eq $System})
    if ($System -eq 'All') {throw 'Choose one system for this SRC folder. The same SRC and DST folders are used for every system.'}
    if ($selected.Count -eq 0) {throw "Unknown system: $System"}
    $script:Clock.Restart()
    $stamp='{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'),$PID
    $logPath=Join-Path $Root ('OptiMiyoo_'+$stamp+'.log')
    $logParentLease=Open-SourcePolicyDirectoryLease ([IO.Path]::GetDirectoryName($logPath))
    $logHandle=$null
    try {
        $logHandle=[IO.File]::Open($logPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $script:Log=New-Object IO.StreamWriter($logHandle,[Text.Encoding]::UTF8)
        $logHandle=$null
    } finally {
        if ($logHandle) {$logHandle.Dispose()}
        $logParentLease.Dispose()
    }
    $script:Log.AutoFlush=$true
    Write-Log ('OptiMiyoo v{0} | System: {1} | Single games: {2} | Playlist media: {3}' -f $script:AppVersion,$System,$SingleStorage,$Storage)
    Write-Log ('Source policy: '+$SourcePolicy)
    Write-Event 'SOURCE' (Join-Path $Root 'SRC')
    Write-Event 'OUTPUT' (Join-Path $Root 'DST')
    Write-Host '  Existing outputs: Y / N / A / S. Skipping keeps the original.'
    Write-Host '  Single media stays visible in DST. Playlists require 2+ images.'
    Write-Host '  Working on staged copies. Originals are handled after verification.'
    Write-Host ('  Single games: '+$SingleStorage+'. Playlist media in .hidden: '+$Storage+'.')
    Write-Host '  Playback notes use standard Onion cores.' -ForegroundColor Yellow
    Show-ConversionStart $System
    $jobs=New-Object 'System.Collections.Generic.List[object]'
    foreach ($profile in $selected) {
        Show-PreparationProgress 'Preparing system' $profile.Folder 0 -1 'profiles' -Force
        $support=Get-PlaylistSupport $profile ''
        Write-Event 'CORE' ($support.Basis+' / '+$support.Core+' / '+$support.Status)
        if (-not $support.CanBuild) {Write-Event 'PLAYBACK NOTE' ((Get-PlaylistFeatureLabel $support)+' '+$support.Reason)}
        $tapeSupport=$null
        if ($profile.Folder -eq 'COMMODORE') {
            $tapeSupport=Get-TapeSwapSupport $profile '' $support
            Write-Event 'TAPES' ($tapeSupport.Status+' / '+$support.Basis+' / '+$tapeSupport.Reason)
        }
        $sourceRoot=Join-Path $Root 'SRC'
        $destRoot=Join-Path $Root 'DST'
        foreach ($dir in @($sourceRoot,$destRoot)) {
            Assert-PlainOutputParents (Join-Path $dir 'placeholder') $Root
            [void][IO.Directory]::CreateDirectory($dir)
        }
        $systemJobs=@(Get-Jobs $sourceRoot $profile)
        if ($systemJobs.Count -gt 0) {
            Write-Event 'FOUND' ('{0}: {1} input set(s) | {2}' -f $profile.Folder,$systemJobs.Count,$profile.Core)
            Write-Event 'NOTE' $profile.Note
        }
        foreach ($job in $systemJobs) {
            $job | Add-Member -NotePropertyName Profile -NotePropertyValue $profile
            $job | Add-Member -NotePropertyName TapeSupport -NotePropertyValue $tapeSupport
            $jobs.Add($job)
        }
    }
    $script:Total=$jobs.Count
    Write-Event 'QUEUE' ('{0} input set(s) found. Checking grouping and output paths.' -f $script:Total)
    $targets=@{}; $checked=0
    Show-PreparationProgress 'Checking game names' 'Checking grouping and output paths.' 0 $jobs.Count 'sets' -Force
    foreach ($job in $jobs) {
        try {Assert-GameStem $job.Stem} catch {$job.Error=$_.Exception.Message}
        $key=$job.System+'/'+$job.Stem
        if ($targets.ContainsKey($key)) {$targets[$key].Error='Several inputs map to the same game.'; $job.Error='Several inputs map to the same game.'}
        else {$targets[$key]=$job}
        $checked++; Show-PreparationProgress 'Checking game names' $job.Source $checked $jobs.Count 'sets'
    }
    $checked=0
    Show-PreparationProgress 'Checking game collections' 'Checking nested game names.' 0 $jobs.Count 'sets'
    foreach ($job in $jobs) {
        $key=$job.System+'/'+$job.Stem
        $parent=$key
        while ($parent.Contains('/')) {
            $parent=$parent.Substring(0,$parent.LastIndexOf('/'))
            $candidates=@($parent)
            foreach ($suffix in '.m3u','.m3u8','.zip') {
                if ($parent.EndsWith($suffix,[StringComparison]::OrdinalIgnoreCase)) {$candidates+=$parent.Substring(0,$parent.Length-$suffix.Length)}
            }
            foreach ($otherKey in $candidates) {
                if ($targets.ContainsKey($otherKey)) {
                    $job.Error='A game output overlaps another game/collection. Rename the input game or collection.'; $targets[$otherKey].Error=$job.Error
                }
            }
        }
        $checked++; Show-PreparationProgress 'Checking game collections' $job.Source $checked $jobs.Count 'sets'
    }
    $checked=0
    Show-PreparationProgress 'Planning game outputs' 'Reading archive directories and media names.' 0 $jobs.Count 'sets'
    foreach ($job in $jobs) {
        $job | Add-Member -NotePropertyName OutputPlan -NotePropertyValue $null
        if ($job.Error) {
            $checked++; Show-PreparationProgress 'Planning game outputs' $job.Source $checked $jobs.Count 'sets'; continue
        }
        Show-PreparationProgress 'Planning game outputs' $job.Source $checked $jobs.Count 'sets'
        try {
            $script:DiskExtensions=@($job.Profile.Extensions)
            $media=Get-GameMediaNames $job $Storage $SingleStorage
            if ($media.DiskNames.Count -gt 0) {$job.OutputPlan=Get-PlaylistOutputPlan $job $sourceRoot $destRoot $Storage $media $SingleStorage}
        } catch {$job.Error=$_.Exception.Message}
        $checked++; Show-PreparationProgress 'Planning game outputs' $job.Source $checked $jobs.Count 'sets'
    }
    Set-PlaylistOutputConflicts $jobs.ToArray()
    $sourcePlan=New-SourcePolicyPlan (Join-Path $Root 'SRC') $SourcePolicy
    $sourceIndex=0
    Show-PreparationProgress 'Checking source dependencies' 'Recording originals and shared tracks.' 0 $jobs.Count 'sets'
    foreach ($job in $jobs) {
        $job | Add-Member -NotePropertyName SourceId -NotePropertyValue ([string]$sourceIndex)
        $sourceIndex++
        try {$sourcePaths=@(Get-JobSourcePaths $job)}
        catch {
            $sourcePaths=@($job.Disks | ForEach-Object {$_.Path})
            if ($job.Zip) {$sourcePaths=@($job.Zip)}
            $sourcePlan.BlockReason='Source references could not all be resolved; originals kept for this batch. '+$_.Exception.Message
        }
        Add-SourcePolicyJob $sourcePlan $job.SourceId $sourcePaths
        Show-PreparationProgress 'Checking source dependencies' $job.Source $sourceIndex $jobs.Count 'sets'
    }
    Complete-PreparationProgress
    $playlistReferenceIndex=New-PlaylistReferenceIndex (Join-Path $Root 'DST')
    foreach ($job in $jobs) {
        Set-ApplicationCurrentJob $job.Source
        $profile=$job.Profile; $script:DiskExtensions=@($profile.Extensions)
        $script:UiGame=$job.Stem; $script:UiSystem=$job.System; $script:UiLastStage=''
        Write-Event 'GAME' ('{0}/{1} | {2}/{3}' -f ($script:Processed+1),$script:Total,$job.System,$job.Source)
        $destinationRoot=Join-Path $Root 'DST'
        $stageData=$null; $stageContent=$null; $stageM3u=$null; $stageContainer=$null; $stageIdentity=''; $stageLease=$null; $commit=$null; $archive=$null; $sourceLock=$null; $items=@()
        $outputDirectoryLocks=New-Object 'System.Collections.Generic.List[System.IDisposable]'
        $zipMode=$false; if($job.OutputPlan){$zipMode=[bool]$job.OutputPlan.ZipMode}
        $result=[pscustomobject]@{System=$job.System; Source=$job.Source; Playlist=($job.Stem+$profile.Playlist); DiskImages=0; Result='Failed'; Original='Kept in SRC'; RemovedFiles=0; KeptFiles=0; RemovalFailures=0; Detail=''}
        if ($job.OutputPlan) {
            $result.DiskImages=$job.OutputPlan.DiskNames.Count
            if (-not $job.OutputPlan.HasPlaylist) {$result.Playlist=''}
        }
        try {
            if ($job.Error) {throw $job.Error}
            # Inspect names first, before reading/hashing image contents or asking
            # to replace anything. One playable image never needs a playlist.
            $diskNames=@(); $contentNames=@(); $manifest=@{}; $dataHash=$null; $sourceHashes=@{}
            Show-Stage 'Inspecting game media' ($job.System+'/'+$job.Source)
            if ($job.Zip) {
                $sourceLock=[IO.File]::Open($job.Zip,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                Assert-ArchiveBudget -Stream $sourceLock -Profile Media
                $archive=New-Object IO.Compression.ZipArchive($sourceLock,[IO.Compression.ZipArchiveMode]::Read,$true)
                $diskNames=@(Get-ZipDisks $archive $job.Zip)
                $contentNames=@($archive.Entries | Where-Object {-not $_.FullName.EndsWith('/')} | ForEach-Object {$_.FullName})
            } else {
                $media=Get-GameMediaNames $job $Storage $SingleStorage
                $diskNames=@($media.DiskNames)
                $contentNames=@($media.ContentNames)
            }
            $result.DiskImages=$diskNames.Count
            if ($diskNames.Count -eq 0) {
                $script:Skipped++; $result.Result='Skipped'; $result.Playlist=''; $result.Detail='No supported media images for the selected system. Check the file formats and system choice.'
                Write-Event 'SKIP' ($job.System+'/'+$job.Source+' - no supported media images.'); continue
            }
            $isMulti=$diskNames.Count -gt 1
            if ($isMulti) {
                if ($zipMode -and -not $profile.ZipMemberPlaylist) {
                    Write-Event 'NOTE' 'ZIP playlists: use a compatible core, or choose Folders / Loose.'
                }
                $tapeIssue=Get-TapeSupportIssue $diskNames $job.TapeSupport
                if ($tapeIssue) {
                    Write-Event 'PLAYBACK NOTE' ($job.Source+' / '+$tapeIssue)
                }
            } else {$result.Playlist=''}
            $plan=$job.OutputPlan
            if ($null -eq $plan -or
                [string]::Join([char]0,[string[]]$diskNames) -cne [string]::Join([char]0,[string[]]$plan.DiskNames) -or
                [string]::Join([char]0,[string[]]$contentNames) -cne [string]::Join([char]0,[string[]]$plan.ContentNames)) {
                throw 'Source media names changed after output planning. Original kept; rerun the batch.'
            }
            $dataFolder=$plan.DataFolder;$relativeData=$plan.RelativeData
            $dataPath=$plan.DataPath;$m3uPath=$plan.M3uPath;$retired=@($plan.Retired)
            $paths=@($plan.Writes)+@($plan.Retired)+@($plan.VisibleCandidates)
            foreach ($target in $paths) {Assert-PlainOutputParents $target.Destination $destinationRoot}
            Assert-NoMediaNesting $job $destinationRoot $zipMode
            Write-Log ('GAME: '+$job.System+'/'+$job.Source)
            $conflicts=@($paths | Where-Object {Test-Path -LiteralPath $_.Destination})
            $overwrite=$false
            if ($conflicts.Count -gt 0) {
                $overwrite=Confirm-Overwrite
                if (-not $overwrite) {
                    $result.Result='Skipped'; $result.Detail='Overwrite declined; existing output and originals kept.'; $script:Skipped++
                    Write-Event 'SKIP' ($job.System+'/'+$job.Source+' - existing output and original kept.'); continue
                }
            }
            $expectedNames=@($contentNames)
            Assert-PlaylistOutputOwnership $plan $expectedNames $playlistReferenceIndex
            foreach ($path in @($plan.Writes | ForEach-Object {$_.Destination})) {
                $parent=[IO.Path]::GetDirectoryName($path); $parentAnchor=$parent
                while (-not (Test-Path -LiteralPath $parentAnchor)) {$parentAnchor=[IO.Path]::GetDirectoryName($parentAnchor)}
                $outputDirectoryLocks.Add((Open-SourcePolicyDirectoryLease $parentAnchor))
                [void][IO.Directory]::CreateDirectory($parent)
                if ($parent -ne $parentAnchor) {$outputDirectoryLocks.Add((Open-SourcePolicyDirectoryLease $parent))}
            }
            $stageContainer=Join-Path $destinationRoot ('.m3u_'+[Guid]::NewGuid().ToString('N').Substring(0,16)+'.tmp')
            New-SourcePolicyOwnedDirectory $stageContainer
            $stageLease=Open-SourcePolicyDirectoryLease $stageContainer;$stageIdentity=$stageLease.DirectoryIdentity
            $stageData=Join-Path $stageContainer 'data'
            if ($plan.HasPlaylist) {$stageM3u=Join-Path $stageContainer 'playlist'}
            Write-Event 'MEDIA COUNT' ('{0} playable image(s); {1}' -f $diskNames.Count,$(if ($isMulti) {'multi-media playlist'} else {'single-media game; no playlist'}))
            if ($job.Zip) {
                $sourceLock.Position=0; $sourceHash=Get-StreamHash $sourceLock $job.Source
                $sourceHashes[[IO.Path]::GetFullPath($job.Zip)]=$sourceHash
                if ($plan.PreserveZip) {
                    $manifest=Read-ZipContents $archive '' $job.Zip
                    $archive.Dispose(); $archive=$null; $sourceLock.Position=0
                    $dest=$null
                    try {
                        $dest=[IO.File]::Open($stageData,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
                        $dataHash=Copy-Stream $sourceLock $dest $sourceLock.Length $job.Source
                    } finally {if ($dest) {$dest.Dispose()}}
                    if ($dataHash -ne $sourceHash -or (Get-VerifiedHash -LiteralPath $stageData).Hash -ne $sourceHash) {throw 'ZIP copy differs from source.'}
                } else {
                    [void][IO.Directory]::CreateDirectory($stageData)
                    $manifest=Read-ZipContents $archive $stageData $job.Zip
                    $archive.Dispose(); $archive=$null
                    Assert-FolderManifest $stageData $manifest
                    Assert-CueTargets $diskNames $stageData
                }
                $sourceLock.Position=0
                if ((Get-StreamHash $sourceLock $job.Source) -ne $sourceHash) {throw 'Source ZIP changed during processing.'}
                Write-Event 'CHECK' 'Source ZIP is unchanged; verified against its starting SHA-256.'
            } else {
                [void][IO.Directory]::CreateDirectory($stageData)
                $manifest=Copy-LooseSet $job $stageData $sourceHashes
                Assert-FolderManifest $stageData $manifest
                $diskNames=@($job.Disks | ForEach-Object {$_.Name})
                Assert-CueTargets $diskNames $stageData
            }
            if($zipMode -and -not $plan.PreserveZip){
                $stageContent=$stageData
                $stageData=Join-Path $stageContainer 'media.zip'
                $dataHash=New-PlaylistZip $stageContent $stageData $manifest
            }
            $result.DiskImages=$diskNames.Count
            if ($plan.LooseFiles) {
                $items=@(foreach($write in $plan.DataWrites){
                    $name=$write.MemberName
                    if(-not $manifest.ContainsKey($name)){throw 'A planned loose output is missing from the verified media.'}
                    [pscustomobject]@{Staged=(Join-Path $stageData $name.Replace('/',[IO.Path]::DirectorySeparatorChar));Destination=$write.Destination;Folder=$false;Hash=$manifest[$name].Hash}
                })
            } else {
                $items=@([pscustomobject]@{Staged=$stageData;Destination=$dataPath;Folder=$dataFolder;Hash=$dataHash;Manifest=$manifest})
            }
            if ($plan.HasPlaylist) {
                New-Playlist $diskNames $job.Stem $stageM3u $zipMode $plan.LooseFiles -OutputLines $plan.PlaylistLines
                $items+=[pscustomobject]@{Staged=$stageM3u;Destination=$m3uPath;Folder=$false;Hash=(Get-VerifiedHash -LiteralPath $stageM3u).Hash}
            }
            # Recheck folder boundaries immediately before the transaction.
            Assert-PlaylistOutputOwnership $plan $expectedNames $playlistReferenceIndex
            Show-Stage 'Saving prepared game output' $job.Source
            Reset-PlaylistReferenceIndexTargets $playlistReferenceIndex (@($plan.Writes)+@($plan.Retired)+@([pscustomobject]@{Destination=$stageContainer;Folder=$true}))
            $commit=Install-PlaylistSet $items $overwrite $retired
            Complete-SourcePolicyJob $sourcePlan $job.SourceId $sourceHashes $items
            Complete-ApplicationCurrentJob
            $result.Result='Written'; if ($commit.Replaced) {$result.Result='Overwritten'}
            $script:Ok++; $script:UiMood='happy'; $script:UiPercent=100
            if ($plan.HasPlaylist) {
                $result.Detail='Playlist and hidden media prepared for final verification.'
                $script:UiSay='Playlist and game files prepared for final verification.'; $script:UiStage='Playlist prepared'
                Write-Event 'READY' ('{0}/{1}{2} - {3} image(s)' -f $job.System,$job.Stem,$profile.Playlist,$diskNames.Count)
            } else {
                $result.Detail='Single-media game prepared for final verification; no playlist.'
                $script:UiSay='Game prepared for final verification. No playlist needed.'; $script:UiStage='Game prepared'
                Write-Event 'READY' ($job.System+'/'+$relativeData+' - single-media game; no playlist')
            }
            Draw-DisplayPanel -Force
            Write-Event 'MEDIA' $relativeData
        } catch {
            $script:Failed++; $result.Result='Failed'; $result.Detail=$_.Exception.Message
            $script:UiMood='oops'; $script:UiSay='Processing failed. Source files are preserved.'
            Write-Event 'FAILED' ('{0}/{1} - {2}' -f $job.System,$job.Source,$result.Detail)
        } finally {
            if ($archive) {$archive.Dispose()}
            if ($sourceLock) {$sourceLock.Dispose()}
            if ($commit) {foreach ($lock in $commit.Locks) {$lock.Dispose()}}
            if($stageLease){$stageLease.Dispose()}
            if($stageContainer -and $stageIdentity -and (Test-Path -LiteralPath $stageContainer)){
                Reset-PlaylistReferenceIndexTargets $playlistReferenceIndex @([pscustomobject]@{Destination=$stageContainer;Folder=$true})
                $retain=$false
                foreach($item in $items){if($item.PreserveStaging){$retain=$true;break}}
                if($retain){Write-Event 'WARNING' ('Unverified temporary output left for session cleanup: '+$stageContainer)}
                else{
                    try{Remove-SourcePolicyOwnedPath -Path $stageContainer -Root $destinationRoot -Identity $stageIdentity -MaximumEntries 400005}
                    catch{Write-Event 'WARNING' ('Temporary output cleanup failed: '+$stageContainer+' / '+$_.Exception.Message)}
                }
            }
            foreach ($directoryLock in $outputDirectoryLocks) {$directoryLock.Dispose()}
            Write-Log ('{0}: {1}/{2} | {3}' -f $result.Result,$job.System,$job.Source,$result.Detail)
            $results.Add($result); $script:Processed++
        }
    }
    if ($SourcePolicy -eq 'Remove') {Write-Event 'CLEANUP' 'Rechecking installed outputs and original hashes before removal.'}
    Invoke-SourcePolicyCleanup $sourcePlan {param($kind,$message) Write-Event $kind $message} {param($stage,$detail,$done,$total) Show-SourceCleanupProgress $stage $detail $done $total}
    $sourceSummary=Get-SourcePolicySummary $sourcePlan
    for ($i=0; $i -lt $jobs.Count; $i++) {
        $status=Get-SourcePolicySummary $sourcePlan $jobs[$i].SourceId
        $results[$i].Original=$status.Label; $results[$i].RemovedFiles=$status.Removed
        $results[$i].KeptFiles=$status.Kept; $results[$i].RemovalFailures=$status.Failed
        if ($SourcePolicy -eq 'Remove' -and $status.Kept -gt 0) {
            $reasons=@($sourcePlan.Jobs[$jobs[$i].SourceId].Paths | ForEach-Object {$sourcePlan.Files[$_]} | Where-Object {$_.State -ne 'Removed'} | ForEach-Object {$_.Reason} | Sort-Object -Unique)
            if ($reasons.Count -gt 0) {$results[$i].Detail+=' Originals kept: '+($reasons -join ' | ')}
        }
    }
    if ($results.Count -gt 0) {
        $reportPath=[IO.Path]::ChangeExtension($logPath,'.csv')
        $reportParentLease=$null
        try {
            $reportParentLease=Open-SourcePolicyDirectoryLease ([IO.Path]::GetDirectoryName($reportPath))
            $results | ConvertTo-SafeReportRow | Export-Csv -LiteralPath $reportPath -NoClobber -NoTypeInformation -Encoding UTF8
        } catch {$script:ReportProblem=$true; Write-Event 'WARNING' ('Temporary processing report could not be saved: '+$_.Exception.Message)}
        finally {if ($reportParentLease) {$reportParentLease.Dispose()}}
    }
    $script:Clock.Stop()
    Show-ClosingPanel -RemovalFailures $sourceSummary.Failed
    foreach ($id in 1,0) {Write-Progress -Id $id -Activity 'Complete' -Completed}
    Write-RetroStripe
    Write-Event 'DONE' ('{0} prepared | {1} skipped/unsupported | {2} failed' -f $script:Ok,$script:Skipped,$script:Failed)
    if ($script:Failed -eq 0 -and $sourceSummary.Failed -eq 0 -and -not $script:ReportProblem -and $script:Ok -gt 0) {Write-Host ('  '+(Color-Text 'MIO > Preparation complete. Waiting for final verification.' '249;172;204'))}
    Write-Host ('  Elapsed: '+(Format-Duration $script:Clock.Elapsed.TotalSeconds))
    if ($jobs.Count -eq 0) {Write-Host '  No matching input images found in SRC for the selected system.' -ForegroundColor Yellow}
    Write-Host '  Waiting for independent verification and publication.'
    Write-Host ('  After final verification, copy the CONTENTS of DST into the SD card Roms/'+$System+' folder.')
    Write-Host '  Include .hidden, then refresh the game list in Onion.'
    if ($script:Failed -gt 0 -or $script:ReportProblem -or $sourceSummary.Failed -gt 0) {$exitCode=1}
} catch {
    $exitCode=1
    Write-Event 'ERROR' $_.Exception.Message
} finally {
    Close-PlaylistReferenceIndex $playlistReferenceIndex
    Restore-Display
    foreach ($id in 1,0) {Write-Progress -Id $id -Activity 'Complete' -Completed}
    if ($script:Log) {try {$script:Log.Dispose()} catch {$exitCode=1}}
}
exit $exitCode
