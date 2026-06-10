#!/bin/bash
# Run the test suite on a Command Line Tools-only machine (no Xcode).
#
# Plain `swift test` fails here: CLT ships Testing.framework outside the
# default search paths, and its lib_TestingInterop.dylib lives in a directory
# no default rpath covers. Point both at the right places explicitly.

set -euo pipefail
cd "$(dirname "$0")/.."

FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib

exec swift test \
  -Xswiftc -F"$FW" \
  -Xlinker -F"$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$@"
