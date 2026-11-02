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

### 2026-11-03 · 已完成

- 数据模型文档 §1:标题改成 v1 / v2;顶层表加 `time_limits`,`reps` 写明 1 / 2 的规则;新增 1.2a(分钟、范围、默认上限表);
  卡片表加 `kind`(取值、推导规则、考试填空题写法),`type` 标明是卡片类型;1.5 报错清单、1.6 兼容格式补上 v2 的内容。
- 中英文格式指南:新增第 8 节「题型与答题时间上限(reps: 2)」(题型表 + 一个能导入的完整例子),写法规则加一条,
  给 AI 的提示词加第 3 条(什么时候写 kind、time_limits 怎么定);后面两节顺延成 9、10。
- 新增示例 `testdata/examples/example-exam.{zh,en}.yaml`(reps: 2,五张卡各演示一种写法,中英 id 一一对应);
  原来的 `example.{zh,en}.yaml` 不动,仍是 reps: 1。
- `guide_test`:例子数 8、卡数 13;第 8 节的例子是 reps: 2、上限和题型对得上;提示词提到 kind 与 time_limits;
  两份考试示例能解析、format 2、上限 / 题型 / 中英 id 一致。62 条全过,完整测试台 26 / 26。
- 模拟器上导入 `example-exam.zh.yaml`:5 张卡,牌组上限和每张卡的题型都存对了(ADR-0007「文档里的例子要真能导入」)。
