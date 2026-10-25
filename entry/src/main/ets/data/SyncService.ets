/**
 * 同步一轮(Task 11–12):先把改过的牌组 YAML 传到云存储,再跑 SyncCore.runSync。
 *
 * 触发:登录成功、回到前台、离开学习页、「立即同步」。同一时刻只跑一轮;
 * 非手动触发 60 秒内不重复。失败只记下来显示在账号页,**不打断学习**,下次触发重来。
 * 只用免费套餐:每轮只传 updatedAt 新于上次的行,一批 100 条。
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appStore } from '../store/AppStore';
import { SK_UID } from './Account';
import { Database, SyncDeckRow } from './Database';
import { metaSyncPullKey, metaSyncPushKey } from './Schema';
import { SyncMarks, SyncReport, runSync } from './SyncCore';
import { AgcCloud, deckCloudPath, uploadText } from './SyncCloud';
import { LocalStore } from './SyncLocal';

const DOMAIN: number = 0x0A01;
const TAG: string = 'REPS-Sync';
const MIN_GAP_MS: number = 60 * 1000;

/** AppStorage:上次同步成功的时刻(0 = 从没成功过)与最近一次的错误(空 = 没错) */
export const SK_SYNC_AT: string = 'reps_sync_at';
export const SK_SYNC_ERROR: string = 'reps_sync_error';
export const SK_SYNC_RUNNING: string = 'reps_sync_running';

let running: boolean = false;
let lastStart: number = 0;

function metaOkKey(uid: string): string {
  return `sync_last_ok:${uid}`;
}

/** 启动 / 登录后把上次成功时刻读进 AppStorage,账号页才显示得出来 */
export function loadSyncStatus(uid: string): void {
  if (!appStore().isReady() || uid.length === 0) {
    AppStorage.setOrCreate<number>(SK_SYNC_AT, 0);
    return;
  }
  const v: string = appStore().getDb().metaString(metaOkKey(uid));
  AppStorage.setOrCreate<number>(SK_SYNC_AT, v.length > 0 ? Number(v) : 0);
}

function readMarks(db: Database, uid: string): SyncMarks {
  const p: string = db.metaString(metaSyncPushKey(uid));
  const q: string = db.metaString(metaSyncPullKey(uid));
  return { lastPush: p.length > 0 ? Number(p) : 0, lastPull: q.length > 0 ? Number(q) : 0 };
}

/** 本轮要上传的牌组文件:updated_at 新于上次上传的 */
async function uploadDeckFiles(ctx: common.UIAbilityContext, db: Database, uid: string, since: number): Promise<number> {
  const decks: SyncDeckRow[] = db.syncDecksSince(since);
  for (const d of decks) {
    const deckId: number = db.deckByUuid(d.uuid)[0];
    if (deckId === 0) {
      continue;
    }
    const text: string = db.exportDeckYaml(deckId)[1];
    await uploadText(ctx, deckCloudPath(uid, d.uuid), text);
  }
  return decks.length;
}

/**
 * 跑一轮同步。force = 用户点了「立即同步」(不受 60 秒间隔限制)。
 * 永不抛错:失败写进 SK_SYNC_ERROR。
 */
export async function syncNow(ctx: common.UIAbilityContext, reason: string, force: boolean): Promise<void> {
  const uid: string = AppStorage.get<string>(SK_UID) ?? '';
  if (uid.length === 0 || !appStore().isReady() || running) {
    return;
  }
  const now: number = Date.now();
  if (!force && now - lastStart < MIN_GAP_MS) {
    return;
  }
  running = true;
  lastStart = now;
  AppStorage.setOrCreate<boolean>(SK_SYNC_RUNNING, true);
  const db: Database = appStore().getDb();
  try {
    const marks: SyncMarks = readMarks(db, uid);
    const files: number = await uploadDeckFiles(ctx, db, uid, marks.lastPush);
    const local = new LocalStore(db, uid, ctx);
    const rep: SyncReport = await runSync(local, new AgcCloud(uid), marks, now);
    db.setMetaString(metaSyncPushKey(uid), `${rep.marks.lastPush}`);
    db.setMetaString(metaSyncPullKey(uid), `${rep.marks.lastPull}`);
    db.setMetaString(metaOkKey(uid), `${now}`);
    AppStorage.setOrCreate<number>(SK_SYNC_AT, now);
    AppStorage.setOrCreate<string>(SK_SYNC_ERROR, '');
    hilog.info(DOMAIN, TAG, '同步完成(%{public}s):上传文件 %{public}d、上传记录 %{public}d、写入本机 %{public}d、导入牌组 %{public}d',
      reason, files, rep.uploaded, rep.applied, local.decksImported);
    if (rep.applied > 0) {
      appStore().bump();   // 别的设备来的数据:各页面重算
    }
  } catch (e) {
    const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
    AppStorage.setOrCreate<string>(SK_SYNC_ERROR, msg);
    hilog.error(DOMAIN, TAG, '同步失败(%{public}s):%{public}s', reason, msg);
  } finally {
    running = false;
    AppStorage.setOrCreate<boolean>(SK_SYNC_RUNNING, false);
  }
}
