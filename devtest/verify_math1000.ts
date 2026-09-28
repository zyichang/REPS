/**
 * 核对合并出来的两本书:Markdown 版和 YAML 版必须解析成**完全一样**的卡组。
 *
 * 这不是形式主义。YAML 导入器的做法是「读出 front / back,拼回 Quizify
 * Markdown,再交给 parseQuizify」,所以两边**本该**一致;一旦不一致,
 * 说明转换脚本在搬文本时弄坏了什么(块标量缩进、行尾、结构标记被吃掉),
 * 而这种损坏在界面上只会表现成「某几张卡长得怪」,很难定位。
 *
 * 跑法:node devtest/sync-and-test.mjs 之后
 *   tsx devtest/verify_math1000.ts
 */
import { readFileSync } from 'node:fs';
import { ParsedDeck, cardKeyOf, parseQuizify } from './Quizify';
import { parseYamlDeck } from './Yaml';

const DIR = 'C:\\temp\\math1000';

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

const mdText = readFileSync(`${DIR}\\math1000.md`, 'utf8');
const ymlText = readFileSync(`${DIR}\\math1000.yml`, 'utf8');

const t0 = Date.now();
const md: ParsedDeck = parseQuizify(mdText, 'math1000.md');
const t1 = Date.now();
const yml: ParsedDeck = parseYamlDeck(ymlText, 'math1000.yml');
const t2 = Date.now();

console.log(`=== 解析 ===`);
console.log(`  Markdown  ${md.cards.length} 张  ${t1 - t0} ms`);
console.log(`  YAML      ${yml.cards.length} 张  ${t2 - t1} ms`);

console.log('\n=== 1. 两边规模一致 ===');
check('卡片数相同', md.cards.length === yml.cards.length,
  `${md.cards.length} vs ${yml.cards.length}`);
check('卡组名相同', md.deck === yml.deck, `${md.deck} / ${yml.deck}`);
check('卡组名是平的,不含 ::', md.deck.indexOf('::') < 0, md.deck);

console.log('\n=== 2. 逐张比对 ===');
let typeDiff = 0;
let frontDiff = 0;
let backDiff = 0;
let keyDiff = 0;
let optDiff = 0;
let ansDiff = 0;
const n = Math.min(md.cards.length, yml.cards.length);
for (let i = 0; i < n; i++) {
  const a = md.cards[i];
  const b = yml.cards[i];
  if (a.type !== b.type) {
    typeDiff++;
    if (typeDiff === 1) {
      console.log(`    首个题型不一致 #${i}: md=${a.type} yml=${b.type}\n      ${a.title.slice(0, 50)}`);
    }
  }
  if (a.front !== b.front) {
    frontDiff++;
    if (frontDiff === 1) {
      console.log(`    首个正面不一致 #${i}:\n      md : ${JSON.stringify(a.front.slice(0, 80))}\n      yml: ${JSON.stringify(b.front.slice(0, 80))}`);
    }
  }
  if (a.back !== b.back) {
    backDiff++;
    if (backDiff === 1) {
      console.log(`    首个背面不一致 #${i}:\n      md : ${JSON.stringify(a.back.slice(0, 80))}\n      yml: ${JSON.stringify(b.back.slice(0, 80))}`);
    }
  }
  if (a.key !== b.key) {
    keyDiff++;
  }
  if (a.options.join('|') !== b.options.join('|')) {
    optDiff++;
  }
  if (a.answer !== b.answer) {
    ansDiff++;
  }
}
check('题型全部一致', typeDiff === 0, `${typeDiff} 张不一致`);
check('正面全部一致', frontDiff === 0, `${frontDiff} 张不一致`);
check('背面全部一致', backDiff === 0, `${backDiff} 张不一致`);
check('标识键全部一致', keyDiff === 0, `${keyDiff} 张不一致`);
check('选项全部一致', optDiff === 0, `${optDiff} 张不一致`);
check('答案全部一致', ansDiff === 0, `${ansDiff} 张不一致`);

console.log('\n=== 3. 导入后不会互相覆盖 ===');
const keys = new Set<string>();
let dup = 0;
const dupSample: string[] = [];
for (const c of md.cards) {
  const k = cardKeyOf(c.title);
  if (keys.has(k)) {
    dup++;
    if (dupSample.length < 3) {
      dupSample.push(k);
    }
  }
  keys.add(k);
}
check('**标识键互不重复**(重复会让后一张覆盖前一张)', dup === 0,
  dup === 0 ? `${keys.size} 个唯一键` : `${dup} 个重复,例如 ${dupSample.join(', ')}`);

console.log('\n=== 4. 题型分布 ===');
const byType = new Map<number, number>();
for (const c of md.cards) {
  byType.set(c.type as number, (byType.get(c.type as number) ?? 0) + 1);
}
const names = ['问答', '选择', '挖空'];
for (const [t, cnt] of [...byType.entries()].sort()) {
  console.log(`  ${names[t] ?? t}  ${cnt} 张`);
}
let withMath = 0;
for (const c of md.cards) {
  if (c.front.indexOf('$') >= 0 || c.back.indexOf('$') >= 0) {
    withMath++;
  }
}
console.log(`  含公式  ${withMath} 张`);

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
if (fail > 0) {
  process.exit(1);
}
