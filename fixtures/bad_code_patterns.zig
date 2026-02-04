const std = @import("std");

// ============================================================================
// ZA105: Use-after-free patterns
// ============================================================================

// Pattern 1: Simple use after free
fn uaf_simple(allocator: std.mem.Allocator) void {
    const data = allocator.alloc(u8, 100) catch return;
    allocator.free(data);
    data[0] = 42; // UAF!
}

// Pattern 2: Use after free in loop
fn uaf_in_loop(allocator: std.mem.Allocator) void {
    const buffer = allocator.alloc(u8, 256) catch return;
    allocator.free(buffer);
    for (buffer) |*byte| { // UAF!
        byte.* = 0;
    }
}

// Pattern 3: Passing freed pointer to function
fn uaf_passed_to_fn(allocator: std.mem.Allocator) void {
    const data = allocator.alloc(u8, 64) catch return;
    allocator.free(data);
    processData(data); // UAF!
}

fn processData(data: []u8) void {
    _ = data;
}

// Pattern 4: Use on RHS of reassignment (edge case - both LHS and RHS have var name)
fn uaf_in_reassignment(allocator: std.mem.Allocator) !void {
    var data = try allocator.alloc(u8, 64);
    allocator.free(data);
    data = transformData(data); // UAF! data used on RHS after free
}

fn transformData(input: []u8) []u8 {
    return input;
}

// ============================================================================
// ZA106: Double-free patterns
// ============================================================================

// Pattern 1: Simple double free
fn double_free_simple(allocator: std.mem.Allocator) void {
    const data = allocator.alloc(u8, 100) catch return;
    allocator.free(data);
    allocator.free(data); // Double free!
}

// Pattern 2: Double free with code between
fn double_free_with_code(allocator: std.mem.Allocator) void {
    const buffer = allocator.alloc(u8, 256) catch return;
    allocator.free(buffer);
    doSomethingElse();
    allocator.free(buffer); // Double free!
}

fn doSomethingElse() void {}

// Pattern 3: Conditional double free (both branches free)
fn double_free_conditional(allocator: std.mem.Allocator, condition: bool) void {
    const data = allocator.alloc(u8, 100) catch return;
    if (condition) {
        allocator.free(data);
    }
    allocator.free(data); // Double free if condition was true!
}

// ============================================================================
// ZA101/ZA102: Missing defer patterns
// ============================================================================

// Pattern 1: Alloc without any defer
fn alloc_no_defer(allocator: std.mem.Allocator) void {
    const data = allocator.alloc(u8, 100) catch return;
    process(data);
    // Memory leak - no defer!
}

fn process(data: []u8) void {
    _ = data;
}

// Pattern 2: Create without defer
fn create_no_defer(allocator: std.mem.Allocator) void {
    const obj = allocator.create(SomeStruct) catch return;
    obj.* = SomeStruct{};
    // Memory leak - no defer destroy!
}

const SomeStruct = struct {
    value: u32 = 0,
};

// Pattern 3: Defer only in conditional branch
fn defer_only_in_if(allocator: std.mem.Allocator, cleanup: bool) void {
    const data = allocator.alloc(u8, 100) catch return;
    if (cleanup) {
        defer allocator.free(data);
        process(data);
    }
    // Leaks if cleanup is false!
}

// ============================================================================
// ZA103: Missing errdefer patterns
// ============================================================================

// Pattern 1: Alloc then try without errdefer
fn errdefer_gap(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 100);
    // MISSING errdefer - if next line fails, data leaks
    const more = try allocator.alloc(u8, 200);
    errdefer allocator.free(more);
    _ = data;
}

// Pattern 2: Multiple allocations, only last has errdefer
fn multiple_alloc_one_errdefer(allocator: std.mem.Allocator) !void {
    const a = try allocator.alloc(u8, 100);
    const b = try allocator.alloc(u8, 100); // a leaks if this fails
    const c = try allocator.alloc(u8, 100); // a,b leak if this fails
    errdefer allocator.free(c);
    _ = a;
    _ = b;
}

// Pattern 3: Create then try without errdefer
fn create_errdefer_gap(allocator: std.mem.Allocator) !*SomeStruct {
    const obj = try allocator.create(SomeStruct);
    // MISSING errdefer destroy
    try riskyInit(obj);
    return obj;
}

fn riskyInit(obj: *SomeStruct) !void {
    _ = obj;
}

// ============================================================================
// ZA201: Silent catch patterns
// ============================================================================

// Pattern 1: Empty catch block
fn silent_catch_empty() void {
    _ = riskyOperation() catch {};
}

fn riskyOperation() !u32 {
    return 42;
}

// Pattern 2: Catch with only logging (still bad)
fn silent_catch_log_only() void {
    _ = anotherRiskyOp() catch |err| {
        std.debug.print("Error: {}\n", .{err});
        // Still silent - doesn't handle or propagate!
    };
}

fn anotherRiskyOp() !void {}

// ============================================================================
// ZA204: Undefined variable patterns
// ============================================================================

// Pattern 1: Read before write
fn undefined_read() u32 {
    var x: u32 = undefined;
    return x; // Reading undefined!
}

// Pattern 2: Conditional initialization
fn undefined_conditional(condition: bool) u32 {
    var result: u32 = undefined;
    if (condition) {
        result = 42;
    }
    return result; // Undefined if condition was false!
}

// Pattern 3: Use in expression before init
fn undefined_in_expr() u32 {
    var a: u32 = undefined;
    var b: u32 = undefined;
    const sum = a + b; // Both undefined!
    return sum;
}

// ============================================================================
// ZA205: Discarded error patterns
// ============================================================================

// Pattern 1: Discarding error union with _
fn discard_error_union() void {
    _ = mightFail(); // Discards potential error!
}

fn mightFail() !u32 {
    return error.SomethingWentWrong;
}

// Pattern 2: Discarding in loop
fn discard_in_loop(items: []const u32) void {
    for (items) |item| {
        _ = processItem(item); // Error discarded each iteration!
    }
}

fn processItem(item: u32) !void {
    _ = item;
}

// ============================================================================
// VALID CODE - These should NOT trigger warnings
// ============================================================================

// Valid: Proper defer
fn valid_defer(allocator: std.mem.Allocator) void {
    const data = allocator.alloc(u8, 100) catch return;
    defer allocator.free(data);
    process(data);
}

// Valid: Proper errdefer chain
fn valid_errdefer(allocator: std.mem.Allocator) !void {
    const a = try allocator.alloc(u8, 100);
    errdefer allocator.free(a);
    const b = try allocator.alloc(u8, 100);
    errdefer allocator.free(b);
    _ = a;
}

// Valid: Catch with return (not silent)
fn valid_catch_return() !void {
    _ = riskyOperation() catch |err| return err;
}

// Valid: Free in catch that returns (path-sensitive)
fn valid_catch_free_return(allocator: std.mem.Allocator) !void {
    const data = allocator.alloc(u8, 100) catch return error.OutOfMemory;
    const result = riskyOperation() catch {
        allocator.free(data);
        return error.Failed;
    };
    // data is still valid here - catch returned
    process(data);
    _ = result;
    defer allocator.free(data);
}

// Valid: Switch arm frees (mutually exclusive)
fn valid_switch_free(allocator: std.mem.Allocator, which: enum { a, b }) void {
    const data = allocator.alloc(u8, 100) catch return;
    switch (which) {
        .a => allocator.free(data),
        .b => allocator.free(data),
    }
}

// Valid: Factory pattern (ownership transferred via return)
fn valid_factory(allocator: std.mem.Allocator) !*SomeStruct {
    const obj = try allocator.create(SomeStruct);
    errdefer allocator.destroy(obj);
    obj.* = SomeStruct{};
    return obj; // Ownership transferred to caller
}

// ============================================================================
// ZA607 Valid Patterns - These should NOT trigger "read before assignment"
// ============================================================================

// Valid: .len access is compile-time property, not a read of undefined values
fn valid_len_access(message: []const u8) bool {
    var buffer: [2000]u8 = undefined;
    if (message.len > buffer.len) return false; // .len is type property
    for (message, 0..) |char, i| {
        buffer[i] = char;
    }
    return true;
}

// Valid: Variable name in comment is not a read
fn valid_comment_reference() void {
    var data: u32 = undefined;
    // Initialize data below
    data = 42;
    _ = data;
}

// Valid: Struct field with same name as local is different variable
const TestStruct = struct {
    file_id: ?[32]u8 = null,
};

fn valid_struct_field_same_name(self: *TestStruct) [32]u8 {
    var file_id: [32]u8 = undefined;
    if (self.file_id) |existing_id| {
        file_id = existing_id;
    } else {
        @memset(&file_id, 0);
    }
    return file_id;
}

// Valid: If-else where both branches assign
fn valid_if_else_assign(condition: bool) u32 {
    var result: u32 = undefined;
    if (condition) {
        result = 42;
    } else {
        result = 0;
    }
    return result;
}

// Valid: Loop fill pattern
fn valid_loop_fill(data: []const u8) [100]u8 {
    var buffer: [100]u8 = undefined;
    for (data, 0..) |byte, i| {
        if (i >= buffer.len) break;
        buffer[i] = byte;
    }
    return buffer;
}

// Valid: @memcpy fill pattern
fn valid_memcpy_fill(src: []const u8) [1024]u8 {
    var buffer: [1024]u8 = undefined;
    const len = @min(src.len, buffer.len);
    @memcpy(buffer[0..len], src[0..len]);
    return buffer;
}

// Valid: Crypto/hash final fills buffer
fn valid_hash_fill(data: []const u8) [32]u8 {
    var hash_output: [32]u8 = undefined;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(data);
    hasher.final(&hash_output);
    return hash_output;
}

// Valid: @memset fill pattern
fn valid_memset_fill() [64]u8 {
    var buffer: [64]u8 = undefined;
    @memset(&buffer, 0);
    return buffer;
}

// Valid: random.bytes fill pattern
fn valid_random_fill() [32]u8 {
    var nonce: [32]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    return nonce;
}

// Valid: String literal containing variable name (not a read)
fn valid_string_literal() void {
    var data: u32 = undefined;
    const msg = "data should be initialized";
    _ = msg;
    data = 42;
    _ = data;
}

// Valid: Nested struct field access (a.b.c where c matches local name)
const Inner = struct { value: u32 = 0 };
const Outer = struct { inner: Inner = .{} };

fn valid_nested_field(obj: *Outer) u32 {
    var inner: u32 = undefined;
    inner = obj.inner.value; // obj.inner is different from local inner
    return inner;
}

// Valid: While-loop initialization
fn valid_while_init(limit: usize) [100]u8 {
    var buffer: [100]u8 = undefined;
    var i: usize = 0;
    while (i < limit and i < buffer.len) : (i += 1) {
        buffer[i] = @intCast(i);
    }
    return buffer;
}

// ============================================================================
// ZA105 Edge Cases - Use-after-free valid patterns
// ============================================================================

// Valid: errdefer cleanup is not use-after-free
fn valid_errdefer_cleanup(allocator: std.mem.Allocator) !*u8 {
    const ptr = try allocator.create(u8);
    errdefer allocator.destroy(ptr); // This is cleanup, not UAF
    ptr.* = 42;
    return ptr;
}

// Valid: Cleanup in catch block before return
fn valid_catch_cleanup(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 100);
    riskyOperation() catch |err| {
        allocator.free(data); // Cleanup before return
        return err;
    };
    defer allocator.free(data);
}

// ============================================================================
// ZA201 Edge Cases - Silent catch patterns
// ============================================================================

// BAD: Silent catch on critical operation
fn bad_silent_catch_critical() void {
    _ = criticalOperation() catch {}; // Should warn!
}

fn criticalOperation() !u32 {
    return error.CriticalFailure;
}

// Valid: Silent catch on cleanup/best-effort operation
fn valid_silent_catch_cleanup(file: std.fs.File) void {
    file.close() catch {}; // Best-effort cleanup is ok
}

// NOTE: This WILL be flagged (correctly) - comments don't make it "safe".
// Silent catch on unknown functions should be reviewed.
// Options: 1) Handle error, 2) Add to config whitelist, 3) Use explicit discard
fn correctly_flagged_silent_catch() void {
    // User thinks this is safe, but linter correctly flags for review
    _ = sendTelemetry() catch {}; // ZA201: Will warn (correct behavior)
}

fn sendTelemetry() !void {
    return error.NetworkUnavailable;
}

// ============================================================================
// ZA106 Edge Cases - Double-free valid patterns
// ============================================================================

// Valid: Free in mutually exclusive branches
fn valid_exclusive_free(allocator: std.mem.Allocator, mode: enum { sync, async_mode }) void {
    const data = allocator.alloc(u8, 100) catch return;
    if (mode == .sync) {
        allocator.free(data);
        return;
    }
    // Only reaches here if mode == .async_mode
    defer allocator.free(data);
}

// Valid: Free in catch that always returns
fn valid_catch_return_free(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 100);
    const result = riskyOperation() catch {
        allocator.free(data);
        return error.OperationFailed;
    };
    _ = result;
    defer allocator.free(data);
}

// ============================================================================
// Complex Edge Cases
// ============================================================================

// Edge case: Multiple variables with similar names
fn edge_similar_names() void {
    var data: u32 = undefined;
    var data_len: u32 = 10; // Not the same as data
    var my_data: u32 = 20; // Not the same as data
    _ = data_len;
    _ = my_data;
    data = 42;
    _ = data;
}

// Edge case: Variable name appears as substring
fn edge_substring_name() void {
    var id: u32 = undefined;
    const valid_id = true; // "id" is substring, but different variable
    const provide = false; // "id" is substring in middle
    _ = valid_id;
    _ = provide;
    id = 1;
    _ = id;
}

// Edge case: Pointer passed to function (initialization by reference)
fn edge_init_by_ref() [32]u8 {
    var key: [32]u8 = undefined;
    initializeKey(&key); // Function initializes via pointer
    return key;
}

fn initializeKey(out: *[32]u8) void {
    @memset(out, 0);
}

// Valid: Comptime blocks - compiler catches undefined at comptime
fn valid_comptime_init() [95]u16 {
    const chars = comptime blk: {
        var result: [95]u16 = undefined;
        var i: u16 = 32;
        while (i < 127) : (i += 1) {
            result[i - 32] = i;
        }
        break :blk result;
    };
    return chars;
}

// ============================================================================
// Linter Philosophy - "Review and Decide" Patterns
// ============================================================================
// These warnings are CORRECT but require human judgment.
// The linter flags them for review; developers decide if they're acceptable.

// Example 1: ZA201 - Best-effort operations that intentionally ignore errors
// fn send_analytics() void {
//     _ = telemetry.send() catch {};  // ZA201 warns - dev reviews, maybe acceptable
// }

// Example 2: ZA301/302/304 - Complex code that's inherently complex
// Large switch statements (AST parsers) will trigger ZA304
// Deep nesting (state machines) will trigger ZA302
// Dev reviews: is refactoring possible/worth it?

// Example 3: ZA103 - Ownership transfer patterns
// fn create_resource() !*Resource {
//     const r = try allocator.create(Resource);
//     // No errdefer - ownership transfers to caller
//     return r;  // ZA103 warns - dev confirms ownership semantics
// }
