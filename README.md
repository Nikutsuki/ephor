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
| **unused** | Unused imports, const, and var declarations |
| **complexity** | Long functions, deep nesting, too many params/branches |
| **style** | Lines too long, files too large |
| **fmt-check** | Files that need `zig fmt` |

## Installation

**Requires**: A Zig project with `build.zig` and `build.zig.zon` (run `zig init` if you don't have these).

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

That's it.

### Upgrading

One command — same as install:

```bash
curl -fsSL https://codeberg.org/RhyosLabs/ephor/raw/branch/main/install.sh | sh
```

The script detects if ephor is already present and upgrades it in place:
- Updates the dependency in `build.zig.zon`
- Replaces the `build.zig` integration block (handles both old v0.11.x and current formats)
- Creates/updates `ephor.json`

If you already have the `ephor-upgrade` step in `build.zig`:

```bash
zig build ephor-upgrade
```

### Version Management

Ephor pins the installed version in `ephor.json` so your team always runs the same version. The pinned version is stored under the `"version"` key. When you run `ephor install`, it auto-detects your source directory, entry points from `build.zig`, and writes a config file.

### Manual Installation

<details>
<summary>Click to expand manual steps</summary>

Add the dependency:

```bash
zig fetch --save=ephor https://codeberg.org/RhyosLabs/ephor/archive/v0.13.3.tar.gz
```

Then add to `build.zig`:

```zig
const ephor_dep = b.dependency("ephor", .{
    .target = target,
    .optimize = .ReleaseSafe,
});
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
ephor errors              # Error handling patterns (ZA201-ZA208)
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
src/main.zig:506:25: note[ZA201]: silent catch {} discards error without handling
  help: use 'catch |err| { log.err(...); return err; }' or propagate with 'try'
```

### JSON Output

```bash
ephor check --format=json
```

## Configuration

Create `ephor.json` in your project root:

```bash
zig build ephor -- init   # Via build system
ephor init                # Standalone CLI
```

Example config:

```json
{
  "version": "0.13.3",
  "path_dir": "src",
  "entries": ["src/main.zig", "build.zig"],
  "exclude": ["test", "vendor", "third_party"],
  "orphan_exclude": ["_test.zig", "/test/", "/tests/"],
  "disable": ["ZA301"],
  "enable": ["ZA702"],
  "thresholds": {
    "max_lines": 50,
    "max_nesting": 3,
    "max_params": 4,
    "max_branches": 12,
    "max_line_length": 100,
    "max_file_bytes": 25000
  }
}
```

### Config Options

| Option | Description |
|--------|-------------|
| `version` | Pinned ephor version (set by `install`/`upgrade`) |
| `path_dir` | Directory to analyze (also accepts `code`, `src`, or `root` as aliases) |
| `entries` | Entry points for orphan detection |
| `exclude` | Paths to exclude from all checks (substring match) |
| `orphan_exclude` | Patterns to exclude from orphan detection only |
| `disable` | Rule IDs to disable (prefix matching: `ZA3` disables all) |
| `enable` | Rule IDs to enable (overrides disable) |
| `thresholds` | Complexity and style thresholds |

## Rule IDs

### Memory (ZA1xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA101** | warning | ON | Stdlib allocation without `defer free()` (alloc, allocPrint, toOwnedSlice, readFileAlloc, mem.concat, etc.) |
| **ZA102** | warning | ON | `create()` without `defer destroy()` |
| **ZA103** | warning | ON | Stdlib allocation without `errdefer` in error-returning function |
| **ZA105** | error | ON | Use-after-free: accessing memory after free |
| **ZA106** | error | ON | Double-free: calling free twice on same pointer |

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

### Complexity (ZA3xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA301** | warning | ON | Function exceeds max lines (default: 50; type factories get 3x) |
| **ZA302** | warning | ON | Function exceeds max nesting depth (default: 3; type factories get 2x) |
| **ZA303** | warning | ON | Function has too many parameters (default: 4) |
| **ZA304** | warning | ON | Function has too many branches (default: 12; type factories get 3x) |
| **ZA305** | warning | OFF | Function has high cyclomatic complexity — McCabe CCN (default: 15) |
| **ZA306** | warning | OFF | Function has high cognitive complexity — Sonar-style weighted nesting (default: 15) |

**Note:** Functions returning `type` (comptime type factories like `fn Bind(T: type) type`) automatically get relaxed limits since they're metaprogramming constructs that build types at compile time. `inline for/while` loops are not counted as branches since they're compile-time unrolled.

### Cyclomatic Complexity (ZA305)

McCabe's cyclomatic complexity counts independent execution paths. Every `if`, `while`, `for`, `switch`, `catch`, `try`, `orelse`, `and`, and `or` adds 1 to the count. A function with no branching has a CCN of 1. Default threshold: 15.

### Cognitive Complexity (ZA306)

Sonar-style cognitive complexity weights branches by nesting depth. An `if` at the top level costs 1; the same `if` nested 3 levels deep costs 4 (1 + nesting depth). Logical operators (`and`/`or`) cost 1 each regardless of depth. Default threshold: 15.

### Enabling ZA305 and ZA306

ZA305 and ZA306 are off by default. To enable them, remove `"ZA305"` and `"ZA306"` from the `"disable"` array in `ephor.json`, or add them to the `"enable"` array to explicitly enable them. The default thresholds are `max_cyclomatic: 15` and `max_cognitive: 15`; lower values are stricter.

### Unused Code (ZA4xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA401** | warning | ON | Unused import |
| **ZA402** | warning | ON | Unused const declaration |
| **ZA403** | warning | ON | Unused var declaration |

### Structure (ZA5xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA501** | warning | ON | Orphan file (not imported from entry points) |

### Formatting (ZA6xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA601** | warning | ON | File needs `zig fmt` |

### Style (ZA7xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA701** | warning | ON | Line exceeds max length (default: 100 columns) |
| **ZA702** | warning | OFF | File exceeds max size (set `max_file_bytes` to enable) |
| **ZA703** | warning | ON | Naming convention violation (see naming rules below) |

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
| Error values (`error.foo`) | `snake_case` | `return error.file_not_found;` |
| Error set members | `snake_case` | `error{ file_not_found }` |
| Imports | (not checked) | `const std = @import("std");` |
| Names starting with `_` | (exempt) | `fn _helper() void {}` |

### Null Safety (ZA8xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA801** | warning | OFF | Optional unwrap (.?) may panic if null (use `--enable=ZA8`) |
| **ZA802** | warning | OFF | Dereferencing optional pointer may panic if null (use `--enable=ZA8`) |

**When to enable ZA8xx:** Pre-release audits for safety-critical code (servers, databases) where a null panic means downtime. Off by default because `.?` is extremely common in Zig and usually intentionally guarded.

### Panic Detection (ZA9xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA901** | warning | OFF | Decrement without overflow guard may panic (use `--enable=ZA9`) |
| **ZA902** | warning | OFF | Subtraction in range may cause overflow (use `--enable=ZA9`) |
| **ZA903** | warning | OFF | Arithmetic in array index may overflow (use `--enable=ZA9`) |

**When to enable ZA9xx:** Before switching from `Debug` to `ReleaseFast` builds — in debug mode, integer overflow panics helpfully; in `ReleaseFast` it becomes undefined behavior. Also useful for security-sensitive or financial code where overflow = vulnerability.

### Runtime Analysis (ZR1xx)

| Rule | Severity | Description |
|------|----------|-------------|
| **ZR101** | error | Memory leak detected at runtime |
| **ZR102** | error | Double-free detected at runtime |
| **ZR103** | error | Use-after-free detected at runtime |
| **ZR104** | error | Test failed |
| **ZR105** | error | Panic detected during test execution |

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

## CLI Reference

Full command reference for the standalone `ephor` binary:

```
ephor [command] [path] [options]

Commands:
  check       Run all static checks (default)
  runtime     Run tests with memory diagnostics (dynamic analysis)
  orphans     Files not imported from entry points
  memory      Stdlib allocation without defer patterns (50+ patterns)
  errors      Error handling patterns (ZA201-ZA208)
  unused      Unused imports/const/var declarations
  complexity  Function complexity metrics
  fmt-check   Files needing zig fmt
  stats       Project statistics
  upgrade     Upgrade ephor to latest version (alias: update)
  install     Add ephor to project's build.zig (version-pinned)
  init        Create ephor.json config file

Options:
  --entry=<file>       Entry point (default: src/main.zig)
  --format=text|json   Output format (default: text)
  --disable=<rule>     Disable rule (e.g., ZA301, ZA3 for all ZA3xx)
  --enable=<rule>      Enable rule (overrides disable)
  --max-lines=N        Max function lines (default: 50)
  --max-nesting=N      Max nesting depth (default: 3)
  --max-params=N       Max parameters (default: 4)
  --max-branches=N     Max branches per function (default: 12)
  --max-line-length=N  Max columns per line (default: 100)
  --max-file-bytes=N   Max file size in bytes (enables ZA702)
  -y, --yes            Skip interactive confirmation (e.g., runtime approval)
  --version=<X.Y.Z>   For install/upgrade: pin a specific version
  --command=<cmd>      For runtime: custom command instead of 'zig build test'
  -V, --verbose        Verbose output
  -s, --summary        Show summary at end (off by default)
```

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
| **File type** | `Zig` (or `Any` if Zig isn't listed) |
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

If IntelliJ doesn't recognize `.zig` files:

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
| 0 | No warnings or errors found |
| 1 | Warnings or errors found |

Notes (informational issues like ZA205 and ZA208) are printed but do **not** cause a non-zero exit code. Only warnings and errors affect the exit code.

## Examples

### Check a project

```bash
$ ephor check
src/main.zig:506:25: note[ZA201]: silent catch {} discards error without handling
  help: use 'catch |err| { log.err(...); return err; }' or propagate with 'try'

ephor summary

Files: 156 | Code: 66884 lines

Issues:
  Orphans:    155
  Memory:     102
  Errors:     89
  Unused:     4
  Complexity: 404
  Format:     0
  TOTAL:      754

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

### Run dynamic analysis

```bash
$ ephor runtime
Running: zig build test (with GPA diagnostics)
src/memory.zig:45:1: error[ZR101]: memory leak detected at runtime
  help: allocation not freed - check for missing defer or error path
```

## Compatibility

**Supported Zig Versions:**
- Zig 0.16.x (current) — **required minimum**

Ephor v0.13.3+ requires Zig 0.16.0 or later. Earlier ephor versions (v0.11.x) support Zig 0.15.x.

### Version Compatibility System

Ephor uses a modular compatibility layer to support Zig 0.16.x API patterns. The system is designed for easy extension as new Zig versions are released:

```
src/compat/
├── compat.zig     # Main module: version detection, registry
└── v0_16.zig      # Zig 0.16.x specific implementations
```

**Adding support for a new Zig version:**

1. Create `src/compat/vX_YZ.zig` (e.g., `v0_17.zig`)
2. Implement the version-specific API wrappers
3. Add import to `compat.zig`
4. Register in `version_registry`

Each version module exports consistent wrapper functions that handle API differences between Zig versions (e.g., `std.process.Init` main signature changes).

## Technical: How Detection Works

This section documents the internal detection architecture. Understanding these internals helps identify gaps and validate correctness.

### Architecture Overview

Ephor has three analysis entry points:

| Entry Point | Scope | Rules | Context |
|-------------|-------|-------|---------|
| `analyzeFileErrors` | Full file, line-by-line | ZA201-ZA208 (in `checkLineErrors`) | `TypeContext` via `parseFileTypeContext(content)` |
| `analyzeIgnoredErrorsInFile` | Full file, line-by-line | ZA205 (in `checkIgnoredError`) | `TypeContext` via `parseFileTypeContext(content)` |
| `analyzeCFGFile` | Full file, per-function CFG | ZA101-ZA106, ZA8xx, ZA9xx | `CFGState` with file-level `no_free_fields` |

Error analysis (`analyzeFileErrors`, `analyzeIgnoredErrorsInFile`) uses `TypeContext` for type-aware method return resolution. Memory analysis (`analyzeCFGFile`) uses CFG-based control flow analysis with type-based allocator suppression.

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
If the receiver variable is tracked in `stdlib_vars`, check against vocabulary patterns from the compat layer (`getSafeMethodPatterns()`, `getVoidMethodPatterns()`). Method patterns (starting with `.`) only match when the receiver is a confirmed stdlib type.

**Tier 4 — Legacy patterns (backwards compat):**
Substring matching for non-stdlib patterns (C FFI uppercase functions, parser internals). Universal patterns (not starting with `.`) always match regardless of receiver type.

**Tier 5 — Unknown → report:**
If no tier resolved the call, the discard is reported (conservative: better to flag than miss).

### Detection Functions and Their Tiers

| Function | Used By | Tiers Used |
|----------|---------|------------|
| `isSafeToDiscard` | `checkDiscardedResult` (ZA205 in `analyzeFileErrors`) | 1→2→3→4 |
| `isSafeBuiltin` | `checkIgnoredError` (ZA205 in `analyzeIgnoredErrorsInFile`) | builtins→2→3→fields→optionals |
| `isKnownVoidFunction` | Error analysis (confirms void return) | 1→2→3→log patterns |
| `checkMethodTransfer` | `processAllocTracking` (ZA101-106 memory) | stdlib_vars only (no Tier 2) |

### Memory Analysis Path (ZA101-ZA106)

Memory analysis uses a **CFG-based approach** through three specialized analyzers:

| Analyzer | Rules | Purpose |
|----------|-------|---------|
| `analyzeCFGDeferCoverage` | ZA101, ZA102 | Allocation without matching `defer free()`/`defer destroy()` |
| `analyzeCFGErrdeferCoverage` | ZA103 | Allocation without `errdefer` before next `try` |
| `analyzeCFGMemorySafety` | ZA105, ZA106 | Use-after-free, double-free |

**Analysis pipeline per file** (`analyzeCFGFile`):

1. **File-level setup**: Compute `no_free_fields` by scanning struct field declarations for no-free allocator types (e.g., `arena: std.heap.ArenaAllocator`)
2. **Function extraction**: Split file into individual functions
3. **Per-function analysis** (`processFunction`): Run `runCFGMemoryAnalyses` (ZA101-ZA106), `runCFGSafetyAnalyses` (ZA8xx, ZA9xx), and `runDefiniteAssignmentAnalysis`

**No-free allocator suppression** — allocations that don't need per-allocation free:

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

#### What Is NOT Parsed

| Pattern | Why | Fallback |
|---------|-----|----------|
| Multi-line function signatures | Line-by-line parser can't join lines | Falls through to `.unknown` → vocab |
| Cross-file type resolution | Types defined in imported files | Falls through to `.unknown` → vocab |
| Generic type parameters | `ArrayList(u8)` stored as full text, lookup mismatch | Falls through to `.unknown` → vocab |
| Type aliases | `const MyList = ArrayList;` not tracked | Falls through to `.unknown` → vocab |
| Variable reassignment | `x = NewType.init()` doesn't update type | Uses original declaration type |
| Method chaining | `a.b().c()` — only sees last receiver | May resolve wrong receiver |
| Nested function definitions | Functions inside functions | Registered as top-level |
| Comptime-generated types | Types from `comptime` blocks | Falls through to `.unknown` → vocab |
| Pointer chain stripping | `**MyStruct` keeps one `*` | May cause lookup mismatch |

All limitations fall through to `.unknown`, which triggers vocab-based detection (Tier 3/4). This means: **no false negatives from parsing limitations** — the worst case is falling back to the same behavior as before TypeContext existed.

#### Known False Positive Patterns

| Pattern | Rule | Root Cause | Status |
|---------|------|------------|--------|
| Arena allocator via `std.mem.Allocator` interface | ZA101/ZA103 | Type erasure — arena loses no-free semantics when passed as generic `Allocator` | Open (by design: type-based detection cannot resolve erased types) |

Note: Arena allocations through **struct field chains** (e.g., `self.arena.allocator().alloc(...)`) are correctly suppressed when the field is declared with a no-free allocator type like `std.heap.ArenaAllocator`. Only type-erased fields (declared as `std.mem.Allocator`) remain as known false positives.

These patterns are validated against the community project corpus (3000+ projects, top 100 by size audited with zero false positives).

### Vocabulary System (Compat Layer)

The compat layer (`src/compat/`) provides version-specific pattern vocabularies:

| Vocabulary | Purpose | Example Patterns |
|-----------|---------|-----------------|
| `getCleanupPatterns()` | Methods that are always void | `.free(`, `.destroy(`, `.deinit(` |
| `getSafeMethodPatterns()` | Stdlib methods safe to discard | `.clear(`, `.next(`, `.pop(` |
| `getVoidMethodPatterns()` | Stdlib methods returning void | `.resize(`, `.shrinkRetainingCapacity(` |
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
- `examples/error_handling_demo.zig` — Error handling patterns (ZA201-ZA208)

**4. Corpus validation** (3000+ community Zig projects):
- Dogfood: `ephor check src/` → zero issues
- Community baseline regression testing against key projects

## Changelog

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

Every ephor release is validated against four scenarios before tagging:

### Test Matrix

| Scenario | Zig Version | Starting State | Expected Result |
|----------|-------------|----------------|-----------------|
| Fresh install | 0.16.0 | No ephor | Installs v0.12.x, `zig build ephor` passes |
| Fresh install | 0.15.2 | No ephor | Installs v0.11.13, `zig build ephor` passes |
| Upgrade | 0.16.0 | v0.11.x snippet | Upgrades to v0.12.x, old snippet replaced with canonical block |
| Upgrade | 0.15.2 | v0.11.x snippet | Upgrades to v0.11.13, old snippet replaced with canonical block |
| Re-run | 0.16.0 | v0.12.x canonical | Idempotent — "up-to-date", no changes |

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
zenv init --zig 0.16.0
source .zenv/activate && zig init
sh /path/to/ephor/install.sh
zig build ephor

# Zig 0.15.2 project  
mkdir fresh-0152 && cd fresh-0152
zenv init --zig 0.15.2
source .zenv/activate && zig init
sh /path/to/ephor/install.sh
zig build ephor

# Upgrade from v0.11.x (simulate old install)
mkdir upgrade-0160 && cd upgrade-0160
zenv init --zig 0.16.0
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
