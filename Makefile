.PHONY: all test build app run dmg production-dmg release require-clean-release clean icon

all: app

test:
	swift test
	swift run AudiobookBinderSelfTest

build:
	swift build -c release

icon:
	@mkdir -p Resources/AppIcon.iconset
	sips -z 16 16     Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_16x16.png >/dev/null
	sips -z 32 32     Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_16x16@2x.png >/dev/null
	sips -z 32 32     Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_32x32.png >/dev/null
	sips -z 64 64     Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_32x32@2x.png >/dev/null
	sips -z 128 128   Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_128x128.png >/dev/null
	sips -z 256 256   Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_128x128@2x.png >/dev/null
	sips -z 256 256   Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_256x256.png >/dev/null
	sips -z 512 512   Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_256x256@2x.png >/dev/null
	sips -z 512 512   Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_512x512.png >/dev/null
	sips -z 1024 1024 Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_512x512@2x.png >/dev/null
	iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns.new
	@if [ -f Resources/AppIcon.icns ] && cmp -s Resources/AppIcon.icns.new Resources/AppIcon.icns; then \
		rm -f Resources/AppIcon.icns.new; \
	else \
		mv Resources/AppIcon.icns.new Resources/AppIcon.icns; \
	fi

app: icon build
	./scripts/package-app.sh

run: app
	open dist/AudiobookBinder.app

dmg: app
	chmod +x scripts/package-dmg.sh
	./scripts/package-dmg.sh

production-dmg: app
	chmod +x scripts/package-dmg.sh
	PRODUCTION=1 ./scripts/package-dmg.sh

require-clean-release:
	chmod +x scripts/require-clean-release.sh
	./scripts/require-clean-release.sh

release: require-clean-release test production-dmg
	chmod +x scripts/github-release.sh scripts/sync-public-release.sh
	./scripts/github-release.sh
	./scripts/sync-public-release.sh

clean:
	rm -rf .build dist Resources/AppIcon.icns Resources/AppIcon.iconset
