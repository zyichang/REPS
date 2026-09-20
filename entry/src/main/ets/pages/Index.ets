/**
 * 首页。
 *
 * Task 3 阶段的作用:证明「排期状态能落库、能读回、due 会推进」这条链路在设备上成立。
 * 真正的复习界面在 Task 5 接进来,届时这一页会被替换。
 *
 * 本项目的 ArkUI 铁律(WordSnap 踩过四次):
 * UI 只能依赖 @State / @StorageLink,绝不能依赖普通对象字段——
 * 按值传参的 @Builder 不会响应更新。所以下面每一行要显示的文字都是 @State。
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Database } from '../data/Database';
import { CardState, Grade, NoteType, PHASE_LABEL } from '../model/Models';
import { formatInterval, newCardState, schedule } from '../srs/Srs';

const DOMAIN: number = 0x0A01;
const TAG: string = 'REPS-Index';

@Entry
@Component
struct Index {
  @State private tagline: string = '把一本书变成一整副卡组';
  @State private dbStatus: string = '正在打开数据库…';
  @State private cardLine: string = '';
  @State private stateLine: string = '';
  @State private dueLine: string = '';
  @State private ok: boolean = false;

  private db: Database = new Database();

  aboutToAppear(): void {
    this.runSelfCheck();
  }

  /**
   * 设备侧自检:建库 → 造一张卡 → 评一次级 → 落盘 → 读回 → 看 due 是否推进。
   * 逻辑本身已由 devtest/schema_test.ts 的 47 条断言覆盖,
   * 这里验的是 relationalStore 这一层真的能跑。
   */
  private async runSelfCheck(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      await this.db.init(ctx);
      this.dbStatus = '数据库已就绪';

      const now: number = Date.now();

      // 库里还没有卡就造一张,避免每次启动都堆新卡
      let cardId: number;
      if (this.db.cardCount() === 0) {
        const deckId: number = this.db.ensureDeck('示例卡组', 0);
        const ids: number[] = this.db.insertNote(
          deckId, '示例卡组', NoteType.QA,
          '刻意重复的英文名是什么?', 'REPS —— 一天的量是 a set,一次作答是 a rep',
          '自检 (1)', 'self-check', 1, now,
        );
        cardId = ids[0];
      } else {
        const news: number[] = this.db.newCardIds(1);
        const dues: number[] = this.db.dueCardIds(now, 1);
        cardId = news.length > 0 ? news[0] : (dues.length > 0 ? dues[0] : 1);
      }
      this.cardLine = `共 ${this.db.cardCount()} 张卡,本次用 card_id = ${cardId}`;

      // 读不到状态说明是新卡
      const prev: CardState | null = this.db.loadState(cardId);
      const base: CardState = prev !== null ? prev : newCardState(cardId, now);

      const before: number = base.due;
      const r = schedule(base, Grade.Good, now, true);
      this.db.saveState(r.state);
      this.db.logReview({
        id: 0, cardId: cardId, ts: now, grade: Grade.Good as number,
        stabilityBefore: r.stabilityBefore, elapsedDays: r.elapsedDays,
        retrievability: r.retrievability, intervalDays: r.intervalDays,
        costMs: 0, algo: 'fsrs',
      });

      // 关键一步:从数据库读回,而不是用内存里那份
      const reloaded: CardState | null = this.db.loadState(cardId);
      if (reloaded === null) {
        this.stateLine = '读回失败:数据库里没有这张卡的状态';
        return;
      }

      this.stateLine = `${PHASE_LABEL[reloaded.phase]} · S=${reloaded.stability.toFixed(2)} 天` +
        ` · D=${reloaded.difficulty.toFixed(2)} · 第 ${reloaded.reps} 次`;
      this.dueLine = `下次 ${formatInterval(r.intervalDays)}后 ` +
        `(${this.hhmm(reloaded.due)})`;
      this.ok = reloaded.due > before && reloaded.reps > 0;

      hilog.info(DOMAIN, TAG, '自检完成, due %{public}d -> %{public}d', before, reloaded.due);
    } catch (e) {
      this.dbStatus = `自检失败: ${e}`;
      hilog.error(DOMAIN, TAG, '自检失败 %{public}s', String(e));
    }
  }

  private hhmm(ms: number): string {
    const d = new Date(ms);
    const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${d.getMonth() + 1}/${d.getDate()} ${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  build() {
    Column({ space: 10 }) {
      Text('刻意重复')
        .fontSize(34)
        .fontWeight(FontWeight.Bold)

      Text('REPS')
        .fontSize(15)
        .fontColor('#8A8A8E')
        .letterSpacing(3)

      Text(this.tagline)
        .fontSize(15)
        .fontColor('#48484A')
        .margin({ top: 4, bottom: 16 })

      Column({ space: 6 }) {
        Text(this.dbStatus).fontSize(14).fontColor('#48484A')
        Text(this.cardLine).fontSize(13).fontColor('#8A8A8E')
        Text(this.stateLine).fontSize(13).fontColor('#8A8A8E')
        Text(this.dueLine).fontSize(13).fontColor('#8A8A8E')
        Text(this.ok ? '排期已推进 ✓' : '')
          .fontSize(14)
          .fontColor('#2E9E63')
          .margin({ top: 6 })
      }
      .width('86%')
      .padding(16)
      .borderRadius(14)
      .backgroundColor('#F5F5F7')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#FFFFFF')
  }
}
