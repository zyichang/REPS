# 08 — 199 的生成脚本和三副牌组加上题型和时间上限

Status: ready-for-agent

## Parent

`.scratch/kind-time-limits/PRD.md`

## What to build

更新 PKB 仓库里 199 牌组的生成脚本,重新生成三副牌组,并更新那个目录的 README:

- **真题 2010—2015:** `time_limits` 选择题 2.5 分钟、写作题 30 分钟(论证有效性分析约 25、论说文约 35,共用一个上限);12 道写作题标 `essay`。
- **逻辑 1001 题:** 选择题 2 分钟。
- **复习指南:** 选择题 2.5 分钟;数学计算类问答卡标 `long`,其余问答卡按内容判断,判断规则写进 README。
- 三副都写 `reps: 2`。

依据:199 是 180 分钟、200 分;数学 25 题约 60 分钟,逻辑 30 题约 55~60 分钟,写作两篇约 60 分钟。

## Acceptance criteria

- [ ] 三个生成脚本输出新字段;重新生成的三个文件通过新版 REPS 解析器的校验。
- [ ] 卡片 id 和内容不变,只多了 `kind` 和顶层的 `time_limits`;在 App 里重新导入后,学习进度保留。
- [ ] README 写明各牌组的上限和依据。
- [ ] 在 App 里导入真题牌组:选择题倒计时从 2:30 开始,写作题从 30:00 开始。

## Blocked by

- `.scratch/kind-time-limits/issues/04-deck-time-limits-end-to-end.md`

## Comments
