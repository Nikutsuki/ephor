// Test case: C FFI out-parameter ownership transfer
// This pattern is common in C API wrappers (e.g., ghostty)
// Expected: NO warning for ZA102 - ownership transferred to out-param
const std = @import("std");

pub const Parser = struct {
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .data = &.{}, .allocator = allocator };
    }

    pub fn deinit(self: *Parser) void {
        self.allocator.free(self.data);
    }
};

pub const Result = enum(c_int) {
    success = 0,
    out_of_memory = 1,
};

// C API: create function with out-parameter
pub fn parser_new(
    allocator: std.mem.Allocator,
    result: **Parser, // out-parameter - receives ownership
) callconv(.c) Result {
    const ptr = allocator.create(Parser) catch
        return .out_of_memory;
    ptr.* = Parser.init(allocator);
    result.* = ptr; // Ownership transfer to out-parameter
    return .success;
}

// C API: destroy function - caller's responsibility
pub fn parser_free(parser: *Parser) callconv(.c) void {
    const allocator = parser.allocator;
    parser.deinit();
    allocator.destroy(parser);
}
