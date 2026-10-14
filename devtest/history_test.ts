/**
 * 复习流水永不删除(ADR-0005)的回归测试。
 *
 * 综合统计(总作答 / 热力图 / 学习时长 / 连续天数 / 保持率)按整个应用算:
 * 删牌组、删卡、清空进度之后,这些数一个都不能少。
 * 「清空进度」只把流水标成 archived,让该组的「今日已学」重新开始。
 */
import { DatabaseSync } from 'node:sqlite';
import {
  DDL, MIGRATE_ADD_ARCHIVED, SQL_ARCHIVE_DECK_LOGS, SQL_DAY_STATS, SQL_DELETE_DECK,
  SQL_DELETE_DECK_CARDS, SQL_DELETE_DECK_NOTES, SQL_DELETE_DECK_SCHED, SQL_HAS_ARCHIVED_COL,
  SQL_RETENTION_ALL, SQL_REVIEWED_TODAY, dayAnchor,
} from './Schema';

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: string): void {
  if (ok) { pass++; console.log(`  PASS  ${name}${detail ? '  ' + detail : ''}`); }
  else { fail++; console.log(`  FAIL  ${name}${detail ? '  ' + detail : ''}`); }
}
interface NRow { n: number }

console.log('=== 1. 旧库迁移:补 archived 列 ===');
const old = new DatabaseSync(':memory:');
old.exec(`CREATE TABLE review_log (id INTEGER PRIMARY KEY AUTOINCREMENT, card_id INTEGER NOT NULL,
  ts INTEGER NOT NULL, grade INTEGER NOT NULL, cost_ms INTEGER NOT NULL DEFAULT 0)`);
old.exec(`INSERT INTO review_log (card_id, ts, grade, cost_ms) VALUES (1, 100, 2, 5)`);
check('迁移前没有 archived', (old.prepare(SQL_HAS_ARCHIVED_COL).get() as NRow).n === 0);
old.exec(MIGRATE_ADD_ARCHIVED);
check('迁移后有 archived', (old.prepare(SQL_HAS_ARCHIVED_COL).get() as NRow).n === 1);
check('旧流水 archived 默认为 0,一条不丢',
  (old.prepare(`SELECT COUNT(*) AS n FROM review_log WHERE archived = 0`).get() as NRow).n === 1);
old.close();

console.log('\n=== 2. 删牌组 / 清空进度后综合统计不变 ===');
const db = new DatabaseSync(':memory:');
for (const s of DDL) { db.exec(s); }
check('新库直接带 archived 列', (db.prepare(SQL_HAS_ARCHIVED_COL).get() as NRow).n === 1);
db.exec(`INSERT INTO decks (id, name) VALUES (1, 'A'), (2, 'B')`);
for (let i = 1; i <= 4; i++) {
  const deck = i <= 2 ? 1 : 2;
  db.exec(`INSERT INTO notes (id, deck_id, type, front, back, title, options, answer, source_file,
           fingerprint, uuid, updated_at) VALUES (${i}, ${deck}, 0, 'f', 'b', '', '', '', 'x', 'fp${i}', 'n${i}', 0)`);
  db.exec(`INSERT INTO cards (id, note_id, ordinal, uuid, updated_at) VALUES (${i}, ${i}, 0, 'c${i}', 0)`);
  db.exec(`INSERT INTO scheduling (card_id, due, last_review) VALUES (${i}, 9e12, 1000)`);
}
const now = Date.UTC(2026, 9, 14, 6, 0);
const D = 86400000;
let ts = now - 3 * D;
for (const [card, grade, ms] of [[1, 0, 60000], [1, 2, 30000], [2, 3, 20000], [3, 2, 120000], [3, 2, 60000], [4, 1, 10000]]) {
  db.exec(`INSERT INTO review_log (card_id, ts, grade, cost_ms) VALUES (${card}, ${ts}, ${grade}, ${ms})`);
  ts += D / 2;
}
interface DayRow { day: number; reps: number; ms: number }
interface RetRow { total: number; good: number }
function overall(): string {
  const days = db.prepare(SQL_DAY_STATS).all(dayAnchor(now)) as DayRow[];
  const reps = days.reduce((a, d) => a + d.reps, 0);
  const ms = days.reduce((a, d) => a + d.ms, 0);
  const r = db.prepare(SQL_RETENTION_ALL).get() as RetRow;
  return `reps=${reps} ms=${ms} days=${days.length} ret=${r.good}/${r.total}`;
}
const before = overall();
console.log(`  基线 ${before}`);

// 清空 A 的进度
db.prepare(SQL_ARCHIVE_DECK_LOGS).run(1);
db.prepare(SQL_DELETE_DECK_SCHED).run(1);
check('**清空进度后综合统计一个数都不变**', overall() === before, overall());
check('A 组的流水被归档', (db.prepare(`SELECT COUNT(*) AS n FROM review_log WHERE archived = 1`).get() as NRow).n === 3);
// 今日已学:A 组今天(ts>=now-3D)的卡不再出现
const reviewedA = db.prepare(SQL_REVIEWED_TODAY).all(0, 0, 1, 1, 0, 100) as Array<{ card_id: number }>;
check('**A 组「今日已学」不再列出已归档的卡**', reviewedA.length === 0, `${reviewedA.length}`);
const reviewedB = db.prepare(SQL_REVIEWED_TODAY).all(0, 0, 2, 2, 0, 100) as Array<{ card_id: number }>;
check('B 组「今日已学」不受影响', reviewedB.length === 2, `${reviewedB.length}`);

// 删掉 B 整组
for (const sql of [SQL_DELETE_DECK_SCHED, SQL_DELETE_DECK_CARDS, SQL_DELETE_DECK_NOTES, SQL_DELETE_DECK]) {
  db.prepare(sql).run(2);
}
check('**删牌组后综合统计一个数都不变**', overall() === before, overall());
check('B 组的卡确实删了', (db.prepare(`SELECT COUNT(*) AS n FROM cards WHERE id IN (3, 4)`).get() as NRow).n === 0);

// 新卡不会认领旧流水:AUTOINCREMENT 不复用 id
db.exec(`INSERT INTO notes (deck_id, type, front, back, title, options, answer, source_file,
         fingerprint, uuid, updated_at) VALUES (1, 0, 'g', 'h', '', '', '', 'x', 'fpN', 'nN', 0)`);
db.exec(`INSERT INTO cards (note_id, ordinal, uuid, updated_at) VALUES (last_insert_rowid(), 0, 'cN', 0)`);
const newId = (db.prepare(`SELECT MAX(id) AS n FROM cards`).get() as NRow).n;
check('新卡 id 不复用被删的 3、4', newId > 4, `${newId}`);
db.close();

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
if (fail > 0) { process.exit(1); }
