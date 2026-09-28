/**
 * 学习页:选择是否开始 → 逐张复习 → 评级 → 完成。
 *
 * ArkUI 铁律:UI 只能依赖 @State / @StorageLink。
 * 所有要显示的内容都摊平成 @State,@Builder 只接常量下标。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { clozeAnswers, renderCloze } from '../data/Quizify';
import {
  ReviewCardRow, ReviewedCard, TodayProgress, dayIndex, dayStart, splitOptions,
} from '../data/Schema';
import { CardState, GRADE_COLOR, Grade, LearnPhase, NoteType } from '../model/Models';
import { MarkupText } from './MarkupText';
import { MathText, hasMath } from './MathText';
import { BookCover } from './BookCover';
import {
  SK_BACK_REQ, SK_CAN_BACK, SK_GOTO_TAB, SK_IMMERSIVE, SK_LANG, SK_TICK, appStore,
} from '../store/AppStore';
import { L, LANG_ZH, fmt, gradeLabels, phaseLabels } from '../i18n/Strings';
import { formatInterval, newCardState, schedule } from '../srs/Srs';

const DOMAIN: number = 0x0A01;
const TAG: string = 'REPS-Study';

/**
 * 选择题自动判档的阈值(毫秒)。方案 C:对错交给机器,费劲程度用耗时推。
 *
 * 只对**选择题**生效 —— 问答和挖空没有「对错」可判,仍然自评四档。
 * 超过 T_MAX 直接判错并揭示答案:再想下去也不是回忆,是推理了。
 */
const T_EASY_MS: number = 10 * 1000;
const T_GOOD_MS: number = 30 * 1000;
const T_MAX_MS: number = 60 * 1000;
/** 计时器步长。250ms 足够让秒数看起来连续,又不至于频繁重绘 */
const TICK_MS: number = 250;
/** 答对后自动翻页的停顿。留一眼看清绿色反馈,又不至于等得难受 */
const AUTO_NEXT_MS: number = 300;
/**
 * 答错的卡最少隔几张再出现。**不能马上重来** ——
 * 刚看过答案立刻再答一遍,测的是短期记忆,不是回忆。
 */
const MIN_REQUEUE_GAP: number = 3;
/** 还没测出平均用时的时候,按这个节奏估算「几分钟等于几张卡」 */
const DEFAULT_PACE_SEC: number = 15;
/** 段内显示数字的最小占比。太窄了塞不进三位数,硬塞会溢出 */
const LABEL_MIN_PCT: number = 14;
/** 进度条变化的动画时长 */
const BAR_ANIM_MS: number = 280;

enum Stage {
  Landing = 0,
  Card = 1,
  Done = 2
}

@Component
export struct StudyPage {
  /** 任何设置或卡组变动都会递增它,从而驱动本页重算计数 */
  /**
   * **@Watch 是必须的。** ArkUI 里 @StorageLink 的变化只触发重绘,
   * 不会自动调用 on<字段名>Change() —— 少了这个装饰器,界面会用旧值重绘,
   * 看起来像「切换了卡组但标题没变」。
   */
  @StorageLink(SK_TICK) @Watch('onTickChange') tick: number = 0;

  @State private stage: Stage = Stage.Landing;
  /** 「学习更多」的结果提示,空串表示不显示 */
  @State private aheadNote: string = '';
  /** 语言。界面文字跟随它;卡片内容永不翻译 */
  @StorageLink(SK_LANG) lang: string = LANG_ZH;
  /** 会话中时可以返回落地页,而不是退出应用 */
  @StorageLink(SK_CAN_BACK) canBack: boolean = false;
  /** 会话中为真,Index 据此隐藏标签栏 */
  @StorageLink(SK_IMMERSIVE) immersive: boolean = false;
  @StorageLink(SK_BACK_REQ) @Watch('onBackReq') backReq: number = 0;
  @State private status: string = '';
  @State private totalCards: number = 0;
  @State private dueCards: number = 0;
  @State private newCards: number = 0;
  /** 当前范围里一共有多少张卡 —— 按钮只在这个数为 0 时才禁用 */
  @State private scopeCards: number = 0;
  @State private deckLabel: string = '';
  /** 今日进度三段:绿(今天不再出现)/ 灰(今天还会回来)/ 白(没碰过) */
  @State private pSettled: number = 0;
  @State private pAgain: number = 0;
  @State private pUntouched: number = 0;
  /** 今日已学的卡,以及那张卡片是否展开 */
  @State private reviewed: ReviewedCard[] = [];

  @State private cardId: number = 0;
  @State private cardStem: string = '';
  @State private cardOptions: string[] = [];
  @State private cardBack: string = '';
  @State private cardAnswer: string = '';
  @State private cardType: number = 0;
  /** 这张卡一共有几个空(ADR-0002:全部同时考),仅用于顶部标签 */
  @State private cardBlanks: number = 0;
  /** 完形填空的正面按 ordinal 渲染,revealed 决定当前空是否揭开 */
  @State private clozeFront: string = '';
  @State private revealed: boolean = false;

  @State private lastLine: string = '';
  @State private remaining: number = 0;
  @State private answered: number = 0;
  /** 当前卡出现的时刻。作答耗时 = now - shownAt */
  private shownAt: number = 0;
  /** 已过去的毫秒,由计时器驱动 —— 要显示,所以必须是 @State */
  @State private elapsedMs: number = 0;
  /** 选择题已选的字母。多答案卡可以多选 */
  @State private picked: string[] = [];
  /** 0 未判 / 1 对 / 2 错 / 3 超时 */
  @State private judged: number = 0;
  /**
   * 当前卡是否还没毕业(新卡或仍在学习步进里)。
   * 自动判档在这种卡上**最高只给「良好」** —— 见 autoGrade。
   */
  private curInLearning: boolean = false;
  /** 本次会话的选择题统计,用于表头的正确率与平均用时 */
  @State private sesChoice: number = 0;
  @State private sesCorrect: number = 0;
  @State private sesMs: number = 0;
  /** 计时器句柄。离开卡片阶段必须清掉,否则后台一直在跑 */
  private timer: number = -1;
  @State private busy: boolean = false;

  private queue: number[] = [];

  aboutToAppear(): void {
    this.refresh();
  }

  /** tick 变化时重算 —— 卡组切换、设置修改都走这里 */
  onTickChange(): void {
    if (this.stage === Stage.Landing) {
      this.refresh();
    }
  }

  /** 计数一律从数据库重算,内存不另存一份 */
  onBackReq(): void {
    if (this.stage !== Stage.Landing) {
      this.refresh();
      this.stage = Stage.Landing;
      this.publishDepth();
      this.aheadNote = '';
      this.publishDepth();
    }
  }

  /** 学习中或做完时都还有上一级(落地页),顶层才放行退出 */
  private publishDepth(): void {
    this.canBack = this.stage !== Stage.Landing;
    // 卡片阶段才沉浸。做完那一屏留着标签栏,方便直接去别处
    this.immersive = this.stage === Stage.Card;
  }

  private refresh(): void {
    const st = appStore();
    if (!st.isReady()) {
      return;
    }
    try {
      const db = st.getDb();
      const now: number = Date.now();
      const deckId: number = st.currentDeckId;
      this.totalCards = db.cardCount();
      this.deckLabel = deckId === 0 ? L(this.lang).allDecks : db.deckName(deckId);

      const today: number = dayIndex(now);
      const dayFrom: number = dayStart(today);
      const dayTo: number = dayStart(today + 1);

      /*
       * 三段条是**同一批卡的划分**,总数一整天固定:
       *   绿 = 今天答过、今天不会再出现
       *   灰 = 今天答过、今天还会回来
       *   白 = 今日集合里今天还没答过的
       *
       * 白色**必须排除今天答过的卡**。早先白色是现查「当前到期 + 没学过」,
       * 于是一张答错的卡进了灰,一分钟后又满足「当前到期」而同时算进白 ——
       * 结果灰在涨、白不降、总数飘。
       */
      const untouchedDue: number = db.untouchedDueCount(deckId, dayTo, dayFrom, st.reviewLimit);
      const usedNew: number = db.newIntroducedToday(deckId, dayFrom);
      const leftNew: number = st.newPerDay > usedNew ? st.newPerDay - usedNew : 0;
      const untouchedNew: number = db.unlearnedCount(deckId, leftNew);

      /*
       * **落地页的三个数字就是进度条三段,一个不多一个不少。**
       *
       *   绿 = 已学完(今天答过、今天不再出现)—— 只画在条上,不单独列数字
       *   灰 = 学习中(今天答过、今天还会回来)
       *   白 = 待学习 + 待复习
       *
       * 待学习 = 今日新词:今天还没引入过的新卡,受当天剩余额度限制
       * 待复习 = 历史复习:有排期、今天之内到期、今天还没答过
       *
       * 这两条**必须和白色用同一个口径**。之前为了解锁按钮把待复习改成了
       * 「此刻 due <= now」,结果一张今天答过、3 分钟后才回来的卡算灰但不算
       * 待复习 —— 灰 55 / 待复习 50,差的就是那几张还没到点的。
       * 按钮现在只看 scopeCards(这本书有没有卡),和这三个数字无关,
       * 所以改回白色口径不会再把用户锁在门外。
       */
      this.newCards = untouchedNew;
      this.dueCards = untouchedDue;
      this.scopeCards = deckId === 0 ? this.totalCards : db.cardCountInDeck(deckId);

      const pr: TodayProgress = db.todayProgress(
        deckId, dayFrom, dayTo, untouchedDue + untouchedNew);
      this.pSettled = pr.settled;
      this.pAgain = pr.again;
      this.pUntouched = pr.untouched;
      this.reviewed = db.reviewedToday(deckId, dayStart(today), 50);
      if (this.totalCards === 0) {
        this.status = L(this.lang).noCardsYet;
      }
    } catch (e) {
      this.status = fmt(L(this.lang).readFailed, `${e}`);
    }
  }

  /**
   * 今日集合在这里**一次定好**,之后不再追加。
   * 复习量受硬上限约束,新卡受每日额度约束 —— 两者都来自设置。
   */
  private startSession(): void {
    const st = appStore();
    const db = st.getDb();
    const now: number = Date.now();
    const deckId: number = st.currentDeckId;

    // 和落地页同一套口径:复习受上限约束,新卡受**当天剩余**额度约束
    const dayFrom: number = dayStart(dayIndex(now));
    const usedNew: number = db.newIntroducedToday(deckId, dayFrom);
    const leftNew: number = st.newPerDay > usedNew ? st.newPerDay - usedNew : 0;
    const due: number[] = db.dueCardIdsInDeck(deckId, now, st.reviewLimit);
    const fresh: number[] = db.newCardIdsInDeck(deckId, leftNew);
    this.queue = due.concat(fresh);
    this.answered = 0;
    // **每开一轮都要清。** 不清的话正确率和平均用时会把上一轮的作答算进来 ——
    // 实测出现过「答对一题却显示 33%」,因为上一轮的「不知道」和超时还在分母里。
    this.resetSessionStats();
    this.lastLine = '';

    if (this.queue.length === 0) {
      this.stage = Stage.Done;
      this.publishDepth();
      return;
    }
    this.nextCard();
  }

  /**
   * 开始给当前卡计时。**离开卡片阶段一定要 stopTimer** ——
   * 忘了清的话计时器会在后台一直跑,既费电又会把下一张卡的耗时算错。
   */
  private startTimer(): void {
    this.stopTimer();
    this.shownAt = Date.now();
    this.elapsedMs = 0;
    this.timer = setInterval(() => {
      this.elapsedMs = Date.now() - this.shownAt;
      // 只有选择题有 60 秒上限:问答是自评,机器不该替用户判失败
      if (this.cardType === (NoteType.Choice as number) && this.judged === 0
          && this.elapsedMs >= T_MAX_MS) {
        this.onTimeout();
      }
    }, TICK_MS);
  }

  private stopTimer(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  aboutToDisappear(): void {
    this.stopTimer();
    // **必须解除沉浸**,否则切走之后标签栏再也不出现
    this.immersive = false;
  }

  /** 超时:揭示答案,按「忘了」记一次 */
  private onTimeout(): void {
    this.stopTimer();
    this.judged = 3;
    this.revealed = true;
    this.lastLine = L(this.lang).timeUp;
    this.noteChoiceResult(false, T_MAX_MS);
    this.commit(Grade.Again);
  }

  /**
   * 选择题自动判档。
   * 答错 → 忘了(FSRS 里「困难」仍算成功回忆,拿它装失败会让稳定性一直涨)。
   * 答对 → 按耗时落到 简单 / 良好 / 困难。
   */
  private autoGrade(correct: boolean, ms: number): Grade {
    if (!correct) {
      return Grade.Again;
    }
    if (ms <= T_EASY_MS) {
      /*
       * **没毕业的卡最高只给「良好」。**
       *
       * FSRS 里 Easy 会让卡从学习阶段直接毕业,配上按耗时自动判档就变成
       * 「10 秒内答对 = 这张新卡从此 6~10 天不见」—— 一次曝光就当学会了,
       * 而四选一还有 25% 的猜中率,猜得快的卡会被直接推走。
       *
       * 压到 Good 之后:第一次答对 → 10 分钟后再确认一次,第二次答对才毕业。
       * 复习卡不受影响,答对照样按保持率排到天以外。
       */
      // 调度器已经保证没毕业的卡不会因为 Easy 跳过步进(见 Srs.schedule 附近的注释)。
      // 这里再压一次是为了**显示一致**:否则界面写「评为简单」、调度理由写「良好」,
      // 用户会以为自己看错了。手动点「简单」按钮不经过这里,由调度器兜住。
      return this.curInLearning ? Grade.Good : Grade.Easy;
    }
    if (ms <= T_GOOD_MS) {
      return Grade.Good;
    }
    return Grade.Hard;
  }

  /**
   * 把一张还要在今天之内再出现的卡重新排进队列。
   *
   * **不能 push 到队尾** —— 队尾意味着「本轮最后」,110 张卡的时候等于一小时后,
   * 而排期给的是 1 分钟。也不能马上重来,那只是在测短期记忆。
   *
   * 做法:用**实测的平均作答时间**把「多久之后」换算成「几张卡之后」。
   * 1 分钟的步进、每张 15 秒,就插到 4 张之后;5 分钟就是 20 张之后。
   * 队列不够长就落到末尾 —— 本轮之内没法排得更远。
   */
  private requeue(cardId: number, delayDays: number): void {
    const delaySec: number = delayDays * 86400;
    const pace: number = this.sesChoice > 0
      ? this.sesMs / this.sesChoice / 1000 : DEFAULT_PACE_SEC;
    const safePace: number = pace > 1 ? pace : 1;
    let gap: number = Math.round(delaySec / safePace);
    if (gap < MIN_REQUEUE_GAP) {
      gap = MIN_REQUEUE_GAP;
    }
    const at: number = gap < this.queue.length ? gap : this.queue.length;
    this.queue.splice(at, 0, cardId);
  }

  private resetSessionStats(): void {
    this.sesChoice = 0;
    this.sesCorrect = 0;
    this.sesMs = 0;
  }

  private noteChoiceResult(correct: boolean, ms: number): void {
    this.sesChoice++;
    this.sesMs += ms;
    if (correct) {
      this.sesCorrect++;
    }
  }

  /** 第 i 个选项对应的字母。按下标算,不去解析选项原文里的「A.」 */
  private letterOf(i: number): string {
    return String.fromCharCode(65 + i);
  }

  private isMultiAnswer(): boolean {
    return this.cardAnswer.trim().length > 1;
  }

  private isPicked(i: number): boolean {
    const letter: string = this.letterOf(i);
    for (const p of this.picked) {
      if (p === letter) {
        return true;
      }
    }
    return false;
  }

  /** 点一个选项。单答案卡立刻提交,多答案卡等「确认」 */
  private pickOption(i: number): void {
    if (this.judged !== 0 || this.revealed) {
      return;
    }
    const letter: string = this.letterOf(i);
    if (this.isMultiAnswer()) {
      const next: string[] = [];
      let found = false;
      for (const p of this.picked) {
        if (p === letter) {
          found = true;
        } else {
          next.push(p);
        }
      }
      if (!found) {
        next.push(letter);
      }
      this.picked = next;
      return;
    }
    this.picked = [letter];
    this.submitPick();
  }

  private submitPick(): void {
    if (this.judged !== 0 || this.picked.length === 0) {
      return;
    }
    this.stopTimer();
    const ms: number = Date.now() - this.shownAt;
    const want: string = this.cardAnswer.trim().toUpperCase().split('').sort().join('');
    const got: string = this.picked.join('').toUpperCase().split('').sort().join('');
    const correct: boolean = want.length > 0 && want === got;
    this.judged = correct ? 1 : 2;
    this.revealed = true;
    this.noteChoiceResult(correct, ms);
    this.commit(this.autoGrade(correct, ms));
    this.afterJudge(correct);
  }

  /**
   * 判完之后走不走。
   *
   * **答错永远停下来** —— 错了才最需要看解析,直接翻页等于白错一次。
   * 答对则看设置:要么 0.3 秒后自动过(留一眼确认绿色反馈),
   * 要么停在解析页等用户点「下一个」。
   */
  private afterJudge(correct: boolean): void {
    if (correct && appStore().autoNext) {
      setTimeout(() => {
        // 这 0.3 秒里用户可能已手动点了「下一个」,nextCard 会把 judged 清成 0
        if (this.judged !== 0 && this.stage === Stage.Card) {
          this.nextCard();
        }
      }, AUTO_NEXT_MS);
    }
  }

  /** 「不知道」:直接记「忘了」并揭示答案。比瞎猜诚实,也不虚高正确率 */
  private onDontKnow(): void {
    if (this.judged !== 0) {
      return;
    }
    this.stopTimer();
    const ms: number = Date.now() - this.shownAt;
    this.judged = 2;
    this.revealed = true;
    this.noteChoiceResult(false, ms);
    this.commit(Grade.Again);
  }

  /** 选项底色:未判时显示选中态,判完后标出对错 */
  private optionBg(i: number): string {
    const letter: string = this.letterOf(i);
    const isAnswer: boolean = this.cardAnswer.toUpperCase().includes(letter);
    if (this.judged === 0) {
      return this.isPicked(i) ? '#D8EAFB' : '#F5F5F7';
    }
    if (isAnswer) {
      return '#D6F0E0';
    }
    return this.isPicked(i) ? '#FBD9D6' : '#F5F5F7';
  }

  private nextCard(): void {
    this.revealed = false;
    if (this.queue.length === 0) {
      this.refresh();
      this.stage = Stage.Done;
      this.publishDepth();
      return;
    }
    const id: number = this.queue.shift() as number;
    const row: ReviewCardRow | null = appStore().getDb().loadReviewCard(id);
    if (row === null) {
      this.nextCard();
      return;
    }
    this.cardId = id;
    this.cardStem = row.front;
    this.cardOptions = splitOptions(row.options);
    this.cardBack = row.back;
    this.cardAnswer = row.answer;
    this.cardType = row.type;
    const st0: CardState | null = appStore().getDb().loadState(id);
    this.curInLearning = st0 === null
      || st0.phase === LearnPhase.New || st0.phase === LearnPhase.Learning;
    this.cardBlanks = row.type === (NoteType.Cloze as number)
      ? clozeAnswers(row.front).length : 0;
    // 完形填空:所有空同时挖出来(ADR-0002),一张卡就考这一组空
    this.clozeFront = row.type === (NoteType.Cloze as number)
      ? renderCloze(row.front, false) : '';
    this.remaining = this.queue.length + 1;
    this.picked = [];
    this.judged = 0;
    this.stage = Stage.Card;
    this.publishDepth();
    this.startTimer();
  }

  /**
   * 记一次作答。**只落库,不前进。**
   *
   * 前进的时机由调用方决定:问答自评完就走;选择题要看答对答错和设置 ——
   * 答错必须停下来看解析,答对才可能直接过。把两件事拆开,是因为
   * 「什么时候算完」和「什么时候翻页」本来就不是同一个问题。
   */
  private commit(grade: Grade): void {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const st = appStore();
      const db = st.getDb();
      const now: number = Date.now();
      const prev: CardState | null = db.loadState(this.cardId);
      const base: CardState = prev !== null ? prev : newCardState(this.cardId, now);
      const r = schedule(base, grade, now, true);

      db.saveState(r.state);
      db.logReview({
        id: 0, cardId: this.cardId, ts: now, grade: grade as number,
        stabilityBefore: r.stabilityBefore, elapsedDays: r.elapsedDays,
        retrievability: r.retrievability, intervalDays: r.intervalDays,
          costMs: this.shownAt > 0 ? Date.now() - this.shownAt : 0, algo: st.algo,
      });

      this.answered++;
      if (this.judged !== 3) {
        this.lastLine = `${gradeLabels(this.lang)[grade as number]} · ${phaseLabels(this.lang)[r.state.phase]}` +
          fmt(L(this.lang).nextAfter, formatInterval(r.intervalDays));
      }
      // 表头的三段条要跟着动,否则做完一张看不出变化
      this.refresh();

      // 还在分钟级步进的卡,今天还会再来一次
      if (r.intervalDays < 1) {
        this.requeue(this.cardId, r.intervalDays);
      }
    } catch (e) {
      this.status = fmt(L(this.lang).saveFailed, `${e}`);
      hilog.error(DOMAIN, TAG, '评级失败 %{public}s', String(e));
    } finally {
      this.busy = false;
    }
  }

  /** 参数只接常量下标,文字与颜色都在内部取 —— WordSnap 踩四次定下的写法 */
  @Builder
  gradeButton(grade: number) {
    Button(gradeLabels(this.lang)[grade])
      .fontSize(15)
      .fontColor(Color.White)
      .backgroundColor(GRADE_COLOR[grade])
      .layoutWeight(1)
      .height(46)
      .onClick(() => { this.commit(grade as Grade); this.nextCard(); })
  }

  /**
   * 「change」:切到卡组页去选。不在这里再做一个选择器 ——
   * 卡组页已经有完整的列表、进度和「设为当前」,复制一份必然走样。
   */
  private onChangeDeck(): void {
    AppStorage.setOrCreate(SK_GOTO_TAB, 2);
  }


  /**
   * 今日进度三段条(照搬 WordSnap)。
   *
   * 绿 = 今天不会再出现;灰 = 今天还会回来;白 = 还没碰过。
   * **分段依据是下次到期时刻,不是答得对不对** —— 新卡答「良好」之后还在
   * 10 分钟步进里,今天还会回来;按成绩分段就会显示成「做完了」,那是骗人。
   *
   * 用**百分比宽度 + animation**,不用 layoutWeight:
   * layoutWeight 变化不会有过渡效果,做完一张卡时条子是硬跳的,
   * 而且宽度一小就没法在段内放数字。
   */
  @Builder
  progressBar() {
    Row() {
      if (this.barTotal() === 0) {
        Row().width('100%').height('100%').backgroundColor('#E5E5EA')
      } else {
        this.barSegment(0)
        this.barSegment(1)
        this.barSegment(2)
      }
    }
    .width('100%').height(18).borderRadius(9)
    .clip(true)
    .borderWidth(1).borderColor('#E5E5EA')
  }

  /** 一段。**只接常量下标**:0 绿(已稳) / 1 灰(今天还回来) / 2 白(未碰) */
  @Builder
  barSegment(which: number) {
    Row() {
      if (this.segPct(which) >= LABEL_MIN_PCT) {
        Text(`${this.segCount(which)}`)
          .fontSize(10)
          .fontColor(which === 2 ? '#8A8A8E' : Color.White)
          .fontWeight(FontWeight.Medium)
      }
    }
    .width(`${this.segPct(which)}%`)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(which === 0 ? '#2E9E63' : which === 1 ? '#C7C7CC' : '#F7F7FA')
    .animation({ duration: BAR_ANIM_MS, curve: Curve.EaseOut })
  }

  private barTotal(): number {
    return this.pSettled + this.pAgain + this.pUntouched;
  }

  private segCount(which: number): number {
    return which === 0 ? this.pSettled : which === 1 ? this.pAgain : this.pUntouched;
  }

  /**
   * 段宽百分比。最后一段用 100 减前两段,**保证三段加起来正好 100** ——
   * 各自四舍五入会差一两个百分点,条子右边就会露出一条缝。
   */
  private segPct(which: number): number {
    const total: number = this.barTotal();
    if (total === 0) {
      return 0;
    }
    const a: number = Math.round(100 * this.pSettled / total);
    const b: number = Math.round(100 * this.pAgain / total);
    if (which === 0) {
      return a;
    }
    if (which === 1) {
      return b;
    }
    const rest: number = 100 - a - b;
    return rest > 0 ? rest : 0;
  }

  /**
   * 第二张大卡:回顾今日已学。
   *
   * 点它**直接开始一轮学习**,卡片就是今天已经答过的那些 —— 不是展开成列表
   * 让人干看。回顾的意义在于再答一遍,看着卡片名字没有任何练习价值。
   *
   * 注意:再答一遍会正常参与排期,和平时作答没有区别 ——
   * 同一天多答一次本来就是学习步进在做的事,不需要另立一套规则。
   */
  @Builder
  todayCard() {
    Row() {
      Column({ space: 3 }) {
        Text(L(this.lang).reviewToday).fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor(this.reviewed.length > 0 ? '#1C1C1E' : '#B0B7C3')
        Text(this.reviewed.length === 0
          ? L(this.lang).reviewTodayNone
          : `${fmt(L(this.lang).reviewTodayCount, this.reviewed.length)} · `
            + L(this.lang).reviewTodayAgainHint)
          .fontSize(11).fontColor('#8A8A8E')
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('›').fontSize(20).fontColor('#B0B7C3')
    }
    .width('90%').padding(16).borderRadius(16).backgroundColor('#FFFFFF')
    .onClick(() => this.studyReviewedToday())
  }

  /** 用今天答过的卡开一轮学习。顺序沿用查询结果:最近答的在前 */
  private studyReviewedToday(): void {
    if (this.reviewed.length === 0) {
      return;
    }
    const ids: number[] = [];
    for (const r of this.reviewed) {
      ids.push(r.cardId);
    }
    this.queue = ids;
    this.answered = 0;
    // **每开一轮都要清。** 不清的话正确率和平均用时会把上一轮的作答算进来 ——
    // 实测出现过「答对一题却显示 33%」,因为上一轮的「不知道」和超时还在分母里。
    this.resetSessionStats();
    this.aheadNote = '';
    this.nextCard();
  }




  /** 卡组大卡:左 2 是本子,右 7 是书名 + 进度条 + 数字与按钮 */
  /**
   * 落地页。内容**靠上排**,不居中 —— 居中会让书随着下面内容多少上下浮动,
   * 每次打开位置都不一样,找不到落点。
   *
   * 「开始学习」是**独立的主按钮**,不塞在书卡里面:它是这一屏唯一的主动作,
   * 塞进卡片里会和「切换」「待学习/待复习」这些次要信息抢注意力。
   */
  @Builder
  landing() {
    Scroll() {
      Column({ space: 14 }) {
        // ---- 课本卡:封面 + 书名 + 进度条 + 两个数字 ----
        Column() {
          Row({ space: 14 }) {
            Column() {
              BookCover({ tint: '#2E9E63', spine: '#24794C' })
            }
            .layoutWeight(2)

            Column({ space: 10 }) {
              Row() {
                Text(this.deckLabel)
                  .fontSize(17).fontWeight(FontWeight.Bold).layoutWeight(1)
                  .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(L(this.lang).change)
                  .fontSize(12).fontColor('#2E9E63')
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .borderRadius(6).backgroundColor('#E8F5EE')
                  .onClick(() => this.onChangeDeck())
              }
              .width('100%')

              this.progressBar()

              /*
               * 三个数字对应三段:待学习 + 待复习 = 白,学习中 = 灰。
               * 颜色也对上 —— 学习中用灰条那个颜色,不然用户得自己猜哪个对哪个。
               */
              Row({ space: 8 }) {
                Column({ space: 2 }) {
                  Text(`${this.newCards}`).fontSize(17).fontWeight(FontWeight.Bold)
                    .fontColor('#4A90D9')
                  Text(L(this.lang).toLearn).fontSize(11).fontColor('#8A8A8E')
                }
                .layoutWeight(1).alignItems(HorizontalAlign.Start)

                Column({ space: 2 }) {
                  Text(`${this.dueCards}`).fontSize(17).fontWeight(FontWeight.Bold)
                    .fontColor('#E5544B')
                  Text(L(this.lang).toReview).fontSize(11).fontColor('#8A8A8E')
                }
                .layoutWeight(1).alignItems(HorizontalAlign.Start)

                Column({ space: 2 }) {
                  Text(`${this.pAgain}`).fontSize(17).fontWeight(FontWeight.Bold)
                    .fontColor('#9AA3B0')
                  Text(L(this.lang).learning).fontSize(11).fontColor('#8A8A8E')
                }
                .layoutWeight(1).alignItems(HorizontalAlign.Start)
              }
              .width('100%')
            }
            .layoutWeight(7)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
        }
        .width('90%').padding(16).borderRadius(16).backgroundColor('#FFFFFF')

        // ---- 唯一的主动作 ----
        /*
         * **按钮永远可点,只要这本书里有卡。**
         *
         * 原来写的是 `enabled(dueCards + newCards > 0)`,而那时 dueCards 用的是
         * 进度条白色段的口径 —— 它**刻意排除了今天答过的卡**。于是今天这批卡
         * 一旦全碰过一遍,那些十分钟后回炉的卡既不算白、也不解锁按钮:
         * 界面显示「待复习 0」,可实际上有几十张此刻就到期,用户被锁在门外。
         *
         * 现在把「有没有东西可学」的判断交给会话自己 —— 取到空队列就显示
         * 「学习完了」那一屏。按钮只在**这本书一张卡都没有**时才禁用。
         */
        Button(L(this.lang).startLearning)
          .width('90%').height(50).fontSize(17).fontWeight(FontWeight.Medium)
          .enabled(this.scopeCards > 0)
          .onClick(() => this.startSession())

        this.todayCard()

        if (this.status.length > 0) {
          Text(this.status).fontSize(12).fontColor('#48484A')
            .width('90%').textAlign(TextAlign.Center)
        }
      }
      .width('100%').padding({ top: 16, bottom: 24 })
    }
    .width('100%').height('100%')
    .backgroundColor('#F2F2F7')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }

  /** 一个可点的选项。**只接常量下标**,状态从 @State 取 */
  @Builder
  optionRow(i: number) {
    Column() {
      this.optionText(i)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
    .borderRadius(8)
    .backgroundColor(this.optionBg(i))
    .onClick(() => this.pickOption(i))
  }

  /**
   * 会话表头:三段进度条 + 正确率 + 平均用时(照搬 WordSnap)。
   * 没有作答过就显示 `--`,不显示 0% —— 0% 看起来像「全错」,而不是「还没开始」。
   */
  @Builder
  sessionHeader() {
    Column({ space: 6 }) {
      Row() {
        Text(this.deckLabel).fontSize(12).fontColor('#8A8A8E').layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(fmt(L(this.lang).remain, this.remaining)).fontSize(12).fontColor('#8A8A8E')
      }
      .width('100%')

      this.progressBar()

      Row() {
        Text(`${L(this.lang).accuracy} ${this.accuracyText()}`)
          .fontSize(11).fontColor('#8A8A8E').layoutWeight(1)
        Text(`${L(this.lang).avgTime} ${this.avgTimeText()}`)
          .fontSize(11).fontColor('#8A8A8E').layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text(this.timerText())
          .fontSize(11)
          .fontColor(this.elapsedMs >= T_GOOD_MS ? '#E5544B' : '#8A8A8E')
          .layoutWeight(1).textAlign(TextAlign.End)
      }
      .width('100%')
    }
    .width('90%').margin({ top: 10, bottom: 4 })
  }

  private accuracyText(): string {
    if (this.sesChoice === 0) {
      return '--';
    }
    return `${Math.round(100 * this.sesCorrect / this.sesChoice)}%`;
  }

  private avgTimeText(): string {
    if (this.sesChoice === 0) {
      return '--';
    }
    const sec: number = this.sesMs / this.sesChoice / 1000;
    return `${sec.toFixed(1)}${L(this.lang).unitSec}`;
  }

  /** 只有选择题显示读秒 —— 问答不设上限,给个秒数反而像在催 */
  private timerText(): string {
    if (this.cardType !== (NoteType.Choice as number) || this.judged !== 0) {
      return '';
    }
    const left: number = Math.max(0, Math.ceil((T_MAX_MS - this.elapsedMs) / 1000));
    return `${left}${L(this.lang).unitSec}`;
  }

  @Builder
  cardView() {
    Column() {
      this.sessionHeader()

      if (this.lastLine.length > 0) {
        Text(this.lastLine).fontSize(11).fontColor('#8A8A8E')
          .width('90%').margin({ bottom: 4 })
      }

      Scroll() {
        Column({ space: 12 }) {
          if (this.cardType === (NoteType.Cloze as number)) {
            Row() {
              Text(fmt(L(this.lang).clozeBlanks, this.cardBlanks))
                .fontSize(11).fontColor('#8A5A00')
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .borderRadius(6).backgroundColor('#FFF3C4')
            }.width('100%')
            this.stemView()
          } else {
            this.stemView()
          }

          if (this.cardOptions.length > 0) {
            Column({ space: 8 }) {
              ForEach(this.cardOptions, (opt: string, idx?: number) => {
                this.optionRow(idx as number)
              })
            }.width('100%')

            if (this.isMultiAnswer() && this.judged === 0) {
              Button(L(this.lang).confirmPick)
                .width('100%').height(40).fontSize(15).margin({ top: 4 })
                .enabled(this.picked.length > 0)
                .onClick(() => this.submitPick())
            }
          }

          if (this.revealed) {
            Divider().margin({ top: 4, bottom: 4 })
            // 结论先说清楚,再给答案和解析 —— 答错的人最需要的就是这一段
            if (this.judged === 1) {
              Text(L(this.lang).correctTitle).fontSize(16)
                .fontWeight(FontWeight.Bold).fontColor('#2E9E63').width('100%')
            } else if (this.judged === 2 || this.judged === 3) {
              Column({ space: 2 }) {
                Text(this.judged === 3 ? L(this.lang).timeUp : L(this.lang).wrongTitle)
                  .fontSize(16).fontWeight(FontWeight.Bold).fontColor('#E5544B').width('100%')
                Text(L(this.lang).whyWrong)
                  .fontSize(11).fontColor('#8A8A8E').width('100%')
              }
              .width('100%')
            }
            if (this.cardAnswer.length > 0) {
              Text(fmt(L(this.lang).answerIs, this.cardAnswer)).fontSize(17)
                .fontWeight(FontWeight.Bold).fontColor('#2E9E63').width('100%')
            }
            this.backView()
          }
        }
        // 右边多留一点:滚动条是浮在内容上的,不留空隙就会压住文字
        .width('100%').padding({ left: 4, right: 14, bottom: 12 })
      }
      .layoutWeight(1).width('90%').align(Alignment.Top)
      .scrollBarWidth(3)
      .scrollBarColor('#D0D3DA')

      if (this.cardType === (NoteType.Choice as number)) {
        // 选择题:点选项即作答,自动判档,没有「显示答案」也没有手动四档
        if (this.judged === 0) {
          // 「不知道」是一个真按钮。给一个诚实的出口,比逼人瞎猜好 ——
          // 猜对会把正确率和 FSRS 的稳定性一起抬高,那是假的
          Button(L(this.lang).dontKnow)
            .width('90%').height(44).fontSize(15).margin({ bottom: 14 })
            .backgroundColor('#F2F2F7').fontColor('#8A8A8E')
            .onClick(() => this.onDontKnow())
        } else if (this.judged === 1 && appStore().autoNext) {
          // 答对且设置了直接过:0.3 秒后自动翻页,这里只给一个绿色确认
          Row() {
            Text(L(this.lang).correctTitle)
              .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#2E9E63')
          }
          .width('90%').height(44).justifyContent(FlexAlign.Center).margin({ bottom: 14 })
        } else {
          Button(L(this.lang).nextOne)
            .width('90%').height(48).fontSize(16).margin({ bottom: 14 })
            .onClick(() => this.nextCard())
        }
      } else if (!this.revealed) {
        Button(L(this.lang).showAnswer)
          .width('90%').height(48).fontSize(16).margin({ bottom: 14 })
          .onClick(() => {
            this.revealed = true;
            if (this.cardType === (NoteType.Cloze as number)) {
              this.clozeFront = renderCloze(this.cardStem, true);
            }
          })
      } else {
        Row({ space: 8 }) {
          this.gradeButton(0)
          this.gradeButton(1)
          this.gradeButton(2)
          this.gradeButton(3)
        }
        .width('90%').margin({ bottom: 14 })
      }
    }
    .width('100%').height('100%')
  }

  /**
   * 「学习更多」:把**今天和明天**要复习的卡提前拿上来。
   *
   * 窗口是 (now, 明天结束的日界) —— 用 dayStart(dayIndex(now) + 2),
   * 所以「明天」的口径和别处一样走凌晨 1 点日界,不会在 00:30 把后天的卡拉进来。
   * 取卡按 due 升序,最快该复习的先来。
   *
   * 每次现算,不累加额度 —— 所以在 A 组点多少次都不会影响 B 组。
   */
  private studyMore(): void {
    const st = appStore();
    const now: number = Date.now();
    const to: number = dayStart(dayIndex(now) + 2);
    const ids: number[] = st.getDb().aheadCardIds(st.currentDeckId, now, to, st.aheadCount);
    if (ids.length === 0) {
      this.aheadNote = L(this.lang).studyMoreEmpty;
      return;
    }
    this.queue = ids;
    this.answered = 0;
    // **每开一轮都要清。** 不清的话正确率和平均用时会把上一轮的作答算进来 ——
    // 实测出现过「答对一题却显示 33%」,因为上一轮的「不知道」和超时还在分母里。
    this.resetSessionStats();
    this.aheadNote = '';
    this.nextCard();
  }

  @Builder
  done() {
    Column({ space: 12 }) {
      Text(L(this.lang).setDone).fontSize(22).fontWeight(FontWeight.Bold)
      Text(fmt(L(this.lang).answeredTimes, this.answered)).fontSize(14).fontColor('#8A8A8E')
      Text(fmt(L(this.lang).leftOver, this.dueCards, this.newCards))
        .fontSize(13).fontColor('#8A8A8E')
      Button(L(this.lang).studyMore)
        .width('70%').height(44).fontSize(15).margin({ top: 10 })
        .onClick(() => this.studyMore())
      Text(fmt(L(this.lang).studyMoreHint, appStore().aheadCount))
        .fontSize(11).fontColor('#8A8A8E')
      if (this.aheadNote.length > 0) {
        Text(this.aheadNote).fontSize(12).fontColor('#48484A')
          .width('80%').textAlign(TextAlign.Center)
      }
      Button(L(this.lang).backHome)
        .width('70%').height(44).fontSize(15)
        .backgroundColor('#E5E5EA').fontColor('#1C1C1E')
        .onClick(() => { this.refresh(); this.aheadNote = ''; this.stage = Stage.Landing; })
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center)
  }


  /**
   * 卡片正文。**有公式才用 WebView**,没有就走原生 Text + Span ——
   * 大多数卡片不含公式,不该为它们付 WebView 的启动代价。
   * 判断用 hasMath(),它复用 parseInline 的切片结果,与显示层同一套规则。
   */
  /**
   * 正文渲染分成三个「槽位」builder,**每个都在内部读状态,不接文字参数**。
   *
   * 这是踩过的坑:原来是 `cardText(src, ...)` 按值传参,而 ArkUI 里
   * 按值传参的 @Builder **不会响应状态更新** —— 于是翻到下一张卡时,
   * 选项(走常量下标 + 内部读状态)变了,题干却一直是上一张的,
   * 看起来就像「题目不变、选项乱跳」。
   *
   * MarkupText / MathText 是 @Component,@Prop 配 @Watch 能正常更新,
   * 所以把状态传给它们没问题 —— 问题只在 @Builder 的参数上。
   */
  @Builder
  stemView() {
    if (this.cardType === (NoteType.Cloze as number)) {
      if (hasMath(this.clozeFront)) {
        MathText({ source: this.clozeFront, fontPx: 17, lineHeightPx: 27 })
      } else {
        MarkupText({ source: this.clozeFront, fontPx: 17, lineHeightPx: 27, color: '#1C1C1E' })
      }
    } else {
      if (hasMath(this.cardStem)) {
        MathText({ source: this.cardStem, fontPx: 17, lineHeightPx: 27 })
      } else {
        MarkupText({ source: this.cardStem, fontPx: 17, lineHeightPx: 27, color: '#1C1C1E' })
      }
    }
  }

  /** 第 i 个选项的正文。**只接常量下标** */
  @Builder
  optionText(i: number) {
    if (hasMath(this.cardOptions[i])) {
      MathText({ source: this.cardOptions[i], fontPx: 15, lineHeightPx: 23 })
    } else {
      MarkupText({ source: this.cardOptions[i], fontPx: 15, lineHeightPx: 23, color: '#1C1C1E' })
    }
  }

  @Builder
  backView() {
    if (hasMath(this.cardBack)) {
      MathText({ source: this.cardBack, fontPx: 15, lineHeightPx: 24 })
    } else {
      MarkupText({ source: this.cardBack, fontPx: 15, lineHeightPx: 24, color: '#48484A' })
    }
  }

  build() {
    Column() {
      if (this.stage === Stage.Landing) {
        this.landing()
      } else if (this.stage === Stage.Card) {
        this.cardView()
      } else {
        this.done()
      }
    }
    .width('100%').height('100%').backgroundColor('#FFFFFF')
  }
}
