# 安全审查与逐项修复（2026-11）

只读审查覆盖 `RustCore/crates/*`（5 crate）、`Core/`（bridge、文件操作、权限、规则、诊断）与
`Scripts/`。审查结论：**无 Critical；5 High、20 Medium、10 Low，共 35 条**（其中 1 条是明确接受的残余风险，1 条只做文档化）。
本篇既是可直接导入 issue tracker 的清单，也是逐项修复的记录：每条的「状态」列写的是**实际
改完的样子**，不是计划。

约定：
- 严重级别取自"若在发布版触发，用户会损失什么"，不是利用难度。
- 位置写的是**修复前**的行号；修复后以文件为准。
- 生成文件（`Core/Rules/ProtectedPaths.swift`、`BuiltInRules.swift`、
  `Core/Resources/CleaningRules.json`）一律由 `Scripts/generate-*.py` 重新产出，不手改。

## 清单

| 编号 | 级别 | 区域 | 位置（修复前） | 症状 | 修复 |
|---|---|---|---|---|---|
| H1 | High | Swift 文件操作 | `FileOperationService.swift:589-590 → 621` | 身份快照/重定位校验之后隔两次 main-actor `await` 才 `trashItem`，窗口内换祖先符号链接可移走未判定对象 | 两次 `await` 前移；校验与移动之间零挂起点；`refusalForARelocatedPath` 对 `lstat` 失败即拒绝 |
| H2 | High | Rust 遍历 | `walker.rs:54,431`；`scanners.rs:1928-1956` | `max_entries` 生产路径从不设置，整树 materialize（每文件 4 个 String）；去重阶段全量持有路径 | 给 `WalkOptions` 设结果集/跳过记录预算，超限置 `truncated`；去重阶段不再保留全量路径 |
| H3 | High | FFI 信任边界 | `sift-ffi/src/lib.rs:997-1077` | 存储分析入口没有根目录/家目录 allowlist 门，伪造 `homeDir` 令 home 相对保护失效 | `sift-ffi` 内新增 `validate_scope`，扫描与存储两个入口共用 |
| H4 | High | 拆除/取消 | `RustScannerEngine.swift:219-228,631-636`；`coordinator.rs:400-413,423-433` | worker detach、无 join；`cancel()` 不持锁却 unlink 活着的 sqlite/-wal/-shm | `cancel()` 持锁；`deinit` 先取消再释放；Rust 侧删索引前等索引锁、`Engine::drop` 取消会话 |
| H5 | High | 保护范围 | `sift-rules/src/lib.rs:636-651` | `PROTECTED_PREFIXES` 无 `/Applications`，`/Library` 仅 5 个子树 | 补前缀表并重新生成 Swift 半；`/Applications` 下任何 `.app` 一律 protected |
| M1 | Medium | Swift 事件泵 | `ScanModel.swift:482` | 排空循环只以"无事件"退出；队列毒化时每次新造 `Failed` → 永不收敛 | 加次数上限；见到 `failed` 即视为终态 |
| M2 | Medium | 权限/付费门 | `AppEnvironment.swift:1202-1203` | 唯一不可撤销删除 `emptyTrash` 不 claim destructive slot、不过 entitlement 门 | 与 `confirmCleanup`/`performUninstall` 同一道门 |
| M3 | Medium | 废纸篓 | `TrashService.swift:107-112` | 无 FDA 时列举失败被报成"废纸篓为空" | 区分 `.empty` 与 `.unreadable`，后者进引导 |
| M4 | Medium | 计划封装 | `OperationModels.swift:232,308,370` | `ApprovedPlan`/`PreflightReport`/`FileIdentitySnapshot` 初始化 public，可自造计划跳过 preflight | 初始化收紧为 internal；`execute` 内重算 risk |
| M5 | Medium | 整数转换 | `RustScannerEngine.swift:688-690`；`SettingsStore.swift:238-242` | `UInt32(max(x,0))` 是 trapping 转换，`defaults write` 2³² 即崩溃 | `UInt32(clamping:)`；设置值 clamp |
| M6 | Medium | 泄漏 | `RustScannerEngine.swift:108,121` | `sift_engine_new()` 后 encode 抛错，两条释放路径都到不了 | 用作用域持有者接管引擎指针 |
| M7 | Medium | unsafe 签名 | `sift-ffi/src/lib.rs:85` | `as_str<'a>(&SiftString) -> Option<&'a str>` 生命周期未绑定入参 | 绑定为 `&'a SiftString` |
| M8 | Medium | 输入上界 | `coordinator.rs:527`；`types.rs:160` | `event_batch_items`/`max_full_hashes`/页大小无上限，直入 `Vec` 容量 | 反序列化时 clamp |
| M9 | Medium | 归一化 | `scanners.rs:488-500` | `root_is_authorised` 用未归一化路径比较，拼写差异让规则静默失效 | 两侧 `collapse_path` 后比较 |
| M10 | Medium | 两引擎语义 | `lib.rs:1803-1813` vs `RuleEngine.swift:529-547` | 同一路径给出不同 `ProtectedReason` | Swift 顺序对齐 Rust（硬前缀最先、回收站其次） |
| M11 | Medium | 运行姿态 | `Config/Sift.entitlements` | 不沙盒 + 可选 FDA + 无 helper：任何内存安全缺陷等于用户级全盘读写 | 接受的风险，写入 `RELEASE.md` 威胁模型；见下文"残余风险" |
| M12 | Medium | ABI 语义 | `sift-ffi/src/lib.rs:333` | 导出的分类器不应用 grants，与引擎实际判定不一致 | 新增 `sift_path_protection_authorized`（附加式，不动版本）；旧函数注释写明不含授权 |
| M13 | Medium | 主线程 | `RustScannerEngine.swift:230-241` | 同步 witness 让 C 轮询与解码跑在 MainActor | witness 真 `async`，在 detached 执行器上跑 |
| M14 | Low→Medium | 大小写 | `FileOperationService.swift:317-324` vs `RuleEngine.swift:1466` | 吸收判定区分大小写、保护判定折叠，同目录两种拼写排队两次 | 吸收判定改用折叠比较 |
| M15 | Low→Medium | 祖先符号链接 | `ReportService.swift:123`、`SettingsStore.swift:208`、`RustScannerEngine.swift:72` | `removeItem` 跟随祖先链接，App Support 被换链会递归删目标树 | 统一走 `removeOwnedItem`：父目录 device/inode 未变且自身非链接才删 |
| M16 | Medium | 两引擎不一致 | `SwiftScannerEngine.swift:205-208` | Swift 不复核规则根的保护状态，会真实列举 `~/Documents` 并把全路径写进 skip | 与容器过滤并列加保护检查 |
| M17 | Medium | 防线缺失 | `scanners.rs:264-315` | 展开结果无包含性复核；带复核的 `resolve_root`/`join_inside` 生产路径零调用者（死代码） | 展开末尾 `retain(is_prefix_of)`；`enforce_rule_invariants` 补判据 |
| M18 | Medium | 完整性判据 | `types.rs:105-131`；`scanners.rs:1401,1560` | 只有 app group 有"集合完整"闸门；私有余量部分失败时把已安装应用的数据报成残留 | 新增 `installed_bundle_ids_complete`，`false` 时五个残留位置整体空 |
| M19 | Medium | "/" 语义 | `lib.rs:1711-1717` vs `RuleEngine.swift:1466-1472` | `is_prefix_of("/")` Rust `false` / Swift `true`，而 `/` 不在保护表 | `is_prefix_of` 空 prefix 返回 `true`；`protection_reason` 显式处理 `path == "/"` |
| M20 | Medium | 校验/使用分叉 | `coordinator.rs:329-351` | 网关只校验折叠视图，遍历用原始字符串；`Caches/x/../y`（x 为链接）可越界 | 网关通过后把折叠结果写回请求 |
| L1 | Low | panic 路径 | `sift-ffi/src/lib.rs:1001-1145` | 多个 `into_raw` 之间 panic 会泄漏已交出的数组 | 先全部构造再一次性交出；panic 时回收 |
| L2 | Low | 事件队列 | `coordinator.rs:713-733` | 超限丢 `ItemBatch`，与索引/计数不一致 | 合并到最后一个批次而不是丢弃 |
| L3 | Low | API 卫生 | `sift-ffi/src/lib.rs:1229,1240` | 解引用调用方内存的函数未标 `unsafe` | 补 `unsafe extern "C"` |
| L4 | Low | 文档不符 | `CancellationFlag.swift:8-9` | 注释称"原子"，实为 `NSLock` | 改用讨论过的一次性标记实现并校正注释 |
| L5 | Low | 复杂度 | `SwiftScannerEngine.swift:126-146` | `removeFirst()` + `dropFirst().contains` 对队列是 O(n²) | 用索引一次扫过 |
| L6 | Low | 注释错误 | `FileOperationService.swift:150` | 注释写 deepest-first，代码浅层优先 | 校正注释并按依赖排序 |
| L7 | Low | 折叠算法 | `lib.rs:1779` vs `RuleEngine.swift:789-791` | 回收站名 Rust ASCII 折叠、Swift Unicode 折叠（`.Traſh` 判定不同） | Rust 改 Unicode 折叠，加共享夹具 |
| L8 | Low | 截断语义 | `scanners.rs:291-297` vs `RuleEngine.swift:1064-1073` | `MAX_RULE_ROOTS` 两侧越界行为不同，注释与实现不符 | 两侧都 `prefix(MAX)` 精确截断 |
| L9 | Low | 字符集 | `RuleEngine.swift:871-879` | bundle id 匹配 Swift 用 Unicode 字母表、Rust 用 ASCII | Swift 收敛到 ASCII |
| L10 | Low | 纯词法归一 | `lib.rs:1636-1649`、`RuleEngine.swift:1425-1441` | 不做 `realpath`：NFC/NFD、硬链接、绑定挂载/firmlink、"符号链接组件之后的 `..`"均未覆盖 | 明确接受的残余风险（见下），由两个 walker 跳过符号链接、身份快照与"只进 Trash"兜底；M20 关掉了 ABI 入口那条 |

## 残余风险（明确接受，不修）

1. **无 App Sandbox（M11）**。直售版要读用户没在面板里点过的缓存与日志，第一版也不带 root
   helper。含义要写清：Rust `unsafe` 边界、规则文件、磁盘文件名——任何一处内存安全缺陷都等价
   于"用户级全盘读写"。对策是收紧 `unsafe` 面（只剩 `sift-ffi`）、给请求加尺寸上限、
   CI 上为 `sift-ffi` 常开 ASan。
2. **纯词法归一（L10）**。不做 `realpath`：NFC/NFD、硬链接、绑定挂载、以及"符号链接组件之后
   的 `..`"都不覆盖。兜底是三件事——两个 walker 整条跳过符号链接、执行前有 device/inode
   身份快照、删除只进 Trash。M20 修完后，ABI 入口那条越界路径也关掉了。
3. **`trashItem` 自身跟随祖先链接**。这是被调用 API 的语义，不是本项目代码：校验与移动之间
   理论窗口仍在。结构性解法是在 Rust 侧用 `openat(O_NOFOLLOW)` + `fstatat` + `renameat`
   按 dirfd 移动（记在 issue #H1 的"后续"里）。

## 落地记录（同一轮修复）

全部 29 条已改。分四个互不重叠的写入范围并行完成，再统一集成：

| 范围 | 条目 |
|---|---|
| `sift-scanner-core` | H2 H4 M8 M9 M17 M18(字段) M20 L2 L8 |
| `sift-rules` + `sift-ffi` + 生成的 Swift 半 | H3 H5 M7 M10 M12 M19 L1 L3 L7 |
| Swift 文件操作与页面 | H1 M1 M2 M3 M4(安全半边) M14 M15 L6 |
| Swift 桥与扫描器 | H4(Swift 半边) M5 M6 M13 M16 M18(Swift 半边) L4 L5 |

### 修复过程中暴露出的三个连带问题（已一并修好）

1. **卸载器被 H5 打断**。`/Applications` 进保护表后，`FileOperationService.preflight`
   是清理与卸载共用的那道门，于是每个卸载都会以 `protectedLocation` 被拒。修法是一条
   **按流程、按理由**的豁免（`permitsApplicationMove`）：只有 `intent == .uninstall` 时、
   且只对 `systemPath("/Applications")` 这一条理由，才放行；用户内容、钥匙串、回收站、
   照片库和其余系统前缀对两个流程一律拒绝。`execute` 用 `plan.operation` 走同一判定。
   测试：`test_onlyAnUninstallMayLookPastTheApplicationsPrefix`、
   `test_aRealApplicationBundleIsPreflightableForAnUninstallOnly`（用本机真实的
   `/Applications/*.app` 走一遍完整 preflight，dry run 不移动任何东西）。
2. **空 ignore 路径会"跳过整个磁盘"**。`is_prefix_of("/")` 按 M19 改成匹配一切之后，
   `normalize_path("")` 得到的 `/` 就把一次扫描变成什么都不扫。修法是在
   `walker::normalize_skip_paths` 与 `storage` 的 ignore 构造处丢掉空项；
   `sift-ffi` 也在 ABI 边界丢掉空 `ignorePaths`。测试：
   `an_empty_ignored_path_does_not_skip_the_whole_walk`。
3. **卸载器的应用列表不受影响**（核对而非修复）：`ApplicationDiscovery` 只在
   **关联文件**上查保护表（`Core/Indexing/ApplicationDiscovery.swift:234`），应用本体
   不加过滤，`isSystemLocation` 另有判据。所以 H5 不会让"选择要卸载的应用"变空。

### 两处有意保留的半边（写在这里而不是留在代码注释里）

1. **M4 只关了安全的那一半**。`FileIdentitySnapshot.init` 已收紧为 `internal`；
   `PreflightReport.init` 与 `makeApprovedPlan` 仍是 `public`，因为
   `SelfTest/SiftSelfTest.swift` 会用它们伪造一个报告来证明"执行期还会再查一次保护表"，
   而那个 target 不能用 `@testable import`。补偿控制是 `execute` 现在会重算
   `rules.risk(for:)` 并拒绝 `.protected`，其余七道检查（保护表、排除位置、容器、
   重定位、身份快照、在用判定、dry-run 分支）一道没少 —— 也就是说公开的接缝已经
   无法产生一次不安全的移动，只能跳过 `skipped`/`subsumed` 的记账。
   若要彻底收紧：给 `SiftSelfTest` 开 `-enable-testing` 并把两处改 `internal`，
   或把那条自检搬进 XCTest 再删掉自检里的伪造。
2. **`resolve_root`/`join_inside` 仍是第二道线而不是唯一一道**。M17 把包含性复核接回了
   生产路径（`expand_relative_path` 末尾的 `retain`），这两个带复核的辅助函数继续只被
   测试调用，作为"表在代码里拼装时"的说明性防线。

### 一处已知的测量缺口（不改，登记）

`storage::measure_bundle` 继承 walker 的默认 500k 条目预算，而那条路径没有
`truncated` 通道：一个文件数超过预算的 bundle 会报一个偏小的体积。它只影响诊断页
显示的数字，不产生清理候选，也不参与删除判定 —— 记在这里，避免下次被当作新发现。

### 验证

`Scripts/verify.sh --quick` 全绿：

```
Rust 286 · Swift XCTest 333 · self-test 265 · Xcode unit target 321 · XCUITest 8 (ran, 8 executed)
VERDICT: every check passed
```

生成产物一致性（`generate-strings` / `generate-protection` / `generate-rules` 的
`--check`）与 `check-explanation-keys.py` 均通过；`cargo fmt --check` 与
`cargo clippy --all-targets -D warnings` 干净。

## 2026-11-04 复核：外部审查清单的逐条判定

一份外部审查（P0/P1/P2 共 10 条，含一条"正式上线阻塞"清单）逐条对回源码。结论先说：
**7 条成立，2 条在本文里已经是"已修/已接受"，1 条是旧版本的结论**。其中 CI 那一条比报告
写的更重——不是"没写"，而是 `RELEASE.md` 与本文都已承诺、`ci.yml` 里都没有。本轮补上三处，
另有两处只能登记（需要证书、服务端或人工），下面写清依赖，避免下次当新发现再报一遍。

| 外部结论 | 对回源码 | 处置 |
|---|---|---|
| P0 Developer ID 签名与公证缺失 | 成立：`RELEASE.md` 自述 ad-hoc，`project.yml:41` `CODE_SIGN_IDENTITY: "-"`；`ENABLE_HARDENED_RUNTIME: YES` 早已在（`project.yml:66`） | 本仓库闭不了（证书 + Apple ID + 干净 Mac）。顺带更正了一处文档假话，见下 |
| P0 授权验证没接通 | 成立，且是**有意**就这样：`Core/App/AppEnvironment.swift:88` 只认 DEBUG 键 `SIFT-DEV-K7QM-3XPD-8R2V`，其余一律 `licenseServiceUnavailable`；`EntitlementService.activate:404`、`purchase()` 同样 | 需要服务端签发与校验，本仓库闭不了；免费版不执行清理由 invariant 6 兜底 |
| P1 CI 没有 `cargo audit`、没有 ASan | 成立，且比报告更重：`RELEASE.md:110`（HEAD）与本文残余风险 1 都写了"CI 常开 ASan、audit 失败即红"，`.github/workflows/ci.yml` 里两个都没有 | **本轮补上**：`Scripts/security-audit.sh` + `rust` job 两个步骤 |
| P1 `/Applications` 卸载豁免过宽 | 成立：`permitsApplicationMove` 只看 reason 与 intent，任何 `/Applications` 子路径在 uninstall 下都被放行 | **本轮补上**：`ApplicationBundleGuard` + 两处调用点 + 3 条测试 |
| P1 `trashItem` 祖先链接 TOCTOU | 部分不成立：H1 已把两次 `await` 前移、校验与移动之间零挂起点，identity snapshot 与重定位校验都在；残余的"被调用 API 自身跟随祖先链接"已登记为残余风险 3 | 不动作，与本文一致 |
| P2 对比度不达标（主按钮 3.17、链接 2.54、Review 徽标 3.56） | 部分不成立：`SiftTheme.swift` 早已把 fill/text 两个角色拆开并达标（`accentText` 4.53、`accentFill`+`onAccent` 4.54、`reviewText` 4.51、`safeText` 4.56、`subtleText` 6.13、暗色 `onAccent` 7.04）；真正不达标的是**15 处调用点仍拿 fill 色画文字/字形**，外加 4 个组件把 `tint: Color` 直接当 label 用 | **本轮补上**：调用点改正 + 组件按角色收口 + `DesignSystemRoleTests` 防回退 |
| P2 大文件职责集中 | 成立 | 报告自己也说别现在做；不动 |
| P2 34 种语言的真机布局未验 | 成立 | 未动作，需要人工跑 RTL 与长文本 |
| P1 真实 macOS 环境回归 | 部分：`Scripts/verify.sh` 的 XCUITest 8 条是真跑（本次 8 executed），但"下载后首次启动、升级"确实没有 | 随签发一并做，属 P0 的验收条件 |
| P2 性能回归阈值未自动化 | 成立：CI 只有 benchmark 冒烟，没有阈值比较 | 未动作，登记 |

### 本轮补上的三处

**一、卸载豁免从"前缀"收紧到"bundle"**（对应上表第 4 条）

`Core/FileOperations/ApplicationBundleGuard.swift` 是新的判定层，`permitsApplicationMove`
在 `/Applications` 分支里改成返回 `ApplicationBundleGuard.isUninstallable(url)`：后缀必须是
`.app`、父目录必须**正好**是 `/Applications`、`lstat` 必须是一个真实目录（符号链接与普通文件
都拒）、`Contents/Info.plist` 必须能解析出 bundle identifier、`com.apple.` 前缀一律拒。拒绝原因
按 `notAnApplicationBundle → notDirectlyInApplications → notADirectory → missingBundleIdentifier
→ systemApplication` 的顺序取第一个，preflight 与执行两处都把它写进日志（`guard=<reason>`），
失败时用户看到的是原因而不是"受保护"。`Info.plist` 用 `PropertyListSerialization` 读，
不用 `Bundle(url:)`——后者会把一个坏 bundle 变成"看起来有 identifier"。

关键是这个改动**让 reason 变成必要条件而不是充分条件**：以前"用户要卸载"就够了，现在还必须
是"用户点的那一个 bundle"。测试在 `Tests/ApplicationBundleGuardTests.swift`（17 条）与
`Tests/SecurityFixFileOperationsTests.swift`（放行=guard 的结论、其他前缀仍拒、
`/Applications/X.app/Contents` 与 `/Applications/vendor/` 与不存在的 bundle 都保持受保护）。

**二、CI 的两个安全检查，以及"flag 静默失效"的自检**（对应第 3 条）

`Scripts/security-audit.sh`（`audit` / `sanitize` / `--offline`），`rust` job 增加
`Dependency audit`、`FFI tests under AddressSanitizer` 两步。测量出来两件事，都影响正确性：

- `-C link-arg=-fsanitize=address` 在**这条工具链上是空操作**：`otool -L` 里没有
  `libclang_rt.asan_*`，测试照样绿。而且 `RustCore/.cargo/config.toml` 的
  `target.<triple>.rustflags` 优先于 `RUSTFLAGS`，环境变量根本到不了 rustc。
- 可用配方是 `RUSTC_BOOTSTRAP=1` + `-Zsanitizer=address`，经
  `--config target.<host>.rustflags=[...]` 传入，并且必须显式 `--target <host>`，否则 cargo
  连 proc macro 一起插桩，rustc 直接以 `Interceptors are not working ... loaded too late` 退出。

因此脚本在构建后**重读 `otool -L`，没有任何测试二进制链上 ASan 运行时就算失败**——一个静默
失效的开关，比没有开关更危险，因为它给的是绿的。两条失败路径都实测过：缺 `cargo-audit` 且
`--offline`、以及旧的 link-arg 构建，都以 exit 1 结束。构建目录是 `RustCore/target/asan`
（`gitignore` 已覆盖），不会污染 `Bridge/macos-universal/libsift_ffi.a`。

**三、对比度按"角色"而不是"色值"修**（对应第 6 条）

token 本身没问题，问题在用法：`SiftColor.accent`（2.54:1）是**填充色**，被当成文字色用了。
本轮改了 15 处文字/字形调用点（rail 标签、eyebrow、诊断状态说明、picker 行等），并把三个
组件的参数形状改了——`SiftMetricPill` 的 `tint: Color` → `tone: Tone`（`fill` 与 `glyph` 分开）、
`NoticeBanner.Level` 的 `tint` 拆成 `fill`/`glyph`、`TierCard` 的 `tint` → `glyph`，
`SiftCheckbox` 的勾改成 `accentFill` + `onAccent`（暗色下原本 2.54:1，因为 `accentDeep` 在暗色
就是 `#00AEEC`）。

剩下的填充/描边/渐变/控件 tint 一律不动，并在两处插画字形上写 `// fill-role: <理由>` 显式
豁免。`Tests/DesignSystemRoleTests.swift` 扫 `App/`、`Features/` 下所有 `.foregroundStyle(...)`
（括号配平，所以 `accentText` 不会被当成 `accent`），没有豁免标记就用 fill 色写文字即失败；
第二条测试要求每条豁免都贴着真正的 fill token 且理由非空，防止它退化成一张空白通行证。
注入一处违规验证过能被抓到并报出行号。

### 报告判重的两处（本文已有记录，仍然成立）

1. **`trashItem` 自身的语义**（残余风险 3）。校验与移动之间的理论窗口是 API 的语义，不是本
   项目漏掉的检查；结构性解法是 `openat(O_NOFOLLOW)` + `fstatat` + `renameat` 按 dirfd 移动，
   但 `trashItem` 的"放回原处"元数据是产品承诺的一部分，换成裸 `renameat` 就要自己写回收站
   元数据，属于产品决策而不是补丁。维持既有决定：接受并记录。
2. **超大 bundle 的 500k 条目预算**（上面的"一处已知的测量缺口"）。报告把它当新发现提出，
   数字对得上：只影响诊断页的体积，不产生候选、不参与删除。

### 本仓库内闭不了的三项

1. **Developer ID 签名与公证**：需要证书、Apple ID、一台没有本仓库任何衍生数据的 Mac。
   命令级步骤在 `RELEASE.md`（`notarytool submit --wait`、`stapler staple`、`spctl -a -vvv`）。
2. **授权服务**：需要服务端签发凭证、客户端 Keychain 存取、到期与恢复购买；客户端骨架
   （`EntitlementService`、14 天离线宽限、每次门禁重算过期）已在，缺的是对端。
3. **ASan 的首次 CI 跑**：本地绿（18 条 `sift-ffi` 测试），但本机没有 GitHub Actions，
   `ci.yml` 的这一步尚未在真实 runner 上跑过；第一次会现编 `cargo-audit`（约 3 分钟，无缓存）。

### 一处文档更正

`Config/Sift.entitlements` 的注释原文写"the app is notarised"，而 `RELEASE.md` 自述当前构建是
ad-hoc 签名——同一棵树里两句话互相矛盾。已改成：hardened runtime 每个配置都开
（`ENABLE_HARDENED_RUNTIME: YES`），Developer ID 签名与公证是发布步骤，checkout 直出的构建是
ad-hoc 且未公证。

### 验证（2026-11-04）

`Scripts/verify.sh --quick` 全绿：

```
Rust 291 · Swift XCTest 401 · self-test 265 · Xcode unit target 401 · XCUITest 8 (ran, 8 executed)
VERDICT: every check passed
```

新增的 19 条测试（17 条 guard + 2 条设计系统角色）第一次跑时**只进了 `swift test`，没进 Xcode
的 unit target**（382 vs 401）。原因是 `project.yml` 里 `SiftTests` 的 `sources: path: Tests`
是生成期展开的显式文件列表：新增测试文件不会自动进已生成的工程，必须
`xcodegen generate --spec project.yml`。重新生成后两边都是 401。这条已补进 `AGENTS.md` 的
"Before committing"，因为它只在"数量对不上"时才可见。
