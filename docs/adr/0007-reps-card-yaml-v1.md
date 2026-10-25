# ADR-0007 · 卡片格式改为 REPS Card YAML v1;分享文件只放内容

- **状态**:已接受
- **日期**:2026-10-25
- **相关**:`data/Yaml.ets`、`data/Quizify.ets`、`data/Importer.ets`、`docs/data-model.md`、ADR-0002、ADR-0006
- **取代**:ADR-0001(「保留 Quizify Markdown,不迁移到 YAML」)

## 背景

ADR-0001 否决 YAML 的理由在一个月后有三条已经不成立,另外出现了两个新需求:

| ADR-0001 的理由 | 现在 |
|---|---|
| ArkTS 没有 YAML 解析器 | `Yaml.ets` 已有自写的严格子集解析器,有回归测试 |
| YAML 只能替换外层,行内标记留在原地 | 选择题的选项和答案改成结构化字段(`options` / `answer`),不再需要 `;;;` 行内块 |
| 冒号截断、`no` 变布尔、`#` 吃半行 | 严格子集强制引号或 `\|` 块标量,三处都已挡住 |
| **新:**云同步要认出「同一张卡」 | 结构化格式可以带固定的 `id`;Markdown 很难 |
| **新:**分享牌组 | 需要作者、版本、许可证等牌组信息(`meta`) |

另外,Quizify 语法来自 AGPL-3.0 的 anki-quizify 项目。REPS 的解析器是自写的,
语法本身风险低;但不应让 REPS 的主格式跟着别人的项目改版。

## 决定

1. **主格式是 REPS Card YAML v1。** 字段表见 `docs/data-model.md`。
2. **Quizify Markdown 保留为兼容导入**(用户的 PKB 是这个格式),不再是主格式,文档不再推荐。
3. **行内只保留通用语法**:标准 Markdown、`$…$` / `$$…$$`(KaTeX)、`{{挖空}}`。
   `;;;`、`[[…||…]]`、`[…]^(…)^`、`:::` 不进新格式。
4. **选择题**:`options` 只写内容,按位置编成 A、B、C…;`answer` 写字母,
   一个字母是单选,列表是多选(全对才算对)。答案物理上不在题面里。
5. **分享格式**:纯文字是一个 `.yaml`;带媒体时是 zip `.reps`(`deck.yaml` + `media/`,以后做)。
   **数据库不进分享文件**,导出永不包含 `scheduling` / `review_log` / `checkins`。
6. **身份**:牌组 `meta.id`、卡片 `id` 一旦生成永不改变;版本更新按 `id` 对卡。

## 例子(实机导入验证见文末)

```yaml
reps: 1
meta:
  id: 3b8e1f0a-2c4d-4e6f-8a1b-9c0d1e2f3a4b
  version: 1
  author: "zyichang"
  language: zh-CN
  license: CC-BY-4.0
  description: "格式示例"
  generated_by: manual
deck: 格式示例
tags: [示例]
cards:
  - id: ex-qa-1
    type: qa
    title: "机会成本"
    front: "什么是机会成本?"
    back: |
      为了得到某种东西所必须放弃的东西。

  - id: ex-choice-1
    type: choice
    front: |
      $f(x)=\dfrac{1}{3}(x+1)^{2}-\dfrac{2}{3}$ 在 $(-\infty,+\infty)$ 上是( ).
    options: ["单调函数", "奇函数", "周期函数", "无界函数"]
    answer: D
    back: "开口向上的抛物线,故无界。"

  - id: ex-choice-2
    type: choice
    front: "下列哪些是线性结构?"
    options:
      - "栈"
      - "树"
      - "队列"
      - "图"
    answer: [A, C]

  - id: ex-cloze-1
    type: cloze
    front: "程序的三种基本结构是 {{顺序}}、{{选择}} 和 {{循环}}。"
    back: "可以表达任何单入口单出口的程序逻辑。"
```

## 理由

- **一个格式同时服务导入、导出、同步、分享。** 云存储里放的是 App 导出的带 `id` 的 YAML,
  平板下载后卡片身份与手机一致(ADR-0006)。
- **人和 AI 都好写。** `|` 块里公式、多行解析原样写;JSON 要转义换行和引号。
- **安全。** 纯数据,没有 HTML 模板或脚本(对比 `.apkg` 的笔记类型模板)。
- **市场友好。** 纯文本能预览、能逐行 diff、能按内容哈希判重。

## 未采纳

- **像 `.apkg` 那样把 SQLite 放进分享包**:内容与个人学习记录混在一起,难解析、易泄露隐私,
  也让数据库改表影响已分享文件。
- **JSON 为主格式**:手写体验差。服务器内部可以用 JSON(`catalog.json`)。
- **直接删掉 Quizify 导入**:用户现有 PKB 全是这个格式。

## 后果

- `Yaml.ets` 要重写成直接产出 `ParsedDeck`,不再拼 Quizify 文本(Task 3)。
- 导入要按 `id` 认卡、按内容哈希判断是否更新(Task 4,依赖 schema v2,Task 2)。
- 需要 YAML 导出(Task 5)。
- 文档里的格式示例必须实机导入过(ADR-0001 的教训)。本 ADR 的例子在 Task 3 完成后验证,
  结果补在下面。

## 实机验证(2026-10-25,模拟器 127.0.0.1:5555,平板布局)

本 ADR 的示例原样存为 `testdata/format-example.yaml`(桌面测试 `yaml_test.ts` 第 7 节也读它),
推到模拟器 Documents 后在 App 里导入、逐张作答:

| 环节 | 结果 |
|---|---|
| 导入 | `Imported 4 cards into "格式示例"`;牌组拿到 v4 uuid;4 条笔记各 1 张卡,指纹 16 位 |
| 问答 | 正面「什么是机会成本?」→ Show answer → Good |
| 单选 | KaTeX 渲染题干;选项 `A. 单调函数`…`D. 无界函数`;点 D 判对(Accuracy 100%) |
| 多选 | 出现 Confirm 按钮;选 A、C 确认后判对 |
| 挖空 | `Cloze · 3 blanks`,三个空同时挖出、同时揭开 |
| 落库 | `notes.answer` 分别为 ''、`D`、`AC`、'';`review_log` 4 行;`scheduling.updated_at = last_review` |

验证过程中发现并修复两个**早已存在**的问题(不是 v1 引入的):

1. **选择器里看不见 YAML 文件。** `fileSuffixFilters` 写成四个元素时,每个元素是「文件类型」
   下拉的一项、默认只启用第一项(`.md`)。改成一项 `'REPS 卡组|.yaml,.yml,.md,.markdown'`。
2. **导入新牌组必定失败(「卡组创建失败」)。** 自从导入整体包进事务(30ffe6f),
   `ensureDeck` 先 INSERT 再 `querySqlSync` 查回 id —— 读连接看不到本事务未提交的行。
   `lastInsertId`(`SELECT MAX(id)`)也有同样问题,会给卡片挂上错误的 note_id。
   改用 `insertSync` 的返回值。
