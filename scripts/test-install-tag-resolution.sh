#!/bin/sh
# Regression tests for the tag resolution in install.sh.
# Run from anywhere: sh scripts/test-install-tag-resolution.sh
# Not wired into any hook. Run it after changing latest_ephor_tag,
# resolve_ephor_tag, max_stable_tag, version_older, TAGS_API, or
# EPHOR_FALLBACK_TAG in install.sh, or max_stable_version in
# scripts/check-version.sh.
#
# set -u only: the cases assert on nonzero function exits, so set -e would
# abort the runner on the first expected failure.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")
INSTALL_SH="$REPO_ROOT/install.sh"
CHECK_VERSION_SH="$REPO_ROOT/scripts/check-version.sh"
WORK="$REPO_ROOT/.tmp/test-install-tag-resolution"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# Extract the shipped functions verbatim so the test drives the real code.
sed -n '/^max_stable_tag() {/,/^}/p' "$INSTALL_SH" > "$WORK/fns.sh"
sed -n '/^version_older() {/,/^}/p' "$INSTALL_SH" >> "$WORK/fns.sh"
sed -n '/^latest_ephor_tag() {/,/^}/p' "$INSTALL_SH" >> "$WORK/fns.sh"
sed -n '/^resolve_ephor_tag() {/,/^}/p' "$INSTALL_SH" >> "$WORK/fns.sh"
sed -n '/^max_stable_version() {/,/^}/p' "$CHECK_VERSION_SH" >> "$WORK/fns.sh"
. "$WORK/fns.sh"
for fn in max_stable_tag version_older latest_ephor_tag resolve_ephor_tag; do
    if ! command -v "$fn" >/dev/null; then
        echo "FAIL: could not extract $fn from install.sh"
        exit 1
    fi
done
if ! command -v max_stable_version >/dev/null; then
    echo "FAIL: could not extract max_stable_version from check-version.sh"
    exit 1
fi

# Drive the fallback from the shipped value so the test stays in sync.
EPHOR_FALLBACK_TAG=$(grep '^EPHOR_FALLBACK_TAG=' "$INSTALL_SH" | head -1 | cut -d'"' -f2)
if [ -z "$EPHOR_FALLBACK_TAG" ]; then
    echo "FAIL: could not read EPHOR_FALLBACK_TAG from install.sh"
    exit 1
fi

printf '[{"name":"v0.14.2","message":"x"}]' > "$WORK/valid.json"
printf '[{\n  "name": "v0.14.2",\n  "message": "x"\n}]' > "$WORK/pretty.json"
printf '[{"name":"v0.15.0-beta.1","message":"x"},{"name":"v0.14.2","message":"x"}]' \
    > "$WORK/prerelease-first.json"
printf '[{"name":"not-a-version"}]' > "$WORK/invalid.json"
: > "$WORK/empty.json"
# The first tag by date is not the max. v0.14.10 also beats v0.14.2 only
# under a numeric compare, so this fixture catches a string sort too.
printf '[{"name":"v0.14.2","message":"x"},{"name":"v0.14.10","message":"x"}]' \
    > "$WORK/max-not-first.json"
# v0.14.1 is older than every fallback this repo has pinned (v0.14.2+).
printf '[{"name":"v0.14.1","message":"x"}]' > "$WORK/older-than-fallback.json"
printf '[{"name":"%s","message":"x"}]' "$EPHOR_FALLBACK_TAG" > "$WORK/equal-fallback.json"

TESTS=0
FAILS=0

# Assert on the globals ACTUAL_OUT and ACTUAL_RC set by the case.
expect() {
    TESTS=$((TESTS + 1))
    if [ "$ACTUAL_OUT" = "$2" ] && [ "$ACTUAL_RC" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        echo "  expected: stdout=[$2] rc=$3"
        echo "  actual:   stdout=[$ACTUAL_OUT] rc=$ACTUAL_RC"
        FAILS=$((FAILS + 1))
    fi
}

# Assert that the stderr file holds a warning that names the fallback tag.
expect_warning() {
    TESTS=$((TESTS + 1))
    if grep -q "warning:" "$2" && grep -q "$EPHOR_FALLBACK_TAG" "$2"; then
        echo "ok   $1"
    else
        echo "FAIL $1: stderr lacks a warning naming the fallback tag"
        FAILS=$((FAILS + 1))
    fi
}

# Assert that the stderr file is empty.
expect_no_warning() {
    TESTS=$((TESTS + 1))
    if [ ! -s "$2" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1: unexpected stderr output"
        FAILS=$((FAILS + 1))
    fi
}

# 1. Valid compact payload resolves the tag.
ACTUAL_OUT=$(TAGS_API="file://$WORK/valid.json"; latest_ephor_tag); ACTUAL_RC=$?
expect "valid payload resolves tag" "v0.14.2" "0"

# 2. Pretty-printed payload resolves the tag.
ACTUAL_OUT=$(TAGS_API="file://$WORK/pretty.json"; latest_ephor_tag); ACTUAL_RC=$?
expect "pretty payload resolves tag" "v0.14.2" "0"

# 3. A prerelease newest tag yields the newest stable tag.
ACTUAL_OUT=$(TAGS_API="file://$WORK/prerelease-first.json"; latest_ephor_tag); ACTUAL_RC=$?
expect "prerelease-first payload resolves newest stable" "v0.14.2" "0"

# 4. An all-invalid payload fails resolution.
ACTUAL_OUT=$(TAGS_API="file://$WORK/invalid.json"; latest_ephor_tag); ACTUAL_RC=$?
expect "invalid payload fails resolution" "" "1"

# 5. An empty payload fails resolution.
ACTUAL_OUT=$(TAGS_API="file://$WORK/empty.json"; latest_ephor_tag); ACTUAL_RC=$?
expect "empty payload fails resolution" "" "1"

# 6. An invalid payload makes the resolver warn and use the fallback.
ACTUAL_OUT=$(TAGS_API="file://$WORK/invalid.json"; resolve_ephor_tag 2>"$WORK/stderr")
ACTUAL_RC=$?
expect "invalid payload resolves fallback" "$EPHOR_FALLBACK_TAG" "0"
expect_warning "invalid payload warns with fallback name" "$WORK/stderr"

# 7. An empty payload makes the resolver warn and use the fallback.
ACTUAL_OUT=$(TAGS_API="file://$WORK/empty.json"; resolve_ephor_tag 2>"$WORK/stderr")
ACTUAL_RC=$?
expect "empty payload resolves fallback" "$EPHOR_FALLBACK_TAG" "0"
expect_warning "empty payload warns with fallback name" "$WORK/stderr"

# 8. An unreachable API makes the resolver warn and use the fallback.
ACTUAL_OUT=$(TAGS_API="http://127.0.0.1:9/x"; resolve_ephor_tag 2>"$WORK/stderr")
ACTUAL_RC=$?
expect "unreachable API resolves fallback" "$EPHOR_FALLBACK_TAG" "0"
expect_warning "unreachable API warns with fallback name" "$WORK/stderr"

# 9. EPH-I0193: the first tag by date is not the max. Resolve the
# semver-highest tag, not the first entry.
ACTUAL_OUT=$(TAGS_API="file://$WORK/max-not-first.json"; latest_ephor_tag); ACTUAL_RC=$?
expect "first-not-max payload resolves the max" "v0.14.10" "0"

# 10. EPH-I0193: a max below the fallback is a downgrade. The resolver warns
# and keeps the fallback.
ACTUAL_OUT=$(TAGS_API="file://$WORK/older-than-fallback.json"; resolve_ephor_tag 2>"$WORK/stderr")
ACTUAL_RC=$?
expect "below-fallback payload resolves fallback" "$EPHOR_FALLBACK_TAG" "0"
expect_warning "below-fallback payload warns with fallback name" "$WORK/stderr"

# 11. EPH-I0193: a max equal to the fallback is no downgrade. The resolver
# returns the tag and stays quiet.
ACTUAL_OUT=$(TAGS_API="file://$WORK/equal-fallback.json"; resolve_ephor_tag 2>"$WORK/stderr")
ACTUAL_RC=$?
expect "equal-fallback payload resolves tag" "$EPHOR_FALLBACK_TAG" "0"
expect_no_warning "equal-fallback payload stays quiet" "$WORK/stderr"

# 12. check-version.sh max_stable_version prints the bare semver max without
# the leading v (check-version compares bare versions). Its pipeline ends in
# tail, so the exit code is 0 even when nothing matches.
ACTUAL_OUT=$(max_stable_version < "$WORK/max-not-first.json"); ACTUAL_RC=$?
expect "check-version max-not-first resolves bare max" "0.14.10" "0"
ACTUAL_OUT=$(max_stable_version < "$WORK/prerelease-first.json"); ACTUAL_RC=$?
expect "check-version prerelease-first resolves bare stable" "0.14.2" "0"
ACTUAL_OUT=$(max_stable_version < "$WORK/invalid.json"); ACTUAL_RC=$?
expect "check-version invalid payload prints nothing" "" "0"
ACTUAL_OUT=$(max_stable_version < "$WORK/empty.json"); ACTUAL_RC=$?
expect "check-version empty payload prints nothing" "" "0"

echo ""
echo "${TESTS} tests, ${FAILS} failed"
[ "$FAILS" -eq 0 ]
