# CleanMyMac 5 规则引擎拆解（对照 Sift）

对象：`/Applications/CleanMyMac.app` 5.7.3（build 50703.0.2610281229）。
分析时间 2026-11-01 18:50–19:10。**本文件只做分析，未改动 sift 代码。**

## 1. 规则在哪、怎么拿到的

规则不在代码里，而在一个加密的 SQLCipher 数据库里：

```
~/Library/Group Containers/S8EX82NJP6.com.macpaw.CleanMyMac5/
  Library/Application Support/KnowledgeBase/info.cmmkb      299 KB  ← 当前生效的规则库
  Library/Application Support/KnowledgeBase/userInfo.cmmkb    2 KB  ← 用户忽略表
/Applications/CleanMyMac.app/Contents/Resources/info.cmmkb  298 KB  ← 随包发布的初始版本
```

日志（`…/Logs/CleanMyMac_5/…log`）验证它**在运行时从网络更新**：

```
15:23:09 📚 KB started … with 1.1.52.202605201253
15:23:09 📚 Current hash 07d88f0c…ce7a0
15:23:14 📚 Knowledge base was updated - 376e074f…cf181f
15:23:14 📚 KB started … with 1.1.54.202610271229
```

取数方法（可复现，产物在 `/tmp/cmmr/`）：解锁版只留了 `get-task-allow` +
`disable-library-validation`，因此可以用 `DYLD_INSERT_LIBRARIES` 注入一个 dylib，
hook 掉 FMDB 的 `FMDatabase` 家族：

* `-[FMDatabase initWithPath:]` — 抓 `info.cmmkb` 的实例
* `-[FMDatabase setKeyWithData:]` — 抓到 **64 字节的十六进制串**当密钥
  （class 是 `KnowledgeBaseAPIService.FMEncryptedDatabase`；`PRAGMA cipher_default_compatibility = 3`）
* 打开后对同一连接执行 `sqlite_master` + 逐表 `SELECT *`，写 `/tmp/cmmr/kb_dump.txt`

结果：`PRAGMA cipher_version = 3.4.2`、`cipher_page_size = 1024`，7 张表、5956 行。
脚本：`/tmp/cmmr/kbhook2.m`（hook + 导出）。原始转储 `/tmp/cmmr/kb_dump.txt`，
结构化 `/tmp/cmmr/kb_rows.json`。

## 2. 数据模型

```
GroupType(26)          Type | PrefixPath | Description             ← 锚点表
ScanItems(1509)        RecordID | Value | ItemType | ScannerID | GroupType | IsRegex
ApplicationInfo(991)   RecordID | Name | BundleID | Type           ← 应用身份
ApplicationFiles(1917) RecordID | Value | FileType | GroupType | Owner | IsRegex
RecordInfo(1509)       RecordID | Value                            ← 迁移标记
General(1)             Key=Version | Value=1.1.54.202610271229
```

四张内容表各管一件事：**锚点 → 扫描规则 → 应用身份 → 每应用的路径**。
`ScanItems` 与 `ApplicationFiles` 都是「一条 = 一个待匹配的路径片段」，都带
`IsRegex`，也都能挂到 `GroupType` 上前缀拼接。也就是说 CMM 的规则不是「路径模板」，
而是「锚点 × 片段」，片段是普通字符串或正则。

### 2.1 锚点表（GroupType，26 条）

| Type | PrefixPath | 说明 |
| --- | --- | --- |
| 1 | `/Library/Application Support/` | Application Support |
| 3 | `~/` | HomeDir Hidden Files |
| 4 / 5 | `/Library/LaunchAgents/` `/Library/LaunchDaemons/` | 启动项 |
| 7 / 13 | `/Library/` `~/Library/` | 库文件 |
| 8 / 14 | `/Library/Preferences/` `~/Library/Preferences/` | 偏好 |
| 9 | `~/Library/Application Support/` | 用户 Application Support |
| 10 | `~/Library/Caches/` | 用户缓存 |
| 11 / 12 | `~/Library/LaunchAgents/` `~/Library/LaunchDaemons/` | 用户启动项 |
| 16 / 17 | `/Library/Extensions/` `/System/Library/Extensions/` | Local / System kext |
| 18 | `~/Library/Containers/` | 沙盒容器 |
| 19 | `/Library/PrivilegedHelperTools/` | 特权 helper |
| 20 / 21 | `/Library/Logs/` `~/Library/Logs/` | 系统 / 用户日志 |
| 23 / 24 | （空） | Temp Files / Package Regex |
| 25 / 26 / 27 | 自己各子应用的容器日志 | CMM MAS / HealthMonitor / Menu |
| 28 | `~/Library/Group Containers/` | 组容器 |
| 0 / 15 | （空） | Other File Type / Package |

注意两点：`~/`（HomeDir Hidden Files，Type 3）是一个**一等锚点**，sift 里点目录
只能靠 `relativePath` 里写点，并且受「显示隐藏文件」开关约束（invariant 35）；
Type 24「Package Regex」说明它们允许锚点本身就是正则。

### 2.2 规则的分布（ScanItems，按 ScannerID）

| ScannerID | 条数 | 形态 | 推断用途（按样本） |
| --- | --- | --- | --- |
| 2 | 276 | `com.apple.IMServicePlugInAgent` 之类 | 系统自带 App 名单 |
| 3 | 233 | `edu.mit.csail.plist` + gt 8/14 各一行 | 已知破损偏好（系统 + 用户成对） |
| 5 | 81 | `com.adobe.flash`、`com.macromedia.Flash Player.app` | 遗留/已停止维护的组件 |
| 10 | 89 | `GeoServices`、`Metadata/1Password`、`SentryCrash/Arc` | **缓存白名单 + 嵌套缓存子路径** |
| 30 | 111 | `de.living-e.mamppro`、`edu.berkeley.boinc` | 应用名单（另一组） |
| 84 | 28 | `.*ru\..*`、`.*kaspersky.*`、`.*com\.vk.*`（ItemType 13） | **排除名单** |
| 39 | 20 | `~/Library/Mail`、`~/Library/Containers`、`/Library/Preferences` | **硬保护路径** |
| 9 | 37 | 正则：`^TemporaryItems$`、`^.+/com.apple.audiounits.cache$` | **全局忽略（正则）** |
| 24 | 18 | `^.*\.vdi$`、`^.*\.vmwarevm$` | 虚拟机磁盘 |
| 27 / 26 | 19 / 1 | `Logs/com.macpaw.CleanMyMac3`、`CrashPlan` | 各家旧日志 |
| 15 | 12 | `/Library/Dictionaries/Oxford …dictionary` | 系统词典/编解码器 |
| 14 / 7 / 65 | 13 / 5 / 1 | `com\.oracle\..*` × 4 个锚点、`com.macpaw.CleanMyMac.*` | 启动项/守护进程 |
| 18 | 1 | `com\.apple\..+` | 排除 Apple 残留 |
| 36 / 74 / 75 / 79 / 4 / 6 / 44 / 80 | 1–5 各 | `^iMazing\..+$`、`Internet Plug-Ins/Flash Player.plugin` | 单点规则 |
| （无）| 541 | 混合 | 全局集合：路径 + 正则 |

`ItemType` 取值 2/3/5/6/9/13/14，`3` 是主力（931 条 = 路径或名字），`13` 只出现在
排除名单纯，`6` 出现在卷（`^/System/Volumes/Data`）。

### 2.3 每应用知识（ApplicationFiles 1917 条 / 487 个 App）

样本：

```
Safari      [com.apple.Safari]      gt=0 regex  .*Safari.*
Parallels   [com.parallels…]        gt=14       …（32 条）
Logic Pro 9 [com.apple.logic.pro]   gt=…        （41 条，最多）
MacKeeper   [com.mackeeper…]        gt=…        （25 + 24 条）
```

`FileType` 只有 0（40 条，浏览器类正则）和 1（1877 条）两种。锚点分布：
Preferences 464、Other 241、Application Support 200、Caches 184、Library 183、
`~/Library/` 139、LaunchDaemons 84。

这就是「一个 App 一条规则」做不到的那层：**487 个 App × 平均 4 条路径**，靠规则
表枚举会变成 1917 条规则；CMM 把它拆成「身份表 + 路径表」，路径表按 owner 关联。

## 3. 排除机制（这部分最值得看）

CMM 用三种不同的机制表达「不要动」：

1. **硬保护路径**（ScannerID 39，20 条，普通字符串）：`~/Library/Mail`、
   `~/Library/Containers`、`~/Library/Messages`、`~/Library/Safari`、
   `~/Library/Preferences`、`/Library/Preferences`、`/Library/Receipts`，
   另外还有 **Sophos / Sophos Anti-Virus / Bitdefender / Tresorit** ——
   其它安全厂商和同步客户端的数据整目录不碰。
2. **全局忽略（正则，ScannerID 9 + 无 ScannerID 的 541 条）**：
   `^TemporaryItems$`、`^Canon`、`^.+/com.apple.Safari/Extensions`、
   `^/private/var/folders/.*/com.apple.sharingd(/)?$`。
   甚至用了负向前瞻：
   `^/System/Library(?!/Caches/com.apple.coresymbolicationd)` ——
   整个 `/System/Library` 都排除，只放行一个缓存。
3. **排除名单（ScannerID 84，ItemType 13）**：`.*ru\..*`、`.*kaspersky.*`、
   `.*maps\.me.*`、`.*com\.vk.*`。

227 条 `IsRegex = true` 的规则，全部走 `NSRegularExpression`。

## 4. 与 Sift 的规则引擎对比

| 维度 | CleanMyMac 5 | Sift（当前） |
| --- | --- | --- |
| 载体 | 加密 SQLCipher KB（299 KB，7 表） | `Core/Resources/CleaningRules.json` + 生成器 |
| 规模 | 26 锚点 / 1509 扫描规则 / 1917 应用路径 / 991 应用身份 | 23 条规则 |
| 匹配能力 | 普通名 + 正则（含前瞻）| 名字、扩展名、`directoriesNamed`、整段 `*` |
| 应用知识 | 独立表，487 App | 无（一个 App 一条规则） |
| 排除 | 硬保护 + 全局正则忽略 + 排除名单三套 | `PROTECTED_*`（8+14+7）+ `FORBIDDEN_RULE_DIRECTORIES`(3) |
| 更新 | 运行时下载、sha256 校验、可回滚（`databaseIsNotNew`） | 编译进二进制，走发布 |
| 风险分级 | 由扫描器/分组决定（KB 里没有 risk 列） | 每条规则带 `safe`/`review`，未发布规则上限 `review` |
| 默认选中 | `JunkCleanupAutoSelectableStrategy`（代码策略） | `safe` 即预选，运行中的应用整体降级（invariant 31） |
| 可审计 | 加密 + 远程更新，用户看不到规则 | 明文、生成器、`verify.sh` 校验 |
| 执行 | `PrivilegedFileRemover`（root helper）可就地改写（剥离架构、删语言包） | 只走废纸篓，无 shell、无 root（invariant 1/18） |

## 5. 可以借鉴的（按价值排序）

### 5.1 「应用身份 + 应用路径」两张表，和规则表分开

CMM：`ApplicationInfo(991)` ← `ApplicationFiles(1917)`，按 `Owner` 关联，
一条路径可以挂任意锚点。**对 Sift 的意义**：本轮扫描里 `~/Library/Caches` 下 45 个
目录被当成「残留」或「缓存」，其中 `com.tencent.workbuddy.mac.BundleMigration`
（688.9 MB）因为名字不等于安装 App 的 bundle id 而被误判。有了应用身份表，
「这个名字属于哪个 App」是一次查表，不是一次字符串相等判断；`Chat.Nightly`、
`…-updater`、`…BundleMigration` 这类后缀自然归属到父 App。
落点：新增 `Core/Resources/ApplicationCatalog.json`（bundle id、显示名、别名、
已知数据根），engine 侧加一次查表，`scan_application_residue` 改成
「最长前缀匹配 + 身份解析」。

### 5.2 缓存白名单 vs 全量枚举

CMM 的 `~/Library/Caches` 顶层同样是全量清（本次清掉了 Google/Trae CN/Doubao），
但它另有 33 条**具名/正则子路径**（`Metadata/1Password`、`SentryCrash/Arc`、
`ms-playwright`）来表达「这个子目录也是缓存」。这是 sift 的 `directoriesNamed`
已经能表达的形状，缺口在**数据**：sift 一条具名缓存规则都没有，所以
`~/.codex/packages`(2.6 GB)、`~/.workbuddy/blobs`(747 MB)、`~/.zcode/cli`(2.9 GB)
这类目录完全没覆盖（`audit-coverage.py` 实测约 21 GB 无规则）。CMM 的做法提示：
这些应当是**具名层规则**，不是「点目录整目录」规则。

### 5.3 「未知 = review，已知 = safe」的判定来源

CMM 的 KB 里没有 risk 列，安全等级来自扫描器与代码策略；Sift 的等级在规则上。
两者可以合并成一条更细的规则：**一份目录属于「已登记的应用数据」→ review；
属于「已知可再生成的缓存形状」→ safe；两者都不属于 → 不产生候选**（而不是像现在
把两者都不属于的当成残留）。本轮 8108 条「应用残留」里 7789 条是自家测试产物、
569 条是 `com.apple.*`，正是「不属于任何应用也能算残留」的直接后果。

### 5.4 排除表独立于规则，且允许用户追加

CMM 有三套排除且互相独立，`userInfo.cmmkb` **单独存用户忽略表**
（`CustomIgnoreItem` / `CustomIgnoreItemSnapshot` / `userIgnoreListUpdatedNotificationName`）。
Sift 有 `SettingsStore.ignoredPaths`（用户忽略路径，存在偏好里），但没有和引擎的
排除表合成一层；`_IgnoringKnowledgeBaseType` 这种类型名说明 CMM 是把「忽略」
当成知识库的一等公民。落点：让 `ignoredPaths` 参与 `ScanRequest`，由两个引擎
在匹配前统一过滤，而不是只在展示层过滤。

### 5.5 版本化 + 校验的规则包

KB 有 `Version = 1.1.54.202610271229`、启动时比对、sha256 哈希、
`KnowledgeBaseUpdaterServiceUpdatedKnowledgeBaseFile` 通知、
`databaseIsNotNew` 回落。Sift 的规则要跟着 App 发版，装了就旧。
**只借机制不借加密**：规则包带 `version` + `sha256` + 审核状态，
`safe` 仍然要求「发布前人工 review」（invariant 23 的立场不动）。

### 5.6 正则能力的中间态

CMM 227 条正则含前瞻（`^/System/Library(?!/Caches/…)`）。Sift 目前禁止部分通配，
换来的是「可枚举、可审计、可预算」（`MAX_RULE_ROOTS`）。可借的中间态：
允许**锚定前缀 + 整段组件**的正则子集（`^name(/.*)?$` 这种），在加载时编译并
验证「不以 `*` 开头、不含 `**`、必须有 `^`」，既能表达 Arc/Dia 这类
「同一 App 多个缓存目录」的形状，又不破坏可枚举性。

### 5.7 AI 工具的「活跃版本」问题

`AIToolScanning` 的符号最能说明这一类为什么不能只写路径规则：

```
AIToolIdentity / AIToolCatalog / AIJunkIgnoreRules / FirstLevelRule
ActiveVersionResolver / activeVersionSymlink / StaleVersionGuard
ShardGroupKey / ShardFileName / GGUFCandidate / LocalModelFormat
OllamaStoreScanner / LMStudioStoreScanner / Manifest / Layer / digest
```

即：先认出是哪个 AI 工具（Claude / Codex / Cursor / Antigravity），
解析「当前活跃版本」的符号链接，只把**非活跃版本**当残留；
本地模型按 store 的 manifest（Ollama 的 `manifests`/`blobs` + layer digest、
llama.cpp 的 GGUF 分片）成组识别，而不是按文件名猜。
Sift 想覆盖那 21 GB，需要的是**一个只读的清单器**（发现 + 分组 + 只读度量），
和 invariant 4「Rust core 只发现与分析」完全兼容。

## 6. 不该照抄的

1. **就地改写**：`UniversalBinaryThinner`、语言包删除、`DocumentVersionRemover`
   都是改已装应用的文件，违反 invariant 1（一切清理走废纸篓）。
2. **root helper 执行删除**：`PrivilegedFileRemover`；Sift 的承诺是无特权、无 shell。
3. **用正则判定「风险」**：`.*ru\..*`、`.*kaspersky.*` 这种名单不可审计，
   也不该由清理工具替用户决定。
4. **加密 + 静默远程更新**：规则是产品行为的一部分，用户与审查者都要能读到；
   `verify.sh` 能校验的前提正是明文与生成器。
5. **`~/` 作为一等锚点后没有「不可清」的兜底**：CMM 靠 `ScannerID 39` 的 20 条硬保护，
   Sift 的 `PROTECTED_HOME_CHILDREN`(8) + `PROTECTED_PREFIXES`(14) 覆盖面更大，
   这个方向不要退回去。

## 7. 结论

CMM 的规则引擎本质是**「锚点表 × 片段表 × 应用身份表」的关系型知识库**，加密、
版本化、可远程更新；Sift 是**「规则文件 + 生成器 + 三处保护校验」的明文表**。
前者在「数据量」和「更新速度」上领先，后者在「可审计」和「执行安全」上领先。

真正值得借的三件事，按性价比：

1. **应用身份表**（修掉 688.9 MB 误报，且是 AI/开发工具覆盖的前置条件）；
2. **具名层规则的覆盖面**（把 `~/.codex/packages` 这类 21 GB 写进规则表）；
3. **忽略表下沉到引擎**（用户可忽略、且与 `PROTECTED_*` 同层生效）。

数据可以借，机制不要照抄：加密与远程更新不适合一个「规则即承诺」的产品。
