/**
 * 一套代码、三种宽度(HarmonyOS「一次开发,多端部署」的断点做法)。
 *
 *   sm  < 600vp   手机竖屏:原来的布局,一点不改
 *   md  600~840vp 平板竖屏 / 折叠屏:结构同手机,内容收进一条居中的列
 *   lg  ≥ 840vp   平板横屏:标签栏变成左侧竖栏;学习 / 浏览 / 我的 变成左右分栏
 *
 * 断点由 EntryAbility 按**窗口**宽度算(不是屏幕宽度:分屏、自由窗口时窗口更窄),
 * 写进 AppStorage 的 SK_BP;页面用 @StorageLink(SK_BP) 读,旋转屏幕时整页跟着重排。
 *
 * 宽度常量都是 vp。MAX_* 用在原来写死 '90%' 的地方:手机上 90% 永远小于这些值,
 * 所以手机布局一像素都不变;到了平板,内容不再被拉成两千多像素的长条。
 */

export const SK_BP: string = 'reps_breakpoint';

export const BP_SM: string = 'sm';
export const BP_MD: string = 'md';
export const BP_LG: string = 'lg';

/** 普通单列页面(设置、统计、列表)的最大宽度 */
export const MAX_COL: number = 720;
/** 作答时题干 / 答案的阅读列。一行太长眼睛就找不到下一行的开头 */
export const MAX_READ: number = 760;
/** 分栏时左侧列表栏的宽度 */
export const SIDE_W: number = 360;
/** 横屏时左侧竖向标签栏的宽度 */
export const RAIL_W: number = 76;

export function breakpointOf(widthVp: number): string {
  if (widthVp >= 840) {
    return BP_LG;
  }
  return widthVp >= 600 ? BP_MD : BP_SM;
}

/** 当前断点是否为左右分栏(只有 lg) */
export function isSplit(bp: string): boolean {
  return bp === BP_LG;
}
