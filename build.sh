#!/bin/zsh
# Sestaví Vlnka.app do složky build/
set -e
cd "$(dirname "$0")"
APP=build/Vlnka.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/tmp

swiftc -O -parse-as-library -swift-version 5 Sources/Shared/*.swift Sources/Mac/*.swift -o "$APP/Contents/MacOS/Vlnka"

if [ ! -f build/tmp/AppIcon.icns ]; then
  swift Tools/make_icon.swift build/tmp/icon.png
  ICONSET=build/tmp/AppIcon.iconset; mkdir -p $ICONSET
  for s in 16 32 128 256 512; do
    sips -z $s $s build/tmp/icon.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/tmp/icon.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns $ICONSET -o build/tmp/AppIcon.icns
fi
cp build/tmp/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Vlnka</string>
  <key>CFBundleDisplayName</key><string>Vlnka</string>
  <key>CFBundleIdentifier</key><string>cz.local.vlnka</string>
  <key>CFBundleExecutable</key><string>Vlnka</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>cs</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
EOF

codesign --force --sign - "$APP"
echo "Hotovo: $PWD/$APP"
