# 07 — book-to-reps 生成题型和时间上限

Status: ready-for-agent

## Parent

`.scratch/kind-time-limits/PRD.md`

## What to build

book-to-reps skill 不在 REPS 仓库里,在用户的 skill 目录。让它生成牌组时:

- 写作题标 `essay`,解答题和计算题标 `long`,考试里的填空题(存成问答卡)标 `blank`;
- 在牌组顶层按真实考试的时间写 `time_limits`(按考试总时长、题量和分值估算,并写明依据);
- 用到这两个字段时写 `reps: 2`;
- 生成后照旧用 REPS 的解析器校验。

## Acceptance criteria

- [ ] skill 的说明里写清楚题型的判断规则,以及 `time_limits` 怎么定。
- [ ] skill 的脚本和模板生成的 YAML 带 `kind`、`time_limits`、`reps: 2`,并通过 REPS 解析器校验。
- [ ] 用一本小样书(或者现有一本书的一章)跑一遍,输出能导入 App。

## Blocked by

- `.scratch/kind-time-limits/issues/06-format-guide-and-examples.md`

## Comments
