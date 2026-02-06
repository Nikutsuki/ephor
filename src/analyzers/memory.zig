// Rhyos Labs - Ephor
// Memory analysis module
// Copyright (C) 2025 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const types = @import("../types.zig");
const Issue = types.Issue;
const FileAnalysis = types.FileAnalysis;

// ============================================================================
// Memory Analysis Helpers
// ============================================================================

/// Check if allocator variable name suggests no-free allocator
pub fn isNoFreeAllocatorName(name: []const u8) bool {
    if (mem.indexOf(u8, name, "arena") != null) return true;
    if (mem.indexOf(u8, name, "scratch") != null) return true;
    if (mem.indexOf(u8, name, "temp") != null) return true;
    if (mem.indexOf(u8, name, "frame") != null) return true;
    if (mem.eql(u8, name, "fba")) return true;
    return false;
}

/// Check if ownership is transferred via cast, reassignment, or return
pub fn isOwnershipTransfer(t: []const u8, alloc_name: []const u8) bool {
    if (mem.indexOf(u8, t, "@ptrCast") != null and
        mem.indexOf(u8, t, alloc_name) != null) return true;
    if (mem.indexOf(u8, t, "@alignCast") != null and
        mem.indexOf(u8, t, alloc_name) != null) return true;
    if (mem.indexOf(u8, t, ".ptr") != null and
        mem.indexOf(u8, t, alloc_name) != null) return true;
    if (mem.indexOf(u8, t, ".append(") != null and
        mem.indexOf(u8, t, alloc_name) != null) return true;
    if (mem.indexOf(u8, t, ".put(") != null and
        mem.indexOf(u8, t, alloc_name) != null) return true;
    if (mem.indexOf(u8, t, ".putNoClobber(") != null and
        mem.indexOf(u8, t, alloc_name) != null) return true;
    // Ownership transfer via return: return alloc_name; or return alloc_name[...]
    if (isReturnOwnership(t, alloc_name)) return true;
    return false;
}

/// Check if line returns the allocated variable (ownership transfer to caller)
fn isReturnOwnership(t: []const u8, alloc_name: []const u8) bool {
    const ret_pos = mem.indexOf(u8, t, "return ") orelse return false;
    const after_return = t[ret_pos + 7 ..];
    const trimmed = mem.trimLeft(u8, after_return, " ");
    // Direct return: "return alloc_name;" or "return alloc_name[..."
    if (mem.startsWith(u8, trimmed, alloc_name)) {
        const after_name = trimmed[alloc_name.len..];
        if (after_name.len == 0) return true;
        const next = after_name[0];
        // return alloc_name; or return alloc_name[0..N]
        if (next == ';' or next == '[' or next == ',' or next == ' ') return true;
        // return alloc_name.items or return alloc_name.ptr - not ownership transfer
        // (accessing a field of the alloc, not transferring the alloc itself)
    }
    return false;
}

/// Check if this is a pool allocator pattern
pub fn isPoolAllocator(t: []const u8) bool {
    if (mem.indexOf(u8, t, "MemoryPool") != null) return true;
    if (mem.indexOf(u8, t, "pool.create(") != null) return true;
    if (mem.indexOf(u8, t, "pool.alloc(") != null) return true;
    if (mem.indexOf(u8, t, "ObjectPool") != null) return true;
    return false;
}

/// Check if name is a known allocator name
fn isKnownAllocatorName(name: []const u8) bool {
    const known = [_][]const u8{
        "allocator", "alloc",          "gpa",               "arena",
        "fba",       "page_allocator", "testing_allocator", "self",
    };
    for (known) |n| {
        if (mem.eql(u8, name, n)) return true;
    }
    return mem.indexOf(u8, name, "allocator") != null or
        mem.indexOf(u8, name, "alloc") != null;
}

/// Check if .create() is allocator.create() vs Type.create() static method
pub fn isAllocatorCreate(t: []const u8) bool {
    const create_pos = mem.indexOf(u8, t, ".create(") orelse return false;
    if (create_pos == 0) return false;

    var start = create_pos;
    while (start > 0 and types.isIdent(t[start - 1])) start -= 1;
    if (start >= create_pos) return false;

    const name = t[start..create_pos];
    // Uppercase = Type.create() static method, not allocation
    if (name.len > 0 and name[0] >= 'A' and name[0] <= 'Z') return false;

    if (isKnownAllocatorName(name)) return true;
    if (mem.indexOf(u8, t, "try ")) |try_pos| {
        if (try_pos < create_pos) return true;
    }
    return true;
}

/// Extract allocator name from allocation line
pub fn extractAllocatorName(t: []const u8) ?[]const u8 {
    const alloc_call = ".alloc(";
    const create_call = ".create(";
    const alloc_pos = mem.indexOf(u8, t, alloc_call) orelse
        mem.indexOf(u8, t, create_call) orelse return null;

    const end = alloc_pos;
    var start = end;
    while (start > 0 and (types.isIdent(t[start - 1]) or t[start - 1] == '.')) {
        start -= 1;
    }
    while (start < end and t[start] == '.') start += 1;

    if (start < end) {
        var name_end = start;
        while (name_end < end and types.isIdent(t[name_end])) name_end += 1;
        if (name_end > start) return t[start..name_end];
    }
    return null;
}

/// Check if line is a comment
fn isComment(trimmed: []const u8) bool {
    return mem.startsWith(u8, trimmed, "//");
}

/// Check if function uses arena/fixed-buffer allocator
fn detectsArenaAllocator(t: []const u8) bool {
    if (mem.indexOf(u8, t, "ArenaAllocator") != null) return true;
    if (mem.indexOf(u8, t, "arena.allocator()") != null) return true;
    if (mem.indexOf(u8, t, "FixedBufferAllocator") != null) return true;
    if (mem.indexOf(u8, t, "fba.allocator()") != null) return true;
    if (mem.indexOf(u8, t, "stackFallback") != null) return true;
    return false;
}

/// Extract variable name from assignment
fn extractVarName(t: []const u8) ?[]const u8 {
    const is_const = mem.startsWith(u8, t, "const ");
    const is_var = mem.startsWith(u8, t, "var ");
    if (!is_const and !is_var) return null;

    const prefix_len: usize = if (is_const) 6 else 4;
    var name_end = prefix_len;
    while (name_end < t.len and types.isIdent(t[name_end])) name_end += 1;
    if (name_end > prefix_len) return t[prefix_len..name_end];
    return null;
}

/// Report allocation issue
fn reportAlloc(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    line: usize,
    col: usize,
    is_create: bool,
) !void {
    const rule = if (is_create) types.RULE_CREATE_NO_DEFER else types.RULE_ALLOC_NO_DEFER;
    const msg = if (is_create)
        "create() without defer destroy()"
    else
        "alloc() without defer free()";
    const help = if (is_create)
        "add 'defer allocator.destroy(ptr);' after create()"
    else
        "add 'defer allocator.free(slice);' after alloc()";

    try issues.append(allocator, .{
        .file = path,
        .line = line,
        .col = col,
        .severity = .warning,
        .rule = rule,
        .message = msg,
        .help = help,
    });
}

/// Track brace depth and reset state on function end
fn trackBraceDepth(t: []const u8, state: *AnalysisState) void {
    for (t) |c| {
        if (c == '{') state.depth += 1;
        if (c != '}') continue;
        if (state.depth > 0) state.depth -= 1;
        if (state.depth == 0) state.resetFn();
    }
}

/// Check if line has valid allocation call
fn isValidAlloc(t: []const u8, col: usize) bool {
    return !types.isInsideString(t, col) and
        mem.indexOf(u8, t, "defer") == null and
        !isPoolAllocator(t);
}

/// Record allocation info into state
fn recordAlloc(t: []const u8, state: *AnalysisState, line: usize, col: usize, is_create: bool) void {
    state.alloc_line = line;
    state.alloc_col = col + 1;
    state.is_create = is_create;
    if (extractVarName(t)) |name| state.alloc_name = name;
    if (extractAllocatorName(t)) |name| state.allocator_name = name;
}

/// Detect allocations on line
fn detectAllocs(t: []const u8, state: *AnalysisState, line_num: usize) void {
    if (mem.indexOf(u8, t, ".alloc(")) |col| {
        if (isValidAlloc(t, col)) recordAlloc(t, state, line_num, col, false);
    } else if (mem.indexOf(u8, t, ".create(")) |col| {
        if (isValidAlloc(t, col) and isAllocatorCreate(t)) {
            recordAlloc(t, state, line_num, col, true);
        }
    }
}

/// Process a single line for allocation tracking
fn processLine(t: []const u8, state: *AnalysisState, line_num: usize) void {
    if (state.in_fn and detectsArenaAllocator(t)) state.uses_arena = true;
    trackBraceDepth(t, state);
    if (mem.indexOf(u8, t, "defer ") != null) state.has_defer = true;
    if (state.alloc_name.len > 0 and isOwnershipTransfer(t, state.alloc_name)) {
        state.has_defer = true;
    }
    if (mem.indexOf(u8, t, "fn ") != null) state.initFn();
    if (state.in_fn) detectAllocs(t, state, line_num);
}

const AnalysisState = struct {
    in_fn: bool = false,
    depth: usize = 0,
    has_defer: bool = false,
    alloc_line: usize = 0,
    alloc_col: usize = 1,
    is_create: bool = false,
    uses_arena: bool = false,
    alloc_name: []const u8 = "",
    allocator_name: []const u8 = "",

    fn initFn(self: *AnalysisState) void {
        self.in_fn = true;
        self.depth = 0;
        self.has_defer = false;
        self.uses_arena = false;
        self.alloc_name = "";
        self.allocator_name = "";
    }

    fn resetFn(self: *AnalysisState) void {
        self.in_fn = false;
        self.alloc_line = 0;
        self.alloc_name = "";
        self.allocator_name = "";
    }
};

/// Check if we need to report missing defer at function end
fn shouldReportMissingDefer(state: *const AnalysisState) bool {
    if (state.alloc_line == 0 or state.has_defer) return false;
    if (state.uses_arena) return false;
    return !isNoFreeAllocatorName(state.allocator_name);
}

/// Check for function-end closing brace and report if needed
fn checkFunctionEnd(
    t: []const u8,
    state: *const AnalysisState,
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
) !void {
    if (state.depth == 0) return;
    for (t) |c| {
        if (c != '}' or state.depth != 1) continue;
        if (shouldReportMissingDefer(state)) {
            try reportAlloc(issues, allocator, path, state.alloc_line, state.alloc_col, state.is_create);
        }
    }
}

/// Analyze a single file for memory issues
fn analyzeFile(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    analysis: FileAnalysis,
) !void {
    var state = AnalysisState{};
    var line_num: usize = 1;
    var lines = mem.splitScalar(u8, analysis.content, '\n');

    while (lines.next()) |line| {
        defer line_num += 1;
        const t = mem.trim(u8, line, " \t\r");
        if (mem.startsWith(u8, t, "\\\\") or isComment(t)) continue;
        try checkFunctionEnd(t, &state, issues, allocator, analysis.path);
        processLine(t, &state, line_num);
    }
}

// ============================================================================
// Public API
// ============================================================================

pub const ImportGraph = struct {
    files: std.StringHashMap(FileAnalysis),

    pub fn iterator(self: *ImportGraph) std.StringHashMap(FileAnalysis).Iterator {
        return self.files.iterator();
    }
};

/// Analyze memory patterns in all files
pub fn analyze(
    allocator: Allocator,
    graph: anytype,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    var iter = graph.files.iterator();

    while (iter.next()) |entry| {
        const analysis = entry.value_ptr.*;
        try analyzeFile(allocator, &issues, analysis);
    }

    return issues;
}

// ============================================================================
// Tests
// ============================================================================

test "isNoFreeAllocatorName detects arena" {
    try std.testing.expect(isNoFreeAllocatorName("arena"));
    try std.testing.expect(isNoFreeAllocatorName("scratch_allocator"));
    try std.testing.expect(!isNoFreeAllocatorName("gpa"));
}

test "isAllocatorCreate detects static methods" {
    try std.testing.expect(!isAllocatorCreate("HmacSha256.create()"));
    try std.testing.expect(isAllocatorCreate("allocator.create(T)"));
    try std.testing.expect(isAllocatorCreate("gpa.create(Node)"));
}

test "extractAllocatorName finds allocator" {
    const name = extractAllocatorName("const x = allocator.alloc(u8, 10)");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("allocator", name.?);
}
