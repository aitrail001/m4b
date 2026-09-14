#!/bin/zsh
# Copy the shipped DMG onto the website and set PUBLIC_VERSION.
# Run only as part of an explicit release (`make release`).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
TAG="v${VERSION}"
DMG="$ROOT/dist/AudiobookBinder-${VERSION}.dmg"
SITE_DMG="$ROOT/site/downloads/AudiobookBinder.dmg"
HTML="$ROOT/site/index.html"

if [[ ! -f "$DMG" ]]; then
  echo "Missing $DMG. Run: make dmg" >&2
  exit 1
fi

if ! gh release view "$TAG" >/dev/null 2>&1; then
  echo "GitHub release $TAG does not exist. Create it before syncing the site download." >&2
  exit 1
fi

mkdir -p "$ROOT/site/downloads"
cp "$DMG" "$SITE_DMG"

python3 - "$HTML" "$VERSION" <<'PY'
import pathlib, re, sys

path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text()
new, n = re.subn(
    r'const PUBLIC_VERSION = "[^"]+"',
    f'const PUBLIC_VERSION = "{version}"',
    text,
    count=1,
)
if n != 1:
    sys.exit("PUBLIC_VERSION constant missing or duplicated in site/index.html")
# No-JS fallbacks in the HTML body (hero.fine, footer).
new = re.sub(r"(Version )(\d+\.\d+\.\d+)", rf"\g<1>{version}", new)
new = re.sub(r"(版本 )(\d+\.\d+\.\d+)", rf"\g<1>{version}", new)
new = re.sub(r"(Audiobook Binder )(\d+\.\d+\.\d+)", rf"\g<1>{version}", new)
path.write_text(new)
print(f"site PUBLIC_VERSION -> {version}")
PY

echo "Copied $DMG -> $SITE_DMG"
echo "Public version is ${VERSION} (GitHub $TAG + site download)."
