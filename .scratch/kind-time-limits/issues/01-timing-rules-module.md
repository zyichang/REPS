# 01 — 把计时规则搬进一个纯逻辑模块(预备重构,行为不变)

Status: ready-for-agent

## Parent

`.scratch/kind-time-limits/PRD.md`

## What to build

学习页现在自己计算所有计时规则:选择题的三条线(10 / 30 / 60 秒)、按用时自动评分、学习时长的两段封顶
(答题段:选择题 60 秒,问答卡和挖空卡的正面 5 分钟;看解析:5 分钟)。把这些规则搬进一个新的纯逻辑模块,
学习页只调用它、只负责显示。**用户看到的行为完全不变。**

模块的接口按「这张卡的上限是多少」来设计:选择题的简单 / 良好线写成上限的 1/6 和 1/2,上限 60 秒时正好是现在的
10 秒和 30 秒。这样后面的 issue 只需要换一个上限,不用再改评分逻辑。

## Acceptance criteria

- [ ] 新模块不依赖任何 `@kit.*`,登记进桌面测试台的同步清单,有自己的测试套件并加入测试台。
- [ ] 学习页 import 并使用它(否则 ArkTS 不会编译它);学习页里不再有计时阈值常量,也不再自己算评分和封顶。
- [ ] 单元测试覆盖:答错 → 忘了;答对按用时落到简单 / 良好 / 困难;没毕业的卡最高只给良好;答题段和看解析段的封顶;
      负的时长(系统时间被往回调)记 0。
- [ ] 评分线由上限按 1/6、1/2 算出;上限 60 秒时结果与现在完全一致。
- [ ] 完整桌面测试台通过;ArkTS 构建成功,改动的文件没有新增警告。

## Blocked by

None - can start immediately

## Comments

### 2026-11-02 · 已完成(待提交)

- 新模块 `model/Timing.ets`(放在 `model/`,和同样是从界面搬出来的 `Steps.ets` 一起):上限 `answerLimitMs`、
  是否超时 `timesOut`、判档线 `easyLineMs` / `goodLineMs`、判档 `choiceGrade`、两段封顶 `answerSegmentMs` /
  `explainSegmentMs`。判档线写成「上限 / 6」「上限 / 2」的除法:乘 1/6 有浮点误差,压线的 10 秒可能被判成良好。
- 学习页换卡时取一次 `limitMs`(@State,倒计时和变红都读它)和 `cardTimesOut`;计时阈值常量、`clampMs`、`autoGrade` 都删掉了。
  02 起只需要改模块里「这张卡的上限怎么算」。
- 测试:`devtest/timing_test.ts` 33 条,登记进同步清单和套件列表,同步出来的 `devtest/Timing.ts` 加进 .gitignore。
  完整桌面测试台 26 / 26 通过。
- clean 构建 BUILD SUCCESSFUL,`StudyPage.ets` 和 `Timing.ets` 没有警告;解包 HAP,`modules.abc` 里有 `choiceGrade` 等符号,
  确认模块真的被编译进去了。
- 行为不变是逐条对过的:上限 60 秒时判档线正好是 10 / 30 秒;问答 / 挖空的上限仍是 5 分钟且不超时,倒计时照旧不显示。
  这一条是纯重构,没有在模拟器上手动跑。
