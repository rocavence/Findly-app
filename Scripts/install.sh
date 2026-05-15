#!/bin/bash
# Build Findly and install it into /Applications.
#
# After this runs, open Findly from the Applications folder once so it can
# register itself for Launch at Login.

set -euo pipefail

cd "$(dirname "$0")/.."

DEST="/Applications/Findly.app"

./Scripts/build-app.sh

if pgrep -x Findly >/dev/null; then
  echo "→ quitting running Findly"
  osascript -e 'tell application "Findly" to quit' 2>/dev/null || pkill -x Findly || true
  sleep 1
fi

echo "→ installing to ${DEST}"
rm -rf "${DEST}"
cp -R build/Findly.app "${DEST}"

# Re-stamp the signature now that the path is final.
codesign --force --deep --sign - "${DEST}"

echo
echo "Installed. Launch with:"
echo "  open ${DEST}"
echo
echo "Then tick 'Launch at Login' from the menu bar to enable auto-start."
