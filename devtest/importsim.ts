/**
 * 桌面测试共用:在 v2 结构上模拟 Database.importDeck。
 *
 * 与 Database.importDeck 一步一步对应,用的是生产那份 SQL 与 Schema.planDeckImport ——
 * 生产代码改了导入步骤,这里要跟着改(reimport_test / export_test 都靠它)。
 */
import { DatabaseSync } from 'node:sqlite';
import {
  DDL, DeckImportPlan, ExistingNote, ImportCardInput, MIGRATIONS, SQL_DECK_BY_UUID, SQL_DECK_NOTE_COUNT,
  SQL_DECK_REF_BY_NAME, SQL_INSERT_NOTE_V2, SQL_NOTE_BY_FP_IN_DECK, SQL_NOTE_BY_UUID_IN_DECK,
  SQL_UPDATE_DECK_INFO, SQL_UPDATE_NOTE_CONTENT, SQL_UPGRADE_FINGERPRINT, contentHashOf, fingerprintOf,
  missingCount, noteUuidOf, planDeckImport,
} from './Schema';
import { ParsedCard, ParsedDeck } from './Quizify';

export function freshDb(): DatabaseSync {
  const db = new DatabaseSync(':memory:');
  for (const s of DDL) {
    db.exec(s);
  }
  for (const m of MIGRATIONS) {
    for (const s of m.statements) {
      db.exec(s);
    }
  }
  return db;
}

export interface SimResult {
  added: number;
  updated: number;
  unchanged: number;
  missing: number;
  deckId: number;
  deckUuid: string;
}

let rnd = 0;
export function hashOf(c: ParsedCard): string {
  return contentHashOf(c.type, c.title, c.front, c.back, c.options, c.answer, c.tags);
}

/** failAt >= 0 时在插第 failAt 张新卡前抛错(测回滚) */
export function importParsed(db: DatabaseSync, parsed: ParsedDeck, now: number, failAt: number = -1): SimResult {
  db.exec('BEGIN');
  try {
    // 1. 牌组:先 meta.id,再名字,都没有就新建
    let ref = parsed.meta.id.length > 0
      ? db.prepare(SQL_DECK_BY_UUID).get(parsed.meta.id) as { id: number; uuid: string } | undefined
      : undefined;
    if (ref === undefined) {
      ref = db.prepare(SQL_DECK_REF_BY_NAME).get(parsed.deck) as { id: number; uuid: string } | undefined;
    }
    if (ref === undefined) {
      const uuid = parsed.meta.id.length > 0 ? parsed.meta.id : `deck-${++rnd}`;
      const r = db.prepare(`INSERT INTO decks (name, uuid, updated_at) VALUES (?, ?, ?)`).run(parsed.deck, uuid, now);
      ref = { id: Number(r.lastInsertRowid), uuid: uuid };
    }
    const deckId = ref.id;
    const deckUuid = ref.uuid;

    // 2. 规划
    const inputs: ImportCardInput[] = parsed.cards.map((c) => ({ id: c.id, key: c.key, hash: hashOf(c) }));
    const look = (row: unknown): ExistingNote | null => {
      const r = row as { id: number; content_hash: string } | undefined;
      return r === undefined ? null : { noteId: r.id, hash: r.content_hash };
    };
    const plan: DeckImportPlan = planDeckImport(parsed.deck, inputs,
      (id) => look(db.prepare(SQL_NOTE_BY_UUID_IN_DECK).get(deckId, noteUuidOf(deckUuid, id), id)),
      (fp) => look(db.prepare(SQL_NOTE_BY_FP_IN_DECK).get(deckId, fp)));
    const before = (db.prepare(SQL_DECK_NOTE_COUNT).get(deckId) as { n: number }).n;

    // 3. 写
    for (const u of plan.upgrades) {
      db.prepare(SQL_UPGRADE_FINGERPRINT).run(u.to, u.from);
    }
    for (const u of plan.updates) {
      const c = parsed.cards[u.index];
      db.prepare(SQL_UPDATE_NOTE_CONTENT).run(c.type, c.front, c.back, c.title, c.options.join('\n'), c.answer,
        JSON.stringify(c.tags), hashOf(c), 'test', now, u.noteId);
    }
    let n = 0;
    for (const i of plan.fresh) {
      if (n === failAt) {
        throw new Error('模拟中途失败');
      }
      n++;
      const c = parsed.cards[i];
      const uuid = noteUuidOf(deckUuid, c.id.length > 0 ? c.id : `gen-${++rnd}`);
      const r = db.prepare(SQL_INSERT_NOTE_V2).run(deckId, c.type, c.front, c.back, c.title, c.options.join('\n'),
        c.answer, 'test', fingerprintOf(parsed.deck, c.key, 0), uuid, now, hashOf(c), JSON.stringify(c.tags));
      db.prepare(`INSERT INTO cards (note_id, ordinal, uuid, updated_at) VALUES (?, 0, ?, ?)`)
        .run(Number(r.lastInsertRowid), uuid, now);
    }
    db.prepare(SQL_UPDATE_DECK_INFO).run(JSON.stringify(parsed.tags), JSON.stringify(parsed.meta),
      parsed.meta.version, now, deckId);
    db.exec('COMMIT');
    return {
      added: plan.fresh.length, updated: plan.updates.length, unchanged: plan.unchanged,
      missing: missingCount(before, plan), deckId: deckId, deckUuid: deckUuid,
    };
  } catch (e) {
    db.exec('ROLLBACK');
    throw e;
  }
}
