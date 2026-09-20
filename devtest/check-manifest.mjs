/**
 * 清单一致性检查(不需要设备)。
 *
 * 这类问题在 ArkTS 编译阶段**不会**报错,但装到设备上会直接启动崩溃或白屏:
 *   1. main_pages.json 指向的页面文件不存在,或页面没有 @Entry
 *   2. module.json5 的 srcEntry 指向的 Ability 文件不存在,或没有默认导出
 *   3. module.json5 / app.json5 里引用了未定义的资源($string: / $color: / $media: / $profile:)
 *   4. srcPath / name 对不上 build-profile.json5 里的模块声明
 *   5. 打包出的 HAP 里应当含有入口页面与各页面的字节码
 *
 * 用法: node devtest/check-manifest.mjs
 */

import { readFileSync, existsSync, readdirSync, mkdtempSync, rmSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const entry = join(root, 'entry');
const main = join(entry, 'src', 'main');
const ets = join(main, 'ets');

let pass = 0;
let fail = 0;

function check(name, cond, extra = '') {
  if (cond) {
    pass++;
    console.log(`  PASS  ${name}${extra ? '  ' + extra : ''}`);
  } else {
    fail++;
    console.log(`  FAIL  ${name}${extra ? '  ' + extra : ''}`);
  }
}

/** JSON5 里允许注释与尾逗号,用宽松方式读出需要的字段 */
function readJson5Like(path) {
  let text = readFileSync(path, 'utf8');
  text = text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
  text = text.replace(/,(\s*[}\]])/g, '$1');
  return JSON.parse(text);
}

// ---------------------------------------------------------------- 1. 页面路由
console.log('=== 1. main_pages.json 与页面文件 ===');
const pagesProfile = join(main, 'resources', 'base', 'profile', 'main_pages.json');
check('main_pages.json 存在', existsSync(pagesProfile));
const pages = readJson5Like(pagesProfile).src;
check('至少注册了一个页面', Array.isArray(pages) && pages.length > 0, JSON.stringify(pages));

for (const p of pages) {
  const file = join(ets, `${p}.ets`);
  const exists = existsSync(file);
  check(`页面 ${p} 文件存在`, exists, exists ? '' : file);
  if (exists) {
    const t = readFileSync(file, 'utf8');
    check(`页面 ${p} 带 @Entry 装饰器`, /@Entry/.test(t));
    check(`页面 ${p} 定义了 struct`, /struct\s+\w+/.test(t));
  }
}

// ---------------------------------------------------------------- 2. Ability 入口
console.log('=== 2. module.json5 的 Ability 入口 ===');
const moduleJson = readJson5Like(join(main, 'module.json5'));
const abilities = moduleJson.module?.abilities ?? [];
check('声明了至少一个 Ability', abilities.length > 0, `${abilities.length}`);

const mainElement = moduleJson.module?.mainElement;
check('mainElement 指向已声明的 Ability',
  abilities.some((a) => a.name === mainElement), String(mainElement));

for (const a of abilities) {
  // srcEntry 形如 "./ets/entryability/EntryAbility.ets",相对于模块的 src/main
  const rel = a.srcEntry.replace(/^\.\//, '');
  const file = join(main, ...rel.split('/'));
  const exists = existsSync(file);
  check(`Ability ${a.name} 的 srcEntry 存在`, exists, rel);
  if (exists) {
    const t = readFileSync(file, 'utf8');
    check(`Ability ${a.name} 有默认导出`, /export\s+default\s+class/.test(t));
    check(`Ability ${a.name} 继承 UIAbility`, /extends\s+UIAbility/.test(t));
  }
  check(`Ability ${a.name} 配了 startWindowIcon`,
    typeof a.startWindowIcon === 'string' && a.startWindowIcon.startsWith('$media:'), String(a.startWindowIcon));
  check(`Ability ${a.name} 配了 startWindowBackground`,
    typeof a.startWindowBackground === 'string' && a.startWindowBackground.startsWith('$color:'), String(a.startWindowBackground));
  if (a.name === mainElement) {
    check('主 Ability 有 home skill',
      (a.skills ?? []).some((s) => (s.actions ?? []).includes('ohos.want.action.home')));
    check('主 Ability 已导出', a.exported === true);
  }
}

// ---------------------------------------------------------------- 3. 资源引用
console.log('=== 3. 资源引用是否都有定义 ===');
const defined = { string: new Set(), color: new Set(), media: new Set(), profile: new Set() };

function collectElements(dir) {
  if (!existsSync(dir)) {
    return;
  }
  for (const f of readdirSync(dir)) {
    if (!f.endsWith('.json')) {
      continue;
    }
    const j = readJson5Like(join(dir, f));
    for (const key of ['string', 'color', 'float', 'boolean', 'integer']) {
      for (const item of j[key] ?? []) {
        if (defined[key]) {
          defined[key].add(item.name);
        }
      }
    }
  }
}

function collectMedia(dir) {
  if (!existsSync(dir)) {
    return;
  }
  for (const f of readdirSync(dir)) {
    defined.media.add(basename(f).replace(/\.[^.]+$/, ''));
  }
}

function collectProfiles(dir) {
  if (!existsSync(dir)) {
    return;
  }
  for (const f of readdirSync(dir)) {
    defined.profile.add(basename(f).replace(/\.[^.]+$/, ''));
  }
}

for (const resRoot of [join(root, 'AppScope', 'resources'), join(main, 'resources')]) {
  for (const qual of readdirSync(resRoot)) {
    const base = join(resRoot, qual);
    collectElements(join(base, 'element'));
    collectMedia(join(base, 'media'));
    collectProfiles(join(base, 'profile'));
  }
}
console.log(`  已定义: string ${defined.string.size} / color ${defined.color.size} / media ${defined.media.size} / profile ${defined.profile.size}`);

const manifests = [join(main, 'module.json5'), join(root, 'AppScope', 'app.json5')];
let refs = 0;
for (const mf of manifests) {
  const text = readFileSync(mf, 'utf8');
  for (const m of text.matchAll(/\$(string|color|media|profile):([A-Za-z0-9_]+)/g)) {
    refs++;
    const [, type, name] = m;
    check(`${basename(mf)} 的 $${type}:${name} 已定义`, defined[type].has(name));
  }
}
check('清单里确实有资源引用被检查到', refs >= 6, `${refs} 处`);

// REPS 是纯本地应用:不申请任何权限本身就是产品承诺,所以这里反向断言。
const perms = (moduleJson.module?.requestPermissions ?? []).map((p) => p.name);
check('未申请任何权限(纯本地应用)', perms.length === 0, perms.length ? perms.join(', ') : '零权限');

// ---------------------------------------------------------------- 4. 模块声明一致
console.log('=== 4. build-profile.json5 的模块声明 ===');
const bp = readJson5Like(join(root, 'build-profile.json5'));
const declared = bp.modules ?? [];
check('声明了 entry 模块', declared.some((m) => m.name === 'entry'), JSON.stringify(declared.map((m) => m.name)));
for (const m of declared) {
  const srcPath = m.srcPath.replace(/^\.\//, '');
  check(`模块 ${m.name} 的 srcPath 存在`, existsSync(join(root, ...srcPath.split('/'))), srcPath);
  check(`模块 ${m.name} 有 oh-package.json5`, existsSync(join(root, ...srcPath.split('/'), 'oh-package.json5')));
  check(`模块 ${m.name} 有 hvigorfile.ts`, existsSync(join(root, ...srcPath.split('/'), 'hvigorfile.ts')));
}
const product = (bp.app?.products ?? [])[0];
check('至少定义了一个 product', product !== undefined, String(product?.name));
for (const m of declared) {
  const targets = m.targets ?? [];
  check(`模块 ${m.name} 的 target 指向已存在的 product`,
    targets.some((t) => (t.applyToProducts ?? []).includes(product?.name)),
    JSON.stringify(targets.map((t) => t.name)));
}
check('runtimeOS 为 HarmonyOS', product?.runtimeOS === 'HarmonyOS', String(product?.runtimeOS));

// ---------------------------------------------------------------- 5. HAP 产物内容
console.log('=== 5. HAP 产物内容 ===');
const hap = join(entry, 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap');
if (!existsSync(hap)) {
  console.log('  跳过:HAP 尚未构建(先跑 build.cmd)');
} else {
  const tmp = mkdtempSync(join(tmpdir(), 'reps-hap-'));
  try {
    const zip = join(tmp, 'p.zip');
    execFileSync('powershell', ['-NoProfile', '-Command',
      `Copy-Item -LiteralPath '${hap}' -Destination '${zip}' -Force; Expand-Archive -LiteralPath '${zip}' -DestinationPath '${join(tmp, 'o')}' -Force`],
      { stdio: 'ignore' });
    const out = join(tmp, 'o');
    check('HAP 含 module.json', existsSync(join(out, 'module.json')));
    check('HAP 含 ets/modules.abc', existsSync(join(out, 'ets', 'modules.abc')));

    const abcPath = join(out, 'ets', 'modules.abc');
    if (existsSync(abcPath)) {
      const abc = readFileSync(abcPath).toString('latin1');
      for (const p of pages) {
        check(`字节码含页面 ${p}`, abc.includes(p));
      }
      for (const a of abilities) {
        check(`字节码含 Ability ${a.name}`, abc.includes(a.name));
      }
    }
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
process.exit(fail === 0 ? 0 : 1);
