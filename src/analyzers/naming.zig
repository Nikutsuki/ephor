// Rhyos Labs - Ephor
// Naming convention analysis module
// Copyright (C) 2025 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const types = @import("../types.zig");
const Issue = types.Issue;
const FileAnalysis = types.FileAnalysis;

// ============================================================================
// Naming Pattern Checks
// ============================================================================

/// Check if name is TitleCase (types)
pub fn isTitleCase(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] < 'A' or name[0] > 'Z') return false;
    for (name[1..]) |c| {
        if (c == '_') return false;
    }
    return true;
}

/// Check if name is camelCase (functions, variables)
pub fn isCamelCase(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] < 'a' or name[0] > 'z') return false;
    for (name) |c| {
        if (c == '_') return false;
    }
    return true;
}

/// Check if name is snake_case (some variables)
pub fn isSnakeCase(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (c >= 'A' and c <= 'Z') return false;
    }
    return true;
}

/// Check if name is SCREAMING_CASE (constants)
pub fn isScreamingCase(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (c >= 'a' and c <= 'z') return false;
    }
    return true;
}

/// Check if line defines a type
fn isTypeDefinition(line: []const u8) bool {
    if (mem.indexOf(u8, line, "= struct") != null) return true;
    if (mem.indexOf(u8, line, "= enum") != null) return true;
    if (mem.indexOf(u8, line, "= union") != null) return true;
    if (mem.indexOf(u8, line, "= packed struct") != null) return true;
    if (mem.indexOf(u8, line, "= packed union") != null) return true;
    if (mem.indexOf(u8, line, "= extern struct") != null) return true;
    return false;
}

/// Extract name from const/var declaration
fn extractDeclName(line: []const u8) ?[]const u8 {
    const is_const = mem.startsWith(u8, line, "const ");
    const is_var = mem.startsWith(u8, line, "var ");
    const is_pub_const = mem.startsWith(u8, line, "pub const ");
    const is_pub_var = mem.startsWith(u8, line, "pub var ");

    const start: usize = if (is_pub_const)
        10
    else if (is_pub_var)
        8
    else if (is_const)
        6
    else if (is_var)
        4
    else
        return null;

    var end = start;
    while (end < line.len and types.isIdent(line[end])) end += 1;

    if (end > start) return line[start..end];
    return null;
}

/// Extract function name
fn extractFunctionName(line: []const u8) ?[]const u8 {
    const fn_keyword = "fn ";
    const fn_pos = mem.indexOf(u8, line, fn_keyword) orelse return null;
    const start = fn_pos + fn_keyword.len;
    var end = start;
    while (end < line.len and types.isIdent(line[end])) end += 1;
    if (end > start) return line[start..end];
    return null;
}

// ============================================================================
// Issue Reporting
// ============================================================================

fn reportNamingIssue(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    path: []const u8,
    line: usize,
    col: usize,
    name: []const u8,
    expected: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(
        allocator,
        "'{s}' should use {s}",
        .{ name, expected },
    );
    try issues.append(allocator, .{
        .file = path,
        .line = line,
        .col = col,
        .severity = .note,
        .rule = types.RULE_NAMING_CONVENTION,
        .message = msg,
        .help = "follow Zig naming conventions",
        .message_owned = true,
    });
}

// ============================================================================
// Public API
// ============================================================================

/// Check type name and report if invalid
fn checkTypeName(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    t: []const u8,
    path: []const u8,
    line: usize,
) !void {
    if (!isTypeDefinition(t)) return;
    const name = extractDeclName(t) orelse return;
    if (isTitleCase(name) or isScreamingCase(name)) return;
    try reportNamingIssue(allocator, issues, path, line, 1, name, "TitleCase");
}

/// Check function name and report if invalid
fn checkFuncName(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    t: []const u8,
    path: []const u8,
    line: usize,
) !void {
    const name = extractFunctionName(t) orelse return;
    if (isCamelCase(name) or isSnakeCase(name)) return;
    if (mem.startsWith(u8, t, "test ")) return;
    try reportNamingIssue(allocator, issues, path, line, 1, name, "camelCase");
}

/// Analyze naming conventions in all files
pub fn analyze(
    allocator: Allocator,
    graph: anytype,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    var iter = graph.files.iterator();

    while (iter.next()) |entry| {
        const a = entry.value_ptr.*;
        var line_num: usize = 1;
        var lines = mem.splitScalar(u8, a.content, '\n');

        while (lines.next()) |line| {
            defer line_num += 1;
            const t = mem.trim(u8, line, " \t\r");
            if (mem.startsWith(u8, t, "//")) continue;
            try checkTypeName(allocator, &issues, t, a.path, line_num);
            try checkFuncName(allocator, &issues, t, a.path, line_num);
        }
    }
    return issues;
}

// ============================================================================
// Tests
// ============================================================================

test "isTitleCase" {
    try std.testing.expect(isTitleCase("MyType"));
    try std.testing.expect(isTitleCase("Foo"));
    try std.testing.expect(!isTitleCase("myType"));
    try std.testing.expect(!isTitleCase("my_type"));
}

test "isCamelCase" {
    try std.testing.expect(isCamelCase("myFunction"));
    try std.testing.expect(isCamelCase("foo"));
    try std.testing.expect(!isCamelCase("MyFunction"));
    try std.testing.expect(!isCamelCase("my_function"));
}

test "isSnakeCase" {
    try std.testing.expect(isSnakeCase("my_variable"));
    try std.testing.expect(isSnakeCase("foo"));
    try std.testing.expect(!isSnakeCase("MyVariable"));
    try std.testing.expect(!isSnakeCase("myVariable"));
}

test "isScreamingCase" {
    try std.testing.expect(isScreamingCase("MY_CONSTANT"));
    try std.testing.expect(isScreamingCase("FOO"));
    try std.testing.expect(!isScreamingCase("myConstant"));
    try std.testing.expect(!isScreamingCase("My_Constant"));
}
