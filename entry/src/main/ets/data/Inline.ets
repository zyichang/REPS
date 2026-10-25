/**
 * 行内标记解析 —— **纯逻辑,不 import 任何 @kit.\* **。
 *
 * ArkUI 的 Text 不认 Markdown:`**粗体**` 会原样显示成五个字符。
 * 所以要把一段文本切成带样式的片段,再由显示层用 Span 拼起来。
 *
 * 支持的语法(取自 Quizify 规范,按真实语料里的出现频率排序):
 *   `\` 行尾硬换行     23 个文件   —— 去掉反斜杠,保留换行
 *   `**粗体**`                    —— 加粗
 *   `*斜体*`                      —— 斜体;星号必须紧贴文字,`a * b` 不算
 *   `==高亮==`          6 个文件   —— 黄色底
 *   `` `行内代码` ``              —— 等宽 + 浅灰底
 *   `X^2^`              1 个文件   —— 上标
 *   `H~2~O`                       —— 下标
 *   `[[题干||答案]]`              —— 点击显示,这里先只取题干部分
 *   `[术语]^(解释)^`              —— 保留术语,解释加括号跟在后面
 *
 * 数学 `$…$` **不在这里处理**:它要么原样显示(当前),要么交给
 * KaTeX + WebView(Task 12)。在这里剥掉 `$` 会让公式变成乱码文本。
 */

/** 片段的样式种类 */
export enum InlineKind {
  Plain = 0,
  Bold = 1,
  Highlight = 2,
  Code = 3,
  Sup = 4,
  Sub = 5,
  /** 数学表达式,含首尾的 $。显示层先按等宽原样显示 */
  Math = 6,
  Italic = 7
}

/** 一个带样式的文本片段 */
export interface InlineSpan {
  text: string;
  kind: InlineKind;
}

/** 去掉 Markdown 的行尾硬换行反斜杠,换行本身保留 */
export function stripHardBreaks(text: string): string {
  return text.replace(/\\(\r?\n)/g, '$1').replace(/\\$/g, '');
}

/**
 * 预处理:把不需要样式、只需要改写文字的语法先摊平。
 *
 *   `#### 标题`        -> `标题`(ArkUI 不认 Markdown 标题,# 会原样显示)
 *   `[[题干||答案]]`  -> `题干`(答案属于背面,正面不该出现)
 *   `[术语]^(解释)^`  -> `术语(解释)`
 *   `::: 标题` / `:::` -> 去掉围栏行,内容保留
 */
export function flattenInline(text: string): string {
  let t = text;
  // ATX 标题标记:Quizify 用 #### 携带卡片标题,ArkUI 会把 # 原样画出来
  t = t.replace(/^\s{0,3}#{1,6}\s+/gm, '');
  // 点击显示:正面只留题干那一半
  t = t.replace(/\[\[([^\]|]*)\|\|[^\]]*\]\]/g, '$1');
  // 行内注释:[术语]^(解释)^ -> 术语(解释)
  t = t.replace(/\[([^\]]*)\]\^\(([^)]*)\)\^/g, '$1($2)');
  // 折叠块的围栏行整行去掉(内容保留,折叠交给显示层决定要不要做)
  t = t.replace(/^:::.*$/gm, '');
  return t;
}

interface Marker {
  open: string;
  close: string;
  kind: InlineKind;
}

/**
 * 标记表。单个 `*` 的斜体不在表里,单独由 italicEnd 判断:
 * 它和乘号、列表符号容易混,规则比这几种严。
 */
const MARKERS: Marker[] = [
  { open: '**', close: '**', kind: InlineKind.Bold },
  { open: '==', close: '==', kind: InlineKind.Highlight },
  { open: '`', close: '`', kind: InlineKind.Code },
  { open: '^', close: '^', kind: InlineKind.Sup },
  { open: '~', close: '~', kind: InlineKind.Sub },
];

/**
 * 把一行文本切成带样式的片段。
 *
 * 数学优先:先把 `$…$` 整段摘出来当 Math 片段,里面的 `^` `~` `**`
 * 一概不解释 —— LaTeX 里这些符号有自己的含义,按 Markdown 去切会切坏公式。
 */
export function parseInline(text: string): InlineSpan[] {
  const out: InlineSpan[] = [];
  const src = flattenInline(stripHardBreaks(text));
  let i = 0;
  let plain = '';

  const pushPlain = (): void => {
    if (plain.length > 0) {
      out.push({ text: plain, kind: InlineKind.Plain });
      plain = '';
    }
  };

  while (i < src.length) {
    const ch = src.charAt(i);

    // ---- 数学:$…$ 整段原样保留 ----
    if (ch === '$') {
      // $$ 开头的块级公式:找下一个 $$
      const isBlock = src.startsWith('$$', i);
      const marker = isBlock ? '$$' : '$';
      const end = src.indexOf(marker, i + marker.length);
      if (end > 0) {
        pushPlain();
        out.push({ text: src.substring(i, end + marker.length), kind: InlineKind.Math });
        i = end + marker.length;
        continue;
      }
      // 没有配对的 $,当普通字符
      plain += ch;
      i++;
      continue;
    }

    // ---- 其余标记 ----
    let matched = false;
    for (const m of MARKERS) {
      if (!src.startsWith(m.open, i)) {
        continue;
      }
      const from = i + m.open.length;
      const end = src.indexOf(m.close, from);
      // 必须在同一行内闭合,且中间非空
      if (end < 0 || end === from) {
        continue;
      }
      const inner = src.substring(from, end);
      if (inner.includes('\n')) {
        continue;
      }
      pushPlain();
      if (m.kind === InlineKind.Bold || m.kind === InlineKind.Highlight) {
        // 粗体 / 高亮里允许有公式:`**$D$ —— 难度**`。不拆的话 $D$ 会当成粗体文字原样显示
        splitMath(inner, m.kind, out);
      } else {
        out.push({ text: inner, kind: m.kind });
      }
      i = end + m.close.length;
      matched = true;
      break;
    }
    if (matched) {
      continue;
    }

    // ---- 斜体 *…*:星号紧贴文字才算 ----
    if (ch === '*') {
      const end = italicEnd(src, i);
      if (end > 0) {
        pushPlain();
        splitMath(src.substring(i + 1, end), InlineKind.Italic, out);
        i = end + 1;
        continue;
      }
    }

    plain += ch;
    i++;
  }

  pushPlain();
  return out;
}

function isWordChar(c: string): boolean {
  return /[A-Za-z0-9_]/.test(c);
}

/**
 * 从 i 处的 `*` 开始的斜体,返回收尾 `*` 的位置;不是斜体返回 -1。
 *
 * 规则(取 CommonMark 的简化版,宁可漏认也不误认):
 *   - 开头 `*` 后面紧跟非空白、且不是 `*`;前面不是字母数字(`a*b*c` 不算)
 *   - 收尾 `*` 前面紧跟非空白;后面不是字母数字
 *   - 同一行内闭合,中间非空
 * 于是 `*Again*` 是斜体,`a * b`、`* 列表项`、`2*3*4` 都不是。
 */
function italicEnd(src: string, i: number): number {
  const next = src.charAt(i + 1);
  if (next.length === 0 || /\s/.test(next) || next === '*') {
    return -1;
  }
  if (i > 0 && (isWordChar(src.charAt(i - 1)) || src.charAt(i - 1) === '*')) {
    return -1;
  }
  for (let j = i + 2; j < src.length; j++) {
    const c = src.charAt(j);
    if (c === '\n') {
      return -1;
    }
    if (c === '*' && !/\s/.test(src.charAt(j - 1))) {
      const after = src.charAt(j + 1);
      if (after === '*' || isWordChar(after)) {
        continue;
      }
      return j;
    }
  }
  return -1;
}

/**
 * 把一段带样式的文字按 `$…$` / `$$…$$` 拆开:公式部分成 Math 片段,其余保持 kind。
 * 没有配对的 `$`(比如价格「$5」)不算公式,原样留在文字里。
 */
function splitMath(inner: string, kind: InlineKind, out: InlineSpan[]): void {
  let i = 0;
  let text = '';
  while (i < inner.length) {
    if (inner.charAt(i) === '$') {
      const marker = inner.startsWith('$$', i) ? '$$' : '$';
      const end = inner.indexOf(marker, i + marker.length);
      if (end > 0) {
        if (text.length > 0) {
          out.push({ text: text, kind: kind });
          text = '';
        }
        out.push({ text: inner.substring(i, end + marker.length), kind: InlineKind.Math });
        i = end + marker.length;
        continue;
      }
    }
    text += inner.charAt(i);
    i++;
  }
  if (text.length > 0) {
    out.push({ text: text, kind: kind });
  }
}

/** 只要纯文本(用于搜索、导出比对等场景) */
export function plainTextOf(spans: InlineSpan[]): string {
  let s = '';
  for (const sp of spans) {
    s += sp.text;
  }
  return s;
}

// ---------------------------------------------------------------- 块级切分

/** 一段内容的种类 */
export enum BlockKind {
  /** 普通段落,里面还要走 parseInline 切行内标记 */
  Para = 0,
  /** ``` 围栏代码块,**整段原样显示**,不做任何行内解析 */
  Code = 1,
  /**
   * 提示框 `> [!NOTE] 可选标题`,后面连续的 `>` 行是内容(Obsidian / GitHub 写法)。
   * text 是去掉 `>` 之后的内容,照常走行内解析;lang 放类型下标(CALLOUT_TYPES)。
   */
  Callout = 2
}

export interface Block {
  kind: BlockKind;
  text: string;
  /** 代码块:围栏后面跟的语言名,如 c / cpp。提示框:类型,如 note。没写就是空串 */
  lang: string;
  /** 提示框自己写的标题(`> [!TIP] 这里`);没写是空串,显示层用类型的默认名 */
  title: string;
}

/**
 * 认得的提示框类型(GitHub 的五种)。下标与 Strings.calloutLabels、显示层的颜色表一一对应。
 * 别的类型不认,整块按普通文字显示 —— 宁可朴素,不要猜错颜色。
 */
export const CALLOUT_TYPES: string[] = ['note', 'tip', 'important', 'warning', 'caution'];

/** 提示框类型的下标;不认识返回 -1 */
export function calloutIndex(type: string): number {
  return CALLOUT_TYPES.indexOf(type.toLowerCase());
}

/** `> [!TYPE] 标题` 这一行:返回 [类型, 标题];不是提示框开头返回 null */
function calloutHead(line: string): string[] | null {
  const m = line.match(/^\s{0,3}>\s*\[!([A-Za-z]+)\][+-]?\s*(.*)$/);
  if (m === null || calloutIndex(m[1]) < 0) {
    return null;
  }
  return [m[1].toLowerCase(), m[2].trim()];
}

/** 一行是不是围栏边界(允许前面有空格) */
function fenceLang(line: string): string | null {
  const t = line.trim();
  if (!t.startsWith('```')) {
    return null;
  }
  return t.substring(3).trim();
}

/**
 * 把文本切成「段落」和「代码块」。
 *
 * 为什么必须有这一步:`parseInline` 只处理行内标记,对 ``` 一无所知,
 * 于是围栏那三行会被当成普通文字显示出来,代码也失去等宽对齐 ——
 * 王道那本书里有 19 张卡是这种情况。
 *
 * 代码块**不做行内解析**:代码里的 `*`、`_`、`$` 都是字面意思,
 * 拿去当粗体或公式解析必然出错。
 *
 * 围栏没闭合时,把剩下的全部当代码 —— 显示层要宽容。
 * 导入时那种文件已经被 Quizify 的「``` 数量为奇数」挡下来了。
 */
export function splitBlocks(text: string): Block[] {
  const out: Block[] = [];
  const lines: string[] = text.split('\n');
  let buf: string[] = [];
  let code: string[] = [];
  let lang = '';
  let inCode = false;
  // 正在收集的提示框:类型为空串表示不在提示框里
  let qType = '';
  let qTitle = '';
  let quote: string[] = [];

  const flushQuote = () => {
    if (qType.length > 0) {
      out.push({ kind: BlockKind.Callout, text: quote.join('\n').trim(), lang: qType, title: qTitle });
      qType = '';
      qTitle = '';
      quote = [];
    }
  };

  const flushPara = () => {
    if (buf.length > 0) {
      const joined: string = buf.join('\n');
      if (joined.trim().length > 0) {
        out.push({ kind: BlockKind.Para, text: joined, lang: '', title: '' });
      }
      buf = [];
    }
  };

  for (const line of lines) {
    const f: string | null = fenceLang(line);
    if (!inCode) {
      // 提示框:开头一行定类型,后面连续的 > 行是内容,遇到别的行就结束
      if (qType.length > 0 && f === null && /^\s{0,3}>/.test(line) && calloutHead(line) === null) {
        quote.push(line.replace(/^\s{0,3}>\s?/, ''));
        continue;
      }
      flushQuote();
      const h: string[] | null = f === null ? calloutHead(line) : null;
      if (h !== null) {
        flushPara();
        qType = h[0];
        qTitle = h[1];
        quote = [];
        continue;
      }
    }
    if (!inCode && f !== null) {
      flushPara();
      inCode = true;
      lang = f;
      code = [];
      continue;
    }
    if (inCode && f !== null) {
      out.push({ kind: BlockKind.Code, text: code.join('\n'), lang: lang, title: '' });
      inCode = false;
      lang = '';
      code = [];
      continue;
    }
    if (inCode) {
      code.push(line);
    } else {
      buf.push(line);
    }
  }
  flushQuote();
  if (inCode && code.length > 0) {
    out.push({ kind: BlockKind.Code, text: code.join('\n'), lang: lang, title: '' });
  }
  flushPara();
  return out;
}
