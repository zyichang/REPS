/**
 * 拿真实语料压解析器。
 *
 * 用法:tsx devtest/parse_corpus.ts <目录> [...]
 *
 * 这不是断言测试,而是一把探照灯:把用户 PKB 里近两千张真卡全喂进去,
 * 看解析器在哪些文件上摔倒、摔在第几行、缺哪条语法。
 * 手写样例永远想不到真实文件里的花样。
 */

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { basename, extname, join, relative } from 'node:path';
import { ParsedDeck, QuizifyError, parseQuizify } from './Quizify';

function walk(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    if (name === '.git' || name === 'node_modules') {
      continue;
    }
    const p = join(dir, name);
    if (statSync(p).isDirectory()) {
      out.push(...walk(p));
    } else if (extname(p) === '.md') {
      out.push(p);
    }
  }
  return out;
}

const roots = process.argv.slice(2);
if (roots.length === 0) {
  console.error('用法: tsx devtest/parse_corpus.ts <目录> [...]');
  process.exit(2);
}

interface Failure {
  file: string;
  line: number;
  message: string;
}

let okFiles = 0;
let okCards = 0;
let skipped = 0;
let choiceCards = 0;
let qaCards = 0;
/** 正面里还残留 ;;; 的卡 —— 一张都不该有,那等于把答案印在题面上 */
const leaks: string[] = [];
/** 是选择题但没取到答案字母的卡 */
const noAnswer: string[] = [];
const failures: Failure[] = [];
/** 出现过的语法特征 -> 文件数,用来看 Task 6 该补什么 */
const features = new Map<string, number>();

function bump(name: string): void {
  features.set(name, (features.get(name) ?? 0) + 1);
}

for (const root of roots) {
  for (const file of walk(root)) {
    const text = readFileSync(file, 'utf8');
    const rel = relative(root, file);

    // 没有 +++ 的文件不是卡组(简历、README 之类),不算失败
    if (!/^\+\+\+\s*$/m.test(text)) {
      skipped++;
      continue;
    }

    // 统计语法特征
    if (/^;;;/m.test(text)) { bump(';;; 选择题块'); }
    if (/\{\{[^}]+\}\}/.test(text)) { bump('{{挖空}} 完形填空'); }
    if (/\$\$[\s\S]*?\$\$/.test(text)) { bump('$$ 块级数学'); }
    if (/\$[^$\n]+\$/.test(text)) { bump('$…$ 行内数学'); }
    if (/^```/m.test(text)) { bump('``` 代码围栏'); }
    if (/\\$/m.test(text)) { bump('\\ 硬换行'); }
    if (/==[^=]+==/.test(text)) { bump('==高亮=='); }
    if (/\[\[[^\]]*\|\|[^\]]*\]\]/.test(text)) { bump('[[点击显示]]'); }
    if (/^:::/m.test(text)) { bump('::: 折叠块'); }
    if (!/^---/m.test(text.slice(0, 8))) { bump('(无 front matter,用文件名兜底)'); }
    if (/\^\([^)]*\)\^/.test(text)) { bump('^(行内注释)^'); }
    if (/[A-Za-z0-9]\^\d+\^/.test(text)) { bump('上标 X^2^'); }
    if (/~\d+~/.test(text)) { bump('下标 H~2~O'); }

    try {
      // 兜底卡组名取文件名,模拟真实导入流程
      const deck: ParsedDeck = parseQuizify(text, basename(file, '.md'));
      okFiles++;
      okCards += deck.cards.length;
      for (const c of deck.cards) {
        if (c.options.length > 0) {
          choiceCards++;
          if (c.answer.length === 0) {
            noAnswer.push(`${rel} :: ${c.key}`);
          }
        } else {
          qaCards++;
        }
        if (/^;;;/m.test(c.front)) {
          leaks.push(`${rel} :: ${c.key}`);
        }
      }
    } catch (e) {
      const line = e instanceof QuizifyError ? e.line : 0;
      const msg = e instanceof Error ? e.message : String(e);
      failures.push({ file: rel, line: line, message: msg });
    }
  }
}

console.log(`\n===== 解析结果 =====`);
console.log(`  成功  ${okFiles} 个文件,共 ${okCards} 张卡`);
console.log(`  失败  ${failures.length} 个文件`);
console.log(`  跳过  ${skipped} 个(没有 +++,不是卡组)`);

if (failures.length > 0) {
  // 按报错类型归并,便于看出「是同一个问题重复出现」还是「各不相同」
  const byKind = new Map<string, Failure[]>();
  for (const f of failures) {
    // 去掉行号前缀与引号内容,只留错误种类
    const kind = f.message.replace(/^第 \d+ 行: /, '').replace(/「[^」]*」/g, '「…」')
      .replace(/\d+/g, 'N');
    const arr = byKind.get(kind) ?? [];
    arr.push(f);
    byKind.set(kind, arr);
  }
  console.log(`\n===== 失败归类(${byKind.size} 种) =====`);
  const kinds = Array.from(byKind.entries()).sort((a, b) => b[1].length - a[1].length);
  for (const [kind, arr] of kinds) {
    console.log(`\n  [${arr.length} 个文件] ${kind}`);
    for (const f of arr.slice(0, 4)) {
      console.log(`      ${f.file}:${f.line}`);
    }
    if (arr.length > 4) {
      console.log(`      … 另外 ${arr.length - 4} 个`);
    }
  }
}

console.log(`\n===== 卡片类型 =====`);
console.log(`  选择题 ${choiceCards} 张,问答 ${qaCards} 张`);

console.log(`\n===== 安全检查:答案有没有泄露到正面 =====`);
if (leaks.length === 0) {
  console.log(`  PASS  ${okCards} 张卡的正面都不含 ;;;`);
} else {
  console.log(`  FAIL  ${leaks.length} 张卡的正面仍含 ;;;`);
  for (const l of leaks.slice(0, 5)) { console.log(`      ${l}`); }
}
if (noAnswer.length > 0) {
  console.log(`  注意  ${noAnswer.length} 张选择题没取到答案字母(收尾行可能是光秃秃的 ;;;)`);
  for (const l of noAnswer.slice(0, 5)) { console.log(`      ${l}`); }
}

console.log(`\n===== 真实语料里出现的语法特征 =====`);
const feats = Array.from(features.entries()).sort((a, b) => b[1] - a[1]);
for (const [name, n] of feats) {
  console.log(`  ${String(n).padStart(3)} 个文件  ${name}`);
}
