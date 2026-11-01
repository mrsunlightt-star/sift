# 从 CleanMyMac 借鉴了三条，跟进在 Sift 里的实现

对照拆解见 [cmm-rule-engine-teardown.md](cmm-rule-engine-teardown.md)。这一篇记录**实际改了什么、
为什么这么改、以及在本机量到的效果**。没有改动 sift 之外的东西。

## 1. 残留的归属：名字延续已安装的标识符，就是那个应用的数据

**问题**（上一轮扫描量到的）：`com.tencent.workbuddy.mac.BundleMigration` 689 MB 被判为
「应用残留，需要你确认」，而 `WorkBuddy.app` 就装在 `/Applications`，标识符是
`com.tencent.workbuddy.mac`。原判据是全名相等，于是凡是「标识符 + 后缀」的目录全部漏网——
helper、updater、ShipIt、BundleMigration 都是这个形状。

**改法**：两个引擎各加一个同语义的判据，
Rust `names_an_installed_application` / Swift `RuleEngine.namesAnInstalledApplication`：
名字等于一个已安装标识符，**或者**在 `.` / `-` 边界上延续了它。
只认边界上的前缀，所以 `com.example.app` 不会认领 `com.example.appleby`；
也不做后缀匹配——尾巴不携带身份。

第二个判据 `is_system_reserved_bundle_name`：`com.apple.` 是保留命名空间。
守护进程（`mediaanalysisd`、`geod`、`BKAgentService`）永远不是「被卸载的应用」，
只会永远匹配不到已安装列表，于是它们的容器和偏好文件被成批当成残留。
本机读数：569 个容器（352 MB）+ 285 个偏好文件。

两个判据都放在 `looks_like_bundle_identifier` 之后、保护检查之前，
顺序在两个引擎里一致，`EngineAgreementTests` 用同一个夹具把两边钉在同一行上。

**效果**（本机文件系统实测，同一套判据重跑）：

| | 改前 | 改后 | 去掉 |
| --- | --- | --- | --- |
| 容器 / 缓存 / Application Support 残留 | 663 | 20 | 643 |
| 偏好文件 / 网页存储残留 | 8149 | 7855 | 294 |

那 689 MB 并没有消失，它现在以「已安装应用的缓存」出现在 `user-cache` 里（`safe`），
而不是一条要用户确认的残留——这正是它本来的身份。

## 2. 日志：一条一条算，而不是一个目录一条

CMM 的 `LogsRemover` 是逐文件清理日志的；Sift 原来的日志规则是「一个目录一条」，
而且只在**目录里每个文件都过期**时才提供。在一个还在用的机器上，这个条件几乎永不成立。

于是新增三条规则（`anyFile` + 跟随用户的过期阈值，默认 30 天，`review`）：

| id | 位置 |
| --- | --- |
| `agent-tool-logs` | `~/.workbuddy/logs` |
| `agent-tool-traces` | `~/.workbuddy/traces` |
| `agent-tool-logs-qoder` | `~/.qoder/logs` |

选这三个是因为它们的形状确实是「每次运行一个文件、从不清理目录」：
`~/.qoder/logs` 有 275 MB / 500 个文件，其中 73 个超过一个月没有被动过，
同时旁边就有刚才那次运行写的文件。其余目录（`packages`、`blobs`、`cli`、`plugins`、
`projects`、`sessions`）是工具本身和它的状态，规则只能看名字和年龄，
看不出「还在用」，所以一条都不加。

## 3. 排除表：别家安全软件的隔离区不是垃圾

CMM 的硬保护名单里有 `Sophos`、`Bitdefender`、`Tresorit`。加进
`PROTECTED_LIBRARY_CHILDREN`（Rust 是源，Swift 由生成器产出）：

```
Library/Application Support/Sophos
Library/Application Support/Sophos Anti-Virus
Library/Application Support/Bitdefender
Library/Application Support/Tresorit
```

理由是不可逆：清掉的隔离区无法重新扫描，丢了历史的杀毒软件会静默地停止工作。
保护列表本来就覆盖 8 个子目录 + 14 个前缀 + 11 个 `~/Library` 子目录，这一条只是补齐同一类。

## 4. 没有跟进的部分，以及原因

| CMM 的做法 | 为什么不做 |
| --- | --- |
| 227 条规则用全功能正则，含负向前瞻（`^/System/Library(?!/…)`） | Sift 的规则必须可枚举、可预算（`MAX_RULE_ROOTS`）；允许任意正则就等于放弃这条。中间态（锚定前缀 + 整段组件）值得做，但要先设计语法与校验，不是这一轮 |
| 规则库加密 + 运行时远程更新 | 与「规则即承诺、`verify.sh` 可校验」直接冲突。机制可借（版本号 + sha256 + 审核状态），实现方向相反 |
| `UniversalBinaryThinner`、语言包删除、文档版本 | 就地改写已安装应用，违反 invariant 1（一切清理走废纸篓） |
| 特权 helper 执行删除 | Sift 承诺无 root、无 shell |
| AI 工具的活跃版本解析、模型分片清单 | 需要一个新的只读清单器（`ActiveVersionResolver` 那一套），是独立的一块工作 |
| `~/` 作为一等锚点 | 现有锚点表已覆盖用户实际会命中的位置，且保护列表是按 `~/Library` 子目录写的 |

## 5. 验证

```
Scripts/verify.sh
  Rust                    252 tests
  Swift XCTest methods    317
  Self-test checks        265
  Xcode unit target       317
  XCUITest methods        8 (ran, 8 executed)
  VERDICT: every check passed
```

新增测试：

* Rust `a_name_that_continues_an_installed_identifier_is_not_residue`、
  `a_system_service_is_never_residue`
* Swift `ProtectionTests.test_aNameThatContinuesAnInstalledIdentifierBelongsToIt`、
  `test_aSystemServiceNameIsReserved`
* `EngineAgreementTests.test_theTwoEnginesAgreeAboutANameThatContinuesAnInstalledIdentifier`
  ——两个引擎对同一批夹具必须给出同一行
* `SettingsTests.test_theScratchSuiteCannotBeMistakenForAnApplication`（见第 7 节）

生成物同步：`CleaningRules.json` / `BuiltInRules.swift` 由 `generate-rules.py` 产出（26 条规则），
`ProtectedPaths.swift` 由 `generate-protection.py` 产出（11 个 `~/Library` 子目录）。
`bootstrap.sh` 还顺带重新生成了 `Sift.xcodeproj`，补上了此前漏进项目的测试夹具与
`TrashServiceTests`（172 行既有漂移）。

## 6. 下一步（按顺序）

1. **测试产物泄漏**：`~/Library/Preferences` 里 7552 个 `sift.tests.*.plist` 是
   `Tests/EntitlementTests.swift:26` 那类 UserDefaults suite 留下的，teardown 没有删除。
   它让本机每次扫描的残留列表多出 7.8 千行自家垃圾——也是上面 7855 这个数字的主要成分。
2. **具名层规则**：`~/.codex/packages`（2.6 GB）、`~/.workbuddy/blobs`（747 MB）这类位置，
   要么定成只读清单器，要么明确写进注释说明为什么不做。
3. **正则子集的语法与校验**：只允许 `^name(/.*)?$` 这一族，加载时编译并断言不以 `*` 开头。

## 7. 附带修掉：测试套件的偏好域泄漏

上一轮把残留列表从 8149 条压到 7855 条时，剩下的部分几乎全是仓库自己造成的。

**成因**：`UserDefaults(suiteName: "sift.tests.<uuid>")` 给每个测试一个持久域，
而 `removePersistentDomain(forName:)` 只清键不删文件——实测：删掉文件后它立刻消失，
1.5 秒后 `cfprefsd` 又把空的 `{ }` plist 写回来（进程还活着时必然如此）。
于是每跑一次测试就多几个文件，本机累计 **7866 个**（4609 `entitlement`、2348 普通、
670 `environment`、238 self-test，共 323 KB，除两个带时间戳的之外全是空文件）。

**影响**：`~/Library/Preferences` 是残留扫描的五个位置之一，而
`sift.tests.entitlement.<uuid>` 是三段式名字，正好过 `looksLikeBundleIdentifier`。
产品的扫描页因此把自家的测试产物列成「需要你确认的残留」——
8108 条偏好残留里 7789 条是它。

**修法**：`Tests/ScratchPreferences.swift`——每个测试类一个**稳定**域名
`sifttests-<class>`，`setUp` 与 `tearDown` 都 `reset`；名字不带点，
三段式判据不再命中，所以留下的那个空 plist 永远不会被当成应用。
`SelfTest` 同样改成 `sifttests-selftest`。

**清理**：删掉现存 7866 个文件，`~/Library/Preferences` 里 `sift.*` 归零；
现在只剩 4 个 42 字节的空域文件，数量与运行次数无关。

**回归保护**：`SettingsTests.test_theScratchSuiteCannotBeMistakenForAnApplication`
（稳定 + 不含三个点）。

## 8. 覆盖面：两家鸿蒙 SDK 的闲置组件（+5.3 GB）

第 2 节只补了日志，因为开发工具自身的状态目录（`packages`、`blobs`、`cli`）不是垃圾。
真正缺的是**已经装过、又很久没读的 SDK 组件**，而这一类在表里早有先例
（`android-sdk-idle-components`：`Android/sdk` + 具名组件 + 90 天）。

按同一个形状补了两条，锚点和阈值都来自实测：

| id | 位置 | 具名组件 | 本机命中 |
| --- | --- | --- | --- |
| `harmonyos-sdk-idle-images` | `~/Library/Huawei/Sdk` | `system-image` | 1 项 / 4.4 GB（`HarmonyOS-6.1.1` 手机镜像） |
| `openharmony-sdk-idle-components` | `~/Library/OpenHarmony/Sdk/*` | `previewer`、`toolchains`、`js`、`ets`、`native`、`system-image` | 4 项 / 829.6 MB |

`licenses` 与 `productConfig.json` 故意不具名：几十 KB，重新接受一遍许可就是代价，
这个交易不值得为 24 KB 做。两条都是 `review` + 90 天，理由是同一台机器上它们自六月起
没被读过，而 `audit-coverage.py --age-sweep` 已经证明 180 天在同类目录上什么都找不到。

审计口径的前后：**23 条规则 / 342 条目标 / 12.3 GB** → **28 条规则 / 469 条目标 / 17.6 GB**。
