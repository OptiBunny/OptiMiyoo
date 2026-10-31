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
    . (Join-Path $PSScriptRoot '../shared/source_policy.ps1')
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

function Get-OnionExtensionValueSpan([string]$Raw) {
    # Walk JSON tokens rather than searching text: escaped names and unrelated
    # nested extlist properties must never redirect the config edit. Token
    # alternatives are disjoint; nesting and the caller's byte limit bound work.
    $token=New-Object regex('\G[ \t\r\n]*(?:(?<String>"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*")|(?<Number>-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)|(?<Literal>true|false|null)|(?<Punctuation>[{}\[\],:])|(?<End>\z))')
    $stack=New-Object 'Collections.Generic.List[object]'
    $position=0;if($Raw.Length -gt 0 -and $Raw[0] -eq [char]0xFEFF){$position=1}
    $rootSeen=$false;$target=$null
    while($true) {
        $match=$token.Match($Raw,$position)
        if(-not $match.Success){throw 'SD config contains malformed JSON.'}
        if($match.Groups['End'].Success){break}
        $position=$match.Index+$match.Length
        $punctuation=$match.Groups['Punctuation'].Value
        $string=$match.Groups['String']
        if($stack.Count -eq 0) {
            if($rootSeen -or $punctuation -cne '{'){throw 'SD config must contain one JSON object.'}
            $rootSeen=$true
            $stack.Add(@{Kind='Object';State='KeyOrEnd';Key=$null;Keys=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))})
            continue
        }
        $frame=$stack[$stack.Count-1]
        if($frame.Kind -ceq 'Object') {
            if($frame.State -in 'KeyOrEnd','Key') {
                if($frame.State -ceq 'KeyOrEnd' -and $punctuation -ceq '}'){$stack.RemoveAt($stack.Count-1);continue}
                if(-not $string.Success){throw 'SD config contains an invalid JSON property.'}
                $key=[regex]::Unescape($string.Value.Substring(1,$string.Length-2))
                if(-not $frame['Keys'].Add($key)){throw 'SD config contains duplicate or ambiguous JSON property names.'}
                $frame.Key=$key;$frame.State='Colon';continue
            }
            if($frame.State -ceq 'Colon') {
                if($punctuation -cne ':'){throw 'SD config contains an invalid JSON property separator.'}
                $frame.State='Value';continue
            }
            if($frame.State -ceq 'CommaOrEnd') {
                if($punctuation -ceq '}'){$stack.RemoveAt($stack.Count-1);continue}
                if($punctuation -cne ','){throw 'SD config contains an invalid JSON object separator.'}
                $frame.State='Key';continue
            }
            if($stack.Count -eq 1 -and $frame.Key -ceq 'extlist') {
                if(-not $string.Success){throw 'SD config extension list must be a JSON string.'}
                $target=[pscustomobject]@{Start=($string.Index+1);End=($string.Index+$string.Length-1);Value=[regex]::Unescape($string.Value.Substring(1,$string.Length-2))}
            }
        } else {
            if($frame.State -ceq 'ValueOrEnd' -and $punctuation -ceq ']'){$stack.RemoveAt($stack.Count-1);continue}
            if($frame.State -ceq 'CommaOrEnd') {
                if($punctuation -ceq ']'){$stack.RemoveAt($stack.Count-1);continue}
                if($punctuation -cne ','){throw 'SD config contains an invalid JSON array separator.'}
                $frame.State='Value';continue
            }
        }
        $frame.State='CommaOrEnd'
        if($string.Success -or $match.Groups['Number'].Success -or $match.Groups['Literal'].Success){continue}
        if($punctuation -cnotin '{','['){throw 'SD config contains an invalid JSON value.'}
        if($stack.Count -ge 64){throw 'SD config exceeds the supported JSON nesting depth.'}
        if($punctuation -ceq '{'){$stack.Add(@{Kind='Object';State='KeyOrEnd';Key=$null;Keys=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))})}
        else {$stack.Add(@{Kind='Array';State='ValueOrEnd'})}
    }
    if(-not $rootSeen -or $stack.Count -ne 0 -or $null -eq $target){throw 'SD config does not contain one unambiguous top-level extension list.'}
    return $target
}

function Get-OnionConfigExtensionData([byte[]]$Original) {
    if($Original.Length -gt 1048576){throw 'config.json exceeds the supported 1 MiB text limit.'}
    $utf8=New-Object Text.UTF8Encoding($false,$true);$raw=$utf8.GetString($Original)
    $value=Get-OnionExtensionValueSpan $raw
    $config=$raw.TrimStart([char]0xFEFF) | ConvertFrom-Json
    if($config.extlist -isnot [string] -or $config.extlist -cne $value.Value){throw 'SD config does not have a valid top-level extension list.'}
    return [pscustomobject]@{Raw=$raw;Span=$value;Encoding=$utf8}
}

function Get-OnionConfigPatch([byte[]]$Original,[string[]]$Extensions,[string[]]$RemoveExtensions=@()) {
    # Only the extlist string contents may change. Retained tokens keep their
    # literal JSON spelling; launcher settings and unrelated bytes stay intact.
    $data=Get-OnionConfigExtensionData $Original
    $raw=$data.Raw;$value=$data.Span;$utf8=$data.Encoding
    $remove=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($extension in $RemoveExtensions){
        if($extension -cnotmatch '\A[A-Za-z0-9]+\z'){throw 'Invalid SD file-list extension.'}
        [void]$remove.Add($extension)
    }
    foreach($extension in $Extensions){
        if($extension -cnotmatch '\A[A-Za-z0-9]+\z'){throw 'Invalid SD file-list extension.'}
        if($remove.Contains($extension)){throw 'An SD file-list extension cannot be both added and removed.'}
    }
    $encoded=$raw.Substring($value.Start,$value.End-$value.Start);$retained=$encoded;$decoded=$value.Value
    if($remove.Count -gt 0) {
        $keptRaw=New-Object Text.StringBuilder;$keptValue=New-Object Text.StringBuilder
        # Skip complete JSON escapes before looking for the next separator.
        # A literal \\u007c is token text; an actual \u007c escape is a pipe.
        $separator=New-Object regex('(?<Pipe>\||\\u007[cC])|\\(?:u[0-9a-fA-F]{4}|["\\/bfnrt])')
        $match=$separator.Match($encoded);$start=0;$prefix='';$kept=0
        while($true) {
            while($match.Success -and -not $match.Groups['Pipe'].Success){$match=$match.NextMatch()}
            $end=$encoded.Length;if($match.Success){$end=$match.Index}
            $token=$encoded.Substring($start,$end-$start);$tokenValue=[regex]::Unescape($token)
            if(-not $remove.Contains($tokenValue)) {
                # Keep the separator immediately preceding each retained token,
                # except the first, which no longer needs a leading separator.
                if($kept -gt 0){[void]$keptRaw.Append($prefix);[void]$keptValue.Append('|')}
                [void]$keptRaw.Append($token);[void]$keptValue.Append($tokenValue);$kept++
            }
            if(-not $match.Success){break}
            $prefix=$match.Value;$start=$match.Index+$match.Length;$match=$match.NextMatch()
        }
        $retained=$keptRaw.ToString();$decoded=$keptValue.ToString()
    }
    $existing=@($decoded -split '\|')
    $missing=@($Extensions | Where-Object {$_ -notin $existing})
    if($missing.Count -eq 0 -and $retained -ceq $encoded){return ,$Original}
    $addition=$missing -join '|'
    if($addition.Length -gt 0 -and $decoded.Length -gt 0){$addition='|'+$addition}
    $updated=$raw.Remove($value.Start,$value.End-$value.Start).Insert($value.Start,$retained+$addition)
    $checked=$updated.TrimStart([char]0xFEFF) | ConvertFrom-Json
    if($checked.extlist -cne ($decoded+$addition)){throw 'SD extension-list patch did not change the intended top-level value.'}
    return ,$utf8.GetBytes($updated)
}

function Get-OnionSetupExtensionState([byte[]]$Original,[string[]]$Extensions) {
    $data=Get-OnionConfigExtensionData $Original
    $requested=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($extension in $Extensions){
        if($extension -cnotmatch '\A[A-Za-z0-9]+\z'){throw 'Invalid SD file-list extension.'}
        [void]$requested.Add($extension)
    }
    $present=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($extension in @($data.Span.Value -split '\|')){[void]$present.Add($extension)}
    $found=0;foreach($extension in $requested){if($present.Contains($extension)){$found++}}
    if($found -eq 0){return 'Off'}
    if($found -eq $requested.Count){return 'On'}
    return 'Partial'
}

function Get-OnionSetupProfiles([string]$CodeRoot=(Split-Path -Parent $PSScriptRoot)) {
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
    $emuFolder=$Profile.Folder
    if ($Profile.EmuFolder) {$emuFolder=$Profile.EmuFolder}
    $result=[pscustomobject]@{ConfigPath=$null;EmuFolder=$emuFolder;CanBuild=$false;Status='UNVERIFIED';Reason='No SD root was supplied.'}
    if (-not $SdRoot) {return $result}
    $lease=$null;$memory=$null
    try {
        # Setup recognizes fixed system file-list additions. It does not assess
        # the user's launcher or whether an installed core can load those files.
        $null=@(Get-OnionSetupExtensions $Profile)
        $result.ConfigPath=Join-Path (Join-Path (Join-Path $SdRoot 'Emu') $emuFolder) 'config.json'
        Assert-PlainOnionPath $result.ConfigPath $SdRoot
        if (-not (Test-Path -LiteralPath $result.ConfigPath -PathType Leaf)) {
            $result.Status='NOT INSTALLED';$result.Reason='No system config.json found on this SD card.';return $result
        }
        $lease=Open-OptiInputLease $result.ConfigPath $SdRoot
        if ($lease.Stream.Length -gt 1MB) {throw 'config.json exceeds the supported 1 MiB text limit.'}
        $memory=New-Object IO.MemoryStream
        $lease.Stream.CopyTo($memory)
        # Reuse the strict byte-level patch validation without adding anything.
        $null=Get-OnionConfigPatch -Original $memory.ToArray() -Extensions @()
        $result.CanBuild=$true;$result.Status='READY';$result.Reason='Installed config has a valid file-type list.'
    } catch {$result.Status='UNVERIFIED';$result.Reason=$_.Exception.Message}
    finally {try {if ($memory) {$memory.Dispose()}} finally {if ($lease) {$lease.Dispose()}}}
    return $result
}

function Get-OnionSetupExtensions($Profile,[string]$SdRoot,$Support) {
    # Keep the optional arguments for existing callers; setup additions do not
    # depend on launcher selection, core binaries or playback support checks.
    switch ([string]$Profile.Folder) {
        'DOS' {'m3u8';return}
        'COMMODORE' {'m3u';'tap';'t64';return}
        'LYNX' {'lyx';return}
        {$_ -in 'AMIGA','MSX','PS','SEGACD','VIC20','CPC','ZXS'} {'m3u';return}
        default {throw 'Unknown SD setup system profile.'}
    }
}

function Get-OnionSetupMenuRows {
    @(
        'Enables supported files in Onion''s game list.',
        'Only edits config.json''s file-type list.',
        'SD config backups: Backups/OptiMiyoo_Backup_<ID>/Emu/',
        'Does not install or switch emulator cores.',
        'Refresh Onion''s game list after setup.',
        '',
        '1. Amiga: enables .m3u playlists / PUAE2021, PUAE',
        '2. C64: enables .m3u playlists + .tap/.t64 tapes',
        '   VICE x64 / x64sc',
        '3. MS-DOS: enables .m3u8 playlists / DOSBox Pure',
        '4. MSX / MSX2: enables .m3u playlists / blueMSX',
        '5. PlayStation: enables .m3u playlists / PCSX ReARMed',
        '6. Sega CD: enables .m3u playlists / PicoDrive, Genesis Plus GX',
        '7. VIC-20: enables .m3u playlists / VICE xvic',
        '8. CPC: enables .m3u playlists / Caprice32',
        '   Default CrocoDS cannot load playlists.',
        '9. ZX: enables .m3u playlists / newer Fuse with M3U support',
        '   Default Onion Fuse cannot load playlists.',
        '10. Lynx: enables .lyx games / Handy, Beetle Lynx'
    )
}

function Get-PlaylistFeatureLabel($Support) {
    if ($Support.CanBuild) {return ''}
    return '[playlists unsupported]'
}

function Get-ZipOutputNotice($Profile,[switch]$GameOutput) {
    # Menu compatibility always describes the standard Onion profile.
    # ZIP games and archive#member playlist links are separate capabilities.
    $notice=[pscustomobject]@{Label='';Hint=''}
    $coreName='the default core'
    if ($Profile.PSObject.Properties['Core'] -and $Profile.Core) {$coreName=$Profile.Core}
    elseif ($Profile.PSObject.Properties['DefaultCore'] -and $Profile.DefaultCore) {$coreName=$Profile.DefaultCore -replace '_libretro\.so$',''}
    if (-not $GameOutput) {
        $memberSupport=$Profile.PSObject.Properties['ZipMemberPlaylist']
        if ($null -eq $memberSupport -or $memberSupport.Value -isnot [bool]) {
            $notice.Label='[ZIP playlists unverified]'
            $notice.Hint='Playlists pointing inside ZIPs are unverified for '+$coreName+'.'
        } elseif (-not $memberSupport.Value) {
            $notice.Label='[ZIP playlists unsupported]'
            $notice.Hint=$coreName+' cannot follow playlist links inside ZIPs.'
        }
        return $notice
    }
    $zipSupport=$Profile.PSObject.Properties['DefaultZipSupport']
    if ($zipSupport -and $zipSupport.Value -eq 'Unsupported') {
        $notice.Label='[ZIP games unsupported]'
        $notice.Hint='ZIP games are not supported in the default Onion setup.'
        if ($Profile.PSObject.Properties['DefaultZipReason']) {$notice.Hint=$Profile.DefaultZipReason}
    } elseif ($null -eq $zipSupport -or $zipSupport.Value -notin 'Documented','UserVerified') {
        $notice.Label='[ZIP games unverified]'
        $notice.Hint='Onion''s docs do not list ZIP games for this default core.'
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
