#!/bin/sh
# Regression suite for install.sh (batch B65: EPH-I0625 through EPH-I0630;
# batch B66: EPH-I0631 through EPH-I0636; batch B67: EPH-I0637 through
# EPH-I0642; batch B85: EPH-I0205; batch B86f: EPH-I1104/I1106/I1107/
# I1110/I1111; batch B93p: EPH-I0717/I0720; batch B94: EPH-I0060/I0284;
# batch B93a: EPH-I1159; batch B106: EPH-I0715; batch B132: EPH-I1220;
# WP-7: the embedded release key activates the verification).
# Runs the real installer against planted fixtures in scratch dirs under
# .tmp/install-sh-tests. Hermetic: the fake zig on PATH answers version
# and fetch, the tags API and the verification archive are local files,
# and a fake minisign serves the signature check, so no network is
# touched. The text assertions pin the fixed behavior. Zon parseability
# for the fallback names was verified with real zig 0.16.0 during
# development (see the batch report), so this suite stays fast and
# shell-only.
#
# Run:
#   sh tests/install-sh-tests.sh          (suite and installer under /bin/sh)
#   dash tests/install-sh-tests.sh        (suite under dash)
#   RUN_SH=dash tests/install-sh-tests.sh (installer under dash)
#   DEBUG=1 ...                           (keep the scratch tree)

set -eu

REPO_ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
INSTALL_SH="$REPO_ROOT/install.sh"
TEST_ROOT="$REPO_ROOT/.tmp/install-sh-tests"
INSTALL_RUNNER="${RUN_SH:-sh}"
if [ "${DEBUG:-0}" = "1" ]; then
    KEEP=1
else
    KEEP=0
fi
trap 'if [ "$KEEP" -eq 0 ]; then rm -rf "$TEST_ROOT"; fi' EXIT
rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT/bin"

# The fake zig answers version from FAKE_ZIG_VERSION and succeeds on
# every fetch without network. When FETCH_FAIL_FILE names an existing
# file, the next fetch consumes it, prints its content on stderr, and
# exits 1 (the F-10 fingerprint-heal tests).
cat > "$TEST_ROOT/bin/zig" <<'EOF'
#!/bin/sh
if [ "$1" = "version" ]; then
    printf '%s\n' "$FAKE_ZIG_VERSION"
    exit 0
fi
if [ -n "${FETCH_FAIL_FILE:-}" ] && [ -e "$FETCH_FAIL_FILE" ]; then
    cat "$FETCH_FAIL_FILE" >&2
    rm -f "$FETCH_FAIL_FILE"
    exit 1
fi
exit 0
EOF
chmod +x "$TEST_ROOT/bin/zig"

# The fake chmod forwards to the real chmod. It blocks for three seconds
# while the F-9 test's project-local marker exists, so the test can send
# TERM to the installer with a live temp file. The installer calls chmod
# only in make_install_tmp and preserve_mode.
cat > "$TEST_ROOT/bin/chmod" <<'EOF'
#!/bin/sh
if [ -e .ephor-chmod-block ]; then
    sleep 3
    [ -e .ephor-chmod-block ] || exit 0
fi
exec /bin/chmod "$@"
EOF
chmod +x "$TEST_ROOT/bin/chmod"

printf '%s\n' '[{"name":"v0.99.1"}]' > "$TEST_ROOT/tags.json"

# The active-verification fixtures (WP-7): an inert tarball and signature
# the verification downloads over the file:// test channel, and a fake
# minisign that records the pubkey it received into the project dir and
# reports the success verdict. The embedded release key drives every
# default run; the assertions grep the recorded key.
printf 'inert archive fixture\n' > "$TEST_ROOT/archive.tar.gz"
printf 'inert signature fixture\n' > "$TEST_ROOT/archive.tar.gz.minisig"
cat > "$TEST_ROOT/bin/minisign" <<'EOF'
#!/bin/sh
# Fake minisign for the active-verification runs: record the pubkey the
# installer handed over, then report the success verdict. The key content
# is never parsed: the assertions grep the recorded file.
if [ "$1" = "-v" ]; then
    exit 0
fi
tarball=""
pubkey=""
while [ $# -gt 0 ]; do
    case "$1" in
        -Vm) shift; tarball="$1" ;;
        -p) shift; pubkey="$1" ;;
    esac
    shift
done
[ -f "$tarball" ] || { echo missing-tarball >&2; exit 1; }
[ -f "$tarball.minisig" ] || { echo missing-signature >&2; exit 1; }
[ -f "$pubkey" ] || { echo missing-pubkey >&2; exit 1; }
printf '%s\n' ran > .minisign-ran
cat "$pubkey" > .minisign-pubkey
echo "Signature and comment signature verified"
exit 0
EOF
chmod +x "$TEST_ROOT/bin/minisign"

PATH="$TEST_ROOT/bin:$PATH"
export PATH
export EPHOR_TAGS_API="file://$TEST_ROOT/tags.json"
export EPHOR_ARCHIVE_URL="file://$TEST_ROOT/archive.tar.gz"
# WP-7: the derived signature URL points at the live raw-branch route,
# so the signature override rides the same file:// channel to keep every
# default run hermetic. t54 pins the derived URL itself.
export EPHOR_SIG_URL="file://$TEST_ROOT/archive.tar.gz.minisig"
# EPH-I0205: the URL overrides are test hooks gated behind an explicit
# test-mode marker. The suite is the sanctioned test channel, so it sets
# the marker for every run. t38 covers the no-marker production shape.
export EPHOR_TEST_MODE=1
export FAKE_ZIG_VERSION="0.16.0"

PASS_COUNT=0
pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "PASS $1"
}
fail() {
    echo "FAIL $1" >&2
    echo "Scratch kept at: $TEST_ROOT" >&2
    exit 1
}

# Run the installer with the project dir as the working directory.
# Leaves stdout in $1/out.log, stderr in $1/err.log, exit code in $rc.
run_installer() {
    rc=0
    (cd "$1" && "$INSTALL_RUNNER" "$INSTALL_SH") > "$1/out.log" 2> "$1/err.log" || rc=$?
}

# Run the installer with FAKE_ZIG_VERSION set for this one run, then
# restore the suite default. A bare prefix assignment is not portable:
# bash keeps it after the function returns, dash does not.
run_installer_with_zig() { # version, dir
    FAKE_ZIG_VERSION="$1"
    run_installer "$2"
    FAKE_ZIG_VERSION="0.16.0"
}

# Run the installer with the first fetch failing (F-10): the fake zig
# consumes FETCH_FAIL_FILE once and answers that fetch with its content.
# The variable is exported for the run and unset after it, so no run
# leaks it into a later test.
run_installer_with_fetch_fail() { # failure_file, dir
    FETCH_FAIL_FILE="$1"
    export FETCH_FAIL_FILE
    run_installer "$2"
    FETCH_FAIL_FILE=""
    export FETCH_FAIL_FILE
}

# Run the installer with a strict umask (F-8): umasks that strip owner
# write must still leave the temp files writable.
run_installer_with_umask() { # umask, dir
    rc=0
    (umask "$1" && cd "$2" && "$INSTALL_RUNNER" "$INSTALL_SH") \
        > "$2/out.log" 2> "$2/err.log" || rc=$?
}

# Run the installer with no zig on PATH (F-7).
run_installer_without_zig() { # dir
    OLD_PATH=$PATH
    PATH="/usr/bin:/bin"
    run_installer "$1"
    PATH=$OLD_PATH
}

# Run the installer with $1/bin prepended to PATH for this one run
# (F-12 GNU-dialect arm: a fake uname selects the stat -c branch and a
# fake GNU stat serves it through the gate machine's BSD stat).
run_installer_with_bin() { # bin_dir, dir
    OLD_PATH=$PATH
    PATH="$1:$PATH"
    run_installer "$2"
    PATH=$OLD_PATH
}

# Run the installer with the tags API file replaced for this one run
# (F-13): write $1 over the shared tags.json, run, then restore the
# suite default so no run leaks the fixture into a later test.
run_installer_with_tags() { # tags_file, dir
    cp "$1" "$TEST_ROOT/tags.json"
    run_installer "$2"
    printf '%s\n' '[{"name":"v0.99.1"}]' > "$TEST_ROOT/tags.json"
}

assert_eq() { # want, got, label
    [ "$1" = "$2" ] || fail "$3 (want [$1], got [$2])"
}
assert_rc() { # want
    assert_eq "$1" "$rc" "wrong exit code"
}
assert_grep() { # file, pattern, label
    grep -qF "$2" "$1" || fail "$3 (missing: $2)"
}
assert_not_grep() { # file, pattern, label
    if grep -qF "$2" "$1"; then
        fail "$3 (unexpected: $2)"
    fi
}
assert_unchanged() { # file, original, label
    cmp -s "$1" "$2" || fail "$3 (file changed)"
}
assert_empty() { # file, label
    [ ! -s "$1" ] || fail "$2 (expected empty, got $(wc -c < "$1" | tr -d ' ') bytes)"
}

# EPH-I1220, WP-7: the embedded release key activates the verification,
# so every successful install that reaches verify_ephor_release checks
# the fixture pair against the release key first. The active path prints
# nothing to stderr on success, so the strict-stderr tests expect an
# empty err.log (assert_empty below). A changed installer stderr surface
# fails them instead of drifting past the pin.

count_of() { # file, pattern -> count on stdout
    grep -cF "$2" "$1" | cat
}
line_of() { # file, pattern -> line number on stdout
    grep -nF "$2" "$1" | head -1 | cut -d: -f1
}

# A minimal fresh build.zig: no ephor markers, no dependency, a single
# installArtifact statement.
write_fresh_build_zig() {
    cat > "$1/build.zig" <<'EOF'
const std = @import("std");
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);
}
EOF
}

# The canonical ephor block in fixture shape. The installer replaces the
# span between the markers with its own EPHOR_BLOCK, so the fixture only
# needs the anchored markers and the dependency line in the right places.
write_canonical_block() {
    cat <<'EOF'
    // Ephor static analysis
    const ephor_dep = b.dependency("ephor", .{ .target = target, .optimize = .ReleaseSafe });
    const ephor_artifact = ephor_dep.artifact("ephor");
    const ephor_cmd = b.addRunArtifact(ephor_artifact);
    if (b.args) |args| {
        ephor_cmd.addArgs(args);
    }
    const ephor_step = b.step("ephor", "Run ephor static analysis");
    ephor_step.dependOn(&ephor_cmd.step);

    // Ephor upgrade
    const ephor_upgrade_cmd = b.addRunArtifact(ephor_artifact);
    ephor_upgrade_cmd.addArgs(&.{"upgrade"});
    const ephor_upgrade_step = b.step("ephor-upgrade", "Upgrade ephor to latest version");
    ephor_upgrade_step.dependOn(&ephor_upgrade_cmd.step);
EOF
}

# The ephor block without its upgrade section: a drifted block shape
# that lost its end marker.
write_analysis_only_block() {
    cat <<'EOF'
    // Ephor static analysis
    const ephor_dep = b.dependency("ephor", .{ .target = target, .optimize = .ReleaseSafe });
    const ephor_artifact = ephor_dep.artifact("ephor");
    const ephor_cmd = b.addRunArtifact(ephor_artifact);
    const ephor_step = b.step("ephor", "Run ephor static analysis");
    ephor_step.dependOn(&ephor_cmd.step);
EOF
}

# --- t01 (EPH-I0625): a doc comment quoting the start marker above a
# real block must not point the splice at the comment.
D="$TEST_ROOT/t01"
mkdir -p "$D"
{
    echo 'const std = @import("std");'
    echo ''
    echo '/// See: // Ephor static analysis'
    echo 'pub fn build(b: *std.Build) !void {'
    echo '    const target = b.standardTargetOptions(.{});'
    echo '    const optimize = b.standardOptimizeOption(.{});'
    echo ''
    write_canonical_block
    echo '}'
} > "$D/build.zig"
run_installer "$D"
assert_rc 0
assert_grep "$D/build.zig" '/// See:' 'the doc comment was deleted'
assert_eq 1 "$(count_of "$D/build.zig" '    // Ephor static analysis')" 'marker count wrong'
assert_empty "$D/err.log" 'stderr not empty'
pass "t01 doc comment quoting the marker (F-1)"

# --- t02 (EPH-I0626): a comment mentioning the end marker above a real
# block must not shorten the span and duplicate the lines in between.
D="$TEST_ROOT/t02"
mkdir -p "$D"
{
    echo 'const std = @import("std");'
    echo ''
    echo '// ephor_upgrade_step.dependOn(&ephor_upgrade_cmd.step);'
    echo ''
    echo 'pub fn build(b: *std.Build) !void {'
    echo '    const target = b.standardTargetOptions(.{});'
    echo '    const optimize = b.standardOptimizeOption(.{});'
    echo ''
    write_canonical_block
    echo '}'
} > "$D/build.zig"
run_installer "$D"
assert_rc 0
assert_eq 1 "$(count_of "$D/build.zig" 'pub fn build')" 'build function duplicated'
assert_grep "$D/build.zig" '// ephor_upgrade_step.dependOn' 'the mention comment was deleted'
assert_empty "$D/err.log" 'stderr not empty'
pass "t02 comment mentioning the end marker (F-2)"

# --- t03 (EPH-I0628): a block that lost its end marker must refuse
# instead of skipping silently and printing Done!.
D="$TEST_ROOT/t03"
mkdir -p "$D"
{
    echo 'const std = @import("std");'
    echo 'pub fn build(b: *std.Build) !void {'
    write_analysis_only_block
    echo '}'
} > "$D/build.zig"
cp "$D/build.zig" "$D/build.zig.orig"
run_installer "$D"
assert_rc 1
assert_grep "$D/err.log" 'missing one of its markers' 'no refusal warning'
assert_unchanged "$D/build.zig" "$D/build.zig.orig" 'build.zig'
assert_not_grep "$D/out.log" 'Done!' 'Done! printed after a refused splice'
pass "t03 exactly one marker refuses (F-4)"

# --- t04 (EPH-I0626): an end marker before the start marker must refuse
# instead of duplicating the middle.
D="$TEST_ROOT/t04"
mkdir -p "$D"
{
    echo 'const std = @import("std");'
    echo 'pub fn build(b: *std.Build) !void {'
    echo '    const target = b.standardTargetOptions(.{});'
    echo '    ephor_upgrade_step.dependOn(&ephor_upgrade_cmd.step);'
    write_analysis_only_block
    echo '}'
} > "$D/build.zig"
cp "$D/build.zig" "$D/build.zig.orig"
run_installer "$D"
assert_rc 1
assert_grep "$D/err.log" 'out of order' 'no order warning'
assert_unchanged "$D/build.zig" "$D/build.zig.orig" 'build.zig'
pass "t04 reversed marker order refuses (F-2)"

# --- t05 (EPH-I0626): a duplicated block must refuse (replacing the
# first copy would leave a second stale block behind).
D="$TEST_ROOT/t05"
mkdir -p "$D"
{
    echo 'const std = @import("std");'
    echo 'pub fn build(b: *std.Build) !void {'
    echo '    const target = b.standardTargetOptions(.{});'
    echo '    const optimize = b.standardOptimizeOption(.{});'
    echo ''
    write_canonical_block
    echo ''
    write_canonical_block
    echo '}'
} > "$D/build.zig"
cp "$D/build.zig" "$D/build.zig.orig"
run_installer "$D"
assert_rc 1
assert_grep "$D/err.log" 'more than one ephor block marker' 'no ambiguity warning'
assert_unchanged "$D/build.zig" "$D/build.zig.orig" 'build.zig'
pass "t05 duplicated block refuses (F-2)"

# --- t06 (EPH-I0625): a marker pair with no dependency line between it
# is a forged or drifted span; replacing it would delete the code inside.
D="$TEST_ROOT/t06"
mkdir -p "$D"
{
    echo 'const std = @import("std");'
    echo 'pub fn build(b: *std.Build) !void {'
    echo '    const target = b.standardTargetOptions(.{});'
    echo '    // Ephor static analysis'
    echo '    const user_code = 1;'
    echo '    ephor_upgrade_step.dependOn(&ephor_upgrade_cmd.step);'
    echo '}'
} > "$D/build.zig"
cp "$D/build.zig" "$D/build.zig.orig"
run_installer "$D"
assert_rc 1
assert_grep "$D/err.log" 'no dependency line' 'no span warning'
assert_unchanged "$D/build.zig" "$D/build.zig.orig" 'build.zig'
pass "t06 span without dependency line refuses (F-1/F-2)"

# --- t07 (EPH-I0627): a build.zig.zon symlink to a directory outside
# the project must be refused before the mv; nothing may land inside it.
D="$TEST_ROOT/t07"
OUTSIDE="$TEST_ROOT/t07-outside"
mkdir -p "$D" "$OUTSIDE"
write_fresh_build_zig "$D"
ln -s "$OUTSIDE" "$D/build.zig.zon"
run_installer "$D"
assert_rc 1
assert_grep "$D/err.log" 'build.zig.zon is a directory' 'no refusal error'
assert_eq "" "$(ls -A "$OUTSIDE" 2>/dev/null)" 'a file landed inside the symlink target'
pass "t07 zon symlink to a directory refuses (F-3)"

# --- t08 (EPH-I0627): a real directory named build.zig.zon must be
# refused the same way.
D="$TEST_ROOT/t08"
mkdir -p "$D" "$D/build.zig.zon"
write_fresh_build_zig "$D"
run_installer "$D"
assert_rc 1
assert_grep "$D/err.log" 'build.zig.zon is a directory' 'no refusal error'
pass "t08 zon directory refuses (F-3)"

# --- t09 (EPH-I0629): a dotted directory name sanitizes to underscores
# with a warning.
D="$TEST_ROOT/my.project"
mkdir -p "$D"
write_fresh_build_zig "$D"
run_installer "$D"
assert_rc 0
assert_grep "$D/build.zig.zon" '.name = .my_project,' 'zon name not sanitized'
assert_grep "$D/err.log" 'not a valid Zig identifier' 'missing warning'
pass "t09 dotted directory name sanitizes (F-5)"

# --- t10 (EPH-I0629): a leading digit gets an underscore prefix.
D="$TEST_ROOT/123proj"
mkdir -p "$D"
write_fresh_build_zig "$D"
run_installer "$D"
assert_rc 0
assert_grep "$D/build.zig.zon" '.name = ._123proj,' 'zon name not prefixed'
assert_grep "$D/err.log" 'not a valid Zig identifier' 'missing warning'
pass "t10 leading-digit directory name prefixed (F-5)"

# --- t11 (EPH-I0629): a reserved-word name falls back to a fixed name.
D="$TEST_ROOT/comptime"
mkdir -p "$D"
write_fresh_build_zig "$D"
run_installer "$D"
assert_rc 0
assert_grep "$D/build.zig.zon" '.name = .project,' 'zon name not fixed'
assert_grep "$D/err.log" 'reserved word in Zig' 'missing warning'
pass "t11 reserved-word directory name fixed (F-5)"

# --- t12 (EPH-I0629, positive): a valid name passes through unwarned.
D="$TEST_ROOT/proj_ok"
mkdir -p "$D"
write_fresh_build_zig "$D"
run_installer "$D"
assert_rc 0
assert_grep "$D/build.zig.zon" '.name = .proj_ok,' 'zon name wrong'
assert_empty "$D/err.log" 'stderr not empty'
pass "t12 valid directory name unchanged (F-5 positive)"

# --- t13 (EPH-I0630): garbage zig version text warns and takes the
# latest-tag path instead of the silent 0.15-era pin.
D="$TEST_ROOT/t13"
mkdir -p "$D"
write_fresh_build_zig "$D"
run_installer_with_zig "abc" "$D"
assert_rc 0
assert_grep "$D/err.log" 'could not parse the zig version' 'missing parse warning'
assert_grep "$D/out.log" 'v0.99.1' 'did not take the latest-tag path'
cat "$D/out.log" "$D/err.log" > "$D/both.log"
assert_not_grep "$D/both.log" 'Illegal number' 'dash noise present'
assert_not_grep "$D/both.log" 'integer expression' 'bash noise present'
assert_not_grep "$D/out.log" 'v0.11.13' '0.15-era pin chosen on garbage'
pass "t13 garbage zig version takes latest tag (F-6)"

# --- t14 (EPH-I0630, positive): a real Zig 0.16 version stays silent.
D="$TEST_ROOT/t14"
mkdir -p "$D"
write_fresh_build_zig "$D"
run_installer_with_zig "0.16.0" "$D"
assert_rc 0
assert_grep "$D/out.log" 'v0.99.1' 'latest tag not chosen'
assert_empty "$D/err.log" 'stderr not empty'
pass "t14 zig 0.16.0 takes latest tag (F-6 positive)"

# --- t15 (EPH-I0630, WP-7): a Zig 0.15 version keeps the pin path. The
# WP-7 era-pin carve skips the signature check for the pinned commit
# archive: it is SHA-addressed and immutable on the remote, while a tag
# is a mutable pointer. The fake curl proves the skip — any
# verification download would invoke it and fail the install closed.
D="$TEST_ROOT/t15"
BINDIR="$TEST_ROOT/t15-bin"
mkdir -p "$D" "$BINDIR"
cat > "$BINDIR/curl" <<'EOF'
#!/bin/sh
# Fake curl for the 0.15-era pin path (WP-7 carve): the carve skips
# every verification download, so any curl call means the skip failed.
# Record the call, then fail the install closed.
printf '%s\n' "$*" > .curl-calls
exit 22
EOF
chmod +x "$BINDIR/curl"
write_fresh_build_zig "$D"
FAKE_ZIG_VERSION="0.15.0"
run_installer_with_bin "$BINDIR" "$D"
FAKE_ZIG_VERSION="0.16.0"
assert_rc 0
assert_grep "$D/out.log" 'v0.11.13' '0.15 pin not chosen'
assert_grep "$D/out.log" 'skips signature verification' 'no carve line'
assert_grep "$D/out.log" 'Done!' 'Done! not printed'
assert_not_grep "$D/out.log" 'Release signature verified.' 'the tag-path verify line printed on the carve'
assert_empty "$D/err.log" 'stderr not empty'
[ ! -e "$D/.curl-calls" ] || fail "the carve path invoked curl (args: $(cat "$D/.curl-calls"))"
pass "t15 zig 0.15.0 pin skips signature verification (F-6, WP-7 carve)"

# --- t16 (EPH-I0626, positive): a fresh install with a one-line
# installArtifact statement inserts the block after that line.
D="$TEST_ROOT/t16"
mkdir -p "$D"
write_fresh_build_zig "$D"
run_installer "$D"
assert_rc 0
assert_grep "$D/out.log" 'Done!' 'no Done! summary'
assert_empty "$D/err.log" 'stderr not empty'
# The embedded release key (WP-7) drove the verification: the fake
# minisign recorded the exact key line the installer handed over.
assert_grep "$D/.minisign-pubkey" 'RWS+PtUzLvwpvc7nVJ8t8MKTpo4/8UdOqoxuLGXhfJQI+qvTyn82Dfit' \
    'the embedded release key did not reach minisign'
assert_grep "$D/out.log" 'Release signature verified.' 'no verification line'
install_line=$(line_of "$D/build.zig" 'b.installArtifact(exe)')
marker_line=$(line_of "$D/build.zig" '    // Ephor static analysis')
[ "$marker_line" -gt "$install_line" ] \
    || fail "block landed before the statement (install $install_line, marker $marker_line)"
pass "t16 fresh install after one-line statement (F-2 positive)"

# --- t17 (EPH-I0626): a fresh install with a multi-line statement
# inserts the block after the closing );, not mid-statement.
D="$TEST_ROOT/t17"
mkdir -p "$D"
{
    echo 'const std = @import("std");'
    echo 'pub fn build(b: *std.Build) !void {'
    echo '    const target = b.standardTargetOptions(.{});'
    echo '    const optimize = b.standardOptimizeOption(.{});'
    echo '    const exe = b.addExecutable(.{ .name = "demo", .root_module = b.createModule(.{}),'
    echo '        .target = target, .optimize = optimize });'
    echo '    b.installArtifact(exe, .{'
    echo '        .lib_dir = .prefix,'
    echo '    });'
    echo '}'
} > "$D/build.zig"
run_installer "$D"
assert_rc 0
assert_grep "$D/build.zig" 'b.installArtifact(exe, .{' 'statement opener lost'
assert_empty "$D/err.log" 'stderr not empty'
close_line=$(line_of "$D/build.zig" '});')
marker_line=$(line_of "$D/build.zig" '    // Ephor static analysis')
[ "$marker_line" -gt "$close_line" ] \
    || fail "block split the statement (close $close_line, marker $marker_line)"
pass "t17 fresh install after multi-line statement (F-2)"

# --- t18 (EPH-I0626): a statement that never reaches a semicolon must
# refuse instead of writing a broken build.zig.
D="$TEST_ROOT/t18"
mkdir -p "$D"
cat > "$D/build.zig" <<'EOF'
const std = @import("std");
pub fn build(b: *std.Build) !void {
    const exe = b.addExecutable(.{ .name = "demo", .root_module = b.createModule(.{}) });
    b.installArtifact(exe, .{
EOF
cp "$D/build.zig" "$D/build.zig.orig"
run_installer "$D"
assert_rc 1
assert_grep "$D/err.log" 'does not end before the end' 'no refusal warning'
assert_unchanged "$D/build.zig" "$D/build.zig.orig" 'build.zig'
pass "t18 unterminated statement refuses (F-2)"

# --- t19 (F-B65-1): digit-led garbage with non-numeric components must
# warn and take the latest tag; the integer tests must never see it.
D="$TEST_ROOT/t19"
mkdir -p "$D"
write_fresh_build_zig "$D"
run_installer_with_zig "1a.2b.3c" "$D"
assert_rc 0
assert_grep "$D/err.log" 'could not parse the zig version' 'missing parse warning'
assert_grep "$D/out.log" 'v0.99.1' 'did not take the latest-tag path'
cat "$D/out.log" "$D/err.log" > "$D/both.log"
assert_not_grep "$D/both.log" 'Illegal number' 'dash noise present'
assert_not_grep "$D/both.log" 'integer expression' 'bash noise present'
assert_not_grep "$D/out.log" 'v0.11.13' '0.15-era pin chosen on garbage'
pass "t19 non-numeric components take latest tag (F-B65-1)"

# --- t20 (F-B65-2): the legacy v0.11.x snippet migrates to the
# canonical block.
D="$TEST_ROOT/t20"
mkdir -p "$D"
{
    echo 'const std = @import("std");'
    echo 'pub fn build(b: *std.Build) !void {'
    echo '    const target = b.standardTargetOptions(.{});'
    echo '    const optimize = b.standardOptimizeOption(.{});'
    echo ''
    echo '    // === Ephor Static Analysis ==='
    echo '    const ephor_dep = b.dependency("ephor", .{'
    echo '        .target = target,'
    echo '        .optimize = .ReleaseSafe,'
    echo '    });'
    echo '    const ephor_exe = ephor_dep.artifact("ephor");'
    echo '    const ephor_step = b.step("ephor", "Run ephor static analysis");'
    echo '    ephor_step.dependOn(&b.addRunArtifact(ephor_exe).step);'
    echo '}'
} > "$D/build.zig"
run_installer "$D"
assert_rc 0
assert_grep "$D/out.log" 'migrated from v0.11.x snippet' 'no migration message'
assert_empty "$D/err.log" 'stderr not empty'
assert_eq 0 "$(count_of "$D/build.zig" '=== Ephor Static Analysis ===')" 'legacy marker remains'
assert_eq 1 "$(count_of "$D/build.zig" '    // Ephor static analysis')" 'canonical marker missing'
assert_not_grep "$D/build.zig" 'ephor_exe' 'legacy symbol remains'
assert_grep "$D/build.zig" 'ephor_upgrade_step.dependOn' 'upgrade step missing'
pass "t20 legacy snippet migrates (F-B65-2)"

# --- t21 (F-B65-2): a legacy snippet missing its end marker refuses.
D="$TEST_ROOT/t21"
mkdir -p "$D"
{
    echo 'const std = @import("std");'
    echo 'pub fn build(b: *std.Build) !void {'
    echo '    const target = b.standardTargetOptions(.{});'
    echo '    // === Ephor Static Analysis ==='
    echo '    const ephor_dep = b.dependency("ephor", .{'
    echo '        .target = target,'
    echo '        .optimize = .ReleaseSafe,'
    echo '    });'
    echo '    const ephor_exe = ephor_dep.artifact("ephor");'
    echo '    const ephor_step = b.step("ephor", "Run ephor static analysis");'
    echo '}'
} > "$D/build.zig"
cp "$D/build.zig" "$D/build.zig.orig"
run_installer "$D"
assert_rc 1
assert_grep "$D/err.log" 'missing one of its markers' 'no refusal warning'
assert_unchanged "$D/build.zig" "$D/build.zig.orig" 'build.zig'
pass "t21 legacy snippet without end marker refuses (F-B65-2)"

# --- t22 (F-B65-3): a trailing line comment after the statement
# terminator masks the semicolon scan. With no later semicolon line the
# install refuses (loud, fail-safe) instead of guessing a cut point.
D="$TEST_ROOT/t22"
mkdir -p "$D"
cat > "$D/build.zig" <<'EOF'
const std = @import("std");
pub fn build(b: *std.Build) !void {
    const exe = b.addExecutable(.{ .name = "demo", .root_module = b.createModule(.{}) });
    b.installArtifact(exe); // build the artifact
}
EOF
cp "$D/build.zig" "$D/build.zig.orig"
run_installer "$D"
assert_rc 1
assert_grep "$D/err.log" 'does not end before the end' 'no refusal warning'
assert_unchanged "$D/build.zig" "$D/build.zig.orig" 'build.zig'
pass "t22 trailing-comment terminator refuses (F-B65-3 pin)"

# --- t23 (EPH-I0631): with no zig on PATH the installer must refuse
# before creating or changing any file, with a clear message.
D="$TEST_ROOT/t23"
mkdir -p "$D"
write_fresh_build_zig "$D"
run_installer_without_zig "$D"
assert_rc 1
assert_grep "$D/err.log" 'zig is not installed' 'no missing-zig error'
assert_not_grep "$D/out.log" 'Done!' 'Done! printed without zig'
if [ -e "$D/build.zig.zon" ]; then
    fail "build.zig.zon was created without zig"
fi
pass "t23 missing zig refuses before mutation (F-7)"

# --- t24 (EPH-I0632): a umask that strips owner write (0277) must not
# leave the temp files unwritable. The full install completes.
D="$TEST_ROOT/t24"
mkdir -p "$D"
write_fresh_build_zig "$D"
run_installer_with_umask 0277 "$D"
assert_rc 0
assert_grep "$D/out.log" 'Done!' 'install did not complete'
assert_grep "$D/build.zig.zon" '.name = .t24,' 'zon not created'
assert_grep "$D/build.zig" '    // Ephor static analysis' 'block not added'
assert_empty "$D/err.log" 'stderr not empty'
pass "t24 strict umask completes (F-8)"

# --- t25 (EPH-I0633): a TERM while a temp file is live must still clean
# it up: the signal becomes an exit, so the EXIT trap runs.
D="$TEST_ROOT/t25"
mkdir -p "$D"
write_fresh_build_zig "$D"
: > "$D/.ephor-chmod-block"
(cd "$D" && exec "$INSTALL_RUNNER" "$INSTALL_SH") > "$D/out.log" 2> "$D/err.log" &
INSTALL_PID=$!
i=0
while [ "$i" -lt 200 ]; do
    set -- "$D"/build.zig.zon.tmp.*
    if [ -e "$1" ]; then
        break
    fi
    sleep 0.05
    i=$((i + 1))
done
if [ ! -e "$1" ]; then
    kill -9 "$INSTALL_PID" 2>/dev/null || true
    rm -f "$D/.ephor-chmod-block"
    fail "temp file never appeared"
fi
kill -TERM "$INSTALL_PID"
i=0
while kill -0 "$INSTALL_PID" 2>/dev/null && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
done
if kill -0 "$INSTALL_PID" 2>/dev/null; then
    kill -9 "$INSTALL_PID" 2>/dev/null || true
    rm -f "$D/.ephor-chmod-block"
    fail "installer did not exit after TERM"
fi
rc=0
wait "$INSTALL_PID" || rc=$?
rm -f "$D/.ephor-chmod-block"
assert_rc 1
leftovers=$(ls "$D"/build.zig.zon.tmp.* 2>/dev/null || true)
[ -z "$leftovers" ] || fail "temp file left after TERM"
pass "t25 TERM runs the EXIT trap (F-9)"

# --- t26 (EPH-I0634, EPH-I1291): two hint lines in one fetch failure
# must take the first hint, not abort sed with a multi-line replacement.
# zig 0.16.0 emits two shapes — "suggested value" for the missing field
# and "use this value" for the 0x0 placeholder — and both must parse.
D="$TEST_ROOT/t26"
mkdir -p "$D"
write_fresh_build_zig "$D"
printf 'error: unable to verify package\nsuggested value: 0x1234dead\nuse this value: 0xbeefcafe\n' \
    > "$TEST_ROOT/fail-hints.txt"
run_installer_with_fetch_fail "$TEST_ROOT/fail-hints.txt" "$D"
assert_rc 0
assert_grep "$D/build.zig.zon" '.fingerprint = 0x1234dead,' 'first hint not used'
assert_not_grep "$D/build.zig.zon" '0xbeefcafe' 'second hint leaked into the zon'
if [ -e "$D/build.zig.zon.bak" ]; then
    fail "sed backup left behind"
fi
assert_empty "$D/err.log" 'stderr not empty'
pass "t26 first fingerprint hint wins (F-10, EPH-I1291 dual shape)"

# --- t27 (EPH-I0634): a hint with a bare 0x (no hex digits) must refuse
# instead of writing a broken fingerprint.
D="$TEST_ROOT/t27"
mkdir -p "$D"
write_fresh_build_zig "$D"
printf 'suggested value: 0x\n' > "$TEST_ROOT/fail-bare.txt"
run_installer_with_fetch_fail "$TEST_ROOT/fail-bare.txt" "$D"
assert_rc 1
assert_grep "$D/build.zig.zon" '.fingerprint = 0x0,' 'fingerprint changed'
assert_grep "$D/err.log" 'suggested value: 0x' 'fetch error not shown'
assert_not_grep "$D/out.log" 'Done!' 'Done! printed after refusal'
pass "t27 bare 0x hint refuses (F-10)"

# --- t28 (EPH-I0635): no installArtifact line means the build steps
# cannot be added. The dependency landed, so the exit code must not
# report success, and the summary must not print Done!.
D="$TEST_ROOT/t28"
mkdir -p "$D"
cat > "$D/build.zig" <<'EOF'
const std = @import("std");
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
}
EOF
run_installer "$D"
assert_rc 1
assert_grep "$D/err.log" 'build steps were not' 'no partial-install message'
assert_not_grep "$D/out.log" 'Done!' 'Done! printed after refusal'
assert_grep "$D/build.zig.zon" '.name = .t28,' 'zon was not created'
pass "t28 missing installArtifact fails the install (F-11)"

# --- t29 (EPH-I0636): the splice preserves the original mode. A 0600
# build.zig stays 0600 instead of re-normalizing to the umask default.
# The mode read uses the BSD stat form: the suite gate machine is macOS.
D="$TEST_ROOT/t29"
mkdir -p "$D"
{
    echo 'const std = @import("std");'
    echo 'pub fn build(b: *std.Build) !void {'
    write_canonical_block
    echo '}'
} > "$D/build.zig"
chmod 600 "$D/build.zig"
run_installer "$D"
assert_rc 0
[ "$(stat -f '%Lp' "$D/build.zig")" = "600" ] || fail "build.zig mode not preserved"
assert_empty "$D/err.log" 'stderr not empty'
pass "t29 splice preserves mode (F-12, BSD stat arm)"

# --- t30 (EPH-I0636): the GNU-dialect arm. A fake uname selects the
# stat -c branch; a fake GNU stat serves -c %a through the gate
# machine's BSD stat. Same assertion as t29.
D="$TEST_ROOT/t30"
BINDIR="$TEST_ROOT/t30-bin"
mkdir -p "$D" "$BINDIR"
cat > "$BINDIR/uname" <<'EOF'
#!/bin/sh
printf 'Linux\n'
EOF
cat > "$BINDIR/stat" <<'EOF'
#!/bin/sh
# GNU-dialect stat double: serve the installer's "stat -c %a file" call.
if [ "$#" -ne 3 ] || [ "$1" != "-c" ] || [ "$2" != "%a" ]; then
    echo "fake stat: unexpected arguments" >&2
    exit 2
fi
exec /usr/bin/stat -f '%Lp' "$3"
EOF
chmod +x "$BINDIR/uname" "$BINDIR/stat"
{
    echo 'const std = @import("std");'
    echo 'pub fn build(b: *std.Build) !void {'
    write_canonical_block
    echo '}'
} > "$D/build.zig"
chmod 600 "$D/build.zig"
run_installer_with_bin "$BINDIR" "$D"
assert_rc 0
[ "$(stat -f '%Lp' "$D/build.zig")" = "600" ] || fail "build.zig mode not preserved (GNU arm)"
assert_empty "$D/err.log" 'stderr not empty'
pass "t30 splice preserves mode (F-12, GNU stat arm)"

# --- t31 (EPH-I0641, EPH-I1106): a comment that mentions the dependency
# call must not mislabel a fresh install as an upgrade, and must not
# misroute it into the non-standard-layout branch. The block lands the
# standard fresh-install way.
D="$TEST_ROOT/t31"
mkdir -p "$D"
cat > "$D/build.zig" <<'EOF'
const std = @import("std");
// The docs show b.dependency("ephor", .{}); the real line is gone.
pub fn build(b: *std.Build) !void {
    const exe = b.addExecutable(.{ .name = "demo", .root_module = b.createModule(.{}) });
    b.installArtifact(exe);
}
EOF
run_installer "$D"
assert_rc 0
assert_grep "$D/out.log" 'Installing ephor v0.99.1' 'fresh install labeled as upgrade'
assert_not_grep "$D/out.log" 'Upgrading' 'comment triggered the upgrade label'
assert_grep "$D/build.zig" '    // Ephor static analysis' 'block not added (layout branch taken)'
assert_empty "$D/err.log" 'stderr not empty'
pass "t31 comment mentioning the dependency stays Installing (F-17, EPH-I1106)"

# --- t32 (EPH-I0641): a real zon dependency entry must label the run
# as an upgrade even when build.zig no longer mentions the dependency.
D="$TEST_ROOT/t32"
mkdir -p "$D"
write_fresh_build_zig "$D"
cat > "$D/build.zig.zon" <<'EOF'
.{
    .name = .t32,
    .version = "0.0.0",
    .fingerprint = 0x1234dead,
    .dependencies = .{
        .ephor = .{
            .url = "https://codeberg.org/RhyosLabs/ephor/archive/v0.14.2.tar.gz",
            .hash = "ephor-0.14.2-p-Eoi3CRFQAKLECH5wnEI78GscKz2AUYXXf0qlr-sOfX",
        },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
EOF
run_installer "$D"
assert_rc 0
assert_grep "$D/out.log" 'Upgrading ephor v0.99.1' 'zon dependency not detected'
assert_empty "$D/err.log" 'stderr not empty'
pass "t32 zon dependency entry labels the run Upgrading (F-17)"

# --- t33 (EPH-I0637): the tags request asks for the API's per-page
# maximum, so the whole tag set arrives in one page (15 tags today).
# The file:// test channel ignores the query string, so this test pins
# the request URL the installer ships.
assert_grep "$INSTALL_SH" 'tags?limit=50' 'tags request does not ask for the full page'
pass "t33 tags request uses limit=50 (F-13)"

# --- t34 (EPH-I0637): a re-dated old tag at the top of the
# date-ordered response must never downgrade the install; the semver
# max wins across the whole window. Behavior pin: the parent already
# sorts the full file, so this test is green before the fix and guards
# the invariant the raised limit relies on.
D="$TEST_ROOT/t34"
mkdir -p "$D"
write_fresh_build_zig "$D"
printf '%s\n' '[{"name":"v0.13.0"},{"name":"v0.14.2"},{"name":"v0.99.1"}]' \
    > "$TEST_ROOT/tags-t34.json"
run_installer_with_tags "$TEST_ROOT/tags-t34.json" "$D"
assert_rc 0
assert_grep "$D/out.log" 'v0.99.1' 'semver max not chosen'
assert_not_grep "$D/out.log" 'v0.13.0' 're-dated old tag won'
assert_empty "$D/err.log" 'stderr not empty'
pass "t34 re-dated old tag loses to the semver max (F-13)"

# --- t35 (EPH-I0637): when every resolved tag sorts below the pinned
# fallback, the floor holds the install at the fallback tag. Behavior
# pin: green before the fix; it guards the floor F-13 names as the
# damage cap.
D="$TEST_ROOT/t35"
mkdir -p "$D"
write_fresh_build_zig "$D"
printf '%s\n' '[{"name":"v0.12.3"},{"name":"v0.12.4"}]' > "$TEST_ROOT/tags-t35.json"
run_installer_with_tags "$TEST_ROOT/tags-t35.json" "$D"
assert_rc 0
assert_grep "$D/out.log" 'v0.15.3' 'fallback floor not applied'
assert_grep "$D/err.log" 'below the fallback' 'no below-fallback warning'
pass "t35 below-fallback tags hold the floor (F-13)"

# --- t36 (EPH-I0640, EPH-I1107): the missing-build.zig error prints to
# stderr like every other error, and keeps STE prose. stdout stays
# empty: the refusal is the installer's first output.
D="$TEST_ROOT/t36"
mkdir -p "$D"
run_installer "$D"
assert_rc 1
assert_grep "$D/err.log" 'no build.zig found in the current directory' 'error missing from stderr'
assert_empty "$D/out.log" 'stdout not empty'
assert_not_grep "$INSTALL_SH" "we're" 'contraction remains in install.sh'
pass "t36 missing-build.zig prose is STE (F-16, EPH-I1107)"

# --- t37 (EPH-I0642): make_install_tmp refuses a second call while its
# single slot still holds a live temp, and still works on a free slot.
# The misuse path has no reachable trigger through the installer flow,
# so the test extracts the function and drives it directly.
sed -n '/^make_install_tmp() {/,/^}/p' "$INSTALL_SH" > "$TEST_ROOT/make-install-tmp.inc"
[ -s "$TEST_ROOT/make-install-tmp.inc" ] || fail "could not extract make_install_tmp from install.sh"
D="$TEST_ROOT/t37"
mkdir -p "$D"
rc=0
(INSTALL_TMP="live" && cd "$D" && . "$TEST_ROOT/make-install-tmp.inc" \
    && make_install_tmp ./x.XXXXXXXX) > "$D/out.log" 2> "$D/err.log" || rc=$?
assert_rc 1
assert_grep "$D/err.log" 'INSTALL_TMP already holds' 'no slot guard message'
[ -z "$(ls "$D"/x.* 2>/dev/null || true)" ] || fail "misuse arm created a temp file"
rc=0
(INSTALL_TMP="" && cd "$D" && . "$TEST_ROOT/make-install-tmp.inc" \
    && make_install_tmp ./y.XXXXXXXX) > "$D/out2.log" 2> "$D/err2.log" || rc=$?
assert_rc 0
[ -n "$(ls "$D"/y.* 2>/dev/null || true)" ] || fail "clean arm created no temp file"
pass "t37 INSTALL_TMP slot guard (F-18)"

# --- t38 (EPH-I0205): ambient URL overrides without EPHOR_TEST_MODE=1
# must be ignored with warnings. The install resolves through the real
# API URL, which the fake curl serves as a failure so the run stays
# hermetic, and takes the pinned fallback tag. With the embedded
# release key (WP-7) the verification then downloads the real archive
# URL through the same failing curl and stops: the install fails closed
# before any zig fetch, and the curl log proves both real URLs ran
# (the overrides stayed ignored).
D="$TEST_ROOT/t38"
BINDIR="$TEST_ROOT/t38-bin"
mkdir -p "$D" "$BINDIR"
cat > "$BINDIR/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CURL_ARGS_FILE"
cat "$CURL_BODY_FILE" 2>/dev/null
exit 1
EOF
chmod +x "$BINDIR/curl"
write_fresh_build_zig "$D"
CURL_ARGS_FILE="$D/curl-args"
CURL_BODY_FILE="$D/no-body"
export CURL_ARGS_FILE CURL_BODY_FILE
OLD_TEST_MODE=$EPHOR_TEST_MODE
unset EPHOR_TEST_MODE
run_installer_with_bin "$BINDIR" "$D"
export EPHOR_TEST_MODE="$OLD_TEST_MODE"
unset CURL_ARGS_FILE CURL_BODY_FILE
assert_rc 1
assert_grep "$D/err.log" 'EPHOR_TAGS_API is ignored without EPHOR_TEST_MODE=1' 'missing tags-override warning'
assert_grep "$D/err.log" 'EPHOR_ARCHIVE_URL is ignored without EPHOR_TEST_MODE=1' 'missing archive-override warning'
assert_grep "$D/out.log" 'v0.15.3' 'fallback tag not chosen'
assert_grep "$D/curl-args" 'codeberg.org/api/v1/repos/RhyosLabs/ephor/tags' 'override URL used without the marker'
assert_grep "$D/curl-args" 'codeberg.org/RhyosLabs/ephor/archive/v0.15.3.tar.gz' 'the verification did not use the real archive URL'
assert_grep "$D/err.log" 'could not download the release tarball for verification' 'no fail-closed download error'
assert_not_grep "$D/out.log" 'Done!' 'Done! printed after the fail-closed refusal'
pass "t38 ambient overrides ignored without EPHOR_TEST_MODE (F-19, WP-7 fail closed)"

# --- t39 (EPH-I1104): a degenerate numeric shape with an empty minor
# component ("0..2.") must take the warn-and-latest path like garbage
# text. The shape glob accepts an empty component, and cut then hands
# the integer test an empty operand, which dash reads as "Illegal
# number" and the old code read as "pin the 0.15-era release".
D="$TEST_ROOT/t39"
mkdir -p "$D"
write_fresh_build_zig "$D"
run_installer_with_zig "0..2." "$D"
assert_rc 0
assert_grep "$D/err.log" 'could not parse the zig version' 'missing parse warning'
assert_grep "$D/out.log" 'v0.99.1' 'did not take the latest-tag path'
cat "$D/out.log" "$D/err.log" > "$D/both.log"
assert_not_grep "$D/both.log" 'Illegal number' 'dash noise present'
assert_not_grep "$D/both.log" 'integer expression' 'bash noise present'
assert_not_grep "$D/out.log" 'v0.11.13' '0.15-era pin chosen on an empty component'
pass "t39 empty zig-version component takes latest tag (EPH-I1104)"

# --- t40 (EPH-I1106, positive control; EPH-I1110): a real dependency
# code line with no block markers must still take the non-standard
# layout branch, and the warning pair must land on stderr. The anchored
# probe must keep firing on real code, and the install must not touch
# build.zig in this branch.
D="$TEST_ROOT/t40"
mkdir -p "$D"
cat > "$D/build.zig" <<'EOF'
const std = @import("std");
pub fn build(b: *std.Build) !void {
    const ephor_dep = b.dependency("ephor", .{});
    const exe = b.addExecutable(.{ .name = "demo", .root_module = b.createModule(.{}) });
    b.installArtifact(exe);
}
EOF
cp "$D/build.zig" "$D/build.zig.orig"
run_installer "$D"
assert_rc 0
assert_grep "$D/err.log" 'non-standard layout' 'no layout warning on stderr'
assert_grep "$D/err.log" 'update your ephor build steps manually' 'no manual-update hint on stderr'
assert_not_grep "$D/out.log" 'non-standard layout' 'layout warning leaked to stdout'
assert_not_grep "$D/out.log" 'Adding ephor build steps' 'fresh branch taken for a real dependency'
assert_grep "$D/out.log" 'Done!' 'install did not complete'
assert_unchanged "$D/build.zig" "$D/build.zig.orig" 'build.zig'
pass "t40 real dependency line keeps the layout branch (EPH-I1106, EPH-I1110)"

# --- t41 (EPH-I1111): a build.zig symlink must be refused before any
# read, so the victim file's content never reaches the install and no
# file is created or replaced.
D="$TEST_ROOT/t41"
VICTIM="$TEST_ROOT/t41-victim"
mkdir -p "$D"
printf '%s\n' 'const victim_secret = 1;' > "$VICTIM"
ln -s "$VICTIM" "$D/build.zig"
run_installer "$D"
assert_rc 1
assert_grep "$D/err.log" 'build.zig is a symlink' 'no refusal error'
assert_not_grep "$D/out.log" 'Done!' 'Done! printed after the refusal'
[ -L "$D/build.zig" ] || fail "the installer replaced the symlink"
[ ! -e "$D/build.zig.zon" ] || fail "the zon was created despite the refusal"
assert_grep "$VICTIM" 'victim_secret' 'victim content lost'
pass "t41 build.zig symlink refuses before read (EPH-I1111)"

# --- t42 (EPH-I0717): a pre-existing zon with a real fingerprint takes
# the single-fetch path, and the no-installArtifact refusal still fails
# the install. This is the F6-audit proj-noart shape: the zon exists
# before the run, the fetch succeeds, and the missing installArtifact
# must still end the install nonzero.
D="$TEST_ROOT/t42"
mkdir -p "$D"
cat > "$D/build.zig" <<'EOF'
const std = @import("std");
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
}
EOF
cat > "$D/build.zig.zon" <<'EOF'
.{
    .name = .t42,
    .version = "0.0.0",
    .fingerprint = 0x1234dead,
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
EOF
run_installer "$D"
assert_rc 1
assert_grep "$D/err.log" 'build steps were not' 'no partial-install message'
assert_not_grep "$D/out.log" 'Done!' 'Done! printed after the refusal'
assert_grep "$D/build.zig.zon" '.fingerprint = 0x1234dead,' 'the existing fingerprint changed'
pass "t42 existing zon still fails the no-installArtifact install (EPH-I0717)"

# --- t43 (EPH-I0720): the README manual-install block stays identical
# to the canonical EPHOR_BUILD_BLOCK in src/main.zig. A user who copies
# the README block is then visible to every block-migration path. The
# extractions pin both surfaces as they ship: the README block spans
# its start and end markers, and the main.zig block spans the const
# lines with the Zig string-literal prefix stripped.
D="$TEST_ROOT/t43"
mkdir -p "$D"
sed -n '/^    \/\/ Ephor static analysis$/,/^    ephor_upgrade_step\.dependOn(&ephor_upgrade_cmd\.step);$/p' \
    "$REPO_ROOT/README.md" > "$D/readme-block.txt"
sed -n '/^const EPHOR_BUILD_BLOCK =$/,/^;$/p' "$REPO_ROOT/src/main.zig" \
    | sed '1d;$d' | sed 's/^    \\\\//' > "$D/main-block.txt"
[ -s "$D/readme-block.txt" ] || fail "could not extract the README block"
[ -s "$D/main-block.txt" ] || fail "could not extract EPHOR_BUILD_BLOCK from src/main.zig"
cmp -s "$D/readme-block.txt" "$D/main-block.txt" \
    || fail "the README manual block differs from EPHOR_BUILD_BLOCK"
pass "t43 README block matches EPHOR_BUILD_BLOCK (EPH-I0720)"

# --- t44 (EPH-I0284): a build.zig.zon symlink to a regular file must be
# refused before the fetch. zig fetch --save rewrites the zon through
# zig's own write path, which follows the link, so the refusal is the
# only installer-side closure. The victim file must keep its bytes and
# the link must survive the refusal.
D="$TEST_ROOT/t44"
VICTIM="$TEST_ROOT/t44-victim"
mkdir -p "$D"
write_fresh_build_zig "$D"
printf '%s\n' '.{ .name = .victim, .version = "1.2.3", .fingerprint = 0x0, .paths = .{} }' > "$VICTIM"
ln -s "$VICTIM" "$D/build.zig.zon"
run_installer "$D"
assert_rc 1
assert_grep "$D/err.log" 'build.zig.zon is a symlink' 'no refusal error'
assert_not_grep "$D/out.log" 'Done!' 'Done! printed after the refusal'
[ -L "$D/build.zig.zon" ] || fail "the installer replaced the zon symlink"
assert_grep "$VICTIM" '.name = .victim' 'victim zon content lost'
pass "t44 zon symlink to a file refuses before the fetch (EPH-I0284)"

# --- t45 (EPH-I0060): every consecutive blank line above the canonical
# block converges to exactly one on re-run. The pre-fix single-step
# absorb left an N>=2 run at N-1+1 = N forever; the loop must heal the
# damaged state to the canonical single blank after two runs.
D="$TEST_ROOT/t45"
mkdir -p "$D"
{
    echo 'const std = @import("std");'
    echo 'pub fn build(b: *std.Build) !void {'
    echo '    const target = b.standardTargetOptions(.{});'
    echo '    const optimize = b.standardOptimizeOption(.{});'
    echo ''
    echo ''
    echo ''
    write_canonical_block
    echo '}'
} > "$D/build.zig"
run_installer "$D"
assert_rc 0
# One blank line separates the block from the code above it after the
# first run (three blanks absorbed, one re-added).
BLOCK_LINE=$(line_of "$D/build.zig" '    // Ephor static analysis')
ABOVE_BLANKS=0
L=$((BLOCK_LINE - 1))
while [ "$L" -ge 1 ] && [ -z "$(sed -n "${L}p" "$D/build.zig")" ]; do
    ABOVE_BLANKS=$((ABOVE_BLANKS + 1))
    L=$((L - 1))
done
assert_eq 1 "$ABOVE_BLANKS" 'blank run above the block is not the canonical one'
run_installer "$D"
assert_rc 0
BLOCK_LINE=$(line_of "$D/build.zig" '    // Ephor static analysis')
ABOVE_BLANKS=0
L=$((BLOCK_LINE - 1))
while [ "$L" -ge 1 ] && [ -z "$(sed -n "${L}p" "$D/build.zig")" ]; do
    ABOVE_BLANKS=$((ABOVE_BLANKS + 1))
    L=$((L - 1))
done
assert_eq 1 "$ABOVE_BLANKS" 'second run did not stay at the canonical single blank'
pass "t45 blank run above the block converges on re-run (EPH-I0060)"

# --- t46 (EPH-I1159): a truncated canonical block whose start marker
# (and dependency const line) the user deleted, but whose end lines
# remain, must refuse instead of splicing a fresh block and
# redeclaring the retained lines. The end-marker-only shape matches
# neither start-marker branch pre-fix, so the old code fell through to
# the fresh-install splice and left ephor_upgrade_cmd and
# ephor_upgrade_step declared twice. The canonical branch now fires on
# the end marker alone, and the empty start line makes the marker-pair
# validation refuse.
D="$TEST_ROOT/t46"
mkdir -p "$D"
{
    echo 'const std = @import("std");'
    echo 'pub fn build(b: *std.Build) !void {'
    echo '    const target = b.standardTargetOptions(.{});'
    echo '    const optimize = b.standardOptimizeOption(.{});'
    echo '    const exe = b.addExecutable(.{ .name = "demo", .root_module = b.createModule(.{}) });'
    echo '    b.installArtifact(exe);'
    echo '    const ephor_upgrade_cmd = b.addRunArtifact(ephor_artifact);'
    echo '    ephor_upgrade_cmd.addArgs(&.{"upgrade"});'
    echo '    const ephor_upgrade_step = b.step("ephor-upgrade", "Upgrade ephor to latest version");'
    echo '    ephor_upgrade_step.dependOn(&ephor_upgrade_cmd.step);'
    echo '}'
} > "$D/build.zig"
cp "$D/build.zig" "$D/build.zig.orig"
run_installer "$D"
assert_rc 1
assert_grep "$D/err.log" 'missing one of its markers' 'no refusal warning'
assert_not_grep "$D/out.log" 'Adding ephor build steps' 'fresh branch taken for an end-marker-only file'
assert_unchanged "$D/build.zig" "$D/build.zig.orig" 'build.zig'
pass "t46 end-marker-only canonical block refuses (EPH-I1159)"

# --- t47 (EPH-I1159): the same truncated shape on the legacy snippet:
# the start marker and dependency line deleted, the v0.11.x end line
# remains. Pre-fix this fell through to the fresh-install splice and
# left the retained ephor_step.dependOn(...) line beside the new
# canonical block, where ephor_exe is undeclared - a broken file. The
# legacy branch now fires on the end marker alone and refuses.
D="$TEST_ROOT/t47"
mkdir -p "$D"
{
    echo 'const std = @import("std");'
    echo 'pub fn build(b: *std.Build) !void {'
    echo '    const target = b.standardTargetOptions(.{});'
    echo '    const optimize = b.standardOptimizeOption(.{});'
    echo '    const exe = b.addExecutable(.{ .name = "demo", .root_module = b.createModule(.{}) });'
    echo '    b.installArtifact(exe);'
    echo '    ephor_step.dependOn(&b.addRunArtifact(ephor_exe).step);'
    echo '}'
} > "$D/build.zig"
cp "$D/build.zig" "$D/build.zig.orig"
run_installer "$D"
assert_rc 1
assert_grep "$D/err.log" 'missing one of its markers' 'no refusal warning'
assert_not_grep "$D/out.log" 'Adding ephor build steps' 'fresh branch taken for an end-marker-only file'
assert_unchanged "$D/build.zig" "$D/build.zig.orig" 'build.zig'
pass "t47 end-marker-only legacy snippet refuses (EPH-I1159)"

# --- t48 (EPH-I0715): the anchor scan is quote- and comment-aware. A
# real call followed by three mention shapes must still land the block
# after the real call: a full-line comment mention, a string-literal
# mention on the multiline-string opener, and a `\\`-body continuation
# line that ends in a semicolon. Pre-fix the grep picked the opener
# line, the semicolon scan landed on the `\\ one;` body line, and the
# block spliced into the middle of the string. The ast-check gate also
# runs here (the fake zig answers rc 0), so the assertions below are
# the corruption detection.
D="$TEST_ROOT/t48"
mkdir -p "$D"
cat > "$D/build.zig" <<'EOF'
const std = @import("std");
pub fn build(b: *std.Build) !void {
    const exe = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{}),
    });
    b.installArtifact(exe);
    // installArtifact mention in a full-line comment below the call.
    const usage = "installArtifact docs" ++
        \\
        \\ one;
        \\ two
    ;
    _ = usage;
}
EOF
run_installer "$D"
assert_rc 0
assert_empty "$D/err.log" 'stderr not empty'
install_line=$(line_of "$D/build.zig" 'b.installArtifact(exe)')
marker_line=$(line_of "$D/build.zig" '    // Ephor static analysis')
[ "$marker_line" -eq "$((install_line + 2))" ] \
    || fail "block did not land right after the real call (install $install_line, marker $marker_line)"
[ "$(count_of "$D/build.zig" '// Ephor static analysis')" -eq 1 ] \
    || fail "block count wrong"
body_line=$(line_of "$D/build.zig" '\\ one;')
[ "$body_line" -gt "$marker_line" ] \
    || fail "string body sits above the block (body $body_line, marker $marker_line)"
[ "$(count_of "$D/build.zig" '\\ one;')" -eq 1 ] \
    || fail "multiline string body did not survive intact"
[ "$(count_of "$D/build.zig" 'installArtifact docs')" -eq 1 ] \
    || fail "string-literal mention changed"
[ "$(count_of "$D/build.zig" 'full-line comment below the call')" -eq 1 ] \
    || fail "comment mention changed"
pass "t48 quote/comment-aware anchor skips mentions (EPH-I0715)"

# --- t49 (EPH-I1274): a directory name that carries an ESC byte must
# render sanitized in every echo. The warning arm fires exactly when the
# name carries non-identifier bytes, which admits ESC, so the raw name
# must never reach the terminal. The zon name sanitization is unchanged:
# the ESC becomes an underscore there, while the echoed name shows a '?'.
D="$TEST_ROOT/$(printf 'my\033proj')"
mkdir -p "$D"
write_fresh_build_zig "$D"
run_installer "$D"
assert_rc 0
assert_grep "$D/build.zig.zon" '.name = .my_proj,' 'zon name not sanitized'
assert_grep "$D/err.log" "warning: 'my?proj' is not a valid Zig identifier" \
    'warning does not carry the sanitized name'
assert_grep "$D/out.log" "Created build.zig.zon for project 'my?proj'" \
    'created line does not carry the sanitized name'
assert_not_grep "$D/err.log" "$(printf '\033')" 'raw ESC in the stderr output'
assert_not_grep "$D/out.log" "$(printf '\033')" 'raw ESC in the stdout output'
pass "t49 ESC-bearing dir name renders sanitized (EPH-I1274)"

# --- t50 (EPH-I1272): the fingerprint repair targets the code-position
# field. The one-line zon carries a string value that mentions the
# ".fingerprint = 0x0" marker before the real inline field. The pre-fix
# sed rewrote the first match per line (the string mention), corrupted
# the string, and left the real field at 0x0, so the authoritative fetch
# failed. The repair must skip the mention and patch the real field.
D="$TEST_ROOT/t50"
mkdir -p "$D"
write_fresh_build_zig "$D"
ZON_LINE='.{ .name = ".fingerprint = 0x0 mention", .version = "0.0.0",'
ZON_LINE="${ZON_LINE} .fingerprint = 0x0, .paths = .{} }"
printf '%s\n' "$ZON_LINE" > "$D/build.zig.zon"
printf 'error: unable to verify package\nuse this value: 0x1234dead\n' \
    > "$TEST_ROOT/fail-hint-t50.txt"
run_installer_with_fetch_fail "$TEST_ROOT/fail-hint-t50.txt" "$D"
assert_rc 0
assert_grep "$D/build.zig.zon" '.fingerprint = 0x1234dead' 'code-position field not repaired'
assert_grep "$D/build.zig.zon" '".fingerprint = 0x0 mention"' 'string mention corrupted'
assert_empty "$D/err.log" 'stderr not empty'
pass "t50 fingerprint repair targets the code-position field (EPH-I1272)"

# --- t51 (EPH-I1272, EPH-I1291): a zon whose ".fingerprint = 0x0" text
# exists only inside a string value has no real field, so zig 0.16.0
# answers "missing top-level 'fingerprint' field; suggested value:
# 0x<hex>". The repair must leave the string alone and add the real
# field after the root struct opener. The pre-fix sed rewrote the string
# mention and leaked the hint into the zon; the I1272-only fix refused
# the repair entirely and the live WP-7 leg then failed at EXIT=2.
D="$TEST_ROOT/t51"
mkdir -p "$D"
write_fresh_build_zig "$D"
printf '%s\n' \
    '.{ .name = ".fingerprint = 0x0 only mention", .version = "0.0.0", .paths = .{} }' \
    > "$D/build.zig.zon"
printf "build.zig.zon:1:2: error: missing top-level 'fingerprint' field; suggested value: 0x1234dead\n" \
    > "$TEST_ROOT/fail-hint-t51.txt"
run_installer_with_fetch_fail "$TEST_ROOT/fail-hint-t51.txt" "$D"
assert_rc 0
assert_grep "$D/build.zig.zon" '.fingerprint = 0x1234dead' 'the missing field was not added'
assert_grep "$D/build.zig.zon" '".fingerprint = 0x0 only mention"' 'string mention corrupted'
assert_empty "$D/err.log" 'stderr not empty'
pass "t51 string-only mention gains the real field (EPH-I1291)"

# --- t52 (EPH-I1283): a mid-line \\ opener consumes the rest of the
# line as string data (Zig-side EPH-I0671 parity), so a decoy mention
# inside the tail must stay intact and the real field on the next line
# must repair. The pre-fix walk read the tail as code: the decoy won
# the repair, the string corrupted, and the real field stayed 0x0, so
# the authoritative fetch failed.
D="$TEST_ROOT/t52"
mkdir -p "$D"
write_fresh_build_zig "$D"
cat > "$D/build.zig.zon" <<'EOF'
.{
    .name = .fpml,
    .version = "0.0.0",
    .paths = .{ \\ .fingerprint = 0x0 decoy, "build.zig" },
    .fingerprint = 0x0,
}
EOF
printf 'error: unable to verify package\nuse this value: 0x1234dead\n' \
    > "$TEST_ROOT/fail-hint-t52.txt"
run_installer_with_fetch_fail "$TEST_ROOT/fail-hint-t52.txt" "$D"
assert_rc 0
assert_grep "$D/build.zig.zon" '.fingerprint = 0x1234dead,' 'code-position field not repaired'
assert_grep "$D/build.zig.zon" '\\ .fingerprint = 0x0 decoy' 'multiline tail mention corrupted'
assert_empty "$D/err.log" 'stderr not empty'
pass "t52 fingerprint repair cuts on the mid-line multiline opener (EPH-I1283)"

# --- t55 (EPH-I1291): a pre-existing zon without a fingerprint field
# (the shape a fresh hand-made project carries) gains the field from the
# real zig 0.16.0 "suggested value" hint. The WP-7 live leg hit exactly
# this shape: the pre-fix grep keyed only on "use this value", so the
# hint never parsed and the install died at EXIT=2 after the verified
# signature. The added field must sit inside the root struct.
D="$TEST_ROOT/t55"
mkdir -p "$D"
write_fresh_build_zig "$D"
cat > "$D/build.zig.zon" <<'EOF'
.{
    .name = .t55,
    .version = "0.0.0",
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
EOF
printf "build.zig.zon:1:2: error: missing top-level 'fingerprint' field; suggested value: 0x1234dead\n" \
    > "$TEST_ROOT/fail-hint-t55.txt"
run_installer_with_fetch_fail "$TEST_ROOT/fail-hint-t55.txt" "$D"
assert_rc 0
assert_grep "$D/build.zig.zon" '.fingerprint = 0x1234dead,' 'missing field not added'
assert_grep "$D/build.zig.zon" '.name = .t55,' 'the name field moved'
assert_empty "$D/err.log" 'stderr not empty'
pass "t55 missing fingerprint field gains the hinted field (EPH-I1291)"

# --- t53a (WP-7): install.sh embeds the exact two-line .pub wire form
# the release key mint produced. Both lines ship: minisign 0.12 rejects
# a file whose key line is the first line, so the comment line is part
# of the shape.
sed -n '/^RELEASE_PUBKEY=/,/^RWS+/p' "$INSTALL_SH" > "$TEST_ROOT/pubkey-extract.txt"
[ -s "$TEST_ROOT/pubkey-extract.txt" ] || fail "could not extract RELEASE_PUBKEY from install.sh"
cat > "$TEST_ROOT/pubkey-want.txt" <<'EOF'
RELEASE_PUBKEY='untrusted comment: minisign public key BD29FC2E33D53EBE
RWS+PtUzLvwpvc7nVJ8t8MKTpo4/8UdOqoxuLGXhfJQI+qvTyn82Dfit'
EOF
cmp -s "$TEST_ROOT/pubkey-extract.txt" "$TEST_ROOT/pubkey-want.txt" \
    || fail "install.sh RELEASE_PUBKEY differs from the minted release key"
pass "t53a install.sh embeds the minted release key (WP-7)"

# --- t53b (EPH-I0205, WP-7): the EPHOR_RELEASE_PUBKEY override replaces
# the embedded key when EPHOR_TEST_MODE is set. The fake minisign
# records the key it received, and the record must carry the fixture,
# not the embedded release key.
D="$TEST_ROOT/t53b"
mkdir -p "$D"
write_fresh_build_zig "$D"
rc=0
(EPHOR_RELEASE_PUBKEY="untrusted comment: seam fixture
RWTESTKEYSEAMPLACEHOLDER"
    export EPHOR_RELEASE_PUBKEY
    cd "$D" && "$INSTALL_RUNNER" "$INSTALL_SH") \
    > "$D/out.log" 2> "$D/err.log" || rc=$?
assert_rc 0
assert_grep "$D/out.log" 'Release signature verified.' 'no verification line'
assert_grep "$D/.minisign-pubkey" 'RWTESTKEYSEAMPLACEHOLDER' 'the override key did not reach minisign'
assert_not_grep "$D/.minisign-pubkey" 'RWS+PtUzLvwpvc7nVJ8t8MKTpo4/8UdOqoxuLGXhfJQI+qvTyn82Dfit' \
    'the embedded key leaked into the override run'
assert_empty "$D/err.log" 'stderr not empty'
pass "t53b EPHOR_RELEASE_PUBKEY replaces the embedded key (WP-7 seam)"

# --- t54 (WP-7): the derived signature URL is the repo-tree raw route.
# A tag release's signature lives at signatures/<tag>.tar.gz.minisig in
# the repo tree (committed by the post-tag commit, served via the raw
# route), not next to the archive tarball: the archive route 404s. A run
# without EPHOR_SIG_URL must fetch the raw-branch URL, so the fake curl
# records every call and serves the fixtures to keep the run hermetic.
D="$TEST_ROOT/t54"
BINDIR="$TEST_ROOT/t54-bin"
mkdir -p "$D" "$BINDIR"
cat > "$BINDIR/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CURL_ARGS_FILE"
out=""
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift; out="$1" ;;
        -*) ;;
        *) url="$1" ;;
    esac
    shift
done
case "$url" in
    *.tar.gz.minisig) body="$SIG_FIXTURE" ;;
    *.tar.gz) body="$ARCHIVE_FIXTURE" ;;
    *tags.json) body="$TAGS_FIXTURE" ;;
    *) exit 1 ;;
esac
if [ -n "$out" ]; then
    cat "$body" > "$out"
else
    cat "$body"
fi
exit 0
EOF
chmod +x "$BINDIR/curl"
write_fresh_build_zig "$D"
CURL_ARGS_FILE="$D/curl-args"
SIG_FIXTURE="$TEST_ROOT/archive.tar.gz.minisig"
ARCHIVE_FIXTURE="$TEST_ROOT/archive.tar.gz"
TAGS_FIXTURE="$TEST_ROOT/tags.json"
export CURL_ARGS_FILE SIG_FIXTURE ARCHIVE_FIXTURE TAGS_FIXTURE
OLD_SIG_URL=$EPHOR_SIG_URL
unset EPHOR_SIG_URL
run_installer_with_bin "$BINDIR" "$D"
export EPHOR_SIG_URL="$OLD_SIG_URL"
unset CURL_ARGS_FILE SIG_FIXTURE ARCHIVE_FIXTURE TAGS_FIXTURE
assert_rc 0
assert_grep "$D/curl-args" \
    'codeberg.org/RhyosLabs/ephor/raw/branch/main/signatures/v0.99.1.tar.gz.minisig' \
    'the derived signature URL is not the repo-tree raw route'
assert_grep "$D/out.log" 'Release signature verified.' 'no verification line'
pass "t54 derived signature URL is the raw-branch signatures path (WP-7)"

echo ""
echo "install-sh tests: $PASS_COUNT passed"
