// Test case: Multi-line errdefer blocks should be detected
// This pattern is common in real-world code (e.g., tigerbeetle)
// Expected: NO warning for ZA103 - errdefer IS present
const std = @import("std");

const Block = struct {
    ptr: []u8,
};

pub fn init(allocator: std.mem.Allocator, block_count: u32) ![]Block {
    const blocks_backing_storage = try allocator.alloc(Block, block_count);
    var blocks_allocated: u32 = 0;
    errdefer {
        // Multi-line errdefer cleanup
        for (blocks_backing_storage[0..blocks_allocated]) |block| {
            allocator.free(block.ptr);
        }
        allocator.free(blocks_backing_storage);
    }

    for (blocks_backing_storage) |*block| {
        block.* = .{
            .ptr = try allocator.alloc(u8, 1024), // This try should NOT trigger ZA103
        };
        blocks_allocated += 1;
    }

    return blocks_backing_storage;
}
