---
quizify:
  format: 1
  deck: Miscellaneous
  tags: [Miscellaneous]
---

+++
<!-- quizify-card
tags: [集成电路, 就业方向, added::2026-08-06]
-->

#### 1. 集成电路（IC）研究生有哪些就业方向？

***

按芯片产业链的环节划分，主要方向有：

1. **芯片设计（IC Design）** —— 数字 / 模拟 / 射频 / 数字后端，最主流的方向。
2. **验证（Verification / DV）** —— 用 SystemVerilog + UVM 验证设计正确性。
3. **制造与工艺（Fabrication & Process）** —— 工艺、器件工程师，就职于晶圆厂（中芯国际、TSMC）。
4. **封装与测试（Packaging & Testing）** —— 封装工程师、测试 / ATE 工程师。
5. **EDA 工具** —— 在 Synopsys、Cadence、华大九天等做工具研发。
6. **应用与系统** —— FAE（现场应用工程师）、系统 / 嵌入式 / 硬件工程师。
7. **科研与学术** —— 读博后进高校或研究所（如中科院微电子所）。
8. **其他** —— 产品经理、技术销售、国企 / 央企、公务员。

> [!TIP]
> 数字设计/验证岗位多、门槛相对友好；模拟/射频稀缺且薪资高；工艺/制造偏物理与产线。

+++
<!-- quizify-card
tags: [集成电路, 就业方向, 芯片设计, added::2026-08-06]
-->

#### 2. 芯片设计（IC Design）主要分为哪几类？

***

- **数字 IC 设计**：用 Verilog/VHDL 做 RTL，属**前端**逻辑设计。
- **模拟 IC 设计**：放大器、电源管理、ADC/DAC，难精通、薪资高。
- **射频 / 混合信号**：无线收发、通信。
- **数字后端 / 版图（Backend / layout）**：布局布线（place & route）、时序收敛。

+++
<!-- quizify-card
tags: [zsh, autosuggestions, shell, added::2026-08-08]
-->

#### 3. zsh-autosuggestions 的 `history` 和 `completion` 两种策略有什么区别？

***

`ZSH_AUTOSUGGEST_STRATEGY` 决定灰色建议从哪里来：

- **`history`**：从**命令历史**里补全——只建议“我以前真正敲过的命令”。
- **`completion`**：用**补全引擎**建议——只建议“系统里真实存在的命令”，即使我从没敲过。

```zsh
ZSH_AUTOSUGGEST_STRATEGY=history
```

> [!TIP]
> 想让它记住并复现自己敲过的命令，用 `history`；想让它提示合法可用命令，用 `completion`。

+++
<!-- quizify-card
tags: [zsh, history, hook, added::2026-08-08]
-->

#### 4. 怎样让 zsh **不记住失败的命令**（这样自动建议就不会提示错误命令）？

***

用两个 hook：先**推迟保存**每条命令，等它执行完，只有**退出码为 0（成功）**才写入历史。

```zsh
autoload -Uz add-zsh-hook

_record_last_command() {
  _LAST_CMD="${1%$'\n'}"
  return 1   # 先别存，交给 precmd 根据退出码决定
}
add-zsh-hook zshaddhistory _record_last_command

_save_if_success() {
  local ret=$?
  if [[ -n "$_LAST_CMD" && $ret -eq 0 ]]; then
    print -sr -- "$_LAST_CMD"
  fi
  _LAST_CMD=
}
add-zsh-hook precmd _save_if_success
```

- `zshaddhistory` 在命令执行**前**触发，返回非零即“暂不保存”。
- `precmd` 在下一个提示符前触发，此时 `$?` 是上一条命令的退出码；成功才用 `print -sr` 补写进历史。
- 效果：`command not found`（退出码 127）、`false`（退出码 1）等失败命令都不会进历史。

+++
<!-- quizify-card
tags: [zsh, history, oh-my-zsh, added::2026-08-08]
-->

#### 5. zsh 的命令历史保存在哪里？

***

默认在 `~/.zsh_history`。这个路径不是我自己设的，而是 Oh My Zsh 的 `~/.oh-my-zsh/lib/history.zsh` 设的：

```zsh
[ -z "$HISTFILE" ] && HISTFILE="$HOME/.zsh_history"
```

查看方式：`history`（当前会话）、`history 1`（全部）、`cat ~/.zsh_history`（原始文件，带 `: 时间戳:0;` 前缀）。

+++
<!-- quizify-card
tags: [oh-my-zsh, zsh, framework, added::2026-08-08]
-->

#### 6. Oh My Zsh 是怎么工作的？如果删掉 `~/.oh-my-zsh` 文件夹会怎样？

***

Oh My Zsh 不是 shell 本身，而是**架在 zsh 之上的配置框架**。真正的 shell 是 `/usr/bin/zsh`。启动链：

1. 启动 zsh → 读 `~/.zshrc`；
2. `~/.zshrc` 里 `export ZSH="$HOME/.oh-my-zsh"` 再 `source $ZSH/oh-my-zsh.sh`；
3. `oh-my-zsh.sh` 加载**主题**、`lib/` 库文件（如 `history.zsh`）、以及 `plugins=(...)` 里的**插件**；
4. 插件实际存放在 `~/.oh-my-zsh/custom/plugins/`（如 `zsh-autosuggestions`）。

**删掉 `~/.oh-my-zsh` 后**：zsh 本身仍能启动（`/usr/bin/zsh` 是独立程序），但 Oh My Zsh 全部失效——`source` 报错、主题丢失、**插件失效（自动建议、语法高亮都没了）**、库设置丢失。`~/.zshrc` 里自己写的 alias、代理块、历史 hook 仍有效。想干净卸载用 `uninstall_oh_my_zsh`，别直接 `rm -rf`。

+++
<!-- quizify-card
tags: [linux, filesystem, usr-merge, added::2026-08-08]
-->

#### 7. 为什么系统里有 `/usr/bin/zsh` 和 `/bin/zsh` 两个路径？它们一样吗？

***

**完全一样**——是同一个文件的两条路径。因为 `/bin` 是指向 `usr/bin` 的**软链接**：

```
/bin -> usr/bin
```

两条路径的 **inode 号相同**（同一磁盘文件，不是副本）。这叫 **/usr merge（/usr 合并）**：历史上 `/bin`（开机必需）和 `/usr/bin`（其余）分开，现代发行版（Fedora、Arch、Debian…）把所有二进制统一放进 `/usr/bin`，`/bin` 保留为软链接以兼容硬编码 `/bin/sh` 等的旧脚本。

> [!TIP]
> 平时直接敲 `zsh` 即可，`PATH` 会解析到 `/usr/bin/zsh`；全路径只在 shebang（`#!/bin/zsh`）或 `/etc/shells` 里才需要。

+++
<!-- quizify-card
tags: [linux, elf, dynamic-linking, added::2026-08-08]
-->

#### 8. 那个约 953K 的 zsh 文件就是 zsh 软件的全部吗？

***

不是占位符，它是**真正的可执行程序**（`file` 显示为 `ELF 64-bit ... dynamically linked, stripped`），但只是 zsh 的**核心**。zsh 是**模块化**的，核心之外还按需加载：

- `/usr/lib64/zsh`（约 1.4M）——编译好的**模块**（`.so` 机器码）。
- `/usr/share/zsh`（约 8.5M）——**架构无关**的 shell 脚本（补全、函数库，如 `add-zsh-hook`）。

所以完整安装约 11M，启动的二进制只是 953K 的核心。`dynamically linked` 说明它运行时还依赖系统共享库（如 `libc.so`）。类比：953K 是“引擎”，运行时再从“车库”取模块和脚本，而不是把所有零件都塞进一个文件。

> [!NOTE]
> Windows 的对应关系：核心 `.exe` ↔ `/usr/bin/zsh`；可加载库 `.dll` ↔ `/usr/lib64/zsh` 的 `.so`；数据/脚本 ↔ `/usr/share/zsh`。静态链接的程序能独立运行，动态链接的则依赖外部库。

+++
<!-- quizify-card
tags: [tmux, Termux, 终端工具, added::2026-08-14]
-->

#### 9. Are tmux and Termux the same software? Is there any difference?

***

不是，两者**完全不同**，只是名字看起来像。

- **tmux**（terminal multiplexer，终端复用器）——一个 Unix **命令行工具**。让一个终端窗口容纳多个 session、window 和分屏 pane。杀手级特性是**会话持久化**：可以 detach 断开，关掉终端或掉了 SSH 连接后再 `tmux attach` 回来，里面的进程仍在运行。可跑在 Linux、macOS、WSL、BSD。
- **Termux**——一个 **Android 应用**。它是终端模拟器加一套无需 root 的 Linux 环境，自带包管理器 `pkg`（基于 APT），可以装 git、Python、Node、openssh 等。

两者的关系：**Termux 是环境，tmux 是可以在里面运行的工具**。`pkg install tmux` 是很常见的搭配，因为 Android 容易杀后台进程，tmux 能在应用失去焦点时保住正在跑的任务。

| | tmux | Termux |
| --- | --- | --- |
| 类型 | 终端复用器（CLI 工具） | 终端模拟器 + Linux 环境（安卓 App） |
| 平台 | Linux、macOS、BSD、WSL | Android |
| 用途 | 分屏 / 保持会话不断 | 让安卓有一个可用的 shell |
| 安装 | `apt install tmux`、`brew install tmux` | Google Play / F-Droid |

> [!NOTE]
> 名字相似只是巧合：tmux 是 **t**erminal **mu**ltiple**x**er 的缩写；Termux 是 **Term**inal + Uni**x** 的混合词。

+++
<!-- quizify-card
tags: [Node.js, Windows, 跨平台, added::2026-08-18]
-->

#### 10. Node.js 在 Windows 和 Linux 上有区别吗？在 Windows 上运行会损失性能吗？

***

Node.js **从来不是只支持 Linux 的**。官方的 Windows 支持从 2011 年的 v0.6 就有了（微软参与开发），这也正是 `libuv` 存在的原因——它把事件循环抽象成跨平台接口，在 Linux 上用 `epoll`，在 Windows 上用 **IOCP**。V8 引擎本身完全跨平台，Windows 是官方的 Tier-1 平台。

所以**纯 JS 的 CPU 密集运算，两个平台性能基本一致**。真正的差别在别处：

- **文件系统密集的操作在 Windows 上更慢** —— `npm install`、文件监听（watch）这类要碰成千上万个小文件的场景，会被 NTFS 的元数据操作和杀毒软件的实时扫描拖慢。这是唯一能明显感受到的地方。把项目目录加进 Windows Defender 的排除列表能挽回不少。
- **Windows 没有 `fork()`** —— `child_process` 创建子进程更重。
- **文件名大小写不敏感** —— `require('./MyModule')` 在 Windows 上能跑，在 Linux 的 CI 上就崩。经典的"在我机器上是好的"。
- **原生模块（node-gyp）** 需要 Visual Studio Build Tools，而不是 `gcc` / `make`。
- **为 bash 写的 npm scripts 会失败** —— `rm -rf`、`NODE_ENV=production node x.js`、`$VAR` 与 `%VAR%`。用 `cross-env` 和 `rimraf` 保持跨平台。

> [!WARNING]
> 用 WSL 时**不要**让 WSL 里的 Node 去操作 `/mnt/c` 下的文件——那要跨 9p 文件系统桥，比两种原生方案都慢得多。二选一：Windows 的 Node 配 `C:\` 上的项目，或 WSL 的 Node 配 `~`（Linux 文件系统）下的项目。不要混用。

+++
<!-- quizify-card
tags: [Node.js, nvm, fnm, 版本管理, added::2026-08-18]
-->

#### 11. 为什么需要 Node 版本管理器（nvm / fnm）？能不能直接装一个自己想要的版本？

***

可以直接装 —— `winget install OpenJS.NodeJS.LTS` 或官网的 MSI 都能正常工作。

版本管理器的价值在这些场景：

- 不同项目锁定不同的 Node 版本（老项目 20，新项目 24）。没有管理器就只能卸了重装来切换。
- 仓库里放 `.nvmrc`，版本被记录下来、可复现。
- 新的大版本出问题时，一条命令就能回退。
- 避免全局 npm 包装进 `Program Files`——那需要管理员权限，还容易出权限错误。

如果只有一个项目、一个版本，直接装确实更简单。痛点通常是后来才出现的，届时再补装管理器就得先清理掉直装的版本。

> [!IMPORTANT]
> Windows 上两个坑：
> 1. **`nvm-windows`（coreybutler）和 Unix 的 `nvm` 是完全不同的两个项目**，只是名字像。命令不一样，而且 `nvm use` 需要管理员权限的终端（它靠切换符号链接实现）。
> 2. 现在更推荐 **`fnm`**。Windows、WSL、macOS 上是同一个工具，速度快得多，能读 `.nvmrc`，装上 shell hook 后可按目录自动切换。

```powershell
winget install Schniz.fnm
fnm install --lts
fnm default lts-latest
corepack enable        # 需要 pnpm / yarn 时
```

截至 2026-08：Node **24.x 是 LTS**，26.x 是 Current。

+++
<!-- quizify-card
tags: [npm, PowerShell, ExecutionPolicy, added::2026-08-18]
-->

#### 12. 为什么 `npm` 命令在 CMD 里能运行，在 PowerShell 里却报错？

***

因为 Windows 上的 `npm` 不是一个可执行文件。Node 安装器会并排放三个文件：

```text
npm       ← bash 脚本（git-bash、WSL 用）
npm.cmd   ← 批处理文件（CMD 用这个）
npm.ps1   ← PowerShell 脚本（PowerShell 优先用这个）
```

CMD 根本没有"执行策略"这个概念，直接跑 `npm.cmd`。PowerShell 会把裸名字 `npm` 解析到 `npm.ps1`，而 Windows 客户端版的 `ExecutionPolicy` 默认是 **`Restricted`**，它禁止**所有** `.ps1` 文件，于是报错：

```text
npm : File ...\npm.ps1 cannot be loaded because running scripts is disabled on this system.
```

这也解释了为什么 `node -v` 在 PowerShell 里正常、`npm -v` 却不行：`node.exe` 是真正的二进制程序，而 **npm、npx、pnpm、yarn、tsc 全都是脚本壳（script shim）**。

+++
<!-- quizify-card
tags: [npm, PowerShell, CMD, ExecutionPolicy, added::2026-08-18]
-->

#### 13. 只用 CMD 跑 npm 可以吗？还是应该改 PowerShell 的执行策略？

***

功能上完全可以：npm 行为一模一样，包装到同一个位置，不会坏。执行策略和 npm 本身的能力无关。但有实际代价：

- **VS Code 的集成终端在 Windows 上默认是 PowerShell**，所以除非同时改默认终端配置，在编辑器里还是会撞上同样的报错。
- **fnm / nvm 的自动切换会失效** —— 按目录读 `.nvmrc` 的 hook 装在 PowerShell profile 里，CMD 没有对应机制，只能手动切版本。
- CMD 的历史记录、Tab 补全都更弱，默认也不是 UTF-8。

不改策略的临时办法：在 PowerShell 里显式写 `npm.cmd install`。点名批处理文件就绕过了 `.ps1` 解析。

推荐的正式做法：

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

`RemoteSigned` = 本地自己写的脚本可以跑，从网上下载的必须有签名。`-Scope CurrentUser` 不需要管理员权限，也不影响机器上其他账户。

> [!NOTE]
> 微软自己的文档明确说明：**执行策略不是安全边界**。它防的是误双击运行脚本，而不是有意的攻击者（`powershell -ExecutionPolicy Bypass` 就能绕过）。`CurrentUser` + `RemoteSigned` 是开发机的惯例配置，比 `Unrestricted` 或 `Bypass` 收敛得多——后两者不推荐。

+++
<!-- quizify-card
tags: [npm, pnpm, 包管理器, added::2026-08-18]
-->

#### 14. npm 和 pnpm 有什么区别？

***

两者都从同一个 npm registry 安装，用同一份 `package.json`。区别在于**包在磁盘上怎么摆放**——这一个选择决定了其余所有差异。

**磁盘布局.** npm 把每个包复制进每个项目的 `node_modules`：10 个项目用 React 就有 10 份 React。pnpm 只维护一个全局的**内容寻址存储**（content-addressable store，Windows 上在 `%LOCALAPPDATA%\pnpm\store`），`node_modules` 里放的是指向它的**硬链接**。通常省下 50%~70% 的磁盘，而且同一个包第二次安装几乎零成本，因为不需要复制。

**严格性——这是真正会改变你代码的区别.** npm 会把间接依赖**提升（hoist）**到 `node_modules` 顶层。所以即使 `package.json` 里没写 `debug`，只要 Express 依赖它，你自己的代码 `require('debug')` 也能跑。这叫**幽灵依赖（phantom dependency）**：在你机器上正常，等 Express 哪天换版本或去掉这个依赖就崩。pnpm 顶层只暴露你**声明过的**依赖，幽灵依赖会立刻报错。

这个严格性既是采用 pnpm 的主要理由，也是它偶尔让人难受的原因——一些老包和打包器配置假设了 hoisting。`.npmrc` 里有逃生阀：`public-hoist-pattern`，最后手段是 `node-linker=hoisted`。

**速度.** pnpm 冷装约快 2 倍，热装快得多。但 npm 已经追上不少，单靠这条理由不够强。

**Monorepo.** 两者都支持 workspaces，但 pnpm 更强：`--filter` 指定单个包、`pnpm -r` 递归执行、`workspace:*` 协议引内部依赖。

**lockfile 不能互换** —— `package-lock.json` 与 `pnpm-lock.yaml` 只能提交其中一个。迁移时用 `pnpm import` 从 npm 的 lockfile 转换。

> [!NOTE]
> Windows 两个注意点：store 要和项目放**同一个盘**，否则硬链接建不了，pnpm 会静默退化成复制；pnpm 用的是 junction 而不是真正的符号链接，所以不需要管理员权限或开发者模式。

选择建议：刚装好 Node 就先用 npm——它随 Node 自带，所有教程都假设它，而且你还没遇到 pnpm 要解决的痛点。等碰到 monorepo、或发现 `node_modules` 吃光 SSD 时再切，用 `corepack enable pnpm`（它通过 `package.json` 的 `packageManager` 字段锁定版本，保持团队一致），而不是全局安装。

+++
<!-- quizify-card
tags: [FSRS, 间隔重复, Anki, added::2026-09-01]
-->

#### 15. FSRS 的复习逻辑是什么？软件里的 0.92 是什么意思？

***

**先纠正一点：0.92 不是版本号，而是 desired retention（期望保留率）** —— 卡片到期那一刻你希望自己能回忆起来的概率。这是你唯一需要手动设的旋钮，其余参数都由算法从你的复习历史里拟合出来。

**DSR 记忆模型.** FSRS 为每张卡片跟踪三个量：

1. **$D$ —— Difficulty（难度）**，取值 $[1, 10]$：这张卡片有多难积累稳定性。按 *Again* 会推高它，按 *Easy* 会拉低它。
2. **$S$ —— Stability（稳定性）**：从现在算起，你对这张卡的回忆概率衰减到 90% 所需的**天数**，也就是记忆强度。
3. **$R$ —— Retrievability（可提取性）**：此刻能回忆起来的概率，由「已过天数」和 $S$ 算出来，不存储。

**遗忘曲线是幂函数，不是指数函数：**

$$R(t) = \left(1 + \text{FACTOR} \cdot \frac{t}{S}\right)^{\text{DECAY}}$$

其中 $\text{FACTOR} = 19/81$，$\text{DECAY} \approx -0.5$（在 FSRS-6 中 DECAY 本身也是被拟合的参数）。幂律衰减意味着**早期掉得快、后期变平**——这既解释了为什么成熟卡片能拿到很长的间隔，也解释了为什么隔很久没复习的卡片很少是**完全**忘掉的。

**调度就是把这条曲线反解.** 给定期望保留率 $DR$，下次间隔取使 $R(t) = DR$ 成立的那个 $t$：

$$I = \frac{S}{\text{FACTOR}} \left( DR^{1/\text{DECAY}} - 1 \right)$$

当 $DR = 0.90$ 时化简为 $I \approx S$。整个调度器就这么一个式子。

**然后你的评分更新 $D$ 和 $S$**：复习成功会把 $S$ 乘上一个倍数（如果当时 $R$ 已经很高，倍数就小——复习一个你本来就记得牢的东西，收益很低）；失误则按 *post-lapse stability* 重算出一个大幅缩小的 $S$。

> [!NOTE]
> 那 21 个参数只是上面这些更新方程的系数，**不需要手填**——用优化器（Optimize）从你自己的复习日志拟合。少于 400 条（理想 1000 条以上）复习记录时优化会报错。

+++
<!-- quizify-card
tags: [FSRS, 间隔重复, Anki, added::2026-09-01]
-->

#### 16. desired retention 设得越高，需要复习的卡片是不是越少（因为记住的更多）？

***

**恰好相反：期望保留率越高，复习量越大。**

关键在因果方向。保留率不是 FSRS 观测到的结果，而是它努力去命中的**目标**。要让你从记住 90% 变成记住 95%，它手上唯一的杠杆就是**更早**把卡片推给你——趁遗忘曲线还没衰减到那么低。间隔更短，就意味着每张卡回来得更频繁。

把数值代入上一张卡的间隔公式：

| 期望保留率 | 间隔（$S$ 的倍数） | 每日复习量（相对 0.90） |
|---|---|---|
| 0.80 | $2.40 \times S$ | $0.42\times$ |
| 0.85 | $1.64 \times S$ | $0.61\times$ |
| 0.90 | $1.00 \times S$ | $1.00\times$ |
| 0.92 | $0.77 \times S$ | $1.29\times$ |
| 0.95 | $0.46 \times S$ | $2.17\times$ |
| 0.97 | $0.27 \times S$ | $3.73\times$ |

一张 $S = 30$ 天的卡片，在 $DR = 0.90$ 下 30 天后到期，在 0.92 下 23 天，在 0.95 下只有 14 天。从 0.90 提到 0.97，日复习量几乎**翻两番**。

**但「记住更多 → 失误更少」这个直觉并非毫无价值**，它抓住了一个真实的二阶效应：失误代价很高——一次 lapse 会让 $S$ 崩塌，卡片退回短间隔，之后要多付很多次。这份节省是真实的，只是远小于额外排期复习带来的开销。

因为这两股力方向相反，**总工作量是 U 型的，而不是单调的**：保留率压太低（0.70）会被重新学习淹没，抬太高（0.97）会被过早复习淹没。最低点通常落在 **0.80 ~ 0.90** 之间，取决于你遗忘得多快。Anki 直接提供了 **"Compute minimum recommended retention"**，它会模拟你自己的历史，算出「单位时间知识量」最大的那个保留率。

> [!TIP]
> 正确的理解方式：desired retention 不是「我想把这些记多牢」，而是**「我每天愿意为复习买多少时间」**。

+++
<!-- quizify-card
tags: [FSRS, 间隔重复, Anki, added::2026-09-01]
-->

#### 17. 一个很久没复习、已经忘掉大半的牌组，FSRS 该怎么设？

***

场景：单词牌组早就过完一遍，但荒废很久，现在大约只记得 40%。

1. **不要 reset，也不要用 "Forget".** 让卡片自然地失误。**一次 lapse 是数据**——FSRS 需要看到它才能学出你真实的遗忘速度；而一张隔了很久你**居然还记得**的卡片会赢得一个很大的稳定性增益，重置就把这份信息扔掉了。
2. **期望保留率保持在 0.90 附近.** 软件推荐的 0.92 没问题，但比 0.90 大约多 20% ~ 30% 的日复习量，换来的准确率提升很小。背单词我会用 0.90；每日负担太重就降到 **0.85 ~ 0.87**；只有临考试这类有 deadline 的情况才往 0.92 ~ 0.95 抬。低于 0.80 或高于 0.97，性价比都会明显变差。
3. **关掉 "Reschedule cards on change".** 改保留率或参数时如果开着它，会一次性把重算出来的整个积压（backlog）砸到你头上。
4. **限制每日复习上限**（比如 50 ~ 100 张），用两三周把积压磨平，而不是第一天就面对几千张。
5. **先复习，之后再 Optimize.** 等这轮追赶积累了几百条复习记录，再跑优化器，让参数反映你**实际**记这批单词的方式。
6. **诚实评分，大部分时候只用 Again 和 Good.** *Hard* 是**通过**，不是失败——把它当成「勉强想起来」会虚高间隔；真的一片空白就按 *Again*，这才是 FSRS 期待的输入。

+++
<!-- quizify-card
tags: [tmux, 终端, 快捷键, added::2026-09-01]
-->

#### 18. tmux 里怎么用快捷键在 window（窗口）之间切换？

***

我的配置（`~/.config/tmux/tmux.conf`）里，切换 window 大多是**不需要 prefix** 的——`bind -n` 就表示「无需前缀键」。

| 按键 | 作用 |
| --- | --- |
| `Alt+n` / `Alt+p` | 下一个 / 上一个 window（无 prefix） |
| `Alt+1` … `Alt+9` | 直接跳到第 1 ~ 9 个 window（无 prefix） |
| `prefix + Ctrl+n` / `Ctrl+p` | 下一个 / 上一个，可连按（`repeat-time 300` 毫秒内） |
| `prefix + W` | `choose-tree -Z`，可视化的 session / window / pane 选择器 |
| `Alt+Shift+N` / `Alt+Shift+P` | 把当前 window 在列表里**右移 / 左移**（重排顺序） |
| `Alt+o` | 在当前目录新建 window |

> [!TIP]
> 设计思路：**高频动作绑成无 prefix 的 Alt 组合，prefix 只留给低频命令**（分屏、重命名、选择器）。这样即使 prefix 稍难按，日常手感也不受影响。

+++
<!-- quizify-card
tags: [tmux, 终端原理, 按键编码, added::2026-09-01]
-->

#### 19. tmux 的 prefix 为什么不能设成 `Ctrl+Win`（Super 键）？

***

因为 **tmux 根本「看不到」Win / Super 键**。

1. tmux 不是 GUI 程序，它只能从终端模拟器拿到一串**字节流**。传统的 xterm 按键编码用一个 modifier 位掩码，只表示 **Shift、Alt、Ctrl、Meta**——**没有 Super 的编码**，所以 `bind Super-x` 压根匹配不到任何输入。
2. 只有较新的协议（kitty keyboard protocol、Windows Terminal 的 win32-input-mode）才能编码 Super。
3. 即便能编码，**操作系统 / 窗口管理器会先把它吃掉**：Windows 弹出开始菜单，GNOME 弹出 Activities，macOS 的 Cmd 被应用本身占用。

> [!IMPORTANT]
> 一个会被窗口管理器抢走的 prefix，比一个稍微难按的 prefix 更糟。

+++
<!-- quizify-card
tags: [tmux, GNU-Screen, readline, added::2026-09-01]
-->

#### 20. tmux 默认 prefix 为什么是 `Ctrl+B`？为什么很多人改成 `Ctrl+S`？

***

**`Ctrl+B` 的来历：** tmux 的思路继承自 GNU Screen，而 Screen 用的是 `Ctrl+A`。但 `Ctrl+A` 在 readline 里是 **beginning-of-line**（行首），使用极其频繁，所以 tmux 作者退一格选了 `Ctrl+B`——它在 readline 里是 backward-char（左移一个字符），交互中几乎没人用，「偷」走它的代价最小。

**为什么改成 `Ctrl+S`：**

1. `s` 在 QWERTY 上处于**主键行**（左手无名指原位），而 `b` 要用食指跑到下排中间，很多人还会用错手去按。
2. `Ctrl+S` 唯一的历史含义是终端流控 **XOFF**，而几乎所有人都会禁用它，所以这个键位基本是**空闲**的。
3. 想让 prefix 更省力，常见做法是在**操作系统层面把 Caps Lock 映射成 Ctrl**——这样 `Ctrl+S` 就变成主键行上两根相邻手指的动作。

+++
<!-- quizify-card
tags: [终端, stty, 流控, added::2026-09-01]
-->

#### 21. 在终端里按 `Ctrl+S` 会「卡住 / 冻结」，这是什么？怎么解决？

***

那不是崩溃，是**终端流控（flow control）**：`Ctrl+S` 发送 **XOFF**，暂停终端输出；`Ctrl+Q` 发送 **XON**，恢复输出。这是纸带打字机时代留下的遗产。

- **临时解冻：** 按 `Ctrl+Q`。
- **永久关掉：** 在 `~/.zshrc`（或 `~/.bashrc`）里加

```bash
stty -ixon
```

- **查看当前状态：** `stty -a | grep ixon`（`-ixon` 表示已关闭）。

关掉之后，`Ctrl+S` 就成了可以自由使用的键位——这也是能把它当 tmux prefix 的前提。
