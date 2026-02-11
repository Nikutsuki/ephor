// False positive fixture: Qualified alloc functions with proper defer
// No ZA101/ZA103 should fire - all allocations have proper cleanup.

const std = @import("std");

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

fn process(data: anytype) void {
    _ = data;
}
