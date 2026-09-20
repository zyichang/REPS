/**
 * 我的:排期引擎、每日额度、目标保持率、导入格式说明。
 *
 * 所有设置写进 preferences 并立刻生效。改完一律调 appStore().bump(),
 * 否则别的页面不会重算 —— UI 只认 @State / @StorageLink。
 */

import { ALGO_LABEL, appStore, DEFAULT_NEW_PER_DAY, DEFAULT_RETENTION, DEFAULT_REVIEW_LIMIT, SK_TICK } from '../store/AppStore';
import { getFsrsParams, setFsrsParams } from '../srs/Srs';

/** 复习上限的可选档位 */
const LIMIT_STEPS: number[] = [20, 50, 100, 200, 500, 9999];
/** 新卡额度的可选档位 */
const NEW_STEPS: number[] = [0, 5, 10, 20, 40, 100];
/** 目标保持率的可选档位 */
const RETENTION_STEPS: number[] = [0.8, 0.85, 0.9, 0.95];

@Component
export struct ProfilePage {
  @StorageLink(SK_TICK) tick: number = 0;

  @State private algo: string = 'fsrs';
  @State private reviewLimit: number = DEFAULT_REVIEW_LIMIT;
  @State private newPerDay: number = DEFAULT_NEW_PER_DAY;
  @State private retention: number = DEFAULT_RETENTION;
  @State private deckLabel: string = '全部卡组';

  aboutToAppear(): void {
    this.pull();
  }

  onTickChange(): void {
    this.pull();
  }

  private pull(): void {
    const st = appStore();
    if (!st.isReady()) {
      return;
    }
    this.algo = st.algo;
    this.reviewLimit = st.reviewLimit;
    this.newPerDay = st.newPerDay;
    this.retention = st.retention;
    this.deckLabel = st.currentDeckId === 0
      ? '全部卡组' : st.getDb().deckPath(st.currentDeckId);
  }

  private pickAlgo(which: number): void {
    appStore().setAlgo(which === 0 ? 'fsrs' : 'ebbinghaus');
    this.pull();
  }

  private cycleLimit(): void {
    const i: number = LIMIT_STEPS.indexOf(this.reviewLimit);
    const next: number = LIMIT_STEPS[(i + 1) % LIMIT_STEPS.length];
    appStore().setReviewLimit(next);
    this.pull();
  }

  private cycleNew(): void {
    const i: number = NEW_STEPS.indexOf(this.newPerDay);
    const next: number = NEW_STEPS[(i + 1) % NEW_STEPS.length];
    appStore().setNewPerDay(next);
    this.pull();
  }

  private cycleRetention(): void {
    const i: number = RETENTION_STEPS.indexOf(this.retention);
    const next: number = RETENTION_STEPS[(i + 1) % RETENTION_STEPS.length];
    appStore().setRetention(next);
    // 保持率是 FSRS 的参数,要同步进引擎才会影响间隔。
    // 用 clone() 改再写回,不要原地改 getFsrsParams() 返回的那个对象。
    const p = getFsrsParams().clone();
    p.desiredRetention = next;
    setFsrsParams(p);
    this.pull();
  }

  /** 引擎选项。只接常量下标 */
  @Builder
  algoOption(which: number) {
    Row() {
      Column({ space: 3 }) {
        Text(ALGO_LABEL[which]).fontSize(15)
          .fontWeight(this.isPicked(which) ? FontWeight.Bold : FontWeight.Normal)
        Text(which === 0
          ? '按记忆模型自适应:为每张卡维护稳定性与难度,间隔因卡而异'
          : '固定阶梯 5 分钟→30 分钟→12 小时→1/2/4/7/15/30/60/120 天,完全可预测')
          .fontSize(11).fontColor('#8A8A8E')
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)

      if (this.isPicked(which)) {
        Text('✓').fontSize(17).fontColor('#2E9E63')
      }
    }
    .width('100%').padding({ top: 10, bottom: 10 })
    .onClick(() => this.pickAlgo(which))
  }

  private isPicked(which: number): boolean {
    return (which === 0 && this.algo === 'fsrs') || (which === 1 && this.algo === 'ebbinghaus');
  }

  /** 一行「点一下换下一档」的设置。只接常量下标 */
  @Builder
  stepRow(which: number) {
    Row() {
      Column({ space: 3 }) {
        Text(which === 0 ? '每日复习上限' : which === 1 ? '每日新卡额度' : '目标保持率')
          .fontSize(15)
        Text(which === 0
          ? '积压再多,一天也只出这么多张 —— 没有上限会变成打开即劝退'
          : which === 1 ? '每天最多引入多少张没学过的卡'
          : '想记住的比例。调高会让间隔变短、复习变密')
          .fontSize(11).fontColor('#8A8A8E')
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)

      Text(which === 0
        ? (this.reviewLimit >= 9999 ? '不限' : `${this.reviewLimit}`)
        : which === 1 ? `${this.newPerDay}`
        : `${Math.round(this.retention * 100)}%`)
        .fontSize(15).fontColor('#4A90D9').fontWeight(FontWeight.Medium)
    }
    .width('100%').padding({ top: 10, bottom: 10 })
    .onClick(() => {
      if (which === 0) {
        this.cycleLimit();
      } else if (which === 1) {
        this.cycleNew();
      } else {
        this.cycleRetention();
      }
    })
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Text('我的').fontSize(24).fontWeight(FontWeight.Bold)
          .width('100%').margin({ top: 14 })

        // ---- 当前卡组 ----
        Column({ space: 4 }) {
          Text('当前学习').fontSize(12).fontColor('#8A8A8E').width('100%')
          Text(this.deckLabel).fontSize(16).fontWeight(FontWeight.Medium).width('100%')
        }
        .width('100%').padding(14).borderRadius(12).backgroundColor('#F5F5F7')
        .alignItems(HorizontalAlign.Start)

        // ---- 排期引擎 ----
        Column({ space: 2 }) {
          Text('排期算法').fontSize(13).fontColor('#8A8A8E').width('100%')
            .margin({ bottom: 4 })
          this.algoOption(0)
          Divider()
          this.algoOption(1)
          Text('两个引擎共用同一份学习记录,随时切换不丢进度。')
            .fontSize(11).fontColor('#B0B7C3').width('100%').margin({ top: 6 })
        }
        .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')

        // ---- 每日额度 ----
        Column({ space: 2 }) {
          Text('今日集合').fontSize(13).fontColor('#8A8A8E').width('100%')
            .margin({ bottom: 4 })
          this.stepRow(0)
          Divider()
          this.stepRow(1)
          Divider()
          this.stepRow(2)
          Text('点一行换下一档。今日集合在按下「开始学习」时一次定好,中途不追加。')
            .fontSize(11).fontColor('#B0B7C3').width('100%').margin({ top: 6 })
        }
        .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')

        // ---- 导入格式 ----
        Column({ space: 6 }) {
          Text('导入格式').fontSize(13).fontColor('#8A8A8E').width('100%')
          Text('Quizify Card Markdown v1').fontSize(15).width('100%')
          Text('与 Anki 的 Quizify Markdown 插件同一套语法,所以卡组可以双向流动:'
            + '已有的 Anki 卡组能导进来,这里的卡组也能导回去。')
            .fontSize(11).fontColor('#8A8A8E').width('100%')
          Text('+++ 起正面,*** 切背面,;;; 块是选择题,{{挖空}} 是完形填空。')
            .fontSize(11).fontColor('#8A8A8E').width('100%')
        }
        .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')
        .alignItems(HorizontalAlign.Start)

        // ---- 关于 ----
        Column({ space: 4 }) {
          Text('关于').fontSize(13).fontColor('#8A8A8E').width('100%')
          Text('刻意重复 REPS').fontSize(15).width('100%')
          Text('一天的学习量是 a set,一次作答是 a rep。').fontSize(11)
            .fontColor('#8A8A8E').width('100%')
          Text('纯本地运行,不申请任何权限。卡片来自你自己的文件,'
            + '排期算在设备上,数据库在应用沙箱里。')
            .fontSize(11).fontColor('#8A8A8E').width('100%')
        }
        .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')
        .alignItems(HorizontalAlign.Start)
      }
      .width('90%').padding({ bottom: 20 })
    }
    .width('100%').height('100%').backgroundColor('#FFFFFF').align(Alignment.Top)
  }
}
