// Zig 0.16.x Compatibility Layer
//
// This module provides version-specific implementations and pattern definitions
// for Zig 0.16.x. Used by Ephor to detect version-appropriate issues.
//
// NOTE: Zig 0.16.0 is released. This module provides compatibility for 0.16.x.
// Update as breaking changes between 0.15.x and 0.16.x are identified.
//
// To update for 0.16 API changes:
//   1. Install Zig 0.16 (`brew upgrade zig`)
//   2. Run `zig build test` to identify breaking changes
//   3. Update the arrays and functions below to handle differences
//   4. Update the notes, breaking_changes, and deprecated_patterns arrays
//   5. Add any new builtins or remove deprecated ones

const std = @import("std");

/// Version identifier
pub const version = "0.16";

/// Full version range supported
pub const min_version = "0.16.0";
pub const max_version = "0.16.255";

/// API Notes for this version
/// NOTE: Zig 0.16.0 is released - update as changes are identified
pub const notes =
    \\Zig 0.16.x API Notes:
    \\  - Released: Zig 0.16.0
    \\  - Check release notes for breaking changes from 0.15.x
    \\  - API patterns largely similar to 0.15.x
    \\  - Update this module as differences are identified
;

// ============================================================================
// Builtin Functions
// Complete list of @builtins available in Zig 0.16.x
// NOTE: 0.16.0 is released - update if builtins change
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
// NOTE: 0.16.0 is released - update if methods change
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
// NOTE: 0.16.0 is released - update if methods change
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
// Breaking changes from 0.15.x to 0.16.x
// NOTE: 0.16.0 is released - add changes as they are identified
// ============================================================================

pub const breaking_changes = [_][]const u8{
    "Check Zig 0.16 release notes for specific breaking changes",
    "Update this array as changes from 0.15.x are identified",
};

// ============================================================================
// Deprecated patterns - old code that needs updating
// NOTE: 0.16.0 is released - update as breaking changes are identified
// ============================================================================

/// Named struct type for deprecated pattern information
/// Used for consistent typing across checkDeprecated return values
pub const DeprecatedPattern = struct {
    pattern: []const u8,
    replacement: []const u8,
    rule: []const u8,
};

pub const deprecated_patterns = [_]DeprecatedPattern{
    // Placeholder - add 0.16-specific deprecations as they're identified
    .{ .pattern = "TBD", .replacement = "TBD", .rule = "ZAV200" },
};

// ============================================================================
// std module structure for 0.16.x
// NOTE: 0.16.0 is released - update if structure changes
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
        // Skip placeholder
        if (std.mem.eql(u8, dep.pattern, "TBD")) continue;
        if (std.mem.indexOf(u8, line, dep.pattern) != null) {
            return dep;
        }
    }
    return null;
}

// ============================================================================
// API Wrappers for consistent interface across versions
// NOTE: 0.16.0 is released - update if APIs change
// ============================================================================

/// HashMap wrapper for consistent API across versions
pub fn hashMapPut(
    comptime K: type,
    comptime V: type,
    map: *std.StringHashMap(V),
    key: K,
    value: V,
) !void {
    // Assuming same API as 0.15 until 0.16 is released
    return map.put(key, value);
}

/// ArrayList wrapper for consistent API across versions
pub fn arrayListAppend(
    comptime T: type,
    list: *std.ArrayListUnmanaged(T),
    allocator: std.mem.Allocator,
    item: T,
) !void {
    // Assuming same API as 0.15 until 0.16 is released
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
    try std.testing.expectEqualStrings("0.16", version);
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

// Note: Add deprecated pattern tests as 0.16 API changes are identified
