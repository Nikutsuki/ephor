// False positive fixture: Proper errdefer cleanup - no ZA103 should fire
// Every allocation is followed by errdefer before the next try.

const std = @import("std");

fn proper_errdefer_alloc(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 100);
    errdefer allocator.free(data);
    const more = try allocator.alloc(u8, 200);
    errdefer allocator.free(more);
    process(data, more);
}

fn proper_errdefer_dupe(allocator: std.mem.Allocator) !void {
    const data = try allocator.dupe(u8, "hello");
    errdefer allocator.free(data);
    const other = try allocator.dupe(u8, "world");
    errdefer allocator.free(other);
    process(data, other);
}

fn proper_errdefer_allocPrint(allocator: std.mem.Allocator) !void {
    const data = try std.fmt.allocPrint(allocator, "val={d}", .{42});
    errdefer allocator.free(data);
    const more = try std.fmt.allocPrint(allocator, "val={d}", .{43});
    errdefer allocator.free(more);
    process(data, more);
}

fn proper_errdefer_toOwnedSlice(allocator: std.mem.Allocator) !void {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    try list.appendSlice("hello");
    const data = try list.toOwnedSlice();
    errdefer allocator.free(data);
    const other = try allocator.dupe(u8, "world");
    errdefer allocator.free(other);
    process(data, other);
}

fn proper_errdefer_mem_concat(allocator: std.mem.Allocator) !void {
    const data = try std.mem.concat(allocator, u8, &.{ "hello", " ", "world" });
    errdefer allocator.free(data);
    const more = try allocator.dupe(u8, "extra");
    errdefer allocator.free(more);
    process(data, more);
}

fn proper_errdefer_mem_join(allocator: std.mem.Allocator) !void {
    const data = try std.mem.join(allocator, ", ", &.{ "a", "b", "c" });
    errdefer allocator.free(data);
    const more = try allocator.alloc(u8, 50);
    errdefer allocator.free(more);
    process(data, more);
}

fn proper_errdefer_realpathAlloc(allocator: std.mem.Allocator) !void {
    const path = try std.fs.cwd().realpathAlloc(allocator, ".");
    errdefer allocator.free(path);
    const data = try allocator.alloc(u8, 100);
    errdefer allocator.free(data);
    process(path, data);
}

fn proper_errdefer_replaceOwned(allocator: std.mem.Allocator) !void {
    const data = try std.mem.replaceOwned(u8, allocator, "hello", "l", "r");
    errdefer allocator.free(data);
    const more = try allocator.dupe(u8, "world");
    errdefer allocator.free(more);
    process(data, more);
}

fn proper_errdefer_stringifyAlloc(allocator: std.mem.Allocator) !void {
    const val: u32 = 42;
    const data = try std.json.stringifyAlloc(allocator, val, .{});
    errdefer allocator.free(data);
    const more = try allocator.alloc(u8, 50);
    errdefer allocator.free(more);
    process(data, more);
}

fn proper_errdefer_getEnvVarOwned(allocator: std.mem.Allocator) !void {
    const data = try std.process.getEnvVarOwned(allocator, "HOME");
    errdefer allocator.free(data);
    const more = try allocator.alloc(u8, 100);
    errdefer allocator.free(more);
    process(data, more);
}

fn proper_errdefer_getAppDataDir(allocator: std.mem.Allocator) !void {
    const data = try std.fs.getAppDataDir(allocator, "myapp");
    errdefer allocator.free(data);
    const more = try allocator.alloc(u8, 100);
    errdefer allocator.free(more);
    process(data, more);
}

fn process(a: anytype, b: anytype) void {
    _ = a;
    _ = b;
}
