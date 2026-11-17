#!/bin/zsh -f
# Phát hành bản mới: build DMG, tạo GitHub Release, cập nhật Homebrew cask.
# Dùng: ./release.sh 1.1
# Cần: gh đã đăng nhập, repo huahuu1/homebrew-tap clone ở ../homebrew-tap (script tự clone nếu chưa có).
set -e
cd "${0:A:h}"
VERSION=${1:?Thiếu số phiên bản, ví dụ: ./release.sh 1.1}
REPO=huahuu1/MacTidy
TAP_DIR=../homebrew-tap

./package.sh $VERSION
DMG=dist/MacTidy-$VERSION.dmg
SHA=$(shasum -a 256 $DMG | cut -d' ' -f1)

gh release create v$VERSION $DMG --repo $REPO --title "MacTidy $VERSION" --generate-notes

[[ -d $TAP_DIR ]] || gh repo clone huahuu1/homebrew-tap $TAP_DIR
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA/" scripts/mactidy.rb.template > $TAP_DIR/Casks/mactidy.rb
git -C $TAP_DIR add Casks/mactidy.rb
git -C $TAP_DIR commit -m "mactidy $VERSION"
git -C $TAP_DIR push
echo "Xong: v$VERSION, sha256 $SHA"
