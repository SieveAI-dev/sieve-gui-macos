# Sieve GUI for macOS

> Sieve daemon 的 native macOS 守门人壳。常驻菜单栏，在不可逆动作发生前用 HIPS 弹窗强制插入认知摩擦，平时几乎不可见。

---

## 这是什么

[Sieve](https://github.com/doskey/sieve) 是一个本地、不联网的 LLM 代理守门人。它在 `127.0.0.1:11453` 拦截 Anthropic / OpenAI 流量，按规则在出站前脱敏、在入站后阻拦危险动作（钓鱼地址替换、签名 tool_use、密钥外泄等）。

daemon 是非交互的 Rust 守护进程——**它无法弹窗，也不该弹窗**。本仓库实现的 macOS GUI 是 daemon 的视觉延伸：

- 收 daemon 推过来的 HIPS 决策请求，渲染弹窗等用户答复
- 菜单栏状态指示（normal / warning / hold / paused / disconnected）
- 历史 / 调试 / 设置 / Onboarding 几个常驻窗口

完整产品需求见 [`docs/requirements/sieve-gui-macos-prd-v1.0.md`](docs/requirements/sieve-gui-macos-prd-v1.0.md)。

---

## 技术栈

| 层 | 选择 |
|----|-----|
| 平台 | macOS 13 Ventura+，Apple Silicon + Intel 通用 |
| UI | SwiftUI + Combine（部分场景 AppKit 桥接） |
| 持久化 | SQLite.swift（只读 audit.db）+ UserDefaults |
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
2. `docs/requirements/sieve-gui-macos-prd-v1.0.md`
3. `docs/design/architecture.md`
4. `docs/api/ipc-protocol.md`
5. 按需查 SPEC

---

## 本地开发

详见 [`docs/guides/development.md`](docs/guides/development.md)。简版：

```bash
# 1. 装 Xcode 15+
# 2. 打开工程
open SieveGUI.xcodeproj

# 3. 跑 mock daemon（不需要真的 sieve daemon）
swift run sieve-gui-mock-daemon

# 4. 在 Xcode 里 Run
```

---

## 当前状态

**Phase 0：文档体系落地中**。代码尚未开工。
进度见 [`tasks/todo.md`](tasks/todo.md)。

GA 时间表与 daemon 同步：
- Week 5：SwiftUI 骨架 + HIPS 主流程
- Week 12：v1.0 GA

---

## License

Phase 1 闭测期间未公开。
