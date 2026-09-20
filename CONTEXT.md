# CONTEXT · REPS(刻意重复)

给下一个接手的人(或 agent)。写于 2026-09-20,承接自 WordSnap 项目的一次长会话。

## 这是什么

一个间隔重复(spaced repetition)flashcard 应用。**核心差异不是「又一个 Anki」,
而是把编卡这一步自动化**:

> 上传一本 Markdown 的书 → 切成知识点 → 生成整副卡组。

Anki 让用户手写卡片,而那是最费时、最容易放弃的一步。SuperMemo 把
「边读边抽取成卡」叫 **incremental reading**(渐进阅读),但它难用;
REPS 想把这条链路做成普通人愿意每天打开的样子。

卡片类型由数据结构决定:完形填空 / 问答 / 选择题。

## 已经定下的决定

| 项 | 决定 | 理由 |
|---|---|---|
| 名字 | REPS / 刻意重复 | reps 是健身的「一组组重复」;一天的量 = a set,一次作答 = a rep |
| 平台 | **HarmonyOS / ArkTS** | 核心是排期算法,而两套引擎在 WordSnap 上已用 ArkTS 实现并通过 168 条回归测试,复用比重写更可靠。早先写过「Web 优先」,已作废 |
| 存储 | `relationalStore`(SQLite) | 应用沙箱内,零权限 |
| 主排期引擎 | FSRS-6 | 已从 WordSnap 移植,`srs/Srs.ets` |
| 备选引擎 | 固定阶梯(艾宾浩斯) | 5min→30min→12h→1/2/4/7/15/30/60/120 天;答错退回第一格。只作对照与基础测试 |
| 明确不做 | SM-2 | 用户否决:FSRS-6 是主算法,不需要第三套 |
| 导入格式 | **Quizify Card Markdown v1** | 与 Anki 的 Quizify 插件同语法,卡组可双向流动;用户的 PKB 本来就是这个格式 |
| 数学公式 | 推迟。v1 显示 `$...$` 原文 | KaTeX 最小集合实测 0.53 MB(js 266KB + css 24KB + 20 个 woff2 254KB),渲染引擎是系统自带的 ArkWeb,不占安装包。不急,但不重 |
| 账号同步 | 本阶段不做,只预留 `uuid` / `updated_at` 字段 | 登录必然需要服务端,但可以让华为账号或用户自己的网盘来当那个服务端 —— 自建服务器的真实成本是 ICP 备案与《个人信息保护法》义务,不是机器钱 |
| 许可 | MIT | 注意 Anki 是 AGPL-3.0,**不要移植它的代码** |
| 数据 | 本地优先,可整库导出 | |

术语:这类软件的正式叫法是 **spaced repetition system (SRS)** / 间隔重复;
日常叫 flashcard / 闪卡。「刷卡」是刷银行卡,别用。
卡片测验这件事在认知科学里叫 **retrieval practice**(提取练习),
不是 Ericsson 的 deliberate practice —— 名字取「刻意重复」是品牌选择,不是学术断言。

## 从 WordSnap 带过来的设计经验(与平台无关,直接适用)

这些是在 WordSnap 上真实踩出来的,不要重新踩一遍。

1. **一天的边界不是午夜,是凌晨 1 点。**
   排期算出来的到期时刻带小时分钟(2.56 天后 = 次日 00:26)。按午夜切,
   深夜还在学的人刚过 0 点就会看到一批「明天的卡」冒出来。
   把界划在 01:00,`dayIndex()` 先减一小时再取整即可。

2. **但「哪一天」和「现在能不能取这张卡」是两件事。**
   取卡仍应是 `due <= now`。如果改成「到下一个 1 点之前都算到期」,
   1 分钟 / 10 分钟的学习步进卡会全部立刻到期,学习流水线就没了。

3. **今日集合在会话开始时一次定好。**
   = 到期旧词(受当日复习上限约束)+ 当日新词额度。
   这样永远不会出现「手上没卡但今天没做完」那种要靠倒计时/等待页兜的状态。
   曾经为此做了等待页 + 自动续跑,最后整套删掉 —— 集合一次取全就不需要它。

4. **复习量要有硬上限。**
   积压 1000 张时,没有上限就会打开即崩溃式的劝退。上限之外的留到明天。

5. **进度条按「今天还会不会再出现」分三段,而不是按「上次答对没有」。**
   绿 = 今天不会再出现;灰 = 今天还会再出现一次;白 = 从未出现。
   新词答对之后并没有毕业(还在 10 分钟步进里),按答对判会显示「完成了」
   而那张卡马上又冒出来 —— 那是在骗用户。

6. **每个卡组的进度、统计、额度必须完全独立。**
   任何「今天还剩多少」的计数都要按卡组存;WordSnap 曾把「学习更多」的
   追加额度存成全局 key,结果在 A 书点一次,B 书也凭空多出额度。

7. **凡是「今天还能做多少」这类计数,数据库是唯一事实来源。**
   内存里维护一份、数据库里另一份,两边生命周期不一致时减法一定出错。
   宁可每次作答后重算一次。

8. **数据授权比代码重要。**
   WordSnap 用了第三方词库(爬取自某词典),导致仓库不能公开放数据。
   REPS 的输入是**用户自己上传的书**,这是结构性优势 —— 别自己内置版权内容。

## ArkTS 的几个陷阱(平台相关,但必读)

**1. UI 只能依赖 `@State` / `@StorageLink`,绝不能依赖普通对象字段。**

按值传参的 `@Builder` 不会响应更新 —— WordSnap 在这件事上踩了**四次**:
`landingStat(value, label)`、一个 `if (store.algo === 'fsrs')` 的条件渲染、
`sectionTitle(title, hint)`、以及一个列表头的书名。每次的表现都是「数据对了但界面不刷新」,
查起来很费时间,因为编译器完全不报错。

修法是**常量选择器 `@Builder`**:传一个常量下标进去,值在 Builder 内部从 `@State` 读。

**2. ArkTS 只编译从入口可达的文件。**

新写的模块如果没有任何文件 import 它,编译器直接跳过 —— `BUILD SUCCESSFUL` 对它
毫无意义。REPS 的 `Database.ets` / `Schema.ets` / `Quizify.ets` 都中过这一枪。
验证手段:解包 HAP,`grep` 一下 `entry/build/.../modules.abc` 里有没有那些符号名。

**3. ArkTS 不支持嵌套函数声明(`arkts-no-nested-funcs`)。**

`function outer() { function inner() {} }` 直接编译失败。桌面测试台**测不出这类限制**,
因为 TypeScript 允许 —— `Quizify.ets` 的 51 条断言全绿之后编译才报错。
所以**编译必须是每个任务的验证环节,不能只跑桌面测试**。
赋值给变量的箭头函数(`const f = () => {}`)是允许的,受限的只是 `function` 声明。

**4. 中文不要穿过 hdc —— shell 命令和参数都不行。**

`hdc shell "sqlite3 ... '中文'"` 会把中文吃成 `??`,还可能连带截断 SQL。
`hdc file send 'C:\...\王道考研数据结构_Markdown\3_1.md'` 同样会变成 `????????_Markdown`
而报「文件不存在」。做法:
- 查设备数据库,SQL 一律用纯 ASCII;
- 推文件先用 WSL 的 `cp` 复制到纯 ASCII 路径(如 `/mnt/c/temp/ds_3_1.md`),再 `file send`。

## 还没决定

- **「一本书 → 卡组」的自动切分还没解决。**
  这是本项目最初的立意,但也要说清:Quizify Markdown 是一种**已经成卡**的格式
  (`+++` / `***` 已经把正反面分好了),它解决的是「导入与交换」,
  不是「把一段散文自动切成知识点」。前者是近期路径(而且用户的 PKB 现成就是这个格式,
  一上线就能全导进来),后者仍是开放问题:靠标题层级?靠段落?要不要人工确认?
- 导入的书要不要保留原文(用于「回看上下文」)还是只留卡片
- 复习界面的评级按钮是几个:FSRS 引擎内部是四级(忘了/困难/良好/简单),
  而 WordSnap 最终只给了三个按钮。REPS 用几个还没定
- 同步方案:用户自带存储(WebDAV/坚果云)还是华为账号 + AGC

## 代码地图(截至 Task 2)

```
entry/src/main/ets/
├── model/Models.ets       领域类型:Deck / Note / Card / CardState / ReviewLog / Grade / NoteType
├── srs/Srs.ets            FSRS-6(701 行,自 WordSnap 移植)
├── srs/Ebbinghaus.ets     固定阶梯(125 行)
├── entryability/          应用入口
└── pages/Index.ets        首页

devtest/                   桌面测试台,不需要模拟器
├── sync-and-test.mjs      把生产 .ets 同步成 .ts 再跑 —— 测的是生产文件本身
├── check-encoding.mjs     中文编码守卫(BOM / U+FFFD / mojibake)
├── check-manifest.mjs     36 项清单检查,含解包 HAP 抽查字节码
├── srs_test.ts            150 条断言
├── ebbinghaus_test.ts     18 条断言
└── interval_demo.ts       打印真实间隔阶梯(非测试)
```

两条硬约束:

- **`Note` 与 `Card` 必须分两层。** 一段含 3 个 `{{挖空}}` 的笔记 = 3 张各自独立排期的卡。
- **排期引擎是纯函数** `(prev, grade, now) → SrsResult`,不认识卡片内容。
  `Algo` 是 `Srs.ets` 里的字符串联合类型(`'fsrs' | 'ebbinghaus'`),不是枚举;
  `Models.ets` 不能反向 import 它(循环依赖),所以 `ReviewLog.algo` 存 `string`。

跑测试(WSL 里没有 node,必须借 DevEco 自带的):

```bash
powershell.exe -NoProfile -Command "\$env:PATH='C:\Program Files\Huawei\DevEco Studio\tools\node;'+\$env:PATH; Set-Location 'C:\Users\yicha\Development\REPS'; node devtest/sync-and-test.mjs"
```

构建:`build.cmd assembleHap`。**退出码 1 但输出里有 `BUILD SUCCESSFUL` 属于正常**
(PowerShell 把 stderr 上的警告当失败)。签名故意留空,要装真机需在 DevEco 里
勾 "Automatically generate signature"。

## 相关仓库

- `zyichang/REPS` —— 本项目
- `zyichang/WordSnap` —— HarmonyOS 背单词应用,FSRS-6 的完整实现在
  `entry/src/main/ets/srs/Srs.ets`,固定阶梯在 `Ebbinghaus.ets`,
  桌面回归测试在 `devtest/`。排期逻辑可以直接参考
- `zyichang/PKB` —— 同一想法的早期尝试,描述与本项目重复,建议归档或合并
