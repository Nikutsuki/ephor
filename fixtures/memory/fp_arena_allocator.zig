// False positive fixture: Arena/FBA allocators - no ZA101/ZA102/ZA103 should fire
// Arena and FixedBufferAllocator manage memory collectively via deinit/reset,
// so individual allocations don't need defer free.

const std = @import("std");

const Node = struct {
    value: u32,
    next: ?*Node,
};

// ============================================================================
// ArenaAllocator - Type-Based Detection
// ============================================================================

fn arena_alloc() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const data = try allocator.alloc(u8, 100);
    _ = data;
}

fn arena_dupe() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const data = try allocator.dupe(u8, "hello");
    _ = data;
}

fn arena_dupeZ() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const data = try allocator.dupeZ(u8, "hello");
    _ = data;
}

fn arena_allocPrint() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const data = try std.fmt.allocPrint(allocator, "hello {d}", .{42});
    _ = data;
}

fn arena_create() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const node = try allocator.create(Node);
    _ = node;
}

fn arena_mem_concat() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const data = try std.mem.concat(allocator, u8, &.{ "hello", " ", "world" });
    _ = data;
}

fn arena_mem_join() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const data = try std.mem.join(allocator, ", ", &.{ "a", "b", "c" });
    _ = data;
}

fn arena_realpathAlloc() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const data = try std.fs.cwd().realpathAlloc(allocator, ".");
    _ = data;
}

fn arena_stringifyAlloc() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const val: u32 = 42;
    const data = try std.json.stringifyAlloc(allocator, val, .{});
    _ = data;
}

fn arena_multiple_allocs() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const a = try allocator.alloc(u8, 100);
    const b = try allocator.dupe(u8, "hello");
    const c = try std.fmt.allocPrint(allocator, "{s} {s}", .{ a, b });
    _ = c;
}

// ============================================================================
// FixedBufferAllocator - Type-Based Detection
// ============================================================================

fn fba_alloc() !void {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const data = try allocator.alloc(u8, 100);
    _ = data;
}

fn fba_dupe() !void {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const data = try allocator.dupe(u8, "hello");
    _ = data;
}

fn fba_create() !void {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const node = try allocator.create(Node);
    _ = node;
}

// ============================================================================
// Arena Passed as Parameter (type-based detection via pointer type)
// ============================================================================

fn arena_param(arena: *std.heap.ArenaAllocator) !void {
    const allocator = arena.allocator();
    const data = try allocator.alloc(u8, 100);
    _ = data;
}

// NOTE: A function taking plain std.mem.Allocator cannot be detected as arena-backed
// at the function boundary. That's a correct warning, not a false positive.
// fn arena_allocator_param_dupe(allocator: std.mem.Allocator) !void { ... }
