/**
 * 统计页:热力图、保持率、复习量预测、掌握度分布。
 *
 * 纪律:**每个显示出来的数字都必须能用一条 SQL 对上。**
 * WordSnap 的统计口径 bug 正是这样查出来的 —— 被忽略的词在分子里、
 * 不在分母里,于是「已学 91 / 3732」这种数字看着正常实则错位。
 *
 * 热力图分桶走 Schema.bucketByDay(),它用的是 dayIndex() 的口径
 * (本地时区、凌晨 1 点分界),与学习页的「今天」是同一个定义。
 */

import { DayBucket, LogPoint, bucketByDay, dayIndex, retentionOf } from '../data/Schema';
import { MASTERY_COLOR, MASTERY_LABEL } from '../model/Models';
import { masteryOf } from '../srs/Srs';
import { SK_TICK, appStore } from '../store/AppStore';

/** 热力图显示最近多少周 */
const WEEKS: number = 18;
const CELL: number = 13;
const GAP: number = 3;
const WEEKDAY: string[] = ['一', '二', '三', '四', '五', '六', '日'];
/** 预测未来多少天 */
const FORECAST_DAYS: number = 14;

@Component
export struct StatsPage {
  @StorageLink(SK_TICK) tick: number = 0;

  @State private totalReps: number = 0;
  @State private retention: number = 0;
  @State private studiedDays: number = 0;
  @State private streak: number = 0;
  /** 热力图:每格的作答次数,按 day 升序,长度 = WEEKS*7 */
  @State private heat: number[] = [];
  /** 未来 FORECAST_DAYS 天每天的到期量 */
  @State private forecast: number[] = [];
  /** 掌握度五档的卡片数 */
  @State private mastery: number[] = [0, 0, 0, 0, 0];
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

      // 热力图只需要窗口内的流水
      const since: number = now - cells * 86400000;
      const logs: LogPoint[] = db.logsSince(since);
      this.totalReps = logs.length;
      this.retention = retentionOf(logs);

      const buckets: DayBucket[] = bucketByDay(logs);
      const byDay = new Map<number, number>();
      for (const b of buckets) {
        byDay.set(b.day, b.reps);
      }
      // 从最早一格排到今天
      const firstDay: number = today - cells + 1;
      const heat: number[] = [];
      for (let d = firstDay; d <= today; d++) {
        heat.push(byDay.get(d) ?? 0);
      }
      this.heat = heat;
      this.studiedDays = buckets.length;

      // 连续学习天数:从今天往回数,遇到 0 就停
      let streak = 0;
      for (let d = today; d >= firstDay; d--) {
        if ((byDay.get(d) ?? 0) > 0) {
          streak++;
        } else {
          break;
        }
      }
      this.streak = streak;

      // 复习量预测
      const to: number = now + FORECAST_DAYS * 86400000;
      const dues: number[] = db.dueForecast(now, to);
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
      for (const s of db.stabilities()) {
        const level: number = masteryOf(s) as number;
        counts[level] = counts[level] + 1;
      }
      this.mastery = counts;
      this.status = this.totalReps === 0 ? '还没有复习记录' : '';
    } catch (e) {
      this.status = `统计读取失败: ${e}`;
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
      Text(which === 0 ? '总作答'
        : which === 1 ? '保持率'
        : which === 2 ? '学习天数'
        : '连续天数')
        .fontSize(11).fontColor('#8A8A8E')
    }
    .layoutWeight(1).padding({ top: 12, bottom: 12 })
    .borderRadius(10).backgroundColor('#F5F5F7')
  }

  @Builder
  masteryRow(level: number) {
    Row({ space: 8 }) {
      Rect({ width: 10, height: 10 }).radius(5).fill(MASTERY_COLOR[level])
      Text(MASTERY_LABEL[level]).fontSize(13).width(56)
      Text(`${this.mastery[level]}`).fontSize(13).fontColor('#48484A')
    }
    .width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Text('统计').fontSize(24).fontWeight(FontWeight.Bold)
          .width('100%').margin({ top: 14 })

        if (this.status.length > 0) {
          Text(this.status).fontSize(13).fontColor('#8A8A8E').width('100%')
        }

        Row({ space: 8 }) {
          this.statCard(0)
          this.statCard(1)
          this.statCard(2)
          this.statCard(3)
        }
        .width('100%')

        // ---- 热力图 ----
        Column({ space: 8 }) {
          Text(`最近 ${WEEKS} 周`).fontSize(14).fontWeight(FontWeight.Medium).width('100%')
          Row({ space: GAP }) {
            Column({ space: GAP }) {
              ForEach(WEEKDAY, (d: string) => {
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

        // ---- 复习量预测 ----
        Column({ space: 8 }) {
          Text(`未来 ${FORECAST_DAYS} 天的复习量`).fontSize(14)
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
          Text('掌握度分布').fontSize(14).fontWeight(FontWeight.Medium).width('100%')
          this.masteryRow(0)
          this.masteryRow(1)
          this.masteryRow(2)
          this.masteryRow(3)
          this.masteryRow(4)
        }
        .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')
      }
      .width('90%').padding({ bottom: 20 })
    }
    .width('100%').height('100%').backgroundColor('#FFFFFF').align(Alignment.Top)
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
