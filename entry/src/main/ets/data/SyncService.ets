/**
 * 同步一轮(Task 11–12):先把改过的牌组 YAML 传到云存储,再跑 SyncCore.runSync。
 *
 * 触发:启动、登录成功、回到前台、学完一轮、离开学习页、打卡、切到后台、「立即同步」。
 * 只有「启动」「回到前台」受 60 秒间隔限制;其余都是强制的,因为它们都意味着本机刚有了改动,
 * 不马上传上去,另一台设备就看不到(.scratch/cross-device-progress)。
 * 同一时刻只跑一轮;正在跑时又来的请求不丢,这一轮结束后补跑一轮(它可能带着新的改动)。
 * 失败只记下来显示在账号页,**不打断学习**,下次触发重来。
 * 只用免费套餐:每轮只传 updatedAt 新于上次的行,一批 100 条。
 */
import { common } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appStore } from '../store/AppStore';
import { SK_UID } from './Account';
import { Database, SyncDeckRow } from './Database';
import { metaSyncPullKey, metaSyncPushKey } from './Schema';
import { SYNC_KINDS, SyncKind, SyncMarks, SyncReport, runSync } from './SyncCore';
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
/** 正在同步时又来了请求:这一轮结束后再补跑一轮 */
let rerun: boolean = false;
let lastStart: number = 0;
/** 当前这一串同步(含补跑)结束时 resolve */
let current: Promise<void> = Promise.resolve();
/** 切到后台时申请的短时任务,-1 = 没有 */
let delayId: number = -1;

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
 * 请求同步。force = false 时 60 秒内不重复。正在同步时不丢:记下来,这一轮结束后补跑。
 * 返回的 Promise 在这一串同步(含补跑)结束时 resolve,**永不 reject**:失败写进 SK_SYNC_ERROR。
 */
export function syncNow(ctx: common.UIAbilityContext, reason: string, force: boolean): Promise<void> {
  const uid: string = AppStorage.get<string>(SK_UID) ?? '';
  if (uid.length === 0 || !appStore().isReady()) {
    return Promise.resolve();
  }
  if (running) {
    rerun = true;
    return current;
  }
  if (!force && Date.now() - lastStart < MIN_GAP_MS) {
    return Promise.resolve();
  }
  // 同步地置位:同一帧里紧接着的第二次请求要看到「正在跑」,走补跑
  running = true;
  AppStorage.setOrCreate<boolean>(SK_SYNC_RUNNING, true);
  current = runChain(ctx, reason);
  return current;
}

/** 跑一轮;跑的过程中又有人请求,就再跑一轮,直到没有新请求 */
async function runChain(ctx: common.UIAbilityContext, reason: string): Promise<void> {
  let why: string = reason;
  try {
    do {
      rerun = false;
      await runOnce(ctx, why);
      why = `${reason}后补跑`;
    } while (rerun);
  } finally {
    running = false;
    AppStorage.setOrCreate<boolean>(SK_SYNC_RUNNING, false);
    endBackgroundDelay();
  }
}

/** 一轮。永不抛错:失败写进 SK_SYNC_ERROR */
async function runOnce(ctx: common.UIAbilityContext, reason: string): Promise<void> {
  const uid: string = AppStorage.get<string>(SK_UID) ?? '';
  if (uid.length === 0) {
    return;   // 补跑之前退出了登录
  }
  const now: number = Date.now();
  lastStart = now;
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
  }
}

/** 本机有没有还没上传的改动 —— 和 runSync 要上传的同一个口径(LocalStore.changedSince) */
function hasLocalChanges(db: Database, uid: string, ctx: common.UIAbilityContext): boolean {
  const since: number = readMarks(db, uid).lastPush;
  const local = new LocalStore(db, uid, ctx);
  return SYNC_KINDS.some((k: SyncKind) => local.changedSince(k, since).length > 0);
}

/**
 * 切到后台:把还没上传的改动传上去。锁屏、切 App 是换设备最常见的时刻 ——
 * 停在「学完了」那一页就锁屏的话,离开学习页那次同步根本不会发生。
 *
 * 应用退到后台一两秒就会被挂起,所以先申请短时任务(只能在前台或 onBackground 里申请),
 * 这一串同步结束就取消。没有要上传的改动、也没在同步,就什么都不做:短时任务每天只有约 10 分钟配额。
 */
export function syncOnBackground(ctx: common.UIAbilityContext): void {
  const uid: string = AppStorage.get<string>(SK_UID) ?? '';
  if (uid.length === 0 || !appStore().isReady()) {
    return;
  }
  if (!running && !hasLocalChanges(appStore().getDb(), uid, ctx)) {
    return;
  }
  if (delayId === -1) {
    try {
      delayId = backgroundTaskManager.requestSuspendDelay('上传学习进度', () => {
        // 快超时了(约提前 6 秒通知):必须取消,否则系统会挂起或结束进程。没传完的下次再传
        endBackgroundDelay();
      }).requestId;
    } catch (e) {
      // 配额用完等:照常发起同步,只是可能传到一半被挂起,回到前台后会重来
      hilog.warn(DOMAIN, TAG, '申请短时任务失败:%{public}s', `${e}`);
    }
  }
  syncNow(ctx, '切到后台', true);
  if (!running) {
    endBackgroundDelay();   // 没有发起同步(比如刚刚退出了登录),短时任务不能留着
  }
}

function endBackgroundDelay(): void {
  if (delayId === -1) {
    return;
  }
  try {
    backgroundTaskManager.cancelSuspendDelay(delayId);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, '取消短时任务失败:%{public}s', `${e}`);
  }
  delayId = -1;
}
