// Rhyos Labs - Ephor
// Style analysis module (line length, file size)
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
// Line Length Analysis
// ============================================================================

/// Check if a line exceeds the maximum length
fn checkLineLength(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    path: []const u8,
    line_num: usize,
    line: []const u8,
    max_length: usize,
) !void {
    if (line.len > max_length) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "line has {d} columns (max {d})",
            .{ line.len, max_length },
        );
        try issues.append(allocator, .{
            .file = path,
            .line = line_num,
            .col = max_length + 1,
            .severity = .warning,
            .rule = types.RULE_LINE_TOO_LONG,
            .message = msg,
            .help = "break line or use trailing comma to let zig fmt wrap",
            .message_owned = true,
        });
    }
}

/// Check file size
fn checkFileSize(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    path: []const u8,
    content: []const u8,
    max_bytes: usize,
) !void {
    if (content.len > max_bytes) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "file has {d} bytes (max {d})",
            .{ content.len, max_bytes },
        );
        try issues.append(allocator, .{
            .file = path,
            .line = 1,
            .col = 1,
            .severity = .warning,
            .rule = types.RULE_FILE_TOO_LONG,
            .message = msg,
            .help = "split into smaller modules",
            .message_owned = true,
        });
    }
}

// ============================================================================
// Public API
// ============================================================================

/// Analyze style issues in all files
pub fn analyze(
    allocator: Allocator,
    graph: anytype,
    thresholds: Thresholds,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    var iter = graph.files.iterator();

    while (iter.next()) |entry| {
        const a = entry.value_ptr.*;

        // Check file size
        if (thresholds.max_file_bytes) |max_bytes| {
            try checkFileSize(allocator, &issues, a.path, a.content, max_bytes);
        }

        // Check line lengths
        var line_num: usize = 1;
        var lines = mem.splitScalar(u8, a.content, '\n');

        while (lines.next()) |line| {
            defer line_num += 1;

            // Skip multiline strings
            const t = mem.trim(u8, line, " \t\r");
            if (mem.startsWith(u8, t, "\\\\")) continue;

            try checkLineLength(
                allocator,
                &issues,
                a.path,
                line_num,
                line,
                thresholds.max_line_length,
            );
        }
    }

    return issues;
}

// ============================================================================
// Tests
// ============================================================================

test "line length check" {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    defer types.deinitIssues(&issues, std.testing.allocator);

    try checkLineLength(
        std.testing.allocator,
        &issues,
        "test.zig",
        1,
        "x" ** 100,
        80,
    );

    try std.testing.expectEqual(@as(usize, 1), issues.items.len);
}
