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
  /*
   * 卡组是**平的**:一本书一个卡组,没有层级。
   *
   * 早先这里有 parent_id,用来表达导入格式里的 `A::B`。实际用起来一本书就是
   * 一本书,层级只带来麻烦:父节点挂 0 张卡、在列表里被 `HAVING cards > 0`
   * 过滤掉、于是「选不中也删不掉」,而按卡组过滤又是精确匹配、不含子树,
   * 导致按章节导入之后**没法整本一起学**。整套概念删掉了。
   *
   * 旧库靠 Database.init() 里的拍平迁移升上来 —— `CREATE TABLE IF NOT EXISTS`
   * 不会改已存在的表,光改这里对老库没有任何作用。
   */
  `CREATE TABLE IF NOT EXISTS decks (
     id   INTEGER PRIMARY KEY AUTOINCREMENT,
     name TEXT    NOT NULL UNIQUE
   )`,

  `CREATE TABLE IF NOT EXISTS notes (
     id          INTEGER PRIMARY KEY AUTOINCREMENT,
     deck_id     INTEGER NOT NULL,
     type        INTEGER NOT NULL DEFAULT 0,
     front       TEXT    NOT NULL,
     back        TEXT    NOT NULL DEFAULT '',
     title       TEXT    NOT NULL DEFAULT '',
     -- 选择题的选项(每项一行)与答案字母。
     -- 单独存而不是留在 front 里,是因为 ;;;B 的收尾行本身就是答案,
     -- 留在正面等于把答案印在题面上。答案必须物理离开 front。
     options     TEXT    NOT NULL DEFAULT '',
     answer      TEXT    NOT NULL DEFAULT '',
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

/** 卡组按 name 唯一,重复导入同名卡组时直接忽略 */
/**
 * 老库检测:decks 还有没有 parent_id 这一列。列名必须叫 n(见 scalar)。
 */
export const SQL_HAS_PARENT_COL: string =
  `SELECT COUNT(*) AS n FROM pragma_table_info('decks') WHERE name = 'parent_id'`;

/**
 * 把带层级的 decks 拍平。**按顺序执行,外面要包事务。**
 *
 * 几个必须这么写的地方:
 *   - 新表**保留原来的 id**。notes.deck_id 指向它,换 id 就全体悬空。
 *   - 只搬「真的挂了笔记」的卡组。纯层级容器(父节点)本来就是 0 张卡,
 *     列表里被 HAVING 过滤掉、用户既看不见也删不掉,正好趁这次清掉。
 *     因为只丢没有笔记的卡组,不会有笔记变成孤儿。
 *   - 重名要兜底。`数学::高数` 和 `物理::高数` 拍平后都叫「高数」,
 *     而新表 name 是 UNIQUE,不处理会直接迁移失败。撞了就加 id 后缀。
 */
export const MIGRATE_FLATTEN_DECKS: string[] = [
  `CREATE TABLE IF NOT EXISTS decks_flat (
     id   INTEGER PRIMARY KEY AUTOINCREMENT,
     name TEXT    NOT NULL UNIQUE
   )`,
  `INSERT INTO decks_flat (id, name)
   SELECT d.id,
          CASE WHEN EXISTS (
                 SELECT 1 FROM decks o
                  WHERE o.name = d.name AND o.id <> d.id
                    AND EXISTS (SELECT 1 FROM notes n2 WHERE n2.deck_id = o.id))
               THEN d.name || ' (' || d.id || ')'
               ELSE d.name END
     FROM decks d
    WHERE EXISTS (SELECT 1 FROM notes n WHERE n.deck_id = d.id)`,
  `DROP TABLE decks`,
  `ALTER TABLE decks_flat RENAME TO decks`,
];

export const SQL_INSERT_DECK: string =
  `INSERT OR IGNORE INTO decks (name) VALUES (?)`;

export const SQL_SELECT_DECK_ID: string =
  `SELECT id FROM decks WHERE name = ?`;

export const SQL_INSERT_NOTE: string =
  `INSERT INTO notes (deck_id, type, front, back, title, options, answer,
                      source_file, fingerprint, uuid, updated_at)
   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`;

export const SQL_INSERT_CARD: string =
  `INSERT INTO cards (note_id, ordinal, uuid, updated_at) VALUES (?, ?, ?, ?)`;

export const SQL_COUNT_CARDS: string = `SELECT COUNT(*) AS n FROM cards`;

export const SQL_SELECT_NOTE_BY_CARD: string =
  `SELECT n.id AS note_id, n.type, n.front, n.back, n.title, n.options, n.answer,
          n.fingerprint, c.ordinal, d.name AS deck_name
     FROM cards c
     JOIN notes n ON n.id = c.note_id
     LEFT JOIN decks d ON d.id = n.deck_id
    WHERE c.id = ?`;

/** 某卡组下的卡片总数,用于首页显示 */
/**
 * 某个卡组的卡片总数。
 *
 * **notes 的别名不能叫 n。** 输出列按 scalar() 的约定必须叫 `n`,
 * 而这条语句原来把 notes 也别名成 n,两个 n 撞在一起 ——
 * 这条查询在接进「开始学习」按钮之前一直是死代码,所以没人发现。
 */
export const SQL_COUNT_CARDS_IN_DECK: string =
  `SELECT COUNT(*) AS n FROM cards c
     JOIN notes nt ON nt.id = c.note_id
    WHERE nt.deck_id = ?`;

// ---------------------------------------------------------------- 卡组一览

/**
 * 卡组一览:每组的卡片数、待复习数、新卡数。
 *
 * **每个卡组的计数必须各自独立** —— 这是 WordSnap 的教训,当年把额度存成
 * 全局 key,结果 A 书点一次「学习更多」,B 书也凭空多出额度。
 *
 * 只列出真正挂了卡片的卡组:`A::B` 会建出 A 与 B 两行,但卡片全挂在 B 上,
 * A 只是层级容器,列出来会让用户看到一堆 0 卡的空组。
 */
export const SQL_LIST_DECKS: string =
  `SELECT d.id, d.name,
          COUNT(c.id) AS cards,
          SUM(CASE WHEN s.card_id IS NOT NULL AND s.due <= ? THEN 1 ELSE 0 END) AS due,
          SUM(CASE WHEN s.card_id IS NULL THEN 1 ELSE 0 END) AS fresh
     FROM decks d
     JOIN notes n ON n.deck_id = d.id
     JOIN cards c ON c.note_id = n.id
     LEFT JOIN scheduling s ON s.card_id = c.id
    GROUP BY d.id
    HAVING cards > 0
    ORDER BY d.name ASC`;

/** 卡组名。卡组是平的,所以「路径」就是名字本身,一次查询搞定 */
export const SQL_SELECT_DECK_NAME: string =
  `SELECT name FROM decks WHERE id = ?`;

/** 按卡组取到期卡。deck_id = 0 时用 SQL_DUE_CARDS 取全部 */
// ------------------------------------------------------------ 今日已学回顾

/**
 * 今天答过的卡,最近答的在前 —— 「回顾今日已学」用。
 *
 * 取 `review_log` 里今天的最后一条,所以一张卡今天答了三次也只出现一次,
 * 并且带的是**最后一次**的评级。参数:今日起点、卡组(0 表示全部)、上限。
 */
export const SQL_REVIEWED_TODAY: string =
  `SELECT c.id AS card_id, n.id AS note_id, n.type, n.title, n.front, n.back,
          COALESCE(s.due, 0) AS due, COALESCE(s.reps, 0) AS reps,
          (SELECT r.grade FROM review_log r
            WHERE r.card_id = c.id AND r.ts >= ?
            ORDER BY r.ts DESC LIMIT 1) AS grade,
          (SELECT MAX(r.ts) FROM review_log r
            WHERE r.card_id = c.id AND r.ts >= ?) AS last_ts
     FROM cards c
     JOIN notes n ON n.id = c.note_id
     LEFT JOIN scheduling s ON s.card_id = c.id
    WHERE (? = 0 OR n.deck_id = ?)
      AND EXISTS (SELECT 1 FROM review_log r WHERE r.card_id = c.id AND r.ts >= ?)
    ORDER BY last_ts DESC
    LIMIT ?`;

// ------------------------------------------------------------ 今日集合的白色部分

/**
 * 今日集合里**今天还没答过**的旧卡数(三段条的白色部分之一)。
 *
 * 关键是 `s.last_review < ?`(今日起点)。早先这里用的是「当前到期」,
 * 于是一张答错的卡进了灰条,一分钟后又满足「当前到期」而被同时算进白条 ——
 * 结果灰条在涨、白条不降、总数还在飘。排除今天答过的卡,三色才是同一批卡的划分。
 *
 * 用 `due < 今日截止` 而不是 `due <= now`:下午才到期的卡也属于今天这一组,
 * 只是还轮不到它。这样一整天里总数是稳定的。
 *
 * 参数:今日截止、今日起点、卡组、卡组、复习上限。列名必须叫 n(见 scalar)。
 */
export const SQL_UNTOUCHED_DUE: string =
  `SELECT COUNT(*) AS n FROM (
     SELECT c.id FROM cards c
       JOIN notes nt ON nt.id = c.note_id
       JOIN scheduling s ON s.card_id = c.id
      WHERE s.due < ? AND s.last_review < ?
        AND (? = 0 OR nt.deck_id = ?)
      LIMIT ?)`;

/** 还没学过的卡(没有排期行)有多少张。列名必须叫 n */
export const SQL_UNLEARNED_COUNT: string =
  `SELECT COUNT(*) AS n FROM (
     SELECT c.id FROM cards c
       JOIN notes nt ON nt.id = c.note_id
       LEFT JOIN scheduling s ON s.card_id = c.id
      WHERE s.card_id IS NULL AND (? = 0 OR nt.deck_id = ?)
      LIMIT ?)`;

/**
 * 今天已经引入过的新卡数 —— 用 `first_seen` 判定。
 * 有了它,「每日新卡额度」才真的是**每天**的:剩余额度 = 额度 − 今天已引入。
 * 早先没有这个数,做完 20 张再开一轮又会给 20 张。
 */
export const SQL_NEW_INTRODUCED_TODAY: string =
  `SELECT COUNT(*) AS n FROM scheduling s
     JOIN cards c ON c.id = s.card_id
     JOIN notes nt ON nt.id = c.note_id
    WHERE s.first_seen >= ? AND (? = 0 OR nt.deck_id = ?)`;

// ------------------------------------------------------------ 今日进度三段条

/**
 * 今天答过的卡,按「今天还会不会再出现」分两段。
 *
 * 这是 WordSnap 的教训:按「上次答对没有」分段会骗人 —— 新卡答对之后还在
 * 10 分钟的学习步进里,今天还会回来,却被显示成「完成了」。
 * 所以分段依据是**下次到期时刻和今日截止的关系**,不是成绩。
 *
 * 参数顺序:今日截止、今日截止、今日起点、卡组、卡组 —— 全用无编号的 `?`。
 * **不要用 `?1`/`?2` 这种编号占位符**:node:sqlite 的桌面测试会直接报
 * 「column index out of range」,两个驱动对编号参数的处理并不一致。
 * 宁可把同一个值传两遍。
 */
export const SQL_TODAY_PROGRESS: string =
  `SELECT
     SUM(CASE WHEN s.due >= ? THEN 1 ELSE 0 END) AS settled,
     SUM(CASE WHEN s.due <  ? THEN 1 ELSE 0 END) AS again
   FROM scheduling s
   JOIN cards c ON c.id = s.card_id
   JOIN notes n ON n.id = c.note_id
   WHERE s.last_review >= ?
     AND (? = 0 OR n.deck_id = ?)`;

// ------------------------------------------------------------ 提前复习(学习更多)

/**
 * 「学习更多」要的卡:**还没到期,但快到期了**。
 *
 * `due > ?`(不是 >=)—— 已经到期的卡本来就在今日集合里,由正常流程出;
 * 这里只负责把未来的卡提前拿上来,两边不重叠。
 * 按 due 升序:最快该复习的先来,这样提前复习的收益最大、打扰最小。
 */
export const SQL_AHEAD_CARDS: string =
  `SELECT s.card_id FROM scheduling s
    WHERE s.due > ? AND s.due < ?
    ORDER BY s.due ASC LIMIT ?`;

export const SQL_AHEAD_CARDS_IN_DECK: string =
  `SELECT c.id AS card_id
     FROM cards c
     JOIN notes n ON n.id = c.note_id
     JOIN scheduling s ON s.card_id = c.id
    WHERE n.deck_id = ? AND s.due > ? AND s.due < ?
    ORDER BY s.due ASC LIMIT ?`;

export const SQL_DUE_CARDS_IN_DECK: string =
  `SELECT c.id AS card_id
     FROM cards c
     JOIN notes n ON n.id = c.note_id
     JOIN scheduling s ON s.card_id = c.id
    WHERE n.deck_id = ? AND s.due <= ?
    ORDER BY s.due ASC LIMIT ?`;

export const SQL_NEW_CARDS_IN_DECK: string =
  `SELECT c.id AS card_id
     FROM cards c
     JOIN notes n ON n.id = c.note_id
     LEFT JOIN scheduling s ON s.card_id = c.id
    WHERE n.deck_id = ? AND s.card_id IS NULL
    ORDER BY c.id ASC LIMIT ?`;

/** 删除一个卡组连同它的笔记、卡片、排期与流水 */
export const SQL_DELETE_DECK_LOGS: string =
  `DELETE FROM review_log WHERE card_id IN
     (SELECT c.id FROM cards c JOIN notes n ON n.id = c.note_id WHERE n.deck_id = ?)`;
export const SQL_DELETE_DECK_SCHED: string =
  `DELETE FROM scheduling WHERE card_id IN
     (SELECT c.id FROM cards c JOIN notes n ON n.id = c.note_id WHERE n.deck_id = ?)`;
export const SQL_DELETE_DECK_CARDS: string =
  `DELETE FROM cards WHERE note_id IN (SELECT id FROM notes WHERE deck_id = ?)`;
export const SQL_DELETE_DECK_NOTES: string = `DELETE FROM notes WHERE deck_id = ?`;
export const SQL_DELETE_DECK: string = `DELETE FROM decks WHERE id = ?`;

/**
 * 这个卡组下还剩几条笔记。
 * **列名必须叫 n** —— Database.scalar() 是按 `n` 取列的,换个别名就会
 * 报「column index is out of bounds」,而且报在运行时,编译期看不出来。
 */
export const SQL_DECK_NOTE_COUNT: string = `SELECT COUNT(*) AS n FROM notes WHERE deck_id = ?`;

// ------------------------------------------------------------ 卡组浏览与手工编辑

/**
 * 列出一个卡组里的卡片。`scheduling` 用 LEFT JOIN —— 没学过的卡没有排期行,
 * INNER JOIN 会把它们整批漏掉。
 */
export const SQL_LIST_CARDS_IN_DECK: string =
  `SELECT c.id AS card_id, n.id AS note_id, n.type, n.title, n.front, n.back,
          COALESCE(s.due, 0) AS due, COALESCE(s.reps, 0) AS reps
     FROM cards c
     JOIN notes n ON n.id = c.note_id
     LEFT JOIN scheduling s ON s.card_id = c.id
    WHERE n.deck_id = ?
    ORDER BY n.id, c.ordinal`;

/** 同上,但跨全部卡组 —— 「浏览全部卡片」用 */
export const SQL_LIST_CARDS_ALL: string =
  `SELECT c.id AS card_id, n.id AS note_id, n.type, n.title, n.front, n.back,
          COALESCE(s.due, 0) AS due, COALESCE(s.reps, 0) AS reps
     FROM cards c
     JOIN notes n ON n.id = c.note_id
     LEFT JOIN scheduling s ON s.card_id = c.id
    ORDER BY n.deck_id, n.id, c.ordinal`;

/**
 * 改写一条笔记的正反面。题型 / 标题 / 选项 / 答案都要一起更新 ——
 * 用户把 `;;;` 删掉之后,这张卡就不该再是选择题了。
 * 指纹不动:那是「还是那张卡」的身份,内容改了身份不变,否则重导会变成新卡。
 */
export const SQL_UPDATE_NOTE_TEXT: string =
  `UPDATE notes SET type = ?, front = ?, back = ?, title = ?, options = ?, answer = ?,
          updated_at = ? WHERE id = ?`;

/** 删一条笔记要先删子表 —— 本库没有开外键级联 */
export const SQL_DELETE_NOTE_LOGS: string =
  `DELETE FROM review_log WHERE card_id IN (SELECT id FROM cards WHERE note_id = ?)`;
export const SQL_DELETE_NOTE_SCHED: string =
  `DELETE FROM scheduling WHERE card_id IN (SELECT id FROM cards WHERE note_id = ?)`;
export const SQL_DELETE_NOTE_CARDS: string = `DELETE FROM cards WHERE note_id = ?`;
export const SQL_DELETE_NOTE: string = `DELETE FROM notes WHERE id = ?`;

// ---------------------------------------------------------------- 统计

/**
 * 按天聚合的复习量,供热力图使用。
 *
 * 分桶用的是**本地日序号**(dayIndex 的口径,凌晨 1 点分界),
 * 所以不能直接在 SQL 里按 UTC 除法分桶 —— 时区与 1 小时偏移都会错位。
 * 这里只把原始 (ts, grade) 取出来,分桶交给 dayIndex() 在 ArkTS 侧做,
 * 保证与界面上其他地方的「今天」是同一个定义。
 */
export const SQL_LOG_SINCE: string =
  `SELECT ts, grade, card_id FROM review_log WHERE ts >= ? ORDER BY ts ASC`;

/** 未来若干天的到期量预测 */
export const SQL_DUE_FORECAST: string =
  `SELECT due FROM scheduling WHERE due > ? AND due <= ? ORDER BY due ASC`;

/**
 * 稳定性分布,用于「掌握度」直方图。
 *
 * **必须 LEFT JOIN 从 cards 出发,不能只查 scheduling。** 没答过的卡没有
 * scheduling 行,只查 scheduling 会把它们整批漏掉,于是「未学」永远是 0,
 * 而各档之和也对不上卡片总数 —— WordSnap 当年就栽在这种分子分母不一致上
 * (统计页显示「已学 91 / 3732」,分子含了分母不含的那批)。
 * COALESCE 让没答过的卡以 stability = 0 出现,masteryOf(0) 正好归到「未学」。
 */
export const SQL_STABILITY_HISTOGRAM: string =
  `SELECT COALESCE(s.stability, 0) AS stability
     FROM cards c LEFT JOIN scheduling s ON s.card_id = c.id`;

/** 按天汇总的一行 */
export interface DayStat {
  /** 与 dayIndex() 同义的天序号 */
  day: number;
  /** 这天作答多少次 */
  reps: number;
  /** 这天累计花了多少毫秒 */
  ms: number;
}

/**
 * SQL_DAY_STATS 要用的锚点:时区偏移 + 凌晨分界。
 * 把它单独拎出来,是为了让 SQL 里的 day 和 dayIndex() 共用同一个定义。
 */
export function dayAnchor(now: number): number {
  const d = new Date(now);
  return d.getTimezoneOffset() * MIN_MS + DAY_CUTOFF_MS;
}

/**
 * 按天汇总的全部历史:每天作答多少次、花了多少毫秒。
 *
 * 为什么不在 TS 里分桶:总作答、学习天数、连续天数都要**全量**口径,
 * 全量分桶就得把整张 review_log 读进内存。按天聚合之后一天只回一行,
 * 十年也就三千多行。
 *
 * **日界口径不在这条 SQL 里重新定义。** `?` 收的是 TS 算好的锚点
 * (时区偏移 + 凌晨分界),SQL 只做一次减法和除法,所以 day 的含义与
 * dayIndex() 完全一致 —— 两处各写一套日界逻辑迟早会对不上。
 *
 * 整数除法在 SQLite 里是向零截断、不是向下取整,但 ts 减锚点后恒为正
 * (epoch 毫秒 ~1.7e12),截断与取整等价。
 */
export const SQL_DAY_STATS: string =
  `SELECT CAST((ts - ?) / 86400000 AS INTEGER) AS day,
          COUNT(*) AS reps,
          SUM(cost_ms) AS ms
     FROM review_log
    GROUP BY day
    ORDER BY day ASC`;

/**
 * 全量保持率:答对(评级 >= 良好)占**除首答以外**全部作答的比例。
 *
 * 排除每张卡的第一次作答,和 retentionOf() 是同一条规则 ——
 * 新卡首答必然「不会」,算进去只会让保持率恒偏低。
 *
 * 用 MIN(id) 而不是 MIN(ts) 找首答:同一毫秒内的两条流水 ts 会相等,
 * 按 ts 比较会把它们**一起**排除掉。id 自增,不会撞。
 */
export const SQL_RETENTION_ALL: string =
  `SELECT COUNT(*) AS total,
          SUM(CASE WHEN grade >= 2 THEN 1 ELSE 0 END) AS good
     FROM review_log r
    WHERE r.id > (SELECT MIN(r2.id) FROM review_log r2 WHERE r2.card_id = r.card_id)`;

/**
 * 未来到期量预测,限定卡组。deckId 传 0 表示不限。
 * 过滤写法与学习页一致(精确匹配 deck_id,不含子卡组),
 * 这样统计页和学习页给出的数字不会互相打脸。
 */
export const SQL_DUE_FORECAST_IN_DECK: string =
  `SELECT s.due AS due
     FROM scheduling s
     JOIN cards c ON c.id = s.card_id
     JOIN notes n ON n.id = c.note_id
    WHERE s.due > ? AND s.due <= ? AND (? = 0 OR n.deck_id = ?)
    ORDER BY s.due ASC`;

/**
 * 稳定性分布,限定卡组。deckId 传 0 表示不限。
 * 和 SQL_STABILITY_HISTOGRAM 一样**从 cards 出发 LEFT JOIN**,
 * 否则没答过的卡会整批消失,「未学」永远是 0。
 */
export const SQL_STABILITY_IN_DECK: string =
  `SELECT COALESCE(s.stability, 0) AS stability
     FROM cards c
     JOIN notes n ON n.id = c.note_id
     LEFT JOIN scheduling s ON s.card_id = c.id
    WHERE (? = 0 OR n.deck_id = ?)`;

/** 按指纹找已有笔记(Task 7 幂等重导用) */
export const SQL_SELECT_NOTE_BY_FINGERPRINT: string =
  `SELECT id FROM notes WHERE fingerprint = ?`;

/** 今日待学总量:到期卡数 + 新卡数,分两条查免得一条 SQL 里塞两种语义 */
export const SQL_COUNT_DUE: string =
  `SELECT COUNT(*) AS n FROM scheduling WHERE due <= ?`;

export const SQL_COUNT_NEW: string =
  `SELECT COUNT(*) AS n FROM cards c
     LEFT JOIN scheduling s ON s.card_id = c.id
    WHERE s.card_id IS NULL`;

/** 卡组一览里的一行 */
export interface DeckRow {
  id: number;
  name: string;
  cards: number;
  due: number;
  fresh: number;
}

/**
 * 卡组浏览列表的一行。front / back 是原文,截断交给界面 ——
 * 数据层不做展示决定。
 */
/**
 * 今日进度的三段。三个数加起来就是「今天这一组有多大」。
 * settled 绿 —— 今天不会再出现;again 灰 —— 今天还会回来;untouched 白 —— 还没碰过。
 */
export interface TodayProgress {
  settled: number;
  again: number;
  untouched: number;
}

/** 今日已学的一张卡。grade 是今天最后一次的评级 */
export interface ReviewedCard {
  cardId: number;
  title: string;
  front: string;
  grade: number;
  lastTs: number;
}

export interface CardBrief {
  cardId: number;
  noteId: number;
  type: number;
  title: string;
  front: string;
  back: string;
  /** 下次到期毫秒。0 表示从没学过 */
  due: number;
  /** 复习次数。0 表示新卡 */
  reps: number;
}

/** 一条复习流水,热力图与保持率都由它聚合 */
export interface LogPoint {
  ts: number;
  grade: number;
  cardId: number;
}

/** 热力图的一格 */
export interface DayBucket {
  /** 本地日序号 */
  day: number;
  /** 当天的作答次数 */
  reps: number;
  /** 当天答对(grade >= 2)的次数 */
  good: number;
}

/**
 * 把复习流水按**本地日序号**分桶。
 *
 * 为什么不在 SQL 里除法分桶:日界是凌晨 1 点且要按本地时区,
 * SQL 里按 UTC 毫秒除以 86400000 会同时错在时区和那 1 小时上,
 * 于是「今天」在热力图和在首页是两个不同的日子。分桶必须走 dayIndex()。
 */
export function bucketByDay(points: LogPoint[]): DayBucket[] {
  const map = new Map<number, DayBucket>();
  for (const p of points) {
    const d = dayIndex(p.ts);
    const b = map.get(d);
    if (b === undefined) {
      map.set(d, { day: d, reps: 1, good: p.grade >= 2 ? 1 : 0 });
    } else {
      b.reps++;
      if (p.grade >= 2) {
        b.good++;
      }
    }
  }
  const out: DayBucket[] = [];
  map.forEach((v: DayBucket) => out.push(v));
  out.sort((a: DayBucket, b: DayBucket) => a.day - b.day);
  return out;
}

/**
 * 保持率 = 答对次数 / 总作答次数,只算**复习**不算新卡首答。
 *
 * 新卡的第一次作答不该计入保持率:那时候还没有任何记忆可供「保持」,
 * 把它算进去会让数字被新卡量左右,失去意义。
 * 这里靠「该卡在此之前是否出现过」来判断。
 */
export function retentionOf(points: LogPoint[]): number {
  const seen = new Set<number>();
  let total = 0;
  let good = 0;
  for (const p of points) {
    if (seen.has(p.cardId)) {
      total++;
      if (p.grade >= 2) {
        good++;
      }
    }
    seen.add(p.cardId);
  }
  return total === 0 ? 0 : good / total;
}

/**
 * 复习界面需要的一整张卡(笔记内容 + 卡片序号)。
 * 字段名与 SQL_SELECT_NOTE_BY_CARD 的列名一致,便于逐列核对。
 */
export interface ReviewCardRow {
  note_id: number;
  type: number;
  front: string;
  back: string;
  title: string;
  /** 选项原文,存的时候用 \n 连接 */
  options: string;
  answer: string;
  fingerprint: string;
  ordinal: number;
  deck_name: string;
}

/** 选项在库里以换行连接,取出时拆回数组。空串拆出空数组,不要拆出 [''] */
export function splitOptions(joined: string): string[] {
  if (joined.length === 0) {
    return [];
  }
  const out: string[] = [];
  for (const one of joined.split('\n')) {
    if (one.trim().length > 0) {
      out.push(one);
    }
  }
  return out;
}

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
