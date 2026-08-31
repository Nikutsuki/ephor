#!/usr/bin/env bash
# ephor Layer-1 gate (EPH-I1074; serves REL-GATE-2 and REL-AB-5).
#
# Steps: fmt, installer tag resolution, install-sh suite, install-ps1
# anchor pin, install-ps1 hardening suite, ReleaseSafe build, test
# ratchet, per-test capture + discovery cross-check, dogfood ratchet
# (fail_on: warning posture), coverage gate, corpus A/B
# (zls/ghostty/sig/tigerbeetle).
#
# Shape rules (core-rules gate lessons):
# - Every step writes its command output to a named file under .tmp/gate/.
# - Every decision reads a saved exit code or a saved output file. No pipe
#   masks a command's exit code.
# - One gate run at a time: a pid-checked lock under .tmp/gate/lock.
# - The script sources .zenv/activate itself (fresh-shell isolation).
#
# Ratchets (scripts/gate-baselines.txt):
# - dogfood: the maximum allowed warning TOTAL. Monotone-decreasing. Update
#   the baseline in the commit that fixes warnings, never otherwise.
# - tests: the minimum test count. Update the baseline in the commit that
#   adds tests.
#
# Corpus A/B: pre-vs-post with frozen baselines. The first run seeds the
# baseline outputs (.tmp/gate/ab/baseline-*) and every later run diffs the
# freshly built binary's outputs against those frozen baselines. The
# baselines never move by themselves: a differing corpus output fails the
# gate, and the commit author either fixes the regression or explains the
# delta and re-seeds by deleting the baseline files (the practical form of
# the B-series pre-vs-post A/B).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if [ ! -f "$REPO_ROOT/.zenv/activate" ]; then
    printf '[FAIL] gate: .zenv/activate missing (run zenv init && zenv use)\n'
    exit 1
fi
# Fresh-shell isolation: pin the zenv toolchain for every command here.
source "$REPO_ROOT/.zenv/activate"

BASELINES="scripts/gate-baselines.txt"
if [ ! -f "$BASELINES" ]; then
    printf '[FAIL] gate: %s missing\n' "$BASELINES"
    exit 1
fi

GATE_DIR=".tmp/gate"
mkdir -p "$GATE_DIR"
LOG="$GATE_DIR/gate.log"
: > "$LOG"

# One gate run at a time (the build mutex).
LOCK_DIR="$GATE_DIR/lock"
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ -f "$LOCK_DIR/pid" ] && ! kill -0 "$(cat "$LOCK_DIR/pid")" 2>/dev/null; then
        rm -rf "$LOCK_DIR"
        continue
    fi
    printf '[FAIL] gate: another gate run holds the lock (%s/pid). If no gate is running, remove %s.\n' "$LOCK_DIR" "$LOCK_DIR"
    exit 1
done
trap 'rm -rf "$LOCK_DIR"' EXIT
printf '%s\n' "$$" > "$LOCK_DIR/pid"

CORPUS_ROOT="${CORPUS_ROOT:-$HOME/Desktop/dev/rhyoslabs/random-zig-projects}"
CORPORA="zls ghostty sig tigerbeetle"

FAILURES=0

ok() {
    printf '[OK]   %s\n' "$1"
    printf '[OK]   %s\n' "$1" >> "$LOG"
}

fail() {
    printf '[FAIL] %s\n' "$1"
    printf '[FAIL] %s\n' "$1" >> "$LOG"
    FAILURES=$((FAILURES + 1))
}

note() {
    printf '[NOTE] %s\n' "$1"
    printf '[NOTE] %s\n' "$1" >> "$LOG"
}

HEAD_SHORT="$(git rev-parse --short HEAD)"
printf 'gate: HEAD %s\n' "$HEAD_SHORT"
printf 'gate: HEAD %s\n' "$HEAD_SHORT" >> "$LOG"

# --- 1. fmt ---------------------------------------------------------------
if zig fmt --check build.zig src/ > "$GATE_DIR/fmt.log" 2>&1; then
    ok "fmt (zig fmt --check build.zig src/)"
else
    fail "fmt (see $GATE_DIR/fmt.log)"
fi

# --- 1b. installer tag resolution (EPH-I1194; REL-ZERO-1, REL-RELEASE-6) ----
# The installer surface changes often (tag clamp, 1 MiB body cap, fallback
# pairing), and the harness drives the real shipped functions with a fake
# curl and file:// fixtures in seconds. A regression must not land
# gate-green. The install.ps1 bounded-read HTTP arm (EPH-I0207) gained ps1
# coverage in B136a (EPH-I1231): the 1e anchor leg's pubkey-channel runs
# drive Get-BoundedFile through a local HTTP listener twice (a clean
# download and an over-cap fail-closed one). The non-http (file://) arm
# stays manual — the recorded limitation.
ITR_EXIT=0
sh "$SCRIPT_DIR/test-install-tag-resolution.sh" > "$GATE_DIR/install-tag.log" 2>&1 || ITR_EXIT=$?
# The tally line is the harness's own verdict ("N tests, M failed"). Its
# absence means the harness aborted before the verdict (a set -u trip or a
# missing install.sh function), which is a leg failure, not a pass.
ITR_RUN="$(sed -nE 's/^([0-9]+) tests, ([0-9]+) failed$/\1/p' "$GATE_DIR/install-tag.log" | tail -1 || true)"
ITR_FAILED="$(sed -nE 's/^([0-9]+) tests, ([0-9]+) failed$/\2/p' "$GATE_DIR/install-tag.log" | tail -1 || true)"
case "$ITR_RUN" in
    '' | *[!0-9]*)
        fail "installer tag resolution (no tally line; see $GATE_DIR/install-tag.log)"
        ;;
    *)
        if [ "$ITR_EXIT" -ne 0 ] || [ "$ITR_FAILED" != "0" ]; then
            fail "installer tag resolution ($ITR_RUN tests, $ITR_FAILED failed, exit $ITR_EXIT; see $GATE_DIR/install-tag.log)"
        else
            ok "installer tag resolution ($ITR_RUN tests, 0 failed)"
        fi
        ;;
esac

# --- 1c. installer e2e (EPH-I0287; REL-RELEASE-6) --------------------------
# The full fail-closed path: the suite drives the real install.sh through
# the six signature-verification states with local HTTP redirect servers
# and a fresh test keypair, and pins the file:// byte cap. Slower than
# the 1b harness (it runs real installs), so it runs once per gate. The
# ps1 e2e-state gap is the same as 1b's: the 1e anchor leg runs one
# scenario.
IEE_EXIT=0
sh "$SCRIPT_DIR/test-install-e2e.sh" > "$GATE_DIR/install-e2e.log" 2>&1 || IEE_EXIT=$?
# The tally line is the harness's own verdict ("wp65 e2e: N checks, M
# failed"). Its absence means the harness aborted before the verdict (a
# missing tool or a dead redirect server), which is a leg failure.
IEE_RUN="$(sed -nE 's/^wp65 e2e: ([0-9]+) checks, ([0-9]+) failed$/\1/p' "$GATE_DIR/install-e2e.log" | tail -1 || true)"
IEE_FAILED="$(sed -nE 's/^wp65 e2e: ([0-9]+) checks, ([0-9]+) failed$/\2/p' "$GATE_DIR/install-e2e.log" | tail -1 || true)"
case "$IEE_RUN" in
    '' | *[!0-9]*)
        fail "installer e2e (no tally line; see $GATE_DIR/install-e2e.log)"
        ;;
    *)
        if [ "$IEE_EXIT" -ne 0 ] || [ "$IEE_FAILED" != "0" ]; then
            fail "installer e2e ($IEE_RUN checks, $IEE_FAILED failed, exit $IEE_EXIT; see $GATE_DIR/install-e2e.log)"
        else
            ok "installer e2e ($IEE_RUN checks, 0 failed)"
        fi
        ;;
esac

# --- 1d. install-sh regression suite (EPH-I1220; REL-ZERO-1, REL-RELEASE-6) -
# The suite drives the real installer through the splice/refusal scenarios
# with a fake zig and file:// fixtures, shell-only, in seconds (16s
# measured at wiring, 2026-08-28). EPH-I1220: the WP-6.5
# inactive-verification trio means every successful run warns on stderr, so
# the strict-stderr tests expect exactly that trio. A changed installer
# stderr surface fails this leg without a suite edit — the drift this leg
# exists to catch. The 1e anchor leg pins one scenario on the ps1 side;
# the full splice/refusal suite has no ps1 companion.
ISS_EXIT=0
sh "$REPO_ROOT/tests/install-sh-tests.sh" > "$GATE_DIR/install-suite.log" 2>&1 || ISS_EXIT=$?
# The tally line is the suite's own verdict ("install-sh tests: N
# passed"). Its absence means the suite aborted before the verdict (a
# fail() trip or a fixture break), which is a leg failure, not a pass.
ISS_PASSED="$(sed -nE 's/^install-sh tests: ([0-9]+) passed$/\1/p' "$GATE_DIR/install-suite.log" | tail -1 || true)"
case "$ISS_PASSED" in
    '' | *[!0-9]*)
        fail "install-sh suite (no tally line; see $GATE_DIR/install-suite.log)"
        ;;
    *)
        if [ "$ISS_EXIT" -ne 0 ]; then
            fail "install-sh suite (aborted, exit $ISS_EXIT; see $GATE_DIR/install-suite.log)"
        else
            ok "install-sh suite ($ISS_PASSED tests passed)"
        fi
        ;;
esac

# --- 1e. install-ps1 anchor pin (EPH-I1219; REL-ZERO-1, REL-RELEASE-6) -----
# The B136 t48-mirror pin: the ps1 anchor walk must skip the comment,
# string, and case-variant mention shapes and land the block right after
# the real call. Runs only when pwsh is on PATH; machines without pwsh
# skip the leg without a failure (the installer surface stays sh-gated
# there).
if command -v pwsh > /dev/null 2>&1; then
    IPA_EXIT=0
    pwsh -NoProfile -NonInteractive -File "$SCRIPT_DIR/test-install-ps1-anchor.ps1" > "$GATE_DIR/install-ps1-anchor.log" 2>&1 || IPA_EXIT=$?
    # The tally line is the suite's own verdict ("ps1 anchor: N checks, M
    # failed"). Its absence means the suite aborted before the verdict (a
    # fixture break or a missing install.ps1 function), which is a leg
    # failure, not a pass.
    IPA_RUN="$(sed -nE 's/^ps1 anchor: ([0-9]+) checks, ([0-9]+) failed$/\1/p' "$GATE_DIR/install-ps1-anchor.log" | tail -1 || true)"
    IPA_FAILED="$(sed -nE 's/^ps1 anchor: ([0-9]+) checks, ([0-9]+) failed$/\2/p' "$GATE_DIR/install-ps1-anchor.log" | tail -1 || true)"
    case "$IPA_RUN" in
        '' | *[!0-9]*)
            fail "install-ps1 anchor pin (no tally line; see $GATE_DIR/install-ps1-anchor.log)"
            ;;
        *)
            if [ "$IPA_EXIT" -ne 0 ] || [ "$IPA_FAILED" != "0" ]; then
                fail "install-ps1 anchor pin ($IPA_RUN checks, $IPA_FAILED failed, exit $IPA_EXIT; see $GATE_DIR/install-ps1-anchor.log)"
            else
                ok "install-ps1 anchor pin ($IPA_RUN checks, 0 failed)"
            fi
            ;;
    esac
else
    note "install-ps1 anchor pin (skipped: pwsh not on PATH)"
fi

# --- 1f. install-ps1 hardening suite (EPH-I1285; REL-REDTEAM-4) -------------
# The RED3 re-derivation pins: the suite drives the real install.ps1
# through the I1272 fingerprint-repair shapes, the I1273 byte caps, and
# the I1274 terminal sanitization with the same hermetic harness as the
# 1e anchor leg (a fake zig, a local HTTP tags listener, the
# EPHOR_TEST_MODE archive override). A regression in any of the three
# fixes fails this leg instead of shipping silently. Runs only when pwsh
# is on PATH; machines without pwsh skip the leg without a failure.
if command -v pwsh > /dev/null 2>&1; then
    IPH_EXIT=0
    pwsh -NoProfile -NonInteractive -File "$SCRIPT_DIR/test-install-ps1-hardening.ps1" > "$GATE_DIR/install-ps1-hardening.log" 2>&1 || IPH_EXIT=$?
    # The tally line is the suite's own verdict ("ps1 hardening: N checks,
    # M failed"). Its absence means the suite aborted before the verdict
    # (a fixture break or a missing install.ps1 function), which is a leg
    # failure, not a pass.
    IPH_RUN="$(sed -nE 's/^ps1 hardening: ([0-9]+) checks, ([0-9]+) failed$/\1/p' "$GATE_DIR/install-ps1-hardening.log" | tail -1 || true)"
    IPH_FAILED="$(sed -nE 's/^ps1 hardening: ([0-9]+) checks, ([0-9]+) failed$/\2/p' "$GATE_DIR/install-ps1-hardening.log" | tail -1 || true)"
    case "$IPH_RUN" in
        '' | *[!0-9]*)
            fail "install-ps1 hardening suite (no tally line; see $GATE_DIR/install-ps1-hardening.log)"
            ;;
        *)
            if [ "$IPH_EXIT" -ne 0 ] || [ "$IPH_FAILED" != "0" ]; then
                fail "install-ps1 hardening suite ($IPH_RUN checks, $IPH_FAILED failed, exit $IPH_EXIT; see $GATE_DIR/install-ps1-hardening.log)"
            else
                ok "install-ps1 hardening suite ($IPH_RUN checks, 0 failed)"
            fi
            ;;
    esac
else
    note "install-ps1 hardening suite (skipped: pwsh not on PATH)"
fi

# --- 2. build (ReleaseSafe) ------------------------------------------------
# Fail-fast: every later leg runs the freshly built binary. A failed build
# must not let the dogfood or corpus legs scan a stale binary.
if ! zig build -Doptimize=ReleaseSafe > "$GATE_DIR/build.log" 2>&1; then
    fail "build (ReleaseSafe) (see $GATE_DIR/build.log)"
    printf '\ngate: build failed, stopping (log: %s)\n' "$GATE_DIR/build.log"
    exit 1
fi
ok "build (ReleaseSafe)"

# --- 3. test ratchet -------------------------------------------------------
# The Build Summary line is the authoritative count. The "failed command:"
# line zig prints beside a green run (stale result_failed_command) is not a
# signal; only the Build Summary counts.
if zig build test -Doptimize=Debug --summary all > "$GATE_DIR/test.log" 2>&1; then
    ok "test (run completed)"
else
    fail "test (run failed; see $GATE_DIR/test.log)"
fi
TESTS_LINE="$(grep -E 'Build Summary: ' "$GATE_DIR/test.log" | tail -1 || true)"
TESTS_PASSED="$(printf '%s\n' "$TESTS_LINE" | sed -nE 's/.*; ([0-9]+)\/([0-9]+) tests passed.*/\1/p')"
TESTS_TOTAL="$(printf '%s\n' "$TESTS_LINE" | sed -nE 's/.*; ([0-9]+)\/([0-9]+) tests passed.*/\2/p')"
STEPS_OK="$(printf '%s\n' "$TESTS_LINE" | sed -nE 's/^Build Summary: ([0-9]+)\/([0-9]+) steps succeeded.*/\1/p')"
STEPS_TOTAL="$(printf '%s\n' "$TESTS_LINE" | sed -nE 's/^Build Summary: ([0-9]+)\/([0-9]+) steps succeeded.*/\2/p')"
TESTS_BASE="$(awk '$1 == "tests" {print $2}' "$BASELINES")"
# The baseline must be exactly one decimal token before any arithmetic
# comparison: the glob rejects empty, non-numeric (the "tests abc" typo
# class), and multi-line values from duplicated keys in one test. The
# ??????????* arm rejects digit runs of 10+ characters ahead of the
# arithmetic path (EPH-I1128): an intmax-overflow run would pass the
# token glob and make the -lt comparison fail with bash "integer
# expression expected" (exit 2), which evaluates false in the elif chain
# and falls through to the ok branch.
case "$TESTS_BASE" in
    '' | *[!0-9]* | ??????????*)
        fail "test ratchet (baseline missing or malformed in $BASELINES)"
        ;;
    *)
        if [ -z "$TESTS_PASSED" ] || [ -z "$STEPS_OK" ]; then
            fail "test ratchet (cannot parse the Build Summary line)"
        elif [ "$STEPS_OK" != "$STEPS_TOTAL" ]; then
            fail "test ratchet ($STEPS_OK/$STEPS_TOTAL steps succeeded)"
        elif [ "$TESTS_PASSED" != "$TESTS_TOTAL" ]; then
            fail "test ratchet ($TESTS_PASSED/$TESTS_TOTAL tests passed)"
        elif [ "$TESTS_PASSED" -lt "$TESTS_BASE" ]; then
            fail "test ratchet ($TESTS_PASSED below baseline $TESTS_BASE)"
        else
            ok "test ratchet ($TESTS_PASSED/$TESTS_TOTAL passed, baseline $TESTS_BASE)"
        fi
        ;;
esac

# --- 3b. per-test capture (EPH-I1088) ---------------------------------------
# The build runner hides the test binary's per-test lines at every summary
# level on a green run (child stderr is captured, not forwarded), so the
# test binary runs directly: each `i/N name...OK` line is the runner's own
# per-test evidence and the final "All N tests passed." line carries the
# total. The same root module and cache namespace as the build test step
# (--name test) keep the compile cached from leg 3.
if zig test -ODebug -Mroot=src/main.zig --cache-dir .zig-cache \
    --global-cache-dir .zenv/cache --name test > "$GATE_DIR/test-perline.log" 2>&1; then
    ok "test (per-test run completed)"
else
    fail "test (per-test run failed; see $GATE_DIR/test-perline.log)"
fi
# Interleaved test output can split an OK token onto its own line, so the
# exact OK count is not load-bearing. The signals that matter: the stream
# exists, no per-test FAIL line, the last denominator equals the Build
# Summary total, and the All-passed line agrees.
PER_FIRST="$(grep -E '^[0-9]+/[0-9]+ ' "$GATE_DIR/test-perline.log" | head -1 || true)"
PER_N="$(grep -E '^[0-9]+/[0-9]+ ' "$GATE_DIR/test-perline.log" | tail -1 | sed -nE 's|^[0-9]+/([0-9]+) .*|\1|p')"
ALL_PASSED="$(sed -nE 's/^All ([0-9]+) tests passed\.$/\1/p' "$GATE_DIR/test-perline.log" | tail -1 || true)"
PER_FAIL="$(grep -cE '^[0-9]+/[0-9]+ .*\.\.\.FAIL' "$GATE_DIR/test-perline.log" || true)"
if [ -z "$PER_FIRST" ]; then
    fail "test per-test (no per-test lines captured)"
elif [ "$PER_FAIL" -ne 0 ]; then
    fail "test per-test ($PER_FAIL failing line(s); see $GATE_DIR/test-perline.log)"
elif [ "$PER_N" != "$TESTS_TOTAL" ]; then
    fail "test per-test (runner denominator ${PER_N:-missing} != $TESTS_TOTAL total)"
elif [ "$ALL_PASSED" != "$TESTS_TOTAL" ]; then
    fail "test per-test (All-passed line ${ALL_PASSED:-missing} != $TESTS_TOTAL total)"
else
    ok "test per-test ($PER_N lines, all passed)"
fi

# --- 3c. test discovery cross-check (EPH-I1088) ----------------------------
# The ephor-side static listing is the runner count's twin: every `i/N`
# denominator and the Build Summary total must agree with it. A mismatch
# means either the discovery walk regressed or a test file dropped out of
# the scan path.
if ./zig-out/bin/ephor list-tests src/ > "$GATE_DIR/tests-list.txt" 2>&1; then
    LIST_COUNT="$(sed -nE 's/^([0-9]+) test blocks? found$/\1/p' "$GATE_DIR/tests-list.txt" | tail -1 || true)"
    if [ "$LIST_COUNT" = "$TESTS_TOTAL" ]; then
        ok "test discovery (listing $LIST_COUNT == runner $TESTS_TOTAL)"
    else
        fail "test discovery (listing ${LIST_COUNT:-missing} != runner $TESTS_TOTAL)"
    fi
else
    fail "test discovery (list-tests failed; see $GATE_DIR/tests-list.txt)"
fi

# --- 4. dogfood ratchet ----------------------------------------------------
# fail_on: warning is the intended posture: the check exits 1 while
# warnings exist. The ratchet is tracked, not green.
#
# Footer shape (renderResultFooter, src/main.zig): the run
# prints "ephor: E error(s)[, W warning(s)[, N note(s)] found]" with the
# severity segments in that order, zero-count segments skipped, counts
# singularized at 1, and NO footer when the run has no findings. The
# error segment prints only when error-severity findings exist
# (EPH-I0740). The ratchet tracks the fail_on:warning count, which
# includes errors (tallyIssues folds errors into warnings), so the
# tracked number is errors + warnings. The summary TOTAL: line includes
# notes (printCheckSummary, src/main.zig), so the footer is the
# warning-count source.
set +e
./zig-out/bin/ephor check src/ --summary > "$GATE_DIR/dogfood.log" 2>&1
DOGFOOD_EXIT=$?
set -e
# Two extractions cover every form: the error count (present only in the
# error forms) and the warning count (the warnings segment of the error
# forms, or the plain warnings forms). Each sed prints only on a match,
# so a missing form leaves the variable empty and the arithmetic default
# covers it.
DOG_ERRS="$(sed -nE 's/^ephor: ([0-9]+) errors?(, .*)? found$/\1/p' "$GATE_DIR/dogfood.log" | tail -1 || true)"
DOG_WARNINGS="$(sed -nE 's/^ephor: ([0-9]+) errors?, ([0-9]+) warnings?(, .*)? found$/\2/p; s/^ephor: ([0-9]+) warnings?(, .*)? found$/\1/p' "$GATE_DIR/dogfood.log" | tail -1 || true)"
DOG_TOTAL="$(( ${DOG_ERRS:-0} + ${DOG_WARNINGS:-0} ))"
if [ "$DOG_TOTAL" -eq 0 ]; then
    DOG_COUNT=""
else
    DOG_COUNT="$DOG_TOTAL"
fi
DOG_BASE="$(awk '$1 == "dogfood" {print $2}' "$BASELINES")"
# Same token validation as the test ratchet: empty, non-numeric, 10+
# character digit runs (EPH-I1128), or multi-line values must fail
# before any -gt comparison.
case "$DOG_BASE" in
    '' | *[!0-9]* | ??????????*)
        fail "dogfood ratchet (baseline missing or malformed in $BASELINES)"
        ;;
    *)
        if [ -n "$DOG_COUNT" ] && [ "$DOG_COUNT" -gt "$DOG_BASE" ]; then
            fail "dogfood ratchet ($DOG_COUNT above baseline $DOG_BASE)"
        else
            ok "dogfood ratchet (${DOG_COUNT:-0} <= baseline $DOG_BASE)"
        fi
        ;;
esac
if [ -z "$DOG_COUNT" ]; then
    # Zero warnings: the notes-only footer or the clean form (no footer).
    # A completed --summary scan always prints the STATUS line; its absence
    # at a zero count means the scan did not complete.
    if ! grep -qE '^STATUS: ' "$GATE_DIR/dogfood.log"; then
        fail "dogfood ratchet (0 warnings but no summary block — scan did not complete)"
    elif [ "$DOGFOOD_EXIT" -ne 0 ]; then
        fail "dogfood fail_on pairing (0 warnings but exit $DOGFOOD_EXIT)"
    else
        ok "dogfood fail_on pairing (warnings=0, exit=$DOGFOOD_EXIT)"
    fi
else
    if [ "$DOGFOOD_EXIT" -ne 1 ]; then
        fail "dogfood fail_on pairing ($DOG_COUNT warnings but exit $DOGFOOD_EXIT)"
    else
        ok "dogfood fail_on pairing (warnings=$DOG_COUNT, exit=$DOGFOOD_EXIT)"
    fi
fi

# --- 4b. coverage gate (EPH-I1091) ------------------------------------------
# The ephor.json coverage block gates the ZT105 unreached-pub-fn ratio
# inside `check`; --coverage-evidence feeds the runner's counts so
# min_tests/require_all_passed evaluate. Exit 1 is expected here (fail_on
# warning plus the dogfood warnings), so the leg reads the coverage lines:
# a "coverage gate:" line is a trip, a "could not read evidence" line is a
# plumbing break, and a "coverage:" ratio line is the dogfood-clean ratio.
if [ -n "$TESTS_PASSED" ] && [ -n "$TESTS_TOTAL" ]; then
    printf '{"passed": %s, "total": %s}\n' "$TESTS_PASSED" "$TESTS_TOTAL" > "$GATE_DIR/coverage-evidence.json"
    set +e
    ./zig-out/bin/ephor check src/ --summary --coverage-evidence="$GATE_DIR/coverage-evidence.json" > "$GATE_DIR/coverage.log" 2>&1
    set -e
    if grep -qE '^ephor: coverage gate:' "$GATE_DIR/coverage.log"; then
        fail "coverage gate (see $GATE_DIR/coverage.log)"
        grep -E '^ephor: coverage gate:' "$GATE_DIR/coverage.log" >> "$LOG" || true
    elif grep -q 'could not read evidence file' "$GATE_DIR/coverage.log"; then
        fail "coverage gate (evidence file broken; see $GATE_DIR/coverage.log)"
    elif grep -qE '^ephor: coverage:' "$GATE_DIR/coverage.log"; then
        ok "coverage gate ($(grep -E '^ephor: coverage:' "$GATE_DIR/coverage.log" | tail -1))"
    else
        note "coverage gate (no ephor.json coverage block — leg inert; recipe in README)"
    fi
else
    fail "coverage gate (cannot parse test counts for the evidence file)"
fi

# --- 5. corpus A/B ----------------------------------------------------------
AB_DIR="$GATE_DIR/ab"
mkdir -p "$AB_DIR"
for corpus in $CORPORA; do
    cdir="$CORPUS_ROOT/$corpus"
    if [ ! -d "$cdir" ]; then
        fail "corpus A/B: $corpus (missing at $cdir)"
        continue
    fi
    txt="$AB_DIR/current-$corpus.txt"
    md="$AB_DIR/current-$corpus.md"
    base_txt="$AB_DIR/baseline-$corpus.txt"
    base_md="$AB_DIR/baseline-$corpus.norm.md"
    set +e
    ./zig-out/bin/ephor check "$cdir" --export="$AB_DIR/current-$corpus.md" > "$txt" 2>&1
    scan_exit=$?
    set -e
    # Footer shape (renderResultFooter, src/main.zig): a clean
    # scan exits 0 (no footer when no findings); a findings scan exits 1
    # and prints one footer with the severity segments in order —
    # "ephor: E error(s)[, W warning(s)[, N note(s)] found]", zero-count
    # segments skipped, counts singularized at 1, and the error segment
    # present only when error-severity findings exist (EPH-I0740); a
    # crash (exit 128+) or a run error (exit 1 without a footer) fails
    # the leg.
    if [ "$scan_exit" -gt 1 ]; then
        fail "corpus A/B: $corpus scan (exit $scan_exit; see $txt)"
        continue
    fi
    if [ "$scan_exit" -eq 1 ] && ! grep -qE '^ephor: ([0-9]+ errors?(, ([0-9]+ warnings?(, [0-9]+ notes?)?|[0-9]+ notes?))?|[0-9]+ warnings?(, [0-9]+ notes?)?|[0-9]+ notes?) found$' "$txt"; then
        fail "corpus A/B: $corpus scan (exit 1 without a findings footer; see $txt)"
        continue
    fi
    norm="$AB_DIR/current-$corpus.norm.md"
    grep -vE '^# (Ephor Issues Export|Generated:)' "$md" > "$norm" || true
    if [ ! -f "$base_txt" ]; then
        cp "$txt" "$base_txt"
        cp "$norm" "$base_md"
        note "corpus A/B: $corpus baseline seeded"
        continue
    fi
    identical=1
    if ! diff -q "$base_txt" "$txt" > /dev/null 2>&1; then
        identical=0
        diff "$base_txt" "$txt" > "$AB_DIR/diff-$corpus.txt" 2>&1 || true
    fi
    if ! diff -q "$base_md" "$norm" > /dev/null 2>&1; then
        identical=0
        diff "$base_md" "$norm" > "$AB_DIR/diff-$corpus.md" 2>&1 || true
    fi
    if [ "$identical" -eq 1 ]; then
        ok "corpus A/B: $corpus byte-identical (text + export)"
    else
        fail "corpus A/B: $corpus differs (see $AB_DIR/diff-$corpus.*)"
    fi
done

# --- verdict ----------------------------------------------------------------
printf '\ngate: %s step(s) failed (log: %s)\n' "$FAILURES" "$GATE_DIR/gate.log"
printf 'gate: %s step(s) failed (log: %s)\n' "$FAILURES" "$GATE_DIR/gate.log" >> "$LOG"
if [ "$FAILURES" -gt 0 ]; then
    exit 1
fi
exit 0
