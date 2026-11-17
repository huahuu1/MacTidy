#!/bin/zsh -f
# Chép bản dịch vào MacTidy.app.
# Chữ gốc trong code là tiếng Việt, nên vi.lproj để trống (dùng luôn chữ gốc), en.lproj chứa bản dịch.
set -e
APP=$1
R="$APP/Contents/Resources"
mkdir -p "$R/en.lproj" "$R/vi.lproj"
plutil -convert binary1 Localization/en.json -o "$R/en.lproj/Localizable.strings"
echo '{}' | plutil -convert binary1 - -o "$R/vi.lproj/Localizable.strings"
echo '{"NSAppleEventsUsageDescription": "MacTidy uses Finder to empty the Trash."}' \
  | plutil -convert binary1 - -o "$R/en.lproj/InfoPlist.strings"
