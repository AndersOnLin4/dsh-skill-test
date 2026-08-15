---
name: doubao
description: 豆包桌面客户端（Doubao.exe）驱动——开新会话、切换快速/专家/工作任务模式、发消息、上传附件（文件/图片）、读取回复、下载/提取豆包生成的图片与文档原文件。所有动作自动前置 ensure（未运行自动拉起、窗口自动移回主屏并最大化），内置 probe-windows/probe-buttons/probe-menu 探测工具 + 「锚点→候选→验证→降级」UI 发现方法链。纯 UIA + Win32 消息注入，零鼠标不抢焦点。统一入口是随附的 scripts/doubao.ps1。历史变更见 CHANGELOG.md。
whenToUse: 用户要求调用豆包/给豆包发消息/问豆包、切换豆包模式（快速/专家/工作任务）、向豆包上传文件或图片、读取豆包回复、**让豆包创作（生成图片/视频/文档/文案等）并取回成品文件**时使用。豆包未运行会自动拉起，无需人工启动；豆包窗口在主屏外/副屏/最小化也会自动归位最大化。
---

# 豆包桌面版自动化（子 AI 通道）

豆包是创作类任务的主力**子 AI**：图片生成、视频生成、文档生成、写作、多模态。主 Agent 需要这些能力时，加载本 skill 驱动豆包——**本 skill 就是"打开豆包"的遥控器**。

> v1 原版已归档至 `G:\harness\dsh-home\skills-archive\doubao-v1\`（未删除，可回看）。v1→v2 与目录整合变更见 `CHANGELOG.md`。

## 铁律：转述，不要设计

主 Agent 不擅长设计/创作，**禁止替用户设计参数**（不要自己编配色、构图、风格、文案结构——既费 token 又平庸）。

- ✅ 正确：把用户的原始意图**直接转述**给豆包（如"给这个模型生成个图标"→ 发给豆包"帮我给 Qwen3.6-35B-A3B 模型生成一个应用图标"），让豆包发挥创作能力。
- ❌ 错误：主 Agent 自己写"紫色渐变 #A78BFA→#7C3AED、白色粗圆环、3 个青色节点、扁平矢量风……"再让豆包执行。
- 主 Agent 的职责：理解意图 → 转述 → 等待生成 → 用下面的方式取回成品 → 交付。

## 铁律：直连模式，任务 + 硬性返回格式写进同一条消息

豆包本身是 AI，会遵守格式要求。主 Agent **直接**通过本 skill 给豆包发消息时，把任务和硬性返回格式（JSON 骨架 + 约束）写在**同一条消息**里，豆包直接按格式返回。

- ✅ 正确：`-Action send -Text '请把结果严格按以下 JSON 返回，不要任何额外文字：{"status":"success","summary":"...","data":{}}。任务：……'`
- ❌ 错误：为"转述 + 把豆包回答改写成 JSON"再包一层子 Agent 当传话筒——中转多烧一层上下文，纯属浪费 token（详见 `agent-delegation-slim` 的「委派的两种形态」）
- 识别类同理：`-Files 图片/音频/视频` 上传 + 消息里附 JSON 格式指令，豆包直接返回结构化文本（主 Agent 的"伪多模态化"首选通道）

## 铁律：先确保窗口就位，再操作

**任何需要窗口的动作（status/send/attach/read/wait/mode/newchat 等）都会自动前置 ensure**，无需手动先跑：

1. 豆包没运行 → 自动按安装路径/注册表/开始菜单搜索 `Doubao.exe` 并拉起，最多等 45 秒主窗口出现
2. 窗口最小化 → 自动还原
3. 窗口中心不在主屏工作区（副屏、被拖出屏幕、离屏残留）→ 自动 `MoveWindow` 回主屏工作区
4. 最后统一 `SW_MAXIMIZE` 放大化，保证全可见

主 Agent 不需要关心豆包"开没开、在哪块屏"——直接发动作指令即可。只有 `probe-windows` 是例外（纯诊断，不做 ensure，保证 ensure 本身出问题时也能排障）。

## 铁律：UI 发现方法链——锚点 → 候选 → 验证 → 降级

**不写死坐标、不盲目信任控件名。** 豆包改版/换分辨率/换屏后控件名、位置、菜单结构都可能变。当标准动作报错（`DOUBAO_ERROR:` 开头）时，按下面方法链逐步探测，自己找出正确目标：

### 第一步：锚点

一切定位先找**最稳定的锚点**——聊天输入框：`-Action probe-buttons` 输出的第一行「输入框(锚点)」。它是支持 ValuePattern 的 Edit 里最宽的那个，改版基本不会动它。

### 第二步：候选

在锚点的相对区域内按「角色 + 模式」收候选，**不要只按名字**（很多按钮无名或名字会变）：

- 附件(+)按钮：输入框左下、支持 ExpandCollapse 模式的 Button
- 发送按钮：输入框右下、支持 Invoke 模式的 Button
- 模式芯片：输入行左侧、名字是四个模式名之一的 Button

`-Action probe-buttons` 会列出**全部**按钮的 Name | x,y,w,h | 模式 | 展开状态，直接对照挑选。

### 第三步：验证（点之前必须做）

候选要动手前先验证身份，标准做法：`-Action probe-menu -ButtonAt 'x,y'`（坐标取候选矩形内任一点）展开它，**看菜单内容**：

- 附件(+)按钮展开后应有「上传文件或图片」（附件的自动流程已内置此验证，会逐个候选展开核对，验证失败换下一个）
- 用户菜单按钮展开后是「设置/收藏夹/豆包官网…」——**展开出这个说明选错了**，换候选
- 模式芯片展开后是四个模式名

### 第四步：降级

- 菜单项找不到：菜单弹层挂在 **RootElement** 下，不在窗口内（v1 的 bug）；probe-menu 已按"矩形中心落在窗口外扩 300px 内"过滤可见项，直接看它的输出
- 窗口元素坐标全负/异常：先 `-Action probe-windows` 看主窗口 rect 是否在屏内、是否 iconic；不在屏内跑一次 `-Action ensure` 归位
- 豆包换了对话框样式（ctrlid 1148/1 找不到）：`probe-windows` 找到对话框 hwnd，用 `EnumChildWindows` 枚举控件重新定位
- 全部探测失败 → 把 probe 输出带给用户，说明"豆包改版超出 skill 已知范围"，请求人工确认，不要硬点

**标准排障顺序**：`probe-windows`（窗口层）→ `probe-buttons`（控件层）→ `probe-menu`（菜单层）→ 定位目标 → 用消息注入/Invoke 操作。每个探针输出都是结构化文本，读输出就能知道下一步。

## 用法（pwsh 工具；每个新进程先执行第一句）

```powershell
$s = Join-Path $env:DSH_HOME 'skills\doubao\scripts\doubao.ps1'   # 或替换为上面说明的资源根目录拼接
Set-ExecutionPolicy -Scope Process Bypass -Force

& $s -Action status                                        # 窗口/当前模式/输入框内容（自动 ensure）
& $s -Action ensure                                        # 手动确保：启动/移回主屏/最大化
& $s -Action newchat                                       # 开新会话
& $s -Action mode -Mode 快速                                # 快速|专家|工作任务 Auto|工作任务 Turbo|工作任务 Pro
& $s -Action send -Text '你好' -WaitSec 30 -MaxLines 10     # 发消息，等回复稳定后打印最后10行
& $s -Action send -Text '描述这张图' -Files 'C:\a.png','C:\b.txt' -WaitSec 40   # 带附件发送（可多文件）
& $s -Action send -Text '...' -NewChat                     # 开新会话再发
& $s -Action attach -Files 'C:\x.pdf'                      # 只加附件不发送（挂载后自动验证附件条）
& $s -Action read -MaxLines 15                             # 只读会话最后15行
& $s -Action wait -WaitSec 60                              # 等生成结束再打印
& $s -Action extract -OutDir 'C:\out' -MinutesBack 10 -MinKB 100   # 从缓存提取最近生成的原文件（无损，首选）
& '<skill目录>\scripts\download-asset.ps1' -TargetName 'image' -SaveDir 'C:\out' -SaveFile 'icon'          # UI 下载生成图片
& '<skill目录>\scripts\download-asset.ps1' -TargetName 'Asset cover' -SaveDir 'C:\out' -SaveFile 'doc' -WatchSec 300   # UI 下载文档

# 探测三件套（排障/方法链专用）
& $s -Action probe-windows          # 主屏工作区 + 豆包全部顶层窗口(hwnd/class/title/rect/visible/iconic)
& $s -Action probe-buttons          # 输入框锚点 + 全部按钮(名称/矩形/模式/展开状态)
& $s -Action probe-menu -ButtonAt '584,930'   # 展开该坐标处按钮，列出可见菜单项（探测完自动收起）
```

- 失败输出以 `DOUBAO_ERROR:` 开头：常规错误重试一次；重试仍失败**走上面的 UI 发现方法链**，不要硬点坐标；深入排障读 `references/troubleshooting.md`（机制细节与常见问题）。
- `-WaitSec` 判定 = 消息区文本连续两轮(3s)不变；长回复给 60s+，或分次 `-Action read`。
- 改过 .ps1 后若报乱码解析错误：脚本必须带 UTF-8 BOM。补 BOM：`$p=$s; $c=[IO.File]::ReadAllText($p,[Text.UTF8Encoding]::new($false)); [IO.File]::WriteAllText($p,$c,[Text.UTF8Encoding]::new($true))`
- **DPI/缩放自适应**：脚本启动时用 `GetDpiForWindow` 探测豆包窗口实际 DPI，所有像素阈值按 `dpi/96` 自动缩放——多显示器、混 DPI、任意系统缩放均无需改代码；UIA 坐标是物理像素，所有定位相对输入框矩形推算。窗口被移回主屏后 DPI 变化也会自动跟随。
- **取回生成的原文件（图片/文档）**：完整流程（extract 缓存提取 → download-asset UI 下载 → 对话框处理 → 豆包下载目录 `G:\下载`）见 `references/download-extract.md`。不要截图（多显示器/混 DPI 下易错位、PrintWindow 可能黑屏、且损失精度）。
