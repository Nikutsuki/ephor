#!/bin/sh
# Ephor installer - adds ephor to your Zig project
# Usage: curl -fsSL https://codeberg.org/RhyosLabs/ephor/raw/branch/main/install.sh | sh

# pipefail is not portable to POSIX sh (dash), so each fallible command
# handles its own exit status explicitly.
set -eu

# EPH-I0194: a cloned repo can plant a symlink at a fixed temp name such as
# build.zig.tmp. A ">" redirect follows the symlink and overwrites the
# target. Every writer below uses mktemp, whose name cannot exist yet, and
# mv, whose rename replaces a planted symlink instead of following it. The
# trap removes the temp file when the script exits before the mv.
INSTALL_TMP=""
trap '[ -z "$INSTALL_TMP" ] || rm -f "$INSTALL_TMP"' EXIT

# Create the swap file for the next mktemp+mv write and publish its path in
# INSTALL_TMP for the EXIT trap. mktemp makes the file 0600, but the files
# this script replaces came from a ">" redirect at 0666 & ~umask. Restore
# that mode so the install does not tighten project files to 0600.
make_install_tmp() {
    INSTALL_TMP=$(mktemp "$1")
    chmod "$(printf '%03o' $((0666 & ~$(umask))))" "$INSTALL_TMP"
}

REPO="https://codeberg.org/RhyosLabs/ephor"
# Tests override this URL through EPHOR_TAGS_API to simulate an API failure.
TAGS_API="${EPHOR_TAGS_API:-https://codeberg.org/api/v1/repos/RhyosLabs/ephor/tags?limit=10}"
# This tag is the fallback when the Codeberg tags API fails. Refresh it on every release.
EPHOR_FALLBACK_TAG="v0.14.2"
# Pin for Zig 0.15.x. Every remote tag (v0.12.3 and later) declares
# minimum_zig_version 0.16.0. The 0.16 migration landed in v0.12.0, so no
# remote tag builds on Zig 0.15.x. v0.11.13 declares minimum_zig_version
# 0.15.0 and is the newest 0.15-era release. Its tag is deleted on the
# remote, so pin the commit hash. Commit archives stay available.
EPHOR_0_15_COMMIT="60145fe05a2b91e7dd32d1c671d98239cd19aea6"

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
    # fetch into a local file read or spew an unbounded body. The
    # EPHOR_TAGS_API test channel (file://, http://) skips the clamp: the
    # operator picks that URL, and the strict-tag filter below still gates
    # the result. The word split of $proto_flags is intentional.
    proto_flags=""
    case "$TAGS_API" in
        https://*) proto_flags="--proto =https --proto-redir =https --max-filesize 1048576" ;;
    esac
    response=$(curl -fsSL --max-time 30 $proto_flags "$TAGS_API" 2>/dev/null) || return 1
    tag=$(printf '%s\n' "$response" | grep -o '"name": *"[^"]*"' | cut -d'"' -f4 \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | max_stable_tag)
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

# Check we're in a Zig project
if [ ! -f "build.zig" ]; then
    echo "error: no build.zig found in current directory"
    echo ""
    echo "  Ephor requires a Zig project with build.zig and build.zig.zon."
    echo "  To initialize a Zig project, run:"
    echo ""
    echo "    zig init"
    echo ""
    echo "  Then re-run the install:"
    echo "    curl -fsSL ${REPO}/raw/branch/main/install.sh | sh"
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
    case "$PROJECT_NAME" in
        ''|*[!a-z0-9_]*|[0-9]*)
            SANITIZED=$(printf '%s' "$PROJECT_NAME" | tr -c 'a-z0-9_' '_')
            case "$SANITIZED" in
                [0-9]*) SANITIZED="_${SANITIZED}" ;;
            esac
            NAME_EXPR=".${SANITIZED}"
            echo "warning: '${PROJECT_NAME}' is not a valid Zig identifier for the zon name." >&2
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
    echo "Created build.zig.zon for project '${PROJECT_NAME}'"
fi

# Detect Zig version and pick compatible ephor version
ZIG_VERSION=$(zig version 2>/dev/null || echo "")
EPHOR_URL=""
# EPH-I0630: the integer tests below need numeric components. The old
# code tested unparsed version text, printed two "Illegal number" lines
# on garbage, and silently pinned the 0.15-era release even on systems
# running Zig 0.16+. The case globs gate the tests: a non-numeric
# version counts as undetectable and takes the latest-tag path with a
# warning. Real zig version output always has two dots.
case "$ZIG_VERSION" in
    [0-9]*.[0-9]*.*)
        ZIG_MAJOR=$(printf '%s\n' "$ZIG_VERSION" | cut -d. -f1)
        ZIG_MINOR=$(printf '%s\n' "$ZIG_VERSION" | cut -d. -f2)
        # Zig 0.16.0 and later track the latest ephor release. Zig 0.15.x
        # uses the pinned 0.15-era release by commit hash.
        if [ "$ZIG_MAJOR" -gt 0 ] || [ "$ZIG_MINOR" -ge 16 ]; then
            EPHOR_TAG=$(resolve_ephor_tag)
        else
            EPHOR_TAG="v0.11.13"
            EPHOR_URL="${REPO}/archive/${EPHOR_0_15_COMMIT}.tar.gz"
        fi
        ;;
    '')
        echo "warning: could not detect zig version, defaulting to latest" >&2
        EPHOR_TAG=$(resolve_ephor_tag)
        ;;
    *)
        echo "warning: could not parse the zig version '${ZIG_VERSION}', defaulting to latest" >&2
        EPHOR_TAG=$(resolve_ephor_tag)
        ;;
esac

# Detect if this is an upgrade or fresh install
if grep -q 'dependency("ephor"' build.zig 2>/dev/null || grep -q '"ephor"' build.zig.zon 2>/dev/null; then
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
    # Tests override the archive URL through EPHOR_ARCHIVE_URL.
    EPHOR_URL="${EPHOR_ARCHIVE_URL:-${REPO}/archive/${EPHOR_TAG}.tar.gz}"
fi

echo "Adding ephor dependency..."
# EPH-I0192: zig fetch reads build.zig.zon but never runs build.zig, so a
# hostile build.zig still executes no code here. On a fresh zon with
# fingerprint 0x0, zig fetch fails and prints a "use this value" hint with
# the computed fingerprint. Patch the hint in and fetch again.
FETCH_OUT=$(zig fetch --save=ephor "$EPHOR_URL" 2>&1) && FETCH_RC=0 || FETCH_RC=$?
if [ "$FETCH_RC" -ne 0 ]; then
    SUGGESTED=$(printf '%s\n' "$FETCH_OUT" | grep -o 'use this value: 0x[0-9a-f]*' \
        | sed 's/use this value: //')
    if [ -z "$SUGGESTED" ]; then
        # No hint means a real fetch failure (network, hash, server). Show
        # the captured error and keep the original exit code.
        printf '%s\n' "$FETCH_OUT" >&2
        exit "$FETCH_RC"
    fi
    sed -i.bak "s/\.fingerprint = 0x0/.fingerprint = ${SUGGESTED}/" build.zig.zon
    rm -f build.zig.zon.bak
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
span_has_dependency_line() {
    sed -n "$1,$(( $2 - 1 ))p" build.zig | grep -q 'dependency("ephor"'
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

if grep -qE "$CANON_START" build.zig; then
    # Ephor block exists - replace it with the canonical version.
    # EPH-I0625: the markers anchor like the Zig-side upgrade gate
    # (EPH-I0168). The old unanchored grep took the first match
    # anywhere, so a doc comment quoting the marker pointed the splice
    # at the comment and deleted the code between it and the real
    # block.
    START_LINE=$(grep -nE "$CANON_START" build.zig | head -1 | cut -d: -f1)
    END_LINE=$(grep -nE "$CANON_END" build.zig | head -1 | cut -d: -f1)
    START_COUNT=$(grep -cE "$CANON_START" build.zig | cat)
    END_COUNT=$(grep -cE "$CANON_END" build.zig | cat)
    validate_marker_pair "$START_LINE" "$START_COUNT" "$END_LINE" "$END_COUNT"
    if ! span_has_dependency_line "$START_LINE" "$END_LINE"; then
        refuse_block_splice "the ephor block in build.zig has no dependency line."
    fi
    # Absorb a pre-existing blank line above the block: EPHOR_BLOCK's
    # leading newline re-creates exactly one, so keeping one here too
    # would grow build.zig by one blank line per re-run.
    if [ "$START_LINE" -gt 1 ] && [ -z "$(sed -n "$((START_LINE - 1))p" build.zig)" ]; then
        START_LINE=$((START_LINE - 1))
    fi
    # head -n 0 is fatal on BSD ("illegal line count") — a line-1 block
    # has nothing above it to keep.
    make_install_tmp ./build.zig.tmp.XXXXXXXX
    if [ "$START_LINE" -gt 1 ]; then
        head -n "$((START_LINE - 1))" build.zig > "$INSTALL_TMP"
    fi
    echo "$EPHOR_BLOCK" >> "$INSTALL_TMP"
    tail -n +"$((END_LINE + 1))" build.zig >> "$INSTALL_TMP"
    mv "$INSTALL_TMP" build.zig
    INSTALL_TMP=""
    echo "Updated ephor build steps in build.zig"
elif grep -qE "$LEGACY_START" build.zig; then
    # Old v0.11.x snippet - replace with canonical block. The markers
    # anchor and validate the same way as the canonical branch
    # (EPH-I0625/26/28).
    START_LINE=$(grep -nE "$LEGACY_START" build.zig | head -1 | cut -d: -f1)
    END_LINE=$(grep -nE "$LEGACY_END" build.zig | head -1 | cut -d: -f1)
    START_COUNT=$(grep -cE "$LEGACY_START" build.zig | cat)
    END_COUNT=$(grep -cE "$LEGACY_END" build.zig | cat)
    validate_marker_pair "$START_LINE" "$START_COUNT" "$END_LINE" "$END_COUNT"
    if ! span_has_dependency_line "$START_LINE" "$END_LINE"; then
        refuse_block_splice "the ephor block in build.zig has no dependency line."
    fi
    # Absorb a pre-existing blank line above the block (same leak as the
    # canonical branch: the v0.11.x snippet was also inserted with a
    # leading blank line).
    if [ "$START_LINE" -gt 1 ] && [ -z "$(sed -n "$((START_LINE - 1))p" build.zig)" ]; then
        START_LINE=$((START_LINE - 1))
    fi
    # head -n 0 is fatal on BSD ("illegal line count") — a line-1 block
    # has nothing above it to keep.
    make_install_tmp ./build.zig.tmp.XXXXXXXX
    if [ "$START_LINE" -gt 1 ]; then
        head -n "$((START_LINE - 1))" build.zig > "$INSTALL_TMP"
    fi
    echo "$EPHOR_BLOCK" >> "$INSTALL_TMP"
    tail -n +"$((END_LINE + 1))" build.zig >> "$INSTALL_TMP"
    mv "$INSTALL_TMP" build.zig
    INSTALL_TMP=""
    echo "Updated ephor build steps in build.zig (migrated from v0.11.x snippet)"
elif grep -q 'dependency("ephor"' build.zig; then
    # Has dependency but non-standard block layout - leave it, warn user
    echo "warning: ephor dependency found but build steps have non-standard layout"
    echo "Please update your ephor build steps manually (see README)"
else
    # Fresh install - add the block after the last installArtifact
    # statement. EPH-I0626: the search anchors to code lines, so a
    # comment that mentions installArtifact cannot win. The insert line
    # extends forward to the statement terminator, so a multi-line call
    # is not split. Boundary: a statement body that carries a semicolon
    # on its own line (a labeled block) ends the scan early.
    echo "Adding ephor build steps to build.zig..."

    LINE=$(grep -nE '^[[:space:]]*[^/.\\[:space:]].*installArtifact' build.zig \
        | tail -1 | cut -d: -f1)

    if [ -z "$LINE" ]; then
        echo "warning: could not find installArtifact in build.zig"
        echo "Please add the ephor build steps manually (see README)"
        exit 0
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
    mv "$INSTALL_TMP" build.zig
    INSTALL_TMP=""
fi

echo ""
echo "Done!"
echo ""
echo "  zig build ephor              (run static analysis)"
echo "  zig build ephor-upgrade      (upgrade to latest version)"
