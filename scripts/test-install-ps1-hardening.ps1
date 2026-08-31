# Regression pins for the RED3 re-derivation wave fixes in install.ps1:
# EPH-I1272 (fingerprint repair targets the code-position field),
# EPH-I1273 (byte caps on the local build.zig and build.zig.zon reads),
# and EPH-I1274 (the echoed project dir name is terminal-sanitized).
# Serves REL-REDTEAM-4. Same harness shape as test-install-ps1-anchor.ps1:
# the real installer runs as a subprocess against hermetic fixtures. A
# fake zig on PATH answers version, fetch, and ast-check; a local HTTP
# listener serves the tags API; and EPHOR_TEST_MODE unlocks the file://
# archive override. No network is touched.
#
# The fingerprint pins use the discriminating one-line zon from the
# redteam evidence: a string value that mentions ".fingerprint = 0x0"
# before the real inline field. The pre-fix -creplace rewrote every
# occurrence, so the mention was corrupted and the real field stayed 0x0.
# A second pin runs the same one-line shape without the mention: the
# inline code-position field must still repair, so the fix must not
# degrade to line-start anchoring.
#
# The cap pins create an oversized local file and assert the installer
# fails closed with the named cap message before Get-Content buffers it.
# The sanitize pin runs in a project dir whose name carries an ESC byte
# and asserts every echo renders the sanitized form and no raw ESC byte
# reaches the logs.
#
# Run:
#   pwsh -NoProfile -File scripts/test-install-ps1-hardening.ps1
#   PS1_HARDEN_KEEP=1 ...        (keep the scratch tree)
#   PS1_HARDEN_INSTALLER=<path>  (run against another install.ps1 copy)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$installPs1 = if ($env:PS1_HARDEN_INSTALLER) {
    $env:PS1_HARDEN_INSTALLER
} else {
    Join-Path $repoRoot "install.ps1"
}
$pwshPath = (Get-Process -Id $PID).Path
$testRoot = Join-Path $repoRoot ".tmp/ps1-hardening"
$keep = ($env:PS1_HARDEN_KEEP -eq "1")

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
$binDir = Join-Path $testRoot "bin"
New-Item -ItemType Directory -Path $binDir | Out-Null

# The fake zig answers version, and serves every fetch and ast-check with
# success. When FETCH_FAIL_ONCE names an existing file, the next fetch
# consumes it, prints a "use this value" hint on stderr, and exits 1 (the
# fingerprint-repair runs).
$fakeZig = Join-Path $binDir "zig"
Set-Content -Path $fakeZig -Encoding ASCII -Value @(
    '#!/bin/sh'
    '# fake zig for the install-ps1 hardening pins'
    'if [ "$1" = "version" ]; then'
    '    printf "%s\n" "0.16.0"'
    '    exit 0'
    'fi'
    'if [ -n "${FETCH_FAIL_ONCE:-}" ] && [ -e "$FETCH_FAIL_ONCE" ]; then'
    '    printf "%s\n" "error: unable to verify package" >&2'
    '    printf "%s\n" "use this value: 0x1234dead" >&2'
    '    rm -f "$FETCH_FAIL_ONCE"'
    '    exit 1'
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

# Bind one local HTTP port (the anchor suite's listener shape). The
# suite's main thread serves the one tags request while the child runs.
function startLocalListener {
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
$serveDeadlineMs = 90000

# The strict-stderr pin for a clean run (install.sh parity, EPH-I1220).
$trio = "warning: release signature verification is inactive.`n" +
    "This installer embeds no release public key yet.`n" +
    "The first signed release activates the check.`n"

# Write the fresh build.zig fixture (one installArtifact call) for a
# work dir.
function writeBuildZig {
    param([string]$WorkDir)
    Set-Content -Path (Join-Path $WorkDir "build.zig") -Encoding UTF8 -Value @(
        'const std = @import("std");'
        'pub fn build(b: *std.Build) !void {'
        '    const target = b.standardTargetOptions(.{});'
        '    const optimize = b.standardOptimizeOption(.{});'
        '    const exe = b.addExecutable(.{'
        '        .name = "demo",'
        '        .root_module = b.createModule(.{}),'
        '    });'
        '    b.installArtifact(exe);'
        '}'
    )
}

# Run the real installer as a subprocess in $WorkDir. $FailFetchOnce
# names the FETCH_FAIL_ONCE marker file, or $null for a clean run.
# Returns a hashtable with the exit code and the output/error logs.
function runInstall {
    param(
        [string]$Tag,
        [string]$WorkDir,
        [string]$FailFetchOnce
    )
    $bound = startLocalListener
    $listener = $bound[0]
    $port = $bound[1]
    $tagsBody = [System.Text.Encoding]::UTF8.GetBytes($tagsJson)
    $outLog = Join-Path $testRoot "$Tag-out.log"
    $errLog = Join-Path $testRoot "$Tag-err.log"
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwshPath
    $psi.ArgumentList.Add("-NoProfile")
    $psi.ArgumentList.Add("-NonInteractive")
    $psi.ArgumentList.Add("-File")
    $psi.ArgumentList.Add($installPs1)
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Environment["PATH"] = $binDir + [System.IO.Path]::PathSeparator + $env:PATH
    $psi.Environment["EPHOR_TEST_MODE"] = "1"
    $psi.Environment["EPHOR_TAGS_API"] = "http://127.0.0.1:$port/tags.json"
    $psi.Environment["EPHOR_ARCHIVE_URL"] = $archiveUrl
    if ($FailFetchOnce) {
        $psi.Environment["FETCH_FAIL_ONCE"] = $FailFetchOnce
    }
    $child = [System.Diagnostics.Process]::new()
    $child.StartInfo = $psi
    $ctxTask = $listener.GetContextAsync()
    $child.Start() | Out-Null
    $served = $false
    $serveDeadline = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $child.HasExited -and
        $serveDeadline.ElapsedMilliseconds -lt $serveDeadlineMs) {
        if ($ctxTask.Wait(200)) {
            $ctx = $ctxTask.Result
            $ctx.Response.StatusCode = 200
            $ctx.Response.ContentType = "application/json"
            $ctx.Response.ContentLength64 = $tagsBody.Length
            try {
                $ctx.Response.OutputStream.Write($tagsBody, 0, $tagsBody.Length)
            } catch {
                # The child aborted the tags read. The request was served.
            } finally {
                try { $ctx.Response.OutputStream.Close() } catch { }
            }
            $served = $true
            break
        }
    }
    if (-not $child.WaitForExit($serveDeadlineMs)) {
        $child.Kill($true)
        throw "install subprocess timed out"
    }
    $rc = $child.ExitCode
    [System.IO.File]::WriteAllText($outLog, $child.StandardOutput.ReadToEnd())
    [System.IO.File]::WriteAllText($errLog, $child.StandardError.ReadToEnd())
    try { $listener.Stop() } catch { }
    return @{
        rc = $rc
        out = [System.IO.File]::ReadAllText($outLog)
        err = [System.IO.File]::ReadAllText($errLog)
        outLog = $outLog
        errLog = $errLog
        served = $served
    }
}

function readZon {
    param([string]$WorkDir)
    return [System.IO.File]::ReadAllText((Join-Path $WorkDir "build.zig.zon"))
}

# --- EPH-I1272: fingerprint repair targets the code-position field -------
# The discriminating one-line zon: a string value mentions the marker
# before the real inline field. The pre-fix -creplace rewrote the mention
# (first occurrence), corrupted the string, and left the real field at
# 0x0, so the authoritative fetch failed. The repair must skip the
# mention and patch the real field.
$oneLineZon = '.{ .name = ".fingerprint = 0x0 mention", .version = "0.0.0", ' +
    '.fingerprint = 0x0, .paths = .{} }'
$D1 = Join-Path $testRoot "fpcode"
New-Item -ItemType Directory -Path $D1 | Out-Null
writeBuildZig $D1
[System.IO.File]::WriteAllText((Join-Path $D1 "build.zig.zon"), $oneLineZon + "`n")
$failMarker = Join-Path $D1 "fail-once"
[System.IO.File]::WriteAllText($failMarker, "")
$fpRun = runInstall -Tag "fpcode" -WorkDir $D1 -FailFetchOnce $failMarker

check "fpcode run exits 0" { $fpRun.rc -eq 0 }
check "fpcode run serves the tags fixture" { $fpRun.served }
check "fpcode run repairs the code-position field" {
    (readZon $D1).Contains('.fingerprint = 0x1234dead')
}
check "fpcode run leaves the string mention intact" {
    (readZon $D1).Contains('".fingerprint = 0x0 mention"')
}
check "fpcode run stderr is the inactive-verification trio" {
    ($fpRun.err -replace "`r`n", "`n") -ceq $trio
}

# The no-regression control: the same one-line shape without the
# mention. The inline code-position field must still repair, so the fix
# must not degrade to line-start anchoring.
$oneLineZonClean = '.{ .name = .fpbenign, .version = "0.0.0", .fingerprint = 0x0, .paths = .{} }'
$D2 = Join-Path $testRoot "fpbenign"
New-Item -ItemType Directory -Path $D2 | Out-Null
writeBuildZig $D2
[System.IO.File]::WriteAllText((Join-Path $D2 "build.zig.zon"), $oneLineZonClean + "`n")
$failMarker2 = Join-Path $D2 "fail-once"
[System.IO.File]::WriteAllText($failMarker2, "")
$fpCleanRun = runInstall -Tag "fpbenign" -WorkDir $D2 -FailFetchOnce $failMarker2

check "fpbenign run exits 0" { $fpCleanRun.rc -eq 0 }
check "fpbenign run repairs the inline field" {
    (readZon $D2).Contains('.fingerprint = 0x1234dead')
}

# The production template shape: the multiline zon the installer writes,
# with the field at line start and a string mention on another line. The
# pre-fix -creplace rewrote the mention too (one match per occurrence),
# so this pin asserts the repair leaves every other line intact.
$D2b = Join-Path $testRoot "fptemplate"
New-Item -ItemType Directory -Path $D2b | Out-Null
writeBuildZig $D2b
[System.IO.File]::WriteAllText((Join-Path $D2b "build.zig.zon"), @(
    '.{'
    '    .name = .fptemplate,'
    '    .version = "0.0.0",'
    '    .fingerprint = 0x0,'
    '    .paths = .{ "build.zig", "note: .fingerprint = 0x0", "src" },'
    '}'
    ''
) -join "`n")
$failMarker2b = Join-Path $D2b "fail-once"
[System.IO.File]::WriteAllText($failMarker2b, "")
$fpTemplateRun = runInstall -Tag "fptemplate" -WorkDir $D2b -FailFetchOnce $failMarker2b

check "fptemplate run exits 0" { $fpTemplateRun.rc -eq 0 }
check "fptemplate run repairs the line-start field" {
    (readZon $D2b).Contains('.fingerprint = 0x1234dead,')
}
check "fptemplate run leaves the paths mention intact" {
    (readZon $D2b).Contains('"note: .fingerprint = 0x0"')
}

# The string-only shape: the marker exists only inside a string value.
# The pre-fix -creplace rewrote the string mention, leaked the hint into
# the zon, and the second fetch passed, so the install reported success
# with a corrupted zon. The repair must leave the string alone and fail
# with the clear message.
$D2c = Join-Path $testRoot "fpnomarker"
New-Item -ItemType Directory -Path $D2c | Out-Null
writeBuildZig $D2c
[System.IO.File]::WriteAllText((Join-Path $D2c "build.zig.zon"),
    '.{ .name = ".fingerprint = 0x0 only mention", .version = "0.0.0", .paths = .{} }' + "`n")
$failMarker2c = Join-Path $D2c "fail-once"
[System.IO.File]::WriteAllText($failMarker2c, "")
$fpNoMarkerRun = runInstall -Tag "fpnomarker" -WorkDir $D2c -FailFetchOnce $failMarker2c

check "fpnomarker run exits 1" { $fpNoMarkerRun.rc -eq 1 }
check "fpnomarker run refuses the repair" {
    $fpNoMarkerRun.err -match 'error: could not repair the fingerprint in build\.zig\.zon'
}
check "fpnomarker run leaves the string mention intact" {
    (readZon $D2c).Contains('.fingerprint = 0x0 only mention')
}
check "fpnomarker run leaks no hint into the zon" {
    -not (readZon $D2c).Contains('0x1234dead')
}

# --- EPH-I1273: byte caps on the local reads ---------------------------
# An oversized build.zig must fail closed with the named cap message
# before Get-Content buffers it.
$D3 = Join-Path $testRoot "capbuildzig"
New-Item -ItemType Directory -Path $D3 | Out-Null
[System.IO.File]::WriteAllText((Join-Path $D3 "build.zig"), 'x' * 524289)
Set-Content -Path (Join-Path $D3 "build.zig.zon") -Encoding UTF8 -Value @(
    '.{'
    '    .name = .capbuildzig,'
    '    .version = "0.0.0",'
    '    .fingerprint = 0x1234dead,'
    '    .paths = .{ "build.zig", "build.zig.zon", "src" },'
    '}'
)
$capBzRun = runInstall -Tag "capbuildzig" -WorkDir $D3 -FailFetchOnce $null

check "capbuildzig run exits 1" { $capBzRun.rc -eq 1 }
check "capbuildzig run names the build.zig cap" {
    $capBzRun.err -match 'error: build\.zig is larger than 524288 bytes\.'
}

# An oversized build.zig.zon must fail closed the same way. The pre-fix
# installer buffered the whole file into the probe array.
$D4 = Join-Path $testRoot "capzon"
New-Item -ItemType Directory -Path $D4 | Out-Null
writeBuildZig $D4
[System.IO.File]::WriteAllText((Join-Path $D4 "build.zig.zon"), 'x' * 65537)
$capZonRun = runInstall -Tag "capzon" -WorkDir $D4 -FailFetchOnce $null

check "capzon run exits 1" { $capZonRun.rc -eq 1 }
check "capzon run names the zon cap" {
    $capZonRun.err -match 'error: build\.zig\.zon is larger than 65536 bytes\.'
}

# --- EPH-I1274: the echoed project dir name is terminal-sanitized -------
# A dir name that carries an ESC byte fires the warning arm, which must
# echo the sanitized form and never the raw ESC.
$escName = "my" + [char]0x1B + "proj"
$D5 = Join-Path $testRoot $escName
New-Item -ItemType Directory -Path $D5 | Out-Null
writeBuildZig $D5
$escRun = runInstall -Tag "escname" -WorkDir $D5 -FailFetchOnce $null

check "escname run exits 0" { $escRun.rc -eq 0 }
check "escname run echoes the sanitized warning" {
    $escRun.err.Contains("warning: 'my?proj' is not a valid Zig identifier")
}
check "escname run echoes the sanitized created line" {
    $escRun.out.Contains("Created build.zig.zon for project 'my?proj'")
}
check "escname run writes no raw ESC to stderr" {
    -not ([System.IO.File]::ReadAllBytes($escRun.errLog) -contains 27)
}
check "escname run writes no raw ESC to stdout" {
    -not ([System.IO.File]::ReadAllBytes($escRun.outLog) -contains 27)
}
check "escname run keeps the zon name sanitization" {
    (readZon $D5).Contains('.name = .my_proj')
}

if (-not $keep) { Remove-Item -Recurse -Force $testRoot }

Write-Host ""
Write-Host "ps1 hardening: $script:checks checks, $script:failed failed"
if ($script:failed -ne 0) { exit 1 }
exit 0
