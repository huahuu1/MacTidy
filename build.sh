#!/bin/zsh -f
# Build MacTidy.app và cài vào ~/Applications
set -e
cd "${0:A:h}"
APP=build/MacTidy.app
swift build -c release
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon.iconset
cp .build/release/MacTidy "$APP/Contents/MacOS/MacTidy"

# icon
swift scripts/make_icon.swift build/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon_1024.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MacTidy</string>
  <key>CFBundleDisplayName</key><string>MacTidy</string>
  <key>CFBundleIdentifier</key><string>io.github.huahuu1.mactidy</string>
  <key>CFBundleExecutable</key><string>MacTidy</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>vi</string></array>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>MacTidy dùng Finder để dọn Thùng rác.</string>
</dict></plist>
EOF

scripts/install_l10n.sh "$APP"
# Ký ad-hoc với điều kiện nhận diện cố định theo bundle id (thay vì theo mã băm),
# để quyền Trợ năng / thông báo không bị mất mỗi lần build lại
codesign --force --deep -s - -r='designated => identifier "io.github.huahuu1.mactidy"' "$APP"
# Cài vào /Applications: macOS 27 chỉ cho icon thanh menu của app trong /Applications
# nằm trong danh sách được phép khi gom icon (bản ở ~/Applications bị ẩn luôn icon của chính nó)
pkill -x MacTidy 2>/dev/null || true
sleep 1
rm -rf ~/Applications/MacTidy.app /Applications/MacTidy.app
cp -R "$APP" /Applications/
echo "Đã cài: /Applications/MacTidy.app"
