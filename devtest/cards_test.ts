/**
 * 手工建卡 / 浏览 / 编辑 / 删除 的回归测试。
 *
 * 分两半:
 *   1. `parseOneCard` —— 手工输入的题型判定必须与导入完全一致
 *   2. 新增的那几条 SQL —— 在真的 sqlite 上跑,尤其是
 *      「没学过的卡没有 scheduling 行」这个 LEFT JOIN 陷阱
 */
import { DatabaseSync } from 'node:sqlite';
import { NoteType } from './Models';
import { QuizifyError, parseOneCard } from './Quizify';
import {
  DDL, SQL_AHEAD_CARDS, SQL_AHEAD_CARDS_IN_DECK, SQL_NEW_INTRODUCED_TODAY,
  SQL_COUNT_CARDS_IN_DECK,
  SQL_TODAY_PROGRESS, SQL_UNLEARNED_COUNT, SQL_UNTOUCHED_DUE, SQL_DELETE_NOTE, SQL_DELETE_NOTE_CARDS,
  SQL_DELETE_NOTE_LOGS, SQL_DELETE_NOTE_SCHED, SQL_LIST_CARDS_ALL, SQL_LIST_CARDS_IN_DECK,
  SQL_UPDATE_NOTE_TEXT,
} from './Schema';

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, got?: string): void {
  if (ok) {
    pass++;
    console.log(`  PASS  ${name}${got !== undefined ? '  ' + got : ''}`);
  } else {
    fail++;
    console.log(`  FAIL  ${name}${got !== undefined ? '  got: ' + got : ''}`);
  }
}

// ================================================================ 1. parseOneCard
console.log('\n=== 1. 手工输入的题型由内容决定,不需要界面开关 ===');

const qa = parseOneCard('测试::章', '什么是栈?', '后进先出的线性表。');
check('纯文字 -> 问答', qa.type === NoteType.QA, `type=${qa.type}`);
check('问答的 clozeCount 为 0', qa.clozeCount === 0);

const cloze = parseOneCard('测试::章', '栈是{{后进先出}},队列是{{先进先出}}', '两种线性表。');
check('写了 {{}} -> 挖空', cloze.type === NoteType.Cloze, `type=${cloze.type}`);
check('挖空数记为 2', cloze.clozeCount === 2, `${cloze.clozeCount}`);
check('一张卡(不按空拆,ADR-0002)', cloze.front.includes('{{后进先出}}'), '保留原标记');

const choice = parseOneCard('测试::章',
  '栈的存取方式是()。\n\n;;;\nA. 先进先出\nB. 后进先出\n;;;B',
  '后进先出。');
check('写了 ;;; -> 选择题', choice.type === NoteType.Choice, `type=${choice.type}`);
check('选项被切出来', choice.options.length === 2, `${choice.options.length}`);
check('答案离开正面', choice.answer === 'B', choice.answer);
check('正面不含答案行', !choice.front.includes(';;;B'), '已剥离');

const titled = parseOneCard('测试::章', '#### 2.1 顺序表\n\n复杂度?', '$O(1)$');
check('#### 标题被提取', titled.title.includes('2.1 顺序表'), titled.title);

function expectReject(name: string, front: string, back: string, part: string): void {
  try {
    parseOneCard('测试::章', front, back);
    check(name, false, '竟然通过了');
  } catch (e) {
    const ok = e instanceof QuizifyError && (e as QuizifyError).message.includes(part);
    check(name, ok, `${e}`);
  }
}
expectReject('空正面被拒', '   ', '答案', '正面不能是空的');
expectReject('空背面被拒', '题目', '  ', '背面不能是空的');
expectReject('正面混入 +++ 被拒', '甲\n+++\n乙', '答案', '结构标记');
expectReject('背面混入 *** 被拒', '题目', '甲\n***\n乙', '结构标记');

// ================================================================ 2. SQL
console.log('\n=== 2. 浏览 / 改写 / 删除的 SQL ===');

const db = new DatabaseSync(':memory:');
for (const stmt of DDL) {
  db.exec(stmt);
}

db.exec(`INSERT INTO decks (id, name) VALUES (1, '测试')`);
db.exec(`INSERT INTO notes (id, deck_id, type, front, back, title, options, answer,
         source_file, fingerprint, uuid, updated_at)
         VALUES (1, 1, 0, '学过的卡', '答案1', 'T1', '', '', 'f.md', 'fp-1', 'n1', 1000)`);
db.exec(`INSERT INTO notes (id, deck_id, type, front, back, title, options, answer,
         source_file, fingerprint, uuid, updated_at)
         VALUES (2, 1, 0, '没学过的卡', '答案2', 'T2', '', '', 'f.md', 'fp-2', 'n2', 1000)`);
db.exec(`INSERT INTO cards (id, note_id, ordinal, uuid, updated_at) VALUES (1, 1, 0, 'c1', 1000)`);
db.exec(`INSERT INTO cards (id, note_id, ordinal, uuid, updated_at) VALUES (2, 2, 0, 'c2', 1000)`);
// 只给第一张卡排期 —— 第二张是「从没学过」
db.exec(`INSERT INTO scheduling (card_id, stability, difficulty, reps, lapses, streak,
         last_review, due, phase, step, first_seen)
         VALUES (1, 3.2, 5.0, 4, 0, 4, 900, 5000, 2, 0, 900)`);

interface Row {
  card_id: number;
  note_id: number;
  type: number;
  title: string;
  front: string;
  back: string;
  due: number;
  reps: number;
}

const inDeck = db.prepare(SQL_LIST_CARDS_IN_DECK).all(1) as Row[];
check('列出卡组里的全部卡片', inDeck.length === 2, `${inDeck.length}`);
check('**没学过的卡也在列表里**(LEFT JOIN,不是 INNER)',
  inDeck.some((r) => r.note_id === 2), inDeck.map((r) => r.note_id).join(','));
const unlearned = inDeck.find((r) => r.note_id === 2) as Row;
check('没学过的卡 due 为 0', unlearned.due === 0, `${unlearned.due}`);
check('没学过的卡 reps 为 0', unlearned.reps === 0, `${unlearned.reps}`);
const learned = inDeck.find((r) => r.note_id === 1) as Row;
check('学过的卡带出真实 reps', learned.reps === 4, `${learned.reps}`);

const all = db.prepare(SQL_LIST_CARDS_ALL).all() as Row[];
check('跨卡组列出全部卡片', all.length === 2, `${all.length}`);

// ---- 改写:题型跟着内容变,指纹不动 ----
const before = db.prepare(`SELECT fingerprint FROM notes WHERE id = 1`).get() as Record<string, string>;
db.prepare(SQL_UPDATE_NOTE_TEXT).run(
  NoteType.Cloze as number, '改成{{挖空}}了', '新答案', 'T1改', '', '', 2000, 1);
const after = db.prepare(
  `SELECT type, front, back, title, fingerprint, updated_at FROM notes WHERE id = 1`,
).get() as Record<string, string | number>;
check('题型被改写', (after.type as number) === (NoteType.Cloze as number), `${after.type}`);
check('正面被改写', (after.front as string) === '改成{{挖空}}了', after.front as string);
check('**指纹不变**(内容改了但还是同一张卡)',
  (after.fingerprint as string) === before.fingerprint, after.fingerprint as string);
check('updated_at 被刷新', (after.updated_at as number) === 2000, `${after.updated_at}`);

const schedStill = db.prepare(`SELECT COUNT(*) AS n FROM scheduling WHERE card_id = 1`)
  .get() as Record<string, number>;
check('改写内容不影响排期行', schedStill.n === 1, `${schedStill.n}`);

// ---- 删除:子表必须一起清掉 ----
db.exec(`INSERT INTO review_log (card_id, ts, grade, stability_before, elapsed_days,
         retrievability, interval_days, cost_ms, algo)
         VALUES (1, 1500, 3, 3.2, 1.0, 0.9, 5.0, 4200, 'fsrs')`);
for (const sql of [SQL_DELETE_NOTE_LOGS, SQL_DELETE_NOTE_SCHED, SQL_DELETE_NOTE_CARDS, SQL_DELETE_NOTE]) {
  db.prepare(sql).run(1);
}
const left = db.prepare(`SELECT
    (SELECT COUNT(*) FROM notes      WHERE id = 1)       AS n,
    (SELECT COUNT(*) FROM cards      WHERE note_id = 1)  AS c,
    (SELECT COUNT(*) FROM scheduling WHERE card_id = 1)  AS s,
    (SELECT COUNT(*) FROM review_log WHERE card_id = 1)  AS l`).get() as Record<string, number>;
check('笔记被删掉', left.n === 0, `${left.n}`);
check('卡片被删掉', left.c === 0, `${left.c}`);
check('排期被删掉', left.s === 0, `${left.s}`);
check('复习流水被删掉', left.l === 0, `${left.l}`);

const survivor = db.prepare(`SELECT COUNT(*) AS n FROM notes WHERE id = 2`).get() as Record<string, number>;
check('别的笔记没被连带删掉', survivor.n === 1, `${survivor.n}`);

// ================================================================ 3. 学习更多的取卡窗口
console.log('\n=== 3. 「学习更多」只拿还没到期、但在窗口内的卡 ===');

const db2 = new DatabaseSync(':memory:');
for (const stmt of DDL) {
  db2.exec(stmt);
}
db2.exec(`INSERT INTO decks (id, name) VALUES (1, 'A'), (2, 'B')`);
function seed(noteId: number, cardId: number, deck: number, due: number): void {
  db2.exec(`INSERT INTO notes (id, deck_id, type, front, back, title, options, answer,
            source_file, fingerprint, uuid, updated_at)
            VALUES (${noteId}, ${deck}, 0, 'f${noteId}', 'b${noteId}', 't${noteId}', '', '',
                    'x.md', 'fp-${noteId}', 'n${noteId}', 0)`);
  db2.exec(`INSERT INTO cards (id, note_id, ordinal, uuid, updated_at)
            VALUES (${cardId}, ${noteId}, 0, 'c${cardId}', 0)`);
  db2.exec(`INSERT INTO scheduling (card_id, stability, difficulty, reps, lapses, streak,
            last_review, due, phase, step, first_seen)
            VALUES (${cardId}, 1, 5, 1, 0, 1, 0, ${due}, 2, 0, 0)`);
}
const NOW = 1000000;
const WIN = NOW + 2 * 86400000;
seed(1, 1, 1, NOW - 5000);        // 已经到期 —— 不该出现在「学习更多」里
seed(2, 2, 1, NOW);              // 正好等于 now —— 边界,也算已到期
seed(3, 3, 1, NOW + 60000);      // 一分钟后到期 —— 应该拿到
seed(4, 4, 1, WIN - 1);          // 窗口内最后一刻 —— 应该拿到
seed(5, 5, 1, WIN + 1);          // 窗口外 —— 不该拿到
seed(6, 6, 2, NOW + 30000);      // 另一个卡组 —— 按组过滤时不该拿到

const ahead = (db2.prepare(SQL_AHEAD_CARDS_IN_DECK).all(1, NOW, WIN, 10) as Row[])
  .map((r) => r.card_id);
check('已到期的卡不在「学习更多」里(due > now,不是 >=)',
  !ahead.includes(1) && !ahead.includes(2), ahead.join(','));
check('窗口内未到期的卡都拿到', ahead.includes(3) && ahead.includes(4), ahead.join(','));
check('窗口外的卡拿不到', !ahead.includes(5), ahead.join(','));
check('别的卡组的卡拿不到(按组过滤)', !ahead.includes(6), ahead.join(','));
check('按 due 升序:最快到期的在前', ahead[0] === 3, ahead.join(','));

const capped = (db2.prepare(SQL_AHEAD_CARDS_IN_DECK).all(1, NOW, WIN, 1) as Row[]);
check('LIMIT 生效(设置里的每次张数就是它)', capped.length === 1, `${capped.length}`);

const allDecks = (db2.prepare(SQL_AHEAD_CARDS).all(NOW, WIN, 10) as Row[])
  .map((r) => r.card_id);
check('全部卡组时能跨组拿(含卡组 B 的那张)',
  allDecks.includes(6) && allDecks.includes(3), allDecks.join(','));
// ================================================================ 4. 今日进度三段条
console.log('\n=== 4. 三段条按「下次到期」分段,不按成绩 ===');

const db3 = new DatabaseSync(':memory:');
for (const stmt of DDL) {
  db3.exec(stmt);
}
db3.exec(`INSERT INTO decks (id, name) VALUES (1, 'A'), (2, 'B')`);
function seedP(noteId: number, cardId: number, deck: number, lastReview: number, due: number): void {
  db3.exec(`INSERT INTO notes (id, deck_id, type, front, back, title, options, answer,
            source_file, fingerprint, uuid, updated_at)
            VALUES (${noteId}, ${deck}, 0, 'f', 'b', 't${noteId}', '', '', 'x.md',
                    'fp${noteId}', 'n${noteId}', 0)`);
  db3.exec(`INSERT INTO cards (id, note_id, ordinal, uuid, updated_at)
            VALUES (${cardId}, ${noteId}, 0, 'c${cardId}', 0)`);
  db3.exec(`INSERT INTO scheduling (card_id, stability, difficulty, reps, lapses, streak,
            last_review, due, phase, step, first_seen)
            VALUES (${cardId}, 1, 5, 1, 0, 1, ${lastReview}, ${due}, 2, 0, 0)`);
}
const DAY_FROM = 1000000;
const DAY_TO = DAY_FROM + 86400000;

seedP(1, 1, 1, DAY_FROM + 100, DAY_TO + 5000);        // 今天答的,明天才回来 -> 绿
seedP(2, 2, 1, DAY_FROM + 200, DAY_TO + 999999);      // 同上 -> 绿
// **关键一条**:今天答对了,但还在 10 分钟步进里,今天还会回来 -> 灰,不是绿
seedP(3, 3, 1, DAY_FROM + 300, DAY_FROM + 900000);
seedP(4, 4, 1, DAY_FROM - 50000, DAY_TO + 1000);      // 昨天答的 -> 两段都不算
seedP(5, 5, 2, DAY_FROM + 400, DAY_TO + 1000);        // 别的卡组 -> 按组过滤时不算

interface PRow { settled: number; again: number }
const p1 = db3.prepare(SQL_TODAY_PROGRESS).get(DAY_TO, DAY_TO, DAY_FROM, 1, 1) as PRow;
check('绿 = 今天答过且今天不再出现', p1.settled === 2, `${p1.settled}`);
check('**灰 = 今天答过但今天还会回来**(新卡答对仍在步进里)',
  p1.again === 1, `${p1.again}`);

const pAll = db3.prepare(SQL_TODAY_PROGRESS).get(DAY_TO, DAY_TO, DAY_FROM, 0, 0) as PRow;
check('卡组传 0 时跨全部卡组统计', pAll.settled === 3, `${pAll.settled}`);
check('按组过滤时别的卡组不计入', p1.settled + p1.again === 3, `${p1.settled + p1.again}`);

const pB = db3.prepare(SQL_TODAY_PROGRESS).get(DAY_TO, DAY_TO, DAY_FROM, 2, 2) as PRow;
check('只数本组:卡组 B 只有 1 张', pB.settled === 1 && pB.again === 0,
  `settled=${pB.settled} again=${pB.again}`);
// ================================================================ 5. 三段条是同一批卡的划分
console.log('\n=== 5. 绿/灰/白三色总数固定,只在彼此之间流转 ===');

const db4 = new DatabaseSync(':memory:');
for (const stmt of DDL) {
  db4.exec(stmt);
}
db4.exec(`INSERT INTO decks (id, name) VALUES (1, 'A')`);
let nid = 0;
function mk(due: number | null, lastReview: number, firstSeen: number): number {
  nid++;
  db4.exec(`INSERT INTO notes (id, deck_id, type, front, back, title, options, answer,
            source_file, fingerprint, uuid, updated_at)
            VALUES (${nid}, 1, 0, 'f', 'b', 't${nid}', '', '', 'x.md',
                    'fp${nid}', 'n${nid}', 0)`);
  db4.exec(`INSERT INTO cards (id, note_id, ordinal, uuid, updated_at)
            VALUES (${nid}, ${nid}, 0, 'c${nid}', 0)`);
  if (due !== null) {
    db4.exec(`INSERT INTO scheduling (card_id, stability, difficulty, reps, lapses, streak,
              last_review, due, phase, step, first_seen)
              VALUES (${nid}, 1, 5, 1, 0, 1, ${lastReview}, ${due}, 2, 0, ${firstSeen})`);
  }
  return nid;
}
const DAY_F = 1000000;
const DAY_T = DAY_F + 86400000;
const YDAY = DAY_F - 3600000;

// 今天答过、明天才回来 -> 绿
mk(DAY_T + 5000, DAY_F + 10, YDAY);
// 今天答过、今天还会回来 -> 灰
mk(DAY_F + 60000, DAY_F + 20, YDAY);
// 今天没答过、今天之内到期 -> 白
mk(DAY_F + 70000, YDAY, YDAY);
// 从没学过 -> 白(新卡那一半)
mk(null, 0, 0);

interface Row2 { n: number }
interface PRow2 { settled: number; again: number }
const p5 = db4.prepare(SQL_TODAY_PROGRESS).get(DAY_T, DAY_T, DAY_F, 1, 1) as PRow2;
const whiteDue = (db4.prepare(SQL_UNTOUCHED_DUE).get(DAY_T, DAY_F, 1, 1, 999) as Row2).n;
const whiteNew = (db4.prepare(SQL_UNLEARNED_COUNT).get(1, 1, 999) as Row2).n;

check('绿 = 今天答过且今天不再出现', p5.settled === 1, `${p5.settled}`);
check('灰 = 今天答过但今天还回来', p5.again === 1, `${p5.again}`);
check('**白不包含今天答过的卡**(这是原来的 bug)', whiteDue === 1, `${whiteDue}`);
check('白的新卡部分 = 没有排期行的卡', whiteNew === 1, `${whiteNew}`);
check('三色加起来 = 全部 4 张(总数固定)',
  p5.settled + p5.again + whiteDue + whiteNew === 4,
  `${p5.settled}+${p5.again}+${whiteDue}+${whiteNew}`);

// 那张灰卡到期了再答一次:它应该还在灰里,**不能又被算进白**
db4.exec(`UPDATE scheduling SET last_review = ${DAY_F + 30}, due = ${DAY_F + 120000}
          WHERE card_id = 2`);
const p6 = db4.prepare(SQL_TODAY_PROGRESS).get(DAY_T, DAY_T, DAY_F, 1, 1) as PRow2;
const whiteDue2 = (db4.prepare(SQL_UNTOUCHED_DUE).get(DAY_T, DAY_F, 1, 1, 999) as Row2).n;
check('灰卡再答一次仍然只算一次灰', p6.again === 1, `${p6.again}`);
check('**灰卡不会同时进白**', whiteDue2 === 1, `${whiteDue2}`);
check('总数仍然是 4', p6.settled + p6.again + whiteDue2 + whiteNew === 4,
  `${p6.settled + p6.again + whiteDue2 + whiteNew}`);

// 新卡额度按天算:今天引入过的要从额度里扣掉
const intro = (db4.prepare(SQL_NEW_INTRODUCED_TODAY).get(DAY_F, 1, 1) as Row2).n;
check('今天引入的新卡数 = 0(三张都是昨天引入的)', intro === 0, `${intro}`);
db4.exec(`INSERT INTO scheduling (card_id, stability, difficulty, reps, lapses, streak,
          last_review, due, phase, step, first_seen)
          VALUES (4, 1, 5, 1, 0, 1, ${DAY_F + 40}, ${DAY_F + 90000}, 1, 0, ${DAY_F + 40})`);
const intro2 = (db4.prepare(SQL_NEW_INTRODUCED_TODAY).get(DAY_F, 1, 1) as Row2).n;
check('今天引入一张新卡后计为 1(额度才真的是每天的)', intro2 === 1, `${intro2}`);
const whiteNew2 = (db4.prepare(SQL_UNLEARNED_COUNT).get(1, 1, 999) as Row2).n;
check('那张新卡学过之后不再算白的新卡部分', whiteNew2 === 0, `${whiteNew2}`);
db4.close();

db3.close();

db2.close();

db.close();

// 「开始学习」按钮的启用条件靠它,而它在接上按钮之前一直是死代码:
// 原来 notes 也被别名成 n,和输出列 `AS n` 撞了,所以谁都没发现。
{
  const dbc = new DatabaseSync(':memory:');
  for (const stmt of DDL) {
    dbc.exec(stmt);
  }
  dbc.exec(`INSERT INTO decks (id, name) VALUES (1, 'A'), (2, 'B')`);
  for (let i = 1; i <= 4; i++) {
    dbc.exec(`INSERT INTO notes (id, deck_id, type, front, back, title, options, answer,
              source_file, fingerprint, uuid, updated_at)
              VALUES (${i}, 1, 0, 'f', 'b', 't${i}', '', '', 'x.md', 'fq${i}', 'v${i}', 0)`);
    dbc.exec(`INSERT INTO cards (id, note_id, ordinal, uuid, updated_at)
              VALUES (${i}, ${i}, 0, 'w${i}', 0)`);
  }
  interface NRow { n: number }
  const c1 = (dbc.prepare(SQL_COUNT_CARDS_IN_DECK).get(1) as NRow).n;
  check('按卡组数卡片数,输出列就叫 n(scalar 靠它取值)', c1 === 4, `${c1}`);
  const c2 = (dbc.prepare(SQL_COUNT_CARDS_IN_DECK).get(2) as NRow).n;
  check('空卡组返回 0', c2 === 0, `${c2}`);
  const c0 = (dbc.prepare(SQL_COUNT_CARDS_IN_DECK).get(999) as NRow).n;
  check('不存在的卡组返回 0,不是报错', c0 === 0, `${c0}`);
  dbc.close();
}

// ================================================================ 6. 落地页三个数字 == 进度条三段
console.log('\n=== 6. 待学习 + 待复习 == 白,学习中 == 灰(恒等式) ===');
{
  const dbi = new DatabaseSync(':memory:');
  for (const stmt of DDL) {
    dbi.exec(stmt);
  }
  dbi.exec(`INSERT INTO decks (id, name) VALUES (1, 'Book')`);
  let k = 0;
  function card(due: number | null, lastReview: number, firstSeen: number): void {
    k++;
    dbi.exec(`INSERT INTO notes (id, deck_id, type, front, back, title, options, answer,
              source_file, fingerprint, uuid, updated_at)
              VALUES (${k}, 1, 0, 'f', 'b', 'T${k}', '', '', 'x.md', 'g${k}', 'h${k}', 0)`);
    dbi.exec(`INSERT INTO cards (id, note_id, ordinal, uuid, updated_at)
              VALUES (${k}, ${k}, 0, 'i${k}', 0)`);
    if (due !== null) {
      dbi.exec(`INSERT INTO scheduling (card_id, stability, difficulty, reps, lapses, streak,
                last_review, due, phase, step, first_seen)
                VALUES (${k}, 1, 5, 1, 0, 1, ${lastReview}, ${due}, 2, 0, ${firstSeen})`);
    }
  }
  const F = 5000000;            // 今日起点
  const T = F + 86400000;       // 今日截止
  const Y = F - 7200000;        // 昨天

  card(T + 60000, F + 10, Y);   // 绿:今天答过,明天才回来
  card(T + 90000, F + 20, Y);   // 绿
  card(F + 300000, F + 30, Y);  // 灰:今天答过,今天还回来(**还没到点**)
  card(F - 60000, F + 40, Y);   // 灰:今天答过,已经到点了
  card(F + 500000, Y, Y);       // 白·待复习:今天没答过,今天之内到期
  card(null, 0, 0);             // 白·待学习:从没学过
  card(null, 0, 0);             // 白·待学习

  interface N { n: number }
  interface P { settled: number; again: number }
  const toLearn = (dbi.prepare(SQL_UNLEARNED_COUNT).get(1, 1, 999) as N).n;
  const toReview = (dbi.prepare(SQL_UNTOUCHED_DUE).get(T, F, 1, 1, 999) as N).n;
  const prog = dbi.prepare(SQL_TODAY_PROGRESS).get(T, T, F, 1, 1) as P;

  check('待学习 = 从没学过的卡', toLearn === 2, `${toLearn}`);
  check('待复习 = 今天之内到期且今天没答过', toReview === 1, `${toReview}`);
  check('学习中(灰) = 今天答过且今天还会回来', prog.again === 2, `${prog.again}`);
  check('已学完(绿) = 今天答过且今天不再出现', prog.settled === 2, `${prog.settled}`);

  // 白色就是这两个数之和 —— StudyPage 把 untouchedDue + untouchedNew 传给 todayProgress
  const white: number = toLearn + toReview;
  check('**待学习 + 待复习 == 白**', white === 3, `${toLearn} + ${toReview} = ${white}`);
  check('三段相加 == 今日集合总数',
    prog.settled + prog.again + white === 7,
    `${prog.settled} + ${prog.again} + ${white} = ${prog.settled + prog.again + white}`);

  /*
   * 这一条钉的是上一轮真实出过的 bug:待复习曾被改成「此刻 due <= now」。
   *
   * 问题不在于那个数字大小,而在于它**和灰色有交集** —— 今天答过、已经又到点的
   * 卡同时落进两边,于是「待学习 + 待复习」不再等于白色,三个数字和三段就对不上。
   * 这里直接量交集:只要它非空,那个口径就不能当待复习用。
   */
  const overlap = (dbi.prepare(
    `SELECT COUNT(*) AS n FROM cards c
       JOIN notes nt ON nt.id = c.note_id
       JOIN scheduling s ON s.card_id = c.id
      WHERE nt.deck_id = 1 AND s.due <= ${F + 100000} AND s.last_review >= ${F}`).get() as N).n;
  check('**「此刻到期」与灰色有交集**,所以不能拿它当待复习(上一轮的 bug)',
    overlap > 0, `交集 ${overlap} 张`);

  // 反过来,白色口径与灰色**必须零交集**,这才叫划分
  const cleanOverlap = (dbi.prepare(
    `SELECT COUNT(*) AS n FROM cards c
       JOIN notes nt ON nt.id = c.note_id
       JOIN scheduling s ON s.card_id = c.id
      WHERE nt.deck_id = 1 AND s.due < ${T} AND s.last_review < ${F}
        AND s.last_review >= ${F}`).get() as N).n;
  check('白色口径与灰色零交集(这才是划分)', cleanOverlap === 0, `交集 ${cleanOverlap} 张`);
  dbi.close();
}

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
if (fail > 0) {
  process.exit(1);
}
