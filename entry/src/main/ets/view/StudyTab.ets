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
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ImportResult, importFromPicker } from '../data/Importer';
import { DeckCounts } from '../data/Schema';
import { L, LANG_ZH, fmt } from '../i18n/Strings';
import { SK_LANG, SK_TICK, appStore } from '../store/AppStore';
import { COLOR_DUE, COLOR_LEARN, COLOR_NEW, COLOR_ZERO } from './DeckColors';
import { StudyPage } from './StudyPage';

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

/** 三个计数列的宽度。固定宽度才能让各行的数字上下对齐,像 Anki 的表格 */
const COL_W: number = 56;

@Component
export struct StudyTab {
  private stack: NavPathStack = new NavPathStack();

  @StorageLink(SK_TICK) @Watch('onTick') tick: number = 0;
  @StorageLink(SK_LANG) lang: string = LANG_ZH;

  @State private decks: DeckCounts[] = [];
  @State private status: string = '';
  @State private busy: boolean = false;
  /**
   * 待确认的操作:作用于哪一组(下标)、什么操作(1 清空进度 / 2 删除牌组)。
   * 两个都不可撤销,所以一律二次确认 —— 菜单里点一下只是「打开确认框」。
   */
  @State private confirmIdx: number = -1;
  @State private confirmKind: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  onTick(): void {
    this.reload();
  }

  private reload(): void {
    const st = appStore();
    if (!st.isReady()) {
      return;
    }
    try {
      this.decks = st.getDb().deckCounts(Date.now(), st.newPerDay, st.reviewLimit);
    } catch (e) {
      this.status = fmt(L(this.lang).readFailed, `${e}`);
      hilog.error(DOMAIN, TAG, '读取牌组失败 %{public}s', `${e}`);
    }
  }

  private openDeck(i: number): void {
    this.stack.pushPath({ name: ROUTE_DECK, param: this.decks[i].id });
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

  private async onImport(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.status = L(this.lang).importing;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const r: ImportResult = await importFromPicker(ctx, appStore().getDb());
      this.status = r.ok
        ? fmt(L(this.lang).importedTo, r.cardsAdded, r.deck)
        : (r.error === L(this.lang).cancel ? '' : fmt(L(this.lang).importFailed, r.error));
      if (r.ok) {
        appStore().bump();
      }
    } catch (e) {
      this.status = fmt(L(this.lang).importFailed, `${e}`);
    } finally {
      this.busy = false;
    }
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
    .width('90%').padding(16).borderRadius(14).backgroundColor(Color.White)
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

  private countOf(i: number, which: number): number {
    const d: DeckCounts = this.decks[i];
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
        Text(this.decks[i].name)
          .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#1C1C1E')
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${this.decks[i].cards} ${L(this.lang).cardsUnit}`)
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
    .backgroundColor(Color.White).borderRadius(12)
    .onClick(() => this.openDeck(i))
  }

  @Builder
  deckList() {
    Column() {
      Text(L(this.lang).deckListTitle)
        .fontSize(26).fontWeight(FontWeight.Bold)
        .width('90%').margin({ top: 16, bottom: 10 })

      if (this.decks.length === 0) {
        Text(L(this.lang).deckListEmpty)
          .fontSize(14).fontColor('#8A8A8E')
          .width('90%').textAlign(TextAlign.Center).margin({ top: 40 })
      } else {
        // 列头:与每行的三个计数同宽,数字才能对齐
        Row() {
          Blank()
          this.headerCell(0)
          this.headerCell(1)
          this.headerCell(2)
        }
        .width('90%').padding({ right: 44 }).margin({ bottom: 6 })

        List({ space: 8 }) {
          // 牌组通常只有个位数到几十个,ForEach 足够;key 带上计数,数字变了行就重建
          ForEach(this.decks, (d: DeckCounts, idx: number) => {
            ListItem() {
              this.deckRow(idx)
            }
          }, (d: DeckCounts, idx: number) =>
            `${idx}:${d.id}:${d.name}:${d.cards}:${d.newCount}:${d.learnCount}:${d.dueCount}`)
        }
        .layoutWeight(1).width('90%')
        .scrollBar(BarState.Auto)
      }

      if (this.status.length > 0) {
        Text(this.status).fontSize(12).fontColor('#48484A')
          .width('90%').textAlign(TextAlign.Center).margin({ top: 8 })
      }

      // Anki 的牌组列表底部就是「导入」这类全局动作
      Button(L(this.lang).importDeck)
        .width('90%').height(46).fontSize(16).margin({ top: 8, bottom: 12 })
        .enabled(!this.busy)
        .onClick(() => { this.onImport(); })
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
    .mode(NavigationMode.Stack)
    .width('100%').height('100%')
  }
}
