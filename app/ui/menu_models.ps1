# Shared menu descriptions for the real chooser and the read-only demonstration.
# Profiles are supplied by the caller; building a model never reads SRC, DST or SD.
if (-not (Get-Command Get-PlaylistSupport -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '../onion/core_support.ps1')
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
        & $addRow '  S. Onion SD setup: enable supported file types / preserve selected cores' 'S. Onion SD setup / cores preserved'
        & $addRow '  C. Commodore 64: convert NIB/NBZ to G64' 'C. Commodore 64 / NIB/NBZ -> G64'
        & $addRow '  Z. ZX Spectrum: convert IPF to DSK' 'Z. ZX Spectrum / IPF -> DSK'
        & $addRow '  Support: standard Onion cores'
        $shortNames=@{AMIGA='Amiga'; COMMODORE='Commodore 64'; PS='PlayStation'; SEGACD='Sega CD / Mega-CD'; CPC='Amstrad CPC'; MSX='MSX / MSX2'; VIC20='VIC-20'; DOS='MS-DOS'; ZXS='ZX Spectrum'}
        for ($i=0;$i -lt $Profiles.Count;$i++) {
            $support=Get-PlaylistSupport $Profiles[$i] ''
            $label=Get-PlaylistFeatureLabel $support
            if ($label) {$label=' '+$label}
            $compact=('{0,2}. {1,-9} {2}{3}' -f ($i+1),$Profiles[$i].Folder,$shortNames[$Profiles[$i].Folder],$label)
            & $addRow ('  {0,2}. {1,-11} {2}{3}' -f ($i+1),$Profiles[$i].Folder,$Profiles[$i].Name,$label) $compact
        }
        & $addRow '  D. Demo / interactive walkthrough' 'D. Demo / interactive walkthrough'
        & $addRow ('  E. CRT effect: '+$crtState+' / turn on or off')
        & $addRow '  Q. Exit'
        $prompt='Choose a system number or letter [Enter = 1, Amiga]'
    } elseif ($Page -eq 'Demo') {
        $title='Demo / walkthrough';$default='1'
        & $addRow '  Demonstration only. No source, output or SD files are touched.'
        & $addRow '  1. Full walkthrough / every stage'
        & $addRow '  2. Commodore 64 / NIB, NBZ and G64 output'
        & $addRow '  3. ZX Spectrum / IPF, DSK and output choices'
        & $addRow '  4. Playlists / hidden media and disk order'
        & $addRow '  5. Results / overwrite, skip and error handling'
        & $addRow '  6. Bunny animation gallery'
        & $addRow '  7. Core support and Onion SD setup'
        & $addRow '  B. Back to main menu     Q. Exit'
        $prompt='Choose demo [Enter = 1]'
    } elseif ($Page -in 'C64','ZX') {
        $title='Commodore 64';$outputName='G64';$converterSystem='COMMODORE'
        if ($Page -eq 'ZX') {$title='ZX Spectrum';$outputName='DSK';$converterSystem='ZXS'}
        if ($Page -eq 'C64') {& $addRow '  Convert NIB/NBZ to G64.'}
        else {& $addRow '  Convert IPF to DSK.'}
        & $addRow '  Conversion only. Choose Keep or Remove on the next screen.'
        $converterProfile=@($Profiles | Where-Object {$_.Folder -eq $converterSystem})[0]
        $default='2';$zipNotice=Get-ZipOutputNotice $converterProfile -GameOutput
        $zipLabel=''; if ($zipNotice.Label) {$zipLabel=' '+$zipNotice.Label}
        & $addRow '  1. Auto / keep input layout'
        & $addRow ('  2. ZIPs (default) / one per game'+$zipLabel) ('2. ZIPs (default)'+$zipLabel)
        & $addRow '  3. Folders / one per game'
        & $addRow ('  4. Loose '+$outputName+' files')
        if ($zipNotice.Hint) {& $addRow ('  '+$zipNotice.Hint)}
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
            & $addRow '  Games with one disc or tape side stay visible in DST.'
            & $addRow '  Choose how to store them.'
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
            & $addRow ('  Single games: '+@{'1'='Auto / keep input layout';'2'='ZIPs';'3'='Folders';'4'='Loose files'}[$SingleOutput])
            & $addRow '  Choose how playlist media is stored in .hidden.'
            & $addRow '  Playlists stay outside .hidden.'
        }
        $default=if ($singlePage) {$SingleOutput} else {$HiddenOutput}
        $zipNotice=Get-ZipOutputNotice $Profile -GameOutput:$singlePage
        $zipLabel=''; if ($zipNotice.Label) {$zipLabel=' '+$zipNotice.Label}
        $autoDefault=if ($default -eq '1') {' (default)'} else {''}
        $zipDefault=if ($default -eq '2') {' (default)'} else {''}
        $folderDefault=if ($default -eq '3') {' (default)'} else {''}
        $looseDefault=if ($default -eq '4') {' (default)'} else {''}
        & $addRow ('  1. Auto'+$autoDefault+' / keep input layout')
        & $addRow ('  2. ZIPs'+$zipDefault+' / one per game'+$zipLabel) ('2. ZIPs'+$zipDefault+$zipLabel)
        & $addRow ('  3. Folders'+$folderDefault+' / one per game')
        & $addRow ('  4. Loose files'+$looseDefault)
        if ($zipNotice.Hint) {& $addRow ('  '+$zipNotice.Hint)}
        if ($singlePage) {
            & $addRow '  Next: storage for playlist media in .hidden.'
            & $addRow '  B. Back to main menu     Q. Exit'
            $prompt='Choose single-game storage'
        } else {
            if ($support.Status -eq 'UNSUPPORTED') {& $addRow ('  '+$coreName+' cannot load playlists.')}
            elseif ($zipNotice.Label -and $support.CanBuild) {& $addRow '  Choose Folders or Loose files for playlists.'}
            & $addRow '  Next: choose Keep or Remove originals.'
            & $addRow '  B. Back to single games     Q. Exit'
            $prompt='Choose storage in .hidden'
        }
        $prompt+=' [Enter = '+$default+']'
    }
    [pscustomobject]@{Title=$title;Rows=$rows.ToArray();TextRows=$textRows.ToArray();Prompt=$prompt;Default=$default}
}
