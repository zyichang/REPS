/**
 * 富文本:把 Quizify 的行内标记渲染成带样式的文字。
 *
 * ArkUI 的 Text 不认 Markdown,所以走 Text + Span:
 * 解析在 data/Inline.ets(纯逻辑、有断言覆盖),这一层只负责给样式。
 *
 * 命名注意:**不能叫 RichText** —— 那是 ArkUI 的内置组件保留名,
 * 同名会直接编译失败。属性也不能叫 size,会和 CustomComponent 自带的冲突。
 *
 * 用法:MarkupText({ source: someText, fontPx: 16, color: '#000000' })
 */

import { LengthMetrics } from '@kit.ArkUI';
import { Block, BlockKind, InlineKind, InlineSpan, parseInline, splitBlocks } from '../data/Inline';

@Component
export struct MarkupText {
  /**
   * 原始文本(含 Quizify 行内标记)。
   *
   * **@Watch 是必须的。** 没有它,source 变了只会重绘而不会重新解析,
   * 于是换到下一张卡时还显示上一张的内容 —— 而编译器一声不响。
   */
  @Prop @Watch('onSourceChange') source: string = '';
  @Prop fontPx: number = 16;
  @Prop color: string = '#1C1C1E';
  @Prop lineHeightPx: number = 25;

  /**
   * 解析结果。**必须是 @State 而不是普通字段** ——
   * 普通字段的变化不会触发重绘,而编译器一声不响。
   */
  /** 先切块再切行内。围栏代码块整段原样显示,不走行内解析 */
  @State private blocks: Block[] = [];

  aboutToAppear(): void {
    this.blocks = splitBlocks(this.source);
  }

  /** source 变了要重新解析,否则换卡之后还显示上一张的内容 */
  onSourceChange(): void {
    this.blocks = splitBlocks(this.source);
  }

  build() {
    Column({ space: 8 }) {
      ForEach(this.blocks, (b: Block, idx?: number) => {
        this.blockView(idx as number)
      })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  /** 一块内容。**只接常量下标** */
  @Builder
  blockView(i: number) {
    if (this.blocks[i].kind === BlockKind.Code) {
      // 代码块:等宽、深底、横向可滚(长行不该被折断)
      Scroll() {
        Text(this.blocks[i].text)
          .fontSize(this.fontPx * 0.88)
          .fontFamily('monospace')
          .fontColor('#1C1C1E')
          .lineHeight(this.lineHeightPx * 0.9)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .borderRadius(8)
      .backgroundColor('#F0F1F4')
      .align(Alignment.TopStart)
    } else {
      Text() {
        ForEach(this.spanOf(i), (sp: InlineSpan) => {
          if (sp.kind === InlineKind.Bold) {
            Span(sp.text).fontWeight(FontWeight.Bold)
          } else if (sp.kind === InlineKind.Highlight) {
            Span(sp.text).fontColor('#8A5A00').backgroundColor('#FFF3C4')
          } else if (sp.kind === InlineKind.Code) {
            Span(sp.text).fontFamily('monospace').fontColor('#B3261E')
              .backgroundColor('#F2F2F7')
          } else if (sp.kind === InlineKind.Math) {
            // Task 12 会换成 KaTeX 渲染;现在原样显示,至少不丢信息
            Span(sp.text).fontFamily('monospace').fontColor('#3A4A6B')
          } else if (sp.kind === InlineKind.Sup) {
            // ArkUI 的 Span 没有真正的上标,用小字号 + 基线偏移近似
            Span(sp.text).fontSize(this.fontPx * 0.68)
              .baselineOffset(LengthMetrics.vp(this.fontPx * 0.3))
          } else if (sp.kind === InlineKind.Sub) {
            Span(sp.text).fontSize(this.fontPx * 0.68)
              .baselineOffset(LengthMetrics.vp(-this.fontPx * 0.18))
          } else {
            Span(sp.text)
          }
        })
      }
      .fontSize(this.fontPx)
      .fontColor(this.color)
      .lineHeight(this.lineHeightPx)
      .width('100%')
    }
  }

  /** 第 i 块的行内片段。段落才需要 */
  private spanOf(i: number): InlineSpan[] {
    return parseInline(this.blocks[i].text);
  }
}
