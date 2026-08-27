#!/bin/sh
# Regression tests for the tag resolution in install.sh.
# Run from anywhere: sh scripts/test-install-tag-resolution.sh
# Wired into scripts/gate.sh (EPH-I1194). Run it directly after changing
# latest_ephor_tag, resolve_ephor_tag, max_stable_tag, version_older,
# TAGS_API, or EPHOR_FALLBACK_TAG in install.sh, or max_stable_version in
# scripts/check-version.sh.
# install.ps1 has no companion suite: pwsh is absent on the dev machine,
# so its bounded-read arm (EPH-I0207) stays manual — the recorded
# limitation (EPH-I1194).
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

# EPH-I0661: a fake curl records its arguments so the https clamp branch in
# latest_ephor_tag gets an assertion. The real curl keeps serving the
# file:// fixtures. The fake reads the body from CURL_BODY_FILE and never
# touches the network.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'CURLEOF'
#!/bin/sh
printf '%s\n' "$*" > "$CURL_ARGS_FILE"
cat "$CURL_BODY_FILE"
CURLEOF
chmod +x "$WORK/bin/curl"

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
# EPH-I0661: a tag string in a sibling message field must not leak into
# the resolution. The fixture embeds a plain tag and an escaped "name" key,
# both newer than every real tag, so a JSON-unaware tag grep would pick
# v9.9.9 over the real name v0.14.2.
printf '[{"name":"v0.14.2","message":"see v9.9.9 or \\"name\\":\\"v9.9.9\\" in the docs"}]' \
    > "$WORK/message-injection.json"

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

# Assert that the recorded curl arguments carry the https clamp flags.
# A missing args file is a FAIL: the fake curl must have run.
expect_curl_clamp() {
    TESTS=$((TESTS + 1))
    if [ -s "$2" ] \
        && grep -q -- '--proto =https' "$2" \
        && grep -q -- '--proto-redir =https' "$2" \
        && grep -q -- '--max-filesize 1048576' "$2"; then
        echo "ok   $1"
    else
        echo "FAIL $1: curl args lack the https clamp flags"
        echo "  args: $(cat "$2" 2>/dev/null)"
        FAILS=$((FAILS + 1))
    fi
}

# Assert that the recorded curl arguments carry no --proto flag.
# A missing args file is a FAIL: the fake curl must have run.
expect_curl_no_proto() {
    TESTS=$((TESTS + 1))
    if [ -s "$2" ] && ! grep -q -- '--proto' "$2"; then
        echo "ok   $1"
    else
        echo "FAIL $1: curl args missing, or they carry --proto on a non-https URL"
        echo "  args: $(cat "$2" 2>/dev/null)"
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

# 13. EPH-I0661: a tag in the message text must not leak into the result.
# The message tags are newer than every real tag, so a JSON-unaware tag
# grep would resolve v9.9.9.
ACTUAL_OUT=$(TAGS_API="file://$WORK/message-injection.json"; latest_ephor_tag); ACTUAL_RC=$?
expect "message tag does not leak into resolution" "v0.14.2" "0"
ACTUAL_OUT=$(max_stable_version < "$WORK/message-injection.json"); ACTUAL_RC=$?
expect "check-version message tag does not leak" "0.14.2" "0"

# 14. EPH-I0661: an https TAGS_API gets the proto clamp and the 1 MiB body
# cap (install.sh latest_ephor_tag). The fake curl records the arguments.
# The assignments are statements plus export: a prefix assignment before a
# function call does not export to the function's child processes, so the
# fake curl would never see the file paths.
ACTUAL_OUT=$(
    PATH="$WORK/bin:$PATH"
    CURL_ARGS_FILE="$WORK/curl-args-https"
    CURL_BODY_FILE="$WORK/valid.json"
    TAGS_API="https://codeberg.org/api/v1/repos/RhyosLabs/ephor/tags?limit=50"
    export CURL_ARGS_FILE CURL_BODY_FILE
    latest_ephor_tag
); ACTUAL_RC=$?
expect "https fetch resolves through the clamped curl" "v0.14.2" "0"
expect_curl_clamp "https fetch carries the clamp flags" "$WORK/curl-args-https"

# 15. EPH-I0207: every scheme carries the 1 MiB body cap; only the https
# arm carries the proto clamp (EPH-I0156, install.sh latest_ephor_tag).
# The fake curl records the arguments.
ACTUAL_OUT=$(
    PATH="$WORK/bin:$PATH"
    CURL_ARGS_FILE="$WORK/curl-args-http"
    CURL_BODY_FILE="$WORK/valid.json"
    TAGS_API="http://127.0.0.1:9/x"
    export CURL_ARGS_FILE CURL_BODY_FILE
    latest_ephor_tag
); ACTUAL_RC=$?
expect "http test channel resolves through the capped curl" "v0.14.2" "0"
expect_curl_no_proto "http test channel carries no proto flags" "$WORK/curl-args-http"
if [ -s "$WORK/curl-args-http" ] && grep -q -- '--max-filesize 1048576' "$WORK/curl-args-http"; then
    echo "ok   http test channel carries the byte cap (EPH-I0207)"
    TESTS=$((TESTS + 1))
else
    echo "FAIL http test channel lacks the --max-filesize cap"
    echo "  args: $(cat "$WORK/curl-args-http" 2>/dev/null)"
    TESTS=$((TESTS + 1))
    FAILS=$((FAILS + 1))
fi

# 15b. EPH-I0207: a real curl fetches an over-cap file:// body through
# the capped arm and must fail closed (rc 1), so the resolver takes the
# pinned fallback instead of buffering the oversized response. Pre-fix
# the file:// arm carried no byte cap and the tag resolved.
(printf '[{"name":"v0.14.2",'; head -c 1200000 /dev/zero | tr '\0' 'x'; printf '}]') \
    > "$WORK/over-cap.json"
ACTUAL_OUT=$(TAGS_API="file://$WORK/over-cap.json"; latest_ephor_tag); ACTUAL_RC=$?
expect "over-cap response fails resolution (EPH-I0207)" "" "1"

# 16. EPH-I0662: known-answer pins for the extracted functions the cases
# above never drive directly. A truncated extraction still sources, so a
# presence guard alone cannot catch it.
ACTUAL_OUT=$(printf 'v0.14.2\nv0.14.10\nv0.14.1\n' | max_stable_tag); ACTUAL_RC=$?
expect "max_stable_tag resolves the numeric max" "v0.14.10" "0"
ACTUAL_OUT=$(printf '' | max_stable_tag); ACTUAL_RC=$?
expect "max_stable_tag on empty input prints nothing" "" "0"

# 17. EPH-I0662: version_older known answers. The compare must stay numeric
# (EPH-I0193): a string compare sorts 0.14.10 below 0.14.2, so the
# v0.14.2/v0.14.10 pair discriminates (string: rc 1, numeric: rc 0). The
# v0.14.1/v0.14.10 pair does not: a prefix sorts before its extension, so
# both collations order 0.14.1 first (EPH-I1129).
ACTUAL_OUT=$(version_older v0.14.1 v0.14.10); ACTUAL_RC=$?
expect "version_older accepts a lower first" "" "0"
ACTUAL_OUT=$(version_older v0.14.2 v0.14.10); ACTUAL_RC=$?
expect "version_older compares numerically" "" "0"
ACTUAL_OUT=$(version_older v0.14.10 v0.14.1); ACTUAL_RC=$?
expect "version_older rejects a higher first" "" "1"
ACTUAL_OUT=$(version_older v0.14.2 v0.14.2); ACTUAL_RC=$?
expect "version_older rejects equal versions" "" "1"

echo ""
echo "${TESTS} tests, ${FAILS} failed"
[ "$FAILS" -eq 0 ]
