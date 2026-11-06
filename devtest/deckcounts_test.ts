/**
 * 牌组列表计数的回归测试(Anki 式主界面)。
 *
 * 风险和统计页一样:**同一个数在两个地方各算一遍。** 牌组列表用一条
 * 分组 SQL 给出全部卡组的数字,落地页用的是逐组的几条单查询。两边只要
 * 对不上,用户在列表上看到「待复习 12」,点进去却是 9。
 *
 * 所以这里对每个卡组、每个口径,都拿 SQL_DECK_COUNTS + applyDeckLimits
 * 去和落地页那条路径对拍。
 */
import { DatabaseSync } from 'node:sqlite';
import {
  DDL, DeckCountRow, DeckCounts, SQL_DECK_COUNTS, SQL_DUE_TOUCHED_IDS, SQL_DUE_UNTOUCHED_IDS, SQL_NEW_INTRODUCED_TODAY,
  SQL_REVIEWS_DONE_TODAY, SQL_TODAY_PROGRESS, SQL_UNLEARNED_COUNT, SQL_UNTOUCHED_DUE,
  SQL_UPSERT_SCHEDULING, SchedulingRow, applyDeckLimits, dayIndex, dayStart, leftToday, schedulingValues,
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

// 三个卡组:A、B 各 30 张新卡(用来测「上限按组各算」),C 用来放各种排期状态
db.exec(`INSERT INTO decks (id, name) VALUES (1, 'A'), (2, 'B'), (3, 'C')`);
let nextId = 1;
function addCard(deck: number): number {
  const id = nextId++;
  db.exec(`INSERT INTO notes (id, deck_id, type, front, back, title, options, answer,
           source_file, fingerprint, uuid, updated_at)
           VALUES (${id}, ${deck}, 0, 'f', 'b', 't${id}', '', '', 'x.md',
                   'fp${id}', 'n${id}', 0)`);
  db.exec(`INSERT INTO cards (id, note_id, ordinal, uuid, updated_at)
           VALUES (${id}, ${id}, 0, 'c${id}', 0)`);
  return id;
}
function sched(card: number, due: number, last: number, firstSeen: number): void {
  db.exec(`INSERT INTO scheduling (card_id, stability, difficulty, reps, lapses, streak,
           last_review, due, phase, step, first_seen) VALUES
           (${card}, 1, 5, 1, 0, 1, ${last}, ${due}, 2, 0, ${firstSeen})`);
}

for (let i = 0; i < 30; i++) {
  addCard(1);
  addCard(2);
}

const now = Date.UTC(2026, 5, 10, 6, 0);      // 当地时间中午前后,远离日界
const today = dayIndex(now);
const dayFrom = dayStart(today);
const dayTo = dayStart(today + 1);
const H = 3600 * 1000;
const D = 24 * H;

// C 组:每一种状态各放几张
for (let i = 0; i < 4; i++) { sched(addCard(3), now - D, now - 3 * D, now - 10 * D); }   // 昨天就到期、今天没答
for (let i = 0; i < 2; i++) { sched(addCard(3), dayTo - H, now - 5 * D, now - 9 * D); }  // 今天晚些到期
for (let i = 0; i < 3; i++) { sched(addCard(3), now + 10 * 60000, now - H, now - H); }   // 今天新学、10 分钟后回来
for (let i = 0; i < 5; i++) { sched(addCard(3), now + 3 * D, now - 2 * H, now - 20 * D); } // 今天复习过、已稳
for (let i = 0; i < 6; i++) { sched(addCard(3), now + 30 * D, now - 9 * D, now - 40 * D); } // 远未到期
for (let i = 0; i < 7; i++) { addCard(3); }                                               // 没学过
// A 组:今天已经引入了 5 张新卡(都在步进里)
for (let i = 1; i <= 5; i++) { sched(i * 2 - 1, now + 5 * 60000, now - H, now - H); }

interface RawRow {
  id: number; name: string; cards: number; unlearned: number; untouched_due: number;
  new_today: number; again: number; settled: number; reviews_done_today: number;
}
interface NRow { n: number }
interface PRow { settled: number | null; again: number | null }
interface IdRow { card_id: number }

function deckCounts(): RawRow[] {
  return db.prepare(SQL_DECK_COUNTS)
    .all(dayTo, dayFrom, dayFrom, dayFrom, dayTo, dayFrom, dayTo, dayFrom, dayFrom) as RawRow[];
}
const raw = deckCounts();

function rowOf(r: RawRow): DeckCountRow {
  return {
    id: r.id, name: r.name, cards: r.cards, unlearned: r.unlearned,
    untouchedDue: r.untouched_due, newToday: r.new_today, again: r.again, settled: r.settled,
    reviewsDoneToday: r.reviews_done_today,
  };
}

console.log('=== 1. 分组 SQL 与落地页的逐组查询逐列一致 ===');
const BIG = 1000000;
for (const limits of [[20, 200], [3, 2], [0, 0], [20, 8]]) {
  const [newPerDay, reviewLimit] = limits;
  for (const r of raw) {
    const got = applyDeckLimits(rowOf(r), newPerDay, reviewLimit);
    // 落地页那条路径(StudyPage.refresh 的算法,原样照抄)
    const usedReview = (db.prepare(SQL_REVIEWS_DONE_TODAY).get(dayFrom, dayFrom, r.id, r.id) as NRow).n;
    const leftReview = leftToday(reviewLimit, usedReview);
    const usedNew = (db.prepare(SQL_NEW_INTRODUCED_TODAY).get(dayFrom, r.id, r.id) as NRow).n;
    const leftNew = leftToday(newPerDay, usedNew);
    const wantNew = (db.prepare(SQL_UNLEARNED_COUNT).get(r.id, r.id, leftNew) as NRow).n;
    const wantDue = (db.prepare(SQL_UNTOUCHED_DUE)
      .get(dayTo, dayFrom, r.id, r.id, leftReview) as NRow).n;
    const pr = db.prepare(SQL_TODAY_PROGRESS).get(dayTo, dayTo, dayFrom, r.id, r.id) as PRow;
    const tag = `${r.name} 上限 ${newPerDay}/${reviewLimit}`;
    check(`${tag} 待学习`, got.newCount === wantNew, `${got.newCount} vs ${wantNew}`);
    check(`${tag} 待复习`, got.dueCount === wantDue, `${got.dueCount} vs ${wantDue}`);
    check(`${tag} 学习中`, got.learnCount === (pr.again ?? 0), `${got.learnCount} vs ${pr.again}`);
    check(`${tag} 已学完`, got.settled === (pr.settled ?? 0), `${got.settled} vs ${pr.settled}`);
    check(`${tag} 今天已复习`, r.reviews_done_today === usedReview, `${r.reviews_done_today} vs ${usedReview}`);
    // 不设上限时原始数也要对上
    const rawNew = (db.prepare(SQL_UNLEARNED_COUNT).get(r.id, r.id, BIG) as NRow).n;
    check(`${r.name} 原始未学数`, r.unlearned === rawNew, `${r.unlearned} vs ${rawNew}`);
  }
}

console.log('\n=== 2. 每日上限按卡组各算一份 ===');
const byName = new Map<string, DeckCountRow>();
for (const r of raw) {
  byName.set(r.name, rowOf(r));
}
const a = applyDeckLimits(byName.get('A') as DeckCountRow, 20, 200);
const b = applyDeckLimits(byName.get('B') as DeckCountRow, 20, 200);
check('B 组 30 张新卡、额度 20 → 20', b.newCount === 20, `${b.newCount}`);
check('**A 组今天已引入 5 张,只剩 15**(额度不串组)', a.newCount === 15, `${a.newCount}`);
check('A 组那 5 张算「学习中」', a.learnCount === 5, `${a.learnCount}`);
check('两组合计 35,不是共享的 20', a.newCount + b.newCount === 35);

const c = applyDeckLimits(byName.get('C') as DeckCountRow, 20, 200);
check('C 组待复习 = 昨天到期 4 + 今天晚些到期 2', c.dueCount === 6, `${c.dueCount}`);
check('C 组学习中 = 今天新学的 3 张', c.learnCount === 3, `${c.learnCount}`);
check('C 组已学完 = 今天复习过、已稳的 5 张', c.settled === 5, `${c.settled}`);
check('C 组待学习 = 7(低于额度,不截断)', c.newCount === 7, `${c.newCount}`);
check('C 组今天已复习 5 张(今天新学的 3 张不算)', (byName.get('C') as DeckCountRow).reviewsDoneToday === 5,
  `${(byName.get('C') as DeckCountRow).reviewsDoneToday}`);
const c2 = applyDeckLimits(byName.get('C') as DeckCountRow, 20, 8);
check('**复习上限 8、今天已复习 5 → 待复习只剩 3**', c2.dueCount === 3, `${c2.dueCount}`);
const c3 = applyDeckLimits(byName.get('C') as DeckCountRow, 20, 4);
check('复习上限 4 已经用完 → 待复习 0', c3.dueCount === 0, `${c3.dueCount}`);
check('上限用完不影响学习中(今天答过、还会回来的照常出)', c3.learnCount === 3, `${c3.learnCount}`);

console.log('\n=== 2b. 开始一轮:今天答过又到期的卡不受复习上限约束 ===');
// 15 分钟后:C 组「今天新学」的 3 张步进到期了(今天答过),「昨天就到期」的 4 张还没答
const t2 = now + 15 * 60000;
function sessionDue(t: number, deck: number, left: number): number[] {
  const touched = db.prepare(SQL_DUE_TOUCHED_IDS).all(t, dayFrom, deck, deck) as IdRow[];
  const untouched = db.prepare(SQL_DUE_UNTOUCHED_IDS).all(t, dayFrom, deck, deck, left) as IdRow[];
  return touched.concat(untouched).map((r) => r.card_id);
}
check('剩余复习额度 2:学习步 3 张 + 没答过的 2 张', sessionDue(t2, 3, 2).length === 5, `${sessionDue(t2, 3, 2).length}`);
check('**额度用完(0):学习步那 3 张照样回来**', sessionDue(t2, 3, 0).length === 3, `${sessionDue(t2, 3, 0).length}`);
check('额度充足:3 + 4', sessionDue(t2, 3, 200).length === 7, `${sessionDue(t2, 3, 200).length}`);
check('卡组 0 = 全部卡组(A 组步进里的 5 张也到期了)', sessionDue(t2, 0, 200).length === 12,
  `${sessionDue(t2, 0, 200).length}`);

console.log('\n=== 3. 空卡组不出现,顺序按名字 ===');
db.exec(`INSERT INTO decks (id, name) VALUES (9, 'Empty')`);
const raw2 = deckCounts();
check('没有卡的卡组不列出', raw2.every((r) => r.name !== 'Empty'));
check('按名字升序', raw2.map((r) => r.name).join(',') === 'A,B,C', raw2.map((r) => r.name).join(','));

console.log('\n=== 4. 另一台设备的进度同步过来以后,本机的「今天」跟着变 ===');
// 照 Database.applySchedRow 整行 upsert(它随后还会改 updated_at,那一列只管同步,不影响计数)
function applyRemote(card: number, due: number, last: number, firstSeen: number): void {
  const row: SchedulingRow = {
    card_id: card, stability: 1, difficulty: 5, reps: 1, lapses: 0, streak: 1,
    last_review: last, due: due, phase: 1, step: 0, first_seen: firstSeen,
  };
  db.prepare(SQL_UPSERT_SCHEDULING).run(...schedulingValues(row));
}
function rawOf(name: string): DeckCountRow {
  return rowOf(deckCounts().find((x) => x.name === name) as RawRow);
}
function limitedOf(name: string, newPerDay: number, reviewLimit: number): DeckCounts {
  return applyDeckLimits(rawOf(name), newPerDay, reviewLimit);
}
// D 组 100 张新卡;另一台设备(手机)今天学了前 20 张,还在步进里
db.exec(`INSERT INTO decks (id, name) VALUES (4, 'D')`);
const dCards: number[] = [];
for (let i = 0; i < 100; i++) {
  dCards.push(addCard(4));
}
check('同步之前:平板额度 75 → 75', limitedOf('D', 75, 200).newCount === 75);
for (let i = 0; i < 20; i++) {
  applyRemote(dCards[i], now + 10 * 60000, now - 30 * 60000, now - 40 * 60000);
}
check('**手机学了 20 张以后:平板额度 75 → 只剩 55**', limitedOf('D', 75, 200).newCount === 55,
  `${limitedOf('D', 75, 200).newCount}`);
check('手机自己(额度 20)→ 0', limitedOf('D', 20, 200).newCount === 0, `${limitedOf('D', 20, 200).newCount}`);
check('那 20 张在平板上算「学习中」', limitedOf('D', 75, 200).learnCount === 20,
  `${limitedOf('D', 75, 200).learnCount}`);
// C 组:手机复习了一张「昨天就到期」的卡
const cDue = (db.prepare(SQL_DUE_UNTOUCHED_IDS).all(now, dayFrom, 3, 3, 1) as IdRow[])[0].card_id;
const doneBefore = rawOf('C').reviewsDoneToday;
const dueBefore = limitedOf('C', 20, 8).dueCount;
applyRemote(cDue, now + 3 * D, now - 20 * 60000, now - 10 * D);
const doneAfter = rawOf('C').reviewsDoneToday;
const dueAfter = limitedOf('C', 20, 8).dueCount;
check('C 组今天已复习 5 → 6', doneBefore === 5 && doneAfter === 6, `${doneBefore} → ${doneAfter}`);
check('**复习上限 8:待复习 3 → 2(手机复习的也扣额度)**', dueBefore === 3 && dueAfter === 2,
  `${dueBefore} → ${dueAfter}`);

db.close();
console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
if (fail > 0) {
  process.exit(1);
}
