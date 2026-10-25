/**
 * 浏览标签页:Anki 的 Browse 窗口在手机上的样子。
 *
 *   浏览列表(卡组过滤 + 搜索 + 卡片列表)──点一行──▶ 预览 ──编辑──▶ 编辑
 *                                         └──右上角 +──▶ 新建(选牌组)
 *
 * Anki 的三块(侧栏 / 表格 / 编辑区)在手机上排不下,所以侧栏变成顶部的卡组过滤,
 * 编辑区变成独立页面。页面栈走 Navigation + NavPathStack,返回交给它自己弹栈。
 *
 * 这一页**不认识「当前卡组」**:过滤只是浏览时的视角,不影响学习页(ADR-0004)。
 *
 * ArkUI 铁律:列表行的 @Builder **只接常量下标**,内容从数组里取;
 * 预览 / 编辑页的正文由 MarkupText / MathText(@Prop + @Watch)渲染。
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ParsedCard, QuizifyError, parseOneCard, renderCloze } from '../data/Quizify';
import { BrowseRow, DeckRow } from '../data/Schema';
import { L, LANG_ZH, fmt } from '../i18n/Strings';
import { SK_LANG, SK_TICK, appStore } from '../store/AppStore';
import { ArrayDataSource } from './ArrayDataSource';
import { MarkupText } from './MarkupText';
import { MathText, hasMath } from './MathText';
import { BP_SM, MAX_COL, SIDE_W, SK_BP, isSplit } from './Layout';
import { ImportIcon } from './ImportIcon';
import { runImport } from './ImportAction';

const DOMAIN: number = 0x0A01;
const TAG: string = 'REPS-Browse';

const ROUTE_PREVIEW: string = 'preview';
const ROUTE_EDIT: string = 'edit';

const TYPE_TINT: string[] = ['#3B82F6', '#B26BD9', '#10B981'];
const PREVIEW_MAX: number = 60;

/** 越界时的占位行(见 BrowserTab.rowAt) */
const EMPTY_ROW: BrowseRow = {
  cardId: 0, noteId: 0, deckId: 0, deckName: '', type: 0,
  title: '', front: '', back: '', due: 0, reps: 0,
};

/** 编辑页的入参。noteId 为 0 表示新建 */
class EditArgs {
  noteId: number = 0;
  /** 从哪张卡的预览进来的(保存后回到它);新建为 0 */
  cardId: number = 0;
  deckId: number = 0;
  front: string = '';
  back: string = '';

  constructor(noteId: number, deckId: number, front: string, back: string, cardId: number = 0) {
    this.noteId = noteId;
    this.cardId = cardId;
    this.deckId = deckId;
    this.front = front;
    this.back = back;
  }
}

/** 路由表:必须是顶层 @Builder(strict 模式不接受内联 lambda) */
@Builder
function browseRoutes(name: string, param: Object) {
  if (name === ROUTE_PREVIEW) {
    CardPreviewPage({ row: param as BrowseRow })
  } else if (name === ROUTE_EDIT) {
    CardEditPage({ args: param as EditArgs })
  }
}

function typeLabelOf(lang: string, type: number): string {
  const d = L(lang);
  return type === 1 ? d.typeChoice : type === 2 ? d.typeCloze : d.typeQA;
}

function typeIdx(type: number): number {
  return type >= 0 && type < 3 ? type : 0;
}

/** 一行的摘要:有标题用标题,去掉 Markdown 标题符号与挖空括号,压成一行 */
function oneLine(title: string, front: string): string {
  const src: string = title.length > 0 ? title : front;
  let t: string = src.replace(/^\s*#{1,6}\s+/gm, '');
  t = t.replace(/\{\{([^}]*)\}\}/g, '$1');
  t = t.replace(/[\r\n]+/g, ' ').replace(/\s{2,}/g, ' ').trim();
  return t.length > PREVIEW_MAX ? t.substring(0, PREVIEW_MAX) + '…' : t;
}

/** 到期状态:新卡 / 已到期 / M-D 到期。Anki 浏览器的 Due 列 */
function dueLabelOf(lang: string, due: number, reps: number, now: number): string {
  const d = L(lang);
  if (due === 0 || reps === 0) {
    return d.newCardBadge;
  }
  if (due <= now) {
    return d.dueNow;
  }
  const t: Date = new Date(due);
  return fmt(d.dueOn, `${t.getMonth() + 1}-${t.getDate()}`);
}

// ======================================================================== 列表

@Component
export struct BrowserTab {
  private stack: NavPathStack = new NavPathStack();
  private source: ArrayDataSource<BrowseRow> = new ArrayDataSource<BrowseRow>();

  @StorageLink(SK_TICK) @Watch('onTick') tick: number = 0;
  @StorageLink(SK_LANG) lang: string = LANG_ZH;
  /**
   * 横屏平板(lg):Navigation 改成 Split,左边列表、右边预览 / 编辑,点一行只换右栏。
   * 一进入分栏就预览第一张,右栏不空着。竖屏平板仍是单栏,内容收进居中列。
   */
  @StorageLink(SK_BP) @Watch('onBreakpoint') bp: string = BP_SM;
  /** 分栏时右栏在预览哪张卡(列表上高亮);0 = 没有 */
  @State private openCard: number = 0;

  @State private rows: BrowseRow[] = [];
  @State private decks: DeckRow[] = [];
  /** 过滤:0 = 全部卡组 */
  @State private filterDeck: number = 0;
  @State private query: string = '';
  @State private status: string = '';
  /** 当前过滤条件下一共多少张 —— 「N 张」显示的是它,不是已加载的行数 */
  @State private total: number = 0;
  /** 已经加载到第几页(从 0 起)。刷到底时加载 page + 1 */
  private page: number = 0;
  private loading: boolean = false;
  /** 列表上 key 的一部分:每次重查(换过滤 / 搜索)都换,LazyForEach 才会整体重建 */
  private gen: number = 0;

  aboutToAppear(): void {
    // 右栏被返回关空了:去掉列表上的高亮
    this.stack.setInterception({
      didShow: () => {
        if (this.stack.size() === 0) {
          this.openCard = 0;
        }
      },
    });
    this.reload();
    this.autoPreview();
  }

  onTick(): void {
    this.reload();
  }

  onBreakpoint(): void {
    this.autoPreview();
  }

  /** 刚进入分栏、右栏还空着:预览第一张。单栏时什么都不做 */
  private autoPreview(): void {
    if (isSplit(this.bp) && this.stack.size() === 0 && this.rows.length > 0) {
      this.openPreview(0);
    }
  }

  /**
   * 打开第 i 行的预览。分栏时右栏整栈替换成这一张(编辑页也一起关掉),
   * 单栏时照旧压栈。
   */
  private openPreview(i: number): void {
    const r: BrowseRow = this.rowAt(i);
    if (r.cardId === 0) {
      return;
    }
    if (isSplit(this.bp)) {
      this.stack.clear(false);
      this.stack.pushPath({ name: ROUTE_PREVIEW, param: r }, false);
    } else {
      this.stack.pushPath({ name: ROUTE_PREVIEW, param: r });
    }
    this.openCard = r.cardId;
  }

  private reload(): void {
    const st = appStore();
    if (!st.isReady()) {
      return;
    }
    try {
      const db = st.getDb();
      this.decks = db.listDecks(Date.now());
      // 过滤的那一组被删了:回到全部,别停在一个不存在的卡组上
      if (this.filterDeck !== 0 && this.decks.every((d: DeckRow) => d.id !== this.filterDeck)) {
        this.filterDeck = 0;
      }
      // 只取第一页。十万张卡的库一次全读进来会卡死(用户要求的分页加载)
      this.page = 0;
      this.total = db.browseCount(this.filterDeck, this.query);
      this.rows = db.browse(this.filterDeck, this.query, st.browsePage, 0);
      this.gen++;
      this.source.setData(this.rows);
      this.status = '';
      // 右栏 / 预览页里那张卡被删了(删牌组、删卡、同步删除):关掉,别显示一张已经不存在的卡
      if (this.openCard !== 0 && db.loadReviewCard(this.openCard) === null) {
        this.stack.clear(false);
        this.openCard = 0;
      }
      // 右栏空着(刚删光、刚从空库导入):补上第一张
      this.autoPreview();
    } catch (e) {
      this.status = fmt(L(this.lang).readFailed, `${e}`);
      hilog.error(DOMAIN, TAG, '浏览查询失败 %{public}s', `${e}`);
    }
  }

  /** 刷到底:加载下一页,追加到列表末尾。已加载完或正在加载就什么都不做 */
  private loadMore(): void {
    if (this.loading || this.rows.length >= this.total) {
      return;
    }
    this.loading = true;
    try {
      const st = appStore();
      const more: BrowseRow[] = st.getDb().browse(this.filterDeck, this.query, st.browsePage, this.page + 1);
      if (more.length > 0) {
        this.page++;
        this.rows = this.rows.concat(more);
        this.source.append(more);
      }
      hilog.info(DOMAIN, TAG, '浏览加载第 %{public}d 页,已加载 %{public}d / %{public}d',
        this.page, this.rows.length, this.total);
    } catch (e) {
      this.status = fmt(L(this.lang).readFailed, `${e}`);
    } finally {
      this.loading = false;
    }
  }

  private filterOptions(): SelectOption[] {
    const out: SelectOption[] = [{ value: L(this.lang).allDecks }];
    for (const d of this.decks) {
      out.push({ value: d.name });
    }
    return out;
  }

  private filterIndex(): number {
    for (let i = 0; i < this.decks.length; i++) {
      if (this.decks[i].id === this.filterDeck) {
        return i + 1;
      }
    }
    return 0;
  }

  private filterLabel(): string {
    const i: number = this.filterIndex();
    return i === 0 ? L(this.lang).allDecks : this.decks[i - 1].name;
  }

  private importing: boolean = false;

  /**
   * 标题栏的导入图标:和学习页的导入完全一样(runImport)。导入成功会 bump(),列表自己重查;
   * 结果用 toast 说 —— 列表顶上那行状态文字在重查时会被清掉。
   */
  private async onImport(): Promise<void> {
    if (this.importing) {
      return;
    }
    this.importing = true;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const msg: string = await runImport(ctx, this.lang);
      if (msg.length > 0) {
        try {
          this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2500 });
        } catch (e) {
          // toast 失败不影响导入本身;列表已经通过 bump() 刷新
          hilog.warn(DOMAIN, TAG, 'toast 失败 %{public}s', `${e}`);
        }
      }
    } finally {
      this.importing = false;
    }
  }

  private openNew(): void {
    if (this.decks.length === 0) {
      this.status = L(this.lang).needDeckFirst;
      return;
    }
    // 默认放进正在看的那一组;看的是全部就放第一组,编辑页里还能改
    const deck: number = this.filterDeck !== 0 ? this.filterDeck : this.decks[0].id;
    if (isSplit(this.bp)) {
      this.stack.clear(false);
      this.openCard = 0;
    }
    this.stack.pushPath({ name: ROUTE_EDIT, param: new EditArgs(0, deck, '', '') }, !isSplit(this.bp));
  }

  /**
   * 第 i 行的数据。**越界时给一个空行,不要直接 this.rows[i]。**
   *
   * 重查(换语言、换过滤、作答后 bump)会把 rows 重置成第一页,而已经建好的
   * 第 260 行之类会**先**因为 lang 等状态变化重绘一次,再被 LazyForEach 换掉 ——
   * 那一下 this.rows[i] 是 undefined,读 .type 直接 JS 崩溃(实测:滑到底后切语言闪退)。
   */
  private rowAt(i: number): BrowseRow {
    return i >= 0 && i < this.rows.length ? this.rows[i] : EMPTY_ROW;
  }

  /** 一行。**只接常量下标** */
  @Builder
  row(i: number) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(typeLabelOf(this.lang, this.rowAt(i).type))
          .fontSize(11).fontColor(Color.White)
          .backgroundColor(TYPE_TINT[typeIdx(this.rowAt(i).type)])
          .borderRadius(4).padding({ left: 6, right: 6, top: 1, bottom: 1 })
        Text(this.rowAt(i).deckName)
          .fontSize(11).fontColor('#8A8A8E').layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(dueLabelOf(this.lang, this.rowAt(i).due, this.rowAt(i).reps, Date.now()))
          .fontSize(11)
          .fontColor(this.rowAt(i).reps === 0 ? '#3B82F6' : '#8A8A8E')
      }
      .width('100%')

      Text(oneLine(this.rowAt(i).title, this.rowAt(i).front))
        .fontSize(15).fontColor('#1C1C1E')
        .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.rowAt(i).reps > 0) {
        Text(fmt(L(this.lang).reviewedTimes, this.rowAt(i).reps))
          .fontSize(11).fontColor('#B0B7C3').width('100%')
      }
    }
    .width('100%').padding(12)
    // 分栏时右栏正在预览的那张用浅蓝底标出来
    .backgroundColor(isSplit(this.bp) && this.rowAt(i).cardId === this.openCard ? '#EAF1FE' : Color.White)
    .borderRadius(10)
    .onClick(() => this.openPreview(i))
  }

  @Builder
  listPage() {
    Column() {
      Row() {
        Text(L(this.lang).browseTitle)
          .fontSize(26).fontWeight(FontWeight.Bold).layoutWeight(1)
        // 导入在左、新建在右:「+」留在原来的最右边
        Stack() {
          ImportIcon({ color: '#3B82F6', side: 26 })
        }
        .width(44).height(44)
        .accessibilityText(L(this.lang).importDeck)
        .accessibilityLevel('yes')
        .onClick(() => { this.onImport(); })
        Text('+')
          .fontSize(30).fontColor('#3B82F6')
          .width(44).height(44).textAlign(TextAlign.Center)
          .accessibilityText(L(this.lang).newCardTitle)
          .onClick(() => this.openNew())
      }
      .width('90%').constraintSize({ maxWidth: MAX_COL }).margin({ top: 16, bottom: 10 })

      Row({ space: 8 }) {
        // 卡组过滤:Anki 浏览器左侧栏的手机版
        Select(this.filterOptions())
          .selected(this.filterIndex())
          .value(this.filterLabel())
          .font({ size: 14 })
          .constraintSize({ maxWidth: '45%' })
          .onSelect((index: number) => {
            this.filterDeck = index === 0 ? 0 : this.decks[index - 1].id;
            this.reload();
          })
        Search({ value: this.query, placeholder: L(this.lang).searchHint })
          .layoutWeight(1).height(40)
          .onChange((v: string) => {
            this.query = v;
            this.reload();
          })
      }
      .width('90%').constraintSize({ maxWidth: MAX_COL }).margin({ bottom: 8 })

      Text(this.status.length > 0 ? this.status : fmt(L(this.lang).matchCount, this.total))
        .fontSize(11).fontColor('#8A8A8E').width('90%').constraintSize({ maxWidth: MAX_COL }).margin({ bottom: 6 })

      if (this.rows.length === 0) {
        Text(this.decks.length === 0 ? L(this.lang).needDeckFirst : L(this.lang).noMatch)
          .fontSize(14).fontColor('#8A8A8E').margin({ top: 40 })
      } else {
        List({ space: 8 }) {
          // 一本书可能上千张卡:LazyForEach 只建可视区 + cachedCount 那几行。
          // key 带上 gen 与下标:行的 @Builder 按下标取数据,重查后必须整体重建
          LazyForEach(this.source, (r: BrowseRow, idx: number) => {
            ListItem() {
              this.row(idx)
            }
          }, (r: BrowseRow, idx: number) => `${this.gen}:${idx}:${r.cardId}`)
        }
        .cachedCount(6)
        .layoutWeight(1).width('90%').constraintSize({ maxWidth: MAX_COL })
        .scrollBar(BarState.Auto)
        // 滑到最后一行就加载下一批(每批张数在「高级设置 → 浏览」里)
        .onReachEnd(() => this.loadMore())
      }
    }
    .width('100%').height('100%').backgroundColor('#F2F2F7')
  }

  build() {
    Navigation(this.stack) {
      this.listPage()
    }
    .navDestination(browseRoutes)
    .hideTitleBar(true)
    .hideToolBar(true)
    .mode(isSplit(this.bp) ? NavigationMode.Split : NavigationMode.Stack)
    .navBarWidth(SIDE_W + 60)
    .width('100%').height('100%')
  }
}

// ======================================================================== 预览

@Component
struct CardPreviewPage {
  row: BrowseRow = {
    cardId: 0, noteId: 0, deckId: 0, deckName: '', type: 0,
    title: '', front: '', back: '', due: 0, reps: 0,
  };
  private stack: NavPathStack | null = null;
  @StorageLink(SK_LANG) lang: string = LANG_ZH;

  /** 正面按「挖空未揭开」渲染,和作答时看到的一样 */
  @Builder
  frontView() {
    if (hasMath(this.row.front)) {
      MathText({ source: renderCloze(this.row.front, false), fontPx: 17, lineHeightPx: 27 })
    } else {
      MarkupText({ source: renderCloze(this.row.front, false), fontPx: 17, lineHeightPx: 27, color: '#1C1C1E' })
    }
  }

  @Builder
  backView() {
    if (hasMath(this.row.back)) {
      MathText({ source: this.row.back, fontPx: 15, lineHeightPx: 24 })
    } else {
      MarkupText({ source: this.row.back, fontPx: 15, lineHeightPx: 24, color: '#48484A' })
    }
  }

  build() {
    NavDestination() {
      Column() {
        Scroll() {
          Column({ space: 12 }) {
            Row({ space: 8 }) {
              Text(typeLabelOf(this.lang, this.row.type))
                .fontSize(11).fontColor(Color.White)
                .backgroundColor(TYPE_TINT[typeIdx(this.row.type)])
                .borderRadius(4).padding({ left: 6, right: 6, top: 1, bottom: 1 })
              Text(this.row.deckName).fontSize(12).fontColor('#8A8A8E')
            }
            .width('100%')
            if (this.row.title.length > 0) {
              Text(this.row.title).fontSize(12).fontColor('#8A8A8E').width('100%')
            }
            Text(L(this.lang).front).fontSize(11).fontColor('#B0B7C3').width('100%')
            this.frontView()
            Divider().color('#E5E5EA')
            Text(L(this.lang).back).fontSize(11).fontColor('#B0B7C3').width('100%')
            this.backView()
          }
          .width('100%').padding(16)
        }
        .layoutWeight(1).width('90%')
        .backgroundColor(Color.White).borderRadius(12).align(Alignment.Top)

        Button(L(this.lang).edit)
          .width('90%').height(46).fontSize(16).margin({ top: 12, bottom: 16 })
          .onClick(() => {
            this.stack?.pushPath({
              name: ROUTE_EDIT,
              param: new EditArgs(this.row.noteId, this.row.deckId, this.row.front, this.row.back, this.row.cardId),
            });
          })
      }
      .width('100%').height('100%')
    }
    .title(L(this.lang).previewTitle)
    .backgroundColor('#F2F2F7')
    .onReady((ctx: NavDestinationContext) => { this.stack = ctx.pathStack; })
  }
}

// ======================================================================== 编辑 / 新建

@Component
struct CardEditPage {
  args: EditArgs = new EditArgs(0, 0, '', '');
  private stack: NavPathStack | null = null;
  @StorageLink(SK_LANG) lang: string = LANG_ZH;

  @State private front: string = '';
  @State private back: string = '';
  @State private deckId: number = 0;
  @State private decks: DeckRow[] = [];
  @State private error: string = '';
  @State private confirmDelete: boolean = false;

  aboutToAppear(): void {
    this.front = this.args.front;
    this.back = this.args.back;
    this.deckId = this.args.deckId;
    try {
      this.decks = appStore().getDb().listDecks(Date.now());
    } catch (e) {
      this.error = fmt(L(this.lang).readFailed, `${e}`);
    }
  }

  private isNew(): boolean {
    return this.args.noteId === 0;
  }

  private deckName(): string {
    for (const d of this.decks) {
      if (d.id === this.deckId) {
        return d.name;
      }
    }
    return '';
  }

  private deckOptions(): SelectOption[] {
    const out: SelectOption[] = [];
    for (const d of this.decks) {
      out.push({ value: d.name });
    }
    return out;
  }

  private deckIndex(): number {
    for (let i = 0; i < this.decks.length; i++) {
      if (this.decks[i].id === this.deckId) {
        return i;
      }
    }
    return 0;
  }

  /** 新建 / 删除之后回到浏览列表(分栏时右栏由列表自动补上第一张) */
  private finish(): void {
    appStore().bump();
    this.stack?.clear();
  }

  /**
   * 改完一张已有的卡:关掉编辑页,底下那层预览换成新内容 —— 还停在这张卡上,
   * 列表的高亮也不丢。预览页的 row 是入参快照,只能整页替换。
   */
  private backToPreview(cardId: number): void {
    appStore().bump();
    const st = this.stack;
    if (st === null) {
      return;
    }
    const row: BrowseRow | null = cardId === 0 ? null : appStore().getDb().browseRow(cardId);
    st.pop(false);
    if (row !== null && st.size() > 0 && st.getAllPathName()[st.size() - 1] === ROUTE_PREVIEW) {
      st.replacePath({ name: ROUTE_PREVIEW, param: row }, false);
    }
  }

  private save(): void {
    const name: string = this.deckName();
    if (name.length === 0) {
      this.error = L(this.lang).needDeckFirst;
      return;
    }
    let parsed: ParsedCard;
    try {
      parsed = parseOneCard(name, this.front, this.back);
    } catch (e) {
      this.error = e instanceof QuizifyError ? e.message : fmt(L(this.lang).importFailed, `${e}`);
      return;
    }
    try {
      const db = appStore().getDb();
      const now: number = Date.now();
      if (this.isNew()) {
        // 同一牌组里标识键重复会撞上 notes.fingerprint 的 UNIQUE:先问一声,给出能看懂的提示
        if (db.hasCardKey(name, parsed.key)) {
          this.error = fmt(L(this.lang).dupCardKey, parsed.key);
          return;
        }
        db.insertManualCard(this.deckId, name, parsed, now);
        this.finish();
      } else {
        db.updateNoteText(this.args.noteId, parsed, now);
        this.backToPreview(this.args.cardId);
      }
    } catch (e) {
      this.error = fmt(L(this.lang).saveFailed, `${e}`);
    }
  }

  private doDelete(): void {
    try {
      appStore().getDb().deleteNote(this.args.noteId);
      this.finish();
    } catch (e) {
      this.error = fmt(L(this.lang).saveFailed, `${e}`);
    }
  }

  build() {
    NavDestination() {
      // 不放进 Scroll:正面 / 背面两个输入框按 3:2 分掉剩下的高度,拉满整栏。
      // 内容多了在输入框里面滚
      Column() {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Text(L(this.lang).putInDeck).fontSize(12).fontColor('#8A8A8E')
            if (this.isNew()) {
              // 新建才能选牌组。改已有卡片的牌组是「换组」,另一回事,暂不做
              Select(this.deckOptions())
                .selected(this.deckIndex())
                .value(this.deckName())
                .font({ size: 14 })
                .onSelect((index: number) => { this.deckId = this.decks[index].id; })
            } else {
              Text(this.deckName()).fontSize(14).fontColor('#1C1C1E')
            }
          }
          .width('100%')

          Text(L(this.lang).front).fontSize(12).fontColor('#8A8A8E').width('100%')
          TextArea({ text: this.front, placeholder: L(this.lang).frontPlaceholder })
            .layoutWeight(3).constraintSize({ minHeight: 120 }).fontSize(15)
            .onChange((v: string) => { this.front = v; })

          Text(L(this.lang).back).fontSize(12).fontColor('#8A8A8E').width('100%')
          TextArea({ text: this.back, placeholder: L(this.lang).backPlaceholder })
            .layoutWeight(2).constraintSize({ minHeight: 96 }).fontSize(15)
            .onChange((v: string) => { this.back = v; })

          if (this.error.length > 0) {
            Text(this.error).fontSize(12).fontColor('#E5544B').width('100%')
          }

          Button(L(this.lang).save).width('100%').height(44)
            .onClick(() => this.save())

          if (!this.isNew()) {
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
        .width('90%').height('100%').padding({ top: 8, bottom: 16 })
      }
      .width('100%').height('100%')
    }
    .title(this.isNew() ? L(this.lang).newCardTitle : L(this.lang).editCardTitle)
    .backgroundColor('#F2F2F7')
    .onReady((ctx: NavDestinationContext) => { this.stack = ctx.pathStack; })
  }
}
