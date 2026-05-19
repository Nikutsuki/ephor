// Test fixture: ZA703 naming convention checks
// Verifies function naming based on Zig style guide:
//   - Return type is literally `type` → TitleCase
//   - Otherwise callable → camelCase
// Reference: https://ziglang.org/documentation/0.15.2/#Names
const std = @import("std");

// ============================================================================
// VALID: Type-returning functions → TitleCase (should NOT warn)
// ============================================================================

// Returns `type` directly
fn Point(comptime T: type) type {
    return struct { x: T, y: T };
}

// Multiple comptime params, returns type
fn ShortList(comptime T: type, comptime n: usize) type {
    return struct { items: [n]T };
}

// Template function returning type
fn ListTemplateFunction(comptime ChildType: type, comptime fixed_size: usize) type {
    return ShortList(ChildType, fixed_size);
}

// Pub fn returning type
pub fn MakeStruct(comptime T: type) type {
    return struct { value: T };
}

// ============================================================================
// VALID: Non-type-returning functions → camelCase (should NOT warn)
// ============================================================================

// Generic function returning T, not type
fn doubleIt(comptime T: type, value: T) T {
    return value * 2;
}

// Takes type param, returns instance of T
fn defaultValue(comptime T: type) T {
    return std.mem.zeroes(T);
}

// Takes type param, returns a concrete type
fn foo(comptime T: type) T {
    return std.mem.zeroes(T);
}

// Simple function, no type params
fn getValue() u32 {
    return 42;
}

// Error union return
fn parse() !void {}

// Takes allocator, returns error union
fn init(allocator: std.mem.Allocator) !void {
    _ = allocator;
}

// ============================================================================
// BAD: Type-returning function with camelCase name (SHOULD warn)
// ============================================================================

// Returns type but uses camelCase → should suggest TitleCase
fn makePoint(comptime T: type) type {
    return struct { x: T, y: T };
}

// Returns !type with camelCase → should suggest TitleCase
fn tryMakeType(x: u32) !type {
    _ = x;
    return struct {};
}

// ============================================================================
// BAD: Non-type-returning function with TitleCase name (SHOULD warn)
// ============================================================================

// Returns u32 but uses TitleCase → should suggest camelCase
fn GetValue() u32 {
    return 42;
}

// Returns void but uses TitleCase → should suggest camelCase
fn DoWork() void {}

// ============================================================================
// EDGE CASES (should NOT warn - correctly handled)
// ============================================================================

// Nested fn type in params - outer fn returns void, not type
fn register(comptime cb: fn (type) type, x: u32) void {
    _ = cb;
    _ = x;
}

// "type" as a substring in return type identifier (e.g. "typedef")
// Should NOT be treated as returning `type`
const typedef = u32;
fn getTypedef() typedef {
    return 0;
}

// Underscore-prefixed names are exempt
fn _helperReturningType(comptime T: type) type {
    return struct { value: T };
}

// ============================================================================
// VALID: Function pointer vars → camelCase (should NOT warn)
// Style guide: "If x is callable, then x should be camelCase"
// ============================================================================

// Qualified function assignment
var myHandler = std.debug.print;

// Explicit fn type annotation
var myCallback: fn () u32 = getValue;

// ============================================================================
// BAD: Function pointer var with wrong casing (SHOULD warn)
// ============================================================================

// Function pointer should be camelCase, not snake_case
var my_callback: fn () u32 = getValue;

// ============================================================================
// VALID: Error values → snake_case (should NOT warn)
// ============================================================================

fn returnGoodError() !void {
    return error.file_not_found;
}

fn returnGoodError2() !void {
    return error.out_of_memory;
}

const GoodErrorSet = error{
    file_not_found,
    access_denied,
    out_of_memory,
};

// ============================================================================
// BAD: Error values with CamelCase (SHOULD warn)
// ============================================================================

fn returnBadError() !void {
    return error.FileNotFound;
}

fn returnBadError2() !void {
    return error.OutOfMemory;
}

// ============================================================================
// BAD: Error set members with CamelCase (SHOULD warn)
// ============================================================================

const BadErrorSet = error{
    FileNotFound,
    AccessDenied,
};

// Single-line error set
const BadErrorSetInline = error{ FileNotFound, AccessDenied };

// ============================================================================
// VALID: Underscore-prefixed error names are exempt
// ============================================================================

const ExemptErrors = error{
    _internal_error,
    _FileNotFound,
};
