# Parent archive service and confined-client adapter. The wire protocol carries
# bounded data and scoped relative paths, never executable names or commands.
. (Join-Path $PSScriptRoot 'source_policy.ps1')
if(-not (Get-Variable ApplicationArchiveTasks -Scope Script -ErrorAction SilentlyContinue)){$script:ApplicationArchiveTasks=@{}}
$script:ApplicationArchiveCodeRoot=$PSScriptRoot

function Assert-ApplicationArchiveFields($Payload,[string[]]$Allowed,[string[]]$Required) {
    if($Payload -is [Collections.IDictionary]){$names=@($Payload.Keys)}
    elseif($null -ne $Payload -and $Payload -is [pscustomobject]) {
        foreach($property in $Payload.PSObject.Properties){if($property.MemberType -ne 'NoteProperty'){throw 'Archive requests contain only plain data.'}}
        $names=@($Payload.PSObject.Properties.Name)
    } else {throw 'Archive request must be an object.'}
    foreach($name in $names){if($name -cnotin $Allowed){throw 'Unknown archive request field.'}}
    foreach($name in $Required){if($name -cnotin $names){throw 'Missing archive request field.'}}
}

function Get-ApplicationArchiveInteger($Value,[long]$Minimum,[long]$Maximum) {
    if($Value -isnot [byte] -and $Value -isnot [int16] -and $Value -isnot [int32] -and $Value -isnot [int64]){throw 'Archive numeric fields require integers.'}
    $number=[long]$Value;if($number -lt $Minimum -or $number -gt $Maximum){throw 'Archive numeric field is outside its limit.'};return $number
}

function Get-ApplicationArchivePath([string]$Root,$Relative) {
    if($Relative -isnot [string] -or [string]::IsNullOrWhiteSpace($Relative) -or $Relative.Length -gt 4096 -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains('\')){throw 'Archive paths must be bounded relative paths.'}
    foreach($part in $Relative.Split('/')) {
        if($part -in '', '.', '..' -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '[<>:"|?*\x00-\x1f]' -or $part -match '^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[0-9\u00b9\u00b2\u00b3]|LPT[0-9\u00b9\u00b2\u00b3])(?:\.|$)'){throw 'Unsafe archive path component.'}
    }
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $full=[IO.Path]::GetFullPath((Join-Path $Root $Relative.Replace('/',[IO.Path]::DirectorySeparatorChar)))
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Archive path leaves its active batch.'}
    return $full
}

function Close-ApplicationArchiveTask($Task) {
    if(-not $Task -or $Task.Closed){return}
    $Task.Closed=$true
    try {
        if($Task.PowerShell) {
            try {if($Task.Async -and -not $Task.Async.IsCompleted){$Task.PowerShell.Stop()}}
            finally {$Task.PowerShell.Dispose();$Task.PowerShell=$null}
        }
    } finally {
        if($Task.DestinationLease){$Task.DestinationLease.Dispose();$Task.DestinationLease=$null}
        if($Task.InputLease){$Task.InputLease.Dispose();$Task.InputLease=$null}
        if($Task.RootLease){$Task.RootLease.Dispose();$Task.RootLease=$null}
    }
}

function Close-ApplicationArchiveSession($BrokerSession) {
    $key=[string]$BrokerSession.Id
    if($script:ApplicationArchiveTasks.ContainsKey($key)) {
        $task=$script:ApplicationArchiveTasks[$key]
        if(-not [object]::ReferenceEquals($task.Session,$BrokerSession)){throw 'Archive session identity mismatch.'}
        try {Close-ApplicationArchiveTask $task}finally{$script:ApplicationArchiveTasks.Remove($key)}
    }
}

function Complete-ApplicationArchiveTask($Task,$ReceiptStore) {
    if($Task.Completed -or -not $Task.Async.IsCompleted){return}
    try {
        $output=$Task.PowerShell.EndInvoke($Task.Async)
        if($Task.PowerShell.HadErrors -or $output.Count -ne 1){throw 'Archive worker returned an invalid result.'}
        $value=$output[0].BaseObject
        if($null -eq $value){$value=$output[0]}
        if($value.InputHash -notmatch '^[0-9A-F]{64}$'){throw 'Archive input verification was incomplete.'}
        $Task.Rows=@($value.Rows);$Task.Bytes=$value.Bytes
        if($Task.Rows.Count -gt 20000){throw 'Archive result count exceeds its limit.'}
        foreach($row in $Task.Rows){if($row.Name -isnot [string] -or $row.Name.Length -gt 4096 -or $row.Hash -notmatch '^[0-9A-F]{64}$' -or [long]$row.Length -lt 0){throw 'Invalid verified archive result.'}}
        if($Task.Operation -eq 'Read' -and ($Task.Bytes -isnot [byte[]] -or $Task.Bytes.Length -gt 16777216)){throw 'Invalid bounded archive byte result.'}
        $receipt=[pscustomobject]@{ReceiptId=[Guid]::NewGuid().ToString('N');BatchId=$Task.BatchId;InputHash=[string]$value.InputHash;
            Operation=$Task.Operation;InputRelativePath=$Task.InputRelativePath;DestinationRelativePath=$Task.DestinationRelativePath;
            Entries=$Task.Rows;Success=$true}
        if(-not $ReceiptStore -or $null -eq $ReceiptStore.ArchiveReceipts){throw 'Host archive receipt store is unavailable.'}
        $receiptRows=$Task.Rows.Count
        foreach($previous in $ReceiptStore.ArchiveReceipts){$receiptRows+=@($previous.Entries).Count}
        if($ReceiptStore.ArchiveReceipts.Count -ge 16384 -or $receiptRows -gt 200000){throw 'Archive receipts exceed this application session limit.'}
        [void]$ReceiptStore.ArchiveReceipts.Add($receipt)
        $Task.ReceiptId=$receipt.ReceiptId;$Task.Completed=$true
    } catch {
        $Task.Error=$_.Exception.Message;$Task.Completed=$true
        Close-ApplicationArchiveTask $Task
    }
}

function Invoke-ApplicationArchiveRequest {
    param([Parameter(Mandatory=$true)]$BrokerSession,
          [Parameter(Mandatory=$true)][ValidateSet('Archive.Start','Archive.Read','Archive.Stop')][string]$Operation,
          [Parameter(Mandatory=$true)]$Payload,[Parameter(Mandatory=$true)]$ReceiptStore)
    $state=Get-ApplicationBrokerState $BrokerSession
    if(-not $state.Batch -or $state.Batch.Completed){throw 'An active authorized batch is required for archive work.'}
    if($Operation -eq 'Archive.Start') {
        Assert-ApplicationArchiveFields $Payload @('BatchId','ZipRelativePath','Profile','ArchiveOperation','EntryIndex','DestinationRelativePath','MaximumBytes') @('BatchId','ZipRelativePath','Profile','ArchiveOperation','EntryIndex','MaximumBytes')
    } elseif($Operation -eq 'Archive.Read') {
        Assert-ApplicationArchiveFields $Payload @('BatchId','TaskId','Offset') @('BatchId','TaskId','Offset')
    } else {
        Assert-ApplicationArchiveFields $Payload @('BatchId','TaskId') @('BatchId','TaskId')
    }
    $batchId=[string]$state.Batch.BatchId
    if([string]::IsNullOrWhiteSpace($batchId)){throw 'Active archive batch identity is unavailable.'}
    if($Payload.BatchId -isnot [string] -or $Payload.BatchId -cne $batchId){throw 'Archive request belongs to another batch.'}
    $key=[string]$BrokerSession.Id
    if($Operation -eq 'Archive.Start') {
        if($script:ApplicationArchiveTasks.ContainsKey($key) -and -not $script:ApplicationArchiveTasks[$key].Closed){throw 'Only one archive task may be active in a session.'}
        if($Payload.Profile -isnot [string] -or $Payload.Profile -cnotin 'Media','Floppy' -or $Payload.ArchiveOperation -isnot [string] -or $Payload.ArchiveOperation -cnotin 'Hash','Extract','Read','File'){throw 'Unknown archive operation or profile.'}
        $index=Get-ApplicationArchiveInteger $Payload.EntryIndex -1 19999
        $maximum=Get-ApplicationArchiveInteger $Payload.MaximumBytes 1 17179869184
        if($Payload.ArchiveOperation -eq 'Read' -and $maximum -gt 16777216){throw 'Archive text reads are limited to 16 MiB.'}
        if($Payload.ArchiveOperation -in 'Read','File' -and $index -lt 0){throw 'Selected archive entry is required.'}
        if($Payload.ArchiveOperation -in 'Hash','Extract' -and $index -ne -1){throw 'Full archive operations cannot select a partial verification set.'}
        $inputPath=Get-ApplicationArchivePath $state.WorkRoot $Payload.ZipRelativePath
        $destination=$null
        if($Payload.ArchiveOperation -in 'Extract','File'){$destination=Get-ApplicationArchivePath $state.WorkRoot $Payload.DestinationRelativePath}
        elseif($Payload.DestinationRelativePath){throw 'This archive operation does not accept a destination.'}
        $task=[pscustomobject]@{Session=$BrokerSession;BatchId=$batchId;TaskId=[Guid]::NewGuid().ToString('N');Operation=$Payload.ArchiveOperation;
            InputRelativePath=$Payload.ZipRelativePath;DestinationRelativePath=$Payload.DestinationRelativePath;RootLease=$null;InputLease=$null;DestinationLease=$null;
            PowerShell=$null;Async=$null;Queue=(New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]');Clock=[Diagnostics.Stopwatch]::StartNew();
            Rows=@();Bytes=$null;Offset=0;Completed=$false;Closed=$false;Error=$null;ReceiptId=$null}
        try {
            $task.RootLease=Open-SourcePolicyDirectoryLease $state.WorkRoot
            $task.InputLease=Open-SourcePolicyReadLease $inputPath $state.WorkRoot
            if($destination) {
                $parent=[IO.Path]::GetDirectoryName($destination)
                if(-not [IO.Directory]::Exists($parent)){throw 'Archive destination parent must already exist in this batch.'}
                $task.DestinationLease=Open-SourcePolicyDirectoryLease $parent
                if($Payload.ArchiveOperation -eq 'Extract') {
                    [void][IO.Directory]::CreateDirectory($destination)
                    $directoryLease=Open-SourcePolicyDirectoryLease $destination
                    $task.DestinationLease.Dispose();$task.DestinationLease=$directoryLease
                } elseif(Test-Path -LiteralPath $destination){throw 'Archive destination must be a new output in the active batch.'}
            }
            # Compile the fixed installed service once in the trusted parent.
            # Fresh runspaces receive only these bytes, never executable payloads
            # from a request, so repeated archive calls do not rerun csc.
            $workerBytes=Get-ArchiveSandboxExecutableBytes
            $script=@'
param($CodeRoot,$InputPath,$InputLease,$Profile,$Operation,$EntryIndex,$Destination,$MaximumBytes,$ProgressQueue,[byte[]]$TrustedWorkerBytes)
$ErrorActionPreference='Stop'
foreach($helper in 'compile_support.ps1','source_policy.ps1','archive_limits.ps1','zip_integrity.ps1','native_process.ps1','archive_sandbox.ps1'){. (Join-Path $CodeRoot $helper)}
$script:ArchiveSandboxExecutableBytes=[byte[]]$TrustedWorkerBytes.Clone()
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $CodeRoot 'make_playlists.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Installed archive helpers failed syntax validation.'}
foreach($name in 'Assert-PlainOutputParents') {
    $definitions=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $name})
    if($definitions.Count -ne 1){throw 'Installed archive helper is missing or ambiguous.'}
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}
$inputHash=[OptiMiyoo.SourceRemovalLeaseV128]::HashStream($InputLease.Stream,$null)
$InputLease.Stream.Position=0
$archive=Open-ArchiveWithBudget -Path $InputPath -Profile $Profile
try {
    $result=Invoke-ArchiveSandbox -ZipPath $InputPath -Archive $archive -Profile $Profile -Operation $Operation -EntryIndex $EntryIndex -Destination $Destination -MaximumBytes $MaximumBytes -Progress {
        param($index,$count,$done,$length)
        $discard=$null;while($ProgressQueue.Count -ge 128){[void]$ProgressQueue.TryDequeue([ref]$discard)}
        $ProgressQueue.Enqueue([pscustomobject]@{Index=[int]$index;Count=[int]$count;Done=[long]$done;Length=[long]$length})
    }
    $rows=New-Object 'System.Collections.Generic.List[object]';$bytes=$null
    if($Operation -eq 'Read') {
        $bytes=[byte[]]$result;$sha=[Security.Cryptography.SHA256]::Create()
        try {$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}
        $rows.Add([pscustomobject]@{Name=$archive.Entries[$EntryIndex].FullName;Length=[long]$bytes.Length;Hash=$hash})
    } else {
        foreach($name in @($result.Keys | Sort-Object)){$rows.Add([pscustomobject]@{Name=[string]$name;Length=[long]$result[$name].Length;Hash=[string]$result[$name].Hash})}
    }
    return [pscustomobject]@{InputHash=$inputHash;Rows=$rows.ToArray();Bytes=$bytes}
}finally{$archive.Dispose()}
'@
            $task.PowerShell=[PowerShell]::Create()
            [void]$task.PowerShell.AddScript($script)
            [void]$task.PowerShell.AddArgument($script:ApplicationArchiveCodeRoot).AddArgument($inputPath).AddArgument($task.InputLease).AddArgument([string]$Payload.Profile).AddArgument([string]$Payload.ArchiveOperation).AddArgument([int]$index).AddArgument($destination).AddArgument([long]$maximum).AddArgument($task.Queue).AddArgument($workerBytes)
            $task.Async=$task.PowerShell.BeginInvoke();$script:ApplicationArchiveTasks[$key]=$task
            return [pscustomobject]@{State='Running';TaskId=$task.TaskId;Offset=0}
        } catch {Close-ApplicationArchiveTask $task;throw}
    }
    if(-not $script:ApplicationArchiveTasks.ContainsKey($key)){throw 'Unknown archive task.'}
    $task=$script:ApplicationArchiveTasks[$key]
    if(-not [object]::ReferenceEquals($task.Session,$BrokerSession) -or $Payload.TaskId -isnot [string] -or $Payload.TaskId -cne $task.TaskId -or $task.BatchId -cne $batchId){throw 'Archive task identity mismatch.'}
    if($Operation -eq 'Archive.Stop'){Close-ApplicationArchiveTask $task;return [pscustomobject]@{State='Stopped';TaskId=$task.TaskId}}
    if($task.Closed){throw 'Archive task is already closed.'}
    $offset=Get-ApplicationArchiveInteger $Payload.Offset 0 16777216
    if($offset -ne $task.Offset){throw 'Archive result offset is stale or out of order.'}
    if($task.Clock.Elapsed.TotalMinutes -gt 31){Close-ApplicationArchiveTask $task;throw 'Archive request exceeded its time limit.'}
    $progress=$null;$item=$null
    while($task.Queue.TryDequeue([ref]$item)){$progress=$item}
    Complete-ApplicationArchiveTask $task $ReceiptStore
    if($task.Error){return [pscustomobject]@{State='Error';TaskId=$task.TaskId;Error='Archive verification failed; original kept.'}}
    if(-not $task.Completed){return [pscustomobject]@{State='Running';TaskId=$task.TaskId;Offset=$task.Offset;Progress=$progress}}
    $rows=@();$encoded=$null;$next=$task.Offset
    if($task.Operation -eq 'Read') {
        $count=[Math]::Min(65536,$task.Bytes.Length-$task.Offset)
        $encoded=[Convert]::ToBase64String($task.Bytes,$task.Offset,$count);$next+=$count;$more=$next -lt $task.Bytes.Length
    } else {
        $page=New-Object 'System.Collections.Generic.List[object]';$pageBytes=2
        while($next -lt $task.Rows.Count -and $page.Count -lt 200) {
            $row=$task.Rows[$next]
            $rowBytes=[Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $row -Depth 4 -Compress))
            $separator=0;if($page.Count){$separator=1}
            if($pageBytes+$separator+$rowBytes -gt 524288){break}
            $page.Add($row);$pageBytes+=$separator+$rowBytes;$next++
        }
        $rows=$page.ToArray()
        if($next -eq $task.Offset -and $next -lt $task.Rows.Count){throw 'Archive result row cannot fit the response limit.'}
        $more=$next -lt $task.Rows.Count
    }
    $response=[pscustomobject]@{State='Completed';TaskId=$task.TaskId;Offset=$task.Offset;NextOffset=$next;More=$more;Rows=$rows;Bytes=$encoded;Progress=$progress}
    $task.Offset=$next
    if(-not $more){Close-ApplicationArchiveTask $task}
    return $response
}

function Invoke-ApplicationArchive {
    param([Parameter(Mandatory=$true)][string]$ZipPath,[Parameter(Mandatory=$true)][IO.Compression.ZipArchive]$Archive,
          [ValidateSet('Media','Floppy')][string]$Profile='Media',[ValidateSet('Hash','Extract','Read','File')][string]$Operation='Hash',
          [int]$EntryIndex=-1,[string]$Destination,[long]$MaximumBytes=16777216,[scriptblock]$Progress=$null)
    $context=$global:OptiMiyooApplicationContext
    if(-not $context -or -not $context.BatchId -or -not $context.WorkRoot){throw 'Archive RPC requires an active application batch.'}
    $prefix=[IO.Path]::GetFullPath($context.WorkRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $archiveInputPath=[IO.Path]::GetFullPath($ZipPath)
    if(-not $archiveInputPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Archive input leaves the application batch.'}
    $payload=@{BatchId=[string]$context.BatchId;ZipRelativePath=$archiveInputPath.Substring($prefix.Length).Replace('\','/');Profile=$Profile;ArchiveOperation=$Operation;EntryIndex=$EntryIndex;MaximumBytes=$MaximumBytes}
    if($Destination) {
        $output=[IO.Path]::GetFullPath($Destination)
        if(-not $output.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Archive output leaves the application batch.'}
        $payload.DestinationRelativePath=$output.Substring($prefix.Length).Replace('\','/')
    }
    $started=Invoke-ApplicationRpc -Operation 'Archive.Start' -Payload $payload
    $taskId=[string]$started.TaskId;$offset=0;$manifest=@{};$memory=$null
    if($Operation -eq 'Read'){$memory=New-Object IO.MemoryStream}
    try {
        while($true) {
            $response=Invoke-ApplicationRpc -Operation 'Archive.Read' -Payload @{BatchId=[string]$context.BatchId;TaskId=$taskId;Offset=$offset}
            if($response.Progress -and $Progress){& $Progress $response.Progress.Index $response.Progress.Count $response.Progress.Done $response.Progress.Length | Out-Null}
            elseif($Progress){& $Progress 0 $Archive.Entries.Count 0 0 | Out-Null}
            if($response.State -eq 'Error'){throw 'Archive verification failed; original kept.'}
            if($response.State -eq 'Running'){Start-Sleep -Milliseconds 50;continue}
            if($response.State -ne 'Completed' -or [long]$response.Offset -ne $offset){throw 'Invalid archive RPC response.'}
            if($Operation -eq 'Read') {
                $bytes=[Convert]::FromBase64String([string]$response.Bytes)
                if($bytes.Length -gt 65536 -or $memory.Length+$bytes.Length -gt [Math]::Min($MaximumBytes,16777216)){throw 'Archive RPC exceeded its byte limit.'}
                $memory.Write($bytes,0,$bytes.Length)
            } else {
                if(@($response.Rows).Count -gt 200){throw 'Archive RPC exceeded its result page limit.'}
                foreach($row in $response.Rows){if($manifest.ContainsKey([string]$row.Name)){throw 'Duplicate archive RPC result.'};$manifest[[string]$row.Name]=[pscustomobject]@{Length=[long]$row.Length;Hash=[string]$row.Hash}}
            }
            $next=[long]$response.NextOffset
            if($next -lt $offset -or ($response.More -and $next -eq $offset)){throw 'Archive RPC did not advance.'}
            $offset=$next;if(-not $response.More){break}
        }
        if($Operation -eq 'Read'){return ,$memory.ToArray()};return $manifest
    } finally {
        try {Invoke-ApplicationRpc -Operation 'Archive.Stop' -Payload @{BatchId=[string]$context.BatchId;TaskId=$taskId} | Out-Null}
        finally {if($memory){$memory.Dispose()}}
    }
}
