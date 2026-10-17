#!/usr/bin/env bash
#
# Installs a downloaded Xcode and points the toolchain at it.
#
# Apple only serves the *current* Xcode, and the current Xcode needs macOS 26.
# This machine stays on macOS 15 (see AGENTS.md), so the download has to be an
# Xcode 16.x from developer.apple.com's Additional Downloads, which needs an Apple
# ID sign-in that only the owner can do. Everything after the download is here.
#
# Usage:
#   Scripts/install-xcode.sh ~/Downloads/Xcode_16.4.xip
#
# What it does:
#   1. refuses to run on an Xcode that needs a newer macOS than this machine,
#      so it cannot drag the system into an upgrade;
#   2. expands the .xip (about 25 GB) and moves Xcode.app into /Applications;
#   3. runs `xcode-select --switch`, which asks for your admin password once;
#   4. reports the toolchain, and tells you to run Scripts/verify.sh.
#
# It never deletes the .xip and never changes the macOS version.

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
REPO_ROOT="$(cd "$(dirname "${SCRIPT_PATH}")/.." && pwd)"

fail() { echo "error: $*" >&2; exit 1; }

[[ $# -eq 1 ]] || fail "usage: $0 /path/to/Xcode_16.x.xip"
XIP="$1"
[[ -f "${XIP}" ]] || fail "not a file: ${XIP}"
[[ "${XIP}" == *.xip ]] || fail "expected an .xip from developer.apple.com, got ${XIP}"

# --- 1. The machine stays where it is ----------------------------------------

OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
echo "==> macOS ${OS_VERSION}"

# Xcode 16.x is the line that runs on macOS 15. A newer download must be refused
# here rather than discovered after 25 GB of unpacking.
case "${XIP}" in
  *Xcode_1[6-9]*|*Xcode_2[0-5]*) ;;
  *Xcode_2[6-9]*|*Xcode_3*)
    fail "this looks like Xcode 26 or later, which requires macOS 26; this machine stays on ${OS_VERSION}"
    ;;
esac

if [[ "${OS_MAJOR}" -ge 26 ]]; then
  echo "note: this machine reports macOS ${OS_VERSION}; the guard above only protects the 15 line."
fi

# --- 2. Room to unpack --------------------------------------------------------

FREE_GB="$(( $(df -g / | awk 'NR==2 {print $4}') ))"
echo "==> free space on /: ${FREE_GB} GB"
[[ "${FREE_GB}" -ge 45 ]] || fail "need about 45 GB free to expand a .xip and keep the download"

# --- 3. Expand, check, move ---------------------------------------------------

# `xip` has no output directory: it expands beside the archive. Fail before that
# if an Xcode is already sitting there, rather than overwriting one.
WORK_DIR="$(cd "$(dirname "${XIP}")" && pwd)"
echo "==> expanding in ${WORK_DIR} (this takes a while)"
EXISTING="$(find "${WORK_DIR}" -maxdepth 1 -name 'Xcode*.app' -type d | head -1)"
[[ -z "${EXISTING}" ]] || fail "${EXISTING} already exists next to the archive; move it aside first"

xip --expand "${XIP}"

APP="$(find "${WORK_DIR}" -maxdepth 1 -name 'Xcode*.app' -type d | head -1)"
[[ -n "${APP}" ]] || fail "no Xcode .app came out of the archive"

INFO="${APP}/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO}" 2>/dev/null || echo "unknown")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${INFO}" 2>/dev/null || true)"
if [[ -z "${MIN_OS}" ]]; then
  MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumSystemVersion' "${INFO}" 2>/dev/null || true)"
fi
echo "==> ${APP##*/} ${VERSION}${MIN_OS:+, requires macOS ${MIN_OS}}"

# The one check that matters for the "no system upgrade" rule: if the app itself
# says it needs a newer macOS, stop before touching /Applications.
if [[ -n "${MIN_OS}" ]]; then
  REQUIRED_MAJOR="${MIN_OS%%.*}"
  CURRENT_MAJOR="${OS_VERSION%%.*}"
  if [[ "${REQUIRED_MAJOR}" -gt "${CURRENT_MAJOR}" ]]; then
    fail "${APP##*/} needs macOS ${MIN_OS}; this machine is on ${OS_VERSION} and is not upgraded"
  fi
fi

[[ -e /Applications/Xcode.app ]] && fail "/Applications/Xcode.app already exists; move it aside first"

echo "==> moving into /Applications"
mv "${APP}" /Applications/Xcode.app

# --- 4. Point the toolchain at it --------------------------------------------

echo "==> selecting the developer directory (asks for your password once)"
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer

echo
xcodebuild -version
echo
echo "Xcode is installed. What is now possible that was not before:"
echo "  swift test                      # the suite under the real XCTest"
echo "  xcodebuild test -scheme Sift    # the test plan, including the UI tests"
echo "  Scripts/verify.sh               # now runs the Xcode stage too"
echo
echo "The download is still at ${XIP}; it is safe to delete once verify.sh passes."
