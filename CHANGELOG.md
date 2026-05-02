# Changelog

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)。

> 写作约定：
> - 每个版本下分 `Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security` 六类
> - 影响 IPC 协议的变更必须额外标注 `protocol_version` 变化
> - Phase 0（文档体系）期间，进度由 `tasks/todo.md` 跟踪，不在此处记录

---

## [Unreleased]

### Added

- _（Phase 1 实现期间在此累积）_

---

## [0.0.1] — 2026-05-02

### Added

- 项目初始化
- Phase 0 文档体系落地（34 个文件）
  - PRD v1.0、DOCS-STANDARD v2.0、glossary
  - architecture.md、data-model.md
  - 11 个 ADR
  - 8 个 SPEC + IPC 协议参考 (`docs/api/ipc-protocol.md`)
  - 开发与发布指南 (`docs/guides/`)
  - 上游引用 (`docs/external/upstream-references.md`)
  - 经验沉淀 (`tasks/lessons.md`)
- Git 必备文件（`.gitignore` / `.gitattributes` / `.editorconfig` / `.github/`）

### Notes

- 协议版本：尚未实现，目标 `v1`
- 代码尚未开工
