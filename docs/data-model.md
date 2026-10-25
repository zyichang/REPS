# REPS 数据模型

卡片在文件里长什么样、进了 App 存在哪、怎么认出同一张卡、今天出哪些卡、云端存什么。
决定的来龙去脉见 ADR-0002(一张就是一张)、0004(多牌组)、0005(流水永不删)、
0006(账号与云同步)、0007(YAML v1)。

> **状态标记:** 本文描述的是**目标结构 schema v2**。标 🚧 的部分要等对应任务完成才生效,
> 完成后去掉标记。

## 1. 文件格式:REPS Card YAML v1

纯文字牌组是一个 `.yaml` 文件。带图片/音频时是 zip `.reps`(`deck.yaml` + `media/`,🚧 以后做)。

### 1.1 顶层字段

| 字段 | 必填 | 说明 |
|---|---|---|
| `reps` | 是 | 格式版本,现在是 `1` |
| `meta` | 否 | 牌组信息块,见 1.2 |
| `deck` | 是 | 牌组名 |
| `tags` | 否 | 行内列表,如 `[数学, 考研]` |
| `cards` | 是 | 卡片列表,每张以 `- ` 开头 |

### 1.2 `meta`(导入时全可选;发布到牌组广场时标 ★ 的必填)

| 字段 | 说明 |
|---|---|
| `id` ★ | 牌组固定身份(uuid)。第一次导出时生成,之后永不改变 |
| `version` ★ | 整数,作者每发布一次 +1 |
| `author` ★ | 作者 |
| `license` ★ | 许可证,建议 `CC-BY-4.0` |
| `description` ★ | 简介 |
| `language` | 如 `zh-CN` |
| `source` | 内容来源(如教材名) |
| `generated_by` | `manual` / `ai` / `ai+manual` |

### 1.3 每张卡

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | 否 | 卡片固定身份。字母、数字、`-`,文件内唯一。缺了导入时生成,导出时写回 |
| `type` | 否 | `qa`(默认)/ `choice` / `cloze` |
| `title` | 否 | 显示在列表与浏览页 |
| `front` | 是 | 正面 |
| `back` | `qa` 必填 | 背面;`choice` / `cloze` 里是可选的解析 |
| `options` | `choice` 必填 | 至少 2 项,每项加引号;行内 `["a", "b"]` 或多行 `- "a"` |
| `answer` | `choice` 必填 | 单选 `D`;多选 `[A, C]`。按位置映射 A、B、C…,大小写不敏感 |
| `tags` | 否 | 这张卡自己的标签 |

### 1.4 写法规则

- `front` / `back` / `title` / `options` 的每一项:**引号标量或 `|` 块标量**,不接受裸标量
  (挡住冒号截断、`no` 变布尔、`#` 被当注释)。
- 缩进 2 个空格,禁止 Tab。`#` 注释只能整行,且不在 `|` 块内。
- 块的正文首行要以空格开头(缩进的代码)时写 `|2`:正文从「键所在列 + 2」开始,多出来的空格算内容。
- 行内语法:标准 Markdown、`$…$` / `$$…$$`(KaTeX)、`{{挖空}}`。
- 挖空:一张卡所有空同时考(ADR-0002)。
- 单选/多选由 `answer` 个数决定;多选全对才算对。

### 1.5 导入时报错(带 YAML 行号)

答案字母超出选项 · 选项少于 2 · `choice` 缺 `options` 或 `answer` · 非 `choice` 却写了 `options` ·
`id` 重复 · 未知字段 · 文字用了裸标量。

### 1.6 兼容格式

- **没有 `reps:` 的旧 YAML**(如 `testdata/math1000.yml`):只认 `deck` / `tags` / 卡片的 `front` + `back`,
  `;;;` 选择题照旧识别。解析结果 `format = 0`。写了 v1 字段(`type` / `options`…)会提示加 `reps: 1`。
- **Quizify Card Markdown**(`+++` / `***` / `;;;`)仍可导入,产出同样的卡片结构。不再作为主格式。

### 1.7 进了 App 之后

- 选项存成 `A. 内容` 一行一项(`notes.options`,换行连接);复习页按下标取字母。
- 答案存成大写、去重、按字母序拼接:`[c, A]` → `AC`(`notes.answer`)。
- 没写 `title` 时,显示用正面首个非空行。
- 卡片标识键:有 `id` 就是 `id`,否则按 `title` 取(与 Quizify 一致)。
- 文件里的 `id` 落库为 **`牌组uuid/id`**(`noteUuidOf`)写进 `notes.uuid`,卡片的 `cards.uuid` 与它相同。
  文件里的 id 只要求文件内唯一,加上牌组命名空间后两副牌组都用 `c-0001` 也不会撞 UNIQUE。
  没写 id 的卡生成一个随机 id,同样带命名空间。导出(Task 5)时剥掉前缀写回 `id`。

## 2. 本地数据库(SQLite,`relationalStore`)

```
decks 1 ── n notes 1 ── 1 cards 1 ── 0..1 scheduling
                               └── n review_log(永不删除)
checkins(一天一行,永不删除)   meta(键值:迁移、设备 id、上次同步时间)
```

**内容和学习进度分开存**:改卡片内容不清进度,清进度不动内容;分享只导出内容;
FSRS-6 与固定阶梯共用同一份流水。

| 表 | 一行是 | 主要列 |
|---|---|---|
| `decks` | 一副牌组 | `id`、`name`(唯一)、`uuid`(部分唯一索引)、`version`、`meta`(JSON)、`tags`(JSON)、`updated_at`、`deleted_at` |
| `notes` | 一张卡的内容 | `deck_id`、`type`、`front`、`back`、`title`、`options`、`answer`、`source_file`、`fingerprint`、`uuid`、`updated_at`、`content_hash`(🚧 Task 4 起填写)、`tags`、`deleted_at` |
| `cards` | 一个排期单位(与 notes 1:1) | `note_id`、`ordinal`(恒 0)、`uuid`、`updated_at` |
| `scheduling` | 一张卡当前的排期 | `card_id`、`stability`、`difficulty`、`reps`、`lapses`、`streak`、`last_review`、**`due`**、`phase`、`step`、`first_seen`、`updated_at`(每次写入后 = `last_review`) |
| `review_log` | 一次作答 | `card_id`、`ts`、`grade`、`stability_before`、`elapsed_days`、`retrievability`、`interval_days`、`cost_ms`、`algo`、`archived` |
| `checkins` | 一天的打卡 | `day`(日序号)、`ts` |
| `meta` | 一个键值 | `key`、`value` |

- 新导入的卡**没有** `scheduling` 行,没有行 = 新卡。第一次作答才建行。
- 答一题:`scheduling` 整行覆盖 + `review_log` 加一行。
- 删牌组:删 notes / cards / scheduling,**流水保留**(ADR-0005)。`deleted_at` 列已在 v2 加上,
  🚧 但删除目前仍是真删、读路径也还没过滤它 —— 等 Task 8 同步需要墓碑时一起改,
  免得现在给几十条查询加过滤却没有任何代码会写这一列。
- **迁移**:`PRAGMA user_version`(relationalStore 里是 `RdbStore.version`)记录 schema 版本,
  当前 **v3**(v3 加了 `remote_day_stats` 与 `sync_tombstones` 两张表,见 §5.4)。DDL 永远是 v1 基线;之后每次改表在 `Schema.MIGRATIONS` 加一项,
  老库和新库走同一条路(DDL → 旧的按列迁移 → MIGRATIONS),每个版本一个事务。
- **新 uuid** 由 Database 层 `util.generateRandomUUID` 生成(v4 格式);v2 之前导入的
  笔记/卡片保留原来的 `n-…` / `c-…` uuid,不重新生成。

## 3. 身份与哈希

| 名字 | 在哪 | 怎么来 | 用途 |
|---|---|---|---|
| 卡片 `uuid` | `notes.uuid` / `cards.uuid` | 第一次入库时生成;导出写进 YAML `id`;之后**永不改变** | 认卡(导入、同步、版本更新) |
| 指纹 `fingerprint` | `notes.fingerprint` | 牌组名 + 标识键 + 序号的 64 位哈希(16 位十六进制,FNV-1a 与乘法哈希各 32 位拼成) | 没有 `id` 的旧文件重导时认卡 |
| 内容哈希 `content_hash` | `notes.content_hash` | 题型 + 标题 + 正面 + 背面 + 选项 + 答案 + 标签的 64 位哈希(`contentHashOf`);v2 之前的行是 '',下次导入时补上 | 同一张卡内容变没变;🚧 发布时判重 |
| 牌组 `uuid` | `decks.uuid` | 导入时取 YAML `meta.id`;没有就生成;老牌组在 v2 迁移时补上 | 认牌组(导入、同步、版本更新) |
| 文件 `sha256` | `catalog.json` | 整个分享文件 | 下载后确认文件没被改 |

**导入时怎么认(`Schema.planDeckImport`,只在这副牌组里找):**

1. 牌组:先按 `meta.id`,再按名字,都没有就新建。
2. 卡片:文件写了 `id` → 按 `牌组uuid/id` 找(也认没有前缀的旧 uuid,即 v2 之前导出的 id);
   找不到 → 按 64 位指纹;再找不到 → 按 8 位旧指纹(命中就升级成新指纹)。
3. 认出来的旧卡:内容哈希相同 → 跳过;不同 → **更新内容,排期不动**。
4. 都认不出 → 新卡。
5. 牌组里有、文件里没有的卡**不删**,导入提示里显示「文件里少了 N 张」(已与用户确认)。

整次导入一个事务,中途失败全部回滚。导入后牌组的 `tags` / `meta` / `version` 也写回 `decks`。

**为什么指纹要从 32 位改成 64 位:** 32 位约 1 万张卡有约 1% 概率、7.7 万张约 50% 概率撞车;
`fingerprint` 是 UNIQUE,撞车时真正的新卡会被当成旧卡跳过,用户只看到「跳过 1 张」。

**旧的 8 位指纹怎么办:** 库里只存了标题,没存算指纹用的标识键,所以迁移时没法重算。
改为导入时**惰性升级**:`planImport` 先查 64 位新指纹,查不到再查 8 位旧指纹
(`legacyFingerprintOf`);命中就算旧卡,并在同一个事务里把那一行换成新指纹。
新指纹的前 8 位恰好就是旧指纹,排查时一眼能对上。

## 4. 今天出哪些卡

1. **一天从凌晨 3 点开始**(`dayIndex`:先减 3 小时再按天取整)。打卡与统计共用这一个日界。
2. **到期旧卡**:`scheduling.due <= 现在`,按 `due` 升序。比较的是「现在」不是 3 点,
   否则 10 分钟的学习步进卡会立刻冒出来。
3. **新卡**:没有 `scheduling` 行的卡,按导入顺序。
4. **每日上限**:复习数、新卡数各有上限,**每个牌组单独算**(ADR-0004)。超出的留到明天。
5. **会话开始时一次定好**今天的集合,之后不变。

**FSRS-6**(`srs/Srs.ets`,21 个参数):每张卡维护稳定性 S、难度 D、可提取性 R;
按评分更新 S、D,再反解 R 降到目标保持率的时刻作为下次 `due`。新卡先走学习步进(`phase` / `step`)。

## 5. 云端(ADR-0006;2026-10-26 MatePad 实测通过「新设备登录后取回牌组与进度」)

### 5.1 云存储

| 路径 | 内容 | 谁能读写 |
|---|---|---|
| `users/{uid}/decks/{deckUuid}.yaml` | App 导出的带 `id` 的 YAML | 仅本人 |
| `public/decks/{deckId}/v{version}.yaml` | 已发布的牌组 | 登录用户只读;App 不能写 |
| `public/catalog.json` | 牌组广场目录 | 登录用户只读 |

### 5.2 云数据库(权限:仅创建者)

> **🚧 提议(Task 9,待确认):四类数据合成一个对象类型 `reps_sync`。** 同步核心(§5.4)本来就把
> 四类数据统一成同一种记录(kind + key + data + 两个时间戳 + 删除标记),一张表就够了:
> 控制台 / agcli 只要建一个对象类型、一套权限,客户端也只有一份读写代码。
>
> | 字段 | 类型 | 说明 |
> |---|---|---|
> | `id` | String,**主键** | `uid|kind|key`。带 uid:两个用户的 `day-100` 不会撞主键 |
> | `uid` | String | 认证服务给的用户 id |
> | `kind` | String | `checkin` / `daily` / `deck` / `card` |
> | `key` | String | 打卡:日序号;汇总:`设备id|日序号`;牌组:牌组 uuid;卡片:卡片 uuid |
> | `data` | Text | 这一类自己的 JSON(排期字段、牌组名与文件路径…) |
> | `updated_at` | Long | 新者胜 |
> | `synced_at` | Long | 增量下载 |
> | `deleted` | Boolean | 墓碑 |
>
> 索引 `(uid, kind, synced_at)`。权限:Creator 读 / 写 / 删,其余角色全无。
> 下表是原先的四表设计,字段含义不变,只是落在 `data` 里。

| 对象类型 | 字段 | 删除 |
|---|---|---|
| `checkin` | uid、day、ts | 永不删 |
| `daily_stat` | uid、day、deviceId、reps、cost_ms | 永不删;读时跨设备相加 |
| `deck` | uid、deckUuid、name、filePath、updated_at、deleted | 删除标记 |
| `card_state` | uid、cardUuid、deckUuid、排期字段、updated_at | 牌组删除后清理 |

### 5.3 本地 ↔ 云端

| 本地 | 云端 | 方向 |
|---|---|---|
| `checkins` | `checkin` | 双向合并(并集) |
| `review_log` → 按日汇总 | `daily_stat`(本机 deviceId 的行) | 只上传;本机统计从不读自己的行 |
| 其他设备的 `daily_stat` | — | 只下载,加到热力图 |
| `decks` | `deck` + 云存储文件 | 双向,`updated_at` 新者胜 |
| `scheduling`(经 `cards.uuid`) | `card_state` | 双向,`updated_at` 新者胜 |

- 本地 SQLite 是唯一事实来源,云端是副本。
- 学完一轮批量上传 `updated_at` 新于上次同步的行;失败只记录,下次重试,不打断学习。
- 只用免费套餐;每日写入 2 万次是首个瓶颈。

### 5.4 同步核心(`data/SyncCore.ets`,纯逻辑,桌面测试 `sync_test`)

- 四类数据(`SyncKind`):打卡、每日汇总、牌组、卡片排期。牌组排在卡片前:收到本地没有的牌组时,
  先下载 YAML 导入,同一轮里后面的排期才对得上。
- **两个水位**:`lastPush`(本地 `updatedAt` > 它的上传)与 `lastPull`(云端 `syncedAt` > 它的下载,
  再往回退 10 分钟容忍时钟差)。分开是因为离线编辑的行 `updatedAt` 早、上传晚,按 `updatedAt` 拉会漏掉。
- 冲突 `updatedAt` 新者胜;离线很久的设备带着旧编辑上线,不会盖掉新的。一批最多 100 条。
- 任何一步失败都不推进水位,下次整轮重来;上传与合并都是幂等的。
- **删除墓碑**(v3 表 `sync_tombstones`):本地删除照旧是真删,删之前记一行墓碑,同步时作为
  `deleted = true` 的记录发出去。卡片墓碑表示「没有排期了」:删卡、删牌组、清空进度都记。
  没有用 `deleted_at` 软删除 —— 那要给几十条读查询加过滤,墓碑只碰删除与同步两处。
  已知局限:另一台设备上单独删掉的一张卡,只会让本机这张卡的排期清空,卡本身不删
  (卡片内容随牌组 YAML 走,重导时「文件里少了的卡」只提示不删)。
- 其他设备的每日汇总缓存在 v3 表 `remote_day_stats`;`Database.dayStats` = 本机现算 + 它们相加。
- 设备 id:第一次用到时生成随机 uuid,存在 `meta` 表 `device_id`。

## 6. 导出与分享不含个人数据

学习页牌组的「⋯ → 导出并分享(YAML)」:`Database.exportDeckYaml` → `YamlExport.exportYaml` →
写进应用缓存 → 系统分享面板(华为分享、复制、另存为、发给其他应用)。

导出的 YAML 只有 `reps`、`meta`、`deck`、`tags`、`cards` 的内容字段。
**永不包含** `scheduling`、`review_log`、`checkins`、`daily_stat`、设备 id、uid ——
导出用的两条 SQL(`SQL_EXPORT_DECK` / `SQL_EXPORT_NOTES`)只取内容列,导出函数的输入里压根没有这些数据。
桌面测试 `export_test` 往返校验:写进排期、流水、打卡之后导出的文本一字不变,也不含任何学习数据。

写法:
- `meta.id` = 牌组 uuid;卡片 `id` = 剥掉 `牌组uuid/` 前缀的 uuid(v2 之前的卡就是它原来的 uuid)。
- 正文单行用双引号(只转义 `\` 和 `"`),多行用 `|` 块;块的首行以空格开头时写 `|2`(缩进的代码)。
- 选项去掉「A. 」前缀;长选项一行一个。`title` 等于正面首行时不写。
- 导出 → 导回同一个库:什么都不改;导入另一台设备的空库:牌组与每张卡的 uuid 完全相同(同步靠它)。
