/**
 * 统计页。**分两段,因为这些数字的口径不同:**
 *
 *   上半段「全部卡组」—— 总作答、保持率、学习天数、连续天数、18 周热力图、
 *   最近 7 天学习时长。这些是**全量历史**,与当前选哪本书无关。
 *
 *   下半段「当前课本」—— 未来 14 天复习量、掌握度分布。这两个只有落到具体
 *   一本书上才有意义:全库的「掌握度分布」混了五本书,看不出任何一本的进度。
 *
 * 之前这两段是混在一起的,而且**复习量预测和掌握度分布其实也是全局查询** ——
 * 不管切到哪本书都显示同一组数,页面却摆在「当前卡组」旁边,等于在骗人。
 *
 * 纪律:**每个显示出来的数字都必须能用一条 SQL 对上。**
 * WordSnap 的统计口径 bug 正是这样查出来的 —— 被忽略的词在分子里、
 * 不在分母里,于是「已学 91 / 3732」这种数字看着正常实则错位。
 *
 * 分桶不再在 TS 里做:总作答等要全量口径,全量分桶就得把整张 review_log
 * 读进内存。改走 SQL_DAY_STATS 按天聚合,日界锚点由 dayAnchor() 提供,
 * 所以 day 的含义与 dayIndex()、与学习页的「今天」仍是同一个定义。
 */

import { DayStat, dayAnchor, dayIndex } from '../data/Schema';
import { MASTERY_COLOR } from '../model/Models';
import { masteryOf } from '../srs/Srs';
import { SK_LANG, SK_TICK, appStore } from '../store/AppStore';
import { L, LANG_ZH, fmt, masteryLabels } from '../i18n/Strings';

/** 热力图显示最近多少周 */
const WEEKS: number = 18;
const CELL: number = 13;
const GAP: number = 3;
/**
 * 星期标签由语言表提供(用 | 分隔的七个)。热力图按周一起头,
 * 所以把语言表里以周日开头的那份转成周一开头。
 */
function weekdayLabels(lang: string): string[] {
  const seq: string[] = L(lang).weekdays.split('|');
  return [seq[1], seq[2], seq[3], seq[4], seq[5], seq[6], seq[0]];
}
/** 预测未来多少天 */
const FORECAST_DAYS: number = 14;
/** 学习时长柱状图显示最近多少天 */
const TIME_DAYS: number = 7;

@Component
export struct StatsPage {
  /** 界面文字跟随语言 */
  @StorageLink(SK_LANG) lang: string = LANG_ZH;
  /**
   * **@Watch 是必须的。** ArkUI 里 @StorageLink 的变化只触发重绘,
   * 不会自动调用 on<字段名>Change() —— 少了这个装饰器,界面会用旧值重绘,
   * 看起来像「切换了卡组但标题没变」。
   */
  @StorageLink(SK_TICK) @Watch('onTickChange') tick: number = 0;

  @State private totalReps: number = 0;
  @State private retention: number = 0;
  @State private studiedDays: number = 0;
  @State private streak: number = 0;
  /** 热力图:每格的作答次数,按 day 升序,长度 = WEEKS*7 */
  @State private heat: number[] = [];
  /** 未来 FORECAST_DAYS 天每天的到期量 */
  @State private forecast: number[] = [];
  /** 掌握度五档的卡片数(**只算当前课本**) */
  @State private mastery: number[] = [0, 0, 0, 0, 0];
  /** 最近 TIME_DAYS 天每天的学习毫秒数 */
  @State private times: number[] = [];
  /** 下半段的标题要写清楚是哪本书 */
  @State private deckLabel: string = '';
  @State private status: string = '';

  aboutToAppear(): void {
    this.reload();
  }

  onTickChange(): void {
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
      const today: number = dayIndex(now);
      const cells: number = WEEKS * 7;
      const deckId: number = st.currentDeckId;

      // ---- 上半段:全部卡组,全量口径 ----
      // 一条按天聚合的查询同时供上四张卡片、热力图、时长柱状图使用
      const days: DayStat[] = db.dayStats(dayAnchor(now));
      const repsByDay = new Map<number, number>();
      const msByDay = new Map<number, number>();
      let total = 0;
      for (const d of days) {
        repsByDay.set(d.day, d.reps);
        msByDay.set(d.day, d.ms);
        total += d.reps;
      }
      this.totalReps = total;
      // 学习天数是**有作答的天数**,全量;不再受热力图窗口限制
      this.studiedDays = days.length;
      this.retention = db.retentionAll();

      const firstDay: number = today - cells + 1;
      const heat: number[] = [];
      for (let d = firstDay; d <= today; d++) {
        heat.push(repsByDay.get(d) ?? 0);
      }
      this.heat = heat;

      // 连续学习天数:从今天往回数,遇到 0 就停。全量,不再被窗口截断
      let streak = 0;
      for (let d = today; ; d--) {
        if ((repsByDay.get(d) ?? 0) > 0) {
          streak++;
        } else {
          break;
        }
      }
      this.streak = streak;

      const times: number[] = [];
      for (let i = TIME_DAYS - 1; i >= 0; i--) {
        times.push(msByDay.get(today - i) ?? 0);
      }
      this.times = times;

      // ---- 下半段:只算当前课本 ----
      this.deckLabel = deckId === 0
        ? L(this.lang).allDecks : db.deckName(deckId);

      const to: number = now + FORECAST_DAYS * 86400000;
      const dues: number[] = db.dueForecastInDeck(deckId, now, to);
      const fc: number[] = [];
      for (let i = 0; i < FORECAST_DAYS; i++) {
        fc.push(0);
      }
      for (const due of dues) {
        const offset: number = dayIndex(due) - today;
        if (offset >= 0 && offset < FORECAST_DAYS) {
          fc[offset] = fc[offset] + 1;
        }
      }
      this.forecast = fc;

      // 掌握度分布。门槛只有一处定义 —— 引擎的 masteryOf(),
      // 这里绝不自己再写一套阈值,否则统计页与其他地方会慢慢说出不同的话。
      const counts: number[] = [0, 0, 0, 0, 0];
      for (const sb of db.stabilitiesInDeck(deckId)) {
        const level: number = masteryOf(sb) as number;
        counts[level] = counts[level] + 1;
      }
      this.mastery = counts;
      this.status = this.totalReps === 0 ? L(this.lang).noReviewYet : '';
    } catch (e) {
      this.status = fmt(L(this.lang).readFailed, `${e}`);
    }
  }

  /** 作答次数 -> 颜色深浅。0 次是空格,不是最浅的绿 */
  private heatColor(n: number): string {
    if (n <= 0) {
      return '#EFEFF4';
    }
    if (n < 5) {
      return '#C8E6D0';
    }
    if (n < 15) {
      return '#8FD0A6';
    }
    if (n < 40) {
      return '#4FB477';
    }
    return '#2E9E63';
  }

  /** 一列 = 一周七天。只接常量下标 */
  @Builder
  heatColumn(w: number) {
    Column({ space: GAP }) {
      ForEach([0, 1, 2, 3, 4, 5, 6], (row: number) => {
        Rect({ width: CELL, height: CELL })
          .radius(2.5)
          .fill(this.heatColor(this.heat[w * 7 + row] ?? 0))
      })
    }
  }

  @Builder
  statCard(which: number) {
    Column({ space: 3 }) {
      Text(which === 0 ? `${this.totalReps}`
        : which === 1 ? `${Math.round(this.retention * 100)}%`
        : which === 2 ? `${this.studiedDays}`
        : `${this.streak}`)
        .fontSize(22).fontWeight(FontWeight.Bold)
      Text(which === 0 ? L(this.lang).totalAnswers
        : which === 1 ? L(this.lang).retentionRate
        : which === 2 ? L(this.lang).studyDays
        : L(this.lang).streakDays)
        .fontSize(11).fontColor('#8A8A8E')
    }
    .layoutWeight(1).padding({ top: 12, bottom: 12 })
    .borderRadius(10).backgroundColor('#F5F5F7')
  }

  /**
   * 掌握度一档 = 一张小卡片,和上面四张统计卡片同一种样式。
   * 只接常量下标 —— 数字与文案都在内部从状态取。
   */
  @Builder
  masteryCard(level: number) {
    Column({ space: 3 }) {
      Text(`${this.mastery[level]}`).fontSize(19).fontWeight(FontWeight.Bold)
        .fontColor(MASTERY_COLOR[level])
      Text(masteryLabels(this.lang)[level]).fontSize(10).fontColor('#8A8A8E')
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1).padding({ top: 10, bottom: 10 })
    .borderRadius(10).backgroundColor('#F5F5F7')
  }

  /** 一段小标题 */
  @Builder
  sectionTitle(which: number) {
    Column({ space: 2 }) {
      Text(which === 0 ? L(this.lang).sectionAll : L(this.lang).sectionBook)
        .fontSize(13).fontColor('#8A8A8E').width('100%')
      if (which === 1) {
        Text(this.deckLabel).fontSize(16).fontWeight(FontWeight.Medium).width('100%')
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start).margin({ top: 4 })
  }

  /** 学习时长的一根柱子。只接常量下标 */
  @Builder
  timeBar(i: number) {
    Column({ space: 2 }) {
      Text(this.timeLabel(i)).fontSize(9).fontColor('#8A8A8E')
      Rect({ width: 18, height: this.timeHeight(i) })
        .radius(2).fill('#2E9E63')
    }
    .layoutWeight(1).justifyContent(FlexAlign.End)
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Text(L(this.lang).statsTitle).fontSize(24).fontWeight(FontWeight.Bold)
          .width('100%').margin({ top: 14 })

        if (this.status.length > 0) {
          Text(this.status).fontSize(13).fontColor('#8A8A8E').width('100%')
        }

        // ================= 全部卡组:与选哪本书无关 =================
        this.sectionTitle(0)

        Row({ space: 8 }) {
          this.statCard(0)
          this.statCard(1)
          this.statCard(2)
          this.statCard(3)
        }
        .width('100%')

        // ---- 热力图 ----
        Column({ space: 8 }) {
          Text(fmt(L(this.lang).recentWeeks, WEEKS)).fontSize(14).fontWeight(FontWeight.Medium).width('100%')
          Row({ space: GAP }) {
            Column({ space: GAP }) {
              ForEach(weekdayLabels(this.lang), (d: string) => {
                Text(d).fontSize(9).fontColor('#B0B7C3')
                  .width(12).height(CELL).textAlign(TextAlign.Center)
              })
            }
            Scroll() {
              Row({ space: GAP }) {
                ForEach(this.weekIndexes(), (w: number) => {
                  this.heatColumn(w)
                })
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .layoutWeight(1)
          }
          .width('100%').alignItems(VerticalAlign.Top)
        }
        .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')

        // ---- 最近 7 天学习时长 ----
        // 用的是 review_log.cost_ms,也就是做计时判档时记下的真实答题耗时,
        // 不是「打开应用多久」——后者会把发呆也算成学习。
        Column({ space: 8 }) {
          Text(L(this.lang).studyTime).fontSize(14)
            .fontWeight(FontWeight.Medium).width('100%')
          if (this.hasAnyTime()) {
            Row({ space: 4 }) {
              this.timeBar(0)
              this.timeBar(1)
              this.timeBar(2)
              this.timeBar(3)
              this.timeBar(4)
              this.timeBar(5)
              this.timeBar(6)
            }
            .width('100%').height(84).alignItems(VerticalAlign.Bottom)
            Row({ space: 4 }) {
              ForEach(this.dayLabels(), (d: string) => {
                Text(d).fontSize(9).fontColor('#B0B7C3')
                  .layoutWeight(1).textAlign(TextAlign.Center)
              })
            }
            .width('100%')
          } else {
            Text(L(this.lang).noTimeYet).fontSize(12).fontColor('#B0B7C3')
              .width('100%').padding({ top: 8, bottom: 8 })
          }
        }
        .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')

        // ================= 当前课本:随切换课本而变 =================
        this.sectionTitle(1)

        // ---- 复习量预测 ----
        Column({ space: 8 }) {
          Text(fmt(L(this.lang).forecastDays, FORECAST_DAYS)).fontSize(14)
            .fontWeight(FontWeight.Medium).width('100%')
          Row({ space: 4 }) {
            ForEach(this.forecast, (n: number) => {
              Column() {
                Text(n > 0 ? `${n}` : '').fontSize(9).fontColor('#8A8A8E')
                Rect({ width: 14, height: this.barHeight(n) })
                  .radius(2).fill('#4A90D9').margin({ top: 2 })
              }
              .layoutWeight(1).justifyContent(FlexAlign.End)
            })
          }
          .width('100%').height(90).alignItems(VerticalAlign.Bottom)
        }
        .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')

        // ---- 掌握度分布 ----
        Column({ space: 8 }) {
          Text(L(this.lang).masterySpread).fontSize(14).fontWeight(FontWeight.Medium).width('100%')
          Row({ space: 6 }) {
            this.masteryCard(0)
            this.masteryCard(1)
            this.masteryCard(2)
            this.masteryCard(3)
            this.masteryCard(4)
          }
          .width('100%')
        }
        .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')
      }
      .width('90%').padding({ bottom: 20 })
    }
    .width('100%').height('100%').backgroundColor('#FFFFFF').align(Alignment.Top)
  }

  /** 这 7 天有没有任何学习记录 */
  private hasAnyTime(): boolean {
    for (const ms of this.times) {
      if (ms > 0) {
        return true;
      }
    }
    return false;
  }

  /** 柱子上的时长文字。不足一分钟就不写,免得一排「0分」 */
  private timeLabel(i: number): string {
    const ms: number = this.times[i] ?? 0;
    const min: number = Math.round(ms / 60000);
    return min > 0 ? `${min}${L(this.lang).minutesShort}` : '';
  }

  /** 时长柱高,按这 7 天的最大值归一 */
  private timeHeight(i: number): number {
    let max = 1;
    for (const ms of this.times) {
      if (ms > max) {
        max = ms;
      }
    }
    const ms: number = this.times[i] ?? 0;
    return ms <= 0 ? 2 : Math.max(3, Math.round((ms / max) * 56));
  }

  /** 柱子下面的星期标签,最后一根是今天 */
  private dayLabels(): string[] {
    const seq: string[] = L(this.lang).weekdays.split('|');
    const out: string[] = [];
    for (let i = TIME_DAYS - 1; i >= 0; i--) {
      const d = new Date(Date.now() - i * 86400000);
      out.push(seq[d.getDay()]);
    }
    return out;
  }

  private weekIndexes(): number[] {
    const out: number[] = [];
    for (let i = 0; i < WEEKS; i++) {
      out.push(i);
    }
    return out;
  }

  /** 柱高按当前窗口的最大值归一,最高 60 */
  private barHeight(n: number): number {
    let max = 1;
    for (const v of this.forecast) {
      if (v > max) {
        max = v;
      }
    }
    return n <= 0 ? 2 : Math.max(3, Math.round((n / max) * 60));
  }
}
