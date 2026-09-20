/**
 * 调度引擎:FSRS-6(Free Spaced Repetition Scheduler 第 6 代)的完整移植。
 *
 * 为什么从「FSRS 风格」换成真正的 FSRS-6:
 *   之前那版是自己按 FSRS 的思路凑的参数(固定 S_INC / D_DELTA 表、固定 90% 保持率),
 *   虽然单调性有保证,但数值没有经过任何真实复习数据的拟合,
 *   属于「长得像 FSRS,但不是 FSRS」。这一版逐行对齐官方实现
 *   (open-spaced-repetition/py-fsrs 的 scheduler.py),21 个权重全部用官方默认值,
 *   并且允许用户在设置里调。
 *
 * 四个核心公式(与官方实现一一对应,下标为 0-based 的 21 个权重 w[0..20]):
 *
 *   1. 遗忘曲线
 *        DECAY  = -w[20]
 *        FACTOR = 0.9^(1/DECAY) - 1
 *        R(t,S) = (1 + FACTOR * t / S) ^ DECAY
 *      这是幂律而非指数 —— 实测中幂律对长期记忆的拟合明显更好。
 *
 *   2. 稳定性增长(回忆成功)
 *        S' = S * (1 + e^w[8] * (11-D) * S^(-w[9]) * (e^((1-R)*w[10]) - 1)
 *                     * hardPenalty * easyBonus)
 *      三个直觉都在里面:越难(D 大)涨得越少、越牢(S 大)涨得越少、
 *      当时越想不起来(R 小)涨得越多。
 *
 *   3. 稳定性衰减(遗忘)
 *        S' = min( w[11] * D^(-w[12]) * ((S+1)^w[13] - 1) * e^((1-R)*w[14]),
 *                  S / e^(w[17]*w[18]) )
 *      取 min 是 FSRS-6 相对 v5 的关键改动之一:遗忘后的稳定性不允许超过某个上界,
 *      否则「忘了反而记得更牢」。
 *
 *   4. 同日重复(短期记忆)
 *        S' = S * max(1, e^(w[17]*(rating-3+w[18])) * S^(-w[19]))
 *      这是 v6 新增的 w[17..19],专门处理「同一天内再答一次」。
 *      本 App 一次会话里会把新卡连认好几次,走的正是这条路径 ——
 *      没有它,同一天内的重复作答会被当成「隔了 0 天复习」而算不出合理的增长。
 *
 * 难度 D 的更新采用「线性阻尼 + 均值回归」(w[6] 控制前者,w[7] 控制后者),
 * 均值回归保证难度不会因为一次极端评级就跑偏。
 */

import { Grade, LearnPhase, Mastery, CardState } from '../model/Models';
import { scheduleEbbinghaus } from './Ebbinghaus';

export const DAY_MS: number = 86400000;
export const MIN_MS: number = 60000;

// ---------------------------------------------------------------- 官方常量

/** FSRS-6 官方默认权重(21 个),取自 py-fsrs DEFAULT_PARAMETERS */
export const DEFAULT_W: number[] = [
  0.212, 1.2931, 2.3065, 8.2956, 6.4133,
  0.8334, 3.0194, 0.001, 1.8722, 0.1666,
  0.796, 1.4835, 0.0614, 0.2629, 1.6483,
  0.6014, 1.8729, 0.5425, 0.0912, 0.0658,
  0.1542
];

/** 参数个数。UI 上要按这个数量渲染 */
export const W_COUNT: number = 21;

/** 合法下界(与 py-fsrs LOWER_BOUNDS_PARAMETERS 一致) */
const W_LOWER: number[] = [
  0.001, 0.001, 0.001, 0.001, 1.0,
  0.001, 0.001, 0.001, 0.0, 0.0,
  0.001, 0.001, 0.001, 0.001, 0.0,
  0.0, 1.0, 0.0, 0.0, 0.0,
  0.1
];

/** 合法上界(与 py-fsrs UPPER_BOUNDS_PARAMETERS 一致) */
const W_UPPER: number[] = [
  100.0, 100.0, 100.0, 100.0, 10.0,
  4.0, 4.0, 0.75, 4.5, 0.8,
  3.5, 5.0, 0.25, 0.9, 4.0,
  1.0, 6.0, 2.0, 2.0, 0.8,
  0.8
];

/**
 * 每个权重的中文名。
 *
 * 这 21 个数对用户是黑盒,但「能不能调」和「调的时候知不知道在调什么」是两件事。
 * 标出含义后,至少能看出 w[0..3] 是四档初始稳定性、w[20] 是遗忘曲线形状。
 */
export const W_LABEL: string[] = [
  '初始稳定性·陌生',
  '初始稳定性·困难',
  '初始稳定性·认识',
  '初始稳定性·简单',
  '初始难度基准',
  '初始难度·评级敏感度',
  '难度变化步长',
  '难度均值回归强度',
  '稳定性增长基准',
  '稳定性增长·难度衰减',
  '稳定性增长·可提取性权重',
  '遗忘后稳定性基准',
  '遗忘后·难度影响',
  '遗忘后·稳定性影响',
  '遗忘后·可提取性影响',
  '困难惩罚系数',
  '简单奖励系数',
  '同日重复·评级敏感度',
  '同日重复·偏移',
  '同日重复·稳定性衰减',
  '遗忘曲线衰减率'
];

const STABILITY_MIN = 0.001;
const INITIAL_STABILITY_MAX = 100.0;
const MIN_DIFFICULTY = 1.0;
const MAX_DIFFICULTY = 10.0;
const MAX_STABILITY = 36500;

/** 间隔模糊化的区间与幅度(与 py-fsrs FUZZ_RANGES 一致) */
const FUZZ_START_1 = 2.5;
const FUZZ_START_2 = 7.0;
const FUZZ_START_3 = 20.0;
const FUZZ_FACTOR_1 = 0.15;
const FUZZ_FACTOR_2 = 0.10;
const FUZZ_FACTOR_3 = 0.05;

// ---------------------------------------------------------------- 参数对象

/**
 * 调度器参数。
 *
 * 为什么不把这些散成一个个 global:`schedule()` 是纯函数,
 * 参数必须能整体替换(设置页改完之后立刻生效,测试里也能塞固定值)。
 */
export class FsrsParams {
  /** 21 个权重 */
  w: number[] = DEFAULT_W.slice();
  /** 目标保持率:希望「记住的概率」降到多少时安排复习 */
  desiredRetention: number = 0.9;
  /** 最大间隔(天) */
  maximumInterval: number = 36500;
  /** 学习阶段步进(分钟),默认 1 分钟 / 10 分钟 */
  learningSteps: number[] = [1, 10];
  /** 重学阶段步进(分钟),默认 10 分钟 */
  relearningSteps: number[] = [10];
  /** 是否给间隔加随机扰动,避免所有卡的到期日挤在同一天 */
  enableFuzzing: boolean = true;

  clone(): FsrsParams {
    const p = new FsrsParams();
    p.w = this.w.slice();
    p.desiredRetention = this.desiredRetention;
    p.maximumInterval = this.maximumInterval;
    p.learningSteps = this.learningSteps.slice();
    p.relearningSteps = this.relearningSteps.slice();
    p.enableFuzzing = this.enableFuzzing;
    return p;
  }
}

/** 默认参数(官方默认值) */
export function defaultParams(): FsrsParams {
  return new FsrsParams();
}

/**
 * 当前生效的参数。
 *
 * 用模块级变量而不是给每个函数加参数,是因为调用点太多
 * (Database 的预测、StatsPage 的记忆条、StudyPage 的间隔预览都算 retrievability)。
 * 参数只在 App 启动和用户改设置时整体替换,不存在并发写。
 */
let PARAMS: FsrsParams = defaultParams();

export function setFsrsParams(p: FsrsParams): void {
  PARAMS = p;
}

export function getFsrsParams(): FsrsParams {
  return PARAMS;
}

/**
 * 随机源。默认就是 Math.random,之所以做成可替换的,
 * 是因为间隔扰动会让长跑模拟测试每次结果都不一样 ——
 * 测试里换成固定种子的 PRNG,默认行为不变,回归测试才可复现。
 */
let RAND: () => number = () => Math.random();

export function setRandomSource(fn: () => number): void {
  RAND = fn;
}

/** 把权重夹到合法区间。用户手输的数字必须过这一关,否则 e^x 会炸 */export function sanitizeW(raw: number[]): number[] {
  const out: number[] = [];
  for (let i = 0; i < W_COUNT; i++) {
    let v = i < raw.length ? raw[i] : DEFAULT_W[i];
    if (!Number.isFinite(v)) {
      v = DEFAULT_W[i];
    }
    out.push(clamp(v, W_LOWER[i], W_UPPER[i]));
  }
  return out;
}

/** 某个权重的合法范围,设置页用来做输入校验 */
export function wBound(i: number): number[] {
  return [W_LOWER[i], W_UPPER[i]];
}

function decayOf(w: number[]): number {
  return -w[20];
}

function factorOf(w: number[]): number {
  const d = decayOf(w);
  return Math.pow(0.9, 1 / d) - 1;
}

function clamp(v: number, lo: number, hi: number): number {
  if (v < lo) {
    return lo;
  }
  if (v > hi) {
    return hi;
  }
  return v;
}

function clampStability(s: number): number {
  return clamp(s, STABILITY_MIN, MAX_STABILITY);
}

function clampDifficulty(d: number): number {
  return clamp(d, MIN_DIFFICULTY, MAX_DIFFICULTY);
}

// ---------------------------------------------------------------- 基础公式

/** 可提取性:距今 elapsedDays 天时还能想起该卡的概率 */
export function retrievability(elapsedDays: number, stability: number): number {
  const s = stability > STABILITY_MIN ? stability : STABILITY_MIN;
  const t = elapsedDays > 0 ? elapsedDays : 0;
  const w = PARAMS.w;
  const r = Math.pow(1 + factorOf(w) * t / s, decayOf(w));
  return clamp(r, 0, 1);
}

/**
 * 反解间隔:希望保持率降到 targetR 时复习,需要多少天。
 * 目标保持率 0.9 时结果恰好等于稳定性。
 */
export function intervalForRetention(stability: number, targetR: number): number {
  const s = clampStability(stability);
  const t = clamp(targetR, 0.01, 0.99);
  const w = PARAMS.w;
  const raw = s / factorOf(w) * (Math.pow(t, 1 / decayOf(w)) - 1);
  return clamp(raw, 1, PARAMS.maximumInterval);
}

/** 按当前参数算下一次间隔(天),含取整与上下界 —— 官方 _next_interval */
function nextInterval(stability: number): number {
  const r = clamp(PARAMS.desiredRetention, 0.01, 0.99);
  const days = intervalForRetention(stability, r);
  return clamp(Math.round(days), 1, PARAMS.maximumInterval);
}

/** 官方 _initial_stability。评级映射:本项目 Grade 0~3 → FSRS rating 1~4,所以下标就是 grade */
function initialStability(grade: Grade): number {
  const s = PARAMS.w[grade];
  return clamp(s, STABILITY_MIN, INITIAL_STABILITY_MAX);
}

/** 官方 _initial_difficulty */
function initialDifficulty(grade: Grade, doClamp: boolean): number {
  const w = PARAMS.w;
  const d = w[4] - Math.exp(w[5] * grade) + 1;
  return doClamp ? clampDifficulty(d) : d;
}

/** 官方 _next_difficulty:线性阻尼 + 向「简单」的均值回归 */
function nextDifficulty(difficulty: number, grade: Grade): number {
  const w = PARAMS.w;
  const arg1 = initialDifficulty(Grade.Easy, false);
  const delta = -(w[6] * (grade - 2));
  const arg2 = difficulty + (10.0 - difficulty) * delta / 9.0;
  return clampDifficulty(w[7] * arg1 + (1 - w[7]) * arg2);
}

/** 官方 _short_term_stability:同一天内的重复作答(FSRS-6 新增) */
function shortTermStability(stability: number, grade: Grade): number {
  const w = PARAMS.w;
  let inc = Math.exp(w[17] * (grade - 2 + w[18])) * Math.pow(stability, -w[19]);
  if (grade !== Grade.Again) {
    inc = inc > 1.0 ? inc : 1.0;
  }
  return clampStability(stability * inc);
}

/** 官方 _next_forget_stability */
function nextForgetStability(difficulty: number, stability: number, r: number): number {
  const w = PARAMS.w;
  const longTerm = w[11]
    * Math.pow(difficulty, -w[12])
    * (Math.pow(stability + 1, w[13]) - 1)
    * Math.exp((1 - r) * w[14]);
  const shortTerm = stability / Math.exp(w[17] * w[18]);
  return clampStability(Math.min(longTerm, shortTerm));
}

/** 官方 _next_recall_stability */
function nextRecallStability(difficulty: number, stability: number, r: number, grade: Grade): number {
  const w = PARAMS.w;
  const hardPenalty = grade === Grade.Hard ? w[15] : 1;
  const easyBonus = grade === Grade.Easy ? w[16] : 1;
  const grown = stability * (1
    + Math.exp(w[8])
    * (11 - difficulty)
    * Math.pow(stability, -w[9])
    * (Math.exp((1 - r) * w[10]) - 1)
    * hardPenalty
    * easyBonus);
  return clampStability(grown);
}

function nextStability(difficulty: number, stability: number, r: number, grade: Grade): number {
  if (grade === Grade.Again) {
    return nextForgetStability(difficulty, stability, r);
  }
  return nextRecallStability(difficulty, stability, r, grade);
}

/** 官方 _get_fuzzed_interval:间隔越长扰动越大,2.5 天以内不扰动 */
function fuzzInterval(days: number): number {
  if (days < FUZZ_START_1) {
    return days;
  }
  const d = days;
  let delta = 1.0;
  delta += FUZZ_FACTOR_1 * Math.max(Math.min(d, FUZZ_START_2) - FUZZ_START_1, 0);
  delta += FUZZ_FACTOR_2 * Math.max(Math.min(d, FUZZ_START_3) - FUZZ_START_2, 0);
  delta += FUZZ_FACTOR_3 * Math.max(d - FUZZ_START_3, 0);

  let minIvl = Math.round(d - delta);
  let maxIvl = Math.round(d + delta);
  minIvl = Math.max(2, minIvl);
  maxIvl = Math.min(maxIvl, PARAMS.maximumInterval);
  minIvl = Math.min(minIvl, maxIvl);

  const fuzzed = RAND() * (maxIvl - minIvl + 1) + minIvl;
  return Math.min(Math.round(fuzzed), PARAMS.maximumInterval);
}

// ---------------------------------------------------------------- 展示辅助

/** 间隔文案:不足 1 天显示小时/分钟 */
export function formatInterval(days: number): string {
  if (days >= 365) {
    return (days / 365).toFixed(1) + ' 年';
  }
  if (days >= 30) {
    return (days / 30).toFixed(1) + ' 个月';
  }
  if (days >= 1) {
    return Math.round(days) + ' 天';
  }
  const mins = days * 1440;
  if (mins >= 60) {
    return Math.round(mins / 60) + ' 小时';
  }
  return Math.max(1, Math.round(mins)) + ' 分钟';
}

/** 掌握度分级:由稳定性推导,门槛明确 */
export function masteryOf(stability: number): Mastery {
  if (stability <= 0) {
    return Mastery.New;
  }
  if (stability < 1) {
    return Mastery.Learning;
  }
  if (stability < 7) {
    return Mastery.Familiar;
  }
  if (stability < 60) {
    return Mastery.Strong;
  }
  return Mastery.Mastered;
}

/** 掌握度百分比,用于进度条:把稳定性按对数刻度映射到 0~100 */
export function masteryPercent(stability: number, reps: number): number {
  if (reps <= 0 || stability <= 0) {
    return 0;
  }
  const raw = Math.log(stability + 1) / Math.log(366) * 100;
  return clamp(Math.round(raw), 0, 100);
}

/** 记忆状态的文字解释 */
export function memoryHint(state: CardState): string {
  if (state.reps <= 0) {
    return '新卡,还没有记忆数据';
  }
  const d = state.difficulty;
  let dText = '难度中等';
  if (d >= 7) {
    dText = '对你偏难';
  } else if (d <= 3.5) {
    dText = '对你偏易';
  }
  return `稳定性 ${state.stability.toFixed(1)} 天 · ${dText}(${d.toFixed(1)}/10) · 已复习 ${state.reps} 次`;
}

// ---------------------------------------------------------------- 调度主流程

/** 引擎计算出的状态迁移结果 */
export interface SrsResult {
  /** 迁移后的状态 */
  state: CardState;
  /** 距下次复习的天数(>=1 天为长期排期,<1 为分钟级步进) */
  intervalDays: number;
  /** 评级前的可提取性 */
  retrievability: number;
  /** 本次实际间隔(天),用于统计「到期才复习还是提前复习」 */
  elapsedDays: number;
  /** 调度理由 */
  reason: string;
  /** 评级前稳定性 */
  stabilityBefore: number;
}

/** 新建一张卡的状态 */
export function newCardState(cardId: number, now: number): CardState {
  const s: CardState = {
    cardId: cardId,
    stability: 0,
    difficulty: 5,
    reps: 0,
    lapses: 0,
    streak: 0,
    lastReview: 0,
    due: now,
    phase: LearnPhase.New,
    step: 0,
    firstSeen: now
  };
  return s;
}

function gradeText(g: Grade): string {
  if (g === Grade.Again) {
    return '忘了';
  }
  if (g === Grade.Hard) {
    return '困难';
  }
  if (g === Grade.Good) {
    return '良好';
  }
  return '简单';
}

/**
 * 从学习步进表里取出这一步的间隔(分钟),并给出说明。
 * 官方实现里 Hard 在第一步有特殊处理(取 1.5 倍或前两步均值),
 * 这里照搬,保证与官方排期一致。
 */
function stepInterval(steps: number[], step: number, grade: Grade): number {
  if (grade === Grade.Hard) {
    if (step === 0 && steps.length === 1) {
      return steps[0] * 1.5;
    }
    if (step === 0 && steps.length >= 2) {
      return (steps[0] + steps[1]) / 2.0;
    }
    return steps[step < steps.length ? step : steps.length - 1];
  }
  return steps[step < steps.length ? step : steps.length - 1];
}

/**
 * 核心调度。纯函数(随机扰动除外),不依赖数据库,方便单独验证。
 *
 * @param fuzz 是否给间隔加随机扰动。默认跟随参数设置;
 *             界面上的「预计间隔」预览会传 false,否则每次重绘数字都在跳。
 */
export function scheduleFsrs(prev: CardState, grade: Grade, now: number, fuzz?: boolean): SrsResult {
  const w = PARAMS.w;
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
  s.reps = s.reps + 1;

  // 官方用的是整数天(``.days``)。同一次会话里连认几次都属于「同一天」,
  // 会走短期记忆分支 —— 这正是 FSRS-6 的 w[17..19] 要处理的情形。
  const elapsedDaysRaw = s.lastReview > 0 ? Math.max(0, (now - s.lastReview) / DAY_MS) : 0;
  const elapsedDays = Math.floor(elapsedDaysRaw);
  const isNew = prev.reps <= 0 || prev.stability <= 0;
  const rBefore = (s.lastReview > 0 && !isNew) ? retrievability(elapsedDays, s.stability) : 0;

  let phase = prev.phase;
  let step = prev.step;
  let intervalDays = 0;
  let reason = '';

  // ---- 第一段:更新稳定性与难度(官方的三个 state 分支在这里合并) ----
  if (isNew) {
    s.stability = initialStability(grade);
    s.difficulty = initialDifficulty(grade, true);
    reason = `首次作答为「${gradeText(grade)}」,FSRS 初始稳定性 ${s.stability.toFixed(2)} 天`;
  } else if (elapsedDays < 1) {
    // 同一天内重复作答 —— FSRS-6 新增的短期记忆路径
    s.stability = shortTermStability(s.stability, grade);
    s.difficulty = nextDifficulty(s.difficulty, grade);
    reason = `同日重复(短期记忆),稳定性 ${stabilityBefore.toFixed(2)} → ${s.stability.toFixed(2)} 天`;
    if (grade === Grade.Again) {
      // lapses 不参与 FSRS 的排期计算,纯粹是给「薄弱卡排行」用的统计量。
      // 所以这里比官方多记一笔:同一天内连续认不出,同样说明这张卡是我的软肋,
      // 只统计跨天的遗忘会让排行榜漏掉最该练的那批卡。
      s.lapses = s.lapses + 1;
    }
  } else {
    s.stability = nextStability(s.difficulty, s.stability, rBefore, grade);
    s.difficulty = nextDifficulty(s.difficulty, grade);
    if (grade === Grade.Again) {
      s.lapses = s.lapses + 1;
      reason = `判定为遗忘(距上次 ${elapsedDays} 天,当时记住概率 ${Math.round(rBefore * 100)}%),`
        + `稳定性 ${stabilityBefore.toFixed(1)} → ${s.stability.toFixed(1)} 天`;
    } else {
      const ratio = stabilityBefore > 0 ? s.stability / stabilityBefore : 1;
      reason = `回忆成功(距上次 ${elapsedDays} 天),稳定性 ${stabilityBefore.toFixed(1)} → `
        + `${s.stability.toFixed(1)} 天(×${ratio.toFixed(2)})`;
    }
  }

  // ---- 第二段:决定下次到期时间(完全对齐官方的 state 机) ----
  const learnSteps = PARAMS.learningSteps;
  const relearnSteps = PARAMS.relearningSteps;

  if (phase === LearnPhase.New || phase === LearnPhase.Learning) {
    const curStep = phase === LearnPhase.New ? 0 : step;
    const graduate = learnSteps.length === 0
      || (curStep >= learnSteps.length && grade !== Grade.Again);

    if (graduate) {
      phase = LearnPhase.Review;
      step = 0;
      intervalDays = nextInterval(s.stability);
      reason = reason + `;学习阶段毕业,排期 ${formatInterval(intervalDays)} 后`;
    } else if (grade === Grade.Again) {
      phase = LearnPhase.Learning;
      step = 0;
      intervalDays = learnSteps.length > 0 ? learnSteps[0] / 1440 : nextInterval(s.stability);
      reason = reason + `;${formatInterval(intervalDays)}后再认一次`;
    } else if (grade === Grade.Easy) {
      phase = LearnPhase.Review;
      step = 0;
      intervalDays = nextInterval(s.stability);
      reason = reason + `;评为简单,直接毕业,排期 ${formatInterval(intervalDays)} 后`;
    } else if (grade === Grade.Good && curStep + 1 >= learnSteps.length) {
      phase = LearnPhase.Review;
      step = 0;
      intervalDays = nextInterval(s.stability);
      reason = reason + `;走完学习步进,排期 ${formatInterval(intervalDays)} 后`;
    } else {
      const nextStep = grade === Grade.Good ? curStep + 1 : curStep;
      phase = LearnPhase.Learning;
      step = nextStep;
      intervalDays = stepInterval(learnSteps, nextStep, grade) / 1440;
      reason = reason + `;${formatInterval(intervalDays)}后再认一次`;
    }
  } else if (phase === LearnPhase.Review) {
    if (grade === Grade.Again) {
      if (relearnSteps.length === 0) {
        intervalDays = nextInterval(s.stability);
        reason = reason + `;无重学步进,直接排期 ${formatInterval(intervalDays)} 后`;
      } else {
        phase = LearnPhase.Relearning;
        step = 0;
        intervalDays = relearnSteps[0] / 1440;
        reason = reason + `;进入重学,${formatInterval(intervalDays)}后再认一次`;
      }
    } else {
      intervalDays = nextInterval(s.stability);
      reason = reason + `;按 ${(PARAMS.desiredRetention * 100).toFixed(0)}% 保持率排期 `
        + `${formatInterval(intervalDays)} 后`;
    }
  } else {
    // Relearning
    const graduate = relearnSteps.length === 0
      || (step >= relearnSteps.length && grade !== Grade.Again);
    if (graduate) {
      phase = LearnPhase.Review;
      step = 0;
      intervalDays = nextInterval(s.stability);
      reason = reason + `;重学通过,排期 ${formatInterval(intervalDays)} 后`;
    } else if (grade === Grade.Again) {
      step = 0;
      intervalDays = relearnSteps.length > 0 ? relearnSteps[0] / 1440 : nextInterval(s.stability);
      reason = reason + `;重学未通过,${formatInterval(intervalDays)}后再认一次`;
    } else if (grade === Grade.Easy) {
      phase = LearnPhase.Review;
      step = 0;
      intervalDays = nextInterval(s.stability);
      reason = reason + `;评为简单,结束重学,排期 ${formatInterval(intervalDays)} 后`;
    } else if (grade === Grade.Good && step + 1 >= relearnSteps.length) {
      phase = LearnPhase.Review;
      step = 0;
      intervalDays = nextInterval(s.stability);
      reason = reason + `;走完重学步进,排期 ${formatInterval(intervalDays)} 后`;
    } else {
      const nextStep = grade === Grade.Good ? step + 1 : step;
      step = nextStep;
      intervalDays = stepInterval(relearnSteps, nextStep, grade) / 1440;
      reason = reason + `;${formatInterval(intervalDays)}后再认一次`;
    }
  }

  // ---- 第三段:模糊化(官方只在卡片回到 Review 状态时才扰动) ----
  const wantFuzz = fuzz !== undefined ? fuzz : PARAMS.enableFuzzing;
  if (wantFuzz && phase === LearnPhase.Review && intervalDays >= 1) {
    const fuzzed = fuzzInterval(intervalDays);
    if (fuzzed !== intervalDays) {
      reason = reason + `(扰动为 ${formatInterval(fuzzed)})`;
      intervalDays = fuzzed;
    }
  }

  // ---- 连击 ----
  if (grade === Grade.Again) {
    s.streak = 0;
  } else if (grade === Grade.Good || grade === Grade.Easy) {
    s.streak = s.streak + 1;
  }

  s.phase = phase;
  s.step = step;
  s.lastReview = now;
  s.due = now + Math.round(intervalDays * DAY_MS);

  const out: SrsResult = {
    state: s,
    intervalDays: intervalDays,
    retrievability: rBefore,
    elapsedDays: elapsedDaysRaw,
    reason: reason,
    stabilityBefore: stabilityBefore
  };
  return out;
}

/** 供设置页展示用:当前遗忘曲线的半衰描述 */
/** 可选的排期引擎 */
export type Algo = 'fsrs' | 'ebbinghaus';

/**
 * 当前生效的引擎。默认 FSRS-6。
 *
 * 和 setFsrsParams 一样存模块级变量、由 AppStore 在启动和用户切换时写入 ——
 * 这样 schedule() 保持「纯函数 + 一处配置」的形状,调用方一行都不用改。
 */
let ALGO: Algo = 'fsrs';

export function setAlgorithm(a: Algo): void {
  ALGO = a;
}

export function getAlgorithm(): Algo {
  return ALGO;
}

/**
 * 排期入口。按当前引擎分发。
 *
 * 两个引擎写的是同一张 learning 表、同一组字段,所以随时切换都不会丢数据:
 * 切到艾宾浩斯后,已有的 stability 会被当成「当前间隔」继续用;
 * 切回 FSRS 后,艾宾浩斯留下的 stability / difficulty 也都是合法值。
 * 会变的只是**以后**怎么排期 —— 这和换参数的性质相同。
 */
export function schedule(prev: CardState, grade: Grade, now: number, fuzz?: boolean): SrsResult {
  if (ALGO === 'ebbinghaus') {
    return scheduleEbbinghaus(prev, grade, now);
  }
  return scheduleFsrs(prev, grade, now, fuzz);
}

export function decaySummary(): string {
  const w = PARAMS.w;
  const d = decayOf(w);
  return `DECAY=${d.toFixed(4)} · FACTOR=${factorOf(w).toFixed(4)} · `
    + `目标保持率 ${(PARAMS.desiredRetention * 100).toFixed(0)}%`;
}
