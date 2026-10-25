. (Join-Path $PSScriptRoot 'compile_support.ps1')
# OptiMiyoo's display is deliberately separate from file processing.
. (Join-Path $PSScriptRoot 'terminal_effects.ps1')
. (Join-Path $PSScriptRoot 'output_safety.ps1')
. (Join-Path $PSScriptRoot 'mio_idle_library.ps1')
. (Join-Path $PSScriptRoot 'mio_idle_scheduler.ps1')
# Percentages use completed preparation items, completed jobs or measured bytes.
function Initialize-Display {
    if ($script:UiFrameTimer) {try {$script:UiFrameTimer.Dispose()} catch {}}
    $script:UiFrameTimer=$null
    $script:UiOldRendering=$null
    $script:Esc=[string][char]27
    $script:UiRows=0; $script:UiTick=0; $script:UiLastStage=''
    $script:UiMioWatch=[Diagnostics.Stopwatch]::StartNew()
    $script:UiCaretWatch=[Diagnostics.Stopwatch]::StartNew()
    $script:UiCaretText=$null; $script:UiCaretIndex=-1; $script:UiCaretDrawn=$null
    $script:UiMioMood=$null; $script:UiMioPoseOverride=$null
    $script:UiIdlePoseOverride=$null
    $script:UiIdleMenuCache=$null
    $script:MioSparseCrtMode='Synchronized'
    $script:MioSparseCrtContinuousFps=12.0
    $script:MioSparseCrtContinuousCycleMs=6000.0
    $script:MioSparseCrtLogoFrameCount=10
    $script:MioSparseCrtBunnyFrameCount=24
    $script:MioSparseCrtBunnyDelayMs=6000.0
    $script:MioSparseCrtGeometry=$null
    $script:MioSparseCrtGeometryKey=''
    $script:MioContinuousCrtLevels=@{}
    $script:OptiLogoMotionCache=@{}
    $script:OptiLogoMotionOrder=[System.Collections.Generic.Queue[string]]::new()
    $script:OptiLogoRowCache=@{}
    $script:OptiLogoRowOrder=[System.Collections.Generic.Queue[string]]::new()
    $script:UiLastLogoRows=@()
    $script:MioSparseCrtIntervalMs=12000.0
    $script:MioSparseCrtBurstMs=1000.0
    $script:MioSparseCrtFrameCount=12
    Reset-MioSparseCrt
    Initialize-MioIdleScheduler
    $script:MioRenderCache=@{}
    $script:MioCrtRowCache=@{}
    $script:MioCrtRowOrder=[System.Collections.Generic.Queue[string]]::new()
    $script:MioSparseCrtFrames=@{}
    $script:MioSparseCrtFrameOrder=[System.Collections.Generic.Queue[string]]::new()
    $script:OptiLogoFont=$null; $script:OptiLogoCache=@{}
    $script:UiPendingEvents=[System.Collections.Generic.List[string]]::new()
    $script:UiEventRows=[System.Collections.Generic.List[string]]::new()
    $script:UiBannerRows=0; $script:UiBannerTimeMs=0; $script:UiPinned=$false
    $script:UiGame='Awaiting a disk set'; $script:UiSystem='LOCAL'
    $script:UiStage='Ready'; $script:UiDetail='Source files remain in SRC.'
    $script:UiPercent=-1; $script:UiMood='idle'
    $script:UiPreparing=$false; $script:UiPreparationCompleted=0; $script:UiPreparationTotal=-1
    $script:UiPreparationUnit='files'; $script:UiPreparationWatch=[Diagnostics.Stopwatch]::StartNew()
    $script:UiSay='Awaiting system selection.'
    $script:UiInteractive=$false; $script:UiAnsi=$false; $script:UiVT=$false
    $script:UiPanel=$false; $script:UiMenuActive=$false; $script:UiMenuLines=$null
    $script:UiDemo=$false; $script:UiDemoPaused=$false; $script:UiPoseOverride=$null
    $script:UiDemoProgressTick=4; $script:UiDemoProgressStatus=''
    if ($script:DisplayEffect -notin 'CRT','Smooth') {$script:DisplayEffect='CRT'}
    $script:UiEffectClock=[Diagnostics.Stopwatch]::StartNew(); $script:UiCrtTimeMs=0
    $script:UiWatch=[Diagnostics.Stopwatch]::StartNew()
    $script:UiSizeWatch=[Diagnostics.Stopwatch]::StartNew()
    $script:Pride=@('255;115;154','255;181;115','255;225;132','144;225;173','110;202;255','194;160;255')
    $script:Trans=@('107;216;245','249;172;204','245;244;255','249;172;204','107;216;245')
    $script:UiWidth=78; $script:UiColumns=0; $script:UiHeight=0
    try {
        [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
        $script:UiInteractive=($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected)
        if ($script:UiInteractive) {
            $script:UiWidth=[Math]::Min(92,[Math]::Max(50,[Console]::WindowWidth-4))
            $script:UiOldCursor=$true
            try {$script:UiOldCursor=[Console]::CursorVisible} catch {}
            $script:UiOldForeground=$Host.UI.RawUI.ForegroundColor
            $script:UiOldBackground=$Host.UI.RawUI.BackgroundColor
            $Host.UI.RawUI.BackgroundColor='Black'
            $Host.UI.RawUI.ForegroundColor='White'
            try {$Host.UI.RawUI.WindowTitle='OptiMiyoo v'+$script:AppVersion+' // DISK LINK'} catch {}
            if ($script:UiInteractive) {
                if ($env:OS -eq 'Windows_NT') {
                    if (-not ('OptiMiyoo.Terminal' -as [type])) {
                        Add-OptiMiyooType -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace OptiMiyoo {
    public static class Terminal {
        [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
        [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint m);
        [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint m);
        public static bool Enable() {
            var h=GetStdHandle(-11); uint m;
            return GetConsoleMode(h,out m) && SetConsoleMode(h,m|4);
        }
    }
}
'@
                    }
                    $script:UiVT=[OptiMiyoo.Terminal]::Enable()
                } else {$script:UiVT=($env:TERM -ne 'dumb')}
            }
        }
    } catch {$script:UiVT=$false}
    $script:UiAnsi=($script:UiVT -and -not $NoColor)
    if ($script:UiVT) {
        $script:UiColumns=[Console]::WindowWidth; $script:UiHeight=[Console]::WindowHeight
    }
    $script:UiPanel=($script:UiVT -and $script:UiWidth -ge 72 -and $script:UiHeight -ge 19)
    $script:UiLive=($script:UiPanel -and -not $NoAnimation)
    Sync-TerminalDisplayEffect
    if ($script:UiVT) {Initialize-FrameTimer}
    if ($script:UiAnsi -and (Get-Variable PSStyle -ErrorAction SilentlyContinue)) {
        $script:UiOldRendering=$PSStyle.OutputRendering
        $PSStyle.OutputRendering='Ansi'
    }
}

function Initialize-FrameTimer {
    if ($env:OS -ne 'Windows_NT' -or $script:UiFrameTimer) {return}
    try {
        if (-not ('OptiMiyoo.FrameTimerV1' -as [type])) {
            Add-OptiMiyooType -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace OptiMiyoo {
    public sealed class FrameTimerV1 : IDisposable {
        [DllImport("kernel32.dll", EntryPoint="CreateWaitableTimerExW", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeWaitHandle CreateWaitableTimerEx(IntPtr attributes, string name, uint flags, uint access);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool SetWaitableTimer(SafeWaitHandle timer, ref long due, int period, IntPtr callback, IntPtr state, bool resume);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern uint WaitForSingleObject(SafeWaitHandle handle, uint timeout);
        SafeWaitHandle handle;
        public FrameTimerV1() {
            // A private high-resolution timer does not alter system-wide timer resolution.
            // Older Windows versions return an invalid handle and use the managed fallback.
            try { handle=CreateWaitableTimerEx(IntPtr.Zero, null, 2, 0x00100002); }
            catch (EntryPointNotFoundException) {}
            catch (DllNotFoundException) {}
        }
        public bool HighResolution {
            get { return handle!=null && !handle.IsInvalid && !handle.IsClosed; }
        }
        public bool Wait(int milliseconds) {
            if (milliseconds<=0 || !HighResolution) return false;
            long due=-(long)milliseconds*10000;
            return SetWaitableTimer(handle, ref due, 0, IntPtr.Zero, IntPtr.Zero, false)
                && WaitForSingleObject(handle, 0xffffffff)==0;
        }
        public void Dispose() {
            if (handle!=null) { handle.Dispose(); handle=null; }
        }
    }
}
'@
        }
        $script:UiFrameTimer=New-Object OptiMiyoo.FrameTimerV1
    } catch {$script:UiFrameTimer=$null}
}
function Wait-DisplayFrame([int]$Milliseconds) {
    # Rendering already consumed this frame's budget: proceed to useful work,
    # rather than adding a mandatory sleep to every slow frame.
    if ($Milliseconds -le 0) {return}
    if ($script:UiFrameTimer) {
        try {if ($script:UiFrameTimer.Wait($Milliseconds)) {return}} catch {}
    }
    Start-Sleep -Milliseconds $Milliseconds
}

function Update-DisplaySize([switch]$Throttled) {
    if (-not $script:UiVT) {return $false}
    if ($Throttled -and $script:UiSizeWatch -and $script:UiSizeWatch.ElapsedMilliseconds -lt 100) {return $false}
    if ($script:UiSizeWatch) {$script:UiSizeWatch.Restart()}
    try {$columns=[Console]::WindowWidth; $height=[Console]::WindowHeight} catch {return $false}
    if ($columns -eq $script:UiColumns -and $height -eq $script:UiHeight) {return $false}
    # A terminal may reflow old rows on resize. Their previous cursor offsets
    # are no longer valid: reset the visible panel once, then redraw at its new size.
    if ($script:UiPinned) {
        [Console]::Write($script:Esc+'[?25l'+$script:Esc+'[r'+$script:Esc+'[2J'+$script:Esc+'[H')
        $script:UiRows=0; $script:UiBannerRows=0; $script:UiPinned=$false
    }
    $script:UiColumns=$columns; $script:UiHeight=$height
    $script:MioSparseCrtGeometry=$null; $script:MioSparseCrtGeometryKey=''
    $script:UiWidth=[Math]::Min(92,[Math]::Max(50,$columns-4))
    $script:UiPanel=($script:UiWidth -ge 72 -and $height -ge 19)
    $script:UiLive=($script:UiPanel -and -not $NoAnimation)
    return $true
}

function Color-Text([string]$Text,[string]$Rgb='218;224;244') {
    if ($script:UiAnsi) {return ($script:Esc+'[38;2;'+$Rgb+'m'+$Text+$script:Esc+'[0m')}
    return $Text
}
function Sync-TerminalDisplayEffect {
    $script:UiFullScreenCrt=$false
    if (-not $script:UiInteractive -or -not $script:UiVT) {return}
    $mode='Smooth'
    if ($script:DisplayEffect -eq 'CRT' -and -not $NoAnimation -and -not $NoColor) {
        $mode='CRT'
        if ($script:UiDemoPaused) {$mode='Paused'}
    }
    $script:UiFullScreenCrt=Set-OptiTerminalCrtMode $mode
}
function Switch-DisplayEffect {
    if ($script:DisplayEffect -eq 'CRT') {$script:DisplayEffect='Smooth'}
    else {$script:DisplayEffect='CRT'}
    Sync-TerminalDisplayEffect
}
function Rainbow-Text([string]$Text,[bool]$Soft=$false,[int]$Shift=0) {
    if (-not $script:UiAnsi) {return $Text}
    $palette=$script:Pride; if ($Soft) {$palette=$script:Trans}
    $palette=@(Get-AnimatedPalette $palette)
    $out=[Text.StringBuilder]::new()
    $prefix=$script:Esc+'[38;2;'; $reset=$script:Esc+'[0m'
    for ($i=0;$i -lt $Text.Length;$i++) {
        $rgb=$palette[([int][Math]::Floor($i/4)+$Shift)%$palette.Count]
        [void]$out.Append($prefix+$rgb+'m'+$Text[$i]+$reset)
    }
    return $out.ToString()
}
function Get-BorderCellIndex([int]$X,[int]$Y,[int]$Width,[int]$Height) {
    # Clockwise, with each corner counted once: top, right, bottom, left.
    if ($Height -eq 1 -or $Y -eq 0) {return $X}
    if ($X -eq $Width-1) {return ($Width-1+$Y)}
    if ($Y -eq $Height-1) {return (2*($Width-1)+$Height-1-$X)}
    return (2*($Width-1)+2*($Height-1)-$Y)
}
function Get-BorderMotion([int]$Width,[int]$Height) {
    $pride=@(Get-AnimatedPalette $script:Pride)
    $trans=@(Get-AnimatedPalette $script:Trans)
    $length=2*($Width-1)+2*($Height-1)
    if ($Height -eq 1) {$length=$Width}
    return [pscustomobject]@{Width=$Width;Height=$Height;Length=$length;
        Head=($script:UiBannerTimeMs%8100)/8100.0*$length;
        Animated=$script:UiLive;Pride=$pride;Trans=$trans}
}
function Format-BorderText([string]$Text,[int]$X,[int]$Y,$Motion,[bool]$Soft=$false) {
    if (-not $script:UiAnsi) {return $Text}
    $palette=$Motion.Pride; if ($Soft) {$palette=$Motion.Trans}
    $position=Get-BorderCellIndex $X $Y $Motion.Width $Motion.Height
    $direction=1; if ($Motion.Height -gt 1 -and $Y -eq $Motion.Height-1) {$direction=-1}
    $out=[Text.StringBuilder]::new()
    $prefix=$script:Esc+'[38;2;'; $reset=$script:Esc+'[0m'
    for ($i=0;$i -lt $Text.Length;$i++) {
        $at=$position+$i*$direction
        $rgb=$palette[([int][Math]::Floor($at/4))%$palette.Count]
        if ($Motion.Animated) {
            # Four white cells lead a long bright trail. Preserve the rainbow
            # at full brightness wherever the moving light is not passing.
            $behind=($Motion.Head-$at+$Motion.Length)%$Motion.Length
            $light=0.0
            if ($behind -lt 4) {$light=1.0}
            elseif ($behind -lt 22) {$light=(22-$behind)/18.0}
            if ($light -eq 1) {$rgb='255;255;255'}
            elseif ($light -gt 0) {
                $channels=$rgb.Split(';')
                $r=[int][Math]::Round([int]$channels[0]*(1-$light)+255*$light)
                $g=[int][Math]::Round([int]$channels[1]*(1-$light)+255*$light)
                $b=[int][Math]::Round([int]$channels[2]*(1-$light)+255*$light)
                $rgb=('{0};{1};{2}' -f $r,$g,$b)
            }
        }
        [void]$out.Append($prefix+$rgb+'m'+$Text[$i]+$reset)
    }
    return $out.ToString()
}
function Format-HighlightStripe([string]$Text,[bool]$Soft=$false) {
    if (-not $script:UiAnsi) {return $Text}
    return (Format-BorderText $Text 0 0 (Get-BorderMotion $Text.Length 1) $Soft)
}

function Get-TextElementWidth([string]$Element) {
    if ([char]::IsSurrogate($Element[0]) -and
        ($Element.Length -lt 2 -or -not [char]::IsSurrogatePair($Element,0))) {return 1}
    $code=[char]::ConvertToUtf32($Element,0)
    $category=[Globalization.CharUnicodeInfo]::GetUnicodeCategory($Element,0)
    if ($category -in 'NonSpacingMark','EnclosingMark','Format') {return 0}
    # Wide CJK/fullwidth characters and emoji need two console cells. Treat
    # supplementary symbols conservatively; never split surrogate pairs.
    if ($code -ge 0x10000 -or $Element.Contains([string][char]0xFE0F) -or
        ($code -ge 0x1100 -and $code -le 0x115F) -or
        ($code -ge 0x2329 -and $code -le 0x232A) -or
        ($code -ge 0x2600 -and $code -le 0x27BF) -or
        ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
        ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
        ($code -ge 0xF900 -and $code -le 0xFAFF) -or
        ($code -ge 0xFE10 -and $code -le 0xFE6F) -or
        ($code -ge 0xFF00 -and $code -le 0xFF60) -or
        ($code -ge 0xFFE0 -and $code -le 0xFFE6)) {return 2}
    return 1
}
function Get-TextWidth([string]$Text) {
    if ($Text -notmatch '[^\x00-\x7F]') {return $Text.Length}
    $width=0; $elements=[Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($elements.MoveNext()) {$width+=Get-TextElementWidth $elements.GetTextElement()}
    return $width
}
function Get-TextPrefix([string]$Text,[int]$Width) {
    if ($Text -notmatch '[^\x00-\x7F]') {return $Text.Substring(0,[Math]::Max(0,[Math]::Min($Width,$Text.Length)))}
    $used=0; $length=0; $elements=[Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($elements.MoveNext()) {
        $element=$elements.GetTextElement(); $cells=Get-TextElementWidth $element
        if ($used+$cells -gt $Width) {break}
        $used+=$cells; $length+=$element.Length
    }
    return $Text.Substring(0,$length)
}
function Fit-Text([string]$Text,[int]$Width) {
    $Text=$Text -replace '[\x00-\x1f\x7f-\x9f]',' '
    # Menu labels and padding are mostly ASCII. Keep grapheme-aware handling
    # for Unicode paths without enumerating every ordinary cell every frame.
    if ($Text -notmatch '[^\x00-\x7F]') {
        if ($Text.Length -gt $Width) {
            if ($Width -le 3) {return ('.'*$Width)}
            return ($Text.Substring(0,$Width-3)+'...')
        }
        return $Text.PadRight($Width)
    }
    if ((Get-TextWidth $Text) -gt $Width) {
        if ($Width -le 3) {return ('.'*$Width)}
        $Text=(Get-TextPrefix $Text ($Width-3))+'...'
    }
    return $Text+(' '*[Math]::Max(0,$Width-(Get-TextWidth $Text)))
}
function Get-InputViewport([string]$Text,[int]$Caret,[int]$Width) {
    $offset=[Math]::Max(0,$Caret-$Width+1)
    if ($offset -lt $Caret -and [char]::IsLowSurrogate($Text[$offset])) {$offset++}
    while ((Get-TextWidth $Text.Substring($offset,$Caret-$offset)) -ge $Width) {
        $element=[Globalization.StringInfo]::GetNextTextElement($Text,$offset)
        $offset+=$element.Length
        if ($offset -ge $Caret) {$offset=$Caret; break}
    }
    return [pscustomobject]@{
        Text=Get-TextPrefix $Text.Substring($offset) $Width
        Caret=Get-TextWidth $Text.Substring($offset,$Caret-$offset)
        CaretTextIndex=$Caret-$offset
    }
}
function Update-InputCaret([string]$Text,[int]$Caret,[switch]$Reset) {
    if ($Reset -or $script:UiCaretText -cne $Text -or $script:UiCaretIndex -ne $Caret) {
        $script:UiCaretWatch.Restart()
        $script:UiCaretText=$Text; $script:UiCaretIndex=$Caret
    }
}
function Get-InputCaretVisible {
    if (-not $script:UiLive) {return $true}
    return (([Math]::Floor($script:UiCaretWatch.ElapsedMilliseconds/500.0)%2) -eq 0)
}
function Format-InputField($Viewport,[int]$Width,[bool]$ShowCaret=$true) {
    $text=Fit-Text $Viewport.Text $Width
    $visible=($ShowCaret -and $script:UiVT -and (Get-InputCaretVisible))
    $script:UiCaretDrawn=$visible
    if (-not $visible -or $text.Length -eq 0) {return $text}
    # Decorate one complete grapheme, or its padded end-space. UTF-16 caret
    # offsets can fall inside a surrogate pair; never split it with escapes.
    $index=[Math]::Max(0,[Math]::Min($text.Length-1,$Viewport.CaretTextIndex))
    if ($text -notmatch '[^\x00-\x7F]') {
        return ($text.Substring(0,$index)+$script:Esc+'[7m'+$text[$index]+$script:Esc+'[27m'+$text.Substring($index+1))
    }
    $elements=[Globalization.StringInfo]::GetTextElementEnumerator($text)
    while ($elements.MoveNext()) {
        $start=$elements.ElementIndex; $element=$elements.GetTextElement()
        if ($index -lt $start+$element.Length) {
            return ($text.Substring(0,$start)+$script:Esc+'[7m'+$element+$script:Esc+'[27m'+$text.Substring($start+$element.Length))
        }
    }
    return $text
}
function Clear-DisplayPanel {
    $script:UiIdleMenuCache=$null
    [void](Update-DisplaySize)
    if ($script:UiRows -gt 0) {
        # Plain questions use the area below the pinned banner. Their output
        # can scroll there without moving the logo out of the viewport.
        [Console]::Write($script:Esc+'[?25l'+$script:Esc+'['+($script:UiBannerRows+1)+';1H'+$script:Esc+'[J')
        $script:UiRows=0
    }
    if ($script:UiPendingEvents -and $script:UiPendingEvents.Count -gt 0) {
        [Console]::Write(($script:UiPendingEvents.ToArray() -join "`r`n")+"`r`n")
        $script:UiPendingEvents.Clear()
    }
}
function Suspend-DisplayPanel {
    # Plain prompts own the terminal until input is complete. Only suspend
    # for an actual question, never for automatic overwrite/skip decisions.
    Clear-DisplayPanel
    if ($script:UiInteractive) {try {[Console]::CursorVisible=$true} catch {}}
}
function Restore-Display {
    if ($script:UiFrameTimer) {try {$script:UiFrameTimer.Dispose()} catch {}}
    $script:UiFrameTimer=$null
    Complete-PreparationProgress
    Clear-DisplayPanel
    if ($script:UiPinned) {
        # Reset margins without moving the caller's cursor onto the banner.
        [Console]::Write($script:Esc+'7'+$script:Esc+'[r'+$script:Esc+'8')
        $script:UiPinned=$false; $script:UiBannerRows=0
    }
    if ($script:UiInteractive) {
        try {[Console]::CursorVisible=$script:UiOldCursor} catch {}
        try {$Host.UI.RawUI.BackgroundColor=$script:UiOldBackground; $Host.UI.RawUI.ForegroundColor=$script:UiOldForeground} catch {}
    }
    if ($script:UiAnsi) {[Console]::Write($script:Esc+'[0m')}
    if ($null -ne $script:UiOldRendering) {$PSStyle.OutputRendering=$script:UiOldRendering}
    $script:UiInteractive=$false; $script:UiAnsi=$false; $script:UiVT=$false
    $script:UiLive=$false; $script:UiPanel=$false; $script:UiOldRendering=$null
}
function Write-RetroStripe {
    Clear-DisplayPanel
    Write-Host ('  '+(Rainbow-Text ('='*$script:UiWidth)))
}
function Write-Event([string]$Label,[string]$Message) {
    Write-Log ($Label+': '+$Message)
    # The fixed panel owns routine per-file progress. Keep the area above it
    # for notices and retain every detailed event in the log (and plain output).
    if ($script:UiVT -and $Label -notin 'ERROR','FAILED','WARN','WARNING','UNSUPPORTED','CORE','MODE','SOURCE','OUTPUT','FOUND','QUEUE','NOTE','TAPES','DONE','EMPTY') {return}
    Write-Notice $Label $Message
}
function Write-Notice([string]$Label,[string]$Message) {
    $Label=ConvertTo-SafeExternalText $Label
    $Message=ConvertTo-SafeExternalText $Message
    # Rendering is separate from logging so a failed log can safely report
    # its own warning without recursion or writing through an active panel.
    $rgb='107;216;245'
    if ($Label -in 'ERROR','FAILED') {$rgb='255;153;205'}
    elseif ($Label -in 'SKIP','NOTE','CHECK','WARN','WARNING') {$rgb='255;221;144'}
    elseif ($Label -in 'READY','DONE','ORDER') {$rgb='194;174;255'}
    if ($script:UiVT -and $script:UiRows -gt 0 -and -not $script:UiDemo) {
        # Logging must not erase the live panel. Queue complete, explicitly
        # wrapped rows; the next frame appends them above the bunny in one write.
        $rows=@(Get-MenuRows @(('[{0,-7}] {1}' -f $Label,$Message)) ([Math]::Max(16,$script:UiColumns-4)))
        for ($i=0;$i -lt $rows.Count;$i++) {
            $row=$rows[$i]
            if ($i -eq 0) {$row=(Color-Text $row.Substring(0,9) $rgb)+$row.Substring(9)}
            $script:UiPendingEvents.Add('  '+$row)
        }
        Draw-DisplayPanel
    } else {
        Clear-DisplayPanel
        Write-Host ('  '+(Color-Text ('[{0,-7}]' -f $Label) $rgb)+' '+$Message)
    }
}
function Reset-MioSparseCrt([switch]$KeepIntro) {
    $script:UiSparseCrtPhase=-1
    $script:UiSparseCrtRegion=''
    $script:UiSparseCrtPositionMs=0.0
    $script:UiSparseCrtLastTimeMs=-1.0
    $script:MioSynchronizedCrtState=$null
    if (-not $KeepIntro) {
        $script:UiSparseCrtIntroPending=$true
        $script:MioSparseCrtGeometry=$null; $script:MioSparseCrtGeometryKey=''
    }
}
function Update-MioSparseCrt([double]$ElapsedMs,[bool]$HasText=$false,[bool]$VisibleBunny=$true) {
    $eligible=($IdleAnimations -and -not $NoColor -and $script:UiAnsi -and
        $script:UiVT -and $script:UiPanel -and $VisibleBunny -and -not $script:UiLive -and
        -not $script:UiDemo -and $script:DisplayEffect -eq 'CRT')
    if (-not $eligible -or $ElapsedMs -lt 0 -or [double]::IsNaN($ElapsedMs) -or [double]::IsInfinity($ElapsedMs)) {
        $changed=($script:UiSparseCrtPhase -ge 0)
        Reset-MioSparseCrt -KeepIntro
        return $changed
    }
    $delta=0.0
    if ($script:UiSparseCrtLastTimeMs -ge 0 -and $ElapsedMs -ge $script:UiSparseCrtLastTimeMs) {
        $delta=$ElapsedMs-$script:UiSparseCrtLastTimeMs
    }
    $reversed=($script:UiSparseCrtLastTimeMs -ge 0 -and $ElapsedMs -lt $script:UiSparseCrtLastTimeMs)
    $script:UiSparseCrtLastTimeMs=$ElapsedMs
    if ($script:MioSparseCrtMode -eq 'Synchronized') {
        return (Update-MioSynchronizedCrt $ElapsedMs ($HasText -or $script:UiDemoPaused -or $reversed))
    }
    # Freeze the current band while typing. Updating the clock baseline avoids
    # jumping or replaying missed frames when input or a pause ends.
    if ($HasText -or $script:UiDemoPaused) {return $false}
    # Both modes sample only the present position after a stall, without
    # queuing missed frames. Burst remains available for low-duty-cycle use.
    if ($script:MioSparseCrtMode -eq 'Continuous') {
        $script:UiSparseCrtPositionMs=($script:UiSparseCrtPositionMs+$delta)%$script:MioSparseCrtContinuousCycleMs
        $phase=[int][Math]::Floor($script:UiSparseCrtPositionMs*$script:MioSparseCrtContinuousFps/1000.0)
    } else {
        $script:UiSparseCrtPositionMs=($script:UiSparseCrtPositionMs+$delta)%$script:MioSparseCrtIntervalMs
        $phase=-1
        if ($script:UiSparseCrtPositionMs -lt $script:MioSparseCrtBurstMs) {
            $step=[int][Math]::Floor($script:UiSparseCrtPositionMs*$script:MioSparseCrtFrameCount/$script:MioSparseCrtBurstMs)
            $phase=[int][Math]::Floor($step*48.0/$script:MioSparseCrtFrameCount)
        }
    }
    if ($phase -eq $script:UiSparseCrtPhase) {return $false}
    $script:UiSparseCrtPhase=$phase
    return $true
}
function Update-MioSynchronizedCrt([double]$ElapsedMs,[bool]$Cancel) {
    $idle=$script:MioIdleSchedulerState
    if (-not $script:MioSynchronizedCrtState) {
        $script:MioSynchronizedCrtState=@{GestureSerial=$idle.GestureSerial;InputSerial=$idle.InputSerial;Region='';StartMs=0.0;BunnyDueMs=-1.0}
    }
    $state=$script:MioSynchronizedCrtState
    $oldPhase=$script:UiSparseCrtPhase; $oldRegion=$script:UiSparseCrtRegion
    if ($Cancel -or $state.InputSerial -ne $idle.InputSerial) {
        $state.InputSerial=$idle.InputSerial; $state.GestureSerial=$idle.GestureSerial
        $state.Region=''; $state.BunnyDueMs=-1.0
        $script:UiSparseCrtIntroPending=$false
        $script:UiSparseCrtPhase=-1; $script:UiSparseCrtRegion=''
        return ($oldPhase -ge 0)
    }
    if ($state.GestureSerial -ne $idle.GestureSerial) {
        # The gesture scheduler is authoritative, including starts delayed by
        # sleep or work. Internal idle frames never start another sweep.
        $state.GestureSerial=$idle.GestureSerial
        $state.Region='Logo'; $state.StartMs=$ElapsedMs
        $state.BunnyDueMs=$ElapsedMs+$script:MioSparseCrtBunnyDelayMs
        $script:UiSparseCrtIntroPending=$false
    } elseif ($script:UiSparseCrtIntroPending) {
        $script:UiSparseCrtIntroPending=$false
        $state.Region='Bunny'; $state.StartMs=$ElapsedMs
    }
    if ($state.Region) {
        $frames=$script:MioSparseCrtBunnyFrameCount
        if ($state.Region -eq 'Logo') {$frames=$script:MioSparseCrtLogoFrameCount}
        $duration=$frames*1000.0/$script:MioSparseCrtContinuousFps
        if ($ElapsedMs-$state.StartMs -ge $duration) {$state.Region=''}
    }
    if (-not $state.Region -and $state.BunnyDueMs -ge 0 -and $ElapsedMs -ge $state.BunnyDueMs) {
        # An expired bunny pass is skipped, never replayed after a long stall.
        if ($ElapsedMs -lt $state.BunnyDueMs+$script:MioSparseCrtBunnyFrameCount*1000.0/$script:MioSparseCrtContinuousFps) {
            $state.Region='Bunny'; $state.StartMs=$state.BunnyDueMs
        }
        $state.BunnyDueMs=-1.0
    }
    if ($state.Region -eq 'Logo' -and $script:MioSparseCrtGeometry -and $script:MioSparseCrtGeometry.LogoRow -eq 0) {$state.Region=''}
    $phase=-1
    if ($state.Region) {$phase=[int][Math]::Floor([Math]::Max(0.0,$ElapsedMs-$state.StartMs)*$script:MioSparseCrtContinuousFps/1000.0)}
    $script:UiSparseCrtPhase=$phase; $script:UiSparseCrtRegion=$state.Region
    return ($phase -ne $oldPhase -or $state.Region -cne $oldRegion)
}
function Get-MioSparseCrtLevels([int]$Phase) {
    if ($script:MioSparseCrtMode -in 'Continuous','Synchronized' -and $script:MioSparseCrtGeometry) {
        return ,(Get-MioContinuousCrtLevels $Phase).Bunny
    }
    if (-not $script:MioSparseCrtLevels) {
        $script:MioSparseCrtLevels=New-Object 'int[][]' 48
        for ($step=0;$step -lt 48;$step++) {
            $levels=New-Object 'int[]' 24
            $center=$step/2.0
            for ($row=0;$row -lt 24;$row++) {
                $base=100; if (($row%2) -eq 1) {$base=84}
                $distance=[Math]::Abs($row-$center)
                $gain=1.0
                if ($distance -lt 1.5) {$gain-=0.12*(1-$distance/1.5)}
                $levels[$row]=[int][Math]::Round($base*$gain)
            }
            $script:MioSparseCrtLevels[$step]=$levels
        }
    }
    return ,$script:MioSparseCrtLevels[$Phase]
}
function Get-MioContinuousCrtLevels([int]$Phase) {
    $geometry=$script:MioSparseCrtGeometry
    $frames=[int][Math]::Ceiling($script:MioSparseCrtContinuousCycleMs*$script:MioSparseCrtContinuousFps/1000.0)
    $regionMode='Continuous'; $sweepOffset=0.0; $sweepPixels=$geometry.SpanPixels
    if ($script:MioSparseCrtMode -eq 'Synchronized') {
        $regionMode=$script:UiSparseCrtRegion
        $frames=$script:MioSparseCrtBunnyFrameCount; $sweepOffset=2*($geometry.BunnyRow-1)
        if ($regionMode -eq 'Logo') {$frames=$script:MioSparseCrtLogoFrameCount; $sweepOffset=2*($geometry.LogoRow-1)}
    }
    $key=$geometry.Key+'|'+$regionMode+'|'+$frames
    if (-not $script:MioContinuousCrtLevels.ContainsKey($key)) {
        if ($script:MioContinuousCrtLevels.Count -ge 4) {$script:MioContinuousCrtLevels.Clear()}
        $templates=New-Object 'object[]' $frames
        for ($step=0;$step -lt $frames;$step++) {
            $center=$step*$geometry.SpanPixels/[double]$frames
            # One physical half-cell row per frame in either artwork region.
            # The taller bunny therefore takes longer, at the same speed.
            if ($script:MioSparseCrtMode -eq 'Synchronized') {$center=$sweepOffset+$step}
            if ($regionMode -eq 'Logo' -and $geometry.LogoRow -eq 0) {$center=-1000000.0}
            $regions=@{}
            foreach ($region in 'Logo','Bunny') {
                $count=24; $offset=2*($geometry.BunnyRow-1)
                if ($region -eq 'Logo') {$count=10; $offset=2*($geometry.LogoRow-1)}
                $levels=New-Object 'int[]' $count
                for ($row=0;$row -lt $count;$row++) {
                    $base=100; if (($row%2) -eq 1) {$base=84}
                    $distance=[Math]::Abs($offset+$row-$center); $gain=1.0
                    if ($distance -lt 1.5) {$gain-=0.12*(1-$distance/1.5)}
                    $levels[$row]=[int][Math]::Round($base*$gain)
                }
                $regions[$region]=$levels
            }
            $templates[$step]=$regions
        }
        $script:MioContinuousCrtLevels[$key]=$templates
    }
    return $script:MioContinuousCrtLevels[$key][$Phase]
}
function Get-MioFrame([string]$Mood,[int]$Tick,[string]$PoseOverride) {
    # Refined original 22 x 24 bunny, drawn as two pixel rows per terminal cell.
    if (-not $script:MioPixelFrames) {
        $script:MioPixelFrames=@{
            'idle'=('.......OO....OO......./......OWWO..OWWO....../......OWWO..OWWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWOOOOPWO....../......OWWWWWWWWO....../.....OWWWWWWWWWWO...../....OWWWWWWWWWWWWO..../...OWWWDWWWWWWDWWWO.../...OWWWDWWWWWWDWWWO.../...OWBBWWWDWWWWBBWO.../...OWWWWWDWDWWWWWWO.../....OWWWWWWWWWWWWO..../.....OSSSSSSSSSSO...../......OOSSOOOSSOWOOO../......OSWWSSSWWSWOWWO./......OSWWSSSWWSWOWWO./.......OSSSSSSSSOWWWO./......OOOOSSSOOOOOOO../.....OWWWWOSOWWWWO..../......OOOO...OOOO.....' -split '/')
            'blink'=('.......OO....OO......./......OWWO..OWWO....../......OWWO..OWWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWOOOOPWO....../......OWWWWWWWWO....../.....OWWWWWWWWWWO...../....OWWWWWWWWWWWWO..../...OWWWWWWWWWWWWWWO.../...OWWDDDWWWWDDDWWO.../...OWBBWWWDWWWWBBWO.../...OWWWWWDWDWWWWWWO.../....OWWWWWWWWWWWWO..../.....OSSSSSSSSSSO...../......OOSSOOOSSOWOOO../......OSWWSSSWWSWOWWO./......OSWWSSSWWSWOWWO./.......OSSSSSSSSOWWWO./......OOOOSSSOOOOOOO../.....OWWWWOSOWWWWO..../......OOOO...OOOO.....' -split '/')
            'scanleft'=('.......OO....OO......./......OWWO..OWWO....../......OWWO..OWWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWOOOOPWO....../......OWWWWWWWWO....../.....OWWWWWWWWWWO...../....OWWWWWWWWWWWWO..../...OWWDWWWWWWDWWWWO.../...OWWDWWWWWWDWWWWO.../...OWBBWWWDWWWWBBWO.../...OWWWWWDWDWWWWWWO.../....OWWWWWWWWWWWWO..../.....OSSSSSSSSSSO...../......OOSSOOOSSOWOOO../......OSWWSSSWWSWOWWO./......OSWWSSSWWSWOWWO./.......OSSSSSSSSOWWWO./......OOOOSSSOOOOOOO../.....OWWWWOSOWWWWO..../......OOOO...OOOO.....' -split '/')
            'scanright'=('.......OO....OO......./......OWWO..OWWO....../......OWWO..OWWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWOOOOPWO....../......OWWWWWWWWO....../.....OWWWWWWWWWWO...../....OWWWWWWWWWWWWO..../...OWWWWDWWWWWWDWWO.../...OWWWWDWWWWWWDWWO.../...OWBBWWWDWWWWBBWO.../...OWWWWWDWDWWWWWWO.../....OWWWWWWWWWWWWO..../.....OSSSSSSSSSSO...../......OOSSOOOSSOWOOO../......OSWWSSSWWSWOWWO./......OSWWSSSWWSWOWWO./.......OSSSSSSSSOWWWO./......OOOOSSSOOOOOOO../.....OWWWWOSOWWWWO..../......OOOO...OOOO.....' -split '/')
            'work'=('.......OO....OO......./......OWWO..OWWO....../......OWWO..OWWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWOOOOPWO....../......OWWWWWWWWO....../.....OWWWWWWWWWWO...../....OWWWWWWWWWWWWO..../...OWWWWWWWWWWWWWWO.../...OWWWDWWWWWWDWWWO.../...OWBBDWWDWWWDBBWO.../...OWWWWWDWDWWWWWWO.../....OWWWWWWWWWWWWO..../.....OSSSSSSSSSSO...../......OOSSOOOSSOWOOO../......OSWWSSSWWSWOWWO./......OSWWSSSWWSWOWWO./.......OSSSSSSSSOWWWO./......OOOOSSSOOOOOOO../.....OWWWWOSOWWWWO..../......OOOO...OOOO.....' -split '/')
            'check'=('.......OO....OO......./......OWWO..OWWO....../......OWWO..OWWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWOOOOPWO....../......OWWWWWWWWO....../.....OWWWWWWWWWWO...../....OWWWWWWWWWWWWO..../...OWWWDWWWWWWWWWWO.../...OWWWDWWWWWDDDWWO.../...OWBBWWWDWWWWBBWO.../...OWWWWWDWDWWWWWWO.../....OWWWWWWWWWWWWO..../.....OSSSSSSSSSSO...../......OOSSOOOSSOWOOO../......OSWWSSSWWSWOWWO./......OSWWSSSWWSWOWWO./.......OSSSSSSSSOWWWO./......OOOOSSSOOOOOOO../.....OWWWWOSOWWWWO..../......OOOO...OOOO.....' -split '/')
            'happy'=('.......OO....OO......./......OWWO..OWWO....../......OWWO..OWWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWOOOOPWO....../......OWWWWWWWWO....../.....OWWWWWWWWWWO...../....OWWWWWWWWWWWWO..../...OWWWDWWWWWWDWWWO.../...OWWDWDWWWWDWDWWO.../...OWBBWWWDWWWWBBWO.../...OWWWWWDWDWWWWWWO.../....OWWWWWWWWWWWWO..../.....OSSSSSSSSSSO...../......OOSSOOOSSOWOOO../......OSWWSSSWWSWOWWO./......OSWWSSSWWSWOWWO./.......OSSSSSSSSOWWWO./......OOOOSSSOOOOOOO../.....OWWWWOSOWWWWO..../......OOOO...OOOO.....' -split '/')
            'happyturn'=('.......OO....OO......./......OWWO..OWWO....../......OWWO..OWWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWOOOOPWO....../......OWWWWWWWWO....../.....OWWWWWWWWWWO...../....OWWWWWWWWWWWWO..../...OWWWDWWWWWWDWWWO.../...OWWDWDWWWWDWDWWO.../...OWBBWWWDWWWWBBWO.../...OWWWWWDWDWWWWWWO.../....OWWWWWWWWWWWWO..../.....OSSSSSSSSSSO...../......OOWWOOOWWOWOOO../......OSWWSSSWWSWOWWO./......OSSSSSSSSSWOWWO./.......OSSSSSSSSOWWWO./......OOOOSSSOOOOOOO../.....OWWWWOSOWWWWO..../......OOOO...OOOO.....' -split '/')
            'oops'=('.......OO....OO......./......OWWO..OWWO....../......OWWO..OWWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWOOOOPWO....../......OWWWWWWWWO....../.....OWWWWWWWWWWO...../....OWWWWWWWWWWWWO..../...OWWWDDWWWWDDWWWO.../...OWWWDDWWWWDDWWWO.../...OWBBWWWDWWWWBBWO.../...OWWWWWWWWWWWWWWO.../....OWWWWWDWWWWWWO..../.....OSSSSSSSSSSO...../......OOSSOOOSSOWOOO../......OSWWSSSWWSWOWWO./......OSWWSSSWWSWOWWO./.......OSSSSSSSSOWWWO./......OOOOSSSOOOOOOO../.....OWWWWOSOWWWWO..../......OOOO...OOOO.....' -split '/')
            'wait'=('.......OO....OO......./......OWWO..OWWO....../......OWWO..OWWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWO..OPWO....../......OPWOOOOPWO....../......OWWWWWWWWO....../.....OWWWWWWWWWWO...../....OWWWWWWWWWWWWO..../...OWWWWWWWWWWWWWWO.../...OWWWDWWWWWWDWWWO.../...OWBBWWWDWWWWBBWO.../...OWWWWWDWDWWWWWWO.../....OWWWWWWWWWWWWO..../.....OSSSSSSSSSSO...../......OOSSOOOSSOWOOO../......OSWWSSSWWSWOWWO./......OSWWSSSWWSWOWWO./.......OSSSSSSSSOWWWO./......OOOOSSSOOOOOOO../.....OWWWWOSOWWWWO..../......OOOO...OOOO.....' -split '/')
        }
        $script:MioPixelColors=@{O='129;117;158';W='255;246;247';S='235;224;239';P='241;164;194';D='57;50;68';B='238;158;187'}
        Initialize-MioIdleLibrary $script:MioPixelFrames
    }
    $pose='idle'
    switch ($Mood) {
        'idle' {
            # A relaxed menu loop: glance around, wink and briefly lift both
            # paws. Pose timing stays on the shared clock, never on key presses.
            $idleBeat=$Tick%32
            if ($idleBeat -eq 6) {$pose='blink'}
            elseif ($idleBeat -ge 10 -and $idleBeat -le 12) {$pose='scanleft'}
            elseif ($idleBeat -ge 13 -and $idleBeat -le 15) {$pose='scanright'}
            elseif ($idleBeat -ge 19 -and $idleBeat -le 21) {$pose='check'}
            elseif ($idleBeat -ge 24 -and $idleBeat -le 25) {$pose='happyturn'}
            elseif ($idleBeat -ge 22 -and $idleBeat -le 27) {$pose='happy'}
        }
        'scan' {if (($Tick%16) -lt 8) {$pose='scanleft'} else {$pose='scanright'}}
        'work' {if (($Tick%18) -ge 12) {$pose='work'}}
        'check' {$pose='check'}
        'happy' {if (($Tick%12) -lt 6) {$pose='happy'} else {$pose='happyturn'}}
        'oops' {$pose='oops'}
        'wait' {$pose='wait'}
        default {if (($Tick%30) -ge 24) {$pose='work'}}
    }
    if (($Tick%28) -ge 26 -and $Mood -notin 'idle','happy','oops','wait') {$pose='blink'}
    if ($PoseOverride -and $script:MioPixelFrames.ContainsKey($PoseOverride)) {$pose=$PoseOverride}
    $pixels=$script:MioPixelFrames[$pose]
    # Timed color modulation creates the requested CRT look without erasing
    # frames, moving pixels or changing any menu/status/input text.
    $useCrt=($script:DisplayEffect -eq 'CRT' -and $script:UiAnsi -and -not $script:UiFullScreenCrt)
    $animatedCrt=($useCrt -and $script:UiLive)
    $sparseCrt=($useCrt -and -not $script:UiLive -and $script:UiSparseCrtPhase -ge 0 -and
        ($script:MioSparseCrtMode -notin 'Continuous','Synchronized' -or $script:MioSparseCrtGeometry))
    $cacheKey=$pose+'|'+$script:UiAnsi+'|'+$useCrt
    $phaseKey=$null
    if ($sparseCrt) {
        $phaseKey=$pose+'|'+$script:MioSparseCrtMode+'|'+$script:UiSparseCrtPhase
        if ($script:MioSparseCrtMode -in 'Continuous','Synchronized') {$phaseKey+='|'+$script:MioSparseCrtGeometry.Key+'|'+$script:MioSparseCrtContinuousFps+'|'+$script:MioSparseCrtContinuousCycleMs+'|'+$script:UiSparseCrtRegion+'|'+$script:MioSparseCrtLogoFrameCount+'|'+$script:MioSparseCrtBunnyFrameCount}
        if ($script:MioSparseCrtFrames.ContainsKey($phaseKey)) {return $script:MioSparseCrtFrames[$phaseKey]}
    } elseif (-not $animatedCrt -and $script:MioRenderCache.ContainsKey($cacheKey)) {return $script:MioRenderCache[$cacheKey]}
    $rowLevels=$null
    if ($useCrt) {
        if (-not $script:MioCrtPalettes) {
            $script:MioCrtPalettes=@{}
            for ($level=65;$level -le 100;$level++) {
                $palette=@{}
                foreach ($key in $script:MioPixelColors.Keys) {
                    $rgb=$script:MioPixelColors[$key].Split(';')
                    $palette[$key]=((@($rgb | ForEach-Object {[int][Math]::Round([int]$_*$level/100.0)})) -join ';')
                }
                $script:MioCrtPalettes[$level]=$palette
            }
        }
        if ($animatedCrt) {
            if (-not $script:UiDemoPaused) {$script:UiCrtTimeMs=$script:UiEffectClock.Elapsed.TotalMilliseconds}
            $seconds=$script:UiCrtTimeMs/1000.0
            $flutter=0.95+0.035*[Math]::Sin($seconds*2*[Math]::PI*1.35)+0.015*[Math]::Sin($seconds*2*[Math]::PI*3.1)
            $band=($seconds%3.8)/3.8*30-3
            $rowLevels=@(for ($row=0;$row -lt 24;$row++) {
                $distance=$row-$band
                $gain=$flutter*(1-0.22*[Math]::Exp(-$distance*$distance/5.0))
                if (($row%2) -eq 1) {$gain*=0.94}
                [int][Math]::Max(65,[Math]::Min(100,[Math]::Round(100*$gain)))
            })
        } elseif ($sparseCrt) {
            $rowLevels=Get-MioSparseCrtLevels $script:UiSparseCrtPhase
        } else {
            # A visible scanline texture costs only the first render of a pose.
            # Sparse gestures reuse it without starting a CRT redraw clock.
            $rowLevels=@(for ($row=0;$row -lt 24;$row++) {if (($row%2) -eq 0) {100} else {84}})
        }
    }
    $result=[System.Collections.Generic.List[string]]::new()
    for ($y=0;$y -lt 24;$y+=2) {
        $topColors=$script:MioPixelColors; $bottomColors=$script:MioPixelColors
        if ($useCrt) {
            $rowKey=$pose+'|'+$y+'|'+$rowLevels[$y]+'|'+$rowLevels[$y+1]
            if ($script:MioCrtRowCache.ContainsKey($rowKey)) {
                $result.Add($script:MioCrtRowCache[$rowKey]); continue
            }
            $topColors=$script:MioCrtPalettes[$rowLevels[$y]]
            $bottomColors=$script:MioCrtPalettes[$rowLevels[$y+1]]
        }
        $line=[Text.StringBuilder]::new()
        for ($x=0;$x -lt 22;$x++) {
            $top=[string]$pixels[$y][$x]; $bottom=[string]$pixels[$y+1][$x]
            if ($top -eq '.' -and $bottom -eq '.') {[void]$line.Append(' '); continue}
            if (-not $script:UiAnsi) {[void]$line.Append('#'); continue}
            if ($top -eq '.') {
                [void]$line.Append($script:Esc+'[38;2;'+$bottomColors[$bottom]+'m'+[char]0x2584+$script:Esc+'[0m')
            } elseif ($bottom -eq '.') {
                [void]$line.Append($script:Esc+'[38;2;'+$topColors[$top]+'m'+[char]0x2580+$script:Esc+'[0m')
            } else {
                [void]$line.Append($script:Esc+'[38;2;'+$topColors[$top]+';48;2;'+$bottomColors[$bottom]+'m'+[char]0x2580+$script:Esc+'[0m')
            }
        }
        $renderedRow=$line.ToString(); $result.Add($renderedRow)
        if ($useCrt) {
            # Reuse identical quantized CRT rows without freezing its clock.
            # Bound memory even during a long-running conversion or demo.
            if ($script:MioCrtRowCache.Count -ge 1024) {
                $script:MioCrtRowCache.Remove($script:MioCrtRowOrder.Dequeue())
            }
            $script:MioCrtRowCache[$rowKey]=$renderedRow
            $script:MioCrtRowOrder.Enqueue($rowKey)
        }
    }
    $rendered=$result.ToArray()
    if ($sparseCrt) {
        # Cache a finite set of pose/phase combinations. Repeated sweep cycles
        # reuse complete rows; unusual gestures cannot grow this indefinitely.
        if ($script:MioSparseCrtFrames.Count -ge 256) {
            $script:MioSparseCrtFrames.Remove($script:MioSparseCrtFrameOrder.Dequeue())
        }
        $script:MioSparseCrtFrames[$phaseKey]=$rendered
        $script:MioSparseCrtFrameOrder.Enqueue($phaseKey)
    } elseif (-not $animatedCrt) {$script:MioRenderCache[$cacheKey]=$rendered}
    return $rendered
}
function Get-TimedMioFrame([string]$Mood,[string]$PoseOverride,[switch]$Refresh) {
    # Forced per-file/status redraws must not accelerate Mio or flicker between
    # stage expressions. Sample the latest pose at most every 250 ms without
    # delaying work; completion and explicit gallery poses can update at once.
    if ($script:UiIdlePoseOverride -and $Mood -in 'idle','wait' -and -not $script:UiDemo -and -not $PoseOverride) {
        $PoseOverride=$script:UiIdlePoseOverride
    }
    $first=($null -eq $script:UiMioMood)
    $due=($script:UiMioWatch.ElapsedMilliseconds -ge 250)
    if ($first -or $Refresh -or -not $script:UiLive -or
        $PoseOverride -ne $script:UiMioPoseOverride -or
        ($due -and -not $script:UiDemoPaused)) {
        if (-not $first -and $due -and $script:UiLive -and -not $script:UiDemoPaused) {$script:UiTick++}
        $script:UiMioMood=$Mood; $script:UiMioPoseOverride=$PoseOverride
        $script:UiMioWatch.Restart()
    }
    return (Get-MioFrame $script:UiMioMood $script:UiTick $script:UiMioPoseOverride)
}
function Get-ProgressBar([double]$Percent,[int]$Width,[int]$Tick) {
    $text=''
    if ($Percent -ge 0) {
        $filled=[int][Math]::Floor($Width*[Math]::Min(100,$Percent)/100)
        for ($i=0;$i -lt $Width;$i++) {
            if ($i -lt $filled) {$text+=(Color-Text '#' $script:Pride[([int][Math]::Floor($i*$script:Pride.Count/$Width))%$script:Pride.Count])}
            else {$text+=(Color-Text '.' '71;78;103')}
        }
    } else {
        $spot=$Tick%($Width+4)-4
        for ($i=0;$i -lt $Width;$i++) {
            if ($i -ge $spot -and $i -lt $spot+4) {$text+=(Color-Text '=' $script:Trans[($i+5)%5])}
            else {$text+=(Color-Text '.' '71;78;103')}
        }
    }
    return ('['+$text+']')
}
function Get-TerminalFrame([string[]]$Lines) {
    # Leave a row below the frame so a subsequent plain message cannot scroll
    # its first line. A compact banner keeps short windows usable.
    $available=$script:UiHeight-$Lines.Count-1
    $banner=@(Get-DisplayBanner ($available -ge 7 -and $script:UiHeight -ge 9 -and $script:UiWidth -ge 72))
    $rows=[System.Collections.Generic.List[string]]::new()
    foreach ($row in $banner) {$rows.Add($row)}
    $noticeCount=[Math]::Max(0,[Math]::Min(3,$script:UiHeight-$banner.Count-$Lines.Count-1))
    if ($script:UiDemo -or $script:UiMenuActive) {$noticeCount=0}
    if ($script:UiEventRows) {
        $first=[Math]::Max(0,$script:UiEventRows.Count-$noticeCount)
        for ($i=$first;$i -lt $script:UiEventRows.Count;$i++) {
            $row=$script:UiEventRows[$i]
            $plain=$row -replace '\x1b\[[0-9;]*m',''
            $noticeWidth=[Math]::Max(1,[Math]::Min($script:UiWidth+2,$script:UiColumns-2))
            if ((Get-TextWidth $plain) -gt $noticeWidth) {$row=Color-Text (Fit-Text $plain $noticeWidth) '255;221;144'}
            $rows.Add($row)
        }
    }
    foreach ($row in $Lines) {$rows.Add($row)}
    return [pscustomobject]@{Lines=$rows.ToArray(); BannerRows=$banner.Count}
}
function Flush-DisplayEvents {
    if ($script:UiPendingEvents) {
        if ($script:UiPendingEvents.Count) {$script:UiIdleMenuCache=$null}
        foreach ($row in $script:UiPendingEvents) {$script:UiEventRows.Add($row)}
        $script:UiPendingEvents.Clear()
        while ($script:UiEventRows.Count -gt 100) {$script:UiEventRows.RemoveAt(0)}
    }
}
function Write-TerminalPanel([string[]]$Lines,[int]$InputColumn=0,[bool]$ShowCaret=$true) {
    $script:UiIdleMenuCache=$null
    Flush-DisplayEvents
    $layout=Get-TerminalFrame $Lines
    $script:UiLastLogoRows=@()
    if ($layout.BannerRows -eq 7) {$script:UiLastLogoRows=@($layout.Lines[0..4] | ForEach-Object {$_.Substring(2)})}
    $script:UiLastFrameRows=$layout.Lines.Count
    # Anchor the whole frame to the viewport. No trailing newline: even a
    # frame ending at the bottom must never scroll its own banner away.
    $frame=[Text.StringBuilder]::new()
    [void]$frame.Append($script:Esc+'[?25l'+$script:Esc+'[r'+$script:Esc+'[H')
    for ($i=0;$i -lt $layout.Lines.Count;$i++) {
        if ($i -gt 0) {[void]$frame.Append("`r`n")}
        [void]$frame.Append($layout.Lines[$i]+$script:Esc+'[K')
    }
    [void]$frame.Append($script:Esc+'[J')
    $script:UiBannerRows=$layout.BannerRows; $script:UiPinned=$true
    [void]$frame.Append($script:Esc+'['+($layout.BannerRows+1)+';'+$script:UiHeight+'r')
    $script:UiRows=$Lines.Count
    $cursorRow=[Math]::Min($script:UiHeight,$layout.Lines.Count+1); $cursorColumn=1
    if ($InputColumn -gt 0) {
        $cursorRow=$layout.Lines.Count; $cursorColumn=$InputColumn
    }
    [void]$frame.Append($script:Esc+'['+$cursorRow+';'+$cursorColumn+'H')
    # The input field paints its own timed caret. Keeping the native cursor
    # hidden avoids every animation frame restarting the terminal's blink.
    [Console]::Write($frame.ToString())
}

function Get-MenuRows([string[]]$Lines,[int]$Width) {
    $rows=[System.Collections.Generic.List[string]]::new()
    foreach ($text in $Lines) {
        $line=($text -replace '[\x00-\x1f\x7f-\x9f]',' ').TrimStart()
        while ((Get-TextWidth $line) -gt $Width) {
            $prefix=Get-TextPrefix $line $Width
            $cut=$prefix.LastIndexOf(' ')
            if ($cut -lt [int]($prefix.Length/2)) {$cut=$prefix.Length}
            $rows.Add($line.Substring(0,$cut))
            $line=$line.Substring($cut).TrimStart()
        }
        $rows.Add($line)
    }
    return $rows.ToArray()
}

function Draw-MenuPanel([string]$Title,[string[]]$Rows,[string]$Prompt,
                        [string]$InputText,[int]$Caret,[string]$Mood='idle',[switch]$RefreshMio) {
    $requiredHeight=[Math]::Max(12,$Rows.Count)+7
    if (-not $script:UiPanel -or $script:UiHeight -lt $requiredHeight) {
        Draw-ResizePanel $Title $Prompt $InputText $Caret $requiredHeight
        return
    }
    $w=$script:UiWidth; $left=$w-28
    $bodyRows=[Math]::Max(12,$Rows.Count); $borderHeight=$bodyRows+3
    if ($script:MioSparseCrtMode -in 'Continuous','Synchronized') {
        Flush-DisplayEvents
        $geometryKey=('{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $w,$script:UiColumns,$script:UiHeight,$bodyRows,$script:UiMenuActive,$script:UiDemo,$script:UiEventRows.Count)
        if ($geometryKey -cne $script:MioSparseCrtGeometryKey) {
            $placeholder=New-Object 'string[]' ($bodyRows+5)
            $layout=Get-TerminalFrame $placeholder
            $bunnyRow=$layout.Lines.Count-$placeholder.Count+3
            $logoRow=0; if ($layout.BannerRows -eq 7) {$logoRow=1}
            $script:MioSparseCrtGeometry=@{Key=($logoRow.ToString()+'|'+$bunnyRow);LogoRow=$logoRow;BunnyRow=$bunnyRow;SpanPixels=(2*($bunnyRow-1)+24)}
            $script:MioSparseCrtGeometryKey=$geometryKey
        }
    }
    $mio=@(Get-TimedMioFrame $Mood -Refresh:$RefreshMio)
    # A sparse gesture changes only Mio. Preserve the rest of the terminal,
    # including its steady input caret, and avoid rebuilding every border.
    $patchable=($script:UiVT -and -not $script:UiLive -and -not $script:UiDemo -and
        ($script:UiIdlePoseOverride -or $script:UiSparseCrtPhase -ge 0 -or $script:UiIdleMenuCache.SparseCrt) -and $mio.Count -eq 12 -and
        (-not $script:UiPendingEvents -or $script:UiPendingEvents.Count -eq 0))
    $rowsKey=$Rows -join [char]0
    $cached=$script:UiIdleMenuCache
    if ($patchable -and $cached -and $script:UiPinned -and
        $cached.Width -eq $w -and $cached.Height -eq $script:UiHeight -and
        $cached.Columns -eq $script:UiColumns -and $cached.BannerRows -eq $script:UiBannerRows -and
        $cached.PanelRows -eq $script:UiRows -and $cached.FrameRows -eq $script:UiLastFrameRows -and
        $cached.Title -ceq $Title -and $cached.RowsKey -ceq $rowsKey -and $cached.Prompt -ceq $Prompt -and
        $cached.InputText -ceq $InputText -and $cached.Caret -eq $Caret -and $cached.Mood -ceq $Mood -and
        $cached.Ansi -eq $script:UiAnsi -and $cached.Version -ceq $script:AppVersion -and
        $cached.Effect -ceq $script:DisplayEffect -and $cached.MenuActive -eq $script:UiMenuActive -and
        $cached.EventCount -eq $script:UiEventRows.Count) {
        $patch=[Text.StringBuilder]::new()
        $logo=@()
        if ($script:MioSparseCrtMode -in 'Continuous','Synchronized' -and $cached.LogoRow -gt 0) {
            $logo=@(Get-OptiLogoRows)
            for ($i=0;$i -lt $logo.Count;$i++) {
                if ($logo[$i] -cne $cached.Logo[$i]) {[void]$patch.Append($script:Esc+'['+($cached.LogoRow+$i)+';3H'+$logo[$i])}
            }
        }
        for ($i=0;$i -lt $mio.Count;$i++) {
            if ($mio[$i] -cne $cached.Mio[$i]) {
                [void]$patch.Append($script:Esc+'['+($cached.BunnyRow+$i)+';'+($w-20)+'H'+$mio[$i])
            }
        }
        if ($patch.Length -gt 0) {
            [void]$patch.Append($script:Esc+'[0m'+$script:Esc+'['+$cached.FrameRows+';'+$cached.InputColumn+'H')
            [Console]::Write($patch.ToString())
        }
        $cached.Mio=$mio
        if ($logo.Count) {$cached.Logo=$logo}
        if ($script:UiSparseCrtPhase -ge 0) {$cached.SparseCrt=$true}
        return
    }
    $border=Get-BorderMotion $w $borderHeight
    $lines=[System.Collections.Generic.List[string]]::new()
    $heading=Fit-Text ('-- OptiMiyoo v'+$script:AppVersion+' / '+$Title+' ') ($w-2)
    $lines.Add('  '+(Format-BorderText ('+'+$heading.TrimEnd().PadRight($w-2,'-')+'+') 0 0 $border))
    $channel='SRC -> DST / LOCAL DISK LINK'
    if ($script:UiDemo) {$channel=('DEMO scene {0}/{1} / SIMULATION' -f $script:UiDemoScene,$script:UiDemoCount)}
    $lines.Add('  '+(Format-BorderText '|' 0 1 $border)+' '+(Color-Text (Fit-Text $channel $left) '107;216;245')+(Color-Text ' | ' '91;104;151')+(Color-Text (Fit-Text '    MIO // READY' 22) '249;172;204')+(Format-BorderText '|' ($w-1) 1 $border))
    for ($i=0;$i -lt $bodyRows;$i++) {
        $text=''; if ($i -lt $Rows.Count) {$text=$Rows[$i]}
        $right=' '*22; if ($i -lt $mio.Count) {$right=$mio[$i]}
        $rgb='218;224;244'
        if ($text -match '\[(?:unsupported|unverified|not installed)\]') {$rgb='255;221;144'}
        elseif ($text -match '^[A-Z]\.') {$rgb='107;216;245'}
        $lines.Add('  '+(Format-BorderText '|' 0 ($i+2) $border)+' '+(Color-Text (Fit-Text $text $left) $rgb)+(Color-Text ' | ' '91;104;151')+$right+(Format-BorderText '|' ($w-1) ($i+2) $border))
    }
    $lines.Add('  '+(Format-BorderText ('+'+('-'*($w-2))+'+') 0 ($borderHeight-1) $border $true))
    $lines.Add('  '+(Color-Text (Fit-Text $Prompt $w) '249;202;226'))
    $fieldWidth=$w-8
    $inputView=Get-InputViewport $InputText $Caret $fieldWidth
    if ($script:UiDemo) {$lines.Add('  '+(Get-MioPreviewTourBar $w))}
    else {$lines.Add('  '+(Color-Text 'INPUT > ' '107;216;245')+(Format-InputField $inputView $fieldWidth))}
    Write-TerminalPanel $lines.ToArray() (11+$inputView.Caret) (-not $script:UiDemo)
    if ($patchable) {
        $script:UiIdleMenuCache=[pscustomobject]@{
            Width=$w;Height=$script:UiHeight;Columns=$script:UiColumns;BannerRows=$script:UiBannerRows
            PanelRows=$script:UiRows;FrameRows=$script:UiLastFrameRows;Title=$Title;RowsKey=$rowsKey;Prompt=$Prompt
            InputText=$InputText;Caret=$Caret;Mood=$Mood;Ansi=$script:UiAnsi;Version=$script:AppVersion
            Effect=$script:DisplayEffect;MenuActive=$script:UiMenuActive;EventCount=$script:UiEventRows.Count
            Mio=$mio;SparseCrt=($script:UiSparseCrtPhase -ge 0);Logo=$script:UiLastLogoRows
            LogoRow=$(if ($script:UiBannerRows -eq 7) {1} else {0})
            InputColumn=(11+$inputView.Caret);BunnyRow=($script:UiLastFrameRows-$lines.Count+3)
        }
    }
}

function Draw-ResizePanel([string]$Title,[string]$Detail,[string]$InputText='',
                          [int]$Caret=-1,[int]$RequiredHeight=19) {
    if ($script:UiColumns -lt 20 -or $script:UiHeight -lt 6) {return}
    $width=[Math]::Min(92,$script:UiColumns-4)
    $lines=[System.Collections.Generic.List[string]]::new()
    $lines.Add('  '+(Fit-Text ('OptiMiyoo / '+$Title) $width))
    $lines.Add('  '+(Fit-Text ('Resize to at least 76 x '+$RequiredHeight+'.') $width))
    $lines.Add('  '+(Fit-Text $Detail $width))
    if ($Caret -ge 0) {
        $fieldWidth=$width-8; $inputView=Get-InputViewport $InputText $Caret $fieldWidth
        $lines.Add('  INPUT > '+(Format-InputField $inputView $fieldWidth (-not $script:UiDemo)))
        Write-TerminalPanel $lines.ToArray() (11+$inputView.Caret) (-not $script:UiDemo)
    } else {
        $message='Processing continues; progress is logged.'
        if ($script:UiDemo) {$message='DEMO / no files are accessed'}
        $lines.Add('  '+(Fit-Text $message $width))
        Write-TerminalPanel $lines.ToArray() 0 $false
    }
}

function Read-DisplayInput([string]$Prompt,[string]$Title='Selection',
                           [string[]]$Lines=@(),[string]$Mood='idle') {
    $Prompt=ConvertTo-SafeExternalText $Prompt
    [void](Update-DisplaySize)
    $rows=@(Get-MenuRows $Lines ([Math]::Max(44,$script:UiWidth-28)))
    $canDraw=$script:UiPanel
    try {
        # An undersized interactive window gets the resize panel and can
        # recover in this input loop as soon as it is enlarged.
        $canDraw=$script:UiVT
        if ($canDraw) {$null=[Console]::KeyAvailable}
    } catch {$canDraw=$false}
    if (-not $canDraw) {
        Clear-DisplayPanel
        foreach ($line in $Lines) {Write-Host ('  '+(ConvertTo-SafeExternalText $line).TrimStart())}
        if ([Console]::IsInputRedirected) {
            Write-Host ($Prompt+': ') -NoNewline
            $line=[Console]::ReadLine()
            if ($null -eq $line) {return 'Q'}
            return $line.Trim()
        }
        if ($script:UiInteractive) {try {[Console]::CursorVisible=$true} catch {}}
        return ([string](Read-Host $Prompt)).Trim()
    }
    $text=''; $caret=0; $dirty=$true
    Update-InputCaret $text $caret -Reset
    $script:UiCaretDrawn=$null
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $idleWatch=[Diagnostics.Stopwatch]::StartNew()
    $sparseIdle=([bool](Get-Variable IdleAnimations -ValueOnly -ErrorAction SilentlyContinue) -and $Mood -eq 'idle' -and -not $script:UiDemo -and -not $script:UiLive)
    $script:UiIdlePoseOverride=$null
    Reset-MioSparseCrt
    if ($sparseIdle) {Reset-MioIdleInput}
    try {
        while ($true) {
            if (Update-DisplaySize -Throttled) {
                $rows=@(Get-MenuRows $Lines ([Math]::Max(44,$script:UiWidth-28)))
                $dirty=$true
            }
            $bunnyVisible=($script:UiPanel -and $script:UiHeight -ge ([Math]::Max(12,$rows.Count)+7))
            if ($sparseIdle) {
                $idlePose=Get-MioIdlePose $idleWatch.Elapsed.TotalMilliseconds ($text.Length -gt 0 -or -not $bunnyVisible)
                if ($idlePose -cne $script:UiIdlePoseOverride) {
                    $script:UiIdlePoseOverride=$idlePose
                    $dirty=$true
                }
            }
            if (Update-MioSparseCrt $script:UiEffectClock.Elapsed.TotalMilliseconds ($text.Length -gt 0) $bunnyVisible) {$dirty=$true}
            $caretChanged=((Get-InputCaretVisible) -ne $script:UiCaretDrawn)
            if ($dirty -or $caretChanged -or ($script:UiLive -and $watch.ElapsedMilliseconds -ge 33)) {
                $watch.Restart()
                Draw-MenuPanel $Title $rows $Prompt $text $caret $Mood
                $dirty=$false
            }
            if ([Console]::KeyAvailable) {
                $key=[Console]::ReadKey($true)
                if ($sparseIdle) {
                    $idleWatch.Restart(); Reset-MioIdleInput
                    $script:UiIdlePoseOverride='idle'
                }
                if ($key.Key -eq [ConsoleKey]::Enter) {return $text.Trim()}
                if ($key.Key -eq [ConsoleKey]::Escape) {return 'B'}
                if ($key.Key -eq [ConsoleKey]::Backspace -and $caret -gt 0) {$text=$text.Remove($caret-1,1); $caret--}
                elseif ($key.Key -eq [ConsoleKey]::Delete -and $caret -lt $text.Length) {$text=$text.Remove($caret,1)}
                elseif ($key.Key -eq [ConsoleKey]::LeftArrow) {$caret=[Math]::Max(0,$caret-1)}
                elseif ($key.Key -eq [ConsoleKey]::RightArrow) {$caret=[Math]::Min($text.Length,$caret+1)}
                elseif ($key.Key -eq [ConsoleKey]::Home) {$caret=0}
                elseif ($key.Key -eq [ConsoleKey]::End) {$caret=$text.Length}
                elseif ($key.Key -eq [ConsoleKey]::U -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {$text='';$caret=0}
                elseif (-not [char]::IsControl($key.KeyChar) -and $text.Length -lt 4096) {$text=$text.Insert($caret,[string]$key.KeyChar);$caret++}
                Update-InputCaret $text $caret
                $dirty=$true
            } else {
                $wait=30
                if ($script:UiLive) {$wait=[int][Math]::Min(8,33-$watch.ElapsedMilliseconds)}
                Wait-DisplayFrame $wait
            }
        }
    } finally {$script:UiIdlePoseOverride=$null; Reset-MioSparseCrt; $idleWatch.Stop(); Clear-DisplayPanel}
}

function Show-ConversionStart([string]$System) {
    $script:UiSystem=$System; $script:UiGame='Preparing the input batch'
    Show-PreparationProgress 'Scanning SRC' 'Reading source files and preparing the queue.' 0 -1 'files' -Force
}

function Show-PreparationProgress([string]$Stage,[string]$Detail,[long]$Completed=0,[long]$Total=-1,[string]$Unit='items',[switch]$Force) {
    # A discovered-file count is not a percentage until the total is known.
    # Refresh at most ~7 times/second, except stage boundaries and completion.
    $changed=(-not $script:UiPreparing -or $script:UiLastStage -ne $Stage)
    $finished=($Total -ge 0 -and $Completed -ge $Total)
    $wasFinished=(-not $changed -and $script:UiPreparing -and $script:UiPreparationTotal -eq $Total -and $script:UiPreparationCompleted -ge $Total)
    if (-not $Force -and -not $changed -and -not ($finished -and -not $wasFinished) -and $script:UiPreparationWatch.ElapsedMilliseconds -lt 150) {return}
    $script:UiPreparationWatch.Restart()
    $script:UiPreparing=$true; $script:UiPreparationCompleted=[Math]::Max(0,$Completed)
    $script:UiPreparationTotal=$Total; $script:UiPreparationUnit=$Unit
    $script:UiGame='Preparing the input batch'; $script:UiStage=$Stage; $script:UiDetail=$Detail
    $script:UiPercent=-1
    if ($Total -ge 0) {
        $script:UiPercent=100
        if ($Total -gt 0) {$script:UiPercent=[Math]::Max(0,[Math]::Min(100,100.0*$Completed/$Total))}
    }
    $script:UiMood='scan'; $script:UiSay='Preparing the queue before processing begins.'
    if ($Stage -match 'Check|Verif|Hash') {$script:UiMood='check'; $script:UiSay='Checking game groups, source files and output paths.'}
    $status=('{0:N0} {1} found' -f $Completed,$Unit)
    if ($Total -ge 0) {$status=('{0:N0} / {1:N0} {2} checked' -f $Completed,$Total,$Unit)}
    if ($changed) {$script:UiLastStage=$Stage; Write-Event 'STAGE' ($Stage+' / '+$status+' / '+$Detail)}
    if (-not $script:UiVT -and $script:UiInteractive) {
        Write-Progress -Id 2 -Activity $Stage -Status ($status+' / '+$Detail) -PercentComplete ([int]$script:UiPercent)
    }
    if (-not $script:UiVT -and $finished -and -not $wasFinished) {Write-Log ('PREPARED: '+$Stage+' / '+$status)}
    Draw-DisplayPanel -Force:($Force -or $changed -or ($finished -and -not $wasFinished))
}
function Complete-PreparationProgress {
    if ($script:UiPreparing) {
        $script:UiPreparing=$false
        if ($script:UiInteractive -and -not $script:UiVT) {Write-Progress -Id 2 -Activity 'Preparing batch' -Completed}
    }
}

function Draw-DisplayPanel([switch]$Force,[switch]$RefreshMio) {
    if (-not $script:UiVT) {return}
    if (Update-DisplaySize) {$Force=$true}
    if (-not $Force -and $script:UiWatch.ElapsedMilliseconds -lt 95) {return}
    $script:UiWatch.Restart()
    if (-not $script:UiPanel) {
        Draw-ResizePanel $script:UiStage $script:UiDetail
        return
    }
    $w=$script:UiWidth; $left=$w-28; $inner=$w-4
    $border=Get-BorderMotion $w 17
    $mio=@(Get-TimedMioFrame $script:UiMood $script:UiPoseOverride -Refresh:$RefreshMio)
    $count=[Math]::Min($script:Total,$script:Processed+1)
    $clock='00:00:00'; if ($script:Clock) {$clock=Format-Duration $script:Clock.Elapsed.TotalSeconds}
    $pct='working'; if ($script:UiPercent -ge 0) {$pct=('{0,3:N0}%' -f $script:UiPercent)}
    $barPrefix=''; if ($script:UiDemo) {$barPrefix='Stage '}
    $barWidth=$left-13-$barPrefix.Length
    $barTick=$script:UiTick
    if ($script:UiDemo) {$barTick=$script:UiDemoProgressTick}
    $bar=$barPrefix+(Get-ProgressBar $script:UiPercent $barWidth $barTick)+' '+$pct
    $queuePercent=[Math]::Max(0,[Math]::Min(100,100.0*$script:Processed/[Math]::Max(1,$script:Total)))
    $queue=('Queue {0}/{1} complete' -f $script:Processed,$script:Total)
    # Overall work uses completed sets, independently of the current stage.
    # Reuse the spare body row so the panel keeps its existing minimum size.
    $showQueueBar=(-not $script:UiPreparing -and $script:Total -gt 0)
    if ($script:UiDemo) {
        $tour=Get-MioPreviewTourProgress
        $queuePercent=$tour.Percent; $queue=$tour.Caption
        $showQueueBar=($tour.Count -gt 0)
    }
    $queuePct=('{0,3:N0}%' -f $queuePercent); $queueBar=''; $queueBarWidth=$left-19
    if ($showQueueBar) {$queueBar='Total '+(Get-ProgressBar $queuePercent $queueBarWidth $barTick)+' '+$queuePct}
    $setLine=('SET '+$count+' / '+$script:Total+'  '+$script:UiGame)
    if ($script:Total -eq 0 -and $script:UiStage -ne 'Finished') {$queue='Queue: scanning source files'; $setLine=$script:UiGame}
    $eta='ETA: pending first completed set'
    if ($script:Processed -ge 1 -and $script:Clock -and $script:Total -gt $script:Processed) {
        $eta='ETA ~'+(Format-Duration ($script:Clock.Elapsed.TotalSeconds/$script:Processed*($script:Total-$script:Processed)))+' (by completed sets)'
    }
    if ($script:UiPreparing) {
        $setLine='PREPARING INPUT BATCH'
        if ($script:UiPreparationTotal -ge 0) {
            $queue=('{0:N0} / {1:N0} {2} checked' -f $script:UiPreparationCompleted,$script:UiPreparationTotal,$script:UiPreparationUnit)
        } else {$queue=('{0:N0} {1} found / scanning' -f $script:UiPreparationCompleted,$script:UiPreparationUnit)}
        $eta='Conversion starts after these checks'
    }
    if ($script:UiDemo) {
        $queue=$tour.Caption
        $setLine='Example: '+$script:UiGame
        $eta='SIMULATION / no files are accessed'
    }
    $resultsLine=('Ready '+$script:Ok+'   Skipped '+$script:Skipped+'   Failed '+$script:Failed)
    if ($script:UiDemo) {$resultsLine='Sample: '+$resultsLine}
    $data=@(
        ('DISK VIEWER // '+$script:UiSystem),
        $setLine,
        '',
        $script:UiStage,
        $script:UiDetail,
        $bar,
        $queue,
        $queueBar,
        $resultsLine,
        'Source: SRC / Output: DST',
        ('Elapsed '+$clock),
        $eta
    )
    $lines=[System.Collections.Generic.List[string]]::new()
    $lines.Add('  '+(Format-BorderText (('+-- OptiMiyoo // LOCAL DISK LINK ').PadRight($w-1,'-')+'+') 0 0 $border))
    $lines.Add('  '+(Format-BorderText '|' 0 1 $border)+' '+(Color-Text (Fit-Text 'MEDIA CHANNEL // 140.85' $left) '107;216;245')+(Color-Text ' | ' '91;104;151')+(Color-Text (Fit-Text '    MIO // ONLINE' 22) '249;172;204')+(Format-BorderText '|' ($w-1) 1 $border))
    for ($i=0;$i -lt 12;$i++) {
        $right=$mio[$i]
        $content=Fit-Text $data[$i] $left
        if ($i -eq 5) {
            if ($script:UiDemo -and $script:UiDemoProgressStatus) {$content=Color-Text (Fit-Text ('Status: '+$script:UiDemoProgressStatus) $left) '218;224;244'}
            else {$content=$bar+(' '*[Math]::Max(0,$left-($barPrefix.Length+$barWidth+2+1+$pct.Length)))}
        }
        elseif ($i -eq 7 -and $showQueueBar) {$content=$queueBar+(' '*[Math]::Max(0,$left-(6+$queueBarWidth+2+1+$queuePct.Length)))}
        else {$content=Color-Text $content $(if ($i -eq 0) {'107;216;245'} elseif ($i -eq 3) {'249;172;204'} else {'218;224;244'})}
        $lines.Add('  '+(Format-BorderText '|' 0 ($i+2) $border)+' '+$content+(Color-Text ' | ' '91;104;151')+$right+(Format-BorderText '|' ($w-1) ($i+2) $border))
    }
    $lines.Add('  '+(Format-BorderText '+' 0 14 $border)+(Format-HighlightStripe ('-'*($w-2)) $true)+(Format-BorderText '+' ($w-1) 14 $border))
    $lines.Add('  '+(Format-BorderText '|' 0 15 $border)+' '+(Color-Text (Fit-Text ('MIO > '+$script:UiSay) $inner) '249;202;226')+' '+(Format-BorderText '|' ($w-1) 15 $border))
    $lines.Add('  '+(Format-BorderText ('+'+('-'*($w-2))+'+') 0 16 $border $true))
    try {[Console]::CursorVisible=$false} catch {}
    Write-TerminalPanel $lines.ToArray()
}
function Show-Stage([double]$Fraction,[string]$Stage,[string]$Detail,[double]$MeasuredPercent=-1) {
    Complete-PreparationProgress
    # Fraction is retained for the converter API, never presented as measured work.
    $script:UiStage=$Stage; $script:UiDetail=$Detail; $script:UiPercent=$MeasuredPercent
    $script:UiMood='work'; $script:UiSay='Processing the current disk set.'
    if ($Stage -match 'Hash|Verif|Check') {$script:UiMood='check'; $script:UiSay='Verifying output integrity before installation.'}
    elseif ($Stage -match 'Scan|Prepar|Read') {$script:UiMood='scan'; $script:UiSay='Reading disk images and checking set order.'}
    elseif ($Stage -match 'HxC|IPF.*DSK') {$script:UiSay='Converting IPF data to DSK.'}
    elseif ($Stage -match 'Convert') {$script:UiSay='Converting NIB data to G64.'}
    elseif ($Stage -match 'Playlist|Install') {$script:UiSay='Installing the playlist and disk images.'}
    $changed=($script:UiLastStage -ne $Stage)
    if ($changed) {
        $script:UiLastStage=$Stage
        Write-Event 'STAGE' ($Stage+' / '+$Detail)
    }
    # Fast batches may change stage many times in one frame. Keep the panel
    # present and coalesce these updates at the regular refresh rate.
    Draw-DisplayPanel
}
function Show-SourceCleanupProgress([string]$Stage,[string]$Detail,[long]$CompletedBytes=0,[long]$TotalBytes=0) {
    Complete-PreparationProgress
    # Cleanup can reread large installed sets. Keep it visibly separate from
    # conversion, and show a percentage only when the callback measures bytes.
    $script:UiSystem='SOURCE CLEANUP'; $script:UiGame='Verifying before original removal'
    $script:UiStage=$Stage; $script:UiDetail=$Detail; $script:UiPercent=-1
    if ($TotalBytes -gt 0) {
        $script:UiPercent=[Math]::Max(0,[Math]::Min(100,100.0*$CompletedBytes/$TotalBytes))
    }
    $script:UiMood='check'; $script:UiSay='Checking saved output and originals before removal.'
    $changed=($script:UiLastStage -ne $Stage)
    if ($changed) {
        $script:UiLastStage=$Stage
        Write-Event 'STAGE' ($Stage+' / '+$Detail)
    }
    Draw-DisplayPanel -Force:$changed
}
function Get-AnimatedPalette([string[]]$Colors) {
    if (-not $script:UiLive) {$script:UiBannerTimeMs=0}
    elseif (-not $script:UiDemoPaused) {$script:UiBannerTimeMs=$script:UiEffectClock.Elapsed.TotalMilliseconds}
    # The logo, title borders and separators share the same elapsed clock.
    # Every palette completes one smooth 8.1-second cycle, so the preview
    # loops cleanly. Forced redraws never speed up the color animation.
    $phase=($script:UiBannerTimeMs/8100.0*$colors.Count)%$colors.Count
    $step=[int][Math]::Floor($phase); $mix=$phase-$step
    for ($i=0;$i -lt $colors.Count;$i++) {
        $a=$colors[($i+$step)%$colors.Count].Split(';')
        $b=$colors[($i+$step+1)%$colors.Count].Split(';')
        $r=[int][Math]::Round([int]$a[0]*(1-$mix)+[int]$b[0]*$mix)
        $g=[int][Math]::Round([int]$a[1]*(1-$mix)+[int]$b[1]*$mix)
        $blue=[int][Math]::Round([int]$a[2]*(1-$mix)+[int]$b[2]*$mix)
        '{0};{1};{2}' -f $r,$g,$blue
    }
}
function Get-BannerPalette {
    $colors=@($script:Pride[0],$script:Pride[1],$script:Pride[2],$script:Pride[3],
              $script:Trans[0],$script:Trans[1],$script:Trans[2],$script:Trans[3],$script:Trans[4])
    Get-AnimatedPalette $colors
}
function Get-DisplayBanner([bool]$Full=$true) {
    if ($Full) {
        foreach ($line in @(Get-OptiLogoRows)) {'  '+$line}
        '  '+(Color-Text (Fit-Text ('OptiMiyoo v'+$script:AppVersion+' // Disk conversion and playlists') $script:UiWidth) '249;172;204')
        '  '+(Format-HighlightStripe ('='*$script:UiWidth))
    } else {
        $palette=@(Get-BannerPalette)
        '  '+(Color-Text (Fit-Text ('OPTIMIYOO v'+$script:AppVersion+' // DISK LINK') ([Math]::Max(1,[Math]::Min($script:UiWidth,$script:UiColumns-4)))) $palette[0])
    }
}
function Format-CrtLogoGlyph([string]$Glyph,[string]$Rgb,[int]$TopLevel=100,[int]$BottomLevel=84) {
    $upper=$Rgb
    if ($TopLevel -ne 100) {$upper=(@($Rgb.Split(';') | ForEach-Object {[int][Math]::Round([int]$_*$TopLevel/100.0)})) -join ';'}
    $lower=(@($Rgb.Split(';') | ForEach-Object {[int][Math]::Round([int]$_*$BottomLevel/100.0)})) -join ';'
    $top=$script:Esc+'[38;2;'+$upper+'m'
    $bottom=$script:Esc+'[38;2;'+$lower+'m'
    $both=$script:Esc+'[38;2;'+$upper+';48;2;'+$lower+'m'
    $reset=$script:Esc+'[0m'; $result=[Text.StringBuilder]::new()
    foreach ($pixel in $Glyph.ToCharArray()) {
        # Keep the same occupied pixel halves, including the bevels and gaps.
        if ($pixel -eq [char]0x2588) {[void]$result.Append($both+[char]0x2580+$reset)}
        elseif ($pixel -eq [char]0x2580) {[void]$result.Append($top+$pixel+$reset)}
        elseif ($pixel -eq [char]0x2584) {[void]$result.Append($bottom+$pixel+$reset)}
        else {[void]$result.Append($pixel)}
    }
    return $result.ToString()
}
function Get-OptiLogoRows {
    # Solid terminal blocks, beveled caps and a small forward rake. The five
    # rows retain the original banner height and fit an 80-column console.
    if (-not $script:OptiLogoFont) {$script:OptiLogoFont=@{
        'O'=@('▄████▄','██  ██','██  ██','██  ██','▀████▀')
        'P'=@('█████▄','██  ██','█████▀','██    ','██    ')
        'T'=@('██████','  ██  ','  ██  ','  ██  ','  ██  ')
        'I'=@('████',' ██ ',' ██ ',' ██ ','████')
        'M'=@('██   ██','███ ███','███████','██ ▀ ██','██   ██')
        'Y'=@('██  ██','▀████▀','  ██  ','  ██  ','  ██  ')
    }}
    $title='OPTIMIYOO'
    $colors=@(Get-BannerPalette)
    $crt=($script:UiAnsi -and $script:DisplayEffect -eq 'CRT')
    $cacheKey=$script:UiAnsi.ToString()+'|'+$crt+'|'+($colors -join '|')
    $motion=($crt -and -not $script:UiLive -and $script:MioSparseCrtMode -in 'Continuous','Synchronized' -and $script:UiSparseCrtPhase -ge 0 -and $script:MioSparseCrtGeometry.LogoRow -gt 0)
    $levels=$null
    if ($motion) {
        $cacheKey+='|'+$script:MioSparseCrtMode+'|'+$script:MioSparseCrtGeometry.Key+'|'+$script:MioSparseCrtContinuousFps+'|'+$script:MioSparseCrtContinuousCycleMs+'|'+$script:UiSparseCrtRegion+'|'+$script:MioSparseCrtLogoFrameCount+'|'+$script:MioSparseCrtBunnyFrameCount+'|'+$script:UiSparseCrtPhase
        if ($script:OptiLogoMotionCache.ContainsKey($cacheKey)) {return $script:OptiLogoMotionCache[$cacheKey]}
        $levels=(Get-MioContinuousCrtLevels $script:UiSparseCrtPhase).Logo
    } elseif (-not $script:UiLive -and $script:OptiLogoCache.ContainsKey($cacheKey)) {return $script:OptiLogoCache[$cacheKey]}
    $rows=[System.Collections.Generic.List[string]]::new()
    $rake=@(2,2,1,1,0)
    $prefix=$script:Esc+'[38;2;'; $reset=$script:Esc+'[0m'
    for ($row=0;$row -lt 5;$row++) {
        $topLevel=100; $bottomLevel=84
        if ($levels) {$topLevel=$levels[$row*2]; $bottomLevel=$levels[$row*2+1]}
        $rowKey=$row.ToString()+'|'+$script:UiAnsi+'|'+$crt+'|'+($colors -join '|')+'|'+$topLevel+'|'+$bottomLevel
        if (-not $script:UiLive -and $script:OptiLogoRowCache.ContainsKey($rowKey)) {$rows.Add($script:OptiLogoRowCache[$rowKey]);continue}
        $line=[Text.StringBuilder]::new()
        [void]$line.Append(' '*$rake[$row])
        for ($column=0;$column -lt $title.Length;$column++) {
            $rgb=$colors[$column]
            # Light on the upper bevel, deeper color along the lower edge.
            if ($row -eq 0 -or $row -eq 4) {
                $channels=$rgb.Split(';'); $gain=0.82; $offset=0.0
                if ($row -eq 0) {$gain=0.86; $offset=255*0.14}
                $r=[int][Math]::Round([int]$channels[0]*$gain+$offset)
                $g=[int][Math]::Round([int]$channels[1]*$gain+$offset)
                $b=[int][Math]::Round([int]$channels[2]*$gain+$offset)
                $rgb=('{0};{1};{2}' -f $r,$g,$b)
            }
            if ($column -gt 0) {[void]$line.Append(' ')}
            if ($column -eq 4) {[void]$line.Append(' ')}
            $glyph=$script:OptiLogoFont[[string]$title[$column]][$row]
            if ($crt) {[void]$line.Append((Format-CrtLogoGlyph $glyph $rgb $topLevel $bottomLevel))}
            elseif ($script:UiAnsi) {[void]$line.Append($prefix+$rgb+'m'+$glyph+$reset)}
            else {[void]$line.Append($glyph)}
        }
        $renderedRow=$line.ToString(); $rows.Add($renderedRow)
        if (-not $script:UiLive) {
            if ($script:OptiLogoRowCache.Count -ge 256) {$script:OptiLogoRowCache.Remove($script:OptiLogoRowOrder.Dequeue())}
            $script:OptiLogoRowCache[$rowKey]=$renderedRow; $script:OptiLogoRowOrder.Enqueue($rowKey)
        }
    }
    $rendered=$rows.ToArray()
    if ($motion) {
        if ($script:OptiLogoMotionCache.Count -ge 256) {$script:OptiLogoMotionCache.Remove($script:OptiLogoMotionOrder.Dequeue())}
        $script:OptiLogoMotionCache[$cacheKey]=$rendered; $script:OptiLogoMotionOrder.Enqueue($cacheKey)
    } elseif (-not $script:UiLive) {$script:OptiLogoCache[$cacheKey]=$rendered}
    return $rendered
}
function Show-Header {
    Initialize-Display
    if ($script:UiVT) {
        if ($script:UiColumns -ge 20 -and $script:UiHeight -ge 6) {Write-TerminalPanel @()}
        return
    }
    Write-Host ''
    Write-RetroStripe
    foreach ($line in @(Get-OptiLogoRows)) {
        Write-Host ('     '+$line)
    }
    Write-Host ('     '+(Color-Text ('OptiMiyoo v'+$script:AppVersion+' // Disk conversion and playlist management') '249;172;204'))
    Write-Host ('     '+(Color-Text 'LOCAL DISK LINK  /  PLAYLISTS + C64 + ZX' '107;216;245'))
    Write-RetroStripe
    $boot=@('Interface online.','Mio status display initialized.','Default source policy: preserve originals.','System profiles loaded.')
    foreach ($line in $boot) {
        if ($script:UiLive) {
            Write-Host ('  '+(Color-Text ':: ' '107;216;245')) -NoNewline
            foreach ($letter in $line.ToCharArray()) {Write-Host ([string]$letter) -NoNewline; Start-Sleep -Milliseconds 7}
            Write-Host ''
        } else {Write-Host ('  :: '+$line)}
    }
    Write-Host ''
}
function Get-MioPreviewTourProgress {
    $count=[Math]::Max(0,[int]$script:UiDemoCount)
    $scene=[Math]::Max(0,[Math]::Min($count,[int]$script:UiDemoScene))
    return [pscustomobject]@{Scene=$scene;Count=$count;Percent=(100.0*$scene/[Math]::Max(1,$count));Caption=('Demo {0}/{1}' -f $scene,$count)}
}
function Get-MioPreviewTourBar([int]$Width) {
    $tour=Get-MioPreviewTourProgress
    $suffix=(' {0,3:N0}%  {1}' -f $tour.Percent,$tour.Caption)
    $barWidth=[Math]::Max(1,$Width-8-$suffix.Length)
    return ('Total '+(Get-ProgressBar $tour.Percent $barWidth 0)+$suffix)
}
function Get-MioPreviewScenes([string]$Section='Tour') {
    # Entirely synthetic data: never call workers, file scanners or log writers.
    $scenes=@(
        @{Group='Tour';Mood='idle';Stage='Main menu';System='MENU';Menu=@('DEMO / no file changes','1. Amiga playlists','3. PlayStation playlists','C. Commodore 64 / NIB -> G64','Z. ZX Spectrum / IPF -> DSK','S. Onion SD setup / preserve cores','D. Demo / walkthrough');Detail='Animated menus and shared status display.'},
        @{Group='Tour';Mood='scan';Stage='Scanning the collection';System='INPUT';Game='Demo collection';Detail='Finding disk sets, companion files and existing outputs.'},
        @{Group='Setup';Mood='idle';Stage='Default core support';System='MENU';Menu=@('DEMO / default Onion cores','Playlists: AMIGA, COMMODORE, PS, SEGACD,','MSX, VIC20 and DOS.','CPC, PCECD and ZXS: playlist unsupported.','ZX IPF-to-DSK conversion remains available.','Selected cores are always preserved.');Detail='Playlist support follows the selected emulator core.'},
        @{Group='Setup';Mood='scan';Stage='Checking an Onion SD card';System='SD SETUP';Game='Example SD / S menu';Detail='Read launcher and core support. Keep selected cores.'},
        @{Group='Setup';Mood='check';Stage='Playlist visibility setup';System='SD SETUP';Game='Example Emu/PSX/config.json';Detail='Back up config; add needed playlist extensions only.'},
        @{Group='C64';Mood='idle';Stage='Commodore 64 settings';System='MENU';Menu=@('DEMO / no file changes','1. ZIP output / keep originals','2. ZIP output / remove after verification','3. Folder output / keep originals','4. Folder output / remove after verification','B. Back to main menu');Detail='All converter menus include the same bunny.'},
        @{Group='C64';Mood='scan';Stage='Reading NIB and NBZ images';System='COMMODORE 64';Game='Demo disk set.zip';Detail='2 disk sides found. G64 files need no conversion.'},
        @{Group='C64';Mood='work';Stage='Converting NIB to G64';System='COMMODORE 64';Game='Demo disk set / Side A.nib';Detail='Simulated nibconv track activity';Progress=$true;Tracks=$true},
        @{Group='C64';Mood='check';Stage='Preserving an existing G64';System='COMMODORE 64';Game='Demo disk set / Side B.g64';Detail='Existing G64 bytes are copied and verified.';Progress=$true},
        @{Group='C64';Mood='check';Stage='Verifying the converted images';System='COMMODORE 64';Game='Demo disk set';Detail='G64 structure, image hashes and ZIP contents.';Progress=$true;CompleteSet=$true},
        @{Group='ZX';Mood='idle';Stage='ZX Spectrum settings';System='MENU';Menu=@('DEMO / no file changes','1. Loose DSK output','2. One ZIP per DSK','Next: Keep / Remove verified originals.','B. Back to main menu');Detail='Conversion is separate from playlist support.'},
        @{Group='ZX';Mood='scan';Stage='Reading an IPF image';System='ZX SPECTRUM';Game='Demo Spectrum / Disk 1.ipf';Detail='HxC and CAPSIMG decode the preservation image.'},
        @{Group='ZX';Mood='work';Stage='Converting IPF to DSK';System='ZX SPECTRUM';Game='Demo Spectrum / Disk 1.ipf';Detail='Engine activity is shown without a guessed percentage.'},
        @{Group='ZX';Mood='check';Stage='Verifying DSK and ZIP output';System='ZX SPECTRUM';Game='Demo Spectrum / Disk 1.zip';Detail='Check DSK structure, archive contents and source policy.';Progress=$true;CompleteSet=$true},
        @{Group='Playlists';Mood='scan';Stage='Amiga IPF and ADF disk sets';System='AMIGA';Game='Demo Amiga / Disk 1.ipf';Detail='Keep IPF/ADF images; Auto can keep supported ZIPs.'},
        @{Group='Playlists';Mood='scan';Stage='PlayStation multi-disc sets';System='PLAYSTATION';Game='Demo PlayStation / Disc 1.chd';Detail='Keep CHD files. CUE sets retain referenced tracks.'},
        @{Group='Playlists';Mood='idle';Stage='Other supported playlist systems';System='MENU';Menu=@('DEMO / supported default cores','Sega CD / Mega-CD: disc sets','MSX / MSX2: floppy disk sets','VIC-20: floppy disk sets','MS-DOS: DOSBox Pure M3U8 disk sets','Choose one system for the shared SRC folder.');Detail='Use the system profile that matches your input set.'},
        @{Group='Playlists';Mood='scan';Stage='Ordering multiple disks';System='PLAYLISTS';Game='Demo Adventure';Detail='Natural disk order: Disk 1, Disk 2, Disk 10.'},
        @{Group='Playlists';Mood='work';Stage='Preparing hidden media';System='PLAYLISTS';Game='Demo Adventure';Detail='DST/.hidden/Demo Adventure / disk images';Progress=$true},
        @{Group='Playlists';Mood='check';Stage='Writing and verifying the playlist';System='PLAYLISTS';Game='Demo Adventure.m3u';Detail='Relative paths point to .hidden. Companion files stay.';Progress=$true;CompleteSet=$true},
        @{Group='Results';Mood='wait';Stage='Waiting for an overwrite choice';System='EXISTING OUTPUT';Game='Demo Adventure.m3u';Detail='Y: overwrite / N: skip / A: yes to all / S: no to all';Status='Waiting for your choice';Total=0},
        @{Group='Results';Mood='wait';Stage='Skipped: overwrite declined';System='RESULT';Game='Demo Adventure.m3u';Detail='Existing output and original source are both kept.';Skipped=1;Status='Skipped / originals kept'},
        @{Group='Results';Mood='oops';Stage='Failed: a CUE track is missing';System='RESULT';Game='Demo Disc 2.cue';Detail='No incomplete playlist is installed. Source is kept.';Failed=1;Status='Stopped / source kept'},
        @{Group='Results';Mood='check';Stage='Retrying a corrected disk set';System='RESULT';Game='Demo Disc 2.cue';Detail='Simulated retry: validate tracks and verify outputs.';Progress=$true;CompleteSet=$true},
        @{Group='Results';Mood='happy';Stage='Batch complete';System='SUMMARY';Game='Demo collection';Detail='Review outputs, originals removed/kept and failures.';Progress=$true;Complete=$true;Ok=3;Skipped=1},
        @{Group='Results';Mood='wait';Stage='No matching inputs';System='EMPTY BATCH';Game='Demo empty SRC';Detail='Return to settings, add inputs and run the batch again.';Status='No matching inputs';Total=0}
    )
    foreach ($pose in 'idle','blink','scanleft','scanright','work','check','happy','happyturn','oops','wait') {
        $scenes+=@{Group='Bunny';Mood='idle';Pose=$pose;Stage=('Bunny animation / '+$pose);System='ANIMATION GALLERY';Game='Mio';Detail='The same pixel bunny is used in menus and converters.';Status='Bunny preview';Total=0}
    }
    # Preview gestures on their own scene clock; normal menus retain 12-second gaps.
    [void](Get-MioFrame 'idle' 0)
    foreach ($gesture in $script:MioIdleGestures) {
        $scenes+=@{Group='Bunny';Mood='idle';IdleGesture=$gesture;Stage=('Idle gesture / '+$gesture.Name);System='ANIMATION GALLERY';Game='Mio';Detail='A brief gesture, then back to rest. Menus wait 12 seconds.';Status='Idle animation preview';Total=0;Duration=2200}
    }
    if ($Section -ne 'Tour') {$scenes=@($scenes | Where-Object {$_.Group -eq $Section})}
    return $scenes
}
function Set-MioPreviewProgress([hashtable]$Scene,[double]$ElapsedMilliseconds,[double]$Duration) {
    # Progress has its own scene clock: low-CPU mode freezes decorative effects,
    # not the demonstration of ongoing work. A stopped scene clock also pauses it.
    $elapsed=[Math]::Max(0.0,$ElapsedMilliseconds)
    $fraction=[Math]::Min(1.0,$elapsed/[Math]::Max(1.0,$Duration-400))
    $script:UiDemoProgressTick=4+[int][Math]::Floor($elapsed/120.0)
    $script:UiDemoProgressStatus=[string]$Scene.Status
    $script:UiPercent=-1
    $script:UiDetail=$Scene.Detail; $script:UiGame=$Scene.Game
    if ($Scene.IdleGesture) {
        $script:UiPoseOverride='idle'
        if ($script:UiLive -or $IdleAnimations) {$script:UiPoseOverride=Get-MioIdleGesturePose $Scene.IdleGesture ($elapsed-400)}
    }
    $script:Total=4
    if ($Scene.ContainsKey('Total')) {$script:Total=[int]$Scene.Total}
    foreach ($name in 'Ok','Skipped','Failed') {Set-Variable -Scope Script -Name $name -Value ([int]$Scene[$name])}
    if ($Scene.Progress) {$script:UiPercent=100*$fraction}
    if ($Scene.Complete) {$script:UiPercent=100}
    elseif ($Scene.CompleteSet -and $fraction -ge 1) {$script:Ok++}
    $script:Processed=$script:Ok+$script:Skipped+$script:Failed
    if ($Scene.Tracks) {
        $script:UiDetail=('Simulated track {0}/84 / no converter is running' -f [Math]::Min(84,[int](84*$elapsed/[Math]::Max(1,$Duration))))
    }
}
function Show-MioPreview([string]$Section='Tour') {
    $scenes=@(Get-MioPreviewScenes $Section)
    $saved=@{}
    foreach ($name in 'Total','Processed','Ok','Skipped','Failed','Clock','UiSystem','UiGame','UiStage','UiDetail','UiPercent','UiMood','UiSay','UiTick','UiMioMood','UiMioPoseOverride','UiLastStage','UiPoseOverride','UiDemo','UiDemoPaused','UiDemoScene','UiDemoCount','UiDemoProgressTick','UiDemoProgressStatus') {
        $value=Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue
        $saved[$name]=$null; if ($value) {$saved[$name]=$value.Value}
    }
    try {
        Clear-DisplayPanel
        $script:UiDemo=$true; $script:UiDemoCount=$scenes.Count
        $animateDemo=$script:UiVT
        $script:Clock=[Diagnostics.Stopwatch]::StartNew()
        $index=0; $paused=$false
        while ($index -ge 0 -and $index -lt $scenes.Count) {
            $scene=$scenes[$index]; $script:UiDemoScene=$index+1
            $script:UiSystem='DEMO / '+$scene.System; $script:UiGame=$scene.Game
            $script:UiStage=$scene.Stage; $script:UiDetail=$scene.Detail
            $script:UiMood=$scene.Mood; $script:UiPoseOverride=$scene.Pose; $script:UiPercent=-1
            if (-not $animateDemo) {
                Write-Host ('  [DEMO {0}/{1}] {2} / {3}' -f ($index+1),$scenes.Count,$scene.System,$scene.Stage)
                Write-Host ('  '+$scene.Detail)
                $index++; continue
            }
            $timer=[Diagnostics.Stopwatch]::StartNew(); if ($paused) {$timer.Stop()}
            $duration=3500; if ($scene.Group -eq 'Bunny') {$duration=1800}
            if ($scene.Duration) {$duration=[int]$scene.Duration}
            $next=$index+1; $dirty=$true; $refreshMio=$true; $draw=[Diagnostics.Stopwatch]::StartNew()
            while ($true) {
                if (Update-DisplaySize -Throttled) {$dirty=$true; $refreshMio=$true}
                $script:UiDemoPaused=$paused
                $script:UiSay=('DEMO {0}/{1} | Space pause | N/P | R replay | F {2} | B back' -f $script:UiDemoScene,$script:UiDemoCount,$script:DisplayEffect)
                if ($paused) {$script:UiSay=('DEMO {0}/{1} PAUSED | Space resume | N/P | F {2} | B back' -f $script:UiDemoScene,$script:UiDemoCount,$script:DisplayEffect)}
                $frameInterval=250; $periodic=$true
                if ($script:UiLive) {$frameInterval=33}
                elseif ($scene.Menu) {$periodic=$false}
                elseif ($scene.Status -or $scene.Complete) {$frameInterval=1000}
                if ($scene.IdleGesture) {
                    $periodic=$false
                    if ($script:UiLive -or $IdleAnimations) {
                        $pose=Get-MioIdleGesturePose $scene.IdleGesture ($timer.ElapsedMilliseconds-400)
                        if ($pose -cne $script:UiPoseOverride) {$dirty=$true; $refreshMio=$true}
                    }
                }
                if ($dirty -or ($periodic -and -not $paused -and $draw.ElapsedMilliseconds -ge $frameInterval)) {
                    $draw.Restart()
                    Set-MioPreviewProgress $scene $timer.ElapsedMilliseconds $duration
                    if ($scene.Menu) {
                        $rows=@(Get-MenuRows $scene.Menu ([Math]::Max(44,$script:UiWidth-28)))
                        Draw-MenuPanel ('DEMO / '+$scene.Stage) $rows $script:UiSay 'Preview only / no selection is applied' 0 $scene.Mood -RefreshMio:$refreshMio
                    } else {Draw-DisplayPanel -Force -RefreshMio:$refreshMio}
                    $dirty=$false; $refreshMio=$false
                }
                if (-not $paused -and $timer.ElapsedMilliseconds -ge $duration) {break}
                if ([Console]::KeyAvailable) {
                    $key=[Console]::ReadKey($true)
                    if ($key.Key -in [ConsoleKey]::B,[ConsoleKey]::Q,[ConsoleKey]::Escape) {return}
                    if ($key.Key -eq [ConsoleKey]::Spacebar) {
                        $paused=-not $paused
                        if ($paused) {$timer.Stop()} else {$timer.Start()}
                        $script:UiDemoPaused=$paused; Sync-TerminalDisplayEffect; $dirty=$true
                    }
                    elseif ($key.Key -in [ConsoleKey]::N,[ConsoleKey]::RightArrow,[ConsoleKey]::Enter) {break}
                    elseif ($key.Key -in [ConsoleKey]::P,[ConsoleKey]::LeftArrow) {$next=[Math]::Max(0,$index-1); break}
                    elseif ($key.Key -eq [ConsoleKey]::R) {$next=0; break}
                    elseif ($key.Key -eq [ConsoleKey]::F) {Switch-DisplayEffect; $dirty=$true}
                } else {
                    $wait=30
                    if ($script:UiLive -and $periodic -and -not $paused) {$wait=[int][Math]::Max(1,[Math]::Min(8,$frameInterval-$draw.ElapsedMilliseconds))}
                    Wait-DisplayFrame $wait
                }
            }
            Clear-DisplayPanel; $index=$next
        }
    } finally {
        Clear-DisplayPanel
        foreach ($name in $saved.Keys) {Set-Variable -Scope Script -Name $name -Value $saved[$name]}
        Sync-TerminalDisplayEffect
        $script:UiMioWatch.Restart()
    }
}

function Show-ClosingPanel([int]$RemovalFailures=0) {
    Complete-PreparationProgress
    $script:UiSystem='SESSION COMPLETE'; $script:UiGame='All queued sets have been handled'
    $script:UiStage='Finished'; $script:UiDetail='See the summary, log and CSV report below.'; $script:UiPercent=100
    $script:UiMood='happy'; $script:UiSay='Processing complete. Review the results below.'
    if ($script:Failed -gt 0) {$script:UiMood='oops'; $script:UiSay='Processing completed with errors. Review the report.'}
    elseif ($RemovalFailures -gt 0) {$script:UiMood='oops'; $script:UiSay='Source cleanup needs attention. Review kept originals and log.'}
    elseif ($script:ReportProblem) {$script:UiMood='oops'; $script:UiSay='A log or report could not be saved. Review the warnings.'}
    elseif ($script:Ok -eq 0) {$script:UiMood='wait'; $script:UiSay='No new outputs were created. Source files are preserved.'}
    Draw-DisplayPanel -Force -RefreshMio
    # Leave the last panel visible above the summary instead of erasing it.
    $script:UiRows=0
}
