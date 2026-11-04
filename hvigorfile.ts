import { appTasks } from '@ohos/hvigor-ohos-plugin';
import { Json5Reader } from '@ohos/hvigor';
import * as fs from 'fs';
import * as path from 'path';

/*
 * 签名从本机的 signing/local.json5 注入,不写进 build-profile.json5(那个文件进版本库)。
 * 没有 signing/local.json5 时不签名,构建照常成功,产出未签名的 HAP。
 * 证书、profile、密钥库的相对路径按 signing/ 文件夹解析,整个文件夹拷到另一台电脑就能用。
 * 文件格式见 signing/local.example.json5。
 */
const SIGNING_DIR = path.join(__dirname, 'signing');
const LOCAL_SIGNING = path.join(SIGNING_DIR, 'local.json5');

function localSigningConfig(): object | undefined {
  if (!fs.existsSync(LOCAL_SIGNING)) {
    return undefined;
  }
  const local = Json5Reader.getJson5Obj(LOCAL_SIGNING);
  const material = { ...local.material };
  for (const key of ['certpath', 'profile', 'storeFile']) {
    if (typeof material[key] === 'string') {
      material[key] = path.resolve(SIGNING_DIR, material[key]);
    }
  }
  // overrides.signingConfig 只接受 type 和 material;从 DevEco 抄来的 name 字段丢掉
  return { type: local.type ?? 'HarmonyOS', material };
}

const overrides: Record<string, object> = {};
const signingConfig = localSigningConfig();
if (signingConfig !== undefined) {
  overrides.signingConfig = signingConfig;
}

export default {
  system: appTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: [],      /* Custom plugin to extend the functionality of Hvigor. */
  config: {
    ohos: {
      overrides
    }
  }
}
