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

test "ZA111: labeled-block values fire only through a proven escape (EPH-I0046)" {
    const a = std.testing.allocator;
    // Sink-side adjudication: the break itself never fires — the block
    // value must provably escape. f's binding chain escapes through the
    // return; i returns the block directly (the field form — a bare
    // `&v` break at a return sink is compiler-caught, probe-pinned, and
    // never echoed). g consumes the block value in-function (the sig
    // merlin.zig shape) and stays silent; h discards the block as a
    // statement and stays silent; j's comptime block is static-safe.
    var issues = try runZa111(a,
        \\const S = struct { a: u32 };
        \\fn f(x: u32) *u32 {
        \\    var v: u32 = x;
        \\    const p = blk: {
        \\        break :blk &v;
        \\    };
        \\    return p;
        \\}
        \\fn g(x: u32, sink: *u32) void {
        \\    var buffer: [4]u32 = @splat(0);
        \\    const bytes: []const u32 = switch (x) {
        \\        0 => &[_]u32{1},
        \\        else => b: {
        \\            break :b &buffer;
        \\        },
        \\    };
        \\    sink.* = bytes[0];
        \\}
        \\fn h(x: u32) void {
        \\    var v: u32 = x;
        \\    blk: {
        \\        break :blk &v;
        \\    }
        \\}
        \\fn i(x: u32) *u32 {
        \\    var s = S{ .a = x };
        \\    return blk: {
        \\        break :blk &s.a;
        \\    };
        \\}
        \\fn j() *u32 {
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
    try std.testing.expectEqual(@as(usize, 2), issues.items.len);
    try std.testing.expect(
        mem.indexOf(u8, issues.items[0].message, "returned pointer 'p'") != null,
    );
    try std.testing.expect(mem.indexOf(u8, issues.items[0].message, "'v'") != null);
    try std.testing.expectEqual(@as(usize, 7), issues.items[0].line);
    try std.testing.expect(mem.indexOf(u8, issues.items[1].message, "'s'") != null);
    try std.testing.expectEqual(@as(usize, 27), issues.items[1].line);
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

test "ZA111: label-aware block breaks keep nested inner breaks out (EPH-I1183)" {
    const a = std.testing.allocator;
    // f: the outer break escapes and must fire — the inner break names
    // the nested block (an unresolvable call operand) and previously
    // silenced the outer through the all-breaks sweep (the FN). g: the
    // void-returned outer block must stay silent — the inner break's
    // stack root is the inner block's value, never the outer's (the
    // contrived FP).
    var issues = try runZa111(a,
        \\const S = struct { a: u32 };
        \\fn make() *u32 {
        \\    return @ptrFromInt(0x1000);
        \\}
        \\fn f(x: u32) *u32 {
        \\    var v = S{ .a = x };
        \\    return outer: {
        \\        _ = inner: { break :inner make(); };
        \\        break :outer &v.a;
        \\    };
        \\}
        \\fn g() void {
        \\    var v = S{ .a = 7 };
        \\    return outer: {
        \\        const p = inner: { break :inner &v.a; };
        \\        _ = p;
        \\    };
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 1), issues.items.len);
    try std.testing.expect(mem.indexOf(u8, issues.items[0].message, "'v'") != null);
}

test "ZA111: while payload capture return fires, by-value stays silent (EPH-I1184)" {
    const a = std.testing.allocator;
    // The pointer capture binds into the condition operand's own slot —
    // the same stack-escape class the if/for capture pins cover. A
    // by-value capture returns a copy and stays silent. A param
    // condition roots at the param slot and fires too.
    var issues = try runZa111(a,
        \\fn f(x: u32) ?*u32 {
        \\    var o: ?u32 = x;
        \\    while (o) |*p| return p;
        \\    return null;
        \\}
        \\fn g(opt: ?u32) ?*u32 {
        \\    while (opt) |*p| return p;
        \\    return null;
        \\}
        \\fn h(x: u32) ?u32 {
        \\    const o: ?u32 = x;
        \\    while (o) |v| return v;
        \\    return null;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 2), issues.items.len);
    try std.testing.expect(mem.indexOf(u8, issues.items[0].message, "'o'") != null);
    try std.testing.expect(mem.indexOf(u8, issues.items[1].message, "'opt'") != null);
}

test "ZA111: switch-wrapped labeled-block binding resolves (EPH-I1185)" {
    const a = std.testing.allocator;
    // s's init is a switch whose only prong is a labeled block rooted
    // in the stack array: the binding carries the block's value and the
    // return escapes it. g consumes the binding in-function (the sig
    // merlin.zig shape) and stays silent. h's mixed prong (a non-block
    // value) keeps the switch unresolvable (FN-only).
    var issues = try runZa111(a,
        \\fn f(x: u32) *u32 {
        \\    var arr: [4]u32 = .{ 1, 2, 3, x };
        \\    const s = switch (x) {
        \\        else => b: {
        \\            break :b &arr[x % 4];
        \\        },
        \\    };
        \\    return s;
        \\}
        \\fn g(x: u32, sink: *u32) void {
        \\    var arr: [4]u32 = .{ 1, 2, 3, x };
        \\    const s = switch (x) {
        \\        else => b: {
        \\            break :b &arr[x % 4];
        \\        },
        \\    };
        \\    sink.* = s[0];
        \\}
        \\fn h(x: u32) *u32 {
        \\    var arr: [4]u32 = .{ 1, 2, 3, x };
        \\    const s = switch (x) {
        \\        0 => @as(*u32, @ptrFromInt(0x1000)),
        \\        else => b: {
        \\            break :b &arr[x % 4];
        \\        },
        \\    };
        \\    return s;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 1), issues.items.len);
    try std.testing.expect(mem.indexOf(u8, issues.items[0].message, "'s'") != null);
    try std.testing.expect(mem.indexOf(u8, issues.items[0].message, "'arr'") != null);
}
