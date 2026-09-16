#!/bin/zsh
# Point the website download at the GitHub Release DMG and set PUBLIC_VERSION.
# Run only as part of an explicit release (`make release`).
set -euo pipefail

# Drop leftover local AudiobookBinder*.dmg copies. (N) is a no-op when the
# downloads dir or matching files are missing (zsh NOMATCH would abort rm -f).
remove_legacy_site_dmgs() {
  rm -f "$1/site/downloads"/AudiobookBinder*.dmg(N)
}

# Sourced by scripts/test-sync-glob.sh — helpers only, no release side effects.
if [[ "$ZSH_EVAL_CONTEXT" == *:file* ]]; then
  return 0
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
TAG="v${VERSION}"
DMG="$ROOT/dist/AudiobookBinder-${VERSION}.dmg"
GH_DMG="https://github.com/aitrail001/m4b/releases/download/${TAG}/AudiobookBinder-${VERSION}.dmg"
HTML="$ROOT/site/index.html"
REDIRECTS="$ROOT/site/_redirects"

if [[ ! -f "$DMG" ]]; then
  echo "Missing $DMG. Run: make dmg" >&2
  exit 1
fi

if ! gh release view "$TAG" >/dev/null 2>&1; then
  echo "GitHub release $TAG does not exist. Create it before syncing the site download." >&2
  exit 1
fi

remove_legacy_site_dmgs "$ROOT"
print -r -- "/downloads/AudiobookBinder.dmg ${GH_DMG} 302
/downloads/AudiobookBinder-${VERSION}.dmg ${GH_DMG} 302" > "$REDIRECTS"

python3 - "$HTML" "$VERSION" "$GH_DMG" <<'PY'
import pathlib, re, sys

path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
gh = sys.argv[3]
text = path.read_text()
new, n = re.subn(
    r'const PUBLIC_VERSION = "[^"]+"',
    f'const PUBLIC_VERSION = "{version}"',
    text,
    count=1,
)
if n != 1:
    sys.exit("PUBLIC_VERSION constant missing or duplicated in site/index.html")
new = re.sub(
    r"https://github.com/aitrail001/m4b/releases/download/v[\d.]+/AudiobookBinder-[\d.]+\.dmg",
    gh,
    new,
)
new = re.sub(
    r"downloads/AudiobookBinder(?:-\d+\.\d+\.\d+)?\.dmg",
    gh,
    new,
)
new = re.sub(r"(Version )(\d+\.\d+\.\d+)", rf"\g<1>{version}", new)
new = re.sub(r"(版本 )(\d+\.\d+\.\d+)", rf"\g<1>{version}", new)
new = re.sub(r"(Audiobook Binder )(\d+\.\d+\.\d+)", rf"\g<1>{version}", new)
path.write_text(new)
print(f"site PUBLIC_VERSION -> {version}")
print(f"download -> {gh}")
PY

echo "Public version is ${VERSION}. Site download redirects to GitHub ${TAG}."
