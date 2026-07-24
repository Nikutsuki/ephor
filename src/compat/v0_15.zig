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
pub const vocab = @import("vocab.zig");

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
    "@memmove",
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
    "@branchHint",

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
    "std.MultiArrayList",
    "std.PriorityQueue",
    "std.SegmentedList",
    "std.SinglyLinkedList",
    "std.StaticStringMap",
    "std.StringHashMap",
    "std.StringArrayHashMap",
};

// ============================================================================
// Stdlib Vocabulary - Allocator Types, Methods, and Patterns
// Single source of truth for Zig 0.15.x stdlib knowledge
// ============================================================================

pub const allocator_types = [_]vocab.AllocatorType{
    .{
        .name = "ArenaAllocator",
        .full_path = "std.heap.ArenaAllocator",
        .init_pattern = "ArenaAllocator.init(",
        .needs_free = false,
        .cleanup_method = ".deinit(",
    },
    .{
        .name = "FixedBufferAllocator",
        .full_path = "std.heap.FixedBufferAllocator",
        .init_pattern = "FixedBufferAllocator.init(",
        .needs_free = false,
        .cleanup_method = "",
    },
    .{
        .name = "StackFallbackAllocator",
        .full_path = "std.heap.StackFallbackAllocator",
        .init_pattern = "StackFallbackAllocator(",
        .needs_free = false,
        .cleanup_method = ".deinit(",
    },
    .{
        .name = "GeneralPurposeAllocator",
        .full_path = "std.heap.GeneralPurposeAllocator",
        .init_pattern = "GeneralPurposeAllocator(",
        .needs_free = true,
        .cleanup_method = ".deinit(",
    },
    .{
        .name = "DebugAllocator",
        .full_path = "std.heap.DebugAllocator",
        .init_pattern = "DebugAllocator(",
        .needs_free = true,
        .cleanup_method = ".deinit(",
    },
    .{
        .name = "ThreadSafeAllocator",
        .full_path = "std.heap.ThreadSafeAllocator",
        .init_pattern = "ThreadSafeAllocator.init(",
        .needs_free = true,
        .cleanup_method = ".deinit(",
    },
    .{
        .name = "MemoryPool",
        .full_path = "std.heap.MemoryPool",
        .init_pattern = "MemoryPool(",
        .needs_free = true,
        .cleanup_method = ".deinit(",
    },
    .{
        .name = "MemoryPoolAligned",
        .full_path = "std.heap.MemoryPoolAligned",
        .init_pattern = "MemoryPoolAligned(",
        .needs_free = true,
        .cleanup_method = ".deinit(",
    },
};

pub const global_allocators = [_]vocab.GlobalAllocator{
    .{ .name = "page_allocator", .full_path = "std.heap.page_allocator", .needs_free = true },
    .{ .name = "c_allocator", .full_path = "std.heap.c_allocator", .needs_free = true },
    .{ .name = "raw_c_allocator", .full_path = "std.heap.raw_c_allocator", .needs_free = true },
    .{ .name = "wasm_allocator", .full_path = "std.heap.wasm_allocator", .needs_free = true },
    .{ .name = "smp_allocator", .full_path = "std.heap.smp_allocator", .needs_free = true },
    .{ .name = "testing.allocator", .full_path = "std.testing.allocator", .needs_free = true },
};

pub const alloc_methods = [_]vocab.AllocMethod{
    .{
        .pattern = ".alloc(",
        .short_name = "alloc",
        .returns_slice = true,
        .cleanup = ".free(",
    },
    .{
        .pattern = ".alignedAlloc(",
        .short_name = "alignedAlloc",
        .returns_slice = true,
        .cleanup = ".free(",
    },
    .{
        .pattern = ".allocSentinel(",
        .short_name = "allocSentinel",
        .returns_slice = true,
        .cleanup = ".free(",
    },
    .{
        .pattern = ".realloc(",
        .short_name = "realloc",
        .returns_slice = true,
        .cleanup = ".free(",
    },
    .{
        .pattern = ".create(",
        .short_name = "create",
        .returns_slice = false,
        .cleanup = ".destroy(",
    },
    .{
        .pattern = ".dupe(",
        .short_name = "dupe",
        .returns_slice = true,
        .cleanup = ".free(",
    },
    .{
        .pattern = ".dupeZ(",
        .short_name = "dupeZ",
        .returns_slice = true,
        .cleanup = ".free(",
    },
    .{
        .pattern = ".allocWithOptions(",
        .short_name = "allocWithOptions",
        .returns_slice = true,
        .cleanup = ".free(",
    },
};

pub const cleanup_methods = [_]vocab.CleanupMethod{
    .{ .pattern = ".free(", .is_void = true },
    .{ .pattern = ".destroy(", .is_void = true },
    .{ .pattern = ".deinit(", .is_void = true },
};

pub const container_methods = [_]vocab.ContainerMethod{
    .{ .pattern = ".put(", .takes_ownership = true, .is_void = false },
    .{ .pattern = ".putNoClobber(", .takes_ownership = true, .is_void = false },
    .{ .pattern = ".append(", .takes_ownership = true, .is_void = false },
    .{ .pattern = ".appendSlice(", .takes_ownership = true, .is_void = false },
    .{ .pattern = ".insert(", .takes_ownership = true, .is_void = false },
    .{ .pattern = ".toOwnedSlice(", .takes_ownership = true, .is_void = false },
    .{ .pattern = ".clone(", .takes_ownership = true, .is_void = false },
};

/// Stdlib methods safe to discard (void or value-returning, not error-returning).
/// Used by isSafeToDiscard, isSafeBuiltin, isKnownVoidFunction in main.zig.
pub const safe_methods = [_]vocab.SafeMethod{
    // Void methods (container lifecycle)
    .{ .pattern = ".clear(", .is_void = true },
    .{ .pattern = ".clearAndFree(", .is_void = true },
    .{ .pattern = ".clearRetainingCapacity(", .is_void = true },
    .{ .pattern = ".reset(", .is_void = true },
    .{ .pattern = ".close(", .is_void = true },
    .{ .pattern = ".skip(", .is_void = true },
    // Value-returning methods (T or ?T, not !T)
    .{ .pattern = ".pop(", .is_void = false },
    .{ .pattern = ".remove(", .is_void = false },
    .{ .pattern = ".swapRemove(", .is_void = false },
    .{ .pattern = ".orderedRemove(", .is_void = false },
    .{ .pattern = ".get(", .is_void = false },
    .{ .pattern = ".getLastOrNull()", .is_void = false },
    .{ .pattern = ".count()", .is_void = false },
    .{ .pattern = ".next()", .is_void = false },
    .{ .pattern = ".peek()", .is_void = false },
    // IO methods (return usize or !void, but commonly discarded)
    .{ .pattern = ".write(", .is_void = false },
    .{ .pattern = ".print(", .is_void = false },
    // Validation/check (returns diagnostic info)
    .{ .pattern = ".check(", .is_void = false },
    // std.debug and std.testing (always void or noreturn)
    .{ .pattern = "debug.print", .is_void = true },
    .{ .pattern = "assert(", .is_void = true },
    .{ .pattern = "expect(", .is_void = false },
};

// ============================================================================
// Comptime Flat Arrays - for fast substring matching in main.zig
// Derived from structured data above
// ============================================================================

/// Init patterns for allocator types that don't need per-allocation free
/// (ArenaAllocator, FixedBufferAllocator, StackFallbackAllocator)
pub const no_free_init_patterns: []const []const u8 = &.{
    "ArenaAllocator.init(",
    "ArenaAllocator.State",
    "FixedBufferAllocator.init(",
    "FixedBufferAllocator{",
    "StackFallbackAllocator(",
    "stackFallback(",
};

/// Struct field type patterns for no-free allocators.
/// Used to detect fields like `arena: std.heap.ArenaAllocator,` so that
/// allocations through field chains (e.g. self.arena.alloc()) are suppressed.
/// Type-based only — never matches on field names, only on declared types.
pub const no_free_field_type_patterns: []const []const u8 = &.{
    "std.heap.ArenaAllocator",
    "heap.ArenaAllocator",
    "ArenaAllocator",
    "std.heap.FixedBufferAllocator",
    "heap.FixedBufferAllocator",
    "FixedBufferAllocator",
    "*std.heap.ArenaAllocator",
    "*heap.ArenaAllocator",
    "*ArenaAllocator",
    "*std.heap.FixedBufferAllocator",
    "*heap.FixedBufferAllocator",
    "*FixedBufferAllocator",
};

/// Init patterns for ALL allocator types (no-free + needs-free)
pub const all_init_patterns: []const []const u8 = &.{
    // No-free types
    "ArenaAllocator.init(",
    "FixedBufferAllocator.init(",
    "FixedBufferAllocator{",
    "StackFallbackAllocator(",
    "stackFallback(",
    // Needs-free types
    "GeneralPurposeAllocator(",
    "DebugAllocator(",
    "ThreadSafeAllocator.init(",
    "MemoryPool(",
    "MemoryPoolAligned(",
};

/// Names of global singleton allocators
pub const global_alloc_names: []const []const u8 = &.{
    "page_allocator",
    "c_allocator",
    "raw_c_allocator",
    "wasm_allocator",
    "smp_allocator",
    "testing.allocator",
};

/// Allocation method patterns for line matching (e.g. ".alloc(")
pub const alloc_method_patterns: []const []const u8 = &.{
    // std.mem.Allocator interface
    ".alloc(",
    ".alignedAlloc(",
    ".allocSentinel(",
    ".realloc(",
    ".create(",
    ".dupe(",
    ".dupeZ(",
    ".allocWithOptions(",
    // std.fmt (allocator as first arg)
    ".allocPrint(",
    ".allocPrintZ(",
    // Container methods that produce owned memory
    ".toOwnedSlice(",
    ".toOwnedSliceSentinel(",
    ".cloneWithAllocator(",
    // File I/O (allocating reads)
    ".readFileAlloc(",
    ".readFileAllocOptions(",
    ".readToEndAlloc(",
    ".readToEndAllocOptions(",
    ".readAllAlloc(",
    // Path operations
    ".selfExePathAlloc(",
    ".selfExeDirPathAlloc(",
    ".realpathAlloc(",
    // String operations
    ".replaceOwned(",
    ".concatWithSentinel(",
    // JSON/serialization
    ".stringifyAlloc(",
};

/// Short names for allocation methods (identifier matching, e.g. "alloc")
pub const alloc_method_short_names: []const []const u8 = &.{
    "alloc",
    "alignedAlloc",
    "allocSentinel",
    "realloc",
    "create",
    "dupe",
    "dupeZ",
    "allocWithOptions",
    "allocPrint",
    "allocPrintZ",
    "toOwnedSlice",
    "toOwnedSliceSentinel",
    "cloneWithAllocator",
    "readFileAlloc",
    "readFileAllocOptions",
    "readToEndAlloc",
    "readToEndAllocOptions",
    "readAllAlloc",
    "selfExePathAlloc",
    "selfExeDirPathAlloc",
    "realpathAlloc",
    "replaceOwned",
    "concatWithSentinel",
    "stringifyAlloc",
};

/// Fully-qualified stdlib function patterns that allocate memory.
/// These have generic names (concat, join) that would false-positive
/// as bare `.method(` patterns, so we match with module prefix.
pub const qualified_alloc_fn_patterns: []const []const u8 = &.{
    "mem.concat(",
    "mem.join(",
    "mem.joinZ(",
    "process.getEnvVarOwned(",
    "fs.getAppDataDir(",
};

/// Cleanup/deallocation patterns
pub const cleanup_pattern_strs: []const []const u8 = &.{
    ".free(",
    ".destroy(",
    ".deinit(",
};

/// Container methods that transfer ownership (store/consume passed values)
pub const container_ownership_methods: []const []const u8 = &.{
    ".put(",
    ".putNoClobber(",
    ".putAssumeCapacity(",
    ".append(",
    ".appendSlice(",
    ".insert(",
    ".addOne(",
    ".toOwnedSlice(",
    ".fromOwnedSlice(",
    ".clone(",
};

/// Stdlib methods safe to discard (all patterns from safe_methods)
pub const safe_method_patterns: []const []const u8 = &.{
    ".clear(",
    ".clearAndFree(",
    ".clearRetainingCapacity(",
    ".reset(",
    ".close(",
    ".skip(",
    ".pop(",
    ".remove(",
    ".swapRemove(",
    ".orderedRemove(",
    ".get(",
    ".getLastOrNull()",
    ".count()",
    ".next()",
    ".peek()",
    ".write(",
    ".print(",
    ".check(",
    "debug.print",
    "assert(",
    "expect(",
};

/// Stdlib void methods (subset of safe_methods where is_void == true)
pub const void_method_patterns: []const []const u8 = &.{
    ".clear(",
    ".clearAndFree(",
    ".clearRetainingCapacity(",
    ".reset(",
    ".close(",
    ".skip(",
    "debug.print",
    "assert(",
};

/// Pointer type patterns for no-free allocator parameter detection
/// Used to check if a function parameter is typed as a no-free allocator pointer
pub const no_free_type_ptrs: []const []const u8 = &.{
    "*ArenaAllocator",
    "*std.heap.ArenaAllocator",
    "*FixedBufferAllocator",
    "*std.heap.FixedBufferAllocator",
    "*StackFallbackAllocator",
    "*std.heap.StackFallbackAllocator",
};

/// Stdlib container mutation methods that fill/modify a variable
/// Used by isFillPattern() to detect "var x = undefined; x.method()" patterns
/// These are methods defined on stdlib containers (ArrayList, HashMap, etc.)
pub const modifying_method_patterns: []const []const u8 = &.{
    ".update(",
    ".set(",
    ".reinit(",
    ".reset(",
    ".fill(",
    ".clear(",
    ".put(",
    ".append(",
    ".resize(",
    ".ensureCapacity(",
    ".replaceRange(",
    ".insertSlice(",
};

/// Stdlib container type init patterns (for type-based detection)
/// Used by collectStdlibVarNames() to track which variables hold stdlib types.
/// Only types from std whose methods (.clear, .append, etc.) are known void.
pub const stdlib_container_init_patterns: []const []const u8 = &.{
    // Collections
    "ArrayList(",
    "ArrayListUnmanaged(",
    "ArrayListAligned(",
    "MultiArrayList(",
    "SegmentedList(",
    "PriorityQueue(",
    "PriorityDequeue(",
    "SinglyLinkedList(",
    "DoublyLinkedList(",
    // Maps
    "StringHashMap(",
    "StringHashMapUnmanaged(",
    "AutoHashMap(",
    "AutoHashMapUnmanaged(",
    "AutoArrayHashMap(",
    "AutoArrayHashMapUnmanaged(",
    "StringArrayHashMap(",
    "StringArrayHashMapUnmanaged(",
    "StaticStringMap(",
    "EnumArray(",
    "EnumMap(",
    "EnumSet(",
    "BufSet.init(",
    "BufMap.init(",
    // IO
    "std.fs.File",
    "fs.File",
    "BufferedReader(",
    "BufferedWriter(",
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
pub fn createTestAllocator() std.heap.DebugAllocator(.{}) {
    return std.heap.DebugAllocator(.{}){};
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

test "ArrayListAppend works with ArrayListUnmanaged" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var list: std.ArrayListUnmanaged(u32) = .empty;
    defer arrayListDeinit(u32, &list, allocator);

    try arrayListAppend(u32, &list, allocator, 42);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(@as(u32, 42), list.items[0]);
}

test "vocabulary allocator_types has expected count" {
    try std.testing.expectEqual(@as(usize, 8), allocator_types.len);
}

test "vocabulary global_allocators includes testing.allocator" {
    var found = false;
    for (global_allocators) |g| {
        if (std.mem.eql(u8, g.name, "testing.allocator")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "vocabulary alloc_methods includes dupe and dupeZ" {
    var found_dupe = false;
    var found_dupez = false;
    for (alloc_methods) |m| {
        if (std.mem.eql(u8, m.short_name, "dupe")) found_dupe = true;
        if (std.mem.eql(u8, m.short_name, "dupeZ")) found_dupez = true;
    }
    try std.testing.expect(found_dupe);
    try std.testing.expect(found_dupez);
}

test "vocabulary no_free_init_patterns is non-empty" {
    try std.testing.expect(no_free_init_patterns.len > 0);
}

test "vocabulary no_free_field_type_patterns covers ArenaAllocator and FixedBufferAllocator" {
    try std.testing.expect(no_free_field_type_patterns.len > 0);
    var found_arena = false;
    var found_fba = false;
    for (no_free_field_type_patterns) |p| {
        if (std.mem.eql(u8, p, "std.heap.ArenaAllocator")) found_arena = true;
        if (std.mem.eql(u8, p, "std.heap.FixedBufferAllocator")) found_fba = true;
    }
    try std.testing.expect(found_arena);
    try std.testing.expect(found_fba);
}

test "vocabulary all_init_patterns includes MemoryPool" {
    var found = false;
    for (all_init_patterns) |p| {
        if (std.mem.eql(u8, p, "MemoryPool(")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
