/**
 * 主页面:导入 → 复习 → 评级。
 *
 * 本项目的 ArkUI 铁律(WordSnap 踩过四次):
 * **UI 只能依赖 @State / @StorageLink,绝不能依赖普通对象字段。**
 * 按值传参的 @Builder 不会响应更新,而编译器完全不报错。
 * 所以下面每一处要显示的内容都摊平成 @State,@Builder 只接常量下标。
 *
 * 评级按钮用 FSRS 原生的四档(忘了/困难/良好/简单)。
 * WordSnap 当年收成三档,但那是背单词的取舍;REPS 主打排期透明,
 * 四档直通引擎,不做折叠。
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Database } from '../data/Database';
import { ImportResult, importFromPicker } from '../data/Importer';
import { ReviewCardRow, splitOptions } from '../data/Schema';
import { CardState, GRADE_COLOR, GRADE_LABEL, Grade, NoteType, PHASE_LABEL } from '../model/Models';
import { formatInterval, newCardState, schedule } from '../srs/Srs';

const DOMAIN: number = 0x0A01;
const TAG: string = 'REPS-Index';

/** 页面所处的阶段 */
enum Stage {
  Loading = 0,
  Landing = 1,
  Card = 2,
  Done = 3
}

@Entry
@Component
struct Index {
  // ---- 全局状态 ----
  @State private stage: Stage = Stage.Loading;
  @State private status: string = '正在打开数据库…';
  @State private totalCards: number = 0;
  @State private dueCards: number = 0;
  @State private newCards: number = 0;

  // ---- 当前卡片(摊平成 @State,不存对象) ----
  @State private cardId: number = 0;
  @State private cardDeck: string = '';
  @State private cardStem: string = '';
  @State private cardOptions: string[] = [];
  @State private cardBack: string = '';
  @State private cardAnswer: string = '';
  @State private cardType: number = 0;
  @State private revealed: boolean = false;

  // ---- 上一次作答的反馈 ----
  @State private lastLine: string = '';
  @State private busy: boolean = false;

  private db: Database = new Database();
  /** 本次会话的取卡队列。不是 @State:它不直接决定任何显示内容 */
  private queue: number[] = [];
  private answeredThisSession: number = 0;

  aboutToAppear(): void {
    this.boot();
  }

  private async boot(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      await this.db.init(ctx);
      this.refreshCounts();
      this.status = this.totalCards === 0 ? '还没有卡片,先导入一个文件' : '';
      this.stage = Stage.Landing;
    } catch (e) {
      this.status = `数据库打开失败: ${e}`;
      hilog.error(DOMAIN, TAG, '启动失败 %{public}s', String(e));
    }
  }

  /** 计数一律从数据库重算 —— 内存里另记一份,两边生命周期不一致时减法一定出错 */
  private refreshCounts(): void {
    const now: number = Date.now();
    this.totalCards = this.db.cardCount();
    this.dueCards = this.db.dueCount(now);
    this.newCards = this.db.newCount();
  }

  // ------------------------------------------------------------ 导入

  private async onImport(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.status = '正在导入…';
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const r: ImportResult = await importFromPicker(ctx, this.db);
      if (r.ok) {
        this.refreshCounts();
        const fallback = r.usedFallbackDeck ? '(文件没有 front matter,卡组名取自文件名)' : '';
        this.status = `已导入 ${r.cardsAdded} 张卡到「${r.deck}」${fallback}`;
      } else {
        this.status = r.error === '已取消' ? '' : `导入失败:${r.error}`;
      }
    } catch (e) {
      this.status = `导入出错: ${e}`;
    } finally {
      this.busy = false;
    }
  }

  // ------------------------------------------------------------ 会话

  /**
   * 开始学习。**今日集合在这里一次定好**,之后不再追加 ——
   * 这样永远不会出现「手上没卡但今天没做完」那种要靠倒计时兜的状态。
   * 完整的上限与新卡额度规则在 Task 8。
   */
  private startSession(): void {
    const now: number = Date.now();
    const due: number[] = this.db.dueCardIds(now, 2000);
    const fresh: number[] = this.db.newCardIds(20);
    this.queue = due.concat(fresh);
    this.answeredThisSession = 0;
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
      this.refreshCounts();
      this.stage = Stage.Done;
      return;
    }
    const id: number = this.queue.shift() as number;
    const row: ReviewCardRow | null = this.db.loadReviewCard(id);
    if (row === null) {
      // 卡片被删了之类,跳过
      this.nextCard();
      return;
    }
    this.cardId = id;
    this.cardDeck = row.deck_name;
    this.cardStem = row.front;
    this.cardOptions = splitOptions(row.options);
    this.cardBack = row.back;
    this.cardAnswer = row.answer;
    this.cardType = row.type;
    this.stage = Stage.Card;
  }

  private rate(grade: Grade): void {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const now: number = Date.now();
      const prev: CardState | null = this.db.loadState(this.cardId);
      const base: CardState = prev !== null ? prev : newCardState(this.cardId, now);
      const r = schedule(base, grade, now, true);

      this.db.saveState(r.state);
      this.db.logReview({
        id: 0, cardId: this.cardId, ts: now, grade: grade as number,
        stabilityBefore: r.stabilityBefore, elapsedDays: r.elapsedDays,
        retrievability: r.retrievability, intervalDays: r.intervalDays,
        costMs: 0, algo: 'fsrs',
      });

      this.answeredThisSession++;
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

  // ------------------------------------------------------------ 界面

  /**
   * 评级按钮。**参数只接常量下标**,文字与颜色都在内部从常量表取 ——
   * 这正是 WordSnap 踩了四次之后定下的写法。
   */
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
      Text('刻意重复').fontSize(32).fontWeight(FontWeight.Bold)
      Text('REPS').fontSize(13).fontColor('#8A8A8E').letterSpacing(3)

      Column({ space: 6 }) {
        Text(`${this.totalCards}`).fontSize(40).fontWeight(FontWeight.Bold)
        Text('张卡片').fontSize(13).fontColor('#8A8A8E')
        Row({ space: 18 }) {
          Text(`待复习 ${this.dueCards}`).fontSize(14).fontColor('#E5544B')
          Text(`新卡 ${this.newCards}`).fontSize(14).fontColor('#4A90D9')
        }.margin({ top: 4 })
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
      // 顶部:卡组与进度
      Row() {
        Text(this.cardDeck).fontSize(12).fontColor('#8A8A8E').layoutWeight(1)
        Text(`剩 ${this.queue.length + 1}`).fontSize(12).fontColor('#8A8A8E')
      }
      .width('90%').margin({ top: 8, bottom: 6 })

      if (this.lastLine.length > 0) {
        Text(this.lastLine).fontSize(11).fontColor('#8A8A8E')
          .width('90%').margin({ bottom: 6 })
      }

      Scroll() {
        Column({ space: 12 }) {
          // 题干
          Text(this.cardStem).fontSize(17).lineHeight(26).width('100%')

          // 选项(选择题才有)。答案字母不在这里,它在 cardAnswer 里,
          // 只有 revealed 之后才显示 —— 数据层已经把它从 front 里摘走了。
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
            Divider().margin({ top: 6, bottom: 6 })
            if (this.cardAnswer.length > 0) {
              Text(`答案 ${this.cardAnswer}`).fontSize(17)
                .fontWeight(FontWeight.Bold).fontColor('#2E9E63').width('100%')
            }
            Text(this.cardBack).fontSize(15).lineHeight(24).fontColor('#48484A').width('100%')
          }
        }
        .width('100%').padding({ left: 4, right: 4 })
      }
      .layoutWeight(1).width('90%').align(Alignment.Top)

      // 底部:未翻面只有一个「显示答案」,翻面后是四档评级
      if (!this.revealed) {
        Button('显示答案')
          .width('90%').height(48).fontSize(16)
          .margin({ bottom: 20 })
          .onClick(() => { this.revealed = true; })
      } else {
        Row({ space: 8 }) {
          this.gradeButton(0)
          this.gradeButton(1)
          this.gradeButton(2)
          this.gradeButton(3)
        }
        .width('90%').margin({ bottom: 20 })
      }
    }
    .width('100%').height('100%')
  }

  @Builder
  done() {
    Column({ space: 12 }) {
      Text('今天的一组做完了').fontSize(22).fontWeight(FontWeight.Bold)
      Text(`本次作答 ${this.answeredThisSession} 次`).fontSize(14).fontColor('#8A8A8E')
      Text(`剩余待复习 ${this.dueCards} · 新卡 ${this.newCards}`)
        .fontSize(13).fontColor('#8A8A8E')
      Button('回到首页')
        .width('70%').height(44).fontSize(15).margin({ top: 10 })
        .onClick(() => { this.refreshCounts(); this.stage = Stage.Landing; })
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center)
  }

  build() {
    Column() {
      if (this.stage === Stage.Loading) {
        Text(this.status).fontSize(14).fontColor('#8A8A8E')
      } else if (this.stage === Stage.Landing) {
        this.landing()
      } else if (this.stage === Stage.Card) {
        this.cardView()
      } else {
        this.done()
      }
    }
    .width('100%').height('100%').backgroundColor('#FFFFFF')
    .justifyContent(FlexAlign.Center)
  }
}
