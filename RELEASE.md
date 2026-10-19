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
**绿色的运行不代表 UI 测试跑过**。发布的这次运行必须满足：

- `Scripts/verify.sh` 的汇总行是 `VERDICT: every check passed`，
  而不是 `VERDICT: every check passed, but the XCUITest target did not run`；
- CI 的 UI 步骤打印 `UI tests: ran`。

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

## 6. 生成产物是当前的

`Scripts/verify.sh` 第一步已经检查字符串目录、保护清单与规则表；发布前确认它在本地与 CI 都是
通过的，且发布包内的 `CleaningRules.json` 与 `BuiltInRules.swift` 同源（由 Rust 的
`default_rules()` 生成）。

## 7. 留下一次发行的证据

发布时记录：谁、哪台机器（macOS 版本、`xcodebuild -version`）、哪个提交、`Scripts/verify.sh`
的汇总行原文、`codesign`/`spctl`/`stapler` 的输出。下一次讨论"上次是不是真的过了"时，
依据就是这些，而不是记忆。
