/**
 * 每日汇总投影(Task 7,ADR-0006 方案 A)的回归测试。
 *
 * 本机的每日汇总从 review_log 现算(生产 SQL_DAY_STATS,凌晨 3 点日界),上传成 daily_stat 行;
 * 其他设备的行下载后与本机现算的相加。断言:日界、已归档流水照算、跨设备相加、
 * 自己的行不算两遍、与热力图口径一致、v3 迁移建了缓存表。
 */
import {
  DAY_CUTOFF_MS, DailyStatRow, DayStat, SQL_DAY_STATS, SQL_DROP_TOMBSTONE, SQL_REMOTE_DAY_STATS,
  SQL_TOMBSTONES_SINCE, SQL_TOMBSTONE_DECK, SQL_TOMBSTONE_DECK_CARDS, SQL_TOMBSTONE_DECK_SCHED,
  SQL_TOMBSTONE_NOTE_CARDS, SQL_UPSERT_REMOTE_DAY_STAT, SQL_CARD_ID_BY_UUID, SQL_DELETE_SCHED_BY_CARD,
  SQL_PUT_TOMBSTONE, SQL_SET_SCHED_UPDATED, SQL_SYNC_CHECKINS_SINCE, SQL_SYNC_CHECKIN_TS, SQL_SYNC_DAYS_SINCE,
  SQL_SYNC_DECKS_SINCE, SQL_SYNC_DECK_BY_UUID, SQL_SYNC_SCHED_BY_UUID, SQL_SYNC_SCHED_SINCE, SQL_TOMBSTONE_AT,
  dayAnchor, dayIndex, dayStart, heatCells, mergeDayStats, projectDailyStats,
} from './Schema';
import { freshDb } from './importsim';

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

const HOUR = 3600000;
const db = freshDb();
const now = Date.now();
const today = dayIndex(now);
const t0 = dayStart(today);            // 今天 03:00

// 今天 03:00 之后两条;今天 02:59(= 昨天)一条;三天前一条已归档(清空进度)
db.exec(`INSERT INTO review_log (card_id, ts, grade, cost_ms, archived) VALUES
  (1, ${t0 + 1000}, 3, 4000, 0),
  (2, ${t0 + 5 * HOUR}, 2, 6000, 0),
  (3, ${t0 - 60000}, 3, 1000, 0),
  (4, ${t0 - 3 * 24 * HOUR + HOUR}, 3, 2000, 1)`);

const local: DayStat[] = (db.prepare(SQL_DAY_STATS).all(dayAnchor(now)) as { day: number; reps: number; ms: number }[])
  .map((r) => ({ day: r.day, reps: r.reps, ms: r.ms }));

console.log('=== 1. 本机现算:3 点日界、已归档照算 ===');
const byDay = new Map(local.map((s) => [s.day, s]));
check('今天 2 次、10 秒', byDay.get(today)?.reps === 2 && byDay.get(today)?.ms === 10000, JSON.stringify(byDay.get(today)));
check('02:59 那条算昨天', byDay.get(today - 1)?.reps === 1, JSON.stringify(byDay.get(today - 1)));
check('已归档的流水照算(ADR-0005)', byDay.get(today - 3)?.reps === 1, JSON.stringify(byDay.get(today - 3)));
check('日序号与 dayIndex 一致', local.every((s) => typeof s.day === 'number') && byDay.has(dayIndex(t0 + 1000)));
check('DAY_CUTOFF 是 3 小时', DAY_CUTOFF_MS === 3 * HOUR);

console.log('=== 2. 投影成 daily_stat 行 ===');
const all = projectDailyStats(local, 'dev-A', -Infinity);
check('全量:3 行,带设备 id', all.length === 3 && all.every((r) => r.deviceId === 'dev-A'), JSON.stringify(all));
const since = projectDailyStats(local, 'dev-A', today - 1);
check('增量:只传昨天及以后', since.length === 2 && since.every((r) => r.day >= today - 1), JSON.stringify(since));

console.log('=== 3. 跨设备相加 ===');
const remote: DailyStatRow[] = [
  { deviceId: 'dev-B', day: today, reps: 5, ms: 30000 },
  { deviceId: 'dev-B', day: today - 10, reps: 7, ms: 1000 },
  { deviceId: 'dev-A', day: today, reps: 999, ms: 999 },   // 自己上传过的行又下载回来了
];
const merged = mergeDayStats(local, remote, 'dev-A');
const m = new Map(merged.map((s) => [s.day, s]));
check('同一天两台设备相加', m.get(today)?.reps === 7 && m.get(today)?.ms === 40000, JSON.stringify(m.get(today)));
check('只有另一台设备学过的天也出现', m.get(today - 10)?.reps === 7);
check('自己的行不算两遍', m.get(today)?.reps !== 999 + 2);
check('升序', merged.every((s, i) => i === 0 || merged[i - 1].day < s.day));
check('没有其他设备时与本机完全一样', JSON.stringify(mergeDayStats(local, [], 'dev-A')) === JSON.stringify(local));
check('合并不改动输入', byDay.get(today)?.reps === 2);

console.log('=== 4. 与热力图口径一致 ===');
const cells = heatCells(today, 18, (d) => m.get(d)?.reps ?? 0);
check('热力图今天那格 = 合并后的 7', cells.includes(7), `${cells.filter((x) => x > 0).join(',')}`);

console.log('=== 5. v3 缓存表 ===');
db.prepare(SQL_UPSERT_REMOTE_DAY_STAT).run('dev-B', today, 5, 30000);
db.prepare(SQL_UPSERT_REMOTE_DAY_STAT).run('dev-B', today, 8, 50000);
const rows = db.prepare(SQL_REMOTE_DAY_STATS).all() as { device_id: string; day: number; reps: number }[];
check('同一设备同一天整行覆盖', rows.length === 1 && rows[0].reps === 8, JSON.stringify(rows));

console.log('=== 6. 删除墓碑(Task 8) ===');
const t = freshDb();
t.exec(`INSERT INTO decks (id, name, uuid) VALUES (1, 'A', 'deck-A'), (2, 'B', 'deck-B')`);
t.exec(`INSERT INTO notes (id, deck_id, front, fingerprint, uuid) VALUES
  (1, 1, 'q1', 'f1', 'deck-A/c1'), (2, 1, 'q2', 'f2', 'deck-A/c2'), (3, 2, 'q3', 'f3', 'deck-B/c3')`);
t.exec(`INSERT INTO cards (id, note_id, uuid) VALUES (1, 1, 'deck-A/c1'), (2, 2, 'deck-A/c2'), (3, 3, 'deck-B/c3')`);
t.exec(`INSERT INTO scheduling (card_id, stability, last_review, due) VALUES (1, 2, 1, 1)`);
const tombs = (kind: string): string[] => (t.prepare(SQL_TOMBSTONES_SINCE).all(kind, 0) as { uuid: string }[])
  .map((r) => r.uuid).sort();
t.prepare(SQL_TOMBSTONE_DECK_SCHED).run(100, 1);
check('清空进度:只给有排期的卡记墓碑', tombs('card').join() === 'deck-A/c1', tombs('card').join());
t.prepare(SQL_TOMBSTONE_NOTE_CARDS).run(200, 3);
check('删一张卡:记它的墓碑', tombs('card').join() === 'deck-A/c1,deck-B/c3', tombs('card').join());
t.prepare(SQL_TOMBSTONE_DECK_CARDS).run(300, 1);
t.prepare(SQL_TOMBSTONE_DECK).run(300, 1);
check('删牌组:牌组和它的每张卡', tombs('deck').join() === 'deck-A' && tombs('card').join() === 'deck-A/c1,deck-A/c2,deck-B/c3',
  `${tombs('deck').join()} / ${tombs('card').join()}`);
check('同一张卡再记一次,时刻更新为最新', (t.prepare(`SELECT deleted_at FROM sync_tombstones WHERE uuid = 'deck-A/c1'`)
  .get() as { deleted_at: number }).deleted_at === 300);
check('按时刻增量取', (t.prepare(SQL_TOMBSTONES_SINCE).all('card', 250) as unknown[]).length === 2);
t.prepare(SQL_DROP_TOMBSTONE).run('card', 'deck-A/c1');
check('活过来的卡,墓碑作废', !tombs('card').includes('deck-A/c1'));

console.log('=== 7. 同步本地一侧的 SQL(Task 12 用) ===');
const s = freshDb();
s.exec(`INSERT INTO decks (id, name, uuid, updated_at) VALUES (1, 'A', 'deck-A', 500), (2, 'B', 'deck-B', 50)`);
s.exec(`INSERT INTO notes (id, deck_id, front, fingerprint, uuid) VALUES (1, 1, 'q', 'f', 'deck-A/c1')`);
s.exec(`INSERT INTO cards (id, note_id, uuid) VALUES (1, 1, 'deck-A/c1')`);
s.exec(`INSERT INTO scheduling (card_id, stability, last_review, due, updated_at) VALUES (1, 3.5, 700, 900, 700)`);
s.exec(`INSERT INTO checkins (day, ts) VALUES (10, 100), (11, 800)`);
s.exec(`INSERT INTO review_log (card_id, ts, grade, cost_ms) VALUES (1, ${t0 + 1000}, 3, 100), (1, ${t0 - 5 * 24 * HOUR}, 3, 50)`);
check('打卡增量', (s.prepare(SQL_SYNC_CHECKINS_SINCE).all(500) as unknown[]).length === 1);
check('打卡时刻', (s.prepare(SQL_SYNC_CHECKIN_TS).get(10) as { ts: number }).ts === 100);
const days = s.prepare(SQL_SYNC_DAYS_SINCE).all(dayAnchor(now), t0) as { day: number; reps: number; last: number }[];
check('只有最近作答过的那天要上传', days.length === 1 && days[0].day === today && days[0].last === t0 + 1000,
  JSON.stringify(days));
check('牌组增量', (s.prepare(SQL_SYNC_DECKS_SINCE).all(100) as { uuid: string }[]).map((r) => r.uuid).join() === 'deck-A');
check('按 uuid 找牌组', (s.prepare(SQL_SYNC_DECK_BY_UUID).get('deck-B') as { id: number }).id === 2);
const sc = s.prepare(SQL_SYNC_SCHED_SINCE).all(600) as { uuid: string; stability: number }[];
check('排期增量带卡片 uuid', sc.length === 1 && sc[0].uuid === 'deck-A/c1' && sc[0].stability === 3.5, JSON.stringify(sc));
check('按卡片 uuid 取排期时刻', (s.prepare(SQL_SYNC_SCHED_BY_UUID).get('deck-A/c1') as { updated_at: number }).updated_at === 700);
check('按 uuid 找卡', (s.prepare(SQL_CARD_ID_BY_UUID).get('deck-A/c1') as { id: number }).id === 1);
s.prepare(SQL_SET_SCHED_UPDATED).run(1234, 1);
check('设置排期时刻', (s.prepare(SQL_SYNC_SCHED_BY_UUID).get('deck-A/c1') as { updated_at: number }).updated_at === 1234);
s.prepare(SQL_PUT_TOMBSTONE).run('card', 'deck-A/c1', 999);
check('写入云端墓碑、按 uuid 取时刻', (s.prepare(SQL_TOMBSTONE_AT).get('card', 'deck-A/c1') as { deleted_at: number }).deleted_at === 999);
s.prepare(SQL_DELETE_SCHED_BY_CARD).run(1);
check('删排期', s.prepare(SQL_SYNC_SCHED_BY_UUID).get('deck-A/c1') === undefined);

console.log(`\n结果: ${pass} 通过, ${fail} 失败`);
process.exit(fail === 0 ? 0 : 1);
