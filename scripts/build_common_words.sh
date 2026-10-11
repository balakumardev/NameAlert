#!/usr/bin/env bash
#
# Builds the list of everyday English words that Balanced matching will not accept as a misheard name
# ("Shane" must not fire on "share"). The result is bundled with NameAlertCore.
#
# Source: SCOWL (Spell Checker Oriented Word Lists), release 2020.12.07, https://github.com/en-wl/wordlist
# (tag rel-2020.12.07). The GitHub repository holds only the sources of that release and has no prebuilt
# lists, so the release tarball is fetched from the project's SourceForge download area and checked against a
# pinned SHA-256 before anything is read from it.
#
# Selection: sizes 10, 20 and 35 of the english, american and british word lists (the lists of one size do not
# include the smaller ones, so all three sizes are read). Only entries made entirely of the lowercase ASCII
# letters a-z, at least two letters long, are kept. That drops proper names, possessives, accented words and
# one-letter words. The result is sorted and has no repeats.
#
# Writes, under Packages/NameAlertKit/Sources/NameAlertCore/Resources/:
#   common-words-en.txt   one word per line
#   SCOWL-LICENSE.txt     SCOWL's Copyright file, verbatim
#
# Usage: scripts/build_common_words.sh      (needs curl, tar, grep, sort and shasum or sha256sum)

set -euo pipefail

SCOWL_VERSION="2020.12.07"
SCOWL_URL="https://downloads.sourceforge.net/project/wordlist/SCOWL/${SCOWL_VERSION}/scowl-${SCOWL_VERSION}.tar.gz"
SCOWL_SHA256="5587667caa20c4891390c2d42dbb4d5c4c3f41bee77af1457ece3ba23fb859cc"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="$repo_root/Packages/NameAlertKit/Sources/NameAlertCore/Resources"

work="$(mktemp -d "${TMPDIR:-/tmp}/build-common-words.XXXXXX")"
trap 'rm -rf "$work"' EXIT

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

echo "Downloading SCOWL $SCOWL_VERSION ..."
curl --fail --silent --show-error --location --retry 3 --output "$work/scowl.tar.gz" "$SCOWL_URL"

actual_sha256="$(sha256_of "$work/scowl.tar.gz")"
if [ "$actual_sha256" != "$SCOWL_SHA256" ]; then
    echo "error: the SCOWL tarball does not match the pinned SHA-256" >&2
    echo "  expected $SCOWL_SHA256" >&2
    echo "  actual   $actual_sha256" >&2
    exit 1
fi

# Extract only the files that are used, by name, into a directory of their own.
top="scowl-${SCOWL_VERSION}"
word_lists=()
for list in english american british; do
    for size in 10 20 35; do
        word_lists+=("$top/final/${list}-words.${size}")
    done
done
mkdir "$work/extracted"
tar -xzf "$work/scowl.tar.gz" -C "$work/extracted" "$top/Copyright" "${word_lists[@]}"

inputs=()
for list in "${word_lists[@]}"; do
    inputs+=("$work/extracted/$list")
done

LC_ALL=C cat "${inputs[@]}" | LC_ALL=C grep -E '^[a-z]{2,}$' | LC_ALL=C sort -u > "$work/common-words-en.txt"

# A changed tarball layout would show up here instead of as a quietly wrong list.
count="$(wc -l < "$work/common-words-en.txt" | tr -d ' ')"
if [ "$count" -lt 30000 ]; then
    echo "error: only $count words were selected; has the SCOWL layout changed?" >&2
    exit 1
fi
for word in the share seven; do
    if ! LC_ALL=C grep -qx "$word" "$work/common-words-en.txt"; then
        echo "error: '$word' is missing from the list; has the SCOWL layout changed?" >&2
        exit 1
    fi
done

mkdir -p "$out_dir"
cp "$work/common-words-en.txt" "$out_dir/common-words-en.txt"
cp "$work/extracted/$top/Copyright" "$out_dir/SCOWL-LICENSE.txt"

bytes="$(wc -c < "$out_dir/common-words-en.txt" | tr -d ' ')"
echo "Wrote $count words ($bytes bytes) to ${out_dir#"$repo_root"/}/common-words-en.txt"
echo "Wrote the SCOWL license to ${out_dir#"$repo_root"/}/SCOWL-LICENSE.txt"
