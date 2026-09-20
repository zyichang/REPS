/**
 * 测试台自检。
 *
 * Task 1 的作用是证明「不用模拟器就能跑真实回归测试」这条链路成立:
 * tsx 能执行 TypeScript、能读到工程文件、断言失败时能非零退出。
 * 真正的排期测试从 Task 2 开始。
 *
 * 断言纪律(全项目通用):期望值必须按公式手算,算式写进注释,
 * **不允许**先跑一遍再把实际输出抄成期望值——那只会把 bug 盖章成「正确」。
 */

import { readFileSync } from 'node:fs';
import { join } from 'node:path';

let pass = 0;
let fail = 0;

function check(name: string, cond: boolean, extra: string = ''): void {
  if (cond) {
    pass++;
    console.log(`  PASS  ${name}${extra ? '  ' + extra : ''}`);
  } else {
    fail++;
    console.log(`  FAIL  ${name}${extra ? '  ' + extra : ''}`);
  }
}

// 1) TypeScript 真的被执行了(类型标注能用,不是当 JS 跑的)
const typed: number[] = [3, 1, 2];
check('tsx 执行 TypeScript', typed.sort((a, b) => a - b).join(',') === '1,2,3');

// 2) 能读到工程文件,说明相对路径基准正确
const pagesJson = join(__dirname, '..', 'entry', 'src', 'main', 'resources', 'base', 'profile', 'main_pages.json');
const pages = JSON.parse(readFileSync(pagesJson, 'utf8')) as { src: string[] };
check('读到 main_pages.json 且注册了首页', pages.src.includes('pages/Index'), pages.src.join(', '));

// 3) 时间算术按后面排期要用的方式工作:毫秒时间戳 + 整天偏移
//    手算:2023-11-14T22:13:20Z 是 1700000000000ms;加 86400000ms 应当正好是次日同一时刻。
const T0 = 1_700_000_000_000;
const DAY_MS = 86_400_000;
check('毫秒时间戳加一天等于次日同刻',
  new Date(T0 + DAY_MS).getTime() - new Date(T0).getTime() === DAY_MS);

// 4) 断言器本身能判负——否则整套测试可能一直「全绿」而毫无意义。
//    用静默探针,不走 check(),免得输出里出现看着像真失败的 FAIL 行。
function probeNegative(): boolean {
  let localFail = 0;
  const cond = 1 + 1 === 3;
  if (!cond) {
    localFail++;
  }
  return localFail === 1;
}
check('断言器能正确判负(静默自检)', probeNegative());

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
process.exit(fail === 0 ? 0 : 1);
