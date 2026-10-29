# Shared Auto, ZIP, loose-file and per-game-folder layouts for C64 and ZX.
. (Join-Path $PSScriptRoot '../onion/core_support.ps1')

function Assert-ConversionRelativeName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or [IO.Path]::IsPathRooted($Name) -or $Name.Contains('\') -or $Name.IndexOfAny([char[]]":`r`n") -ge 0) {throw 'Unsafe conversion output name.'}
    foreach ($part in $Name.Split('/')) {
        if ($part -in '', '.', '..' -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $part -match '^(?i:con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)') {throw 'Unsafe conversion output name.'}
    }
}

function Get-ConversionGameIdentity([string]$Relative,[bool]$Archive) {
    $relative=$Relative.Replace('\','/'); Assert-ConversionRelativeName $relative
    $parent=([string][IO.Path]::GetDirectoryName($relative)).Replace('\','/')
    $title=[IO.Path]::GetFileNameWithoutExtension($relative);$tag='';$errorText='';$usedFolderTitle=$false
    if (-not $Archive) {
        $pattern='(?i)\s*[\(\[]\s*(?:disc|disk|side)\s*(\d+[a-z]?|[a-z])(?:\s*(?:of|/)\s*\d+)?\s*[\)\]]'
        $found=[regex]::Matches($title,$pattern)
        if ($found.Count -eq 1) {$tag=$found[0].Groups[1].Value.ToLowerInvariant();$title=[regex]::Replace([regex]::Replace($title,$pattern,''),'\s{2,}',' ').Trim()}
        elseif ($found.Count -gt 1) {$errorText='Multiple disk labels in one filename; separate the input sets.'}
        elseif ($parent -and $title -match '^(?i:disc|disk|side)\s*(\d+[a-z]?|[a-z])$') {
            $usedFolderTitle=$true
            $tag=$Matches[1].ToLowerInvariant();$title=[IO.Path]::GetFileName($parent);$parent=([string][IO.Path]::GetDirectoryName($parent)).Replace('\','/')
        }
    }
    if (-not $Archive -and -not $usedFolderTitle -and $parent -and $title.Equals([IO.Path]::GetFileName($parent),[StringComparison]::OrdinalIgnoreCase)) {
        $title=[IO.Path]::GetFileName($parent);$parent=([string][IO.Path]::GetDirectoryName($parent)).Replace('\','/')
    }
    $stem=$title;if ($parent) {$stem=$parent+'/'+$title}
    Assert-ConversionRelativeName $stem
    foreach ($part in $stem.Split('/')) {if ($part.StartsWith('.')) {throw 'A game or collection name starts with a dot; rename the input.'}}
    [pscustomobject]@{Stem=$stem;Tag=$tag;Error=$errorText}
}

function Get-ConversionSourceGroups([string]$SourceRoot,[string]$DestinationRoot,[string]$Storage,[string]$Kind) {
    $items=New-Object 'System.Collections.Generic.List[object]';$pending=New-Object 'System.Collections.Generic.Stack[string]';$pending.Push($SourceRoot)
    $extensions=@('.ipf','.dsk');if ($Kind -eq 'C64') {$extensions=@('.nib','.nbz','.g64')}
    $scanned=0
    while ($pending.Count) {foreach ($file in @(Get-ChildItem -LiteralPath $pending.Pop() -Force | Sort-Object Name)) {
        if (++$scanned -gt 100000) {throw 'Conversion input scan exceeds the entry limit.'}
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {continue}
        if ($file.PSIsContainer) {$pending.Push($file.FullName);continue}
        if ($file.Extension -notin @('.zip')+$extensions) {continue}
        $entries=New-Object 'System.Collections.Generic.List[object]';$errorText='';$archive=$null
        try {
            if ($file.Extension -ieq '.zip') {
                $archive=Open-ArchiveWithBudget -Path $file.FullName -Profile Floppy
                foreach ($entry in $archive.Entries) {
                    if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {continue}
                    $name=$entry.FullName.Replace('\','/');Assert-ConversionRelativeName $name
                    $convert=[IO.Path]::GetExtension($name) -in $extensions
                    $entries.Add([pscustomobject]@{InputPath=$file.FullName;Type='Zip';EntryName=$name;InputName=$name;Name=$name;Converter='';Media=$convert;Error='';SourceBlockReason=''})
                }
            } else {
                if ($file.Length -gt 512MB) {throw 'Disk image exceeds the 512 MiB input limit.'}
                $entries.Add([pscustomobject]@{InputPath=$file.FullName;Type='Loose';EntryName=$null;InputName=$file.Name;Name=$file.Name;Converter='';Media=$true;Error='';SourceBlockReason=''})
            }
            if (@($entries | Where-Object {$_.Media}).Count -eq 0) {$errorText='No supported disk images in this input.'}
        } catch {$errorText=$_.Exception.Message} finally {if ($archive) {$archive.Dispose()}}
        if ($entries.Count -eq 0) {$entries.Add([pscustomobject]@{InputPath=$file.FullName;Type=$(if ($file.Extension -ieq '.zip') {'Zip'} else {'Loose'});EntryName=$null;InputName=$file.Name;Name=$file.Name;Converter='';Media=$false;Error=$errorText;SourceBlockReason=''})}
        foreach ($item in $entries) {
            $item.Error=$errorText
            if ($item.Media) {
                if ($Kind -eq 'ZX' -and [IO.Path]::GetExtension($item.Name) -ieq '.ipf') {$item.Name=[IO.Path]::ChangeExtension($item.Name,'.dsk').Replace('\','/');$item.Converter='HxC'}
                elseif ([IO.Path]::GetExtension($item.Name) -in '.nib','.nbz') {$item.Name=[IO.Path]::ChangeExtension($item.Name,'.g64').Replace('\','/');$item.Converter='Nib'}
            }
            if ($items.Count -ge 100000) {throw 'Conversion batch exceeds the output member limit; split it into smaller batches.'}
            $items.Add($item)
        }
    }}
    New-ConversionGroups $items.ToArray() $SourceRoot $DestinationRoot $Storage
}

function New-ConversionGroups([object[]]$Items,[string]$SourceRoot,[string]$DestinationRoot,[string]$Storage) {
    if ($Storage -notin 'Auto','Zip','Loose','Folders') {throw 'Choose Auto, ZIPs, a folder per game or loose files.'}
    if ($Items.Count -gt 100000) {throw 'Conversion batch exceeds the output member limit.'}
    $prefix=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\','/')+'\';$groups=@{};$auto=$Storage -eq 'Auto'
    foreach ($item in $Items) {
        $full=[IO.Path]::GetFullPath($item.InputPath)
        if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'Conversion source leaves SRC.'}
        $relative=$full.Substring($prefix.Length).Replace('\','/');$archive=$item.Type -eq 'Zip'
        if ($auto) {
            # Preserving the layout needs no inference from disk labels. Each
            # loose input keeps its own path; each ZIP remains one container.
            Assert-ConversionRelativeName $relative
            foreach ($part in $relative.Split('/')) {if ($part.StartsWith('.')) {throw 'A game or collection name starts with a dot; rename the input.'}}
            $identity=[pscustomobject]@{Stem=$relative;Tag='';Error=''}
        } else {$identity=Get-ConversionGameIdentity $relative $archive}
        $key='files:'+ $identity.Stem;if ($archive) {$key='zip:'+$relative}
        if (-not $groups.ContainsKey($key)) {
            if ($groups.Count -ge 20000) {throw 'Conversion batch exceeds the game limit.'}
            $source=$identity.Stem;if ($archive) {$source=$relative}
            $groups[$key]=[pscustomobject]@{Source=$source;SourceKey=$key;Stem=$identity.Stem;Items=(New-Object 'System.Collections.Generic.List[object]');Paths=@();Error=$identity.Error;SourceBlockReason='';Plan=$null}
        }
        $group=$groups[$key];$item | Add-Member NoteProperty DiskTag $identity.Tag -Force
        if ($item.PSObject.Properties['Error'] -and $item.Error) {$group.Error=$item.Error}
        if ($item.SourceBlockReason) {$group.SourceBlockReason=$item.SourceBlockReason}
        $group.Items.Add($item)
    }
    $result=@($groups.Values | Sort-Object Source)
    foreach ($group in $result) {
        $group.Items=@($group.Items | Sort-Object Name)
        $group.Paths=@($group.Items | ForEach-Object {$_.InputPath} | Sort-Object -Unique)
        $names=@{};$tags=@{}
        foreach ($item in $group.Items) {
            try {
                Assert-ConversionRelativeName $item.Name
                if ($names.ContainsKey($item.Name)) {throw 'Several input images have the same output name.'};$names[$item.Name]=$true
                if ($item.Type -eq 'Loose' -and $group.Items.Count -gt 1) {
                    if (-not $item.DiskTag -or $tags.ContainsKey($item.DiskTag)) {throw 'Ambiguous game set: repeated disk labels or mixed numbered and unnumbered files.'};$tags[$item.DiskTag]=$true
                }
            } catch {$group.Error=$_.Exception.Message}
        }
        if (-not $group.Error) {
            # Extension changes can turn a file into another member's parent.
            # Check the complete name set so input order and container layout
            # cannot hide a conflict; only walk each member's own ancestors.
            foreach ($name in $names.Keys) {
                $parent=([string][IO.Path]::GetDirectoryName($name)).Replace('\','/')
                while ($parent) {
                    if ($names.ContainsKey($parent)) {$group.Error='A converted output file overlaps another output member directory.';break}
                    $parent=([string][IO.Path]::GetDirectoryName($parent)).Replace('\','/')
                }
                if ($group.Error) {break}
            }
        }
        $folder=$Storage -eq 'Folders';$loose=($Storage -eq 'Loose' -or ($auto -and $group.Items[0].Type -eq 'Loose'));$relativeData=$group.Stem
        if ($Storage -eq 'Zip') {$relativeData+='.zip'}
        $writes=New-Object 'System.Collections.Generic.List[object]'
        if ($loose) {
            $parent=([string][IO.Path]::GetDirectoryName($group.Stem)).Replace('\','/')
            foreach ($item in $group.Items) {
                $name=$item.Name;if ($parent) {$name=$parent+'/'+$name}
                $writes.Add([pscustomobject]@{Name=$name;Destination=[IO.Path]::GetFullPath((Join-Path $DestinationRoot $name));Folder=$false;Role='Data';MemberName=$item.Name})
            }
            if ($writes.Count) {$relativeData=$writes[0].Name}
        } else {$writes.Add([pscustomobject]@{Name=$relativeData;Destination=[IO.Path]::GetFullPath((Join-Path $DestinationRoot $relativeData));Folder=$folder;Role='Data';MemberName=$null})}
        $group.Plan=[pscustomobject]@{Destination=[IO.Path]::GetFullPath((Join-Path $DestinationRoot $relativeData));RelativeData=$relativeData;LooseFiles=$loose;DataWrites=$writes.ToArray()}
    }
    $owners=@{}
    foreach ($group in $result) {
        # Skipped or invalid inputs cannot write outputs or claim their paths.
        if ($group.Error) {continue}
        foreach ($write in $group.Plan.DataWrites) {
            $path=$write.Destination.TrimEnd('\','/');if (-not $owners.ContainsKey($path)) {$owners[$path]=New-Object 'System.Collections.Generic.List[object]'};$owners[$path].Add($group)
        }
    }
    # Keep the latest event per path, then visit each owner list once. Repeated
    # descendants must not repeatedly traverse every owner of a shared parent.
    $marks=@{};$markState=[pscustomobject]@{Sequence=0L}
    $markOwners={param([string]$Path,[string]$Reason)
        $markState.Sequence++
        $marks[$Path]=[pscustomobject]@{Owners=$owners[$Path];Sequence=$markState.Sequence;Message=$Reason}
    }
    foreach ($path in @($owners.Keys)) {
        if ($owners[$path].Count -gt 1) {& $markOwners $path 'Several games share an output filename. Rename the conflicting images or choose ZIPs or folders.'}
        $parent=[IO.Path]::GetDirectoryName($path)
        while ($parent) {
            if ($owners.ContainsKey($parent)) {
                & $markOwners $path 'A game output overlaps another output folder or file.'
                & $markOwners $parent 'A game output overlaps another output folder or file.'
            }
            $parent=[IO.Path]::GetDirectoryName($parent)
        }
    }
    $latest=@{}
    foreach($mark in $marks.Values){
        foreach($group in $mark.Owners){
            if(-not $latest.ContainsKey($group.SourceKey) -or $mark.Sequence -gt $latest[$group.SourceKey].Sequence){
                $latest[$group.SourceKey]=[pscustomobject]@{Group=$group;Sequence=$mark.Sequence;Message=$mark.Message}
            }
        }
    }
    foreach($mark in $latest.Values){$mark.Group.Error=$mark.Message}
    return $result
}

function Test-ConversionReferenceTarget([string]$Path,$Targets) {
    if($Targets.Exact.Contains($Path)){return $true}
    $parent=[IO.Path]::GetDirectoryName($Path)
    while($parent){if($Targets.Folders.Contains($parent)){return $true};$parent=[IO.Path]::GetDirectoryName($parent)}
    return $false
}

function New-ConversionDescriptorCache([string]$Root) {
    return [pscustomobject]@{Root=[IO.Path]::GetFullPath($Root).TrimEnd('\','/');Entries=@{};Characters=0L;
        MaximumDescriptors=4096;MaximumCharacters=16MB;Disabled=$false;Closed=$false}
}

function Clear-ConversionDescriptorCache($Cache) {
    foreach($entry in @($Cache.Entries.Values)){$entry.Lease.Dispose()}
    $Cache.Entries.Clear();$Cache.Characters=0L
}

function Close-ConversionDescriptorCache($Cache) {
    if($Cache -and -not $Cache.Closed){try{Clear-ConversionDescriptorCache $Cache}finally{$Cache.Closed=$true}}
}

function Reset-ConversionDescriptorCacheTargets($Cache,[object[]]$Targets) {
    if(-not $Cache -or $Cache.Closed -or -not $Cache.Entries.Count){return}
    $paths=[pscustomobject]@{Exact=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase));Folders=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))}
    foreach($target in $Targets){[void]$paths.Exact.Add($target.Destination);if($target.Folder){[void]$paths.Folders.Add($target.Destination)}}
    foreach($path in @($Cache.Entries.Keys)){
        if(Test-ConversionReferenceTarget $path $paths){
            $entry=$Cache.Entries[$path];$entry.Lease.Dispose();$Cache.Characters-=$entry.Characters;$Cache.Entries.Remove($path)
        }
    }
}

function Read-ConversionDescriptorText([string]$Path,[string]$Root,[string]$Description,$Cache=$null) {
    if(-not $Cache){return Read-OptiTextFile $Path 1MB $Description $Root}
    if($Cache.Closed -or -not $Cache.Root.Equals([IO.Path]::GetFullPath($Root).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)){throw 'Conversion descriptor cache is closed or belongs to another output root.'}
    if($Cache.Disabled){return Read-OptiTextFile $Path 1MB $Description $Root}
    $pathFull=[IO.Path]::GetFullPath($Path)
    if($Cache.Entries.ContainsKey($pathFull)){
        $entry=$Cache.Entries[$pathFull]
        # A cached value is usable only while its original file and ancestors
        # remain pinned. Never turn an unexpectedly disposed lease into a hit.
        if(-not $entry.Lease.Stream -or -not $entry.Lease.Stream.CanRead){throw 'Conversion descriptor lease was released unexpectedly.'}
        return $entry.Text
    }
    if($Cache.Entries.Count -ge $Cache.MaximumDescriptors){
        Clear-ConversionDescriptorCache $Cache;$Cache.Disabled=$true
        return Read-OptiTextFile $Path 1MB $Description $Root
    }
    $lease=$null
    try {
        Assert-SourcePolicyPath $pathFull $Root;Initialize-SourcePolicyNative
        # File content stays immutable, while publication-compatible ancestor
        # sharing permits unrelated sibling outputs to move during this batch.
        $lease=[OptiMiyoo.SourceRemovalLeaseV128]::OpenReadForPublication($pathFull)
        $text=Read-OptiBoundedText $lease.Stream 1MB $Description $lease.Stream.Length
        [long]$characters=$pathFull.Length+$text.Length
        if($characters -gt $Cache.MaximumCharacters-$Cache.Characters){
            Clear-ConversionDescriptorCache $Cache;$Cache.Disabled=$true
        }else{
            $Cache.Entries[$pathFull]=[pscustomobject]@{Text=$text;Lease=$lease;Characters=$characters}
            $Cache.Characters+=$characters;$lease=$null
        }
        return $text
    } finally {if($lease){$lease.Dispose()}}
}

function Get-ConversionCueDependencies([string]$Path,[string]$Root,$DescriptorCache=$null) {
    $text=Read-ConversionDescriptorText $Path $Root 'Existing CUE' $DescriptorCache
    $lines=@($text -split '\r\n|\r|\n');$count=0
    if($lines.Count -gt 16384){throw 'Existing CUE exceeds the supported line count; output kept.'}
    foreach($line in $lines){
        if($line.Length -gt 8192){throw 'Existing CUE contains an overlong line; output kept.'}
        if($line -notmatch '^\s*FILE\b'){continue}
        if($line -notmatch '^\s*FILE\s+(?:"([^"]+)"|(\S+))\s+\S+\s*$'){throw 'An existing CUE has an unreadable FILE reference; output kept.'}
        $track=$Matches[1];if(-not $track){$track=$Matches[2]}
        if(++$count -gt 1024){throw 'Existing CUE exceeds the supported reference limit.'}
        if(-not [IO.Path]::IsPathRooted($track)){$track=Join-Path ([IO.Path]::GetDirectoryName($Path)) $track}
        [IO.Path]::GetFullPath($track)
    }
    if(-not $count){throw 'Existing CUE contains no FILE references; output kept.'}
}

function Assert-ConversionGroupOwnership($Group,[string]$DestinationRoot,$DescriptorCache=$null) {
    $root=[IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\','/');$names=@{};$directories=@{}
    if($DescriptorCache -and ($DescriptorCache.Closed -or -not $DescriptorCache.Root.Equals($root,[StringComparison]::OrdinalIgnoreCase))){throw 'Conversion descriptor cache is closed or belongs to another output root.'}
    $targets=[pscustomobject]@{Exact=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase));Folders=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))}
    foreach($write in $Group.Plan.DataWrites){[void]$targets.Exact.Add($write.Destination);if($write.Folder){[void]$targets.Folders.Add($write.Destination)}}
    foreach ($item in $Group.Items) {
        $names[$item.Name]=$true;$parent=([string][IO.Path]::GetDirectoryName($item.Name)).Replace('\','/')
        while ($parent) {$directories[$parent]=$true;$parent=([string][IO.Path]::GetDirectoryName($parent)).Replace('\','/')}
    }
    foreach ($write in $Group.Plan.DataWrites) {
        if (-not $write.Destination.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'Conversion output leaves DST.'}
        Assert-PlainOutputParents $write.Destination $DestinationRoot
        if (-not (Test-Path -LiteralPath $write.Destination)) {continue}
        $existing=Get-Item -LiteralPath $write.Destination -Force
        if (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [bool]$existing.PSIsContainer -ne [bool]$write.Folder) {throw 'Existing output is a link or has the wrong type; it was kept.'}
        if ($write.Folder) {
            $prefix=$existing.FullName.TrimEnd('\','/')+'\';$pending=New-Object 'System.Collections.Generic.Stack[string]';$pending.Push($existing.FullName);$count=0
            while ($pending.Count) {foreach ($entry in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
                if (++$count -gt 100000) {throw 'Existing output ownership inspection exceeds its entry limit.'}
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Existing output contains a link; it was kept.'}
                $name=$entry.FullName.Substring($prefix.Length).Replace('\','/')
                if ($entry.PSIsContainer) {
                    if (-not $directories.ContainsKey($name)) {throw 'Existing game folder contains unrelated folders; it was kept.'}
                    $pending.Push($entry.FullName)
                } elseif (-not $names.ContainsKey($name)) {throw 'Existing game folder contains unrelated files; it was kept.'}
            }}
        } elseif (-not $Group.Plan.LooseFiles) {
            $archive=Open-ArchiveWithBudget -Path $existing.FullName -Profile Floppy
            try {foreach ($entry in $archive.Entries) {
                $name=$entry.FullName.Replace('\','/')
                if ($name.EndsWith('/')) {
                    if (-not $directories.ContainsKey($name.TrimEnd('/'))) {throw 'Existing ZIP contains unrelated folders; it was kept.'}
                } elseif (-not $names.ContainsKey($name)) {throw 'Existing ZIP contains unrelated files; it was kept.'}
            }} finally {$archive.Dispose()}
        }
    }
    # Converting cannot replace an image already owned by a playlist.
    $pending=New-Object 'System.Collections.Generic.Stack[string]';$pending.Push($root);$count=0
    while ($pending.Count) {foreach ($entry in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
        if (++$count -gt 100000) {throw 'Output ownership inspection exceeds its entry limit.'}
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'An output link prevents checking playlist ownership.'}
        if ($entry.PSIsContainer) {$pending.Push($entry.FullName);continue}
        if($entry.Extension -eq '.cue'){
            # A standalone game descriptor owns its tracks even without an M3U.
            # Only descriptors replaced by this exact output set are exempt.
            if(Test-ConversionReferenceTarget $entry.FullName $targets){continue}
            foreach($reference in @(Get-ConversionCueDependencies $entry.FullName $DestinationRoot $DescriptorCache)){
                if(Test-ConversionReferenceTarget $reference $targets){throw 'An existing CUE uses this conversion output; use a separate DST.'}
            }
            continue
        }
        if ($entry.Extension -notin '.m3u','.m3u8') {continue}
        $text=Read-ConversionDescriptorText $entry.FullName $DestinationRoot 'Existing playlist' $DescriptorCache
        foreach ($line in @($text -split '\r\n|\r|\n')) {
            $line=$line.Trim();if (-not $line -or $line.StartsWith('#')) {continue}
            $reference=($line -split '#',2)[0].Replace('/','\')
            if (-not [IO.Path]::IsPathRooted($reference)) {$reference=Join-Path $entry.DirectoryName $reference};$reference=[IO.Path]::GetFullPath($reference)
            $references=New-Object 'System.Collections.Generic.List[string]';$references.Add($reference)
            if ([IO.Path]::GetExtension($reference) -ieq '.cue' -and (Test-Path -LiteralPath $reference)) {
                foreach($track in @(Get-ConversionCueDependencies $reference $DestinationRoot $DescriptorCache)){$references.Add($track)}
            }
            foreach ($owned in $references) {if(Test-ConversionReferenceTarget $owned $targets){throw 'An existing playlist uses this conversion output; use a separate DST.'}}
        }
    }}
}

function New-ConversionArchive([string]$Directory,[string]$Destination) {
    $prefix=$Directory.TrimEnd('\','/')+'\';$expected=@{}
    $zip=[IO.Compression.ZipFile]::Open($Destination,[IO.Compression.ZipArchiveMode]::Create)
    try {foreach ($file in @(Get-ChildItem -LiteralPath $Directory -File -Recurse -Force | Sort-Object FullName)) {
        $name=$file.FullName.Substring($prefix.Length).Replace('\','/');Assert-ConversionRelativeName $name
        $entry=$zip.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal);$input=$null;$output=$null
        try {$input=$file.OpenRead();$output=$entry.Open();$input.CopyTo($output)} finally {if ($output) {$output.Dispose()};if ($input) {$input.Dispose()}}
        $expected[$name]=[pscustomobject]@{Hash=(Get-SourcePolicyHash $file.FullName);Length=$file.Length}
    }} finally {$zip.Dispose()}
    $archive=Open-ArchiveWithBudget -Path $Destination -Profile Floppy
    try {
        $actual=Invoke-ArchiveSandbox -ZipPath $Destination -Archive $archive -Profile Floppy -Operation Hash
        if ($actual.Count -ne $expected.Count) {throw 'Converted ZIP member count changed.'}
        foreach ($name in $expected.Keys) {if (-not $actual.ContainsKey($name) -or $actual[$name].Hash -ne $expected[$name].Hash -or $actual[$name].Length -ne $expected[$name].Length) {throw 'Converted ZIP failed content verification.'}}
    } finally {$archive.Dispose()}
}

function Save-ConversionGroup($Group,[string]$ConvertedDirectory,[string]$DestinationRoot,[bool]$Overwrite,$DescriptorCache=$null) {
    Assert-ConversionGroupOwnership $Group $DestinationRoot $DescriptorCache
    $staged=New-Object 'System.Collections.Generic.List[object]';$backups=New-Object 'System.Collections.Generic.List[object]';$installed=New-Object 'System.Collections.Generic.List[object]';$locks=$null;$parents=New-Object 'System.Collections.Generic.List[IDisposable]'
    try {
        foreach ($write in $Group.Plan.DataWrites) {
            $parent=[IO.Path]::GetDirectoryName($write.Destination);$anchor=$parent
            while (-not [IO.Directory]::Exists($anchor)) {$anchor=[IO.Path]::GetDirectoryName($anchor)}
            $parents.Add((Open-SourcePolicyDirectoryLease $anchor));[void][IO.Directory]::CreateDirectory($parent)
            if ($parent -ne $anchor) {$parents.Add((Open-SourcePolicyDirectoryLease $parent))}
            $container=Join-Path $parent ('.ppg_'+[Guid]::NewGuid().ToString('N').Substring(0,12)+'.tmp')
            # Never adopt a pre-existing path, even when a generated name collides.
            New-SourcePolicyOwnedDirectory $container
            $output=[pscustomobject]@{Container=$container;Identity='';Staged=(Join-Path $container 'data');Destination=$write.Destination;Folder=$write.Folder;Hash=$null;Manifest=$null;Preserve=$false};$staged.Add($output)
            $containerLease=Open-SourcePolicyDirectoryLease $container;$parents.Add($containerLease);$output.Identity=$containerLease.DirectoryIdentity
            if ($write.Folder) {
                [void][IO.Directory]::CreateDirectory($output.Staged);$manifest=@{}
                foreach ($item in $Group.Items) {
                    $source=Join-Path $ConvertedDirectory $item.Name;$target=Join-Path $output.Staged $item.Name
                    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target));[IO.File]::Copy($source,$target)
                    $manifest[$item.Name.Replace('/','\')]=@{Hash=(Get-SourcePolicyHash $source);Length=(Get-Item -LiteralPath $source).Length}
                };$output.Manifest=$manifest
            } elseif ($Group.Plan.LooseFiles) {[IO.File]::Copy((Join-Path $ConvertedDirectory $write.MemberName),$output.Staged);$output.Hash=Get-SourcePolicyHash (Join-Path $ConvertedDirectory $write.MemberName)}
            else {New-ConversionArchive $ConvertedDirectory $output.Staged;$output.Hash=Get-SourcePolicyHash $output.Staged}
        }
        Assert-ConversionGroupOwnership $Group $DestinationRoot $DescriptorCache
        Reset-ConversionDescriptorCacheTargets $DescriptorCache (@($Group.Plan.DataWrites)+@($staged | ForEach-Object {[pscustomobject]@{Destination=$_.Container;Folder=$true}}))
        foreach ($output in $staged) {
            if (Test-Path -LiteralPath $output.Destination) {
                if (-not $Overwrite) {throw 'An output appeared during conversion; rerun to choose overwrite.'}
                $backup=Join-Path ([IO.Path]::GetDirectoryName($output.Destination)) ('.ppg_'+[Guid]::NewGuid().ToString('N').Substring(0,12)+'.backup')
                if ($output.Folder) {[IO.Directory]::Move($output.Destination,$backup)} else {[IO.File]::Move($output.Destination,$backup)}
                $backups.Add([pscustomobject]@{Path=$backup;Destination=$output.Destination;Folder=$output.Folder})
            }
        }
        foreach ($output in $staged) {if ($output.Folder) {[IO.Directory]::Move($output.Staged,$output.Destination)} else {[IO.File]::Move($output.Staged,$output.Destination)};$installed.Add($output)}
        # Preserve the returned List itself, not an array containing that List.
        $locks=Open-SourcePolicyOutputs $staged.ToArray()
        foreach ($backup in $backups) {try {Remove-SourcePolicyOwnedPath -Path $backup.Path -Root $DestinationRoot} catch {Write-Notice 'WARNING' ('Could not remove previous output backup: '+$backup.Path)}}
        return [pscustomobject]@{Outputs=$staged.ToArray();Locks=$locks;Replaced=($backups.Count -gt 0)}
    } catch {
        $message=$_.Exception.Message
        if ($locks) {foreach ($lock in $locks) {$lock.Dispose()}};$locks=$null
        for ($i=$installed.Count-1;$i -ge 0;$i--) {
            $output=$installed[$i]
            # Failed verification can mean another program replaced this path.
            # Retain rollback data instead of deleting it as temporary output.
            $output.Preserve=$true
            try {
                if ($output.Folder) {[IO.Directory]::Move($output.Destination,$output.Staged)} else {[IO.File]::Move($output.Destination,$output.Staged)}
                $message+=' New output moved back to: '+$output.Staged+'.'
            } catch {$message+=' Could not move output back from: '+$output.Destination+'.'}
        }
        for ($i=$backups.Count-1;$i -ge 0;$i--) {try {if ($backups[$i].Folder) {[IO.Directory]::Move($backups[$i].Path,$backups[$i].Destination)} else {[IO.File]::Move($backups[$i].Path,$backups[$i].Destination)}} catch {Write-Notice 'WARNING' ('Could not restore previous output from: '+$backups[$i].Path)}}
        throw $message
    } finally {
        Reset-ConversionDescriptorCacheTargets $DescriptorCache @($staged | ForEach-Object {[pscustomobject]@{Destination=$_.Container;Folder=$true}})
        foreach ($parent in $parents) {$parent.Dispose()}
        foreach ($output in $staged) {if (-not $output.Preserve -and $output.Identity -and (Test-Path -LiteralPath $output.Container)) {Remove-SourcePolicyOwnedPath -Path $output.Container -Root $DestinationRoot -Identity $output.Identity -MaximumEntries 400005}}
    }
}

function Invoke-ConversionGroupBatch([object[]]$Groups,[string]$Root,[string]$SourcePolicy,[string]$Existing,[scriptblock]$Convert) {
    $sourceRoot=Join-Path $Root 'SRC';$destinationRoot=Join-Path $Root 'DST';$policy=$Existing
    $sourcePlan=New-SourcePolicyPlan $sourceRoot $SourcePolicy
    foreach ($group in $Groups) {Add-SourcePolicyJob $sourcePlan $group.SourceKey $group.Paths $group.SourceBlockReason}
    $script:Total=$Groups.Count;$script:Processed=0;$script:Ok=0;$script:Skipped=0;$script:Failed=0
    $descriptorCache=New-ConversionDescriptorCache $destinationRoot
    try {
    foreach ($group in $Groups) {
        Set-ApplicationCurrentJob $group.SourceKey
        $script:UiGame=$group.Source;$script:UiLastStage=''
        $temp=$null;$tempOwned=$false;$tempIdentity='';$tempLease=$null;$commit=$null;$leases=New-Object 'System.Collections.Generic.List[IDisposable]';$hashes=@{}
        try {
            Write-Event 'GAME' ('{0}/{1} | {2}' -f ($script:Processed+1),$script:Total,$group.Source)
            if ($group.Error) {if ($group.Error -eq 'No supported disk images in this input.') {$script:Skipped++;Write-Notice 'SKIP' $group.Error;continue};throw $group.Error}
            $conflicts=@($group.Plan.DataWrites | Where-Object {Test-Path -LiteralPath $_.Destination});$overwrite=$false
            if ($conflicts.Count) {
                $choice=$policy
                while ($choice -eq 'Ask') {
                    $answer=Read-ApplicationOverwriteChoice
                    $choice=ConvertFrom-OverwriteAnswer $answer
                    if ($choice -eq 'OverwriteAll') {$policy='Overwrite';$choice='Overwrite'}
                    elseif ($choice -eq 'SkipAll') {$policy='Skip';$choice='Skip'}
                    elseif ($choice -notin 'Overwrite','Skip') {$choice='Ask'}
                }
                if ($choice -eq 'Skip') {$script:Skipped++;Write-Notice 'SKIP' ($group.Source+' - existing output kept.');continue}
                $overwrite=$true
            }
            Assert-ConversionGroupOwnership $group $destinationRoot $descriptorCache
            foreach ($path in $group.Paths) {$leases.Add((Open-SourcePolicyReadLease $path $sourceRoot));$hashes[[IO.Path]::GetFullPath($path)]=Get-SourcePolicyHash $path}
            $temp=Join-Path (Get-OptiScratchRoot) ('ppg_'+[Guid]::NewGuid().ToString('N').Substring(0,12))
            New-SourcePolicyOwnedDirectory $temp;$tempOwned=$true
            $tempLease=Open-SourcePolicyDirectoryLease $temp;$tempIdentity=$tempLease.DirectoryIdentity
            $inputDir=Join-Path $temp 'i';$convertedDir=Join-Path $temp 'o'
            [void][IO.Directory]::CreateDirectory($inputDir);[void][IO.Directory]::CreateDirectory($convertedDir)
            if ($group.Items[0].Type -eq 'Zip') {
                $zipPath=$group.Paths[0];$archive=Open-ArchiveWithBudget -Path $zipPath -Profile Floppy
                try {$null=Invoke-ArchiveSandbox -ZipPath $zipPath -Archive $archive -Profile Floppy -Operation Extract -Destination $inputDir} finally {$archive.Dispose()}
            } else {foreach ($item in $group.Items) {
                $staged=Join-Path $inputDir $item.InputName;[IO.File]::Copy($item.InputPath,$staged)
                if ((Get-SourcePolicyHash $staged) -ne $hashes[[IO.Path]::GetFullPath($item.InputPath)]) {throw 'Staged disk differs from its original.'}
            }}
            $index=0;$mediaCount=@($group.Items | Where-Object {$_.Media}).Count
            foreach ($item in $group.Items) {
                $source=Join-Path $inputDir $item.InputName;$target=Join-Path $convertedDir $item.Name
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                if ($item.Media) {Show-Stage ('Preparing disk '+($index+1)+'/'+$mediaCount) $item.InputName}
                else {Show-Stage 'Copying companion file' $item.InputName}
                & $Convert $item $source $target $temp $index $mediaCount
                if ($item.Media) {$index++}
            }
            foreach ($path in $group.Paths) {if ((Get-SourcePolicyHash $path) -ne $hashes[[IO.Path]::GetFullPath($path)]) {throw 'Source changed during conversion; original kept.'}}
            Show-Stage 'Checking prepared output' $group.Source
            $commit=Save-ConversionGroup $group $convertedDir $destinationRoot $overwrite $descriptorCache
            Complete-SourcePolicyJob $sourcePlan $group.SourceKey $hashes $commit.Outputs
            Complete-ApplicationCurrentJob
            $script:Ok++;Write-Notice 'READY' ($group.Source+' | prepared for final checks: '+$group.Plan.RelativeData)
        } catch {$script:Failed++;Write-Notice 'FAILED' ($group.Source+' | '+$_.Exception.Message);Write-Log ($_ | Out-String)}
        finally {
            foreach ($lease in $leases) {$lease.Dispose()}
            if ($commit) {foreach ($lock in $commit.Locks) {$lock.Dispose()}}
            if ($tempLease) {$tempLease.Dispose()}
            if ($tempOwned -and $tempIdentity -and (Test-Path -LiteralPath $temp)) {Remove-SourcePolicyOwnedPath -Path $temp -Root (Get-OptiScratchRoot) -Identity $tempIdentity -MaximumEntries 400005}
            $script:Processed++
        }
    }
    Invoke-SourcePolicyCleanup $sourcePlan {param($kind,$message) Write-Notice $kind $message}
    Show-ClosingPanel
    if ($script:Failed -or (Get-SourcePolicySummary $sourcePlan).Failed) {return 1};return 0
    } finally {Close-ConversionDescriptorCache $descriptorCache}
}
