#!/bin/sh
# Regression suite for install.sh (batch B65: EPH-I0625 through EPH-I0630).
# Runs the real installer against planted fixtures in scratch dirs under
# .tmp/install-sh-tests. Hermetic: the fake zig on PATH answers version
# and fetch, and the tags API is a local file, so no network is touched.
# The text assertions pin the fixed behavior. Zon parseability for the
# fallback names was verified with real zig 0.16.0 during development
# (see the batch report), so this suite stays fast and shell-only.
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
# every fetch without network.
cat > "$TEST_ROOT/bin/zig" <<'EOF'
#!/bin/sh
if [ "$1" = "version" ]; then
    printf '%s\n' "$FAKE_ZIG_VERSION"
    exit 0
fi
exit 0
EOF
chmod +x "$TEST_ROOT/bin/zig"

printf '%s\n' '[{"name":"v0.99.1"}]' > "$TEST_ROOT/tags.json"

PATH="$TEST_ROOT/bin:$PATH"
export PATH
export EPHOR_TAGS_API="file://$TEST_ROOT/tags.json"
export EPHOR_ARCHIVE_URL="file://$TEST_ROOT/archive.tar.gz"
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
    [ ! -s "$1" ] || fail "$3 (expected empty, got $(wc -c < "$1" | tr -d ' ') bytes)"
}
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
FAKE_ZIG_VERSION="abc" run_installer "$D"
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
FAKE_ZIG_VERSION="0.16.0" run_installer "$D"
assert_rc 0
assert_grep "$D/out.log" 'v0.99.1' 'latest tag not chosen'
assert_empty "$D/err.log" 'stderr not empty'
pass "t14 zig 0.16.0 takes latest tag (F-6 positive)"

# --- t15 (EPH-I0630, positive): a Zig 0.15 version keeps the pin path.
D="$TEST_ROOT/t15"
mkdir -p "$D"
write_fresh_build_zig "$D"
FAKE_ZIG_VERSION="0.15.0" run_installer "$D"
assert_rc 0
assert_grep "$D/out.log" 'v0.11.13' '0.15 pin not chosen'
assert_not_grep "$D/out.log" 'v0.99.1' 'latest tag chosen for 0.15'
assert_empty "$D/err.log" 'stderr not empty'
pass "t15 zig 0.15.0 keeps the pin (F-6 positive)"

# --- t16 (EPH-I0626, positive): a fresh install with a one-line
# installArtifact statement inserts the block after that line.
D="$TEST_ROOT/t16"
mkdir -p "$D"
write_fresh_build_zig "$D"
run_installer "$D"
assert_rc 0
assert_grep "$D/out.log" 'Done!' 'no Done! summary'
assert_empty "$D/err.log" 'stderr not empty'
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

echo ""
echo "install-sh tests: $PASS_COUNT passed"
