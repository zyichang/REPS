/**
 * 课本封面。学习页和词卡表(Glossary)共用同一份画法 ——
 * 两处各画一遍必然慢慢走样。
 *
 * 卡组没有封面图,所以是纯矢量画的:封面 + 书脊 + 三条书页线。
 * 比例按**竖着的本子**来(宽:高 = 3:4);横着的 4:3 不像一本书。
 */

@Component
export struct BookCover {
  /** 封面主色。不同卡组可以给不同颜色,默认用主色 */
  @Prop tint: string;
  /** 书脊色,通常比封面深一档 */
  @Prop spine: string;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%').height('100%')
        .borderRadius({ topLeft: 3, bottomLeft: 3, topRight: 8, bottomRight: 8 })
        .backgroundColor(this.tint.length > 0 ? this.tint : '#2E9E63')
      Column()
        .width(6).height('100%')
        .position({ x: 0, y: 0 })
        .borderRadius({ topLeft: 3, bottomLeft: 3 })
        .backgroundColor(this.spine.length > 0 ? this.spine : '#24794C')
      Column({ space: 6 }) {
        Divider().color('#FFFFFF').opacity(0.85).strokeWidth(2).width('62%')
        Divider().color('#FFFFFF').opacity(0.65).strokeWidth(2).width('48%')
        Divider().color('#FFFFFF').opacity(0.45).strokeWidth(2).width('56%')
      }
      .width('100%').padding({ left: 16, right: 10 })
      .alignItems(HorizontalAlign.Start)
    }
    .aspectRatio(0.75)
    .width('100%')
  }
}
