/**
 * 艾宾浩斯固定阶梯排期(FSRS 之外的另一个引擎)。
 *
 * 和 FSRS-6 的根本差别:**它不建记忆模型**。
 * FSRS 为每张卡维护稳定性 S 和难度 D,由目标保持率反解间隔;
 * 艾宾浩斯这一版只有一条写死的间隔阶梯,答对往前走一格,答错退回第一格。
 * 好处是完全可预测、可解释;代价是它不会因为「这张卡你总记不住」而自动缩短间隔。
 *
 * 为什么仍然写满 CardState 的所有字段:两个引擎共用同一张 learning 表,
 * 用户随时可能切回 FSRS。如果这里只写 due 和 step,切回去之后 FSRS 会读到
 * stability=0 / difficulty=0,把卡当成全新的,排期直接崩掉。
 * 所以这里把 stability 填成「当前间隔天数」—— 这个值对两边都讲得通:
 * 统计页的「已掌握 = 稳定性 ≥ 60 天」在两种算法下都是「已经走到 60 天档」。
 */

import { Grade, LearnPhase, CardState } from '../model/Models';
// 只从 Srs 取 SrsResult 这个**接口** —— 接口在编译期被擦掉,
// 所以 Srs -> Ebbinghaus 的依赖是单向的,不会形成运行时循环引用。
// 毫秒常量在本文件自己定义,正是为了不引入值依赖。
import { SrsResult } from './Srs';

const MIN_MS: number = 60000;
const DAY_MS: number = 86400000;

/**
 * 间隔阶梯(分钟)。前三格在一天以内,用来当天内强化;之后按天推进。
 * 5 分钟 → 30 分钟 → 12 小时 → 1 → 2 → 4 → 7 → 15 → 30 → 60 → 120 天
 */
const LADDER_MIN: number[] = [
  5, 30, 12 * 60,
  1 * 1440, 2 * 1440, 4 * 1440, 7 * 1440, 15 * 1440, 30 * 1440, 60 * 1440, 120 * 1440
];

/** 一天以内的格子算「学习中」,一天及以上算「长期复习」 */
const FIRST_DAY_STEP = 3;

/** 阶梯长度,供设置页说明用 */
export const EBB_STEPS: number = LADDER_MIN.length;

/** 第 i 格的间隔(天) */
function ladderDays(i: number): number {
  const idx = i < 0 ? 0 : (i >= LADDER_MIN.length ? LADDER_MIN.length - 1 : i);
  return LADDER_MIN[idx] * MIN_MS / DAY_MS;
}

function describe(days: number): string {
  if (days < 1) {
    const mins = Math.round(days * 1440);
    return mins >= 60 ? `${Math.round(mins / 60)} 小时` : `${mins} 分钟`;
  }
  return `${Math.round(days)} 天`;
}

/**
 * 按固定阶梯排期。
 *
 * 评级语义:
 *   陌生(Again) —— 退回第 0 格,并记一次 lapse
 *   认识(Good)  —— 前进一格
 *   已习得(Easy) —— 直接跳到最后一格(这张卡随后会被永久退出,排期只是留个记录)
 */
export function scheduleEbbinghaus(prev: CardState, grade: Grade, now: number): SrsResult {
  const s: CardState = {
    cardId: prev.cardId,
    stability: prev.stability,
    difficulty: prev.difficulty,
    reps: prev.reps,
    lapses: prev.lapses,
    streak: prev.streak,
    lastReview: prev.lastReview,
    due: prev.due,
    phase: prev.phase,
    step: prev.step,
    firstSeen: prev.firstSeen > 0 ? prev.firstSeen : now
  };

  const stabilityBefore = s.stability;
  const elapsedDaysRaw = s.lastReview > 0 ? Math.max(0, (now - s.lastReview) / DAY_MS) : 0;
  const isFirst = prev.reps <= 0;
  s.reps = s.reps + 1;

  let step = prev.step;
  let reason = '';

  if (grade === Grade.Again) {
    // 答错就回到第一格。只有跨过「当天以内」的格子才算真正遗忘,
    // 否则同一天内反复答错会把 lapses 刷得很高,薄弱卡榜就没意义了。
    if (!isFirst && prev.step >= FIRST_DAY_STEP) {
      s.lapses = s.lapses + 1;
    }
    step = 0;
    s.streak = 0;
    reason = `答错,退回阶梯第 1 格(${describe(ladderDays(0))}后再认)`;
  } else if (grade === Grade.Easy) {
    step = LADDER_MIN.length - 1;
    s.streak = s.streak + 1;
    reason = '已习得,直接跳到阶梯末格';
  } else {
    step = isFirst ? 0 : Math.min(prev.step + 1, LADDER_MIN.length - 1);
    s.streak = s.streak + 1;
    const pos = step + 1;
    reason = `答对,阶梯第 ${pos}/${LADDER_MIN.length} 格(${describe(ladderDays(step))}后再认)`;
  }

  const intervalDays = ladderDays(step);
  s.step = step;
  // 阶梯没有难度概念。填一个中位数 5 而不是 0:
  // 0 在 FSRS 里是非法难度,切回 FSRS 时会算出荒唐的间隔。
  s.difficulty = 5;
  // stability 用「当前间隔」表达,让掌握度分档在两种算法下口径一致
  s.stability = intervalDays;
  s.phase = step >= FIRST_DAY_STEP ? LearnPhase.Review : LearnPhase.Learning;
  s.lastReview = now;
  s.due = now + Math.round(intervalDays * DAY_MS);

  const out: SrsResult = {
    state: s,
    intervalDays: intervalDays,
    retrievability: 0,
    elapsedDays: elapsedDaysRaw,
    reason: reason,
    stabilityBefore: stabilityBefore
  };
  return out;
}
