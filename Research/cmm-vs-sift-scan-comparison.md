# CleanMyMac 5.7.3 与 Sift 在同一台机器上的扫描对账

记录时间 2026-11-01 18:31–18:33（Asia/Shanghai）。左侧窗口是 CleanMyMac 5（解锁版），
右侧窗口是本地开发中的 Sift（`/Users/sunqiqi/sift/.build/Sift.app`，pid 26785）。

数据来源：

* CleanMyMac：`~/Library/Group Containers/S8EX82NJP6.com.macpaw.CleanMyMac5/Library/Logs/CleanMyMac_5/…-07-23-09-156.log`
  （18:31:35 起的那一轮，24 个扫描任务，末行 `flow main changed state to review(result: failure)`）
  以及截图里模块级读数。
* Sift：`~/Library/Application Support/Sift/Index/1A0AFF2F-…sqlite`（该轮唯一的 session），
  以及截图里的页面读数。统一日志（`subsystem == "com.siftmac.cleaner"`）这轮只有两行：
  `Using the Rust scanner core` 和 `Scan started (engine=rust roots=3)`，之后没有任何收尾行。

## 一、同一批缓存，两个引擎逐项一致

两个引擎都在枚举 `~/Library/Caches` 的直接子目录，读数到字节都相同：

| 目录 | CleanMyMac | Sift | 文件数 |
| --- | --- | --- | --- |
| `~/Library/Caches/Google` | 2.17 GB | 2168.8 MB | 36788（两边相同） |
| `~/Library/Caches/Trae CN` | 1.2 GB | 1198.3 MB | 3 |
| `~/Library/Caches/Doubao` | 1.12 GB | 1116.0 MB | 16383（两边相同） |
| `~/Library/Caches/routercode-desktop-updater` | 992.5 MB | 992.5 MB | 3 |
| 安全可清理合计 | — | 8.05 GB | — |

`du -sk` 复核：`Google` 2118456 KB、`Trae CN` 1170204 KB、`Doubao` 1089876 KB、
`routercode-desktop-updater` 969220 KB，与两边显示一致（CMM 用十进制 GB 显示）。

## 二、汇总口径

| | CleanMyMac | Sift |
| --- | --- | --- |
| 垃圾模块 | 19.3 GB（系统垃圾 10.3 + AI 杂乱 504 MB + 额外二进制 3.8 GB + Xcode 3.7 MB） | 垃圾 11.18 GB |
| 大文件 | 独立模块，本次页面未展开 | 8.55 GB / 4 项 |
| 旧文件 | 独立模块 | 1.20 GB / 36 项 |
| 重复 | 独立模块 | 1.42 MB / 136 组 |
| 合计 | 19.3 GB | 20.93 GB / 9113 项 / 114786 个文件 |
| 默认勾选 | 默认全选（“清理”一键） | 8.06 GB / 87 行（`safe`），其余 9026 行全部 `review` |

Sift 的垃圾 11.18 GB = `applicationCache` 9.37 + `applicationResidue` 1.34 +
`temporaryFiles` 0.43 + `groupContainerResidue` 0.04。CMM 的系统垃圾 10.3 GB 与其中的
缓存 + 临时项基本重合；CMM 多出的部分是 sift 按设计不做的类别（见下）。

## 三、差异清单

CleanMyMac 有、Sift 没有（按日志里真实跑过的扫描器）：

* `CMSystemJunkScanIdentifierUniversalBinaries` — 3.8 GB。剥离通用二进制里用不到的那一
  半架构。**Sift 不能做**：它改写可执行文件本体，而 invariant 1 规定一切清理都走废纸篓。
* `CMSystemJunkScanIdentifierApplicationLanguages` — 删除 `.lproj` 语言包，同样是对已装
  应用的就地改写。
* `CMSystemJunkScanIdentifierBrokenPreferences` / `BrokenStartupItems` / `DocumentVersions` /
  `DocumentationCache` / `Backups` / `DeletedUsers` / `CMMailModuleScanIdentifierMail`。
  Sift 只有 `user-diagnostic-reports` 一项沾边，邮件与备份没有对应规则。
* `CMSystemJunkScanIdentifierSystemCachesCompound` — `/Library/Caches`、`/System/Library/Caches`。
  Sift 的 `system-logs` 只锚在 `/Library/Logs`，系统缓存需要 root，按设计不做。
* `CMTrashBinScanIdentifierTrashes` — 废纸篓。Sift 有 `TrashService`，但它是独立操作
  （invariant 33），不进扫描结果。
* `LocalModelsScanTask`（AI 本地模型）与 `AgentFootprintScanTask`（其它清理器的残留）。

Sift 有、CleanMyMac 这一屏没有：`~/Library/Containers/*/Data/Library/Caches`（53 项）、
Chromium 系 profile 缓存（32 项）、`app-support-caches`（37 项）、`~/.cache` 与各种开发
工具缓存、`~/Library/Group Containers` 的独立分类。

## 四、这一轮扫描暴露出的四个 Sift 侧问题

### 1. 扫描结果的 83% 是仓库自己的测试产物

`~/Library/Preferences` 里 8108 个“应用残留”，其中 **7552 个是 `sift.tests.*.plist`**、
237 个 `sift.selftes*`，合计 30.9 MB（整个 Preferences 目录 59 MB）。它们由
`Tests/EntitlementTests.swift:26` 等处用 `"sift.tests.entitlement.\(UUID().uuidString)"`
建的 UserDefaults suite 留下，teardown 从不删除。后果：9113 行里有 7789 行是自家垃圾，
扫描页、覆盖页、残留计数全部被自己污染。修法是在 teardown 里
`UserDefaults().removePersistentDomain(forName: suiteName)`，另加一次清库脚本。

### 2. `com.tencent.workbuddy.mac.BundleMigration` 688.9 MB 被判为残留

`WorkBuddy.app` 就在 `/Applications`，bundle id 是 `com.tencent.workbuddy.mac`。
`scan_application_residue` 用全名相等比较已安装 id（`installed.iter().any(|id| *id == name)`），
`com.tencent.workbuddy.mac.BundleMigration` 不等于它，于是整目录进了残留。这是同一台机器上
最大的一条误报，也是 `~/Library/Caches` 下 45 条残留（788.6 MB）里的 87%。
应照 invariant 38 对 group container 的做法，把“安装 id + `.` 前缀”也算命中。

### 3. 569 个 `com.apple.*` 容器（352.4 MB）与 285 个 `com.apple.*` 偏好（2.1 MB）被判为残留

系统守护进程从来没有“被卸载”，它们的名字永远匹配不到应用包。`Scripts/audit-coverage.py`
的说明里已经把这一点写成“残留是上限”，但产品里应当直接排除 `com.apple.` 前缀，
否则 `mediaanalysisd` 93.8 MB、`geod` 49.4 MB 这类行会一直出现在“需要你确认”里。

### 4. `~/Library/Caches` 有 27 个条目没有出现在索引里（对得上账，但值得记录）

磁盘 128 项，索引 101 项（`user-cache` 56 / `app-residue` 45）。差额正好等于：
4 个空目录 + 1 个同名普通文件 + `skipped` 表里的 22 条（`protectedLocation` 15、
`permissionDenied` 7）。空目录不产生候选是对的；`skipped` 表已经记了原因，但它没有
任何界面出口——CMM 至少会在日志里打 `Permission denied`。

另外：页面上“可安全清理 38 个项目”与引擎的 87 行 `safe` 行数不同（体积两边都是
8.05 / 8.06 GB），说明列表按某个键做了合并显示，而计数和体积用了不同口径。同一面板里
组数与行数混用，值得统一。

## 五、无规则覆盖的位置（按体积，来自 `Scripts/audit-coverage.py`）

23 条规则共命中 342 个目标、12.3 GB；以下目录一条规则都没有：

| 位置 | 体积 | 性质 |
| --- | --- | --- |
| `~/Library/Huawei` | 4.4 GB | 鸿蒙 SDK 系统镜像 |
| `~/.codex` | 3.4 GB | `packages/` 2582 MB、`plugins/` 357 MB |
| `~/.workbuddy` | 3.5 GB | `binaries/` 751 MB、`blobs/` 747 MB、`plugins/` 476 MB |
| `~/.zcode` | 3.1 GB | `cli/` 2954 MB |
| `~/.hermes` | 1.8 GB | `hermes-agent/` 1576 MB |
| `~/.rustup` | 1.8 GB | 多套 toolchain |
| `~/Library/Python` | 1.5 GB | 3.9 site-packages |
| `~/Library/OpenHarmony` | 1.2 GB | SDK |
| `~/Library/pnpm` | 904 MB | store |
| `~/.antigravity` / `~/.qoder` | 703 / 562 MB | 编辑器数据 |

合计约 21 GB。CMM 的“AI 杂乱文件”在这一屏只报了 504 MB，说明它也没吃到这些目录；
两边都存在同一个缺口，而这里的量级是 CMM 那一类的 40 倍。

## 六、建议顺序

1. 修 `sift.tests.*` 泄漏（改测试 teardown）。它让每一次开发机扫描的结果都不可读。
2. 残留匹配接受“安装 id + `.`”前缀，消掉 688.9 MB 误报（invariant 38 的同一读法）。
3. 排除 `com.apple.` 前缀的残留（624 条、354 MB 噪声）。
4. 给 `~/.codex`、`~/.workbuddy`、`~/.zcode`、`~/.hermes` 这类 CLI 数据目录定
   `directoriesNamed` 规则（`packages`/`blobs`/`cli` 这种具名层），risk 定 `review`，
   并让 `needsAppClosed` 生效；先跑 `--age-sweep` 选阈值再落表。
5. 给扫描收尾加一行可审计日志（项数、字节区间、耗时、跳过原因计数）。CMM 的日志之所以
   能拿来做这次对账，就是因为它每个扫描器都打了 Started/Ended + Duration；Sift 现在
   只有开头两行。
