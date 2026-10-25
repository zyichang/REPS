/**
 * 牌组发布工具(Task 14)的回归测试:发布检查、判重、目录更新。不碰云端。
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ParsedDeck } from './Quizify';
import { parseYamlDeck } from './Yaml';
import {
  Catalog, catalogEntryOf, cloudPathOf, findDuplicates, normalizedCardHash, overlapRatio, previewOf, publishProblems,
  sha256Of, upsertCatalog,
} from '../tools/publish/lib';

const here = dirname(fileURLToPath(import.meta.url));

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: string): void {
  if (ok) {
    pass++;
    console.log(`  PASS  ${name}${detail ? '  ' + detail : ''}`);
  } else {
    fail++;
    console.log(`  FAIL  ${name}${detail ? '  ' + detail : ''}`);
  }
}

const exText = readFileSync(join(here, '..', 'testdata', 'format-example.yaml'), 'utf8');
const ex: ParsedDeck = parseYamlDeck(exText);

console.log('=== 1. 发布检查 ===');
check('ADR 示例可以发布', publishProblems(ex).length === 0, publishProblems(ex).join(';'));
const bare = parseYamlDeck(`reps: 1\ndeck: 无信息\ncards:\n  - front: "甲"\n    back: "乙"\n`);
const ps = publishProblems(bare);
check('缺 meta.id / version / author / license / description、卡没有 id 都会报',
  ps.length === 6, ps.join(' | '));
const legacy = parseYamlDeck(`deck: 旧\ncards:\n  - front: "甲"\n    back: "乙"\n`);
check('旧格式不能发布', publishProblems(legacy).some((p) => p.includes('reps: 1')));

console.log('=== 2. 判重:改几个字绕不过去 ===');
const tweak = exText
  .replace('3b8e1f0a-2c4d-4e6f-8a1b-9c0d1e2f3a4b', '11111111-2222-4333-8444-555555555555')
  .replace('什么是机会成本?', '什么是 机会成本 ?!')
  .replace('"单调函数"', '"单调 函数"')
  .replace('deck: 格式示例', 'deck: 换了个名字');
const copy = parseYamlDeck(tweak);
const published = new Map<string, ParsedDeck>([[ex.meta.id, ex]]);
const dups = findDuplicates(copy, published);
check('加空格、加标点、改牌组名:仍判为重复', dups.length === 1 && dups[0].ratio === 1, JSON.stringify(dups));
check('同一个 meta.id 的新版本不算重复', findDuplicates(ex, published).length === 0);
const half = parseYamlDeck(`reps: 1\ndeck: 一半\ncards:\n  - id: a\n    front: "什么是机会成本?"\n    back: |\n      为了得到某种东西所必须放弃的东西。\n  - id: b\n    front: "全新的题"\n    back: "全新"\n`);
check('一半相同不到 80%:不算重复', findDuplicates(half, published).length === 0,
  `${overlapRatio(half.cards.map(normalizedCardHash), ex.cards.map(normalizedCardHash))}`);
check('真正改了内容的卡指纹不同', normalizedCardHash(ex.cards[0]) !== normalizedCardHash(half.cards[1]));

console.log('=== 3. 目录 ===');
const e1 = catalogEntryOf(ex, exText, true, 1000);
check('路径', e1.path === `public/decks/${ex.meta.id}/v1.yaml` && e1.path === cloudPathOf(ex.meta.id, 1));
check('sha256 是文件全文的', e1.sha256 === sha256Of(exText) && e1.sha256.length === 64);
check('字节数按 UTF-8', e1.bytes === Buffer.byteLength(exText, 'utf8'));
check('张数与预览', e1.cards === 4 && e1.preview.length === 3 && e1.preview[0] === '什么是机会成本?', e1.preview.join(' | '));
check('预览去掉标题记号', previewOf(parseYamlDeck(`reps: 1\ndeck: x\ncards:\n  - front: |\n      #### 标题\n      正文\n    back: "b"\n`))[0] === '标题');
let cat: Catalog = { updatedAt: 0, decks: [] };
cat = upsertCatalog(cat, e1, 1000);
check('加进目录', cat.decks.length === 1 && cat.updatedAt === 1000);
let threw = false;
try {
  upsertCatalog(cat, e1, 2000);
} catch {
  threw = true;
}
check('同版本号不能再发布', threw);
const v2text = exText.replace('version: 1', 'version: 2');
cat = upsertCatalog(cat, catalogEntryOf(parseYamlDeck(v2text), v2text, true, 3000), 3000);
check('新版本替换旧版本,目录里仍是一项', cat.decks.length === 1 && cat.decks[0].version === 2);
const commText = tweak;
cat = upsertCatalog(cat, catalogEntryOf(copy, commText, false, 4000), 4000);
check('官方牌组排在社区牌组前', cat.decks[0].official && !cat.decks[1].official);
check('目录 JSON 往返', JSON.stringify(JSON.parse(JSON.stringify(cat))) === JSON.stringify(cat));

console.log(`\n结果: ${pass} 通过, ${fail} 失败`);
process.exit(fail === 0 ? 0 : 1);
