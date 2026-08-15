# 豆包桌面版（进程名 Doubao.exe，自动定位，与安装路径无关）驱动脚本 v2
# 全程 UIA + Win32 消息注入，不移动鼠标、不抢焦点，不影响用户办公。
#
# v2 相比 v1 的增强（见 CHANGELOG.md）：
#   1) 所有动作自动前置 ensure：豆包未运行自动拉起；窗口最小化/在主屏外/副屏时自动移回主屏并最大化
#   2) 新增探测动作 probe-windows / probe-buttons / probe-menu：教 agent 按"锚点→候选→验证→降级"方法链自己找控件
#   3) 修复 v1 实测 bug：附件菜单项从 RootElement 搜、文件对话框轮询等待、WM_SETTEXT 字符串封送（SendMessageStr）、附件按钮候选逐个验证
#
# 用法（在 pwsh 中执行，脚本路径按实际 skill 目录拼接）:
#   & '<skill目录>\scripts\doubao.ps1' -Action ensure                  # 手动触发：启动/归位/最大化（其他动作默认自动执行）
#   & '<skill目录>\scripts\doubao.ps1' -Action status
#   & '<skill目录>\scripts\doubao.ps1' -Action newchat
#   & '<skill目录>\scripts\doubao.ps1' -Action mode -Mode 快速          # 快速 | 专家 | 工作任务 Auto | 工作任务 Turbo | 工作任务 Pro
#   & '<skill目录>\scripts\doubao.ps1' -Action send -Text '你好' -WaitSec 20 -MaxLines 8
#   & '<skill目录>\scripts\doubao.ps1' -Action send -Text '看图说话' -Files 'C:\a.png','C:\b.txt'
#   & '<skill目录>\scripts\doubao.ps1' -Action read -MaxLines 10
#   & '<skill目录>\scripts\doubao.ps1' -Action wait -WaitSec 60         # 等待回复生成完毕
#   & '<skill目录>\scripts\doubao.ps1' -Action extract -OutDir 'C:\out' -MinutesBack 10 -MinKB 100  # 从缓存提取最近生成的原文件
#   & '<skill目录>\scripts\doubao.ps1' -Action probe-windows            # 诊断：豆包全部顶层窗口 + 主屏信息（不需要窗口就位）
#   & '<skill目录>\scripts\doubao.ps1' -Action probe-buttons            # 诊断：输入框位置 + 全部按钮（名称/矩形/模式/展开状态）
#   & '<skill目录>\scripts\doubao.ps1' -Action probe-menu -ButtonAt '584,930'   # 诊断：展开指定坐标的按钮并列出可见菜单项

param(
    [ValidateSet('status','newchat','mode','send','attach','read','wait','extract','ensure','probe-windows','probe-buttons','probe-menu')]
    [string]$Action = 'status',
    [string]$Text = '',
    [string[]]$Files = @(),
    [string]$Mode = '',
    [int]$WaitSec = 0,
    [int]$MaxLines = 20,
    [switch]$NewChat,
    [string]$OutDir = '',
    [int]$MinutesBack = 15,
    [int]$MinKB = 100,
    [string]$ButtonAt = ''
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
if (-not ('W32Doubao' -as [type])) {
    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class W32Doubao {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    public delegate bool EnumWinProc(IntPtr h, IntPtr l);
    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }

    // SendMessage 两个重载拆成不同名字，避免 PowerShell 重载解析歧义（v1 曾把 string 当 IntPtr 传导致 WM_SETTEXT 失败）
    // 注意：自定义方法名必须配 EntryPoint 指明 user32 里的真实入口
    [DllImport("user32.dll", EntryPoint="SendMessageW")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] public static extern IntPtr SendMessageStr(IntPtr h, uint m, IntPtr w, string l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWinProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int cx, int cy, bool repaint);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO mi);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
'@
}

# ---------- 窗口就位保障（v2 新增） ----------

function Get-DoubaoMainHwnd {
    $p = Get-Process -Name Doubao -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($p) { return [IntPtr]$p.MainWindowHandle }
    return [IntPtr]::Zero
}

function Find-DoubaoExe {
    $candidates = @()
    foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) {
            $candidates += (Join-Path $base 'Doubao\Doubao.exe')
            $candidates += (Join-Path $base 'Programs\Doubao\Doubao.exe')
        }
    }
    # 注册表卸载信息里的安装路径
    foreach ($k in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*豆包*' } | ForEach-Object {
            if ($_.InstallLocation) { $candidates += (Join-Path $_.InstallLocation 'Doubao.exe') }
            if ($_.DisplayIcon -and $_.DisplayIcon -like '*.exe*') { $candidates += ($_.DisplayIcon -replace ',.*$','') }
        }
    }
    # 开始菜单快捷方式
    foreach ($d in @((Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'), (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'))) {
        if (Test-Path $d) {
            $candidates += (Get-ChildItem $d -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*豆包*' } | ForEach-Object { $_.FullName })
        }
    }
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Get-PrimaryWorkArea {
    $script:primaryWork = $null
    $cb = [W32Doubao+MonitorEnumProc]{
        param($hMon, $hdc, [ref]$rc, $l)
        $mi = New-Object W32Doubao+MONITORINFO
        $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
        if ([W32Doubao]::GetMonitorInfo($hMon, [ref]$mi)) {
            if ($mi.dwFlags -band 1) { $script:primaryWork = $mi.rcWork }  # MONITORINFOF_PRIMARY = 1
        }
        return $true
    }
    [W32Doubao]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $cb, [IntPtr]::Zero) | Out-Null
    if (-not $script:primaryWork) { return [pscustomobject]@{ L = 0; T = 0; R = 1920; B = 1080 } }
    return $script:primaryWork
}

function Ensure-Doubao {
    # 1) 进程检测 + 自动启动（v2 新增：v1 只会报错让用户手动开）
    $hwnd = Get-DoubaoMainHwnd
    if ($hwnd -eq [IntPtr]::Zero) {
        $exe = Find-DoubaoExe
        if (-not $exe) { throw '豆包未运行且未找到 Doubao.exe（请手动启动并登录豆包桌面版，或告知安装路径）' }
        Start-Process -FilePath $exe
        Write-Output "已自动启动豆包: $exe"
        $deadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $deadline -and $hwnd -eq [IntPtr]::Zero) {
            Start-Sleep -Seconds 2
            $hwnd = Get-DoubaoMainHwnd
        }
        if ($hwnd -eq [IntPtr]::Zero) { throw '豆包已启动但 45 秒内未出现主窗口（可能停留在登录/更新界面）' }
    }
    # 2) 窗口就位（v2 新增：修复实测中窗口被移到屏幕外 x=-1928 导致 UIA 坐标全负的问题）
    if ([W32Doubao]::IsIconic($hwnd)) { [W32Doubao]::ShowWindow($hwnd, 9) | Out-Null; Start-Sleep -Milliseconds 800 }  # SW_RESTORE
    $wa = Get-PrimaryWorkArea
    $r = New-Object W32Doubao+RECT
    [W32Doubao]::GetWindowRect($hwnd, [ref]$r) | Out-Null
    $cx = ($r.L + $r.R) / 2.0; $cy = ($r.T + $r.B) / 2.0
    $onPrimary = ($cx -ge $wa.L -and $cx -lt $wa.R -and $cy -ge $wa.T -and $cy -lt $wa.B)
    if (-not $onPrimary) {
        $w = [Math]::Min(($wa.R - $wa.L), 1600); $h = [Math]::Min(($wa.B - $wa.T), 1000)
        [W32Doubao]::MoveWindow($hwnd, $wa.L + 40, $wa.T + 20, $w, $h, $true) | Out-Null
        Start-Sleep -Milliseconds 600
        Write-Output ("窗口不在主屏，已移回主屏工作区: {0},{1} {2}x{3}" -f ($wa.L + 40), ($wa.T + 20), $w, $h)
    }
    [W32Doubao]::ShowWindow($hwnd, 3) | Out-Null  # SW_MAXIMIZE：放大化保证全可见，副屏场景也归位
    Start-Sleep -Milliseconds 800
    return $hwnd
}

# ---------- UIA 基础 ----------

function Get-MainWindow {
    $hwnd = Get-DoubaoMainHwnd
    if ($hwnd -eq [IntPtr]::Zero) { throw '豆包未运行或没有主窗口（请先启动并登录豆包桌面版）' }
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NativeWindowHandleProperty, [int]$hwnd)
    $win = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
    if (-not $win) { throw '找不到豆包主窗口的 UIA 元素（无障碍树未唤醒，重跑一次）' }
    return $win
}

function Wake-Tree($win) {
    # 向窗口发 WM_GETOBJECT 唤醒 Chromium 无障碍树（否则树里只有窗口按钮）
    [W32Doubao]::SendMessage([IntPtr]$win.Current.NativeWindowHandle, 0x003D, [IntPtr]::Zero, [IntPtr]0xFFFFFFFC) | Out-Null
    # 树构建需 ≥2s，短了会拿到不完整子树（部分控件缺失）；每次 FindAll 前都应重新唤醒
    Start-Sleep -Milliseconds 2000
}

function Get-All($win) {
    return $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
}

function Get-WindowPhysRect($win) {
    $r = New-Object W32Doubao+RECT
    $h = [IntPtr]$win.Current.NativeWindowHandle
    [W32Doubao]::GetWindowRect($h, [ref]$r) | Out-Null
    return $r
}

function Find-InputEdit($all) {
    # 聊天输入框：支持 ValuePattern 的 Edit 中，底部最宽的那个（不依赖占位符文本，工作任务模式下占位符不同）
    $best = $null
    foreach ($e in $all) {
        if ($e.Current.ControlType.ProgrammaticName -ne 'ControlType.Edit') { continue }
        try { $null = $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern) } catch { continue }
        $r = $e.Current.BoundingRectangle
        if ($r.Width -gt (300 * $script:scale) -and $r.Height -gt (20 * $script:scale)) {
            if (-not $best -or $r.Width -gt $best.Current.BoundingRectangle.Width) { $best = $e }
        }
    }
    if (-not $best) { throw '找不到消息输入框（无障碍树可能未唤醒，重试或先跑 -Action status）' }
    return $best
}

function Invoke-SendButton($all, $edit) {
    # 发送按钮 = 输入框右下方的无名 Button；同坐标常有 Invoke/ExpandCollapse 两个变体，必须选支持 Invoke 的
    $r = $edit.Current.BoundingRectangle
    foreach ($e in $all) {
        if ($e.Current.ControlType.ProgrammaticName -ne 'ControlType.Button') { continue }
        $br = $e.Current.BoundingRectangle
        if ($br.X -gt ($r.X + $r.Width - (160 * $script:scale)) -and $br.Y -gt ($r.Y + (20 * $script:scale)) -and $br.Y -lt ($r.Y + (140 * $script:scale))) {
            if (($e.GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName }) -contains 'InvokePatternIdentifiers.Pattern') {
                $e.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                return $true
            }
        }
    }
    return $false
}

# 菜单弹层是独立的顶层窗口，挂在 RootElement 下、属于豆包进程。
# 搜索范围 = 豆包进程的所有顶层窗口子树（v2.1 修复：遍历整个桌面树 FindAll(Descendants) 会被无响应的 provider 卡死）
function Get-PopupMenuItems($win) {
    $p = Get-Process -Name Doubao -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { return ,@() }
    $pcond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $p.Id)
    $mic = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem)
    $items = @()
    foreach ($w in [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $pcond)) {
        try { foreach ($m in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $mic)) { $items += $m } } catch {}
    }
    return ,$items
}

# 找可见菜单项（v2 修复：v1 只在主窗口内搜，弹层挂在 RootElement 下导致找不到）
# 过滤条件：名字精确匹配 + 矩形中心落在豆包窗口物理矩形(外扩 200px)内，排除其他隐藏弹层的同名项
function Find-VisibleMenuItem($win, [string]$name) {
    $wr = Get-WindowPhysRect $win
    $found = $null
    foreach ($m in (Get-PopupMenuItems $win)) {
        if ($m.Current.Name -ne $name) { continue }
        $r = $m.Current.BoundingRectangle
        if ($r.Width -le 0 -or $r.Height -le 0) { continue }
        $mcx = $r.X + $r.Width / 2.0; $mcy = $r.Y + $r.Height / 2.0
        if ($mcx -ge ($wr.L - 200) -and $mcx -le ($wr.R + 200) -and $mcy -ge ($wr.T - 200) -and $mcy -le ($wr.B + 200)) {
            $found = $m; break
        }
    }
    return $found
}

function Get-ModeChip($all, [string]$mode) {
    foreach ($e in $all) {
        if ($e.Current.ControlType.ProgrammaticName -ne 'ControlType.Button') { continue }
        if ($e.Current.Name -eq $mode) { return $e }
    }
    return $null
}

function Set-Mode($win, [string]$mode) {
    Wake-Tree $win
    $all = Get-All $win
    if (Get-ModeChip $all $mode) { Write-Output "模式已是 $mode"; return }
    $chip = $null
    foreach ($e in $all) {
        if ($e.Current.ControlType.ProgrammaticName -ne 'ControlType.Button') { continue }
        if ($e.Current.Name -in @('快速','专家','工作任务 Auto','工作任务 Turbo','工作任务 Pro')) { $chip = $e; break }
    }
    if (-not $chip) { throw '找不到模式切换芯片' }
    try { $chip.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() } catch {}
    Start-Sleep -Milliseconds 700
    $item = Find-VisibleMenuItem $win $mode
    if (-not $item) {
        foreach ($e in (Get-All $win)) {
            if ($e.Current.ControlType.ProgrammaticName -eq 'ControlType.MenuItem' -and $e.Current.Name -like "$mode*") { $item = $e; break }
        }
    }
    if (-not $item) { throw "模式菜单里找不到 '$mode'（下拉可能没展开，重试一次；或先 probe-menu 看实际菜单项）" }
    $item.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Seconds 4
    Write-Output ("模式切换完成: " + $(if (Get-ModeChip (Get-All $win) $mode) { $mode } else { "$mode (未确认到芯片变化，多半已生效)" }))
}

function New-Chat($win) {
    Wake-Tree $win
    $label = $null
    foreach ($e in (Get-All $win)) {
        if ($e.Current.ControlType.ProgrammaticName -eq 'ControlType.Text' -and $e.Current.Name -eq '新对话') { $label = $e; break }
    }
    if (-not $label) { throw '找不到侧栏「新对话」按钮（先 probe-buttons 看侧栏实际按钮）' }
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $p = $walker.GetParent($label)
    $depth = 0
    while ($p -and $depth -lt 4) {
        if (($p.GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName }) -contains 'InvokePatternIdentifiers.Pattern') {
            $p.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            Start-Sleep -Seconds 2
            return
        }
        $p = $walker.GetParent($p); $depth++
    }
    throw '「新对话」按钮不可调用'
}

function Send-Text($win, [string]$text) {
    Wake-Tree $win
    $edit = Find-InputEdit (Get-All $win)
    $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text)
    Start-Sleep -Milliseconds 1200
    if (-not (Invoke-SendButton (Get-All $win) $edit)) { throw '找不到可调用的发送按钮（文字可能已写入但未发送）' }
}

function Wait-VisibleDialog([string]$class, [int]$timeoutMs) {
    # Win32 轮询找可见对话框（v2 修复：v1 固定 sleep 2s 后找不到就报错；对话框弹出时机不定）
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        $script:foundDlg = [IntPtr]::Zero
        $cbw = [W32Doubao+EnumWinProc]{
            param($h, $l)
            $cls = New-Object System.Text.StringBuilder 128
            [W32Doubao]::GetClassName($h, $cls, 128) | Out-Null
            if ($cls.ToString() -eq $class -and [W32Doubao]::IsWindowVisible($h)) { $script:foundDlg = $h }
            return $true
        }
        [W32Doubao]::EnumWindows($cbw, [IntPtr]::Zero) | Out-Null
        if ($script:foundDlg -ne [IntPtr]::Zero) { return $script:foundDlg }
        Start-Sleep -Milliseconds 500
    }
    return [IntPtr]::Zero
}

function Close-ExistingFileDialogs {
    # 上次运行崩溃/失败可能留下未关闭的 #32770 文件对话框；其上传请求已超时，完成它也不会挂载文件，
    # 反而会污染本次流程（实测：复用残留对话框 → 附件未挂载）。上传前全部 WM_CLOSE 关掉。
    $script:fdlist = New-Object System.Collections.Generic.List[IntPtr]
    $cbw = [W32Doubao+EnumWinProc]{
        param($h, $l)
        $cls = New-Object System.Text.StringBuilder 128
        [W32Doubao]::GetClassName($h, $cls, 128) | Out-Null
        if ($cls.ToString() -eq '#32770' -and [W32Doubao]::IsWindowVisible($h)) { $script:fdlist.Add($h) }
        return $true
    }
    [W32Doubao]::EnumWindows($cbw, [IntPtr]::Zero) | Out-Null
    foreach ($d in $script:fdlist) {
        [W32Doubao]::SendMessage($d, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null  # WM_CLOSE
        Write-Output ("已关闭残留文件对话框 h=$d")
    }
    if ($script:fdlist.Count -gt 0) { Start-Sleep -Seconds 1 }
}

function Add-Attachments($win, [string[]]$files) {
    # 最多尝试两次：第一次失败常见原因是残留对话框污染或附件条挂载慢
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try { Close-ExistingFileDialogs } catch {}
        $ok = Attempt-AttachOnce $win $files
        if ($ok) { Write-Output '附件已确认挂载到输入框'; return }
        Write-Output "第 $attempt 次挂载未确认到附件条，重试一次"
    }
    Write-Output '警告：两次尝试后附件条仍未确认，图片可能没挂上——不要继续发消息，先人工检查豆包输入框'
}

function Attempt-AttachOnce($win, [string[]]$files) {
    Wake-Tree $win
    $all = Get-All $win
    $edit = Find-InputEdit $all
    $er = $edit.Current.BoundingRectangle
    # 候选收集：输入框左下方、支持 ExpandCollapse 的 Button（可能有多个，逐个验证）
    $cands = @()
    foreach ($e in $all) {
        if ($e.Current.ControlType.ProgrammaticName -ne 'ControlType.Button') { continue }
        $br = $e.Current.BoundingRectangle
        if ($br.X -gt ($er.X - (120 * $script:scale)) -and $br.X -lt $er.X -and $br.Y -gt ($er.Y + (15 * $script:scale)) -and $br.Y -lt ($er.Y + (150 * $script:scale))) {
            if (($e.GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName }) -contains 'ExpandCollapsePatternIdentifiers.Pattern') { $cands += $e }
        }
    }
    if ($cands.Count -eq 0) { throw '输入框左下方找不到附件(+)按钮候选（先 probe-buttons 核对实际布局）' }
    # 逐个候选"展开→验证菜单"，验证标准：展开后菜单里出现「上传文件或图片」（v2 修复：v1 找到第一个就点，曾误点成用户菜单按钮）
    $plus = $null
    foreach ($c in $cands) {
        try {
            $ecp = $c.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
            if ($ecp.Current.ExpandCollapseState -eq [System.Windows.Automation.ExpandCollapseState]::Expanded) { $ecp.Collapse(); Start-Sleep -Milliseconds 500 }
            try { $ecp.Expand() } catch {}  # Expand 偶尔抛 "Could not open the process token"，菜单可能照样展开，继续验证
            Start-Sleep -Milliseconds 1200
            $up = Find-VisibleMenuItem $win '上传文件或图片'
            if ($up) { $plus = $c; break }
            try { $ecp.Collapse() } catch {}  # 验证失败，收起换下一个候选
            Start-Sleep -Milliseconds 400
        } catch {}
    }
    if (-not $plus) { throw '附件(+)按钮候选均未通过验证（展开后无「上传文件或图片」菜单项；用 probe-menu 检查菜单内容，或豆包改版需更新验证标准）' }
    $up = Find-VisibleMenuItem $win '上传文件或图片'
    $up.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    # 文件对话框：Win32 轮询最多 12 秒（v2 修复：v1 固定 sleep 2s）
    $dlg = Wait-VisibleDialog '#32770' 12000
    if ($dlg -eq [IntPtr]::Zero) { throw '文件对话框 12 秒内未出现（检查豆包是否弹了别的界面；probe-windows 可看顶层窗口）' }
    $script:dlgEdit = [IntPtr]::Zero
    $script:dlgBtn = [IntPtr]::Zero
    $cb = [W32Doubao+EnumProc]{
        param($h, $l)
        $cls = New-Object System.Text.StringBuilder 128
        [W32Doubao]::GetClassName($h, $cls, 128) | Out-Null
        $id = [W32Doubao]::GetDlgCtrlID($h)
        if ($cls.ToString() -eq 'Edit' -and $id -eq 1148) { $script:dlgEdit = $h }
        if ($cls.ToString() -eq 'Button' -and $id -eq 1) { $script:dlgBtn = $h }
        return $true
    }
    [W32Doubao]::EnumChildWindows($dlg, $cb, [IntPtr]::Zero) | Out-Null
    if ($script:dlgEdit -eq [IntPtr]::Zero -or $script:dlgBtn -eq [IntPtr]::Zero) { throw '文件对话框控件未找到（需要 ctrlid=1148 的文件名框和 ctrlid=1 的打开按钮；若豆包换了对话框样式，用 probe-windows + EnumChildWindows 排查）' }
    # 多文件：'"路径1" "路径2"'（必须带引号）；SendMessageStr 专用 string 重载（v2 修复 WM_SETTEXT 封送）
    $quoted = ($files | ForEach-Object { '"' + $_.Trim('"') + '"' }) -join ' '
    [W32Doubao]::SendMessageStr($script:dlgEdit, 0x000C, [IntPtr]::Zero, $quoted) | Out-Null
    Start-Sleep -Milliseconds 800
    [W32Doubao]::SendMessage($script:dlgBtn, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    # 等对话框关闭，确认文件已被接受
    $deadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $deadline -and [W32Doubao]::IsWindowVisible($dlg)) { Start-Sleep -Milliseconds 500 }
    if ([W32Doubao]::IsWindowVisible($dlg)) { throw '点击「打开」后文件对话框未关闭（文件名可能没写进去，检查路径是否存在）' }
    # 验证附件条挂载（v2 新增：反馈真实结果而不是盲目报成功）
    Start-Sleep -Seconds 1
    return (Test-AttachmentChip $win $edit $files)
}

function Test-AttachmentChip($win, $edit, $files) {
    Wake-Tree $win
    $all = Get-All $win
    $er = $edit.Current.BoundingRectangle
    foreach ($f in $files) {
        $base = [IO.Path]::GetFileName($f)
        foreach ($e in $all) {
            $nm = $e.Current.Name
            if (-not $nm) { continue }
            $r = $e.Current.BoundingRectangle
            $inZone = ($r.X -gt ($er.X - 400)) -and ($r.Y -gt ($er.Y - 350)) -and ($r.Y -lt $er.Y)
            if (-not $inZone) { continue }
            if ($nm -like "*$base*") { return $true }
            if ($nm -eq 'image' -and $e.Current.ControlType.ProgrammaticName -eq 'ControlType.Image') { return $true }
        }
    }
    return $false
}

function Get-Messages($all, $edit, $maxLines) {
    $er = $edit.Current.BoundingRectangle
    $left = $er.X - (50 * $script:scale)
    $items = @()
    foreach ($e in $all) {
        $ct = $e.Current.ControlType.ProgrammaticName
        if ($ct -notin @('ControlType.Text','ControlType.ListItem','ControlType.Hyperlink')) { continue }
        $nm = $e.Current.Name
        if (-not $nm) { continue }
        $r = $e.Current.BoundingRectangle
        if ($r.X -lt $left -or $r.Y -lt (80 * $script:scale) -or $r.Y -gt ($er.Y - (10 * $script:scale))) { continue }
        $items += ,[pscustomobject]@{ Y = $r.Y; X = $r.X; Text = $nm }
    }
    return @($items | Sort-Object Y, X | Select-Object -Last $maxLines)
}

function Wait-ReplyStable($win, $edit, $timeoutSec) {
    # 轮询消息区文本签名，连续两轮不变即认为生成结束
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $prev = ''
    $stable = 0
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $msgs = Get-Messages (Get-All $win) $edit 200
        $sig = ($msgs | ForEach-Object { $_.Text }) -join '|'
        if ($sig -and $sig -eq $prev) { $stable++; if ($stable -ge 2) { return $true } } else { $stable = 0 }
        $prev = $sig
    }
    return $false
}

# ---------- 探测动作（v2 新增：方法链的"寻找工具"） ----------

function Show-ProbeWindows {
    $wa = Get-PrimaryWorkArea
    Write-Output ("主屏工作区: {0},{1} - {2},{3}" -f $wa.L, $wa.T, $wa.R, $wa.B)
    $script:probePids = @((Get-Process -Name Doubao -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }))
    if ($script:probePids.Count -eq 0) { Write-Output '（无 Doubao 进程）'; return }
    Write-Output '豆包进程顶层窗口（hwnd | class | title | rect | visible | iconic）:'
    $script:probeLines = New-Object System.Collections.Generic.List[string]
    $cb = [W32Doubao+EnumWinProc]{
        param($h, $l)
        $pid2 = 0
        [W32Doubao]::GetWindowThreadProcessId($h, [ref]$pid2) | Out-Null
        if ($script:probePids -contains [int]$pid2) {
            $cls = New-Object System.Text.StringBuilder 128
            [W32Doubao]::GetClassName($h, $cls, 128) | Out-Null
            $txt = New-Object System.Text.StringBuilder 128
            [W32Doubao]::GetWindowText($h, $txt, 128) | Out-Null
            $r = New-Object W32Doubao+RECT
            [W32Doubao]::GetWindowRect($h, [ref]$r) | Out-Null
            $script:probeLines.Add(("  h=$h class='$($cls.ToString())' title='$($txt.ToString())' rect=$($r.L),$($r.T),$($r.R),$($r.B) visible=$([W32Doubao]::IsWindowVisible($h)) iconic=$([W32Doubao]::IsIconic($h))"))
        }
        return $true
    }
    [W32Doubao]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    $script:probeLines | ForEach-Object { Write-Output $_ }
    $hwnd = Get-DoubaoMainHwnd
    if ($hwnd -ne [IntPtr]::Zero) {
        $r = New-Object W32Doubao+RECT
        [W32Doubao]::GetWindowRect($hwnd, [ref]$r) | Out-Null
        $dpi = 0
        try { $dpi = [W32Doubao]::GetDpiForWindow($hwnd) } catch {}
        $cx = ($r.L + $r.R) / 2.0; $cy = ($r.T + $r.B) / 2.0
        Write-Output ("主窗口 h=$hwnd rect=$($r.L),$($r.T),$($r.R),$($r.B) dpi=$dpi 中心是否在主屏: $($cx -ge $wa.L -and $cx -lt $wa.R -and $cy -ge $wa.T -and $cy -lt $wa.B)")
    }
}

function Show-ProbeButtons($win) {
    Wake-Tree $win
    $all = Get-All $win
    $edit = $null
    try { $edit = Find-InputEdit $all } catch {}
    if ($edit) {
        $r = $edit.Current.BoundingRectangle
        Write-Output ("输入框(锚点): {0},{1},{2},{3}" -f $r.X, $r.Y, $r.Width, $r.Height)
    } else {
        Write-Output '输入框: 未找到（树可能未唤醒，重跑一次）'
    }
    Write-Output '按钮清单（Name | x,y,w,h | 模式 | 展开状态）:'
    $n = 0
    foreach ($e in $all) {
        if ($e.Current.ControlType.ProgrammaticName -ne 'ControlType.Button') { continue }
        $n++
        $r = $e.Current.BoundingRectangle
        $pats = (($e.GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName -replace 'PatternIdentifiers\.Pattern','' }) -join '+')
        $state = ''
        try { $ec = $e.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern); $state = $ec.Current.ExpandCollapseState.ToString() } catch {}
        Write-Output ("  [{0}] '{1}' | {2},{3},{4},{5} | {6} | {7}" -f $n, $e.Current.Name, $r.X, $r.Y, $r.Width, $r.Height, $pats, $state)
    }
    Write-Output "共 $n 个按钮。选择候选时优先看「与锚点的相对位置 + 模式」，点击前用 probe-menu 验证菜单内容。"
}

function Show-ProbeMenu($win, [string]$buttonAt) {
    $xy = $buttonAt -split ','
    if ($xy.Count -lt 2) { throw '需要 -ButtonAt x,y（取自 probe-buttons 输出的按钮矩形内任一点）' }
    $x = [int]$xy[0]; $y = [int]$xy[1]
    Wake-Tree $win
    $btn = $null
    foreach ($e in (Get-All $win)) {
        if ($e.Current.ControlType.ProgrammaticName -ne 'ControlType.Button') { continue }
        $r = $e.Current.BoundingRectangle
        if ($x -ge $r.X -and $x -lt ($r.X + $r.Width) -and $y -ge $r.Y -and $y -lt ($r.Y + $r.Height)) { $btn = $e; break }
    }
    if (-not $btn) { throw '该坐标处没有按钮（界面可能变了，先重跑 probe-buttons 取最新坐标）' }
    try { $ecp = $btn.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern) } catch { throw '该按钮不支持 ExpandCollapse，无法展开（换一个候选）' }
    Write-Output ("展开按钮: '{0}' ({1},{2},{3},{4})" -f $btn.Current.Name, $btn.Current.BoundingRectangle.X, $btn.Current.BoundingRectangle.Y, $btn.Current.BoundingRectangle.Width, $btn.Current.BoundingRectangle.Height)
    if ($ecp.Current.ExpandCollapseState -eq [System.Windows.Automation.ExpandCollapseState]::Expanded) { $ecp.Collapse(); Start-Sleep -Milliseconds 500 }
    try { $ecp.Expand() } catch {}
    Start-Sleep -Milliseconds 1200
    $wr = Get-WindowPhysRect $win
    $shown = 0
    foreach ($m in (Get-PopupMenuItems $win)) {
        $r = $m.Current.BoundingRectangle
        if ($r.Width -le 0 -or $r.Height -le 0 -or -not $m.Current.Name) { continue }
        $mcx = $r.X + $r.Width / 2.0; $mcy = $r.Y + $r.Height / 2.0
        if ($mcx -ge ($wr.L - 300) -and $mcx -le ($wr.R + 300) -and $mcy -ge ($wr.T - 300) -and $mcy -le ($wr.B + 300)) {
            $shown++
            Write-Output ("  菜单项 '{0}' | {1},{2},{3},{4}" -f $m.Current.Name, $r.X, $r.Y, $r.Width, $r.Height)
        }
    }
    if ($shown -eq 0) { Write-Output '（未发现可见菜单项：可能展开失败或菜单挂载较慢，重跑一次）' }
    try { $ecp.Collapse() } catch {}  # 探测完毕收起菜单，不留垃圾状态
}

try {
    # extract 不需要窗口/登录状态：直接从磁盘缓存提取，先短路处理
    if ($Action -eq 'extract') {
        if (-not $OutDir) { throw '需要 -OutDir（输出目录）' }
        if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
        $cacheDir = Join-Path $env:LOCALAPPDATA 'Doubao\User Data\Default\Cache\Cache_Data'
        if (-not (Test-Path $cacheDir)) { throw '找不到豆包缓存目录' }
        $since = (Get-Date).AddMinutes(-$MinutesBack)
        $sigs = @(
            @{N='PNG';  B=[byte[]](0x89,0x50,0x4E,0x47); Ext='.png'},
            @{N='JPEG'; B=[byte[]](0xFF,0xD8,0xFF); Ext='.jpg'},
            @{N='WEBP'; B=[byte[]](0x52,0x49,0x46,0x46); Ext='.webp'},
            @{N='DOCX'; B=[byte[]](0x50,0x4B,0x03,0x04); Ext='.zip'},
            @{N='DOC';  B=[byte[]](0xD0,0xCF,0x11,0xE0); Ext='.doc'}
        )
        $cnt = 0
        foreach ($f in (Get-ChildItem $cacheDir -File | Where-Object { $_.LastWriteTime -gt $since -and $_.Length -gt ($MinKB * 1KB) } | Sort-Object LastWriteTime)) {
            $bytes = $null
            try {
                $fs = [IO.File]::Open($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
                try { $bytes = New-Object byte[] $fs.Length; $fs.Read($bytes, 0, $bytes.Length) | Out-Null } finally { $fs.Dispose() }
            } catch { continue }
            $head = New-Object byte[] 16
            [Array]::Copy($bytes, 0, $head, 0, [Math]::Min(16, $bytes.Length))
            foreach ($s in $sigs) {
                $match = $true
                for ($i = 0; $i -lt [Math]::Min(4, $s.B.Length); $i++) { if ($head[$i] -ne $s.B[$i]) { $match = $false; break } }
                if ($s.N -eq 'WEBP' -and $match) {
                    $w = [Text.Encoding]::ASCII.GetBytes('WEBP')
                    for ($i = 0; $i -lt 4; $i++) { if ($head[8 + $i] -ne $w[$i]) { $match = $false; break } }
                }
                if ($match) {
                    $dest = Join-Path $OutDir ("doubao-{0:yyyyMMdd-HHmmss}-{1}{2}" -f $f.LastWriteTime, $s.N, $s.Ext)
                    [IO.File]::WriteAllBytes($dest, $bytes)
                    Write-Output ("提取: {0} -> {1} ({2:N0} bytes)" -f $s.N, $dest, $bytes.Length)
                    $cnt++
                    break
                }
            }
        }
        Write-Output ("共提取 {0} 个文件到 {1}" -f $cnt, $OutDir)
        exit 0
    }

    # probe-windows 是纯诊断动作：不做 ensure（ensure 本身出问题时也要能诊断）
    if ($Action -eq 'probe-windows') {
        Show-ProbeWindows
        exit 0
    }

    # 其余所有动作自动前置 ensure：启动/归位主屏/最大化（v2 新增）
    $null = Ensure-Doubao

    $win = Get-MainWindow
    # 运行时 DPI 缩放探测：所有像素阈值均乘 $scale，兼容任意 DPI/多显示器（UIA 坐标始终是物理像素）
    $script:scale = 1.0
    try {
        $dpi = [W32Doubao]::GetDpiForWindow([IntPtr]$win.Current.NativeWindowHandle)
        if ($dpi -and $dpi -gt 0) { $script:scale = $dpi / 96.0 }
    } catch {}
    if ($script:scale -lt 0.5 -or $script:scale -gt 4) { $script:scale = 1.0 }
    Wake-Tree $win
    $all = Get-All $win
    $edit = $null
    try { $edit = Find-InputEdit $all } catch {}

    switch ($Action) {
        'ensure' {
            $r = Get-WindowPhysRect $win
            $sb = New-Object System.Text.StringBuilder 128
            [W32Doubao]::GetWindowText([IntPtr]$win.Current.NativeWindowHandle, $sb, 128) | Out-Null
            Write-Output ("窗口已就位: title='$($sb.ToString())' rect=$($r.L),$($r.T),$($r.R),$($r.B) dpi=$([W32Doubao]::GetDpiForWindow([IntPtr]$win.Current.NativeWindowHandle))")
        }
        'status' {
            $sb = New-Object System.Text.StringBuilder 128
            [W32Doubao]::GetWindowText([IntPtr]$win.Current.NativeWindowHandle, $sb, 128) | Out-Null
            $chip = ($all | Where-Object { $_.Current.ControlType.ProgrammaticName -eq 'ControlType.Button' -and $_.Current.Name -in @('快速','专家','工作任务 Auto','工作任务 Turbo','工作任务 Pro') } | Select-Object -First 1).Current.Name
            $val = ''
            if ($edit) { $val = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value }
            Write-Output "窗口: $($sb.ToString())"
            Write-Output "模式: $(if ($chip) { $chip } else { '未知' })"
            Write-Output "输入框内容: $val"
        }
        'newchat' {
            New-Chat $win
            Write-Output '已开新会话'
        }
        'mode' {
            if (-not $Mode) { throw '需要 -Mode（快速|专家|工作任务 Auto|工作任务 Turbo|工作任务 Pro）' }
            Set-Mode $win $Mode
        }
        'send' {
            if ($NewChat) { New-Chat $win; $all = Get-All $win; $edit = Find-InputEdit $all }
            if ($Files) { Add-Attachments $win $Files }
            if ($Text) {
                Send-Text $win $Text
                Write-Output "已发送: $Text"
            } else { Write-Output '已添加附件（未发文字，可继续 -Action send -Text ...）' }
            if ($WaitSec -gt 0) {
                Wake-Tree $win  # 发送后界面重渲染，先重新唤醒树再找输入框（v2.1 修复：不唤醒会拿到过期树报找不到输入框）
                $all = Get-All $win; $edit2 = Find-InputEdit $all
                $done = Wait-ReplyStable $win $edit2 $WaitSec
                Write-Output ($(if ($done) { '回复生成完毕' } else { '等待超时（可能仍在生成）' }) + ':')
                Get-Messages (Get-All $win) $edit2 $MaxLines | ForEach-Object { Write-Output ("  " + $_.Text) }
            }
        }
        'attach' {
            if (-not $Files) { throw '需要 -Files' }
            Add-Attachments $win $Files
        }
        'read' {
            Wake-Tree $win
            $edit = Find-InputEdit (Get-All $win)
            Get-Messages (Get-All $win) $edit $MaxLines | ForEach-Object { Write-Output $_.Text }
        }
        'wait' {
            if ($WaitSec -le 0) { $WaitSec = 60 }
            Wake-Tree $win
            $edit = Find-InputEdit (Get-All $win)
            $done = Wait-ReplyStable $win $edit $WaitSec
            Write-Output ($(if ($done) { '回复生成完毕' } else { '等待超时' }))
            Get-Messages (Get-All $win) $edit $MaxLines | ForEach-Object { Write-Output $_.Text }
        }
        'probe-buttons' {
            Show-ProbeButtons $win
        }
        'probe-menu' {
            Show-ProbeMenu $win $ButtonAt
        }
        # 'extract'/'probe-windows' 在 try 块开头短路处理
    }
} catch {
    Write-Output "DOUBAO_ERROR: $($_.Exception.Message)"
    exit 1
}
