# Sift 体验诊断与改进方案

审计日期：2026-11-01
审计对象：本仓库 `main`（SwiftUI 外壳 + Rust 扫描核心），不含未提交改动。
方法：三条独立审计线（流程状态机 / 视觉工艺 / 信息架构与文案）逐行读码取证，全部结论带 `文件:行`；配色对比度由 `python3` 按 WCAG 2.1 相对亮度公式实算；文案一律取自 `Shared/Localization/Localizable.xcstrings`（498 key / 34 语言），改写建议单独标注为提案。

总原则：**提升信任感 → 降低认知负担 → 保留 macOS 原生质感**。三者冲突时，信任优先。清理类产品的第一体验不是"好看"，而是"我敢按这个按钮"。

---

## 0. 结论摘要

骨架是好的，且好在意料之外的地方：单一扫描入口 + 全程 single-flight + 代数隔离（`AppEnvironment.swift:692-704`）、pre-flight 快照而非实时选择（`CleanupModel.swift:197-228`）、`review` 项无法被"跳过确认"绕过（`CleanupModel.swift:294-297`）、清空废纸篓前先报计数与大小且 bin 不可读即拒绝（`CleanupResultView.swift:89-99, 272-288`）、取消扫描走 `shutDown` 真释放资源（`RustScannerEngine.swift:289-305`）。这些是同类产品普遍做错的地方，这里做对了。

问题几乎全部落在**"用户看得到的那一层"**，并且有四个系统性缺口：

1. **最终关卡不可核验。** 结果列表有路径，确认面板只有分类聚合 —— 用户在"要动手了"的那一刻，信息量反而比上一屏少（`CleanupConfirmationView.swift:107-129`）。
2. **结果页在事实上不准确。** 主数字写"已释放 10.2 GB"，但字节还在废纸篓里，同一屏还提供"清空废纸篓"按钮（`CleanupResultView.swift:152-173`）。这是整份报告里唯一"说错话"的地方，也是信任成本最高的一处。
3. **过程没有态。** 点清理到结果页之间没有任何 UI（`isWorking` 一把锁）；取消扫描把已发现结果连同索引一起丢掉（`ScanModel.swift:187-203` + `SiftTheme.swift:274-276`）；失败项不能重试（`cleanup.failure.retry` 是死键）、不能定位（`onRevealFailed` 是死参）。
4. **浅色模式整体不达 AA。** 主按钮白字 3.17:1、accent 链接 2.54:1、review 徽标 3.56:1（实算值见 §3.2）；而深色模式 6.99–10.10:1 全部合格 —— 说明配色是按深色反推的，浅色只是把同一色相压在白色上。

另有两条阻断级问题不属于体验设计，但会直接吞掉体验：免费用户**无法完成购买**（购买按钮调用的是激活流程，见 UX-46），以及**导出报告被拦截时先把清理结果销毁**（`RootView.swift:89-99`，见 UX-07）。

---

## 1. 体验问题清单

严重程度：阻断（流程走不通 / 事实错误） / 高（削弱信任或可达性） / 中（明显摩擦） / 低（工艺瑕疵）。

### 一、信任感与安全感

| 编号 | 维度 | 严重度 | 位置 | 问题 | 改进方向 |
|---|---|---|---|---|---|
| UX-01 | 删除前确认 | 高 | `CleanupConfirmationView.swift:107-129` | 确认面板只有按类聚合，无逐项清单、无路径、无 Finder 入口；信息量低于上一屏的结果列表 | 加可展开逐项列表（复用 `ScanItemRow` 只读形态），把手动核验带回最终关卡 |
| UX-02 | 删除前确认 | 高 | `CleanupModel.swift:222-228` + `SiftComponents.swift:332` | 主按钮 label 达 19–24 字（"将 24 个项目移入废纸篓，共 10.2 GB"），`lineLimit(1)` 无缩放，德语/俄语必然截断 | 按钮只留动作，数量与体积移到按钮上方一行 |
| UX-03 | 删除前确认 | 中 | `CleanupConfirmationView.swift:53` + `RootView.swift:157-159` | 面板自身 `padding(24).frame(width: 520)`，宿主再 `padding(24)` 放进 560 → 超约束 8pt | 统一为"卡片 560 / 内容 maxWidth 512"，`frame` 前置到 padding 之前 |
| UX-04 | 删除前确认 | 中 | `CleanupConfirmationView.swift:87-103` | 受保护项只给一句"受保护的位置"无计数；跳过项借用逐项句子渲染成"已被移除: 3" | 两行各给计数 + 首个原因，用复数正确的句式 |
| UX-05 | 可恢复性 | 高 | `CleanupResultView.swift:152-173` | 主数字"已释放 %@"在文件仍在废纸篓时宣称空间已释放，同屏还提供"清空废纸篓" | 改报"已移入废纸篓"，并实测卷可用空间差值；"已释放"只在 bin 空时出现 |
| UX-06 | 可恢复性 | 高 | `CleanupResultView.swift:252-317` | 唯一退路是"在 Finder 中显示废纸篓"，而 bin 里混着用户自己丢的东西，找不到这一批 | 提供"撤销这次清理"（同卷且未清空时逐项放回），否则降级为"在废纸篓中定位这批" |
| UX-07 | 可恢复性 | 阻断 | `RootView.swift:89-99` | 免费用户点导出 → 先 `acknowledgeOutcome()` 销毁结果再弹付费墙，结果与报告一起消失 | 付费墙以 sheet 覆盖在结果之上，并记住回程目标 |
| UX-08 | 风险分级 | 中 | `SmartScanView.swift:483-489` + `SiftComponents.swift:644-678` | 分组/徽标做得好（色+图标+词+句四重冗余），但 `review` 徽标写"需确认"却是可直接勾选的，行为与措辞不完全对应 | 措辞改为描述风险（"通常可以，确认一下"），并在勾选瞬间保持"待你确认"的可见状态 |
| UX-09 | 风险分级 | 中 | `SmartScanView.swift:648-654` vs `598-611` | 底部"全选"作用于整个模型且无二次确认，而 review 组内"全选已显示"有 `confirmationDialog` + 风险提示 | 两个入口共用同一确认与同一作用域（当前筛选的可见可清理项） |
| UX-10 | 权限透明 | 高 | `SettingsView.swift:145-193` | 完全磁盘访问权限塞在"扫描范围"组里，点按钮后把同一段说明再渲染一遍；`permission.grantLater`「暂不授权，继续」是死键 | 权限独立分组 + 用一次 sheet 讲"读什么/为什么/怎么撤销/不授权也能用" |
| UX-11 | 权限透明 | 中 | `permission.fullDiskAccessDetail` | 文案是辩护句（"无需该权限也能…"），不是解释句（"要什么、为什么、能撤销"） | 三段式：要什么 → 为什么 → 怎么撤销 |
| UX-12 | 越界风险 | 中 | `SettingsView.swift:551-557` → `AppEnvironment.swift:1101-1106` | "恢复默认设置"无二次确认，且清空全部已授权文件夹、取消进行中的扫描 | 确认对话框列出影响面 |

### 二、扫描与清理过程

| 编号 | 维度 | 严重度 | 位置 | 问题 | 改进方向 |
|---|---|---|---|---|---|
| UX-13 | 进度诚实 | 中 | `SmartScanView.swift:1147-1153` | 环是 indeterminate（诚实），但环心放 `"2/4"` 在 22pt 数字位，读起来像百分比拨盘；环无 ETA 也没有解释 | 环心改放"已发现大小"（真实单调递增），步数移到环下 caption |
| UX-14 | 进度诚实 | 中 | `SmartScanView.swift:1276-1291, 1288-1318` | 分类条实际是"占最大分类的比例"，用的是 `UsageBar`（进度条外观），视觉上被读成进度 | 改成分担型条形 + 明确"已发现 / 等待 / 完成"文字，弱化进度语义 |
| UX-15 | 进度诚实 | 中 | `ScanModel.swift:567-569` + `SmartScanView.swift:1163-1178` | `currentItemName` 随 200ms 节流的 progress 事件刷新，UI 侧无二次节流，逐文件跳变无法阅读 | ≥600ms 变化才更新 + 等值短路 + 目录级展示 |
| UX-16 | 进度诚实 | 中 | `RustScannerEngine.swift:431` 唯一赋值 | 纯 `swift build` 的 Swift 回退引擎从不写 `currentItemName`，同一页在两种核心下信息量不同 | 回退引擎补齐，或 UI 在该字段空时降级为阶段文案（不要留空 chip） |
| UX-17 | 可中断 | 高 | `ScanModel.swift:187-203` + `SiftTheme.swift:274-276` | 取消 → `.cancelled` → `hasResults` 假 → 页面回落起始卡；索引随后被删，已发现的 N 项**真的丢了** | 取消后保留部分结果并以"已停止"落地（见 P0-5） |
| UX-18 | 可中断 | 中 | `SmartScanView.swift:252-256` + `ScanModel.swift:192-195` | 取消无二次确认；点击后按钮无状态变化，重复点击静默 return；`preparing` 阶段无取消入口 | 按钮切"正在停止…"并禁用；`isPreparingScan` 同样可取消 |
| UX-19 | 可中断 | 高 | `SmartScanView.swift:762-768` + `CleanupModel.swift:329` | 预检 + 执行期间无任何 UI（`isPreparingCleanup` 不参与禁用），确认面板已关，大批次等于"点了没反应" | 执行期 overlay：进度、当前项、软停止 |
| UX-20 | 空状态 | 中 | `SmartScanView.swift:397-402` | 空态不看 `filter`：筛选到"大文件"为空也说"你的 Mac 很整洁，没有缓存、日志或安装包" | 空态按筛选取不同 key（4 种 + 2 种特殊） |
| UX-21 | 空状态 | 中 | `SmartScanView.swift:129-135` | 重复文件空态用 `filesNoDuplicates` 配 `files.requiresAuthorization`（讲的是扫描范围），标题与说明互相矛盾 | 新增 `files.noDuplicatesDetail`，说明"本轮未哈希"而非"没授权" |
| UX-22 | 空状态 | 中 | `Features/Scan` 全目录 | `phase == .partial` 与 `report.isPartial` 在扫描/结果页零呈现；无 skipped 的 partial 完全看不出来 | 页眉状态后缀 + 一句"部分位置未读，结果可能偏少" |
| UX-23 | 空状态 | 低 | `DashboardView.swift:156, 511` | 总览空态同一句 `overview.noResults` 出现两次；`overview.ready`"准备就绪"与"尚未扫描"语义冲突 | 空态收敛成一句 + 一个动作 |
| UX-24 | 结果架构 | 高 | `SmartScanView.swift:441-455, 908-910` | 每组默认只渲染 4 行且 safe 全预选，按钮写"清理 347 项"，可见行可能只有 8 行，无"已选但未显示"提示 | 清理栏明示"已选 N 项（M 项未显示）"+「只看已选」 |
| UX-25 | 结果架构 | 中 | `SmartScanView.swift:127-152` | duplicates 卡片在 `.junk/.large/.old` 过滤下也无条件渲染，选"垃圾"却看到重复文件与它的全选 | 仅 `.all` / `.duplicates` 显示 |
| UX-26 | 结果架构 | 中 | `SmartScanView.swift:800-829` | 换 chip 时先 `items = []` 再填充，列表闪白且无过渡 | 保留旧数组直到新页到达，或外层按 `filter` 做 0.18s 交叉淡入 |
| UX-27 | 结果架构 | 中 | `SmartScanView.swift:302-306` vs `700-710` | 摘要字节/计数来自整轮 report，列表只加载每类 100 行，两个数字不同源 | 摘要注明"共 N 项，已载入 M 项" |
| UX-28 | 结果架构 | 低 | `SmartScanView.swift:501-508` | 折叠行文案"另有 %d 项较小内容"按大小排序时成立，按名称/日期排序时是假话 | 改"另有 %d 项未显示" |
| UX-29 | 结果架构 | 低 | `SmartScanView.swift:1046-1050, 1091-1099` | 路径只有一行截断；"在 Finder 中显示"只在右键菜单里 | 行尾 hover 出 reveal 图标按钮 |
| UX-30 | 执行反馈 | 高 | `CleanupResultView.swift:236-238` | "跳过 %d 项（显示前 20 条）"的 %d 含失败数，列表只渲染 skipped，与上方失败块重复统计 | 两个计数分开，列表与数字同源 |
| UX-31 | 执行反馈 | 高 | 全仓 | 无"重试失败项"入口：`ErrorAction.retry` 只有扫描页接了一处，`cleanup.failure.retry` 是死键 | 结果页给"重试这 N 项"，走子集 plan 重跑 |
| UX-32 | 执行反馈 | 中 | `CleanupResultView.swift:125-130` | 清空废纸篓部分失败只剩一句"部分完成"，逐项 message 被丢弃 | 列出前 5 条失败项 + 原因 |
| UX-33 | 执行反馈 | 中 | `SmartScanView.swift:946-955` + `CleanupModel.swift:275-287` | 点清理的四种结局里 `.nothingToDo` / `.busy` 完全静默；`cleanup.failure` 全仓无视图渲染 | 统一渲染成右侧栏 `NoticeBanner` |
| UX-34 | 执行反馈 | 中 | `SmartScanView.swift:96-98` + `CleanupModel.swift:365-371` | 关闭结果页后列表不重载（`reloadKey` 只依赖 session/filter/sort），已移入废纸篓的行仍在、可再勾选，再清理得到一堆"已被移除" | 加 `listGeneration` 并入 `reloadKey` |
| UX-35 | 执行反馈 | 低 | `SmartScanView.swift:946-950` | 无论从哪个 chip 点清理都记 `.smartScan`，报告与历史名称与所见不符 | 由 `filter` 映射 `CleanupOperationName` |

### 三、信息架构与主流程

| 编号 | 维度 | 严重度 | 位置 | 问题 | 改进方向 |
|---|---|---|---|---|---|
| UX-36 | 首启路径 | 高 | 全仓 `onboard|firstRun|hasLaunched` 零命中 | 没有任何首启流程；落在总览，两个"开始扫描"按钮、旧页名状态行、hero 里硬编码"—" | 一次性首页变体（不是轮播）：范围说明 + 一个主按钮 |
| UX-37 | 首启路径 | 高 | `DashboardView.swift:181` | 点击的同一帧开始扫描，全程没有"将要读哪些目录"的点击前说明 | 起始卡给范围清单（`~` 开头的 3–6 条）+ "只读、不上传" |
| UX-38 | 主界面布局 | 中 | `SiftApp.swift:47,51` + `SiftTheme.swift:344-349` | 最小 1100×720 / 默认 1340×860；1440×900 上默认窗口顶满，1280×800 或缩放模式下超屏；`contentWidthWide 1180 + 摘要列 330` 在最小宽度下压扁 | 最小降到 960×640，摘要列可折叠 |
| UX-39 | 主界面布局 | 中 | `RootView.swift:176-180` | `hiddenTitleBar` 下 rail 顶部的 40pt 产品标记（top 8）与红绿灯区重叠 | rail 顶部让出 28–32pt，或标记下移 |
| UX-40 | 导航层级 | 中 | `RootView.swift:186-214` | 一列 8 项混了四种语义：4 导航 + 2 弹窗 + 1 CTA + 1 导航；页脚 4 项占 232pt | CTA 不占选中态、弹窗用 expanded 语义、页脚收成 3 项 |
| UX-41 | 导航层级 | 中 | `RootView.swift:278` | 未解锁时"解锁 Sift"永远 `isSelected: true`，与当前页选中标记并存 | 用描边/强调色区分 CTA 与选中 |
| UX-42 | 页面职责 | 中 | `DashboardView.swift:171-182` vs `SmartScanView.swift:332-339` | 两个主按钮同 key、同图标、同动作，其中一个还替你跳页；总览给复选框 + "全选安全项"却没有提交入口 | 总览只留一个入口；选择要么能提交，要么标明"到扫描页继续" |
| UX-43 | 设置页 | 高 | `SettingsView.swift:324-345` + `SettingsStore.swift:70-72` | `requireConfirmation=false` 等于跳过确认，**不触发任何警告**（警告只绑 `skipConfirmation`） | 两个开关合并成一个危险项，任一路径都给警告 |
| UX-44 | 设置页 | 中 | `SettingsView.swift:93-100` | `settings.showHiddenFiles` 文案是"结果显示隐藏文件"，但它决定**扫描范围**（不变量 35） | 改"扫描包含隐藏文件" |
| UX-45 | 设置页 | 中 | `SettingsStore.swift:33,66` + `SettingsView.swift:117-141` | `launchAtLogin`/`keepScanHistory` 无 UI（前者无实现）；忽略列表只能删不能加 | 补 UI 或删字段；忽略列表给添加入口 |
| UX-46 | 商业化 | 阻断 | `PurchaseView.swift:231-236` + `EntitlementService.swift:419-421` | 唯一"购买"按钮实际调用 `activate()`，`purchase()` 无人调用；release 下任何 key 都返回"服务不可达" → 免费用户无法解锁 | Buy 接真实通道，激活独立成第二按钮；未接通时按钮自己说清"暂不可用" |
| UX-47 | 商业化 | 中 | `PurchaseView.swift:54` + `AppRouter.swift:96-103` | 付费墙原因横幅用 `", "` 拼两句，`reason.titleKey` 又是页面名 → "扫描, 扫描、分析和预览始终免费…" | 每个 reason 一句独立文案 |
| UX-48 | 文案一致性 | 中 | `trash.empty.message` + `cleanup.result.*` | 唯一不可逆操作的确认按钮是 `common.remove`「移除」，而正文写"永久删除…无法恢复"；"可恢复"承诺在产品里有 4 种说法 | 不可逆按钮改"永久删除"；撤销承诺收敛成一句 |
| UX-49 | 本地化 | 中 | `Localizable.xcstrings` | 34 语言、498 key，**零复数变体**：英文 1 项显示"1 items moved to Trash"；德语按钮字符串普遍 1.8× 英文长度 | 计数 key 加 plural variation + 德语/俄语长度回归测试 |
| UX-50 | 死代码 | 低 | 全仓 | 105 个 key 零引用（含 `permission.grantLater`、`cleanup.result.failed`、`nav.group.*`）、5 个死组件、4 个死令牌（含 `minimumHitTarget`） | 清理或接回，否则设计系统与页面持续分叉 |

### 四、视觉与细节

| 编号 | 维度 | 严重度 | 位置 | 问题 | 改进方向 |
|---|---|---|---|---|---|
| UX-51 | 对比度 | 阻断 | `SiftTheme.swift:36-39` + `SiftComponents.swift:339` | 主按钮白字 on `#009AD9` = **3.17:1**，13pt 不达 4.5:1；深色模式白字 on `#00AEEC` = **2.54:1** 更差 | 填充改 `#007EB2`（4.52:1），深色模式改黑字（8.26:1） |
| UX-52 | 对比度 | 高 | `SiftTheme.swift:22-25` + `SiftComponents.swift:475` | 浅色 accent `#00AEEC` 在白色上 **2.54:1**，却是 30 处链接正文色；选中 chip **2.29:1** | 文本/图标角色改用 `#007FAC`（4.54:1），亮值只留填充与装饰 |
| UX-53 | 对比度 | 高 | `SiftTheme.swift:47-50` | `review` 3.56:1、`safe` 4.07:1、`danger` 4.38:1，三枚徽标文字都不达 4.5:1 | `#AA6709` / `#2C8649` / `#CD4848`（各 4.5:1） |
| UX-54 | 对比度 | 高 | `SiftComponents.swift:365` | 禁用主按钮整块 `opacity(0.45)` → 文字 1.27:1，等于消失 | 只降填充、文字改 `secondaryLabelColor` |
| UX-55 | 对比度 | 中 | `.tertiary` 使用处（含 `scan.running.readOnly`） | 浅色下 tertiary 约 **1.73:1**，而"只读、不上传"这条最重要的信任文案正是 tertiary | 信任类文案提升到 secondary 或自定义 `#6B6B72`（4.5:1） |
| UX-56 | 点击目标 | 阻断 | `SiftComponents.swift:777` | 自定义复选框 18×18，命中区就是 18pt；`minimumHitTarget = 44` 全仓 0 引用 | 外层 44×44 `contentShape`，视觉仍 18pt |
| UX-57 | 语义 | 高 | `SiftComponents.swift:783-784` | 复选框用 `.isSelected` + `accessibilityValue("1"/"0")`：VoiceOver 读成"1，已选中，按钮"，且值不本地化 | 改原生 `Toggle(.checkbox)`，或用 `.isToggle` + 本地化值 |
| UX-58 | 语义 | 高 | 全仓 22 个 `accessibilityLabel` / 8.7k 行 UI | 进度环、图标按钮、rail 解锁项、用量条、结果行均无标签；结果行 6 个元素逐项朗读 | 组件内部自带 label/trait；结果行 `.combine` |
| UX-59 | 动态字体 | 高 | `SiftTheme.swift:367-381` + 306 处 | 零 Dynamic Type：全部固定 `Font.system(size:)`，`.dynamicTypeSize` 0 处 | 令牌改语义字体 + 提供"界面字号"三档兜底 |
| UX-60 | 键盘 | 中 | 全仓 | `focusable` 0 处、无焦点环、结果列表无方向键/⌘A/空格；`SiftSelectableRow` 是 Button 而非 List，丢失 type-select | 关键列表改 `Table`/`List` 或补 `focusable` + `.onKeyPress` |
| UX-61 | 动效 | 中 | `SmartScanView.swift:1161` | 阶段文字硬切（环在转、字在跳），而这是本产品最该有过渡的一次状态跃迁 | `.contentTransition(.opacity)` + `.smooth(0.28)` |
| UX-62 | 动效 | 中 | `SmartScanView.swift:460,476,1419`、`DuplicateGroupsCard.swift:168`、`StorageAnalysisView.swift:604` | 分组/跳过卡/树图展开全部零动画，而 `SiftMotion.settle` 的注释正承诺了这三件事 | `withAnimation(.smooth(0.24))` + 行 `.offset(y:6)` |
| UX-63 | 动效 | 中 | `SiftComponents.swift:908` | 确定性环的动画**没有** reduce-motion 守卫（同文件其余 6 处都有） | `reduceMotion ? nil : SiftMotion.progress` |
| UX-64 | 动效 | 中 | `SiftComponents.swift:259-268` + `RootView.swift:382-388` | `siftAppear` 0.38s + 0.05×index 阶梯，每次切页因 `.id(destination)` 重放，最长 0.53s，叠在 0.20s 页面淡入上 | 仅首次播放；阶梯降到 0.02 |
| UX-65 | 动效 | 低 | `SiftComponents.swift:729` | chip hover 是透明度降到 0.85（变淡），与全站"hover 变亮"相反且无动画 | 改 `hoverFill` + `hover(0.12)` |
| UX-66 | 玻璃材质 | 中 | `SiftTheme.swift:496-502` | `ReduceTransparency` / `IncreaseContrast` / `DifferentiateWithoutColor` 各 0 处，玻璃在降透明度开启后仍全量 | `SiftSurface.material` 分支读无障碍环境值 |
| UX-67 | 原生感 | 中 | `RootView.swift:118-127` + 分四处 | 确认/结果是整窗 ZStack 遮罩而非 sheet：无焦点陷阱、背景仍可点、⌘. 无效；同类"确认"用了 4 种呈现（sheet / 遮罩 / confirmationDialog / alert） | 确认与结果改真 `.sheet`，或补齐 Esc/⌘./焦点陷阱 |

### 五、性能即体验

| 编号 | 维度 | 严重度 | 位置 | 问题 | 改进方向 |
|---|---|---|---|---|---|
| UX-68 | 主线程 | 低 | `ScanModel.swift:523` + `apply` | 事件泵 60ms 轮询、每批 256 事件、`progress`/`itemsFound` 逐个 `@Published` 赋值；总量 8 类 × 每秒十余次重渲染 | 合并一次 `objectWillChange`，或把 `progress` 收敛成 4Hz |
| UX-69 | 浪费 I/O | 低 | `SmartScanView.swift:101-103` + `AppEnvironment.swift:754-757` | 重复组加载了两次 | 只由 `runScan` 负责 |
| UX-70 | 首帧 | 中 | `Features/*` 页面 | 无骨架屏；首帧依赖真实卷查询（`refreshVolumes`），冷启动会先出现"—"再跳数字 | 冷启动用骨架 + 数字 `contentTransition` |
| UX-71 | 大列表 | 中 | 全仓无 `List`/`LazyVStack` 虚拟化（`ScrollView { VStack { ForEach } }`） | 结果页 `pageSize = 100`、`minimumDrainedBatches` 上千项时全量构建视图 | 行容器改 `LazyVStack`（低风险、无视觉变化） |

---

## 2. 具体改进方案（按优先级）

### P0（做完这五条，产品才"可被信任"）

#### P0-1 确认面板升级为"可核验的两栏 sheet"（UX-01/02/03/04/08）

**现状问题**：从有路径的结果列表 → 只剩"3 个分类数字"的确认层，用户在最需要核验的一刻失去了核验能力；按钮 19–24 字；520 装不进 512；受保护/跳过项只有一个孤零零的句子。

**设计目标**：让"我确认的东西"和"会移动的东西"是同一份、看得见、可点开。

**做法**

1. 形态：真 `.sheet(item:)`（不是整窗 ZStack），宽 **640**，最小高 420，内容 `ScrollView`，footer 固定。
2. 结构（自上而下，间距 `spacingL=16`）：
   - 标题：问句 + 量化 → `把这 24 个项目移入废纸篓？`
   - 事实行（3 个 `SiftMetricPill`）：`24 项` / `10.2 GB` / `3 类`
   - 范围行：`将移动的位置` + 3–6 条 `~` 开头路径，超过 3 条折叠为 `+9 处`
   - 折叠区 A：`逐项查看（24 项）` → 复用 `ScanItemRow` 的只读变体（无 checkbox，右侧显示大小 + 风险徽标）
   - 折叠区 B：`为什么可以恢复` → 一句：进入废纸篓，清空前可放回
   - 两行计数：`12 项受保护，不会移动` / `3 项已不存在，自动跳过`
   - footer：左 `下次跳过确认`（checkbox）、右 `取消` + `移入废纸篓`
3. 按钮：**只写动作**。数量与体积放 footer 上方一行，`monospacedDigit`：
   `24 项 · 10.2 GB`（13pt，secondary）/ 按钮 `移入废纸篓`（13pt medium）。
   若必须把数字写进按钮：`移入废纸篓 · 10.2 GB` + `.minimumScaleFactor(0.85)`，并给德语/俄语加 1.8× 长度回归测试。
4. 状态机：

```swift
// Features/JunkCleanup/CleanupConfirmationView.swift
enum ConfirmDetail: Hashable { case items, recoverability }
@State private var expanded: Set<ConfirmDetail> = []
```

5. 文案（改写提案，zh / en）：

| 位置 | 现状 | 提案 |
|---|---|---|
| 标题 | 移入废纸篓？ | 把这 24 个项目移入废纸篓？ / Move 24 items to Trash? |
| 主按钮 | 将 24 个项目移入废纸篓，共 10.2 GB | 移入废纸篓 / Move to Trash |
| 按钮上方 | — | 24 项 · 10.2 GB / 24 items · 10.2 GB |
| 可恢复 | 所有内容都会进入废纸篓，在清空前都可以恢复。 | 进入废纸篓，清空前可随时放回 / To the Trash — recoverable until emptied |
| 受保护 | 受保护的位置 | 12 项受保护，不会移动 / 12 protected, not moved |
| 跳过 | 已被移除: 3 | 3 项已不存在，自动跳过 / 3 already gone, skipped |
| 风险警告 | 你已选中标记为需确认的项目。继续前请检查列表。 | 含 5 项需你确认，展开逐项查看 / 5 need your review |

6. 与不变量的关系：数字仍取 `PreflightReport.ready`（不变量 27），不读实时选择；逐项列表只读，不可勾选。

#### P0-2 结果页不得谎报"已释放"（UX-05）

**现状问题**：`cleanup.result.released` = "Released %@"，绿色 tint 的 `StatTile`，但文件在废纸篓里，磁盘可用空间没变；同屏还提供"清空废纸篓"。

**设计目标**：任一数字都能被用户在 Finder / 磁盘工具里复核。

**做法**

1. 主数字改语义：`已移入废纸篓 10.2 GB`（`cleanup.result.moved`），绿色只用于"全部成功"这个事实，不用于"释放"。
2. 加一个真实测量：preflight 前与执行后各读一次
   `URL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])`（`Core/Diagnostics/VolumeSpaceProvider.swift` 已存在，复用它），展示 `可用空间 +0.0（清空废纸篓后 +10.2 GB）`。
3. "已释放"这个词只允许出现在 bin 为空时：`trash.isEmpty` 才把 label 换成 `已释放` 并显示实测增量。
4. 文案：

| 场景 | 文案（zh / en） |
|---|---|
| 刚移入 | 已移入废纸篓，共 10.2 GB / Moved to Trash, 10.2 GB |
| 副行 | 清空废纸篓后，可用空间增加 10.2 GB / 10.2 GB frees up once you empty the Trash |
| bin 已空 | 已释放 10.2 GB / Freed 10.2 GB |

#### P0-3 结果页三条退路：重试 / 定位 / 撤销（UX-06/30/31/32）

**现状问题**：失败项只能看不能救；不能定位；唯一"退路"是在混着别人文件的废纸篓里翻。

**做法**

1. 每失败行尾部 hover 出 3 个 28pt 图标按钮：`在 Finder 中显示`（接上已存在但未使用的 `onRevealFailed`）、`重试`、`复制原因`。
2. 标题行给主按钮 `重试这 7 项`：用失败项构造子集 plan，重走 preflight → execute；`@State retrying: Set<ItemID>` 防重入；成功项原地移除，失败项累计。
3. 撤销：
   - 生成 batch 记录时同时存 `(trashedURL, originalURL)`（`TrashService` 已有 `entry` 结构）；
   - `撤销这次清理` 只在"同卷 + 未被清空"时可用，逐项 `moveItem` 回原位，失败项进结果行；
   - 否则降级为 `在废纸篓中定位这批项目` → `NSWorkspace.shared.activateFileViewerSelecting(batchURLs)`。
4. 文案：`重试这 %d 项 / Retry %d`、`撤销这次清理 / Undo this cleanup`、`无法撤销（废纸篓已清空或跨磁盘） / Can't undo — Trash emptied or another disk`。

#### P0-4 清理执行期有态可看、有手可停（UX-19）

**现状问题**：点确认到结果页之间没有 UI；`isWorking` 只是禁用按钮。

**做法**

1. `FileOperationService.execute` 增两个参数（`FileOperations` 内部循环头，约 `:529`）：
   `onProgress: (done: Int, total: Int, currentName: String) -> Void`、`shouldStop: () -> Bool`。
2. `CleanupModel` 发布 `executionProgress`（只报"已移 k/n"，不报字节百分比 —— 沿用扫描侧"不发明数字"的原则）。
3. shell 层 `ExecutionOverlay`（复用玻璃层，宽 420）：标题 `正在移入废纸篓`、`ProgressView(value:)`、当前项名（节流 600ms）、`停止` 按钮（软停止：完成当前项后停）。
4. `CleanupOutcome` 增 `stoppedAfter: Int?`；结果页首行 `已停止，已移动 137 项`。
5. 动效：进度条 `.linear(duration: 0.2)`，数字 `.contentTransition(.numericText())`。

#### P0-5 取消扫描不再清零（UX-17/18）

**现状问题**：`cancel()` → `.cancelled` → `hasResults` 假 → 索引被删 → 40 秒白扫。

**设计目标**：取消是"到此为止"，不是"全部作废"；同时不破坏不变量 28（无 verdict 的运行必须报成一种 verdict）。

**做法（推荐 A：双字段表达）**

1. `ScanModel.cancel()` 在 `shutDown()` 之前拉一次 `session.report()`；若有 item，则以 `.partial` 落地 `report`，同时保留 `phase = .cancelled` 与新增 `cancelledByUser = true`。报告与日志仍写"用户取消"，页面拿到的是"部分结果"。
2. 页面判定改为：

```swift
// Features/Scan/SmartScanView.swift
private var hasActionableResults: Bool {
    scan.hasResults || (scan.phase == .cancelled && scan.report != nil)
}
```

3. `AppEnvironment.swift:751-752` 的结果保留条件同步放宽到 `.cancelled && report != nil`。
4. UI：结果页顶部 `NoticeBanner(.information)`：`已停止扫描。以下是停止前找到的 32 项（2.5 GB），仍可清理。` + 页眉 `继续扫描`。
5. 取消按钮：点击后立刻切 `正在停止…` 并禁用，`shutDown` 返回后复原。

文案表：`已停止扫描 / Scan stopped`、`以下是停止前找到的 %d 项 / %@ found before you stopped`、`继续扫描 / Continue scanning`。

#### P0-6 付费层不许"点完再拦"（UX-07/46/47）

1. 购买按钮接真实通道；激活独立成第二个按钮（`激活授权码`），未接通时按钮自己说 `购买暂不可用` 而不是伪装成购买。
2. 付费墙改 `.sheet`，覆盖在结果/结果页之上，不 `acknowledgeOutcome()`。
3. `PaywallReason` 增 `returnTo: AppDestination?`，解锁后回到原页并恢复结果。
4. 免费层把限制**前置**：清理按钮旁 `扫描免费，清理需解锁`（`purchase.licenseRequiredDetail` 已存在），点击后付费墙只讲一句 `解锁后可清理这 347 项`。

---

### P1（做完这七条，体验从"能用"到"顺手"）

| # | 主题 | 关键做法 | 覆盖 |
|---|---|---|---|
| P1-1 | 选择面 = 所见 | 清理栏三段式：`已选 347 项` / `其中 12 项未在列表中显示 · 展开` / 主按钮；底部"全选"收敛到"当前筛选的可见可清理项"并复用同一 `confirmationDialog`；加 `只看已选` 开关 | UX-09/24 |
| P1-2 | 空态矩阵 | 4 类筛选各一套 key + 2 种特殊（部分结果、权限拒）；"磁盘很干净"不庆祝，而给三个事实（扫描位置数 / 读取文件数 / 跳过数）+ `查看扫描范围` + `30 天后再提醒我` | UX-20/21/22/23 |
| P1-3 | 权限解释 sheet | 三段式（要什么 / 为什么 / 怎么撤销）+ 两条出口（打开系统设置 / 先用现在的权限，用回死键 `permission.grantLater`）；回来后 `NoticeBanner.success` + 重新扫描引导 | UX-10/11 |
| P1-4 | 首启路径 | 不做轮播；总览首卡换成一次性变体（范围清单 + 只读声明 + 一个主按钮），首次清理的确认面板加一次性提示"第一次清理，建议展开逐项看一眼" | UX-36/37/42 |
| P1-5 | 进度表达 | 环心 = `已发现 3.2 GB`（monospaced，`.numericText()`），caption = `第 2 步 / 共 4 步`；分类行改"占比"语义（去圆头、降不透明度）；当前项 ≥600ms 变化才更新，并显示 `~/Library/Caches/…` 目录级（`ScanProgress` 增 `currentRoot`） | UX-13/14/15/16 |
| P1-6 | 对比度与无障碍 | 见 §3.2 的数值表（主按钮 `#007EB2`、链接 `#007FAC`、review/safe/danger 加深）；checkbox 44pt 命中 + 原生 Toggle 语义；结果行 `.combine`；语义字体三档；`ReduceTransparency` 降级 | UX-51…60 |
| P1-7 | 裁决后的自洽 | `listGeneration` 并入 `reloadKey`；重试/撤销后同页刷新；结果计数与列表同源 | UX-30/34 |

### P2（结构与工艺）

- **设置页分层**：基础 6 项（扫描范围、授权位置、清空确认、隐藏文件、语言、清除历史）；高级折叠（自定义规则、阈值、诊断、恢复默认）。`requireConfirmation` 与 `skipConfirmation` 合并为**一个**危险项，任何置 false 的路径都出警告（UX-43）。
- **rail 语义**：CTA 用描边不占选中态；popover 用 `.expanded` 而非 `.isSelected`；页脚与导航加分组间距（UX-40/41）。
- **卸载器走 shell 确认**：现在是页面私有 sheet，且确认发生在 preflight **之前**（`AppEnvironment.swift:891`），面板里没有"实际会移什么"。改为复用 `ConfirmationHost` + `PreflightReport.ready`（UX-42 的自然延伸，也是不变量 17 的收口）。
- **文案与本地化**：34 语言复数变体；德语/俄语长度回归（把按钮 label 的最长语言做成快照测试）；不可逆按钮改"永久删除"（UX-48/49）。
- **清理死代码**：105 个零引用 key、5 个死组件、4 个死令牌（UX-50）。
- **窗口与列宽**：最小 960×640；摘要列可折叠；固定列宽 112/74/48 改 `Grid`（UX-38）。

---

## 3. 关键界面线框

### 3.1 主界面（扫描空态，`ScanView.startCard`）

```
┌ rail 112 ─┬───────────────────────────────────────────────────────────────┐
│  [mark]  │  扫描                                        [ 重新扫描 ]      │  頁眉 44pt：32pt 标题 + 右上动作
│          │  扫描，尚未扫描                                              │
│ 总览      ├───────────────────────────────────────────────────────────────┤
│ 扫描 ●    │  ┌─────────────────────────────────────────────────────────┐  │  ① 范围卡（一次性变体）
│ 应用      │  │ ◎  找出可以安全清理的内容                               │  │
│ 存储      │  │    扫描缓存、日志、安装包与残留；删除前逐项说明。        │  │
│          │  │    ── 会读取的位置 ──────────────────────────────       │  │
│          │  │    ~/Library/Caches        ~/Library/Logs               │  │
│          │  │    ~/Downloads            ~/Library/Application Support │  │
│          │  │    [ 开始扫描 ]   只读，不上传 · 完整覆盖需要磁盘访问权限 │  │
│          │  └─────────────────────────────────────────────────────────┘  │
│          │  ┌─────────────────────────────────────────────────────────┐  │  ② 类别预览（8 格）
│          │  │ 应用缓存  系统日志  旧安装包  临时文件  …                │  │
│          │  └─────────────────────────────────────────────────────────┘  │
│          │  ┌─────────────────────────────────────────────────────────┐  │  ③ 范围管理（已有）
│  [外观]   │  │ 你添加的文件夹          只在设置里授权   [ 前往设置 ]    │  │
│  [账户]   │  └─────────────────────────────────────────────────────────┘  │
│  [语言]   │                                                               │
│  [设置]   │                                                               │
└──────────┴───────────────────────────────────────────────────────────────┘
```

要点：① 把"扫什么目录 + 只读 + 需要什么权限"放在**点击之前**（UX-37）；页眉只留一个动作（UX-42）。

### 3.2 扫描中（`ScanRunningCard`）

```
┌────────────────────────────────────────────────────────────────────────────┐
│  ┌──────────┐  本轮目标                                       已用时  00:42   │
│  │   ◔      │  缓存与日志                                     第 2 步 / 共 4  │
│  │ 3.2 GB   │  ~/Library/Caches/com.apple.Safari/WebKitCache                │
│  │ 已发现    │  已遍历 128,430 个文件 · 已发现 3.2 GB                        │
│  └──────────┘                                                              │
│  说明：环心不再放 "2/4"（像百分比），改为单调递增的真实体积                │
├────────────────────────────────────────────────────────────────────────────┤
│  各类已发现                                        5 个类别 · 已完成 2 个    │
│  应用缓存   ████████████████████░░  6.8 GB   已发现                        │
│  系统日志   ██████████████░░░░░░░░  1.9 GB   读取中                        │
│  旧安装包   ████████████████████░░  3.2 GB   已发现                        │
│  临时文件   ░░░░░░░░░░░░░░░░░░░░░░  0.5 GB   等待                          │
│  隐私痕迹   ░░░░░░░░░░░░░░░░░░░░░░  0.8 GB   等待                          │
├────────────────────────────────────────────────────────────────────────────┤
│  🔒 只读取文件名、大小与修改时间，不打开内容、不上传    [ 权限说明 ]  [停止] │
└────────────────────────────────────────────────────────────────────────────┘
```

要点：条形去掉圆头与"进度"暗示（UX-14）；停止按钮有"正在停止…"态（UX-18）。

### 3.3 结果页（`ScanView` resultsWorkspace）

```
┌ 页眉：扫描   结果来自 3 天前 · 46 项 ───────────────────── [ 重新扫描 ] ┐
│ [全部 46项] [垃圾 12.4GB] [大文件 8.2GB] [旧文件 5.1GB] [重复 3.4GB]    │
├───────────────────────────────────────────────┬────────────────────────┤
│ 结果           12.4 GB · 32 项        [按大小] │ 本次清理               │
│ ─────────────────────────────────────────────  │ 10.2 GB                │
│ ● 可安全清理  32 项            默认已选中      │ 24 项 · 移入废纸篓      │
│  ┌──────────────────────────────────────────┐  │ 应用缓存 6.8 · 日志 1.9 │
│  │☑ 应用缓存  ~/Library/Caches 128 个应用   │  │ ──────────────────────  │
│  │            6.8 GB            安全         │  │ 已选 347 项             │
│  │☑ 旧安装包  ~/Downloads 14 个 .dmg 3.2 GB  │  │ 其中 12 项未在列表显示  │
│  └──────────────────────────────────────────┘  │ [展开全部已选]          │
│ ● 需要你确认  14 项        逐项确认后才可清理  │ ──────────────────────  │
│   [ 全选已显示（4 项）]  ← 有确认对话框         │ 废纸篓可恢复，清空前    │
│ ● 受保护  3 项              Sift 不会删除      │ 系统与受保护路径已跳过  │
│ ─────────────────────────────────────────────  │                        │
│ 另有 26 项未显示，共 2.5 GB            [展开]  │ [ 清理 347 项 ]        │
│ ─────────────────────────────────────────────  │ 扫描免费，清理需解锁    │
│ 已选 347 项 · 10.2 GB       [全选][反选]       │                        │
└───────────────────────────────────────────────┴────────────────────────┘
```

要点：右侧栏必须写清"已选 vs 可见"（UX-24）；底部"全选"与 review 组用同一个确认（UX-09）。

### 3.4 确认 sheet（P0-1）

```
┌ Move 24 items to Trash? ─────────────────────────────── 640pt ─────────┐
│  把这 24 个项目移入废纸篓？                                            │
│  [ 24 项 ]  [ 10.2 GB ]  [ 3 类 ]                                      │
│                                                                        │
│  将移动的位置                                                          │
│  ~/Library/Caches · ~/Downloads · ~/Library/Logs        +9 处          │
│                                                                        │
│  ▸ 逐项查看（24 项）                                                   │
│  ▸ 为什么可以恢复                                                      │
│                                                                        │
│  ⚠ 含 5 项需你确认，展开逐项查看                                       │
│  · 12 项受保护，不会移动                                               │
│  · 3 项已不存在，自动跳过                                              │
│  ───────────────────────────────────────────────────────────────────   │
│  ☐ 下次跳过确认                              24 项 · 10.2 GB           │
│                                        [ 取消 ]  [ 移入废纸篓 ]        │
└────────────────────────────────────────────────────────────────────────┘
```

### 3.5 完成页（P0-2/03）

```
┌ ✓ 清理完成 ────────────────────────────────────────────────────────────┐
│  清空前可从废纸篓恢复                                                  │
│                                                                        │
│  [ 已移入废纸篓 10.2 GB ]  [ 24 项 ]  [ 0 项未处理 ]                   │
│   清空废纸篓后，可用空间增加 10.2 GB（当前实测 +0.0）                  │
│                                                                        │
│  ── 未处理 7 项 ────────────────────────────────────────────────       │
│  ⚠ ~/Library/Caches/com.foo/cache  应用占用中   [定位][重试][复制原因] │
│  ⚠ ~/Library/Logs/x.log            权限不足     [定位][授权]           │
│                                     [ 重试这 7 项 ]                    │
│  ───────────────────────────────────────────────────────────────────   │
│  [ 撤销这次清理 ] [ 在废纸篓中定位 ] [ 导出报告 ]        [ 完成 ]      │
└────────────────────────────────────────────────────────────────────────┘
```

### 3.6 空状态（磁盘很干净，P1-2）

```
┌ 扫描   结果来自 2 分钟前 · 0 项 ──────────────────────────────────────┐
│                        ◎                                              │
│                   无需清理                                            │
│        当前范围没有可清理的内容                                        │
│                                                                       │
│   扫描位置 14 处 · 读取 128,430 个文件 · 跳过 2 处                    │
│   [ 查看扫描范围 ]        [ 30 天后再提醒我 ]                          │
└───────────────────────────────────────────────────────────────────────┘
```

要点：不庆祝、不夸张；把"白扫一场"变成"一个有数据支撑的结论"。

---

## 4. 体验验收清单

### A. 信任（每次发版必跑）

- [ ] 确认 sheet 里能找到至少 3 个可核验事实：项目数、体积、位置；展开后能看到逐项路径。
- [ ] 按钮在最长的 3 种语言（de / ru / ar）下不截断、不换行、不缩小到 <11pt。
- [ ] 结果页"已释放"字样**只**在废纸篓为空时出现；否则显示"已移入废纸篓"。
- [ ] 结果页显示的字节数 = `预检 ready` 之和；与 Finder 里废纸篓该批的大小一致（±1%）。
- [ ] 失败项能：定位、重试、复制原因；重试成功后该项从列表消失。
- [ ] 撤销在同卷且未清空时可用；跨卷/已清空时自动降级并说明原因。
- [ ] 免费用户：点清理 → 付费墙以 sheet 覆盖，取消后结果页仍在。

### B. 状态机（并发与中断）

- [ ] 扫描中再点扫描/清理：不产生第二次运行，有可见反馈。
- [ ] 扫描中取消：已发现结果保留并可清理；页眉出现"继续扫描"；RSS 在 3s 内回落。
- [ ] `preparing` 阶段取消：不卡死，回到起始卡。
- [ ] 清理中停止：已移动项计入结果，未移动项保持选中，结果页报"已停止，已移动 k 项"。
- [ ] 清理中按 ⌘Q：重启后不出现半完成状态被当成已完成（结果只由 outcome 赋值）。
- [ ] 两次快速点"清理"：只进一次 preflight（`isPreparingCleanup` 生效）。
- [ ] 确认 sheet 打开时换页/改选择：面板描述仍是 preflight 快照。

### C. 空态与边界

- [ ] 4 个筛选各自为空：文案互不相同，且都不说"整机很干净"。
- [ ] `partial`（有 skipped）与 `partial`（无 skipped，预算耗尽）：都能看出来。
- [ ] 废纸篓不可读（无 FDA）：不给"清空"按钮，给授权引导。
- [ ] 磁盘被拔掉：扫描/存储页各自有失败 + 重试，不显示 0 字节。
- [ ] 0 项结果、1 项结果、10,000 项结果、单项 >100 GB：四种都能渲染且按钮文案语法正确（1 项用单数）。
- [ ] 空文件夹、符号链接目录、无权限目录各一条 fixture 走查。

### D. 视觉与本地化

- [ ] 浅/深色逐页截图比对；`python3` 对比度脚本对 4 个文本角色 + 3 个填充角色输出全部 ≥4.5:1（或 ≥3:1 的大字）。
- [ ] 34 语言各截一张结果页与确认 sheet；de / ru / ar（RTL）为重点。
- [ ] 窗口 960×640 / 1100×720 / 1340×860 / 1440×900 四档，摘要列折叠与展开各一遍。
- [ ] 界面字号三档（小/默认/大）下无截断、无重叠。
- [ ] 玻璃层在"降低透明度"开启时降级为不透明填充。

### E. 可访问性

- [ ] VoiceOver 手测脚本：扫描空态 → 结果列表（逐行应读"名称、路径、大小、风险、是否已选"）→ 清理按钮 → 确认 sheet（应读标题、3 个事实、按钮）→ 结果页。
- [ ] 全键盘完成一次清理：Tab 遍历所有可交互元素、空格切勾选、⌘A 全选、Esc 关 sheet、⌘. 取消。
- [ ] `Reduce Motion` 开启：无循环动画、无数字滚动、无阶梯入场；进度用文字表达。
- [ ] `Increase Contrast` 开启：边框可见、禁用态仍可读。
- [ ] 自绘复选框读作"复选框/已选中"，而不是"1"。

### F. 性能

- [ ] 冷启动到可交互 < 1s（含卷查询）；首帧无"—"闪烁。
- [ ] 扫描 100 万文件：UI 帧率 ≥50fps，当前项文案刷新 ≥600ms 一次。
- [ ] 结果页 10,000 行 + `LazyVStack`：滚动帧率 ≥55fps，内存峰值 <300MB。
- [ ] 清理 5,000 项：执行 overlay 进度平滑，停止后 1s 内可交互。
- [ ] 取消扫描后 3s 内 RSS 回落（索引已删）。

### G. 自动化

- [ ] UITest 新增：`test_confirmSheetShowsItemList`、`test_resultDoesNotClaimReleasedWhileTrashFull`、`test_cancelKeepsPartialResults`、`test_cleanupShowsProgressAndStops`、`test_retryFailedItems`、`test_unlockSheetKeepsResult`。
- [ ] 快照测试：确认 sheet × 4 语言 × 2 外观；结果页 × 2 外观。
- [ ] `Scripts/verify.sh` 全绿，且 UI target 记录到"已执行"（参考 AGENTS.md 对 `did not run` 的规定）。

### H. 不变量回归

- [ ] 不变量 17（唯一扫描入口 / 单飞 / 破坏性槽）、27（快照而非实时选择）、28（无 verdict 的运行报成 verdict）、33（清空废纸篓是唯一永久删除）相关测试仍绿。
- [ ] 取消保留结果的改动不改变 `ScanReport.phase` 的语义（报告仍写 cancelled）。

---

## 5. 需要你补充的材料

我读的是代码与三张设计稿（`sift-redesign/png/*`，均早于当前配色）加两张 10 月 17 日的旧版截图（`iShot_*.png`，侧栏五入口、系统蓝），**没有当前构建的真实截图**。以下信息能显著提高结论精度：

1. **当前构建的 6 张截图**（浅/深各一份）：扫描空态、扫描中、结果页、确认 sheet、结果页、干净空态。代码结构我已读全，但间距与拥挤程度必须看图才能判断。
2. **总览页与存储页各一张**（含冷启动首帧）。
3. **免费层完整序列录像**：点清理 → 付费墙 → 取消 → 回程（我要确认 UX-07 的实际观感）。
4. **是否有意保留 34 语言**：若是，把"按钮字符串长度上限"作为硬约束写进 `generate-strings.py` 的检查项。
5. **是否允许改 FFI 接口**：P1-5 需要 `ScanProgress.currentRoot`（目录级展示），`fraction` 字段目前是死字段（`types.rs:405-408` 硬编码 `None`），可以顺手删掉或接上。
6. **产品意图澄清**：`purchase.buyButton` 现在调用 `activate()`。这是刻意（先做激活、后接商店）还是错误？它决定了 P0-6 是"修文案"还是"修流程"。
7. **是否要我直接动手**：以上 P0 五条我可以直接落成代码 + 测试（不动 Rust 侧的前四条）。说一声就从 P0-2（结果页不谎报）开始，它影响面最小、信任收益最大。

---

## 6. 实施状态（2026-11-01 第一轮）

总原则没有变；这一节记录**哪些已经落到代码里**，以及没落地的那些为什么还没落地。构建与 333 项测试在改动后全绿（`Scripts/run-tests.sh`）。

### 6.1 已完成（45 项）

| 编号 | 落点 |
|---|---|
| UX-01 | `CleanupConfirmationView.swift` 重写：640pt 固定宽、逐项只读清单、位置行、三条计数行 |
| UX-02 | 主按钮只写动作（`cleanupConfirmMoveAction`），数量与体积另起一行；`minimumScaleFactor(0.85)` |
| UX-03 | 视图自己定宽 640，宿主不再叠加 padding（原先超约束 8pt） |
| UX-04 | 受保护 / 已不存在 / 已被包含 三行分开计数 |
| UX-05 | 结果页主指标改「已移入废纸篓」；`availableCapacity()` 实测可用空间；「已释放」只在 bin 为空时出现 |
| UX-06 | `FileOperationService.restore(_:)` + `undoLastCleanup()` + 结果页「撤销这次清理」 |
| UX-07 | shell 改成单一 sheet 槽：导出被付费墙拦截不再 `acknowledgeOutcome()`，结果留在原处 |
| UX-09 | 底部「全选」与 review 组共用同一个 `pendingSelectAll` 与同一个 dialog，作用域都是「当前筛选可见可清理行」 |
| UX-10/11 | `FullDiskAccessSheet`：三段式解释 + 两条出口（打开系统设置 / 先用现在的权限）+ 回来后的提示 |
| UX-13 | 环心改「已发现大小」，caption 改「第 N 步 / 共 4 步」；右侧重复的步数改回阶段名 |
| UX-14 | 分类条 4pt 高、0.7 透明度，明确是「占比」而非进度 |
| UX-15 | 当前项 600ms 前沿节流 + `scan.currentItem` 句式（「正在检查：X」） |
| UX-17/18 | `ScanModel.cancel()` 改为让引擎自己发终止汇总（保留 itemCount / 走过文件数），停止按钮有「正在停止…」态 |
| UX-19 | `CleanupExecutionView`：进度、当前项、软停止；`execute` 增 `onProgress` / `shouldStop` |
| UX-20 | 空态按筛选分四种文案 |
| UX-21 | `files.noDuplicatesDetail` 专用说明，不再借用授权文案 |
| UX-24 | 清理栏显示「有 N 项已选中但未显示在此列表」 |
| UX-25 | 重复文件卡只在「全部」筛选下出现 |
| UX-26 | 换 filter 时先收集新行再替换，列表不再闪白 |
| UX-29 | 行内 hover 出现「在 Finder 中显示」 |
| UX-30 | 跳过计数改用 `skippedResults.count`，与列表同源 |
| UX-31 | 结果页「重试这 N 项」：子集重跑 preflight + execute，与旧 outcome 合并去重 |
| UX-33 | 点清理的四种结局都有反馈（`cleanup.busyNotice` / `cleanup.nothingToDo`） |
| UX-34 | `CleanupModel.listGeneration` 并入 `reloadKey`，清理后的行不再留在列表里 |
| UX-35 | `ScanFilter.operationName`，报告与历史名随筛选 |
| UX-36/37 | 不做轮播；起始卡列出四个将读取的位置 + 「只读、完整覆盖需完全磁盘访问」 |
| UX-38 | 最小 960×640，默认 1280×820 |
| UX-39 | rail 顶部标记让出 28pt，红绿灯不再压在产品标记上 |
| UX-40/41 | CTA 不再 `isSelected: true`；外观/语言 popover 不再打 `.isSelected` 无障碍 trait；hover 曲线统一 0.12 |
| UX-42 | 总览建议项改只读预览 + 「查看扫描结果」，不再有无法提交的复选框 |
| UX-43 | 两个确认开关合并为一个（`showsConfirmationPanel`），关闭即出警告 |
| UX-44 | 隐藏文件开关文案改「扫描包含隐藏文件」，删掉误导性副行 |
| UX-46 | 「激活授权码」与「去官网购买」拆开；无 `SiftStoreURL` 时明说暂不可用 |
| UX-48 | 清空废纸篓的确认按钮改「永久删除」 |
| UX-51…55 | 新增 `accentText` / `accentFill` / `onAccent` / `safeText` / `reviewText` / `dangerText` / `subtleText` 七个文本角色，全部 ≥4.5:1；链接、徽标、徽章、禁用主按钮改用它们 |
| UX-56 | 复选框命中区 44×44（视觉仍 18pt，用 13pt padding + 负 padding 不影响布局） |
| UX-57 | 去掉 `accessibilityValue("1"/"0")`，改用 `.isSelected` trait，VoiceOver 用系统语言读「已选中」 |
| UX-58 | 结果行名称/路径/说明合并为一个朗读单元，尺寸块合并；进度环接受 `spokenLabel`/`spokenValue` |
| UX-62 | 分组展开、重复组展开、chevron 旋转统一 `SiftMotion.expand`（0.24 smooth） |
| UX-63 | 确定性环动画补上 reduce-motion 守卫 |
| UX-65 | chip hover 改「变亮 + 0.12 动画」，不再变淡 |
| UX-66 | `SiftGlassCard` 读 `accessibilityReduceTransparency`，开启时用不透明填充 |
| UX-67 | 确认 / 执行 / 结果改成同一槽位的真 `.sheet`：Esc、⌘.、焦点都由系统管理 |
| UX-71 | 扫描结果列表改 `LazyVStack` |
| 新增 UX-72 | 受保护路径不再被报成「无法访问」并引导去开权限：卡片标题按原因取名，全为保护时用 `permission.protectedTitle` |

### 6.2 未完成（27 项），按原因分组

**A. 需要引擎/ABI 改动（影响面大，单独一轮）**
- UX-16 Swift 回退引擎不写 `currentItemName`：`SwiftScannerEngine.swift:94` 起从未赋值。P1-5 的「目录级进度」还需要 `ScanProgress.currentRoot`（FFI 加字段）——本轮用「正在检查：文件」句式替代，目录级留待下一轮。
- UX-17 的完整形态：取消后**可清理的清单**需要 Rust 侧在取消时保留索引（`coordinator.rs:545` 的 `remove_index_files` 在 worker 结束时删库）。本轮实现的是「保留汇总数字」，页面上明确说明拿不到清单。改引擎语义要先改 AGENTS.md 的不变量 28。

**B. 需要跨文件的系统性迁移**
- UX-59 Dynamic Type：306 处 `Font.system(size:)` 要换成语义字体，并给三档「界面字号」兜底。这是一次独立重构。
- UX-60 键盘导航：结果/应用列表从 Button 换 `List`/`Table` 或补 `focusable` + `.onKeyPress` + ⌘A/空格。
- UX-49 复数变体：生成器目前不支持 `variations`，34 语言 × 计数 key 的复数规则要先进生成器。
- UX-50 死代码：105 个零引用 key、5 个死组件、4 个死令牌。要改生成器表 + 全仓确认，单独一轮。

**C. 本轮未及的页面级改动**
- UX-12「恢复默认设置」仍无二次确认。
- UX-22 `partial`（预算耗尽型）仍无呈现。
- UX-23 总览空态同一句仍出现两次（只改了页眉状态）。
- UX-27 摘要字节来自整轮 report、列表只载每类 100 行。
- UX-28「另有 N 项较小内容」按名称排序时仍不成立。
- UX-32 清空废纸篓部分失败仍只有一句。
- UX-45 `launchAtLogin` / `keepScanHistory` / 忽略列表入口。
- UX-47 付费墙原因横幅仍用 `", "` 拼接。
- UX-64 `siftAppear` 每次切页仍重放。
- UX-68 事件泵仍是每条事件一次 `@Published`。
- UX-69 重复组疑似仍加载两次（未复核）。
- UX-70 无骨架屏（本轮用「—」缓解首屏空白）。
- UX-61 阶段文字加了 `contentTransition`，但缺一层 `withAnimation` 包裹，效果打折。

**D. 需要产品决策**
- 卸载器仍用页面私有 sheet、且确认发生在 pre-flight 之前（不变量 17 的收口）。改它要动 `AppEnvironment.swift:891` 的顺序，和卸载流程的 `nothingToDo/busy` 反馈一起做。
- 首次清理的一次性提示（`scan.firstRun.review`）需要「是否清理过」的持久化标志，属于设置模型加字段。

### 6.2b 第二轮补上的（10 项）

| 编号 | 落点 |
|---|---|
| UX-22 | 页眉状态加部分结果后缀；两种 partial 分开说（权限跳过 → `scan.phase.partial`，预算截断 → 新增 `scan.partialBudget`，34 语言） |
| UX-27 | 摘要与列表对不上时并列写：`… 419 项 · 已载入 100/419`（复用 `common.of`） |
| UX-28 | 「另有 N 项较小内容」只在按大小排序时说；其它排序改中性「N 项 · X GB」 |
| UX-32 | 清空废纸篓的部分失败改为逐条列出（前 5 条 + 计数），不再只有一句「部分完成」 |
| UX-45 | 忽略列表可添加（`NSOpenPanel`，存 `~` 相对路径）；`keepScanHistory` 有步进器；`launchAtLogin` 从设置模型里删掉，改由 `Core/App/LoginItem.swift` 读系统真实注册状态（`SMAppService`），未打包时整行隐藏 |
| UX-64 | `siftAppear` 阶梯从 0.05×index + 0.38s 收到 0.03×min(index,2) + 0.16s |
| UX-68 | 事件泵不再逐条发布：相位/名称未变且文件数变化 <1% 时跳过赋值 |
| UX-69 | 重复组索引只读一次（删掉 `runScan` 里的那次，保留页面那次） |
| UX-70 | 首屏用 `—` 代替 `0 KB`（部分等价于骨架屏；真骨架未做） |
| — | 卸载确认按钮改「卸载并清理 X」，不再拿问题句当按钮 |

### 6.3 引擎层：停止后的清单现在真的可清理（已做）

`UX-17` 的完整形态已完成。三处改动：

1. **Rust worker 不再删索引**（`coordinator.rs` 的 `run_worker`）：取消时曾经以「这个会话的索引再也不会被读」为前提把 `.sqlite`/`-wal`/`-shm` 删掉 —— 这个前提正是「停止 = 丢掉已发现的一切」的根。现在索引的寿命由持有它的会话决定，Swift 侧释放句柄时才删（`shutDown` / `deinit` / 新一轮替换）。
2. **`finish_cancelled` 报真实汇总**：从索引读 `summary()` 与 `category_totals()`，而不是 `Default` 的空汇总 —— 之前页面有总数没有分类，有分类没有体积。
3. **Swift 保留会话**：`ScanModel.isHoldingStoppedSession`；`hasStoppedResults` 让结果页把停止前的行当普通候选（同样的选择、同样的清理），顶部一条横幅说明「这次扫描是停止的」。再次取消（新一轮或页面丢弃）才真正 `shutDown()`。

不变量写进了 `AGENTS.md` 第 42 条。测试：Rust `a_stopped_scan_keeps_an_index_that_still_pages`（文件仍在 + 汇总带分类 + `page_results` 非空）、Swift `test_aStoppedRunKeepsItsSessionAndItsRows`（脚本化会话：停止后 `shutDownCount == 0`，再次取消后恰为 1）。

隐私面没有变宽：索引仍然只在临时目录里，仍然在会话释放时删除；崩溃残留的窗口与「已完成但未释放」的会话完全相同，不是新增面。

### 6.3b 第三轮：死代码与键盘入口（已做）

- **UX-50 死代码**：目录从 553 key 降到 **447**（−106 个零引用 key，四张表同步删除）；删掉 6 个死组件（`SiftSectionHeader`、`PrimaryActionButton`、`StatTile`、`SiftRow`、`PageHeader`、`BreakdownBar`，含它们的空 `Trailing` 扩展）与 3 个死令牌（`unit`、`sidebarWidth`、`resultListMaxHeight`）。`SiftComponents.swift` 1797 → 1585 行。
  - 过程中踩到一个真问题：我第一版把 `Shared/Localization/` 整个目录排除在「引用扫描」之外，于是 `Localization.swift`（手写辅助代码）里用到的三个 key 被误判成死键删掉，构建当场报错。改成只排除生成文件后重扫，现在「零引用」的计数是可信的（0 个）。
- **UX-60 键盘**：扫描页的「全选 / 取消全选 / 开始·重新扫描」接上 ⌘A / ⇧⌘A / ⌘R（原来这三个动作只能用鼠标）。列表本身的方向键导航仍未做，需要把行容器换成 `Table`/`List`，跟着 UX-59 一起做。
- **UX-16 Swift 回退引擎的当前项**：`SwiftScannerEngine` 现在也发布 `currentItemName`（walk 回调里取叶子名，每 200 个文件采样一次，用锁保护的 `LiveNameBox` 交给 actor 转手发布）。同一个页面在两种内核下的信息量不再不同。
- **UX-23 总览空态**：把「—」从「大小」的位置拿掉，直接给「扫描后，这里会显示可以安全释放的空间。」——一个破折号在那个位置读起来像「0 字节」。

### 6.3c 第四轮：界面字号与键盘可达性（已做）

- **UX-59 界面字号（重写后的问题定义）**：macOS 没有 iOS 那种系统级 Dynamic Type —— `dynamicTypeSize` 只作用于系统自己缩放的文本样式，应用读不到「用户想要更大的字」。所以正确的做法是应用自己给三档：`SiftFont` 的每一档从 `let` 改成读 `SiftTypeScale.current` 的计算属性（13/15/20/32 全部缩放，圆整到整磅），设置页 `界面字号 [小 | 默认 | 大]`，值随 `AppSettings.textScale` 持久化，`bootstrap` 在**第一帧之前**应用，切换时靠根视图的 `.id(language + textScale)` 重建子树。
  - 关键实现细节：`SiftTypeScale.current` 是全局可变状态，Swift 6 下必须处理隔离；选的是锁保护 + `nonisolated(unsafe)`，而不是 `@MainActor` —— 字体在视图构建、PDF 报告绘制与自检代码里都会被读，把它们全钉到主 actor 的代价比这个设置本身大。
  - 验证：`defaults write settings.textScale large` 重启后截图（`Research/shots/20-large-type-settings.png`）确认整页等比放大且不破版；`test_theTypeScaleSurvivesAndHasThreeSteps` 固定三档与持久化。
- **UX-60 键盘可达性（后半）**：`SiftCheckbox` 加 `.focusable()`，于是结果行、总览建议行的复选框进入 Tab 环，聚焦后空格切换（它是 Button），焦点环是系统的。列表的方向键导航仍未做：`.onKeyPress` 是 macOS 14+，而包的目标是 13，要做得把行容器换成 `Table`/`List`，那是一次独立的页面重写。

### 6.3d 第五轮：复数机制与骨架屏（已做）

- **UX-49 复数（能做到的那一半，做对了）**：不引入 ICU/stringsdict 依赖 —— 构建机可能只有 CLT，且目录要保持「一张能读的表」。做法是**兄弟键 + 生成式规则**：
  - `Scripts/generate-strings.py` 新增 `PLURAL_RULES`（每种语言「什么计数算单数」）与 `PLURAL_ONE`（每条被复数化的串的单数写法），生成 `<key>.one` 兄弟键，并同时生成 `Shared/Localization/PluralForms.swift`（`SiftPlural.takesSingular`）——**规则与字符串出自同一个 dict，不可能分叉**。
  - 运行时 `LocalizationKey.counted(_:)`：命中单数就取 `<key>.one`，否则回退基串，调用点可以逐个改（本轮改了 8 个文件的 3 个 key）。
  - 覆盖：`common.itemCount`、`common.fileCount`、`cleanup.result.moved`；en/de/es/it/pt/nl/da/nb/fi/el/he/bg/ar 有真正的单数，fr 与 pt-br 按 CLDR 把 0 也算单数并被测试钉住；ru/uk/pl/cs/ro 用「标签式」措辞（`Элементов: %d`、`Elemente: %d`）本就不需要变格，tr/ja/zh/ko/vi/th/id/ms/hu 名词不随数变化 —— 这些在表里写成 `never`，是**陈述**不是遗漏。
  - 测试：`test_aCountOfOneTakesTheSingularForm`（en/de/fr/pt-br/ru/ja/zh 的 1 与 2，外加 fr 与 pt-br 的 0 分别取单/复）。
- **UX-70 骨架屏**：新增 `SiftSkeletonRow`（两条文字条 + 一个数字条，0.9s 呼吸，尊重 Reduce Motion，VoiceOver 只念一句「正在加载」）；扫描结果首次加载时用它替代那个孤零零的小转圈；总览的磁盘卡在卷查询返回前也不再画一根「0 已用」的空条。

### 6.3e 第六轮：卸载确认前置与首次清理提示（已做）

- **卸载：先判定，再确认**。原来面板先出来、pre-flight 后跑，于是「用户批准的那一批」和「真正移动的那一批」是两份不同的文件——期间启动的应用、消失的关联文件都会改变批次；更糟的是如果 pre-flight 全部拒绝，那次点击什么都不做、也不说话。现在拆成 `prepareUninstall(items:)`（只判定，返回 `count / bytes / refused`）与 `confirmUninstall()`（认领破坏性槽、复核授权、执行**同一个** plan）。面板显示的是 pre-flight 的数字，拒绝原因逐条列出。
  - 顺带修掉一个顺序错误：空批次现在**先**于授权检查返回「无事可做」——把空选择送进付费墙是在撒谎（用户根本没选东西）。
  - 测试：`test_prepareUninstallJudgesTheBatchBeforeAnyoneConfirms`（空批次 → `.nothingToDo`；可判定批次 → `.ready` 的 count/bytes 来自 pre-flight；被拒批次 → 带原因）。
- **首次清理的一次性提示**：`AppSettings.hasCompletedCleanup`（默认 false，`confirmCleanup` 成功后置位），经 `PreferencesSnapshot` 传到面板，只在第一次那批显示一句「确认前建议展开清单看一眼」。测试：`test_theFirstCleanupFlagStartsFalseAndSurvives`。
  - 注：这条文案在我第五轮的死键清理里被误删过（当时它确实零引用），本轮按 34 语言重新写下并接回使用。
  - 两轮踩到同一类测试缺陷：`ScratchPreferences` 的名字是**按测试类稳定**的（为了不把上千个 plist 写进 `~/Library/Preferences`，那会反过来变成扫描结果里的「残留」），独立靠 `setUp` 的 `removePersistentDomain`。我给两个新测试各开了私有 label，`setUp` 清不到，于是「初始值」断言其实断言的是上一次运行的遗留。现在两个测试都用本类的 label，`makeStore()` 统一入口。

### 6.3f 第七轮：结果列表的方向键（已做）

`onMoveCommand` 只会送到已聚焦的 responder，所以做法是：每一行的复选框 `.focused(focus, equals: rowID)`，同时挂 `.onMoveCommand` → 上/下把焦点移到相邻行。没有全局快捷键、没有自绘焦点环——焦点环是系统的，空格照常切换，因为复选框就是 Button。这条路的**失败模式是安全的**：如果事件没有送达，行为退回改前的样子（Tab 遍历 + 空格），不会破坏任何东西。

未做的是「游标高亮一行、但不移动焦点」那种样式；它需要自绘选中态与焦点解耦，收益低于把行容器换成 `List`，留给以后。

### 6.5 收口：72 项的最终状态

- **70 项已实施**，逐条落点见 6.1 / 6.2b / 6.3 / 6.3b / 6.3c / 6.3d / 6.3e / 6.3f。
- **1 项复核后关闭**：`UX-08` 风险徽标措辞。复核结论是它不是缺陷——徽标（安全 / 需确认 / 受保护）与分组标题（需要你确认）一致，`review` 项默认为不勾选，勾选时面板会给出计数警告。把「需确认」改成别的词不会让风险更清楚，只会让文案与分组标题打架。这一条我不改，并记在这里，以免以后被当成漏项。
- **1 项未做**：`UX-46` 的真实收款通道。它需要的不是代码，是一个官网结账页地址与一个许可证验证服务（规格 §12.3）。应用侧该做的已经做了：「激活授权码」与「去官网购买」分开，`Info.plist` 的 `SiftStoreURL` 缺失时明说「这个版本暂不支持应用内购买」，而不是给一个假装能付款的按钮。

### 6.4 剩余项（下一轮）

只剩三类：

1. **系统性迁移**：`UX-49` 复数变体（生成器要支持 `variations`）、`UX-50` 死代码（105 个零引用 key / 5 个死组件 / 4 个死令牌）、`UX-60` 键盘导航（列表换 `Table` 或补 `focusable` + ⌘A / 空格）、`UX-59` 应用内「界面字号」三档（macOS 没有 iOS 式 Dynamic Type，所以要自己做）。
2. **页面级小项**：`UX-16`（Swift 回退引擎仍不写 `currentItemName`）、`UX-23`（总览 hero 仍写「准备就绪」+「—」）、`UX-46` 剩余部分（真实收款通道，属商业决定）。
3. **需要产品决定**：卸载器是否改走 shell 统一确认（要把 pre-flight 提到确认之前）；首次清理的一次性提示要加持久化标志。

### 6.5 验证状态

- `swift build`：通过。
- `Scripts/run-tests.sh`：333 项通过、0 失败（含 FFI 契约、两引擎一致性、预检/执行/撤销相关）。
- `Scripts/generate-strings.py --check`：548 key × 34 语言，与目录一致。
- 截图：`Research/shots/` 下
  - `01`…`07`：改动前基线（总览、扫描结果、应用、存储、扫描中 ×2、扫描旧结果）
  - `09`：改动后总览（建议项改为只读预览 + 「查看扫描结果」）
  - `11`：改动后扫描空态（范围清单 + 「只读 · 完整覆盖需完全磁盘访问」）
  - `12`：改动后扫描中（环心「已发现大小」、`正在检查：X`、占比条、`—` 占位）
  - `15` / `17`：改动后结果页（「结果来自 … · 共 N 项」+ 右侧「有 13 项已选中但未显示在此列表」）
  - `18`：改动后确认 sheet（真 sheet、事实 chip、按类别行、位置行、两个折叠区、按钮只写动作）
  - 未取得：执行浮层与结果页的实拍（需要真的移动文件），这两个由单元测试与代码复核覆盖；要看的话在应用里点一次清理即可。
