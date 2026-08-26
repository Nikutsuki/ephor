// Rhyos Labs - Ephor
// ZA111 returned-stack-reference: the rule's I0046 extension tests.
// Copyright (C) 2025 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

//! The EPH-I0046 test battery lives here, split out of ast_tier.zig so
//! both AST-tier halves stay under the 64 KiB byte cap (EPH-I0601,
//! F12 guard). The suite-join shim in ast_tier.zig references this file.

const std = @import("std");
const mem = std.mem;
const types = @import("types.zig");
const tier = @import("ast_tier.zig");

const runZa111 = tier.runZa111;
const expectZa111 = tier.expectZa111;

test "ZA111: out-param escape fires (EPH-I0046)" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\fn f(out: *[*]u32, x: u32) void {
        \\    var v: u32 = x;
        \\    out.* = &v;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 3, "stored pointer to stack local 'v'");
}

test "ZA111: out-param field store and by-value param stay silent (EPH-I0046)" {
    const a = std.testing.allocator;
    // The by-value struct param's field write touches a local copy — no
    // escape. A local pointer's pointee store is out of scope (silent).
    var issues = try runZa111(a,
        \\const S = struct { p: *u32 };
        \\fn f(s: S, x: u32) void {
        \\    var v: u32 = x;
        \\    s.p = &v;
        \\}
        \\fn g(x: u32) void {
        \\    var v: u32 = x;
        \\    var local_p: *u32 = undefined;
        \\    local_p = &v;
        \\    _ = local_p;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "ZA111: labeled-block break escapes fire, comptime blocks stay silent (EPH-I0046)" {
    const a = std.testing.allocator;
    // The runtime break hands the stack address to the block value. The
    // comptime block evaluates at compile time, where every local lives
    // in constant memory — the ghostty cli/ghostty.zig shape stays
    // silent.
    var issues = try runZa111(a,
        \\fn f(x: u32) *u32 {
        \\    var v: u32 = x;
        \\    const p = blk: {
        \\        break :blk &v;
        \\    };
        \\    return p;
        \\}
        \\fn g() *u32 {
        \\    comptime {
        \\        var v: u32 = 42;
        \\        const p = blk: {
        \\            break :blk &v;
        \\        };
        \\        return p;
        \\    }
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 1), issues.items.len);
    try expectZa111(issues.items, 4, "escapes through a labeled block break");
}

test "ZA111: if payload capture return fires, local and param (EPH-I0046)" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\fn f(x: u32) *u32 {
        \\    var o: ?u32 = x;
        \\    if (o) |*p| return p;
        \\    return null;
        \\}
        \\fn g(opt: ?u32) ?*u32 {
        \\    if (opt) |*p| return p;
        \\    return null;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 2), issues.items.len);
    try std.testing.expect(mem.indexOf(u8, issues.items[0].message, "'o'") != null);
    try std.testing.expect(mem.indexOf(u8, issues.items[1].message, "'opt'") != null);
}

test "ZA111: for payload capture return fires over local arrays (EPH-I0046)" {
    const a = std.testing.allocator;
    // Both the `&arr` and the by-value forms iterate stack storage (the
    // by-value loop copies into a hidden stack slot). A slice input
    // iterates caller memory and stays silent.
    var issues = try runZa111(a,
        \\fn f() ?*u32 {
        \\    var arr = [_]u32{ 1, 2, 3, 4 };
        \\    for (&arr) |*p| return p;
        \\    return null;
        \\}
        \\fn g() ?*u32 {
        \\    var arr = [_]u32{ 1, 2, 3, 4 };
        \\    for (arr) |*p| return p;
        \\    return null;
        \\}
        \\fn h(s: []u32) ?*u32 {
        \\    for (s) |*p| return p;
        \\    return null;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 2), issues.items.len);
}

test "ZA111: @ptrCast evasion fires, direct and through @as (EPH-I0046)" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\fn f(x: u32) *u32 {
        \\    var v: u32 = x;
        \\    return @ptrCast(&v);
        \\}
        \\fn g(x: u32) *u32 {
        \\    var v: u32 = x;
        \\    const p = @as(*u32, @ptrCast(&v));
        \\    return p;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 2), issues.items.len);
}

test "ZA111: @field chain fires; pointer-param and dynamic-name forms stay silent (EPH-I0046)" {
    const a = std.testing.allocator;
    // The @field builtin peels as a field hop. A pointer param roots the
    // chain in caller memory (silent), and a non-literal field name
    // cannot resolve a field type (silent under the precision policy).
    var issues = try runZa111(a,
        \\const Inner = struct { x: u32 };
        \\const Outer = struct { inner: Inner };
        \\fn f(x: u32) *u32 {
        \\    var s = Outer{ .inner = .{ .x = x } };
        \\    return &@field(s, "inner").x;
        \\}
        \\fn g(s: *Outer) *u32 {
        \\    return &@field(s, "inner").x;
        \\}
        \\fn h(comptime fname: []const u8, x: u32) *u32 {
        \\    var s = Outer{ .inner = .{ .x = x } };
        \\    return &@field(s, fname);
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 5, "'s'");
}

test "ZA111: @unionInit temporary root fires (EPH-I0046)" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\const U = union(enum) {
        \\    a: u32,
        \\    arr: [4]u32,
        \\};
        \\fn f() *const [4]u32 {
        \\    return &@unionInit(U, "arr", .{ 1, 2, 3, 4 }).arr;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 6, "stack temporary");
}

test "ZA111: named array-alias chain resolves and fires (EPH-I0046)" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\const Alias4 = [4]u32;
        \\fn f(x: u32) *u32 {
        \\    var v: Alias4 = .{ 1, 2, 3, x };
        \\    return &v[1];
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 4, "'v'");
}

test "ZA111: rebound var aliases fire only when every rebind stays stack-rooted (EPH-I0046)" {
    const a = std.testing.allocator;
    // The both-stack rebind dangles; a heap rebind drops the alias. A
    // never-rebound `var p = &v;` is a hard compile error (the
    // pointless-var lint), which the rule never echoes.
    var issues = try runZa111(a,
        \\fn f(x: u32) *u32 {
        \\    var v: u32 = x;
        \\    var w: u32 = x + 1;
        \\    var p = &v;
        \\    p = &w;
        \\    return p;
        \\}
        \\fn g(x: u32, h: *u32) *u32 {
        \\    var v: u32 = x;
        \\    var p = &v;
        \\    p = h;
        \\    return p;
        \\}
        \\fn h2(x: u32) *u32 {
        \\    var v: u32 = x;
        \\    var p = &v;
        \\    return p;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 1), issues.items.len);
    try std.testing.expect(mem.indexOf(u8, issues.items[0].message, "'w'") != null);
}

test "ZA111: slice bindings fire; elem-mutated var bindings stay silent (EPH-I0046)" {
    const a = std.testing.allocator;
    // Const and rebound-var slice bindings of a stack array dangle. The
    // element-mutated var binding compiles (the lint counts element
    // writes as mutation) but carries no rebind — a documented FN.
    var issues = try runZa111(a,
        \\fn f(x: u32) []u32 {
        \\    var arr = [_]u32{ 1, 2, 3, x };
        \\    const s = arr[0..2];
        \\    return s;
        \\}
        \\fn g(x: u32) []u32 {
        \\    var arr = [_]u32{ 1, 2, 3, x };
        \\    var other = [_]u32{ 4, 5, 6, x };
        \\    var s = arr[0..2];
        \\    s = other[0..2];
        \\    return s;
        \\}
        \\fn h(x: u32) []u32 {
        \\    var arr = [_]u32{ 1, 2, 3, x };
        \\    var s = arr[0..2];
        \\    s[0] += 1;
        \\    return s;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 2), issues.items.len);
    try std.testing.expect(mem.indexOf(u8, issues.items[1].message, "'other'") != null);
}

test "ZA111: slice of array field and array param fire (EPH-I0046)" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\const Holder = struct { arr: [4]u32 };
        \\fn f(x: u32) []u32 {
        \\    var holder = Holder{ .arr = .{ 1, 2, 3, x } };
        \\    return holder.arr[0..2];
        \\}
        \\fn g(a: [4]u32) []u32 {
        \\    return a[0..2];
        \\}
        \\fn h(s: []u32) []u32 {
        \\    return s[0..2];
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 2), issues.items.len);
    try std.testing.expect(mem.indexOf(u8, issues.items[0].message, "'holder'") != null);
    try std.testing.expect(mem.indexOf(u8, issues.items[1].message, "'a'") != null);
}
