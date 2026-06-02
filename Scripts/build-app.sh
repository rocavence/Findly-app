#!/bin/bash
# Build Findly as a proper macOS .app bundle.
# Output: build/Findly.app
#
# Requires: Xcode Command Line Tools (swift, codesign).
# Drag the resulting .app into /Applications, or run `open build/Findly.app`.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Findly"
APP_DIR="build/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RES_DIR="${CONTENTS}/Resources"

echo "→ swift build (release)"
swift build -c release

echo "→ assembling bundle at ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"

cp ".build/release/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
cp "Resources/Info.plist" "${CONTENTS}/Info.plist"
if [[ -f "Resources/AppIcon.icns" ]]; then
  cp "Resources/AppIcon.icns" "${RES_DIR}/AppIcon.icns"
fi

# Localizations: copy every Resources/*.lproj into the bundle's Resources so the
# .strings load from Bundle.main at runtime (NSLocalizedString). Required — SwiftPM
# doesn't bundle these for us, and without them only English keys would resolve.
for lproj in Resources/*.lproj; do
  [[ -d "$lproj" ]] && cp -R "$lproj" "${RES_DIR}/"
done

# PkgInfo is optional but conventional.
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# Sign with a stable self-signed identity when present, so macOS keeps the
# Full Disk Access grant across rebuilds (ad-hoc signatures change every build,
# which silently invalidates the TCC grant). Falls back to ad-hoc otherwise.
SIGN_IDENTITY="Findly Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -q "${SIGN_IDENTITY}"; then
  echo "→ codesign with ${SIGN_IDENTITY}"
  codesign --force --deep --sign "${SIGN_IDENTITY}" --timestamp=none "${APP_DIR}"
else
  echo "→ ad-hoc codesign (no '${SIGN_IDENTITY}' identity found)"
  codesign --force --deep --sign - "${APP_DIR}"
fi

echo
echo "Done. Open with:  open ${APP_DIR}"
echo "Or install:       cp -R ${APP_DIR} /Applications/"
