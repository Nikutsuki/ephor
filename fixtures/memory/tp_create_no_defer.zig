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

fn leak_create_in_loop(allocator: std.mem.Allocator) !void {
    for (0..5) |i| {
        const node = try allocator.create(Node);
        node.* = .{ .value = @intCast(i), .next = null };
        _ = node;
    }
}

fn leak_multiple_creates(allocator: std.mem.Allocator) !void {
    const a = try allocator.create(Node);
    const b = try allocator.create(Node);
    a.* = .{ .value = 1, .next = null };
    b.* = .{ .value = 2, .next = a };
    _ = b;
}
