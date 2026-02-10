// True positive fixture: ZA101 - allocation without defer free
// Every function here should trigger ZA101.
// Each function demonstrates one allocation pattern missing its required defer.

const std = @import("std");

// ============================================================================
// Core Allocator Methods
// ============================================================================

fn leak_alloc(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 100);
    _ = data;
}

fn leak_alignedAlloc(allocator: std.mem.Allocator) !void {
    const data = try allocator.alignedAlloc(u8, 16, 100);
    _ = data;
}

fn leak_allocSentinel(allocator: std.mem.Allocator) !void {
    const data = try allocator.allocSentinel(u8, 100, 0);
    _ = data;
}

fn leak_realloc(allocator: std.mem.Allocator) !void {
    const old = try allocator.alloc(u8, 50);
    defer allocator.free(old);
    const data = try allocator.realloc(old, 100);
    _ = data;
}

fn leak_dupe(allocator: std.mem.Allocator) !void {
    const data = try allocator.dupe(u8, "hello");
    _ = data;
}

fn leak_dupeZ(allocator: std.mem.Allocator) !void {
    const data = try allocator.dupeZ(u8, "hello");
    _ = data;
}

fn leak_allocWithOptions(allocator: std.mem.Allocator) !void {
    const data = try allocator.allocWithOptions(u8, 100, null, null);
    _ = data;
}

// ============================================================================
// Format Methods
// ============================================================================

fn leak_allocPrint(allocator: std.mem.Allocator) !void {
    const data = try std.fmt.allocPrint(allocator, "hello {d}", .{42});
    _ = data;
}

fn leak_allocPrintZ(allocator: std.mem.Allocator) !void {
    const data = try std.fmt.allocPrintZ(allocator, "hello {d}", .{42});
    _ = data;
}

// ============================================================================
// Container Methods
// ============================================================================

fn leak_toOwnedSlice(allocator: std.mem.Allocator) !void {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    try list.appendSlice("hello");
    const data = try list.toOwnedSlice();
    _ = data;
}

// ============================================================================
// File I/O Methods
// ============================================================================

fn leak_readToEndAlloc(allocator: std.mem.Allocator) !void {
    const file = try std.fs.cwd().openFile("test.txt", .{});
    defer file.close();
    const data = try file.reader().readToEndAlloc(allocator, 1024);
    _ = data;
}

fn leak_readAllAlloc(allocator: std.mem.Allocator) !void {
    const file = try std.fs.cwd().openFile("test.txt", .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 1024);
    _ = data;
}

// ============================================================================
// Path Operations
// ============================================================================

fn leak_realpathAlloc(allocator: std.mem.Allocator) !void {
    const data = try std.fs.cwd().realpathAlloc(allocator, ".");
    _ = data;
}

// ============================================================================
// String Operations
// ============================================================================

fn leak_replaceOwned(allocator: std.mem.Allocator) !void {
    const data = try std.mem.replaceOwned(u8, allocator, "hello world", "world", "zig");
    _ = data;
}

// ============================================================================
// JSON/Serialization
// ============================================================================

fn leak_stringifyAlloc(allocator: std.mem.Allocator) !void {
    const val: u32 = 42;
    const data = try std.json.stringifyAlloc(allocator, val, .{});
    _ = data;
}

// ============================================================================
// Qualified Stdlib Functions
// ============================================================================

fn leak_mem_concat(allocator: std.mem.Allocator) !void {
    const data = try std.mem.concat(allocator, u8, &.{ "hello", " ", "world" });
    _ = data;
}

fn leak_mem_join(allocator: std.mem.Allocator) !void {
    const data = try std.mem.join(allocator, ", ", &.{ "a", "b", "c" });
    _ = data;
}

fn leak_mem_joinZ(allocator: std.mem.Allocator) !void {
    const data = try std.mem.joinZ(allocator, ", ", &.{ "a", "b", "c" });
    _ = data;
}

// ============================================================================
// New Qualified Patterns
// ============================================================================

fn leak_getEnvVarOwned(allocator: std.mem.Allocator) !void {
    const data = try std.process.getEnvVarOwned(allocator, "HOME");
    _ = data;
}

fn leak_getAppDataDir(allocator: std.mem.Allocator) !void {
    const data = try std.fs.getAppDataDir(allocator, "myapp");
    _ = data;
}
