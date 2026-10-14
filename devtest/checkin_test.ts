/**
 * 打卡的回归测试:日界(凌晨 3 点)、连续天数规则、一次性回填、月历格子。
 */
import { DatabaseSync } from 'node:sqlite';
import {
  DDL, META_BACKFILL_CHECKINS, MIGRATE_BACKFILL_CHECKINS, SQL_CHECKIN_DAYS, SQL_INSERT_CHECKIN,
  SQL_IS_CHECKED_IN, SQL_META_GET, SQL_META_SET, calendarCells, calendarDate, checkinStreak,
  dayAnchor, dayIndex, weekdaySun0,
} from './Schema';

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: string): void {
  if (ok) { pass++; console.log(`  PASS  ${name}${detail ? '  ' + detail : ''}`); }
  else { fail++; console.log(`  FAIL  ${name}${detail ? '  ' + detail : ''}`); }
}
interface NRow { n: number }

const oct14 = dayIndex(new Date(2026, 9, 14, 12, 0).getTime());

console.log('=== 1. 打卡记到哪一天(用户给的例子) ===');
const db = new DatabaseSync(':memory:');
for (const s of DDL) { db.exec(s); }
for (const [h, m, d] of [[23, 51, 14], [2, 59, 15]]) {
  const t = new Date(2026, 9, d, h, m).getTime();
  db.prepare(SQL_INSERT_CHECKIN).run(dayIndex(t), t);
}
check('10/14 23:51 与 10/15 02:59 打卡都落在 10/14,只有一行',
  (db.prepare(`SELECT COUNT(*) AS n FROM checkins`).get() as NRow).n === 1);
check('10/14 已打卡', (db.prepare(SQL_IS_CHECKED_IN).get(oct14) as NRow).n === 1);
const t3 = new Date(2026, 9, 15, 3, 1).getTime();
db.prepare(SQL_INSERT_CHECKIN).run(dayIndex(t3), t3);
check('10/15 03:01 打卡算 10/15', (db.prepare(SQL_IS_CHECKED_IN).get(oct14 + 1) as NRow).n === 1);
const first = db.prepare(`SELECT ts FROM checkins WHERE day = ?`).get(oct14) as { ts: number };
check('重复打卡保留第一次的时刻', first.ts === new Date(2026, 9, 14, 23, 51).getTime());

console.log('\n=== 2. 连续天数:漏一天不断,连漏两天才断 ===');
const T = 1000;
check('没打过卡 = 0', checkinStreak([], T) === 0);
check('只有今天 = 1', checkinStreak([T], T) === 1);
check('今天还没打、昨天打了 = 1(今天不算漏)', checkinStreak([T - 1], T) === 1);
check('**周一 ✓ 周二 ✗ 周三 ✓ = 2**', checkinStreak([T - 2, T], T) === 2);
check('隔天打卡一直不断:✓✗✓✗✓ = 3', checkinStreak([T - 4, T - 2, T], T) === 3);
check('**连漏两天就断**:✓✗✗✓ = 1', checkinStreak([T - 3, T], T) === 1);
check('今天没打、昨天也没打、前天打了 = 1(只漏了昨天)', checkinStreak([T - 2], T) === 1);
check('今天没打、昨天前天都没打 = 0', checkinStreak([T - 3], T) === 0);
check('连续 5 天 = 5', checkinStreak([T - 4, T - 3, T - 2, T - 1, T], T) === 5);
check('顺序无关', checkinStreak([T, T - 2, T - 1], T) === 3);

console.log('\n=== 3. 一次性回填 ===');
db.exec(`DELETE FROM checkins`);
const logTs = [
  new Date(2026, 9, 11, 20, 0).getTime(),   // 10/11
  new Date(2026, 9, 12, 2, 30).getTime(),   // 10/12 02:30 -> 10/11
  new Date(2026, 9, 13, 10, 0).getTime(),   // 10/13
];
for (const ts of logTs) {
  db.exec(`INSERT INTO review_log (card_id, ts, grade) VALUES (1, ${ts}, 2)`);
}
const now = new Date(2026, 9, 14, 12, 0).getTime();
db.prepare(MIGRATE_BACKFILL_CHECKINS).run(dayAnchor(now));
db.prepare(SQL_META_SET).run(META_BACKFILL_CHECKINS, '1');
const days = (db.prepare(SQL_CHECKIN_DAYS).all() as Array<{ day: number }>).map((r) => r.day);
check('有作答的 2 天被回填(02:30 那次按 3 点日界归前一天)', days.length === 2, days.join(','));
check('回填的日序号与 dayIndex 一致',
  days[0] === dayIndex(logTs[0]) && days[1] === dayIndex(logTs[2]));
check('标记已写入', (db.prepare(SQL_META_GET).get(META_BACKFILL_CHECKINS) as NRow).n === 1);
db.prepare(MIGRATE_BACKFILL_CHECKINS).run(dayAnchor(now));
check('重跑也不会重复', (db.prepare(`SELECT COUNT(*) AS n FROM checkins`).get() as NRow).n === 2);
db.close();

console.log('\n=== 4. 月历:周日开头,首尾带相邻月份 ===');
for (const [y, m] of [[2026, 9], [2026, 1], [2026, 2], [2027, 1], [2024, 1]]) {
  const cells = calendarCells(y, m);
  const dates = cells.map((d) => calendarDate(d));
  const inMonth = dates.filter((x) => x[0] === y && x[1] === m);
  const daysInMonth = new Date(y, m + 1, 0).getDate();
  const tag = `${y}-${m + 1}`;
  check(`${tag} 格子数是 7 的倍数`, cells.length % 7 === 0, `${cells.length}`);
  check(`${tag} 第一格是周日、最后一格是周六`,
    weekdaySun0(cells[0]) === 0 && weekdaySun0(cells[cells.length - 1]) === 6);
  check(`${tag} 本月 ${daysInMonth} 天一天不少`, inMonth.length === daysInMonth
    && inMonth[0][2] === 1 && inMonth[inMonth.length - 1][2] === daysInMonth);
  check(`${tag} 日序号连续`, cells.every((d, i) => i === 0 || d === cells[i - 1] + 1));
}
const oct = calendarCells(2026, 9).map((d) => calendarDate(d)[2]);
check('2026 年 10 月以 9/27 开头(10/1 是周四)', oct.slice(0, 5).join(',') === '27,28,29,30,1', oct.slice(0, 7).join(','));
check('2026 年 10 月以 10/31 结尾(10/31 是周六,不需要补下个月)', oct[oct.length - 1] === 31, `${oct[oct.length - 1]}`);

const nov = calendarCells(2026, 10).map((d) => calendarDate(d)[2]);
check('2026 年 11 月以 11/1 开头(周日)、以 12/5 结尾', nov[0] === 1 && nov[nov.length - 1] === 5,
  `${nov[0]} … ${nov[nov.length - 1]}`);

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
if (fail > 0) { process.exit(1); }
