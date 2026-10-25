/**
 * 牌组发布工具(Task 14)。**只有开发者自己用**:审核过的社区牌组 / 官方牌组 → 云存储 public/。
 *
 * 用法(Windows 的 node,与桌面测试一样借 DevEco 自带的;先跑一次 devtest/sync-and-test.mjs 生成解析器副本):
 *
 *   npx tsx tools/publish/publish.ts check   <牌组.yaml>
 *   npx tsx tools/publish/publish.ts publish <牌组.yaml> [--official] [--allow-duplicate] [--upload]
 *
 * check   只检查:能不能导入、meta 必填项、与已发布牌组的重复度(≥80% 相同的卡算疑似重复)。
 * publish 检查通过后,把文件与新的 catalog.json 写进本地镜像目录 tools/publish/mirror/,
 *         并列出要执行的 agcli 上传命令。**默认不上传**;加 --upload 才真正调用 agcli 改云端。
 *
 * 本地镜像就是「已发布」的事实来源(判重、版本号都看它),所以发布只在这一台电脑上做。
 */
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ParsedDeck } from '../../devtest/Quizify';
import {
  Catalog, catalogEntryOf, cloudPathOf, findDuplicates, parseForPublish, publishProblems, upsertCatalog,
} from './lib';

const here = dirname(fileURLToPath(import.meta.url));
const MIRROR = join(here, 'mirror');
const CATALOG = join(MIRROR, 'catalog.json');

function loadCatalog(): Catalog {
  return existsSync(CATALOG) ? JSON.parse(readFileSync(CATALOG, 'utf8')) as Catalog : { updatedAt: 0, decks: [] };
}

/** 镜像里每副已发布牌组的最新版本 */
function loadPublished(cat: Catalog): Map<string, ParsedDeck> {
  const out = new Map<string, ParsedDeck>();
  for (const e of cat.decks) {
    const p = join(MIRROR, e.path);
    if (existsSync(p)) {
      out.set(e.id, parseForPublish(readFileSync(p, 'utf8')));
    }
  }
  return out;
}

function fail(msg: string): never {
  console.error(`\n✗ ${msg}`);
  process.exit(1);
}

function main(): void {
  const [cmd, file, ...flags] = process.argv.slice(2);
  if ((cmd !== 'check' && cmd !== 'publish') || file === undefined) {
    fail('用法: publish.ts check|publish <牌组.yaml> [--official] [--allow-duplicate] [--upload]');
  }
  const text = readFileSync(file, 'utf8');
  let deck: ParsedDeck;
  try {
    deck = parseForPublish(text);
  } catch (e) {
    fail(`App 导入不了这个文件: ${e instanceof Error ? e.message : e}`);
  }
  console.log(`牌组「${deck.deck}」 ${deck.cards.length} 张卡  meta.id=${deck.meta.id}  v${deck.meta.version}`);

  const problems = publishProblems(deck);
  for (const p of problems) {
    console.log(`  ✗ ${p}`);
  }
  const cat = loadCatalog();
  const dups = findDuplicates(deck, loadPublished(cat));
  for (const d of dups) {
    console.log(`  ⚠ 疑似重复:${Math.round(d.ratio * 100)}% 的卡与已发布的「${d.name}」(${d.id})相同`);
  }
  if (problems.length > 0) {
    fail('有必须修的问题,不能发布');
  }
  if (cmd === 'check') {
    console.log(dups.length === 0 ? '\n✓ 可以发布' : '\n⚠ 格式没问题,但疑似重复,发布时要加 --allow-duplicate');
    return;
  }
  if (dups.length > 0 && !flags.includes('--allow-duplicate')) {
    fail('疑似重复。确认不是重复之后加 --allow-duplicate');
  }

  const now = Date.now();
  const entry = catalogEntryOf(deck, text, flags.includes('--official'), now);
  let next: Catalog;
  try {
    next = upsertCatalog(cat, entry, now);
  } catch (e) {
    fail(e instanceof Error ? e.message : String(e));
  }
  const dest = join(MIRROR, cloudPathOf(entry.id, entry.version));
  mkdirSync(dirname(dest), { recursive: true });
  writeFileSync(dest, text, 'utf8');
  writeFileSync(CATALOG, JSON.stringify(next, null, 2) + '\n', 'utf8');
  console.log(`\n已写进本地镜像: ${dest}\n               ${CATALOG}`);
  console.log(`sha256 ${entry.sha256}  ${entry.bytes} 字节`);

  const uploads: [string, string][] = [[dest, entry.path], [CATALOG, 'public/catalog.json']];
  console.log('\n要执行的上传(会改云端):');
  for (const [local, remote] of uploads) {
    console.log(`  agcli storage upload --file "${local}" --destination ${remote}`);
  }
  if (!flags.includes('--upload')) {
    console.log('\n(没有 --upload,这次只写了本地镜像,没有动云端)');
    return;
  }
  for (const [local, remote] of uploads) {
    const r = spawnSync('agcli', ['storage', 'upload', '--file', local, '--destination', remote],
      { stdio: 'inherit', shell: true });
    if (r.status !== 0) {
      fail(`上传失败: ${remote}。本地镜像已更新,修好后重跑同一条命令即可(目录会再写一次)`);
    }
  }
  console.log(`\n✓ 已发布,镜像里共 ${readdirSync(join(MIRROR, 'public', 'decks')).length} 副牌组`);
}

main();
