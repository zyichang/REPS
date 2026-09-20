/**
 * Task 2 的 demo:把 FSRS-6 排出来的真实间隔序列打印出来。
 *
 * 这不是测试(断言在 srs_test.ts 里,150 条),而是让人肉眼确认
 * 「一张新卡连续答对,间隔是怎么长起来的」。
 *
 * 跑法:tsx devtest/interval_demo.ts
 * 需要先跑过 sync-and-test.mjs(它负责把生产 .ets 同步成 .ts)。
 */

import { CardState, Grade, PHASE_LABEL } from './Models';
import { formatInterval, newCardState, schedule, setAlgorithm, setRandomSource } from './srs';

// 关掉随机扰动,否则每次跑出来的天数都不一样,看不出规律
setRandomSource(() => 0.5);

const T0 = Date.UTC(2026, 0, 1, 9, 0, 0); // 2026-01-01 09:00 UTC

function ladder(grade: Grade, label: string, steps: number): void {
  console.log(`\n=== 连续「${label}」${steps} 次 ===`);
  console.log('  次数   间隔        累计时刻              阶段      S(天)   D');

  let state: CardState = newCardState(1, T0);
  let now = T0;

  for (let i = 1; i <= steps; i++) {
    const r = schedule(state, grade, now, false);
    state = r.state;
    const waited = state.due - now;
    now = state.due; // 假设用户恰好在到期时刻作答

    const when = new Date(state.due).toISOString().slice(0, 16).replace('T', ' ');
    console.log(
      `  ${String(i).padStart(3)}   ` +
      `${formatInterval(r.intervalDays).padEnd(10)}  ` +
      `${when}     ` +
      `${PHASE_LABEL[state.phase].padEnd(6)}  ` +
      `${state.stability.toFixed(2).padStart(7)}  ` +
      `${state.difficulty.toFixed(2)}   ` +
      `(等了 ${(waited / 60000).toFixed(0)} 分钟)`
    );
  }
}

console.log('FSRS-6 —— 一张新卡在「恰好到期就复习」的理想节奏下的真实排期');
setAlgorithm('fsrs');
ladder(Grade.Good, '良好', 10);
ladder(Grade.Easy, '简单', 8);

console.log('\n\n对照:固定阶梯引擎(完全可预测,不因卡而异)');
setAlgorithm('ebbinghaus');
ladder(Grade.Good, '良好', 11);
