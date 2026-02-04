const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

// =============================================================================
// ZA101: Alloc without defer free
// =============================================================================

/// BAD: Allocates memory but forgets to free it
pub fn leakyFunction(allocator: Allocator) ![]u8 {
    const data = try allocator.alloc(u8, 1024);
    // Missing: defer allocator.free(data);

    // Do some work...
    @memset(data, 0);

    // Oops! Returns without freeing - memory leak!
    return data; // This is actually OK - ownership transferred
}

/// BAD: Creates object but forgets to destroy
pub fn leakyCreate(allocator: Allocator) !void {
    const node = try allocator.create(Node);
    // Missing: defer allocator.destroy(node);

    node.value = 42;
    // Function ends without freeing - ZA102 should fire
}

const Node = struct {
    value: i32 = 0,
    next: ?*Node = null,
};

// =============================================================================
// ZA103: Alloc without errdefer in error-returning function
// =============================================================================

/// BAD: Allocates then can fail without errdefer
pub fn missingErrdefer(allocator: Allocator) ![]u8 {
    const buffer = try allocator.alloc(u8, 512);
    // Missing: errdefer allocator.free(buffer);

    // This can fail! If it does, buffer leaks
    const result = try riskyOperation();
    _ = result;

    defer allocator.free(buffer);
    return buffer;
}

fn riskyOperation() !u32 {
    return 42;
}

// =============================================================================
// ZA104: Memory leak - not freed on all paths
// =============================================================================

/// BAD: Memory not freed on error path
pub fn conditionalLeak(allocator: Allocator, condition: bool) !void {
    const data = try allocator.alloc(u8, 256);

    if (condition) {
        allocator.free(data);
        return;
    }

    // Oops! data not freed when condition is false - ZA104 should fire
}

// =============================================================================
// ZA105: Use-after-free
// =============================================================================

/// BAD: Uses memory after freeing it
pub fn useAfterFree(allocator: Allocator) void {
    const data = allocator.alloc(u8, 100) catch return;

    // Free the memory
    allocator.free(data);

    // BAD: Using data after it was freed! - ZA105 should fire
    if (data.len > 0) {
        std.debug.print("Data length: {}\n", .{data.len});
    }
}

// =============================================================================
// ZA106: Double-free
// =============================================================================

/// BAD: Frees memory twice
pub fn doubleFree(allocator: Allocator) void {
    const buffer = allocator.alloc(u8, 64) catch return;

    // First free - OK
    allocator.free(buffer);

    // Second free - BAD! ZA106 should fire
    allocator.free(buffer);
}

// =============================================================================
// ZA201: Silent catch {} discards error
// =============================================================================

/// BAD: Silently discards errors
pub fn silentCatch(allocator: Allocator) void {
    // BAD: Error is silently discarded - ZA201 should fire
    const data = allocator.alloc(u8, 1024) catch {};
    _ = data;
}

/// BAD: Silent catch with ignored error variable
pub fn silentCatchIgnored() void {
    const file = std.fs.cwd().openFile("config.json", .{}) catch |_| {};
    _ = file;
}

// =============================================================================
// ZA202: catch unreachable will panic
// =============================================================================

/// BAD: Using catch unreachable on fallible operation
pub fn catchUnreachable(allocator: Allocator) []u8 {
    // BAD: This CAN fail if OOM - ZA202 should fire
    const data = allocator.alloc(u8, 1024) catch unreachable;
    return data;
}

// =============================================================================
// ZA203: orelse unreachable will panic
// =============================================================================

/// BAD: Using orelse unreachable on nullable
pub fn orelseUnreachable(maybe_value: ?i32) i32 {
    // BAD: This CAN be null - ZA203 should fire
    return maybe_value orelse unreachable;
}

// =============================================================================
// ZA204: = undefined may leak sensitive data
// =============================================================================

/// BAD: Using undefined for sensitive data
pub fn undefinedSensitive() void {
    // BAD: Uninitialized memory may contain sensitive data - ZA204 should fire
    var password: [32]u8 = undefined;
    _ = &password;
}

// =============================================================================
// ZA301: Function exceeds max lines (50)
// =============================================================================

/// BAD: Function is way too long
pub fn wayTooLongFunction() void {
    var x: i32 = 0;
    x += 1; // line 1
    x += 1; // line 2
    x += 1; // line 3
    x += 1; // line 4
    x += 1; // line 5
    x += 1; // line 6
    x += 1; // line 7
    x += 1; // line 8
    x += 1; // line 9
    x += 1; // line 10
    x += 1; // line 11
    x += 1; // line 12
    x += 1; // line 13
    x += 1; // line 14
    x += 1; // line 15
    x += 1; // line 16
    x += 1; // line 17
    x += 1; // line 18
    x += 1; // line 19
    x += 1; // line 20
    x += 1; // line 21
    x += 1; // line 22
    x += 1; // line 23
    x += 1; // line 24
    x += 1; // line 25
    x += 1; // line 26
    x += 1; // line 27
    x += 1; // line 28
    x += 1; // line 29
    x += 1; // line 30
    x += 1; // line 31
    x += 1; // line 32
    x += 1; // line 33
    x += 1; // line 34
    x += 1; // line 35
    x += 1; // line 36
    x += 1; // line 37
    x += 1; // line 38
    x += 1; // line 39
    x += 1; // line 40
    x += 1; // line 41
    x += 1; // line 42
    x += 1; // line 43
    x += 1; // line 44
    x += 1; // line 45
    x += 1; // line 46
    x += 1; // line 47
    x += 1; // line 48
    x += 1; // line 49
    x += 1; // line 50
    x += 1; // line 51 - now exceeds 50 - ZA301 should fire
    _ = x;
}

// =============================================================================
// ZA302: Function exceeds max nesting depth (4)
// =============================================================================

/// BAD: Too deeply nested
pub fn deeplyNested(a: bool, b: bool, c: bool, d: bool, e: bool) void {
    if (a) { // depth 1
        if (b) { // depth 2
            if (c) { // depth 3
                if (d) { // depth 4
                    if (e) { // depth 5 - exceeds 4 - ZA302 should fire
                        std.debug.print("Too deep!\n", .{});
                    }
                }
            }
        }
    }
}

// =============================================================================
// ZA303: Function has too many parameters (5)
// =============================================================================

/// BAD: Too many parameters
pub fn tooManyParams(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32) i32 {
    // 6 parameters exceeds default of 5 - ZA303 should fire
    return a + b + c + d + e + f;
}

// =============================================================================
// ZA304: Function has too many branches (10)
// =============================================================================

/// BAD: Too many branches
pub fn tooManyBranches(value: u8) []const u8 {
    // 12 if/else branches exceeds 10 - ZA304 should fire
    if (value == 0) return "zero";
    if (value == 1) return "one";
    if (value == 2) return "two";
    if (value == 3) return "three";
    if (value == 4) return "four";
    if (value == 5) return "five";
    if (value == 6) return "six";
    if (value == 7) return "seven";
    if (value == 8) return "eight";
    if (value == 9) return "nine";
    if (value == 10) return "ten";
    if (value == 11) return "eleven";
    return "other";
}

// =============================================================================
// GOOD EXAMPLES - These should NOT trigger warnings
// =============================================================================

/// GOOD: Proper defer free
pub fn properDefer(allocator: Allocator) !void {
    const data = try allocator.alloc(u8, 1024);
    defer allocator.free(data);

    @memset(data, 0);
    // Memory properly freed via defer
}

/// GOOD: Proper errdefer
pub fn properErrdefer(allocator: Allocator) ![]u8 {
    const buffer = try allocator.alloc(u8, 512);
    errdefer allocator.free(buffer);

    // Even if this fails, buffer is freed by errdefer
    const result = try riskyOperation();
    _ = result;

    return buffer; // Ownership transferred to caller
}

/// GOOD: Arena allocator - no individual free needed
pub fn arenaExample(arena: *std.heap.ArenaAllocator) !void {
    const allocator = arena.allocator();

    // These don't need individual free - arena frees all at once
    const data1 = try allocator.alloc(u8, 100);
    const data2 = try allocator.alloc(u8, 200);
    const data3 = try allocator.alloc(u8, 300);

    _ = data1;
    _ = data2;
    _ = data3;
    // All freed when arena.deinit() is called
}

/// GOOD: Ownership transfer to container
pub fn ownershipTransfer(allocator: Allocator) !void {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    const data = try allocator.alloc(u8, 10);
    // Ownership transferred to list
    try list.appendSlice(data);
}

/// GOOD: Return transfers ownership
pub fn returnOwnership(allocator: Allocator) ![]u8 {
    const data = try allocator.alloc(u8, 1024);
    // No defer needed - ownership transferred to caller
    return data;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Run examples (most will have issues!)
    _ = try leakyFunction(allocator);
    try properDefer(allocator);
}
