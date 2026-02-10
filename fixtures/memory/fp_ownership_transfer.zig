// False positive fixture: Ownership transfer patterns - no ZA101/ZA102 should fire
// When memory ownership is transferred (returned, stored, passed to collection),
// the caller is responsible for cleanup, not this function.

const std = @import("std");

const Node = struct {
    value: u32,
    data: []const u8,
};

// ============================================================================
// Return Transfers
// ============================================================================

fn factory_alloc(allocator: std.mem.Allocator) ![]u8 {
    const data = try allocator.alloc(u8, 100);
    return data;
}

fn factory_dupe(allocator: std.mem.Allocator) ![]u8 {
    const data = try allocator.dupe(u8, "hello");
    return data;
}

fn factory_allocPrint(allocator: std.mem.Allocator) ![]u8 {
    const data = try std.fmt.allocPrint(allocator, "hello {d}", .{42});
    return data;
}

fn factory_mem_concat(allocator: std.mem.Allocator) ![]u8 {
    const data = try std.mem.concat(allocator, u8, &.{ "hello", " ", "world" });
    return data;
}

fn factory_mem_join(allocator: std.mem.Allocator) ![]u8 {
    const data = try std.mem.join(allocator, ", ", &.{ "a", "b", "c" });
    return data;
}

fn factory_realpathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const data = try std.fs.cwd().realpathAlloc(allocator, ".");
    return data;
}

fn factory_create(allocator: std.mem.Allocator) !*Node {
    const node = try allocator.create(Node);
    return node;
}

// ============================================================================
// Anonymous Struct Return
// ============================================================================

fn factory_struct_return(allocator: std.mem.Allocator) !struct { data: []u8, len: usize } {
    const data = try allocator.alloc(u8, 100);
    return .{ .data = data, .len = 100 };
}

// ============================================================================
// Store in Struct Field
// ============================================================================

fn store_in_field(self: *Node, allocator: std.mem.Allocator) !void {
    const data = try allocator.dupe(u8, "hello");
    self.data = data;
}

// ============================================================================
// Collection Transfer
// ============================================================================

fn append_to_list(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) !void {
    const data = try allocator.dupe(u8, "hello");
    try list.append(data);
}

fn put_in_map(allocator: std.mem.Allocator, map: *std.StringHashMap([]const u8)) !void {
    const data = try allocator.dupe(u8, "value");
    try map.put("key", data);
}

// ============================================================================
// Labeled Break Transfer
// ============================================================================

fn labeled_break_transfer(allocator: std.mem.Allocator) ![]u8 {
    const result = blk: {
        const data = try allocator.alloc(u8, 100);
        break :blk data;
    };
    return result;
}

// ============================================================================
// Pointer Deref Assignment (ownership transfer to pointed-to location)
// ============================================================================

fn deref_assignment(allocator: std.mem.Allocator, out: *[]u8) !void {
    const data = try allocator.alloc(u8, 100);
    out.* = data;
}
