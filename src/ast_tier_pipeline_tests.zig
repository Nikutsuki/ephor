// Rhyos Labs - Ephor
// AST-tier pipeline regression tests: skip-class diagnosis on large
// files (EPH-I1297).
// Copyright (C) 2025 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

//! The EPH-I1297 battery lives here, split out of ast_tier.zig so the
//! core stays under the 64 KiB byte cap (EPH-I0601, F12 guard): at the
//! I1297 fix ast_tier.zig held 101 spare bytes. The suite-join shim in
//! ast_tier.zig references this file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const tier = @import("ast_tier.zig");

const Issue = types.Issue;
const Stats = tier.Stats;
const max_ast_file_bytes = tier.max_ast_file_bytes;
const buildPaddedSource = tier.buildPaddedSource;

/// Valid Zig padded past 50 KB, then one broken statement. The parse
/// error sits past byte 50K, inside the AST tier's cap, so the cap
/// class cannot refuse the file (EPH-I1297).
fn buildParseErrorPast50K(a: Allocator) ![]u8 {
    const head = "fn f() void {}\n//";
    const padding: usize = 60_000;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, head);
    try buf.appendNTimes(a, 'x', padding - head.len);
    try buf.appendSlice(a, "\nfoo bar;");
    return buf.toOwnedSlice(a);
}

test "EPH-I1297: >64 KiB valid file skips with the cap class (REL-P1-VERIFY-3)" {
    const a = std.testing.allocator;
    const src = try buildPaddedSource(a, max_ast_file_bytes + 1);
    defer a.free(src);
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    defer types.deinitIssues(&issues, a);
    var stats = Stats{};
    try tier.analyzeFileAstTier(a, .{ .issues = &issues, .stats = &stats }, "big.zig", src);
    try std.testing.expectEqual(@as(usize, 0), stats.parsed);
    try std.testing.expectEqual(@as(usize, 1), stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), stats.skipped_cap);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped_nesting);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped_parse);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped_spawn);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "EPH-I1297: parse error past byte 50K skips with the parse class (REL-P1-VERIFY-3)" {
    const a = std.testing.allocator;
    const src = try buildParseErrorPast50K(a);
    defer a.free(src);
    try std.testing.expect(src.len > 50_000);
    try std.testing.expect(src.len <= max_ast_file_bytes);
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    defer types.deinitIssues(&issues, a);
    var parse_issues: std.ArrayListUnmanaged(Issue) = .empty;
    defer types.deinitIssues(&parse_issues, a);
    var stats = Stats{};
    try tier.analyzeFileAstTier(a, .{
        .issues = &issues,
        .stats = &stats,
        .parse_issues = &parse_issues,
    }, "broken_big.zig", src);
    try std.testing.expectEqual(@as(usize, 0), stats.parsed);
    try std.testing.expectEqual(@as(usize, 1), stats.skipped);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped_cap);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped_nesting);
    try std.testing.expectEqual(@as(usize, 1), stats.skipped_parse);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped_spawn);
    // The ZA503 names the error on line 3: the tier parsed past the
    // 50 KB padding line, so the parse class (not the cap) refused. The
    // fixture is three lines — the decl head, the padded comment line,
    // and the broken statement — so the error token's line is 3. The
    // fixture's error token is the real `bar` identifier, unlike an
    // EOF-shaped break whose null token reports at line 1 (the I0742
    // test pins only line >= 1 for that reason).
    try std.testing.expectEqual(@as(usize, 1), parse_issues.items.len);
    try std.testing.expectEqualStrings("ZA503", parse_issues.items[0].rule);
    try std.testing.expectEqual(@as(usize, 3), parse_issues.items[0].line);
}
