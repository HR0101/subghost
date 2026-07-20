# Repository Guidelines

## Project Structure & Module Organization

Subghost is a SwiftUI macOS menu-bar application. The Xcode project is at `Subghost/Subghost.xcodeproj`; application code lives in `Subghost/Subghost/`:

- `Core/` contains CLI discovery, hooks, tmux integration, state detection, and terminal control.
- `Models/` contains shared data and preferences.
- `UI/` contains the notch panel, settings, coordinator, and reusable views.
- `Assets.xcassets/` stores app icons and colors.

Unit tests are in `Subghost/SubghostTests/`; launch and interaction tests are in `Subghost/SubghostUITests/`. Consult `README.md` for user behavior and `詳細設計書.md` before changing state transitions or UI flows.

## Build, Test, and Development Commands

Run commands from the repository root:

```sh
xcodebuild -project Subghost/Subghost.xcodeproj -scheme Subghost build
xcodebuild -project Subghost/Subghost.xcodeproj -scheme Subghost \
  -destination 'platform=macOS' test
open Subghost/Subghost.xcodeproj
```

The first command builds the app, the second runs unit and UI test targets, and the third opens the project in Xcode. If command-line tools point elsewhere, prefix builds with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Coding Style & Naming Conventions

Use four-space indentation and standard Swift API naming: `UpperCamelCase` for types, `lowerCamelCase` for properties/functions, and descriptive enum cases. Keep one primary type or cohesive feature per file. Group long files with `// MARK:` sections. Preserve the existing Japanese comments and test names where they clarify product behavior. Prefer value types and pure parsing/state logic in `Core/`; isolate AppKit, permissions, and side effects behind focused components. No formatter or linter is configured, so use Xcode formatting and keep warnings at zero.

## Testing Guidelines

Unit tests use Swift Testing (`@Test`, `#expect`); UI tests use XCTest. Add deterministic tests for parsing and state transitions, passing fixed `Date` values instead of waiting. Name tests as behavior statements, matching the existing Japanese convention. Run the full test command before opening a PR; add UI tests when navigation, focus, notifications, or notch interaction changes.

## Commit & Pull Request Guidelines

History favors short prefixes such as `add:` and `fix:`; `Githubrule.md` also recommends `feat:`, `docs:`, `refactor:`, `test:`, and `chore:`. Use an imperative, specific subject, for example `fix: 回答後の再通知を抑制`.

Create feature branches rather than committing to `main`. PRs should explain user-visible behavior, list test evidence, link related issues, and include screenshots or recordings for UI changes. Do not commit `xcuserdata`, build output, coverage artifacts such as `default.profraw`, credentials, or local hook configuration.
