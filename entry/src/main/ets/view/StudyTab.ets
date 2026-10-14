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

import { hilog } from '@kit.PerformanceAnalysisKit';
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
    }
    .width('100%').padding({ left: 16, right: 12, top: 14, bottom: 14 })
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
        .width('90%').padding({ right: 12 }).margin({ bottom: 6 })

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
          .width('90%').textAlign(TextAlign.Center).margin({ top: 8, bottom: 8 })
      }
    }
    .width('100%').height('100%').backgroundColor('#F2F2F7')
  }

  build() {
    Navigation(this.stack) {
      this.deckList()
    }
    .navDestination(studyRoutes)
    .hideTitleBar(true)
    .hideToolBar(true)
    .mode(NavigationMode.Stack)
    .width('100%').height('100%')
  }
}
