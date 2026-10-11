#!/bin/zsh
# 官網與 README 用的 App 截圖：在假的資料夾裡放一組像真的檔案，讓 App 真的打開抽屜與設定
# 每個視窗，再用 screencapture 連同視窗外框與陰影拍下來（需要終端機有「螢幕錄製」權限）。
# 用法：scripts/screenshots.sh [語言，預設 zh-Hant] [light|dark]   輸出：build/screenshots/*.png
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/screenshots
# 示範檔案放在 /Users/Shared，路徑列才不會露出建置資料夾；拍完就刪
DEMO="/Users/Shared/Findly Demo"
rm -rf "$OUT" && mkdir -p "$OUT"
xcodegen generate --quiet
xcodebuild -project Findly.xcodeproj -scheme Findly -configuration Debug \
  -derivedDataPath build/xcode.noindex build | grep -E "error:|BUILD FAILED" || true
APP=build/xcode.noindex/Build/Products/Debug/Findly.app/Contents/MacOS/Findly

FINDLY_HOME="$DEMO" FINDLY_SHOTS="$PWD/$OUT" FINDLY_SELFTEST=screenshots \
  "$APP" -AppleLanguages "(\"${1:-zh-Hant}\")" -Findly.appearance "${2:-dark}" > "$OUT/log" 2>&1 &
PID=$!
for _ in {1..600}; do
  for req in "$OUT"/*.request(N); do
    name=$(basename "$req" .request)
    # 名稱以 .noshadow 結尾的不拍陰影（官網的抽屜示範要貼齊邊緣）
    flags=(-x); [[ "$name" == *.noshadow ]] && flags+=(-o)
    screencapture "${flags[@]}" -l "$(cat "$req")" "$OUT/$name.full.png"
    sips -Z 1600 "$OUT/$name.full.png" --out "$OUT/$name.png" >/dev/null
    rm -f "$req" "$OUT/$name.full.png"
    echo "拍好：$name"
  done
  kill -0 $PID 2>/dev/null || break
  sleep 0.1
done
kill $PID 2>/dev/null || true
rm -rf "${DEMO:?}"
grep -E "SCREENSHOTS|no capture" "$OUT/log"
