# ADR-0003 · 公式用真 KaTeX + ArkWeb,切片仍在原生侧

- **状态**:已接受
- **日期**:2026-09-25
- **相关**:`view/MathText.ets`、`resources/rawfile/katex/`、`data/Inline.ets`
- **取代**:CONTEXT.md 里「数学公式:推迟,v1 显示 `$...$` 原文」

## 背景

v1 把公式渲染推迟了,卡片上直接显示 `$O(\log n)$` 原文。用户要求处理,
并且愿意为此改卡片格式:「如果 KaTeX 不支持 dollar,我们就改成它支持的包裹符」。

两件事需要先查清:

**一、KaTeX 到底支不支持 `$…$`?** 支持。只是它的 auto-render 扩展**默认**
不含单个 `$`(默认是 `$$…$$`、`\(…\)`、`\[…\]`),把 `$` 写进 `delimiters`
配置即可。所以**不需要改任何卡片内容** —— 这很重要,因为 Quizify 规范本来就
规定用 `$…$`,而且用户 PKB 里已有近两万处。

**二、能不能不用 WebView,用 ArkUI 原生画一个 LaTeX 子集?** 不能。
把用户 PKB 语料扫了一遍:

| 出现次数 | |
|---|---|
| 行内 `$…$` | **19 636** |
| `$$` 公式块 | 3 378 |
| `\frac` + `\dfrac` | 10 734 |
| `\mathrm` / `\boldsymbol` | 8 383 / 5 973 |
| `\int` | 2 822 |
| `\left` / `\right` | 2 289 / 2 289 |
| `\begin` / `\end` 环境 | 1 315 / 1 315 |

`\dfrac`、`\int_0^1`、`\left(…\right)` 自适应括号、`\begin{pmatrix}` 这些
用 Text + Span 拼不出来。原本准备提的「原生子集渲染」方案,被这组数字否掉了 ——
它只够应付 `x^2` 那种,对这份语料远远不够。

## 决定

1. **内嵌真正的 KaTeX**,版本钉在 **v0.18.9**(MIT),放在
   `entry/src/main/resources/rawfile/katex/`,用 ArkWeb 的 `Web` 组件渲染。
   下载时校验过官方发布的 sha256。
   只保留 `katex.min.js`、`katex.min.css` 和 `fonts/*.woff2`(20 个),
   丢掉 `.woff` / `.ttf` 回退 —— CSS 里 woff2 排在第一位,那两种永远不会被请求。
   共约 600 KB。
2. **切片继续在原生侧做,KaTeX 只负责排版。** 传给页面的是
   `parseInline()` 已经切好的片段数组,不是整段原文。因此:
   - 不需要 auto-render,也不需要配 `delimiters`
   - 「价格是 $100 元」不会被误判成公式 —— 那个判断解析器早就做对了,
     `inline_test.ts` 里有断言盯着,不必在 JS 里重做一遍
3. **只有含公式的文本才走 WebView。** `hasMath()` 为假时走原来的
   `MarkupText`(Text + Span)。多数卡片不含公式,不该为它们付 WebView 的代价。
4. **公式写错时显示红色原文**,不留白。一张卡不该因为一个反斜杠打错就没法复习。
5. **卡片格式不变**,继续用 `$…$` / `$$…$$`。

## 实现要点

- **高度必须由页面回报。** `Web` 组件不会自己长到内容高度;不接
  `arkBridge.onHeight` 回调,卡片就会被截断或留下大片空白。
  字体是异步加载的,所以 `document.fonts.ready` 之后再报一次。
- **`@Prop source` 必须带 `@Watch`。** 这是实测踩到的坑:翻到下一张卡时
  ArkUI 复用同一个组件实例、只更新 `@Prop`,**不会再调 `aboutToAppear`** ——
  少了 `@Watch`,WebView 会一直停在上一张卡的内容上。
  现象很隐蔽:第二张卡的高度和第一张一模一样,而且没有新的渲染日志。
  `MarkupText` 早就用了同一个模式,照抄即可。
- **渲染自检。** WebView 内部不出现在 `uitest dumpLayout` 里,截图通道也不可用,
  所以页面会把 `{katex, attempted, failed, rendered, chars}` 报回原生并写进
  hilog。这是确认公式真的排版成功的唯一手段,保留它。
- **关掉不需要的 Web 能力**:`domStorageAccess`、`imageAccess`、
  `onlineImageAccess` 全部为 false,`trust: false` 禁掉 `\href`、
  `\includegraphics` 这类有副作用的命令。本地壳不该有联网或改存储的能力。

## 实机验证(2026-09-25)

| 项 | 结果 |
|---|---|
| KaTeX 从 rawfile 加载 | `{"katex":true,…}` |
| 含公式卡片 | 出现 `Web` 组件,src = `resource:/RAWFILE/katex/index.html` |
| 排版成功 | `attempted:1, failed:0, rendered:1`(DOM 里有 `.katex` 节点) |
| 高度自适应 | Web 高度 126 / 150 / 315 px,随内容变化,不是固定兜底值 |
| 翻页重渲染 | 连续三张卡 `chars` 依次为 33 / 64 / 115,内容确实在变 |
| **无公式卡片不起 WebView** | 专门做的两卡「路由测试」卡组:无公式那张 `Web components: 0`,正文由原生 Text 渲染 |
| HAP 体积 | 1.60 MB(内嵌 KaTeX 之后) |

桌面套件 10/10 全过。

## 代价

- 安装包 +600 KB。
- 含公式的卡片渲染是异步的,首次显示可能有一帧高度跳动(已用 `MIN_H` 兜底缓解)。
- WebView 里的文本不能和原生卡片共用选中/长按行为。目前不需要,将来若要加
  「长按查词」得两条路径各做一次。
