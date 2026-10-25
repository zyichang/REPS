/**
 * 账号(Task 10,ADR-0006):**可选**的华为账号登录。不登录时 App 照常完全本地使用。
 *
 * 这一层只做三件事,别的模块都不直接碰认证 SDK:
 *   1. 启动时用 rawfile/agconnect-services.json 初始化 AGC 认证服务(@hw-agconnect/auth);
 *   2. 用认证服务给的 AuthProvider 初始化 Cloud Foundation Kit —— 云数据库 / 云存储
 *      靠它知道「这是哪个用户」,安全规则里的 request.auth.uid 就是这里的 uid;
 *   3. 登录 / 退出 / 查当前用户,把 uid 写进 AppStorage(SK_UID),界面跟着刷新。
 *
 * agconnect-services.json 含 client_secret / api_key,不进版本库(.gitignore)。
 * 缺了这个文件,initAccount 只记一条日志,登录按钮会提示不可用,App 其余功能不受影响。
 *
 * 登录要求:AGC 里登记了签名证书的 SHA-256 指纹,否则报 1001500001(见 CONTEXT.md)。
 */
import auth, { AuthUser, SignInResult } from '@hw-agconnect/auth';
import { common } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';
import { cloudCommon } from '@kit.CloudFoundationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0A01;
const TAG: string = 'REPS-Account';
const CONFIG_FILE: string = 'agconnect-services.json';

/** AppStorage:当前登录用户的 uid,未登录为空串 */
export const SK_UID: string = 'reps_uid';

let configured: boolean = false;

/** EntryAbility.onCreate 里调一次 */
export function initAccount(ctx: common.UIAbilityContext): void {
  try {
    const raw: Uint8Array = ctx.resourceManager.getRawFileContentSync(CONFIG_FILE);
    const json: string = buffer.from(raw.buffer, raw.byteOffset, raw.byteLength).toString('utf-8');
    // **必须传 UIAbility 的 context,不能传 getApplicationContext()。** 华为账号登录要弹授权页,
    // SDK 内部拿这个 context 构造 AuthenticationController;传应用级 context 会在点登录时报
    // 401「Parameter error. Incorrect context parameter type.」(2026-10-25 平板实测)。
    auth.init(ctx, json);
    cloudCommon.init({ region: cloudCommon.CloudRegion.CHINA, authProvider: auth.getAuthProvider() });
    configured = true;
    hilog.info(DOMAIN, TAG, '认证服务与云服务已初始化');
  } catch (e) {
    configured = false;
    hilog.error(DOMAIN, TAG, '初始化失败(缺 %{public}s?):%{public}s', CONFIG_FILE, `${e}`);
  }
  AppStorage.setOrCreate<string>(SK_UID, '');
  refreshUid();
}

/** 认证服务能不能用(配置文件在不在) */
export function accountConfigured(): boolean {
  return configured;
}

/** 启动时恢复上次的登录状态 */
export function refreshUid(): void {
  if (!configured) {
    return;
  }
  auth.getCurrentUser().then((u: AuthUser | null) => {
    AppStorage.setOrCreate<string>(SK_UID, u === null ? '' : u.getUid());
  }).catch((e: Error) => {
    hilog.warn(DOMAIN, TAG, '查当前用户失败:%{public}s', `${e}`);
  });
}

/** 华为账号登录。成功返回 uid;失败抛错,message 面向用户 */
export async function signInHuawei(): Promise<string> {
  if (!configured) {
    throw new Error(`缺少 ${CONFIG_FILE}`);
  }
  const r: SignInResult = await auth.signIn({ autoCreateUser: true, credentialInfo: { kind: 'hwid' } });
  const uid: string = r.getUser().getUid();
  AppStorage.setOrCreate<string>(SK_UID, uid);
  hilog.info(DOMAIN, TAG, '登录成功');
  return uid;
}

/** 退出。本地数据一张不动 —— 退出只是不再同步 */
export async function signOut(): Promise<void> {
  if (configured) {
    await auth.signOut();
  }
  AppStorage.setOrCreate<string>(SK_UID, '');
  hilog.info(DOMAIN, TAG, '已退出');
}

/** 界面显示用:只露头尾,uid 不整串显示 */
export function maskUid(uid: string): string {
  return uid.length <= 8 ? uid : `${uid.substring(0, 4)}…${uid.substring(uid.length - 4)}`;
}
