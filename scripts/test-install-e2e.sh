#!/bin/sh
# End-to-end tests for the install.sh release-signature verification
# (EPH-I0287) and the bounded-download policy (EPH-I1216).
# Run from anywhere: sh scripts/test-install-e2e.sh
# Wired into scripts/gate.sh (EPH-I0287). Run it directly after changing
# verify_ephor_release, fetch_bounded, or the EPHOR_TEST_MODE override
# gates in install.sh. The suite drives the real install.sh through the
# verification states against local HTTP redirect servers, mints a fresh
# test minisign keypair per run (-W: no password), and includes the
# file:// byte-cap scenario. WP-7: the embedded release key makes the
# check active by default, so the no-override scenario pins the
# fail-closed outcome against the embedded key (s1), and s7 pins the
# override-ignored warnings with the key-id-mismatch exclusion that
# holds whether or not the latest release is signed (EPH-I1289).
# install.ps1 has no companion leg in this suite: its verification states
# live in the ps1 anchor and hardening suites (test-install-ps1-*.ps1),
# which gate through scripts/gate.sh. The bounded-read arm pin
# (EPH-I0207) lives in the ps1 anchor suite's pubkey-channel runs —
# the recorded limitation (EPH-I1194) covers the manual residue.
#
# Needs: sh, curl, minisign, openssl, python3, and the pinned zig on
# PATH (or in .zenv/bin). A missing tool aborts with a FATAL line.
#
# set -u only: the cases assert on nonzero install exits, so set -e
# would abort the runner on the first expected failure.
set -u

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
E2E="$ROOT/.tmp/test-install-e2e"
rm -rf "$E2E"
mkdir -p "$E2E/cache" "$E2E/proj"
FAILS=0
TESTS=0

# --- tool checks (before any scenario work) --------------------------------
for tool in curl minisign; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "FATAL: $tool is not installed or not on PATH." >&2
        exit 2
    fi
done
if ! command -v openssl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "FATAL: the redirect scenarios need openssl and python3." >&2
    exit 2
fi

SERVER_PIDS=""
cleanup() {
    if [ -n "$SERVER_PIDS" ]; then
        # shellcheck disable=SC2086
        kill $SERVER_PIDS 2>/dev/null || true
    fi
}
trap cleanup EXIT

expect() { # label want got
    TESTS=$((TESTS + 1))
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1 (want [$2], got [$3])"
        FAILS=$((FAILS + 1))
    fi
}
expect_grep() { # label file pattern
    TESTS=$((TESTS + 1))
    if grep -qF "$3" "$2"; then
        echo "ok   $1"
    else
        echo "FAIL $1 (missing [$3] in $2)"
        FAILS=$((FAILS + 1))
    fi
}
expect_not_grep() { # label file pattern
    TESTS=$((TESTS + 1))
    if grep -qF "$3" "$2"; then
        echo "FAIL $1 (unexpected [$3] in $2)"
        FAILS=$((FAILS + 1))
    else
        echo "ok   $1"
    fi
}

# --- fixtures ---------------------------------------------------------------
# Mint a fresh test keypair per run (EPH-I0194: no fixed names). -W
# generates passwordless keys, the automation shape: the sign step then
# needs no interactive password prompt. The keygen chatter is muted; the
# failure guard keeps the FATAL exit.
minisign -G -W -p "$E2E/test.pub" -s "$E2E/test.key" < /dev/null 2>/dev/null || {
    echo "FATAL: minisign key generation failed." >&2
    exit 2
}
minisign -G -W -p "$E2E/other.pub" -s "$E2E/other.key" < /dev/null 2>/dev/null || {
    echo "FATAL: minisign key generation failed." >&2
    exit 2
}

# The real v0.14.2 tarball, a valid signature from the test keypair, a
# tampered tarball, and a wrong-key signature. Codeberg serves outages
# (a 503 was observed 2026-08-27), so a failed live fetch falls back to
# the v0.14.2 archive zig cached from the same URL during an earlier
# install (zig stores fetched archives in its package cache, the
# project-isolated cache first).
if ! curl -fsSL --max-time 60 -o "$E2E/valid.tar.gz" \
    "https://codeberg.org/RhyosLabs/ephor/archive/v0.14.2.tar.gz"; then
    echo "note: the live v0.14.2 fetch failed; using a cached copy."
    V0142_CACHE=$(ls -1 "$ROOT/.zenv/cache/p/ephor-0.14.2-p-"*.tar.gz 2>/dev/null | head -1)
    if [ -z "$V0142_CACHE" ]; then
        V0142_CACHE=$(ls -1 "$HOME/.cache/zig/p/ephor-0.14.2-p-"*.tar.gz 2>/dev/null | head -1)
    fi
    if [ -z "$V0142_CACHE" ]; then
        echo "FATAL: the v0.14.2 fetch failed and no cached copy exists." >&2
        exit 2
    fi
    cp "$V0142_CACHE" "$E2E/valid.tar.gz"
fi
minisign -S -m "$E2E/valid.tar.gz" -s "$E2E/test.key" -t "wp65 e2e" \
    -x "$E2E/valid.tar.gz.minisig" < /dev/null 2>/dev/null
printf 'tampered bytes\n' > "$E2E/tampered.tar.gz"
minisign -S -m "$E2E/tampered.tar.gz" -s "$E2E/other.key" -t "other" \
    -x "$E2E/tampered.tar.gz.minisig" < /dev/null 2>/dev/null
printf '[{"name":"v0.99.1"}]' > "$E2E/tags.json"

PUBKEY=$(cat "$E2E/test.pub")
OTHER_PUBKEY=$(cat "$E2E/other.pub")

# One fresh zig project per scenario (the install mutates the project).
new_project() { # name
    rm -rf "$E2E/$1"
    mkdir -p "$E2E/$1"
    cat > "$E2E/$1/build.zig" <<'EOF'
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
    cat > "$E2E/$1/build.zig.zon" <<'EOF'
.{
    .name = .wproj,
    .version = "0.0.0",
    .fingerprint = 0x0,
    .paths = .{ "build.zig", "build.zig.zon" },
}
EOF
}

# Run the installer in the scenario dir. Remaining args are env
# assignments. Returns the exit code in the global $rc.
run_scenario() { # dir ...
    dir=$1
    shift
    rc=0
    (cd "$E2E/$dir" && env \
        EPHOR_TEST_MODE=1 \
        EPHOR_TAGS_API="file://$E2E/tags.json" \
        ZIG_GLOBAL_CACHE_DIR="$E2E/cache" \
        "$@" \
        sh "$ROOT/install.sh") > "$E2E/$dir/out.log" 2> "$E2E/$dir/err.log" || rc=$?
}

# s1 active default: no pubkey override, so the embedded release key
# verifies the release. The valid.tar.gz carries the test keypair's
# signature, which the release key rejects: the unsigned old release
# fails closed before zig fetch. The signature rides the EPHOR_SIG_URL
# channel, so the derived raw-branch URL stays untested here (the
# install-sh t54 pin covers it).
new_project s1
run_scenario s1 \
    EPHOR_ARCHIVE_URL="$E2E/valid.tar.gz" \
    EPHOR_SIG_URL="$E2E/valid.tar.gz.minisig"
expect "s1 active-default rc 1" "1" "$rc"
expect_grep "s1 key-id mismatch surfaced" "$E2E/s1/err.log" "Signature key id in"
expect_grep "s1 fail-closed error" "$E2E/s1/err.log" "error: the release signature check failed."
expect_not_grep "s1 no inactive warning" "$E2E/s1/err.log" "release signature verification is inactive"
expect_not_grep "s1 no Done" "$E2E/s1/out.log" "Done!"
expect_grep "s1 zon untouched" "$E2E/s1/build.zig.zon" ".fingerprint = 0x0,"

# s2 active + valid signature: verify + full install succeeds.
new_project s2
run_scenario s2 \
    EPHOR_RELEASE_PUBKEY="$PUBKEY" \
    EPHOR_ARCHIVE_URL="$E2E/valid.tar.gz" \
    EPHOR_SIG_URL="$E2E/valid.tar.gz.minisig"
expect "s2 active-valid rc 0" "0" "$rc"
expect_grep "s2 verification line" "$E2E/s2/out.log" "Release signature verified."
expect_grep "s2 install completes" "$E2E/s2/out.log" "Done!"

# s3 active + tampered tarball (signature for the original bytes): fail
# closed before zig fetch.
new_project s3
run_scenario s3 \
    EPHOR_RELEASE_PUBKEY="$PUBKEY" \
    EPHOR_ARCHIVE_URL="$E2E/tampered.tar.gz" \
    EPHOR_SIG_URL="$E2E/valid.tar.gz.minisig"
expect "s3 tampered rc 1" "1" "$rc"
expect_grep "s3 minisign verdict surfaced" "$E2E/s3/err.log" "Signature verification failed"
expect_grep "s3 fail-closed error" "$E2E/s3/err.log" "error: the release signature check failed."
expect_not_grep "s3 no Done" "$E2E/s3/out.log" "Done!"
expect_grep "s3 zon untouched" "$E2E/s3/build.zig.zon" ".fingerprint = 0x0,"

# s4 active + missing signature file: fail closed.
new_project s4
run_scenario s4 \
    EPHOR_RELEASE_PUBKEY="$PUBKEY" \
    EPHOR_ARCHIVE_URL="$E2E/valid.tar.gz" \
    EPHOR_SIG_URL="$E2E/no-such-sig.minisig"
expect "s4 missing-sig rc 1" "1" "$rc"
expect_grep "s4 missing-sig error" "$E2E/s4/err.log" "error: could not download the release signature."

# s5 active + wrong key: fail closed.
new_project s5
run_scenario s5 \
    EPHOR_RELEASE_PUBKEY="$OTHER_PUBKEY" \
    EPHOR_ARCHIVE_URL="$E2E/valid.tar.gz" \
    EPHOR_SIG_URL="$E2E/valid.tar.gz.minisig"
expect "s5 wrong-key rc 1" "1" "$rc"
expect_grep "s5 fail-closed error" "$E2E/s5/err.log" "error: the release signature check failed."

# s6 active + minisign missing from PATH: fail closed with the
# dependency message.
new_project s6
rc=0
(cd "$E2E/s6" && env \
    EPHOR_TEST_MODE=1 \
    EPHOR_TAGS_API="file://$E2E/tags.json" \
    ZIG_GLOBAL_CACHE_DIR="$E2E/cache" \
    EPHOR_RELEASE_PUBKEY="$PUBKEY" \
    EPHOR_ARCHIVE_URL="$E2E/valid.tar.gz" \
    EPHOR_SIG_URL="$E2E/valid.tar.gz.minisig" \
    PATH="/usr/bin:/bin:$ROOT/.zenv/bin" \
    sh "$ROOT/install.sh") > "$E2E/s6/out.log" 2> "$E2E/s6/err.log" || rc=$?
expect "s6 missing-minisign rc 1" "1" "$rc"
expect_grep "s6 dependency error" "$E2E/s6/err.log" "error: minisign is not installed or not on PATH."

# s7 override hygiene + active default: an override set without
# EPHOR_TEST_MODE is ignored with a warning (EPH-I0205 parity), and the
# embedded release key then verifies the latest release on its own
# derived URLs. No assertion depends on whether the latest release is
# signed (EPH-I1289): pre-release the install fails closed at the
# signature download, post-release it verifies and installs. The two
# warning pins prove the ignore branches fired. The exclusion proves
# the consequence: the override signature is test-key-signed, so an
# honored sig override surfaces minisign's key-id mismatch verdict under
# the embedded release key, and that verdict stays absent in both eras
# of correct behavior (no minisign run pre-release, a matching key
# post-release). This scenario needs the live network: the tarball
# download runs against codeberg.org.
new_project s7
rc=0
(cd "$E2E/s7" && env \
    ZIG_GLOBAL_CACHE_DIR="$E2E/cache" \
    EPHOR_RELEASE_PUBKEY="$PUBKEY" \
    EPHOR_SIG_URL="file://$E2E/valid.tar.gz.minisig" \
    sh "$ROOT/install.sh") > "$E2E/s7/out.log" 2> "$E2E/s7/err.log" || rc=$?
expect_grep "s7 pubkey override ignored" "$E2E/s7/err.log" "warning: EPHOR_RELEASE_PUBKEY is ignored without EPHOR_TEST_MODE=1."
expect_grep "s7 sig override ignored" "$E2E/s7/err.log" "warning: EPHOR_SIG_URL is ignored without EPHOR_TEST_MODE=1."
expect_not_grep "s7 no override-honored key-id verdict" "$E2E/s7/err.log" "Signature key id in"

# --- I1216 parity scenarios (2026-08-27): fetch_bounded's redirect and
# cap policy, driven through the tags channel. The archive channel
# cannot prove the https clamp end-to-end here: zig fetch trusts only
# the system keychains on macOS, so a scratch-cert https archive origin
# fails zig fetch's own TLS check after the curl-side policy worked.
# The tags fetch carries the same --proto-redir =https clamp as
# fetch_bounded, so the s8/s9 scenarios pin the shared policy, and s10
# pins the file:// cap on fetch_bounded itself.
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$E2E/server.key" -out "$E2E/server.crt" -days 2 \
    -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" \
    >/dev/null 2>&1 || { echo "FATAL: openssl cert generation failed" >&2; exit 2; }

cat > "$E2E/serve.py" <<'PYEOF'
import http.server
import socketserver
import ssl
import sys
import os

MODE = sys.argv[1]
DOCROOT = sys.argv[2]


def peer_port(name):
    with open(os.path.join(DOCROOT, name)) as f:
        return f.read().strip()


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if self.path == "/redir-tags":
            self.send_response(302)
            self.send_header(
                "Location",
                "https://127.0.0.1:%s/tags.json" % peer_port("peer-tls.port"),
            )
            self.end_headers()
            return
        if self.path == "/redir-tags-http":
            self.send_response(302)
            self.send_header(
                "Location",
                "http://127.0.0.1:%s/tags.json" % peer_port("peer-http.port"),
            )
            self.end_headers()
            return
        return super().do_GET()


class ThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def main():
    os.chdir(DOCROOT)
    httpd = ThreadingServer(("127.0.0.1", 0), QuietHandler)
    if MODE == "tls":
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(
            os.path.join(DOCROOT, "server.crt"),
            os.path.join(DOCROOT, "server.key"),
        )
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    sys.stdout.write(str(httpd.server_address[1]) + "\n")
    sys.stdout.flush()
    httpd.serve_forever()


main()
PYEOF

(cd "$E2E" && exec python3 serve.py http "$E2E") > "$E2E/http.port" 2>"$E2E/http.err" &
HTTP_PID=$!
SERVER_PIDS="$HTTP_PID"
(cd "$E2E" && exec python3 serve.py tls "$E2E") > "$E2E/tls.port" 2>"$E2E/tls.err" &
TLS_PID=$!
SERVER_PIDS="$SERVER_PIDS $TLS_PID"
i=0
while { [ ! -s "$E2E/http.port" ] || [ ! -s "$E2E/tls.port" ]; } && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
done
if [ ! -s "$E2E/http.port" ] || [ ! -s "$E2E/tls.port" ]; then
    echo "FATAL: the redirect servers did not start." >&2
    exit 2
fi
HTTP_PORT=$(cat "$E2E/http.port")
TLS_PORT=$(cat "$E2E/tls.port")
printf '%s' "$HTTP_PORT" > "$E2E/peer-http.port"
printf '%s' "$TLS_PORT" > "$E2E/peer-tls.port"

# s8 https-to-https redirect follow (I1216): the tags fetch follows the
# clamped redirect chain from an https origin to an https target and
# resolves the tag. The archive stays a local path, so zig fetch never
# sees the scratch cert. The install completes.
new_project s8
rc=0
(cd "$E2E/s8" && env \
    EPHOR_TEST_MODE=1 \
    EPHOR_TAGS_API="https://127.0.0.1:$TLS_PORT/redir-tags" \
    ZIG_GLOBAL_CACHE_DIR="$E2E/cache" \
    EPHOR_RELEASE_PUBKEY="$PUBKEY" \
    EPHOR_ARCHIVE_URL="$E2E/valid.tar.gz" \
    EPHOR_SIG_URL="$E2E/valid.tar.gz.minisig" \
    CURL_CA_BUNDLE="$E2E/server.crt" \
    sh "$ROOT/install.sh") > "$E2E/s8/out.log" 2> "$E2E/s8/err.log" || rc=$?
expect "s8 https-to-https redirect rc 0" "0" "$rc"
expect_grep "s8 tag resolved through the redirect" "$E2E/s8/out.log" "Installing ephor v0.99.1"
expect_grep "s8 install completes" "$E2E/s8/out.log" "Done!"

# s9 https-to-http downgrade refusal (I1216): the clamp refuses the
# downgrade hop, so the resolution fails and the install takes the
# pinned fallback with its warning pair. The http target serves the
# payload, so the refusal is the clamp, not a dead endpoint.
new_project s9
rc=0
(cd "$E2E/s9" && env \
    EPHOR_TEST_MODE=1 \
    EPHOR_TAGS_API="https://127.0.0.1:$TLS_PORT/redir-tags-http" \
    ZIG_GLOBAL_CACHE_DIR="$E2E/cache" \
    EPHOR_RELEASE_PUBKEY="$PUBKEY" \
    EPHOR_ARCHIVE_URL="$E2E/valid.tar.gz" \
    EPHOR_SIG_URL="$E2E/valid.tar.gz.minisig" \
    CURL_CA_BUNDLE="$E2E/server.crt" \
    sh "$ROOT/install.sh") > "$E2E/s9/out.log" 2> "$E2E/s9/err.log" || rc=$?
expect "s9 downgrade refusal falls back rc 0" "0" "$rc"
expect_grep "s9 fallback warning" "$E2E/s9/err.log" "warning: could not resolve the latest ephor tag from the Codeberg API."
expect_grep "s9 fallback tag line" "$E2E/s9/out.log" "Installing ephor v0.15.4"
expect_grep "s9 install completes" "$E2E/s9/out.log" "Done!"

# The remaining scenario needs no redirect servers.
kill "$HTTP_PID" "$TLS_PID" 2>/dev/null || true
SERVER_PIDS=""
wait "$HTTP_PID" 2>/dev/null || true
wait "$TLS_PID" 2>/dev/null || true

# s10 file:// byte cap (I1216): an over-cap local archive fails the
# bounded fetch before the signature check, so the install fails closed
# and the zon stays untouched. The bare path exercises fetch_bounded's
# file:// conversion too.
head -c 33554433 /dev/zero > "$E2E/oversized.tar.gz"
new_project s10
run_scenario s10 \
    EPHOR_RELEASE_PUBKEY="$PUBKEY" \
    EPHOR_ARCHIVE_URL="$E2E/oversized.tar.gz" \
    EPHOR_SIG_URL="$E2E/valid.tar.gz.minisig"
expect "s10 over-cap archive rc 1" "1" "$rc"
expect_grep "s10 over-cap error" "$E2E/s10/err.log" "error: could not download the release tarball for verification."
expect_grep "s10 zon untouched" "$E2E/s10/build.zig.zon" ".fingerprint = 0x0,"

echo ""
echo "wp65 e2e: $TESTS checks, $FAILS failed"
[ "$FAILS" -eq 0 ]
