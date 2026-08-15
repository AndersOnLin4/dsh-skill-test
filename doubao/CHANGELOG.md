# doubao skill v1 → v2 变更记录

v2 目录：`G:\harness\dsh-home\skills\doubao-v2\`（本目录）
v1 原版：`G:\harness\dsh-home\skills\doubao\`（未改动，保留）

## 变更动因

来自真实任务实测（`G:\文档\网络学习笔记\图片识别测试.md` 记录了 v1 驱动豆包上传图片的完整失败过程）暴露的问题：

1. v1 没有自动启动豆包、没有窗口放大化/归位逻辑 —— 实测中窗口甚至被移到屏幕外（x=-1928），UIA 坐标全负，所有定位失效
2. v1 没考虑副屏/多显示器场景（窗口在副屏或离屏时无兜底）
3. v1 写死控件名和搜索范围，豆包改版/界面变化后容易失效；且没有"怎么找控件"的方法论和探测工具
4. 实测踩坑：附件菜单项搜索范围错误（弹层挂在 RootElement 下，v1 只在窗口内搜）、文件对话框固定 sleep 2s 后找不到就报错、WM_SETTEXT 字符串封送歧义（string 被当 IntPtr 传）、"找一个可展开按钮"太宽泛误点成用户菜单按钮

## 具体变更

### A. 窗口就位保障（对应问题 1、2）

| 项 | v1 | v2 |
|---|---|---|
| 豆包未运行 | 报错让用户手动开 | 自动搜索安装路径/注册表/开始菜单并拉起，等主窗口最多 45s |
| 窗口最小化 | 无处理 | 自动 SW_RESTORE |
| 窗口在主屏外/副屏 | 无处理 | EnumDisplayMonitors 取主屏工作区，窗口中心不在主屏就 MoveWindow 回主屏 |
| 放大化 | 无 | 每次动作前 SW_MAXIMIZE，保证全可见 |
| 执行时机 | — | 所有窗口相关动作（status/send/attach/read/wait/mode/newchat/ensure/probe-buttons/probe-menu）自动前置；仅 probe-windows 例外（诊断用，不做 ensure） |

### B. UI 发现方法链 + 探测工具（对应问题 3）

新增「锚点→候选→验证→降级」四步方法（SKILL.md 铁律章节）：不写死坐标、不盲信控件名；先定位稳定锚点（输入框），在锚点相对区域按角色+模式收候选，动手前 probe-menu 验证菜单内容，验证失败降级输出候选清单让 agent 判断。

新增三个探测动作：

- `-Action probe-windows`：主屏工作区 + 豆包全部顶层窗口（hwnd/class/title/rect/visible/iconic）+ 主窗口 DPI 与是否在主屏
- `-Action probe-buttons`：输入框锚点矩形 + 全部按钮清单（Name | x,y,w,h | 支持模式 | 展开状态）
- `-Action probe-menu -ButtonAt 'x,y'`：展开指定坐标处的按钮，dump 可见菜单项（RootElement 下、窗口外扩 300px 过滤），探测完自动收起

### C. 附件上传流程重写（对应问题 4）

| 项 | v1 | v2 |
|---|---|---|
| 菜单项搜索 | 只在窗口内搜 → 找不到 | 在 RootElement 下搜 + 按"矩形中心落在窗口外扩 200px 内"过滤同名隐藏项 |
| 附件按钮选择 | 找到第一个可展开按钮就点（误点用户菜单按钮） | 逐个候选"展开→验证菜单含「上传文件或图片」"，验证失败收起换下一个 |
| 文件对话框等待 | 固定 sleep 2s 后找不到就报错 | Win32 EnumWindows 轮询最多 12s |
| WM_SETTEXT | SendMessage 重载歧义，string 被当 IntPtr 传而失败 | 拆成 SendMessage（IntPtr）/ SendMessageStr（string）两个名字，封送无歧义 |
| 结果反馈 | 盲目报"附件已加入" | 点「打开」后确认对话框关闭 + 验证输入框上方附件条出现，挂不上明确告警 |
| 错误提示 | 只说"找不到" | 每个失败点都提示下一步该用哪个 probe 动作排查 |

### D. 其他

- `status` 窗口标题改用 Win32 GetWindowText（不再依赖 UIA Document 元素名）
- 模式切换菜单项搜索同样改走 RootElement（含窗口内回退）
- troubleshooting.md 重写：新增离屏/副屏、菜单项搜索范围、误点用户菜单、对话框样式变更等条目；明确"副屏在主屏左侧时 UIA 坐标为负属正常，按相对锚点判断"
- SKILL.md 新增「先确保窗口就位」「UI 发现方法链」两条铁律 + 探测三件套用法；v1 版本号标注

## 升级指引

- 本会话加载新 skill 名 `doubao-v2`（已注册进技能目录）；`agent-delegation-slim` 的路由表中"豆包"仍指向 v1，如需全局切换到 v2，把 `doubao-v2` 目录重命名为 `doubao`（先备份 v1）或修改路由表 skill 名。
- 脚本为 UTF-8 BOM 编码；编辑后若报乱码，按 SKILL.md 的补 BOM 命令恢复。
- v2 的 ensure 每次动作前会把豆包窗口移回主屏并最大化，属设计行为。

## v2.1 实测修复（本轮开发期间用真实豆包客户端验证发现并修复）

E2E 实测（开新会话 → 上传 PNG → 发消息 → 读回复，豆包正确识别图片内容）过程中发现并修复 5 个问题：

1. **`SendMessageStr` EntryPoint 缺失**：自定义 P/Invoke 方法名必须配 `EntryPoint="SendMessageW"`，否则报 "Unable to find an entry point"（第一次 E2E 即踩中，且失败残留对话框污染了下一次运行）。
2. **残留文件对话框污染**：上一次运行崩溃/失败留下的 `#32770` 对话框，其上传请求已超时，完成它也不会挂载文件。修复：每次上传前 `WM_CLOSE` 关闭所有残留可见对话框（实测第二次 E2E 被污染后正因这个机制自愈）。
3. **挂载验证 + 自动重试**：附件条未确认时自动重试一次（最多 2 次），两次都失败则明确告警"不要继续发消息，先人工检查"——v1 是盲目报成功。
4. **菜单搜索卡死**：`RootElement.FindAll(Descendants)` 遍历整个桌面树会被无响应的 provider 卡死（probe-menu 实测挂 120s）。修复：只在豆包进程的顶层窗口子树内搜 MenuItem（`Get-PopupMenuItems`）。
5. **发消息后读回复报"找不到输入框"**：发送后界面重渲染，输入框元素引用过期。修复：`send` 的 WaitSec 分支和 `read`/`wait` 动作在读取前重新 `Wake-Tree` + 重新定位输入框。

以上修复后的完整链路已在真实豆包客户端跑通：`newchat → send -Files → 附件条确认挂载 → 消息发出 → 回复读取`，豆包成功识别上传图片。

## v3 目录整合（2026-09）

- 目录更名：`doubao-v2` → `doubao`（唯一主版本）；v1 原版归档至 `G:\harness\dsh-home\skills-archive\doubao-v1\`。
- SKILL.md 去掉"-v2 /（v2 新增）"标注与 v1 回退表述；脚本路径统一为 `skills\doubao\scripts\`。
- `download-asset.ps1` 与 `references\download-extract.md` 原与 v1 完全相同的副本随 v1 归档，主目录只保留一份。
