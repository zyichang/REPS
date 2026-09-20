/**
 * 数据库层验证:用 node:sqlite 执行**生产的**建表语句与映射函数。
 *
 * 关键点:这里 import 的 './Schema' 是由 sync-and-test.mjs 从
 * entry/src/main/ets/data/Schema.ets 同步过来的,不是手抄的副本。
 * 所以这套测试测的是真正会跑在设备上的那份 SQL。
 *
 * 断言纪律:期望值按语义手推,不允许把实际输出抄成期望值。
 */

import { DatabaseSync } from 'node:sqlite';
import { CardState, Grade, LearnPhase } from './Models';
import {
  DAY_CUTOFF_HOUR, DAY_CUTOFF_MS, DDL, DayBucket, LOG_COLUMNS, LogPoint, SCHED_COLUMNS,
  SQL_DUE_CARDS, SQL_INSERT_LOG, SQL_NEW_CARDS, SQL_SELECT_SCHEDULING,
  SQL_STABILITY_HISTOGRAM, SQL_UPSERT_SCHEDULING, SchedulingRow, dayIndex,
  dayStart, fingerprintOf,
  bucketByDay, fromSchedulingRow, isValidAlgo, makeUuid, retentionOf,
  schedulingValues, toSchedulingRow,
} from './Schema';
import { newCardState, schedule, setAlgorithm, setRandomSource } from './srs';

let pass = 0;
let fail = 0;

function check(name: string, cond: boolean, extra: string = ''): void {
  if (cond) {
    pass++;
    console.log(`  PASS  ${name}${extra ? '  ' + extra : ''}`);
  } else {
    fail++;
    console.log(`  FAIL  ${name}${extra ? '  ' + extra : ''}`);
  }
}

const DAY_MS = 86_400_000;
const MIN_MS = 60_000;

// ================================================================ 1. 建表
console.log('=== 1. 生产 DDL 能被真实 SQLite 接受 ===');

const db = new DatabaseSync(':memory:');
let ddlOk = true;
let ddlErr = '';
try {
  for (const stmt of DDL) {
    db.exec(stmt);
  }
} catch (e) {
  ddlOk = false;
  ddlErr = String(e);
}
check('全部 DDL 执行成功', ddlOk, ddlOk ? `${DDL.length} 条` : ddlErr);

const tables = db.prepare(
  `SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name`
).all() as Array<{ name: string }>;
const tableNames = tables.map((t) => t.name);
for (const t of ['cards', 'decks', 'notes', 'review_log', 'scheduling']) {
  check(`表 ${t} 已建立`, tableNames.includes(t));
}

const indexes = db.prepare(
  `SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%' ORDER BY name`
).all() as Array<{ name: string }>;
check('五个索引都建好了', indexes.length === 5, indexes.map((i) => i.name).join(', '));

// scheduling 的列必须与 SCHED_COLUMNS 完全一致,否则 INSERT 的占位符会错位
const schedCols = (db.prepare(`PRAGMA table_info(scheduling)`).all() as Array<{ name: string }>)
  .map((c) => c.name);
check('scheduling 实际列与 SCHED_COLUMNS 一致',
  schedCols.join(',') === SCHED_COLUMNS.join(','),
  `实际 ${schedCols.join(',')}`);

const logCols = (db.prepare(`PRAGMA table_info(review_log)`).all() as Array<{ name: string }>)
  .map((c) => c.name).filter((c) => c !== 'id');
check('review_log 实际列与 LOG_COLUMNS 一致',
  logCols.join(',') === LOG_COLUMNS.join(','),
  `实际 ${logCols.join(',')}`);

// ================================================================ 2. 约束
console.log('\n=== 2. 表约束真的生效 ===');

db.exec(`INSERT INTO decks (name, parent_id) VALUES ('DataStructure', 0)`);
db.exec(`INSERT INTO notes (deck_id, type, front, back, title, fingerprint, uuid, updated_at)
         VALUES (1, 2, '栈是{{后进先出}}的', '', '基础填空 (1)', 'fp-001', 'uuid-n1', 1000)`);
db.exec(`INSERT INTO cards (note_id, ordinal, uuid, updated_at) VALUES (1, 0, 'uuid-c1', 1000)`);

let dupFp = false;
try {
  db.exec(`INSERT INTO notes (deck_id, front, fingerprint, uuid)
           VALUES (1, 'x', 'fp-001', 'uuid-n2')`);
} catch (e) {
  dupFp = true;
}
check('notes.fingerprint 唯一约束拦住重复(幂等重导的基础)', dupFp);

let dupOrdinal = false;
try {
  db.exec(`INSERT INTO cards (note_id, ordinal, uuid) VALUES (1, 0, 'uuid-c2')`);
} catch (e) {
  dupOrdinal = true;
}
check('cards (note_id, ordinal) 唯一约束生效', dupOrdinal);

// 同一条笔记的第二个挖空 —— 必须能插进去
db.exec(`INSERT INTO cards (note_id, ordinal, uuid, updated_at) VALUES (1, 1, 'uuid-c2', 1000)`);
const cardCount = (db.prepare(`SELECT COUNT(*) AS n FROM cards`).get() as { n: number }).n;
check('一条笔记可挂多张卡(完形填空多挖空)', cardCount === 2, `${cardCount} 张`);

// ================================================================ 3. CardState 往返
console.log('\n=== 3. CardState 存取一轮必须逐字段一致 ===');

setRandomSource(() => 0.5);
setAlgorithm('fsrs');

const T0 = Date.UTC(2026, 0, 15, 9, 0, 0);
// 造一个「用过一阵」的状态:各字段都不是默认值,才能查出漏存的列
let state: CardState = newCardState(1, T0);
state = schedule(state, Grade.Good, T0, false).state;           // 进入学习步进
state = schedule(state, Grade.Again, state.due, false).state;   // 制造一次 lapse
state = schedule(state, Grade.Good, state.due, false).state;
state = schedule(state, Grade.Good, state.due, false).state;

const row: SchedulingRow = toSchedulingRow(state);
db.prepare(SQL_UPSERT_SCHEDULING).run(...schedulingValues(row));

const readBack = db.prepare(SQL_SELECT_SCHEDULING).get(1) as SchedulingRow;
const restored: CardState = fromSchedulingRow(readBack);

// 逐字段比较。phase / step 是最容易漏的两个:它们只在学习步进里有意义,
// 漏存的话卡片会从「学习中」凭空跳回「新卡」。
const fields: Array<[string, number, number]> = [
  ['cardId', state.cardId, restored.cardId],
  ['stability', state.stability, restored.stability],
  ['difficulty', state.difficulty, restored.difficulty],
  ['reps', state.reps, restored.reps],
  ['lapses', state.lapses, restored.lapses],
  ['streak', state.streak, restored.streak],
  ['lastReview', state.lastReview, restored.lastReview],
  ['due', state.due, restored.due],
  ['phase', state.phase as number, restored.phase as number],
  ['step', state.step, restored.step],
  ['firstSeen', state.firstSeen, restored.firstSeen],
];
for (const [name, want, got] of fields) {
  check(`字段 ${name} 往返一致`, want === got, `${want} -> ${got}`);
}
check('往返覆盖了 CardState 的全部 11 个字段',
  fields.length === Object.keys(state).length, `${fields.length} / ${Object.keys(state).length}`);

// 这个状态确实「非默认」,否则上面的比较没有说服力
check('测试用的状态不是一堆默认值(lapses>0 且 reps>1)',
  state.lapses > 0 && state.reps > 1, `reps=${state.reps} lapses=${state.lapses}`);
check('difficulty 不为 0(0 在 FSRS 里非法)', restored.difficulty > 0, `${restored.difficulty.toFixed(2)}`);

// 覆盖写:同一张卡再答一次,应当替换而不是新增一行
const before = (db.prepare(`SELECT COUNT(*) AS n FROM scheduling`).get() as { n: number }).n;
const next = schedule(restored, Grade.Good, restored.due, false).state;
db.prepare(SQL_UPSERT_SCHEDULING).run(...schedulingValues(toSchedulingRow(next)));
const after = (db.prepare(`SELECT COUNT(*) AS n FROM scheduling`).get() as { n: number }).n;
check('再次写入是覆盖,不是新增', before === 1 && after === 1, `${before} -> ${after}`);
check('覆盖后 due 确实推进了', next.due > restored.due,
  `${new Date(restored.due).toISOString().slice(0, 16)} -> ${new Date(next.due).toISOString().slice(0, 16)}`);

// ================================================================ 4. 复习日志
console.log('\n=== 4. 复习日志 ===');

const r = schedule(next, Grade.Hard, next.due, false);
db.prepare(SQL_INSERT_LOG).run(
  1, next.due, Grade.Hard as number, r.stabilityBefore, r.elapsedDays,
  r.retrievability, r.intervalDays, 1234, 'fsrs'
);
const log = db.prepare(`SELECT * FROM review_log WHERE card_id = 1`).get() as Record<string, number | string>;
check('日志写入成功', log !== undefined);
check('日志记下了评级', log['grade'] === (Grade.Hard as number), String(log['grade']));
check('日志记下了引擎名(换引擎后历史仍可解释)', log['algo'] === 'fsrs', String(log['algo']));
check('日志的 stability_before 是评级前的值', Math.abs((log['stability_before'] as number) - next.stability) < 1e-9);
check('日志保留了答题耗时', log['cost_ms'] === 1234);
check('algo 取值校验函数正确', isValidAlgo('fsrs') && isValidAlgo('ebbinghaus') && !isValidAlgo('sm2'));

// ================================================================ 5. 队列查询
console.log('\n=== 5. 取卡查询 ===');

// 第 2 张卡(uuid-c2)没有 scheduling 行 —— 按定义它是新卡
const newCards = db.prepare(SQL_NEW_CARDS).all(10) as Array<{ card_id: number }>;
check('新卡 = 没有 scheduling 行的卡', newCards.length === 1 && newCards[0].card_id === 2,
  `命中 ${newCards.map((c) => c.card_id).join(',')}`);

// 到期查询:把第 1 张卡的 due 设到过去
db.exec(`UPDATE scheduling SET due = 1000 WHERE card_id = 1`);
const due = db.prepare(SQL_DUE_CARDS).all(2000, 10) as Array<{ card_id: number }>;
check('到期卡被取出', due.length === 1 && due[0].card_id === 1);
const notYet = db.prepare(SQL_DUE_CARDS).all(999, 10) as Array<{ card_id: number }>;
check('未到期的卡不会被取出', notYet.length === 0);

// ================================================================ 6. 日界
console.log('\n=== 6. 凌晨 1 点日界 ===');

check('DAY_CUTOFF_HOUR 是 1', DAY_CUTOFF_HOUR === 1);
check('DAY_CUTOFF_MS = 1 小时', DAY_CUTOFF_MS === 60 * MIN_MS, `${DAY_CUTOFF_MS}`);

// 用本地时间构造,因为 dayIndex 按本地时区归天
const at0030 = new Date(2026, 0, 15, 0, 30, 0).getTime(); // 1/15 00:30 本地
const at0130 = new Date(2026, 0, 15, 1, 30, 0).getTime(); // 1/15 01:30 本地
const at2330 = new Date(2026, 0, 14, 23, 30, 0).getTime(); // 1/14 23:30 本地

check('00:30 与前一天 23:30 属于同一天(关键:没被午夜切开)',
  dayIndex(at0030) === dayIndex(at2330), `${dayIndex(at0030)} vs ${dayIndex(at2330)}`);
check('01:30 已属于新的一天', dayIndex(at0130) === dayIndex(at0030) + 1,
  `${dayIndex(at0130)} vs ${dayIndex(at0030)}`);
check('恰好 01:00 是新一天的第一刻',
  dayIndex(new Date(2026, 0, 15, 1, 0, 0).getTime()) === dayIndex(at0130));
check('00:59:59 仍算前一天',
  dayIndex(new Date(2026, 0, 15, 0, 59, 59).getTime()) === dayIndex(at0030));

// dayStart 必须是 dayIndex 的逆
const d = dayIndex(at0130);
const start = dayStart(d);
check('dayStart 落在当天 01:00', new Date(start).getHours() === 1, new Date(start).toString().slice(0, 24));
check('dayStart 与 dayIndex 互逆', dayIndex(start) === d, `${dayIndex(start)} vs ${d}`);
check('dayStart 不晚于当天任何时刻', start <= at0130);
check('相邻两天的分界正好相差一天', dayStart(d + 1) - dayStart(d) === DAY_MS);

// ================================================================ 7. 指纹与 uuid
console.log('\n=== 7. 卡片指纹(幂等重导的基础) ===');

const fpA = fingerprintOf('DataStructure::Chapter_2', '基础选择 (1)', 0);

check('同样输入得到同样指纹(确定性)',
  fpA === fingerprintOf('DataStructure::Chapter_2', '基础选择 (1)', 0), fpA);
check('指纹是 8 位十六进制', /^[0-9a-f]{8}$/.test(fpA), fpA);

// 这三条决定了「什么算同一张卡」
check('标题不同 -> 不同卡',
  fpA !== fingerprintOf('DataStructure::Chapter_2', '基础选择 (2)', 0));
check('序号不同 -> 不同卡(同一条笔记的不同挖空)',
  fpA !== fingerprintOf('DataStructure::Chapter_2', '基础选择 (1)', 1));
check('卡组不同 -> 不同卡',
  fpA !== fingerprintOf('DataStructure::Chapter_3', '基础选择 (1)', 0));

// 这条是「改了错别字重导不丢进度」的根据:指纹压根不看正反面内容
check('指纹不含正反面内容,所以改正文不会变成新卡',
  fingerprintOf('DataStructure::Chapter_2', '基础选择 (1)', 0) === fpA);

// 分隔符不能让不同输入撞车:('a','b') 与 ('a\0b','') 必须不同
check('字段边界不会被拼接歧义吃掉',
  fingerprintOf('a', 'b', 0) !== fingerprintOf('a\u0000b', '', 0));

// 真实场景:Quizify 要求标题带小节限定,正是为了避免下面这种撞车
check('带小节限定的两个 (1) 不撞车',
  fingerprintOf('Math_880::Chapter_2', '基础选择 (1)', 0) !==
  fingerprintOf('Math_880::Chapter_2', '综合选择 (1)', 0));

const u1 = makeUuid('n', 1_700_000_000_000);
const u2 = makeUuid('n', 1_700_000_000_000);
check('uuid 带前缀', u1.startsWith('n-'), u1);
check('同一毫秒内两次生成也不相同', u1 !== u2, `${u1} / ${u2}`);

// ================================================================ 8. 统计聚合
console.log('\n=== 8. 热力图分桶与保持率 ===');

// 构造:1/15 三次、1/16 一次,其中 1/15 00:30 那次按日界算属于 1/14
const t15_0030 = new Date(2026, 0, 15, 0, 30, 0).getTime();  // -> 1/14
const t15_1000 = new Date(2026, 0, 15, 10, 0, 0).getTime();  // -> 1/15
const t15_2300 = new Date(2026, 0, 15, 23, 0, 0).getTime();  // -> 1/15
const t16_1200 = new Date(2026, 0, 16, 12, 0, 0).getTime();  // -> 1/16

const pts: LogPoint[] = [
  { ts: t15_0030, grade: 2, cardId: 1 },
  { ts: t15_1000, grade: 2, cardId: 1 },
  { ts: t15_2300, grade: 0, cardId: 2 },
  { ts: t16_1200, grade: 3, cardId: 1 },
];
const buckets: DayBucket[] = bucketByDay(pts);

check('分出三天(00:30 那次归前一天)', buckets.length === 3,
  buckets.map((b) => `${b.day}:${b.reps}`).join(' '));
check('分桶按日序号升序', buckets[0].day < buckets[1].day && buckets[1].day < buckets[2].day);
check('第一天只有 1 次(就是 00:30 那次)', buckets[0].reps === 1);
check('第二天有 2 次', buckets[1].reps === 2, `${buckets[1].reps}`);
check('第二天答对 1 次(另一次是「忘了」)', buckets[1].good === 1, `${buckets[1].good}`);
check('第三天 1 次且答对', buckets[2].reps === 1 && buckets[2].good === 1);
check('分桶用的是 dayIndex 的口径', buckets[0].day === dayIndex(t15_0030));

// 保持率:新卡首答不计入 —— 那时还没有任何记忆可供「保持」
// card 1 出现 3 次:第 1 次是首答(不计),第 2、3 次计入且都答对
// card 2 出现 1 次:首答,不计
// 所以 total=2, good=2 -> 100%
check('保持率排除新卡首答', Math.abs(retentionOf(pts) - 1.0) < 1e-9,
  `${(retentionOf(pts) * 100).toFixed(0)}%`);

const pts2: LogPoint[] = [
  { ts: 1000, grade: 2, cardId: 1 },   // 首答,不计
  { ts: 2000, grade: 0, cardId: 1 },   // 计入,失败
  { ts: 3000, grade: 2, cardId: 1 },   // 计入,成功
];
check('一半答对时保持率为 50%', Math.abs(retentionOf(pts2) - 0.5) < 1e-9,
  `${(retentionOf(pts2) * 100).toFixed(0)}%`);
check('没有复习记录时保持率为 0 而不是 NaN', retentionOf([]) === 0);
check('只有新卡首答时保持率为 0',
  retentionOf([{ ts: 1, grade: 2, cardId: 9 }]) === 0);
check('空输入分桶得到空数组', bucketByDay([]).length === 0);

// ---- 掌握度直方图的口径:各档之和必须等于卡片总数 ----
// 这是 WordSnap 栽过的那类 bug:只查 scheduling 会漏掉没答过的卡,
// 于是「未学」永远是 0,各档之和也对不上总数。
const histRows = db.prepare(SQL_STABILITY_HISTOGRAM).all() as Array<{ stability: number }>;
const totalCards = (db.prepare(`SELECT COUNT(*) AS n FROM cards`).get() as { n: number }).n;
check('稳定性直方图覆盖全部卡片,不只是答过的',
  histRows.length === totalCards, `直方图 ${histRows.length} 行 / 卡片 ${totalCards} 张`);

const schedCount = (db.prepare(`SELECT COUNT(*) AS n FROM scheduling`).get() as { n: number }).n;
check('确实存在没答过的卡(否则上一条断言没有说服力)',
  totalCards > schedCount, `${totalCards} 张卡中 ${schedCount} 张有排期`);
check('没答过的卡以 stability = 0 出现(masteryOf(0) 归入未学)',
  histRows.filter((r) => r.stability === 0).length === totalCards - schedCount,
  `${histRows.filter((r) => r.stability === 0).length} 行为 0`);

db.close();

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
process.exit(fail === 0 ? 0 : 1);
