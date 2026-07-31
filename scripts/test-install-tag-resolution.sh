#!/bin/sh
# Regression tests for the tag resolution in install.sh.
# Run from anywhere: sh scripts/test-install-tag-resolution.sh
# Not wired into any hook. Run it after changing latest_ephor_tag,
# resolve_ephor_tag, TAGS_API, or EPHOR_FALLBACK_TAG in install.sh.
#
# set -u only: the cases assert on nonzero function exits, so set -e would
# abort the runner on the first expected failure.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")
INSTALL_SH="$REPO_ROOT/install.sh"
WORK="$REPO_ROOT/.tmp/test-install-tag-resolution"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# Extract the shipped functions verbatim so the test drives the real code.
sed -n '/^latest_ephor_tag() {/,/^}/p' "$INSTALL_SH" > "$WORK/fns.sh"
sed -n '/^resolve_ephor_tag() {/,/^}/p' "$INSTALL_SH" >> "$WORK/fns.sh"
. "$WORK/fns.sh"
if ! command -v latest_ephor_tag >/dev/null || ! command -v resolve_ephor_tag >/dev/null; then
    echo "FAIL: could not extract the functions from install.sh"
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

echo ""
echo "${TESTS} tests, ${FAILS} failed"
[ "$FAILS" -eq 0 ]
