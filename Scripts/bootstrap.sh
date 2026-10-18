#!/usr/bin/env bash
#
# One-time setup after cloning.
#
#   1. builds the Rust scanner core and places the archive where SwiftPM and
#      Xcode both look for it,
#   2. regenerates the string catalog and its `.lproj` outputs,
#   3. regenerates the Swift protection list from the Rust constants,
#   4. regenerates the rule table the app ships from the Rust rule table,
#   5. regenerates the Xcode project from `project.yml`.
#
# Usage: Scripts/bootstrap.sh [--universal]

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
REPO_ROOT="$(cd "$(dirname "${SCRIPT_PATH}")/.." && pwd)"
cd "${REPO_ROOT}"

"${REPO_ROOT}/Scripts/build-rust-core.sh" "$@"

echo "==> Regenerating localisations"
python3 Scripts/generate-strings.py >/dev/null

echo "==> Regenerating the protection list"
python3 Scripts/generate-protection.py >/dev/null

echo "==> Regenerating the rule table"
python3 Scripts/generate-rules.py >/dev/null

if command -v xcodegen >/dev/null 2>&1; then
  echo "==> Regenerating Sift.xcodeproj"
  xcodegen generate --spec project.yml >/dev/null
else
  echo "==> xcodegen is not installed; Sift.xcodeproj will not be regenerated"
  echo "    brew install xcodegen"
fi

echo
echo "Ready:"
echo "  swift build                 # SwiftPM (Rust core linked)"
echo "  Scripts/build-app.sh        # .app bundle"
echo "  open Sift.xcodeproj         # Xcode"
