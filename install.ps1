# Ephor installer for Windows - adds ephor to your Zig project
# Usage: irm https://bitbucket.org/rhyoslabs/ephor/raw/main/install.ps1 | iex

$ErrorActionPreference = "Stop"

$EPHOR_URL = "https://bitbucket.org/rhyoslabs/ephor/get/main.tar.gz"

# Check we're in a Zig project
if (-not (Test-Path "build.zig")) {
    Write-Error "Error: build.zig not found. Run this from your Zig project root."
    exit 1
}

if (-not (Test-Path "build.zig.zon")) {
    Write-Error "Error: build.zig.zon not found. Run this from your Zig project root."
    exit 1
}

Write-Host "Adding ephor dependency..."
zig fetch --save=ephor $EPHOR_URL

# Check if ephor step already exists
$buildContent = Get-Content "build.zig" -Raw
if ($buildContent -match 'dependency\("ephor"') {
    Write-Host "ephor step already exists in build.zig"
} else {
    Write-Host "Patching build.zig..."

    $lines = Get-Content "build.zig"
    $lastInstallLine = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "installArtifact") {
            $lastInstallLine = $i
        }
    }

    if ($lastInstallLine -eq -1) {
        Write-Host "Warning: Could not find installArtifact in build.zig"
        Write-Host "Please add manually after your exe/lib setup:"
        Write-Host ""
        Write-Host '    const ephor_dep = b.dependency("ephor", .{ .target = target, .optimize = .ReleaseSafe });'
        Write-Host '    const ephor_step = b.step("ephor", "Run ephor static analysis");'
        Write-Host '    ephor_step.dependOn(&b.addRunArtifact(ephor_dep.artifact("ephor")).step);'
        exit 0
    }

    $ephorCode = @"

    // Ephor static analysis
    const ephor_dep = b.dependency("ephor", .{ .target = target, .optimize = .ReleaseSafe });
    const ephor_step = b.step("ephor", "Run ephor static analysis");
    ephor_step.dependOn(&b.addRunArtifact(ephor_dep.artifact("ephor")).step);
"@

    $newLines = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $newLines += $lines[$i]
        if ($i -eq $lastInstallLine) {
            $newLines += $ephorCode
        }
    }

    $newLines | Set-Content "build.zig"
}

Write-Host ""
Write-Host "Done! Run static analysis with:"
Write-Host "  zig build ephor"
