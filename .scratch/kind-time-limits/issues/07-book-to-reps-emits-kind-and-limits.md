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

### 2026-11-03 · 已完成

skill 在 `zyichang-setting/skills/book-to-reps`(`~/.kiro/skills/book-to-reps` 是指向它的链接),提交 `a15d3ea`。

- 脚本:
  - `repsyaml.py`:`card(..., kind=)`、`deck_yaml(..., time_limits=)`;有题型或上限才写 `reps: 2`,否则仍写 `reps: 1`;
    题型拼错、上限不在 (0, 180] 内、`time_limits` 里写了不认识的题型,都直接报错。
  - `txbook.py`:`Q(type=, kind=)` 把卡片类型和题型分开;旧的转写文件把卡片类型写在 `kind=` 里,照样能用;
    `build(time_limits=)` 打印写了哪些题型和上限。
  - `check.mts`:每个牌组多打印一行版本号、题型数量、上限;问答卡的标题或标签像写作题 / 大题却没写 `kind` 时给警告;
    写了题型却没写上限时也给警告。
- 说明:`SKILL.md` 的流程第 2、4、6、8 步;`references/reps-yaml.md` 新增「Question kinds and time limits」
  (怎样判断题型;上限 = 这一部分的答题时间 ÷ 题量,没有参考时间就按分值分配总时长;一个牌组混了快慢不同的部分时取大的;
  199、数学一、英语一的起点值表);`output-and-overview.md` 要求 README 写明每个牌组的上限和依据;
  `parsing-patterns.md` 写作题标 `essay`、题库里没有选项的例题标 `long`。
- 样书试跑(`/tmp/b2r-sample/`):
  - 文本路线(bookio → qparse → repsyaml):一份小 199 练习卷 TXT,4 道选择题(含条件充分性判断)+ 2 道写作题,
    `time_limits: {choice: 2.5, essay: 30}`。
  - 扫描路线(txbook):一份小数学一样卷,选择 2(其中一张用旧写法 `kind='choice'`)、填空 1(`qa` + `blank`)、解答 1(`long`),
    `time_limits: {choice: 3, blank: 4, long: 20}`。
  - 对照:没有题型和上限的概念牌组,输出 `reps: 1`;一张标题含「写作要点」的问答卡触发了「像写作题」的警告(故意的)。
  - `check.sh`:三份都 OK,KaTeX 错误 0,版本号、题型数、上限与预期一致。反例:`reps: 1` 文件里写 `kind` → 解析器报错退出 1。
  - 模拟器导入:三份都导入成功(4 / 6 / 2 张);数据库里 `decks.time_limits` 和 `notes.kind` 与文件一致。
    学习页倒计时起点:数学一样卷 选择 3:00、填空 4:00、解答 20:00;199 练习卷 选择 2:30、写作 30:00。
