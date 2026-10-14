/**
 * 热力图网格的回归测试。
 *
 * 曾经的 bug:网格是「从今天往前数 18*7-1 天」按 7 个一列摆的,所以今天
 * 永远落在最后一列的最后一行(周日)。周三学的显示成周日,
 * 「最近 7 天」里上周日的 8 分钟在热力图上却是空白。
 * 网格必须按星期对齐:行 = 周一…周日,最后一列 = 本周。
 */
import { dayIndex, dayStart, heatCells, heatFirstDay, weekdayMon0 } from './Schema';

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: string): void {
  if (ok) { pass++; console.log(`  PASS  ${name}${detail ? '  ' + detail : ''}`); }
  else { fail++; console.log(`  FAIL  ${name}${detail ? '  ' + detail : ''}`); }
}

const WEEKS = 18;
// 2026-10-14 是周三。用本地时间中午,远离 01:00 日界
const wed = new Date(2026, 9, 14, 12, 0).getTime();
const today = dayIndex(wed);

console.log('=== 1. 星期 ===');
check('2026-10-14 是周三(周一=0 → 2)', weekdayMon0(today) === 2, `${weekdayMon0(today)}`);
check('2026-10-11 是周日(6)', weekdayMon0(dayIndex(new Date(2026, 9, 11, 12, 0).getTime())) === 6);
check('2026-10-12 是周一(0)', weekdayMon0(dayIndex(new Date(2026, 9, 12, 12, 0).getTime())) === 0);
// 00:30 归前一天:周四 00:30 仍算周三
check('周四 00:30 按日界仍是周三', weekdayMon0(dayIndex(new Date(2026, 9, 15, 0, 30).getTime())) === 2);

console.log('\n=== 2. 网格对齐 ===');
const first = heatFirstDay(today, WEEKS);
check('左上角是周一', weekdayMon0(first) === 0, `${weekdayMon0(first)}`);
const sunday = dayIndex(new Date(2026, 9, 11, 12, 0).getTime());
const reps = new Map<number, number>([[today, 5], [sunday, 30]]);
const cells = heatCells(today, WEEKS, (d) => reps.get(d) ?? 0);
check('格子数 = 18*7', cells.length === WEEKS * 7);
const lastCol = WEEKS - 1;
check('**今天(周三)在最后一列第 3 行**', cells[lastCol * 7 + 2] === 5, `${cells[lastCol * 7 + 2]}`);
check('**本周四、周五…周日是 -1(还没到)**',
  [3, 4, 5, 6].every((r) => cells[lastCol * 7 + r] === -1),
  [3, 4, 5, 6].map((r) => cells[lastCol * 7 + r]).join(','));
check('本周一、周二是 0(没学,但已经过去了)', cells[lastCol * 7] === 0 && cells[lastCol * 7 + 1] === 0);
check('**上周日在倒数第二列最后一行**', cells[(lastCol - 1) * 7 + 6] === 30, `${cells[(lastCol - 1) * 7 + 6]}`);
check('-1 只出现在本周今天之后', cells.filter((c) => c === -1).length === 4);

console.log('\n=== 3. 每个星期几做「今天」都对齐 ===');
for (let k = 0; k < 7; k++) {
  const t = today - 2 + k;          // 周一 … 周日
  const cs = heatCells(t, WEEKS, (d) => (d === t ? 1 : 0));
  const wd = weekdayMon0(t);
  check(`今天是周${wd + 1}:落在最后一列第 ${wd + 1} 行`, cs[lastCol * 7 + wd] === 1
    && cs.filter((c) => c === -1).length === 6 - wd);
  check(`今天是周${wd + 1}:左上角仍是周一`, weekdayMon0(heatFirstDay(t, WEEKS)) === 0
    && dayStart(heatFirstDay(t, WEEKS)) < dayStart(t));
}

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
if (fail > 0) { process.exit(1); }
