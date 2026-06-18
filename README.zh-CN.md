# Sieve GUI for macOS

> Sieve daemon 的 native macOS 守门人壳——常驻菜单栏，在不可逆动作发生前用 HIPS 弹窗强制插入一瞬认知摩擦。

[English](./README.md) | 中文

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![Platform: macOS 13+](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)](#技术栈)
[![UI: SwiftUI](https://img.shields.io/badge/UI-SwiftUI-orange.svg)](#技术栈)

---

## 这是什么

[Sieve](https://github.com/SieveAI-dev/sieve) 是一个完全本地、不联网的 LLM 流量安全代理——单个 Rust 守护进程，坐在你的 AI 编码 agent（Claude Code / Codex CLI / Cursor）与上游模型 API（Anthropic / OpenAI / 中转）之间。它双向检查流量：出站时脱敏密钥，入站时阻拦危险 tool 调用（fail-closed，失败即拦）。

daemon 是非交互的后台进程——**它无法弹窗，也不该弹窗。** 本仓库就是它的视觉延伸。GUI 是人真正与 Sieve 相遇的地方：

- **HIPS 弹窗** —— 接收 daemon 推过来的决策请求，渲染确认面板，在不可逆动作放行前等待用户答复。
- **菜单栏状态** —— 一眼可见的状态指示（normal / warning / hold / paused / disconnected）。
- **历史 / 调试 / 设置 / Onboarding** —— 环绕 daemon 的常驻窗口。

检测逻辑 100% 留在 daemon；GUI 从不发明协议字段，从不改写 daemon 推送的值。daemon 仓库见 [SieveAI-dev/sieve](https://github.com/SieveAI-dev/sieve)，完整产品规格见 [`docs/requirements/sieve-gui-macos-prd-v1.0.md`](docs/requirements/sieve-gui-macos-prd-v1.0.md)。

---

## 技术栈

| 层 | 选择 |
|----|-----|
| 平台 | macOS 13 Ventura+，通用（universal，Apple Silicon + Intel） |
| UI | SwiftUI + Combine（部分场景 AppKit 桥接） |
| 持久化 | SQLite.swift（只读 `audit.db`）+ UserDefaults |
| IPC | `~/.sieve/ipc.sock` Unix Domain Socket，JSON-RPC 2.0 |
| 分发 | hardened runtime + Apple notarization + Sparkle 自动更新 |

栈锁定见 [ADR-001](docs/design/adr/ADR-001-swiftui-native-only-stack.md)，硬约束见 [`CLAUDE.md`](CLAUDE.md)。

---

## 文档地图

```
docs/
├── DOCS-STANDARD.md            ← 文档体系规范
├── glossary.md                 ← 术语表
├── requirements/
│   └── sieve-gui-macos-prd-v1.0.md
├── design/
│   ├── architecture.md         ← GUI 进程架构
│   ├── data-model.md           ← 本地数据模型
│   └── adr/
│       ├── INDEX.md
│       └── ADR-001 … ADR-011
├── specs/
│   ├── INDEX.md
│   └── SPEC-001 … SPEC-008
├── api/
│   └── ipc-protocol.md         ← GUI ↔ daemon 完整 IPC 参考
├── guides/
│   ├── development.md
│   └── deployment.md
└── external/
    └── upstream-references.md  ← daemon 仓库的 PRD/ADR/SPEC 引用
```

新人推荐阅读顺序：

1. 本 README
2. [`docs/requirements/sieve-gui-macos-prd-v1.0.md`](docs/requirements/sieve-gui-macos-prd-v1.0.md)
3. [`docs/design/architecture.md`](docs/design/architecture.md)
4. [`docs/api/ipc-protocol.md`](docs/api/ipc-protocol.md)
5. 按需查 SPEC

---

## 本地开发

完整指南见 [`docs/guides/development.md`](docs/guides/development.md)。简版：

```bash
# 1. 装 Xcode 15+ 和 xcodegen
brew install xcodegen

# 2. 生成 Xcode 工程
xcodegen generate

# 3. 编译 + 测试 Core 库（不依赖 Xcode）
swift build              # 编译 Models / IPC / AuditDB / Logger / Telemetry
swift test               # 跑单元测试

# 4. 完整 App 构建
xcodebuild -project SieveGUI.xcodeproj -scheme SieveGUI -destination 'platform=macOS' build

# 5. Xcode 里 Run
open SieveGUI.xcodeproj
```

> 工程是双轨制：`Package.swift` 只编译 Core 库（Models / IPC / AuditDB / Logger / Telemetry）供命令行快速测试；完整 App 走 XcodeGen 生成的 `.xcodeproj` 构建。App target 的代码（UI / Features / Sparkle）只能由 `xcodebuild` 编译——`swift test` 抓不到 UI 层的编译错误，所以验证 UI 改动务必跑 `xcodebuild`。

> mock daemon 子项目尚未接好。当前请连真的 `sieve` daemon（监听 `~/.sieve/ipc.sock`）联调；daemon 不在时 GUI 进入 disconnected 状态并显示失联视图。

---

## 项目状态

**公开仓库 · GA 前闭测（邀请制测试者）。** 源码公开，是为了兑现 Sieve 的核心承诺——*可验证，而非仅凭信任*：用户在安装签名后的二进制前，可以先读懂安全模型。

当前工程基线：

- 50+ 个 Swift 源文件；IPC 与跨仓库 SPEC-005 v2.x 协议完全对齐（ADR-026 `listeners[]` + ADR-028 中性化）。
- `swift test` —— 全部测试通过（覆盖 IPC 解码、HIPS 状态机、脱敏、audit-db 访问的大量单元测试）。
- `xcodebuild` —— **BUILD SUCCEEDED**，产出 `Sieve GUI.app`（通用，universal）。
- Phase 1B 全部 UX / 系统集成已交付（HIPS / Settings / History / Debug / Onboarding / Toast）。
- 域名迁移至 `sieveai.dev`（Sparkle `SUFeedURL` + appcast + About 链接）。

进度真实源见 [`tasks/PROGRESS.md`](tasks/PROGRESS.md)；工程踩坑沉淀见 [`tasks/lessons.md`](tasks/lessons.md)。

---

## 贡献

欢迎提 Pull Request 和 Issue。开 PR 前请先读 [`./CONTRIBUTING.md`](./CONTRIBUTING.md) 和 [`./CODE_OF_CONDUCT.md`](./CODE_OF_CONDUCT.md)。

## 安全

发现漏洞？请按 [`./SECURITY.md`](./SECURITY.md) 中的负责任披露流程处理，不要直接开公开 Issue。

---

## License

- **代码** —— [Apache License 2.0](./LICENSE)
- **文档** —— [CC BY-NC-SA 4.0](./LICENSE-DOCS)（`docs/` 下全部内容，外加 `README*.md`、`CLAUDE.md` 以及其他非源码的 Markdown / 配置文件）

---

[sieveai.dev](https://sieveai.dev)
