# Sparse menu gestures: a finite pose sequence, then twelve seconds between
# gesture starts. It reports actual starts to synchronized CRT; display.ps1
# controls the artwork and rendering cadence.
$script:MioIdleSchedulerState=$null

function Initialize-MioIdleScheduler {
    $script:MioIdleSchedulerState=[pscustomobject]@{
        Catalog=@(); Bag=[int[]]@(); BagIndex=0; LastId=$null
        Active=$null; StartMs=0.0; EndMs=0.0; NextStartMs=12000.0
        LastElapsedMs=0.0; HadText=$false; GestureSerial=0L; InputSerial=0L
    }
}

function Reset-MioIdleInput {
    if ($null -eq $script:MioIdleSchedulerState) {Initialize-MioIdleScheduler; return}
    # The caller restarts its inactivity stopwatch on every key. Keep the bag
    # so navigating menus does not repeatedly show only the first few gestures.
    $state=$script:MioIdleSchedulerState
    $state.InputSerial++
    $state.Active=$null; $state.StartMs=0.0; $state.EndMs=0.0; $state.NextStartMs=12000.0
    $state.LastElapsedMs=0.0; $state.HadText=$false
}

function Get-MioIdleGesturePose([object]$Gesture,[double]$ElapsedMs) {
    if ($null -eq $Gesture -or $ElapsedMs -lt 0 -or
        [double]::IsNaN($ElapsedMs) -or [double]::IsInfinity($ElapsedMs)) {return 'idle'}
    $end=0.0
    foreach ($frame in $Gesture.Frames) {
        $end+=[double]$frame.DurationMs
        if ($ElapsedMs -lt $end) {return [string]$frame.Pose}
    }
    return 'idle'
}

function Get-MioIdlePose([double]$ElapsedMs,[bool]$HasText=$false) {
    if ($null -eq $script:MioIdleSchedulerState) {Initialize-MioIdleScheduler}
    $state=$script:MioIdleSchedulerState
    if ([double]::IsNaN($ElapsedMs) -or [double]::IsInfinity($ElapsedMs)) {
        Reset-MioIdleInput
        return 'idle'
    }
    $ElapsedMs=[Math]::Max(0.0,$ElapsedMs)
    if ($ElapsedMs -lt $state.LastElapsedMs) {
        # A replaced/restarted stopwatch must not inherit an overdue deadline.
        Reset-MioIdleInput
        $state.NextStartMs=$ElapsedMs+12000.0
    }
    $state.LastElapsedMs=$ElapsedMs
    if ($HasText) {
        $state.Active=$null; $state.HadText=$true
        $state.NextStartMs=$ElapsedMs+12000.0
        return 'idle'
    }
    if ($state.HadText) {
        $state.HadText=$false; $state.NextStartMs=$ElapsedMs+12000.0
        return 'idle'
    }
    if ($null -ne $state.Active) {
        # Internal idle frames (for example, a double blink) still belong to
        # the gesture. After its final frame, polls take the cheap resting path.
        if ($ElapsedMs -lt $state.EndMs) {
            return (Get-MioIdleGesturePose $state.Active ($ElapsedMs-$state.StartMs))
        }
        $state.Active=$null
    }
    if ($ElapsedMs -lt $state.NextStartMs) {return 'idle'}

    if ($state.BagIndex -ge $state.Bag.Count) {
        # The sprite library is initialized by the renderer. Read its cached
        # catalog only when filling the bag, never during the input polling loop.
        $catalog=Get-Variable -Name MioIdleGestures -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        $state.Catalog=@()
        if ($null -ne $catalog) {$state.Catalog=@($catalog)}
        $count=$state.Catalog.Count
        if ($count -eq 0) {$state.NextStartMs=$ElapsedMs+12000.0; return 'idle'}
        $bag=New-Object 'int[]' $count
        for ($i=0; $i -lt $count; $i++) {$bag[$i]=$i}
        for ($i=$count-1; $i -gt 0; $i--) {
            $j=Get-Random -Minimum 0 -Maximum ($i+1)
            $swap=$bag[$i]; $bag[$i]=$bag[$j]; $bag[$j]=$swap
        }
        if ($count -gt 1 -and $state.Catalog[$bag[0]].Id -eq $state.LastId) {
            $swap=$bag[0]; $bag[0]=$bag[1]; $bag[1]=$swap
        }
        $state.Bag=$bag; $state.BagIndex=0
    }
    $state.Active=$state.Catalog[$state.Bag[$state.BagIndex]]
    $state.GestureSerial++
    $state.BagIndex++
    $state.LastId=[string]$state.Active.Id
    # Schedule from now: a delayed poll never queues missed gestures or replays
    # frames in a burst after sleep, resizing or a busy foreground operation.
    $state.StartMs=$ElapsedMs; $state.NextStartMs=$ElapsedMs+12000.0
    $state.EndMs=$ElapsedMs
    foreach ($frame in $state.Active.Frames) {$state.EndMs+=[double]$frame.DurationMs}
    return (Get-MioIdleGesturePose $state.Active 0.0)
}
