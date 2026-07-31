#!/bin/sh
# Ephor installer - adds ephor to your Zig project
# Usage: curl -fsSL https://codeberg.org/RhyosLabs/ephor/raw/branch/main/install.sh | sh

# pipefail is not portable to POSIX sh (dash), so each fallible command
# handles its own exit status explicitly.
set -eu

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
# Print the newest stable release tag on stdout. Return 1 when the API
# fails, the result is empty, or no tag is a strict vMAJOR.MINOR.PATCH.
latest_ephor_tag() {
    # 30s: the Codeberg API has answered in 20s+ on slow days; refusals still fail fast.
    response=$(curl -fsSL --max-time 30 "$TAGS_API" 2>/dev/null) || return 1
    tag=$(printf '%s\n' "$response" | grep -o '"name": *"[^"]*"' | cut -d'"' -f4 \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
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
    fi
    printf '%s\n' "$tag"
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
    PROJECT_NAME=$(basename "$(pwd)" | tr '-' '_' | tr '[:upper:]' '[:lower:]')
    echo "No build.zig.zon found, creating one..."
    cat > build.zig.zon << ZONEOF
.{
    .name = .${PROJECT_NAME},
    .version = "0.0.0",
    .fingerprint = 0x0,
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
ZONEOF
    # Zig computes the correct fingerprint - capture it
    SUGGESTED=$(zig build 2>&1 | grep -o 'use this value: 0x[0-9a-f]*' | sed 's/use this value: //')
    if [ -n "$SUGGESTED" ]; then
        sed -i.bak "s/\.fingerprint = 0x0/.fingerprint = ${SUGGESTED}/" build.zig.zon
        rm -f build.zig.zon.bak
    fi
    echo "Created build.zig.zon for project '${PROJECT_NAME}'"
fi

# Detect Zig version and pick compatible ephor version
ZIG_VERSION=$(zig version 2>/dev/null || echo "")
EPHOR_URL=""
if [ -n "$ZIG_VERSION" ]; then
    ZIG_MAJOR=$(echo "$ZIG_VERSION" | cut -d. -f1)
    ZIG_MINOR=$(echo "$ZIG_VERSION" | cut -d. -f2)
    # Zig 0.16.0 and later track the latest ephor release. Zig 0.15.x uses
    # the pinned 0.15-era release by commit hash.
    if [ "$ZIG_MAJOR" -gt 0 ] || [ "$ZIG_MINOR" -ge 16 ]; then
        EPHOR_TAG=$(resolve_ephor_tag)
    else
        EPHOR_TAG="v0.11.13"
        EPHOR_URL="${REPO}/archive/${EPHOR_0_15_COMMIT}.tar.gz"
    fi
else
    echo "warning: could not detect zig version, defaulting to latest"
    EPHOR_TAG=$(resolve_ephor_tag)
fi

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
    EPHOR_URL="${REPO}/archive/${EPHOR_TAG}.tar.gz"
fi

echo "Adding ephor dependency..."
zig fetch --save=ephor "$EPHOR_URL"

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

if grep -q '// Ephor static analysis' build.zig; then
    # Ephor block exists - replace it with the canonical version
    START_LINE=$(grep -n '// Ephor static analysis' build.zig | head -1 | cut -d: -f1)
    END_LINE=$(grep -n 'ephor_upgrade_step\.dependOn' build.zig | head -1 | cut -d: -f1)

    if [ -n "$START_LINE" ] && [ -n "$END_LINE" ]; then
        # Absorb a pre-existing blank line above the block: EPHOR_BLOCK's
        # leading newline re-creates exactly one, so keeping one here too
        # would grow build.zig by one blank line per re-run.
        if [ "$START_LINE" -gt 1 ] && [ -z "$(sed -n "$((START_LINE - 1))p" build.zig)" ]; then
            START_LINE=$((START_LINE - 1))
        fi
        # head -n 0 is fatal on BSD ("illegal line count") — a line-1 block
        # has nothing above it to keep.
        if [ "$START_LINE" -gt 1 ]; then
            head -n "$((START_LINE - 1))" build.zig > build.zig.tmp
        else
            : > build.zig.tmp
        fi
        echo "$EPHOR_BLOCK" >> build.zig.tmp
        tail -n +"$((END_LINE + 1))" build.zig >> build.zig.tmp
        mv build.zig.tmp build.zig
        echo "Updated ephor build steps in build.zig"
    fi
elif grep -q '=== Ephor Static Analysis ===' build.zig; then
    # Old v0.11.x snippet - replace with canonical block
    START_LINE=$(grep -n '=== Ephor Static Analysis ===' build.zig | head -1 | cut -d: -f1)
    END_LINE=$(grep -n 'ephor_step\.dependOn(&b.addRunArtifact(ephor_exe).step);' build.zig | head -1 | cut -d: -f1)

    if [ -n "$START_LINE" ] && [ -n "$END_LINE" ]; then
        # Absorb a pre-existing blank line above the block (same leak as the
        # canonical branch: the v0.11.x snippet was also inserted with a
        # leading blank line).
        if [ "$START_LINE" -gt 1 ] && [ -z "$(sed -n "$((START_LINE - 1))p" build.zig)" ]; then
            START_LINE=$((START_LINE - 1))
        fi
        # head -n 0 is fatal on BSD ("illegal line count") — a line-1 block
        # has nothing above it to keep.
        if [ "$START_LINE" -gt 1 ]; then
            head -n "$((START_LINE - 1))" build.zig > build.zig.tmp
        else
            : > build.zig.tmp
        fi
        echo "$EPHOR_BLOCK" >> build.zig.tmp
        tail -n +"$((END_LINE + 1))" build.zig >> build.zig.tmp
        mv build.zig.tmp build.zig
        echo "Updated ephor build steps in build.zig (migrated from v0.11.x snippet)"
    fi
elif grep -q 'dependency("ephor"' build.zig; then
    # Has dependency but non-standard block layout - leave it, warn user
    echo "warning: ephor dependency found but build steps have non-standard layout"
    echo "Please update your ephor build steps manually (see README)"
else
    # Fresh install - add the block after the last installArtifact
    echo "Adding ephor build steps to build.zig..."

    LINE=$(grep -n "installArtifact" build.zig | tail -1 | cut -d: -f1)

    if [ -z "$LINE" ]; then
        echo "Warning: Could not find installArtifact in build.zig"
        echo "Please add the ephor build steps manually (see README)"
        exit 0
    fi

    head -n "$LINE" build.zig > build.zig.tmp
    echo "$EPHOR_BLOCK" >> build.zig.tmp
    tail -n +"$((LINE + 1))" build.zig >> build.zig.tmp
    mv build.zig.tmp build.zig
fi

echo ""
echo "Done!"
echo ""
echo "  zig build ephor              (run static analysis)"
echo "  zig build ephor-upgrade      (upgrade to latest version)"
