#!/bin/zsh
# 重拍 README 與官網用的截圖並放進 docs/（螢幕要解鎖、終端機要有「螢幕錄製」權限）。
# 用法：scripts/docs-shots.sh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p docs/readme-shots docs/shots
for lang in zh-Hant en; do
  for ap in dark light; do
    # 欄寬會被記住，先清掉，每張都用預設欄寬
    defaults delete com.findly.app.debug Findly.columnWidths 2>/dev/null || true
    scripts/screenshots.sh "$lang" "$ap" >/dev/null
    S=build/screenshots
    [[ -f "$S/drawer.png" ]] || { echo "沒拍到 $lang $ap（螢幕鎖定？）" >&2; exit 1; }
    cp "$S/drawer.png" "docs/readme-shots/$lang-drawer-$ap.png"
    if [[ "$ap" == dark ]]; then
      cp "$S/settings-shortcuts.png" "docs/readme-shots/$lang-settings-shortcuts-dark.png"
      short=${lang%-Hant}
      sips -Z 1000 "$S/drawer-tall.noshadow.png" --out "docs/shots/drawer-${short}-dark.png" >/dev/null
    fi
    echo "完成：$lang $ap"
  done
done
