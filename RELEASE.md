# 发布前检查清单

本仓库当前产出的是**开发构建**：`Scripts/build-app.sh` 与 `project.yml` 都用 ad-hoc 签名
（`CODE_SIGN_IDENTITY: "-"`），只为让本机和 CI 能编译、运行与测试。它能在这台机器上运行，
不代表别的 Mac 能打开。这份清单是把它变成可交付版本所缺的步骤，每一条都写明**怎么验证**，
而不是"应该做了"。

## 1. 版本号必须来自 tag

`Scripts/build-app.sh` 现在从最近的 `v<major>.<minor>.<patch>` tag 取
`CFBundleShortVersionString`（`--abbrev=0` 去掉 `-<commits>-g<hash>`，并去掉 `-rc1` 之类的
后缀，因为该字段只接受最多三段整数）；没有 tag 时回退到 `project.yml` 里的
`MARKETING_VERSION`。Xcode 路径不会自己读 tag，发布时要显式传入：

```bash
MARKETING_VERSION="$(git describe --tags --abbrev=0 --match 'v[0-9]*' | sed 's/^v//')" \
  xcodebuild ... build
```

验证：

```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" .build/Sift.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" .build/Sift.app/Contents/Info.plist
```

两者都必须与本次发行一致；`CFBundleVersion` 是整数（当前取提交数）。

## 2. 签名、Hardened Runtime、公证与产物校验

需要真实的 Developer ID 身份，仓库里无法预置：

- 用 **Developer ID Application** 签名，开启 Hardened Runtime（`--options runtime`），
  entitlement 用 `Config/Sift.entitlements`（非沙盒，直接下载版）。
- `xcrun notarytool submit --wait` 之后 `xcrun stapler staple`。
- 校验**发布产物本身**，不是中间构建：

```bash
codesign --verify --deep --strict --verbose=2 Sift.app
spctl -a -vv Sift.app                     # 必须 accepted, source=Notarized Developer ID
xcrun stapler validate Sift.app
```

- 最后一关是在一台**干净的 Mac** 上（不同机器、非本 checkout）下载、首次打开、走一遍扫描。

## 3. UI 测试必须真的执行过

`Scripts/verify.sh` 与 CI 把"某个测试失败"和"runner 根本没启动"分开，这是对的，但那意味着
**绿色的运行不代表 UI 测试跑过**。阶段 8 现在不靠退出码判断，而是读每个 Xcode 目标的结果包
（`xcrun xcresulttool get test-results summary`），所以汇总行会写明实际执行了多少个用例。
发布的这次运行必须满足：

- `Scripts/verify.sh` 的汇总行是 `VERDICT: every check passed`；
- 同一份汇总里 `XCUITest methods` 一行必须是 `(ran, N executed)` 且 N > 0
  （本机最近一次：`8 (ran, 8 executed)`——7 个通过、1 个是用例内的 `XCTSkip`）；
- 同一份汇总里 `Xcode unit target` 一行的数字必须非零；
- CI 的 UI 步骤打印 `UI tests: ran`。

`did not run` 的两种形态（runner 没启动、退出码 0 但结果包里没有用例）都按失败处理，
因此那一次的 `VERDICT` 是 `at least one check failed`；只有装了命令行工具、没有 Xcode 的
机器才会出现 `VERDICT: every check passed, but the XCUITest target did not run`，那种运行
不能作为发布依据。

runner 起不来是**间歇**的，不是这台机器的固有缺陷，而且有三种形态（找不到目标应用的
`.../Debug/Sift`；`Timed out while enabling automation mode`，属于自动化授权；以及完全不返回、
日志一片空白的挂起——每次尝试现在有五分钟上限，超时会被停掉并按同一口径记录）。
2026-10-19 实测：同一个提交先在 `Scripts/verify.sh` 里连续两次没起来，随后连续五次 5/5 通过
（包括一次全新 DerivedData 从零构建，以及一次在重新注册另一个 checkout 的 bundle 之后）；
八小时后机器睡醒，第二种形态又可复现地出现，重启 runner 进程与唤醒显示器都没恢复，需要人在
图形界面确认授权。所以遇到 `did not run` 就重跑，并把那次真正跑通的运行作为依据。
细节见 `AGENTS.md`。

## 4. 购买与授权接通真实服务

现状：`Core/App/Entitlements/EntitlementService.swift` 的接口、Keychain 存储、14 天离线宽限、
按时钟（而非进程启动时刻）判定的过期、未来时间戳拒绝都已就绪，但
`AppEnvironment` 注入的 `verify` 闭包**无条件抛** `licenseServiceUnavailable`。
也就是说当前构建里没有任何路径可以解锁付费功能，免费档是唯一可能的状态。

接入后至少要实测：

- 激活成功、激活失败、恢复购买；
- 断网 14 天内仍可用，**第 15 天在应用不重启的情况下**降级为免费档；
- 系统时间被向前/向后改动；
- 本地状态被手工篡改（删除 keychain 项、改 UserDefaults）后不会解锁；
- 免费档仍然完整可扫描、不可清理。

## 5. 升级、卸载与权限

- 覆盖安装、从旧版本升级（偏好与扫描历史不丢）；
- 卸载应用后重新扫描：残留是否被正确识别，哪些是**有意保留**的；
- Full Disk Access 提示路径；
- 外部卷授权：拔盘后 bookmark 失效、重新插上后重新授权，且授权未扩大可扫描范围。

## 5.1 威胁模型：不沙盒的代价要写在明处

直售版没有 App Sandbox（`Config/Sift.entitlements` 里 `com.apple.security.app-sandbox` 为
`false`），也没有 privileged helper，Full Disk Access 由用户在系统设置里授予。这不是可以含糊
过去的一处配置，它决定了产品的威胁模型：

> **进程内任何一处内存安全缺陷，等价于"用户级全盘读写"，而不是"沙盒内的越权"。**

因此三件事是发布条件，而不是"最好有"：

- `unsafe` 面只有 `sift-ffi` 一个 crate（其余 crate 生产代码里没有 `unsafe`），新增的第二处
  需要在这份清单里说明理由；
- 跨语言的每一个入口都校验形状：扫描请求与存储分析的根目录走同一个 allowlist
  （`RustCore/crates/sift-ffi/src/lib.rs` 的 `validate_scope`），请求里的尺寸字段在反序列化
  时被 clamp，用户规则文件在读取时拒绝逃逸锚点与禁用目录；
- 依赖审计与 ASan 都在 `Scripts/security-audit.sh` 里，CI 的 `rust` 作业（每个 push 与 PR）
  两步都跑：`cargo audit` 这一步、`sift-ffi` 的 AddressSanitizer 这一步。**`cargo audit`
  非零退出即整个作业变红**，不是警告。

本地跑同一份脚本（无参数 = 两项都跑，`--offline` = 不联网）：

```bash
Scripts/security-audit.sh                 # cargo audit + sift-ffi 的 ASan 测试
Scripts/security-audit.sh audit           # 只跑依赖审计
Scripts/security-audit.sh sanitize        # 只跑 ASan
Scripts/security-audit.sh --offline       # 网络不可用：用本地 advisory-db，不装工具
grep -rn "unsafe" RustCore/crates --include=*.rs | grep -v "sift-ffi"   # 期望：只在测试或注释里
```

`audit` 在 `RustCore/` 里跑 `cargo audit`；`cargo-audit` 没装时，非 `--offline` 会先
`cargo install cargo-audit --locked`，`--offline` 则直接以"工具缺失 + 安装命令"失败。

`sanitize` 跑的是：

```bash
cd RustCore && RUSTC_BOOTSTRAP=1 CARGO_TARGET_DIR=$PWD/target/asan \
  ASAN_OPTIONS=detect_leaks=0 cargo test -p sift-ffi --target "$(rustc -vV | sed -n 's/^host: //p')" \
  --config 'target.<host>.rustflags=["-C","link-arg=-mmacosx-version-min=13.0","-C","link-args=-mmacosx-version-min=13.0","-Zsanitizer=address"]'
```

三件事是实测出来的，不是写法偏好：

- `RustCore/.cargo/config.toml` 设了 `target.<triple>.rustflags`，cargo 会因此**忽略**
  `RUSTFLAGS` 环境变量；只在环境里加 `-Zsanitizer=address` 会静默无效，测试照跑，代码一行都没插桩。
  所以标志走 `--config`，并且要连部署目标那两条一起给（配置里只留其中一条时，另一条会被丢掉）。
- 只用 `-C link-arg=-fsanitize=address` 在这条工具链上根本不会链接运行时：产出的测试二进制里没有
  ASan 运行时，测试全绿却什么都没检查。脚本因此构建后回读 `otool -L`，没有 ASan 运行时即判失败。
- `-Z` 在 stable 上是 nightly-only，本机与 CI 都只有 `rust-toolchain.toml` 钉住的 1.99.1。
  `RUSTC_BOOTSTRAP=1` 让这条钉住的工具链接受该标志，不安装、也不升级任何工具。
  `--target <host>` 同样必需：不指定时 cargo 会把 target 的 rustflags 也用到 proc macro 上，
  rustc 加载被插桩的过程宏时会直接 abort（`Interceptors are not working ... loaded too late`）。

`sanitize` 构建到 `RustCore/target/asan`，不碰 `RustCore/target/<triple>/release`，因此
`Bridge/macos-universal/libsift_ffi.a`——Swift 侧 `-force_load` 的那个归档——不会被带 sanitizer
的对象替换。**无法运行的检查不算通过**：工具缺失、advisory 库拉不下来、测试二进制没有链接
sanitizer 运行时，三者都让脚本以非零退出。

对应的审查记录见 [Research/security-audit-2026-11.md](Research/security-audit-2026-11.md)：那一篇
列了每条缺陷、修法与**明确接受的残余风险**（纯词法归一不做 `realpath`、`trashItem` 自身跟随
祖先链接）。残余风险不是待办，是产品当前的样子；改动它们要同时改这份清单。

## 6. 生成产物是当前的

`Scripts/verify.sh` 第一步已经检查字符串目录、保护清单与规则表；发布前确认它在本地与 CI 都是
通过的，且发布包内的 `CleaningRules.json` 与 `BuiltInRules.swift` 同源（由 Rust 的
`default_rules()` 生成）。

## 7. 留下一次发行的证据

发布时记录：谁、哪台机器（macOS 版本、`xcodebuild -version`）、哪个提交、`Scripts/verify.sh`
的汇总行原文、`codesign`/`spctl`/`stapler` 的输出。下一次讨论"上次是不是真的过了"时，
依据就是这些，而不是记忆。
