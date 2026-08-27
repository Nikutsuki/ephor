# Ephor Design Document

**Version**: 1.0
**Date**: 2026-02-03
**Author**: Rhyos Labs

## Overview

Ephor is a static + dynamic code quality tool for Zig projects that complements (not duplicates) `zig fmt`, `zig build`, and `zig build test`. This document defines the separation between **linting** (fast, pattern-based) and **static analysis** (slower, semantic).

## Purpose

**Primary Use Case**: Highlight code patterns that need human review.

In an era of AI-assisted coding, Ephor serves as a safety net that catches:
- Memory patterns that commonly lead to leaks or use-after-free
- Error handling that silently swallows failures
- Code complexity that makes bugs harder to spot
- Dead code and unused imports

The tool does not judge code as "wrong" - it flags areas where a developer (human or AI) should double-check their work. Think of it as a code review checklist that runs automatically.

**Philosophy**: The linter highlights potential issues. The developer decides if they are actual problems.

## Design Principles

### 1. Enforce Community Standards, Not Personal Opinions

Ephor enforces **established community conventions** - not arbitrary rules we invented. The Zig compiler intentionally does not enforce style, but the community has clear standards documented in the official style guide and demonstrated throughout the standard library.

**What we enforce by default**:
- Memory safety patterns (defer after alloc, errdefer, undefined warnings)
- Error handling (no silent catch {}, no catch unreachable)
- Code quality metrics (complexity thresholds, unused code detection)
- Line length (100 columns - configurable)
- Formatting consistency (zig fmt check)

**What we DO NOT enforce by default** (project-dependent):
- File size limits (set `max_file_bytes` to enable)
- Naming conventions (ZA703 - not yet implemented)

**What is configurable**:
- All thresholds (line length, function size, nesting, params, branches)
- Any rule can be disabled: `"disable": ["ZA301"]`

**Everything is configurable**:
- Do not like a rule? Disable it: `"disable": ["ZA703"]`
- Want stricter checks? Enable them: `"enable": ["ZA204", "ZA701"]`
- Different thresholds? Set them: `"thresholds": { "max_function_lines": 100 }`

### 2. Do Not Duplicate Existing Tools

| Tool | Handles | Ephor Does NOT Duplicate |
|------|---------|-------------------------------|
| `zig fmt` | Formatting, indentation, whitespace | Formatting rules |
| `zig build` | Compilation errors, type checking | Type errors |
| `zig build test` | Runtime behavior, test execution | Test failures |

### 3. Feedback Before Build

The linter gives developers feedback **before** they run `zig build`. Finding issues at lint time is faster than finding them at build time or runtime.

```
ephor check src/      # All enabled checks (~2-10s depending on config)
```

No separate modes. All checks available. Configure what you want via `ephor.json`.

---

## Quick Reference: Default Rule States

### ON by Default (Best Practices & Community Standards)

| Rule | Category | Default Threshold | Rationale |
|------|----------|-------------------|-----------|
| **ZA101** alloc no defer | Memory Safety | - | Memory leak prevention |
| **ZA102** create no defer | Memory Safety | - | Memory leak prevention |
| **ZA103** alloc no errdefer | Memory Safety | - | Leak on error path |
| **ZA105** use-after-free | Memory Safety | - | Access after free |
| **ZA106** double-free | Memory Safety | - | Free called twice |
| **ZA201** silent catch {} | Error Handling | - | Error swallowing is universally bad |
| **ZA202** catch unreachable | Error Handling | - | Will panic on error |
| **ZA203** orelse unreachable | Error Handling | - | Will panic on null |
| **ZA204** = undefined | Error Handling | - | May leak sensitive data |
| **ZA205** ignored error union | Error Handling | - | Error result discarded |
| **ZA301** function too long | Complexity | 50 lines | Complexity indicator |
| **ZA302** nesting too deep | Complexity | 3 levels | Complexity indicator |
| **ZA303** too many params | Complexity | 4 params | API smell indicator |
| **ZA304** too many branches | Complexity | 12 branches | Complexity indicator |
| **ZA401** unused import | Unused Code | - | Dead code indicator |
| **ZA402** unused const | Unused Code | - | Feedback before build |
| **ZA403** unused var | Unused Code | - | Feedback before build |
| **ZA501** orphan file | Structure | - | Dead code indicator |
| **ZA601** needs zig fmt | Formatting | - | Consistency with std library |
| **ZA701** line too long | Style | 100 columns | Readability |
| **ZA703** naming conventions | Style | - | Community standard enforcement |
| **ZA801** optional deref unchecked | Null Safety | - | Will panic on null |
| **ZA802** .? without null check | Null Safety | - | Will panic on null |

### OFF by Default (Expensive/Optional)

| Rule | Rationale | How to Enable |
|------|-----------|---------------|
| **ZA702** file too long | Project-dependent | Set `max_file_bytes` threshold |
| **ZA901** stack pointer escapes | Expensive analysis | `"enable": ["ZA901"]` |
| **ZA902** allocator mismatch | Expensive analysis | `"enable": ["ZA902"]` |
| **ZA903** resource not closed | Expensive analysis | `"enable": ["ZA903"]` |
| **ZAV01** deprecated API | Version-specific | `"enable": ["ZAV"]` + set target version |
| **ZAV02** breaking API changes | Version-specific | `"enable": ["ZAV"]` + set target version |
| **ZAV03** new API available | Version-specific | `"enable": ["ZAV"]` + set target version |

---

## Architecture

### Single Mode - All Checks Available

No separate "deep" mode. All checks run together. Some use pattern matching (fast), some use control flow analysis (slower but more accurate). Configure what you need.

**Rule Categories**:
```
ZA1xx  Memory      Allocation/deallocation checks
ZA2xx  ErrHandle   Error handling patterns (notes + ZA206 warning)
ZA3xx  Complexity  Code complexity metrics
ZA4xx  Unused      Dead code detection
ZA5xx  Structure   Import graph analysis
ZA6xx  Format      Formatting checks (delegates to zig fmt)
ZA7xx  Style       Style and naming conventions
ZA8xx  Optional    Null safety checks
ZA9xx  Lifetime    Resource and lifetime tracking
ZAVxx  Version     Zig API version compatibility
```

### Performance Expectations

| Check Type | Speed | Example Rules |
|------------|-------|---------------|
| Pattern-based | ~1-2s | ZA101, ZA201, ZA301 |
| CFG-based | ~5-15s | ZA105, ZA205, ZA801 |
| Full project | ~10-30s | All checks enabled |

All checks are fast enough for regular development. No need for separate modes.

---

## Rule Definitions

### ZA1xx Memory Safety

| Rule | Default | Description | Rationale |
|------|---------|-------------|-----------|
| ZA101 | ON | `.alloc()` without `defer free()` in same scope | Memory leak prevention |
| ZA102 | ON | `.create()` without `defer destroy()` in same scope | Memory leak prevention |
| ZA103 | ON | Allocation in error-returning function without `errdefer` | Leak on error path |
| ZA105 | ON | Use-after-free detected | Memory safety |
| ZA106 | ON | Double-free detected | Memory safety |

### ZA2xx Error Handling Patterns

| Rule | Default | Severity | Description | Rationale |
|------|---------|----------|-------------|-----------|
| ZA201 | ON | note | `catch {}` or `catch \|_\| {}` with empty body | Informational - often intentional in Zig |
| ZA202 | ON | note | `catch unreachable` | Informational - assertion pattern |
| ZA203 | ON | note | `orelse unreachable` | Informational - assertion pattern |
| ZA204 | ON | note | `= undefined` initialization | May leak sensitive data |
| ZA205 | ON | note | Error union result discarded without `try`/`catch` | Informational |
| ZA206 | ON | warning | `std.process.exit()` bypasses defers | Causes resource leaks |

### ZA3xx Complexity

| Rule | Default | Threshold | Description |
|------|---------|-----------|-------------|
| ZA301 | ON | 50 lines | Function exceeds max lines |
| ZA302 | ON | 3 levels | Function exceeds max nesting |
| ZA303 | ON | 4 params | Function has too many parameters |
| ZA304 | ON | 12 | Function has too many branches |

**Threshold Rationale**:
- 50 lines: Fits on one screen, comprehensible at a glance
- 3 nesting: Beyond this, extract helper functions
- 4 params: Consider a config struct
- 12 branches: Consider lookup tables or state machines

### ZA4xx Unused Code

| Rule | Default | Description | Rationale |
|------|---------|-------------|-----------|
| ZA401 | ON | Unused import | Feedback before build |
| ZA402 | ON | Unused const | Feedback before build |
| ZA403 | ON | Unused var | Feedback before build |

**Note**: The compiler also catches unused variables, but the linter gives feedback faster (before you run `zig build`).

### ZA5xx Structure

| Rule | Default | Description | Rationale |
|------|---------|-------------|-----------|
| ZA501 | ON | File not imported from any entry point | Dead code detection |

### ZA6xx Format

| Rule | Default | Description | Rationale |
|------|---------|-------------|-----------|
| ZA601 | ON | File needs `zig fmt` | Wrapper around `zig fmt --check` |

### ZA7xx Style

| Rule | Default | Threshold | Description |
|------|---------|-----------|-------------|
| ZA701 | ON | 100 columns | Line too long |
| ZA702 | OFF | configurable | File too large (set `max_file_bytes` to enable) |
| ZA703 | ON | - | Naming convention violations |

### ZA8xx Null Safety

| Rule | Default | Description | Rationale |
|------|---------|-------------|-----------|
| ZA801 | ON | Optional dereferenced without null check | Will panic on null |
| ZA802 | ON | `.?` used without prior null check | Will panic on null |

### ZA9xx Lifetime (OFF by default - expensive)

These checks require more expensive analysis. Enable them if you want deeper safety guarantees.

| Rule | Default | Description | How to Enable |
|------|---------|-------------|---------------|
| ZA901 | OFF | Stack pointer escapes function | `"enable": ["ZA901"]` |
| ZA902 | OFF | Allocator mismatch (alloc/free use different allocators) | `"enable": ["ZA902"]` |
| ZA903 | OFF | Resource (File, etc.) not closed on all paths | `"enable": ["ZA903"]` |

### ZAVxx Version Compatibility (OFF by default)

Check for Zig API changes between versions. Helps developers assess upgrade effort.

| Rule | Default | Description | How to Enable |
|------|---------|-------------|---------------|
| ZAV01 | OFF | Deprecated API usage for target version | `"enable": ["ZAV01"]` |
| ZAV02 | OFF | Breaking API changes for target version | `"enable": ["ZAV02"]` |
| ZAV03 | OFF | New API available in target version | `"enable": ["ZAV03"]` |

**Configuration**:
```json
{
  "enable": ["ZAV"],
  "version": {
    "current": "0.15.2",
    "target": "0.16.0"
  }
}
```

**Example output**:
```
src/main.zig:45:12: warning[ZAV02]: ArrayList.init() API changed in 0.16.0
  help: Change 'ArrayList(T).init(allocator)' to 'ArrayList(T){}'
  see: https://ziglang.org/download/0.16.0/release-notes.html#breaking-changes

ephor version-check summary:
  Breaking changes:  12
  Deprecated APIs:   3
  New APIs available: 5

  Estimated upgrade effort: MODERATE (12 breaking changes)
```

This helps developers decide if upgrading is a quick task or a major undertaking.

---

## Configuration

### Config File: `ephor.json`

The example shows the standard shape the `init` and `install` writers emit:
`version`, `path_dir`, `entries`, `exclude`, `orphan_exclude`, `enable`
(`ZA305`, `ZA306`), and `fail_on` (EPH-I1146). The `strict`,
`error_naming`, and `thresholds` keys are schema reference only: each stays
an optional manual override, and the built-in threshold defaults apply when
the `thresholds` block is absent.

```json
{
  "version": "0.14.3",
  "path_dir": "src",
  "entries": ["src/main.zig", "build.zig"],
  "exclude": ["vendor", "third_party"],
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

### Enabling Expensive Checks (ZA9xx)

The ZA9xx lifetime checks are OFF by default because they are slower. To enable:

```json
{
  "enable": ["ZA901", "ZA902", "ZA903"]
}
```

Or enable all ZA9xx:

```json
{
  "enable": ["ZA9"]
}
```

---

## CLI Interface

### Commands

```bash
ephor init                    # Create ephor.json
ephor check [path]            # Run all enabled checks (default)
ephor runtime [path]          # Run tests with memory diagnostics (dynamic analysis)

# Individual analyzers
ephor orphans [path]
ephor memory [path]
ephor errors [path]
ephor unused [path]
ephor complexity [path]
ephor fmt-check [path]
ephor stats [path]

# Version compatibility
ephor version-check [path] --from=0.15.2 --to=0.16.0
```

### Options

```bash
--entry=<file>           Entry point for orphan detection
--format=text|json       Output format (default: text)
--disable=<rule>         Disable rule (prefix matching: ZA1 disables ZA1xx)
--enable=<rule>          Enable rule (overrides disable)

# Threshold overrides
--max-lines=N
--max-nesting=N
--max-params=N
--max-branches=N
--max-line-length=N
--max-file-bytes=N

# Output control
-V, --verbose            Verbose output
```

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | No issues found |
| 1 | Issues found |
| 2 | Configuration error |

---

## Inline Disable Directives

```zig
// ephor:disable ZA201
_ = func() catch {};  // No warning

// ephor:disable-next-line ZA301
fn veryLongFunction() void {  // No warning on this line
    // ... 100 lines ...
}

// ephor:disable (disables all rules on this line)
```

---

## Implementation Phases

### Phase 1: Current State (v0.5)
- Pattern-based checks: ZA101, ZA102, ZA201-204, ZA301-304, ZA401, ZA501, ZA601, ZA701
- Basic config file support
- ZA103 (errdefer) implemented as pattern matching (limited accuracy)

### Phase 2: Core Improvements (v0.6) ✓
- [ ] Add profiles system — never shipped. The section was removed (EPH-I1186)
- [x] Add `enable` config option (overrides disable)
- [x] Add ZA402, ZA403 (unused const/var)
- [ ] Improve inline disable parsing (deferred to v0.7)

### Phase 3: Style & Naming (v0.7) ✓
- [x] Add ZA703 naming convention checker
- [x] Add ZA702 file size check
- [x] Fix string literal false positives in naming checker

### Phase 4: CFG Infrastructure (v0.8) ✓
- [x] Build control flow graph (CFG) infrastructure
- [x] Add ZA105 (use-after-free)
- [x] Add ZA106 (double-free)
- [ ] Improve ZA103 accuracy with CFG (optional refinement)

### Phase 5: Error & Null Safety (v0.9) ✓
- [x] Add ZA205 (ignored error union)
- [x] Add ZA801 (optional unwrap without check)
- [x] Add ZA802 (optional deref without check)

### Phase 6: Lifetime Analysis (v1.0)
- [ ] Add ZA901 (stack pointer escapes) - OFF by default
- [ ] Add ZA902 (allocator mismatch) - OFF by default
- [ ] Add ZA903 (resource not closed) - OFF by default

### Phase 7: Version Compatibility (v1.1)
- [ ] Add ZAV01 (deprecated API usage)
- [ ] Add ZAV02 (breaking API changes)
- [ ] Add ZAV03 (new API available)
- [ ] Maintain version compatibility database
- [ ] Add ephor version-check` command

---

## Technical Details: CFG/DFA Infrastructure

This section explains what CFG/DFA infrastructure means and how it enables advanced checks (ZA105-106, ZA205, ZA801-802, ZA901-903).

### Why Pattern Matching Is Not Enough

Current linting uses pattern matching: scan text for `catch {}` or `.alloc(` without nearby `defer`. This works for simple cases but fails when:

```zig
fn example(allocator: Allocator) ![]u8 {
    const data = try allocator.alloc(u8, 100);

    if (some_condition) {
        return data;  // Ownership transferred - no leak
    }

    // ... more code ...

    defer allocator.free(data);  // defer is here, but pattern matcher might miss it
    return try processData(data);
}
```

Pattern matching cannot understand:
- Which execution paths exist
- Whether `defer` covers all paths
- Whether ownership is transferred (returned, stored elsewhere)

### Control Flow Graph (CFG)

A CFG represents all possible execution paths through a function.

**What it is**: A directed graph where:
- **Nodes** = Basic blocks (straight-line code with no branches)
- **Edges** = Possible jumps (if/else, loops, returns, errors)

**Example**:
```zig
fn process(x: i32) !i32 {
    if (x < 0) {           // Block 1: entry + condition
        return error.Negative;  // Block 2: error path
    }
    const result = x * 2;  // Block 3: happy path
    return result;         // Block 4: return
}
```

**CFG**:
```
    [Block 1: entry]
         |
    [if x < 0?]
       /    \
      Y      N
     /        \
[Block 2]  [Block 3]
  |            |
[return     [Block 4]
 error]        |
            [return
             result]
```

**What CFG enables**:
- ZA103: Check if `errdefer` exists on ALL error paths
- Unreachable code detection
- Understanding which paths reach which statements

### Data Flow Analysis (DFA)

DFA tracks how values flow through the CFG.

**What it is**: For each program point, compute what values a variable might hold.

**Example - tracking allocation state**:
```zig
fn example(allocator: Allocator) !void {
    const ptr = try allocator.alloc(u8, 100);  // ptr: ALLOCATED

    if (condition) {
        allocator.free(ptr);                    // ptr: FREED
        return;                                 // exit with ptr FREED ✓
    }

    defer allocator.free(ptr);                  // ptr: WILL_BE_FREED
    // ... use ptr ...
    return;                                     // exit with ptr WILL_BE_FREED ✓
}
```

**State lattice for allocation tracking**:
```
         ⊤ (unknown)
        / | \
       /  |  \
ALLOCATED FREED WILL_BE_FREED
       \  |  /
        \ | /
         ⊥ (unreachable)
```

**What DFA enables**:
- ZA101/ZA102: Leak detection - ptr is ALLOCATED at function exit without FREED or WILL_BE_FREED
- ZA105: Use-after-free - ptr is FREED but then accessed
- ZA801: Null safety - optional is UNCHECKED but then dereferenced

### Implementation Approach

**Phase 4.1: CFG Construction**
```
Input: Zig AST (from std.zig.Ast)
Output: CFG with basic blocks and edges

Steps:
1. Parse file with std.zig.Ast
2. Walk function bodies
3. Create basic blocks at branch points (if, switch, while, for, try, catch)
4. Connect blocks with edges
5. Mark entry/exit blocks
```

**Phase 4.2: Basic DFA Framework**
```
Input: CFG + analysis definition (what to track)
Output: Facts at each program point

Algorithm (worklist):
1. Initialize all blocks with ⊥ (bottom)
2. Add entry block to worklist with initial facts
3. While worklist not empty:
   a. Pop block from worklist
   b. Compute transfer function (how block changes facts)
   c. Propagate to successors
   d. If successor facts changed, add to worklist
4. Reached fixpoint when worklist empty
```

**Phase 4.3: Specific Analyses**

| Analysis | Tracks | Lattice |
|----------|--------|---------|
| Allocation state | ptr → {Allocated, Freed, WillBeFreed} | 3-element |
| Null check | optional → {Checked, Unchecked} | 2-element |
| Error handling | result → {Handled, Unhandled} | 2-element |

### Complexity and Performance

**Time complexity**: O(n × h) where n = CFG nodes, h = lattice height
- Small lattices (2-4 elements) = fast convergence
- Typical function: 10-50 blocks × 2-4 iterations = sub-millisecond

**Memory**: O(n × v) where v = tracked variables per block
- Only track allocations, optionals, error unions (not all variables)
- Scope to single function (no interprocedural analysis in v1.0)

**Why CFG-based checks are slower**:
- Must parse full AST (not just text patterns)
- Must build CFG for each function
- Must iterate to fixpoint
- But still O(seconds) not O(minutes) for typical projects

All checks are fast enough to run on every lint. No need for separate modes.

### Design Principle: Do Not Duplicate Zig Tools

| Zig Tool | What It Does | Ephor Does NOT Duplicate |
|----------|--------------|-------------------------------|
| `zig fmt` | Formatting | We wrap `zig fmt --check`, do not reimplement |
| `zig build` | Compilation, type checking | We use compiler output for type info if needed |
| `zig build test` | Runtime behavior | We do static analysis only |

**If the Zig compiler already does it, we use it - do not rebuild it.**

For advanced checks:
- Need type info? → Parse `zig build` output or use AST hints
- Need to know if code compiles? → Run `zig build` first
- Complex type inference? → That is the compiler's job

The linter focuses on **single-function analysis** with simple state tracking. This catches common bugs (leaks, null derefs, ignored errors) that slip past the compiler but do not require rebuilding compiler internals.

---

## Design Decisions (Resolved)

### 1. ZA204 (undefined initialization)

**Decision**: ON by default

`= undefined` can leak sensitive data if memory is reused. The linter warns about this as a best practice. Users who want to suppress can disable:
```json
{ "disable": ["ZA204"] }
```

### 2. ZA701 (line length)

**Decision**: ON by default (100 columns)

A 100-column limit matches major Zig project style guides (TigerBeetle, Bun) and accommodates Zig's 4-space indentation. Users can adjust the threshold:
```json
{ "thresholds": { "max_line_length": 120 } }
```
Or disable entirely:
```json
{ "disable": ["ZA701"] }
```

### 3. ZA703 (naming conventions)

**Decision**: ON by default (when implemented)

Zig's compiler does not enforce naming, but the community has clear documented standards. Ephor will enforce community conventions:
- Types (struct, enum, union): `TitleCase`
- Enum fields: `snake_case`
- Error set values: `TitleCase`
- Type-returning functions: `TitleCase`
- Functions: `camelCase`
- Variables/constants: `snake_case`
- Namespaces (0-field struct): `snake_case`

**Status**: Not yet implemented.

### 4. Auto-Fix

**Decision**: No auto-fix

Ephor is a linter, not a formatter. Use `zig fmt` for formatting fixes. The tool reports issues; the developer fixes them.

Rationale:
- `zig fmt` is the official formatting tool - do not duplicate
- Auto-fixing code changes can introduce bugs
- Keep the tool simple and focused on detection

### 5. No Separate Modes

**Decision**: Single mode, no `--deep` flag

All checks run together. If a check is helpful, it is ON by default. If it is expensive, it is OFF by default but easily enabled via config.

Rationale:
- Simpler mental model for users
- All checks are fast enough to run together
- Configuration handles opt-in/opt-out

### 6. ZA9xx Lifetime Checks

**Decision**: OFF by default, easily enabled

ZA901-903 are more expensive and may have more false positives. Users who want deeper safety guarantees can enable:
```json
{ "enable": ["ZA9"] }
```

---

## Appendix: Zig Official Style Reference

From Zig documentation:

### Naming Conventions

| Identifier Type | Convention | Example |
|-----------------|------------|---------|
| Types (struct, enum, union) | TitleCase | `Point`, `Color`, `FileError` |
| Enum fields | snake_case | `.blue`, `.file_not_found` |
| Error set values | TitleCase | `FileNotFound`, `AccessDenied` |
| Type-returning functions | TitleCase | `@TypeOf`, `Point(comptime T)` |
| Functions | camelCase | `addOne`, `getValue` |
| Variables | snake_case | `my_var`, `loop_count` |
| Constants | snake_case | `max_value` |
| Namespaces (0-field struct) | snake_case | `const std = @import("std")` |

**Note**: Error set values are TitleCase (like types), but regular enum fields are snake_case.

### What `zig fmt` Enforces

- Indentation (4 spaces)
- Brace positions
- Whitespace around operators
- Trailing commas in multi-line constructs

### What `zig fmt` Does NOT Enforce

- Line length limits
- Naming conventions
- File organization
- Comment style

---

## References

- [Zig Language Reference - Style Guide](https://ziglang.org/documentation/master/#Style-Guide)
- [Nathan Craddock - Zig naming conventions](https://nathancraddock.com/blog/zig-naming-conventions/)
- [Clippy Documentation](https://doc.rust-lang.org/clippy/)
- [Clang-Tidy Documentation](https://clang.llvm.org/extra/clang-tidy/)
- [Clang Data Flow Analysis](https://clang.llvm.org/docs/DataFlowAnalysisIntro.html)
