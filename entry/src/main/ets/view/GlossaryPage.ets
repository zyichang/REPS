/**
 * Glossary(词卡表):当前课本的入口页。
 *
 * 结构是一个**菜单**,不是一屏塞满的列表:
 *
 *   课本卡(封面 + 书名 + 描述)+ 「清空本书进度」
 *   ─────────────────────────
 *   浏览卡片        ›
 *   新建卡片        ›
 *
 * 「清空本书进度」放在课本旁边而不是右上角的三个点里 ——
 * 它是**针对当前这本书**的动作,放在书旁边才说得清作用对象;
 * 三个点里只留跨课本的动作(换书、导入、去学习)。
 *
 * 卡片的预览和编辑是**两个独立的页面**,各自只有一个「返回」:
 * 不在预览里切编辑,也不在编辑里切预览。一个页面只做一件事,
 * 退出方式只有一个,就不用去想「取消」和「返回」有什么区别。
 *
 * ArkUI 铁律:列表行的 @Builder **只接常量下标**,内容一律从 @State 数组里取。
 */

import { CardBrief, DeckRow } from '../data/Schema';
import { ParsedCard, QuizifyError, parseOneCard, renderCloze } from '../data/Quizify';
import { ImportResult, importFromPicker } from '../data/Importer';
import { SK_BACK_REQ, SK_CAN_BACK, SK_GOTO_TAB, SK_LANG, SK_TICK, appStore } from '../store/AppStore';
import { L, LANG_ZH, fmt } from '../i18n/Strings';
import { BookCover } from './BookCover';
import { MarkupText } from './MarkupText';
import { MathText, hasMath } from './MathText';
import { common } from '@kit.AbilityKit';

const TYPE_TINT: string[] = ['#4A90D9', '#B26BD9', '#2E9E63'];
const PREVIEW_MAX: number = 42;

/** 这一页的五种形态。每种都只有一个退出方向 */
enum Mode {
  Home = 0,
  SwitchBook = 1,
  CardList = 2,
  Preview = 3,
  Edit = 4,
}

@Component
export struct GlossaryPage {
  @StorageLink(SK_TICK) @Watch('onTick') tick: number = 0;
  /** 界面名称默认中文,只有切到英文时才显示英文 */
  @StorageLink(SK_LANG) lang: string = LANG_ZH;
  /** 告诉 Index:这一页现在还能不能返回一级 */
  @StorageLink(SK_CAN_BACK) canBack: boolean = false;
  @StorageLink(SK_BACK_REQ) @Watch('onBackReq') backReq: number = 0;

  @State private mode: Mode = Mode.Home;
  @State private cards: CardBrief[] = [];
  @State private status: string = '';
  @State private busy: boolean = false;

  // ---- 当前课本 ----
  @State private deckId: number = 0;
  @State private deckLabel: string = '全部卡组';
  @State private deckCards: number = 0;
  @State private deckDue: number = 0;
  @State private deckNew: number = 0;
  @State private confirmClear: boolean = false;
  /** 待确认删除的卡组下标,-1 表示没有。删整本书不能一键触发 */
  @State private confirmDeckIdx: number = -1;

  // ---- 换书 ----
  @State private decks: DeckRow[] = [];
  @State private paths: string[] = [];

  // ---- 正在看 / 正在改的那张卡 ----
  @State private curFront: string = '';
  @State private curBack: string = '';
  @State private curTitle: string = '';
  @State private curType: number = 0;
  /** 0 表示新建 */
  @State private curNoteId: number = 0;
  @State private editError: string = '';
  @State private confirmDelete: boolean = false;
  /**
   * 编辑 / 预览是**从哪一级进来的**。从首页点「新建卡片」进来,返回就该回首页;
   * 从卡片列表进来,返回才回列表。不记这个的话「新建卡片 → 返回」会莫名
   * 掉进卡片列表 —— 用户根本没去过那儿。
   */
  @State private cameFrom: Mode = Mode.Home;

  aboutToAppear(): void {
    this.reload();
    this.publishDepth();
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
      const db = st.getDb();
      const now: number = Date.now();
      this.deckId = st.currentDeckId;
      this.deckLabel = this.deckId === 0 ? L(this.lang).allDecks : db.deckName(this.deckId);
      this.cards = db.listCards(this.deckId);
      this.deckCards = this.cards.length;
      this.deckDue = db.dueCardIdsInDeck(this.deckId, now, 100000).length;
      this.deckNew = db.newCardIdsInDeck(this.deckId, 100000).length;
    } catch (e) {
      this.status = fmt(L(this.lang).readFailed, `${e}`);
    }
  }

  // ---------------------------------------------------------------- 课本级动作

  private openSwitch(): void {
    try {
      const db = appStore().getDb();
      const rows: DeckRow[] = db.listDecks(Date.now());
      const ps: string[] = [];
      for (const r of rows) {
        ps.push(db.deckName(r.id));
      }
      this.decks = rows;
      this.paths = ps;
    } catch (e) {
      this.status = fmt(L(this.lang).readFailed, `${e}`);
      return;
    }
    this.confirmDeckIdx = -1;
    this.mode = Mode.SwitchBook;
    this.publishDepth();
  }

  private async onImport(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.status = L(this.lang).importing;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const r: ImportResult = await importFromPicker(ctx, appStore().getDb());
      this.status = r.ok
        ? fmt(L(this.lang).importedTo, r.cardsAdded, r.deck)
        : (r.error === L(this.lang).cancel ? '' : fmt(L(this.lang).importFailed, r.error));
      if (r.ok) {
        appStore().bump();
      }
      this.reload();
    } catch (e) {
      this.status = fmt(L(this.lang).importFailed, `${e}`);
    } finally {
      this.busy = false;
    }
  }

  private gotoStudy(): void {
    AppStorage.setOrCreate(SK_GOTO_TAB, 0);
  }

  private pickDeck(i: number): void {
    appStore().setCurrentDeck(this.decks[i].id, this.paths[i]);
    this.mode = Mode.Home;
    this.publishDepth();
    this.reload();
    this.status = fmt(L(this.lang).switchedTo, this.paths[i]);
  }

  private pickAll(): void {
    appStore().setCurrentDeck(0, '全部卡组');
    this.mode = Mode.Home;
    this.publishDepth();
    this.reload();
    this.status = L(this.lang).switchedAll;
  }

  /**
   * 整本删掉。**连卡片一起删**,和「清空本书进度」完全不同 ——
   * 后者只退回新卡,卡片一张不动。
   *
   * 删的正好是当前课本时,把当前切回「全部卡组」:
   * 留一个指向不存在卡组的 id,界面会一直显示 0 张卡而没人看得出为什么。
   */
  private doDeleteDeck(i: number): void {
    const d: DeckRow = this.decks[i];
    const label: string = this.paths[i];
    try {
      const st = appStore();
      st.getDb().deleteDeck(d.id);
      if (st.currentDeckId === d.id) {
        st.setCurrentDeck(0, L(this.lang).allDecks);
      }
      this.confirmDeckIdx = -1;
      st.bump();
      this.openSwitch();          // 重新拉一遍列表
      this.status = fmt(L(this.lang).deletedDeck, label);
    } catch (e) {
      this.status = fmt(L(this.lang).saveFailed, `${e}`);
      this.confirmDeckIdx = -1;
    }
  }

  /** 清空当前这本书的进度。**不可撤销**,只能从二次确认里调用 */
  private doClearProgress(): void {
    if (this.deckId <= 0) {
      this.status = L(this.lang).cannotClearAll;
      this.confirmClear = false;
      return;
    }
    try {
      appStore().getDb().clearDeckProgress(this.deckId);
      this.confirmClear = false;
      this.status = fmt(L(this.lang).clearedProgress, this.deckLabel, this.deckCards);
      appStore().bump();
      this.reload();
    } catch (e) {
      this.status = fmt(L(this.lang).saveFailed, `${e}`);
      this.confirmClear = false;
    }
  }

  // ---------------------------------------------------------------- 卡片

  private openPreview(i: number): void {
    const c: CardBrief = this.cards[i];
    this.curFront = c.front;
    this.curBack = c.back;
    this.curTitle = c.title;
    this.curType = c.type;
    this.curNoteId = c.noteId;
    this.cameFrom = Mode.CardList;
    this.mode = Mode.Preview;
    this.publishDepth();
  }

  private openEdit(i: number): void {
    const c: CardBrief = this.cards[i];
    this.curFront = c.front;
    this.curBack = c.back;
    this.curTitle = c.title;
    this.curType = c.type;
    this.curNoteId = c.noteId;
    this.editError = '';
    this.confirmDelete = false;
    this.cameFrom = Mode.CardList;
    this.mode = Mode.Edit;
    this.publishDepth();
  }

  private openNew(): void {
    this.curFront = '';
    this.curBack = '';
    this.curTitle = '';
    this.curType = 0;
    this.curNoteId = 0;
    this.editError = '';
    this.confirmDelete = false;
    // 从首页新建,返回就回首页
    this.cameFrom = Mode.Home;
    this.mode = Mode.Edit;
    this.publishDepth();
  }

  private save(): void {
    const st = appStore();
    if (this.curNoteId === 0 && this.deckId <= 0) {
      this.editError = L(this.lang).allDecksNoNew;
      return;
    }
    let parsed: ParsedCard;
    try {
      const db = st.getDb();
      const deckName: string = this.deckId > 0 ? db.deckName(this.deckId) : this.deckLabel;
      parsed = parseOneCard(deckName, this.curFront, this.curBack);
    } catch (e) {
      this.editError = e instanceof QuizifyError
        ? e.message : fmt(L(this.lang).importFailed, `${e}`);
      return;
    }
    try {
      const db = st.getDb();
      const now: number = Date.now();
      if (this.curNoteId === 0) {
        db.insertManualCard(this.deckId, db.deckName(this.deckId), parsed, now);
        this.status = L(this.lang).createdCard;
      } else {
        db.updateNoteText(this.curNoteId, parsed, now);
        this.status = L(this.lang).savedEdit;
      }
      st.bump();
      this.reload();
      this.mode = this.cameFrom;
      this.publishDepth();
    } catch (e) {
      this.editError = fmt(L(this.lang).saveFailed, `${e}`);
    }
  }

  private doDelete(): void {
    try {
      appStore().getDb().deleteNote(this.curNoteId);
      this.status = L(this.lang).deletedCard;
      this.confirmDelete = false;
      appStore().bump();
      this.reload();
      this.mode = this.cameFrom;
      this.publishDepth();
    } catch (e) {
      this.editError = fmt(L(this.lang).saveFailed, `${e}`);
    }
  }

  // ---------------------------------------------------------------- 小工具

  /** 题型文字。跟随语言 —— 「问答/选择/挖空」是界面用词,不是卡片内容 */
  private typeLabel(i: number): string {
    const d = L(this.lang);
    const t: number = this.typeOf(i);
    return t === 1 ? d.typeChoice : t === 2 ? d.typeCloze : d.typeQA;
  }

  private typeOf(i: number): number {
    const t: number = this.cards[i].type;
    return t >= 0 && t < 3 ? t : 0;
  }

  private rowPreview(i: number): string {
    const c: CardBrief = this.cards[i];
    const src: string = c.title.length > 0 ? c.title : c.front;
    let t: string = src.replace(/^\s*#{1,6}\s+/gm, '');
    t = t.replace(/\{\{([^}]*)\}\}/g, '$1');
    t = t.replace(/[\r\n]+/g, ' ').replace(/\s{2,}/g, ' ').trim();
    return t.length > PREVIEW_MAX ? t.substring(0, PREVIEW_MAX) + '…' : t;
  }

  private deckDesc(): string {
    if (this.deckCards === 0) {
      return L(this.lang).deckDescEmpty;
    }
    return fmt(L(this.lang).deckDesc, this.deckCards, this.deckDue, this.deckNew);
  }

  // ---------------------------------------------------------------- 视图

  /** 正文渲染:有公式走 WebView,没有就走原生 —— 与学习页同一套判断 */
  /**
   * 预览的正反面各自一个 builder,**内部读状态,不接文字参数** ——
   * 按值传参的 @Builder 不响应更新,换一张卡预览会显示上一张的内容。
   * 学习页就是这么翻车的。
   */
  @Builder
  previewFront() {
    if (hasMath(this.curFront)) {
      MathText({ source: renderCloze(this.curFront, false), fontPx: 17, lineHeightPx: 27 })
    } else {
      MarkupText({
        source: renderCloze(this.curFront, false),
        fontPx: 17, lineHeightPx: 27, color: '#1C1C1E',
      })
    }
  }

  @Builder
  previewBack() {
    if (hasMath(this.curBack)) {
      MathText({ source: this.curBack, fontPx: 15, lineHeightPx: 24 })
    } else {
      MarkupText({ source: this.curBack, fontPx: 15, lineHeightPx: 24, color: '#48484A' })
    }
  }

  /** 顶部一行:标题 + 返回或三个点 */
  @Builder
  topBar(forMode: Mode) {
    Row() {
      // 返回是左上角的箭头。不用「返回」二字 —— 图标不需要翻译,
      // 而且位置固定在左上角,用户不必每页去找。
      if (forMode !== Mode.Home) {
        Text('‹')
          .fontSize(30).fontWeight(FontWeight.Medium).fontColor('#1C1C1E')
          .padding({ right: 10 })
          .onClick(() => this.goBack())
      }
      Text(this.titleFor(forMode))
        .fontSize(22).fontWeight(FontWeight.Bold).layoutWeight(1)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (forMode === Mode.Home) {
        Text('⋯')
          .fontSize(26).fontColor('#1C1C1E')
          .padding({ left: 12, right: 12 })
          .bindMenu([
            { value: L(this.lang).menuSwitchBook, action: () => this.openSwitch() },
            { value: L(this.lang).menuImport, action: () => { this.onImport(); } },
            { value: L(this.lang).menuGoStudy, action: () => this.gotoStudy() },
          ] as MenuElement[])
      }
    }
    .width('90%').margin({ top: 14, bottom: 10 })
  }

  /** 每个形态只有一个退出方向 */
  /**
   * 标题文字。**在 @Builder 内部现取** —— 把 L() 的结果当参数传进 @Builder
   * 不会响应语言切换,实测就是这么出现「一半中文一半英文」的。
   */
  private titleFor(m: Mode): string {
    const d = L(this.lang);
    if (m === Mode.SwitchBook) {
      return d.switchBookTitle;
    }
    if (m === Mode.CardList) {
      return d.cardsTitle;
    }
    if (m === Mode.Preview) {
      return d.previewTitle;
    }
    if (m === Mode.Edit) {
      return this.curNoteId === 0 ? d.newCardTitle : d.editCardTitle;
    }
    return d.tabGlossary;
  }

  /** 每个形态只有一个退出方向。返回到「进来时所在的那一级」 */
  private goBack(): void {
    if (this.mode === Mode.Preview || this.mode === Mode.Edit) {
      this.mode = this.cameFrom;
      this.publishDepth();
      this.editError = '';
      this.confirmDelete = false;
    } else {
      this.mode = Mode.Home;
      this.publishDepth();
    }
  }

  /** 还能不能再返回一级。Index 的 onBackPress 靠它决定是否拦下侧滑返回 */
  private canGoBack(): boolean {
    return this.mode !== Mode.Home;
  }

  /** Index 拦下了一次系统返回 */
  onBackReq(): void {
    if (this.canGoBack()) {
      this.goBack();
      this.publishDepth();
    }
  }

  /** 每次换形态都要同步给 Index,否则侧滑返回会用上一次的判断 */
  private publishDepth(): void {
    this.canBack = this.canGoBack();
  }

  /** 带小箭头的列表项 —— 不是按钮 */
  @Builder
  chevronRow(id: number) {
    Row() {
      Column({ space: 3 }) {
        Text(L(this.lang).cardBrowse).fontSize(16)
          .fontColor(this.deckCards > 0 ? '#1C1C1E' : '#B0B7C3')
        Text(`${this.deckCards} ${L(this.lang).cardsUnit} · ${L(this.lang).browseHint}`)
          .fontSize(11).fontColor('#8A8A8E')
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('›').fontSize(20).fontColor('#B0B7C3')
    }
    .width('100%').padding({ top: 14, bottom: 14, left: 14, right: 14 })
    .backgroundColor(Color.White)
    .onClick(() => {
      if (this.deckCards > 0) {
        this.mode = Mode.CardList;
        this.publishDepth();
      }
    })
  }

  @Builder
  bookCard() {
    Column({ space: 12 }) {
      Row({ space: 14 }) {
        Column() {
          BookCover({ tint: '#2E9E63', spine: '#24794C' })
        }
        .layoutWeight(2)

        Column({ space: 6 }) {
          Text(this.deckLabel)
            .fontSize(17).fontWeight(FontWeight.Bold).width('100%')
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.deckDesc()).fontSize(12).fontColor('#8A8A8E').width('100%')
        }
        .layoutWeight(7)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      // 针对**这本书**的动作,所以放在书旁边,不放进右上角的三个点
      Divider().color('#E5E5EA')
      Row() {
        Text(L(this.lang).clearProgress).fontSize(13)
          .fontColor(this.deckId > 0 ? '#E5544B' : '#B0B7C3').layoutWeight(1)
        Text(L(this.lang).clearProgressHint).fontSize(11).fontColor('#B0B7C3')
      }
      .width('100%')
      .onClick(() => {
        if (this.deckId > 0) {
          this.confirmClear = true;
        }
      })
    }
    .width('90%').padding(16).borderRadius(16).backgroundColor('#FFFFFF')
  }

  /** 卡片列表的一行:预览 / 编辑 两个独立入口。**只接常量下标** */
  @Builder
  cardRow(i: number) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.typeLabel(i))
          .fontSize(11).fontColor(Color.White)
          .backgroundColor(TYPE_TINT[this.typeOf(i)])
          .borderRadius(4).padding({ left: 6, right: 6, top: 1, bottom: 1 })
        Text(this.cards[i].reps > 0
          ? fmt(L(this.lang).reviewedTimes, this.cards[i].reps)
          : L(this.lang).newCardBadge)
          .fontSize(11)
          .fontColor(this.cards[i].reps > 0 ? '#8A8A8E' : '#4A90D9')
      }
      .width('100%')

      Text(this.rowPreview(i))
        .fontSize(15).fontColor('#1C1C1E')
        .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })

      Row({ space: 10 }) {
        Text(L(this.lang).preview).fontSize(13).fontColor('#2E9E63')
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .borderRadius(6).backgroundColor('#E8F5EE')
          .onClick(() => this.openPreview(i))
        Text(L(this.lang).edit).fontSize(13).fontColor('#4A90D9')
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .borderRadius(6).backgroundColor('#EAF2FB')
          .onClick(() => this.openEdit(i))
        Blank()
      }
      .width('100%')
    }
    .width('100%').padding(12)
    .backgroundColor(Color.White).borderRadius(10)
  }

  @Builder
  deckRow(i: number) {
    Column({ space: 8 }) {
      Row() {
        Column({ space: 3 }) {
          Text(this.paths[i]).fontSize(15).fontWeight(FontWeight.Medium)
          Text(fmt(L(this.lang).deckDesc, this.decks[i].cards,
            this.decks[i].due, this.decks[i].fresh))
            .fontSize(11).fontColor('#8A8A8E')
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)
        .onClick(() => this.pickDeck(i))

        if (this.decks[i].id === this.deckId) {
          Text('✓').fontSize(17).fontColor('#2E9E63').margin({ right: 10 })
        }
        Text(L(this.lang).deleteDeck)
          .fontSize(12).fontColor('#E5544B')
          .padding({ left: 10, right: 6, top: 4, bottom: 4 })
          .onClick(() => { this.confirmDeckIdx = i; })
      }
      .width('100%')

      if (this.confirmDeckIdx === i) {
        Column({ space: 8 }) {
          Text(L(this.lang).deleteDeckTitle)
            .fontSize(14).fontWeight(FontWeight.Medium).width('100%')
          Text(fmt(L(this.lang).deleteDeckBody, this.paths[i], this.decks[i].cards))
            .fontSize(11).fontColor('#48484A').width('100%')
          Text(L(this.lang).deleteDeckIrreversible)
            .fontSize(11).fontColor('#E5544B').width('100%')
          Row({ space: 8 }) {
            Button(L(this.lang).confirmDelete).layoutWeight(1).height(38).fontSize(14)
              .backgroundColor('#E5544B')
              .onClick(() => this.doDeleteDeck(i))
            Button(L(this.lang).cancel).layoutWeight(1).height(38).fontSize(14)
              .backgroundColor('#E5E5EA').fontColor('#1C1C1E')
              .onClick(() => { this.confirmDeckIdx = -1; })
          }
          .width('100%')
        }
        .width('100%').padding(10).borderRadius(8).backgroundColor('#FDF2F1')
      }
    }
    .width('100%').padding(14).backgroundColor(Color.White).borderRadius(10)
  }

  build() {
    Column() {
      if (this.mode === Mode.Home) {
        this.topBar(Mode.Home)
        this.bookCard()

        Button(L(this.lang).newCard)
          .width('90%').height(44).fontSize(16).margin({ top: 14 })
          .enabled(this.deckId > 0)
          .onClick(() => this.openNew())

        Column() {
          this.chevronRow(0)
        }
        .width('90%').margin({ top: 12 })
        .borderRadius(12).clip(true)

        if (this.status.length > 0) {
          Text(this.status).fontSize(12).fontColor('#48484A')
            .width('90%').textAlign(TextAlign.Center).margin({ top: 12 })
        }

        if (this.confirmClear) {
          Column({ space: 10 }) {
            Text(L(this.lang).clearConfirmTitle).fontSize(17).fontWeight(FontWeight.Bold).width('100%')
            Text(fmt(L(this.lang).clearConfirmBody, this.deckCards, this.deckLabel))
              .fontSize(12).fontColor('#48484A').width('100%')
            Text(L(this.lang).clearIrreversible).fontSize(12).fontColor('#E5544B').width('100%')
            Row({ space: 8 }) {
              Button(L(this.lang).confirmClear).layoutWeight(1).height(42)
                .backgroundColor('#E5544B')
                .onClick(() => this.doClearProgress())
              Button(L(this.lang).cancel).layoutWeight(1).height(42)
                .backgroundColor('#E5E5EA').fontColor('#1C1C1E')
                .onClick(() => { this.confirmClear = false; })
            }
            .width('100%')
          }
          .width('90%').padding(16).margin({ top: 14 })
          .borderRadius(12).backgroundColor('#FFFFFF')
        }
      } else if (this.mode === Mode.SwitchBook) {
        this.topBar(Mode.SwitchBook)
        Row() {
          Column({ space: 3 }) {
            Text(L(this.lang).allDecks).fontSize(15).fontWeight(FontWeight.Medium)
            Text(L(this.lang).noDeckMix).fontSize(11).fontColor('#8A8A8E')
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          if (this.deckId === 0) {
            Text('✓').fontSize(17).fontColor('#2E9E63')
          }
        }
        .width('90%').padding(14).backgroundColor(Color.White).borderRadius(10)
        .onClick(() => this.pickAll())

        List({ space: 8 }) {
          ForEach(this.decks, (d: DeckRow, idx?: number) => {
            ListItem() {
              this.deckRow(idx as number)
            }
          }, (d: DeckRow) => `${d.id}`)
        }
        .layoutWeight(1).width('90%').margin({ top: 8 })
        .scrollBar(BarState.Auto)
      } else if (this.mode === Mode.CardList) {
        this.topBar(Mode.CardList)
        List({ space: 8 }) {
          ForEach(this.cards, (c: CardBrief, idx?: number) => {
            ListItem() {
              this.cardRow(idx as number)
            }
          }, (c: CardBrief) => `${c.cardId}`)
        }
        .layoutWeight(1).width('90%')
        .scrollBar(BarState.Auto)
      } else if (this.mode === Mode.Preview) {
        this.topBar(Mode.Preview)
        Scroll() {
          Column({ space: 12 }) {
            if (this.curTitle.length > 0) {
              Text(this.curTitle).fontSize(12).fontColor('#8A8A8E').width('100%')
            }
            Text(L(this.lang).front).fontSize(11).fontColor('#B0B7C3').width('100%')
            this.previewFront()
            Divider().color('#E5E5EA')
            Text(L(this.lang).back).fontSize(11).fontColor('#B0B7C3').width('100%')
            this.previewBack()
          }
          .width('100%').padding(16)
        }
        .layoutWeight(1).width('90%')
        .backgroundColor('#FFFFFF').borderRadius(12)
      } else {
        this.topBar(Mode.Edit)
        Scroll() {
          Column({ space: 10 }) {
            Text(L(this.lang).front).fontSize(12).fontColor('#8A8A8E').width('100%')
            TextArea({ text: this.curFront, placeholder: L(this.lang).frontPlaceholder })
              .height(150).fontSize(15)
              .onChange((v: string) => { this.curFront = v; })

            Text(L(this.lang).back).fontSize(12).fontColor('#8A8A8E').width('100%')
            TextArea({ text: this.curBack, placeholder: L(this.lang).backPlaceholder })
              .height(120).fontSize(15)
              .onChange((v: string) => { this.curBack = v; })

            if (this.editError.length > 0) {
              Text(this.editError).fontSize(12).fontColor('#E5544B').width('100%')
            }

            Button(L(this.lang).save).width('100%').height(44)
              .onClick(() => this.save())

            if (this.curNoteId > 0) {
              if (this.confirmDelete) {
                Row({ space: 8 }) {
                  Button(L(this.lang).confirmDelete).layoutWeight(1).height(40)
                    .backgroundColor('#E5544B')
                    .onClick(() => this.doDelete())
                  Button(L(this.lang).cancelDelete).layoutWeight(1).height(40)
                    .backgroundColor('#E5E5EA').fontColor('#1C1C1E')
                    .onClick(() => { this.confirmDelete = false; })
                }
                .width('100%')
              } else {
                Button(L(this.lang).deleteCard).width('100%').height(40)
                  .backgroundColor('#F2F2F7').fontColor('#E5544B')
                  .onClick(() => { this.confirmDelete = true; })
              }
            }
          }
          .width('100%').padding({ bottom: 24 })
        }
        .layoutWeight(1).width('90%')
      }
    }
    .width('100%').height('100%').backgroundColor('#F2F2F7')
  }
}
