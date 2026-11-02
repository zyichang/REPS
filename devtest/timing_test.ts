/**
 * 计时规则(model/Timing.ets)。
 *
 * 这些规则原来写在学习页里,测不到;错了也是静默的 —— 用户只会觉得「怎么又判成困难了」,
 * 或者某一天的学习时长突然变成 10 小时。搬成纯函数之后在这里逐条钉住。
 *
 * 第 1~4 节同时是「搬家前后行为一致」的证据:上限 60 秒时,判档线必须正好是原来的 10 秒 / 30 秒。
 */
import {
  CHOICE_LIMIT_MS, SEGMENT_CAP_MS, answerLimitMs, answerSegmentMs, choiceGrade, clampMs, easyLineMs,
  explainSegmentMs, goodLineMs, timesOut,
} from './Timing';
import { Grade, NoteType } from './Models';

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

const S = 1000;
const MIN = 60 * S;
const QA: number = NoteType.QA as number;
const CHOICE: number = NoteType.Choice as number;
const CLOZE: number = NoteType.Cloze as number;

console.log('=== 1. 每种卡的上限与是否超时 ===');

check('选择题上限 60 秒', answerLimitMs(CHOICE) === 60 * S, `${answerLimitMs(CHOICE)}`);
check('选择题到上限判超时', timesOut(CHOICE));
check('问答卡不超时,上限只给学习时长封顶(5 分钟)', !timesOut(QA) && answerLimitMs(QA) === 5 * MIN);
check('挖空卡同问答卡', !timesOut(CLOZE) && answerLimitMs(CLOZE) === 5 * MIN);
check('常量:选择题上限 60 秒、每段封顶 5 分钟', CHOICE_LIMIT_MS === 60 * S && SEGMENT_CAP_MS === 5 * MIN);

console.log('\n=== 2. 判档线是上限的 1/6 和 1/2 ===');

check('**上限 60 秒时正好是原来的 10 秒 / 30 秒**',
  easyLineMs(60 * S) === 10 * S && goodLineMs(60 * S) === 30 * S,
  `${easyLineMs(60 * S)} / ${goodLineMs(60 * S)}`);
check('上限 2 分钟 → 20 秒 / 60 秒', easyLineMs(2 * MIN) === 20 * S && goodLineMs(2 * MIN) === 60 * S);
check('上限 2.5 分钟 → 25 秒 / 75 秒', easyLineMs(2.5 * MIN) === 25 * S && goodLineMs(2.5 * MIN) === 75 * S);

console.log('\n=== 3. 选择题按用时判档(上限 60 秒,复习卡)===');

const L60: number = 60 * S;
check('答错一律忘了,再快也一样', choiceGrade(false, 1 * S, L60, false) === Grade.Again);
check('答错一律忘了,慢也一样', choiceGrade(false, 59 * S, L60, false) === Grade.Again);
check('0 秒答对 → 简单', choiceGrade(true, 0, L60, false) === Grade.Easy);
check('正好 10 秒 → 简单(线上算线内)', choiceGrade(true, 10 * S, L60, false) === Grade.Easy);
check('10 秒多 1 毫秒 → 良好', choiceGrade(true, 10 * S + 1, L60, false) === Grade.Good);
check('正好 30 秒 → 良好', choiceGrade(true, 30 * S, L60, false) === Grade.Good);
check('30 秒多 1 毫秒 → 困难', choiceGrade(true, 30 * S + 1, L60, false) === Grade.Hard);
check('59 秒答对 → 困难', choiceGrade(true, 59 * S, L60, false) === Grade.Hard);

console.log('\n=== 4. 没毕业的卡最高只给良好 ===');

check('**新卡 5 秒答对 → 良好,不给简单**', choiceGrade(true, 5 * S, L60, true) === Grade.Good);
check('新卡 20 秒答对 → 良好', choiceGrade(true, 20 * S, L60, true) === Grade.Good);
check('新卡 40 秒答对 → 困难(只压简单,不抬困难)', choiceGrade(true, 40 * S, L60, true) === Grade.Hard);
check('新卡答错 → 忘了', choiceGrade(false, 5 * S, L60, true) === Grade.Again);

console.log('\n=== 5. 上限放大时判档线跟着放大 ===');

const L150: number = 2.5 * MIN;
check('上限 2.5 分钟:25 秒 → 简单', choiceGrade(true, 25 * S, L150, false) === Grade.Easy);
check('上限 2.5 分钟:75 秒 → 良好', choiceGrade(true, 75 * S, L150, false) === Grade.Good);
check('上限 2.5 分钟:**2 分钟答对 → 困难**,不是忘了', choiceGrade(true, 2 * MIN, L150, false) === Grade.Hard);

console.log('\n=== 6. 两段封顶 ===');

check('clampMs:负数记 0(系统时间被往回调)', clampMs(-500, 100) === 0);
check('clampMs:范围内原样', clampMs(0, 100) === 0 && clampMs(50, 100) === 50 && clampMs(100, 100) === 100);
check('clampMs:超出记上限', clampMs(101, 100) === 100);
check('**选择题切后台 3 小时回来才判超时,答题段只记 60 秒**',
  answerSegmentMs(3 * 60 * MIN, answerLimitMs(CHOICE)) === 60 * S);
check('问答卡正面放了一整夜,只记 5 分钟', answerSegmentMs(8 * 60 * MIN, answerLimitMs(QA)) === 5 * MIN);
check('答题段正常时长原样计入', answerSegmentMs(20 * S, answerLimitMs(CHOICE)) === 20 * S);
check('**看解析开着睡了一夜,只记 5 分钟**', explainSegmentMs(8 * 60 * MIN) === 5 * MIN);
check('看解析 4 分钟原样计入', explainSegmentMs(4 * MIN) === 4 * MIN);
check('看解析时系统时间被往回调,记 0', explainSegmentMs(-3 * S) === 0);
check('一张选择题的学习时长 = 20 秒答题 + 5 分钟解析(上限)',
  answerSegmentMs(20 * S, answerLimitMs(CHOICE)) + explainSegmentMs(20 * MIN) === 20 * S + 5 * MIN);

console.log(`\n===== 结果: ${pass} 通过 / ${fail} 失败 =====`);
if (fail > 0) {
  process.exit(1);
}
