/**
 * YAML 子集导入的回归测试。
 *
 * 重点不在「能解析成功」,而在**该报错的时候报得准**:
 * YAML 的坑几乎全是「静默解析成了别的东西」,所以裸标量、Tab 缩进、
 * 未知字段这些都必须硬失败并给出正确行号。
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { NoteType } from './Models';
import { ParsedDeck, QuizifyError } from './Quizify';
import { parseYamlDeck } from './Yaml';

const here = dirname(fileURLToPath(import.meta.url));

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

/** 断言解析失败,并且报错行号符合预期 */
function expectError(name: string, src: string, wantLine: number, wantPart: string): void {
  try {
    parseYamlDeck(src);
    check(name, false, '竟然解析成功了');
  } catch (e) {
    if (!(e instanceof QuizifyError)) {
      check(name, false, `抛的不是 QuizifyError: ${e}`);
      return;
    }
    const err = e as QuizifyError;
    const okLine = err.line === wantLine;
    const okMsg = err.message.includes(wantPart);
    check(name, okLine && okMsg, `第 ${err.line} 行(期望 ${wantLine}): ${err.message}`);
  }
}

// ================================================================ 1. 基本解析
console.log('\n=== 1. 基本解析 ===');

const basic: ParsedDeck = parseYamlDeck(`deck: 数据结构::第二章
tags: [考研, 第二章]
cards:
  - front: "顺序表随机访问的复杂度是多少?"
    back: "$O(1)$"
  - front: "栈的特点?"
    back: "后进先出"
`);
check('deck 读出来', basic.deck === '数据结构::第二章', basic.deck);
check('deck 原样保留,不再按 :: 拆层', basic.deck === '数据结构::第二章', basic.deck);
check('tags 读出来', basic.tags.join(',') === '考研,第二章', basic.tags.join(','));
check('两张卡', basic.cards.length === 2, `${basic.cards.length}`);
check('正面内容正确', basic.cards[0].front.includes('顺序表随机访问'), basic.cards[0].front);
check('背面内容正确', basic.cards[0].back.includes('$O(1)$'), basic.cards[0].back);
check('纯问答识别为 QA', basic.cards[0].type === NoteType.QA, `type=${basic.cards[0].type}`);

// ================================================================ 2. 块标量
console.log('\n=== 2. | 块标量:多行正面 ===');

const block: ParsedDeck = parseYamlDeck(`deck: 测试
cards:
  - front: |
      #### 1.2 三种基本结构

      三种基本结构是 {{顺序}}、{{选择}} 和 {{循环}}。
    back: |
      可以表达任何单入口单出口的逻辑。
`);
check('块标量保留换行', block.cards[0].front.includes('\n'), JSON.stringify(block.cards[0].front));
check('#### 标题被提取', block.cards[0].title.includes('三种基本结构'), block.cards[0].title);
check('识别为完形填空', block.cards[0].type === NoteType.Cloze, `type=${block.cards[0].type}`);
check('三个空只算一张卡(ADR-0002)', block.cards.length === 1, `${block.cards.length}`);
check('挖空数记为 3', block.cards[0].clozeCount === 3, `${block.cards[0].clozeCount}`);

// ================================================================ 3. 题型沿用 Quizify 判定
console.log('\n=== 3. 题型判定与 Markdown 路径一致 ===');

const choice: ParsedDeck = parseYamlDeck(`deck: 测试
cards:
  - front: |
      #### 基础选择 (1) 顺序表的随机访问

      复杂度是()。

      ;;;
      A. $O(1)$
      B. $O(n)$
      ;;;A
    back: "地址可由下标直接算出。"
`);
check('识别为选择题', choice.cards[0].type === NoteType.Choice, `type=${choice.cards[0].type}`);
check('选项被切出来', choice.cards[0].options.length === 2, `${choice.cards[0].options.length}`);
check('答案离开正面', choice.cards[0].answer === 'A', choice.cards[0].answer);
check('正面不再含答案字母行', !choice.cards[0].front.includes(';;;A'), '已剥离');

// ================================================================ 4. YAML 的坑必须硬失败
console.log('\n=== 4. 裸标量与其他坑:必须报错,不能静默曲解 ===');

expectError('裸标量被拒(冒号会截断题干)',
  `deck: 测试
cards:
  - front: 下列说法正确的是: 甲
    back: "甲"
`, 3, '必须用引号');

expectError('裸标量被拒(no 会变成布尔)',
  `deck: 测试
cards:
  - front: "这样对吗?"
    back: no
`, 4, '必须用引号');

expectError('Tab 缩进被拒', "deck: 测试\ncards:\n\t- front: \"甲\"\n", 3, 'Tab');

expectError('未知字段被拒(页码已取消)',
  `deck: 测试
cards:
  - front: "甲"
    back: "乙"
    page: 12
`, 5, 'page');

expectError('缺 deck 被拒',
  `cards:
  - front: "甲"
    back: "乙"
`, 1, '缺少 deck');

expectError('cards 为空被拒', "deck: 测试\ncards:\n", 1, '一张卡都没有');

expectError('front 为空被拒',
  `deck: 测试
cards:
  - front: ""
    back: "乙"
`, 3, 'front 是空的');

expectError('正面里混入 +++ 被拒',
  `deck: 测试
cards:
  - front: |
      甲
      +++
      乙
    back: "丙"
`, 3, '结构标记');

expectError('未知顶层字段被拒',
  `deck: 测试
format: 2
cards:
  - front: "甲"
`, 2, '不认识的顶层字段');

// ================================================================ 5. 报错行号映射回 YAML
console.log('\n=== 5. 转换后文本的报错要映射回 YAML 行号 ===');

// 围栏不闭合是 parseQuizify 才会发现的错,行号必须指回这张卡在 YAML 里的位置
expectError('delegate 的报错也给 YAML 行号',
  `deck: 测试
cards:
  - front: "甲"
    back: "乙"
  - front: |
      看这段代码
      \`\`\`cpp
      int x = 1;
    back: "丙"
`, 5, '围栏');

// ================================================================ 6. 边界
console.log('\n=== 6. 边界情况 ===');

expectError('缺 back 被拒(与 Markdown 的 *** 要求一致)',
  `deck: 测试
cards:
  - front: "只有正面的挖空题 {{答案}}"
`, 3, '缺少 back');

const comments: ParsedDeck = parseYamlDeck(`# 这是注释
deck: 测试
# 这也是注释
cards:
  - front: "甲"
    back: "乙"
`);
check('整行注释被跳过', comments.cards.length === 1, `${comments.cards.length}`);

const hashInside: ParsedDeck = parseYamlDeck(`deck: 测试
cards:
  - front: |
      \`#include <stdio.h>\` 是 C 的头文件
    back: "对"
`);
check('块标量里的 # 不当注释',
  hashInside.cards[0].front.includes('#include'), hashInside.cards[0].front);

const singleQuote: ParsedDeck = parseYamlDeck(`deck: 测试
cards:
  - front: '单引号也认'
    back: 'It''s fine'
`);
check('单引号标量可用', singleQuote.cards[0].front === '单引号也认', singleQuote.cards[0].front);
check("单引号里的 '' 还原成一个撇号",
  singleQuote.cards[0].back === "It's fine", singleQuote.cards[0].back);

const crlf: ParsedDeck = parseYamlDeck("deck: 测试\r\ncards:\r\n  - front: \"甲\"\r\n    back: \"乙\"\r\n");
check('CRLF 换行也认', crlf.cards.length === 1, `${crlf.cards.length}`);

// ================================================================ 7. REPS Card YAML v1(ADR-0007)
console.log('\n=== 7. v1:ADR-0007 的示例文件 ===');

const ex: ParsedDeck = parseYamlDeck(readFileSync(join(here, '..', 'testdata', 'format-example.yaml'), 'utf8'));
check('format = 1', ex.format === 1, `${ex.format}`);
check('deck', ex.deck === '格式示例', ex.deck);
check('tags', ex.tags.join(',') === '示例', ex.tags.join(','));
check('meta.id', ex.meta.id === '3b8e1f0a-2c4d-4e6f-8a1b-9c0d1e2f3a4b', ex.meta.id);
check('meta.version 是数字 1', ex.meta.version === 1, `${ex.meta.version}`);
check('meta.author', ex.meta.author === 'zyichang', ex.meta.author);
check('meta.language / license', ex.meta.language === 'zh-CN' && ex.meta.license === 'CC-BY-4.0');
check('meta.description', ex.meta.description === '格式示例', ex.meta.description);
check('meta.generated_by', ex.meta.generatedBy === 'manual', ex.meta.generatedBy);
check('四张卡', ex.cards.length === 4, `${ex.cards.length}`);

const qa = ex.cards[0];
check('卡 1:id', qa.id === 'ex-qa-1', qa.id);
check('卡 1:问答', qa.type === NoteType.QA, `${qa.type}`);
check('卡 1:title', qa.title === '机会成本', qa.title);
check('卡 1:背面(块标量去掉末尾空行)', qa.back === '为了得到某种东西所必须放弃的东西。', JSON.stringify(qa.back));
check('卡 1:有 id 时标识键就是 id', qa.key === 'ex-qa-1', qa.key);

const ch = ex.cards[1];
check('卡 2:选择题', ch.type === NoteType.Choice, `${ch.type}`);
check('卡 2:四个选项按位置编号', ch.options.join('|') === 'A. 单调函数|B. 奇函数|C. 周期函数|D. 无界函数',
  ch.options.join('|'));
check('卡 2:单选答案 D', ch.answer === 'D', ch.answer);
check('卡 2:正面不含答案', !ch.front.includes('无界函数') && ch.front.includes('dfrac'), ch.front);
check('卡 2:没写 title 时用正面首行', ch.title.startsWith('$f(x)'), ch.title);

const multi = ex.cards[2];
check('卡 3:多行选项列表', multi.options.length === 4 && multi.options[2] === 'C. 队列', multi.options.join('|'));
check('卡 3:多选答案 AC', multi.answer === 'AC', multi.answer);
check('卡 3:没有 back 也行(选择题)', multi.back === '', JSON.stringify(multi.back));

const cz = ex.cards[3];
check('卡 4:挖空', cz.type === NoteType.Cloze, `${cz.type}`);
check('卡 4:三个空', cz.clozeCount === 3, `${cz.clozeCount}`);
check('卡 4:解析', cz.back.includes('单入口单出口'), cz.back);

console.log('\n=== 8. v1:字段细节 ===');

const v1 = (body: string): ParsedDeck => parseYamlDeck(`reps: 1\ndeck: 测试\ncards:\n${body}`);

const dflt = v1(`  - front: "甲"\n    back: "乙"\n`);
check('不写 type 就是问答', dflt.cards[0].type === NoteType.QA, `${dflt.cards[0].type}`);
check('不写 id 就是空串(导入时再生成)', dflt.cards[0].id === '', dflt.cards[0].id);
check('没有 meta 也能导入', dflt.meta.id === '' && dflt.meta.version === 0);

const lower = v1(`  - type: choice\n    front: "甲"\n    options: ["x", "y", "z"]\n    answer: b\n`);
check('答案字母大小写不敏感', lower.cards[0].answer === 'B', lower.cards[0].answer);

const unsorted = v1(`  - type: choice\n    front: "甲"\n    options: ["x", "y", "z"]\n    answer: [c, A]\n`);
check('多选答案排序、转大写', unsorted.cards[0].answer === 'AC', unsorted.cards[0].answer);

const comma = v1(`  - type: choice\n    front: "甲"\n    options: ["1, 2", 'it''s', "3"]\n    answer: A\n`);
check('引号里的逗号不切选项', comma.cards[0].options.length === 3 && comma.cards[0].options[0] === 'A. 1, 2',
  comma.cards[0].options.join('|'));
check('单引号选项', comma.cards[0].options[1] === "B. it's", comma.cards[0].options[1]);

const tagged = v1(`  - front: "甲"\n    back: "乙"\n    tags: [第一章, 重点]\n`);
check('卡片 tags', tagged.cards[0].tags.join(',') === '第一章,重点', tagged.cards[0].tags.join(','));

const anyOrder = v1(`  - back: "乙"\n    front: "甲"\n    id: z-9\n`);
check('字段顺序随意', anyOrder.cards[0].front === '甲' && anyOrder.cards[0].id === 'z-9');

const titled = v1(`  - title: "基础选择 (1) 一个算法应该是"\n    front: "甲"\n    back: "乙"\n`);
check('没有 id 时,标识键按标题取(与 Quizify 一致)', titled.cards[0].key === '基础选择 (1)', titled.cards[0].key);

const colon = v1(`  - front: "下列说法正确的是: 甲"\n    back: "no"\n`);
check('引号里的冒号保留', colon.cards[0].front === '下列说法正确的是: 甲', colon.cards[0].front);
check('引号里的 no 是文字不是布尔', colon.cards[0].back === 'no', colon.cards[0].back);

console.log('\n=== 9. v1:该报错的必须报错,行号要准 ===');

const H = 'reps: 1\ndeck: 测试\ncards:\n';   // 第 4 行起是卡片

expectError('答案字母超出选项', H +
  `  - type: choice\n    front: "甲"\n    options: ["a", "b", "c", "d"]\n    answer: E\n`, 7, 'E');
expectError('选项少于 2 个', H +
  `  - type: choice\n    front: "甲"\n    options: ["a"]\n    answer: A\n`, 6, '至少 2');
expectError('选择题缺 options', H + `  - type: choice\n    front: "甲"\n    answer: A\n`, 4, 'options');
expectError('选择题缺 answer', H + `  - type: choice\n    front: "甲"\n    options: ["a", "b"]\n`, 4, 'answer');
expectError('问答题写了 options', H + `  - front: "甲"\n    back: "乙"\n    options: ["a", "b"]\n`, 6, 'choice');
expectError('问答题写了 answer', H + `  - front: "甲"\n    back: "乙"\n    answer: A\n`, 6, 'choice');
expectError('问答题缺 back', H + `  - front: "甲"\n`, 4, 'back');
expectError('挖空题没有 {{}}', H + `  - type: cloze\n    front: "甲"\n`, 4, '{{');
expectError('不认识的题型', H + `  - type: essay\n    front: "甲"\n    back: "乙"\n`, 4, 'essay');
expectError('id 重复', H +
  `  - id: a1\n    front: "甲"\n    back: "乙"\n  - id: a1\n    front: "丙"\n    back: "丁"\n`, 7, 'a1');
expectError('id 只能是字母数字和 -', H + `  - id: "a b"\n    front: "甲"\n    back: "乙"\n`, 4, 'id');
expectError('v1 卡片的未知字段', H + `  - front: "甲"\n    back: "乙"\n    page: 12\n`, 6, 'page');
expectError('同一张卡字段重复', H + `  - front: "甲"\n    front: "丙"\n    back: "乙"\n`, 5, 'front');
expectError('行内选项没加引号', H + `  - type: choice\n    front: "甲"\n    options: [a, "b"]\n    answer: A\n`, 6, '引号');
expectError('多行选项没加引号', H +
  `  - type: choice\n    front: "甲"\n    options:\n      - "a"\n      - b: c\n    answer: A\n`, 8, '引号');
expectError('v1 里 title 也要引号', H + `  - title: 标题\n    front: "甲"\n    back: "乙"\n`, 4, '引号');
expectError('v1 不再支持 ;;; 选择题块', H +
  `  - front: |\n      题干\n      ;;;\n      A. x\n      ;;;A\n    back: "乙"\n`, 4, 'options');
expectError('不支持的格式版本', `reps: 2\ndeck: 测试\ncards:\n  - front: "甲"\n    back: "乙"\n`, 1, '2');
expectError('meta 的未知字段', `reps: 1\nmeta:\n  colour: red\ndeck: 测试\ncards:\n  - front: "甲"\n    back: "乙"\n`,
  3, 'colour');
expectError('meta.version 必须是整数', `reps: 1\nmeta:\n  version: v2\ndeck: 测试\ncards:\n  - front: "甲"\n    back: "乙"\n`,
  3, 'version');
expectError('meta.description 要引号', `reps: 1\nmeta:\n  description: 简介: 好\ndeck: 测试\ncards:\n  - front: "甲"\n    back: "乙"\n`,
  3, '引号');
expectError('没有 reps 却写了 v1 字段(旧格式只认 front/back)',
  `deck: 测试\ncards:\n  - front: "甲"\n    back: "乙"\n    type: qa\n`, 5, 'reps: 1');

console.log('\n=== 10. 旧格式 math1000.yml 照常导入 ===');
const m1000: ParsedDeck = parseYamlDeck(readFileSync(join(here, '..', 'testdata', 'math1000.yml'), 'utf8'));
check('math1000.yml 能导入', m1000.cards.length > 200, `${m1000.cards.length}`);
check('旧格式 format 记为 0(没有 reps)', m1000.format === 0, `${m1000.format}`);
check('旧格式里的 ;;; 选择题仍然识别', m1000.cards.some((c) => c.type === NoteType.Choice));

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
if (fail > 0) {
  process.exit(1);
}
