/**
 * 给 LazyForEach 用的最小数据源:包一层数组,整体替换时通知列表重载。
 *
 * 为什么要它:ForEach 会一次性把**所有**行都建出来。Math_1000 一本就是
 * 1000 张卡,打开卡片列表要先建 1000 个 ListItem 才出第一帧。
 * LazyForEach 只建屏幕内(加 cachedCount 预取)的那几十行。
 *
 * 支持整体替换(setData)和末尾追加(append,分页用)。没有逐行增删的场景,
 * 不值得为它维护更细的通知。
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

  /**
   * 在末尾追加一批(分页加载下一页)。只通知「新增了这一段」,
   * 已经建好的行原样保留,滚动位置不会跳。
   */
  append(more: T[]): void {
    if (more.length === 0) {
      return;
    }
    const start: number = this.data.length;
    this.data = this.data.concat(more);
    this.listeners.forEach((l: DataChangeListener) => {
      l.onDatasetChange([{ type: DataOperationType.ADD, index: start, count: more.length }]);
    });
  }

  /** 整体替换并让列表重载。调用方仍要保证 key 稳定(用卡片 id,不用下标) */
  setData(data: T[]): void {
    this.data = data;
    // **全部走 onDatasetChange,不要混用 onDataReloaded。** ArkUI 规定一个数据源
    // 一旦用过 onDatasetChange(append 里用了),再调旧接口就抛
    // 「onDatasetChange cannot be used with other interface」—— 实测:分页加载过之后
    // 再搜索 / 换过滤,列表就报「读取失败」
    this.listeners.forEach((l: DataChangeListener) => {
      l.onDatasetChange([{ type: DataOperationType.RELOAD }]);
    });
  }
}
