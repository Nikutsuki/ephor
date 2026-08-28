# Regression pin for install.ps1's Find-LastInstallArtifactLine anchor walk
# (EPH-I1219; B136; serves REL-ZERO-1 and REL-RELEASE-6). Direct port of
# tests/install-sh-tests.sh t48 (EPH-I0715) plus the B129 review-r1
# case-variant control line. The t48 fixture is verbatim: a real call, then
# a full-line comment mention, a string-literal mention on a
# multiline-string opener, and a \\-body continuation line ending in a
# semicolon. The pin asserts the block lands right after the real call and
# the string body survives intact.
#
# The installer has no function-import seam: dot-sourcing executes the
# whole install. The sh suite never sources functions either; it runs the
# real installer as a subprocess against hermetic fixtures. This suite
# takes the same shape: a fake zig on PATH answers version, fetch, and
# ast-check, a local HTTP listener serves the tags API, and
# EPHOR_TEST_MODE unlocks the file:// archive override. No network is
# touched.
#
# The control line carries a case-variant token in code position plus a
# lowercase mention in a trailing comment. The bare r1 example
# (b.InstallArtifact(exe);) dies at the case-sensitive Contains pre-filter
# and never reaches the walk, so it cannot pin the token match this pin
# exists to guard. The trailing-comment shape reaches the walk: -ceq skips
# the variant, -eq would match it and mis-anchor the block, and the
# marker-position check below fails.
#
# Run:
#   pwsh -NoProfile -File scripts/test-install-ps1-anchor.ps1
#   PS1_ANCHOR_KEEP=1 ...        (keep the scratch tree)
#   PS1_ANCHOR_INSTALLER=<path>  (run against another install.ps1 copy)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$installPs1 = if ($env:PS1_ANCHOR_INSTALLER) {
    $env:PS1_ANCHOR_INSTALLER
} else {
    Join-Path $repoRoot "install.ps1"
}
$pwshPath = (Get-Process -Id $PID).Path
$testRoot = Join-Path $repoRoot ".tmp/ps1-anchor"
$keep = ($env:PS1_ANCHOR_KEEP -eq "1")

$script:checks = 0
$script:failed = 0

function pass {
    param([string]$label)
    Write-Host "[PASS] $label"
}

function fail {
    param([string]$label)
    $script:failed += 1
    Write-Host "[FAIL] $label"
}

function check {
    param([string]$label, [scriptblock]$test)
    $script:checks += 1
    $ok = $false
    try {
        $ok = [bool](& $test)
    } catch {
        $ok = $false
    }
    if ($ok) { pass $label } else { fail $label }
}

if (Test-Path $testRoot) { Remove-Item -Recurse -Force $testRoot }
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

# The scratch project dir doubles as the zon name source. "t48" is a valid
# Zig identifier, so the zon creation prints no stderr warning.
$D = Join-Path $testRoot "t48"
New-Item -ItemType Directory -Path $D | Out-Null
$binDir = Join-Path $testRoot "bin"
New-Item -ItemType Directory -Path $binDir | Out-Null
$buildZig = Join-Path $D "build.zig"

# The t48 fixture verbatim (tests/install-sh-tests.sh:1178-1194) plus the
# r1 case-variant control line right after the real call.
$fixtureLines = @(
    'const std = @import("std");'
    'pub fn build(b: *std.Build) !void {'
    '    const exe = b.addExecutable(.{'
    '        .name = "demo",'
    '        .root_module = b.createModule(.{}),'
    '    });'
    '    b.installArtifact(exe);'
    '    b.InstallArtifact(exe); // installArtifact case-variant control'
    '    // installArtifact mention in a full-line comment below the call.'
    '    const usage = "installArtifact docs" ++'
    '        \\'
    '        \\ one;'
    '        \\ two'
    '    ;'
    '    _ = usage;'
    '}'
)
Set-Content -Path $buildZig -Value $fixtureLines -Encoding UTF8

# The fake zig answers the three commands the install flow runs (version,
# fetch, ast-check) with no network and no compilation.
$fakeZig = Join-Path $binDir "zig"
Set-Content -Path $fakeZig -Encoding ASCII -Value @(
    '#!/bin/sh'
    '# fake zig for the install-ps1 anchor pin'
    'if [ "$1" = "version" ]; then'
    '    printf "%s\n" "0.16.0"'
    '    exit 0'
    'fi'
    'exit 0'
)
$null = & chmod +x $fakeZig
if ($LASTEXITCODE -ne 0) { throw "chmod failed for the fake zig" }

# The fake zig never opens the archive. The file exists so the override
# URL is a real local path.
$archivePath = Join-Path $testRoot "archive.tar.gz"
Set-Content -Path $archivePath -Value 'dummy archive' -Encoding ASCII
$archiveUrl = "file://" + $archivePath

# Bind one local HTTP port and serve the tags JSON once. Both
# Invoke-RestMethod and HttpClient reject file:// URLs on this pwsh, so
# local HTTP is the hermetic tags channel.
function startTagsListener {
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $probe = [System.Net.Sockets.TcpListener]::new(
            [System.Net.IPAddress]::Loopback, 0)
        $probe.Start()
        $port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
        $probe.Stop()
        $listener = [System.Net.HttpListener]::new()
        try {
            $listener.Prefixes.Add("http://127.0.0.1:$port/")
            $listener.Start()
            return @($listener, $port)
        } catch {
            $listener.Close()
        }
    }
    throw "could not bind a local HTTP port for the tags fixture"
}

$tagsJson = '[{"name":"v0.99.2"},{"name":"v0.99.1"}]'
$bound = startTagsListener
$listener = $bound[0]
$tagsPort = $bound[1]

# Run the real installer as a subprocess in the scratch dir, the sh
# suite's run_installer shape. The Process redirection feeds pipes, not
# files, so the suite drains them into out.log and err.log after the
# child exits (the output is far below the pipe buffer). Write-Stderr
# uses the process stderr handle, so it lands in err.log.
$outLog = Join-Path $testRoot "out.log"
$errLog = Join-Path $testRoot "err.log"
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $pwshPath
$psi.ArgumentList.Add("-NoProfile")
$psi.ArgumentList.Add("-NonInteractive")
$psi.ArgumentList.Add("-File")
$psi.ArgumentList.Add($installPs1)
$psi.WorkingDirectory = $D
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.Environment["PATH"] = $binDir + [System.IO.Path]::PathSeparator + $env:PATH
$psi.Environment["EPHOR_TEST_MODE"] = "1"
$psi.Environment["EPHOR_TAGS_API"] = "http://127.0.0.1:$tagsPort/tags.json"
$psi.Environment["EPHOR_ARCHIVE_URL"] = $archiveUrl
$child = [System.Diagnostics.Process]::new()
$child.StartInfo = $psi
# The suite's main thread serves the one tags request while the child
# runs: a Task.Run scriptblock has no runspace on a thread-pool thread,
# so the accept stays on this thread through GetContextAsync polling.
$ctxTask = $listener.GetContextAsync()
$child.Start() | Out-Null
$served = $false
while (-not $child.HasExited) {
    if ($ctxTask.Wait(500)) {
        $ctx = $ctxTask.Result
        $body = [System.Text.Encoding]::UTF8.GetBytes($tagsJson)
        $ctx.Response.StatusCode = 200
        $ctx.Response.ContentType = "application/json"
        $ctx.Response.ContentLength64 = $body.Length
        $ctx.Response.OutputStream.Write($body, 0, $body.Length)
        $ctx.Response.OutputStream.Close()
        $served = $true
        break
    }
}
# Bound the wait so a hung child cannot stall the gate forever. The
# child's own 30s fetch timeout keeps a healthy run well inside 90s.
if (-not $child.WaitForExit(90000)) {
    $child.Kill($true)
    throw "install subprocess timed out"
}
$installRc = $child.ExitCode
[System.IO.File]::WriteAllText($outLog, $child.StandardOutput.ReadToEnd())
[System.IO.File]::WriteAllText($errLog, $child.StandardError.ReadToEnd())
try { $listener.Stop() } catch { }

check "install exits 0" { $installRc -eq 0 }
# The channel proof: the child must have consumed the served tags (a run
# that takes the fallback path instead would also trip the trio check,
# but this check names the mechanism directly).
check "tags fixture served" { $served }

# The strict-stderr pin: a successful run prints exactly the
# inactive-verification trio (install.sh parity, EPH-I1220). A changed
# stderr surface fails the pin instead of drifting past it.
$errNorm = ([System.IO.File]::ReadAllText($errLog)) -replace "`r`n", "`n"
$trio = "warning: release signature verification is inactive.`n" +
    "This installer embeds no release public key yet.`n" +
    "The first signed release activates the check.`n"
check "stderr is the inactive-verification trio" { $errNorm -ceq $trio }

# The composed build.zig: the anchor walk result is read back from the
# spliced file, exactly like t48's line/count assertions.
$lines = [System.IO.File]::ReadAllLines($buildZig)
$installIdx = -1
$markerIdx = -1
$markerCount = 0
$bodyIdx = -1
$bodyCount = 0
$mentionCount = 0
$commentCount = 0
$controlIdx = -1
$controlCount = 0
for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($installIdx -eq -1 -and $line -cmatch '^\s*b\.installArtifact\(exe\);\s*$') {
        $installIdx = $i
    }
    if ($line -cmatch '^\s*// Ephor static analysis\s*$') {
        $markerCount += 1
        if ($markerIdx -eq -1) { $markerIdx = $i }
    }
    if ($line.Contains('\\ one;')) {
        $bodyCount += 1
        if ($bodyIdx -eq -1) { $bodyIdx = $i }
    }
    if ($line.Contains('installArtifact docs')) { $mentionCount += 1 }
    if ($line.Contains('full-line comment below the call')) { $commentCount += 1 }
    if ($line.Contains('b.InstallArtifact(exe)')) {
        $controlCount += 1
        if ($controlIdx -eq -1) { $controlIdx = $i }
    }
}

# The t48 marker-position pin: the block lands right after the real call
# (install + 2, one blank separator). A walk that returns the control
# line, the comment line, or the string opener fails here.
check "block lands right after the real call" {
    $installIdx -ge 0 -and $markerIdx -eq $installIdx + 2
}
check "block appears exactly once" { $markerCount -eq 1 }
check "multiline string body survives intact" { $bodyCount -eq 1 }
check "string body sits below the block" { $bodyIdx -gt $markerIdx }
check "string-literal mention unchanged" { $mentionCount -eq 1 }
check "comment mention unchanged" { $commentCount -eq 1 }
check "case-variant control line survives" { $controlCount -eq 1 }
check "case-variant control line sits below the block" { $controlIdx -gt $markerIdx }

if (-not $keep) { Remove-Item -Recurse -Force $testRoot }

Write-Host ""
Write-Host "ps1 anchor: $script:checks checks, $script:failed failed"
if ($script:failed -ne 0) { exit 1 }
exit 0
