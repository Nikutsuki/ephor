// Rhyos Labs - Ephor
// Unused detection module
// Copyright (C) 2025 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const types = @import("../types.zig");
const Issue = types.Issue;
const ImportInfo = types.ImportInfo;
const FileAnalysis = types.FileAnalysis;

// ============================================================================
// Import Analysis
// ============================================================================

/// Count occurrences of a name in content
fn countOccurrences(content: []const u8, name: []const u8) usize {
    var count: usize = 0;
    var idx: usize = 0;
    while (idx + name.len <= content.len) : (idx += 1) {
        if (mem.eql(u8, content[idx .. idx + name.len], name)) {
            count += 1;
        }
    }
    return count;
}

/// Check if character after name indicates usage
fn isUsageChar(c: u8) bool {
    return c == '.' or c == '(' or c == ')' or
        c == ',' or c == ' ' or c == '\n' or c == ';';
}

/// Check if an import is used in the file content
fn isImportUsed(content: []const u8, import_name: []const u8) bool {
    // More than 1 occurrence means it's used (not just imported)
    return countOccurrences(content, import_name) > 1;
}

/// Report unused import
fn reportUnusedImport(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    import: ImportInfo,
) !void {
    const msg = try std.fmt.allocPrint(
        allocator,
        "unused import '{s}'",
        .{import.name},
    );
    try issues.append(allocator, .{
        .file = path,
        .line = import.line,
        .col = import.col,
        .severity = .warning,
        .rule = types.RULE_UNUSED_IMPORT,
        .message = msg,
        .help = "remove unused import",
        .message_owned = true,
    });
}

// ============================================================================
// Public API
// ============================================================================

/// Analyze unused imports in all files
pub fn analyze(
    allocator: Allocator,
    graph: anytype,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    var iter = graph.files.iterator();

    while (iter.next()) |entry| {
        const a = entry.value_ptr.*;

        for (a.imports.items) |import| {
            if (isImportUsed(a.content, import.name)) continue;
            try reportUnusedImport(&issues, allocator, a.path, import);
        }
    }

    return issues;
}

// ============================================================================
// Tests
// ============================================================================

test "isImportUsed detects usage" {
    const content = "const std = @import(\"std\");\nstd.debug.print();";
    try std.testing.expect(isImportUsed(content, "std"));
}

test "isImportUsed detects unused" {
    const content = "const foo = @import(\"foo\");";
    try std.testing.expect(!isImportUsed(content, "foo"));
}
