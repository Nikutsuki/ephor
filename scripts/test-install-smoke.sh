#!/bin/sh
# Hermetic real-zig smoke for install.sh (EPH-I0282). This commits the
# verification that ran ad-hoc for EPH-I0192/93/94: the real installer
# runs against the real zig, with a local package tarball served over
# localhost HTTP and a private ZIG_GLOBAL_CACHE_DIR. The scenarios pin
# the behaviors the fake-zig suite cannot reach.
#
# Asserts (EPH-I0282 done-when):
#   - no zig build spawn (a logging zig wrapper records every invocation)
#   - fingerprint self-heal (a real 0x0 fingerprint is repaired from the
#     hint the real zig fetch prints)
#   - symlink safety (planted build.zig and build.zig.zon symlinks are
#     refused before any read)
#   - 0644 modes (fresh files carry the umask-022 default)
#   - idempotent re-run (a second run converges with no file growth)
#   - failure rc propagation (no installArtifact fails the install)
#   - release-signature verification (WP-7: a fixture keypair signs the
#     served tarball, EPHOR_SIG_URL serves the signature locally, and
#     EPHOR_RELEASE_PUBKEY drives the active check through the real
#     minisign before the fetch)
# Wired into scripts/gate.sh (EPH-I1292): the real-zig legs here — the
# fingerprint self-heal and the no-build-spawn pin — are the behaviors
# the fake-zig suites cannot reach, and they broke silently while the
# suite sat unwired.
#
# Run:
#   sh scripts/test-install-smoke.sh
#   DEBUG=1 ...                        (keep the scratch tree)

set -eu

REPO_ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
INSTALL_SH="$REPO_ROOT/install.sh"
SMOKE_ROOT="$REPO_ROOT/.tmp/install-smoke"
if [ "${DEBUG:-0}" = "1" ]; then
    KEEP=1
else
    KEEP=0
fi

ZIG_BIN=$(command -v zig) || true
if [ -z "$ZIG_BIN" ]; then
    echo "error: zig is not installed or not on PATH." >&2
    echo "The smoke runs the real installer against the real zig." >&2
    exit 1
fi
case "$ZIG_BIN" in
    /*) ;;
    *) ZIG_BIN=$(pwd)/$ZIG_BIN ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 is not installed or not on PATH." >&2
    echo "The smoke serves the local package tarball with python3's http server." >&2
    exit 1
fi

# WP-7: the embedded release key activates the verification, so the
# smoke verifies the served tarball with the real minisign against a
# fixture keypair minted fresh per run (the e2e suite's pattern).
if ! command -v curl >/dev/null 2>&1 || ! command -v minisign >/dev/null 2>&1; then
    echo "error: curl and minisign are required for the release-signature verification." >&2
    exit 1
fi

rm -rf "$SMOKE_ROOT"
mkdir -p "$SMOKE_ROOT/bin" "$SMOKE_ROOT/cache"

SERVER_PID=""
trap 'if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true
      wait "$SERVER_PID" 2>/dev/null || true; fi
      if [ "$KEEP" -eq 0 ]; then rm -rf "$SMOKE_ROOT"; fi' EXIT

# The package tarball: a minimal ephor stand-in that real zig can fetch.
# The .fingerprint is the value zig 0.16.0 computes for this exact
# manifest (name, version, and paths), printed by zig itself as the
# "use this value" hint. The package content is fixed, so the value is
# stable; a future zig that recomputes it fails this smoke loudly.
PKG="$SMOKE_ROOT/pkg"
mkdir -p "$PKG"
cat > "$PKG/build.zig.zon" <<'EOF'
.{
    .name = .smoke_ephor,
    .version = "0.0.0",
    .fingerprint = 0x221484678669c3c1,
    .paths = .{ "build.zig", "build.zig.zon" },
}
EOF
cat > "$PKG/build.zig" <<'EOF'
const std = @import("std");
pub fn build(b: *std.Build) void {
    _ = b;
}
EOF
tar -czf "$SMOKE_ROOT/ephor.tar.gz" -C "$PKG" build.zig build.zig.zon

# WP-7: sign the package tarball with a fresh fixture keypair and serve
# the signature next to it. The installer's default SIG_URL points at
# the real remote (raw/branch/main/signatures/<tag>.tar.gz.minisig), so
# the exports below override it with EPHOR_SIG_URL (the e2e suite's
# pattern), and EPHOR_RELEASE_PUBKEY replaces the embedded key for the
# hermetic run (the fixture-key seam, EPH-I0205).
minisign -G -W -p "$SMOKE_ROOT/test.pub" -s "$SMOKE_ROOT/test.key" < /dev/null >/dev/null 2>&1 || {
    echo "error: minisign key generation failed." >&2
    exit 1
}
minisign -S -m "$SMOKE_ROOT/ephor.tar.gz" -s "$SMOKE_ROOT/test.key" \
    -t "install smoke" -x "$SMOKE_ROOT/ephor.tar.gz.minisig" < /dev/null 2>/dev/null || {
    echo "error: signing the smoke tarball failed." >&2
    exit 1
}
SMOKE_PUBKEY=$(cat "$SMOKE_ROOT/test.pub")

# The local HTTP server binds an ephemeral port and prints it, so no
# fixed port can collide with another process.
cat > "$SMOKE_ROOT/serve.py" <<'EOF'
import http.server
import socketserver
import sys

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(("127.0.0.1", 0), QuietHandler) as httpd:
    sys.stdout.write(str(httpd.server_address[1]) + "\n")
    sys.stdout.flush()
    httpd.serve_forever()
EOF
(cd "$SMOKE_ROOT" && exec python3 serve.py) > "$SMOKE_ROOT/port.txt" &
SERVER_PID=$!
i=0
while [ ! -s "$SMOKE_ROOT/port.txt" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
done
if [ ! -s "$SMOKE_ROOT/port.txt" ]; then
    echo "error: the local HTTP server did not start." >&2
    exit 1
fi
PORT=$(cat "$SMOKE_ROOT/port.txt")

# The logging zig wrapper records every installer zig invocation and
# forwards to the real binary. The no-build assertions below grep the
# log for a build spawn.
cat > "$SMOKE_ROOT/bin/zig" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$SMOKE_ZIG_LOG"
exec "$ZIG_BIN" "$@"
EOF
chmod +x "$SMOKE_ROOT/bin/zig"

printf '%s\n' '[{"name":"v0.99.1"}]' > "$SMOKE_ROOT/tags.json"

SMOKE_ZIG_LOG="$SMOKE_ROOT/zig-calls.log"
export SMOKE_ZIG_LOG
export ZIG_BIN
export EPHOR_TEST_MODE=1
export EPHOR_TAGS_API="file://$SMOKE_ROOT/tags.json"
export EPHOR_ARCHIVE_URL="http://127.0.0.1:$PORT/ephor.tar.gz"
export EPHOR_SIG_URL="http://127.0.0.1:$PORT/ephor.tar.gz.minisig"
export EPHOR_RELEASE_PUBKEY="$SMOKE_PUBKEY"
export ZIG_GLOBAL_CACHE_DIR="$SMOKE_ROOT/cache"
OLD_PATH=$PATH
PATH="$SMOKE_ROOT/bin:$PATH"
export PATH

PASS_COUNT=0
pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "PASS $1"
}
fail() {
    echo "FAIL $1" >&2
    echo "Scratch kept at: $SMOKE_ROOT" >&2
    exit 1
}

# Run the installer with the project dir as the working directory under
# a fixed umask 022, so the mode assertions see the documented default.
# Leaves stdout in $1/out.log, stderr in $1/err.log, exit code in $rc.
run_installer() {
    rc=0
    (umask 022 && cd "$1" && sh "$INSTALL_SH") > "$1/out.log" 2> "$1/err.log" || rc=$?
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
count_of() { # file, pattern -> count on stdout
    grep -cF "$2" "$1" | cat
}
line_of() { # file, pattern -> line number on stdout
    grep -nF "$2" "$1" | head -1 | cut -d: -f1
}
assert_mode() { # file, want
    case "$(uname -s)" in
        Darwin|FreeBSD|OpenBSD|NetBSD) M=$(stat -f '%Lp' "$1") ;;
        *) M=$(stat -c '%a' "$1") ;;
    esac
    [ "$M" = "$2" ] || fail "wrong mode on $1 (want $2, got $M)"
}
assert_no_build_spawn() {
    if grep -qE '^build($| )' "$SMOKE_ZIG_LOG"; then
        fail "the installer spawned zig build"
    fi
}

# --- s01 fresh install: the full happy path with real fetch. The 0x0
# fingerprint forces the heal, so the zon must carry a real fingerprint
# and a dependency entry, the log must show exactly two fetches, the
# block must land after installArtifact, the modes must be 0644, and a
# second run must converge with no growth and no second block.
D="$SMOKE_ROOT/s01"
mkdir -p "$D"
cat > "$D/build.zig" <<'EOF'
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
: > "$SMOKE_ZIG_LOG"
run_installer "$D"
assert_rc 0
assert_grep "$D/out.log" 'Done!' 'no Done! summary'
assert_grep "$D/out.log" 'Release signature verified.' 'no verification line'
assert_grep "$D/build.zig" '    // Ephor static analysis' 'block not added'
install_line=$(line_of "$D/build.zig" 'b.installArtifact(exe)')
marker_line=$(line_of "$D/build.zig" '    // Ephor static analysis')
[ "$marker_line" -gt "$install_line" ] \
    || fail "block landed before the statement (install $install_line, marker $marker_line)"
assert_eq 2 "$(count_of "$SMOKE_ZIG_LOG" 'fetch --save=ephor')" \
    'the self-heal did not run two fetches'
assert_no_build_spawn
assert_grep "$D/build.zig.zon" '.ephor = .{' 'the zon has no dependency entry'
assert_not_grep "$D/build.zig.zon" '.fingerprint = 0x0,' 'the fingerprint was not healed'
if ! grep -qE '\.fingerprint = 0x[0-9a-f]+,' "$D/build.zig.zon"; then
    fail "the healed fingerprint is not a hex value"
fi
assert_mode "$D/build.zig" 644
assert_mode "$D/build.zig.zon" 644
lines_before=$(wc -l < "$D/build.zig" | tr -d ' ')
run_installer "$D"
assert_rc 0
assert_grep "$D/out.log" 'Updated ephor build steps' 'the re-run did not take the replace branch'
assert_eq 1 "$(count_of "$D/build.zig" '    // Ephor static analysis')" \
    'the re-run duplicated the block'
lines_after=$(wc -l < "$D/build.zig" | tr -d ' ')
assert_eq "$lines_before" "$lines_after" 'the re-run grew build.zig'
pass "s01 fresh install: fetch, self-heal, modes, idempotent re-run, no zig build"

# --- s02 failure rc propagation: no installArtifact means the build
# steps cannot land. The dependency still landed through the real
# fetch, and the install must end nonzero with no Done! summary.
D="$SMOKE_ROOT/s02"
mkdir -p "$D"
cat > "$D/build.zig" <<'EOF'
const std = @import("std");
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
}
EOF
: > "$SMOKE_ZIG_LOG"
run_installer "$D"
assert_rc 1
assert_grep "$D/err.log" 'build steps were not' 'no partial-install message'
assert_not_grep "$D/out.log" 'Done!' 'Done! printed after the refusal'
assert_grep "$D/build.zig.zon" '.ephor = .{' 'the dependency did not land'
assert_no_build_spawn
pass "s02 failure rc propagation with real fetch"

# --- s03 symlink safety: planted symlinks at build.zig.zon and
# build.zig are refused before any read, with nothing written through
# them and no victim content lost.
D="$SMOKE_ROOT/s03"
OUTSIDE="$SMOKE_ROOT/s03-outside"
mkdir -p "$D" "$OUTSIDE"
cat > "$D/build.zig" <<'EOF'
const std = @import("std");
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{ .name = "demo", .root_module = b.createModule(.{}) });
    b.installArtifact(exe);
}
EOF
ln -s "$OUTSIDE" "$D/build.zig.zon"
run_installer "$D"
assert_rc 1
assert_grep "$D/err.log" 'build.zig.zon is a directory' 'no zon-symlink refusal'
[ -z "$(ls -A "$OUTSIDE" 2>/dev/null || true)" ] \
    || fail "a file landed inside the symlink target"

D2="$SMOKE_ROOT/s03b"
VICTIM="$SMOKE_ROOT/s03b-victim"
mkdir -p "$D2"
printf '%s\n' 'const victim_secret = 1;' > "$VICTIM"
ln -s "$VICTIM" "$D2/build.zig"
run_installer "$D2"
assert_rc 1
assert_grep "$D2/err.log" 'build.zig is a symlink' 'no build.zig-symlink refusal'
[ -L "$D2/build.zig" ] || fail "the installer replaced the symlink"
assert_grep "$VICTIM" 'victim_secret' 'victim content lost'
pass "s03 symlink refusals"

PATH=$OLD_PATH
export PATH
echo ""
echo "install smoke: $PASS_COUNT passed"
