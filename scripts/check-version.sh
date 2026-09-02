#!/bin/sh
# Validates all version references match before pushing a tagged release.
# Usage: ./scripts/check-version.sh [expected_version] [post-tag]
#
# If no version is given, extracts it from build.zig.zon as the source of truth.
# The optional second argument "post-tag" names the post-tag mode: the
# release runbook (REL-RELEASE-6) runs the script after pushing the tag, and
# section 6 treats a remote tag that is not the expected version as MISMATCH.
# The pre-push hook passes only the version; its tag does not exist on the
# remote yet, so PENDING stays non-failing for the hook.
#
# Checked locations:
#   1. build.zig.zon        .version field (source of truth)
#   2. src/main.zig          EPHOR_VERSION constant
#   3. README.md             every install URL matches the latest remote tag
#   4. README.md             every example config "version" matches EXPECTED
#   5. install.sh            EPHOR_FALLBACK_TAG matches the latest remote tag
#   5b. install.ps1          EPHOR_FALLBACK_TAG matches install.sh's value
#   5c. install.ps1          EPHOR_0_15_COMMIT matches install.sh's value
#   6. Codeberg tags API     latest remote tag matches
#   7. README.md             changelog header names the in-development version
#   8. README.md             changelog header date matches the local date

set -e

# Source of truth: build.zig.zon. EPH-I0659: anchor the extraction to the
# field assignment, as release.py does. A comment or string elsewhere in
# the zon that gains the substring ".version" must not capture the field.
ZON_VERSION=$(grep '^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"' build.zig.zon | head -1 | sed 's/.*"\([0-9][0-9.]*\)".*/\1/')

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
# EPH-I1271: the extraction accepts only "name" values at a key position.
# A "name" text inside a string value (a tag message that quotes it) must
# not mint a candidate: the awk byte scan tracks string context with
# backslash escapes, the Zig-side isJsonKeyPosition model. Kept in sync
# with install.sh latest_ephor_tag.
max_stable_version() {
    awk '
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
        ' \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}

# Fetch the latest remote tag once. Sections 3, 5, and 6 use it.
# Give the API 30s: observed 20s+ responses must not skip the gate.
# EPH-I0156: clamp the fetch to the https scheme, redirects included, and
# cap the body at 1 MiB. A hostile network cannot redirect the fetch into
# a local file read or spew an unbounded body.
# EPH-I1105: limit=50 matches the install.sh fix (EPH-I0637). The API
# orders tags by date, so a small page left a window: re-dated old tags
# could evict the true max from the page. The per-page clamp is 50.
TAGS_API="https://codeberg.org/api/v1/repos/RhyosLabs/ephor/tags?limit=50"
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

# 2. src/main.zig EPHOR_VERSION. Anchored to the declaration line, the
# same shape release.py anchors (EPH-I0659, same unanchored class as the
# zon extraction: a comment that mentions the const must not win).
MAIN_VERSION=$(grep '^[[:space:]]*const EPHOR_VERSION[[:space:]]*=[[:space:]]*"' src/main.zig | head -1 | sed 's/.*"\([0-9][0-9.]*\)".*/\1/')
if [ -z "$MAIN_VERSION" ]; then
    echo "MISSING  src/main.zig: EPHOR_VERSION not found"
    ERRORS=$((ERRORS + 1))
elif [ "$MAIN_VERSION" != "$EXPECTED" ]; then
    echo "MISMATCH src/main.zig EPHOR_VERSION: ${MAIN_VERSION} (expected ${EXPECTED})"
    ERRORS=$((ERRORS + 1))
else
    echo "ok       src/main.zig EPHOR_VERSION: ${MAIN_VERSION}"
fi

# 3. Every README.md install URL matches the latest remote tag.
# The manual install URLs must name the newest existing tag, never the
# untagged version under development. Bump them to the release version in
# the first post-tag commit so the pre-push hook passes while the tag is in
# flight. EPH-I0252: every match is checked, not just the first; a second
# stale archive URL can no longer hide drift. REL-RELEASE-6.
README_URL_COUNT=0
README_URL_BAD=0
for README_URL_VERSION in $(grep 'ephor/archive/v' README.md | sed 's/.*\/v\([0-9][0-9.]*\)\.tar\.gz.*/\1/'); do
    README_URL_COUNT=$((README_URL_COUNT + 1))
    if [ -z "$REMOTE_TAG" ]; then
        echo "SKIP     README.md install URL: Codeberg tags API unreachable"
        break
    fi
    if [ "$README_URL_VERSION" != "$REMOTE_TAG" ]; then
        echo "MISMATCH README.md install URL: v${README_URL_VERSION} (latest remote tag v${REMOTE_TAG})"
        ERRORS=$((ERRORS + 1))
        README_URL_BAD=$((README_URL_BAD + 1))
    fi
done
if [ "$README_URL_COUNT" -eq 0 ]; then
    echo "MISSING  README.md: no tagged install URL found"
    ERRORS=$((ERRORS + 1))
elif [ "$README_URL_BAD" -eq 0 ] && [ -n "$REMOTE_TAG" ]; then
    echo "ok       README.md install URL: v${REMOTE_TAG}"
fi

# 4. Every README.md example config version matches the expected version.
# A "version" line belongs to the ephor.json example when it sits directly
# above the example's "path_dir" line. The VS Code tasks.json example
# (README.md:838, "version": "2.0.0") has no path_dir line and stays out of
# the check by context, never by a magic version literal. EPH-I0252: every
# example is checked, not just the first; the pairing must stay adjacent or
# the section fails closed with MISSING.
README_CFG_COUNT=0
README_CFG_BAD=0
for README_CFG_VERSION in $(grep -B1 '"path_dir"' README.md | grep '"version":' | sed 's/.*"\([0-9][0-9.]*\)".*/\1/'); do
    README_CFG_COUNT=$((README_CFG_COUNT + 1))
    if [ "$README_CFG_VERSION" != "$EXPECTED" ]; then
        echo "MISMATCH README.md example config: ${README_CFG_VERSION} (expected ${EXPECTED})"
        ERRORS=$((ERRORS + 1))
        README_CFG_BAD=$((README_CFG_BAD + 1))
    fi
done
if [ "$README_CFG_COUNT" -eq 0 ]; then
    echo "MISSING  README.md: no example config version found"
    ERRORS=$((ERRORS + 1))
elif [ "$README_CFG_BAD" -eq 0 ]; then
    echo "ok       README.md example config: ${EXPECTED}"
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

# 5c. install.ps1 EPHOR_0_15_COMMIT matches install.sh's value. Both
# installers pin the same pre-0.15-era archive commit; they must never
# diverge (EPH-I0286). A missing install.sh pin is MISSING, not SKIP:
# section 5b can skip on a missing install.sh fallback only because
# section 5 already fails on that condition, while nothing else covers
# install.sh's commit pin. install.sh:144 assembles the pre-0.15 archive
# URL from it. REL-RELEASE-6.
SH_COMMIT=$(grep 'EPHOR_0_15_COMMIT=' install.sh | head -1 \
    | sed 's/.*"\([0-9a-f]\{40\}\)".*/\1/')
PS1_COMMIT=$(grep 'EPHOR_0_15_COMMIT = ' install.ps1 | head -1 \
    | sed 's/.*"\([0-9a-f]\{40\}\)".*/\1/')
if [ -z "$PS1_COMMIT" ]; then
    echo "MISSING  install.ps1: EPHOR_0_15_COMMIT not found"
    ERRORS=$((ERRORS + 1))
elif [ -z "$SH_COMMIT" ]; then
    echo "MISSING  install.sh: EPHOR_0_15_COMMIT not found"
    ERRORS=$((ERRORS + 1))
elif [ "$PS1_COMMIT" != "$SH_COMMIT" ]; then
    echo "MISMATCH install.ps1 EPHOR_0_15_COMMIT: ${PS1_COMMIT}" \
        "(install.sh ${SH_COMMIT})"
    ERRORS=$((ERRORS + 1))
else
    echo "ok       install.ps1 EPHOR_0_15_COMMIT: ${PS1_COMMIT}"
fi

# 6. Codeberg tags API - latest remote tag
# The post-tag mode (second argument "post-tag") asserts the tag IS the
# latest remote tag: the release runbook runs the script after pushing the
# tag, and PENDING becomes MISMATCH so a failed or missing push cannot pass
# the gate. EPH-I0252. The pre-push hook never passes the post-tag mode;
# its tag does not exist on the remote yet. REL-RELEASE-6.
if [ -z "$REMOTE_TAG" ]; then
    echo "SKIP     Codeberg tags API: could not reach (offline?)"
elif [ "$REMOTE_TAG" = "$EXPECTED" ]; then
    echo "ok       Codeberg latest tag: v${REMOTE_TAG}"
elif [ "${2:-}" = "post-tag" ]; then
    echo "MISMATCH Codeberg latest tag: v${REMOTE_TAG} (expected v${EXPECTED}: tag not on the remote)"
    ERRORS=$((ERRORS + 1))
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

# 8. README.md changelog header date matches the local calendar date.
# EPH-I1316 (REL-P4-SCOPE-1, the date leg of REL-P4-RELEASE-4): the
# I1314 class fired on v0.15.2 and v0.15.3 — the release header carried
# a one-day-forward date (the planner ETA, not the push day) and both
# releases survived only on the human binding check. The run-63 WP-7
# amendment pins the header date to the planned push day, re-derived
# from the actual calendar at the bump step; a push-day slip updates the
# header date in the same release commit before the tag. This section
# closes the class mechanically: at the pre-tag run the header names the
# version being tagged, so its date must equal the local date
# (date +%F, the local calendar — the push-day pin). Any difference is
# MISMATCH (ahead or behind, the message names the direction); a header
# with no parenthesized date fails closed as MISSING.
#
# The check fires only in that pre-tag state. It skips when the header
# names another version (section 7 governs the version relationship),
# when the tag is already on the remote (the header date is frozen
# history with the immutable tag, and the post-tag commits must not
# trip on it), and offline (the tags API verdict is the shipped-state
# signal; the pre-tag run is online by definition — the push follows
# it). No PENDING case exists by design.
#
# Controls (REL-P4-VERIFY-3, run at the candidate): positive — a
# header naming the expected version with today's date exits green;
# negative — the same header with a different date exits red. Both run
# in a scratch tree whose zon/main/installer pins match the release
# prep state (see the VERDICT.md record).
TODAY=$(date +%F)
if [ -z "$CHANGELOG_VERSION" ]; then
    echo "SKIP     README.md changelog header date: no changelog header (section 7)"
elif [ "$CHANGELOG_VERSION" != "$EXPECTED" ]; then
    echo "SKIP     README.md changelog header date: header v${CHANGELOG_VERSION} is not the release being tagged"
elif [ -z "$REMOTE_TAG" ]; then
    echo "SKIP     README.md changelog header date: Codeberg tags API unreachable"
elif [ "$REMOTE_TAG" = "$EXPECTED" ]; then
    echo "SKIP     README.md changelog header date: v${EXPECTED} on the remote (the header date is frozen history)"
else
    HEADER_DATE=$(grep '^### v' README.md | head -1 \
        | sed 's/.*(\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\))[[:space:]]*$/\1/')
    case "$HEADER_DATE" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        *) HEADER_DATE="" ;;
    esac
    if [ -z "$HEADER_DATE" ]; then
        echo "MISSING  README.md changelog header date: no (YYYY-MM-DD) on the v${CHANGELOG_VERSION} header"
        ERRORS=$((ERRORS + 1))
    elif [ "$HEADER_DATE" = "$TODAY" ]; then
        echo "ok       README.md changelog header date: ${HEADER_DATE} (local date)"
    else
        NEWER_DATE=$(printf '%s\n%s\n' "$HEADER_DATE" "$TODAY" | sort | tail -n 1)
        if [ "$NEWER_DATE" = "$HEADER_DATE" ]; then
            echo "MISMATCH README.md changelog header date: ${HEADER_DATE} (local date ${TODAY}, the header date is ahead)"
        else
            echo "MISMATCH README.md changelog header date: ${HEADER_DATE} (local date ${TODAY}, the header date is behind)"
        fi
        ERRORS=$((ERRORS + 1))
    fi
fi

echo ""
if [ "$ERRORS" -gt 0 ]; then
    echo "FAILED: ${ERRORS} version mismatch(es) found"
    echo "  Sections 1, 2, 4, and 7 must be ${EXPECTED} before tagging v${EXPECTED}."
    echo "  Sections 3 and 5 must match the latest remote tag."
    echo "  Sections 5b and 5c pins must agree across install.sh and install.ps1."
    echo "  Section 8 must carry the local date at the pre-tag run."
    exit 1
else
    echo "All versions match: ${EXPECTED}"
fi
