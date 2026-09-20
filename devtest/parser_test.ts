/**
 * Quizify 解析器验证。测的是生产文件 data/Quizify.ets 本身
 * (由 sync-and-test.mjs 同步为 ./Quizify.ts)。
 *
 * 重点不在「能解析正常文件」,而在**畸形输入必须报错而不是静默产出错卡**。
 * 静默错卡是最坏的失败:用户要复习很久之后才会发现某张卡缺了一半。
 */

import { NoteType } from './Models';
import { splitOptions } from './Schema';
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

// ================================================================ 8. 真实语料回归
console.log('\n=== 8. 真实语料(PKB 1850 张卡)暴露出的情况 ===');

// 子题编号:这是真实数据发现的 bug。非贪婪正则只吃第一个括号,
// 会让 (2)-(1) 与 (2)-(2) 塌成同一个键,8 个文件因此被误判为重复卡。
check('子题编号 (2)-(1) 完整保留',
  cardKeyOf('基础篇 第12章 (2)-(1) 有一内表面为旋转抛物面的水缸') === '基础篇 第12章 (2)-(1)',
  cardKeyOf('基础篇 第12章 (2)-(1) 有一内表面为旋转抛物面的水缸'));
check('(2)-(1) 与 (2)-(2) 是两个不同的键',
  cardKeyOf('基础篇 第12章 (2)-(1) 甲') !== cardKeyOf('基础篇 第12章 (2)-(2) 乙'),
  `${cardKeyOf('基础篇 第12章 (2)-(1) 甲')} vs ${cardKeyOf('基础篇 第12章 (2)-(2) 乙')}`);
check('(2) 与 (2)-(1) 也不相同',
  cardKeyOf('X (2) 甲') !== cardKeyOf('X (2)-(1) 甲'),
  `${cardKeyOf('X (2) 甲')} vs ${cardKeyOf('X (2)-(1) 甲')}`);
check('三层编号也吃得下',
  cardKeyOf('综合 (1)-(2)-(3) 题干') === '综合 (1)-(2)-(3)',
  cardKeyOf('综合 (1)-(2)-(3) 题干'));
// 标题里「第12章」含数字但不含点,不该被点号分支误命中
check('标题中的「第12章」不被当作点号编号',
  cardKeyOf('基础篇 第12章 (1) 题干') === '基础篇 第12章 (1)',
  cardKeyOf('基础篇 第12章 (1) 题干'));
// 全角括号 + 无数字的（ ）不该命中编号分支
check('（ ）这种填空括号不算编号',
  cardKeyOf('01. 图中有关路径的定义是（ ）。') === '01. 图中有关路径的定义是（ ）。');

// 没有 front matter:用户 PKB 里有 25 个文件(548 张卡)直接从 +++ 开头
const noFm: ParsedDeck = parseQuizify(
  `+++\n\n01. 图中有关路径的定义是( )。\n***\nA\n`, '王道数据结构_6_1');
check('缺 front matter 时可用兜底卡组名', noFm.deck === '王道数据结构_6_1', noFm.deck);
check('并标记出卡组名是兜底来的', noFm.hadFrontMatter === false);
check('有 front matter 时该标记为 true', basic.hadFrontMatter === true);
expectError('缺 front matter 且没给兜底名时仍报错',
  `+++\n正面\n***\n背面\n`, 'front matter');

// ================================================================ 9. 选择题块
console.log('\n=== 9. ;;; 选择题块:答案必须离开正面 ===');

const mcq: ParsedDeck = parseQuizify(`${FM}
+++

#### 基础选择 (1) 一个算法应该是( )。

;;;
A. 程序
B. 问题求解步骤的描述
C. 要满足五个基本特性
D. A 和 C
;;;B
***
算法是**问题求解步骤的描述**,程序是算法在计算机上的特定实现。
`);

const c0 = mcq.cards[0];
check('识别为选择题', c0.type === NoteType.Choice, `type=${c0.type}`);
check('四个选项都摘出来了', c0.options.length === 4, `${c0.options.length} 个`);
check('选项原文保留', c0.options[1] === 'B. 问题求解步骤的描述', c0.options[1]);
check('答案字母取到了', c0.answer === 'B', c0.answer);

// 这是整段代码存在的理由
check('**正面已不含答案字母**', !c0.front.includes(';;;B'), JSON.stringify(c0.front));
check('**正面已不含 ;;; 标记**', !c0.front.includes(';;;'), JSON.stringify(c0.front));
check('正面也不含选项文本(选项单独存)', !c0.front.includes('A. 程序'));
check('正面只剩题干', c0.front === '#### 基础选择 (1) 一个算法应该是( )。', JSON.stringify(c0.front));
check('背面不受影响', c0.back.startsWith('算法是'), c0.back.slice(0, 8));

// 多选
const multi: ParsedDeck = parseQuizify(`${FM}
+++

#### 基础选择 (2) 下列正确的是( )。

;;;
A. 甲
B. 乙
C. 丙
D. 丁
;;;ABD
***
甲乙丁。
`);
check('多选答案 ABD', multi.cards[0].answer === 'ABD', multi.cards[0].answer);

// 小写答案要归一化成大写
const lower: ParsedDeck = parseQuizify(`${FM}\n+++\n\n#### 小写 (1) 题干\n\n;;;\nA. 甲\nB. 乙\n;;;b\n***\n乙\n`);
check('小写答案归一化为大写', lower.cards[0].answer === 'B', lower.cards[0].answer);

// 非选择题不该被误判
check('纯问答仍是 QA 且无选项',
  basic.cards[0].type === NoteType.QA && basic.cards[0].options.length === 0);
check('纯问答的 answer 为空', basic.cards[0].answer === '');

// 围栏代码块里的 ;;; 不能当选择题块
const fencedSemi: ParsedDeck = parseQuizify(`${FM}
+++

#### 代码里有分号 (1) 这段 C 代码?

\`\`\`c
for (;;) { }
;;;
\`\`\`
***
死循环。
`);
check('代码块内的 ;;; 不被当作选择题块',
  fencedSemi.cards[0].type === NoteType.QA && fencedSemi.cards[0].options.length === 0,
  `type=${fencedSemi.cards[0].type} options=${fencedSemi.cards[0].options.length}`);
check('代码块内容完整保留', fencedSemi.cards[0].front.includes('for (;;)'));

// 真实语料的形状:选项之间没有空格、题干不带 ####
const realShape: ParsedDeck = parseQuizify(
  `+++\n\n1. 可以用( )定义一个完整的数据结构。\n\n;;;\nA.数据元素\nB.数据对象\nC.数据关系\nD.抽象数据类型\n;;;D\n***\n1. 抽象数据类型\n`,
  '王道_1_1');
check('真实语料形状也能解析', realShape.cards[0].options.length === 4);
check('真实语料的答案是 D', realShape.cards[0].answer === 'D');
check('真实语料的正面不泄露答案', !realShape.cards[0].front.includes('D'),
  JSON.stringify(realShape.cards[0].front));

// splitOptions 的往返(界面靠它把库里的字符串拆回数组)
check('选项 join/split 往返一致',
  splitOptions(c0.options.join('\n')).join('|') === c0.options.join('|'));
check('空串拆出空数组,而不是含一个空串的数组', splitOptions('').length === 0);

// 真实语料里有人给 ;;; 那一行也加了硬换行反斜杠。只按空白去尾会认不出来,
// 整块连答案一起留在正面 —— 1850 张卡里就泄露了这一张(3_1.md)。
const backslashed: ParsedDeck = parseQuizify(
  `+++\n\n01. 栈和队列具有相同的( )。\n\n;;;\\\nA. 抽象数据类型\\\nB. 逻辑结构\\\nC. 存储结构\\\nD. 运算\\\n;;;B\n***\n逻辑结构。\n`,
  '王道_3_1');
check('开启标记写成 `;;;\\` 也能识别',
  backslashed.cards[0].options.length === 4, `${backslashed.cards[0].options.length} 个选项`);
check('这种写法的答案也取到了', backslashed.cards[0].answer === 'B', backslashed.cards[0].answer);
check('这种写法的正面同样不泄露答案',
  !backslashed.cards[0].front.includes(';;;'), JSON.stringify(backslashed.cards[0].front));
check('选项末尾的硬换行反斜杠被剥掉(显示时是噪声)',
  backslashed.cards[0].options[0] === 'A. 抽象数据类型', backslashed.cards[0].options[0]);

// 收尾行带反斜杠也要认
const tailBreak: ParsedDeck = parseQuizify(
  `+++\n\n题干\n\n;;;\nA. 甲\nB. 乙\n;;;A\\\n***\n甲\n`, 'x');
check('收尾行 `;;;A\\` 也能取到答案', tailBreak.cards[0].answer === 'A', tailBreak.cards[0].answer);

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
process.exit(fail === 0 ? 0 : 1);
