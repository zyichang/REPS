/**
 * 牌组计数的三种颜色,牌组列表与卡组概览共用 —— 同一个数在两处必须同色,
 * 否则用户得自己猜「列表上的红」对应概览里的哪个数。
 *
 * 沿用 Anki 的约定:新卡蓝、学习中红、待复习绿。
 * (绿在别处只表示「答对 / 掌握」;待复习用绿是 Anki 的惯例,两者不冲突:都是「该做的」。)
 */
export const COLOR_NEW: string = '#3B82F6';
export const COLOR_LEARN: string = '#E5544B';
export const COLOR_DUE: string = '#10B981';
/** 计数为 0 时的颜色:Anki 把 0 显示成灰,一眼就能看出哪组今天没事 */
export const COLOR_ZERO: string = '#C7C7CC';
