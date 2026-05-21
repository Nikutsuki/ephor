#!/bin/sh
# Validates all version references match before pushing a tagged release.
# Usage: ./scripts/check-version.sh [expected_version]
#
# If no version is given, extracts it from build.zig.zon as the source of truth.
#
# Checked locations:
#   1. build.zig.zon        .version field (source of truth)
#   2. src/main.zig          EPHOR_VERSION constant
#   3. README.md             manual install URL (v*.tar.gz)
#   4. README.md             example config "version" field
#   5. Codeberg tags API     latest remote tag matches

set -e

# Source of truth: build.zig.zon
ZON_VERSION=$(grep '\.version' build.zig.zon | head -1 | sed 's/.*"\([0-9][0-9.]*\)".*/\1/')

EXPECTED="${1:-$ZON_VERSION}"

if [ -z "$EXPECTED" ]; then
    echo "error: could not determine version from build.zig.zon"
    exit 1
fi

ERRORS=0

# 1. build.zig.zon
if [ "$ZON_VERSION" != "$EXPECTED" ]; then
    echo "MISMATCH build.zig.zon .version: ${ZON_VERSION} (expected ${EXPECTED})"
    ERRORS=$((ERRORS + 1))
else
    echo "ok       build.zig.zon .version: ${ZON_VERSION}"
fi

# 2. src/main.zig EPHOR_VERSION
MAIN_VERSION=$(grep 'EPHOR_VERSION = ' src/main.zig | head -1 | sed 's/.*"\([0-9][0-9.]*\)".*/\1/')
if [ -z "$MAIN_VERSION" ]; then
    echo "MISSING  src/main.zig: EPHOR_VERSION not found"
    ERRORS=$((ERRORS + 1))
elif [ "$MAIN_VERSION" != "$EXPECTED" ]; then
    echo "MISMATCH src/main.zig EPHOR_VERSION: ${MAIN_VERSION} (expected ${EXPECTED})"
    ERRORS=$((ERRORS + 1))
else
    echo "ok       src/main.zig EPHOR_VERSION: ${MAIN_VERSION}"
fi

# 3. README.md install URL
README_URL_VERSION=$(grep 'ephor/get/v' README.md | head -1 | sed 's/.*\/v\([0-9][0-9.]*\)\.tar\.gz.*/\1/')
if [ -z "$README_URL_VERSION" ]; then
    echo "MISSING  README.md: no tagged install URL found"
    ERRORS=$((ERRORS + 1))
elif [ "$README_URL_VERSION" != "$EXPECTED" ]; then
    echo "MISMATCH README.md install URL: v${README_URL_VERSION} (expected v${EXPECTED})"
    ERRORS=$((ERRORS + 1))
else
    echo "ok       README.md install URL: v${README_URL_VERSION}"
fi

# 4. README.md example config version
README_CFG_VERSION=$(grep '"version":' README.md | grep -v '2\.0\.0' | head -1 | sed 's/.*"\([0-9][0-9.]*\)".*/\1/')
if [ -z "$README_CFG_VERSION" ]; then
    echo "MISSING  README.md: no example config version found"
    ERRORS=$((ERRORS + 1))
elif [ "$README_CFG_VERSION" != "$EXPECTED" ]; then
    echo "MISMATCH README.md example config: ${README_CFG_VERSION} (expected ${EXPECTED})"
    ERRORS=$((ERRORS + 1))
else
    echo "ok       README.md example config: ${README_CFG_VERSION}"
fi

# 5. Codeberg tags API - latest remote tag
TAGS_API="https://codeberg.org/api/v1/repos/RhyosLabs/ephor/tags?limit=1"
REMOTE_TAG=$(curl -sL --max-time 5 "$TAGS_API" 2>/dev/null | grep -o '"name": "v[0-9.]*"' | head -1 | sed 's/.*"v\([0-9.]*\)".*/\1/')
if [ -z "$REMOTE_TAG" ]; then
    echo "SKIP     Codeberg tags API: could not reach (offline?)"
elif [ "$REMOTE_TAG" = "$EXPECTED" ]; then
    echo "ok       Codeberg latest tag: v${REMOTE_TAG}"
else
    echo "PENDING  Codeberg latest tag: v${REMOTE_TAG} (will be v${EXPECTED} after push)"
fi

echo ""
if [ "$ERRORS" -gt 0 ]; then
    echo "FAILED: ${ERRORS} version mismatch(es) found"
    echo "  All versions must be ${EXPECTED} before tagging v${EXPECTED}"
    exit 1
else
    echo "All versions match: ${EXPECTED}"
fi
