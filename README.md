# REPS · 刻意重复

A spaced-repetition flashcard app for building and reviewing a personal knowledge base.

**中文名:刻意重复。** 英文名 **REPS** —— 取「repetitions」之意:
健身用一组一组的 reps 长肌肉,记忆也一样,靠一次次刻意的重复长下来。
所以一天的学习量是 *a set*,一次作答是 *a rep*。

本项目的构想来自 **Anki** 这一类 flashcard 软件(间隔重复 / spaced repetition),
但不是它的移植或分支:代码、数据结构与排期实现都是重新设计的。

## Why another one

Anki 把卡片的**编写**交给用户 —— 那恰恰是最费时间、最容易放弃的一步。
REPS 想解决的是这一步:

> 丢进一本书,得到一整副卡组。

上传一份 Markdown(比如《数据结构》),它被切成知识点,再按卡片类型生成题目:
完形填空、问答、选择题。一万个知识点就是一万张卡,不需要手工录入。

这个思路在 SuperMemo 里叫 **incremental reading**(渐进阅读);
REPS 想做的是把它做成一个普通人愿意每天打开的样子。

## Goals

- **Book → deck.** 以 Markdown 文件为输入,自动切分知识点并生成卡片。
- **多种卡片类型.** 完形填空 / 问答 / 选择题,由卡片的数据结构决定。
- **可选的排期算法.** 默认 FSRS-6,另提供经典艾宾浩斯固定阶梯等选项,
  让用户自己决定相信哪一套。
- **排期透明.** 每张卡为什么排在今天、下一次为什么是这个间隔,都能查到。
- **数据属于用户.** 本地优先,随时可整库导出。

## Scheduling

主引擎是 **FSRS-6**(Free Spaced Repetition Scheduler):
为每张卡维护稳定性 S、难度 D、可提取性 R,再由目标保持率反解下次间隔。

同时保留一个**固定阶梯**引擎(5 分钟 → 30 分钟 → 12 小时 → 1/2/4/7/15/30/60/120 天),
答对前进一格、答错退回第一格 —— 完全可预测,代价是不会因词而异地自适应。
两者共用同一份学习记录,可以随时切换而不丢进度。

## Target platform

**HarmonyOS(ArkTS)。** 原生应用,纯本地运行 —— 不申请任何权限,
卡片来自用户自己的文件,排期算在设备上,数据库在应用沙箱里。

> 早先的 README 写过「Web 优先」,现已作废。改回 HarmonyOS 的理由:
> 项目核心是排期算法,而 FSRS-6 与固定阶梯两套引擎在 WordSnap 上
> 已经用 ArkTS 完整实现并通过 168 条回归测试,直接复用比用 TypeScript
> 重写一遍再重新验证更省事、也更可靠。

## Import format

导入格式是 **Quizify Card Markdown v1** —— 和
[Anki 的 Quizify Markdown 插件](https://github.com/e-chehil/anki-quizify)同一套语法:

```markdown
---
quizify:
  format: 1
  deck: DataStructure::Chapter_2
  tags: [DataStructure, 第二章]
---

+++

#### 基础选择 (1) 一个算法应该是（　）。

;;;
A. 程序
B. 问题求解步骤的描述
;;;B
***
算法是**问题求解步骤的描述**,程序是算法在计算机上的特定实现。
```

`+++` 起一张卡的正面,`***` 切到背面,`;;;` 块是选择题,`{{挖空}}` 是完形填空。
选这个格式的好处是双向的:已有的 Anki 卡组能直接导进来,REPS 的卡组也能导回 Anki。

## Status

🚧 Early development。骨架与排期引擎已就绪:

- [x] HarmonyOS 工程骨架,`assembleHap` 通过,零权限
- [x] 桌面回归测试台(不需要模拟器,`node devtest/sync-and-test.mjs`)
- [x] FSRS-6 引擎 + 固定阶梯引擎,168 条引擎断言;连编码与清单守卫共 208 条全绿

## Roadmap

- [x] 定下项目名称(REPS / 刻意重复)
- [x] 选定平台与技术栈(HarmonyOS / ArkTS / relationalStore)
- [x] 移植 FSRS-6 与固定阶梯两套排期引擎
- [ ] 卡片与卡组的数据模型落库(deck / note / card 三层 + 排期状态)
- [ ] Quizify Markdown 解析:一份文件 → 知识点 → 卡片
- [ ] 复习界面(含作答与评级)
- [ ] 幂等重导:改过文件再导入不丢进度
- [ ] 今日集合规则(01:00 分界、复习上限、新卡额度)
- [ ] 算法切换
- [ ] 排期透明化(每张卡为什么排在今天)
- [ ] 统计面板(保持率、复习量预测、薄弱知识点)
- [ ] 数学公式渲染(KaTeX,约 0.53 MB)
- [ ] 数据导入导出

## A note on Anki

REPS 借用的是 **idea**(间隔重复 + 卡片),不是 Anki 的代码。
Anki 以 AGPL-3.0 发布,若将来真要移植它的任何实现,必须连带遵守该许可证;
本项目不打算这样做,排期与存储都会自行实现。
