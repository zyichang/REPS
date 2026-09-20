/**
 * Quizify Card Markdown v1 解析器 —— **纯逻辑,不 import 任何 @kit.\* **。
 *
 * 规范:~/.kiro/skills/file-to-anki-deck/references/markdown-format.md
 * 对应 Anki 的 Quizify Markdown 插件(github.com/e-chehil/anki-quizify),
 * 所以卡组可以双向流动:已有的 Anki 卡组能导进来,REPS 的也能导回去。
 *
 * 结构:
 *   文件开头必须有 YAML front matter,声明 quizify.deck(用 :: 表示卡组嵌套)
 *   +++  起一张卡的正面
 *   ***  切到背面
 *   文件结束  收尾最后一张卡
 *
 * **为什么必须写成状态机,不能按行 split:**
 * 规范明确规定,围栏代码块(```)与块级数学($$)**内部**的 +++ / ***
 * 不是结构标记。一份讲 Markdown 语法的笔记里,代码块里出现 *** 是很正常的事;
 * 按行切会把那张卡劈成两半,而且报不出错 —— 静默产出错卡是最坏的一种失败。
 *
 * Task 4 只做最小子集:front matter + 卡片切分 + 纯问答。
 * 选择题 ;;;、完形填空 {{}}、硬换行等留给 Task 6。
 */

import { NoteType } from '../model/Models';

/** 一张解析出来的卡(尚未落库,所以没有 id) */
export interface ParsedCard {
  /** #### 标题的完整原文,用于显示 */
  title: string;
  /**
   * 卡片标识键 —— 从标题里取出的**识别部分**,不含题干文字。
   *
   * 这是身份的依据(指纹取它而不取整行标题):
   * `#### 基础选择 (1) 一个算法应该是()。` 的键是 `基础选择 (1)`。
   * 这样用户把题干里的错别字改掉,卡片仍然是同一张,进度不丢。
   */
  key: string;
  /**
   * 正面。**选择题的 `;;;` 块已经被摘掉**,只剩题干。
   *
   * 这一点是安全性而不是美观:`;;;` 块的收尾行形如 `;;;D`,那个 D 就是答案。
   * 原样留在正面等于提问的同时把答案印在题面上。所以答案必须**物理移出**正面,
   * 不能只靠显示层去躲 —— 显示层以后总会有人改。
   */
  front: string;
  /** 背面原文 */
  back: string;
  /** 选择题的选项,每项一行的原文(如 `A. 程序`)。非选择题为空数组 */
  options: string[];
  /** 选择题的正确答案字母,如 `B` 或 `ABD`。非选择题为空串 */
  answer: string;
  type: NoteType;
  /** 这张卡在文件里的序号,从 0 起,仅用于报错定位 */
  index: number;
  /** 正面起始行号(1 基),报错时告诉用户去哪一行看 */
  line: number;
}

/** 整份文件的解析结果 */
export interface ParsedDeck {
  /** front matter 里的 deck,如 'Math_880::Chapter_2' */
  deck: string;
  /** deck 按 :: 拆开的层级 */
  deckPath: string[];
  tags: string[];
  format: number;
  /**
   * 文件里原本有没有 front matter。false 表示卡组名是调用方兜底给的,
   * 界面上值得提示一句,让用户知道卡组名的来历。
   */
  hadFrontMatter: boolean;
  cards: ParsedCard[];
}

/** 解析失败。message 面向用户,line 指出出问题的行 */
export class QuizifyError extends Error {
  readonly line: number;

  constructor(message: string, line: number) {
    super(line > 0 ? `第 ${line} 行: ${message}` : message);
    this.line = line;
  }
}

const MARK_CARD: string = '+++';
const MARK_SIDE: string = '***';
const FENCE: string = '```';
const MATH_BLOCK: string = '$$';

/** 解析器所处的区域 */
enum Region {
  /** 还没遇到第一个 +++ */
  Preamble = 0,
  Front = 1,
  Back = 2
}

/**
 * 判断一行是否是结构标记。
 *
 * 规范:标记必须**不缩进且独占一行**,尾部空格忽略。
 * 正文里要写字面量标记则转义成 \+++,导入时去掉那个反斜杠。
 */
function markerOf(rawLine: string): string {
  if (rawLine.length > 0 && rawLine.charAt(0) === ' ') {
    return ''; // 缩进了 -> 不是结构标记
  }
  if (rawLine.length > 0 && rawLine.charAt(0) === '\t') {
    return '';
  }
  const t = rawLine.replace(/\s+$/, '');
  if (t === MARK_CARD) {
    return MARK_CARD;
  }
  if (t === MARK_SIDE) {
    return MARK_SIDE;
  }
  return '';
}

/** 去掉标记的转义反斜杠:`\+++` -> `+++` */
function unescapeMarker(line: string): string {
  const t = line.replace(/\s+$/, '');
  if (t === '\\' + MARK_CARD || t === '\\' + MARK_SIDE) {
    return t.substring(1);
  }
  return line;
}

/** 一行是否开启/关闭围栏代码块。围栏可以带语言标注,如 ```c */
function isFence(line: string): boolean {
  return line.replace(/^\s+/, '').startsWith(FENCE);
}

/** 一行是否是独立的块级数学分隔符 $$ */
function isMathFence(line: string): boolean {
  return line.trim() === MATH_BLOCK;
}

/**
 * 从正面文本里取出 #### 标题。
 *
 * 规范:正面的首行提问要写成 H4,携带文件内唯一、带小节限定的标题。
 * 找不到标题不算错(Task 6 之前先宽松处理),用首行非空文本代替,
 * 但要保证「文件内唯一」这条由调用方检查。
 */
function extractTitle(front: string): string {
  const lines = front.split('\n');
  for (const ln of lines) {
    const m = ln.match(/^\s*#{4}\s+(.*)$/);
    if (m !== null) {
      return m[1].trim();
    }
  }
  for (const ln of lines) {
    if (ln.trim().length > 0) {
      return ln.trim();
    }
  }
  return '';
}

/**
 * 从标题里取出**卡片标识键**。
 *
 * 规范给了两种标题形式,这里各自取其识别部分:
 *   `#### 1.2.3 求下列极限`            -> `1.2.3`            (点号编号)
 *   `#### 综合填空 (3) 已知 f(x)…`      -> `综合填空 (3)`      (命名小节 + 题号)
 *   `#### 基础篇 第12章 (2)-(1) 水缸…`  -> `基础篇 第12章 (2)-(1)` (带子题号)
 *
 * **为什么不用整行标题当身份:** 整行含题干文字,用户改一个错别字就会
 * 变成另一张卡,排期进度全丢。键只取编号部分,对正文编辑免疫。
 *
 * **为什么必须吃完整条编号链:** 真实语料里有 `(2)-(1)` / `(2)-(2)` 这种子题编号。
 * 只吃第一个括号的话两者会塌成同一个键,被误判成重复卡 —— 用户 PKB 里
 * 有 8 个文件因此解析失败,是真实数据发现的 bug。
 *
 * 两种都不匹配时退回整行(此时改标题确实会被当成新卡,这是没办法的事,
 * 但至少行为是明确的)。
 */
export function cardKeyOf(title: string): string {
  const t = title.trim();

  // 点号编号:1.2.3 / 2.1 —— 必须至少含一个点,否则「1 什么是栈」会误命中
  const dotted = t.match(/^(\d+(?:\.\d+)+)/);
  if (dotted !== null) {
    return dotted[1];
  }

  // 命名小节 + 一条或多条括号编号。中英文括号都认,括号内允许空格,
  // 编号之间允许 - 或 . 或空格连接。
  const named = t.match(/^(.*?)((?:[(（]\s*\d+\s*[)）])(?:\s*[-.]?\s*[(（]\s*\d+\s*[)）])*)/);
  if (named !== null) {
    const name = named[1].trim();
    // 把编号链规范化:全角括号转半角、去掉内部空格,连接符统一成 -
    const nums: string[] = [];
    const re = /[(（]\s*(\d+)\s*[)）]/g;
    let m = re.exec(named[2]);
    while (m !== null) {
      nums.push(`(${m[1]})`);
      m = re.exec(named[2]);
    }
    const chain = nums.join('-');
    return name.length > 0 ? `${name} ${chain}` : chain;
  }

  return t;
}

/** 摘出来的选择题块 */
export interface ChoiceBlock {
  /** 摘掉 ;;; 块之后剩下的题干 */
  stem: string;
  /** 选项原文,每项一行 */
  options: string[];
  /** 正确答案字母,单选一个字母,多选多个,如 ABD */
  answer: string;
  found: boolean;
}

const MARK_CHOICE: string = ';;;';

/**
 * 去掉行尾的空白与 Markdown 硬换行反斜杠。
 *
 * 真实语料里有人把开启标记写成 `;;;\`(顺手给每行都加了硬换行),
 * 只按空白去尾的话这一行就认不出来,整个 `;;;` 块连答案一起留在正面。
 * 用户 PKB 的 3_1.md 就是这样,1850 张卡里泄露了 1 张。
 */
function trimTailAndBreak(line: string): string {
  return line.replace(/\s+$/, '').replace(/\\+$/, '').replace(/\s+$/, '');
}

/**
 * 从正面里摘出 `;;;` 选择题块。
 *
 * 规范形状:
 * ```
 * ;;;
 * A. 程序
 * B. 问题求解步骤的描述
 * ;;;B          <- 收尾行紧跟答案字母,多选则多个字母
 * ```
 *
 * **为什么一定要摘出来而不是留在正面:** 收尾行 `;;;B` 里的 B 就是答案。
 * 留在正面等于把答案印在题面上。这在用户 PKB 的 60 个文件里都会发生。
 *
 * 围栏代码块内部的 `;;;` 不算 —— 同 +++/*** 的道理。
 */
export function extractChoiceBlock(front: string): ChoiceBlock {
  const lines = front.split('\n');
  let inFence = false;
  let start = -1;
  let end = -1;
  let answer = '';

  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    if (isFence(raw)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) {
      continue;
    }
    const t = trimTailAndBreak(raw);
    if (!t.startsWith(MARK_CHOICE)) {
      continue;
    }
    // 开启行是光秃秃的 ;;;(可能带硬换行反斜杠,已在上面剥掉)
    if (start < 0 && t === MARK_CHOICE) {
      start = i;
      continue;
    }
    // 收尾行是 ;;; 紧跟答案字母(也允许光秃秃的 ;;;,此时答案未知)
    if (start >= 0 && end < 0) {
      end = i;
      answer = t.substring(MARK_CHOICE.length).trim().toUpperCase();
      break;
    }
  }

  if (start < 0 || end < 0) {
    return { stem: front, options: [], answer: '', found: false };
  }

  const options: string[] = [];
  for (let i = start + 1; i < end; i++) {
    // 选项行的硬换行反斜杠对显示没有意义(每个选项本来就独占一行),剥掉
    const one = trimTailAndBreak(lines[i]).trim();
    if (one.length > 0) {
      options.push(one);
    }
  }

  // 题干 = ;;; 块之前 + 之后的内容(之后通常是空的,但别丢)
  const before = lines.slice(0, start);
  const after = lines.slice(end + 1);
  const stem = trimBlankEdges(before.concat(after));

  return { stem: stem, options: options, answer: answer, found: true };
}

/** 去掉首尾空行,但保留内部换行(正文的排版是有意义的) */
function trimBlankEdges(lines: string[]): string {
  let a = 0;
  let b = lines.length;
  while (a < b && lines[a].trim().length === 0) {
    a++;
  }
  while (b > a && lines[b - 1].trim().length === 0) {
    b--;
  }
  return lines.slice(a, b).join('\n');
}

// ---------------------------------------------------------------- front matter

interface FrontMatter {
  deck: string;
  tags: string[];
  format: number;
  /** front matter 之后的第一行下标(0 基) */
  bodyStart: number;
  /** 文件里原本有没有 front matter。false 表示用的是兜底卡组名 */
  hadFrontMatter: boolean;
}

/** front matter 的三个可变字段。单独一个接口,是为了能把 applyField 提到顶层 */
interface FmFields {
  deck: string;
  tags: string[];
  format: number;
}

/**
 * 把一个 key: value 写进 FmFields。
 *
 * 注意:**ArkTS 不允许嵌套函数声明**(arkts-no-nested-funcs),
 * 所以这个函数必须在顶层,靠参数把状态传进来,不能写成 parseFrontMatter 内部的闭包。
 */
function applyField(f: FmFields, key: string, value: string): void {
  if (key === 'deck') {
    f.deck = stripQuotes(value);
  } else if (key === 'tags') {
    f.tags = parseList(value);
  } else if (key === 'format') {
    const n = parseInt(value, 10);
    f.format = isNaN(n) ? 1 : n;
  }
}

/**
 * 读 front matter。
 *
 * 规范说这一块是**必需**的:没有显式 deck,导入就没有可靠的落点。
 * 这里只认 quizify 这一层下面的简单标量与列表,不做通用 YAML 解析
 * (通用 YAML 会引入依赖,而且我们只需要三个字段)。
 */
function parseFrontMatter(lines: string[], fallbackDeck?: string): FrontMatter {
  let i = 0;
  while (i < lines.length && lines[i].trim().length === 0) {
    i++;
  }
  if (i >= lines.length || lines[i].trim() !== '---') {
    // 没有 front matter。调用方给了兜底卡组名就照用,否则报错。
    if (fallbackDeck !== undefined && fallbackDeck.length > 0) {
      return { deck: fallbackDeck, tags: [], format: 1, bodyStart: i, hadFrontMatter: false };
    }
    throw new QuizifyError('缺少 YAML front matter。文件开头必须有 --- 包起来的 quizify 声明', i + 1);
  }

  const start = i;
  i++;
  let end = -1;
  while (i < lines.length) {
    if (lines[i].trim() === '---') {
      end = i;
      break;
    }
    i++;
  }
  if (end < 0) {
    throw new QuizifyError('front matter 没有结束的 ---', start + 1);
  }

  let inQuizify = false;
  const f: FmFields = { deck: '', tags: [], format: 1 };

  for (let k = start + 1; k < end; k++) {
    const raw = lines[k];
    if (raw.trim().length === 0) {
      continue;
    }
    const indented = /^\s+/.test(raw);
    const body = raw.trim();

    if (!indented) {
      inQuizify = body.startsWith('quizify:');
      // 支持写成一行的 quizify: { deck: X, tags: [a, b] } 这种紧凑形式。
      // 不能直接按逗号切:那会把 [a, b] 劈成 "[a" 和 "b]"。
      const inline = body.match(/^quizify:\s*\{(.*)\}$/);
      if (inline !== null) {
        for (const part of splitTopLevel(inline[1])) {
          const idx2 = part.indexOf(':');
          if (idx2 > 0) {
            applyField(f, part.substring(0, idx2).trim(), part.substring(idx2 + 1).trim());
          }
        }
      }
      continue;
    }
    if (!inQuizify) {
      continue;
    }
    const idx = body.indexOf(':');
    if (idx < 0) {
      continue;
    }
    applyField(f, body.substring(0, idx).trim(), body.substring(idx + 1).trim());
  }

  if (f.deck.length === 0) {
    throw new QuizifyError('front matter 里必须声明 quizify.deck,否则卡片没有可靠的落点', start + 1);
  }
  if (f.format !== 1) {
    throw new QuizifyError(`不支持的 format: ${f.format}(本解析器只认 format: 1)`, start + 1);
  }

  return { deck: f.deck, tags: f.tags, format: f.format, bodyStart: end + 1, hadFrontMatter: true };
}

function stripQuotes(s: string): string {
  const t = s.trim();
  if (t.length >= 2) {
    const q = t.charAt(0);
    if ((q === '"' || q === "'") && t.charAt(t.length - 1) === q) {
      return t.substring(1, t.length - 1);
    }
  }
  return t;
}

/**
 * 按顶层逗号切分,方括号内部的逗号不算分隔。
 * 用于紧凑写法 `{ deck: X, tags: [a, b] }` —— 直接 split(',') 会把列表劈开。
 */
function splitTopLevel(s: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let cur = '';
  for (let i = 0; i < s.length; i++) {
    const ch = s.charAt(i);
    if (ch === '[' || ch === '{') {
      depth++;
    } else if (ch === ']' || ch === '}') {
      depth--;
    }
    if (ch === ',' && depth === 0) {
      out.push(cur);
      cur = '';
      continue;
    }
    cur += ch;
  }
  if (cur.trim().length > 0) {
    out.push(cur);
  }
  return out;
}

/** 解析 [a, b, c] 或 a, b, c 形式的列表。tag 内不允许空格 */
function parseList(value: string): string[] {
  let t = value.trim();
  if (t.startsWith('[') && t.endsWith(']')) {
    t = t.substring(1, t.length - 1);
  }
  const out: string[] = [];
  for (const part of t.split(',')) {
    const one = stripQuotes(part).trim();
    if (one.length > 0) {
      out.push(one);
    }
  }
  return out;
}

// ---------------------------------------------------------------- 主解析

/**
 * 解析一份 Quizify Markdown。
 *
 * fallbackDeck:当文件没有 front matter 时用作卡组名(通常由调用方取文件名)。
 * 不传则缺 front matter 直接报错。
 *
 * 为什么留这个口子:规范把 front matter 定为必需,理由是「没有显式 deck,
 * 导入就没有可靠的落点」—— 那是针对 Anki 导入界面说的。REPS 导入的是用户
 * **亲手选中的那个文件**,文件路径本身就是可靠落点。用户 PKB 里有 25 个文件
 * (548 张真卡)是直接从 +++ 开头的,一律拒收没有道理。
 *
 * 失败时抛 QuizifyError 而不是返回半成品 —— 静默产出错卡比报错糟得多。
 */
export function parseQuizify(text: string, fallbackDeck?: string): ParsedDeck {
  // 统一换行,顺手去掉 BOM
  const clean = text.replace(/^\uFEFF/, '').replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const lines = clean.split('\n');

  const fm = parseFrontMatter(lines, fallbackDeck);

  const cards: ParsedCard[] = [];
  let region: Region = Region.Preamble;
  let frontLines: string[] = [];
  let backLines: string[] = [];
  let cardStartLine = 0;
  let sideMarks = 0;

  // 围栏状态:在围栏内部,结构标记一律不作数
  let inFence = false;
  let inMath = false;

  const flush = (endLine: number): void => {
    const front = trimBlankEdges(frontLines);
    if (front.length === 0) {
      throw new QuizifyError('这张卡的正面是空的', cardStartLine);
    }
    if (sideMarks === 0) {
      throw new QuizifyError(
        `这张卡没有 *** 分隔线,正面与背面分不开(标题「${extractTitle(front)}」)`, cardStartLine);
    }
    if (sideMarks > 1) {
      throw new QuizifyError(
        `这张卡有 ${sideMarks} 条 *** 分隔线,每张卡只能有一条`, cardStartLine);
    }
    const title = extractTitle(front);
    const choice: ChoiceBlock = extractChoiceBlock(front);
    cards.push({
      title: title,
      key: cardKeyOf(title),
      front: choice.found ? choice.stem : front,
      back: trimBlankEdges(backLines),
      options: choice.options,
      answer: choice.answer,
      type: choice.found ? NoteType.Choice : NoteType.QA,
      index: cards.length,
      line: cardStartLine,
    });
  };

  for (let i = fm.bodyStart; i < lines.length; i++) {
    const raw = lines[i];
    const lineNo = i + 1;

    // 围栏优先级最高:先切换状态,再决定这一行怎么归属
    if (isFence(raw)) {
      inFence = !inFence;
    } else if (!inFence && isMathFence(raw)) {
      inMath = !inMath;
    }

    const mark = (inFence || inMath) ? '' : markerOf(raw);

    if (mark === MARK_CARD) {
      if (region !== Region.Preamble) {
        flush(lineNo);
      }
      region = Region.Front;
      frontLines = [];
      backLines = [];
      sideMarks = 0;
      cardStartLine = lineNo;
      continue;
    }

    if (mark === MARK_SIDE) {
      if (region === Region.Preamble) {
        throw new QuizifyError('出现 *** 之前必须先有 +++ 开启一张卡', lineNo);
      }
      sideMarks++;
      region = Region.Back;
      continue;
    }

    if (region === Region.Front) {
      frontLines.push(unescapeMarker(raw));
    } else if (region === Region.Back) {
      backLines.push(unescapeMarker(raw));
    }
    // Preamble 区域的正文直接丢掉:front matter 与第一个 +++ 之间不该有内容
  }

  if (inFence) {
    throw new QuizifyError('有围栏代码块没有闭合(``` 数量为奇数)', lines.length);
  }
  if (region === Region.Preamble) {
    throw new QuizifyError('整份文件里没有任何 +++,一张卡都没有', fm.bodyStart + 1);
  }
  flush(lines.length);

  // 标识键必须文件内唯一 —— 指纹由 (deck, 键, 序号) 构成,
  // 键撞车会让两张不同的卡被认成同一张,重导时互相覆盖。
  //
  // 注意查的是 key 而不是整行 title:`选择 (1) 甲` 与 `选择 (1) 乙`
  // 标题不同但键同为 `选择 (1)`,仍然会撞车,必须拦住。
  const seen = new Map<string, number>();
  for (const c of cards) {
    const prev = seen.get(c.key);
    if (prev !== undefined) {
      throw new QuizifyError(
        `卡片标识「${c.key}」重复(上一次在第 ${prev} 行)。` +
        `Quizify 要求标题在文件内唯一并带小节限定,例如「基础选择 (1)」与「综合选择 (1)」`,
        c.line);
    }
    seen.set(c.key, c.line);
  }

  return {
    deck: fm.deck,
    deckPath: fm.deck.split('::').map((s) => s.trim()).filter((s) => s.length > 0),
    tags: fm.tags,
    format: fm.format,
    hadFrontMatter: fm.hadFrontMatter,
    cards: cards,
  };
}
