# Ephor installer for Windows - adds ephor to your Zig project
# Usage: irm https://codeberg.org/RhyosLabs/ephor/raw/branch/main/install.ps1 | iex

$ErrorActionPreference = "Stop"

$REPO = "https://codeberg.org/RhyosLabs/ephor"

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
    @"
.{
    .name = .$projectName,
    .version = "0.0.0",
    .fingerprint = 0x0,
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
"@ | Set-Content "build.zig.zon"

    # Zig computes the correct fingerprint - capture it
    $output = zig build 2>&1 | Out-String
    if ($output -match 'use this value: (0x[0-9a-f]+)') {
        $fingerprint = $Matches[1]
        (Get-Content "build.zig.zon" -Raw) -replace '\.fingerprint = 0x0', ".fingerprint = $fingerprint" | Set-Content "build.zig.zon"
    }
    Write-Host "Created build.zig.zon for project '$projectName'"
}

# Fetch latest tagged version from Codeberg tags API (not cached raw files)
$TAGS_API = "https://codeberg.org/api/v1/repos/RhyosLabs/ephor/tags?limit=1"
try {
    $tagsJson = Invoke-RestMethod -Uri $TAGS_API -TimeoutSec 10
    $LATEST_TAG = $tagsJson.values[0].name -replace '^v', ''
} catch {
    $LATEST_TAG = $null
}

if (-not $LATEST_TAG) {
    Write-Host "warning: could not detect latest version, using main branch"
    $EPHOR_URL = "$REPO/archive/main.tar.gz"
} else {
    Write-Host "Installing ephor v$LATEST_TAG..."
    $EPHOR_URL = "$REPO/archive/v$LATEST_TAG.tar.gz"
}

Write-Host "Adding ephor dependency..."
zig fetch --save=ephor $EPHOR_URL

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
        $newLines | Set-Content "build.zig"
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
    $newLines | Set-Content "build.zig"
}

Write-Host ""
Write-Host "Done! Run static analysis with:"
Write-Host "  zig build ephor              (run all checks)"
Write-Host "  zig build ephor -- init      (create ephor.json config)"
Write-Host "  zig build ephor-upgrade      (upgrade to latest version)"
