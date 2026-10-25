/**
 * YAML v1 导出(Task 5)的回归测试。
 *
 * 导入 → 用生产 SQL 从库里取出 → exportYaml → parseYamlDeck,断言:
 *   - 每张卡的 id、题型、标题、正反面、选项、答案、标签逐字段一致(往返无损);
 *   - 冒号、#、引号、反斜杠、公式、多行、缩进的代码块都原样回来;
 *   - 导出文件里没有任何排期 / 流水 / 打卡数据;
 *   - 把导出的文件再导入同一个库:什么都不改(id 对得上);导入一个空库:id 也一样。
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { SQL_EXPORT_DECK, SQL_EXPORT_NOTES, parseTagsColumn } from './Schema';
import { DeckMeta, ParsedCard, ParsedDeck, emptyMeta, parseQuizify } from './Quizify';
import { parseYamlDeck } from './Yaml';
import { ExportCard, ExportDeck, cardIdOf, exportYaml, optionText } from './YamlExport';
import { freshDb, importParsed } from './importsim';

const here = dirname(fileURLToPath(import.meta.url));

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

/** 与 Database.exportDeckYaml 对应:生产 SQL 取行 → exportYaml */
function exportFrom(db: DatabaseSync, deckId: number): string {
  const d = db.prepare(SQL_EXPORT_DECK).get(deckId) as { name: string; uuid: string; tags: string; meta: string };
  let meta: DeckMeta = emptyMeta();
  if (d.meta.length > 0) {
    meta = { ...emptyMeta(), ...(JSON.parse(d.meta) as DeckMeta) };
  }
  const deck: ExportDeck = { name: d.name, uuid: d.uuid, tags: parseTagsColumn(d.tags), meta: meta };
  const rows = db.prepare(SQL_EXPORT_NOTES).all(deckId) as {
    uuid: string; type: number; title: string; front: string; back: string; options: string; answer: string;
    tags: string;
  }[];
  const cards: ExportCard[] = rows.map((r) => ({
    uuid: r.uuid, type: r.type, title: r.title, front: r.front, back: r.back,
    options: r.options.length > 0 ? r.options.split('\n') : [], answer: r.answer, tags: parseTagsColumn(r.tags),
  }));
  return exportYaml(deck, cards);
}

/** 两张卡内容一致(id 另外比) */
function sameCard(a: ParsedCard, b: ParsedCard): string {
  const fields: [string, string, string][] = [
    ['type', `${a.type}`, `${b.type}`], ['title', a.title, b.title], ['front', a.front, b.front],
    ['back', a.back, b.back], ['options', a.options.join('|'), b.options.join('|')], ['answer', a.answer, b.answer],
    ['tags', a.tags.join('|'), b.tags.join('|')],
  ];
  for (const [k, x, y] of fields) {
    if (x !== y) {
      return `${k}: ${JSON.stringify(x)} ≠ ${JSON.stringify(y)}`;
    }
  }
  return '';
}

// ---------------------------------------------------------------- 1
console.log('=== 1. ADR-0007 示例:导入 → 导出 → 解析,逐字段一致 ===');
const src: ParsedDeck = parseYamlDeck(readFileSync(join(here, '..', 'testdata', 'format-example.yaml'), 'utf8'));
const db = freshDb();
const r1 = importParsed(db, src, 1000);
const text1 = exportFrom(db, r1.deckId);
let back1: ParsedDeck | null = null;
try {
  back1 = parseYamlDeck(text1);
} catch (e) {
  check('导出的文件能被重新解析', false, `${e}\n${text1}`);
}
if (back1 !== null) {
  check('导出的文件能被重新解析', true);
  check('reps: 1', back1.format === 1);
  check('meta.id = 牌组 uuid', back1.meta.id === r1.deckUuid, back1.meta.id);
  check('meta 其余字段保留', back1.meta.author === 'zyichang' && back1.meta.license === 'CC-BY-4.0' &&
    back1.meta.generatedBy === 'manual' && back1.meta.version === 1, JSON.stringify(back1.meta));
  check('deck、tags', back1.deck === src.deck && back1.tags.join() === src.tags.join());
  check('张数', back1.cards.length === src.cards.length, `${back1.cards.length}`);
  for (let i = 0; i < src.cards.length; i++) {
    const diff = sameCard(src.cards[i], back1.cards[i]);
    check(`卡 ${i + 1} 内容一致`, diff === '', diff);
    check(`卡 ${i + 1} id 原样`, back1.cards[i].id === src.cards[i].id, back1.cards[i].id);
  }
}

// ---------------------------------------------------------------- 2
console.log('=== 2. 刁钻内容 ===');
const tricky = `reps: 1
deck: "带: 冒号 # 和 \\"引号\\" 的牌组"
tags: ["a, b", "c"]
cards:
  - id: t-1
    title: "下列说法正确的是: 甲"
    front: |
      \`#include <stdio.h>\` 里的 # 不是注释
      路径 C:\\\\temp\\\\x 与 $\\frac{a}{b}$、$$\\int_0^1 x\\,dx$$

      空行之后的第二段 "带引号"
    back: "no"
    tags: ["重点: 必考", "第一章"]
  - id: t-2
    front: |2
        int main() {
          return 0;
        }
      上面是缩进的代码
    back: "代码首行带前导空格"
  - id: t-3
    type: choice
    front: "选出所有正确的:"
    options: ["1, 2 是一项", "it's", "$O(\\\\log n)$", "一个很长很长很长很长很长很长很长很长很长很长的选项"]
    answer: [A, D]
  - id: t-4
    type: cloze
    front: "{{顺序}}、{{选择}}、{{循环}}"
`;
let tsrc: ParsedDeck | null = null;
try {
  tsrc = parseYamlDeck(tricky);
} catch (e) {
  check('刁钻的源文件本身能解析', false, `${e}`);
}
if (tsrc !== null) {
  check('源文件里缩进代码的前导空格读出来了(|2)', tsrc.cards[1].front.startsWith('  int main()'),
    JSON.stringify(tsrc.cards[1].front));
  const db2 = freshDb();
  const r2 = importParsed(db2, tsrc, 1);
  const text2 = exportFrom(db2, r2.deckId);
  let back2: ParsedDeck | null = null;
  try {
    back2 = parseYamlDeck(text2);
  } catch (e) {
    check('刁钻内容导出后能解析', false, `${e}\n${text2}`);
  }
  if (back2 !== null) {
    check('刁钻内容导出后能解析', true);
    check('牌组名带冒号 # 引号', back2.deck === tsrc.deck, back2.deck);
    check('牌组 tags 里的逗号', back2.tags.join('|') === 'a, b|c', back2.tags.join('|'));
    for (let i = 0; i < tsrc.cards.length; i++) {
      const diff = sameCard(tsrc.cards[i], back2.cards[i]);
      check(`刁钻卡 ${i + 1} 往返无损`, diff === '', diff);
    }
    check('长选项写成多行列表', text2.includes('    options:\n      - '), '');
    check('缩进代码写了 |2', text2.includes('front: |2'), '');
  }
}

// ---------------------------------------------------------------- 3
console.log('=== 3. 隐私:导出里没有任何学习数据 ===');
const cardId = (db.prepare(`SELECT id FROM cards LIMIT 1`).get() as { id: number }).id;
db.exec(`INSERT INTO scheduling (card_id, stability, difficulty, reps, lapses, last_review, due)
         VALUES (${cardId}, 12.345, 6.789, 42, 7, 1761300000000, 1761999999999)`);
db.exec(`INSERT INTO review_log (card_id, ts, grade, cost_ms) VALUES (${cardId}, 1761300000000, 3, 98765)`);
db.exec(`INSERT INTO checkins (day, ts) VALUES (20385, 1761300000000)`);
const text3 = exportFrom(db, r1.deckId);
check('导出与写进学习数据之前完全一样', text3 === text1);
for (const needle of ['12.345', '6.789', '1761999999999', '98765', '20385', 'stability', 'due', 'grade',
  'review', 'checkin', 'scheduling']) {
  check(`不含「${needle}」`, !text3.includes(needle));
}
const topKeys = text3.split('\n').filter((l) => /^[a-z_]+:/.test(l)).map((l) => l.split(':')[0]);
check('顶层只有 reps / meta / deck / tags / cards', topKeys.every((k) => ['reps', 'meta', 'deck', 'tags', 'cards'].includes(k)),
  topKeys.join(','));

// ---------------------------------------------------------------- 4
console.log('=== 4. 导出的文件再导入 ===');
const again = importParsed(db, parseYamlDeck(text1), 2000);
check('导回同一个库:同一副牌组、什么都不改', again.deckId === r1.deckId && again.added === 0 &&
  again.updated === 0 && again.missing === 0 && again.unchanged === 4, JSON.stringify(again));
const other = freshDb();
const r4 = importParsed(other, parseYamlDeck(text1), 3000);
const uuidsA = (db.prepare(`SELECT uuid FROM notes WHERE deck_id = ? ORDER BY id`).all(r1.deckId) as { uuid: string }[])
  .map((r) => r.uuid).join(',');
const uuidsB = (other.prepare(`SELECT uuid FROM notes ORDER BY id`).all() as { uuid: string }[]).map((r) => r.uuid).join(',');
check('导入另一台设备(空库):牌组 uuid 相同', r4.deckUuid === r1.deckUuid);
check('导入另一台设备(空库):每张卡 uuid 相同(同步靠它)', uuidsA === uuidsB, uuidsB);

// ---------------------------------------------------------------- 5
console.log('=== 5. 没有 id 的旧卡(Quizify 导入)也能导出、导回 ===');
const md = parseQuizify(['---', 'quizify:', '  deck: 旧牌组', '---', '', '+++', '', '#### 基础选择 (1) 算法是( )',
  '', ';;;', 'A. 程序', 'B. 步骤的描述', ';;;B', '***', '解析', '', '+++', '', '#### 1.2 挖空',
  '三种结构 {{顺序}}', '***', '说明', ''].join('\n'));
const db5 = freshDb();
const r5 = importParsed(db5, md, 1);
const text5 = exportFrom(db5, r5.deckId);
let back5: ParsedDeck | null = null;
try {
  back5 = parseYamlDeck(text5);
} catch (e) {
  check('Quizify 牌组导出后能解析', false, `${e}\n${text5}`);
}
if (back5 !== null) {
  check('Quizify 牌组导出后能解析', true);
  check('选择题变成 options / answer', back5.cards[0].options.join('|') === 'A. 程序|B. 步骤的描述' &&
    back5.cards[0].answer === 'B', back5.cards[0].options.join('|'));
  check('选择题正面不含答案', !text5.includes(';;;'));
  check('生成的 id 写进了文件', back5.cards.every((c) => c.id.length > 0));
  for (let i = 0; i < md.cards.length; i++) {
    const diff = sameCard(md.cards[i], back5.cards[i]);
    check(`Quizify 卡 ${i + 1} 往返无损`, diff === '', diff);
  }
  const again5 = importParsed(db5, back5, 2);
  check('导回:什么都不改', again5.added === 0 && again5.updated === 0 && again5.unchanged === 2, JSON.stringify(again5));
  // Task 6:同一副卡,.md 导入的库与 .yaml 导入的库,内容逐字段相同
  const dbY = freshDb();
  importParsed(dbY, back5, 3);
  const q = `SELECT type, title, front, back, options, answer, tags FROM notes ORDER BY id`;
  check('同一副卡用 .md 与 .yaml 分别导入:库里的内容完全相同',
    JSON.stringify(db5.prepare(q).all()) === JSON.stringify(dbY.prepare(q).all()));
}

// ---------------------------------------------------------------- 6
console.log('=== 6. 小函数 ===');
check('剥掉本牌组前缀', cardIdOf('D', 'D/c-1') === 'c-1');
check('没有前缀的旧 uuid 原样', cardIdOf('D', 'n-mh3k2x-8f1a') === 'n-mh3k2x-8f1a');
check('别的牌组的前缀:不合法字符换成 -', cardIdOf('D', 'E/c-1') === 'E-c-1');
check('选项去掉字母前缀', optionText('C. 队列') === '队列' && optionText('无前缀') === '无前缀');
check('坏的 tags 列当空列表', parseTagsColumn('not json').length === 0 && parseTagsColumn('').length === 0);

console.log(`\n结果: ${pass} 通过, ${fail} 失败`);
process.exit(fail === 0 ? 0 : 1);
