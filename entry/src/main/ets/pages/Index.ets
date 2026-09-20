/**
 * 主框架:四个标签页 —— 学习 / 统计 / 卡组 / 我的。
 *
 * 图标用矢量图形手绘,不依赖系统 symbol 资源:symbol 名一旦写错
 * 编译不报错、运行时只是画不出来,查起来很费时间。
 *
 * ArkUI 铁律:tabBar 的 @Builder **只接常量下标**,选中态从 @State 读。
 * 按值传参的 @Builder 不会响应更新,而编译器一声不响 ——
 * WordSnap 在这件事上踩过四次。
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appStore } from '../store/AppStore';
import { DecksPage } from '../view/DecksPage';
import { ProfilePage } from '../view/ProfilePage';
import { StatsPage } from '../view/StatsPage';
import { StudyPage } from '../view/StudyPage';

const DOMAIN: number = 0x0A01;
const TAG: string = 'REPS-Index';

const TAB_LABEL: string[] = ['学习', '统计', '卡组', '我的'];
const ACTIVE: string = '#2E9E63';
const INACTIVE: string = '#B0B7C3';
const ICON_BOX: number = 22;

@Entry
@Component
struct Index {
  @State private current: number = 0;
  @State private ready: boolean = false;
  @State private bootError: string = '';

  aboutToAppear(): void {
    this.boot();
  }

  private async boot(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      await appStore().init(ctx);
      this.ready = true;
      hilog.info(DOMAIN, TAG, '主框架就绪');
    } catch (e) {
      this.bootError = `启动失败: ${e}`;
      hilog.error(DOMAIN, TAG, '启动失败 %{public}s', String(e));
    }
  }

  private tint(i: number): string {
    return this.current === i ? ACTIVE : INACTIVE;
  }

  /** 学习:一张卡片的轮廓 */
  @Builder
  iconStudy(i: number) {
    Stack() {
      Rect({ width: ICON_BOX - 4, height: ICON_BOX - 7 })
        .radius(3).stroke(this.tint(i)).strokeWidth(1.6).fill(Color.Transparent)
      Line({ width: ICON_BOX - 12, height: 0 })
        .startPoint([0, 0]).endPoint([ICON_BOX - 12, 0])
        .stroke(this.tint(i)).strokeWidth(1.6)
        .offset({ y: -2 })
      Line({ width: ICON_BOX - 15, height: 0 })
        .startPoint([0, 0]).endPoint([ICON_BOX - 15, 0])
        .stroke(this.tint(i)).strokeWidth(1.6)
        .offset({ y: 3, x: -1.5 })
    }
    .width(ICON_BOX).height(ICON_BOX)
  }

  /** 统计:三根高低不同的柱子 */
  @Builder
  iconStats(i: number) {
    Row({ space: 3 }) {
      Rect({ width: 3.4, height: 8 }).radius(1.4).fill(this.tint(i))
      Rect({ width: 3.4, height: 14 }).radius(1.4).fill(this.tint(i))
      Rect({ width: 3.4, height: 11 }).radius(1.4).fill(this.tint(i))
    }
    .width(ICON_BOX).height(ICON_BOX).alignItems(VerticalAlign.Bottom)
    .justifyContent(FlexAlign.Center)
  }

  /** 卡组:两张叠起来的卡 */
  @Builder
  iconDecks(i: number) {
    Stack() {
      Rect({ width: ICON_BOX - 8, height: ICON_BOX - 10 })
        .radius(2.5).stroke(this.tint(i)).strokeWidth(1.5).fill(Color.Transparent)
        .offset({ x: -3, y: -3 })
      Rect({ width: ICON_BOX - 8, height: ICON_BOX - 10 })
        .radius(2.5).stroke(this.tint(i)).strokeWidth(1.5).fill(Color.Transparent)
        .offset({ x: 3, y: 3 })
    }
    .width(ICON_BOX).height(ICON_BOX)
  }

  /** 我的:一个头肩轮廓 */
  @Builder
  iconProfile(i: number) {
    Stack() {
      Circle({ width: 8, height: 8 })
        .stroke(this.tint(i)).strokeWidth(1.6).fill(Color.Transparent)
        .offset({ y: -5 })
      Path()
        .commands('M0 8 A8 8 0 0 1 16 8')
        .stroke(this.tint(i)).strokeWidth(1.6).fill(Color.Transparent)
        .offset({ y: 6 })
    }
    .width(ICON_BOX).height(ICON_BOX)
  }

  /** 标签项。只接常量下标 —— 文字与颜色都在内部算 */
  @Builder
  tabItem(i: number) {
    Column({ space: 2 }) {
      if (i === 0) {
        this.iconStudy(0)
      } else if (i === 1) {
        this.iconStats(1)
      } else if (i === 2) {
        this.iconDecks(2)
      } else {
        this.iconProfile(3)
      }
      Text(TAB_LABEL[i])
        .fontSize(10)
        .fontColor(this.tint(i))
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center)
  }

  build() {
    Column() {
      if (!this.ready) {
        Column({ space: 8 }) {
          Text('刻意重复').fontSize(26).fontWeight(FontWeight.Bold)
          Text(this.bootError.length > 0 ? this.bootError : '正在打开数据库…')
            .fontSize(13).fontColor(this.bootError.length > 0 ? '#E5544B' : '#8A8A8E')
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
      } else {
        Tabs({ barPosition: BarPosition.End, index: this.current }) {
          TabContent() {
            StudyPage()
          }.tabBar(this.tabItem(0))

          TabContent() {
            StatsPage()
          }.tabBar(this.tabItem(1))

          TabContent() {
            DecksPage()
          }.tabBar(this.tabItem(2))

          TabContent() {
            ProfilePage()
          }.tabBar(this.tabItem(3))
        }
        .barHeight(58)
        .barMode(BarMode.Fixed)
        .onChange((index: number) => { this.current = index; })
        .width('100%')
        .height('100%')
      }
    }
    .width('100%').height('100%').backgroundColor('#FFFFFF')
  }
}
