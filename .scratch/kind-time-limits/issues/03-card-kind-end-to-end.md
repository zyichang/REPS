# 03 — 卡片上的 `kind`:从牌组文件一直到学习页

Status: ready-for-agent

## Parent

`.scratch/kind-time-limits/PRD.md`

## What to build

牌组文件可以在卡片上用 `kind` 写明题型,学习页按它取上限。做完以后,大题 5 分钟、写作题 25 分钟生效。

- **格式(ADR-0008):** 卡片新增可选字段 `kind`,取值 `choice` / `blank` / `short` / `long` / `essay`。
  用了 `kind` 的文件必须写 `reps: 2`;App 同时读 `reps: 1` 和 `reps: 2`;`reps: 1` 里出现 `kind` 时报错并提示改成 `reps: 2`;
  不认识的值报错并带 YAML 行号。旧格式(没有 `reps` 的 YAML、Quizify Markdown)不支持 `kind`。
- **存储:** schema 升到 v4(走版本化迁移),笔记新增「明写的题型」,空 = 文件里没写。
- **内容哈希:** 把题型算进去,但题型为空时与现在的哈希完全一致,否则所有旧卡下次导入都会被当成「改过」。
  只改了 `kind` 的卡,重新导入时被认作更新,新题型存进去,学习进度保留。
- **导出:** 有明写题型的卡写 `kind`;用到 `kind` 的牌组写 `reps: 2`,否则照旧写 `reps: 1`。
- **有效题型:** 明写优先,否则按卡片类型推出。题型和卡片类型的组合不做限制。
- **编辑器:** 保存修改时保留原来的题型;在 App 里新建的卡没有明写的题型。

## Acceptance criteria

- [ ] 解析:`reps: 2` + `kind` 正常解析;不认识的 `kind`、`reps: 1` 里写 `kind`、`reps` 既不是 1 也不是 2 时,报错并带行号,中英文提示都有。
- [ ] 迁移:v3 的库升到 v4 后数据不丢,旧笔记的题型为空(参照 `migration_test`)。
- [ ] 内容哈希:题型为空时与现在相同;只改 `kind` 的重新导入被认作更新,进度保留(参照 `reimport_test`)。
- [ ] 导出往返:带 `kind` 的牌组导出再导入完全一致;不带 `kind` 的牌组仍写 `reps: 1`(参照 `export_test`)。
- [ ] 云同步下载的 `reps: 2` 牌组能正常解析和入库。
- [ ] 学习页:`kind: essay` 的问答卡倒计时从 25:00 开始,`kind: long` 从 5:00 开始;在 App 里编辑这张卡并保存后,题型不变。
- [ ] 模拟器上手动验证,结果记在本 issue 的 Comments 里。
- [ ] 完整桌面测试台通过,ArkTS 构建成功。

## Blocked by

- `.scratch/kind-time-limits/issues/02-default-limits-and-timeout.md`

## Comments
