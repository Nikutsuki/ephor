#!/bin/sh
# Ephor installer - adds ephor to your Zig project
# Usage: curl -fsSL https://bitbucket.org/rhyoslabs/ephor/raw/main/install.sh | sh

set -e

REPO="https://bitbucket.org/rhyoslabs/ephor"

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

# Fetch latest tagged version from Bitbucket tags API (not cached raw files)
TAGS_API="https://api.bitbucket.org/2.0/repositories/rhyoslabs/ephor/refs/tags?sort=-target.date&pagelen=1"
LATEST_TAG=$(curl -sL "$TAGS_API" | grep -o '"name": "v[0-9.]*"' | head -1 | sed 's/.*"v\([0-9.]*\)".*/\1/')

if [ -z "$LATEST_TAG" ]; then
    echo "warning: could not detect latest version, using main branch"
    EPHOR_URL="${REPO}/get/main.tar.gz"
else
    echo "Installing ephor v${LATEST_TAG}..."
    EPHOR_URL="${REPO}/get/v${LATEST_TAG}.tar.gz"
fi

echo "Adding ephor dependency..."
zig fetch --save=ephor "$EPHOR_URL"

# Check if ephor step already exists
if grep -q 'dependency("ephor"' build.zig; then
    echo "ephor step already exists in build.zig"
else
    echo "Patching build.zig..."

    # Find the line number of the last installArtifact call
    LINE=$(grep -n "installArtifact" build.zig | tail -1 | cut -d: -f1)

    if [ -z "$LINE" ]; then
        echo "Warning: Could not find installArtifact in build.zig"
        echo "Please add manually after your exe/lib setup:"
        echo ""
        echo '    const ephor_dep = b.dependency("ephor", .{ .target = target, .optimize = .ReleaseSafe });'
        echo '    const ephor_step = b.step("ephor", "Run ephor static analysis");'
        echo '    ephor_step.dependOn(&b.addRunArtifact(ephor_dep.artifact("ephor")).step);'
        exit 0
    fi

    # Create patched file using head/tail (portable)
    head -n "$LINE" build.zig > build.zig.tmp
    cat >> build.zig.tmp << 'EPHOR_EOF'

    // Ephor static analysis
    const ephor_dep = b.dependency("ephor", .{ .target = target, .optimize = .ReleaseSafe });
    const ephor_step = b.step("ephor", "Run ephor static analysis");
    ephor_step.dependOn(&b.addRunArtifact(ephor_dep.artifact("ephor")).step);
EPHOR_EOF
    tail -n +"$((LINE + 1))" build.zig >> build.zig.tmp
    mv build.zig.tmp build.zig
fi

echo ""
echo "Done! Run static analysis with:"
echo "  zig build ephor"
