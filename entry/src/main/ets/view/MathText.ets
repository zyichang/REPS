/**
 * 数学公式文本。**只在文本里真的有公式时才用**。
 *
 * 为什么必须走 WebView:实测用户 PKB 语料里有 19636 处行内 `$…$`、3378 个
 * `$$` 公式块,`\frac`/`\dfrac` 合计一万多次,还有 `\int`、`\left…\right`
 * 自适应括号和 `\begin{}` 环境。这些用 ArkUI 的 Text + Span 拼不出来,
 * 只能交给真正的 KaTeX。见 docs/adr/0003。
 *
 * 两个关键设计:
 *
 * 1. **切片在原生侧做,KaTeX 只负责排版。** 传过去的是 `parseInline()` 已经
 *    切好的片段数组,而不是整段原文 —— 所以不需要 KaTeX 的 auto-render,
 *    也就不会把「价格是 $100 元」误判成公式。那个判断解析器已经做过了。
 * 2. **高度由页面回报。** Web 组件不会自己长到内容高度;不接这个回调,
 *    卡片就会被截断或留下大片空白。字体是异步加载的,所以 fonts.ready
 *    之后会再报一次。
 *
 * 公式写错时显示红色原文,不留白 —— 一张卡不该因为一个反斜杠打错就没法复习。
 */

import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  Block, BlockKind, InlineKind, InlineSpan, parseInline, splitBlocks,
} from '../data/Inline';

const DOMAIN: number = 0x0A01;
const TAG: string = 'REPS-Math';

/** 没有公式时的兜底高度,拿到回报之前先占这么高,避免跳动太剧烈 */
const MIN_H: number = 28;

/** 传给页面的片段。字段名压到一个字母 —— 每张卡都要序列化一次 */
interface WireSpan {
  t: string;
  k: number;
}

/** 一块内容。k='c' 是代码块(原样显示),否则是段落(带行内片段) */
interface WireBlock {
  k: string;
  t: string;
  spans: WireSpan[];
}

interface WirePayload {
  fontPx: number;
  lineHeightPx: number;
  blocks: WireBlock[];
}

/** 文本里有没有需要 KaTeX 的东西。没有就别付 WebView 的代价 */
export function hasMath(text: string): boolean {
  for (const sp of parseInline(text)) {
    if (sp.kind === InlineKind.Math) {
      return true;
    }
  }
  return false;
}

@Component
export struct MathText {
  /**
   * **@Watch 是必须的。** 卡片翻页时 ArkUI 复用同一个组件实例,只更新 @Prop,
   * 不会再调 aboutToAppear —— 少了这个装饰器,WebView 会一直停在上一张卡的
   * 内容上。实测就是这么翻车的:第二张卡的高度和第一张一模一样,
   * 而且没有新的渲染自检日志。MarkupText 早就用了同一个模式。
   */
  @Prop @Watch('onSourceChange') source: string;
  @Prop fontPx: number;
  @Prop lineHeightPx: number;

  private controller: webview.WebviewController = new webview.WebviewController();
  /** 页面报回来的内容高度 */
  @State private contentH: number = MIN_H;
  /** 壳加载完之前不能调 runJavaScript */
  private ready: boolean = false;
  /** 壳还没好时先存着,ready 之后立刻灌进去 */
  private pending: string = '';

  private payload(): string {
    const blocks: WireBlock[] = [];
    for (const b of splitBlocks(this.source)) {
      if (b.kind === BlockKind.Code) {
        // 代码块不切行内:代码里的 * _ $ 都是字面意思
        blocks.push({ k: 'c', t: b.text, spans: [] });
      } else {
        const spans: WireSpan[] = [];
        for (const sp of parseInline(b.text)) {
          spans.push({ t: sp.text, k: sp.kind as number });
        }
        blocks.push({ k: 'p', t: '', spans: spans });
      }
    }
    const p: WirePayload = {
      fontPx: this.fontPx,
      lineHeightPx: this.lineHeightPx,
      blocks: blocks,
    };
    return JSON.stringify(p);
  }

  /** 把内容送进页面。JSON 再套一层 stringify 是为了安全地当成 JS 字面量传入 */
  private push(): void {
    const json: string = this.payload();
    if (!this.ready) {
      this.pending = json;
      return;
    }
    try {
      this.controller.runJavaScript(`window.renderCard(${JSON.stringify(json)})`);
    } catch (e) {
      hilog.error(DOMAIN, TAG, '注入失败: %{public}s', `${e}`);
    }
  }

  build() {
    Web({ src: $rawfile('katex/index.html'), controller: this.controller })
      .width('100%')
      .height(this.contentH)
      .backgroundColor(Color.Transparent)
      // 本地壳不需要联网。关掉可以避免卡片里的外链被悄悄加载。
      .domStorageAccess(false)
      .imageAccess(false)
      .onlineImageAccess(false)
      .javaScriptAccess(true)
      .verticalScrollBarAccess(false)
      .horizontalScrollBarAccess(false)
      .javaScriptProxy({
        object: {
          onHeight: (h: number): void => {
            const v: number = Math.max(MIN_H, Math.ceil(h));
            if (v !== this.contentH) {
              this.contentH = v;
            }
          },
          onStats: (json: string): void => {
            // 渲染自检。WebView 内部不在 dumpLayout 里,这行日志是确认
            // KaTeX 真的排版成功的唯一手段。
            hilog.info(DOMAIN, TAG, '渲染自检 %{public}s', json);
          },
          onReady: (): void => {
            this.ready = true;
            if (this.pending.length > 0) {
              const json: string = this.pending;
              this.pending = '';
              try {
                this.controller.runJavaScript(`window.renderCard(${JSON.stringify(json)})`);
              } catch (e) {
                hilog.error(DOMAIN, TAG, '注入失败: %{public}s', `${e}`);
              }
            }
          },
        },
        name: 'arkBridge',
        methodList: ['onHeight', 'onReady', 'onStats'],
        controller: this.controller,
      })
      .onPageEnd(() => {
        // onReady 可能比 onPageEnd 先到,两边都尝试一次,以 ready 标志去重
        this.ready = true;
        this.push();
      })
  }

  onSourceChange(): void {
    this.push();
  }

  aboutToAppear(): void {
    this.push();
  }
}
