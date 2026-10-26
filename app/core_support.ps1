# Parse only straightforward shell commands, never execute a launcher. Quoted
# examples and comments are data, not evidence of a selected emulator core.
function Get-LauncherCommands([string]$Launch) {
    if ($Launch.Length -gt 262144) {throw 'launch.sh exceeds the supported 256 KiB text limit.'}
    $commands=New-Object 'System.Collections.Generic.List[object]'
    $tokens=New-Object 'System.Collections.Generic.List[object]'
    $word=New-Object Text.StringBuilder
    $quote=[char]0; $started=$false; $literalDollar=$false
    $text=$Launch+"`n"
    for ($i=0; $i -lt $text.Length; $i++) {
        $c=$text[$i]
        if ($quote -eq [char]39) {
            if ($c -eq [char]39) {$quote=[char]0}
            else {[void]$word.Append($c); if ($c -eq '$') {$literalDollar=$true}}
            continue
        }
        if ($c -eq '\') {
            if ($i+1 -ge $text.Length) {throw 'Incomplete shell escape in launch.sh.'}
            $next=$text[$i+1]
            if ($next -eq "`r" -and $i+2 -lt $text.Length -and $text[$i+2] -eq "`n") {$i+=2; continue}
            if ($next -eq "`n") {$i++; continue}
            if ($quote -eq [char]34 -and $next -notin [char]34,[char]36,[char]92,[char]96) {[void]$word.Append($c); continue}
            $i++; $started=$true; [void]$word.Append($next)
            if ($next -eq '$') {$literalDollar=$true}
            continue
        }
        # Keep substitutions opaque so their contents cannot be mistaken for
        # top-level commands. Only the standard dirname assignment qualifies.
        if ($c -eq [char]96) {
            $started=$true; [void]$word.Append($c); $closed=$false
            for ($i++; $i -lt $text.Length; $i++) {
                $part=$text[$i]; [void]$word.Append($part)
                if ($part -eq '\' -and $i+1 -lt $text.Length) {$i++; [void]$word.Append($text[$i]); continue}
                if ($part -eq [char]96) {$closed=$true; break}
            }
            if (-not $closed) {throw 'Unclosed shell substitution in launch.sh.'}
            continue
        }
        if ($c -eq '$' -and $i+1 -lt $text.Length -and $text[$i+1] -eq '(') {
            $started=$true; [void]$word.Append('$('); $i++; $depth=1; $innerQuote=[char]0
            for ($i++; $i -lt $text.Length; $i++) {
                $part=$text[$i]; [void]$word.Append($part)
                if ($part -eq '\' -and $innerQuote -ne [char]39 -and $i+1 -lt $text.Length) {$i++; [void]$word.Append($text[$i]); continue}
                if ($innerQuote -ne [char]0) {if ($part -eq $innerQuote) {$innerQuote=[char]0}; continue}
                if ($part -in [char]34,[char]39) {$innerQuote=$part; continue}
                if ($part -eq '(') {$depth++}
                elseif ($part -eq ')') {$depth--; if ($depth -eq 0) {break}}
            }
            if ($depth -ne 0) {throw 'Unclosed shell substitution in launch.sh.'}
            continue
        }
        if ($quote -eq [char]34) {
            if ($c -eq [char]34) {$quote=[char]0} else {[void]$word.Append($c)}
            continue
        }
        if ($c -in [char]34,[char]39) {$quote=$c; $started=$true; continue}
        if ($c -eq '#' -and -not $started) {
            while ($i -lt $text.Length -and $text[$i] -ne "`n") {$i++}
            $c="`n"
        }
        if ($c -in '|','&','(',')' -or ($c -in '{','}' -and -not $started) -or ($c -eq '<' -and $i+1 -lt $text.Length -and $text[$i+1] -eq '<')) {
            throw 'Conditional, compound or redirected shell execution is unverified.'
        }
        if ([char]::IsWhiteSpace($c) -or $c -eq ';') {
            if ($started) {
                $tokens.Add([pscustomobject]@{Value=$word.ToString(); LiteralDollar=$literalDollar})
                [void]$word.Clear(); $started=$false; $literalDollar=$false
            }
            if ($c -eq "`n" -or $c -eq ';') {
                if ($tokens.Count -gt 0) {$commands.Add([pscustomobject]@{Tokens=$tokens.ToArray()}); $tokens.Clear()}
            }
            continue
        }
        $started=$true; [void]$word.Append($c)
    }
    if ($quote -ne [char]0) {throw 'Unclosed shell quote in launch.sh.'}
    return $commands.ToArray()
}

function Get-SelectedRetroArchCore([string]$Launch) {
    $calls=New-Object 'System.Collections.Generic.List[string]'
    $progdirKnown=$false
    foreach ($command in @(Get-LauncherCommands $Launch)) {
        $words=@($command.Tokens); $at=0
        while ($at -lt $words.Count -and $words[$at].Value -match '^[A-Za-z_][A-Za-z0-9_]*=') {$at++}
        if ($at -eq $words.Count) {
            foreach ($word in $words) {
                if ($word.Value -cmatch '^progdir=') {
                    $progdirKnown=($word.Value -cmatch '^progdir=(?:`dirname "\$0"`|\$\(dirname "\$0"\))$' -and -not $word.LiteralDollar)
                }
            }
            continue
        }
        $head=$words[$at].Value
        # A later export/read/unset must not leave a stale dirname assumption.
        if ($head -in 'export','readonly','local','declare','typeset','read','unset') {
            foreach ($word in $words) {if ($word.Value -cmatch '^progdir(?:=|$)') {$progdirKnown=$false}}
        }
        if ($head -in 'if','then','elif','else','fi','case','esac','while','until','for','select','do','done','function','eval','.','source','alias','unalias','trap','exit','return','!') {
            throw 'Conditional or custom shell execution in launch.sh is unverified.'
        }
        $wasExec=($head -ceq 'exec')
        if ($wasExec) {$at++; if ($at -ge $words.Count) {throw 'Incomplete exec command in launch.sh.'}; $head=$words[$at].Value}
        $exePattern='^(?:retroarch|\./retroarch|/mnt/SDCARD/RetroArch/retroarch|(?:\$progdir|\$\{progdir\})/\.\./\.\./RetroArch/retroarch)$'
        if ($head -cnotmatch $exePattern) {
            if ($wasExec) {throw 'Custom exec command in launch.sh is unverified.'}
            continue
        }
        foreach ($prefix in @($words | Select-Object -First $at)) {if ($prefix.Value -cmatch '^progdir=') {$progdirKnown=$false}}
        if ($words[$at].LiteralDollar -or ($head.Contains('$') -and -not $progdirKnown)) {throw 'The RetroArch program directory is unverified.'}
        $coreArguments=New-Object 'System.Collections.Generic.List[object]'
        for ($j=$at+1; $j -lt $words.Count; $j++) {
            $value=$words[$j].Value
            if ($value -ceq '-L') {
                $j++; if ($j -ge $words.Count) {throw 'Missing literal -L argument in launch.sh.'}
                $coreArguments.Add($words[$j]); continue
            }
            if ($value -cmatch '^(?:-L.|--libretro)' -or ($value.Contains('$') -and $value -cne '$1') -or $value.Contains([string][char]96)) {
                throw 'Dynamic or additional core arguments in launch.sh are unverified.'
            }
        }
        if ($coreArguments.Count -ne 1) {throw 'Ambiguous/custom core selection in launch.sh; no automatic changes.'}
        $argument=$coreArguments[0]
        $pathPattern='^(?:\$progdir/\.\./\.\.|\$\{progdir\}/\.\./\.\.|/mnt/SDCARD)/RetroArch/\.retroarch/cores/(?<core>[A-Za-z0-9_]+_libretro\.so)$'
        if ($argument.LiteralDollar -or $argument.Value -cnotmatch $pathPattern) {throw 'Custom core path in launch.sh; no automatic changes.'}
        $core=$Matches['core']
        if ($argument.Value.Contains('$') -and -not $progdirKnown) {throw 'The core program directory is unverified.'}
        $calls.Add($core)
    }
    if ($calls.Count -ne 1) {throw 'No single unconditional RetroArch core selection was found in launch.sh.'}
    return $calls[0]
}

# Read-only assessment of the user's selected Onion core. Never execute a launcher.
function Assert-PlainOnionPath([string]$Path,[string]$Root) {
    $full=[IO.Path]::GetFullPath($Path)
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if (-not $full.Equals($rootFull,[StringComparison]::OrdinalIgnoreCase) -and
        -not $full.StartsWith($rootFull+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'SD path is outside the selected root.'
    }
    # Inspect every existing ancestor, including those above the selected root.
    # Native leases pin these checked paths while reading or editing them.
    $current=$full
    $workBoundary=$null
    if ((Get-Command Test-ApplicationWorker -ErrorAction SilentlyContinue) -and (Test-ApplicationWorker)) {$workBoundary=Get-ApplicationValidationRoot $Path ([IO.Path]::GetPathRoot($Path))}
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'SD path contains a link; left unchanged.'}
        }
        if ($workBoundary -and $current.Equals($workBoundary,[StringComparison]::OrdinalIgnoreCase)) {break}
        $current=[IO.Path]::GetDirectoryName($current)
    }
}

function Read-OptiBoundedText([IO.Stream]$Stream,[int]$MaximumBytes,[string]$Description,[long]$ExpectedLength=-1) {
    if ($MaximumBytes -lt 1) {throw 'Invalid text size limit.'}
    if ($ExpectedLength -gt $MaximumBytes -or ($Stream.CanSeek -and $Stream.Length-$Stream.Position -gt $MaximumBytes)) {
        throw ($Description+' exceeds its supported text size limit.')
    }
    $memory=New-Object IO.MemoryStream
    $reader=$null; $buffer=New-Object byte[] 65536; [long]$total=0
    try {
        while (($read=$Stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            # Check actual bytes too: ZIP metadata can understate expanded data.
            if ($read -gt $MaximumBytes-$total) {throw ($Description+' exceeds its supported text size limit.')}
            $memory.Write($buffer,0,$read); $total+=$read
        }
        if ($ExpectedLength -ge 0 -and $total -ne $ExpectedLength) {throw ($Description+' text length does not match its declared size.')}
        $memory.Position=0
        $reader=New-Object IO.StreamReader($memory,$true)
        return $reader.ReadToEnd()
    } finally {if ($reader) {$reader.Dispose()}; $memory.Dispose()}
}

function Open-OptiInputLease([string]$Path,[string]$Root) {
    if (Get-Command Open-SourcePolicyReadLease -ErrorAction SilentlyContinue) {return Open-SourcePolicyReadLease $Path $Root}
    if ('OptiMiyoo.OnionPathLease' -as [type]) {return [OptiMiyoo.OnionPathLease]::Open($Path,$Root,$false,$false,$false)}
    # Standalone SD assessment uses the same native path pinning as workers.
    . (Join-Path $PSScriptRoot 'source_policy.ps1')
    Assert-PlainOnionPath $Path $Root
    Initialize-SourcePolicyNative
    return [OptiMiyoo.SourceRemovalLeaseV128]::OpenRead($Path)
}

function Read-OptiTextFile([string]$Path,[int]$MaximumBytes,[string]$Description,[string]$Root) {
    $lease=$null; $stream=$null
    try {
        if ($Root) {$lease=Open-OptiInputLease $Path $Root; $stream=$lease.Stream}
        else {$stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}
        return Read-OptiBoundedText $stream $MaximumBytes $Description $stream.Length
    } finally {if ($lease) {$lease.Dispose()} elseif ($stream) {$stream.Dispose()}}
}

function Test-CoreBinaryPatterns([string]$Path,[string[]]$Patterns,[int]$Overlap=512,[string]$Root) {
    # Only bounded format/callback tokens are requested below. Retain enough
    # bytes between chunks to recognize a token crossing a read boundary, while
    # avoiding a byte array plus UTF-16 string for the entire emulator binary.
    $found=New-Object bool[] $Patterns.Count
    $remaining=$Patterns.Count
    $buffer=New-Object byte[] 65536
    $tail=''
    $lease=$null; $stream=$null
    try {
        if ($Root) {$lease=Open-OptiInputLease $Path $Root; $stream=$lease.Stream}
        else {$stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}
        if ($stream.Length -gt 512MB) {throw 'Installed core exceeds the supported 512 MiB inspection limit.'}
        while ($remaining -gt 0 -and ($count=$stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            $chunk=$tail+[Text.Encoding]::ASCII.GetString($buffer,0,$count)
            for ($i=0; $i -lt $Patterns.Count; $i++) {
                if (-not $found[$i] -and ($chunk -match $Patterns[$i])) {$found[$i]=$true; $remaining--}
            }
            $tail=$chunk.Substring([Math]::Max(0,$chunk.Length-$Overlap))
        }
    } finally {if ($lease) {$lease.Dispose()} elseif ($stream) {$stream.Dispose()}}
    return ,$found
}

function Get-OnionCoreSupport($Profile,[string]$SdRoot,[string]$Extension,[switch]$Playlist) {
    # Onion's ROM folder and emulator configuration folder can differ.
    # PlayStation uses Roms/PS but Emu/PSX.
    $emuFolder=$Profile.Folder
    if ($Profile.EmuFolder) {$emuFolder=$Profile.EmuFolder}
    $result=[pscustomobject]@{CanBuild=$false; Status='UNSUPPORTED'; Core=$Profile.DefaultCore;
        Reason=$Profile.DefaultReason; Basis='Onion default'; EmuFolder=$emuFolder; ConfigPath=$null; LaunchPath=$null}
    if (-not $SdRoot) {
        $result.CanBuild=[bool]$Profile.DefaultSupported
        if ($result.CanBuild) {$result.Status='DEFAULT'; $result.Reason='Supported with the standard Onion core; your SD selection has not been checked.'}
        return $result
    }
    $result.Basis='Selected on SD'; $result.Core='unknown'
    try {
        $emu=Join-Path (Join-Path $SdRoot 'Emu') $emuFolder
        $result.ConfigPath=Join-Path $emu 'config.json'
        $result.LaunchPath=Join-Path $emu 'launch.sh'
        Assert-PlainOnionPath $result.ConfigPath $SdRoot
        Assert-PlainOnionPath $result.LaunchPath $SdRoot
        if (-not (Test-Path -LiteralPath $result.ConfigPath -PathType Leaf)) {
            $result.Status='NOT INSTALLED'; $result.Reason='No system config.json found on this SD card.'; return $result
        }
        $config=(Read-OptiTextFile $result.ConfigPath 1MB 'config.json' $SdRoot) | ConvertFrom-Json
        if ($config.launch -ne 'launch.sh') {throw 'Custom launch filename; the selected core cannot be verified automatically.'}
        $launch=Read-OptiTextFile $result.LaunchPath 256KB 'launch.sh' $SdRoot
        $result.Core=Get-SelectedRetroArchCore $launch
        if ($result.Core -notin @($Profile.SupportedCores)) {
            if ($result.Core -eq $Profile.DefaultCore -and -not $Profile.DefaultSupported) {
                $result.Status='UNSUPPORTED'; $result.Reason=$Profile.DefaultReason
            } else {
                $result.Status='UNVERIFIED'; $result.Reason='Loading this file type has not been established for the selected core.'
                if ($Playlist) {$result.Reason='Playlist loading and disk swapping have not been established for this selected core.'}
            }
            return $result
        }
        $corePath=Join-Path (Join-Path $SdRoot 'RetroArch/.retroarch/cores') $result.Core
        Assert-PlainOnionPath $corePath $SdRoot
        if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
            $result.Status='NOT INSTALLED'; $result.Reason='The selected core file is missing from the SD card.'; return $result
        }
        $formatToken=$Extension.TrimStart('.')
        # Bound format tokens so incidental error text cannot grant support.
        # Known playlist core families supply the disk-control check; these
        # binary checks also distinguish older builds without playlist loading.
        $pattern='(?:\x00|\|)'+[regex]::Escape($formatToken)+'(?:\||\x00)'
        if ($Playlist -and $Profile.Folder -eq 'ZXS') {$pattern='tzx\|tap\|[^\x00\r\n]{0,300}\|m3u(?:\||\x00)'}
        $patterns=@($pattern)
        $lynxRaw=(-not $Playlist -and $Profile.Folder -eq 'LYNX' -and $Extension -eq '.lyx')
        # Older Handy/Beetle Lynx loaders accept headerless ROMs by contents.
        # Their lnx|o list omits lyx, but only limits archive-member selection;
        # a loose .lyx path from Onion still reaches the raw cartridge loader.
        if ($lynxRaw) {$patterns+='\x00lnx\|o\x00'}
        $advertises=(Test-CoreBinaryPatterns $corePath $patterns ([Math]::Max(512,$formatToken.Length+2)) $SdRoot) -contains $true
        if (-not $advertises) {$result.Reason=('Selected core build does not advertise '+$Extension+' loading.'); return $result}
        $result.CanBuild=$true; $result.Status='SUPPORTED'
        $result.Reason=('Selected core build advertises '+$Extension+' loading.')
        if ($lynxRaw) {$result.Reason='Selected Lynx core supports loading headerless ROM files.'}
        if ($Playlist) {$result.Reason='Selected core is a known disk-swap core and its installed build advertises playlist loading.'}
    } catch {$result.Status='UNVERIFIED'; $result.Reason=$_.Exception.Message}
    return $result
}

function Get-PlaylistSupport($Profile,[string]$SdRoot) {
    return Get-OnionCoreSupport $Profile $SdRoot $Profile.Playlist -Playlist
}

function Get-OnionConfigPatch([byte[]]$Original,[string[]]$Extensions) {
    # Build only the file-type-list edit. Each caller checks core eligibility
    # independently before supplying extensions; this helper never touches files.
    $utf8=New-Object Text.UTF8Encoding($false,$true);$raw=$utf8.GetString($Original)
    $config=$raw.TrimStart([char]0xFEFF) | ConvertFrom-Json
    if($config.launch -cne 'launch.sh' -or $config.extlist -isnot [string] -or -not $config.extlist){throw 'SD config does not have a verified launcher and extension list.'}
    $missing=@($Extensions | Where-Object {$_ -notin @($config.extlist -split '\|')})
    if($missing.Count -eq 0){return ,$Original}
    $rx=New-Object regex('("extlist"\s*:\s*")((?:[^"\\]|\\.)*)(")')
    if($rx.Matches($raw).Count -ne 1){throw 'Ambiguous extension list in SD config.'}
    $updated=$rx.Replace($raw,('${1}${2}|'+($missing -join '|')+'${3}'))
    $null=$updated.TrimStart([char]0xFEFF) | ConvertFrom-Json
    return ,$utf8.GetBytes($updated)
}

function Get-OnionSetupProfiles([string]$CodeRoot=$PSScriptRoot) {
    $profileData=Get-Content -LiteralPath (Join-Path $CodeRoot 'systems.json') -Raw | ConvertFrom-Json
    @($profileData)
    # Lynx is a file-list addition only, not a numbered playlist system.
    [pscustomobject]@{
        Folder='LYNX';EmuFolder='LYNX';Name='Atari Lynx';SetupExtension='.lyx'
        DefaultCore='handy_libretro.so';DefaultSupported=$false
        DefaultReason='LYX support must be checked in the installed core.'
        SupportedCores=@('handy_libretro.so','mednafen_lynx_libretro.so')
    }
}

function Get-OnionSetupSupport($Profile,[string]$SdRoot) {
    if ($Profile.PSObject.Properties['SetupExtension']) {
        return Get-OnionCoreSupport $Profile $SdRoot $Profile.SetupExtension
    }
    return Get-PlaylistSupport $Profile $SdRoot
}

function Get-OnionSetupExtensions($Profile,[string]$SdRoot,$Support) {
    if (-not $Support.CanBuild) {return}
    if ($Profile.PSObject.Properties['SetupExtension']) {
        return $Profile.SetupExtension.TrimStart('.')
    }
    $Profile.Playlist.TrimStart('.')
    if ($Profile.Folder -eq 'COMMODORE') {
        $tape=Get-TapeSwapSupport $Profile $SdRoot $Support
        if ($tape.CanBuild) {$tape.Extensions | ForEach-Object {$_.TrimStart('.')}}
    }
}

function Get-OnionSetupMenuRows {
    @(
        'Enables supported files in Onion''s list.',
        'Only edits config.json''s file-type list.',
        'Adds playlists, C64 tapes and Lynx .lyx.',
        'SD config backups: OptiMiyoo_Backup_<ID>/',
        'Does not install or switch emulator cores.',
        'Refresh Onion''s game list after setup.',
        '1. Amiga: PUAE2021 / PUAE',
        '2. C64: VICE x64 / x64sc',
        '3. PlayStation: PCSX ReARMed',
        '4. Sega CD: PicoDrive / Genesis Plus GX',
        '5. CPC: use Caprice32 instead of CrocoDS.',
        '   Default CrocoDS cannot load playlists.',
        '6. MSX / MSX2: blueMSX',
        '7. VIC-20: VICE xvic',
        '8. MS-DOS: DOSBox Pure',
        '9. ZX: needs newer Fuse with M3U support.',
        '   Default Onion Fuse cannot load playlists.',
        'Lynx .lyx: Handy / Beetle Lynx'
    )
}

function Get-PlaylistFeatureLabel($Profile,$Support) {
    if ($Support.CanBuild) {return ''}
    if ($Support.Status -eq 'NOT INSTALLED') {return '[not installed]'}
    if ($Support.Status -eq 'UNVERIFIED') {return '[playlists unverified]'}
    return '[playlists unsupported]'
}

function Get-ZipOutputNotice($Profile,$Support,[switch]$Conversion) {
    # ZipMemberPlaylist describes OptiMiyoo's archive#member playlist layout,
    # not general ZIP loading. DefaultZipSupport follows Onion's core docs.
    $notice=[pscustomobject]@{Label='';Hint=''}
    $knownMemberCore=($Profile.ZipMemberPlaylist -and $Support.Core -in @($Profile.SupportedCores))
    if ($Support.Status -in 'UNVERIFIED','NOT INSTALLED' -or
        ($Support.Core -ne $Profile.DefaultCore -and -not $knownMemberCore)) {
        $notice.Label='[ZIP playback unverified]'
        $notice.Hint='Unpack ZIP output before playing.'
    } elseif ($Profile.DefaultZipSupport -eq 'Unsupported') {
        $notice.Label='[unsupported by default Onion OS core]'
        $notice.Hint='ZIP loading is not supported. Unpack before playing.'
    } elseif ($Profile.DefaultZipSupport -eq 'Unlisted') {
        $notice.Label='[unpack before playing]'
        if ($Profile.Folder -in 'CPC','ZXS') {$notice.Label='[unsupported by default Onion OS core]'}
        $notice.Hint='ZIP loading is not listed in Onion docs for this core.'
    } elseif (-not $Conversion -and -not $Profile.ZipMemberPlaylist) {
        $notice.Label='[ZIP playlists unsupported]'
        $notice.Hint='The core loads ZIPs, but not ZIP playlists.'
        if ($Profile.Folder -eq 'MSX') {
            $notice.Label='[unsupported by default Onion OS core]'
            $notice.Hint='ZIP games work; ZIP playlists are unsupported.'
        }
    }
    if (-not $Conversion) {
        if ($notice.Label -eq '[unpack before playing]') {$notice.Label='[ZIP playlists unsupported]'}
        if ($notice.Hint -match '(?i)unpack') {$notice.Hint='Choose Folders or Loose files for playlists.'}
    }
    return $notice
}

function Get-TapeSwapSupport($Profile,[string]$SdRoot,$PlaylistSupport=$null) {
    # Tape loading is not proof of side swapping. The VICE Disk Control handlers
    # were checked separately: eject detaches tape unit 1; insert attaches the
    # selected tape and starts the datasette. See docs/USAGE.md for tape support details.
    $result=[pscustomobject]@{CanBuild=$false; Status='UNVERIFIED'; Extensions=@();
        Core=$Profile.DefaultCore; Reason='Tape swapping has not been established for this core.'}
    if ($Profile.Folder -ne 'COMMODORE') {return $result}
    if ($null -eq $PlaylistSupport) {$PlaylistSupport=Get-PlaylistSupport $Profile $SdRoot}
    $result.Core=$PlaylistSupport.Core
    if (-not $PlaylistSupport.CanBuild) {
        $result.Status=$PlaylistSupport.Status; $result.Reason=$PlaylistSupport.Reason
        return $result
    }
    if ($result.Core -notin 'vice_x64_libretro.so','vice_x64sc_libretro.so') {return $result}
    $extensions=@('.tap','.t64')
    if ($SdRoot) {
        try {
            $path=Join-Path (Join-Path $SdRoot 'RetroArch/.retroarch/cores') $result.Core
            Assert-PlainOnionPath $path $SdRoot
            $patterns=@('(?:\x00|\|)tap(?:\||\x00)','(?:\x00|\|)t64(?:\||\x00)',
                '(?-i:retro_disk_set_eject_state\x00)','(?-i:retro_disk_set_image_index\x00)')
            $evidence=Test-CoreBinaryPatterns $path $patterns -Root $SdRoot
            $extensions=@(for ($i=0; $i -lt 2; $i++) {if ($evidence[$i]) {$extensions[$i]}})
            if ($extensions.Count -eq 0) {
                $result.Status='UNSUPPORTED'; $result.Reason='Selected build does not advertise TAP or T64 loading.'
                return $result
            }
            if (-not $evidence[2] -or -not $evidence[3]) {
                $result.Reason='Tape formats are listed, but the expected VICE Disk Control callbacks could not be verified.'
                return $result
            }
        } catch {$result.Reason=$_.Exception.Message; return $result}
    }
    $result.CanBuild=$true; $result.Status='SUPPORTED'; $result.Extensions=$extensions
    $result.Reason='VICE Disk Control ejects and attaches tape sides; TAP/T64 images are kept unchanged.'
    return $result
}
