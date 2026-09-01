#!/bin/sh
# Ephor installer - adds ephor to your Zig project
# Usage: curl -fsSL https://codeberg.org/RhyosLabs/ephor/raw/branch/main/install.sh | sh

# pipefail is not portable to POSIX sh (dash), so each fallible command
# handles its own exit status explicitly.
# EPH-I0638: mktemp, grep -o, and stat go beyond POSIX. macOS and
# Linux ship all three, and an exotic system fails loudly at the first
# use instead of misbehaving silently, so the dependency is accepted
# and documented here. sed -i.bak left the script with the EPH-I1272
# repair rewrite. The stat acceptance note lives at preserve_mode.
set -eu

# EPH-I0194: a cloned repo can plant a symlink at a fixed temp name such as
# build.zig.tmp. A ">" redirect follows the symlink and overwrites the
# target. Every writer below uses mktemp, whose name cannot exist yet, and
# mv, whose rename replaces a planted symlink instead of following it. The
# trap removes the temp file when the script exits before the mv.
INSTALL_TMP=""
VERIFY_DIR=""
# EPH-I0633: dash does not run the EXIT trap on SIGTERM or SIGHUP, so a
# signal during the install litters the temp file in the project dir.
# Convert the signals into an exit; the EXIT trap then always cleans.
trap 'exit 1' TERM HUP INT
trap '[ -z "$INSTALL_TMP" ] || rm -f "$INSTALL_TMP"
[ -z "$VERIFY_DIR" ] || rm -rf "$VERIFY_DIR"' EXIT

# Create the swap file for the next mktemp+mv write and publish its path in
# INSTALL_TMP for the EXIT trap. mktemp makes the file 0600. chmod applies
# the project default (0666 & ~umask) with owner write kept unconditionally
# (EPH-I0632): umasks like 0277 or 0777 strip owner write, and the next
# redirect would fail with EACCES.
make_install_tmp() {
    # EPH-I0642: INSTALL_TMP is one slot, and only the mv at each call
    # site clears it. A second call before that mv would orphan the live
    # temp file. Refuse the internal misuse instead of leaking it; the
    # EXIT trap removes the live temp on the way out.
    if [ -n "$INSTALL_TMP" ]; then
        echo "error: INSTALL_TMP already holds a live temp file." >&2
        exit 1
    fi
    INSTALL_TMP=$(mktemp "$1")
    chmod "$(printf '%03o' $((0600 | (0666 & ~$(umask)))))" "$INSTALL_TMP"
}

# Preserve the original file's mode across the splice (EPH-I0636). The mv
# below renames the temp over the original, so the result takes the temp's
# mode: a 0600 or +x build.zig re-normalizes otherwise. Call this right
# before each build.zig mv. stat is not POSIX, but the two target
# platforms each have one dialect, and an exotic platform fails the chmod
# loudly instead of silently re-normalizing. The BSD form reads the low
# three octal digits, so setuid bits are not preserved; xattrs and ACLs
# are not preserved on any platform. Both losses are accepted: a build
# file that carries them is out of scope.
preserve_mode() { # original file
    case "$(uname -s)" in
        Darwin|FreeBSD|OpenBSD|NetBSD) chmod "$(stat -f '%Lp' "$1")" "$INSTALL_TMP" ;;
        *) chmod "$(stat -c '%a' "$1")" "$INSTALL_TMP" ;;
    esac
}

REPO="https://codeberg.org/RhyosLabs/ephor"
# Tests override these URLs through EPHOR_TAGS_API and EPHOR_ARCHIVE_URL to
# simulate an API failure and serve a local archive. EPH-I0205: the
# overrides steer the install's trust anchor, so ambient environment
# (direnv, .envrc) must not activate them. Each override takes effect only
# when EPHOR_TEST_MODE=1 is set explicitly; an override set without the
# marker is ignored with a warning.
test_mode_active() {
    [ "${EPHOR_TEST_MODE:-}" = "1" ]
}

# EPH-I0637: the API orders tags by date, so limit=10 left a window: ten
# re-dated old tags could evict the true max from the page. limit=50 is
# the API's per-page maximum and holds every tag the repo has released
# so far (15, verified 2026-08-22), so the window is closed today. When
# the repo grows past 50 tags it reopens, and the fallback floor in
# resolve_ephor_tag caps the damage at the pinned tag.
TAGS_API="https://codeberg.org/api/v1/repos/RhyosLabs/ephor/tags?limit=50"
if test_mode_active; then
    TAGS_API="${EPHOR_TAGS_API:-$TAGS_API}"
elif [ -n "${EPHOR_TAGS_API:-}" ]; then
    echo "warning: EPHOR_TAGS_API is ignored without EPHOR_TEST_MODE=1." >&2
fi
# This tag is the fallback when the Codeberg tags API fails. Refresh it on every release.
EPHOR_FALLBACK_TAG="v0.15.1"
# Pin for Zig 0.15.x. Every remote tag (v0.12.3 and later) declares
# minimum_zig_version 0.16.0. The 0.16 migration landed in v0.12.0, so no
# remote tag builds on Zig 0.15.x. v0.11.13 declares minimum_zig_version
# 0.15.0 and is the newest 0.15-era release. Its tag is deleted on the
# remote, so pin the commit hash. Commit archives stay available.
EPHOR_0_15_COMMIT="60145fe05a2b91e7dd32d1c671d98239cd19aea6"

# EPH-I0287 (WP-6.5): the minisign public key of the ephor release
# signing keypair, the exact two-line .pub file the WP-7 key mint
# produced. Both lines are wire shape, not prose: minisign 0.12 rejects
# a file whose key line is the first line, so the comment line ships
# with the key. EPH-I0205: tests override it through
# EPHOR_RELEASE_PUBKEY, gated by EPHOR_TEST_MODE like the other
# trust-anchor overrides.
RELEASE_PUBKEY='untrusted comment: minisign public key BD29FC2E33D53EBE
RWS+PtUzLvwpvc7nVJ8t8MKTpo4/8UdOqoxuLGXhfJQI+qvTyn82Dfit'
if test_mode_active; then
    RELEASE_PUBKEY="${EPHOR_RELEASE_PUBKEY:-$RELEASE_PUBKEY}"
elif [ -n "${EPHOR_RELEASE_PUBKEY:-}" ]; then
    echo "warning: EPHOR_RELEASE_PUBKEY is ignored without EPHOR_TEST_MODE=1." >&2
fi
# EPH-I0287: byte caps for the verification downloads. The tarball cap
# is 32 MiB: the largest published archive measures 436,635 bytes
# (main, verified 2026-08-27), so the cap holds 77x headroom and still
# bounds a hostile stream. The signature cap matches the tags-API cap;
# a minisig file measures 282 bytes (verified 2026-08-27).
TARBALL_CAP=33554432
SIG_CAP=1048576

# Bare globals here stay POSIX-correct only while every call site is a $() subshell.
# Read strict vX.Y.Z tags on stdin and print the semver-highest one. Print
# nothing on empty input.
# EPH-I0193: the Codeberg API orders tags by date, so the first entry is not
# always the highest version. A re-dated old tag must never downgrade an
# install. The numeric sort keys are the portable (BSD+GNU) semver compare.
# sort -V is GNU-only.
max_stable_tag() {
    sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 | sed 's/^/v/'
}

# Return 0 when the strict tag $1 sorts below the strict tag $2, else 1.
# EPH-I0193: the downgrade floor needs a version compare, not a string
# compare.
version_older() {
    [ "$1" != "$2" ] || return 1
    lower=$(printf '%s\n%s\n' "${1#v}" "${2#v}" \
        | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)
    [ "$lower" = "${1#v}" ]
}

# Print the newest stable release tag on stdout. Return 1 when the API
# fails, the result is empty, or no tag is a strict vMAJOR.MINOR.PATCH.
latest_ephor_tag() {
    # 30s: the Codeberg API has answered in 20s+ on slow days; refusals still fail fast.
    # EPH-I0156: an https fetch is clamped to the https scheme, redirects
    # included, and capped at 1 MiB. A hostile network cannot redirect the
    # fetch into a local file read or spew an unbounded body.
    # EPH-I0207 (RED2-6): the 1 MiB body cap now applies to every scheme,
    # so the operator-picked test channel (file://, http://) gets the
    # same byte bound as production. --max-time bounds duration, not
    # bytes; --max-filesize bounds bytes, so a fast network-path attacker
    # cannot stream gigabytes into the shell variable inside the 30s
    # window. An over-cap transfer fails curl (rc 63), which fails the
    # resolution and takes the pinned fallback. The word split of
    # $proto_flags is intentional.
    proto_flags="--max-filesize 1048576"
    case "$TAGS_API" in
        https://*) proto_flags="--proto =https --proto-redir =https --max-filesize 1048576" ;;
    esac
    response=$(curl -fsSL --max-time 30 $proto_flags "$TAGS_API" 2>/dev/null) || return 1
    # EPH-I1271: extract only "name" values that sit at a key position.
    # The pre-fix grep minted candidates from "name" text inside a string
    # value (a tag message that quotes it), so a message-steered v9.9.9
    # could win the semver max and 404 the install. The awk byte scan
    # tracks string context with backslash escapes (the Zig-side
    # isJsonKeyPosition model): a quote at an even unescaped-quote index
    # opens a string, so a "name" token there is data, not a key. The
    # body is buffered first so a raw newline inside a malformed string
    # cannot reset the context. Kept in sync with scripts/check-version.sh
    # max_stable_version.
    tag=$(printf '%s\n' "$response" | awk '
        { body = body $0 "\n" }
        END {
            n = length(body)
            in_str = 0
            i = 1
            while (i <= n) {
                c = substr(body, i, 1)
                if (in_str) {
                    if (c == "\\") { i = i + 2; continue }
                    if (c == "\"") in_str = 0
                    i = i + 1
                    continue
                }
                if (c != "\"") { i = i + 1; continue }
                if (substr(body, i + 1, 5) == "name\"") {
                    j = i + 6
                    while (j <= n) {
                        w = substr(body, j, 1)
                        if (w != " " && w != "\t" && w != "\n" && w != "\r") break
                        j = j + 1
                    }
                    if (j <= n && substr(body, j, 1) == ":") {
                        j = j + 1
                        while (j <= n) {
                            w = substr(body, j, 1)
                            if (w != " " && w != "\t" && w != "\n" && w != "\r") break
                            j = j + 1
                        }
                        if (j <= n && substr(body, j, 1) == "\"") {
                            j = j + 1
                            val = ""
                            while (j <= n && substr(body, j, 1) != "\"") {
                                val = val substr(body, j, 1)
                                j = j + 1
                            }
                            print val
                            i = j + 1
                            continue
                        }
                    }
                }
                in_str = 1
                i = i + 1
            }
        }
        ' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | max_stable_tag)
    [ -n "$tag" ] || return 1
    printf '%s\n' "$tag"
}

# Print the release tag to install: the latest tag from the Codeberg API, or
# the pinned fallback tag when the API does not yield a valid tag.
resolve_ephor_tag() {
    tag=$(latest_ephor_tag) || tag=""
    if [ -z "$tag" ]; then
        echo "warning: could not resolve the latest ephor tag from the Codeberg API." >&2
        echo "The install continues with the fallback tag ${EPHOR_FALLBACK_TAG}." >&2
        tag="$EPHOR_FALLBACK_TAG"
    elif version_older "$tag" "$EPHOR_FALLBACK_TAG"; then
        # EPH-I0193: a stale or re-dated API response must not downgrade the
        # install below the pinned fallback.
        echo "warning: the resolved tag ${tag} is below the fallback ${EPHOR_FALLBACK_TAG}." >&2
        echo "The install continues with the fallback tag." >&2
        tag="$EPHOR_FALLBACK_TAG"
    fi
    printf '%s\n' "$tag"
}

# EPH-I0287 (WP-6.5): download $1 to $2 with the scheme clamp and the
# byte cap (EPH-I0156, EPH-I0207). The flags mirror latest_ephor_tag's
# fetch; that function keeps its own inline copy because the harness
# extracts it verbatim (EPH-I1194). $3 is the byte cap. --max-time
# bounds duration; --max-filesize bounds bytes, so a fast network-path
# attacker cannot stream unbounded data into the temp file inside the
# 30 s window. An over-cap transfer fails curl (rc 63). The word split
# of $proto_flags is intentional. Curl 8.7 rejects a bare absolute
# path (rc 3, "No host part"), so a path-shaped URL gets the file://
# prefix curl accepts (verified 2026-08-27); zig fetch receives the
# original EPHOR_URL untouched.
fetch_bounded() {
    url="$1"
    proto_flags=""
    case "$url" in
        https://*) proto_flags="--proto =https --proto-redir =https" ;;
        /*) url="file://$url" ;;
    esac
    curl -fsSL --max-time 30 $proto_flags --max-filesize "$3" -o "$2" "$url" 2>/dev/null
}

# EPH-I0287 (WP-6.5): download the release tarball and its minisign
# signature, and verify the signature before zig fetch downloads the
# artifact again. Two states:
# - Active (the shipped state): the release key is embedded, so every
#   release must be signed. A missing minisign binary, a failed
#   download, or a bad signature fails the install closed.
# - Inactive (empty key): the pre-release fallback state. The check
#   warns and the install continues on the recorded-hash model.
verify_ephor_release() {
    if [ -z "$RELEASE_PUBKEY" ]; then
        echo "warning: release signature verification is inactive." >&2
        echo "This installer embeds no release public key yet." >&2
        echo "The first signed release activates the check." >&2
        return 0
    fi
    if ! command -v minisign >/dev/null 2>&1; then
        echo "error: minisign is not installed or not on PATH." >&2
        echo "This release is signed. Install minisign, then re-run the install." >&2
        exit 1
    fi
    # EPH-I0194: a fixed temp name could be planted, so the verification
    # files live in a fresh mktemp dir. The EXIT trap removes it. Under
    # set -e a failed mktemp aborts the install before any download.
    VERIFY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ephor-verify.XXXXXXXX")
    # EPH-I0632 (WP-7 fill exposure): the BSD mktemp applies the umask to
    # its 0700, so a umask that strips owner write (0277) leaves the dir
    # unwritable and every download fails. Keep it owner-writable like
    # make_install_tmp keeps its temp files.
    chmod u+w "$VERIFY_DIR"
    fetch_bounded "$EPHOR_URL" "$VERIFY_DIR/ephor.tar.gz" "$TARBALL_CAP" || {
        echo "error: could not download the release tarball for verification." >&2
        echo "Check the network connection, then re-run the install." >&2
        exit 1
    }
    fetch_bounded "$SIG_URL" "$VERIFY_DIR/ephor.tar.gz.minisig" "$SIG_CAP" || {
        echo "error: could not download the release signature." >&2
        echo "Check the network connection, then re-run the install." >&2
        exit 1
    }
    printf '%s\n' "$RELEASE_PUBKEY" > "$VERIFY_DIR/ephor.pub"
    # minisign reads the signature from <file>.minisig next to the
    # file, so both downloads share the dir and the base name above.
    # The if guard keeps set -e from aborting on the failing status.
    if ! VERIFY_OUT=$(minisign -Vm "$VERIFY_DIR/ephor.tar.gz" -p \
        "$VERIFY_DIR/ephor.pub" 2>&1); then
        printf '%s\n' "$VERIFY_OUT" >&2
        echo "error: the release signature check failed." >&2
        echo "The downloaded artifact may be tampered with. The install stops." >&2
        exit 1
    fi
    rm -rf "$VERIFY_DIR"
    VERIFY_DIR=""
    echo "Release signature verified."
}

# The words Zig reserves in the .name field of build.zig.zon. The field
# must be a bare identifier, and Zig rejects every keyword, primitive
# type, and literal there even though the words look like identifiers
# (EPH-I0629). The list mirrors the Zig 0.16 tokenizer keyword table
# plus the primitive types and literals. Each entry was verified
# against zig 0.16.0.
ZON_RESERVED_WORDS='addrspace
align
allowzero
and
anyframe
anytype
asm
break
callconv
catch
comptime
const
continue
defer
else
enum
errdefer
error
export
extern
fn
for
if
inline
noalias
noinline
nosuspend
opaque
or
orelse
packed
pub
resume
return
linksection
struct
suspend
switch
test
threadlocal
try
union
unreachable
var
volatile
while
bool
f16
f32
f64
f80
f128
i8
i16
i32
i64
i128
isize
u8
u16
u32
u64
u128
usize
void
noreturn
type
anyerror
anyopaque
comptime_int
comptime_float
c_short
c_ushort
c_int
c_uint
c_long
c_ulong
c_longlong
c_ulonglong
c_longdouble
true
false
null
undefined'

# True (exit 0) when $1 is a word Zig reserves for the zon .name field
# (EPH-I0629). The fixed-string whole-line grep matches the table above.
zon_name_is_keyword() {
    printf '%s\n' "$ZON_RESERVED_WORDS" | grep -qxF "$1"
}

# EPH-I0631: without zig the fetch below dies with a shell "not found"
# message and exit 127 after the zon was already created. Refuse first,
# before any file is created or changed.
if ! command -v zig >/dev/null 2>&1; then
    echo "error: zig is not installed or not on PATH." >&2
    echo "Install Zig, then re-run the install." >&2
    exit 1
fi

# Check that this is a Zig project.
# EPH-I1111: refuse a symlink at build.zig before any read. sed and grep
# follow symlinks, so a planted link would feed the victim file's content
# through the probes and splice it into the repo tree (the same mechanism
# the Zig side closed in EPH-I0670). The -L test does not follow the
# link, so it sees the link itself. -L is the XSI test form; it ships in
# dash, bash 3.2, and the BSD test builtins.
if [ -L "build.zig" ]; then
    echo "error: build.zig is a symlink." >&2
    echo "Replace it with a regular file before installing ephor." >&2
    exit 1
fi

# EPH-I1107: this refusal prints to stderr like every other error in the
# script, so consumers that read stderr for diagnostics see it.
if [ ! -f "build.zig" ]; then
    echo "error: no build.zig found in the current directory" >&2
    echo "" >&2
    echo "  Ephor requires a Zig project with build.zig and build.zig.zon." >&2
    echo "  To initialize a Zig project, run:" >&2
    echo "" >&2
    echo "    zig init" >&2
    echo "" >&2
    echo "  Then re-run the install:" >&2
    echo "    curl -fsSL ${REPO}/raw/branch/main/install.sh | sh" >&2
    exit 1
fi

if [ ! -f "build.zig.zon" ]; then
    # EPH-I0627: a build.zig.zon that is a directory, or a symlink to a
    # directory, absorbs the mv below - the temp file lands inside it
    # instead of replacing the name. -d follows symlinks, so this one
    # test covers both shapes. Refuse before the mv.
    if [ -d "build.zig.zon" ]; then
        echo "error: build.zig.zon is a directory." >&2
        echo "Remove or rename it, then re-run the install." >&2
        exit 1
    fi
    PROJECT_NAME=$(basename "$(pwd)" | tr '-' '_' | tr '[:upper:]' '[:lower:]')
    # EPH-I0629: .name must be a valid bare Zig identifier. Zig 0.16
    # rejects every quoted form ("name must be a valid bare zig
    # identifier"), so a name that is not one is sanitized the way
    # zig init sanitizes: characters outside a-z0-9_ become
    # underscores, and a leading digit gets an underscore prefix.
    # A name that is a reserved word is a bare identifier but still
    # rejected, so it falls back to a fixed name. Both fallbacks warn.
    # The invalid arm reads "empty, or contains a character outside
    # a-z0-9_, or starts with a digit": a bare [a-z_][a-z0-9_]* glob
    # would also match dotted names, because glob * is not limited to
    # the class.
    NAME_EXPR=""
    # EPH-I1274: sanitize the echoed name before it reaches the terminal.
    # The warning arm below fires exactly when the name carries
    # non-identifier bytes, which admits ESC and friends, so the raw name
    # must not reach any echo. The byte filter replaces C0 controls and
    # DEL with '?' (the Zig-side sanitizeTerminal placeholder). The
    # residual is live, not inert: the encoded C1 set (0xC2 0x80..0x9F)
    # and the Cf format set pass the portable byte filter, and a
    # UTF-8-decoding terminal dispatches the encoded C1 bytes as CSI or
    # OSC. Portable shell cannot express the code-point filter the
    # Zig-side sanitizeTerminal applies; the PowerShell installer's
    # \p{Cc} form covers the C1 half there.
    ECHO_NAME=$(printf '%s' "$PROJECT_NAME" | LC_ALL=C tr '[:cntrl:]' '?')
    case "$PROJECT_NAME" in
        ''|*[!a-z0-9_]*|[0-9]*)
            SANITIZED=$(printf '%s' "$PROJECT_NAME" | tr -c 'a-z0-9_' '_')
            case "$SANITIZED" in
                [0-9]*) SANITIZED="_${SANITIZED}" ;;
            esac
            NAME_EXPR=".${SANITIZED}"
            echo "warning: '${ECHO_NAME}' is not a valid Zig identifier for the zon name." >&2
            echo "The zon uses the name '${SANITIZED}'. Edit build.zig.zon to rename it." >&2
            ;;
        *)
            NAME_EXPR=".${PROJECT_NAME}"
            ;;
    esac
    if zon_name_is_keyword "${NAME_EXPR#.}"; then
        echo "warning: '${NAME_EXPR#.}' is a reserved word in Zig and cannot be the zon name." >&2
        echo "The zon uses the name 'project'. Edit build.zig.zon to rename it." >&2
        NAME_EXPR=".project"
    fi
    echo "No build.zig.zon found, creating one..."
    make_install_tmp ./build.zig.zon.tmp.XXXXXXXX
    cat > "$INSTALL_TMP" << ZONEOF
.{
    .name = ${NAME_EXPR},
    .version = "0.0.0",
    .fingerprint = 0x0,
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
ZONEOF
    mv "$INSTALL_TMP" build.zig.zon
    INSTALL_TMP=""
    # EPH-I0192: do not spawn zig build for the fingerprint here. A hostile
    # build.zig would run attacker code. The zig fetch step below repairs
    # the 0x0 fingerprint from the hint zig fetch prints.
    echo "Created build.zig.zon for project '${ECHO_NAME}'"
fi

# EPH-I0284: refuse a symlink at build.zig.zon before the fetch. zig
# fetch --save rewrites the zon through zig's own write path, which
# follows a planted link, so no installer-side no-follow writer can
# close it (the EPH-I0194 mktemp+mv discipline covers only the files
# this script writes itself). The -L test does not follow the link
# (lstat), so it sees the link itself. A fresh-zon mv above already
# replaces the name, so a link that survives to here existed before
# the install. The symlink-to-a-directory shape refused earlier.
# EPH-I1165: the check-to-fetch window stays open: a concurrent writer
# could swap in a symlink after this lstat check and before the zig
# fetch below. The no-active-adversary-during-install assumption
# scopes the window out, because a concurrent same-privilege writer
# during the install is the invoking user, and the
# clone-time-planting class is closed by this check.
if [ -L "build.zig.zon" ]; then
    echo "error: build.zig.zon is a symlink." >&2
    echo "Replace it with a regular file before installing ephor." >&2
    exit 1
fi

# Detect Zig version and pick compatible ephor version
ZIG_VERSION=$(zig version 2>/dev/null || echo "")
EPHOR_URL=""
# Print the undetectable-version warning and resolve the latest tag
# (EPH-I0630). The garbage-shape arm and the non-numeric component arm
# share this helper.
warn_bad_zig_version() {
    echo "warning: could not parse the zig version '${ZIG_VERSION}', defaulting to latest" >&2
    EPHOR_TAG=$(resolve_ephor_tag)
}
# EPH-I0630: the integer tests below need numeric components. The old
# code tested unparsed version text, printed two "Illegal number" lines
# on garbage, and silently pinned the 0.15-era release even on systems
# running Zig 0.16+. The outer glob gates only the shape (a glob * is a
# wildcard, not a digit repetition, so "1a.2b.3c" passes it), so the
# components get a second gate: a non-numeric or empty component counts
# as undetectable and takes the latest-tag path with a warning.
case "$ZIG_VERSION" in
    [0-9]*.[0-9]*.*)
        ZIG_MAJOR=$(printf '%s\n' "$ZIG_VERSION" | cut -d. -f1)
        ZIG_MINOR=$(printf '%s\n' "$ZIG_VERSION" | cut -d. -f2)
        case "$ZIG_MAJOR$ZIG_MINOR" in
            *[!0-9]*)
                warn_bad_zig_version
                ;;
            *)
                # EPH-I1104: the shape glob accepts an empty component
                # ("[0-9]*" matches zero digits), and cut then yields an
                # empty operand. A version like "0..2." would reach the
                # integer test below with an empty minor: dash prints an
                # "Illegal number" noise line and the test reads false,
                # silently taking the 0.15-era pin. Reject the empty
                # operand like the non-numeric one (warn and latest).
                if [ -z "$ZIG_MAJOR" ] || [ -z "$ZIG_MINOR" ]; then
                    warn_bad_zig_version
                elif [ "$ZIG_MAJOR" -gt 0 ] || [ "$ZIG_MINOR" -ge 16 ]; then
                    # Zig 0.16.0 and later track the latest ephor release.
                    EPHOR_TAG=$(resolve_ephor_tag)
                else
                    # Zig 0.15.x uses the pinned 0.15-era release by
                    # commit hash.
                    EPHOR_TAG="v0.11.13"
                    EPHOR_URL="${REPO}/archive/${EPHOR_0_15_COMMIT}.tar.gz"
                fi
                ;;
        esac
        ;;
    '')
        echo "warning: could not detect zig version, defaulting to latest" >&2
        EPHOR_TAG=$(resolve_ephor_tag)
        ;;
    *)
        warn_bad_zig_version
        ;;
esac

# Detect if this is an upgrade or fresh install.
# EPH-I0641: both probes anchor to code context, so a comment that
# mentions ephor cannot mislabel a fresh install as an upgrade. The
# build.zig probe uses the same code-line idiom as the installArtifact
# search below. The zon probe matches the .ephor = dependency entry
# line that zig fetch writes; the old '"ephor"' pattern matched no
# real zon shape, only comments.
# EPH-I1106 decision: a trailing inline comment on a code line still
# reaches the anchored probe, because the .* spans into the comment.
# Stripping trailing comments needs a Zig lexer, which the installer
# does not carry. The installArtifact search below has the same idiom
# limit (EPH-I0626). The residual is accepted: it is label-only at this
# site, and the layout branch below shares the idiom and the limit.
DEP_PROBE='^[[:space:]]*[^/.\\[:space:]].*dependency\("ephor"'
ZON_DEP_PROBE='^[[:space:]]*\.ephor[[:space:]]*='
if grep -qE "$DEP_PROBE" build.zig 2>/dev/null || grep -qE "$ZON_DEP_PROBE" build.zig.zon 2>/dev/null; then
    ACTION="Upgrading"
else
    ACTION="Installing"
fi

if [ -n "$ZIG_VERSION" ]; then
    echo "${ACTION} ephor ${EPHOR_TAG} (Zig ${ZIG_VERSION})..."
else
    echo "${ACTION} ephor ${EPHOR_TAG}..."
fi
if [ -z "$EPHOR_URL" ]; then
    # Tests override the archive URL through EPHOR_ARCHIVE_URL, gated by
    # EPHOR_TEST_MODE like EPHOR_TAGS_API (EPH-I0205).
    EPHOR_URL="${REPO}/archive/${EPHOR_TAG}.tar.gz"
    if test_mode_active; then
        EPHOR_URL="${EPHOR_ARCHIVE_URL:-$EPHOR_URL}"
    elif [ -n "${EPHOR_ARCHIVE_URL:-}" ]; then
        echo "warning: EPHOR_ARCHIVE_URL is ignored without EPHOR_TEST_MODE=1." >&2
    fi
fi

# EPH-I0287 (WP-6.5): verify the release signature before zig fetch.
# EPH-I0205: tests override the signature URL through EPHOR_SIG_URL,
# gated by EPHOR_TEST_MODE like the other trust-anchor overrides.
# WP-7 era-pin carve (M-2): the check covers every TAG URL. The pinned
# 0.15-era commit archive skips it. A tag is a mutable pointer, and a
# moved tag is the M-2 threat, so a tag URL must verify. The commit
# archive is SHA-addressed and immutable on the remote: the commit
# cannot move, and https transport plus the package fingerprint that
# zig fetch records in build.zig.zon carry its integrity.
case "$EPHOR_URL" in
    "${REPO}/archive/${EPHOR_0_15_COMMIT}.tar.gz")
        echo "The installer skips signature verification for the pinned commit archive: it is immutable and SHA-addressed."
        ;;
    *)
        # WP-7: the signature lives in the repo tree at
        # signatures/<tag>.tar.gz.minisig, committed by the post-tag
        # commit for each release and served via the raw route.
        # Codeberg's archive route serves only real refs, so
        # ${EPHOR_URL}.minisig would 404 in production.
        SIG_URL="${REPO}/raw/branch/main/signatures/${EPHOR_TAG}.tar.gz.minisig"
        if test_mode_active; then
            SIG_URL="${EPHOR_SIG_URL:-$SIG_URL}"
        elif [ -n "${EPHOR_SIG_URL:-}" ]; then
            echo "warning: EPHOR_SIG_URL is ignored without EPHOR_TEST_MODE=1." >&2
        fi
        verify_ephor_release
        ;;
esac

echo "Adding ephor dependency..."
# EPH-I0192: zig fetch reads build.zig.zon but never runs build.zig, so a
# hostile build.zig still executes no code here. On a fresh zon with
# fingerprint 0x0, zig fetch fails and prints a "use this value" hint
# with the computed fingerprint. A zon without the field draws the
# sibling "suggested value" hint (EPH-I1291). Patch the hint in and
# fetch again.
FETCH_OUT=$(zig fetch --save=ephor "$EPHOR_URL" 2>&1) && FETCH_RC=0 || FETCH_RC=$?
if [ "$FETCH_RC" -ne 0 ]; then
    # EPH-I0634: take the first hint only (a multi-line SUGGESTED breaks
    # the sed script below) and require at least one hex digit (a bare 0x
    # would write a broken zon). BSD grep supports -m1 as GNU grep does.
    # EPH-I1291: zig 0.16.0 emits two hint shapes — "use this value" for
    # the 0x0 placeholder and "suggested value" for the missing field —
    # so the pattern accepts both.
    SUGGESTED=$(printf '%s\n' "$FETCH_OUT" \
        | grep -m1 -oE '(use this value|suggested value): 0x[0-9a-f][0-9a-f]*' \
        | sed -E 's/(use this value|suggested value): //')
    if [ -z "$SUGGESTED" ]; then
        # No hint means a real fetch failure (network, hash, server). Show
        # the captured error and keep the original exit code.
        printf '%s\n' "$FETCH_OUT" >&2
        exit "$FETCH_RC"
    fi
    # EPH-I1272: repair the fingerprint only at a code position. The
    # pre-fix sed rewrote the first match per line, so a string value
    # that mentions ".fingerprint = 0x0" on the same line won and the
    # real field stayed 0x0 (a corrupted zon plus a failed fetch). The
    # awk walk mirrors find_install_artifact_line: string literals mask
    # their content, a // comment ends the line's code, a \\-led
    # multiline body line is string data, and a mid-line \\ opener
    # consumes the rest of the line as string data (EPH-I1283, the
    # Zig-side EPH-I0671 semantics). The first code-position marker wins
    # the repair; a code-position fingerprint with any other value fails
    # with the clear message (install.ps1 EPH-I0648 parity).
    # EPH-I1291: a zon with no code-position fingerprint field gains one
    # right after the root struct opener (the first code-position brace),
    # the shape zig 0.16.0 answers with "missing top-level 'fingerprint'
    # field; suggested value: 0x<hex>". The live WP-7 leg failed on this
    # shape before the arm landed.
    make_install_tmp ./build.zig.zon.tmp.XXXXXXXX
    if awk -v hint="$SUGGESTED" -f - build.zig.zon > "$INSTALL_TMP" <<'AWKEOF'
{
    lines[++nr] = $0
}
END {
    replaced = 0
    has_fp = 0
    open_line = 0
    open_col = 0
    open_indent = ""
    for (ln = 1; ln <= nr && !replaced; ln++) {
        line = lines[ln]
        n = length(line)
        i = 1
        while (i <= n && substr(line, i, 1) == " ") i = i + 1
        while (i <= n && substr(line, i, 1) == "\t") i = i + 1
        line_indent = substr(line, 1, i - 1)
        if (i <= n && substr(line, i, 1) == "\\") continue
        in_str = 0
        while (i <= n) {
            c = substr(line, i, 1)
            if (in_str) {
                if (c == "\\") i = i + 1
                else if (c == "\"") in_str = 0
                i = i + 1
                continue
            }
            if (c == "\"") { in_str = 1; i = i + 1; continue }
            if (c == "/" && substr(line, i + 1, 1) == "/") break
            if (c == "\\" && substr(line, i + 1, 1) == "\\") break
            if (c == "{" && open_line == 0) {
                open_line = ln
                open_col = i
                open_indent = line_indent
            }
            if (substr(line, i, 18) == ".fingerprint = 0x0") {
                lines[ln] = substr(line, 1, i - 1) ".fingerprint = " hint substr(line, i + 18)
                replaced = 1
                break
            }
            if (substr(line, i, 12) == ".fingerprint" &&
                substr(line, i + 12, 1) !~ /[A-Za-z0-9_]/) has_fp = 1
            i = i + 1
        }
    }
    if (!replaced) {
        if (has_fp || open_line == 0) exit 1
        rest = substr(lines[open_line], open_col + 1)
        blank = rest
        gsub(/[[:space:]]/, "", blank)
        if (blank == "") {
            for (ln = nr; ln > open_line; ln--) lines[ln + 1] = lines[ln]
            lines[open_line + 1] = open_indent "    .fingerprint = " hint ","
            nr = nr + 1
        } else {
            lines[open_line] = substr(lines[open_line], 1, open_col) " .fingerprint = " hint ", " rest
        }
    }
    for (ln = 1; ln <= nr; ln++) print lines[ln]
}
AWKEOF
    then
        mv "$INSTALL_TMP" build.zig.zon
        INSTALL_TMP=""
    else
        printf '%s\n' "$FETCH_OUT" >&2
        echo "error: could not repair the fingerprint in build.zig.zon." >&2
        echo "The .fingerprint field does not match the 0x0 placeholder." >&2
        echo "Set it to the value zig printed above, then re-run the install." >&2
        exit 1
    fi
    # This fetch is authoritative: a failure aborts the install under set -e.
    zig fetch --save=ephor "$EPHOR_URL"
fi

# Canonical ephor block for build.zig (single source of truth)
EPHOR_BLOCK='
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
    ephor_upgrade_step.dependOn(&ephor_upgrade_cmd.step);'

# Refuse the splice and stop the install. The installer never guesses
# when the markers do not describe one unambiguous block
# (EPH-I0625/26/28). The argument names the problem.
refuse_block_splice() {
    echo "warning: $1" >&2
    echo "The ephor build steps in build.zig were not updated." >&2
    echo "Update them manually (see the ephor README)." >&2
    exit 1
}

# Fail closed when the marker pair does not describe exactly one block:
# a missing marker, more than one of either marker, or an end line that
# is not after the start line (EPH-I0626/28). Arguments: start line,
# start count, end line, end count.
validate_marker_pair() {
    if [ -z "$1" ] || [ -z "$3" ]; then
        refuse_block_splice "the ephor block in build.zig is missing one of its markers."
    fi
    if [ "$2" -gt 1 ] || [ "$4" -gt 1 ]; then
        refuse_block_splice "build.zig has more than one ephor block marker."
    fi
    if [ "$3" -le "$1" ]; then
        refuse_block_splice "the ephor block markers in build.zig are out of order."
    fi
}

# True (exit 0) when the block span between the start and end marker
# lines holds its dependency line. A marker pair without it is drifted
# or forged, and replacing it would delete the code in between
# (EPH-I0625/26). Arguments: start line, end line.
# EPH-I1106 decision: this grep stays unanchored, unlike the action and
# layout probes. The span's endpoints are themselves anchored
# code-context markers, and the check's job is to confirm the span
# holds the dependency line before the whole span is replaced with the
# canonical block. The unanchored form accepts every real block shape,
# including a reformatted dependency call whose continuation line starts
# with ".", which the DEP_PROBE idiom would miss and then falsely
# refuse. A comment mention inside a marker-bounded span still lets the
# splice restore the canonical block, the intended upgrade outcome; the
# forged-marker residual needs an attacker to plant the anchored
# end-marker code line, at which point the file is already attacker
# content.
span_has_dependency_line() {
    sed -n "$1,$(( $2 - 1 ))p" build.zig | grep -q 'dependency("ephor"'
}

# Print the 1-based line number of the last code-position installArtifact
# mention in build.zig, or nothing when none exists (EPH-I0715). The awk
# walk tracks string and char literals and stops at // comments and \\
# multiline tails, so a mention inside a string or a comment cannot win
# the insertion anchor. A trailing inline comment after the real call
# still anchors that call correctly: the walk breaks at // after it has
# seen the code-position mention. The first non-space char gate keeps
# the EPH-I0626 code-line idiom: a line that opens with // or \\, or a
# `.`-led field line, is data, not a call. The masked-semicolon limit
# lives in the terminator scan below, not here (EPH-I1106 shares it
# with the DEP_PROBE idiom).
find_install_artifact_line() {
    awk -f - build.zig <<'AWKEOF'
{
    line = $0
    n = length(line)
    if (index(line, "installArtifact") == 0) next
    i = 1
    while (i <= n && substr(line, i, 1) == " ") i = i + 1
    while (i <= n && substr(line, i, 1) == "\t") i = i + 1
    if (i > n) next
    first = substr(line, i, 1)
    if (first == "/" || first == "\\" || first == ".") next
    in_str = 0
    in_char = 0
    while (i <= n) {
        c = substr(line, i, 1)
        if (in_str) {
            if (c == "\\") i = i + 1
            else if (c == "\"") in_str = 0
            i = i + 1
            continue
        }
        if (in_char) {
            if (c == "\\") i = i + 1
            else if (c == "'") in_char = 0
            i = i + 1
            continue
        }
        if (c == "\"") { in_str = 1; i = i + 1; continue }
        if (c == "'") { in_char = 1; i = i + 1; continue }
        if (c == "/" && substr(line, i + 1, 1) == "/") break
        if (c == "\\" && substr(line, i + 1, 1) == "\\") break
        if (substr(line, i, 15) == "installArtifact") {
            last_line = NR
            i = i + 15
            continue
        }
        i = i + 1
    }
}
END { if (last_line != "") print last_line }
AWKEOF
}

# The anchored marker patterns for the block splice (EPH-I0625). Each
# start marker requires the canonical four-space indent (or deeper),
# and each end marker must sit at line start in code context: a line
# that begins with // or \\ cannot match, and a match that follows
# other tokens cannot match. Same anchoring as the Zig-side gate
# (EPH-I0168).
CANON_START='^[[:space:]]*    // Ephor static analysis'
CANON_END='^[[:space:]]*ephor_upgrade_step\.dependOn\(&ephor_upgrade_cmd\.step\);'
LEGACY_START='^[[:space:]]*    // === Ephor Static Analysis ==='
LEGACY_END='^[[:space:]]*ephor_step\.dependOn\(&b\.addRunArtifact\(ephor_exe\)\.step\);'

# EPH-I1159: each branch condition fires on the start OR the end
# marker, mirroring install.ps1. A truncated block whose start marker
# (and dependency line) the user deleted but whose end lines remain
# then lands here, where the empty start line makes the marker-pair
# validation refuse instead of falling through to the fresh-install
# splice and redeclaring the retained end lines.
if grep -qE "$CANON_START" build.zig || grep -qE "$CANON_END" build.zig; then
    # Ephor block exists - replace it with the canonical version.
    # EPH-I0625: the markers anchor like the Zig-side upgrade gate
    # (EPH-I0168). The old unanchored grep took the first match
    # anywhere, so a doc comment quoting the marker pointed the splice
    # at the comment and deleted the code between it and the real
    # block.
    # EPH-I0639: the splice line numbers are read here and written
    # later, so a concurrent edit to build.zig in that window can
    # misalign the splice. The risk is accepted: the installer runs
    # once, and a corrupt splice fails the next zig build loudly. The
    # same window applies to every splice branch below.
    START_LINE=$(grep -nE "$CANON_START" build.zig | head -1 | cut -d: -f1)
    END_LINE=$(grep -nE "$CANON_END" build.zig | head -1 | cut -d: -f1)
    START_COUNT=$(grep -cE "$CANON_START" build.zig | cat)
    END_COUNT=$(grep -cE "$CANON_END" build.zig | cat)
    validate_marker_pair "$START_LINE" "$START_COUNT" "$END_LINE" "$END_COUNT"
    if ! span_has_dependency_line "$START_LINE" "$END_LINE"; then
        refuse_block_splice "the ephor block in build.zig has no dependency line."
    fi
    # Absorb every consecutive blank line above the block (EPH-I0060):
    # EPHOR_BLOCK's leading newline re-creates exactly one, so the loop
    # converges any run of N>=1 blanks to the canonical single blank on
    # the next re-run. The pre-fix single-step absorb left files already
    # damaged by the buggy installer at their N>=2 count forever (absorb
    # one, re-add one, fixed point).
    while [ "$START_LINE" -gt 1 ] && [ -z "$(sed -n "$((START_LINE - 1))p" build.zig)" ]; do
        START_LINE=$((START_LINE - 1))
    done
    # head -n 0 is fatal on BSD ("illegal line count") — a line-1 block
    # has nothing above it to keep.
    make_install_tmp ./build.zig.tmp.XXXXXXXX
    if [ "$START_LINE" -gt 1 ]; then
        head -n "$((START_LINE - 1))" build.zig > "$INSTALL_TMP"
    fi
    echo "$EPHOR_BLOCK" >> "$INSTALL_TMP"
    tail -n +"$((END_LINE + 1))" build.zig >> "$INSTALL_TMP"
    preserve_mode build.zig
    mv "$INSTALL_TMP" build.zig
    INSTALL_TMP=""
    echo "Updated ephor build steps in build.zig"
elif grep -qE "$LEGACY_START" build.zig || grep -qE "$LEGACY_END" build.zig; then
    # Old v0.11.x snippet - replace with canonical block. The markers
    # anchor and validate the same way as the canonical branch
    # (EPH-I0625/26/28, EPH-I1159).
    START_LINE=$(grep -nE "$LEGACY_START" build.zig | head -1 | cut -d: -f1)
    END_LINE=$(grep -nE "$LEGACY_END" build.zig | head -1 | cut -d: -f1)
    START_COUNT=$(grep -cE "$LEGACY_START" build.zig | cat)
    END_COUNT=$(grep -cE "$LEGACY_END" build.zig | cat)
    validate_marker_pair "$START_LINE" "$START_COUNT" "$END_LINE" "$END_COUNT"
    if ! span_has_dependency_line "$START_LINE" "$END_LINE"; then
        refuse_block_splice "the ephor block in build.zig has no dependency line."
    fi
    # Absorb every consecutive blank line above the block (EPH-I0060,
    # same convergence as the canonical branch: the v0.11.x snippet was
    # also inserted with a leading blank line).
    while [ "$START_LINE" -gt 1 ] && [ -z "$(sed -n "$((START_LINE - 1))p" build.zig)" ]; do
        START_LINE=$((START_LINE - 1))
    done
    # head -n 0 is fatal on BSD ("illegal line count") — a line-1 block
    # has nothing above it to keep.
    make_install_tmp ./build.zig.tmp.XXXXXXXX
    if [ "$START_LINE" -gt 1 ]; then
        head -n "$((START_LINE - 1))" build.zig > "$INSTALL_TMP"
    fi
    echo "$EPHOR_BLOCK" >> "$INSTALL_TMP"
    tail -n +"$((END_LINE + 1))" build.zig >> "$INSTALL_TMP"
    preserve_mode build.zig
    mv "$INSTALL_TMP" build.zig
    INSTALL_TMP=""
    echo "Updated ephor build steps in build.zig (migrated from v0.11.x snippet)"
elif grep -qE "$DEP_PROBE" build.zig; then
    # EPH-I1106: the probe anchors to code lines exactly like the action
    # probe above, so a comment that mentions the dependency no longer
    # misroutes a fresh install into this branch. The trailing-inline
    # comment limit is shared and recorded at the DEP_PROBE definition.
    # Has dependency but non-standard block layout - leave it, warn user
    # EPH-I1110: the warning pair prints to stderr like every other
    # warning in this script, matching install.ps1's Write-Stderr pair.
    echo "warning: ephor dependency found but build steps have non-standard layout" >&2
    echo "Please update your ephor build steps manually (see README)" >&2
else
    # Fresh install - add the block after the last installArtifact
    # statement. EPH-I0626: the search anchors to code lines, so a
    # comment that mentions installArtifact cannot win. The insert line
    # extends forward to the statement terminator, so a multi-line call
    # is not split. Boundaries: a statement body that carries a
    # semicolon on its own line (a labeled block) ends the scan early.
    # A trailing line comment after the terminator
    # (b.installArtifact(exe); // note) masks the semicolon match: the
    # block then lands after the next semicolon line, which is still
    # valid Zig, or the install refuses when no semicolon line follows.
    # EPH-I0715: the anchor scan is quote- and comment-aware
    # (find_install_artifact_line), so a mention inside a string or a
    # comment below the real call cannot win. The composed file must
    # pass zig ast-check before it replaces the live one — the same
    # gate the Zig side runs (EPH-I0512) — so any anchor shape that
    # still corrupts the file fails the install instead of writing a
    # broken build.zig.
    echo "Adding ephor build steps to build.zig..."

    LINE=$(find_install_artifact_line)

    if [ -z "$LINE" ]; then
        # EPH-I0635: the dependency landed but the build steps did not.
        # Exit nonzero so CI does not mistake a partial install for success.
        echo "warning: could not find installArtifact in build.zig" >&2
        echo "The ephor dependency was added, but the build steps were not." >&2
        echo "Add the build steps manually (see README)." >&2
        exit 1
    fi

    OFFSET=$(tail -n +"$LINE" build.zig | grep -nE ';[[:space:]]*$' | head -1 | cut -d: -f1)
    if [ -z "$OFFSET" ]; then
        echo "warning: the installArtifact statement does not end before the end of build.zig." >&2
        echo "The ephor build steps were not added." >&2
        echo "Add them manually (see README)." >&2
        exit 1
    fi

    INSERT_AT=$((LINE + OFFSET - 1))
    make_install_tmp ./build.zig.tmp.XXXXXXXX
    head -n "$INSERT_AT" build.zig > "$INSTALL_TMP"
    echo "$EPHOR_BLOCK" >> "$INSTALL_TMP"
    tail -n +"$((INSERT_AT + 1))" build.zig >> "$INSTALL_TMP"
    # EPH-I0715: the composed file must pass zig ast-check before it
    # replaces the live one (the Zig-side EPH-I0512 gate). ast-check
    # resolves names too, so the gate also proves the block's `target`
    # name stays in scope. On failure the original stays untouched and
    # the EXIT trap removes the temp file.
    if ! zig ast-check "$INSTALL_TMP" >/dev/null 2>&1; then
        echo "warning: the composed build.zig failed zig ast-check." >&2
        echo "The ephor build steps were not added." >&2
        echo "Add them manually (see README)." >&2
        exit 1
    fi
    preserve_mode build.zig
    mv "$INSTALL_TMP" build.zig
    INSTALL_TMP=""
fi

echo ""
echo "Done!"
echo ""
echo "  zig build ephor              (run static analysis)"
echo "  zig build ephor-upgrade      (upgrade to latest version)"
