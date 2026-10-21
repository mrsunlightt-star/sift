# Sift — macOS 清理工具

Sift 是一款不依赖账号、不上传用户文件、以「扫描 — 解释 — 确认 — 可恢复清理」为核心流程的轻量 Mac 清理工具。所有清理项默认移入废纸篓，删除前展示来源、大小、原因和风险等级。

**$4.99 一次性买断，永久使用，包含未来大版本更新，无订阅。**

界面按 `sift-redesign/` 的方案重做：左侧图标导航（总览 / 扫描 / 应用 / 存储）、玻璃材质卡片、浅色与深色主题。原「智能扫描 / 垃圾清理 / 文件清理」三个入口合并为一个「扫描」页，结果用类别筛选切换，导航只保留用户真正要去的地方。

产品与体验的完整基线见 [sift-macos-cleaner-development-spec.md](sift-macos-cleaner-development-spec.md)。

---

## 快速开始

```bash
# 1. 一次性初始化：编译 Rust 核心、生成字符串、生成 Xcode 工程
Scripts/bootstrap.sh

# 2. 构建并打包 Sift.app（SwiftPM）
Scripts/build-app.sh --release
open .build/Sift.app

# 或者用 Xcode 打开完整工程
open Sift.xcodeproj
```

`bootstrap.sh` 会把 Rust 静态库放到固定路径 `Bridge/macos-universal/libsift_ffi.a`，
SwiftPM 与 Xcode 工程都从这里链接。固定路径是刻意的：SwiftPM 在沙盒中求值清单，
文件存在性探测可能误报为「不存在」，所以清单不做任何探测。

如果这台机器还没有 Xcode，`Scripts/run-tests.sh` 与 `SiftSelfTest` 仍可完成全部验证。

---

## 目录结构

| 路径 | 内容 |
|---|---|
| `App/` | 应用入口、路由、图标导航栏与窗口外壳 |
| `Core/` | 领域模型、规则引擎、文件操作、报告、权限、购买、扫描引擎 |
| `Core/RustBridge/` | Rust C ABI 的 Swift 封装（`#if canImport(SiftScanner)` 保护） |
| `Core/UI/` | 多个功能共用的视图（结果列表、选择栏、确认与结果页） |
| `Features/` | 功能模块：总览、扫描（原智能扫描/垃圾清理/文件清理已合并）、应用、存储、设置、购买 |
| `Shared/` | 设计系统、通用组件、八种语言的字符串目录 |
| `RustCore/` | Rust workspace：规则、哈希、SQLite 索引、扫描协调器、FFI |
| `Bridge/` | C 头文件、SwiftPM 的 module map、XCFramework 输出目录 |
| `Scripts/` | 构建、环境、字符串生成、测试运行脚本 |
| `Tests/` | XCTest 测试套件（219 个测试方法） |
| `SelfTest/` | 无需 Xcode 即可运行的自检套件（245 项检查） |

---

## 架构

```
SwiftUI Views  →  Feature ViewModels  →  Use Cases  →  Scanner Engine
                                                   →  File Operations (Trash)
                                                   →  Permission / Entitlement
Rust Scanner Core  →  Rules · SQLite Index · Duplicate Pipeline
```

三条边界是刻意设计的：

1. **Rust 只负责发现与分析。** 遍历、规则匹配、重复文件分阶段检测都在 `RustCore/`；它不删除、不移动、不读写购买状态。所有破坏性操作回到 Swift 的 `FileOperationService`。
2. **Swift 侧再验证一次。** `RuleEngine.protectionReason` 在界面上、预检时、执行前各查一次。Rust 的规则文件和 Swift 的规则表都**无法**取消编译进二进制的保护清单（`Documents`、`Desktop`、`/System`、钥匙串等）。
3. **事件批量、结果分页。** Rust 每次最多回传一批摘要，明细留在 SQLite 索引里按页读取；Swift 永远不会为整块磁盘构建对象图。

### 两个扫描核心

| 核心 | 何时使用 | 说明 |
|---|---|---|
| `RustScannerEngine` | 生产构建（`bootstrap.sh` 已生成 Rust 静态库） | 高性能实现，事件/分页经由 C ABI |
| `SwiftScannerEngine` | 参考实现，也是 Rust 不可用时的回退 | 行为与 Rust 核心逐条对齐，可脱离 Rust 单独测试 |

`ScannerEngineFactory` 在启动时校验 ABI 版本，版本不一致时拒绝使用 Rust 核心并回退——宁可慢，不可错。设置页「诊断」一栏会写明当前使用哪个核心。

---

## Xcode 工程

`Sift.xcodeproj` 由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成并已提交，
因此装有 Xcode 的机器不需要额外安装工具即可打开。

| 内容 | 位置 |
|---|---|
| App target（`App/Entry` + 资源） | `project.yml` |
| 单元测试 target（`Tests/`，219 个测试方法） | `project.yml` |
| UI 测试 target（`UITests/`，XCUITest） | `project.yml` |
| 测试计划（单元 + UI 两组配置） | `Config/Sift.xctestplan` |
| Info.plist / entitlements | `Config/` |
| 图标与强调色 | `Resources/Assets.xcassets` |
| 构建前自动编译 Rust 核心 | `project.yml` 的 `preBuildScripts` |

`project.yml` 里的 app target 只编译入口文件，其余模块来自同一个本地 SwiftPM 包，
所以 Xcode 与 `swift build` 用的是同一份源码、同一套模块边界。

**分发方式只有直接下载。** 本项目不提供 Mac App Store 版本：App Sandbox 无法扫描
`~/Library/Caches`、`~/Library/Logs`，也无法列出 `/Applications` 做批量卸载。要上架
App Store 必须另做一个“只清理用户选中文件夹”的 Lite 版本，而不是切换一个 entitlement。

## 构建要求

| 组件 | 版本 | 说明 |
|---|---|---|
| macOS | 13 Ventura 或更高 | 应用最低部署目标 |
| Swift | 6.0 | `Package.swift` 使用 swift-tools-version 6.0 |
| Rust | stable（`RustCore/rust-toolchain.toml` 锁定） | 双架构目标：`aarch64-apple-darwin`、`x86_64-apple-darwin` |
| Xcode | 16+，可选 | 打开 `Sift.xcodeproj`、运行 XCUITest、`swift test` 时需要；仅用命令行工具也能构建并运行应用 |
| XcodeGen | 2.46+，可选 | 只有修改 `project.yml` 后重新生成工程时需要：`brew install xcodegen` |

Rust 部署目标固定为 13.0（`RustCore/.cargo/config.toml`），否则链接时会出现 "built for newer macOS version" 警告，且产物无法在旧系统加载。

---

## 脚本

| 脚本 | 作用 |
|---|---|
| `Scripts/bootstrap.sh` | 一次性初始化：Rust 核心 + 字符串 + Xcode 工程 |
| `Scripts/build-rust-core.sh` | 构建 Rust 静态库到 `Bridge/macos-universal/`（`--universal` 生成双架构） |
| `Scripts/build-app.sh` | 构建、打包 `.app`、ad-hoc 签名；`--release`、`--run`、`--install` |
| `Scripts/build-rust-xcframework.sh` | 生成 Universal（arm64 + x86_64）XCFramework 并校验双架构 |
| `Scripts/generate-strings.py` | 从单一表格生成 `Localizable.xcstrings`、`LocalizationKey.swift` 与 8 个 `.lproj/Localizable.strings` |
| `Scripts/generate-protection.py` | 从 Rust 常量生成 Swift 保护清单 |
| `Scripts/generate-rules.py` | 从 Rust 的 `default_rules()` 生成 `CleaningRules.json` 与 Swift 兜底规则表 |
| `Scripts/check-explanation-keys.py` | 校验代码交给界面的每个解释键都在字符串目录里，且不带格式占位符 |
| `Scripts/check-tests.sh` | 用类型检查验证 XCTest 套件（无需 Xcode） |
| `Scripts/run-tests.sh` | 用内置的 XCTest 兼容 runner 真正执行 XCTest 套件（无需 Xcode） |
| `Scripts/verify.sh` | 全量验证：Rust 测试 + FFI 契约 + 自检 + XCTest + 构建 |

---

## 验证

```bash
Scripts/verify.sh            # 全部检查
```

准备发行时另有一份逐条写明验证方式的清单：[RELEASE.md](RELEASE.md)——签名与公证、产物校验、
UI 测试必须真的执行过、支付接通后的实测项。

各层单独运行：

```bash
# Rust：单元测试、FFI 契约测试、基准
cd RustCore
cargo test                              # 188 个测试
cargo clippy --all-targets              # 无警告
cargo bench -p sift-scanner-core        # 目录遍历 / 局部比较 / 完整哈希 / 索引写入

# Swift 自检（245 项检查，无需 Xcode）
swift run SiftSelfTest

# XCTest 套件（219 个测试方法）+ 7 个 XCUITest
./Scripts/run-tests.sh                  # 命令行工具即可运行
swift test                              # 装了 Xcode 时的标准方式
xcodebuild test-without-building -scheme Sift -testPlan Sift -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath .build/xcode
```

`Scripts/verify.sh` 结束时会把三套测试的实际数量打印出来（Rust 188、XCTest 219、自检
245，以及 XCUITest 7）。文档里引用的是这份输出，而不是另外记一份数字：数字会漂。

### 测试覆盖了什么

Rust（188 个测试）：

- 规则匹配、保护路径（含 `/var` → `/private/var` 这类别名）、风险等级合并
- 规则文件版本、重复 ID、非法覆盖
- 分阶段重复检测：大小分组 → 首尾中部采样 → 完整 BLAKE3 → 分组与保留项
- 目录遍历的字节数按**分配大小**统计（含稀疏文件回退到逻辑大小）
- SQLite 索引：分页稳定性、分类过滤、重复组、跳过记录、schema 版本
- 扫描协调器：事件顺序、取消、不可读目录、受保护内容零泄漏、panic 不越界
- FFI 契约：头文件与 Rust 结构体逐字段比对（大小、偏移、对齐、版本号、枚举值）

Swift（245 项自检 + 219 个 XCTest）：

- 保护清单、路径穿越、符号链接、包目录、CloudKit 排除
- 预检（父子去重、缺失文件、占用文件、受保护路径在**执行时**再拒绝）
- 拒绝可追溯：预检丢掉的条目会带着原因进入结果（而不是从批次里消失），被父目录包含的子项不重复上报
- 双引擎一致：同一个 fixture 同时喂给生产引擎与参考引擎，逐行比较路径、分类、风险、大小、文件数与解释键（含隐藏文件开关、仅测量根、重复文件管线）
- 扫描：日志按文件年龄过滤、新安装包不推荐、分页不重复、取消、部分失败
- 重复文件：同大小不同内容必须分开、保留最旧副本、iCloud 占位文件排除、520 个成员的分页不重复
- 清理选择：稳定身份、重绘后仍保持勾选、重复文件成员可单独选择、受保护项无法选择
- 扫描策略：仅测量根不产生候选；授权卷可扫描而其他卷仍关闭；授权不解锁用户内容或系统前缀
- 授权白名单：`/`、`/Library`、`/private/var`、`/Volumes` 均不可授权
- 报告：扫描范围/跳过/失败计数准确，条目携带真实分类
- 生产引擎：自检套件直接用 `ScannerEngineFactory` 返回的 Rust 引擎跑一遍扫描与分页
- 报告：本地副本不含目录路径、PDF 多页渲染、八种语言均可渲染
- 本地化：8 种语言每个 key 都有译文、占位符全部替换、复数形态区分
- 购买：免费版可扫描不可清理、验证失败不影响离线宽限期、过期回退免费版

---

## 开发过程中的重要决定

以下决定都在代码注释中记录了原因，这里汇总便于评审：

1. **保护清单编译进二进制。** `RuleEngine.protectedHomeChildren` 与 `PROTECTED_PREFIXES` 不来自规则文件，规则文件只能扩大「可识别范围」。用户放进数据目录的 `CleaningRules.json` 无法把 `Documents` 变成可清理项。
2. **重复文件按「分配大小」分组。** 这与访达显示的容量一致；APFS 会向上取整到 4 KB 块，因此小于 4 KB 的文件实际不会成为重复候选，文档里也如此说明。
3. **日志年龄按文件计算，不按目录。** 一个 `~/Library/Logs/<app>` 里同时有 1 天和 1 年的日志时，只统计旧的那份。
4. **路径先规范化再比较。** 归一化会解析 `.`、`..` 和 macOS 的固定符号链接别名（`/var`、`/tmp`、`/etc`）。否则同一目录的两种写法会让保护规则失效——这是开发中实际触发过的缺陷。
5. **`homeDirectory` 是规则集的属性。** 扫描器、存储分析、卸载关联文件全部使用同一个 home，不允许回退到进程 home；否则扫描任何「非当前用户的树」时都会套用错误的保护名单。
6. **卸载只认 bundle identifier 或精确应用名。** `~/Library/Application Support/Editor` 永远不会因为某个应用叫 Editor 就被认定为残留。
7. **免费版完全没有清理入口。** 付费墙在点击「清理」「卸载」「移入废纸篓」时出现，启动时绝不拦截扫描。
8. **外部磁盘必须由用户主动添加。** 应用不枚举挂载点自动纳入扫描；用户在设置里选择文件夹或磁盘后，通过 security-scoped bookmark 持久化授权。授权采用**白名单**：只接受 `/Volumes/<卷名>` 与用户主目录内的普通文件夹，`/`、`/Library`、`/private/var` 等系统树无法被授权。硬保护永远优先，授权只能解除 `/Volumes` 这一条默认前缀，且只对具体卷生效；`Documents`、钥匙串、照片图库和所有系统前缀即使是授权路径也保持锁定。stale bookmark 会在启动时重新生成并写回设置。
9. **清理项身份稳定。** 身份由「分类 + 标准化路径」派生，而不是每次转换生成随机 UUID；否则 SwiftUI 每次重绘都会让勾选失效。
10. **`isCleanable` 是硬约束。** 仅测量根不产生任何清理候选，Rust 与 Swift 两个引擎都执行这一约束，残留扫描同样受 home 根策略约束。
11. **结果与报告来自实际操作。** 报告不再把跳过数重复相加，也不用跳过位置数冒充扫描范围（PDF 的范围行同样使用真实位置数）；每条结果携带真实分类，结果页在清理后呈现并可导出 PDF。不同入口（智能扫描、垃圾清理、大文件、旧文件、重复文件、卸载）各自记录正确的操作名称。
12. **确认偏好真正生效。** 关闭确认后直接执行，但内容仍然进入废纸篓、结果页仍然显示；默认开启。
13. **XCTest 与自检并存。** 只装 Command Line Tools 的机器无法运行 XCTest，`Scripts/run-tests.sh` 用内置 runner 真正执行全部 219 个测试（在主 actor 上、不阻塞主线程），`swift test` 与 `xcodebuild` 在装了 Xcode 的环境运行同一批文件。UI 测试只有 `xcodebuild` 能跑，`Scripts/verify.sh` 与 CI 都会执行它们。
14. **多语言两种产物。** `.xcstrings` 是权威来源（Xcode 编译），同时生成 `.lproj/Localizable.strings`，使没有 `xcstringstool` 的构建也能正确显示八种语言。

---

## 交付范围对照

| 规格章节 | 状态 | 位置 |
|---|---|---|
| §5.1 智能扫描（阶段、取消、部分失败、分页结果） | 完成 | `Core/Scanner/`、`Features/Scan/` |
| 外部磁盘授权（用户选择 + bookmark + 规则豁免） | 完成 | `Core/Permissions/AuthorizationService.swift` |
| §5.2 垃圾清理（四类、风险、确认面板、结果页） | 完成 | `Core/Scanner/CleanupModel.swift`、`Core/UI/` |
| §5.3 软件卸载（发现、关联文件分组、运行中提示、系统应用标记） | 完成 | `Core/Indexing/`、`Features/Uninstaller/` |
| §5.4 存储分析（卷、分类、目录树、大文件、索引与快照诊断、覆盖状态） | 完成 | `Core/Scanner/StorageAnalyzer.swift`、`Core/Diagnostics/`、`Features/StorageAnalysis/` |
| §5.5 文件清理（大文件、旧文件、重复文件三分阶段） | 完成 | `Core/Scanner/SwiftScannerEngine.swift`、`RustCore/crates/sift-hasher` |
| §5.6 设置（分组、阈值、忽略列表、外观） | 完成 | `Core/Settings/`、`Features/Settings/` |
| §5.7 清理报告与 PDF（本地副本、脱敏、分页、字体回退） | 完成 | `Core/Reporting/` |
| §6.1–6.5 技术栈、目录、分层、FFI、双架构 | 完成 | 见上方架构与脚本 |
| §7 数据模型 | 完成 | `Core/Models/` |
| §8 扫描引擎（协议、事件、安全规则、规则格式） | 完成 | `RustCore/`、`Core/Rules/` |
| §9 文件操作与恢复（预检、废纸篓、失败分类） | 完成 | `Core/FileOperations/` |
| §10 权限（无 Full Disk Access 也能工作、明确报告） | 完成 | `Core/Permissions/` |
| §11 UI/UX（配色、密度、空状态、无障碍、八语言） | 完成 | `Shared/`、`Features/` |
| §12 购买（免费/买断边界、激活、恢复、离线宽限） | 完成（支付供应商待定） | `Core/Entitlements/` |
| §13 隐私与安全（日志脱敏、白名单；除两条只读状态查询外不执行任何命令） | 完成 | `Core/Logging/`、`Core/FileOperations/`、`Core/Diagnostics/SystemQuery.swift` |
| §14 错误码与用户提示 | 完成 | `Core/Models/OperationModels.swift` |
| §15 性能要求（批量事件、分页、取消、基准） | 完成 | `RustCore` benches |
| §16 测试计划 | 完成（含 XCUITest，见 `Scripts/verify.sh` 与 CI） | `Tests/`、`UITests/`、`SelfTest/`、`RustCore/*/tests` |

### 按规格刻意延后 / 未包含

- **支付与授权服务供应商**：规格 §19 把这个决定留到正式开发前。`DirectLicenseService` 已定义完整合同（校验闭包、Keychain 存储、离线宽限、恢复），接入时只需提供一个 `verify` 闭包。
- **Sparkle 自动更新**：需要在签名与发布流程确定后接入；`build-rust-xcframework.sh` 已保证更新包内 Rust 二进制的双架构与部署目标一致。
- **UI 测试录制**：`UITests/` 已提交并在 `Scripts/verify.sh` 与 CI 中执行（7 个用例）；录制新的交互仍需要 Xcode GUI。
- **应用图标**：未提供资源，打包脚本保留 `AppIcon` 位置。
- **发布流水线**：Developer ID 签名、Hardened Runtime、公证、产物校验与 Sparkle 更新。这些需要一个
  真实的签名身份，仓库里只能先留出位置——`Scripts/build-app.sh` 是开发构建脚本，不是发布脚本。
  逐条的验证方式见 [RELEASE.md](RELEASE.md)。

---

## 已知限制

- **发布构建尚未签名与公证。** `Scripts/build-app.sh` 与 `project.yml` 使用的是 ad-hoc 签名
  （`CODE_SIGN_IDENTITY: "-"`），只为让本机与 CI 能构建并运行测试。面向用户的直接下载版本还需要
  Developer ID 签名、Hardened Runtime、公证与发布产物校验；仓库里目前没有这些步骤，也没有对应的
  发布配置。**当前的构建产物是开发构建，不是可交付给用户的版本。**
- **直接下载版本不是 App Sandbox。** 这与「扫描整台机器」的产品定位一致，但也意味着路径边界、
  最小授权与隐私说明承担了更多责任。项目只支持这一条分发渠道，没有 Mac App Store 配置。
- **未接入真实支付服务。** 许可证校验目前是一个明确的「服务不可用」占位：`AppEnvironment`
  注入的 `verify` 闭包无条件抛 `licenseServiceUnavailable`，所以**当前构建里没有任何路径可以
  解锁付费功能**，免费档是唯一可能的状态——清理与卸载在真机上还没有用户走到过（只有测试走到）。
  接口、Keychain 存储、离线宽限（14 天，每次授权判断都会重新核对是否过期）与恢复流程已就绪，
  缺的是传输层。发布前必须替换，见 [RELEASE.md](RELEASE.md) 第 4 节。
- **规则表只有一份来源。** `default_rules()` 是唯一来源，`Core/Resources/CleaningRules.json`
  与 `Core/Rules/BuiltInRules.swift` 都由 `Scripts/generate-rules.py` 从它生成，`verify.sh`
  在任一份过期时失败。此前这三份是手写的三张表（Rust 12 条、文件与兜底表 7 条），两个引擎因此
  识别不同的文件集合。
- **容器目录不再由规则扫描。** `~/Library/Containers` 与 `~/Library/Group Containers` 里
  每个应用各占一个目录，所以规则表里没有指向它们的规则（`Directory` 会把所有应用的数据变成一条
  清理项）。已卸载应用的容器由扫描核心按「已安装 bundle id」判定为残留后给出；仍在使用的应用的
  容器只出现在卸载流程里，并且是跟着它所属的应用出现。
- **`~/Library/Application Support` 只按「已卸载」判定残留。** 规则表里没有 `app-residue-*`
  规则：规则只能匹配名称形状或年龄，无法知道应用是否还装着，此前会让该目录下**每一个**子目录都
  成为「应用残留」候选（含 `Google`、`Editor` 这类仍在使用的应用数据）。
- **`Scripts/verify.sh` 需要 Xcode 16 才能跑 UI 测试。** 只装 Command Line Tools 时，Xcode 阶段
  会跳过并明确打印「skipped」，其余阶段照常执行。
- **XCUITest runner 起不来的三种形态，都是间歇的、都不是仓库的问题。** Xcode 16.4 的 UI 测试
  runner 会在三种情况下**在第一个用例执行之前**就退出：一是寻找目标应用时去找
  `.../Debug/Sift`——没有 `.app` 后缀的路径——而 bundle 就在旁边的 `Sift.app`，于是报
  `The bundle identifier for Sift couldn't be read`；二是报
  `The test runner failed to initialize for UI testing. (Underlying Error: Timed out while enabling automation mode.)`，
  那属于自动化授权而不是代码；三是完全不返回（一次尝试静置十三分钟、日志一片空白），因此每次尝试
  现在有五分钟上限，超时会把它停掉并按同一口径记录。三种形态在本机与 GitHub 的 `macos-15` runner
  上都出现过，且跟仓库代码无关：失败的那次运行里 `xctestrun` 里的路径是正确的 `Sift.app`，
  bundle 存在、名字正确、签名也通过校验。2026-10-19 实测：同一个提交先在 `Scripts/verify.sh` 里
  连续两次没起来，随后**连续五次 5 个用例全部通过**（含一次全新 DerivedData 从零构建）；八小时后
  机器睡醒，又以第二种形态可复现地失败（重启 runner 进程、唤醒显示器都没恢复，需要人在图形界面
  确认授权）。因此遇到 `did not run` 应当重跑，而不是当作环境缺陷绕开。`Scripts/verify.sh` 与 CI
  仍把两件事分开：「某个测试失败」会让流程失败；「runner 根本没启动」记为 `did not run` 并在汇总
  里写明，不会伪装成通过——绿色的汇总永远不代表 UI 测试真的跑过。发布时要求这一次运行的 UI 目标
  确实执行过，见 [RELEASE.md](RELEASE.md) 第 3 节。
- **先运行一次 `Scripts/bootstrap.sh`。** 它编译 Rust 核心并放到固定路径；之后 `swift build`
  与 Xcode 都直接可用。

---

## 许可证

私有软件，保留所有权利。
