/**
 * 完形填空与行内标记的验证。
 *
 * 这两块都是纯逻辑,所以能在桌面上跑真实生产代码
 * (由 sync-and-test.mjs 同步 Quizify.ets 与 Inline.ets)。
 */

import { NoteType } from './Models';
import { Block, BlockKind, InlineKind, InlineSpan, flattenInline, parseInline, plainTextOf, splitBlocks, stripHardBreaks } from './Inline';
import { ParsedDeck, clozeAnswers, parseQuizify, renderCloze } from './Quizify';

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

const FM = `---
quizify:
  format: 1
  deck: Test::Cloze
---
`;

// ================================================================ 1. 挖空抽取
console.log('=== 1. {{挖空}} 抽取 ===');

check('取出单个挖空',
  clozeAnswers('栈是{{后进先出}}的线性表').join('|') === '后进先出',
  clozeAnswers('栈是{{后进先出}}的线性表').join('|'));

const three = clozeAnswers('{{栈}}是{{后进先出}},{{队列}}是先进先出');
check('按出现顺序取出三个挖空', three.join('|') === '栈|后进先出|队列', three.join('|'));

check('没有挖空时返回空数组', clozeAnswers('普通一句话').length === 0);
check('挖空内的空格被去掉',
  clozeAnswers('{{  后进先出  }}')[0] === '后进先出',
  `"${clozeAnswers('{{  后进先出  }}')[0]}"`);

// 代码里的双花括号不是挖空 —— 模板语法、C++ 初始化列表都会出现
const codeBraces = clozeAnswers('看这段代码\n```cpp\nvector<int> v{{1,2},{3}};\n```\n结束');
check('围栏代码块内的 {{ }} 不算挖空', codeBraces.length === 0, `取到 ${codeBraces.length} 个`);

// ================================================================ 2. 按空渲染
console.log('\n=== 2. 所有空同时挖出来 ===');

const src = '{{栈}}是后进先出,{{队列}}是先进先出';

const blanked = renderCloze(src, false);
check('未揭开时每个空都是空的', blanked === '[____]是后进先出,[____]是先进先出', blanked);

const revealed = renderCloze(src, true);
check('揭开后每个空都显示答案', revealed === '栈是后进先出,队列是先进先出', revealed);

check('没有挖空的文本原样返回',
  renderCloze('普通句子', false) === '普通句子');

// 跨行的挖空一样全挖
const multiline = renderCloze('第一行{{甲}}\n第二行{{乙}}', false);
check('跨行的空也同时挖', multiline === '第一行[____]\n第二行[____]', JSON.stringify(multiline));

// ================================================================ 3. 题型与卡片数
console.log('\n=== 3. 一条笔记 = 一张卡,挖几个空都一样 ===');

const clozeDeck: ParsedDeck = parseQuizify(`${FM}
+++

#### 填空 (1) 三种基本结构

{{顺序}}结构、{{选择}}结构、{{循环}}结构
***
这是程序设计的三种基本控制结构。
`);
const cc = clozeDeck.cards[0];
check('识别为完形填空', cc.type === NoteType.Cloze, `type=${cc.type}`);
check('挖空数 = 3(仅记录空的个数,不再决定卡片数)', cc.clozeCount === 3, `${cc.clozeCount}`);
check('正面保留原始 {{}} 标记(渲染时才整体替换)',
  cc.front.includes('{{顺序}}'), '保留');
check('三个空的笔记仍然只是一张卡', clozeDeck.cards.length === 1,
  `cards=${clozeDeck.cards.length}`);

// 选择题优先于完形填空:选项已经把答案结构化了
const both: ParsedDeck = parseQuizify(`${FM}
+++

#### 混排 (1) 下面哪个是{{后进先出}}的?

;;;
A. 栈
B. 队列
;;;A
***
栈。
`);
check('同时有 ;;; 和 {{}} 时按选择题处理',
  both.cards[0].type === NoteType.Choice, `type=${both.cards[0].type}`);
check('按选择题处理时 clozeCount 为 0', both.cards[0].clozeCount === 0);

// 纯问答
const qa: ParsedDeck = parseQuizify(`${FM}\n+++\n\n#### 问答 (1) 什么是栈?\n***\n后进先出。\n`);
check('纯问答的 clozeCount 为 0', qa.cards[0].clozeCount === 0);

// ================================================================ 4. 硬换行
console.log('\n=== 4. 行尾硬换行反斜杠 ===');

check('去掉行尾反斜杠但保留换行',
  stripHardBreaks('I. 甲\\\nII. 乙\\\nIII. 丙') === 'I. 甲\nII. 乙\nIII. 丙',
  JSON.stringify(stripHardBreaks('I. 甲\\\nII. 乙')));
check('末尾单独的反斜杠也去掉', stripHardBreaks('结尾\\') === '结尾');
check('句中的反斜杠不动(LaTeX 命令要留着)',
  stripHardBreaks('$\\alpha + \\beta$') === '$\\alpha + \\beta$',
  stripHardBreaks('$\\alpha + \\beta$'));

// ================================================================ 5. 行内标记
console.log('\n=== 5. 行内标记切片 ===');

const bold: InlineSpan[] = parseInline('算法是**问题求解步骤**的描述');
check('粗体被切出来', bold.length === 3 && bold[1].kind === InlineKind.Bold,
  bold.map((s) => `${s.kind}:${s.text}`).join(' | '));
check('粗体内容不含标记符', bold[1].text === '问题求解步骤', bold[1].text);
check('拼回原文(去掉标记)', plainTextOf(bold) === '算法是问题求解步骤的描述', plainTextOf(bold));

const hl: InlineSpan[] = parseInline('这是==重点==内容');
check('高亮被切出来', hl[1].kind === InlineKind.Highlight && hl[1].text === '重点');

const code: InlineSpan[] = parseInline('访问 `L.data[i]` 元素');
check('行内代码被切出来', code[1].kind === InlineKind.Code && code[1].text === 'L.data[i]',
  code[1].text);

const sup: InlineSpan[] = parseInline('面积是 X^2^ 平方米');
check('上标被切出来', sup[1].kind === InlineKind.Sup && sup[1].text === '2');
const sub: InlineSpan[] = parseInline('分子式 H~2~O');
check('下标被切出来', sub[1].kind === InlineKind.Sub && sub[1].text === '2');

// ---- 数学必须整段保留 ----
const math: InlineSpan[] = parseInline('复杂度是 $O(\\log n)$ 级别');
check('行内数学整段保留', math[1].kind === InlineKind.Math && math[1].text === '$O(\\log n)$',
  math[1].text);
check('数学片段含首尾的 $', math[1].text.startsWith('$') && math[1].text.endsWith('$'));

// 这一条很关键:LaTeX 里的 ^ 和 ~ 有自己的含义,不能按 Markdown 切
const mathSup: InlineSpan[] = parseInline('$x^{2} + y_{1}$');
check('**数学里的 ^ 不被当作上标标记**',
  mathSup.length === 1 && mathSup[0].kind === InlineKind.Math,
  mathSup.map((s) => `${s.kind}:${s.text}`).join(' | '));

const mathStar: InlineSpan[] = parseInline('$a ** b$');
check('数学里的 ** 也不被当作粗体',
  mathStar.length === 1 && mathStar[0].kind === InlineKind.Math);

const blockMath: InlineSpan[] = parseInline('$$\\int_0^1 x dx$$');
check('块级 $$ 也整段保留',
  blockMath.length === 1 && blockMath[0].kind === InlineKind.Math, blockMath[0].text);

// 未配对的 $ 当普通字符,不能把后面全吞掉
const lonely: InlineSpan[] = parseInline('价格是 $100 元');
check('孤立的 $ 当普通字符', plainTextOf(lonely) === '价格是 $100 元', plainTextOf(lonely));

// ================================================================ 6. 需要改写的语法
console.log('\n=== 6. [[点击显示]] 与 [术语]^(解释)^ ===');

check('[[题干||答案]] 正面只留题干',
  flattenInline('[[栈的特点||后进先出]]') === '栈的特点',
  flattenInline('[[栈的特点||后进先出]]'));
check('[术语]^(解释)^ 展开成 术语(解释)',
  flattenInline('[ADT]^(抽象数据类型)^') === 'ADT(抽象数据类型)',
  flattenInline('[ADT]^(抽象数据类型)^'));
// ArkUI 不认 Markdown 标题,#### 会原样画出来
check('#### 标题标记被剥掉,文字保留',
  flattenInline('#### 综合填空 (1) 三种基本结构') === '综合填空 (1) 三种基本结构',
  flattenInline('#### 综合填空 (1) 三种基本结构'));
check('多级标题都认', flattenInline('## 二级\n###### 六级') === '二级\n六级');
check('正文中间的 # 不动(只认行首)',
  flattenInline('C# 是一门语言') === 'C# 是一门语言', flattenInline('C# 是一门语言'));
check('行首 # 后面没空格的不算标题',
  flattenInline('#hashtag') === '#hashtag', flattenInline('#hashtag'));
check('::: 折叠围栏行被去掉,内容保留',
  flattenInline(':::  查看解析\n正文\n:::').trim() === '正文',
  JSON.stringify(flattenInline(':::  查看解析\n正文\n:::')));

// 混排:一句话里多种标记
const mixed: InlineSpan[] = parseInline('**栈**是==后进先出==的,复杂度 $O(1)$,见 `push()`');
const kinds = mixed.map((s) => s.kind);
check('混排时各标记都被正确切分',
  kinds.includes(InlineKind.Bold) && kinds.includes(InlineKind.Highlight)
  && kinds.includes(InlineKind.Math) && kinds.includes(InlineKind.Code),
  mixed.map((s) => `${InlineKind[s.kind]}:${s.text}`).join(' | '));

check('空字符串得到空数组', parseInline('').length === 0);
check('纯文本只有一个片段',
  parseInline('没有任何标记').length === 1 && parseInline('没有任何标记')[0].kind === InlineKind.Plain);

// ================================================================ 7. 块级切分:``` 代码块
console.log('\n=== 7. ``` 围栏切成代码块 ===');

const b1 = splitBlocks('前面一句\n```c\nint i = 1;\nwhile (i <= n)\n```\n后面一句');
check('切成三块', b1.length === 3, `${b1.length}`);
check('第一块是段落', b1[0].kind === BlockKind.Para, `${b1[0].kind}`);
check('第二块是代码', b1[1].kind === BlockKind.Code, `${b1[1].kind}`);
check('语言名被取出', b1[1].lang === 'c', b1[1].lang);
check('代码原文保留换行与缩进',
  b1[1].text === 'int i = 1;\nwhile (i <= n)', JSON.stringify(b1[1].text));
check('围栏那两行不出现在任何块里',
  !b1.some((b) => b.text.includes('```')), 'ok');
check('第三块是段落', b1[2].kind === BlockKind.Para && b1[2].text.includes('后面一句'), b1[2].text);

const b2 = splitBlocks('没有围栏的一段话');
check('没有围栏时只有一块', b2.length === 1 && b2[0].kind === BlockKind.Para, `${b2.length}`);

const b3 = splitBlocks('开头\n```\n没闭合的代码');
check('围栏没闭合时剩下的算代码(显示层要宽容)',
  b3.length === 2 && b3[1].kind === BlockKind.Code, `${b3.length}`);

const b4 = splitBlocks('```\nint x;\n```');
check('整张卡就是一个代码块', b4.length === 1 && b4[0].kind === BlockKind.Code, `${b4.length}`);
check('无语言名时 lang 为空串', b4[0].lang === '', `"${b4[0].lang}"`);

// 代码块里的 * 和 $ 不该被当成标记 —— 它们不进 parseInline
const b5 = splitBlocks('```\na * b + $x$\n```');
check('代码块原文含 * 与 $', b5[0].text === 'a * b + $x$', b5[0].text);

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
process.exit(fail === 0 ? 0 : 1);
