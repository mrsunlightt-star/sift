# 安全复审与逐项修复（2026-11-07）

复审覆盖全部 153 个源文件（约 7.2 万行）：`RustCore/crates/*`（5 crate）、`Core/`、
`Features/`、`Shared/`、`App/`、`Scripts/`、`.github/`、`project.yml`。工具链为阿里开源
OpenCodeReview（`ocr` 1.13.2，delegate 模式：ocr 负责文件选取与规则匹配，审查由宿主
agent 执行），四个区域并行审查，安全关键路径（FFI、进程调用、删除、授权、规则解析）
逐文件人工复核，关键发现均经源码二次核实可达性。

复审结论：**无 Critical / High；3 Medium、9 Low（其中 1 条为记录性接受项）**。
上一轮审计（`security-audit-2026-11.md`，35 条）与 2026-11-04 复核的修复经抽查
**全部仍在位**（H1 零挂起点、H3 `validate_scope`、M4 init 收紧、CI audit + ASan）。

约定：
- 严重级别取自"若在发布版触发，用户会损失什么"，不是利用难度。
- 位置写的是**修复前**的行号；修复后以文件为准。
- 本轮不新增源文件，无需重新生成 Xcode 工程；Rust 改动经
  `Scripts/build-rust-core.sh` 重建归档后由两套测试共同验证。

## 清单

| 编号 | 级别 | 区域 | 位置（修复前） | 症状 | 修复 |
|---|---|---|---|---|---|
| R1 | Medium | Rust 门禁 | `sift-scanner-core/src/coordinator.rs:764`；`sift-ffi/src/lib.rs:525` | `duplicates.roots` 的过滤条件是 `request.roots.is_empty() \|\| …`：请求声明空 `roots` 时该过滤整体失效，重复文件扫描的根只做保护列表过滤，可指向白名单外树并写入路径与 BLAKE3 摘要。注释自称 "The ABI is a trust boundary too"，此条直接违反该声明 | 见下方落地记录 |
| R2 | Medium | Swift 删除 | `SettingsStore.swift:245`；`RustScannerEngine.swift:83,93` | 三处应用自有目录用裸 `FileManager.removeItem`（跟随祖先符号链接）+ `try?` 吞错后仍报成功。仓库为此专门写了 `OwnedLocationRemoval`，但只剩 `ReportService` 一处接上；其文档自称"三处服务使用"，与实现脱节 | 见下方落地记录 |
| R3 | Medium | CI | `.github/workflows/ci.yml:13,62,78,213` | `actions/checkout@v4`、`actions/upload-artifact@v4` 为可变 tag 引用：上游被覆盖时下一次 push 自动执行被替换代码 | 见下方落地记录 |
| R4 | Low | Swift 扫描 | `SwiftScannerEngine.swift:628` | `measureMatching` 缺 `FileWalker.measure` 的跨卷 device 检查，规则目录下挂载的卷会被越界读取（后果限于漏报与隐私边界，不误删） | 见下方落地记录 |
| R5 | Low | Rust 遍历 | `dir_lister.rs:106-124` | 超时遗弃的 worker 线程无全局上限，卡死卷上每个超时目录泄漏一个线程；`spawn_worker` 的 `expect` 是生产 panic 路径（有 catch_unwind 兜底，但宜消除） | 见下方落地记录 |
| R6 | Low | Rust 规则解码 | `sift-rules/src/lib.rs:800` | 规则 JSON 无宽度/大小上限；防栈溢出隐式依赖 serde_json 默认 128 层递归限制（未启用 `unbounded_depth`），该前提无注释锁定 | 见下方落地记录 |
| R7 | Low | Rust API | `sift-hasher/src/lib.rs:38` | `CancelToken::clone` 拷贝状态而非共享句柄，与类型名暗示相反；公共导出类型，下游 `.clone()` 会静默丢失取消能力 | 见下方落地记录 |
| R8 | Low | Rust panic 面 | `coordinator.rs:182` | `poll_events`（FFI 直调路径）里 `queue.remove(index).expect(...)`，不变量当前成立但有 FFI 层 catch_unwind 之外更防御的写法 | 见下方落地记录 |
| R9 | Low | 脚本供应链 | `Scripts/security-audit.sh:76` | 缺失时 `cargo install cargo-audit`（未固定版本）：审计闸门自身未固定上游 | 见下方落地记录 |
| R10 | Low | 脚本 | `Scripts/install-xcode.sh:68-99` | 解压出的 `.app` 未做签名校验就以 `sudo xcode-select` 指向它；脚本接受任意路径的 `.xip` | 见下方落地记录 |
| R11 | Low | Swift 隐私 | `TrashService.swift:271` | 失败消息用 `NSError.localizedDescription`（可能携带文件名），与 `FileOperationService.message(for:)` 的脱敏模式不一致 | 见下方落地记录 |
| R12 | Low（记录） | 签名 | `Scripts/build-app.sh:200` | ad-hoc designated requirement 只绑定 identifier（本机同 identifier 应用可继承 Keychain ACL 与 TCC 授权）。已知取舍，release 流程换 Developer ID 时闭合 | 脚本输出补充提示，其余不动 |
| R13 | 记录 | 构建 | `project.yml:37` | `ENABLE_USER_SCRIPT_SANDBOXING: NO`：preBuildScript 以完整用户权限运行，`Scripts/` 应视作特权代码审查。构建需要，不修改 | 无动作，登记 |

## 核销清单（复审未发现问题的面）

- **进程注入**：全 App 仅 `SystemQuery.swift` 一处 `Process()`，固定路径/参数、无 shell、超时 + SIGKILL 兜底。
- **FFI 内存安全**：25 个入口点 panic 拦截全覆盖（3 个平凡函数除外）；boxed slice 交接、`SiftString` 生命周期、`UInt32(clamping:)` 均正确。
- **Rust unsafe**：4 处均最小化且 SAFETY 注释准确；无 transmute / static mut / 手写 Send+Sync。
- **路径绕过**：`..`、绝对 relativePath、join 替换语义、前缀边界、符号链接（O_NOFOLLOW / symlink_metadata）、别名归一化——三层防御完整且有测试。
- **隐私**：UI 层零日志；报告去标识化、进度只留叶名、错误消息路径消毒（不变量 7）。
- **凭据**：Keychain 存储正确、DEBUG 门控正确、掩码显示；仓库无嵌入凭据（`SIFT-DEV-*` 为文档化设计）。
- **CI**：无 `pull_request_target`、无 secrets 暴露、无缓存投毒面；cargo audit + ASan 在位。
- **供应链**：二进制不入库、`Cargo.lock` 已提交、脚本 subprocess 一律列表传参、路径全带引号。

## 落地记录（同一轮修复）

全部 12 条已改（R13 为记录性接受项，无动作）。分三个互不重叠的写入范围完成：

| 范围 | 条目 |
|---|---|
| `RustCore/`（4 crate） | R1 R5 R6 R7 R8 |
| `Core/`（Swift） | R2 R4 R11 |
| `Scripts/` + `.github/` | R3 R9 R10 R12 |

- **R1** — `sift-scanner-core/src/coordinator.rs`：重复文件扫描的根在进入"cleanable 根包含"测试之前，先过与 `Engine::start_scan` 门禁相同的范围白名单（home 内、`/Volumes/` 内、`/Library/Logs`、会话临时目录形状）。空 `roots` 不再使包含测试整体失效。测试：`sift-ffi/tests` 中 `a_crafted_empty_root_list_cannot_wander_outside_the_allowlist`（home 树内外的两组重复文件，断言只有 home 内的组入索引）。
- **R2** — `OwnedLocationRemoval` 泛化：`remove(at:)` 拒绝**任意层级**祖先上的符号链接（词法-解析比较经 `RuleEngine.normalize`，与 pre-flight 重定位检查同一套调和，macOS 别名 `/var→/private/var` 比较相等，`/var/folders` 下的测试夹具不误拒）；拒绝理由改名 `.ancestorIsSymbolicLink`；新增只读判定 `ancestorsSpellTheLocation` 供写入方在写之前询问。三处接线：`SettingsStore.clearHistory`（改走防护，失败记录日志而非吞掉报成功）；`RustScannerEngine.prepareIndexDirectory`（清扫前先判定祖先链，逐条删除走防护）；`removeIndexArtifacts`（逐个附属文件走防护）。文档从"三处服务"改为与实际一致的四处。测试：`test_ownedLocationRemovalRefusesASymbolicLinkAboveTheParent`（祖父级链接，旧检查放行的形状）、`test_clearingHistoryRefusesARepointedSupportDirectory`。
- **R3** — `.github/workflows/ci.yml`：`actions/checkout` 固定 `11bd719…`（v4.2.2）、`actions/upload-artifact` 固定 `ea165f8…`（v4.6.2），四处引用全部按 commit SHA 固定并注释版本。
- **R4** — `SwiftScannerEngine.measureMatching` 在符号链接检查之后加 `FileWalker.device(of:)` 比较，与 `FileWalker.measure` 同一顺序、同一原语：挂载点处停下，不再越卷读取。
- **R5** — `dir_lister.rs`：每个 lister 用 `AtomicUsize` 统计存活 worker（worker 退出时自减，含迟到的被遗弃者），超过 `MAX_ABANDONED_WORKERS`（64）后不再孵化，目录按超时语义跳过；`spawn_worker` 失败降级为跳过而非 `expect` panic，`list` 里两处 `expect("worker present")` 一并消除。测试：`a_lister_stops_spawning_workers_once_the_leak_budget_is_spent`。
- **R6** — `sift-rules/src/lib.rs`：新增 `MAX_RULE_JSON_BYTES`（1 MiB），`RuleSet::from_json` 在解析前拒绝超限文档（新错误变体 `RuleError::TooLarge`，报出实际大小与上限）；serde_json 递归限制的前提（未启用 `unbounded_depth`）写进文档注释锁定。测试：`a_document_past_the_size_cap_is_refused_before_it_is_parsed`。
- **R7** — `sift-hasher` 的 `CancelToken` 改为 `Arc<AtomicBool>`，`Clone` 共享同一标志（`a.clone()` 后 `a.cancel()` 取消双方）；`sift-ffi` 里"克隆复制值"的过时注释一并更正。测试：`a_clone_shares_the_flag_with_its_original`。
- **R8** — `coordinator.rs` 的 `poll_events`：`queue.remove(index).expect(...)` 改为显式 `Some/None` 匹配，`None`（今天不可达）跳过而非 unwind。
- **R9** — `Scripts/security-audit.sh`：`cargo install cargo-audit` 固定 `--version 0.22.2 --locked`（与本机在用版本一致），提示行同步；升级改为脚本内的显式编辑。
- **R10** — `Scripts/install-xcode.sh`：解压出的 `.app` 在移入 `/Applications` 之前先 `codesign --verify --deep --strict -R="anchor=apple"`，不是 Apple 签的拒绝安装。
- **R11** — `TrashService.empty` 的失败行改用 `FileOperationService.classify` 映出的错误码本地化句子，不再透传 `NSError.localizedDescription`（它可能携带条目文件名）。
- **R12** — `Scripts/build-app.sh` 在签名验证旁打印 ad-hoc DR 的适用范围说明（identifier-only、授予仅限本机、release 换 Developer ID 锚定证书）。

## 验证

- `cargo fmt --all` 无改动意见；`cargo clippy --all-targets -- -D warnings` 干净。
- `cargo test --workspace`：Rust 295 项全过（含本轮新增 4 项）。
- `Scripts/build-rust-core.sh` 重建 `Bridge/macos-universal/libsift_ffi.a`，归档变更按既有机制触摸桥文件、清扫旧链接产物。
- `Scripts/verify.sh`（2026-11-07）：**every check passed** — 生成源检查、Rust fmt/lints 与 295 项测试、benchmark 构建、Swift 构建、Self-test 265 项、Xcode unit target 413 项、XCUITest 8 项（ran, 8 executed，7 passed 1 skipped）、App bundle 装配与签名。
