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

function Get-ApplicationSdHash([IO.Stream]$Stream) {
    $Stream.Position=0;$sha=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($sha.ComputeHash($Stream)).Replace('-','')}finally{$sha.Dispose();$Stream.Position=0}
}

function Add-ApplicationSdSnapshotFile($State,[string]$Relative,[long]$Maximum,[switch]$Config) {
    if($State.Files.ContainsKey($Relative)){return}
    # Callers supply only fixed profile paths and a core basename parsed by the
    # installed literal-launcher parser; no path is taken from the child.
    $path=Join-Path $State.OriginalRoot $Relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
    if(-not (Test-Path -LiteralPath $path)){return}
    $lease=[OptiMiyoo.OnionPathLease]::Open($path,$State.OriginalRoot,$false,$false,$false);$output=$null
    try {
        if($lease.Stream.Length -gt $Maximum -or $State.TotalBytes+$lease.Stream.Length -gt 2147483648){throw 'SD snapshot exceeds its supported inspection size.'}
        $target=Join-Path $State.StagedRoot $Relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        $output=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $lease.Stream.CopyTo($output);$output.Flush($true);$output.Dispose();$output=$null
        $hash=Get-ApplicationSdHash $lease.Stream;$bytes=$null
        if($Config){$bytes=Read-ApplicationSdBytes $lease.Stream $Maximum}
        $State.TotalBytes+=$lease.Stream.Length
        $State.Files[$Relative]=[pscustomobject]@{Path=$path;Relative=$Relative;Lease=$lease;Length=$lease.Stream.Length;Hash=$hash;Bytes=$bytes;Config=[bool]$Config;Expected=$null;Changed=$false;Folder=''}
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
    $state=[pscustomobject]@{Handle=$null;OriginalRoot=$original;StagedRoot=(Join-Path $work 'Onion');RootLease=$null;Files=@{};TotalBytes=0L;Closed=$false;Completed=$false;BackupRoot=$null;VerifiedBackups=(New-Object 'Collections.Generic.List[object]');UnverifiedBackups=(New-Object 'Collections.Generic.List[object]')}
    $workLease=$null
    try {
        $state.RootLease=[OptiMiyoo.OnionPathLease]::Open($original,$original,$true,$false,$false)
        $cores=Join-Path $original 'RetroArch/.retroarch/cores'
        $coresLease=[OptiMiyoo.OnionPathLease]::Open($cores,$original,$true,$false,$false);$coresLease.Dispose()
        $workLease=[OptiMiyoo.OnionPathLease]::Open($work,$work,$true,$false,$false)
        if(Test-Path -LiteralPath $state.StagedRoot){throw 'SD snapshot needs a fresh Onion staging folder.'}
        [void][IO.Directory]::CreateDirectory((Join-Path $state.StagedRoot 'RetroArch/.retroarch/cores'))
        $profiles=@(Get-OnionSetupProfiles $script:ApplicationSdCodeRoot)
        for($index=0;$index -lt $profiles.Count;$index++) {
            $profile=$profiles[$index]
            $folder=$profile.Folder;if($profile.EmuFolder){$folder=$profile.EmuFolder}
            if($folder -notmatch '^[A-Z0-9]+$'){throw 'Invalid installed SD profile.'}
            if($Progress){$null=& $Progress 'Reading SD setup files' $folder $index $profiles.Count 'systems'}
            $config='Emu/'+$folder+'/config.json';$launch='Emu/'+$folder+'/launch.sh'
            Add-ApplicationSdSnapshotFile $state $config 1048576 -Config
            if(-not $state.Files.ContainsKey($config)){continue}
            Add-ApplicationSdSnapshotFile $state $launch 262144
            if($state.Files.ContainsKey($launch)) {
                $selected=$null
                try{$text=[Text.Encoding]::UTF8.GetString((Read-ApplicationSdBytes $state.Files[$launch].Lease.Stream 262144));$selected=Get-SelectedRetroArchCore $text}catch{}
                if($selected -and $selected -in @($profile.SupportedCores)) {Add-ApplicationSdSnapshotFile $state ('RetroArch/.retroarch/cores/'+$selected) 536870912}
            }
        }
        if($Progress){$null=& $Progress 'Reading SD setup files' 'SD setup files collected.' $profiles.Count $profiles.Count 'systems'}
        for($index=0;$index -lt $profiles.Count;$index++) {
            $profile=$profiles[$index]
            $folder=$profile.Folder;if($profile.EmuFolder){$folder=$profile.EmuFolder}
            if($Progress){$null=& $Progress 'Checking supported file types' $folder $index $profiles.Count 'systems'}
            $relative='Emu/'+$folder+'/config.json';if(-not $state.Files.ContainsKey($relative)){continue}
            $file=$state.Files[$relative];$file.Folder=$folder
            $support=& $script:ApplicationSdModule {param($profile,$root)Get-OnionSetupSupport $profile $root} $profile $original
            # An unverified profile remains visible in the staged assessment but
            # has no publication authority, even if the child changes its core.
            if($support.CanBuild -and $state.Files.ContainsKey('Emu/'+$folder+'/launch.sh') -and $state.Files.ContainsKey('RetroArch/.retroarch/cores/'+$support.Core)) {
                try {
                    $extensions=@(& $script:ApplicationSdModule {param($profile,$root,$support)Get-OnionSetupExtensions $profile $root $support} $profile $original $support)
                    $file.Expected=Get-OnionConfigPatch -Original $file.Bytes -Extensions $extensions
                }
                catch{$file.Expected=$null}
            }
        }
        if($Progress){$null=& $Progress 'Checking supported file types' 'Ready for isolated setup checks.' $profiles.Count $profiles.Count 'systems'}
        $handle=[pscustomobject]@{Id=([Guid]::NewGuid().ToString('N')+[Guid]::NewGuid().ToString('N'));StagedRoot=$state.StagedRoot}
        $state.Handle=$handle;$script:ApplicationSdStates[$handle.Id]=$state
        return $handle
    }catch {
        foreach($file in $state.Files.Values){if($file.Lease){$file.Lease.Dispose()}}
        if($state.RootLease){$state.RootLease.Dispose()}
        throw
    }finally{if($workLease){$workLease.Dispose()}}
}

function Complete-ApplicationSdSession {
    param([Parameter(Mandatory=$true)]$Session,[scriptblock]$Progress)
    $state=Get-ApplicationSdState $Session
    if($state.Completed){throw 'SD setup result has already been consumed.'}
    $state.Completed=$true
    $results=New-Object 'Collections.Generic.List[object]';$stagedLeases=New-Object 'Collections.Generic.List[object]'
    $changed=0;$failed=0;$skipped=0
    try {
        # Freeze and validate the entire selected snapshot before any original
        # write. Extra child files are never imported or executed.
        $checked=0
        foreach($file in $state.Files.Values) {
            if($Progress){$null=& $Progress 'Verifying SD setup changes' $file.Relative $checked $state.Files.Count 'files'}
            $target=Join-Path $state.StagedRoot $file.Relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
            $lease=[OptiMiyoo.OnionPathLease]::Open($target,$state.StagedRoot,$false,$false,$false);$stagedLeases.Add($lease)
            if($file.Config) {
                $bytes=Read-ApplicationSdBytes $lease.Stream 1048576
                if([Convert]::ToBase64String($bytes) -ceq [Convert]::ToBase64String($file.Bytes)){$checked++;continue}
                if($null -eq $file.Expected -or [Convert]::ToBase64String($bytes) -cne [Convert]::ToBase64String($file.Expected)){throw 'SD sandbox proposed an unapproved config change; originals kept.'}
                $file.Changed=$true
            } elseif($lease.Stream.Length -ne $file.Length -or (Get-ApplicationSdHash $lease.Stream) -cne $file.Hash){throw 'SD sandbox changed a launcher or core; originals kept.'}
            $checked++
        }
        if($Progress){$null=& $Progress 'Verifying SD setup changes' 'All staged files verified.' $checked $state.Files.Count 'files'}
        $configs=@($state.Files.Values | Where-Object {$_.Config} | Sort-Object Relative)
        for($index=0;$index -lt $configs.Count;$index++) {
            $file=$configs[$index]
            if($Progress){$null=& $Progress 'Updating SD file lists' $file.Folder $index $configs.Count 'systems'}
            if(-not $file.Changed){$skipped++;$results.Add([pscustomobject]@{System=$file.Folder;State='Kept'});continue}
            $writeLease=$null;$backupLease=$null;$writeStarted=$false;$restored=$false
            try {
                $file.Lease.Dispose();$file.Lease=$null
                $writeLease=[OptiMiyoo.OnionPathLease]::Open($file.Path,$state.OriginalRoot,$false,$true,$false)
                $current=Read-ApplicationSdBytes $writeLease.Stream 1048576
                if([Convert]::ToBase64String($current) -cne [Convert]::ToBase64String($file.Bytes)){throw 'Original SD config changed during setup.'}
                if(-not $state.BackupRoot){$state.BackupRoot=Join-Path $state.OriginalRoot ('OptiMiyoo_Backup_'+[Guid]::NewGuid().ToString('N'))}
                $backup=Join-Path $state.BackupRoot $file.Folder
                Assert-PlainOnionPath $backup $state.OriginalRoot;[void][IO.Directory]::CreateDirectory($backup)
                $backupPath=Join-Path $backup 'config.json'
                $backupLease=[OptiMiyoo.OnionPathLease]::Open($backupPath,$state.OriginalRoot,$false,$true,$true)
                # Creating a filename is not proof of a recoverable backup. Keep
                # failed or partial writes explicitly excluded from recovery advice.
                $backupRecord=[pscustomobject]@{System=$file.Folder;Path=$backupPath};$state.UnverifiedBackups.Add($backupRecord)
                & $script:ApplicationSdModule {param($stream,$bytes)Write-OnionBytesVerified $stream $bytes 'SD backup'} $backupLease.Stream $file.Bytes
                [void]$state.UnverifiedBackups.Remove($backupRecord);$state.VerifiedBackups.Add($backupRecord)
                $writeStarted=$true
                & $script:ApplicationSdModule {param($stream,$bytes)Write-OnionBytesVerified $stream $bytes 'Updated config'} $writeLease.Stream $file.Expected
                $changed++;$results.Add([pscustomobject]@{System=$file.Folder;State='Updated'})
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
                $results.Add([pscustomobject]@{System=$file.Folder;State=$result})
            }finally{if($backupLease){$backupLease.Dispose()};if($writeLease){$writeLease.Dispose()}}
        }
        if($Progress){$null=& $Progress 'SD setup finished' ('Updated: {0}; skipped: {1}; failed: {2}.' -f $changed,$skipped,$failed) $configs.Count $configs.Count 'systems'}
        return [pscustomobject]@{Changed=$changed;Skipped=$skipped;Failed=$failed;BackupRoot=$state.BackupRoot;VerifiedBackups=$state.VerifiedBackups.ToArray();UnverifiedBackups=$state.UnverifiedBackups.ToArray();Results=$results.ToArray()}
    }finally{foreach($lease in $stagedLeases){$lease.Dispose()}}
}

function Close-ApplicationSdSession {
    param([Parameter(Mandatory=$true)]$Session)
    $state=Get-ApplicationSdState $Session;$state.Closed=$true
    try{foreach($file in $state.Files.Values){if($file.Lease){$file.Lease.Dispose();$file.Lease=$null}}}
    finally{if($state.RootLease){$state.RootLease.Dispose();$state.RootLease=$null};$script:ApplicationSdStates.Remove($Session.Id)}
}

function Get-ApplicationSdResultLines {
    param([Parameter(Mandatory=$true)]$Result)
    'SD setup finished.'
    'Updated: {0} | Skipped: {1} | Failed: {2}' -f $Result.Changed,$Result.Skipped,$Result.Failed
    if ($Result.Changed) {"Refresh Onion's game list."}
    elseif (-not $Result.Failed) {'No configs were changed.'}
    if ($Result.Failed) {'Some configs could not be updated.'}
    foreach ($item in $Result.Results) {
        $status=[string]$item.State
        if ($status -eq 'Kept') {$status='Unchanged'}
        ConvertTo-ApplicationPromptPath ($item.System+': '+$status)
    }
    if ($Result.VerifiedBackups) {
        'Verified original config backups:'
        foreach($backup in $Result.VerifiedBackups){ConvertTo-ApplicationPromptPath ($backup.System+': '+$backup.Path)}
    }
    if ($Result.UnverifiedBackups) {
        'Incomplete or unverified backups; do not restore:'
        foreach($backup in $Result.UnverifiedBackups){ConvertTo-ApplicationPromptPath ($backup.System+': '+$backup.Path)}
    }
}

function Get-ApplicationSdResultModel {
    param([Parameter(Mandatory=$true)]$Result,[int]$Page=0)
    # Wrap before paging so even long redirected-drive paths fit the normal panel.
    $rows=@(Get-MenuRows @(Get-ApplicationSdResultLines -Result $Result) 44)
    $pageSize=11
    $pages=[Math]::Max(1,[int][Math]::Ceiling($rows.Count/[double]$pageSize))
    $page=[Math]::Max(0,[Math]::Min($Page,$pages-1))
    $lines=@($rows | Select-Object -Skip ($page*$pageSize) -First $pageSize)
    if ($pages -gt 1) {$lines+=('Page {0}/{1} | > Next | < Previous' -f ($page+1),$pages)}
    [pscustomobject]@{
        Title='Onion SD setup / results';Lines=$lines
        Prompt='Enter / Esc: Main menu | Q: Exit';Page=$page;Pages=$pages
    }
}

function Read-ApplicationSdResult {
    param([Parameter(Mandatory=$true)]$Result,[switch]$NoAnimation,[switch]$NoColor,
          [ValidateSet('CRT','Smooth')][string]$DisplayEffect='CRT')
    $previousEffect=$script:DisplayEffect;$display=$false;$page=0
    try {
        $script:DisplayEffect=$DisplayEffect
        Initialize-Display;$display=$true
        while ($true) {
            $model=Get-ApplicationSdResultModel -Result $Result -Page $page
            $answer=Read-ApplicationConsoleChoice $model
            if ($answer -in '', 'B') {return $true}
            if ($answer -eq 'Q') {return $false}
            if ($answer -eq '>') {$page=[Math]::Min($model.Page+1,$model.Pages-1)}
            elseif ($answer -eq '<') {$page=[Math]::Max(0,$model.Page-1)}
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
    $candidate=$Text.Trim().Trim('"')
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
    return $choice
}

function Read-ApplicationSdConsolePath {
    param([string]$InitialText='', [string]$ErrorMessage='', $Session=$null)
    if($Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected){throw 'SD selection requires the parent console.'}
    $title='Onion SD setup';$prompt='SD drive or folder (for example E:\) / Esc: Back'
    if ($ErrorMessage) {$prompt=$ErrorMessage}
    $rows=@(Get-OnionSetupMenuRows)+@('Esc. Back to main menu');$text=$InitialText;$dirty=$true
    [void](Update-DisplaySize)
    $layout=Get-MenuLayout -Rows $rows
    $sparseIdle=(-not $NoAnimation -and $script:UiVT)
    $idleWatch=$null;$script:UiIdlePoseOverride=$null
    Reset-MioSparseCrt
    if($sparseIdle){Reset-MioIdleInput;$idleWatch=[Diagnostics.Stopwatch]::StartNew()}
    if(-not $script:UiVT){[Console]::WriteLine($title);foreach($line in $rows){[Console]::WriteLine($line)};[Console]::Write($prompt+': ')}
    try {while($true) {
        if(Update-DisplaySize -Throttled){$layout=Get-MenuLayout -Rows $rows;$dirty=$true}
        $bunnyVisible=($script:UiVT -and $layout.Fits -and $layout.ShowMio)
        if($sparseIdle) {
            $pose=Get-MioIdlePose $idleWatch.Elapsed.TotalMilliseconds ($text.Length -gt 0 -or -not $bunnyVisible)
            if($pose -cne $script:UiIdlePoseOverride){$script:UiIdlePoseOverride=$pose;$dirty=$true}
        }
        if(Update-MioSparseCrt $script:UiEffectClock.Elapsed.TotalMilliseconds ($text.Length -gt 0) $bunnyVisible){$dirty=$true}
        if($script:UiVT -and $dirty){Draw-MenuPanel $title $rows $prompt $text $text.Length 'wait';$dirty=$false}
        if([Console]::KeyAvailable) {
            $key=[Console]::ReadKey($true)
            if($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                if($Session){$Session.Stop()}
                throw [OperationCanceledException]::new('Application cancelled.')
            }
            if($sparseIdle){$idleWatch.Restart();Reset-MioIdleInput;$script:UiIdlePoseOverride='idle';$dirty=$true}
            if($key.Key -eq [ConsoleKey]::Escape){return $null}
            if($script:UiVT -and -not $layout.Fits){continue}
            if($key.Key -eq [ConsoleKey]::Enter){
                if(-not $script:UiVT){[Console]::WriteLine()}
                $selected=$text.Trim().Trim('"')
                return $selected
            }
            if($key.Key -eq [ConsoleKey]::Backspace -and $text.Length){$text=$text.Substring(0,(Get-InputCaretOffset $text $text.Length -1))}
            elseif(-not [char]::IsControl($key.KeyChar) -and $key.KeyChar -notmatch '[\u202a-\u202e\u2066-\u2069]' -and $text.Length -lt 32767){$text+=[string]$key.KeyChar}
            $dirty=$true
            if(-not $script:UiVT){[Console]::Write("`r"+$prompt+': '+$text+' ')}
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
            if (-not [IO.Directory]::Exists((Join-Path $choice.Path 'RetroArch/.retroarch/cores'))) {
                $message='No Onion cores here. Choose your SD root, or press Esc to go back.';continue
            }
            $selected=$choice.Path;break
        }
    }finally {
        try{if($display){Restore-Display}}
        finally{$script:DisplayEffect=$previousEffect;if($paused -and -not $Session.CancellationRequested){if($Session.HasExited){throw 'The isolated application exited during SD selection.'};[void]$Session.ResumeRelay()}}
    }
    return $selected
}
