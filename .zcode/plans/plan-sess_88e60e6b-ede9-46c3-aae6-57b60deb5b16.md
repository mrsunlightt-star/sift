# Sift for Windows — 新建同级仓库并完成 Windows 版首版

## Context

`/Users/sunqiqi/sift` 是一个 macOS 清理应用：SwiftUI 壳 + Rust 扫描核心（规则引擎、目录遍历、SQLite 结果索引、去重、存储分析，经 C ABI FFI 交付）。用户要求创建同级目录，开发 Windows 版本。

探索结论决定了架构：
- **RustCore（5 crates，~16.5k 行，252 个测试）几乎完全可移植** —— 唯一的 darwin 专属代码是 `walker.rs` 的 `st_flags/SF_DATALESS`、`storage.rs` 的 `statfs`、`hasher.rs` 的 `O_NOFOLLOW`，以及硬编码的 macOS 路径/规则表（`~/Library`、`/Volumes`、`/var/folders`、bundle-id 残留）。
- **FFI 契约（`Bridge/include/sift_scanner.h`，27 个符号，版本 1，已由 ffi_contract.rs 逐字段钉死）可以直接被 C# P/Invoke 复用**，ScanRequest/ItemSummary 全部走 JSON。
- 本机（macOS 15，不得升级）有 rustup 1.99.1；无 .NET SDK、无 mingw —— 两者都可经 brew 安装，装完后：Rust 可在本机跑宿主测试 + 交叉编译校验 Windows 目标；C#/.NET 可在本机编译、跑 xunit、甚至把 app 跑起来做真实扫描（后端 Rust dylib 是真的，Windows 专属服务用干跑 stub）。

**锁定方案**：C# + Avalonia 11（Fluent 主题 + 自绘玻璃设计系统）；Rust 核心复制进新仓库做 cfg 门控移植；UI 经 C ABI（`sift_ffi.dll`）调用；本地化直接复用原 34 语言 catalog；Windows 专属服务（回收站、注册表卸载枚举、DPAPI、进程令牌、卷枚举、VSS）集中在 `Sift.Platform.Windows`（net8.0-windows，本机用 `EnableWindowsTargeting` 编译校验）。仓库自包含：`/Users/sunqiqi/sift-windows`，git init，单分支 main 直接提交。

## 仓库布局

```
/Users/sunqiqi/sift-windows/
├── AGENTS.md                        # Windows 版不变量（移植 42 条中适用部分 + Windows 特有决定）
├── README.md                        # 中文，对齐原 README 结构
├── Directory.Build.props            # net8.0、LangVersion、TreatWarningsAsErrors
├── RustCore/                        # 移植的 Rust 工作区（sift-rules/file-index/hasher/scanner-core/ffi）
│   ├── Cargo.toml / .cargo/config.toml   # 按目标分的 link-args（去掉全局 macOS 强制）
│   └── crates/…
├── Bridge/include/sift_scanner.h    # 原样拷贝（ABI 冻结，ffi_contract.rs 继续钉住它）
├── Native/                          # 构建产物：host .dylib（本机开发跑真实扫描）、windows-x64/sift_ffi.dll
├── Tests/Fixtures/Rules/            # 原 accept/reject 语料原样拷贝（Rust 单解码器仍跑全套）
├── Localization/Localizable.xcstrings   # 从 ../sift 拷贝 + 新增 Windows 规则 explanation 键
├── src/
│   ├── Sift.Core/                   # net8.0：模型、付费墙、设置、本地化、请求装配、预检、报告
│   ├── Sift.Interop/                # P/Invoke + JSON 编解码（NativeMethods、SiftEngine）
│   ├── Sift.Platform.Windows/       # net8.0-windows（EnableWindowsTargeting，本机可编译）
│   ├── Sift.Platform.Dev/           # 本机开发 stub（干跑回收站/注册表等），让 app 在 macOS 上真跑
│   ├── Sift.App/                    # Avalonia：视图 + ViewModel + 设计系统
│   └── Sift.Tests/                  # xunit
├── Scripts/
│   ├── bootstrap.sh                 # build-rust-core + dotnet restore
│   ├── build-rust-core.sh           # host cdylib → Native/；--target x86_64-pc-windows-gnu 交叉校验（有 mingw 则产出 dll）
│   └── verify.sh                    # fmt/clippy → cargo test → windows 交叉校验 → dotnet build/test → 汇总
└── .github/workflows/ci.yml         # windows-latest：msvc 构建 + dotnet publish（真 Windows 验证交给 CI）
```

## 工作分解

### M1 — Rust 核心移植（先做，是其余一切的地基）

拷贝 `RustCore/` 五个 crate，然后：

1. **`.cargo/config.toml`**：macOS 部署目标 flags 改为 `[target.'cfg(target_os = "macos")']`；新增 `[target.x86_64-pc-windows-gnu]`（linker = x86_64-w64-mingw32-gcc）。`rustup target add x86_64-pc-windows-gnu`、`brew install mingw-w64`。
2. **`sift-rules`**：共享 schema/解码/合并/通配符逻辑不动；新增 `platform` 层做 Windows 表：
   - 保护表：`PROTECTED_HOME_CHILDREN` = Desktop/Documents/Pictures/Music/Videos；`PROTECTED_PREFIXES` = 每盘符根下 `Windows`、`Program Files`、`Program Files (x86)`、`ProgramData`、`Boot`、`Recovery`、`$Recycle.Bin`、`System Volume Information`、`Windows.old`，加 `C:\Users`（他人配置）、根盘 pagefile.sys/hiberfil.sys/swapfile.sys；`PROTECTED_LIBRARY_CHILDREN` = `%APPDATA%\Microsoft` 与 `%LOCALAPPDATA%\Microsoft` 下 Crypto/Protect/Credentials/SystemCertificates/Vault/IdentityCache/Outlook，加家目录 `.ssh/.gnupg/.aws/.kube`；`PROTECTED_RECYCLE_BIN_NAMES` = `$Recycle.Bin`/`Recycled`/`Recycler`（任意深度路径组件）；`SYMLINK_ALIASES` 置空；`DEFAULT_PACKAGE_EXTENSIONS` 置空（无 bundle 概念，walker 的 stop_at_packages 在 Windows 变 no-op）。
   - `RootAnchor` 增加 `LocalAppData`/`RoamingAppData`（保留 Home/UserTemp/Authorized/ExternalVolume；`HomeLibrary` 仅 darwin 编译）。
   - **Windows 规则表**（`default_rules()` cfg 分支，~20 条；id 复用 macOS 同义键以复用 explanation）：
     - `user-temp-caches`→`%LOCALAPPDATA%\Temp`(7d stale, safe)；`windows-temp`→`C:\Windows\Temp`(review)；`user-cache`→`%LOCALAPPDATA%\*` + `directoriesNamed(Cache,Caches,Code Cache,GPUCache,ShaderCache)`(safe, needsAppClosed)；`chromium-profile-caches`→`%LOCALAPPDATA%\Google\Chrome\User Data\*\*` 与 Edge 同形、Firefox `Profiles\*\cache2`；`user-logs`→`directoriesNamed(Logs,log)`；`download-installers`→exe/msi/msu/msix/appx(30d stale)；`download-archives`→zip/7z/rar/tar/gz/iso(90d)；`windows-error-reports`→`%LOCALAPPDATA%\Microsoft\Windows\WER\{ReportArchive,ReportQueue}`；`crash-dumps`→`%LOCALAPPDATA%\CrashDumps`；`directx-shader-caches`→D3DSCache、NVIDIA\GLCache、AMD\DxCache(needsAppClosed)；`thumbnail-cache`→`Explorer` 下 thumbcache(review)；dev 家族：gradle/cargo/npm-cache/pip-cache/nuget/yarn/pnpm；`office-file-cache`→OfficeFileCache(review)。
   - **残留扫描**（`scan_application_residue` Windows 分支）：位置改为 `%APPDATA%`、`%LOCALAPPDATA%` 深度 1；名字匹配从 bundle-id 扩展为「安装名/厂商 token/GUID 形状」；`EXCLUDED_BUNDLE_IDENTIFIERS` 换成 Windows 排除表（Microsoft、Google、Packages、NVIDIA、AMD、D3DSCache、Temp、SquirrelTemp、pip、npm-cache…）；Group Containers 概念在 Windows 无等价物 → 整组逻辑 darwin-only，文档写明。
3. **`sift-scanner-core`**：
   - `walker.rs`：allocated size——darwin 保留 `st_blocks`，Windows 用 `MetadataExt::file_size_on_disk()`（目录=子项求和，现有结构已按文件累加）；`device_of`——Windows 用 `volume_serial_number()`；隐藏判定——Windows 用 `FILE_ATTRIBUTE_HIDDEN`（`skip_hidden` 语义保持"扫描范围"不变）；junction/symlink 一律不跟随（std 把 junction 报告为 symlink，现有拒绝逻辑直接生效）。
   - `storage.rs`：经 `windows-sys`——`GetLogicalDrives`+`GetDriveTypeW`（固定盘/可移动/网络）、`GetDiskFreeSpaceExW`、`GetVolumeInformationW`（只读卷+卷标）；darwin 分支保留 `statfs`。
   - `hasher.rs`：`O_NOFOLLOW` cfg 化，Windows 用 `OpenOptionsExt::custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)`；`FileIdentity` 用 file index+volume serial+size+attributes+mtime。
   - `coordinator.rs`：`Engine::start_scan` 根门控的 Windows 形状（home 内、已授权盘符内、`UserTemp` = 精确 `%LOCALAPPDATA%\Temp`）；测试里的 `/Users/...`、`/var/folders` 夹具改为 platform tempdir + 注入 home。
   - `sift-ffi`：不动（契约冻结）；ffi_contract.rs 继续跑。
4. **验证**：`cargo test --workspace`（宿主跑 darwin 分支全部既有测试，需把 unix-perm 测试 cfg 化）；`cargo check --target x86_64-pc-windows-gnu`（Windows 分支编译校验）；fmt/clippy。

### M2 — C# 骨架：Interop + Core

- `Sift.Interop`：`NativeMethods`（27 符号 P/Invoke，`SiftString` = `{IntPtr, UIntPtr}`，句柄 `SafeHandle` 或 IntPtr+显式 Free）；`SiftEngine` 类移植 `RustScannerEngine.swift` 的语义（每会话独立索引目录、512 一批 poll、分页、跳过位置、取消、所有分配显式释放）；`sift_ffi_version()` 校验。
- `Sift.Core`（对齐 Swift 文件，逐个移植）：
  - `Models/`：`CleanupCategory`（raw 值 = Rust 字符串）、`CleanupRisk`、`CleanupItem`（**id = category+规范化路径**，无随机值）、`ScanReport/CategoryTotal/SkippedLocation/DuplicateGroup/Member/InstalledApplication/VolumeInfo/ScanPhase/UninstallPlan`；`OperationModels`（ErrorCode 表、`FileIdentitySnapshot`——Windows 用 `GetFileInformationByHandle` 取 volume serial+file index+size+attributes、PreflightReport、`ApprovedPlan`）。
  - `Scanning/`：`IScanEngine`、`ScanRequest` 装配（字段与 Rust `types.rs` 一致）、`ScanModel`（轮询泵、分页、重复组、风险合计、失败/取消语义——移植 `ScanModel.swift`）。
  - `Entitlements/`：状态机逐行移植（free/unlocked/offlineGrace、14 天离线窗、300s 时钟容忍、**每次闸门按当前时钟重估**）；`LicenseKeyStore` = DPAPI（`ProtectedData`，CurrentUser）；DEBUG 保留开发密钥 `SIFT-DEV-K7QM-3XPD-8R2V`。
  - `Settings/`：JSON 文件于 `%APPDATA%\Sift\settings.json`，`StringPreferences` 接口缝（测试用内存实现）；字段同 macOS（阈值、隐藏文件=扫描范围、确认开关、语言、外观、授权位置）。
  - `Localization/`：`LocalizationService` 直接解析 xcstrings JSON（System.Text.Json），34 语言、RTL、字节格式化（十进制，对齐 ByteCountFormatter）；缺键回退 en（与 macOS 的"每语言全表"差异写入 AGENTS.md）。
  - `Operations/FileOperationService.cs`：**四步语义原样保留**——预检（三次保护拒绝、`sift_path_protection` 走 FFI 而非第二张表、符号链接拒绝、重叠吸收、运行中应用拒绝、身份快照）→ `makeApprovedPlan`（唯一构造路径）→ 执行前重读身份 → 移动。Windows 移动 = 回收站（`IFileOperation` COM + `FOF_ALLOWUNDO`，逐项结果；回退 `Microsoft.VisualBasic.FileIO`）；干跑模式保留。
  - `RuleEngine.cs`：FFI 消费（protection/risk/rules JSON）+ 本地实现规范化（大小写折叠、去尾分隔符）与容器表。
- `Sift.Tests`（xunit，移植高价值套件）：Entitlement、FileOperation（干跑+身份变更拒绝）、ScanModel、Settings、Localization（catalog 完整性）、Selection（身份稳定）、Protection（经 FFI 全矩阵）。
- 本机验证：`dotnet build`（含 net8.0-windows 编译校验）+ `dotnet test` 全绿。

### M3 — Avalonia UI：设计系统 + 主链路

- `SiftTheme.axaml`：移植 `SiftTheme.swift` 令牌——accent（#00AEEC 族）、语义色 safe/review/danger/neutral、canvas + 三层 glass（`baseGlass/cardGlass/floatingGlass`，Avalonia 用半透明 brush + `TransparencyLevelHint="AcrylicBlurs"`）、glassBorder/Highlight、8 色 categoryPalette；4pt 网格、圆角 6/10/14/20、rail 112pt。
- `SiftComponents/`：GlassCard、PageHeader、Primary/SecondaryButton、Checkbox、FilterChip、RiskBadge、UsageBar/SegmentedUsageBar、ProgressRing、StatTile、Row/SelectableRow、EmptyState、NoticeBanner、RailItemLabel+chrome（对齐 `SiftComponents.swift` 清单）。
- `RootShellView`：图标 rail（概览/扫描/应用/存储 + 外观、账户、语言、设置）+ 页面宿主 + 弹层宿主（确认/结果/付费墙模态由壳持有——不变量 17）；语言切换整树重建。
- 页面：**ScanView**（`SmartScanView` 移植：过滤 chips、排序、分页游标、重复组卡、启动/进度/取消）→ **确认弹层**（"将 24 项移入回收站，10.2 GB"，分类分组、review 警告）→ **结果弹层**（含回收站快照/清空流）→ **PurchaseView**（免费层只扫不清、license 激活、掩码密钥）→ **SettingsView**（阈值、隐藏文件、忽略路径、授权位置、外观/语言、历史、license）。

### M4 — 其余页面 + Windows 平台服务

- `DashboardView`（回收合计按风险分列、磁盘环、建议=真实结果首页）；`UninstallerView`（注册表卸载键枚举：HKLM/HKCU×64/32 的 Uninstall 键，DisplayName/DisplayIcon/InstallLocation/EstimatedSize；**Windows 惯例适配：应用本体由厂商卸载器删除（ShellExecute UninstallString），Sift 只做卸载后残留清扫入回收站**——写入 AGENTS.md 作为与 macOS 的有意差异）；`StorageAnalysisView`（Rust storage::analyse 经 FFI + 诊断）。
- `Sift.Platform.Windows`：`ProcessTokens`（运行中进程枚举，token=去扩展名 exe 名+完整路径，喂给 `running_app_owns_path` 等价匹配）、`RegistryDiscovery`、`RecycleBinService`（`SHQueryRecycleBin` 按盘枚举+快照清空，语义同 TrashService）、`DpapiLicenseStore`、`VolumeEnumerator`（DriveInfo+GetDriveType）、`DiagnosticsProviders`（只读不变量 18：Windows Search 状态=注册表+索引文件测量、VSS=`vssadmin list shadows` 固定参数只读、回收站尺寸=SHQueryRecycleBin；refused→unknown，绝不编造）；`reveal`=`explorer /select`；`ms-settings:` 深链。
- `Sift.Platform.Dev`：上述接口的 macOS 干跑实现（回收站/注册表 stub），使 app 在本机连真实 Rust 引擎端到端可跑。

### M5 — 收尾

- `Scripts/verify.sh` + CI（windows-latest msvc + dotnet publish）；README（中文）+ AGENTS.md（不变量移植与差异清单）；首次提交到 main。

## 有意差异（写入 AGENTS.md）

安全作用域书签 → 授权文件夹清单（Windows 无该授权模型，保留 allowlist 复验与可读性探测）；Group Containers/应用组 → 无等价物，删除该类别；报告导出首版 HTML/txt（PDF 后续）；MSIX/UWP 卸载枚举留 TODO；`com.apple.*` 系统保留名 → `microsoft.` 等排除表。

## 验证

1. `Scripts/bootstrap.sh` 后：`cargo test --workspace` 全绿（宿主）+ `cargo check --target x86_64-pc-windows-gnu` 通过；`dotnet test` 全绿。
2. `dotnet run --project src/Sift.App` 在本机跑起来：连真实 Rust 引擎扫描一个注入的假 home（Platform.Dev 干跑删除），走完 扫描→确认（免费层弹付费墙）→（解锁后）回收站干跑→结果 全链路。
3. `cargo check/build` 产出 `Native/windows-x64/sift_ffi.dll`（mingw 存在时），C# interop 编译目标含 Windows 服务实现。
4. CI 文件就绪，真 Windows 构建交给 windows-latest runner（本机无法运行 Windows 二进制，如实说明）。