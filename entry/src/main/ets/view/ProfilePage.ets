/**
 * 我的:一个菜单,不在根页面铺开任何设置。
 *
 * 根页面只有入口行(账号、排期算法、集合参数、导入格式、语言)加一个开关;
 * 每个入口点进去是一个独立子页,左上 `‹` 返回。副标题直接显示当前值,
 * 所以不展开也看得到设置内容。
 *
 * 数字类设置(复习上限、新卡额度、目标保持率、学习更多批量)用系统滚轮
 * TextPickerDialog。**不用「点一下换下一档」** —— 档位粗了拿不到 75 这种值,
 * 档位细了从 5 点到 100 要点二十下。滚轮是 ArkUI 自带的原生组件(和 DatePicker
 * 同一族),我们只提供一个 string[] 和选中下标,滑动/惯性/无障碍都由系统负责,
 * 所以它其实比自己写换档逻辑的代码更少。
 *
 * 选项类设置(排期算法、语言)只有两三个选项,继续用带 ✓ 的列表,不上滚轮。
 *
 * 所有设置写进 preferences 并立刻生效。改完一律调 appStore().bump(),
 * 否则别的页面不会重算 —— UI 只认 @State / @StorageLink。
 */

import {
  AHEAD_STEPS, SK_BACK_REQ, SK_CAN_BACK, SK_LANG, DEFAULT_AHEAD_COUNT, DEFAULT_NEW_PER_DAY, DEFAULT_RETENTION, DEFAULT_REVIEW_LIMIT, SK_TICK, appStore,
} from '../store/AppStore';
import { LIMIT_STEPS, NEW_STEPS, RETENTION_PCT, nearestStepIndex } from '../model/Steps';
import { getFsrsParams, setFsrsParams } from '../srs/Srs';
import { LoginPage } from './LoginPage';
import { L, LANG_EN, LANG_ZH, algoLabels, fmt } from '../i18n/Strings';

/** 根页面显示哪一层。0 是菜单本身 */
enum Sub {
  Root = 0,
  Algo = 1,
  SetParams = 2,
  Format = 3,
  Language = 4,
}

/** 四个走滚轮的数字设置 */
enum NumKey {
  ReviewLimit = 0,
  NewPerDay = 1,
  Retention = 2,
  Ahead = 3,
}

@Component
export struct ProfilePage {
  /**
   * **@Watch 是必须的。** ArkUI 里 @StorageLink 的变化只触发重绘,
   * 不会自动调用 on<字段名>Change() —— 少了这个装饰器,界面会用旧值重绘,
   * 看起来像「切换了卡组但标题没变」。
   */
  @StorageLink(SK_TICK) @Watch('onTickChange') tick: number = 0;

  @State private algo: string = 'fsrs';
  @State private reviewLimit: number = DEFAULT_REVIEW_LIMIT;
  @State private newPerDay: number = DEFAULT_NEW_PER_DAY;
  @State private retention: number = DEFAULT_RETENTION;
  @State private aheadCount: number = DEFAULT_AHEAD_COUNT;
  @State private accountName: string = '';
  @State private autoNext: boolean = true;
  /** true 时显示登录页而不是设置列表 */
  @State private showLogin: boolean = false;
  /** 当前在哪一层子页 */
  @State private sub: Sub = Sub.Root;
  /**
   * 语言。**必须从 AppStorage 读** —— 直接读 appStore().lang 的话,
   * 切换之后这一节不会重绘(WordSnap 上就是这么翻车的)。
   */
  @StorageLink(SK_LANG) lang: string = LANG_ZH;
  @StorageLink(SK_CAN_BACK) canBack: boolean = false;
  @StorageLink(SK_BACK_REQ) @Watch('onBackReq') backReq: number = 0;
  @State private deckLabel: string = '全部卡组';

  aboutToAppear(): void {
    this.pull();
  }

  onTickChange(): void {
    this.pull();
  }

  /**
   * 系统返回 / 侧滑返回。一次只弹一层:先登录页,再子页。
   * 弹完要重算 canBack,否则 Index 会以为还能返回,系统返回就被吃掉、退不出应用。
   */
  onBackReq(): void {
    if (this.showLogin) {
      this.showLogin = false;
      this.pull();
    } else if (this.sub !== Sub.Root) {
      this.sub = Sub.Root;
    }
    this.syncCanBack();
  }

  private syncCanBack(): void {
    this.canBack = this.showLogin || this.sub !== Sub.Root;
  }

  private enter(where: Sub): void {
    this.sub = where;
    this.syncCanBack();
  }

  private pull(): void {
    const st = appStore();
    if (!st.isReady()) {
      return;
    }
    this.algo = st.algo;
    this.reviewLimit = st.reviewLimit;
    this.newPerDay = st.newPerDay;
    this.retention = st.retention;
    this.aheadCount = st.aheadCount;
    this.accountName = st.accountName;
    this.autoNext = st.autoNext;
    this.deckLabel = st.currentDeckId === 0
      ? '全部卡组' : st.getDb().deckName(st.currentDeckId);
  }

  private pickAlgo(which: number): void {
    appStore().setAlgo(which === 0 ? 'fsrs' : 'ebbinghaus');
    this.pull();
  }

  private toggleAutoNext(): void {
    appStore().setAutoNext(!this.autoNext);
    this.pull();
  }

  // ---------------- 滚轮 ----------------

  /** 某个数字设置的全部档位 */
  private steps(which: number): number[] {
    if (which === NumKey.ReviewLimit) {
      return LIMIT_STEPS;
    }
    if (which === NumKey.NewPerDay) {
      return NEW_STEPS;
    }
    if (which === NumKey.Retention) {
      return RETENTION_PCT;
    }
    return AHEAD_STEPS;
  }

  /** 当前值(保持率取百分比整数,和 RETENTION_PCT 对齐) */
  private currentNum(which: number): number {
    if (which === NumKey.ReviewLimit) {
      return this.reviewLimit;
    }
    if (which === NumKey.NewPerDay) {
      return this.newPerDay;
    }
    if (which === NumKey.Retention) {
      return Math.round(this.retention * 100);
    }
    return this.aheadCount;
  }

  /** 一档显示成什么 */
  private stepLabel(which: number, v: number): string {
    if (which === NumKey.ReviewLimit && v >= 9999) {
      return L(this.lang).unlimited;
    }
    if (which === NumKey.Retention) {
      return `${v}%`;
    }
    return `${v}`;
  }

  /** 当前值在档位里的下标。就近吸附的原因见 Steps.ets */
  private selectedIndex(which: number): number {
    return nearestStepIndex(this.steps(which), this.currentNum(which));
  }

  private applyNum(which: number, idx: number): void {
    const steps: number[] = this.steps(which);
    if (idx < 0 || idx >= steps.length) {
      return;
    }
    const v: number = steps[idx];
    const st = appStore();
    if (which === NumKey.ReviewLimit) {
      st.setReviewLimit(v);
    } else if (which === NumKey.NewPerDay) {
      st.setNewPerDay(v);
    } else if (which === NumKey.Retention) {
      const r: number = v / 100;
      st.setRetention(r);
      // 保持率是 FSRS 的参数,要同步进引擎才会影响间隔。
      // 用 clone() 改再写回,不要原地改 getFsrsParams() 返回的那个对象。
      const p = getFsrsParams().clone();
      p.desiredRetention = r;
      setFsrsParams(p);
    } else {
      st.setAheadCount(v);
    }
    this.pull();
  }

  private openPicker(which: number): void {
    const steps: number[] = this.steps(which);
    const range: string[] = [];
    for (let i = 0; i < steps.length; i++) {
      range.push(this.stepLabel(which, steps[i]));
    }
    TextPickerDialog.show({
      range: range,
      selected: this.selectedIndex(which),
      canLoop: false,
      onAccept: (r: TextPickerResult) => {
        // index 的类型是 number | number[](多列滚轮时是数组),这里只有一列
        const raw: number | number[] = r.index;
        const idx: number = typeof raw === 'number' ? raw : raw[0];
        this.applyNum(which, idx);
      },
    });
  }

  // ---------------- 行与子页 ----------------

  /**
   * 入口行。**只接常量下标** —— 标题和副标题都在内部从状态现算。
   * 带值参数的 @Builder 不会随状态刷新(这个坑在 CONTEXT.md 里记了五次)。
   */
  @Builder
  entryRow(section: number) {
    Row() {
      Column({ space: 3 }) {
        Text(this.entryTitle(section)).fontSize(15)
        Text(this.entrySummary(section)).fontSize(11).fontColor('#8A8A8E')
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)

      Text('›').fontSize(22).fontColor('#C2C8D2')
    }
    .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')
    .onClick(() => this.enter(section as Sub))
  }

  private entryTitle(section: number): string {
    if (section === Sub.Algo) {
      return L(this.lang).algoSection;
    }
    if (section === Sub.SetParams) {
      return L(this.lang).dailySection;
    }
    if (section === Sub.Format) {
      return L(this.lang).formatSection;
    }
    return L(this.lang).langSection;
  }

  /** 副标题 = 当前值,这样不展开也看得到 */
  private entrySummary(section: number): string {
    if (section === Sub.Algo) {
      const i: number = this.algo === 'fsrs' ? 0 : 1;
      return `${algoLabels(this.lang)[i]} · ${Math.round(this.retention * 100)}%`;
    }
    if (section === Sub.SetParams) {
      return fmt(L(this.lang).setSummary,
        this.reviewLimit >= 9999 ? L(this.lang).unlimited : `${this.reviewLimit}`,
        `${this.newPerDay}`, `${this.aheadCount}`);
    }
    if (section === Sub.Format) {
      return L(this.lang).formatValue;
    }
    return this.lang === LANG_EN ? L(this.lang).langEnglish : L(this.lang).langChinese;
  }

  /** 子页标题栏。只接常量下标 */
  @Builder
  subHeader(section: number) {
    Row({ space: 8 }) {
      Text('‹').fontSize(28).fontColor('#1B2333')
        .onClick(() => this.enter(Sub.Root))
      Text(this.entryTitle(section)).fontSize(22).fontWeight(FontWeight.Bold)
        .layoutWeight(1)
    }
    .width('100%').margin({ top: 14, bottom: 4 })
  }

  /** 引擎选项。只接常量下标 */
  @Builder
  algoOption(which: number) {
    Row() {
      Column({ space: 3 }) {
        Text(algoLabels(this.lang)[which]).fontSize(15)
          .fontWeight(this.isPicked(which) ? FontWeight.Bold : FontWeight.Normal)
        Text(which === 0
          ? L(this.lang).algoFsrsHint
          : L(this.lang).algoEbbinghausHint)
          .fontSize(11).fontColor('#8A8A8E')
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)

      if (this.isPicked(which)) {
        Text('✓').fontSize(17).fontColor('#2E9E63')
      }
    }
    .width('100%').padding({ top: 10, bottom: 10 })
    .onClick(() => this.pickAlgo(which))
  }

  /**
   * 一行语言选项。**只接常量下标**,选中态与文案都在内部从状态里取 ——
   * 把 L() 的结果传进来会导致切换后不更新。
   */
  @Builder
  langOption(which: number) {
    Row() {
      Text(which === 0 ? L(this.lang).langChinese : L(this.lang).langEnglish)
        .fontSize(15).layoutWeight(1)
      if ((which === 0 && this.lang !== LANG_EN) || (which === 1 && this.lang === LANG_EN)) {
        Text('✓').fontSize(17).fontColor('#2E9E63')
      }
    }
    .width('100%').padding({ top: 10, bottom: 10 })
    .onClick(() => {
      appStore().setLanguage(which === 1 ? LANG_EN : LANG_ZH);
    })
  }

  private isPicked(which: number): boolean {
    return (which === 0 && this.algo === 'fsrs') || (which === 1 && this.algo === 'ebbinghaus');
  }

  /** 一行数字设置,点开滚轮。只接常量下标 */
  @Builder
  numRow(which: number) {
    Row() {
      Column({ space: 3 }) {
        Text(which === NumKey.ReviewLimit ? L(this.lang).reviewLimit
          : which === NumKey.NewPerDay ? L(this.lang).newPerDay
          : which === NumKey.Retention ? L(this.lang).retention
          : L(this.lang).aheadCount)
          .fontSize(15)
        Text(which === NumKey.ReviewLimit ? L(this.lang).reviewLimitHint
          : which === NumKey.NewPerDay ? L(this.lang).newPerDayHint
          : which === NumKey.Retention ? L(this.lang).retentionHint
          : L(this.lang).aheadCountHint)
          .fontSize(11).fontColor('#8A8A8E')
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)

      Text(this.stepLabel(which, this.currentNum(which)))
        .fontSize(15).fontColor('#4A90D9').fontWeight(FontWeight.Medium)
      Text('›').fontSize(18).fontColor('#C2C8D2').margin({ left: 6 })
    }
    .width('100%').padding({ top: 12, bottom: 12 })
    .onClick(() => this.openPicker(which))
  }

  /**
   * **Scroll 必须写在 build() 里,不能整个搬进 @Builder。**
   * 实测:搬进去之后内容照样渲染,却再也滚不动 —— 语言、导入格式几节永远划不到,
   * 而且没有任何报错。只让 @Builder 提供 Scroll 的孩子就没事。
   */
  build() {
    if (this.showLogin) {
      LoginPage({ onBack: () => {
        this.showLogin = false;
        this.pull();
        this.syncCanBack();
      } })
    } else {
      Scroll() {
        this.currentBody()
      }
      .width('100%').height('100%').backgroundColor('#FFFFFF')
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  /** 按当前层给出 Scroll 的孩子 */
  @Builder
  currentBody() {
    if (this.sub === Sub.Algo) {
      this.algoBody()
    } else if (this.sub === Sub.SetParams) {
      this.setBody()
    } else if (this.sub === Sub.Format) {
      this.formatBody()
    } else if (this.sub === Sub.Language) {
      this.langBody()
    } else {
      this.menuBody()
    }
  }

  /** 根菜单 */
  @Builder
  menuBody() {
    Column({ space: 12 }) {
      Text(L(this.lang).meTitle).fontSize(24).fontWeight(FontWeight.Bold)
        .width('100%').margin({ top: 14 })

      // ---- 账号 ----
      Row() {
        Column({ space: 3 }) {
          Text(this.accountName.length > 0 ? this.accountName : L(this.lang).notSignedIn)
            .fontSize(16).fontWeight(FontWeight.Medium)
          Text(this.accountName.length > 0
            ? L(this.lang).accountLocalHint
            : L(this.lang).loginReadyHint)
            .fontSize(11).fontColor('#8A8A8E')
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text('›').fontSize(22).fontColor('#C2C8D2')
      }
      .width('100%').padding(14).borderRadius(12).backgroundColor('#F5F5F7')
      .onClick(() => {
        this.showLogin = true;
        this.syncCanBack();
      })

      // ---- 当前卡组 ----
      Column({ space: 4 }) {
        Text(L(this.lang).currentStudy).fontSize(12).fontColor('#8A8A8E').width('100%')
        Text(this.deckLabel).fontSize(16).fontWeight(FontWeight.Medium).width('100%')
      }
      .width('100%').padding(14).borderRadius(12).backgroundColor('#F5F5F7')
      .alignItems(HorizontalAlign.Start)

      this.entryRow(Sub.Algo)
      this.entryRow(Sub.SetParams)
      this.entryRow(Sub.Format)
      this.entryRow(Sub.Language)

      // ---- 作答:单个开关,没必要再点进一层 ----
      Column({ space: 2 }) {
        Text(L(this.lang).autoNextLabel).fontSize(13).fontColor('#8A8A8E')
          .width('100%').margin({ bottom: 4 })
        Row() {
          Column({ space: 3 }) {
            Text(this.autoNext ? L(this.lang).autoNextOn : L(this.lang).autoNextOff)
              .fontSize(15)
            Text(L(this.lang).autoNextHint).fontSize(11).fontColor('#8A8A8E')
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.autoNext })
            .onChange(() => this.toggleAutoNext())
        }
        .width('100%').padding({ top: 10, bottom: 10 })
      }
      .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')

      // ---- 关于 ----
      Column({ space: 4 }) {
        Text(L(this.lang).aboutSection).fontSize(13).fontColor('#8A8A8E').width('100%')
        Text(L(this.lang).appName).fontSize(15).width('100%')
        Text(L(this.lang).aboutTagline).fontSize(11)
          .fontColor('#8A8A8E').width('100%')
        Text(L(this.lang).aboutLocal)
          .fontSize(11).fontColor('#8A8A8E').width('100%')
      }
      .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')
      .alignItems(HorizontalAlign.Start)
    }
    .width('90%').padding({ bottom: 20 })
    .constraintSize({ minHeight: '100%' })
  }

  /** 排期算法子页:引擎二选一 + 目标保持率(它是 FSRS 的参数,归这里) */
  @Builder
  algoBody() {
    Column({ space: 12 }) {
      this.subHeader(Sub.Algo)

      Column({ space: 2 }) {
        this.algoOption(0)
        Divider()
        this.algoOption(1)
        Text(L(this.lang).algoHint)
          .fontSize(11).fontColor('#B0B7C3').width('100%').margin({ top: 6 })
      }
      .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')

      Column({ space: 2 }) {
        this.numRow(NumKey.Retention)
      }
      .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')
    }
    .width('90%').padding({ bottom: 20 })
    .constraintSize({ minHeight: '100%' })
  }

  /** 集合参数子页:今日这一批卡有多大 */
  @Builder
  setBody() {
    Column({ space: 12 }) {
      this.subHeader(Sub.SetParams)

      Column({ space: 2 }) {
        this.numRow(NumKey.ReviewLimit)
        Divider().color('#E5E5EA')
        this.numRow(NumKey.NewPerDay)
        Divider().color('#E5E5EA')
        this.numRow(NumKey.Ahead)
        Text(L(this.lang).dailyHint)
          .fontSize(11).fontColor('#B0B7C3').width('100%').margin({ top: 6 })
      }
      .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')
    }
    .width('90%').padding({ bottom: 20 })
    .constraintSize({ minHeight: '100%' })
  }

  /** 导入格式子页:纯说明 */
  @Builder
  formatBody() {
    Column({ space: 12 }) {
      this.subHeader(Sub.Format)

      Column({ space: 6 }) {
        Text(L(this.lang).formatValue).fontSize(15).width('100%')
        Text(L(this.lang).formatDispatch)
          .fontSize(11).fontColor('#8A8A8E').width('100%')
        Divider().color('#E5E5EA').margin({ top: 4, bottom: 4 })
        Text(L(this.lang).formatMarkdown)
          .fontSize(11).fontColor('#8A8A8E').width('100%')
        Text(L(this.lang).formatYaml)
          .fontSize(11).fontColor('#8A8A8E').width('100%')
        Text(L(this.lang).formatAnki)
          .fontSize(11).fontColor('#B0B7C3').width('100%')
      }
      .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')
      .alignItems(HorizontalAlign.Start)
    }
    .width('90%').padding({ bottom: 20 })
    .constraintSize({ minHeight: '100%' })
  }

  /** 语言子页:两个选项,不上滚轮 */
  @Builder
  langBody() {
    Column({ space: 12 }) {
      this.subHeader(Sub.Language)

      Column({ space: 2 }) {
        this.langOption(0)
        Divider()
        this.langOption(1)
        Text(L(this.lang).langHint)
          .fontSize(11).fontColor('#B0B7C3').width('100%').margin({ top: 6 })
      }
      .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')
    }
    .width('90%').padding({ bottom: 20 })
    .constraintSize({ minHeight: '100%' })
  }
}
