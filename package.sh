#!/bin/zsh -f
# Đóng gói MacTidy thành file .dmg để cài ở máy khác.
# Bản universal: chạy trên cả Mac chip Apple và Mac chip Intel.
set -e
cd "${0:A:h}"
VERSION=${1:-1.0}
OUT=dist
APP=$OUT/MacTidy.app
STAGE=$OUT/dmg

echo "1/4 Build universal (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/MacTidy

echo "2/4 Tạo MacTidy.app"
rm -rf $OUT && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" $OUT/icon.iconset
cp "$BIN" "$APP/Contents/MacOS/MacTidy"
swift scripts/make_icon.swift $OUT/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s $OUT/icon_1024.png --out $OUT/icon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) $OUT/icon_1024.png --out $OUT/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $OUT/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<EOF
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
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>MacTidy dùng Finder để dọn Thùng rác.</string>
</dict></plist>
EOF
scripts/install_l10n.sh "$APP"
# Ký ad-hoc với điều kiện nhận diện theo bundle id (giữ quyền Trợ năng khi cập nhật bản mới)
codesign --force --deep -s - -r='designated => identifier "io.github.huahuu1.mactidy"' "$APP"

echo "3/4 Chuẩn bị nội dung DMG"
mkdir -p $STAGE
cp -R "$APP" $STAGE/
ln -s /Applications $STAGE/Applications
cp "dist-assets/Huong-dan-cai-dat.txt" "$STAGE/Hướng dẫn cài đặt.txt"
cp "dist-assets/Install-Guide.txt" "$STAGE/Install Guide.txt"

echo "4/4 Tạo DMG"
DMG=$OUT/MacTidy-$VERSION.dmg
hdiutil create -volname "MacTidy $VERSION" -srcfolder $STAGE -ov -format UDZO "$DMG" >/dev/null
rm -rf $STAGE $OUT/icon.iconset $OUT/icon_1024.png
echo "Xong: $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))"
