// False positive fixture: Every allocation pattern WITH proper defer free
// No ZA101 should fire - all allocations have correct cleanup.
// Tests the "good code is good" path exhaustively.

const std = @import("std");

// ============================================================================
// Core Allocator Methods
// ============================================================================

fn proper_alloc(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 100);
    defer allocator.free(data);
    process(data);
}

fn proper_alignedAlloc(allocator: std.mem.Allocator) !void {
    const data = try allocator.alignedAlloc(u8, 16, 100);
    defer allocator.free(data);
    process(data);
}

fn proper_allocSentinel(allocator: std.mem.Allocator) !void {
    const data = try allocator.allocSentinel(u8, 100, 0);
    defer allocator.free(data);
    process(data);
}

fn proper_realloc(allocator: std.mem.Allocator) !void {
    const old = try allocator.alloc(u8, 50);
    const data = try allocator.realloc(old, 100);
    defer allocator.free(data);
    process(data);
}

fn proper_dupe(allocator: std.mem.Allocator) !void {
    const data = try allocator.dupe(u8, "hello");
    defer allocator.free(data);
    process(data);
}

fn proper_dupeZ(allocator: std.mem.Allocator) !void {
    const data = try allocator.dupeZ(u8, "hello");
    defer allocator.free(data);
    process(data);
}

fn proper_allocWithOptions(allocator: std.mem.Allocator) !void {
    const data = try allocator.allocWithOptions(u8, 100, null, null);
    defer allocator.free(data);
    process(data);
}

// ============================================================================
// Format Methods
// ============================================================================

fn proper_allocPrint(allocator: std.mem.Allocator) !void {
    const data = try std.fmt.allocPrint(allocator, "hello {d}", .{42});
    defer allocator.free(data);
    process(data);
}

fn proper_allocPrintZ(allocator: std.mem.Allocator) !void {
    const data = try std.fmt.allocPrintZ(allocator, "hello {d}", .{42});
    defer allocator.free(data);
    process(data);
}

// ============================================================================
// Container Methods
// ============================================================================

fn proper_toOwnedSlice(allocator: std.mem.Allocator) !void {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    try list.appendSlice("hello");
    const data = try list.toOwnedSlice();
    defer allocator.free(data);
    process(data);
}

fn proper_toOwnedSliceSentinel(allocator: std.mem.Allocator) !void {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    try list.appendSlice("hello");
    const data = try list.toOwnedSliceSentinel(0);
    defer allocator.free(data);
    process(data);
}

// ============================================================================
// File I/O Methods
// ============================================================================

fn proper_readToEndAlloc(allocator: std.mem.Allocator) !void {
    const file = try std.fs.cwd().openFile("test.txt", .{});
    defer file.close();
    const data = try file.reader().readToEndAlloc(allocator, 1024);
    defer allocator.free(data);
    process(data);
}

fn proper_readFileAlloc(allocator: std.mem.Allocator) !void {
    const dir = std.fs.cwd();
    const data = try dir.readFileAlloc(allocator, "test.txt", 1024);
    defer allocator.free(data);
    process(data);
}

// ============================================================================
// Path Operations
// ============================================================================

fn proper_realpathAlloc(allocator: std.mem.Allocator) !void {
    const data = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(data);
    process(data);
}

fn proper_selfExePathAlloc(allocator: std.mem.Allocator) !void {
    const data = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(data);
    process(data);
}

fn proper_selfExeDirPathAlloc(allocator: std.mem.Allocator) !void {
    const data = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(data);
    process(data);
}

// ============================================================================
// String Operations
// ============================================================================

fn proper_replaceOwned(allocator: std.mem.Allocator) !void {
    const data = try std.mem.replaceOwned(u8, allocator, "hello world", "world", "zig");
    defer allocator.free(data);
    process(data);
}

fn proper_concatWithSentinel(allocator: std.mem.Allocator) !void {
    const data = try allocator.concatWithSentinel(u8, &.{ "hello", " ", "world" }, 0);
    defer allocator.free(data);
    process(data);
}

// ============================================================================
// Qualified Stdlib Functions
// ============================================================================

fn proper_mem_concat(allocator: std.mem.Allocator) !void {
    const data = try std.mem.concat(allocator, u8, &.{ "hello", " ", "world" });
    defer allocator.free(data);
    process(data);
}

fn proper_mem_join(allocator: std.mem.Allocator) !void {
    const data = try std.mem.join(allocator, ", ", &.{ "a", "b", "c" });
    defer allocator.free(data);
    process(data);
}

fn proper_mem_joinZ(allocator: std.mem.Allocator) !void {
    const data = try std.mem.joinZ(allocator, ", ", &.{ "a", "b", "c" });
    defer allocator.free(data);
    process(data);
}

fn proper_getEnvVarOwned(allocator: std.mem.Allocator) !void {
    const data = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(data);
    process(data);
}

fn proper_getAppDataDir(allocator: std.mem.Allocator) !void {
    const data = try std.fs.getAppDataDir(allocator, "myapp");
    defer allocator.free(data);
    process(data);
}

// ============================================================================
// JSON/Serialization
// ============================================================================

fn proper_stringifyAlloc(allocator: std.mem.Allocator) !void {
    const val: u32 = 42;
    const data = try std.json.stringifyAlloc(allocator, val, .{});
    defer allocator.free(data);
    process(data);
}

fn process(data: anytype) void {
    _ = data;
}
