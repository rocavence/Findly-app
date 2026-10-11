#!/usr/bin/env python3
"""從 Reicon 的 icon-data.json 產生 Xcode Asset Catalog 與 Swift enum。

用法：python3 scripts/reicon/generate.py
"""

import json
import shutil
import sys
import urllib.request
from pathlib import Path

# 固定 Reicon 版本，升級時改這裡
REICON_COMMIT = "ceab2340577684a47d8e361172bdbcd75cb8c7f3"
DATA_URL = f"https://raw.githubusercontent.com/dqev/reicon/{REICON_COMMIT}/data/icon-data.json"

ROOT = Path(__file__).resolve().parents[2]
ICON_LIST = ROOT / "scripts/reicon/icons.txt"
# Reicon 沒有的 icon 自己畫，照 Reicon 的格線與粗細：custom/<名稱>.outline.svg、custom/<名稱>.filled.svg
CUSTOM = ROOT / "scripts/reicon/custom"
CACHE = ROOT / ".cache/reicon" / f"icon-data-{REICON_COMMIT[:12]}.json"
CATALOG = ROOT / "Findly/Resources/Assets.xcassets/Reicon"
SWIFT_OUT = ROOT / "Findly/DesignSystem/Reicon+Generated.swift"

WEIGHTS = {"Outline": "outline", "Filled": "filled"}
SWIFT_KEYWORDS = {"repeat", "default", "case", "in", "is", "as", "return", "self", "func", "var", "let"}


def load_data() -> dict:
    if not CACHE.exists():
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        print(f"下載 {DATA_URL}")
        urllib.request.urlretrieve(DATA_URL, CACHE)
    return json.loads(CACHE.read_text())


def load_names() -> list[str]:
    lines = (l.strip() for l in ICON_LIST.read_text().splitlines())
    return [l for l in lines if l and not l.startswith("#")]


def to_svg(code: str) -> str:
    # CoreSVG 不支援 currentColor；template image 只看 alpha，顏色固定黑色即可
    code = code.replace("currentColor", "#000000")
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" '
        f'viewBox="0 0 24 24" fill="none">{code}</svg>\n'
    )


def write_json(path: Path, obj: dict) -> None:
    path.write_text(json.dumps(obj, indent=2) + "\n")


def swift_case(name: str) -> str:
    head, *rest = name.split("-")
    ident = head + "".join(p.capitalize() for p in rest)
    return f"`{ident}`" if ident in SWIFT_KEYWORDS else ident


def main() -> int:
    data = load_data()
    icons = {n: v for c in data["categories"].values() for n, v in c["icons"].items()}
    names = load_names()
    custom = {p.name.split(".")[0] for p in CUSTOM.glob("*.svg")}

    missing = [n for n in names if n not in icons and n not in custom]
    if missing:
        print(f"Reicon 沒有這些 icon：{', '.join(missing)}", file=sys.stderr)
        return 1

    if CATALOG.exists():
        shutil.rmtree(CATALOG)
    CATALOG.mkdir(parents=True)
    write_json(CATALOG / "Contents.json", {
        "info": {"author": "xcode", "version": 1},
        "properties": {"provides-namespace": True},
    })

    for name in names:
        for weight, suffix in WEIGHTS.items():
            if name in custom:
                source = CUSTOM / f"{name}.{suffix}.svg"
                if not source.exists():
                    print(f"{name} 缺少 {source.name}", file=sys.stderr)
                    return 1
                svg = source.read_text()
            else:
                weights = icons[name]["weights"]
                if weight not in weights:
                    print(f"{name} 缺少 {weight}", file=sys.stderr)
                    return 1
                svg = to_svg(weights[weight]["code"])
            imageset = CATALOG / f"{name}.{suffix}.imageset"
            imageset.mkdir()
            (imageset / f"{name}.{suffix}.svg").write_text(svg)
            write_json(imageset / "Contents.json", {
                "images": [{"filename": f"{name}.{suffix}.svg", "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1},
                "properties": {
                    "preserves-vector-representation": True,
                    "template-rendering-intent": "template",
                },
            })

    cases = "\n".join(f'    case {swift_case(n)} = "{n}"' for n in names)
    SWIFT_OUT.parent.mkdir(parents=True, exist_ok=True)
    SWIFT_OUT.write_text(
        "// 由 scripts/reicon/generate.py 產生，請勿手動修改\n"
        f"// Reicon commit {REICON_COMMIT}\n\n"
        "enum Reicon: String, CaseIterable, Sendable {\n"
        f"{cases}\n"
        "}\n"
    )

    print(f"產生 {len(names)} 個 icon × {len(WEIGHTS)} weights")
    return 0


if __name__ == "__main__":
    sys.exit(main())
