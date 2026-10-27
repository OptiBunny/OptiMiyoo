. (Join-Path $PSScriptRoot '../shared/source_policy.ps1')
. (Join-Path $PSScriptRoot '../shared/native_process.ps1')
# Fixed native-converter requests for the application AppContainer. This module
# runs in the trusted parent; paths and receipts are never authority from a child.
function Resolve-ApplicationJobPath {
    param([string]$Root,[string]$Relative)
    if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative.Length -gt 2048 -or
        [IO.Path]::IsPathRooted($Relative) -or $Relative -match '[:\x00-\x1f]') {throw 'Invalid application work path.'}
    foreach ($part in ($Relative -split '[\\/]')) {
        if (-not $part -or $part -in @('.','..') -or $part.TrimEnd(' ','.') -cne $part -or
            $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $part -match '^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(?:\.|$)') {throw 'Invalid application path component.'}
    }
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')+'\'
    $full=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'Application path escaped its batch.'}
    return $full
}

function New-ApplicationJobBroker {
    param([Parameter(Mandatory=$true)][string]$ApplicationRoot,[Parameter(Mandatory=$true)]$ReceiptStore)
    . (Join-Path $ApplicationRoot 'app/shared/source_policy.ps1')
    . (Join-Path $ApplicationRoot 'app/shared/native_process.ps1')
    Initialize-SourcePolicyNative
    Initialize-NativeSandbox
    Initialize-NativeTextCapture
    return [pscustomobject]@{ApplicationRoot=[IO.Path]::GetFullPath($ApplicationRoot);ReceiptStore=$ReceiptStore;Jobs=@{}}
}

function Close-ApplicationNativeJob {
    param($State,$Job)
    if (-not $Job) {return}
    try {
        if ($Job.Native) {Close-NativeSandboxJob $Job.Native}
    } finally {
        foreach ($resource in @($Job.Out,$Job.Err,$Job.InputLease,$Job.ParentLease)) {
            if ($resource) {$resource.Dispose()}
        }
        [void]$State.Jobs.Remove($Job.Id)
    }
}

function Close-ApplicationJobBroker {
    param($State)
    foreach ($job in @($State.Jobs.Values)) {Close-ApplicationNativeJob $State $job}
}

function Invoke-ApplicationNativeRequest {
    param($State,$BrokerSession,[ValidateSet('Native.Start','Native.Read','Native.Stop')][string]$Operation,$Payload)
    $brokerState=Get-ApplicationBrokerState $BrokerSession
    $batch=$brokerState.Batch
    if (-not $batch -or $batch.Completed -or [string]$Payload.BatchId -cne [string]$batch.BatchId) {throw 'Native request has no active batch.'}
    if ($batch.Operation -notin 'C64','ZX') {throw 'Playlist batches cannot run native converters. Use C or Z for conversion.'}
    $work=[string]$brokerState.WorkRoot
    if ($Operation -ne 'Native.Start') {
        $id=[string]$Payload.TaskId
        if (-not $State.Jobs.ContainsKey($id)) {throw 'Unknown native task.'}
        $job=$State.Jobs[$id]
        if ($job.BatchId -cne [string]$batch.BatchId) {throw 'Native task belongs to another batch.'}
        if ($Operation -eq 'Native.Stop') {Close-ApplicationNativeJob $State $job;return @{Stopped=$true}}
        if (-not $job.Done) {
            $job.TimedOut=($job.Timer.Elapsed.TotalSeconds -gt $job.Timeout)
            $job.LimitExceeded=($job.Out.LimitExceeded -or $job.Err.LimitExceeded)
            if ($job.TimedOut -or $job.LimitExceeded) {
                $job.Native.Kill();[void]$job.Native.WaitForExit(5000)
                $job.Failure=if ($job.TimedOut) {'Native converter exceeded its time limit.'} else {'Native diagnostic-output limit exceeded.'}
            }
            if ($job.Native.HasExited) {
                $job.Done=$true;$job.ExitCode=$job.Native.ExitCode
                $stdoutReady=$job.Out.Wait(5000);$stderrReady=$job.Err.Wait(5000)
                $job.LimitExceeded=($job.LimitExceeded -or $job.Out.LimitExceeded -or $job.Err.LimitExceeded)
                $job.CaptureFailed=(-not $stdoutReady -or -not $stderrReady -or [bool]$job.Out.Failure -or [bool]$job.Err.Failure)
                if (-not $job.Failure) {
                    if ($job.LimitExceeded) {$job.Failure='Native diagnostic-output limit exceeded.'}
                    elseif ($job.CaptureFailed) {$job.Failure='Native diagnostic capture failed or did not finish.'}
                }
                if ($job.ExitCode -eq 0 -and -not $job.Failure -and $job.Destination) {
                    # Hash the inaccessible native output BEFORE giving any copy
                    # to the app. Child edits can never manufacture a receipt.
                    $outputLease=$null
                    try {
                        $nativeOutput=Join-Path $job.Native.WorkPath $job.Native.OutputName
                        $outputLease=[OptiMiyoo.SourceRemovalLeaseV128]::OpenRead($nativeOutput)
                        if ($outputLease.Stream.Length -gt 512MB) {throw 'Native output exceeds 512 MiB.'}
                        if ($job.ReceiptKind -eq 'Nib') {
                            $validator=Get-ApplicationBrokerModule C64
                            & $validator {param($path) Assert-G64 $path} $nativeOutput
                        } else {
                            $validator=Get-ApplicationBrokerModule ZX
                            $valid=& $validator {param($path) Test-DSK $path} $nativeOutput
                            if (-not $valid) {throw 'Native converter did not produce a valid DSK image.'}
                        }
                        $length=$outputLease.Stream.Length
                        $hash=[OptiMiyoo.SourceRemovalLeaseV128]::HashStream($outputLease.Stream,$null)
                        $job.Native.Export($job.Destination)
                        [void]$State.ReceiptStore.NativeReceipts.Add([pscustomobject]@{
                            BatchId=$job.BatchId;Kind=$job.ReceiptKind;InputHash=$job.InputHash;
                            OutputHash=$hash;Length=$length;Success=$true
                        })
                    } catch {
                        # A failed import stays failed on every subsequent poll.
                        # In particular, native exit 0 is not verified success.
                        $job.Failure='Native output verification or import failed.'
                    } finally {if ($outputLease) {$outputLease.Dispose()}}
                }
            }
        }
        # Both captures are bounded at one MiB. Each response is much smaller
        # than the RPC frame limit, including JSON escaping overhead.
        $lines=New-Object 'System.Collections.Generic.List[string]'
        $size=0
        while ($size -lt 24576) {
            $line=$job.Out.NextLine();if ($null -eq $line) {$line=$job.Err.NextLine()}
            if ($null -eq $line) {break}
            $lines.Add($line);$size+=$line.Length
        }
        return @{TaskId=$job.Id;Done=$job.Done;Drained=($job.Done -and $size -eq 0);ExitCode=$job.ExitCode;
            Lines=$lines.ToArray();TimedOut=$job.TimedOut;LimitExceeded=$job.LimitExceeded;CaptureFailed=$job.CaptureFailed;Failure=$job.Failure}
    }
    if ($State.Jobs.Count -ge 1) {throw 'Finish the active native task before starting another.'}
    $kind=[string]$Payload.Kind;$mode=[string]$Payload.Mode
    if ($kind -notin @('Nib','HxcX64','HxcX86') -or $mode -notin @('Convert','Modules','Info') -or
        ($kind -eq 'Nib' -and $mode -ne 'Convert')) {throw 'Unknown native operation.'}
    if (($batch.Operation -eq 'C64') -ne ($kind -eq 'Nib')) {throw 'Native converter does not match the active batch.'}
    $job=[pscustomobject]@{Id=[Guid]::NewGuid().ToString('N');BatchId=[string]$batch.BatchId;Native=$null;
        Out=$null;Err=$null;InputLease=$null;ParentLease=$null;InputHash=$null;Destination=$null;
        ReceiptKind=$(if($kind -eq 'Nib'){'Nib'}else{'HxC'});Timer=[Diagnostics.Stopwatch]::StartNew();
        Timeout=120;Done=$false;ExitCode=-1;TimedOut=$false;LimitExceeded=$false;CaptureFailed=$false;Failure=$null}
    try {
        $inputFile=$null;$outputName=$null
        if ($mode -ne 'Modules') {
            $inputFile=Resolve-ApplicationJobPath $work ([string]$Payload.Input)
            $job.InputLease=[OptiMiyoo.SourceRemovalLeaseV128]::OpenRead($inputFile)
            if ($job.InputLease.Stream.Length -gt 512MB) {throw 'Native input exceeds 512 MiB.'}
            $job.InputHash=[OptiMiyoo.SourceRemovalLeaseV128]::HashStream($job.InputLease.Stream,$null)
        }
        if ($mode -eq 'Convert') {
            $job.Destination=Resolve-ApplicationJobPath $work ([string]$Payload.Output)
            $job.ParentLease=Open-SourcePolicyDirectoryLease ([IO.Path]::GetDirectoryName($job.Destination))
            if ([IO.File]::Exists($job.Destination) -or [IO.Directory]::Exists($job.Destination)) {throw 'Native output already exists.'}
            $outputName=if ($kind -eq 'Nib') {'output.g64'} else {'output.dsk'}
        }
        $runtime=New-Object 'System.Collections.Generic.List[string]'
        if ($kind -eq 'Nib') {$exe=Join-Path $State.ApplicationRoot 'app/C64/tools/nibconv.exe';$lpac=$true}
        else {
            $arch=if ($kind -eq 'HxcX86') {'x86'} else {'x64'}
            $directory=Join-Path $State.ApplicationRoot ('app/ZX/tools/hxc/'+$arch)
            $exe=Join-Path $directory 'hxcfe.exe';$lpac=($arch -eq 'x64')
            foreach ($name in @('libhxcfe.dll','libusbhxcfe.dll','CAPSImg.dll','config.script',
                'libgcc_s_dw2-1.dll','libstdc++-6.dll','libwinpthread-1.dll')) {
                $file=Join-Path $directory $name;if ([IO.File]::Exists($file)) {$runtime.Add($file)}
            }
        }
        $job.Native=[OptiMiyoo.NativeSandboxJob]::Create($exe,$runtime.ToArray(),$inputFile,$outputName,$lpac)
        switch ($mode) {
            'Modules' {$arguments='-modulelist';$job.Timeout=20}
            'Info' {$arguments='-verbose -finput:"'+$job.Native.InputRelativePath+'" -infos';$job.Timeout=30}
            'Convert' {
                if ($kind -eq 'Nib') {$arguments='-v "'+$job.Native.InputRelativePath+'" "'+$outputName+'"'}
                else {$arguments='-verbose -finput:"'+$job.Native.InputRelativePath+'" -conv:AMSTRADCPC_DSK -foutput:"'+$outputName+'"'}
            }
        }
        $job.Native.WallTimeLimitSeconds=$job.Timeout
        $job.Native.Start($arguments)
        $job.Out=New-Object OptiMiyoo.NativeTextCapture($job.Native.StandardOutput,1048576)
        $job.Err=New-Object OptiMiyoo.NativeTextCapture($job.Native.StandardError,1048576)
        $State.Jobs.Add($job.Id,$job)
        return @{TaskId=$job.Id}
    } catch {Close-ApplicationNativeJob $State $job;throw}
}

function ConvertTo-ApplicationWorkRelative([string]$Path) {
    $context=$global:OptiMiyooApplicationContext
    if (-not $context -or -not $context.BatchId) {throw 'No isolated application batch is active.'}
    $prefix=[IO.Path]::GetFullPath($context.WorkRoot).TrimEnd('\','/')+'\'
    $full=[IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'Converter path is outside its batch.'}
    return $full.Substring($prefix.Length)
}

function New-ApplicationNativeCapture {
    param([ValidateSet('Nib','HxcX64','HxcX86')][string]$Kind,[ValidateSet('Convert','Modules','Info')][string]$Mode,
        [string]$InputPath,[string]$OutputPath)
    $payload=@{BatchId=$global:OptiMiyooApplicationContext.BatchId;Kind=$Kind;Mode=$Mode}
    if ($InputPath) {$payload.Input=ConvertTo-ApplicationWorkRelative $InputPath}
    if ($OutputPath) {$payload.Output=ConvertTo-ApplicationWorkRelative $OutputPath}
    $reply=Invoke-ApplicationRpc -Operation Native.Start -Payload $payload
    $proxy=[pscustomobject]@{TaskId=$reply.TaskId;BatchId=$payload.BatchId;Queue=(New-Object 'System.Collections.Generic.Queue[string]');
        Done=$false;Drained=$false;Code=-1;Failure=$null;TimedOut=$false;LimitExceeded=$false;CaptureFailed=$false;Disposed=$false;Child=$null}
    $proxy.Child=$proxy
    $proxy | Add-Member ScriptMethod Poll {
        if ($this.Disposed -or $this.Drained) {return}
        $r=Invoke-ApplicationRpc -Operation Native.Read -Payload @{BatchId=$this.BatchId;TaskId=$this.TaskId}
        foreach ($line in $r.Lines) {$this.Queue.Enqueue([string]$line)}
        $this.Done=[bool]$r.Done;$this.Drained=[bool]$r.Drained;$this.Code=[int]$r.ExitCode
        $this.Failure=$r.Failure;$this.TimedOut=[bool]$r.TimedOut
        $this.LimitExceeded=[bool]$r.LimitExceeded;$this.CaptureFailed=[bool]$r.CaptureFailed
    }
    $proxy | Add-Member ScriptProperty HasExited {$this.Poll();return $this.Done}
    $proxy | Add-Member ScriptProperty ExitCode {return $this.Code}
    $proxy | Add-Member ScriptMethod NextLine {if ($this.Queue.Count) {return $this.Queue.Dequeue()};return $null}
    $proxy | Add-Member ScriptMethod WaitOutput {
        param([int]$Milliseconds)
        $timer=[Diagnostics.Stopwatch]::StartNew()
        while (-not $this.Drained -and $timer.ElapsedMilliseconds -lt $Milliseconds) {$this.Poll()}
        return $this.Drained
    }
    $proxy | Add-Member ScriptMethod WaitForExit {
        param([int]$Milliseconds)
        $timer=[Diagnostics.Stopwatch]::StartNew()
        do {$this.Poll();if ($this.Done) {return $true};Start-Sleep -Milliseconds 25} while ($timer.ElapsedMilliseconds -lt $Milliseconds)
        return $false
    }
    $proxy | Add-Member ScriptMethod Export {if (-not $this.Done -or $this.Code -ne 0 -or $this.Failure) {throw 'Isolated native output was not accepted.'}}
    $proxy | Add-Member ScriptMethod Dispose {
        if (-not $this.Disposed) {
            try {[void](Invoke-ApplicationRpc -Operation Native.Stop -Payload @{BatchId=$this.BatchId;TaskId=$this.TaskId})}
            finally {$this.Disposed=$true}
        }
    }
    $proxy | Add-Member ScriptMethod Kill {$this.Dispose()}
    return $proxy
}

function Invoke-ApplicationEngineText([string]$EnginePath,[string]$Arguments) {
    $kind=if ([IO.Path]::GetFileName([IO.Path]::GetDirectoryName($EnginePath)) -eq 'x86') {'HxcX86'} else {'HxcX64'}
    $inputPath=$null;$outputPath=$null
    if ($Arguments -ceq '-modulelist') {$mode='Modules'}
    elseif ($Arguments -cmatch '^-verbose -finput:"([^"]+)" -infos$') {$mode='Info';$inputPath=$Matches[1]}
    elseif ($Arguments -cmatch '^-verbose -finput:"([^"]+)" -conv:AMSTRADCPC_DSK -foutput:"([^"]+)"$') {
        $mode='Convert';$inputPath=$Matches[1];$outputPath=$Matches[2]
    } else {throw 'Unrecognized isolated HxC operation.'}
    $capture=New-ApplicationNativeCapture $kind $mode $inputPath $outputPath
    $text=New-Object Text.StringBuilder
    try {
        do {
            $done=$capture.WaitForExit(125)
            while ($null -ne ($line=$capture.NextLine())) {[void]$text.AppendLine($line)}
            Show-Stage 'Running isolated HxC / waiting for engine output' (Get-EngineLabel $EnginePath)
        } while (-not $done)
        if (-not $capture.WaitOutput(5000)) {throw 'Isolated HxC capture did not finish.'}
        while ($null -ne ($line=$capture.NextLine())) {[void]$text.AppendLine($line)}
        if ($capture.Failure) {throw $capture.Failure}
        return [pscustomobject]@{ExitCode=$capture.Code;Output=$text.ToString().Trim();TimedOut=$capture.TimedOut}
    } finally {$capture.Dispose()}
}
