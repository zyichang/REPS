/**
 * 账号登录界面 —— **目前没有后端,这是一个纯界面占位。**
 *
 * 刻意做的几件事,别在接后端之前改掉:
 *
 * 1. **密码不落任何盘。** 只活在 @State 里,退出这个页面就没了。
 *    没有 preferences、没有数据库、没有日志 —— 一个还没有服务端的应用
 *    保存密码没有任何好处,只有风险。
 * 2. **页面顶部明说「还没有服务端」。** 否则用户会以为这是真登录,
 *    输入自己常用的密码。没接后端却长得像能用,是在骗用户交出凭据。
 * 3. **不发任何网络请求。** 点「登录」只切换本地状态。
 *
 * 接后端时要补的:HTTPS、密码不进日志、失败次数限制、令牌安全存储
 * (用 @ohos.security.asset 而不是 preferences)。
 */

import { SK_LANG, appStore } from '../store/AppStore';
import { L, LANG_ZH } from '../i18n/Strings';

@Component
export struct LoginPage {
  /** 返回「我的」 */
  onBack: () => void = () => {};

  @StorageLink(SK_LANG) lang: string = LANG_ZH;

  @State private account: string = '';
  /** 只在内存里。**不要持久化** */
  @State private password: string = '';
  @State private note: string = '';
  @State private signedIn: boolean = false;
  @State private signedInAs: string = '';

  aboutToAppear(): void {
    // 只读回「显示用的账号名」,永远不读密码 —— 因为从不保存密码
    const name: string = appStore().accountName;
    if (name.length > 0) {
      this.signedIn = true;
      this.signedInAs = name;
    }
  }

  private canSubmit(): boolean {
    return this.account.trim().length > 0 && this.password.length > 0;
  }

  /**
   * 「登录」。没有服务端,所以只记住一个显示用的账号名,
   * 并且**立刻把内存里的密码清掉**。
   */
  private signIn(): void {
    if (!this.canSubmit()) {
      this.note = L(this.lang).needBoth;
      return;
    }
    const name: string = this.account.trim();
    appStore().setAccountName(name);
    this.password = '';          // 用完即弃
    this.signedIn = true;
    this.signedInAs = name;
    this.note = L(this.lang).signedInLocal;
  }

  private signOut(): void {
    appStore().setAccountName('');
    this.account = '';
    this.password = '';
    this.signedIn = false;
    this.signedInAs = '';
    this.note = L(this.lang).signedOut;
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Row({ space: 10 }) {
          Text('‹').fontSize(30).fontWeight(FontWeight.Medium).fontColor('#1C1C1E')
            .onClick(() => this.onBack())
          Text(L(this.lang).accountTitle).fontSize(22).fontWeight(FontWeight.Bold).layoutWeight(1)
        }
        .width('100%').margin({ top: 14 })

        // ---- 醒目的免责说明。接后端之前不要删 ----
        Column({ space: 4 }) {
          Text(L(this.lang).noBackendTitle).fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor('#8A5A00').width('100%')
          Text(L(this.lang).noBackendBody)
            .fontSize(11).fontColor('#8A5A00').width('100%')
        }
        .width('100%').padding(12).borderRadius(10).backgroundColor('#FFF3C4')
        .alignItems(HorizontalAlign.Start)

        if (this.signedIn) {
          Column({ space: 6 }) {
            Text(L(this.lang).currentAccount).fontSize(12).fontColor('#8A8A8E').width('100%')
            Text(this.signedInAs).fontSize(17).fontWeight(FontWeight.Medium).width('100%')
            Text(L(this.lang).notSynced).fontSize(11).fontColor('#B0B7C3').width('100%')
          }
          .width('100%').padding(14).borderRadius(12).backgroundColor('#F5F5F7')
          .alignItems(HorizontalAlign.Start)

          Button(L(this.lang).signOut)
            .width('100%').height(44).fontSize(15)
            .backgroundColor('#F2F2F7').fontColor('#E5544B')
            .onClick(() => this.signOut())
        } else {
          Column({ space: 10 }) {
            Text(L(this.lang).accountField).fontSize(12).fontColor('#8A8A8E').width('100%')
            TextInput({ text: this.account, placeholder: L(this.lang).accountPlaceholder })
              .height(44).fontSize(15)
              .onChange((v: string) => { this.account = v; })

            Text(L(this.lang).passwordField).fontSize(12).fontColor('#8A8A8E').width('100%')
            TextInput({ text: this.password, placeholder: L(this.lang).passwordPlaceholder })
              .type(InputType.Password)
              .height(44).fontSize(15)
              .onChange((v: string) => { this.password = v; })
          }
          .width('100%')

          Button(L(this.lang).signIn)
            .width('100%').height(46).fontSize(16)
            .enabled(this.canSubmit())
            .onClick(() => this.signIn())

          Text(L(this.lang).signUpLater)
            .fontSize(11).fontColor('#B0B7C3')
        }

        if (this.note.length > 0) {
          Text(this.note).fontSize(12).fontColor('#48484A')
            .width('100%').margin({ top: 4 })
        }
      }
      .width('88%').padding({ bottom: 30 })
    }
    .width('100%').height('100%').backgroundColor('#FFFFFF')
  }
}
