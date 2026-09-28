/**
 * 导入:让用户选一个 .md 文件,解析成卡片落库。
 *
 * 这一层碰运行时(文件选择器、文件读取),所以逻辑尽量少 ——
 * 解析规则全在 Quizify.ets,SQL 全在 Schema.ets,两者都有桌面测试覆盖。
 */

import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Database } from './Database';
import { ParsedCard, ParsedDeck, QuizifyError, parseOneCard, parseQuizify } from './Quizify';
import { parseYamlDeck } from './Yaml';

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

const DOMAIN: number = 0x0A01;
const TAG: string = 'REPS-Import';

/** 一次导入的结果,给界面显示 */
export interface ImportResult {
  ok: boolean;
  /** 文件名(不含扩展名),失败时也要有,便于提示 */
  name: string;
  deck: string;
  cardsAdded: number;
  /** 文件里原本没有 front matter,卡组名是用文件名兜底的 */
  usedFallbackDeck: boolean;
  /** 失败原因,ok 为 true 时是空串 */
  error: string;
}

/**
 * 弹出系统文档选择器,返回用户选中的文件 uri。
 * 用户取消时返回空串。
 */
export async function pickDeckFile(context: common.UIAbilityContext): Promise<string> {
  const options = new picker.DocumentSelectOptions();
  options.maxSelectNumber = 1;
  // 过滤器带上 .md 与 .markdown;有些设备上过滤器为空才显示全部文件
  options.fileSuffixFilters = ['.md', '.markdown', '.yaml', '.yml'];

  const viewPicker = new picker.DocumentViewPicker(context);
  const uris: string[] = await viewPicker.select(options);
  if (uris === undefined || uris.length === 0) {
    return '';
  }
  return uris[0];
}

/** 扩展名是不是 YAML。大小写不敏感,查询串先切掉 */
export function isYamlName(uriOrName: string): boolean {
  let s = uriOrName.toLowerCase();
  const q = s.indexOf('?');
  if (q >= 0) {
    s = s.substring(0, q);
  }
  return s.endsWith('.yaml') || s.endsWith('.yml');
}

/** 按 uri 读出整个文件的文本。假定 UTF-8 —— Quizify 规范就要求 UTF-8 */
export function readTextByUri(uri: string): string {
  const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
  try {
    const size: number = fileIo.statSync(file.fd).size;
    if (size === 0) {
      return '';
    }
    const buf = new ArrayBuffer(size);
    const read: number = fileIo.readSync(file.fd, buf);
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(buf.slice(0, read)));
  } finally {
    fileIo.closeSync(file);
  }
}

/**
 * 从 uri 里取出不含扩展名的文件名,用作缺 front matter 时的兜底卡组名。
 * uri 形如 `file://docs/storage/Users/currentUser/Documents/1_1.md`。
 */
export function deckNameFromUri(uri: string): string {
  const slash = uri.lastIndexOf('/');
  let name = slash >= 0 ? uri.substring(slash + 1) : uri;
  const dot = name.lastIndexOf('.');
  if (dot > 0) {
    name = name.substring(0, dot);
  }
  return name;
}

/**
 * 把一份已解析的卡组写进数据库。
 *
 * 一个文件一个卡组,名字就是 front matter 里的 deck ——
 * 卡组是平的,没有层级(见 Schema 里 decks 的注释)。
 * 已存在的指纹直接跳过 —— Task 7 会把「跳过」升级成「保留排期、更新内容」。
 */
export function storeDeck(db: Database, parsed: ParsedDeck, sourceFile: string,
                          now: number): number {
  const deckId: number = db.ensureDeck(parsed.deck);

  let added = 0;
  for (const c of parsed.cards) {
    // **导入进来一张,落库就是一张。**挖空数不再决定卡片数(ADR-0002):
    // 想让一句话产出多张卡,在源文件里自己写多张。
    const ids: number[] = db.insertNote(deckId, parsed.deck, c.type, c.front, c.back,
      c.title, c.key, c.options, c.answer, sourceFile, 1, now);
    added += ids.length;
  }
  return added;
}

/** 选文件 → 读 → 解析 → 落库。任何一步失败都返回 ok=false 而不抛异常 */
export async function importFromPicker(context: common.UIAbilityContext,
                                       db: Database): Promise<ImportResult> {
  let uri = '';
  try {
    uri = await pickDeckFile(context);
  } catch (e) {
    return fail('', m(`打开文件选择器失败: ${e}`, `Could not open the file picker: ${e}`));
  }
  if (uri.length === 0) {
    return fail('', m('已取消', 'Cancelled'));
  }

  const name: string = deckNameFromUri(uri);

  let text = '';
  try {
    text = readTextByUri(uri);
  } catch (e) {
    return fail(name, m(`读文件失败: ${e}`, `Could not read the file: ${e}`));
  }
  if (text.length === 0) {
    return fail(name, m('文件是空的', 'The file is empty'));
  }

  let parsed: ParsedDeck;
  try {
    // 按扩展名分派。两条路都产出 ParsedDeck —— YAML 那条先转成
    // Quizify 文本,所以题型判定与 Markdown 完全一致(见 Yaml.ets)。
    parsed = isYamlName(uri) ? parseYamlDeck(text) : parseQuizify(text, name);
  } catch (e) {
    const msg = e instanceof QuizifyError ? e.message : String(e);
    return fail(name, msg);
  }

  try {
    const added: number = storeDeck(db, parsed, name, Date.now());
    hilog.info(DOMAIN, TAG, '导入 %{public}s: %{public}d 张卡', parsed.deck, added);
    return {
      ok: true, name: name, deck: parsed.deck, cardsAdded: added,
      usedFallbackDeck: !parsed.hadFrontMatter, error: '',
    };
  } catch (e) {
    return fail(name, m(`写入数据库失败: ${e}`, `Could not write to the database: ${e}`));
  }
}

function fail(name: string, error: string): ImportResult {
  return { ok: false, name: name, deck: '', cardsAdded: 0, usedFallbackDeck: false, error: error };
}
