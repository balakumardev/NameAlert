#!/usr/bin/env bash
#
# Builds Takeheed's Developer ID disk image, dist/Takeheed-<version>.dmg.
#
#   scripts/build_dmg.sh                 build, sign, notarize and staple
#   scripts/build_dmg.sh --no-notarize   build and sign, but do not send the app or the image to Apple's notary service
#   scripts/build_dmg.sh --unsigned      build the image without any signing: a dry run that needs no
#                                        certificate and no network (implies --no-notarize)
#
# What it does:
#   1. Checks everything it needs (tools, the signing identity, the notary key) before it builds anything.
#   2. Builds a universal (arm64 + x86_64) Release app and checks that every Mach-O in it has both slices.
#      It also checks that the app does not sell Pro: only the Mac App Store build does (scripts/check_purchase_mode.sh).
#   3. Signs the nested code and then the app with the hardened runtime and a secure timestamp, using the
#      app's one entitlements file (NameAlert/NameAlert.entitlements). No --deep: each piece is signed itself.
#   4. Notarizes the app by itself first: a zip of it goes to Apple's notary service (waits up to 60 minutes), and the
#      ticket is stapled to the app, so the copy in the disk image is a notarized app wherever it ends up.
#   5. Packs the stapled app and an Applications shortcut into a compressed disk image, and signs the image.
#   6. Sends the image to Apple's notary service (waits up to 60 minutes), staples the ticket to it and has
#      Gatekeeper assess it.
#   7. Writes dist/Takeheed-<version>.dmg.sha256 (shasum -a 256, run inside dist/, so `shasum -c` works there).
#
# Environment (names only; values are never printed):
#   BUILD_NUMBER          CFBundleVersion of the app. Default: git rev-list --count HEAD.
#   DEVELOPER_ID_SHA1     SHA-1 of the "Developer ID Application" identity to sign with. Default: the one for team
#                         KHD36T7C97 that the keychain below holds.
#   APPLE_BUILD_KEYCHAIN  Path of the keychain with that identity. Default: the keychain search list.
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
#                         App Store Connect API key for notarytool: the key id, the issuer id and the path of the
#                         .p8 file. Needed unless notarization is skipped.
#
# The script never stops or restarts a running app. Everything it builds goes under build/ and dist/, and the app it
# builds is taken out of LaunchServices again, so that macOS never opens that copy in place of the app in use.

set -euo pipefail

TEAM_ID="KHD36T7C97"
# The app's PRODUCT_NAME in project.yml: the bundle is $APP_NAME.app.
APP_NAME="Takeheed"
ENTITLEMENTS="NameAlert/NameAlert.entitlements"
# The name ends in .noindex: Spotlight skips such folders, so it never finds the throwaway app built here and
# registers it with LaunchServices again after unregister_apps took it out.
DERIVED_DATA="build/DerivedData.noindex"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

usage() {
    cat <<'EOF'
Usage: scripts/build_dmg.sh [--no-notarize] [--unsigned]

  --no-notarize   build and sign the disk image, but do not send the app or the image to Apple's notary service
  --unsigned      build the disk image without signing it: a dry run that needs no certificate
                  (implies --no-notarize)
  -h, --help      show this help
EOF
}

SIGN=true
NOTARIZE=true
for arg in "$@"; do
    case "$arg" in
        --no-notarize)
            NOTARIZE=false
            ;;
        --unsigned)
            SIGN=false
            NOTARIZE=false
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# Paths in the environment are relative to where the script was started, not to the repository it moves into.
for name in ASC_KEY_PATH APPLE_BUILD_KEYCHAIN; do
    value="${!name:-}"
    if [[ -n "$value" && "$value" != /* ]]; then
        printf -v "$name" '%s' "$PWD/$value"
    fi
done

cd "$(dirname "${BASH_SOURCE[0]}")/.."

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/namealert-dmg.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

log() {
    printf '==> %s\n' "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

problems=0
problem() {
    echo "ERROR: $*" >&2
    problems=$((problems + 1))
}

# The SHA-1 of the first valid identity whose name matches the awk pattern $1, if any. The other arguments are
# options for `security find-identity`.
find_identity() {
    local pattern="$1"
    shift
    security find-identity -v "$@" ${APPLE_BUILD_KEYCHAIN:+"$APPLE_BUILD_KEYCHAIN"} 2>/dev/null \
        | awk -v pattern="$pattern" '$0 ~ pattern && !found { print $2; found = 1 }'
}

# Succeeds when the keychain holds a valid identity with the SHA-1 $1.
identity_exists() {
    local found
    found="$(security find-identity -v ${APPLE_BUILD_KEYCHAIN:+"$APPLE_BUILD_KEYCHAIN"} 2>/dev/null \
        | awk -v sha="$1" 'toupper($2) == sha { found = 1 } END { print found + 0 }')"
    [[ "$found" == "1" ]]
}

# The top-level keys of the property list $1, one per line.
plist_keys() {
    /usr/libexec/PlistBuddy -c 'Print' "$1" | awk '/^    [^ ]/ { print $1 }'
}

# xcodebuild registers every app it builds with LaunchServices, and macOS may then open such a copy by its bundle id in
# place of the app in use: after a Screen Recording "Quit & Reopen" it opened an unsigned build from build/, which had
# neither the permissions nor the settings. This takes every app under the folder $1 out of LaunchServices again; the
# files stay.
# xcodebuild registers the app, and about a third of a second later siriknowledged registers it again as a
# launch-disabled copy, which is after the first pass when that one comes straight after the build. So this takes the
# apps out a second time, a few seconds later.
unregister_apps() {
    local app pass
    [[ -d "$1" ]] || return 0
    for pass in 1 2; do
        while IFS= read -r -d '' app; do
            "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
        done < <(find "$1" -type d -name '*.app' -prune -print0)
        [[ $pass -eq 2 ]] || sleep 3
    done
}

# Sends the file $1 (the app in a zip, or the disk image) to Apple's notary service and waits for the verdict. $2 says
# what the file is, for messages. Unless Apple accepted it, prints Apple's log and exits with 1.
notarize() {
    local file="$1" what="$2" out notary_status=0 submission_id final_status
    out="$WORK_DIR/notarytool-$(basename "$file").txt"
    log "Sending $what to Apple's notary service (waits up to 60 minutes)"
    xcrun notarytool submit "$file" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
        --wait --timeout 60m > "$out" 2>&1 || notary_status=$?
    cat "$out"

    # The text output ends with "  status: Accepted" (or Invalid, Rejected) under "Processing complete".
    submission_id="$(awk '$1 == "id:" && !found { print $2; found = 1 }' "$out")"
    final_status="$(awk '$1 == "status:" { s = $2 } END { print s }' "$out")"
    if [[ $notary_status -ne 0 || "$final_status" != "Accepted" ]]; then
        echo "ERROR: Apple's notary service did not accept $what (notarytool exit $notary_status, status '${final_status:-none}')." >&2
        if [[ -n "$submission_id" ]]; then
            echo "The notary log for submission $submission_id:" >&2
            xcrun notarytool log "$submission_id" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" >&2 || true
        fi
        exit 1
    fi
}

# ---------------------------------------------------------------------------------------------------------------------
# Preflight: find every problem before the build starts, and report them all together.
# ---------------------------------------------------------------------------------------------------------------------

tools=(git xcodebuild xcodegen lipo plutil hdiutil ditto shasum)
if $SIGN; then
    tools+=(codesign security)
fi
if $NOTARIZE; then
    tools+=(xcrun spctl)
fi
for tool in "${tools[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        if [[ "$tool" == "xcodegen" ]]; then
            problem "xcodegen is not installed (brew install xcodegen)."
        else
            problem "$tool is not installed or not on PATH."
        fi
    fi
done

number_re='^[0-9]+(\.[0-9]+){0,2}$'
BUILD="${BUILD_NUMBER:-}"
if [[ -z "$BUILD" ]]; then
    if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo true)" != "false" ]]; then
        problem "This is a shallow clone, so the commit count would be wrong. Fetch the full history or set BUILD_NUMBER."
    elif ! BUILD="$(git rev-list --count HEAD 2>/dev/null)"; then
        problem "Could not count the commits for the build number. Set BUILD_NUMBER."
    fi
fi
if [[ -n "$BUILD" ]] && ! [[ "$BUILD" =~ $number_re ]]; then
    problem "The build number '$BUILD' must be one to three integers separated by periods, such as 123."
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
    problem "$ENTITLEMENTS was not found."
fi

IDENTITY=""
if $SIGN; then
    IDENTITY="$(printf '%s' "${DEVELOPER_ID_SHA1:-}" | tr -d '[:space:]' | tr 'a-f' 'A-F')"
    if [[ -z "$IDENTITY" ]]; then
        IDENTITY="$(find_identity '"Developer ID Application: .*[(]'"$TEAM_ID"'[)]"' -p codesigning || true)"
        if [[ -z "$IDENTITY" ]]; then
            problem "No Developer ID Application identity for team $TEAM_ID was found${APPLE_BUILD_KEYCHAIN:+ in $APPLE_BUILD_KEYCHAIN}. Set DEVELOPER_ID_SHA1, or point APPLE_BUILD_KEYCHAIN at the keychain that has it."
        fi
    elif ! [[ "$IDENTITY" =~ ^[0-9A-F]{40}$ ]]; then
        problem "DEVELOPER_ID_SHA1 is not a SHA-1 (40 hexadecimal digits)."
        IDENTITY=""
    elif ! identity_exists "$IDENTITY"; then
        problem "The identity DEVELOPER_ID_SHA1 names is not among the valid identities${APPLE_BUILD_KEYCHAIN:+ in $APPLE_BUILD_KEYCHAIN}."
        IDENTITY=""
    fi
    if [[ -n "${APPLE_BUILD_KEYCHAIN:-}" && ! -f "$APPLE_BUILD_KEYCHAIN" ]]; then
        problem "APPLE_BUILD_KEYCHAIN does not point at a file: $APPLE_BUILD_KEYCHAIN"
    fi
fi

if $NOTARIZE; then
    for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
        if [[ -z "${!name:-}" ]]; then
            problem "$name is not set. Notarization needs the App Store Connect API key (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH), or run with --no-notarize."
        fi
    done
    if [[ -n "${ASC_KEY_PATH:-}" && ! -f "$ASC_KEY_PATH" ]]; then
        problem "ASC_KEY_PATH does not point at a file: $ASC_KEY_PATH"
    fi
    if command -v xcrun >/dev/null 2>&1; then
        for tool in notarytool stapler; do
            if ! xcrun --find "$tool" >/dev/null 2>&1; then
                problem "xcrun cannot find $tool. Select Xcode 13 or later (xcode-select)."
            fi
        done
    fi
fi

if [[ $problems -ne 0 ]]; then
    echo "Preflight failed with $problems problem(s). Nothing was built." >&2
    exit 1
fi

if $SIGN; then
    MODE="signed"
else
    MODE="UNSIGNED dry run"
fi
if $NOTARIZE; then
    MODE="$MODE, notarized"
else
    MODE="$MODE, not notarized"
fi
log "$APP_NAME disk image, build $BUILD ($MODE)"

KEYCHAIN_ARGS=()
if [[ -n "${APPLE_BUILD_KEYCHAIN:-}" ]]; then
    KEYCHAIN_ARGS=(--keychain "$APPLE_BUILD_KEYCHAIN")
fi

# ---------------------------------------------------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------------------------------------------------

log "Generating the Xcode project"
xcodegen generate --quiet

log "Building a universal Release app (arm64 and x86_64)"
# Xcode does not sign anything here: the signing below is done piece by piece, with the explicit identity.
rm -rf "$DERIVED_DATA"
build_status=0
xcodebuild build \
    -project NameAlert.xcodeproj \
    -scheme NameAlert \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" || build_status=$?
unregister_apps "$DERIVED_DATA"
[[ $build_status -eq 0 ]] || exit "$build_status"

APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || die "The build did not produce $APP."

if ! VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"; then
    die "Could not read the version from $APP/Contents/Info.plist."
fi
if ! BUILT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"; then
    die "Could not read the build number from $APP/Contents/Info.plist."
fi
[[ "$VERSION" =~ $number_re ]] || die "The version '$VERSION' must be one to three integers separated by periods."
[[ "$BUILT_BUILD" == "$BUILD" ]] || die "The app is build $BUILT_BUILD, expected $BUILD."
log "Built $APP_NAME $VERSION (build $BUILD)"

# Every Mach-O in the app, the whisper framework included, must have both slices.
check_universal() {
    local app="$1" file archs arch count=0 bad=0
    while IFS= read -r -d '' file; do
        archs="$(lipo -archs "$file" 2>/dev/null)" || continue
        count=$((count + 1))
        for arch in arm64 x86_64; do
            case " $archs " in
                *" $arch "*) ;;
                *)
                    echo "ERROR: ${file#"$app"/} has no $arch slice (it has: $archs)." >&2
                    bad=1
                    ;;
            esac
        done
    done < <(find "$app/Contents" -type f -print0)
    [[ $count -gt 0 ]] || die "Found no Mach-O files in $app."
    [[ $bad -eq 0 ]] || exit 1
    echo "All $count Mach-O files in the app include arm64 and x86_64."
}
check_universal "$APP"

# Only the Mac App Store build sells Pro; this one has everything on.
bash scripts/check_purchase_mode.sh "$APP" --does-not-sell

# ---------------------------------------------------------------------------------------------------------------------
# Sign the app
# ---------------------------------------------------------------------------------------------------------------------

# The app's entitlements are exactly the keys of NameAlert.entitlements.
check_entitlements() {
    local app="$1" file="$WORK_DIR/signed-entitlements.plist" expected actual
    codesign -d --entitlements - --xml "$app" > "$file" 2>/dev/null || die "Could not read the entitlements of $app."
    expected="$(plist_keys "$ENTITLEMENTS" | sort)"
    actual="$(plist_keys "$file" | sort)"
    if [[ "$actual" != "$expected" ]]; then
        echo "ERROR: the app's entitlements are not the ones in $ENTITLEMENTS." >&2
        echo "  expected: $(echo "$expected" | tr '\n' ' ')" >&2
        echo "  actual:   $(echo "$actual" | tr '\n' ' ')" >&2
        exit 1
    fi
    echo "Entitlements: $(echo "$actual" | tr '\n' ' ')"
}

sign_app() {
    local app="$1" item
    # Nested code first, the deepest first (find -depth lists a folder after what is in it), then the app itself.
    # Bundles with no code in them, such as the Swift package's resource bundle, are signed too, so that nothing
    # nested is left unsigned.
    while IFS= read -r -d '' item; do
        echo "  signing ${item#"$app"/}"
        codesign --force --options runtime --timestamp ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} \
            --sign "$IDENTITY" "$item"
    done < <(find "$app/Contents" -depth \
        \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' \) \
        -print0)
    echo "  signing $(basename "$app")"
    codesign --force --options runtime --timestamp ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} \
        --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$app"
}

if $SIGN; then
    log "Signing the app with the hardened runtime"
    sign_app "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    details="$(codesign -d --verbose=4 "$APP" 2>&1)"
    [[ "$details" == *"TeamIdentifier=$TEAM_ID"* ]] || die "The app is not signed by team $TEAM_ID."
    [[ "$details" == *"flags="*"(runtime)"* ]] || die "The app was signed without the hardened runtime."
    [[ "$details" == *"Authority=Developer ID Application:"* ]] || die "The app is not signed with a Developer ID Application identity."
    [[ "$details" == *"Timestamp="* ]] || die "The app was signed without a secure timestamp."
    check_entitlements "$APP"
else
    log "Skipping signing (--unsigned)"
fi

# ---------------------------------------------------------------------------------------------------------------------
# Notarize and staple the app, before it goes into the disk image
# ---------------------------------------------------------------------------------------------------------------------

if $NOTARIZE; then
    # The app is notarized by itself, so that the copy that goes into the image carries its own ticket: it passes
    # Gatekeeper wherever it is dragged to, without looking for the image's. Notarizing only the image leaves the app in
    # it unstapled.
    log "Notarizing the app on its own"
    APP_ZIP="$WORK_DIR/$APP_NAME.zip"
    # ditto, as Apple asks: it keeps the symlinks and the signature of the app as they are.
    ditto -c -k --keepParent "$APP" "$APP_ZIP"
    notarize "$APP_ZIP" "the app"

    log "Stapling the notarization ticket to the app"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl -a -t exec -vv "$APP"
else
    log "Skipping notarization of the app"
fi

# ---------------------------------------------------------------------------------------------------------------------
# Disk image
# ---------------------------------------------------------------------------------------------------------------------

DMG="dist/$APP_NAME-$VERSION.dmg"
log "Creating $DMG"
mkdir -p dist
rm -f "$DMG" "$DMG.sha256"
STAGING="$WORK_DIR/staging"
mkdir -p "$STAGING"
# ditto keeps the symlinks, extended attributes and signature of the app as they are.
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

# hdiutil sometimes fails with "Resource busy" on a freshly written folder, most often on CI runners.
attempt=1
until hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"; do
    if [[ $attempt -ge 3 ]]; then
        die "hdiutil could not create $DMG."
    fi
    echo "hdiutil create failed (attempt $attempt of 3). Trying again in 5 seconds." >&2
    attempt=$((attempt + 1))
    rm -f "$DMG"
    sleep 5
done
hdiutil verify "$DMG"

if $SIGN; then
    log "Signing the disk image"
    codesign --force --timestamp ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --sign "$IDENTITY" "$DMG"
    codesign --verify --verbose=2 "$DMG"
fi

# ---------------------------------------------------------------------------------------------------------------------
# Notarize, staple, and let Gatekeeper assess the result
# ---------------------------------------------------------------------------------------------------------------------

if $NOTARIZE; then
    notarize "$DMG" "the disk image"

    log "Stapling the notarization ticket to the disk image"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"

    log "Asking Gatekeeper to assess the disk image"
    spctl -a -t open --context context:primary-signature -vv "$DMG"
else
    log "Skipping notarization of the disk image"
fi

# Stapling changes the file, so the checksum is taken last. It is the same file release.yml writes.
(
    cd dist
    shasum -a 256 "$APP_NAME-$VERSION.dmg" > "$APP_NAME-$VERSION.dmg.sha256"
)

echo ""
echo "=================================================="
echo "$APP_NAME $VERSION (build $BUILD): $MODE"
echo "Disk image: $DMG"
echo "SHA-256:    $DMG.sha256"
echo "=================================================="
