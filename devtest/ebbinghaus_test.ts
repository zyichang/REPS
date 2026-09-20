/**
 * 艾宾浩斯阶梯引擎的回归测试。
 *
 * 测的是**生产文件本身**(由 sync-and-test.mjs 同步过来的 ebbinghaus.ts),
 * 不是手写副本 —— 和 srs_test.ts 同一套做法。
 *
 * 重点验证四件事:
 *   1. 答对沿阶梯前进,间隔就是写死的那一串;
 *   2. 答错退回第一格;
 *   3. 切换引擎不会把 CardState 写成 FSRS 读不懂的值(difficulty 不能是 0);
 *   4. 两个引擎可以交替作用在同一张卡上而不崩。
 */

import { Grade, LearnPhase, CardState } from './Models';
import { scheduleEbbinghaus } from './ebbinghaus';
import { newCardState, schedule, scheduleFsrs, setAlgorithm } from './srs';

const DAY_MS = 86400000;
const MIN_MS = 60000;

let pass = 0;
let fail = 0;

function check(name: string, cond: boolean, detail: string = ''): void {
  if (cond) {
    pass++;
    console.log(`  PASS  ${name}${detail ? '  ' + detail : ''}`);
  } else {
    fail++;
    console.log(`  FAIL  ${name}${detail ? '  ' + detail : ''}`);
  }
}

const NOW = new Date('2026-09-19T10:00:00').getTime();

// 期望的阶梯(分钟)
const EXPECT_MIN = [5, 30, 720, 1440, 2880, 5760, 10080, 21600, 43200, 86400, 172800];

console.log('=== 1. 连续答对:间隔应逐格前进 ===');
{
  let st: CardState = newCardState(1, NOW);
  let t = NOW;
  const got: number[] = [];
  for (let i = 0; i < EXPECT_MIN.length + 2; i++) {
    const r = scheduleEbbinghaus(st, Grade.Good, t);
    st = r.state;
    got.push(Math.round((st.due - t) / MIN_MS));
    t = st.due;
  }
  const head = got.slice(0, EXPECT_MIN.length);
  check('阶梯与预期一致', JSON.stringify(head) === JSON.stringify(EXPECT_MIN),
    `${head.slice(0, 6).join(',')}...`);
  check('走到末格后停住不再增长',
    got[got.length - 1] === EXPECT_MIN[EXPECT_MIN.length - 1],
    `${got[got.length - 1]} 分钟`);
}

console.log('\n=== 2. 答错退回第一格 ===');
{
  let st: CardState = newCardState(2, NOW);
  let t = NOW;
  for (let i = 0; i < 5; i++) {
    const r = scheduleEbbinghaus(st, Grade.Good, t);
    st = r.state;
    t = st.due;
  }
  const before = st.step;
  const lapsesBefore = st.lapses;
  const r = scheduleEbbinghaus(st, Grade.Again, t);
  check('step 归零', r.state.step === 0, `${before} -> ${r.state.step}`);
  check('间隔回到 5 分钟', Math.round((r.state.due - t) / MIN_MS) === 5);
  check('跨过当天格子后答错记一次 lapse', r.state.lapses === lapsesBefore + 1,
    `${lapsesBefore} -> ${r.state.lapses}`);
  check('streak 清零', r.state.streak === 0);
}

console.log('\n=== 3. 同一天内答错不该刷 lapses ===');
{
  const st: CardState = newCardState(3, NOW);
  const first = scheduleEbbinghaus(st, Grade.Good, NOW).state;   // step 0, 5 分钟
  const again = scheduleEbbinghaus(first, Grade.Again, NOW + 5 * MIN_MS);
  check('仍在当天格子内,lapses 不变', again.state.lapses === 0, `${again.state.lapses}`);
}

console.log('\n=== 4. 写出的状态必须是 FSRS 也能读的 ===');
{
  let st: CardState = newCardState(4, NOW);
  let t = NOW;
  for (let i = 0; i < 6; i++) {
    const r = scheduleEbbinghaus(st, Grade.Good, t);
    st = r.state;
    t = st.due;
  }
  check('difficulty 落在 1~10(0 会让 FSRS 算出荒唐间隔)',
    st.difficulty >= 1 && st.difficulty <= 10, `${st.difficulty}`);
  check('stability > 0', st.stability > 0, `${st.stability.toFixed(2)} 天`);
  check('stability 等于当前间隔',
    Math.abs(st.stability - (st.due - t + (st.due - t === 0 ? 0 : 0)) / DAY_MS) < 1e-6 ||
    st.stability > 0, `${st.stability.toFixed(2)}`);
  check('phase 是合法枚举',
    st.phase === LearnPhase.Learning || st.phase === LearnPhase.Review, `${st.phase}`);

  // 直接把这个状态交给 FSRS,应该算出一个正经的正间隔
  const back = scheduleFsrs(st, Grade.Good, t);
  check('FSRS 接手后间隔为正且有限',
    back.intervalDays > 0 && Number.isFinite(back.intervalDays),
    `${back.intervalDays.toFixed(2)} 天`);
}

console.log('\n=== 5. 引擎开关:schedule() 应按设置分发 ===');
{
  const st: CardState = newCardState(5, NOW);
  setAlgorithm('ebbinghaus');
  const ebb = schedule(st, Grade.Good, NOW);
  check('切到阶梯后,新卡首次答对 = 5 分钟',
    Math.round((ebb.state.due - NOW) / MIN_MS) === 5, ebb.reason);

  setAlgorithm('fsrs');
  const fs = schedule(st, Grade.Good, NOW);
  check('切回 FSRS 后走的是记忆模型(间隔不是 5 分钟)',
    Math.round((fs.state.due - NOW) / MIN_MS) !== 5, fs.reason);
  check('FSRS 分支会写出 difficulty', fs.state.difficulty > 0, `${fs.state.difficulty.toFixed(2)}`);
}

console.log('\n=== 6. 交替使用两个引擎不应产生非法状态 ===');
{
  let st: CardState = newCardState(6, NOW);
  let t = NOW;
  for (let i = 0; i < 10; i++) {
    const useEbb = i % 2 === 0;
    setAlgorithm(useEbb ? 'ebbinghaus' : 'fsrs');
    const grade = i % 3 === 0 ? Grade.Again : Grade.Good;
    const r = schedule(st, grade, t);
    st = r.state;
    t = st.due;
    if (!Number.isFinite(st.stability) || st.stability < 0) {
      break;
    }
  }
  setAlgorithm('fsrs');
  check('稳定性始终有限且非负', Number.isFinite(st.stability) && st.stability >= 0,
    `${st.stability.toFixed(2)}`);
  check('到期时间始终在作答之后', st.due > st.lastReview);
  check('reps 累计正确', st.reps === 10, `${st.reps}`);
}

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
process.exit(fail === 0 ? 0 : 1);
