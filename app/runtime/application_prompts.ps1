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
    return ConvertTo-SafeExternalLine $Path
}

function New-ApplicationPromptPreparation {
    param([Parameter(Mandatory=$true)][ValidateSet('SourcePolicy','Overwrite')][string]$Kind,
          [Parameter(Mandatory=$true)][ValidateSet('Playlist','C64','ZX','SD')][string]$Operation,[string]$System,
          [ValidateSet('Auto','Zip','Loose','Folders')][string]$Storage='Zip',
          [ValidateSet('Auto','Zip','Loose','Folders')][string]$SingleStorage='Auto',
          [string[]]$ConflictPaths=@(),[switch]$Folder)
    $title=Get-ApplicationPromptTitle $Operation $System $Storage
    if($Kind -eq 'SourcePolicy' -and $Operation -eq 'SD'){throw 'SD setup cannot remove source media.'}
    if($Kind -ne 'Overwrite' -and $ConflictPaths.Count){throw 'Unexpected conflict paths in a policy prompt.'}
    if($Kind -eq 'SourcePolicy') {
        $lines=@()
        if ($Operation -eq 'Playlist') {
            $names=@{Auto='Auto / keep input layout';Zip='ZIPs';Folders='Folders';Loose='Loose files'}
            $lines+=@(('Single games: '+$names[$SingleStorage]),('Playlist media: '+$names[$Storage]))
        }
        $lines+=@(Get-OptiOriginalsRows)
        return [pscustomobject]@{Kind=$Kind;Title=($title+' / originals');Lines=$lines}
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
    # This copied display state belongs to one trusted prompt invocation. It is
    # never accepted from a worker or exposed through a prompt/RPC parameter.
    return [pscustomobject]@{Kind=$Kind;Title=($title+' / existing output');Details=$details.ToArray();Folder=[bool]$Folder}
}

function Get-ApplicationPreparedPromptModel {
    param([Parameter(Mandatory=$true)]$Preparation,[int]$Page=0,[switch]$Invalid)
    if($Preparation.Kind -eq 'SourcePolicy') {
        $lines=@($Preparation.Lines)
        if($Invalid){$lines+='Choose 1, 2, B or Q.'}
        return [pscustomobject]@{Title=$Preparation.Title;Lines=$lines;Prompt='Choose originals [Enter = 1, Keep]';Page=0;Pages=1}
    }
    $details=$Preparation.Details
    $fixed=@('Skipped originals stay in SRC.')
    if($Preparation.Folder){$fixed+='Replacing a folder replaces ALL its contents.'}
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
    return [pscustomobject]@{Title=$Preparation.Title;Lines=$lines;Prompt=$prompt;Page=$page;Pages=$pages}
}

function Get-ApplicationPromptModel {
    param([Parameter(Mandatory=$true)][ValidateSet('SourcePolicy','Overwrite')][string]$Kind,
          [Parameter(Mandatory=$true)][ValidateSet('Playlist','C64','ZX','SD')][string]$Operation,[string]$System,
          [ValidateSet('Auto','Zip','Loose','Folders')][string]$Storage='Zip',
          [ValidateSet('Auto','Zip','Loose','Folders')][string]$SingleStorage='Auto',
          [string[]]$ConflictPaths=@(),[switch]$Folder,[int]$Page=0,[switch]$Invalid)
    $preparation=New-ApplicationPromptPreparation -Kind $Kind -Operation $Operation -System $System -Storage $Storage -SingleStorage $SingleStorage -ConflictPaths $ConflictPaths -Folder:$Folder
    return Get-ApplicationPreparedPromptModel $preparation -Page $Page -Invalid:$Invalid
}

function Read-ApplicationConsoleChoice($Model,$Session=$null,[switch]$ReturnOnResize,[string]$InitialText='',[string]$EscapeValue='B',[string[]]$ImmediateChoices=@(),[switch]$LiteralRows) {
    if($Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        throw 'Trusted policy choices require the parent console; redirected child answers are not accepted.'
    }
    $text=$InitialText;$caret=$text.Length;$dirty=$true
    $sparseIdle=(-not $NoAnimation -and $script:UiVT)
    $idleWatch=$null;$script:UiIdlePoseOverride=$null
    Reset-MioSparseCrt
    if($sparseIdle){Reset-MioIdleInput;$idleWatch=[Diagnostics.Stopwatch]::StartNew()}
    $initialResize=Update-DisplaySize
    $rows=@($Model.Lines);$layout=Get-MenuLayout -Rows $rows -Prompt $Model.Prompt -LiteralRows:$LiteralRows
    if(-not $script:UiVT) {
        [Console]::WriteLine($Model.Title)
        foreach($line in @(Get-PlainMenuRows $Model.Lines -Prompt $Model.Prompt -LiteralRows:$LiteralRows)){[Console]::WriteLine($line)}
        $plainPrompt='INPUT >'
        [Console]::Write($plainPrompt+' ')
    }
    try {
    if($ReturnOnResize -and $script:UiVT -and $initialResize){return [pscustomobject]@{Resized=$true;InputText=$text}}
    while($true) {
        if(Update-DisplaySize -Throttled){
            if($ReturnOnResize -and $script:UiVT){return [pscustomobject]@{Resized=$true;InputText=$text}}
            $layout=Get-MenuLayout -Rows $rows -Prompt $Model.Prompt -LiteralRows:$LiteralRows;$dirty=$true
        }
        $bunnyVisible=($script:UiVT -and $layout.Fits -and $layout.ShowMio)
        if($sparseIdle) {
            $pose=Get-MioIdlePose $idleWatch.Elapsed.TotalMilliseconds ($text.Length -gt 0 -or -not $bunnyVisible)
            if($pose -cne $script:UiIdlePoseOverride){$script:UiIdlePoseOverride=$pose;$dirty=$true}
        }
        if(Update-MioSparseCrt $script:UiEffectClock.Elapsed.TotalMilliseconds ($text.Length -gt 0) $bunnyVisible){$dirty=$true}
        $fits=(-not $script:UiVT -or $layout.Fits)
        if($script:UiVT -and $dirty) {
            Draw-MenuPanel $Model.Title $rows $Model.Prompt $text $caret 'wait' -LiteralRows:$LiteralRows
            $dirty=$false
        }
        if([Console]::KeyAvailable) {
            $key=[Console]::ReadKey($true)
            if($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                if($Session){$Session.Stop()}
                throw [OperationCanceledException]::new('Application cancelled.')
            }
            if($sparseIdle){$idleWatch.Restart();Reset-MioIdleInput;$script:UiIdlePoseOverride='idle';$dirty=$true}
            if($key.Key -eq [ConsoleKey]::Escape){return $EscapeValue}
            if(-not $text.Length -and [string][char]::ToUpperInvariant($key.KeyChar) -in $ImmediateChoices){return ([string][char]::ToUpperInvariant($key.KeyChar))}
            if($script:UiVT -and $key.Key -eq [ConsoleKey]::Enter -and (Update-DisplaySize)){
                if($ReturnOnResize){return [pscustomobject]@{Resized=$true;InputText=$text}}
                $layout=Get-MenuLayout -Rows $rows -Prompt $Model.Prompt -LiteralRows:$LiteralRows;$dirty=$true;continue
            }
            if(-not $fits) {
                if([char]::ToUpperInvariant($key.KeyChar) -eq 'Q'){return 'Q'}
                if([char]::ToUpperInvariant($key.KeyChar) -eq 'B'){return 'B'}
                continue
            }
            if($key.Key -eq [ConsoleKey]::Enter){if(-not $script:UiVT){[Console]::WriteLine()};return $text.Trim().ToUpperInvariant()}
            if($script:UiVT) {
                if($key.Key -eq [ConsoleKey]::Backspace -and $caret -gt 0){$previous=Get-InputCaretOffset $text $caret -1;$next=Get-InputCaretOffset $text $previous 1;$text=$text.Remove($previous,$next-$previous);$caret=$previous}
                elseif($key.Key -eq [ConsoleKey]::Delete -and $caret -lt $text.Length){$next=Get-InputCaretOffset $text $caret 1;$previous=Get-InputCaretOffset $text $next -1;$text=$text.Remove($previous,$next-$previous);$caret=$previous}
                elseif($key.Key -eq [ConsoleKey]::LeftArrow){$caret=Get-InputCaretOffset $text $caret -1}
                elseif($key.Key -eq [ConsoleKey]::RightArrow){$caret=Get-InputCaretOffset $text $caret 1}
                elseif($key.Key -eq [ConsoleKey]::Home){$caret=0}
                elseif($key.Key -eq [ConsoleKey]::End){$caret=$text.Length}
                elseif(-not [char]::IsControl($key.KeyChar) -and $text.Length -lt 16){$text=$text.Insert($caret,[string]$key.KeyChar);$caret++}
            } else {
                if($key.Key -eq [ConsoleKey]::Backspace -and $text.Length){$text=$text.Substring(0,(Get-InputCaretOffset $text $text.Length -1))}
                elseif(-not [char]::IsControl($key.KeyChar) -and $text.Length -lt 16){$text+=[string]$key.KeyChar}
                $caret=$text.Length
            }
            $dirty=$true
            if(-not $script:UiVT){[Console]::Write("`r"+$plainPrompt+' '+$text+' ')}
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
    $preparation=New-ApplicationPromptPreparation @parameters
    $model=Get-ApplicationPreparedPromptModel $preparation
    $paused=$false;$display=$false;$result=$null;$previousEffect=$script:DisplayEffect
    try {
        [void]$Session.PauseRelay()
        if(-not $Session.IsRelayPaused){throw 'The application relay did not surrender the parent console.'}
        $paused=$true
        $script:DisplayEffect=$DisplayEffect
        Initialize-Display;$display=$true
        $invalid=$false;$page=0
        while($true) {
            $model=Get-ApplicationPreparedPromptModel $preparation -Page $page -Invalid:$invalid
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
                if($choice -in 'Back','Exit'){$navigation=$choice}
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

# Final result pages belong to the parent after the worker relay has stopped.
# Keep long paths and per-file results available through the same resize-aware
# pager used by SD results, rather than printing over a retained worker frame.
function New-ApplicationResultLayout {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string[]]$SourceLines,[Parameter(Mandatory=$true)][string]$Title,
          [string[]]$SectionHeadings=@())
    $prompt='Enter / B / Esc: Main menu | Q: Exit'
    # Let the shared renderer reclaim artwork or paragraph gaps before paging.
    # Without an initialized viewport, retain the conservative minimum panel.
    $textWidth=44;$pageSize=11
    if($script:UiColumns -ge 44 -and $script:UiHeight -gt 0) {
        $whole=Get-MenuLayout -Rows $sourceLines -Prompt $prompt -LiteralRows
        if($whole.Fits) {
            return [pscustomobject]@{Title=$title;PageList=@([pscustomobject]@{Rows=@($whole.Rows);Anchor=0L});Prompt=$prompt;TextWidth=$whole.TextWidth;PageSize=$whole.BodyRows}
        }
        $empty=Get-MenuLayout -Rows @('') -LiteralRows
        $textWidth=$empty.TextWidth
        $overhead=8
        if($empty.ShowMio -and $script:UiHeight -ge 26){$overhead=14}
        $wrappedCount=@(Get-MenuRows $sourceLines $textWidth).Count
        $navigationRows=@(Get-MenuRows @(('Page {0}/{0} | > Next | < Previous' -f $wrappedCount)) $textWidth).Count
        $pageSize=[Math]::Max(3,$script:UiHeight-$overhead-$navigationRows)
    }
    # Keep section headings with their first data row. Logical character anchors
    # retain the current part of a long report when resize changes its wrapping.
    $pageRows=New-Object 'Collections.Generic.List[string]'
    $pageList=New-Object 'Collections.Generic.List[object]'
    $separator=$false;$offset=0L;$pageAnchor=0L
    foreach ($line in $sourceLines) {
        if (-not $line) {$separator=($pageRows.Count -gt 0);continue}
        $wrapped=@(Get-MenuRows @($line) $textWidth)
        $needed=1
        if ($line -in $SectionHeadings) {$needed=$wrapped.Count+1}
        $gap=0;if ($separator -and $pageRows.Count) {$gap=1}
        if ($pageRows.Count -and $pageRows.Count+$gap+$needed -gt $pageSize) {
            $pageList.Add([pscustomobject]@{Rows=$pageRows.ToArray();Anchor=$pageAnchor});$pageRows.Clear();$pageAnchor=$offset
        }
        if ($separator -and $pageRows.Count) {$pageRows.Add('')}
        $separator=$false
        foreach ($row in $wrapped) {
            if ($pageRows.Count -eq $pageSize) {$pageList.Add([pscustomobject]@{Rows=$pageRows.ToArray();Anchor=$pageAnchor});$pageRows.Clear();$pageAnchor=$offset}
            $pageRows.Add($row);$offset+=($row -replace '\s','').Length
        }
    }
    if ($pageRows.Count -or -not $pageList.Count) {$pageList.Add([pscustomobject]@{Rows=$pageRows.ToArray();Anchor=$pageAnchor})}
    return [pscustomobject]@{Title=$title;PageList=$pageList.ToArray();Prompt=$prompt;TextWidth=$textWidth;PageSize=$pageSize}
}

function Get-ApplicationResultPage {
    param([Parameter(Mandatory=$true)]$Layout,[int]$Page=0,[long]$Anchor=-1)
    $pageList=$Layout.PageList;$title=$Layout.Title;$prompt=$Layout.Prompt
    $textWidth=$Layout.TextWidth;$pageSize=$Layout.PageSize
    $pages=$pageList.Count
    $page=[Math]::Max(0,[Math]::Min($Page,$pages-1))
    if($Anchor -ge 0) {
        $page=0
        for($index=1;$index -lt $pages -and $pageList[$index].Anchor -le $Anchor;$index++){$page=$index}
    }
    $lines=@($pageList[$page].Rows)
    if ($pages -gt 1) {$lines+=('Page {0}/{1} | > Next | < Previous' -f ($page+1),$pages)}
    [pscustomobject]@{Title=$title;Lines=$lines;Prompt=$prompt;Page=$page;Pages=$pages;Anchor=$pageList[$page].Anchor;TextWidth=$textWidth;PageSize=$pageSize}
}

function Get-ApplicationResultModel {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string[]]$SourceLines,[Parameter(Mandatory=$true)][string]$Title,
          [int]$Page=0,[long]$Anchor=-1,[string[]]$SectionHeadings=@())
    $layout=New-ApplicationResultLayout -SourceLines $SourceLines -Title $Title -SectionHeadings $SectionHeadings
    Get-ApplicationResultPage -Layout $layout -Page $Page -Anchor $Anchor
}

function Read-ApplicationResult {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string[]]$Lines,[Parameter(Mandatory=$true)][string]$Title,
          [string[]]$SectionHeadings=@(),[switch]$NoAnimation,[switch]$NoColor,
          [ValidateSet('CRT','Smooth')][string]$DisplayEffect='CRT')
    $previousEffect=$script:DisplayEffect;$display=$false;$page=0;$anchor=-1L;$inputText='';$previousControlC=$null
    $resultLayout=$null;$layoutKey=$null
    try {
        if($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected){
            $previousControlC=[Console]::TreatControlCAsInput;[Console]::TreatControlCAsInput=$true
        }
        $script:DisplayEffect=$DisplayEffect
        Initialize-Display;$display=$true
        while ($true) {
            [void](Update-DisplaySize)
            $currentKey=('{0}|{1}|{2}' -f $script:UiColumns,$script:UiHeight,$script:UiWidth)
            if($null -eq $resultLayout -or $currentKey -cne $layoutKey) {
                # Retain only this active screen and viewport, never resize history.
                $resultLayout=$null
                $resultLayout=New-ApplicationResultLayout -SourceLines $Lines -Title $Title -SectionHeadings $SectionHeadings
                $layoutKey=$currentKey
            }
            $model=Get-ApplicationResultPage -Layout $resultLayout -Page $page -Anchor $anchor
            $answer=Read-ApplicationConsoleChoice $model -ReturnOnResize -InitialText $inputText -EscapeValue 'B' -ImmediateChoices @('B','Q','>','<') -LiteralRows
            if($answer -isnot [string] -and $answer.Resized) {$page=$model.Page;if($anchor -lt 0){$anchor=$model.Anchor};$inputText=$answer.InputText;continue}
            $inputText='';$anchor=-1L
            if ($answer -in '', 'B') {return $true}
            if ($answer -eq 'Q') {return $false}
            if ($answer -eq '>') {$page=[Math]::Min($model.Page+1,$model.Pages-1)}
            elseif ($answer -eq '<') {$page=[Math]::Max(0,$model.Page-1)}
            else {$page=$model.Page}
        }
    }catch [OperationCanceledException] {
        # At this point the batch is finished; Ctrl+C simply exits its results.
        return $false
    }finally {
        try {if ($display) {Restore-Display}}
        finally {
            $resultLayout=$null
            $script:DisplayEffect=$previousEffect
            if($null -ne $previousControlC){[Console]::TreatControlCAsInput=$previousControlC}
        }
    }
}

function Write-ApplicationResultText {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string[]]$Lines)
    # NoPause and redirected callers keep ordinary stream output and do not
    # initialize a new interactive display or consume input.
    foreach($line in $Lines){Write-Host $line}
}
