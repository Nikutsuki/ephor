// Comprehensive demo of all memory/panic issues that ephor can detect
// Both static (ZA2xx, ZA9xx) and runtime (ZR1xx) analysis

const std = @import("std");

// =============================================================================
// Issue 1: Memory leak - alloc without free (ZA101, ZR101)
// =============================================================================
pub fn memoryLeak(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 1024);
    // Missing: defer allocator.free(data);
    _ = data;
    // Static: ZA101 (alloc without defer)
    // Runtime: ZR101 (GPA detects leak)
}

// =============================================================================
// Issue 2: Exit bypasses defer - the bug we just fixed (ZA206, ZR101)
// =============================================================================
pub fn exitBypassesDefer(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 1024);
    defer allocator.free(data);

    // Static: ZA206 detects exit() with defer in scope
    // Runtime: ZR101 would detect the leak when run
    if (true) {
        std.process.exit(1); // This bypasses the defer!
    }
}

// =============================================================================
// Issue 3: Silent catch (ZA201)
// =============================================================================
pub fn silentCatch() void {
    const result = std.fs.cwd().openFile("nonexistent", .{}) catch {};
    // Static: ZA201 - silent catch {} discards error
    _ = result;
}

// =============================================================================
// Issue 4: Catch unreachable (ZA202, ZR105)
// =============================================================================
pub fn catchUnreachable() void {
    const result = std.fs.cwd().openFile("might_not_exist", .{}) catch unreachable;
    // Static: ZA202 - will panic if file doesn't exist
    // Runtime: ZR105 - panic detected
    _ = result;
}

// =============================================================================
// Issue 5: Decrement overflow (ZA901, ZR105)
// =============================================================================
pub fn decrementOverflow() usize {
    var x: usize = 0;
    x -= 1; // Underflow panic!
    // Static: ZA901 - decrement without guard
    // Runtime: ZR105 - panic detected
    return x;
}

// =============================================================================
// Issue 6: Array bounds (ZR105)
// =============================================================================
pub fn arrayBounds() void {
    const arr = [_]u8{ 1, 2, 3 };
    const i: usize = 10;
    _ = arr[i]; // Out of bounds panic!
    // Runtime: ZR105 - panic detected
}

// =============================================================================
// Issue 7: Double free (ZR102)
// =============================================================================
pub fn doubleFree(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 1024);
    allocator.free(data);
    allocator.free(data); // Double free!
    // Runtime: ZR102 - double free detected
}

// =============================================================================
// Issue 8: Use after free (ZA105, ZR103)
// =============================================================================
pub fn useAfterFree(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 1024);
    allocator.free(data);
    data[0] = 42; // Use after free!
    // Static: ZA105 - use after free
    // Runtime: ZR103 - use after free detected
}

// =============================================================================
// Issue 9: Optional unwrap panic (ZA801)
// =============================================================================
pub fn optionalUnwrap() u32 {
    const opt: ?u32 = null;
    return opt.?; // Will panic!
    // Static: ZA801 - optional unwrap may panic
}

// =============================================================================
// MAIN: Choose which issue to demonstrate
// =============================================================================
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Run the leaky function to demonstrate ZR101
    try memoryLeak(allocator);
}
