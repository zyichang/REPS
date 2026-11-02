/**
 * 计时规则:一张卡的题型与答题时间上限、超时、选择题按用时自动判档、倒计时的显示、学习时长的两段封顶。
 *
 * 学习页只负责显示和转发用户操作,规则都在这里。纯函数,不碰 @kit.*,
 * 桌面测试台直接测(devtest/timing_test.ts)—— 和 Steps.ets 一样,搬出界面就是为了能测。
 *
 * 术语见 CONTEXT.md:卡片类型、题型、超时、答题时长 / 学习时长。设计见 .scratch/kind-time-limits/PRD.md。
 */
import { Grade, NoteType } from './Models';

/**
 * 题型:这张卡在考试里属于哪一类题。只决定答题时间的上限(以及以后的「忘了之后当天还出不出现」),
 * 和卡片类型(怎么作答)是两个独立的属性。代号就是牌组文件里 `kind` 的写法(ADR-0008)。
 */
export type Kind = 'choice' | 'blank' | 'short' | 'long' | 'essay';

/** 全部题型代号,按文档里的顺序。牌组文件里 `kind` 只能写这几个(解析器用它校验) */
export const KINDS: Kind[] = ['choice', 'blank', 'short', 'long', 'essay'];

/** 这个词是不是题型代号 */
export function isKind(word: string): boolean {
  for (const k of KINDS) {
    if (k === word) {
      return true;
    }
  }
  return false;
}

const SEC: number = 1000;
const MINUTE: number = 60 * SEC;

/** 选择题、填空题、简答题的默认上限,也是学习页还没换卡时的初值 */
export const SHORT_LIMIT_MS: number = 60 * SEC;
const LONG_LIMIT_MS: number = 5 * MINUTE;
const ESSAY_LIMIT_MS: number = 25 * MINUTE;

/**
 * 看解析的保底:**最多计 5 分钟**。超出的部分不计,但**不自动翻页**。
 *
 * 一张卡分两段:答题(出现 → 作答 / 超时 / 不知道 / 显示答案)和看解析(揭示答案 → 离开这张卡)。
 * 答题段由这张卡的上限封顶(到点就超时);看解析没有上限可言,用它封顶。
 * 难题看 20 分钟解析是正常的,少记 15 分钟无所谓。它防的是开着没关、睡着了,
 * 把某一天记成 10 个小时。
 */
export const SEGMENT_CAP_MS: number = 5 * MINUTE;

/**
 * 选择题判档的两条线:上限的 1/6 和 1/2。上限 60 秒时正好是 10 秒 / 30 秒;
 * 上限放大时跟着放大,否则长上限的题按正常速度答对也只能评「困难」。
 * **写成除法,不写乘 1/6**:60000 / 6 正好是 10000,乘 1/6 带浮点误差,压线的 10 秒可能被判成良好。
 */
const EASY_DIVISOR: number = 6;
const GOOD_DIVISOR: number = 2;
/** 自己评级的卡没有评分线,剩最后 1/10 的时间时倒计时变红 */
const LAST_PART_DIVISOR: number = 10;

/** 把一段时长夹在 [0, cap] 之间。系统时间被往回调时差值会是负的,一并挡掉 */
export function clampMs(ms: number, cap: number): number {
  return ms < 0 ? 0 : ms > cap ? cap : ms;
}

/**
 * 这张卡的有效题型。牌组文件里明写的 `kind` 优先(explicitKind,空串 = 没写);
 * 没写就按卡片类型推出:选择 → 选择题,挖空 → 填空题,问答 → 简答题。大题和写作题只能明写。
 * 明写的值导入时已经校验过;万一库里是认不出的值,也按没写处理,不让一张坏卡卡住学习页。
 */
export function kindOf(cardType: number, explicitKind: string): Kind {
  for (const k of KINDS) {
    if (k === explicitKind) {
      return k;
    }
  }
  if (cardType === (NoteType.Choice as number)) {
    return 'choice';
  }
  if (cardType === (NoteType.Cloze as number)) {
    return 'blank';
  }
  return 'short';
}

/** 各题型默认的答题时间上限(毫秒):选择题、填空题、简答题 60 秒,大题 5 分钟,写作题 25 分钟 */
export function defaultLimitMs(kind: Kind): number {
  if (kind === 'long') {
    return LONG_LIMIT_MS;
  }
  if (kind === 'essay') {
    return ESSAY_LIMIT_MS;
  }
  return SHORT_LIMIT_MS;
}

/** 不超过它答对算「简单」 */
export function easyLineMs(limitMs: number): number {
  return limitMs / EASY_DIVISOR;
}

/** 不超过它答对算「良好」 */
export function goodLineMs(limitMs: number): number {
  return limitMs / GOOD_DIVISOR;
}

/**
 * 选择题自动判档。方案 C:对错交给机器,费劲程度用耗时推。
 *
 * 答错 → 忘了(FSRS 里「困难」仍算成功回忆,拿它装失败会让稳定性一直涨)。
 * 答对 → 按耗时落到 简单 / 良好 / 困难。超时不经过这里:任何卡超时一律记「忘了」。
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
 * 倒计时的文字。剩余 1 分钟及以上显示「分:秒」(25 分钟的写作题要看得懂),
 * 不到 1 分钟显示秒数,单位跟着界面语言(unitSec)。秒数向上取整:还剩 0.4 秒时显示 1 秒,不是 0。
 */
export function countdownText(remainingMs: number, unitSec: string): string {
  const total: number = Math.max(0, Math.ceil(remainingMs / SEC));
  if (total >= 60) {
    const m: number = Math.floor(total / 60);
    const s: number = total % 60;
    return `${m}:${s < 10 ? '0' : ''}${s}`;
  }
  return `${total}${unitSec}`;
}

/**
 * 倒计时是否变红。
 * 选择题由 App 判档:过了「良好」线就变红,再慢只能评「困难」。
 * 自己评级的卡(问答 / 挖空)没有评分线:剩最后 10% 的时间时变红,提醒快到时间了。
 */
export function countdownRed(cardType: number, elapsedMs: number, limitMs: number): boolean {
  if (cardType === (NoteType.Choice as number)) {
    return elapsedMs >= goodLineMs(limitMs);
  }
  return elapsedMs >= limitMs - limitMs / LAST_PART_DIVISOR;
}

/**
 * 答题段计入的时长,按这张卡的上限封顶。正常超不过上限(到点就超时);
 * 超过只可能是计时器在后台停了 —— 切后台、锁屏回来,第一跳才判超时,中间那几个小时不是在答题。
 * 上限之内的答题时间全部计入:写作题写满 25 分钟就记 25 分钟。
 */
export function answerSegmentMs(elapsedMs: number, limitMs: number): number {
  return clampMs(elapsedMs, limitMs);
}

/** 看解析计入的时长,最多 5 分钟 */
export function explainSegmentMs(elapsedMs: number): number {
  return clampMs(elapsedMs, SEGMENT_CAP_MS);
}
