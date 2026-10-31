. (Join-Path $PSScriptRoot '../shared/compile_support.ps1')
# OptiMiyoo's display is deliberately separate from file processing.
. (Join-Path $PSScriptRoot '../shared/output_safety.ps1')
. (Join-Path $PSScriptRoot 'mio_idle_library.ps1')
. (Join-Path $PSScriptRoot 'mio_idle_scheduler.ps1')
. (Join-Path $PSScriptRoot 'menu_models.ps1')
. (Join-Path $PSScriptRoot '../shared/overwrite_prompt.ps1')
# Percentages use completed preparation items, completed jobs or measured bytes.
function Initialize-Display {
    if ($null -eq $script:UiRestoreState) {$script:UiRestoreState=@{}}
    $restore=$script:UiRestoreState
    if ($script:UiPinned) {$restore.Pinned=$true}
    if ($script:UiFrameTimer) {try {$script:UiFrameTimer.Dispose()} catch {}}
    $script:UiFrameTimer=$null
    $script:Esc=[string][char]27
    $script:UiRows=0; $script:UiTick=0; $script:UiLastStage=''
    $script:UiIdlePoseOverride=$null
    $script:UiIdleMenuCache=$null
    $script:UiMenuLayoutCache=$null
    $script:MioSparseCrtFps=12.0
    $script:MioSparseCrtLogoFrameCount=10
    $script:MioSparseCrtBunnyFrameCount=24
    $script:MioSparseCrtBunnyDelayMs=6000.0
    $script:MioSparseCrtGeometry=$null
    $script:MioSparseCrtGeometryKey=''
    $script:MioSweepLevels=@{}
    $script:OptiLogoMotionCache=@{}
    $script:OptiLogoMotionOrder=[System.Collections.Generic.Queue[string]]::new()
    $script:OptiLogoRowCache=@{}
    $script:OptiLogoRowOrder=[System.Collections.Generic.Queue[string]]::new()
    $script:UiLastLogoRows=@(); $script:UiLastLogoRow=0
    Reset-MioSparseCrt
    Initialize-MioIdleScheduler
    $script:MioRenderCache=@{}
    $script:MioGrayColors=$null; $script:MioCrtPalettes=@{}
    $script:OptiLogoGrayPaletteKey=$null; $script:OptiLogoGrayPalette=$null
    $script:MioCrtRowCache=@{}
    $script:MioCrtRowOrder=[System.Collections.Generic.Queue[string]]::new()
    $script:MioSparseCrtFrames=@{}
    $script:MioSparseCrtFrameOrder=[System.Collections.Generic.Queue[string]]::new()
    $script:OptiLogoFont=$null; $script:OptiLogoCache=@{}
    $script:UiPendingEvents=[System.Collections.Generic.List[string]]::new()
    $script:UiEventRows=[System.Collections.Generic.List[string]]::new()
    $script:UiBannerRows=0; $script:UiPinned=$false
    $script:UiGame='Awaiting game files'; $script:UiSystem='LOCAL'
    $script:UiStage='Ready'; $script:UiDetail='Source files remain in SRC.'
    $script:UiPercent=-1; $script:UiMood='idle'
    $script:UiPreparing=$false; $script:UiPreparationCompleted=0; $script:UiPreparationTotal=-1
    $script:UiPreparationUnit='files'; $script:UiPreparationWatch=[Diagnostics.Stopwatch]::StartNew()
    $script:UiSay='Awaiting system selection.'
    $script:UiInteractive=$false; $script:UiAnsi=$false; $script:UiVT=$false
    $script:UiPanel=$false; $script:UiMenuActive=$false; $script:UiMenuLines=$null
    $script:UiOnionProgressStage=''; $script:UiOnionProgressFinished=$false
    $script:UiDemo=$false; $script:UiDemoPaused=$false; $script:UiPoseOverride=$null
    $script:UiDemoProgressTick=4; $script:UiDemoProgressStatus=''
    if ($script:DisplayEffect -notin 'CRT','Smooth') {$script:DisplayEffect='CRT'}
    $script:UiEffectClock=[Diagnostics.Stopwatch]::StartNew()
    $script:UiWatch=[Diagnostics.Stopwatch]::StartNew()
    $script:UiSizeWatch=[Diagnostics.Stopwatch]::StartNew()
    $script:Pride=@('255;115;154','255;181;115','255;225;132','144;225;173','110;202;255','194;160;255')
    $script:Trans=@('107;216;245','249;172;204','245;244;255','249;172;204','107;216;245')
    $script:UiWidth=78; $script:UiColumns=0; $script:UiHeight=0
    try {
        if (-not $restore.ContainsKey('Encoding')) {$restore.Encoding=[Console]::OutputEncoding}
        [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
        $script:UiInteractive=($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected)
        if ($script:UiInteractive) {
            $script:UiWidth=[Math]::Min(296,[Math]::Max(16,[Console]::WindowWidth-4))
            if (-not $restore.ContainsKey('Foreground')) {
                $restore.Cursor=$true
                try {$restore.Cursor=[Console]::CursorVisible} catch {}
                $restore.Foreground=$Host.UI.RawUI.ForegroundColor
                $restore.Background=$Host.UI.RawUI.BackgroundColor
            }
            $script:UiOldForeground=$restore.Foreground;$script:UiOldBackground=$restore.Background
            $Host.UI.RawUI.BackgroundColor='Black'
            $Host.UI.RawUI.ForegroundColor='White'
            try {
                if (-not $restore.ContainsKey('Title')) {$restore.Title=$Host.UI.RawUI.WindowTitle}
                $Host.UI.RawUI.WindowTitle='OptiMiyoo v'+$script:AppVersion+' // DISK LINK'
            } catch {}
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
        public static bool ReadMode(out uint mode) { return GetConsoleMode(GetStdHandle(-11),out mode); }
        public static bool RestoreMode(uint mode) { return SetConsoleMode(GetStdHandle(-11),mode); }
        public static bool Enable() {
            var h=GetStdHandle(-11); uint m;
            return GetConsoleMode(h,out m) && SetConsoleMode(h,m|4);
        }
    }
}
'@
                    }
                    if (-not $restore.ContainsKey('OutputMode')) {
                        [uint32]$mode=0
                        if ([OptiMiyoo.Terminal]::ReadMode([ref]$mode)) {$restore.OutputMode=$mode}
                    }
                    $script:UiVT=($restore.ContainsKey('OutputMode') -and [OptiMiyoo.Terminal]::Enable())
                } else {$script:UiVT=($env:TERM -ne 'dumb')}
            }
        }
    } catch {$script:UiVT=$false}
    $script:UiAnsi=($script:UiVT -and -not $NoColor)
    if ($script:UiVT) {
        $script:UiColumns=[Console]::WindowWidth; $script:UiHeight=[Console]::WindowHeight
    }
    $script:UiPanel=($script:UiVT -and $script:UiWidth -ge 72 -and $script:UiHeight -ge 20)
    # Menus use brief idle gestures and cached sweeps, never continuous redraws.
    Sync-DisplayPreference
    if ($script:UiVT) {Initialize-FrameTimer}
    if ($script:UiVT -and (Get-Variable PSStyle -ErrorAction SilentlyContinue)) {
        if (-not $restore.ContainsKey('Rendering')) {$restore.Rendering=$PSStyle.OutputRendering}
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
    $script:UiIdleMenuCache=$null
    $script:UiMenuLayoutCache=$null
    $script:UiWidth=[Math]::Min(296,[Math]::Max(16,$columns-4))
    $script:UiPanel=($script:UiWidth -ge 72 -and $height -ge 20)
    return $true
}

function Get-DisplayArtMode {
    if (-not $script:UiVT) {return 'Plain'}
    if ($script:UiAnsi) {return 'Color'}
    return 'Gray'
}
function ConvertTo-DisplayGray([string]$Rgb) {
    $channels=$Rgb.Split(';')
    $level=[int][Math]::Round(0.2126*[int]$channels[0]+0.7152*[int]$channels[1]+0.0722*[int]$channels[2])
    return ('{0};{0};{0}' -f $level)
}
function Color-Text([string]$Text,[string]$Rgb='218;224;244') {
    if ($script:UiAnsi) {return ($script:Esc+'[38;2;'+$Rgb+'m'+$Text+$script:Esc+'[0m')}
    return $Text
}
function Sync-DisplayPreference {
    if ((Get-Command Test-ApplicationWorker -ErrorAction SilentlyContinue) -and (Test-ApplicationWorker)) {
        $null=Invoke-ApplicationRpc -Operation Display.Preference -Payload @{Preference=[string]$script:DisplayEffect}
    }
}
function Switch-DisplayEffect {
    if ($script:DisplayEffect -eq 'CRT') {$script:DisplayEffect='Smooth'}
    else {$script:DisplayEffect='CRT'}
    Sync-DisplayPreference
}
function Rainbow-Text([string]$Text,[bool]$Soft=$false,[int]$Shift=0) {
    if (-not $script:UiAnsi) {return $Text}
    $palette=$script:Pride; if ($Soft) {$palette=$script:Trans}
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
function Get-BorderStyle([int]$Width,[int]$Height) {
    return [pscustomobject]@{Width=$Width;Height=$Height;Pride=$script:Pride;Trans=$script:Trans}
}
function Format-BorderText([string]$Text,[int]$X,[int]$Y,$Style,[bool]$Soft=$false) {
    if (-not $script:UiAnsi) {return $Text}
    $palette=$Style.Pride; if ($Soft) {$palette=$Style.Trans}
    $position=Get-BorderCellIndex $X $Y $Style.Width $Style.Height
    $direction=1; if ($Style.Height -gt 1 -and $Y -eq $Style.Height-1) {$direction=-1}
    $out=[Text.StringBuilder]::new()
    $prefix=$script:Esc+'[38;2;'; $reset=$script:Esc+'[0m'
    for ($i=0;$i -lt $Text.Length;$i++) {
        $at=$position+$i*$direction
        $rgb=$palette[([int][Math]::Floor($at/4))%$palette.Count]
        [void]$out.Append($prefix+$rgb+'m'+$Text[$i]+$reset)
    }
    return $out.ToString()
}
function Format-DisplayStripe([string]$Text,[bool]$Soft=$false) {
    if (-not $script:UiAnsi) {return $Text}
    return (Format-BorderText $Text 0 0 (Get-BorderStyle $Text.Length 1) $Soft)
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
function Get-InputCaretOffset([string]$Text,[int]$Caret,[int]$Direction) {
    $Caret=[Math]::Max(0,[Math]::Min($Text.Length,$Caret))
    if ($Text -notmatch '[^\x00-\x7F]') {
        return [Math]::Max(0,[Math]::Min($Text.Length,$Caret+[Math]::Sign($Direction)))
    }
    # Carets and deletions follow whole text elements, including surrogate pairs
    # and combining accents. This runs only on a key press, never an idle poll.
    $starts=[Globalization.StringInfo]::ParseCombiningCharacters($Text)
    $at=[Array]::BinarySearch($starts,$Caret)
    if ($Direction -gt 0) {
        if ($at -ge 0) {$at++} else {$at=-bnot $at}
        if ($at -ge $starts.Length) {return $Text.Length}
    } else {
        if ($at -ge 0) {$at--} else {$at=(-bnot $at)-1}
        if ($at -lt 0) {return 0}
    }
    return $starts[$at]
}
function Get-InputViewport([string]$Text,[int]$Caret,[int]$Width) {
    $Caret=[Math]::Max(0,[Math]::Min($Text.Length,$Caret))
    if ($Width -lt 1) {return [pscustomobject]@{Text='';Caret=0;CaretTextIndex=0}}
    if ($Text -notmatch '[^\x00-\x7F]') {
        $offset=[Math]::Max(0,$Caret-$Width+1)
        return [pscustomobject]@{
            Text=$Text.Substring($offset,[Math]::Min($Width,$Text.Length-$offset))
            Caret=$Caret-$offset;CaretTextIndex=$Caret-$offset
        }
    }
    $starts=[Globalization.StringInfo]::ParseCombiningCharacters($Text)
    $at=$starts.Length
    if ($Caret -lt $Text.Length) {
        $at=[Array]::BinarySearch($starts,$Caret)
        if ($at -lt 0) {$at=(-bnot $at)-1;$Caret=$starts[$at]}
    }
    # Work backward over visible elements once. A UTF-16 offset can otherwise
    # drop the base of an accent, even when the whole input fits on screen.
    $reserve=1
    if ($Caret -lt $Text.Length) {$reserve=[Math]::Max(1,(Get-TextElementWidth ([Globalization.StringInfo]::GetNextTextElement($Text,$Caret))))}
    $offset=$Caret;$cells=0
    for ($index=$at-1;$index -ge 0;$index--) {
        $end=$Text.Length;if ($index+1 -lt $starts.Length) {$end=$starts[$index+1]}
        $element=$Text.Substring($starts[$index],$end-$starts[$index])
        $widthOfElement=Get-TextElementWidth $element
        if ($cells+$widthOfElement -gt $Width-$reserve) {break}
        $cells+=$widthOfElement;$offset=$starts[$index]
    }
    return [pscustomobject]@{
        Text=Get-TextPrefix $Text.Substring($offset) $Width
        Caret=$cells;CaretTextIndex=$Caret-$offset
    }
}

function Format-InputField($Viewport,[int]$Width,[bool]$ShowCaret=$true) {
    $text=Fit-Text $Viewport.Text $Width
    $visible=($ShowCaret -and $script:UiVT)
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
function Restore-Display {
    $restore=$script:UiRestoreState
    if ($null -eq $restore) {return}
    $script:UiRestoreState=$null
    try {
        if ($script:UiFrameTimer) {try {$script:UiFrameTimer.Dispose()} catch {}}
        $script:UiFrameTimer=$null
        Complete-PreparationProgress
        Clear-DisplayPanel
    } finally {
        if ($script:UiPinned -or $restore.Pinned) {
            # Layout flags may have been reset by another Initialize-Display.
            try {[Console]::Write($script:Esc+'7'+$script:Esc+'[r'+$script:Esc+'8')} catch {}
        }
        $script:UiPinned=$false; $script:UiBannerRows=0
        # Reset display attributes before restoring the caller's native colors.
        if ($script:UiVT) {try {[Console]::Write($script:Esc+'[0m')} catch {}}
        if ($restore.ContainsKey('Cursor')) {try {[Console]::CursorVisible=$restore.Cursor} catch {}}
        if ($restore.ContainsKey('Foreground')) {try {$Host.UI.RawUI.BackgroundColor=$restore.Background;$Host.UI.RawUI.ForegroundColor=$restore.Foreground} catch {}}
        if ($restore.ContainsKey('Title')) {try {$Host.UI.RawUI.WindowTitle=$restore.Title} catch {}}
        if ($restore.ContainsKey('Encoding')) {try {[Console]::OutputEncoding=$restore.Encoding} catch {}}
        if ($restore.ContainsKey('OutputMode')) {try {$null=[OptiMiyoo.Terminal]::RestoreMode($restore.OutputMode)} catch {}}
        if ($restore.ContainsKey('Rendering')) {try {$PSStyle.OutputRendering=$restore.Rendering} catch {}}
        $script:UiInteractive=$false; $script:UiAnsi=$false; $script:UiVT=$false
        $script:UiPanel=$false
    }
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
    $script:UiSparseCrtLastTimeMs=-1.0
    $script:MioSynchronizedCrtState=$null
    if (-not $KeepIntro) {
        $script:UiSparseCrtIntroPending=$true
        $script:MioSparseCrtGeometry=$null; $script:MioSparseCrtGeometryKey=''
    }
}
function Update-MioSparseCrt([double]$ElapsedMs,[bool]$HasText=$false,[bool]$VisibleBunny=$true) {
    $eligible=(-not $NoAnimation -and $script:UiVT -and $script:UiPanel -and $VisibleBunny -and
        -not $script:UiDemo -and $script:DisplayEffect -eq 'CRT')
    if (-not $eligible -or $ElapsedMs -lt 0 -or [double]::IsNaN($ElapsedMs) -or [double]::IsInfinity($ElapsedMs)) {
        $changed=($script:UiSparseCrtPhase -ge 0)
        Reset-MioSparseCrt -KeepIntro
        return $changed
    }
    $reversed=($script:UiSparseCrtLastTimeMs -ge 0 -and $ElapsedMs -lt $script:UiSparseCrtLastTimeMs)
    $script:UiSparseCrtLastTimeMs=$ElapsedMs
    return Update-MioSynchronizedCrt $ElapsedMs ($HasText -or $script:UiDemoPaused -or $reversed)
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
        $duration=$frames*1000.0/$script:MioSparseCrtFps
        if ($ElapsedMs-$state.StartMs -ge $duration) {$state.Region=''}
    }
    if (-not $state.Region -and $state.BunnyDueMs -ge 0 -and $ElapsedMs -ge $state.BunnyDueMs) {
        # An expired bunny pass is skipped, never replayed after a long stall.
        if ($ElapsedMs -lt $state.BunnyDueMs+$script:MioSparseCrtBunnyFrameCount*1000.0/$script:MioSparseCrtFps) {
            $state.Region='Bunny'; $state.StartMs=$state.BunnyDueMs
        }
        $state.BunnyDueMs=-1.0
    }
    if ($state.Region -eq 'Logo' -and $script:MioSparseCrtGeometry -and $script:MioSparseCrtGeometry.LogoRow -eq 0) {$state.Region=''}
    $phase=-1
    if ($state.Region) {$phase=[int][Math]::Floor([Math]::Max(0.0,$ElapsedMs-$state.StartMs)*$script:MioSparseCrtFps/1000.0)}
    $script:UiSparseCrtPhase=$phase; $script:UiSparseCrtRegion=$state.Region
    return ($phase -ne $oldPhase -or $state.Region -cne $oldRegion)
}

function Get-MioSweepLevels([int]$Phase) {
    $geometry=$script:MioSparseCrtGeometry
    $regionMode=$script:UiSparseCrtRegion
    $frames=$script:MioSparseCrtBunnyFrameCount; $sweepOffset=2*($geometry.BunnyRow-1)
    if ($regionMode -eq 'Logo') {$frames=$script:MioSparseCrtLogoFrameCount; $sweepOffset=2*($geometry.LogoRow-1)}
    $key=$geometry.Key+'|'+$regionMode+'|'+$frames
    if (-not $script:MioSweepLevels.ContainsKey($key)) {
        if ($script:MioSweepLevels.Count -ge 4) {$script:MioSweepLevels.Clear()}
        $templates=New-Object 'object[]' $frames
        for ($step=0;$step -lt $frames;$step++) {
            # One physical half-cell row per frame in either artwork region.
            # The taller bunny therefore takes longer, at the same speed.
            $center=$sweepOffset+$step
            if ($regionMode -eq 'Logo' -and $geometry.LogoRow -eq 0) {$center=-1000000.0}
            $regions=@{}
            foreach ($region in 'Logo','Bunny') {
                $count=24; $offset=2*($geometry.BunnyRow-1)
                if ($region -eq 'Logo') {$count=10; $offset=2*($geometry.LogoRow-1)}
                $levels=New-Object 'int[]' $count
                for ($row=0;$row -lt $count;$row++) {
                    $base=100; if (($row%2) -eq 1) {$base=84; if ($region -eq 'Bunny') {$base=88}}
                    $distance=$offset+$row-$center; $gain=1.0
                    # A soft leading edge, one dim sweep row, then a faint
                    # phosphor recovery. Keep the footprint to three pixels
                    # and preserve the brighter/darker scanline ordering.
                    if ($distance -eq 0) {$gain=0.92}
                    elseif ($distance -eq 1) {$gain=0.99}
                    elseif ($distance -eq -1) {$gain=1.02}
                    $levels[$row]=[int][Math]::Min(100,[Math]::Round($base*$gain))
                }
                $regions[$region]=$levels
            }
            $templates[$step]=$regions
        }
        $script:MioSweepLevels[$key]=$templates
    }
    return $script:MioSweepLevels[$key][$Phase]
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
    # Cached row shading adds CRT texture without moving pixels or changing
    # menu, status, or input text.
    $artMode=Get-DisplayArtMode
    $useCrt=($script:DisplayEffect -eq 'CRT' -and $script:UiVT)
    # A logo-only sweep leaves these pixels static; reuse the ordinary pose
    # cache instead of retaining an identical bunny frame for every logo phase.
    $sparseCrt=($useCrt -and $script:UiSparseCrtPhase -ge 0 -and $script:MioSparseCrtGeometry -and $script:UiSparseCrtRegion -eq 'Bunny')
    $cacheKey=$pose+'|'+$artMode+'|'+$useCrt
    $phaseKey=$null
    if ($sparseCrt) {
        $phaseKey=$pose+'|'+$artMode+'|'+$script:UiSparseCrtPhase+'|'+$script:MioSparseCrtGeometry.Key+'|'+$script:UiSparseCrtRegion+'|'+$script:MioSparseCrtLogoFrameCount+'|'+$script:MioSparseCrtBunnyFrameCount
        if ($script:MioSparseCrtFrames.ContainsKey($phaseKey)) {return $script:MioSparseCrtFrames[$phaseKey]}
    } elseif ($script:MioRenderCache.ContainsKey($cacheKey)) {return $script:MioRenderCache[$cacheKey]}
    $pixelColors=$script:MioPixelColors
    if ($artMode -eq 'Gray') {
        # Preserve every pixel and face detail; only the palette changes.
        if (-not $script:MioGrayColors) {
            $script:MioGrayColors=@{}
            foreach ($key in $script:MioPixelColors.Keys) {$script:MioGrayColors[$key]=ConvertTo-DisplayGray $script:MioPixelColors[$key]}
        }
        $pixelColors=$script:MioGrayColors
    }
    $rowLevels=$null
    if ($useCrt) {
        if (-not $script:MioCrtPalettes.ContainsKey($artMode)) {
            $levels=@{}
            for ($level=65;$level -le 100;$level++) {
                $palette=@{}
                foreach ($key in $pixelColors.Keys) {
                    $rgb=$pixelColors[$key].Split(';')
                    $palette[$key]=((@($rgb | ForEach-Object {[int][Math]::Round([int]$_*$level/100.0)})) -join ';')
                }
                $levels[$level]=$palette
            }
            $script:MioCrtPalettes[$artMode]=$levels
        }
        $crtPalettes=$script:MioCrtPalettes[$artMode]
        if ($sparseCrt) {
            $rowLevels=(Get-MioSweepLevels $script:UiSparseCrtPhase).Bunny
        } else {
            # A visible scanline texture costs only the first render of a pose.
            # Sparse gestures reuse it without starting a CRT redraw clock.
            $rowLevels=@(for ($row=0;$row -lt 24;$row++) {if (($row%2) -eq 0) {100} else {88}})
        }
    }
    $result=[System.Collections.Generic.List[string]]::new()
    for ($y=0;$y -lt 24;$y+=2) {
        $topColors=$pixelColors; $bottomColors=$pixelColors
        if ($useCrt) {
            $rowKey=$pose+'|'+$artMode+'|'+$y+'|'+$rowLevels[$y]+'|'+$rowLevels[$y+1]
            if ($script:MioCrtRowCache.ContainsKey($rowKey)) {
                $result.Add($script:MioCrtRowCache[$rowKey]); continue
            }
            $topColors=$crtPalettes[$rowLevels[$y]]
            $bottomColors=$crtPalettes[$rowLevels[$y+1]]
        }
        $line=[Text.StringBuilder]::new()
        for ($x=0;$x -lt 22;$x++) {
            $top=[string]$pixels[$y][$x]; $bottom=[string]$pixels[$y+1][$x]
            if ($top -eq '.' -and $bottom -eq '.') {[void]$line.Append(' '); continue}
            if (-not $script:UiVT) {[void]$line.Append('#'); continue}
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
            # Reuse identical quantized CRT rows; bound memory across all poses.
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
    } else {$script:MioRenderCache[$cacheKey]=$rendered}
    return $rendered
}
function Get-DisplayMioFrame([string]$Mood,[string]$PoseOverride) {
    if ($script:UiIdlePoseOverride -and $Mood -in 'idle','wait' -and -not $script:UiDemo -and -not $PoseOverride) {
        $PoseOverride=$script:UiIdlePoseOverride
    }
    return (Get-MioFrame $Mood 0 $PoseOverride)
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
    # Keep one blank row above every screen and one spare row below it.
    # A compact banner preserves both margins in short windows.
    $available=$script:UiHeight-$Lines.Count-2
    $fullBanner=($available -ge 7 -and $script:UiWidth -ge 72)
    $banner=@('')+@(Get-DisplayBanner $fullBanner)
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
    return [pscustomobject]@{Lines=$rows.ToArray(); BannerRows=$banner.Count;LogoRow=$(if ($fullBanner) {2} else {0})}
}
function Flush-DisplayEvents {
    if ($script:UiPendingEvents) {
        if ($script:UiPendingEvents.Count) {$script:UiIdleMenuCache=$null}
        foreach ($row in $script:UiPendingEvents) {$script:UiEventRows.Add($row)}
        $script:UiPendingEvents.Clear()
        while ($script:UiEventRows.Count -gt 100) {$script:UiEventRows.RemoveAt(0)}
    }
}
function Write-TerminalPanel([string[]]$Lines,[int]$InputColumn=0) {
    $script:UiIdleMenuCache=$null
    Flush-DisplayEvents
    $layout=Get-TerminalFrame $Lines
    $script:UiLastLogoRows=@()
    $script:UiLastLogoRow=$layout.LogoRow
    if ($layout.LogoRow -gt 0) {
        $first=$layout.LogoRow-1
        $script:UiLastLogoRows=@($layout.Lines[$first..($first+4)] | ForEach-Object {$_.Substring(2)})
    }
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

function Get-MenuRows([string[]]$Lines,[int]$Width,[ref]$DefaultRows,[bool[]]$SourceDefaults) {
    $rows=[System.Collections.Generic.List[string]]::new()
    $defaults=[System.Collections.Generic.List[bool]]::new()
    $sourceIndex=0
    foreach ($text in $Lines) {
        $line=($text -replace '[\x00-\x1f\x7f-\x9f]',' ').TrimStart()
        $isDefault=($line -match '^(?:\d+|[A-Z])\..*\(default\)')
        if ($SourceDefaults -and $sourceIndex -lt $SourceDefaults.Count) {$isDefault=$SourceDefaults[$sourceIndex]}
        while ((Get-TextWidth $line) -gt $Width) {
            $prefix=Get-TextPrefix $line $Width
            $cut=$prefix.LastIndexOf(' ')
            if ($cut -lt [int]($prefix.Length/2)) {$cut=$prefix.Length}
            $rows.Add($line.Substring(0,$cut))
            $defaults.Add($isDefault)
            $line=$line.Substring($cut).TrimStart()
        }
        $rows.Add($line)
        $defaults.Add($isDefault)
        $sourceIndex++
    }
    if ($DefaultRows) {$DefaultRows.Value=$defaults.ToArray()}
    return $rows.ToArray()
}

function Get-MenuSpacing([string[]]$Rows,[bool[]]$DefaultRows,[int]$MaximumRows) {
    # Paragraph gaps are optional only when they cost artwork or usable space.
    # Remove the minimum number, starting at the bottom; never alter source rows.
    $remove=[Math]::Max(0,$Rows.Count-$MaximumRows)
    $dropped=New-Object 'Collections.Generic.HashSet[int]'
    for($i=$Rows.Count-1;$i -ge 0 -and $remove -gt 0;$i--) {
        if([string]::IsNullOrWhiteSpace($Rows[$i])){[void]$dropped.Add($i);$remove--}
    }
    $kept=New-Object 'Collections.Generic.List[string]'
    $defaults=New-Object 'Collections.Generic.List[bool]'
    for($i=0;$i -lt $Rows.Count;$i++) {
        if($dropped.Contains($i)){continue}
        $kept.Add($Rows[$i]);$defaults.Add(($i -lt $DefaultRows.Count -and $DefaultRows[$i]))
    }
    return [pscustomobject]@{Rows=$kept.ToArray();DefaultRows=$defaults.ToArray()}
}

function Get-MenuLayout([string[]]$Rows,[switch]$NoInput,[bool[]]$DefaultRows) {
    # Keep source rows intact so a later wider window can unwrap them again.
    # Reserve top padding, the compact banner, borders, prompt and a spare row.
    $width=[Math]::Max(16,[Math]::Min($script:UiWidth,$script:UiColumns-4))
    $key=('{0}|{1}|{2}|{3}' -f $width,$script:UiColumns,$script:UiHeight,[bool]$NoInput)
    $key+='|'+($DefaultRows -join ',')
    $cached=$script:UiMenuLayoutCache
    if ($cached -and $cached.Key -ceq $key -and $cached.Rows.Count -eq $Rows.Count) {
        $same=$true
        for ($i=0;$i -lt $Rows.Count;$i++) {if ($Rows[$i] -cne $cached.Rows[$i]) {$same=$false;break}}
        if ($same) {return $cached.Layout}
    }
    $overhead=8;$fullOverhead=14;if ($NoInput) {$overhead=7;$fullOverhead=13}
    $result=$null
    if ($width -ge 72) {
        $wrappedDefaults=$null
        $wrapped=@(Get-MenuRows $Rows ($width-28) ([ref]$wrappedDefaults) $DefaultRows)
        $spacing=Get-MenuSpacing $wrapped $wrappedDefaults ([Math]::Max(12,$script:UiHeight-$fullOverhead))
        $wrapped=$spacing.Rows;$wrappedDefaults=$spacing.DefaultRows
        $body=[Math]::Max(12,$wrapped.Count)
        if ($script:UiHeight -ge $body+$overhead) {
            $result=[pscustomobject]@{Rows=$wrapped;DefaultRows=$wrappedDefaults;Width=$width;TextWidth=($width-28);BodyRows=$body;RequiredHeight=($body+$overhead);ShowMio=$true;Fits=$true}
        }
    }
    # Reclaim the mascot column and empty padding before asking for more room.
    if (-not $result) {
        $wrappedDefaults=$null
        $wrapped=@(Get-MenuRows $Rows ($width-4) ([ref]$wrappedDefaults) $DefaultRows)
        $budget=$script:UiHeight-$overhead;if($width -ge 72){$budget=$script:UiHeight-$fullOverhead}
        $spacing=Get-MenuSpacing $wrapped $wrappedDefaults $budget
        $wrapped=$spacing.Rows;$wrappedDefaults=$spacing.DefaultRows
        $required=$wrapped.Count+$overhead
        $result=[pscustomobject]@{Rows=$wrapped;DefaultRows=$wrappedDefaults;Width=$width;TextWidth=($width-4);BodyRows=$wrapped.Count;RequiredHeight=$required;ShowMio=$false;Fits=($script:UiColumns -ge 44 -and $script:UiHeight -ge $required)}
    }
    $script:UiMenuLayoutCache=[pscustomobject]@{Key=$key;Rows=@($Rows);Layout=$result}
    return $result
}

function Draw-MenuPanel([string]$Title,[string[]]$Rows,[string]$Prompt,
                        [string]$InputText,[int]$Caret,[string]$Mood='idle',
                        [switch]$NoInput,[string]$Channel='SRC -> DST / LOCAL DISK LINK',[bool[]]$DefaultRows) {
    $menuLayout=Get-MenuLayout $Rows -NoInput:$NoInput -DefaultRows $DefaultRows
    if (-not $menuLayout.Fits) {
        Draw-ResizePanel $Title $Prompt $InputText $Caret $menuLayout.RequiredHeight 44
        return
    }
    $Rows=$menuLayout.Rows
    $w=$menuLayout.Width; $left=$menuLayout.TextWidth
    $bodyRows=$menuLayout.BodyRows; $borderHeight=$bodyRows+3
    Flush-DisplayEvents
    $geometryKey=('{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f $w,$script:UiColumns,$script:UiHeight,$bodyRows,$script:UiMenuActive,$script:UiDemo,$script:UiEventRows.Count,[bool]$NoInput)
    if ($menuLayout.ShowMio -and $geometryKey -cne $script:MioSparseCrtGeometryKey) {
        $panelRows=$bodyRows+5;if ($NoInput) {$panelRows--}
        $placeholder=New-Object 'string[]' $panelRows
        $layout=Get-TerminalFrame $placeholder
        $bunnyRow=$layout.Lines.Count-$placeholder.Count+3
        $logoRow=$layout.LogoRow
        $script:MioSparseCrtGeometry=@{Key=($logoRow.ToString()+'|'+$bunnyRow);LogoRow=$logoRow;BunnyRow=$bunnyRow}
        $script:MioSparseCrtGeometryKey=$geometryKey
    }
    $mio=@();if ($menuLayout.ShowMio) {$mio=@(Get-DisplayMioFrame $Mood)}
    # A sparse gesture changes only Mio. Preserve the rest of the terminal,
    # including its steady input caret, and avoid rebuilding every border.
    $patchable=($menuLayout.ShowMio -and $script:UiVT -and -not $script:UiDemo -and -not $NoInput -and
        ($script:UiIdlePoseOverride -or $script:UiSparseCrtPhase -ge 0 -or $script:UiIdleMenuCache.SparseCrt) -and $mio.Count -eq 12 -and
        (-not $script:UiPendingEvents -or $script:UiPendingEvents.Count -eq 0))
    $rowsKey=($Rows -join [char]0)+'|'+($menuLayout.DefaultRows -join ',')
    $cached=$script:UiIdleMenuCache
    if ($patchable -and $cached -and $script:UiPinned -and
        $cached.Width -eq $w -and $cached.Height -eq $script:UiHeight -and
        $cached.Columns -eq $script:UiColumns -and $cached.BannerRows -eq $script:UiBannerRows -and
        $cached.PanelRows -eq $script:UiRows -and $cached.FrameRows -eq $script:UiLastFrameRows -and
        $cached.Title -ceq $Title -and $cached.RowsKey -ceq $rowsKey -and $cached.Prompt -ceq $Prompt -and
        $cached.InputText -ceq $InputText -and $cached.Caret -eq $Caret -and $cached.Mood -ceq $Mood -and
        $cached.Ansi -eq $script:UiAnsi -and $cached.VT -eq $script:UiVT -and $cached.Version -ceq $script:AppVersion -and
        $cached.Effect -ceq $script:DisplayEffect -and $cached.MenuActive -eq $script:UiMenuActive -and
        $cached.EventCount -eq $script:UiEventRows.Count) {
        $patch=[Text.StringBuilder]::new()
        $logo=@()
        if ($cached.LogoRow -gt 0) {
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
    $border=Get-BorderStyle $w $borderHeight
    $lines=[System.Collections.Generic.List[string]]::new()
    $heading=Fit-Text ('-- OptiMiyoo v'+$script:AppVersion+' / '+$Title+' ') ($w-2)
    $lines.Add('  '+(Format-BorderText ('+'+$heading.TrimEnd().PadRight($w-2,'-')+'+') 0 0 $border))
    if ($script:UiDemo) {
        $channel=('DEMO scene {0}/{1} / SIMULATION' -f $script:UiDemoScene,$script:UiDemoCount)
        if ($script:UiDemoPageCount -gt 1) {
            $channel=('DEMO scene {0}/{1} / page {2}/{3}' -f $script:UiDemoScene,$script:UiDemoCount,$script:UiDemoPage,$script:UiDemoPageCount)
        }
    }
    $mioStatus='    MIO // READY';if ($Mood -in 'work','scan','check') {$mioStatus='   MIO // WORKING'}
    $channelRight=' '
    if ($menuLayout.ShowMio) {$channelRight=(Color-Text ' | ' '91;104;151')+(Color-Text (Fit-Text $mioStatus 22) '249;172;204')}
    $lines.Add('  '+(Format-BorderText '|' 0 1 $border)+' '+(Color-Text (Fit-Text $channel $left) '107;216;245')+$channelRight+(Format-BorderText '|' ($w-1) 1 $border))
    # Match complete warnings before coloring, including explanations split across rows.
    $warnings=@()
    if ($script:UiAnsi) {
        $warningPatterns=@(
            '\[[^\[\]]*(?:unsupported|unverified|not\s+installed|unpack)[^\[\]]*\]',
            '^[^\r\n]*\bcannot\s+(?:follow\s+playlist\s+links\s+inside\s+ZIPs|load\s+(?:playlists|ZIPs(?:\s+through\s+RetroArch)?))\.',
            '^Choose\s+Folders\s+or\s+Loose\s+files\s+for\s+playlists\.',
            '^ZIP\s+games\s+are\s+not\s+supported\s+in\s+the\s+default\s+Onion\s+setup\.',
            '(?<UnverifiedHint>^Playlists\s+pointing\s+inside\s+ZIPs\s+are\s+unverified\s+for\s+[^.]+\.|^Onion''s\s+docs\s+do\s+not\s+list\s+ZIP\s+games\s+for\s+this\s+default\s+core\.)'
        )
        $warnings=@([regex]::Matches(($Rows -join "`n"),'(?im)(?:'+($warningPatterns -join '|')+')'))
    }
    $rowOffset=0
    for ($i=0;$i -lt $bodyRows;$i++) {
        $text=''; if ($i -lt $Rows.Count) {$text=$Rows[$i]}
        $right=' '*22; if ($i -lt $mio.Count) {$right=$mio[$i]}
        $warningRow=$false; $unverifiedRow=$false
        foreach ($warning in $warnings) {
            if ($warning.Index -lt $rowOffset+$text.Length -and $warning.Index+$warning.Length -gt $rowOffset) {
                if (($warning.Groups['UnverifiedHint'].Success -or $warning.Value -match '(?i)unverified') -and $warning.Value -notmatch '(?i)unsupported|not\s+installed|unpack') {$unverifiedRow=$true}
                else {$warningRow=$true}
            }
        }
        $rgb='218;224;244'
        if ($i -lt $menuLayout.DefaultRows.Count -and $menuLayout.DefaultRows[$i]) {$rgb='255;221;144'}
        elseif ($warningRow) {$rgb='255;96;96'}
        elseif ($unverifiedRow) {$rgb='255;190;96'}
        elseif ($NoInput -and $text -match '^\[[#.]+\] \d+%$') {$rgb='107;216;245'}
        elseif ($text -match '^[A-Z]\.') {$rgb='107;216;245'}
        $rightColumn=' '
        if ($menuLayout.ShowMio) {$rightColumn=(Color-Text ' | ' '91;104;151')+$right}
        $lines.Add('  '+(Format-BorderText '|' 0 ($i+2) $border)+' '+(Color-Text (Fit-Text $text $left) $rgb)+$rightColumn+(Format-BorderText '|' ($w-1) ($i+2) $border))
        $rowOffset+=$text.Length+1
    }
    $lines.Add('  '+(Format-BorderText ('+'+('-'*($w-2))+'+') 0 ($borderHeight-1) $border $true))
    $lines.Add('  '+(Color-Text (Fit-Text $Prompt $w) '249;202;226'))
    if ($NoInput) {Write-TerminalPanel $lines.ToArray();return}
    $fieldWidth=$w-8
    $inputView=Get-InputViewport $InputText $Caret $fieldWidth
    if ($script:UiDemo) {$lines.Add('  '+(Get-MioPreviewTourBar $w))}
    else {$lines.Add('  '+(Color-Text 'INPUT > ' '107;216;245')+(Format-InputField $inputView $fieldWidth))}
    Write-TerminalPanel $lines.ToArray() (11+$inputView.Caret)
    if ($patchable) {
        $script:UiIdleMenuCache=[pscustomobject]@{
            Width=$w;Height=$script:UiHeight;Columns=$script:UiColumns;BannerRows=$script:UiBannerRows
            PanelRows=$script:UiRows;FrameRows=$script:UiLastFrameRows;Title=$Title;RowsKey=$rowsKey;Prompt=$Prompt
            InputText=$InputText;Caret=$Caret;Mood=$Mood;Ansi=$script:UiAnsi;VT=$script:UiVT;Version=$script:AppVersion
            Effect=$script:DisplayEffect;MenuActive=$script:UiMenuActive;EventCount=$script:UiEventRows.Count
            Mio=$mio;SparseCrt=($script:UiSparseCrtPhase -ge 0);Logo=$script:UiLastLogoRows
            LogoRow=$script:UiLastLogoRow
            InputColumn=(11+$inputView.Caret);BunnyRow=($script:UiLastFrameRows-$lines.Count+3)
        }
    }
}

function Get-ProgressTextRows([string]$Text,[int]$Width,[int]$Count) {
    # A path or tool message must not add terminal controls or new panel rows.
    $safe=$Text -replace '[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]',' '
    $rows=@(Get-MenuRows @($safe) $Width)
    if ($rows.Count -gt $Count) {
        $rows=@($rows[0..($Count-1)])
        $rows[$Count-1]=(Fit-Text $rows[$Count-1] ($Width-3)).TrimEnd()+'...'
    }
    while ($rows.Count -lt $Count) {$rows+=@('')}
    return $rows
}

function Get-OnionProgressRows([string]$Stage,[string]$Detail='',
                               [long]$Completed=0,[long]$Total=-1,[string]$Unit='systems',
                               [int]$Width=68,[switch]$Compact) {
    $Stage=$Stage -replace '[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]',' '
    $Unit=$Unit -replace '[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]',' '
    $Unit=(Fit-Text $Unit 20).TrimEnd()
    $Completed=[Math]::Max(0,$Completed)
    if ($Total -ge 0) {$Completed=[Math]::Min($Completed,$Total)}
    $count='Working...';$bar='';$basis='The total for this step is not known yet.'
    $remaining='';$next='Progress is for this step, not the whole SD setup.'
    if ($Total -ge 0) {
        $count=('{0} / {1} {2} complete' -f $Completed,$Total,$Unit)
        $percent=100.0;if ($Total -gt 0) {$percent=100.0*$Completed/$Total}
        $filled=[int][Math]::Floor(28*$percent/100)
        $bar='['+('#'*$filled)+('.'*(28-$filled))+('] {0:N0}%' -f $percent)
        $basis='Current step: measured progress'
        $remaining=('Remaining in this step: {0} {1}' -f ($Total-$Completed),$Unit)
        if ($Completed -eq $Total) {$next='100% finishes this step only; SD setup may still be running.'}
    }
    if ($Stage -eq 'Preparing selected changes') {
        $basis='Systems processed in this setup pass'
        $next='Preparing your On/Off choices in temporary config copies.'
        if ($Total -ge 0) {$remaining=('Remaining in this pass: {0} {1}' -f ($Total-$Completed),$Unit)}
    }
    if ($Stage -eq 'SD setup finished') {$next='Review the results before returning to the main menu.'}
    $detailRows=@(Get-ProgressTextRows $Detail $Width 4)
    # Do not force four blank detail rows when the reported message is short.
    while ($detailRows.Count -gt 1 -and -not $detailRows[-1]) {$detailRows=@($detailRows[0..($detailRows.Count-2)])}
    $stageRows=@(Get-ProgressTextRows $Stage $Width 2)
    if (-not $stageRows[1]) {$stageRows=@($stageRows[0])}
    $rows=$stageRows+@('')+$detailRows+@('',$count,$bar)
    if (-not $Compact) {$rows+=@($basis,$remaining,'',$next)}
    $rows+=@('','Games and emulator cores stay unchanged.')
    return @(Get-MenuRows $rows $Width)
}

function Show-OnionProgress([string]$Stage,[string]$Detail='',
                            [long]$Completed=0,[long]$Total=-1,[string]$Unit='systems',[switch]$Force) {
    # Refresh only when work reports progress; no background animation loop.
    $Stage=$Stage -replace '[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]',' '
    $Detail=$Detail -replace '[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]',' '
    $Unit=$Unit -replace '[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]',' '
    $Completed=[Math]::Max(0,$Completed)
    if ($Total -ge 0) {$Completed=[Math]::Min($Completed,$Total)}
    $changed=($Stage -cne $script:UiOnionProgressStage)
    $finished=($Total -ge 0 -and $Completed -eq $Total)
    if (-not $Force -and -not $changed -and -not ($finished -and -not $script:UiOnionProgressFinished) -and $script:UiPreparationWatch.ElapsedMilliseconds -lt 150) {return}
    $script:UiOnionProgressStage=$Stage;$script:UiOnionProgressFinished=$finished
    $script:UiPreparationWatch.Restart()
    $count='Working...';$bar=''
    if ($Total -ge 0) {
        $count=('{0} / {1} {2} complete' -f $Completed,$Total,$Unit)
        $percent=100.0;if ($Total -gt 0) {$percent=100.0*$Completed/$Total}
        $filled=[int][Math]::Floor(28*$percent/100)
        $bar='['+('#'*$filled)+('.'*(28-$filled))+('] {0:N0}%' -f $percent)
    }
    if (-not $script:UiVT) {Write-Host ($Stage+' / '+$count+' / '+$Detail);return}
    [void](Update-DisplaySize)
    $width=[Math]::Max(12,$script:UiWidth-28)
    if ($script:UiWidth -lt 72) {$width=[Math]::Max(12,$script:UiWidth-4)}
    $rows=@(Get-OnionProgressRows $Stage $Detail $Completed $Total $Unit $width -Compact:($script:UiHeight -lt 35))
    if (-not (Get-MenuLayout $rows -NoInput).ShowMio) {
        $width=[Math]::Max(12,$script:UiWidth-4)
        $rows=@(Get-OnionProgressRows $Stage $Detail $Completed $Total $Unit $width -Compact:($script:UiHeight -lt 35))
    }
    Draw-MenuPanel -Title 'Onion SD setup / progress' -Rows $rows -Prompt 'Please wait...' -Caret -1 -Mood 'scan' -NoInput -Channel 'ONION SD SETUP'
}

function Draw-ResizePanel([string]$Title,[string]$Detail,[string]$InputText='',
                          [int]$Caret=-1,[int]$RequiredHeight=20,[int]$RequiredWidth=76) {
    if ($script:UiDemo) {$script:UiDemoNeedsSpace=$true}
    if ($script:UiColumns -lt 20 -or $script:UiHeight -lt 7) {return}
    $width=[Math]::Min(92,$script:UiColumns-4)
    $lines=[System.Collections.Generic.List[string]]::new()
    $lines.Add('  '+(Fit-Text ('OptiMiyoo / '+$Title) $width))
    $lines.Add('  '+(Fit-Text ('Enlarge window: '+$RequiredHeight+' rows, '+$RequiredWidth+'+ columns.') $width))
    $lines.Add('  '+(Fit-Text $Detail $width))
    if ($Caret -ge 0) {
        $fieldWidth=$width-8; $inputView=Get-InputViewport $InputText $Caret $fieldWidth
        $lines.Add('  INPUT > '+(Format-InputField $inputView $fieldWidth (-not $script:UiDemo)))
        Write-TerminalPanel $lines.ToArray() (11+$inputView.Caret)
    } else {
        $message='Processing continues.'
        if ($script:UiDemo) {$message='DEMO / no files are accessed'}
        $lines.Add('  '+(Fit-Text $message $width))
        Write-TerminalPanel $lines.ToArray()
    }
}

function Read-DisplayInput([string]$Prompt,[string]$Title='Selection',
                           [string[]]$Lines=@(),[string]$Mood='idle') {
    $Prompt=ConvertTo-SafeExternalText $Prompt
    [void](Update-DisplaySize)
    $layout=Get-MenuLayout $Lines
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
    $idleWatch=[Diagnostics.Stopwatch]::StartNew()
    $sparseIdle=(-not $NoAnimation -and $Mood -eq 'idle' -and -not $script:UiDemo)
    $script:UiIdlePoseOverride=$null
    Reset-MioSparseCrt
    if ($sparseIdle) {Reset-MioIdleInput}
    try {
        while ($true) {
            if (Update-DisplaySize -Throttled) {
                $layout=Get-MenuLayout $Lines
                $dirty=$true
            }
            $bunnyVisible=($layout.Fits -and $layout.ShowMio)
            if ($sparseIdle) {
                $idlePose=Get-MioIdlePose $idleWatch.Elapsed.TotalMilliseconds ($text.Length -gt 0 -or -not $bunnyVisible)
                if ($idlePose -cne $script:UiIdlePoseOverride) {
                    $script:UiIdlePoseOverride=$idlePose
                    $dirty=$true
                }
            }
            if (Update-MioSparseCrt $script:UiEffectClock.Elapsed.TotalMilliseconds ($text.Length -gt 0) $bunnyVisible) {$dirty=$true}
            if ($dirty) {
                Draw-MenuPanel $Title $Lines $Prompt $text $caret $Mood
                $dirty=$false
            }
            if ([Console]::KeyAvailable) {
                $key=[Console]::ReadKey($true)
                if ($sparseIdle) {
                    $idleWatch.Restart(); Reset-MioIdleInput
                    $script:UiIdlePoseOverride='idle'
                }
                if ($key.Key -eq [ConsoleKey]::Escape) {return 'B'}
                if ($key.Key -eq [ConsoleKey]::Enter -and (Update-DisplaySize)) {
                    $layout=Get-MenuLayout $Lines;$dirty=$true;continue
                }
                # Never accept an unseen default or confirmation on a tiny screen.
                if (-not $layout.Fits) {
                    if ($key.Key -eq [ConsoleKey]::Q) {return 'Q'}
                    if ($key.Key -eq [ConsoleKey]::B) {return 'B'}
                    continue
                }
                if ($key.Key -eq [ConsoleKey]::Enter) {return $text.Trim()}
                if ($key.Key -eq [ConsoleKey]::Backspace -and $caret -gt 0) {$previous=Get-InputCaretOffset $text $caret -1;$text=$text.Remove($previous,$caret-$previous);$caret=$previous}
                elseif ($key.Key -eq [ConsoleKey]::Delete -and $caret -lt $text.Length) {$next=Get-InputCaretOffset $text $caret 1;$text=$text.Remove($caret,$next-$caret)}
                elseif ($key.Key -eq [ConsoleKey]::LeftArrow) {$caret=Get-InputCaretOffset $text $caret -1}
                elseif ($key.Key -eq [ConsoleKey]::RightArrow) {$caret=Get-InputCaretOffset $text $caret 1}
                elseif ($key.Key -eq [ConsoleKey]::Home) {$caret=0}
                elseif ($key.Key -eq [ConsoleKey]::End) {$caret=$text.Length}
                elseif ($key.Key -eq [ConsoleKey]::U -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {$text='';$caret=0}
                elseif (-not [char]::IsControl($key.KeyChar) -and $text.Length -lt 4096) {$text=$text.Insert($caret,[string]$key.KeyChar);$caret++}
                $dirty=$true
            } else {
                Wait-DisplayFrame 30
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

function Draw-DisplayPanel([switch]$Force) {
    if (-not $script:UiVT) {return}
    if (Update-DisplaySize) {$Force=$true}
    if (-not $Force -and $script:UiWatch.ElapsedMilliseconds -lt 95) {return}
    $script:UiWatch.Restart()
    if ($script:UiColumns -lt 44) {
        Draw-ResizePanel $script:UiStage $script:UiDetail -RequiredWidth 44
        return
    }
    $w=$script:UiWidth; $left=$w-28; $inner=$w-4
    $compact=(-not $script:UiPanel)
    if ($compact) {$left=$inner}
    $expanded=(-not $compact -and $script:UiHeight -ge 35)
    $mio=@(Get-DisplayMioFrame $script:UiMood $script:UiPoseOverride)
    $count=[Math]::Min($script:Total,$script:Processed+1)
    $clock='00:00:00'; if ($script:Clock) {$clock=Format-Duration $script:Clock.Elapsed.TotalSeconds}
    $pct='working'; if ($script:UiPercent -ge 0) {$pct=('{0,3:N0}%' -f $script:UiPercent)}
    $barPrefix=''; if ($script:UiDemo -or $expanded) {$barPrefix='Stage '}
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
    if ($script:Total -eq 0 -and $script:UiStage -ne 'Preparation finished') {$queue='Queue: scanning source files'; $setLine=$script:UiGame}
    $eta='ETA: pending first completed set'
    if ($script:UiStage -eq 'Preparation finished' -or ($script:Total -gt 0 -and $script:Processed -ge $script:Total)) {$eta='Final verification pending'}
    elseif ($script:Processed -ge 1 -and $script:Clock -and $script:Total -gt $script:Processed) {
        $eta='ETA ~'+(Format-Duration ($script:Clock.Elapsed.TotalSeconds/$script:Processed*($script:Total-$script:Processed)))+' (by completed sets)'
    }
    if ($script:UiPreparing) {
        $setLine='PREPARING INPUT BATCH'
        if ($script:UiPreparationTotal -ge 0) {
            $queue=('{0:N0} / {1:N0} {2} checked' -f $script:UiPreparationCompleted,$script:UiPreparationTotal,$script:UiPreparationUnit)
        } else {$queue=('{0:N0} {1} found / scanning' -f $script:UiPreparationCompleted,$script:UiPreparationUnit)}
        $eta='Processing starts after these checks'
    }
    if ($script:UiDemo) {
        $queue=$tour.Caption
        $setLine='Example: '+$script:UiGame
        $eta='SIMULATION / no files are accessed'
    }
    $resultsLine=('Ready '+$script:Ok+'   Skipped '+$script:Skipped+'   Failed '+$script:Failed)
    if ($script:UiDemo) {$resultsLine='Sample: '+$resultsLine}
    $title='Progress'; $channel='SRC -> DST / LOCAL DISK LINK'
    if ($script:UiDemo) {
        $title='DEMO / '+$script:UiStage
        $channel=('DEMO scene {0}/{1} / SIMULATION' -f $script:UiDemoScene,$script:UiDemoCount)
    }
    $data=@(
        $script:UiSystem,
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
    $stageIndex=3;$barIndex=5;$queueBarIndex=7
    if ($expanded) {
        $basis='Current step: waiting for measured progress'
        if ($script:UiPercent -ge 0) {$basis='Current step: measured progress'}
        $remaining=('Sets remaining: {0} (including current)' -f [Math]::Max(0,$script:Total-$script:Processed))
        if ($script:UiPreparing) {
            $basis='Preparing the queue / total not known yet';$remaining='The batch starts after these checks finish.'
            if ($script:UiPreparationTotal -ge 0) {
                $basis='Current check: measured progress'
                $remaining=('Checks remaining: {0} {1}' -f [Math]::Max(0,$script:UiPreparationTotal-$script:UiPreparationCompleted),$script:UiPreparationUnit)
            }
        }
        if ($script:UiDemo) {
            $basis='Sample step progress / no real files processed'
            $remaining='Total bar tracks demo scenes, not game files.'
        }
        $data=@($script:UiSystem)+@(Get-ProgressTextRows $setLine $left 2)+@('')+
              @(Get-ProgressTextRows $script:UiStage $left 2)+
              @(Get-ProgressTextRows $script:UiDetail $left 3)+
              @($bar,$basis,'',$queue,$queueBar,$remaining,'',$resultsLine,'Source: SRC / Output: DST',('Elapsed '+$clock),$eta)
        $stageIndex=4;$barIndex=9;$queueBarIndex=13
    }
    if ($compact) {
        if ($script:UiDemo -and $script:UiDemoProgressStatus) {$data[5]='Status: '+$script:UiDemoProgressStatus}
        $plain=@($data | ForEach-Object {$_ -replace '\x1b\[[0-9;?]*[ -/]*[@-~]',''} | Where-Object {$_})
        Draw-MenuPanel -Title $title -Rows $plain -Prompt ('MIO > '+$script:UiSay) -Caret -1 -Mood $script:UiMood -NoInput -Channel $channel
        return
    }
    $lines=[System.Collections.Generic.List[string]]::new()
    $bodyCount=$data.Count
    $border=Get-BorderStyle $w ($bodyCount+5)
    $heading=Fit-Text ('-- OptiMiyoo v'+$script:AppVersion+' / '+$title+' ') ($w-2)
    $lines.Add('  '+(Format-BorderText ('+'+$heading.TrimEnd().PadRight($w-2,'-')+'+') 0 0 $border))
    $mioStatus='    MIO // READY'
    if ($script:UiMood -in 'work','scan','check') {$mioStatus='   MIO // WORKING'}
    $lines.Add('  '+(Format-BorderText '|' 0 1 $border)+' '+(Color-Text (Fit-Text $channel $left) '107;216;245')+(Color-Text ' | ' '91;104;151')+(Color-Text (Fit-Text $mioStatus 22) '249;172;204')+(Format-BorderText '|' ($w-1) 1 $border))
    for ($i=0;$i -lt $bodyCount;$i++) {
        $right=' '*22;if ($i -lt $mio.Count) {$right=$mio[$i]}
        $content=Fit-Text ($data[$i] -replace '[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]',' ') $left
        if ($i -eq $barIndex) {
            if ($script:UiDemo -and $script:UiDemoProgressStatus) {$content=Color-Text (Fit-Text ('Status: '+$script:UiDemoProgressStatus) $left) '218;224;244'}
            else {$content=$bar+(' '*[Math]::Max(0,$left-($barPrefix.Length+$barWidth+2+1+$pct.Length)))}
        }
        elseif ($i -eq $queueBarIndex -and $showQueueBar) {$content=$queueBar+(' '*[Math]::Max(0,$left-(6+$queueBarWidth+2+1+$queuePct.Length)))}
        else {$content=Color-Text $content $(if ($i -eq 0) {'107;216;245'} elseif ($i -eq $stageIndex) {'249;172;204'} else {'218;224;244'})}
        $lines.Add('  '+(Format-BorderText '|' 0 ($i+2) $border)+' '+$content+(Color-Text ' | ' '91;104;151')+$right+(Format-BorderText '|' ($w-1) ($i+2) $border))
    }
    $lines.Add('  '+(Format-BorderText '+' 0 ($bodyCount+2) $border)+(Format-DisplayStripe ('-'*($w-2)) $true)+(Format-BorderText '+' ($w-1) ($bodyCount+2) $border))
    $safeSay=$script:UiSay -replace '[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]',' '
    $lines.Add('  '+(Format-BorderText '|' 0 ($bodyCount+3) $border)+' '+(Color-Text (Fit-Text ('MIO > '+$safeSay) $inner) '249;202;226')+' '+(Format-BorderText '|' ($w-1) ($bodyCount+3) $border))
    $lines.Add('  '+(Format-BorderText ('+'+('-'*($w-2))+'+') 0 ($bodyCount+4) $border $true))
    try {[Console]::CursorVisible=$false} catch {}
    Write-TerminalPanel $lines.ToArray()
}
function Show-Stage([string]$Stage,[string]$Detail,[double]$MeasuredPercent=-1) {
    Complete-PreparationProgress
    $script:UiStage=$Stage; $script:UiDetail=$Detail; $script:UiPercent=$MeasuredPercent
    $script:UiMood='work'; $script:UiSay='Processing the current game.'
    if ($Stage -match 'Hash|Verif|Check') {$script:UiMood='check'; $script:UiSay='Checking file integrity.'}
    elseif ($Stage -match 'Scan|Prepar|Read') {$script:UiMood='scan'; $script:UiSay='Reading game files and checking their order.'}
    elseif ($Stage -match 'HxC|IPF.*DSK') {$script:UiSay='Running the disk-image engine.'}
    elseif ($Stage -match 'Convert') {$script:UiSay='Converting disk images.'}
    elseif ($Stage -match 'Playlist|Install') {$script:UiSay='Preparing the playlist and game files.'}
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
function Get-BannerPalette {
    return @($script:Pride[0],$script:Pride[1],$script:Pride[2],$script:Pride[3],
              $script:Trans[0],$script:Trans[1],$script:Trans[2],$script:Trans[3],$script:Trans[4])
}
function Get-DisplayBanner([bool]$Full=$true) {
    if ($Full) {
        foreach ($line in @(Get-OptiLogoRows)) {'  '+$line}
        '  '+(Color-Text (Fit-Text ('OptiMiyoo v'+$script:AppVersion+' // Disk conversion and playlists') $script:UiWidth) '249;172;204')
        '  '+(Format-DisplayStripe ('='*$script:UiWidth))
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
    $artMode=Get-DisplayArtMode
    if ($artMode -eq 'Gray') {
        $paletteKey=$colors -join '|'
        if ($script:OptiLogoGrayPaletteKey -cne $paletteKey) {
            $script:OptiLogoGrayPalette=@($colors | ForEach-Object {ConvertTo-DisplayGray $_})
            $script:OptiLogoGrayPaletteKey=$paletteKey
        }
        $colors=$script:OptiLogoGrayPalette
    }
    $crt=($script:UiVT -and $script:DisplayEffect -eq 'CRT')
    $cacheKey=$artMode+'|'+$crt+'|'+($colors -join '|')
    # The later bunny sweep cannot shade the logo. Its steady rows already
    # have a cache entry and need no per-phase copies.
    $motion=($crt -and $script:UiSparseCrtPhase -ge 0 -and $script:MioSparseCrtGeometry.LogoRow -gt 0 -and $script:UiSparseCrtRegion -eq 'Logo')
    $levels=$null
    if ($motion) {
        $cacheKey+='|'+$script:MioSparseCrtGeometry.Key+'|'+$script:UiSparseCrtRegion+'|'+$script:MioSparseCrtLogoFrameCount+'|'+$script:MioSparseCrtBunnyFrameCount+'|'+$script:UiSparseCrtPhase
        if ($script:OptiLogoMotionCache.ContainsKey($cacheKey)) {return $script:OptiLogoMotionCache[$cacheKey]}
        $levels=(Get-MioSweepLevels $script:UiSparseCrtPhase).Logo
    } elseif ($script:OptiLogoCache.ContainsKey($cacheKey)) {return $script:OptiLogoCache[$cacheKey]}
    $rows=[System.Collections.Generic.List[string]]::new()
    $rake=@(2,2,1,1,0)
    $prefix=$script:Esc+'[38;2;'; $reset=$script:Esc+'[0m'
    for ($row=0;$row -lt 5;$row++) {
        $topLevel=100; $bottomLevel=84
        if ($levels) {$topLevel=$levels[$row*2]; $bottomLevel=$levels[$row*2+1]}
        $rowKey=$row.ToString()+'|'+$artMode+'|'+$crt+'|'+($colors -join '|')+'|'+$topLevel+'|'+$bottomLevel
        if ($script:OptiLogoRowCache.ContainsKey($rowKey)) {$rows.Add($script:OptiLogoRowCache[$rowKey]);continue}
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
            elseif ($script:UiVT) {[void]$line.Append($prefix+$rgb+'m'+$glyph+$reset)}
            else {[void]$line.Append($glyph)}
        }
        $renderedRow=$line.ToString(); $rows.Add($renderedRow)
        if ($script:OptiLogoRowCache.Count -ge 256) {$script:OptiLogoRowCache.Remove($script:OptiLogoRowOrder.Dequeue())}
        $script:OptiLogoRowCache[$rowKey]=$renderedRow; $script:OptiLogoRowOrder.Enqueue($rowKey)
    }
    $rendered=$rows.ToArray()
    if ($motion) {
        if ($script:OptiLogoMotionCache.Count -ge 256) {$script:OptiLogoMotionCache.Remove($script:OptiLogoMotionOrder.Dequeue())}
        $script:OptiLogoMotionCache[$cacheKey]=$rendered; $script:OptiLogoMotionOrder.Enqueue($cacheKey)
    } else {$script:OptiLogoCache[$cacheKey]=$rendered}
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
    foreach ($line in $boot) {Write-Host ('  :: '+$line)}
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
    # Only the installed profiles are read. All games, paths, results and work
    # below are invented; never call a scanner, converter or SD setup worker.
    $profileData=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../systems.json') -Raw | ConvertFrom-Json
    $profiles=@($profileData)
    $byFolder=@{};foreach ($profile in $profiles) {$byFolder[$profile.Folder]=$profile}
    $scenes=@(
        @{Group='Tour';Mood='happy';Stage='Welcome to the demo';System='MENU';Menu=@(
            'A guided tour of every menu and the main features.',
            'All games, progress and results here are examples.',
            'No game files or SD cards are read or changed.','',
            'Space: pause / resume','N / Right / Enter: next',
            'P / Left: previous','R: restart this section',
            'E: turn the CRT effect on or off','B / Q / Esc: return to demo selection');Detail='Use the controls below at any time.';Duration=13000},
        @{Group='Tour';Mood='idle';Stage='Main menu';System='MENU';MenuPage='Main';Lesson='S prepares an SD card. C/Z convert. Numbers create playlists.';Duration=12000},
        @{Group='Tour';Mood='idle';Stage='Choose a demo';System='MENU';MenuPage='Demo';Lesson='Each section can also be watched on its own.';Duration=10000},
        @{Group='Tour';Mood='idle';Stage='Start with SRC and DST';System='MENU';Menu=@(
            'Put one system''s games in SRC.',
            'Use ZIPs, game folders or individual files.',
            'Finished files go into DST.','',
            'C / Z: convert disk images; no playlists.',
            '1-9: make playlists; keep media formats.',
            'S: choose enabled file types on an Onion SD card.');Detail='Choose the task that matches your files.';Duration=10000},
        @{Group='Setup';Mood='idle';Stage='Onion SD setup';System='MENU';Menu=@(Get-OnionSetupPathRows);Duration=10000},
        @{Group='Setup';Mood='scan';Stage='Checking an Onion SD card';System='SD SETUP';Game='Example SD';Detail='Read config file lists to find enabled and disabled types.';SdProgress=$true;Progress=$true;SdTotal=10;SdUnit='systems checked';Duration=5000},
        @{Group='Setup';Mood='idle';Stage='Choose SD file types';System='MENU';Menu=@((Get-OnionSetupChecklistModel -Items @(
            foreach($id in 'AMIGA','COMMODORE','DOS','MSX','PS','SEGACD','VIC20','CPC','ZXS','LYNX') {
                $state='On';if($id -eq 'COMMODORE'){$state='Partial'};if($id -in 'PS','LYNX'){$state='Off'}
                [pscustomobject]@{Id=$id;State=$state;Available=$true;Intent='Keep';Reason=''}
            })).Lines);Detail='Example scan. Toggle a number; 1 toggles all. Apply saves changes.';Duration=14000},
        @{Group='Setup';Mood='check';Stage='Preparing selected changes';System='SD SETUP';Game='Example Emu/PSX/config.json';Detail='Prepare additions and removals in temporary config copies.';SdProgress=$true;Progress=$true;SdTotal=3;SdUnit='systems';Duration=4500},
        @{Group='Setup';Mood='happy';Stage='SD setup results';System='MENU';Menu=@(
            'Example: SD setup finished','Updated: 3    Skipped: 7    Failed: 0','',
            'PlayStation: enabled .m3u playlists',
            'C64: enabled supported playlists and tape files',
            'Lynx: enabled .lyx games','',
            'Original configs saved in Backups/OptiMiyoo_<ID>/Emu/',
            'Refresh Onion''s game list after setup.',
            'S does not change the other menus.','',
            'The results screen waits for you.',
            'Enter / Esc: main menu    Q: exit');Detail='Setup keeps games and installed emulator cores unchanged.';Duration=12000}
    )
    foreach ($converter in @(
        @{Group='C64';Name='Commodore 64';System='COMMODORE 64';Input='NIB/NBZ';Source='NIB';Target='G64';Game='Demo disk set';Engine='Converting NIB to G64'},
        @{Group='ZX';Name='ZX Spectrum';System='ZX SPECTRUM';Input='IPF';Source='IPF';Target='DSK';Game='Demo Spectrum';Engine='Converting IPF to DSK'}
    )) {
        $group=$converter.Group;$target=$converter.Target;$game=$converter.Game
        $scenes+=@(
            @{Group=$group;Mood='idle';Stage=($converter.Name+' settings');System='MENU';MenuPage=$group;Lesson='Choose the output layout, then Keep or Remove originals.';Duration=10000},
            @{Group=$group;Mood='idle';Stage='How converter Auto works';System='MENU';Menu=@(
                '1. Auto / keep the input layout',
                'A game ZIP becomes a game ZIP.',
                'A game folder stays a game folder.',
                'Individual files stay individual files.','',
                ('The images inside are converted to '+$target+'.'),'',
                '2. ZIPs puts each game into a ZIP.',
                '3. Folders makes a folder for each game.',
                '4. Loose files adds no game folder.');Detail='Auto preserves the layout, not the source image format.';Duration=11000},
            @{Group=$group;Mood='idle';Stage='Choose what happens to originals';System='MENU';Menu=@(Get-OptiOriginalsRows);Detail='These choices also apply to numbered playlist batches.';Duration=10000},
            @{Group=$group;Mood='scan';Stage=('Reading '+$converter.Input+' images');System=$converter.System;Game=($game+'.zip');Detail=('Two images found; existing '+$target+' images need no conversion.');Total=1},
            @{Group=$group;Mood='work';Stage=$converter.Engine;System=$converter.System;Game=($game+' / Disk 1.'+$converter.Source.ToLowerInvariant());Detail='The converter reports activity, not a measured percentage.';Total=1;Duration=4500},
            @{Group=$group;Mood='check';Stage=('Preserving an existing '+$target);System=$converter.System;Game=($game+' / Disk 2.'+$target.ToLowerInvariant());Detail=('Existing '+$target+' bytes are copied and verified.');Total=1;Progress=$true},
            @{Group=$group;Mood='check';Stage=('Verifying and saving '+$target+' output');System=$converter.System;Game=$game;Detail='Check the finished files, then save the chosen layout in DST.';Total=1;Progress=$true;CompleteSet=$true},
            @{Group=$group;Mood='happy';Stage='Conversion complete';System='MENU';Menu=@(
                ('Example with ZIP output: DST/'+$game+'.zip'),
                ('Inside: Disk 1.'+$target.ToLowerInvariant()+', Disk 2.'+$target.ToLowerInvariant()),
                'Converted games stay visible in DST.',
                'No playlist or .hidden folder is created.','',
                'To create a playlist later, use the converted files',
                'as input for the matching numbered system.');Detail=('Finished '+$target+' output is ready in DST.');Duration=10000}
        )
    }
    $zxResult=@($scenes | Where-Object {$_.Group -eq 'ZX' -and $_.Stage -eq 'Conversion complete'})[0]
    $zxResult.Menu+=@('Fuse cannot load playlists.')
    $scenes+=@{Group='Playlists';Mood='idle';Stage='Two separate storage choices';System='MENU';Menu=@(
        'First: single games',
        'Choose how games with one disc or tape side stay in DST.','',
        'Second: playlist media',
        'Choose how multi-disc media is stored in DST/.hidden.',
        'The playlist itself stays outside .hidden.','',
        'The two choices are independent.',
        'Auto keeps the input ZIP, folder or individual-file layout.',
        'ZIPs, Folders and Loose files set a different layout.');Detail='Next: both menus for each of the nine systems.';Duration=12000}
    $lessons=@{
        AMIGA='Amiga keeps IPF/ADF formats. PUAE2021 supports links into ZIPs.'
        COMMODORE='C64 keeps disks and TAP/T64 tape sides in their original formats.'
        DOS='DOS uses .m3u8 playlists. ZIP games and ZIP playlist links differ.'
        MSX='blueMSX loads ZIP games, but not playlist links inside ZIPs.'
        PS='PlayStation defaults to loose single games and folders for playlists.'
        SEGACD='Sega CD defaults to loose single games and folders for playlists.'
        VIC20='VIC-20 disk playlists can point to images inside ZIPs.'
        CPC='CrocoDS supports neither ZIP games nor playlists.'
        ZXS='Fuse loads ZIP games. Its playlist limits are shown separately.'
    }
    foreach ($profile in $profiles) {
        $scenes+=@(
            @{Group='Playlists';Mood='idle';Stage=($profile.Name+' / single games');System='MENU';MenuPage='SingleStorage';Folder=$profile.Folder;Lesson=$lessons[$profile.Folder];Duration=10000},
            @{Group='Playlists';Mood='idle';Stage=($profile.Name+' / playlist media');System='MENU';MenuPage='Storage';Folder=$profile.Folder;Duration=11000}
        )
    }
    $scenes+=@(
        @{Group='Playlists';Mood='idle';Stage='Name and group the discs';System='MENU';Menu=@(
            'Separate images:','Demo Adventure (Disc 1).chd','Demo Adventure (Disc 2).chd','',
            'Inside a game folder: Disc 1.chd, Disc 2.chd',
            'C64 tapes: Game (Side A).tap, Game (Side B).tap','',
            'Keep a CUE with its tracks and any matching SBI files.',
            'Keep different versions of a disc in separate batches.');Detail='Numbered systems do not convert image formats.';Duration=12000},
        @{Group='Playlists';Mood='scan';Stage='Ordering multiple disks';System='PLAYLISTS';Game='Demo Adventure';Detail='Natural order: Disk 1, Disk 2, Disk 10.';Total=1},
        @{Group='Playlists';Mood='work';Stage='Preparing hidden media';System='PLAYLISTS';Game='Demo Adventure';Detail='Folder choice: DST/.hidden/Demo Adventure/';Progress=$true;Total=1},
        @{Group='Playlists';Mood='check';Stage='Writing and verifying the playlist';System='PLAYLISTS';Game='Demo Adventure.m3u';Detail='Check relative paths and their media before saving.';Progress=$true;CompleteSet=$true;Total=1},
        @{Group='Playlists';Mood='happy';Stage='Finished playlist layout';System='MENU';Menu=@(
            'DST/','  Demo Adventure.m3u','  .hidden/','    Demo Adventure/','      Disc 1.chd','      Disc 2.chd','',
            'The playlist contains relative paths:',
            '.hidden/Demo Adventure/Disc 1.chd',
            '.hidden/Demo Adventure/Disc 2.chd');Detail='One visible playlist; its disc images stay in .hidden.';Duration=11000},
        @{Group='Playlists';Mood='happy';Stage='Finished single-game layouts';System='MENU';Menu=@(
            'A single game does not need a playlist.',
            'Its output stays visible in DST.','',
            'Auto: preserve the original ZIP, folder or loose layout.',
            'ZIPs: DST/Demo Solo.zip',
            'Folders: DST/Demo Solo/Demo Solo (Disc 1).chd',
            'Loose files: DST/Demo Solo (Disc 1).chd');Detail='Single-game storage is independent of .hidden storage.';Duration=11000},
        @{Group='Playlists';Mood='idle';Stage='Copy to the SD card';System='MENU';Menu=@(
            'Copy the contents of DST to the system''s ROM folder.',
            'Include .hidden when it exists.',
            'Refresh Onion''s game list.','',
            'Launch the playlist for a multi-disc game.',
            'RetroArch: Quick Menu > Disk Control',
            'Eject, select the next image, then insert it.',
            'DOSBox Pure has its own disc-selection controls.',
            'C64 tapes may also need keyboard/load commands.');Detail='Use S if supported file types are missing from the game list.';Duration=12000},
        @{Group='Results';Mood='wait';Stage='Overwrite choices';System='MENU';Menu=@(
            'Example: DST/Demo Adventure.m3u already exists.',
            'The app lists the outputs that would be replaced.','')+@(Get-OverwriteChoiceRows)+@('',
            'Skipping keeps both existing output and its originals.');Detail='This demo never overwrites files. Use N/Right to continue.';Duration=11000},
        @{Group='Results';Mood='wait';Stage='Waiting for an overwrite choice';System='EXISTING OUTPUT';Game='Demo Adventure.m3u';Detail='The batch waits; no percentage is invented.';Status='Waiting for your choice';Total=3;Ok=1},
        @{Group='Results';Mood='wait';Stage='Skipped: overwrite declined';System='RESULT';Game='Demo Adventure.m3u';Detail='Existing output and original source are both kept.';Total=3;Ok=1;Skipped=1;Status='Skipped / originals kept'},
        @{Group='Results';Mood='oops';Stage='Failed: a CUE track is missing';System='RESULT';Game='Demo Disc 2.cue';Detail='This set fails; its originals are kept. Other sets continue.';Total=3;Ok=1;Skipped=1;Failed=1;Status='Failed / originals kept'},
        @{Group='Results';Mood='oops';Stage='Batch complete';System='SUMMARY';Game='Demo collection';Detail='Three sets: one ready, one skipped, one failed.';Progress=$true;Complete=$true;Total=3;Ok=1;Skipped=1;Failed=1},
        @{Group='Results';Mood='idle';Stage='Review the batch results';System='MENU';Menu=@(
            'Ready: 1    Skipped: 1    Failed: 1',
            'Skipped and failed originals stay in SRC.',
            'Fix the missing CUE track before trying that set again.','',
            'The results screen waits for you.','',
            'Enter: main menu',
            'Q: exit');Detail='These are sample results, not an actual batch.';Duration=10000},
        @{Group='Results';Mood='check';Stage='Retrying a corrected disk set';System='RESULT';Game='Demo Disc 2.cue';Detail='New batch: check the restored track, then verify and save.';Total=1;Progress=$true;CompleteSet=$true},
        @{Group='Results';Mood='happy';Stage='Corrected set complete';System='RESULT';Game='Demo Disc 2.cue';Detail='The new batch has one verified output.';Progress=$true;Complete=$true;Total=1;Ok=1},
        @{Group='Results';Mood='wait';Stage='No matching inputs';System='EMPTY BATCH';Game='Demo empty SRC';Detail='Add matching files to SRC, then start a new batch.';Status='No matching inputs';Total=0}
    )
    $poseNames=@{idle='At rest';blink='Blink';scanleft='Look left';scanright='Look right';work='Working';check='Checking';happy='Happy';happyturn='Happy turn';oops='Oops';wait='Waiting'}
    foreach ($pose in 'idle','blink','scanleft','scanright','work','check','happy','happyturn','oops','wait') {
        $scenes+=@{Group='Bunny';Mood='idle';Pose=$pose;Stage=('Mio / '+$poseNames[$pose]);System='ANIMATION GALLERY';Game='Mio';Detail='E turns CRT styling on or off. Space holds this pose.';Status='Bunny preview';Total=0;Duration=2000}
    }
    # The gallery uses its own scene clock; normal menus retain 12-second gaps.
    [void](Get-MioFrame 'idle' 0)
    foreach ($gesture in $script:MioIdleGestures) {
        $scenes+=@{Group='Bunny';Mood='idle';IdleGesture=$gesture;Stage=('Idle gesture / '+$gesture.Name);System='ANIMATION GALLERY';Game='Mio';Detail='Brief gestures with a 12-second rest between them in menus.';Status='Idle animation preview';Total=0;Duration=2200}
    }
    $scenes+=@{Group='Tour';Mood='happy';Stage='Ready to try it';System='MENU';Menu=@(
        'That is the full walkthrough.','',
        'S prepares your SD card.',
        'C / Z convert disk images.',
        '1-9 create playlists for the chosen system.',
        'D opens this demo. E turns CRT on or off.',
        'Q exits from the main menu.','',
        'B / Q / Esc here returns to demo selection.',
        'R restarts the full walkthrough.');Detail='No game files or SD cards were changed.';Duration=12000}
    foreach ($scene in $scenes) {
        if ($scene.MenuPage) {
            $profile=$null;if ($scene.Folder) {$profile=$byFolder[$scene.Folder]}
            $model=Get-OptiMenuModel -Page $scene.MenuPage -Profiles $profiles -Profile $profile -DisplayEffect $script:DisplayEffect
            $scene.Menu=@($model.Rows)
            if ($scene.MenuPage -eq 'Main') {$scene.Profiles=$profiles}
        } elseif ($scene.SdProgress) {$scene.Menu=@($scene.Stage,$scene.Detail)}
        if ($scene.Menu -and -not $scene.Duration) {$scene.Duration=10000}
    }
    if ($Section -ne 'Tour') {$scenes=@($scenes | Where-Object {$_.Group -eq $Section})}
    return $scenes
}
function Get-MioPreviewMenuRows([hashtable]$Scene) {
    $rows=@($Scene.Menu)
    if ($Scene.MenuPage -eq 'Main') {
        # E is a real display preference even while all other actions are examples.
        $rows=@((Get-OptiMenuModel -Page Main -Profiles $Scene.Profiles -DisplayEffect $script:DisplayEffect).Rows)
    } elseif ($Scene.SdProgress) {
        $total=[int]$Scene.SdTotal
        $done=[Math]::Min($total,[int][Math]::Floor($total*$script:UiPercent/100.0))
        $width=[Math]::Max(12,$script:UiWidth-28)
        if ($script:UiWidth -lt 72) {$width=[Math]::Max(12,$script:UiWidth-4)}
        $rows=@(Get-OnionProgressRows $Scene.Stage $Scene.Detail $done $total $Scene.SdUnit $width -Compact:($script:UiHeight -lt 35))+
              @('Sample SD data / no card is accessed.')
    }
    if ($Scene.Lesson) {$rows+=@('',$Scene.Lesson)}
    return $rows
}
function Get-MioPreviewMenuPage([string[]]$Rows,[int]$Page=0,[long]$Anchor=-1) {
    $first=0;$last=$Rows.Count-1
    while($first -le $last -and [string]::IsNullOrWhiteSpace($Rows[$first])){$first++}
    while($last -ge $first -and [string]::IsNullOrWhiteSpace($Rows[$last])){$last--}
    if($last -ge $first){$Rows=@($Rows[$first..$last])}else{$Rows=@()}
    $width=[Math]::Max(16,[Math]::Min($script:UiWidth,$script:UiColumns-4))
    if ($width -lt 72 -or $script:UiHeight -lt 26) {
        # Small windows retain the normal compact layout and resize prompt.
        return [pscustomobject]@{Rows=@($Rows);DefaultRows=@();Index=0;Count=1;Anchor=-1}
    }
    # Reserve the full logo, top margin, borders, controls and spare bottom row.
    # Page the text rather than switching artwork on and off between scenes.
    $capacity=$script:UiHeight-14
    $allDefaults=$null
    $allWrapped=@(Get-MenuRows $Rows ($width-28) ([ref]$allDefaults))
    $spacing=Get-MenuSpacing $allWrapped $allDefaults $capacity
    if ($spacing.Rows.Count -le $capacity) {return [pscustomobject]@{Rows=$spacing.Rows;DefaultRows=$spacing.DefaultRows;Index=0;Count=1;Anchor=0L}}
    # Keep each paragraph together when it fits. In particular, an option and
    # its following explanation must not land on different demo pages.
    $paragraphs=New-Object 'Collections.Generic.List[object]'
    $paragraph=New-Object 'Collections.Generic.List[string]';$gap=0
    foreach($line in $Rows) {
        if([string]::IsNullOrWhiteSpace($line)) {
            if($paragraph.Count){$paragraphs.Add([pscustomobject]@{Lines=$paragraph.ToArray();Gap=$gap});$paragraph.Clear();$gap=0}
            $gap++
        } else {$paragraph.Add($line)}
    }
    if($paragraph.Count){$paragraphs.Add([pscustomobject]@{Lines=$paragraph.ToArray();Gap=$gap})}
    $chunks=New-Object 'Collections.Generic.List[object]'
    foreach($block in $paragraphs) {
        $blockDefaults=$null;$wrapped=@(Get-MenuRows $block.Lines ($width-28) ([ref]$blockDefaults))
        if($wrapped.Count -le $capacity){$chunks.Add([pscustomobject]@{Rows=$wrapped;DefaultRows=$blockDefaults;Gap=$block.Gap});continue}
        # Oversized paragraphs retain the prior per-source-line wrapping policy.
        $gap=$block.Gap
        foreach($line in $block.Lines) {
            $lineDefaults=$null;$wrapped=@(Get-MenuRows @($line) ($width-28) ([ref]$lineDefaults))
            $chunks.Add([pscustomobject]@{Rows=$wrapped;DefaultRows=$lineDefaults;Gap=$gap});$gap=0
        }
    }
    $pages=[System.Collections.Generic.List[object]]::new()
    $current=[System.Collections.Generic.List[string]]::new()
    $currentDefaults=[System.Collections.Generic.List[bool]]::new()
    $offset=0L; $pageAnchor=0L
    foreach ($chunk in $chunks) {
        $wrapped=$chunk.Rows;$gap=$chunk.Gap
        if ($current.Count -and $current.Count+$gap+[Math]::Min($wrapped.Count,$capacity) -gt $capacity) {
            $pages.Add([pscustomobject]@{Rows=$current.ToArray();DefaultRows=$currentDefaults.ToArray();Anchor=$pageAnchor})
            $current.Clear(); $currentDefaults.Clear(); $pageAnchor=$offset
        }
        if($current.Count){for($i=0;$i -lt $gap;$i++){$current.Add('');$currentDefaults.Add($false)}}
        $wrappedIndex=0
        foreach ($row in $wrapped) {
            if ($current.Count -eq $capacity) {
                $pages.Add([pscustomobject]@{Rows=$current.ToArray();DefaultRows=$currentDefaults.ToArray();Anchor=$pageAnchor})
                $current.Clear(); $currentDefaults.Clear(); $pageAnchor=$offset
            }
            $current.Add($row); $currentDefaults.Add($chunk.DefaultRows[$wrappedIndex]); $wrappedIndex++
            $offset+=($row -replace '\s','').Length
        }
    }
    if ($current.Count -or -not $pages.Count) {$pages.Add([pscustomobject]@{Rows=$current.ToArray();DefaultRows=$currentDefaults.ToArray();Anchor=$pageAnchor})}
    $count=$pages.Count
    if ($Anchor -ge 0) {
        # Wrapping changes row numbers, so preserve the first visible text's
        # position instead. Ignore whitespace removed by word wrapping.
        $Page=0
        for ($i=1;$i -lt $count;$i++) {if ($pages[$i].Anchor -gt $Anchor) {break}; $Page=$i}
    }
    if ($Page -lt 0) {$Page=$count-1}
    $index=[Math]::Max(0,[Math]::Min($count-1,$Page))
    return [pscustomobject]@{Rows=$pages[$index].Rows;DefaultRows=$pages[$index].DefaultRows;Index=$index;Count=$count;Anchor=$pages[$index].Anchor}
}
function Get-MioPreviewControls([bool]$Paused,[bool]$NeedsSpace=$false) {
    $action='pause';if ($Paused) {$action='resume'}
    $prefix='DEMO';if ($Paused) {$prefix='PAUSED'}
    if ($NeedsSpace) {$prefix='RESIZE PAUSED'}
    $state='On';if ($script:DisplayEffect -eq 'Smooth') {$state='Off'}
    $width=[Math]::Max(1,$script:UiWidth-10)
    $options=@(
        ($prefix+' | Space '+$action+' | N/P step | R restart | E CRT '+$state+' | B back'),
        ($prefix+' | Space '+$action+' | N/P | R | E CRT | B back'),
        ('Space '+$action+' | N/P | B back')
    )
    foreach ($option in $options) {if ($option.Length -le $width) {return $option}}
    return 'Space pause | B back'
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
        if (-not $NoAnimation) {$script:UiPoseOverride=Get-MioIdleGesturePose $Scene.IdleGesture ($elapsed-400)}
    }
    $script:Total=4
    if ($Scene.ContainsKey('Total')) {$script:Total=[int]$Scene.Total}
    foreach ($name in 'Ok','Skipped','Failed') {Set-Variable -Scope Script -Name $name -Value ([int]$Scene[$name])}
    if ($Scene.Progress) {$script:UiPercent=100*$fraction}
    if ($Scene.Complete) {$script:UiPercent=100}
    elseif ($Scene.CompleteSet -and $fraction -ge 1) {$script:Ok++}
    $script:Processed=$script:Ok+$script:Skipped+$script:Failed
}
function Show-MioPreview([string]$Section='Tour') {
    $scenes=@(Get-MioPreviewScenes $Section)
    $saved=@{}
    foreach ($name in 'Total','Processed','Ok','Skipped','Failed','Clock','UiSystem','UiGame','UiStage','UiDetail','UiPercent','UiMood','UiSay','UiTick','UiLastStage','UiPoseOverride','UiDemo','UiDemoPaused','UiDemoScene','UiDemoCount','UiDemoPage','UiDemoPageCount','UiDemoProgressTick','UiDemoProgressStatus','UiPreparing','UiPreparationCompleted','UiPreparationTotal','UiPreparationUnit','UiDemoNeedsSpace') {
        $value=Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue
        $saved[$name]=$null; if ($value) {$saved[$name]=$value.Value}
    }
    try {
        Clear-DisplayPanel
        $script:UiDemo=$true; $script:UiDemoCount=$scenes.Count
        $script:UiPreparing=$false; $script:UiDemoNeedsSpace=$false
        $animateDemo=$script:UiVT
        $script:Clock=[Diagnostics.Stopwatch]::StartNew()
        $index=0; $paused=$false; $requestedPage=0
        while ($index -ge 0 -and $index -lt $scenes.Count) {
            $scene=$scenes[$index]; $script:UiDemoScene=$index+1
            $pageIndex=0; if ($scene.Menu) {$pageIndex=$requestedPage}
            $requestedPage=0; $pageCount=1; $pageAnchor=-1L
            $script:UiDemoPage=1; $script:UiDemoPageCount=1
            $script:UiSystem='DEMO / '+$scene.System; $script:UiGame=$scene.Game
            $script:UiStage=$scene.Stage; $script:UiDetail=$scene.Detail
            $script:UiMood=$scene.Mood; $script:UiPoseOverride=$scene.Pose; $script:UiPercent=-1
            if (-not $animateDemo) {
                Write-Host ('  [DEMO {0}/{1}] {2} / {3}' -f ($index+1),$scenes.Count,$scene.System,$scene.Stage)
                if ($scene.Menu) {
                    Set-MioPreviewProgress $scene 0 3500
                    foreach ($row in @(Get-MioPreviewMenuRows $scene)) {Write-Host ('  '+$row)}
                }
                if ($scene.Detail) {Write-Host ('  '+$scene.Detail)}
                $index++; continue
            }
            $timer=[Diagnostics.Stopwatch]::StartNew(); if ($paused) {$timer.Stop()}
            $duration=3500; if ($scene.Group -eq 'Bunny') {$duration=1800}
            if ($scene.Duration) {$duration=[int]$scene.Duration}
            $next=$index+1; $dirty=$true; $resizePaused=$false; $draw=[Diagnostics.Stopwatch]::StartNew()
            $frameInterval=250; $periodic=$true
            if (($scene.Menu -and -not $scene.SdProgress) -or $scene.IdleGesture) {$periodic=$false}
            elseif ($scene.Status -or $scene.Complete) {$frameInterval=1000}
            while ($true) {
                $resized=Update-DisplaySize -Throttled
                if ($resized) {$dirty=$true}
                if ($scene.IdleGesture -and -not $NoAnimation -and -not $paused -and -not $resizePaused) {
                    $pose=Get-MioIdleGesturePose $scene.IdleGesture ($timer.ElapsedMilliseconds-400)
                    if ($pose -cne $script:UiPoseOverride) {$dirty=$true}
                }
                if ($dirty -or ($periodic -and -not $paused -and -not $resizePaused -and $draw.ElapsedMilliseconds -ge $frameInterval)) {
                    $draw.Restart()
                    $script:UiDemoPaused=($paused -or $resizePaused)
                    $script:UiSay=Get-MioPreviewControls $paused $resizePaused
                    Set-MioPreviewProgress $scene $timer.ElapsedMilliseconds $duration
                    $script:UiDemoNeedsSpace=$false
                    if ($scene.Menu) {
                        $rows=@(Get-MioPreviewMenuRows $scene)
                        $anchor=-1L; if ($resized) {$anchor=$pageAnchor}
                        $page=Get-MioPreviewMenuPage $rows $pageIndex $anchor
                        $pageIndex=$page.Index; $pageCount=$page.Count
                        # Compact views have no page anchor. Retain the last valid
                        # reading position until the paged layout returns.
                        if ($page.Anchor -ge 0) {$pageAnchor=$page.Anchor}
                        $script:UiDemoPage=$pageIndex+1; $script:UiDemoPageCount=$pageCount
                        Draw-MenuPanel ('DEMO / '+$scene.Stage) $page.Rows $script:UiSay '' -1 $scene.Mood -DefaultRows $page.DefaultRows
                    } else {Draw-DisplayPanel -Force}
                    $wasResizePaused=$resizePaused
                    $resizePaused=[bool]$script:UiDemoNeedsSpace
                    if ($paused -or $resizePaused) {$timer.Stop();$script:Clock.Stop()}
                    else {$timer.Start();$script:Clock.Start()}
                    $dirty=($wasResizePaused -ne $resizePaused)
                }
                if (-not $paused -and -not $resizePaused -and $timer.ElapsedMilliseconds -ge $duration) {
                    if ($pageIndex+1 -lt $pageCount) {$next=$index; $requestedPage=$pageIndex+1}
                    break
                }
                if ([Console]::KeyAvailable) {
                    $key=[Console]::ReadKey($true)
                    if ($key.Key -in [ConsoleKey]::B,[ConsoleKey]::Q,[ConsoleKey]::Escape) {return}
                    if ($key.Key -eq [ConsoleKey]::Spacebar) {
                        $paused=-not $paused
                        if ($paused -or $resizePaused) {$timer.Stop();$script:Clock.Stop()} else {$timer.Start();$script:Clock.Start()}
                        $script:UiDemoPaused=$paused; $dirty=$true
                    }
                    elseif ($key.Key -in [ConsoleKey]::N,[ConsoleKey]::RightArrow,[ConsoleKey]::Enter) {
                        if ($pageIndex+1 -lt $pageCount) {$next=$index; $requestedPage=$pageIndex+1}
                        break
                    }
                    elseif ($key.Key -in [ConsoleKey]::P,[ConsoleKey]::LeftArrow) {
                        if ($pageIndex -gt 0) {$next=$index; $requestedPage=$pageIndex-1}
                        else {$next=[Math]::Max(0,$index-1); if ($index -gt 0) {$requestedPage=-1}}
                        break
                    }
                    elseif ($key.Key -eq [ConsoleKey]::R) {$next=0; $script:Clock.Restart();if ($paused) {$script:Clock.Stop()};break}
                    elseif ($key.Key -eq [ConsoleKey]::E) {Switch-DisplayEffect; $dirty=$true}
                } else {
                    Wait-DisplayFrame 30
                }
            }
            Clear-DisplayPanel; $index=$next
        }
    } finally {
        Clear-DisplayPanel
        foreach ($name in $saved.Keys) {Set-Variable -Scope Script -Name $name -Value $saved[$name]}
    }
}

function Show-ClosingPanel([int]$RemovalFailures=0) {
    Complete-PreparationProgress
    $script:UiSystem='PREPARATION COMPLETE'; $script:UiGame='Prepared outputs await final verification'
    $script:UiStage='Preparation finished'; $script:UiDetail='Waiting for final verification and saving to DST.'; $script:UiPercent=100
    $script:UiMood='happy'; $script:UiSay='Files prepared. Waiting for final verification.'
    if ($script:Failed -gt 0) {$script:UiMood='oops'; $script:UiSay='Preparation finished with errors. Review the results.'}
    elseif ($RemovalFailures -gt 0) {$script:UiMood='oops'; $script:UiSay='Source cleanup needs attention. Review the warnings.'}
    elseif ($script:ReportProblem) {$script:UiMood='oops'; $script:UiSay='A temporary log or report could not be saved. Check warnings.'}
    elseif ($script:Ok -eq 0) {$script:UiMood='wait'; $script:UiSay='No files prepared. Source files are unchanged.'}
    Draw-DisplayPanel -Force
    # Leave the last panel visible above the summary instead of erasing it.
    $script:UiRows=0
}
