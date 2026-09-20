/**
 * 源码编码守卫。
 *
 * 背景:Windows PowerShell 5.1 的 Get-Content/Set-Content 默认按 GBK 读文件,
 * 用它改写含中文的 .ets 会静默产出不可逆乱码(WordSnap 真实踩过一次:
 * 一个文件的 213 个中文字符全被替换掉,U+FFFD 已丢失原始信息无法还原)。
 * 本项目的源码注释几乎全是中文,所以这个守卫排在所有测试之前。
 *
 * 用法:  node devtest/check-encoding.mjs
 * 发现 BOM、替换字符、mojibake、或中文文件丢失中文时报错并非零退出。
 */

import { readdirSync, readFileSync, statSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const srcRoot = join(here, '..', 'entry', 'src');

/** 这些文件按设计就应当含有中文 */
const EXPECT_CJK = new Set([
  'EntryAbility.ets',
  'Index.ets',
  'Models.ets',
  'Srs.ets',
  'Ebbinghaus.ets',
  'Schema.ets',
  'Database.ets',
]);

function walk(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) {
      out.push(...walk(p));
    } else {
      out.push(p);
    }
  }
  return out;
}

if (!existsSync(srcRoot)) {
  console.error(`缺少源码目录: ${srcRoot}`);
  process.exit(2);
}

let problems = 0;
const files = walk(srcRoot).filter((p) => {
  // rawfile 是用户数据/静态资源,不由本守卫负责
  if (p.includes(join('resources', 'rawfile'))) {
    return false;
  }
  return p.endsWith('.ets') || p.endsWith('.json5') || p.endsWith('.json');
});

console.log(`扫描 ${files.length} 个文件...\n`);

for (const f of files) {
  const rel = f.slice(srcRoot.length + 1);
  const buf = readFileSync(f);
  const text = buf.toString('utf8');
  const name = f.split(/[\\/]/).pop();
  const issues = [];

  // 1) 不要 BOM(ArkTS 编译器不需要,且会让部分工具误判)
  if (buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf) {
    issues.push('含 UTF-8 BOM');
  }

  // 2) 替换字符 = 解码时已经丢过信息,不可逆
  const fffd = (text.match(/\uFFFD/g) ?? []).length;
  if (fffd > 0) {
    issues.push(`含 ${fffd} 个替换字符 U+FFFD(编码损坏)`);
  }

  // 3) 典型 mojibake:UTF-8 被按 Latin-1/GBK 读后再写成 UTF-8
  const moji = (text.match(/[ÃÂ][\u0080-\u00BF]/g) ?? []).length;
  if (moji > 0) {
    issues.push(`含 ${moji} 处 mojibake(疑似被按错误编码读写)`);
  }

  // 4) 本应有中文的文件不能丢中文
  if (EXPECT_CJK.has(name)) {
    const cjk = (text.match(/[\u4e00-\u9fff]/g) ?? []).length;
    if (cjk === 0) {
      issues.push('中文全部丢失(预期含中文)');
    }
  }

  if (issues.length > 0) {
    problems++;
    console.log(`  FAIL  ${rel}\n        ${issues.join('\n        ')}`);
  }
}

if (problems === 0) {
  console.log('  PASS  所有源码文件编码正常(无 BOM / 无替换字符 / 中文完整)');
  console.log('\n编码检查通过。');
  process.exit(0);
}

console.log(`\n发现 ${problems} 个文件编码异常。`);
console.log('修复提示:用 write/edit 工具重写文件,不要用 PowerShell 的 Get-Content/Set-Content 改写中文文件。');
process.exit(1);
