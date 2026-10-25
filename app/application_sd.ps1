# The SD root comes from the original command line or the parent's own console.
# Child output can only request the exact extension patch computed here from
# frozen original bytes; it cannot supply a host path, replacement, or backup.
. (Join-Path $PSScriptRoot 'compile_support.ps1')
. (Join-Path $PSScriptRoot 'core_support.ps1')
. (Join-Path $PSScriptRoot 'application_prompts.ps1')
if(-not (Get-Variable ApplicationSdStates -Scope Script -ErrorAction SilentlyContinue)){$script:ApplicationSdStates=@{}}
$script:ApplicationSdCodeRoot=$PSScriptRoot

function Initialize-ApplicationSdSupport {
    if(Get-Variable ApplicationSdModule -Scope Script -ErrorAction SilentlyContinue){return}
    $script:ApplicationSdModule=New-Module -Name OptiMiyooSdBroker -ArgumentList $script:ApplicationSdCodeRoot -ScriptBlock {
        param($codeRoot)
        . (Join-Path $codeRoot 'compile_support.ps1')
        . (Join-Path $codeRoot 'core_support.ps1')
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $codeRoot 'prepare_onion.ps1'),[ref]$tokens,[ref]$errors)
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
        $State.Files[$Relative]=[pscustomobject]@{Path=$path;Relative=$Relative;Lease=$lease;Length=$lease.Stream.Length;Hash=$hash;Bytes=$bytes;Config=[bool]$Config;Expected=$null;Changed=$false;Folder='';Core=''}
        $lease=$null
    }finally{if($output){$output.Dispose()};if($lease){$lease.Dispose()}}
}

function Get-ApplicationSdPatch([byte[]]$Original,$Profile,$Support,[string]$OnionRoot) {
    if(-not $Support.CanBuild){return $null}
    $utf8=New-Object Text.UTF8Encoding($false,$true);$raw=$utf8.GetString($Original)
    $config=$raw.TrimStart([char]0xFEFF) | ConvertFrom-Json
    if($config.launch -cne 'launch.sh' -or $config.extlist -isnot [string] -or -not $config.extlist){throw 'SD config does not have a verified launcher and extension list.'}
    $extensions=@($Profile.Playlist.TrimStart('.'))
    if($Profile.Folder -eq 'COMMODORE') {
        $tape=& $script:ApplicationSdModule {param($profile,$root,$support)Get-TapeSwapSupport $profile $root $support} $Profile $OnionRoot $Support
        if($tape.CanBuild){$extensions+=@($tape.Extensions | ForEach-Object {$_.TrimStart('.')})}
    }
    $missing=@($extensions | Where-Object {$_ -notin @($config.extlist -split '\|')})
    if($missing.Count -eq 0){return ,$Original}
    $rx=New-Object regex('("extlist"\s*:\s*")((?:[^"\\]|\\.)*)(")')
    if($rx.Matches($raw).Count -ne 1){throw 'Ambiguous extension list in SD config.'}
    $updated=$rx.Replace($raw,('${1}${2}|'+($missing -join '|')+'${3}'))
    $null=$updated.TrimStart([char]0xFEFF) | ConvertFrom-Json
    return ,$utf8.GetBytes($updated)
}

function New-ApplicationSdSession {
    param([Parameter(Mandatory=$true)][string]$OnionRoot,[Parameter(Mandatory=$true)][string]$WorkRoot)
    Initialize-ApplicationSdSupport
    $original=[IO.Path]::GetFullPath($OnionRoot);$work=[IO.Path]::GetFullPath($WorkRoot)
    $originalPrefix=$original.TrimEnd('\','/')+'\';$workPrefix=$work.TrimEnd('\','/')+'\'
    if($originalPrefix.Equals($workPrefix,[StringComparison]::OrdinalIgnoreCase) -or $originalPrefix.StartsWith($workPrefix,[StringComparison]::OrdinalIgnoreCase) -or $workPrefix.StartsWith($originalPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'SD staging must be separate from the selected SD root.'}
    if(-not [IO.Directory]::Exists($work)){throw 'SD staging must already exist and belong to the application session.'}
    $state=[pscustomobject]@{Handle=$null;OriginalRoot=$original;StagedRoot=(Join-Path $work 'Onion');RootLease=$null;Files=@{};Profiles=@();TotalBytes=0L;Closed=$false;Completed=$false;BackupRoot=$null}
    $workLease=$null
    try {
        $state.RootLease=[OptiMiyoo.OnionPathLease]::Open($original,$original,$true,$false,$false)
        $cores=Join-Path $original 'RetroArch/.retroarch/cores'
        $coresLease=[OptiMiyoo.OnionPathLease]::Open($cores,$original,$true,$false,$false);$coresLease.Dispose()
        $workLease=[OptiMiyoo.OnionPathLease]::Open($work,$work,$true,$false,$false)
        if(Test-Path -LiteralPath $state.StagedRoot){throw 'SD snapshot needs a fresh Onion staging folder.'}
        [void][IO.Directory]::CreateDirectory((Join-Path $state.StagedRoot 'RetroArch/.retroarch/cores'))
        $profileData=Get-Content -LiteralPath (Join-Path $script:ApplicationSdCodeRoot 'systems.json') -Raw | ConvertFrom-Json
        $state.Profiles=@($profileData)
        foreach($profile in $state.Profiles) {
            $folder=$profile.Folder;if($profile.EmuFolder){$folder=$profile.EmuFolder}
            if($folder -notmatch '^[A-Z0-9]+$'){throw 'Invalid installed SD profile.'}
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
        foreach($profile in $state.Profiles) {
            $folder=$profile.Folder;if($profile.EmuFolder){$folder=$profile.EmuFolder}
            $relative='Emu/'+$folder+'/config.json';if(-not $state.Files.ContainsKey($relative)){continue}
            $file=$state.Files[$relative];$file.Folder=$folder
            $support=& $script:ApplicationSdModule {param($profile,$root)Get-PlaylistSupport $profile $root} $profile $original
            $file.Core=$support.Core
            # An unverified profile remains visible in the staged assessment but
            # has no publication authority, even if the child changes its core.
            if($support.CanBuild -and $state.Files.ContainsKey('Emu/'+$folder+'/launch.sh') -and $state.Files.ContainsKey('RetroArch/.retroarch/cores/'+$support.Core)) {
                try{$file.Expected=Get-ApplicationSdPatch $file.Bytes $profile $support $original}
                catch{$file.Expected=$null}
            }
        }
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
    param([Parameter(Mandatory=$true)]$Session)
    $state=Get-ApplicationSdState $Session
    if($state.Completed){throw 'SD setup result has already been consumed.'}
    $state.Completed=$true
    $results=New-Object 'Collections.Generic.List[object]';$stagedLeases=New-Object 'Collections.Generic.List[object]'
    $changed=0;$failed=0;$skipped=0
    try {
        # Freeze and validate the entire selected snapshot before any original
        # write. Extra child files are never imported or executed.
        foreach($file in $state.Files.Values) {
            $target=Join-Path $state.StagedRoot $file.Relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
            $lease=[OptiMiyoo.OnionPathLease]::Open($target,$state.StagedRoot,$false,$false,$false);$stagedLeases.Add($lease)
            if($file.Config) {
                $bytes=Read-ApplicationSdBytes $lease.Stream 1048576
                if([Convert]::ToBase64String($bytes) -ceq [Convert]::ToBase64String($file.Bytes)){continue}
                if($null -eq $file.Expected -or [Convert]::ToBase64String($bytes) -cne [Convert]::ToBase64String($file.Expected)){throw 'SD sandbox proposed an unapproved config change; originals kept.'}
                $file.Changed=$true
            } elseif($lease.Stream.Length -ne $file.Length -or (Get-ApplicationSdHash $lease.Stream) -cne $file.Hash){throw 'SD sandbox changed a launcher or core; originals kept.'}
        }
        foreach($file in @($state.Files.Values | Where-Object {$_.Config} | Sort-Object Relative)) {
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
                $backupLease=[OptiMiyoo.OnionPathLease]::Open((Join-Path $backup 'config.json'),$state.OriginalRoot,$false,$true,$true)
                & $script:ApplicationSdModule {param($stream,$bytes)Write-OnionBytesVerified $stream $bytes 'SD backup'} $backupLease.Stream $file.Bytes
                $writeStarted=$true
                & $script:ApplicationSdModule {param($stream,$bytes)Write-OnionBytesVerified $stream $bytes 'Updated config'} $writeLease.Stream $file.Expected
                $changed++;$results.Add([pscustomobject]@{System=$file.Folder;State='Updated'})
            }catch {
                $failed++
                if($writeStarted -and $writeLease) {
                    try{& $script:ApplicationSdModule {param($stream,$bytes)Write-OnionBytesVerified $stream $bytes 'Restored config'} $writeLease.Stream $file.Bytes;$restored=$true}
                    catch{throw ('SD restoration failed; restore config.json from '+(ConvertTo-SafeExternalText $state.BackupRoot)+' before using this card.')}
                }
                $result='Kept';if($restored){$result='Restored'}
                $results.Add([pscustomobject]@{System=$file.Folder;State=$result})
            }finally{if($backupLease){$backupLease.Dispose()};if($writeLease){$writeLease.Dispose()}}
        }
        return [pscustomobject]@{Changed=$changed;Skipped=$skipped;Failed=$failed;BackupRoot=$state.BackupRoot;Results=$results.ToArray()}
    }finally{foreach($lease in $stagedLeases){$lease.Dispose()}}
}

function Close-ApplicationSdSession {
    param([Parameter(Mandatory=$true)]$Session)
    $state=Get-ApplicationSdState $Session;$state.Closed=$true
    try{foreach($file in $state.Files.Values){if($file.Lease){$file.Lease.Dispose();$file.Lease=$null}}}
    finally{if($state.RootLease){$state.RootLease.Dispose();$state.RootLease=$null};$script:ApplicationSdStates.Remove($Session.Id)}
}

function Read-ApplicationSdConsolePath {
    if($Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected){throw 'SD selection requires the parent console.'}
    $title='Onion SD setup';$prompt='SD card root (for example E:\)';$rows=@('Choose the SD card root folder.','Setup adds supported file-list extensions.','Selected emulator cores stay unchanged.','Escape cancels.');$text='';$dirty=$true;$clock=[Diagnostics.Stopwatch]::StartNew()
    $sparseIdle=(-not $NoAnimation -and $script:UiVT -and -not $script:UiLive)
    $idleWatch=$null;$script:UiIdlePoseOverride=$null
    Reset-MioSparseCrt
    if($sparseIdle){Reset-MioIdleInput;$idleWatch=[Diagnostics.Stopwatch]::StartNew()}
    if(-not $script:UiVT){[Console]::WriteLine($title);foreach($line in $rows){[Console]::WriteLine($line)};[Console]::Write($prompt+': ')}
    Update-InputCaret '' 0 -Reset
    try {while($true) {
        if(Update-DisplaySize -Throttled){$dirty=$true}
        $bunnyVisible=($script:UiPanel -and $script:UiHeight -ge ([Math]::Max(12,$rows.Count)+7))
        if($sparseIdle) {
            $pose=Get-MioIdlePose $idleWatch.Elapsed.TotalMilliseconds ($text.Length -gt 0 -or -not $bunnyVisible)
            if($pose -cne $script:UiIdlePoseOverride){$script:UiIdlePoseOverride=$pose;$dirty=$true}
        }
        if(Update-MioSparseCrt $script:UiEffectClock.Elapsed.TotalMilliseconds ($text.Length -gt 0) $bunnyVisible){$dirty=$true}
        if($script:UiVT -and ($dirty -or ((Get-InputCaretVisible) -ne $script:UiCaretDrawn) -or ($script:UiLive -and $clock.ElapsedMilliseconds -ge 33))){Draw-MenuPanel $title $rows $prompt $text $text.Length 'wait';$clock.Restart();$dirty=$false}
        if([Console]::KeyAvailable) {
            $key=[Console]::ReadKey($true)
            if($sparseIdle){$idleWatch.Restart();Reset-MioIdleInput;$script:UiIdlePoseOverride='idle';$dirty=$true}
            if($key.Key -eq [ConsoleKey]::Escape){return $null}
            if($script:UiVT -and (-not $script:UiPanel -or $script:UiHeight -lt 19)){continue}
            if($key.Key -eq [ConsoleKey]::Enter){if(-not $script:UiVT){[Console]::WriteLine()};return $text.Trim().Trim('"')}
            if($key.Key -eq [ConsoleKey]::Backspace -and $text.Length){$text=$text.Substring(0,$text.Length-1)}
            elseif(-not [char]::IsControl($key.KeyChar) -and $key.KeyChar -notmatch '[\u202a-\u202e\u2066-\u2069]' -and $text.Length -lt 32767){$text+=[string]$key.KeyChar}
            Update-InputCaret $text $text.Length;$dirty=$true
            if(-not $script:UiVT){[Console]::Write("`r"+$prompt+': '+$text+' ')}
        }else{if($script:UiLive){Wait-DisplayFrame 8}else{Wait-DisplayFrame 30}}
    }} finally {$script:UiIdlePoseOverride=$null;Reset-MioSparseCrt;if($idleWatch){$idleWatch.Stop()}}
}

function Invoke-ApplicationSdFolderPrompt {
    param([Parameter(Mandatory=$true)]$Session,[switch]$NoAnimation,[switch]$NoColor,
          [ValidateSet('CRT','Smooth')][string]$DisplayEffect='CRT')
    $paused=$false;$display=$false;$selected=$null;$previousEffect=$script:DisplayEffect
    try {
        [void]$Session.PauseRelay();if(-not $Session.IsRelayPaused){throw 'The application relay did not surrender the parent console.'};$paused=$true
        $script:DisplayEffect=$DisplayEffect
        Initialize-Display;$display=$true;$selected=Read-ApplicationSdConsolePath
        if($null -ne $selected) {
            if([string]::IsNullOrWhiteSpace($selected) -or -not [IO.Path]::IsPathRooted($selected) -or $selected.StartsWith('\\?\') -or $selected.StartsWith('\\.\')){throw 'Choose an absolute SD card folder.'}
            $selected=[IO.Path]::GetFullPath($selected)
        }
    }finally {
        try{if($display){Restore-Display}}
        finally{$script:DisplayEffect=$previousEffect;if($paused){if($Session.HasExited){throw 'The isolated application exited during SD selection.'};[void]$Session.ResumeRelay()}}
    }
    return $selected
}
