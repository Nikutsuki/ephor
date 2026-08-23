#!/usr/bin/env bash
# ephor Layer-1 gate (EPH-I1074; serves REL-GATE-2 and REL-AB-5).
#
# Steps: fmt, ReleaseSafe build, test ratchet, dogfood ratchet (fail_on:
# warning posture), corpus A/B (zls/ghostty/sig/tigerbeetle).
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
# class), and multi-line values from duplicated keys in one test.
case "$TESTS_BASE" in
    '' | *[!0-9]*)
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

# --- 4. dogfood ratchet ----------------------------------------------------
# fail_on: warning is the intended posture: the check exits 1 while
# warnings exist. The ratchet is tracked, not green.
#
# Footer contract (printResultFooter, src/main.zig:40530-40551): the run
# prints "ephor: N warning(s)[, M note(s)] found" when warnings exist,
# "ephor: N note(s) found" when only notes exist, and NO footer when the
# tree is clean (0 warnings + 0 notes). The counts singularize at 1. The
# summary TOTAL: includes notes (src/main.zig:40762), so the footer is the
# warning-count source.
set +e
./zig-out/bin/ephor check src/ --summary > "$GATE_DIR/dogfood.log" 2>&1
DOGFOOD_EXIT=$?
set -e
DOG_COUNT="$(sed -nE 's/^ephor: ([0-9]+) warnings?(, [0-9]+ notes?)? found$/\1/p' "$GATE_DIR/dogfood.log" | tail -1 || true)"
DOG_BASE="$(awk '$1 == "dogfood" {print $2}' "$BASELINES")"
# Same token validation as the test ratchet: empty, non-numeric, or
# multi-line values must fail before any -gt comparison.
case "$DOG_BASE" in
    '' | *[!0-9]*)
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
    # Scan contract (printResultFooter, src/main.zig:40530-40551): a clean
    # scan exits 0 (no footer at 0 warnings + 0 notes); a findings scan
    # exits 1 and prints one of the three footer forms (warnings, warnings
    # + notes, notes only — counts singularize at 1); a crash (exit 128+)
    # or a run error (exit 1 without a footer) fails the leg.
    if [ "$scan_exit" -gt 1 ]; then
        fail "corpus A/B: $corpus scan (exit $scan_exit; see $txt)"
        continue
    fi
    if [ "$scan_exit" -eq 1 ] && ! grep -qE '^ephor: ([0-9]+ warnings?(, [0-9]+ notes?)?|[0-9]+ notes?) found$' "$txt"; then
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
