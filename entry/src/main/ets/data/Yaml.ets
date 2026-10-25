/**
 * YAML 卡组导入 —— 一个**严格子集**,不是通用 YAML 解析器。两条路:
 *
 * **1. REPS Card YAML v1**(文件里有顶层 `reps: 1`,ADR-0007,字段表见 docs/data-model.md)
 *    直接产出 ParsedCard:`type` / `options` / `answer` / `id` / `title` / `tags` / `meta`
 *    都是结构化字段,不经过 Quizify。选择题的选项按位置编成 A、B、C…,答案物理上不在正面。
 *
 * **2. 旧格式**(没有 `reps`,如 testdata/math1000.yml)—— 兼容导入,行为不变:
 *    只认 deck / tags 和一串 front + back,拼成 Quizify Markdown 交给 `parseQuizify` 收尾,
 *    于是 `;;;` 选择题、`####` 标题、标识键推导与 Markdown 路径完全一致。
 *
 * 旧格式的形状:
 *
 *   deck: 数据结构::第二章          # 必需。裸标量即可(:: 里没有「冒号+空格」)
 *   tags: [考研, 第二章]            # 可选。行内列表
 *   cards:                          # 必需
 *     - front: "顺序表随机访问的复杂度是多少?"
 *       back: "$O(1)$ —— 地址可由下标直接算出。"
 *
 * **两条路共同的规则:正文必须是引号标量或 `|` 块标量,不接受裸标量。**
 * (v1 里正文是 front / back / title / options 的每一项,以及 meta 的 author / description / source。)
 * 这一条挡掉 YAML 最容易咬人的三处:
 *   - 题干里的「下列说法正确的是:」会把裸标量截断
 *   - 答案写成 no / yes / on / off / y / n 会被当成布尔值
 *   - `#` 起注释,会吃掉 `#include <stdio.h>` 的后半行
 * 报错时一律给出 YAML 里的行号,而不是转换后文本的行号。
 */

import { NoteType } from '../model/Models';
import {
  DeckMeta, ParsedCard, ParsedDeck, QuizifyError, cardKeyOf, clozeAnswers, emptyMeta, parseQuizify,
} from './Quizify';

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

  const blockHead: RegExpMatchArray | null = inline.match(/^\|([1-9])?([+-])?$/);
  if (blockHead !== null) {
    const keep: boolean = blockHead[2] === '+';
    // 缩进指示符 |2:正文从「键所在列 + 2」开始,第一行本身带的前导空格算内容。
    // 导出器在正文首行以空格开头(缩进的代码)时写它,否则那几个空格会被当成缩进吃掉。
    const explicit: number = blockHead[1] !== undefined ? keyIndent + Number(blockHead[1]) : -1;
    const body: string[] = [];
    let j = i + 1;
    let base = explicit;
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
 * 解析一份 YAML 卡组。有顶层 `reps:` 走 v1,否则走旧格式。
 *
 * 失败时抛 `QuizifyError`,行号指向 YAML 文件本身 ——
 * 包括旧格式里 `parseQuizify` 在转换后文本里报的错,也会被映射回对应卡片的行号。
 */
export function parseYamlDeck(text: string): ParsedDeck {
  const lines: string[] = text.replace(/^\uFEFF/, '').replace(/\r\n/g, '\n').replace(/\r/g, '\n')
    .split('\n');
  for (const ln of lines) {
    if (/^reps\s*:/.test(ln)) {
      return parseV1(lines);
    }
  }
  const legacy: ParsedDeck = parseLegacy(lines);
  // 旧格式没有版本号。记成 0,和 v1 的 1 区分开(导出时一律写 v1)
  legacy.format = 0;
  return legacy;
}

/** v1 的卡片字段。旧格式里出现这些字段,提示用户在文件开头加 reps: 1 */
const V1_CARD_KEYS: string[] = ['id', 'type', 'title', 'options', 'answer', 'tags'];

function parseLegacy(lines: string[]): ParsedDeck {
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
            if (V1_CARD_KEYS.includes(k2)) {
              throw new QuizifyError(
                m(`${k2} 是 REPS YAML v1 的字段。要用它,请在文件第一行加上 reps: 1`,
                `${k2} is a REPS YAML v1 field. To use it, add reps: 1 as the first line of the file`),
                i + 1);
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

// ================================================================ REPS Card YAML v1

/** 一个值的写法 */
enum ValKind {
  /** 单行标量(引号或裸写) */
  Scalar = 0,
  /** `|` 块标量 */
  Block = 1,
  /** 行内 `[a, b]` 或多行 `- a` 列表 */
  List = 2,
}

/** 读出来的一个字段值 */
interface Val {
  kind: ValKind;
  /** Scalar / Block 的内容(已去引号) */
  text: string;
  /** Scalar 是否加了引号;Block 恒为 true(块标量里什么都能写) */
  quoted: boolean;
  /** List 的每一项(已去引号) */
  items: string[];
  itemsQuoted: boolean[];
  /** 每一项所在的行号;行内列表的各项都是键所在的行 */
  itemLines: number[];
  /** 键所在的行号(1 基) */
  line: number;
  /** 读完之后的下一行下标(0 基) */
  next: number;
}

/** 列表里的一项(行内列表切分用) */
interface FlowItem {
  value: string;
  quoted: boolean;
}

const V1_CARD_FIELDS: string[] = ['id', 'type', 'title', 'front', 'back', 'options', 'answer', 'tags'];
const V1_META_FIELDS: string[] = [
  'id', 'version', 'author', 'language', 'license', 'description', 'source', 'generated_by',
];
const V1_TOP_FIELDS: string[] = ['reps', 'meta', 'deck', 'tags', 'cards'];
const CARD_ID_RE: RegExp = /^[A-Za-z0-9-]+$/;

function newVal(kind: ValKind, line: number, next: number): Val {
  return {
    kind: kind, text: '', quoted: false, items: [], itemsQuoted: [], itemLines: [], line: line,
    next: next,
  };
}

/**
 * 切行内列表 `a, "b, c", 'd'`。**引号里的逗号不切** ——
 * 选项「1, 2」写成 "1, 2" 时必须还是一项。
 */
function splitFlow(inner: string): FlowItem[] {
  const out: FlowItem[] = [];
  let cur = '';
  let quote = '';
  for (let k = 0; k < inner.length; k++) {
    const ch = inner.charAt(k);
    if (quote.length > 0) {
      cur += ch;
      if (quote === '"' && ch === '\\' && k + 1 < inner.length) {
        cur += inner.charAt(k + 1);
        k++;
      } else if (ch === quote) {
        // 单引号里的 '' 是转义,不是结束
        if (quote === "'" && k + 1 < inner.length && inner.charAt(k + 1) === "'") {
          cur += "'";
          k++;
        } else {
          quote = '';
        }
      }
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      cur += ch;
      continue;
    }
    if (ch === ',') {
      out.push({ value: unquote(cur), quoted: isQuoted(cur) });
      cur = '';
      continue;
    }
    cur += ch;
  }
  if (cur.trim().length > 0 || out.length > 0) {
    out.push({ value: unquote(cur), quoted: isQuoted(cur) });
  }
  return out;
}

/**
 * 读一个字段的值。认得:`| 块标量`、`[行内列表]`、下一行起的 `- 多行列表`、单行标量。
 * 哪个字段允许哪种写法由调用方检查 —— 这里只负责读准、报准行号。
 */
function readValue(lines: string[], i: number, afterColon: string, keyIndent: number,
                   key: string): Val {
  const inline = afterColon.trim();
  const line = i + 1;

  if (/^\|([1-9])?([+-])?$/.test(inline)) {
    const r: ScalarRead = readScalar(lines, i, afterColon, keyIndent, key);
    const v = newVal(ValKind.Block, line, r.next);
    v.text = r.value;
    v.quoted = true;
    return v;
  }

  if (inline.startsWith('[')) {
    if (!inline.endsWith(']')) {
      throw new QuizifyError(m(`${key} 的列表少了右括号 ]`, `The ${key} list is missing its closing ]`), line);
    }
    const v = newVal(ValKind.List, line, i + 1);
    const inner = inline.substring(1, inline.length - 1);
    if (inner.trim().length > 0) {
      for (const it of splitFlow(inner)) {
        v.items.push(it.value);
        v.itemsQuoted.push(it.quoted);
        v.itemLines.push(line);
      }
    }
    return v;
  }

  if (inline.length === 0) {
    // 下一行起的多行列表:每一项 `- 值`,比键缩进更深
    let j = i + 1;
    while (j < lines.length && (isBlank(lines[j]) || isComment(lines[j]))) {
      j++;
    }
    const first = j < lines.length ? lines[j] : '';
    const ft = first.trim();
    if (j < lines.length && indentOf(first) > keyIndent && (ft.startsWith('- ') || ft === '-')) {
      const itemIndent = indentOf(first);
      const v = newVal(ValKind.List, line, j);
      while (j < lines.length) {
        const ln = lines[j];
        if (isBlank(ln) || isComment(ln)) {
          j++;
          continue;
        }
        const ind = indentOf(ln);
        if (ind <= keyIndent) {
          break;
        }
        const t = ln.trim();
        if (ind !== itemIndent || !(t.startsWith('- ') || t === '-')) {
          throw new QuizifyError(
            m(`${key} 列表的每一项都要以 "- " 开头,并且缩进对齐`,
            `Every item of the ${key} list must start with "- " and line up`), j + 1);
        }
        const raw = t === '-' ? '' : t.substring(2);
        v.items.push(unquote(raw));
        v.itemsQuoted.push(isQuoted(raw));
        v.itemLines.push(j + 1);
        j++;
      }
      v.next = j;
      return v;
    }
    throw new QuizifyError(
      m(`${key} 的值是空的。写成 ${key}: "内容",或者用 ${key}: | 接多行`,
      `${key} has an empty value. Write ${key}: "text", or use ${key}: | for multiple lines`), line);
  }

  const v = newVal(ValKind.Scalar, line, i + 1);
  v.text = unquote(inline);
  v.quoted = isQuoted(inline);
  return v;
}

/** 正文字段:必须是引号标量或块标量。返回内容 */
function textOf(v: Val, key: string): string {
  if (v.kind === ValKind.List) {
    throw new QuizifyError(m(`${key} 是一段文字,不能写成列表`, `${key} is text and cannot be a list`), v.line);
  }
  if (!v.quoted) {
    throw new QuizifyError(
      m(`${key} 必须用引号包起来,或者用 ${key}: | 写成多行。`
      + '裸写的话,内容里的冒号、# 号,以及 no/yes 这类词都会被 YAML 曲解',
      `${key} must be quoted, or written as ${key}: | across multiple lines. `
      + 'Unquoted, a colon, a # or a word like no/yes gets misread by YAML'),
      v.line);
  }
  return v.text;
}

/** 短字段(id / type / version…):单行标量,引号可写可不写 */
function wordOf(v: Val, key: string): string {
  if (v.kind !== ValKind.Scalar) {
    throw new QuizifyError(m(`${key} 只能写在一行里`, `${key} must be on a single line`), v.line);
  }
  return v.text.trim();
}

/** 标签之类的列表 */
function listOf(v: Val, key: string): string[] {
  if (v.kind !== ValKind.List) {
    throw new QuizifyError(m(`${key} 要写成列表,如 ${key}: [甲, 乙]`, `${key} must be a list, e.g. ${key}: [a, b]`),
      v.line);
  }
  const out: string[] = [];
  for (const it of v.items) {
    if (it.trim().length > 0) {
      out.push(it.trim());
    }
  }
  return out;
}

/** 一行 `key: value` 拆出键;不是这个形状返回空串 */
function keyOf(trimmed: string): string {
  const c = trimmed.indexOf(':');
  return c < 0 ? '' : trimmed.substring(0, c).trim();
}

/** meta 块里的一行 */
interface MetaEntry {
  key: string;
  val: Val;
}

/** 读 meta 块(顶层 `meta:` 下面缩进的若干 `key: value`) */
function readMeta(lines: string[], i: number): MetaEntry[] {
  const out: MetaEntry[] = [];
  let j = i + 1;
  while (j < lines.length) {
    const ln = lines[j];
    if (isBlank(ln) || isComment(ln)) {
      j++;
      continue;
    }
    const ind = indentOf(ln);
    if (ind === 0) {
      break;
    }
    if (hasTab(ln)) {
      throw new QuizifyError(m('YAML 不允许用 Tab 缩进,请改成空格', 'YAML does not allow tab indentation; use spaces'), j + 1);
    }
    const t = ln.trim();
    const key = keyOf(t);
    if (key.length === 0) {
      throw new QuizifyError(m('看不懂这一行:meta 里每一行都是 字段: 值', 'Cannot read this line: each line in meta is field: value'),
        j + 1);
    }
    if (!V1_META_FIELDS.includes(key)) {
      throw new QuizifyError(
        m(`meta 里不认识的字段 ${key}。只认 ${V1_META_FIELDS.join(' / ')}`,
        `Unknown meta field ${key}. Only ${V1_META_FIELDS.join(' / ')} are accepted`), j + 1);
    }
    const v: Val = readValue(lines, j, t.substring(t.indexOf(':') + 1), ind, key);
    out.push({ key: key, val: v });
    j = v.next;
  }
  return out;
}

function buildMeta(entries: MetaEntry[]): DeckMeta {
  const meta: DeckMeta = emptyMeta();
  const seen: string[] = [];
  for (const e of entries) {
    const key: string = e.key;
    const v: Val = e.val;
    if (seen.includes(key)) {
      throw new QuizifyError(m(`meta 里 ${key} 写了两次`, `meta has ${key} twice`), v.line);
    }
    seen.push(key);
    if (key === 'id') {
      meta.id = wordOf(v, 'meta.id');
    } else if (key === 'version') {
      const s: string = wordOf(v, 'meta.version');
      if (!/^\d+$/.test(s)) {
        throw new QuizifyError(m(`meta.version 必须是整数,不能是 ${s}`, `meta.version must be an integer, not ${s}`),
          v.line);
      }
      meta.version = Number(s);
    } else if (key === 'author') {
      meta.author = textOf(v, 'meta.author');
    } else if (key === 'description') {
      meta.description = textOf(v, 'meta.description');
    } else if (key === 'source') {
      meta.source = textOf(v, 'meta.source');
    } else if (key === 'language') {
      meta.language = wordOf(v, 'meta.language');
    } else if (key === 'license') {
      meta.license = wordOf(v, 'meta.license');
    } else if (key === 'generated_by') {
      const g: string = wordOf(v, 'meta.generated_by');
      if (g !== 'manual' && g !== 'ai' && g !== 'ai+manual') {
        throw new QuizifyError(m(`meta.generated_by 只能是 manual / ai / ai+manual,不能是 ${g}`,
          `meta.generated_by must be manual / ai / ai+manual, not ${g}`), v.line);
      }
      meta.generatedBy = g;
    }
  }
  return meta;
}

/** 扫描阶段的一张 v1 卡:字段名 -> 值 */
interface RawV1Card {
  keys: string[];
  vals: Val[];
  /** `- ` 所在行(1 基) */
  line: number;
}

function fieldOf(c: RawV1Card, key: string): Val | null {
  const k = c.keys.indexOf(key);
  return k < 0 ? null : c.vals[k];
}

/** 读 cards: 下面的列表。i 指向 `cards:` 那一行 */
function readV1Cards(lines: string[], i: number): RawV1Card[] {
  const out: RawV1Card[] = [];
  let j = i + 1;
  while (j < lines.length) {
    const ln = lines[j];
    if (isBlank(ln) || isComment(ln)) {
      j++;
      continue;
    }
    if (indentOf(ln) === 0) {
      break;
    }
    if (hasTab(ln)) {
      throw new QuizifyError(m('YAML 不允许用 Tab 缩进,请改成空格', 'YAML does not allow tab indentation; use spaces'), j + 1);
    }
    const t = ln.trim();
    if (!t.startsWith('- ')) {
      throw new QuizifyError(m('cards 下面每一张卡都要以 "- " 开头', 'Every card under cards must begin with "- "'), j + 1);
    }
    const dashIndent = indentOf(ln);
    const card: RawV1Card = { keys: [], vals: [], line: j + 1 };
    // 第一组 key: value 和短横线在同一行
    let keyCol = ln.indexOf('- ') + 2;
    let rest = ln.substring(keyCol);
    while (true) {
      const key = keyOf(rest.trim());
      if (key.length === 0) {
        throw new QuizifyError(m('看不懂这一行:卡片里每一行都是 字段: 值', 'Cannot read this line: each line in a card is field: value'),
          j + 1);
      }
      if (!V1_CARD_FIELDS.includes(key)) {
        throw new QuizifyError(
          m(`不认识的字段 ${key}。卡片只认 ${V1_CARD_FIELDS.join(' / ')}`,
          `Unknown field ${key}. A card only accepts ${V1_CARD_FIELDS.join(' / ')}`), j + 1);
      }
      if (card.keys.includes(key)) {
        throw new QuizifyError(m(`一张卡里 ${key} 写了两次`, `${key} appears twice in one card`), j + 1);
      }
      const v: Val = readValue(lines, j, rest.substring(rest.indexOf(':') + 1), keyCol, key);
      card.keys.push(key);
      card.vals.push(v);
      j = v.next;
      // 同一张卡的下一个字段:缩进比短横线深、而且不是新的 `- `
      while (j < lines.length && (isBlank(lines[j]) || isComment(lines[j]))) {
        j++;
      }
      if (j >= lines.length) {
        break;
      }
      const nx = lines[j];
      const ni = indentOf(nx);
      if (ni <= dashIndent) {
        break;
      }
      if (hasTab(nx)) {
        throw new QuizifyError(m('YAML 不允许用 Tab 缩进,请改成空格', 'YAML does not allow tab indentation; use spaces'), j + 1);
      }
      keyCol = ni;
      rest = nx.substring(ni);
    }
    out.push(card);
  }
  return out;
}

/** 答案字母 -> 规范形式(大写、去重、按字母序拼接,如 AC) */
function normalizeAnswer(v: Val, optionCount: number): string {
  const raw: string[] = [];
  const at: number[] = [];
  if (v.kind === ValKind.List) {
    for (let k = 0; k < v.items.length; k++) {
      raw.push(v.items[k].trim());
      at.push(v.itemLines[k]);
    }
  } else if (v.kind === ValKind.Scalar) {
    raw.push(v.text.trim());
    at.push(v.line);
  } else {
    throw new QuizifyError(m('answer 写成字母,如 answer: D 或 answer: [A, C]',
      'Write answer as letters, e.g. answer: D or answer: [A, C]'), v.line);
  }
  if (raw.length === 0) {
    throw new QuizifyError(m('answer 是空的', 'answer is empty'), v.line);
  }
  const last: string = String.fromCharCode(64 + optionCount);
  const picked: string[] = [];
  for (let k = 0; k < raw.length; k++) {
    const s = raw[k].toUpperCase();
    if (!/^[A-Z]$/.test(s) || s.charCodeAt(0) - 65 >= optionCount) {
      throw new QuizifyError(
        m(`答案 ${raw[k]} 不在选项里:一共 ${optionCount} 个选项,答案只能是 A–${last}`,
        `Answer ${raw[k]} is not one of the options: there are ${optionCount}, so answers run A–${last}`),
        at[k]);
    }
    if (!picked.includes(s)) {
      picked.push(s);
    }
  }
  picked.sort();
  return picked.join('');
}

/** 正面里有没有 Quizify 的 `;;;` 选择题块(v1 用 options / answer) */
function hasChoiceFence(front: string): boolean {
  for (const ln of front.split('\n')) {
    if (/^\s*;;;/.test(ln)) {
      return true;
    }
  }
  return false;
}

/** 没写 title 时显示用的标题:正面首个非空行(去掉开头的 ####),与 Quizify 一致。导出器也用它判断要不要写 title */
export function fallbackTitle(front: string): string {
  for (const ln of front.split('\n')) {
    const t = ln.trim();
    if (t.length > 0) {
      return t.replace(/^#{1,6}\s+/, '');
    }
  }
  return '';
}

function buildV1Card(c: RawV1Card, index: number): ParsedCard {
  const typeVal: Val | null = fieldOf(c, 'type');
  const typeWord: string = typeVal === null ? 'qa' : wordOf(typeVal, 'type');
  let type: NoteType = NoteType.QA;
  if (typeWord === 'choice') {
    type = NoteType.Choice;
  } else if (typeWord === 'cloze') {
    type = NoteType.Cloze;
  } else if (typeWord !== 'qa') {
    throw new QuizifyError(m(`不认识的题型 ${typeWord}。type 只能是 qa / choice / cloze`,
      `Unknown type ${typeWord}. type must be qa / choice / cloze`), typeVal === null ? c.line : typeVal.line);
  }

  const frontVal: Val | null = fieldOf(c, 'front');
  if (frontVal === null) {
    throw new QuizifyError(m('这张卡缺少 front', 'This card is missing front'), c.line);
  }
  const front: string = textOf(frontVal, 'front');
  if (front.trim().length === 0) {
    throw new QuizifyError(m('这张卡的 front 是空的', 'This card has an empty front'), frontVal.line);
  }
  if (hasChoiceFence(front)) {
    throw new QuizifyError(
      m('v1 不再用 ;;; 写选择题。改成 type: choice,再用 options 列选项、answer 写答案字母',
      'v1 no longer uses ;;; for multiple choice. Use type: choice with options and answer'), frontVal.line);
  }

  const backVal: Val | null = fieldOf(c, 'back');
  const back: string = backVal === null ? '' : textOf(backVal, 'back');
  const titleVal: Val | null = fieldOf(c, 'title');
  const title: string = titleVal === null ? '' : textOf(titleVal, 'title').trim();

  const idVal: Val | null = fieldOf(c, 'id');
  const id: string = idVal === null ? '' : wordOf(idVal, 'id');
  if (idVal !== null && !CARD_ID_RE.test(id)) {
    throw new QuizifyError(m(`id 只能用字母、数字和 -,不能是「${id}」`,
      `id may only contain letters, digits and -, not "${id}"`), idVal.line);
  }
  const tagsVal: Val | null = fieldOf(c, 'tags');
  const tags: string[] = tagsVal === null ? [] : listOf(tagsVal, 'tags');

  const optVal: Val | null = fieldOf(c, 'options');
  const ansVal: Val | null = fieldOf(c, 'answer');
  let options: string[] = [];
  let answer = '';
  if (type === NoteType.Choice) {
    if (optVal === null) {
      throw new QuizifyError(m('选择题缺少 options(选项列表)', 'This choice card is missing options'), c.line);
    }
    if (ansVal === null) {
      throw new QuizifyError(m('选择题缺少 answer(答案字母)', 'This choice card is missing answer'), c.line);
    }
    if (optVal.kind !== ValKind.List) {
      throw new QuizifyError(m('options 要写成列表,如 options: ["甲", "乙"]', 'options must be a list, e.g. options: ["a", "b"]'),
        optVal.line);
    }
    for (let k = 0; k < optVal.items.length; k++) {
      if (!optVal.itemsQuoted[k]) {
        throw new QuizifyError(m('每个选项都要用引号包起来(选项里常有冒号、# 或公式)',
          'Every option must be quoted (options often contain colons, # or math)'), optVal.itemLines[k]);
      }
      if (optVal.items[k].trim().length === 0) {
        throw new QuizifyError(m('有一个选项是空的', 'One of the options is empty'), optVal.itemLines[k]);
      }
    }
    if (optVal.items.length < 2) {
      throw new QuizifyError(m('选择题至少 2 个选项', 'A choice card needs at least 2 options'), optVal.line);
    }
    // 按位置编号,存成「A. 内容」:复习页按下标取字母,显示时原样展示这一行
    for (let k = 0; k < optVal.items.length; k++) {
      options.push(`${String.fromCharCode(65 + k)}. ${optVal.items[k].trim()}`);
    }
    answer = normalizeAnswer(ansVal, optVal.items.length);
  } else {
    if (optVal !== null) {
      throw new QuizifyError(m('只有 type: choice 的卡才能写 options', 'Only a type: choice card may have options'),
        optVal.line);
    }
    if (ansVal !== null) {
      throw new QuizifyError(m('只有 type: choice 的卡才能写 answer(挖空的答案写在 {{ }} 里)',
        'Only a type: choice card may have answer (cloze answers go inside {{ }})'), ansVal.line);
    }
  }

  const blanks: string[] = clozeAnswers(front);
  if (type === NoteType.Cloze && blanks.length === 0) {
    throw new QuizifyError(m('挖空题的正面里没有 {{ }}。把要考的词写成 {{答案}}',
      'This cloze card has no {{ }} in its front. Mark each blank as {{answer}}'), c.line);
  }
  if (type === NoteType.QA && back.trim().length === 0) {
    throw new QuizifyError(m('问答题缺少 back(答案)', 'This qa card is missing back'), c.line);
  }

  const shown: string = title.length > 0 ? title : fallbackTitle(front);
  return {
    title: shown,
    // 有 id 时身份就是 id;没有就和 Quizify 一样按标题取标识键(给旧的指纹路径用)
    key: id.length > 0 ? id : cardKeyOf(shown),
    front: front,
    back: back,
    options: options,
    answer: answer,
    clozeCount: type === NoteType.Cloze ? blanks.length : 0,
    type: type,
    index: index,
    line: c.line,
    id: id,
    tags: tags,
  };
}

function parseV1(lines: string[]): ParsedDeck {
  let deck = '';
  let deckLine = 0;
  let tags: string[] = [];
  let meta: DeckMeta = emptyMeta();
  let raws: RawV1Card[] = [];
  let sawCards = false;
  const seenTop: string[] = [];

  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (isBlank(line) || isComment(line)) {
      i++;
      continue;
    }
    if (hasTab(line)) {
      throw new QuizifyError(m('YAML 不允许用 Tab 缩进,请改成空格', 'YAML does not allow tab indentation; use spaces'), i + 1);
    }
    if (indentOf(line) !== 0) {
      throw new QuizifyError(m('缩进对不上:这一行既不是顶层字段,也不在 meta 或 cards 里',
        'Indentation does not line up: this line is not a top-level field, nor inside meta or cards'), i + 1);
    }
    const t = line.trim();
    const key = keyOf(t);
    if (!V1_TOP_FIELDS.includes(key)) {
      throw new QuizifyError(
        m(`不认识的顶层字段 ${key.length > 0 ? key : t}。只认 ${V1_TOP_FIELDS.join(' / ')}`,
        `Unknown top-level field ${key.length > 0 ? key : t}. Only ${V1_TOP_FIELDS.join(' / ')} are accepted`), i + 1);
    }
    if (seenTop.includes(key)) {
      throw new QuizifyError(m(`顶层字段 ${key} 写了两次`, `Top-level field ${key} appears twice`), i + 1);
    }
    seenTop.push(key);
    const rest = t.substring(t.indexOf(':') + 1);

    if (key === 'reps') {
      const ver = unquote(rest).trim();
      if (ver !== '1') {
        throw new QuizifyError(m(`不支持的格式版本 reps: ${ver}。这个版本的 REPS 只认 reps: 1`,
          `Unsupported format version reps: ${ver}. This version of REPS only reads reps: 1`), i + 1);
      }
      i++;
    } else if (key === 'deck') {
      deck = unquote(rest).trim();
      deckLine = i + 1;
      if (deck.length === 0) {
        throw new QuizifyError(m('deck 不能是空的', 'deck cannot be empty'), i + 1);
      }
      i++;
    } else if (key === 'tags') {
      tags = listOf(readValue(lines, i, rest, 0, 'tags'), 'tags');
      i++;
    } else if (key === 'meta') {
      if (rest.trim().length > 0) {
        throw new QuizifyError(m('meta: 后面直接换行,下面缩进写各个字段', 'Put a newline after meta:, then indent its fields'), i + 1);
      }
      const entries: MetaEntry[] = readMeta(lines, i);
      meta = buildMeta(entries);
      i = entries.length > 0 ? entries[entries.length - 1].val.next : i + 1;
    } else {
      // cards
      if (rest.trim().length > 0) {
        throw new QuizifyError(m('cards: 后面直接换行,卡片写成 - 字段: 值 的列表',
          'Put a newline after cards:, then list each card as - field: value'), i + 1);
      }
      sawCards = true;
      raws = readV1Cards(lines, i);
      let j = i + 1;
      while (j < lines.length && (isBlank(lines[j]) || isComment(lines[j]) || indentOf(lines[j]) > 0)) {
        j++;
      }
      i = j;
    }
  }

  if (deck.length === 0) {
    throw new QuizifyError(m('缺少 deck,卡片没有可靠的落点', 'Missing deck, so the cards have nowhere to land'), 1);
  }
  if (!sawCards || raws.length === 0) {
    throw new QuizifyError(m('cards 下面一张卡都没有', 'No cards listed under cards'), deckLine);
  }

  const cards: ParsedCard[] = [];
  const idLine = new Map<string, number>();
  const keyLine = new Map<string, number>();
  for (let k = 0; k < raws.length; k++) {
    const c: ParsedCard = buildV1Card(raws[k], k);
    if (c.id.length > 0) {
      const prev = idLine.get(c.id);
      const at: number = (fieldOf(raws[k], 'id') as Val).line;
      if (prev !== undefined) {
        throw new QuizifyError(m(`id「${c.id}」重复(上一次在第 ${prev} 行)。id 在文件内必须唯一`,
          `id "${c.id}" is repeated (first on line ${prev}). ids must be unique within the file`), at);
      }
      idLine.set(c.id, at);
    }
    const prevKey = keyLine.get(c.key);
    if (prevKey !== undefined) {
      throw new QuizifyError(
        m(`这张卡和第 ${prevKey} 行那张认不出区别(标识「${c.key}」相同)。给它们各写一个 id 或不同的 title`,
        `This card cannot be told apart from the one on line ${prevKey} (same identity "${c.key}"). `
        + 'Give each an id or a different title'), c.line);
    }
    keyLine.set(c.key, c.line);
    cards.push(c);
  }

  return {
    deck: deck,
    tags: tags,
    format: 1,
    hadFrontMatter: true,
    cards: cards,
    meta: meta,
  };
}
