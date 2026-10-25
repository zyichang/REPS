/**
 * Schema v2 迁移的回归测试(ADR-0007 / docs/data-model.md)。
 *
 * 用生产那份 DDL(= v1 基线)建库、填一副带进度的牌组,再跑生产那份 MIGRATIONS,
 * 断言:行数与学习进度一字不差、新列都在、旧牌组补上了 uuid、重复启动不重复迁移、
 * 64 位指纹不再撞车、v1 旧指纹能被导入时认出并升级。
 */
import { DatabaseSync } from 'node:sqlite';
import {
  DDL, MIGRATIONS, SCHEMA_VERSION, SQL_FILL_DECK_UUID, SQL_INSERT_DECK, fingerprintOf,
  legacyFingerprintOf, pendingMigrations, planImport,
} from './Schema';

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: string): void {
  if (ok) {
    pass++;
    console.log(`  PASS  ${name}${detail ? '  ' + detail : ''}`);
  } else {
    fail++;
    console.log(`  FAIL  ${name}${detail ? '  ' + detail : ''}`);
  }
}

function userVersion(db: DatabaseSync): number {
  return (db.prepare('PRAGMA user_version').get() as { user_version: number }).user_version;
}

/** 模拟 Database.migrate():按 user_version 只跑没跑过的,每个版本一个事务 */
function migrate(db: DatabaseSync): number {
  let ran = 0;
  for (const m of pendingMigrations(userVersion(db))) {
    db.exec('BEGIN');
    try {
      for (const s of m.statements) {
        db.exec(s);
      }
      db.exec('COMMIT');
    } catch (e) {
      db.exec('ROLLBACK');
      throw e;
    }
    db.exec(`PRAGMA user_version = ${m.version}`);
    ran++;
  }
  return ran;
}

function cols(db: DatabaseSync, table: string): string[] {
  return (db.prepare(`SELECT name FROM pragma_table_info('${table}')`).all() as { name: string }[])
    .map((r) => r.name);
}
function count(db: DatabaseSync, sql: string): number {
  return (db.prepare(sql).get() as { n: number }).n;
}

// ---------------------------------------------------------------- 1. 老库
console.log('=== 1. v1 老库迁移:数据一字不差 ===');
const db = new DatabaseSync(':memory:');
for (const s of DDL) {
  db.exec(s);
}
db.exec(`INSERT INTO decks (id, name) VALUES (1, 'Math'), (2, 'Words')`);
const oldFp = legacyFingerprintOf('Math', '基础选择 (1)', 0);
db.exec(`INSERT INTO notes (id, deck_id, front, title, fingerprint, uuid, updated_at)
         VALUES (1, 1, 'q1', '基础选择 (1)', '${oldFp}', 'n-old-1', 1000),
                (2, 1, 'q2', '基础选择 (2)', '${legacyFingerprintOf('Math', '基础选择 (2)', 0)}', 'n-old-2', 2000),
                (3, 2, 'w1', 'apple', '${legacyFingerprintOf('Words', 'apple', 0)}', 'n-old-3', 500)`);
db.exec(`INSERT INTO cards (id, note_id, uuid) VALUES (1, 1, 'c-old-1'), (2, 2, 'c-old-2'), (3, 3, 'c-old-3')`);
db.exec(`INSERT INTO scheduling (card_id, stability, difficulty, reps, last_review, due)
         VALUES (1, 2.5, 4.1, 3, 7000, 9000)`);
db.exec(`INSERT INTO review_log (card_id, ts, grade) VALUES (1, 5000, 3), (1, 6000, 3), (1, 7000, 4)`);
db.exec(`INSERT INTO checkins (day, ts) VALUES (100, 5000)`);

const before = {
  notes: count(db, 'SELECT COUNT(*) AS n FROM notes'),
  cards: count(db, 'SELECT COUNT(*) AS n FROM cards'),
  logs: count(db, 'SELECT COUNT(*) AS n FROM review_log'),
  sched: JSON.stringify(db.prepare('SELECT * FROM scheduling').all()),
  uuids: JSON.stringify(db.prepare('SELECT uuid FROM notes UNION ALL SELECT uuid FROM cards').all()),
};

check('老库 user_version 是 0', userVersion(db) === 0);
check('有 1 个待迁移版本', pendingMigrations(0).length === MIGRATIONS.length && MIGRATIONS.length >= 1);
const ran = migrate(db);
check(`迁移后 user_version = ${SCHEMA_VERSION}`, userVersion(db) === SCHEMA_VERSION, `${userVersion(db)}`);
check('跑了全部迁移', ran === MIGRATIONS.length, `${ran}`);

check('笔记数不变', count(db, 'SELECT COUNT(*) AS n FROM notes') === before.notes);
check('卡片数不变', count(db, 'SELECT COUNT(*) AS n FROM cards') === before.cards);
check('流水数不变', count(db, 'SELECT COUNT(*) AS n FROM review_log') === before.logs);
check('打卡不变', count(db, 'SELECT COUNT(*) AS n FROM checkins') === 1);
const schedAfter = db.prepare(
  `SELECT card_id, stability, difficulty, reps, lapses, streak, last_review, due, phase, step, first_seen
     FROM scheduling`).all();
check('排期原有列一字不差', JSON.stringify(schedAfter) === before.sched, JSON.stringify(schedAfter));
check('笔记/卡片 uuid 没有重新生成',
  JSON.stringify(db.prepare('SELECT uuid FROM notes UNION ALL SELECT uuid FROM cards').all()) === before.uuids);

const dc = cols(db, 'decks');
for (const c of ['uuid', 'version', 'meta', 'tags', 'updated_at', 'deleted_at']) {
  check(`decks 有 ${c} 列`, dc.includes(c));
}
const nc = cols(db, 'notes');
for (const c of ['content_hash', 'tags', 'deleted_at']) {
  check(`notes 有 ${c} 列`, nc.includes(c));
}
check('scheduling 有 updated_at 列', cols(db, 'scheduling').includes('updated_at'));

const deckUuids = db.prepare('SELECT uuid FROM decks ORDER BY id').all() as { uuid: string }[];
const uuidRe = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
check('旧牌组都补上了 uuid(v4 格式)', deckUuids.every((r) => uuidRe.test(r.uuid)), JSON.stringify(deckUuids));
check('两个牌组的 uuid 不同', deckUuids[0].uuid !== deckUuids[1].uuid);
check('牌组 updated_at 回填为笔记最新时刻',
  count(db, `SELECT updated_at AS n FROM decks WHERE id = 1`) === 2000);
check('排期 updated_at 回填为 last_review',
  count(db, `SELECT updated_at AS n FROM scheduling WHERE card_id = 1`) === 7000);
check('tags 默认空列表', count(db, `SELECT COUNT(*) AS n FROM notes WHERE tags = '[]'`) === 3);

// ---------------------------------------------------------------- 2. 重复启动
console.log('=== 2. 重复启动不重复迁移 ===');
check('第二次启动没有待迁移版本', pendingMigrations(userVersion(db)).length === 0);
check('第二次 migrate 什么都不跑', migrate(db) === 0);
const uuidsAgain = JSON.stringify(db.prepare('SELECT uuid FROM decks ORDER BY id').all());
check('牌组 uuid 不会被重新生成', uuidsAgain === JSON.stringify(deckUuids));

// ---------------------------------------------------------------- 3. 新库
console.log('=== 3. 全新安装:同一条路径 ===');
const fresh = new DatabaseSync(':memory:');
for (const s of DDL) {
  fresh.exec(s);
}
migrate(fresh);
check('新库也到 v2', userVersion(fresh) === SCHEMA_VERSION);
// 新建牌组走生产 SQL:先 INSERT(只给名字),再补 uuid
fresh.prepare(SQL_INSERT_DECK).run('A');
fresh.prepare(SQL_FILL_DECK_UUID).run('11111111-1111-4111-8111-111111111111', 1234, 'A');
fresh.prepare(SQL_INSERT_DECK).run('B');
fresh.prepare(SQL_FILL_DECK_UUID).run('22222222-2222-4222-8222-222222222222', 1234, 'B');
check('新建两个牌组,uuid 各自写入',
  count(fresh, `SELECT COUNT(DISTINCT uuid) AS n FROM decks WHERE uuid <> ''`) === 2);
fresh.prepare(SQL_FILL_DECK_UUID).run('33333333-3333-4333-8333-333333333333', 9999, 'A');
check('已有 uuid 的牌组不会被覆盖',
  (fresh.prepare(`SELECT uuid FROM decks WHERE name = 'A'`).get() as { uuid: string }).uuid
    === '11111111-1111-4111-8111-111111111111');
let dupRejected = false;
try {
  fresh.exec(`UPDATE decks SET uuid = '11111111-1111-4111-8111-111111111111' WHERE name = 'B'`);
} catch {
  dupRejected = true;
}
check('牌组 uuid 唯一', dupRejected);

// ---------------------------------------------------------------- 4. 64 位指纹
console.log('=== 4. 64 位指纹 ===');
// 生日攻击:找一对在 v1 32 位下撞车的标识键。
// 键用伪随机串(固定种子):FNV-1a 对「只差末尾数字」的顺序键分布得特别均匀,反而很难撞
const seen = new Map<string, string>();
let pair: [string, string] | null = null;
let seed = 12345;
function nextKey(): string {
  seed = (Math.imul(seed, 1103515245) + 12345) >>> 0;
  const a = seed;
  seed = (Math.imul(seed, 1103515245) + 12345) >>> 0;
  return `k${a.toString(36)}${seed.toString(36)}`;
}
for (let i = 0; i < 1000000 && pair === null; i++) {
  const k = nextKey();
  const h = legacyFingerprintOf('Big', k, 0);
  const prev = seen.get(h);
  if (prev !== undefined && prev !== k) {
    pair = [prev, k];
  }
  seen.set(h, k);
}
check('能构造出 32 位撞车的一对键', pair !== null, pair ? pair.join(' / ') : '');
if (pair !== null) {
  check('这一对在 32 位下确实相同',
    legacyFingerprintOf('Big', pair[0], 0) === legacyFingerprintOf('Big', pair[1], 0));
  check('64 位下不再相同', fingerprintOf('Big', pair[0], 0) !== fingerprintOf('Big', pair[1], 0),
    `${fingerprintOf('Big', pair[0], 0)} vs ${fingerprintOf('Big', pair[1], 0)}`);
}
const all64 = new Set<string>();
for (let i = 0; i < 100000; i++) {
  all64.add(fingerprintOf('Big', `card-${i}`, 0));
}
check('10 万个键 64 位指纹零撞车', all64.size === 100000, `${all64.size}`);
check('新指纹前 8 位就是旧指纹(便于排查)',
  fingerprintOf('Math', 'x', 0).startsWith(legacyFingerprintOf('Math', 'x', 0)));

// ---------------------------------------------------------------- 5. 旧指纹惰性升级
console.log('=== 5. v1 旧指纹在导入时被认出并升级 ===');
function exists(fp: string): boolean {
  return count(db, `SELECT COUNT(*) AS n FROM notes WHERE fingerprint = '${fp}'`) > 0;
}
const plan = planImport('Math', ['基础选择 (1)', '基础选择 (2)', '基础选择 (3)'], exists);
check('两张旧卡跳过、一张新卡', plan.skipped === 2 && plan.fresh.length === 1 && plan.fresh[0] === 2,
  `fresh=${plan.fresh} skipped=${plan.skipped}`);
check('两条升级', plan.upgrades.length === 2, JSON.stringify(plan.upgrades));
check('升级的源是 v1 指纹', plan.upgrades[0].from === oldFp);
check('升级的目标是 64 位指纹', plan.upgrades[0].to === fingerprintOf('Math', '基础选择 (1)', 0));
for (const u of plan.upgrades) {
  db.prepare(`UPDATE notes SET fingerprint = ? WHERE fingerprint = ?`).run(u.to, u.from);
}
const plan2 = planImport('Math', ['基础选择 (1)', '基础选择 (2)'], exists);
check('升级之后再导入:直接按新指纹认出,不再需要升级',
  plan2.skipped === 2 && plan2.upgrades.length === 0);

console.log(`\n结果: ${pass} 通过, ${fail} 失败`);
process.exit(fail === 0 ? 0 : 1);
