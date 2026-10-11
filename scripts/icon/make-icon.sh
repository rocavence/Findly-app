#!/bin/bash
# 由 make-icon.swift 繪製 1024×1024 母圖，再切成資產目錄的 AppIcon 各尺寸。
set -euo pipefail
cd "$(dirname "$0")/../.."

SRC="scripts/icon/icon-1024.png"
SET="Findly/Resources/Assets.xcassets/AppIcon.appiconset"

if [[ "${1:-}" != "--keep" ]]; then
  echo "→ 繪製 1024×1024 母圖"
  swift scripts/icon/make-icon.swift
fi

mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$SRC" --out "$SET/icon_${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$SRC" --out "$SET/icon_${size}@2x.png" >/dev/null
done
echo "完成：${SET}"
