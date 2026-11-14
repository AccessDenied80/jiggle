#!/bin/bash
# Збирає Jiggle.app у ./build. Використання: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Jiggle.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary: Intel (x86_64) + Apple Silicon (arm64)
for ARCH in x86_64 arm64; do
  swiftc -O Sources/*.swift -target "$ARCH-apple-macos13.0" -o "build/Jiggle-$ARCH" \
    -framework Cocoa -framework IOKit -framework ServiceManagement
done
lipo -create build/Jiggle-x86_64 build/Jiggle-arm64 -output "$APP/Contents/MacOS/Jiggle"
rm build/Jiggle-x86_64 build/Jiggle-arm64

# Іконка: генеруємо, якщо ще немає
if [[ ! -f Resources/AppIcon.icns ]]; then
  mkdir -p Resources
  swift Tools/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Jiggle</string>
  <key>CFBundleDisplayName</key><string>Jiggle</string>
  <key>CFBundleIdentifier</key><string>local.jiggle.app</string>
  <key>CFBundleExecutable</key><string>Jiggle</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc підпис зі сталою вимогою за ідентифікатором (а не за cdhash),
# тож дозвіл Accessibility переживає перезбирання. Якщо в TCC лишився
# старий запис, прив'язаний до хешу, скинь його й надай доступ знову:
#   tccutil reset Accessibility local.jiggle.app
codesign --force --sign - -r='designated => identifier "local.jiggle.app"' "$APP"
echo "Зібрано: $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Jiggle || true
  rm -rf /Applications/Jiggle.app
  cp -R "$APP" /Applications/
  open /Applications/Jiggle.app
  echo "Встановлено в /Applications і запущено"
fi
