/**
 * 导出:库里的一副牌组 -> REPS Card YAML v1 文本(ADR-0007,docs/data-model.md §1、§6)。
 *
 * **纯逻辑,不 import 任何 @kit.\*** —— 桌面测试 export_test 把导出结果再交给 parseYamlDeck,
 * 断言逐字段往返一致。写文件、弹分享面板在 Database / ExportAction 里。
 *
 * 只写内容字段(reps / meta / deck / tags / cards)。**排期、作答流水、打卡、设备 id 一样都不写** ——
 * 函数的输入里压根没有这些数据,这是隐私的结构性保证,不靠「记得别写」。
 *
 * 写法规则(都是为了让我们自己的严格解析器原样读回来):
 *   - 正文一律引号或 `|` 块;多行用块,单行用双引号(只转义 \ 和 ")。
 *   - 块的首行以空格开头(缩进的代码)时写 `|2`,否则那几个空格会被当成缩进吃掉。
 *   - 选项去掉库里的「A. 」前缀,按位置写回;答案单选写字母,多选写列表。
 *   - title 等于正面首行(没写 title 时的默认值)就不写,文件保持干净。
 */

import { NoteType } from '../model/Models';
import { DeckMeta } from './Quizify';
import { fallbackTitle } from './Yaml';

/** 要导出的牌组 */
export interface ExportDeck {
  name: string;
  /** 写成 meta.id */
  uuid: string;
  tags: string[];
  meta: DeckMeta;
}

/** 要导出的一张卡(库里的原样) */
export interface ExportCard {
  /** notes.uuid,可能带「牌组uuid/」前缀 */
  uuid: string;
  type: number;
  title: string;
  front: string;
  back: string;
  /** 库里的选项,每项形如「A. 内容」 */
  options: string[];
  /** 如 D、AC */
  answer: string;
  tags: string[];
}

const ID_RE: RegExp = /^[A-Za-z0-9-]+$/;

/** 双引号标量。我们的解析器只认 \" 与 \\ 两种转义,所以也只转义这两样 */
function dq(s: string): string {
  return `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

/** 一个正文字段:单行用双引号,多行用块标量。indent 是键所在的列 */
function textField(key: string, value: string, indent: number): string[] {
  const pad = ' '.repeat(indent);
  if (!value.includes('\n')) {
    return [`${pad}${key}: ${dq(value)}`];
  }
  const lines = value.split('\n');
  let first = '';
  for (const ln of lines) {
    if (ln.trim().length > 0) {
      first = ln;
      break;
    }
  }
  // 首个非空行以空格开头:写缩进指示符,正文从键列 + 2 开始
  const head = first.startsWith(' ') ? '|2' : '|';
  const body = ' '.repeat(indent + 2);
  const out: string[] = [`${pad}${key}: ${head}`];
  for (const ln of lines) {
    out.push(ln.length === 0 ? '' : body + ln);
  }
  return out;
}

function inlineList(items: string[]): string {
  return `[${items.map((s: string) => dq(s)).join(', ')}]`;
}

/** 库里的 uuid -> 文件里的 id:剥掉本牌组的命名空间;剩下不合法的字符换成 - */
export function cardIdOf(deckUuid: string, uuid: string): string {
  const prefix = `${deckUuid}/`;
  const bare = uuid.startsWith(prefix) ? uuid.substring(prefix.length) : uuid;
  return ID_RE.test(bare) ? bare : bare.replace(/[^A-Za-z0-9-]/g, '-');
}

/** 库里的「A. 内容」-> 内容 */
export function optionText(stored: string): string {
  const m = stored.match(/^[A-Z]\.\s?(.*)$/);
  return m !== null ? m[1] : stored;
}

function typeWord(type: number): string {
  if (type === (NoteType.Choice as number)) {
    return 'choice';
  }
  if (type === (NoteType.Cloze as number)) {
    return 'cloze';
  }
  return 'qa';
}

function metaLines(deck: ExportDeck): string[] {
  const m: DeckMeta = deck.meta;
  const out: string[] = ['meta:', `  id: ${deck.uuid}`, `  version: ${m.version > 0 ? m.version : 1}`];
  if (m.author.length > 0) {
    out.push(`  author: ${dq(m.author)}`);
  }
  if (m.language.length > 0) {
    out.push(`  language: ${m.language}`);
  }
  if (m.license.length > 0) {
    out.push(`  license: ${m.license}`);
  }
  if (m.description.length > 0) {
    out.push(...textField('description', m.description, 2));
  }
  if (m.source.length > 0) {
    out.push(...textField('source', m.source, 2));
  }
  if (m.generatedBy.length > 0) {
    out.push(`  generated_by: ${m.generatedBy}`);
  }
  return out;
}

/** 整副牌组 -> YAML 文本(以换行结尾) */
export function exportYaml(deck: ExportDeck, cards: ExportCard[]): string {
  const out: string[] = ['reps: 1', ...metaLines(deck), `deck: ${dq(deck.name)}`];
  if (deck.tags.length > 0) {
    out.push(`tags: ${inlineList(deck.tags)}`);
  }
  out.push('cards:');
  for (const c of cards) {
    out.push(`  - id: ${cardIdOf(deck.uuid, c.uuid)}`);
    out.push(`    type: ${typeWord(c.type)}`);
    if (c.title.length > 0 && c.title !== fallbackTitle(c.front)) {
      out.push(...textField('title', c.title, 4));
    }
    out.push(...textField('front', c.front, 4));
    if (c.type === (NoteType.Choice as number)) {
      const opts: string[] = c.options.map((o: string) => optionText(o));
      // 选项长(中文 20 个字就很宽了)或者合起来一行放不下:一行一个,方便人读和改
      const total: number = opts.reduce((n: number, o: string) => n + o.length + 4, 0);
      const long = total > 60 || opts.some((o: string) => o.length > 20);
      if (long) {
        out.push('    options:');
        for (const o of opts) {
          out.push(`      - ${dq(o)}`);
        }
      } else {
        out.push(`    options: ${inlineList(opts)}`);
      }
      const letters: string[] = c.answer.split('');
      out.push(letters.length === 1 ? `    answer: ${letters[0]}` : `    answer: [${letters.join(', ')}]`);
    }
    if (c.back.length > 0) {
      out.push(...textField('back', c.back, 4));
    }
    if (c.tags.length > 0) {
      out.push(`    tags: ${inlineList(c.tags)}`);
    }
    out.push('');
  }
  return out.join('\n');
}
