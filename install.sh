#!/bin/sh
# Ephor installer - adds ephor to your Zig project
# Usage: curl -fsSL https://codeberg.org/RhyosLabs/ephor/raw/branch/main/install.sh | sh

set -e

REPO="https://codeberg.org/RhyosLabs/ephor"

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
    echo "    curl -fsSL ${REPO}/raw/main/install.sh | sh"
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
if [ -n "$ZIG_VERSION" ]; then
    ZIG_MAJOR=$(echo "$ZIG_VERSION" | cut -d. -f1)
    ZIG_MINOR=$(echo "$ZIG_VERSION" | cut -d. -f2)
    # Zig 0.16.0+ → ephor 0.12.x; Zig 0.15.x → ephor 0.11.13
    if [ "$ZIG_MAJOR" -gt 0 ] || [ "$ZIG_MINOR" -ge 16 ]; then
        EPHOR_TAG="v0.12.4"
    else
        EPHOR_TAG="v0.11.13"
    fi
else
    echo "warning: could not detect zig version, defaulting to latest"
    # Fetch latest tagged version from Codeberg tags API
    TAGS_API="https://codeberg.org/api/v1/repos/RhyosLabs/ephor/tags?limit=1"
    LATEST_TAG=$(curl -sL "$TAGS_API" | grep -o '"name": "v[0-9.]*"' | head -1 | sed 's/.*"v\([0-9.]*\)".*/\1/')
    EPHOR_TAG="v${LATEST_TAG}"
fi

# Detect if this is an upgrade or fresh install
if grep -q 'dependency("ephor"' build.zig 2>/dev/null || grep -q '"ephor"' build.zig.zon 2>/dev/null; then
    ACTION="Upgrading"
else
    ACTION="Installing"
fi

if [ -z "$EPHOR_TAG" ] || [ "$EPHOR_TAG" = "v" ]; then
    echo "warning: could not detect ephor version, using main branch"
    EPHOR_URL="${REPO}/archive/main.tar.gz"
else
    echo "${ACTION} ephor ${EPHOR_TAG} (Zig ${ZIG_VERSION})..."
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
        head -n "$((START_LINE - 1))" build.zig > build.zig.tmp
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
        head -n "$((START_LINE - 1))" build.zig > build.zig.tmp
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
