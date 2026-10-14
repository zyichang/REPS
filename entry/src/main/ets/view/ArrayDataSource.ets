/**
 * 给 LazyForEach 用的最小数据源:包一层数组,整体替换时通知列表重载。
 *
 * 为什么要它:ForEach 会一次性把**所有**行都建出来。Math_1000 一本就是
 * 1000 张卡,打开卡片列表要先建 1000 个 ListItem 才出第一帧。
 * LazyForEach 只建屏幕内(加 cachedCount 预取)的那几十行。
 *
 * 只支持整体替换(setData)。REPS 的列表每次都是从数据库整页重读,
 * 没有逐行增删的场景,不值得为它维护细粒度通知。
 */
export class ArrayDataSource<T> implements IDataSource {
  private data: T[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.data.length;
  }

  getData(index: number): T {
    return this.data[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const i: number = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }

  /** 整体替换并让列表重载。调用方仍要保证 key 稳定(用卡片 id,不用下标) */
  setData(data: T[]): void {
    this.data = data;
    this.listeners.forEach((l: DataChangeListener) => {
      l.onDataReloaded();
    });
  }
}
