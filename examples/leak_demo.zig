// Demo file showing various memory issues that ephor's runtime feature should catch
// This demonstrates why runtime needs --command support for testing actual apps

const std = @import("std");

// Issue 1: Memory leak - alloc without free
pub fn leakyFunction(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 1024);
    // Missing: defer allocator.free(data);
    _ = data;
    // Leak: data is never freed
}

// Issue 2: Exit bypassing defer (the bug we just fixed in ephor)
pub fn exitBypassesDefer(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 1024);
    defer allocator.free(data);

    // This exit() bypasses the defer, causing a leak
    if (true) {
        // ephor:disable-next-line ZA206
        std.process.exit(1); // Would bypass defer!
    }
}

// Issue 3: Double free
pub fn doubleFree(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 1024);
    allocator.free(data);
    allocator.free(data); // Double free - will panic!
}

// Issue 4: Use after free
pub fn useAfterFree(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 1024);
    allocator.free(data);
    data[0] = 42; // Use after free - undefined behavior!
}

// Issue 5: Overflow panic
pub fn overflowPanic() void {
    var x: usize = 0;
    x -= 1; // Underflow panic!
}

// Issue 6: Array bounds panic
pub fn boundsCheck() void {
    const arr = [_]u8{ 1, 2, 3 };
    const i: usize = 10;
    _ = arr[i]; // Out of bounds panic!
}

// This demonstrates what a proper test would look like
// that ephor runtime could run to detect issues
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit(); // This will detect leaks!

    const allocator = gpa.allocator();

    // Uncomment each to test different issues:
    // try leakyFunction(allocator);  // Memory leak
    // try exitBypassesDefer(allocator);  // Exit bypasses defer
    // try doubleFree(allocator);  // Double free panic
    // try useAfterFree(allocator);  // Use after free
    // overflowPanic();  // Underflow panic
    // boundsCheck();  // Bounds check panic

    // Default: run the leaky function to show leak detection
    try leakyFunction(allocator);
}
