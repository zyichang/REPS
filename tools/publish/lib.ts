/**
 * 牌组发布工具的纯逻辑(Task 14)。CLI 在 publish.ts;桌面测试 devtest/publish_test.ts 直接测这里。
 *
 * 解析用的是**生产那份** Yaml.ets(经 devtest/sync-and-test.mjs 同步出的 Yaml.ts)——
 * 这里能通过的文件,App 一定能导入。
 */
import { createHash } from 'node:crypto';
import { ParsedCard, ParsedDeck } from '../../devtest/Quizify';
import { parseYamlDeck } from '../../devtest/Yaml';

/** catalog.json 里的一项(docs/data-model.md §5.1,App 的牌组广场读它) */
export interface CatalogEntry {
  id: string;
  name: string;
  version: number;
  author: string;
  description: string;
  language: string;
  license: string;
  source: string;
  generatedBy: string;
  cards: number;
  bytes: number;
  path: string;
  sha256: string;
  official: boolean;
  preview: string[];
  updatedAt: number;
}

export interface Catalog {
  updatedAt: number;
  decks: CatalogEntry[];
}

/** 发布前检查。返回问题列表,空 = 可以发布 */
export function publishProblems(deck: ParsedDeck): string[] {
  const out: string[] = [];
  const m = deck.meta;
  if (deck.format !== 1) {
    out.push('不是 REPS YAML v1(文件开头要有 reps: 1)。旧格式请先在 App 里导入再导出');
  }
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(m.id)) {
    out.push('meta.id 必须是一个 uuid(App 导出的文件里已经有)');
  }
  if (m.version < 1) {
    out.push('meta.version 必须是 >= 1 的整数');
  }
  if (m.author.trim().length === 0) {
    out.push('缺少 meta.author');
  }
  if (m.license.trim().length === 0) {
    out.push('缺少 meta.license(建议 CC-BY-4.0)');
  }
  if (m.description.trim().length === 0) {
    out.push('缺少 meta.description');
  }
  if (deck.cards.length === 0) {
    out.push('一张卡都没有');
  }
  if (deck.cards.some((c: ParsedCard) => c.id.length === 0)) {
    out.push('有卡片没有 id。请在 App 里导入后再导出,导出的文件每张卡都有 id');
  }
  return out;
}

/**
 * 判重用的卡片指纹:**规范化之后**的正面 + 选项 + 背面。
 * 去掉所有空白与标点、统一小写 —— 改几个空格、换个标点、改大小写都绕不过去。
 */
export function normalizedCardHash(c: ParsedCard): string {
  const norm = (s: string): string => s.toLowerCase().replace(/[\s\p{P}\p{S}]+/gu, '');
  const text = [norm(c.front), c.options.map((o) => norm(o.replace(/^[A-Z]\.\s?/, ''))).join('|'), norm(c.back)]
    .join('\u0000');
  return createHash('sha256').update(text).digest('hex').substring(0, 16);
}

export function deckHashes(deck: ParsedDeck): string[] {
  return deck.cards.map((c) => normalizedCardHash(c));
}

/** 新牌组有多少比例的卡已经出现在 other 里(0~1) */
export function overlapRatio(fresh: string[], other: string[]): number {
  if (fresh.length === 0) {
    return 0;
  }
  const set = new Set(other);
  let hit = 0;
  for (const h of fresh) {
    if (set.has(h)) {
      hit++;
    }
  }
  return hit / fresh.length;
}

/** 疑似重复的门槛:80% 的卡相同 */
export const DUPLICATE_THRESHOLD: number = 0.8;

export interface DuplicateHit {
  id: string;
  name: string;
  ratio: number;
}

/** 与已发布的每副牌组比(同一个 meta.id 的旧版本不算重复,那是更新) */
export function findDuplicates(deck: ParsedDeck, published: Map<string, ParsedDeck>): DuplicateHit[] {
  const mine = deckHashes(deck);
  const out: DuplicateHit[] = [];
  published.forEach((other: ParsedDeck, id: string) => {
    if (id === deck.meta.id) {
      return;
    }
    const r = overlapRatio(mine, deckHashes(other));
    if (r >= DUPLICATE_THRESHOLD) {
      out.push({ id: id, name: other.deck, ratio: r });
    }
  });
  return out;
}

export function sha256Of(text: string): string {
  return createHash('sha256').update(text, 'utf8').digest('hex');
}

/** 云存储里的路径 */
export function cloudPathOf(id: string, version: number): string {
  return `public/decks/${id}/v${version}.yaml`;
}

/** 前几张卡的正面,给牌组广场预览(去掉 Markdown 标题记号,截断) */
export function previewOf(deck: ParsedDeck, n: number = 3): string[] {
  return deck.cards.slice(0, n).map((c) => {
    const first = c.front.split('\n').find((l) => l.trim().length > 0) ?? '';
    const t = first.replace(/^#{1,6}\s+/, '').trim();
    return t.length > 60 ? `${t.substring(0, 60)}…` : t;
  });
}

export function catalogEntryOf(deck: ParsedDeck, text: string, official: boolean, now: number): CatalogEntry {
  const m = deck.meta;
  return {
    id: m.id, name: deck.deck, version: m.version, author: m.author, description: m.description,
    language: m.language, license: m.license, source: m.source, generatedBy: m.generatedBy,
    cards: deck.cards.length, bytes: Buffer.byteLength(text, 'utf8'), path: cloudPathOf(m.id, m.version),
    sha256: sha256Of(text), official: official, preview: previewOf(deck), updatedAt: now,
  };
}

/**
 * 把一副牌组放进目录:同一个 id 只保留最新版本;版本号必须比已发布的大。
 * 返回新目录(不改输入)。
 */
export function upsertCatalog(cat: Catalog, entry: CatalogEntry, now: number): Catalog {
  const prev = cat.decks.find((d) => d.id === entry.id);
  if (prev !== undefined && entry.version <= prev.version) {
    throw new Error(`「${entry.name}」已发布 v${prev.version},新版本号必须更大(现在是 v${entry.version})`);
  }
  const decks = cat.decks.filter((d) => d.id !== entry.id);
  decks.push(entry);
  decks.sort((a, b) => (a.official === b.official ? a.name.localeCompare(b.name) : (a.official ? -1 : 1)));
  return { updatedAt: now, decks: decks };
}

export function parseForPublish(text: string): ParsedDeck {
  return parseYamlDeck(text);
}
