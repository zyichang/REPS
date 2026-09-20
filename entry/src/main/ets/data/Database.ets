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
  DDL, ReviewCardRow, SQL_COUNT_CARDS, SQL_COUNT_DUE, SQL_COUNT_NEW, SQL_DUE_CARDS,
  SQL_INSERT_CARD, SQL_INSERT_DECK, SQL_INSERT_LOG, SQL_INSERT_NOTE, SQL_NEW_CARDS,
  SQL_SELECT_DECK_ID, SQL_SELECT_NOTE_BY_CARD, SQL_SELECT_SCHEDULING,
  SQL_UPSERT_SCHEDULING, SchedulingRow, fingerprintOf, fromSchedulingRow,
  isValidAlgo, makeUuid, schedulingValues, toSchedulingRow,
} from './Schema';

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
    hilog.info(DOMAIN, TAG, '数据库就绪,已执行 %{public}d 条 DDL', DDL.length);
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

  /** 取得卡组 id,不存在则创建 */
  ensureDeck(name: string, parentId: number): number {
    this.db().executeSync(SQL_INSERT_DECK, [name, parentId] as Array<relationalStore.ValueType>);
    const rs = this.db().querySqlSync(SQL_SELECT_DECK_ID, [name, parentId]);
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

  cardCount(): number {
    const rs = this.db().querySqlSync(SQL_COUNT_CARDS);
    try {
      rs.goToFirstRow();
      return rs.getLong(rs.getColumnIndex('n'));
    } finally {
      rs.close();
    }
  }
}
