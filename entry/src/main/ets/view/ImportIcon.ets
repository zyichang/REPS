/**
 * 「导入」图标:向下的箭头落进一个托盘(通用的 import / download 图形)。
 *
 * **Path 的 commands 单位是 px,不是 vp**(CONTEXT 里记过的坑):坐标按 24×24 的网格设计,
 * 先按 side 缩放成 vp,再过 vp2px —— 和标签栏「我的」图标的肩膀同一种写法。
 * (先试过 Shape + viewPort 让它自己缩放,实测图形缩成一小团,不可靠。)
 */
@Component
export struct ImportIcon {
  @Prop color: ResourceColor = '#3B82F6';
  /** 边长,vp */
  @Prop side: number = 26;

  /** 24×24 网格上的一个坐标 → px */
  private p(v: number): number {
    return Math.round(this.getUIContext().vp2px(v * this.side / 24) * 10) / 10;
  }

  private commands(): string {
    const p = (v: number): number => this.p(v);
    // 箭头杆、箭头两翼、托盘(两边竖起 + 底边)
    return `M${p(12)} ${p(3)} L${p(12)} ${p(14)} ` +
      `M${p(7.5)} ${p(9.5)} L${p(12)} ${p(14)} L${p(16.5)} ${p(9.5)} ` +
      `M${p(4)} ${p(14)} L${p(4)} ${p(20)} L${p(20)} ${p(20)} L${p(20)} ${p(14)}`;
  }

  build() {
    Path()
      .width(this.side).height(this.side)
      .commands(this.commands())
      .fill(Color.Transparent)
      .stroke(this.color)
      .strokeWidth(2)
      .strokeLineCap(LineCapStyle.Round)
      .strokeLineJoin(LineJoinStyle.Round)
  }
}
