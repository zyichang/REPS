/**
 * 计时规则:一张卡的答题时间上限、选择题按用时自动判档、学习时长的两段封顶。
 *
 * 学习页只负责显示和转发用户操作,规则都在这里。纯函数,不碰 @kit.*,
 * 桌面测试台直接测(devtest/timing_test.ts)—— 和 Steps.ets 一样,搬出界面就是为了能测。
 *
 * 术语见 CONTEXT.md:答题时长 / 学习时长、超时。
 * 后续(.scratch/kind-time-limits/)上限改成按题型取,判档线和封顶的规则不变。
 */
import { Grade, NoteType } from './Models';

/** 选择题的答题时间上限。到点判超时,记「忘了」 */
export const CHOICE_LIMIT_MS: number = 60 * 1000;

/**
 * 学习时长的保底:**每一段最多计 5 分钟**。超出的部分不计,但**不自动翻页**。
 *
 * 一张卡分两段:答题(出现 → 作答 / 超时 / 不知道 / 显示答案)和看解析(揭示答案 → 离开这张卡)。
 *   - 看解析:任何卡都用它封顶;
 *   - 答题:问答 / 挖空没有超时,用它封顶;选择题由自己的上限封顶。
 * 难题看 20 分钟解析是正常的,少记 15 分钟无所谓。它防的是开着没关、睡着了,
 * 把某一天记成 10 个小时。
 */
export const SEGMENT_CAP_MS: number = 5 * 60 * 1000;

/**
 * 选择题判档的两条线:上限的 1/6 和 1/2。上限 60 秒时正好是 10 秒 / 30 秒;
 * 上限放大时跟着放大,否则长上限的题按正常速度答对也只能评「困难」。
 * **写成除法,不写乘 1/6**:60000 / 6 正好是 10000,乘 1/6 带浮点误差,压线的 10 秒可能被判成良好。
 */
const EASY_DIVISOR: number = 6;
const GOOD_DIVISOR: number = 2;

/** 把一段时长夹在 [0, cap] 之间。系统时间被往回调时差值会是负的,一并挡掉 */
export function clampMs(ms: number, cap: number): number {
  return ms < 0 ? 0 : ms > cap ? cap : ms;
}

/**
 * 这张卡答题段的上限(毫秒)。
 * 会超时的卡到点判超时;不超时的卡(问答 / 挖空)只用它给学习时长封顶。
 */
export function answerLimitMs(cardType: number): number {
  return cardType === (NoteType.Choice as number) ? CHOICE_LIMIT_MS : SEGMENT_CAP_MS;
}

/** 这种卡到上限时是否判超时。现在只有选择题:问答 / 挖空是自评,机器不替用户判失败 */
export function timesOut(cardType: number): boolean {
  return cardType === (NoteType.Choice as number);
}

/** 不超过它答对算「简单」 */
export function easyLineMs(limitMs: number): number {
  return limitMs / EASY_DIVISOR;
}

/** 不超过它答对算「良好」。倒计时过了这条线变红:再慢就只能评「困难」 */
export function goodLineMs(limitMs: number): number {
  return limitMs / GOOD_DIVISOR;
}

/**
 * 选择题自动判档。方案 C:对错交给机器,费劲程度用耗时推。
 *
 * 答错 → 忘了(FSRS 里「困难」仍算成功回忆,拿它装失败会让稳定性一直涨)。
 * 答对 → 按耗时落到 简单 / 良好 / 困难。
 *
 * **没毕业的卡最高只给「良好」**(inLearning = 新卡或仍在学习步进里)。
 * FSRS 里 Easy 会让卡从学习阶段直接毕业,配上按耗时自动判档就变成
 * 「10 秒内答对 = 这张新卡从此 6~10 天不见」—— 一次曝光就当学会了,
 * 而四选一还有 25% 的猜中率,猜得快的卡会被直接推走。
 * 压到 Good 之后:第一次答对 → 10 分钟后再确认一次,第二次答对才毕业。
 * 复习卡不受影响,答对照样按保持率排到天以外。
 *
 * 调度器已经保证没毕业的卡不会因为 Easy 跳过步进(见 Srs.schedule 附近的注释)。
 * 这里再压一次是为了**显示一致**:否则界面写「评为简单」、调度理由写「良好」,
 * 用户会以为自己看错了。手动点「简单」按钮不经过这里,由调度器兜住。
 */
export function choiceGrade(correct: boolean, answerMs: number, limitMs: number, inLearning: boolean): Grade {
  if (!correct) {
    return Grade.Again;
  }
  if (answerMs <= easyLineMs(limitMs)) {
    return inLearning ? Grade.Good : Grade.Easy;
  }
  if (answerMs <= goodLineMs(limitMs)) {
    return Grade.Good;
  }
  return Grade.Hard;
}

/**
 * 答题段计入的时长,按这张卡的上限封顶。
 * 选择题正常超不过上限(到点就判超时);超过只可能是计时器在后台停了 ——
 * 切后台、锁屏回来,第一跳才判超时,中间那几个小时不是在答题。
 */
export function answerSegmentMs(elapsedMs: number, limitMs: number): number {
  return clampMs(elapsedMs, limitMs);
}

/** 看解析计入的时长,最多 5 分钟 */
export function explainSegmentMs(elapsedMs: number): number {
  return clampMs(elapsedMs, SEGMENT_CAP_MS);
}
