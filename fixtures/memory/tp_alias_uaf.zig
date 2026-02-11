// True positive fixture: Use-after-free through variable alias
// ZA105 should fire — alias points to freed memory.

const std = @import("std");

// ============================================================================
// Simple alias UAF
// ============================================================================

fn alias_uaf(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 100);
    const alias = data;
    allocator.free(data);
    process(alias); // ZA105: use-after-free through alias
}

// ============================================================================
// Alias with intermediate use
// ============================================================================

fn alias_uaf_with_work(allocator: std.mem.Allocator) !void {
    const buf = try allocator.alloc(u8, 256);
    const view = buf;
    @memset(buf, 0);
    allocator.free(buf);
    process(view); // ZA105: use-after-free through alias
}

fn process(data: anytype) void {
    _ = data;
}
