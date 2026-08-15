# 豆包自动化 — 机制与排障参考（按需阅读，不常驻上下文）

## 工作机制（脚本内部实现，排查问题时对照）

1. **自动就位（ensure）**：每个需要窗口的动作先跑 `Ensure-Doubao`——进程没开就按 `%LOCALAPPDATA%\Doubao\Doubao.exe` / `Program Files` / 注册表卸载项 / 开始菜单快捷方式找 `Doubao.exe` 拉起（最多等 45s）；窗口最小化则 `SW_RESTORE`；用 `EnumDisplayMonitors` 拿主屏工作区，窗口中心不在主屏就 `MoveWindow` 回主屏；最后 `SW_MAXIMIZE` 放大化。**v1 没有这层保障，实测出现过窗口被拖到 x=-1928 屏幕外、UIA 坐标全负、所有定位失效的情况。**
2. **唤醒无障碍树**：向主窗口发 `WM_GETOBJECT`（Msg 0x003D，lParam 0xFFFFFFFC）后等 ≥2s，否则 UIA 树里只有窗口按钮；树是异步构建的，**每次 FindAll 前都要重新唤醒**，否则拿到过期树（表现为控件"时有时无"或坐标异常）。
3. **主窗口定位**：`Get-Process Doubao | Where MainWindowHandle -ne 0`，再用 UIA RootElement 按 NativeWindowHandle 找顶层元素。主窗口类名 `Chrome_WidgetWin_1`。
4. **输入框（锚点）**：支持 ValuePattern 的 Edit 中底部最宽的那个。普通聊天占位符「发消息或按住空格说话...」，工作任务模式占位符「输入问题或任务，/ 选择技能」（name 为空，不要依赖占位符）。所有按钮定位都相对输入框矩形推算。
5. **发送按钮**：输入框右下方的**无名 Button**。Chromium 在同坐标暴露两个变体（一个只有 ExpandCollapse、一个只有 Invoke）——必须选**支持 InvokePattern** 的那个，否则静默失败。
6. **模式切换**：输入行左侧模式芯片（Button，名称「快速/专家/工作任务 Auto/Turbo/Pro」之一）只有 ExpandCollapsePattern，Expand 弹菜单；对目标 MenuItem Invoke。**生效有 3-5 秒延迟**，之后芯片名变为新模式名。
7. **附件上传**：
   - 候选收集：输入框左下方、支持 ExpandCollapse 的 Button（可能有多个）
   - **逐个候选验证**：Expand → 在 **RootElement** 下找「上传文件或图片」MenuItem（弹层挂在根下，不在窗口内——v1 在窗口内搜所以找不到）；菜单里没有该词条就 Collapse 换下一个候选（防误点用户菜单按钮）
   - Invoke 菜单项 → **Win32 轮询最多 12s** 等可见 `#32770` 对话框（v1 固定 sleep 2s 后找不到就报错）
   - 枚举对话框子窗口：文件名框 = class Edit + ctrlid 1148；打开按钮 = class Button + ctrlid 1
   - `SendMessageStr`（专用 string 重载，修复 v1 曾有的 WM_SETTEXT 封送歧义）写入 `"路径1" "路径2"`（多文件必须带引号），`BM_CLICK`（Msg 0x00F5）提交
   - 等对话框关闭 → 验证输入框上方附件条出现（文件名或 Image 控件），挂不上会明确告警而不是假装成功
8. **读回复**：消息区（输入框左缘-50 为左边界，y 80~输入框上方）内 ControlType 为 Text/ListItem/Hyperlink 的元素的 Name，按 y 排序即会话内容。生成中/结束无显式状态按钮，靠文本稳定性轮询（`-Action wait`）。
9. **探测三件套**：`probe-windows`（顶层窗口+主屏信息）、`probe-buttons`（锚点+全部按钮）、`probe-menu -ButtonAt x,y`（展开指定按钮并 dump 可见菜单项，探测完自动收起）。这是「锚点→候选→验证→降级」方法链的执行工具。

## 常见问题

- `找不到主窗口`：豆包没开或最小化到托盘。会自动拉起和还原；仍失败则 `probe-windows` 看进程窗口列表，确认是否停在登录/更新界面。
- `豆包未运行且未找到 Doubao.exe`：自动搜索安装路径/注册表/开始菜单失败。请用户告知安装路径，或手动启动一次后重跑（进程在时不需要 exe 路径）。
- **窗口坐标全负/控件 rect 异常（v1 实测坑）**：窗口被移到屏幕外或副屏布局变化。跑 `-Action ensure` 自动移回主屏最大化；`probe-windows` 可先确认 rect 与 iconic 状态。
- **多显示器/混 DPI（已双保险）**：① ensure 会把窗口归位主屏工作区；② `GetDpiForWindow` 按窗口实际 DPI 缩放所有像素阈值，UIA 物理坐标 + 相对输入框定位，换屏/换缩放无需改代码。注意：副屏在主屏**左侧**时其 UIA 坐标为负值，属正常现象，方法链按"相对锚点"判断而不是按正负号。
- 菜单项找不到：确认是在 **RootElement 下搜**（v1 的 bug）；`probe-menu` 输出里只有"窗口外扩 300px 内"的可见项，同名隐藏项会被过滤掉。
- 误点成用户菜单按钮（展开出「设置/收藏夹/豆包官网」）：候选验证没过就 Invoke 了。附件流程已改为逐个候选验证；手工操作时养成"先 probe-menu 看菜单再 Invoke"的习惯。
- 文件对话框控件没找到（ctrlid 1148/1）：确认弹出的是经典「打开」对话框；若豆包换了对话框样式，用 `probe-windows` 拿对话框 hwnd + `EnumChildWindows` 枚举 Edit+Button 对，更新脚本常量。
- **残留文件对话框（上次运行失败留下）**：上传前脚本会自动 `WM_CLOSE` 所有可见 `#32770` 对话框再重新走流程（残留对话框的上传请求已超时，直接完成它不会挂载文件）。若看到"已关闭残留文件对话框"输出，说明发生过这种自愈。
- 附件条未确认挂载：脚本会自动重试一次；两次都失败会明确告警。此时**不要继续发消息**——豆包会当作无图消息回复，先人工检查豆包输入框上方是否有附件缩略图。
- 点「打开」后对话框不关：文件名没写进去（路径不存在/引号丢失）。`SendMessageStr` 用 string 重载；多文件必须 `"路径1" "路径2"` 带引号。
- 消息没发出去（输入框仍有文字）：命中了无 InvokePattern 的按钮变体（见机制第 5 条）；重跑 send 即可。
- 上传后附件条重复：多次 attach 会重复添加同名文件，属正常行为，直接发送即可。
- 执行策略报错（cannot be loaded because running scripts is disabled）：每个新 pwsh 进程先 `Set-ExecutionPolicy -Scope Process Bypass -Force`。
- 脚本解析乱码（Unexpected token 乱码）：文件被编辑工具重写后丢了 UTF-8 BOM，用 SKILL.md 里的补 BOM 命令恢复。
- 豆包版本更新后按钮/菜单名变了：走「锚点→候选→验证→降级」方法链——先 `probe-buttons` 看候选，`probe-menu` 验证菜单，确认新名称后更新脚本常量（或临时用候选坐标点），**不要沿用旧名称硬点**。
- 控件时有时无（屏幕上明明有却找不到）：无障碍树是异步构建的，`WM_GETOBJECT` 后要等 ≥2s 再 `FindAll`；轮询查找时**每次都要重新唤醒**，否则拿到旧树/半棵树。
- hover 才出现的控件（消息工具栏、图片/文档预览的保存/下载按钮）：注入的 `WM_MOUSEMOVE`/`PostMessage` **无法触发** Chromium 的 hover（客户端只认真实光标），且这些控件随光标离开自动隐藏。对策：让用户把光标悬停在目标上，脚本轮询到控件出现后立刻 Invoke；或直接走缓存提取，绕开 UI。
- 多显示器截图不可靠：不要用截图取内容（PrintWindow 可能黑屏、UIA 物理坐标与光标逻辑坐标错位、且损失精度），一律用 UIA 文本/缓存提取。

## 备注

- 该通道走桌面端 UI，等同于用户手动操作，不消耗 API Key 额度；用户豆包账户自身配额照常消耗（档位以用户账户为准）。
- 模式下拉里「工作任务 Pro」带“升级”标记，可能触发付费/升级提示，慎用。
- `ensure` 会在每次动作前把豆包窗口**移回主屏并最大化**——这是设计行为（修复离屏/副屏问题），用户若想保留自定义窗口位置，注意这一点。

## 拿生成的原文件（图片/文档）——优先缓存提取，不要截图

豆包生成的图片/文档经网络拉取后会落到 Chromium 磁盘缓存：`%LOCALAPPDATA%\Doubao\User Data\Default\Cache\Cache_Data\f_*`。

1. 记下生成完成的大致时间，列出该时间点前后几分钟内修改的 `f_*` 文件（按 `LastWriteTime` 排序）。
2. 按文件签名识别：PNG `89 50 4E 47`、JPEG `FF D8 FF`、WebP `RIFF`+`WEBP`、docx/ZIP `50 4B 03 04`、doc/OLE2 `D0 CF 11 E0`、PDF `25 50 44 46`。
3. 读取时用 `FileShare.ReadWrite -bor FileShare.Delete` 共享读（缓存文件被进程锁着），整段拷出即为**原始无损文件**——与显示器数量、DPI、缩放完全无关。
4. 聊天消息本体在 `Default\IndexedDB\chrome_doubao-chat_*.indexeddb.leveldb\*.log`（UTF-8 文本，可搜消息内容和附件元数据）；文档类附件的元数据（file_id/file_type 等）可能在 `Default\WebStorage\6\IndexedDB\indexeddb.leveldb\*.log`。

若缓存里没有目标文件（尚未被预览/下载过），先在 UI 里打开一次预览让资源入缓存，再重复 1-3。注意：豆包文档预览拉取的是内部二进制格式（无 docx 签名），只有真正触发“下载”才会产生标准 docx/doc 文件。
