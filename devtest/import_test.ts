/**
 * 重复导入的回归测试:**指纹已在库里的是旧卡,跳过;只插新卡。**
 *
 * 原来的导入对每张卡直接 INSERT,靠 notes.fingerprint 的 UNIQUE 约束报错:
 * 重导同一个文件会在第一张旧卡上失败,排在它前面的新卡却已经写进去了。
 * 这里用 node:sqlite 执行生产那份 DDL / SQL,判定逻辑就是生产的 Schema.planImport。
 */
import { DatabaseSync } from 'node:sqlite';
import { DDL, SQL_HAS_FINGERPRINT, SQL_INSERT_NOTE, fingerprintOf, planImport } from './Schema';
import { parseQuizify } from './Quizify';

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
db.exec(`INSERT INTO decks (id, name) VALUES (1, 'Math')`);

function exists(fp: string): boolean {
  return (db.prepare(SQL_HAS_FINGERPRINT).get(fp) as { n: number }).n > 0;
}

let uid = 1;
/** 模拟 Database.importDeck:按 planImport 只插新卡,整次一个事务 */
function importDoc(doc: string): { added: number; skipped: number } {
  const parsed = parseQuizify(doc, 'test');
  const plan = planImport(parsed.deck, parsed.cards.map((c) => c.key), exists);
  db.exec('BEGIN');
  try {
    for (const i of plan.fresh) {
      const c = parsed.cards[i];
      db.prepare(SQL_INSERT_NOTE).run(1, c.type, c.front, c.back, c.title, c.options.join('\n'), c.answer,
        'test', fingerprintOf(parsed.deck, c.key, 0), `n${uid++}`, 0);
    }
    db.exec('COMMIT');
  } catch (e) {
    db.exec('ROLLBACK');
    throw e;
  }
  return { added: plan.fresh.length, skipped: plan.skipped };
}

function noteCount(): number {
  return (db.prepare('SELECT COUNT(*) AS n FROM notes').get() as { n: number }).n;
}

function card(title: string, body: string): string {
  return ['+++', '', `#### ${title}`, body, '***', '答案', ''].join('\n');
}
const head = ['---', 'quizify:', '  deck: Math', '---', ''].join('\n');
const fileV1 = head + [card('基础 (1) 求极限', '题一'), card('基础 (2) 求导', '题二'),
  card('基础 (3) 积分', '题三')].join('\n');

console.log('=== 1. 第一次导入:全部是新卡 ===');
const r1 = importDoc(fileV1);
check('新增 3 张,跳过 0', r1.added === 3 && r1.skipped === 0, `${r1.added}/${r1.skipped}`);
check('库里 3 条笔记', noteCount() === 3, `${noteCount()}`);

console.log('=== 2. 原样重导:全部跳过,不报错 ===');
let threw = false;
let r2 = { added: -1, skipped: -1 };
try {
  r2 = importDoc(fileV1);
} catch (e) {
  threw = true;
}
check('重导不抛错(原来会撞 UNIQUE)', !threw);
check('新增 0 张,跳过 3', r2.added === 0 && r2.skipped === 3, `${r2.added}/${r2.skipped}`);
check('库里仍是 3 条', noteCount() === 3, `${noteCount()}`);

console.log('=== 3. 文件里新卡排在旧卡前面:只插新卡 ===');
// 原来:「基础 (0)」先插进去,接着「基础 (1)」撞 UNIQUE 抛错,文件只导入了一半
const fileV2 = head + [card('基础 (0) 预备', '新题'), card('基础 (1) 求极限', '题一'),
  card('基础 (2) 求导', '题二'), card('基础 (3) 积分', '题三'), card('基础 (4) 级数', '新题二')].join('\n');
const r3 = importDoc(fileV2);
check('新增 2 张,跳过 3', r3.added === 2 && r3.skipped === 3, `${r3.added}/${r3.skipped}`);
check('库里 5 条', noteCount() === 5, `${noteCount()}`);

console.log('=== 4. 只改正文的错别字:仍是旧卡(指纹只看编号) ===');
const fileTypo = head + [card('基础 (1) 求极限(改了错别字)', '题一改'), card('基础 (2) 求导', '题二')].join('\n');
const r4 = importDoc(fileTypo);
check('改正文不算新卡:新增 0,跳过 2', r4.added === 0 && r4.skipped === 2, `${r4.added}/${r4.skipped}`);

console.log('=== 5. planImport 兜底:同一批里指纹重复也不会抛错 ===');
const p5 = planImport('Math', ['新键 (9)', '新键 (9)', '新键 (10)'], () => false);
check('第二个重复键算跳过', p5.fresh.length === 2 && p5.skipped === 1,
  `fresh=${p5.fresh.join(',')} skipped=${p5.skipped}`);
check('保持文件里的顺序', p5.fresh[0] === 0 && p5.fresh[1] === 2);

console.log('=== 6. 换一个牌组名就是另一批卡(指纹含牌组名) ===');
const p6 = planImport('Words', ['基础 (1)'], exists);
check('另一个牌组同编号:新卡', p6.fresh.length === 1 && p6.skipped === 0);

console.log(`\n结果: ${pass} 通过, ${fail} 失败`);
process.exit(fail === 0 ? 0 : 1);
