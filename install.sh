#!/bin/sh
# Ephor installer - adds ephor to your Zig project
# Usage: curl -fsSL https://bitbucket.org/rhyoslabs/ephor/raw/main/install.sh | sh

set -e

EPHOR_URL="https://bitbucket.org/rhyoslabs/ephor/get/main.tar.gz"

# Check we're in a Zig project
if [ ! -f "build.zig" ]; then
    echo "Error: build.zig not found. Run this from your Zig project root."
    exit 1
fi

if [ ! -f "build.zig.zon" ]; then
    echo "Error: build.zig.zon not found. Run this from your Zig project root."
    exit 1
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
