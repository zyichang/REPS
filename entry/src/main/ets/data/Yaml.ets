/**
 * YAML 卡组导入 —— 一个**严格子集**,不是通用 YAML 解析器。
 *
 * 设计要点:**不自己解析卡片内容。** YAML 只负责读出 deck / tags 和一串
 * front + back,然后拼成 Quizify Markdown 文本,交给 `parseQuizify` 收尾。
 * 于是题型判定(问答 / 选择 / 挖空)、`####` 标题提取、`;;;` 选项解析、
 * 标识键推导全部与 Markdown 路径**完全一致**,一行都不重复实现 ——
 * 那条路径有 86 条回归断言护着,值得复用。
 * 参见 docs/adr/0001(为什么保留 Markdown)、docs/adr/0002(一张就是一张)。
 *
 * 认得的形状只有这些:
 *
 *   deck: 数据结构::第二章          # 必需。裸标量即可(:: 里没有「冒号+空格」)
 *   tags: [考研, 第二章]            # 可选。行内列表
 *   cards:                          # 必需
 *     - front: "顺序表随机访问的复杂度是多少?"
 *       back: "$O(1)$ —— 地址可由下标直接算出。"
 *     - front: |
 *         #### 1.2 三种基本结构
 *
 *         三种基本结构是 {{顺序}}、{{选择}} 和 {{循环}}。
 *       back: |
 *         可以表达任何单入口单出口的程序逻辑。
 *
 * **front / back 必须是引号标量或 `|` 块标量,不接受裸标量。**
 * 这一条挡掉 YAML 最容易咬人的三处:
 *   - 题干里的「下列说法正确的是:」会把裸标量截断
 *   - 答案写成 no / yes / on / off / y / n 会被当成布尔值
 *   - `#` 起注释,会吃掉 `#include <stdio.h>` 的后半行
 * 报错时一律给出 YAML 里的行号,而不是转换后文本的行号。
 */

import { ParsedDeck, QuizifyError, parseQuizify } from './Quizify';

/**
 * 报错文案的语言。**注入式,本模块不 import i18n** ——
 * 它是纯逻辑、要在桌面上跑回归测试,不能牵进界面依赖。
 * 默认中文,所以现有断言不受影响;AppStore 在初始化和切语言时调用 setMessageLang。
 */
let MSG_EN: boolean = false;

export function setMessageLang(lang: string): void {
  MSG_EN = lang === 'en';
}

/** 取一条双语文案 */
function m(zh: string, en: string): string {
  return MSG_EN ? en : zh;
}

const MARK_CARD: string = '+++';
const MARK_SIDE: string = '***';

/** 扫描阶段的一张卡。line 是 front 在 YAML 里的行号(1 基) */
interface RawCard {
  front: string;
  back: string;
  line: number;
}

/** 一次标量读取的结果 */
interface ScalarRead {
  value: string;
  /** 读完之后的下一行下标(0 基) */
  next: number;
}

function isBlank(line: string): boolean {
  return line.trim().length === 0;
}

/** 整行注释。块标量内部不走这里,所以不会误删正文里的 # */
function isComment(line: string): boolean {
  return line.trim().startsWith('#');
}

function indentOf(line: string): number {
  let n = 0;
  while (n < line.length && line.charAt(n) === ' ') {
    n++;
  }
  return n;
}

function hasTab(line: string): boolean {
  const upto = line.length - line.trimStart().length;
  return line.substring(0, upto).includes('\t');
}

/** 去掉引号并处理最基本的转义。不是引号标量时原样返回 */
function unquote(raw: string): string {
  const s = raw.trim();
  if (s.length >= 2 && s.charAt(0) === '"' && s.charAt(s.length - 1) === '"') {
    return s.substring(1, s.length - 1).replace(/\\"/g, '"').replace(/\\\\/g, '\\');
  }
  if (s.length >= 2 && s.charAt(0) === "'" && s.charAt(s.length - 1) === "'") {
    return s.substring(1, s.length - 1).replace(/''/g, "'");
  }
  return s;
}

function isQuoted(raw: string): boolean {
  const s = raw.trim();
  if (s.length < 2) {
    return false;
  }
  const a = s.charAt(0);
  const b = s.charAt(s.length - 1);
  return (a === '"' && b === '"') || (a === "'" && b === "'");
}

/**
 * 读 front / back 的值。只接受两种写法:
 *   key: "引号标量"
 *   key: |        后面跟缩进更深的若干行
 */
function readScalar(lines: string[], i: number, afterColon: string,
                    keyIndent: number, key: string): ScalarRead {
  const inline = afterColon.trim();

  if (inline === '|' || inline === '|-' || inline === '|+') {
    const keep: boolean = inline === '|+';
    const body: string[] = [];
    let j = i + 1;
    let base = -1;
    while (j < lines.length) {
      const ln = lines[j];
      if (isBlank(ln)) {
        body.push('');
        j++;
        continue;
      }
      const ind = indentOf(ln);
      if (ind <= keyIndent) {
        break;
      }
      if (base < 0) {
        base = ind;
      }
      if (ind < base) {
        throw new QuizifyError(
          m(`${key} 的块标量缩进不齐:这一行比第一行浅。块里每一行都要至少缩进 ${base} 个空格`,
          `Ragged indent in the ${key} block scalar: this line is shallower than the first. `
          + `Every line in the block needs at least ${base} spaces`),
          j + 1);
      }
      body.push(ln.substring(base));
      j++;
    }
    if (base < 0) {
      throw new QuizifyError(m(`${key}: | 后面一行内容都没有`, `${key}: | is followed by no content at all`), i + 1);
    }
    // 默认 clip:去掉末尾多余空行,只留内容
    while (!keep && body.length > 0 && body[body.length - 1] === '') {
      body.pop();
    }
    return { value: body.join('\n'), next: j };
  }

  if (inline.length === 0) {
    throw new QuizifyError(
      m(`${key} 的值是空的。写成 ${key}: "内容",或者用 ${key}: | 接多行`,
      `${key} has an empty value. Write ${key}: "text", or use ${key}: | for multiple lines`), i + 1);
  }

  if (!isQuoted(inline)) {
    throw new QuizifyError(
      m(`${key} 必须用引号包起来,或者用 ${key}: | 写成多行。`
      + '裸写的话,内容里的冒号、# 号,以及 no/yes 这类词都会被 YAML 曲解',
      `${key} must be quoted, or written as ${key}: | across multiple lines. `
      + 'Unquoted, a colon, a # or a word like no/yes gets misread by YAML'),
      i + 1);
  }

  return { value: unquote(inline), next: i + 1 };
}

/** 行内列表 `[a, b, c]`;也接受空列表 `[]` */
function parseInlineList(raw: string, lineNo: number): string[] {
  const s = raw.trim();
  if (!s.startsWith('[') || !s.endsWith(']')) {
    throw new QuizifyError(m('tags 只支持行内列表写法,如 tags: [考研, 第二章]',
      'tags only supports inline list form, e.g. tags: [exam, chapter2]'), lineNo);
  }
  const inner = s.substring(1, s.length - 1).trim();
  if (inner.length === 0) {
    return [];
  }
  const out: string[] = [];
  for (const part of inner.split(',')) {
    const v = unquote(part);
    if (v.length > 0) {
      out.push(v);
    }
  }
  return out;
}

/** 正反面里不能出现独占一行的 +++ / ***,否则拼回 Quizify 文本会被切错 */
function assertNoStructuralMarks(text: string, key: string, lineNo: number): void {
  for (const raw of text.split('\n')) {
    const t = raw.replace(/\s+$/, '');
    if (t === MARK_CARD || t === MARK_SIDE) {
      throw new QuizifyError(
        m(`${key} 里不能有独占一行的 ${t} —— 那是 Quizify 的结构标记。`
        + '想显示它就在前面加别的字符,或者放进 ``` 围栏里',
        `${key} cannot contain a bare ${t} on its own line — that is a Quizify structure marker. `
        + 'Prefix it with another character, or put it inside a ``` fence'),
        lineNo);
    }
  }
}

/**
 * 解析一份 YAML 卡组。
 *
 * 失败时抛 `QuizifyError`,行号指向 YAML 文件本身 ——
 * 包括 `parseQuizify` 在转换后文本里报的错,也会被映射回对应卡片的行号。
 */
export function parseYamlDeck(text: string): ParsedDeck {
  const lines: string[] = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');

  let deck = '';
  let deckLine = 0;
  let tags: string[] = [];
  const cards: RawCard[] = [];

  let i = 0;
  let sawCardsKey = false;

  while (i < lines.length) {
    const line = lines[i];
    if (isBlank(line) || isComment(line)) {
      i++;
      continue;
    }
    if (hasTab(line)) {
      throw new QuizifyError(m('YAML 不允许用 Tab 缩进,请改成空格', 'YAML does not allow tab indentation; use spaces'), i + 1);
    }

    const ind = indentOf(line);
    const trimmed = line.trim();

    // ---- 顶层键 ----
    if (ind === 0) {
      const colon = trimmed.indexOf(':');
      if (colon < 0) {
        throw new QuizifyError(m('看不懂这一行:顶层只认 deck / tags / cards',
            'Cannot read this line: the top level only accepts deck / tags / cards'), i + 1);
      }
      const key = trimmed.substring(0, colon).trim();
      const rest = trimmed.substring(colon + 1);

      if (key === 'deck') {
        deck = unquote(rest);
        deckLine = i + 1;
        if (deck.length === 0) {
          throw new QuizifyError(m('deck 不能是空的', 'deck cannot be empty'), i + 1);
        }
        i++;
        continue;
      }
      if (key === 'tags') {
        tags = parseInlineList(rest, i + 1);
        i++;
        continue;
      }
      if (key === 'cards') {
        if (rest.trim().length > 0) {
          throw new QuizifyError(m('cards: 后面直接换行,卡片写成 - front: … 的列表',
            'Put a newline after cards:, then list each card as - front: …'), i + 1);
        }
        sawCardsKey = true;
        i++;
        // ---- 卡片列表 ----
        while (i < lines.length) {
          const ln = lines[i];
          if (isBlank(ln) || isComment(ln)) {
            i++;
            continue;
          }
          if (indentOf(ln) === 0) {
            break;      // 回到顶层,列表结束
          }
          const t = ln.trim();
          if (!t.startsWith('- ')) {
            throw new QuizifyError(
              m('cards 下面每一张卡都要以 "- front:" 开头',
              'Every card under cards must begin with "- front:"'), i + 1);
          }
          const dashIndent = indentOf(ln);
          const firstKeyOffset = ln.indexOf('- ') + 2;
          const afterDash = ln.substring(firstKeyOffset);
          const c1 = afterDash.indexOf(':');
          if (c1 < 0) {
            throw new QuizifyError(m('这一项缺少 front:', 'This item is missing front:'), i + 1);
          }
          const k1 = afterDash.substring(0, c1).trim();
          if (k1 !== 'front') {
            throw new QuizifyError(m(`每张卡必须先写 front,不能是 ${k1}`, `Each card must start with front, not ${k1}`), i + 1);
          }
          const frontLine = i + 1;
          // 块标量的内容必须比 **front 这个键所在的列** 更深,而不是比短横线更深 ——
          // 否则同一张卡里缩进相同的 back: 会被当成 front 块的正文吞掉。
          const fr: ScalarRead = readScalar(lines, i, afterDash.substring(c1 + 1),
            firstKeyOffset, 'front');
          const front = fr.value;
          i = fr.next;

          // ---- 同一张卡后续的键(back)----
          let back = '';
          while (i < lines.length) {
            const ln2 = lines[i];
            if (isBlank(ln2) || isComment(ln2)) {
              i++;
              continue;
            }
            const ind2 = indentOf(ln2);
            if (ind2 <= dashIndent) {
              break;                       // 下一张卡,或回到顶层
            }
            const t2 = ln2.trim();
            const c2 = t2.indexOf(':');
            if (c2 < 0) {
              throw new QuizifyError(m('看不懂这一行:卡片里只认 front / back',
                'Cannot read this line: a card only accepts front / back'), i + 1);
            }
            const k2 = t2.substring(0, c2).trim();
            if (k2 === 'back') {
              const br: ScalarRead = readScalar(lines, i, t2.substring(c2 + 1),
                ind2, 'back');
              back = br.value;
              i = br.next;
              continue;
            }
            if (k2 === 'front') {
              throw new QuizifyError(m('一张卡里出现了两个 front', 'Two front keys in one card'), i + 1);
            }
            throw new QuizifyError(
              m(`不认识的字段 ${k2}。一张卡只有 front 和 back(没有页码,见 ADR-0002)`,
              `Unknown field ${k2}. A card has only front and back (no page number, see ADR-0002)`),
              i + 1);
          }

          if (front.trim().length === 0) {
            throw new QuizifyError(m('这张卡的 front 是空的', 'This card has an empty front'), frontLine);
          }
          // Markdown 那条路要求每张卡都有 *** 把正反面分开,YAML 这边对应的
          // 就是必须写 back。两条路的卡片形状保持一致,不留「只有正面」的特例。
          if (back.length === 0) {
            throw new QuizifyError(
              m('这张卡缺少 back。一张卡必须有正反两面 —— 写 back: "答案",或 back: | 接多行',
              'This card is missing back. A card needs both sides — write back: "answer", '
              + 'or back: | for multiple lines'),
              frontLine);
          }
          assertNoStructuralMarks(front, 'front', frontLine);
          assertNoStructuralMarks(back, 'back', frontLine);
          cards.push({ front: front, back: back, line: frontLine });
        }
        continue;
      }
      throw new QuizifyError(m(`不认识的顶层字段 ${key}。只认 deck / tags / cards`,
        `Unknown top-level field ${key}. Only deck / tags / cards are accepted`), i + 1);
    }

    throw new QuizifyError(m('缩进对不上:这一行既不是顶层字段,也不在 cards 列表里',
      'Indentation does not line up: this line is neither a top-level field nor inside cards'), i + 1);
  }

  if (deck.length === 0) {
    throw new QuizifyError(m('缺少 deck,卡片没有可靠的落点。第一行写 deck: 书名::章节',
      'Missing deck, so the cards have nowhere to land. Put deck: Book::Chapter on line one'), 1);
  }
  if (!sawCardsKey) {
    throw new QuizifyError(m('缺少 cards,一张卡都没有', 'Missing cards, so there are none at all'), deckLine > 0 ? deckLine : 1);
  }
  if (cards.length === 0) {
    throw new QuizifyError(m('cards 下面一张卡都没有', 'No cards listed under cards'), deckLine > 0 ? deckLine : 1);
  }

  // ---- 拼成 Quizify Markdown,交给那条久经测试的路径 ----
  const out: string[] = ['---', 'quizify:', `  deck: ${deck}`];
  if (tags.length > 0) {
    out.push(`  tags: [${tags.join(', ')}]`);
  }
  out.push('---', '');

  // 记录每张卡在转换后文本里的起始行,用于把错误行号映射回 YAML
  const synthStart: number[] = [];
  for (const c of cards) {
    out.push(MARK_CARD, '');
    synthStart.push(out.length);
    out.push(c.front);
    if (c.back.length > 0) {
      out.push(MARK_SIDE, c.back);
    }
    out.push('');
  }

  try {
    return parseQuizify(out.join('\n'));
  } catch (e) {
    if (e instanceof QuizifyError) {
      const at: number = e.line;
      let owner = -1;
      for (let k = 0; k < synthStart.length; k++) {
        if (at >= synthStart[k]) {
          owner = k;
        }
      }
      const yamlLine: number = owner >= 0 ? cards[owner].line : 1;
      // QuizifyError 的构造函数会自己拼上「第 N 行: 」,所以先把转换后文本的
      // 那个前缀剥掉,否则用户看到「第 5 行: 第 19 行: …」两个行号。
      const bare: string = e.message.replace(/^第 \d+ 行: /, '');
      throw new QuizifyError(bare, yamlLine);
    }
    // ArkTS 的 arkts-limited-throw 不允许 `throw e` 抛一个任意类型的捕获值,
    // 所以统一收敛成 QuizifyError。
    const detail: string = e instanceof Error ? e.message : String(e);
    throw new QuizifyError(m(`转换后的内容解析失败: ${detail}`, `The converted content failed to parse: ${detail}`), 1);
  }
}
