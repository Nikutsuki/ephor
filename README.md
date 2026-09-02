# Ephor

**The overseer of your Zig code** - Static + Dynamic analysis tool for Zig projects that fills gaps in `zig fmt`, `zig build`, and `zig build test`.

## What It Does

| Analyzer | What It Finds |
|----------|---------------|
| **check** | Run all static checks |
| **runtime** | Dynamic analysis via test execution (memory leaks, panics) |
| **orphans** | Files not imported from entry points |
| **memory** | Allocation without `defer free/destroy`, missing `errdefer`, use-after-free, double-free |
| **errors** | Silent `catch {}`, `catch unreachable`, `orelse unreachable`, `catch undefined`, `exit()` bypassing defers, `@panic()`, discarded errors |
| **unused** | Unused imports, params, and declarations |
| **complexity** | Long functions, deep nesting, too many params/branches |
| **style** (check-only) | Lines too long, files too large, naming conventions |
| **fmt-check** | Files that need `zig fmt` |

`style` is not a command: the ZA7xx style rules run under `check` only.
A bare word that names no command is a scan path, so `ephor style` scans
a directory named `style`.

## Installation

**Requires**: A Zig project with `build.zig` and `build.zig.zon` (run `zig init` if you do not have these).

**macOS / Linux:**
```bash
cd /path/to/your-project
curl -fsSL https://codeberg.org/RhyosLabs/ephor/raw/branch/main/install.sh | sh
```

**Windows (PowerShell):**
```powershell
cd C:\path\to\your-project
irm https://codeberg.org/RhyosLabs/ephor/raw/branch/main/install.ps1 | iex
```

Then run:

```bash
zig build ephor
```

That is it.

### Upgrading

One command — same as install:

```bash
curl -fsSL https://codeberg.org/RhyosLabs/ephor/raw/branch/main/install.sh | sh
```

The script detects if ephor is already present and upgrades it in place:
- Updates the dependency in `build.zig.zon`
- Replaces the `build.zig` integration block (handles both old v0.11.x and current formats)

The script does not touch `ephor.json`. Run `ephor init` (or
`zig build ephor -- init`) to create the config. The `ephor install`
command writes one when it detects your project (see Version Management).

If you already have the `ephor-upgrade` step in `build.zig`:

```bash
zig build ephor-upgrade
```

On Zig 0.15.x, the install and upgrade commands — standalone and via
`zig build ephor-upgrade` — refuse with a named error. No ephor release
newer than v0.11.13 builds with this Zig. Use install.sh instead. It
detects the Zig version and installs v0.11.13 for 0.15.x projects.

### Upgrade Integrity

The first install or upgrade fetches whatever the release tag points to.
zig fetch records the content hash of that download in `build.zig.zon`. This
model is trust on first use (TOFU). The download channel is the only check
on the first fetch.

Both installers cap the tags-API response at 1 MiB (EPH-I0207). The 30 s
timeout bounds duration only. A fast network-path attacker can stream
gigabytes inside that window. The 1 MiB cap stops the stream. An over-cap
response fails the resolution, and the installer uses the pinned fallback
tag.

**Release signatures (minisign).** The installers and the `ephor
install` and `ephor upgrade` commands verify the release signature
before zig fetch. They download the tarball and its signature, and check
the pair with minisign against the release public key embedded in the
installer or the ephor binary (EPH-I0287). The tarball download is
capped at 32 MiB and the signature download at 1 MiB. Each fetch times
out after 30 s. On a signed release, the install or upgrade fails closed
when the signature download fails, when minisign is not installed, or
when the check fails. Each release's signature lives in the repository
tree at `signatures/<tag>.tar.gz.minisig`. The post-tag commit publishes
it, and the raw route (`/raw/branch/main/...`) serves it.

Signature verification is active. The installer and the binary embed the
release public key, and every release must be signed with the release
keypair. Signed releases need the minisign binary on PATH. The installer
test suites exercise the check through `EPHOR_RELEASE_PUBKEY`, which
replaces the embedded key when `EPHOR_TEST_MODE=1` is set.

The installers and the binary keep zig fetch on the canonical `https`
archive URL. They never hand a local file to zig fetch (EPH-I1215): zig
0.16.0 crashes on `file://` URLs (upstream SIGBUS). The bounded
downloader writes the tarball and the signature to the temp dir: curl on
install.sh and the binary, the .NET client in install.ps1. Minisign
reads them there, and zig fetch never touches a local file.

One window remains. zig fetch downloads the artifact again after the
installer or the upgrade command verifies it. A network attacker who
swaps bytes between the two downloads defeats the check. The recorded
hash in `build.zig.zon` limits this window: every later fetch verifies
the artifact against the recorded hash, and ephor prints the hash after
every fetch. Compare it across upgrades to catch a changed artifact.

- Upgrades refuse to move below the running binary's version. Pass
  `--force` to override.

### Update Check

Analysis commands (everything except `help`, `version`, `init`, `install`,
`upgrade`) perform a best-effort check for a newer ephor release and print a
notification after the analysis output. The check never blocks analysis on
failure:

- The latest version is cached for 24h at `~/.ephor_update_check`. A fresh
  cache skips the network fetch entirely; a stale, missing, or corrupt cache
  is refetched and rewritten after a successful fetch, and left untouched
  when the fetch fails.
- Set `EPHOR_NO_UPDATE_CHECK` (any value, including empty) to skip the check
  entirely — no fetch, no cache read, no warning. Recommended for
  deterministic CI.
- Without `HOME`, the cache is skipped and every run fetches live.

### Version Management

Ephor pins the installed version in `ephor.json` so your team always runs the same version. The pinned version is stored under the `"version"` key. When you run `ephor install`, it auto-detects your source directory, entry points from `build.zig`, and writes a config file.

### Manual Installation

<details>
<summary>Click to expand manual steps</summary>

Add the dependency. Substitute the newest tag from the
[tags page](https://codeberg.org/RhyosLabs/ephor/tags) for `v0.14.2`:

```bash
zig fetch --save=ephor https://codeberg.org/RhyosLabs/ephor/archive/v0.15.2.tar.gz
```

Then add to `build.zig`:

```zig
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
```

</details>

## Usage

### Via Build System (Recommended)

Most users interact with ephor through their project's build system:

```bash
zig build ephor              # Run all static checks
zig build ephor -- init      # Create ephor.json config file
zig build ephor -- stats     # Show project statistics
zig build ephor-upgrade      # Upgrade to latest version
```

Arguments after `--` are forwarded to ephor, so any CLI command works through the build system. No standalone binary needed — the install script adds these build steps automatically.

### Standalone CLI

If you have the `ephor` binary installed directly, it accepts commands and options:

```bash
ephor                     # Defaults to 'check' on configured src directory
ephor check src/          # Explicit path
ephor memory              # Alloc without defer patterns
ephor errors              # Error handling patterns (ZA201-ZA210)
ephor orphans             # Files not imported
ephor complexity          # Function complexity
ephor fmt-check           # Files needing zig fmt
ephor runtime             # Dynamic analysis (runs tests with memory diagnostics)
ephor stats               # Project statistics
ephor init                # Create ephor.json config file
```

## Output Format

Industry-standard format compatible with GCC, clang, ESLint, IntelliJ IDEA, and VS Code:

```
src/main.zig:506:25: warning[ZA201]: silent catch {} discards error without handling
  help: use 'catch |err| { log.err(...); return err; }' or propagate with 'try'
```

### JSON Output

```bash
ephor check --format=json
```

`-f=json` is an alias of `--format=json`. `-f=text` (or `--format=text`)
switches back to the human format.

`--format=json` writes one stream of top-level JSON objects to stderr: one
object per analyzer (orphans, memory, errors, null-safety, panic, unused,
complexity, format, naming, style, tests, concurrency), then the summary
object when `--summary` is set. The suppression counts ride the summary's
`"suppressed"` member with `--summary`. Without it they print as a trailing
top-level object. The stream serves machine consumers, so JSON mode
suppresses every human diagnostic: the footer, the strict-failure notice,
the suppression-accounting note, the AST-skip note, the update-check
notification and fetch warning, the export confirmation, and the runtime
band's "Running:" line. The AST-skipped count rides the summary's
`ast_skipped` member. The export file itself confirms the export. See
[Suppression Accounting](#suppression-accounting) for the `"suppressed"`
object shape.

The summary `issues` member gained `"notes"`. Each per-category bucket
counts warnings, and error-severity findings ride inside the warning
count. `"total"` counts every printed finding: warnings, errors, and
notes. `"status"` reflects that total, so a notes-only run never reports
`"ok"`.

The two error-family lists (error-handling findings and discarded error
unions) merge into one `"errors"` analyzer object. Each analyzer name
appears at most once in the stream.

The strict gate prints no human notice in JSON mode. The exit code
carries the gate. A failed run closes the stream with one machine error
object and exits 1. The `message` member carries the last human
diagnostic the machine latch muted during the run. It is empty when the run
muted nothing. A strict run whose scan printed the entry-widen note
closed with:

```
{
  "error": "RunFailed",
  "message": "note: scan includes 1 entry point outside scandir/bad.zig (entry points always join the scan)\n"
}
```

A run that aborts before analysis closes with the same object. A
no-entries run carries the stashed hint (`"  run: ephor init\n"`). On a
usage error the diagnostic rides the `message` member. For example, an
unknown flag emits:

```
{
  "error": "UnknownFlag",
  "message": "error: unknown flag '--bogusflag' (see ephor --help)\n"
}
```

A mid-run handler failure (for example an unreadable explicit
`--known-issues` file) carries an empty message: the dispatch does not
attach a mid-run diagnostic to the abort.

Boundaries: `--verbose` is a no-op in JSON mode. The machine latch arms
before the config load and the tool-path resolution, so diagnostics from
either stay off the stream. The `init`, `install`, and `upgrade` commands
reject `--format=json` with a hard error and one machine error object,
because their human progress text has no machine equivalent. The `help`
and `version` commands are not analysis commands and print their human
text regardless of `--format=json`.

## Configuration

Create `ephor.json` in your project root:

```bash
zig build ephor -- init   # Via build system
ephor init                # Standalone CLI
```

Example config. The `init` and `install` writers emit this shape:
`version`, `path_dir`, `entries`, `exclude`, `orphan_exclude`,
`enable` (`ZA305`, `ZA306`), and `fail_on` (EPH-I1146). The example
below adds `strict`, `error_naming`, and `thresholds` as schema
reference only: each stays an optional manual override, and the
built-in threshold defaults apply when the thresholds block is absent.

```json
{
  "version": "0.15.3",
  "path_dir": "src",
  "entries": ["src/main.zig", "build.zig"],
  "exclude": ["test", "vendor", "third_party"],
  "orphan_exclude": ["_test.zig", "/test/", "/tests/"],
  "enable": ["ZA305", "ZA306"],
  "strict": true,
  "fail_on": "warning",
  "error_naming": "TitleCase",
  "thresholds": {
    "max_lines": 50,
    "max_nesting": 3,
    "max_params": 4,
    "max_branches": 12,
    "max_line_length": 100,
    "max_cyclomatic": 10,
    "max_cognitive": 15,
    "max_file_bytes": 50000
  }
}
```

### Config Options

| Option | Description |
|--------|-------------|
| `version` | Pinned ephor version (set by `install`/`upgrade`) |
| `path_dir` | Directory to analyze (also accepts `code`, `src`, or `root` as aliases). Must resolve inside the config's own directory |
| `entries` | Entry points for orphan detection. An entry outside the scan root joins the import graph only: findings print only for files inside the scan root |
| `exclude` | Paths to exclude from all checks. Component-wise match: pattern components (split on `/`) match path components in order (a subsequence); the final pattern component also covers its dot-extended file form, so `vendor` matches `src/vendor/x.zig` and `src/vendor.zig` but never `src/vendored/`. Empty is a hard error. Ephor ignores the over-broad patterns `/`, `.zig`, `.`, `zig`, and the scan root's first path component with a warning |
| `orphan_exclude` | Patterns to exclude from orphan detection only |
| `disable` | Rule IDs to disable (prefix matching: `ZA3` disables all) |
| `enable` | Rule IDs to enable (overrides disable) |
| `strict` | `true` to exit 1 when any warning/error is found (CI gate) |
| `fail_on` | Finer CI gate: `error`, `warning`, `note`, `never` (overrides `strict`) |
| `coverage` | Coverage gate block (see the gate recipe in Development): `unreached_pub_fn_ratio_max` (f32 percent, `< 0` = off), `min_tests` (0 = off), `require_all_passed` (bool). Absent block = no gate; a malformed value warns and leaves that key off |
| `error_naming` | ZA703 convention for error set member declarations: `TitleCase` (default; `PascalCase` accepted as an alias) or `snake_case` |
| `thresholds` | Complexity and style thresholds. Values clamp at documented maxima (see Config trust model) |

Keys parse in file order. A repeated scalar key (`path_dir`, `strict`, `fail_on`, `error_naming`) resolves last-wins. A repeated list key (`entries`, `exclude`, `orphan_exclude`, `disable`, `enable`) accumulates. `fail_on` outranks `strict` regardless of key order (see Exit Codes). Threshold keys are `max_lines` (alias `max_function_lines`), `max_nesting`, `max_params`, `max_branches`, `max_line_length`, `max_file_bytes`, `max_cyclomatic`, and `max_cognitive`.

### Config changes by version

`install` and `upgrade` stamp the `version` field and never rewrite the
other keys. An unchanged config from an older release keeps its shape
and picks up the behavior changes below. The full release notes live in
[Changelog](#changelog).

**0.13.x → 0.14.x (v0.14.0):**

- New keys: `strict` and `fail_on` (CI exit gates).
- New default-ON rules: the ZT1xx test-quality band (ZT101-ZT105), the
  ZC1xx concurrency band (ZC101-ZC104), ZA110, ZA111, ZA209, and ZA210.
  ZA904 ships off by default (`--enable=ZA904`).
- ZA704 is removed. `disable` and `enable` entries naming ZA704 become
  inert.

**0.14.x → 0.15.x (v0.15.0):**

- New key: `error_naming`. The ZA703 error-name default flips from
  `snake_case` to `TitleCase`. Set `"error_naming": "snake_case"` to
  keep the old behavior.
- New key: `coverage` (the ZT105 unreached-pub-fn ratio gate).
- Eleven new default-ON rules: ZA404, ZA405, ZA406, ZA502, ZA503, ZA504,
  ZA505, ZA506, ZA507, ZA508, and ZT106.
- The `max_cyclomatic` default drops from 15 to 10 (the unified
  complexity standard).
- `exclude` matching changes from substring to component-wise (see the
  Config Options table).
- ZA902 is removed. `disable` and `enable` entries naming ZA902 become
  inert.

### Config trust model

A config file is trusted when its directory is the working directory or an ancestor of it (realpath compare). Every other config is untrusted. `--trust-target-config` declares a scanned target's config trusted.

Ephor honors only `entries` from an untrusted config. It ignores the suppression and CI-gate keys (`disable`, `enable`, `exclude`, `orphan_exclude`, `strict`, `fail_on`, `thresholds`, `error_naming`, `coverage`) and prints one note per offending file:

```
note: ignoring suppression/gate keys from untrusted <path> (use --trust-target-config to honor)
```

The trust decision is visible. A trusted config whose directory covers the scan target prints one note:

```
note: trusting config at <path>
```

Ephor containment-checks honored `entries` at load. Each entry must resolve inside the scan root (realpath compare). Ephor drops an entry that resolves outside, escapes through `..`, or does not resolve, and prints one note per file:

```
note: ignoring <N> outside-root entries from untrusted <path> (use --trust-target-config to honor)
```

The entries that survive are honored as reachability hints, and ephor names them:

```
note: honoring 2 entries from untrusted <path> as reachability hints
```

A non-default `error_naming` convention that comes from a config at or inside the scanned tree prints its own note:

```
note: error naming convention snake_case comes from config <path>
```

Entries extracted from build.zig files in the scanned tree pass the same check, with one note per scan:

```
note: ignoring <N> outside-root entries extracted from target tree <path>
```

Operator channels stay exempt: `--entry`, a trusted config's `entries`, and the working directory's own build.zig may point outside the scan root. Orphan detection then stays complete for files the scan root does not cover. Those files do not produce findings: the scan root bounds the finding scope, and an out-of-root entry is graph-only.

The containment gates realpath a path to decide, then open the original textual path. The final path component opens no-follow, so a symlink swapped in there fails the open instead of redirecting the read, and a symlinked scan root fails closed. An intermediate path component swapped between the gate and the open could still redirect the read. That residual is the accepted posture for a batch scanner.

The `check` scan covers the CLI path and every honored entry point. An entry outside the CLI path joins the scan as an extra root. A targeted run such as `ephor check src/foo.zig` also scans those entry files. The summary's Files count reflects the union. Ephor prints one note when the entries widen the scan:

```
note: scan includes <N> entry points outside <path> (entry points always join the scan)
```

A target config's `path_dir` is containment-checked and then discarded. The scan root comes from the CLI path, the trusted working-directory config, or auto-detection.

The directory walk prunes a hardcoded set: every dot-prefixed directory (`.git`, `.zig-cache`, and other hidden dirs) plus `zig-out`, `zig-cache`, `.build`, `node_modules`, `deps`, `.packages`, and `vendor` (one predicate serves the main walk and the nested discovery walks, EPH-I0377). First-party code under a directory with one of these names is not scanned. The config `exclude` list applies on top of this set. A prune is disclosed: when the main walk skips at least one directory, the run prints one note with the count.

```
note: N directories skipped (hidden or known-cache names). Files inside them are not analyzed.
```

The `.ephor-ignore` auto-load honors the same trust decision. Ephor refuses an untrusted file with one skip note:

```
note: ignoring untrusted .ephor-ignore at <path> (use --trust-target-config to honor)
```

Ephor always honors an explicit `--known-issues=<file>`, and the load stays silent. An explicit file that cannot be read is a hard usage error: a mistyped path never silently un-filters the known-issue list.

The trust decision depends on the invocation directory. The model trusts the operator's own tree, identified as the working directory and its ancestors (realpath compare, `isConfigDirTrusted` in `src/main.zig`). Running ephor from inside a scanned tree makes that tree the trusted one, so the tree's own `ephor.json` then honors its suppression and gate keys. The only signal is the `note: trusting config at <path>` line. To audit a repo you do not trust, run `ephor check <path>` from outside it, or review its `ephor.json` first.

Validation rules:

- Every config `path_dir` resolves relative to the config's directory and must stay inside it. Ephor ignores an escaping value (for example `..` or `/`) with a warning.
- An honored `exclude` list rejects an empty pattern with a hard usage error. Ephor ignores the over-broad patterns `/`, `.zig`, `.`, `zig`, and the scan root's first path component with a warning. Untrusted configs skip `exclude` before validation.
- Threshold values clamp at documented maxima with a warning: 100000 (lines, nesting, params, branches, line length), 10000 (cyclomatic, cognitive), 100000000 (file bytes). Config files and CLI flags clamp alike.
- CLI threshold flags reject a zero or non-integer value as a hard usage error ("expected a positive integer"). A zero threshold would flag every function, so the flag fails closed instead of silently contradicting the value you typed.

### Subprocess trust

Ephor executes the `zig` and `curl` binaries it finds on `PATH`. A poisoned `PATH` is code execution on every analysis run, including a bare `ephor check`. Run ephor in a clean environment, or pin the tools with the overrides below.

Set `EPHOR_ZIG_PATH` and `EPHOR_CURL_PATH` to absolute paths to override the `PATH` lookup:

```bash
export EPHOR_ZIG_PATH=/usr/local/bin/zig
export EPHOR_CURL_PATH=/usr/bin/curl
```

An override that is not absolute or does not resolve prints a warning and falls back to `PATH`. The fallback keeps a typo from blocking the run. The threat is a hostile environment, and the operator controls the overrides.

The subprocess boundary is fixed. The `check` and `fmt-check` commands spawn one analysis child per run: `zig fmt --check` on the scanned path. The update check (see Update Check) may add a capped `curl` fetch when its 24 h cache is stale. The child is read-only: no build, no test, and no execution of scanned code. Its output is capped at 10 MB, and its paths gate on the scan root. Ephor resolves the `zig` binary to an absolute path at startup, so the spawned binary is fixed before any scan input is read.

## Rule IDs

### Memory (ZA1xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA101** | warning | ON | Stdlib allocation without `defer free()` (alloc, allocPrint, toOwnedSlice, readFileAlloc, mem.concat, etc.) |
| **ZA102** | warning | ON | `create()` without `defer destroy()` |
| **ZA103** | warning | ON | Stdlib allocation without `errdefer` in error-returning function |
| **ZA105** | error / warning (conditional use-after-free) | ON | Use-after-free: accessing memory after free |
| **ZA106** | error / warning (conditional double-free) | ON | Double-free: calling free twice on same pointer |
| **ZA110** | warning | ON | Managed container local returned by value while a `defer x.deinit()` is still armed — the returned copy's backing is freed (the plain `var x = ...; return x;` ownership-transfer idiom is correct and stays silent). Also the dual-owner form: `return self.list;` copies the header while the receiver stays alive — a visible field reset (`self.list = .empty;`) adjudicates the take() idiom |
| **ZA111** | error | ON | Returned-stack-reference (AST tier): returned pointer/slice provably refers to a stack local or by-value parameter (`return &s.field;`, `return &param;`, `const p = &x; return p;`, `return arr[0..n];`). Covers the forms Zig's Sema misses: out-param escapes (`out.* = &x;`), labeled-block breaks, if/for payload-capture returns, `@ptrCast`/`@as` evasion, `@field`/`@unionInit` chains, named array-alias indexing, rebound var aliases, and slice bindings of arrays. The bare `return &var;` form is a hard compile error and is never echoed. Chains through pointer/slice bindings or fields are safe and stay silent, as do `comptime` blocks, `comptime var`s, and unresolvable types |

**Memory family caveats.** The 2026-08-01 audit found two family-wide silences: a used allocation stayed quiet for the no-defer rules, and cross-block frees stayed invisible. Both are fixed. Every shape named here ran live against the current binary.

- **ZA101/ZA102 fire through every probed use.** An indexed fill (`buf[0] = 1`), a loop fill, a loop increment, a bare loop read, a slice pass, a variable copy, and an aggregate init (`const h = Holder{ .slice = buf };`) all warn. The fixes: the bare loop read began to warn under a real assignment predicate (EPH-I0327), the transfer rule narrowed to ownership-capable targets (EPH-I0346), and the two fill-mask sites fell last (EPH-I0752, EPH-I0102). What stays silent is the ownership transfer, by design. A field store into a pre-existing holder (`h.slice = buf;`) or a `return buf;` moves ownership to the caller, so the no-defer rules have nothing to report. ZA102 follows the same line. A used `create` warns, and the same two transfer shapes silence it.
- **ZA105/ZA106 cross-block dataflow.** The forward fixpoint propagates a free across nested blocks (EPH-I0676): a use after a conditionally-executed free reports the conditional warning even when the free sits several blocks deep. The two residuals the audit named are fixed and firing: the return-else shape (`return; } else { free(x); }` before the use) reports an error, and the errdefer-then-free-then-use tail fires. One grading residual stays open: after an unconditional free, a second free inside the shallower arms of an all-arms else-if chain reports a warning instead of the error (EPH-I1145). The direction is safe.

### Error Handling Patterns (ZA2xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA201** | warning | ON | Silent `catch {}` discards error |
| **ZA202** | warning | ON | `catch unreachable` will panic on error |
| **ZA203** | warning | ON | `orelse unreachable` will panic on null |
| **ZA204** | warning | OFF | `= undefined` may leak sensitive data (use `--enable=ZA204`) |
| **ZA205** | note | OFF | Discarding error union result (use `--enable=ZA205`) |
| **ZA206** | warning | ON | `exit()` bypasses defers (memory leak!) |
| **ZA207** | warning | ON | `catch undefined` (dangerous — converts errors to UB) |
| **ZA208** | note | ON | `@panic()` crash point (informational) |
| **ZA209** | note | ON | Error union return type `!` but function never fails (no `try`, no `return error`, no propagated payload) — drop the `!` |
| **ZA210** | note | OFF | `catch \|e\| return e` is a verbose `try` (use `--enable=ZA210`) |

**ZA209 scope:** error paths are deliberately over-counted (note severity, false-positive-safe direction). Silent when the body has `try`, `return error.*`, a returned catch payload (`catch \|e\| return e` or a later `return e;`), a returned error-typed parameter (`err: anyerror`) or error-literal/call-derived local, any `return f(...)` or `return Namespace.member;` (the target may carry an error union ephor cannot resolve cross-module), or `unreachable` (assertion-style bodies). Also silent for the **interface-shim** carve-out: a body of `_ = param;` discards with no call-containing statement, only constant/void/aggregate returns, and at most 4 non-discard statements — the noop interface implementation (ghostty's `KeymapNoop.translate`, `OpenGL.threadEnter`) whose `!` is forced by the interface, making the note unactionable. A `_ = foo();` call-result discard is real work, not a shim marker, and real infallible logic (calls, computed returns, or simply no discards — messenger's `parseVersion` class) keeps firing. Two classes are accepted with eyes open: (1) interface-conformance bodies with real computation — uniform-signature implementations such as ghostty's shaper backends and `draw*` fns — **fire** with a factually-accurate "never fails" note that is often unactionable (the error union exists for interface uniformity); accepted as note-level noise. (2) Error paths behind labeled blocks (`break :blk error.X`) are not scanned, so a function whose only error path is block-carried still fires — a rule-level false positive. Error evidence inside nested functions rolls up into the outer function (ZT101 precedent), an accepted false negative.

**ZA210 scope:** single-line, same-payload forms only: the bare return (`foo() catch \|err\| return err;`) and the one-line block whose sole statement is the payload return (`foo() catch \|err\| { return err; }`). A block that does real work between catch and return (`catch \|err\| { log(err); return err; }`), a block with a second statement or a different return payload, and the multi-line block form stay silent by design.

**ZA208 scope:** the note fires on every code-position `@panic(` outside test context — test blocks and test files are suppressed (pinned by "ZA208 @panic does NOT fire in test block") — and documentation never silences it. The rule reports an objective fact (a crash point exists); a doc-comment or helper-name carve-out would make the rule judge the *quality* of the justification or the helper's name, both opinions the detection philosophy excludes (type/data-flow-based, never name-based — EPH-I0278, decided WONTFIX). The sanctioned per-site escape hatch for a justified panic is the inline `// ephor:ignore ZA208` directive: the human records the justification decision, the analyzer stays factual. The note never fails a gate, and its help text already names documentation as a valid response ("document why panic is necessary").

### Complexity (ZA3xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA301** | warning | ON | Function exceeds max lines (default: 50; type factories get 3x, data tables get 20x) |
| **ZA302** | warning | ON | Function exceeds max nesting depth (default: 3; type factories get 2x) |
| **ZA303** | warning | ON | Function has too many parameters (default: 4; counted across multi-line signatures). Exempt: `extern`, `export`, and `callconv(.c)`/`callconv(.C)`/`callconv(.Stdcall)` declarations — a pinned ABI fixes the parameter list (EPH-I1059, EPH-I1093, EPH-I1096) |
| **ZA304** | warning | ON | Function has too many branches (default: 12; type factories get 3x, data tables get 20x, flat switch dispatchers get 2x) |
| **ZA305** | warning | OFF | Function has high cyclomatic complexity — McCabe CCN (default: 10) |
| **ZA306** | warning | OFF | Function has high cognitive complexity — Sonar-style weighted nesting (default: 15) |

**Note:** Functions returning `type` (comptime type factories like `fn Bind(T: type) type`) automatically get relaxed limits since they are metaprogramming constructs that build types at compile time. `inline for/while` loops are not counted as branches since they are compile-time unrolled.

**Data-dispatch functions** (parse/deserialize/serialize/config loaders — one branch per field) get an 8x limit on ZA304, ZA305, and ZA306. **Flat-chain functions** (routers/dispatchers where cognitive <= cyclomatic x 1.5 and max nesting <= 2) get a 2x limit on ZA305 and ZA306. **Flat switch dispatchers** (a top-level switch whose arms sit at one level with trivial bodies — the cognitive excess over cyclomatic is at most the arm count, the switch scope's per-arm scaling) get a 2x limit on ZA304, ZA305, and ZA306. **Data tables** (structurally detected pure data mapping — constant arms, literal-assignment rows, no calls or control flow) get a 20x limit on ZA301, ZA304, ZA305, and ZA306.

### Cyclomatic Complexity (ZA305)

McCabe's cyclomatic complexity counts independent execution paths. Every `if`, `while`, `for`, `switch`, `catch`, `try`, `orelse`, `and`, and `or` adds 1 to the count. Each `=>` switch arm adds 1 to the count. A standalone `else` adds nothing: it is the alternative of an already-counted predicate (an `else if` line counts once, for its `if`). A function with no branching has a CCN of 1. Default threshold: 10.

### Cognitive Complexity (ZA306)

Sonar-style cognitive complexity weights branches by nesting depth. An `if` at the top level costs 1; the same `if` nested 3 levels deep costs 4 (1 + nesting depth). Logical operators (`and`/`or`) cost 1 each regardless of depth. Default threshold: 15.

### Enabling ZA305 and ZA306

ZA305 and ZA306 are off by default. To enable them, remove `"ZA305"` and `"ZA306"` from the `"disable"` array in `ephor.json`, or add them to the `"enable"` array to explicitly enable them. The default thresholds are `max_cyclomatic: 10` and `max_cognitive: 15`; lower values are stricter.

### Unused Code (ZA4xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA401** | warning | ON | Unused import |
| **ZA402** | warning | ON | Unused const declaration |
| **ZA403** | warning | ON | Unused var declaration |
| **ZA404** | warning | ON | Unused private function: a fn declared without `pub` that no code position references anywhere in the project — no call site, no fn-value reference, and no test caller. The tests-as-callers carve-out is principled, not a blanket exclusion: a test decl is the caller of record (EPH-I1082). Name-level and conservative: any identifier occurrence sharing the name suppresses the finding (the ZT105 flat-namespace direction). Exempt: C-ABI decls (their callers live outside Zig source) and `main`. Statically invisible invocation (`@field` dispatch, external callers) is the residual class |
| **ZA405** | warning | ON | Unused parameter: a private fn declares a parameter its body never references. Exempt: pub fns (interface and vtable impls are public by construction), the `self` receiver, `_`-prefixed names (the deliberate-unused convention), generic fns (`comptime`/`anytype` params and the bare `T: type` spelling), and C-ABI decls (EPH-I1080) |
| **ZA406** | warning | ON | Unnecessary var: a var whose binding is never mutated anywhere in the body — `const` suffices (Zig's const is deep). The name-level mutation shapes the scan covers stay silent: a reassignment (`x = 1`), a compound assignment (`x += 1`, the saturating and wraparound forms), a field store (`x.field = 1`), an element or slice position (`x[i] = 1`, `x[0..]`), an address-taken view (`&x`), a dotted call chain (`x.append(...)`, `x.changes.?.map.put(...)`), an `@field`/`@memset`/`@memcpy` first argument, a pointer capture (`if (x) \|*v\|`), a destructuring assignment (`x, y = .{...}`), and an inline-asm operand. Outside the covered set, a mutation the callee makes through a by-value argument stays invisible to the scan (a buffer handed to `std.mem.set(u8, buf, 0)` writes through the slice parameter), and the rule fires there while `const` is a compile error — an accepted residual (EPH-I1246). Exempt: `comptime var` and `threadlocal var`, a `var` inside a struct/enum/union/error/opaque body (a static field is always mutable), and the fn-interface carve-outs (generic fns, type factories, C-ABI decls stay silent). Name-level and conservative: a shadowed or aliased mutation silences the finding |

**ZA405 and interface signatures:** the carve-out for pub fns is
structural: a fn that implements an interface or fills a vtable slot must
be callable from the impl site, so its signature is fixed by the
contract, not by the body. A private fn keeps its parameter list by
choice, so an unused parameter there is speculative generality.

### Structure (ZA5xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA501** | warning | ON | Orphan file (not imported from entry points) |
| **ZA502** | warning | ON | File reaches or exceeds the 10 MiB source read cap and is skipped from analysis (split the file into smaller units) |
| **ZA503** | warning | ON | File does not parse (the AST tier's host-parser check rejected it): one finding per file, located at the first parse error, naming the error. The line tier still scans the file, but `zig build` cannot compile it (EPH-I0742) |
| **ZA504** | warning | ON | Duplicated block: a run of 6 or more normalized lines that repeats within one file or across files (copy-paste duplication, EPH-I1076) |
| **ZA505** | warning | ON | Passthrough wrapper: the fn body is a single call statement (`return`/`try` prefixes allowed) whose argument list is exactly the parameter list in order (a shallow module that adds interface without hiding implementation, EPH-I1077). Nullary C-binding rename wrappers (`fini` → `c.FcFini`) and generated-code forwards (a wrapped forward a code generator emits) are true positives by the rule's letter and keep firing by design — the nullary shape is the EPH-I1239 nullary-consequence pin (EPH-I1242). Where regeneration overwrites the edit, suppress the generated file with `// ephor:ignore-file ZA505` |
| **ZA506** | warning | ON | Boolean flag parameter: a `bool`-typed parameter whose name appears inside an `if`/`switch` condition in the body — the flag selects between two code paths (two functions in one signature, EPH-I1081) |
| **ZA507** | note | ON | Redundant else: an else whose if-branch ends in return/break/continue — the guard-clause style removes the else and one nesting level. else-if chain links, switch `else =>` prongs, and error-capture elses (`else \|err\|`) stay silent: they carry real branch structure, not redundant nesting |
| **ZA508** | note | ON | Simplifiable boolean return: `if (x) return true else return false;` (or the reversed form) where `return x;` / `return !(x);` suffices. Both branches must be exactly one `return <bool literal>;`; equal literals, extra statements, and else-if links stay silent |

**ZA505 and interface implementations:** a forward to a method of the
same name (`fn write(...) { return self.backend.write(...); }`) is an
interface impl by structure — the wrapper IS the job — and never fires.
A forward to a different name (a rename-only lifecycle wrapper like
`deinit` → `destroy`) is the finding class. Generic fns and C-ABI decls
are exempt: their signatures are compile-time or external contracts.
A wrapper whose name the file references as a fn value — an argument
segment, an assignment right-hand side, or a return expression — is a
generic-instantiation adapter and never fires (the value-reference
carve-out, EPH-I1238): a generic callee cannot serve a value position,
so the wrapper exists to monomorphize it.
**ZA507/ZA508 and the fn-interface carve-outs:** both rules ride the
fn-interface pass, so generic fns, type factories, and C-ABI decls stay
silent — their bodies are compile-time machinery or external contracts.
**ZA506 and flag conventions:** the rule fires on the selector shape
(the flag sits in a condition), never on a flag that is only passed
along or returned. `?bool` counts as a flag type; the receiver and
generic fns are exempt.

**ZA504 and normalization:** the normalized form of a line strips `//`
comments (quote-aware), trims surrounding whitespace, and drops blank
and comment-only lines. Consecutive duplicated windows merge into one
finding per maximal run, so a 30-line copy reports once with its full
span. Three deliberate-duplication surfaces never join the comparison:
lines inside test bodies, including each test block's closing brace
(test scaffolding repeats by design), `\\` multiline-string content
(help text and fixtures are data, not code), and cross-file pairs whose
files both sit under a directory named `compat` (version-mirror trees).
A fourth surface stays silent: a same-named whole-type declaration
(`const Name = struct {` family, plain, packed, or extern, with an
optional backing-type group such as `struct(u32)` — EPH-I1306) mirrored
byte-for-byte in a different build root — the host-build stand-in shape
(EPH-I1295). The duplication IS the mechanism there: the two builds
cannot share the file, and flagging demands an impossible refactor. The
arm is narrow — the duplicated run must BE the whole type exactly, both
sides must declare the same name, and the two files must attribute to
two different build roots (their nearest directories containing a
`build.zig`). A partial-field pair and a same-root pair keep firing.
A fifth surface stays silent: the same-root comptime-if stand-in
(EPH-I1308, the RhyOS `OpenFlags` pair) — a same-named whole-type
declaration directly inside the anonymous-struct else arm of
`const x = if (cond) @import(...) else struct { ... }`, where the
@import resolves to a file that declares the same name. The host build
cannot take the import branch, so the else-arm stand-in IS the
mechanism, and flagging demands the same impossible refactor. The arm
is narrow — the duplicated run must BE the whole type exactly, both
sides must declare the same name, the container must be the bare
anonymous struct (a named container, an else block, or deeper nesting
keeps the pair firing), and the import must resolve with the resolved
file declaring the same name. The condition is never inspected: the
pair goes silent whenever the shape matches, even when the condition
would select the import arm and leave the else arm dead in that build
configuration. The
analyzer re-verifies hash-collision candidates byte-for-byte before
reporting, so a finding is never a hash collision.

**ZA501 and the build graph:** build.zig contributes reachability
through its `b.path("...")` references — test roots and tools that
nothing `@import`s are alive only because build.zig compiles them.
When the scan tree lacks a readable build.zig (a scratch copy that
omits it, a broken symlink), ephor cannot see those compile roots, and
ZA501 would misreport them as orphans. In that build-blind mode ZA501
applies a conservative rule: it skips any file that some analyzed file
imports, and any file that declares `pub fn main` (a main is only
compilable as a root module, so it is root-surface evidence). The rule
silences the false-positive class; it never fires new findings. A dead
file that nothing imports and that carries no main still fires. When
ephor reads build.zig, normal reachability applies unchanged
(EPH-I1060).

### Formatting (ZA6xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA601** | warning | ON | File needs `zig fmt` |
| **ZA607** | warning | ON | Variable potentially read before assignment on some code path |

**Note:** ZA607 is a semantic definite-assignment check (CFG-based), not a
formatting rule — it lives in the ZA6xx range only for backward compatibility
with existing inline-ignores, and is reported under the Memory category in
`--summary` output.

### Style (ZA7xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA701** | warning | ON | Line exceeds max length (default: 100 characters; lines over-length solely due to unbreakable string-literal content are exempt) |
| **ZA702** | warning | OFF | File exceeds max size (requires `--enable=ZA702` or config `enable`; threshold via `max_file_bytes`, default 50000) |
| **ZA703** | warning | ON | Naming convention violation (see naming rules below) |

ZA704 (`std.debug.print` left in non-test code) was removed in 0.14.0 —
intent-based, cannot be grounded in objective detection (see EPH-I0049).
The ID is retired and will never be reused.

#### ZA703 Naming Rules

Based on the [Zig Style Guide](https://ziglang.org/documentation/0.15.2/#Names):

| Declaration | Expected | Example |
|---|---|---|
| Type definitions (`struct`, `enum`, `union`, `opaque`) | `TitleCase` | `const MyStruct = struct {};` |
| Functions returning `type` | `TitleCase` | `fn ArrayList(comptime T: type) type {}` |
| All other functions | `camelCase` | `fn getValue() u32 {}` |
| Generic functions returning `T` (not `type`) | `camelCase` | `fn maxInt(comptime T: type) T {}` |
| Variables (`var`) | `snake_case` | `var my_count: u32 = 0;` |
| Constants (`const`) | `snake_case` | `const max_size = 1024;` |
| Type aliases (`const`) | `TitleCase` | `const Allocator = std.mem.Allocator;` |
| Function aliases (`const`) | `camelCase` | `const eql = std.mem.eql;` |
| Error set members | `TitleCase` | `error{ FileNotFound }` |
| Imports | (not checked) | `const std = @import("std");` |
| Names starting with `_` | (exempt) | `fn _helper() void {}` |

**Error naming:** `TitleCase` is the default because the stdlib and virtually all community code declare TitleCase error names (the pre-0.15.0 ZA703 default of `snake_case` produced false positives on idiomatic Zig). Set `"error_naming": "snake_case"` in `ephor.json` to keep the old behavior.

**ZA703 fire surface:** ZA703 fires on error-set member declarations only — the body of an `error{...}` set, whether a named const or an inline set in a signature or type. Use sites of an error value are never flagged: a used error value cannot be restyled per site, and renaming the set is a cross-tree refactor unrelated to the change that triggered the hit (EPH-I1075).

**ZA703 exemptions:** `extern fn` declarations are exempt — their names are ABI-fixed (`export fn` names are NOT exempt — they are project-chosen identifiers). Identifiers on the right-hand side of error-set composition (`error{ a, b } || other.Error`) are references to other error sets, not members, and are not checked. Variables are judged by declaration kind: `var` is always `snake_case`, even when its value is a function reference. Declared members that match the std library's canonical error names (`OutOfMemory`, `NoSpaceLeft`, `FileNotFound`, and every other name the stdlib declares in an `error{...}` set, pinned in `std_canonical_error_names`) are exempt (EPH-I1296): a Zig error name is a global singleton, so a declared member matching a std name unions with the SAME error, and renaming it changes the error identity and breaks the coercion — an impossible refactor. A non-canonical TitleCase collision is the project's own name and stays reportable in `snake_case` mode (EPH-I0473).

#### Generated files

A file whose head (first two non-empty lines) carries one of these
banner tokens inside a comment is treated as generated:

- `Code generated` (protoc-gen-zig style)
- `AUTO-GENERATED` (ClockHelper-zig style)
- `DO NOT EDIT` (sig wycheproof, ghostty nerd-font, zls Config.zig style)

ZA701 (line length) and ZA703 (naming) stay silent on generated files:
the generator chose the names and line shapes, and the project cannot
restyle them by hand. Every other analyzer keeps full coverage
(EPH-I1062). The banner must sit in the head — a prose mention later
in the file does not mark a file generated.

Generated trees that carry no banner (libqt6zig's Qt bindings, for
example) are an accepted corpus cost: put the generated directories in
`exclude` in `ephor.json` when the project wants them out of the
report. Banner detection cannot serve marker-less trees, and no
path-class heuristic is grounded for them.

### Null Safety (ZA8xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA801** | warning | OFF | Optional unwrap (`.?`) may panic if null — fires on any continuation except `;`, `,`, `)`; suppressed in if/while/orelse and std.testing-call contexts (use `--enable=ZA8`) |
| **ZA802** | warning | OFF | Dereferencing a nullable pointer may panic or cause undefined behavior (use `--enable=ZA8`). Fires on `.*` derefs of variables declared `?*T`, `[*c]T`, or `*allowzero T` without a null check on the path. |

**The test-call suppression is receiver-scoped (EPH-I0296).** A line
disarms through a test call only when the receiver is the std.testing
module: `testing.expect(...)` and `std.testing.expect(...)` qualify. A
user method on another receiver (`tokens.expectToken(...)`) or a user
field (`foo.testing.bar(...)`) does not disarm. A renamed import
(`const t = std.testing; t.expect(...)`) is a documented false negative:
the receiver is not `testing`.

**When to enable ZA8xx:** Pre-release audits for safety-critical code (servers, databases) where a null panic means downtime. Off by default because `.?` is extremely common in Zig and usually intentionally guarded.

### Panic Detection (ZA9xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA901** | warning | OFF | Decrement without overflow guard may panic (use `--enable=ZA9`) |
| **ZA903** | warning | OFF | Subtraction in an array index may underflow (use `--enable=ZA9`) |
| **ZA904** | note | OFF | `@intCast`/`@truncate` without a bounds proof in the preceding lines (use `--enable=ZA904`) |

**ZA904 guard classes** (any one suppresses the note, scanning the same-line
prefix and up to 10 preceding lines, stopping at function boundaries): a
comparison against the target type's limit (`x < N`, `x <= N`,
`std.math.maxInt`/`minInt`), an exit guard on the over-limit path
(`if (x >= N) return/break/continue`), `@min`/`@max` clamping of the casted
variable, a `std.math.cast` checked conversion of the same variable, or a
`const x = <literal>` declaration (comptime-known value cannot fail the
cast), or a range-for index capture over a bounded range (`for (0..N) |i|` —
last capture only, and the range expression must be present; iterating a
slice with `for (items) |x|` is not a proof). `testing.expect` lines are
skipped entirely (assertions construct fixtures, they do not need guards).
Only plain-identifier arguments are analyzed — literals (already
comptime-known), expressions, field accesses, and multi-line calls are
skipped silently. Note that `@truncate` can never panic (it is defined to
discard high bits); its message names the real defect — silent data loss.

**When to enable ZA9xx:** Before switching from `Debug` to `ReleaseFast` builds — in debug mode, integer overflow panics helpfully; in `ReleaseFast` it becomes undefined behavior. Also useful for security-sensitive or financial code where overflow = vulnerability.

**ZA901/ZA903 guard-walk note:** the zero-check backstop is amount-aware, but a write between the guard and the candidate defeats the proof even when the write provably cannot introduce zero (for example `m += 5`, or a `while (m > 3) m -= 1;` loop before `m -= 1`). Judging those writes needs per-write-site guard reachability that the line walk cannot carry. The class is tracked in the Known False Positive Patterns table.

### Tests (ZT1xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZT101** | warning | ON | Lie test: test name references a fn defined in this file that the body never calls, directly or through file-local helpers |
| **ZT102** | warning/note | ON | Test block with no assertions: `warning` when the body has no calls that can fail, `note` for try-only smoke tests (errors still propagate) |
| **ZT103** | warning | ON | Trivially-true assertion: `expect(true)`, `expectEqual(x, x)`, or `expect(x == x)` with textually identical operands |
| **ZT104** | note | ON | Test swallows error: empty `catch {}` (any payload) or `catch unreachable` in test context — the failure stays unobservable |
| **ZT105** | note | ON | Public fn never called or referenced from any test block in the project — `zig build test` cannot see uncovered API surface; note severity because indirect/integration coverage is statically invisible |
| **ZT106** | note | ON | Test block whose body carries no call site — the runner counts the block as a passing test while executing it covers no function body. A body of only `_ = Name;` reference discards is a compile pin and stays silent |

`zig build test` cannot catch these: a test whose name promises coverage the body never exercises passes anyway, a test with no assertions passes trivially, an assertion that is true by construction verifies nothing, and a swallowed error keeps the test green. ZT101 extracts fn-name candidates from the test name (ident form, or string-form words that look like code references and exactly match a non-generic local fn — prose words never match) and requires at least one candidate to be reachable from the body through the file-local call graph. The check is any-satisfied (OR) suppression: one satisfied candidate silences the test, and the message names only the first candidate — a test named for two fns that calls only one of them is not flagged (EPH-I0431). Invocation through comptime reflection is invisible to that graph: `std.json.parseFromSlice(T, ...)` reaches a type's `jsonParse` method without a textual call or value reference, so a test that genuinely exercises the fn still fires (zlint's `Severity.jsonParse` class). A value reference in the body (`_ = Severity.jsonParse;`) is the workaround and counts as evidence. ZT102 counts assertion-shaped calls inside each `test {}` block: calls whose target name carries `expect` or `assert` as a whole word (split on case transitions and underscores — `expectEqual`, `std.debug.assert`, and custom `assertFoo` helpers count; `unexpectedError` and `unexpected_errno` do not, EPH-I0048), calls whose target name carries the whole word `snap` (the `snap(@src(), ...)` idiom — substrings like `initWithSnaplen` do NOT count), dotted snapshot-diff methods (`.diff(...)`, `.diff_fmt(...)`), and `try`-propagated verify/validate calls, where absence of error is the assertion (EPH-I0047). A call to `expect` or `assert` whose only argument is an enum literal (`expect(.kwIf)`) is a token matcher, not an assertion, so it neither counts nor witnesses (EPH-I0048). A block that only delegates is also covered when a fn it calls — directly or through the file-local call graph — contains an assertion in its own body, and cross-file helpers are covered anywhere in the project for code-shaped (distinctive) names (ubiquitous lowercase names like `init` stay file-local). The helper-mediation witness set excludes the verify/validate verbs, so a test whose only check is a called helper that validates under `try` still fires (EPH-I0047). ZT103 inspects `expect`/`expectEqual` arguments string-aware, so `expectEqual("a,b", s)` and `expectEqual("true", s)` are not flagged. ZT104 inverts ZA201/ZA202 in test context (each fires only outside it), keeping the condition-position idiom (`while (it.next() catch {})`) and best-effort cleanup (defer/discard/cleanup-method/stream forms) exempt; for `catch undefined` it defers to ZA207's higher-severity report, which keeps firing in tests.

ZT105 is the band's project-level coverage rule: it collects every `pub fn` (skipping generics, type factories, and `main`; `pub inline fn` and `pub noinline fn` decls and quoted names like `pub fn @"foo-bar"` count) and checks the name against a project-wide test corpus — every identifier inside any `test {}` block in any analyzed file, the whole content of test files (`_test.zig`, `/test/`, `/tests/`), and anything reachable from test-block calls through the project-wide call graph (a private helper between the test and the pub fn still counts, and the chain may cross files: a test in `foo_test.zig` reaching a pub fn in `foo.zig` through a helper in either file covers it). Value references count as coverage, so a fn passed to a table/fuzz harness is not flagged, and a name appearing in any non-test value position (a re-export like `pub const x = name;`, a function-pointer table, a same-named field) suppresses the note conservatively. A pub fn nested inside a type factory counts as covered when any test instantiates the factory — the nested declaration lines roll up as call edges under the factory's span. String literals and comments are never evidence, so a test merely *named* after a fn does not cover it. Matching is by name across a flat project namespace — two same-named pub fns in different files share coverage — and coverage through reflection (`@field`, `@hasDecl`), C-ABI callers, or out-of-tree harnesses is statically invisible, which is why the rule is a note rather than a warning. Evidence is segment-granular: every dotted segment counts as its own name, so a test-local variable `header` marks a same-named pub fn covered, and a non-test value-position segment (`config.mode`) aliases a pub fn `mode` — the name-based boundary cost of the flat namespace, conservative in the FN direction (EPH-I0434). The name merge over-approximates: a genuinely untested pub fn can be suppressed by a same-named fn reachable from a test in another file (tigerbeetle `lsm/tree_fuzz.zig` `apply`, EPH-I0907); a distinctive-name gate on the call graph was rejected because it re-flags genuinely test-reachable fns whose chains run through plain names (ghostty's `prepare`, sole call site inside `RunIterator.next`, itself driven by same-file tests).

ZT106 is the band's second project-level rule and the static/dynamic reconciliation floor (EPH-I1089): it takes the `list-tests` discovery census (the static listing of every test block the runner executes) and checks each block's body — from the opener through its brace group's close — for at least one call site. A block with none invokes no function, so executing it covers no function body: the runner counts it as a passing test while it verifies nothing dynamic. The rule is a note and FN-tolerant by design: anything that could hide an invocation counts as one — `if (`/`while (`/`switch (` condition parens read as call sites, and `@`builtins like `@compileError` do too — so a block fires only when its body provably calls nothing. The accepted FN bounds: the two unhandled Allman opener shapes and same-line double test decls the listing skips stay silent; a body that only declares items fires (the block executes no call either way); a body whose brace group never balances stays silent (fail open); a fn exercised only through comptime reflection without a textual call still has a call site at the reflection entry point, which silences the note; and a compile-pin body stays silent (EPH-I1294): when every statement is a pure reference discard (`_ = Name;`, `_ = Name.field;` — identifier chains only, no call, no operator, no literal), the references force the compiler to semantically analyze the named declarations, a real verification the call-site premise misses. The arm requires at least one discard and rejects keyword references (`_ = undefined;` names no declaration) and mixed bodies.

### Concurrency (ZC1xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZC101** | warning/note | ON | Lock-family acquire with no covering `defer` release: `warning` when no release exists anywhere in the fn, `note` when a plain (non-defer) release exists but error paths bypass it |
| **ZC102** | warning/note | ON | Lock-family acquire while the receiver is already held on the same path: `warning` for exclusive-mode re-acquires (certain deadlock), `note` for double `lockShared` (deadlocks under std's writer-preference RwLock only when a writer queues between the acquires) |
| **ZC103** | warning | ON | `warning` for a fn-scope `defer unlock` whose only acquire is a conditional `tryLock` — the defer runs on the tryLock==false path too, unlocking an unheld lock |
| **ZC104** | warning | ON | `std.Thread.spawn` handle never joined or detached anywhere in the file — the std requirement ("the caller must eventually either call `join()` ... or call `detach()`") makes the handle leak certain |

Neither `zig build` nor `zig build test` can see these: a missing `defer unlock()` only manifests as a deadlock or lock leak on an error path at runtime. ZC101 is API-agnostic — it matches method *names* in the lock/unlock families (`lock`, `lockShared`, `lockUncancelable`, `lockSharedUncancelable`, `tryLock`, `tryLockShared`, and semaphore `wait`/`waitUncancelable`/`post`), so Zig 0.15 (`std.Thread.Mutex`) and 0.16 (`std.Io.Mutex`/`std.Io.RwLock`/`std.Io.Semaphore`) codebases are covered by the same scan — with one type-backed gate: an acquire whose receiver is a bare fn-parameter name bound to a struct declared in the same file with no tracked lock-primitive field reads as a domain method (the RhyOS `VaultManager.lock()` auto-lock class) and stays silent (EPH-I1228). Chain receivers (`self.mu.lock()`), std-typed params, locals, and cross-file structs keep the name-match behavior. A same-fn `defer`/`errdefer` release counts as coverage only when the defer registers on every acquired path: its statement depth must be at most the acquire's depth (a conditional `defer if (c) m.unlock();` at the same level qualifies; a defer nested inside a branch the acquire sits outside of does not — it registers only on that branch and runs at the block's exit), with one exception for an acquire in condition position (`if (mu.tryLock()) { defer mu.unlock(); }`), where the opened block is the acquire's own guard. Pairing is strict: `lockShared` pairs with `unlockShared`, `wait` with `post` — a mis-paired release is not coverage. Five suppressions keep intentional designs silent: a tiny acquire wrapper (`fn acquire() void { mu.lock(); }`), the lock-less-struct domain-method gate named above, a release of the same receiver field-chain in any other fn of the same file (the zls `InternPool`/`string_pool` acquire/release idiom), a discarded acquire result (`_ = file.tryLock(...)`, the hold-till-close file-lock idiom), and a free-function release whose first argument is the acquire's receiver (`compat.fileUnlock(file)` in a sibling release fn, the hold-till-close file-lock release — the argument is the pairing receiver, not the module prefix; EPH-I0903). `wait`/`waitUncancelable` are only evaluated as semaphore acquires when a `post` on the same receiver exists somewhere in the file — without that evidence they are assumed to be WaitGroup/condition-variable/process/event waiting, none of which pair with `post`. Matching is textual by receiver field-chain (`self.mu`, `ip.lock`); string literals and comments are never evidence, calls inside `test` blocks are not attributed, and a solo `errdefer` release with no success-path release is a documented blind spot. Four more residuals are accepted with eyes open: the cross-fn suppression requires the receiver field-chain text to match exactly, so a release spelled differently across the fn boundary (ghostty's blocking_queue `self.mutex` vs `self.queue.mutex`) is invisible and the acquire still warns; `close()` is not in the release family, so a resource whose lock is released by closing it (messenger's file handle, `file.lock()` held and `file.close()` releasing in a sibling) shows no release; a mis-paired release is never reported by ZC101 itself (it judges acquire coverage only), so a mis-pair beside a correctly-paired same-receiver release is masked; and the tiny-wrapper suppression counts body statements, so a conditional acquire (`fn acquire() void { if (c) mu.lock(); }`) fits the one-statement shape and its missing release is invisible. A fn-scope `defer unlock` at a conditional `tryLock`'s depth or shallower satisfies the depth rule, so the tryLock==false path stays silent here — the unlock-of-unheld is the reserved ZC103 warning shape. Nested-fn lock events roll up into the outer fn's record for the coverage math (type-factory methods, local struct methods), so a nested acquire with no release surfaces as a note or warning on the outer record (mach module.zig class).

ZC102 walks each fn's lock events in source order — acquires, plain and deferred releases, and block closes — tracking per-receiver held state. A blocking re-acquire while held is flagged; acquires in sibling if/else arms or switch prongs are disjoint paths and never flagged (the arm chain survives while each close opens another arm — `} else {` / `},` — and ends at the first plain close, so `if (c) { mu.lock(); } else { work(); } if (d) { mu.lock(); }` warns on the c∧d path). Timing is execution-order, not registration-order: a deferred release clears the hold only when its scope closes (`mu.lock(); defer mu.unlock(); mu.lock();` warns — the second lock executes before the defer runs), while a loop-body or `tryLock` guard-block defer releases on exactly the held paths and stays silent. A branch-scoped release (plain or deferred) downgrades the hold to path-conditional instead of clearing it, so `mu.lock(); if (c) { mu.unlock(); } mu.lock();` warns on the !c path. Semaphore `wait` is exempt (a counting semaphore may wait twice legally) and a `tryLock`-family second acquire is exempt (it cannot block, so it cannot deadlock). Remaining blind spots, all false-negative-safe unless noted: an `errdefer` release is treated as firing on all paths (it fires only on error paths), a hold suspended through a nested-fn declaration is not restored when the outer flow resumes, loop back-edges are not modeled (a hold carried across iterations is invisible to the single-pass walk), and a release inside a bare `{}` block reads as branch-scoped (contrived shape, and the one FP-unsafe direction). The arm chain is recognized only when the close and the `else` or `,` share a line (`} else {` / `},` — the `zig fmt` form), so a multiline else in unformatted code ends the chain at a plain close and the arms read as sequential ifs — a re-acquire across them warns (an FP bounded by ZA601).

ZC103's remaining channel is the conditional-`tryLock` fn-scope-defer warning: `if (mu.tryLock()) { work(); } defer mu.unlock();` runs the defer on the tryLock==false path too. Neither set-aside idiom can trip it: the deferred re-lock (`m.unlock(); defer m.lock();` borrow idiom) is not a conditional try acquire, and a discarded `tryLock` result (`_ = file.tryLock(...); defer file.unlock();`) is not evaluated and is not in condition position. The old zero-evidence note — a release whose receiver never acquires anywhere in the file — is gone (EPH-I0903): that shape is an app-domain method (`ClientIdentityGate.unlock(passphrase)`) or a RAII guard (`writeWithLock()` binding) more often than a lock release, and no textual signal separates it from a real 0.16 `mu.unlock(io)`, so the note class was unsound.

ZC104 binds each `std.Thread.spawn` result name (`const t =`, `self.t =`; `child.spawn()` and `exe.spawn()` are process spawns and never match) and searches the whole file for `<name>.join(`/`.detach(` — including the `.?.join()` optional-unwrap form — plus ownership transfers (returned, passed as a call argument, stored into a container or field). Field-bound handles (`context.thread = ...`) are also searched by their last segment, following the alias-copy idiom (`const thread = self.thread; defer thread.join();`) and the dotted-receiver join (`self.thread.join()` in the witness deinit, EPH-I0904) — the fallback admits a preceding `.` on the segment search only, never on the exact-name search, so `event.t.join(` still fails to satisfy a local `t`. Shapes textual search cannot follow — bare spawn statements, `_ =` discards, `ptr.* =` stores — are left silent rather than guessed at. An alias of the spawn call itself (`const spawn = std.Thread.spawn; spawn(...)`) is invisible — the call-target match is textual. The last-segment fallback over-suppresses by design: any join/detach on a same-named segment satisfies it, so an unrelated local (`thread.join()` on a different handle) can mask a real leak — the FN-safe direction.

### Runtime Analysis (ZR1xx)

| Rule | Severity | Description |
|------|----------|-------------|
| **ZR101** | error | Memory leak detected at runtime |
| **ZR102** | error | Double-free detected at runtime |
| **ZR103** | error | Use-after-free detected at runtime |
| **ZR104** | error | Test failed or command could not run |
| **ZR105** | error | Panic detected during test execution |
| **ZR106** | error | Command terminated by signal |

### Enabling/Disabling Rules

```bash
# Disable rules (CLI)
ephor check --disable=ZA301
ephor check --disable=ZA3  # Disable all ZA3xx rules

# Enable rules (CLI) - overrides disable, enables off-by-default rules
ephor check --enable=ZA702

# Config file
{
  "disable": ["ZA301", "ZA302"],
  "enable": ["ZA702"]
}
```

**Priority**: `enable` takes precedence over `disable`. Use `enable` to:
- Override a disabled rule
- Turn on off-by-default rules (like ZA702)

### Inline Ignores

Suppress warnings with `// ephor:ignore` at three levels:

**Same line** — suppresses just that line:
```zig
const x = foo() catch {};  // ephor:ignore ZA201
```

**Above a function or block** — automatically suppresses the entire scope:
```zig
// ephor:ignore ZA201
fn legacy_handler() void {
    foo() catch {};   // suppressed
    bar() catch {};   // suppressed
}
// issues reported normally after the scope ends
```

**File level** — suppresses a rule for the entire file (place anywhere):
```zig
// ephor:ignore-file ZA201
```

Omit the rule to suppress all rules: `// ephor:ignore`

Aliases: `// ephor:ignore-next-line` is an alias of `ephor:ignore` in all
forms. The legacy spellings `// ephor:disable` and
`// ephor:disable-next-line` alias `ephor:ignore` the same way.

Directives are anchored: the keyword must be the first token of a plain `//`
comment — keywords mentioned inside prose or in `///` and `//!` doc comments
are ignored. Directives match rule ids exactly: `ZA3` does not suppress
`ZA301`. The config `disable`/`enable` lists accept category prefixes.
Directives do not. A directive is a surgical, in-code decision. A config
list is run-wide policy. List multiple rules separated by whitespace, e.g.
`// ephor:ignore ZA201 ZA305`. The rule list ends at the first non-rule word,
so trailing prose is fine, but a rule id following other words is not part
of the list. Rule ids must be whole tokens: `ZA201,` (trailing comma) is not
a rule id and ends the list — comma-joined lists do not work, use
space-separated ids.

### Suppression Accounting

Suppression is never silent. When an inline directive, the known-issues
list, a config `disable`, a config `exclude`, or a config `orphan_exclude`
hides a finding, ephor prints one note to stderr before the status line:

```
note: 3 findings suppressed (2 inline, 1 config disable)
```

The note omits zero-count channels. A finding hidden by two channels counts
once, under the most specific channel: inline directive, known-issues,
config disable, orphan exclude, config exclude (in that order). Findings
outside the scanned path are scope, not suppression. Rules that ephor
ships OFF by default (for example ZA305) are ephor's own posture, not
suppression. Neither one counts. The built-in orphan exclusions
(`_test.zig`, `build.zig`, the directory patterns) are the same posture —
only a config `orphan_exclude` match counts.

`--format=json` adds a `"suppressed"` object for machine consumers. With
`--summary`, ephor embeds it in the summary object. Without `--summary`,
ephor prints it as a trailing top-level object:

```json
"suppressed": {"inline": 2, "known_issues": 0, "config_disable": 1, "config_exclude": 0, "orphan_exclude": 0, "total": 3}
```

`--export` appends the same note to the markdown export as a final
"Suppression accounting" section.

**Audit mode** — `--no-suppression` stops inline directives and the
known-issues list from hiding findings. The findings print as if
unsuppressed, and the note counts what would have been hidden. Config
`disable`, `exclude`, and `orphan_exclude` still apply — they are your own
explicit config.
Use it in CI to audit a repo you do not trust.

A `.ephor-ignore` file in the scanned path auto-loads as the known-issues
list. The auto-load honors the same trust decision as `ephor.json`: Ephor
refuses an untrusted file with a skip note. The load discloses itself once:

```
note: loaded 2 known-issue entries from repo/.ephor-ignore
```

An explicit `--known-issues=<file>` stays silent — you asked for it.

## CLI Reference

Full command reference for the standalone `ephor` binary:

```
ephor [command] [path] [options]

Commands:
  check       Run all static checks (default)
  runtime     Run tests with memory diagnostics (dynamic analysis)
  orphans     Files not imported from entry points
  memory      Stdlib allocation without defer patterns (21 patterns: 18 method + 3 qualified)
  errors      Error handling patterns (ZA201-ZA210)
  unused      Unused imports/params/declarations
  complexity  Function complexity metrics
  fmt-check   Files needing zig fmt
  stats       Project statistics
  upgrade     Upgrade ephor to latest version (alias: update)
  install     Add ephor to project's build.zig (version-pinned)
  init        Create ephor.json config file
  help        Print the usage text (aliases: --help, -h)
  version     Print the version banner (aliases: --version, -v)

Options:
  --entry=<file>       Entry point (default: src/main.zig)
  --format=text|json   Output format (default: text; aliases: -f=text, -f=json)
  --disable=<rule>     Disable rule (e.g., ZA301, ZA3 for all ZA3xx)
  --enable=<rule>      Enable rule (overrides disable)
  --max-lines=N        Max function lines (default: 50)
  --max-nesting=N      Max nesting depth (default: 3)
  --max-params=N       Max parameters (default: 4)
  --max-branches=N     Max branches per function (default: 12)
  --max-line-length=N  Max characters per line (default: 100)
  --max-file-bytes=N   Max file size in bytes (requires --enable=ZA702)
  -y, --yes            Skip interactive confirmation (e.g., runtime approval)
  --version=<X.Y.Z>   For install/upgrade: pin a specific version
  --force             For upgrade: allow a downgrade below the running
                      binary's version (refused by default)
  --command=<cmd>      For runtime: custom command instead of 'zig build test'
  -V, --verbose        Verbose output
  -s, --summary        Show summary at end (off by default)
  --strict             Exit 1 when any warning/error is found (CI gate)
  --fail-on=<level>    Exit 1 on findings at level: error, warning,
                       note, never (warning == --strict; overrides config)
  --trust-target-config  Honor every key from a scanned target's
                       ephor.json and its .ephor-ignore auto-load.
                       Without it, a config outside the working
                       directory and its ancestors sets only
                       "entries". The rest is ignored with a note.
  --include-parent    Include the scan path's parent directory in
                      the build-reference search (the parent
                      build.zig and the parent module-directory
                      root). Off by default for a parent outside
                      the working directory. The reachability marks
                      still stay inside the scan root.
  --no-suppression     Audit mode: inline directives and the
                       known-issues list no longer hide findings.
                       The findings print, and the suppression note
                       counts what would have been hidden. Config
                       disable/exclude still apply.
  --                  Stop flag parsing: the rest of the arguments
                      are scan paths (use for a path that starts
                      with '-')
  -b, --build          With 'init': also show build.zig integration
  --export=<file>      Export issues to file with code snippets
  --known-issues=<file> Filter out known true positives (file:line format)
```

The `--known-issues` file lists known true positives to filter out — one issue
per line in `file:line` format; lines starting with `#` are comments:

```
# One issue per line, format: file:line
# Lines starting with # are comments
src/main.zig:123
src/util.zig:456
```

When `--known-issues` is absent, ephor auto-loads `<path>/.ephor-ignore` in
the same format and prints one note with the entry count. The auto-load
requires a trusted path (see [Config trust model](#config-trust-model)). See
[Suppression Accounting](#suppression-accounting).

## IDE Integration

### IntelliJ IDEA / CLion

#### Method 1: External Tool (Manual Trigger)

Use this to run Ephor on demand via menu or keyboard shortcut.

**Step 1: Add External Tool**

1. Open **Settings** (⌘, on macOS, Ctrl+Alt+S on Windows/Linux)
2. Navigate to **Tools** → **External Tools**
3. Click the **+** button to add a new tool

**Step 2: Configure the Tool**

| Field | Value |
|-------|-------|
| **Name** | `Ephor` |
| **Group** | `Zig Tools` (or leave default) |
| **Description** | `Run static analysis on Zig files` |
| **Program** | `/usr/local/bin/ephor` (or your install path) |
| **Arguments** | `check $FileDir$` |
| **Working directory** | `$ProjectFileDir$` |

> **Arguments variations:**
> - `check $FilePath$` - Lint current file only
> - `check $FileDir$` - Lint current file's directory
> - `check src/` - Lint specific directory
> - `check --summary` - Show summary at end

**Step 3: Add Output Filter (Clickable Errors)**

1. In the External Tool dialog, click **Output Filters...**
2. Click **+** to add a filter
3. Configure:
   - **Name**: `Ephor output`
   - **Regular expression**: `$FILE_PATH$:$LINE$:$COLUMN$:.*`

This makes file paths in the output clickable - click to jump to the error location.

**Step 4: Add Keyboard Shortcut (Optional)**

1. Go to **Settings** → **Keymap**
2. Search for `Ephor` (under External Tools)
3. Right-click → **Add Keyboard Shortcut**
4. Suggested: `Ctrl+Shift+L` or `⌘+Shift+L`

**Usage:**
- **Menu**: Tools → External Tools → Ephor
- **Keyboard**: Your configured shortcut
- **Right-click**: Right-click in editor → External Tools → Ephor

---

#### Method 2: File Watcher (Auto-Run on Save)

Use this to automatically run Ephor whenever you save a `.zig` file.

**Prerequisites:**
- Install the **File Watchers** plugin (built-in or via Settings → Plugins)

**Step 1: Open File Watchers Settings**

1. Go to **Settings** → **Tools** → **File Watchers**
2. Click **+** to add a new watcher
3. Select **\<custom\>** template

**Step 2: Configure the File Watcher**

| Field | Value |
|-------|-------|
| **Name** | `Ephor` |
| **File type** | `Zig` (or `Any` if Zig is not listed) |
| **Scope** | `Project Files` |
| **Program** | `/usr/local/bin/ephor` |
| **Arguments** | `check $FilePath$` |
| **Output paths to refresh** | `$FilePath$` |
| **Working directory** | `$ProjectFileDir$` |

**Step 3: Advanced Options**

In the **Advanced Options** section:

| Option | Recommended |
|--------|-------------|
| **Auto-save edited files** | ☑ Enabled |
| **Trigger on external changes** | ☐ Disabled |
| **Trigger only on edit** | ☑ Enabled |
| **Show console** | `On error` or `Always` |
| **Output filters** | `$FILE_PATH$:$LINE$:$COLUMN$:.*` |

**Step 4: File Type Configuration (if Zig not recognized)**

If IntelliJ does not recognize `.zig` files:

1. Go to **Settings** → **Editor** → **File Types**
2. Click **+** to add a new file type, or find an existing one to modify
3. Add `*.zig` to the registered patterns
4. Or use **File type**: `Any` in the File Watcher and set **File name pattern**: `*.zig`

**How it works:**
- Every time you save a `.zig` file, Ephor runs on that file
- Errors appear in the **Run** tool window
- Click error lines to jump to the source location
- Summary is off by default for clean IDE output (add `--summary` if you want it)

> **Tip**: Use `$FilePath$` for fast single-file linting on save. Use `$FileDir$` if you want to lint the whole directory (slower but catches cross-file issues like orphans).

---

#### Troubleshooting IntelliJ Integration

**Problem: "Program not found"**
- Verify the path: `which ephor` in terminal
- Use absolute path in Program field
- Ensure file has execute permissions: `chmod +x /path/to/ephor`

**Problem: Output not clickable**
- Verify the Output Filter regex: `$FILE_PATH$:$LINE$:$COLUMN$:.*`
- Make sure filter is enabled (checkbox)

**Problem: File Watcher not triggering**
- Check File Watcher is enabled (checkbox in list)
- Verify File type matches (try `Any` with pattern `*.zig`)
- Check Scope includes your files

**Problem: Working directory issues**
- Use `$ProjectFileDir$` for project-relative paths
- Ensure `ephor.json` is in project root

---

### VS Code

The output format is compatible with VS Code's problem matcher. Add to `.vscode/tasks.json`:

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "ephor",
      "type": "shell",
      "command": "ephor",
      "args": ["check", "${workspaceFolder}/src"],
      "problemMatcher": {
        "owner": "ephor",
        "fileLocation": ["relative", "${workspaceFolder}"],
        "pattern": {
          "regexp": "^(.+):(\\d+):(\\d+): (\\w+)\\[(.+)\\]: (.+)$",
          "file": 1,
          "line": 2,
          "column": 3,
          "severity": 4,
          "code": 5,
          "message": 6
        }
      },
      "presentation": {
        "reveal": "silent",
        "panel": "shared"
      }
    }
  ]
}
```

**Run on Save (VS Code):**

Install the **Run on Save** extension, then add to `.vscode/settings.json`:

```json
{
  "emeraldwalk.runonsave": {
    "commands": [
      {
        "match": "\\.zig$",
        "cmd": "ephor check ${fileDirname}"
      }
    ]
  }
}
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Analysis completed; no findings at the configured fail-on level |
| 1 | Usage error (no entry points, bad arguments, init/install failures), findings met the `--strict`/`--fail-on` level, a declined runtime prompt, or a runtime run that could not start |

Findings are informational by default: `ephor check` exits 0 whether or not issues are found. For CI gating, opt into strict mode:

| Flag | Config key | Exit 1 when |
|------|-----------|-------------|
| `--strict` | `"strict": true` | any warning or error is found (notes never fail) |
| `--fail-on=error` | `"fail_on": "error"` | any error-severity finding |
| `--fail-on=warning` | `"fail_on": "warning"` | any warning or error (same as `--strict`) |
| `--fail-on=note` | `"fail_on": "note"` | any finding, notes included |
| `--fail-on=never` | `"fail_on": "never"` | never — lets the CLI override a strict config off |

CLI flags override `ephor.json` — including a target-directory `ephor.json` loaded for the analyzed path. Inside one config file, `fail_on` is more specific than `strict` and wins regardless of key order. An invalid fail-on value — in the CLI flag or in any `ephor.json` — is a usage error (exit 1): a misspelled CI gate must never fail open. When the gate trips, the footer says so, e.g. `ephor: strict mode: failing with 12 warnings (exit 1)`. A declined runtime prompt exits 1 by design: the analysis did not run, so a CI pipeline without `--yes` fails instead of passing silently (see [Run dynamic analysis](#run-dynamic-analysis)). A runtime run that could not start — a spawn failure, a capture overflow, or a missing target directory — also exits 1, regardless of `fail_on`: the analysis never ran, so a CI gate must not pass on it.

## Examples

### Check a project

```bash
$ ephor check
src/main.zig:506:25: warning[ZA201]: silent catch {} discards error without handling
  help: use 'catch |err| { log.err(...); return err; }' or propagate with 'try'

ephor summary

Files: 156 | Code: 66884 lines
AST tier: 148 parsed, 8 skipped

Issues:
  Orphans:    155
  Memory:     102
  Errors:     89
  Unused:     4
  Complexity: 404
  Format:     0
  Style:      0
  NullSafety: 0
  Panic:      0
  Tests:      0
  Concurrency: 0
  Notes:      0
  TOTAL:      754

Quality: NotImplemented=497 TODO/FIXME=268

STATUS: ISSUES FOUND
```

### Get project stats

```bash
$ ephor stats
ephor stats

Files:          156
Total Lines:    104550
  Code:         66884
  Comments:     20959
  Blank:        16707

Public funcs:   2274
Tests:          972
Files w/tests:  140 (89%)

NotImplemented: 497
TODO/FIXME:     268
```

The stats scanner matches TODO and FIXME markers as raw bytes. A marker
spelled through comptime string concatenation (`"TO" ++ "DO"`) renders
at compile time and does not count (EPH-I0538, EPH-I1053). `ephor check
--summary` counts the scan path plus the joined entry points
(EPH-I0784, EPH-I0541); `ephor stats` counts the scan path alone.

### Run dynamic analysis

```bash
$ ephor runtime

WARNING: Runtime analysis will COMPILE AND EXECUTE code in:
  .

Command: zig build test

This runs untrusted code with your user privileges.
Only run this on projects you trust.

Proceed? [y/N] y
Running: zig build test (with GPA diagnostics)
src/memory.zig:45:1: error[ZR101]: memory leak detected at runtime
  help: allocation not freed - check for missing defer or error path
```

Runtime compiles and executes the target, so the interactive confirmation
prints before anything runs. Pass `-y` (`--yes`) to skip it in CI. A
declined prompt (an answer other than `y`, or EOF on a non-interactive
stdin) prints `Aborted.` and exits 1, so a CI run without `--yes` fails
instead of passing silently.

## Compatibility

**Supported Zig Versions:**
- Zig 0.16.x (current) — **required minimum**

Ephor v0.12.3+ requires Zig 0.16.0 or later. Earlier ephor versions (v0.11.x) support Zig 0.15.x.

### Version Compatibility System

Ephor uses a modular compatibility layer to support Zig 0.16.x API patterns. The system is designed for easy extension as new Zig versions are released:

```
src/compat/
├── compat.zig     # Main module: version detection, table dispatch, getters
├── v0_15.zig      # Zig 0.15.x pattern and predicate tables
└── v0_16.zig      # Zig 0.16.x pattern and predicate tables
```

**Adding support for a new Zig version:**

1. Create the module `src/compat/vX_YZ.zig` (e.g., `v0_17.zig`).
2. Implement the pattern tables and the pattern-checking helpers.
3. Add the import, a `Tables` constant, and a `knownTablesFor` switch arm in `compat.zig`.
4. Bump `newest_supported_minor` so the fallback clamps to the new tables.

Each version module exports the same pattern tables and pattern-checking helpers for its Zig version.

## Technical: How Detection Works

This section documents the internal detection architecture. Understanding these internals helps identify gaps and validate correctness.

### Architecture Overview

Ephor has five analysis entry points:

| Entry Point | Scope | Rules | Context |
|-------------|-------|-------|---------|
| `analyzeFileErrors` | Full file, line-by-line | ZA201-ZA208, ZA210 (in `checkLineErrors`), ZA209 (whole-body scan) | `TypeContext` via `parseFileTypeContext(content)` |
| `analyzeIgnoredErrorsInFile` | Full file, line-by-line | ZA205 (in `checkIgnoredError`) | `TypeContext` via `parseFileTypeContext(content)` |
| `analyzeCFGFile` | Full file, per-function CFG | ZA101-ZA106, ZA110, ZA607, ZA8xx, ZA901/ZA903 (ZA904 runs standalone) | `CFGState` with file-level `no_free_fields` |
| `analyzeAstTier` | Project import graph, per-file AST | ZA111, ZA503 | `std.Ast` parse per file (`src/ast_tier.zig`); files with parse errors are skipped for ZA111 and reported as ZA503 (EPH-I0742) |
| `analyzeClones` | Project import graph, normalized-line stream per file | ZA504 | Windowed hash matching over comment-stripped, trimmed lines; test bodies, multiline-string content, versioned-compat mirror pairs (EPH-I1076), and cross-root same-name whole-type stand-in mirrors (EPH-I1295) excluded |

Error analysis (`analyzeFileErrors`, `analyzeIgnoredErrorsInFile`) uses `TypeContext` for type-aware method return resolution. Memory analysis (`analyzeCFGFile`) uses CFG-based control flow analysis with type-based allocator suppression. ZA103 is the one exception: its errdefer verdict uses a line-interval model, not the CFG (see the Memory Analysis Path section).

### TypeContext: The Core Data Structure

```
TypeContext = {
    struct_methods:   Map<TypeName, Map<MethodName, ReturnKind>>
    function_returns: Map<FunctionName, ReturnKind>
    var_types:        Map<VariableName, TypeName>
    stdlib_vars:      Map<VariableName, void>
}
```

| Field | Purpose | Example |
|-------|---------|---------|
| `struct_methods` | Maps type names to their method return types | `"MyLogger" -> {"clear" -> void_type, "flush" -> error_union}` |
| `function_returns` | Maps top-level function names to return types | `"helper" -> void_type, "riskyOp" -> error_union` |
| `var_types` | Maps variable names to their declared type | `"logger" -> "MyLogger", "state" -> "State"` |
| `stdlib_vars` | Tracks variables initialized from stdlib containers/allocators | `"list" -> void, "map" -> void` |

### ReturnKind Classification

The `classifyReturnType` function converts return type text to an enum:

| Return Type Text | ReturnKind | Safe to Discard? |
|-----------------|------------|------------------|
| `void` | `.void_type` | Yes |
| `noreturn` | `.noreturn_type` | Yes |
| `!void`, `!T`, `ErrorSet!T` | `.error_union` | **No** (ZA205) |
| `?T`, `?*T` | `.optional` | Yes |
| `u32`, `[]u8`, `*T`, etc. | `.value` | Yes |
| (empty/unparseable) | `.unknown` | Falls through to vocab |

### Type Parsing: What Gets Registered

`parseFileTypeContext` scans the file line-by-line and builds TypeContext:

**1. Type definitions** (struct, enum, union — all can have methods in Zig):

```zig
const MyStruct = struct { ... };       // Tracked
const State = enum { ... };            // Tracked
const Result = union(enum) { ... };    // Tracked
const Flags = packed struct { ... };   // Tracked
const CHandle = extern struct { ... }; // Tracked
```

Detection pattern: `= struct {`, `= enum {`, `= enum(`, `= union(`, `= union {`, `= packed struct {`, `= extern struct {`, `= packed union {`, `= extern union {`

**2. Method signatures** (inside a type scope):

```zig
pub fn method(self: *MyStruct) void { ... }       // struct_methods["MyStruct"]["method"] = .void_type
pub fn method(self: *MyStruct) !void { ... }       // struct_methods["MyStruct"]["method"] = .error_union
pub fn method(self: MyEnum) u32 { ... }            // struct_methods["MyEnum"]["method"] = .value
fn method(self: *const MyStruct, arg: u32) ?T { }  // struct_methods["MyStruct"]["method"] = .optional
```

Self parameter extraction: strips `*` and `*const` prefixes to get bare type name.

**3. Variable declarations**:

```zig
var x: MyStruct = .{};                // var_types["x"] = "MyStruct" (explicit annotation)
var x = MyStruct.init(allocator);     // var_types["x"] = "MyStruct" (RHS inference: TypeName.init)
var x = MyStruct{};                   // var_types["x"] = "MyStruct" (RHS inference: TypeName{})
var x = MyStruct{ .field = 5 };       // var_types["x"] = "MyStruct" (RHS inference: TypeName{ .field)
```

RHS inference requires the type name to start with uppercase (PascalCase).

**4. Stdlib variable tracking** (for vocab fallback):

```zig
var list = std.ArrayList(u32).init(allocator);     // stdlib_vars["list"] = void
var map = std.StringHashMap(u32).init(allocator);  // stdlib_vars["map"] = void
var arena = std.heap.ArenaAllocator.init(...);     // stdlib_vars["arena"] = void
```

Matched via `compat.getStdlibContainerInitPatterns()` and `compat.getAllInitPatterns()`.

**5. Top-level functions** (outside any type scope):

```zig
fn helper() void { }          // function_returns["helper"] = .void_type
fn riskyOp() !void { }        // function_returns["riskyOp"] = .error_union
pub fn getValue() u32 { }     // function_returns["getValue"] = .value
```

### Resolution Chain

When ephor encounters `_ = expr`, it resolves whether the discard is safe through a tiered chain. Different detection functions use slightly different tiers, but the core pattern is:

**Tier 1 — Cleanup patterns (always safe):**
Hardcoded patterns like `.free(`, `.destroy(`, `.deinit(` — these are void by Zig convention and always safe to discard.

**Tier 2 — TypeContext resolution (definitive when available):**

For `_ = receiver.method(...)`:
1. Look up `receiver` in `var_types` → get type name (e.g., `"MyLogger"`)
2. Look up type name in `struct_methods` → get method map
3. Look up method name in method map → get `ReturnKind`

For `_ = funcName(...)`:
1. Extract function name (must be simple identifier, no dots)
2. Look up in `function_returns` → get `ReturnKind`

Decision:
- `.void_type`, `.value`, `.optional`, `.noreturn_type` → **safe** (suppress)
- `.error_union` → **not safe** (report ZA205)
- `.unknown` → fall through to next tier

**Tier 3 — Stdlib vocab (trusted for known containers):**
If the receiver variable is tracked in `stdlib_vars`, check against vocabulary patterns from the compat layer (`getSafeMethodPatterns()`). Method patterns (starting with `.`) only match when the receiver is a confirmed stdlib type.

**Tier 4 — Legacy patterns (backwards compat):**
Substring matching for non-stdlib patterns (C FFI uppercase functions, parser internals). Universal patterns (not starting with `.`) always match regardless of receiver type.

**Tier 5 — Unknown → report:**
If no tier resolved the call, the discard is reported (conservative: better to flag than miss).

### Detection Functions and Their Tiers

| Function | Used By | Tiers Used |
|----------|---------|------------|
| `isSafeToDiscard` | `checkIgnoredError` (ZA205 in `analyzeIgnoredErrorsInFile`) | 1→2→3→4 |
| `isSafeBuiltin` | `checkIgnoredError` (ZA205 in `analyzeIgnoredErrorsInFile`) | builtins→2→3→fields→optionals |
| `checkMethodTransfer` | `processAllocTracking` (ZA101-106 memory) | stdlib_vars only (no Tier 2) |

### Memory Analysis Path (ZA101-ZA106)

Memory analysis runs three specialized analyzers. ZA101, ZA102, ZA105, and ZA106 use the CFG-based approach. ZA103 is a line-interval model, not CFG-based: the alloc line, the trigger lines (later `try` or error return), and the errdefer line sit between them at the alloc's indent or deeper, and the CFG contributes nothing to the verdict. The function name keeps the historical `analyzeCFG*` prefix (EPH-I0682, design-cfg-soundness F15).

| Analyzer | Rules | Purpose |
|----------|-------|---------|
| `analyzeCFGDeferCoverage` | ZA101, ZA102 | Allocation without matching `defer free()`/`defer destroy()` |
| `analyzeCFGErrdeferCoverage` | ZA103 | Allocation without `errdefer` before a later `try` or error return (line-interval model, not CFG) |
| `analyzeCFGMemorySafety` | ZA105, ZA106 | Use-after-free, double-free |

**Analysis pipeline per file** (`analyzeCFGFile`):

1. **File-level setup**: Compute `no_free_fields` by scanning struct field declarations for no-free allocator types (e.g., `arena: std.heap.ArenaAllocator`)
2. **Function extraction**: Split file into individual functions
3. **Per-function analysis** (`processFunction`): Run `runCFGMemoryAnalyses` (ZA101-ZA106), `runCFGSafetyAnalyses` (ZA8xx, ZA901/ZA903 — ZA904 runs standalone), and `runDefiniteAssignmentAnalysis`

**No-free allocator suppression** — allocations that do not need per-allocation free:

| Detection Method | What It Catches | Example |
|-----------------|-----------------|---------|
| Local variable init | Variables initialized with `ArenaAllocator.init(...)` | `var arena = std.heap.ArenaAllocator.init(...)` |
| `.allocator()` call chain | Allocations via `.allocator()` on tracked no-free variables | `arena.allocator().alloc(u8, 100)` |
| Struct field type (file-level) | Fields declared as no-free allocator types in struct definitions | `arena: std.heap.ArenaAllocator` |
| Field access chain | Allocations through struct fields of no-free types | `self.arena.allocator().alloc(u8, 100)` |
| Data flow tracking | No-free allocator types propagated through assignments | `const alloc = arena.allocator();` |

**IMPORTANT**: All suppression is **type-based, not name-based**. Ephor tracks `std.heap.ArenaAllocator`, `std.heap.FixedBufferAllocator`, and `std.heap.StackFallbackAllocator` via stdlib type patterns. Variable/field names like "arena" or "fba" are never used for detection — only the declared type matters.

**Alias tracking for ZA105** (use-after-free):

The UAF detector tracks variable aliases — `const alias = data;` where `data` is a tracked allocation. If `data` is freed and `alias` is used afterwards, ZA105 fires on the alias usage.

**Ownership transfer detection**:

Allocations transferred to stdlib containers (e.g., `list.append(ptr)`) or returned from the function (`return ptr`) are suppressed. The `checkMethodTransfer` function uses `type_ctx.stdlib_vars` to identify stdlib container ownership methods.

### Known Limitations

The line-based analyzers mask string, char, `//` comment, and multiline-string content when they scan for braces, parens, and trigger patterns. This masking includes mid-line `\\` opener tails. Multi-line signatures resolve through a param lookahead, and split-RHS alloc declarations join into one logical line before the analysis. A `.?` inside a string or a trailing comment is prose, never an unwrap. The table below lists the residual shapes the design-line-model audit identified. Each row carries its tracker issue ID.

#### Line-Based Analysis — Residual Blind Spots

| Residual | Family | Effect | Tracker |
|----------|--------|--------|---------|
| ZA903 misses RHS operands that are `@`-builtins, string literals, or unary negatives | ZA9xx | False negative | EPH-I0016 |
| Test-block tracking is string-literal blind on shared ZA2xx/ZA3xx paths | ZA2xx/ZA3xx | Test-context misclassification | EPH-I0025 |
| ZA701 exempts string-literal tails from the column count | ZA6xx | False negative | EPH-I0267 |
| `@import` missed when the string opens on the next line | ZA5xx | Import-graph false negative | EPH-I0300 |
| fn-naming check stops at the first match and masks a real fn later on the line | ZA7xx | False negative | EPH-I0302 |
| Files over the 256 KiB AST cap lose ZA111 coverage | AST tier | False negative | EPH-I0293 |

The 256 KiB AST-tier cap is an accepted residual (EPH-I0293, re-derived in EPH-I1300). It is a parser-stack safety guarantee: at the module's worst verified density (ten parser frames per byte pair) the 2 GiB parse-thread stack covers 256 KiB of source, and ephor's own `src/main.zig` sits far past the cap (5.2 MiB on the 0.15.2 line), so covering it would need a ~42 GiB stack under the same linear scaling. Chunking a whole-file grammar is out of scope. The per-run skip note is the designed visibility for the residual (EPH-I0200).

#### What Is NOT Parsed

| Pattern | Why | Fallback |
|---------|-----|----------|
| Cross-file type resolution | Types defined in imported files | Falls through to `.unknown` → vocab |
| Generic type parameters | `ArrayList(u8)` stored as full text, lookup mismatch | Falls through to `.unknown` → vocab |
| Type aliases | `const MyList = ArrayList;` not tracked | Falls through to `.unknown` → vocab |
| Variable reassignment | `x = NewType.init()` does not update type | Uses original declaration type |
| Method chaining | `a.b().c()` — only sees last receiver | May resolve wrong receiver |
| Nested function definitions | Functions inside functions | Registered as top-level |
| Comptime-generated types | Types from `comptime` blocks | Falls through to `.unknown` → vocab |
| Pointer chain stripping | `**MyStruct` keeps one `*` | May cause lookup mismatch |

All limitations fall through to `.unknown`, which triggers vocab-based detection (Tier 3/4) — the worst case is falling back to the same behavior as before TypeContext existed. This fallback limits but does **not** eliminate false negatives: ephor handles common multi-line signatures and allocations, but line-based analysis retains documented blind spots (some multi-line signature/extraction edge cases are still missed; these are tracked in the project issue tracker).

#### Known False Positive Patterns

| Pattern | Rule | Root Cause | Status |
|---------|------|------------|--------|
| Arena allocator via `std.mem.Allocator` interface | ZA101/ZA103 | Type erasure — arena loses no-free semantics when passed as generic `Allocator` | Open (by design: type-based detection cannot resolve erased types) |
| Write between the zero-check guard and the candidate | ZA901/ZA903 | The defeat scan treats any write as defeating the proof, even one that cannot introduce zero (`m += 5`, `while (m > 3) m -= 1;` before the decrement) | Open (by design: judging those writes needs per-write-site guard reachability the line walk cannot carry) |

Note: Arena allocations through **struct field chains** (e.g., `self.arena.allocator().alloc(...)`) are correctly suppressed when the field is declared with a no-free allocator type like `std.heap.ArenaAllocator`. Only type-erased fields (declared as `std.mem.Allocator`) remain as known false positives.

These patterns are validated against the community project corpus (3000+ projects, top 100 by size audited with zero false positives).

### Vocabulary System (Compat Layer)

The compat layer (`src/compat/`) provides version-specific pattern vocabularies:

| Vocabulary | Purpose | Example Patterns |
|-----------|---------|-----------------|
| `getCleanupPatterns()` | Methods that are always void | `.free(`, `.destroy(`, `.deinit(` |
| `getSafeMethodPatterns()` | Stdlib methods safe to discard | `.clear(`, `.next(`, `.pop(` |
| `getContainerOwnershipMethods()` | Methods that transfer allocation ownership | `.append(`, `.put(`, `.insert(` |
| `getStdlibContainerInitPatterns()` | Init patterns for stdlib containers | `ArrayList(`, `StringHashMap(` |
| `getAllInitPatterns()` | Init patterns for all stdlib types including allocators | `ArenaAllocator.init(`, `FixedBufferAllocator.init(` |
| `getNoFreeFieldTypePatterns()` | Struct field types that are no-free allocators | `std.heap.ArenaAllocator`, `std.heap.FixedBufferAllocator` |

Vocabularies are defined per Zig version (`v0_15.zig`, `v0_16.zig`) and selected at build time via `compat.zig`.

### Testing Strategy

Ephor uses three testing layers:

**1. Unit tests** (in `src/main.zig`): Test individual parsing and classification functions:
- `classifyReturnType`, `extractFnReturnType`, `extractSelfTypeName`, `extractFnName`, `extractVarTypeName`
- `extractMethodCall`, `resolveReturnKind`
- `parseFileTypeContext` (struct, enum, union, packed/extern, top-level functions)

**2. Integration tests** (in `src/main.zig`): Test full detection pipeline using `createTestFileAnalysis` + `ImportGraph`:
- User-defined struct/enum/union void methods → NOT flagged
- User-defined error-returning methods → flagged
- Stdlib methods via vocab fallback → NOT flagged
- Vocab override (user `.clear()` returning `!void` → flagged despite vocab)
- Mixed types in same file resolved independently
- Unknown receiver falls through to legacy

**3. Fixture files** (in `fixtures/`):
- `bad_code_patterns.zig` — Code that MUST be flagged (true positives)
- `good_code_patterns_false_positive.zig` — Code that MUST NOT be flagged (false positive regression tests)
- `naming_conventions.zig` — Naming rule test patterns
- `fixtures/memory/tp_*.zig` — True positive memory fixtures (ZA101-ZA106)
- `fixtures/memory/fp_*.zig` — False positive memory fixtures (arena field chains, ownership transfer, deferred alloc)
- `examples/error_handling_demo.zig` — Error handling patterns (ZA201-ZA210)

**4. Corpus validation** (3000+ community Zig projects):
- Dogfood: `ephor check src/` → zero warnings, zero notes
- Community baseline regression testing against key projects

## Changelog

### v0.15.3 — ZA607 Same-Line Opener, Min-Derived FOR Bound, Else-Arm Rejection (2026-09-01)

**Fixed:**

- ZA607 admits the same-line loop opener: the enclosing-loop walk checks
  the opener on the read line itself, with three fail-closed boundary
  guards (header, braced, and braceless). The nine RhyOS sites named in
  the issue go silent, and the I1299 fail-closed controls hold
  (EPH-I1312).
- ZA607 admits the min-derived for-range bound with the identical
  bound-var tracking as the while branch. The 16 RhyOS sites named in
  the issue go silent, and the fail-closed controls hold (EPH-I1313).
- The same-line admission rejects the arm when a depth-0 else keyword
  follows the body start (quote-aware, masked, on both branches). The
  else-arm read on the zero-trip path can no longer ride the body read's
  silence. Four pins: the three else shapes fire, and the braced
  positive stays silent (EPH-I1315).

**Deferred:**

- The ZA106 block-scoped-defer false-positive fix (EPH-I1310) stays in
  flight in another lane at release prep. It joins this release only if
  its fix lands and passes review before the release gate. Otherwise it
  ships in a later patch.

### v0.15.2 — ZA607 Expression Arms, 256 KiB AST Re-Entry, Stand-In Exclusions (2026-09-02)

**Fixed:**

- ZA607 extends its counter-bounded suppressor to the five
  expression-index reverse-copy forms: the i-1 read, the c-1-i while and
  for-range, min-derived and compound bounds. The read-loop increment now
  fires when the bound var differs from the counter (the min-derived
  shape), and the I0826 pin flips to the silent verdict. Failed checks
  stay in the fail-safe over-warn direction (EPH-I1299, EPH-I1311).
- ZA607 walks the conditional prefix of a braceless `if`/`while`, so an
  errdefer increment inside one credits the fill-then-read run instead of
  escaping the arm (EPH-I1305).
- ZA504 excludes same-root whole-type stand-in mirrors where one side is
  the else arm of a comptime-if/@import stand-in resolving to the
  witness's file, the RhyOS OpenFlags shape. The v0.15.1 residual goes
  silent with zero collateral (EPH-I1308).

**Re-admission:**

- The AST tier re-admits files up to 256 KiB with the parse stack raised
  to 2 GiB in the same step. The measured pair (REL-P2-VERIFY-3):
  ReleaseSafe frames 297.6-314.6 B and Debug frames 1,206.4-1,216.3 B
  under the ten-frame convention (Debug margin 1.35×), and the
  131,072-level grouped-type-paren probe parses the shipped stack in both
  build modes. The 78 re-admitted corpus files add zero findings and
  remove one before-side false positive (EPH-I1300).

**Deferred:**

- The ZA106 block-scoped-defer false-positive fix (EPH-I1310) is in
  flight in another lane at release prep. It joins this release only if
  its fix lands and passes review before the release gate; otherwise it
  ships in a later patch.

### v0.15.1 — AST-Tier Skip Signal, ZA607 Suppressor, Analyzer Arm Fixes (2026-09-01)

**Fixed (0.15.0 regressions):**

- The install-path fingerprint repair accepts both zig 0.16.0 hint
  shapes and adds the missing fingerprint field (the live-install
  defect the 0.15.0 release exposed) (EPH-I1291).
- The AST tier now names its skip class (size cap, nesting, parse,
  spawn) with the hardcoded 64 KiB cap documented as the stack-coupled
  bound. The 34 files over the AST-tier byte cap that 0.15.0 skipped
  silently now surface in a named per-class skip note (EPH-I1297).
- ZA607 gains a counter-bounded suppressor for the fill-then-read loop
  shape, the dominant class of the 0.15.0 ZA607 surge. Failed checks
  stay in the fail-safe over-warn direction (EPH-I1293).
- ZA703 skips the std canonical error names in declared error sets (the
  488-name comptime table from the pinned stdlib). Use sites stay
  governed (EPH-I1296).
- ZT106 excludes pure reference-discard compile-pin bodies, the pinned
  compile-check test shape (EPH-I1294).
- ZA504 excludes same-name whole-type stand-in mirrors across build
  roots. The arm's claims re-scope to cross-root whole-type mirrors
  only, with the same-root comptime-if pair documented as a residual
  (EPH-I1295).
- The run-span check reads `end_line` from the run's last covered stream
  line directly, and the whole-type opener accepts the optional
  parenthesized backing group. Gaps no longer break the exact-span check
  in either direction (EPH-I1306, EPH-I1307).

**Operations:**

- The smoke suite gains the sig fixture and joins the gate as leg 1g
  (EPH-I1292).
- The README gains the config-changes-by-version note. The error-naming
  flip ships in v0.15.0, not a phantom 0.14.4 (EPH-I1298).

### v0.15.0 — Directive Anchoring, ZA1xx Accuracy, Print-Path Cache (2026-08-31)

**New default-ON rules:**

- ZA404 unused private functions — a fn declared without `pub` that no
  code position references anywhere in the project. Test decls count as
  callers. C-ABI decls and `main` stay exempt (EPH-I1084).
- ZA405 unused parameters — a private fn declares a parameter its body
  never references. Pub fns, the `self` receiver, `_`-prefixed names,
  generic fns, and C-ABI decls stay exempt (EPH-I1080).
- ZA406 unnecessary var — a `var` never mutated in its body, so `const`
  suffices. Compound assignments, field and element stores, address-taken
  views, pointer captures, destructuring, and inline-asm operands count as
  mutations (EPH-I1085).
- ZA504 duplicated block — a run of six or more normalized lines that
  repeats within one file or across files, the copy-paste duplication
  detector (EPH-I1076).
- ZA505 passthrough wrapper — a body that is a single call statement whose
  argument list is exactly the parameter list in order (EPH-I1077).
- ZA506 boolean flag parameter — a `bool`-typed parameter whose name
  appears inside an `if`/`switch` condition, the selector that hides two
  functions in one signature (EPH-I1081).
- ZA507 redundant else (note) — an else whose if-branch ends in return,
  break, or continue. The guard-clause style removes the else and one
  nesting level (EPH-I1079).
- ZA508 simplifiable boolean return (note) — `if (x) return true else
  return false;` where `return x;` suffices (EPH-I1078).
- ZT106 invocationless test block (note) — a test block whose body carries
  no call site, so the runner counts it as passing while it covers no
  function body (EPH-I1089).

**Complexity:** the complexity defaults are unified at cyclomatic 10 and
cognitive 15 (EPH-I0992). ZA305 and ZA306 stay off by default. Enable them
in `ephor.json`.

**Signed releases (minisign):** the installers and the `ephor install` and
`ephor upgrade` commands verify the release signature before zig fetch
(EPH-I0287). They download the tarball and its signature and check the
pair against the embedded release public key. The tarball download caps at
32 MiB and the signature at 1 MiB, each with a 30 s timeout. On a signed
release the install or upgrade fails closed when the signature download
fails, when minisign is not installed, or when the check fails. The pinned
0.15-era commit archive skips the check: it is SHA-addressed and immutable
on the remote. Every tag URL verifies, because a tag is a mutable pointer.

**Changed (ZA703 default flip):** Error set members now default to
`TitleCase` (`error{ FileNotFound }`), matching the stdlib and virtually
all community code — the old `snake_case` default false-positived on
idiomatic Zig (Codeberg issue #1, EPH-I0092). Set `"error_naming":
"snake_case"` in `ephor.json` to keep the old behavior. `"PascalCase"` is
accepted as an alias for `TitleCase`. Unknown values warn and fall back to
the default.

**Changed (ZA703 fire surface):** ZA703 now fires on error-set member
declarations only. Use sites of an error value are never flagged — a used
error value cannot be restyled per site (EPH-I1075). The member scan stops
at the error-union boundary, so payload and plain return types are never
flagged as members (EPH-I0274).

**Changed (ZA303 exemption):** `extern`, `export`, and
`callconv(.c)`/`callconv(.C)`/`callconv(.Stdcall)` declarations are exempt
from parameter counting — a pinned ABI fixes the parameter list
(EPH-I1059, EPH-I1093, EPH-I1096).

**Changed (exclude matching):** The `exclude` config key now matches
component-wise, not by substring: pattern components (split on `/`) match
path components in order (a subsequence), and the final pattern component
also covers its dot-extended file form. `vendor` matches `src/vendor/` and
`src/vendor.zig` but never `src/vendored/` — the old substring form
silently applied a cwd config's exclude list to foreign-target code whose
paths merely contained a pattern (EPH-I0076, EPH-I1182). A dual-load note
now prints when the cwd config and a target-side config both load.

**Changed (migration required):** Inline-ignore directives are now anchored —
only plain `//` comments whose first token is `ephor:ignore`,
`ephor:ignore-next-line`, `ephor:disable`, `ephor:disable-next-line`, or
`ephor:ignore-file` are directives. Migration:

- `///` doc-comment directives → change to `//`
- comma-joined rule lists → space-separated (`ZA201,` ends the rule list)
- `ephor:ignore-next-line` works again as an alias of `ephor:ignore`
  (re-enabled in this release, EPH-I0250). No migration needed.
- rule ids in prose no longer count — previously hidden issues may surface
  (fail-closed)
- `//ephor:ignore` (no space) now works
- a trailing-space bare directive now suppresses (was inert)

**Removed:** ZA902 — its only emitter sat in the dead legacy panic-analyzer
cluster, so it never emitted. `disable`/`enable` entries naming ZA902
become inert no-ops.

**Added (new detections — genuine leaks, expect new warnings):**

- ZA103 on multi-line-signature error-returning fns — the return type on a
  later signature line no longer silently disables ZA103 (EPH-I0072) — and
  on error exits preceding an ownership transfer (EPH-I0005).
- ZA101/ZA103 coverage family: embedded returns, container handoff,
  realloc, block-span errdefer, and per-site no-free shapes (EPH-I0273,
  EPH-I066, EPH-I067, EPH-I070).
- ZT105 cross-file two-hop call graph — a test-target candidate can sit
  two hops from the test site (EPH-I0429, EPH-I0031).

**Fixed (false positives):** ZA103 return-transfers, ZA101/ZA103
orelse-return allocs (EPH-I0009), ZA101 allocator-first-arg shapes
(EPH-I0008), ZA102 `.prepend` ownership (EPH-I0007), ZA105
sibling-switch-arm UAF (EPH-I0010), ZA205 compound-annotation resolution
(EPH-I0057).

**Containment and disclosure:** symlink and open-failure prunes and
depth-cap truncations count into `pruned_dirs` in the summary output, so a
skipped subtree is visible in the JSON summary (EPH-I1261, EPH-I1267,
EPH-I1268). Hidden-dir skips carry a count note (EPH-I1260). The export
open and the snippet read go no-follow: a planted symlink fails the open
instead of redirecting the read. A symlinked scan root fails closed.

**Output sanitization:** the config-diagnostic channels (the
over-broad-exclude and threshold-clamp warnings), the AST-skip notes, the
list-tests text mode, the runtime prompt and banner, and the minisign
stderr sanitize hostile control and bidi/invisible characters before the
terminal (EPH-I1256, EPH-I1257, EPH-I1275, EPH-I1280-I1282).

**Redteam #3 hardening:** the run-3 findings (EPH-I1254-I1260) and the
re-derivation wave (EPH-I1264-I1282) fixed every filed finding across the
five attack areas: parser/input, supply chain, suppression, containment,
and output. Headlines: the cimport filename skip now needs a code-position
marker, so a filename-only substring no longer blinds six analyzer
families (EPH-I1254). The version fetchers check the curl exit status
(EPH-I1255). The 16 KiB statement-end mask fails closed: past the bound an
overhang scan counts code-position braces and semicolons with the same
string/comment masking (EPH-I1258, EPH-I1265). The installer hardening
suites joined the Layer-1 gate (EPH-I1285).

**Performance:** print path 16x on issue-bound projects (libqt6zig 50-60
min → 3:10) via a per-(file, rule) suppression cache (EPH-I0061).

**Operations:** the update check now honors the documented 24h cache
(`~/.ephor_update_check`). Set `EPHOR_NO_UPDATE_CHECK` (any value) to skip
it entirely (deterministic CI). See [Update Check](#update-check).

**Internal:** dead legacy panic-analyzer cluster removed (272 lines,
EPH-I0015, EPH-I0041). The dogfood ratchet holds at zero warnings and zero
notes, and the gate ships 2958 tests.

### v0.14.2 — Dogfood Complexity Debt Cleared (2026-07-27)

**Fixed:** Dogfood complexity debt cleared — `ephor check src/` 173 → 0 warnings (EPH-I0002). README accuracy pass.

### v0.14.1 — .gitignore Fix (2026-07-26)

**Fixed:** `.gitignore` patch.

### v0.14.0 — Test-Quality + Concurrency Bands, AST Tier (2026-07-26)

**Added:**
- ZT1xx test-quality band (ZT101-ZT105)
- ZC1xx concurrency band (ZC101-ZC104)
- AST analysis tier + ZA111 (returned-stack-ref)
- ZA110 (must-return-ref), ZA209/ZA210 (error-handling notes), ZA904 (intCast without bounds proof)
- Strict CI mode (`--strict` / `--fail-on`)

**Removed:** ZA704 (`std.debug.print` left in non-test code) — intent-based, cannot be grounded in objective detection (EPH-I0049). The ID is retired and will never be reused.

### v0.12.3 — Error Naming Enforcement (ZA703)

**Added:** ZA703 now enforces `snake_case` for error values and error set members.

- Error values: `error.file_not_found` (was silently allowed as `error.FileNotFound`)
- Error set members: `error{ file_not_found }` (was silently allowed as `error{ FileNotFound }`)
- Error set type aliases (the `const` binding) remain `TitleCase` since they are types

Per the [Zig Style Guide](https://ziglang.org/documentation/master/#Names): "Otherwise, x should be snake_case." Error values are values, not types, so they fall under the "Otherwise" rule. The std lib's `PascalCase` errors are grandfathered, not normative.

**Changed:** Minimum Zig version bumped to `0.16.0`.

### v0.12.2 — Zig Version-Aware Install

**Fixed:** `install.sh` now detects your Zig version and installs the compatible ephor version:
- Zig 0.16.0+ → ephor v0.12.x
- Zig 0.15.x → ephor v0.11.13

Before this fix, the install script always fetched the latest ephor version regardless of Zig version, causing build failures on Zig 0.15.x projects.

### v0.12.1 — Upgrade Path Fix

**Fixed:** `ephor upgrade` (and `zig build ephor-upgrade`) now correctly detects and replaces the old v0.11.x `EPHOR_BUILD_SNIPPET` marker (`// === Ephor Static Analysis ===`) in `build.zig`.

**Before this fix:** Projects installed with ephor v0.11.x could not have their `build.zig` updated to include the `ephor-upgrade` step when upgrading to v0.12.0. The upgrade appeared to succeed (dependency updated in `build.zig.zon`) but `build.zig` was silently left in the old state.

**Impact:** If you installed ephor before v0.12.0 and your `build.zig` still uses `// === Ephor Static Analysis ===`, running `ephor upgrade` (or `zig build ephor-upgrade`) will now properly migrate your `build.zig` to the canonical block that includes both the `ephor` and `ephor-upgrade` steps.

### v0.12.0 — Zig 0.16.0 Support

- Added Zig 0.16.0 compatibility (`std.heap.GeneralPurposeAllocator` → `std.heap.DebugAllocator`, API changes)
- Updated build integration block to include `ephor-upgrade` step

### v0.11.13 — Performance

- Cache resolved paths, eliminate O(N²) realpath storm

## Testing Methodology

Every ephor release is validated against five scenarios before tagging:

### Test Matrix

| Scenario | Zig Version | Starting State | Expected Result |
|----------|-------------|----------------|-----------------|
| Fresh install | 0.16.0 | No ephor | Installs v0.15.0, `zig build ephor` passes |
| Fresh install | 0.15.2 | No ephor | Installs v0.11.13, `zig build ephor` passes |
| Upgrade | 0.16.0 | v0.11.x snippet | Upgrades to v0.15.0, old snippet replaced with canonical block |
| Upgrade | 0.15.2 | v0.11.x snippet | Upgrades to v0.11.13, old snippet replaced with canonical block |
| Build-step upgrade | 0.15.2 | ephor dependency present | Refuses with a named error; install.sh pins v0.11.13 |
| Re-run | 0.16.0 | v0.15.0 canonical | Idempotent — block replaced with identical content, zon pin unchanged |

### Running the Tests Locally

```bash
# 1. Build ephor from source
cd /path/to/ephor
git checkout main
zig build -j1

# 2. Create test projects with different Zig versions
mkdir -p /tmp/test-ephor && cd /tmp/test-ephor

# Zig 0.16.0 project
mkdir fresh-0160 && cd fresh-0160
zenv init
zenv use 0.16.0
source .zenv/activate && zig init
sh /path/to/ephor/install.sh
zig build ephor

# Zig 0.15.2 project  
mkdir fresh-0152 && cd fresh-0152
zenv init
zenv use 0.15.2
source .zenv/activate && zig init
sh /path/to/ephor/install.sh
zig build ephor

# Upgrade from v0.11.x (simulate old install)
mkdir upgrade-0160 && cd upgrade-0160
zenv init
zenv use 0.16.0
source .zenv/activate && zig init
# Manually inject old v0.11.x snippet into build.zig and build.zig.zon
sh /path/to/ephor/install.sh
zig build ephor
```

### What We Check

1. **Install script output** — correct version detected for the Zig version
2. **build.zig.zon** — dependency URL points to correct ephor version
3. **build.zig** — canonical block present with both `ephor` and `ephor-upgrade` steps
4. **`zig build ephor`** — compiles and runs without errors
5. **`zig build ephor-upgrade`** — idempotent on already-up-to-date projects

### Layer-1 Gate Recipe

`scripts/gate.sh` is the commit gate. Its legs, in order: fmt, ReleaseSafe
build, the test ratchet (Build Summary counts), a per-test capture run
(the runner's `i/N name...OK` lines — `--summary all` suppresses them, so
a second cached-compile run collects them), the discovery cross-check,
the dogfood ratchet (`check src/`, fail_on warning posture), the coverage
gate, and the corpus A/B. Ratchet baselines live in
`scripts/gate-baselines.txt` (update `tests` in the commit that adds
tests; update `dogfood` in the commit that fixes warnings).

**Test discovery cross-check:** `ephor list-tests src/` lists every test
block the static scan finds (file, line, name; `--format=json` for the
machine shape). The gate requires the listing count to equal the runner's
`i/N` denominator and the Build Summary total — the static twin must
match what `zig test` executes. The scan reuses the ZT1xx opener
machinery (masking, Allman carry, block tracking), so its known residuals
are the two unhandled Allman shapes and two decls on one line.

**Coverage gate:** the ephor.json `coverage` block:

```json
"coverage": {
  "unreached_pub_fn_ratio_max": 5.0,
  "min_tests": 0,
  "require_all_passed": true
}
```

`unreached_pub_fn_ratio_max` gates the ZT105 census: the percentage of
unreached pub fns the scan collected (the ratio prints on every gated run
as `ephor: coverage: N% of M public functions unreached by tests (limit
X%)`). `min_tests` and `require_all_passed` evaluate only when the run
carries `--coverage-evidence=<file>` with the runner's counts
(`{"passed": N, "total": M}` — the gate writes it from the test ratchet).
A tripped leg prints an `ephor: coverage gate:` line and exits 1; in text
mode (the gate-script mode) a broken evidence file warns and leaves the
runner legs unevaluated, and the gate script fails on that warning. The
block is optional: an old config without it parses unchanged, and a
malformed value warns and leaves that key off. Untrusted target configs
never honor `coverage` (it is a gate key). The coverage block is a
static proxy — Zig 0.16.0 has no line-coverage flag and external
coverage tools are banned — so it measures what the scanner can prove,
not line coverage.

**Fuzz smoke stage — documented deferral (EPH-I1090):** the gate wires no
fuzz stage yet. Evidence: ephor's own tree carries zero `std.testing.fuzz`
annotations, and a live probe shows `zig build test --fuzz=N` exits 1
with "no fuzz tests found" on a fuzz-less tree (0.16.0 parses only the
`--fuzz=N` form). A stage over an empty inventory would fail permanently
or skip forever. When the first fuzzable module lands, wire the stage
behind an opt-in latch, e.g. `GATE_FUZZ=1000 zig build test --fuzz=1000`,
with N bounded and the run kept off the default path.

### CDN Cache Consideration

Codeberg raw file URLs (`/raw/branch/main/install.sh`) are CDN-cached. After pushing a release, wait 2–3 minutes before testing the live `curl | sh` path, or add a cache-busting query parameter for immediate validation:

```bash
curl -fsSL "https://codeberg.org/RhyosLabs/ephor/raw/branch/main/install.sh?nocache=1" | sh
```

## License

MIT License - see [LICENSE](LICENSE)

## Contributing

Issues and pull requests welcome at [codeberg.org/RhyosLabs/ephor](https://codeberg.org/RhyosLabs/ephor)

---

**Rhyos Labs** - [rhyoslabs.com](https://rhyoslabs.com)
