# 腾讯柠檬清理（Tencent Lemon）清理规则体系：逆向观察与可借鉴点

调查对象：`/Applications/Tencent Lemon.app`，版本 **5.3.3 (1047)**，CFBundleIdentifier `com.tencent.Lemon`，
fat binary（x86_64 + arm64），118 MB，44 个内嵌 framework，构建机 Xcode 16.1 / macOS SDK 15.1（`macosx15.1`）。
调查时间：2026-11-01。目的：给 Sift 的清理规则找可直接借鉴的东西。

> 方法说明：只做**静态**分析（`strings` / `nm` / plist / SQLite 读取 / 字符串邻接关系还原），没有运行它做清理，
> 没有联网抓它的规则包。所有结论都标注了「观察到的常量」与「推断」的区别。

---

## 0. TL;DR — 最值得抄的五件事

| # | 它怎么做 | 我们现在 | 价值 |
|---|---|---|---|
| 1 | **`clean_status` 表把用户对每个子类的勾选状态持久化**（本机实测：324 条记录，291 选中 / 33 取消） | 每次扫描都从规则表的 `risk` 重新推导默认勾选，用户上次关掉的规则下次又被勾上 | 高。用户关掉一个子类是一次表态，不是一次操作 |
| 2 | **规则条目带 `type`（扫描策略）+ `action`（处置动作）两个正交维度**，还有 `defaultstate` / `multi` / `sandbox` / `relation` / `bundle` / `appname` | `Rule` 只有 `match_spec` + `min_age_days` + `excludes`，一条规则只能说「在哪、多久」 | 高。`type` 这一层是我们缺的表达力 |
| 3 | **`filters` 是带逻辑的排除器**（`contains` / `suffix` / `regex` / `logicLevel`=and-or） | `excludes: Vec<String>` 只做字面量名字匹配 | 中高。低成本、纯收益，双端都能加 |
| 4 | **`cautions` 是一等公民**：整组「谨慎项」默认不勾，与普通条目在结构上分开 | 靠 `Risk::Review` 单点降级 | 中。我们缺「整组谨慎」这个 UI/结构概念 |
| 5 | **破损登录项 / 破 plist（`brokenregister` / `brokenplist` 策略）**：读 plist 指向的可执行文件是否存在 | 完全没有登录项扫描 | 高。这是清理软件里用户感知最强的「无用项」之一 |

还有一条反向的：**它把 `truncate` / `cutbinary` / `removelanguage` / `deleteBinary` 当作规则可以指定的动作**
（原地截断、剥语言包、裁二进制、直接删）。这四条我们**不该抄**——见第 6 节，理由写在我们的不变式 1 上。

---

## 1. 它把规则放在哪：云端下发的 XML 知识库

规则本体**不在安装包里**，是运行时下载的 XML：

```
~/Library/Application Support/com.tencent.lemon/KnowledgeCh/2      ← 中文规则
~/Library/Application Support/com.tencent.lemon/KnowledgeEn/2      ← 英文规则
~/Library/Application Support/com.tencent.LemonLite/KnowledgeCh/2  ← Lite 版
```

（`KnowledgeCh`/`KnowledgeEn`/`Knowledge/2` 四条路径以字面量形式硬编码在 `LemonClener` 与 `QMCoreFunction` 里；
`QMCoreFunction` 上有 `_knowledgePath` / `setKnowledgePath:` / `knowledgeUpdateNotification:`。）

### 1.1 规则本体：本机没有，服务器也不下发（证据链）

这一段是后来补做的验证，结论是**拿不到规则内容**，而且不是「没找到」，是**它自己也没拿到**：

1. `~/Library/Application Support/*encent*/Knowledge*` 四个目录全部不存在；`find /` 全盘也没有别的
   `KnowledgeCh`。
2. 主进程日志 `~/Library/Logs/Tencent Lemon.log:98`：
   `2026-10-31 16:27:57.011 fetchCleanConfigure responseData is nsnull: {}` —— 解析出来是**空字典**。
   紧随其后的是 `wechat version : 4.1.8` 和 `cleanItemParseEnd stop`：XML 解析器跑完了，但手里没有条目。
3. `NSURLCache` 的落盘缓存直接给出了回包原文
   （`~/Library/Caches/com.tencent.Lemon/Cache.db` → `cfurl_cache_receiver_data`）：

   ```
   https://lemon.guanjia.qq.com/cleanconfig   →  {"code":0,"msg":"请求成功","data":{}}
   ```

   **code 0，请求成功，data 空。** 不是被墙、不是签名错、不是版本不匹配——服务端就是这么回的。
4. 我按参数名逐个暴力试探了 `cleanconfig`（`guid` 用的是它自己 `kLemonCurrentGuid` 里的真值
   `03113825110309164901029192565702`，还试了 POST JSON），一律 `{"code":1,"msg":"参数错误"}`；
   但即便猜对参数，第 3 条的缓存已经说明**它自己的请求也只拿到 `{}`**。
5. 安装包内**没有**内嵌副本：`Assets.car` 里 211 个资源全是 `Image`，没有 `Data` 资产；
   所有二进制里没有 `bplist00` 魔数，`__cstring` 里也没有任何 `<category`/`<item` 之类的 XML 片段。

所以：**这份 XML 的表结构是我从解析器代码反推的，不是从规则文件读的**——这一点在下面每个结论上都标注了
「观察到的常量」还是「推断」。它的用户（包括你这台，92 次清理记录、324 条子类勾选状态）跑的是
**代码里写死的那批路径 + 扫描策略**，云端那层知识库对这批客户端已经不下发了
（客户端 5.3.3，当前线上 5.3.7）。

### 1.2 下载链路（还原出来的，供将来对照）

```
GET  https://lemon.guanjia.qq.com/cleanconfig
       → { code, data: { fileurl, Version, updateType } }        // 现在返回 {}
GET  <fileurl>                                                    // zip
/usr/bin/unzip -o …                                               // 跳过 __MACOSX
       → ~/Library/Application Support/com.tencent.lemon/KnowledgeCh/<Version>/
```

相关符号：`-[LMHttpRequestManager fetchCleanConfigure:callBack:]`（`imp 0xd920`，`QMCoreFunction`）、
`QMNetworkFileSave`、`QMNetworkFileChangedNotificaton`、
`QMNDQueryErrorInvalidDownloadURL` / `EmptyDownloadData` / `UnzipFailed`。
另一条线是 RDelivery（`https://rdelivery.qq.com/v3/config/pull`，md5 `sign` + gzip/base64 `context`，
属性里带 `qimei`/`guid`/`bundleId`/`appVersion`），本机每 4 小时拉一次，回包 `hasNext:0, bizData:null`，
同样是空的。

顺带能看到的：`lm cleaner use update verison = %@` / `lm cleaner use current verison = %@` —— 规则库有版本号，
`/2` 是版本目录，下载是 gzip（`dataByGZipCompressingAtLevel:...`）。**没有看到签名校验**。

> 对我们的意义：我们的 overlay 规则文件（不变式 23）已经是「文件可扩展、编译进保护表不可动」，
> 比它这个明文 XML 强。**不建议**改造成远程下发；要抄的是它的**版本化与回退**思路，不是它的分发方式。

---

## 2. 还原出来的规则 schema

从 `LemonClener` 的字符串表里，`filter` / `cautions` / `category` / `item` / `atom` / `path` / `garbage` /
`version` / `title` / `tips` 这十个词是**连续排布**的，紧挨着下面这批属性名——它们是同一个 XML 词表：

```
            <knowledge version="N">
  <filters>   <filter …/>                      ← 排除器，带逻辑
  <cautions>  <caution …/>                     ← 谨慎组
  <category id title tips>
    <item type action path  …attributes… >
      <atom …/>                                ← 单一目标（一个具体路径/文件）
    </item>
  </category>
```

### 2.1 `item` 的属性（观察到的字面量）

| 属性 | 作用（推断） |
|---|---|
| `type` | **扫描策略**，见 2.2。决定「怎么找」 |
| `action` | **处置动作**，见 2.3。决定「怎么删」 |
| `path` | 目标路径，支持 `%@` / 正则片段 |
| `level` | 风险等级（我们的 `Risk`） |
| `defaultstate` | 默认是否选中——**不是从 level 推的，是规则自己说的** |
| `showaction` | 是否在结果里给「显示」按钮（打开 Finder） |
| `fastmode` | 该条目是否走快速模式（不逐个算大小） |
| `multi` | 一条规则出多个结果 |
| `sandbox` | 需要按沙盒容器路径展开 |
| `relation` | 该条目与某个 app 的关系（用于「这是某某应用的东西」展示） |
| `bundle` / `appname` / `apppath` / `appversion` / `buildversion` / `appstorebundleid` | 与具体应用绑定，以及**版本门控**（只在某版本区间内清理，避免清坏新版本的数据格式） |
| `language` | 语言包相关（配合 `removelanguage`） |
| `column` / `value` / `value1` / `garbage` | 结果表的列与取值映射 |

`appversion` / `buildversion` 这条很值得注意：**规则可以按应用版本收窄**。微信改一次存储结构，
它下发一个新规则版本区间就行，不用等客户端发版。

### 2.2 `type`：扫描策略（决定「怎么找」）

```
brokenplist      brokenregister   developer        appleft
binary           otherBinary      InstallPackage   mail
soft             derivedapp       archive
appcache         leftcache        leftlog
wechatAvatar     wechatImage      wechatImage90    wechatFile
wechatVideo      wechatAudio      cleanemptyfolder cleanhiddenfile
```

> 注意：这一批词和 2.3 的动作词在字符串表里是**同一个连续区块**，没有文档级标记区分。
> 「哪些是 type、哪些是 action」是我按**类名与选择器**划分的（`QMXcodeScan` / `__scanMailAttachments:` /
> `scanArchives:` 只能是策略；`truncate` / `movetrash` / `deleteBinary` 只能是动作），不是读到的标签。
> 词表本身是观察到的常量，划分是推断。

对应实现类（`QMCoreFunction` / `LemonClener` 的 ObjC 类符号）：
`QMXcodeScan`、`QMWechatScan`、`QMMailScan`、`QMAppLeftScan`、`QMBrokenRegister`、`QMSoftScan`、
`QMDirectoryScan`、`QMCacheEnumerator`、`QMFilterParse`、`QMAppUnlessFile`、`QMBaseScan`、`QMItemCreateHelper`。

### 2.3 `action`：处置动作（决定「怎么删」）

```
movetrash    clean       cleanemptyfolder   cleanhiddenfile
caution      truncate    removelanguage     cutbinary
deleteBinary deletePackage  safaricookie
```

**`movetrash` 只是其中一个**。其余是原地改写 / 直接删（第 6 节展开）。

### 2.4 对象模型

```
QMCategoryItem ── 类别        （对应我们的 Category）
  └ QMCategorySubItem ── 子类 （没有对应物：我们一个 Rule 就是一个可勾选单位）
      └ QMActionItem
          ├ QMActionPathItem  （一个目录）
          └ QMActionAtomItem  （一个具体对象）
QMResultItem / QMResultBrowerItem   ── 结果行
QMWarnReultItem / QMCleanWarnItem   ── 警告行（与结果行并列，不进清理队列）
QMFilterItem                        ── 排除项
```

**类别 → 子类 → 条目**是三级，且**勾选状态记在子类上**（见第 4 节）。我们的等价单位是 `Rule`，
也就是层级比它少一级——我们的 `Category` 目前只承担分组和筛选 chip 的作用，不是「可勾选容器」。

---

## 3. 它的清理规则内容（能从代码里看到的部分）

### 3.1 Xcode（`QMXcodeScan`）

```
~/Library/Developer/Xcode/DerivedData/(.+)      ← 逐个 DerivedData，正则取 app 名
~/Library/Developer/Xcode/Archives/             ← 归档
~/Library/Developer/CoreSimulator/Profiles/Runtimes/(.+)
~/Library/Developer/CoreSimulator/Volumes/(.+)/Library/Developer/CoreSimulator/Profiles/Runtimes/(.+)
Library/Developer/CoreSimulator/Profiles/Runtimes/iOS…
```

并且它调 **`/usr/bin/xcrun`** 拿真实的 runtime 列表（`__updateXcodeRuntimeListInfo`、
`setXcodeRuntimeListInfo:`、`[XR] Xcode not installed. Aborting runtime list update.`），
用**磁盘上的真实列表**去和路径正则交集，而不是拿正则硬猜。
`__checkIfNeedRemoveXcodeRuntimeSimulator:` 再判断「这个 runtime 有没有被任何 Simulator 设备在用」。

> **这条我们要抄**：我们已经有 `xcode-derived-data` / `xcode-device-support` / `xcode-simulator-caches` 三条，
> 但 **`Archives`、`CoreSimulator/Devices`、`CoreSimulator/Profiles/Runtimes` 都还没有**。
> 而且「用 `xcrun simctl runtime list` 的真实结果去收窄路径展开」正是我们 `expand_relative_path` 该有的思路。

### 3.2 邮件（`__scanMailAttachments:`）

`MailData` / `getMailAttachMentPathArray:actionItem:withDelegate:` / `getMailBoxPathArrayWithPath:`
—— 也就是 `~/Library/Mail/V*/<UUID>/<Mailbox>/Attachments` 这一族，逐邮箱展开。

### 3.3 微信（`QMWechatScan`）

```
~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files
~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/all_users/config/global_config.crc
~/Library/Containers/com.tencent.xinWeChat/Data/Library/Caches/com.tencent.xinWeChat/Cache.db
~/Library/Containers/com.tencent.xinWeChat/Data/Library/HTTPStorages/com.tencent.xinWeChat/httpstorages.sqlite
~/Library/Containers/com.tencent.xinWeChat/Data/Library/Caches/Matrix/AppReboot/AppReboot.dat
~/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/lock/lock.ini
/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files     ← 注意：系统级
```

它还要读微信 **版本号**（`wechat version : %@` / `version format invalide : %@`）来决定清哪些子目录——
这就是 2.1 里 `appversion` 属性在真实规则里的用法。

### 3.4 浏览器（隐私清理，`LemonPrivacyClean`）

按「浏览器 × 数据类型」两维展开，数据类型固定六类：
**浏览历史 / 下载历史 / 本地存储（Cookie）/ 存储的密码 / 自动填充项 / 扩展数据**，
并且**清理前要求退出正在运行的浏览器**（`RunningAppPopViewController`：`%li 款浏览器正在运行中,退出当前的浏览器开始清理`）。

> 这条和我们 `needs_app_closed`（不变式 31）思路一致，但它的做法更粗：**弹窗让用户自己退**。
> 我们的做法（把 `safe` 降成 `review`，仍可操作，pre-flight 再拒一次）体验更好，**不要往回抄**。

### 3.5 阈值（UI 文案里写死的常量）

- **大文件：≥ 50 MB**（`大文件只扫描 50 MB 以上的文件噢`）
- **老文件时间轴**：最近 / 一周前 / 两周前 / 一个月前 / 两个月前 / 三个月前 / 六个月前 / 一年前 / 两年前
- **卸载「不常用」判定**：`7天内使用过` / `一个月内使用过` / `三个月内使用过` / `不常用`

我们 `android-sdk-idle-components` 从 180 天改到 90 天，是靠 `--age-sweep` 量出来的，不是拍脑袋——
这一点我们已经比它严谨，**保持**。

### 3.6 大小口径：`diskMode` 是一等参数

```
caluactionSize:
caluactionSize:diskMode:
caluactionSize:associatedItem:diskMode:
fastFolderSizeAtFSRef:diskMode:
fastFolderSizeAtFSRef:associatedItem:diskMode:
addResultWithPathByDeamonCalculateSize:
```

**它的每个算大小 API 都强制带 `diskMode`**——逻辑大小还是分配大小，调用方必须表态，不存在「默认口径」。
另外 `addResultWithPathByDeamonCalculateSize:` 说明大目录的大小是**在独立 daemon 里算的**，不占主进程。

> 这正是我们不变式 26 那个 Rust bug 的形状（`metadata.len()` vs 分配大小，同一台 Mac 两个核读出的数不一样）。
> 我们靠 `EngineAgreementTests` 抓到了它；它靠**把口径做成必填参数**从源头杜绝。**这一层我们可以学**：
> 把口径做成类型（`SizeBasis`），而不是一个「大家都知道要用 allocated」的默契。

---

### 3.7 判定链路：它到底根据什么来清理

规则库不下发，但软件照样在清（本机 92 次清理记录）。把判定拆开看，它不是一个来源，是六层拼起来的：

| 层 | 在哪 | 例子 | 变不变的 |
|---|---|---|---|
| ① 顶部分类 | 写死在 nib 里 | 「系统垃圾」「应用垃圾」「上网垃圾」 | 随版本 |
| ② 子类注册表 | 写死在 `__cstring` | `1001 1002 1004 1005 1008 / 2101–2103 / 20001–20005 / 20101–20307 / 22222`，加 `garbage` `garbage1` `garbage_appstore` | 随版本 |
| ③ 子类内容 | 云端 XML 知识库 | 路径、`type`、`action`、`level`、`defaultstate` | 热更新（现在空） |
| ④ 路径常量 + 专用扫描器 | 编译进代码 | `QMXcodeScan` / `QMWechatScan` / `QMMailScan` / `QMAppLeftScan` / `QMBrokenRegister` | 随版本 |
| ⑤ 本机实时状态 | 运行时 | 装了哪些 app、微信是不是 4.1.8、有没有完全磁盘访问权限、进程在不在跑、用哪个大小口径 | 每次扫描 |
| ⑥ 用户选择 | `LemonClean.db` | `clean_status` 324 条勾选记忆 | 用户决定 |

证据：

- **①** `LemonClener.framework/Resources/LMClean*ViewController.nib` 是二进制 plist，反序列化后含
  `'系统垃圾' '应用垃圾' '上网垃圾' '系统缓存'`（配文「系统应用产生的缓存，可放心清理」）。
  **单个子类的名字则一个都没有**——它们原本在 XML 里。
- **②** `__cstring` 里这串 id 连续排布在 `0x82de6`–`0x82e86`，紧挨着 `xmlParseDidEndCategory/Filters/Caution`
  这三类回调名，是「扫描掩码 ↔ 子类 id」的对表（`__comparisonTableBetweenScanMaskAndSubCategoryId`）。
- **④** 常量本身就能读出清扫对象：`~/Library/Caches`、`~/Library/Logs/%@/`、
  `~/Library/Containers/%@/Data/Library/Logs/`、`~/Library/LaunchAgents`、`~/Library/PreferencePanes/*%@*`、
  `~/Library/Developer/Xcode/{DerivedData,Archives}`、微信容器 6 条、`/Library/{Extensions,Filesystems,PreferencePanes}/*%@*`。
- **⑤** `dict2`（plist）是按 bundle id 记的应用过滤表，本机 56 条、20 开 36 关；
  日志里 `wechat version : 4.1.8` 说明它在按应用版本决定清哪些子目录；
  `QMFullDiskAccessManager` 决定「上网垃圾」这类要不要走授权引导。
- **⑥** `clean_result` 按 `clean_type` 汇总：类型 1 跑了 48 次、清掉 313 GB；类型 2 跑了 44 次、149 GB。

**所以「柠檬清什么」≈ 版本（①②④，编译期）× 本机状态（⑤）× 用户选择（⑥）。**
云端的 ③ 只是给这些写死的子类**填内容**的那一层。服务器断供，它仍然能清——因为「能清什么」已经在
二进制里了；断掉的是「清得对」：哪些应用的目录、哪些版本的数据格式，只能靠 ③ 追赶。

这一点对我们是个提醒：我们的规则表是编译期单一来源、可审计、生成物与源码强制一致，
但它换来的代价是**新增一条规则要发版**。Lemon 用 ③ 换掉了这个代价，也就把"规则可以随时改、
且没有签名校验"这个风险一起接受了（第 1.1 节：明文 gzip、无签名）。我们不该换。

## 4. 勾选状态持久化（最有价值的一条）

`~/Library/Application Support/com.tencent.LemonMonitor/LemonClean.db`（SQLite，VACUUM 后 28 KB）：

```sql
CREATE TABLE clean_result (
  result_id INTEGER PRIMARY KEY AUTOINCREMENT,
  total_size, sys_size, app_size, int_size  UNSIGNED BIG INT,
  clean_type TINYINT, file_num, oprate_time, createTime );

CREATE table clean_status (
  status_id INTEGER PRIMARY KEY AUTOINCREMENT,
  subcate_id varchar(20) NOT NULL,
  status integer NOT NULL );
```

相关选择器：`addSubcateStatusToDatabaseWithId:selectStatus:`、`getSubcateSelectStatus:`、
`changeSubcate:selectStatus:`、`needTipUserSaveSubcateStatus`、
`lmClean_resetDownloadSelectStatus_key` / `lmClean_resetSketchCacheSelectStatus_key`。

**本机实测数据**（你这台机器上真跑过）：

```
status=1（选中）: 291 条
status=2（取消）:  33 条
clean_result 行数 : 92
```

也就是说：**这个用户永久关掉了 33 个子类，而它记得**。`needTipUserSaveSubcateStatus` 这个标志说明它在
「用户的改动与默认值不一致」时会提示一次（提示用户这个选择被记住了），而不是默默记住。

对照我们：`CleanupItem` 的勾选状态由 `risk` 推导（`safe` 预选、`review` 不选），**每次扫描重算**。
用户上次取消掉的 `user-cache`，下次扫描又回来了。这是真实的体验缺口。

### 落地建议

新增 `SelectionMemory`（`Core/Settings/` 或 `Core/Scanning/`）：

- 键：`rule_id` + 归一化路径前缀（跟不变式 8 的 item 身份同源，**不要**用随机 id）
- 值：`selected` / `deselected`，带 `recordedAt`
- 套用时机：`AppEnvironment.runScan` 组装请求之后、把 item 交给页面之前——**在单一入口里做**（不变式 17）
- 与 `risk` 的关系：`risk` 决定「首次出现的默认值」，记忆只覆盖用户显式改过的
- `protected` 永远不可选，记忆不能碰（不变式 5）
- 首次记忆生效时提示一次（抄 `needTipUserSaveSubcateStatus` 的语义）

测试：`test_aDeselectedRuleStaysDeselectedOnTheNextScan`、`test_memoryCannotSelectAProtectedItem`。

---

## 5. 与 Sift 现规则的逐项对照

我们的表：21 条规则 / 9 个类别（`RustCore/crates/sift-rules/src/lib.rs` → `default_rules()`）。

| 能力 | Lemon | Sift | 结论 |
|---|---|---|---|
| 规则来源 | 云端 XML + 版本目录 + gzip | 编译进 Rust + 生成两份副本 | 我们的更安全，保持 |
| 结构 | 类别 → 子类 → 条目/原子 | 类别 → 规则（平） | 可加「子类」层，见第 8 节 |
| 扫描策略 | `type` 十余种专用扫描器 | `match_spec` 5 种（childDirectories / directoriesNamed / filesByExtension / …） | 我们少的是**专用扫描器**，不是规则表达力 |
| 处置动作 | 12 种（含原地改写/直删） | 只有 Trash 一种 | **故意的**，见第 6 节 |
| 排除器 | `filter`：contains/suffix/regex + and/or | `excludes`：字面量 | 可升，见第 7 节 P1 |
| 默认勾选 | `defaultstate` 写在规则里 | 由 `risk` 推导 | 建议保持推导（少一个自由度） |
| 谨慎分组 | `cautions` 组 + `isCautious` | `Risk::Review` | 可加「谨慎组」的 UI 结构 |
| 版本门控 | `appversion`/`buildversion` | 无（`needs_app_closed` 是运行态，不是版本） | 值得加，见 P2 |
| 排除器逻辑 | and/or 两级 | 无 | P1 |
| 大小口径 | `diskMode` 必填 + daemon 计算 | 已统一 allocated（不变式 26） | 我们已修；可把口径做成类型 |
| 勾选记忆 | `clean_status` 表 | 无 | **P0** |
| 应用归属展示 | `relation`/`bundle`/`appname` | `RelatedFile.MatchReason` + `sharedWith` | 平手 |
| 保护表 | 未见编译进二进制 | `PROTECTED_*` 双端生成 + 三重校验 | **我们明显更强** |
| 破损登录项 | `brokenregister`/`brokenplist` | 无 | **P0（能力）** |
| 空目录 / 隐藏文件 | `cleanemptyfolder` / `cleanhiddenfile` | 只有 `skip_hidden` 偏好 | P2 |
| 运行态降级 | 弹窗要求退出 | 逐条降级 + pre-flight + 执行前重查 | **我们更强** |

---

## 6. 明确**不**借鉴的四条动作

| 动作 | 它做什么 | 为什么不抄 |
|---|---|---|
| `truncate` | 原地把文件截断成 0 字节 | 不可撤销，击穿不变式 1（一切只进废纸篓） |
| `cutbinary` | 裁掉 Mach-O 里的多余架构 | 破坏代码签名与公证，用户下次启动 app 就被 Gatekeeper 拦 |
| `removelanguage` | 删 `.lproj` 语言包 | 同上，且签名一变 `codesign --verify` 直接失败 |
| `deleteBinary` / `deletePackage` / `safaricookie` | 直接 unlink | 不可撤销 |

它的废纸篓路径是单独的 `movetrash` 动作，说明**它自己也把「可撤销」当成需要显式声明的东西**——
只是给了规则作者选择不可撤销的权力。我们的设计是把这个权力拿掉：**规则文件能扩大识别范围，不能扩大删除能力**
（不变式 3）。这个差别不要为了「多清几个 G」而放弃。

---

## 7. 可借鉴清单（按优先级，含落点）

### P0-1 勾选记忆
见第 4 节。落点：`Core/Settings/SelectionMemory.swift`（新）、`AppEnvironment.runScan`、
`Core/Models/CleanupItem.swift` 的默认勾选处。测试两条。

### P0-2 破损登录项扫描器（`brokenregister` 的等价物）
它读 `~/Library/LaunchAgents`、`/Library/LaunchAgents`、`/Library/LaunchDaemons` 下的 plist，
取 `Program` / `ProgramArguments[0]`，**指向的可执行文件不存在**就是一条候选。
`QMCoreFunction` 里有 `Program` / `ProgramArguments` / `WorkingDirectory` / `Error: Program and ProgramArguments does not contain executable Path(%@)`。

我们**完全没有**这个能力，而这是我们用户最容易理解的价值（「这个启动项已经坏了」）。

落点：`RustCore/crates/sift-scanner-core/src/scanners.rs`，紧挨 `scan_application_residue` 新增
`scan_broken_login_items`；它**不是规则**，是策略（跟 residue 一样由代码决定，`Row.isSynthesized == true`，
覆盖页要能显示，见不变式 41）。需要新类别 `Category::BrokenLoginItem`（会波及 `junkCategories`、
Swift 的穷尽 `switch`、本地化 key 与 `Scripts/check-explanation-keys.py`——**按我们的规矩，这是一次真实的
跨端改动，别偷偷塞进 `applicationResidue`**）。

只能读 plist，**不能**执行 `launchctl`（不变式 18：诊断只读，只有 `mdutil` / `tmutil` 两个白名单程序）。

### P1-1 排除器升级成带逻辑的匹配器
```
filter: { op: contains | suffix | prefix | regex, value, logicLevel: and | or }
```
落点：`Rule.excludes: Vec<String>` → `Rule.excludes: Vec<Exclusion>`，Rust `sift-rules` 与
Swift `RuleEngine.decode` **同时**改；`Tests/Fixtures/Rules/accept|reject/` 各加语料（不变式 23 要求这份
两套测试共用的语料库是唯一裁判）。正则要用有限制的引擎（`regex` crate 已经是默认特性，确认没开 backtracking）。

现状 `excludes` 只按名字。`user-cache` 排掉 `CloudKit` 是够的，但「排除所有 `com.apple.*` 开头的」
就只能逐条列——`container-caches` 那条注释里已经承认了这一点。

### P1-2 `Xcode/Archives` + `CoreSimulator/Devices` ✅ 已落地（runtimes 暂缓）

`xcode-archives` 与 `xcode-simulator-devices` 两条已进 `default_rules()`（现在 23 条规则），
`CleaningRules.json` / `BuiltInRules.swift` 已重新生成，两个本地化 key 补了 34 种语言。
细节见第 8 节。

`CoreSimulator/Profiles/Runtimes` **故意没发**：它在 `/Library` 下，属主是 root，
移进废纸篓需要管理员授权，`trashItem` 会失败。发一条注定失败的规则，比不发更糟——
用户会看到「清理了 3 项」和 3 个失败。要做就先用 `xcrun simctl runtime list` 拿真实列表收窄
（它就是这么做的），并把「不可写」在 pre-flight 报成失败，而不是当成成功（不变式 28）。

### P1-3 谨慎组
把「用户数据语义」的规则（邮件附件、微信文件、浏览器数据）收进一个 `Risk::Review` 的子组，
UI 上单独一栏、默认折叠、批量勾选要二次确认。落点：`ScanFilter`（`Features/Scan`）+ 本地化。

### P2-1 版本门控
`Rule` 加 `app_version_range: Option<String>` + `bundle_id`，命中时先读应用的
`CFBundleShortVersionString` 再决定是否出条目。抄它的 `appversion` / `buildversion`。
注意：这会让规则依赖 LaunchServices，和 `AppGroupRegistry` 的读法同源，可以复用它的缓存与指纹机制（不变式 39）。

### P2-2 大小口径做成类型
`SizeBasis::{Logical, Allocated}` 显式进 `FileWalker` / `DiagnosticMeasurement` / FFI 请求，
而不是「默认 allocated」。抄它 `diskMode` 必填的做法。

### P2-3 空目录清理
`cleanemptyfolder`。我们有 `FileWalker` 的目录遍历，加一条「整棵树都是空目录」的判定即可；
但要小心：**空目录是零字节**，清理它对「腾空间」毫无贡献，只对「整洁」有意义。低优先。

---

## 8. 已落地的两条规则

在 `RustCore/crates/sift-rules/src/lib.rs` 的 `default_rules()` 里，紧跟 `xcode-simulator-caches`：

```rust
// Archives/<date>/<name>.xcarchive —— 条目是归档本身，不是装着它的日期目录
rules.push(with_spec(
    rule(
        "xcode-archives",
        TemporaryFiles,
        Review,
        HomeLibrary,
        "Developer/Xcode/Archives/*/*",
        "cleanup.explanation.xcodeArchives",
    ),
    MatchSpec::Directory,
));

rules.push(with_spec(
    rule(
        "xcode-simulator-devices",
        TemporaryFiles,
        Review,
        HomeLibrary,
        "Developer/CoreSimulator/Devices",
        "cleanup.explanation.simulatorDevices",
    ),
    MatchSpec::ChildDirectories,
));
```

三个设计点，都对着我们自己的不变式：

- **`Archives/*/*` 而不是 `Archives` 或 `Archives/*`。** Xcode 的第一层是按日期建的桶
  （`Archives/2026-10-19/`），把整个箱子当一个条目，会把一个上周刚发的版本和三个废弃的一起移走。
  两个通配符都只匹配目录名，由 `expand_relative_path` 从磁盘展开，受 `MAX_RULE_ROOTS` 约束（不变式 36）。
- **`review`，不是 `safe`，也不设 `min_age_days`。** 归档是构建产物但不是缓存：重新归档需要当初的源码
  和签名身份。按名字和年龄匹配的规则分不清「做完的项目」和「还在做的项目」，所以预选勾就交给 `risk`。
- **两条都不写 `explanation_key` 的通用句。** 新加 `cleanup.explanation.xcodeArchives` /
  `simulatorDevices` 两个 key，34 种语言齐全——`Scripts/check-explanation-keys.py` 会拒绝一个不在目录里的
  key，而 `.temporary`（"Scratch files left behind by apps"）用在这里是错的描述。

验证：

```
python3 Scripts/generate-strings.py        # 498 keys, 34 languages
python3 Scripts/generate-rules.py          # 23 rules
python3 Scripts/check-explanation-keys.py  # 15 keys, all shipped, no placeholders
cargo test -p sift-rules                    # 53 passed
cargo test -p sift-scanner-core             # 123 passed
Scripts/run-tests.sh                        # 309 passed, 0 failed
```

### 还没做，以及为什么

- **`CoreSimulator/Profiles/Runtimes`**：在 `/Library` 下、属主 root，`trashItem` 会失败。
  要发必须先改成「用 `xcrun simctl runtime list` 收窄 + pre-flight 报不可写」，否则就是一条
  注定失败的规则。
- **邮件附件**：`~/Library/Mail/V*/<UUID>/<Mailbox>/Attachments` 要三层通配，`MAX_RULE_ROOTS` 会被打满，
  而且移动 `Attachments` 会让 Mail 重新下载并弄乱「已下载」状态。真要做，做成 `__scanMailAttachments:`
  那样的**专用扫描器**，不是一条通配规则。
- **`Application Support/MobileSync/Backup`（iOS 备份）**：`Application Support/*/*` 形状能表达，
  但 `Backup` 这个名字在别的应用下也常见，规则分不清 `MobileSync` 和别人的 `Backup`。
  需要 `MobileSync` 作为锚点显式列出，属于锚点表改动，不是规则改动。

## 9. 附录

### A. 完整属性/动作词表（从 `LemonClener` 字符串表连续区块还原，出现 2 次 = 双架构各一份）

```
结构性: filter  cautions  category  item  atom  path  garbage  version  title  tips  filters  level
属性  : column value bundle appname relation action showaction fastmode appstorebundleid
        defaultstate type sandbox multi language brokenplist brokenregister developer appleft
        binary otherBinary InstallPackage mail soft derivedapp archive appcache leftcache leftlog
        wechatAvatar wechatImage wechatImage90 wechatFile wechatVideo wechatAudio
        cleanemptyfolder cleanhiddenfile caution clean truncate movetrash removelanguage
        cutbinary deleteBinary deletePackage safaricookie apppath appversion buildversion value1
核心类: QMBaseItem QMCategoryItem QMCategorySubItem QMActionItem QMActionPathItem QMActionAtomItem
        QMResultItem QMResultBrowerItem QMWarnReultItem QMFilterItem QMFilterParse QMItemCreateHelper
        QMCleanManager QMRemoveManager QMScanCategory QMScanFileSizeCacheManager QMCleanerUtils
        QMBaseScan QMDirectoryScan QMCacheEnumerator QMAppUnlessFile QMFilterItem QMXMLParse
        QMXMLParseManager QMCleanXMLItemParseEnd QMXcodeScan QMWechatScan QMMailScan
        QMAppLeftScan QMBrokenRegister QMSoftScan QMLiteCleanerManager
```

### B. 卸载器的文件类型标签（`LMFileItem getLMFileTypeName`）

```
程序文件 / 支持文件 / 缓存文件 / 设置文件 / 程序状态文件 / 崩溃日志 / 程序日志 / 沙盒文件
守护进程项 / 登录项 / 内核扩展 / 运行程序 / 文件系统 / 偏好设置面板 / 其他文件
```

比我们 `RelatedFile.MatchReason`（`bundleIdentifier` / `identifierPrefix` / `applicationName` /
`identifierSuffix` / `appGroup`）多一个正交维度：**我们说的是「为什么认为它属于这个 app」，
它说的是「这是什么东西」**。这两个维度不冲突，可以并存——给 `RelatedFile` 加 `kind` 是个便宜的改进。

顺带：它的卸载例外表是 JSON（`uninstallConfigs.json`），按 bundle id 覆写：
```json
{ "version": "1",
  "com.bjango.istatmenus": {
    "UserAgents": ["~/Library/LaunchAgents/com.bjango.istatmenus.status.plist"],
    "Daemons":    ["/Library/LaunchDaemons/com.bjango.istatmenus.daemon.plist", "...fans.plist", "...installerhelper.plist"] } }
```
iStat Menus 的 daemon 名和 bundle id 对不上——正是「名字匹配」的边界。我们做登录项扫描时，
需要一张同样形状的例外表，否则会把正常应用的 helper 当残留。

### C. 本机残留（分析过程中没有修改任何东西）

两个**不同**的目录，各自一份同内容的 `LemonClean.db`（inode 不同，都是 324/92 条）：

```
~/Library/Application Support/com.tencent.Lemon/          LemonClean.db  dict2  trashLog  Owl/  Profile/
~/Library/Application Support/com.tencent.LemonMonitor/   LemonClean.db  dict2  disk.plist  DynamicConfig(文件, 2840 B)
```

`DynamicConfig` 是一个**加密的** 2.8 KB 文件（`file` 报 `data`，无明文结构）。
对应代码里的 `parseGetConfigResponse:aesEncryptKey:` / `CCMCryptor` / `CCMKeyLoader` / `CSSMRSACryptor`：
**远程配置走 AES，规则包走明文 gzip**——这个不一致本身也是个可借鉴的教训（同一条链路上两种保护强度）。
`~/Library/Application Support/*encent*/Knowledge*` 全部不存在 ⇒ 规则库从未在本机下载过。

### D. 证据锚点

| 结论 | 证据 |
|---|---|
| XML 词表 | `LemonClener` 中 `strings` 第 ~4940–5010 行的连续区块 |
| 知识库路径 | 同上，`~/Library/Application Support/com.tencent.lemon/KnowledgeCh/2` |
| 勾选持久化 | `LemonClean.db` 的 `clean_status` 表，`addSubcateStatusToDatabaseWithId:selectStatus:` |
| 大文件 50 MB | `LemonBigOldFile` 的 `zh-Hans.lproj/Localizable.strings` |
| 时间轴 | `QMLargeOldManager_init_1553075107_{1..9}` |
| Xcode 真实 runtime | `__updateXcodeRuntimeListInfo` / `[XR] Xcode not installed. Aborting runtime list update.` / `/usr/bin/xcrun` |
| diskMode | `caluactionSize:diskMode:` / `fastFolderSizeAtFSRef:diskMode:` |
| 卸载类型标签 | `LMFileItem_getLMFileTypeName_1553153166_{1..15,99}` |
