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

**HarmonyOS(ArkTS)。** 原生应用,支持手机、平板与 PC(2in1,普通可缩放窗口;窄时单栏、宽时双栏)。
卡片来自用户自己的文件,排期算在设备上,数据库在应用沙箱里;只有可选的华为账号同步会联网(权限仅 INTERNET)。

> 早先的 README 写过「Web 优先」,现已作废。改回 HarmonyOS 的理由:
> 项目核心是排期算法,而 FSRS-6 与固定阶梯两套引擎在 WordSnap 上
> 已经用 ArkTS 完整实现并通过 168 条回归测试,直接复用比用 TypeScript
> 重写一遍再重新验证更省事、也更可靠。

## Import format

主格式是 **REPS Card YAML v1**(ADR-0007)。

**怎样写牌组、怎样让 AI 生成:** [`docs/yaml-guide.zh.md`](docs/yaml-guide.zh.md) /
[English](docs/yaml-guide.en.md)。每种题型一个例子,外加可直接复制的 AI 提示词;
完整模板 `testdata/examples/example.{zh,en}.yaml`。文档里的例子由 `devtest/guide_test.ts` 逐个解析。

完整字段表、数据库结构、卡片身份与云同步见
**[docs/data-model.md](docs/data-model.md)**。

```yaml
reps: 1
deck: 数据结构
tags: [DataStructure, 第二章]
cards:
  - type: qa
    front: "顺序表按下标随机访问的时间复杂度是多少?"
    back: "$O(1)$ —— 元素地址可由下标直接算出。"

  - type: choice
    title: "基础选择 (1)"
    front: "一个算法应该是( )。"
    options: ["程序", "问题求解步骤的描述"]
    answer: B
    back: "算法是**问题求解步骤的描述**,程序是算法在计算机上的特定实现。"

  - type: cloze
    front: "三种基本结构是 {{顺序}}、{{选择}} 和 {{循环}}。"
```

- 选择题的选项按顺序自动编成 A、B、C…,`answer` 写字母;写成 `[A, C]` 就是多选。
- 文字一律用引号或 `|` 块,行内只用标准 Markdown、`$公式$` 和 `{{挖空}}`。
- 分享出去的文件只有内容,不带任何学习记录。

**兼容导入:** [Quizify Card Markdown](https://github.com/e-chehil/anki-quizify)(`+++` / `***` / `;;;`)
仍然可以导入。REPS 的解析器是自己写的,没有使用该项目(AGPL-3.0)的代码。

## Status

**v1.1.0(2026-10-26)—— 自用稳定版。** 新增:支持 PC(2in1,可缩放窗口,窄单栏、宽双栏);
牌组格式指南(中英,`docs/yaml-guide.*.md`)与完整示例;斜体 `*…*` 与提示框 `> [!NOTE]` 等。

**v1.0.3(2026-10-26)** 相对 1.0.0:删牌组后浏览页预览残留、卡片开头的
`<!-- quizify-card -->` 注释外露、编辑页输入框拉满且保存后回到预览、目标保持率挂到 FSRS-6 下面、
粗体里的公式不渲染。

**v1.0.0(2026-10-26)** 首个自用版。 在模拟器与 MatePad Air 真机上验证过,桌面回归测试 24 套全过。

已可用:

- [x] 导入 REPS Card YAML v1(主格式)与 Quizify Markdown(兼容);问答 / 选择(单选、多选)/ 挖空
- [x] 重导:按卡片 id 认卡,内容变了就更新、学习进度保留;文件里少了的卡只提示不删
- [x] 导出 YAML 并用系统分享面板发出(只有卡片内容,不含学习记录)
- [x] 复习:FSRS-6 / 固定阶梯两套引擎可切换;凌晨 3 点日界;复习上限与新卡额度按牌组单独算
- [x] KaTeX 数学公式;粗体、斜体、高亮、行内代码、上下标;提示框 `> [!NOTE]` / TIP / IMPORTANT / WARNING / CAUTION
- [x] 统计:综合统计(含已删牌组)、热力图、保持率、学习时长;打卡与连续天数
- [x] 可选的华为账号登录(登录前同意隐私政策);头像昵称只存本机
- [x] 多设备同步(AGC 云数据库 + 云存储,只用免费套餐):打卡、热力图、牌组、学习进度
- [x] 平板布局;中文 / English 随系统

还没做(见 `CONTEXT.md`):注销账号、牌组广场(官方牌组下载)、牌组版本更新提示、
MDX 词典转换、`.apkg` 导入;上架前还要把隐私政策放到公网(云托管或 AGC 协议服务)、申请发布证书。

## Roadmap

- [x] 名称、平台与技术栈;FSRS-6 与固定阶梯两套排期引擎
- [x] 数据模型(deck / note / card + 排期,schema v3)与 YAML v1 格式(ADR-0007,`docs/data-model.md`)
- [x] 复习界面、今日集合规则、算法切换、统计面板、数学公式、导入导出
- [x] 华为账号 + 云同步(ADR-0006)
- [ ] 注销账号
- [ ] 牌组广场与发布工具上线(`tools/publish` 已就绪,未上传)
- [ ] MDX 词典转换、`.apkg` 导入
- 暂不做:卡片里的图片 / 音频 / 视频。REPS 以文字为主,卡组要能让 AI 一次生成一份纯文本 YAML;
  媒体会让生成、导入、同步都变复杂,也占存储
- [ ] 排期透明化(每张卡为什么排在今天)

## A note on Anki

REPS 借用的是 **idea**(间隔重复 + 卡片),不是 Anki 的代码。
Anki 以 AGPL-3.0 发布,若将来真要移植它的任何实现,必须连带遵守该许可证;
本项目不打算这样做,排期与存储都会自行实现。
