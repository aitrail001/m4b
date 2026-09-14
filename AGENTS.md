# AGENTS.md

## Project

Audiobook Binder is a local macOS 14+ Swift 6 app. It scans a book folder or a library of folders, then binds chapter audio into an Apple Books `.m4b` with title, author, cover, and chapter marks.

`AudiobookBinderCore` is the library (scan, metadata, export). `AudiobookBinder` is the SwiftUI app and CLI. Unit tests are XCTest. `AudiobookBinderSelfTest` is an optional live scan of `~/Documents/books`. The shipped app is self-contained: AVFoundation encode/play, no ffmpeg. EPUB metadata may use stock `/usr/bin/unzip`; missing unzip is not an error.

## Layout

- `Sources/AudiobookBinderCore/` — models, scanner, library folder tree, tags, encoder
- `Sources/AudiobookBinder/` — UI, `AppState`, CLI
- `Sources/AudiobookBinderSelfTest/` — live library smoke (skipped if that folder is missing)
- `Info.plist` — shipping version (copied into the `.app` by `scripts/package-app.sh`)

## Workflow

- KISS. No new test target, no new dependencies, unless the task needs them.
- TDD for Core logic: fail in `swift test`, then implement.
- Fixture folders in `/tmp` (empty `.mp3` is enough for discovery). Do not scan large real libraries in XCTest.
- Keep `loadBook` recursive for chapters inside a book (`mp3/`, `CD1`/`CD2`). Library discovery is `discoverBookFolders`.
- `make test` runs `swift test` then the live SelfTest smoke. XCTest must pass.
- `make app` packages `dist/AudiobookBinder.app`.
- `make dmg` writes `dist/AudiobookBinder-x.y.z.dmg` (version from `Info.plist`). Do not emit a versionless DMG name in `dist/` or on GitHub.

## Versioning

Marketing version is **`x.y.z`** (`major.minor.patch`) in `Info.plist` → `CFBundleShortVersionString`. Build number is a monotonic integer in `CFBundleVersion`.

Bump both in the **same change** the user will run, whenever the work is a feature, bug fix, enhancement, UX copy change that ships, or other user-visible behavior change. Docs-only or `AGENTS.md` edits do not bump.

| Bump | When |
|---|---|
| **z** (patch) | Bug fix, reliability, copy, small enhancement, no new capability |
| **y** (minor) | New user-visible feature or capability; reset **z** to `0` |
| **x** (major) | Breaking behavior or a non-compatible product milestone; reset **y** and **z** to `0` |

Always increment `CFBundleVersion` when the marketing version changes.

`Info.plist` is the only source of truth for the **app** version. `scripts/package-app.sh` copies it into the app bundle. Do not leave `dist/` as a second edited copy. Do not hard-code the version in Swift.

If HEAD already contains unreleased user-visible work at the current marketing version, bump before packaging (`make app` / `make dmg`). That bump does **not** change the public download.

State the new `x.y.z` (build N) in the completion summary.

## Public release (website + GitHub)

The website, the DMG it serves, and GitHub Releases are one public version. They must stay in lockstep with each other. They are **not** updated when `Info.plist` is bumped.

| Must match | Location |
|---|---|
| Latest GitHub Release tag `vX.Y.Z` and its attached DMG | https://github.com/aitrail001/m4b/releases/latest |
| File visitors download from the site | `site/downloads/AudiobookBinder-x.y.z.dmg` (that same DMG) |
| Version the site advertises | `PUBLIC_VERSION` in `site/index.html` (copy uses `{v}`) |

The public version may lag `Info.plist`. That is correct until a release.

**Do not** create a GitHub release, replace `site/downloads/AudiobookBinder-x.y.z.dmg`, change `PUBLIC_VERSION`, or run `make release` / `scripts/sync-public-release.sh` unless the user **explicitly** asks to release, ship, publish, cut a GitHub release, or update the website download. App features, version bumps, i18n, and ordinary Pages deploys are not a release.

Site copy and translations may be edited and deployed without a release. Leave `PUBLIC_VERSION` and the DMG untouched.

`make dmg` is local packaging only. Do not copy that DMG onto the site or GitHub unless this is a release.

The disk image **must** include the marketing version in its file name: `AudiobookBinder-x.y.z.dmg`, taken from `Info.plist` (`CFBundleShortVersionString`). That name is used in `dist/`, as the GitHub Release asset, and as `site/downloads/AudiobookBinder-x.y.z.dmg` (the file visitors save). Never ship a versionless `AudiobookBinder.dmg` as the download. Old unversioned URLs redirect to the versioned file.

When the user does ask to release:

1. Confirm `Info.plist` is the version to ship (bump first if unreleased app work is still at an old marketing version).
2. `make test`
3. Review the website against the shipping app. If features, how-to steps, or UI changed since the last public version, update `site/index.html` (English and 中文) and replace stale screenshots/videos in `site/media/` with captures of the real current UI. No generated watermarks. Leave media that still matches the app.
4. `make release` — builds the signed DMG, creates or updates GitHub tag `vX.Y.Z`, copies that DMG to `site/downloads/AudiobookBinder-x.y.z.dmg`, sets `PUBLIC_VERSION` and download hrefs.
5. Deploy Pages: `npx wrangler pages deploy site --project-name audiobook-binder`
6. Check that GitHub latest, the site version line, and the downloaded DMG all show the same `x.y.z`, and that the live page’s copy and pictures match the app in the DMG.
