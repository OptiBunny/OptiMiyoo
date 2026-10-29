# These prompts run only in the trusted parent. The confined application can
# request a known prompt, but cannot supply its text, defaults or answer.
. (Join-Path $PSScriptRoot '../ui/display.ps1')
. (Join-Path $PSScriptRoot '../shared/overwrite_prompt.ps1')

function Get-ApplicationPromptTitle {
    param([Parameter(Mandatory=$true)][ValidateSet('Playlist','C64','ZX','SD')][string]$Operation,
          [string]$System,[ValidateSet('Auto','Zip','Loose','Folders')][string]$Storage='Zip')
    $systems=@{AMIGA='Amiga';COMMODORE='Commodore 64';PS='PlayStation';SEGACD='Sega CD';
        CPC='Amstrad CPC';MSX='MSX';VIC20='VIC-20';DOS='MS-DOS';ZXS='ZX Spectrum'}
    $storageName=@{Auto='Auto / keep input layout';Zip='ZIP output';Loose='Loose files';Folders='Folder per game'}[$Storage]
    switch($Operation) {
        'Playlist' {
            if(-not $systems.ContainsKey($System)){throw 'Unknown playlist system in trusted prompt.'}
            return ($systems[$System]+' / output settings')
        }
        'C64' {
            if($System -and $System -cne 'COMMODORE'){throw 'Invalid C64 prompt system.'}
            return ('Commodore 64 / '+$storageName)
        }
        'ZX' {
            if($System -and $System -cne 'ZXS'){throw 'Invalid ZX prompt system.'}
            return ('ZX Spectrum / '+$storageName)
        }
        'SD' {
            if($System){throw 'SD setup does not accept a system override.'}
            return 'Onion SD setup'
        }
    }
}

function ConvertTo-ApplicationPromptPath([string]$Path) {
    if([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 32767){throw 'Invalid parent conflict path.'}
    # Preserve the identity of unusual characters without emitting terminal or
    # bidirectional controls. This spelling is for display, never filesystem use.
    return [regex]::Replace($Path,'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]',{
        param($match) '\u{0:X4}' -f [int][char]$match.Value
    })
}

function Get-ApplicationPromptModel {
    param([Parameter(Mandatory=$true)][ValidateSet('SourcePolicy','Overwrite')][string]$Kind,
          [Parameter(Mandatory=$true)][ValidateSet('Playlist','C64','ZX','SD')][string]$Operation,[string]$System,
          [ValidateSet('Auto','Zip','Loose','Folders')][string]$Storage='Zip',
          [ValidateSet('Auto','Zip','Loose','Folders')][string]$SingleStorage='Auto',
          [string[]]$ConflictPaths=@(),[switch]$Folder,[int]$Page=0,[switch]$Invalid)
    $title=Get-ApplicationPromptTitle $Operation $System $Storage
    if($Kind -eq 'SourcePolicy' -and $Operation -eq 'SD'){throw 'SD setup cannot remove source media.'}
    if($Kind -ne 'Overwrite' -and $ConflictPaths.Count){throw 'Unexpected conflict paths in a policy prompt.'}
    if($Kind -eq 'SourcePolicy') {
        $lines=@()
        if ($Operation -eq 'Playlist') {
            $names=@{Auto='Auto / keep input layout';Zip='ZIPs';Folders='Folders';Loose='Loose files'}
            $lines+=@(('Single games: '+$names[$SingleStorage]),('Playlist media: '+$names[$Storage]))
        }
        $lines+=@('Finished game files go to DST.','',
            '1. KEEP originals in SRC (default)',
            '   Leave source files in place.','',
            '2. REMOVE originals after verified success',
            '   Check saved output before source removal.',
            'Skipped or failed items keep their originals.','',
            'Choosing 1 or 2 starts the batch.',
            'B. Back to output settings     Q. Exit')
        if($Invalid){$lines+='Choose 1, 2, B or Q.'}
        return [pscustomobject]@{Title=($title+' / originals');Lines=$lines;Prompt='Choose originals [Enter = 1, Keep]';Page=0;Pages=1}
    }
    if($Operation -eq 'SD'){throw 'SD setup does not use output overwrite authority.'}
    if(-not $ConflictPaths.Count -or $ConflictPaths.Count -gt 20000){throw 'A bounded parent conflict list is required.'}
    $details=New-Object 'System.Collections.Generic.List[string]';$characters=0
    for($index=0;$index -lt $ConflictPaths.Count;$index++) {
        $remaining=ConvertTo-ApplicationPromptPath $ConflictPaths[$index]
        $characters+=$remaining.Length;if($characters -gt 1048576){throw 'Conflict display exceeds its text limit.'}
        $details.Add(('Output {0} of {1}:' -f ($index+1),$ConflictPaths.Count))
        do {$chunk=Get-TextPrefix $remaining 42;$details.Add('| '+$chunk);$remaining=$remaining.Substring($chunk.Length)} while($remaining.Length)
    }
    $fixed=@('Skipped originals stay in SRC.')
    if($Folder){$fixed+='Replacing a folder replaces ALL its contents.'}
    $fixed+=@('')+@(Get-OverwriteChoiceRows)
    $prompt=Get-OverwriteInputPrompt
    if($Invalid){$fixed+='Choose one of the shown options.'}
    # Leave room for the blank top row and trusted input in a 19-row window.
    # Only path details paginate; choices and the folder warning remain visible.
    $fixed=@(Get-MenuRows $fixed 44);$pageSize=11-$fixed.Count-2
    if($pageSize -lt 1){throw 'Trusted overwrite prompt cannot fit its choices.'}
    $pages=[Math]::Max(1,[int][Math]::Ceiling($details.Count/[double]$pageSize))
    $page=[Math]::Max(0,[Math]::Min($Page,$pages-1));$lines=@('Existing output paths:')
    for($row=0;$row -lt $pageSize;$row++) {
        $at=$page*$pageSize+$row
        if($at -lt $details.Count){$lines+=$details[$at]}else{$lines+=''}
    }
    $lines+=('Page {0}/{1} | > Next | < Previous' -f ($page+1),$pages);$lines+=$fixed
    return [pscustomobject]@{Title=($title+' / existing output');Lines=$lines;Prompt=$prompt;Page=$page;Pages=$pages}
}

function Read-ApplicationConsoleChoice($Model,$Session=$null) {
    if($Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        throw 'Trusted policy choices require the parent console; redirected child answers are not accepted.'
    }
    $text='';$caret=0;$dirty=$true
    $sparseIdle=(-not $NoAnimation -and $script:UiVT)
    $idleWatch=$null;$script:UiIdlePoseOverride=$null
    Reset-MioSparseCrt
    if($sparseIdle){Reset-MioIdleInput;$idleWatch=[Diagnostics.Stopwatch]::StartNew()}
    [void](Update-DisplaySize)
    $rows=@($Model.Lines);$layout=Get-MenuLayout -Rows $rows
    if(-not $script:UiVT) {
        [Console]::WriteLine($Model.Title)
        foreach($line in $Model.Lines){[Console]::WriteLine($line)}
        [Console]::Write($Model.Prompt+': ')
    }
    try {while($true) {
        if(Update-DisplaySize -Throttled){$layout=Get-MenuLayout -Rows $rows;$dirty=$true}
        $bunnyVisible=($script:UiVT -and $layout.Fits -and $layout.ShowMio)
        if($sparseIdle) {
            $pose=Get-MioIdlePose $idleWatch.Elapsed.TotalMilliseconds ($text.Length -gt 0 -or -not $bunnyVisible)
            if($pose -cne $script:UiIdlePoseOverride){$script:UiIdlePoseOverride=$pose;$dirty=$true}
        }
        if(Update-MioSparseCrt $script:UiEffectClock.Elapsed.TotalMilliseconds ($text.Length -gt 0) $bunnyVisible){$dirty=$true}
        $fits=(-not $script:UiVT -or $layout.Fits)
        if($script:UiVT -and $dirty) {
            Draw-MenuPanel $Model.Title $rows $Model.Prompt $text $caret 'wait'
            $dirty=$false
        }
        if([Console]::KeyAvailable) {
            $key=[Console]::ReadKey($true)
            if($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                if($Session){$Session.Stop()}
                throw [OperationCanceledException]::new('Application cancelled.')
            }
            if($sparseIdle){$idleWatch.Restart();Reset-MioIdleInput;$script:UiIdlePoseOverride='idle';$dirty=$true}
            if($key.Key -eq [ConsoleKey]::Escape){return 'B'}
            if(-not $fits) {
                if([char]::ToUpperInvariant($key.KeyChar) -eq 'Q'){return 'Q'}
                continue
            }
            if($key.Key -eq [ConsoleKey]::Enter){if(-not $script:UiVT){[Console]::WriteLine()};return $text.Trim().ToUpperInvariant()}
            if($key.Key -eq [ConsoleKey]::Backspace -and $text.Length){$text=$text.Substring(0,(Get-InputCaretOffset $text $text.Length -1))}
            elseif(-not [char]::IsControl($key.KeyChar) -and $text.Length -lt 16){$text+=[string]$key.KeyChar}
            $caret=$text.Length;$dirty=$true
            if(-not $script:UiVT){[Console]::Write("`r"+$Model.Prompt+': '+$text+' ')}
        } else {Wait-DisplayFrame 30}
    }} finally {$script:UiIdlePoseOverride=$null;Reset-MioSparseCrt;if($idleWatch){$idleWatch.Stop()}}
}

function Invoke-ApplicationPolicyPrompt {
    param([Parameter(Mandatory=$true)]$Session,
          [Parameter(Mandatory=$true)][ValidateSet('SourcePolicy','Overwrite')][string]$Kind,
          [Parameter(Mandatory=$true)][ValidateSet('Playlist','C64','ZX','SD')][string]$Operation,[string]$System,
          [ValidateSet('Auto','Zip','Loose','Folders')][string]$Storage='Zip',
          [ValidateSet('Auto','Zip','Loose','Folders')][string]$SingleStorage='Auto',
          [string[]]$ConflictPaths=@(),[switch]$Folder,
          [switch]$NoAnimation,[switch]$NoColor,
          [ValidateSet('CRT','Smooth')][string]$DisplayEffect='CRT')
    # Validate before taking terminal ownership. Callers must resolve conflict
    # capabilities through the host broker; never pass child-supplied filenames.
    $parameters=@{Kind=$Kind;Operation=$Operation;System=$System;Storage=$Storage;SingleStorage=$SingleStorage;ConflictPaths=$ConflictPaths;Folder=$Folder}
    $model=Get-ApplicationPromptModel @parameters
    $paused=$false;$display=$false;$result=$null;$previousEffect=$script:DisplayEffect
    try {
        [void]$Session.PauseRelay()
        if(-not $Session.IsRelayPaused){throw 'The application relay did not surrender the parent console.'}
        $paused=$true
        $script:DisplayEffect=$DisplayEffect
        Initialize-Display;$display=$true
        $invalid=$false;$page=0
        while($true) {
            $model=Get-ApplicationPromptModel @parameters -Page $page -Invalid:$invalid
            $answer=Read-ApplicationConsoleChoice $model -Session $Session
            if($Kind -eq 'Overwrite' -and $answer -in '<','>') {
                if($answer -eq '>'){$page=[Math]::Min($model.Pages-1,$model.Page+1)}else{$page=[Math]::Max(0,$model.Page-1)}
                continue
            }
            $choice=$null;$policy=$null;$navigation=$null;$selectedStorage=$Storage
            if($Kind -eq 'SourcePolicy') {
                switch($answer){''{$choice='Keep';$policy='Keep'}'1'{$choice='Keep';$policy='Keep'}'2'{$choice='Remove';$policy='Remove'}'B'{$choice='Back';$navigation='Back'}'Q'{$choice='Exit';$navigation='Exit'}}
            } else {
                $choice=ConvertFrom-OverwriteAnswer $answer
            }
            if($choice) {
                $result=[pscustomobject]@{Kind=$Kind;Answer=$answer;Choice=$choice;SourcePolicy=$policy;Storage=$selectedStorage;SingleStorage=$SingleStorage;Navigation=$navigation}
                break
            }
            $invalid=$true
        }
    } finally {
        try {if($display){Restore-Display}}
        finally {
            $script:DisplayEffect=$previousEffect
            if($paused -and -not $Session.CancellationRequested) {
                if($Session.HasExited){throw 'The isolated application exited before the policy choice could be delivered.'}
                [void]$Session.ResumeRelay()
            }
        }
    }
    # A failed resume/drain never releases a policy grant to the caller.
    return $result
}
