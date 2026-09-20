/**
 * SRS 引擎独立验证:不依赖 HarmonyOS 运行时,直接跑真实引擎代码。
 * 由 devtest/sync-and-test.mjs 把生产文件 entry/.../srs/Srs.ets 同步为 devtest/srs.ts 后执行。
 *
 * 这一版验证的是**真正的 FSRS-6**(逐行对齐官方 py-fsrs scheduler.py)。
 * 纪律:每条期望值都按官方公式手算,算式写在注释里 —— 不允许「先跑一遍、把实际输出抄成期望值」,
 * 那只会把 bug 一起盖章成「正确」。所以如果某个手算值与实际不符,那是引擎的问题,先报出来,
 * 不要改测试去迁就。
 *
 * 注意:本文件必须用 UTF-8 保存,不要用 PowerShell 直接改写(会把中文写坏)。
 */

import { Grade, LearnPhase, CardState } from './Models';
import {
  DAY_MS, MIN_MS, DEFAULT_W, W_COUNT, FsrsParams, formatInterval, getFsrsParams,
  intervalForRetention, masteryOf, masteryPercent, newCardState, retrievability,
  sanitizeW, schedule, setFsrsParams, setRandomSource,
} from './srs';

let pass = 0;
let fail = 0;

function check(name: string, cond: boolean, extra: string = ''): void {
  if (cond) {
    pass++;
    console.log(`  PASS  ${name}${extra ? '  ' + extra : ''}`);
  } else {
    fail++;
    console.log(`  FAIL  ${name}${extra ? '  ' + extra : ''}`);
  }
}

function near(a: number, b: number, tol: number): boolean {
  return Math.abs(a - b) <= tol;
}

const T0 = 1_700_000_000_000;

/** 可复现的伪随机数(LCG),用来替换引擎的随机源 */
function makeRng(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

// 引擎的间隔扰动默认走 Math.random,那会让本文件的断言每次跑都不一样。
// 换成固定种子后结果完全可复现;专门测扰动的用例会再显式指定种子。
setRandomSource(makeRng(12345));

/**
 * 关掉间隔扰动的排期。
 * 稳定性/难度/阶段迁移与扰动无关,但扰动会改变「下次到期时间」,进而改变后续复习的
 * elapsedDays 与 R —— 想把数值写死就必须关掉它(界面上的「预计间隔」预览也是这么调的)。
 */
function plan(prev: CardState, g: Grade, now: number) {
  return schedule(prev, g, now, false);
}

/** 临时改引擎参数跑一段,跑完恢复。参数是模块级单例,不恢复会污染后面的用例 */
function withParams(patch: (p: FsrsParams) => void, fn: () => void): void {
  const saved = getFsrsParams().clone();
  const p = getFsrsParams().clone();
  patch(p);
  setFsrsParams(p);
  try {
    fn();
  } finally {
    setFsrsParams(saved);
  }
}

/**
 * 造一个已经进入 Review 阶段的卡。
 * 动线(默认步进 [1,10],全程「良好」):
 *   T0      + Good → 首次作答,S = w[2] = 2.3065,Learning step 0→1,10 分钟后再认
 *   T0+2d   + Good → 同日?不,已隔 2 天 → 长期公式 S = 10.9710482631,走完步进毕业,排期 11 天
 *   T0+6d   + Good → 距上次 4 天,R = 0.9539827 → S = 26.8427518878
 * 第 1、2 次之间的真实间隔是 10 分钟(第 1 次给的 due),但这里固定用 T0+2d 复习,
 * 属于「拖了两天才复习」,所以第 2 次走的是长期记忆路径,而不是短期路径。
 */
function reviewWord(id: number): CardState {
  let cur = plan(newCardState(id, T0), Grade.Good, T0).state;
  cur = plan(cur, Grade.Good, T0 + 2 * DAY_MS).state;
  cur = plan(cur, Grade.Good, T0 + 6 * DAY_MS).state;
  return cur;
}

console.log('=== 1. 遗忘曲线的基本性质 ===');
{
  // R(t,S) = (1 + FACTOR*t/S)^DECAY
  //   DECAY  = -w[20] = -0.1542
  //   FACTOR = 0.9^(1/DECAY) - 1 = 0.9^(-6.4850843) - 1 = 1.9803465 - 1 = 0.9803464944
  // 老引擎把 DECAY 写死成 -0.5(FACTOR = 0.9^-2 - 1 = 0.2345679),衰减快得多;第 5 节有对照。
  const s = 10;
  const r0 = retrievability(0, s);
  const r1 = retrievability(5, s);
  const r2 = retrievability(10, s);
  const r3 = retrievability(30, s);
  check('R(t=0) = 1', near(r0, 1, 1e-9), `实际 ${r0.toFixed(6)}`);
  check('R 随 t 单调下降', r0 > r1 && r1 > r2 && r2 > r3,
    `${r0.toFixed(3)} > ${r1.toFixed(3)} > ${r2.toFixed(3)} > ${r3.toFixed(3)}`);
  check('R(t=S) = 0.9  —— 「稳定性」可直接读作「保持 90% 的时限(天)」',
    near(retrievability(s, s), 0.9, 1e-9), `实际 ${retrievability(s, s).toFixed(6)}`);
  check('S 越大 R 越高', retrievability(30, 100) > retrievability(30, 10),
    `S=100: ${retrievability(30, 100).toFixed(3)} vs S=10: ${retrievability(30, 10).toFixed(3)}`);
  // 顺手把新曲线的两个基准点钉住(第 5 节会用到):R(2S,S) / R(5S,S) 与 S 无关,只由 DECAY 决定
  check('R(t=2S) = (1+2*0.9803465)^-0.1542 = 0.8458846',
    near(retrievability(2 * 90, 90), 0.8458846, 1e-6), `实际 ${retrievability(180, 90).toFixed(7)}`);
  check('R(t=5S) = (1+5*0.9803465)^-0.1542 = 0.7605276',
    near(retrievability(5 * 90, 90), 0.7605276, 1e-6), `实际 ${retrievability(450, 90).toFixed(7)}`);
}

console.log('=== 2. 间隔反解的方向性 ===');
{
  // intervalForRetention(S, r) = clamp(S/FACTOR * (r^(1/DECAY) - 1), 1, maximumInterval)
  // r = 0.9 时 r^(1/DECAY) = 0.9^(1/DECAY) = 1 + FACTOR,所以结果恰好等于 S —— FSRS 的定义性质。
  check('目标 90% 时间隔 = S', near(intervalForRetention(12, 0.9), 12, 1e-6),
    `实际 ${intervalForRetention(12, 0.9).toFixed(4)} 天`);
  // 93%:12/0.9803465*(0.93^-6.4850843 - 1) = 12.24057*(1.6009843-1) = 12.24057*0.6009843 = 7.3564
  // 80%:12/0.9803465*(0.80^-6.4850843 - 1) = 12.24057*(4.2510852-1) = 12.24057*3.2510852 = 39.7951
  check('保持率要求越高 -> 间隔越短',
    intervalForRetention(12, 0.93) < intervalForRetention(12, 0.9)
    && intervalForRetention(12, 0.9) < intervalForRetention(12, 0.80),
    `93%: ${intervalForRetention(12, 0.93).toFixed(2)} < 90%: 12.00 < 80%: ${intervalForRetention(12, 0.80).toFixed(2)} 天`);
  check('间隔有下限 1 天', intervalForRetention(0.001, 0.9) >= 1,
    `${intervalForRetention(0.001, 0.9).toFixed(2)} 天`);
}

console.log('=== 2b. 同一张卡、同一时刻,四个评级的排期必须严格递增 ===');
{
  // 这一条是整个引擎最关键的语义保证:
  // 用户点「简单」不可能比点「困难」排得更近。TARGET_R 按评级分配时踩过这个坑,这里做回归。
  // 每次都从**同一个已进入 Review 的状态**出发,否则难度漂移会污染对比。
  // 关掉扰动:2b 想验证的是引擎语义,而扰动是 UI 层的随机化,开着它 29/34/40 这种数字会随机漂
  // (而且理论上 Hard 上界可能压到 Good 下界之上,断言本身就会变成抛硬币)。
  const iv = (g: Grade): number => plan(reviewWord(99), g, T0 + 8 * DAY_MS).intervalDays;
  const iAgain = iv(Grade.Again);
  const iHard = iv(Grade.Hard);
  const iGood = iv(Grade.Good);
  const iEasy = iv(Grade.Easy);
  // 忘了 → Review 阶段进 Relearning,间隔 = relearningSteps[0] = 10 分钟 = 0.0069444 天
  // 困难/良好/简单的稳定性:31.5083326304 / 34.6006181044 / 41.3724595248
  // 保持率 0.9 时间隔 = round(S),所以是 32 / 35 / 41 天
  console.log(`  间隔: 忘了 ${(iAgain * 1440).toFixed(0)} 分钟 / 困难 ${iHard.toFixed(1)} 天 / 良好 ${iGood.toFixed(1)} 天 / 简单 ${iEasy.toFixed(1)} 天`);
  check('四档间隔严格递增', iAgain < iHard && iHard < iGood && iGood < iEasy,
    `${(iAgain * 1440).toFixed(0)} 分钟 < ${iHard} < ${iGood} < ${iEasy} 天`);
  check('间隔就是 round(稳定性):32 / 35 / 41', iHard === 32 && iGood === 35 && iEasy === 41,
    `${iHard} / ${iGood} / ${iEasy}`);
  check('忘了排得最近', iAgain < iHard, `${(iAgain * 1440).toFixed(1)} 分钟 < ${iHard.toFixed(1)} 天`);
}

console.log('=== 3. 评级对稳定性的影响 ===');
{
  // 复习前:S = 26.8427518878,D = 2.1043313908,R = retrievability(2, S) = 0.9891879
  // 忘了:S' = min(1.4835*D^-0.0614*((S+1)^0.2629-1)*e^((1-R)*1.6483), S/e^(0.5425*0.0912))
  //          = min(2.0166773, 25.547) = 2.0166773 → ×0.0751293
  // 回忆成功的共同因子 G = e^1.8722*(11-D)*S^-0.1666*(e^((1-R)*0.796)-1)
  //   = 6.5032605*8.8956686*0.4702413*0.0828534 = 0.2890115
  //   困难 = 1 + G*w[15] = 1 + 0.2890115*0.6014 = 1.1738116  ← w[15] 是惩罚但不是反转
  //   良好 = 1 + G       = 1.2890116
  //   简单 = 1 + G*w[16] = 1 + 0.2890115*1.8729 = 1.5412898
  const ratio = (g: Grade): number => {
    const st = reviewWord(1);
    const before = st.stability;
    const after = plan(st, g, T0 + 8 * DAY_MS).state.stability;
    return after / before;
  };
  const again = ratio(Grade.Again);
  const hard = ratio(Grade.Hard);
  const good = ratio(Grade.Good);
  const easy = ratio(Grade.Easy);
  console.log(`  稳定性变化倍数: 忘了 ×${again.toFixed(3)} / 困难 ×${hard.toFixed(3)} / 良好 ×${good.toFixed(3)} / 简单 ×${easy.toFixed(3)}`);
  check('忘记会使稳定性下降', again < 1, `×${again.toFixed(3)}`);
  check('困难 < 良好 < 简单', hard < good && good < easy,
    `${hard.toFixed(3)} < ${good.toFixed(3)} < ${easy.toFixed(3)}`);
  check('困难仍略有增长(困难惩罚 0.6014 只削弱不反转)', hard > 1.0, `×${hard.toFixed(3)}`);
  check('四个倍数与手算一致: 0.0751293 / 1.1738116 / 1.2890116 / 1.5412898',
    near(again, 0.0751293, 1e-6) && near(hard, 1.1738116, 1e-6)
    && near(good, 1.2890116, 1e-6) && near(easy, 1.5412898, 1e-6),
    `${again.toFixed(7)} / ${hard.toFixed(7)} / ${good.toFixed(7)} / ${easy.toFixed(7)}`);
}

console.log('=== 4. 难度 ===');
{
  // nextDifficulty(D, grade):
  //   arg1 = w[4] - e^(w[5]*3) + 1 = 6.4133 - 12.1849307 + 1 = -4.7716307032(不夹取)
  //   delta = -(w[6]*(grade-2)) = -(3.0194*(grade-2))
  //   arg2 = D + (10-D)*delta/9
  //   D' = clamp(w[7]*arg1 + (1-w[7])*arg2, 1, 10) = clamp(0.001*arg1 + 0.999*arg2, 1, 10)
  // 起点 D = 2.1043313908(10-D = 7.8956686092):
  //   忘了(0): delta = 6.0388 → arg2 = 2.1043314+7.8956686*6.0388/9 = 7.4021496 → D' = 7.3899758
  //   困难(1): delta = 3.0194 → arg2 = 2.1043314+7.8956686*3.0194/9 = 4.7532405 → D' = 4.7437156
  //   良好(2): delta = 0      → arg2 = D = 2.1043314 → D' = -0.0047716+0.999*2.1043314 = 2.0974554
  //   简单(3): delta = -3.0194→ arg2 = -0.5445777 → D' = -0.5488048 → 夹到 1
  const diff = (g: Grade): number => plan(reviewWord(2), g, T0 + 8 * DAY_MS).state.difficulty;
  const dAgain = diff(Grade.Again);
  const dHard = diff(Grade.Hard);
  const dGood = diff(Grade.Good);
  const dEasy = diff(Grade.Easy);
  console.log(`  难度: 忘了 ${dAgain.toFixed(2)} / 困难 ${dHard.toFixed(2)} / 良好 ${dGood.toFixed(2)} / 简单 ${dEasy.toFixed(2)}`);
  check('忘记使难度上升最多', dAgain > dHard);
  check('良好高于简单', dGood > dEasy);
  check('难度被夹在 1~10', dAgain <= 10 && dEasy >= 1);
  check('四个难度与手算一致: 7.3899758 / 4.7437156 / 2.0974554 / 1(简单被夹取)',
    near(dAgain, 7.3899758, 1e-6) && near(dHard, 4.7437156, 1e-6)
    && near(dGood, 2.0974554, 1e-6) && dEasy === 1,
    `${dAgain.toFixed(7)} / ${dHard.toFixed(7)} / ${dGood.toFixed(7)} / ${dEasy.toFixed(7)}`);
}

console.log('=== 5. 学习阶段 -> 复习阶段 的完整动线(FSRS-6 默认步进 [1,10]) ===');
{
  const now = T0;
  const s0 = newCardState(7, now);
  check('新卡初始阶段 = New', s0.phase === LearnPhase.New);

  // 第 1 次:首次作答 → S = w[2] = 2.3065,D = w[4]-e^(w[5]*2)+1 = 2.1181039705
  //   定间隔:curStep=0,Good 且 curStep+1=1 < len=2 → 不毕业,nextStep=1,间隔 = learningSteps[1] = 10 分钟
  const r1 = plan(s0, Grade.Good, now);
  console.log(`  第 1 次(良好): ${r1.reason}`);
  check('第一次作答进入 Learning', r1.state.phase === LearnPhase.Learning, `phase=${r1.state.phase}`);
  check('第一次间隔 = learningSteps[1] = 10 分钟', near(r1.intervalDays * 1440, 10, 1e-9),
    `${(r1.intervalDays * 1440).toFixed(0)} 分钟`);
  check('第一次稳定性 = w[2] = 2.3065', near(r1.state.stability, 2.3065, 1e-9), `S=${r1.state.stability}`);
  check('第一次难度 = 2.1181039705', near(r1.state.difficulty, 2.1181039705, 1e-9), `D=${r1.state.difficulty}`);

  // 第 2 次:距上次 10 分钟 → floor(10/1440) = 0 < 1,走**短期记忆**路径
  //   inc = e^(w[17]*(2-2+w[18])) * S^-w[19] = e^(0.5425*0.0912) * 2.3065^-0.0658
  //       = 1.0507204 * 0.9464936 = 0.9945001 → Good 有 max(inc,1.0) 托底 → inc = 1
  //   S' = 2.3065 * 1 = 2.3065(不变)
  //   定间隔:curStep=1,Good 且 curStep+1=2 >= len=2 → **毕业进 Review**,间隔 = round(2.3065) = 2 天
  //   (2 < 2.5,所以连扰动都不施加)→ 新卡只要连认两次「良好」就毕业,老引擎要三次。
  const t2 = now + Math.round(r1.intervalDays * DAY_MS);
  const r2 = plan(r1.state, Grade.Good, t2);
  console.log(`  第 2 次(良好): ${r2.reason}`);
  check('第二次(良好)即毕业进入 Review', r2.state.phase === LearnPhase.Review, `phase=${r2.state.phase}`);
  check('毕业间隔 = round(2.3065) = 2 天', r2.intervalDays === 2, `${r2.intervalDays} 天`);
  check('同日重复 S 不变(inc 被 max(1.0) 托底)', near(r2.state.stability, 2.3065, 1e-9),
    `S=${r2.state.stability}`);

  // 第 3 次:距上次 2 天 → 长期路径
  //   R = (1+0.9803465*2/2.3065)^-0.1542 = 1.8500622^-0.1542 = 0.9094929
  //   S' = S*(1+G),G = e^1.8722*(11-2.1112142)*2.3065^-0.1666*(e^((1-0.9094929)*0.796)-1) = 3.7565483
  //      = 2.3065*(1+3.7565483) = 10.9710482631 → 间隔 = round(10.9710483) = 11 天
  const t3 = t2 + Math.round(r2.intervalDays * DAY_MS);
  const r3 = plan(r2.state, Grade.Good, t3);
  console.log(`  第 3 次(良好): ${r3.reason}`);
  check('长期复习稳定性 2.3065 → 10.9710483', near(r3.state.stability, 10.9710483, 1e-6),
    `S=${r3.state.stability}`);
  check('间隔 = round(10.9710483) = 11 天', r3.intervalDays === 11, `${r3.intervalDays} 天`);

  // 第 4 次:距上次 11 天,点「忘了」
  //   R = (1+0.9803465*11/10.9710483)^-0.1542 = 1.9829840^-0.1542 = 0.8998188
  //   S' = min(1.4835*2.1043314^-0.0614*((10.9710483+1)^0.2629-1)*e^(0.1001812*1.6483), S/e^(0.5425*0.0912))
  //      = min(1.5390125, 10.4410) = 1.5390125
  //   Review 阶段 Again(默认 relearningSteps=[10])→ 进 **Relearning**,间隔 = 10 分钟(不是老引擎的 1 分钟)
  const t4 = t3 + Math.round(r3.intervalDays * DAY_MS);
  const r4 = plan(r3.state, Grade.Again, t4);
  console.log(`  第 4 次(忘了): ${r4.reason}`);
  check('忘记后进入 Relearning', r4.state.phase === LearnPhase.Relearning, `phase=${r4.state.phase}`);
  check('忘记后回到重学最短步进 relearningSteps[0] = 10 分钟',
    near(r4.intervalDays * 1440, 10, 1e-9), `${(r4.intervalDays * 1440).toFixed(1)} 分钟`);
  check('忘记计入 lapses', r4.state.lapses === 1, `lapses=${r4.state.lapses}`);
  check('忘记使稳定性 10.9710483 → 1.5390125', near(r4.state.stability, 1.5390125, 1e-6),
    `S=${r4.state.stability}`);

  // 第 5 次:重学后 10 分钟再认,「良好」→ 同日短期路径
  //   inc = e^(0.5425*0.0912) * 1.5390125^-0.0658 = 1.0507204*0.9720 = 1.0213… → S' = 1.5718415898
  //   relearningSteps=[10] 只有一步,step+1 = 1 >= 1 → 通过重学,回 Review,间隔 = round(1.5718416) = 2 天
  const t5 = t4 + Math.round(r4.intervalDays * DAY_MS);
  const r5 = plan(r4.state, Grade.Good, t5);
  console.log(`  第 5 次(良好): ${r5.reason}`);
  check('重学通过后回到 Review', r5.state.phase === LearnPhase.Review, `phase=${r5.state.phase}`);
  check('重学通过间隔 = round(1.5718416) = 2 天', r5.intervalDays === 2, `${r5.intervalDays} 天`);
}

console.log('=== 6. 「简单」可以跳过学习步进 ===');
{
  // 首次作答 Easy:S = w[3] = 8.2956;D = w[4]-e^(w[5]*3)+1 = -4.7716307 → 夹到 1
  // Easy 无条件毕业进 Review,间隔 = round(8.2956) = 8 天
  const r = plan(newCardState(9, T0), Grade.Easy, T0);
  console.log(`  新卡 + 简单: ${r.reason}`);
  check('简单直接毕业', r.state.phase === LearnPhase.Review, `phase=${r.state.phase}`);
  check('间隔 = round(w[3]) = 8 天', r.intervalDays === 8, `${r.intervalDays} 天`);
  check('稳定性 = w[3] = 8.2956', near(r.state.stability, 8.2956, 1e-9), `S=${r.state.stability}`);
  check('难度被夹到下限 1(原始值 -4.7716307)', r.state.difficulty === 1, `D=${r.state.difficulty}`);
}

console.log('=== 7. 连续答对 10 次,间隔演化是否健康 ===');
{
  // 关掉扰动,这张表才能逐行手算复核(#n 的间隔 = round(S_n),S_{n+1} 由 R = R(间隔_n, S_n) 推出)
  let now = T0;
  let st = newCardState(11, now);
  const rows: string[] = [];
  const ivls: number[] = [];
  const stab: number[] = [];
  for (let i = 1; i <= 10; i++) {
    const r = plan(st, Grade.Good, now);
    rows.push(
      `  #${String(i).padStart(2)}  间隔 ${formatInterval(r.intervalDays).padEnd(9)}` +
      `  S=${r.state.stability.toFixed(2).padStart(8)}天` +
      `  D=${r.state.difficulty.toFixed(2)}` +
      `  R前=${r.retrievability > 0 ? (r.retrievability * 100).toFixed(0) + '%' : '--'}`
    );
    ivls.push(r.intervalDays);
    stab.push(r.state.stability);
    st = r.state;
    now = now + Math.round(r.intervalDays * DAY_MS);
  }
  console.log(rows.join('\n'));
  // 手算基准:#1 10 分钟 → #2 2 天 → #3 11 天 → #4 round(46.3168584) = 46 → #5 round(162.9998158) = 163
  //          #6 498 → #7 1348 → #8 3299 → #9 7415 → #10 round(15504.1741948) = 15504
  // #1→#2 是同一天(R 记为 1);从 #3 起每次都复习在到期日上,R 都在 0.900 附近,
  // 所以 S 按「每轮 ×4 上下」稳定滚大,而不是指数爆掉。
  check('间隔逐次严格变长', ivls.every((v, i) => i === 0 || v > ivls[i - 1]),
    ivls.map((v) => (v < 1 ? `${(v * 1440).toFixed(0)}min` : String(v))).join(' < '));
  check('稳定性逐次不下降', stab.every((v, i) => i === 0 || v >= stab[i - 1]),
    stab.map((v) => v.toFixed(2)).join(' -> '));
  // #1 → #2 是平的:S 都是 2.3065。因为这两次都发生在同一天(相隔 10 分钟),
  // 走短期公式 inc = max(0.9945001, 1.0) = 1 —— 短期路径**不会**凭空造出增长。
  check('#1→#2 稳定性持平(同日 inc 被 max(1.0) 托底)', near(stab[0], stab[1], 1e-12),
    `${stab[0]} -> ${stab[1]}`);
  check('从第 2 次起稳定性逐次严格增长', stab.every((v, i) => i < 2 || v > stab[i - 1]),
    stab.slice(1).map((v) => v.toFixed(2)).join(' < '));
  check('10 次连续良好后稳定性 = 15504.1741948', near(st.stability, 15504.1741948, 1e-3),
    `S=${st.stability.toFixed(4)} 天`);
  check('掌握度达到「已掌握」', masteryOf(st.stability) === 4, `mastery=${masteryOf(st.stability)}`);
  check('掌握度百分比在合理区间', masteryPercent(st.stability, 10) > 50 && masteryPercent(st.stability, 10) <= 100,
    `${masteryPercent(st.stability, 10)}%`);
}

console.log('=== 8. schedule 是纯函数 ===');
{
  const st = newCardState(3, T0);
  const before = JSON.stringify(st);
  schedule(st, Grade.Good, T0 + DAY_MS);
  check('不修改入参', before === JSON.stringify(st));
}

console.log('=== 9. 掌握度门槛 ===');
{
  check('S=0 -> 未学', masteryOf(0) === 0);
  check('S=0.5 -> 生疏', masteryOf(0.5) === 1);
  check('S=3 -> 眼熟', masteryOf(3) === 2);
  check('S=20 -> 熟练', masteryOf(20) === 3);
  check('S=90 -> 已掌握', masteryOf(90) === 4);
}

console.log('=== 10. 遗忘循环与边界 ===');
{
  // 起点 reviewWord(5):S = 26.8427518878(与 reviewWord(99) 同值,cardId 不参与计算)
  // 每次 Again 都走 nextForgetStability,而上界 short = S/e^(w[17]*w[18]) = S*0.9517280 < S,
  // 所以 S 每一步都必然严格下降,一路降到 STABILITY_MIN = 0.001 附近:
  //   2.0166773 → 0.6837053 → 0.2488927 → 0.0968350 → 0.0400893 → 0.0175884 → 0.0081465 → 0.0039692
  let st = reviewWord(5);
  let t = T0 + 8 * DAY_MS;
  const LAPSE_ROUNDS = 8;
  let prevS = st.stability;
  let monotone = true;
  let strict = true;
  for (let i = 0; i < LAPSE_ROUNDS; i++) {
    const r = plan(st, Grade.Again, t);
    if (r.state.stability > prevS + 1e-9) {
      monotone = false;
      console.log(`    第 ${i + 1} 次忘记后 S 反而增大: ${prevS.toFixed(4)} -> ${r.state.stability.toFixed(4)}`);
    }
    if (r.state.stability >= prevS) {
      strict = false;
    }
    prevS = r.state.stability;
    st = r.state;
    t = t + Math.round(r.intervalDays * DAY_MS);
  }
  check('连续忘记后 S 仍 > 0', st.stability > 0, `S=${st.stability.toFixed(4)}`);
  // 稳定性下限是官方的 STABILITY_MIN = 0.001(老引擎是 0.25)
  check('连续忘记后 S 不低于下限 STABILITY_MIN = 0.001', st.stability >= 0.001 - 1e-12,
    `S=${st.stability.toFixed(4)}`);
  check('8 次忘记后 S = 0.0039692(手算末项)', near(st.stability, 0.0039692, 1e-7),
    `S=${st.stability.toFixed(7)}`);
  check('每次忘记 S 单调不增', monotone);
  check('每次忘记 S 严格下降(上界 short = S*0.9517280 < S)', strict);
  check(`连续忘记 ${LAPSE_ROUNDS} 次 -> lapses = ${LAPSE_ROUNDS}`, st.lapses === LAPSE_ROUNDS,
    `lapses=${st.lapses}`);
  check('不会卡在重学循环', st.phase === LearnPhase.Relearning, `phase=${st.phase}`);

  // 超长稳定性:Review 阶段 S = 30000,Easy 复习一次
  //   R = retrievability(30000, 30000) = 0.9
  //   S' = 30000*(1+e^1.8722*6*30000^-0.1666*(e^0.0796-1)*1.8729) = 30000*2.0866972 = 62600.9
  //      → 被 clampStability 夹到 MAX_STABILITY = 36500 → 间隔 = min(round(36500), 36500) = 36500
  // 注意必须先把它变成「非新卡」:reps = 0 时 isNew 分支会用 w[3] 覆盖掉这个 30000。
  const hi = newCardState(6, T0);
  hi.stability = 30000;
  hi.reps = 5;
  hi.phase = LearnPhase.Review;
  hi.lastReview = T0;
  const rh = plan(hi, Grade.Easy, T0 + 30000 * DAY_MS);
  check('超长稳定性被夹到 MAX_STABILITY = 36500 天', near(rh.state.stability, 36500, 1e-9),
    `S=${rh.state.stability}`);
  check('超长间隔不溢出', isFinite(rh.intervalDays) && rh.intervalDays <= 36500,
    `${rh.intervalDays.toFixed(0)} 天`);
  check('到期时间有限', isFinite(rh.state.due));
  check('超长间隔后阶段正确', rh.state.phase === LearnPhase.Review, `phase=${rh.state.phase}`);
}

console.log('=== 11. 回归:忘了之后重学通过不能立刻排到很远 ===');
{
  // 忘记:26.8427518878 → 2.0166773(长期项 2.0166773 < 上界 25.547,取长期项)
  // 10 分钟后「良好」:同日短期路径,inc = 1.0507204*2.0166773^-0.0658 = 1.0033076 → S = 2.0233848
  // relearningSteps=[10] 一步即通过,间隔 = round(2.0233848) = 2 天
  const st = reviewWord(21);
  const t = T0 + 8 * DAY_MS;
  const lapse = plan(st, Grade.Again, t);
  check('忘记时稳定性确实下降', lapse.state.stability < st.stability,
    `${st.stability.toFixed(1)} -> ${lapse.state.stability.toFixed(1)}`);
  check('忘记后稳定性 = 2.0166773', near(lapse.state.stability, 2.0166773, 1e-6),
    `S=${lapse.state.stability}`);
  const back = plan(lapse.state, Grade.Good, t + 60 * MIN_MS);
  console.log(`  重学通过: ${back.reason}`);
  check('重学通过后间隔 = round(2.0233848) = 2 天', back.intervalDays === 2,
    `${back.intervalDays.toFixed(2)} 天`);
  check('重学通过后 >= 1 天(不回到分钟级)', back.intervalDays >= 1, `${back.intervalDays.toFixed(2)} 天`);
}

console.log('=== 12. 学习阶段点「忘了」:留在 Learning,不是「重学」 ===');
{
  // 全新卡 + 忘了:isNew 分支 → S = w[0] = 0.212,D = w[4]-e^0+1 = 6.4133
  // 定间隔:Again → 留在 Learning(一个全新卡不叫「重学」),step = 0,间隔 = learningSteps[0] = 1 分钟
  // lapses 不加:第一次作答还没「学过」,谈不上遗忘。
  const r1 = plan(newCardState(31, T0), Grade.Again, T0);
  console.log(`  新卡 + 忘了: ${r1.reason}`);
  check('新卡点忘了仍有初始稳定性 w[0] = 0.212', near(r1.state.stability, 0.212, 1e-9),
    `S=${r1.state.stability.toFixed(2)}`);
  check('新卡点忘了留在 Learning(不是 Relearning)', r1.state.phase === LearnPhase.Learning,
    `phase=${r1.state.phase}`);
  check('新卡点忘了间隔 = learningSteps[0] = 1 分钟', near(r1.intervalDays * 1440, 1, 1e-9),
    `${(r1.intervalDays * 1440).toFixed(1)} 分钟`);
  check('新卡点忘了不计 lapse', r1.state.lapses === 0, `lapses=${r1.state.lapses}`);

  // 学习中(已认过一次)+ 忘了:同日走短期记忆公式
  //   inc = e^(w[17]*(0-2+w[18])) * S^-w[19] = e^(0.5425*(-1.9088)) * 2.3065^-0.0658
  //       = 0.3550403 * 0.9464936 = 0.3360433
  //   Again **没有** max(1.0) 托底(只有 Hard/Good/Easy 有),所以 S' = 2.3065*0.3360433 = 0.7750840
  //   —— 学习阶段点「忘了」稳定性确实会掉,这是 FSRS-6 的行为,不是 bug。
  const cur = plan(newCardState(32, T0), Grade.Good, T0);
  const sBefore = cur.state.stability;
  const r2 = plan(cur.state, Grade.Again, T0 + MIN_MS);
  console.log(`  学习中 + 忘了: ${r2.reason}`);
  check('学习阶段稳定性下降到 0.7750840', near(r2.state.stability, 0.7750840, 1e-6),
    `${sBefore.toFixed(2)} -> ${r2.state.stability.toFixed(2)}`);
  check('同日 Again 也计入 lapse(lapses 现在每次 Again 都 +1)', r2.state.lapses === 1,
    `lapses=${r2.state.lapses}`);
  check('学习阶段点忘了仍回到最短步进 1 分钟', near(r2.intervalDays * 1440, 1, 1e-9),
    `${(r2.intervalDays * 1440).toFixed(1)} 分钟`);
  check('学习阶段点忘了仍留在 Learning', r2.state.phase === LearnPhase.Learning,
    `phase=${r2.state.phase}`);

  const rev = reviewWord(33);
  const revBefore = rev.stability;
  const r3 = plan(rev, Grade.Again, T0 + 8 * DAY_MS);
  check('复习阶段点忘了才进 Relearning 并计 lapse', r3.state.lapses === 1 && r3.state.phase === LearnPhase.Relearning,
    `lapses=${r3.state.lapses} phase=${r3.state.phase}`);
  check('复习阶段点忘了稳定性下降', r3.state.stability < revBefore,
    `${revBefore.toFixed(2)} -> ${r3.state.stability.toFixed(2)}`);
}

console.log('=== 13. FSRS-6 专项:逐条钉住官方公式 ===');
{
  // ---- 13.1 四个初始稳定性:initialStability(grade) = clamp(w[grade], 0.001, 100) ----
  // 本项目 Grade 是 0-based,官方 rating = grade+1,官方 w[rating-1] 正对应这里的 w[grade]
  const initS = (g: Grade): number => plan(newCardState(1, T0), g, T0).state.stability;
  check('新卡 + 忘了 → S = w[0] = 0.212', near(initS(Grade.Again), 0.212, 1e-9), `${initS(Grade.Again)}`);
  check('新卡 + 困难 → S = w[1] = 1.2931', near(initS(Grade.Hard), 1.2931, 1e-9), `${initS(Grade.Hard)}`);
  check('新卡 + 良好 → S = w[2] = 2.3065', near(initS(Grade.Good), 2.3065, 1e-9), `${initS(Grade.Good)}`);
  check('新卡 + 简单 → S = w[3] = 8.2956', near(initS(Grade.Easy), 8.2956, 1e-9), `${initS(Grade.Easy)}`);
  check('四个初始稳定性就是 DEFAULT_W[0..3]',
    [0, 1, 2, 3].every((k) => near(initS(k as Grade), DEFAULT_W[k], 1e-12)));

  // ---- 13.2 初始难度:initialDifficulty(grade) = clamp(w[4] - e^(w[5]*grade) + 1, 1, 10) ----
  //   e^0      = 1            → 6.4133 - 1        + 1 = 6.4133
  //   e^0.8334 = 2.3011292944 → 6.4133 - 2.3011293+ 1 = 5.1121707056
  //   e^1.6668 = 5.2951960295 → 6.4133 - 5.2951960+ 1 = 2.1181039705
  //   e^2.5002 = 12.1849307032→ 6.4133 -12.1849307+ 1 = -4.7716307032 → 夹到 1
  const initD = (g: Grade): number => plan(newCardState(2, T0), g, T0).state.difficulty;
  check('初始难度(忘了) = 6.4133', near(initD(Grade.Again), 6.4133, 1e-9), `${initD(Grade.Again)}`);
  check('初始难度(困难) = 5.1121707056', near(initD(Grade.Hard), 5.1121707056, 1e-9), `${initD(Grade.Hard)}`);
  check('初始难度(良好) = 2.1181039705', near(initD(Grade.Good), 2.1181039705, 1e-9), `${initD(Grade.Good)}`);
  check('初始难度(简单) 原始 -4.7716307032 被夹到 1', initD(Grade.Easy) === 1, `${initD(Grade.Easy)}`);
  check('初始难度原始值就是 w[4]-e^(w[5]*grade)+1',
    near(DEFAULT_W[4] - Math.exp(DEFAULT_W[5] * 2) + 1, initD(Grade.Good), 1e-9)
    && near(DEFAULT_W[4] - Math.exp(DEFAULT_W[5] * 3) + 1, -4.7716307032, 1e-9),
    `raw(Easy)=${(DEFAULT_W[4] - Math.exp(DEFAULT_W[5] * 3) + 1).toFixed(7)}`);

  // ---- 13.3 intervalForRetention(S, 0.9) === S(FSRS 的定义性质) ----
  // interval = S/FACTOR*(0.9^(1/DECAY) - 1) = S/FACTOR*FACTOR = S
  for (const S of [1, 2.3065, 10, 90, 500, 3000]) {
    const ivl = intervalForRetention(S, 0.9);
    check(`intervalForRetention(${S}, 0.9) = ${S}`, near(ivl, S, 1e-6), `实际 ${ivl}`);
    check(`  ↳ 该间隔处的可提取性恰为 0.9`, near(retrievability(ivl, S), 0.9, 1e-9),
      `R=${retrievability(ivl, S).toFixed(9)}`);
  }
}

{
  // ---- 13.4 间隔单调性:同一状态、同一时刻,间隔(Again) <= (Hard) <= (Good) <= (Easy) ----
  // 用 reviewWord(99)(S = 26.8427518878,D = 2.1043313908,R = 0.9891879)横向对比四个评级。
  // 关掉扰动:扰动区间是 [round(d±delta)],开着它 Hard 的上界可能压到 Good 的下界之上。
  const w = reviewWord(99);
  const rAt = (g: Grade) => plan(w, g, T0 + 8 * DAY_MS);
  const iAgain = rAt(Grade.Again).intervalDays;
  const iHard = rAt(Grade.Hard).intervalDays;
  const iGood = rAt(Grade.Good).intervalDays;
  const iEasy = rAt(Grade.Easy).intervalDays;
  const sHard = rAt(Grade.Hard).state.stability;
  const sGood = rAt(Grade.Good).state.stability;
  const sEasy = rAt(Grade.Easy).state.stability;
  console.log(`  间隔 ${(iAgain * 1440).toFixed(0)}分钟 / ${iHard} / ${iGood} / ${iEasy} 天  |  ` +
    `稳定性 ${sHard.toFixed(4)} / ${sGood.toFixed(4)} / ${sEasy.toFixed(4)} 天`);
  check('间隔(忘了) <= 间隔(困难) <= 间隔(良好) <= 间隔(简单)',
    iAgain <= iHard && iHard <= iGood && iGood <= iEasy,
    `${(iAgain * 1440).toFixed(0)}min <= ${iHard} <= ${iGood} <= ${iEasy} 天`);
  check('稳定性(困难) < (良好) < (简单) —— 间隔的递增来自稳定性的递增',
    sHard < sGood && sGood < sEasy, `${sHard.toFixed(3)} < ${sGood.toFixed(3)} < ${sEasy.toFixed(3)}`);
  // 具体数值:31.5083326304 / 34.6006181044 / 41.3724595248 → round 后 32 / 35 / 41
  check('三档稳定性 = 31.5083326 / 34.6006181 / 41.3724595',
    near(sHard, 31.5083326, 1e-6) && near(sGood, 34.6006181, 1e-6) && near(sEasy, 41.3724595, 1e-6));
}

{
  // ---- 13.5 稳定性随复习增长;遗忘后下降且绝不超过遗忘前 ----
  const w = reviewWord(99);
  const s0 = w.stability;
  const good = plan(w, Grade.Good, T0 + 8 * DAY_MS).state.stability;
  const hard = plan(w, Grade.Hard, T0 + 8 * DAY_MS).state.stability;
  const easy = plan(w, Grade.Easy, T0 + 8 * DAY_MS).state.stability;
  check('回忆成功使稳定性增长(困难/良好/简单都 > S)', hard > s0 && good > s0 && easy > s0,
    `${s0.toFixed(3)} → ${hard.toFixed(3)} / ${good.toFixed(3)} / ${easy.toFixed(3)}`);
  const again = plan(w, Grade.Again, T0 + 8 * DAY_MS).state.stability;
  // S' = min(long, short),short = S/e^(w[17]*w[18]) = S/1.0507204 = S*0.9517280
  const cap = s0 * 0.9517280;
  check('遗忘使稳定性下降', again < s0, `${s0.toFixed(3)} → ${again.toFixed(3)}`);
  check('遗忘后稳定性不超过 S/e^(w[17]*w[18]) = S*0.9517280', again <= cap + 1e-9,
    `${again.toFixed(4)} <= ${cap.toFixed(4)}`);

  // 让 min() 的上界真正生效的极端状态:D = 10, S = 0.002,距上次 30 天
  //   R = (1+0.9803465*30/0.002)^-0.1542 = 14706.2^-0.1542 = 0.2277044
  //   long  = 1.4835 * 10^-0.0614 * ((1.002)^0.2629 - 1) * e^(0.7722956*1.6483)
  //         = 1.4835 * 0.8681605 * 0.0005254 * 3.7383338 = 0.0024168
  //   注意 long(0.0024168) > S(0.002):没有 min() 就会得出「忘了反而记得更牢」
  //   short = 0.002/1.0507204 = 0.0019034560  ← 取它
  const tiny: CardState = {
    cardId: 1, stability: 0.002, difficulty: 10, reps: 5, lapses: 0, streak: 0,
    lastReview: T0, due: T0 + 30 * DAY_MS, phase: LearnPhase.Review, step: 0, firstSeen: T0,
  };
  const rTiny = plan(tiny, Grade.Again, T0 + 30 * DAY_MS);
  check('极端状态下遗忘后 S = min(long, short) = 0.0019034560',
    near(rTiny.state.stability, 0.001903456, 1e-9), `S=${rTiny.state.stability}`);
  check('极端状态下遗忘后 S 仍小于遗忘前(上界生效)', rTiny.state.stability < 0.002,
    `${rTiny.state.stability.toFixed(9)} < 0.002`);
}

{
  // ---- 13.6 同日重复(floor(elapsedDays) < 1)走短期记忆路径 ----
  // 前置:新卡认一次「良好」→ S = 2.3065,Learning step = 1
  // 10 分钟后再答,elapsed = floor(10/1440) = 0 < 1 → 短期路径
  //   inc(grade) = e^(w[17]*(grade-2+w[18])) * S^-w[19],S^-w[19] = 2.3065^-0.0658 = 0.9464936
  //     忘了(0): e^(0.5425*(-1.9088)) = 0.3550403 → inc = 0.3360433(Again 无 max 托底)
  //     困难(1): e^(0.5425*(-0.9088)) = 0.6108330 → inc = 0.5780961 → max(...,1) = 1
  //     良好(2): e^(0.5425*0.0912)   = 1.0507204 → inc = 0.9945001 → max(...,1) = 1
  //     简单(3): e^(0.5425*1.0912)   = 1.8079292 → inc = 1.7108407
  const base = plan(newCardState(41, T0), Grade.Good, T0);
  const sameDay = (g: Grade) => plan(base.state, g, T0 + 10 * MIN_MS);
  const rAgain = sameDay(Grade.Again);
  const rHard = sameDay(Grade.Hard);
  const rGood = sameDay(Grade.Good);
  const rEasy = sameDay(Grade.Easy);
  check('短期路径:elapsedDays < 1', rGood.elapsedDays < 1, `elapsed=${rGood.elapsedDays}`);
  check('同日「良好」S 不下降(inc 被 max(1.0) 托底,恰好等于 S)', near(rGood.state.stability, 2.3065, 1e-9),
    `S=${rGood.state.stability}`);
  check('同日「困难」S 也不下降(w[15] 的惩罚不参与短期公式)', near(rHard.state.stability, 2.3065, 1e-9),
    `S=${rHard.state.stability}`);
  check('同日「简单」S 增长到 3.9460541', near(rEasy.state.stability, 3.9460541, 1e-6),
    `S=${rEasy.state.stability}`);
  check('同日「忘了」S 下降到 0.7750840', near(rAgain.state.stability, 0.7750840, 1e-6),
    `S=${rAgain.state.stability}`);
  check('同日「忘了」稳定性确实低于原值', rAgain.state.stability < base.state.stability,
    `${base.state.stability} → ${rAgain.state.stability.toFixed(4)}`);
}

{
  // ---- 13.7 maximumInterval 生效 ----
  // 同一张卡(Good 后 S = 34.6006181),默认参数下间隔 = round(34.6006) = 35 天;
  // 把 maximumInterval 压到 5 / 30,间隔必须被夹住。
  const w = reviewWord(5);
  const at = () => plan(w, Grade.Good, T0 + 8 * DAY_MS).intervalDays;
  check('默认 maximumInterval=36500 时间隔 = 35 天', at() === 35, `${at()} 天`);
  withParams((p) => { p.maximumInterval = 5; }, () => {
    check('maximumInterval=5 → 间隔夹到 5 天', at() === 5, `${at()} 天`);
  });
  withParams((p) => { p.maximumInterval = 30; }, () => {
    check('maximumInterval=30 → 间隔夹到 30 天', at() === 30, `${at()} 天`);
  });
  check('参数已恢复:又是 35 天', at() === 35, `${at()} 天`);
}

{
  // ---- 13.8 desiredRetention 生效:目标保持率越高,间隔越短 ----
  // S = 34.6006181,interval = round(S/FACTOR*(ret^(1/DECAY) - 1))
  //   ret=0.95: 0.95^-6.4850843 = 1.3946070 → round(35.2944730*0.3946070) = round(13.9309461) = 14
  //   ret=0.90: 0.90^-6.4850843 = 1.9803465 → round(35.2944730*0.9803465) = round(34.6006181) = 35
  //   ret=0.80: 0.80^-6.4850843 = 4.2510852 → round(35.2944730*3.2510852) = round(114.7459667) = 115
  const w = reviewWord(5);
  const at = (ret: number): number => {
    let v = 0;
    withParams((p) => { p.desiredRetention = ret; }, () => { v = plan(w, Grade.Good, T0 + 8 * DAY_MS).intervalDays; });
    return v;
  };
  const d95 = at(0.95);
  const d90 = at(0.90);
  const d80 = at(0.80);
  console.log(`  同一卡同一评级: 95% → ${d95} 天 / 90% → ${d90} 天 / 80% → ${d80} 天`);
  check('调高保持率后间隔变短', d95 < d90 && d90 < d80, `${d95} < ${d90} < ${d80}`);
  check('三个保持率的间隔 = 14 / 35 / 115 天', d95 === 14 && d90 === 35 && d80 === 115,
    `${d95} / ${d90} / ${d80}`);
}

{
  // ---- 13.9 自定义步进生效 ----
  // learningSteps = []:官方在「步进表为空」时直接毕业 → 一次「良好」就进 Review
  //   S = 2.3065 → 间隔 = round(2.3065) = 2 天
  withParams((p) => { p.learningSteps = []; }, () => {
    const r = plan(newCardState(51, T0), Grade.Good, T0);
    check('learningSteps=[] → 一次「良好」即毕业进 Review', r.state.phase === LearnPhase.Review,
      `phase=${r.state.phase}`);
    check('毕业间隔 = round(2.3065) = 2 天', r.intervalDays === 2, `${r.intervalDays} 天`);
  });
  // learningSteps = [3,30]:第一步「困难」按官方特例取前两步均值 (3+30)/2 = 16.5 分钟
  withParams((p) => { p.learningSteps = [3, 30]; }, () => {
    const h = plan(newCardState(52, T0), Grade.Hard, T0);
    check('learningSteps=[3,30] 第一步「困难」= (3+30)/2 = 16.5 分钟',
      near(h.intervalDays * 1440, 16.5, 1e-9), `${(h.intervalDays * 1440).toFixed(1)} 分钟`);
    const g1 = plan(newCardState(53, T0), Grade.Good, T0);
    check('learningSteps=[3,30] 「良好」→ learningSteps[1] = 30 分钟',
      near(g1.intervalDays * 1440, 30, 1e-9), `${(g1.intervalDays * 1440).toFixed(0)} 分钟`);
    const g2 = plan(g1.state, Grade.Good, T0 + 30 * MIN_MS);
    check('learningSteps=[3,30] 两次「良好」后毕业', g2.state.phase === LearnPhase.Review,
      `phase=${g2.state.phase}`);
  });
  // relearningSteps = []:Review 阶段 Again 不再进 Relearning,直接按稳定性排期
  withParams((p) => { p.relearningSteps = []; }, () => {
    const r = plan(reviewWord(54), Grade.Again, T0 + 8 * DAY_MS);
    check('relearningSteps=[] → 忘了不进 Relearning', r.state.phase === LearnPhase.Review,
      `phase=${r.state.phase}`);
    check('relearningSteps=[] → 直接排 round(2.0166773) = 2 天', r.intervalDays === 2,
      `${r.intervalDays} 天`);
  });
  // 默认参数恢复后,Again 仍然进 Relearning
  check('参数已恢复:默认 Again 进 Relearning',
    plan(reviewWord(55), Grade.Again, T0 + 8 * DAY_MS).state.phase === LearnPhase.Relearning);
}

{
  // ---- 13.10 sanitizeW:越界夹回、非有限回落默认值 ----
  // 合法区间取自官方 py-fsrs 的 LOWER_BOUNDS_PARAMETERS / UPPER_BOUNDS_PARAMETERS
  const LOWER = [0.001, 0.001, 0.001, 0.001, 1.0, 0.001, 0.001, 0.001, 0.0, 0.0,
    0.001, 0.001, 0.001, 0.001, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.1];
  const UPPER = [100, 100, 100, 100, 10, 4, 4, 0.75, 4.5, 0.8,
    3.5, 5, 0.25, 0.9, 4, 1, 6, 2, 2, 0.8, 0.8];
  const same = sanitizeW(DEFAULT_W);
  check('默认权重本身合法,原样返回',
    same.length === W_COUNT && same.every((v, i) => v === DEFAULT_W[i]));

  const raw = DEFAULT_W.slice();
  raw[0] = 999;         // 上界 100
  raw[4] = 0.5;         // 下界 1.0
  raw[8] = -3;          // 下界 0.0
  raw[20] = 5;          // 上界 0.8
  raw[5] = NaN;         // 非有限 → 回落默认值
  raw[16] = Infinity;   // 非有限 → 回落默认值
  const s = sanitizeW(raw);
  check('上界夹取: w[0] 999 → 100', s[0] === 100, `${s[0]}`);
  check('下界夹取: w[4] 0.5 → 1', s[4] === 1, `${s[4]}`);
  check('下界为 0 的项: w[8] -3 → 0', s[8] === 0, `${s[8]}`);
  check('上界 0.8 的项: w[20] 5 → 0.8', s[20] === 0.8, `${s[20]}`);
  check('NaN 回落默认值: w[5] → 0.8334', s[5] === DEFAULT_W[5], `${s[5]}`);
  check('Infinity 回落默认值: w[16] → 1.8729', s[16] === DEFAULT_W[16], `${s[16]}`);
  check('长度恒为 W_COUNT = 21', s.length === W_COUNT, `${s.length}`);
  check('每一项都落在官方区间内', s.every((v, i) => v >= LOWER[i] && v <= UPPER[i]));
  const short = sanitizeW([0.5]);
  check('数组短了用默认值补全', short.length === W_COUNT && short[0] === 0.5 && short[1] === DEFAULT_W[1],
    `${short.length} 项`);
}

{
  // ---- 13.11 扰动可关闭:enableFuzzing=false 时结果完全可复现 ----
  // 造一个间隔约 100 天的卡:S = 27,D = 2.1043313908,距上次正好 27 天 → R = R(27,27) = 0.9
  //   S' = 27*(1+e^1.8722*8.8956686*27^-0.1666*(e^0.0796-1)) = 101.7267207651 → 间隔 = round = 102 天
  const longWord = (): CardState => ({
    cardId: 1, stability: 27, difficulty: 2.1043313908, reps: 10, lapses: 0, streak: 5,
    lastReview: T0, due: T0 + 27 * DAY_MS, phase: LearnPhase.Review, step: 0, firstSeen: T0,
  });
  const at = () => plan(longWord(), Grade.Good, T0 + 27 * DAY_MS);
  check('基准:无扰动时间隔 = round(101.7267208) = 102 天', at().intervalDays === 102,
    `${at().intervalDays} 天`);
  check('基准:S = 101.7267207651', near(at().state.stability, 101.7267207651, 1e-6),
    `S=${at().state.stability}`);

  withParams((p) => { p.enableFuzzing = false; }, () => {
    // 不传第四参数,走 PARAMS.enableFuzzing
    const first = schedule(longWord(), Grade.Good, T0 + 27 * DAY_MS).intervalDays;
    let identical = true;
    for (let i = 0; i < 20; i++) {
      if (schedule(longWord(), Grade.Good, T0 + 27 * DAY_MS).intervalDays !== first) {
        identical = false;
      }
    }
    check('enableFuzzing=false:同一输入连续算 20 次结果完全一致', identical && first === 102,
      `${first} 天`);
  });

  // 随机源被换掉后,开着扰动就必须真的产生波动,并且只在该动的间隔上动
  setRandomSource(makeRng(20240917));
  let randUsed = false;
  setRandomSource(() => { randUsed = true; return 0.5; });
  const notFuzzed = schedule(plan(newCardState(56, T0), Grade.Good, T0).state, Grade.Good, T0 + 10 * MIN_MS);
  check('间隔 2 天(< 2.5)时完全不消耗随机数', !randUsed && notFuzzed.intervalDays === 2,
    `interval=${notFuzzed.intervalDays} randUsed=${randUsed}`);
  randUsed = false;
  const fuzzed = schedule(longWord(), Grade.Good, T0 + 27 * DAY_MS);
  check('间隔 102 天时会消耗随机数(扰动已生效)', randUsed && fuzzed.intervalDays !== 0,
    `interval=${fuzzed.intervalDays}`);

  // ---- 13.12 扰动区间合法 ----
  // delta = 1 + 0.15*max(min(d,7)-2.5,0) + 0.10*max(min(d,20)-7,0) + 0.05*max(d-20,0)
  // d = 102: delta = 1 + 0.15*4.5 + 0.10*13 + 0.05*82 = 1 + 0.675 + 1.3 + 4.1 = 7.075
  // minIvl = max(2, round(102-7.075)) = max(2, round(94.925)) = 95
  // maxIvl = min(round(102+7.075), 36500) = round(109.075) = 109
  //
  // ⚠ 注意实现与「扰动区间」这个说法的**一天偏差**:
  //     均匀取值的宽度是 (maxIvl - minIvl + 1),所以 fuzzed ∈ [minIvl, maxIvl+1),
  //     再 Math.round 就会在抽到 [maxIvl+0.5, maxIvl+1) 时进位成 **maxIvl + 1**
  //     (概率 0.5/(maxIvl-minIvl+1) = 1/30),最后只被 maximumInterval 兜一次。
  //     这不是移植 bug:Srs.ets 的这两行与官方 py-fsrs 的
  //     `(random() * (max_ivl - min_ivl + 1)) + min_ivl` + `min(round(...), maximum_interval)`
  //     逐字一致,官方同样会偶尔给出 max_ivl + 1。所以这里断言的是实现的真实上界
  //     [minIvl, min(maxIvl+1, maximumInterval)],并在下面用 maximumInterval 已生效的场景
  //     验证「硬上限一定兜得住」。
  const d = 102;
  const delta = 1 + 0.15 * (Math.min(d, 7) - 2.5) + 0.10 * (Math.min(d, 20) - 7) + 0.05 * (d - 20);
  const lo = Math.max(2, Math.round(d - delta));
  const hi = Math.min(Math.round(d + delta), 36500);
  const hardHi = Math.min(hi + 1, 36500);
  setRandomSource(makeRng(20240917));
  const seen = new Set<number>();
  let inRange = true;
  let allInt = true;
  let minSeen = Infinity;
  let maxSeen = -Infinity;
  for (let i = 0; i < 500; i++) {
    const v = schedule(longWord(), Grade.Good, T0 + 27 * DAY_MS).intervalDays;
    seen.add(v);
    if (v < lo || v > hardHi) {
      inRange = false;
    }
    if (!Number.isInteger(v)) {
      allInt = false;
    }
    minSeen = Math.min(minSeen, v);
    maxSeen = Math.max(maxSeen, v);
  }
  console.log(`  500 次扰动: 区间 [${lo}, ${hi}](真实上界 ${hardHi}),实际覆盖 [${minSeen}, ${maxSeen}],${seen.size} 种取值`);
  check(`500 次扰动结果都落在 [${lo}, ${hardHi}]`, inRange, `实际 [${minSeen}, ${maxSeen}]`);
  check('扰动结果都是整数天', allInt);
  check('扰动确实在变(不是恒等映射)', seen.size >= 10, `${seen.size} 种`);
  check('除非抽到上界外的进位,否则不越过 round(d+delta)', minSeen >= lo && maxSeen <= hardHi,
    `max=${maxSeen}`);
  check('结果永不超过 base±1 的邻域(没有失控)', maxSeen <= hi + 1 && minSeen >= lo - 1);

  // maximumInterval 已经小于扰动区间时,最后那次 min() 必须把「+1 进位」也兜住。
  // 注意 maximumInterval 会先夹住**基准间隔**:S = 101.7267208 → nextInterval = min(round(101.7267), 100) = 100,
  // 所以这里 d = 100(不是 102):
  //   delta  = 1 + 0.15*4.5 + 0.10*13 + 0.05*80 = 6.975
  //   minIvl = max(2, round(100-6.975)) = max(2, 93) = 93
  //   maxIvl = min(round(100+6.975), 100) = min(107, 100) = 100
  //   均匀取值 ∈ [93, 101) → round → 93..101 → min(..., 100) → 严格落在 [93, 100]
  withParams((p) => { p.maximumInterval = 100; }, () => {
    const cappedBase = plan(longWord(), Grade.Good, T0 + 27 * DAY_MS).intervalDays;
    const dCap = 100;
    const deltaCap = 1 + 0.15 * (Math.min(dCap, 7) - 2.5) + 0.10 * (Math.min(dCap, 20) - 7)
      + 0.05 * (dCap - 20);
    const loCap = Math.max(2, Math.round(dCap - deltaCap));
    const hiCap = Math.min(Math.round(dCap + deltaCap), 100);
    let capped = true;
    let capMax = 0;
    let capMin = Infinity;
    for (let i = 0; i < 500; i++) {
      const v = schedule(longWord(), Grade.Good, T0 + 27 * DAY_MS).intervalDays;
      capMax = Math.max(capMax, v);
      capMin = Math.min(capMin, v);
      if (v < loCap || v > hiCap) {
        capped = false;
      }
    }
    check('基准间隔先被夹到 100', cappedBase === 100, `${cappedBase} 天`);
    check(`maximumInterval=100 时扰动全落在 [${loCap}, ${hiCap}](进位也被兜住)`, capped,
      `实际 [${capMin}, ${capMax}]`);
  });
  setRandomSource(makeRng(12345));
}

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
process.exit(fail === 0 ? 0 : 1);
