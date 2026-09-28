/**
 * 统计口径的回归测试。
 *
 * 这一套盯的是同一个风险:**同一个指标在两个地方各写了一套算法。**
 * 统计页原来把全部流水读进内存、在 TS 里分桶算保持率;改成全量之后
 * 换成 SQL 聚合。两份实现只要对不上,页面上的数字就会和「用一条 SQL
 * 查出来的真值」不一致 —— 而这正是 WordSnap 当年那个统计 bug 的形状。
 *
 * 所以这里不只测 SQL 自己对不对,更要测**SQL 和 TS 给出同一个答案**。
 */
import { DatabaseSync } from 'node:sqlite';
import {
  DDL, LogPoint, SQL_DAY_STATS, SQL_DUE_FORECAST_IN_DECK, SQL_RETENTION_ALL,
  MIGRATE_FLATTEN_DECKS, SQL_HAS_PARENT_COL,
  SQL_STABILITY_IN_DECK, dayAnchor, dayIndex, retentionOf,
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

const db = new DatabaseSync(':memory:');
for (const stmt of DDL) {
  db.exec(stmt);
}

// 两个卡组:1 号 3 张,2 号 2 张
db.exec(`INSERT INTO decks (id, name) VALUES (1, 'A'), (2, 'B')`);
function addCard(id: number, deck: number): void {
  db.exec(`INSERT INTO notes (id, deck_id, type, front, back, title, options, answer,
           source_file, fingerprint, uuid, updated_at)
           VALUES (${id}, ${deck}, 0, 'f', 'b', 't${id}', '', '', 'x.md',
                   'fp${id}', 'n${id}', 0)`);
  db.exec(`INSERT INTO cards (id, note_id, ordinal, uuid, updated_at)
           VALUES (${id}, ${id}, 0, 'c${id}', 0)`);
}
addCard(1, 1);
addCard(2, 1);
addCard(3, 1);
addCard(4, 2);
addCard(5, 2);

console.log('=== 1. 日界锚点:SQL 里的 day 必须与 dayIndex() 同义 ===');

// 挑几个刁钻的时刻:凌晨 0:30(按口径应归前一天)、1:30、正午、深夜
const stamps: number[] = [
  Date.UTC(2026, 0, 15, 16, 30),
  Date.UTC(2026, 0, 15, 17, 30),
  Date.UTC(2026, 0, 16, 4, 0),
  Date.UTC(2026, 0, 16, 15, 59),
  Date.UTC(2026, 5, 1, 2, 0),
];
let logId = 0;
for (const ts of stamps) {
  logId++;
  db.exec(`INSERT INTO review_log (id, card_id, ts, grade, stability_before, elapsed_days,
           retrievability, interval_days, cost_ms, algo)
           VALUES (${logId}, 1, ${ts}, 2, 1, 0, 0.9, 1, ${1000 * logId}, 'fsrs')`);
}
const anchor: number = dayAnchor(Date.now());
interface DayRow { day: number; reps: number; ms: number }
const rows = db.prepare(SQL_DAY_STATS).all(anchor) as DayRow[];

let dayMatch = true;
for (const ts of stamps) {
  const want: number = dayIndex(ts);
  const got = rows.find((r) => r.day === want);
  if (!got) {
    dayMatch = false;
  }
}
check('每个时刻都落进 dayIndex() 算出来的那一天', dayMatch,
  `SQL 返回 ${rows.length} 天,dayIndex 期望 ${new Set(stamps.map((t) => dayIndex(t))).size} 天`);
check('天数 = dayIndex 去重后的天数',
  rows.length === new Set(stamps.map((t) => dayIndex(t))).size,
  `${rows.length}`);

const totalReps: number = rows.reduce((a, r) => a + r.reps, 0);
const totalMs: number = rows.reduce((a, r) => a + r.ms, 0);
check('作答次数求和 = 流水条数', totalReps === stamps.length, `${totalReps}`);
check('耗时求和 = 各条 cost_ms 之和', totalMs === 1000 + 2000 + 3000 + 4000 + 5000,
  `${totalMs} ms`);

console.log('\n=== 2. 全量保持率:SQL 与 retentionOf() 必须一致 ===');

// 再堆一些流水,覆盖「同一张卡多次」「首答必须排除」「不同评级」
db.exec(`DELETE FROM review_log`);
const seq: Array<[number, number, number]> = [
  // [card_id, ts, grade]
  [1, 1000, 0],
  [1, 2000, 2],
  [1, 3000, 3],
  [2, 1500, 3],
  [2, 2500, 1],
  [3, 1800, 0],
  [3, 2800, 0],
  [3, 3800, 2],
];
logId = 0;
for (const [card, ts, grade] of seq) {
  logId++;
  db.exec(`INSERT INTO review_log (id, card_id, ts, grade, stability_before, elapsed_days,
           retrievability, interval_days, cost_ms, algo)
           VALUES (${logId}, ${card}, ${ts}, ${grade}, 1, 0, 0.9, 1, 100, 'fsrs')`);
}

interface RetRow { total: number; good: number }
const rr = db.prepare(SQL_RETENTION_ALL).get() as RetRow;
const sqlRetention: number = rr.total === 0 ? 0 : rr.good / rr.total;

// TS 那一份:按 ts 升序喂进去
const points: LogPoint[] = seq
  .map((x) => ({ cardId: x[0], ts: x[1], grade: x[2] } as LogPoint))
  .sort((a, b) => a.ts - b.ts);
const tsRetention: number = retentionOf(points);

check('**SQL 保持率 === retentionOf()**(两套定义不许漂移)',
  Math.abs(sqlRetention - tsRetention) < 1e-9,
  `SQL ${(sqlRetention * 100).toFixed(1)}% vs TS ${(tsRetention * 100).toFixed(1)}%`);
check('分母排除了每张卡的首答', rr.total === seq.length - 3,
  `${rr.total}(共 ${seq.length} 条,3 张卡各排除 1 条首答)`);
check('分子只数评级 >= 良好的', rr.good === 3, `${rr.good}`);

console.log('\n=== 3. 按卡组过滤 ===');

const now = 2000000000000;
const soon = now + 5 * 86400000;
const later = now + 40 * 86400000;
db.exec(`INSERT INTO scheduling (card_id, stability, difficulty, reps, lapses, streak,
         last_review, due, phase, step, first_seen) VALUES
         (1, 10, 5, 3, 0, 3, ${now - 1000}, ${soon}, 2, 0, 0),
         (2, 40, 5, 5, 0, 5, ${now - 1000}, ${soon + 1000}, 2, 0, 0),
         (4, 2,  5, 1, 0, 1, ${now - 1000}, ${soon + 2000}, 2, 0, 0)`);
// 卡 3 和卡 5 故意不给排期行:它们是「没学过」的

interface DueRow { due: number }
const inDeck1 = db.prepare(SQL_DUE_FORECAST_IN_DECK).all(now, later, 1, 1) as DueRow[];
const inDeck2 = db.prepare(SQL_DUE_FORECAST_IN_DECK).all(now, later, 2, 2) as DueRow[];
const inAll = db.prepare(SQL_DUE_FORECAST_IN_DECK).all(now, later, 0, 0) as DueRow[];
check('1 号卡组的预测只含 1 号的卡', inDeck1.length === 2, `${inDeck1.length} 张`);
check('2 号卡组的预测只含 2 号的卡', inDeck2.length === 1, `${inDeck2.length} 张`);
check('deckId = 0 表示不限,拿到全部', inAll.length === 3, `${inAll.length} 张`);
check('两个卡组相加 = 不限时的总数',
  inDeck1.length + inDeck2.length === inAll.length);

interface StabRow { stability: number }
const st1 = db.prepare(SQL_STABILITY_IN_DECK).all(1, 1) as StabRow[];
const st2 = db.prepare(SQL_STABILITY_IN_DECK).all(2, 2) as StabRow[];
check('稳定性按卡组过滤,1 号卡组 3 张全在', st1.length === 3, `${st1.length} 张`);
check('**没学过的卡也在里面,以 0 出现**(LEFT JOIN 陷阱)',
  st1.filter((r) => r.stability === 0).length === 1,
  `${st1.filter((r) => r.stability === 0).length} 张未学`);
check('2 号卡组 2 张,其中 1 张未学', st2.length === 2
  && st2.filter((r) => r.stability === 0).length === 1, `${st2.length} 张`);
check('各档之和 = 卡组卡片数(分子分母不会错位)',
  st1.length + st2.length === 5);

db.close();

console.log('\n=== 4. 拍平迁移:旧库升级不能丢卡 ===');

// 造一个**旧结构**的库:decks 带 parent_id,卡片挂在叶子上
const old = new DatabaseSync(':memory:');
old.exec(`CREATE TABLE decks (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            name      TEXT    NOT NULL,
            parent_id INTEGER NOT NULL DEFAULT 0,
            UNIQUE(name, parent_id))`);
for (const stmt of DDL) {
  if (stmt.indexOf('CREATE TABLE IF NOT EXISTS decks') >= 0) {
    continue;                       // decks 用上面的旧结构
  }
  old.exec(stmt);
}
// 测试(空壳) > 第一章(4 张);数学(空壳) > 高数(2 张);王道(3 张,本来就是平的)
old.exec(`INSERT INTO decks (id, name, parent_id) VALUES
          (1, '测试', 0), (2, '第一章', 1),
          (3, '数学', 0), (4, '高数', 3),
          (5, '王道', 0),
          (6, '物理', 0), (7, '高数', 6)`);
let nid2 = 0;
function mkIn(deck: number, n: number): void {
  for (let i = 0; i < n; i++) {
    nid2++;
    old.exec(`INSERT INTO notes (id, deck_id, type, front, back, title, options, answer,
              source_file, fingerprint, uuid, updated_at)
              VALUES (${nid2}, ${deck}, 0, 'f', 'b', 't${nid2}', '', '', 'x.md',
                      'fp${nid2}', 'u${nid2}', 0)`);
    old.exec(`INSERT INTO cards (id, note_id, ordinal, uuid, updated_at)
              VALUES (${nid2}, ${nid2}, 0, 'c${nid2}', 0)`);
  }
}
mkIn(2, 4);
mkIn(4, 2);
mkIn(5, 3);
mkIn(7, 1);

interface ColRow { n: number }
const before = (old.prepare(SQL_HAS_PARENT_COL).get() as ColRow).n;
check('迁移前检测到 parent_id 列', before === 1, `${before}`);

const cardsBefore = (old.prepare(`SELECT COUNT(*) AS n FROM cards`).get() as ColRow).n;
for (const stmt of MIGRATE_FLATTEN_DECKS) {
  old.exec(stmt);
}
const after = (old.prepare(SQL_HAS_PARENT_COL).get() as ColRow).n;
check('迁移后 parent_id 列已消失(**重复启动不会再跑**)', after === 0, `${after}`);

interface NameRow { id: number; name: string }
const decks = old.prepare(`SELECT id, name FROM decks ORDER BY id`).all() as NameRow[];
check('空壳父卡组被清掉,只留真的挂了卡的',
  decks.length === 4, `剩 ${decks.length} 个: ${decks.map((d) => d.name).join(', ')}`);
check('**卡组 id 保持不变**,notes.deck_id 不会悬空',
  decks.some((d) => d.id === 2) && decks.some((d) => d.id === 4)
  && decks.some((d) => d.id === 5) && decks.some((d) => d.id === 7),
  decks.map((d) => `${d.id}:${d.name}`).join(' '));

const cardsAfter = (old.prepare(`SELECT COUNT(*) AS n FROM cards`).get() as ColRow).n;
check('一张卡都没丢', cardsAfter === cardsBefore, `${cardsBefore} -> ${cardsAfter}`);

const orphans = (old.prepare(
  `SELECT COUNT(*) AS n FROM notes n WHERE NOT EXISTS
     (SELECT 1 FROM decks d WHERE d.id = n.deck_id)`).get() as ColRow).n;
check('没有笔记变成孤儿', orphans === 0, `${orphans}`);

// 数学::高数 和 物理::高数 拍平后同名,新表 name 是 UNIQUE,必须兜底
const gaoshu = decks.filter((d) => d.name.indexOf('高数') >= 0);
check('**重名的卡组被加后缀区分**,迁移不会因 UNIQUE 失败',
  gaoshu.length === 2 && gaoshu[0].name !== gaoshu[1].name,
  gaoshu.map((d) => d.name).join(' / '));

const uniq = new Set(decks.map((d) => d.name));
check('迁移后卡组名互不重复', uniq.size === decks.length);
old.close();

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
if (fail > 0) {
  process.exit(1);
}
