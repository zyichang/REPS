/**
 * 表结构、行映射与日界算术 —— **纯逻辑,不 import 任何 @kit.\* **。
 *
 * 为什么单独一层:ArkTS 的 relationalStore 只能在设备上跑,
 * 而 SQL 写错、字段漏存这类问题恰恰最需要测。WordSnap 当年的做法是
 * 在 devtest 里**手抄一份镜像 SQL**,结果生产代码改了、镜像没跟上,
 * 四个测试文件一起失真。
 *
 * 这里改成:所有 DDL 与行映射都放在本文件,Database.ets 只负责调
 * relationalStore。桌面测试直接把本文件同步过去,用 node:sqlite
 * 执行**同一份**建表语句和同一套映射函数,不存在第二份副本。
 */

import { CardState, LearnPhase } from '../model/Models';
import { DAY_MS, MIN_MS } from '../srs/Srs';

// ---------------------------------------------------------------- 日界

/**
 * 一天的分界是凌晨 1 点,不是午夜。
 *
 * 排期算出来的到期时刻带小时分钟(2.56 天后 = 次日 00:26)。按午夜切,
 * 深夜还在学的人刚过 0 点就会看到一批「明天的卡」冒出来。
 *
 * 注意:这个分界只决定「一张卡属于哪一天」以及「今日集合怎么组成」。
 * **取卡条件仍然是 due <= now**。如果把分界也用到取卡上,
 * 5 分钟 / 30 分钟的学习步进卡会全部立刻到期,学习流水线就没了。
 */
export const DAY_CUTOFF_HOUR: number = 1;
export const DAY_CUTOFF_MS: number = DAY_CUTOFF_HOUR * 60 * MIN_MS;

/**
 * 本地日序号(以本地时区把毫秒归到「天」)。
 *
 * 减去 DAY_CUTOFF_MS 之后再取整:这样 00:00~01:00 会落回前一天,
 * 「一天」实际是 01:00 → 次日 01:00。
 */
export function dayIndex(ms: number): number {
  const d = new Date(ms);
  const local = ms - d.getTimezoneOffset() * MIN_MS - DAY_CUTOFF_MS;
  return Math.floor(local / DAY_MS);
}

/**
 * 日序号 -> 当天的分界时刻(即当天凌晨 1 点)毫秒。dayIndex 的逆。
 *
 * 已知局限:时区偏移按 day*DAY_MS 那一刻取,夏令时切换当天会差一小时。
 * 目标时区(中国)不用夏令时,所以暂不处理。
 */
export function dayStart(day: number): number {
  const d = new Date(day * DAY_MS);
  const offset = d.getTimezoneOffset() * MIN_MS;
  return day * DAY_MS + offset + DAY_CUTOFF_MS;
}

// ---------------------------------------------------------------- DDL

/**
 * 建表语句。顺序即执行顺序。
 *
 * 设计要点:
 *  - notes 与 cards 分两层。一条含 3 个 {{挖空}} 的笔记生成 3 张卡,
 *    每张卡**各自独立排期**。合成一张表就没法给挖空单独排期了。
 *  - scheduling 以 card_id 作主键,一张卡最多一行。
 *    **没有 scheduling 行 = 这张卡还没被答过(新卡)** —— 队列查询靠这个判断。
 *  - notes.fingerprint 唯一:重复导入靠它认出「还是那张卡」并保住排期(Task 7)。
 *  - uuid / updated_at 是为将来同步预留的,现阶段只写不用。
 */
export const DDL: string[] = [
  `CREATE TABLE IF NOT EXISTS decks (
     id        INTEGER PRIMARY KEY AUTOINCREMENT,
     name      TEXT    NOT NULL,
     parent_id INTEGER NOT NULL DEFAULT 0,
     UNIQUE(name, parent_id)
   )`,

  `CREATE TABLE IF NOT EXISTS notes (
     id          INTEGER PRIMARY KEY AUTOINCREMENT,
     deck_id     INTEGER NOT NULL,
     type        INTEGER NOT NULL DEFAULT 0,
     front       TEXT    NOT NULL,
     back        TEXT    NOT NULL DEFAULT '',
     title       TEXT    NOT NULL DEFAULT '',
     source_file TEXT    NOT NULL DEFAULT '',
     fingerprint TEXT    NOT NULL UNIQUE,
     uuid        TEXT    NOT NULL UNIQUE,
     updated_at  INTEGER NOT NULL DEFAULT 0
   )`,

  `CREATE TABLE IF NOT EXISTS cards (
     id         INTEGER PRIMARY KEY AUTOINCREMENT,
     note_id    INTEGER NOT NULL,
     ordinal    INTEGER NOT NULL DEFAULT 0,
     uuid       TEXT    NOT NULL UNIQUE,
     updated_at INTEGER NOT NULL DEFAULT 0,
     UNIQUE(note_id, ordinal)
   )`,

  `CREATE TABLE IF NOT EXISTS scheduling (
     card_id     INTEGER PRIMARY KEY,
     stability   REAL    NOT NULL DEFAULT 0,
     difficulty  REAL    NOT NULL DEFAULT 5,
     reps        INTEGER NOT NULL DEFAULT 0,
     lapses      INTEGER NOT NULL DEFAULT 0,
     streak      INTEGER NOT NULL DEFAULT 0,
     last_review INTEGER NOT NULL DEFAULT 0,
     due         INTEGER NOT NULL DEFAULT 0,
     phase       INTEGER NOT NULL DEFAULT 0,
     step        INTEGER NOT NULL DEFAULT 0,
     first_seen  INTEGER NOT NULL DEFAULT 0
   )`,

  `CREATE TABLE IF NOT EXISTS review_log (
     id               INTEGER PRIMARY KEY AUTOINCREMENT,
     card_id          INTEGER NOT NULL,
     ts               INTEGER NOT NULL,
     grade            INTEGER NOT NULL,
     stability_before REAL    NOT NULL DEFAULT 0,
     elapsed_days     REAL    NOT NULL DEFAULT 0,
     retrievability   REAL    NOT NULL DEFAULT 0,
     interval_days    REAL    NOT NULL DEFAULT 0,
     cost_ms          INTEGER NOT NULL DEFAULT 0,
     algo             TEXT    NOT NULL DEFAULT 'fsrs'
   )`,

  // 队列查询是「按 due 取到期卡」,没有这个索引会全表扫
  `CREATE INDEX IF NOT EXISTS idx_sched_due ON scheduling(due)`,
  `CREATE INDEX IF NOT EXISTS idx_cards_note ON cards(note_id)`,
  `CREATE INDEX IF NOT EXISTS idx_notes_deck ON notes(deck_id)`,
  // 统计页按卡查历史、按时间查每日量,两个方向都要
  `CREATE INDEX IF NOT EXISTS idx_log_card ON review_log(card_id)`,
  `CREATE INDEX IF NOT EXISTS idx_log_ts ON review_log(ts)`,
];

/** 合法的排期引擎取值。ReviewLog.algo 存 string,由这里兜底校验 */
export const VALID_ALGOS: string[] = ['fsrs', 'ebbinghaus'];

export function isValidAlgo(a: string): boolean {
  return VALID_ALGOS.indexOf(a) >= 0;
}

// ---------------------------------------------------------------- 行映射

/** scheduling 表的一行。字段名与列名一致,便于逐列核对 */
export interface SchedulingRow {
  card_id: number;
  stability: number;
  difficulty: number;
  reps: number;
  lapses: number;
  streak: number;
  last_review: number;
  due: number;
  phase: number;
  step: number;
  first_seen: number;
}

/** scheduling 表的列顺序。INSERT 的占位符顺序必须与之一致 */
export const SCHED_COLUMNS: string[] = [
  'card_id', 'stability', 'difficulty', 'reps', 'lapses', 'streak',
  'last_review', 'due', 'phase', 'step', 'first_seen',
];

export function toSchedulingRow(s: CardState): SchedulingRow {
  return {
    card_id: s.cardId,
    stability: s.stability,
    difficulty: s.difficulty,
    reps: s.reps,
    lapses: s.lapses,
    streak: s.streak,
    last_review: s.lastReview,
    due: s.due,
    phase: s.phase as number,
    step: s.step,
    first_seen: s.firstSeen,
  };
}

export function fromSchedulingRow(r: SchedulingRow): CardState {
  return {
    cardId: r.card_id,
    stability: r.stability,
    difficulty: r.difficulty,
    reps: r.reps,
    lapses: r.lapses,
    streak: r.streak,
    lastReview: r.last_review,
    due: r.due,
    phase: r.phase as LearnPhase,
    step: r.step,
    firstSeen: r.first_seen,
  };
}

/** 按 SCHED_COLUMNS 的顺序取值,供 INSERT 使用 */
export function schedulingValues(r: SchedulingRow): number[] {
  return [
    r.card_id, r.stability, r.difficulty, r.reps, r.lapses, r.streak,
    r.last_review, r.due, r.phase, r.step, r.first_seen,
  ];
}

/**
 * 写入排期状态的语句。用 INSERT OR REPLACE:
 * 一张卡只有一行,答完直接整行覆盖,不需要先查再决定 insert 还是 update。
 */
export const SQL_UPSERT_SCHEDULING: string =
  `INSERT OR REPLACE INTO scheduling (${SCHED_COLUMNS.join(', ')}) ` +
  `VALUES (${SCHED_COLUMNS.map(() => '?').join(', ')})`;

export const SQL_SELECT_SCHEDULING: string =
  `SELECT ${SCHED_COLUMNS.join(', ')} FROM scheduling WHERE card_id = ?`;

// ---------------------------------------------------------------- 复习日志

export interface ReviewLogRow {
  card_id: number;
  ts: number;
  grade: number;
  stability_before: number;
  elapsed_days: number;
  retrievability: number;
  interval_days: number;
  cost_ms: number;
  algo: string;
}

export const LOG_COLUMNS: string[] = [
  'card_id', 'ts', 'grade', 'stability_before', 'elapsed_days',
  'retrievability', 'interval_days', 'cost_ms', 'algo',
];

export const SQL_INSERT_LOG: string =
  `INSERT INTO review_log (${LOG_COLUMNS.join(', ')}) ` +
  `VALUES (${LOG_COLUMNS.map(() => '?').join(', ')})`;

/**
 * 今日集合的取卡语句(Task 8 会在外层加上限与新卡额度)。
 *
 * 注意 due <= ? 用的是 now,**不是**日界 —— 见 DAY_CUTOFF_HOUR 的说明。
 */
export const SQL_DUE_CARDS: string =
  `SELECT s.card_id FROM scheduling s WHERE s.due <= ? ORDER BY s.due ASC LIMIT ?`;

/** 新卡 = 没有 scheduling 行的卡 */
export const SQL_NEW_CARDS: string =
  `SELECT c.id AS card_id FROM cards c
     LEFT JOIN scheduling s ON s.card_id = c.id
    WHERE s.card_id IS NULL
    ORDER BY c.id ASC LIMIT ?`;

// ---------------------------------------------------------------- 写入卡组/笔记/卡片

/** 卡组按 (name, parent_id) 唯一,重复导入同名卡组时直接忽略 */
export const SQL_INSERT_DECK: string =
  `INSERT OR IGNORE INTO decks (name, parent_id) VALUES (?, ?)`;

export const SQL_SELECT_DECK_ID: string =
  `SELECT id FROM decks WHERE name = ? AND parent_id = ?`;

export const SQL_INSERT_NOTE: string =
  `INSERT INTO notes (deck_id, type, front, back, title, source_file, fingerprint, uuid, updated_at)
   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`;

export const SQL_INSERT_CARD: string =
  `INSERT INTO cards (note_id, ordinal, uuid, updated_at) VALUES (?, ?, ?, ?)`;

export const SQL_COUNT_CARDS: string = `SELECT COUNT(*) AS n FROM cards`;

export const SQL_SELECT_NOTE_BY_CARD: string =
  `SELECT n.id, n.deck_id, n.type, n.front, n.back, n.title, n.source_file,
          n.fingerprint, n.uuid, n.updated_at, c.ordinal
     FROM cards c JOIN notes n ON n.id = c.note_id
    WHERE c.id = ?`;

/**
 * 生成 uuid。为将来同步预留,现阶段只要求「全局不重复」。
 *
 * 不用 @kit.ArkTS 的 util.generateRandomUUID,是为了让本文件保持纯逻辑
 * (桌面测试要能执行它)。时间戳 + 随机数对本地单机足够。
 */
export function makeUuid(prefix: string, now: number): string {
  const rand = Math.floor(Math.random() * 0x100000000).toString(16).padStart(8, '0');
  return `${prefix}-${now.toString(36)}-${rand}`;
}

/**
 * 卡片指纹:重复导入时用它认出「还是那张卡」并保住排期(Task 7)。
 *
 * 取 deck + 标题 + 序号 —— 正好对应 Quizify 强制「标题在文件内唯一且带小节限定」
 * 这条规则。正文改了错别字不影响指纹,所以改文件重导不会丢进度。
 */
export function fingerprintOf(deck: string, title: string, ordinal: number): string {
  const raw = `${deck}\u0000${title}\u0000${ordinal}`;
  // FNV-1a 32 位:够短、够散,且不依赖任何运行时库
  let h = 0x811c9dc5;
  for (let i = 0; i < raw.length; i++) {
    h ^= raw.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, '0');
}
