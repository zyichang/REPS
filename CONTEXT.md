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

## 当前版本

**v1.0.3(2026-10-26,自用稳定版;versionCode 1000003)**:功能清单见 README 的 Status。之后每次发布改 `AppScope/app.json5` 的
`versionName`,`versionCode` 只增不减(1.0.0 = 1000000;上传应用市场前必须比上一次大)。

## 已经定下的决定

| 项 | 决定 | 理由 |
|---|---|---|
| 名字 | REPS / 刻意重复 | reps 是健身的「一组组重复」;一天的量 = a set,一次作答 = a rep |
| 平台 | **HarmonyOS / ArkTS** | 核心是排期算法,而两套引擎在 WordSnap 上已用 ArkTS 实现并通过 168 条回归测试,复用比重写更可靠。早先写过「Web 优先」,已作废 |
| 存储 | `relationalStore`(SQLite) | 应用沙箱内,零权限 |
| 主排期引擎 | FSRS-6 | 已从 WordSnap 移植,`srs/Srs.ets` |
| 备选引擎 | 固定阶梯(艾宾浩斯) | 5min→30min→12h→1/2/4/7/15/30/60/120 天;答错退回第一格。只作对照与基础测试 |
| 明确不做 | SM-2 | 用户否决:FSRS-6 是主算法,不需要第三套 |
| 导入格式 | **REPS Card YAML v1 为主,Quizify Markdown 兼容导入**(2026-10-25,ADR-0007 取代 ADR-0001) | YAML 能带固定卡片 `id`(同步、版本更新靠它)和牌组 `meta`(分享);选择题用 `options` / `answer` 字段。Quizify 保留是因为用户的 PKB 是这个格式。字段表见 `docs/data-model.md` |
| 数学公式 | **已接入 KaTeX v0.18.9 + ArkWeb**(见 ADR-0003) | 语料实测行内 `$…$` 19636 处、`\frac`/`\dfrac` 一万多次、还有 `\left…\right` 与 `\begin{}` 环境 —— 原生子集拼不出来。内嵌约 600 KB,只有含公式的卡片才起 WebView |
| 主题色 | 黑白蓝:主色蓝 `#3B82F6`(按下 `#2563EB`、浅底 `#EAF1FE`),深色 `#0B0D12`;绿 `#10B981` 只表示「答对 / 掌握」(2026-10-11 起,替换微信绿 `#07C160`) | 用户觉得纯绿单调,改为与新图标(黑底白蓝书)一致 |
| 账号登录 | **恢复:华为账号 + AGC 云同步**(2026-10-23,ADR-0006 提议中) | 登录可选,不登录照常本地使用。以下是 2026-10-10 移除时的旧记录:不做账号。换华为手机时的记录迁移改走:整库导出/导入文件(主)+ BackupExtensionAbility 系统备份/手机克隆(附带,侧载应用是否生效待真机验证)。「删卡组连带删掉复习流水」已于 2026-10-14 解决(ADR-0005:流水永不删除)。其余为后续任务 |
| 账号同步 | **AGC 认证服务 + 云数据库 + 云存储,只用免费套餐**(ADR-0006,已接受);作答数据只上传每日汇总 `daily_stat`(按设备分行);云存储放 App 导出的带 `id` 的 YAML | 登录必然需要服务端,但可以让华为账号或用户自己的网盘来当那个服务端 —— 自建服务器的真实成本是 ICP 备案与《个人信息保护法》义务,不是机器钱 |
| 牌组结构 | **Anki 式多牌组,没有「当前卡组」**(2026-10-14,ADR-0004) | 学习页列出所有牌组,各学各的;浏览页是 Anki 式浏览器;每日上限对每组各算一份;牌组暂保持扁平 |
| 复习流水 | **永不删除**(2026-10-14,ADR-0005) | 删牌组 / 删卡不删流水,清空进度只归档;统计页「综合统计」按整个应用算,含已删牌组 |
| 应用图标 | **一叠卡片 + 循环箭头,背景浅海青 `#22D3EE` → 深海蓝 `#2563EB`**(2026-10-25,方案 C8) | 卡片一遍遍回来 = 刻意重复;由浅海到深海 = 学得越久潜得越深。源文件 `design/app-icon*.svg`,导出 `design/export/`,对比稿与落选方案 `design/icon-concepts/` |
| 语言 | 跟随系统(默认)/ 中文 / English | 系统是 zh-* 显示中文,其余英文 |
| 打卡 | 学习页「今日」卡片上手动打卡;**学习天数 = 打卡天数**,连续天数「漏一天不断、连漏两天才断」;不可撤销;上线时按作答记录回填 | 打卡是用户自己说「今天就到这里」;热力图仍按作答量,两者独立 |
| 周的起点 | 周日(热力图的行、打卡月历的列) | 用户指定 |
| 许可 | MIT | 注意 Anki 是 AGPL-3.0,**不要移植它的代码** |
| 数据 | 本地优先,可整库导出 | |

术语:这类软件的正式叫法是 **spaced repetition system (SRS)** / 间隔重复;
日常叫 flashcard / 闪卡。「刷卡」是刷银行卡,别用。
卡片测验这件事在认知科学里叫 **retrieval practice**(提取练习),
不是 Ericsson 的 deliberate practice —— 名字取「刻意重复」是品牌选择,不是学术断言。

## 从 WordSnap 带过来的设计经验(与平台无关,直接适用)

这些是在 WordSnap 上真实踩出来的,不要重新踩一遍。

1. **一天的边界不是午夜,是凌晨 3 点**(2026-10-14 由 1 点改为 3 点,打卡与其余口径共用这一个日界)。
   排期算出来的到期时刻带小时分钟(2.56 天后 = 次日 00:26)。按午夜切,
   深夜还在学的人刚过 0 点就会看到一批「明天的卡」冒出来。
   把界划在 03:00,`dayIndex()` 先减三小时再取整即可。

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

**按值传参的 @Builder 不响应更新 —— 这条已经犯了五次,记住它的症状。**

典型现象:**一部分内容更新了,另一部分停在上一次的值。** 学习页上表现为
「翻到下一张卡,选项变了,题干没变」,因为选项走 `optionRow(i)`(常量下标 +
内部读状态),题干走 `cardText(this.cardStem, ...)`(把文字当参数传进去)。
预览页、标签栏、语言切换、FSRS 面板都栽在同一件事上。

规则:**@Builder 只接常量(下标、枚举),文字和状态一律在内部现取。**
要把状态传下去就传给 @Component(@Prop 配 @Watch 会更新),不要传给 @Builder。


**uitest 的 `dircFling` 在这台模拟器上不滚动,长按拖拽才行。**
排查「设置页划不到底」浪费了很久,最后发现页面本来就是好的,是手势没生效:

```
hdc shell uitest uiInput dircFling 2 3000      # 无效,页面不动
hdc shell uinput -T -g 660 1700 660 500 800 1500   # 有效(按住 800ms,总时长 1500ms)
```

另外 `uitest dumpLayout` **只报可视区域内的节点**。所以「某个控件不在 dump 里」
不等于它没渲染,很可能只是在屏幕外 —— 别据此去改布局。


**`@Prop` 想在父组件换值时重新跑逻辑,必须配 `@Watch`。**
翻到下一张卡时 ArkUI 复用同一个组件实例,只更新 `@Prop`,**不会再调
`aboutToAppear`**。MathText 少了 `@Watch` 就一直显示上一张卡的公式,
现象隐蔽:高度和上一张一模一样,也没有新日志。`MarkupText`/`DecksPage`
早就是这个写法,照抄。

**`throw e` 过不了编译(arkts-limited-throw)。**
catch 到的值类型是任意的,ArkTS 不允许直接再抛。要收敛成一个具体的
Error 子类型再抛,例如 `throw new QuizifyError(\`…: ${detail}\`, line)`。


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

**5. relationalStore 事务里,`querySqlSync` 看不到本事务刚写的行。**
读走单独的连接。`beginTransaction()` 之后 INSERT 再 SELECT 回来,查不到 —— 新 id 一律取
`insertSync()` 的返回值,不要 `SELECT MAX(id)`。桌面测试(node:sqlite 单连接)**测不出**这一条,
2026-10-25 导入新牌组在模拟器上报「卡组创建失败」才发现。

**6. 文档选择器的 `fileSuffixFilters`:一个元素 = 「文件类型」下拉的一项,默认只启用第一项。**
要同时显示多种后缀,合成一项:`['描述|.yaml,.yml,.md']`。写成四个元素时 YAML 文件在选择器里根本看不见。
往模拟器推测试文件用 `devtest/push_testdata.sh`(放进 Documents;Download 里推进去的文件选择器不显示)。

**7. AGC 云数据库对象类型 JSON:控制台「导入」的格式和 DevEco 模板不一样。**
2026-10-25 试了三次才导入成功(最终文件 `cloud/clouddb/reps_sync.json`,存储区叫 `REPS`):
- 权限要放在**顶层** `permissions: [{ objectTypeName, permissions: [...] }]`;放在对象类型里面(DevEco 模板
  `[CloudDev]Empty Ability/.../clouddb/objecttype/Post.json` 的写法)会报「对象类型未设置权限」。
- **非空且非主键的字段必须有 `defaultValue`,写成字符串**(`""`、`"0"`、`"false"`),否则报「非空情况下未设置默认值」。
  主键不写默认值。
- Long / Text / Boolean 都可用(模板里只出现了 String / Integer / Date)。
- agcli 1.12.0 的 `db import-object` 报 502,只能在控制台导入;但 `db list-zone` / `list-object` 可用于只读核对。
- 写这类配置文件之前先找官方样例对照,不要凭记忆。
- **端侧还要一份 `entry/src/main/resources/rawfile/schema.json`**(对象类型 + 权限),没有它 cloudDatabase 报
  「schema parse fail or objectTypeName error」。用 `agcli db export-object -d <目录>` 导出,改名放进 rawfile。
  对象类型一改就要重新导出。核对云端数据:`agcli db export-data --mode Local --encryptMode UnEncrypt --zone REPS --object reps_sync --path <目录>`。
- agcli 偶尔报 ERR_SERVER_AUTH / ERR_SERVER_BAD_GATEWAY,隔一会儿重试就好,不是项目没选的问题。

## 还没决定

- **「一本书 → 卡组」的自动切分还没解决。**
  这是本项目最初的立意,但也要说清:Quizify Markdown 是一种**已经成卡**的格式
  (`+++` / `***` 已经把正反面分好了),它解决的是「导入与交换」,
  不是「把一段散文自动切成知识点」。前者是近期路径(而且用户的 PKB 现成就是这个格式,
  一上线就能全导进来),后者仍是开放问题:靠标题层级?靠段落?要不要人工确认?
- 导入的书要不要保留原文(用于「回看上下文」)还是只留卡片
- 复习界面的评级按钮是几个:FSRS 引擎内部是四级(忘了/困难/良好/简单),
  而 WordSnap 最终只给了三个按钮。REPS 用几个还没定
- 同步方案已定:华为账号 + AGC,作答数据用每日汇总(ADR-0006)。实现分在 Task 7–12,数据结构见 `docs/data-model.md`
- 牌组广场:第一阶段用户导出 `.yaml` 发给开发者,审核后用 `tools/publish-deck` 上架到云存储 `public/`;用户直传与防滥用是第二阶段

## 代码地图(截至 2026-10-14,Anki 式多牌组之后)

结构见 ADR-0004:学习页根是牌组列表,浏览页是 Anki 式浏览器,**没有「当前卡组」**。

```
entry/src/main/ets/
├── entryability/EntryAbility.ets  入口;设置键盘避让 RESIZE
├── pages/Index.ets         四个标签:学习 / 统计 / 浏览 / 我的;只有「我的」用返回计数器
├── view/StudyTab.ets       学习页根:牌组列表(Navigation + NavPathStack),⋯ 清空/删除,导入
├── view/StudyPage.ets      一个牌组的页面(NavDestination):概览 → 作答 → 做完
├── view/BrowserTab.ets     浏览器:卡组过滤 + 搜索 + 列表 → 预览 → 编辑 / 新建
├── view/StatsPage.ets      统计:上半段全部,下半段按所选牌组(默认全部)
├── view/ProfilePage.ets    设置:算法、今日集合、格式、语言
├── view/DeckColors.ets     新 / 学习中 / 待复习 三色,列表与概览共用
├── view/ArrayDataSource.ets LazyForEach 的数据源
├── view/MarkupText / MathText / BookCover
├── data/Schema.ets         DDL + 全部 SQL + 纯函数(deckCounts 的 applyDeckLimits、escapeLike)
├── data/Database.ets       relationalStore 封装
├── data/Quizify / Yaml / Inline / Importer   解析与导入
├── store/AppStore.ets      数据库连接 + 全局设置 + SK_TICK 重绘计数
├── srs/Srs.ets             FSRS-6;srs/Ebbinghaus.ets 固定阶梯
└── i18n/Strings.ets        中英文案(两个字典字段必须一一对应)

devtest/                   桌面测试台,不需要模拟器(14 套)
├── sync-and-test.mjs      把生产 .ets 同步成 .ts 再跑 —— 测的是生产文件本身
├── deckcounts_test.ts     牌组列表计数 vs 概览页逐组查询,逐列对拍
├── browse_test.ts         浏览器搜索:过滤、% _ \ 字面量、中文
├── check-encoding.mjs     中文编码守卫(BOM / U+FFFD / mojibake)
├── check-manifest.mjs     36 项清单检查,含解包 HAP 抽查字节码
└── …                      srs / ebbinghaus / schema / parser / cards / stats 等
```

**Navigation 的坑:** `navDestination` 必须传**顶层 `@Builder` 函数**,内联 lambda
过不了 strict 编译;路由页根节点是 `NavDestination`,返回用 `.onBackPressed()`
(返回 true 表示自己处理了,比如作答中先回概览)。

**LazyForEach 的数据源不能混用通知接口:** 用过 `onDatasetChange` 之后再调
`onDataReloaded` 会抛错。`ArrayDataSource` 全部走 `onDatasetChange`。
**列表行按下标取数据时要做越界保护**(`rowAt` / `deckAt`):数组被重置成更短时,
旧下标的行会先重绘一次才被换掉,直接 `this.rows[i].x` 会 JS 崩溃。

**热力图必须按星期对齐**(`Schema.heatCells`):行 = 周一…周日,最后一列 = 本周,
今天之后留空。按「从今天往前数 N 天」摆格子,今天会永远落在周日那一行。

**`Path` 的 `commands` 单位是 px,不是 vp。** 按 vp 设计的坐标要先过 `vp2px`,
否则高密度屏上图形缩在角落里(标签栏「我的」图标的肩膀就这么丢了一半)。

**跟日期有关的显示一律走日序号**(`dayIndex` / `weekdaySun0` / `calendarDate`),
不要用 `new Date(now - i 天).getDay()`:凌晨 0~3 点时钟表日期和日序号差一天,
「最近 7 天」的星期标签曾因此整体错位。

**`fmt` 按顺序填占位符**,中英两个模板的参数顺序必须一致 —— 清空进度的确认文案
曾因中文是 `%s %d`、调用传 `(张数, 名字)` 而显示成「「21」的 Miscellaneous 张卡」。

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
