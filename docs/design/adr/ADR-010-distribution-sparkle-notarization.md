# ADR-010：Sparkle EdDSA + Apple notarization 双签；reproducible build 推迟 v1.1

> Status: Accepted
> Date: 2026-05-02
> Deciders: SieveAI
> Tags: build, security, infra

## Context

Sieve GUI 需要一套分发和自动更新机制。核心要求：

1. **分发格式**：`.dmg`，用户拖拽安装（Phase 1 闭测期间通过链接分发，GA 后考虑 Homebrew cask）
2. **自动更新**：用户不应该手动重下 `.dmg` 才能升级；但强制升级不可接受（PRD §10 排除项）
3. **签名安全**：更新包必须签名验证，防止中间人篡改
4. **notarization**：通过 Apple Gatekeeper，用户双击不出现"无法验证开发者"警告

安全约束（PRD §8.4 / CLAUDE.md 硬约束 2）：
- `com.apple.security.network.client = false`，Sparkle 是唯一例外（自动更新需要 HTTPS 出站）
- hardened runtime 必须开启
- entitlement 严格最小化：GUI 决策路径绝不联网

风险 OQ-G-06：Sparkle 的 entitlement 例外若配置错误会导致 App Store / notarization 拒绝。
风险 OQ-G-09：reproducible build 可让用户验证二进制与源码一致，是安全产品的加分项，但实现成本高。

## Options Considered

### Option 1：Sparkle（EdDSA 签名）+ Apple notarization（本方案）
- 优点：
  - Sparkle 是 macOS 开源社区标准自动更新框架（Homebrew 等大量使用），成熟可靠
  - EdDSA（ed25519）签名：私钥由开发者持有，公钥 hardcode 进 App binary；即使 CDN 被攻击，也无法推送有效的恶意更新
  - appcast XML 托管在 Cloudflare Pages（静态，零运维成本）
  - Apple notarization 提供第二层验证（Apple 扫描 malware），用户体验好（无 Gatekeeper 警告）
  - Sparkle 2.x 原生支持 `hardened runtime`；entitlement 只需要在 Sparkle 的 XPC service 层面添加 `network.client`，主 App target 可保持 `false`
- 缺点：
  - Sparkle 是第三方依赖（但已在白名单）
  - EdDSA 私钥管理需要安全存储（本地 keychain，不 commit 到 repo）
  - appcast 需要手动更新（或脚本）；Phase 1 手动可接受
- 估计成本：中等，配置一次后基本自动化

### Option 2：Homebrew cask + GitHub Releases
- 优点：无需维护自己的 appcast
- 缺点：
  - 更新不是无感自动推送（用户需要 `brew upgrade`），体验不如 Sparkle
  - Phase 1 闭测期间不适合公开 Homebrew cask（需要公开 GitHub repo）
  - 与 Phase 1 分发模式不符
- 估计成本：Phase 1 不可行

### Option 3：Mac App Store 分发
- 优点：Apple 管理签名和更新
- 缺点：
  - MAS 沙箱限制与 GUI 需求不兼容：`~/.sieve/` 的 UDS 连接、`~/.sieve/audit.db` 直读，都需要 sandbox entitlement 豁免，MAS 审核可能拒绝
  - IPC socket 连接（非 MAS 沙箱友好路径）
  - Phase 1 闭测期间不适合上架
- 估计成本：entitlement 冲突，不可行

### Option 4：自实现更新机制（HTTPS 拉 manifest + 验签）
- 优点：无第三方依赖
- 缺点：重复发明轮子；签名验证、delta update、rollback 等都需要自实现；安全性反而不如 Sparkle（成熟审计）
- 估计成本：高，且引入安全风险

### Option 5：Sparkle + reproducible build（同步实现）
- 优点：reproducible build 让用户可以自行验证二进制
- 缺点：
  - macOS `.app` bundle 的 reproducible build 需要解决：Xcode 内嵌时间戳、UUID 注入、bitcode 等
  - Swift 编译器生成的 DWARF UUID 在每次构建时变化
  - 实现成本 ≥ 2 周，对 Phase 1 里程碑是风险
  - 推迟到 v1.1 不影响安全（已有 EdDSA + notarization 双保险）
- 估计成本：推迟到 v1.1（OQ-G-09）

## Decision

选择 **Sparkle（EdDSA 签名）+ Apple notarization**；reproducible build 推迟到 v1.1 评估。

**关键配置**：

**EdDSA 密钥对**：
- `generate_keys`（Sparkle 工具）生成 ed25519 密钥对
- 私钥存 macOS Keychain（`sparkle-private-key`），绝不 commit 到 repo
- 公钥（`SUPublicEDKey`）hardcode 进 `Info.plist`

**appcast 托管**：Cloudflare Pages 静态站点，appcast URL 格式：
```
https://updates.sieveai.dev/appcast.xml
```

**entitlement 处理**（OQ-G-06）：
- 主 App target：`com.apple.security.network.client = false`
- Sparkle 内嵌 XPC service（`org.sparkle-project.Downloader`）：Apple 在 notarization 流程中允许 Sparkle XPC bundle 有 network entitlement，与主 App 的 `false` 不冲突
- 在 Xcode target 的 entitlement 文件中**不**添加 `network.client = true`；Sparkle 2.x 自带 XPC service 处理下载

**hardened runtime**：
- Code Signing Flags：`--options=runtime`
- Xcode Build Settings：`ENABLE_HARDENED_RUNTIME = YES`
- 禁止 `com.apple.security.cs.allow-jit` / `cs.allow-unsigned-executable-memory` / `cs.disable-library-validation`

**notarization CI**：
- `xcrun notarytool submit SieveGUI.dmg --apple-id ... --team-id ... --wait`
- 成功后 `xcrun stapler staple SieveGUI.dmg`
- 验证：`spctl --assess --type execute SieveGUI.app`

**reproducible build（OQ-G-09）**：推迟 v1.1。届时评估 `xcode-archive-reproducible` 工具链是否成熟。

## Consequences

**正面影响**：
- EdDSA 签名保证更新包来自私钥持有者，appcast CDN 被攻击不影响安全
- notarization 让用户双击即可打开，无 Gatekeeper 警告
- Sparkle 2.x 无感后台下载，不打断用户工作流

**引入的新约束**：
- EdDSA 私钥**严禁 commit**，必须在构建环境中通过 CI secret 注入
- 每次发布必须走：archive → notarize → staple → 生成 EdDSA 签名 → 更新 appcast → 上传 Cloudflare Pages 这条流水线
- `com.apple.security.network.client = false` 是主 App 硬约束，任何试图在主 target 开启 `network.client` 的 PR 都应 reject
- reproducible build 推迟意味着 v1.0 用户无法自验证 binary；需在 About 页面说明签名机制（EdDSA + notarization）以建立信任

**后续需要做的事**：
- 在 `docs/guides/deployment.md` 补充完整发布流水线步骤
- CI（GitHub Actions）配置 Sparkle 签名 step（使用 `sign_update` 工具）
- v1.1 milestone 加入 reproducible build 评估 task

## References

- PRD §5.3.5（Updates 标签）、§8.4（安全 entitlement 要求）
- [`docs/guides/deployment.md`](../../guides/deployment.md)（发布流程）
- ADR-001（依赖白名单：Sparkle 已列入）：[`ADR-001-swiftui-native-only-stack.md`](ADR-001-swiftui-native-only-stack.md)
- CLAUDE.md 硬约束 2（GUI 决策路径不联网）
