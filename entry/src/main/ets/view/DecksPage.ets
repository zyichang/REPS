/**
 * 卡组页:一本书一行,各自独立的进度与额度。
 *
 * **每个卡组的计数必须完全独立。** 这是 WordSnap 的教训 ——
 * 当年把「学习更多」的追加额度存成全局 key,在 A 书点一次,B 书也凭空多出额度。
 * 所以这一页显示的每个数字都是按 deck_id 查出来的,没有任何共享计数。
 */

import { common } from '@kit.AbilityKit';
import { DeckRow } from '../data/Schema';
import { ImportResult, importFromPicker } from '../data/Importer';
import { SK_TICK, appStore } from '../store/AppStore';

@Component
export struct DecksPage {
  @StorageLink(SK_TICK) tick: number = 0;

  @State private decks: DeckRow[] = [];
  @State private paths: string[] = [];
  @State private currentId: number = 0;
  @State private status: string = '';
  @State private busy: boolean = false;
  /** 待确认删除的卡组下标,-1 表示没有 */
  @State private confirmIndex: number = -1;

  aboutToAppear(): void {
    this.reload();
  }

  onTickChange(): void {
    this.reload();
  }

  private reload(): void {
    const st = appStore();
    if (!st.isReady()) {
      return;
    }
    try {
      const db = st.getDb();
      const rows: DeckRow[] = db.listDecks(Date.now());
      const ps: string[] = [];
      for (const r of rows) {
        ps.push(db.deckPath(r.id));
      }
      this.decks = rows;
      this.paths = ps;
      this.currentId = st.currentDeckId;
      this.status = rows.length === 0 ? '还没有卡组,导入一个 Markdown 文件试试' : '';
    } catch (e) {
      this.status = `读取失败: ${e}`;
    }
  }

  private async onImport(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.status = '正在导入…';
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const r: ImportResult = await importFromPicker(ctx, appStore().getDb());
      this.status = r.ok
        ? `已导入 ${r.cardsAdded} 张卡到「${r.deck}」`
        : (r.error === '已取消' ? '' : `导入失败:${r.error}`);
      if (r.ok) {
        appStore().bump();
      }
      this.reload();
    } catch (e) {
      this.status = `导入出错: ${e}`;
    } finally {
      this.busy = false;
    }
  }

  private selectDeck(i: number): void {
    const d = this.decks[i];
    appStore().setCurrentDeck(d.id, this.paths[i]);
    this.currentId = d.id;
    this.status = `已切到「${this.paths[i]}」,学习页只出这一组的卡`;
  }

  private selectAll(): void {
    appStore().setCurrentDeck(0, '全部卡组');
    this.currentId = 0;
    this.status = '已切到全部卡组';
  }

  private doDelete(i: number): void {
    const d = this.decks[i];
    try {
      appStore().getDb().deleteDeck(d.id);
      if (appStore().currentDeckId === d.id) {
        appStore().setCurrentDeck(0, '全部卡组');
      }
      this.status = `已删除「${this.paths[i]}」及其 ${d.cards} 张卡`;
      this.confirmIndex = -1;
      appStore().bump();
      this.reload();
    } catch (e) {
      this.status = `删除失败: ${e}`;
    }
  }

  /**
   * 一行卡组。**只接常量下标**,内容从 @State 数组里取 ——
   * 按值传参的 @Builder 不会响应更新。
   */
  @Builder
  deckRow(i: number) {
    Column({ space: 6 }) {
      Row() {
        Column({ space: 2 }) {
          Text(this.paths[i])
            .fontSize(16)
            .fontWeight(this.decks[i].id === this.currentId ? FontWeight.Bold : FontWeight.Normal)
          Row({ space: 12 }) {
            Text(`${this.decks[i].cards} 张`).fontSize(12).fontColor('#8A8A8E')
            Text(`待复习 ${this.decks[i].due}`).fontSize(12).fontColor('#E5544B')
            Text(`新卡 ${this.decks[i].fresh}`).fontSize(12).fontColor('#4A90D9')
          }
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)

        if (this.decks[i].id === this.currentId) {
          Text('学习中').fontSize(11).fontColor('#2E9E63')
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(6).backgroundColor('#E8F6EE')
        }
      }
      .width('100%')

      Row({ space: 8 }) {
        Button('设为当前')
          .fontSize(13).height(34).layoutWeight(1)
          .backgroundColor('#E5E5EA').fontColor('#1C1C1E')
          .enabled(this.decks[i].id !== this.currentId)
          .onClick(() => this.selectDeck(i))
        if (this.confirmIndex === i) {
          Button('确认删除')
            .fontSize(13).height(34).layoutWeight(1)
            .backgroundColor('#E5544B').fontColor(Color.White)
            .onClick(() => this.doDelete(i))
          Button('取消')
            .fontSize(13).height(34).width(64)
            .backgroundColor('#E5E5EA').fontColor('#1C1C1E')
            .onClick(() => { this.confirmIndex = -1; })
        } else {
          Button('删除')
            .fontSize(13).height(34).width(72)
            .backgroundColor('#F5F5F7').fontColor('#E5544B')
            .onClick(() => { this.confirmIndex = i; })
        }
      }
      .width('100%')
    }
    .width('100%').padding(14).borderRadius(12).backgroundColor('#FAFAFC')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Text('卡组').fontSize(24).fontWeight(FontWeight.Bold).layoutWeight(1)
        Text(`${this.decks.length} 组`).fontSize(13).fontColor('#8A8A8E')
      }
      .width('90%').margin({ top: 14 })

      Button('导入 Markdown 文件')
        .width('90%').height(42).fontSize(15)
        .enabled(!this.busy)
        .onClick(() => this.onImport())

      Button('学习全部卡组')
        .width('90%').height(38).fontSize(14)
        .backgroundColor(this.currentId === 0 ? '#E8F6EE' : '#E5E5EA')
        .fontColor('#1C1C1E')
        .onClick(() => this.selectAll())

      if (this.status.length > 0) {
        Text(this.status).fontSize(12).fontColor('#48484A')
          .width('90%').textAlign(TextAlign.Center)
      }

      Scroll() {
        Column({ space: 10 }) {
          ForEach(this.decks, (d: DeckRow, idx?: number) => {
            this.deckRow(idx ?? 0)
          }, (d: DeckRow) => `${d.id}`)
        }
        .width('100%').padding({ bottom: 16 })
      }
      .layoutWeight(1).width('90%').align(Alignment.Top)
    }
    .width('100%').height('100%').backgroundColor('#FFFFFF')
  }
}
