// Rhyos Labs - Ephor
// Shared types for all analyzer modules
// Copyright (C) 2025 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ============================================================================
// Rule IDs (for suppression and documentation)
// ============================================================================

// ZA1xx - Memory
pub const RULE_ALLOC_NO_DEFER = "ZA101";
pub const RULE_CREATE_NO_DEFER = "ZA102";
pub const RULE_ALLOC_NO_ERRDEFER = "ZA103";
pub const RULE_USE_AFTER_FREE = "ZA105";
pub const RULE_DOUBLE_FREE = "ZA106";
pub const RULE_MUST_RETURN_REF = "ZA110";
pub const RULE_RETURNED_STACK_REF = "ZA111";

// ZA2xx - Error handling patterns (warnings; ZA205/ZA208/ZA209/ZA210 are notes)
pub const RULE_SILENT_CATCH = "ZA201";
pub const RULE_CATCH_UNREACHABLE = "ZA202";
pub const RULE_ORELSE_UNREACHABLE = "ZA203";
pub const RULE_UNDEFINED_USAGE = "ZA204";
pub const RULE_IGNORED_ERROR = "ZA205";
pub const RULE_EXIT_BYPASSES_DEFER = "ZA206";
pub const RULE_CATCH_UNDEFINED = "ZA207";
pub const RULE_PANIC = "ZA208";
pub const RULE_USELESS_ERROR_RETURN = "ZA209";
pub const RULE_NO_CATCH_RETURN = "ZA210";

// ZA3xx - Complexity
pub const RULE_FUNC_TOO_LONG = "ZA301";
pub const RULE_NESTING_TOO_DEEP = "ZA302";
pub const RULE_TOO_MANY_PARAMS = "ZA303";
pub const RULE_TOO_MANY_BRANCHES = "ZA304";
pub const RULE_CYCLOMATIC = "ZA305";
pub const RULE_COGNITIVE = "ZA306";

// ZA4xx - Unused
pub const RULE_UNUSED_IMPORT = "ZA401";
pub const RULE_UNUSED_CONST = "ZA402";
pub const RULE_UNUSED_VAR = "ZA403";

// ZA5xx - Structure
pub const RULE_ORPHAN_FILE = "ZA501";

// ZA6xx - Formatting (ZA607 is a semantic definite-assignment check that kept
// its ZA6xx ID for backward compatibility with existing inline-ignores)
pub const RULE_NEEDS_FORMAT = "ZA601";
pub const RULE_DEFINITE_ASSIGNMENT = "ZA607";

// ZA7xx - Style
pub const RULE_LINE_TOO_LONG = "ZA701";
pub const RULE_FILE_TOO_LONG = "ZA702";
pub const RULE_NAMING_CONVENTION = "ZA703";
// ZA704 (std.debug.print) is RETIRED — removed in 0.14.0 as intent-based
// (EPH-I0049). Never reuse the ID: consumer inline-ignores reference it.

// ZA8xx - Null Safety
pub const RULE_OPTIONAL_UNWRAP_UNSAFE = "ZA801";
pub const RULE_ORELSE_QUESTION_UNSAFE = "ZA802";

// ZA9xx - Panic/Overflow Detection
pub const RULE_DECREMENT_WITHOUT_CHECK = "ZA901";
pub const RULE_INDEX_ARITHMETIC = "ZA903";
pub const RULE_INTCAST_NO_BOUNDS = "ZA904";

// ZR1xx - Runtime Analysis (dynamic analysis via test execution)
pub const RULE_RUNTIME_MEMORY_LEAK = "ZR101";
pub const RULE_RUNTIME_DOUBLE_FREE = "ZR102";
pub const RULE_RUNTIME_USE_AFTER_FREE = "ZR103";
pub const RULE_RUNTIME_TEST_FAILURE = "ZR104";
pub const RULE_RUNTIME_PANIC = "ZR105";

// ZT1xx - Tests
pub const RULE_TEST_LIE = "ZT101";
pub const RULE_TEST_NO_ASSERTIONS = "ZT102";
pub const RULE_TEST_TRIVIAL_ASSERT = "ZT103";
pub const RULE_TEST_SWALLOWED_ERROR = "ZT104";
pub const RULE_TEST_UNTESTED_PUBLIC_FN = "ZT105";

// ZC1xx - Concurrency
pub const RULE_LOCK_NO_DEFER_UNLOCK = "ZC101";
pub const RULE_DOUBLE_LOCK = "ZC102";
pub const RULE_UNLOCK_WITHOUT_LOCK = "ZC103";
pub const RULE_THREAD_NO_JOIN = "ZC104";

// ============================================================================
// Return Type Classification (for type-based detection)
// ============================================================================

pub const ReturnKind = enum {
    void_type, // void — safe to discard
    error_union, // !void, !T — NOT safe (ZA205)
    value, // u32, []u8 — safe to discard
    optional, // ?T — safe to discard
    noreturn_type, // noreturn — safe
    unknown, // can't determine — fall through to legacy
};

// ============================================================================
// Severity Levels
// ============================================================================

pub const Severity = enum {
    err, // error - should fail CI
    warning, // warning - should be fixed
    note, // note - informational

    pub fn str(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .note => "note",
        };
    }
};

// ============================================================================
// Output Formats
// ============================================================================

pub const OutputFormat = enum {
    text, // Standard GCC-style: path:line:col: severity[rule]: message
    json, // JSON array for IDE integration
};

// ============================================================================
// Strict CI Gating
// ============================================================================

/// Severity level at which findings fail the run (exit 1).
/// --strict is exactly .warning; .never keeps findings informational.
pub const FailOn = enum {
    never, // findings never fail the run (default)
    err, // fail only on error-severity findings
    warning, // fail on warnings + errors (== --strict)
    note, // fail on any finding, notes included

    pub fn str(self: FailOn) []const u8 {
        return switch (self) {
            .never => "never",
            .err => "error",
            .warning => "warning",
            .note => "note",
        };
    }

    pub fn fromString(s: []const u8) ?FailOn {
        if (std.mem.eql(u8, s, "never")) return .never;
        if (std.mem.eql(u8, s, "error")) return .err;
        if (std.mem.eql(u8, s, "warning")) return .warning;
        if (std.mem.eql(u8, s, "note")) return .note;
        return null;
    }
};

// ============================================================================
// Error Naming Convention (ZA703)
// ============================================================================

/// Which convention ZA703 enforces for error values and error set members.
/// The stdlib and virtually all community code use TitleCase error names, so
/// that is the default; snake_case preserves the pre-flip ZA703 behavior for
/// projects that adopted it.
pub const ErrorNaming = enum {
    title_case, // error.FileNotFound (default, community standard)
    snake_case, // error.file_not_found (pre-flip ZA703 default)

    pub fn str(self: ErrorNaming) []const u8 {
        return switch (self) {
            .title_case => "TitleCase",
            .snake_case => "snake_case",
        };
    }

    /// "PascalCase" is accepted as an alias for TitleCase (common spelling).
    pub fn fromString(s: []const u8) ?ErrorNaming {
        if (std.mem.eql(u8, s, "TitleCase")) return .title_case;
        if (std.mem.eql(u8, s, "PascalCase")) return .title_case;
        if (std.mem.eql(u8, s, "snake_case")) return .snake_case;
        return null;
    }
};

// ============================================================================
// Core Types
// ============================================================================

pub const ImportInfo = struct {
    path: []const u8,
    resolved: ?[]const u8,
    name: []const u8,
    line: usize,
    col: usize,
    is_pub: bool = false, // True for `pub const X = @import()` re-exports
};

pub const Issue = struct {
    file: []const u8,
    line: usize,
    col: usize,
    severity: Severity,
    rule: []const u8,
    message: []const u8,
    help: ?[]const u8,
    message_owned: bool = false,

    pub fn deinit(self: *Issue, allocator: Allocator) void {
        if (self.message_owned) {
            allocator.free(self.message);
            self.message_owned = false;
        }
    }

    pub fn printText(self: Issue, base_path: []const u8) void {
        const rel_path = relativePath(self.file, base_path);
        // File-level issues (line=1, col=1) show just filename, no confusing :1:1
        if (self.line == 1 and self.col == 1) {
            std.debug.print("{s}: {s}[{s}]: {s}\n", .{
                rel_path,
                self.severity.str(),
                self.rule,
                self.message,
            });
        } else {
            std.debug.print("{s}:{d}:{d}: {s}[{s}]: {s}\n", .{
                rel_path,
                self.line,
                self.col,
                self.severity.str(),
                self.rule,
                self.message,
            });
        }
        if (self.help) |h| {
            std.debug.print("  help: {s}\n", .{h});
        }
    }

    pub fn printJson(
        self: Issue,
        base_path: []const u8,
        is_last: bool,
    ) void {
        const rel_path = relativePath(self.file, base_path);
        std.debug.print("  {{\n", .{});
        std.debug.print("    \"file\": \"{s}\",\n", .{rel_path});
        std.debug.print("    \"line\": {d},\n", .{self.line});
        std.debug.print("    \"column\": {d},\n", .{self.col});
        std.debug.print("    \"severity\": \"{s}\",\n", .{
            self.severity.str(),
        });
        std.debug.print("    \"rule\": \"{s}\",\n", .{self.rule});
        std.debug.print("    \"message\": \"{s}\"", .{self.message});
        if (self.help) |h| {
            std.debug.print(",\n    \"help\": \"{s}\"\n", .{h});
        } else {
            std.debug.print("\n", .{});
        }
        if (is_last) {
            std.debug.print("  }}\n", .{});
        } else {
            std.debug.print("  }},\n", .{});
        }
    }
};

pub const Thresholds = struct {
    max_function_lines: usize = 50,
    max_nesting_depth: usize = 3,
    max_params: usize = 4,
    max_branches: usize = 12,
    max_line_length: usize = 100,
    max_file_bytes: usize = 50_000,
    max_cyclomatic: usize = 15,
    max_cognitive: usize = 15,
};

pub const ProjectStats = struct {
    total_files: usize = 0,
    total_lines: usize = 0,
    code_lines: usize = 0,
    comment_lines: usize = 0,
    blank_lines: usize = 0,
    test_count: usize = 0,
    pub_fn_count: usize = 0,
    not_implemented_count: usize = 0,
    todo_count: usize = 0,
    files_with_tests: usize = 0,
};

pub const FileAnalysis = struct {
    path: []const u8,
    /// Cached realpath of `path`, resolved once at ingest time.
    /// When realpath fails (e.g. file no longer exists), this falls back
    /// to `path`. Avoids per-lookup realpath calls in the import graph —
    /// re-resolving on every `findImportsForPath` call scaled O(N²) and
    /// blew up to millions of openat syscalls on large codebases.
    resolved_path: []const u8,
    imports: std.ArrayListUnmanaged(ImportInfo),
    content: []const u8,
    has_tests: bool,
    pub_function_count: usize,
    line_count: usize,

    pub fn deinit(self: *FileAnalysis, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.resolved_path.ptr != self.path.ptr) {
            allocator.free(self.resolved_path);
        }
        for (self.imports.items) |import| {
            allocator.free(import.path);
            if (import.resolved) |r| allocator.free(r);
            allocator.free(import.name);
        }
        self.imports.deinit(allocator);
        allocator.free(self.content);
    }
};

// ============================================================================
// Utility Functions
// ============================================================================

/// Properly deinit an issues array, freeing any owned messages
pub fn deinitIssues(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
) void {
    for (issues.items) |*issue| {
        issue.deinit(allocator);
    }
    issues.deinit(allocator);
}

pub fn relativePath(path: []const u8, base: []const u8) []const u8 {
    if (mem.startsWith(u8, path, base)) {
        var result = path[base.len..];
        while (result.len > 0 and result[0] == '/') {
            result = result[1..];
        }
        return if (result.len > 0) result else path;
    }
    return path;
}

pub fn countOccurrences(h: []const u8, n: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i + n.len <= h.len) : (i += 1) {
        if (mem.eql(u8, h[i .. i + n.len], n)) count += 1;
    }
    return count;
}

pub fn countLines(content: []const u8) usize {
    var count: usize = 1;
    for (content) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

pub fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Check if position `col` is inside a string literal
/// Handles escape sequences correctly:
///   "normal"     - quotes toggle string state
///   "with \" "   - escaped quote doesn't toggle
///   "with \\" x  - escaped backslash, quote DOES toggle
///   "with \\\" " - escaped backslash + escaped quote
pub fn isInsideString(line: []const u8, col: usize) bool {
    var in_string = false;
    var i: usize = 0;
    while (i < col and i < line.len) : (i += 1) {
        if (line[i] != '"') continue;
        // Count consecutive backslashes before this quote
        var backslash_count: usize = 0;
        var j = i;
        while (j > 0 and line[j - 1] == '\\') {
            backslash_count += 1;
            j -= 1;
        }
        // Quote is escaped only if odd number of backslashes
        // Even backslashes = pairs of escaped backslashes, quote is real
        if (backslash_count % 2 == 0) {
            in_string = !in_string;
        }
    }
    return in_string;
}

/// Check if a rule is disabled via inline comment
pub fn isInlineDisabled(
    content: []const u8,
    line_num: usize,
    rule: []const u8,
) bool {
    var lines = mem.splitScalar(u8, content, '\n');
    var current_line: usize = 1;

    while (lines.next()) |line| {
        if (current_line == line_num or current_line == line_num - 1) {
            if (checkDisableComment(line, rule)) return true;
        }
        if (current_line > line_num) break;
        current_line += 1;
    }
    return false;
}

fn checkDisableComment(line: []const u8, rule: []const u8) bool {
    const patterns = [_][]const u8{
        "// ephor-disable",
        "// zig-lint-disable",
        "// nolint",
    };

    for (patterns) |pattern| {
        const idx = mem.indexOf(u8, line, pattern) orelse continue;
        const rest = line[idx + pattern.len ..];
        // Disabled all rules
        if (rest.len == 0 or rest[0] == '\n' or rest[0] == '\r') {
            return true;
        }
        // Check specific rule
        if (mem.indexOf(u8, rest, rule) != null) return true;
        // "next-line" applies to next line
        if (mem.indexOf(u8, rest, "next-line") != null) return true;
    }
    return false;
}

pub fn skipWhitespace(
    content: []const u8,
    start: usize,
    skip_comma: bool,
) usize {
    var i = start;
    while (i < content.len) : (i += 1) {
        const c = content[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
        if (skip_comma and c == ',') continue;
        break;
    }
    return i;
}

// ============================================================================
// Tests
// ============================================================================

test "relativePath removes base" {
    const result = relativePath("/foo/bar/baz.zig", "/foo/bar");
    try std.testing.expectEqualStrings("baz.zig", result);
}

test "countOccurrences counts correctly" {
    try std.testing.expectEqual(@as(usize, 3), countOccurrences("ababa", "a"));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences("ababa", "ab"));
}

test "countLines counts newlines" {
    try std.testing.expectEqual(@as(usize, 3), countLines("a\nb\nc"));
    try std.testing.expectEqual(@as(usize, 1), countLines("no newlines"));
}

test "isInsideString detects strings" {
    try std.testing.expect(isInsideString("const x = \"hello", 14));
    try std.testing.expect(!isInsideString("const x = 42", 8));
}

test "ReturnKind has all expected variants" {
    const rk: ReturnKind = .void_type;
    try std.testing.expect(rk == .void_type);
    try std.testing.expect(ReturnKind.error_union != .void_type);
    try std.testing.expect(ReturnKind.value != .error_union);
    try std.testing.expect(ReturnKind.optional != .value);
    try std.testing.expect(ReturnKind.noreturn_type != .optional);
    try std.testing.expect(ReturnKind.unknown != .noreturn_type);
}
