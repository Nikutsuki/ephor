// Rhyos Labs - Ephor
// Good code patterns that MUST NOT be flagged as issues.
// Each section documents a known false positive pattern found in real community projects.
// Ephor should report ZERO issues on this file.
// Copyright (C) 2025-2026 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

const std = @import("std");

// ============================================================================
// ZA101/ZA103 FALSE POSITIVES: Arena allocator through std.mem.Allocator interface
// Source: tigerbeetle, zls, and many community projects
// Root cause: ArenaAllocator passed as std.mem.Allocator loses type info
// ============================================================================

// Pattern 1: Arena allocator parameter named "arena" typed as std.mem.Allocator
// Found in: zls/src/features/completions.zig, tigerbeetle/src/scripts/amqp.zig
fn arena_alloc_no_errdefer(arena: std.mem.Allocator) ![]u8 {
    const data = try arena.alloc(u8, 100); // ZA103 false positive: arena needs no errdefer
    const more = try arena.alloc(u8, 200); // ZA103 false positive: same arena
    _ = more;
    return data;
}

// Pattern 2: Arena allocator in struct field
// Found in: zls/src/analysis.zig
const Analyser = struct {
    arena: std.mem.Allocator,

    fn analyse(self: *Analyser) ![]u8 {
        const result = try self.arena.alloc(u8, 256); // ZA103 false positive
        return result;
    }
};

// Pattern 3: Arena allocator — no defer free needed (bulk free on arena.deinit)
// Found in: tigerbeetle/src/lsm/binary_search_benchmark.zig
fn arena_alloc_no_defer(arena: std.mem.Allocator) !void {
    const page_picker = try arena.alloc(usize, 100); // ZA101 false positive
    const value_picker = try arena.alloc(usize, 200); // ZA101 false positive
    _ = page_picker;
    _ = value_picker;
    // No defer free needed — arena frees everything at once
}

// Pattern 4: Allocation immediately returned (ownership transfer)
// Found in: tigerbeetle/src/multiversion.zig
fn alloc_and_return(allocator: std.mem.Allocator) ![]u8 {
    const path = try allocator.alloc(u8, 256); // ZA103 false positive: immediately returned
    return path; // Ownership transferred to caller
}

// ============================================================================
// ZA205 FALSE POSITIVES: Discarded results that are actually safe
// These patterns MUST NOT trigger ZA205
// ============================================================================

// Pattern 5: User-defined struct with void method
// Must not confuse with stdlib patterns
const MyLogger = struct {
    level: u8,

    pub fn clear(self: *MyLogger) void {
        self.level = 0;
    }

    pub fn reset(self: *MyLogger) void {
        self.level = 0;
    }
};

// Pattern 6: User-defined enum with void method
// Enums can have methods in Zig — ephor must parse them
const State = enum {
    active,
    inactive,
    paused,

    pub fn deactivate(self: *State) void {
        self.* = .inactive;
    }

    pub fn reset(self: *State) void {
        self.* = .inactive;
    }
};

// Pattern 7: User-defined tagged union with void method
const Command = union(enum) {
    start: u32,
    stop: void,
    pause: void,

    pub fn cancel(self: *Command) void {
        self.* = .{ .stop = {} };
    }
};

// Pattern 8: User-defined struct with value-returning method (safe to discard)
const Counter = struct {
    count: u32,

    pub fn increment(self: *Counter) u32 {
        self.count += 1;
        return self.count;
    }

    pub fn getCount(self: *const Counter) u32 {
        return self.count;
    }
};

// Pattern 9: User-defined struct with optional-returning method (safe to discard)
const Cache = struct {
    data: ?u32,

    pub fn lookup(self: *const Cache) ?u32 {
        return self.data;
    }
};

// Pattern 10: Packed struct with void method (hardware registers, protocol headers)
const Flags = packed struct {
    readable: bool,
    writable: bool,
    _padding: u6 = 0,

    pub fn clear(self: *Flags) void {
        self.readable = false;
        self.writable = false;
    }
};

// Pattern 11: Extern struct with void method (C FFI)
const CHandle = extern struct {
    fd: i32,

    pub fn close(self: *CHandle) void {
        self.fd = -1;
    }
};

// Pattern 12: Top-level void function
fn helperVoid() void {}

// Pattern 13: Top-level function returning value (safe to discard)
fn computeValue() u32 {
    return 42;
}

// Pattern 14: Noreturn function (safe to discard)
const Processor = struct {
    data: u32,

    pub fn halt(self: *Processor) noreturn {
        _ = self;
        while (true) {}
    }
};

// ============================================================================
// ZA205 MUST-FLAG: These SHOULD be flagged (error unions being discarded)
// Included here for completeness — tests verify these ARE detected
// ============================================================================

// Pattern 15: User-defined struct with error-returning method
const FlushableLogger = struct {
    data: u32,

    pub fn flush(self: *FlushableLogger) !void {
        _ = self;
        return;
    }

    pub fn save(self: *FlushableLogger) !u32 {
        _ = self;
        return 42;
    }
};

// Pattern 16: User-defined enum with error-returning method
const Connection = enum {
    open,
    closed,

    pub fn tryConnect(self: *Connection) !void {
        _ = self;
        return;
    }
};

// Pattern 17: User-defined union with error-returning method
const Result = union(enum) {
    ok: u32,
    fail: void,

    pub fn tryUnwrap(self: Result) !u32 {
        return switch (self) {
            .ok => |v| v,
            .fail => error.Failed,
        };
    }
};

// Pattern 18: Top-level error-returning function
fn riskyOp() !void {
    return;
}

fn riskyCompute() !u32 {
    return 42;
}

// Pattern 5 (arena): Cross-function propagation with multi-line call
// Source: tigerbeetle/src/lsm/binary_search_benchmark.zig
// Arena created in caller, passed as Nth argument to callee via multi-line call
fn multiArgCallee(
    _: u32,
    _: []const u8,
    alloc: std.mem.Allocator,
    _: bool,
) !u64 {
    const page_picker = try alloc.alloc(usize, 100); // ZA101 FP without propagation
    const value_picker = try alloc.alloc(usize, 200); // ZA101 FP without propagation
    _ = page_picker;
    _ = value_picker;
    return 42;
}

fn multiArgCaller() !void {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    _ = try multiArgCallee(
        1,
        "test",
        arena_impl.allocator(),
        true,
    );
}

// ============================================================================
// Exercise functions — these call the patterns above
// ============================================================================

// Safe discards — NONE of these should trigger ZA205
fn exerciseSafePatterns() void {
    // User-defined struct void methods
    var logger = MyLogger{ .level = 5 };
    _ = logger.clear();
    _ = logger.reset();

    // User-defined enum void methods
    var state: State = .active;
    _ = state.deactivate();
    _ = state.reset();

    // User-defined union void method
    var cmd: Command = .{ .start = 1 };
    _ = cmd.cancel();

    // User-defined value-returning methods (safe to discard)
    var counter = Counter{ .count = 0 };
    _ = counter.increment();
    _ = counter.getCount();

    // User-defined optional-returning method (safe to discard)
    const cache = Cache{ .data = 42 };
    _ = cache.lookup();

    // Packed struct void method
    var flags = Flags{ .readable = true, .writable = true };
    _ = flags.clear();

    // Extern struct void method
    var handle = CHandle{ .fd = 3 };
    _ = handle.close();

    // Top-level void function
    _ = helperVoid();

    // Top-level value function
    _ = computeValue();
}

// Unsafe discards — ALL of these SHOULD trigger ZA205
fn exerciseUnsafePatterns() void {
    // User-defined error-returning struct methods
    var flogger = FlushableLogger{ .data = 0 };
    _ = flogger.flush(); // SHOULD flag ZA205
    _ = flogger.save(); // SHOULD flag ZA205

    // User-defined error-returning enum method
    var conn: Connection = .open;
    _ = conn.tryConnect(); // SHOULD flag ZA205

    // User-defined error-returning union method
    const result: Result = .{ .ok = 42 };
    _ = result.tryUnwrap(); // SHOULD flag ZA205

    // Top-level error-returning functions
    _ = riskyOp(); // SHOULD flag ZA205
    _ = riskyCompute(); // SHOULD flag ZA205
}

// ============================================================================
// ZA101/ZA103 arena patterns exercised
// ============================================================================

fn exerciseArenaPatterns() !void {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // All of these use arena — no individual defer/errdefer needed
    _ = try arena_alloc_no_errdefer(arena);
    try arena_alloc_no_defer(arena);
    _ = try alloc_and_return(arena);
}
