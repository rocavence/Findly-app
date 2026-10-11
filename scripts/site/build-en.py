#!/usr/bin/env python3
"""從 docs/index.html（中文）產生 docs/en/index.html（英文靜態頁），讓搜尋引擎與 LLM 不跑 JavaScript 也讀得到英文。

文字取自頁面裡的 I18N.en（用 node 讀出），套進每個 data-i 元素；head 的標題、描述、canonical、og 換成英文。
改完 docs/index.html 的文案就重跑：python3 scripts/site/build-en.py
"""

import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "docs/index.html"
OUT = ROOT / "docs/en/index.html"
SITE = "https://findly.rocavence.com"

TITLE = "Findly — a Finder-style file drawer that slides in from any screen edge on Mac"
DESC = ("Findly is a free, open-source macOS menu bar app: press Ctrl + ~ and a Finder-style file drawer "
        "slides in from any screen edge, then slides away when you switch apps. Finder's sidebar and list view, "
        "every Space, macOS 14+.")
SHORT = "Press Ctrl + ~ and a Finder-style file drawer slides in from any screen edge. Free, open source, lives in the menu bar."


def i18n_en(html: str) -> dict:
    start = html.index("const I18N = {")
    end = html.index("\n};", start) + 3
    js = html[start:end] + "\nprocess.stdout.write(JSON.stringify(I18N.en));"
    return json.loads(subprocess.run(["node", "-e", js], capture_output=True, text=True, check=True).stdout)


def replace_inner(html: str, key: str, value: str) -> str:
    """Replaces the contents of every element carrying data-i="key"."""
    pos = 0
    attr = f'data-i="{key}"'
    while (i := html.find(attr, pos)) != -1:
        tag_start = html.rfind("<", 0, i)
        name = re.match(r"<(\w+)", html[tag_start:]).group(1)
        open_end = html.index(">", i) + 1
        depth, j = 1, open_end
        pattern = re.compile(rf"<(/?){name}\b[^>]*>")
        while depth:
            m = pattern.search(html, j)
            depth += -1 if m.group(1) else 1
            j = m.end()
        close_start = j - len(f"</{name}>")
        html = html[:open_end] + value + html[close_start:]
        pos = open_end + len(value)
    return html


def sub1(html: str, old: str, new: str) -> str:
    assert old in html, f"找不到：{old[:60]}"
    return html.replace(old, new, 1)


def main() -> None:
    html = SRC.read_text()
    en = i18n_en(html)
    for key, value in en.items():
        if f'data-i="{key}"' in html:
            html = replace_inner(html, key, value)

    html = sub1(html, '<html lang="zh-Hant">', '<html lang="en">')
    html = re.sub(r"<title>.*?</title>", f"<title>{TITLE}</title>", html, count=1)
    html = re.sub(r'<meta name="description" content="[^"]*">', f'<meta name="description" content="{DESC}">', html, count=1)
    html = re.sub(r'<meta name="keywords" content="[^"]*">',
                  '<meta name="keywords" content="Findly, macOS file drawer, Finder alternative, menu bar app, slide-out drawer, '
                  'quick file access, global hotkey, macOS file browser, Homebrew cask">', html, count=1)
    html = sub1(html, f'<link rel="canonical" href="{SITE}/">', f'<link rel="canonical" href="{SITE}/en/">')
    html = sub1(html, f'<meta property="og:url" content="{SITE}/">', f'<meta property="og:url" content="{SITE}/en/">')
    html = re.sub(r'<meta property="og:title" content="[^"]*">', f'<meta property="og:title" content="{TITLE}">', html, count=1)
    html = re.sub(r'<meta property="og:description" content="[^"]*">', f'<meta property="og:description" content="{SHORT}">', html, count=1)
    html = re.sub(r'<meta property="og:image:alt" content="[^"]*">', f'<meta property="og:image:alt" content="{TITLE}">', html, count=1)
    html = sub1(html, f'<meta property="og:image" content="{SITE}/og.png">', f'<meta property="og:image" content="{SITE}/og-en.png">')
    html = sub1(html, '<meta property="og:locale" content="zh_TW">\n<meta property="og:locale:alternate" content="en_US">',
                '<meta property="og:locale" content="en_US">\n<meta property="og:locale:alternate" content="zh_TW">')
    html = re.sub(r'<meta name="twitter:title" content="[^"]*">', f'<meta name="twitter:title" content="{TITLE}">', html, count=1)
    html = re.sub(r'<meta name="twitter:description" content="[^"]*">', f'<meta name="twitter:description" content="{SHORT}">', html, count=1)
    html = sub1(html, f'<meta name="twitter:image" content="{SITE}/og.png">', f'<meta name="twitter:image" content="{SITE}/og-en.png">')
    html = sub1(html, 'src="/shots/drawer-zh-dark.png"', 'src="/shots/drawer-en-dark.png"')
    html = sub1(html, 'alt="Findly 抽屜的實際畫面"', 'alt="The real Findly drawer"')
    html = html.replace('<button data-lang="zh" class="on">中</button>', '<button data-lang="zh">中</button>')
    html = html.replace('<button data-lang="en">EN</button>', '<button data-lang="en" class="on">EN</button>')
    html = sub1(html, "<!DOCTYPE html>\n", "<!DOCTYPE html>\n<!-- 由 scripts/site/build-en.py 從 docs/index.html 產生，不要直接改 -->\n")

    left = re.findall(r"[一-鿿]+", re.sub(r"const I18N = \{.*?\n\};", "", html, flags=re.S))
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(html)
    print(f"寫入 {OUT.relative_to(ROOT)}；I18N 以外還有中文：{sorted(set(left))[:20]}")


if __name__ == "__main__":
    main()
