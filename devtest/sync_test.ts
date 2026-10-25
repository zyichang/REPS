/**
 * 同步核心(Task 8)的回归测试:内存里的两台「设备」+ 一个假「云端」,不联网。
 *
 * 场景:手机写、平板拉;两边交替改同一张卡(新者胜);删除传播;离线很久的设备带着旧编辑上线
 * (不能盖掉新的);同一天两台设备的每日汇总各自一行;上传中途失败不推进水位、重来不出错;
 * 重复同步什么都不变(幂等);分批上传。
 */
import {
  CloudPort, LocalPort, PULL_MARGIN_MS, PUSH_BATCH, SyncKind, SyncMarks, SyncRecord, chunk, planSync, runSync,
} from './SyncCore';

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: string): void {
  if (ok) {
    pass++;
    console.log(`  PASS  ${name}${detail ? '  ' + detail : ''}`);
  } else {
    fail++;
    console.log(`  FAIL  ${name}${detail ? '  ' + detail : ''}`);
  }
}

/** 一台设备:每类数据一张 key -> 记录 的表 */
class FakeDevice implements LocalPort {
  tables = new Map<SyncKind, Map<string, SyncRecord>>();
  marks: SyncMarks = { lastPush: 0, lastPull: 0 };

  table(kind: SyncKind): Map<string, SyncRecord> {
    let t = this.tables.get(kind);
    if (t === undefined) {
      t = new Map();
      this.tables.set(kind, t);
    }
    return t;
  }
  write(kind: SyncKind, key: string, data: string, at: number): void {
    this.table(kind).set(key, { key, updatedAt: at, syncedAt: 0, deleted: false, data });
  }
  remove(kind: SyncKind, key: string, at: number): void {
    this.table(kind).set(key, { key, updatedAt: at, syncedAt: 0, deleted: true, data: '' });
  }
  get(kind: SyncKind, key: string): SyncRecord | undefined {
    return this.table(kind).get(key);
  }
  changedSince(kind: SyncKind, since: number): SyncRecord[] {
    return Array.from(this.table(kind).values()).filter((r) => r.updatedAt > since);
  }
  localUpdatedAt(kind: SyncKind, key: string): number {
    const r = this.table(kind).get(key);
    return r === undefined ? -1 : r.updatedAt;
  }
  async apply(kind: SyncKind, records: SyncRecord[]): Promise<void> {
    for (const r of records) {
      this.table(kind).set(r.key, { ...r });
    }
  }
  async sync(cloud: CloudPort, now: number): Promise<number> {
    const rep = await runSync(this, cloud, this.marks, now);
    this.marks = rep.marks;
    return rep.applied;
  }
}

class FakeCloud implements CloudPort {
  tables = new Map<SyncKind, Map<string, SyncRecord>>();
  pushCalls = 0;
  failNextPush = false;

  table(kind: SyncKind): Map<string, SyncRecord> {
    let t = this.tables.get(kind);
    if (t === undefined) {
      t = new Map();
      this.tables.set(kind, t);
    }
    return t;
  }
  async pull(kind: SyncKind, since: number): Promise<SyncRecord[]> {
    return Array.from(this.table(kind).values()).filter((r) => r.syncedAt > since).map((r) => ({ ...r }));
  }
  async push(kind: SyncKind, records: SyncRecord[]): Promise<void> {
    if (this.failNextPush) {
      this.failNextPush = false;
      throw new Error('网络断了');
    }
    this.pushCalls++;
    for (const r of records) {
      this.table(kind).set(r.key, { ...r });
    }
  }
}

async function main(): Promise<void> {
  const cloud = new FakeCloud();
  const phone = new FakeDevice();
  const pad = new FakeDevice();
  const C = SyncKind.Card;

  console.log('=== 1. 手机写,平板拉 ===');
  phone.write(C, 'card-1', 'S=1', 1000);
  phone.write(SyncKind.Checkin, 'day-100', '{}', 1000);
  await phone.sync(cloud, 2000);
  check('云端有了', cloud.table(C).get('card-1')?.data === 'S=1');
  check('上传时打上 syncedAt', cloud.table(C).get('card-1')?.syncedAt === 2000);
  await pad.sync(cloud, 3000);
  check('平板拿到卡片', pad.get(C, 'card-1')?.data === 'S=1');
  check('平板拿到打卡', pad.get(SyncKind.Checkin, 'day-100') !== undefined);

  console.log('=== 2. 两边交替改同一张卡:新者胜 ===');
  pad.write(C, 'card-1', 'S=2(平板)', 4000);
  await pad.sync(cloud, 4500);
  phone.write(C, 'card-1', 'S=3(手机,更新)', 5000);
  await phone.sync(cloud, 5500);
  check('手机的更新版本留在手机', phone.get(C, 'card-1')?.data === 'S=3(手机,更新)');
  check('云端是手机的版本', cloud.table(C).get('card-1')?.data === 'S=3(手机,更新)');
  await pad.sync(cloud, 6000);
  check('平板拿到手机的新版本', pad.get(C, 'card-1')?.data === 'S=3(手机,更新)');

  console.log('=== 3. 删除传播 ===');
  phone.write(C, 'card-2', 'x', 6100);
  await phone.sync(cloud, 6200);
  await pad.sync(cloud, 6300);
  check('平板先有 card-2', pad.get(C, 'card-2')?.deleted === false);
  phone.remove(C, 'card-2', 7000);
  await phone.sync(cloud, 7100);
  await pad.sync(cloud, 7200);
  check('平板上 card-2 变成墓碑', pad.get(C, 'card-2')?.deleted === true);

  console.log('=== 4. 离线很久的设备带着旧编辑上线:不能盖掉新的 ===');
  const old = new FakeDevice();
  old.write(C, 'card-1', 'S=0(离线时改的旧版)', 3500);   // 比云端 5000 旧
  old.write(C, 'card-9', '离线时新建', 3600);
  await old.sync(cloud, 8000);
  check('旧编辑没有盖掉云端', cloud.table(C).get('card-1')?.data === 'S=3(手机,更新)');
  check('旧设备反过来拿到新版本', old.get(C, 'card-1')?.data === 'S=3(手机,更新)');
  check('离线时新建的卡照样上传', cloud.table(C).get('card-9')?.data === '离线时新建');
  await phone.sync(cloud, 9000);
  check('手机拿到离线设备新建的卡(updatedAt 早于手机的水位也不漏)', phone.get(C, 'card-9')?.data === '离线时新建');

  console.log('=== 5. 同一天两台设备的每日汇总:各自一行,不互相覆盖 ===');
  const D = SyncKind.Daily;
  phone.write(D, 'phone|day-200', '{"reps":30}', 9100);
  pad.write(D, 'pad|day-200', '{"reps":12}', 9100);
  await phone.sync(cloud, 9200);
  await pad.sync(cloud, 9300);
  await phone.sync(cloud, 9400);
  check('云端两行', cloud.table(D).size === 2);
  check('手机两行都有', phone.get(D, 'pad|day-200')?.data === '{"reps":12}' && phone.get(D, 'phone|day-200') !== undefined);

  console.log('=== 6. 上传中途失败:水位不动,重来不出错 ===');
  phone.write(C, 'card-3', 'y', 10000);
  const before: SyncMarks = { ...phone.marks };
  cloud.failNextPush = true;
  let threw = false;
  try {
    await phone.sync(cloud, 10100);
  } catch {
    threw = true;
  }
  check('抛出了错误', threw);
  check('水位没有推进', phone.marks.lastPush === before.lastPush && phone.marks.lastPull === before.lastPull);
  await phone.sync(cloud, 10200);
  check('重来之后上传成功', cloud.table(C).get('card-3')?.data === 'y');

  console.log('=== 7. 幂等:再同步一轮什么都不变 ===');
  const snap = JSON.stringify(Array.from(cloud.table(C).values()).map((r) => [r.key, r.data, r.updatedAt, r.deleted]));
  const applied1 = await phone.sync(cloud, 11000);
  const applied2 = await pad.sync(cloud, 11100);
  await pad.sync(cloud, 11200);
  const snap2 = JSON.stringify(Array.from(cloud.table(C).values()).map((r) => [r.key, r.data, r.updatedAt, r.deleted]));
  check('云端内容不变', snap === snap2);
  check('手机没有写入任何东西', applied1 === 0, `${applied1}`);
  check('平板只拿到它还没有的(card-3;card-9 在第 5 步已经拿到)', applied2 === 1, `${applied2}`);

  console.log('=== 8. 与本轮同一毫秒的修改不漏 ===');
  phone.write(C, 'card-4', 'z', 12000);
  await phone.sync(cloud, 12000);
  phone.write(C, 'card-5', 'w', 12000);           // 同一毫秒、在上一轮读完之后写的
  await phone.sync(cloud, 12500);
  check('下一轮带上了', cloud.table(C).get('card-5')?.data === 'w');

  console.log('=== 9. 计划与分批 ===');
  const p = planSync(
    [{ key: 'a', updatedAt: 5, syncedAt: 0, deleted: false, data: 'L' }],
    [{ key: 'a', updatedAt: 5, syncedAt: 9, deleted: false, data: 'R' }],
    () => 5);
  check('一样新:什么都不做', p.upload.length === 0 && p.apply.length === 0);
  const many: SyncRecord[] = [];
  for (let i = 0; i < PUSH_BATCH * 2 + 5; i++) {
    many.push({ key: `k${i}`, updatedAt: 1, syncedAt: 0, deleted: false, data: '' });
  }
  check('分批', chunk(many, PUSH_BATCH).length === 3 && chunk(many, PUSH_BATCH)[2].length === 5);
  const bulk = new FakeDevice();
  for (const r of many) {
    bulk.write(C, r.key, 'd', 20000);
  }
  const callsBefore = cloud.pushCalls;
  await bulk.sync(cloud, 21000);
  check(`${many.length} 条只发 3 次请求`, cloud.pushCalls - callsBefore === 3, `${cloud.pushCalls - callsBefore}`);
  check('下载水位回退量是 10 分钟', PULL_MARGIN_MS === 600000);

  console.log(`\n结果: ${pass} 通过, ${fail} 失败`);
  process.exit(fail === 0 ? 0 : 1);
}

main();
