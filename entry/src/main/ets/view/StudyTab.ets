/**
 * 学习标签页的根:Anki 式的**牌组列表**。
 *
 *   牌组列表 ──点一行──▶ 卡组概览(StudyPage 的落地页)──开始学习──▶ 作答
 *
 * 每个卡组各自一行,各自的 新 / 学习中 / 待复习,点进去只学这一组。
 * 没有「当前卡组」这回事 —— 想换就返回列表点另一行(ADR-0004)。
 *
 * 页面栈用 Navigation + NavPathStack(skill 的推荐写法):系统返回 / 侧滑由
 * Navigation 自己弹栈,不再走 Index 的返回计数器。
 *
 * ArkUI 铁律:列表行的 @Builder **只接常量下标**,内容从 @State 数组里取。
 *
 * 横屏平板(lg):Navigation 改成 Split —— 左边是「今日」+ 牌组列表,右边是选中的卡组页;
 * 一进来就自动选中第一组,右边不会空着。开始作答(沉浸)时把左栏也藏掉,作答区占满全屏。
 * 竖屏平板(md):仍是单栏,内容收进最宽 MAX_COL 的居中列。
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DeckCounts, dayIndex } from '../data/Schema';
import { L, LANG_ZH, fmt } from '../i18n/Strings';
import { SK_IMMERSIVE, SK_LANG, SK_TICK, appStore } from '../store/AppStore';
import { BP_SM, MAX_COL, SIDE_W, SK_BP, isSplit } from './Layout';
import { ImportIcon } from './ImportIcon';
import { runImport } from './ImportAction';
import { COLOR_DUE, COLOR_LEARN, COLOR_NEW, COLOR_ZERO } from './DeckColors';
import { StudyPage } from './StudyPage';

/** 页面大标题。品牌名,各语言都写 REPS(中文应用名「刻意重复」只出现在桌面和关于里) */
const BRAND: string = 'REPS';
const DOMAIN: number = 0x0A01;
const TAG: string = 'REPS-Decks';

/** 路由名。参数是卡组 id(number) */
export const ROUTE_DECK: string = 'deck';

/**
 * 路由表。**必须是顶层 @Builder 函数** —— strict 模式下 navDestination
 * 不接受内联 lambda(skill: ArkTS strict-mode compiler errors)。
 */
@Builder
function studyRoutes(name: string, param: Object) {
  if (name === ROUTE_DECK) {
    StudyPage({ deckId: param as number })
  }
}

const EMPTY_DECK: DeckCounts = {
  id: 0, name: '', cards: 0, newCount: 0, learnCount: 0, dueCount: 0, settled: 0,
};

/** 三个计数列的宽度。固定宽度才能让各行的数字上下对齐,像 Anki 的表格 */
const COL_W: number = 46;

@Component
export struct StudyTab {
  private stack: NavPathStack = new NavPathStack();

  @StorageLink(SK_TICK) @Watch('onTick') tick: number = 0;
  @StorageLink(SK_LANG) lang: string = LANG_ZH;
  @StorageLink(SK_BP) @Watch('onBreakpoint') bp: string = BP_SM;
  /** 作答中:分栏时左栏要藏起来 */
  @StorageLink(SK_IMMERSIVE) immersive: boolean = false;
  /** 分栏时右边打开的是哪一组(列表上高亮这一行);0 = 没有 */
  @State private openId: number = 0;
  /** 第一次拿到牌组之后才自动打开第一组(启动时数据库可能还没就绪) */
  private autoOpened: boolean = false;

  @State private decks: DeckCounts[] = [];
  @State private status: string = '';
  @State private busy: boolean = false;
  /** 今天(凌晨 3 点分界)打过卡没有 */
  @State private checkedIn: boolean = false;
  /** 全部牌组今天的待学习 / 待复习之和 —— 就是各行数字相加,同一个口径 */
  @State private totalNew: number = 0;
  @State private totalDue: number = 0;
  /**
   * 待确认的操作:作用于哪一组(下标)、什么操作(1 清空进度 / 2 删除牌组)。
   * 两个都不可撤销,所以一律二次确认 —— 菜单里点一下只是「打开确认框」。
   */
  @State private confirmIdx: number = -1;
  @State private confirmKind: number = 0;

  aboutToAppear(): void {
    // 右栏的卡组页被返回关掉时,列表上的高亮跟着去掉
    this.stack.setInterception({
      didShow: () => {
        if (this.stack.size() === 0) {
          this.openId = 0;
        }
      },
    });
    this.reload();
  }

  onTick(): void {
    this.reload();
  }

  /** 旋转到横屏:右栏不要空着;转回竖屏:页面栈原样保留,继续当单栏用 */
  onBreakpoint(): void {
    this.ensureDetail(true);
  }

  /**
   * 分栏时整理右栏:打开的那组被删掉了就关掉它;`autoOpen` 时若右栏是空的就打开第一组。
   *
   * 只在**刚进入分栏**(启动、转到横屏)时 autoOpen。用户在右栏按返回把卡组页关掉之后,
   * 右栏就该空着、列表上不再高亮 —— 再按一次返回才退出应用,和系统的双栏应用一致。
   * 单栏时什么都不做:手机上进入卡组必须是用户自己点的。
   */
  private ensureDetail(autoOpen: boolean): void {
    if (!isSplit(this.bp)) {
      return;
    }
    if (this.openId !== 0 && this.decks.every((d: DeckCounts) => d.id !== this.openId)) {
      this.stack.clear(false);
    }
    if (this.stack.size() === 0) {
      this.openId = 0;
    }
    if (autoOpen && this.openId === 0 && this.decks.length > 0) {
      this.openDeck(0);
    }
  }

  private reload(): void {
    const st = appStore();
    if (!st.isReady()) {
      return;
    }
    try {
      const db = st.getDb();
      const now: number = Date.now();
      this.decks = db.deckCounts(now, st.newPerDay, st.reviewLimit);
      let n = 0;
      let d = 0;
      for (const x of this.decks) {
        n += x.newCount;
        d += x.dueCount;
      }
      this.totalNew = n;
      this.totalDue = d;
      this.checkedIn = db.isCheckedIn(dayIndex(now));
      this.ensureDetail(!this.autoOpened);
      this.autoOpened = this.autoOpened || this.decks.length > 0;
    } catch (e) {
      this.status = fmt(L(this.lang).readFailed, `${e}`);
      hilog.error(DOMAIN, TAG, '读取牌组失败 %{public}s', `${e}`);
    }
  }

  private openDeck(i: number): void {
    const id: number = this.decks[i].id;
    if (isSplit(this.bp)) {
      // 分栏:右栏只放一组,换一组就整栈替换(不在右栏里越摞越深)
      if (this.openId === id && this.stack.size() > 0) {
        return;
      }
      this.stack.clear(false);
      this.stack.pushPath({ name: ROUTE_DECK, param: id }, false);
    } else {
      this.stack.pushPath({ name: ROUTE_DECK, param: id });
    }
    this.openId = id;
  }

  // ---------------------------------------------------------------- 打卡

  /**
   * 点打卡。**打卡是用户自己说「今天就到这里」**,统计里的学习天数按它算。
   * 待学习 + 待复习都是 0:直接打卡;还有剩:先问一句。已打卡:什么都不做(不能撤销)。
   */
  private onCheckIn(): void {
    if (this.checkedIn) {
      return;
    }
    if (this.totalNew + this.totalDue === 0) {
      this.doCheckIn();
      return;
    }
    this.getUIContext().showAlertDialog({
      title: L(this.lang).checkInConfirmTitle,
      message: fmt(L(this.lang).checkInConfirmBody, this.totalNew, this.totalDue),
      autoCancel: true,
      primaryButton: { value: L(this.lang).cancel, action: () => {} },
      secondaryButton: { value: L(this.lang).checkInAnyway, action: () => this.doCheckIn() },
    });
  }

  private doCheckIn(): void {
    try {
      const now: number = Date.now();
      appStore().getDb().checkIn(dayIndex(now), now);
      this.checkedIn = true;
      this.status = L(this.lang).checkInDone;
      appStore().bump();      // 统计页的学习天数 / 月历跟着变
    } catch (e) {
      this.status = fmt(L(this.lang).saveFailed, `${e}`);
    }
  }

  /**
   * 「今日」卡片:全部牌组的待学习 / 待复习之和 + 打卡按钮。
   * 未打卡灰、已打卡绿 —— 绿色在 REPS 里只表示「完成 / 掌握」。
   */
  @Builder
  todayCard() {
    Row() {
      Column({ space: 4 }) {
        Text(L(this.lang).todayTitle).fontSize(13).fontColor('#8A8A8E')
        Row({ space: 18 }) {
          Column({ space: 1 }) {
            Text(`${this.totalNew}`).fontSize(24).fontWeight(FontWeight.Bold)
              .fontColor(this.totalNew === 0 ? COLOR_ZERO : COLOR_NEW)
            Text(L(this.lang).toLearn).fontSize(11).fontColor('#8A8A8E')
          }
          .alignItems(HorizontalAlign.Start)
          Column({ space: 1 }) {
            Text(`${this.totalDue}`).fontSize(24).fontWeight(FontWeight.Bold)
              .fontColor(this.totalDue === 0 ? COLOR_ZERO : COLOR_DUE)
            Text(L(this.lang).toReview).fontSize(11).fontColor('#8A8A8E')
          }
          .alignItems(HorizontalAlign.Start)
        }
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)

      Row({ space: 4 }) {
        Text(this.checkedIn ? '✓' : '○').fontSize(15)
          .fontColor(this.checkedIn ? Color.White : '#8A8A8E')
        Text(this.checkedIn ? L(this.lang).checkedIn : L(this.lang).notCheckedIn)
          .fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.checkedIn ? Color.White : '#8A8A8E')
      }
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .borderRadius(20)
      .backgroundColor(this.checkedIn ? '#10B981' : '#EDEEF2')
      .onClick(() => this.onCheckIn())
    }
    .width('90%').constraintSize({ maxWidth: MAX_COL }).padding(16).margin({ bottom: 12 })
    .borderRadius(16).backgroundColor(Color.White)
  }

  // ---------------------------------------------------------------- 牌组操作

  /** 每行的「⋯」菜单。用 MenuElement 数组,不用已废弃的弹窗 API */
  private actionsFor(i: number): MenuElement[] {
    return [
      { value: L(this.lang).actClear, action: () => this.askConfirm(i, 1) },
      { value: L(this.lang).actDelete, action: () => this.askConfirm(i, 2) },
    ];
  }

  private askConfirm(i: number, kind: number): void {
    this.confirmIdx = i;
    this.confirmKind = kind;
  }

  private cancelConfirm(): void {
    this.confirmIdx = -1;
    this.confirmKind = 0;
  }

  private doConfirm(): void {
    const i: number = this.confirmIdx;
    if (i < 0 || i >= this.decks.length) {
      this.cancelConfirm();
      return;
    }
    const d: DeckCounts = this.decks[i];
    const db = appStore().getDb();
    try {
      if (this.confirmKind === 1) {
        db.clearDeckProgress(d.id);
        this.status = fmt(L(this.lang).clearedProgress, d.name, d.cards);
      } else {
        db.deleteDeck(d.id);
        this.status = fmt(L(this.lang).deletedDeck, d.name);
      }
    } catch (e) {
      this.status = fmt(L(this.lang).saveFailed, `${e}`);
    }
    this.cancelConfirm();
    // 全局重算:词卡表、统计也要跟着变
    appStore().bump();
  }

  /** 标题栏的导入图标(没有牌组时还有一个居中的大按钮)。和浏览页共用 runImport */
  private async onImport(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.status = L(this.lang).importing;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      // 取消返回空串:取消不是失败,什么都不用说
      this.status = await runImport(ctx, this.lang);
    } finally {
      this.busy = false;
    }
  }

  /**
   * 页面标题栏:左边 REPS,右边导入图标。和浏览页「浏览 + 导入 + 新建」同一种标题栏,
   * 取代原来页面底部那条整宽的「导入牌组」按钮。
   */
  @Builder
  header() {
    Row() {
      Text(BRAND)
        .fontSize(26).fontWeight(FontWeight.Bold).layoutWeight(1)
      Stack() {
        ImportIcon({ color: this.busy ? '#B0B7C3' : '#3B82F6', side: 26 })
      }
      .width(44).height(44)
      .accessibilityText(L(this.lang).importDeck)
      .accessibilityLevel('yes')
      .onClick(() => { this.onImport(); })
    }
    .width('90%').constraintSize({ maxWidth: MAX_COL }).margin({ top: 16, bottom: 10 })
  }

  /** 确认框。文案沿用原词卡表里的那套,作用对象是被点的那一组 */
  @Builder
  confirmPanel() {
    Column({ space: 10 }) {
      Text(this.confirmKind === 1 ? L(this.lang).clearConfirmTitle : L(this.lang).deleteDeckTitle)
        .fontSize(17).fontWeight(FontWeight.Bold).width('100%')
      Text(this.confirmKind === 1
        ? fmt(L(this.lang).clearConfirmBody, this.decks[this.confirmIdx].name, this.decks[this.confirmIdx].cards)
        : fmt(L(this.lang).deleteDeckBody, this.decks[this.confirmIdx].name, this.decks[this.confirmIdx].cards))
        .fontSize(13).fontColor('#48484A').width('100%')
      Text(this.confirmKind === 1 ? L(this.lang).clearIrreversible : L(this.lang).deleteDeckIrreversible)
        .fontSize(12).fontColor('#E5544B').width('100%')
      Row({ space: 8 }) {
        Button(this.confirmKind === 1 ? L(this.lang).confirmClear : L(this.lang).confirmDelete)
          .layoutWeight(1).height(42).backgroundColor('#E5544B')
          .onClick(() => this.doConfirm())
        Button(L(this.lang).cancel).layoutWeight(1).height(42)
          .backgroundColor('#E5E5EA').fontColor('#1C1C1E')
          .onClick(() => this.cancelConfirm())
      }
      .width('100%')
    }
    .width('90%').constraintSize({ maxWidth: 480 }).padding(16).borderRadius(14).backgroundColor(Color.White)
    .shadow({ radius: 16, color: '#33000000' })
  }

  /** 一个计数。为 0 时显示灰色 —— Anki 的做法,一眼看出哪组今天没事 */
  @Builder
  countCell(i: number, which: number) {
    Text(`${this.countOf(i, which)}`)
      .width(COL_W).textAlign(TextAlign.End)
      .fontSize(15).fontWeight(FontWeight.Medium)
      .fontColor(this.countOf(i, which) === 0 ? COLOR_ZERO
        : which === 0 ? COLOR_NEW : which === 1 ? COLOR_LEARN : COLOR_DUE)
  }

  /** 越界时给空行:删掉一组后,旧下标的行可能先重绘一次才被换掉(见 BrowserTab.rowAt) */
  private deckAt(i: number): DeckCounts {
    return i >= 0 && i < this.decks.length ? this.decks[i] : EMPTY_DECK;
  }

  private countOf(i: number, which: number): number {
    const d: DeckCounts = this.deckAt(i);
    return which === 0 ? d.newCount : which === 1 ? d.learnCount : d.dueCount;
  }

  @Builder
  headerCell(which: number) {
    Text(which === 0 ? L(this.lang).colNew : which === 1 ? L(this.lang).colLearn : L(this.lang).colDue)
      .width(COL_W).textAlign(TextAlign.End)
      .fontSize(11).fontColor('#8A8A8E')
      .maxLines(1)
  }

  /** 牌组的一行。**只接常量下标** */
  @Builder
  deckRow(i: number) {
    Row() {
      Column({ space: 2 }) {
        // 英文名不能在单词中间断开(实测 Miscellaneous 被切成 Miscellaneou / s)
        Text(this.deckAt(i).name)
          .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#1C1C1E')
          .wordBreak(WordBreak.NORMAL)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${this.deckAt(i).cards} ${L(this.lang).cardsUnit}`)
          .fontSize(11).fontColor('#8A8A8E')
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)

      this.countCell(i, 0)
      this.countCell(i, 1)
      this.countCell(i, 2)

      // 「⋯」:Anki 牌组列表行尾的齿轮。点它不会进入卡组
      Text('⋯')
        .fontSize(20).fontColor('#8A8A8E')
        .width(36).height(36).textAlign(TextAlign.Center)
        .margin({ left: 4 })
        .accessibilityText(L(this.lang).deckActions)
        .bindMenu(this.actionsFor(i))
    }
    .width('100%').padding({ left: 16, right: 4, top: 14, bottom: 14 })
    // 分栏时右边正打开的那组用浅蓝底标出来
    .backgroundColor(isSplit(this.bp) && this.deckAt(i).id === this.openId ? '#EAF1FE' : Color.White)
    .borderRadius(12)
    .onClick(() => this.openDeck(i))
  }

  @Builder
  deckList() {
    Column() {
      this.header()
      this.todayCard()

      if (this.decks.length === 0) {
        Text(L(this.lang).deckListEmpty)
          .fontSize(14).fontColor('#8A8A8E')
          .width('90%').constraintSize({ maxWidth: MAX_COL }).textAlign(TextAlign.Center).margin({ top: 40 })
        // 还没有任何牌组:标题栏上的小图标容易被忽略,这里给一个明显的入口。有牌组之后就不再显示
        Button(L(this.lang).importDeck)
          .height(46).fontSize(16).padding({ left: 32, right: 32 }).margin({ top: 16 })
          .enabled(!this.busy)
          .onClick(() => { this.onImport(); })
      } else {
        // 列头:与每行的三个计数同宽,数字才能对齐
        Row() {
          Blank()
          this.headerCell(0)
          this.headerCell(1)
          this.headerCell(2)
        }
        .width('90%').constraintSize({ maxWidth: MAX_COL }).padding({ right: 44 }).margin({ bottom: 6 })

        List({ space: 8 }) {
          // 牌组通常只有个位数到几十个,ForEach 足够;key 带上计数,数字变了行就重建
          ForEach(this.decks, (d: DeckCounts, idx: number) => {
            ListItem() {
              this.deckRow(idx)
            }
          }, (d: DeckCounts, idx: number) =>
            `${idx}:${d.id}:${d.name}:${d.cards}:${d.newCount}:${d.learnCount}:${d.dueCount}`)
        }
        .layoutWeight(1).width('90%').constraintSize({ maxWidth: MAX_COL })
        .scrollBar(BarState.Auto)
      }

      if (this.status.length > 0) {
        Text(this.status).fontSize(12).fontColor('#48484A')
          .width('90%').constraintSize({ maxWidth: MAX_COL }).textAlign(TextAlign.Center)
          .margin({ top: 8, bottom: 12 })
      }
    }
    .width('100%').height('100%').backgroundColor('#F2F2F7')
  }

  build() {
    Navigation(this.stack) {
      Stack({ alignContent: Alignment.Center }) {
        this.deckList()
        if (this.confirmIdx >= 0 && this.confirmIdx < this.decks.length) {
          // 半透明遮罩:点空白处等于取消,确认框之外什么都点不到
          Column()
            .width('100%').height('100%').backgroundColor('#66000000')
            .onClick(() => this.cancelConfirm())
          this.confirmPanel()
        }
      }
      .width('100%').height('100%')
    }
    .navDestination(studyRoutes)
    .hideTitleBar(true)
    .hideToolBar(true)
    .mode(isSplit(this.bp) ? NavigationMode.Split : NavigationMode.Stack)
    .navBarWidth(SIDE_W)
    // 作答时左栏也收起来,作答区占满全屏
    .hideNavBar(isSplit(this.bp) && this.immersive)
    .width('100%').height('100%')
  }
}
