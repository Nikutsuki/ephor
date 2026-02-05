# Ephor

**The overseer of your Zig code** - Static + Dynamic analysis tool for Zig projects that fills gaps in `zig fmt`, `zig build`, and `zig build test`.

## What It Does

| Analyzer | What It Finds |
|----------|---------------|
| **check** | Run all static checks |
| **runtime** | Dynamic analysis via test execution (memory leaks, panics) |
| **orphans** | Files not imported from entry points |
| **memory** | `alloc()` without matching `defer free()` |
| **errors** | Silent `catch {}`, `catch unreachable`, `= undefined` |
| **unused** | Unused imports, const, and var declarations |
| **complexity** | Long functions, deep nesting, too many params/branches |
| **style** | Lines too long, files too large |
| **fmt-check** | Files that need `zig fmt` |

## Installation

### From Source

```bash
git clone https://bitbucket.org/rhyoslabs/ephor.git
cd ephor
zig build -Doptimize=ReleaseSafe
```

Binary will be at `zig-out/bin/ephor`.

### Add to PATH

```bash
# Option 1: Copy to /usr/local/bin
sudo cp zig-out/bin/ephor /usr/local/bin/

# Option 2: Add to PATH in .zshrc/.bashrc
export PATH="$PATH:/path/to/ephor/zig-out/bin"
```

### Integrate into Your Project's build.zig

Add ephor as a build step in your project so `zig build ephor` runs static analysis automatically.

#### Quick Setup (Recommended)

If you have ephor installed, run this in your project directory:

```bash
cd /path/to/your-project
ephor install
```

This will:
1. Add the ephor dependency to your `build.zig.zon` (via `zig fetch`)
2. Print the code snippet to add to your `build.zig`

Then run `zig build ephor` to verify it works.

#### Manual Setup

**Step 1: Add ephor as a dependency in your `build.zig.zon`:**

```zig
.{
    .name = .my_project,
    .version = "0.1.0",
    .dependencies = .{
        .ephor = .{
            .url = "https://bitbucket.org/rhyoslabs/ephor/get/main.tar.gz",
            // After first run, Zig will tell you the correct hash to add here:
            // .hash = "...",
        },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

> **Note:** On first build, Zig will error with the correct `.hash` value - copy it into your `build.zig.zon`.

**Step 2: Add an ephor step in your `build.zig`:**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Your normal exe/lib setup...
    const exe = b.addExecutable(.{
        .name = "my_project",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // === Add Ephor Static Analysis ===
    const ephor_dep = b.dependency("ephor", .{
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const ephor_exe = ephor_dep.artifact("ephor");

    const ephor_cmd = b.addRunArtifact(ephor_exe);
    ephor_cmd.addArgs(&.{ "check", "src/" });

    const ephor_step = b.step("ephor", "Run ephor static analysis");
    ephor_step.dependOn(&ephor_cmd.step);

    // Optional: Make ephor run before build
    // exe.step.dependOn(&ephor_cmd.step);
}
```

**Step 3: Run it:**

```bash
# Run static analysis
zig build ephor

# Run ephor before every build (if you uncommented the dependOn line)
zig build
```

**Available ephor commands:**

```zig
// Check all (default)
ephor_cmd.addArgs(&.{ "check", "src/" });

// Check with summary
ephor_cmd.addArgs(&.{ "check", "src/", "--summary" });

// Memory analysis only
ephor_cmd.addArgs(&.{ "memory", "src/" });

// With custom thresholds
ephor_cmd.addArgs(&.{ "check", "src/", "--max-lines=100", "--max-branches=15" });

// Disable specific rules
ephor_cmd.addArgs(&.{ "check", "src/", "--disable=ZA301" });
```

## Usage

```bash
# Add ephor to your project (recommended)
cd /path/to/your-project
ephor install            # Adds dependency and patches build.zig

# Update ephor to latest version
ephor upgrade            # or: ephor update

# Run all static checks
ephor check

# Run all checks on specific directory
ephor check src/

# Run dynamic analysis (tests with memory diagnostics)
ephor runtime

# Individual analyzers
ephor orphans
ephor memory
ephor errors
ephor complexity
ephor fmt-check

# Project statistics
ephor stats

# Create config file
ephor init
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

## Configuration

Create `ephor.json` in your project root:

```bash
ephor init
```

Example config:

```json
{
  "src": "src",
  "entries": ["src/main.zig", "build.zig"],
  "exclude": ["test", "vendor", "third_party"],
  "orphan_exclude": ["_test.zig", "/test/", "/tests/"],
  "disable": ["ZA301"],
  "enable": ["ZA702"],
  "thresholds": {
    "max_lines": 50,
    "max_nesting": 4,
    "max_params": 5,
    "max_branches": 10,
    "max_line_length": 100,
    "max_file_bytes": 25000
  }
}
```

### Config Options

| Option | Description |
|--------|-------------|
| `src` | Source directory to scan |
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
| **ZA101** | warning | ON | `alloc()` without `defer free()` |
| **ZA102** | warning | ON | `create()` without `defer destroy()` |
| **ZA103** | warning | ON | Allocation in error-returning function without `errdefer` |
| **ZA104** | warning | ON | Memory leak: allocation not freed on all paths |
| **ZA105** | error | ON | Use-after-free: accessing memory after free |
| **ZA106** | error | ON | Double-free: calling free twice on same pointer |

### Error Handling (ZA2xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA201** | warning | ON | Silent `catch {}` discards errors |
| **ZA202** | error | ON | `catch unreachable` will panic |
| **ZA203** | error | ON | `orelse unreachable` will panic |
| **ZA204** | warning | ON | `= undefined` may leak sensitive data |
| **ZA205** | warning | ON | Discarding error union result without try/catch |

### Complexity (ZA3xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA301** | warning | ON | Function exceeds max lines (default: 50; type factories get 3x) |
| **ZA302** | warning | ON | Function exceeds max nesting depth (default: 4; type factories get 2x) |
| **ZA303** | warning | ON | Function has too many parameters (default: 5) |
| **ZA304** | warning | ON | Function has too many branches (default: 10; type factories get 3x) |

**Note:** Functions returning `type` (comptime type factories like `fn Bind(T: type) type`) automatically get relaxed limits since they're metaprogramming constructs that build types at compile time. `inline for/while` loops are not counted as branches since they're compile-time unrolled.

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
| **ZA701** | warning | ON | Line exceeds max length (default: 80 columns) |
| **ZA702** | warning | OFF | File exceeds max size (set `max_file_bytes` to enable) |
| **ZA703** | warning | ON | Naming convention violation (types=TitleCase, funcs=camelCase, vars=snake_case) |

### Null Safety (ZA8xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA801** | warning | ON | Optional unwrap (.?) may panic if null |
| **ZA802** | warning | ON | Dereferencing optional pointer may panic if null |

### Panic Detection (ZA9xx)

| Rule | Severity | Default | Description |
|------|----------|---------|-------------|
| **ZA901** | warning | ON | Decrement without overflow guard may panic |
| **ZA902** | warning | ON | Subtraction in range may cause overflow |
| **ZA903** | warning | ON | Arithmetic in array index may overflow |

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

## CLI Options

```
ephor <command> [path] [options]

Commands:
  init        Create ephor.json config file
  check       Run all static checks (default)
  runtime     Run tests with memory diagnostics (dynamic analysis)
  orphans     Files not imported from entry points
  memory      Alloc without defer patterns
  errors      Silent catch {} discards
  unused      Unused imports/const/var declarations
  complexity  Function complexity metrics
  fmt-check   Files needing zig fmt
  stats       Project statistics

Options:
  --entry=<file>       Entry point (default: src/main.zig)
  --format=text|json   Output format (default: text)
  --disable=<rule>     Disable rule (e.g., ZA301, ZA3 for all ZA3xx)
  --enable=<rule>      Enable rule (overrides disable)
  --max-lines=N        Max function lines (default: 50)
  --max-nesting=N      Max nesting depth (default: 4)
  --max-params=N       Max parameters (default: 5)
  --max-line-length=N  Max columns per line (default: 80)
  --max-file-bytes=N   Max file size in bytes (enables ZA702)
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
| 0 | No issues found |
| 1 | Issues found |

## Examples

### Check a project

```bash
$ ephor check
src/main.zig:506:25: warning[ZA201]: silent catch {} discards error without handling
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
- Zig 0.15.x (current)
- Zig 0.16.x (when released)

### Version Compatibility System

Ephor uses a modular compatibility layer to support multiple Zig versions. The system is designed for easy extension:

```
src/compat/
├── compat.zig     # Main module: version detection, registry
├── v0_15.zig      # Zig 0.15.x specific implementations
└── v0_16.zig      # Zig 0.16.x specific implementations (placeholder)
```

**Adding support for a new Zig version:**

1. Create `src/compat/vX_YZ.zig` (e.g., `v0_17.zig`)
2. Implement the version-specific API wrappers
3. Add import to `compat.zig`
4. Register in `version_registry`

Each version module exports consistent wrapper functions that handle API differences between Zig versions (e.g., HashMap.put signature changes).

## License

MIT License - see [LICENSE](LICENSE)

## Contributing

Issues and pull requests welcome at [bitbucket.org/rhyoslabs/ephor](https://bitbucket.org/rhyoslabs/ephor)

---

**Rhyos Labs** - [rhyoslabs.com](https://rhyoslabs.com)
