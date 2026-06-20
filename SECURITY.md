# Sieve GUI 安全策略

> Sieve GUI 是 [Sieve daemon](https://github.com/sieveai/sieve) 的 native macOS 守门人壳。daemon 做检测，GUI 只做交互。
> GUI 自身被攻陷意味着用户看到伪造的 HIPS 弹窗或被绕过决策——直接威胁 Sieve 产品安全承诺。
>
> **请不要在 GitHub Issues 公开报告 GUI 自身的安全漏洞。** 走下方私有渠道。

---

## 报告渠道

| 渠道 | 说明 | 适用阶段 |
|------|------|---------|
| **Email** | doskey.lee@gmail.com | Pre-GA 唯一渠道 |
| Email | security@sieveai.dev | GA 后启用 |
| PGP | TBD（GA 前公布公钥指纹） | GA 后启用 |

请在邮件标题加前缀 `[SIEVE-GUI-SECURITY]`，内容包含：

- **受影响版本**：菜单栏 → 关于 中显示的 GUI 版本 + 二进制 SHA-256
- **平台**：macOS 版本 / 芯片架构（Intel / Apple Silicon）/ 安装方式（DMG / Homebrew / 源码构建）
- **漏洞类型**（任一）：
  - HIPS 弹窗渲染绕过（如 `allow_remember == false` 时仍渲染 Remember checkbox）
  - 决策路径联网（[CLAUDE.md 硬约束 #2](./CLAUDE.md)）
  - 原始 prompt / 命中片段被持久化（违反硬约束 #3）
  - 协议版本嗅探导致的握手降级
  - 菜单栏假装健康（伪造 sieve.hello 状态）
  - 导出诊断包未脱敏（违反硬约束 #7）
  - Sparkle 自动更新被绕过签名验证
  - TouchID unlock session 被绕过
  - 配置 / 用户设置非原子写入导致的 race condition
- **复现步骤**（最小化用例，附 daemon 版本）
- **影响评估**：是否能让攻击者绕过 Sieve 产品级安全承诺

---

## 响应时间承诺

| 阶段 | SLA |
|------|-----|
| 邮件确认收到 | **24 小时内** |
| 初步评估（严重程度 + 复现验证） | **7 天内** |
| 修复或缓解（按严重程度） | Critical: 7 天 / High: 30 天 / Medium: 90 天 |
| 公开 advisory | 修复发布后 30 天内 |

> Sieve 由一人维护，上述 SLA 已考虑单人响应能力。如涉及**当前正在被利用 + 用户资产损失风险**，请在标题加 `[URGENT]`，将优先响应。

---

## 责任披露原则

- 修复发布前请勿公开（包括会议演讲 / 博客 / Twitter / 漏洞数据库）
- 修复发布同时致谢报告者（除非要求匿名）
- 涉及 Sieve 用户资产损失风险时，立即通过 Sparkle 推送强制升级
- 不提供 bounty 现金奖励（项目资源有限），但对重大发现会在 advisory 与 changelog 中署名致谢

---

## 不在范围

以下不构成 GUI 安全漏洞：

- **daemon 检测漏报 / 误报**：见 [sieve daemon SECURITY.md](https://github.com/sieveai/sieve/blob/main/SECURITY.md)
- **用户主动禁用 Sparkle 自动更新后未升级**：用户责任
- **macOS 系统级提权 / sandbox 绕过**：上报给 Apple，不在 GUI 责任范围
- **第三方依赖漏洞**（SQLite.swift / Sparkle）：先报给上游，同时通知本仓库
- **未签名 / 未公证的二进制**：用户责任在安装时验证 codesign + spctl 输出

---

## 自身供应链承诺

GUI 与 daemon 共享相同的 "[redacted]" 叙事：

- 所有 release 二进制 **Apple Developer ID 签名 + Notarization + sigstore 双签**
- **Sparkle EdDSA 签名验证**（appcast.xml 中的 sparkle:edSignature）
- **pinned dependencies**：`Package.resolved` 入库
- **entitlements 最小化**：sandbox 关闭仅为 Unix Socket IPC 所必需，[ADR-001](./docs/design/adr/ADR-001-swiftui-native-only-stack.md) 有完整说明

供应链审计建议：

```bash
# 1. 验证代码签名
codesign --verify --deep --strict --verbose=4 "SieveGUI.app"

# 2. 验证公证状态
spctl --assess --type execute --verbose=4 "SieveGUI.app"

# 3. 验证 Sparkle EdDSA 签名（自动更新前 Sparkle 自身做）
# 公钥见 Info.plist 的 SUPublicEDKey
```

---

## 历史 Advisories

> Pre-GA 期间 advisories 不分配正式编号，记录在 [CHANGELOG.md](./CHANGELOG.md)。GA 后启用正式编号 `SIEVE-GUI-YYYY-NNN`。

---

## 相关文档

- [Sieve daemon SECURITY.md](https://github.com/sieveai/sieve/blob/main/SECURITY.md) — daemon 侧安全策略
- [CLAUDE.md 硬约束](./CLAUDE.md#硬约束违反--reject-pr) — GUI 特有的 8 条 reject-PR 约束
- [docs/api/ipc-protocol.md](./docs/api/ipc-protocol.md) — GUI ↔ daemon IPC 边界
- [docs/external/upstream-references.md](./docs/external/upstream-references.md) — 上游契约清单
