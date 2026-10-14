#!/usr/bin/env bash
#
# Builds NameAlert's Mac App Store package, dist/appstore/NameAlert.pkg.
#
#   scripts/build_appstore.sh           archive, sign, check and export the package
#   scripts/build_appstore.sh --check   run the preflight checks only: nothing is built
#
# What it does:
#   1. Checks everything it needs (tools, the profile, the two signing identities) before it builds anything,
#      and reports every problem it finds together.
#   2. Archives a universal (arm64 + x86_64) Release build, signed with the Apple Distribution identity.
#      One entitlements file is used (NameAlert/NameAlert.entitlements): the sandbox, audio input and network
#      client, and nothing else.
#   3. Checks the archived app: exactly those entitlements, the right team, the build number, and a slice for
#      both architectures in every Mach-O file.
#   4. Writes build/ExportOptions.plist (app-store-connect, manual signing) and exports. -exportArchive embeds
#      the provisioning profile, re-signs the app and signs the package with the installer identity.
#
# Environment (names only; values are never printed):
#   MAS_PROFILE_PATH         Required. The Mac App Store provisioning profile for dev.balakumar.namealert (a
#                            .provisionprofile file). It is installed for Xcode if it is not already.
#   BUILD_NUMBER             CFBundleVersion of the app. Default: git rev-list --count HEAD.
#   APPLE_BUILD_KEYCHAIN     Path of the keychain with the signing identities. It must be on the keychain search
#                            list for the export to find them. Default: the keychain search list.
#   MAS_IDENTITY_SHA1        SHA-1 of the "Apple Distribution" (or "3rd Party Mac Developer Application") identity
#                            for team KHD36T7C97. Default: found in the keychain.
#   INSTALLER_IDENTITY_SHA1  SHA-1 of the "3rd Party Mac Developer Installer" (or "Mac Installer Distribution")
#                            identity for the team, which signs the package. Default: found in the keychain.
#   ALLOW_BETA_XCODE         Set to 1 to build with a beta Xcode. Without it the preflight refuses one, because App Store
#                            Connect rejects an upload that was built with a beta. A beta shows in the developer
#                            directory (DEVELOPER_DIR, else what xcode-select names) or in `xcodebuild -version`.
#
# The script never stops or restarts a running app. Everything it builds goes under build/ and dist/appstore/, and the
# app the archive builds is taken out of LaunchServices again, so that macOS never opens that copy in place of the app
# in use.

set -euo pipefail

TEAM_ID="KHD36T7C97"
BUNDLE_ID="dev.balakumar.namealert"
APP_NAME="NameAlert"
ENTITLEMENTS="NameAlert/NameAlert.entitlements"
DERIVED_DATA="build/DerivedData-appstore"
ARCHIVE_PATH="build/$APP_NAME.xcarchive"
EXPORT_OPTIONS="build/ExportOptions.plist"
EXPORT_DIR="dist/appstore"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

usage() {
    cat <<'EOF'
Usage: scripts/build_appstore.sh [--check]

  --check      run the preflight checks only (tools, provisioning profile, signing identities) and stop
  -h, --help   show this help

Needs MAS_PROFILE_PATH; see the top of the script for the environment it reads.
EOF
}

CHECK_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --check)
            CHECK_ONLY=true
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
for name in MAS_PROFILE_PATH APPLE_BUILD_KEYCHAIN; do
    value="${!name:-}"
    if [[ -n "$value" && "$value" != /* ]]; then
        printf -v "$name" '%s' "$PWD/$value"
    fi
done

cd "$(dirname "${BASH_SOURCE[0]}")/.."

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/namealert-appstore.XXXXXX")"
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

# xcodebuild registers every app it builds with LaunchServices (an archive, the copy it builds in the derived data), and
# macOS may then open such a copy by its bundle id in place of the app in use: after a Screen Recording "Quit & Reopen"
# it opened an unsigned build from build/, which had neither the permissions nor the settings. This takes every app
# under the folder $1 out of LaunchServices again; the files stay.
unregister_apps() {
    local app
    [[ -d "$1" ]] || return 0
    while IFS= read -r -d '' app; do
        "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
    done < <(find "$1" -type d -name '*.app' -prune -print0)
}

# Succeeds when the provisioning profile (decoded to the property list $1) lists the certificate with SHA-1 $2.
profile_has_certificate() {
    local index=0 data sha
    while data="$(plutil -extract "DeveloperCertificates.$index" raw -o - "$1" 2>/dev/null)"; do
        sha="$(printf '%s' "$data" | base64 --decode | shasum -a 1 | awk '{ print toupper($1) }')"
        if [[ "$sha" == "$2" ]]; then
            return 0
        fi
        index=$((index + 1))
    done
    return 1
}

# Sets the variable named $1 to an identity's SHA-1: the one in the environment variable named $2, else the first
# valid identity in the keychain whose name matches the awk pattern $3 or, failing that, $4. $5 says what the
# identity is, for messages. The remaining arguments are options for `security find-identity`.
resolve_identity() {
    local var="$1" env_name="$2" pattern="$3" fallback="$4" what="$5" sha
    shift 5
    sha="$(printf '%s' "${!env_name:-}" | tr -d '[:space:]' | tr 'a-f' 'A-F')"
    if [[ -z "$sha" ]]; then
        sha="$(find_identity "$pattern" "$@" || true)"
        if [[ -z "$sha" ]]; then
            sha="$(find_identity "$fallback" "$@" || true)"
        fi
        if [[ -z "$sha" ]]; then
            problem "No $what identity for team $TEAM_ID was found${APPLE_BUILD_KEYCHAIN:+ in $APPLE_BUILD_KEYCHAIN}. Set $env_name, or point APPLE_BUILD_KEYCHAIN at the keychain that has it."
        fi
    elif ! [[ "$sha" =~ ^[0-9A-F]{40}$ ]]; then
        problem "$env_name is not a SHA-1 (40 hexadecimal digits)."
        sha=""
    elif ! identity_exists "$sha"; then
        problem "The identity $env_name names is not among the valid identities${APPLE_BUILD_KEYCHAIN:+ in $APPLE_BUILD_KEYCHAIN}."
        sha=""
    fi
    printf -v "$var" '%s' "$sha"
}

# ---------------------------------------------------------------------------------------------------------------------
# Preflight: find every problem before the build starts, and report them all together.
# ---------------------------------------------------------------------------------------------------------------------

for tool in git xcodebuild xcodegen security plutil lipo codesign pkgutil base64 shasum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        if [[ "$tool" == "xcodegen" ]]; then
            problem "xcodegen is not installed (brew install xcodegen)."
        else
            problem "$tool is not installed or not on PATH."
        fi
    fi
done

# A beta Xcode makes a build that App Store Connect rejects after the upload, an hour into the pipeline. Look for the word
# in the folder Xcode runs from (Xcode_27.2_beta_2.app, Xcode-beta.app) and in what `xcodebuild -version` says.
XCODE_DESCRIPTION=""
if command -v xcodebuild >/dev/null 2>&1; then
    developer_dir="${DEVELOPER_DIR:-}"
    if [[ -z "$developer_dir" ]] && command -v xcode-select >/dev/null 2>&1; then
        developer_dir="$(xcode-select -p 2>/dev/null || true)"
    fi
    xcode_version="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed -e 's/ *$//' || true)"
    XCODE_DESCRIPTION="${xcode_version:-unknown Xcode} from ${developer_dir:-an unknown folder}"
    shopt -s nocasematch
    if [[ "$developer_dir $xcode_version" == *beta* ]]; then
        if [[ "${ALLOW_BETA_XCODE:-}" == "1" ]]; then
            echo "WARNING: building with a beta Xcode ($XCODE_DESCRIPTION) because ALLOW_BETA_XCODE=1. App Store Connect may reject the upload." >&2
        else
            problem "The selected Xcode is a beta ($XCODE_DESCRIPTION), and App Store Connect rejects builds made with one. Select a release Xcode (xcode-select, or DEVELOPER_DIR), or set ALLOW_BETA_XCODE=1 to build anyway."
        fi
    fi
    shopt -u nocasematch
fi

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

if [[ -n "${APPLE_BUILD_KEYCHAIN:-}" ]]; then
    if [[ ! -f "$APPLE_BUILD_KEYCHAIN" ]]; then
        problem "APPLE_BUILD_KEYCHAIN does not point at a file: $APPLE_BUILD_KEYCHAIN"
    elif [[ "$APPLE_BUILD_KEYCHAIN" == *" "* ]]; then
        # It is passed to codesign through OTHER_CODE_SIGN_FLAGS, which is split at spaces.
        problem "APPLE_BUILD_KEYCHAIN must not contain a space: $APPLE_BUILD_KEYCHAIN"
    fi
fi

PROFILE_UUID=""
PROFILE_NAME=""
PROFILE_PLIST="$WORK_DIR/profile.plist"
profile_ok=false
if [[ -z "${MAS_PROFILE_PATH:-}" ]]; then
    problem "MAS_PROFILE_PATH is not set. Set it to the Mac App Store provisioning profile for $BUNDLE_ID (a .provisionprofile file)."
elif [[ ! -f "$MAS_PROFILE_PATH" ]]; then
    problem "MAS_PROFILE_PATH does not point at a file: $MAS_PROFILE_PATH"
elif ! security cms -D -i "$MAS_PROFILE_PATH" > "$PROFILE_PLIST" 2>/dev/null; then
    problem "MAS_PROFILE_PATH is not a provisioning profile: $MAS_PROFILE_PATH"
else
    profile_ok=true
    PROFILE_UUID="$(plutil -extract UUID raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
    PROFILE_NAME="$(plutil -extract Name raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
    profile_app_id="$(plutil -extract 'Entitlements.com\.apple\.application-identifier' raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
    profile_expires="$(plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
    if [[ -z "$PROFILE_UUID" || -z "$profile_app_id" || -z "$profile_expires" ]]; then
        problem "The provisioning profile at MAS_PROFILE_PATH has no UUID, application identifier or expiry date."
        profile_ok=false
    else
        if [[ "$profile_app_id" != "$TEAM_ID.$BUNDLE_ID" ]]; then
            problem "The provisioning profile is for $profile_app_id, not $TEAM_ID.$BUNDLE_ID."
        fi
        if [[ "$profile_expires" < "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]]; then
            problem "The provisioning profile expired on $profile_expires. Make a new one."
        fi
        if plutil -extract ProvisionedDevices raw -o - "$PROFILE_PLIST" >/dev/null 2>&1 \
            || plutil -extract ProvisionsAllDevices raw -o - "$PROFILE_PLIST" >/dev/null 2>&1; then
            problem "The provisioning profile is for named devices or Developer ID, not the Mac App Store. Make a Mac App Store (distribution) profile."
        fi
    fi
fi

MAS_IDENTITY=""
resolve_identity MAS_IDENTITY MAS_IDENTITY_SHA1 \
    '"Apple Distribution: .*[(]'"$TEAM_ID"'[)]"' '"3rd Party Mac Developer Application: .*[(]'"$TEAM_ID"'[)]"' \
    "Apple Distribution" -p codesigning

INSTALLER_IDENTITY=""
resolve_identity INSTALLER_IDENTITY INSTALLER_IDENTITY_SHA1 \
    '"3rd Party Mac Developer Installer: .*[(]'"$TEAM_ID"'[)]"' '"Mac Installer Distribution: .*[(]'"$TEAM_ID"'[)]"' \
    "3rd Party Mac Developer Installer"

# The export fails late and obscurely when the profile does not list the certificate that signs the app.
if $profile_ok && [[ -n "$MAS_IDENTITY" ]] && ! profile_has_certificate "$PROFILE_PLIST" "$MAS_IDENTITY"; then
    problem "The provisioning profile does not include the signing certificate $MAS_IDENTITY. Set MAS_IDENTITY_SHA1 to a certificate the profile lists, or make the profile again with this one."
fi

if [[ $problems -ne 0 ]]; then
    echo "Preflight failed with $problems problem(s). Nothing was built." >&2
    exit 1
fi

log "Preflight passed"
echo "  xcode:               $XCODE_DESCRIPTION"
echo "  profile:             $PROFILE_NAME ($PROFILE_UUID), expires $profile_expires"
echo "  signing identity:    $MAS_IDENTITY"
echo "  installer identity:  $INSTALLER_IDENTITY"
echo "  build number:        $BUILD"
if $CHECK_ONLY; then
    exit 0
fi

# ---------------------------------------------------------------------------------------------------------------------
# Archive
# ---------------------------------------------------------------------------------------------------------------------

log "Generating the Xcode project"
xcodegen generate --quiet

log "Archiving a universal Release build (arm64 and x86_64), build $BUILD"
rm -rf "$ARCHIVE_PATH" "$DERIVED_DATA"
mkdir -p build

# No provisioning profile is named here: on the command line it would apply to every target, and the framework and
# the Swift package's resource bundle reject it. The archive does not need one; -exportArchive embeds the profile.
ARCHIVE_ARGS=(
    archive
    -project NameAlert.xcodeproj
    -scheme NameAlert
    -configuration Release
    -destination 'generic/platform=macOS'
    -derivedDataPath "$DERIVED_DATA"
    -archivePath "$ARCHIVE_PATH"
    ARCHS="arm64 x86_64"
    ONLY_ACTIVE_ARCH=NO
    CURRENT_PROJECT_VERSION="$BUILD"
    DEVELOPMENT_TEAM="$TEAM_ID"
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$MAS_IDENTITY"
)
if [[ -n "${APPLE_BUILD_KEYCHAIN:-}" ]]; then
    # Sign from that keychain only, not from another one that holds a copy of the identity.
    ARCHIVE_ARGS+=("OTHER_CODE_SIGN_FLAGS=--keychain $APPLE_BUILD_KEYCHAIN")
fi
archive_status=0
xcodebuild "${ARCHIVE_ARGS[@]}" || archive_status=$?
unregister_apps "$DERIVED_DATA"
[[ $archive_status -eq 0 ]] || exit "$archive_status"

APP="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
[[ -d "$APP" ]] || die "The archive has no app at $APP."

# ---------------------------------------------------------------------------------------------------------------------
# Check the archived app
# ---------------------------------------------------------------------------------------------------------------------

log "Checking the archived app"

# The app's entitlements are exactly the keys of NameAlert.entitlements. The application and team identifiers are
# the two keys that signing with a provisioning profile adds.
signed_entitlements="$WORK_DIR/signed-entitlements.plist"
codesign -d --entitlements - --xml "$APP" > "$signed_entitlements" 2>/dev/null || die "Could not read the entitlements of $APP."
expected_keys="$(plist_keys "$ENTITLEMENTS" | sort)"
actual_keys="$(plist_keys "$signed_entitlements" \
    | grep -v -e '^com.apple.application-identifier$' -e '^com.apple.developer.team-identifier$' | sort || true)"
if [[ "$actual_keys" != "$expected_keys" ]]; then
    echo "ERROR: the archived app's entitlements are not the ones in $ENTITLEMENTS." >&2
    echo "  expected: $(echo "$expected_keys" | tr '\n' ' ')" >&2
    echo "  actual:   $(echo "$actual_keys" | tr '\n' ' ')" >&2
    exit 1
fi
echo "Entitlements: $(echo "$actual_keys" | tr '\n' ' ')"

details="$(codesign -d --verbose=4 "$APP" 2>&1)"
[[ "$details" == *"TeamIdentifier=$TEAM_ID"* ]] || die "The archived app is not signed by team $TEAM_ID."

if ! VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"; then
    die "Could not read the version from $APP/Contents/Info.plist."
fi
if ! BUILT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"; then
    die "Could not read the build number from $APP/Contents/Info.plist."
fi
[[ "$VERSION" =~ $number_re ]] || die "The version '$VERSION' must be one to three integers separated by periods."
[[ "$BUILT_BUILD" == "$BUILD" ]] || die "The archived app is build $BUILT_BUILD, expected $BUILD."
echo "Version: $VERSION, build $BUILD"

# Every Mach-O in the app, the whisper framework included, must have both slices. A Swift support library that Xcode
# copies in from the toolchain carries both too, so there is no exception to make.
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

# ---------------------------------------------------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------------------------------------------------

log "Installing the provisioning profile for Xcode"
# Xcode 16 and later read the first folder; older tools read the second, which is only filled if it is there.
profile_dirs=("$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles")
if [[ -d "$HOME/Library/MobileDevice/Provisioning Profiles" ]]; then
    profile_dirs+=("$HOME/Library/MobileDevice/Provisioning Profiles")
fi
for dir in "${profile_dirs[@]}"; do
    mkdir -p "$dir"
    cp -f "$MAS_PROFILE_PATH" "$dir/$PROFILE_UUID.provisionprofile"
done

log "Writing $EXPORT_OPTIONS"
# manageAppVersionAndBuildNumber is off so that the package carries exactly the build number stamped above, not the
# next one Xcode thinks App Store Connect expects.
cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>$MAS_IDENTITY</string>
    <key>installerSigningCertificate</key>
    <string>$INSTALLER_IDENTITY</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>$BUNDLE_ID</key>
        <string>$PROFILE_UUID</string>
    </dict>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
EOF
plutil -lint "$EXPORT_OPTIONS"

log "Exporting the Mac App Store package"
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_DIR"

PKG="$EXPORT_DIR/$APP_NAME.pkg"
[[ -f "$PKG" ]] || die "The export finished without making $PKG."
pkgutil --check-signature "$PKG"

echo ""
echo "=================================================="
echo "$APP_NAME $VERSION (build $BUILD)"
echo "Mac App Store package: $PKG"
echo "=================================================="
