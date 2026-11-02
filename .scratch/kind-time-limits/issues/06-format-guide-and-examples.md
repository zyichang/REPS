# 06 — 格式指南和示例:`reps: 2`、`kind`、`time_limits`

Status: ready-for-agent

## Parent

`.scratch/kind-time-limits/PRD.md`

## What to build

把新字段写进给人和 AI 看的文档:数据模型文档的字段表、中英文格式指南(包括给 AI 的提示词部分)、示例文件。
「文档里的格式示例必须真的能导入」这条规则不变(ADR-0007)。

## Acceptance criteria

- [ ] 数据模型文档:顶层字段表加 `time_limits`,卡片字段表加 `kind`;写明 `reps: 2` 的规则、取值、单位、范围、默认上限和推导规则。
- [ ] 中英文格式指南各加一节「题型与时间上限」,至少一个完整的 `reps: 2` 例子(包含写作题和 `time_limits`);中英两份一一对应。
- [ ] 给 AI 的提示词部分写明什么时候写 `kind`、`time_limits` 怎么定。
- [ ] 示例文件加上新字段,或者新增一份 v2 示例;中英文示例的卡片 id 一一对应。
- [ ] `guide_test` 通过:指南里所有 YAML 例子都能被解析器解析。
- [ ] 完整桌面测试台通过。

## Blocked by

- `.scratch/kind-time-limits/issues/03-card-kind-end-to-end.md`
- `.scratch/kind-time-limits/issues/04-deck-time-limits-end-to-end.md`

## Comments
