/**
 * 同步核心(Task 8,ADR-0006)—— **纯逻辑,不联网、不碰数据库、不 import 任何 @kit.\***。
 *
 * 本地数据库与云端都藏在两个接口后面(LocalPort / CloudPort)。桌面测试 sync_test 用内存里的
 * 假实现模拟两台设备交替修改、删除、离线后再上线;Task 12 再给出 Cloud Foundation Kit 的真实现。
 *
 * 规则:
 *   - **本地 SQLite 是唯一事实来源**,云端是副本。
 *   - 增量:只上传 updatedAt 新于上次上传的本地行;只下载 syncedAt 新于上次下载的云端行。
 *     两个时间戳分开,是因为离线编辑的行 updatedAt 早、上传晚 —— 按 updatedAt 拉取会漏掉它。
 *     下载水位再往回退 PULL_MARGIN_MS,容忍设备之间的时钟差;重复拉到的行按规则合并是幂等的。
 *   - 冲突:updatedAt 新者胜(相等时什么都不做)。删除是一条 deleted = true 的记录,同样新者胜。
 *   - 失败:任何一步抛错都不推进水位,下次整轮重来。上传与合并都是幂等的,重来不会出错。
 */

/** 要同步的几类数据 */
export enum SyncKind {
  /** 打卡:一天一行,永不删除 */
  Checkin = 'checkin',
  /** 每日汇总:一台设备一天一行(ADR-0006 方案 A) */
  Daily = 'daily',
  /** 牌组 */
  Deck = 'deck',
  /** 一张卡的排期状态 */
  Card = 'card',
}

export const SYNC_KINDS: SyncKind[] = [SyncKind.Checkin, SyncKind.Daily, SyncKind.Deck, SyncKind.Card];

/** 一条同步记录。data 是这一类数据自己的 JSON(由 LocalPort 编解码,核心不关心) */
export interface SyncRecord {
  key: string;
  /** 这条数据最后一次被修改的时刻(冲突时新者胜) */
  updatedAt: number;
  /** 上传到云端的时刻(增量下载用);本地还没上传的记录为 0 */
  syncedAt: number;
  deleted: boolean;
  data: string;
}

/** 本地这一侧 */
export interface LocalPort {
  /** updatedAt > since 的本地记录(含墓碑) */
  changedSince(kind: SyncKind, since: number): SyncRecord[];
  /** 本地这条的 updatedAt;本地没有返回 -1 */
  localUpdatedAt(kind: SyncKind, key: string): number;
  /**
   * 把云端更新的记录写进本地(调用方保证这些都比本地新)。异步:收到一副本地没有的牌组时,
   * 要先下载它的 YAML 并导入,同一轮里后面的卡片排期才对得上(所以 SYNC_KINDS 里牌组排在卡片前)。
   */
  apply(kind: SyncKind, records: SyncRecord[]): Promise<void>;
}

/** 云端这一侧 */
export interface CloudPort {
  /** syncedAt > since 的云端记录 */
  pull(kind: SyncKind, since: number): Promise<SyncRecord[]>;
  /** 写入(按 key 覆盖) */
  push(kind: SyncKind, records: SyncRecord[]): Promise<void>;
}

/** 两个水位,存在本地 meta 表 */
export interface SyncMarks {
  lastPush: number;
  lastPull: number;
}

/** 一轮同步的结果 */
export interface SyncReport {
  marks: SyncMarks;
  uploaded: number;
  applied: number;
}

/** 一类数据的合并计划 */
export interface SyncPlan {
  upload: SyncRecord[];
  apply: SyncRecord[];
}

/** 下载水位往回退 10 分钟,容忍设备之间的时钟差 */
export const PULL_MARGIN_MS: number = 10 * 60 * 1000;
/** 一次上传最多几条。云数据库免费额度是每天 2 万次写,批量是为了少发请求 */
export const PUSH_BATCH: number = 100;

/**
 * 合并计划:本地改过的 vs 云端改过的,按 key 新者胜。
 *   - 只在本地改过 → 上传
 *   - 只在云端改过 → 和本地现在的那条比:云端新才写进本地(离线很久的设备传上来的旧编辑,不能盖掉本地新的)
 *   - 两边都改过 → 新的一方赢;一样新什么都不做
 */
export function planSync(localChanged: SyncRecord[], remoteChanged: SyncRecord[],
                         localUpdatedAt: (key: string) => number): SyncPlan {
  const plan: SyncPlan = { upload: [], apply: [] };
  const remoteByKey = new Map<string, SyncRecord>();
  for (const r of remoteChanged) {
    const prev: SyncRecord | undefined = remoteByKey.get(r.key);
    if (prev === undefined || r.updatedAt > prev.updatedAt) {
      remoteByKey.set(r.key, r);
    }
  }
  const localKeys = new Set<string>();
  for (const l of localChanged) {
    localKeys.add(l.key);
    const r: SyncRecord | undefined = remoteByKey.get(l.key);
    if (r === undefined || l.updatedAt > r.updatedAt) {
      plan.upload.push(l);
    } else if (r.updatedAt > l.updatedAt) {
      plan.apply.push(r);
    }
  }
  remoteByKey.forEach((r: SyncRecord, key: string) => {
    if (!localKeys.has(key) && r.updatedAt > localUpdatedAt(key)) {
      plan.apply.push(r);
    }
  });
  return plan;
}

/** 分批 */
export function chunk(records: SyncRecord[], size: number): SyncRecord[][] {
  const out: SyncRecord[][] = [];
  for (let i = 0; i < records.length; i += size) {
    out.push(records.slice(i, i + size));
  }
  return out;
}

/**
 * 跑一轮同步。now 是这一轮开始的时刻:新水位就是它 ——
 * 这一轮之后才改的行 updatedAt 一定大于它,下一轮会被带上。
 * 抛错时不返回新水位,调用方保留旧水位,下次重来。
 */
export async function runSync(local: LocalPort, cloud: CloudPort, marks: SyncMarks,
                              now: number): Promise<SyncReport> {
  let uploaded = 0;
  let applied = 0;
  for (const kind of SYNC_KINDS) {
    const localChanged: SyncRecord[] = local.changedSince(kind, marks.lastPush);
    const remoteChanged: SyncRecord[] = await cloud.pull(kind, Math.max(0, marks.lastPull - PULL_MARGIN_MS));
    const plan: SyncPlan = planSync(localChanged, remoteChanged,
      (key: string) => local.localUpdatedAt(kind, key));
    for (const batch of chunk(plan.upload, PUSH_BATCH)) {
      const stamped: SyncRecord[] = batch.map((r: SyncRecord): SyncRecord => {
        return { key: r.key, updatedAt: r.updatedAt, syncedAt: now, deleted: r.deleted, data: r.data };
      });
      await cloud.push(kind, stamped);
      uploaded += stamped.length;
    }
    if (plan.apply.length > 0) {
      await local.apply(kind, plan.apply);
      applied += plan.apply.length;
    }
  }
  // lastPush 取 now - 1:changedSince 用的是「>」,与 now 同一毫秒的修改下一轮也要带上(重复上传是幂等的)
  return { marks: { lastPush: now - 1, lastPull: now }, uploaded: uploaded, applied: applied };
}
