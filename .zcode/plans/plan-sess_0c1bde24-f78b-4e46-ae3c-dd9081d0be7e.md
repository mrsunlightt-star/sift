# 扫描结果页降噪重设计

## Context

截图反馈：扫描结果页太杂乱。按 `desktop-agent-ui` skill 的八条铁律与 `Design/V2/02、05` 规范逐条核对，杂乱来源有四类：

1. **每行元素过载**：每个结果行尾部有 4 个元素（体积 + 展开箭头 + Finder 按钮 + 风险徽章），"可安全清理"组 38 行全部带绿底 + 重复 38 次的"✓ 安全"徽章。
2. **冗余文案**：废纸篓可恢复的解释在页面上出现 3 次；"逐项确认后才可清理"重复组标题；"按类别"是一串含 0 KB 条目的逗号长句；"需确认 0 个项目"零值行；每组的"这个位置需要额外权限。"
3. **中点分隔符**："发现 150 个项目 · 可处理空间 14.68 GB"（翻译串内置）、"38 个项目 · 移入废纸篓（可恢复）"（代码拼接）等。
4. **视觉层级过多**：绿底、绿徽章、绿链接、琥珀徽章同屏竞争。

只动视图与文案，**不改任何模型/选择/预检/分页行为**；`scan.start`、`scan.cancel`、`scan.rescan`、`scan.clean` 等 accessibility id 全部保留（UITests 依赖）。

## 改动

### 1. 结果行 `ScanItemRow`（`Features/Scan/SmartScanView.swift`）

- 行结构收敛为：复选框｜名称 + 路径（两行）｜体积（等宽右对齐）。
- **删除每行 RiskBadge**——风险由分组标题表达；无障碍仍通过 checkbox 的 `accessibilityHint`（risk.detailKey）朗读风险词，不丢语义。
- **删除独立箭头按钮**——行主体点击已切换详情块（invariant 45，无动画展开）。
- **Finder 按钮改为悬停显示**（opacity 0→1，reduce-motion 时不加动画；始终在无障碍树中，context menu 里同样可达）。`DuplicateGroupsCard` 成员行做同样处理（invariant 45 的"每行都有 reveal 控件"仍成立）。
- 第二行去掉"，应用缓存"类别后缀（类别保留在详情块与右栏里）。
- protected 行：复选框位置放锁形图标、文字用 quiet 色——用形状说明"不可选"，不用徽章。
- 保留选中绿底（`selectedWash`，05 §8 规定）与 hover 填充；保留键盘焦点/方向键移动。

### 2. 分组标题

- 可安全清理：标题 + N 项，右侧"默认已选中"（保留，解释预选）。
- 需要你确认：标题 + N 项 + 体积 + 箭头；**删除"逐项确认后才可清理"副行**（标题本身即说明）；展开后的"全选已显示 N 项"链接与确认弹窗保留（安全设计）。
- 系统保护：标题 + N 项。

### 3. 跳过位置卡片 `SkippedLocationsCard`

- 每个目录组压缩为单行（图标 + 路径 + N 项 + 箭头）；删除行下方的"这个位置需要额外权限。"（原因进展开详情）。
- 保留"打开系统设置"链接（仅 actionable 时）与重启提示句（invariant 43 要求）。

### 4. 右栏选择摘要

- 计数行改为纯"38 个项目"（复用 `commonItemCount`），删除"移入废纸篓（可恢复）"后缀——按钮与唯一一条提示承载语义。
- 风险拆分只显示非零行；仅 safe 被选时整段隐藏（计数行已表达）。
- "按类别"长句 → 紧凑两列小行（类别名左、体积右、等宽），只列 `totalBytes > 0` 的条目，去掉"按类别:"前缀（数据来自 `CleanupModel.selectedByCategory`，含 `totalBytes`）。
- 提示收敛为一条废纸篓说明；删除"自动跳过系统文件与受保护路径"与"可在废纸篓恢复，或导出清理报告。"两行。
- 保留：隐藏已选提示（`scanHiddenSelected`）、全选/取消全选、主按钮。
- 窄窗口 `selectionStrip`/`bottomBar` 同步去掉中点拼接，风险行同样只显示非零。

### 5. 页头副标题（去中点，动一处翻译表）

- 在 `Scripts/generate-strings.py` 表中：删除 `scan.header.ready`，新增 `scan.header.reclaimable`——值为现有 34 个语言里该句"·"之后的尾部（如 zh-hans "可处理空间 %@"、en "%@ can be reclaimed"），机械拆分保留各语言措辞。
- 页头渲染两个 quiet 文本段（`commonItemCount.counted(n)` + 新 key），中间留白分隔，无分隔符字形。
- 更新 `Tests/LocalizationTests.swift` 的 `test_theStudySentencesResolveTheirArguments`（改测新 key），然后运行 `python3 Scripts/generate-strings.py` 重新生成 catalog/`.lproj`/`LocalizationKey.swift`。

### 6. 其余中点与重复徽章

- `ScanRunningCard` 里 `Text("·")` 改为间距；`resultSummary`、`hiddenSummary` 的 " · " 拼接改为两段文本（`resultSummary` 去掉 "x of y" 后缀——列表本身有"还有 N 项"行）。
- `Core/UI/DuplicateGroupsCard.swift`：删除每个重复组行的 `RiskBadge(risk: .review)`（136 个同值徽章；卡片标题与 hint 已说明）。

### 不改的东西

筛选 chips、排序菜单、分页/懒加载、选择模型与两道确认弹窗、键盘导航、窄窗口底栏布局、保护/权限卡片的信息结构（invariant 43 的分类陈述）。

## 文件清单

| 文件 | 改动 |
|---|---|
| `Features/Scan/SmartScanView.swift` | 行、分组、右栏、页头、各 summary |
| `Core/UI/DuplicateGroupsCard.swift` | 去每组徽章；成员行 reveal 悬停化 |
| `Scripts/generate-strings.py` | `scan.header.ready` → `scan.header.reclaimable`（34 语言） |
| `Tests/LocalizationTests.swift` | 更新对应断言 |

不新增文件 → 无需 `xcodegen generate`；不改模型/FFI。

## 验证

1. `python3 Scripts/generate-strings.py` 重新生成字符串目录；`Scripts/check-explanation-keys.py` 随 verify 校验。
2. `Scripts/verify.sh`（至少 `--quick`）全绿后提交 `main`（仓库工作流）。
3. `Scripts/build-app.sh` 构建并启动 app，对扫描结果页截图（浅色 + 深色各一张）目视验收：无中点、无每行徽章、右栏无零值行与长句；再核对键盘 Tab/方向键与 hover 显示的 Finder 按钮仍可用。