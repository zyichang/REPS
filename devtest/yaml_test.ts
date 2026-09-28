/**
 * YAML 子集导入的回归测试。
 *
 * 重点不在「能解析成功」,而在**该报错的时候报得准**:
 * YAML 的坑几乎全是「静默解析成了别的东西」,所以裸标量、Tab 缩进、
 * 未知字段这些都必须硬失败并给出正确行号。
 */
import { NoteType } from './Models';
import { ParsedDeck, QuizifyError } from './Quizify';
import { parseYamlDeck } from './Yaml';

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

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
if (fail > 0) {
  process.exit(1);
}
