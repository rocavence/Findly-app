#!/usr/bin/env python3
"""發版後更新 Homebrew tap（rocavence/homebrew-tap）的 Findly cask：版本與 zip 的 sha256 取自 GitHub 最新的 release。

用法：python3 scripts/update-cask.py          更新並 push
      python3 scripts/update-cask.py --dry-run  只印出 cask
tap 的本機位置：環境變數 FINDLY_TAP，預設 ~/Code/_app/homebrew-tap（沒有就 clone）
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = "rocavence/Findly-app"
TAP_REPO = "rocavence/homebrew-tap"
TAP = Path(os.environ.get("FINDLY_TAP", Path.home() / "Code/_app/homebrew-tap"))

CASK = """\
cask "findly" do
  version "{version}"
  sha256 "{sha256}"

  url "https://github.com/rocavence/Findly-app/releases/download/v#{{version}}/Findly-#{{version}}.zip"
  name "Findly"
  desc "Finder-style file drawer that slides in from any screen edge"
  homepage "https://findly.rocavence.com/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Findly.app"

  # Not notarized by Apple: remove the quarantine flag so the first launch isn't blocked.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{{{appdir}}}}/Findly.app"]
  end

  uninstall quit: "com.findly.app"

  zap trash: "~/Library/Preferences/com.findly.app.plist"
end
"""


def run(*args: str, cwd: Path | None = None) -> str:
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout


def main() -> int:
    release = json.loads(run("gh", "api", f"repos/{REPO}/releases/latest"))
    version = release["tag_name"].removeprefix("v")
    asset = next((a for a in release["assets"] if a["name"] == f"Findly-{version}.zip"), None)
    sha256 = ((asset or {}).get("digest") or "").removeprefix("sha256:")
    if not sha256:
        print(f"v{version} 缺少 Findly-{version}.zip 或 sha256", file=sys.stderr)
        return 1

    # 版本與 sha256 會寫進 Ruby 程式碼，只接受預期的格式，避免被竄改的 release 注入程式碼
    if not re.fullmatch(r"\d+(\.\d+){1,3}", version) or not re.fullmatch(r"[0-9a-f]{64}", sha256):
        print(f"版本或 sha256 格式不對：{version!r} {sha256!r}", file=sys.stderr)
        return 1

    cask = CASK.format(version=version, sha256=sha256)
    if "--dry-run" in sys.argv:
        sys.stdout.write(cask)
        return 0

    if not TAP.exists():
        run("gh", "repo", "clone", TAP_REPO, str(TAP))
    run("git", "pull", "--quiet", "--ff-only", cwd=TAP)
    path = TAP / "Casks/findly.rb"
    if path.exists() and path.read_text() == cask:
        print(f"cask 已經是 {version}")
        return 0
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(cask)
    run("git", "add", "Casks/findly.rb", cwd=TAP)
    run("git", "commit", "--quiet", "-m", f"findly {version}", cwd=TAP)
    run("git", "push", "--quiet", cwd=TAP)
    print(f"cask 更新為 {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
