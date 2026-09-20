/**
 * REPS 的领域类型与排期状态。
 *
 * 命名纪律(见 CONTEXT.md):
 *   deck 卡组 / note 笔记 / card 卡片 / rep 一次作答 / set 一天的学习量。
 * note 与 card 是**两层**:一段含 3 个挖空的笔记会生成 3 张各自独立排期的卡片。
 * 这一层区分是从 Anki 借来的,不区分的话完形填空根本没法排期。
 */

/** 学习阶段 */
export enum LearnPhase {
  New = 0,
  Learning = 1,
  Review = 2,
  Relearning = 3
}

/** 复习评级:0 忘光 / 1 困难 / 2 良好 / 3 简单 */
export enum Grade {
  Again = 0,
  Hard = 1,
  Good = 2,
  Easy = 3
}

/** 卡片题型,由 Quizify 语法决定 */
export enum NoteType {
  /** 问答:正面提问,背面作答 */
  QA = 0,
  /** 选择题:正面带 ;;; 选项块 */
  Choice = 1,
  /** 完形填空:正面含 {{挖空}},每个挖空一张卡 */
  Cloze = 2
}

export const NOTE_TYPE_LABEL: string[] = ['问答', '选择题', '完形填空'];

/**
 * 每张卡片的学习状态(与 scheduling 表一一对应)。
 *
 * 字段形状直接沿用 WordSnap 里已验证过的那一套 —— 两个排期引擎都写满全部字段,
 * 所以随时切换引擎不会污染数据。
 */
export interface CardState {
  cardId: number;
  /** 记忆稳定性,单位「天」。数值越大,记得越牢 */
  stability: number;
  /** 难度 1~10,越大越难。**不得为 0**,0 在 FSRS 里非法 */
  difficulty: number;
  /** 已复习次数 */
  reps: number;
  /** 遗忘(lapse)次数 */
  lapses: number;
  /** 连续答对次数 */
  streak: number;
  /** 上次复习时间(毫秒) */
  lastReview: number;
  /** 下次到期时间(毫秒) */
  due: number;
  /** 当前学习阶段 */
  phase: LearnPhase;
  /** 学习阶段内的步进下标 */
  step: number;
  /** 首次学习时间 */
  firstSeen: number;
}

/** 复习日志(统计页与「排期透明化」的全部数据来源) */
export interface ReviewLog {
  id: number;
  cardId: number;
  /** 复习时刻(毫秒) */
  ts: number;
  /** 评级 0~3 */
  grade: number;
  /** 本次复习前的稳定性 */
  stabilityBefore: number;
  /** 复习前距上次复习的天数 */
  elapsedDays: number;
  /** 复习前的可提取性 0~1 */
  retrievability: number;
  /** 本次推迟的天数 */
  intervalDays: number;
  /** 本次答题耗时(毫秒) */
  costMs: number;
  /**
   * 当时生效的排期引擎,取值 'fsrs' | 'ebbinghaus'(即 Srs.ets 的 Algo 类型)。
   * 这里故意写成 string 而不 import Algo:Srs.ets 已经 import 了本文件,
   * 反向 import 会形成循环依赖。持久化层负责校验取值合法。
   */
  algo: string;
}

/** 卡组。用 parentId 表达 Quizify 的 `A::B` 嵌套 */
export interface Deck {
  id: number;
  name: string;
  parentId: number;
}

/** 一条笔记 = 导入源里的一张「题」 */
export interface Note {
  id: number;
  deckId: number;
  type: NoteType;
  /** 正面原文(Quizify 语法未展开) */
  front: string;
  /** 背面原文 */
  back: string;
  /** #### 标题,文件内唯一且带小节限定 */
  title: string;
  /** 来源文件路径,便于重导时定位 */
  sourceFile: string;
  /** hash(deck + title + ordinal),重复导入靠它认出「还是那张卡」 */
  fingerprint: string;
  /** 为将来同步预留 */
  uuid: string;
  updatedAt: number;
}

/** 一张卡片。一条笔记可生成多张(完形填空每个挖空一张) */
export interface Card {
  id: number;
  noteId: number;
  /** 在该笔记内的序号,从 0 起。问答/选择题恒为 0 */
  ordinal: number;
  uuid: string;
  updatedAt: number;
}

/** 可调度队列里的一项 = 卡片 + 它的笔记 + 学习状态(新卡没有状态) */
export interface QueueItem {
  card: Card;
  note: Note;
  state?: CardState;
}

/** 掌握度分级 */
export enum Mastery {
  New = 0,
  Learning = 1,
  Familiar = 2,
  Strong = 3,
  Mastered = 4
}

export const MASTERY_LABEL: string[] = ['未学', '生疏', '眼熟', '熟练', '已掌握'];
export const MASTERY_COLOR: string[] = ['#B0B7C3', '#F5A623', '#4A90D9', '#3FBF7F', '#2E9E63'];
export const GRADE_LABEL: string[] = ['忘了', '困难', '良好', '简单'];
export const GRADE_COLOR: string[] = ['#E5544B', '#F5A623', '#4A90D9', '#3FBF7F'];
export const PHASE_LABEL: string[] = ['新卡', '学习中', '复习中', '重学中'];
