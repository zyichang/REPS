/**
 * 浏览器(Anki Browse)查询的回归测试。
 *
 * 盯三件事:
 *   1. 卡组过滤与搜索能组合,0 表示全部
 *   2. 用户输入里的 % 和 _ 是**字面量**,不是通配符
 *   3. 中文子串能搜到(SQLite 的 LIKE 对非 ASCII 只做精确匹配,子串本身没问题)
 */
import { DatabaseSync } from 'node:sqlite';
import { DDL, SQL_BROWSE, browseArgs, escapeLike } from './Schema';

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
db.exec(`INSERT INTO decks (id, name) VALUES (1, 'Math'), (2, 'Words')`);
let id = 1;
function add(deck: number, front: string, back: string, title: string = ''): void {
  const ins = db.prepare(`INSERT INTO notes (id, deck_id, type, front, back, title, options, answer,
           source_file, fingerprint, uuid, updated_at)
           VALUES (?, ?, 0, ?, ?, ?, '', '', 'x.md', ?, ?, 0)`);
  ins.run(id, deck, front, back, title, `fp${id}`, `n${id}`);
  db.prepare(`INSERT INTO cards (id, note_id, ordinal, uuid, updated_at) VALUES (?, ?, 0, ?, 0)`)
    .run(id, id, `c${id}`);
  id++;
}
add(1, '求极限 lim x->0', '答案 1');
add(1, '增长率 100% 时', '翻倍');
add(1, '增长率 1000 时', '十倍');
add(1, 'snake_case 命名', '下划线');
add(1, 'snakeXcase', '没有下划线');
add(2, 'apple', '苹果', '水果');
add(2, 'path C:\\temp', '反斜杠');
add(2, 'pathXCtemp', '无');

interface Row { card_id: number; deck_name: string; front: string }
function q(deck: number, text: string): Row[] {
  return db.prepare(SQL_BROWSE).all(...browseArgs(deck, text)) as Row[];
}

console.log('=== 1. 卡组过滤 ===');
check('全部卡组、不搜:8 张', q(0, '').length === 8, `${q(0, '').length}`);
check('Math 5 张', q(1, '').length === 5);
check('Words 3 张', q(2, '').length === 3);
check('只有空白的搜索词等于不搜', q(0, '   ').length === 8);
check('按卡组名排序:Math 在前', q(0, '')[0].deck_name === 'Math');

console.log('\n=== 2. 通配符是字面量 ===');
check('escapeLike 转义 % _ \\', escapeLike('a%b_c\\d') === 'a\\%b\\_c\\\\d', escapeLike('a%b_c\\d'));
const pct = q(0, '100%');
check('**搜「100%」只命中真有 100% 的那张**,不连带 1000', pct.length === 1 && pct[0].front.includes('100%'),
  pct.map((r) => r.front).join(' | '));
const und = q(0, 'snake_case');
check('**搜「snake_case」不把 snakeXcase 也搜出来**', und.length === 1, und.map((r) => r.front).join(' | '));
const bs = q(0, 'C:\\temp');
check('反斜杠按字面量匹配', bs.length === 1 && bs[0].front.includes('\\'), bs.map((r) => r.front).join(' | '));

console.log('\n=== 3. 中文与字段 ===');
check('中文子串:极限', q(0, '极限').length === 1);
check('搜背面:苹果', q(0, '苹果').length === 1);
check('搜标题:水果', q(0, '水果').length === 1);
check('ASCII 不区分大小写:APPLE', q(0, 'APPLE').length === 1);

console.log('\n=== 4. 过滤与搜索组合 ===');
check('Words 里搜「增长率」:0', q(2, '增长率').length === 0);
check('Math 里搜「增长率」:2', q(1, '增长率').length === 2);
check('全部里搜「下划线」:2(两张背面都含)', q(0, '下划线').length === 2);

db.close();
console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
if (fail > 0) {
  process.exit(1);
}
