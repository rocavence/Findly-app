#!/bin/zsh
# 建置 Release 版 Findly（本機簽章，未公證），打包成發版用的 zip。
# 用法：scripts/build-app.sh [--install]   輸出：dist/Findly-<版本>.zip
#   --install  順便換掉「應用程式」裡的 Findly（先正常結束正在執行的版本，讓它把手上的工作做完）
# 建置輸出放在 build/xcode.noindex：資料夾名稱結尾是 .noindex，Spotlight 不會把裡面的 app
# 當成另一份 Findly 列進搜尋結果；dist 也只放 zip，不放 .app。
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project Findly.xcodeproj -scheme Findly -configuration Release \
  -derivedDataPath build/xcode.noindex build | grep -E "error:|BUILD" || true

APP=build/xcode.noindex/Build/Products/Release/Findly.app
[[ -d "$APP" ]] || { echo "建置失敗：找不到 $APP" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p dist
rm -f "dist/Findly-${VERSION}.zip"
ditto -c -k --keepParent "$APP" "dist/Findly-${VERSION}.zip"
echo "完成：dist/Findly-${VERSION}.zip"
shasum -a 256 "dist/Findly-${VERSION}.zip"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app id "com.findly.app"' 2>/dev/null || true
  for _ in {1..10}; do pgrep -f /Applications/Findly.app >/dev/null || break; sleep 0.5; done
  rm -rf /Applications/Findly.app
  ditto "$APP" /Applications/Findly.app
  open /Applications/Findly.app
  echo "已安裝並開啟：/Applications/Findly.app ${VERSION}"
fi
