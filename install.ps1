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
    $EPHOR_FALLBACK_TAG = "v0.15.0"
    # Pin for Zig 0.15.x. Every remote tag (v0.12.3 and later) declares
    # minimum_zig_version 0.16.0. The 0.16 migration landed in v0.12.0, so
    # no remote tag builds on Zig 0.15.x. v0.11.13 declares
    # minimum_zig_version 0.15.0 and is the newest 0.15-era release. Its
    # tag is deleted on the remote, so pin the commit hash. Commit
    # archives stay available.
    $EPHOR_0_15_COMMIT = "60145fe05a2b91e7dd32d1c671d98239cd19aea6"

    # EPH-I0287 (WP-6.5): the minisign public key of the ephor release
    # signing keypair, the exact two-line .pub file the WP-7 key mint
    # produced. Both lines are wire shape, not prose: minisign 0.12
    # rejects a file whose key line is the first line, so the comment
    # line ships with the key. EPH-I0205: tests override it through
    # EPHOR_RELEASE_PUBKEY, gated by EPHOR_TEST_MODE like the other
    # trust-anchor overrides (install.sh parity).
    $ReleasePubkey = "untrusted comment: minisign public key BD29FC2E33D53EBE`n" +
        "RWS+PtUzLvwpvc7nVJ8t8MKTpo4/8UdOqoxuLGXhfJQI+qvTyn82Dfit"
    if ($testModeActive -and $env:EPHOR_RELEASE_PUBKEY) {
        $ReleasePubkey = $env:EPHOR_RELEASE_PUBKEY
    } elseif ($env:EPHOR_RELEASE_PUBKEY) {
        Write-Stderr "warning: EPHOR_RELEASE_PUBKEY is ignored without EPHOR_TEST_MODE=1."
    }
    # EPH-I0287: byte caps for the verification downloads (install.sh
    # parity). The tarball cap is 32 MiB: the largest published archive
    # measures 436,635 bytes (main, verified 2026-08-27), so the cap
    # holds 77x headroom and still bounds a hostile stream. The
    # signature cap matches the tags-API cap; a minisig file measures
    # 282 bytes (verified 2026-08-27).
    $TarballCap = 33554432
    $SigCap = 1048576
    # EPH-I1273: byte caps for the local build.zig and build.zig.zon
    # reads (Zig-side parity: build.zig 512 KiB, build.zig.zon 64 KiB).
    # Get-Content buffers the whole file, so an unbounded read OOMs the
    # install session on an oversized local file.
    $BuildZigReadCap = 524288
    $ZonReadCap = 65536

    # EPH-I1273: refuse to read $Path when it exceeds $MaxBytes. The
    # length check bounds the read before Get-Content buffers it. The
    # check-to-read window stays open to a concurrent writer, the same
    # accepted class the symlink refusal records (EPH-I1165); a hostile
    # oversized file present at install time is the class this closes.
    # A refusal prints a clear error and the caller aborts (fail-closed).
    function Assert-LocalFileWithinCap {
        param([string]$Path, [long]$MaxBytes)
        $item = Get-Item $Path -Force -ErrorAction SilentlyContinue
        if ($null -eq $item -or $item.Length -le $MaxBytes) {
            return $true
        }
        Write-Stderr @"
error: $Path is larger than $MaxBytes bytes.

  The installer reads local build files through a byte cap.
  Trim $Path, then re-run the install.
"@
        return $false
    }

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
        # EPH-I0207 (RED2-6): the response is byte-capped at 1 MiB. A
        # fast network-path attacker could stream gigabytes inside the
        # 30 s timeout window; the bounded read below stops at the cap,
        # warns, and fails the resolution, so the resolver takes the
        # pinned fallback. TimeoutSec bounds duration, not bytes.
        # The capped read uses HttpClient, which serves http and https
        # only. A non-http test-channel URL (file://) keeps the old
        # Invoke-RestMethod path: the operator picked that URL, the
        # bytes are local, and the strict-tag filter below still gates
        # the result.
        $maxTag = $null
        $maxVersion = $null
        $tagsJson = $null
        if ($TAGS_API.StartsWith("https://") -or $TAGS_API.StartsWith("http://")) {
            $handler = [System.Net.Http.HttpClientHandler]::new()
            if ($TAGS_API.StartsWith("https://")) { $handler.MaxAutomaticRedirections = 0 }
            $client = [System.Net.Http.HttpClient]::new($handler)
            $response = $null
            $stream = $null
            $buffer = $null
            try {
                $client.Timeout = [TimeSpan]::FromSeconds(30)
                $response = $client.GetAsync(
                    $TAGS_API,
                    [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
                ).GetAwaiter().GetResult()
                # EPH-I1219 pin run: on .NET 5+ EnsureSuccessStatusCode
                # returns the response message, and a bare method call
                # emits its return value, so the function output carried
                # the response beside the resolved tag and
                # Test-VersionOlder died converting it. Discard the
                # return explicitly, like the ast-check capture below.
                $null = $response.EnsureSuccessStatusCode()
                $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $bytes = New-Object byte[] 1048576
                $buffer = [System.IO.MemoryStream]::new()
                $total = 0
                while ($total -lt 1048576) {
                    $n = $stream.Read($bytes, 0, [Math]::Min($bytes.Length, 1048576 - $total))
                    if ($n -le 0) { break }
                    $buffer.Write($bytes, 0, $n)
                    $total += $n
                }
                if ($total -ge 1048576 -and $stream.ReadByte() -ne -1) {
                    Write-Stderr "warning: the tags API response exceeds the 1 MiB cap."
                    return $null
                }
                $text = [System.Text.Encoding]::UTF8.GetString($buffer.ToArray())
                $tagsJson = $text | ConvertFrom-Json
            } finally {
                if ($null -ne $buffer) { $buffer.Dispose() }
                if ($null -ne $stream) { $stream.Dispose() }
                if ($null -ne $response) { $response.Dispose() }
                $client.Dispose()
            }
        } else {
            $tagsJson = Invoke-RestMethod -Uri $TAGS_API -TimeoutSec 30
        }
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
        # EPH-I1274: sanitize the echoed name before it reaches the
        # terminal. The warning arm below fires exactly when the name
        # carries non-identifier bytes, which admits ESC and friends, so
        # the raw name must not reach any render. \p{Cc} covers C0, DEL,
        # and C1, the Zig-side sanitizeTerminal control class. The
        # multi-byte hostile format set stays an accepted residual, like
        # the sh installer's byte filter.
        $echoName = $projectName -replace '[\p{Cc}]', '?'
        if (-not ($projectName -match '^[a-z_][a-z0-9_]*$') -or
            ($projectName -match '^[0-9]')) {
            $sanitized = $projectName -replace '[^a-z0-9_]', '_'
            # Split-Path -Leaf is empty at a drive root, which sh's
            # basename can never produce: fall back to the fixed name.
            if (-not $sanitized) { $sanitized = "project" }
            if ($sanitized -match '^[0-9]') { $sanitized = "_$sanitized" }
            $nameExpr = ".$sanitized"
            Write-Stderr "warning: '$echoName' is not a valid Zig identifier for the zon name."
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
        Write-Host "Created build.zig.zon for project '$echoName'"
    }

    # EPH-I0284: refuse a symlink at build.zig.zon before the fetch. zig
    # fetch --save rewrites the zon through zig's own write path, which
    # follows a planted reparse point, so no installer-side no-follow
    # writer (EPH-I0280) can close it. Get-Item -Force returns the link
    # itself, where the reparse-point attribute is visible; Test-Path
    # follows the link and cannot see it. The fresh-zon write above
    # already replaced the name through Set-ContentNoFollow's rename, so
    # a link that survives to here existed before the install.
    # EPH-I1165: the check-to-fetch window stays open: a concurrent
    # writer could swap in a symlink after this check and before the
    # zig fetch below. The no-active-adversary-during-install
    # assumption scopes the window out, because a concurrent
    # same-privilege writer during the install is the invoking user,
    # and the clone-time-planting class is closed by this check.
    $zonItem = Get-Item "build.zig.zon" -Force -ErrorAction SilentlyContinue
    if ($zonItem -and
        ($zonItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        Write-Stderr "error: build.zig.zon is a symlink."
        Write-Stderr "Replace it with a regular file before installing ephor."
        return 1
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

    # Detect if this is an upgrade or a fresh install (install.sh
    # EPH-I0641/I1106 parity, EPH-I0285 port). Both probes anchor to
    # code lines, so a comment that mentions ephor cannot mislabel a
    # fresh install as an upgrade. The build.zig probe shares its
    # line-anchored idiom with the layout probe below. The zon probe
    # matches the .ephor = dependency line that zig fetch writes.
    # EPH-I1106 decision: a trailing inline comment on a code line
    # still reaches the anchored probe, because the .* spans into the
    # comment. Stripping trailing comments needs a Zig lexer, which
    # the installer does not carry. The residual is accepted: it is
    # label-only at this site, and the layout branch below shares the
    # idiom and the limit.
    $depProbe = '^\s*[^/.\s\\].*dependency\("ephor"'
    $zonDepProbe = '^\s*\.ephor\s*='
    # EPH-I1273: bound both probe reads before Get-Content buffers them.
    # The build.zig read feeds the probe and the block splice below, so
    # the same cap covers both consumers.
    if (-not (Assert-LocalFileWithinCap -Path "build.zig" -MaxBytes $BuildZigReadCap)) {
        return 1
    }
    $buildLines = Get-Content "build.zig" -Encoding UTF8
    $hasDepLine = $false
    foreach ($line in $buildLines) {
        if ($line -cmatch $depProbe) {
            $hasDepLine = $true
            break
        }
    }
    $hasZonDep = $false
    if (Test-Path "build.zig.zon") {
        if (-not (Assert-LocalFileWithinCap -Path "build.zig.zon" -MaxBytes $ZonReadCap)) {
            return 1
        }
        foreach ($line in (Get-Content "build.zig.zon" -Encoding UTF8)) {
            if ($line -cmatch $zonDepProbe) {
                $hasZonDep = $true
                break
            }
        }
    }
    if ($hasDepLine -or $hasZonDep) {
        $ACTION = "Upgrading"
    } else {
        $ACTION = "Installing"
    }

    if ($zigVersion) {
        Write-Host "$ACTION ephor $EPHOR_TAG (Zig $zigVersion)..."
    } else {
        Write-Host "$ACTION ephor $EPHOR_TAG..."
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

    # EPH-I0287 (WP-6.5): download $Url into $OutPath with a $MaxBytes
    # byte cap (EPH-I0207; install.sh fetch_bounded parity). The bounded
    # read mirrors the tags-API fetch: TimeoutSec bounds duration, the
    # cap bounds bytes, and an over-cap download warns and fails, so the
    # caller fails closed.
    # EPH-I1216 (qa-gate B112+M-1): the redirect and cap policy matches
    # install.sh fetch_bounded. An https origin follows redirects
    # clamped to https (install.sh --proto-redir =https): an
    # https-to-https hop is followed, and a hop that leaves https fails
    # the download closed. The hop loop runs because
    # MaxAutomaticRedirections clamps the count but not the scheme, and
    # the automatic downgrade protection differs across PowerShell
    # versions. The non-http arm (the operator-picked file:// test
    # channel) copies through the same bounded read as the network arm,
    # so the cap applies to every scheme (install.sh --max-filesize).
    function Get-BoundedFile {
        param([string]$Url, [string]$OutPath, [long]$MaxBytes)
        if ($Url.StartsWith("https://") -or $Url.StartsWith("http://")) {
            $handler = [System.Net.Http.HttpClientHandler]::new()
            $handler.AllowAutoRedirect = $false
            $client = [System.Net.Http.HttpClient]::new($handler)
            $response = $null
            $stream = $null
            $fileStream = $null
            try {
                $client.Timeout = [TimeSpan]::FromSeconds(30)
                $currentUrl = $Url
                $httpsOrigin = $Url.StartsWith("https://")
                # EPH-I1216: follow up to ten hops. Real CDN chains use
                # one to three hops; the bound only stops a
                # self-redirect loop. An https origin refuses every hop
                # whose target is not https (install.sh --proto-redir
                # =https). An exhausted hop budget or a hop without a
                # Location header fails the download closed.
                for ($hop = 0; $hop -le 10; $hop++) {
                    $response = $client.GetAsync(
                        $currentUrl,
                        [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
                    ).GetAwaiter().GetResult()
                    $statusCode = [int]$response.StatusCode
                    if ($statusCode -ge 300 -and $statusCode -lt 400) {
                        $location = $response.Headers.Location
                        $response.Dispose()
                        $response = $null
                        if ($null -eq $location) { return $false }
                        if (-not $location.IsAbsoluteUri) {
                            $location = [System.Uri]::new(
                                [System.Uri]$currentUrl, $location)
                        }
                        if ($httpsOrigin -and ($location.Scheme -ne "https")) {
                            Write-Stderr "warning: the download redirects away from https."
                            return $false
                        }
                        $currentUrl = $location.AbsoluteUri
                        continue
                    }
                    break
                }
                if ($null -eq $response) { return $false }
                # EPH-I1231: the same emission class as the tags fetch
                # (EPH-I1219): on .NET 5+ EnsureSuccessStatusCode
                # returns the message, and a bare call emits it into the
                # function output. The caller's -not test reads the
                # two-element output as success, so the byte cap's
                # fail-closed return read as a clean download. Discard
                # the return explicitly.
                $null = $response.EnsureSuccessStatusCode()
                $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $bytes = New-Object byte[] 8192
                $fileStream = [System.IO.File]::Create($OutPath)
                $total = [long]0
                while ($total -lt $MaxBytes) {
                    $remaining = [int][Math]::Min([long]$bytes.Length, $MaxBytes - $total)
                    $n = $stream.Read($bytes, 0, $remaining)
                    if ($n -le 0) { break }
                    $fileStream.Write($bytes, 0, $n)
                    $total += $n
                }
                if ($total -ge $MaxBytes -and $stream.ReadByte() -ne -1) {
                    Write-Stderr "warning: the download exceeds the $MaxBytes byte cap."
                    return $false
                }
                return $true
            } catch {
                return $false
            } finally {
                if ($null -ne $fileStream) { $fileStream.Dispose() }
                if ($null -ne $stream) { $stream.Dispose() }
                if ($null -ne $response) { $response.Dispose() }
                $client.Dispose()
            }
        }
        # EPH-I1216: the non-http arm (a file:// URL or a bare path)
        # applies the same byte cap as the network arm, so the
        # operator-picked test channel stays bounded (install.sh
        # --max-filesize on every scheme). A local copy reads
        # MaxBytes plus one probe byte at most, even when the file
        # grows during the copy.
        $source = $null
        $fileStream = $null
        try {
            $filePath = $Url
            if ($Url.StartsWith("file://")) {
                $filePath = [System.Uri]::new($Url).LocalPath
            }
            $source = [System.IO.File]::OpenRead($filePath)
            $fileStream = [System.IO.File]::Create($OutPath)
            $bytes = New-Object byte[] 8192
            $total = [long]0
            while ($total -lt $MaxBytes) {
                $remaining = [int][Math]::Min([long]$bytes.Length, $MaxBytes - $total)
                $n = $source.Read($bytes, 0, $remaining)
                if ($n -le 0) { break }
                $fileStream.Write($bytes, 0, $n)
                $total += $n
            }
            if ($total -ge $MaxBytes -and $source.ReadByte() -ne -1) {
                Write-Stderr "warning: the download exceeds the $MaxBytes byte cap."
                return $false
            }
            return $true
        } catch {
            return $false
        } finally {
            if ($null -ne $fileStream) { $fileStream.Dispose() }
            if ($null -ne $source) { $source.Dispose() }
        }
    }

    # EPH-I0287 (WP-6.5): download the release tarball and its minisign
    # signature, and verify the signature before zig fetch downloads
    # the artifact again (install.sh parity). Two states:
    # - Active (the shipped state): the release key is embedded, so
    #   every release must be signed. A missing minisign binary, a
    #   failed download, or a bad signature fails the install closed.
    # - Inactive (empty key): the pre-release fallback state. The check
    #   warns and the install continues on the recorded-hash model.
    function Test-EphorReleaseSignature {
        if (-not $ReleasePubkey) {
            Write-Stderr "warning: release signature verification is inactive."
            Write-Stderr "This installer embeds no release public key yet."
            Write-Stderr "The first signed release activates the check."
            return $true
        }
        if (-not (Get-Command minisign -CommandType Application -ErrorAction SilentlyContinue)) {
            Write-Stderr @"
error: minisign is not installed or not on PATH.

  This release is signed. Install minisign, then re-run the install.
"@
            return $false
        }
        # EPH-I0280: the verification files live in a fresh temp dir, so
        # nothing in the project dir is read or written here.
        $verifyName = "ephor-verify-" + [System.IO.Path]::GetRandomFileName()
        $verifyDir = Join-Path ([System.IO.Path]::GetTempPath()) $verifyName
        New-Item -ItemType Directory -Path $verifyDir | Out-Null
        $tarballPath = Join-Path $verifyDir "ephor.tar.gz"
        $sigPath = "$tarballPath.minisig"
        $pubkeyPath = Join-Path $verifyDir "ephor.pub"
        try {
            if (-not (Get-BoundedFile -Url $EPHOR_URL `
                -OutPath $tarballPath -MaxBytes $TarballCap)) {
                Write-Stderr "error: could not download the release tarball for verification."
                Write-Stderr "Check the network connection, then re-run the install."
                return $false
            }
            if (-not (Get-BoundedFile -Url $SIG_URL -OutPath $sigPath -MaxBytes $SigCap)) {
                Write-Stderr "error: could not download the release signature."
                Write-Stderr "Check the network connection, then re-run the install."
                return $false
            }
            # WP-7: write the key file byte-verbatim. Set-Content appends
            # the platform newline (CRLF on Windows), which would break
            # the two-line pubkey wire shape minisign parses, so the
            # bytes go through WriteAllText with an explicit LF tail.
            # Recorded limitation (EPH-I1287): no test discriminates this
            # write on the POSIX dev host (a POSIX pin is masked). The
            # discriminator design: a fake minisign records the written
            # pubkey bytes, and a Windows-run suite asserts zero CR bytes
            # plus exactly one trailing LF. The WP-7 live pwsh leg runs
            # that check manually and records it in the release evidence.
            [System.IO.File]::WriteAllText($pubkeyPath, $ReleasePubkey + [char]10)
            # EPH-I0645: capture the exit code under "Continue" like the
            # fetch steps, or PowerShell 7.4+ throws before this code
            # reads $LASTEXITCODE.
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            $verifyOut = (& minisign -Vm $tarballPath -p $pubkeyPath 2>&1 | Out-String)
            $verifyRc = $LASTEXITCODE
            $ErrorActionPreference = $prevEAP
            if ($null -eq $verifyRc) { $verifyRc = 1 }
            if ($verifyRc -ne 0) {
                Write-Stderr $verifyOut
                Write-Stderr "error: the release signature check failed."
                Write-Stderr "The downloaded artifact may be tampered with. The install stops."
                return $false
            }
        } catch {
            Write-Stderr "error: could not verify the release signature."
            return $false
        } finally {
            Remove-Item -Path $verifyDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host "Release signature verified."
        return $true
    }

    # EPH-I0287 (WP-6.5): verify the release signature before zig fetch.
    # EPH-I0205: tests override the signature URL through EPHOR_SIG_URL,
    # gated by EPHOR_TEST_MODE like the other trust-anchor overrides.
    # WP-7 era-pin carve (M-2): the check covers every TAG URL. The
    # pinned 0.15-era commit archive skips it. A tag is a mutable
    # pointer, and a moved tag is the M-2 threat, so a tag URL must
    # verify. The commit archive is SHA-addressed and immutable on the
    # remote: the commit cannot move, and https transport plus the
    # package fingerprint that zig fetch records in build.zig.zon
    # carry its integrity.
    $eraPinUrl = "$REPO/archive/$EPHOR_0_15_COMMIT.tar.gz"
    if ($EPHOR_URL -eq $eraPinUrl) {
        Write-Host "The installer skips signature verification for the pinned commit archive: it is immutable and SHA-addressed."
    } else {
        # WP-7: the signature lives in the repo tree at
        # signatures/<tag>.tar.gz.minisig, committed by the post-tag
        # commit for each release and served via the raw route.
        # Codeberg's archive route serves only real refs, so
        # "$EPHOR_URL.minisig" would 404 in production.
        $SIG_URL = "$REPO/raw/branch/main/signatures/$EPHOR_TAG.tar.gz.minisig"
        if ($testModeActive -and $env:EPHOR_SIG_URL) {
            $SIG_URL = $env:EPHOR_SIG_URL
        } elseif ($env:EPHOR_SIG_URL) {
            Write-Stderr "warning: EPHOR_SIG_URL is ignored without EPHOR_TEST_MODE=1."
        }
        if (-not (Test-EphorReleaseSignature)) {
            return 1
        }
    }

    # EPH-I1272: repair the fingerprint only at a code position
    # (install.sh EPH-I1272 parity; the Zig-side indexOfCode model). The
    # pre-fix -creplace rewrote every occurrence, so a string value that
    # mentions ".fingerprint = 0x0" got corrupted. The walk mirrors
    # Find-LastInstallArtifactLine: string and char literals mask their
    # content, a // comment ends the line's code, a \\-led multiline
    # body line is string data, and a mid-line \\ opener consumes the
    # rest of the line as string data (EPH-I1283, the Zig-side EPH-I0671
    # semantics). The first code-position marker wins the repair. A
    # code-position fingerprint with any other value fails closed (the
    # caller prints the clear error); a zon with no code-position
    # fingerprint field gains one right after the root struct opener,
    # the shape zig 0.16.0 answers with "missing top-level 'fingerprint'
    # field; suggested value: 0x<hex>" (EPH-I1291). Returns the patched
    # zon, or $null when a nonzero field sits in code or no root opener
    # exists. The match regex keeps the EPH-I0648 flexibility: any
    # spacing around the placeholder, and \b stops a real fingerprint
    # that starts with 0x0 from matching as the placeholder prefix.
    function Repair-ZonFingerprint {
        param([string]$Zon, [string]$Hint)
        $repaired = $false
        $hasFingerprintField = $false
        $rootOpenLine = -1
        $rootOpenCol = -1
        $rootOpenIndent = ""
        $lines = $Zon -split "`n"
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            $pos = 0
            while ($pos -lt $line.Length -and $line[$pos] -eq ' ') { $pos++ }
            while ($pos -lt $line.Length -and $line[$pos] -eq "`t") { $pos++ }
            $lineIndent = $line.Substring(0, $pos)
            if ($pos -lt $line.Length -and $line[$pos] -eq '\') { continue }
            $inString = $false
            $inChar = $false
            while ($pos -lt $line.Length) {
                $c = $line[$pos]
                if ($inString) {
                    if ($c -eq '\') { $pos++ } elseif ($c -eq '"') { $inString = $false }
                    $pos++
                    continue
                }
                if ($inChar) {
                    if ($c -eq '\') { $pos++ } elseif ($c -eq "'") { $inChar = $false }
                    $pos++
                    continue
                }
                if ($c -eq '"') { $inString = $true; $pos++; continue }
                if ($c -eq "'") { $inChar = $true; $pos++; continue }
                if ($c -eq '/' -and ($pos + 1) -lt $line.Length -and
                    $line[$pos + 1] -eq '/') { break }
                if ($c -eq '\' -and ($pos + 1) -lt $line.Length -and
                    $line[$pos + 1] -eq '\') { break }
                if ($c -eq '{' -and $rootOpenLine -lt 0) {
                    $rootOpenLine = $i
                    $rootOpenCol = $pos
                    $rootOpenIndent = $lineIndent
                }
                if ($c -eq '.') {
                    $tail = $line.Substring($pos)
                    if ($tail -cmatch '^\.fingerprint[ \t]*=[ \t]*0x0\b') {
                        $matchLen = $Matches[0].Length
                        $lines[$i] = $line.Substring(0, $pos) +
                            ".fingerprint = $Hint" +
                            $line.Substring($pos + $matchLen)
                        $repaired = $true
                        break
                    }
                    if ($tail -cmatch '^\.fingerprint\b') {
                        $hasFingerprintField = $true
                    }
                }
                $pos++
            }
            if ($repaired) { break }
        }
        if (-not $repaired) {
            if ($hasFingerprintField -or $rootOpenLine -lt 0) { return $null }
            $openLine = $lines[$rootOpenLine]
            $restOfLine = $openLine.Substring($rootOpenCol + 1)
            $newLines = New-Object System.Collections.Generic.List[string]
            if ($restOfLine.Trim().Length -eq 0) {
                # The opener owns its line: insert an indented field line
                # after it.
                for ($j = 0; $j -le $rootOpenLine; $j++) { $newLines.Add($lines[$j]) }
                $newLines.Add($rootOpenIndent + "    " + ".fingerprint = $Hint" + ",")
                for ($j = $rootOpenLine + 1; $j -lt $lines.Count; $j++) {
                    $newLines.Add($lines[$j])
                }
            } else {
                # A one-line zon: insert the field inline after the opener.
                $newLines.Add(($openLine.Substring(0, $rootOpenCol + 1) +
                    " .fingerprint = $Hint" + ", " +
                    $openLine.Substring($rootOpenCol + 1)))
                for ($j = $rootOpenLine + 1; $j -lt $lines.Count; $j++) {
                    $newLines.Add($lines[$j])
                }
            }
            $lines = $newLines.ToArray()
        }
        return [string]::Join("`n", $lines)
    }

    Write-Host "Adding ephor dependency..."
    # EPH-I0192: zig fetch reads build.zig.zon but never runs build.zig,
    # so a hostile build.zig still executes no code here. On a fresh zon
    # with fingerprint 0x0, zig fetch fails and prints a "use this value"
    # hint with the computed fingerprint. A zon without the field draws
    # the sibling "suggested value" hint (EPH-I1291). Patch the hint in
    # and fetch again.
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
        # EPH-I1291: zig 0.16.0 emits two hint shapes — "use this value"
        # for the 0x0 placeholder and "suggested value" for the missing
        # field — so the pattern accepts both. $Matches[2] is the hex
        # value; $Matches[1] is the prefix alternation.
        if ($fetchOut -match '(use this value|suggested value): (0x[0-9a-f]+)') {
            $suggested = $Matches[2]
            # EPH-I1273: bound the repair read like the probe reads. The
            # probe's zon cap fired earlier for a zon that was already
            # oversized, so this check covers the window a concurrent
            # writer opens between the probe and the repair.
            if (-not (Assert-LocalFileWithinCap -Path "build.zig.zon" -MaxBytes $ZonReadCap)) {
                return 1
            }
            $zon = Get-Content "build.zig.zon" -Raw -Encoding UTF8
            # EPH-I0648: verify the patch changed the content. A zon
            # whose layout does not match stops with a clear message
            # instead of failing the next fetch the same way.
            $patched = Repair-ZonFingerprint -Zon $zon -Hint $suggested
            if ($null -eq $patched) {
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

    # Canonical ephor block for build.zig (install.sh parity, EPH-I0285
    # port). The leading blank line of the here-string is the separator
    # the block lands with. The TrimEnd call drops the trailing newline
    # the here-string captures, so Set-Content writes exactly one line
    # terminator after the block. install.sh parity: sh's EPHOR_BLOCK
    # carries no trailing newline, and echo adds one.
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
    $EPHOR_BLOCK = $EPHOR_BLOCK.TrimEnd("`r", "`n")

    # Warn about a malformed ephor block and leave build.zig untouched.
    # EPH-I0290 arm (a): the missing-marker case warns with manual
    # instructions like the non-standard-layout branch, and the install
    # exits 0. install.sh refuses that shape with exit 1; the warn
    # shape is the ps1 behavior the issue sanctions.
    function Warn-BlockLayout {
        param([string]$Reason)
        Write-Stderr "warning: $Reason"
        Write-Stderr "Please update your ephor build steps manually (see README)."
    }

    # Refuse a splice and fail the install. The installer never guesses
    # when the markers do not describe one unambiguous block
    # (install.sh EPH-I0625/26/28 parity, EPH-I0285 port).
    function Refuse-BlockSplice {
        param([string]$Reason)
        Write-Stderr "warning: $Reason"
        Write-Stderr "The ephor build steps in build.zig were not updated."
        Write-Stderr "Update them manually (see the ephor README)."
    }

    # Find the index of the last code-position installArtifact mention
    # in $Lines, or -1 when none exists (EPH-I1202; install.sh
    # find_install_artifact_line parity, the EPH-I0715 awk-walk port).
    # The walk tracks string and char literals and stops at // comments
    # and \\ multiline tails, so a mention inside a string or a comment
    # cannot win the insertion anchor. A trailing inline comment after
    # the real call still anchors that call correctly: the walk breaks
    # at // after it has seen the code-position mention. The first
    # non-space char gate keeps the EPH-I0626 code-line idiom: a line
    # that opens with // or \\, or a .-led field line, is data, not a
    # call. The masked-semicolon limit lives in the terminator scan
    # below, not here (EPH-I1106 shares it with the action probe).
    function Find-LastInstallArtifactLine {
        param([string[]]$Lines)
        $lastIndex = -1
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            $line = $Lines[$i]
            if (-not $line.Contains("installArtifact")) { continue }
            $pos = 0
            while ($pos -lt $line.Length -and $line[$pos] -eq ' ') { $pos++ }
            while ($pos -lt $line.Length -and $line[$pos] -eq "`t") { $pos++ }
            if ($pos -ge $line.Length) { continue }
            $firstChar = $line[$pos]
            if ($firstChar -eq '/' -or $firstChar -eq '\' -or $firstChar -eq '.') {
                continue
            }
            $inString = $false
            $inChar = $false
            while ($pos -lt $line.Length) {
                $c = $line[$pos]
                if ($inString) {
                    if ($c -eq '\') { $pos++ } elseif ($c -eq '"') { $inString = $false }
                    $pos++
                    continue
                }
                if ($inChar) {
                    if ($c -eq '\') { $pos++ } elseif ($c -eq "'") { $inChar = $false }
                    $pos++
                    continue
                }
                if ($c -eq '"') { $inString = $true; $pos++; continue }
                if ($c -eq "'") { $inChar = $true; $pos++; continue }
                if ($c -eq '/' -and ($pos + 1) -lt $line.Length -and
                    $line[$pos + 1] -eq '/') { break }
                if ($c -eq '\' -and ($pos + 1) -lt $line.Length -and
                    $line[$pos + 1] -eq '\') { break }
                # -ceq keeps the awk == case semantics (EPH-I1202 review
                # r1): -eq is case-insensitive in PowerShell, and a
                # case-variant identifier in code position is not the
                # real call.
                if (($pos + 15) -le $line.Length -and
                    $line.Substring($pos, 15) -ceq 'installArtifact') {
                    $lastIndex = $i
                    $pos += 15
                    continue
                }
                $pos++
            }
        }
        return $lastIndex
    }

    # The anchored marker patterns (install.sh parity, EPH-I0285 port).
    # Each start marker requires the canonical four-space indent, and
    # each end marker must sit at line start in code context: a line
    # that begins with // cannot match. -cmatch keeps grep's
    # case-sensitive anchoring.
    $canonStart = '^\s*    // Ephor static analysis'
    $canonEnd = '^\s*ephor_upgrade_step\.dependOn\(&ephor_upgrade_cmd\.step\);'
    $legacyStart = '^\s*    // === Ephor Static Analysis ==='
    $legacyEnd = '^\s*ephor_step\.dependOn\(&b\.addRunArtifact\(ephor_exe\)\.step\);'

    # Find the first marker line of each kind and count every match, so
    # the splice below replaces exactly one unambiguous span
    # (install.sh EPH-I0625/26/28 parity). $buildLines comes from the
    # upgrade/install probe above.
    $startLine = -1
    $endLine = -1
    $startCount = 0
    $endCount = 0
    $legacyStartLine = -1
    $legacyEndLine = -1
    $legacyStartCount = 0
    $legacyEndCount = 0
    for ($i = 0; $i -lt $buildLines.Count; $i++) {
        if ($buildLines[$i] -cmatch $canonStart) {
            if ($startLine -eq -1) { $startLine = $i }
            $startCount += 1
        }
        if ($buildLines[$i] -cmatch $canonEnd) {
            if ($endLine -eq -1) { $endLine = $i }
            $endCount += 1
        }
        if ($buildLines[$i] -cmatch $legacyStart) {
            if ($legacyStartLine -eq -1) { $legacyStartLine = $i }
            $legacyStartCount += 1
        }
        if ($buildLines[$i] -cmatch $legacyEnd) {
            if ($legacyEndLine -eq -1) { $legacyEndLine = $i }
            $legacyEndCount += 1
        }
    }

    if ($startCount -gt 0 -or $endCount -gt 0) {
        # The canonical block exists - replace it with the canonical
        # version (EPH-I0290: a missing end marker warns instead of
        # doing nothing; install.sh EPH-I0625 parity for the rest).
        if ($startLine -eq -1 -or $endLine -eq -1) {
            Warn-BlockLayout "the ephor block in build.zig is missing one of its markers."
            return 0
        }
        if ($startCount -gt 1 -or $endCount -gt 1) {
            Refuse-BlockSplice "build.zig has more than one ephor block marker."
            return 1
        }
        if ($endLine -le $startLine) {
            Refuse-BlockSplice "the ephor block markers in build.zig are out of order."
            return 1
        }
        $spanHasDep = $false
        for ($i = $startLine; $i -lt $endLine; $i++) {
            if ($buildLines[$i] -cmatch 'dependency\("ephor"') {
                $spanHasDep = $true
                break
            }
        }
        if (-not $spanHasDep) {
            Refuse-BlockSplice "the ephor block in build.zig has no dependency line."
            return 1
        }
        # Absorb every consecutive blank line above the block (EPH-I0060,
        # install.sh parity): the block's leading newline re-creates
        # exactly one, so the loop converges any run of N>=1 blanks to
        # the canonical single blank on the next re-run.
        while ($startLine -gt 0 -and $buildLines[$startLine - 1] -eq '') {
            $startLine -= 1
        }
        $newLines = @()
        if ($startLine -gt 0) {
            # EPH-I0285 port: the line-0 edge guard. Without it,
            # $lines[0..-1] evaluates as (0, -1) and duplicates the
            # first and last lines (EPH-I0251 evidence).
            $newLines += $buildLines[0..($startLine - 1)]
        }
        $newLines += $EPHOR_BLOCK
        if ($endLine + 1 -lt $buildLines.Count) {
            $newLines += $buildLines[($endLine + 1)..($buildLines.Count - 1)]
        }
        Set-ContentNoFollow -Path "build.zig" -Value $newLines
        Write-Host "Updated ephor build steps in build.zig"
    } elseif ($legacyStartCount -gt 0 -or $legacyEndCount -gt 0) {
        # The old v0.11.x snippet migrates to the canonical block
        # (install.sh parity, EPH-I0285 port). The markers validate the
        # same way as the canonical branch.
        if ($legacyStartLine -eq -1 -or $legacyEndLine -eq -1) {
            Refuse-BlockSplice "the ephor block in build.zig is missing one of its markers."
            return 1
        }
        if ($legacyStartCount -gt 1 -or $legacyEndCount -gt 1) {
            Refuse-BlockSplice "build.zig has more than one ephor block marker."
            return 1
        }
        if ($legacyEndLine -le $legacyStartLine) {
            Refuse-BlockSplice "the ephor block markers in build.zig are out of order."
            return 1
        }
        $spanHasDep = $false
        for ($i = $legacyStartLine; $i -lt $legacyEndLine; $i++) {
            if ($buildLines[$i] -cmatch 'dependency\("ephor"') {
                $spanHasDep = $true
                break
            }
        }
        if (-not $spanHasDep) {
            Refuse-BlockSplice "the ephor block in build.zig has no dependency line."
            return 1
        }
        # Absorb every consecutive blank line above the block (EPH-I0060,
        # same convergence as the canonical branch: the v0.11.x snippet
        # was also inserted with a leading blank line).
        while ($legacyStartLine -gt 0 -and $buildLines[$legacyStartLine - 1] -eq '') {
            $legacyStartLine -= 1
        }
        $newLines = @()
        if ($legacyStartLine -gt 0) {
            $newLines += $buildLines[0..($legacyStartLine - 1)]
        }
        $newLines += $EPHOR_BLOCK
        if ($legacyEndLine + 1 -lt $buildLines.Count) {
            $newLines += $buildLines[($legacyEndLine + 1)..($buildLines.Count - 1)]
        }
        Set-ContentNoFollow -Path "build.zig" -Value $newLines
        Write-Host "Updated ephor build steps in build.zig (migrated from v0.11.x snippet)"
    } elseif ($hasDepLine) {
        # EPH-I1144: the probe anchors to code lines exactly like the
        # action probe above, so a comment that mentions the dependency
        # no longer misroutes a fresh install into this branch. The
        # trailing-inline-comment limit is shared and recorded at the
        # action probe.
        # Has a dependency but a non-standard block layout - leave it
        # and warn the user (EPH-I1110: the warning pair prints to
        # stderr).
        Warn-BlockLayout "ephor dependency found but build steps have non-standard layout"
    } else {
        # Fresh install - add the block after the last installArtifact
        # statement (EPH-I1158; install.sh EPH-I0626 parity).
        # EPH-I1202 (install.sh EPH-I0715 parity): the anchor scan is
        # quote- and comment-aware (Find-LastInstallArtifactLine), so a
        # mention inside a string or a comment cannot win the anchor.
        # The composed file must also pass zig ast-check before it
        # replaces the live one - the same gate install.sh runs - so an
        # anchor shape that still corrupts the file fails the install
        # instead of writing a broken build.zig. The insert extends
        # forward to the first line that ends with the statement
        # terminator (a semicolon plus whitespace), so a multi-line
        # b.installArtifact(exe, .{ ... }); statement is not split
        # mid-statement. A statement that never reaches a terminator
        # refuses with a manual-edit message instead of writing a
        # broken build.zig. A trailing line comment after the
        # terminator masks the semicolon match
        # (b.installArtifact(exe); // note): the block then lands after
        # the next terminator line, which is still valid Zig, or the
        # install refuses when no terminator line follows.
        Write-Host "Adding ephor build steps to build.zig..."

        $lastInstallLine = Find-LastInstallArtifactLine $buildLines

        if ($lastInstallLine -eq -1) {
            # EPH-I0635 parity: the dependency landed but the build steps
            # did not. Exit nonzero so automation does not mistake a
            # partial install for success.
            Write-Stderr "warning: could not find installArtifact in build.zig"
            Write-Stderr "The ephor dependency was added, but the build steps were not."
            Write-Stderr "Add the build steps manually (see README)."
            return 1
        }

        $terminatorLine = -1
        for ($i = $lastInstallLine; $i -lt $buildLines.Count; $i++) {
            if ($buildLines[$i] -cmatch ';[\s]*$') {
                $terminatorLine = $i
                break
            }
        }
        if ($terminatorLine -eq -1) {
            # EPH-I0626 parity: the statement never reaches a semicolon,
            # so refuse instead of guessing a cut point and writing a
            # broken build.zig.
            Write-Stderr "warning: the installArtifact statement does not end before the end of build.zig."
            Write-Stderr "The ephor build steps were not added."
            Write-Stderr "Add them manually (see README)."
            return 1
        }

        $newLines = @()
        $newLines += $buildLines[0..$terminatorLine]
        $newLines += $EPHOR_BLOCK
        if ($terminatorLine + 1 -lt $buildLines.Count) {
            $newLines += $buildLines[($terminatorLine + 1)..($buildLines.Count - 1)]
        }
        # EPH-I1202 (install.sh EPH-I0715 second arm parity): the
        # composed file must pass zig ast-check before it replaces the
        # live one. ast-check resolves names too, so the gate also
        # proves the block's target name stays in scope (EPH-I0512).
        # The gate needs the composed content on disk, so the temp
        # write and the rename run here instead of inside
        # Set-ContentNoFollow. The rename keeps the EPH-I0280
        # no-follow property: it replaces a planted symlink itself and
        # never touches its target. On failure the finally block
        # removes the temp file and the original stays untouched.
        $tempBuildPath = "build.zig.$([System.IO.Path]::GetRandomFileName())"
        try {
            Set-Content -Path $tempBuildPath -Value $newLines -Encoding UTF8
            # EPH-I0645: capture the exit code under "Continue" like the
            # fetch steps. Under "Stop", PowerShell 7.4+ throws before
            # this code reads $LASTEXITCODE.
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            $null = (zig ast-check $tempBuildPath 2>&1 | Out-String)
            $astCheckRc = $LASTEXITCODE
            $ErrorActionPreference = $prevEAP
            if ($null -eq $astCheckRc) { $astCheckRc = 1 }
            if ($astCheckRc -ne 0) {
                Write-Stderr "warning: the composed build.zig failed zig ast-check."
                Write-Stderr "The ephor build steps were not added."
                Write-Stderr "Add them manually (see README)."
                return 1
            }
            Move-Item -Force -Path $tempBuildPath -Destination "build.zig"
        } finally {
            if (Test-Path $tempBuildPath) { Remove-Item $tempBuildPath -Force }
        }
    }

    Write-Host ""
    Write-Host "Done! Run static analysis with:"
    Write-Host "  zig build ephor              (run all checks)"
    Write-Host "  zig build ephor -- init      (create ephor.json config)"
    Write-Host "  zig build ephor-upgrade      (upgrade to latest version)"

    return 0
}

# Report the install code only when this file runs as a script. The
# $MyInvocation.PSCommandPath property is populated only when the caller
# is a script (about_Automatic_Variables), so under irm | iex it stays
# empty and the user's shell stays open. The code is the script block's
# only output.
# EPH-I1231 (B136a pin): on pwsh 7.6.5 $MyInvocation.PSCommandPath is
# empty even in a -File run, so the guard never fired and a failing
# install always exited 0 for script callers. $PSCommandPath is
# populated in -File runs and empty under iex (probed 2026-08-28), so
# the pair covers both channels without opening the iex exit hazard.
if ($MyInvocation.PSCommandPath -or $PSCommandPath) { exit $installExitCode }
