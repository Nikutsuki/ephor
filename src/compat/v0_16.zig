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
pub const vocab = @import("vocab.zig");
// Shared quote machine for the code-position mask (EPH-I0880). types.zig
// imports only std, so this import edge stays cycle-free.
const types = @import("../types.zig");

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
    "@optimizeFor",
    "@prefetch",

    // GPU and WebAssembly builtins: all five names verified against the
    // pinned 0.16.0 compiler (probe compile; a recognized builtin reports
    // a scope or target error, an unknown name reports invalid builtin).
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

    // HashMap/StringHashMap lookups (return ?V or ?*V)
    ".get(",
    ".getKey(",
    ".getEntry(",
    ".getPtr(",
    ".fetchRemove(",

    // ArrayHashMap methods
    ".getIndex(",
    ".swapRemove(",
    ".orderedRemove(",

    // ArrayList/container optional methods (pop returns ?T since 0.15.1)
    ".pop(",
    ".getLastOrNull(",

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

    // fs.path functions (only dirname returns an optional: fs/path.zig:1318)
    "fs.path.dirname(",

    // Tokenizer/Parser methods
    ".peek(",
};

// ============================================================================
// Methods that return error unions (!T)
// These should NOT be silently discarded - ZA205 should flag them
// NOTE: 0.16.0 is released - update if methods change
// ============================================================================

pub const error_methods = [_][]const u8{
    // File operations (close is void in 0.16: Io/File.zig:221, Io/Dir.zig:490)
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

    // Process and thread operations
    ".spawn(",
    ".wait(",
    ".kill(",
    ".exec(",
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
    ".stringify(",

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

    // HashMap operations that can fail (fetchPut returns !?KV: hash_map.zig:347)
    ".put(",
    ".putNoClobber(",
    ".getOrPut(",
    ".getOrPutValue(",
    ".fetchPut(",

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
    "threadlocal ",
    "extern ",
    "export ",
    "align ",
    "packed ",
    "volatile ",
    "allowzero ",
    "anytype ",
    "anyopaque ",
    "anyerror ",
    // suspend/resume/nosuspend/anyframe stay: the pinned 0.16.0 compiler
    // still rejects them as identifiers (probe compile), so they remain
    // reserved words even though async fn support left in 0.11.
    "suspend ",
    "resume ",
    "nosuspend ",
    "anyframe ",
};

// ============================================================================
// Breaking changes from 0.15.x to 0.16.x
// NOTE: 0.16.0 is released - add changes as they are identified
// ============================================================================

pub const breaking_changes = [_][]const u8{
    "raw_c_allocator removed (c_allocator handles alignment directly)",
    "MemoryPool API rewrite: .init(alloc) -> .empty, .deinit() -> .deinit(alloc)",
    "MemoryPool.create() -> .create(alloc), .preheat() -> .addCapacity(alloc)",
    "MemoryPool.initPreheated() -> .initCapacity()",
    "MemoryPoolAligned deprecated -> memory_pool.Aligned",
    "MemoryPoolExtra deprecated -> memory_pool.Extra",
    "DebugAllocator.detectLeaks() returns usize (was bool)",
    "DebugAllocator.Config.MutexType field removed",
    "SinglyLinkedList de-genericified (no type parameter)",
    "std.Io.Mutex replaces std.Thread.Mutex in stdlib",
};

// ============================================================================
// Deprecated patterns - old code that needs updating
// NOTE: 0.16.0 is released - update as breaking changes are identified
// ============================================================================

/// Named struct type for deprecated pattern information.
/// Alias of the shared vocab type, so checkDeprecated returns one type
/// across all version modules.
pub const DeprecatedPattern = vocab.DeprecatedPattern;

pub const deprecated_patterns = [_]DeprecatedPattern{
    .{
        .pattern = "raw_c_allocator",
        .replacement = "c_allocator (handles alignment directly in 0.16)",
        .rule = "ZAV201",
    },
    .{
        .pattern = "GeneralPurposeAllocator",
        .replacement = "DebugAllocator",
        .rule = "ZAV202",
    },
    .{
        .pattern = "MemoryPoolAligned",
        .replacement = "memory_pool.Aligned",
        .rule = "ZAV203",
    },
    .{
        .pattern = "MemoryPoolExtra",
        .replacement = "memory_pool.Extra",
        .rule = "ZAV204",
    },
    .{
        .pattern = "SinglyLinkedList(",
        .replacement = "SinglyLinkedList (non-generic since 0.15)",
        .rule = "ZAV205",
    },
    .{
        .pattern = "DoublyLinkedList(",
        .replacement = "DoublyLinkedList (non-generic since 0.15)",
        .rule = "ZAV206",
    },
    .{
        .pattern = "std.ArrayListUnmanaged(",
        .replacement = "std.ArrayList (unmanaged by default since 0.15)",
        .rule = "ZAV207",
    },
    .{
        .pattern = "ThreadSafeAllocator",
        .replacement = "SmpAllocator",
        .rule = "ZAV208",
    },
};

// ============================================================================
// std module structure for 0.16.x
// NOTE: 0.16.0 is released - update if structure changes
// ============================================================================

pub const std_modules = [_][]const u8{
    "std.mem",
    "std.fs",
    "std.Io",
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
    "std.process",
    "std.sort",
    "std.testing",
    "std.time",
    "std.unicode",
    "std.ArrayList",
    "std.AutoHashMap",
    "std.MultiArrayList",
    "std.PriorityQueue",
    "std.SinglyLinkedList",
    "std.StaticStringMap",
    "std.StringHashMap",
};

// ============================================================================
// Stdlib Vocabulary - Allocator Types, Methods, and Patterns
// Single source of truth for Zig 0.16.x stdlib knowledge. Re-grounded
// against the pinned 0.16.0 std tree in B71 (mega-audit file-compat batch).
// ============================================================================

/// Current 0.16 allocator vocabulary. Removed names (GeneralPurposeAllocator,
/// ThreadSafeAllocator) and the deprecated MemoryPoolAligned alias live only
/// in deprecated_patterns (ZAV202/ZAV203/ZAV208) — verified against the
/// pinned 0.16 std heap.zig (zero text for GPA and ThreadSafeAllocator;
/// MemoryPoolAligned exists only as the alias at heap.zig:33).
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
        .name = "DebugAllocator",
        .full_path = "std.heap.DebugAllocator",
        .init_pattern = "DebugAllocator(",
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
};

pub const global_allocators = [_]vocab.GlobalAllocator{
    .{ .name = "page_allocator", .full_path = "std.heap.page_allocator", .needs_free = true },
    .{ .name = "c_allocator", .full_path = "std.heap.c_allocator", .needs_free = true },
    // raw_c_allocator removed in 0.16 — c_allocator now handles alignment directly
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
/// Used by isSafeToDiscard and isSafeBuiltin in main.zig. The .write( and
/// .print( IO methods are NOT here: both return error unions (!usize, !void),
/// and discarding them is exactly what ZA205 exists to catch (F7).
pub const safe_methods = [_]vocab.SafeMethod{
    // Void methods (container lifecycle)
    .{ .pattern = ".clear(", .is_void = true },
    .{ .pattern = ".clearAndFree(", .is_void = true },
    .{ .pattern = ".clearRetainingCapacity(", .is_void = true },
    .{ .pattern = ".reset(", .is_void = true },
    .{ .pattern = ".close(", .is_void = true },
    // process.Args.Iterator.skip returns bool (Args.zig:68)
    .{ .pattern = ".skip(", .is_void = false },
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
    // Validation/check (returns diagnostic info)
    .{ .pattern = ".check(", .is_void = false },
    // std.debug and std.testing (always void or noreturn)
    .{ .pattern = "debug.print", .is_void = true },
    .{ .pattern = "assert(", .is_void = true },
    .{ .pattern = "expect(", .is_void = true },
};

// ============================================================================
// Comptime Flat Arrays - for fast substring matching in main.zig
// Derived from structured data above
// ============================================================================

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

pub const all_init_patterns: []const []const u8 = &.{
    "ArenaAllocator.init(",
    "FixedBufferAllocator.init(",
    "FixedBufferAllocator{",
    "StackFallbackAllocator(",
    "stackFallback(",
    "DebugAllocator(",
    "MemoryPool(",
};

pub const global_alloc_names: []const []const u8 = &.{
    "page_allocator",
    "c_allocator",
    // raw_c_allocator removed in 0.16 (c_allocator handles alignment)
    "wasm_allocator",
    "smp_allocator",
    "testing.allocator",
};

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
    // Container methods that produce owned memory
    ".toOwnedSlice(",
    ".toOwnedSliceSentinel(",
    ".cloneWithAllocator(",
    // File I/O (allocating reads; allocator is the first argument)
    ".readFileAlloc(",
    ".readFileAllocOptions(",
    ".readAlloc(",
    ".allocRemaining(",
    // Path operations (0.15's realpathAlloc moved and renamed to
    // Io.Dir.realPathFileAlloc, where the allocator is the third argument —
    // the first-arg extractor cannot model it, so it is deliberately absent)
    // String operations
    ".replaceOwned(",
    ".concatWithSentinel(",
};

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
    "toOwnedSlice",
    "toOwnedSliceSentinel",
    "cloneWithAllocator",
    "readFileAlloc",
    "readFileAllocOptions",
    "readAlloc",
    "allocRemaining",
    "replaceOwned",
    "concatWithSentinel",
};

/// Fully-qualified stdlib function patterns that allocate memory.
/// These have generic names (concat, join) that would false-positive
/// as bare `.method(` patterns, so we match with module prefix.
pub const qualified_alloc_fn_patterns: []const []const u8 = &.{
    "mem.concat(",
    "mem.join(",
};

pub const cleanup_pattern_strs: []const []const u8 = &.{
    ".free(",
    ".destroy(",
    ".deinit(",
};

pub const container_ownership_methods: []const []const u8 = &.{
    ".put(",
    ".putNoClobber(",
    ".putAssumeCapacity(",
    ".append(",
    ".appendSlice(",
    ".insert(",
    ".prepend(",
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
    "debug.print",
    "assert(",
    "expect(",
};

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
    // Collections (linked lists are non-generic structs since 0.15:
    // std.zig:10 and :26 import them as plain `pub const`)
    "ArrayList(",
    "ArrayListUnmanaged(",
    "ArrayListAligned(",
    "MultiArrayList(",
    "PriorityQueue(",
    "PriorityDequeue(",
    "SinglyLinkedList",
    "DoublyLinkedList",
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
    // IO (0.16 moved File and Dir from std.fs to std.Io: Io.zig:41-45;
    // the BufferedReader/BufferedWriter names left the stdlib in 0.15)
    "Io.File",
    "Io.Dir",
    "Io.Reader",
};

/// Managed-container type families: structs that own a backing resource
/// (ptr + capacity + allocator fields for the containers; an OS handle for
/// Io.File/Io.Dir), so a BY-VALUE copy aliases the same backing — returning
/// one from a fn creates a second owner with no language-level transfer
/// (double-free on deinit, dangle after a callee defer, use of a closed
/// handle). Deliberately EXCLUDES the inline-storage entries of
/// stdlib_container_init_patterns (EnumArray/EnumMap/EnumSet/StaticStringMap
/// copy safely), node-based linked lists (nodes stay user-owned), and
/// Io.Reader (an interface struct whose by-value return is the idiomatic
/// construction pattern). Patterns carry the trailing `(` of a generic
/// instantiation except the non-generic BufMap/BufSet and the Io handles.
/// Used by ZA110 return-type classification.
pub const managed_container_type_patterns: []const []const u8 = &.{
    "ArrayList(",
    "ArrayListUnmanaged(",
    "ArrayListAligned(",
    "MultiArrayList(",
    "PriorityQueue(",
    "PriorityDequeue(",
    "StringHashMap(",
    "StringHashMapUnmanaged(",
    "AutoHashMap(",
    "AutoHashMapUnmanaged(",
    "AutoArrayHashMap(",
    "AutoArrayHashMapUnmanaged(",
    "StringArrayHashMap(",
    "StringArrayHashMapUnmanaged(",
    "BufMap",
    "BufSet",
    "Io.File",
    "Io.Dir",
};

// ============================================================================
// Helper functions
// ============================================================================

// The code-position mask routes through the shared quote machine:
// types.LineClassifier owns the quote state (EPH-I0876) and its edge battery
// (EPH-I0104 char-literal spans, EPH-I0671 multiline openers). The compat
// layer uses that one machine instead of a local copy, so the version
// modules cannot drift from the analyzer's own classifier (EPH-I0880).
// findCommentStart and containsPatternInCode stay local: they search THIS
// module's pattern tables at code positions — version-specific text logic,
// not quote state.

/// Start of the real `//` comment: not inside a string literal. A line that
/// is a multiline-string body has no comment (EPH-I0876).
fn findCommentStart(line: []const u8) ?usize {
    const t = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, t, "\\\\")) return null;
    var scanner = types.LineClassifier.init(line);
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, line, pos, "//")) |idx| {
        if (!scanner.isInsideString(idx)) return idx;
        pos = idx + 2;
    }
    return null;
}

/// True when `pattern` occurs at a code position: not inside a string
/// literal, not inside a trailing comment. Comment prose or string data
/// that merely names a builtin or method never matches (EPH-I0876).
fn containsPatternInCode(line: []const u8, pattern: []const u8) bool {
    const comment_start = findCommentStart(line);
    var scanner = types.LineClassifier.init(line);
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, pattern)) |pos| {
        from = pos + pattern.len;
        if (scanner.isInsideString(pos)) continue;
        if (comment_start != null and pos >= comment_start.?) continue;
        return true;
    }
    return false;
}

/// Check if a line contains an optional-returning method call at a code position
pub fn containsOptionalMethod(line: []const u8) bool {
    for (optional_methods) |pattern| {
        if (containsPatternInCode(line, pattern)) return true;
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

/// Check if a line contains a builtin function at a code position
pub fn containsBuiltin(line: []const u8) bool {
    for (builtins) |builtin| {
        if (containsPatternInCode(line, builtin)) return true;
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
pub fn createTestAllocator() std.heap.DebugAllocator(.{}) {
    return std.heap.DebugAllocator(.{}){};
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

test "comment or string naming a builtin or method never suppresses (EPH-I0876)" {
    // Trailing comment names a builtin: no suppression.
    try std.testing.expect(!containsBuiltin("_ = foo(); // @sizeOf usage"));
    // String data names a builtin: no suppression.
    try std.testing.expect(!containsBuiltin("_ = foo(); const s = \"@sizeOf(u32)\";"));
    // Multiline-string body names a builtin: no suppression.
    try std.testing.expect(!containsBuiltin("_ = foo(); \\\\ iter.next() @sizeOf data"));
    // Real code positions still match.
    try std.testing.expect(containsBuiltin("_ = @sizeOf(u32);"));
    // A comment mention never masks a real call on the same line.
    try std.testing.expect(containsBuiltin("_ = @sizeOf(u32); // @sizeOf is a builtin"));
    // Trailing comment names an optional method: no suppression.
    try std.testing.expect(!containsOptionalMethod("_ = foo(); // map.get(key) returns an optional"));
    // String data names an optional method: no suppression.
    try std.testing.expect(!containsOptionalMethod("_ = foo(); const s = \"iter.next()\";"));
    // Real code positions still match.
    try std.testing.expect(containsOptionalMethod("_ = map.get(key);"));
}

test "code-position mask keeps the shared classifier edges (EPH-I0880)" {
    // Char-literal span: the `"` inside `'...'` is data (EPH-I0104), so a
    // `//` after the closed literal is a real comment and its text never
    // matches a builtin.
    try std.testing.expect(!containsBuiltin("const q = '\"'; // @sizeOf is data"));
    try std.testing.expect(findCommentStart("const q = '\"'; // real comment") != null);
    // Multiline opener: the tail is string data (EPH-I0671), so neither a
    // comment nor a builtin exists after it.
    try std.testing.expect(!containsBuiltin("const s = \\\\ @sizeOf data"));
    try std.testing.expect(findCommentStart("const s = \\\\ tail // data") == null);
    // Escaped quote: `\"` keeps the string open, so the `//` is string
    // data, not a comment.
    try std.testing.expect(!containsBuiltin("const s = \"a \\\" b; // @sizeOf"));
    // Unterminated string: the `//` and the pattern are string data.
    try std.testing.expect(!containsBuiltin("const s = \"unterminated // @sizeOf"));
    // Comment text: a quote inside a comment never opens string state, and
    // comment prose never matches.
    try std.testing.expect(!containsBuiltin("// \"quoted\" @sizeOf"));
    // Code after a closed char literal still matches.
    try std.testing.expect(containsBuiltin("const q = 'a'; _ = @sizeOf(u32);"));
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

test "vocabulary allocator_types has expected count" {
    // ArenaAllocator, FixedBufferAllocator, StackFallbackAllocator,
    // DebugAllocator, MemoryPool — the removed GeneralPurposeAllocator,
    // ThreadSafeAllocator, and deprecated MemoryPoolAligned left (F4).
    try std.testing.expectEqual(@as(usize, 5), allocator_types.len);
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

// Note: Add deprecated pattern tests as 0.16 API changes are identified

test "managed_container_type_patterns: heap-backed in, inline-storage out" {
    var found_arraylist = false;
    var found_hashmap = false;
    for (managed_container_type_patterns) |p| {
        if (std.mem.eql(u8, p, "ArrayList(")) found_arraylist = true;
        if (std.mem.eql(u8, p, "StringHashMap(")) found_hashmap = true;
        // Inline-storage types copy safely — they must never enter the
        // ZA110 set (EnumSet/EnumArray/StaticStringMap/BoundedArray).
        try std.testing.expect(!std.mem.startsWith(u8, p, "Enum"));
        try std.testing.expect(!std.mem.startsWith(u8, p, "StaticStringMap"));
        try std.testing.expect(!std.mem.startsWith(u8, p, "BoundedArray"));
    }
    try std.testing.expect(found_arraylist);
    try std.testing.expect(found_hashmap);
}

test "createTestAllocator returns a working leak-detecting allocator" {
    var da = createTestAllocator();
    const allocator = da.allocator();
    const buf = try allocator.alloc(u8, 16);
    allocator.free(buf);
    try std.testing.expect(da.deinit() == .ok);
}
