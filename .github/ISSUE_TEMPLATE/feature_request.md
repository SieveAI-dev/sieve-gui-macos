---
name: 功能请求
about: 提议一个新功能或改进
title: "[feat] "
labels: enhancement
---

> 提议前先确认：
> 1. 不在范围之外（GUI 只做交互，检测逻辑属上游 daemon）
> 2. 不违反 [`CLAUDE.md`](../../CLAUDE.md) 硬约束（特别是不联网决策、Critical 锁、fail-closed）

## 想解决什么问题

<!-- 用户/场景导向；不要直接给方案 -->

## 提议的方案

<!-- 可选：你想到的实现方向 -->

## 涉及模块

- [ ] 菜单栏 (SPEC-001)
- [ ] HIPS 弹窗 (SPEC-002)
- [ ] 设置 (SPEC-003)
- [ ] 历史 (SPEC-004)
- [ ] 调试 (SPEC-005)
- [ ] Onboarding (SPEC-006)
- [ ] Toast / 通知 (SPEC-007)
- [ ] IPC (SPEC-008)
- [ ] 其他：

## 是否影响 IPC 协议

- [ ] 是（需要双仓库同步 + 协议版本号变更）
- [ ] 否

## 优先级建议

- [ ] P0（违反硬约束 / 阻断主流程）
- [ ] P1（重要，有解决方案）
- [ ] P2（nice-to-have）
- [ ] P3（远期）
