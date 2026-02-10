// True positive fixture: ZA103 - allocation without errdefer before next try
// Every function here should trigger ZA103.
// Pattern: try alloc, then another try without errdefer in between.

const std = @import("std");

fn missing_errdefer_alloc(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 100);
    // Missing errdefer here!
    const more = try allocator.alloc(u8, 200);
    defer allocator.free(data);
    defer allocator.free(more);
}

fn missing_errdefer_dupe(allocator: std.mem.Allocator) !void {
    const data = try allocator.dupe(u8, "hello");
    // Missing errdefer here!
    const other = try allocator.dupe(u8, "world");
    defer allocator.free(data);
    defer allocator.free(other);
}

fn missing_errdefer_allocPrint(allocator: std.mem.Allocator) !void {
    const data = try std.fmt.allocPrint(allocator, "val={d}", .{42});
    // Missing errdefer here!
    const more = try std.fmt.allocPrint(allocator, "val={d}", .{43});
    defer allocator.free(data);
    defer allocator.free(more);
}

fn missing_errdefer_toOwnedSlice(allocator: std.mem.Allocator) !void {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    try list.appendSlice("hello");
    const data = try list.toOwnedSlice();
    // Missing errdefer here!
    const other = try allocator.dupe(u8, "world");
    defer allocator.free(data);
    defer allocator.free(other);
}

fn missing_errdefer_mem_concat(allocator: std.mem.Allocator) !void {
    const data = try std.mem.concat(allocator, u8, &.{ "hello", " ", "world" });
    // Missing errdefer here!
    const more = try allocator.dupe(u8, "extra");
    defer allocator.free(data);
    defer allocator.free(more);
}

fn missing_errdefer_mem_join(allocator: std.mem.Allocator) !void {
    const data = try std.mem.join(allocator, ", ", &.{ "a", "b", "c" });
    // Missing errdefer here!
    const more = try allocator.alloc(u8, 50);
    defer allocator.free(data);
    defer allocator.free(more);
}

fn missing_errdefer_realpathAlloc(allocator: std.mem.Allocator) !void {
    const path = try std.fs.cwd().realpathAlloc(allocator, ".");
    // Missing errdefer here!
    const data = try allocator.alloc(u8, 100);
    defer allocator.free(path);
    defer allocator.free(data);
}

fn missing_errdefer_replaceOwned(allocator: std.mem.Allocator) !void {
    const data = try std.mem.replaceOwned(u8, allocator, "hello", "l", "r");
    // Missing errdefer here!
    const more = try allocator.dupe(u8, "world");
    defer allocator.free(data);
    defer allocator.free(more);
}

fn missing_errdefer_stringifyAlloc(allocator: std.mem.Allocator) !void {
    const val: u32 = 42;
    const data = try std.json.stringifyAlloc(allocator, val, .{});
    // Missing errdefer here!
    const more = try allocator.alloc(u8, 50);
    defer allocator.free(data);
    defer allocator.free(more);
}

fn missing_errdefer_getEnvVarOwned(allocator: std.mem.Allocator) !void {
    const data = try std.process.getEnvVarOwned(allocator, "HOME");
    // Missing errdefer here!
    const more = try allocator.alloc(u8, 100);
    defer allocator.free(data);
    defer allocator.free(more);
}

fn missing_errdefer_getAppDataDir(allocator: std.mem.Allocator) !void {
    const data = try std.fs.getAppDataDir(allocator, "myapp");
    // Missing errdefer here!
    const more = try allocator.alloc(u8, 100);
    defer allocator.free(data);
    defer allocator.free(more);
}
