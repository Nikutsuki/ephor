// Rhyos Labs - Ephor
// Complexity analysis module
// Copyright (C) 2025 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const types = @import("../types.zig");
const Issue = types.Issue;
const Thresholds = types.Thresholds;
const FileAnalysis = types.FileAnalysis;

// ============================================================================
// Helpers
// ============================================================================

/// Check if function is a comptime type factory
pub fn isTypeFactory(line: []const u8) bool {
    if (mem.indexOf(u8, line, ") type")) |_| return true;
    const trimmed = mem.trim(u8, line, " \t\r");
    if (mem.endsWith(u8, trimmed, ") type")) return true;
    return false;
}

/// Check if line starts an inline loop (compile-time unrolled)
fn isInlineLoop(t: []const u8) bool {
    if (mem.indexOf(u8, t, "inline for") != null) return true;
    if (mem.indexOf(u8, t, "inline while") != null) return true;
    return false;
}

/// Count keyword at position with boundary check
fn countKeyword(t: []const u8, kw: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i + kw.len <= t.len) : (i += 1) {
        if (!mem.eql(u8, t[i .. i + kw.len], kw)) continue;
        if (i > 0 and types.isIdent(t[i - 1])) continue;
        count += 1;
    }
    return count;
}

/// Count if statements (excluding else if)
fn countIfStatements(t: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i + 3 <= t.len) : (i += 1) {
        if (!mem.eql(u8, t[i .. i + 3], "if ")) continue;
        if (i > 0 and types.isIdent(t[i - 1])) continue;
        if (i >= 5 and mem.eql(u8, t[i - 5 .. i], "else ")) continue;
        count += 1;
    }
    return count;
}

/// Count else (excluding else if)
fn countElseStatements(t: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i + 4 < t.len) : (i += 1) {
        if (!mem.eql(u8, t[i .. i + 4], "else")) continue;
        const after = i + 4;
        if (after < t.len and t[after] != ' ' and t[after] != '{') continue;
        if (after + 3 <= t.len and mem.eql(u8, t[after .. after + 3], " if")) continue;
        count += 1;
    }
    return count;
}

/// Count branches in a line (if/else/switch/for/while)
fn countBranchesInLine(t: []const u8) usize {
    if (isInlineLoop(t)) return 0;
    return countIfStatements(t) + countElseStatements(t) +
        countKeyword(t, "switch") + countKeyword(t, "for") + countKeyword(t, "while");
}

// ============================================================================
// Function Metrics
// ============================================================================

/// Count parameters in function signature
fn countParams(line: []const u8) usize {
    const open = mem.indexOf(u8, line, "(") orelse return 0;
    const close = mem.indexOf(u8, line, ")") orelse return 0;
    if (close <= open + 1) return 0;

    const params = line[open + 1 .. close];
    if (params.len == 0) return 0;

    var count: usize = 1;
    for (params) |c| {
        if (c == ',') count += 1;
    }
    return count;
}

/// Extract function name from line
fn extractFunctionName(line: []const u8) ?[]const u8 {
    const fn_pos = mem.indexOf(u8, line, "fn ") orelse return null;
    const start = fn_pos + 3;
    var end = start;
    while (end < line.len and (types.isIdent(line[end]))) end += 1;
    if (end > start) return line[start..end];
    return null;
}

// ============================================================================
// File Analysis
// ============================================================================

const FnMetrics = struct {
    depth: usize = 0,
    max_nest: usize = 0,
    branches: usize = 0,
    params: usize = 0,
    fn_start: usize = 0,
    in_fn: bool = false,
};

const FnLimits = struct {
    lines: usize,
    nesting: usize,
    branches: usize,
    params: usize,
};

fn calcLimits(th: Thresholds, is_tf: bool) FnLimits {
    const lm = if (is_tf) @as(usize, 3) else @as(usize, 1);
    const nm = if (is_tf) @as(usize, 2) else @as(usize, 1);
    return .{
        .lines = th.max_function_lines * lm,
        .nesting = th.max_nesting_depth * nm,
        .branches = th.max_branches * lm,
        .params = th.max_params,
    };
}

fn trackDepth(t: []const u8, m: *FnMetrics) bool {
    for (t) |c| {
        if (c == '{') {
            m.depth += 1;
            if (m.depth > m.max_nest) m.max_nest = m.depth;
        }
        if (c == '}' and m.depth > 0) {
            m.depth -= 1;
            if (m.depth == 0) return true;
        }
    }
    return false;
}

const ReportCtx = struct {
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    path: []const u8,
    line: usize,
    name: []const u8,
    th: Thresholds,
};

fn reportIfNeeded(
    ctx: ReportCtx,
    m: *const FnMetrics,
    lim: FnLimits,
    fn_len: usize,
) !void {
    if (fn_len > lim.lines) try reportLongFunction(
        ctx.allocator,
        ctx.issues,
        ctx.path,
        ctx.line,
        ctx.name,
        fn_len,
        ctx.th.max_function_lines,
    );
    if (m.max_nest > lim.nesting) try reportDeepNesting(
        ctx.allocator,
        ctx.issues,
        ctx.path,
        ctx.line,
        ctx.name,
        m.max_nest,
        ctx.th.max_nesting_depth,
    );
    if (m.branches > lim.branches) try reportHighBranches(
        ctx.allocator,
        ctx.issues,
        ctx.path,
        ctx.line,
        ctx.name,
        m.branches,
        ctx.th.max_branches,
    );
    if (m.params > lim.params) try reportManyParams(
        ctx.allocator,
        ctx.issues,
        ctx.path,
        ctx.line,
        ctx.name,
        m.params,
        ctx.th.max_params,
    );
}

/// Analyze a single function's complexity
fn analyzeFunction(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    path: []const u8,
    content: []const u8,
    thresholds: Thresholds,
    fn_line: usize,
    fn_name: []const u8,
    is_type_factory: bool,
) !void {
    var lines = mem.splitScalar(u8, content, '\n');
    var line_num: usize = 0;
    var m = FnMetrics{};
    const lim = calcLimits(thresholds, is_type_factory);
    const ctx = ReportCtx{
        .allocator = allocator,
        .issues = issues,
        .path = path,
        .line = fn_line,
        .name = fn_name,
        .th = thresholds,
    };

    while (lines.next()) |line| {
        line_num += 1;
        const t = mem.trim(u8, line, " \t\r");

        if (line_num != fn_line and !m.in_fn) continue;
        if (line_num == fn_line) {
            m.in_fn = true;
            m.fn_start = line_num;
            m.params = countParams(t);
        }

        if (!trackDepth(t, &m)) {
            m.branches += countBranchesInLine(t);
            continue;
        }
        try reportIfNeeded(ctx, &m, lim, line_num - m.fn_start + 1);
        return;
    }
}

// ============================================================================
// Issue Reporters
// ============================================================================

fn reportLongFunction(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    path: []const u8,
    line: usize,
    name: []const u8,
    actual: usize,
    max: usize,
) !void {
    const msg = try std.fmt.allocPrint(
        allocator,
        "function '{s}' has {d} lines (max {d})",
        .{ name, actual, max },
    );
    try issues.append(allocator, .{
        .file = path,
        .line = line,
        .col = 1,
        .severity = .warning,
        .rule = types.RULE_FUNC_TOO_LONG,
        .message = msg,
        .help = "split into smaller functions",
        .message_owned = true,
    });
}

fn reportDeepNesting(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    path: []const u8,
    line: usize,
    name: []const u8,
    actual: usize,
    max: usize,
) !void {
    const msg = try std.fmt.allocPrint(
        allocator,
        "function '{s}' has nesting depth {d} (max {d})",
        .{ name, actual, max },
    );
    try issues.append(allocator, .{
        .file = path,
        .line = line,
        .col = 1,
        .severity = .warning,
        .rule = types.RULE_NESTING_TOO_DEEP,
        .message = msg,
        .help = "use early returns or extract nested logic",
        .message_owned = true,
    });
}

fn reportHighBranches(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    path: []const u8,
    line: usize,
    name: []const u8,
    actual: usize,
    max: usize,
) !void {
    const msg = try std.fmt.allocPrint(
        allocator,
        "function '{s}' has {d} branches (max {d})",
        .{ name, actual, max },
    );
    try issues.append(allocator, .{
        .file = path,
        .line = line,
        .col = 1,
        .severity = .warning,
        .rule = types.RULE_TOO_MANY_BRANCHES,
        .message = msg,
        .help = "simplify logic or use lookup tables",
        .message_owned = true,
    });
}

fn reportManyParams(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    path: []const u8,
    line: usize,
    name: []const u8,
    actual: usize,
    max: usize,
) !void {
    const msg = try std.fmt.allocPrint(
        allocator,
        "function '{s}' has {d} parameters (max {d})",
        .{ name, actual, max },
    );
    try issues.append(allocator, .{
        .file = path,
        .line = line,
        .col = 1,
        .severity = .warning,
        .rule = types.RULE_TOO_MANY_PARAMS,
        .message = msg,
        .help = "group parameters into a struct",
        .message_owned = true,
    });
}

// ============================================================================
// Public API
// ============================================================================

/// Analyze a single file for function complexity
fn analyzeFileComplexity(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    a: *const types.FileAnalysis,
    th: Thresholds,
) !void {
    var line_num: usize = 0;
    var lines = mem.splitScalar(u8, a.content, '\n');

    while (lines.next()) |line| {
        line_num += 1;
        const t = mem.trim(u8, line, " \t\r");
        if (mem.startsWith(u8, t, "//")) continue;
        if (mem.indexOf(u8, t, "fn ") == null) continue;
        const name = extractFunctionName(t) orelse continue;
        try analyzeFunction(
            allocator,
            issues,
            a.path,
            a.content,
            th,
            line_num,
            name,
            isTypeFactory(t),
        );
    }
}

/// Analyze complexity of all functions in all files
pub fn analyze(
    allocator: Allocator,
    graph: anytype,
    thresholds: Thresholds,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    var iter = graph.files.iterator();

    while (iter.next()) |entry| {
        try analyzeFileComplexity(allocator, &issues, entry.value_ptr, thresholds);
    }
    return issues;
}

// ============================================================================
// Tests
// ============================================================================

test "isTypeFactory detects type factories" {
    try std.testing.expect(isTypeFactory("fn Foo() type {"));
    try std.testing.expect(isTypeFactory("pub fn Bar(comptime T: type) type"));
    try std.testing.expect(!isTypeFactory("fn baz() void {"));
}

test "countBranchesInLine counts correctly" {
    try std.testing.expectEqual(@as(usize, 1), countBranchesInLine("if (x) {"));
    try std.testing.expectEqual(@as(usize, 0), countBranchesInLine("inline for"));
}

test "countParams counts correctly" {
    try std.testing.expectEqual(@as(usize, 0), countParams("fn foo() void"));
    try std.testing.expectEqual(@as(usize, 1), countParams("fn foo(x: i32) void"));
    try std.testing.expectEqual(@as(usize, 2), countParams("fn foo(x: i32, y: i32) void"));
}
