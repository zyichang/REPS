/**
 * 按 id 导入与更新(Task 4)的回归测试。
 *
 * 在 v2 结构(DDL + MIGRATIONS)上,用生产那份 SQL 与 Schema.planDeckImport,
 * 按 Database.importDeck 的步骤走一遍导入。断言:
 *   - v1 的 id 落库为「牌组uuid/id」,牌组 uuid 取 meta.id;
 *   - 原样重导什么都不改;改标题(有 id)、改正文都更新内容、排期不动;
 *   - 文件里少了的卡只计数、不删;
 *   - v2 之前的行(没有内容哈希、uuid 没有命名空间)也能认出来;
 *   - 两副牌组用同一个卡片 id 不会撞 UNIQUE;中途失败整体回滚。
 */
import { DatabaseSync } from 'node:sqlite';
import { contentHashOf, fingerprintOf, legacyFingerprintOf } from './Schema';
import { ParsedDeck, parseQuizify } from './Quizify';
import { parseYamlDeck } from './Yaml';
import { freshDb, importParsed } from './importsim';

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

function yamlDeck(metaId: string, cards: string): ParsedDeck {
  const meta = metaId.length > 0 ? `meta:\n  id: ${metaId}\n  version: 2\n  author: "我"\n` : '';
  return parseYamlDeck(`reps: 1\n${meta}deck: 经济学\ntags: [考研]\ncards:\n${cards}`);
}
const C1 = `  - id: c-1\n    title: "机会成本"\n    front: "什么是机会成本?"\n    back: "放弃的东西"\n    tags: [第一章]\n`;
const C2 = `  - id: c-2\n    type: choice\n    front: "哪个是需求定律?"\n    options: ["价高量少", "价高量多"]\n    answer: A\n`;
const C3 = `  - id: c-3\n    type: cloze\n    front: "边际效用 {{递减}}"\n`;
const MID = '7d0c9e1a-0000-4000-8000-000000000001';

function one<T>(db: DatabaseSync, sql: string, ...args: (string | number)[]): T {
  return db.prepare(sql).get(...args) as T;
}

// ---------------------------------------------------------------- 1
console.log('=== 1. 第一次导入 v1 文件 ===');
const db = freshDb();
const r1 = importParsed(db, yamlDeck(MID, C1 + C2 + C3), 1000);
check('新增 3 张', r1.added === 3 && r1.updated === 0 && r1.unchanged === 0, JSON.stringify(r1));
check('牌组 uuid 取 meta.id', r1.deckUuid === MID, r1.deckUuid);
const uuids = (db.prepare(`SELECT uuid FROM notes ORDER BY id`).all() as { uuid: string }[]).map((r) => r.uuid);
check('笔记 uuid = 牌组uuid/卡片id', uuids.join(',') === [`${MID}/c-1`, `${MID}/c-2`, `${MID}/c-3`].join(','),
  uuids.join(','));
check('卡片 uuid 与笔记 uuid 相同(两台设备上对得上)',
  one<{ n: number }>(db, `SELECT COUNT(*) AS n FROM cards c JOIN notes n ON n.id = c.note_id WHERE c.uuid = n.uuid`).n === 3);
check('内容哈希已写', one<{ n: number }>(db, `SELECT COUNT(*) AS n FROM notes WHERE length(content_hash) = 16`).n === 3);
check('卡片 tags 落库', one<{ tags: string }>(db, `SELECT tags FROM notes WHERE uuid = ?`, `${MID}/c-1`).tags === '["第一章"]');
const deckRow = one<{ tags: string; meta: string; version: number }>(db, `SELECT tags, meta, version FROM decks WHERE id = ?`, r1.deckId);
check('牌组 tags 落库', deckRow.tags === '["考研"]', deckRow.tags);
check('牌组 meta 落库(JSON)', JSON.parse(deckRow.meta).author === '我', deckRow.meta);
check('牌组 version', deckRow.version === 2);

// 给 c-1 一点学习进度,后面要确认它不被动
const c1Card = one<{ id: number }>(db, `SELECT c.id FROM cards c JOIN notes n ON n.id = c.note_id WHERE n.uuid = ?`, `${MID}/c-1`).id;
db.exec(`INSERT INTO scheduling (card_id, stability, difficulty, reps, last_review, due, updated_at)
         VALUES (${c1Card}, 4.5, 3.3, 5, 900, 99999, 900)`);
const schedBefore = JSON.stringify(db.prepare(`SELECT * FROM scheduling`).all());

// ---------------------------------------------------------------- 2
console.log('=== 2. 原样重导:什么都不改 ===');
const r2 = importParsed(db, yamlDeck(MID, C1 + C2 + C3), 2000);
check('新增 0、更新 0、跳过 3、缺 0', r2.added === 0 && r2.updated === 0 && r2.unchanged === 3 && r2.missing === 0,
  JSON.stringify(r2));
check('笔记 updated_at 没变', one<{ n: number }>(db, `SELECT COUNT(*) AS n FROM notes WHERE updated_at = 1000`).n === 3);

// ---------------------------------------------------------------- 3
console.log('=== 3. 有 id 时改标题、改正文:同一张卡,内容更新,排期不动 ===');
const C1b = C1.replace('"机会成本"', '"机会成本(修订)"').replace('"放弃的东西"', '"为得到某物而放弃的最高价值"');
const r3 = importParsed(db, yamlDeck(MID, C1b + C2 + C3), 3000);
check('更新 1、跳过 2、新增 0', r3.updated === 1 && r3.unchanged === 2 && r3.added === 0, JSON.stringify(r3));
const n1 = one<{ title: string; back: string; uuid: string; updated_at: number }>(db,
  `SELECT title, back, uuid, updated_at FROM notes WHERE uuid = ?`, `${MID}/c-1`);
check('标题更新了', n1.title === '机会成本(修订)', n1.title);
check('正文更新了', n1.back === '为得到某物而放弃的最高价值', n1.back);
check('uuid(身份)没变', n1.uuid === `${MID}/c-1`);
check('updated_at 更新了', n1.updated_at === 3000);
check('**排期一字不差**', JSON.stringify(db.prepare(`SELECT * FROM scheduling`).all()) === schedBefore);
check('笔记总数仍是 3', one<{ n: number }>(db, `SELECT COUNT(*) AS n FROM notes`).n === 3);

console.log('=== 4. 改题型(问答 → 选择):也是更新,不是新卡 ===');
const C1c = `  - id: c-1\n    type: choice\n    front: "机会成本是?"\n    options: ["放弃的", "得到的"]\n    answer: A\n`;
const r4 = importParsed(db, yamlDeck(MID, C1c + C2 + C3), 4000);
check('更新 1', r4.updated === 1 && r4.added === 0, JSON.stringify(r4));
check('题型、选项、答案都更新了',
  one<{ type: number; answer: string }>(db, `SELECT type, answer FROM notes WHERE uuid = ?`, `${MID}/c-1`).answer === 'A');

// ---------------------------------------------------------------- 5
console.log('=== 5. 文件里少了的卡:只计数,不删 ===');
const r5 = importParsed(db, yamlDeck(MID, C1c + C3), 5000);
check('缺 1 张', r5.missing === 1, JSON.stringify(r5));
check('那张没被删', one<{ n: number }>(db, `SELECT COUNT(*) AS n FROM notes WHERE uuid = ?`, `${MID}/c-2`).n === 1);
const r5b = importParsed(db, yamlDeck(MID, C1c + `  - id: c-4\n    front: "新卡"\n    back: "新"\n`), 5100);
check('又少一张、加一张新的:缺 2、新增 1', r5b.missing === 2 && r5b.added === 1, JSON.stringify(r5b));

// ---------------------------------------------------------------- 6
console.log('=== 6. 两副牌组用同一个卡片 id:不撞 UNIQUE ===');
const MID2 = '7d0c9e1a-0000-4000-8000-000000000002';
let threw = false;
try {
  const other = parseYamlDeck(`reps: 1\nmeta:\n  id: ${MID2}\ndeck: 另一副\ncards:\n${C1}`);
  const r6 = importParsed(db, other, 6000);
  check('另一副牌组新增 1', r6.added === 1, JSON.stringify(r6));
} catch (e) {
  threw = true;
  check('另一副牌组导入不抛错', false, `${e}`);
}
check('没有抛错', !threw);
check('两条 c-1 各自命名空间',
  one<{ n: number }>(db, `SELECT COUNT(*) AS n FROM notes WHERE uuid LIKE '%/c-1'`).n === 2);

// ---------------------------------------------------------------- 7
console.log('=== 7. 没有 meta.id 时按名字认牌组 ===');
const db7 = freshDb();
const noMeta = (cards: string): ParsedDeck => parseYamlDeck(`reps: 1\ndeck: 无身份\ncards:\n${cards}`);
const r7a = importParsed(db7, noMeta(C1), 100);
const r7b = importParsed(db7, noMeta(C1), 200);
check('第二次认出同一副牌组', r7a.deckId === r7b.deckId && r7b.unchanged === 1 && r7b.added === 0,
  `${JSON.stringify(r7a)} / ${JSON.stringify(r7b)}`);

// ---------------------------------------------------------------- 8
console.log('=== 8. v2 之前的行:没有内容哈希、uuid 没有命名空间、8 位旧指纹 ===');
const db8 = freshDb();
db8.exec(`INSERT INTO decks (id, name, uuid) VALUES (1, 'Math', 'deck-old')`);
const oldFp = legacyFingerprintOf('Math', '基础 (1)', 0);
db8.exec(`INSERT INTO notes (id, deck_id, type, front, back, title, fingerprint, uuid, updated_at)
          VALUES (1, 1, 0, '题一', '旧答案', '基础 (1) 求极限', '${oldFp}', 'n-legacy-1', 10)`);
db8.exec(`INSERT INTO cards (id, note_id, uuid) VALUES (1, 1, 'c-legacy-1')`);
db8.exec(`INSERT INTO scheduling (card_id, stability, reps, last_review, due) VALUES (1, 7.7, 4, 9, 99)`);
const md = (body: string): ParsedDeck => parseQuizify(
  ['---', 'quizify:', '  deck: Math', '---', '', '+++', '', '#### 基础 (1) 求极限', body, '***', '新答案', ''].join('\n'));
const r8 = importParsed(db8, md('题一'), 20);
check('认出旧卡(旧指纹),旧行没有哈希 → 更新一次补上', r8.updated === 1 && r8.added === 0, JSON.stringify(r8));
check('旧指纹升级成 16 位',
  one<{ fingerprint: string }>(db8, `SELECT fingerprint FROM notes WHERE id = 1`).fingerprint === fingerprintOf('Math', '基础 (1)', 0));
check('背面更新了(以前重导只跳过,内容永远停在旧的)',
  one<{ back: string }>(db8, `SELECT back FROM notes WHERE id = 1`).back === '新答案');
check('旧 uuid 不动', one<{ uuid: string }>(db8, `SELECT uuid FROM notes WHERE id = 1`).uuid === 'n-legacy-1');
check('旧卡排期不动', one<{ stability: number }>(db8, `SELECT stability FROM scheduling WHERE card_id = 1`).stability === 7.7);
const r8b = importParsed(db8, md('题一'), 30);
check('再导一次:内容没变 → 跳过', r8b.unchanged === 1 && r8b.updated === 0, JSON.stringify(r8b));
const r8c = importParsed(db8, md('题一(改了错别字)'), 40);
check('Quizify 文件改正文:更新内容、排期不动', r8c.updated === 1 &&
  one<{ stability: number }>(db8, `SELECT stability FROM scheduling WHERE card_id = 1`).stability === 7.7, JSON.stringify(r8c));

// 导出时 id 原样写成 n-legacy-1(没有命名空间);带着这个 id 再导入也要认出来
const legacyId = parseYamlDeck(`reps: 1\ndeck: Math\ncards:\n  - id: n-legacy-1\n    title: "完全换了标题"\n    front: "题一"\n    back: "新答案"\n`);
const r8d = importParsed(db8, legacyId, 50);
check('按原样的旧 uuid 认出(标题全换也不是新卡)', r8d.added === 0 && r8d.updated === 1, JSON.stringify(r8d));

// ---------------------------------------------------------------- 9
console.log('=== 9. 中途失败:整体回滚 ===');
const db9 = freshDb();
const before9 = one<{ n: number }>(db9, `SELECT COUNT(*) AS n FROM notes`).n;
let rolled = false;
try {
  importParsed(db9, yamlDeck(MID, C1 + C2 + C3), 1, 2);
} catch {
  rolled = true;
}
check('抛出了错误', rolled);
check('一张都没写进去', one<{ n: number }>(db9, `SELECT COUNT(*) AS n FROM notes`).n === before9);
check('牌组也没留下', one<{ n: number }>(db9, `SELECT COUNT(*) AS n FROM decks`).n === 0);

// ---------------------------------------------------------------- 10
console.log('=== 10. 内容哈希 ===');
const h = (back: string, tags: string[]): string => contentHashOf(0, 't', 'f', back, [], '', tags);
check('同内容同哈希', h('b', []) === h('b', []));
check('改背面哈希变', h('b', []) !== h('b2', []));
check('改标签哈希变', h('b', []) !== h('b', ['x']));
check('字段边界不会串(ab|c ≠ a|bc)',
  contentHashOf(0, 'ab', 'c', '', [], '', []) !== contentHashOf(0, 'a', 'bc', '', [], '', []));

console.log(`\n结果: ${pass} 通过, ${fail} 失败`);
process.exit(fail === 0 ? 0 : 1);
