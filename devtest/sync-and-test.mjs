/**
 * 把生产源码同步到 devtest 并修正 import 路径,然后跑测试。
 *
 * 为什么要这么做:ArkTS 源码无法直接在 Node 上跑(依赖 @kit.* 运行时),
 * 但排期引擎与 Quizify 解析器是纯逻辑,可以用这种方式做真实回归测试——
 * 测的是生产文件本身,不是手写的副本。这是本项目最重要的一条测试原则:
 * 手写镜像副本会和生产代码悄悄分叉,WordSnap 为此付过代价。
 *
 * 用法:  node devtest/sync-and-test.mjs
 *
 * 注意:每新增一个被测的 .ets,都必须登记进下面的 FILES,
 *      否则它的 import 解析不到,整套测试会直接跑不起来。
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));

// 第 0 步:不依赖设备的静态检查。含中文的 .ets 被按错误编码读写会静默损坏;
// 清单里的悬空资源引用 / 页面路径写错会在设备上直接启动崩溃,编译阶段都不报。
const CHECKS = ['check-encoding.mjs', 'check-manifest.mjs'];
let failed = 0;

for (const guard of CHECKS) {
  console.log(`\n########## 运行 ${guard} ##########`);
  const r = spawnSync(process.execPath, [join(here, guard)], {
    stdio: 'inherit',
    cwd: here,
  });
  if (r.status !== 0) {
    failed++;
  }
}
console.log('');

const ets = join(here, '..', 'entry', 'src', 'main', 'ets');

/** [源文件, 目标文件, 需要替换的 import] */
const FILES = [
  [join(ets, 'srs', 'Srs.ets'), join(here, 'srs.ts'), [
    ["'../model/Models'", "'./Models'"],
    ["'./Ebbinghaus'", "'./ebbinghaus'"],
  ]],
  // 固定阶梯引擎。Srs.ets 会 import 它,不一起同步的话 srs.ts 解析不到模块,
  // 整套测试直接跑不起来。
  [join(ets, 'srs', 'Ebbinghaus.ets'), join(here, 'ebbinghaus.ts'), [
    ["'../model/Models'", "'./Models'"],
    ["'./Srs'", "'./srs'"],
  ]],
  [join(ets, 'model', 'Models.ets'), join(here, 'Models.ts'), []],
];

for (const [src, dst, subs] of FILES) {
  if (!existsSync(src)) {
    console.error(`缺少源文件: ${src}`);
    process.exit(2);
  }
  let text = readFileSync(src, 'utf8');
  for (const [from, to] of subs) {
    text = text.split(from).join(to);
  }
  writeFileSync(dst, text, 'utf8');
  console.log(`同步 ${src.replace(here, '.')} -> ${dst.replace(here, '.')}`);
}

// tsx 来自同层的 deepseek-harness;没有就退回 npx
const tsx = join(here, '..', '..', 'deepseek-harness', 'node_modules', '.bin', 'tsx.cmd');
const useTsx = existsSync(tsx);

const suites = [
  'smoke_test.ts',
  'srs_test.ts',
  'ebbinghaus_test.ts',
];

for (const suite of suites) {
  const p = join(here, suite);
  if (!existsSync(p)) {
    continue;
  }
  console.log(`\n########## 运行 ${suite} ##########`);
  // Windows 下 .cmd 必须经 shell 才能被 spawnSync 启动
  const r = useTsx
    ? spawnSync(tsx, [p], { stdio: 'inherit', cwd: here, shell: true })
    : spawnSync('npx', ['tsx', p], { stdio: 'inherit', cwd: here, shell: true });
  if (r.status !== 0) {
    failed++;
  }
}

const total = CHECKS.length + suites.length;
console.log(`\n########## 汇总:${total - failed} / ${total} 全部通过,${failed} 个失败 ##########`);
process.exit(failed === 0 ? 0 : 1);
