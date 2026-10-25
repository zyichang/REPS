/**
 * 「导出牌组」这一个动作(Task 5):库 → REPS Card YAML v1 → 写进应用缓存 → 系统分享面板。
 *
 * 分享面板里可以发微信 / 邮件、存到文件管理 —— 社区分享第一阶段就是用户这样把 .yaml 发给开发者。
 * 文件里只有内容,没有学习记录(Database.exportDeckYaml / YamlExport.ets,桌面测试 export_test 守着)。
 *
 * 返回要显示在页面上的一句话。
 */
import { common } from '@kit.AbilityKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { systemShare } from '@kit.ShareKit';
import { L, fmt } from '../i18n/Strings';
import { appStore } from '../store/AppStore';

const DOMAIN: number = 0x0A01;
const TAG: string = 'REPS-Export';

/** 文件名:牌组名里不能进文件名的字符换成 _ */
export function exportFileName(deckName: string): string {
  const safe: string = deckName.replace(/[\\/:*?"<>|\s]+/g, '_').replace(/^_+|_+$/g, '');
  return `${safe.length > 0 ? safe : 'deck'}.yaml`;
}

export async function runExport(ctx: common.UIAbilityContext, deckId: number, lang: string): Promise<string> {
  let name = '';
  try {
    const out: string[] = appStore().getDb().exportDeckYaml(deckId);
    name = out[0];
    const path: string = `${ctx.cacheDir}/${exportFileName(name)}`;
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, out[1]);
    } finally {
      fileIo.closeSync(file);
    }

    // .yaml 在 UTD 里不一定有专门的类型,查不到就按普通文件分享
    let utd: string = uniformTypeDescriptor.UniformDataType.FILE;
    try {
      const t: string = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension('.yaml');
      if (t.length > 0 && !t.startsWith('flexible.')) {
        utd = t;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '查 .yaml 的 UTD 失败,按普通文件分享: %{public}s', `${e}`);
    }
    const data: systemShare.SharedData = new systemShare.SharedData({
      utd: utd,
      uri: fileUri.getUriFromPath(path),
      title: name,
    });
    const controller: systemShare.ShareController = new systemShare.ShareController(data);
    await controller.show(ctx, {
      previewMode: systemShare.SharePreviewMode.DEFAULT,
      selectionMode: systemShare.SelectionMode.SINGLE,
    });
    hilog.info(DOMAIN, TAG, '已导出 %{public}s -> %{public}s', name, path);
    return fmt(L(lang).exportedDeck, name);
  } catch (e) {
    hilog.error(DOMAIN, TAG, '导出失败 %{public}s', `${e}`);
    return fmt(L(lang).exportFailed, `${e}`);
  }
}
