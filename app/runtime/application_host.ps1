# This is the small trusted coordinator. The interface and processing scripts
# execute in a zero-capability AppContainer using disposable SRC/DST snapshots.
. (Join-Path $PSScriptRoot 'application_entry.ps1')
. (Join-Path $PSScriptRoot 'application_session.ps1')
. (Join-Path $PSScriptRoot 'application_staging.ps1')
. (Join-Path $PSScriptRoot 'application_broker.ps1')
. (Join-Path $PSScriptRoot 'application_jobs.ps1')
. (Join-Path $PSScriptRoot 'application_archive.ps1')
. (Join-Path $PSScriptRoot 'application_prompts.ps1')
. (Join-Path $PSScriptRoot 'application_sd.ps1')

function ConvertFrom-ApplicationPayload([string]$Json) {
    # Bound parser nesting before ConvertFrom-Json sees a hostile frame.
    $depth=0;$quoted=$false;$escaped=$false
    foreach ($character in $Json.ToCharArray()) {
        if ($quoted) {
            if ($escaped) {$escaped=$false}
            elseif ($character -eq '\') {$escaped=$true}
            elseif ($character -eq '"') {$quoted=$false}
        } elseif ($character -eq '"') {$quoted=$true}
        elseif ($character -eq '{' -or $character -eq '[') {$depth++;if ($depth -gt 16) {throw 'Application request nesting limit exceeded.'}}
        elseif ($character -eq '}' -or $character -eq ']') {$depth--;if ($depth -lt 0) {throw 'Malformed application request.'}}
    }
    if ($quoted -or $depth -ne 0) {throw 'Malformed application request.'}
    return (ConvertFrom-Json -InputObject $Json)
}

function Get-ApplicationSelection {
    param($Payload)
    $operation=[string]$Payload.Operation;$system=[string]$Payload.System
    $storage=[string]$Payload.Storage
    if ($operation -notin 'Playlist','C64','ZX' -or $storage -notin 'Auto','Zip','Loose','Folders') {throw 'Unknown application selection.'}
    if ($operation -eq 'Playlist' -and $system -notin 'AMIGA','COMMODORE','PS','SEGACD','CPC','MSX','VIC20','DOS','ZXS') {throw 'Unknown playlist system.'}
    if ($operation -eq 'C64') {$system='COMMODORE'}
    if ($operation -eq 'ZX') {$system='ZXS'}
    $output=Resolve-ApplicationOutputSelection -Operation $operation -Storage $storage -SingleStorage ([string]$Payload.SingleStorage)
    $selection=@{Operation=$operation;System=$system;Storage=$output.Storage}
    if ($operation -eq 'Playlist') {$selection.SingleStorage=$output.SingleStorage}
    return $selection
}

function Invoke-ApplicationHostRequest {
    param($State,$Request)
    $payload=ConvertFrom-ApplicationPayload $Request.Payload
    if ($State.StopRequested) {throw 'The application session has completed.'}
    switch -Exact ($Request.Operation) {
        'Policy.Source' {
            if ($State.Broker.ActiveBatch -or $State.Completed) {throw 'A batch is already active.'}
            $selection=Get-ApplicationSelection $payload
            $choice=Invoke-ApplicationPolicyPrompt -Session $State.Session -Kind SourcePolicy @selection -DisplayEffect $State.DisplayEffect -NoAnimation:([bool]$State.NoAnimation) -NoColor:([bool]$State.NoColor)
            $State.Grant=$null
            if ($choice.SourcePolicy) {$selection.SourcePolicy=$choice.SourcePolicy;$State.Grant=$selection}
            return @{Choice=$choice.Choice}
        }
        'Batch.Begin' {
            if (-not $State.Grant -or $State.Completed) {throw 'Select the batch policy in the trusted prompt first.'}
            $selection=Get-ApplicationSelection $payload
            foreach ($key in 'Operation','System','Storage','SingleStorage') {if ($selection[$key] -cne $State.Grant[$key]) {throw 'Batch does not match the approved selection.'}}
            $selection.SourcePolicy=$State.Grant.SourcePolicy;$State.Grant=$null
            $State.BatchView=Start-ApplicationBrokerBatch -Session $State.Broker @selection -Existing $State.Existing
            return @{BatchId=$State.BatchView.BatchId;WorkRoot=$State.BatchView.WorkRoot;Operation=$State.BatchView.Operation;JobCount=$State.BatchView.Jobs.Count}
        }
        'Batch.Jobs' {
            if (-not $State.BatchView -or [string]$payload.BatchId -cne $State.BatchView.BatchId -or ($payload.Offset -isnot [int] -and $payload.Offset -isnot [long])) {throw 'Invalid batch page.'}
            $offset=[long]$payload.Offset;$total=$State.BatchView.Jobs.Count
            if ($offset -lt 0 -or $offset -gt $total) {throw 'Invalid batch page offset.'}
            $rows=New-Object 'System.Collections.Generic.List[object]';$next=$offset;$bytes=2
            while ($next -lt $total -and $rows.Count -lt 200) {
                $row=$State.BatchView.Jobs[$next]
                $length=[Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $row -Depth 6 -Compress))
                if ($rows.Count) {$length++}
                if ($bytes+$length -gt 524288) {break}
                $rows.Add($row);$bytes+=$length;$next++
            }
            if ($next -eq $offset -and $next -lt $total) {throw 'Batch row exceeds its response limit.'}
            return @{Jobs=$rows.ToArray();NextOffset=$next;More=($next -lt $total)}
        }
        'Policy.Overwrite' {
            $batch=$State.Broker.ActiveBatch
            if (-not $batch -or [string]$payload.BatchId -cne $batch.BatchId) {throw 'Unknown overwrite batch.'}
            $conflict=Get-ApplicationBrokerConflict $State.Broker $batch.BatchId ([string]$payload.ConflictId)
            $choice=$conflict.Decision
            if ($choice -eq 'Pending') {
                $prompt=Invoke-ApplicationPolicyPrompt -Session $State.Session -Kind Overwrite -Operation $batch.Operation -System $batch.System -Storage $batch.Storage -SingleStorage $batch.SingleStorage -ConflictPaths $conflict.Paths -Folder:$conflict.Folder -DisplayEffect $State.DisplayEffect -NoAnimation:([bool]$State.NoAnimation) -NoColor:([bool]$State.NoColor)
                $choice=$prompt.Choice
                Set-ApplicationBrokerOverwrite $State.Broker $batch.BatchId $conflict.ConflictId $choice
            }
            if ($choice -notin 'Overwrite','Skip','OverwriteAll','SkipAll') {throw 'Invalid overwrite decision.'}
            return @{Choice=$choice}
        }
        'Batch.Complete' {
            if ($State.Completed) {throw 'Application batch was already completed.'}
            $ids=@($payload.CompletedJobIds)
            if ($ids.Count -gt 20000) {throw 'Too many completed jobs.'}
            foreach ($id in $ids) {if ($id -isnot [string] -or $id -cnotmatch '^[0-9a-f]{32}$') {throw 'Invalid completed job capability.'}}
            if (-not $State.Broker.ActiveBatch -or [string]$payload.BatchId -cne $State.Broker.ActiveBatch.BatchId) {throw 'Unknown completion batch.'}
            $State.Pending=@{BatchId=[string]$payload.BatchId;CompletedJobIds=[string[]]$ids}
            $State.StopRequested=$true
            return @{Accepted=$true}
        }
        'SD.Select' {
            if ($State.Broker.ActiveBatch) {throw 'Finish the active batch first.'}
            $root=Invoke-ApplicationSdFolderPrompt -Session $State.Session -DisplayEffect $State.DisplayEffect -NoAnimation:([bool]$State.NoAnimation) -NoColor:([bool]$State.NoColor)
            if (-not $root) {return @{Cancelled=$true}}
            $State.NextOnionRoot=$root;$State.StopRequested=$true
            return @{Accepted=$true}
        }
        'Display.Preference' {
            $preference=[string]$payload.Preference
            if ($preference -notin 'CRT','Smooth') {throw 'Unknown display preference.'}
            $State.DisplayEffect=$preference
            return @{Accepted=$true}
        }
        {$_ -in 'Native.Start','Native.Read','Native.Stop'} {
            return (Invoke-ApplicationNativeRequest -State $State.Native -BrokerSession $State.Broker -Operation $Request.Operation -Payload $payload)
        }
        {$_ -in 'Archive.Start','Archive.Read','Archive.Stop'} {
            return (Invoke-ApplicationArchiveRequest -BrokerSession $State.Broker -Operation $Request.Operation -Payload $payload -ReceiptStore $State.Receipts)
        }
        default {throw 'The application requested an unsupported broker operation.'}
    }
}

function Invoke-ApplicationHostLoop($State) {
    $session=$State.Session
    while (-not $session.HasExited) {
        if ($session.Failure) {throw $session.Failure}
        $request=$session.ReadRequest(100)
        if (-not $request) {continue}
        $success=$true;$result=$null
        try {$result=Invoke-ApplicationHostRequest $State $request}
        catch {$success=$false;$result=@{error=$_.Exception.Message}}
        $json=ConvertTo-Json -InputObject $result -Depth 24 -Compress
        $session.Respond($request.Id,$success,$json)
        if ($State.StopRequested) {
            # No app thread survives the final handoff. Files remain staged until
            # publication has finished; Dispose removes only this session's files.
            $session.Stop()
            if (-not $session.WaitForExit(5000)) {throw 'The isolated application did not stop; originals kept.'}
            return 0
        }
    }
    if ($session.Failure) {throw $session.Failure}
    return $session.ExitCode
}

function Write-ApplicationBootstrap {
    param($Session,[string]$Entry,[hashtable]$Arguments,$Batch)
    $scriptName=@{Playlist='app/playlists/make_playlists.ps1';C64='app/C64/convert_c64.ps1';ZX='app/ZX/convert_zx.ps1';SD='app/onion/prepare_onion.ps1'}[$Entry]
    $config=@{Entry=$scriptName;Arguments=$Arguments;Batch=$Batch}
    $encoding=New-Object Text.UTF8Encoding($true)
    [IO.File]::WriteAllText((Join-Path $Session.CodePath 'launch.json'),(ConvertTo-Json -InputObject $config -Depth 16 -Compress),$encoding)
    $boot=@'
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'app/runtime/application_session.ps1')
. (Join-Path $PSScriptRoot 'app/runtime/application_entry.ps1')
if (-not (Test-ApplicationWorker)) {throw 'The application did not start inside its required boundary.'}
$config=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'launch.json') -Raw | ConvertFrom-Json
if ($config.Entry -ne 'app/onion/prepare_onion.ps1') {
    . (Join-Path $PSScriptRoot 'app/runtime/application_jobs.ps1')
    . (Join-Path $PSScriptRoot 'app/runtime/application_archive.ps1')
}
$parameters=@{}
foreach ($property in $config.Arguments.PSObject.Properties) {$parameters[$property.Name]=$property.Value}
if ($config.Batch) {Set-ApplicationBatchContext $config.Batch}
$code=1
try {& (Join-Path $PSScriptRoot $config.Entry) @parameters;$code=$LASTEXITCODE}
catch {Write-Host ('ERROR: '+$_.Exception.Message);$code=1}
if ($config.Batch) {
    try {
        $null=Invoke-ApplicationRpc -Operation Batch.Complete -Payload @{BatchId=$config.Batch.BatchId;CompletedJobIds=$global:OptiMiyooApplicationContext.Completed.ToArray()}
    } catch {Write-Host 'The batch could not be completed. Check DST before retrying.';$code=1}
}


exit $code
'@
    [IO.File]::WriteAllText((Join-Path $Session.CodePath 'boot.ps1'),($boot -replace '\r?\n',"`r`n"),$encoding)
}

function Write-ApplicationVerifiedReport([string]$Root,$Result) {
    $lease=$null;$csvStream=$null;$logStream=$null;$csvWriter=$null;$logWriter=$null
    $stamp=(Get-Date -Format 'yyyyMMdd_HHmmss_fff')+'_'+[Guid]::NewGuid().ToString('N').Substring(0,8)
    $csv=Join-Path $Root ('OptiMiyoo_'+$stamp+'.csv');$log=Join-Path $Root ('OptiMiyoo_'+$stamp+'.log')
    try {
        $lease=Open-SourcePolicyDirectoryLease $Root
        $csvStream=[IO.File]::Open($csv,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $csvWriter=New-Object IO.StreamWriter($csvStream,(New-Object Text.UTF8Encoding($true)))
        $logStream=[IO.File]::Open($log,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $logWriter=New-Object IO.StreamWriter($logStream,(New-Object Text.UTF8Encoding($true)))
        $rows=@($Result.Results | Select-Object System,Source,Playlist,@{Name='MediaFiles';Expression={$_.DiskImages}},Result,Original,RemovedFiles,KeptFiles,RemovalFailures,Detail | ConvertTo-SafeReportRow | ConvertTo-Csv -NoTypeInformation)
        foreach ($line in $rows) {$csvWriter.WriteLine($line)}
        $skipped=@($Result.Results | Where-Object {$_.Result -eq 'Skipped'}).Count
        $logWriter.WriteLine(('OptiMiyoo verified results: {0} published; {1} skipped; {2} failed.' -f $Result.Written,$skipped,$Result.Failed))
        $logWriter.WriteLine(('Source policy: '+$Result.SourcePolicy.ToUpperInvariant()))
        $logWriter.WriteLine(('Originals in this batch: {0} removed | {1} kept | {2} removal failures' -f $Result.Removed,$Result.Kept,$Result.RemovalFailures))
        foreach ($reason in @($Result.Sources | Where-Object {$_.State -ne 'Removed' -and $_.Reason} | ForEach-Object {$_.Reason} | Sort-Object -Unique)) {
            $logWriter.WriteLine(('Originals kept: '+((ConvertTo-SafeExternalText $reason) -replace '[\r\n]+',' ')))
        }
        foreach ($row in $Result.Results) {$logWriter.WriteLine(((ConvertTo-SafeExternalText ($row.Source+': '+$row.Result+' / '+$row.Original+' / '+$row.Detail)) -replace '[\r\n]+',' '))}
        $csvWriter.Flush();$csvStream.Flush($true);$logWriter.Flush();$logStream.Flush($true)
        Write-Host ('Report: '+$csv)
        Write-Host ('Log: '+$log)
    } catch {Write-Warning ('Could not save the verified result report: '+$_.Exception.Message)}
    finally {
        if ($csvWriter) {$csvWriter.Dispose()} elseif ($csvStream) {$csvStream.Dispose()}
        if ($logWriter) {$logWriter.Dispose()} elseif ($logStream) {$logStream.Dispose()}
        if ($lease) {$lease.Dispose()}
    }
}

function Initialize-ApplicationVersion([string]$ApplicationRoot) {
    # Trusted prompts run outside the worker and use the installed version file.
    $stream=$null;$reader=$null
    try {
        $stream=[IO.File]::OpenRead((Join-Path $ApplicationRoot 'VERSION'))
        if ($stream.Length -lt 1 -or $stream.Length -gt 64) {throw 'Invalid installed application version.'}
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
        $version=$reader.ReadToEnd().Trim()
        if ($version -cnotmatch '\A[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(?:[-+][0-9A-Za-z.-]{1,32})?\z') {throw 'Invalid installed application version.'}
        $script:AppVersion=$version
    } finally {
        if ($reader) {$reader.Dispose()} elseif ($stream) {$stream.Dispose()}
    }
}

function Invoke-ApplicationHost {
    param([Parameter(Mandatory=$true)][string]$ApplicationRoot,[string]$Entry,[hashtable]$Arguments)
    $ErrorActionPreference='Stop'
    $application=[IO.Path]::GetFullPath($ApplicationRoot)
    Initialize-ApplicationVersion $application
    $originalRoot=$application
    if ($Arguments.Root) {$originalRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath([string]$Arguments.Root)}
    $originalArguments=$Arguments.Clone()
    $menu=($Entry -eq 'Playlist' -and -not $Arguments.System -and -not $Arguments.C64Convert -and -not $Arguments.ZXConvert -and -not $Arguments.PrepareOnion -and -not $Arguments.Preview)
    if ($Arguments.C64Convert) {$Entry='C64'}
    elseif ($Arguments.ZXConvert) {$Entry='ZX'}
    elseif ($Arguments.PrepareOnion) {$Entry='SD'}
    if ($Entry -in 'C64','ZX' -and $Arguments.Storage -eq 'Auto') {throw 'Auto storage is available only for playlists.'}
    Initialize-ApplicationSession
    $startPage='Main'
    if ($Arguments.StartPage) {$startPage=[string]$Arguments.StartPage}
    $explicitStorage=($Arguments.ContainsKey('Storage') -and $Arguments.Storage -in 'Auto','Zip','Loose','Folders')
    if (-not $explicitStorage -and $Entry -in 'C64','ZX') {
        $startPage=$Entry;$Entry='Playlist';$menu=$true
    }
    $displayEffect='CRT';if ($Arguments.DisplayEffect) {$displayEffect=[string]$Arguments.DisplayEffect}
    $again=$true;$exitCode=1;$selectedOnionRoot=$originalArguments.OnionRoot
    while ($again) {
        $again=$false;$session=$null;$broker=$null;$native=$null;$state=$null;$sd=$null;$sdResult=$null
        try {
            Write-Host 'Preparing isolated OptiMiyoo...' -ForegroundColor Cyan
            $session=[OptiMiyoo.ApplicationSession]::Create()
            $staged=New-ApplicationStagedCode -ApplicationRoot $application -Session $session
            if ($selectedOnionRoot -and -not $Arguments.Preview) {$sd=New-ApplicationSdSession -OnionRoot $selectedOnionRoot -WorkRoot $session.WorkPath}
            $receipts=[pscustomobject]@{NativeReceipts=(New-Object Collections.ArrayList);ArchiveReceipts=(New-Object Collections.ArrayList)}
            if ($Entry -ne 'SD' -and -not $Arguments.Preview) {
                $broker=New-ApplicationBrokerSession -OriginalRoot $originalRoot -WorkRoot $session.WorkPath -OnionRoot $selectedOnionRoot
                $native=New-ApplicationJobBroker -ApplicationRoot $application -ReceiptStore $receipts
            }
            $existing='Ask';if ($originalArguments.Existing) {$existing=[string]$originalArguments.Existing}
            $state=[pscustomobject]@{Session=$session;Broker=$broker;Native=$native;Receipts=$receipts;Existing=$existing;Grant=$null;Completed=$false;Result=$null;Pending=$null;BatchView=$null;StopRequested=$false;NextOnionRoot=$null;DisplayEffect=$displayEffect;NoAnimation=[bool]$Arguments.NoAnimation;NoColor=[bool]$Arguments.NoColor}
            $worker=@{Root=$session.WorkPath;Existing=$existing;SourcePolicy='Keep';DisplayEffect=$displayEffect}
            foreach ($key in 'NoAnimation','NoColor','Preview') {if ($Arguments.ContainsKey($key)) {$worker[$key]=[bool]$Arguments[$key]}}
            if ($Entry -eq 'Playlist' -and $Arguments.Preview -and $Arguments.PreviewSection) {$worker.PreviewSection=[string]$Arguments.PreviewSection}
            if ($menu) {$worker.StartPage=$startPage}
            if ($sd) {$worker.OnionRoot=$sd.StagedRoot}
            $batch=$null
            if (-not $menu -and -not $Arguments.Preview -and $Entry -ne 'SD') {
                $output=Resolve-ApplicationOutputSelection -Operation $Entry -Storage $Arguments.Storage -SingleStorage $Arguments.SingleStorage
                $selection=Get-ApplicationSelection ([pscustomobject]@{Operation=$Entry;System=$Arguments.System;Storage=$output.Storage;SingleStorage=$output.SingleStorage})
                $policy='Keep';if ($Arguments.SourcePolicy -eq 'Remove') {$policy='Remove'}
                $batch=Start-ApplicationBrokerBatch -Session $broker @selection -SourcePolicy $policy -Existing $existing
                if ($Entry -eq 'Playlist') {$worker.System=$selection.System;$worker.SingleStorage=$selection.SingleStorage}
                else {[void]$worker.Remove('Preview');[void]$worker.Remove('OnionRoot')}
                $worker.Storage=$selection.Storage
            }
            if ($Entry -eq 'SD') {
                if (-not $sd) {throw 'Supply the SD root, or choose S from the main menu.'}
                $worker=@{OnionRoot=$sd.StagedRoot}
            }
            Write-ApplicationBootstrap $session $Entry $worker $batch
            $operations=[string[]]@('Policy.Source','Policy.Overwrite','Batch.Begin','Batch.Jobs','Batch.Complete','Display.Preference','SD.Select','Native.Start','Native.Read','Native.Stop','Archive.Start','Archive.Read','Archive.Stop')
            if ($Arguments.Preview) {$operations=[string[]]@('Display.Preference')}
            $session.Start('boot.ps1',[string[]]$staged.Assemblies,$operations)
            $exitCode=Invoke-ApplicationHostLoop $state
            if ($native) {Close-ApplicationJobBroker $native}
            if ($broker) {Close-ApplicationArchiveSession $broker}
            if (-not $state.Pending -and $broker -and $broker.ActiveBatch) {
                # A worker exit code is not evidence of a completed batch.
                # With no handoff, verify no outputs and keep every original.
                $state.Pending=@{BatchId=$broker.ActiveBatch.BatchId;CompletedJobIds=[string[]]@()}
            }
            if ($state.Pending) {
                $pending=$state.Pending
                $state.Result=Complete-ApplicationBrokerBatch -Session $broker @pending -ReceiptStore $receipts
                $state.Completed=$true
            }
            if ($Entry -eq 'SD' -and $exitCode -eq 0) {$sdResult=Complete-ApplicationSdSession -Session $sd}
            if ($state.NextOnionRoot) {$selectedOnionRoot=$state.NextOnionRoot;$Entry='SD';$again=$true}
        } catch {Write-Host ('OptiMiyoo could not complete safely: '+(ConvertTo-SafeExternalText $_.Exception.Message)) -ForegroundColor Red;$exitCode=1}
        finally {
            if ($native) {Close-ApplicationJobBroker $native}
            if ($broker) {Close-ApplicationArchiveSession $broker;Close-ApplicationBrokerSession $broker}
            if ($sd) {Close-ApplicationSdSession -Session $sd}
            if ($session) {$session.Dispose();if ($session.CleanupWarning) {Write-Warning $session.CleanupWarning}}
        }
        if ($state) {$displayEffect=$state.DisplayEffect}
        if ($state -and $state.Result) {
            $skipped=@($state.Result.Results | Where-Object {$_.Result -eq 'Skipped'}).Count
            Write-Host ('Published: {0}; skipped: {1}; failed: {2}.' -f $state.Result.Written,$skipped,$state.Result.Failed)
            foreach ($result in $state.Result.Results) {Write-Host (ConvertTo-SafeExternalText ($result.Source+': '+$result.Result+' / '+$result.Detail))}
            Write-Host ('  Source policy: '+$state.Result.SourcePolicy.ToUpperInvariant())
            Write-Host ('  Originals in this batch: {0} removed | {1} kept | {2} removal failures' -f $state.Result.Removed,$state.Result.Kept,$state.Result.RemovalFailures)
            foreach ($reason in @($state.Result.Sources | Where-Object {$_.State -ne 'Removed' -and $_.Reason} | ForEach-Object {$_.Reason} | Sort-Object -Unique)) {
                Write-Host ('  Originals kept: '+(ConvertTo-SafeExternalText $reason))
            }
            Write-ApplicationVerifiedReport $originalRoot $state.Result
            if ($state.Result.Failed -or $state.Result.RemovalFailures) {$exitCode=1}
            if ($menu -and -not $originalArguments.NoPause -and -not [Console]::IsInputRedirected) {
                Write-Host 'Press Enter for the main menu, or Q to exit.'
                do {$key=[Console]::ReadKey($true)} while ($key.Key -ne [ConsoleKey]::Enter -and $key.Key -ne [ConsoleKey]::Q)
                $again=($key.Key -eq [ConsoleKey]::Enter)
                if ($again) {$startPage='Main'}
            }
        }
        if ($sdResult) {
            Write-Host ('SD setup updated: {0}; skipped: {1}; failed: {2}.' -f $sdResult.Changed,$sdResult.Skipped,$sdResult.Failed)
            if ($sdResult.BackupRoot) {Write-Host ('Original configs: '+$sdResult.BackupRoot)}
            if ($sdResult.Changed) {Write-Host 'Refresh the Onion game list.'}
            if ($sdResult.Failed) {$exitCode=1}
            if ($menu) {$Entry='Playlist';$startPage='Main';$again=$true}
        }
    }
    return [int]$exitCode
}
