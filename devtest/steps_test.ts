/**
 * 设置滚轮的档位表。
 *
 * 为什么值得单独测:滚轮本身是系统组件,但**「哪些值能被选中」和「打开时停在
 * 哪一档」是我们的逻辑**,而且这两件事错了都是静默的 ——
 * 用户只会看到「我明明想要 75,怎么变成 100 了」。
 *
 * 模拟器上还验不了:合成的滑动手势驱动不了 TextPicker(和 uiInput dircFling
 * 划不动列表是同一类问题),所以只能靠这里的断言。
 */
import { LIMIT_STEPS, NEW_STEPS, RETENTION_PCT, nearestStepIndex } from './Steps';

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

function isAscending(a: number[]): boolean {
  for (let i = 1; i < a.length; i++) {
    if (a[i] <= a[i - 1]) {
      return false;
    }
  }
  return true;
}

console.log('=== 1. 档位表本身 ===');

check('三张表都严格递增(滚轮顺序才不会乱)',
  isAscending(LIMIT_STEPS) && isAscending(NEW_STEPS) && isAscending(RETENTION_PCT));
check('三张表都没有重复值',
  new Set(LIMIT_STEPS).size === LIMIT_STEPS.length
  && new Set(NEW_STEPS).size === NEW_STEPS.length
  && new Set(RETENTION_PCT).size === RETENTION_PCT.length);

// 这条就是用户提的原始诉求
check('**新卡额度能选到 75**(点选换档做不到的那个值)',
  NEW_STEPS.indexOf(75) >= 0, `下标 ${NEW_STEPS.indexOf(75)}`);
check('新卡额度 5~100 之间每 5 一档,一个不缺',
  (() => {
    for (let v = 5; v <= 100; v += 5) {
      if (NEW_STEPS.indexOf(v) < 0) {
        return false;
      }
    }
    return true;
  })());
check('新卡额度含 0(今天不想学新卡)', NEW_STEPS.indexOf(0) === 0);

check('复习上限保留旧档位,换表不会让老值落空',
  [20, 50, 100, 200, 500].every((v) => LIMIT_STEPS.indexOf(v) >= 0));
check('复习上限最后一档是「不限」哨兵 9999',
  LIMIT_STEPS[LIMIT_STEPS.length - 1] === 9999);

check('保持率是百分比整数,不是小数(躲开浮点相等)',
  RETENTION_PCT.every((v) => Number.isInteger(v)));
check('保持率覆盖 80%~97%',
  RETENTION_PCT[0] === 80 && RETENTION_PCT[RETENTION_PCT.length - 1] === 97);

console.log('\n=== 2. 打开滚轮时停在哪一档 ===');

check('存 75 就停在 75,不会漂',
  NEW_STEPS[nearestStepIndex(NEW_STEPS, 75)] === 75);
check('存 100 停在 100', NEW_STEPS[nearestStepIndex(NEW_STEPS, 100)] === 100);
check('存 0 停在 0', NEW_STEPS[nearestStepIndex(NEW_STEPS, 0)] === 0);
check('存 500 停在 500(补回这几档就是为了它)',
  LIMIT_STEPS[nearestStepIndex(LIMIT_STEPS, 500)] === 500);
check('存 9999 停在「不限」那一档',
  LIMIT_STEPS[nearestStepIndex(LIMIT_STEPS, 9999)] === 9999);

// 表里没有的值:只能吸附,但必须吸到邻近的,不能掉回第一项
const orphan: number = nearestStepIndex(NEW_STEPS, 77);
check('表里没有的 77 吸附到 75(不是掉回第一项)',
  NEW_STEPS[orphan] === 75, `得到 ${NEW_STEPS[orphan]}`);
const orphan2: number = nearestStepIndex(LIMIT_STEPS, 430);
check('表里没有的 430 吸附到 450',
  LIMIT_STEPS[orphan2] === 450, `得到 ${LIMIT_STEPS[orphan2]}`);
check('比最小档还小的值吸到最小档',
  NEW_STEPS[nearestStepIndex(NEW_STEPS, -5)] === 0);
check('比最大档还大的值吸到最大档',
  NEW_STEPS[nearestStepIndex(NEW_STEPS, 99999)] === 200);

// 每一档都能自我往返,这才叫「选得中」
let roundTrip = true;
for (const steps of [LIMIT_STEPS, NEW_STEPS, RETENTION_PCT]) {
  for (let i = 0; i < steps.length; i++) {
    if (nearestStepIndex(steps, steps[i]) !== i) {
      roundTrip = false;
    }
  }
}
check('**每一档都能原样往返**:存进去的值再打开一定停回同一档', roundTrip);

// 保持率的浮点往返:界面存 0.87,滚轮要能回到 87
let pctTrip = true;
for (const pct of RETENTION_PCT) {
  const stored: number = pct / 100;
  if (RETENTION_PCT[nearestStepIndex(RETENTION_PCT, Math.round(stored * 100))] !== pct) {
    pctTrip = false;
  }
}
check('保持率经过 /100 存盘再 *100 读回,18 档全部对得上', pctTrip);

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
if (fail > 0) {
  process.exit(1);
}
