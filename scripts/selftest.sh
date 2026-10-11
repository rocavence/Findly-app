#!/bin/zsh
# 端對端自我測試：在假的資料夾裡實際讀取、改名、複製、開瀏覽器與設定視窗，
# 不會碰你真正的檔案。
# 用法：scripts/selftest.sh [項目]   紀錄在 build/selftest/log，截圖在 build/selftest/shots
# 項目：reader operations browser windows（不填就全跑）
# 換語言或外觀：FINDLY_LANG=ja FINDLY_APPEARANCE=dark scripts/selftest.sh windows
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/selftest
rm -rf "$OUT" && mkdir -p "$OUT/shots"

xcodegen generate --quiet
xcodebuild -project Findly.xcodeproj -scheme Findly -configuration Debug \
  -derivedDataPath build/xcode.noindex build | grep -E "error:|BUILD FAILED" || true
APP=build/xcode.noindex/Build/Products/Debug/Findly.app/Contents/MacOS/Findly

APPEARANCE=()
[[ -n "${FINDLY_APPEARANCE:-}" ]] && APPEARANCE=(-Findly.appearance "$FINDLY_APPEARANCE")
FINDLY_HOME="$PWD/$OUT/fixture" FINDLY_SHOTS="$PWD/$OUT/shots" FINDLY_SELFTEST="${1:-all}" \
  "$APP" -AppleLanguages "(\"${FINDLY_LANG:-zh-Hant}\")" "${APPEARANCE[@]}" > "$OUT/log" 2>&1 &
PID=$!
for _ in {1..90}; do
  sleep 1
  kill -0 $PID 2>/dev/null || break
done
kill $PID 2>/dev/null || true
grep -E "PASS|FAIL|SELFTEST" "$OUT/log"
grep -q "SELFTEST OK" "$OUT/log"
