// Zig 0.15.x Compatibility Layer
//
// This module provides version-specific implementations and pattern definitions
// for Zig 0.15.x. Used by Ephor to detect version-appropriate issues.
//
// API Characteristics (0.15.x):
//   - HashMap.put(key, value) - no allocator argument
//   - ArrayList.append(allocator, item) - allocator required
//   - ArrayListUnmanaged - preferred for embedded use
//   - std.mem.Allocator passed to methods, not stored in containers
//   - zig-cache renamed to .zig-cache

const std = @import("std");

/// Version identifier
pub const version = "0.15";

/// Full version range supported
pub const min_version = "0.15.0";
pub const max_version = "0.15.255";

/// API Notes for this version
pub const notes =
    \\Zig 0.15.x API Notes:
    \\  - std.StringHashMap.put(key, value) - allocator stored in struct
    \\  - std.ArrayListUnmanaged.append(allocator, item)
    \\  - std.ArrayListUnmanaged.deinit(allocator)
    \\  - std.ArrayListUnmanaged.toOwnedSlice(allocator)
    \\  - Use GeneralPurposeAllocator for leak detection
    \\  - StaticStringMap replaces ComptimeStringMap
    \\  - std.process.Child replaces std.ChildProcess
;

// ============================================================================
// Builtin Functions
// Complete list of @builtins available in Zig 0.15.x
// ============================================================================

pub const builtins = [_][]const u8{
    // Type introspection
    "@This",
    "@Type",
    "@TypeOf",
    "@typeInfo",
    "@typeName",
    "@hasDecl",
    "@hasField",
    "@field",
    "@fieldParentPtr",
    "@unionInit",
    "@tagName",
    "@enumFromInt",
    "@intFromEnum",
    "@errorFromInt",
    "@intFromError",
    "@errorName",

    // Memory operations
    "@alignOf",
    "@sizeOf",
    "@bitSizeOf",
    "@offsetOf",
    "@bitOffsetOf",
    "@alignCast",
    "@ptrCast",
    "@constCast",
    "@volatileCast",
    "@addrSpaceCast",
    "@intFromPtr",
    "@ptrFromInt",
    "@intCast",
    "@floatCast",
    "@floatFromInt",
    "@intFromFloat",
    "@intFromBool",
    "@bitCast",
    "@truncate",
    "@errorCast",
    "@memcpy",
    "@memset",

    // Math operations
    "@abs",
    "@min",
    "@max",
    "@clz",
    "@ctz",
    "@popCount",
    "@byteSwap",
    "@bitReverse",
    "@sqrt",
    "@sin",
    "@cos",
    "@tan",
    "@exp",
    "@log",
    "@floor",
    "@ceil",
    "@round",
    "@trunc",
    "@mod",
    "@rem",
    "@divExact",
    "@divFloor",
    "@divTrunc",
    "@mulAdd",
    "@addWithOverflow",
    "@subWithOverflow",
    "@mulWithOverflow",
    "@shlExact",
    "@shlWithOverflow",
    "@shrExact",

    // Vector operations
    "@Vector",
    "@splat",
    "@shuffle",
    "@select",
    "@reduce",

    // Atomics
    "@atomicLoad",
    "@atomicStore",
    "@atomicRmw",
    "@cmpxchgWeak",
    "@cmpxchgStrong",
    "@fence",

    // Control flow and debugging
    "@panic",
    "@trap",
    "@breakpoint",
    "@compileError",
    "@compileLog",
    "@src",
    "@returnAddress",
    "@frameAddress",
    "@errorReturnTrace",
    "@call",

    // C interop
    "@cImport",
    "@cInclude",
    "@cDefine",
    "@cUndef",
    "@cVaArg",
    "@cVaCopy",
    "@cVaEnd",
    "@cVaStart",

    // Misc
    "@import",
    "@embedFile",
    "@export",
    "@extern",
    "@as",
    "@inComptime",
    "@setRuntimeSafety",
    "@setEvalBranchQuota",
    "@setFloatMode",
    "@setAlignStack",
    "@setCold",
    "@optimizeFor",
    "@prefetch",

    // WebAssembly
    "@wasmMemorySize",
    "@wasmMemoryGrow",
    "@workItemId",
    "@workGroupId",
    "@workGroupSize",
};

// ============================================================================
// Methods that return optionals (?T)
// These are SAFE to discard with `_ = ` - not an error
// Used by ZA205/ZA201 to avoid false positives
// ============================================================================

pub const optional_methods = [_][]const u8{
    // Iterator methods (return ?T)
    ".next()",
    ".peek()",

    // HashMap/StringHashMap lookups (return ?V or ?*V)
    ".get(",
    ".getKey(",
    ".getEntry(",
    ".getPtr(",
    ".fetchRemove(",
    ".fetchPut(",

    // ArrayHashMap methods
    ".getIndex(",
    ".swapRemove(",
    ".orderedRemove(",

    // ArrayList optional methods
    ".popOrNull()",
    ".getLastOrNull(",
    ".getLast()",

    // BoundedArray
    ".popOrNull()",

    // MultiArrayList
    ".popOrNull()",

    // std.mem module functions (return ?usize)
    "mem.indexOf(",
    "mem.lastIndexOf(",
    "mem.indexOfScalar(",
    "mem.indexOfAny(",
    "mem.indexOfNone(",
    "mem.indexOfPos(",
    "mem.indexOfPosLinear(",
    "mem.lastIndexOfScalar(",
    "mem.lastIndexOfAny(",
    "mem.lastIndexOfNone(",

    // String/slice searching
    "std.mem.indexOf(",
    "std.mem.lastIndexOf(",

    // fs.path functions
    "fs.path.dirname(",
    "fs.path.basename(",
    "fs.path.extension(",
    "std.fs.path.dirname(",
    "std.fs.path.basename(",
    "std.fs.path.extension(",

    // Tokenizer/Parser methods
    ".peek(",
    ".peekNext(",

    // Environment
    "std.process.getenv(",
    "std.posix.getenv(",

    // JSON
    ".objectGet(",
    ".objectGetPtr(",
};

// ============================================================================
// Methods that return error unions (!T)
// These should NOT be silently discarded - ZA205 should flag them
// ============================================================================

pub const error_methods = [_][]const u8{
    // File operations
    ".read(",
    ".readAll(",
    ".readAtLeast(",
    ".readUntilDelimiter(",
    ".readUntilDelimiterOrEof(",
    ".write(",
    ".writeAll(",
    ".print(",
    ".open(",
    ".openFile(",
    ".openDir(",
    ".openDirAbsolute(",
    ".openIterableDir(",
    ".close(",
    ".create(",
    ".createFile(",
    ".makeDir(",
    ".makeDirAbsolute(",
    ".makePath(",
    ".deleteFile(",
    ".deleteDir(",
    ".deleteTree(",
    ".rename(",
    ".copyFile(",
    ".stat(",
    ".fstat(",
    ".readLink(",
    ".realpath(",
    ".access(",
    ".seek(",
    ".seekTo(",
    ".seekBy(",
    ".getPos(",
    ".getEndPos(",
    ".setEndPos(",
    ".sync(",
    ".lock(",
    ".unlock(",

    // Memory allocation
    ".alloc(",
    ".allocSentinel(",
    ".realloc(",
    ".resize(",
    ".create(",
    ".alignedAlloc(",
    ".dupeZ(",
    ".dupe(",

    // Network operations
    ".connect(",
    ".listen(",
    ".accept(",
    ".send(",
    ".recv(",
    ".sendTo(",
    ".recvFrom(",
    ".bind(",

    // Process operations
    ".spawn(",
    ".wait(",
    ".kill(",
    ".exec(",

    // Thread operations
    ".spawn(",
    ".join(",

    // Parsing
    ".parse(",
    ".parseFromSlice(",
    ".parseInt(",
    ".parseFloat(",
    ".parseUnsigned(",

    // Formatting
    ".format(",
    ".allocPrint(",
    ".bufPrint(",

    // JSON
    ".parse(",
    ".parseFromSlice(",
    ".stringify(",
    ".stringifyAlloc(",

    // Compression
    ".compress(",
    ".decompress(",

    // Crypto
    ".hash(",
    ".verify(",
    ".sign(",
    ".encrypt(",
    ".decrypt(",

    // ArrayList/containers that can fail
    ".append(",
    ".appendSlice(",
    ".appendNTimes(",
    ".insert(",
    ".insertSlice(",
    ".ensureTotalCapacity(",
    ".ensureUnusedCapacity(",
    ".addOne(",
    ".addManyAsArray(",
    ".addManyAsSlice(",
    ".toOwnedSlice(",
    ".clone(",

    // HashMap operations that can fail
    ".put(",
    ".putNoClobber(",
    ".getOrPut(",
    ".getOrPutValue(",
    ".fetchPut(",
    ".ensureTotalCapacity(",
    ".ensureUnusedCapacity(",

    // Build system
    ".addModule(",
    ".addIncludePath(",
    ".addLibraryPath(",
    ".linkLibrary(",
    ".linkSystemLibrary(",
};

// ============================================================================
// Allocation patterns - for memory leak detection (ZA101, ZA102)
// ============================================================================

pub const alloc_patterns = [_][]const u8{
    ".alloc(",
    ".alignedAlloc(",
    ".allocSentinel(",
    "allocator.alloc(",
    "allocator.alignedAlloc(",
};

pub const create_patterns = [_][]const u8{
    ".create(",
    "allocator.create(",
};

pub const realloc_patterns = [_][]const u8{
    ".realloc(",
    ".resize(",
    "allocator.realloc(",
    "allocator.resize(",
};

// ============================================================================
// Deallocation patterns - must pair with alloc (ZA101, ZA102)
// ============================================================================

pub const free_patterns = [_][]const u8{
    ".free(",
    "allocator.free(",
};

pub const destroy_patterns = [_][]const u8{
    ".destroy(",
    "allocator.destroy(",
};

// ============================================================================
// Dangerous patterns - potential runtime panics
// ============================================================================

pub const panic_patterns = [_][]const u8{
    "catch unreachable",
    "orelse unreachable",
    "@panic(",
    "unreachable",
};

pub const undefined_patterns = [_][]const u8{
    "= undefined",
    ": undefined",
};

// ============================================================================
// Keywords and language constructs
// ============================================================================

pub const keywords = [_][]const u8{
    "fn ",
    "pub ",
    "const ",
    "var ",
    "if ",
    "else ",
    "switch ",
    "while ",
    "for ",
    "return ",
    "break ",
    "continue ",
    "defer ",
    "errdefer ",
    "try ",
    "catch ",
    "orelse ",
    "and ",
    "or ",
    "comptime ",
    "inline ",
    "noalias ",
    "struct ",
    "enum ",
    "union ",
    "error ",
    "test ",
    "usingnamespace ",
    "threadlocal ",
    "extern ",
    "export ",
    "align ",
    "packed ",
    "volatile ",
    "allowzero ",
    "anytype ",
    "anyframe ",
    "anyopaque ",
    "anyerror ",
    "suspend ",
    "resume ",
    "async ",
    "await ",
    "nosuspend ",
};

// ============================================================================
// Breaking changes from 0.14.x to 0.15.x
// ============================================================================

pub const breaking_changes = [_][]const u8{
    "ArrayList.init(allocator) -> ArrayList{} (allocator passed to methods)",
    "list.append(item) -> list.append(allocator, item)",
    "list.deinit() -> list.deinit(allocator)",
    "list.toOwnedSlice() -> list.toOwnedSlice(allocator)",
    "ComptimeStringMap renamed to StaticStringMap",
    "std.ChildProcess renamed to std.process.Child",
    "zig-cache renamed to .zig-cache",
    "PriorityQueue stores capacity instead of length",
    "posix.iovec uses .base and .len instead of .iov_base and .iov_len",
};

// ============================================================================
// Deprecated patterns - old code that needs updating
// ============================================================================

/// Named struct type for deprecated pattern information
/// Used for consistent typing across checkDeprecated return values
pub const DeprecatedPattern = struct {
    pattern: []const u8,
    replacement: []const u8,
    rule: []const u8,
};

pub const deprecated_patterns = [_]DeprecatedPattern{
    .{
        .pattern = "std.ArrayList(",
        .replacement = "Use std.ArrayListUnmanaged with allocator",
        .rule = "ZAV101",
    },
    .{
        .pattern = "std.ChildProcess",
        .replacement = "std.process.Child",
        .rule = "ZAV102",
    },
    .{
        .pattern = "ComptimeStringMap",
        .replacement = "StaticStringMap",
        .rule = "ZAV103",
    },
    .{
        .pattern = ".iov_base",
        .replacement = ".base",
        .rule = "ZAV104",
    },
    .{
        .pattern = ".iov_len",
        .replacement = ".len",
        .rule = "ZAV105",
    },
    .{
        .pattern = "zig-cache/",
        .replacement = ".zig-cache/",
        .rule = "ZAV106",
    },
};

// ============================================================================
// std module structure for 0.15.x
// ============================================================================

pub const std_modules = [_][]const u8{
    "std.mem",
    "std.fs",
    "std.io",
    "std.os",
    "std.posix",
    "std.debug",
    "std.fmt",
    "std.json",
    "std.crypto",
    "std.compress",
    "std.hash",
    "std.heap",
    "std.math",
    "std.meta",
    "std.net",
    "std.process",
    "std.rand",
    "std.sort",
    "std.testing",
    "std.time",
    "std.unicode",
    "std.ArrayList",
    "std.ArrayListUnmanaged",
    "std.AutoArrayHashMap",
    "std.AutoHashMap",
    "std.BoundedArray",
    "std.MultiArrayList",
    "std.PriorityQueue",
    "std.SegmentedList",
    "std.SinglyLinkedList",
    "std.TailQueue",
    "std.StaticStringMap",
    "std.StringHashMap",
    "std.StringArrayHashMap",
};

// ============================================================================
// Helper functions
// ============================================================================

/// Check if a line contains an optional-returning method call
pub fn containsOptionalMethod(line: []const u8) bool {
    for (optional_methods) |pattern| {
        if (std.mem.indexOf(u8, line, pattern) != null) return true;
    }
    return false;
}

/// Check if a line contains an error-returning method call
pub fn containsErrorMethod(line: []const u8) bool {
    for (error_methods) |pattern| {
        if (std.mem.indexOf(u8, line, pattern) != null) return true;
    }
    return false;
}

/// Check if a line contains an allocation pattern
pub fn containsAllocation(line: []const u8) bool {
    for (alloc_patterns) |pattern| {
        if (std.mem.indexOf(u8, line, pattern) != null) return true;
    }
    for (create_patterns) |pattern| {
        if (std.mem.indexOf(u8, line, pattern) != null) return true;
    }
    return false;
}

/// Check if a line contains a builtin function
pub fn containsBuiltin(line: []const u8) bool {
    for (builtins) |builtin| {
        if (std.mem.indexOf(u8, line, builtin) != null) return true;
    }
    return false;
}

/// Check for deprecated patterns, returns replacement suggestion if found
pub fn checkDeprecated(line: []const u8) ?DeprecatedPattern {
    for (deprecated_patterns) |dep| {
        if (std.mem.indexOf(u8, line, dep.pattern) != null) {
            return dep;
        }
    }
    return null;
}

// ============================================================================
// API Wrappers for consistent interface across versions
// ============================================================================

/// HashMap wrapper for consistent API across versions
pub fn hashMapPut(
    comptime K: type,
    comptime V: type,
    map: *std.StringHashMap(V),
    key: K,
    value: V,
) !void {
    // In 0.15.x, allocator is stored in the map itself
    return map.put(key, value);
}

/// ArrayList wrapper for consistent API across versions
pub fn arrayListAppend(
    comptime T: type,
    list: *std.ArrayListUnmanaged(T),
    allocator: std.mem.Allocator,
    item: T,
) !void {
    // In 0.15.x, allocator must be passed to append
    return list.append(allocator, item);
}

/// ArrayList deinit wrapper
pub fn arrayListDeinit(
    comptime T: type,
    list: *std.ArrayListUnmanaged(T),
    allocator: std.mem.Allocator,
) void {
    list.deinit(allocator);
}

/// Create a test allocator with leak detection
pub fn createTestAllocator() std.heap.GeneralPurposeAllocator(.{}) {
    return std.heap.GeneralPurposeAllocator(.{}){};
}

// ============================================================================
// Tests
// ============================================================================

test "version constant is correct" {
    try std.testing.expectEqualStrings("0.15", version);
}

test "containsOptionalMethod detects iterator methods" {
    try std.testing.expect(containsOptionalMethod("const item = iter.next()"));
    try std.testing.expect(containsOptionalMethod("if (map.get(key)) |v|"));
    try std.testing.expect(containsOptionalMethod("_ = args.next()"));
    try std.testing.expect(!containsOptionalMethod("try file.read(buf)"));
}

test "containsErrorMethod detects error-returning methods" {
    try std.testing.expect(containsErrorMethod("try file.read(buf)"));
    const alloc_line = "try allocator.alloc(u8, 100)";
    try std.testing.expect(containsErrorMethod(alloc_line));
    try std.testing.expect(!containsErrorMethod("iter.next()"));
}

test "containsAllocation detects allocation patterns" {
    const alloc_line = "try allocator.alloc(u8, 100)";
    try std.testing.expect(containsAllocation(alloc_line));
    const create_line = "try allocator.create(Node)";
    try std.testing.expect(containsAllocation(create_line));
    try std.testing.expect(!containsAllocation("const x = 42"));
}

test "checkDeprecated finds deprecated patterns" {
    const line = "var list = std.ArrayList(u8).init(alloc);";
    const result = checkDeprecated(line);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("ZAV101", result.?.rule);
}

test "HashMapPut works with StringHashMap" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var map = std.StringHashMap(u32).init(allocator);
    defer map.deinit();

    try hashMapPut([]const u8, u32, &map, "test", 42);
    try std.testing.expectEqual(@as(u32, 42), map.get("test").?);
}

test "ArrayListAppend works with ArrayListUnmanaged" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var list: std.ArrayListUnmanaged(u32) = .{};
    defer arrayListDeinit(u32, &list, allocator);

    try arrayListAppend(u32, &list, allocator, 42);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(@as(u32, 42), list.items[0]);
}
