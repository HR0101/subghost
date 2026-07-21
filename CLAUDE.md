# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` covers project layout, coding style, testing conventions, and commit/PR rules — follow it and do not duplicate it here. This file covers commands and the architecture that only becomes visible after reading several files together.

## Commands

Run from the repository root. `DEVELOPER_DIR` is required whenever `xcode-select` points at the Command Line Tools rather than Xcode.

```sh
# Build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Subghost/Subghost.xcodeproj -scheme Subghost build

# All tests (unit + UI)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Subghost/Subghost.xcodeproj -scheme Subghost test

# One suite / one test (targets: SubghostTests, SubghostUITests)
... -only-testing:SubghostTests/StateDetectorTests test
... -only-testing:'SubghostTests/StateDetectorTests/エラーパターンでerrorへ遷移する()' test
```

If the build fails with `No signing certificate "Mac Development" found`, the project's `DEVELOPMENT_TEAM` does not match a certificate on this machine. Override it on the command line — `xcodebuild ... DEVELOPMENT_TEAM=<your team id>` — rather than editing `project.pbxproj`, which would churn the file for everyone else.

Unit tests are Swift Testing (`@Test` / `#expect`) with Japanese behavior-statement names; UI tests are XCTest.

## Architecture

Subghost is a menu-bar-less macOS app: `SubghostApp` owns only a `Settings` scene, and `AppDelegate` starts the singleton `AppCoordinator`, which is the sole entry point. All interaction happens through a floating notch panel.

### Discovery is zero-config, and tty is the identity

`AgentDiscovery` finds AI CLIs by scanning running processes for executable names from `CLIProfile.executableNames` — not by shell aliases or tmux session naming. It uses the kernel's real executable name, so CLIs that rewrite their process title (Claude Code) are still matched, and processes without a controlling terminal are excluded.

`SessionInfo.id` is the **tty**, not the pid or tmux name. This is what lets a session survive tmux being absent. `CLIProfile.withCustomAliases` folds user-registered wrapper-script names into the built-in profiles at discovery time.

### Two monitoring paths converge in SessionWatcher

This is the central design fact. `SessionWatcher.pollOnce()` runs both, and **which path a session uses changes the rules that apply to it**:

| | Hook path | tmux path |
|---|---|---|
| Transport | Unix domain socket, minimal HTTP/1.1 (`HookServer`) | `tmux capture-pane` text scraping |
| Accuracy | Events are authoritative | Inferred from screen text |
| Requires tmux | No | Yes |
| CLIs | Claude Code, Codex | All three |

**Once a session is hook-connected, `StateDetector.ingest` is never called for it again** (`pollOnce` hits `continue`). Screen analysis stops entirely, so a dropped hook event has no self-healing route and the session would stick on `Working` forever. `reconcileStaleHookState` exists solely as the independent safety net for this — it re-checks via tmux when available, and otherwise forces `idle` after a long timeout. Preserve this net when touching hook handling.

For the same reason, `handleHook` resets a `thinking` state on first hook connection: a `thinking` inferred from screen scraping cannot be trusted once the only thing that can move state is hook events.

### State detection is a pure state machine

`StateDetector` is a `nonisolated struct` with no I/O — text in, `DetectorEvent` out — which is why it is heavily unit-testable with fixed `Date` values. Keep it that way; put side effects in `SessionWatcher`.

Two entry points, deliberately different:
- `adoptCurrentState` — first sight of an already-running CLI. Never returns "completed", because announcing a response that finished before Subghost launched is a false alarm.
- `ingest` — steady-state, diff-driven.

Choice detection (`ChoicePrompt`) uses a two-poll confirmation on startup (`candidateChoice`): a numbered list must be seen twice before it is treated as a live prompt, because leftover conversation text reads like a menu.

`CLIProfile` regexes are the contract with each CLI's real on-screen UI. They drift when a CLI ships a UI change — `promptPattern` in particular gates preview extraction, since `extractPreview` slices off everything below the last prompt line to drop the status bar. Verify against real `capture-pane` output, not just mock fixtures.

### Sending back to the CLI has three routes with different requirements

Ordered by capability, and the reason several error messages exist:
1. **Hook return value** — approvals only, no keystrokes involved, works in the background.
2. **tmux `send-keys`** — arbitrary text, works in the background.
3. **Synthesized keystrokes** (`KeystrokeSender`) — the fallback when there is no tmux. Requires Accessibility permission (`AXIsProcessTrusted`) *and* the target tab in front, so it cannot serve background replies.

`MonitoredSession.canRespondToChoice` encodes exactly this: only routes 1 and 2 count.

### UI layer

`AppCoordinator` (`@Observable` singleton) holds all UI state and wires the components; `NotchPanelController` owns the `NSPanel`; `NotchView` renders it.

`NotchMode` is the requested mode, but `displayMode` is what actually renders — it applies a priority ladder (input > choice > onboarding > notification > sessions > activity > hover > compact) so urgent prompts cannot be buried and typing is never interrupted. Change display precedence there, not at the call sites.

`NotchPanel` overrides `constrainFrameRect(_:to:)` to return the rect unchanged. Without it macOS pushes the panel below the menu bar and it never sits in the notch. Do not remove it.

`NotchLayout` holds geometry constants shared between the panel and the SwiftUI view; `canvasWidth(for:)` accounts for the top shoulder curve, so panel sizing and shape drawing must both go through it or they desync.

## Gotchas

- **SourceKit diagnostics like `Cannot find type 'X' in scope` in this project are noise** from single-file indexing across an Xcode target with no module boundaries. Trust `xcodebuild`, not the editor diagnostics.
- **`SubghostUITests.testLaunchPerformance` is flaky** — it measures launch time and fails intermittently on identical code. Re-run before treating a failure as a regression.
- Runtime behavior depends on macOS permissions (Accessibility for keystrokes, Automation for Terminal.app tab jumping). Failures there surface as user-facing errors, not crashes.
- `詳細設計書.md` is the design of record and section numbers are cited throughout the code comments (`設計書 5.2` etc.). Read the cited section before changing state transitions or UI flows.
