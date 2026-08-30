// Zig 0.15.x Compatibility Layer
//
// This module provides version-specific implementations and pattern definitions
// for Zig 0.15.x. Used by Ephor to detect version-appropriate issues.
//
// API Characteristics (0.15.x):
//   - HashMap.put(key, value) - no allocator argument
//   - ArrayList.append(allocator, item) - allocator required
//   - ArrayList - unmanaged by default (0.15.1 "ArrayList: make unmanaged
//     the default"). The ArrayListUnmanaged spelling is the deprecated alias
//   - std.mem.Allocator passed to methods, not stored in containers
//   - zig-cache renamed to .zig-cache

const std = @import("std");
const mem = std.mem;
// Shared quote machine for the code-position mask (EPH-I0880). types.zig
// imports only std, so this import edge stays cycle-free.
const types = @import("../types.zig");

/// Version identifier
pub const version = "0.15";

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

    // GPU and WebAssembly builtins (verified against the 0.16.0 compiler.
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

    // Environment (posix.getenv returns ?[:0]const u8: posix.zig:2029.
    // std.process.getenv left in 0.15 — process has getenvW and EnvironMap)
    "std.posix.getenv(",
};

// ============================================================================
// Comptime Flat Arrays - for fast substring matching in main.zig
// Hand-maintained. Keep in sync with the structured tables above (F14)
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
    // File I/O (allocating reads. Allocator is the first argument)
    ".readFileAlloc(",
    ".readFileAllocOptions(",
    ".readAlloc(",
    ".allocRemaining(",
    // .allocRemainingAlignedSentinel is deliberately absent — 0.16-only
    // (Io/Reader.zig:299, zero hits in the 0.15.1 and 0.15.2 stdlib).
    // v0_16 carries it, and main.zig's first_arg_alloc_patterns keeps the
    // version-agnostic superset entry (EPH-I1114).
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
    // IO (File and Dir stay at std.fs in 0.15: fs.zig:18-19. Reader moved
    // to std.Io in 0.15: Io.zig:82. The BufferedReader/BufferedWriter names
    // left the stdlib in 0.15)
    "std.fs.File",
    "fs.File",
    "Io.Reader",
};

/// Managed-container exclusions: init-table entries that copy safely or
/// own no heap backing (node-based lists keep their nodes user-owned.
/// The inline-storage containers copy by value). The idx field is the
/// entry's position in stdlib_container_init_patterns, and the comptime
/// block below asserts each pair stays in sync, so a reordered or
/// renamed init table fails the build instead of silently changing the
/// managed set (EPH-I1232).
const managed_exclusions = [_]struct { idx: usize, name: []const u8 }{
    .{ .idx = 7, .name = "SinglyLinkedList" },
    .{ .idx = 8, .name = "DoublyLinkedList" },
    .{ .idx = 17, .name = "StaticStringMap(" },
    .{ .idx = 18, .name = "EnumArray(" },
    .{ .idx = 19, .name = "EnumMap(" },
    .{ .idx = 20, .name = "EnumSet(" },
    .{ .idx = 21, .name = "BufSet.init(" },
    .{ .idx = 22, .name = "BufMap.init(" },
    .{ .idx = 23, .name = "std.fs.File" },
    .{ .idx = 24, .name = "fs.File" },
    .{ .idx = 25, .name = "Io.Reader" },
};

/// Non-generic managed names appended after the filtered init entries.
const managed_extras = [_][]const u8{ "BufMap", "BufSet" };

/// Managed-container type families: structs that own a heap backing store
/// (ptr + capacity + allocator fields), so a BY-VALUE copy aliases the same
/// backing allocation — returning one from a fn creates a second owner with
/// no language-level transfer (double-free on deinit, dangle after a callee
/// defer). Derived from stdlib_container_init_patterns minus the
/// managed_exclusions plus managed_extras: the inline-storage entries
/// (EnumArray/EnumMap/EnumSet/StaticStringMap copy safely) and node-based
/// linked lists drop out, and the BufMap/BufSet names join without the
/// `.init(` of the generic form. Patterns carry the trailing `(` of a
/// generic instantiation except the non-generic BufMap/BufSet. Used by
/// ZA110 return-type classification.
pub const managed_container_type_patterns: []const []const u8 = managed_patterns_list[0..];

/// Result length of the managed table: init entries minus the excluded
/// ones plus the extras.
const managed_pattern_count =
    stdlib_container_init_patterns.len - managed_exclusions.len + managed_extras.len;

/// The managed families built once at comptime: init entries minus the
/// exclusions plus the extras, in init order. The array form (not a blk
/// slice) keeps the result immutable comptime data.
fn buildManagedPatterns() [managed_pattern_count][]const u8 {
    var list: [managed_pattern_count][]const u8 = undefined;
    var n: usize = 0;
    for (stdlib_container_init_patterns) |p| {
        if (isManagedExcluded(p)) continue;
        list[n] = p;
        n += 1;
    }
    for (managed_extras) |e| {
        list[n] = e;
        n += 1;
    }
    return list;
}

/// The immutable comptime array backing managed_container_type_patterns.
const managed_patterns_list = buildManagedPatterns();

/// True when init-table entry `p` stays out of the managed families.
fn isManagedExcluded(p: []const u8) bool {
    for (managed_exclusions) |x| {
        if (mem.eql(u8, p, x.name)) return true;
    }
    return false;
}

comptime {
    for (managed_exclusions) |x| {
        if (!mem.eql(u8, stdlib_container_init_patterns[x.idx], x.name)) {
            @compileError("managed_exclusions drift at: " ++ x.name);
        }
    }
}

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

/// Check if a line contains a builtin function at a code position
pub fn containsBuiltin(line: []const u8) bool {
    for (builtins) |builtin| {
        if (containsPatternInCode(line, builtin)) return true;
    }
    return false;
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
    try std.testing.expect(!containsOptionalMethod(
        "_ = foo(); // map.get(key) returns an optional",
    ));
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

test "alloc tables include allocPrintSentinel, omit 0.16-only allocRemainingAlignedSentinel (EPH-I1114)" {
    // findAllocCall/hasAllocCallPattern read the flat pattern table and
    // isNonAllocFnCallAt reads the short-name table. A name must land in
    // both. allocPrintSentinel pins the 0.15 std (fmt.zig:644).
    // allocRemainingAlignedSentinel is 0.16-only (Io/Reader.zig:299), so
    // both v0_15 tables deliberately omit it. v0_16 carries it.
    var found_pattern_print = false;
    var found_pattern_remaining = false;
    for (alloc_method_patterns) |p| {
        if (std.mem.eql(u8, p, ".allocPrintSentinel(")) found_pattern_print = true;
        if (std.mem.eql(u8, p, ".allocRemainingAlignedSentinel(")) found_pattern_remaining = true;
    }
    try std.testing.expect(found_pattern_print);
    try std.testing.expect(!found_pattern_remaining);
    var found_name_print = false;
    var found_name_remaining = false;
    for (alloc_method_short_names) |n| {
        if (std.mem.eql(u8, n, "allocPrintSentinel")) found_name_print = true;
        if (std.mem.eql(u8, n, "allocRemainingAlignedSentinel")) found_name_remaining = true;
    }
    try std.testing.expect(found_name_print);
    try std.testing.expect(!found_name_remaining);
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
