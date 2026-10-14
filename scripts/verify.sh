#!/usr/bin/env bash
#
# Takeheed's automated verification sweep (spec section 15). It runs every check that needs no person at the Mac,
# prints PASS, FAIL or SKIPPED with a one-line reason for each step, and writes build/verification-report.md.
#
#   scripts/verify.sh                        every step, in the order below
#   scripts/verify.sh --only unit,release    only the steps with these ids
#   scripts/verify.sh --list                 the steps and what each one does
#
# Steps:
#   unit         swift test on NameAlertKit, without the opt-in tests.
#   integration  The opt-in tests (NAMEALERT_INTEGRATION=1): real whisper models, Apple's speech engines, the
#                Keychain, the audio process list. A test that Apple's permissions keep from running is listed as
#                skipped, with the reason; a test skipped because the gate was closed is a failure.
#   performance  WhisperPerformanceTests: ten minutes of speech through the Light and the Balanced model, peak memory
#                and processing time over audio time. It runs alone in its own process, because Swift Testing runs
#                suites side by side and another suite's memory and CPU would be in its numbers.
#   rosetta      The whisper tests as x86_64 under Rosetta. Skipped when Rosetta is not installed (the macos-26-intel
#                leg of ci.yml covers the Intel slice then).
#   release      An unsigned universal (arm64 + x86_64) Release build of the app, and `lipo -archs` on every Mach-O in
#                it, the app and whisper.framework included.
#   dmg          scripts/build_dmg.sh --no-notarize --unsigned, then hdiutil verify on the disk image.
#   screenshots  The Screenshots scheme: every render test, and the five App Store screenshots, which are written to
#                build/verify/ and checked there (2880 x 1800, no alpha), so appstore/screenshots/ is not touched.
#   warnings     Last, once every build of the run is done: no warnings in NameAlert/ or Packages/ in the build logs
#                of this run (the same check as ci.yml, which looks at the Release build log).
#
# Exit status: 0 when no step failed (a skipped step does not count), 1 when one did, 2 for a usage error.
# Every step runs even when an earlier one failed, so one run shows everything that is wrong.
#
# Needs: Xcode 26 or later selected, xcodegen, a logged-in macOS session (the Screenshots tests draw real windows),
# network access the first time (the Balanced model, 60 MB, is downloaded into ~/Library/Caches/NameAlertTests), and
# about 3 GB of free disk space. A run takes about 5 minutes on a Mac that has built the project before, and longer
# on a clean checkout. Everything it makes goes under build/ and dist/, which git ignores: the release and dmg steps
# delete build/DerivedData and build it again, and dmg replaces dist/NameAlert-<version>.dmg. It never stops or
# restarts a running app, and it does not sign or send anything anywhere. The apps it builds are taken out of
# LaunchServices again, so that macOS never opens one of them in place of the app in use.
#
# Written for bash 3.2, the one macOS ships.

# step_<id> is called by name ("step_$id"), and on_interrupt through trap: ShellCheck cannot see either call, so it
# reports those functions, and every function only they call, as never invoked.
# shellcheck disable=SC2329
set -uo pipefail

# A path in the environment is relative to where the script was started, not to the repository it moves into.
if [[ -n "${DERIVED_DATA:-}" && "$DERIVED_DATA" != /* ]]; then
    DERIVED_DATA="$PWD/$DERIVED_DATA"
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
export PATH="/opt/homebrew/bin:$PATH"

BUILD_DIR="build"
LOG_DIR="$BUILD_DIR/verify"
REPORT="$BUILD_DIR/verification-report.md"
RELEASE_DERIVED_DATA="$BUILD_DIR/DerivedData"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

STEP_IDS="unit integration performance rosetta release dmg screenshots warnings"

# --filter takes a regular expression that is matched against test ids like `NameAlertSpeechTests.WhisperEngineTests/
# detectsNameInSpeech()`: the module, the Swift type that holds the tests (not the @Suite display name), the test.
# These are the types that have a test gated by NAMEALERT_INTEGRATION. WhisperPerformanceTests is the performance step.
INTEGRATION_FILTER='\.(WhisperEngineTests|CallDetection[A-Za-z]*Tests|SecretStoreTests|AppleAnalyzerEngineTests|AppleSFSpeechEngineTests|ModelManagerTests|EngineResolverTests)/'
PERFORMANCE_FILTER='\.WhisperPerformanceTests/'
ROSETTA_FILTER='\.WhisperEngineTests/'

# The warnings in our own sources: a path inside a NameAlert or Packages folder. ci.yml anchors the same pattern to its
# checkout (^$GITHUB_WORKSPACE/(NameAlert|Packages)/); here it is not, which makes this check the stricter of the two.
WARNING_PATTERN='^/.*/(NameAlert|Packages)/.*: warning:'

# MARK: - What the steps are

step_title() {
    case "$1" in
        unit) echo "Package unit tests" ;;
        integration) echo "Opt-in integration tests" ;;
        performance) echo "Whisper memory and speed" ;;
        rosetta) echo "Whisper tests under Rosetta (x86_64)" ;;
        release) echo "Universal Release build" ;;
        warnings) echo "Warnings gate" ;;
        dmg) echo "Unsigned disk image" ;;
        screenshots) echo "Screenshots scheme tests" ;;
    esac
}

step_about() {
    case "$1" in
        unit) echo "swift test on NameAlertKit, without the opt-in tests" ;;
        integration) echo "NAMEALERT_INTEGRATION=1: real whisper models, Apple speech, Keychain, audio processes" ;;
        performance) echo "ten minutes of speech through Light and Balanced: peak memory (limit 500 MB), time over audio (limit 0.8)" ;;
        rosetta) echo "the whisper tests as x86_64 under Rosetta (skipped when Rosetta is not installed)" ;;
        release) echo "unsigned arm64 + x86_64 Release build, lipo -archs on every Mach-O in the app" ;;
        warnings) echo "no warnings in NameAlert/ or Packages/ in this run's build logs" ;;
        dmg) echo "scripts/build_dmg.sh --no-notarize --unsigned, then hdiutil verify" ;;
        screenshots) echo "the Screenshots scheme, and the five App Store screenshots checked in a scratch folder" ;;
    esac
}

usage() {
    cat <<'EOF'
Usage: scripts/verify.sh [--only ID[,ID...]] [--list]

  --only IDS   run only these steps (see --list); the default is every step
  --list       list the steps and exit
  -h, --help   show this help

Writes build/verification-report.md. Exits 1 when a step failed, 0 otherwise.
EOF
}

list_steps() {
    local id
    for id in $STEP_IDS; do
        printf '  %-12s %s\n' "$id" "$(step_about "$id")"
    done
}

# MARK: - Arguments

ONLY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --only needs a list of step ids." >&2
                usage >&2
                exit 2
            fi
            ONLY="$2"
            shift 2
            ;;
        --only=*)
            ONLY="${1#--only=}"
            shift
            ;;
        --list)
            list_steps
            exit 0
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -n "$ONLY" ]]; then
    IFS=, read -r -a requested <<<"$ONLY"
    for id in ${requested[@]+"${requested[@]}"}; do
        case " $STEP_IDS " in
            *" $id "*) ;;
            *)
                echo "ERROR: unknown step '$id'. The steps are: $STEP_IDS" >&2
                exit 2
                ;;
        esac
    done
fi

selected() {
    [[ -z "$ONLY" || ",$ONLY," == *",$1,"* ]]
}

# MARK: - Results

# One entry per step that ran, in the order it ran: parallel arrays (bash 3.2 has no associative ones).
R_IDS=()
R_RESULTS=()
R_REASONS=()
R_SECONDS=()

CURRENT_ID=""
RESULT=""
REASON=""
RELEASE_LOG=""
RUN_LOGS=""  # the logs this run wrote, for the warnings gate
STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S %Z')"
SCRIPT_START=$SECONDS

pass() { RESULT="PASS"; REASON="$*"; }
fail() { RESULT="FAIL"; REASON="$*"; }
skip() { RESULT="SKIPPED"; REASON="$*"; }

# Adds a line to what the report says about the current step.
detail() { printf '%s\n' "$*" >> "$LOG_DIR/$CURRENT_ID.details"; }

duration() {
    local total="$1"
    if [[ $total -ge 60 ]]; then
        printf '%d min %02d s' $((total / 60)) $((total % 60))
    else
        printf '%d s' "$total"
    fi
}

# The log, without terminal color codes (the build tools color their errors and warnings even into a file).
plain() {
    sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g' "$@"
}

# Runs a command with its output going to build/verify/<name>.log (and nowhere else). Returns the command's status.
run_logged() {
    local name="$1"
    shift
    local log="$LOG_DIR/$name.log"
    RUN_LOGS="$RUN_LOGS $log"
    printf '$ %s\n\n' "$*" > "$log"
    "$@" >> "$log" 2>&1
}

# xcodebuild registers every app it builds with LaunchServices, and macOS may then open such a copy by its bundle id in
# place of the app in use: after a Screen Recording "Quit & Reopen" it opened the unsigned Release build from here, which
# had neither the permissions nor the settings. This takes every app under the folder $1 out of LaunchServices again;
# the files stay.
unregister_apps() {
    local app
    [[ -d "$1" ]] || return 0
    while IFS= read -r -d '' app; do
        "$LSREGISTER" -u "$app" > /dev/null 2>&1 || true
    done < <(find "$1" -type d -name '*.app' -prune -print0)
}

# One line on why a log's command failed: the first failed test or compiler error in it, else the first error, else its
# last line. Xcode's own complaints about CoreDevice and CoreSimulator, which fill the top of many logs on a Mac whose
# Xcode and OS do not match, say "error" too and are not what failed, so they are not looked for.
why_failed() {
    local log="$1" line="" pattern
    for pattern in 'recorded an issue' '^/.*: error:' '^(xcodebuild: )?error:' '^ld: ' 'Fatal error' '\*\* (TEST|BUILD) FAILED'; do
        line="$(plain "$log" | grep -E -m1 -e "$pattern" || true)"
        [[ -z "$line" ]] || break
    done
    if [[ -z "$line" ]]; then
        line="$(plain "$log" | grep -v '^[[:space:]]*$' | tail -1)"
    fi
    printf '%s' "$line" | cut -c1-220
}

# Reads a `swift test` or `xcodebuild test` log and sets T_RUNS, T_TESTS, T_FAILED, T_KNOWN and T_SKIPPED: the test
# runs it reports, the tests in them, the runs that failed, the known issues and the tests that were skipped.
tally_tests() {
    local counts
    counts="$(plain "$1" | awk '
        /Test run with [0-9]+ tests? in/ {
            runs++
            for (i = 1; i <= NF; i++) if ($i == "with") { tests += $(i + 1); break }
            if ($0 ~ / failed after /) failed++
            if (match($0, /with [0-9]+ known issues?/)) { split(substr($0, RSTART, RLENGTH), known_issue, " "); known += known_issue[2] }
        }
        /^➜ Test .* skipped/ { skipped++ }
        END { printf "%d %d %d %d %d\n", runs, tests, failed, known, skipped }')"
    read -r T_RUNS T_TESTS T_FAILED T_KNOWN T_SKIPPED <<<"$counts"
}

# The tests a log says were skipped, one per line, as "name: reason".
skipped_tests() {
    plain "$1" | grep -E '^➜ Test .* skipped' \
        | sed -E -e 's/^➜ Test (.*) skipped: "(.*)"\.?$/\1: \2/' -e 's/^➜ Test (.*) skipped\.?$/\1: no reason given/' || true
}

# The names of the tests that recorded a known issue, comma separated.
known_issue_names() {
    plain "$1" | sed -n -E 's/^━ Test (.*) recorded a known issue.*$/\1/p' | sort -u | paste -sd, - | sed 's/,/, /g'
}

# Puts what a test log says into the report: the counts, the known issues, and the tests that were skipped.
detail_tests() {
    local log="$1" names skipped
    detail "- Test runs: $T_RUNS, tests: $T_TESTS, failed runs: $T_FAILED, known issues: $T_KNOWN, skipped tests: $T_SKIPPED."
    names="$(known_issue_names "$log")"
    if [[ -n "$names" ]]; then
        detail "- Known issues (expected failures that are written down in the tests): $names."
    fi
    skipped="$(skipped_tests "$log" | sort | sed 's/^/  - /')"
    if [[ -n "$skipped" ]]; then
        detail "- Skipped tests, with the reason the test gives:"
        detail "$skipped"
    fi
}

# MARK: - The steps

step_unit() {
    local log="$LOG_DIR/unit.log" status=0
    # The opt-in tests stay off here even when the caller's environment turns them on.
    run_logged unit env -u NAMEALERT_INTEGRATION swift test --package-path Packages/NameAlertKit || status=$?
    tally_tests "$log"
    detail "- Command: \`swift test --package-path Packages/NameAlertKit\` (log: \`$log\`)"
    detail_tests "$log"
    if [[ $status -ne 0 ]]; then
        fail "swift test exited with $status: $(why_failed "$log")"
    elif [[ $T_TESTS -eq 0 ]]; then
        fail "swift test ran no tests"
    else
        local known=""
        if [[ $T_KNOWN -gt 0 ]]; then
            known=", with $T_KNOWN known issue ($(known_issue_names "$log"))"
        fi
        pass "$T_TESTS tests in $T_RUNS test runs passed$known; $T_SKIPPED skipped (the opt-in ones)"
    fi
}

step_integration() {
    local log="$LOG_DIR/integration.log" status=0
    run_logged integration env NAMEALERT_INTEGRATION=1 \
        swift test --package-path Packages/NameAlertKit --filter "$INTEGRATION_FILTER" || status=$?
    tally_tests "$log"
    detail "- Command: \`NAMEALERT_INTEGRATION=1 swift test --package-path Packages/NameAlertKit --filter '$INTEGRATION_FILTER'\` (log: \`$log\`)"
    detail_tests "$log"

    local closed
    closed="$(skipped_tests "$log" | grep -c 'NAMEALERT_INTEGRATION' || true)"
    if [[ $status -ne 0 ]]; then
        fail "swift test exited with $status: $(why_failed "$log")"
    elif [[ $T_TESTS -eq 0 ]]; then
        fail "the filter matched no tests"
    elif [[ $closed -gt 0 ]]; then
        fail "$closed tests were skipped because the NAMEALERT_INTEGRATION gate was closed"
    else
        local skipped=""
        if [[ $T_SKIPPED -gt 0 ]]; then
            skipped="; $T_SKIPPED skipped ($(skipped_tests "$log" | head -1 | cut -c1-150))"
        fi
        pass "$T_TESTS tests in $T_RUNS test runs passed$skipped"
    fi
}

# "Light 250.2 MB 0.012" for the line the performance test prints for Light, in the log $2. Empty when there is none.
perf_numbers() {
    plain "$2" | sed -n -E "s/^\[whisper-perf\] $1: .* ratio ([0-9.]+) \(limit.*peak memory ([0-9.]+) MB.*\$/\2 MB, ratio \1/p" | head -1
}

step_performance() {
    local log="$LOG_DIR/performance.log" status=0
    run_logged performance env NAMEALERT_INTEGRATION=1 \
        swift test --package-path Packages/NameAlertKit --filter "$PERFORMANCE_FILTER" || status=$?
    tally_tests "$log"
    detail "- Command: \`NAMEALERT_INTEGRATION=1 swift test --package-path Packages/NameAlertKit --filter '$PERFORMANCE_FILTER'\` (log: \`$log\`)"
    detail "- What the test measures: the process's physical footprint (\`phys_footprint\`, read with \`task_info(TASK_VM_INFO)\` every 50 ms from before the model loads), and the time to transcribe about ten minutes of speech divided by the length of that audio. The footprint is the whole test process, with the speech held in memory by the test."
    detail "- Numbers printed by the test:"
    detail ""
    detail '```'
    plain "$log" | grep '^\[whisper-perf\]' | while IFS= read -r line; do detail "$line"; done
    detail '```'

    local light balanced
    light="$(perf_numbers Light "$log")"
    balanced="$(perf_numbers Balanced "$log")"
    if [[ $status -ne 0 ]]; then
        fail "swift test exited with $status: $(why_failed "$log")${light:+; Light $light}${balanced:+; Balanced $balanced}"
    elif [[ -z "$light" || -z "$balanced" ]]; then
        fail "the test passed but printed no numbers for both models (is the gate open, and did the filter match?)"
    elif [[ $T_SKIPPED -gt 0 ]]; then
        fail "the performance test was skipped"
    else
        pass "Light $light; Balanced $balanced (limits: 500 MB, ratio 0.8)"
    fi
}

step_rosetta() {
    if [[ "$(uname -m)" != "arm64" ]]; then
        skip "this Mac is not Apple Silicon, so its ordinary tests already run as x86_64"
        return
    fi
    if ! arch -x86_64 /usr/bin/true > /dev/null 2>&1; then
        skip "Rosetta not installed (owner decision)"
        detail "- Not run here. The Intel slice is covered by the \`macos-26-intel\` leg of \`.github/workflows/ci.yml\`."
        return
    fi
    local log="$LOG_DIR/rosetta.log" status=0
    run_logged rosetta env NAMEALERT_INTEGRATION=1 \
        swift test --package-path Packages/NameAlertKit --arch x86_64 --filter "$ROSETTA_FILTER" || status=$?
    tally_tests "$log"
    detail "- Command: \`NAMEALERT_INTEGRATION=1 swift test --package-path Packages/NameAlertKit --arch x86_64 --filter '$ROSETTA_FILTER'\` (log: \`$log\`)"
    detail_tests "$log"
    if [[ $status -ne 0 ]]; then
        fail "swift test exited with $status: $(why_failed "$log")"
    elif [[ $T_TESTS -eq 0 ]]; then
        fail "the filter matched no tests"
    elif [[ $T_SKIPPED -gt 0 ]]; then
        fail "$T_SKIPPED of the whisper tests were skipped, so none of them ran on the Intel slice"
    else
        pass "$T_TESTS whisper tests passed as x86_64 under Rosetta"
    fi
}

# Runs lipo -archs on every Mach-O file in the app (the same files ci.yml checks), lists them in the report, and
# sets UNIVERSAL_COUNT to how many there are and UNIVERSAL_MISSING to how many lack an arm64 or an x86_64 slice.
check_universal() {
    local app="$1" file archs arch
    UNIVERSAL_COUNT=0
    UNIVERSAL_MISSING=0
    while IFS= read -r -d '' file; do
        archs="$(lipo -archs "$file" 2> /dev/null)" || continue
        UNIVERSAL_COUNT=$((UNIVERSAL_COUNT + 1))
        detail "  - \`${file#"$app"/}\`: $archs"
        for arch in arm64 x86_64; do
            case " $archs " in
                *" $arch "*) ;;
                *)
                    detail "    - MISSING the $arch slice"
                    UNIVERSAL_MISSING=$((UNIVERSAL_MISSING + 1))
                    ;;
            esac
        done
    done < <(find "$app/Contents" -type f \( -perm -u+x -o -name '*.dylib' \) -print0)
}

step_release() {
    RELEASE_LOG=""
    if ! command -v xcodegen > /dev/null 2>&1; then
        fail "xcodegen is not installed (brew install xcodegen)"
        return
    fi
    local status=0
    run_logged release-xcodegen xcodegen generate --quiet || status=$?
    if [[ $status -ne 0 ]]; then
        fail "xcodegen generate exited with $status: $(why_failed "$LOG_DIR/release-xcodegen.log")"
        return
    fi

    # A clean build, so that the warnings gate sees every warning and not only those of the files that changed.
    rm -rf "$RELEASE_DERIVED_DATA"
    local log="$LOG_DIR/release-build.log"
    run_logged release-build xcodebuild build \
        -project NameAlert.xcodeproj \
        -scheme NameAlert \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$RELEASE_DERIVED_DATA" \
        ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" || status=$?
    unregister_apps "$RELEASE_DERIVED_DATA"
    detail "- Command: the same \`xcodebuild build\` as \`ci.yml\` (Release, \`generic/platform=macOS\`, \`ARCHS=\"arm64 x86_64\"\`, signing off), from a clean \`$RELEASE_DERIVED_DATA\` (log: \`$log\`)"
    if [[ $status -ne 0 ]]; then
        fail "xcodebuild exited with $status: $(why_failed "$log")"
        return
    fi
    # Only a build that succeeded gives the warnings gate something to read.
    RELEASE_LOG="$log"

    local app="$RELEASE_DERIVED_DATA/Build/Products/Release/NameAlert.app"
    if [[ ! -d "$app" ]]; then
        fail "the build did not produce $app"
        return
    fi
    local executable="$app/Contents/MacOS/NameAlert"
    local whisper="$app/Contents/Frameworks/whisper.framework/Versions/A/whisper"
    local app_archs whisper_archs
    app_archs="$(lipo -archs "$executable" 2> /dev/null)" || app_archs="unreadable"
    whisper_archs="$(lipo -archs "$whisper" 2> /dev/null)" || whisper_archs="unreadable"
    detail "- \`lipo -archs\` on the app: \`$app_archs\`; on whisper.framework: \`$whisper_archs\`."
    detail "- Every Mach-O file in the app:"
    check_universal "$app"

    case " $app_archs " in *" arm64 "*) ;; *) fail "the app has no arm64 slice (it has: $app_archs)"; return ;; esac
    case " $app_archs " in *" x86_64 "*) ;; *) fail "the app has no x86_64 slice (it has: $app_archs)"; return ;; esac
    case " $whisper_archs " in *" arm64 "*) ;; *) fail "whisper.framework has no arm64 slice (it has: $whisper_archs)"; return ;; esac
    case " $whisper_archs " in *" x86_64 "*) ;; *) fail "whisper.framework has no x86_64 slice (it has: $whisper_archs)"; return ;; esac
    if [[ $UNIVERSAL_MISSING -gt 0 ]]; then
        fail "$UNIVERSAL_MISSING slices are missing from the Mach-O files in the app (listed in the report)"
        return
    fi
    pass "app $app_archs, whisper.framework $whisper_archs; all $UNIVERSAL_COUNT Mach-O files in the app have both slices"
}

step_dmg() {
    local log="$LOG_DIR/dmg.log" status=0
    run_logged dmg scripts/build_dmg.sh --no-notarize --unsigned || status=$?
    detail "- Command: \`scripts/build_dmg.sh --no-notarize --unsigned\` (log: \`$log\`). It builds the universal app again, from a clean \`$RELEASE_DERIVED_DATA\`."
    if [[ $status -ne 0 ]]; then
        fail "build_dmg.sh exited with $status: $(why_failed "$log")"
        return
    fi
    local dmg
    dmg="$(sed -n 's/^Disk image: //p' "$log" | tail -1)"
    if [[ -z "$dmg" || ! -f "$dmg" ]]; then
        fail "build_dmg.sh finished but its disk image is not there (${dmg:-no path reported})"
        return
    fi

    local verify_log="$LOG_DIR/dmg-verify.log" verify_status=0
    run_logged dmg-verify hdiutil verify "$dmg" || verify_status=$?
    detail "- Command: \`hdiutil verify $dmg\` (log: \`$verify_log\`): $(grep -E -i 'VALID|verif' "$verify_log" | tail -1 | cut -c1-160)"
    if [[ $verify_status -ne 0 ]]; then
        fail "hdiutil verify exited with $verify_status: $(why_failed "$verify_log")"
        return
    fi
    if ! grep -q -i 'is VALID' "$verify_log"; then
        fail "hdiutil verify did not say the image is valid"
        return
    fi

    local sum_status=0 sum_file
    sum_file="$(basename "$dmg").sha256"
    (cd "$(dirname "$dmg")" && shasum -a 256 -c "$sum_file" > "$OLDPWD/$LOG_DIR/dmg-sha256.log" 2>&1) || sum_status=$?
    if [[ $sum_status -ne 0 ]]; then
        fail "the checksum file next to the disk image does not match it (see $LOG_DIR/dmg-sha256.log)"
        return
    fi
    local size
    size="$(du -h "$dmg" | awk '{ print $1 }')"
    detail "- Disk image: \`$dmg\` ($size, SHA-256 in \`$(dirname "$dmg")/$sum_file\`, checked with \`shasum -c\`). Unsigned and not notarized: \`codesign\`, \`spctl\` and \`stapler\` are not part of this dry run."
    pass "$dmg ($size) passed hdiutil verify, and its checksum file matches; unsigned, not notarized"
}

step_screenshots() {
    if ! command -v xcodegen > /dev/null 2>&1; then
        fail "xcodegen is not installed (brew install xcodegen)"
        return
    fi
    local status=0
    run_logged screenshots-xcodegen xcodegen generate --quiet || status=$?
    if [[ $status -ne 0 ]]; then
        fail "xcodegen generate exited with $status: $(why_failed "$LOG_DIR/screenshots-xcodegen.log")"
        return
    fi

    # The five App Store screenshots are written only when asked for. Asking here, with the output in a scratch folder
    # of this run, runs the whole pipeline without replacing the screenshots in appstore/screenshots/.
    local out="$PWD/$LOG_DIR/store-screenshots" log="$LOG_DIR/screenshots.log"
    rm -rf "$out"
    mkdir -p "$out"
    local xcb=(
        xcodebuild test
        -project NameAlert.xcodeproj
        -scheme Screenshots
        -destination 'platform=macOS'
        -testLanguage en
        -testRegion US
    )
    if [[ -n "${DERIVED_DATA:-}" ]]; then
        xcb+=(-derivedDataPath "$DERIVED_DATA")
    fi
    run_logged screenshots env \
        TEST_RUNNER_NAMEALERT_RENDER_SCREENSHOTS=1 "TEST_RUNNER_NAMEALERT_SCREENSHOTS_OUT=$out" \
        "${xcb[@]}" || status=$?
    tally_tests "$log"
    detail "- Command: \`xcodebuild test -scheme Screenshots\` with the screenshot variables set, output in \`$LOG_DIR/store-screenshots/\` (log: \`$log\`)"
    detail_tests "$log"
    if [[ $status -ne 0 ]]; then
        local hint=""
        if [[ "$(launchctl managername 2> /dev/null || true)" != "Aqua" ]]; then
            hint=" (this is not a logged-in macOS session, which the offscreen windows need)"
        fi
        fail "xcodebuild exited with $status: $(why_failed "$log")$hint"
        return
    fi
    if ! grep -q '\*\* TEST SUCCEEDED \*\*' "$log"; then
        fail "xcodebuild did not report TEST SUCCEEDED"
        return
    fi
    if [[ $T_TESTS -eq 0 ]]; then
        fail "the Screenshots scheme ran no tests"
        return
    fi

    # The store wants exactly 2880 x 1800 and no alpha channel.
    local files=0 bad=0 file info width height alpha
    detail "- The App Store screenshots this run rendered:"
    for file in "$out"/*.png; do
        [[ -f "$file" ]] || continue
        files=$((files + 1))
        info="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$file")"
        width="$(awk '/pixelWidth/ { print $2 }' <<< "$info")"
        height="$(awk '/pixelHeight/ { print $2 }' <<< "$info")"
        alpha="$(awk '/hasAlpha/ { print $2 }' <<< "$info")"
        detail "  - \`$(basename "$file")\`: ${width}x${height}, alpha: $alpha"
        if [[ "$width" != "2880" || "$height" != "1800" || "$alpha" != "no" ]]; then
            bad=$((bad + 1))
        fi
    done
    if [[ $files -ne 5 ]]; then
        fail "$files App Store screenshots were written, not 5"
    elif [[ $bad -gt 0 ]]; then
        fail "$bad of the 5 App Store screenshots are not 2880x1800 without alpha"
    else
        pass "$T_TESTS tests passed in $T_RUNS test runs; the 5 App Store screenshots render at 2880x1800 without alpha"
    fi
}

step_warnings() {
    if [[ -z "$RELEASE_LOG" || ! -f "$RELEASE_LOG" ]]; then
        skip "no clean Release build in this run (the release step did not run)"
        return
    fi
    # The Release build is a clean one, so its log is the one that counts. The logs of the other steps are scanned too:
    # they only hold the warnings of the files those builds had to compile again, but a warning there is a real one.
    local log hits total=0 first="" count=0
    detail "- The pattern is the one \`ci.yml\` uses: \`$WARNING_PATTERN\`. Logs of this run that were scanned:"
    for log in $RUN_LOGS; do
        count=$((count + 1))
        hits="$(plain "$log" | grep -E -c "$WARNING_PATTERN" || true)"
        detail "  - \`$log\`: $hits warnings in $(plain "$log" | wc -l | tr -d ' ') lines"
        if [[ $hits -gt 0 ]]; then
            total=$((total + hits))
            [[ -n "$first" ]] || first="$(plain "$log" | grep -E -m1 "$WARNING_PATTERN" | cut -c1-200)"
            detail ""
            detail '```'
            plain "$log" | grep -E "$WARNING_PATTERN" | sort -u | head -20 | while IFS= read -r line; do detail "$line"; done
            detail '```'
        fi
    done
    if [[ $total -gt 0 ]]; then
        fail "$total warnings in NameAlert/ or Packages/, the first: $first"
    else
        pass "no warnings in NameAlert/ or Packages/ in the $count logs of this run (the clean Release build is the main one)"
    fi
}

# MARK: - Report

# Sets N_PASS, N_FAIL and N_SKIPPED from the steps that have run.
count_results() {
    local i
    N_PASS=0
    N_FAIL=0
    N_SKIPPED=0
    for ((i = 0; i < ${#R_IDS[@]}; i++)); do
        case "${R_RESULTS[$i]}" in
            PASS) N_PASS=$((N_PASS + 1)) ;;
            FAIL) N_FAIL=$((N_FAIL + 1)) ;;
            SKIPPED) N_SKIPPED=$((N_SKIPPED + 1)) ;;
        esac
    done
}

write_report() {
    local i id verdict="PASS"
    count_results
    [[ $N_FAIL -eq 0 ]] || verdict="FAIL"

    local commit branch dirty machine
    commit="$(git rev-parse --short HEAD 2> /dev/null || echo unknown)"
    branch="$(git rev-parse --abbrev-ref HEAD 2> /dev/null || echo unknown)"
    dirty="$(git status --porcelain 2> /dev/null | wc -l | tr -d ' ')"
    machine="$(sysctl -n machdep.cpu.brand_string 2> /dev/null || uname -m), macOS $(sw_vers -productVersion 2> /dev/null), $(xcodebuild -version 2> /dev/null | head -1) ($(xcodebuild -version 2> /dev/null | sed -n '2p' | sed 's/Build version //')), $(swift --version 2>&1 | sed -n -E 's/.*Swift version ([0-9.]+).*/Swift \1/p' | head -1)"

    mkdir -p "$BUILD_DIR"
    {
        echo "# NameAlert verification report"
        echo
        echo "- Run: $STARTED_AT, $(duration $((SECONDS - SCRIPT_START))) long"
        echo "- Commit: \`$commit\` on \`$branch\`, $dirty uncommitted file(s) in the working tree"
        echo "- Machine: $machine"
        if [[ -n "$ONLY" ]]; then
            echo "- Partial run: only \`$ONLY\`"
        fi
        echo "- Result: **$verdict** ($N_PASS PASS, $N_FAIL FAIL, $N_SKIPPED SKIPPED)"
        echo
        echo "| Step | Result | Reason | Time |"
        echo "|---|---|---|---|"
        for ((i = 0; i < ${#R_IDS[@]}; i++)); do
            id="${R_IDS[$i]}"
            echo "| $(step_title "$id") (\`$id\`) | ${R_RESULTS[$i]} | $(printf '%s' "${R_REASONS[$i]}" | sed 's/|/\\|/g') | $(duration "${R_SECONDS[$i]}") |"
        done
        echo
        echo "## Details"
        for ((i = 0; i < ${#R_IDS[@]}; i++)); do
            id="${R_IDS[$i]}"
            echo
            echo "### $(step_title "$id")"
            echo
            echo "**${R_RESULTS[$i]} — ${R_REASONS[$i]}**"
            if [[ -s "$LOG_DIR/$id.details" ]]; then
                echo
                cat "$LOG_DIR/$id.details"
            fi
        done
        echo
        echo "## Not covered by this script"
        echo
        echo "- The acceptance checks that need the real app and a person (spec section 15, items 1 to 6), CPU use while the app is off, waiting or snoozed, memory with an Apple speech engine (item 7, the 300 MB half: only the two whisper models are measured here), and the App Store \`.pkg\` validation (item 9)."
        echo "- Signing, notarization, \`spctl\` and \`stapler\`: the disk image here is an unsigned dry run."
        echo "- GitHub Actions itself (item 10), including the \`macos-26-intel\` leg."
        echo "- Warnings in the package's test code: the gate reads the clean Release build (the app and the libraries) and whatever else the logs of this run show, and the test targets are not rebuilt clean."
        echo
        echo "Logs: \`$LOG_DIR/\`. This report is not committed (\`build/\` is git-ignored)."
    } > "$REPORT"
}

print_summary() {
    local i
    echo
    echo "=================================================="
    echo "NameAlert verification"
    echo "=================================================="
    for ((i = 0; i < ${#R_IDS[@]}; i++)); do
        printf '%-8s %s: %s\n' "${R_RESULTS[$i]}" "$(step_title "${R_IDS[$i]}")" "${R_REASONS[$i]}"
    done
    echo "=================================================="
}

finish() {
    write_report
    print_summary
    echo "$N_PASS PASS, $N_FAIL FAIL, $N_SKIPPED SKIPPED. Report: $REPORT"
    if [[ $N_FAIL -ne 0 ]]; then
        exit 1
    fi
    exit 0
}

# Ctrl-C ends the step that is running as a failure and still writes the report.
on_interrupt() {
    echo
    echo "Interrupted."
    if [[ -n "$CURRENT_ID" && -z "$RESULT" ]]; then
        R_IDS+=("$CURRENT_ID")
        R_RESULTS+=("FAIL")
        R_REASONS+=("interrupted")
        R_SECONDS+=("$((SECONDS - STEP_START))")
    fi
    write_report
    print_summary
    exit 130
}
trap on_interrupt INT TERM

# MARK: - Run

mkdir -p "$LOG_DIR"

echo "NameAlert verification, $STARTED_AT"
echo "  $(git rev-parse --short HEAD 2> /dev/null) on $(git rev-parse --abbrev-ref HEAD 2> /dev/null), $(xcodebuild -version 2> /dev/null | head -1)"

STEP_START=$SECONDS
for id in $STEP_IDS; do
    selected "$id" || continue
    CURRENT_ID="$id"
    RESULT=""
    REASON=""
    STEP_START=$SECONDS
    rm -f "$LOG_DIR/$id.details"
    : > "$LOG_DIR/$id.details"
    echo
    echo "==> $(step_title "$id")"
    "step_$id"
    if [[ -z "$RESULT" ]]; then
        RESULT="FAIL"
        REASON="the step ended without a result"
    fi
    took=$((SECONDS - STEP_START))
    R_IDS+=("$id")
    R_RESULTS+=("$RESULT")
    R_REASONS+=("$REASON")
    R_SECONDS+=("$took")
    printf '%-8s %s: %s [%s]\n' "$RESULT" "$(step_title "$id")" "$REASON" "$(duration "$took")"
done
CURRENT_ID=""

finish
