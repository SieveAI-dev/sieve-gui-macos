# PR 标题：`<scope>: <一句话>`

> scope ∈ `menu-bar | hips | settings | history | debug | onboarding | toast | ipc | infra | docs | chore`

## 这个 PR 做了什么

<!-- 一句话说"为什么"，而不是罗列"改了什么" -->

## 关联

- Closes #
- 关联 SPEC：<!-- e.g., SPEC-002 §4.6 -->
- 关联上游 daemon PR：<!-- 仅当涉及 IPC 字段变更时必填 -->

## Checklist

### 通用

- [ ] 修改了哪些代码就跑了哪些测试，并附粘贴/截图
- [ ] `swift-format lint` 通过
- [ ] `xcodebuild test` 通过
- [ ] commit message 是 Conventional Commits 格式（`feat(scope): ...` / `fix(scope): ...`）
- [ ] **没有** 在 commit 里加任何 AI 署名 / `Co-Authored-By: Claude` 之类

### 文档同步（必查）

- [ ] 改了 IPC → `docs/api/ipc-protocol.md` + `docs/specs/SPEC-008-ipc-client.md` 已同步
- [ ] 改了 HIPS 行为 → `docs/specs/SPEC-002-hips-popup-window.md` 已同步
- [ ] 改了模块行为 → 对应 SPEC 已同步
- [ ] 改了架构 → 写新 ADR 或把旧 ADR 标记 Superseded
- [ ] 没复制上游 daemon 仓库的 ADR/SPEC 到本仓库（应通过 `external/` 引用）

### 安全 / 隐私（涉及时必查）

- [ ] 没有把 `allow_remember=false` 时的 Remember checkbox 渲染出来（哪怕灰显）
- [ ] 敏感字段都走 `MaskedField`，没有裸 `Text(...)`
- [ ] 没有让 GUI 在失联期间做安全决策
- [ ] HIPS 主按钮在 `confidence != high` 时永远是拒绝
- [ ] 没有写入原始 prompt / 命中片段到磁盘
- [ ] 没有引入 `network.client` entitlement（除 Sparkle 配置）

### 协议变更（涉及时必查）

- [ ] 字段变更已与上游 daemon 仓库 PR 绑定
- [ ] 不兼容变更已递增 `protocol_version`（v1 → v2）
- [ ] mock daemon 的对应场景已更新

## 如何测试

<!-- 给 reviewer 一份 5 分钟内能复现的步骤 -->

```
1. ...
2. ...
3. ...
```

## 截图 / 录屏（涉及 UI 变更时）

<!-- light + dark mode 各一张；如果涉及动效，录 < 10s gif -->

## 风险与回退

<!-- 上线后如果有问题怎么回退？影响面有多大？ -->
