// False positive fixture: Conditional free patterns - no ZA101 should fire
// Memory is freed on all paths, just not via defer.

const std = @import("std");

// ============================================================================
// Free in if/else (both branches)
// ============================================================================

fn free_in_both_branches(allocator: std.mem.Allocator, cond: bool) !void {
    const data = try allocator.alloc(u8, 100);
    if (cond) {
        process(data);
        allocator.free(data);
    } else {
        allocator.free(data);
    }
}

// ============================================================================
// Free in switch arms
// ============================================================================

fn free_in_switch(allocator: std.mem.Allocator, mode: enum { keep, discard, reset }) !void {
    const data = try allocator.alloc(u8, 100);
    switch (mode) {
        .keep => {
            process(data);
            allocator.free(data);
        },
        .discard => allocator.free(data),
        .reset => {
            @memset(data, 0);
            allocator.free(data);
        },
    }
}

// ============================================================================
// Free in catch block with return
// ============================================================================

fn free_in_catch_return(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 100);
    defer allocator.free(data);
    const result = riskyOp() catch {
        return error.Failed;
    };
    _ = result;
    process(data);
}

// ============================================================================
// Free before early return in guard clause
// ============================================================================

fn free_before_early_return(allocator: std.mem.Allocator, valid: bool) !void {
    const data = try allocator.alloc(u8, 100);
    if (!valid) {
        allocator.free(data);
        return error.Invalid;
    }
    defer allocator.free(data);
    process(data);
}

fn riskyOp() !void {
    return;
}

fn process(data: anytype) void {
    _ = data;
}
