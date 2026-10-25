/**
 * 同步的本地一侧(Task 12):SyncCore.LocalPort 的真实现。
 *
 * 四类数据各自怎么编成 SyncRecord(data 是这一类自己的 JSON):
 *   打卡   key = 日序号                      updatedAt = 打卡时刻        永不删除
 *   汇总   key = 设备id|日序号               updatedAt = 那天最后一条作答  只传本机的;别的设备的存进 remote_day_stats
 *   牌组   key = 牌组 uuid                   updatedAt = decks.updated_at 内容在云存储的 YAML 里;删除走墓碑
 *   卡片   key = 牌组uuid/文件里的 id(同步键)updatedAt = 排期 updated_at 删除 / 清空进度走墓碑
 *
 * 应用云端记录时,本地的时刻一律用**云端那条的**,不用现在 —— 否则两台设备会把同一条来回互传。
 */
import { common } from '@kit.AbilityKit';
import { Database, SyncDeckRow, SyncSchedRow, SyncTombstone } from './Database';
import { storeDeck } from './Importer';
import { ParsedDeck } from './Quizify';
import { DailyStatRow, SchedulingRow, dayAnchor } from './Schema';
import { LocalPort, SyncKind, SyncRecord } from './SyncCore';
import { deckCloudPath, downloadText } from './SyncCloud';
import { parseYamlDeck } from './Yaml';

interface CheckinData {
  day: number;
  ts: number;
}

interface DailyData {
  deviceId: string;
  day: number;
  reps: number;
  ms: number;
}

interface DeckData {
  name: string;
  path: string;
}

/** 同一个 key 本地有多条(比如清空过进度又学了:墓碑 + 新排期)时只留最新的 */
function newestPerKey(records: SyncRecord[]): SyncRecord[] {
  const m = new Map<string, SyncRecord>();
  for (const r of records) {
    const prev: SyncRecord | undefined = m.get(r.key);
    if (prev === undefined || r.updatedAt > prev.updatedAt) {
      m.set(r.key, r);
    }
  }
  return Array.from(m.values());
}

function tombRecord(t: SyncTombstone): SyncRecord {
  return { key: t.uuid, updatedAt: t.deletedAt, syncedAt: 0, deleted: true, data: '' };
}

export class LocalStore implements LocalPort {
  private db: Database;
  private uid: string;
  private deviceId: string;
  private ctx: common.UIAbilityContext;
  /** 这一轮从云端导入了几副牌组(界面提示用) */
  decksImported: number = 0;

  constructor(db: Database, uid: string, ctx: common.UIAbilityContext) {
    this.db = db;
    this.uid = uid;
    this.ctx = ctx;
    this.deviceId = db.deviceId();
  }

  changedSince(kind: SyncKind, since: number): SyncRecord[] {
    if (kind === SyncKind.Checkin) {
      return this.db.syncCheckinsSince(since).map((r): SyncRecord => {
        const d: CheckinData = { day: r.day, ts: r.ts };
        return { key: `${r.day}`, updatedAt: r.ts, syncedAt: 0, deleted: false, data: JSON.stringify(d) };
      });
    }
    if (kind === SyncKind.Daily) {
      return this.db.syncDaysSince(dayAnchor(Date.now()), since).map((r): SyncRecord => {
        const d: DailyData = { deviceId: this.deviceId, day: r.day, reps: r.reps, ms: r.ms };
        return { key: `${this.deviceId}|${r.day}`, updatedAt: r.last, syncedAt: 0, deleted: false, data: JSON.stringify(d) };
      });
    }
    if (kind === SyncKind.Deck) {
      const alive: SyncRecord[] = this.db.syncDecksSince(since).map((r: SyncDeckRow): SyncRecord => {
        const d: DeckData = { name: r.name, path: deckCloudPath(this.uid, r.uuid) };
        return { key: r.uuid, updatedAt: r.updatedAt, syncedAt: 0, deleted: false, data: JSON.stringify(d) };
      });
      const gone: SyncRecord[] = this.db.tombstonesSince('deck', since).map(tombRecord);
      return newestPerKey(alive.concat(gone));
    }
    const alive: SyncRecord[] = this.db.syncSchedSince(since).map((r: SyncSchedRow): SyncRecord => {
      return { key: r.key, updatedAt: r.updatedAt, syncedAt: 0, deleted: false, data: JSON.stringify(r.row) };
    });
    const gone: SyncRecord[] = this.db.tombstonesSince('card', since).map(tombRecord);
    return newestPerKey(alive.concat(gone));
  }

  localUpdatedAt(kind: SyncKind, key: string): number {
    if (kind === SyncKind.Checkin) {
      return this.db.checkinTs(Number(key));
    }
    if (kind === SyncKind.Daily) {
      // 本机自己的汇总只认 review_log,云端回来的旧值永远不覆盖;别的设备的直接覆盖缓存(幂等)
      return key.startsWith(`${this.deviceId}|`) ? Number.MAX_SAFE_INTEGER : -1;
    }
    if (kind === SyncKind.Deck) {
      return Math.max(this.db.deckByUuid(key)[1], this.db.tombstoneAt('deck', key));
    }
    return Math.max(this.db.cardBySyncKey(key)[1], this.db.tombstoneAt('card', key));
  }

  async apply(kind: SyncKind, records: SyncRecord[]): Promise<void> {
    if (kind === SyncKind.Checkin) {
      for (const r of records) {
        const d: CheckinData = JSON.parse(r.data) as CheckinData;
        this.db.checkIn(d.day, d.ts);
      }
      return;
    }
    if (kind === SyncKind.Daily) {
      const rows: DailyStatRow[] = [];
      for (const r of records) {
        const d: DailyData = JSON.parse(r.data) as DailyData;
        if (d.deviceId !== this.deviceId) {
          rows.push({ deviceId: d.deviceId, day: d.day, reps: d.reps, ms: d.ms });
        }
      }
      this.db.saveRemoteDayStats(rows);
      return;
    }
    if (kind === SyncKind.Deck) {
      for (const r of records) {
        await this.applyDeck(r);
      }
      return;
    }
    for (const r of records) {
      const cardId: number = this.db.cardBySyncKey(r.key)[0];
      if (cardId === 0) {
        continue;   // 这张卡本机没有(牌组还没下载,或已在本机删掉):跳过
      }
      if (r.deleted) {
        this.db.deleteSchedByCard(cardId);
        this.db.putTombstone('card', r.key, r.updatedAt);
      } else {
        this.db.applySchedRow(cardId, JSON.parse(r.data) as SchedulingRow, r.updatedAt);
        this.db.dropTombstone('card', r.key);
      }
    }
  }

  /** 一副牌组:删除 → 本机也删;存在 → 下载 YAML 导入(新增或更新内容,排期不动) */
  private async applyDeck(r: SyncRecord): Promise<void> {
    const deckId: number = this.db.deckByUuid(r.key)[0];
    if (r.deleted) {
      if (deckId > 0) {
        this.db.deleteDeck(deckId);
      }
      this.db.putTombstone('deck', r.key, r.updatedAt);
      return;
    }
    const d: DeckData = JSON.parse(r.data) as DeckData;
    // 下载失败直接抛:整轮不推进水位,下次重来(否则这副牌组的卡片排期会全部落空)
    const text: string = await downloadText(this.ctx, d.path);
    const parsed: ParsedDeck = parseYamlDeck(text);
    storeDeck(this.db, parsed, '云同步', Date.now());
    this.db.setDeckUpdated(r.key, r.updatedAt);
    this.db.dropTombstone('deck', r.key);
    this.decksImported++;
  }
}
