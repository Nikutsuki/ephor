// Rhyos Labs - Ephor
// Error handling analysis module
// Copyright (C) 2025 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const types = @import("../types.zig");
const Issue = types.Issue;
const FileAnalysis = types.FileAnalysis;

// ============================================================================
// Test Context Detection
// ============================================================================

/// Check if code is in a test context
pub fn isInTestContext(path: []const u8, in_test_block: bool) bool {
    if (in_test_block) return true;
    if (mem.indexOf(u8, path, "_test.zig") != null) return true;
    if (mem.indexOf(u8, path, "/test") != null) return true;
    return false;
}

/// Track test block state
pub fn trackTestBlock(
    t: []const u8,
    in_test: bool,
    depth: usize,
) struct { in_test: bool, depth: usize } {
    var current_in_test = in_test;
    var current_depth = depth;

    if (mem.startsWith(u8, t, "test ")) {
        current_in_test = true;
        current_depth = 0;
    }

    for (t) |c| {
        if (c == '{') current_depth += 1;
        if (c == '}') {
            if (current_depth > 0) current_depth -= 1;
            if (current_depth == 0 and current_in_test) {
                current_in_test = false;
            }
        }
    }

    return .{ .in_test = current_in_test, .depth = current_depth };
}

// ============================================================================
// Issue Checkers
// ============================================================================

/// Check for silent catch {}
/// Skip in defer/errdefer where best-effort cleanup is intentional
pub fn checkSilentCatch(
    t: []const u8,
    path: []const u8,
    line: usize,
) ?Issue {
    // In defer/errdefer, catch {} is intentional for best-effort cleanup
    if (mem.startsWith(u8, t, "defer ") or mem.startsWith(u8, t, "errdefer ")) {
        return null;
    }
    const col = mem.indexOf(u8, t, "catch {}") orelse return null;
    if (types.isInsideString(t, col)) return null;
    return .{
        .file = path,
        .line = line,
        .col = col + 1,
        .severity = .note,
        .rule = types.RULE_SILENT_CATCH,
        .message = "silent catch {} discards error",
        .help = "use catch |err| with logging, or propagate with try",
    };
}

/// Check for catch unreachable
pub fn checkCatchUnreachable(
    t: []const u8,
    path: []const u8,
    line: usize,
    in_test: bool,
) ?Issue {
    _ = in_test;
    const col = mem.indexOf(u8, t, "catch unreachable") orelse return null;
    if (types.isInsideString(t, col)) return null;
    return .{
        .file = path,
        .line = line,
        .col = col + 1,
        .severity = .note,
        .rule = types.RULE_CATCH_UNREACHABLE,
        .message = "catch unreachable will panic if error occurs",
        .help = "consider explicit error handling",
    };
}

/// Check for orelse unreachable
pub fn checkOrelseUnreachable(
    t: []const u8,
    path: []const u8,
    line: usize,
    in_test: bool,
) ?Issue {
    _ = in_test;
    const col = mem.indexOf(u8, t, "orelse unreachable") orelse return null;
    if (types.isInsideString(t, col)) return null;
    return .{
        .file = path,
        .line = line,
        .col = col + 1,
        .severity = .note,
        .rule = types.RULE_ORELSE_UNREACHABLE,
        .message = "orelse unreachable will panic if null",
        .help = "consider explicit null handling or validation",
    };
}

/// Check for undefined usage
pub fn checkUndefinedUsage(
    t: []const u8,
    path: []const u8,
    line: usize,
) ?Issue {
    const col = mem.indexOf(u8, t, "= undefined") orelse return null;
    if (types.isInsideString(t, col)) return null;
    return .{
        .file = path,
        .line = line,
        .col = col + 1,
        .severity = .note,
        .rule = types.RULE_UNDEFINED_USAGE,
        .message = "uninitialized memory may cause UB",
        .help = "use explicit initialization or std.mem.zeroes()",
    };
}

/// Check for discarded result
pub fn checkDiscardedResult(
    t: []const u8,
    path: []const u8,
    line: usize,
) ?Issue {
    const col = mem.indexOf(u8, t, "_ = ") orelse return null;
    if (types.isInsideString(t, col) or isSafeToDiscard(t)) return null;
    return .{
        .file = path,
        .line = line,
        .col = col + 1,
        .severity = .note,
        .rule = types.RULE_IGNORED_ERROR,
        .message = "discarded result may contain error",
        .help = "consider handling the result or using try",
    };
}

/// Check if a discarded result is safe
fn isSafeToDiscard(t: []const u8) bool {
    const skip_patterns = [_][]const u8{
        ".destroy(",
        ".free(",
        ".pop(",
        ".clear(",
        ".deinit(",
        "print(",
        "debug.print(",
        ".close(",
    };

    for (skip_patterns) |pattern| {
        if (mem.indexOf(u8, t, pattern) != null) return true;
    }
    return false;
}

// ============================================================================
// Public API
// ============================================================================

fn appendIfPresent(
    allocator: Allocator,
    issue: ?Issue,
    issues: *std.ArrayListUnmanaged(Issue),
) !void {
    if (issue) |i| try issues.append(allocator, i);
}

fn analyzeFile(
    allocator: Allocator,
    a: FileAnalysis,
    issues: *std.ArrayListUnmanaged(Issue),
) !void {
    var line_num: usize = 1;
    var lines = mem.splitScalar(u8, a.content, '\n');
    var in_test = false;
    var test_depth: usize = 0;

    while (lines.next()) |line| {
        defer line_num += 1;
        const t = mem.trim(u8, line, " \t\r");

        if (mem.startsWith(u8, t, "\\\\") or mem.startsWith(u8, t, "//")) continue;

        const state = trackTestBlock(t, in_test, test_depth);
        in_test = state.in_test;
        test_depth = state.depth;

        try appendIfPresent(allocator, checkSilentCatch(t, a.path, line_num), issues);
        try appendIfPresent(
            allocator,
            checkCatchUnreachable(t, a.path, line_num, in_test),
            issues,
        );
        try appendIfPresent(
            allocator,
            checkOrelseUnreachable(t, a.path, line_num, in_test),
            issues,
        );
    }
}

/// Analyze error handling patterns in all files
pub fn analyze(
    allocator: Allocator,
    graph: anytype,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    var iter = graph.files.iterator();

    while (iter.next()) |entry| {
        try analyzeFile(allocator, entry.value_ptr.*, &issues);
    }

    return issues;
}

// ============================================================================
// Tests
// ============================================================================

test "checkSilentCatch detects catch {}" {
    const issue = checkSilentCatch("result catch {}", "test.zig", 1);
    try std.testing.expect(issue != null);
}

test "checkCatchUnreachable detects catch unreachable" {
    const t = "x catch unreachable";
    const issue = checkCatchUnreachable(t, "test.zig", 1, false);
    try std.testing.expect(issue != null);
}

test "isInTestContext detects test files" {
    try std.testing.expect(isInTestContext("foo_test.zig", false));
    try std.testing.expect(isInTestContext("src/test/bar.zig", false));
    try std.testing.expect(!isInTestContext("src/main.zig", false));
}
