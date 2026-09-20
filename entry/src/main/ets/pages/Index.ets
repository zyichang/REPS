/**
 * 首页。
 *
 * Task 1 只需要一个能启动、能证明工程骨架成立的页面。
 * 真正的学习界面在 Task 5(端到端追踪弹)接进来。
 *
 * 注意本项目的 ArkUI 铁律(WordSnap 踩过四次):
 * UI 只能依赖 @State / @StorageLink,绝不能依赖普通对象字段——
 * 按值传参的 @Builder 不会响应更新。
 */
@Entry
@Component
struct Index {
  @State private tagline: string = '把一本书变成一整副卡组';

  build() {
    Column({ space: 12 }) {
      Text('刻意重复')
        .fontSize(34)
        .fontWeight(FontWeight.Bold)

      Text('REPS')
        .fontSize(15)
        .fontColor('#8A8A8E')
        .letterSpacing(3)

      Text(this.tagline)
        .fontSize(15)
        .fontColor('#48484A')
        .margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#FFFFFF')
  }
}
