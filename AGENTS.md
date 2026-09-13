# AGENTS.md

## Project

Audiobook Binder is a local macOS 14+ Swift 6 app. It scans a book folder or a library of folders, then binds chapter audio into an Apple Books `.m4b` with title, author, cover, and chapter marks.

`AudiobookBinderCore` is the library (scan, metadata, export). `AudiobookBinder` is the SwiftUI app and CLI. Tests are the `AudiobookBinderSelfTest` executable, not XCTest.

## Layout

- `Sources/AudiobookBinderCore/` — models, scanner, library folder tree, tags, encoder
- `Sources/AudiobookBinder/` — UI, `AppState`, CLI
- `Sources/AudiobookBinderSelfTest/` — `expect()` harness
- `Info.plist` — shipping version (copied into the `.app` by `scripts/package-app.sh`)

## Workflow

- KISS. No new test target, no new dependencies, unless the task needs them.
- TDD for scanner, titles, export settings, and other Core logic: fail in `AudiobookBinderSelfTest`, then implement.
- Fixture folders in `/tmp` (empty `.mp3` is enough for discovery). Do not scan large real libraries in tests.
- Keep `loadBook` recursive for chapters inside a book (`mp3/`, `CD1`/`CD2`). Library discovery is `discoverBookFolders`.
- `make test` / `swift run AudiobookBinderSelfTest` must pass before claiming done.
- `make app` packages `dist/AudiobookBinder.app`.

## Versioning

Marketing version is **`x.y.z`** (`major.minor.patch`) in `Info.plist` → `CFBundleShortVersionString`. Build number is a monotonic integer in `CFBundleVersion`.

Bump both in the **same change** the user will run, whenever the work is a feature, bug fix, enhancement, UX copy change that ships, or other user-visible behavior change. Docs-only or `AGENTS.md` edits do not bump.

| Bump | When |
|---|---|
| **z** (patch) | Bug fix, reliability, copy, small enhancement, no new capability |
| **y** (minor) | New user-visible feature or capability; reset **z** to `0` |
| **x** (major) | Breaking behavior or a non-compatible product milestone; reset **y** and **z** to `0` |

Always increment `CFBundleVersion` when the marketing version changes.

`Info.plist` is the only source of truth. `scripts/package-app.sh` copies it into the app bundle. Do not leave `dist/` as a second edited copy. Do not hard-code the version in Swift.

If HEAD already contains unreleased user-visible work at the current marketing version, bump before packaging.

State the new `x.y.z` (build N) in the completion summary.
