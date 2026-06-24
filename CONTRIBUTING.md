中文版见 [README.zh-CN.md](README.zh-CN.md) · This guide is written in English.

# Contributing to Sieve GUI for macOS

Thanks for your interest in contributing. This repository is the **native macOS gatekeeper UI for the [Sieve daemon](https://github.com/SieveAI-dev/sieve)** — a menu-bar accessory app that surfaces HIPS confirmation prompts, reads the daemon's audit log for history, and exposes settings/debug/onboarding surfaces.

**Scope, in one line:** the daemon does the detection; the GUI only does interaction. We accept contributions that improve the macOS UI, IPC client, audit-log views, and developer tooling. We do **not** accept contributions that move security/detection logic into the GUI — that belongs upstream in the daemon repo.

Before writing any code, read [`CLAUDE.md`](CLAUDE.md). It is the source of truth for hard constraints, the dependency whitelist, and the IPC contract with the daemon. Anything below that conflicts with `CLAUDE.md` loses to `CLAUDE.md`.

---

## Prerequisites

- **Xcode 15+** (with Command Line Tools installed)
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — `brew install xcodegen` (the `.xcodeproj` is generated, never hand-edited)
- **macOS 13+** (Ventura or later; Apple Silicon + Intel)
- **[swiftformat](https://github.com/nicklockwood/SwiftFormat)** — `brew install swiftformat` (config lives in `.swiftformat`)

The project is dual-track:

- `Package.swift` compiles only the **Core** library (Models / IPC / AuditDB / Logger / Telemetry) for fast command-line testing.
- The **full App** (UI / Features / Sparkle) is built via the XcodeGen-generated `.xcodeproj`.

---

## Build & test

```bash
# Regenerate the Xcode project (required after editing project.yml)
xcodegen generate

# Command-line: build + test the Core library (fastest feedback, used by CI)
swift build
swift test

# Run a single test (filter takes TestSuite or TestSuite/testName)
swift test --filter SieveGUICoreTests.HipsRequestDecoderTests
swift test --filter SieveGUICoreTests.HipsRequestDecoderTests/testRejectsUnknownProtocolVersion

# Full App build (produces SieveGUI.app)
xcodebuild -project SieveGUI.xcodeproj -scheme SieveGUI -destination 'platform=macOS' build

# Open in Xcode for interactive Run / debugging
open SieveGUI.xcodeproj
```

> [!IMPORTANT]
> **The UI layer can only be verified with `xcodebuild`.** App-target code (UI / Features / Sparkle) is excluded from `Package.swift`, so `swift build` / `swift test` will **not** catch UI compile errors. If you touch anything under `Sources/UI` or `Sources/Features`, you must run the `xcodebuild` command above before claiming it works. Unit tests covering the Core library are not sufficient validation for UI changes.

IPC behavior is covered by the `MockDaemonHarness` test fixtures for fast, deterministic unit testing; end-to-end integration testing connects to a real `sieve` daemon over `~/.sieve/ipc.sock`. With the daemon absent, the GUI enters the `disconnected` state. See [`docs/guides/development.md`](docs/guides/development.md) for details.

---

## Code style

- **Run `swiftformat .` before committing.** Config is in `.swiftformat` (Swift 5.9, 4-space indent, 120 max width). CI checks formatting.
- **Swift 5.9+ with `-warnings-as-errors`.** A warning is a build failure — fix it, don't suppress it.
- **All IPC messages go through `Codable` structs. No `[String: Any]` passthrough.** The GUI never invents protocol fields and never rewrites values the daemon pushes.
- **Render sensitive fields (addresses, keys, tool input) through the `MaskedField` component.** Never use a bare `Text(...)` for sensitive data.
- Async: `async/await` first; `Task` cancellation must propagate.
- No business logic in SwiftUI views — logic lives in `@Observable` ViewModels.
- User-facing strings go through String Catalogs (`Localizable.xcstrings`); debug logs may be hardcoded English, never machine-translated Chinese.
- One `View` / `Model` / `Service` per file; file > 400 lines is a signal to split.

---

## Hard constraints (violating any of these = the PR is rejected)

These mirror [`CLAUDE.md`](CLAUDE.md) "硬约束". Read `CLAUDE.md` for the full list and rationale; the load-bearing ones:

1. **When `allow_remember == false`, the HIPS panel must not render the Remember checkbox** — not even greyed out. (Third line of the three defenses.)
2. **The GUI decision path does not touch the network.** Sparkle update checks and external links are the only exceptions, and neither may affect the HIPS panel.
3. **Never store raw prompts or matched evidence snippets.** Evidence the daemon pushes is held in memory only and discarded when the panel closes.
4. **The HIPS primary button is always "Reject" when `recommendation` is missing or `confidence != high`.** The keyboard Return default maps to Reject.
5. **Unrecognized protocol version → `disconnected`.** No backward-compatible field sniffing.
6. **Menu-bar status reflects the actual `sieve.hello` handshake** — never "pretend healthy".
7. **Exported diagnostic bundles are redacted by default**, independent of whether the user reads any disclaimer.
8. **File writes use atomic rename** (preset cache / user settings / GUI log).

If your change interacts with any of the above, link the relevant SPEC in your PR description and explain how the constraint is preserved.

---

## Commits & pull requests

- **Conventional Commits.** Format: `type(scope): summary`.
- **Scope tags:** `menu-bar` / `hips` / `settings` / `history` / `debug` / `onboarding` / `toast` / `ipc` / `infra`.
  - Examples: `feat(menu-bar): show degraded handshake state`, `fix(hips): force Reject default when confidence is low`, `docs(spec): clarify the IPC handshake sequence`.
- One commit does one thing — do not mix feature changes with formatting.
- **No AI signatures, ever.** Do not add `Co-Authored-By: <any AI tool>`, "Generated with …", robot emojis, or any AI-generated footer/byline to commits or PR descriptions. This applies to every commit and PR without exception.
- Keep PRs scoped; update the relevant SPEC when you change behavior. Any IPC field or behavior change requires updating the SPEC **and** bumping the protocol version in both this repo and the daemon repo.

---

## Security

Do **not** open a public issue for security vulnerabilities. Follow the disclosure process in [`SECURITY.md`](SECURITY.md).

---

## License of contributions

By contributing, you agree your contributions are licensed under this repository's terms (see [`LICENSE`](LICENSE)):

- **Source code** — Apache License 2.0
- **Documentation** (everything under `docs/`, plus `README*` / `CLAUDE.md` and other Markdown/config that is not source) — CC BY-NC-SA 4.0
