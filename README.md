# Sieve GUI for macOS

> The native macOS gatekeeper shell for the Sieve daemon — lives in the menu bar and forces a moment of cognitive friction (HIPS prompt) before irreversible actions happen.

English | [中文](./README.zh-CN.md)

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![Platform: macOS 13+](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)](#tech-stack)
[![UI: SwiftUI](https://img.shields.io/badge/UI-SwiftUI-orange.svg)](#tech-stack)

---

## What is this

[Sieve](https://github.com/SieveAI-dev/sieve) is a fully local, no-cloud LLM-traffic security proxy — a single Rust daemon that sits between your AI coding agent (Claude Code / OpenClaw / Hermes / Codex CLI) and the upstream model API (Anthropic / OpenAI / relays). It inspects traffic in both directions: redacting secrets on the way out, and blocking dangerous tool calls on the way in (fail-closed). Inbound detection runs with equal coverage across all four content routes (Anthropic and OpenAI, each in streaming and JSON modes), Critical tool-call interception is always-on and cannot be disabled, and every check runs purely locally with no remote validation. Detection rules ship as signed rule packs.

The daemon is a non-interactive background process — **it cannot, and should not, draw windows.** This repository is its visual extension. The GUI is where a human actually meets Sieve:

- **HIPS prompts** — receives decision requests pushed from the daemon, renders the confirmation panel, and waits for the user's answer before an irreversible action proceeds.
- **Menu-bar status** — at-a-glance state indicator (normal / warning / hold / paused / disconnected).
- **History / Debug / Settings / Onboarding** — the persistent windows around the daemon.

Detection logic stays 100% in the daemon; the GUI never invents protocol fields and never rewrites the values the daemon pushes. See the daemon repository at [SieveAI-dev/sieve](https://github.com/SieveAI-dev/sieve) for the security model and the IPC protocol specs.

---

## Tech stack

| Layer | Choice |
|-------|--------|
| Platform | macOS 13 Ventura+, universal (Apple Silicon + Intel) |
| UI | SwiftUI + Combine (AppKit bridging where required) |
| Persistence | SQLite.swift (read-only `audit.db`) + UserDefaults |
| IPC | `~/.sieve/ipc.sock` Unix domain socket, JSON-RPC 2.0 |
| Distribution | Hardened runtime + Apple notarization + Sparkle auto-update |

Hard constraints live in [`CLAUDE.md`](CLAUDE.md).

---

## Documentation map

```
docs/
├── DOCS-STANDARD.md            ← documentation system standard
├── glossary.md                 ← glossary
├── design/
│   ├── architecture.md         ← GUI process architecture
│   └── data-model.md           ← local data model
├── specs/
│   ├── INDEX.md
│   └── SPEC-001 … SPEC-008
├── api/
│   └── ipc-protocol.md         ← full GUI ↔ daemon IPC reference
├── guides/
│   ├── development.md
│   └── deployment.md
└── external/
    └── upstream-references.md  ← upstream contract references from the daemon repo
```

Recommended reading order for newcomers:

1. This README
2. [`docs/design/architecture.md`](docs/design/architecture.md)
3. [`docs/api/ipc-protocol.md`](docs/api/ipc-protocol.md)
4. SPECs as needed

---

## Local development

See [`docs/guides/development.md`](docs/guides/development.md) for the full guide. Quick version:

```bash
# 1. Install Xcode 15+ and xcodegen
brew install xcodegen

# 2. Generate the Xcode project
xcodegen generate

# 3. Build + test the Core libraries (no Xcode required)
swift build              # compiles Models / IPC / AuditDB / Logger / Telemetry
swift test               # runs unit tests

# 4. Full app build
xcodebuild -project SieveGUI.xcodeproj -scheme SieveGUI -destination 'platform=macOS' build

# 5. Run from Xcode
open SieveGUI.xcodeproj
```

> The project is dual-track: `Package.swift` compiles only the Core libraries (Models / IPC / AuditDB / Logger / Telemetry) for fast command-line testing; the full app is built via the XcodeGen-generated `.xcodeproj`. App-target code (UI / Features / Sparkle) is only compiled by `xcodebuild` — `swift test` will not catch UI-layer compile errors, so always run `xcodebuild` to validate UI changes.

> IPC behavior is covered by the `MockDaemonHarness` test fixtures for fast, deterministic unit testing. For end-to-end work, run against a real `sieve` daemon (listening on `~/.sieve/ipc.sock`); when the daemon is absent the GUI enters the disconnected state and shows the lost-connection view.

---

## Project status

**Public repository · early preview (alpha).** The source is public to honor Sieve's core promise — *verifiable, not merely trusted*: users can read the security model before installing the signed binary. Sieve is currently available as source you build yourself and as an invite-based alpha preview, with a one-click installer and automatic rule updates on the way.

Capabilities the GUI surfaces today:

- Bidirectional inspection driven entirely by the daemon: outbound secret redaction plus inbound dangerous-tool-call interception with fail-closed Critical confirmation.
- IPC aligned with the cross-repo SPEC-005 v2 protocol (`listeners[]` + protocol-term neutralization).
- Native macOS UX surfaces: HIPS prompts, Settings, History, Debug, Onboarding, and status-bar toasts.
- Distribution via Apple Developer ID signing, notarization, and Sparkle auto-update; About / appcast links on `sieveai.dev`.

---

## Contributing

Pull requests and issues are welcome. Please read [`./CONTRIBUTING.md`](./CONTRIBUTING.md) and our [`./CODE_OF_CONDUCT.md`](./CODE_OF_CONDUCT.md) before opening a PR.

## Security

Found a vulnerability? Please follow the responsible-disclosure process in [`./SECURITY.md`](./SECURITY.md) rather than opening a public issue.

---

## License

- **Code** — [Apache License 2.0](./LICENSE)
- **Documentation** — [CC BY-NC-SA 4.0](./LICENSE-DOCS) (everything under `docs/`, plus `README*.md`, `CLAUDE.md`, and other non-source Markdown / config)

---

[sieveai.dev](https://sieveai.dev)
