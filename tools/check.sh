#!/usr/bin/env bash
# Pre-push check — the same two jobs CI runs (.github/workflows/ci.yml).
#
#   tools/check.sh          core tests + app compile
#   tools/check.sh core     core tests only (fast inner loop)
#
# Neither job launches the app: they prove the engines are correct and the app still
# compiles. Whether it *feels* right is what the phone is for.
set -euo pipefail

cd "$(dirname "$0")/.."

# Xcode's toolchain, so `swift test` matches CI rather than whatever's on PATH.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }

bold "▸ Core tests (swift test)"
( cd DeckCheckCore && swift test )

if [ "${1:-all}" = "core" ]; then
  bold "✓ Core tests passed (skipped the app build)"
  exit 0
fi

bold "▸ App compiles (xcodebuild)"
xcodebuild \
  -project ios/DeckCheck.xcodeproj \
  -scheme DeckCheck \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build \
  | grep -Ev '^$' | tail -5

bold "✓ All checks passed"
