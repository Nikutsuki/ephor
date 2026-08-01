# Ephor installer for Windows - adds ephor to your Zig project
# Usage: irm https://codeberg.org/RhyosLabs/ephor/raw/branch/main/install.ps1 | iex

$ErrorActionPreference = "Stop"

$REPO = "https://codeberg.org/RhyosLabs/ephor"
# Fetch the newest stable tags from the Codeberg tags API (not cached raw
# files). 30s: observed answers from the Codeberg API take 20s+ on slow
# days. Refusals still fail fast.
$TAGS_API = "https://codeberg.org/api/v1/repos/RhyosLabs/ephor/tags?limit=10"
# This tag is the fallback when the Codeberg tags API fails. Refresh it on
# every release.
$EPHOR_FALLBACK_TAG = "v0.14.2"
# Pin for Zig 0.15.x. Every remote tag (v0.12.3 and later) declares
# minimum_zig_version 0.16.0. The 0.16 migration landed in v0.12.0, so no
# remote tag builds on Zig 0.15.x. v0.11.13 declares minimum_zig_version
# 0.15.0 and is the newest 0.15-era release. Its tag is deleted on the
# remote, so pin the commit hash. Commit archives stay available.
$EPHOR_0_15_COMMIT = "60145fe05a2b91e7dd32d1c671d98239cd19aea6"

# Write $Value to $Path without following a symlink at $Path.
# EPH-I0280: Set-Content follows reparse points, so a git-tracked symlink
# planted at build.zig or build.zig.zon overwrites its target. Write a temp
# file in the same directory, then Move-Item -Force. A rename on the same
# volume replaces the symlink itself and never touches the target. The
# finally block removes the temp file when the move does not happen.
function Set-ContentNoFollow {
    param(
        [string]$Path,
        [object[]]$Value
    )
    $tempPath = "$Path.$([System.IO.Path]::GetRandomFileName())"
    try {
        Set-Content -Path $tempPath -Value $Value
        Move-Item -Force -Path $tempPath -Destination $Path
    } finally {
        if (Test-Path $tempPath) { Remove-Item $tempPath -Force }
    }
}

# Return the semver-highest strict vX.Y.Z tag from the Codeberg tags API, or
# $null when the API fails, the result is empty, or no tag matches.
# EPH-I0186: the API returns a top-level JSON array, so the response has no
# .values member. Iterate the array itself.
# EPH-I0193: the API orders tags by date, so the first entry is not always
# the highest version. A re-dated old tag must never downgrade an install.
# [version] parses and compares X.Y.Z numerically, so 0.14.10 sorts above
# 0.14.2 where a string sort would not.
function Get-LatestEphorTag {
    $tagsJson = Invoke-RestMethod -Uri $TAGS_API -TimeoutSec 30
    $maxTag = $null
    $maxVersion = $null
    foreach ($entry in $tagsJson) {
        $name = $entry.name
        if ($name -notmatch '^v\d+\.\d+\.\d+$') { continue }
        $parsed = [version]($name.Substring(1))
        if ($null -eq $maxVersion -or $parsed -gt $maxVersion) {
            $maxVersion = $parsed
            $maxTag = $name
        }
    }
    return $maxTag
}

# Return $true when the strict tag $A sorts below the strict tag $B.
# EPH-I0193: the downgrade floor needs a version compare, not a string
# compare.
function Test-VersionOlder {
    param([string]$A, [string]$B)
    if ($A -eq $B) { return $false }
    return [version]($A.Substring(1)) -lt [version]($B.Substring(1))
}

# Return the release tag to install: the newest stable tag from the Codeberg
# API, or the pinned fallback tag when the API does not yield a valid tag or
# resolves below the fallback.
function Resolve-EphorTag {
    try {
        $tag = Get-LatestEphorTag
    } catch {
        # Handled below: an empty tag takes the fallback branch, which warns
        # and continues with $EPHOR_FALLBACK_TAG.
        $tag = $null
    }
    if (-not $tag) {
        Write-Host "warning: could not resolve the latest ephor tag from the Codeberg API."
        Write-Host "The install continues with the fallback tag $EPHOR_FALLBACK_TAG."
        return $EPHOR_FALLBACK_TAG
    }
    if (Test-VersionOlder $tag $EPHOR_FALLBACK_TAG) {
        # EPH-I0193: a stale or re-dated API response must not downgrade the
        # install below the pinned fallback.
        Write-Host "warning: the resolved tag $tag is below the fallback $EPHOR_FALLBACK_TAG."
        Write-Host "The install continues with the fallback tag."
        return $EPHOR_FALLBACK_TAG
    }
    return $tag
}

# Check we're in a Zig project
if (-not (Test-Path "build.zig")) {
    Write-Error @"
error: no build.zig found in current directory

  Ephor requires a Zig project with build.zig and build.zig.zon.
  To initialize a Zig project, run:

    zig init

  Then re-run the install:
    irm $REPO/raw/main/install.ps1 | iex
"@
    exit 1
}

if (-not (Test-Path "build.zig.zon")) {
    $projectName = (Split-Path -Leaf (Get-Location)) -replace '-', '_'
    $projectName = $projectName.ToLower()
    Write-Host "No build.zig.zon found, creating one..."
    Set-ContentNoFollow -Path "build.zig.zon" -Value @"
.{
    .name = .$projectName,
    .version = "0.0.0",
    .fingerprint = 0x0,
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
"@

    # EPH-I0192: do not spawn zig build for the fingerprint here. A hostile
    # build.zig would run attacker code. The zig fetch step below repairs
    # the 0x0 fingerprint from the hint zig fetch prints.
    Write-Host "Created build.zig.zon for project '$projectName'"
}

# Detect the Zig version and pick a compatible ephor version.
# EPH-I0187: no remote tag builds on Zig 0.15.x, so Zig below 0.16 pins the
# 0.15-era release by commit hash (see $EPHOR_0_15_COMMIT above).
$zigVersion = ""
try {
    $zigVersion = (& zig version 2>$null | Out-String).Trim()
} catch {
    # Handled below: an empty version takes the warning branch and the
    # install defaults to the latest tag.
    $zigVersion = ""
}
$EPHOR_URL = ""
if ($zigVersion -match '^(\d+)\.(\d+)') {
    $zigMajor = [int]$Matches[1]
    $zigMinor = [int]$Matches[2]
    # Zig 0.16.0 and later track the latest ephor release. Zig 0.15.x uses
    # the pinned 0.15-era release by commit hash.
    if ($zigMajor -gt 0 -or $zigMinor -ge 16) {
        $EPHOR_TAG = Resolve-EphorTag
    } else {
        $EPHOR_TAG = "v0.11.13"
        $EPHOR_URL = "$REPO/archive/$EPHOR_0_15_COMMIT.tar.gz"
    }
} else {
    Write-Host "warning: could not detect zig version, defaulting to latest"
    $EPHOR_TAG = Resolve-EphorTag
}

if ($zigVersion) {
    Write-Host "Installing ephor $EPHOR_TAG (Zig $zigVersion)..."
} else {
    Write-Host "Installing ephor $EPHOR_TAG..."
}
if (-not $EPHOR_URL) {
    $EPHOR_URL = "$REPO/archive/$EPHOR_TAG.tar.gz"
}

Write-Host "Adding ephor dependency..."
# EPH-I0192: zig fetch reads build.zig.zon but never runs build.zig, so a
# hostile build.zig still executes no code here. On a fresh zon with
# fingerprint 0x0, zig fetch fails and prints a "use this value" hint with
# the computed fingerprint. Patch the hint in and fetch again.
# PowerShell 7.4+ turns a nonzero native exit into a terminating error under
# "Stop". Relax the preference so this code can inspect the failure.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$fetchOut = zig fetch --save=ephor $EPHOR_URL 2>&1 | Out-String
$fetchRc = $LASTEXITCODE
$ErrorActionPreference = $prevEAP
if ($null -eq $fetchRc) { $fetchRc = 1 }
if ($fetchRc -ne 0) {
    if ($fetchOut -match 'use this value: (0x[0-9a-f]+)') {
        $suggested = $Matches[1]
        $zon = Get-Content "build.zig.zon" -Raw
        $patched = $zon -replace '\.fingerprint = 0x0', ".fingerprint = $suggested"
        Set-ContentNoFollow -Path "build.zig.zon" -Value $patched
        # This fetch is authoritative: a failure aborts the install.
        zig fetch --save=ephor $EPHOR_URL
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } else {
        # No hint means a real fetch failure (network, hash, server). Show
        # the captured error and keep the original exit code.
        Write-Host $fetchOut
        exit $fetchRc
    }
}

# Canonical ephor block for build.zig
$EPHOR_BLOCK = @"

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
    ephor_upgrade_step.dependOn(&ephor_upgrade_cmd.step);
"@

$buildContent = Get-Content "build.zig" -Raw

if ($buildContent -match '// Ephor static analysis') {
    # Ephor block exists - replace it with the canonical version
    $lines = Get-Content "build.zig"
    $startLine = -1
    $endLine = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '// Ephor static analysis' -and $startLine -eq -1) {
            $startLine = $i
        }
        if ($lines[$i] -match 'ephor_upgrade_step\.dependOn') {
            $endLine = $i
        }
    }

    if ($startLine -ge 0 -and $endLine -ge 0) {
        $newLines = @()
        $newLines += $lines[0..($startLine - 1)]
        $newLines += $EPHOR_BLOCK
        if ($endLine + 1 -lt $lines.Count) {
            $newLines += $lines[($endLine + 1)..($lines.Count - 1)]
        }
        Set-ContentNoFollow -Path "build.zig" -Value $newLines
        Write-Host "Updated ephor build steps in build.zig"
    }
} elseif ($buildContent -match 'dependency\("ephor"') {
    Write-Host "warning: ephor dependency found but build steps have non-standard layout"
    Write-Host "Please update your ephor build steps manually (see README)"
} else {
    Write-Host "Adding ephor build steps to build.zig..."

    $lines = Get-Content "build.zig"
    $lastInstallLine = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "installArtifact") {
            $lastInstallLine = $i
        }
    }

    if ($lastInstallLine -eq -1) {
        Write-Host "Warning: Could not find installArtifact in build.zig"
        Write-Host "Please add the ephor build steps manually (see README)"
        exit 0
    }

    $newLines = @()
    $newLines += $lines[0..$lastInstallLine]
    $newLines += $EPHOR_BLOCK
    if ($lastInstallLine + 1 -lt $lines.Count) {
        $newLines += $lines[($lastInstallLine + 1)..($lines.Count - 1)]
    }
    Set-ContentNoFollow -Path "build.zig" -Value $newLines
}

Write-Host ""
Write-Host "Done! Run static analysis with:"
Write-Host "  zig build ephor              (run all checks)"
Write-Host "  zig build ephor -- init      (create ephor.json config)"
Write-Host "  zig build ephor-upgrade      (upgrade to latest version)"
