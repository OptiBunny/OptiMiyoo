# Shared overwrite questions use a bounded body even for long conflict lists.
function Get-OverwritePathRows([string[]]$Paths) {
    for ($index=0;$index -lt $Paths.Count;$index++) {
        'Output {0} of {1}:' -f ($index+1),$Paths.Count
        $remaining=$Paths[$index]
        do {
            # A visible prefix preserves spaces at chunk boundaries when the
            # menu wraps its rows. Never truncate a filename or split a grapheme.
            $chunk=Get-TextPrefix $remaining 42
            '| '+$chunk
            $remaining=$remaining.Substring($chunk.Length)
        } while ($remaining.Length -gt 0)
    }
}

function Read-OverwriteChoice([string]$Title,[string[]]$Paths,[string[]]$Warnings,
                              [string[]]$Choices,[string]$Prompt) {
    # 44 cells is the menu text width at the supported 76-column minimum.
    # Keep twelve body rows so every page also fits a 19-row terminal.
    $fixed=@(Get-MenuRows (@($Warnings)+@($Choices)) 44)
    $pageSize=12-$fixed.Count-2
    if ($pageSize -lt 1) {throw 'Overwrite choices leave no space for destination paths.'}
    $details=@(Get-OverwritePathRows $Paths)
    if ($details.Count -eq 0) {$details=@('(No destination paths supplied.)')}
    $pageCount=[Math]::Max(1,[int][Math]::Ceiling($details.Count/[double]$pageSize))
    $page=0
    while ($true) {
        $lines=@('Existing output paths:')
        $start=$page*$pageSize
        for ($row=0;$row -lt $pageSize;$row++) {
            if ($start+$row -lt $details.Count) {$lines+=$details[$start+$row]}
            else {$lines+=''}
        }
        $lines+=('Page {0}/{1} | > Next | < Previous' -f ($page+1),$pageCount)
        $lines+=$fixed
        $answer=([string](Read-DisplayInput $Prompt $Title $lines 'wait')).Trim()
        if ($answer -eq '>') {$page=[Math]::Min($pageCount-1,$page+1); continue}
        if ($answer -eq '<') {$page=[Math]::Max(0,$page-1); continue}
        return $answer
    }
}
