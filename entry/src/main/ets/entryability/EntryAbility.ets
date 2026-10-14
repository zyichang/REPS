import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { appStore } from '../store/AppStore';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KeyboardAvoidMode, window } from '@kit.ArkUI';

const DOMAIN: number = 0x0000;
const TAG: string = 'REPS';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
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
      // 键盘弹出时**压缩**页面而不是整体上推:编辑卡片时「保存」按钮原来会被键盘盖住,
      // 必须先收起键盘才点得到。RESIZE 下页面变矮,Scroll 里的按钮滚一下就能点
      try {
        windowStage.getMainWindowSync().getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
      } catch (e) {
        hilog.error(DOMAIN, TAG, '设置键盘避让失败: %{public}s', `${e}`);
      }
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
  }
}
