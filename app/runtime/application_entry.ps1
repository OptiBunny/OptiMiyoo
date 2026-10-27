# Shared entry routing. A caller-controlled variable cannot bypass the boundary.
function Test-ApplicationWorker {
    $client='OptiMiyoo.ApplicationRpcClient' -as [type]
    return ($null -ne $client -and $client::IsIsolated)
}

function Get-ApplicationValidationRoot([string]$Path,[string]$Root) {
    if (-not (Test-ApplicationWorker)) {return $Root}
    $work=[IO.Path]::GetFullPath($env:OPTIMIYOO_SESSION_WORK).TrimEnd('\','/')
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if (-not $full.Equals($work,[StringComparison]::OrdinalIgnoreCase) -and -not $full.StartsWith($work+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'Application path is outside its owned work directory.'}
    $boundary=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if ($boundary.Length -lt $work.Length) {return $work}
    return $Root
}

function Enter-ApplicationHost {
    param([string]$ApplicationRoot,[ValidateSet('Playlist','C64','ZX','SD')][string]$Entry,[hashtable]$Arguments)
    $ErrorActionPreference='Stop'
    $temporary=$null
    try {
        . (Join-Path $ApplicationRoot 'app/shared/portable_storage.ps1')
        $temporary=Open-OptiPortableTempScope $ApplicationRoot
        . (Join-Path $ApplicationRoot 'app/runtime/application_host.ps1')
        return (Invoke-ApplicationHost -ApplicationRoot $ApplicationRoot -Entry $Entry -Arguments $Arguments)
    } catch {
        # exit(Enter-ApplicationHost ...) must receive a failure code, even when
        # bootstrap fails before the host's normal session error handler runs.
        $message=[regex]::Replace([string]$_.Exception.Message,'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]',' ')
        Write-Host ('OptiMiyoo could not start: '+$message) -ForegroundColor Red
        return 1
    } finally {if ($temporary) {Close-OptiPortableTempScope $temporary}}
}

function Resolve-ApplicationOutputSelection {
    param([ValidateSet('Playlist','C64','ZX')][string]$Operation,
          [string]$Storage,[string]$SingleStorage)
    if ($Storage -and ($Storage -notin 'Auto','Zip','Loose','Folders' -or ($Storage -eq 'Auto' -and $Operation -ne 'Playlist'))) {throw 'Unknown output storage.'}
    if ($Storage) {$Storage=@{Auto='Auto';Zip='Zip';Loose='Loose';Folders='Folders'}[$Storage]}
    if (-not $Storage) {
        $Storage='Zip';if ($Operation -eq 'ZX') {$Storage='Folders'}
    }
    $selection=@{Storage=$Storage}
    if ($Operation -eq 'Playlist') {
        if (-not $SingleStorage) {$SingleStorage='Auto'}
        if ($SingleStorage -notin 'Auto','Zip','Loose','Folders') {throw 'Unknown single-game storage.'}
        $selection.SingleStorage=@{Auto='Auto';Zip='Zip';Loose='Loose';Folders='Folders'}[$SingleStorage]
    }
    return $selection
}

function Read-ApplicationSourcePolicy {
    param([string]$Operation,[string]$System,[string]$Storage='Zip',[string]$SingleStorage='Auto')
    $output=Resolve-ApplicationOutputSelection -Operation $Operation -Storage $Storage -SingleStorage $SingleStorage
    $selection=@{Operation=$Operation;System=$System;Storage=$output.Storage}
    if ($Operation -eq 'Playlist') {$selection.SingleStorage=$output.SingleStorage}
    $reply=Invoke-ApplicationRpc -Operation Policy.Source -Payload $selection
    return [string]$reply.Choice
}

function Set-ApplicationCurrentJob([string]$SourceKey) {
    if (-not (Test-ApplicationWorker)) {return}
    $context=$global:OptiMiyooApplicationContext
    $key=$SourceKey.Replace('\','/')
    $context.CurrentJob=$null
    if ($context.JobIndex.ContainsKey($key)) {$context.CurrentJob=$context.JobIndex[$key]}
}

function Complete-ApplicationCurrentJob {
    if (-not (Test-ApplicationWorker)) {return}
    $context=$global:OptiMiyooApplicationContext
    if (-not $context.CurrentJob -or $context.CurrentJob.BlockedReason) {throw 'The broker did not authorize this output set.'}
    if ($context.CompletedSet.Add([string]$context.CurrentJob.JobId)) {[void]$context.Completed.Add([string]$context.CurrentJob.JobId)}
}

function Read-ApplicationOverwriteChoice {
    $context=$global:OptiMiyooApplicationContext
    if (-not $context.CurrentJob -or -not $context.CurrentJob.ConflictId) {throw 'Output conflict was not planned by the broker.'}
    $reply=Invoke-ApplicationRpc -Operation Policy.Overwrite -Payload @{BatchId=$context.BatchId;ConflictId=$context.CurrentJob.ConflictId}
    return @{Overwrite='Y';Skip='N';OverwriteAll='A';SkipAll='S'}[[string]$reply.Choice]
}

function Set-ApplicationBatchContext($Batch) {
    $index=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($job in @($Batch.Jobs)) {
        $key=$job.SourceKey.Replace('\','/')
        # An ambiguous source never acquires a job capability. Keep the same
        # exact-case matching while avoiding a full batch scan for every item.
        if ($index.ContainsKey($key)) {$index[$key]=$null} else {$index.Add($key,$job)}
    }
    $global:OptiMiyooApplicationContext=[pscustomobject]@{BatchId=$Batch.BatchId;WorkRoot=$Batch.WorkRoot;
        JobIndex=$index;CurrentJob=$null;
        Completed=(New-Object 'System.Collections.Generic.List[string]');CompletedSet=(New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))}
}

function Invoke-ApplicationMenuWorker([string]$Path,[hashtable]$Arguments) {
    $name=[IO.Path]::GetFileName($Path)
    $operation=switch ($name) {'make_playlists.ps1' {'Playlist'} 'convert_c64.ps1' {'C64'} 'convert_zx.ps1' {'ZX'} default {throw 'Unknown application worker.'}}
    $output=Resolve-ApplicationOutputSelection -Operation $operation -Storage $Arguments.Storage -SingleStorage $Arguments.SingleStorage
    $selection=@{Operation=$operation;System=$Arguments.System;Storage=$output.Storage}
    if ($operation -eq 'Playlist') {$selection.SingleStorage=$output.SingleStorage}
    $batch=Invoke-ApplicationRpc -Operation Batch.Begin -Payload $selection
    $jobs=New-Object 'System.Collections.Generic.List[object]';$offset=0
    do {
        $page=Invoke-ApplicationRpc -Operation Batch.Jobs -Payload @{BatchId=$batch.BatchId;Offset=$offset}
        foreach ($job in $page.Jobs) {$jobs.Add($job)}
        if ($jobs.Count -gt 20000 -or [int]$page.NextOffset -lt $offset -or ($page.More -and [int]$page.NextOffset -eq $offset)) {throw 'Invalid batch plan page.'}
        $offset=[int]$page.NextOffset
    } while ($page.More)
    $batch | Add-Member NoteProperty Jobs $jobs.ToArray()
    Set-ApplicationBatchContext $batch
    # All source removal happens in the parent after verified publication.
    $Arguments.Root=$batch.WorkRoot;$Arguments.SourcePolicy='Keep'
    $Arguments.Storage=$output.Storage
    if ($operation -eq 'Playlist') {$Arguments.SingleStorage=$output.SingleStorage}
    else {[void]$Arguments.Remove('SingleStorage')}
    Restore-Display
    try {& $Path @Arguments | Out-Host;$code=$LASTEXITCODE}
    catch {$code=1;Write-Host ('  ERROR: '+(ConvertTo-SafeExternalText $_.Exception.Message))}
    $null=Invoke-ApplicationRpc -Operation Batch.Complete -Payload @{BatchId=$batch.BatchId;CompletedJobIds=$global:OptiMiyooApplicationContext.Completed.ToArray()}
    return [int]$code
}
