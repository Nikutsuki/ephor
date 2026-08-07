#!/bin/sh
# Validates all version references match before pushing a tagged release.
# Usage: ./scripts/check-version.sh [expected_version]
#
# If no version is given, extracts it from build.zig.zon as the source of truth.
#
# Checked locations:
#   1. build.zig.zon        .version field (source of truth)
#   2. src/main.zig          EPHOR_VERSION constant
#   3. README.md             manual install URL matches the latest remote tag
#   4. README.md             example config "version" field
#   5. install.sh            EPHOR_FALLBACK_TAG matches the latest remote tag
#   5b. install.ps1          EPHOR_FALLBACK_TAG matches install.sh's value
#   6. Codeberg tags API     latest remote tag matches
#   7. README.md             changelog header names the in-development version

set -e

# Source of truth: build.zig.zon
ZON_VERSION=$(grep '\.version' build.zig.zon | head -1 | sed 's/.*"\([0-9][0-9.]*\)".*/\1/')

EXPECTED="${1:-$ZON_VERSION}"

if [ -z "$EXPECTED" ]; then
    echo "error: could not determine version from build.zig.zon"
    exit 1
fi

# Read a Codeberg tags API response on stdin. Print the semver-highest
# strict vX.Y.Z tag without the leading v. Print nothing when no tag matches.
# EPH-I0193: the API orders tags by date, so limit=1 plus head -1 can select
# a re-dated older tag. The numeric sort keys are the portable (BSD+GNU)
# semver compare. sort -V is GNU-only.
max_stable_version() {
    grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}

# Fetch the latest remote tag once. Sections 3, 5, and 6 use it.
# Give the API 30s: observed 20s+ responses must not skip the gate.
# EPH-I0156: clamp the fetch to the https scheme, redirects included, and
# cap the body at 1 MiB. A hostile network cannot redirect the fetch into
# a local file read or spew an unbounded body.
TAGS_API="https://codeberg.org/api/v1/repos/RhyosLabs/ephor/tags?limit=10"
REMOTE_TAG=$(curl -sL --max-time 30 --proto "=https" --proto-redir "=https" \
    --max-filesize 1048576 "$TAGS_API" 2>/dev/null | max_stable_version)

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

# 3. README.md install URL matches the latest remote tag.
# The manual install URL must name the newest existing tag, never the
# untagged version under development. Bump it to the release version in the
# first post-tag commit so the pre-push hook passes while the tag is in flight.
README_URL_VERSION=$(grep 'ephor/archive/v' README.md | head -1 | sed 's/.*\/v\([0-9][0-9.]*\)\.tar\.gz.*/\1/')
if [ -z "$README_URL_VERSION" ]; then
    echo "MISSING  README.md: no tagged install URL found"
    ERRORS=$((ERRORS + 1))
elif [ -z "$REMOTE_TAG" ]; then
    echo "SKIP     README.md install URL: Codeberg tags API unreachable"
elif [ "$README_URL_VERSION" != "$REMOTE_TAG" ]; then
    echo "MISMATCH README.md install URL: v${README_URL_VERSION} (latest remote tag v${REMOTE_TAG})"
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

# 5. install.sh EPHOR_FALLBACK_TAG matches the latest remote tag.
# The fallback serves installs when the tags API fails. It must name the
# newest existing tag, never the untagged version under development.
INSTALL_FALLBACK=$(grep 'EPHOR_FALLBACK_TAG=' install.sh | head -1 | sed 's/.*"v\([0-9][0-9.]*\)".*/\1/')
if [ -z "$INSTALL_FALLBACK" ]; then
    echo "MISSING  install.sh: EPHOR_FALLBACK_TAG not found"
    ERRORS=$((ERRORS + 1))
elif [ -z "$REMOTE_TAG" ]; then
    echo "SKIP     install.sh EPHOR_FALLBACK_TAG: Codeberg tags API unreachable"
elif [ "$INSTALL_FALLBACK" != "$REMOTE_TAG" ]; then
    echo "MISMATCH install.sh EPHOR_FALLBACK_TAG: v${INSTALL_FALLBACK} (latest remote tag v${REMOTE_TAG})"
    ERRORS=$((ERRORS + 1))
else
    echo "ok       install.sh EPHOR_FALLBACK_TAG: v${INSTALL_FALLBACK}"
fi

# 5b. install.ps1 EPHOR_FALLBACK_TAG matches install.sh's value. The two
# installers must never diverge: a Windows install and a POSIX install hit
# the same API failure modes and must land on the same pinned floor.
PS1_FALLBACK=$(grep 'EPHOR_FALLBACK_TAG = ' install.ps1 | head -1 \
    | sed 's/.*"v\([0-9][0-9.]*\)".*/\1/')
if [ -z "$PS1_FALLBACK" ]; then
    echo "MISSING  install.ps1: EPHOR_FALLBACK_TAG not found"
    ERRORS=$((ERRORS + 1))
elif [ -z "$INSTALL_FALLBACK" ]; then
    echo "SKIP     install.ps1 EPHOR_FALLBACK_TAG: install.sh pin missing"
elif [ "$PS1_FALLBACK" != "$INSTALL_FALLBACK" ]; then
    echo "MISMATCH install.ps1 EPHOR_FALLBACK_TAG: v${PS1_FALLBACK}" \
        "(install.sh v${INSTALL_FALLBACK})"
    ERRORS=$((ERRORS + 1))
else
    echo "ok       install.ps1 EPHOR_FALLBACK_TAG: v${PS1_FALLBACK}"
fi

# 6. Codeberg tags API - latest remote tag
if [ -z "$REMOTE_TAG" ]; then
    echo "SKIP     Codeberg tags API: could not reach (offline?)"
elif [ "$REMOTE_TAG" = "$EXPECTED" ]; then
    echo "ok       Codeberg latest tag: v${REMOTE_TAG}"
else
    echo "PENDING  Codeberg latest tag: v${REMOTE_TAG} (will be v${EXPECTED} after push)"
fi

# 7. README.md changelog header against the in-development version.
# The newest changelog section names the next release. Release prep adds
# the unreleased header and bumps build.zig.zon in one commit, so the two
# versions match from one release prep to the next. A header behind
# build.zig.zon is drift and fails. A header ahead routes on the caller.
# With no argument the caller runs the local check, and a header ahead is
# the skip-window case: a skipped release (v0.14.3, user ruling 2026-08-05)
# retitles the changelog before build.zig.zon bumps. The script reports
# PENDING until release prep converges the two versions. With an explicit
# argument the caller names the tag being pushed. The tag is immutable.
# A header ahead of the tag ships the wrong release notes forever. The
# script fails MISMATCH.
CHANGELOG_VERSION=$(grep '^### v' README.md | head -1 | sed 's/^### v\([0-9][0-9.]*\).*/\1/')
if [ -z "$CHANGELOG_VERSION" ]; then
    echo "MISSING  README.md: no changelog header found"
    ERRORS=$((ERRORS + 1))
elif [ "$CHANGELOG_VERSION" = "$EXPECTED" ]; then
    echo "ok       README.md changelog header: v${CHANGELOG_VERSION}"
else
    NEWER_VERSION=$(printf '%s\n%s\n' "$EXPECTED" "$CHANGELOG_VERSION" \
        | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
    if [ "$NEWER_VERSION" = "$CHANGELOG_VERSION" ] && [ -z "${1:-}" ]; then
        echo "PENDING  README.md changelog header: v${CHANGELOG_VERSION}" \
            "(awaits build.zig.zon bump at release prep, currently ${EXPECTED})"
    else
        echo "MISMATCH README.md changelog header: v${CHANGELOG_VERSION} (expected ${EXPECTED})"
        ERRORS=$((ERRORS + 1))
    fi
fi

echo ""
if [ "$ERRORS" -gt 0 ]; then
    echo "FAILED: ${ERRORS} version mismatch(es) found"
    echo "  Sections 1, 2, 4, and 7 must be ${EXPECTED} before tagging v${EXPECTED}."
    echo "  Sections 3 and 5 must match the latest remote tag."
    exit 1
else
    echo "All versions match: ${EXPECTED}"
fi
