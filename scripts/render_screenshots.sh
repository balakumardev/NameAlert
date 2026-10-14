#!/usr/bin/env bash
#
# Renders the six Mac App Store screenshots into appstore/screenshots/, as 2880 x 1800 PNGs (RGB, no alpha), from the
# app's real SwiftUI views filled with demo data.
#
#   scripts/render_screenshots.sh           all six
#   scripts/render_screenshots.sh 01 05     only the files whose names start with 01 and with 05
#   scripts/render_screenshots.sh --review  the App Review screenshot of the Pro purchase, into appstore/review-screenshots/
#
# Environment:
#   SCREENSHOTS_OUT   the folder the finished PNGs go to (default: appstore/screenshots)
#   DERIVED_DATA      passed to xcodebuild as -derivedDataPath
#
# How: xcodegen, then `xcodebuild test` on the Screenshots scheme, running only AppStoreScreenshotTests. That test runs
# inside ScreenshotHost, an app made from Takeheed's sources without its @main, Info.plist or entitlements, so
# Takeheed itself is never started: nothing listens, nothing is downloaded or sent, and the views read no real
# settings or Keychain item (they get demo data and inert stand-ins). The test draws each screen offscreen, puts it on
# the brand gradient with its headline and writes the PNG. This script checks every PNG with sips (2880 x 1800, no
# alpha) in a scratch folder first, and copies them into appstore/screenshots/ only when all of them pass.
#
# Needs a logged-in macOS session: the views are drawn in real (offscreen) windows.

set -euo pipefail

# Paths in the environment are relative to where the script was started, not to the repository it moves into.
for name in SCREENSHOTS_OUT DERIVED_DATA; do
    value="${!name:-}"
    if [[ -n "$value" && "$value" != /* ]]; then
        printf -v "$name" '%s' "$PWD/$value"
    fi
done

cd "$(dirname "${BASH_SOURCE[0]}")/.."
export PATH="/opt/homebrew/bin:$PATH"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "ERROR: xcodegen is not installed (brew install xcodegen)." >&2
    exit 1
fi

REVIEW=false
prefixes=()
for arg in "$@"; do
    if [[ "$arg" == "--review" ]]; then
        REVIEW=true
    else
        prefixes+=("$arg")
    fi
done

DEFAULT_OUT="appstore/screenshots"
if $REVIEW; then
    DEFAULT_OUT="appstore/review-screenshots"
fi
OUT="${SCREENSHOTS_OUT:-$DEFAULT_OUT}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

ONLY=""
if [[ ${#prefixes[@]} -gt 0 ]]; then
    ONLY="$(IFS=,; echo "${prefixes[*]}")"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/namealert-screenshots.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
STAGE="$WORK_DIR/png"
mkdir -p "$STAGE"
# Outside the scratch folder: it is kept when something goes wrong, and removed at the end when not.
LOG="$(mktemp "${TMPDIR:-/tmp}/namealert-screenshots-log.XXXXXX")"

xcodegen generate --quiet

# xcodebuild hands the variables that start with TEST_RUNNER_ to the test process, without the prefix.
SUITE=AppStoreScreenshotTests
RUNNER_ENV=("TEST_RUNNER_NAMEALERT_SCREENSHOTS_OUT=$STAGE")
if $REVIEW; then
    SUITE=ReviewScreenshotTests
    RUNNER_ENV+=(TEST_RUNNER_NAMEALERT_RENDER_REVIEW_SCREENSHOT=1)
else
    RUNNER_ENV+=(TEST_RUNNER_NAMEALERT_RENDER_SCREENSHOTS=1)
    if [[ -n "$ONLY" ]]; then
        RUNNER_ENV+=("TEST_RUNNER_NAMEALERT_SCREENSHOTS_ONLY=$ONLY")
    fi
fi

# English and US formats, so that times read "10:32 AM" whatever this Mac is set to.
XCODEBUILD=(
    xcodebuild test
    -project NameAlert.xcodeproj
    -scheme Screenshots
    -destination 'platform=macOS'
    -testLanguage en
    -testRegion US
    "-only-testing:NameAlertScreenshots/$SUITE"
)
if [[ -n "${DERIVED_DATA:-}" ]]; then
    XCODEBUILD+=(-derivedDataPath "$DERIVED_DATA")
fi

if $REVIEW; then
    echo "Rendering the App Review screenshot of the Pro purchase into $OUT"
else
    echo "Rendering ${ONLY:-all six screenshots} into $OUT"
fi
status=0
env "${RUNNER_ENV[@]}" "${XCODEBUILD[@]}" > "$LOG" 2>&1 || status=$?

# What the run said about the test, without the build output around it.
grep -E '^\[screenshots\]|: error:|^\*\* (TEST|BUILD)|^(✔|✘|◇) Test ' "$LOG" | sed 's/^/  /' || true
if [[ $status -ne 0 ]]; then
    echo "ERROR: rendering failed (xcodebuild exit $status). The full log is kept at $LOG" >&2
    if [[ "$(launchctl managername 2>/dev/null || true)" != "Aqua" ]]; then
        echo "       This session is not a logged-in macOS session, which the offscreen windows need." >&2
    fi
    exit "$status"
fi

# The store wants exactly 2880 x 1800 and no alpha channel. Check what this run wrote, before anything is replaced.
files=()
while IFS= read -r file; do
    files+=("$file")
done < <(sed -n 's/^\[screenshots\] wrote //p' "$LOG")
if [[ ${#files[@]} -eq 0 ]]; then
    echo "ERROR: no screenshots were written (the test was skipped, or none matched '$ONLY'). The full log is kept at $LOG" >&2
    exit 1
fi

bad=0
for file in "${files[@]}"; do
    info="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$file")"
    width="$(awk '/pixelWidth/ { print $2 }' <<<"$info")"
    height="$(awk '/pixelHeight/ { print $2 }' <<<"$info")"
    alpha="$(awk '/hasAlpha/ { print $2 }' <<<"$info")"
    if [[ "$width" == "2880" && "$height" == "1800" && "$alpha" == "no" ]]; then
        echo "  ok  $(basename "$file")  ${width}x${height}, no alpha"
    else
        echo "  !!  $(basename "$file")  ${width}x${height}, alpha: $alpha" >&2
        bad=1
    fi
done
if [[ $bad -ne 0 ]]; then
    echo "ERROR: a screenshot is not 2880x1800 without alpha, so none were copied. The full log is kept at $LOG" >&2
    exit 1
fi

for file in "${files[@]}"; do
    cp "$file" "$OUT/"
done
rm -f "$LOG"
echo "Wrote ${#files[@]} screenshot(s) to $OUT"
