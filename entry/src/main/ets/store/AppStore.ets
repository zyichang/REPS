/**
 * 全局状态:数据库连接 + 用户设置。
 *
 * 四个标签页共用同一个 Database 实例 —— 各自 new 一个会开出多个连接,
 * 一个页面写入之后另一个页面读到旧数据。
 *
 * 设置落在 preferences 里。注意一条纪律(WordSnap 的教训):
 * **凡是「今天还剩多少」这类按卡组计的额度,key 必须带卡组名。**
 * WordSnap 曾把追加额度存成全局 key,结果在 A 书点一次「学习更多」,
 * B 书也凭空多出额度。
 *
 * 另一条:preferences 在启动时读一次就缓存在内存里。想从外部改它,
 * 必须先停掉应用,否则会被内存里的旧值覆盖回去。
 */

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Database } from '../data/Database';
import { LANG_EN, LANG_ZH, algoLabels, intervalUnits } from '../i18n/Strings';
import { getFsrsParams, setAlgorithm, setFsrsParams, setIntervalUnits } from '../srs/Srs';
import { setMessageLang as setQuizifyLang } from '../data/Quizify';
import { setMessageLang as setYamlLang } from '../data/Yaml';
import { setMessageLang as setImporterLang } from '../data/Importer';

const DOMAIN: number = 0x0A01;
const TAG: string = 'REPS-Store';
const PREF_NAME: string = 'reps_settings';

/** 设置项的 key。带 _<deck> 后缀的是按卡组独立的 */
const K_ALGO: string = 'algo';
const K_REVIEW_LIMIT: string = 'review_limit';
const K_NEW_PER_DAY: string = 'new_per_day';
const K_RETENTION: string = 'target_retention';
const K_CURRENT_DECK: string = 'current_deck_id';
const K_AHEAD_COUNT: string = 'ahead_count';
/** **只存显示用的账号名,永远不存密码。** 见 LoginPage 的注释 */
const K_ACCOUNT_NAME: string = 'account_name';
const K_LANG: string = 'lang';
const K_AUTO_NEXT: string = 'auto_next';

/** 默认值 */
export const DEFAULT_REVIEW_LIMIT: number = 200;
export const DEFAULT_NEW_PER_DAY: number = 20;
export const DEFAULT_RETENTION: number = 0.9;
/**
 * 「学习更多」一次提前拿多少张。
 *
 * 注意这是「每次拿几张」,**不是累加的额度**。WordSnap 当年把追加额度
 * 持久化成一个全局 key,结果在 A 书点一次、B 书也凭空多出额度
 * (见 CONTEXT.md 经验 6)。这里每次都从该卡组自己的到期表里现算,
 * 不存任何计数器,所以结构上不可能串组。
 */
export const DEFAULT_AHEAD_COUNT: number = 20;
/** 可选档位,点一行换下一档 */
export const AHEAD_STEPS: number[] = [5, 10, 20, 40, 80];

/** 引擎显示名,下标对应 0=fsrs / 1=ebbinghaus */
// 引擎显示名改为跟随语言,见 i18n/algoLabels()

/** AppStorage 里的 key,UI 靠它们刷新 —— @StorageLink 才会驱动重绘 */
export const SK_TICK: string = 'reps_tick';
export const SK_DECK_NAME: string = 'reps_deck_name';
/**
 * 请求切到某个标签页。学习页的「change」按钮写它,Index 监听后翻页 ——
 * 比在学习页里再复制一份卡组选择器可靠。
 */
export const SK_GOTO_TAB: string = 'reps_goto_tab';
/**
 * 当前语言。**必须放进 AppStorage** —— 界面要跟着切换,就只能读可观察状态;
 * 直接读 appStore().lang 的组件不会重绘(见 i18n/Strings.ets 的说明)。
 */
export const SK_LANG: string = 'reps_lang';
/**
 * 当前标签页还能不能再返回一级。有内部层级的页面负责写它。
 * Index 的 onBackPress 读它来决定:拦下这次返回,还是让系统退出应用。
 */
 /**
 * 是否处于沉浸状态(正在一轮学习里)。为真时 Index 隐藏标签栏 ——
 * 做卡的时候不该还能一键跳去别的页面,那既打断节奏,也会让计时变得没有意义。
 */
export const SK_IMMERSIVE: string = 'reps_immersive';
export const SK_CAN_BACK: string = 'reps_can_back';
/**
 * 返回请求计数器。Index 每次拦下返回就 +1,有层级的页面 @Watch 它并弹一级。
 * 用计数器而不是布尔,是因为连续按两次返回要能触发两次。
 */
export const SK_BACK_REQ: string = 'reps_back_req';

class Store {
  private db: Database = new Database();
  private prefs: preferences.Preferences | null = null;
  private ready: boolean = false;

  /** 当前算法,'fsrs' | 'ebbinghaus' */
  algo: string = 'fsrs';
  /** 每日复习硬上限 */
  reviewLimit: number = DEFAULT_REVIEW_LIMIT;
  /** 每日新卡额度 */
  newPerDay: number = DEFAULT_NEW_PER_DAY;
  /** 目标保持率 */
  retention: number = DEFAULT_RETENTION;
  /** 当前选中的卡组 id,0 表示「全部卡组」 */
  currentDeckId: number = 0;
  /** 「学习更多」每次提前拿几张 */
  aheadCount: number = DEFAULT_AHEAD_COUNT;
  /** 显示用的账号名,空串表示未登录。**不是凭据** */
  accountName: string = '';
  /** 'zh' 或 'en'。真正驱动界面的是 AppStorage 里的 SK_LANG */
  lang: string = LANG_ZH;
  /** 答对之后自动进入下一张(否则停在解析界面等用户点「下一个」) */
  autoNext: boolean = true;

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.ready) {
      return;
    }
    await this.db.init(context);
    this.prefs = await preferences.getPreferences(context, PREF_NAME);
    this.load();
    this.ready = true;
    hilog.info(DOMAIN, TAG, '全局状态就绪, algo=%{public}s', this.algo);
  }

  isReady(): boolean {
    return this.ready;
  }

  getDb(): Database {
    return this.db;
  }

  private load(): void {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    this.algo = p.getSync(K_ALGO, 'fsrs') as string;
    this.reviewLimit = p.getSync(K_REVIEW_LIMIT, DEFAULT_REVIEW_LIMIT) as number;
    this.newPerDay = p.getSync(K_NEW_PER_DAY, DEFAULT_NEW_PER_DAY) as number;
    this.retention = p.getSync(K_RETENTION, DEFAULT_RETENTION) as number;
    this.currentDeckId = p.getSync(K_CURRENT_DECK, 0) as number;
    this.aheadCount = p.getSync(K_AHEAD_COUNT, DEFAULT_AHEAD_COUNT) as number;
    this.accountName = p.getSync(K_ACCOUNT_NAME, '') as string;
    this.lang = p.getSync(K_LANG, LANG_ZH) as string;
    // preferences 这一层只存字符串/数字,布尔用 1/0 表示
    this.autoNext = (p.getSync(K_AUTO_NEXT, 1) as number) !== 0;
    AppStorage.setOrCreate(SK_LANG, this.lang);
    this.applyUnits();
    // 引擎是模块级状态,读完设置要同步过去。
    // 漏了这一步的后果是:设置记在 preferences 里,重启后界面显示 95%,
    // 但引擎仍按默认 90% 算间隔 —— 设置看着生效了实际没有。
    setAlgorithm(this.algo === 'ebbinghaus' ? 'ebbinghaus' : 'fsrs');
    const fp = getFsrsParams().clone();
    fp.desiredRetention = this.retention;
    setFsrsParams(fp);
  }

  private put(key: string, value: string | number): void {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    p.putSync(key, value);
    p.flush();
  }

  setAlgo(a: string): void {
    this.algo = a === 'ebbinghaus' ? 'ebbinghaus' : 'fsrs';
    setAlgorithm(this.algo === 'ebbinghaus' ? 'ebbinghaus' : 'fsrs');
    this.put(K_ALGO, this.algo);
    this.bump();
  }

  setReviewLimit(n: number): void {
    this.reviewLimit = n < 0 ? 0 : n;
    this.put(K_REVIEW_LIMIT, this.reviewLimit);
    this.bump();
  }

  /** 「学习更多」每次提前拿几张。只是批量大小,不是累加额度 */
  setAheadCount(n: number): void {
    this.aheadCount = n < 1 ? 1 : n;
    this.put(K_AHEAD_COUNT, this.aheadCount);
    this.bump();
  }

  /**
   * 记住显示用的账号名。**不要在这里加密码参数** ——
   * 没有服务端的应用保存密码只有风险没有收益(见 LoginPage)。
   */
  setAccountName(name: string): void {
    this.accountName = name;
    this.put(K_ACCOUNT_NAME, name);
    this.bump();
  }

  /** 切语言。同时写 AppStorage,否则界面不会跟着变 */
  setLanguage(lang: string): void {
    this.lang = lang === LANG_EN ? LANG_EN : LANG_ZH;
    this.put(K_LANG, this.lang);
    AppStorage.setOrCreate(SK_LANG, this.lang);
    // **切语言时必须重新注入。** 只写 AppStorage 只够界面重绘,
    // 排期单位和解析器报错是注入式的,不跟着改就会中英混着出。
    this.applyUnits();
    this.bump();
  }

  /** 答对后的走法。答错永远停在解析界面,不受这个设置影响 */
  setAutoNext(on: boolean): void {
    this.autoNext = on;
    this.put(K_AUTO_NEXT, on ? 1 : 0);
    this.bump();
  }

  /**
   * 把间隔单位推给排期模块。Srs / Ebbinghaus 是纯逻辑、要在桌面跑测试,
   * 所以它们不 import i18n,而是由这里注入。
   */
  private applyUnits(): void {
    const u = intervalUnits(this.lang);
    setIntervalUnits(u.year, u.month, u.day, u.hour, u.minute);
    // 解析器与导入器的报错文案也要跟着切 —— 它们不 import i18n,只接注入
    setQuizifyLang(this.lang);
    setYamlLang(this.lang);
    setImporterLang(this.lang);
  }

  setNewPerDay(n: number): void {
    this.newPerDay = n < 0 ? 0 : n;
    this.put(K_NEW_PER_DAY, this.newPerDay);
    this.bump();
  }

  setRetention(r: number): void {
    this.retention = r;
    this.put(K_RETENTION, r);
    this.bump();
  }

  setCurrentDeck(id: number, name: string): void {
    this.currentDeckId = id;
    this.put(K_CURRENT_DECK, id);
    AppStorage.setOrCreate(SK_DECK_NAME, name);
    this.bump();
  }

  /**
   * 让所有页面重绘。
   *
   * UI 只能依赖 @State / @StorageLink,不能依赖 Store 的普通字段 ——
   * 改了普通字段界面不会动,而编译器一声不响。所以每次改设置都递增这个计数,
   * 各页面用 @StorageLink(SK_TICK) 监听它。
   */
  bump(): void {
    const n: number = (AppStorage.get<number>(SK_TICK) ?? 0) + 1;
    AppStorage.setOrCreate(SK_TICK, n);
  }
}

const INSTANCE: Store = new Store();

export function appStore(): Store {
  return INSTANCE;
}
