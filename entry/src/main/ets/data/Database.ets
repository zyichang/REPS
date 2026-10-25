/**
 * 数据层:relationalStore(SQLite)封装。
 *
 * 本文件**故意写得很薄** —— 它是唯一无法在桌面测试里跑的一层,
 * 所以除了「调用 relationalStore」之外不承担任何逻辑:
 * 建表语句、行映射、日界算术全部来自 Schema.ets,那一层有 47 条断言覆盖。
 *
 * 一条纪律:**不要在本文件里新写 SQL 字面量**。新增查询请加到 Schema.ets,
 * 让桌面测试能执行到它。WordSnap 的教训是手抄的镜像 SQL 会和生产悄悄分叉。
 *
 * review_log 只写不改 —— 统计要可信,原始流水一条都不能丢。
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CardState, NoteType, ReviewLog } from '../model/Models';
import {
  BrowseRow, CardBrief, DDL, META_BACKFILL_CHECKINS, MIGRATE_BACKFILL_CHECKINS, SQL_CHECKIN_DAYS,
  SQL_INSERT_CHECKIN, SQL_IS_CHECKED_IN, SQL_META_GET, SQL_META_SET, dayAnchor, DayStat, SQL_BROWSE, SQL_BROWSE_COUNT, browseArgs, browseCountArgs, DeckCountRow, DeckCounts, DeckRow, LogPoint, SQL_DECK_COUNTS,
  applyDeckLimits, dayIndex, dayStart, MIGRATE_FLATTEN_DECKS, ReviewCardRow,
  ReviewedCard, SQL_AHEAD_CARDS, SQL_AHEAD_CARDS_IN_DECK, SQL_COUNT_CARDS,
  SQL_COUNT_CARDS_IN_DECK, SQL_COUNT_DUE, SQL_COUNT_DUE_IN_DECK, SQL_COUNT_NEW,
  SQL_COUNT_NEW_IN_DECK, SQL_DAY_STATS, SQL_DECK_NOTE_COUNT,
  SQL_DELETE_DECK, SQL_DELETE_DECK_CARDS, SQL_ARCHIVE_DECK_LOGS, SQL_DELETE_DECK_NOTES,
  MIGRATE_ADD_ARCHIVED, SQL_HAS_ARCHIVED_COL,
  SQL_DELETE_DECK_SCHED, SQL_DELETE_NOTE, SQL_DELETE_NOTE_CARDS,
  SQL_DELETE_NOTE_SCHED, SQL_DUE_CARDS, SQL_DUE_CARDS_IN_DECK, SQL_DUE_FORECAST,
  SQL_DUE_FORECAST_IN_DECK, SQL_HAS_PARENT_COL,
  SQL_INSERT_LOG, SQL_LIST_CARDS_ALL, SQL_LIST_CARDS_IN_DECK, SQL_LIST_DECKS,
  SQL_LOG_SINCE, SQL_NEW_CARDS, SQL_NEW_CARDS_IN_DECK, SQL_NEW_INTRODUCED_TODAY,
  SQL_RETENTION_ALL, SQL_REVIEWED_TODAY, SQL_SELECT_DECK_ID, SQL_SELECT_DECK_NAME,
  SQL_SELECT_NOTE_BY_CARD, SQL_SELECT_SCHEDULING, SQL_STABILITY_HISTOGRAM,
  SQL_STABILITY_IN_DECK, SQL_TODAY_PROGRESS, SQL_UNLEARNED_COUNT, SQL_UNTOUCHED_DUE,
  SQL_UPDATE_NOTE_TEXT, SQL_UPSERT_SCHEDULING, SchedulingRow, TodayProgress, fingerprintOf,
  fromSchedulingRow, isValidAlgo, schedulingValues, toSchedulingRow,
  SQL_HAS_FINGERPRINT, legacyFingerprintOf, Migration, pendingMigrations,
  SCHEMA_VERSION, SQL_TOUCH_SCHEDULING, SQL_UPGRADE_FINGERPRINT,
  DeckImportPlan, ExistingNote, ImportCardInput, SQL_DECK_BY_UUID,
  SQL_DECK_REF_BY_NAME, SQL_NOTE_BY_FP_IN_DECK, SQL_NOTE_BY_UUID_IN_DECK, SQL_UPDATE_DECK_INFO,
  SQL_UPDATE_NOTE_CONTENT, contentHashOf, missingCount, noteUuidOf, planDeckImport,
  SQL_EXPORT_DECK, SQL_EXPORT_NOTES, parseTagsColumn,
  DailyStatRow, META_DEVICE_ID, SQL_META_VALUE, SQL_REMOTE_DAY_STATS, SQL_UPSERT_REMOTE_DAY_STAT,
  mergeDayStats, SQL_TOMBSTONE_DECK, SQL_TOMBSTONE_DECK_CARDS, SQL_TOMBSTONE_DECK_SCHED,
  SQL_TOMBSTONE_NOTE_CARDS,
} from './Schema';
import { DeckMeta, ParsedCard, ParsedDeck, emptyMeta } from './Quizify';
import { ExportCard, ExportDeck, exportYaml } from './YamlExport';
import { util } from '@kit.ArkTS';

/** importDeck 的结果 */
export interface StoreResult {
  /** 新插入的张数 */
  added: number;
  /** 已有、内容没变而跳过的张数 */
  skipped: number;
  /** 已有、内容变了而更新的张数(排期保留) */
  updated: number;
  /** 牌组里有、这次文件里没有的张数(没有删除,只提示) */
  missing: number;
}

/** 一副牌组的本地 id 与固定身份 */
interface DeckRef {
  id: number;
  uuid: string;
}

/** 一张卡的内容哈希(notes.content_hash) */
function cardHash(c: ParsedCard): string {
  return contentHashOf(c.type as number, c.title, c.front, c.back, c.options, c.answer, c.tags);
}

const DOMAIN: number = 0x0A01;
const TAG: string = 'REPS-DB';
const DB_NAME: string = 'reps.db';

export class Database {
  private store: relationalStore.RdbStore | null = null;

  async init(context: common.UIAbilityContext): Promise<void> {
    const config: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1,
    };
    this.store = await relationalStore.getRdbStore(context, config);
    for (const stmt of DDL) {
      await this.store.executeSql(stmt);
    }
    await this.flattenDecksIfNeeded();
    await this.addArchivedIfNeeded();
    await this.backfillCheckinsOnce();
    await this.migrate();
    hilog.info(DOMAIN, TAG, '数据库就绪,已执行 %{public}d 条 DDL,schema v%{public}d',
      DDL.length, this.db().version);
  }

  /**
   * 版本化迁移(schema v2 起):按 RdbStore.version(= PRAGMA user_version)只跑没跑过的。
   * 每个版本一个事务,提交之后才写版本号 —— 崩在中途,下次启动整版重跑。
   * 逻辑与 devtest/migration_test.ts 里的 migrate() 一一对应。
   */
  private async migrate(): Promise<void> {
    const store = this.db();
    const todo: Migration[] = pendingMigrations(store.version);
    for (const m of todo) {
      hilog.info(DOMAIN, TAG, '迁移到 schema v%{public}d', m.version);
      store.beginTransaction();
      try {
        for (const stmt of m.statements) {
          await store.executeSql(stmt);
        }
        store.commit();
      } catch (e) {
        store.rollBack();
        hilog.error(DOMAIN, TAG, '迁移 v%{public}d 失败,已回滚: %{public}s', m.version, `${e}`);
        throw new Error(`数据库迁移 v${m.version} 失败: ${e}`);
      }
      store.version = m.version;
    }
    if (store.version !== SCHEMA_VERSION) {
      throw new Error(`数据库版本 ${store.version} 与应用要求的 ${SCHEMA_VERSION} 不一致`);
    }
  }

  /** 新的固定身份(牌组 / 笔记 / 卡片)。生成一次,之后永不改变 */
  private newUuid(): string {
    return util.generateRandomUUID(true);
  }

  /**
   * 一次性迁移:把带层级的 decks 拍平。
   *
   * 必须有这一步,因为 DDL 用的是 `CREATE TABLE IF NOT EXISTS` ——
   * 光把建表语句改成新结构,对**已经存在**的表没有任何作用。
   *
   * 包在事务里:中间是 DROP TABLE decks 再 RENAME,崩在中途会把卡组全丢掉。
   * 判据是「decks 还有没有 parent_id 列」,所以重复启动不会再跑第二次。
   */
  private async flattenDecksIfNeeded(): Promise<void> {
    const store = this.db();
    const rs = await store.querySql(SQL_HAS_PARENT_COL);
    let hasParent = false;
    try {
      hasParent = rs.goToFirstRow() && rs.getLong(rs.getColumnIndex('n')) > 0;
    } finally {
      rs.close();
    }
    if (!hasParent) {
      return;
    }
    hilog.info(DOMAIN, TAG, '检测到旧版分层卡组,开始拍平迁移');
    store.beginTransaction();
    try {
      for (const stmt of MIGRATE_FLATTEN_DECKS) {
        await store.executeSql(stmt);
      }
      store.commit();
      hilog.info(DOMAIN, TAG, '卡组已拍平');
    } catch (e) {
      store.rollBack();
      hilog.error(DOMAIN, TAG, '拍平迁移失败,已回滚: %{public}s', `${e}`);
      throw new Error(`卡组拍平迁移失败: ${e}`);
    }
  }

  /** 旧库补上 review_log.archived 列(ADR-0005)。判据是列在不在,重复启动不会再跑 */
  private async addArchivedIfNeeded(): Promise<void> {
    const store = this.db();
    const rs = await store.querySql(SQL_HAS_ARCHIVED_COL);
    let has = false;
    try {
      has = rs.goToFirstRow() && rs.getLong(rs.getColumnIndex('n')) > 0;
    } finally {
      rs.close();
    }
    if (!has) {
      await store.executeSql(MIGRATE_ADD_ARCHIVED);
      hilog.info(DOMAIN, TAG, 'review_log 已补 archived 列');
    }
  }

  /**
   * 打卡功能上线前的日子:有作答就算打过卡(一次性,meta 标记)。
   * 不回填的话老用户的「学习天数」会从 0 开始。
   */
  private async backfillCheckinsOnce(): Promise<void> {
    const store = this.db();
    const rs = await store.querySql(SQL_META_GET, [META_BACKFILL_CHECKINS]);
    let done = false;
    try {
      done = rs.goToFirstRow() && rs.getLong(rs.getColumnIndex('n')) > 0;
    } finally {
      rs.close();
    }
    if (done) {
      return;
    }
    await store.executeSql(MIGRATE_BACKFILL_CHECKINS, [dayAnchor(Date.now())]);
    await store.executeSql(SQL_META_SET, [META_BACKFILL_CHECKINS, `${Date.now()}`]);
    hilog.info(DOMAIN, TAG, '已按作答记录回填打卡');
  }

  // ------------------------------------------------------------ 打卡

  /** 给某一天打卡。重复打卡无效果;**没有撤销** */
  checkIn(day: number, now: number): void {
    this.db().executeSync(SQL_INSERT_CHECKIN, [day, now] as Array<relationalStore.ValueType>);
  }

  isCheckedIn(day: number): boolean {
    return this.scalar(SQL_IS_CHECKED_IN, [day] as Array<relationalStore.ValueType>) > 0;
  }

  /** 全部打卡日(日序号,升序) */
  checkinDays(): number[] {
    const rs = this.db().querySqlSync(SQL_CHECKIN_DAYS);
    const out: number[] = [];
    try {
      while (rs.goToNextRow()) {
        out.push(rs.getLong(rs.getColumnIndex('day')));
      }
    } finally {
      rs.close();
    }
    return out;
  }

  private db(): relationalStore.RdbStore {
    if (this.store === null) {
      throw new Error('数据库尚未初始化,先 await init(context)');
    }
    return this.store;
  }

  // ------------------------------------------------------------ 排期状态

  /** 写入(或整行覆盖)一张卡的排期状态 */
  saveState(state: CardState): void {
    const values: number[] = schedulingValues(toSchedulingRow(state));
    this.db().executeSync(SQL_UPSERT_SCHEDULING, values as Array<relationalStore.ValueType>);
    this.db().executeSync(SQL_TOUCH_SCHEDULING, [state.cardId] as Array<relationalStore.ValueType>);
  }

  /** 读一张卡的排期状态。返回 null 表示这张卡还没被答过(新卡) */
  loadState(cardId: number): CardState | null {
    const rs = this.db().querySqlSync(SQL_SELECT_SCHEDULING, [cardId]);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      const row: SchedulingRow = {
        card_id: rs.getLong(rs.getColumnIndex('card_id')),
        stability: rs.getDouble(rs.getColumnIndex('stability')),
        difficulty: rs.getDouble(rs.getColumnIndex('difficulty')),
        reps: rs.getLong(rs.getColumnIndex('reps')),
        lapses: rs.getLong(rs.getColumnIndex('lapses')),
        streak: rs.getLong(rs.getColumnIndex('streak')),
        last_review: rs.getLong(rs.getColumnIndex('last_review')),
        due: rs.getLong(rs.getColumnIndex('due')),
        phase: rs.getLong(rs.getColumnIndex('phase')),
        step: rs.getLong(rs.getColumnIndex('step')),
        first_seen: rs.getLong(rs.getColumnIndex('first_seen')),
      };
      return fromSchedulingRow(row);
    } finally {
      rs.close();
    }
  }

  // ------------------------------------------------------------ 复习流水

  /** 追加一条复习记录。只写不改 */
  logReview(log: ReviewLog): void {
    const algo: string = isValidAlgo(log.algo) ? log.algo : 'fsrs';
    this.db().executeSync(SQL_INSERT_LOG, [
      log.cardId, log.ts, log.grade, log.stabilityBefore, log.elapsedDays,
      log.retrievability, log.intervalDays, log.costMs, algo,
    ] as Array<relationalStore.ValueType>);
  }

  // ------------------------------------------------------------ 取卡

  /** 到期卡的 id。注意用的是 now,不是日界 —— 见 Schema 的 DAY_CUTOFF_HOUR 说明 */
  dueCardIds(now: number, limit: number): number[] {
    return this.idColumn(this.db().querySqlSync(SQL_DUE_CARDS, [now, limit]));
  }

  /** 新卡的 id(没有 scheduling 行的卡) */
  newCardIds(limit: number): number[] {
    return this.idColumn(this.db().querySqlSync(SQL_NEW_CARDS, [limit]));
  }

  private idColumn(rs: relationalStore.ResultSet): number[] {
    const out: number[] = [];
    try {
      const idx = rs.getColumnIndex('card_id');
      while (rs.goToNextRow()) {
        out.push(rs.getLong(idx));
      }
    } finally {
      rs.close();
    }
    return out;
  }

  // ------------------------------------------------------------ 写入卡组/笔记/卡片

  /**
   * 写入一条笔记及其卡片,返回卡片 id 列表。
   *
   * title 与 key 是两回事,不能混:
   *   title 是 #### 的完整原文,给人看的(含题干);
   *   key   是标识部分(如「基础选择 (1)」),指纹取它。
   * 用 title 算指纹的话,用户改一个错别字就会被当成新卡,进度全丢。
   *
   * 一条笔记恒为一张卡(ADR-0002)。**卡片 uuid 与笔记 uuid 相同** —— 同步时
   * card_state 按它对卡,两台设备从同一份导出 YAML 导入后这一串完全一样。
   */
  insertNote(deckId: number, deckName: string, c: ParsedCard, sourceFile: string,
             uuid: string, now: number): number[] {
    const noteId: number = this.insertNoteRow(deckId, deckName, c, sourceFile, uuid, now);
    const card: relationalStore.ValuesBucket = {
      note_id: noteId, ordinal: 0, uuid: uuid, updated_at: now,
    };
    return [this.db().insertSync('cards', card)];
  }

  /**
   * 写一行 notes。用 insertSync 拿新 id —— 不能 INSERT 后再 `SELECT MAX(id)`:
   * 那条查询走读连接,在 importDeck 的事务里看不到刚写的行(CONTEXT 陷阱 5)。
   * 列与 Schema.SQL_INSERT_NOTE_V2 一致(桌面测试 reimport_test 用的是那一条)。
   */
  private insertNoteRow(deckId: number, deckName: string, c: ParsedCard, sourceFile: string,
                        uuid: string, now: number): number {
    const note: relationalStore.ValuesBucket = {
      deck_id: deckId,
      type: c.type as number,
      front: c.front,
      back: c.back,
      title: c.title,
      options: c.options.join('\n'),
      answer: c.answer,
      source_file: sourceFile,
      fingerprint: fingerprintOf(deckName, c.key, 0),
      uuid: uuid,
      updated_at: now,
      content_hash: cardHash(c),
      tags: JSON.stringify(c.tags),
    };
    return this.db().insertSync('notes', note);
  }

  /** 取一张卡的完整内容,供复习界面显示。找不到返回 null */
  loadReviewCard(cardId: number): ReviewCardRow | null {
    const rs = this.db().querySqlSync(SQL_SELECT_NOTE_BY_CARD, [cardId]);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return {
        note_id: rs.getLong(rs.getColumnIndex('note_id')),
        type: rs.getLong(rs.getColumnIndex('type')),
        front: rs.getString(rs.getColumnIndex('front')),
        back: rs.getString(rs.getColumnIndex('back')),
        title: rs.getString(rs.getColumnIndex('title')),
        options: rs.getString(rs.getColumnIndex('options')),
        answer: rs.getString(rs.getColumnIndex('answer')),
        fingerprint: rs.getString(rs.getColumnIndex('fingerprint')),
        ordinal: rs.getLong(rs.getColumnIndex('ordinal')),
        deck_name: rs.getString(rs.getColumnIndex('deck_name')),
      };
    } finally {
      rs.close();
    }
  }

  /** 到期卡总数(不受取卡上限影响,用于首页显示「今天还有多少」) */
  dueCount(now: number): number {
    return this.scalar(SQL_COUNT_DUE, [now]);
  }

  /** 新卡总数 */
  newCount(): number {
    return this.scalar(SQL_COUNT_NEW, []);
  }

  /** 某卡组(0 = 全部)此刻到期的卡数。只要数字时用它,不要取 id 列表再数 */
  dueCountInDeck(deckId: number, now: number): number {
    return this.scalar(SQL_COUNT_DUE_IN_DECK,
      [now, deckId, deckId] as Array<relationalStore.ValueType>);
  }

  /** 某卡组(0 = 全部)还没学过的卡数,不设上限 */
  newCountInDeck(deckId: number): number {
    return this.scalar(SQL_COUNT_NEW_IN_DECK,
      [deckId, deckId] as Array<relationalStore.ValueType>);
  }

  /**
   * 取一个单值。**查询的列必须别名为 `n`** —— 这里是按名字取列的。
   * 用别的别名不会编译报错,只会在运行时抛「column index is out of bounds」。
   */
  private scalar(sql: string, args: Array<relationalStore.ValueType>): number {
    const rs = this.db().querySqlSync(sql, args);
    try {
      rs.goToFirstRow();
      return rs.getLong(rs.getColumnIndex('n'));
    } finally {
      rs.close();
    }
  }

  /** 某个卡组里的卡片总数 —— 「开始学习」按钮只在这个数为 0 时才禁用 */
  cardCountInDeck(deckId: number): number {
    return this.scalar(SQL_COUNT_CARDS_IN_DECK, [deckId] as Array<relationalStore.ValueType>);
  }

  cardCount(): number {
    const rs = this.db().querySqlSync(SQL_COUNT_CARDS);
    try {
      rs.goToFirstRow();
      return rs.getLong(rs.getColumnIndex('n'));
    } finally {
      rs.close();
    }
  }

  // ------------------------------------------------------------ 卡组一览

  /** 列出所有挂了卡片的卡组,每组带卡片数 / 待复习 / 新卡 */
  listDecks(now: number): DeckRow[] {
    const rs = this.db().querySqlSync(SQL_LIST_DECKS, [now]);
    const out: DeckRow[] = [];
    try {
      while (rs.goToNextRow()) {
        out.push({
          id: rs.getLong(rs.getColumnIndex('id')),
          name: rs.getString(rs.getColumnIndex('name')),
          cards: rs.getLong(rs.getColumnIndex('cards')),
          due: rs.getLong(rs.getColumnIndex('due')),
          fresh: rs.getLong(rs.getColumnIndex('fresh')),
        });
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /**
   * 牌组列表的计数:一条 SQL 拿全部卡组的原始数,再按每日上限逐组截断。
   * 口径与学习页落地页完全一致(见 Schema.SQL_DECK_COUNTS)。
   */
  deckCounts(now: number, newPerDay: number, reviewLimit: number): DeckCounts[] {
    const today: number = dayIndex(now);
    const dayFrom: number = dayStart(today);
    const dayTo: number = dayStart(today + 1);
    const rs = this.db().querySqlSync(SQL_DECK_COUNTS,
      [dayTo, dayFrom, dayFrom, dayFrom, dayTo, dayFrom, dayTo] as Array<relationalStore.ValueType>);
    const out: DeckCounts[] = [];
    try {
      while (rs.goToNextRow()) {
        const row: DeckCountRow = {
          id: rs.getLong(rs.getColumnIndex('id')),
          name: rs.getString(rs.getColumnIndex('name')),
          cards: rs.getLong(rs.getColumnIndex('cards')),
          unlearned: rs.getLong(rs.getColumnIndex('unlearned')),
          untouchedDue: rs.getLong(rs.getColumnIndex('untouched_due')),
          newToday: rs.getLong(rs.getColumnIndex('new_today')),
          again: rs.getLong(rs.getColumnIndex('again')),
          settled: rs.getLong(rs.getColumnIndex('settled')),
        };
        out.push(applyDeckLimits(row, newPerDay, reviewLimit));
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /** 浏览器的总数(同一过滤条件) */
  browseCount(deckId: number, query: string): number {
    return this.scalar(SQL_BROWSE_COUNT, browseCountArgs(deckId, query) as Array<relationalStore.ValueType>);
  }

  /**
   * 浏览器的一页:按卡组(0 = 全部)过滤 + 子串搜索,第 page 页(从 0 起)。
   * 搜索词的转义在 browseArgs 里。
   */
  browse(deckId: number, query: string, pageSize: number, page: number): BrowseRow[] {
    const rs = this.db().querySqlSync(SQL_BROWSE,
      browseArgs(deckId, query, pageSize, page) as Array<relationalStore.ValueType>);
    const out: BrowseRow[] = [];
    try {
      while (rs.goToNextRow()) {
        out.push({
          cardId: rs.getLong(rs.getColumnIndex('card_id')),
          noteId: rs.getLong(rs.getColumnIndex('note_id')),
          deckId: rs.getLong(rs.getColumnIndex('deck_id')),
          deckName: rs.getString(rs.getColumnIndex('deck_name')),
          type: rs.getLong(rs.getColumnIndex('type')),
          title: rs.getString(rs.getColumnIndex('title')),
          front: rs.getString(rs.getColumnIndex('front')),
          back: rs.getString(rs.getColumnIndex('back')),
          due: rs.getLong(rs.getColumnIndex('due')),
          reps: rs.getLong(rs.getColumnIndex('reps')),
        });
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /** 卡组名。卡组是平的,不存在「路径」,一次查询即可 */
  deckName(deckId: number): string {
    const rs = this.db().querySqlSync(SQL_SELECT_DECK_NAME, [deckId]);
    try {
      return rs.goToFirstRow() ? rs.getString(rs.getColumnIndex('name')) : '';
    } finally {
      rs.close();
    }
  }

  /** 按卡组取到期卡;deckId 为 0 表示全部卡组 */
  dueCardIdsInDeck(deckId: number, now: number, limit: number): number[] {
    if (deckId === 0) {
      return this.dueCardIds(now, limit);
    }
    return this.idColumn(this.db().querySqlSync(SQL_DUE_CARDS_IN_DECK, [deckId, now, limit]));
  }

  newCardIdsInDeck(deckId: number, limit: number): number[] {
    if (deckId === 0) {
      return this.newCardIds(limit);
    }
    return this.idColumn(this.db().querySqlSync(SQL_NEW_CARDS_IN_DECK, [deckId, limit]));
  }

  /**
   * 「学习更多」取卡:**还没到期但快到期**的卡,最早该复习的在前。
   *
   * `from` 通常是 now,`to` 是明天结束的那个日界 —— 于是拿到的就是
   * 「今天和明天要复习的卡」。用 `due > from` 而不是 `>=`,是为了和正常
   * 到期取卡不重叠:已经到期的卡由今日集合负责,这里只管提前的部分。
   *
   * deckId 传 0 表示全部卡组。
   */
  aheadCardIds(deckId: number, from: number, to: number, limit: number): number[] {
    if (limit <= 0 || to <= from) {
      return [];
    }
    const sql: string = deckId > 0 ? SQL_AHEAD_CARDS_IN_DECK : SQL_AHEAD_CARDS;
    const args: Array<relationalStore.ValueType> = deckId > 0
      ? [deckId, from, to, limit] as Array<relationalStore.ValueType>
      : [from, to, limit] as Array<relationalStore.ValueType>;
    const rs = this.db().querySqlSync(sql, args);
    const out: number[] = [];
    try {
      while (rs.goToNextRow()) {
        out.push(rs.getLong(rs.getColumnIndex('card_id')));
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /**
   * 今日进度三段条的数据。
   *
   * `untouched` 由调用方把「还没做的到期卡 + 剩余新卡额度」加进来 ——
   * 那两个数已经有各自的口径(受复习上限、新卡额度约束),不该在这里重算一遍
   * 而产生第二套事实。
   */
  todayProgress(deckId: number, dayFrom: number, dayTo: number, untouched: number): TodayProgress {
    const rs = this.db().querySqlSync(SQL_TODAY_PROGRESS,
      [dayTo, dayTo, dayFrom, deckId, deckId] as Array<relationalStore.ValueType>);
    let settled = 0;
    let again = 0;
    try {
      if (rs.goToFirstRow()) {
        settled = rs.getLong(rs.getColumnIndex('settled'));
        again = rs.getLong(rs.getColumnIndex('again'));
      }
    } finally {
      rs.close();
    }
    return { settled: settled, again: again, untouched: untouched < 0 ? 0 : untouched };
  }

  /** 今日集合里今天还没答过的旧卡数 */
  untouchedDueCount(deckId: number, dayTo: number, dayFrom: number, limit: number): number {
    return this.scalar(SQL_UNTOUCHED_DUE,
      [dayTo, dayFrom, deckId, deckId, limit] as Array<relationalStore.ValueType>);
  }

  /** 还没学过的卡有多少张(最多数到 limit) */
  unlearnedCount(deckId: number, limit: number): number {
    return this.scalar(SQL_UNLEARNED_COUNT,
      [deckId, deckId, limit] as Array<relationalStore.ValueType>);
  }

  /** 今天已经引入了多少张新卡。剩余新卡额度 = 额度 − 这个数 */
  newIntroducedToday(deckId: number, dayFrom: number): number {
    return this.scalar(SQL_NEW_INTRODUCED_TODAY,
      [dayFrom, deckId, deckId] as Array<relationalStore.ValueType>);
  }

  /** 今天答过的卡,最近的在前。一张卡答了多次也只出现一次 */
  reviewedToday(deckId: number, dayFrom: number, limit: number): ReviewedCard[] {
    const rs = this.db().querySqlSync(SQL_REVIEWED_TODAY,
      [dayFrom, dayFrom, deckId, deckId, dayFrom, limit] as Array<relationalStore.ValueType>);
    const out: ReviewedCard[] = [];
    try {
      while (rs.goToNextRow()) {
        out.push({
          cardId: rs.getLong(rs.getColumnIndex('card_id')),
          title: rs.getString(rs.getColumnIndex('title')),
          front: rs.getString(rs.getColumnIndex('front')),
          grade: rs.getLong(rs.getColumnIndex('grade')),
          lastTs: rs.getLong(rs.getColumnIndex('last_ts')),
        });
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /** 删除一个卡组连同它的全部内容。顺序必须从子表往父表删 */
  /**
   * 删一个卡组连同它的笔记、卡片、排期与流水。
   * 卡组是平的,所以没有「级联到子卡组」这回事,也没有空父节点要收拾。
   * 不可撤销,调用方必须先确认。
   */
  deleteDeck(deckId: number): void {
    const d = this.db();
    // 先记墓碑(同步时传给其他设备),再真删
    const t: Array<relationalStore.ValueType> = [Date.now(), deckId] as Array<relationalStore.ValueType>;
    d.executeSync(SQL_TOMBSTONE_DECK_CARDS, t);
    d.executeSync(SQL_TOMBSTONE_DECK, t);
    // 流水不删:综合统计按整个应用算(ADR-0005)
    d.executeSync(SQL_DELETE_DECK_SCHED, [deckId] as Array<relationalStore.ValueType>);
    d.executeSync(SQL_DELETE_DECK_CARDS, [deckId] as Array<relationalStore.ValueType>);
    d.executeSync(SQL_DELETE_DECK_NOTES, [deckId] as Array<relationalStore.ValueType>);
    d.executeSync(SQL_DELETE_DECK, [deckId] as Array<relationalStore.ValueType>);
  }

  /**
   * 清空一个卡组的学习进度:**删排期、归档复习流水,卡片本身一张不动。**
   *
   * 清完之后这一组的卡全部变回「新卡」 —— 因为「是不是新卡」看的就是
   * 有没有 scheduling 行。流水不删(ADR-0005):花掉的时间和打卡是真实的,
   * 综合统计照算;只是这一组的「今日已学」不再看到它们。
   *
   * 这是**不可撤销**的操作,调用方必须先让用户确认。
   */
  clearDeckProgress(deckId: number): void {
    const d = this.db();
    const a: Array<relationalStore.ValueType> = [deckId] as Array<relationalStore.ValueType>;
    // 流水只归档不删:时间与打卡仍计入综合统计,本组「今日已学」不再看它们
    d.executeSync(SQL_ARCHIVE_DECK_LOGS, a);
    // 有排期的卡记墓碑,其他设备同步后也变回新卡
    d.executeSync(SQL_TOMBSTONE_DECK_SCHED, [Date.now(), deckId] as Array<relationalStore.ValueType>);
    d.executeSync(SQL_DELETE_DECK_SCHED, a);
  }

  // ------------------------------------------------------------ 卡组浏览与手工编辑

  /**
   * 列出卡片。`deckId` 传 0 表示「全部卡组」。
   * 没学过的卡没有 scheduling 行,所以查询用 LEFT JOIN,这里 due/reps 会是 0。
   */
  listCards(deckId: number): CardBrief[] {
    const sql: string = deckId > 0 ? SQL_LIST_CARDS_IN_DECK : SQL_LIST_CARDS_ALL;
    const args: Array<relationalStore.ValueType> = deckId > 0
      ? [deckId] as Array<relationalStore.ValueType> : [] as Array<relationalStore.ValueType>;
    const rs = this.db().querySqlSync(sql, args);
    const out: CardBrief[] = [];
    try {
      while (rs.goToNextRow()) {
        out.push({
          cardId: rs.getLong(rs.getColumnIndex('card_id')),
          noteId: rs.getLong(rs.getColumnIndex('note_id')),
          type: rs.getLong(rs.getColumnIndex('type')),
          title: rs.getString(rs.getColumnIndex('title')),
          front: rs.getString(rs.getColumnIndex('front')),
          back: rs.getString(rs.getColumnIndex('back')),
          due: rs.getLong(rs.getColumnIndex('due')),
          reps: rs.getLong(rs.getColumnIndex('reps')),
        });
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /** 这个指纹在库里有没有(导入判断新旧卡、手工新建判断重复都用它) */
  hasFingerprint(fp: string): boolean {
    return this.scalar(SQL_HAS_FINGERPRINT, [fp] as Array<relationalStore.ValueType>) > 0;
  }

  /**
   * 手工新建时:这个牌组里是不是已经有同一个标识键的卡了。
   * 有的话插入会撞上 notes.fingerprint 的 UNIQUE —— 编辑页先问一声,给出能看懂的提示。
   * v2 之前导入的卡还是 8 位旧指纹,两种都要查。
   */
  hasCardKey(deckName: string, key: string): boolean {
    return this.hasFingerprint(fingerprintOf(deckName, key, 0)) ||
      this.hasFingerprint(legacyFingerprintOf(deckName, key, 0));
  }

  /**
   * 导入一份已解析的卡组(Task 4,docs/data-model.md §3):
   *
   *   - 牌组:先按 meta.id 认,再按名字认,都没有就新建(uuid 取 meta.id,没有就生成);
   *   - 卡片:先按 id、再按指纹认(Schema.planDeckImport,桌面测试 reimport_test 逐步对应);
   *     认出来的旧卡内容变了就更新内容,**排期不动**;新卡插入;
   *   - 文件里少了的已有卡不删,只算出数量交给界面提示。
   *
   * 整次导入一个事务:中途任何一张失败,全部回滚,库里不会留下导入了一半的文件。
   * 事务里的查询只能看见**事务开始前**就提交的行(CONTEXT 陷阱 5)—— 认卡查的正是这些,
   * 本次新插的行不需要被查到(同一文件里的重复由 planDeckImport 自己去掉)。
   */
  importDeck(parsed: ParsedDeck, sourceFile: string, now: number): StoreResult {
    const store = this.db();
    store.beginTransaction();
    try {
      const deck: DeckRef = this.resolveDeck(parsed, now);
      const inputs: ImportCardInput[] = parsed.cards.map((c: ParsedCard): ImportCardInput => {
        return { id: c.id, key: c.key, hash: cardHash(c) };
      });
      const plan: DeckImportPlan = planDeckImport(parsed.deck, inputs,
        (id: string) => this.existingNote(SQL_NOTE_BY_UUID_IN_DECK,
          [deck.id, noteUuidOf(deck.uuid, id), id] as Array<relationalStore.ValueType>),
        (fp: string) => this.existingNote(SQL_NOTE_BY_FP_IN_DECK,
          [deck.id, fp] as Array<relationalStore.ValueType>));
      const before: number = this.scalar(SQL_DECK_NOTE_COUNT, [deck.id] as Array<relationalStore.ValueType>);

      for (const u of plan.upgrades) {
        store.executeSync(SQL_UPGRADE_FINGERPRINT, [u.to, u.from] as Array<relationalStore.ValueType>);
      }
      for (const u of plan.updates) {
        const c: ParsedCard = parsed.cards[u.index];
        store.executeSync(SQL_UPDATE_NOTE_CONTENT, [
          c.type as number, c.front, c.back, c.title, c.options.join('\n'), c.answer,
          JSON.stringify(c.tags), cardHash(c), sourceFile, now, u.noteId,
        ] as Array<relationalStore.ValueType>);
      }
      let added = 0;
      for (const i of plan.fresh) {
        const c: ParsedCard = parsed.cards[i];
        // **导入进来一张,落库就是一张。**挖空数不再决定卡片数(ADR-0002)
        const uuid: string = noteUuidOf(deck.uuid, c.id.length > 0 ? c.id : this.newUuid());
        const ids: number[] = this.insertNote(deck.id, parsed.deck, c, sourceFile, uuid, now);
        added += ids.length;
      }
      store.executeSync(SQL_UPDATE_DECK_INFO, [
        JSON.stringify(parsed.tags), JSON.stringify(parsed.meta), parsed.meta.version, now, deck.id,
      ] as Array<relationalStore.ValueType>);
      store.commit();
      return {
        added: added, skipped: plan.unchanged, updated: plan.updates.length,
        missing: missingCount(before, plan),
      };
    } catch (e) {
      store.rollBack();
      hilog.error(DOMAIN, TAG, '导入失败,已回滚: %{public}s', `${e}`);
      throw new Error(`${e}`);
    }
  }

  /**
   * 把一副牌组导出成 REPS Card YAML v1 文本(Task 5)。返回 [牌组名, 文本]。
   * 与桌面测试 export_test 的 exportFrom 一步一步对应;只读内容列,不碰排期与流水。
   */
  exportDeckYaml(deckId: number): string[] {
    const rs = this.db().querySqlSync(SQL_EXPORT_DECK, [deckId]);
    let deck: ExportDeck;
    try {
      if (!rs.goToFirstRow()) {
        throw new Error(`找不到牌组 ${deckId}`);
      }
      const metaRaw: string = rs.getString(rs.getColumnIndex('meta'));
      const meta: DeckMeta = emptyMeta();
      if (metaRaw.length > 0) {
        const m: DeckMeta = JSON.parse(metaRaw) as DeckMeta;
        meta.version = typeof m.version === 'number' ? m.version : 0;
        meta.author = m.author ?? '';
        meta.language = m.language ?? '';
        meta.license = m.license ?? '';
        meta.description = m.description ?? '';
        meta.source = m.source ?? '';
        meta.generatedBy = m.generatedBy ?? '';
      }
      deck = {
        name: rs.getString(rs.getColumnIndex('name')),
        uuid: rs.getString(rs.getColumnIndex('uuid')),
        tags: parseTagsColumn(rs.getString(rs.getColumnIndex('tags'))),
        meta: meta,
      };
    } finally {
      rs.close();
    }
    const cards: ExportCard[] = [];
    const ns = this.db().querySqlSync(SQL_EXPORT_NOTES, [deckId]);
    try {
      while (ns.goToNextRow()) {
        const opts: string = ns.getString(ns.getColumnIndex('options'));
        cards.push({
          uuid: ns.getString(ns.getColumnIndex('uuid')),
          type: ns.getLong(ns.getColumnIndex('type')),
          title: ns.getString(ns.getColumnIndex('title')),
          front: ns.getString(ns.getColumnIndex('front')),
          back: ns.getString(ns.getColumnIndex('back')),
          options: opts.length > 0 ? opts.split('\n') : [],
          answer: ns.getString(ns.getColumnIndex('answer')),
          tags: parseTagsColumn(ns.getString(ns.getColumnIndex('tags'))),
        });
      }
    } finally {
      ns.close();
    }
    return [deck.name, exportYaml(deck, cards)];
  }

  /** 导入的目标牌组:先 meta.id,再名字,都没有就新建 */
  private resolveDeck(parsed: ParsedDeck, now: number): DeckRef {
    if (parsed.meta.id.length > 0) {
      const byUuid: DeckRef | null = this.deckRef(SQL_DECK_BY_UUID, parsed.meta.id);
      if (byUuid !== null) {
        return byUuid;
      }
    }
    // 同名牌组已存在(且 uuid 不同)时并进去,沿用它原来的 uuid —— 名字是 UNIQUE 的
    const byName: DeckRef | null = this.deckRef(SQL_DECK_REF_BY_NAME, parsed.deck);
    if (byName !== null) {
      return byName;
    }
    const uuid: string = parsed.meta.id.length > 0 ? parsed.meta.id : this.newUuid();
    const bucket: relationalStore.ValuesBucket = { name: parsed.deck, uuid: uuid, updated_at: now };
    return { id: this.db().insertSync('decks', bucket), uuid: uuid };
  }

  private deckRef(sql: string, arg: string): DeckRef | null {
    const rs = this.db().querySqlSync(sql, [arg]);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return { id: rs.getLong(rs.getColumnIndex('id')), uuid: rs.getString(rs.getColumnIndex('uuid')) };
    } finally {
      rs.close();
    }
  }

  private existingNote(sql: string, args: Array<relationalStore.ValueType>): ExistingNote | null {
    const rs = this.db().querySqlSync(sql, args);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return {
        noteId: rs.getLong(rs.getColumnIndex('id')),
        hash: rs.getString(rs.getColumnIndex('content_hash')),
      };
    } finally {
      rs.close();
    }
  }

  /**
   * 手工新建一张卡。题型 / 标题 / 选项 / 答案由调用方先用 Quizify 那条路解析出来
   * (见 Quizify.parseOneCard),所以手工卡与导入卡的形状完全一致。
   * 返回新卡的 card id。
   */
  insertManualCard(deckId: number, deckName: string, c: ParsedCard, now: number): number {
    const ids: number[] = this.insertNote(deckId, deckName, c, '手工添加', this.newUuid(), now);
    return ids.length > 0 ? ids[0] : 0;
  }

  /**
   * 改写一条笔记的正反面。**指纹不动** —— 内容变了但这还是同一张卡,
   * 排期与历史都该留着;改指纹会让下次重导把它当成新卡。
   */
  updateNoteText(noteId: number, c: ParsedCard, now: number): void {
    this.db().executeSync(SQL_UPDATE_NOTE_TEXT, [
      c.type as number, c.front, c.back, c.title, c.options.join('\n'), c.answer,
      now, noteId,
    ] as Array<relationalStore.ValueType>);
  }

  /** 删一条笔记连同它的卡、排期与流水。本库没开外键级联,顺序必须子表在前 */
  deleteNote(noteId: number): void {
    const d = this.db();
    const a: Array<relationalStore.ValueType> = [noteId] as Array<relationalStore.ValueType>;
    d.executeSync(SQL_TOMBSTONE_NOTE_CARDS, [Date.now(), noteId] as Array<relationalStore.ValueType>);
    d.executeSync(SQL_DELETE_NOTE_SCHED, a);
    d.executeSync(SQL_DELETE_NOTE_CARDS, a);
    d.executeSync(SQL_DELETE_NOTE, a);
  }

  // ------------------------------------------------------------ 统计

  /** 取某时刻之后的全部复习流水。分桶交给 Schema.bucketByDay(日界口径一致) */
  logsSince(since: number): LogPoint[] {
    const rs = this.db().querySqlSync(SQL_LOG_SINCE, [since]);
    const out: LogPoint[] = [];
    try {
      const iTs = rs.getColumnIndex('ts');
      const iGrade = rs.getColumnIndex('grade');
      const iCard = rs.getColumnIndex('card_id');
      while (rs.goToNextRow()) {
        out.push({
          ts: rs.getLong(iTs),
          grade: rs.getLong(iGrade),
          cardId: rs.getLong(iCard),
        });
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /**
   * 按天汇总的全部历史:**本机流水现算 + 其他设备同步下来的汇总**(ADR-0006 方案 A)。
   * 热力图、学习天数、学习时长都读它;还没同步过时其他设备为空,结果与本机完全一样。
   * anchor 必须由 Schema 的日界口径算出来(见 dayAnchor()),这样返回的 day 与 dayIndex() 同义。
   */
  dayStats(anchor: number): DayStat[] {
    return mergeDayStats(this.localDayStats(anchor), this.remoteDayStats(), this.deviceId());
  }

  /** 只算本机 review_log。同步上传 daily_stat 用它(Schema.projectDailyStats) */
  localDayStats(anchor: number): DayStat[] {
    const rs = this.db().querySqlSync(SQL_DAY_STATS, [anchor]);
    const out: DayStat[] = [];
    try {
      const iDay = rs.getColumnIndex('day');
      const iReps = rs.getColumnIndex('reps');
      const iMs = rs.getColumnIndex('ms');
      while (rs.goToNextRow()) {
        out.push({ day: rs.getLong(iDay), reps: rs.getLong(iReps), ms: rs.getLong(iMs) });
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /** 其他设备的每日汇总(同步下载后的本机缓存) */
  remoteDayStats(): DailyStatRow[] {
    const rs = this.db().querySqlSync(SQL_REMOTE_DAY_STATS);
    const out: DailyStatRow[] = [];
    try {
      while (rs.goToNextRow()) {
        out.push({
          deviceId: rs.getString(rs.getColumnIndex('device_id')),
          day: rs.getLong(rs.getColumnIndex('day')),
          reps: rs.getLong(rs.getColumnIndex('reps')),
          ms: rs.getLong(rs.getColumnIndex('ms')),
        });
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /** 同步下载的其他设备汇总写进缓存 */
  saveRemoteDayStats(rows: DailyStatRow[]): void {
    for (const r of rows) {
      this.db().executeSync(SQL_UPSERT_REMOTE_DAY_STAT,
        [r.deviceId, r.day, r.reps, r.ms] as Array<relationalStore.ValueType>);
    }
  }

  private cachedDeviceId: string = '';

  /** 本机设备 id:第一次用到时生成随机 uuid 存进 meta,之后不变。不用任何硬件标识 */
  deviceId(): string {
    if (this.cachedDeviceId.length > 0) {
      return this.cachedDeviceId;
    }
    const rs = this.db().querySqlSync(SQL_META_VALUE, [META_DEVICE_ID]);
    try {
      if (rs.goToFirstRow()) {
        this.cachedDeviceId = rs.getString(rs.getColumnIndex('value'));
      }
    } finally {
      rs.close();
    }
    if (this.cachedDeviceId.length === 0) {
      this.cachedDeviceId = this.newUuid();
      this.db().executeSync(SQL_META_SET, [META_DEVICE_ID, this.cachedDeviceId] as Array<relationalStore.ValueType>);
    }
    return this.cachedDeviceId;
  }

  /** 全量保持率。口径与 Schema.retentionOf() 相同,桌面测试盯住两者一致 */
  retentionAll(): number {
    const rs = this.db().querySqlSync(SQL_RETENTION_ALL);
    let total = 0;
    let good = 0;
    try {
      if (rs.goToNextRow()) {
        total = rs.getLong(rs.getColumnIndex('total'));
        good = rs.getLong(rs.getColumnIndex('good'));
      }
    } finally {
      rs.close();
    }
    return total === 0 ? 0 : good / total;
  }

  /** 未来 from~to 之间的到期时刻,限定卡组(0 = 不限) */
  dueForecastInDeck(deckId: number, from: number, to: number): number[] {
    const rs = this.db().querySqlSync(SQL_DUE_FORECAST_IN_DECK,
      [from, to, deckId, deckId]);
    const out: number[] = [];
    try {
      const i = rs.getColumnIndex('due');
      while (rs.goToNextRow()) {
        out.push(rs.getLong(i));
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /** 卡片稳定性,限定卡组(0 = 不限)。没答过的卡以 0 出现 */
  stabilitiesInDeck(deckId: number): number[] {
    const rs = this.db().querySqlSync(SQL_STABILITY_IN_DECK, [deckId, deckId]);
    const out: number[] = [];
    try {
      const i = rs.getColumnIndex('stability');
      while (rs.goToNextRow()) {
        out.push(rs.getDouble(i));
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /** 未来 from~to 之间的到期时刻,用于复习量预测 */
  dueForecast(from: number, to: number): number[] {
    const rs = this.db().querySqlSync(SQL_DUE_FORECAST, [from, to]);
    const out: number[] = [];
    try {
      const i = rs.getColumnIndex('due');
      while (rs.goToNextRow()) {
        out.push(rs.getLong(i));
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /** 全部卡片的稳定性,用于掌握度直方图 */
  stabilities(): number[] {
    const rs = this.db().querySqlSync(SQL_STABILITY_HISTOGRAM);
    const out: number[] = [];
    try {
      const i = rs.getColumnIndex('stability');
      while (rs.goToNextRow()) {
        out.push(rs.getDouble(i));
      }
    } finally {
      rs.close();
    }
    return out;
  }
}
