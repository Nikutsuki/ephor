// False positive fixture: Arena accessed through struct field chain
// No ZA101/ZA102/ZA103 should fire — arena allocations don't need per-alloc free.
// Type-based detection: field declared as std.heap.ArenaAllocator in struct.

const std = @import("std");

// ============================================================================
// Struct with ArenaAllocator field (type-based detection)
// ============================================================================

const Analyser = struct {
    arena: std.heap.ArenaAllocator,
    data: []const u8,
};

const Context = struct {
    req_arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
};

const Server = struct {
    conn_arena: *std.heap.ArenaAllocator,
    buffer: []u8,
};

const Parser = struct {
    fba: std.heap.FixedBufferAllocator,
    input: []const u8,
};

// ============================================================================
// Direct field chain allocations (self.arena.method)
// ============================================================================

fn arena_field_alloc(self: *Analyser) !void {
    const data = try self.arena.allocator().alloc(u8, 100);
    process(data);
}

fn arena_field_dupe(self: *Analyser) !void {
    const data = try self.arena.allocator().dupe(u8, "hello");
    process(data);
}

fn arena_field_create(self: *Analyser) !void {
    const node = try self.arena.allocator().create(Analyser);
    process(node);
}

// ============================================================================
// Context struct with named arena field
// ============================================================================

fn ctx_arena_alloc(ctx: *Context) !void {
    const data = try ctx.req_arena.allocator().alloc(u8, 256);
    process(data);
}

// ============================================================================
// Pointer to arena (common in server code)
// ============================================================================

fn ptr_arena_alloc(srv: *Server) !void {
    const data = try srv.conn_arena.allocator().alloc(u8, 512);
    process(data);
}

// ============================================================================
// FixedBufferAllocator through field chain
// ============================================================================

fn fba_field_alloc(parser: *Parser) !void {
    const data = try parser.fba.allocator().alloc(u8, 64);
    process(data);
}

fn process(data: anytype) void {
    _ = data;
}
