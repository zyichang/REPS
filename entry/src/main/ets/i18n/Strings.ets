/**
 * 界面文案表。
 *
 * **原则:界面文字跟随语言设置,卡片内容永远不翻译。**
 * 卡组名、正面、背面、选项都是用户自己的数据,任何情况下都原样显示。
 *
 * **ArkUI 铁律(WordSnap 上踩过):**
 * 语言必须从**可观察状态**里读,不能直接读 `appStore().lang`。
 * 普通对象字段变了不会触发重绘,界面会留在旧语言上,而编译器一声不响。
 * 所以各组件用 `@StorageLink(SK_LANG) lang: string`,再调 `L(this.lang)`。
 * 同理:**不要把 L() 的结果当参数传进 @Builder** —— 按值传参的 @Builder
 * 不响应更新,要在 @Builder 内部现取。
 *
 * 加键时两个实现都要补,否则编译器报缺字段 —— 这是故意的,防止漏翻。
 */

export interface Dict {
  // ---- 标签栏 ----
  tabStudy: string;
  tabStats: string;
  tabGlossary: string;
  tabMe: string;

  // ---- 学习页 ----
  appName: string;
  toLearn: string;
  toReview: string;
  /** 灰色段:今天答过、今天还会回来 —— 与进度条的灰严格同口径 */
  learning: string;
  startLearning: string;
  change: string;
  allDecks: string;
  noCardsYet: string;
  reviewToday: string;
  reviewTodayNone: string;
  reviewTodayCount: string;      // 用 %d 占位
  reviewTodayAgainHint: string;
  expand: string;
  collapse: string;
  remain: string;
  showAnswer: string;
  clozeBlanks: string;           // %d
  setDone: string;
  answeredTimes: string;         // %d
  leftOver: string;              // %d %d
  studyMore: string;
  studyMoreHint: string;         // %d
  studyMoreEmpty: string;
  backHome: string;
  importing: string;
  nextIn: string;

  // ---- 词卡表 ----
  menuSwitchBook: string;
  menuImport: string;
  menuGoStudy: string;
  newCard: string;
  cardBrowse: string;
  browseHint: string;
  cardsUnit: string;
  switchBookTitle: string;
  cardsTitle: string;
  previewTitle: string;
  editCardTitle: string;
  newCardTitle: string;
  front: string;
  back: string;
  preview: string;
  edit: string;
  save: string;
  deleteCard: string;
  confirmDelete: string;
  cancelDelete: string;
  deleteDeck: string;
  deleteDeckTitle: string;
  deleteDeckBody: string;
  deleteDeckIrreversible: string;
  deletedDeck: string;
  clearProgress: string;
  clearProgressHint: string;
  clearConfirmTitle: string;
  clearConfirmBody: string;      // %s %d
  clearIrreversible: string;
  confirmClear: string;
  cancel: string;
  deckDescEmpty: string;
  deckDesc: string;             // %d %d %d
  newCardBadge: string;
  reviewedTimes: string;        // %d
  typeQA: string;
  typeChoice: string;
  typeCloze: string;
  frontPlaceholder: string;
  backPlaceholder: string;
  allDecksNoNew: string;
  pickBookFirst: string;
  noDeckMix: string;
  handWriteHint: string;

  // ---- 我的 ----
  meTitle: string;
  notSignedIn: string;
  accountLocalHint: string;
  loginReadyHint: string;
  currentStudy: string;
  algoSection: string;
  algoHint: string;
  dailySection: string;
  /** 入口行的摘要:复习 %s · 新卡 %s · 提前 %s */
  setSummary: string;
  reviewLimit: string;
  reviewLimitHint: string;
  newPerDay: string;
  newPerDayHint: string;
  retention: string;
  retentionHint: string;
  aheadCount: string;
  aheadCountHint: string;
  dailyHint: string;
  unlimited: string;
  langSection: string;
  langHint: string;
  langChinese: string;
  langEnglish: string;
  formatSection: string;
  formatValue: string;
  formatDispatch: string;
  formatMarkdown: string;
  formatYaml: string;
  formatAnki: string;
  aboutSection: string;
  aboutTagline: string;
  aboutLocal: string;

  // ---- 账号 ----
  accountTitle: string;
  noBackendTitle: string;
  noBackendBody: string;
  accountField: string;
  accountPlaceholder: string;
  passwordField: string;
  passwordPlaceholder: string;
  signIn: string;
  signOut: string;
  currentAccount: string;
  notSynced: string;
  signUpLater: string;
  needBoth: string;
  signedInLocal: string;
  signedOut: string;

 // ---- 作答反馈 ----
  dontKnow: string;
  nextOne: string;
  correctTitle: string;
  wrongTitle: string;
  whyWrong: string;
  autoNextLabel: string;
  autoNextOn: string;
  autoNextOff: string;
  autoNextHint: string;

 // ---- 作答与计时 ----
  accuracy: string;
  avgTime: string;
  unitSec: string;
  timeUp: string;
  confirmPick: string;
  pickHint: string;
  correctMark: string;
  wrongMark: string;

 // ---- 状态提示 ----
  readFailed: string;
  importedTo: string;
  importFailed: string;
  switchedTo: string;
  switchedAll: string;
  cannotClearAll: string;
  clearedProgress: string;
  createdCard: string;
  savedEdit: string;
  deletedCard: string;
  saveFailed: string;
  bootFailed: string;
  openingDb: string;
  answerIs: string;
  nextAfter: string;
  recentWeeks: string;
  forecastDays: string;
  algoFsrsHint: string;
  algoEbbinghausHint: string;

 // ---- 统计 ----
  statsTitle: string;
  studyDays: string;
  streakDays: string;
  totalAnswers: string;
  retentionRate: string;
  masterySpread: string;
  /** 统计页上半段:与选哪本书无关的总体数字 */
  sectionAll: string;
  /** 统计页下半段:只算当前这本书 */
  sectionBook: string;
  /** 最近 7 天学习时长 */
  studyTime: string;
  /** 时长单位,短写 */
  minutesShort: string;
  /** 这 7 天没有记录时的占位 */
  noTimeYet: string;
  noReviewYet: string;
  weekdays: string;              // 七个标签,用 | 分隔
  mastery: string;               // 五档,用 | 分隔

  // ---- 间隔单位(前面带空格) ----
  unitYear: string;
  unitMonth: string;
  unitDay: string;
  unitHour: string;
  unitMinute: string;

  // ---- 排期引擎名 ----
  algoFsrs: string;
  algoEbbinghaus: string;

  // ---- 评级 / 阶段 ----
  gradeAgain: string;
  gradeHard: string;
  gradeGood: string;
  gradeEasy: string;
  phaseNew: string;
  phaseLearning: string;
  phaseReview: string;
  phaseRelearn: string;
}

const ZH: Dict = {
  tabStudy: '学习', tabStats: '统计', tabGlossary: '词卡表', tabMe: '我的',

  appName: '刻意重复',
  toLearn: '待学习', toReview: '待复习', learning: '学习中',
  startLearning: '开始学习', change: '切换', allDecks: '全部卡组',
  noCardsYet: '还没有卡片,先导入一个文件',
  reviewToday: '回顾今日已学',
  reviewTodayNone: '今天还没答过卡',
  reviewTodayCount: '今天答过 %d 张',
  reviewTodayAgainHint: '点一下,把今天做过的卡再过一遍',
  expand: '展开', collapse: '收起',
  remain: '剩 %d', showAnswer: '显示答案',
  clozeBlanks: '完形填空 · %d 个空',
  setDone: '今天的一组做完了',
  answeredTimes: '本次作答 %d 次',
  leftOver: '剩余待复习 %d · 新卡 %d',
  studyMore: '学习更多',
  studyMoreHint: '提前复习今天和明天的卡,每次 %d 张',
  studyMoreEmpty: '今天和明天都没有待复习的卡了 —— 可以歇了,或者去卡组里导入新的',
  backHome: '回到首页',
  importing: '正在导入…',
  nextIn: '下次',

  menuSwitchBook: '切换课本', menuImport: '导入课本', menuGoStudy: '去学习',
  newCard: '新建卡片', cardBrowse: '浏览卡片',
  browseHint: '进去可以预览和编辑', cardsUnit: '张',
  switchBookTitle: '切换课本', cardsTitle: '卡片',
  previewTitle: '预览', editCardTitle: '编辑卡片', newCardTitle: '新建卡片',
  front: '正面', back: '背面', preview: '预览', edit: '编辑',
  save: '保存', deleteCard: '删除这张卡',
  confirmDelete: '确认删除', cancelDelete: '取消删除',
  deleteDeck: '删除', deleteDeckTitle: '删除这本课本?',
  deleteDeckBody: '「%s」及其 %d 张卡会被整本删掉,复习历史一并清除。',
  deleteDeckIrreversible: '卡片本身也会删掉,这个操作不能撤销。',
  deletedDeck: '已删除「%s」',
  clearProgress: '清空本书进度', clearProgressHint: '卡片保留,只退回新卡',
  clearConfirmTitle: '清空这本书的进度?',
  clearConfirmBody: '「%s」的 %d 张卡会全部变回新卡:排期和复习历史都会删掉,卡片本身一张不删。',
  clearIrreversible: '这个操作不能撤销。',
  confirmClear: '确认清空', cancel: '取消',
  deckDescEmpty: '还没有卡片',
  deckDesc: '%d 张卡 · 待复习 %d · 新卡 %d',
  newCardBadge: '新卡', reviewedTimes: '已复习 %d 次',
  typeQA: '问答', typeChoice: '选择', typeCloze: '挖空',
  frontPlaceholder: '题目。{{答案}} 是挖空,;;; 块是选择题',
  backPlaceholder: '答案或解析',
  allDecksNoNew: '「全部卡组」下不能新建 —— 先用三个点切到某一本课本',
  pickBookFirst: '先切到某一本课本',
  noDeckMix: '不分课本,所有卡一起学',
  handWriteHint: '手写一张,题型由内容决定',

  meTitle: '我的',
  notSignedIn: '未登录',
  accountLocalHint: '本机记录,尚未同步',
  loginReadyHint: '登录界面已就绪,后端还没定',
  currentStudy: '当前学习',
  algoSection: '排期算法',
  algoHint: '两个引擎共用同一份学习记录,随时切换不丢进度。',
  dailySection: '今日集合',
  setSummary: '复习 %s · 新卡 %s · 提前 %s',
  reviewLimit: '每日复习上限',
  reviewLimitHint: '积压再多,一天也只出这么多张 —— 没有上限会变成打开即劝退',
  newPerDay: '每日新卡额度',
  newPerDayHint: '每天最多引入多少张没学过的卡',
  retention: '目标保持率',
  retentionHint: '想记住的比例。调高会让间隔变短、复习变密',
  aheadCount: '学习更多 每次张数',
  aheadCountHint: '做完今天的一组后,点「学习更多」一次提前拿几张。每次现算,不累加',
  dailyHint: '点一行拨滚轮选数值。今日集合在按下「开始学习」时一次定好,中途不追加。',
  unlimited: '不限',
  langSection: '语言',
  langHint: '点一行切换。切换立刻生效,不用重启。',
  langChinese: '中文', langEnglish: 'English',
  formatSection: '导入格式',
  formatValue: 'Quizify Card Markdown v1  ·  YAML 卡组',
  formatDispatch: '两种都收,按扩展名分派:.md / .markdown 走 Quizify,'
    + '.yaml / .yml 走 YAML。两条路产出的卡片形状完全一致。',
  formatMarkdown: 'Markdown:+++ 起一张卡,*** 切正反面,;;; 块是选择题,{{挖空}} 是完形填空。',
  formatYaml: 'YAML:顶层写 deck 和 cards,每张卡只有 front 和 back;'
    + '两者必须用引号或 | 块标量。',
  formatAnki: '与 Anki 的 Quizify Markdown 插件同一套语法,所以卡组可以双向流动。',
  aboutSection: '关于',
  aboutTagline: '一天的学习量是 a set,一次作答是 a rep。',
  aboutLocal: '纯本地运行,不申请任何权限。卡片来自你自己的文件,'
    + '排期算在设备上,数据库在应用沙箱里。',

  accountTitle: '账号',
  noBackendTitle: '还没有服务端',
  noBackendBody: '这一页只是界面。不会联网,也不会保存密码 —— '
    + '请不要在这里输入你在别处真正使用的密码。',
  accountField: '账号', accountPlaceholder: '邮箱或手机号',
  passwordField: '密码', passwordPlaceholder: '密码',
  signIn: '登录', signOut: '退出登录',
  currentAccount: '当前账号', notSynced: '本机记录,未同步到任何地方',
  signUpLater: '注册 / 忘记密码 —— 等后端定下来再做',
  needBoth: '账号和密码都要填',
  signedInLocal: '已记住账号名(仅本机)。后端接好之前,这不是真正的登录。',
  signedOut: '已退出(只是清掉本机记录)',

 dontKnow: '不知道', nextOne: '下一个',
  correctTitle: '回答正确', wrongTitle: '回答错误',
  whyWrong: '正确答案与解析',
  autoNextLabel: '答对后', autoNextOn: '直接下一张', autoNextOff: '停留看解析',
  autoNextHint: '答错永远会停下来看解析,不受这个开关影响',

 accuracy: '正确率', avgTime: '平均用时', unitSec: '秒',
  timeUp: '超过 60 秒,按「忘了」处理', confirmPick: '确认',
  pickHint: '选一个', correctMark: '答对', wrongMark: '答错',

 readFailed: '读取失败: %s', importedTo: '已导入 %d 张卡到「%s」',
  importFailed: '导入失败:%s', switchedTo: '已切到「%s」,学习页也跟着换了',
  switchedAll: '已切到全部卡组', cannotClearAll: '「全部卡组」下不能清空 —— 先切到某一本课本',
  clearedProgress: '已清空「%s」的进度,%d 张卡全部变回新卡',
  createdCard: '已新建一张卡', savedEdit: '已保存修改', deletedCard: '已删除这张卡',
  saveFailed: '保存失败: %s', bootFailed: '启动失败: %s', openingDb: '正在打开数据库…',
  answerIs: '答案 %s', nextAfter: ' · 下次 %s后',
  recentWeeks: '最近 %d 周', forecastDays: '未来 %d 天的复习量',
  algoFsrsHint: '按记忆模型自适应:为每张卡维护稳定性与难度,间隔因卡而异',
  algoEbbinghausHint: '固定阶梯 5 分钟→30 分钟→12 小时→1/2/4/7/15/30/60/120 天,完全可预测',

 statsTitle: '统计', studyDays: '学习天数', streakDays: '连续天数',
  totalAnswers: '总作答', retentionRate: '保持率', masterySpread: '掌握度分布',
  sectionAll: '全部卡组', sectionBook: '当前课本',
  studyTime: '最近 7 天学习时长', minutesShort: '分',
  noTimeYet: '这 7 天还没有学习记录',
  noReviewYet: '还没有复习记录', weekdays: '日|一|二|三|四|五|六',
  mastery: '未学|生疏|眼熟|熟练|已掌握',
  unitYear: ' 年', unitMonth: ' 个月', unitDay: ' 天',
  unitHour: ' 小时', unitMinute: ' 分钟',
  algoFsrs: 'FSRS-6', algoEbbinghaus: '艾宾浩斯固定阶梯',

  gradeAgain: '忘了', gradeHard: '困难', gradeGood: '良好', gradeEasy: '简单',
  phaseNew: '新卡', phaseLearning: '学习中', phaseReview: '复习中', phaseRelearn: '重学中',
};

const EN: Dict = {
  tabStudy: 'Learn', tabStats: 'Stats', tabGlossary: 'Glossary', tabMe: 'Me',

  appName: 'REPS',
  toLearn: 'To learn', toReview: 'To review', learning: 'Learning',
  startLearning: 'Learning', change: 'Change', allDecks: 'All decks',
  noCardsYet: 'No cards yet — import a file first',
  reviewToday: "Review today's cards",
  reviewTodayNone: 'Nothing answered today',
  reviewTodayCount: 'Answered %d today',
  reviewTodayAgainHint: 'Tap to run through today’s cards again',
  expand: 'Expand', collapse: 'Collapse',
  remain: '%d left', showAnswer: 'Show answer',
  clozeBlanks: 'Cloze · %d blanks',
  setDone: "Today's set is done",
  answeredTimes: 'Answered %d this session',
  leftOver: 'To review %d · New %d',
  studyMore: 'Study more',
  studyMoreHint: "Review today's and tomorrow's cards early, %d at a time",
  studyMoreEmpty: 'Nothing left for today or tomorrow — rest, or import a new deck',
  backHome: 'Back to home',
  importing: 'Importing…',
  nextIn: 'Next in',

  menuSwitchBook: 'Switch book', menuImport: 'Import book', menuGoStudy: 'Go study',
  newCard: 'New card', cardBrowse: 'Card browse',
  browseHint: 'preview and edit inside', cardsUnit: 'cards',
  switchBookTitle: 'Switch book', cardsTitle: 'Cards',
  previewTitle: 'Preview', editCardTitle: 'Edit card', newCardTitle: 'New card',
  front: 'Front', back: 'Back', preview: 'Preview', edit: 'Edit',
  save: 'Save', deleteCard: 'Delete this card',
  confirmDelete: 'Confirm delete', cancelDelete: 'Keep card',
  deleteDeck: 'Delete', deleteDeckTitle: 'Delete this book?',
  deleteDeckBody: '“%s” and all %d of its cards will be removed, along with their review history.',
  deleteDeckIrreversible: 'The cards themselves are deleted too. This cannot be undone.',
  deletedDeck: 'Deleted “%s”',
  clearProgress: 'Clear this book’s progress', clearProgressHint: 'cards kept, reset to new',
  clearConfirmTitle: 'Clear this book’s progress?',
  clearConfirmBody: 'All %d cards in “%s” go back to new: scheduling and review history '
    + 'are deleted. No card itself is removed.',
  clearIrreversible: 'This cannot be undone.',
  confirmClear: 'Confirm clear', cancel: 'Cancel',
  deckDescEmpty: 'No cards yet',
  deckDesc: '%d cards · %d to review · %d new',
  newCardBadge: 'New', reviewedTimes: 'Reviewed %d times',
  typeQA: 'Q&A', typeChoice: 'Choice', typeCloze: 'Cloze',
  frontPlaceholder: 'Question. {{answer}} is a blank, a ;;; block is multiple choice',
  backPlaceholder: 'Answer or explanation',
  allDecksNoNew: 'Cannot create under “All decks” — switch to a book from the ⋯ menu',
  pickBookFirst: 'Switch to a book first',
  noDeckMix: 'All books together, no separation',
  handWriteHint: 'Write one by hand; the type follows the content',

  meTitle: 'Me',
  notSignedIn: 'Not signed in',
  accountLocalHint: 'Stored on this device, not synced',
  loginReadyHint: 'Login screen is ready; no backend chosen yet',
  currentStudy: 'Currently studying',
  algoSection: 'Scheduler',
  algoHint: 'Both engines share one review history; switch any time without losing progress.',
  dailySection: "Today's set",
  setSummary: 'Review %s · New %s · Ahead %s',
  reviewLimit: 'Daily review cap',
  reviewLimitHint: 'However big the backlog, only this many appear per day',
  newPerDay: 'New cards per day',
  newPerDayHint: 'How many unseen cards to introduce each day',
  retention: 'Target retention',
  retentionHint: 'How much you want to remember. Higher means shorter, denser intervals',
  aheadCount: 'Study more · batch size',
  aheadCountHint: "How many cards 'Study more' pulls forward each tap. "
    + 'Recomputed each time, never accumulated',
  dailyHint: "Tap a row to pick a value on the wheel. The day's set is fixed when you press "
    + 'Learning and is not topped up mid-session.',
  unlimited: 'Unlimited',
  langSection: 'Language',
  langHint: 'Tap a row to switch. Takes effect immediately, no restart.',
  langChinese: '中文', langEnglish: 'English',
  formatSection: 'Import format',
  formatValue: 'Quizify Card Markdown v1  ·  YAML decks',
  formatDispatch: 'Both are accepted, dispatched by extension: .md / .markdown use Quizify, '
    + '.yaml / .yml use YAML. Both paths produce identical cards.',
  formatMarkdown: 'Markdown: +++ starts a card, *** splits front from back, '
    + 'a ;;; block is multiple choice, {{blank}} is a cloze.',
  formatYaml: 'YAML: deck and cards at the top level; each card has only front and back, '
    + 'both quoted or written as a | block scalar.',
  formatAnki: 'Same syntax as the Quizify Markdown add-on for Anki, so decks flow both ways.',
  aboutSection: 'About',
  aboutTagline: "A day's workload is a set; one answer is a rep.",
  aboutLocal: 'Runs entirely on device and requests no permissions. Cards come from your own '
    + 'files, scheduling is computed locally, and the database stays in the app sandbox.',

  accountTitle: 'Account',
  noBackendTitle: 'No server yet',
  noBackendBody: 'This screen is UI only. It does not go online and does not store your '
    + 'password — please do not type a password you use elsewhere.',
  accountField: 'Account', accountPlaceholder: 'Email or phone',
  passwordField: 'Password', passwordPlaceholder: 'Password',
  signIn: 'Sign in', signOut: 'Sign out',
  currentAccount: 'Current account', notSynced: 'Stored on this device only',
  signUpLater: 'Sign up / forgot password — once the backend is settled',
  needBoth: 'Fill in both account and password',
  signedInLocal: 'Account name remembered on this device. Not a real sign-in until the '
    + 'backend exists.',
  signedOut: 'Signed out (local record cleared)',

 dontKnow: "Don't know", nextOne: 'Next',
  correctTitle: 'Correct', wrongTitle: 'Incorrect',
  whyWrong: 'Answer and explanation',
  autoNextLabel: 'After a correct answer', autoNextOn: 'Go straight on',
  autoNextOff: 'Stay on the explanation',
  autoNextHint: 'A wrong answer always stops on the explanation, regardless of this',

 accuracy: 'Accuracy', avgTime: 'Avg time', unitSec: 's',
  timeUp: 'Over 60s — counted as Again', confirmPick: 'Confirm',
  pickHint: 'Pick one', correctMark: 'Correct', wrongMark: 'Wrong',

 readFailed: 'Read failed: %s', importedTo: 'Imported %d cards into “%s”',
  importFailed: 'Import failed: %s', switchedTo: 'Switched to “%s”; the Learn tab follows',
  switchedAll: 'Switched to all decks',
  cannotClearAll: 'Cannot clear under “All decks” — switch to a book first',
  clearedProgress: 'Cleared progress for “%s”; all %d cards are new again',
  createdCard: 'Card created', savedEdit: 'Changes saved', deletedCard: 'Card deleted',
  saveFailed: 'Save failed: %s', bootFailed: 'Startup failed: %s',
  openingDb: 'Opening the database…',
  answerIs: 'Answer %s', nextAfter: ' · next in %s',
  recentWeeks: 'Last %d weeks', forecastDays: 'Reviews due over %d days',
  algoFsrsHint: 'Adapts to a memory model: tracks stability and difficulty per card, '
    + 'so intervals differ card by card',
  algoEbbinghausHint: 'Fixed ladder 5min→30min→12h→1/2/4/7/15/30/60/120d, fully predictable',

 statsTitle: 'Stats', studyDays: 'Days studied', streakDays: 'Streak',
  totalAnswers: 'Answers', retentionRate: 'Retention', masterySpread: 'Mastery spread',
  sectionAll: 'All decks', sectionBook: 'Current book',
  studyTime: 'Study time, last 7 days', minutesShort: 'm',
  noTimeYet: 'No study records in the last 7 days',
  noReviewYet: 'No reviews yet', weekdays: 'S|M|T|W|T|F|S',
  mastery: 'Unseen|Shaky|Familiar|Solid|Mastered',
  unitYear: 'y', unitMonth: 'mo', unitDay: 'd',
  unitHour: 'h', unitMinute: 'min',
  algoFsrs: 'FSRS-6', algoEbbinghaus: 'Ebbinghaus fixed ladder',

  gradeAgain: 'Again', gradeHard: 'Hard', gradeGood: 'Good', gradeEasy: 'Easy',
  phaseNew: 'New', phaseLearning: 'Learning', phaseReview: 'Review', phaseRelearn: 'Relearning',
};

export const LANG_ZH: string = 'zh';
export const LANG_EN: string = 'en';

/** 取文案表。认不出的语言码一律按中文 —— 宁可显示中文,不要显示空白 */
export function L(lang: string): Dict {
  return lang === LANG_EN ? EN : ZH;
}

/**
 * 把 `%d` / `%s` 依次换成给定的值。
 * 只做位置替换,不做本地化数字格式 —— 目前两种语言都用阿拉伯数字。
 */
export function fmt(tpl: string, a?: string | number, b?: string | number,
                   c?: string | number): string {
  const args: string[] = [];
  if (a !== undefined) {
    args.push(`${a}`);
  }
  if (b !== undefined) {
    args.push(`${b}`);
  }
  if (c !== undefined) {
    args.push(`${c}`);
  }
  let out = '';
  let ai = 0;
  let i = 0;
  while (i < tpl.length) {
    const ch = tpl.charAt(i);
    if (ch === '%' && i + 1 < tpl.length) {
      const nx = tpl.charAt(i + 1);
      if ((nx === 'd' || nx === 's') && ai < args.length) {
        out += args[ai];
        ai++;
        i += 2;
        continue;
      }
    }
    out += ch;
    i++;
  }
  return out;
}

/** 评级文字,下标对应 Grade 的 0..3 */
export function gradeLabels(lang: string): string[] {
  const d = L(lang);
  return [d.gradeAgain, d.gradeHard, d.gradeGood, d.gradeEasy];
}

/** 阶段文字,下标对应 Phase */
export function phaseLabels(lang: string): string[] {
  const d = L(lang);
  return [d.phaseNew, d.phaseLearning, d.phaseReview, d.phaseRelearn];
}

/** 间隔单位。Srs / Ebbinghaus 靠 setIntervalUnits 注入,避免它们依赖 i18n 模块 */
export interface IntervalUnits {
  year: string;
  month: string;
  day: string;
  hour: string;
  minute: string;
}

export function intervalUnits(lang: string): IntervalUnits {
  const d = L(lang);
  return {
    year: d.unitYear, month: d.unitMonth, day: d.unitDay,
    hour: d.unitHour, minute: d.unitMinute,
  };
}

/** 引擎显示名,下标 0=fsrs / 1=ebbinghaus */
export function algoLabels(lang: string): string[] {
  const d = L(lang);
  return [d.algoFsrs, d.algoEbbinghaus];
}

/** 掌握度五档,下标对应 masteryOf() 的返回值 */
export function masteryLabels(lang: string): string[] {
  return L(lang).mastery.split('|');
}
