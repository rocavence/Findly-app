#!/usr/bin/env python3
"""把官網所有網址送給 IndexNow（Bing、Naver、Yandex、Seznam 等會互相分享），改完官網、部署好之後執行。

用法：python3 scripts/site/indexnow.py
網址取自線上的 sitemap.xml；金鑰是網站根目錄那個 32 碼 .txt（IndexNow 用它確認網站是我們的，本來就是公開的）。
"""

import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def site_root() -> Path:
    for name in ("docs", "site"):
        if (ROOT / name / "CNAME").exists():
            return ROOT / name
    sys.exit("找不到含 CNAME 的網站資料夾")


def main() -> None:
    root = site_root()
    host = (root / "CNAME").read_text().strip()
    keys = [p for p in root.glob("*.txt") if re.fullmatch(r"[0-9a-f]{32}", p.stem)]
    if not keys:
        sys.exit(f"{root} 沒有 IndexNow 金鑰檔")
    key = keys[0].stem
    with urllib.request.urlopen(f"https://{host}/sitemap.xml", timeout=20) as r:
        sitemap = r.read().decode()
    urls = sorted(set(re.findall(r"<loc>\s*([^<\s]+)\s*</loc>", sitemap)) | set(re.findall(r'hreflang="[^"]+" href="([^"]+)"', sitemap)))
    body = json.dumps({"host": host, "key": key, "keyLocation": f"https://{host}/{key}.txt", "urlList": urls}).encode()
    req = urllib.request.Request("https://api.indexnow.org/indexnow", data=body,
                                 headers={"Content-Type": "application/json; charset=utf-8"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            status = r.status
    except urllib.error.HTTPError as e:
        status = e.code
    meaning = {200: "已收下", 202: "已收下（金鑰稍後驗證）", 400: "格式錯誤", 403: "金鑰不符", 422: "網址和網站不符", 429: "送太頻繁"}
    print(f"{host}：送出 {len(urls)} 個網址 → {status} {meaning.get(status, '')}")
    for u in urls:
        print("  " + u)


if __name__ == "__main__":
    main()
