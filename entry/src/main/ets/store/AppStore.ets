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
import { getFsrsParams, setAlgorithm, setFsrsParams } from '../srs/Srs';

const DOMAIN: number = 0x0A01;
const TAG: string = 'REPS-Store';
const PREF_NAME: string = 'reps_settings';

/** 设置项的 key。带 _<deck> 后缀的是按卡组独立的 */
const K_ALGO: string = 'algo';
const K_REVIEW_LIMIT: string = 'review_limit';
const K_NEW_PER_DAY: string = 'new_per_day';
const K_RETENTION: string = 'target_retention';
const K_CURRENT_DECK: string = 'current_deck_id';

/** 默认值 */
export const DEFAULT_REVIEW_LIMIT: number = 200;
export const DEFAULT_NEW_PER_DAY: number = 20;
export const DEFAULT_RETENTION: number = 0.9;

/** 引擎显示名,下标对应 0=fsrs / 1=ebbinghaus */
export const ALGO_LABEL: string[] = ['FSRS-6', '艾宾浩斯固定阶梯'];

/** AppStorage 里的 key,UI 靠它们刷新 —— @StorageLink 才会驱动重绘 */
export const SK_TICK: string = 'reps_tick';
export const SK_DECK_NAME: string = 'reps_deck_name';

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
