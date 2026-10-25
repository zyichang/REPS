import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { appStore } from '../store/AppStore';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KeyboardAvoidMode, window } from '@kit.ArkUI';
import { SK_BP, breakpointOf } from '../view/Layout';
import { initAccount } from '../data/Account';
import { syncNow } from '../data/SyncService';

const DOMAIN: number = 0x0000;
const TAG: string = 'REPS';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
    // 可选的华为账号 + 云服务(ADR-0006)。失败只记日志,不影响本地使用
    initAccount(this.context);
  }

  /** 系统语言等配置变了。语言设为「跟随系统」时界面要跟着换 */
  onConfigurationUpdate(config: Configuration): void {
    hilog.info(DOMAIN, TAG, '配置变化 language=%{public}s', config.language ?? '');
    if (appStore().isReady()) {
      appStore().onSystemLanguageChanged();
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, '加载首页失败: %{public}s', JSON.stringify(err) ?? '');
        return;
      }
      hilog.info(DOMAIN, TAG, '首页加载完成');
      this.trackBreakpoint(windowStage);
      // 键盘弹出时**压缩**页面而不是整体上推:编辑卡片时「保存」按钮原来会被键盘盖住,
      // 必须先收起键盘才点得到。RESIZE 下页面变矮,Scroll 里的按钮滚一下就能点
      try {
        windowStage.getMainWindowSync().getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
      } catch (e) {
        hilog.error(DOMAIN, TAG, '设置键盘避让失败: %{public}s', `${e}`);
      }
    });
  }

  /**
   * 按窗口宽度算断点写进 AppStorage(见 view/Layout.ets)。启动算一次,之后窗口尺寸一变
   * (旋转、分屏、折叠屏展开)就重算 —— 页面读 @StorageLink(SK_BP),整页跟着重排。
   */
  private trackBreakpoint(windowStage: window.WindowStage): void {
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      const ui = win.getUIContext();
      const apply = (widthPx: number): void => {
        const bp: string = breakpointOf(ui.px2vp(widthPx));
        if (AppStorage.get<string>(SK_BP) !== bp) {
          AppStorage.setOrCreate<string>(SK_BP, bp);
          hilog.info(DOMAIN, TAG, '断点 %{public}s(窗口 %{public}d px)', bp, widthPx);
        }
      };
      apply(win.getWindowProperties().windowRect.width);
      win.on('windowSizeChange', (size: window.Size) => apply(size.width));
    } catch (e) {
      hilog.error(DOMAIN, TAG, '监听窗口尺寸失败: %{public}s', `${e}`);
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
    // 回到前台:另一台设备可能刚学过(60 秒内不重复,未登录直接返回)
    syncNow(this.context, '回到前台', false);
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
  }
}
