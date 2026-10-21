/**
 * 「导入牌组」这一个动作。学习页和浏览页标题栏上的导入图标都调它,行为完全一样:
 * 打开系统文件选择器 → 解析 → 落库 → 成功就 bump(),各页面跟着重算。
 *
 * 返回要显示在页面上的一句话;用户在选择器里点了取消返回空串(取消不是失败)。
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ImportResult, importFromPicker } from '../data/Importer';
import { L, fmt } from '../i18n/Strings';
import { appStore } from '../store/AppStore';

const DOMAIN: number = 0x0A01;
const TAG: string = 'REPS-Import';

export async function runImport(ctx: common.UIAbilityContext, lang: string): Promise<string> {
  try {
    const r: ImportResult = await importFromPicker(ctx, appStore().getDb());
    if (r.ok) {
      appStore().bump();
      return fmt(L(lang).importedTo, r.cardsAdded, r.deck);
    }
    return r.cancelled ? '' : fmt(L(lang).importFailed, r.error);
  } catch (e) {
    hilog.error(DOMAIN, TAG, '导入失败 %{public}s', `${e}`);
    return fmt(L(lang).importFailed, `${e}`);
  }
}
