# AI 能力路由表（唯一权威）

> 本文件从 SKILL.md 抽离，**按需加载**：只有需要精确查表时才读，不要默认全量载入上下文。SKILL.md 的「AI 能力路由」一节只保留使用要点。

## 能力优先级快照（2026-08 社区共识，豆包+网络交叉核实；重大模型发布后应重新外派核实）

| 能力 ID | 优先级（AI → 对应 skill 名，按序检查） |
|---------|--------------------------------------|
| ocr_recognize 识图/OCR | Gemini(`gemini`) → GPT(`gpt`) → 豆包(`doubao`) |
| image_generate 图像生成 | Nano Banana(`nano-banana`) → GPT Image(`gpt`) → Midjourney(`midjourney`) → 豆包(`doubao`) |
| video_generate 视频生成 | Seedance 豆包引擎(`doubao`) → Kling(`kling`) → Veo(`gemini`) |
| video_understand 视频理解 | Gemini(`gemini`) → 豆包(`doubao`) → Qwen-VL(`qwen`) |
| writing 写作/文案 | Claude(`claude`) → GPT(`gpt`) → 豆包(`doubao`)（中文语境豆包可直选） |
| coding 编程 | Claude(`claude`) → GPT(`gpt`) → Qwen(`qwen`) → DeepSeek(`deepseek-web`) |
| reasoning 深度推理/研究 | GPT(`gpt`) → Claude(`claude`) → Gemini(`gemini`) → DeepSeek(`deepseek-web`) |
| speech 语音转写/合成 | Gemini(`gemini`) → ElevenLabs(`elevenlabs`) → Whisper(`gpt`) → 豆包(`doubao`) |
| music 音乐生成 | Suno(`suno`) → Udio(`udio`) → Stable Audio(`stable-audio`) → 豆包(`doubao`) |
| document_ppt 文档/PPT | Gamma(`gamma`) → Kimi(`kimi`) → 豆包(`doubao`) |
| translation 翻译 | DeepL(`deepl`) → GPT(`gpt`) → Gemini(`gemini`) → 豆包(`doubao`)（中文互译豆包可直选） |
| web_search 联网搜索 | 主 Agent 自带搜索工具（不经过子 AI，最快最省） |
| agent_task 智能体任务执行 | 豆包工作任务模式(`doubao`) |

> 本机（当前环境）已有 `doubao`、`deepseek-web`、`github-push` 三个通道 skill，因此除 coding/reasoning 路由到 DeepSeek 外，其余能力实际都顺延到豆包。

## 路由算法

1. 识别任务的**能力 ID**（多能力任务拆成子任务分别路由）
2. 按上表顺序取 AI 对应的 skill 名，**检查该 skill 当前环境是否可用**：优先看本会话注入的可用 skill 列表；拿不准就 `glob` skills 目录确认
3. 命中第一个可用的 → 加载该 skill 执行（生成类任务：**转述用户意图，不设计参数**）
4. 一个都不在 → 降级顺序：普通子 Agent（delegate_task）→ 主 Agent 自己；交付时说明"最强 AI 未接入，已顺延至 X"
5. 生成类成品一律按通道 skill 的取回流程拿文件（豆包：`-Action extract` / `download-asset.ps1`）

## skill 命名约定

AI 通道 skill 的 `name` 按 AI 惯例命名（`gpt` / `gemini` / `claude` / `doubao` / `deepseek-web` / `kimi` / `qwen` …），与上表"skill 名"列对应即可。**不需要任何能力声明字段**——能力归属由中枢路由表统一维护：一处维护、处处生效、换环境自动适配。

**版本管理（2026-09 目录整合后）**：通道 skill 不再用 `-v2` 后缀建双目录（`doubao-v2`/`deepseek-web-v2` 已更名为 `doubao`/`deepseek-web`，v1 原版归档于 `G:\harness\dsh-home\skills-archive\`）。今后升级一律直接覆盖主目录，被替换的旧版移入 skills-archive；**路由表永不出现"回退 v1"项**，保持只指向唯一主名。

## UI 通道方法链（对形态一的豆包/DeepSeek 通道适用）

`doubao` / `deepseek-web` 两个 UI 自动化通道已内置同一套健壮性机制，主 Agent 不需要了解内部细节，只需记住两条：

1. **窗口就位是自动的**：豆包没开自动拉起；窗口最小化/副屏/离屏自动移回主屏并最大化。主 Agent 直接发动作指令，不要自己先做"开软件、挪窗口"。
2. **报错时走发现方法链，不要硬点**：通道报错（`DOUBAO_ERROR:` / `DEEPSEEK_WEB_ERROR:`）且重试一次仍失败时，按「锚点→候选→验证→降级」四步用探测工具自己找控件——`probe-windows`（窗口层）→ `probe-buttons`（控件层）→ `probe-menu -ButtonAt x,y`（菜单层验证）→ 定位目标后再操作；全部失败就把 probe 输出带给用户，说明"客户端改版超出 skill 已知范围"。**禁止在方法链走完前盲目改坐标或硬点。**

> 方法链完整说明与探测工具用法见 `doubao/SKILL.md`、`deepseek-web/SKILL.md` 的「铁律：UI 发现方法链」章节；实测案例见 `doubao/CHANGELOG.md`。
