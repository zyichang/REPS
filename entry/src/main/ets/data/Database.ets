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
  CardBrief, DDL, DayStat, DeckRow, LogPoint, MIGRATE_FLATTEN_DECKS, ReviewCardRow,
  ReviewedCard, SQL_AHEAD_CARDS, SQL_AHEAD_CARDS_IN_DECK, SQL_COUNT_CARDS,
  SQL_COUNT_CARDS_IN_DECK, SQL_COUNT_DUE, SQL_COUNT_NEW, SQL_DAY_STATS, SQL_DECK_NOTE_COUNT,
  SQL_DELETE_DECK, SQL_DELETE_DECK_CARDS, SQL_DELETE_DECK_LOGS, SQL_DELETE_DECK_NOTES,
  SQL_DELETE_DECK_SCHED, SQL_DELETE_NOTE, SQL_DELETE_NOTE_CARDS, SQL_DELETE_NOTE_LOGS,
  SQL_DELETE_NOTE_SCHED, SQL_DUE_CARDS, SQL_DUE_CARDS_IN_DECK, SQL_DUE_FORECAST,
  SQL_DUE_FORECAST_IN_DECK, SQL_HAS_PARENT_COL, SQL_INSERT_CARD, SQL_INSERT_DECK,
  SQL_INSERT_LOG, SQL_INSERT_NOTE, SQL_LIST_CARDS_ALL, SQL_LIST_CARDS_IN_DECK, SQL_LIST_DECKS,
  SQL_LOG_SINCE, SQL_NEW_CARDS, SQL_NEW_CARDS_IN_DECK, SQL_NEW_INTRODUCED_TODAY,
  SQL_RETENTION_ALL, SQL_REVIEWED_TODAY, SQL_SELECT_DECK_ID, SQL_SELECT_DECK_NAME,
  SQL_SELECT_NOTE_BY_CARD, SQL_SELECT_SCHEDULING, SQL_STABILITY_HISTOGRAM,
  SQL_STABILITY_IN_DECK, SQL_TODAY_PROGRESS, SQL_UNLEARNED_COUNT, SQL_UNTOUCHED_DUE,
  SQL_UPDATE_NOTE_TEXT, SQL_UPSERT_SCHEDULING, SchedulingRow, TodayProgress, fingerprintOf,
  fromSchedulingRow, isValidAlgo, makeUuid, schedulingValues, toSchedulingRow,
} from './Schema';
import { ParsedCard } from './Quizify';

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
    hilog.info(DOMAIN, TAG, '数据库就绪,已执行 %{public}d 条 DDL', DDL.length);
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

  /** 取得卡组 id,不存在则创建。卡组是平的,所以只按名字认 */
  ensureDeck(name: string): number {
    this.db().executeSync(SQL_INSERT_DECK, [name] as Array<relationalStore.ValueType>);
    const rs = this.db().querySqlSync(SQL_SELECT_DECK_ID, [name]);
    try {
      if (!rs.goToFirstRow()) {
        throw new Error(`卡组创建失败: ${name}`);
      }
      return rs.getLong(rs.getColumnIndex('id'));
    } finally {
      rs.close();
    }
  }

  /**
   * 写入一条笔记及其卡片,返回卡片 id 列表。
   *
   * title 与 key 是两回事,不能混:
   *   title 是 #### 的完整原文,给人看的(含题干);
   *   key   是标识部分(如「基础选择 (1)」),指纹取它。
   * 用 title 算指纹的话,用户改一个错别字就会被当成新卡,进度全丢。
   *
   * cardCount 由题型决定:问答与选择题恒为 1,完形填空等于挖空个数。
   */
  insertNote(deckId: number, deckName: string, type: NoteType, front: string, back: string,
             title: string, key: string, options: string[], answer: string,
             sourceFile: string, cardCount: number, now: number): number[] {
    const noteId: number = this.insertNoteRow(deckId, deckName, type, front, back,
      title, key, options, answer, sourceFile, 0, now);
    const ids: number[] = [];
    for (let i = 0; i < cardCount; i++) {
      this.db().executeSync(SQL_INSERT_CARD,
        [noteId, i, makeUuid('c', now), now] as Array<relationalStore.ValueType>);
      ids.push(this.lastInsertId('cards'));
    }
    return ids;
  }

  private insertNoteRow(deckId: number, deckName: string, type: NoteType, front: string,
                        back: string, title: string, key: string, options: string[],
                        answer: string, sourceFile: string, ordinal: number,
                        now: number): number {
    const fp: string = fingerprintOf(deckName, key, ordinal);
    this.db().executeSync(SQL_INSERT_NOTE, [
      deckId, type as number, front, back, title, options.join('\n'), answer,
      sourceFile, fp, makeUuid('n', now), now,
    ] as Array<relationalStore.ValueType>);
    return this.lastInsertId('notes');
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

  private lastInsertId(table: string): number {
    // 只读一个标量,不值得为它在 Schema 里单开常量;表名由调用方给定,不来自外部输入
    const rs = this.db().querySqlSync(`SELECT MAX(id) AS id FROM ${table}`);
    try {
      rs.goToFirstRow();
      return rs.getLong(rs.getColumnIndex('id'));
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
    d.executeSync(SQL_DELETE_DECK_LOGS, [deckId] as Array<relationalStore.ValueType>);
    d.executeSync(SQL_DELETE_DECK_SCHED, [deckId] as Array<relationalStore.ValueType>);
    d.executeSync(SQL_DELETE_DECK_CARDS, [deckId] as Array<relationalStore.ValueType>);
    d.executeSync(SQL_DELETE_DECK_NOTES, [deckId] as Array<relationalStore.ValueType>);
    d.executeSync(SQL_DELETE_DECK, [deckId] as Array<relationalStore.ValueType>);
  }

  /**
   * 清空一个卡组的学习进度:**删排期和复习流水,卡片本身一张不动。**
   *
   * 清完之后这一组的卡全部变回「新卡」 —— 因为「是不是新卡」看的就是
   * 有没有 scheduling 行。热力图里属于这一组的历史也会一起消失,
   * 那是有意的:留着会让统计和实际进度对不上。
   *
   * 这是**不可撤销**的操作,调用方必须先让用户确认。
   */
  clearDeckProgress(deckId: number): void {
    const d = this.db();
    const a: Array<relationalStore.ValueType> = [deckId] as Array<relationalStore.ValueType>;
    d.executeSync(SQL_DELETE_DECK_LOGS, a);
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

  /**
   * 手工新建一张卡。题型 / 标题 / 选项 / 答案由调用方先用 Quizify 那条路解析出来
   * (见 Quizify.parseOneCard),所以手工卡与导入卡的形状完全一致。
   * 返回新卡的 card id。
   */
  insertManualCard(deckId: number, deckName: string, c: ParsedCard, now: number): number {
    const ids: number[] = this.insertNote(deckId, deckName, c.type, c.front, c.back,
      c.title, c.key, c.options, c.answer, '手工添加', 1, now);
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
    d.executeSync(SQL_DELETE_NOTE_LOGS, a);
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
   * 按天汇总的全部历史。anchor 必须由 Schema 的日界口径算出来
   * (见 dayAnchor()),这样返回的 day 与 dayIndex() 同义。
   */
  dayStats(anchor: number): DayStat[] {
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
