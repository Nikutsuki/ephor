// Test case: Arena and FixedBufferAllocator allocations
// These don't need individual defer/errdefer - the arena is freed as a whole
// Expected: NO warning for ZA101/ZA102/ZA103
const std = @import("std");

pub fn processWithArena(backing_allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Arena allocations - no individual defer needed
    const buffer1 = try allocator.alloc(u8, 1024);
    const buffer2 = try allocator.alloc(u8, 2048);
    const obj = try allocator.create(SomeStruct);
    _ = buffer1;
    _ = buffer2;
    _ = obj;
}

pub fn processWithFBA() !void {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    // FBA allocations - no defer needed, memory is on stack
    const data1 = try allocator.alloc(u8, 100);
    const data2 = try allocator.alloc(u8, 200);
    _ = data1;
    _ = data2;
}

pub fn processWithRecycleFBA(recycle_fba: *std.heap.FixedBufferAllocator) !void {
    const allocator = recycle_fba.allocator();
    // No defer needed - caller manages FBA lifetime
    const csv_string = try allocator.alloc(u8, 1000);
    _ = csv_string;
}

const SomeStruct = struct {
    value: u32,
};
