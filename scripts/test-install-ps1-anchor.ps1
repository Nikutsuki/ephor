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
# EPHOR_TEST_MODE unlocks the file:// archive override. WP-7: the
# embedded release key activates the signature check, so every run
# injects EPHOR_RELEASE_PUBKEY (the fixture-key seam) and a fake
# minisign on PATH accepts the signature. No network is touched.
#
# The control line carries a case-variant token in code position plus a
# lowercase mention in a trailing comment. The bare r1 example
# (b.InstallArtifact(exe);) dies at the case-sensitive Contains pre-filter
# and never reaches the walk, so it cannot pin the token match this pin
# exists to guard. The trailing-comment shape reaches the walk: -ceq skips
# the variant, -eq would match it and mis-anchor the block, and the
# marker-position check below fails.
#
# EPH-I1231 (B136a): two more subprocess runs activate the release
# signature check with EPHOR_RELEASE_PUBKEY (EPHOR_TEST_MODE-gated) and
# a fake minisign on PATH. Test-EphorReleaseSignature's active branch is
# the only Get-BoundedFile caller, and with the archive and signature
# URLs pointed at a local HTTP listener the bounded download takes its
# HTTP arm twice per run. On .NET 5+ a bare EnsureSuccessStatusCode()
# emits the response into the function output, which makes the byte
# cap's fail-closed return read as success (details in the pin block).
# The over-cap run discriminates the defect on a .NET 5+ pwsh (7.6.5
# here).
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

# WP-7: the embedded release key activates Test-EphorReleaseSignature, so
# the scenarios inject EPHOR_RELEASE_PUBKEY (the fixture-key seam) and a
# fake minisign on PATH accepts the signature. The derived SIG_URL points
# at the live raw-branch route, so every run sets EPHOR_SIG_URL to the
# local signature file to stay hermetic (the override replaces the
# derived URL wholesale).
$sigPath = "$archivePath.minisig"
Set-Content -Path $sigPath -Value 'dummy signature' -Encoding ASCII
$fakeMinisign = Join-Path $binDir "minisign"
Set-Content -Path $fakeMinisign -Encoding ASCII -Value @(
    '#!/bin/sh'
    '# fake minisign: every signature verifies'
    'exit 0'
)
$null = & chmod +x $fakeMinisign
if ($LASTEXITCODE -ne 0) { throw "chmod failed for the fake minisign" }

# Bind one local HTTP port. Both Invoke-RestMethod and HttpClient reject
# file:// URLs on this pwsh, so local HTTP is the hermetic network
# channel for the tags API and the pubkey-channel downloads.
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
$bound = startLocalListener
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
$psi.Environment["EPHOR_SIG_URL"] = "file://" + $sigPath
# WP-7: any non-empty key reaches the active branch; the fake minisign
# never reads it, so the pin needs no real keypair.
$psi.Environment["EPHOR_RELEASE_PUBKEY"] = "untrusted comment: ephor ps1 anchor pin (fake)"
$child = [System.Diagnostics.Process]::new()
$child.StartInfo = $psi
# The suite's main thread serves the one tags request while the child
# runs: a Task.Run scriptblock has no runspace on a thread-pool thread,
# so the accept stays on this thread through GetContextAsync polling.
# One accept is pending at a time. A wait that times out keeps waiting
# on the same task: an abandoned task would still hold the next
# connection (EPH-I1237). The serve loop carries a wall-clock bound
# (EPH-I1241): a child that hangs before its first request must reach
# the WaitForExit/Kill path below instead of spinning forever.
$serveDeadlineMs = 90000
$ctxTask = $listener.GetContextAsync()
$child.Start() | Out-Null
$served = $false
$serveDeadline = [System.Diagnostics.Stopwatch]::StartNew()
while (-not $child.HasExited -and $serveDeadline.ElapsedMilliseconds -lt $serveDeadlineMs) {
    if ($ctxTask.Wait(200)) {
        $ctx = $ctxTask.Result
        $body = [System.Text.Encoding]::UTF8.GetBytes($tagsJson)
        $ctx.Response.StatusCode = 200
        $ctx.Response.ContentType = "application/json"
        $ctx.Response.ContentLength64 = $body.Length
        try {
            $ctx.Response.OutputStream.Write($body, 0, $body.Length)
        } catch {
            # The child aborted the tags read. A killed child leaves the
            # response half-written. The request was still served.
        } finally {
            try { $ctx.Response.OutputStream.Close() } catch { }
        }
        $served = $true
        break
    }
}
# Bound the wait so a hung child cannot stall the gate forever. The
# child's own 30s fetch timeout keeps a healthy run well inside 90s.
if (-not $child.WaitForExit($serveDeadlineMs)) {
    $child.Kill($true)
    throw "install subprocess timed out"
}
$installRc = $child.ExitCode
[System.IO.File]::WriteAllText($outLog, $child.StandardOutput.ReadToEnd())
[System.IO.File]::WriteAllText($errLog, $child.StandardError.ReadToEnd())
try { $listener.Stop() } catch { }

check "install exits 0" { $installRc -eq 0 }
# The channel proof: the child must have consumed the served tags (a run
# that takes the fallback path instead would also trip the stderr check,
# but this check names the mechanism directly).
check "tags fixture served" { $served }

# The strict-stderr pin (WP-7): the active verification prints nothing
# to stderr on success, and the completion line lands on stdout. A
# changed installer stderr surface fails the pin instead of drifting
# past it.
$errNorm = ([System.IO.File]::ReadAllText($errLog)) -replace "`r`n", "`n"
check "stderr stays empty on the active verification" { $errNorm -ceq "" }
$outText = [System.IO.File]::ReadAllText($outLog)
check "the verification line prints" { $outText.Contains("Release signature verified.") }

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

# --- EPH-I1231 (B136a): the Get-BoundedFile HTTP-arm emission pin --------
# The pubkey channel activates Test-EphorReleaseSignature's active branch
# (the only Get-BoundedFile caller): EPHOR_RELEASE_PUBKEY supplies the
# key and the setup fake minisign (created above) verifies everything.
# Two subprocess runs point the archive and signature URLs at a local
# HTTP listener, so the bounded download takes its HTTP arm twice per
# run.
#
# On .NET 5+ a bare EnsureSuccessStatusCode() emits the response into
# the function output (probed on this pwsh: the call returns the message
# and the statement emits it). The caller's -not test reads a two-element
# array as success, so the leak is invisible on a clean download. The
# over-cap return path changes the shape: the emission lands first and
# return $false follows, so the output is @(response, $false) — the
# caller still reads success, and the 1 MiB byte cap fails open (a
# truncated signature verifies and the install exits 0). The over-cap
# run pins exit 1 plus the named download failure, which discriminates
# the defect on a .NET 5+ pwsh (7.6.5 here).

# Any non-empty key reaches the active branch: the fake minisign never
# reads it, so the pin needs no real keypair.
$testPubkey = "untrusted comment: ephor B136a pubkey-channel pin (fake)"

# Run the installer subprocess with the pubkey channel active and serve
# its three fetches (tags, archive, signature) from a fresh local HTTP
# listener. $SigBodyLength controls the signature body size: a normal
# size pins the success path, one byte over the 1 MiB cap pins the
# fail-closed cap. Returns the exit code, the output logs, and the
# served-request flags in a hashtable.
function runPubkeyInstall {
    param(
        [string]$Tag,
        [string]$WorkDir,
        [long]$SigBodyLength
    )
    $bound = startLocalListener
    $listener = $bound[0]
    $port = $bound[1]
    $tagsBody = [System.Text.Encoding]::UTF8.GetBytes($tagsJson)
    $archiveBody = [System.Text.Encoding]::UTF8.GetBytes("B136a pubkey-channel archive body")
    $sigBody = [System.Text.Encoding]::UTF8.GetBytes(("s" * $SigBodyLength))
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
    $psi.Environment["EPHOR_ARCHIVE_URL"] = "http://127.0.0.1:$port/archive.tar.gz"
    $psi.Environment["EPHOR_SIG_URL"] = "http://127.0.0.1:$port/sig.minisig"
    $psi.Environment["EPHOR_RELEASE_PUBKEY"] = $testPubkey
    $child = [System.Diagnostics.Process]::new()
    $child.StartInfo = $psi
    $child.Start() | Out-Null
    $script:servedTags = $false
    $script:servedArchive = $false
    $script:servedSig = $false
    # Serve one accepted request: route the body by path and mark the
    # served flag. Script scope holds the flags, so the serve loop and
    # the final drain share them.
    function servePubkeyRequest {
        param([System.Net.HttpListenerContext]$ctx)
        $path = $ctx.Request.Url.AbsolutePath
        $body = $null
        if ($path -eq "/tags.json") {
            $body = $tagsBody
            $script:servedTags = $true
        } elseif ($path -eq "/archive.tar.gz") {
            $body = $archiveBody
            $script:servedArchive = $true
        } elseif ($path -eq "/sig.minisig") {
            $body = $sigBody
            $script:servedSig = $true
        }
        try {
            if ($null -eq $body) {
                $ctx.Response.StatusCode = 404
                $ctx.Response.ContentLength64 = 0
            } else {
                $ctx.Response.StatusCode = 200
                $ctx.Response.ContentType = "application/octet-stream"
                $ctx.Response.ContentLength64 = $body.Length
                $ctx.Response.OutputStream.Write($body, 0, $body.Length)
            }
        } catch {
            # The over-cap child aborts the response mid-body when the
            # cap fires, so the write can throw on the closed
            # connection. The request was served. The close below is
            # best-effort.
        } finally {
            try { $ctx.Response.OutputStream.Close() } catch { }
        }
    }
    # Serve every request the child makes until it exits. One accept is
    # pending at a time: a wait that times out keeps waiting on the
    # same task. An abandoned task still holds the next connection, and
    # the loop never reads it again (EPH-I1237: the old 500 ms fixed
    # wait lost whole pubkey runs when a slow child stretched one
    # request past the window). The loop also carries the wall-clock
    # bound (EPH-I1241): a child that hangs after its last download
    # must reach the WaitForExit/Kill path below instead of spinning
    # forever.
    $ctxTask = $listener.GetContextAsync()
    $serveDeadline = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $child.HasExited -and $serveDeadline.ElapsedMilliseconds -lt $serveDeadlineMs) {
        if (-not $ctxTask.Wait(200)) { continue }
        servePubkeyRequest $ctxTask.Result
        $ctxTask = $listener.GetContextAsync()
    }
    # The child can exit while its final request is still in flight.
    # One bounded wait on the pending accept serves it, so the flags
    # report the real channel traffic.
    if ($ctxTask.Wait(300)) {
        servePubkeyRequest $ctxTask.Result
    }
    if (-not $child.WaitForExit($serveDeadlineMs)) {
        $child.Kill($true)
        throw "pubkey-channel install subprocess timed out"
    }
    $rc = $child.ExitCode
    [System.IO.File]::WriteAllText($outLog, $child.StandardOutput.ReadToEnd())
    [System.IO.File]::WriteAllText($errLog, $child.StandardError.ReadToEnd())
    try { $listener.Stop() } catch { }
    return @{
        rc = $rc
        out = [System.IO.File]::ReadAllText($outLog)
        err = [System.IO.File]::ReadAllText($errLog)
        servedTags = $script:servedTags
        servedArchive = $script:servedArchive
        servedSig = $script:servedSig
    }
}

$D2 = Join-Path $testRoot "t48b"
New-Item -ItemType Directory -Path $D2 | Out-Null
Set-Content -Path (Join-Path $D2 "build.zig") -Encoding UTF8 -Value @(
    'const std = @import("std");'
    'pub fn build(b: *std.Build) !void {'
    '    const exe = b.addExecutable(.{'
    '        .name = "demo",'
    '        .root_module = b.createModule(.{}),'
    '    });'
    '    b.installArtifact(exe);'
    '}'
)
$D3 = Join-Path $testRoot "t48c"
New-Item -ItemType Directory -Path $D3 | Out-Null
Set-Content -Path (Join-Path $D3 "build.zig") -Encoding UTF8 -Value @(
    'const std = @import("std");'
    'pub fn build(b: *std.Build) !void {'
    '    const exe = b.addExecutable(.{'
    '        .name = "demo",'
    '        .root_module = b.createModule(.{}),'
    '    });'
    '    b.installArtifact(exe);'
    '}'
)

# 282 is the measured minisig size (installer comment, verified
# 2026-08-27): the success run serves a realistic signature body.
$pubRun = runPubkeyInstall -Tag "pubkey" -WorkDir $D2 -SigBodyLength 282
# One byte over the 1 MiB signature cap ($SigCap = 1048576 in the
# installer): the download must fail closed.
$ovRun = runPubkeyInstall -Tag "overcap" -WorkDir $D3 -SigBodyLength 1048577

# The success pin: a green install downloads the tarball and the
# signature through the bounded HTTP arm, verifies, and exits 0 with an
# empty stderr (the active verification prints nothing to stderr).
check "pubkey run exits 0" { $pubRun.rc -eq 0 }
check "pubkey run reports verified signature" {
    $pubRun.out -match 'Release signature verified\.'
}
check "pubkey run serves all three fetches" {
    $pubRun.servedTags -and $pubRun.servedArchive -and $pubRun.servedSig
}
check "pubkey run stderr is empty" { $pubRun.err -eq "" }

# The emission pin: a signature one byte over the 1 MiB cap must fail
# the download closed. The emission defect turns the cap's return $false
# into @(response, $false), which the caller's -not reads as success, so
# the unfixed installer verifies a truncated signature and exits 0. The
# fixed installer names the failure and exits 1.
check "over-cap sig run exits 1" { $ovRun.rc -eq 1 }
check "over-cap sig run names the download failure" {
    $ovRun.err -match 'error: could not download the release signature\.'
}
check "over-cap sig run warns about the cap" {
    $ovRun.err -match 'warning: the download exceeds the 1048576 byte cap\.'
}
check "over-cap sig run serves all three fetches" {
    $ovRun.servedTags -and $ovRun.servedArchive -and $ovRun.servedSig
}

if (-not $keep) { Remove-Item -Recurse -Force $testRoot }

Write-Host ""
Write-Host "ps1 anchor: $script:checks checks, $script:failed failed"
if ($script:failed -ne 0) { exit 1 }
exit 0
