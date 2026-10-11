#!/usr/bin/env python3
"""由 translations.py 產生 Findly/Resources/Localizable.xcstrings。

用法：先建置一次（xcodebuild 會擷取程式裡的字串），再執行
  python3 scripts/l10n/build-catalog.py
程式裡有、翻譯表沒有的字串會列出來並以失敗結束。
"""
import glob
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).parent))
from translations import LANGS, T  # noqa: E402

CATALOG = ROOT / "Findly/Resources/Localizable.xcstrings"
EXTRACTED = ROOT / "build/xcode.noindex/Build/Intermediates.noindex/Findly.build/Debug/Findly.build/Objects-normal/arm64"


def extracted() -> dict[str, str]:
    keys: dict[str, str] = {}
    for f in glob.glob(str(EXTRACTED / "*.stringsdata")):
        data = json.load(open(f))
        if data.get("source", "").endswith("SelfTest.swift"):
            continue
        for entries in data.get("tables", {}).values():
            for e in entries:
                keys.setdefault(e["key"], e.get("comment", ""))
    return keys


def main() -> int:
    keys = extracted()
    if not keys:
        print("找不到擷取的字串，請先建置 Debug 版", file=sys.stderr)
        return 1
    missing = sorted(k for k in keys if k not in T)
    if missing:
        print("翻譯表缺少：\n  " + "\n  ".join(missing), file=sys.stderr)
        return 1
    for k, values in T.items():
        assert len(values) == len(LANGS), k
    strings = {}
    for key in sorted(keys):
        loc = {"en": {"stringUnit": {"state": "translated", "value": key}}}
        for lang, value in zip(LANGS, T[key]):
            loc[lang] = {"stringUnit": {"state": "translated", "value": value}}
        entry = {"localizations": loc}
        if keys[key]:
            entry["comment"] = keys[key]
        strings[key] = entry
    CATALOG.write_text(json.dumps({"sourceLanguage": "en", "strings": strings, "version": "1.0"},
                                  ensure_ascii=False, indent=2) + "\n")
    unused = sorted(set(T) - set(keys))
    print(f"寫入 {len(strings)} 個字串 × {len(LANGS) + 1} 種語言" + (f"；翻譯表多出：{unused}" if unused else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
