/**
 * 格式指南的守卫:docs/yaml-guide.{zh,en}.md 里的每个 ```yaml 例子、
 * testdata/examples/example.{zh,en}.yaml 都必须能被生产解析器(Yaml.ets)解析。
 *
 * 文档是给用户和 AI 当模板抄的 —— 格式改了而文档没跟上,AI 会照着错的例子批量生成坏卡。
 * ADR-0001 的教训:文档里的例子必须真的能导入。
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { NoteType } from './Models';
import { ParsedDeck } from './Quizify';
import { parseYamlDeck } from './Yaml';
import { BlockKind, InlineKind, parseInline, splitBlocks } from './Inline';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail: string = ''): void {
  if (ok) {
    pass++;
    console.log(`  PASS  ${name}${detail ? '  ' + detail : ''}`);
  } else {
    fail++;
    console.log(`  FAIL  ${name}${detail ? '  ' + detail : ''}`);
  }
}

/** 取出文档里所有 ```yaml 块。外层围栏顶格;例子内部的 ``` 有缩进,不会被当成结束 */
function yamlBlocks(md: string): string[] {
  const out: string[] = [];
  let buf: string[] | null = null;
  for (const line of md.replace(/\r\n/g, '\n').split('\n')) {
    if (buf === null && line === '```yaml') {
      buf = [];
    } else if (buf !== null && line === '```') {
      out.push(buf.join('\n') + '\n');
      buf = null;
    } else if (buf !== null) {
      buf.push(line);
    }
  }
  return out;
}

function tryParse(text: string): ParsedDeck | string {
  try {
    return parseYamlDeck(text);
  } catch (e) {
    return e instanceof Error ? e.message : String(e);
  }
}

function typesOf(d: ParsedDeck): string {
  const n = (t: NoteType) => d.cards.filter((c) => c.type === t).length;
  return `qa ${n(NoteType.QA)} / choice ${n(NoteType.Choice)} / cloze ${n(NoteType.Cloze)}`;
}

for (const lang of ['zh', 'en']) {
  console.log(`\n=== docs/yaml-guide.${lang}.md ===`);
  const md = readFileSync(join(root, 'docs', `yaml-guide.${lang}.md`), 'utf8');
  const blocks = yamlBlocks(md);
  check(`${lang}:有 7 个 yaml 例子`, blocks.length === 7, `${blocks.length}`);
  let cards = 0;
  blocks.forEach((b, i) => {
    const r = tryParse(b);
    const ok = typeof r !== 'string';
    check(`${lang} 例子 ${i + 1} 能解析`, ok, ok ? `${(r as ParsedDeck).deck}:${typesOf(r as ParsedDeck)}` : r as string);
    if (ok) {
      cards += (r as ParsedDeck).cards.length;
    }
  });
  check(`${lang}:例子共 10 张卡`, cards === 10, `${cards}`);
  check(`${lang}:AI 提示词提到三种题型`, md.includes('type: qa') && md.includes('type: choice') && md.includes('type: cloze'));
  // 错误示例用 ```text,真要是写成 yaml 也必须解析失败
  check(`${lang}:错误示例不在 yaml 块里`, !blocks.some((b) => b.includes('answer: E')));
}

console.log('\n=== testdata/examples/example.{zh,en}.yaml ===');
const decks: ParsedDeck[] = [];
for (const lang of ['zh', 'en']) {
  const r = tryParse(readFileSync(join(root, 'testdata', 'examples', `example.${lang}.yaml`), 'utf8'));
  check(`example.${lang}.yaml 能解析`, typeof r !== 'string', typeof r === 'string' ? r : typesOf(r));
  if (typeof r === 'string') {
    continue;
  }
  decks.push(r);
  check(`${lang}:10 张卡,qa 5 / choice 3 / cloze 2`, typesOf(r) === 'qa 5 / choice 3 / cloze 2' && r.cards.length === 10);
  check(`${lang}:meta 齐全`, r.meta.version === 1 && r.meta.license === 'CC-BY-4.0' && r.meta.generatedBy === 'manual');
  const multi = r.cards.find((c) => c.id === 'ex-multi-1');
  check(`${lang}:多选答案 AC`, multi !== undefined && multi.answer === 'AC', multi?.answer);
  const cloze = r.cards.find((c) => c.id === 'ex-cloze-2');
  check(`${lang}:三空挖空`, cloze !== undefined && cloze.clozeCount === 3, `${cloze?.clozeCount}`);
  const code = r.cards.find((c) => c.id === 'ex-code-1');
  check(`${lang}:代码块里的 # 是内容,不是注释`, code !== undefined && code.back.includes('```python') && code.back.includes('#'));
  const style = r.cards.find((c) => c.id === 'ex-style-1');
  const blocksOfStyle = style === undefined ? [] : splitBlocks(style.back);
  const callouts = blocksOfStyle.filter((b) => b.kind === BlockKind.Callout).map((b) => b.lang).join(',');
  check(`${lang}:四个提示框都认出来`, callouts === 'note,important,warning,caution', callouts);
  const kinds = style === undefined ? [] : parseInline(blocksOfStyle[0].text).map((s) => s.kind);
  check(`${lang}:粗体、斜体、高亮、代码、上下标都认出来`,
    [InlineKind.Bold, InlineKind.Italic, InlineKind.Highlight, InlineKind.Code, InlineKind.Sup, InlineKind.Sub]
      .every((k) => kinds.includes(k)));
}
if (decks.length === 2) {
  check('中英两份示例的卡片 id 一一对应',
    decks[0].cards.map((c) => c.id).join(',') === decks[1].cards.map((c) => c.id).join(','));
}

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
process.exit(fail === 0 ? 0 : 1);
