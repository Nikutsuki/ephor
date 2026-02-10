// True positive fixture: ZA102 - create() without defer destroy
// Every function here should trigger ZA102.

const std = @import("std");

const Node = struct {
    value: u32,
    next: ?*Node,
};

fn leak_create(allocator: std.mem.Allocator) !void {
    const node = try allocator.create(Node);
    _ = node;
}

fn leak_create_with_init(allocator: std.mem.Allocator) !void {
    const node = try allocator.create(Node);
    node.* = .{ .value = 42, .next = null };
    _ = node;
}
