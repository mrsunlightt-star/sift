# Sift — macOS 清理工具

Sift 是一款不依赖账号、不上传用户文件的轻量 Mac 清理工具，核心流程为「扫描 — 解释 — 确认 — 可恢复清理」。所有清理项默认移入废纸篓，并在删除前展示来源、大小、原因和风险等级。

商业模式：$4.99 一次性买断，永久使用，无订阅。

## 仓库内容

| 文件 | 说明 |
|---|---|
| [sift-macos-cleaner-development-spec.md](sift-macos-cleaner-development-spec.md) | v0.1 开发基线文档：产品定义与范围、功能需求、技术方案、核心数据模型、扫描引擎设计、文件操作与恢复、macOS 权限与沙盒、UI/UX 规格、购买与商业化、隐私与安全、错误码、性能要求、测试计划、版本计划与 MVP 验收标准 |
| `iShot_2026-10-17_10.40.42.png` | 界面稿：智能扫描首页 |
| `iShot_2026-10-17_10.40.53.png` | 界面稿：Mac 状态总览 |

## 功能范围（MVP）

智能扫描、垃圾清理、软件卸载、存储分析、大文件 / 旧文件 / 重复文件扫描、清理结果报告与 PDF 导出、废纸篓恢复提示、官网购买与授权激活、自动更新、设置与隐私说明，以及中文、英文、韩语、俄语、西班牙语、日语、法语、德语八种界面语言。

## 技术栈

- 应用层：Swift 6 + SwiftUI，最低支持 macOS 13 Ventura
- 扫描核心：Rust stable，通过 C ABI + `cbindgen` 与 Swift 桥接
- 扫描索引：Rust 侧 SQLite，Swift 只读取分页结果
- 报告导出：PDFKit
- 购买：官网一次性授权；如后续上架 Mac App Store，使用 StoreKit 2
- 构建：Xcode 16+、Swift Package Manager、Cargo

详细架构分层、FFI 边界与安全规则见开发文档。
