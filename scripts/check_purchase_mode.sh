#!/usr/bin/env bash
#
# Says whether a built app sells Pro, by the marker string only the Mac App Store build has (StoreBuild.marker in
# NameAlert/Store/StoreBuild.swift, compiled only with APP_STORE_BUILD, which only scripts/build_appstore.sh sets).
#
#   scripts/check_purchase_mode.sh <App.app> --sells          fails unless the app sells Pro (the App Store build)
#   scripts/check_purchase_mode.sh <App.app> --does-not-sell  fails if it does (every other build)
#
# Exit status: 0 when the app is what was asked for, 1 when it is not, 2 for a usage error.

set -euo pipefail

MARKER="app-store-build:pro-purchases-enforced"

usage() {
    echo "Usage: scripts/check_purchase_mode.sh <App.app> --sells|--does-not-sell" >&2
    exit 2
}

[[ $# -eq 2 ]] || usage
app="$1"
mode="$2"
[[ -d "$app/Contents/MacOS" ]] || { echo "ERROR: $app is not an app bundle." >&2; exit 1; }

sells=false
if grep -a -r -q -F "$MARKER" "$app/Contents/MacOS"; then
    sells=true
fi

case "$mode" in
    --sells)
        if ! $sells; then
            echo "ERROR: $app was built without APP_STORE_BUILD, so it would not sell Pro." >&2
            exit 1
        fi
        echo "Purchase check passed: $(basename "$app") sells Pro."
        ;;
    --does-not-sell)
        if $sells; then
            echo "ERROR: $app was built with APP_STORE_BUILD. Only the Mac App Store build may sell Pro." >&2
            exit 1
        fi
        echo "Purchase check passed: $(basename "$app") does not sell Pro (everything is on)."
        ;;
    *)
        usage
        ;;
esac
