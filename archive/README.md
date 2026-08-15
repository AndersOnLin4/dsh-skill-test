# skills-archive（skill 历史版本归档区）

本目录**不在** `skills` 目录内，不会被技能目录扫描注册。仅用于保留历史版本，便于回看/回滚。

## 对应关系

| 归档目录 | 原路径 | 归档原因 | 现行主版本 |
|---------|--------|---------|-----------|
| `doubao-v1` | `skills\doubao` | v2 为全量超集：新增窗口就位保障、探测三件套、发现方法链，修复附件上传 4 个实测 bug | `skills\doubao` |
| `deepseek-web-v1` | `skills\deepseek-web` | v2 为全量超集：窗口就位保障、探测三件套、方法链、读回复路径修复 | `skills\deepseek-web` |
| `agent-delegation-slim-v1` | `skills\agent-delegation-slim` | v2 为全量超集（路由指向 v2 通道 + UI 方法链衔接）；v3 起路由表抽离瘦身 | `skills\agent-delegation-slim` |

## 回滚方法

把归档目录复制回 `G:\harness\dsh-home\skills\` 并删除/改名现行主目录即可。注意：SKILL.md frontmatter 的 `name` 字段必须与目录名一致，否则技能目录注册名会错位。

## 归档时间

2026-09（目录整合）：v1/v2 双目录合并，主目录以 v2 内容为准；今后升级一律直接覆盖主目录，被替换的旧版移入本目录。
