/**
 * Quizify 解析器验证。测的是生产文件 data/Quizify.ets 本身
 * (由 sync-and-test.mjs 同步为 ./Quizify.ts)。
 *
 * 重点不在「能解析正常文件」,而在**畸形输入必须报错而不是静默产出错卡**。
 * 静默错卡是最坏的失败:用户要复习很久之后才会发现某张卡缺了一半。
 */

import { NoteType } from './Models';
import { ParsedDeck, QuizifyError, cardKeyOf, parseQuizify } from './Quizify';

let pass = 0;
let fail = 0;

function check(name: string, cond: boolean, extra: string = ''): void {
  if (cond) {
    pass++;
    console.log(`  PASS  ${name}${extra ? '  ' + extra : ''}`);
  } else {
    fail++;
    console.log(`  FAIL  ${name}${extra ? '  ' + extra : ''}`);
  }
}

/** 断言解析会失败,并且报错信息里含某个关键词 */
function expectError(name: string, text: string, keyword: string): void {
  try {
    parseQuizify(text);
    fail++;
    console.log(`  FAIL  ${name}  —— 本该报错却解析通过了`);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    const isQuizify = e instanceof QuizifyError;
    if (isQuizify && msg.includes(keyword)) {
      pass++;
      console.log(`  PASS  ${name}  「${msg}」`);
    } else {
      fail++;
      console.log(`  FAIL  ${name}  报错了但不符合预期: ${msg}`);
    }
  }
}

const FM = `---
quizify:
  format: 1
  deck: DataStructure::Chapter_2
  tags: [DataStructure, 第二章]
---
`;

// ================================================================ 1. 正常解析
console.log('=== 1. 基本解析 ===');

const basic: ParsedDeck = parseQuizify(`${FM}
+++

#### 基础问答 (1) 什么是栈?

***
一种**后进先出**的线性表。

+++

#### 基础问答 (2) 什么是队列?
***
先进先出的线性表。
`);

check('解析出 2 张卡', basic.cards.length === 2, `${basic.cards.length} 张`);
check('deck 读对了', basic.deck === 'DataStructure::Chapter_2', basic.deck);
check('deck 按 :: 拆成层级', basic.deckPath.join(' > ') === 'DataStructure > Chapter_2',
  basic.deckPath.join(' > '));
check('tags 读对了', basic.tags.join(',') === 'DataStructure,第二章', basic.tags.join(','));
check('format 默认为 1', basic.format === 1);
check('标题取自 #### 行', basic.cards[0].title === '基础问答 (1) 什么是栈?', basic.cards[0].title);
check('正面保留了 #### 原文', basic.cards[0].front.includes('#### 基础问答 (1)'));
check('背面解析正确', basic.cards[0].back === '一种**后进先出**的线性表。', basic.cards[0].back);
check('第二张卡也对', basic.cards[1].back === '先进先出的线性表。', basic.cards[1].back);
check('题型暂为问答', basic.cards[0].type === NoteType.QA);
check('记录了正面起始行号(便于报错定位)', basic.cards[0].line > 0, `第 ${basic.cards[0].line} 行`);
check('正面首尾空行被去掉,但没动内部内容',
  !basic.cards[0].front.startsWith('\n') && !basic.cards[0].front.endsWith('\n'));

// ================================================================ 2. 围栏代码块
console.log('\n=== 2. 围栏代码块内部的标记不算结构标记(规范硬要求) ===');

const fenced: ParsedDeck = parseQuizify(`${FM}
+++

#### 综合解答 (1) 下面这段 Markdown 会渲染成什么?

\`\`\`markdown
+++
这是代码块里的文本
***
\`\`\`
***
代码块里的 +++ 与 *** 都只是普通文本,不参与卡片切分。
`);

check('代码块里的 +++ / *** 没把卡切开', fenced.cards.length === 1, `${fenced.cards.length} 张`);
check('代码块内容完整保留在正面',
  fenced.cards[0].front.includes('+++') && fenced.cards[0].front.includes('***'),
  '正面确实含这两个标记的字面量');
check('真正的 *** 仍然切出了背面',
  fenced.cards[0].back.startsWith('代码块里的'), fenced.cards[0].back.slice(0, 12));

// 带语言标注的围栏
const fencedLang: ParsedDeck = parseQuizify(`${FM}
+++

#### 综合解答 (2) 这段 C 代码的复杂度?

\`\`\`c
for (int i = 0; i < n; i++)
    sum += a[i];
\`\`\`
***
$O(n)$
`);
check('带语言标注的围栏也能正确识别', fencedLang.cards.length === 1);
check('代码缩进被保留', fencedLang.cards[0].front.includes('    sum += a[i];'));

// 块级数学
const mathy: ParsedDeck = parseQuizify(`${FM}
+++

#### 基础解答 (1) 求导

$$
f'(x) = 3x^2
***
$$
***
这是真正的背面。
`);
check('$$ 块内部的 *** 不作分隔', mathy.cards.length === 1, `${mathy.cards.length} 张`);
check('$$ 块之后的 *** 才切背面', mathy.cards[0].back === '这是真正的背面。', mathy.cards[0].back);

// ================================================================ 3. 转义
console.log('\n=== 3. 转义的字面量标记 ===');

const escaped: ParsedDeck = parseQuizify(`${FM}
+++

#### 基础问答 (3) Quizify 用什么符号分隔卡片?

\\+++
***
用 \\+++ 起正面,\\*** 切背面。
`);
check('\\+++ 不被当作结构标记', escaped.cards.length === 1, `${escaped.cards.length} 张`);
check('导入时去掉了转义反斜杠', escaped.cards[0].front.includes('\n+++'),
  JSON.stringify(escaped.cards[0].front.slice(-6)));

// ================================================================ 4. 缩进不算标记
console.log('\n=== 4. 缩进的标记不算结构标记(规范要求「不缩进且独占一行」) ===');

const indented: ParsedDeck = parseQuizify(`${FM}
+++

#### 基础问答 (4) 缩进的标记呢?

  +++
	***
***
缩进过的标记只是普通文本。
`);
check('缩进的 +++ / *** 不切卡', indented.cards.length === 1, `${indented.cards.length} 张`);

// ================================================================ 5. 必须报错的畸形输入
console.log('\n=== 5. 畸形输入必须报错,不能静默产出错卡 ===');

expectError('缺 front matter', `+++\n正面\n***\n背面\n`, 'front matter');

expectError('front matter 没闭合',
  `---\nquizify:\n  deck: A\n+++\n正面\n***\n背面\n`, '没有结束');

expectError('front matter 里没有 deck',
  `---\nquizify:\n  format: 1\n  tags: [x]\n---\n+++\n正面\n***\n背面\n`, 'deck');

expectError('不支持的 format',
  `---\nquizify:\n  format: 2\n  deck: A\n---\n+++\n正面\n***\n背面\n`, 'format');

expectError('卡片缺 *** 分隔线', `${FM}\n+++\n\n#### 只有正面 (1) 没有背面分隔\n`, '***');

expectError('一张卡有两条 ***',
  `${FM}\n+++\n\n#### 两条线 (1) 题干\n***\n背面甲\n***\n背面乙\n`, '只能有一条');

expectError('*** 出现在 +++ 之前',
  `${FM}\n***\n还没开卡就切面\n`, '必须先有 +++');

expectError('整份文件没有 +++', `${FM}\n只有一段正文,没有任何卡片标记。\n`, '一张卡都没有');

expectError('正面为空', `${FM}\n+++\n***\n只有背面\n`, '正面是空的');

expectError('围栏没闭合',
  `${FM}\n+++\n\n#### 围栏漏闭合 (1)\n\n\`\`\`c\nint x;\n***\n背面\n`, '没有闭合');

// 标题撞车:这正是 Quizify 强制「标题带小节限定」的原因
expectError('标题在文件内重复',
  `${FM}\n+++\n\n#### 选择 (1) 甲\n***\nA\n\n+++\n\n#### 选择 (1) 乙\n***\nB\n`, '重复');

// ================================================================ 6. 边界情况
console.log('\n=== 6. 边界情况 ===');

// 背面允许为空(规范:允许但告警)
const emptyBack: ParsedDeck = parseQuizify(`${FM}\n+++\n\n#### 无背面 (1) 题干\n***\n`);
check('背面允许为空', emptyBack.cards.length === 1 && emptyBack.cards[0].back === '',
  `back=${JSON.stringify(emptyBack.cards[0].back)}`);

// CRLF 与 BOM
const crlf: ParsedDeck = parseQuizify(
  '\uFEFF' + `${FM}+++\r\n\r\n#### CRLF (1) 题干\r\n***\r\n背面\r\n`.replace(/\n/g, '\r\n'));
check('CRLF 与 BOM 都能处理', crlf.cards.length === 1 && crlf.cards[0].back === '背面',
  `back=${crlf.cards[0].back}`);

// 紧凑写法的 front matter
const inline: ParsedDeck = parseQuizify(
  `---\nquizify: { format: 1, deck: X::Y, tags: [a, b] }\n---\n+++\n\n#### 紧凑 (1)\n***\n背面\n`);
check('紧凑写法的 front matter 也能读', inline.deck === 'X::Y' && inline.tags.length === 2,
  `deck=${inline.deck} tags=${inline.tags.join(',')}`);

// 没有 #### 时退回首行非空文本
const noHeading: ParsedDeck = parseQuizify(`${FM}\n+++\n这是没有四级标题的题干\n***\n背面\n`);
check('缺 #### 标题时用首行文本兜底',
  noHeading.cards[0].title === '这是没有四级标题的题干', noHeading.cards[0].title);

// 单层 deck
const flat: ParsedDeck = parseQuizify(
  `---\nquizify:\n  deck: SingleDeck\n---\n+++\n\n#### 单层 (1)\n***\n背面\n`);
check('单层 deck 的 deckPath 只有一项',
  flat.deckPath.length === 1 && flat.deckPath[0] === 'SingleDeck', flat.deckPath.join('>'));

// 报错必须带行号,否则用户无从下手
try {
  parseQuizify(`${FM}\n+++\n\n#### 有头无尾 (1)\n`);
} catch (e) {
  const err = e as QuizifyError;
  check('报错带行号', err.line > 0, `line=${err.line}`);
  check('报错信息里含行号文字', err.message.includes('行'), err.message);
}

// ================================================================ 7. 卡片标识键
console.log('\n=== 7. 标识键:改题干不该变成新卡 ===');

check('命名小节形式取出编号部分',
  cardKeyOf('基础选择 (1) 一个算法应该是()。') === '基础选择 (1)',
  cardKeyOf('基础选择 (1) 一个算法应该是()。'));
check('点号编号形式取出编号',
  cardKeyOf('1.2.3 求下列极限') === '1.2.3', cardKeyOf('1.2.3 求下列极限'));
check('中文括号也认',
  cardKeyOf('综合填空 (3) 已知 f(x)') === '综合填空 (3)', cardKeyOf('综合填空 (3) 已知 f(x)'));
check('括号内有空格也认',
  cardKeyOf('综合解答 ( 7 ) 证明') === '综合解答 (7)', cardKeyOf('综合解答 ( 7 ) 证明'));

// 这条是整个 Task 7 的根据
check('**改掉题干里的错别字,键不变**',
  cardKeyOf('基础选择 (1) 一个算法应该是()。') === cardKeyOf('基础选择 (1) 一个算法应该是什么()。'),
  '两个不同题干 -> 同一个键');

// 但小节/题号变了就是另一张卡
check('题号不同 -> 不同键', cardKeyOf('基础选择 (1) 甲') !== cardKeyOf('基础选择 (2) 甲'));
check('小节不同 -> 不同键', cardKeyOf('基础选择 (1) 甲') !== cardKeyOf('综合选择 (1) 甲'));

// 不含编号时退回整行,行为明确
check('无编号时退回整行标题',
  cardKeyOf('什么是栈') === '什么是栈', cardKeyOf('什么是栈'));
// 「1 什么是栈」不该被误判成点号编号(要求至少一个点)
check('单个数字不算点号编号',
  cardKeyOf('1 什么是栈') === '1 什么是栈', cardKeyOf('1 什么是栈'));

// 解析结果里确实带上了键
const keyed: ParsedDeck = parseQuizify(`${FM}
+++

#### 基础选择 (5) 下列说法正确的是()。
***
B
`);
check('ParsedCard 带 key 字段', keyed.cards[0].key === '基础选择 (5)', keyed.cards[0].key);
check('title 仍保留完整原文',
  keyed.cards[0].title === '基础选择 (5) 下列说法正确的是()。', keyed.cards[0].title);

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
process.exit(fail === 0 ? 0 : 1);
