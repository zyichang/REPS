/**
 * 同步的云端一侧(Task 11–12):SyncCore.CloudPort 的真实现 + 云存储的牌组文件。
 *
 * 写法照 DevEco 官方端云模板([CloudDev]Empty Ability 的 CloudDb.ets / CloudStorage.ets):
 *   - 对象类型是 DatabaseObject 的子类,naturalbase_ClassName() 返回控制台里的对象类型名;
 *   - cloudDatabase.zone(存储区名) 拿到 DatabaseZone,query / upsert;
 *   - bucket.uploadFile / downloadFile 返回 request.agent.Task,**要自己 on('completed') 再 start()**。
 *
 * 云数据库对象类型 reps_sync 的定义见 cloud/clouddb/reps_sync.json,存储区叫 REPS,权限只有创建者能读。
 * 用户身份由 Account.ets 初始化 cloudCommon 时传入的 AuthProvider 提供。
 */
import { common } from '@kit.AbilityKit';
import { BusinessError, request } from '@kit.BasicServicesKit';
import { cloudDatabase, cloudStorage } from '@kit.CloudFoundationKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { CloudPort, SyncKind, SyncRecord } from './SyncCore';

/** 控制台里建的存储区名(大写,2026-10-25 agcli db list-zone 核对) */
export const SYNC_ZONE: string = 'REPS';
/** 一次查询取多少条 */
const PAGE: number = 500;

/** 云数据库对象类型 reps_sync 的一行。字段名必须与控制台里完全一致 */
class reps_sync extends cloudDatabase.DatabaseObject {
  id: string = '';
  uid: string = '';
  kind: string = '';
  key: string = '';
  data: string = '';
  updated_at: number = 0;
  synced_at: number = 0;
  deleted: boolean = false;

  naturalbase_ClassName(): string {
    return 'reps_sync';
  }
}

export class AgcCloud implements CloudPort {
  private zone: cloudDatabase.DatabaseZone = cloudDatabase.zone(SYNC_ZONE);
  private uid: string;

  constructor(uid: string) {
    this.uid = uid;
  }

  async pull(kind: SyncKind, since: number): Promise<SyncRecord[]> {
    const out: SyncRecord[] = [];
    let offset = 0;
    while (true) {
      const q = new cloudDatabase.DatabaseQuery(reps_sync)
        .equalTo('uid', this.uid).equalTo('kind', kind as string).greaterThan('synced_at', since)
        .orderByAsc('synced_at').limit(PAGE, offset);
      const rows: reps_sync[] = await this.zone.query(q);
      for (const r of rows) {
        out.push({ key: r.key, updatedAt: r.updated_at, syncedAt: r.synced_at, deleted: r.deleted, data: r.data });
      }
      if (rows.length < PAGE) {
        break;
      }
      offset += PAGE;
    }
    return out;
  }

  async push(kind: SyncKind, records: SyncRecord[]): Promise<void> {
    const objs: reps_sync[] = records.map((r: SyncRecord): reps_sync => {
      const o = new reps_sync();
      // 主键带 uid:两个用户的同一个 key 不会撞(权限另由「仅创建者」保证)
      o.id = `${this.uid}|${kind as string}|${r.key}`;
      o.uid = this.uid;
      o.kind = kind as string;
      o.key = r.key;
      o.data = r.data;
      o.updated_at = r.updatedAt;
      o.synced_at = r.syncedAt;
      o.deleted = r.deleted;
      return o;
    });
    if (objs.length > 0) {
      await this.zone.upsert(objs);
    }
  }
}

// ---------------------------------------------------------------- 云存储:牌组 YAML 文件

/** 一个牌组文件在云存储里的路径(安全规则:users/{uid}/ 只有本人能读写) */
export function deckCloudPath(uid: string, deckUuid: string): string {
  return `users/${uid}/decks/${deckUuid}.yaml`;
}

/** 等一个上传 / 下载任务结束。监听要在 start() 之前挂上 */
function runTask(task: request.agent.Task, what: string): Promise<void> {
  return new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
    task.on('completed', (_p: request.agent.Progress) => resolve());
    task.on('failed', (p: request.agent.Progress) => reject(new Error(`${what} 失败(状态 ${p.state})`)));
    task.start().catch((e: BusinessError) => reject(new Error(`${what} 启动失败 ${e.code} ${e.message}`)));
  });
}

function safeName(s: string): string {
  return s.replace(/[^A-Za-z0-9-]/g, '_');
}

/** 把一段文本作为文件上传到云存储 */
export async function uploadText(ctx: common.UIAbilityContext, cloudPath: string, text: string): Promise<void> {
  const local = `${ctx.cacheDir}/up-${safeName(cloudPath)}.yaml`;
  const f = fileIo.openSync(local, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(f.fd, text);
  } finally {
    fileIo.closeSync(f);
  }
  const task: request.agent.Task = await cloudStorage.bucket().uploadFile(ctx, { localPath: local, cloudPath: cloudPath });
  await runTask(task, `上传 ${cloudPath}`);
}

/** 从云存储下载一个文本文件 */
export async function downloadText(ctx: common.UIAbilityContext, cloudPath: string): Promise<string> {
  const local = `${ctx.cacheDir}/down-${safeName(cloudPath)}.yaml`;
  const task: request.agent.Task = await cloudStorage.bucket().downloadFile(ctx,
    { localPath: local, cloudPath: cloudPath, overwrite: true });
  await runTask(task, `下载 ${cloudPath}`);
  const f = fileIo.openSync(local, fileIo.OpenMode.READ_ONLY);
  try {
    const size: number = fileIo.statSync(f.fd).size;
    const buf = new ArrayBuffer(size);
    fileIo.readSync(f.fd, buf);
    // 与 Importer.readTextByUri 同一种写法
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(buf));
  } finally {
    fileIo.closeSync(f);
  }
}

/** 删云存储里的文件;不存在不算错 */
export async function deleteCloudFile(cloudPath: string): Promise<void> {
  try {
    await cloudStorage.bucket().deleteFile(cloudPath);
  } catch (e) {
    // 文件本来就不在:忽略
  }
}

