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
import { SQL_EXPORT_DECK, SQL_EXPORT_NOTES, SQL_UPDATE_NOTE_TEXT, parseTagsColumn, parseTimeLimitsColumn, splitOptions } from './Schema';
import {
  DeckMeta, ParsedCard, ParsedDeck, choiceCardOf, emptyMeta, optionBody, parseOneCard, parseQuizify, titleAfterEdit,
} from './Quizify';
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
  const d = db.prepare(SQL_EXPORT_DECK).get(deckId) as {
    name: string; uuid: string; tags: string; meta: string; time_limits: string;
  };
  let meta: DeckMeta = emptyMeta();
  if (d.meta.length > 0) {
    meta = { ...emptyMeta(), ...(JSON.parse(d.meta) as DeckMeta) };
  }
  const deck: ExportDeck = {
    name: d.name, uuid: d.uuid, tags: parseTagsColumn(d.tags), meta: meta,
    timeLimits: parseTimeLimitsColumn(d.time_limits),
  };
  const rows = db.prepare(SQL_EXPORT_NOTES).all(deckId) as {
    uuid: string; type: number; kind: string; title: string; front: string; back: string; options: string;
    answer: string; tags: string;
  }[];
  const cards: ExportCard[] = rows.map((r) => ({
    uuid: r.uuid, type: r.type, kind: r.kind, title: r.title, front: r.front, back: r.back,
    options: r.options.length > 0 ? r.options.split('\n') : [], answer: r.answer, tags: parseTagsColumn(r.tags),
  }));
  return exportYaml(deck, cards);
}

/** 两张卡内容一致(id 另外比) */
function sameCard(a: ParsedCard, b: ParsedCard): string {
  const fields: [string, string, string][] = [
    ['type', `${a.type}`, `${b.type}`], ['kind', a.kind, b.kind], ['title', a.title, b.title],
    ['front', a.front, b.front],
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
check('坏的 time_limits 列当没写', parseTimeLimitsColumn('not json').length === 0 &&
  parseTimeLimitsColumn('').length === 0 && parseTimeLimitsColumn('{"choice":2}').length === 0 &&
  parseTimeLimitsColumn('[{"kind":"choice"}]').length === 0 && parseTimeLimitsColumn('[{"kind":"choice","minutes":0}]').length === 0);
check('好的 time_limits 列', JSON.stringify(parseTimeLimitsColumn('[{"kind":"choice","minutes":2.5}]')) ===
  '[{"kind":"choice","minutes":2.5}]');

// ---------------------------------------------------------------- 7
console.log('=== 7. v2:题型往返,版本号取够用的最低 ===');
const v2src: ParsedDeck = parseYamlDeck(['reps: 2', 'meta:', '  id: 9a1b2c3d-0000-4000-8000-0000000000aa',
  'deck: "写作与计算"', 'cards:',
  '  - id: e-1', '    type: qa', '    kind: essay', '    front: "论说文:题目"', '    back: "范文"', '',
  '  - id: l-1', '    kind: long', '    front: "求极限"', '    back: "答案"', '',
  '  - id: s-1', '    front: "没写题型"', '    back: "答"', ''].join('\n'));
const db7 = freshDb();
const r7 = importParsed(db7, v2src, 1);
const text7 = exportFrom(db7, r7.deckId);
check('**用到题型的牌组导出成 reps: 2**', text7.startsWith('reps: 2\n'), text7.split('\n')[0]);
check('写了题型的卡导出 kind', text7.includes('    kind: essay\n') && text7.includes('    kind: long\n'));
check('没写题型的卡不写 kind', (text7.match(/kind:/g) ?? []).length === 2);
check('**没用到题型的牌组仍写 reps: 1**', text1.startsWith('reps: 1\n'), text1.split('\n')[0]);
let back7: ParsedDeck | null = null;
try {
  back7 = parseYamlDeck(text7);
} catch (e) {
  check('reps: 2 的导出能解析', false, `${e}\n${text7}`);
}
if (back7 !== null) {
  check('reps: 2 的导出能解析', back7.format === 2, `${back7.format}`);
  for (let i = 0; i < v2src.cards.length; i++) {
    const diff = sameCard(v2src.cards[i], back7.cards[i]);
    check(`v2 卡 ${i + 1} 往返无损(含题型)`, diff === '', diff);
  }
  // 云同步下载走的也是 parseYamlDeck → 导入:另一台设备拿到同样的题型
  const dev2 = freshDb();
  importParsed(dev2, back7, 2);
  const kinds = (dev2.prepare(`SELECT kind FROM notes ORDER BY id`).all() as { kind: string }[])
    .map((r) => r.kind).join(',');
  check('另一台设备(空库)导入后题型一样', kinds === 'essay,long,', kinds);
}

// ---------------------------------------------------------------- 8
console.log('=== 8. v2:牌组的 time_limits 往返 ===');
const tlsrc: ParsedDeck = parseYamlDeck(['reps: 2', 'meta:', '  id: 9a1b2c3d-0000-4000-8000-0000000000bb',
  'deck: "限时"', 'time_limits:', '  choice: 2.5', '  essay: 30', 'cards:',
  '  - id: c-1', '    front: "甲"', '    back: "乙"', ''].join('\n'));
const db8 = freshDb();
const r8 = importParsed(db8, tlsrc, 1);
const text8 = exportFrom(db8, r8.deckId);
check('**只用了 time_limits(没有 kind)也写 reps: 2**', text8.startsWith('reps: 2\n'), text8.split('\n')[0]);
check('time_limits 原样写回(2.5 还是 2.5,30 还是 30)', text8.includes('time_limits:\n  choice: 2.5\n  essay: 30\n'), text8);
let back8: ParsedDeck | null = null;
try {
  back8 = parseYamlDeck(text8);
} catch (e) {
  check('带 time_limits 的导出能解析', false, `${e}\n${text8}`);
}
if (back8 !== null) {
  check('带 time_limits 的导出能解析', back8.format === 2);
  check('time_limits 往返一致', JSON.stringify(back8.timeLimits) === JSON.stringify(tlsrc.timeLimits),
    JSON.stringify(back8.timeLimits));
}

// ---------------------------------------------------------------- 9
console.log('=== 9. 在 App 里改选择卡和问答卡 → 存回去 → 导出(.scratch/editor-choice-card-loss) ===');
const editSrcText = ['reps: 2', 'meta:', '  id: 9a1b2c3d-0000-4000-8000-0000000000cc',
  'deck: "编辑测试"', 'time_limits:', '  choice: 2.5', 'cards:',
  '  - id: ch-1', '    type: choice', '    kind: choice', '    title: "2015 年第 1 题 · 问题求解"',
  '    front: "下列哪种排序是稳定的?"', '    options: ["快速排序", "归并排序", "堆排序", "选择排序"]', '    answer: B',
  '    back: "归并排序合并时保持相等元素的先后。"', '    tags: [真题2015, 数学]', '',
  '  - id: es-1', '    type: qa', '    kind: essay', '    title: "2015 年第 57 题 · 论说文"',
  '    front: "论说文:以「坚持」为话题"', '    back: "审题:坚持是手段。"', '    tags: [写作]', ''].join('\n');
const editSrc: ParsedDeck = parseYamlDeck(editSrcText);
const db9 = freshDb();
const r9 = importParsed(db9, editSrc, 100);
interface NoteRow9 {
  id: number; type: number; kind: string; title: string; front: string; back: string; options: string;
  answer: string; tags: string; content_hash: string;
}
const note9 = (cid: string): NoteRow9 => db9.prepare(
  `SELECT id, type, kind, title, front, back, options, answer, tags, content_hash FROM notes WHERE uuid = ?`)
  .get(`${r9.deckUuid}/${cid}`) as unknown as NoteRow9;
const before9 = note9('ch-1');
// 这张卡学过:排期挂在卡片上,编辑不能动它
const card9 = (db9.prepare(`SELECT id FROM cards WHERE note_id = ?`).get(before9.id) as { id: number }).id;
db9.exec(`INSERT INTO scheduling (card_id, stability, difficulty, reps, lapses, streak, last_review, due, phase, step,
          first_seen, updated_at) VALUES (${card9}, 4.2, 5, 3, 0, 3, 150, 9000, 2, 0, 120, 150)`);

// 编辑页打开:库里的选项 → 表单(和 CardEditPage.aboutToAppear 一样)
const stored9 = splitOptions(before9.options);
const opts9 = stored9.map((s, i) => optionBody(s, i));
const marks9 = opts9.map((_, i) => before9.answer.includes(String.fromCharCode(65 + i)));
check('编辑页拿到的选项不带字母', opts9.join('|') === '快速排序|归并排序|堆排序|选择排序', opts9.join('|'));
check('编辑页拿到的正确答案是 B', marks9.join(',') === 'false,true,false,false', marks9.join(','));

// 用户的修改:B 改个字;删掉 C(堆排序);加一个插入排序;改成多选:A 快速排序、C 选择排序(原来是 D)都对
opts9[1] = '归并排序(稳定)';
opts9.splice(2, 1);
marks9.splice(2, 1);
opts9.push('插入排序');
marks9.push(false);
marks9[0] = true;
marks9[1] = false;
marks9[2] = true;
const edited9 = choiceCardOf(before9.title, '下列哪些排序**不**稳定?', '', opts9, marks9, true);
db9.prepare(SQL_UPDATE_NOTE_TEXT).run(edited9.type, edited9.front, edited9.back, edited9.title,
  edited9.options.join('\n'), edited9.answer, 200, before9.id);
const after9 = note9('ch-1');
check('**存回去以后还是选择卡**(不再变成问答卡)', after9.type === 1, `type=${after9.type}`);
check('选项按新的顺序编号', after9.options === 'A. 快速排序\nB. 归并排序(稳定)\nC. 选择排序\nD. 插入排序',
  JSON.stringify(after9.options));
check('答案 AC', after9.answer === 'AC', after9.answer);
check('标题、题型、标签都没变', after9.title === before9.title && after9.kind === 'choice' && after9.tags === before9.tags,
  `${after9.title} / ${after9.kind} / ${after9.tags}`);
const sched9 = db9.prepare(`SELECT stability, due, reps FROM scheduling WHERE card_id = ?`).get(card9) as {
  stability: number; due: number; reps: number;
};
check('学习进度没动', sched9.stability === 4.2 && sched9.due === 9000 && sched9.reps === 3, JSON.stringify(sched9));

// 问答卡(写作题):走 parseOneCard,标题保持原来的
const es9 = note9('es-1');
const qaParsed9 = parseOneCard('编辑测试', es9.front, '审题:坚持是手段,不是目的。');
qaParsed9.title = titleAfterEdit(es9.title, es9.front, qaParsed9.title);
db9.prepare(SQL_UPDATE_NOTE_TEXT).run(qaParsed9.type, qaParsed9.front, qaParsed9.back, qaParsed9.title,
  qaParsed9.options.join('\n'), qaParsed9.answer, 200, es9.id);
const es9b = note9('es-1');
check('**问答卡改完,YAML 里单独写的标题还在**', es9b.title === '2015 年第 57 题 · 论说文', es9b.title);
check('问答卡的题型 essay 还在', es9b.kind === 'essay', es9b.kind);

// 导出 → 重新解析:改过的内容都在,id 不变
const text9 = exportFrom(db9, r9.deckId);
let back9: ParsedDeck | null = null;
try {
  back9 = parseYamlDeck(text9);
} catch (e) {
  check('改过的牌组导出后能解析', false, `${e}\n${text9}`);
}
if (back9 !== null) {
  const c9 = back9.cards.find((c) => c.id === 'ch-1');
  const e9 = back9.cards.find((c) => c.id === 'es-1');
  check('改过的牌组导出后能解析', c9 !== undefined && e9 !== undefined);
  if (c9 !== undefined && e9 !== undefined) {
    check('导出的选择卡:选项、答案、题干', c9.type === 1 && c9.answer === 'AC'
      && c9.options.map((o, i) => optionBody(o, i)).join('|') === '快速排序|归并排序(稳定)|选择排序|插入排序'
      && c9.front === '下列哪些排序**不**稳定?', `${c9.answer} ${c9.options.join('|')}`);
    check('导出的选择卡没有解析(选择卡可以不写)', c9.back === '', JSON.stringify(c9.back));
    check('导出的两张卡:标题、题型、标签原样',
      c9.title === '2015 年第 1 题 · 问题求解' && c9.kind === 'choice' && c9.tags.join(',') === '真题2015,数学'
      && e9.title === '2015 年第 57 题 · 论说文' && e9.kind === 'essay' && e9.back === '审题:坚持是手段,不是目的。');
  }
}

// 用没改过的原文件重新导入:内容哈希还是原文件的,导入认为这两张卡没变,在 App 里的修改留着。
// (bug 文件里写的「重新导入能恢复」不成立;原文件里这张卡改了,才会用文件的版本覆盖)
check('编辑不改内容哈希', after9.content_hash === before9.content_hash);
const r9b = importParsed(db9, parseYamlDeck(editSrcText), 300);
check('**原文件重新导入:不覆盖 App 里的修改**', r9b.unchanged === 2 && r9b.updated === 0 && note9('ch-1').answer === 'AC',
  JSON.stringify(r9b));
const changedText = editSrcText.replace('answer: B', 'answer: C');
const r9c = importParsed(db9, parseYamlDeck(changedText), 400);
check('原文件里这张卡变了:用文件的版本', r9c.updated === 1 && note9('ch-1').answer === 'C' && note9('ch-1').type === 1,
  JSON.stringify(r9c));

console.log(`\n结果: ${pass} 通过, ${fail} 失败`);
process.exit(fail === 0 ? 0 : 1);
