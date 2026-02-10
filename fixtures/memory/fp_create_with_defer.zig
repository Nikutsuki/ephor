// False positive fixture: create() with proper cleanup - no ZA102 should fire

const std = @import("std");

const Node = struct {
    value: u32,
    next: ?*Node,
};

// ============================================================================
// create() with proper defer destroy
// ============================================================================

fn proper_create(allocator: std.mem.Allocator) !void {
    const node = try allocator.create(Node);
    defer allocator.destroy(node);
    node.* = .{ .value = 42, .next = null };
    process(node);
}

// ============================================================================
// create() returned (ownership transfer)
// ============================================================================

fn factory_create(allocator: std.mem.Allocator) !*Node {
    const node = try allocator.create(Node);
    node.* = .{ .value = 42, .next = null };
    return node;
}

// ============================================================================
// create() stored in struct field (ownership transfer)
// ============================================================================

const Container = struct {
    node: *Node,
};

fn store_create_in_field(allocator: std.mem.Allocator, container: *Container) !void {
    const node = try allocator.create(Node);
    node.* = .{ .value = 1, .next = null };
    container.node = node;
}

fn process(node: anytype) void {
    _ = node;
}
