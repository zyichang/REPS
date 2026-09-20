/**
 * 学习页:选择是否开始 → 逐张复习 → 评级 → 完成。
 *
 * ArkUI 铁律:UI 只能依赖 @State / @StorageLink。
 * 所有要显示的内容都摊平成 @State,@Builder 只接常量下标。
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ImportResult, importFromPicker } from '../data/Importer';
import { ReviewCardRow, splitOptions } from '../data/Schema';
import { CardState, GRADE_COLOR, GRADE_LABEL, Grade, PHASE_LABEL } from '../model/Models';
import { SK_TICK, appStore } from '../store/AppStore';
import { formatInterval, newCardState, schedule } from '../srs/Srs';

const DOMAIN: number = 0x0A01;
const TAG: string = 'REPS-Study';

enum Stage {
  Landing = 0,
  Card = 1,
  Done = 2
}

@Component
export struct StudyPage {
  /** 任何设置或卡组变动都会递增它,从而驱动本页重算计数 */
  @StorageLink(SK_TICK) tick: number = 0;

  @State private stage: Stage = Stage.Landing;
  @State private status: string = '';
  @State private totalCards: number = 0;
  @State private dueCards: number = 0;
  @State private newCards: number = 0;
  @State private deckLabel: string = '全部卡组';

  @State private cardId: number = 0;
  @State private cardStem: string = '';
  @State private cardOptions: string[] = [];
  @State private cardBack: string = '';
  @State private cardAnswer: string = '';
  @State private revealed: boolean = false;

  @State private lastLine: string = '';
  @State private remaining: number = 0;
  @State private answered: number = 0;
  @State private busy: boolean = false;

  private queue: number[] = [];

  aboutToAppear(): void {
    this.refresh();
  }

  /** tick 变化时重算 —— 卡组切换、设置修改都走这里 */
  onTickChange(): void {
    if (this.stage === Stage.Landing) {
      this.refresh();
    }
  }

  /** 计数一律从数据库重算,内存不另存一份 */
  private refresh(): void {
    const st = appStore();
    if (!st.isReady()) {
      return;
    }
    try {
      const db = st.getDb();
      const now: number = Date.now();
      const deckId: number = st.currentDeckId;
      this.totalCards = db.cardCount();
      this.dueCards = db.dueCardIdsInDeck(deckId, now, 100000).length;
      this.newCards = db.newCardIdsInDeck(deckId, 100000).length;
      this.deckLabel = deckId === 0 ? '全部卡组' : db.deckPath(deckId);
      if (this.totalCards === 0) {
        this.status = '还没有卡片,先导入一个文件';
      }
    } catch (e) {
      this.status = `读取失败: ${e}`;
    }
  }

  private async onImport(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.status = '正在导入…';
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const r: ImportResult = await importFromPicker(ctx, appStore().getDb());
      if (r.ok) {
        const fallback = r.usedFallbackDeck ? '(无 front matter,卡组名取自文件名)' : '';
        this.status = `已导入 ${r.cardsAdded} 张卡到「${r.deck}」${fallback}`;
        appStore().bump();
        this.refresh();
      } else {
        this.status = r.error === '已取消' ? '' : `导入失败:${r.error}`;
      }
    } catch (e) {
      this.status = `导入出错: ${e}`;
    } finally {
      this.busy = false;
    }
  }

  /**
   * 今日集合在这里**一次定好**,之后不再追加。
   * 复习量受硬上限约束,新卡受每日额度约束 —— 两者都来自设置。
   */
  private startSession(): void {
    const st = appStore();
    const db = st.getDb();
    const now: number = Date.now();
    const deckId: number = st.currentDeckId;

    const due: number[] = db.dueCardIdsInDeck(deckId, now, st.reviewLimit);
    const fresh: number[] = db.newCardIdsInDeck(deckId, st.newPerDay);
    this.queue = due.concat(fresh);
    this.answered = 0;
    this.lastLine = '';

    if (this.queue.length === 0) {
      this.stage = Stage.Done;
      return;
    }
    this.nextCard();
  }

  private nextCard(): void {
    this.revealed = false;
    if (this.queue.length === 0) {
      this.refresh();
      this.stage = Stage.Done;
      return;
    }
    const id: number = this.queue.shift() as number;
    const row: ReviewCardRow | null = appStore().getDb().loadReviewCard(id);
    if (row === null) {
      this.nextCard();
      return;
    }
    this.cardId = id;
    this.cardStem = row.front;
    this.cardOptions = splitOptions(row.options);
    this.cardBack = row.back;
    this.cardAnswer = row.answer;
    this.remaining = this.queue.length + 1;
    this.stage = Stage.Card;
  }

  private rate(grade: Grade): void {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const st = appStore();
      const db = st.getDb();
      const now: number = Date.now();
      const prev: CardState | null = db.loadState(this.cardId);
      const base: CardState = prev !== null ? prev : newCardState(this.cardId, now);
      const r = schedule(base, grade, now, true);

      db.saveState(r.state);
      db.logReview({
        id: 0, cardId: this.cardId, ts: now, grade: grade as number,
        stabilityBefore: r.stabilityBefore, elapsedDays: r.elapsedDays,
        retrievability: r.retrievability, intervalDays: r.intervalDays,
        costMs: 0, algo: st.algo,
      });

      this.answered++;
      this.lastLine = `${GRADE_LABEL[grade as number]} · ${PHASE_LABEL[r.state.phase]}` +
        ` · 下次 ${formatInterval(r.intervalDays)}后`;

      // 还在分钟级步进的卡,今天还会再来一次
      if (r.intervalDays < 1) {
        this.queue.push(this.cardId);
      }
      this.nextCard();
    } catch (e) {
      this.status = `保存失败: ${e}`;
      hilog.error(DOMAIN, TAG, '评级失败 %{public}s', String(e));
    } finally {
      this.busy = false;
    }
  }

  /** 参数只接常量下标,文字与颜色都在内部取 —— WordSnap 踩四次定下的写法 */
  @Builder
  gradeButton(grade: number) {
    Button(GRADE_LABEL[grade])
      .fontSize(15)
      .fontColor(Color.White)
      .backgroundColor(GRADE_COLOR[grade])
      .layoutWeight(1)
      .height(46)
      .onClick(() => this.rate(grade as Grade))
  }

  @Builder
  landing() {
    Column({ space: 14 }) {
      Text('刻意重复').fontSize(30).fontWeight(FontWeight.Bold)
      Text(this.deckLabel).fontSize(13).fontColor('#8A8A8E')

      Column({ space: 4 }) {
        Text(`${this.dueCards + this.newCards}`).fontSize(44).fontWeight(FontWeight.Bold)
        Text('今天要做的一组').fontSize(13).fontColor('#8A8A8E')
        Row({ space: 18 }) {
          Text(`待复习 ${this.dueCards}`).fontSize(14).fontColor('#E5544B')
          Text(`新卡 ${this.newCards}`).fontSize(14).fontColor('#4A90D9')
        }.margin({ top: 6 })
        Text(`共 ${this.totalCards} 张卡片`).fontSize(12).fontColor('#B0B7C3')
          .margin({ top: 2 })
      }
      .width('86%').padding(20).borderRadius(16).backgroundColor('#F5F5F7')

      if (this.status.length > 0) {
        Text(this.status).fontSize(13).fontColor('#48484A')
          .width('86%').textAlign(TextAlign.Center)
      }

      Button('开始学习')
        .width('86%').height(48).fontSize(16)
        .enabled(this.dueCards + this.newCards > 0)
        .onClick(() => this.startSession())

      Button('导入 Markdown 文件')
        .width('86%').height(44).fontSize(15)
        .backgroundColor('#E5E5EA').fontColor('#1C1C1E')
        .enabled(!this.busy)
        .onClick(() => this.onImport())
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center)
  }

  @Builder
  cardView() {
    Column() {
      Row() {
        Text(this.deckLabel).fontSize(12).fontColor('#8A8A8E').layoutWeight(1)
        Text(`剩 ${this.remaining}`).fontSize(12).fontColor('#8A8A8E')
      }
      .width('90%').margin({ top: 10, bottom: 4 })

      if (this.lastLine.length > 0) {
        Text(this.lastLine).fontSize(11).fontColor('#8A8A8E')
          .width('90%').margin({ bottom: 4 })
      }

      Scroll() {
        Column({ space: 12 }) {
          Text(this.cardStem).fontSize(17).lineHeight(26).width('100%')

          if (this.cardOptions.length > 0) {
            Column({ space: 8 }) {
              ForEach(this.cardOptions, (opt: string) => {
                Text(opt).fontSize(15).lineHeight(23).width('100%')
                  .padding({ left: 12, right: 12, top: 9, bottom: 9 })
                  .borderRadius(8).backgroundColor('#F5F5F7')
              })
            }.width('100%')
          }

          if (this.revealed) {
            Divider().margin({ top: 4, bottom: 4 })
            if (this.cardAnswer.length > 0) {
              Text(`答案 ${this.cardAnswer}`).fontSize(17)
                .fontWeight(FontWeight.Bold).fontColor('#2E9E63').width('100%')
            }
            Text(this.cardBack).fontSize(15).lineHeight(24).fontColor('#48484A').width('100%')
          }
        }
        .width('100%').padding({ left: 4, right: 4, bottom: 12 })
      }
      .layoutWeight(1).width('90%').align(Alignment.Top)

      if (!this.revealed) {
        Button('显示答案')
          .width('90%').height(48).fontSize(16).margin({ bottom: 14 })
          .onClick(() => { this.revealed = true; })
      } else {
        Row({ space: 8 }) {
          this.gradeButton(0)
          this.gradeButton(1)
          this.gradeButton(2)
          this.gradeButton(3)
        }
        .width('90%').margin({ bottom: 14 })
      }
    }
    .width('100%').height('100%')
  }

  @Builder
  done() {
    Column({ space: 12 }) {
      Text('今天的一组做完了').fontSize(22).fontWeight(FontWeight.Bold)
      Text(`本次作答 ${this.answered} 次`).fontSize(14).fontColor('#8A8A8E')
      Text(`剩余待复习 ${this.dueCards} · 新卡 ${this.newCards}`)
        .fontSize(13).fontColor('#8A8A8E')
      Button('回到首页')
        .width('70%').height(44).fontSize(15).margin({ top: 10 })
        .onClick(() => { this.refresh(); this.stage = Stage.Landing; })
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center)
  }

  build() {
    Column() {
      if (this.stage === Stage.Landing) {
        this.landing()
      } else if (this.stage === Stage.Card) {
        this.cardView()
      } else {
        this.done()
      }
    }
    .width('100%').height('100%').backgroundColor('#FFFFFF')
  }
}
