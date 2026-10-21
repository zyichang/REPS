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

import {
  DayStat, DeckRow, calendarCells, calendarDate, checkinStreak, dayAnchor, dayIndex, heatCells,
  weekdaySun0,
} from '../data/Schema';
import { MASTERY_COLOR } from '../model/Models';
import { masteryOf } from '../srs/Srs';
import { SK_LANG, SK_TICK, appStore } from '../store/AppStore';
import { L, LANG_ZH, fmt, masteryLabels } from '../i18n/Strings';
import { BP_SM, MAX_COL, SK_BP, isSplit } from './Layout';

/** 热力图显示最近多少周 */
/** 热力图至少显示多少周(手机上就是这么多,超出部分横向滑动) */
const WEEKS: number = 18;
const CELL: number = 13;
const GAP: number = 3;
/** 星期标签由语言表提供(用 | 分隔的七个),周日开头 —— 全应用的周都从周日开始 */
function weekdayLabels(lang: string): string[] {
  return L(lang).weekdays.split('|');
}
/** 预测未来多少天 */
const FORECAST_DAYS: number = 14;
/** 学习时长柱状图显示最近多少天 */
const TIME_DAYS: number = 7;

@Component
export struct StatsPage {
  /** 界面文字跟随语言 */
  @StorageLink(SK_LANG) lang: string = LANG_ZH;
  /** 断点:横屏平板两栏 */
  @StorageLink(SK_BP) bp: string = BP_SM;
  /**
   * **@Watch 是必须的。** ArkUI 里 @StorageLink 的变化只触发重绘,
   * 不会自动调用 on<字段名>Change() —— 少了这个装饰器,界面会用旧值重绘,
   * 看起来像「切换了卡组但标题没变」。
   */
  @StorageLink(SK_TICK) @Watch('onTickChange') tick: number = 0;

  @State private totalReps: number = 0;
  @State private retention: number = 0;
  @State private studiedDays: number = 0;
  /** 打卡月历:正在看的年 / 月(0~11),格子的日序号,打过卡的日子 */
  @State private calYear: number = new Date().getFullYear();
  @State private calMonth: number = new Date().getMonth();
  @State private calCells: number[] = [];
  /** 不是 @State(Set 不可观察),所以每次重读都递增 calGen,月历行的 key 带上它才会重建 */
  private checkins: Set<number> = new Set<number>();
  @State private calGen: number = 0;
  @State private today: number = 0;
  @State private streak: number = 0;
  /**
   * 热力图实际显示的周数。手机固定 WEEKS;平板按热力图区域的实际宽度能放下多少列就显示多少列
   * (见 onHeatWidth),横屏半栏和竖屏整栏各自铺满,不再右边空一大块。
   */
  @State private weeks: number = WEEKS;
  /** 按天的作答次数,reload 时取一次;周数变了直接用它重排格子,不必重查数据库 */
  private repsByDay: Map<number, number> = new Map<number, number>();
  /** 热力图:每格的作答次数,按 day 升序,长度 = weeks*7 */
  @State private heat: number[] = [];
  /** 未来 FORECAST_DAYS 天每天的到期量 */
  @State private forecast: number[] = [];
  /** 掌握度五档的卡片数(**只算当前课本**) */
  @State private mastery: number[] = [0, 0, 0, 0, 0];
  /** 最近 TIME_DAYS 天每天的学习毫秒数 */
  @State private times: number[] = [];
  /**
   * 下半段的卡组过滤:0 = 全部。只是看统计时的视角,不影响学习页 ——
   * 没有「当前卡组」这回事了(ADR-0004)。
   */
  @State private filterDeck: number = 0;
  @State private decks: DeckRow[] = [];
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
      this.decks = db.listDecks(now);
      // 过滤的那一组被删了:回到全部
      if (this.filterDeck !== 0 && this.decks.every((d: DeckRow) => d.id !== this.filterDeck)) {
        this.filterDeck = 0;
      }
      const deckId: number = this.filterDeck;

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
      // 学习天数 = **打卡天数**(用户自己说「今天就到这里」),不再是「有作答的天数」
      const checkinDays: number[] = db.checkinDays();
      this.checkins = new Set<number>(checkinDays);
      this.studiedDays = checkinDays.length;
      this.today = today;
      this.calCells = calendarCells(this.calYear, this.calMonth);
      this.calGen++;
      this.retention = db.retentionAll();

      // 按星期对齐:最后一列是本周,今天之后为 -1(见 Schema.heatCells)
      this.repsByDay = repsByDay;
      this.heat = heatCells(today, this.weeks, (d: number) => repsByDay.get(d) ?? 0);

      // 连续天数也按打卡算:漏一天不断,连漏两天才断(Schema.checkinStreak)
      this.streak = checkinStreak(checkinDays, today);

      const times: number[] = [];
      for (let i = TIME_DAYS - 1; i >= 0; i--) {
        times.push(msByDay.get(today - i) ?? 0);
      }
      this.times = times;

      // ---- 下半段:按所选卡组(默认全部) ----

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

  /** 作答次数 -> 颜色深浅。0 次是空格,不是最浅的蓝 */
  private heatColor(n: number): string {
    if (n < 0) {
      return 'rgba(0,0,0,0)';     // 今天之后:还没到,不画
    }
    if (n === 0) {
      return '#EFEFF4';
    }
    if (n < 5) {
      return '#DBE7FD';
    }
    if (n < 15) {
      return '#93B9F9';
    }
    if (n < 40) {
      return '#5B95F6';
    }
    return '#3B82F6';
  }

  // ---------------------------------------------------------------- 打卡月历

  private shiftMonth(delta: number): void {
    let m: number = this.calMonth + delta;
    let y: number = this.calYear;
    while (m < 0) { m += 12; y--; }
    while (m > 11) { m -= 12; y++; }
    this.calYear = y;
    this.calMonth = m;
    this.calCells = calendarCells(y, m);
  }

  /** 月份不能翻到未来 —— 未来没有打卡可看 */
  private canGoNext(): boolean {
    const now: Date = new Date();
    return this.calYear < now.getFullYear()
      || (this.calYear === now.getFullYear() && this.calMonth < now.getMonth());
  }

  private calRows(): number[] {
    const out: number[] = [];
    for (let r = 0; r < this.calCells.length / 7; r++) {
      out.push(r);
    }
    return out;
  }

  /** 月历的一格。**只接常量下标**:几号、是否本月、是否打卡都在内部现算 */
  @Builder
  calCell(idx: number) {
    Stack() {
      Text(`${calendarDate(this.calCells[idx] ?? 0)[2]}`)
        .fontSize(13)
        .fontColor(this.checkins.has(this.calCells[idx] ?? -1) ? Color.White
          : calendarDate(this.calCells[idx] ?? 0)[1] === this.calMonth ? '#1C1C1E' : '#C7C7CC')
    }
    // 手机上正方形(约 45vp)。平板上格子更宽,还按 1:1 就会长成 100vp 高的大格子:
    // 改成扁一点的宽高比,高度都在 45vp 上下,宽度仍跟着星期那一行对齐
    .layoutWeight(1).aspectRatio(this.bp === BP_SM ? 1 : isSplit(this.bp) ? 1.5 : 2).margin(2)
    .borderRadius(8)
    .backgroundColor(this.checkins.has(this.calCells[idx] ?? -1) ? '#10B981' : 'rgba(0,0,0,0)')
    .borderWidth(this.calCells[idx] === this.today ? 1.5 : 0)
    .borderColor('#3B82F6')
  }

  @Builder
  calRow(r: number) {
    Row() {
      this.calCell(r * 7)
      this.calCell(r * 7 + 1)
      this.calCell(r * 7 + 2)
      this.calCell(r * 7 + 3)
      this.calCell(r * 7 + 4)
      this.calCell(r * 7 + 5)
      this.calCell(r * 7 + 6)
    }
    .width('100%')
  }

  /**
   * 打卡统计:月历。第一行年月(可左右翻月),第二行星期(周日开头),下面是日期格。
   * 打过卡的日子是绿色,今天有蓝框;相邻月份的日子是浅灰字。
   * 这是**打卡**的记录,与热力图(作答量)互相独立。
   */
  @Builder
  checkinCalendar() {
    Column({ space: 8 }) {
      Row() {
        Text(L(this.lang).checkinCalendar).fontSize(14).fontWeight(FontWeight.Medium).layoutWeight(1)
        Text('‹').fontSize(22).fontColor('#3B82F6').width(36).textAlign(TextAlign.Center)
          .onClick(() => this.shiftMonth(-1))
        Text(fmt(L(this.lang).monthTitle, this.calYear, this.calMonth + 1))
          .fontSize(14).fontColor('#1C1C1E')
        Text('›').fontSize(22).width(36).textAlign(TextAlign.Center)
          .fontColor(this.canGoNext() ? '#3B82F6' : '#D0D3DA')
          .onClick(() => { if (this.canGoNext()) { this.shiftMonth(1); } })
      }
      .width('100%')
      Row() {
        ForEach(weekdayLabels(this.lang), (d: string) => {
          Text(d).fontSize(11).fontColor('#8A8A8E').layoutWeight(1).textAlign(TextAlign.Center)
        })
      }
      .width('100%')
      ForEach(this.calRows(), (r: number) => {
        this.calRow(r)
      }, (r: number) => `${this.calGen}-${this.calYear}-${this.calMonth}-${r}`)
    }
    .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')
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

  /** 一段小标题 */
  @Builder
  sectionTitle(which: number) {
    // 两段的分界:上「综合统计」按整个应用算(删了的牌组也在内,ADR-0005),
    // 下「进度统计」按所选牌组。标题用同一级字号,一眼看出是两块。
    // 卡组选择器和「进度统计」放在同一行的右边 —— 它本来就属于这个标题,
    // 单独占一行会把横屏平板的统计页撑出滚动条
    Row() {
      Text(which === 0 ? L(this.lang).sectionAll : L(this.lang).sectionBook)
        .fontSize(17).fontWeight(FontWeight.Bold).fontColor('#1C1C1E').layoutWeight(1)
      if (which === 1) {
        Select(this.filterOptions())
          .selected(this.filterIndex())
          .value(this.filterLabel())
          .font({ size: 15, weight: FontWeight.Medium })
          .constraintSize({ maxWidth: '60%' })
          .onSelect((index: number) => {
            this.filterDeck = index === 0 ? 0 : this.decks[index - 1].id;
            this.reload();
          })
      }
    }
    .width('100%').margin({ top: 4 })
  }

  /** 学习时长的一根柱子。只接常量下标 */
  @Builder
  timeBar(i: number) {
    Column({ space: 2 }) {
      Text(this.timeLabel(i)).fontSize(9).fontColor('#8A8A8E')
      Rect({ width: 18, height: this.timeHeight(i) })
        .radius(2).fill('#3B82F6')
    }
    .layoutWeight(1).justifyContent(FlexAlign.End)
  }

  /** 热力图(作答量)。无参 @Builder:内容全在内部从状态取 */
  @Builder
  heatCard() {
    // ---- 热力图 ----
    Column({ space: 8 }) {
      Text(fmt(L(this.lang).recentWeeks, this.weeks)).fontSize(14).fontWeight(FontWeight.Medium).width('100%')
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
        // 格子不够撑满宽度时靠左,不要漂在卡片中间
        .align(Alignment.Start)
        .layoutWeight(1)
        // 宽度由 layoutWeight 决定,与格子多少无关,所以按它算周数不会来回抖
        .onAreaChange((_old: Area, now: Area) => this.onHeatWidth(Number(now.width)))
      }
      .width('100%').alignItems(VerticalAlign.Top)
    }
    .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')
  }

  /** 最近 7 天学习时长 */
  @Builder
  timeCard() {
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
  }

  /** 复习量预测 */
  @Builder
  forecastCard() {
    // ---- 复习量预测 ----
    Column({ space: 8 }) {
      Text(fmt(L(this.lang).forecastDays, FORECAST_DAYS)).fontSize(14)
        .fontWeight(FontWeight.Medium).width('100%')
      Row({ space: 4 }) {
        ForEach(this.forecast, (n: number) => {
          Column() {
            Text(n > 0 ? `${n}` : '').fontSize(9).fontColor('#8A8A8E')
            Rect({ width: 14, height: this.barHeight(n) })
              .radius(2).fill('#3B82F6').margin({ top: 2 })
          }
          .layoutWeight(1).justifyContent(FlexAlign.End)
        })
      }
      .width('100%').height(90).alignItems(VerticalAlign.Bottom)
    }
    .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')
  }

  /** 掌握度分布 */
  @Builder
  masteryBlock() {
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

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Text(L(this.lang).statsTitle).fontSize(24).fontWeight(FontWeight.Bold)
          .width('100%').margin({ top: 14 })

        if (this.status.length > 0) {
          Text(this.status).fontSize(13).fontColor('#8A8A8E').width('100%')
        }

        // ================= 全部卡组:与选哪本书无关 =================
        // 不再画「综合统计」小标题:四张统计卡片紧挨着页面大标题,含义已经很清楚,
        // 省下的这一行让横屏平板的统计页一屏放得下

        Row({ space: 8 }) {
          this.statCard(0)
          this.statCard(1)
          this.statCard(2)
          this.statCard(3)
        }
        .width('100%')

        // 横屏平板两栏并排:左栏 热力图 + 学习时长,右栏 打卡月历 —— 两栏高度相近,
        // 热力图下面不会空出一大块。手机 / 竖屏平板单栏,顺序与原来一致
        if (isSplit(this.bp)) {
          Row({ space: 14 }) {
            Column({ space: 14 }) {
              this.heatCard()
              this.timeCard()
            }
            .layoutWeight(1)
            Column() { this.checkinCalendar() }.layoutWeight(1)
          }
          .width('100%').alignItems(VerticalAlign.Top)
        } else {
          this.heatCard()
          // ---- 打卡统计(月历)----
          this.checkinCalendar()
          this.timeCard()
        }

        // ================= 当前课本:随切换课本而变 =================
        this.sectionTitle(1)

        if (isSplit(this.bp)) {
          Row({ space: 14 }) {
            Column() { this.forecastCard() }.layoutWeight(1)
            Column() { this.masteryBlock() }.layoutWeight(1)
          }
          .width('100%').alignItems(VerticalAlign.Top)
        } else {
          this.forecastCard()
          this.masteryBlock()
        }
      }
      // 竖屏平板收进居中列;横屏平板两栏并排,给到 1100vp
      .width('90%').constraintSize({ maxWidth: isSplit(this.bp) ? 1100 : MAX_COL }).padding({ bottom: 20 })
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
  /**
   * 最近 7 天柱子下的星期。**必须按日序号取星期**(weekdaySun0),和柱子的数据同一个日界。
   * 原来用的是 new Date(now - i 天).getDay(),即钟表上的日期:凌晨 0~3 点时
   * 标签整体错一天 —— 周日的 8 分钟显示在「一」下面。
   */
  private dayLabels(): string[] {
    const seq: string[] = L(this.lang).weekdays.split('|');
    const today: number = dayIndex(Date.now());
    const out: string[] = [];
    for (let i = TIME_DAYS - 1; i >= 0; i--) {
      out.push(seq[weekdaySun0(today - i)]);
    }
    return out;
  }

  /**
   * 热力图区域宽度变了(首次布局、旋转、分屏):平板上按宽度放满整列,手机固定 WEEKS。
   * 一列占 CELL + GAP,最后一列后面不需要 GAP,所以分子加一个 GAP。
   */
  private onHeatWidth(widthVp: number): void {
    const fit: number = Math.floor((widthVp + GAP) / (CELL + GAP));
    const next: number = this.bp === BP_SM ? WEEKS : Math.max(WEEKS, fit);
    if (next === this.weeks || !(next > 0)) {
      return;
    }
    this.weeks = next;
    const reps: Map<number, number> = this.repsByDay;
    this.heat = heatCells(dayIndex(Date.now()), next, (d: number) => reps.get(d) ?? 0);
  }

  private weekIndexes(): number[] {
    const out: number[] = [];
    for (let i = 0; i < this.weeks; i++) {
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
