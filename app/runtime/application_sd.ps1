# The SD root comes from the original command line or the parent's own console.
# Child output can only request the exact extension patch computed here from
# frozen original bytes; it cannot supply a host path, replacement, or backup.
. (Join-Path $PSScriptRoot '../shared/compile_support.ps1')
. (Join-Path $PSScriptRoot '../onion/core_support.ps1')
. (Join-Path $PSScriptRoot 'application_prompts.ps1')
if(-not (Get-Variable ApplicationSdStates -Scope Script -ErrorAction SilentlyContinue)){$script:ApplicationSdStates=@{}}
$script:ApplicationSdCodeRoot=Split-Path -Parent $PSScriptRoot

function Initialize-ApplicationSdSupport {
    if(Get-Variable ApplicationSdModule -Scope Script -ErrorAction SilentlyContinue){return}
    $script:ApplicationSdModule=New-Module -Name OptiMiyooSdBroker -ArgumentList $script:ApplicationSdCodeRoot -ScriptBlock {
        param($codeRoot)
        . (Join-Path $codeRoot 'shared/compile_support.ps1')
        . (Join-Path $codeRoot 'onion/core_support.ps1')
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $codeRoot 'onion/prepare_onion.ps1'),[ref]$tokens,[ref]$errors)
        if($errors.Count){throw 'Installed SD helpers failed syntax validation.'}
        foreach($name in 'Initialize-OnionPathLease','Write-OnionBytesVerified') {
            $definitions=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $name})
            if($definitions.Count -ne 1){throw 'Installed SD helper is missing or ambiguous.'}
            . ([scriptblock]::Create($definitions[0].Extent.Text))
        }
        Initialize-OnionPathLease
        function Open-OptiInputLease([string]$Path,[string]$Root) {
            return [OptiMiyoo.OnionPathLease]::Open($Path,$Root,$false,$false,$false)
        }
    }
}

function Get-ApplicationSdState($Session) {
    if($null -eq $Session -or $Session.Id -isnot [string] -or -not $script:ApplicationSdStates.ContainsKey($Session.Id)){throw 'Unknown SD setup session.'}
    $state=$script:ApplicationSdStates[$Session.Id]
    if(-not [object]::ReferenceEquals($Session,$state.Handle) -or $state.Closed){throw 'SD setup session is closed or forged.'}
    return $state
}

function Read-ApplicationSdBytes([IO.Stream]$Stream,[long]$Maximum) {
    if($Stream.Length -gt $Maximum){throw 'SD metadata exceeds its supported size.'}
    $Stream.Position=0;$memory=New-Object IO.MemoryStream
    try{$Stream.CopyTo($memory);if($memory.Length -ne $Stream.Length -or $memory.Length -gt $Maximum){throw 'SD metadata changed while reading.'};return ,$memory.ToArray()}finally{$memory.Dispose();$Stream.Position=0}
}

function Add-ApplicationSdSnapshotFile($State,[string]$Relative,[long]$Maximum,[switch]$Config) {
    if($State.Files.ContainsKey($Relative) -or $State.UnavailableConfigs.ContainsKey($Relative)){return}
    # Callers supply only fixed installed profile config paths;
    # no path is taken from the child.
    $path=Join-Path $State.OriginalRoot $Relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
    if(-not (Test-Path -LiteralPath $path)){return}
    $lease=$null;$output=$null;$unavailable=''
    try {
        try{$lease=[OptiMiyoo.OnionPathLease]::Open($path,$State.OriginalRoot,$false,$false,$false)}
        catch {
            $cause=$_.Exception
            while($cause -and $cause -isnot [ComponentModel.Win32Exception]){$cause=$cause.InnerException}
            if(-not $Config -or -not $cause -or $cause.NativeErrorCode -notin 32,33){throw}
            # Only an original sharing conflict is skippable. A linked or
            # wrong-type path must still fail even when it is also in use.
            Assert-PlainOnionPath $path $State.OriginalRoot
            $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'SD config is linked or has the wrong type; left unchanged.'}
            $unavailable='Config is in use'
        }
        if($lease -and $Config -and $lease.Stream.Length -gt $Maximum){$unavailable='Config exceeds 1 MiB'}
        if($unavailable){
            # These records carry no captured bytes, lease or patch authority.
            # They exist only for the checklist and accurate skipped receipts.
            $State.UnavailableConfigs[$Relative]=[pscustomobject]@{Relative=$Relative;Folder=$Relative.Split('/')[1];Reason=$unavailable}
            return
        }
        if($lease.Stream.Length -gt $Maximum -or $State.TotalBytes+$lease.Stream.Length -gt 2147483648){throw 'SD snapshot exceeds its supported inspection size.'}
        $target=Join-Path $State.StagedRoot $Relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        $output=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $bytes=$null
        # Use one pinned read for both the staged copy and patch authority.
        if($Config){$bytes=Read-ApplicationSdBytes $lease.Stream $Maximum;$output.Write($bytes,0,$bytes.Length)}
        else{$lease.Stream.CopyTo($output)}
        $output.Flush($true);$output.Dispose();$output=$null
        $State.TotalBytes+=$lease.Stream.Length
        $State.Files[$Relative]=[pscustomobject]@{Path=$path;Relative=$Relative;Lease=$lease;Bytes=$bytes;Config=[bool]$Config;Expected=$null;Changed=$false;Folder='';Extensions=@()}
        $lease=$null
    }finally{if($output){$output.Dispose()};if($lease){$lease.Dispose()}}
}

function New-ApplicationSdSession {
    param([Parameter(Mandatory=$true)][string]$OnionRoot,[Parameter(Mandatory=$true)][string]$WorkRoot,[scriptblock]$Progress)
    Initialize-ApplicationSdSupport
    $original=[IO.Path]::GetFullPath($OnionRoot);$work=[IO.Path]::GetFullPath($WorkRoot)
    $originalPrefix=$original.TrimEnd('\','/')+'\';$workPrefix=$work.TrimEnd('\','/')+'\'
    if($originalPrefix.Equals($workPrefix,[StringComparison]::OrdinalIgnoreCase) -or $originalPrefix.StartsWith($workPrefix,[StringComparison]::OrdinalIgnoreCase) -or $workPrefix.StartsWith($originalPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'SD staging must be separate from the selected SD root.'}
    if(-not [IO.Directory]::Exists($work)){throw 'SD staging must already exist and belong to the application session.'}
    $state=[pscustomobject]@{Handle=$null;OriginalRoot=$original;StagedRoot=(Join-Path $work 'Onion');RootLease=$null;Files=@{};UnavailableConfigs=@{};TotalBytes=0L;Closed=$false;Completed=$false;SelectionFinalized=$false;BackupRoot=$null;VerifiedBackups=(New-Object 'Collections.Generic.List[object]');UnverifiedBackups=(New-Object 'Collections.Generic.List[object]')}
    $workLease=$null;$registered=$false
    try {
        $state.RootLease=[OptiMiyoo.OnionPathLease]::Open($original,$original,$true,$false,$false)
        $emu=Join-Path $original 'Emu'
        $emuLease=[OptiMiyoo.OnionPathLease]::Open($emu,$original,$true,$false,$false);$emuLease.Dispose()
        $workLease=[OptiMiyoo.OnionPathLease]::Open($work,$work,$true,$false,$false)
        if(Test-Path -LiteralPath $state.StagedRoot){throw 'SD snapshot needs a fresh Onion staging folder.'}
        [void][IO.Directory]::CreateDirectory((Join-Path $state.StagedRoot 'Emu'))
        $profiles=@(Get-OnionSetupProfiles $script:ApplicationSdCodeRoot)
        for($index=0;$index -lt $profiles.Count;$index++) {
            $profile=$profiles[$index]
            $folder=$profile.Folder;if($profile.EmuFolder){$folder=$profile.EmuFolder}
            if($folder -notmatch '^[A-Z0-9]+$'){throw 'Invalid installed SD profile.'}
            if($Progress){$null=& $Progress 'Reading config files' $folder $index $profiles.Count 'systems'}
            $relative='Emu/'+$folder+'/config.json'
            Add-ApplicationSdSnapshotFile $state $relative 1048576 -Config
            if(-not $state.Files.ContainsKey($relative)){continue}
            $file=$state.Files[$relative];$file.Folder=$folder
            # The original and its parents are already pinned. Validate the
            # captured bytes without reopening or rereading the SD card.
            # Invalid configs never receive authority for a replacement.
            try {
                $file.Extensions=[string[]]@(Get-OnionSetupExtensions $profile)
                $file.Expected=Get-OnionConfigPatch -Original $file.Bytes -Extensions $file.Extensions
            }
            catch{$file.Expected=$null}
        }
        if($Progress){$null=& $Progress 'Reading config files' 'Config files read and checked.' $profiles.Count $profiles.Count 'systems'}
        $handle=[pscustomobject]@{Id=([Guid]::NewGuid().ToString('N')+[Guid]::NewGuid().ToString('N'));StagedRoot=$state.StagedRoot}
        $state.Handle=$handle;$script:ApplicationSdStates[$handle.Id]=$state
        $registered=$true
        return $handle
    }finally{
        try {
            # Engine Stop bypasses catch; startup retains ownership until its
            # complete state is registered for Close-ApplicationSdSession.
            if(-not $registered){
                foreach($file in $state.Files.Values){if($file.Lease){$file.Lease.Dispose();$file.Lease=$null}}
                if($state.RootLease){$state.RootLease.Dispose();$state.RootLease=$null}
            }
        }finally{if($workLease){$workLease.Dispose()}}
    }
}

function Get-ApplicationSdSelection {
    param([Parameter(Mandatory=$true)]$Session)
    $state=Get-ApplicationSdState $Session
    foreach($profile in @(Get-OnionSetupProfiles $script:ApplicationSdCodeRoot)) {
        $folder=$profile.Folder;if($profile.EmuFolder){$folder=$profile.EmuFolder}
        $relative='Emu/'+$folder+'/config.json';$status='Unavailable';$reason='No config found';$available=$false
        if($state.Files.ContainsKey($relative)) {
            $file=$state.Files[$relative];$reason='Invalid config'
            if($null -ne $file.Expected) {
                $status=Get-OnionSetupExtensionState -Original $file.Bytes -Extensions @(Get-OnionSetupExtensions $profile)
                $available=$true;$reason=''
            }
        } elseif($state.UnavailableConfigs.ContainsKey($relative)) {
            $reason=$state.UnavailableConfigs[$relative].Reason
        }
        # Return display-only copies. Callers never receive bytes or leases.
        [pscustomobject]@{Id=[string]$profile.Folder;State=$status;Available=$available;Intent='Keep';Reason=$reason}
    }
}

function Set-ApplicationSdSelection {
    param([Parameter(Mandatory=$true)]$Session,[Parameter(Mandatory=$true)][object[]]$Items)
    $state=Get-ApplicationSdState $Session
    if($state.Completed -or $state.SelectionFinalized){throw 'SD selection has already been finalized.'}
    $profiles=@(Get-OnionSetupProfiles $script:ApplicationSdCodeRoot)
    # Startup already validated the pinned original bytes. Selection needs only
    # trusted IDs and availability, not the display-only extension state.
    $known=@(foreach($profile in $profiles) {
        $folder=$profile.Folder;if($profile.EmuFolder){$folder=$profile.EmuFolder}
        $relative='Emu/'+$folder+'/config.json'
        $available=$state.Files.ContainsKey($relative) -and $null -ne $state.Files[$relative].Expected
        [pscustomobject]@{Id=[string]$profile.Folder;Available=$available}
    })
    if($Items.Count -ne $known.Count){throw 'SD selection must include each installed system profile exactly once.'}
    $seen=@{};$expected=@{};$enable=New-Object 'Collections.Generic.List[string]';$disable=New-Object 'Collections.Generic.List[string]'
    foreach($item in $Items) {
        $id=[string]$item.Id;$match=@($known | Where-Object {$_.Id -ceq $id})
        if($match.Count -ne 1 -or $seen.ContainsKey($id)){throw 'Unknown or duplicate SD selection.'}
        $seen[$id]=$true;$trusted=$match[0]
        if($item.Available -isnot [bool] -or $item.Available -ne $trusted.Available -or $item.Intent -cnotin 'Keep','On','Off') {throw 'Invalid SD selection state.'}
        if(-not $trusted.Available -and $item.Intent -cne 'Keep'){throw 'Unavailable SD configs cannot be selected.'}
        $profile=@($profiles | Where-Object {$_.Folder -ceq $id})[0]
        $folder=$profile.Folder;if($profile.EmuFolder){$folder=$profile.EmuFolder}
        $relative='Emu/'+$folder+'/config.json'
        if(-not $state.Files.ContainsKey($relative)){continue}
        $file=$state.Files[$relative];$patch=$null
        if($trusted.Available) {
            $extensions=@(Get-OnionSetupExtensions $profile)
            switch -CaseSensitive ($item.Intent) {
                'Keep' {$patch=$file.Bytes}
                # Startup already computed the exact On patch from the pinned bytes.
                'On' {$patch=$file.Expected;$enable.Add($id)}
                'Off' {$patch=Get-OnionConfigPatch -Original $file.Bytes -Extensions @() -RemoveExtensions $extensions;$disable.Add($id)}
            }
        }
        $expected[$relative]=$patch
    }
    # Publish authority atomically only after the entire selection validates.
    foreach($relative in $expected.Keys){$state.Files[$relative].Expected=$expected[$relative]}
    $state.SelectionFinalized=$true
    return @{SelectionOnly=$true;EnableSystems=[string[]]$enable.ToArray();DisableSystems=[string[]]$disable.ToArray()}
}

function ConvertTo-ApplicationSdSelection {
    param([Parameter(Mandatory=$true)]$Session,[string[]]$EnableSystems=@(),[string[]]$DisableSystems=@())
    $items=@(Get-ApplicationSdSelection $Session);$seen=@{}
    foreach($intent in 'On','Off') {
        $ids=$EnableSystems;if($intent -eq 'Off'){$ids=$DisableSystems}
        foreach($id in $ids) {
            $match=@($items | Where-Object {$_.Id -eq $id})
            if($match.Count -ne 1 -or $seen.ContainsKey($id)){throw 'Unknown, duplicate or conflicting SD selection.'}
            $seen[$id]=$true;$match[0].Intent=$intent
        }
    }
    Set-ApplicationSdSelection -Session $Session -Items $items
}

function Invoke-ApplicationSdChecklist {
    param([Parameter(Mandatory=$true)]$SdSession,$ApplicationSession=$null)
    $items=@(Get-ApplicationSdSelection $SdSession);$message=''
    # Display is already owned by the parent; this session has no running worker.
    $controlC=$null
    try {
    if($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected) {
        $controlC=[Console]::TreatControlCAsInput;[Console]::TreatControlCAsInput=$true
    }
    while($true) {
        $model=Get-OnionSetupChecklistModel -Items $items -Message $message
        $answer=Read-ApplicationConsoleChoice -Model $model -Session $ApplicationSession -EscapeValue ([string][char]27)
        $message=''
        if([string]::Equals($answer,([string][char]27),[StringComparison]::Ordinal)){return $null}
        if($answer -in '','A'){return (Set-ApplicationSdSelection -Session $SdSession -Items $items)}
        $number=0
        if(-not [int]::TryParse($answer,[ref]$number) -or $number -lt 1 -or $number -gt $items.Count+1){$message='Choose a system number, A to apply, or Esc to cancel.';continue}
        if($number -eq 1) {
            $available=@($items | Where-Object {$_.Available})
            if(-not $available.Count){$message='No valid installed configs are available to change.';continue}
            $next='On';if(@($available | Where-Object {$_.State -ne 'On'}).Count -eq 0){$next='Off'}
            foreach($item in $available){$item.State=$next;$item.Intent=$next}
        } else {
            $item=$items[$number-2]
            if(-not $item.Available){$message=$item.Id+': '+$item.Reason+'.';continue}
            $next='On';if($item.State -eq 'On'){$next='Off'}
            $item.State=$next;$item.Intent=$next
        }
    }
    } finally {if($null -ne $controlC){[Console]::TreatControlCAsInput=$controlC}}
}

function Test-ApplicationSdCancellation($ApplicationSession) {
    if(-not $ApplicationSession){return $false}
    if($ApplicationSession.Failure){throw $ApplicationSession.Failure}
    if($ApplicationSession.CancellationRequested){return $true}
    if(-not $ApplicationSession.Interactive){return $false}
    if(-not $ApplicationSession.HasExited -or -not $ApplicationSession.IsRelayPaused){throw 'SD publication requires the finished application relay to be paused.'}
    # The worker input thread has ended. Only the trusted parent consumes keys
    # here, at boundaries where no config backup, write or restoration is active.
    while([Console]::KeyAvailable){
        $key=[Console]::ReadKey($true)
        if([int]$key.KeyChar -eq 3 -or ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control))){
            $ApplicationSession.Stop()
            if($ApplicationSession.Failure){throw $ApplicationSession.Failure}
            return $true
        }
    }
    return $false
}

function Get-ApplicationSdFileTypeState([byte[]]$Bytes,[string[]]$Extensions) {
    # Reporting must not interrupt a verified write or its recovery path.
    if($null -eq $Bytes -or -not $Extensions.Count){return 'Unknown'}
    try{return (Get-OnionSetupExtensionState -Original $Bytes -Extensions $Extensions)}
    catch{return 'Unknown'}
}

function Complete-ApplicationSdSession {
    param([Parameter(Mandatory=$true)]$Session,[scriptblock]$Progress,$ApplicationSession=$null)
    $state=Get-ApplicationSdState $Session
    if($state.Completed){throw 'SD setup result has already been consumed.'}
    $state.Completed=$true
    $results=New-Object 'Collections.Generic.List[object]';$stagedLeases=New-Object 'Collections.Generic.List[object]'
    $changed=0;$failed=0;$skipped=0;$cancelled=$false;$backupSetLease=$null
    try {
        # Freeze and validate the entire selected snapshot before any original
        # write. Extra child files are never imported or executed.
        $checked=0
        foreach($file in $state.Files.Values) {
            if($Progress){$null=& $Progress 'Checking selected changes' $file.Relative $checked $state.Files.Count 'files'}
            if(Test-ApplicationSdCancellation $ApplicationSession){$cancelled=$true;break}
            $target=Join-Path $state.StagedRoot $file.Relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
            $lease=[OptiMiyoo.OnionPathLease]::Open($target,$state.StagedRoot,$false,$false,$false);$stagedLeases.Add($lease)
            $bytes=Read-ApplicationSdBytes $lease.Stream 1048576
            if([Convert]::ToBase64String($bytes) -ceq [Convert]::ToBase64String($file.Bytes)){$checked++;continue}
            if($null -eq $file.Expected -or [Convert]::ToBase64String($bytes) -cne [Convert]::ToBase64String($file.Expected)){throw 'SD sandbox proposed an unapproved config change; originals kept.'}
            $file.Changed=$true
            $checked++
        }
        if(-not $cancelled -and $Progress){$null=& $Progress 'Checking selected changes' 'All staged files verified.' $checked $state.Files.Count 'files'}
        $configs=@((@($state.Files.Values | Where-Object {$_.Config})+@($state.UnavailableConfigs.Values)) | Sort-Object Relative)
        for($index=0;-not $cancelled -and $index -lt $configs.Count;$index++) {
            $file=$configs[$index]
            if($Progress){$null=& $Progress 'Saving config changes' $file.Folder $index $configs.Count 'systems'}
            if(Test-ApplicationSdCancellation $ApplicationSession){$cancelled=$true;break}
            if($state.UnavailableConfigs.ContainsKey($file.Relative)){
                $skipped++;$results.Add([pscustomobject]@{System=$file.Folder;State='Kept';FileTypeState='Unknown';Failed=$false;Reason=$file.Reason});continue
            }
            if(-not $file.Changed){
                $before=Get-ApplicationSdFileTypeState $file.Bytes $file.Extensions
                $skipped++;$results.Add([pscustomobject]@{System=$file.Folder;State='Kept';FileTypeState=$before;Failed=$false});continue
            }
            $after=Get-ApplicationSdFileTypeState $file.Expected $file.Extensions
            $writeLease=$null;$backupLease=$null;$backupDirectoryLease=$null;$writeStarted=$false;$restored=$false
            try {
                $file.Lease.Dispose();$file.Lease=$null
                $writeLease=[OptiMiyoo.OnionPathLease]::Open($file.Path,$state.OriginalRoot,$false,$true,$false)
                $current=Read-ApplicationSdBytes $writeLease.Stream 1048576
                if([Convert]::ToBase64String($current) -cne [Convert]::ToBase64String($file.Bytes)){throw 'Original SD config changed during setup.'}
                if(-not $state.BackupRoot){
                    $backupSetLease=[OptiMiyoo.OnionPathLease]::CreateBackupSet($state.OriginalRoot)
                    $state.BackupRoot=$backupSetLease.DirectoryPath
                }
                $backup=Join-Path (Join-Path $state.BackupRoot 'Emu') $file.Folder
                Assert-PlainOnionPath $backup $state.OriginalRoot
                $backupDirectoryLease=[OptiMiyoo.OnionPathLease]::CreateDirectory($backup,$state.OriginalRoot)
                $backupPath=Join-Path $backup 'config.json'
                $backupLease=[OptiMiyoo.OnionPathLease]::Open($backupPath,$state.OriginalRoot,$false,$true,$true)
                # Creating a filename is not proof of a recoverable backup. Keep
                # failed or partial writes explicitly excluded from recovery advice.
                $backupRecord=[pscustomobject]@{System=$file.Folder;Path=$backupPath};$state.UnverifiedBackups.Add($backupRecord)
                & $script:ApplicationSdModule {param($stream,$bytes)Write-OnionBytesVerified $stream $bytes 'SD backup'} $backupLease.Stream $file.Bytes
                [void]$state.UnverifiedBackups.Remove($backupRecord);$state.VerifiedBackups.Add($backupRecord)
                $writeStarted=$true
                & $script:ApplicationSdModule {param($stream,$bytes)Write-OnionBytesVerified $stream $bytes 'Updated config'} $writeLease.Stream $file.Expected
                $changed++;$results.Add([pscustomobject]@{System=$file.Folder;State='Updated';FileTypeState=$after;Failed=$false})
            }catch {
                $failed++
                if($writeStarted -and $writeLease) {
                    try{& $script:ApplicationSdModule {param($stream,$bytes)Write-OnionBytesVerified $stream $bytes 'Restored config'} $writeLease.Stream $file.Bytes;$restored=$true}
                    catch{
                        $recovery='SD restoration failed; restore '+(ConvertTo-SafeExternalText $file.Path)+' from verified backup '+(ConvertTo-SafeExternalText $backupPath)+' before using this card.'
                        foreach($unverified in $state.UnverifiedBackups){$recovery+=' Do not restore from incomplete or unverified backup: '+(ConvertTo-SafeExternalText $unverified.Path)+'.'}
                        throw $recovery
                    }
                }
                $result='Kept';if($restored){$result='Restored'}
                $results.Add([pscustomobject]@{System=$file.Folder;State=$result;FileTypeState='Unknown';Failed=$true})
            }finally{
                # A failed backup close must not leave the config write handle
                # or its parent directory pins held after setup has stopped.
                try{if($backupLease){$backupLease.Dispose()}}
                finally{
                    try{if($backupDirectoryLease){$backupDirectoryLease.Dispose()}}
                    finally{if($writeLease){$writeLease.Dispose()}}
                }
            }
        }
        if(-not $cancelled){$cancelled=Test-ApplicationSdCancellation $ApplicationSession}
        if(-not $cancelled -and $Progress){$null=& $Progress 'SD setup finished' ('Updated: {0}; skipped: {1}; failed: {2}.' -f $changed,$skipped,$failed) $configs.Count $configs.Count 'systems'}
        return [pscustomobject]@{Changed=$changed;Skipped=$skipped;Failed=$failed;Cancelled=$cancelled;BackupRoot=$state.BackupRoot;VerifiedBackups=$state.VerifiedBackups.ToArray();UnverifiedBackups=$state.UnverifiedBackups.ToArray();Results=$results.ToArray()}
    }finally{
        try{foreach($lease in $stagedLeases){$lease.Dispose()}}
        finally{if($backupSetLease){$backupSetLease.Dispose()}}
    }
}

function Close-ApplicationSdSession {
    param([Parameter(Mandatory=$true)]$Session)
    $state=Get-ApplicationSdState $Session;$state.Closed=$true
    try{foreach($file in $state.Files.Values){if($file.Lease){$file.Lease.Dispose();$file.Lease=$null}}}
    finally{if($state.RootLease){$state.RootLease.Dispose();$state.RootLease=$null};$script:ApplicationSdStates.Remove($Session.Id)}
}

function Get-ApplicationSdResultLines {
    param([Parameter(Mandatory=$true)]$Result)
    if($Result.Cancelled){'SD setup cancelled. Completed updates and backups were kept.'}
    else {'SD setup finished.'}
    'Updated: {0} | Skipped: {1} | Failed: {2}' -f $Result.Changed,$Result.Skipped,$Result.Failed
    if ($Result.Changed) {"Refresh Onion's game list."}
    elseif (-not $Result.Failed) {'No configs were changed.'}
    if ($Result.Failed) {'Some configs could not be updated.'}
    if ($Result.Results) {''}
    foreach ($item in $Result.Results) {
        $status=[string]$item.State
        if ($status -eq 'Kept') {$status='Unchanged'}
        if($item.Failed) {
            $status='Failed (no changes saved)'
            if($item.State -eq 'Restored'){$status='Failed (original settings restored)'}
        } elseif($item.FileTypeState) {
            if($item.State -eq 'Updated') {
                switch($item.FileTypeState){'On'{$status='Enabled'}'Off'{$status='Disabled'}}
            } elseif($item.State -eq 'Kept') {
                switch($item.FileTypeState){
                    'On'{$status='Already on'}
                    'Off'{$status='Already off'}
                    'Partial'{$status='Unchanged (partly enabled)'}
                    'Unknown'{$status='Unchanged (unverified)'}
                }
            }
        }
        ConvertTo-ApplicationPromptPath ($item.System+': '+$status)
    }
    if ($Result.VerifiedBackups) {
        ''
        'Verified original config backups:'
        foreach($backup in $Result.VerifiedBackups){ConvertTo-ApplicationPromptPath ($backup.System+': '+$backup.Path)}
    }
    if ($Result.UnverifiedBackups) {
        ''
        'Incomplete or unverified backups; do not restore:'
        foreach($backup in $Result.UnverifiedBackups){ConvertTo-ApplicationPromptPath ($backup.System+': '+$backup.Path)}
    }
}

function Get-ApplicationSdResultModel {
    param([Parameter(Mandatory=$true)]$Result,[int]$Page=0,[long]$Anchor=-1)
    $sourceLines=@(Get-ApplicationSdResultLines -Result $Result)
    $title='Onion SD setup / results';$prompt='Enter / Esc: Main menu | Q: Exit'
    # Let the shared renderer reclaim artwork or paragraph gaps before paging.
    # Without an initialized viewport, retain the conservative minimum panel.
    $textWidth=44;$pageSize=11
    if($script:UiColumns -ge 44 -and $script:UiHeight -gt 0) {
        $whole=Get-MenuLayout -Rows $sourceLines
        if($whole.Fits) {
            return [pscustomobject]@{Title=$title;Lines=@($whole.Rows);Prompt=$prompt;Page=0;Pages=1;Anchor=0L;TextWidth=$whole.TextWidth;PageSize=$whole.BodyRows}
        }
        $empty=Get-MenuLayout -Rows @('')
        $textWidth=$empty.TextWidth
        $overhead=8
        if($empty.ShowMio -and $script:UiHeight -ge 26){$overhead=14}
        $wrappedCount=@(Get-MenuRows $sourceLines $textWidth).Count
        $navigationRows=@(Get-MenuRows @(('Page {0}/{0} | > Next | < Previous' -f $wrappedCount)) $textWidth).Count
        $pageSize=[Math]::Max(3,$script:UiHeight-$overhead-$navigationRows)
    }
    # Keep backup headings with their first data row. Logical character anchors
    # retain the current part of a long report when resize changes its wrapping.
    $pageRows=New-Object 'Collections.Generic.List[string]'
    $pageList=New-Object 'Collections.Generic.List[object]'
    $separator=$false;$offset=0L;$pageAnchor=0L
    foreach ($line in $sourceLines) {
        if (-not $line) {$separator=($pageRows.Count -gt 0);continue}
        $wrapped=@(Get-MenuRows @($line) $textWidth)
        $needed=1
        if ($line -in @('Verified original config backups:','Incomplete or unverified backups; do not restore:')) {$needed=$wrapped.Count+1}
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

function Read-ApplicationSdResult {
    param([Parameter(Mandatory=$true)]$Result,[switch]$NoAnimation,[switch]$NoColor,
          [ValidateSet('CRT','Smooth')][string]$DisplayEffect='CRT')
    $previousEffect=$script:DisplayEffect;$display=$false;$page=0;$anchor=-1L;$inputText=''
    try {
        $script:DisplayEffect=$DisplayEffect
        Initialize-Display;$display=$true
        while ($true) {
            [void](Update-DisplaySize)
            $model=Get-ApplicationSdResultModel -Result $Result -Page $page -Anchor $anchor
            $answer=Read-ApplicationConsoleChoice $model -ReturnOnResize -InitialText $inputText
            if($answer -isnot [string] -and $answer.Resized) {$page=$model.Page;if($anchor -lt 0){$anchor=$model.Anchor};$inputText=$answer.InputText;continue}
            $inputText='';$anchor=-1L
            if ($answer -in '', 'B') {return $true}
            if ($answer -eq 'Q') {return $false}
            if ($answer -eq '>') {$page=[Math]::Min($model.Page+1,$model.Pages-1)}
            elseif ($answer -eq '<') {$page=[Math]::Max(0,$model.Page-1)}
            else {$page=$model.Page}
        }
    }finally {
        try {if ($display) {Restore-Display}}
        finally {$script:DisplayEffect=$previousEffect}
    }
}

function Show-ApplicationSdResult {
    param([Parameter(Mandatory=$true)]$Result,[switch]$NoPause,[switch]$NoAnimation,[switch]$NoColor,
          [ValidateSet('CRT','Smooth')][string]$DisplayEffect='CRT')
    if ($NoPause -or $Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        foreach ($line in @(Get-ApplicationSdResultLines -Result $Result)) {Write-Host $line}
        return $true
    }
    Read-ApplicationSdResult -Result $Result -NoAnimation:$NoAnimation -NoColor:$NoColor -DisplayEffect $DisplayEffect
}

function Resolve-ApplicationSdInput([string]$Text) {
    $choice=[pscustomobject]@{Path=$null;Error=$null}
    # Only surrounding ASCII spaces are prompt padding. Unicode whitespace can
    # be part of a real folder name and must not select a different sibling.
    $candidate=$Text.Trim(' ').Trim('"')
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $choice.Error='Enter your SD path, e.g. E:\, or press Esc to go back.';return $choice
    }
    # IsPathRooted also accepts drive-relative B: and current-drive \folder.
    # The SD prompt must never resolve those against the app's working folder.
    $drive=($candidate -match '^[A-Za-z]:[\\/]')
    $unc=($candidate -match '^\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$)')
    if ((-not $drive -and -not $unc) -or $candidate.StartsWith('\\?\') -or $candidate.StartsWith('\\.\') -or
        $candidate -match '[\x00-\x1f<>|"*?]' -or ($drive -and $candidate.Substring(2).Contains(':')) -or ($unc -and $candidate.Contains(':'))) {
        $choice.Error='Use a full SD path, e.g. E:\, or press Esc to go back.';return $choice
    }
    try {$choice.Path=[IO.Path]::GetFullPath($candidate)}
    catch {$choice.Error='Check the SD path, or press Esc to go back.'}
    # Some Windows PowerShell runtimes trim Unicode whitespace in GetFullPath.
    # Refuse that normalization rather than silently selecting a sibling folder.
    $trailingWhitespace=[regex]::Match($candidate,'\s+$').Value
    if($choice.Path -and $trailingWhitespace -and -not $choice.Path.EndsWith($trailingWhitespace,[StringComparison]::Ordinal)){
        $choice.Path=$null
        $choice.Error='Windows cannot preserve the end of this SD path. Use another path, or press Esc to go back.'
    }
    return $choice
}

function Read-ApplicationSdConsolePath {
    param([string]$InitialText='', [string]$ErrorMessage='', $Session=$null)
    if($Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected){throw 'SD selection requires the parent console.'}
    $title='Onion SD setup';$prompt='SD drive or folder (for example E:\) / Esc: Back'
    if ($ErrorMessage) {$prompt=$ErrorMessage}
    $rows=@(Get-OnionSetupPathRows);$text=$InitialText;$dirty=$true
    [void](Update-DisplaySize)
    $layout=Get-MenuLayout -Rows $rows
    $sparseIdle=(-not $NoAnimation -and $script:UiVT)
    $idleWatch=$null;$script:UiIdlePoseOverride=$null
    Reset-MioSparseCrt
    if($sparseIdle){Reset-MioIdleInput;$idleWatch=[Diagnostics.Stopwatch]::StartNew()}
    $fallbackTextLength=0
    if(-not $script:UiVT){
        $visibleText=ConvertTo-SafeExternalLine $text;$fallbackTextLength=$visibleText.Length
        [Console]::WriteLine($title);foreach($line in $rows){[Console]::WriteLine($line)};[Console]::Write($prompt+': '+$visibleText)
    }
    try {while($true) {
        if(Update-DisplaySize -Throttled){$layout=Get-MenuLayout -Rows $rows;$dirty=$true}
        $bunnyVisible=($script:UiVT -and $layout.Fits -and $layout.ShowMio)
        if($sparseIdle) {
            $pose=Get-MioIdlePose $idleWatch.Elapsed.TotalMilliseconds ($text.Length -gt 0 -or -not $bunnyVisible)
            if($pose -cne $script:UiIdlePoseOverride){$script:UiIdlePoseOverride=$pose;$dirty=$true}
        }
        if(Update-MioSparseCrt $script:UiEffectClock.Elapsed.TotalMilliseconds ($text.Length -gt 0) $bunnyVisible){$dirty=$true}
        if($script:UiVT -and $dirty){
            # Escape only the displayed copy; edits and path resolution use the
            # original characters, including valid Unicode filename controls.
            $visibleText=ConvertTo-SafeExternalLine $text
            Draw-MenuPanel $title $rows $prompt $visibleText $visibleText.Length 'wait';$dirty=$false
        }
        if([Console]::KeyAvailable) {
            $key=[Console]::ReadKey($true)
            if($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                if($Session){$Session.Stop()}
                throw [OperationCanceledException]::new('Application cancelled.')
            }
            if($sparseIdle){$idleWatch.Restart();Reset-MioIdleInput;$script:UiIdlePoseOverride='idle';$dirty=$true}
            if($key.Key -eq [ConsoleKey]::Escape){return $null}
            if($script:UiVT -and $key.Key -eq [ConsoleKey]::Enter -and (Update-DisplaySize)){
                $layout=Get-MenuLayout -Rows $rows;$dirty=$true;continue
            }
            if($script:UiVT -and -not $layout.Fits){continue}
            if($key.Key -eq [ConsoleKey]::Enter){
                if(-not $script:UiVT){[Console]::WriteLine()}
                $selected=$text.Trim(' ').Trim('"')
                return $selected
            }
            if($key.Key -eq [ConsoleKey]::Backspace){if($text.Length){$text=$text.Substring(0,(Get-InputCaretOffset $text $text.Length -1))}}
            elseif($key.KeyChar -ne [char]0 -and $text.Length -lt 32767){$text+=[string]$key.KeyChar}
            $dirty=$true
            if(-not $script:UiVT){
                $visibleText=ConvertTo-SafeExternalLine $text
                [Console]::Write("`r"+$prompt+': '+$visibleText+(' '*[Math]::Max(1,$fallbackTextLength-$visibleText.Length)))
                $fallbackTextLength=$visibleText.Length
            }
        }else{Wait-DisplayFrame 30}
    }} finally {$script:UiIdlePoseOverride=$null;Reset-MioSparseCrt;if($idleWatch){$idleWatch.Stop()}}
}

function Invoke-ApplicationSdFolderPrompt {
    param([Parameter(Mandatory=$true)]$Session,[switch]$NoAnimation,[switch]$NoColor,
          [ValidateSet('CRT','Smooth')][string]$DisplayEffect='CRT')
    $paused=$false;$display=$false;$selected=$null;$previousEffect=$script:DisplayEffect
    try {
        [void]$Session.PauseRelay();if(-not $Session.IsRelayPaused){throw 'The application relay did not surrender the parent console.'};$paused=$true
        $script:DisplayEffect=$DisplayEffect
        Initialize-Display;$display=$true;$text='';$message=''
        while ($true) {
            $selected=Read-ApplicationSdConsolePath -InitialText $text -ErrorMessage $message -Session $Session
            if ($null -eq $selected) {break}
            $choice=Resolve-ApplicationSdInput $selected
            $text=$selected
            if ($choice.Error) {$message=$choice.Error;continue}
            if (-not [IO.Directory]::Exists($choice.Path)) {
                $message='Folder not found. Check your SD path, or press Esc to go back.';continue
            }
            if (-not [IO.Directory]::Exists((Join-Path $choice.Path 'Emu'))) {
                $message='No Emu folder here. Choose your SD root, or press Esc to go back.';continue
            }
            $selected=$choice.Path;break
        }
    }finally {
        try{if($display){Restore-Display}}
        finally{$script:DisplayEffect=$previousEffect;if($paused -and -not $Session.CancellationRequested){if($Session.HasExited){throw 'The isolated application exited during SD selection.'};[void]$Session.ResumeRelay()}}
    }
    return $selected
}
