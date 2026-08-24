# Ephor installer for Windows - adds ephor to your Zig project
# Usage: irm https://codeberg.org/RhyosLabs/ephor/raw/branch/main/install.ps1 | iex

# EPH-I0644: run the install inside one script block. The documented
# irm | iex usage executes this file in the caller's session: a top-level
# exit closes the user's shell, and every variable, function, and
# preference change leaks into it. A script block invoked with & runs in a
# child scope, so nothing defined here survives it. The block returns the
# install exit code as its only output. The exit below runs only when this
# file runs as a script, where the code must reach the caller.
$installExitCode = & {
    $ErrorActionPreference = "Stop"

    # Write $Message to the process standard error stream.
    # EPH-I0650: Write-Error under $ErrorActionPreference "Stop" throws
    # before the return below runs, so the exit code never reaches the
    # caller. EPH-I0653: Write-Host writes to the host stream, which
    # automation cannot capture through stderr. [Console]::Error is the
    # direct stderr handle on every supported host, needs no EAP
    # handling, and adds no PowerShell decoration, so the output matches
    # install.sh's echo >&2 line for line. The framework flushes this
    # writer on every write (verified: .NET Framework
    # InitializeStdOutError sets AutoFlush = true on the error writer).
    # A test harness must capture this output at the process level (a
    # shell redirect or Start-Process -RedirectStandardError), because
    # the text bypasses the PowerShell streams and an in-session 2>&1
    # sees nothing.
    function Write-Stderr {
        param([string]$Message)
        [Console]::Error.WriteLine($Message)
    }

    $REPO = "https://codeberg.org/RhyosLabs/ephor"
    # EPH-I0205: EPHOR_TAGS_API and EPHOR_ARCHIVE_URL are test hooks. They
    # steer the install's trust anchor, so ambient environment must not
    # activate them: an override takes effect only when EPHOR_TEST_MODE=1
    # is set explicitly. An override set without the marker is ignored
    # with a warning (install.sh parity).
    $testModeActive = ($env:EPHOR_TEST_MODE -eq "1")
    # Fetch the newest stable tags from the Codeberg tags API (not cached
    # raw files). 30s: observed answers from the Codeberg API take 20s+ on
    # slow days. Refusals still fail fast.
    # EPH-I0637: the API orders tags by date, so limit=10 left a window:
    # ten re-dated old tags could evict the true max from the page.
    # limit=50 is the API's per-page maximum and holds every tag the repo
    # has released so far (15, verified 2026-08-22), so the window is
    # closed today. install.sh uses the same limit.
    # EPH-I0652: tests override this URL through EPHOR_TAGS_API to
    # simulate an API failure (install.sh channel). Empty or unset takes
    # the default, like install.sh's ${EPHOR_TAGS_API:-...} expansion.
    $TAGS_API = $null
    if ($testModeActive -and $env:EPHOR_TAGS_API) {
        $TAGS_API = $env:EPHOR_TAGS_API
    } else {
        if ($env:EPHOR_TAGS_API) {
            Write-Stderr "warning: EPHOR_TAGS_API is ignored without EPHOR_TEST_MODE=1."
        }
        $TAGS_API = "https://codeberg.org/api/v1/repos/RhyosLabs/ephor/tags?limit=50"
    }
    # This tag is the fallback when the Codeberg tags API fails. Refresh it
    # on every release.
    $EPHOR_FALLBACK_TAG = "v0.14.2"
    # Pin for Zig 0.15.x. Every remote tag (v0.12.3 and later) declares
    # minimum_zig_version 0.16.0. The 0.16 migration landed in v0.12.0, so
    # no remote tag builds on Zig 0.15.x. v0.11.13 declares
    # minimum_zig_version 0.15.0 and is the newest 0.15-era release. Its
    # tag is deleted on the remote, so pin the commit hash. Commit
    # archives stay available.
    $EPHOR_0_15_COMMIT = "60145fe05a2b91e7dd32d1c671d98239cd19aea6"

    # EPH-I0643: refuse when zig is missing before any file is created or
    # changed (install.sh EPH-I0631). Without this guard, a fetch of a
    # missing command leaves $LASTEXITCODE at the caller's last exit code:
    # under irm | iex a stale 0 used to skip the failure branch below and
    # the install reported success with no dependency saved.
    if (-not (Get-Command zig -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Stderr @"
error: zig is not installed or not on PATH.

  Ephor requires a Zig compiler to fetch the dependency.
  Install Zig, then re-run the install.
"@
        return 1
    }

    # Write $Value to $Path without following a symlink at $Path.
    # EPH-I0280: Set-Content follows reparse points, so a git-tracked
    # symlink planted at build.zig or build.zig.zon overwrites its target.
    # Write a temp file in the same directory, then Move-Item -Force. A
    # rename on the same volume replaces the symlink itself and never
    # touches the target. The finally block removes the temp file when the
    # move does not happen.
    function Set-ContentNoFollow {
        param(
            [string]$Path,
            [object[]]$Value
        )
        $tempPath = "$Path.$([System.IO.Path]::GetRandomFileName())"
        try {
            # EPH-I0646: the explicit UTF-8 keeps every PowerShell version
            # away from its default encoding. 5.1 defaults to the ANSI
            # code page, which mangles non-ASCII content; 7 defaults to
            # UTF-8 without a BOM. (5.1 writes a BOM here; the Zig
            # tokenizer skips it.)
            Set-Content -Path $tempPath -Value $Value -Encoding UTF8
            Move-Item -Force -Path $tempPath -Destination $Path
        } finally {
            if (Test-Path $tempPath) { Remove-Item $tempPath -Force }
        }
    }

    # Return the semver-highest strict vX.Y.Z tag from the Codeberg tags
    # API, or $null when the API fails, the result is empty, or no tag
    # matches.
    # EPH-I0186: the API returns a top-level JSON array, so the response
    # has no .values member. Iterate the array itself.
    # EPH-I0193: the API orders tags by date, so the first entry is not
    # always the highest version. A re-dated old tag must never downgrade
    # an install. [version] parses and compares X.Y.Z numerically, so
    # 0.14.10 sorts above 0.14.2 where a string sort would not.
    function Get-LatestEphorTag {
        # EPH-I0647: refuse every redirect on this fetch. PowerShell 7.4+
        # aborts an https-to-http downgrade by default, but 5.1 and
        # earlier 7.x follow it. MaximumRedirection 0 clamps every
        # version at once. Codeberg serves this API without a redirect
        # (verified 2026-08-22), so the clamp costs nothing today; a
        # future redirect takes the fallback path instead of being
        # followed. This is stricter than install.sh, which still follows
        # https-to-https redirects.
        # EPH-I0652: the clamp covers the default https URL only. A
        # test-channel URL (http:// or file://) skips it, matching
        # install.sh's scheme check, so a local test server may redirect.
        $irmParams = @{ Uri = $TAGS_API; TimeoutSec = 30 }
        if ($TAGS_API.StartsWith("https://")) { $irmParams.MaximumRedirection = 0 }
        $tagsJson = Invoke-RestMethod @irmParams
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

    # Return the release tag to install: the newest stable tag from the
    # Codeberg API, or the pinned fallback tag when the API does not yield
    # a valid tag or resolves below the fallback.
    function Resolve-EphorTag {
        try {
            $tag = Get-LatestEphorTag
        } catch {
            # Handled below: an empty tag takes the fallback branch, which
            # warns and continues with $EPHOR_FALLBACK_TAG.
            $tag = $null
        }
        if (-not $tag) {
            Write-Stderr "warning: could not resolve the latest ephor tag from the Codeberg API."
            Write-Stderr "The install continues with the fallback tag $EPHOR_FALLBACK_TAG."
            return $EPHOR_FALLBACK_TAG
        }
        if (Test-VersionOlder $tag $EPHOR_FALLBACK_TAG) {
            # EPH-I0193: a stale or re-dated API response must not
            # downgrade the install below the pinned fallback.
            Write-Stderr "warning: the resolved tag $tag is below the fallback $EPHOR_FALLBACK_TAG."
            Write-Stderr "The install continues with the fallback tag."
            return $EPHOR_FALLBACK_TAG
        }
        return $tag
    }

    # The words Zig reserves in the .name field of build.zig.zon
    # (EPH-I0629, install.sh parity — EPH-I0206). The field must be a
    # bare identifier, and Zig rejects every keyword, primitive type, and
    # literal there even though the words look like identifiers. The list
    # mirrors install.sh's ZON_RESERVED_WORDS, verified against zig
    # 0.16.0.
    $ZON_RESERVED_WORDS = @(
        "addrspace", "align", "allowzero", "and", "anyframe", "anytype",
        "asm", "break", "callconv", "catch", "comptime", "const",
        "continue", "defer", "else", "enum", "errdefer", "error",
        "export", "extern", "fn", "for", "if", "inline", "noalias",
        "noinline", "nosuspend", "opaque", "or", "orelse", "packed",
        "pub", "resume", "return", "linksection", "struct", "suspend",
        "switch", "test", "threadlocal", "try", "union", "unreachable",
        "var", "volatile", "while", "bool", "f16", "f32", "f64", "f80",
        "f128", "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16",
        "u32", "u64", "u128", "usize", "void", "noreturn", "type",
        "anyerror", "anyopaque", "comptime_int", "comptime_float",
        "c_short", "c_ushort", "c_int", "c_uint", "c_long", "c_ulong",
        "c_longlong", "c_ulonglong", "c_longdouble", "true", "false",
        "null", "undefined"
    )

    # Check that this directory is a Zig project.
    # EPH-I1111: refuse a symlink at build.zig before any read (install.sh
    # parity). Get-Content follows reparse points, so a planted link would
    # feed the victim file's content through the probes and the splice
    # below (the same mechanism the Zig side closed in EPH-I0670).
    # Get-Item -Force returns the link itself, where the reparse-point
    # attribute is visible; Test-Path follows the link and cannot see it.
    # On PowerShell 5.1 a dangling link reports "not found" in the
    # Test-Path check below, which refuses the install either way.
    $buildZigItem = Get-Item "build.zig" -Force -ErrorAction SilentlyContinue
    if ($buildZigItem -and
        ($buildZigItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        Write-Stderr "error: build.zig is a symlink."
        Write-Stderr "Replace it with a regular file before installing ephor."
        return 1
    }
    if (-not (Test-Path "build.zig")) {
        Write-Stderr @"
error: no build.zig found in current directory

  Ephor requires a Zig project with build.zig and build.zig.zon.
  To initialize a Zig project, run:

    zig init

  Then re-run the install:
    irm $REPO/raw/branch/main/install.ps1 | iex
"@
        return 1
    }

    if (-not (Test-Path "build.zig.zon")) {
        $projectName = (Split-Path -Leaf (Get-Location)) -replace '-', '_'
        $projectName = $projectName.ToLower()
        # EPH-I0206 (install.sh EPH-I0629 parity): .name must be a valid
        # bare Zig identifier, so a hostile directory name cannot inject
        # zon syntax. Characters outside a-z0-9_ become underscores, a
        # leading digit gets an underscore prefix, and a reserved word
        # falls back to a fixed name. Both fallbacks warn, like the sh
        # installer. A PowerShell regex match reads as a truthy array or
        # null, so the arms must cast through -not explicitly.
        $nameExpr = ""
        if (-not ($projectName -match '^[a-z_][a-z0-9_]*$') -or
            ($projectName -match '^[0-9]')) {
            $sanitized = $projectName -replace '[^a-z0-9_]', '_'
            # Split-Path -Leaf is empty at a drive root, which sh's
            # basename can never produce: fall back to the fixed name.
            if (-not $sanitized) { $sanitized = "project" }
            if ($sanitized -match '^[0-9]') { $sanitized = "_$sanitized" }
            $nameExpr = ".$sanitized"
            Write-Stderr "warning: '$projectName' is not a valid Zig identifier for the zon name."
            Write-Stderr "The zon uses the name '$sanitized'. Edit build.zig.zon to rename it."
        } else {
            $nameExpr = ".$projectName"
        }
        if ($ZON_RESERVED_WORDS -contains $nameExpr.Substring(1)) {
            Write-Stderr "warning: '$($nameExpr.Substring(1))' is a reserved word in Zig and cannot be the zon name."
            Write-Stderr "The zon uses the name 'project'. Edit build.zig.zon to rename it."
            $nameExpr = ".project"
        }
        Write-Host "No build.zig.zon found, creating one..."
        Set-ContentNoFollow -Path "build.zig.zon" -Value @"
.{
    .name = $nameExpr,
    .version = "0.0.0",
    .fingerprint = 0x0,
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
"@

        # EPH-I0192: do not spawn zig build for the fingerprint here. A
        # hostile build.zig would run attacker code. The zig fetch step
        # below repairs the 0x0 fingerprint from the hint zig fetch
        # prints.
        Write-Host "Created build.zig.zon for project '$projectName'"
    }

    # Detect the Zig version and pick a compatible ephor version.
    # EPH-I0187: no remote tag builds on Zig 0.15.x, so Zig below 0.16
    # pins the 0.15-era release by commit hash (see $EPHOR_0_15_COMMIT
    # above).
    $zigVersion = ""
    try {
        $zigVersion = (& zig version 2>$null | Out-String).Trim()
    } catch {
        # Handled below: an empty version takes the warning branch and
        # the install defaults to the latest tag.
        $zigVersion = ""
    }
    $EPHOR_URL = ""
    if ($zigVersion -match '^(\d+)\.(\d+)') {
        $zigMajor = [int]$Matches[1]
        $zigMinor = [int]$Matches[2]
        # Zig 0.16.0 and later track the latest ephor release. Zig 0.15.x
        # uses the pinned 0.15-era release by commit hash.
        if ($zigMajor -gt 0 -or $zigMinor -ge 16) {
            $EPHOR_TAG = Resolve-EphorTag
        } else {
            $EPHOR_TAG = "v0.11.13"
            $EPHOR_URL = "$REPO/archive/$EPHOR_0_15_COMMIT.tar.gz"
        }
    } else {
        Write-Stderr "warning: could not detect zig version, defaulting to latest"
        $EPHOR_TAG = Resolve-EphorTag
    }

    if ($zigVersion) {
        Write-Host "Installing ephor $EPHOR_TAG (Zig $zigVersion)..."
    } else {
        Write-Host "Installing ephor $EPHOR_TAG..."
    }
    if (-not $EPHOR_URL) {
        # EPH-I0652: tests override the archive URL through
        # EPHOR_ARCHIVE_URL (install.sh channel), gated by EPHOR_TEST_MODE
        # like EPHOR_TAGS_API (EPH-I0205). The Zig 0.15 pin path above
        # sets $EPHOR_URL directly and never takes the override, matching
        # install.sh's ordering.
        if ($testModeActive -and $env:EPHOR_ARCHIVE_URL) {
            $EPHOR_URL = $env:EPHOR_ARCHIVE_URL
        } else {
            if ($env:EPHOR_ARCHIVE_URL) {
                Write-Stderr "warning: EPHOR_ARCHIVE_URL is ignored without EPHOR_TEST_MODE=1."
            }
            $EPHOR_URL = "$REPO/archive/$EPHOR_TAG.tar.gz"
        }
    }

    Write-Host "Adding ephor dependency..."
    # EPH-I0192: zig fetch reads build.zig.zon but never runs build.zig,
    # so a hostile build.zig still executes no code here. On a fresh zon
    # with fingerprint 0x0, zig fetch fails and prints a "use this value"
    # hint with the computed fingerprint. Patch the hint in and fetch
    # again.
    # PowerShell 7.4+ turns a nonzero native exit into a terminating
    # error under "Stop". Relax the preference so this code can inspect
    # the failure.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $fetchOut = zig fetch --save=ephor $EPHOR_URL 2>&1 | Out-String
    $fetchRc = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    if ($null -eq $fetchRc) { $fetchRc = 1 }
    if ($fetchRc -ne 0) {
        if ($fetchOut -match 'use this value: (0x[0-9a-f]+)') {
            $suggested = $Matches[1]
            $zon = Get-Content "build.zig.zon" -Raw -Encoding UTF8
            # EPH-I0648: allow any spacing around the placeholder and
            # verify the patch changed the content. The case-sensitive
            # replace matches only the canonical lowercase field, and \b
            # stops a real fingerprint that starts with 0x0 from matching
            # as the placeholder prefix. A zon whose layout does not match
            # stops with a clear message instead of failing the next
            # fetch the same way.
            $patched = $zon -creplace '\.fingerprint[ \t]*=[ \t]*0x0\b', ".fingerprint = $suggested"
            if ($patched -eq $zon) {
                Write-Stderr $fetchOut
                Write-Stderr @"
error: could not repair the fingerprint in build.zig.zon

  The .fingerprint field does not match the 0x0 placeholder.
  Set it to the value zig printed above, then re-run the install.
"@
                return 1
            }
            # EPH-I0649: $zon keeps the file's trailing newline
            # (Get-Content -Raw), and Set-Content appends one terminator
            # of its own. Trim the trailing CR/LF first so each repair
            # writes the same end-of-file the zon already had instead of
            # adding one blank line per repair.
            $patched = $patched.TrimEnd("`r", "`n")
            Set-ContentNoFollow -Path "build.zig.zon" -Value $patched
            # This fetch is authoritative: a failure aborts the install.
            # EPH-I0645: capture the exit code under "Continue" like the
            # first fetch. Under "Stop", PowerShell 7.4+ throws before
            # this code reads $LASTEXITCODE and the original exit code is
            # lost.
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            $fetchOut2 = zig fetch --save=ephor $EPHOR_URL 2>&1 | Out-String
            $fetchRc2 = $LASTEXITCODE
            $ErrorActionPreference = $prevEAP
            if ($null -eq $fetchRc2) { $fetchRc2 = 1 }
            if ($fetchRc2 -ne 0) {
                Write-Stderr $fetchOut2
                return $fetchRc2
            }
        } else {
            # No hint means a real fetch failure (network, hash, server).
            # Show the captured error and keep the original exit code.
            Write-Stderr $fetchOut
            return $fetchRc
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

    $buildContent = Get-Content "build.zig" -Raw -Encoding UTF8

    if ($buildContent -match '// Ephor static analysis') {
        # Ephor block exists - replace it with the canonical version
        $lines = Get-Content "build.zig" -Encoding UTF8
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
        Write-Stderr "warning: ephor dependency found but build steps have non-standard layout"
        Write-Stderr "Please update your ephor build steps manually (see README)"
    } else {
        Write-Host "Adding ephor build steps to build.zig..."

        $lines = Get-Content "build.zig" -Encoding UTF8
        $lastInstallLine = -1

        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "installArtifact") {
                $lastInstallLine = $i
            }
        }

        if ($lastInstallLine -eq -1) {
            # EPH-I0635 parity: the dependency landed but the build steps
            # did not. Exit nonzero so automation does not mistake a
            # partial install for success.
            Write-Stderr "warning: could not find installArtifact in build.zig"
            Write-Stderr "The ephor dependency was added, but the build steps were not."
            Write-Stderr "Add the build steps manually (see README)."
            return 1
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

    return 0
}

# Report the install code only when this file runs as a script. The
# $MyInvocation.PSCommandPath property is populated only when the caller is
# a script (about_Automatic_Variables), so under irm | iex it stays empty
# and the user's shell stays open. The code is the script block's only
# output.
if ($MyInvocation.PSCommandPath) { exit $installExitCode }
