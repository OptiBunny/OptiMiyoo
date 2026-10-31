# Shared menu descriptions for the real chooser and the read-only demonstration.
# Profiles are supplied by the caller; building a model never reads SRC, DST or SD.
if (-not (Get-Command Get-PlaylistSupport -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '../onion/core_support.ps1')
}

function Get-OnionSetupPathRows {
    @('Enable playlists, C64 tapes and Atari Lynx .lyx files',
      'in Onion''s game list.','',
      'Choose your SD card''s drive or main folder below.',
      'OptiMiyoo reads its config files to see what is enabled.','',
      'Next, review the settings and choose what to enable or disable.',
      'Nothing is saved until you choose Apply.','',
      'Esc. Back to main menu')
}

function Get-OnionSetupChecklistModel {
    param([Parameter(Mandatory=$true)][object[]]$Items,[string]$Message='')
    $rows=New-Object 'Collections.Generic.List[string]'
    $rows.Add('On adds the listed types; Off removes them from the game list.')
    $rows.Add('Other file types, games and emulator cores stay unchanged.')
    $rows.Add('[x] On    [ ] Off    [-] Partly enabled    [--] Unavailable')
    $rows.Add('')
    $available=@($Items | Where-Object {$_.Available});$all=' '
    if($available.Count -and @($available | Where-Object {$_.State -ne 'On'}).Count -eq 0){$all='x'}
    elseif(@($available | Where-Object {$_.State -in 'On','Partial'}).Count){$all='-'}
    $rows.Add(('1. [{0}] Toggle all installed systems' -f $all))
    $index=-1
    foreach($line in @(Get-OnionSetupMenuRows)) {
        if($line -match '^\d+\. (.+)$') {
            $index++;$item=$Items[$index];$description=$Matches[1].Replace(': enables ',': ')
            $mark=switch($item.State){'On'{'x'}'Off'{' '}'Partial'{'-'}default{'--'}}
            if(-not $item.Available){$description=($description -split ':',2)[0]+': '+$item.Reason}
            $rows.Add(('{0}. [{1}] {2}' -f ($index+2),$mark,$description))
        } elseif($index -ge 0 -and $line) {$rows.Add($line)}
    }
    $rows.Add('')
    $rows.Add('Apply saves changes and backs up changed configs.')
    $rows.Add('Refresh Onion''s game list afterwards.')
    $rows.Add('A. Apply (default)     Esc. Cancel without saving')
    $prompt='Type a number to toggle / Enter: Apply / Esc: Cancel'
    if($Message){$prompt=$Message}
    [pscustomobject]@{Title='Onion SD setup / file types';Lines=[string[]]$rows.ToArray();Prompt=$prompt}
}

function Get-OptiOriginalsRows {
    # The demo and trusted prompt describe the same choices. This helper only
    # returns text; confirmation and source-removal authority stay in the parent.
    return @('Finished game files go to DST.','',
        '1. KEEP originals in SRC (default)',
        '   Leave source files in place.','',
        '2. REMOVE originals after verified success',
        '   Check saved output before source removal.',
        'Skipped or failed items keep their originals.','',
        'Choosing 1 or 2 starts the batch.',
        'B. Back to output settings     Q. Exit')
}

function Get-OptiStorageDefaults {
    param([Parameter(Mandatory=$true)]$Profile)
    $single='2'; if ($Profile.Folder -in 'CPC','PS','SEGACD') {$single='4'}
    $hidden='2'; if ($Profile.Folder -in 'DOS','MSX','PS','SEGACD','CPC','ZXS') {$hidden='3'}
    [pscustomobject]@{Single=$single;Hidden=$hidden}
}

function Get-OptiMenuModel {
    param([Parameter(Mandatory=$true)][ValidateSet('Main','Demo','C64','ZX','SingleStorage','Storage')][string]$Page,
          [object[]]$Profiles=@(),$Profile,
          [ValidateSet('','1','2','3','4')][string]$SingleOutput='',
          [ValidateSet('','1','2','3','4')][string]$HiddenOutput='',
          [ValidateSet('CRT','Smooth')][string]$DisplayEffect='CRT')
    $rows=New-Object 'System.Collections.Generic.List[string]'
    $textRows=New-Object 'System.Collections.Generic.List[string]'
    # Keep plain-console wording and compact terminal wording byte-for-byte alike
    # across callers, including the existing indentation of unchanged rows.
    $addRow={param([string]$Text,[string]$Compact='')
        $textRows.Add($Text)
        if ($Compact) {$rows.Add($Compact)} else {$rows.Add($Text)}
    }
    $title='';$prompt='';$default=''
    if ($Page -eq 'Main') {
        $title='Main menu';$default='1'
        $crtState=if ($DisplayEffect -eq 'CRT') {'On'} else {'Off'}
        & $addRow '  S. Onion SD setup: choose file types / preserve selected cores'
        & $addRow '  C. Commodore 64: convert NIB/NBZ to G64' 'C. Commodore 64 / NIB/NBZ -> G64'
        & $addRow '  Z. ZX Spectrum: convert IPF to DSK' 'Z. ZX Spectrum / IPF -> DSK'
        & $addRow ''
        & $addRow '  Numbered systems: build playlists / standard Onion cores'
        $shortNames=@{AMIGA='Amiga'; COMMODORE='Commodore 64'; PS='PlayStation'; SEGACD='Sega CD / Mega-CD'; CPC='Amstrad CPC'; MSX='MSX / MSX2'; VIC20='VIC-20'; DOS='MS-DOS'; ZXS='ZX Spectrum'}
        for ($i=0;$i -lt $Profiles.Count;$i++) {
            $support=Get-PlaylistSupport $Profiles[$i] ''
            $label=Get-PlaylistFeatureLabel $support
            if ($label) {$label=' '+$label}
            $compact=('{0,2}. {1,-9} {2}{3}' -f ($i+1),$Profiles[$i].Folder,$shortNames[$Profiles[$i].Folder],$label)
            & $addRow ('  {0,2}. {1,-11} {2}{3}' -f ($i+1),$Profiles[$i].Folder,$Profiles[$i].Name,$label) $compact
        }
        & $addRow ''
        & $addRow '  D. Demo / interactive walkthrough, no files changed'
        & $addRow ('  E. CRT effect: '+$crtState+' / turn on or off')
        & $addRow '  Q. Exit'
        $prompt='Choose a system number or letter [Enter = 1, Amiga]'
    } elseif ($Page -eq 'Demo') {
        $title='Demo / walkthrough';$default='1'
        & $addRow '  Demonstration only. No source, output or SD files are touched.'
        & $addRow '  Explore example menus, progress and results by topic.'
        & $addRow ''
        & $addRow '  1. Full walkthrough / every stage'
        & $addRow '  2. Commodore 64 / NIB/NBZ -> G64, storage and originals'
        & $addRow '  3. ZX Spectrum / IPF -> DSK, storage and originals'
        & $addRow '  4. Playlists / single games, hidden media and disk order'
        & $addRow '  5. Results / overwrite, skip and error handling'
        & $addRow '  6. Bunny animation gallery'
        & $addRow '  7. Core support and Onion SD setup'
        & $addRow ''
        & $addRow '  B. Back to main menu     Q. Exit'
        $prompt='Choose demo [Enter = 1]'
    } elseif ($Page -in 'C64','ZX') {
        $title='Commodore 64';$outputName='G64';$converterSystem='COMMODORE'
        if ($Page -eq 'ZX') {$title='ZX Spectrum';$outputName='DSK';$converterSystem='ZXS'}
        $inputName=if ($Page -eq 'C64') {'NIB/NBZ'} else {'IPF'}
        & $addRow ('  Input: '+$inputName+' or '+$outputName+' images in SRC.')
        & $addRow '  Read images from ZIPs, folders or individual files.'
        & $addRow ''
        & $addRow ('  Output: '+$inputName+' -> '+$outputName+' images in DST.')
        & $addRow ('  Existing '+$outputName+' images are copied without conversion.')
        & $addRow '  Build playlists separately with a numbered main-menu choice.'
        & $addRow ''
        $converterProfile=@($Profiles | Where-Object {$_.Folder -eq $converterSystem})[0]
        $default='2';$zipNotice=Get-ZipOutputNotice $converterProfile -GameOutput
        $zipLabel=''; if ($zipNotice.Label) {$zipLabel=' '+$zipNotice.Label}
        & $addRow '  1. Auto / keep input layout'
        & $addRow '     ZIPs stay zipped; folders and loose paths are preserved.'
        & $addRow ('  2. ZIPs (default) / one archive per game'+$zipLabel)
        & $addRow '  3. Folders / unpack into one folder per game'
        & $addRow ('  4. Loose '+$outputName+' files / no added game folder')
        if ($zipNotice.Hint) {& $addRow ''; & $addRow ('  '+$zipNotice.Hint)}
        & $addRow ''
        & $addRow '  Next: choose Keep or Remove originals in SRC.'
        & $addRow '  B. Back to main menu     Q. Exit'
        $prompt='Choose output [Enter = 2]'
    } else {
        if ($null -eq $Profile) {throw 'A profile is required for storage menu descriptions.'}
        $defaults=Get-OptiStorageDefaults $Profile
        if (-not $SingleOutput) {$SingleOutput=$defaults.Single}
        if (-not $HiddenOutput) {$HiddenOutput=$defaults.Hidden}
        $singlePage=$Page -eq 'SingleStorage'
        $title=$Profile.Name+' / playlist media'
        if ($singlePage) {$title=$Profile.Name+' / single games'}
        $support=Get-PlaylistSupport $Profile ''
        $coreName=$support.Core; if ($support.Core -eq $Profile.DefaultCore) {$coreName=$Profile.Core}
        & $addRow ('  '+$Profile.Folder+' / '+$coreName)
        if ($singlePage) {
            & $addRow ''
            & $addRow '  One disc or tape side: visible in DST, outside .hidden.'
            & $addRow '  These games launch directly, without a playlist.'
            & $addRow '  Multi-disc and multi-side storage is a separate choice next.'
        } else {
            $playlistLabel=Get-PlaylistFeatureLabel $support
            if ($playlistLabel) {& $addRow ('  '+$playlistLabel)}
            if ($Profile.Folder -eq 'COMMODORE') {
                $tapeSupport=Get-TapeSwapSupport $Profile '' $support
                $tapeFormats='TAP, T64'
                if ($tapeSupport.CanBuild) {$tapeFormats=(@($tapeSupport.Extensions | ForEach-Object {$_.TrimStart('.').ToUpperInvariant()}) -join ', ')}
                $tapeLabel=''; if (-not $tapeSupport.CanBuild) {$tapeLabel=' ['+$tapeSupport.Status.ToLowerInvariant()+']'}
                & $addRow ('  Tape swapping: '+$tapeFormats+$tapeLabel)
                if (-not $tapeSupport.CanBuild) {& $addRow ('  '+$tapeSupport.Reason)}
            }
            & $addRow ''
            & $addRow ('  Single games stay visible: '+@{'1'='Auto / keep input layout';'2'='ZIPs';'3'='Folders';'4'='Loose files'}[$SingleOutput])
            & $addRow '  Multi-disc / multi-side media goes in DST/.hidden.'
            & $addRow '  Playlists stay visible above .hidden to launch each game.'
        }
        & $addRow '  Image formats stay unchanged by playlist processing.'
        & $addRow ''
        $default=if ($singlePage) {$SingleOutput} else {$HiddenOutput}
        $zipNotice=Get-ZipOutputNotice $Profile -GameOutput:$singlePage
        $zipLabel=''; if ($zipNotice.Label) {$zipLabel=' '+$zipNotice.Label}
        $autoDefault=if ($default -eq '1') {' (default)'} else {''}
        $zipDefault=if ($default -eq '2') {' (default)'} else {''}
        $folderDefault=if ($default -eq '3') {' (default)'} else {''}
        $looseDefault=if ($default -eq '4') {' (default)'} else {''}
        & $addRow ('  1. Auto'+$autoDefault+' / keep input layout')
        & $addRow '     ZIPs stay zipped; folders and loose paths are preserved.'
        & $addRow ('  2. ZIPs'+$zipDefault+' / one archive per game'+$zipLabel)
        & $addRow ('  3. Folders'+$folderDefault+' / unpack into one folder per game')
        & $addRow ('  4. Loose files'+$looseDefault+' / no added game folder')
        if ($zipNotice.Hint) {& $addRow ''; & $addRow ('  '+$zipNotice.Hint)}
        if ($singlePage) {
            & $addRow ''
            & $addRow '  Next: storage for playlist media in .hidden.'
            & $addRow '  B. Back to main menu     Q. Exit'
            $prompt='Choose single-game storage'
        } else {
            if ($support.Status -eq 'UNSUPPORTED') {& $addRow ('  '+$coreName+' cannot load playlists.')}
            elseif ($zipNotice.Label -and $support.CanBuild) {& $addRow '  Choose Folders or Loose files for playlists.'}
            & $addRow ''
            & $addRow '  Next: choose Keep or Remove originals.'
            & $addRow '  B. Back to single games     Q. Exit'
            $prompt='Choose storage in .hidden'
        }
        $prompt+=' [Enter = '+$default+']'
    }
    [pscustomobject]@{Title=$title;Rows=$rows.ToArray();TextRows=$textRows.ToArray();Prompt=$prompt;Default=$default}
}
