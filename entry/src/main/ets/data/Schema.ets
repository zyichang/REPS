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
 * 一天的分界是**凌晨 3 点**,不是午夜(2026-10-14 起;原为 1 点)。
 *
 * 排期算出来的到期时刻带小时分钟(2.56 天后 = 次日 00:26)。按午夜切,
 * 深夜还在学的人刚过 0 点就会看到一批「明天的卡」冒出来。
 * 打卡也按这个分界:10/15 02:59 打卡算 10/14,03:01 才算 10/15。
 * **全应用只有这一个日界** —— 打卡单独用 3 点、其余用 1 点的话,凌晨 2 点
 * 「今日」卡片已经显示新一天的待学,打卡却还记在前一天。(Anki 默认是 4 点。)
 *
 * 注意:这个分界只决定「一张卡属于哪一天」以及「今日集合怎么组成」。
 * **取卡条件仍然是 due <= now**。如果把分界也用到取卡上,
 * 5 分钟 / 30 分钟的学习步进卡会全部立刻到期,学习流水线就没了。
 */
export const DAY_CUTOFF_HOUR: number = 3;
export const DAY_CUTOFF_MS: number = DAY_CUTOFF_HOUR * 60 * MIN_MS;

/**
 * 本地日序号(以本地时区把毫秒归到「天」)。
 *
 * 减去 DAY_CUTOFF_MS 之后再取整:这样 00:00~03:00 会落回前一天,
 * 「一天」实际是 03:00 → 次日 03:00。
 */
export function dayIndex(ms: number): number {
  const d = new Date(ms);
  const local = ms - d.getTimezoneOffset() * MIN_MS - DAY_CUTOFF_MS;
  return Math.floor(local / DAY_MS);
}

/**
 * 日序号 -> 当天的分界时刻(即当天凌晨 3 点)毫秒。dayIndex 的逆。
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
     algo             TEXT    NOT NULL DEFAULT 'fsrs',
     archived         INTEGER NOT NULL DEFAULT 0
   )`,

  // 队列查询是「按 due 取到期卡」,没有这个索引会全表扫
  `CREATE INDEX IF NOT EXISTS idx_sched_due ON scheduling(due)`,
  `CREATE INDEX IF NOT EXISTS idx_cards_note ON cards(note_id)`,
  `CREATE INDEX IF NOT EXISTS idx_notes_deck ON notes(deck_id)`,
  // 统计页按卡查历史、按时间查每日量,两个方向都要
  `CREATE INDEX IF NOT EXISTS idx_log_card ON review_log(card_id)`,
  `CREATE INDEX IF NOT EXISTS idx_log_ts ON review_log(ts)`,

  // 打卡:一天一行,day 是 dayIndex() 的日序号(凌晨 3 点分界)。**永不删除,不能撤销**
  `CREATE TABLE IF NOT EXISTS checkins (
     day INTEGER PRIMARY KEY,
     ts  INTEGER NOT NULL
   )`,

  // 一次性迁移的标记(key = 迁移名)。不用 preferences:迁移和数据在同一个库里才不会对不上
  `CREATE TABLE IF NOT EXISTS meta (
     key   TEXT PRIMARY KEY,
     value TEXT NOT NULL DEFAULT ''
   )`,
];

// ---------------------------------------------------------------- 打卡

/** 打卡。同一天重复打卡什么都不做(INSERT OR IGNORE),第一次的时刻保留 */
export const SQL_INSERT_CHECKIN: string = `INSERT OR IGNORE INTO checkins (day, ts) VALUES (?, ?)`;
/** 某一天打过卡没有。列名必须叫 n */
export const SQL_IS_CHECKED_IN: string = `SELECT COUNT(*) AS n FROM checkins WHERE day = ?`;
/** 全部打卡日,升序 */
export const SQL_CHECKIN_DAYS: string = `SELECT day FROM checkins ORDER BY day ASC`;

/**
 * 一次性回填:打卡功能上线之前,**有作答的日子一律算打过卡**,
 * 否则老用户的「学习天数」会从 0 重新数。
 * 参数是 dayAnchor(now)(与 SQL_DAY_STATS 同一个日界口径)。由 meta 里的标记保证只跑一次。
 */
export const MIGRATE_BACKFILL_CHECKINS: string =
  `INSERT OR IGNORE INTO checkins (day, ts)
     SELECT CAST((ts - ?) / 86400000 AS INTEGER) AS day, MIN(ts)
       FROM review_log
      GROUP BY day`;
export const META_BACKFILL_CHECKINS: string = 'backfill_checkins_v1';
export const SQL_META_GET: string = `SELECT COUNT(*) AS n FROM meta WHERE key = ?`;
export const SQL_META_SET: string = `INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)`;

/**
 * 连续打卡天数。规则(用户定的):**漏一天不算中断,连漏两天才断。**
 *
 * 从今天往回数,数的是链上**打过卡的天数**(周一 ✓、周二 ✗、周三 ✓ = 2)。
 * 今天还没打卡不算「漏」—— 今天还没过完;从昨天开始数漏的天。
 * days 是打卡日序号(任意顺序)。
 */
export function checkinStreak(days: number[], today: number): number {
  const has = new Set<number>(days);
  let earliest: number = today;
  for (const x of days) {
    if (x < earliest) {
      earliest = x;
    }
  }
  let count = 0;
  let missed = 0;
  // 今天没打卡 = 今天还没过完,不算漏;从昨天开始数
  for (let d = has.has(today) ? today : today - 1; d >= earliest; d--) {
    if (has.has(d)) {
      count++;
      missed = 0;
    } else {
      missed++;
      if (missed >= 2) {
        break;
      }
    }
  }
  return count;
}

/**
 * 打卡月历的格子:从「这个月 1 号所在那一周的周日」开始,到「最后一天所在那一周的周六」,
 * 所以首尾会带上相邻月份的几天(例如 27 28 29 30 | 1 2 3)。
 * 返回每格的日序号;界面再用 calendarDate() 取「几号、是不是本月」。month0 是 0~11。
 */
export function calendarCells(year: number, month0: number): number[] {
  const first: number = dayIndex(new Date(year, month0, 1, 12, 0, 0).getTime());
  const last: number = dayIndex(new Date(year, month0 + 1, 0, 12, 0, 0).getTime());
  const start: number = first - weekdaySun0(first);
  const end: number = last + (6 - weekdaySun0(last));
  const out: number[] = [];
  for (let d = start; d <= end; d++) {
    out.push(d);
  }
  return out;
}

/** 日序号 -> 本地日历上的 年 / 月(0~11)/ 日。取当天中午,远离日界与夏令时切换 */
export function calendarDate(day: number): number[] {
  const t: Date = new Date(dayStart(day) + 9 * 3600 * 1000);
  return [t.getFullYear(), t.getMonth(), t.getDate()];
}

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

/**
 * 写完排期后打同步时间戳(schema v2)。INSERT OR REPLACE 会把整行换掉,
 * updated_at 不在 SCHED_COLUMNS 里所以会回到默认 0 —— 必须紧跟着这一句。
 * 用 last_review 而不是墙钟:它就是这次改动发生的时刻。
 */
export const SQL_TOUCH_SCHEDULING: string =
  `UPDATE scheduling SET updated_at = last_review WHERE card_id = ?`;

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
/**
 * review_log 有没有 archived 列。旧库靠 Database.init() 里的 ALTER 补上 ——
 * `CREATE TABLE IF NOT EXISTS` 对已存在的表不起作用。
 *
 * **复习流水永不删除**(ADR-0005):删牌组、删卡片都不删流水,综合统计
 * (总作答、热力图、学习时长、连续天数、保持率)按整个应用算,与牌组是否还在无关。
 * 「清空进度」只把该组的流水标成 archived = 1:综合统计照算,
 * 这个牌组自己的「今日已学」等视图不再看它们。
 */
export const SQL_HAS_ARCHIVED_COL: string =
  `SELECT COUNT(*) AS n FROM pragma_table_info('review_log') WHERE name = 'archived'`;
export const MIGRATE_ADD_ARCHIVED: string =
  `ALTER TABLE review_log ADD COLUMN archived INTEGER NOT NULL DEFAULT 0`;

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

/**
 * 新建牌组之后补上 uuid 与时刻。**只填空的** —— 已有 uuid 是牌组的固定身份,永不覆盖。
 * 参数:(uuid, now, name)。uuid 由 Database 层用 util.generateRandomUUID 生成。
 */
export const SQL_FILL_DECK_UUID: string =
  `UPDATE decks SET uuid = ?, updated_at = ? WHERE name = ? AND uuid = ''`;

// ---------------------------------------------------------------- 版本化迁移

/**
 * 当前 schema 版本,记在 SQLite 的 `PRAGMA user_version`(relationalStore 里是 RdbStore.version)。
 *
 * 规则:DDL 永远是 v1 基线(`CREATE TABLE IF NOT EXISTS` 对老库无效,所以不在 DDL 里加列);
 * 之后的每次改表都是 MIGRATIONS 里的一项。老库和新库走同一条路:DDL → 旧的按列迁移 → MIGRATIONS。
 * v2 之前的迁移(拍平 decks、补 archived、回填打卡)靠「列在不在」判断,保持原样。
 */
export const SCHEMA_VERSION: number = 3;

export interface Migration {
  /** 跑完之后 user_version 设成它 */
  version: number;
  /** 按顺序执行,外面包一个事务 */
  statements: string[];
}

/** SQLite 里生成 v4 uuid(老牌组补身份用)。每行求值一次 */
const SQL_RANDOM_UUID: string =
  `lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' ||
   substr(lower(hex(randomblob(2))), 2) || '-' ||
   substr('89ab', 1 + (abs(random()) % 4), 1) || substr(lower(hex(randomblob(2))), 2) || '-' ||
   lower(hex(randomblob(6)))`;

export const MIGRATIONS: Migration[] = [
  {
    // v2(docs/data-model.md):牌组身份、内容哈希、删除标记、标签、排期时间戳
    version: 2,
    statements: [
      `ALTER TABLE decks ADD COLUMN uuid TEXT NOT NULL DEFAULT ''`,
      `ALTER TABLE decks ADD COLUMN version INTEGER NOT NULL DEFAULT 0`,
      // YAML meta 块(作者、许可证、来源…),JSON 文本;导出时原样写回
      `ALTER TABLE decks ADD COLUMN meta TEXT NOT NULL DEFAULT ''`,
      `ALTER TABLE decks ADD COLUMN tags TEXT NOT NULL DEFAULT '[]'`,
      `ALTER TABLE decks ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0`,
      // 删除标记(墓碑):0 = 没删。云同步确认之后才真删,否则另一台设备会把它传回来
      `ALTER TABLE decks ADD COLUMN deleted_at INTEGER NOT NULL DEFAULT 0`,
      `UPDATE decks SET uuid = ${SQL_RANDOM_UUID} WHERE uuid = ''`,
      `UPDATE decks SET updated_at = COALESCE(
         (SELECT MAX(n.updated_at) FROM notes n WHERE n.deck_id = decks.id), 0)`,
      // 部分唯一索引:刚 INSERT 还没补 uuid 的那一瞬间是 '',不能互相撞
      `CREATE UNIQUE INDEX IF NOT EXISTS idx_decks_uuid ON decks(uuid) WHERE uuid <> ''`,

      // front + back + options + answer 的哈希。'' = 还没算过,Task 4 导入时补
      `ALTER TABLE notes ADD COLUMN content_hash TEXT NOT NULL DEFAULT ''`,
      `ALTER TABLE notes ADD COLUMN tags TEXT NOT NULL DEFAULT '[]'`,
      `ALTER TABLE notes ADD COLUMN deleted_at INTEGER NOT NULL DEFAULT 0`,

      // 同步只传 updated_at 新于上次同步的行
      `ALTER TABLE scheduling ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0`,
      `UPDATE scheduling SET updated_at = last_review WHERE updated_at = 0`,
    ],
  },
  {
    // v3(ADR-0006 方案 A):**其他设备**的每日汇总在本机的缓存。本机自己的汇总从不存表 ——
    // 它永远从 review_log 现算(SQL_DAY_STATS),否则就是同一个数的第二个口径(ADR-0005)。
    version: 3,
    statements: [
      `CREATE TABLE IF NOT EXISTS remote_day_stats (
         device_id TEXT    NOT NULL,
         day       INTEGER NOT NULL,
         reps      INTEGER NOT NULL DEFAULT 0,
         ms        INTEGER NOT NULL DEFAULT 0,
         PRIMARY KEY (device_id, day)
       )`,
      // 删除墓碑(Task 8):本地删牌组 / 删卡照旧是真删,另记一行墓碑交给同步传到其他设备。
      // 不用 decks/notes.deleted_at 软删除 —— 那要给几十条读查询都加过滤,而墓碑只碰删除和同步两处。
      `CREATE TABLE IF NOT EXISTS sync_tombstones (
         kind       TEXT    NOT NULL,
         uuid       TEXT    NOT NULL,
         deleted_at INTEGER NOT NULL,
         PRIMARY KEY (kind, uuid)
       )`,
    ],
  },
];

/** 从当前版本出发还要跑哪些迁移,按版本升序 */
export function pendingMigrations(current: number): Migration[] {
  return MIGRATIONS.filter((m: Migration) => m.version > current)
    .sort((a: Migration, b: Migration) => a.version - b.version);
}

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
            WHERE r.card_id = c.id AND r.ts >= ? AND r.archived = 0
            ORDER BY r.ts DESC LIMIT 1) AS grade,
          (SELECT MAX(r.ts) FROM review_log r
            WHERE r.card_id = c.id AND r.ts >= ? AND r.archived = 0) AS last_ts
     FROM cards c
     JOIN notes n ON n.id = c.note_id
     LEFT JOIN scheduling s ON s.card_id = c.id
    WHERE (? = 0 OR n.deck_id = ?)
      AND EXISTS (SELECT 1 FROM review_log r
                   WHERE r.card_id = c.id AND r.ts >= ? AND r.archived = 0)
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
 * 某个卡组(0 表示全部)此刻到期的卡有多少张。列名必须叫 n。
 * 只为了显示一个数字,不要用 dueCardIdsInDeck(…, 100000).length ——
 * 那会把十万个 id 读进内存再丢掉。
 */
export const SQL_COUNT_DUE_IN_DECK: string =
  `SELECT COUNT(*) AS n FROM cards c
     JOIN notes nt ON nt.id = c.note_id
     JOIN scheduling s ON s.card_id = c.id
    WHERE s.due <= ? AND (? = 0 OR nt.deck_id = ?)`;

/** 某个卡组(0 表示全部)还没学过的卡有多少张,不设上限。列名必须叫 n */
export const SQL_COUNT_NEW_IN_DECK: string =
  `SELECT COUNT(*) AS n FROM cards c
     JOIN notes nt ON nt.id = c.note_id
     LEFT JOIN scheduling s ON s.card_id = c.id
    WHERE s.card_id IS NULL AND (? = 0 OR nt.deck_id = ?)`;

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

/**
 * 删除一个卡组连同它的笔记、卡片、排期。**复习流水不删**(ADR-0005)——
 * 学过的时间和打卡是真实发生过的,综合统计要一直算进去。
 * 卡片 id 是 AUTOINCREMENT,永不复用,所以留下的流水不会被新卡「认领」。
 *
 * 「清空进度」用 SQL_ARCHIVE_DECK_LOGS:把流水标成已归档,而不是删掉。
 */
export const SQL_ARCHIVE_DECK_LOGS: string =
  `UPDATE review_log SET archived = 1 WHERE card_id IN
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

/** 删一条笔记要先删子表 —— 本库没有开外键级联。复习流水保留(ADR-0005) */
export const SQL_DELETE_NOTE_SCHED: string =
  `DELETE FROM scheduling WHERE card_id IN (SELECT id FROM cards WHERE note_id = ?)`;
export const SQL_DELETE_NOTE_CARDS: string = `DELETE FROM cards WHERE note_id = ?`;
export const SQL_DELETE_NOTE: string = `DELETE FROM notes WHERE id = ?`;

// ---------------------------------------------------------------- 统计

/**
 * 按天聚合的复习量,供热力图使用。
 *
 * 分桶用的是**本地日序号**(dayIndex 的口径,凌晨 3 点分界),
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
 * 某个日序号是星期几,**周日 = 0 … 周六 = 6**(全应用的周都从周日开始:
 * 热力图的行、打卡月历的列)。取 dayStart(day) 那一刻(本地 03:00)的星期,
 * 日界口径与 dayIndex() 一致。
 */
export function weekdaySun0(day: number): number {
  return new Date(dayStart(day)).getDay();
}

/**
 * 热力图第一格(左上角)的日序号。
 *
 * **网格必须按星期对齐**:行是 周日…周六,最后一列是本周,今天落在本周那一列
 * 自己星期的那一行,今天之后的格子留空。早先的写法是「从今天往前数 weeks*7-1 天」
 * 再按 7 个一列摆,于是今天总落在最后一列的最后一行(周日)——
 * 周三学的显示成周日,整张图错位,上周日的 8 分钟跑到了别的格子里。
 */
export function heatFirstDay(today: number, weeks: number): number {
  return today - weekdaySun0(today) - (weeks - 1) * 7;
}

/**
 * 热力图的格子:按列(周)主序,每列 7 格(周日…周六)。
 * 值是作答次数;**今天之后的格子是 -1**,界面画成透明,不算「没学」。
 */
export function heatCells(today: number, weeks: number, repsOf: (day: number) => number): number[] {
  const first: number = heatFirstDay(today, weeks);
  const out: number[] = [];
  for (let i = 0; i < weeks * 7; i++) {
    const day: number = first + i;
    out.push(day > today ? -1 : repsOf(day));
  }
  return out;
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

// ---------------------------------------------------------------- 每日汇总投影(Task 7,ADR-0006 方案 A)

/** 云端 daily_stat 的一行:某台设备某一天的作答数与时长 */
export interface DailyStatRow {
  deviceId: string;
  day: number;
  reps: number;
  ms: number;
}

/**
 * 本机的每日汇总 -> 要上传的 daily_stat 行。只取 sinceDay 及以后的天:
 * review_log 只增不删、新流水的 ts 总是「现在」,所以上次同步那天之前的汇总不会再变,不必重传。
 * sinceDay 传 -Infinity 就是全量(第一次同步)。
 */
export function projectDailyStats(stats: DayStat[], deviceId: string, sinceDay: number): DailyStatRow[] {
  const out: DailyStatRow[] = [];
  for (const s of stats) {
    if (s.day >= sinceDay) {
      out.push({ deviceId: deviceId, day: s.day, reps: s.reps, ms: s.ms });
    }
  }
  return out;
}

/**
 * 本机现算的汇总 + 其他设备的 daily_stat -> 热力图、学习时长用的汇总(按天相加,升序)。
 * remote 里本机自己的行一律忽略 —— 本机的数只认 review_log(否则会把自己算两遍)。
 */
export function mergeDayStats(local: DayStat[], remote: DailyStatRow[], selfDevice: string): DayStat[] {
  const byDay = new Map<number, DayStat>();
  for (const s of local) {
    byDay.set(s.day, { day: s.day, reps: s.reps, ms: s.ms });
  }
  for (const r of remote) {
    if (r.deviceId === selfDevice) {
      continue;
    }
    const cur: DayStat | undefined = byDay.get(r.day);
    if (cur === undefined) {
      byDay.set(r.day, { day: r.day, reps: r.reps, ms: r.ms });
    } else {
      cur.reps += r.reps;
      cur.ms += r.ms;
    }
  }
  const out: DayStat[] = Array.from(byDay.values());
  out.sort((a: DayStat, b: DayStat) => a.day - b.day);
  return out;
}

/** 其他设备的每日汇总(本机缓存) */
export const SQL_REMOTE_DAY_STATS: string = `SELECT device_id, day, reps, ms FROM remote_day_stats`;

/** 同步下载后写进缓存:同一设备同一天整行覆盖(那台设备当天又学了,数会变大) */
export const SQL_UPSERT_REMOTE_DAY_STAT: string =
  `INSERT OR REPLACE INTO remote_day_stats (device_id, day, reps, ms) VALUES (?, ?, ?, ?)`;

/** meta 里存本机设备 id 的键。随机 uuid,不用硬件标识(ADR-0006) */
export const META_DEVICE_ID: string = 'device_id';
export const SQL_META_VALUE: string = `SELECT value FROM meta WHERE key = ?`;

// ---------------------------------------------------------------- 删除墓碑(Task 8)

/**
 * 卡片的**同步键** = `牌组uuid/文件里的 id`(与导出 YAML 一致)。
 *
 * 不能直接用 notes.uuid:Task 4 之前导入的卡 notes.uuid 是随机 uuid(没有牌组前缀),
 * 而另一台设备从导出的 YAML 导入后存的是 `牌组uuid/那个 uuid` —— 同一张卡两边不一样。
 * 取「导出时写进文件的 id」再加牌组前缀,两台设备就对得上。与 YamlExport.cardIdOf 同一规则。
 */
export function cardSyncKey(deckUuid: string, noteUuid: string): string {
  const prefix = `${deckUuid}/`;
  return noteUuid.startsWith(prefix) ? noteUuid : prefix + noteUuid;
}

/** 同步键拆回 [牌组 uuid, 文件里的 id]。牌组 uuid 本身不含 / */
export function splitCardSyncKey(key: string): string[] {
  const i = key.indexOf('/');
  return i < 0 ? ['', key] : [key.substring(0, i), key.substring(i + 1)];
}

/**
 * 本地删除照旧是真删;**在删之前**记下墓碑,同步时作为 deleted = true 的记录传给其他设备。
 * 卡片的墓碑表示「这张卡没有排期了」:删卡、删牌组、清空进度三种情况都记。
 * 参数一律 (now, id)。
 */
export const SQL_TOMBSTONE_DECK: string =
  `INSERT OR REPLACE INTO sync_tombstones (kind, uuid, deleted_at)
   SELECT 'deck', uuid, ? FROM decks WHERE id = ? AND uuid <> ''`;
export const SQL_TOMBSTONE_DECK_CARDS: string =
  `INSERT OR REPLACE INTO sync_tombstones (kind, uuid, deleted_at)
   SELECT 'card', d.uuid || '/' || (CASE WHEN substr(n.uuid, 1, length(d.uuid) + 1) = d.uuid || '/'
                         THEN substr(n.uuid, length(d.uuid) + 2) ELSE n.uuid END), ?
     FROM notes n JOIN decks d ON d.id = n.deck_id WHERE n.deck_id = ?`;
export const SQL_TOMBSTONE_NOTE_CARDS: string =
  `INSERT OR REPLACE INTO sync_tombstones (kind, uuid, deleted_at)
   SELECT 'card', d.uuid || '/' || (CASE WHEN substr(n.uuid, 1, length(d.uuid) + 1) = d.uuid || '/'
                         THEN substr(n.uuid, length(d.uuid) + 2) ELSE n.uuid END), ?
     FROM notes n JOIN decks d ON d.id = n.deck_id WHERE n.id = ?`;
/** 清空进度只给**有排期**的卡记墓碑(新卡本来就没有排期,不用传) */
export const SQL_TOMBSTONE_DECK_SCHED: string =
  `INSERT OR REPLACE INTO sync_tombstones (kind, uuid, deleted_at)
   SELECT 'card', d.uuid || '/' || (CASE WHEN substr(n.uuid, 1, length(d.uuid) + 1) = d.uuid || '/'
                         THEN substr(n.uuid, length(d.uuid) + 2) ELSE n.uuid END), ?
     FROM scheduling s JOIN cards c ON c.id = s.card_id JOIN notes n ON n.id = c.note_id
     JOIN decks d ON d.id = n.deck_id WHERE n.deck_id = ?`;
/** 同一个 uuid 又活过来了(重新导入 / 又学了),墓碑作废。参数:(kind, uuid) */
export const SQL_DROP_TOMBSTONE: string = `DELETE FROM sync_tombstones WHERE kind = ? AND uuid = ?`;
/** 某类的墓碑,deleted_at > ? */
export const SQL_TOMBSTONES_SINCE: string =
  `SELECT uuid, deleted_at FROM sync_tombstones WHERE kind = ? AND deleted_at > ?`;

// ---------------------------------------------------------------- 同步的本地一侧(Task 12,SyncLocal.ets)

/** 打卡:ts > ? 的(打卡不删、不改,ts 就是它的 updatedAt) */
export const SQL_SYNC_CHECKINS_SINCE: string = `SELECT day, ts FROM checkins WHERE ts > ?`;
export const SQL_SYNC_CHECKIN_TS: string = `SELECT ts FROM checkins WHERE day = ?`;

/**
 * 本机每日汇总里,最后一次作答晚于 ? 的那些天(增量上传)。参数:(dayAnchor, since)。
 * last 是那天最后一条流水的时刻,作 updatedAt。
 */
export const SQL_SYNC_DAYS_SINCE: string =
  `SELECT CAST((ts - ?) / 86400000 AS INTEGER) AS day, COUNT(*) AS reps, SUM(cost_ms) AS ms, MAX(ts) AS last
     FROM review_log GROUP BY day HAVING MAX(ts) > ?`;

/** 牌组:updated_at > ? 的(内容在云存储的 YAML 里,这里只同步「有这副牌组」) */
export const SQL_SYNC_DECKS_SINCE: string = `SELECT uuid, name, updated_at FROM decks WHERE updated_at > ? AND uuid <> ''`;
export const SQL_SYNC_DECK_BY_UUID: string = `SELECT id, updated_at FROM decks WHERE uuid = ?`;

/** 卡片排期:updated_at > ? 的,带同步键(列名 uuid) */
export const SQL_SYNC_SCHED_SINCE: string =
  `SELECT d.uuid || '/' || (CASE WHEN substr(n.uuid, 1, length(d.uuid) + 1) = d.uuid || '/'
                         THEN substr(n.uuid, length(d.uuid) + 2) ELSE n.uuid END) AS uuid, s.*
     FROM scheduling s JOIN cards c ON c.id = s.card_id JOIN notes n ON n.id = c.note_id
     JOIN decks d ON d.id = n.deck_id
    WHERE s.updated_at > ?`;
/**
 * 按同步键找本机的卡。参数:(牌组 uuid, 牌组uuid/id, id) —— 新卡存的是带前缀的,Task 4 之前的卡存的是裸 id。
 * updated_at 是这张卡排期的时刻,没有排期为 -1。
 */
export const SQL_CARD_BY_SYNC_KEY: string =
  `SELECT c.id AS card_id, COALESCE(s.updated_at, -1) AS updated_at
     FROM cards c JOIN notes n ON n.id = c.note_id JOIN decks d ON d.id = n.deck_id
     LEFT JOIN scheduling s ON s.card_id = c.id
    WHERE d.uuid = ? AND (n.uuid = ? OR n.uuid = ?) LIMIT 1`;
export const SQL_TOMBSTONE_AT: string = `SELECT deleted_at FROM sync_tombstones WHERE kind = ? AND uuid = ?`;
/** 云端来的墓碑写进本地(时刻用云端的,不能用现在 —— 否则会被当成本地新改动再传回去) */
export const SQL_PUT_TOMBSTONE: string =
  `INSERT OR REPLACE INTO sync_tombstones (kind, uuid, deleted_at) VALUES (?, ?, ?)`;
export const SQL_DELETE_SCHED_BY_CARD: string = `DELETE FROM scheduling WHERE card_id = ?`;
/** 应用云端排期后把 updated_at 设成云端那条的(不是 last_review),参数:(updated_at, card_id) */
export const SQL_SET_SCHED_UPDATED: string = `UPDATE scheduling SET updated_at = ? WHERE card_id = ?`;

/** 应用云端牌组后把 updated_at 设成云端那条的(不是现在),否则两台设备会来回互相重传 */
export const SQL_SET_DECK_UPDATED: string = `UPDATE decks SET updated_at = ? WHERE uuid = ?`;

/** 同步水位存在 meta 表,**按 uid 分开**:换了账号要从头同步 */
export function metaSyncPushKey(uid: string): string {
  return `sync_last_push:${uid}`;
}
export function metaSyncPullKey(uid: string): string {
  return `sync_last_pull:${uid}`;
}

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

/** 某个指纹在库里有没有。列名必须叫 n(Database.scalar 按名字取列) */
export const SQL_HAS_FINGERPRINT: string =
  `SELECT COUNT(*) AS n FROM notes WHERE fingerprint = ?`;

/** v1 的 8 位旧指纹就地换成 64 位新指纹(planImport.upgrades)。参数:(新, 旧) */
export const SQL_UPGRADE_FINGERPRINT: string =
  `UPDATE notes SET fingerprint = ? WHERE fingerprint = ?`;

/** 今日待学总量:到期卡数 + 新卡数,分两条查免得一条 SQL 里塞两种语义 */
export const SQL_COUNT_DUE: string =
  `SELECT COUNT(*) AS n FROM scheduling WHERE due <= ?`;

export const SQL_COUNT_NEW: string =
  `SELECT COUNT(*) AS n FROM cards c
     LEFT JOIN scheduling s ON s.card_id = c.id
    WHERE s.card_id IS NULL`;

// ---------------------------------------------------------------- 浏览器(Anki Browse)

/**
 * 浏览器的查询:按卡组过滤(0 = 全部)+ 在正面 / 背面 / 标题里搜一个子串。
 *
 * 搜索词**必须先过 escapeLike()** 再包上 `%…%`:用户输入里的 `%` 和 `_`
 * 在 LIKE 里是通配符,不转义的话搜「100%」会把所有含「100」的卡都搜出来。
 * **分页**:一次只取一页(LIMIT ? OFFSET ?),刷到底再取下一页 ——
 * 十万张卡的库不能一次全读进来。排序必须是全序(最后落到 c.id),
 * 否则相邻两页之间可能重复或漏卡。
 *
 * 参数:卡组、卡组、搜索词、模式、模式、模式、页大小、偏移。搜索词为空串时不过滤。
 *
 * 注意 ESCAPE 子句:源码里写 `'\\'`,模板字符串求值后才是 SQL 里的 `'\'`。
 */
export const SQL_BROWSE: string =
  `SELECT c.id AS card_id, n.id AS note_id, n.deck_id, d.name AS deck_name,
          n.type, n.title, n.front, n.back,
          COALESCE(s.due, 0) AS due, COALESCE(s.reps, 0) AS reps
     FROM cards c
     JOIN notes n ON n.id = c.note_id
     JOIN decks d ON d.id = n.deck_id
     LEFT JOIN scheduling s ON s.card_id = c.id
    WHERE (? = 0 OR n.deck_id = ?)
      AND (? = '' OR n.front LIKE ? ESCAPE '\\'
                  OR n.back  LIKE ? ESCAPE '\\'
                  OR n.title LIKE ? ESCAPE '\\')
    ORDER BY d.name, n.id, c.ordinal, c.id
    LIMIT ? OFFSET ?`;

/** 与 SQL_BROWSE 同一个过滤条件下的总数(列表上方的「N 张」)。列名必须叫 n */
export const SQL_BROWSE_COUNT: string =
  `SELECT COUNT(*) AS n
     FROM cards c
     JOIN notes n ON n.id = c.note_id
    WHERE (? = 0 OR n.deck_id = ?)
      AND (? = '' OR n.front LIKE ? ESCAPE '\\'
                  OR n.back  LIKE ? ESCAPE '\\'
                  OR n.title LIKE ? ESCAPE '\\')`;

/** 把用户输入转成 LIKE 的字面量:转义 \ % _。只做这一件事,包 %…% 由调用方决定 */
export function escapeLike(raw: string): string {
  let out: string = '';
  for (let i = 0; i < raw.length; i++) {
    const ch: string = raw.charAt(i);
    if (ch === '\\' || ch === '%' || ch === '_') {
      out += '\\';
    }
    out += ch;
  }
  return out;
}

/** SQL_BROWSE_COUNT 的参数。query 是用户原始输入,这里负责 trim + 转义 */
export function browseCountArgs(deckId: number, query: string): Array<number | string> {
  const q: string = query.trim();
  const pat: string = q.length === 0 ? '' : `%${escapeLike(q)}%`;
  return [deckId, deckId, q, pat, pat, pat];
}

/** SQL_BROWSE 的参数:过滤条件 + 第几页。page 从 0 起 */
export function browseArgs(deckId: number, query: string, pageSize: number, page: number): Array<number | string> {
  const size: number = pageSize > 0 ? pageSize : 50;
  return browseCountArgs(deckId, query).concat([size, page * size]);
}

/** 浏览器的一行。比 CardBrief 多了它在哪个卡组 */
export interface BrowseRow {
  cardId: number;
  noteId: number;
  deckId: number;
  deckName: string;
  type: number;
  title: string;
  front: string;
  back: string;
  /** 下次到期毫秒。0 表示从没学过 */
  due: number;
  reps: number;
}

/** 卡组一览里的一行 */
export interface DeckRow {
  id: number;
  name: string;
  cards: number;
  due: number;
  fresh: number;
}

/**
 * 牌组列表(Anki 式主界面)的原始计数:**一条 SQL 给出所有卡组**,还没套上限。
 *
 * 每一列都和落地页那几条单卡组查询同口径 —— 测试逐列对拍:
 *   unlearned     = SQL_UNLEARNED_COUNT(不设上限)
 *   untouchedDue  = SQL_UNTOUCHED_DUE(不设上限):今日截止前到期、今天还没答过
 *   newToday      = SQL_NEW_INTRODUCED_TODAY:今天第一次见的卡
 *   again/settled = SQL_TODAY_PROGRESS 的灰 / 绿
 *
 * 参数顺序:今日截止、今日起点、今日起点、今日起点、今日截止、今日起点、今日截止。
 * 一律无编号 `?`(编号占位符在 node:sqlite 上不可靠,见 SQL_TODAY_PROGRESS)。
 */
export const SQL_DECK_COUNTS: string =
  `SELECT d.id, d.name,
          COUNT(c.id) AS cards,
          SUM(CASE WHEN s.card_id IS NULL THEN 1 ELSE 0 END) AS unlearned,
          SUM(CASE WHEN s.card_id IS NOT NULL AND s.due < ? AND s.last_review < ?
                   THEN 1 ELSE 0 END) AS untouched_due,
          SUM(CASE WHEN s.card_id IS NOT NULL AND s.first_seen >= ?
                   THEN 1 ELSE 0 END) AS new_today,
          SUM(CASE WHEN s.card_id IS NOT NULL AND s.last_review >= ? AND s.due < ?
                   THEN 1 ELSE 0 END) AS again,
          SUM(CASE WHEN s.card_id IS NOT NULL AND s.last_review >= ? AND s.due >= ?
                   THEN 1 ELSE 0 END) AS settled
     FROM decks d
     JOIN notes n ON n.deck_id = d.id
     JOIN cards c ON c.note_id = n.id
     LEFT JOIN scheduling s ON s.card_id = c.id
    GROUP BY d.id
    HAVING cards > 0
    ORDER BY d.name ASC`;

/** SQL_DECK_COUNTS 的一行 */
export interface DeckCountRow {
  id: number;
  name: string;
  cards: number;
  unlearned: number;
  untouchedDue: number;
  newToday: number;
  again: number;
  settled: number;
}

/** 牌组列表上显示的一行:已经按每日上限截过 */
export interface DeckCounts {
  id: number;
  name: string;
  cards: number;
  /** 待学习:今天还能引入的新卡 */
  newCount: number;
  /** 学习中:今天答过、今天还会回来 */
  learnCount: number;
  /** 待复习:今天到期、今天还没答过 */
  dueCount: number;
  /** 今天已学完(三段条的绿) */
  settled: number;
}

/**
 * 套上每日上限。**上限对每个卡组各算一份**(Anki 默认预设的行为):
 * 新卡额度 20 时,两个卡组各自能出 20 张,而不是合起来 20 张。
 * 新卡剩余额度 = 额度 − 本组今天已引入,和落地页的算法一字不差。
 */
export function applyDeckLimits(r: DeckCountRow, newPerDay: number, reviewLimit: number): DeckCounts {
  const leftNew: number = newPerDay > r.newToday ? newPerDay - r.newToday : 0;
  return {
    id: r.id,
    name: r.name,
    cards: r.cards,
    newCount: Math.min(r.unlearned, leftNew),
    learnCount: r.again,
    dueCount: Math.min(r.untouchedDue, reviewLimit < 0 ? 0 : reviewLimit),
    settled: r.settled,
  };
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
 * 为什么不在 SQL 里除法分桶:日界是凌晨 3 点且要按本地时区,
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
 * 卡片指纹:没有 `id` 的旧文件重导时,用它认出「还是那张卡」并保住排期。
 *
 * 取 deck + 标识键 + 序号 —— 正文改了错别字不影响指纹,所以改文件重导不会丢进度。
 *
 * **64 位(16 位十六进制),schema v2 起。** 32 位版本约 1 万张卡就有 ~1% 概率撞车、
 * 7.7 万张 ~50%;notes.fingerprint 是 UNIQUE,撞车时真正的新卡会被当成旧卡跳过。
 * 两半用两个不同的 32 位哈希拼成:FNV-1a + 一个 murmur 风格的乘法哈希(带 fmix 收尾)。
 * 都不依赖任何运行时库,桌面测试能直接跑。
 *
 * 旧库里的 8 位指纹无法在迁移时重算(库里只存了标题,没存标识键),
 * 所以由导入时**惰性升级**:见 planImport 的 upgrades 与 legacyFingerprintOf。
 */
export function fingerprintOf(deck: string, title: string, ordinal: number): string {
  const raw = `${deck}\u0000${title}\u0000${ordinal}`;
  return fnv1a32(raw) + mix32(raw);
}

/** schema v1 的 32 位指纹(8 位十六进制)。只用来认出旧库里的行并升级它们 */
export function legacyFingerprintOf(deck: string, title: string, ordinal: number): string {
  return fnv1a32(`${deck}\u0000${title}\u0000${ordinal}`);
}

/** FNV-1a 32 位 -> 8 位十六进制 */
function fnv1a32(raw: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < raw.length; i++) {
    h ^= raw.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, '0');
}

/** 第二个 32 位哈希:与 FNV-1a 结构不同,两者同时撞车的概率才接近 2^-64 */
function mix32(raw: string): string {
  let h = 0x9747b28c ^ raw.length;
  for (let i = 0; i < raw.length; i++) {
    h = Math.imul(h ^ raw.charCodeAt(i), 0x5bd1e995);
    h ^= h >>> 15;
  }
  h ^= h >>> 16;
  h = Math.imul(h, 0x85ebca6b);
  h ^= h >>> 13;
  h = Math.imul(h, 0xc2b2ae35);
  h ^= h >>> 16;
  return (h >>> 0).toString(16).padStart(8, '0');
}

/** 旧指纹 -> 新指纹 的就地升级 */
export interface FingerprintUpgrade {
  from: string;
  to: string;
}

// ---------------------------------------------------------------- 按 id 导入与更新(Task 4)

/**
 * 卡片内容哈希(notes.content_hash):同一张卡(同 id / 同指纹)重导时,用它判断内容变没变。
 * 包含所有用户看得见、改了就该更新的字段;不含身份(id / 指纹)与排期。64 位,算法同指纹。
 */
export function contentHashOf(type: number, title: string, front: string, back: string,
                              options: string[], answer: string, tags: string[]): string {
  const raw = [`${type}`, title, front, back, options.join('\n'), answer, tags.join('\n')]
    .join('\u0000');
  return fnv1a32(raw) + mix32(raw);
}

/**
 * 卡片在库里的固定身份。v1 文件里的 `id` 只要求**文件内**唯一,两副牌组都可能有 `c-0001`,
 * 而 notes.uuid 是全局 UNIQUE —— 所以落库时加上牌组 uuid 作命名空间。
 * 导出时(Task 5)剥掉 `牌组uuid/` 前缀写回 `id`;牌组 uuid 同时写进 meta.id,
 * 所以导出 → 另一台设备导入后,这一串完全一样。
 */
export function noteUuidOf(deckUuid: string, cardId: string): string {
  return `${deckUuid}/${cardId}`;
}

/** 文件里的一张卡,规划导入用的那几样 */
export interface ImportCardInput {
  /** v1 的 id;空串 = 没写 */
  id: string;
  /** 标识键(指纹取它) */
  key: string;
  /** contentHashOf 的结果 */
  hash: string;
}

/** 库里已有的一条笔记 */
export interface ExistingNote {
  noteId: number;
  /** '' = v2 之前导入的,还没算过 */
  hash: string;
}

/** 已有的卡、内容变了:按 noteId 更新内容,排期不动 */
export interface NoteUpdate {
  /** 在文件卡片里的下标 */
  index: number;
  noteId: number;
}

/** planDeckImport 的结果 */
export interface DeckImportPlan {
  /** 要新插入的卡(文件下标),保持文件顺序 */
  fresh: number[];
  /** 要更新内容的旧卡 */
  updates: NoteUpdate[];
  /** 已有且内容没变、原样跳过的张数(含同一文件里重复的那张) */
  unchanged: number;
  /** v1 旧指纹的就地升级 */
  upgrades: FingerprintUpgrade[];
  /** 文件认领到的已有笔记 id(算「文件里少了几张」用) */
  matched: number[];
}

/**
 * 重导的核心判定(纯函数,查库由调用方注入,只查**这一副牌组**里的笔记):
 *
 *   1. 文件写了 id → 先按 id 找;
 *   2. 找不到 → 按 64 位指纹找;再找不到按 v1 的 8 位旧指纹找(命中就记一条升级);
 *   3. 找到了:内容哈希相同 → 跳过;不同(或旧行还没有哈希)→ 更新内容,**排期不动**;
 *   4. 都找不到 → 新卡。
 *
 * 同一文件里两张卡认领到同一条笔记时,只有第一张算数,第二张跳过 —— 不会把一条笔记更新两次。
 * 文件里没有的已有卡**不删**,只由调用方用 matched 算出数量提示用户(已与用户确认)。
 */
export function planDeckImport(deck: string, cards: ImportCardInput[],
                               byId: (id: string) => ExistingNote | null,
                               byFp: (fp: string) => ExistingNote | null): DeckImportPlan {
  const plan: DeckImportPlan = { fresh: [], updates: [], unchanged: 0, upgrades: [], matched: [] };
  const seenFp = new Set<string>();
  for (let i = 0; i < cards.length; i++) {
    const c: ImportCardInput = cards[i];
    const fp: string = fingerprintOf(deck, c.key, 0);
    if (seenFp.has(fp)) {
      plan.unchanged++;
      continue;
    }
    seenFp.add(fp);

    let ex: ExistingNote | null = c.id.length > 0 ? byId(c.id) : null;
    if (ex === null) {
      ex = byFp(fp);
    }
    if (ex === null) {
      const old: string = legacyFingerprintOf(deck, c.key, 0);
      ex = byFp(old);
      if (ex !== null) {
        plan.upgrades.push({ from: old, to: fp });
      }
    }
    if (ex === null) {
      plan.fresh.push(i);
      continue;
    }
    if (plan.matched.includes(ex.noteId)) {
      plan.unchanged++;
      continue;
    }
    plan.matched.push(ex.noteId);
    if (ex.hash === c.hash) {
      plan.unchanged++;
    } else {
      plan.updates.push({ index: i, noteId: ex.noteId });
    }
  }
  return plan;
}

/** 按 id 找笔记,只在这副牌组里。参数:(deckId, 命名空间形式的 uuid, 原样的 id) —— 后者认 v2 之前的行 */
export const SQL_NOTE_BY_UUID_IN_DECK: string =
  `SELECT id, content_hash FROM notes WHERE deck_id = ? AND (uuid = ? OR uuid = ?) LIMIT 1`;

/** 按指纹找笔记,只在这副牌组里。参数:(deckId, fingerprint) */
export const SQL_NOTE_BY_FP_IN_DECK: string =
  `SELECT id, content_hash FROM notes WHERE deck_id = ? AND fingerprint = ? LIMIT 1`;

/** 新卡落库(schema v2 全列)。参数顺序见 Database.insertNoteRow 与 import_test */
export const SQL_INSERT_NOTE_V2: string =
  `INSERT INTO notes (deck_id, type, front, back, title, options, answer, source_file,
                      fingerprint, uuid, updated_at, content_hash, tags)
   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`;

/** 重导时更新一张旧卡的内容。**身份(uuid / 指纹)与排期都不动。** 最后一个参数是 note id */
export const SQL_UPDATE_NOTE_CONTENT: string =
  `UPDATE notes SET type = ?, front = ?, back = ?, title = ?, options = ?, answer = ?,
          tags = ?, content_hash = ?, source_file = ?, updated_at = ? WHERE id = ?`;

/** 按 meta.id 找牌组 */
export const SQL_DECK_BY_UUID: string = `SELECT id, uuid FROM decks WHERE uuid = ?`;
/** 按名字找牌组(带 uuid) */
export const SQL_DECK_REF_BY_NAME: string = `SELECT id, uuid FROM decks WHERE name = ?`;

/** 导入后写回牌组信息。参数:(tags JSON, meta JSON, version, now, deckId) */
export const SQL_UPDATE_DECK_INFO: string =
  `UPDATE decks SET tags = ?, meta = ?, version = ?, updated_at = ? WHERE id = ?`;

/** 文件里少了几张:这副牌组现有笔记数 − 文件认领到的 */
export function missingCount(deckNoteCount: number, plan: DeckImportPlan): number {
  return Math.max(0, deckNoteCount - plan.matched.length);
}

// ---------------------------------------------------------------- 导出(Task 5)

/** 导出一副牌组的牌组信息。**只取内容列** */
export const SQL_EXPORT_DECK: string = `SELECT name, uuid, tags, meta FROM decks WHERE id = ?`;

/**
 * 导出一副牌组的全部卡片,按导入顺序。**只取内容列,不 JOIN scheduling / review_log** ——
 * 导出文件里没有任何个人学习数据(docs/data-model.md §6)。
 */
export const SQL_EXPORT_NOTES: string =
  `SELECT uuid, type, title, front, back, options, answer, tags
     FROM notes WHERE deck_id = ? AND deleted_at = 0 ORDER BY id ASC`;

/** tags 列(JSON 文本)-> 数组。旧行或坏数据一律当空列表,不让导出因为一列失败 */
export function parseTagsColumn(raw: string): string[] {
  if (raw.length === 0) {
    return [];
  }
  try {
    const v: Object = JSON.parse(raw) as Object;
    if (!Array.isArray(v)) {
      return [];
    }
    const out: string[] = [];
    for (const x of v as Object[]) {
      if (typeof x === 'string' && x.length > 0) {
        out.push(x as string);
      }
    }
    return out;
  } catch (e) {
    return [];
  }
}

/** planImport 的结果:要插入的卡(下标)与跳过的张数 */
export interface ImportPlan {
  /** parsed.cards 里要新插入的那些的下标,保持文件里的顺序 */
  fresh: number[];
  /** 库里已有(或同一个文件里前面已经出现过)而跳过的张数 */
  skipped: number;
  /** 命中了 v1 旧指纹的行:调用方在同一个事务里把它们改成 64 位指纹 */
  upgrades: FingerprintUpgrade[];
}

/**
 * 重导的核心判定:**指纹已在库里的卡就是旧卡,跳过;其余是新卡。**
 *
 * 原来的导入对每张卡直接 INSERT,靠 notes.fingerprint 的 UNIQUE 约束报错来「防重复」——
 * 于是重导同一个文件会在第一张旧卡上失败,而排在它前面的新卡已经写进去了。
 * 现在先按指纹分好新旧,只插新卡(调用方包事务)。
 *
 * 先查 64 位新指纹;查不到再查 v1 的 32 位旧指纹 —— 命中就是 v2 之前导入的那张卡,
 * 也算旧卡跳过,并记进 upgrades 让调用方把那一行升级成新指纹。
 *
 * 同一个文件里两张卡算出同一个指纹时(Quizify 已经拦住了键重复,这里是兜底),
 * 第二张也算跳过,不会让 UNIQUE 中途抛错。纯函数:查库由 `exists` 注入,桌面测试能直接跑。
 */
export function planImport(deck: string, keys: string[], exists: (fp: string) => boolean): ImportPlan {
  const fresh: number[] = [];
  const upgrades: FingerprintUpgrade[] = [];
  const seen = new Set<string>();
  let skipped = 0;
  for (let i = 0; i < keys.length; i++) {
    const fp: string = fingerprintOf(deck, keys[i], 0);
    if (seen.has(fp) || exists(fp)) {
      skipped++;
    } else {
      const old: string = legacyFingerprintOf(deck, keys[i], 0);
      if (exists(old)) {
        skipped++;
        upgrades.push({ from: old, to: fp });
      } else {
        fresh.push(i);
      }
    }
    seen.add(fp);
  }
  return { fresh: fresh, skipped: skipped, upgrades: upgrades };
}
