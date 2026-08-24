// Zig 0.15.x Compatibility Layer
//
// This module provides version-specific implementations and pattern definitions
// for Zig 0.15.x. Used by Ephor to detect version-appropriate issues.
//
// API Characteristics (0.15.x):
//   - HashMap.put(key, value) - no allocator argument
//   - ArrayList.append(allocator, item) - allocator required
//   - ArrayList - unmanaged by default (0.15.1 "ArrayList: make unmanaged
//     the default"); the ArrayListUnmanaged spelling is the deprecated alias
//   - std.mem.Allocator passed to methods, not stored in containers
//   - zig-cache renamed to .zig-cache

const std = @import("std");
pub const vocab = @import("vocab.zig");
// Shared quote machine for the code-position mask (EPH-I0880). types.zig
// imports only std, so this import edge stays cycle-free.
const types = @import("../types.zig");

/// Version identifier
pub const version = "0.15";

/// Full version range supported
pub const min_version = "0.15.0";
pub const max_version = "0.15.255";

/// API Notes for this version
pub const notes =
    \\Zig 0.15.x API Notes:
    \\  - std.StringHashMap.put(key, value) - allocator stored in struct
    \\  - std.ArrayList.append(allocator, item)
    \\  - std.ArrayList.deinit(allocator)
    \\  - std.ArrayList.toOwnedSlice(allocator)
    \\  - Use DebugAllocator for leak detection
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
    "@optimizeFor",
    "@prefetch",

    // GPU and WebAssembly builtins (verified against the 0.16.0 compiler;
    // @setCold left in 0.14 — it is not in this list)
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

    // fs.path functions (only dirname returns an optional: fs/path.zig:845)
    "fs.path.dirname(",

    // Tokenizer/Parser methods
    ".peek(",

    // Environment (posix.getenv returns ?[:0]const u8: posix.zig:2029;
    // std.process.getenv left in 0.15 — process has getenvW and EnvironMap)
    "std.posix.getenv(",
};

// ============================================================================
// Methods that return error unions (!T)
// These should NOT be silently discarded - ZA205 should flag them
// ============================================================================

pub const error_methods = [_][]const u8{
    // File operations (close is void in 0.15: fs/File.zig:202, fs/Dir.zig:806)
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

    // Parsing. The flat list matches all call shapes: one entry per
    // pattern, never per std module. ".parseFromSlice(" also covers
    // std.json.parseFromSlice (0.15.1 json.zig alias of json/static.zig;
    // json.zig:26-27 use it), so the old JSON-section duplicate collapsed
    // here (F7 dedup).
    ".parse(",
    ".parseFromSlice(",
    ".parseInt(",
    ".parseFloat(",
    ".parseUnsigned(",

    // Formatting
    ".format(",
    ".allocPrint(",
    ".bufPrint(",

    // JSON. The parse family stays in the Parsing section above, and
    // ".stringifyAlloc(" left the table: it is absent from 0.15.1's
    // json.zig, json/Stringify.zig, json/dynamic.zig, and json/static.zig
    // (verified against the fetched 0.15.1 sources).
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

    // ArrayList/containers that can fail. ".ensureTotalCapacity(" and
    // ".ensureUnusedCapacity(" also cover the HashMap methods
    // (0.15.1 hash_map.zig:303/:310 — !void), so the old HashMap-section
    // duplicates collapsed here (F7 dedup).
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

/// Named struct type for deprecated pattern information.
/// Alias of the shared vocab type, so checkDeprecated returns one type
/// across all version modules.
pub const DeprecatedPattern = vocab.DeprecatedPattern;

pub const deprecated_patterns = [_]DeprecatedPattern{
    .{
        // 0.15 made ArrayList the unmanaged default: the Unmanaged spelling
        // is the deprecated alias, not the other way around (0.16 std.zig:59
        // "Deprecated; use `ArrayList`" corroborates).
        .pattern = "std.ArrayListUnmanaged(",
        .replacement = "std.ArrayList (unmanaged by default since 0.15)",
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
    .{
        // 0.15 de-genericified the linked lists (0.15.1 release notes,
        // "De-Genericify Linked Lists"): the generic `SinglyLinkedList(T)`
        // spelling is the deprecated form.
        .pattern = "SinglyLinkedList(",
        .replacement = "SinglyLinkedList (non-generic since 0.15)",
        .rule = "ZAV107",
    },
    .{
        .pattern = "DoublyLinkedList(",
        .replacement = "DoublyLinkedList (non-generic since 0.15)",
        .rule = "ZAV108",
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

// ============================================================================
// Comptime Flat Arrays - for fast substring matching in main.zig
// Hand-maintained; keep in sync with the structured tables above (F14)
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
    ".allocPrintSentinel(",
    // Container methods that produce owned memory
    ".toOwnedSlice(",
    ".toOwnedSliceSentinel(",
    ".cloneWithAllocator(",
    // File I/O (allocating reads; allocator is the first argument)
    ".readFileAlloc(",
    ".readFileAllocOptions(",
    ".readAlloc(",
    ".allocRemaining(",
    // Sentinel-terminated read of the rest of the stream
    // (Io/Reader.zig:299 — allocator is the first arg after the receiver,
    // the same shape as .readAlloc/.allocRemaining)
    ".allocRemainingAlignedSentinel(",
    // Path operations (fs.zig:521/656/683)
    ".selfExePathAlloc(",
    ".selfExeDirPathAlloc(",
    ".realpathAlloc(",
    // String operations
    ".replaceOwned(",
    ".concatWithSentinel(",
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
    "allocPrintSentinel",
    "toOwnedSlice",
    "toOwnedSliceSentinel",
    "cloneWithAllocator",
    "readFileAlloc",
    "readFileAllocOptions",
    "readAlloc",
    "allocRemaining",
    "allocRemainingAlignedSentinel",
    "selfExePathAlloc",
    "selfExeDirPathAlloc",
    "realpathAlloc",
    "replaceOwned",
    "concatWithSentinel",
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
    ".prepend(",
    ".addOne(",
    ".toOwnedSlice(",
    ".fromOwnedSlice(",
    ".clone(",
};

/// Stdlib methods safe to discard (void or value-returning, not error-returning).
/// This flat array is the consumed surface: isSafeToDiscard and isSafeBuiltin
/// in main.zig read it through compat.getSafeMethodPatterns(). The .write(,
/// .print(, and expect( forms are NOT here: all three return error unions
/// (!usize, !void, !void) and discarding them is exactly what ZA205 exists
/// to catch (B71 F7, r2 F2 — testing.zig:614).
pub const safe_method_patterns: []const []const u8 = &.{
    ".clear(",
    ".clearAndFree(",
    ".clearRetainingCapacity(",
    ".reset(",
    ".close(",
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
};

/// Stdlib void methods (the void-returning subset of safe_method_patterns)
pub const void_method_patterns: []const []const u8 = &.{
    ".clear(",
    ".clearAndFree(",
    ".clearRetainingCapacity(",
    ".reset(",
    ".close(",
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
    // Collections (linked lists are non-generic structs since 0.15:
    // std.zig:13 and :30 import them as plain `pub const`)
    "ArrayList(",
    "ArrayListUnmanaged(",
    "ArrayListAligned(",
    "MultiArrayList(",
    "SegmentedList(",
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
    // IO (File and Dir stay at std.fs in 0.15: fs.zig:18-19; Reader moved
    // to std.Io in 0.15: Io.zig:82; the BufferedReader/BufferedWriter names
    // left the stdlib in 0.15)
    "std.fs.File",
    "fs.File",
    "Io.Reader",
};

/// Managed-container type families: structs that own a heap backing store
/// (ptr + capacity + allocator fields), so a BY-VALUE copy aliases the same
/// backing allocation — returning one from a fn creates a second owner with
/// no language-level transfer (double-free on deinit, dangle after a callee
/// defer). Deliberately EXCLUDES the inline-storage entries of
/// stdlib_container_init_patterns (EnumArray/EnumMap/EnumSet/StaticStringMap
/// copy safely) and node-based linked lists (nodes stay user-owned).
/// Patterns carry the trailing `(` of a generic instantiation except the
/// non-generic BufMap/BufSet. Used by ZA110 return-type classification.
pub const managed_container_type_patterns: []const []const u8 = &.{
    "ArrayList(",
    "ArrayListUnmanaged(",
    "ArrayListAligned(",
    "MultiArrayList(",
    "SegmentedList(",
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
        if (std.mem.indexOf(u8, line, dep.pattern) != null) {
            return dep;
        }
    }
    return null;
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

test "checkDeprecated flags the deprecated ArrayListUnmanaged alias (F5)" {
    // 0.15 made ArrayList the unmanaged default, so the Unmanaged spelling
    // is the deprecated form — not the other way around.
    const line = "var list = std.ArrayListUnmanaged(u8){};";
    const result = checkDeprecated(line);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("ZAV101", result.?.rule);
    // The canonical form must NOT be flagged.
    const canonical = "var list = std.ArrayList(u8){};";
    try std.testing.expect(checkDeprecated(canonical) == null);
}

test "checkDeprecated flags the generic linked-list spellings (EPH-I1118)" {
    // 0.15 de-genericified the linked lists, so the generic `(T)` spelling
    // is the deprecated form (mirrors v0_16's ZAV205/ZAV206).
    const singly = "const node = std.SinglyLinkedList(u32).Node{};";
    const singly_result = checkDeprecated(singly);
    try std.testing.expect(singly_result != null);
    try std.testing.expectEqualStrings("ZAV107", singly_result.?.rule);
    const doubly = "var list = std.DoublyLinkedList(u8){};";
    const doubly_result = checkDeprecated(doubly);
    try std.testing.expect(doubly_result != null);
    try std.testing.expectEqualStrings("ZAV108", doubly_result.?.rule);
    // The non-generic form must NOT be flagged.
    const canonical = "var list = std.SinglyLinkedList{};";
    try std.testing.expect(checkDeprecated(canonical) == null);
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

test "alloc tables include allocPrintSentinel and allocRemainingAlignedSentinel (EPH-I1114)" {
    // findAllocCall/hasAllocCallPattern read the flat pattern table and
    // isNonAllocFnCallAt reads the short-name table; both names must land
    // in both (pinned 0.16 std: fmt.zig:639, Io/Reader.zig:299).
    var found_pattern_print = false;
    var found_pattern_remaining = false;
    for (alloc_method_patterns) |p| {
        if (std.mem.eql(u8, p, ".allocPrintSentinel(")) found_pattern_print = true;
        if (std.mem.eql(u8, p, ".allocRemainingAlignedSentinel(")) found_pattern_remaining = true;
    }
    try std.testing.expect(found_pattern_print);
    try std.testing.expect(found_pattern_remaining);
    var found_name_print = false;
    var found_name_remaining = false;
    for (alloc_method_short_names) |n| {
        if (std.mem.eql(u8, n, "allocPrintSentinel")) found_name_print = true;
        if (std.mem.eql(u8, n, "allocRemainingAlignedSentinel")) found_name_remaining = true;
    }
    try std.testing.expect(found_name_print);
    try std.testing.expect(found_name_remaining);
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
