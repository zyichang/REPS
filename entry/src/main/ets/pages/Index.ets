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
import {
  SK_BACK_REQ, SK_CAN_BACK, SK_GOTO_TAB, SK_IMMERSIVE, SK_LANG, appStore,
} from '../store/AppStore';
import { L, LANG_ZH, fmt } from '../i18n/Strings';
import { GlossaryPage } from '../view/GlossaryPage';
import { ProfilePage } from '../view/ProfilePage';
import { StatsPage } from '../view/StatsPage';
import { StudyPage } from '../view/StudyPage';

const DOMAIN: number = 0x0A01;
const TAG: string = 'REPS-Index';

/**
  * 标签文字改为跟着语言走。**不要把 L() 的结果传进 @Builder** ——
  * 按值传参的 @Builder 不响应更新;在 tabItem 内部现取。
  */
function tabLabel(lang: string, i: number): string {
  const d = L(lang);
  return i === 0 ? d.tabStudy : i === 1 ? d.tabStats : i === 2 ? d.tabGlossary : d.tabMe;
}
const ACTIVE: string = '#2E9E63';
const INACTIVE: string = '#B0B7C3';
const ICON_BOX: number = 22;

@Entry
@Component
struct Index {
  @State private current: number = 0;
  /** 别的页面请求翻页时写 SK_GOTO_TAB,这里接住。-1 表示没有待处理的请求 */
  @StorageLink(SK_GOTO_TAB) @Watch('onGotoTab') gotoTab: number = -1;
  /** 语言。从 AppStorage 读,这样切换时标签栏会重绘 */
  @StorageLink(SK_LANG) lang: string = LANG_ZH;
  /** 学习页进入卡片阶段时为真 —— 此时藏掉标签栏,给一个干净的作答界面 */
  @StorageLink(SK_IMMERSIVE) immersive: boolean = false;
  /** 当前页面是否还有上一级可回。由各标签页写入 */
  @StorageLink(SK_CAN_BACK) canBack: boolean = false;
  @StorageLink(SK_BACK_REQ) backReq: number = 0;
  @State private ready: boolean = false;
  @State private bootError: string = '';

  /**
   * 系统返回(含侧滑返回)。
   *
   * **默认行为是直接退出应用**,那在有内部层级的页面上是错的 ——
   * 用户在「预览」里侧滑,期望回到卡片列表,而不是把应用关掉。
   * 所以:当前页说自己还能返回,就拦下来发一个返回请求(返回 true);
   * 已经在顶层了才交给系统(返回 false)。
   */
  onBackPress(): boolean {
    if (this.canBack) {
      this.backReq = this.backReq + 1;
      return true;
    }
    return false;
  }

  onGotoTab(): void {
    if (this.gotoTab >= 0) {
      this.current = this.gotoTab;
      this.gotoTab = -1;        // 消费掉,否则下次写同样的值不会触发 @Watch
    }
  }

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
      this.bootError = fmt(L(this.lang).bootFailed, `${e}`);
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

  /**
   * 标签项。只接常量下标 —— 文字与颜色都在内部从 @State 算。
   *
   * 文字**只在选中时出现**。用 Visibility.Hidden 而不是 None:
   * Hidden 仍然占位,所以切换标签时图标不会上下跳动;None 会让整行重新布局。
   * 文字隐藏后无障碍读屏拿不到标签,因此把标签挂到整项的 accessibilityText 上,
   * 无论选中与否都念得出来。
   */
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
      Text(tabLabel(this.lang, i))
        .fontSize(10)
        .fontColor(this.tint(i))
        .visibility(this.current === i ? Visibility.Visible : Visibility.Hidden)
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center)
    .accessibilityText(tabLabel(this.lang, i))
    .accessibilityLevel('yes')
  }

  build() {
    Column() {
      if (!this.ready) {
        /*
         * 启动画面接着系统启动窗走,所以底色要和 start_window_background 一致,
         * 否则会闪一下白 —— 原来是默认白底 + 深灰字,改成绿底之后那行字几乎看不见。
         */
        Column({ space: 8 }) {
          Text(L(this.lang).appName)
            .fontSize(26).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          Text(this.bootError.length > 0 ? this.bootError : L(this.lang).openingDb)
            .fontSize(13)
            .fontColor(this.bootError.length > 0 ? '#FFD9D6' : 'rgba(255,255,255,0.72)')
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor('#227C50')
      } else {
        Tabs({ barPosition: BarPosition.End, index: this.current }) {
          TabContent() {
            StudyPage()
          }.tabBar(this.tabItem(0))

          TabContent() {
            StatsPage()
          }.tabBar(this.tabItem(1))

          TabContent() {
            GlossaryPage()
          }.tabBar(this.tabItem(2))

          TabContent() {
            ProfilePage()
          }.tabBar(this.tabItem(3))
        }
        .barHeight(58)
        .barMode(BarMode.Fixed)
        .onChange((index: number) => { this.current = index; })
        .barHeight(this.immersive ? 0 : 56)
        // **藏起标签栏不等于锁住手势。** Tabs 默认可以左右滑动切页,
        // 作答中一划就跳走,计时和专注都被打断 —— 所以沉浸时把滑动也关掉。
        .scrollable(!this.immersive)
        .animationDuration(0)
        .width('100%')
        .height('100%')
      }
    }
    .width('100%').height('100%').backgroundColor('#FFFFFF')
  }
}
