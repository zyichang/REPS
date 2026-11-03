/**
 * 打卡的回归测试:日界(凌晨 3 点)、连续天数规则、一次性回填、月历格子。
 */
import { DatabaseSync } from 'node:sqlite';
import {
  DDL, DeckCounts, META_BACKFILL_CHECKINS, MIGRATE_BACKFILL_CHECKINS, SQL_ANSWERED_SINCE, SQL_CHECKIN_DAYS,
  SQL_DECK_COUNTS, SQL_INSERT_CHECKIN, SQL_IS_CHECKED_IN, SQL_META_GET, SQL_META_SET, applyDeckLimits,
  calendarCells, calendarDate, checkinStreak, dayAnchor, dayIndex, dayStart, todayAllDone, weekdaySun0,
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

console.log('\n=== 5. 今天的卡都学完了就自动打卡(todayAllDone,.scratch/auto-check-in) ===');
const zero: DeckCounts = { id: 1, name: 'A', cards: 3, newCount: 0, learnCount: 0, dueCount: 0, settled: 3 };
check('今天一张都没答:不算学完(没有牌组)', !todayAllDone([], 0));
check('今天一张都没答:不算学完(各组都是 0,比如今天根本没有卡)', !todayAllDone([zero], 0));
check('各组都是 0、今天答过:学完', todayAllDone([zero, { ...zero, id: 2 }], 5));
check('还有新卡:没学完', !todayAllDone([zero, { ...zero, id: 2, newCount: 1 }], 5));
check('还有卡在学习步里(学习中):没学完', !todayAllDone([{ ...zero, learnCount: 1 }], 5));
check('还有待复习:没学完', !todayAllDone([{ ...zero, dueCount: 1 }], 5));

// 用生产的牌组计数 SQL 走一遍真实的一天:两个牌组,4 张新卡 + 1 张今天下午到期的旧卡
const db5 = new DatabaseSync(':memory:');
for (const s of DDL) { db5.exec(s); }
db5.exec(`INSERT INTO decks (id, name) VALUES (1, 'A'), (2, 'B')`);
for (let id = 1; id <= 5; id++) {
  db5.exec(`INSERT INTO notes (id, deck_id, type, front, back, title, options, answer, source_file, fingerprint, uuid, updated_at)
            VALUES (${id}, ${id <= 2 ? 1 : 2}, 0, 'f', 'b', 't${id}', '', '', 'x', 'fp${id}', 'n${id}', 0)`);
  db5.exec(`INSERT INTO cards (id, note_id, ordinal, uuid, updated_at) VALUES (${id}, ${id}, 0, 'c${id}', 0)`);
}
const N5 = new Date(2026, 9, 20, 12, 0).getTime();   // 中午,远离凌晨 3 点的日界
const from5 = dayStart(dayIndex(N5));
const to5 = dayStart(dayIndex(N5) + 1);
const MIN5 = 60 * 1000;
const DAY5 = 24 * 60 * MIN5;
function decks5(): DeckCounts[] {
  const rows = db5.prepare(SQL_DECK_COUNTS).all(to5, from5, from5, from5, to5, from5, to5) as Array<Record<string, number>>;
  return rows.map((r) => applyDeckLimits({
    id: r.id, name: `${r.name}`, cards: r.cards, unlearned: r.unlearned, untouchedDue: r.untouched_due,
    newToday: r.new_today, again: r.again, settled: r.settled,
  }, 20, 200));
}
const answered5 = (): number => (db5.prepare(SQL_ANSWERED_SINCE).get(from5) as NRow).n;
/** 答一次:排期写成 due / last,流水记一条 */
function answer5(card: number, due: number, last: number, firstSeen: number): void {
  db5.exec(`INSERT OR REPLACE INTO scheduling (card_id, stability, difficulty, reps, lapses, streak,
            last_review, due, phase, step, first_seen) VALUES
            (${card}, 1, 5, 1, 0, 1, ${last}, ${due}, 2, 0, ${firstSeen})`);
  db5.exec(`INSERT INTO review_log (card_id, ts, grade) VALUES (${card}, ${last}, 3)`);
}
// 第 5 张:三天前学过,今天下午 5 点到期 —— 属于今天这一组
answer5(5, to5 - 10 * 60 * MIN5, N5 - 3 * DAY5, N5 - 10 * DAY5);
check('早上:4 张新卡 + 1 张今天到期,没学完', !todayAllDone(decks5(), answered5()), JSON.stringify(decks5()));
answer5(1, to5 + 2 * DAY5, N5 - 30 * MIN5, N5 - 30 * MIN5);
answer5(2, to5 + DAY5, N5 - 25 * MIN5, N5 - 25 * MIN5);
answer5(3, to5 + DAY5, N5 - 20 * MIN5, N5 - 20 * MIN5);
answer5(4, N5 + 10 * MIN5, N5 - 5 * MIN5, N5 - 5 * MIN5);        // 答错了,10 分钟后回来
check('新卡都答过了,但第 4 张还在学习步里、第 5 张还没复习:没学完', !todayAllDone(decks5(), answered5()));
answer5(5, to5 + 3 * DAY5, N5 - 2 * MIN5, N5 - 10 * DAY5);
check('下午到期的那张提前复习了,第 4 张仍在学习步里:没学完', !todayAllDone(decks5(), answered5()));
answer5(4, to5 + DAY5, N5 + 11 * MIN5, N5 - 5 * MIN5);           // 回来又答一次,明天见
check('**最后一张也学完了:学完,该自动打卡**', todayAllDone(decks5(), answered5()), JSON.stringify(decks5()));
check('今天的作答数 = 6(第 4 张答了两次;第 5 张三天前那次不算)', answered5() === 6, `${answered5()}`);
db5.exec(`INSERT INTO review_log (card_id, ts, grade, archived) VALUES (1, ${N5 + 20 * MIN5}, 3, 1)`);
check('清空进度归档的流水照算:今天确实学过(ADR-0005)', answered5() === 7, `${answered5()}`);
db5.exec(`INSERT INTO review_log (card_id, ts, grade) VALUES (1, ${from5 - MIN5}, 3)`);
check('凌晨 3 点之前的那次算昨天', answered5() === 7, `${answered5()}`);
db5.close();

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
if (fail > 0) { process.exit(1); }
