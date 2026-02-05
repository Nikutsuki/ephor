// Rhyos Labs - Ephor
// Static analysis tool for Zig projects
// Copyright (C) 2025 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

//! Ephor: The overseer of your Zig code - Static + Dynamic analysis
//!
//! Output format: path:line:col: severity[rule-id]: message
//! Compatible with GCC, clang, ESLint, IntelliJ IDEA, VS Code
//!
//! Commands:
//! - orphans:    Files not imported from entry points
//! - memory:     Alloc without defer patterns
//! - errors:     Silent catch {} discards
//! - unused:     Unused imports and declarations
//! - complexity: Function complexity metrics
//! - fmt-check:  Files needing zig fmt (wrapper)
//! - stats:      Project metrics
//! - check:      Run all checks

const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;

// Version compatibility layer
pub const compat = @import("compat/compat.zig");

// Shared types and utilities
const types = @import("types.zig");

// Analyzer modules (for future use - keeps them as non-orphans)
const analyzers = @import("analyzers/analyzers.zig");

// Import shared types and constants from types.zig
const RULE_ALLOC_NO_DEFER = types.RULE_ALLOC_NO_DEFER;
const RULE_CREATE_NO_DEFER = types.RULE_CREATE_NO_DEFER;
const RULE_ALLOC_NO_ERRDEFER = types.RULE_ALLOC_NO_ERRDEFER;
const RULE_MEMORY_LEAK = types.RULE_MEMORY_LEAK;
const RULE_USE_AFTER_FREE = types.RULE_USE_AFTER_FREE;
const RULE_DOUBLE_FREE = types.RULE_DOUBLE_FREE;
const RULE_SILENT_CATCH = types.RULE_SILENT_CATCH;
const RULE_CATCH_UNREACHABLE = types.RULE_CATCH_UNREACHABLE;
const RULE_ORELSE_UNREACHABLE = types.RULE_ORELSE_UNREACHABLE;
const RULE_UNDEFINED_USAGE = types.RULE_UNDEFINED_USAGE;
const RULE_IGNORED_ERROR = types.RULE_IGNORED_ERROR;
const RULE_FUNC_TOO_LONG = types.RULE_FUNC_TOO_LONG;
const RULE_NESTING_TOO_DEEP = types.RULE_NESTING_TOO_DEEP;
const RULE_TOO_MANY_PARAMS = types.RULE_TOO_MANY_PARAMS;
const RULE_TOO_MANY_BRANCHES = types.RULE_TOO_MANY_BRANCHES;
const RULE_UNUSED_IMPORT = types.RULE_UNUSED_IMPORT;
const RULE_UNUSED_CONST = types.RULE_UNUSED_CONST;
const RULE_UNUSED_VAR = types.RULE_UNUSED_VAR;
const RULE_ORPHAN_FILE = types.RULE_ORPHAN_FILE;
const RULE_NEEDS_FORMAT = types.RULE_NEEDS_FORMAT;
const RULE_LINE_TOO_LONG = types.RULE_LINE_TOO_LONG;
const RULE_FILE_TOO_LONG = types.RULE_FILE_TOO_LONG;
const RULE_NAMING_CONVENTION = types.RULE_NAMING_CONVENTION;
const RULE_OPTIONAL_UNWRAP_UNSAFE = types.RULE_OPTIONAL_UNWRAP_UNSAFE;
const RULE_ORELSE_QUESTION_UNSAFE = types.RULE_ORELSE_QUESTION_UNSAFE;
const RULE_DECREMENT_WITHOUT_CHECK = types.RULE_DECREMENT_WITHOUT_CHECK;
const RULE_SUBTRACTION_OVERFLOW = types.RULE_SUBTRACTION_OVERFLOW;
const RULE_INDEX_ARITHMETIC = types.RULE_INDEX_ARITHMETIC;
const RULE_RUNTIME_MEMORY_LEAK = types.RULE_RUNTIME_MEMORY_LEAK;
const RULE_RUNTIME_DOUBLE_FREE = types.RULE_RUNTIME_DOUBLE_FREE;
const RULE_RUNTIME_USE_AFTER_FREE = types.RULE_RUNTIME_USE_AFTER_FREE;
const RULE_RUNTIME_TEST_FAILURE = types.RULE_RUNTIME_TEST_FAILURE;
const RULE_RUNTIME_PANIC = types.RULE_RUNTIME_PANIC;

const Severity = types.Severity;

// Output format (not in types.zig - specific to CLI)
const OutputFormat = types.OutputFormat;

// Import shared types from types.zig
const ImportInfo = types.ImportInfo;
const Issue = types.Issue;
const ProjectStats = types.ProjectStats;
const deinitIssues = types.deinitIssues;
const countOccurrences = types.countOccurrences;
const countLines = types.countLines;
const isIdent = types.isIdent;
const isInsideString = types.isInsideString;
const skipWhitespace = types.skipWhitespace;

const FileAnalysis = types.FileAnalysis;
const Thresholds = types.Thresholds;

// ============================================================================
// Control Flow Graph (CFG) Infrastructure - Phase 4
// ============================================================================

/// State of an allocation through the CFG
const AllocationState = enum {
    unknown, // Initial state
    allocated, // Memory allocated, not yet freed
    freed, // Memory has been freed
    will_free, // Covered by defer (will be freed on scope exit)
    escaped, // Pointer returned or stored (ownership transferred)
};

/// Represents a variable/allocation being tracked
const TrackedAllocation = struct {
    name: []const u8, // Variable name holding the allocation
    line: usize, // Line where allocated
    col: usize, // Column where allocated
    state: AllocationState,
    is_create: bool, // true = create(), false = alloc()
};

/// A basic block in the CFG - straight-line code with no internal branches
const BasicBlock = struct {
    id: usize,
    start_line: usize,
    end_line: usize,
    allocations: std.ArrayListUnmanaged(TrackedAllocation),
    has_defer_free: bool,
    has_errdefer: bool,
    is_return: bool,
    is_error_return: bool,
    returns_value: bool,
    is_catch_block: bool, // Block is in error recovery path (catch handler)

    fn init() BasicBlock {
        return .{
            .id = 0,
            .start_line = 0,
            .end_line = 0,
            .allocations = .{},
            .has_defer_free = false,
            .has_errdefer = false,
            .is_return = false,
            .is_error_return = false,
            .returns_value = false,
            .is_catch_block = false,
        };
    }

    fn deinit(self: *BasicBlock, allocator: Allocator) void {
        self.allocations.deinit(allocator);
    }
};

/// Edge types in CFG
const EdgeKind = enum {
    sequential, // Normal flow to next block
    branch_true, // Conditional true branch
    branch_false, // Conditional false branch
    loop_back, // Loop back edge
    error_path, // Error handling path (catch, errdefer)
};

/// An edge connecting two basic blocks
const CFGEdge = struct {
    from: usize, // Block ID
    to: usize, // Block ID
    kind: EdgeKind,
};

/// Block type for stack tracking in CFG construction
const BlockType = enum {
    if_block, // if-statement true branch
    else_block, // else branch
    while_block, // while loop
    for_block, // for loop
    catch_block, // catch block (error path)
    switch_block, // switch arm
};

/// Stack entry for CFG construction - tracks block type and continuation point
const StackEntry = struct {
    block_type: BlockType,
    merge_block: usize, // Block to merge back to (or continuation for catch)
    catch_origin_block: usize, // For catch: the block before catch started (0 if N/A)
};

/// Control Flow Graph for a single function
const ControlFlowGraph = struct {
    allocator: Allocator,
    func_name: []const u8,
    func_line: usize,
    blocks: std.ArrayListUnmanaged(BasicBlock),
    edges: std.ArrayListUnmanaged(CFGEdge),
    entry_block: usize,
    exit_blocks: std.ArrayListUnmanaged(usize),

    fn init(alloc: Allocator, name: []const u8, line: usize) ControlFlowGraph {
        return .{
            .allocator = alloc,
            .func_name = name,
            .func_line = line,
            .blocks = .{},
            .edges = .{},
            .entry_block = 0,
            .exit_blocks = .{},
        };
    }

    fn deinit(self: *ControlFlowGraph) void {
        for (self.blocks.items) |*block| {
            block.deinit(self.allocator);
        }
        self.blocks.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.exit_blocks.deinit(self.allocator);
    }

    fn addBlock(self: *ControlFlowGraph) !usize {
        const id = self.blocks.items.len;
        var block = BasicBlock.init();
        block.id = id;
        try self.blocks.append(self.allocator, block);
        return id;
    }

    fn addEdge(
        self: *ControlFlowGraph,
        from: usize,
        to: usize,
        kind: EdgeKind,
    ) !void {
        try self.edges.append(self.allocator, .{
            .from = from,
            .to = to,
            .kind = kind,
        });
    }

    /// Get all predecessor blocks for a given block
    fn getPredecessors(
        self: *ControlFlowGraph,
        block_id: usize,
        result: *std.ArrayListUnmanaged(usize),
    ) !void {
        for (self.edges.items) |edge| {
            if (edge.to == block_id) {
                try result.append(self.allocator, edge.from);
            }
        }
    }

    /// Get all successor blocks for a given block
    fn getSuccessors(
        self: *ControlFlowGraph,
        block_id: usize,
        result: *std.ArrayListUnmanaged(usize),
    ) !void {
        for (self.edges.items) |edge| {
            if (edge.from == block_id) {
                try result.append(self.allocator, edge.to);
            }
        }
    }
};

// ============================================================================
// Data Flow Analysis Framework (Phase 2)
// ============================================================================

/// Variable state for definite assignment analysis
const VarState = enum {
    undefined, // Not yet assigned
    defined, // Has been assigned
    maybe_defined, // Assigned on some but not all paths
};

/// Allocation state for path-sensitive memory analysis
const AllocState = enum {
    not_allocated, // Not yet allocated
    allocated, // Memory allocated, not yet freed
    freed, // Memory has been freed on this path
    maybe_freed, // Freed on some paths but not all (join point)
    escaped, // Ownership transferred (returned/stored)
};

/// Tracked allocation for CFG-based analysis
const CFGAllocation = struct {
    name: []const u8,
    alloc_line: usize,
    alloc_col: usize,
    state: AllocState,
    freed_line: usize = 0, // Line where freed (if freed)
    is_create: bool = false,
};

/// Definition info for reaching definitions
const DefInfo = struct {
    var_name: []const u8,
    line: usize,
    kind: DefKind,
};

const DefKind = enum {
    allocation, // alloc() or create()
    assignment, // = value
    undefined_init, // = undefined
};

/// Block-level data flow state
const BlockDataFlow = struct {
    // Definite assignment: gen = vars defined in block, kill = vars read
    def_gen: std.StringHashMap(usize), // var -> line where defined
    def_kill: std.StringHashMap(void), // vars read before def
    // Reaching definitions: allocations
    alloc_gen: std.ArrayListUnmanaged(DefInfo),
    // Output state after data flow
    defined_vars: std.StringHashMap(VarState),

    fn init(allocator: Allocator) BlockDataFlow {
        return .{
            .def_gen = std.StringHashMap(usize).init(allocator),
            .def_kill = std.StringHashMap(void).init(allocator),
            .alloc_gen = .{},
            .defined_vars = std.StringHashMap(VarState).init(allocator),
        };
    }

    fn deinit(self: *BlockDataFlow, allocator: Allocator) void {
        self.def_gen.deinit();
        self.def_kill.deinit();
        self.alloc_gen.deinit(allocator);
        self.defined_vars.deinit();
    }
};

/// Control flow pattern detected on a line
const CFPattern = enum {
    none,
    if_start, // if (...) {
    else_start, // } else {
    else_if, // } else if {
    while_start, // while (...) {
    for_start, // for (...) {
    switch_start, // switch (...) {
    switch_arm, // .X => or else =>
    try_expr, // try ...
    catch_start, // catch |err| {
    return_stmt, // return ...
    break_stmt, // break
    continue_stmt, // continue
    block_end, // }
};

/// Pattern entry for control flow detection
const CFPatternEntry = struct {
    prefix: []const u8,
    exact: bool, // true = exact match, false = startsWith
    result: CFPattern,
};

/// Patterns checked in order (first match wins)
const cf_patterns = [_]CFPatternEntry{
    .{ .prefix = "} else if", .exact = false, .result = .else_if },
    .{ .prefix = "} else", .exact = false, .result = .else_start },
    .{ .prefix = "else {", .exact = true, .result = .else_start },
    .{ .prefix = "if ", .exact = false, .result = .if_start },
    .{ .prefix = "if(", .exact = false, .result = .if_start },
    .{ .prefix = "while ", .exact = false, .result = .while_start },
    .{ .prefix = "while(", .exact = false, .result = .while_start },
    .{ .prefix = "for ", .exact = false, .result = .for_start },
    .{ .prefix = "for(", .exact = false, .result = .for_start },
    .{ .prefix = "switch ", .exact = false, .result = .switch_start },
    .{ .prefix = "switch(", .exact = false, .result = .switch_start },
    .{ .prefix = "return ", .exact = false, .result = .return_stmt },
    .{ .prefix = "return;", .exact = true, .result = .return_stmt },
    .{ .prefix = "break;", .exact = true, .result = .break_stmt },
    .{ .prefix = "continue;", .exact = true, .result = .continue_stmt },
    .{ .prefix = "};", .exact = true, .result = .block_end }, // catch { ... }; ending
    .{ .prefix = "},", .exact = true, .result = .block_end }, // struct field ending
    .{ .prefix = "}", .exact = true, .result = .block_end },
};

/// Detect control flow pattern on a line
fn detectCFPattern(t: []const u8) CFPattern {
    const trimmed = mem.trim(u8, t, " \t\r");

    // Check simple patterns via table
    for (cf_patterns) |p| {
        if (p.exact) {
            if (mem.eql(u8, trimmed, p.prefix)) return p.result;
        } else {
            if (mem.startsWith(u8, trimmed, p.prefix)) return p.result;
        }
    }

    // Special cases requiring two checks
    if (mem.indexOf(u8, trimmed, "catch ") != null and
        mem.indexOf(u8, trimmed, "{") != null)
        return .catch_start;
    if (mem.indexOf(u8, trimmed, "try ") != null)
        return .try_expr;

    // Switch arm detection: .x => or else =>
    if (mem.indexOf(u8, trimmed, "=>") != null) {
        // Check for switch arm patterns
        if (mem.startsWith(u8, trimmed, ".") or
            mem.startsWith(u8, trimmed, "else =>") or
            mem.indexOf(u8, trimmed, ", .") != null)
        {
            return .switch_arm;
        }
    }

    return .none;
}

/// Build CFG from function lines
fn buildCFG(
    allocator: Allocator,
    func_name: []const u8,
    func_line: usize,
    lines: []const []const u8,
) !ControlFlowGraph {
    var cfg = ControlFlowGraph.init(allocator, func_name, func_line);
    var current_block = try cfg.addBlock();
    cfg.entry_block = current_block;

    // Set entry block's start_line to the function start
    cfg.blocks.items[current_block].start_line = func_line;

    // Use typed stack entries for proper block type tracking
    var block_stack = std.ArrayListUnmanaged(StackEntry){};
    defer block_stack.deinit(allocator);

    for (lines, 0..) |line, idx| {
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;

        const pattern = detectCFPattern(t);
        cfg.blocks.items[current_block].end_line = func_line + idx;

        switch (pattern) {
            .if_start => {
                // Create true and false branches
                const true_block = try cfg.addBlock();
                const false_block = try cfg.addBlock();
                try cfg.addEdge(current_block, true_block, .branch_true);
                try cfg.addEdge(current_block, false_block, .branch_false);
                try block_stack.append(allocator, .{
                    .block_type = .if_block,
                    .merge_block = false_block,
                    .catch_origin_block = 0,
                });
                current_block = true_block;
                cfg.blocks.items[current_block].start_line = func_line + idx;
            },
            .while_start => {
                const loop_body = try cfg.addBlock();
                const after_loop = try cfg.addBlock();
                try cfg.addEdge(current_block, loop_body, .branch_true);
                try cfg.addEdge(current_block, after_loop, .branch_false);
                try block_stack.append(allocator, .{
                    .block_type = .while_block,
                    .merge_block = after_loop,
                    .catch_origin_block = current_block, // For loop-back edge
                });
                current_block = loop_body;
                cfg.blocks.items[current_block].start_line = func_line + idx;
            },
            .for_start => {
                const loop_body = try cfg.addBlock();
                const after_loop = try cfg.addBlock();
                try cfg.addEdge(current_block, loop_body, .branch_true);
                try cfg.addEdge(current_block, after_loop, .branch_false);
                try block_stack.append(allocator, .{
                    .block_type = .for_block,
                    .merge_block = after_loop,
                    .catch_origin_block = current_block, // For loop-back edge
                });
                current_block = loop_body;
                cfg.blocks.items[current_block].start_line = func_line + idx;
            },
            .switch_start => {
                // Switch statement: create merge block for after switch
                // Arms will be handled by switch_arm
                const merge_block = try cfg.addBlock();
                try block_stack.append(allocator, .{
                    .block_type = .switch_block,
                    .merge_block = merge_block,
                    .catch_origin_block = current_block, // Store switch header block
                });
                // Don't change current_block yet - first arm will do that
            },
            .switch_arm => {
                // Switch arm: each arm gets its own block, all arms are mutually exclusive
                // Find the switch entry on the stack
                var switch_idx: ?usize = null;
                for (block_stack.items, 0..) |entry, i| {
                    if (entry.block_type == .switch_block) {
                        switch_idx = i;
                        break;
                    }
                }
                if (switch_idx) |si| {
                    // Get the switch entry (don't pop, just peek)
                    const switch_entry = block_stack.items[si];
                    const switch_header = switch_entry.catch_origin_block;

                    // If we're in an arm block (not the first arm), connect to merge
                    // Check if current_block is NOT the switch header
                    if (current_block != switch_header) {
                        // Previous arm ends - connect to merge if no return
                        if (!cfg.blocks.items[current_block].is_return) {
                            try cfg.addEdge(current_block, switch_entry.merge_block, .sequential);
                        }
                    }

                    // Create new block for this arm
                    const arm_block = try cfg.addBlock();
                    try cfg.addEdge(switch_header, arm_block, .branch_true);
                    current_block = arm_block;
                    cfg.blocks.items[current_block].start_line = func_line + idx;
                }
            },
            .else_start, .else_if => {
                // End true branch, start else branch
                if (block_stack.items.len > 0) {
                    const entry = block_stack.pop() orelse continue;
                    const else_block = entry.merge_block;
                    const merge_block = try cfg.addBlock();
                    try cfg.addEdge(current_block, merge_block, .sequential);
                    try block_stack.append(allocator, .{
                        .block_type = .else_block,
                        .merge_block = merge_block,
                        .catch_origin_block = 0,
                    });
                    current_block = else_block;
                    cfg.blocks.items[current_block].start_line = func_line + idx;
                }
            },
            .return_stmt => {
                cfg.blocks.items[current_block].is_return = true;
                try cfg.exit_blocks.append(allocator, current_block);
            },
            .block_end => {
                if (block_stack.items.len > 0) {
                    const entry = block_stack.pop() orelse continue;
                    switch (entry.block_type) {
                        .catch_block => {
                            // Catch block ending:
                            // - If catch block has return, DON'T connect to continuation
                            // - Otherwise, connect to continuation
                            const continuation = entry.merge_block;
                            if (!cfg.blocks.items[current_block].is_return) {
                                try cfg.addEdge(current_block, continuation, .sequential);
                            }
                            current_block = continuation;
                            // Set continuation start_line to the line after catch block
                            cfg.blocks.items[current_block].start_line = func_line + idx + 1;
                        },
                        .while_block, .for_block => {
                            // Loop ending: add back-edge to loop header
                            try cfg.addEdge(current_block, entry.catch_origin_block, .loop_back);
                            current_block = entry.merge_block;
                        },
                        .switch_block => {
                            // Switch ending: connect last arm to merge block
                            // All arms are mutually exclusive, so no double-free between arms
                            if (!cfg.blocks.items[current_block].is_return) {
                                try cfg.addEdge(current_block, entry.merge_block, .sequential);
                            }
                            current_block = entry.merge_block;
                            cfg.blocks.items[current_block].start_line = func_line + idx + 1;
                        },
                        else => {
                            // Normal if/else block ending
                            try cfg.addEdge(current_block, entry.merge_block, .sequential);
                            current_block = entry.merge_block;
                            // Set merge block's start_line to the line after the closing brace
                            cfg.blocks.items[current_block].start_line = func_line + idx + 1;
                        },
                    }
                }
            },
            .catch_start => {
                // Proper catch block handling with path-sensitivity:
                // 1. Create continuation block (code after catch)
                // 2. Normal path: current -> continuation
                // 3. Error path: current -> catch_block
                // 4. At block_end: if catch returns, DON'T connect to continuation
                const origin_block = current_block;
                const continuation_block = try cfg.addBlock();
                const catch_block = try cfg.addBlock();

                // Mark catch block for error recovery context detection
                cfg.blocks.items[catch_block].is_catch_block = true;

                // Edge: normal (non-error) path continues to code after catch
                try cfg.addEdge(origin_block, continuation_block, .sequential);
                // Edge: error path goes to catch block
                try cfg.addEdge(origin_block, catch_block, .error_path);

                // Push catch entry - will determine if catch->continuation edge at block_end
                try block_stack.append(allocator, .{
                    .block_type = .catch_block,
                    .merge_block = continuation_block,
                    .catch_origin_block = origin_block,
                });

                current_block = catch_block;
                cfg.blocks.items[current_block].start_line = func_line + idx;
            },
            else => {},
        }
    }

    // Mark final block as exit if no explicit return
    if (cfg.exit_blocks.items.len == 0) {
        try cfg.exit_blocks.append(allocator, current_block);
    }

    return cfg;
}

/// Check if a pattern at position is inside a string literal
/// Uses centralized implementation from types.zig that handles escape sequences correctly
fn isPatternInString(t: []const u8, pattern_pos: usize) bool {
    return types.isInsideString(t, pattern_pos);
}

/// Check if line is a comment or multiline string (should be skipped in analysis)
fn isCommentOrMultilineString(t: []const u8) bool {
    return mem.startsWith(u8, t, "//") or mem.startsWith(u8, t, "\\\\");
}

/// Check if line has a free/destroy pattern that's NOT inside a string
fn hasRealFreePattern(t: []const u8) bool {
    // Check for .free(
    if (mem.indexOf(u8, t, ".free(")) |pos| {
        if (!isPatternInString(t, pos)) return true;
    }
    // Check for .destroy(
    if (mem.indexOf(u8, t, ".destroy(")) |pos| {
        if (!isPatternInString(t, pos)) return true;
    }
    return false;
}

/// Check if line has any cleanup pattern (.free, .destroy, .deinit) NOT inside a string
fn hasRealCleanupPattern(t: []const u8) bool {
    const patterns = [_][]const u8{ ".free(", ".destroy(", ".deinit(" };
    for (patterns) |pat| {
        if (mem.indexOf(u8, t, pat)) |pos| {
            if (!isPatternInString(t, pos)) return true;
        }
    }
    return false;
}

/// Check if a specific pattern appears NOT inside a string literal
fn hasPatternNotInString(t: []const u8, pattern: []const u8) bool {
    if (mem.indexOf(u8, t, pattern)) |pos| {
        return !isPatternInString(t, pos);
    }
    return false;
}

/// Check if the caller before .alloc() or .create() is a Type (starts uppercase)
/// Type.alloc() is a factory method, not an allocator call
/// Handles patterns like: Type.alloc(), module.Type.alloc(), Type(T).alloc()
///
/// NOTE: This is CONVENTION-BASED, not language semantics. Zig style guide recommends
/// TitleCase for types, but it's not enforced by the compiler. This heuristic works
/// for code following standard Zig naming conventions.
fn isTypeAllocFactory(t: []const u8, alloc_pos: usize) bool {
    if (alloc_pos == 0) return false;
    var end = alloc_pos;
    // Skip any whitespace before .alloc(
    while (end > 0 and t[end - 1] == ' ') end -= 1;
    // Skip past type parameters like ([]const u8) before .alloc(
    // Pattern: Type(T).alloc() - need to skip the (T) part
    if (end > 0 and t[end - 1] == ')') {
        var paren_depth: usize = 1;
        end -= 1;
        while (end > 0 and paren_depth > 0) {
            end -= 1;
            if (t[end] == ')') paren_depth += 1;
            if (t[end] == '(') paren_depth -= 1;
        }
    }
    // Now find the identifier immediately before (or at position after skipping parens)
    while (end > 0 and (t[end - 1] == '.' or t[end - 1] == ' ')) end -= 1;
    // Walk backwards to find the full identifier chain
    const id_end = end;
    var id_start = end;
    while (id_start > 0 and isIdent(t[id_start - 1])) {
        id_start -= 1;
    }
    if (id_start >= id_end) return false;
    // Check if this identifier starts with uppercase (Type name)
    const first_char = t[id_start];
    return first_char >= 'A' and first_char <= 'Z';
}

/// Check if line has an allocation pattern (.alloc or .create) NOT inside a string
/// Skips Type.alloc() factory methods (uppercase first letter)
fn hasRealAllocPattern(t: []const u8) bool {
    if (mem.indexOf(u8, t, ".alloc(")) |pos| {
        if (!isPatternInString(t, pos) and !isTypeAllocFactory(t, pos)) return true;
    }
    if (mem.indexOf(u8, t, ".create(")) |pos| {
        if (!isPatternInString(t, pos) and !isTypeAllocFactory(t, pos)) return true;
    }
    return false;
}

/// Get position of real allocation pattern (not in string, not Type.alloc()), returns null if not found
fn getRealAllocPos(t: []const u8) ?usize {
    if (mem.indexOf(u8, t, ".alloc(")) |pos| {
        if (!isPatternInString(t, pos) and !isTypeAllocFactory(t, pos)) return pos;
    }
    if (mem.indexOf(u8, t, ".create(")) |pos| {
        if (!isPatternInString(t, pos) and !isTypeAllocFactory(t, pos)) return pos;
    }
    return null;
}

/// Check if this is a real .create( call (not in string)
fn hasRealCreatePattern(t: []const u8) bool {
    if (mem.indexOf(u8, t, ".create(")) |pos| {
        return !isPatternInString(t, pos);
    }
    return false;
}

/// Check if a variable name appears as a LOCAL variable (not a struct field)
/// Returns true if the name appears NOT preceded by '.' (which would be field access)
fn isLocalVarOccurrence(t: []const u8, name: []const u8) bool {
    var search_start: usize = 0;
    while (mem.indexOf(u8, t[search_start..], name)) |rel_pos| {
        const var_pos = search_start + rel_pos;
        search_start = var_pos + name.len;

        // Verify it's a full word match (not part of longer identifier)
        if (var_pos + name.len < t.len and isIdent(t[var_pos + name.len])) continue;
        if (var_pos > 0 and isIdent(t[var_pos - 1])) continue;

        // If preceded by '.', it's a struct field access (self.field) - skip
        if (var_pos > 0 and t[var_pos - 1] == '.') continue;

        // Found a local variable occurrence
        return true;
    }
    return false;
}

/// Check if an identifier appears in text with word boundaries
/// Handles patterns like: pool.free(context, buffer) where we look for "buffer"
fn containsIdentifier(text: []const u8, name: []const u8) bool {
    if (name.len == 0) return false;
    var search_start: usize = 0;
    while (mem.indexOf(u8, text[search_start..], name)) |rel_pos| {
        const pos = search_start + rel_pos;
        search_start = pos + name.len;

        // Check word boundaries
        const at_start = pos == 0 or !isIdent(text[pos - 1]);
        const at_end = pos + name.len >= text.len or !isIdent(text[pos + name.len]);

        if (at_start and at_end) return true;
    }
    return false;
}

/// Check if position is a DIRECT assignment (var = value), not subscript (var[i] = value)
/// For use-after-free: var[i] = value IS a use of var (dereferences it)
fn isDirectAssignment(t: []const u8, name: []const u8, pos: usize) bool {
    if (pos + name.len >= t.len) return false;
    const after = t[pos + name.len ..];
    const trimmed = mem.trimLeft(u8, after, " \t");
    // Only direct assignment: `name = value`
    // NOT subscript: `name[i] = value` (this is a USE of name)
    if (mem.startsWith(u8, trimmed, "==")) return false;
    if (mem.startsWith(u8, trimmed, "[")) return false; // Subscript is a USE
    return mem.startsWith(u8, trimmed, "=");
}

/// Check if position is an assignment target (not a read) - includes subscript
fn isAssignmentTarget(t: []const u8, name: []const u8, pos: usize) bool {
    if (pos + name.len >= t.len) return false;
    const after = t[pos + name.len ..];
    const trimmed = mem.trimLeft(u8, after, " \t");
    if (mem.startsWith(u8, trimmed, "==")) return false;

    // Direct assignment: `name = value`
    if (mem.startsWith(u8, trimmed, "=")) return true;

    // Subscript assignment: `name[i] = value`
    // Need to check if there's an `=` after the closing `]`
    if (mem.startsWith(u8, trimmed, "[")) {
        // Find the closing bracket
        var depth: usize = 0;
        for (trimmed, 0..) |c, i| {
            if (c == '[') depth += 1 else if (c == ']') {
                if (depth > 0) depth -= 1;
                if (depth == 0) {
                    // Found closing bracket, check what follows
                    const after_bracket = mem.trimLeft(u8, trimmed[i + 1 ..], " \t");
                    // Skip additional subscripts
                    if (mem.startsWith(u8, after_bracket, "[")) {
                        // Recurse for multi-dimensional: name[i][j] = value
                        var inner_depth: usize = 0;
                        for (after_bracket, 0..) |ic, ii| {
                            if (ic == '[') inner_depth += 1 else if (ic == ']') {
                                if (inner_depth > 0) inner_depth -= 1;
                                if (inner_depth == 0) {
                                    const final_after = mem.trimLeft(u8, after_bracket[ii + 1 ..], " \t");
                                    if (mem.startsWith(u8, final_after, "==")) return false;
                                    return mem.startsWith(u8, final_after, "=");
                                }
                            }
                        }
                        return false;
                    }
                    // Check if `=` follows (but not `==`)
                    if (mem.startsWith(u8, after_bracket, "==")) return false;
                    return mem.startsWith(u8, after_bracket, "=");
                }
            }
        }
        // No closing bracket found, not an assignment
        return false;
    }

    return false;
}

/// Track assignments to undefined vars
fn trackAssignments(
    t: []const u8,
    undef_vars: *std.StringHashMap(usize),
    def_vars: *std.StringHashMap(void),
) !void {
    var iter = undef_vars.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const pos = mem.indexOf(u8, t, name) orelse continue;
        if (isAssignmentTarget(t, name, pos)) try def_vars.put(name, {});
    }
}

/// Check for reads of undefined vars
fn checkUndefinedReads(
    t: []const u8,
    line: usize,
    undef_vars: *std.StringHashMap(usize),
    def_vars: *std.StringHashMap(void),
    issues: *std.StringHashMap(usize),
) !void {
    var iter = undef_vars.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        if (def_vars.contains(name)) continue;
        if (mem.indexOf(u8, t, name)) |pos| {
            if (!isAssignmentTarget(t, name, pos)) {
                try issues.put(name, line);
            }
        }
    }
}

/// Compute which block a line belongs to
fn findBlockForLine(cfg: *const ControlFlowGraph, line: usize) ?usize {
    for (cfg.blocks.items, 0..) |block, i| {
        if (line >= block.start_line and line <= block.end_line) return i;
    }
    return null;
}

/// Get predecessors of a block
fn getBlockPredecessors(
    cfg: *const ControlFlowGraph,
    block_id: usize,
    allocator: Allocator,
) !std.ArrayListUnmanaged(usize) {
    var preds: std.ArrayListUnmanaged(usize) = .{};
    for (cfg.edges.items) |edge| {
        if (edge.to == block_id) try preds.append(allocator, edge.from);
    }
    return preds;
}

/// Check if a variable has an unconditional fill before any use
/// Returns true if filled before use, false if used first or no fill found
fn hasUnconditionalFillBeforeUse(lines: []const []const u8, start_idx: usize, name: []const u8) bool {
    var nesting_depth: usize = 0;

    for (start_idx..lines.len) |check_idx| {
        const check_line = mem.trim(u8, lines[check_idx], " \t\r");

        // Track conditional nesting (if/else blocks)
        if (mem.startsWith(u8, check_line, "if ") or
            mem.startsWith(u8, check_line, "if(") or
            mem.startsWith(u8, check_line, "else ") or
            mem.startsWith(u8, check_line, "else{"))
        {
            nesting_depth += 1;
        }
        for (check_line) |c| {
            if (c == '}' and nesting_depth > 0) nesting_depth -= 1;
        }

        // Check for unconditional fill (at depth 0, or while/for loops)
        const is_loop = mem.startsWith(u8, check_line, "while ") or
            mem.startsWith(u8, check_line, "for ");
        if (nesting_depth == 0 or is_loop) {
            if (isFillPattern(check_line, name)) return true;
        }

        // Check for use of variable (excluding fills, assignments, declarations)
        if (mem.indexOf(u8, check_line, name)) |pos| {
            const end_pos = pos + name.len;
            const is_word = (pos == 0 or !isIdent(check_line[pos - 1])) and
                (end_pos >= check_line.len or !isIdent(check_line[end_pos]));
            if (is_word) {
                // Skip .len access - it's a type property, not a value read
                const is_len_access = end_pos + 4 <= check_line.len and
                    mem.eql(u8, check_line[end_pos .. end_pos + 4], ".len");

                // Skip if it's a fill, assignment, declaration, or .len access
                if (!is_len_access and
                    !isFillPattern(check_line, name) and
                    !isAssignmentTarget(check_line, name, pos) and
                    !mem.startsWith(u8, check_line, "var ") and
                    !mem.startsWith(u8, check_line, "const "))
                {
                    // This is a USE - if unconditional, it's a use-before-fill
                    if (nesting_depth == 0) return false;
                }
            }
        }

        // Stop at return or function end
        if (mem.startsWith(u8, check_line, "return ")) break;
        if (mem.eql(u8, check_line, "}")) break;
    }
    return false; // No unconditional fill found
}

/// Compute gen set: which blocks assign a variable (includes loop fill patterns)
fn computeGenSetForVar(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    var_name: []const u8,
    num_blocks: usize,
) ![]bool {
    const gen = try allocator.alloc(bool, num_blocks);
    errdefer allocator.free(gen); // Free on error; caller owns on success
    @memset(gen, false);

    // Check for multi-line loop fill pattern: var arr = undefined; for (...) arr[i] = ...
    var in_for_loop = false;
    var for_loop_start_bid: ?usize = null;
    for (lines, 0..) |line, idx| {
        const actual_line = func_line + idx;
        const t = mem.trim(u8, line, " \t\r");

        // Track for-loop scope
        if (mem.startsWith(u8, t, "for ") or mem.startsWith(u8, t, "for(")) {
            in_for_loop = true;
            for_loop_start_bid = findBlockForLine(cfg, actual_line);
        }

        // Check for indexed assignment inside loop: var_name[...] =
        if (in_for_loop) {
            if (mem.indexOf(u8, t, var_name)) |pos| {
                const end_pos = pos + var_name.len;
                if (end_pos < t.len and t[end_pos] == '[') {
                    if (for_loop_start_bid) |bid| gen[bid] = true;
                }
            }
        }

        // Track closing brace for loop
        if (in_for_loop and mem.indexOf(u8, t, "}") != null) {
            var brace_count: i32 = 0;
            for (t) |c| {
                if (c == '{') brace_count += 1;
                if (c == '}') brace_count -= 1;
            }
            if (brace_count < 0) in_for_loop = false;
        }

        if (isAssignmentTarget(t, var_name, 0) or isFillPattern(t, var_name)) {
            if (findBlockForLine(cfg, actual_line)) |bid| gen[bid] = true;
        }
    }
    return gen;
}

/// Collect variables declared with `= undefined`, skipping comptime blocks
/// Returns map of var_name -> declaration line
fn collectUndefinedVars(
    allocator: Allocator,
    lines: []const []const u8,
    func_line: usize,
) !std.StringHashMap(usize) {
    var undef_vars = std.StringHashMap(usize).init(allocator);
    var comptime_depth: usize = 0;
    var comptime_brace_depth: usize = 0;

    for (lines, 0..) |line, idx| {
        const t = mem.trim(u8, line, " \t\r");

        // Track comptime block depth
        if (mem.indexOf(u8, t, "comptime ") != null or mem.indexOf(u8, t, "comptime{") != null) {
            comptime_depth += 1;
            comptime_brace_depth = 0;
            for (t) |c| {
                if (c == '{') comptime_brace_depth += 1;
            }
        }
        if (comptime_depth > 0) {
            for (t) |c| {
                if (c == '{') comptime_brace_depth += 1;
                if (c == '}') {
                    if (comptime_brace_depth > 0) {
                        comptime_brace_depth -= 1;
                        if (comptime_brace_depth == 0 and comptime_depth > 0) {
                            comptime_depth -= 1;
                        }
                    }
                }
            }
            continue; // Skip variables declared inside comptime
        }

        if (mem.indexOf(u8, t, "= undefined")) |col| {
            // Ensure "undefined" is complete token, not part of "undefined_col"
            const after_undefined = col + "= undefined".len;
            if (after_undefined < t.len) {
                const next_char = t[after_undefined];
                if ((next_char >= 'a' and next_char <= 'z') or
                    (next_char >= 'A' and next_char <= 'Z') or
                    (next_char >= '0' and next_char <= '9') or
                    next_char == '_')
                {
                    continue; // Part of longer identifier
                }
            }
            // Skip if this is a struct field being set to undefined, not the variable itself
            // Pattern: .field = undefined (inside a struct literal)
            // The variable IS assigned, just with some undefined fields
            if (isStructFieldUndefined(t, col)) continue;

            if (extractVarDeclName(t)) |name| {
                if (!hasUnconditionalFillBeforeUse(lines, idx + 1, name)) {
                    try undef_vars.put(name, func_line + idx);
                }
            }
        }
    }
    return undef_vars;
}

/// Check if `= undefined` is a struct field assignment, not a variable declaration
/// Zig struct literals: `var x = .{ .field = undefined }` - x IS assigned, field is undefined
/// Pattern: looks for `.identifier = undefined` indicating field, not top-level variable
fn isStructFieldUndefined(t: []const u8, undefined_col: usize) bool {
    // Look backwards from the `=` sign to find if there's a `.identifier` pattern
    // The `= undefined` starts at undefined_col, so the `=` is at undefined_col
    if (undefined_col == 0) return false;

    // Scan backwards from the `=` to find preceding `.identifier` pattern
    var i = undefined_col;
    // Skip whitespace before `=`
    while (i > 0 and (t[i - 1] == ' ' or t[i - 1] == '\t')) i -= 1;
    if (i == 0) return false;

    // Check for identifier characters
    while (i > 0 and isIdent(t[i - 1])) i -= 1;

    // Check for leading `.` (struct field notation)
    if (i > 0 and t[i - 1] == '.') return true;

    return false;
}

/// Run definite assignment analysis on CFG
/// Returns map of variable -> line where potentially uninitialized read occurs
fn analyzeDefiniteAssignment(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
) !std.StringHashMap(usize) {
    var issues = std.StringHashMap(usize).init(allocator);

    // Phase 1: Find all undefined variable declarations (skipping comptime blocks)
    var undef_vars = try collectUndefinedVars(allocator, lines, func_line);
    defer undef_vars.deinit();

    if (undef_vars.count() == 0) return issues;

    // Phase 2: For each undefined var, compute definitely-assigned at each block
    // Using forward data flow: out[B] = gen[B] ∪ in[B], in[B] = ∩ out[pred]
    const num_blocks = cfg.blocks.items.len;
    if (num_blocks == 0) return issues;

    // For each variable, track which blocks have it definitely assigned (bitmap)
    var var_iter = undef_vars.iterator();
    while (var_iter.next()) |entry| {
        const var_name = entry.key_ptr.*;
        const var_line = entry.value_ptr.*;

        // Initialize: all blocks start with var unassigned except after def line
        var def_at_entry = try allocator.alloc(bool, num_blocks);
        defer allocator.free(def_at_entry);
        var def_at_exit = try allocator.alloc(bool, num_blocks);
        defer allocator.free(def_at_exit);
        @memset(def_at_entry, false);
        @memset(def_at_exit, false);

        // Compute gen set: which blocks assign this variable
        const gen = try computeGenSetForVar(allocator, cfg, lines, func_line, var_name, num_blocks);
        defer allocator.free(gen);

        // Worklist algorithm: iterate until fixed point
        // Max iterations = 2 * num_blocks (boolean lattice height * blocks)
        // Use saturating arithmetic to avoid overflow on very large CFGs
        var changed = true;
        var iters: usize = 0;
        const max_iters = @min(num_blocks, std.math.maxInt(usize) / 2 - 1) *| 2 +| 1;
        while (changed and iters < max_iters) : (iters += 1) {
            changed = false;
            for (0..num_blocks) |bid| {
                // in[B] = intersection of out[pred] (must be assigned on ALL paths)
                var preds = try getBlockPredecessors(cfg, bid, allocator);
                defer preds.deinit(allocator);

                var new_in: bool = true;
                if (preds.items.len == 0) {
                    // Entry block: variable starts unassigned
                    new_in = false;
                } else {
                    for (preds.items) |pred| {
                        if (!def_at_exit[pred]) new_in = false;
                    }
                }

                // out[B] = gen[B] ∪ in[B]
                const new_out = gen[bid] or new_in;

                if (def_at_entry[bid] != new_in or def_at_exit[bid] != new_out) {
                    def_at_entry[bid] = new_in;
                    def_at_exit[bid] = new_out;
                    changed = true;
                }
            }
        }

        // Phase 3: Check for reads when variable might be uninitialized
        for (lines, 0..) |line, idx| {
            const actual_line = func_line + idx;
            if (actual_line <= var_line) continue; // Before declaration
            const t = mem.trim(u8, line, " \t\r");
            const bid = findBlockForLine(cfg, actual_line) orelse continue;

            // If var not definitely assigned at this block and is read
            if (!def_at_entry[bid] and !gen[bid]) {
                if (hasVarRead(t, var_name)) {
                    try issues.put(var_name, actual_line);
                    break; // One issue per variable
                }
            }
        }
    }

    return issues;
}

/// Check if line reads a variable (not just assigns)
fn hasVarRead(t: []const u8, var_name: []const u8) bool {
    // Skip comment and multiline string lines entirely
    if (isCommentOrMultilineString(t)) return false;

    var i: usize = 0;
    while (i + var_name.len <= t.len) : (i += 1) {
        if (!mem.eql(u8, t[i .. i + var_name.len], var_name)) continue;
        const end_i = i + var_name.len;
        if (end_i < t.len and isIdent(t[end_i])) continue; // Middle of word
        if (i > 0 and isIdent(t[i - 1])) continue; // Middle of word

        // Skip struct field access - e.g., self.file_id is not the local file_id
        if (i > 0 and t[i - 1] == '.') continue;

        // Skip if inside a comment (after //)
        if (mem.indexOf(u8, t[0..i], "//")) |_| continue;

        // Skip .len access - it's a compile-time property, not a read of undefined values
        // e.g., "arr.len" doesn't read arr's contents
        if (end_i + 4 <= t.len and mem.eql(u8, t[end_i .. end_i + 4], ".len")) continue;

        // Check it's not an assignment target
        if (!isAssignmentTarget(t, var_name, i)) return true;
    }
    return false;
}

// ============================================================================
// CFG-Based Path-Sensitive Memory Analysis (ZA105, ZA106)
// ============================================================================

/// Result of marking defer and errdefer block lines
const DeferBlockMarkers = struct {
    in_defer: []bool,
    in_errdefer: []bool,
};

/// Mark which lines are inside defer and errdefer blocks
fn markDeferAndErrdeferBlocks(allocator: Allocator, lines: []const []const u8) !DeferBlockMarkers {
    var in_errdefer = try allocator.alloc(bool, lines.len);
    errdefer allocator.free(in_errdefer);
    var in_defer = try allocator.alloc(bool, lines.len);
    @memset(in_errdefer, false);
    @memset(in_defer, false);

    var errdefer_depth: usize = 0;
    var defer_depth: usize = 0;
    for (lines, 0..) |line, idx| {
        const t = mem.trim(u8, line, " \t\r");

        // Track errdefer blocks
        if (mem.startsWith(u8, t, "errdefer ") or mem.startsWith(u8, t, "errdefer{")) {
            errdefer_depth += 1;
            var braces: i32 = 0;
            for (t) |c| {
                if (c == '{') braces += 1;
                if (c == '}') braces -= 1;
            }
            if (braces == 0 and errdefer_depth > 0) errdefer_depth -= 1;
            in_errdefer[idx] = true;
            continue;
        }
        if (errdefer_depth > 0) {
            in_errdefer[idx] = true;
            for (t) |c| {
                if (c == '{') errdefer_depth += 1;
                if (c == '}' and errdefer_depth > 0) errdefer_depth -= 1;
            }
        }

        // Track regular defer blocks (multi-line only)
        if (mem.startsWith(u8, t, "defer {") or mem.startsWith(u8, t, "defer{")) {
            in_defer[idx] = true;
            for (t) |c| {
                if (c == '{') defer_depth += 1;
                if (c == '}' and defer_depth > 0) defer_depth -= 1;
            }
            continue;
        }
        if (defer_depth > 0) {
            in_defer[idx] = true;
            for (t) |c| {
                if (c == '{') defer_depth += 1;
                if (c == '}' and defer_depth > 0) defer_depth -= 1;
            }
        }
    }
    return .{ .in_defer = in_defer, .in_errdefer = in_errdefer };
}

/// Analyze memory states through CFG for path-sensitive use-after-free and double-free
/// This properly handles patterns like: catch { free(x); return; }
/// where the free only occurs on the early-return path, not the main path
fn analyzeCFGMemorySafety(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};

    // Phase 1: Identify all allocations in the function
    var allocs = std.StringHashMap(CFGAllocation).init(allocator);
    defer allocs.deinit();

    for (lines, 0..) |line, idx| {
        const actual_line = func_line + idx;
        const t = mem.trim(u8, line, " \t\r");

        // Detect allocations: const x = ... .alloc( or .create( (skip patterns in strings)
        if (hasRealAllocPattern(t)) {
            if (extractVarDeclName(t)) |name| {
                const col = getRealAllocPos(t) orelse 0;
                try allocs.put(name, .{
                    .name = name,
                    .alloc_line = actual_line,
                    .alloc_col = col + 1,
                    .state = .allocated,
                    .is_create = hasRealCreatePattern(t),
                });
            }
        }
    }

    if (allocs.count() == 0) return issues;

    const num_blocks = cfg.blocks.items.len;
    if (num_blocks == 0) return issues;

    // Pre-pass: Mark which lines are inside errdefer or defer blocks
    const markers = try markDeferAndErrdeferBlocks(allocator, lines);
    const in_defer = markers.in_defer;
    const in_errdefer = markers.in_errdefer;
    defer allocator.free(in_defer);
    defer allocator.free(in_errdefer);

    // Phase 2: For each allocation, track freed state through CFG
    var alloc_iter = allocs.iterator();
    while (alloc_iter.next()) |entry| {
        const alloc = entry.value_ptr;
        const var_name = alloc.name;

        // Track state per block: freed, has_return_after_free
        var freed_in_block = try allocator.alloc(bool, num_blocks);
        defer allocator.free(freed_in_block);
        var block_returns_after_free = try allocator.alloc(bool, num_blocks);
        defer allocator.free(block_returns_after_free);
        var freed_line_in_block = try allocator.alloc(usize, num_blocks);
        defer allocator.free(freed_line_in_block);
        @memset(freed_in_block, false);
        @memset(block_returns_after_free, false);
        @memset(freed_line_in_block, 0);

        // Scan each block for free operations
        for (cfg.blocks.items, 0..) |block, bid| {
            var free_seen = false;
            var return_after_free = false;
            var free_line: usize = 0;

            // Skip blocks with invalid line ranges
            if (block.start_line == 0 or block.start_line > block.end_line) continue;

            for (block.start_line..block.end_line + 1) |line_num| {
                if (line_num < func_line) continue;
                const idx = line_num - func_line;
                if (idx >= lines.len) continue;
                const t = mem.trim(u8, lines[idx], " \t\r");

                // Skip lines inside errdefer blocks (frees only run on error path)
                if (in_errdefer[idx]) continue;

                // Skip lines inside defer blocks (frees happen at scope exit, not here)
                // This prevents false use-after-free when code uses var before defer scope ends
                if (in_defer[idx]) continue;

                // Skip single-line defer - tracked separately
                if (mem.startsWith(u8, t, "defer ")) continue;

                // Check if this free is for our local variable (not a struct field)
                // Skip patterns inside string literals (e.g., searching for ".free(")
                if (hasRealFreePattern(t) and isLocalVarOccurrence(t, var_name)) {
                    free_seen = true;
                    free_line = line_num;
                }

                if (free_seen and mem.startsWith(u8, t, "return")) {
                    return_after_free = true;
                }
            }

            freed_in_block[bid] = free_seen;
            freed_line_in_block[bid] = free_line;
            block_returns_after_free[bid] = return_after_free;
            if (free_seen and alloc.freed_line == 0) {
                alloc.freed_line = free_line;
            }
        }

        // Phase 3: Detect use-after-free with path-sensitivity
        // Key insight: if free is in a block with return, subsequent blocks
        // are NOT reached via that path - free doesn't affect them
        for (lines, 0..) |line, idx| {
            const actual_line = func_line + idx;
            const t = mem.trim(u8, line, " \t\r");

            // Skip UAF detection inside errdefer - it's cleanup code
            // (uses pre-computed in_errdefer[] from markDeferAndErrdeferBlocks)
            if (in_errdefer[idx]) continue;

            // Skip: declarations, frees, defers, comments
            if (mem.startsWith(u8, t, "const ") or mem.startsWith(u8, t, "var ")) continue;
            if (hasRealFreePattern(t)) continue; // Skip patterns in string literals
            if (mem.startsWith(u8, t, "defer")) continue;
            if (isCommentOrMultilineString(t)) continue;

            // Check ALL occurrences of the variable on this line
            // Pattern: `data = transformData(data)` has UAF on RHS even though LHS is assignment
            var has_use = false;
            var use_col: usize = 0;
            var search_start: usize = 0;
            while (mem.indexOf(u8, t[search_start..], var_name)) |rel_pos| {
                const var_pos = search_start + rel_pos;
                search_start = var_pos + var_name.len;

                // Verify it's a full word match
                if (var_pos + var_name.len < t.len and isIdent(t[var_pos + var_name.len])) continue;
                if (var_pos > 0 and isIdent(t[var_pos - 1])) continue;

                // Skip struct field access (self.field) - not a local variable use
                if (var_pos > 0 and t[var_pos - 1] == '.') continue;

                // Skip if inside a string literal
                if (isInsideString(t, var_pos)) continue;

                // Skip if this occurrence is a DIRECT reassignment target (LHS of =)
                // BUT: If it appears elsewhere on the line, that's a USE
                if (isDirectAssignment(t, var_name, var_pos)) continue;

                // This occurrence is a USE (not assignment, not in string)
                has_use = true;
                use_col = var_pos;
                break;
            }
            if (!has_use) continue;

            const bid = findBlockForLine(cfg, actual_line) orelse continue;

            // Check if freed earlier in same block (without intervening return)
            var freed_same_block = false;
            var intervening_return = false;
            const block_start = cfg.blocks.items[bid].start_line;
            if (block_start == 0 or block_start > actual_line) continue;
            for (block_start..actual_line) |check_line| {
                if (check_line < func_line) continue;
                const check_idx = check_line - func_line;
                if (check_idx >= lines.len) continue;
                const check_t = mem.trim(u8, lines[check_idx], " \t\r");

                // Skip lines inside errdefer blocks (frees only run on error path)
                if (in_errdefer[check_idx]) continue;

                // Skip lines inside defer blocks (frees happen at scope exit, not here)
                if (in_defer[check_idx]) continue;

                // Skip single-line defer - tracked separately
                if (mem.startsWith(u8, check_t, "defer ")) continue;

                const check_free = hasRealFreePattern(check_t);
                // Only count frees of local variables (not struct fields)
                if (check_free and isLocalVarOccurrence(check_t, var_name)) {
                    freed_same_block = true;
                    alloc.freed_line = check_line;
                }
                if (freed_same_block and mem.startsWith(u8, check_t, "return")) {
                    intervening_return = true;
                }
            }

            // Use-after-free in same block (no return between)
            if (freed_same_block and !intervening_return) {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "use-after-free: '{s}' freed on {d}",
                    .{ var_name, alloc.freed_line },
                );
                try issues.append(allocator, .{
                    .file = file_path,
                    .line = actual_line,
                    .col = use_col + 1,
                    .severity = .err,
                    .rule = RULE_USE_AFTER_FREE,
                    .message = msg,
                    .message_owned = true,
                    .help = "don't access freed memory",
                });
                continue;
            }

            // Check if freed in ALL predecessor paths (excluding early-return paths)
            var preds = try getBlockPredecessors(cfg, bid, allocator);
            defer preds.deinit(allocator);

            if (preds.items.len == 0) continue; // Entry block - can't have been freed

            var definitely_freed = true;
            var any_normal_pred = false;
            for (preds.items) |pred| {
                // Early-return path: block frees then returns - doesn't reach us
                if (block_returns_after_free[pred]) continue;
                any_normal_pred = true;
                if (!freed_in_block[pred]) {
                    definitely_freed = false;
                }
            }

            // Only report if freed on all normal (non-returning) paths
            if (any_normal_pred and definitely_freed and alloc.freed_line > 0) {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "use-after-free: '{s}' freed on {d}",
                    .{ var_name, alloc.freed_line },
                );
                try issues.append(allocator, .{
                    .file = file_path,
                    .line = actual_line,
                    .col = use_col + 1,
                    .severity = .err,
                    .rule = RULE_USE_AFTER_FREE,
                    .message = msg,
                    .message_owned = true,
                    .help = "don't access freed memory",
                });
            }
        }

        // Phase 4: Detect double-free with path-sensitivity
        for (lines, 0..) |line, idx| {
            const actual_line = func_line + idx;
            const t = mem.trim(u8, line, " \t\r");

            // Skip defer/errdefer - they don't free immediately
            if (mem.startsWith(u8, t, "defer ") or mem.startsWith(u8, t, "errdefer ")) continue;

            // Only look at free operations (skip patterns in string literals)
            if (!hasRealFreePattern(t)) continue;
            if (mem.indexOf(u8, t, var_name) == null) continue;

            const bid = findBlockForLine(cfg, actual_line) orelse continue;

            // Check if already freed in same block before this line
            var prev_free_in_block = false;
            const block_start_df = cfg.blocks.items[bid].start_line;
            if (block_start_df == 0 or block_start_df > actual_line) continue;
            for (block_start_df..actual_line) |check_line| {
                if (check_line < func_line) continue;
                const check_idx = check_line - func_line;
                if (check_idx >= lines.len) continue;
                const check_t = mem.trim(u8, lines[check_idx], " \t\r");

                // Skip lines inside errdefer blocks (frees only run on error path)
                if (in_errdefer[check_idx]) continue;

                // Skip lines inside defer blocks (frees happen at scope exit, not here)
                if (in_defer[check_idx]) continue;

                // Skip single-line defer - tracked separately
                if (mem.startsWith(u8, check_t, "defer ")) continue;

                const check_free = hasRealFreePattern(check_t);
                // Only count frees of local variables (not struct fields)
                if (check_free and isLocalVarOccurrence(check_t, var_name)) {
                    prev_free_in_block = true;
                    alloc.freed_line = check_line;
                    break;
                }
            }

            if (prev_free_in_block) {
                // Check if there's a switch arm or mutually exclusive branch between the two frees
                // If so, they're in different branches (not a real double-free)
                var has_exclusive_branch = false;
                if (alloc.freed_line < actual_line) {
                    for (alloc.freed_line + 1..actual_line) |between_line| {
                        if (between_line < func_line) continue;
                        const between_idx = between_line - func_line;
                        if (between_idx >= lines.len) continue;
                        const between_t = mem.trim(u8, lines[between_idx], " \t\r");
                        // Switch arm patterns: "=> blk:", "=> {", ".X =>"
                        if (mem.indexOf(u8, between_t, "=>") != null) {
                            has_exclusive_branch = true;
                            break;
                        }
                        // catch/orelse pattern: "} orelse {" - mutually exclusive branches
                        // Pattern: catch { ... return; } orelse { ... return; }
                        if (mem.indexOf(u8, between_t, "} orelse {") != null or
                            mem.indexOf(u8, between_t, "} orelse return") != null or
                            mem.startsWith(u8, between_t, "orelse {") or
                            mem.eql(u8, between_t, "} orelse {"))
                        {
                            has_exclusive_branch = true;
                            break;
                        }
                        // else branch pattern: "} else {"
                        if (mem.indexOf(u8, between_t, "} else {") != null or
                            mem.eql(u8, between_t, "} else {"))
                        {
                            has_exclusive_branch = true;
                            break;
                        }
                    }
                }
                if (has_exclusive_branch) continue;

                const col = mem.indexOf(u8, t, ".free(") orelse
                    mem.indexOf(u8, t, ".destroy(") orelse 0;
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "double-free: '{s}' freed on {d}",
                    .{ var_name, alloc.freed_line },
                );
                try issues.append(allocator, .{
                    .file = file_path,
                    .line = actual_line,
                    .col = col + 1,
                    .severity = .err,
                    .rule = RULE_DOUBLE_FREE,
                    .message = msg,
                    .message_owned = true,
                    .help = "remove duplicate free",
                });
                continue;
            }

            // Check predecessors (excluding early-return paths)
            var preds = try getBlockPredecessors(cfg, bid, allocator);
            defer preds.deinit(allocator);

            if (preds.items.len == 0) continue;

            var definitely_freed = true;
            var any_freed = false;
            var any_normal_pred = false;
            var freed_pred_line: usize = 0;
            for (preds.items) |pred| {
                if (block_returns_after_free[pred]) continue;
                any_normal_pred = true;
                if (freed_in_block[pred]) {
                    any_freed = true;
                    if (freed_line_in_block[pred] > freed_pred_line) {
                        freed_pred_line = freed_line_in_block[pred];
                    }
                } else {
                    definitely_freed = false;
                }
            }

            // Skip if no predecessors freed (first free is ok)
            if (!any_freed) continue;

            // Check if there's a switch arm or mutually exclusive branch between the two frees
            // If so, they're in different branches (not a real double-free)
            var has_exclusive_branch_2 = false;
            const check_from_line = if (freed_pred_line > 0) freed_pred_line else alloc.freed_line;
            if (check_from_line > 0 and check_from_line < actual_line) {
                for (check_from_line + 1..actual_line) |between_line| {
                    if (between_line < func_line) continue;
                    const between_idx = between_line - func_line;
                    if (between_idx >= lines.len) continue;
                    const between_t = mem.trim(u8, lines[between_idx], " \t\r");
                    // Switch arm patterns
                    if (mem.indexOf(u8, between_t, "=>") != null) {
                        has_exclusive_branch_2 = true;
                        break;
                    }
                    // catch/orelse pattern - mutually exclusive branches
                    if (mem.indexOf(u8, between_t, "} orelse {") != null or
                        mem.indexOf(u8, between_t, "} orelse return") != null or
                        mem.startsWith(u8, between_t, "orelse {") or
                        mem.eql(u8, between_t, "} orelse {"))
                    {
                        has_exclusive_branch_2 = true;
                        break;
                    }
                    // else branch pattern
                    if (mem.indexOf(u8, between_t, "} else {") != null or
                        mem.eql(u8, between_t, "} else {"))
                    {
                        has_exclusive_branch_2 = true;
                        break;
                    }
                }
            }
            if (has_exclusive_branch_2) continue;

            const col = mem.indexOf(u8, t, ".free(") orelse
                mem.indexOf(u8, t, ".destroy(") orelse 0;

            // Definite double-free: all paths freed
            if (any_normal_pred and definitely_freed) {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "double-free: '{s}' freed on {d}",
                    .{ var_name, if (freed_pred_line > 0) freed_pred_line else alloc.freed_line },
                );
                try issues.append(allocator, .{
                    .file = file_path,
                    .line = actual_line,
                    .col = col + 1,
                    .severity = .err,
                    .rule = RULE_DOUBLE_FREE,
                    .message = msg,
                    .message_owned = true,
                    .help = "remove duplicate free",
                });
            } else if (any_normal_pred and any_freed and !definitely_freed) {
                // Conditional double-free: some paths freed, some didn't
                // This is a potential double-free if the branch that freed is taken
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "conditional double-free: '{s}' may be freed on {d}",
                    .{ var_name, if (freed_pred_line > 0) freed_pred_line else alloc.freed_line },
                );
                try issues.append(allocator, .{
                    .file = file_path,
                    .line = actual_line,
                    .col = col + 1,
                    .severity = .warning,
                    .rule = RULE_DOUBLE_FREE,
                    .message = msg,
                    .message_owned = true,
                    .help = "move free outside conditional or ensure only one path frees",
                });
            }
        }
    }

    return issues;
}

// ============================================================================
// CFG Defer Coverage Analysis Helpers
// ============================================================================

/// Allocation info for CFG-based defer analysis
const CFGAlloc = struct {
    name: []const u8,
    line: usize,
    col: usize,
    block: usize,
    is_create: bool,
};

/// Check if function has arena parameter (first few lines)
fn hasArenaParameter(lines: []const []const u8) bool {
    for (lines[0..@min(5, lines.len)]) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (mem.indexOf(u8, t, "arena:") != null or
            mem.indexOf(u8, t, "arena :") != null)
        {
            return true;
        }
    }
    return false;
}

/// Collect allocations from function lines for CFG analysis
fn collectCFGAllocations(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
) !std.ArrayListUnmanaged(CFGAlloc) {
    var allocs = std.ArrayListUnmanaged(CFGAlloc){};

    for (lines, 0..) |line, idx| {
        const actual_line = func_line + idx;
        const t = mem.trim(u8, line, " \t\r");

        // Detect allocations (skip patterns inside string literals)
        if (!hasRealAllocPattern(t)) continue;

        // Skip no-free allocators (arena, scratch, temp, frame, fba, recycle)
        if (hasNoFreeAllocatorPattern(t)) continue;

        const name = extractVarDeclName(t) orelse continue;
        const col = getRealAllocPos(t) orelse 0;
        const block = findBlockForLine(cfg, actual_line) orelse continue;

        try allocs.append(allocator, .{
            .name = name,
            .line = actual_line,
            .col = col + 1,
            .block = block,
            .is_create = hasRealCreatePattern(t),
        });
    }

    return allocs;
}

/// Check for immediate defer after multi-line allocations
/// Returns true if allocation should be removed (has immediate defer)
fn hasImmediateDefer(
    alloc: *CFGAlloc,
    lines: []const []const u8,
    func_line: usize,
) bool {
    const alloc_idx = alloc.line - func_line;
    if (alloc_idx >= lines.len) return false;

    // Get indentation of allocation line
    const alloc_line = lines[alloc_idx];
    const alloc_indent = countIndent(alloc_line);

    // Find where the allocation statement ends (may span multiple lines)
    var alloc_end_idx = alloc_idx;
    var brace_depth: i32 = 0;
    for (alloc_idx..lines.len) |idx| {
        const scan_line = mem.trim(u8, lines[idx], " \t\r");
        for (scan_line) |c| {
            if (c == '{' or c == '(') brace_depth += 1;
            if (c == '}' or c == ')') brace_depth -= 1;
        }
        // Allocation ends when we see semicolon at brace depth 0 (or negative)
        if (mem.indexOf(u8, scan_line, ";") != null and brace_depth <= 0) {
            alloc_end_idx = idx;
            break;
        }
    }

    // Check the line immediately after allocation for a defer
    const defer_idx = alloc_end_idx + 1;
    if (defer_idx >= lines.len) return false;

    const raw_line = lines[defer_idx];
    const scan_line = mem.trim(u8, raw_line, " \t\r");

    // Must be a defer statement
    if (!mem.startsWith(u8, scan_line, "defer ")) return false;

    // Check indentation matches - defer must be at same level as alloc
    const defer_indent = countIndent(raw_line);
    if (defer_indent != alloc_indent) return false;

    // Check if it frees this allocation (skip patterns in string literals)
    const has_free = hasRealCleanupPattern(scan_line);
    return has_free and mem.indexOf(u8, scan_line, alloc.name) != null;
}

/// Remove allocations that have immediate defer (marked with line = 0)
fn removeImmediateDeferAllocs(
    allocs: *std.ArrayListUnmanaged(CFGAlloc),
    lines: []const []const u8,
    func_line: usize,
) void {
    // First pass: mark allocations with immediate defer
    for (allocs.items) |*alloc| {
        if (hasImmediateDefer(alloc, lines, func_line)) {
            alloc.line = 0; // Mark for removal
        }
    }

    // Second pass: remove marked allocations
    var i: usize = 0;
    while (i < allocs.items.len) {
        if (allocs.items[i].line == 0) {
            _ = allocs.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

/// Track owner variables through data flow
/// Pattern: const x = Type{ .field = alloc_name } -> x is an owner
const OwnerVar = struct { name: []const u8 };

/// Add a new owner if not already tracked
fn tryAddOwner(allocator: Allocator, owner_vars: *std.ArrayListUnmanaged(OwnerVar), name: []const u8) !void {
    for (owner_vars.items) |ov| {
        if (mem.eql(u8, ov.name, name)) return;
    }
    try owner_vars.append(allocator, .{ .name = name });
}

/// Check if any owner var appears in line
fn hasOwnerAppearance(owner_vars: []const OwnerVar, t: []const u8) bool {
    for (owner_vars) |ov| {
        if (mem.indexOf(u8, t, ov.name) != null) return true;
    }
    return false;
}

fn trackOwnerVariables(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    alloc_name: []const u8,
) !std.ArrayListUnmanaged(OwnerVar) {
    var owner_vars = std.ArrayListUnmanaged(OwnerVar){};
    try owner_vars.append(allocator, .{ .name = alloc_name });

    for (cfg.blocks.items) |block| {
        if (block.start_line == 0 or block.start_line > block.end_line) continue;

        for (block.start_line..block.end_line + 1) |line_num| {
            if (line_num < func_line) continue;
            const idx = line_num - func_line;
            if (idx >= lines.len) continue;
            const t = mem.trim(u8, lines[idx], " \t\r");

            if (!hasOwnerAppearance(owner_vars.items, t)) continue;

            // Pattern: const varname = Type{ ... owner_var ... }
            if (mem.startsWith(u8, t, "const ") and mem.indexOf(u8, t, "{") != null) {
                var end: usize = 6;
                while (end < t.len and isIdent(t[end])) end += 1;
                if (end > 6) try tryAddOwner(allocator, &owner_vars, t[6..end]);
            }

            // Pattern: varname.* = Type{ ... owner_var ... }
            if (mem.indexOf(u8, t, ".* = ") != null and mem.indexOf(u8, t, "{") != null) {
                var end: usize = 0;
                while (end < t.len and isIdent(t[end])) end += 1;
                if (end > 0) try tryAddOwner(allocator, &owner_vars, t[0..end]);
            }
        }
    }

    return owner_vars;
}

/// Check if ownership is transferred in a line using owner variables
fn checkOwnershipInLine(
    t: []const u8,
    owner_vars: []const OwnerVar,
) bool {
    for (owner_vars) |ov| {
        if (mem.indexOf(u8, t, ov.name) == null) continue;

        // Direct return of owner variable
        if (mem.startsWith(u8, t, "return ")) return true;

        // Stored in self or ctx field
        if (mem.indexOf(u8, t, "self.") != null or
            mem.indexOf(u8, t, "ctx.") != null)
        {
            return true;
        }

        // Module-level variable assignment
        if (mem.indexOf(u8, t, " = ") != null and
            !mem.startsWith(u8, t, "const ") and
            !mem.startsWith(u8, t, "var "))
        {
            const eq_pos = mem.indexOf(u8, t, " = ").?;
            const lhs = mem.trim(u8, t[0..eq_pos], " \t");
            if (lhs.len > 0 and mem.indexOf(u8, lhs, ".") == null) {
                return true;
            }
        }
    }
    return false;
}

/// CFG-based defer coverage analysis (ZA101/ZA102)
/// Detects allocations where defer only exists on some paths
fn analyzeCFGDeferCoverage(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};

    // Skip arena-based functions (no defer needed)
    if (hasArenaParameter(lines)) return issues;

    // Phase 1: Collect allocations
    var allocs = try collectCFGAllocations(allocator, cfg, lines, func_line);
    defer allocs.deinit(allocator);
    if (allocs.items.len == 0) return issues;

    // Pre-pass: Remove allocations with immediate defer
    removeImmediateDeferAllocs(&allocs, lines, func_line);
    if (allocs.items.len == 0) return issues;

    const num_blocks = cfg.blocks.items.len;
    if (num_blocks == 0) return issues;

    // Phase 2-3: Check defer coverage for each allocation
    for (allocs.items) |alloc| {
        const issue = try checkDeferCoverageForAlloc(
            allocator,
            cfg,
            lines,
            func_line,
            file_path,
            alloc,
            num_blocks,
        );
        if (issue) |iss| {
            try issues.append(allocator, iss);
        }
    }

    return issues;
}

/// Block coverage state for defer analysis
const BlockCoverageState = struct {
    has_defer: []bool,
    ownership_transferred: []bool,
    free_and_return: []bool,

    fn deinit(self: *BlockCoverageState, allocator: Allocator) void {
        allocator.free(self.has_defer);
        allocator.free(self.ownership_transferred);
        allocator.free(self.free_and_return);
    }

    fn isBlockCovered(self: BlockCoverageState, bid: usize) bool {
        return self.has_defer[bid] or self.ownership_transferred[bid] or self.free_and_return[bid];
    }

    fn anyDeferExists(self: BlockCoverageState) bool {
        for (self.has_defer) |has| {
            if (has) return true;
        }
        return false;
    }
};

/// Scan CFG blocks for defer, free, and ownership patterns
fn scanBlocksForPatterns(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    alloc_name: []const u8,
    owner_vars: []const OwnerVar,
    num_blocks: usize,
) !BlockCoverageState {
    var state = BlockCoverageState{
        .has_defer = try allocator.alloc(bool, num_blocks),
        .ownership_transferred = try allocator.alloc(bool, num_blocks),
        .free_and_return = try allocator.alloc(bool, num_blocks),
    };
    @memset(state.has_defer, false);
    @memset(state.ownership_transferred, false);
    @memset(state.free_and_return, false);

    for (cfg.blocks.items, 0..) |block, bid| {
        if (block.start_line == 0 or block.start_line > block.end_line) continue;

        var freed = false;
        var return_after = false;

        for (block.start_line..block.end_line + 1) |line_num| {
            if (line_num < func_line) continue;
            const idx = line_num - func_line;
            if (idx >= lines.len) continue;
            const t = mem.trim(u8, lines[idx], " \t\r");

            if (mem.startsWith(u8, t, "defer ")) {
                if (hasRealFreePattern(t) and mem.indexOf(u8, t, alloc_name) != null) {
                    state.has_defer[bid] = true;
                }
            }

            if (!mem.startsWith(u8, t, "defer ") and !mem.startsWith(u8, t, "errdefer ")) {
                if (hasRealFreePattern(t) and mem.indexOf(u8, t, alloc_name) != null) {
                    freed = true;
                }
            }

            if (freed and mem.startsWith(u8, t, "return")) {
                return_after = true;
            }

            if (checkOwnershipInLine(t, owner_vars)) {
                state.ownership_transferred[bid] = true;
            }
        }

        if (freed and return_after) {
            state.free_and_return[bid] = true;
        }
    }

    return state;
}

/// Propagate coverage backward through CFG
fn propagateCoverageBackward(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    state: BlockCoverageState,
    num_blocks: usize,
) ![]bool {
    var covered = try allocator.alloc(bool, num_blocks);
    @memset(covered, false);

    // Initialize from state
    for (0..num_blocks) |bid| {
        if (state.isBlockCovered(bid)) {
            covered[bid] = true;
        }
    }

    // Propagate backwards
    var changed = true;
    var iters: usize = 0;
    const max_iters = num_blocks * 2 + 1;
    while (changed and iters < max_iters) : (iters += 1) {
        changed = false;
        for (0..num_blocks) |bid| {
            if (covered[bid]) continue;

            var all_succs_covered = true;
            var has_succ = false;
            for (cfg.edges.items) |edge| {
                if (edge.from != bid) continue;
                has_succ = true;
                if (!covered[edge.to]) {
                    all_succs_covered = false;
                    break;
                }
            }

            if (!has_succ) {
                var is_exit = false;
                for (cfg.exit_blocks.items) |exit_bid| {
                    if (exit_bid == bid) {
                        is_exit = true;
                        break;
                    }
                }
                if (is_exit) continue;
            }

            if (has_succ and all_succs_covered) {
                covered[bid] = true;
                changed = true;
            }
        }
    }

    return covered;
}

/// Check defer coverage for a single allocation using CFG dataflow
fn checkDeferCoverageForAlloc(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
    alloc: CFGAlloc,
    num_blocks: usize,
) !?Issue {
    // Track owner variables through data flow
    var owner_vars = try trackOwnerVariables(allocator, cfg, lines, func_line, alloc.name);
    defer owner_vars.deinit(allocator);

    // Scan blocks for patterns
    var state = try scanBlocksForPatterns(
        allocator,
        cfg,
        lines,
        func_line,
        alloc.name,
        owner_vars.items,
        num_blocks,
    );
    defer state.deinit(allocator);

    // Propagate coverage
    const covered = try propagateCoverageBackward(allocator, cfg, state, num_blocks);
    defer allocator.free(covered);

    // Check result
    const alloc_block_covered = covered[alloc.block];
    const any_defer = state.anyDeferExists();

    if (!alloc_block_covered and !any_defer) {
        return null; // Let analyzeFunction handle no-defer-at-all case
    }

    if (!alloc_block_covered and any_defer) {
        const rule = if (alloc.is_create) RULE_CREATE_NO_DEFER else RULE_ALLOC_NO_DEFER;
        const msg = if (alloc.is_create)
            "defer destroy() not on all code paths"
        else
            "defer free() not on all code paths";

        return Issue{
            .file = file_path,
            .line = alloc.line,
            .col = alloc.col,
            .severity = .warning,
            .rule = rule,
            .message = msg,
            .help = "move defer to outer scope or add defer on all branches",
        };
    }

    return null;
}

// ============================================================================
// CFG Errdefer Coverage Analysis Helpers
// ============================================================================

/// Allocation info for errdefer analysis
const TryAlloc = struct {
    name: []const u8,
    line: usize,
    col: usize,
    has_errdefer: bool = false,
    is_create: bool,
};

/// Errdefer/defer statement info
const ErrdeferInfo = struct {
    line: usize,
    content: []const u8,
};

/// Check if function uses arena allocator (skip errdefer analysis)
fn usesArenaAllocator(lines: []const []const u8) bool {
    for (lines) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (mem.indexOf(u8, t, "ArenaAllocator.init") != null) return true;
        if (mem.indexOf(u8, t, "arena.deinit()") != null) return true;
        if (mem.indexOf(u8, t, "arena.allocator()") != null) return true;
    }
    return false;
}

/// Check if line contains a try allocation (not in no-free allocator)
fn isTryAllocation(t: []const u8) bool {
    const has_try = mem.indexOf(u8, t, "try ") != null;
    const has_alloc = hasPatternNotInString(t, ".alloc(");
    const has_create = hasPatternNotInString(t, ".create(") and isAllocatorCreate(t);

    if (!has_try or !(has_alloc or has_create)) return false;
    if (!mem.startsWith(u8, t, "const ") and !mem.startsWith(u8, t, "var ")) return false;

    // Skip no-free allocators
    if (hasNoFreeAllocatorPattern(t)) return false;

    return true;
}

/// Check ownership transfer for errdefer analysis
fn checkErrdeferOwnershipTransfer(
    alloc: *TryAlloc,
    lines: []const []const u8,
    func_line: usize,
) void {
    const alloc_idx = alloc.line - func_line;
    if (alloc_idx >= lines.len) return;

    for (lines[alloc_idx..]) |line| {
        const lt = mem.trim(u8, line, " \t\r");
        // Check for break :label ownership transfer
        if (mem.indexOf(u8, lt, "break :") != null and containsIdentifier(lt, alloc.name)) {
            alloc.has_errdefer = true;
            return;
        }
        // Check other ownership transfer patterns
        if (isOwnershipTransfer(lt, alloc.name)) {
            alloc.has_errdefer = true;
            return;
        }
        // Check for struct field storage (self.field = alloc_name)
        if (isStructFieldStorage(lt, alloc.name)) {
            alloc.has_errdefer = true;
            return;
        }
    }
}

/// CFG-based errdefer coverage analysis (ZA103)
/// Detects allocations where errdefer is missing before subsequent try statements
/// Pattern: const data = try alloc(); // MISSING errdefer
///          const more = try alloc(); // If this fails, data leaks
fn analyzeCFGErrdeferCoverage(
    allocator: Allocator,
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
    fn_returns_error: bool,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};

    // Early exit conditions
    if (!fn_returns_error) return issues;
    if (usesArenaAllocator(lines)) return issues;

    // Collect allocations, errdefers, and try statements
    var try_allocs = std.ArrayListUnmanaged(TryAlloc){};
    defer try_allocs.deinit(allocator);

    var errdefers = std.ArrayListUnmanaged(ErrdeferInfo){};
    defer errdefers.deinit(allocator);

    var try_lines_list = std.ArrayListUnmanaged(usize){};
    defer try_lines_list.deinit(allocator);

    // Multi-line block tracking state
    var block_depth: usize = 0;
    var block_start: usize = 0;
    var block_content = std.ArrayListUnmanaged(u8){};
    defer block_content.deinit(allocator);

    // Single pass to collect all information
    for (lines, 0..) |line, idx| {
        const actual_line = func_line + idx;
        const t = mem.trim(u8, line, " \t\r");

        if (isCommentOrMultilineString(t)) continue;

        // Handle multi-line errdefer/defer blocks
        if (block_depth > 0) {
            try block_content.appendSlice(allocator, t);
            try block_content.append(allocator, ' ');
            for (t) |c| {
                if (c == '{') block_depth += 1;
                if (c == '}') {
                    if (block_depth > 0) block_depth -= 1;
                    if (block_depth == 0) {
                        if (hasRealCleanupPattern(block_content.items)) {
                            try errdefers.append(allocator, .{
                                .line = block_start,
                                .content = try allocator.dupe(u8, block_content.items),
                            });
                        }
                        block_content.clearRetainingCapacity();
                    }
                }
            }
            continue;
        }

        // Collect try allocations
        const has_try = mem.indexOf(u8, t, "try ") != null;
        if (has_try and isTryAllocation(t)) {
            if (extractVarDeclName(t)) |name| {
                try try_allocs.append(allocator, .{
                    .name = name,
                    .line = actual_line,
                    .col = (getRealAllocPos(t) orelse 0) + 1,
                    .is_create = hasRealCreatePattern(t),
                });
            }
        }

        // Collect errdefer/defer statements
        const is_errdefer = mem.startsWith(u8, t, "errdefer ");
        const is_defer = mem.startsWith(u8, t, "defer ");
        if (is_errdefer or is_defer) {
            const prefix_len: usize = if (is_errdefer) 9 else 6;
            const content = if (prefix_len < t.len) t[prefix_len..] else "";

            if (mem.startsWith(u8, content, "{")) {
                block_start = actual_line;
                block_depth = 1;
                block_content.clearRetainingCapacity();
                try block_content.appendSlice(allocator, content);
                try block_content.append(allocator, ' ');
                for (content[1..]) |c| {
                    if (c == '{') block_depth += 1;
                    if (c == '}' and block_depth > 0) block_depth -= 1;
                }
                if (block_depth == 0) {
                    if (hasRealCleanupPattern(block_content.items)) {
                        try errdefers.append(allocator, .{
                            .line = actual_line,
                            .content = try allocator.dupe(u8, block_content.items),
                        });
                    }
                    block_content.clearRetainingCapacity();
                }
            } else if (hasRealCleanupPattern(t)) {
                try errdefers.append(allocator, .{
                    .line = actual_line,
                    .content = content,
                });
            }
        }

        // Track all try statements
        if (has_try) {
            try try_lines_list.append(allocator, actual_line);
        }
    }

    if (try_allocs.items.len == 0) return issues;

    // Check ownership transfer for each allocation
    for (try_allocs.items) |*alloc| {
        checkErrdeferOwnershipTransfer(alloc, lines, func_line);
    }

    // Check errdefer gaps for each allocation
    for (try_allocs.items) |*alloc| {
        if (alloc.has_errdefer) continue;

        // Find errdefer for this allocation
        var errdefer_line: usize = 0;
        for (errdefers.items) |ed| {
            if (containsIdentifier(ed.content, alloc.name)) {
                errdefer_line = ed.line;
                alloc.has_errdefer = true;
                break;
            }
        }

        // Check for try statements after allocation without errdefer coverage
        for (try_lines_list.items) |try_line| {
            if (try_line <= alloc.line) continue;

            if (alloc.has_errdefer and errdefer_line > alloc.line and errdefer_line < try_line) {
                continue; // Errdefer exists between allocation and try
            }

            if (!alloc.has_errdefer or errdefer_line >= try_line) {
                try issues.append(allocator, .{
                    .file = file_path,
                    .line = alloc.line,
                    .col = alloc.col,
                    .severity = .warning,
                    .rule = RULE_ALLOC_NO_ERRDEFER,
                    .message = "allocation without errdefer before next try",
                    .help = "add errdefer immediately after allocation",
                });
                break;
            }
        }
    }

    return issues;
}

// ============================================================================
// Function Analysis Types (for analyzeFunction)
// ============================================================================

/// Track allocations in function analysis
const AllocInfo = struct {
    name: []const u8,
    allocator_name: []const u8,
    line: usize,
    col: usize,
    is_create: bool,
    has_defer: bool = false,
    has_errdefer: bool = false,
    freed_explicitly: bool = false,
    freed_line: usize = 0,
    freed_in_early_return: bool = false, // Free is in catch/if block with return (path-safe)
    returned: bool = false,
    stored: bool = false,
    ownership_transferred: bool = false,
    is_arena_alloc: bool = false,
};

/// Memory event types for use-after-free and double-free
const MemoryEventKind = enum { use_after_free, double_free };

/// Track memory events
const MemoryEvent = struct {
    kind: MemoryEventKind,
    alloc_name: []const u8,
    alloc_line: usize,
    freed_line: usize,
    event_line: usize,
    event_col: usize,
};

// ============================================================================
// Import Graph
// ============================================================================

const ImportGraph = struct {
    allocator: Allocator,
    files: std.StringHashMap(FileAnalysis),
    reachable: std.StringHashMap(void),

    fn init(allocator: Allocator) ImportGraph {
        return .{
            .allocator = allocator,
            .files = std.StringHashMap(FileAnalysis).init(allocator),
            .reachable = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *ImportGraph) void {
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            var analysis = entry.value_ptr.*;
            analysis.deinit(self.allocator);
        }
        self.files.deinit();

        var keys: std.ArrayListUnmanaged([]const u8) = .{};
        defer keys.deinit(self.allocator);
        var reachable_iter = self.reachable.keyIterator();
        while (reachable_iter.next()) |key| {
            keys.append(self.allocator, key.*) catch continue;
        }
        self.reachable.deinit();
        for (keys.items) |key| {
            self.allocator.free(key);
        }
    }

    fn scanDirectory(self: *ImportGraph, dir_path: []const u8) !void {
        var dir = fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            std.debug.print("error: cannot open '{s}': {}\n", .{
                dir_path, err,
            });
            return err;
        };
        defer dir.close();
        try self.scanRecursive(dir, dir_path);
    }

    fn scanSingleFile(self: *ImportGraph, file_path: []const u8) !void {
        if (mem.endsWith(u8, file_path, ".zig")) {
            const path_copy = try self.allocator.dupe(u8, file_path);
            try self.analyzeFile(path_copy);
            self.allocator.free(path_copy);
        }
    }

    fn scanRecursive(self: *ImportGraph, dir: fs.Dir, base: []const u8) !void {
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ base, entry.name },
            );

            switch (entry.kind) {
                .file => {
                    if (mem.endsWith(u8, entry.name, ".zig")) {
                        try self.analyzeFile(path);
                    }
                    self.allocator.free(path);
                },
                .directory => {
                    const skip = entry.name[0] == '.' or
                        mem.eql(u8, entry.name, "zig-cache") or
                        mem.eql(u8, entry.name, "zig-out");
                    if (!skip) {
                        const open_opts: fs.Dir.OpenOptions = .{
                            .iterate = true,
                        };
                        var subdir = dir.openDir(entry.name, open_opts) catch {
                            self.allocator.free(path);
                            continue;
                        };
                        defer subdir.close();
                        try self.scanRecursive(subdir, path);
                    }
                    self.allocator.free(path);
                },
                else => self.allocator.free(path),
            }
        }
    }

    fn analyzeFile(self: *ImportGraph, file_path: []const u8) !void {
        const file = fs.cwd().openFile(file_path, .{}) catch return;
        defer file.close();
        const max_size = 10 * 1024 * 1024;
        const content = file.readToEndAlloc(self.allocator, max_size) catch {
            return;
        };
        const has_tests = mem.indexOf(u8, content, "test \"") != null;
        const pub_fn_count = types.countOccurrences(content, "pub fn ");
        var analysis = FileAnalysis{
            .path = try self.allocator.dupe(u8, file_path),
            .imports = .{},
            .content = content,
            .has_tests = has_tests,
            .pub_function_count = pub_fn_count,
            .line_count = types.countLines(content),
        };
        try self.extractImports(content, file_path, &analysis);
        try self.files.put(analysis.path, analysis);
    }

    /// Extract variable name after "const "
    fn extractVarName(content: []const u8, start: usize) ?[]const u8 {
        var end = start;
        while (end < content.len) : (end += 1) {
            const c = content[end];
            if (c == ' ' or c == '=' or c == '\n') break;
        }
        return if (end > start) content[start..end] else null;
    }

    /// Find import path in line starting from position
    fn findImportPath(content: []const u8, start: usize) ?[]const u8 {
        var j = start;
        while (j < content.len and content[j] != '\n') : (j += 1) {
            if (j + 9 >= content.len) continue;
            if (!mem.eql(u8, content[j .. j + 9], "@import(\"")) continue;
            const path_start = j + 9;
            var path_end = path_start;
            while (path_end < content.len and content[path_end] != '"') {
                path_end += 1;
            }
            if (path_end > path_start) return content[path_start..path_end];
        }
        return null;
    }

    fn extractImports(
        self: *ImportGraph,
        content: []const u8,
        file_path: []const u8,
        analysis: *FileAnalysis,
    ) !void {
        var line_num: usize = 1;
        var col: usize = 1;
        var i: usize = 0;

        while (i < content.len) : ({
            col += 1;
            i += 1;
        }) {
            if (content[i] == '\n') {
                line_num += 1;
                col = 1;
                continue;
            }

            const not_const = i + 6 >= content.len or
                !mem.eql(u8, content[i .. i + 6], "const ");
            if (not_const) continue;

            // Check if this is "pub const" (preceded by "pub ")
            const is_pub = i >= 4 and mem.eql(u8, content[i - 4 .. i], "pub ");

            const name_start = i + 6;
            const var_name = extractVarName(content, name_start) orelse {
                continue;
            };
            const path_start = name_start + var_name.len;
            const import_path = findImportPath(content, path_start) orelse {
                continue;
            };

            const is_std = mem.eql(u8, import_path, "std");
            const is_builtin = mem.eql(u8, import_path, "builtin");
            if (is_std or is_builtin) continue;

            const resolved = try self.resolveImport(file_path, import_path);
            try analysis.imports.append(self.allocator, .{
                .path = try self.allocator.dupe(u8, import_path),
                .resolved = resolved,
                .name = try self.allocator.dupe(u8, var_name),
                .line = line_num,
                .col = col,
                .is_pub = is_pub,
            });
        }
    }

    fn resolveImport(
        self: *ImportGraph,
        from: []const u8,
        import_path: []const u8,
    ) !?[]const u8 {
        const dir = std.fs.path.dirname(from) orelse ".";

        // Build relative path first
        const full = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ dir, import_path },
        );
        defer self.allocator.free(full);

        // Always resolve to absolute path for consistent comparison
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const resolved = std.fs.cwd().realpath(full, &buf) catch return null;
        return try self.allocator.dupe(u8, resolved);
    }

    fn markReachable(self: *ImportGraph, entry: []const u8) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const norm = fs.cwd().realpath(entry, &buf) catch return;
        try self.markReachableRecursive(norm);
    }

    fn markReachableRecursive(self: *ImportGraph, path: []const u8) !void {
        if (self.reachable.contains(path)) return;

        const copy = try self.allocator.dupe(u8, path);
        try self.reachable.put(copy, {});

        const imports = self.findImportsForPath(path) orelse return;
        for (imports) |imp| {
            const resolved = imp.resolved orelse continue;
            try self.markReachableRecursive(resolved);
        }
    }

    fn findImportsForPath(self: *ImportGraph, path: []const u8) ?[]ImportInfo {
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            var buf: [fs.max_path_bytes]u8 = undefined;
            const norm = fs.cwd().realpath(entry.key_ptr.*, &buf) catch {
                continue;
            };
            if (mem.eql(u8, norm, path)) return entry.value_ptr.imports.items;
        }
        return null;
    }

    fn getOrphanIssues(
        self: *ImportGraph,
        allocator: Allocator,
        cfg: *const Config,
    ) !std.ArrayListUnmanaged(Issue) {
        var issues: std.ArrayListUnmanaged(Issue) = .{};
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const key = entry.key_ptr.*;

            // Skip files matching orphan_exclude patterns
            if (isOrphanExcluded(key, cfg)) continue;

            const norm = fs.cwd().realpath(key, &buf) catch continue;
            if (!self.reachable.contains(norm)) {
                const help_msg =
                    "add @import() or remove if unused";
                try issues.append(allocator, .{
                    .file = key,
                    .line = 1,
                    .col = 1,
                    .severity = .warning,
                    .rule = RULE_ORPHAN_FILE,
                    .message = "file not imported",
                    .help = help_msg,
                });
            }
        }
        return issues;
    }

    fn getStats(self: *ImportGraph) ProjectStats {
        var s = ProjectStats{};
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            const a = entry.value_ptr.*;
            s.total_files += 1;
            s.total_lines += a.line_count;
            s.pub_fn_count += a.pub_function_count;
            if (a.has_tests) s.files_with_tests += 1;
            const test_pat = "test \"";
            s.test_count += countOccurrences(a.content, test_pat);
            const ni_pat = "error.NotImplemented";
            const ni_count = countOccurrences(a.content, ni_pat);
            s.not_implemented_count += ni_count;
            const todo = countOccurrences(a.content, "TODO");
            const fixme = countOccurrences(a.content, "FIXME");
            s.todo_count += todo + fixme;

            var lines = mem.splitScalar(u8, a.content, '\n');
            while (lines.next()) |line| {
                const t = mem.trim(u8, line, " \t\r");
                if (t.len == 0) {
                    s.blank_lines += 1;
                } else if (mem.startsWith(u8, t, "//")) {
                    s.comment_lines += 1;
                } else {
                    s.code_lines += 1;
                }
            }
        }
        return s;
    }
};

// ============================================================================
// Memory Analysis Helpers
// ============================================================================

/// Check if line indicates arena/fixed-buffer allocator
fn isNoFreeAllocator(lines: []const []const u8) bool {
    for (lines) |line| {
        const t = mem.trim(u8, line, " \t\r");
        // Arena allocators
        if (mem.indexOf(u8, t, "ArenaAllocator") != null) return true;
        if (mem.indexOf(u8, t, "arena.allocator()") != null) return true;
        if (mem.indexOf(u8, t, "arena_allocator") != null) return true;
        // Fixed buffer allocators
        const fba = "FixedBufferAllocator";
        if (mem.indexOf(u8, t, fba) != null) return true;
        const fba2 = "fixedBufferAllocator";
        if (mem.indexOf(u8, t, fba2) != null) return true;
        if (mem.indexOf(u8, t, "fba.allocator()") != null) return true;
        // Stack fallback
        if (mem.indexOf(u8, t, "stackFallback") != null) return true;
    }
    return false;
}

/// Check if allocator name suggests no-free allocator
fn isNoFreeAllocatorName(name: []const u8) bool {
    // Arena/scratch allocator naming patterns
    if (mem.indexOf(u8, name, "arena") != null) return true;
    if (mem.indexOf(u8, name, "scratch") != null) return true;
    if (mem.indexOf(u8, name, "temp") != null) return true;
    if (mem.indexOf(u8, name, "frame") != null) return true;
    if (mem.indexOf(u8, name, "recycle") != null) return true;
    if (mem.eql(u8, name, "fba")) return true;
    return false;
}

/// Check if a line contains no-free allocator patterns (arena, scratch, temp, frame, fba, recycle)
/// Used to skip allocations that don't need defer cleanup
fn hasNoFreeAllocatorPattern(t: []const u8) bool {
    const patterns = [_][]const u8{ "arena", "scratch", "temp", "frame", ".fba.", "recycle" };
    for (patterns) |p| {
        if (mem.indexOf(u8, t, p) != null) return true;
    }
    return false;
}

/// Patterns indicating ownership transfer (casts, out-params, container methods)
const ownership_transfer_patterns = [_][]const u8{
    "break :",        // Labeled block break - ownership to block result
    ".* = ",          // Out-parameter assignment (C FFI)
    "@ptrCast",       // Pointer cast
    "@alignCast",     // Alignment cast
    ".ptr",           // Slice reassignment
    // Container methods
    ".append(",       ".put(",         ".putNoClobber(",
    // Async/queue methods
    ".submit(",       ".enqueue(",     ".push(",        ".send(",
    ".emit(",         ".dispatch(",    ".transfer(",    ".deliver(",
    ".publish(",      ".broadcast(",   ".post(",        ".write(",
};

/// Check if ownership is transferred via cast or reassignment
fn isOwnershipTransfer(t: []const u8, alloc_name: []const u8) bool {
    if (mem.indexOf(u8, t, alloc_name) == null) return false;
    for (ownership_transfer_patterns) |pattern| {
        if (mem.indexOf(u8, t, pattern) != null) return true;
    }
    return false;
}

/// Check if allocation is stored in a struct field (ownership transferred to struct)
/// Patterns: self.field = alloc_name, self.*.field = alloc_name
fn isStructFieldStorage(t: []const u8, alloc_name: []const u8) bool {
    // Check for self.field = alloc_name or self.*.field = alloc_name
    if (mem.indexOf(u8, t, "self.") == null) return false;
    if (mem.indexOf(u8, t, alloc_name) == null) return false;

    // Pattern: self.something = alloc_name (assignment to struct field)
    // Look for = followed by alloc_name
    if (mem.indexOf(u8, t, " = ")) |eq_pos| {
        // Check if alloc_name appears after the =
        if (mem.indexOf(u8, t, alloc_name)) |name_pos| {
            if (name_pos > eq_pos) return true;
        }
    }
    return false;
}

/// Check if this is a pool allocator pattern
fn isPoolAllocator(t: []const u8) bool {
    // Memory pool patterns
    if (mem.indexOf(u8, t, "MemoryPool") != null) return true;
    if (mem.indexOf(u8, t, "pool.create(") != null) return true;
    if (mem.indexOf(u8, t, "pool.alloc(") != null) return true;
    if (mem.indexOf(u8, t, "ObjectPool") != null) return true;
    return false;
}

/// Extract identifier before .create( position
fn extractCreateCaller(t: []const u8, create_pos: usize) ?[]const u8 {
    if (create_pos == 0) return null;
    var start = create_pos;
    while (start > 0 and isIdent(t[start - 1])) start -= 1;
    if (start >= create_pos) return null;
    return t[start..create_pos];
}

/// Check if name is a known allocator name
fn isKnownAllocatorName(name: []const u8) bool {
    const names = [_][]const u8{
        "allocator",
        "alloc",
        "gpa",
        "arena",
        "fba",
        "page_allocator",
        "testing_allocator",
        "self",
    };
    for (names) |n| {
        if (mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// Check if name is known NON-allocator that calls .create()
fn isKnownNonAllocatorCreate(name: []const u8) bool {
    // Common non-allocator methods named .create() in Zig ecosystem
    const non_allocator_creates = [_][]const u8{
        "cgroup",     // Linux cgroup management (ghostty)
        "os",         // OS file operations
        "file",       // File system operations
        "dir",        // Directory operations
        "socket",     // Network socket creation
        "thread",     // Thread spawning
        "process",    // Process spawning
        "pipe",       // Pipe creation
        "event",      // Event creation
        "signal",     // Signal handlers
        "timer",      // Timer creation
        "mutex",      // Mutex creation
        "semaphore",  // Semaphore creation
        "condvar",    // Condition variable creation
        "internal_os", // Internal OS wrappers (ghostty)
    };
    for (non_allocator_creates) |known| {
        if (mem.eql(u8, name, known)) return true;
        // Also check dotted prefixes like internal_os.cgroup
        if (mem.indexOf(u8, name, known) != null) return true;
    }
    return false;
}

/// Check if .create() is allocator.create() vs static method or non-allocator
fn isAllocatorCreate(t: []const u8) bool {
    const pos = mem.indexOf(u8, t, ".create(") orelse return false;
    const name = extractCreateCaller(t, pos) orelse return false;
    // Uppercase = Type.create() static method (e.g., Parser.create())
    const is_upper = name.len > 0 and name[0] >= 'A' and name[0] <= 'Z';
    if (is_upper) return false;
    // Check known non-allocator .create() patterns first
    if (isKnownNonAllocatorCreate(name)) return false;
    // Known allocator names
    if (isKnownAllocatorName(name)) return true;
    // Name contains allocator/alloc - likely an allocator
    if (mem.indexOf(u8, name, "allocator") != null) return true;
    if (mem.indexOf(u8, name, "alloc") != null) return true;
    // Default to false - be conservative about flagging .create()
    // Only flag when we're confident it's an allocator
    return false;
}

/// Extract the allocator name from an allocation line
fn extractAllocatorName(t: []const u8) ?[]const u8 {
    // Pattern: name.alloc( or name.create(
    const alloc_pat = ".alloc(";
    const create_pat = ".create(";
    const alloc_pos = mem.indexOf(u8, t, alloc_pat) orelse
        mem.indexOf(u8, t, create_pat) orelse return null;

    // Walk backwards to find the allocator name
    const end = alloc_pos;
    var start = end;
    while (start > 0 and (isIdent(t[start - 1]) or t[start - 1] == '.')) {
        start -= 1;
    }
    // Skip the leading dot if any
    while (start < end and t[start] == '.') start += 1;

    if (start < end) {
        // Find just the allocator identifier
        var name_end = start;
        while (name_end < end and isIdent(t[name_end])) {
            name_end += 1;
        }
        if (name_end > start) return t[start..name_end];
    }
    return null;
}

// ============================================================================
// Analysis Functions
// ============================================================================

// ============================================================================
// Memory Analysis Helpers
// ============================================================================

/// Detect if allocation is returned (factory pattern)
fn isReturnPattern(t: []const u8, alloc_name: []const u8) bool {
    if (!mem.startsWith(u8, t, "return ")) return false;
    return mem.indexOf(u8, t, alloc_name) != null;
}

/// Detect if allocation is stored in self (builder pattern)
fn isSelfStoragePattern(t: []const u8, alloc_name: []const u8) bool {
    const has_self = mem.indexOf(u8, t, "self.") != null;
    const has_name = mem.indexOf(u8, t, alloc_name) != null;
    const has_assign = mem.indexOf(u8, t, " = ") != null;
    return has_self and has_name and has_assign;
}

/// Detect direct field assignment: var.field = try allocator.alloc(...)
/// This handles patterns like ctx.editing_buffer = try self.allocator.alloc(...)
fn isDirectFieldAssignment(t: []const u8, alloc_name: []const u8) bool {
    // Look for pattern: identifier.field = ... alloc_name
    const eq_pos = mem.indexOf(u8, t, " = ") orelse return false;
    const lhs = t[0..eq_pos];
    const rhs = t[eq_pos + 3 ..];

    // LHS should be identifier.field (e.g., ctx.editing_buffer, self.buffer)
    if (mem.indexOf(u8, lhs, ".") == null) return false;

    // RHS should contain alloc/create pattern (skip patterns in strings)
    const has_alloc = hasPatternNotInString(rhs, ".alloc(") or
        hasPatternNotInString(rhs, ".create(");
    if (!has_alloc) return false;

    // Check if lhs field name matches alloc_name (e.g., ctx.editing_buffer with editing_buffer)
    if (mem.indexOf(u8, lhs, alloc_name) != null) return true;

    return false;
}

fn detectsArenaAllocator(t: []const u8) bool {
    const patterns = [_][]const u8{
        "ArenaAllocator",
        "arena.allocator()",
        "FixedBufferAllocator",
        "fba.allocator()",
        "stackFallback",
    };
    for (patterns) |p| {
        if (mem.indexOf(u8, t, p) != null) return true;
    }
    // Check for function parameter named "arena" (common pattern)
    // Pattern: fn foo(arena: std.mem.Allocator) or fn foo(arena: Allocator)
    if (mem.indexOf(u8, t, "fn ") != null) {
        if (mem.indexOf(u8, t, "arena:") != null) return true;
        if (mem.indexOf(u8, t, "arena :") != null) return true;
    }
    return false;
}

/// Detect ownership transfer via function call
/// Pattern: foo.submit(alloc_name), queue.enqueue(alloc_name), etc.
fn isOwnershipTransferCall(t: []const u8, alloc_name: []const u8) bool {
    // Must contain alloc_name
    const alloc_pos = mem.indexOf(u8, t, alloc_name) orelse return false;

    // alloc_name must be followed by ) (argument to function)
    if (alloc_pos + alloc_name.len >= t.len) return false;

    // Check characters after alloc_name
    var after_pos = alloc_pos + alloc_name.len;
    while (after_pos < t.len and t[after_pos] == ' ') after_pos += 1;
    if (after_pos >= t.len) return false;

    // Must end with ) or , (part of argument list)
    if (t[after_pos] != ')' and t[after_pos] != ',') return false;

    // Check for ownership-transferring method names before (
    const ownership_methods = [_][]const u8{
        ".submit(",  ".enqueue(",   ".push(",     ".send(",
        ".emit(",    ".dispatch(",  ".transfer(", ".deliver(",
        ".publish(", ".broadcast(", ".post(",     ".write(",
    };
    for (ownership_methods) |method| {
        if (mem.indexOf(u8, t, method) != null) return true;
    }

    return false;
}

/// Detect module-level variable assignment (singleton/global pattern)
/// Pattern: identifier = alloc_name (no const/var keyword, no self./ctx. prefix)
fn isModuleLevelAssignment(t: []const u8, alloc_name: []const u8) bool {
    // Must contain alloc_name
    if (mem.indexOf(u8, t, alloc_name) == null) return false;

    // Must have an assignment
    const eq_pos = mem.indexOf(u8, t, " = ") orelse return false;

    // Must not be a const/var declaration (those are local)
    if (mem.startsWith(u8, t, "const ") or mem.startsWith(u8, t, "var ")) return false;

    // Extract lhs (the assigned-to variable)
    const lhs = mem.trim(u8, t[0..eq_pos], " \t");
    if (lhs.len == 0) return false;

    // LHS must be a simple identifier OR have a dot for field access
    // Skip if it's self.x or ctx.x (handled by other checks)
    if (mem.startsWith(u8, lhs, "self.") or mem.startsWith(u8, lhs, "ctx.")) return false;

    // If LHS is a simple identifier (no dots), it might be a module-level variable
    if (mem.indexOf(u8, lhs, ".") == null) {
        // Ensure alloc_name appears on RHS
        const rhs = t[eq_pos + 3 ..];
        return mem.indexOf(u8, rhs, alloc_name) != null;
    }

    return false;
}

/// Detect direct module-level allocation (not a local var, not a field)
/// Pattern: identifier = try allocator.alloc/create(...) where identifier is module-level
fn isDirectModuleLevelAlloc(t: []const u8) bool {
    // Must have an assignment
    const eq_pos = mem.indexOf(u8, t, " = ") orelse return false;

    // Extract lhs (the assigned-to variable)
    const lhs = mem.trim(u8, t[0..eq_pos], " \t");
    if (lhs.len == 0) return false;

    // Must not be a const/var declaration (those are local)
    if (mem.startsWith(u8, lhs, "const ") or mem.startsWith(u8, lhs, "var ")) return false;

    // Skip if it's self.x or ctx.x (handled by other checks as field assignment)
    if (mem.startsWith(u8, lhs, "self.") or mem.startsWith(u8, lhs, "ctx.")) return false;

    // Skip if lhs contains a dot (field access like x.y)
    if (mem.indexOf(u8, lhs, ".") != null) return false;

    // LHS must be a valid identifier (letters, numbers, underscores)
    for (lhs) |c| {
        if (!isIdent(c)) return false;
    }

    // RHS must contain .alloc( or .create( (skip patterns in strings)
    const rhs = t[eq_pos + 3 ..];
    return hasPatternNotInString(rhs, ".alloc(") or hasPatternNotInString(rhs, ".create(");
}

/// Check if allocation is directly assigned to a struct field (x.field = alloc)
/// These are managed by the struct's lifecycle and don't need local defer
fn isFieldAssignmentAlloc(t: []const u8) bool {
    const eq_pos = mem.indexOf(u8, t, " = ") orelse return false;
    const lhs = mem.trim(u8, t[0..eq_pos], " \t");

    // Not a field assignment if it's a const/var declaration
    if (mem.startsWith(u8, lhs, "const ") or mem.startsWith(u8, lhs, "var ")) {
        return false;
    }

    // Check if LHS is a field access (contains .)
    return mem.indexOf(u8, lhs, ".") != null;
}

/// Check if allocation is directly returned (return alloc.alloc(...))
/// Ownership transfers to caller, no defer needed
fn isDirectReturnAlloc(t: []const u8) bool {
    // Direct return statement
    if (mem.startsWith(u8, t, "return ")) return true;
    // Part of return if-else expression (check if line ends with semicolon after alloc)
    // Pattern: return if (...) ... else try alloc.alloc(...);
    // The alloc line might not start with return but is part of return expression
    if (mem.indexOf(u8, t, "return if") != null) return true;
    return false;
}

// ============================================================================
// Error Analysis Helpers
// ============================================================================

/// Check if code is in a test context (test file path or inside test block)
fn isInTestContext(path: []const u8, in_test_block: bool) bool {
    if (in_test_block) return true;
    if (mem.indexOf(u8, path, "_test.zig") != null) return true;
    if (mem.indexOf(u8, path, "/test") != null) return true;
    return false;
}

/// Check if a discarded result is safe (void/non-error return type)
fn isSafeToDiscard(t: []const u8) bool {
    const skip_patterns = [_][]const u8{
        ".destroy(", // Allocator destroy - returns void
        ".free(", // Allocator free - returns void
        ".pop(", // Returns popped T, not error - ok to discard
        ".clear(", // Returns void
        ".clearAndFree(", // Returns void
        ".clearRetainingCapacity(", // Returns void
        ".reset(", // Usually returns void
        ".skip(", // Iterator skip - returns bool, not error
    };
    for (skip_patterns) |pattern| {
        if (mem.indexOf(u8, t, pattern) != null) return true;
    }
    return false;
}

const TestBlockState = struct {
    in_test: bool,
    depth: usize,
};

/// Track test block boundaries
fn trackTestBlock(
    t: []const u8,
    in_test: bool,
    depth: usize,
) TestBlockState {
    var in_block = in_test;
    var brace_depth = depth;
    const starts_test = mem.startsWith(u8, t, "test ");
    const has_brace = mem.indexOf(u8, t, "{") != null;
    if (starts_test and has_brace) {
        in_block = true;
        brace_depth = 0;
    }
    if (in_block) {
        for (t) |c| {
            if (c == '{') brace_depth += 1;
            if (c == '}') {
                if (brace_depth > 0) brace_depth -= 1;
                if (brace_depth == 0) in_block = false;
            }
        }
    }
    return .{ .in_test = in_block, .depth = brace_depth };
}

/// Best-effort operations where silent catch {} is acceptable
/// NOTE: This is HEURISTIC-BASED on common library patterns, not Zig language semantics.
/// Categories: filesystem, cleanup, collection, writer, network, threading
const best_effort_ops = [_][]const u8{
    // Filesystem - might already exist/not exist
    "makePath(",     "makeDir(",      "deleteFile(",   "deleteDir(",
    "deleteTree(",   "unlink(",       "remove(",       "rename(",
    "symLink(",
    // Cleanup - best effort during teardown
    ".close(",       ".deinit(",      ".destroy(",     ".free(",
    ".flush(",       ".sync(",        ".reset(",       ".clear(",
    // Collection - partial success acceptable
    ".append(",      ".put(",         ".appendSlice(", ".appendAssumeCapacity(",
    ".ensureTotalCapacity(",          ".ensureUnusedCapacity(",
    // Writer - logging/debugging can fail
    ".print(",       ".writeAll(",    ".writeByte(",   ".write(",
    "std.debug.print(",
    "writePositionalAll(", "writeStreamingAll(",
    "writeAllBuffer(",
    // Network - transient failures expected
    ".send(",        ".recv(",        ".connect(",     ".bind(",
    ".stream.write(",
    // Locking - best effort
    ".lock(",        ".unlock(",
    // State changes - best effort (display links, services)
    ".start(",       ".stop(",
    // Threading - community pattern from Zig std lib (std/Thread.zig, std/Thread/Condition.zig)
    // Event loops: missed wakeups are self-correcting on next iteration
    // Zig std lib uses catch {} for yield(), timedWait(); ghostty uses .notify() catch {}
    ".setName(",     ".notify(",      ".wakeup(",      ".signal(",
    ".yield(",       ".timedWait(",
};

/// Check if a silent catch is for a best-effort operation
fn isBestEffortOperation(t: []const u8) bool {
    for (best_effort_ops) |op| {
        if (mem.indexOf(u8, t, op) != null) return true;
    }
    return false;
}

/// Check if we're in a cleanup function (deinit, close, destroy, cleanup, shutdown)
fn isCleanupFunctionContext(func_name: []const u8) bool {
    const cleanup_patterns = [_][]const u8{
        "deinit",
        "close",
        "destroy",
        "cleanup",
        "shutdown",
        "teardown",
        "dispose",
        "release",
    };
    for (cleanup_patterns) |pattern| {
        if (mem.indexOf(u8, func_name, pattern) != null) return true;
    }
    return false;
}

/// Check for silent catch patterns (ZA201)
/// Skip warning in contexts where best-effort is intentional
fn checkSilentCatch(t: []const u8, path: []const u8, line: usize) ?Issue {
    return checkSilentCatchWithContext(t, path, line, "");
}

/// Context-aware silent catch check
fn checkSilentCatchWithContext(t: []const u8, path: []const u8, line: usize, func_name: []const u8) ?Issue {
    // In defer/errdefer, catch {} is intentional for best-effort cleanup
    if (mem.startsWith(u8, t, "defer ") or mem.startsWith(u8, t, "errdefer ")) {
        return null;
    }

    // Best-effort operations where failure is acceptable
    if (isBestEffortOperation(t)) {
        return null;
    }

    // In cleanup functions, silent catch is often intentional
    if (isCleanupFunctionContext(func_name)) {
        return null;
    }

    if (mem.indexOf(u8, t, "catch {}")) |col| {
        if (!isInsideString(t, col)) return .{
            .file = path,
            .line = line,
            .col = col + 1,
            .severity = .warning,
            .rule = RULE_SILENT_CATCH,
            .message = "silent catch {} discards error",
            .help = "use catch |err| with logging, or propagate with try",
        };
    } else if (mem.indexOf(u8, t, "catch |_| {}")) |col| {
        if (!isInsideString(t, col)) return .{
            .file = path,
            .line = line,
            .col = col + 1,
            .severity = .warning,
            .rule = RULE_SILENT_CATCH,
            .message = "silent catch |_| {} discards error",
            .help = "use catch |err| with logging, or propagate with try",
        };
    }
    return null;
}

/// Check for catch unreachable (ZA202)
fn checkCatchUnreachable(
    t: []const u8,
    path: []const u8,
    line: usize,
) ?Issue {
    if (mem.indexOf(u8, t, "catch unreachable")) |col| {
        if (!isInsideString(t, col)) return .{
            .file = path,
            .line = line,
            .col = col + 1,
            .severity = .warning,
            .rule = RULE_CATCH_UNREACHABLE,
            .message = "catch unreachable will panic",
            .help = "use explicit error handling",
        };
    }
    return null;
}

/// Check for orelse unreachable (ZA203)
fn checkOrelseUnreachable(
    t: []const u8,
    path: []const u8,
    line: usize,
) ?Issue {
    if (mem.indexOf(u8, t, "orelse unreachable")) |col| {
        if (!isInsideString(t, col)) return .{
            .file = path,
            .line = line,
            .col = col + 1,
            .severity = .warning,
            .rule = RULE_ORELSE_UNREACHABLE,
            .message = "orelse unreachable will panic",
            .help = "use explicit null handling",
        };
    }
    return null;
}

/// Extract variable name from "var x" or "const x" declaration (for ZA204)
fn extractVarDeclName(t: []const u8) ?[]const u8 {
    const is_var = mem.startsWith(u8, t, "var ");
    const is_const = mem.startsWith(u8, t, "const ");
    if (!is_var and !is_const) return null;
    const start: usize = if (is_var) 4 else 6;
    var end = start;
    while (end < t.len and isIdent(t[end])) end += 1;
    if (end > start) return t[start..end];
    return null;
}

/// Check if &var_name appears at position (pointer passed to function)
fn hasPointerToVar(t: []const u8, pos: usize, var_name: []const u8) bool {
    if (t[pos] != '&') return false;
    const after = pos + 1;
    if (after + var_name.len > t.len) return false;
    if (!mem.eql(u8, t[after .. after + var_name.len], var_name)) return false;
    const end_pos = after + var_name.len;
    return end_pos >= t.len or !isIdent(t[end_pos]);
}

/// Check if line fills a variable (pointer passed to function or direct assignment)
fn isFillPattern(t: []const u8, var_name: []const u8) bool {
    // Check all occurrences of var_name (handles Struct.var_name patterns)
    var i: usize = 0;
    while (i + var_name.len <= t.len) : (i += 1) {
        if (!mem.eql(u8, t[i .. i + var_name.len], var_name)) continue;
        // Check it's a word boundary (not middle of identifier)
        const end_i = i + var_name.len;
        const after_ok = end_i >= t.len or !isIdent(t[end_i]);
        if (!after_ok) continue;

        // Pattern 1: &var_name or &Struct.var_name
        if (i > 0 and t[i - 1] == '&') return true;
        if (i > 1 and t[i - 1] == '.') {
            // Check for &Struct.var_name pattern - look back for &
            var j: usize = i - 2;
            while (j > 0 and (isIdent(t[j]) or t[j] == '.')) : (j -= 1) {}
            if (j < t.len and t[j] == '&') return true;
        }

        // Pattern 2: var_name[...] = (slice assignment)
        if (end_i < t.len and t[end_i] == '[') return true;

        // Pattern 3: var_name = or .var_name = (direct assignment)
        if (isAssignmentTarget(t, var_name, i)) return true;
    }

    // Pattern 4: @memcpy/@memset where var_name is the DESTINATION (first arg)
    // @memcpy(dest, src) - dest is filled, src is read
    // @memset(dest, value) - dest is filled
    if (mem.indexOf(u8, t, "@memcpy(")) |pos| {
        const after_paren = pos + 8; // "@memcpy(" is 8 chars
        if (after_paren < t.len) {
            if (mem.indexOf(u8, t[after_paren..], var_name)) |var_pos| {
                if (var_pos == 0 or (var_pos == 1 and t[after_paren] == '&')) return true;
            }
        }
    }
    if (mem.indexOf(u8, t, "@memset(")) |pos| {
        const after_paren = pos + 8; // "@memset(" is 8 chars
        if (after_paren < t.len) {
            if (mem.indexOf(u8, t[after_paren..], var_name)) |var_pos| {
                if (var_pos == 0 or (var_pos == 1 and t[after_paren] == '&')) return true;
            }
        }
    }

    // Pattern 5: Loop with indexed assignment to var_name
    // Only count as fill if we see var_name[...] = inside the loop
    // Note: This is a heuristic - full analysis requires tracking loop scope
    if (mem.indexOf(u8, t, "for ") != null or mem.indexOf(u8, t, "for(") != null) {
        // For loop on same line - check if it assigns to var_name
        if (mem.indexOf(u8, t, var_name)) |pos| {
            const end = pos + var_name.len;
            if (end < t.len and t[end] == '[') return true; // var_name[...] inside for
        }
    }

    // Pattern 6: Read/decode/bufPrint fills buffer (only if var_name is destination)
    // These functions typically take output buffer as first arg or via pointer
    if ((mem.indexOf(u8, t, ".read(") != null or
        mem.indexOf(u8, t, ".recv(") != null or
        mem.indexOf(u8, t, ".readAll(") != null or
        mem.indexOf(u8, t, ".decode(") != null or
        mem.indexOf(u8, t, "bufPrint(") != null) and
        mem.indexOf(u8, t, var_name) != null)
    {
        // Check if &var_name appears (pointer to buffer being filled)
        var j: usize = 0;
        while (j + var_name.len + 1 <= t.len) : (j += 1) {
            if (t[j] == '&' and mem.eql(u8, t[j + 1 .. j + 1 + var_name.len], var_name)) {
                return true;
            }
        }
    }

    // Pattern 7: Crypto operations that fill output buffers
    // .final(&output) fills output, but .update(input) reads input
    // Only .final, .encrypt, .decrypt, .hash fill output buffers
    if ((mem.indexOf(u8, t, "random.bytes(") != null or
        mem.indexOf(u8, t, ".final(") != null or
        mem.indexOf(u8, t, ".encrypt(") != null or
        mem.indexOf(u8, t, ".decrypt(") != null or
        mem.indexOf(u8, t, ".hash(") != null) and
        mem.indexOf(u8, t, var_name) != null)
    {
        // Check if &var_name appears
        var j: usize = 0;
        while (j + var_name.len + 1 <= t.len) : (j += 1) {
            if (t[j] == '&' and mem.eql(u8, t[j + 1 .. j + 1 + var_name.len], var_name)) {
                return true;
            }
        }
    }

    // Pattern 8: Common init functions that fill via pointer
    if (mem.indexOf(u8, t, ".init(") != null and mem.indexOf(u8, t, var_name) != null)
        return true;

    // Pattern 9: Method calls on var that may modify receiver (self parameter)
    // Covers: var_name.update(...), var_name.set(...), var_name.reinit(...), etc.
    const modifying_methods = [_][]const u8{
        ".update(",   ".set(",      ".reinit(",  ".reset(",
        ".assign(",   ".fill(",     ".clear(",   ".put(",
        ".append(",   ".resize(",   ".ensureCapacity(",
        ".replaceRange(", ".insertSlice(",
    };
    for (modifying_methods) |method| {
        if (mem.indexOf(u8, t, var_name)) |var_pos| {
            const after_var = var_pos + var_name.len;
            if (after_var + method.len <= t.len) {
                if (mem.startsWith(u8, t[after_var..], method)) return true;
            }
        }
    }

    return false;
}

/// Pending undefined variable to check within function scope
const PendingUndefined = struct {
    name: []const u8,
    line: usize,
    col: usize,
    brace_depth: usize = 1, // Track nesting to detect scope end
};

/// Pending struct field that was set to undefined
const PendingStructField = struct {
    struct_name: []const u8 = "",
    field_name: []const u8 = "",
    line: usize = 0,
    col: usize = 0,
    active: bool = false,
};

/// State for tracking struct literal initialization
const StructLiteralState = struct {
    struct_name: []const u8 = "",
    in_literal: bool = false,
    brace_depth: usize = 0,
};

/// Check if position matches struct.field pattern
fn matchesStructField(
    t: []const u8,
    pos: usize,
    sn: []const u8,
    fn_: []const u8,
) bool {
    if (pos + sn.len >= t.len) return false;
    if (!mem.eql(u8, t[pos .. pos + sn.len], sn)) return false;
    const after_s = pos + sn.len;
    if (after_s >= t.len or t[after_s] != '.') return false;
    const fld_start = after_s + 1;
    if (fld_start + fn_.len > t.len) return false;
    if (!mem.eql(u8, t[fld_start .. fld_start + fn_.len], fn_)) return false;
    const af = fld_start + fn_.len;
    return af >= t.len or !isIdent(t[af]);
}

/// Check for &struct.field pattern
fn hasPointerPattern(t: []const u8, sn: []const u8, fn_: []const u8) bool {
    for (t, 0..) |c, i| {
        if (c != '&') continue;
        if (matchesStructField(t, i + 1, sn, fn_)) return true;
    }
    return false;
}

/// Check for struct.field = pattern
fn hasAssignPattern(t: []const u8, sn: []const u8, fn_: []const u8) bool {
    var i: usize = 0;
    while (i + sn.len < t.len) : (i += 1) {
        if (i > 0 and isIdent(t[i - 1])) continue;
        if (!matchesStructField(t, i, sn, fn_)) continue;
        const af = i + sn.len + 1 + fn_.len;
        var j = af;
        while (j < t.len and t[j] == ' ') j += 1;
        if (j < t.len and t[j] == '=') return true;
    }
    return false;
}

/// Check if struct field is filled
fn isStructFieldFilled(t: []const u8, sn: []const u8, fn_: []const u8) bool {
    return hasPointerPattern(t, sn, fn_) or hasAssignPattern(t, sn, fn_);
}

/// Check if position starts a struct literal (Type{ or .{)
fn isStructLiteralStart(t: []const u8, i: usize) bool {
    if (i >= t.len) return false;
    // Anonymous struct .{
    if (t[i] == '.' and i + 1 < t.len and t[i + 1] == '{') return true;
    // Named type - skip identifier to find {
    if (!isIdent(t[i])) return false;
    var j = i;
    while (j < t.len and (isIdent(t[j]) or t[j] == '.')) j += 1;
    return j < t.len and t[j] == '{';
}

/// Extract struct variable name from "var NAME = Type{" or "var NAME = .{"
fn extractStructVarName(t: []const u8) ?[]const u8 {
    const is_var = mem.startsWith(u8, t, "var ");
    const is_const = mem.startsWith(u8, t, "const ");
    if (!is_var and !is_const) return null;

    const start: usize = if (is_var) 4 else 6;
    var end = start;
    while (end < t.len and isIdent(t[end])) end += 1;
    if (end <= start) return null;

    const name = t[start..end];
    var i = skipSpaces(t, end);
    if (i >= t.len or t[i] != '=') return null;
    i = skipSpaces(t, i + 1);

    return if (isStructLiteralStart(t, i)) name else null;
}

fn skipSpaces(t: []const u8, start: usize) usize {
    var i = start;
    while (i < t.len and t[i] == ' ') i += 1;
    return i;
}

/// Extract field name from ".field_name = undefined"
fn extractStructFieldName(t: []const u8) ?[]const u8 {
    // Find .field_name = undefined pattern
    const undef_pos = mem.indexOf(u8, t, "= undefined") orelse return null;

    // Work backwards from = to find field name
    var i: usize = undef_pos;
    // Skip space before =
    while (i > 0 and t[i - 1] == ' ') i -= 1;
    if (i == 0) return null;

    // Now at end of field name, find start
    const field_end = i;
    while (i > 0 and isIdent(t[i - 1])) i -= 1;
    if (i == field_end) return null;

    // Check preceded by '.'
    if (i == 0 or t[i - 1] != '.') return null;

    return t[i..field_end];
}

/// Check if column is preceded by '.' (struct field pattern)
fn isStructFieldPattern(t: []const u8, col: usize) bool {
    if (col == 0) return false;
    var i: usize = col;
    while (i > 0 and t[i - 1] == ' ') i -= 1;
    while (i > 0 and isIdent(t[i - 1])) i -= 1;
    return i > 0 and t[i - 1] == '.';
}

/// Try to start tracking a new undefined variable
fn tryTrackNewUndefined(
    t: []const u8,
    line: usize,
    pending: *?PendingUndefined,
) void {
    const col = mem.indexOf(u8, t, "= undefined") orelse return;
    if (isInsideString(t, col)) return;
    if (isStructFieldPattern(t, col)) return;
    const name = extractVarDeclName(t) orelse return;
    pending.* = .{ .name = name, .line = line, .col = col + 1 };
}

/// Create undefined issue (returns null if should be skipped)
fn makeUndefinedIssue(path: []const u8, ln: usize, col: usize) ?Issue {
    // Skip for test files
    if (isTestFilePath(path)) return null;

    return .{
        .file = path,
        .line = ln,
        .col = col,
        .severity = .warning,
        .rule = RULE_UNDEFINED_USAGE,
        .message = "undefined may leak data",
        .help = "initialize or write before use",
    };
}

/// Update brace depth tracking
fn updateBraceDepth(t: []const u8, depth: *usize) void {
    for (t) |c| {
        if (c == '{') depth.* += 1;
        if (c == '}' and depth.* > 0) depth.* -= 1;
    }
}

/// Check if scope has ended
fn hasScopeEnded(t: []const u8, brace_depth: usize) bool {
    if (brace_depth == 0) return true;
    if (mem.startsWith(u8, t, "return ")) return true;
    if (mem.startsWith(u8, t, "return;")) return true;
    const has_fn = mem.indexOf(u8, t, "fn ") != null;
    return has_fn and mem.indexOf(u8, t, "(") != null;
}

/// Handle pending undefined variable
fn handlePendingUndefined(
    t: []const u8,
    path: []const u8,
    line: usize,
    pending: *?PendingUndefined,
) ?Issue {
    const p = pending.*.?;
    if (isFillPattern(t, p.name)) {
        pending.* = null;
        return null;
    }
    var depth = p.brace_depth;
    updateBraceDepth(t, &depth);
    pending.* = .{
        .name = p.name,
        .line = p.line,
        .col = p.col,
        .brace_depth = depth,
    };
    if (!hasScopeEnded(t, depth)) return null;
    const issue = makeUndefinedIssue(path, p.line, p.col);
    pending.* = null;
    tryTrackNewUndefined(t, line, pending);
    return issue;
}

/// Check if line is a module-level declaration (no leading whitespace)
fn isModuleLevelDecl(raw_line: []const u8) bool {
    if (raw_line.len == 0) return false;
    // Module-level declarations start at column 0 (no indentation)
    return raw_line[0] != ' ' and raw_line[0] != '\t';
}

/// Check if `= undefined` is a cleanup pattern (intentional memory clearing)
/// Patterns like `self.* = undefined;` or `ptr.* = undefined;` are cleanup ops
fn isCleanupUndefinedPattern(t: []const u8, undefined_col: usize) bool {
    // Look for `.* =` or `.*=` pattern before the `= undefined`
    // The undefined_col points to the `=` in `= undefined`
    if (undefined_col < 2) return false;

    // Search backwards from the `=` to find `.*`
    var i: usize = undefined_col;
    // Skip whitespace before the `=`
    while (i > 0 and (t[i - 1] == ' ' or t[i - 1] == '\t')) {
        i -= 1;
    }
    // Check for `.*` pattern (pointer dereference)
    if (i >= 2 and t[i - 2] == '.' and t[i - 1] == '*') {
        return true;
    }
    // Check for `]` pattern (array index assignment)
    if (i >= 1 and t[i - 1] == ']') {
        return true;
    }
    return false;
}

/// Check for undefined usage (ZA204)
fn checkUndefinedUsage(
    t: []const u8,
    path: []const u8,
    line: usize,
    pending: *?PendingUndefined,
) ?Issue {
    if (pending.* != null) {
        return handlePendingUndefined(t, path, line, pending);
    }
    const col = mem.indexOf(u8, t, "= undefined") orelse return null;
    // Ensure "undefined" is a complete token, not part of "undefined_col" etc.
    const after_undefined = col + "= undefined".len;
    if (after_undefined < t.len) {
        const next_char = t[after_undefined];
        if ((next_char >= 'a' and next_char <= 'z') or
            (next_char >= 'A' and next_char <= 'Z') or
            (next_char >= '0' and next_char <= '9') or
            next_char == '_')
        {
            return null; // Part of longer identifier like "undefined_col"
        }
    }
    if (isInsideString(t, col)) return null;
    // Skip if match is inside a trailing comment (but not if // is in a string)
    if (mem.indexOf(u8, t, "//")) |comment_start| {
        if (col > comment_start and !isInsideString(t, comment_start)) return null;
    }
    if (isStructFieldPattern(t, col)) return null;
    // Skip cleanup patterns like `self.* = undefined;` or `ptr.* = undefined;`
    if (isCleanupUndefinedPattern(t, col)) return null;
    if (extractVarDeclName(t)) |name| {
        pending.* = .{ .name = name, .line = line, .col = col + 1 };
        return null;
    }
    return makeUndefinedIssue(path, line, col + 1);
}

/// Check for discarded error union results
fn checkDiscardedResult(
    t: []const u8,
    path: []const u8,
    line: usize,
) ?Issue {
    const starts_discard = mem.startsWith(u8, t, "_ = ");
    const has_call = mem.indexOf(u8, t, "()") != null;
    if (!starts_discard or !has_call) return null;
    if (compat.containsOptionalMethod(t)) return null;
    if (isSafeToDiscard(t)) return null;
    // _ = try func() propagates errors - only discards success value
    if (mem.indexOf(u8, t, "try ") != null) return null;
    const has_catch = mem.indexOf(u8, t, " catch ") != null;
    const has_catch2 = mem.indexOf(u8, t, "catch ") != null;
    if (has_catch or has_catch2) return null;
    return .{
        .file = path,
        .line = line,
        .col = 1,
        .severity = .note,
        .rule = RULE_SILENT_CATCH,
        .message = "discarded result - errors may be lost",
        .help = "use try or catch to handle",
    };
}

/// State for error analysis of a single file
const ErrorAnalysisState = struct {
    in_test_block: bool = false,
    test_brace_depth: usize = 0,
    pending_undefined: ?PendingUndefined = null,
    struct_state: StructLiteralState = .{},
    pending_struct_fields: [64]PendingStructField =
        [_]PendingStructField{.{}} ** 64,
    pending_field_count: usize = 0,
    // Track static storage struct pattern (const S = struct { var x; })
    in_static_struct: bool = false,
    static_struct_depth: usize = 0,
    // Track defer/errdefer blocks (catch {} is intentional for cleanup)
    in_defer_block: bool = false,
    defer_brace_depth: usize = 0,
    // Track current function name for context-sensitive checks
    current_func_name: []const u8 = "",
    func_brace_depth: usize = 0,
    // Track catch blocks (error recovery context - silent catch is intentional)
    in_catch_block: bool = false,
    catch_brace_depth: usize = 0,
};

/// Check if line starts a static storage struct pattern
fn isStaticStorageStruct(t: []const u8) bool {
    // Pattern: const X = struct { (used for thread-local static storage)
    if (mem.indexOf(u8, t, "const ") == null) return false;
    if (mem.indexOf(u8, t, "= struct")) |pos| {
        // Make sure there's an identifier between const and = struct
        const before = t[6..pos]; // after "const "
        return mem.trim(u8, before, " \t").len > 0;
    }
    return false;
}

/// Track static storage struct braces
fn trackStaticStructBraces(t: []const u8, state: *ErrorAnalysisState) void {
    for (t) |c| {
        if (c == '{') state.static_struct_depth += 1;
        if (c == '}' and state.static_struct_depth > 0) {
            state.static_struct_depth -= 1;
            if (state.static_struct_depth == 0) state.in_static_struct = false;
        }
    }
}

/// Track defer/errdefer blocks for silent catch exclusion
fn trackDeferBlock(t: []const u8, state: *ErrorAnalysisState) void {
    // Detect defer/errdefer start
    if (mem.startsWith(u8, t, "defer ") or mem.startsWith(u8, t, "errdefer ")) {
        // Check if it's a block defer (has { on same line)
        if (mem.indexOf(u8, t, "{") != null) {
            state.in_defer_block = true;
            state.defer_brace_depth = 0;
            // Count braces on this line
            for (t) |c| {
                if (c == '{') state.defer_brace_depth += 1;
                if (c == '}' and state.defer_brace_depth > 0) state.defer_brace_depth -= 1;
            }
            // If braces balanced on same line, block ended
            if (state.defer_brace_depth == 0) state.in_defer_block = false;
        }
        return;
    }

    // Track braces if inside defer block
    if (state.in_defer_block) {
        for (t) |c| {
            if (c == '{') state.defer_brace_depth += 1;
            if (c == '}' and state.defer_brace_depth > 0) {
                state.defer_brace_depth -= 1;
                if (state.defer_brace_depth == 0) state.in_defer_block = false;
            }
        }
    }
}

/// Track catch blocks for error recovery context detection
/// Silent catch {} inside a catch block is intentional error handling
fn trackCatchBlock(t: []const u8, state: *ErrorAnalysisState) void {
    // Detect catch block start: "catch |err| {" or "} catch {"
    // But NOT "catch {}" on same line (that's the pattern we're checking for)
    if (mem.indexOf(u8, t, "catch |") != null or
        (mem.indexOf(u8, t, "} catch {") != null and mem.indexOf(u8, t, "catch {}") == null))
    {
        if (mem.indexOf(u8, t, "{") != null) {
            state.in_catch_block = true;
            state.catch_brace_depth = 0;
            for (t) |c| {
                if (c == '{') state.catch_brace_depth += 1;
                if (c == '}' and state.catch_brace_depth > 0) state.catch_brace_depth -= 1;
            }
            if (state.catch_brace_depth == 0) state.in_catch_block = false;
        }
        return;
    }

    // Track braces if inside catch block
    if (state.in_catch_block) {
        for (t) |c| {
            if (c == '{') state.catch_brace_depth += 1;
            if (c == '}' and state.catch_brace_depth > 0) {
                state.catch_brace_depth -= 1;
                if (state.catch_brace_depth == 0) state.in_catch_block = false;
            }
        }
    }
}

/// Extract function name from function declaration line
fn extractFuncName(t: []const u8) ?[]const u8 {
    // Pattern: "pub fn name(" or "fn name("
    const fn_idx = mem.indexOf(u8, t, "fn ") orelse return null;
    const start = fn_idx + 3;
    if (start >= t.len) return null;
    var end = start;
    while (end < t.len and isIdent(t[end])) end += 1;
    if (end > start) return t[start..end];
    return null;
}

/// Track current function context for context-sensitive checks
fn trackFunctionContext(t: []const u8, state: *ErrorAnalysisState) void {
    // Detect function declaration
    if (extractFuncName(t)) |name| {
        state.current_func_name = name;
        state.func_brace_depth = 0;
        // Count braces on the declaration line
        for (t) |c| {
            if (c == '{') state.func_brace_depth += 1;
        }
        return;
    }

    // Track braces to detect function end
    if (state.current_func_name.len > 0) {
        for (t) |c| {
            if (c == '{') state.func_brace_depth += 1;
            if (c == '}' and state.func_brace_depth > 0) {
                state.func_brace_depth -= 1;
                if (state.func_brace_depth == 0) {
                    state.current_func_name = "";
                }
            }
        }
    }
}

/// Track struct literal and collect pending undefined fields
fn trackStructLiteral(
    t: []const u8,
    ln: usize,
    state: *ErrorAnalysisState,
) void {
    if (extractStructVarName(t)) |name| {
        state.struct_state.struct_name = name;
        state.struct_state.in_literal = true;
        state.struct_state.brace_depth = 1;
        return;
    }
    if (!state.struct_state.in_literal) return;
    trackStructBraces(t, &state.struct_state);
    collectUndefinedField(t, ln, state);
}

/// Track braces within struct literal
fn trackStructBraces(t: []const u8, ss: *StructLiteralState) void {
    for (t) |c| {
        if (c == '{') ss.brace_depth += 1;
        if (c == '}' and ss.brace_depth > 0) {
            ss.brace_depth -= 1;
            if (ss.brace_depth == 0) ss.in_literal = false;
        }
    }
}

/// Collect undefined field if found
fn collectUndefinedField(t: []const u8, ln: usize, s: *ErrorAnalysisState) void {
    if (!s.struct_state.in_literal) return;
    if (mem.indexOf(u8, t, "= undefined") == null) return;
    const field = extractStructFieldName(t) orelse return;
    if (s.pending_field_count >= s.pending_struct_fields.len) return;
    const col = mem.indexOf(u8, t, "= undefined") orelse 0;
    s.pending_struct_fields[s.pending_field_count] = .{
        .struct_name = s.struct_state.struct_name,
        .field_name = field,
        .line = ln,
        .col = col + 1,
    };
    s.pending_field_count += 1;
}

/// Activate pending fields when struct literal closes
fn activatePendingFields(state: *ErrorAnalysisState) void {
    if (state.struct_state.in_literal) return;
    if (state.pending_field_count == 0) return;
    for (state.pending_struct_fields[0..state.pending_field_count]) |*pf| {
        pf.active = true;
    }
}

/// Check if line ends the scope (return or new function)
fn isScopeEnd(t: []const u8) bool {
    if (mem.startsWith(u8, t, "return ")) return true;
    if (mem.startsWith(u8, t, "return;")) return true;
    const has_fn = mem.indexOf(u8, t, "fn ") != null;
    const has_paren = mem.indexOf(u8, t, "(") != null;
    return has_fn and has_paren;
}

/// Check pending struct fields and report unfilled ones
fn checkPendingFields(
    t: []const u8,
    path: []const u8,
    state: *ErrorAnalysisState,
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
) !void {
    if (state.pending_field_count == 0) return;
    var i: usize = 0;
    while (i < state.pending_field_count) {
        const pf = &state.pending_struct_fields[i];
        if (!pf.active) {
            i += 1;
            continue;
        }
        if (isStructFieldFilled(t, pf.struct_name, pf.field_name)) {
            removePendingField(state, i);
            continue;
        }
        if (isScopeEnd(t)) {
            try reportUnfilledField(issues, allocator, path, pf);
            removePendingField(state, i);
            continue;
        }
        i += 1;
    }
}

/// Remove pending field at index
fn removePendingField(state: *ErrorAnalysisState, i: usize) void {
    if (state.pending_field_count == 0) return;
    state.pending_field_count -= 1;
    if (i < state.pending_field_count) {
        state.pending_struct_fields[i] =
            state.pending_struct_fields[state.pending_field_count];
    }
}

/// Check if path is likely a test file
fn isTestFilePath(path: []const u8) bool {
    return mem.indexOf(u8, path, "_test.zig") != null or
        mem.indexOf(u8, path, "/test/") != null or
        mem.indexOf(u8, path, "/tests/") != null or
        mem.indexOf(u8, path, "localhost_testing") != null;
}

/// Report unfilled struct field
fn reportUnfilledField(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    pf: *const PendingStructField,
) !void {
    // Skip reporting in test files - undefined fields are common for mocks
    if (isTestFilePath(path)) return;

    try issues.append(allocator, .{
        .file = path,
        .line = pf.line,
        .col = pf.col,
        .severity = .warning,
        .rule = RULE_UNDEFINED_USAGE,
        .message = "struct field undefined may leak data",
        .help = "assign value before use",
    });
}

/// Check all error patterns on a single line
fn checkLineErrors(
    t: []const u8,
    path: []const u8,
    ln: usize,
    skip_undefined: bool,
    in_defer: bool,
    func_name: []const u8,
    pending: *?PendingUndefined,
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
) !void {
    // Skip silent catch in defer context - catch {} is intentional for cleanup
    // NOTE: ZA201/ZA202/ZA203 are now handled by analyzeCFGErrors with proper test context
    // The CFG-based analysis can detect nested functions inside test blocks
    if (!in_defer) {
        if (checkSilentCatchWithContext(t, path, ln, func_name)) |i| {
            try issues.append(allocator, i);
        }
    }
    // ZA202 (catch unreachable) and ZA203 (orelse unreachable) moved to analyzeCFGErrors
    // to support test context detection for nested anonymous callbacks
    // Skip undefined checks in test/module-level context
    if (!skip_undefined) {
        if (checkUndefinedUsage(t, path, ln, pending)) |i| {
            try issues.append(allocator, i);
        }
    }
    if (checkDiscardedResult(t, path, ln)) |i| try issues.append(allocator, i);
}

/// Report remaining pending issues at end of file
fn reportEndOfFileIssues(
    state: *ErrorAnalysisState,
    path: []const u8,
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
) !void {
    // Skip undefined reports for test files
    if (!isTestFilePath(path)) {
        if (state.pending_undefined) |pending| {
            try issues.append(allocator, .{
                .file = path,
                .line = pending.line,
                .col = pending.col,
                .severity = .warning,
                .rule = RULE_UNDEFINED_USAGE,
                .message = "undefined may leak data",
                .help = "initialize or write before use",
            });
        }
    }
    const fields = state.pending_struct_fields[0..state.pending_field_count];
    for (fields) |pf| {
        try reportUnfilledField(issues, allocator, path, &pf);
    }
}

/// Analyze a single file for error issues
fn analyzeFileErrors(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    a: FileAnalysis,
) !void {
    var state = ErrorAnalysisState{};
    var line_num: usize = 1;
    var lines = mem.splitScalar(u8, a.content, '\n');

    while (lines.next()) |line| {
        defer line_num += 1;
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;

        const ts = trackTestBlock(
            t,
            state.in_test_block,
            state.test_brace_depth,
        );
        state.in_test_block = ts.in_test;
        state.test_brace_depth = ts.depth;
        const in_test = isInTestContext(a.path, state.in_test_block);

        // Track static storage struct pattern (const S = struct { var x; })
        if (isStaticStorageStruct(t)) {
            state.in_static_struct = true;
            state.static_struct_depth = 0;
        }
        if (state.in_static_struct) {
            trackStaticStructBraces(t, &state);
        }

        // Skip undefined checks in tests, module-level, and static storage
        const skip_undefined = in_test or isTestFilePath(a.path) or
            isModuleLevelDecl(line) or state.in_static_struct;

        // Track function context for cleanup detection
        trackFunctionContext(t, &state);

        // Track defer blocks for silent catch exclusion
        trackDeferBlock(t, &state);

        // Track struct fields only outside tests
        if (!skip_undefined) {
            trackStructLiteral(t, line_num, &state);
            activatePendingFields(&state);
            try checkPendingFields(t, a.path, &state, issues, allocator);
        }
        try checkLineErrors(
            t,
            a.path,
            line_num,
            skip_undefined,
            state.in_defer_block,
            state.current_func_name,
            &state.pending_undefined,
            issues,
            allocator,
        );
    }
    try reportEndOfFileIssues(&state, a.path, issues, allocator);
}

fn analyzeErrors(
    allocator: Allocator,
    graph: *ImportGraph,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    var iter = graph.files.iterator();
    while (iter.next()) |entry| {
        try analyzeFileErrors(allocator, &issues, entry.value_ptr.*);
    }
    return issues;
}

// ============================================================================
// Unused Analysis Helpers
// ============================================================================

/// Count word-boundary occurrences of name in content
fn countIdentOccurrences(content: []const u8, name: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i + name.len <= content.len) : (i += 1) {
        if (!mem.eql(u8, content[i .. i + name.len], name)) continue;
        const before_ok = i == 0 or !isIdent(content[i - 1]);
        const end_idx = i + name.len;
        const after_ok = end_idx >= content.len or !isIdent(content[end_idx]);
        if (before_ok and after_ok) count += 1;
    }
    return count;
}

/// Extract variable name for unused detection (filters out _ prefix and short names)
fn extractUnusedDeclName(t: []const u8, is_const: bool) ?[]const u8 {
    const prefix_len: usize = if (is_const) 6 else 4;
    if (t.len <= prefix_len) return null;
    var end = prefix_len;
    while (end < t.len and isIdent(t[end])) end += 1;
    if (end <= prefix_len) return null;
    const name = t[prefix_len..end];
    // Skip names that are intentionally unused (_ prefix) or too short to be meaningful
    if (name.len < 2 or name[0] == '_') return null;
    return name;
}

/// Check a single import for usage (ZA401)
fn checkUnusedImport(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    path: []const u8,
    content: []const u8,
    imp: ImportInfo,
) !void {
    if (imp.name.len > 0 and imp.name[0] == '_') return;
    // Skip public re-exports - they're intentional library API
    if (imp.is_pub) return;
    if (countIdentOccurrences(content, imp.name) > 1) return;
    const msg = try std.fmt.allocPrint(
        allocator,
        "unused import '{s}'",
        .{imp.name},
    );
    try issues.append(allocator, .{
        .file = path,
        .line = imp.line,
        .col = imp.col,
        .severity = .warning,
        .rule = RULE_UNUSED_IMPORT,
        .message = msg,
        .message_owned = true,
        .help = "remove the import or prefix with '_' to suppress",
    });
}

/// Check a single declaration line for usage (ZA402/ZA403)
fn checkUnusedDecl(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    path: []const u8,
    content: []const u8,
    t: []const u8,
    line_num: usize,
) !void {
    if (isCommentOrMultilineString(t)) return;
    if (mem.indexOf(u8, t, "@import(") != null) return;
    // Skip @This() pattern - common idiom for self-referential types
    if (mem.indexOf(u8, t, "@This()") != null) return;
    const is_const = mem.startsWith(u8, t, "const ");
    const is_var = mem.startsWith(u8, t, "var ");
    if (!is_const and !is_var) return;
    const name = extractUnusedDeclName(t, is_const) orelse return;
    if (countIdentOccurrences(content, name) != 1) return;
    const rule = if (is_const) RULE_UNUSED_CONST else RULE_UNUSED_VAR;
    const kind = if (is_const) "const" else "var";
    const msg = try std.fmt.allocPrint(
        allocator,
        "unused {s} '{s}'",
        .{ kind, name },
    );
    try issues.append(allocator, .{
        .file = path,
        .line = line_num,
        .col = 1,
        .severity = .warning,
        .rule = rule,
        .message = msg,
        .message_owned = true,
        .help = "remove the declaration or prefix with '_' to suppress",
    });
}

fn analyzeUnused(
    allocator: Allocator,
    graph: *ImportGraph,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    var iter = graph.files.iterator();
    while (iter.next()) |entry| {
        const a = entry.value_ptr.*;
        // Skip auto-generated C import files (many false positives)
        if (mem.endsWith(u8, a.path, "cimport.zig")) continue;
        if (mem.indexOf(u8, a.path, "/deps/") != null and
            mem.endsWith(u8, a.path, ".zig"))
        {
            // Check for C translation markers
            if (mem.indexOf(u8, a.content, "__builtin_") != null or
                mem.indexOf(u8, a.content, "enum_unnamed_") != null)
            {
                continue;
            }
        }
        for (a.imports.items) |imp| {
            try checkUnusedImport(allocator, &issues, a.path, a.content, imp);
        }
        var line_num: usize = 1;
        var lines = mem.splitScalar(u8, a.content, '\n');
        while (lines.next()) |line| {
            defer line_num += 1;
            const t = mem.trim(u8, line, " \t\r");
            try checkUnusedDecl(allocator, &issues, a.path, a.content, t, line_num);
        }
    }
    return issues;
}

// ============================================================================
// Complexity Analysis Helpers
// ============================================================================

const ComplexityState = struct {
    in_fn: bool = false,
    fn_start: usize = 0,
    fn_col: usize = 1,
    fn_name: []const u8 = "",
    fn_lines: usize = 0,
    max_nest: usize = 0,
    nest: usize = 0,
    branches: usize = 0,
    params: usize = 0,
    is_type_factory: bool = false,
};

/// Count function parameters by counting colons at depth 1
fn countFnParams(t: []const u8) usize {
    const p = mem.indexOf(u8, t, "(") orelse return 0;
    var params: usize = 0;
    var i = p + 1;
    var d: usize = 1;
    while (i < t.len and d > 0) : (i += 1) {
        if (t[i] == '(') d += 1;
        if (t[i] == ')') d -= 1;
        if (t[i] == ':' and d == 1) params += 1;
    }
    return params;
}

/// Check if keyword exists but not with inline prefix
fn hasNonInline(t: []const u8, kw: []const u8, inline_kw: []const u8) bool {
    return mem.indexOf(u8, t, kw) != null and mem.indexOf(u8, t, inline_kw) == null;
}

/// Count branches in a line (control flow decision points)
fn countLineBranches(t: []const u8) usize {
    var b: usize = 0;
    if (mem.indexOf(u8, t, "if ") != null) b += 1;
    if (hasNonInline(t, "else ", "else =>")) b += 1;
    if (mem.indexOf(u8, t, "switch ") != null) b += 1;
    if (hasNonInline(t, "while ", "inline while")) b += 1;
    if (hasNonInline(t, "for ", "inline for")) b += 1;
    if (mem.indexOf(u8, t, " catch ") != null) b += 1;
    return b;
}

/// Calculate limit with type factory multiplier
fn calcLimit(base: usize, is_factory: bool, mult: usize) usize {
    return if (is_factory) base * mult else base;
}

/// Report a single complexity issue
fn reportSingleComplexity(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    state: *const ComplexityState,
    rule: []const u8,
    actual: usize,
    limit: usize,
    metric: []const u8,
    help: []const u8,
) !void {
    if (actual <= limit) return;
    const suffix: []const u8 = if (state.is_type_factory) " [tf]" else "";
    const fmt = "function '{s}' has {d} {s} (max {d}){s}";
    const msg = try std.fmt.allocPrint(
        allocator,
        fmt,
        .{ state.fn_name, actual, metric, limit, suffix },
    );
    try issues.append(allocator, .{
        .file = path,
        .line = state.fn_start,
        .col = state.fn_col,
        .severity = .warning,
        .rule = rule,
        .message = msg,
        .message_owned = true,
        .help = help,
    });
}

/// Complexity check definition
const ComplexityCheck = struct {
    rule: []const u8,
    actual: usize,
    limit: usize,
    metric: []const u8,
    help: []const u8,
};

/// Build complexity checks array for a function
fn buildComplexityChecks(
    state: *const ComplexityState,
    th: Thresholds,
) [4]ComplexityCheck {
    const is_tf = state.is_type_factory;
    return .{
        .{
            .rule = RULE_FUNC_TOO_LONG,
            .actual = state.fn_lines,
            .limit = calcLimit(th.max_function_lines, is_tf, 3),
            .metric = "lines",
            .help = "split into smaller functions",
        },
        .{
            .rule = RULE_NESTING_TOO_DEEP,
            .actual = state.max_nest,
            .limit = calcLimit(th.max_nesting_depth, is_tf, 2),
            .metric = "nesting depth",
            .help = "use early returns",
        },
        .{
            .rule = RULE_TOO_MANY_PARAMS,
            .actual = state.params,
            .limit = th.max_params,
            .metric = "parameters",
            .help = "group into struct",
        },
        .{
            .rule = RULE_TOO_MANY_BRANCHES,
            .actual = state.branches,
            .limit = calcLimit(th.max_branches, is_tf, 3),
            .metric = "branches",
            .help = "simplify logic",
        },
    };
}

/// Report complexity issues for a completed function
fn reportComplexityIssues(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    state: *const ComplexityState,
    th: Thresholds,
) !void {
    const checks = buildComplexityChecks(state, th);
    for (checks) |c| {
        try reportSingleComplexity(
            issues,
            allocator,
            path,
            state,
            c.rule,
            c.actual,
            c.limit,
            c.metric,
            c.help,
        );
    }
}

/// Check if line starts a new function definition (not struct method, not string)
fn isNewFunctionDef(t: []const u8) bool {
    // Must start with "fn " or "pub fn " (not inside struct/string)
    if (mem.startsWith(u8, t, "fn ")) return true;
    if (mem.startsWith(u8, t, "pub fn ")) return true;
    return false;
}

/// Find real function definition position (not inside string)
fn findRealFnDef(t: []const u8) ?usize {
    const pos = mem.indexOf(u8, t, "fn ") orelse return null;
    // Skip if "fn " appears inside a string literal
    if (isInsideString(t, pos)) return null;
    // Must be followed by identifier (function name)
    if (pos + 3 >= t.len or !isIdent(t[pos + 3])) return null;
    return pos;
}

/// Detect function start and initialize complexity state
fn detectFnStart(t: []const u8, state: *ComplexityState, line_num: usize) void {
    const pos = findRealFnDef(t) orelse return;

    // New top-level function definition resets state even if in_fn is true
    // This handles cases where brace counting didn't detect function end
    if (state.in_fn and isNewFunctionDef(t)) {
        state.* = .{}; // Reset state for new function
    }
    if (state.in_fn) return;

    state.* = .{
        .in_fn = true,
        .fn_start = line_num,
        .fn_col = pos + 1,
        .is_type_factory = isTypeFactory(t),
        .params = countFnParams(t),
    };
    var end = pos + 3;
    while (end < t.len and isIdent(t[end])) end += 1;
    state.fn_name = t[pos + 3 .. end];
}

/// State for tracking string/char literals while parsing
const LiteralState = struct {
    in_str: bool = false,
    in_chr: bool = false,

    fn updateForChar(self: *LiteralState, t: []const u8, i: usize) ?usize {
        const c = t[i];
        if (c == '\'' and !self.in_str) {
            if (!self.in_chr) {
                self.in_chr = true;
                // Skip char content
                if (i + 1 < t.len and t[i + 1] == '\\') return i + 2;
                if (i + 1 < t.len) return i + 1;
            } else {
                self.in_chr = false;
            }
            return null;
        }
        if (c == '"' and !self.in_chr and (i == 0 or t[i - 1] != '\\')) {
            self.in_str = !self.in_str;
            return null;
        }
        return if (self.in_str or self.in_chr) null else i;
    }
};

/// Track brace nesting, returns true if function ended
fn trackBraceNesting(t: []const u8, state: *ComplexityState) bool {
    const is_switch = mem.indexOf(u8, t, "=>") != null;
    var lit = LiteralState{};
    var first = true;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (lit.updateForChar(t, i)) |pos| {
            const c = t[pos];
            if (c == '{' and !(is_switch and first)) {
                state.nest += 1;
                if (state.nest > state.max_nest) state.max_nest = state.nest;
                first = false;
            }
            if (c == '}' and state.nest > 0) {
                state.nest -= 1;
                if (state.nest == 0) return true;
            }
        } else if (lit.in_chr and i + 1 < t.len) {
            // Skip char literal content
            i += 1;
        }
    }
    return false;
}

/// Analyze complexity of a single file
fn analyzeFileComplexity(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    a: FileAnalysis,
    th: Thresholds,
) !void {
    var state = ComplexityState{};
    var line_num: usize = 1;
    var lines = mem.splitScalar(u8, a.content, '\n');
    while (lines.next()) |line| {
        defer line_num += 1;
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;
        detectFnStart(t, &state, line_num);
        if (!state.in_fn) continue;
        state.fn_lines += 1;
        state.branches += countLineBranches(t);
        if (trackBraceNesting(t, &state)) {
            try reportComplexityIssues(issues, allocator, a.path, &state, th);
            state = .{};
        }
    }
}

fn analyzeComplexity(
    allocator: Allocator,
    graph: *ImportGraph,
    th: Thresholds,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    var iter = graph.files.iterator();
    while (iter.next()) |entry| {
        try analyzeFileComplexity(allocator, &issues, entry.value_ptr.*, th);
    }
    return issues;
}

// ============================================================================
// Style Analysis Helpers
// ============================================================================

/// Calculate visible line length (tabs expand to 4-space boundaries)
fn calculateVisibleLength(line: []const u8) usize {
    var visible_len: usize = 0;
    for (line) |c| {
        if (c == '\t') {
            visible_len = ((visible_len / 4) + 1) * 4;
        } else if (c != '\r') {
            visible_len += 1;
        }
    }
    return visible_len;
}

/// Report file too long issue
fn reportFileTooLong(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    actual: usize,
    max: usize,
) !void {
    const msg = try std.fmt.allocPrint(
        allocator,
        "file has {d} bytes (max {d})",
        .{ actual, max },
    );
    try issues.append(allocator, .{
        .file = path,
        .line = 1,
        .col = 1,
        .severity = .warning,
        .rule = RULE_FILE_TOO_LONG,
        .message = msg,
        .message_owned = true,
        .help = "split into smaller modules",
    });
}

/// Report line too long issue
fn reportLineTooLong(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    line_num: usize,
    visible_len: usize,
    max_len: usize,
) !void {
    const msg = try std.fmt.allocPrint(
        allocator,
        "line has {d} columns (max {d})",
        .{ visible_len, max_len },
    );
    try issues.append(allocator, .{
        .file = path,
        .line = line_num,
        .col = max_len + 1,
        .severity = .warning,
        .rule = RULE_LINE_TOO_LONG,
        .message = msg,
        .message_owned = true,
        .help = "break line or use trailing comma to let zig fmt wrap",
    });
}

fn analyzeStyle(
    allocator: Allocator,
    graph: *ImportGraph,
    th: Thresholds,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    var iter = graph.files.iterator();

    while (iter.next()) |entry| {
        const a = entry.value_ptr.*;

        // ZA702: File too long
        if (th.max_file_bytes) |max_bytes| {
            if (a.content.len > max_bytes) {
                try reportFileTooLong(
                    &issues,
                    allocator,
                    a.path,
                    a.content.len,
                    max_bytes,
                );
            }
        }

        // ZA701: Line too long
        var line_num: usize = 1;
        var lines = mem.splitScalar(u8, a.content, '\n');
        while (lines.next()) |line| {
            defer line_num += 1;
            const trimmed = mem.trimLeft(u8, line, " \t");
            if (mem.startsWith(u8, trimmed, "\\\\")) continue;

            const visible_len = calculateVisibleLength(line);
            if (visible_len > th.max_line_length) {
                try reportLineTooLong(
                    &issues,
                    allocator,
                    a.path,
                    line_num,
                    visible_len,
                    th.max_line_length,
                );
            }
        }
    }
    return issues;
}

// ============================================================================
// Naming Analysis Helpers
// ============================================================================

const NamingContext = struct {
    path: []const u8,
    line: usize,
    col: usize,
    kind: []const u8,
    name: []const u8,
    expected: []const u8,
};

fn reportNamingIssue(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    ctx: NamingContext,
) !void {
    const msg = try std.fmt.allocPrint(
        allocator,
        "{s} '{s}' should be {s}",
        .{ ctx.kind, ctx.name, ctx.expected },
    );
    try issues.append(allocator, .{
        .file = ctx.path,
        .line = ctx.line,
        .col = ctx.col,
        .severity = .warning,
        .rule = RULE_NAMING_CONVENTION,
        .message = msg,
        .message_owned = true,
        .help = ctx.expected,
    });
}

/// Check if this is a function alias (const fooBar = module.fooBar)
fn isFunctionAlias(t: []const u8, name: []const u8) bool {
    if (!isCamelCase(name)) return false;
    const eq_pos = mem.indexOf(u8, t, "= ") orelse return false;
    const rhs = t[eq_pos + 2 ..];
    const dot_pos = mem.indexOf(u8, rhs, ".") orelse return false;
    return mem.startsWith(u8, rhs[dot_pos + 1 ..], name);
}

/// Check if constant naming follows conventions
fn isValidConstName(t: []const u8, name: []const u8) bool {
    if (mem.indexOf(u8, t, "@import(") != null) return true;
    if (isFunctionAlias(t, name)) return true;
    return isSnakeCase(name) or isTitleCase(name) or isScreamingCase(name);
}

fn checkConstNaming(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    t: []const u8,
    line_num: usize,
) !void {
    const plen: usize = if (mem.startsWith(u8, t, "pub const ")) 10 else 6;
    var end = plen;
    while (end < t.len and isIdent(t[end])) end += 1;
    if (end <= plen) return;
    const name = t[plen..end];
    if (name.len > 0 and name[0] == '_') return;

    if (isTypeDefinition(t)) {
        if (!isTitleCase(name)) {
            try reportNamingIssue(issues, allocator, .{
                .path = path,
                .line = line_num,
                .col = plen + 1,
                .kind = "type",
                .name = name,
                .expected = "TitleCase",
            });
        }
    } else if (!isValidConstName(t, name)) {
        try reportNamingIssue(issues, allocator, .{
            .path = path,
            .line = line_num,
            .col = plen + 1,
            .kind = "constant",
            .name = name,
            .expected = "snake_case",
        });
    }
}

fn checkVarNaming(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    t: []const u8,
    line_num: usize,
) !void {
    const prefix: usize = if (mem.startsWith(u8, t, "pub var ")) 8 else 4;
    var end = prefix;
    while (end < t.len and isIdent(t[end])) end += 1;
    if (end <= prefix) return;
    const name = t[prefix..end];
    if (name.len > 0 and name[0] == '_') return;
    if (!isSnakeCase(name)) {
        try reportNamingIssue(issues, allocator, .{
            .path = path,
            .line = line_num,
            .col = prefix + 1,
            .kind = "variable",
            .name = name,
            .expected = "snake_case",
        });
    }
}

fn checkFnNaming(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    t: []const u8,
    line_num: usize,
) !void {
    const fn_pos = mem.indexOf(u8, t, "fn ") orelse return;
    const start = fn_pos + 3;
    var end = start;
    while (end < t.len and isIdent(t[end])) end += 1;
    if (end <= start) return;
    const name = t[start..end];
    if (name.len > 0 and name[0] == '_') return;
    const ret_type = mem.indexOf(u8, t, ") type") != null;
    const is_comptime = mem.indexOf(u8, t, "comptime") != null;
    const returns_type = ret_type or is_comptime;
    if (returns_type and !isTitleCase(name)) {
        try reportNamingIssue(issues, allocator, .{
            .path = path,
            .line = line_num,
            .col = start + 1,
            .kind = "type-returning fn",
            .name = name,
            .expected = "TitleCase",
        });
    } else if (!returns_type and !isCamelCase(name)) {
        try reportNamingIssue(issues, allocator, .{
            .path = path,
            .line = line_num,
            .col = start + 1,
            .kind = "function",
            .name = name,
            .expected = "camelCase",
        });
    }
}

fn analyzeNaming(
    allocator: Allocator,
    graph: *ImportGraph,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    var iter = graph.files.iterator();

    while (iter.next()) |entry| {
        const a = entry.value_ptr.*;
        var line_num: usize = 1;
        var lines = mem.splitScalar(u8, a.content, '\n');

        while (lines.next()) |line| {
            defer line_num += 1;
            const t = mem.trim(u8, line, " \t\r");
            if (isCommentOrMultilineString(t)) continue;

            if (mem.startsWith(u8, t, "const ") or mem.startsWith(u8, t, "pub const ")) {
                try checkConstNaming(&issues, allocator, a.path, t, line_num);
            }
            if (mem.startsWith(u8, t, "var ") or mem.startsWith(u8, t, "pub var ")) {
                try checkVarNaming(&issues, allocator, a.path, t, line_num);
            }
            if (mem.indexOf(u8, t, "fn ") != null) {
                try checkFnNaming(&issues, allocator, a.path, t, line_num);
            }
        }
    }
    return issues;
}

/// Check if name is TitleCase (PascalCase): starts with uppercase, no underscores
fn isTitleCase(name: []const u8) bool {
    if (name.len == 0) return false;
    // Must start with uppercase
    if (name[0] < 'A' or name[0] > 'Z') return false;
    // No underscores allowed (except possibly trailing for reserved word avoidance)
    for (name[0 .. name.len - 1]) |c| {
        if (c == '_') return false;
    }
    return true;
}

/// Check if name is camelCase: starts with lowercase, no underscores
fn isCamelCase(name: []const u8) bool {
    if (name.len == 0) return false;
    // Must start with lowercase
    if (name[0] < 'a' or name[0] > 'z') return false;
    // No underscores allowed
    for (name) |c| {
        if (c == '_') return false;
    }
    return true;
}

/// Check if name is snake_case: all lowercase with underscores
fn isSnakeCase(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        // Allow lowercase, digits, and underscores
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_')) {
            return false;
        }
    }
    return true;
}

/// Check if name is SCREAMING_CASE: all uppercase with underscores
fn isScreamingCase(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!((c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_')) {
            return false;
        }
    }
    return true;
}

/// Check if keyword is followed by valid boundary char
fn isValidTypeBoundary(txt: []const u8, pos: usize, expect_brace: bool) bool {
    if (pos >= txt.len) return true;
    if (!expect_brace) return true;
    const c = txt[pos];
    return c == '{' or c == '(' or c == ' ' or c == '\t';
}

/// Check if a type definition pattern appears in code, not inside a string literal.
fn isTypeDefinition(line: []const u8) bool {
    const eq_pos = mem.indexOf(u8, line, "=") orelse return false;
    const after_eq = line[eq_pos + 1 ..];
    const quote_pos = mem.indexOf(u8, after_eq, "\"");

    const type_kws = [_]struct { kw: []const u8, chk: bool }{
        .{ .kw = " struct", .chk = true },       .{ .kw = " enum", .chk = true },
        .{ .kw = " union", .chk = true },        .{ .kw = " opaque", .chk = true },
        .{ .kw = " error{", .chk = false },      .{ .kw = " packed struct", .chk = true },
        .{ .kw = " packed union", .chk = true }, .{ .kw = " extern struct", .chk = true },
        .{ .kw = " extern union", .chk = true },
    };

    for (type_kws) |pat| {
        const pos = mem.indexOf(u8, after_eq, pat.kw) orelse continue;
        if (quote_pos != null and quote_pos.? < pos) continue;
        if (!isValidTypeBoundary(after_eq, pos + pat.kw.len, pat.chk)) continue;
        return true;
    }
    return false;
}

// ============================================================================
// CFG-Based Memory Analysis (Phase 4)
// ============================================================================

const CFGState = struct {
    func_start: usize = 0,
    func_name: []const u8 = "",
    brace_depth: usize = 0,
    in_func: bool = false,
    fn_returns_error: bool = false,
    // Test block context tracking
    in_test_block: bool = false,
    test_brace_depth: usize = 0,
    // Whether current function started inside a test block
    func_in_test: bool = false,
};

/// Detect function start and initialize state
/// Returns true if a nested function was detected (caller should process current func first)
fn detectCFGFuncStart(t: []const u8, state: *CFGState, line_num: usize) bool {
    if (mem.indexOf(u8, t, "fn ") == null) return false;

    // Check if fn is inside a string or comment (basic check)
    const fn_pos = mem.indexOf(u8, t, "fn ").?;
    if (fn_pos > 0) {
        // Check for common non-function patterns
        const before = t[0..fn_pos];
        if (mem.indexOf(u8, before, "\"") != null) return false; // In string
        if (mem.lastIndexOf(u8, before, "//")) |cp| {
            if (cp < fn_pos) return false; // After comment start
        }
    }

    const name_start = fn_pos + 3;
    var name_end = name_start;
    while (name_end < t.len and isIdent(t[name_end])) name_end += 1;
    if (name_end <= name_start) return false;

    // If already in a function, this is a nested fn - signal to process current first
    const was_in_func = state.in_func;

    state.func_name = t[name_start..name_end];
    state.func_start = line_num;
    state.in_func = true;
    state.brace_depth = 0;
    // Detect if function returns errors: ) ! or !void, !bool, etc.
    state.fn_returns_error = mem.indexOf(u8, t, ") !") != null or
        mem.indexOf(u8, t, "!void") != null or
        mem.indexOf(u8, t, "!bool") != null or
        mem.indexOf(u8, t, "!usize") != null or
        mem.indexOf(u8, t, "!*") != null or
        mem.indexOf(u8, t, "![") != null;

    return was_in_func; // True if we interrupted another function
}

/// Track braces and return true when function ends
fn trackCFGBraces(t: []const u8, state: *CFGState) bool {
    for (t) |c| {
        if (c == '{') state.brace_depth += 1;
        if (c != '}') continue;
        if (state.brace_depth > 0) state.brace_depth -= 1;
        if (state.brace_depth == 0) return true;
    }
    return false;
}

/// Process a single function's analysis (memory, CFG, etc.)
fn processFunction(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    file_path: []const u8,
    func_name: []const u8,
    func_start: usize,
    func_lines_items: []const []const u8,
    fn_returns_error: bool,
    is_in_test_context: bool,
) !void {
    // Run memory analysis
    var func_issues = try analyzeFunction(
        allocator,
        file_path,
        func_start,
        func_lines_items,
    );
    defer func_issues.deinit(allocator);
    try issues.appendSlice(allocator, func_issues.items);

    // Run CFG-based definite assignment analysis (ZA607)
    var cfg = try buildCFG(
        allocator,
        func_name,
        func_start,
        func_lines_items,
    );
    defer cfg.deinit();

    var def_issues = try analyzeDefiniteAssignment(
        allocator,
        &cfg,
        func_lines_items,
        func_start,
    );
    defer def_issues.deinit();

    // Convert definite assignment issues to ZA607 warnings
    var def_iter = def_issues.iterator();
    while (def_iter.next()) |entry| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "variable '{s}' potentially read before assignment",
            .{entry.key_ptr.*},
        );
        try issues.append(allocator, .{
            .file = file_path,
            .line = entry.value_ptr.*,
            .col = 1,
            .severity = .warning,
            .rule = "ZA607",
            .message = msg,
            .help = "ensure variable is assigned on all code paths",
            .message_owned = true,
        });
    }

    // Run CFG-based path-sensitive memory safety analysis (ZA105, ZA106)
    var mem_safety_issues = try analyzeCFGMemorySafety(
        allocator,
        &cfg,
        func_lines_items,
        func_start,
        file_path,
    );
    defer mem_safety_issues.deinit(allocator);
    try issues.appendSlice(allocator, mem_safety_issues.items);

    // Run CFG-based defer coverage analysis (ZA101, ZA102)
    var defer_issues = try analyzeCFGDeferCoverage(
        allocator,
        &cfg,
        func_lines_items,
        func_start,
        file_path,
    );
    defer defer_issues.deinit(allocator);
    try issues.appendSlice(allocator, defer_issues.items);

    // Run CFG-based errdefer coverage analysis (ZA103)
    var errdefer_issues = try analyzeCFGErrdeferCoverage(
        allocator,
        func_lines_items,
        func_start,
        file_path,
        fn_returns_error,
    );
    defer errdefer_issues.deinit(allocator);
    try issues.appendSlice(allocator, errdefer_issues.items);

    // Run CFG-based null safety analysis (ZA801, ZA802)
    var null_safety_issues = try analyzeCFGNullSafety(
        allocator,
        &cfg,
        func_lines_items,
        func_start,
        file_path,
    );
    defer null_safety_issues.deinit(allocator);
    try issues.appendSlice(allocator, null_safety_issues.items);

    // Run CFG-based panic/overflow analysis (ZA901, ZA902, ZA903)
    var panic_issues = try analyzeCFGPanicPatterns(
        allocator,
        &cfg,
        func_lines_items,
        func_start,
        file_path,
    );
    defer panic_issues.deinit(allocator);
    try issues.appendSlice(allocator, panic_issues.items);

    // Run CFG-based error analysis (ZA201, ZA202, ZA203)
    var error_issues = try analyzeCFGErrors(
        allocator,
        &cfg,
        func_lines_items,
        func_start,
        file_path,
        func_name,
        is_in_test_context,
    );
    defer error_issues.deinit(allocator);
    try issues.appendSlice(allocator, error_issues.items);
}

/// Analyze a single file for CFG memory issues
fn analyzeCFGFile(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    content: []const u8,
    file_path: []const u8,
) !void {
    var state = CFGState{};
    var line_num: usize = 1;
    var lines = mem.splitScalar(u8, content, '\n');
    var func_lines = std.ArrayListUnmanaged([]const u8){};
    defer func_lines.deinit(allocator);
    var prev_func_name: []const u8 = "";
    var prev_func_start: usize = 0;
    var prev_func_in_test: bool = false;

    while (lines.next()) |line| {
        defer line_num += 1;
        const t = mem.trim(u8, line, " \t\r");
        const is_comment = isCommentOrMultilineString(t);

        // Track test block context (before function detection)
        if (!is_comment) {
            const ts = trackTestBlock(t, state.in_test_block, state.test_brace_depth);
            state.in_test_block = ts.in_test;
            state.test_brace_depth = ts.depth;
        }

        // Detect function start (skip comments for detection)
        // Returns true if we found a nested function - process previous function first
        if (!is_comment) {
            const was_in_func = state.in_func;
            // Save previous function's state in case we need to process it
            prev_func_name = state.func_name;
            prev_func_start = state.func_start;
            prev_func_in_test = state.func_in_test;
            const found_nested = detectCFGFuncStart(t, &state, line_num);

            // If we started a new function (nested or not), record test context
            if (state.in_func and !was_in_func) {
                // New top-level function started
                state.func_in_test = state.in_test_block;
            } else if (found_nested) {
                // Nested function found - new function starts in current test context
                state.func_in_test = state.in_test_block;

                if (func_lines.items.len > 0) {
                    // Process the previous (outer) function before starting the nested one
                    // Skip if it's too short (likely just a type-returning stub)
                    if (func_lines.items.len >= 3) {
                        try processFunction(allocator, issues, file_path, prev_func_name, prev_func_start, func_lines.items, false, prev_func_in_test);
                    }
                    func_lines.clearRetainingCapacity();
                }
            }
        }
        if (!state.in_func) continue;

        // Always append to keep line numbers aligned (comments skipped during analysis)
        try func_lines.append(allocator, line);

        // Track braces only for non-comments
        if (is_comment) continue;
        if (!trackCFGBraces(t, &state)) continue;

        // Function ended - process it
        // Pass test context: func started inside a test block OR file is a test file
        const is_in_test = state.func_in_test or isInTestContext(file_path, false);
        try processFunction(
            allocator,
            issues,
            file_path,
            state.func_name,
            state.func_start,
            func_lines.items,
            state.fn_returns_error,
            is_in_test,
        );

        state.in_func = false;
        func_lines.clearRetainingCapacity();
    }
}

/// Build a simplified CFG for a function and analyze memory flow
fn analyzeCFGMemory(
    allocator: Allocator,
    graph: *ImportGraph,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    var iter = graph.files.iterator();
    while (iter.next()) |entry| {
        try analyzeCFGFile(allocator, &issues, entry.value_ptr.content, entry.key_ptr.*);
    }
    return issues;
}

// ============================================================================
// analyzeFunction Helpers
// ============================================================================

/// Detect if function can return errors
fn detectErrorReturns(lines: []const []const u8) bool {
    for (lines) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (mem.indexOf(u8, t, ") !") != null) return true;
        if (mem.indexOf(u8, t, "!void") != null) return true;
        if (mem.indexOf(u8, t, "!bool") != null) return true;
        if (mem.indexOf(u8, t, "!usize") != null) return true;
    }
    return false;
}

/// Check if line contains allocation call
fn findAllocCall(t: []const u8) ?struct { col: usize, is_create: bool } {
    if (isPoolAllocator(t)) return null;
    // Check for .alloc( (includes allocator.alloc( as suffix match)
    // Skip Type.alloc() factory patterns (Type starts uppercase)
    if (mem.indexOf(u8, t, ".alloc(")) |col| {
        if (!isPatternInString(t, col) and !isTypeAllocFactory(t, col))
            return .{ .col = col, .is_create = false };
    }
    // Check for .create( (includes allocator.create( as suffix match)
    // Skip Type.create() factory patterns (Type starts uppercase)
    if (mem.indexOf(u8, t, ".create(")) |col| {
        if (!isPatternInString(t, col) and !isTypeAllocFactory(t, col) and isAllocatorCreate(t))
            return .{ .col = col, .is_create = true };
    }
    return null;
}

/// Try to extract allocation from a line
fn tryExtractAllocation(t: []const u8, actual_line: usize, uses_arena: bool) ?AllocInfo {
    const name = extractVarDeclName(t) orelse return null;
    const alloc_call = findAllocCall(t) orelse return null;
    const alloc_name = extractAllocatorName(t) orelse "";
    return AllocInfo{
        .name = name,
        .allocator_name = alloc_name,
        .line = actual_line,
        .col = alloc_call.col + 1,
        .is_create = alloc_call.is_create,
        .is_arena_alloc = uses_arena or isNoFreeAllocatorName(alloc_name),
    };
}

/// Update allocations based on defer patterns in a line
fn updateDefers(t: []const u8, allocs: []AllocInfo) void {
    if (mem.indexOf(u8, t, "defer ") == null) return;
    for (allocs) |*alloc| {
        if (mem.indexOf(u8, t, alloc.name) == null) continue;
        // Check for cleanup patterns (skip if inside string literals)
        if (hasRealCleanupPattern(t)) {
            alloc.has_defer = true;
        }
    }
}

/// Update allocations based on errdefer patterns
fn updateErrdefers(t: []const u8, allocs: []AllocInfo) void {
    if (mem.indexOf(u8, t, "errdefer ") == null) return;
    for (allocs) |*alloc| {
        if (mem.indexOf(u8, t, alloc.name) == null) continue;
        // Check for cleanup patterns (skip if inside string literals)
        if (hasRealCleanupPattern(t)) {
            alloc.has_errdefer = true;
        }
    }
}

/// Report memory leak issue
fn reportMemoryLeak(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    file_path: []const u8,
    alloc: AllocInfo,
) !void {
    const msg = if (alloc.is_create)
        "memory leak: create() result not freed on all paths"
    else
        "memory leak: alloc() result not freed on all paths";

    const help = if (alloc.is_create)
        "add 'defer allocator.destroy(ptr);' or return/store the pointer"
    else
        "add 'defer allocator.free(slice);' or return/store the pointer";

    try issues.append(allocator, .{
        .file = file_path,
        .line = alloc.line,
        .col = alloc.col,
        .severity = .warning,
        .rule = RULE_MEMORY_LEAK,
        .message = msg,
        .help = help,
    });
}

// ============================================================================
// CFG Function Analysis Helpers
// ============================================================================

const AllocLineContext = struct {
    var_name: []const u8,
    actual_line: usize,
    uses_arena: bool,
};

fn detectAllocOnLine(
    t: []const u8,
    ctx: AllocLineContext,
    allocs: *std.ArrayListUnmanaged(AllocInfo),
    allocator: Allocator,
) !void {
    const alloc_call = findAllocCall(t) orelse return;
    const aname = extractAllocatorName(t) orelse "";
    try allocs.append(allocator, .{
        .name = ctx.var_name,
        .allocator_name = aname,
        .line = ctx.actual_line,
        .col = alloc_call.col + 1,
        .is_create = alloc_call.is_create,
        .is_arena_alloc = ctx.uses_arena or isNoFreeAllocatorName(aname),
    });
}

fn trackDeferFrees(
    t: []const u8,
    allocs: []AllocInfo,
    is_errdefer: bool,
) void {
    const keyword = if (is_errdefer) "errdefer " else "defer ";
    if (mem.indexOf(u8, t, keyword) == null) return;
    // Check for cleanup patterns (skip if inside string literals)
    const has_cleanup = hasRealFreePattern(t) or
        hasPatternNotInString(t, "free(") or hasPatternNotInString(t, "destroy(");
    if (!has_cleanup) return;
    for (allocs) |*alloc| {
        if (mem.indexOf(u8, t, alloc.name) != null) {
            if (is_errdefer) {
                alloc.has_errdefer = true;
            } else {
                alloc.has_defer = true;
            }
        }
    }
}

fn trackExplicitFrees(
    t: []const u8,
    actual_line: usize,
    allocs: []AllocInfo,
    _: *std.ArrayListUnmanaged(MemoryEvent), // unused - double-free now in CFG analysis
    _: Allocator, // unused - double-free now in CFG analysis
) !void {
    const has_defer = mem.indexOf(u8, t, "defer ") != null;
    const has_errdefer = mem.indexOf(u8, t, "errdefer ") != null;
    if (has_defer or has_errdefer) return;
    // Use hasRealFreePattern to skip patterns inside string literals
    if (!hasRealFreePattern(t)) return;

    // Check if this free is in a catch/if block that also has a return
    // Pattern: catch { ... .free(...) ... return ...; }
    const is_catch_with_return = mem.indexOf(u8, t, "catch") != null and
        mem.indexOf(u8, t, "return") != null;
    const is_if_with_return = mem.startsWith(u8, t, "if ") and
        mem.indexOf(u8, t, "return") != null;
    const is_early_return_free = is_catch_with_return or is_if_with_return;

    for (allocs) |*alloc| {
        if (mem.indexOf(u8, t, alloc.name) == null) continue;
        // Note: double-free/use-after-free detection now handled by CFG-based
        // analyzeCFGMemorySafety which provides path-sensitive analysis
        alloc.freed_explicitly = true;
        alloc.freed_line = actual_line;
        alloc.freed_in_early_return = is_early_return_free;
    }
}

fn trackUseAfterFree(
    t: []const u8,
    actual_line: usize,
    allocs: []const AllocInfo,
    events: *std.ArrayListUnmanaged(MemoryEvent),
    allocator: Allocator,
) !void {
    const has_defer = mem.indexOf(u8, t, "defer ") != null;
    // Use hasRealFreePattern to skip patterns inside string literals
    if (has_defer or hasRealFreePattern(t)) return;
    const is_decl = mem.startsWith(u8, t, "const ");
    const is_var = mem.startsWith(u8, t, "var ");
    if (is_decl or is_var) return;
    for (allocs) |alloc| {
        const not_freed = !alloc.freed_explicitly;
        const no_line = alloc.freed_line == 0;
        const not_yet = alloc.freed_line >= actual_line;
        if (not_freed or no_line or not_yet) continue;
        // Skip if free was in an early-return block (path-safe)
        // The free only happens on the early-return path, not on the main path
        // TODO: Full CFG analysis would properly track path-sensitive freed state
        if (alloc.freed_in_early_return) continue;
        if (mem.indexOf(u8, t, alloc.name)) |col| {
            try events.append(allocator, .{
                .kind = .use_after_free,
                .alloc_name = alloc.name,
                .alloc_line = alloc.line,
                .freed_line = alloc.freed_line,
                .event_line = actual_line,
                .event_col = col + 1,
            });
        }
    }
}

/// Track multi-line return/store state
const ReturnStoreState = struct {
    in_return: bool = false,
    in_self_assign: bool = false,
    brace_depth: usize = 0,
};

/// Track if line starts a multi-line return or self assignment
fn updateReturnStoreState(t: []const u8, state: *ReturnStoreState) void {
    // Start tracking return statements
    if (mem.startsWith(u8, t, "return ")) {
        state.in_return = true;
        state.brace_depth = 0;
    }

    // Start tracking self.field = .{} assignments
    if (!state.in_self_assign) {
        if ((mem.indexOf(u8, t, "self.") != null or
            mem.indexOf(u8, t, "result.") != null) and
            mem.indexOf(u8, t, "= .{") != null)
        {
            state.in_self_assign = true;
            state.brace_depth = 0;
        }
    }

    // Track brace depth for multi-line constructs
    if (state.in_return or state.in_self_assign) {
        for (t) |c| {
            if (c == '{') state.brace_depth += 1;
            if (c == '}') {
                if (state.brace_depth > 0) state.brace_depth -= 1;
                if (state.brace_depth == 0) {
                    state.in_return = false;
                    state.in_self_assign = false;
                }
            }
        }
        // Single-line without braces
        if (state.brace_depth == 0 and mem.indexOf(u8, t, ";") != null) {
            state.in_return = false;
            state.in_self_assign = false;
        }
    }
}

fn trackReturnAndStore(
    t: []const u8,
    allocs: []AllocInfo,
    state: *ReturnStoreState,
    debug_line: usize, // Added for debugging
) void {
    // Capture state before update
    const was_in_return = state.in_return;
    const was_in_self = state.in_self_assign;
    updateReturnStoreState(t, state);

    // Debug: Track return state changes (disabled for production)
    const debug_enabled = false;
    if (debug_enabled) {
        if (was_in_return or state.in_return) {
            std.debug.print("LINE {}: was_in_return={}, now_in_return={}, brace_depth={}\n", .{ debug_line, was_in_return, state.in_return, state.brace_depth });
            std.debug.print("  content: {s}\n", .{t});
        }
    }

    // Mark allocations as returned if in return statement
    if (was_in_return or mem.startsWith(u8, t, "return ")) {
        for (allocs) |*alloc| {
            if (mem.indexOf(u8, t, alloc.name) != null) {
                if (debug_enabled) std.debug.print("  MARKED RETURNED: {s}\n", .{alloc.name});
                alloc.returned = true;
            }
        }
    }

    // Mark allocations as stored if in self/result assignment
    if (was_in_self or state.in_self_assign) {
        for (allocs) |*alloc| {
            if (mem.indexOf(u8, t, alloc.name) != null) alloc.stored = true;
        }
    }

    // Also handle single-line self.x = alloc patterns
    if (mem.indexOf(u8, t, "self.") != null or mem.indexOf(u8, t, "result.") != null) {
        const eq_pos = mem.indexOf(u8, t, "=") orelse return;
        for (allocs) |*alloc| {
            if (mem.indexOf(u8, t, alloc.name)) |pos| {
                if (pos > eq_pos) alloc.stored = true;
            }
        }
    }

    // Handle general struct.field = alloc patterns (not just self./result.)
    // Pattern: identifier.field = alloc_name (ownership transferred to struct field)
    if (mem.indexOf(u8, t, " = ")) |eq_pos| {
        // Check if LHS is a struct field access (has a dot before the =)
        const lhs = mem.trim(u8, t[0..eq_pos], " \t");
        if (mem.indexOf(u8, lhs, ".") != null) {
            // LHS has a dot, might be struct.field assignment
            for (allocs) |*alloc| {
                if (mem.indexOf(u8, t, alloc.name)) |pos| {
                    if (pos > eq_pos) {
                        // alloc_name is on RHS of assignment to struct field
                        alloc.stored = true;
                    }
                }
            }
        }
    }
}

fn reportLeaks(
    allocs: []const AllocInfo,
    has_err_return: bool,
    file_path: []const u8,
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
) !void {
    for (allocs) |alloc| {
        const skip = alloc.is_arena_alloc or alloc.returned or
            alloc.stored or alloc.ownership_transferred or
            alloc.has_defer or alloc.freed_explicitly;
        if (skip) continue;

        const msg = if (alloc.is_create)
            "memory leak: create() not freed"
        else
            "memory leak: alloc() not freed";

        const help = if (alloc.is_create)
            "add 'defer allocator.destroy(ptr);'"
        else
            "add 'defer allocator.free(slice);'";

        try issues.append(allocator, .{
            .file = file_path,
            .line = alloc.line,
            .col = alloc.col,
            .severity = .warning,
            .rule = RULE_MEMORY_LEAK,
            .message = msg,
            .help = help,
        });

        const needs_errdefer = has_err_return and
            !alloc.has_errdefer and !alloc.returned and
            !alloc.stored and !alloc.ownership_transferred;

        if (needs_errdefer) {
            try issues.append(allocator, .{
                .file = file_path,
                .line = alloc.line,
                .col = alloc.col,
                .severity = .warning,
                .rule = RULE_ALLOC_NO_ERRDEFER,
                .message = "alloc without errdefer",
                .help = "add errdefer to prevent leak",
            });
        }
    }
}

fn reportMemEvents(
    events: []const MemoryEvent,
    file_path: []const u8,
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
) !void {
    for (events) |event| {
        const args = .{ event.alloc_name, event.freed_line };
        const is_uaf = event.kind == .use_after_free;
        const msg = if (is_uaf)
            try std.fmt.allocPrint(
                allocator,
                "use-after-free: '{s}' freed on {d}",
                args,
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "double-free: '{s}' freed on {d}",
                args,
            );
        const rule = if (is_uaf) RULE_USE_AFTER_FREE else RULE_DOUBLE_FREE;
        const help = if (is_uaf)
            "don't access freed memory"
        else
            "remove duplicate free";
        try issues.append(allocator, .{
            .file = file_path,
            .line = event.event_line,
            .col = event.event_col,
            .severity = .err,
            .rule = rule,
            .message = msg,
            .message_owned = true,
            .help = help,
        });
    }
}

/// Mark which lines are inside defer blocks (for use-after-free detection)
/// Frees inside defer blocks execute at scope exit, not at the literal line number
fn markDeferBlockLines(
    allocator: Allocator,
    lines: []const []const u8,
) ![]bool {
    var in_defer = try allocator.alloc(bool, lines.len);
    @memset(in_defer, false);

    var defer_depth: usize = 0;
    for (lines, 0..) |line, idx| {
        const t = mem.trim(u8, line, " \t\r");
        if (mem.startsWith(u8, t, "defer {") or mem.startsWith(u8, t, "defer{")) {
            in_defer[idx] = true;
            for (t) |c| {
                if (c == '{') defer_depth += 1;
                if (c == '}' and defer_depth > 0) defer_depth -= 1;
            }
            continue;
        }
        if (defer_depth > 0) {
            in_defer[idx] = true;
            for (t) |c| {
                if (c == '{') defer_depth += 1;
                if (c == '}' and defer_depth > 0) defer_depth -= 1;
            }
        }
    }
    return in_defer;
}

/// Alias set for tracking data flow through variables
const AliasSet = struct {
    names: std.ArrayListUnmanaged([]const u8),

    fn deinit(self: *AliasSet, allocator: Allocator) void {
        self.names.deinit(allocator);
    }
};

/// Build alias sets by tracking data flow through struct assignments
/// Pattern: const x = Type{ ... alloc_name ... } makes x an alias
fn buildAliasSets(
    allocator: Allocator,
    lines: []const []const u8,
    allocs: []const AllocInfo,
) ![]AliasSet {
    const alias_sets = try allocator.alloc(AliasSet, allocs.len);
    for (alias_sets, 0..) |*as, i| {
        as.* = .{ .names = .{} };
        try as.names.append(allocator, allocs[i].name);
    }

    // Scan for data flow using brace-depth tracking
    var in_struct = false;
    var brace_depth: i32 = 0;
    var struct_var: []const u8 = "";

    for (lines) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;

        // Detect start of struct assignment
        if (!in_struct and mem.indexOf(u8, t, "{") != null and mem.indexOf(u8, t, "= ") != null) {
            if (extractVarDeclName(t)) |name| {
                struct_var = name;
                in_struct = true;
                brace_depth = 0;
            } else if (mem.indexOf(u8, t, ".* = ") != null) {
                var end: usize = 0;
                while (end < t.len and isIdent(t[end])) end += 1;
                if (end > 0) {
                    struct_var = t[0..end];
                    in_struct = true;
                    brace_depth = 0;
                }
            }
        }

        if (in_struct) {
            for (t) |c| {
                if (c == '{') brace_depth += 1;
                if (c == '}') brace_depth -= 1;
            }

            // Find allocation references and add struct var as alias
            var to_update: [64]usize = undefined;
            var count: usize = 0;

            for (alias_sets, 0..) |*as, ai| {
                if (count >= 64) break;
                var found = false;
                for (as.names.items) |alias| {
                    if (mem.indexOf(u8, t, alias) != null) {
                        found = true;
                        break;
                    }
                }
                if (found and struct_var.len > 0 and
                    !mem.eql(u8, struct_var, allocs[ai].name))
                {
                    var exists = false;
                    for (as.names.items) |existing| {
                        if (mem.eql(u8, existing, struct_var)) {
                            exists = true;
                            break;
                        }
                    }
                    if (!exists) {
                        to_update[count] = ai;
                        count += 1;
                    }
                }
            }

            for (to_update[0..count]) |idx| {
                try alias_sets[idx].names.append(allocator, struct_var);
            }

            if (brace_depth <= 0 and mem.indexOf(u8, t, ";") != null) {
                in_struct = false;
                struct_var = "";
            }
        }
    }

    return alias_sets;
}

/// Analyze a single function for memory issues
fn analyzeFunction(
    allocator: Allocator,
    file_path: []const u8,
    func_start: usize,
    lines: []const []const u8,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    var allocs = std.ArrayListUnmanaged(AllocInfo){};
    defer allocs.deinit(allocator);
    var events = std.ArrayListUnmanaged(MemoryEvent){};
    defer events.deinit(allocator);

    const has_err_return = detectErrorReturns(lines);
    const uses_arena = isNoFreeAllocator(lines);
    var return_store_state = ReturnStoreState{};

    // Pre-pass: Mark which lines are inside defer blocks
    const in_defer_block = try markDeferBlockLines(allocator, lines);
    defer allocator.free(in_defer_block);

    // Pass 1: Collect allocations
    for (lines, 0..) |line, idx| {
        const actual_line = func_start + idx;
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;

        if (extractVarDeclName(t)) |var_name| {
            const ctx: AllocLineContext = .{
                .var_name = var_name,
                .actual_line = actual_line,
                .uses_arena = uses_arena,
            };
            try detectAllocOnLine(t, ctx, &allocs, allocator);
        }
    }

    // Pass 2: CFG-based data flow - track aliases (variables that contain allocations)
    const alias_sets = try buildAliasSets(allocator, lines, allocs.items);
    defer {
        for (alias_sets) |*as| as.deinit(allocator);
        allocator.free(alias_sets);
    }

    // Pass 3: Process lines for defer, explicit free, ownership transfer, return/store
    for (lines, 0..) |line, idx| {
        const actual_line = func_start + idx;
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;

        for (allocs.items) |*a| {
            if (isOwnershipTransfer(t, a.name)) a.ownership_transferred = true;
        }
        trackDeferFrees(t, allocs.items, false);
        trackDeferFrees(t, allocs.items, true);
        // Skip tracking explicit frees inside defer blocks - they execute at scope exit
        if (!in_defer_block[idx]) {
            try trackExplicitFrees(t, actual_line, allocs.items, &events, allocator);
        }

        // CFG-based return/store tracking using alias sets
        updateReturnStoreState(t, &return_store_state);
        const in_return = return_store_state.in_return or mem.startsWith(u8, t, "return ");
        const in_self = return_store_state.in_self_assign or
            mem.indexOf(u8, t, "self.") != null or mem.indexOf(u8, t, "ctx.") != null;

        for (alias_sets, 0..) |as, ai| {
            for (as.names.items) |alias| {
                if (mem.indexOf(u8, t, alias) == null) continue;

                if (in_return) allocs.items[ai].returned = true;
                if (in_self) allocs.items[ai].stored = true;

                // Module-level assignment (no const/var prefix, simple identifier LHS)
                if (mem.indexOf(u8, t, " = ") != null and
                    !mem.startsWith(u8, t, "const ") and
                    !mem.startsWith(u8, t, "var "))
                {
                    const eq_pos = mem.indexOf(u8, t, " = ").?;
                    const lhs = mem.trim(u8, t[0..eq_pos], " \t");
                    if (lhs.len > 0 and mem.indexOf(u8, lhs, ".") == null and
                        !mem.eql(u8, lhs, alias))
                    {
                        allocs.items[ai].stored = true;
                    }
                    // Struct field assignment: struct.field = alloc (ownership transfer)
                    // Pattern: deque.buffer = new_buffer, ctx.data = alloc_ptr
                    if (lhs.len > 0 and mem.indexOf(u8, lhs, ".") != null) {
                        // Check if alias is on the RHS (after =)
                        const rhs = t[eq_pos + 3 ..];
                        if (mem.indexOf(u8, rhs, alias) != null) {
                            allocs.items[ai].stored = true;
                        }
                    }
                }

                // Ownership transfer via method call: .put(alias), .append(alias), etc.
                const transfer_methods = [_][]const u8{
                    ".put(", ".putNoClobber(", ".append(", ".appendSlice(",
                    ".insert(", ".add(", ".push(", ".enqueue(", ".submit(",
                };
                for (transfer_methods) |method| {
                    if (mem.indexOf(u8, t, method) != null) {
                        allocs.items[ai].ownership_transferred = true;
                        break;
                    }
                }
            }
        }
    }

    try reportLeaks(allocs.items, has_err_return, file_path, &issues, allocator);
    try reportMemEvents(events.items, file_path, &issues, allocator);
    return issues;
}

// ============================================================================
// Phase 5: Error & Null Safety Analysis
// ============================================================================

// ============================================================================
// Ignored Error Analysis Helpers
// ============================================================================

/// Check if line is a discard pattern with error handling already
fn hasErrorHandling(t: []const u8) bool {
    return mem.indexOf(u8, t, " try ") != null or
        mem.indexOf(u8, t, " catch ") != null or
        mem.startsWith(u8, t, "_ = try ");
}

/// Check if line contains builtin or optional method (safe to discard)
fn isSafeBuiltin(t: []const u8) bool {
    // Builtins that don't return errors
    if (mem.indexOf(u8, t, "@import") != null) return true;
    if (mem.indexOf(u8, t, "@intCast") != null) return true;
    if (mem.indexOf(u8, t, "@ptrCast") != null) return true;
    if (mem.indexOf(u8, t, "@as(") != null) return true;
    if (compat.containsOptionalMethod(t)) return true;

    // Common methods that return values (not errors)
    if (mem.indexOf(u8, t, ".pop()") != null) return true;
    if (mem.indexOf(u8, t, ".orderedRemove(") != null) return true;
    if (mem.indexOf(u8, t, ".swapRemove(") != null) return true;
    if (mem.indexOf(u8, t, ".getLast()") != null) return true;
    if (mem.indexOf(u8, t, ".getLastOrNull()") != null) return true;
    if (mem.indexOf(u8, t, ".get(") != null) return true;
    if (mem.indexOf(u8, t, ".count()") != null) return true;
    if (mem.indexOf(u8, t, ".len") != null) return true;
    if (mem.indexOf(u8, t, ".items") != null) return true;
    if (mem.indexOf(u8, t, ".next()") != null) return true;
    if (mem.indexOf(u8, t, ".peek()") != null) return true;

    return false;
}

/// Check if line is a statement pattern (not assignment/control flow)
fn isStatementPattern(t: []const u8) bool {
    if (!mem.endsWith(u8, t, ");")) return false;
    const skip = [_][]const u8{
        "const ", "var ",   "return ", "try ",   "_ = ",
        "if ",    "while ", "for ",    "defer ", "errdefer ",
        "}",
    };
    for (skip) |prefix| {
        if (mem.startsWith(u8, t, prefix)) return false;
    }
    return mem.indexOf(u8, t, " catch ") == null;
}

/// Check if it's a known void function (safe to not capture result)
fn isKnownVoidFunction(t: []const u8) bool {
    const void_fns = [_][]const u8{
        "print(",   "debug.print", "log.",   "assert(",   "expect(",
        ".deinit(", ".close(",     ".free(", ".destroy(",
    };
    for (void_fns) |fn_name| {
        if (mem.indexOf(u8, t, fn_name) != null) return true;
    }
    return false;
}

/// Check a single line for ignored error pattern
fn checkIgnoredError(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    file_path: []const u8,
    t: []const u8,
    line_num: usize,
) !void {
    const is_discard = mem.startsWith(u8, t, "_ = ") and mem.indexOf(u8, t, "(") != null;
    if (!is_discard or hasErrorHandling(t) or isSafeBuiltin(t)) return;
    try issues.append(allocator, .{
        .file = file_path,
        .line = line_num,
        .col = 1,
        .severity = .note, // Changed from warning - discarding is often intentional
        .rule = RULE_IGNORED_ERROR,
        .message = "function result discarded with '_ ='",
        .help = "if error union, use try/catch; if intentional discard, this can be ignored",
    });
}

/// ZA205: Detect ignored error union results (function returns error but result discarded)
fn analyzeIgnoredErrors(
    allocator: Allocator,
    graph: *ImportGraph,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    var iter = graph.files.iterator();
    while (iter.next()) |entry| {
        const content = entry.value_ptr.content;
        const file_path = entry.key_ptr.*;

        // Skip auto-generated C import files (many false positives)
        if (mem.endsWith(u8, file_path, "cimport.zig")) continue;
        if (isCImportFile(file_path, content)) continue;

        var line_num: usize = 1;
        var lines = mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            defer line_num += 1;
            const t = mem.trim(u8, line, " \t\r");
            if (t.len == 0 or isCommentOrMultilineString(t)) continue;
            try checkIgnoredError(allocator, &issues, file_path, t, line_num);
        }
    }
    return issues;
}

// ============================================================================
// Null Safety Analysis Helpers
// ============================================================================

/// Check if line is in a safe context (if/while condition, orelse, test)
fn isInSafeContext(t: []const u8) bool {
    // Control flow checks
    if (mem.startsWith(u8, t, "if ")) return true;
    if (mem.startsWith(u8, t, "while ")) return true;
    if (mem.startsWith(u8, t, "} else if ")) return true;
    if (mem.indexOf(u8, t, " orelse ") != null) return true;
    // Testing context
    if (mem.indexOf(u8, t, "expect") != null) return true;
    if (mem.indexOf(u8, t, "testing.") != null) return true;
    return false;
}

/// Check if .? unwrap is followed by usage (unsafe)
fn isUnsafeUnwrapUsage(t: []const u8, col: usize) bool {
    if (col + 2 >= t.len) return false;
    const after = mem.trim(u8, t[col + 2 ..], " \t");
    if (after.len == 0) return false;
    return after[0] != ';' and after[0] != ',' and after[0] != ')';
}

/// Check for unsafe .? unwrap (ZA801)
fn checkUnsafeUnwrap(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    t: []const u8,
    line_num: usize,
) !void {
    const col = mem.indexOf(u8, t, ".?") orelse return;
    if (isInSafeContext(t) or !isUnsafeUnwrapUsage(t, col)) return;
    try issues.append(allocator, .{
        .file = path,
        .line = line_num,
        .col = col + 1,
        .severity = .warning,
        .rule = RULE_OPTIONAL_UNWRAP_UNSAFE,
        .message = "optional unwrap (.?) may panic if null",
        .help = "use 'orelse' for safe unwrap, or check for null with 'if'",
    });
}

/// Check for unsafe optional pointer deref (ZA802)
fn checkUnsafeDeref(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    t: []const u8,
    line_num: usize,
) !void {
    const has_maybe = mem.indexOf(u8, t, "maybe_") != null;
    const has_opt = mem.indexOf(u8, t, "opt_") != null;
    if (!has_maybe and !has_opt) return;
    const col = mem.indexOf(u8, t, ".*") orelse return;
    const before = t[0..col];
    const prefix_maybe = mem.indexOf(u8, before, "maybe_") != null;
    const prefix_opt = mem.indexOf(u8, before, "opt_") != null;
    if ((!prefix_maybe and !prefix_opt) or isInSafeContext(t)) return;
    try issues.append(allocator, .{
        .file = path,
        .line = line_num,
        .col = col + 1,
        .severity = .warning,
        .rule = RULE_ORELSE_QUESTION_UNSAFE,
        .message = "dereferencing optional pointer may panic if null",
        .help = "check for null before dereferencing, or use 'orelse'",
    });
}

/// CFG-based null safety analysis (ZA801/ZA802)
/// Uses control flow graph to track null checks across paths
fn analyzeCFGNullSafety(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};

    const num_blocks = cfg.blocks.items.len;
    if (num_blocks == 0) return issues;

    // Track null-checked variables per block (variables known to be non-null)
    var checked_per_block = try allocator.alloc(std.StringHashMapUnmanaged(void), num_blocks);
    defer {
        for (checked_per_block) |*map| map.deinit(allocator);
        allocator.free(checked_per_block);
    }
    for (checked_per_block) |*map| map.* = .{};

    // Phase 1: Identify null checks in each block
    for (cfg.blocks.items, 0..) |block, bid| {
        if (block.start_line == 0 or block.start_line > block.end_line) continue;

        for (block.start_line..block.end_line + 1) |line_num| {
            if (line_num < func_line) continue;
            const idx = line_num - func_line;
            if (idx >= lines.len) continue;
            const t = mem.trim(u8, lines[idx], " \t\r");
            if (isCommentOrMultilineString(t)) continue;

            // Detect null check patterns and extract variable names
            // Pattern: if (x != null) or if (x) |_|
            if (mem.startsWith(u8, t, "if (") or mem.startsWith(u8, t, "} else if (") or
                mem.startsWith(u8, t, "while ("))
            {
                if (extractNullCheckedVar(t)) |var_name| {
                    try checked_per_block[bid].put(allocator, var_name, {});
                }
            }
        }
    }

    // Phase 2: Propagate null-check state through CFG (forward dataflow)
    // A variable is checked if it's checked on ALL predecessor paths
    var changed = true;
    var iterations: usize = 0;
    while (changed and iterations < 100) {
        changed = false;
        iterations += 1;

        for (cfg.blocks.items, 0..) |_, bid| {
            // Get all predecessors of this block
            var preds = std.ArrayListUnmanaged(usize){};
            defer preds.deinit(allocator);
            for (cfg.edges.items) |edge| {
                if (edge.to == bid) {
                    try preds.append(allocator, edge.from);
                }
            }

            // Skip entry block (no predecessors)
            if (preds.items.len == 0) continue;

            // For each variable checked in all predecessors, it's checked here too
            // (unless this block re-assigns it)
            var first_pred = true;
            var intersection: std.StringHashMapUnmanaged(void) = .{};
            defer intersection.deinit(allocator);

            for (preds.items) |pred| {
                if (first_pred) {
                    // Start with first predecessor's set
                    var iter = checked_per_block[pred].iterator();
                    while (iter.next()) |entry| {
                        try intersection.put(allocator, entry.key_ptr.*, {});
                    }
                    first_pred = false;
                } else {
                    // Intersect with other predecessors
                    var to_remove = std.ArrayListUnmanaged([]const u8){};
                    defer to_remove.deinit(allocator);
                    var iter = intersection.iterator();
                    while (iter.next()) |entry| {
                        if (!checked_per_block[pred].contains(entry.key_ptr.*)) {
                            try to_remove.append(allocator, entry.key_ptr.*);
                        }
                    }
                    for (to_remove.items) |key| {
                        _ = intersection.remove(key);
                    }
                }
            }

            // Add intersection to this block's checked set
            var iter = intersection.iterator();
            while (iter.next()) |entry| {
                const gop = try checked_per_block[bid].getOrPut(allocator, entry.key_ptr.*);
                if (!gop.found_existing) changed = true;
            }
        }
    }

    // Phase 3: Check for unsafe unwraps where variable isn't null-checked
    for (cfg.blocks.items, 0..) |block, bid| {
        if (block.start_line == 0 or block.start_line > block.end_line) continue;

        for (block.start_line..block.end_line + 1) |line_num| {
            if (line_num < func_line) continue;
            const idx = line_num - func_line;
            if (idx >= lines.len) continue;
            const t = mem.trim(u8, lines[idx], " \t\r");
            if (isCommentOrMultilineString(t)) continue;

            // Check for .? unwrap
            if (mem.indexOf(u8, t, ".?")) |col| {
                // Skip if in safe context on this line
                if (isInSafeContext(t)) continue;
                if (!isUnsafeUnwrapUsage(t, col)) continue;

                // Extract variable being unwrapped
                if (extractUnwrappedVar(t, col)) |var_name| {
                    // Skip if variable is null-checked on all paths to this point
                    if (checked_per_block[bid].contains(var_name)) continue;

                    try issues.append(allocator, .{
                        .file = file_path,
                        .line = line_num,
                        .col = col + 1,
                        .severity = .warning,
                        .rule = RULE_OPTIONAL_UNWRAP_UNSAFE,
                        .message = "optional unwrap (.?) may panic if null",
                        .help = "use 'orelse' for safe unwrap, or check for null with 'if'",
                    });
                }
            }

            // Check for unsafe deref of optional pointer (maybe_/opt_ prefix)
            if (mem.indexOf(u8, t, ".*")) |col| {
                const before = t[0..col];
                const has_maybe = mem.indexOf(u8, before, "maybe_") != null;
                const has_opt = mem.indexOf(u8, before, "opt_") != null;
                if (!has_maybe and !has_opt) continue;
                if (isInSafeContext(t)) continue;

                // Extract the variable name
                if (extractDerefVar(t, col)) |var_name| {
                    if (checked_per_block[bid].contains(var_name)) continue;

                    try issues.append(allocator, .{
                        .file = file_path,
                        .line = line_num,
                        .col = col + 1,
                        .severity = .warning,
                        .rule = RULE_ORELSE_QUESTION_UNSAFE,
                        .message = "dereferencing optional pointer may panic if null",
                        .help = "check for null before dereferencing, or use 'orelse'",
                    });
                }
            }
        }
    }

    return issues;
}

/// CFG-based error analysis (ZA201, ZA202, ZA203)
/// Uses CFG to understand:
/// - Catch block context (error recovery - silent catch is intentional)
/// - Cleanup function context (deinit, close, destroy, etc.)
/// - Defer block context (best-effort cleanup)
/// - Test block context (nested functions inside tests)
fn analyzeCFGErrors(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
    func_name: []const u8,
    is_in_test_context: bool,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};

    // Check if we're in a cleanup function (deinit, close, etc.)
    const is_cleanup_func = isCleanupFunctionContext(func_name);

    // Analyze each block
    for (cfg.blocks.items) |block| {
        if (block.start_line == 0 or block.start_line > block.end_line) continue;

        // Skip analysis inside catch blocks - error recovery context
        const in_catch_context = block.is_catch_block;

        for (block.start_line..block.end_line + 1) |line_num| {
            if (line_num < func_line) continue;
            const idx = line_num - func_line;
            if (idx >= lines.len) continue;

            const t = mem.trim(u8, lines[idx], " \t\r");
            if (isCommentOrMultilineString(t)) continue;

            // ZA201: Silent catch {} - skip in catch/cleanup/defer context
            // defer catch {} is idiomatic for cleanup that shouldn't propagate errors
            const in_defer_context = mem.startsWith(u8, t, "defer ") or
                mem.startsWith(u8, t, "errdefer ");
            if (!in_catch_context and !is_cleanup_func and !in_defer_context) {
                if (!isBestEffortOperation(t)) {
                    if (mem.indexOf(u8, t, "catch {}")) |col| {
                        if (!isInsideString(t, col)) {
                            try issues.append(allocator, .{
                                .file = file_path,
                                .line = line_num,
                                .col = col + 1,
                                .severity = .warning,
                                .rule = RULE_SILENT_CATCH,
                                .message = "silent catch {} discards error",
                                .help = "use catch |err| with logging, or propagate with try",
                            });
                        }
                    } else if (mem.indexOf(u8, t, "catch |_| {}")) |col| {
                        if (!isInsideString(t, col)) {
                            try issues.append(allocator, .{
                                .file = file_path,
                                .line = line_num,
                                .col = col + 1,
                                .severity = .warning,
                                .rule = RULE_SILENT_CATCH,
                                .message = "silent catch |_| {} discards error",
                                .help = "use catch |err| with logging, or propagate with try",
                            });
                        }
                    }
                }
            }

            // ZA202: catch unreachable - skip in test context (intentional fail-fast)
            // In production code, catch unreachable is dangerous. In tests, it's common.
            // Test context: func name starts with "test " OR function is nested inside a test block
            const is_test_ctx = mem.startsWith(u8, func_name, "test ") or is_in_test_context;
            if (!is_test_ctx) {
                if (mem.indexOf(u8, t, "catch unreachable")) |col| {
                    if (!isInsideString(t, col)) {
                        try issues.append(allocator, .{
                            .file = file_path,
                            .line = line_num,
                            .col = col + 1,
                            .severity = .warning,
                            .rule = RULE_CATCH_UNREACHABLE,
                            .message = "catch unreachable will panic on error",
                            .help = "use explicit error handling",
                        });
                    }
                }
            }

            // ZA203: orelse unreachable - skip in test context (intentional fail-fast)
            if (!is_test_ctx) {
                if (mem.indexOf(u8, t, "orelse unreachable")) |col| {
                    if (!isInsideString(t, col)) {
                        try issues.append(allocator, .{
                            .file = file_path,
                            .line = line_num,
                            .col = col + 1,
                            .severity = .warning,
                            .rule = RULE_ORELSE_UNREACHABLE,
                            .message = "orelse unreachable will panic on null",
                            .help = "use explicit null handling",
                        });
                    }
                }
            }
        }
    }

    return issues;
}

/// Extract variable name from null check pattern
/// Patterns: "if (x != null)", "if (x) |_|", "while (x != null)"
fn extractNullCheckedVar(t: []const u8) ?[]const u8 {
    // Find opening paren
    const open_paren = mem.indexOf(u8, t, "(") orelse return null;
    const after_paren = t[open_paren + 1 ..];

    // Pattern: x != null
    if (mem.indexOf(u8, after_paren, " != null")) |ne_pos| {
        const var_part = mem.trim(u8, after_paren[0..ne_pos], " \t");
        if (var_part.len > 0 and isIdent(var_part[0])) {
            return var_part;
        }
    }

    // Pattern: x == null (inverted check - variable NOT null in else branch)
    // We can't easily track this without more complex analysis, skip for now

    // Pattern: if (x) |_| - capture means x is non-null inside
    if (mem.indexOf(u8, after_paren, ") |")) |pipe_pos| {
        const var_part = mem.trim(u8, after_paren[0..pipe_pos], " \t");
        if (var_part.len > 0 and isIdent(var_part[0])) {
            return var_part;
        }
    }

    return null;
}

/// Extract variable name being unwrapped with .?
fn extractUnwrappedVar(t: []const u8, dot_q_pos: usize) ?[]const u8 {
    if (dot_q_pos == 0) return null;
    // Look backwards for identifier
    const end = dot_q_pos;
    var start = end;
    while (start > 0 and (isIdent(t[start - 1]) or t[start - 1] == '.')) {
        start -= 1;
    }
    if (start < end) return t[start..end];
    return null;
}

/// Extract variable name being dereferenced with .*
fn extractDerefVar(t: []const u8, dot_star_pos: usize) ?[]const u8 {
    if (dot_star_pos == 0) return null;
    const end = dot_star_pos;
    var start = end;
    while (start > 0 and (isIdent(t[start - 1]) or t[start - 1] == '.')) {
        start -= 1;
    }
    if (start < end) return t[start..end];
    return null;
}

/// CFG-based panic/overflow pattern analysis (ZA901/ZA902/ZA903)
/// Uses control flow graph to track guards across paths
fn analyzeCFGPanicPatterns(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};

    const num_blocks = cfg.blocks.items.len;
    if (num_blocks == 0) return issues;

    // Track guarded variables per block (variables with overflow guard)
    var guarded_per_block = try allocator.alloc(std.StringHashMapUnmanaged(void), num_blocks);
    defer {
        for (guarded_per_block) |*map| map.deinit(allocator);
        allocator.free(guarded_per_block);
    }
    for (guarded_per_block) |*map| map.* = .{};

    // Phase 1: Identify guards in each block
    for (cfg.blocks.items, 0..) |block, bid| {
        if (block.start_line == 0 or block.start_line > block.end_line) continue;

        for (block.start_line..block.end_line + 1) |line_num| {
            if (line_num < func_line) continue;
            const idx = line_num - func_line;
            if (idx >= lines.len) continue;
            const t = mem.trim(u8, lines[idx], " \t\r");
            if (isCommentOrMultilineString(t)) continue;

            // Detect guard patterns and extract variable names
            if (extractGuardedVar(t)) |var_name| {
                try guarded_per_block[bid].put(allocator, var_name, {});
            }
        }
    }

    // Phase 2: Propagate guard state through CFG (forward dataflow)
    // Key insight: Guards in conditional blocks only apply to the `then` branch
    var changed = true;
    var iterations: usize = 0;
    while (changed and iterations < 100) {
        changed = false;
        iterations += 1;

        for (cfg.blocks.items, 0..) |_, bid| {
            // Collect predecessors with their edge types
            const PredInfo = struct { block: usize, via_true_branch: bool };
            var preds = std.ArrayListUnmanaged(PredInfo){};
            defer preds.deinit(allocator);
            for (cfg.edges.items) |edge| {
                if (edge.to == bid) {
                    try preds.append(allocator, .{
                        .block = edge.from,
                        .via_true_branch = edge.kind == .branch_true,
                    });
                }
            }

            if (preds.items.len == 0) continue;

            var first_pred = true;
            var intersection: std.StringHashMapUnmanaged(void) = .{};
            defer intersection.deinit(allocator);

            for (preds.items) |pred_info| {
                const pred = pred_info.block;

                // Check if predecessor is a conditional (has both true and false edges)
                const pred_has_both_branches = blk: {
                    var has_true: bool = false;
                    var has_false: bool = false;
                    for (cfg.edges.items) |e| {
                        if (e.from == pred) {
                            if (e.kind == .branch_true) has_true = true;
                            if (e.kind == .branch_false) has_false = true;
                        }
                    }
                    break :blk has_true and has_false;
                };

                if (first_pred) {
                    var iter = guarded_per_block[pred].iterator();
                    while (iter.next()) |entry| {
                        // If coming from conditional via false branch, don't inherit guards
                        // because guards in conditions only apply to true branch
                        if (pred_has_both_branches and !pred_info.via_true_branch) continue;
                        try intersection.put(allocator, entry.key_ptr.*, {});
                    }
                    first_pred = false;
                } else {
                    var to_remove = std.ArrayListUnmanaged([]const u8){};
                    defer to_remove.deinit(allocator);
                    var iter = intersection.iterator();
                    while (iter.next()) |entry| {
                        // Check if this guard should come from this predecessor
                        var should_have_guard = guarded_per_block[pred].contains(entry.key_ptr.*);
                        // If coming via false branch from conditional, pred doesn't provide guard
                        if (pred_has_both_branches and !pred_info.via_true_branch) {
                            should_have_guard = false;
                        }
                        if (!should_have_guard) {
                            try to_remove.append(allocator, entry.key_ptr.*);
                        }
                    }
                    for (to_remove.items) |key| {
                        _ = intersection.remove(key);
                    }
                }
            }

            var iter = intersection.iterator();
            while (iter.next()) |entry| {
                const gop = try guarded_per_block[bid].getOrPut(allocator, entry.key_ptr.*);
                if (!gop.found_existing) changed = true;
            }
        }
    }

    // Phase 3: Check for unguarded decrements and subtractions
    for (cfg.blocks.items, 0..) |block, bid| {
        if (block.start_line == 0 or block.start_line > block.end_line) continue;

        for (block.start_line..block.end_line + 1) |line_num| {
            if (line_num < func_line) continue;
            const idx = line_num - func_line;
            if (idx >= lines.len) continue;
            const t = mem.trim(u8, lines[idx], " \t\r");
            if (isCommentOrMultilineString(t)) continue;

            // Skip test blocks
            if (mem.indexOf(u8, t, "testing.expect") != null) continue;

            // Check for decrement (-= 1) without guard
            if (mem.indexOf(u8, t, "-= 1")) |col| {
                if (isInsideString(t, col)) continue;

                if (extractDecrementVar(t, col)) |var_name| {
                    // Skip if guarded on all paths
                    if (guarded_per_block[bid].contains(var_name)) continue;

                    // Skip if guard on same line
                    if (hasGuardOnLine(t, var_name)) continue;

                    // Skip if guard on prior lines (if (x == 0) break; pattern)
                    if (hasBreakGuardOnPriorLines(lines, idx, var_name)) continue;

                    // Skip signed types (can go negative)
                    if (isSignedVarInContext(lines, idx, var_name)) continue;

                    // Skip if there's a paired increment
                    if (hasPairedIncrementInLines(lines[0..idx], var_name)) continue;

                    try issues.append(allocator, .{
                        .file = file_path,
                        .line = line_num,
                        .col = col + 1,
                        .severity = .warning,
                        .rule = RULE_DECREMENT_WITHOUT_CHECK,
                        .message = "decrement without overflow guard may panic",
                        .help = "add guard (if/while/assert x > 0), use saturating arithmetic (-|), or document caller contract",
                    });
                }
            }

            // Check for array index arithmetic
            if (hasArrayIndexSubtraction(t)) |col| {
                if (isInsideString(t, col)) continue;

                // Skip if saturating subtraction
                if (mem.indexOf(u8, t, "-|") != null) continue;

                // Skip if guard pattern on same line
                if (hasIndexGuardOnLine(t)) continue;

                // Skip if short-circuit guard on prior lines (multi-line expressions)
                if (hasShortCircuitGuardOnPriorLines(lines, idx)) continue;

                // Skip if the array's .len is guarded via CFG
                // Pattern: x[x.len - N] is safe if x.len is guarded
                if (extractArrayBaseFromIndexArithmetic(t)) |base| {
                    // Check if {base}.len is guarded
                    var buf: [128]u8 = undefined;
                    if (base.len + 4 <= buf.len) {
                        @memcpy(buf[0..base.len], base);
                        @memcpy(buf[base.len..][0..4], ".len");
                        const len_var = buf[0 .. base.len + 4];
                        if (guarded_per_block[bid].contains(len_var)) continue;
                    }
                }

                try issues.append(allocator, .{
                    .file = file_path,
                    .line = line_num,
                    .col = col + 1,
                    .severity = .warning,
                    .rule = RULE_INDEX_ARITHMETIC,
                    .message = "arithmetic in array index may overflow",
                    .help = "ensure index arithmetic cannot underflow, or use saturating subtraction -|",
                });
            }
        }
    }

    return issues;
}

/// Extract variable name from guard pattern
/// Patterns: "if (x > 0)", "while (x > 0)", "assert(x > 0)", "x >= 1", "x.len > N"
/// Also: "if (x == 0) return" (early return guard, inverted)
fn extractGuardedVar(t: []const u8) ?[]const u8 {
    // Pattern: x > 0 or x >= 1 or x != 0
    const guard_patterns = [_][]const u8{ "> 0", ">0", ">= 1", ">=1", "!= 0", "!=0" };
    for (guard_patterns) |pattern| {
        if (mem.indexOf(u8, t, pattern)) |pos| {
            // Look backwards for identifier
            var end = pos;
            while (end > 0 and t[end - 1] == ' ') end -= 1;
            var start = end;
            while (start > 0 and (isIdent(t[start - 1]) or t[start - 1] == '.')) {
                start -= 1;
            }
            if (start < end) return t[start..end];
        }
    }

    // Pattern: x.len > N (any positive number) - length guards
    // Find patterns like "x.len > " or "x.len >= " followed by digit
    if (mem.indexOf(u8, t, ".len >")) |pos| {
        // Check if followed by a digit (any threshold)
        const after = pos + ".len >".len;
        if (after < t.len) {
            var check_pos = after;
            // Skip optional '=' for >=
            if (check_pos < t.len and t[check_pos] == '=') check_pos += 1;
            // Skip space
            while (check_pos < t.len and t[check_pos] == ' ') check_pos += 1;
            // Must be followed by a digit
            if (check_pos < t.len and t[check_pos] >= '0' and t[check_pos] <= '9') {
                // Extract the variable before .len
                var end = pos;
                while (end > 0 and t[end - 1] == ' ') end -= 1;
                var start = end;
                while (start > 0 and (isIdent(t[start - 1]) or t[start - 1] == '.')) {
                    start -= 1;
                }
                if (start < end) {
                    // Return "x.len" as the guarded variable
                    const base = t[start..end];
                    _ = base; // We want to return x.len, not just x
                    return t[start .. pos + ".len".len];
                }
            }
        }
    }

    // Pattern: if (x == 0) return/break/continue - early exit guard (inverted check)
    // After this line, x != 0 is true
    const early_exit_patterns = [_][]const u8{ "== 0) return", "== 0) break", "== 0) continue" };
    for (early_exit_patterns) |pattern| {
        if (mem.indexOf(u8, t, pattern)) |pos| {
            // Find opening paren
            if (mem.lastIndexOf(u8, t[0..pos], "(")) |paren_pos| {
                const var_part = mem.trim(u8, t[paren_pos + 1 .. pos], " \t");
                if (var_part.len > 0 and isIdent(var_part[0])) {
                    return var_part;
                }
            }
        }
    }

    return null;
}

/// Extract variable being decremented
fn extractDecrementVar(t: []const u8, decrement_pos: usize) ?[]const u8 {
    var end = decrement_pos;
    while (end > 0 and t[end - 1] == ' ') end -= 1;
    var start = end;
    while (start > 0 and (isIdent(t[start - 1]) or t[start - 1] == '.')) {
        start -= 1;
    }
    if (start < end) return t[start..end];
    return null;
}

/// Check if variable is signed type in context
fn isSignedVarInContext(lines: []const []const u8, current_idx: usize, var_name: []const u8) bool {
    const signed_types = [_][]const u8{ ": i8", ": i16", ": i32", ": i64", ": i128", ": isize" };
    const check_start = if (current_idx > 10) current_idx - 10 else 0;
    for (lines[check_start .. current_idx + 1]) |line| {
        const ctx = mem.trim(u8, line, " \t\r");
        if (mem.indexOf(u8, ctx, var_name)) |var_pos| {
            const after_var = ctx[var_pos + var_name.len ..];
            for (signed_types) |stype| {
                if (mem.startsWith(u8, after_var, stype)) return true;
            }
        }
    }
    return false;
}

/// Check for paired increment in lines
fn hasPairedIncrementInLines(lines: []const []const u8, var_name: []const u8) bool {
    var i = lines.len;
    while (i > 0) {
        i -= 1;
        const ctx = mem.trim(u8, lines[i], " \t\r");
        if (mem.indexOf(u8, ctx, "fn ") != null and mem.indexOf(u8, ctx, "(") != null) {
            return false;
        }
        if (mem.indexOf(u8, ctx, var_name)) |var_pos| {
            const after_var = ctx[var_pos + var_name.len ..];
            if (mem.startsWith(u8, after_var, " += 1") or mem.startsWith(u8, after_var, "+=1")) {
                return true;
            }
        }
    }
    return false;
}

/// Check for short-circuit guard on prior lines (multi-line expressions)
/// Pattern: assert(offset == 0 or switch { .x => values[offset - 1] });
/// Based on Zig short-circuit evaluation - RHS only evaluated when LHS fails
fn hasShortCircuitGuardOnPriorLines(lines: []const []const u8, current_idx: usize) bool {
    // Track brace/paren balance going backwards to find expression start
    var close_parens: usize = 0;
    var close_braces: usize = 0;
    var line_idx = current_idx;

    while (line_idx > 0) {
        line_idx -= 1;
        const ctx = mem.trim(u8, lines[line_idx], " \t\r");
        if (isCommentOrMultilineString(ctx)) continue;

        // Count brackets going backwards (closes before opens as we scan backward)
        for (ctx) |c| {
            if (c == ')') close_parens += 1;
            if (c == '(') {
                if (close_parens > 0) {
                    close_parens -= 1;
                } else {
                    // Found unmatched open paren - we're inside this expression
                    // Check for short-circuit guard patterns
                    if (mem.indexOf(u8, ctx, "== 0 or") != null) return true;
                    if (mem.indexOf(u8, ctx, "!= 0 and") != null) return true;
                    if (mem.indexOf(u8, ctx, "> 0 and") != null) return true;
                }
            }
            if (c == '}') close_braces += 1;
            if (c == '{') {
                if (close_braces > 0) {
                    close_braces -= 1;
                }
            }
        }

        // Check for short-circuit patterns if we're inside multi-line expr
        if (close_parens > 0 or close_braces > 0) {
            if (mem.indexOf(u8, ctx, "== 0 or") != null) return true;
            if (mem.indexOf(u8, ctx, "!= 0 and") != null) return true;
            if (mem.indexOf(u8, ctx, "> 0 and") != null) return true;
        }

        // Stop at statement boundary (balanced and ends with semicolon)
        if (close_parens == 0 and close_braces == 0 and ctx.len > 0 and ctx[ctx.len - 1] == ';') {
            break;
        }

        // Stop at function boundary
        if (mem.indexOf(u8, ctx, "fn ") != null and mem.indexOf(u8, ctx, "(") != null) break;
    }
    return false;
}

/// Check for break/continue guard on prior lines within same loop body
/// Pattern: while (true) { if (x == 0) break; x -= 1; }
/// Based on Zig control flow semantics - break/continue/return exits prevent reaching decrement
fn hasBreakGuardOnPriorLines(lines: []const []const u8, current_idx: usize, var_name: []const u8) bool {
    // Look back up to 5 lines for a guard pattern
    const check_start = if (current_idx > 5) current_idx - 5 else 0;
    for (lines[check_start..current_idx]) |line| {
        const ctx = mem.trim(u8, line, " \t\r");
        // Stop at function boundary - guard in different function doesn't apply
        if (mem.indexOf(u8, ctx, "fn ") != null and mem.indexOf(u8, ctx, "(") != null) return false;
        // Stop at loop boundary - guard in outer loop doesn't apply to inner loop
        // A new while/for creates a new scope where prior guards don't apply
        if (mem.startsWith(u8, ctx, "while ") or mem.startsWith(u8, ctx, "while(")) return false;
        if (mem.startsWith(u8, ctx, "for ") or mem.startsWith(u8, ctx, "for(")) return false;
        // Check for if (var == 0) break/continue/return pattern
        if (mem.indexOf(u8, ctx, var_name)) |_| {
            if (mem.indexOf(u8, ctx, "== 0)") != null) {
                if (mem.indexOf(u8, ctx, "break") != null) return true;
                if (mem.indexOf(u8, ctx, "continue") != null) return true;
                if (mem.indexOf(u8, ctx, "return") != null) return true;
            }
        }
    }
    return false;
}

/// Check for array index subtraction pattern [x - y]
/// Returns position of subtraction if unsafe, null if safe or not found
fn hasArrayIndexSubtraction(t: []const u8) ?usize {
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (t[i] != '[') continue;
        const bracket_start = i;
        var bracket_end: ?usize = null;
        var depth: usize = 1;
        var j = i + 1;
        while (j < t.len) : (j += 1) {
            if (t[j] == '[') depth += 1;
            if (t[j] == ']') {
                if (depth == 1) {
                    bracket_end = j;
                    break;
                }
                if (depth > 1) depth -= 1;
            }
        }
        if (bracket_end) |end| {
            const inside = t[bracket_start + 1 .. end];

            // Skip slice range patterns [0 .. x - N] - bounded by 0 start
            if (mem.indexOf(u8, inside, "..")) |range_pos| {
                // If subtraction is after .., it's part of range end, not index
                if (mem.indexOf(u8, inside, " - ")) |sub_pos| {
                    if (sub_pos > range_pos) {
                        // Check if range starts at 0 - safe pattern
                        const before_range = mem.trim(u8, inside[0..range_pos], " ");
                        if (mem.eql(u8, before_range, "0")) {
                            i = end;
                            continue;
                        }
                    }
                }
            }

            if (mem.indexOf(u8, inside, " - ")) |sub_pos| {
                return bracket_start + sub_pos + 1;
            }
            i = end;
        }
    }
    return null;
}

/// Extract array base variable from index arithmetic pattern
/// e.g., "x[x.len - 8]" -> "x", "in[in.len - 4 ..]" -> "in"
fn extractArrayBaseFromIndexArithmetic(t: []const u8) ?[]const u8 {
    // Find pattern: identifier[identifier.len
    // Look for ".len" inside brackets
    const len_pos = mem.indexOf(u8, t, ".len") orelse return null;

    // Must have [ before .len
    const bracket_pos = mem.lastIndexOf(u8, t[0..len_pos], "[") orelse return null;

    // Extract identifier before [
    var end = bracket_pos;
    while (end > 0 and t[end - 1] == ' ') end -= 1;
    var start = end;
    while (start > 0 and (isIdent(t[start - 1]) or t[start - 1] == '.')) {
        start -= 1;
    }
    if (start < end) return t[start..end];
    return null;
}

/// Check for index guard patterns on same line
fn hasIndexGuardOnLine(t: []const u8) bool {
    // Pattern: while (x > 0 and expr[x - 1])
    if (mem.indexOf(u8, t, "while") != null and mem.indexOf(u8, t, "> 0") != null) return true;
    // Pattern: (i == 0 or t[i - 1]) - short-circuit OR (safe: RHS only evaluated when LHS false)
    if (mem.indexOf(u8, t, "== 0 or") != null) return true;
    // Pattern: (x != 0 and arr[x - 1]) - short-circuit AND (safe: RHS only evaluated when LHS true)
    if (mem.indexOf(u8, t, "!= 0 and") != null) return true;
    if (mem.indexOf(u8, t, "!=0 and") != null) return true;
    // Pattern: x > N and - any numeric guard before array access
    // This covers: > 0 and, > 1 and, >= 1 and, >= 4 and, etc.
    if (mem.indexOf(u8, t, " and ") != null) {
        // Check for any comparison guard: >, >=, !=
        if (mem.indexOf(u8, t, " > ") != null) return true;
        if (mem.indexOf(u8, t, " >= ") != null) return true;
        if (mem.indexOf(u8, t, " != ") != null) return true;
    }
    // Pattern: if (x > N) check before array access on same line
    if (mem.indexOf(u8, t, "if (") != null) {
        if (mem.indexOf(u8, t, "> ") != null) return true;
        if (mem.indexOf(u8, t, ">= ") != null) return true;
    }
    // Pattern: endsWith/startsWith guarantees minimum length
    if (mem.indexOf(u8, t, "endsWith") != null) return true;
    if (mem.indexOf(u8, t, "startsWith") != null) return true;
    return false;
}

/// ZA801/ZA802: Detect unsafe optional unwrapping (legacy line-based - kept for comparison)
fn analyzeNullSafety(
    allocator: Allocator,
    graph: *ImportGraph,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    var iter = graph.files.iterator();
    while (iter.next()) |entry| {
        const file_path = entry.key_ptr.*;
        var line_num: usize = 1;
        var lines_iter = mem.splitScalar(u8, entry.value_ptr.content, '\n');
        while (lines_iter.next()) |line| {
            defer line_num += 1;
            const t = mem.trim(u8, line, " \t\r");
            if (isCommentOrMultilineString(t)) continue;
            try checkUnsafeUnwrap(&issues, allocator, file_path, t, line_num);
            try checkUnsafeDeref(&issues, allocator, file_path, t, line_num);
        }
    }
    return issues;
}

// ============================================================================
// ZA9xx - Panic/Overflow Detection
// ============================================================================

/// Check for decrement without guard (ZA901)
/// Detects patterns like `x -= 1` without a prior `x > 0` check
fn checkDecrementWithoutGuard(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    t: []const u8,
    line_num: usize,
    context_lines: []const []const u8,
    current_idx: usize,
) !void {
    // Look for patterns: x -= 1, depth -= 1, count -= 1, etc.
    const decrement_patterns = [_][]const u8{ "-= 1", " -= 1" };
    for (decrement_patterns) |pattern| {
        if (mem.indexOf(u8, t, pattern)) |col| {
            if (isInsideString(t, col)) continue;

            // Extract variable name (look backwards from -= for identifier)
            var var_end = col;
            while (var_end > 0 and t[var_end - 1] == ' ') var_end -= 1;
            var var_start = var_end;
            while (var_start > 0 and (isIdent(t[var_start - 1]) or t[var_start - 1] == '.')) var_start -= 1;

            if (var_start >= var_end) continue;
            const var_name = t[var_start..var_end];
            if (var_name.len == 0) continue;

            // Check if there's a guard - first check current line for while/if guards
            var has_guard = hasGuardOnLine(t, var_name);

            // Then check preceding lines (up to 5 lines back)
            if (!has_guard) {
                const check_start = if (current_idx > 5) current_idx - 5 else 0;
                for (context_lines[check_start..current_idx]) |ctx_line| {
                    const ctx = mem.trim(u8, ctx_line, " \t\r");
                    if (hasGuardOnLine(ctx, var_name)) {
                        has_guard = true;
                        break;
                    }
                }
            }

            if (!has_guard) {
                // Skip if variable is declared as a signed type (can't overflow)
                const check_start_signed = if (current_idx > 10) current_idx - 10 else 0;
                if (isSignedTypeDecl(context_lines[check_start_signed .. current_idx + 1], var_name)) {
                    continue;
                }

                // Skip if there's a paired increment earlier in the function scope
                // Pattern: x += 1 followed by x -= 1 is safe (paired operations)
                if (hasPairedIncrement(context_lines[0..current_idx], var_name)) {
                    continue;
                }

                try issues.append(allocator, .{
                    .file = path,
                    .line = line_num,
                    .col = col + 1,
                    .severity = .warning,
                    .rule = RULE_DECREMENT_WITHOUT_CHECK,
                    .message = "decrement without overflow guard may panic",
                    .help = "add guard (if/while/assert x > 0), use saturating arithmetic (-|), or document caller contract",
                });
                return; // One issue per line
            }
        }
    }
}

/// Check if there's a paired increment for a variable (x += 1 before x -= 1)
/// or if the variable was initialized to a positive value (x = 1, x = N > 0)
fn hasPairedIncrement(context_lines: []const []const u8, var_name: []const u8) bool {
    // Search backwards from current line for a matching increment or positive init
    // within the same function scope (stop at fn declarations)
    var i = context_lines.len;
    while (i > 0) {
        i -= 1;
        const ctx = mem.trim(u8, context_lines[i], " \t\r");

        // Stop at function boundary - increments in other functions don't count
        if (mem.indexOf(u8, ctx, "fn ") != null and mem.indexOf(u8, ctx, "(") != null) {
            return false;
        }

        // Look for var_name in this line
        if (mem.indexOf(u8, ctx, var_name)) |var_pos| {
            const after_var = ctx[var_pos + var_name.len ..];

            // Pattern 1: x += 1 (paired increment)
            if (mem.startsWith(u8, after_var, " += 1") or
                mem.startsWith(u8, after_var, "+=1") or
                mem.startsWith(u8, after_var, " += 1;") or
                (mem.startsWith(u8, after_var, " = ") and mem.indexOf(u8, after_var, "+ 1") != null))
            {
                return true;
            }

            // Pattern 2: var x: usize = 1 or var x = 1 (positive initialization)
            // This provides a "reserve" that can be decremented safely once
            if (mem.startsWith(u8, ctx, "var ") or mem.startsWith(u8, ctx, "const ")) {
                // Check for = N where N > 0
                if (mem.indexOf(u8, after_var, "= 1") != null or
                    mem.indexOf(u8, after_var, "= 2") != null or
                    mem.indexOf(u8, after_var, "= 3") != null or
                    mem.indexOf(u8, after_var, ": usize = 1") != null or
                    mem.indexOf(u8, after_var, ":usize = 1") != null)
                {
                    return true;
                }
            }
        }
    }
    return false;
}

/// Check if variable is declared as a signed integer type in context
fn isSignedTypeDecl(context_lines: []const []const u8, var_name: []const u8) bool {
    const signed_types = [_][]const u8{ ": i8", ": i16", ": i32", ": i64", ": i128", ": isize" };
    for (context_lines) |ctx_line| {
        const ctx = mem.trim(u8, ctx_line, " \t\r");
        // Look for "var varname: iXX" or "const varname: iXX"
        if (mem.indexOf(u8, ctx, var_name)) |var_pos| {
            const after_var = ctx[var_pos + var_name.len ..];
            for (signed_types) |stype| {
                if (mem.startsWith(u8, after_var, stype)) return true;
            }
        }
    }
    return false;
}

/// Check if a line contains a guard for a variable
fn hasGuardOnLine(line: []const u8, var_name: []const u8) bool {
    // Must contain the variable name
    if (mem.indexOf(u8, line, var_name) == null) return false;

    // Check for common guard patterns:
    // 1. x > 0, x > 1, x >= 1 (simple guards, with or without spaces)
    if (mem.indexOf(u8, line, "> 0") != null) return true;
    if (mem.indexOf(u8, line, ">0") != null) return true;
    if (mem.indexOf(u8, line, "> 1") != null) return true;
    if (mem.indexOf(u8, line, ">1") != null) return true;
    if (mem.indexOf(u8, line, ">= 1") != null) return true;
    if (mem.indexOf(u8, line, ">=1") != null) return true;

    // 2. while (x > ...) : (x -= 1) - guard in while condition
    if (mem.indexOf(u8, line, "while") != null and mem.indexOf(u8, line, ">") != null) return true;

    // 3. if (x == 0) break/return/continue - guard before decrement
    if (mem.indexOf(u8, line, "== 0") != null and
        (mem.indexOf(u8, line, "break") != null or
            mem.indexOf(u8, line, "return") != null or
            mem.indexOf(u8, line, "continue") != null))
    {
        return true;
    }

    // 4. x != 0 (inverted guard) - includes short-circuit AND pattern
    if (mem.indexOf(u8, line, "!= 0") != null) return true;
    if (mem.indexOf(u8, line, "!=0") != null) return true;

    // 5. Short-circuit OR pattern: x == 0 or expr - safe when RHS uses x-1
    if (mem.indexOf(u8, line, "== 0 or") != null) return true;

    // 6. assert(x > 0) - assertion as guard (TigerBeetle pattern)
    if (mem.indexOf(u8, line, "assert") != null) {
        if (mem.indexOf(u8, line, "> 0") != null) return true;
        if (mem.indexOf(u8, line, ">0") != null) return true;
        if (mem.indexOf(u8, line, "> 1") != null) return true;
        if (mem.indexOf(u8, line, ">1") != null) return true;
        if (mem.indexOf(u8, line, ">= 1") != null) return true;
        if (mem.indexOf(u8, line, ">=1") != null) return true;
        if (mem.indexOf(u8, line, "!= 0") != null) return true;
        if (mem.indexOf(u8, line, "!=0") != null) return true;
    }

    // 7. std.debug.assert pattern
    if (mem.indexOf(u8, line, "debug.assert") != null) {
        if (mem.indexOf(u8, line, ">") != null) return true;
        if (mem.indexOf(u8, line, "!=") != null) return true;
    }

    return false;
}

/// Check for subtraction that may overflow (ZA902)
/// Detects patterns like `a - b` for unsigned types without bounds check
fn checkSubtractionOverflow(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    t: []const u8,
    line_num: usize,
    context_lines: []const []const u8,
    current_idx: usize,
) !void {
    // Look for subtraction in specific patterns that are likely problematic:
    // - Array indexing: arr[x - y]
    // - Range creation: for (a..b - 1)
    // - Direct assignment: const idx = x - y;

    // Check for array index subtraction: [something - something]
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (t[i] != '[') continue;
        const bracket_start = i;
        var bracket_end: ?usize = null;
        var depth: usize = 1;
        var j = i + 1;
        while (j < t.len) : (j += 1) {
            if (t[j] == '[') depth += 1;
            if (t[j] == ']') {
                if (depth == 1) {
                    bracket_end = j;
                    break;
                }
                if (depth > 1) depth -= 1;
            }
        }
        if (bracket_end) |end| {
            const inside = t[bracket_start + 1 .. end];
            // Check for subtraction inside brackets
            if (mem.indexOf(u8, inside, " - ")) |sub_pos| {
                // Extract what's being subtracted from
                const before_minus = mem.trim(u8, inside[0..sub_pos], " ");
                if (before_minus.len == 0) continue;

                // Skip if it's using saturating subtraction -|
                if (mem.indexOf(u8, inside, "-|") != null) continue;

                // Check for guard on current line first
                var has_guard = false;
                // Pattern: while (x > 0 and expr[x - 1])
                if (mem.indexOf(u8, t, "while") != null and
                    mem.indexOf(u8, t, "> 0") != null)
                {
                    has_guard = true;
                }
                // Pattern: (i == 0 or t[i - 1]) - short-circuit guards access
                if (mem.indexOf(u8, t, "== 0 or") != null) {
                    has_guard = true;
                }

                // Check for guard in context (previous lines)
                if (!has_guard) {
                    const check_start = if (current_idx > 5) current_idx - 5 else 0;
                    for (context_lines[check_start..current_idx]) |ctx_line| {
                        const ctx = mem.trim(u8, ctx_line, " \t\r");
                        // Look for bounds checking patterns
                        if (mem.indexOf(u8, ctx, ">=") != null or
                            mem.indexOf(u8, ctx, "> ") != null or
                            mem.indexOf(u8, ctx, ".len") != null or
                            // endsWith/startsWith guarantee minimum length
                            mem.indexOf(u8, ctx, "endsWith") != null or
                            mem.indexOf(u8, ctx, "startsWith") != null)
                        {
                            has_guard = true;
                            break;
                        }
                    }
                }

                if (!has_guard) {
                    try issues.append(allocator, .{
                        .file = path,
                        .line = line_num,
                        .col = bracket_start + sub_pos + 2,
                        .severity = .warning,
                        .rule = RULE_INDEX_ARITHMETIC,
                        .message = "arithmetic in array index may overflow",
                        .help = "ensure index arithmetic cannot underflow, or use saturating subtraction -|",
                    });
                    return;
                }
            }
            i = end;
        }
    }

    // Check for range subtraction: for (a..b - 1) or a..b - something
    if (mem.indexOf(u8, t, "..")) |range_pos| {
        const after_range = t[range_pos + 2 ..];
        // Look for subtraction after the range start
        if (mem.indexOf(u8, after_range, " - ")) |sub_in_range| {
            // Skip if inside parentheses (likely a calculation)
            const before_sub = after_range[0..sub_in_range];
            if (mem.indexOf(u8, before_sub, ")") != null) return;

            // Check for guard
            const check_start = if (current_idx > 5) current_idx - 5 else 0;
            var has_guard = false;
            for (context_lines[check_start..current_idx]) |ctx_line| {
                const ctx = mem.trim(u8, ctx_line, " \t\r");
                // Common guard patterns
                if (mem.indexOf(u8, ctx, ">=") != null or
                    mem.indexOf(u8, ctx, "> 0") != null or
                    // Pattern: if (x == 0) return - early return guards later access
                    (mem.indexOf(u8, ctx, "== 0") != null and
                        mem.indexOf(u8, ctx, "return") != null) or
                    // Pattern: endsWith/startsWith - guarantees minimum length
                    mem.indexOf(u8, ctx, "endsWith") != null or
                    mem.indexOf(u8, ctx, "startsWith") != null)
                {
                    has_guard = true;
                    break;
                }
            }

            if (!has_guard) {
                try issues.append(allocator, .{
                    .file = path,
                    .line = line_num,
                    .col = range_pos + 2 + sub_in_range + 1,
                    .severity = .warning,
                    .rule = RULE_SUBTRACTION_OVERFLOW,
                    .message = "subtraction in range may cause overflow if minuend < subtrahend",
                    .help = "ensure range bounds are valid, or add bounds checking",
                });
            }
        }
    }
}

/// ZA9xx: Detect potential panic/overflow patterns
fn analyzePanicPatterns(
    allocator: Allocator,
    graph: *ImportGraph,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    var iter = graph.files.iterator();

    while (iter.next()) |entry| {
        const file_path = entry.key_ptr.*;
        var line_num: usize = 1;
        var lines_list: std.ArrayListUnmanaged([]const u8) = .{};
        defer lines_list.deinit(allocator);

        // Collect all lines for context
        var lines = mem.splitScalar(u8, entry.value_ptr.content, '\n');
        while (lines.next()) |line| {
            try lines_list.append(allocator, line);
        }

        const context_lines = lines_list.items;
        for (context_lines, 0..) |line, idx| {
            defer line_num += 1;
            const t = mem.trim(u8, line, " \t\r");

            // Skip comments
            if (isCommentOrMultilineString(t)) continue;

            // Skip test blocks (intentional panic testing is common)
            if (mem.indexOf(u8, t, "testing.expect") != null) continue;

            try checkDecrementWithoutGuard(&issues, allocator, file_path, t, line_num, context_lines, idx);
            try checkSubtractionOverflow(&issues, allocator, file_path, t, line_num, context_lines, idx);
        }
    }

    return issues;
}

fn runFmtCheck(allocator: Allocator, path: []const u8) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "fmt", "--check", path },
    }) catch |err| {
        std.debug.print("error: cannot run zig fmt: {}\n", .{err});
        return issues;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var lines = mem.splitScalar(u8, result.stderr, '\n');
    while (lines.next()) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (t.len > 0 and mem.endsWith(u8, t, ".zig")) {
            try issues.append(allocator, .{
                .file = t,
                .line = 1,
                .col = 1,
                .severity = .warning,
                .rule = RULE_NEEDS_FORMAT,
                .message = "file needs formatting",
                .help = "run 'zig fmt' to fix",
            });
        }
    }

    return issues;
}

// ============================================================================
// Runtime Analysis (Dynamic Analysis via Test Execution)
// ============================================================================

/// Run tests with Zig's GeneralPurposeAllocator and parse memory diagnostics
fn runRuntimeAnalysis(
    allocator: Allocator,
    path: []const u8,
    verbose: bool,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .{};

    if (verbose) {
        std.debug.print("Running: zig build test (with GPA diagnostics)\n", .{});
    }

    // Run zig build test - GPA produces diagnostics on stderr
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "build", "test" },
        .cwd = path,
        .max_output_bytes = 10 * 1024 * 1024, // 10MB limit for large test output
    }) catch |err| {
        std.debug.print("error: cannot run zig build test: {}\n", .{err});
        return issues;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Parse GPA memory leak output from stderr
    // GPA format: "error(gpa): Memory leak detected at 0x..." or
    //            "error: memory leak at ..."
    try parseGPADiagnostics(allocator, &issues, result.stderr, verbose);

    // Also check stdout for test failures and panics
    try parseTestOutput(allocator, &issues, result.stdout, verbose);

    // Parse exit status - non-zero means test failures
    if (result.term.Exited != 0) {
        // Check if we already captured specific failures
        if (issues.items.len == 0) {
            try issues.append(allocator, .{
                .file = "build.zig",
                .line = 1,
                .col = 1,
                .severity = .err,
                .rule = RULE_RUNTIME_TEST_FAILURE,
                .message = "test suite failed",
                .help = "run 'zig build test' to see details",
            });
        }
    }

    return issues;
}

/// Parse GPA memory diagnostics from stderr
fn parseGPADiagnostics(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    stderr_output: []const u8,
    verbose: bool,
) !void {
    var lines = mem.splitScalar(u8, stderr_output, '\n');

    while (lines.next()) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;

        // Check for memory leak indicators
        if (mem.indexOf(u8, t, "memory leak") != null or
            mem.indexOf(u8, t, "Memory leak") != null)
        {
            if (verbose) {
                std.debug.print("GPA: {s}\n", .{t});
            }

            // Try to extract file:line from stack trace
            const loc = extractFileLocation(t);
            try issues.append(allocator, .{
                .file = loc.file,
                .line = loc.line,
                .col = 1,
                .severity = .err,
                .rule = RULE_RUNTIME_MEMORY_LEAK,
                .message = "memory leak detected at runtime",
                .help = "allocation not freed - check for missing defer or error path",
            });
        }

        // Check for double-free
        if (mem.indexOf(u8, t, "double free") != null or
            mem.indexOf(u8, t, "Double free") != null)
        {
            if (verbose) {
                std.debug.print("GPA: {s}\n", .{t});
            }

            const loc = extractFileLocation(t);
            try issues.append(allocator, .{
                .file = loc.file,
                .line = loc.line,
                .col = 1,
                .severity = .err,
                .rule = RULE_RUNTIME_DOUBLE_FREE,
                .message = "double free detected at runtime",
                .help = "memory freed twice - check defer order and error paths",
            });
        }

        // Check for use-after-free
        if (mem.indexOf(u8, t, "use after free") != null or
            mem.indexOf(u8, t, "Use after free") != null or
            mem.indexOf(u8, t, "freed memory") != null)
        {
            if (verbose) {
                std.debug.print("GPA: {s}\n", .{t});
            }

            const loc = extractFileLocation(t);
            try issues.append(allocator, .{
                .file = loc.file,
                .line = loc.line,
                .col = 1,
                .severity = .err,
                .rule = RULE_RUNTIME_USE_AFTER_FREE,
                .message = "use after free detected at runtime",
                .help = "accessing memory after it was freed",
            });
        }
    }
}

/// Parse test output for failures and panics
fn parseTestOutput(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    stdout_output: []const u8,
    verbose: bool,
) !void {
    var lines = mem.splitScalar(u8, stdout_output, '\n');

    while (lines.next()) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;

        // Check for panics
        if (mem.indexOf(u8, t, "panic:") != null or
            mem.indexOf(u8, t, "thread ") != null and mem.indexOf(u8, t, " panic:") != null)
        {
            if (verbose) {
                std.debug.print("PANIC: {s}\n", .{t});
            }

            const loc = extractFileLocation(t);
            try issues.append(allocator, .{
                .file = loc.file,
                .line = loc.line,
                .col = 1,
                .severity = .err,
                .rule = RULE_RUNTIME_PANIC,
                .message = "panic detected during test execution",
                .help = "runtime panic - check for integer overflow, null pointer, or unreachable",
            });
        }

        // Check for FAIL test markers
        if (mem.startsWith(u8, t, "FAIL")) {
            if (verbose) {
                std.debug.print("TEST FAIL: {s}\n", .{t});
            }

            // Try to extract test name and location
            const loc = extractFileLocation(t);
            try issues.append(allocator, .{
                .file = loc.file,
                .line = loc.line,
                .col = 1,
                .severity = .err,
                .rule = RULE_RUNTIME_TEST_FAILURE,
                .message = "test failed",
                .help = "check test assertions and expected values",
            });
        }
    }
}

/// Extract file:line location from a log line
const FileLocation = struct {
    file: []const u8,
    line: usize,
};

fn extractFileLocation(text: []const u8) FileLocation {
    // Look for pattern: /path/to/file.zig:123 or file.zig:123:45
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        // Find .zig extension
        if (i + 4 < text.len and mem.eql(u8, text[i .. i + 4], ".zig")) {
            // Find start of filename (backtrack to last space or start)
            var start = i;
            while (start > 0 and text[start - 1] != ' ' and text[start - 1] != '\t') {
                start -= 1;
            }

            // Find end (colon followed by digit for line number)
            const file_end = i + 4;
            if (file_end < text.len and text[file_end] == ':') {
                // Parse line number
                var line_end = file_end + 1;
                while (line_end < text.len and text[line_end] >= '0' and text[line_end] <= '9') {
                    line_end += 1;
                }
                if (line_end > file_end + 1) {
                    const line_num = std.fmt.parseInt(usize, text[file_end + 1 .. line_end], 10) catch 0;
                    return .{
                        .file = text[start..file_end],
                        .line = line_num,
                    };
                }
            }

            // No line number, just return file
            return .{
                .file = text[start..file_end],
                .line = 0,
            };
        }
    }

    return .{
        .file = "unknown",
        .line = 0,
    };
}

// ============================================================================
// Utilities
// ============================================================================

fn relativePath(path: []const u8, base: []const u8) []const u8 {
    if (mem.startsWith(u8, path, base)) {
        var rel = path[base.len..];
        while (rel.len > 0 and rel[0] == '/') rel = rel[1..];
        if (rel.len > 0) return rel;
    }
    // Try to strip common absolute path prefix
    if (mem.indexOf(u8, path, "/src/")) |idx| {
        return path[idx + 1 ..];
    }
    // Return as-is if we can't make it relative
    return path;
}

// countOccurrences, countLines, isIdent imported from types.zig

/// Check if a function declaration is a comptime type factory (returns `type`)
/// These functions are used for metaprogramming and legitimately need higher complexity.
/// Examples:
///   fn Bind(Instance: type) type { ... }
///   pub fn Handler(comptime T: type) type { ... }
fn isTypeFactory(line: []const u8) bool {
    // Look for pattern: ") type {" or ") type{" or ") type"
    // This indicates the return type is `type`
    if (mem.indexOf(u8, line, ") type")) |_| return true;
    // Also check for multi-line: function signature ends with ) type
    if (mem.endsWith(u8, mem.trim(u8, line, " \t\r"), ") type")) return true;
    return false;
}

// isInsideString imported from types.zig

/// Check if file path should be excluded from orphan detection
fn isOrphanExcluded(path: []const u8, cfg: *const Config) bool {
    // If user configured patterns, use them
    if (cfg.orphan_exclude.items.len > 0) {
        for (cfg.orphan_exclude.items) |pattern| {
            // Support suffix match (e.g., "_test.zig")
            if (mem.endsWith(u8, path, pattern)) return true;
            // Support contains match (e.g., "/test/")
            if (mem.indexOf(u8, path, pattern) != null) return true;
        }
        return false;
    }

    // Default patterns if no config
    if (mem.endsWith(u8, path, "_test.zig")) return true;
    if (mem.indexOf(u8, path, "/test/") != null) return true;
    if (mem.indexOf(u8, path, "/tests/") != null) return true;
    if (mem.indexOf(u8, path, "/testing/") != null) return true;
    if (mem.indexOf(u8, path, "localhost_testing/") != null) return true;

    return false;
}

/// Count leading whitespace (indentation level)
fn countIndent(line: []const u8) usize {
    var indent: usize = 0;
    for (line) |c| {
        if (c == ' ' or c == '\t') {
            indent += 1;
        } else {
            break;
        }
    }
    return indent;
}

/// Check if file is an auto-generated C import file (should be skipped)
fn isCImportFile(file_path: []const u8, content: []const u8) bool {
    // Skip files ending in cimport.zig
    if (mem.endsWith(u8, file_path, "cimport.zig")) return true;

    // Skip files in deps/ with C translation markers
    if (mem.indexOf(u8, file_path, "/deps/") != null) {
        if (mem.indexOf(u8, content, "__builtin_") != null or
            mem.indexOf(u8, content, "enum_unnamed_") != null or
            mem.indexOf(u8, content, "@cImport") != null)
        {
            return true;
        }
    }
    return false;
}

/// Check if current line has disable directive for rule
fn checkSameLineDisable(line: []const u8, rule: []const u8) bool {
    if (mem.indexOf(u8, line, "// ephor:disable") == null) return false;
    if (mem.indexOf(u8, line, rule) != null) return true;
    // Check for specific rule disable (with rule after directive)
    const has_specific = mem.indexOf(u8, line, "ephor:disable ") != null;
    const has_variant = mem.indexOf(u8, line, "ephor:disable-") != null;
    return !has_specific and !has_variant;
}

/// Check if previous line has disable-next-line directive for rule
fn checkPrevLineDisable(pl: []const u8, rule: []const u8) bool {
    if (mem.indexOf(u8, pl, "// ephor:disable-next-line") == null) return false;
    if (mem.indexOf(u8, pl, rule) != null) return true;
    const disable_idx = mem.indexOf(u8, pl, "disable-next-line") orelse return false;
    const after = pl[disable_idx + 17 ..];
    const trimmed = mem.trim(u8, after, " \t");
    return trimmed.len == 0 or trimmed[0] == '/';
}

/// Check if a line has an inline disable directive for the given rule
fn isInlineDisabled(content: []const u8, line_num: usize, rule: []const u8) bool {
    var current_line: usize = 1;
    var lines = mem.splitScalar(u8, content, '\n');
    var prev_line: ?[]const u8 = null;
    while (lines.next()) |line| {
        defer {
            prev_line = line;
            current_line += 1;
        }
        if (current_line != line_num) continue;
        if (checkSameLineDisable(line, rule)) return true;
        if (prev_line) |pl| {
            if (checkPrevLineDisable(pl, rule)) return true;
        }
        break;
    }
    return false;
}

// ============================================================================
// CLI
// ============================================================================

const Command = enum {
    orphans,
    memory,
    errors,
    unused,
    complexity,
    fmt_check,
    stats,
    check,
    runtime,
    help,
    version,
    init,
    install, // Add ephor to a project's build.zig
    upgrade, // Update ephor to latest version
};

const Config = struct {
    command: Command,
    path: []const u8,
    path_owned: bool,
    entries: std.ArrayListUnmanaged([]const u8),
    exclude: std.ArrayListUnmanaged([]const u8),
    orphan_exclude: std.ArrayListUnmanaged([]const u8),
    disabled_rules: std.ArrayListUnmanaged([]const u8),
    enabled_rules: std.ArrayListUnmanaged([]const u8),
    verbose: bool,
    show_summary: bool,
    format: OutputFormat,
    thresholds: Thresholds,
    init_build: bool, // For `init --build` to also output build.zig integration

    fn deinit(self: *Config, allocator: Allocator) void {
        if (self.path_owned) allocator.free(self.path);
        for (self.entries.items) |e| allocator.free(e);
        self.entries.deinit(allocator);
        for (self.exclude.items) |e| allocator.free(e);
        self.exclude.deinit(allocator);
        for (self.orphan_exclude.items) |e| allocator.free(e);
        self.orphan_exclude.deinit(allocator);
        for (self.disabled_rules.items) |r| allocator.free(r);
        self.disabled_rules.deinit(allocator);
        for (self.enabled_rules.items) |r| allocator.free(r);
        self.enabled_rules.deinit(allocator);
    }

    /// Determine if a rule is enabled considering enable list and disable list
    /// Priority: explicit enable > explicit disable > defaults
    fn isRuleEnabled(self: *const Config, rule: []const u8) bool {
        // Check explicit enable list (highest priority - enables even if disabled)
        for (self.enabled_rules.items) |enabled| {
            if (mem.eql(u8, enabled, rule)) return true;
            // Support prefix matching: "ZA9" enables all ZA9xx rules
            if (enabled.len < rule.len and mem.startsWith(u8, rule, enabled)) return true;
        }

        // Check explicit disable list
        for (self.disabled_rules.items) |disabled| {
            if (mem.eql(u8, disabled, rule)) return false;
            // Support prefix matching: "ZA1" disables all ZA1xx rules
            if (disabled.len < rule.len and mem.startsWith(u8, rule, disabled)) return false;
        }

        // Default: rule is enabled (most rules ON by default per DESIGN.md)
        // Rules that are OFF by default: ZA702, ZA9xx, ZAVxx
        if (mem.eql(u8, rule, RULE_FILE_TOO_LONG)) {
            // ZA702 is OFF by default unless max_file_bytes is set
            return self.thresholds.max_file_bytes != null;
        }
        if (mem.startsWith(u8, rule, "ZAV")) {
            // ZAVxx version checks are OFF by default
            return false;
        }
        // ZA9xx panic/overflow detection is ON by default (critical safety checks)

        return true;
    }

    fn isRuleDisabled(self: *const Config, rule: []const u8) bool {
        return !self.isRuleEnabled(rule);
    }

    fn isPathExcluded(self: *const Config, path: []const u8) bool {
        for (self.exclude.items) |pattern| {
            if (mem.indexOf(u8, path, pattern) != null) return true;
        }
        return false;
    }
};

const CONFIG_FILENAME = "ephor.json";

fn loadConfigFile(allocator: Allocator, cfg: *Config) !void {
    // Try to load ephor.json config file from current directory
    const file = fs.cwd().openFile(CONFIG_FILENAME, .{}) catch return;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 64 * 1024) catch return;
    defer allocator.free(content);

    // Simple JSON parsing for config format
    parseConfigJson(allocator, content, cfg) catch |err| {
        std.debug.print("warning: failed to parse {s}: {}\n", .{ CONFIG_FILENAME, err });
    };
}

/// Try to load ephor.json config from a directory, returning true if found
fn tryLoadConfigFromDir(
    allocator: Allocator,
    cfg: *Config,
    dir: []const u8,
    saved_path: []const u8,
) !bool {
    const config_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ dir, CONFIG_FILENAME },
    );
    defer allocator.free(config_path);

    // Dupe dir BEFORE parsing config, since parseConfigJson might free cfg.path
    // and dir might point to the same memory as cfg.path
    const dir_copy = try allocator.dupe(u8, dir);
    defer allocator.free(dir_copy);

    const file = fs.cwd().openFile(config_path, .{}) catch return false;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 64 * 1024) catch return false;
    defer allocator.free(content);

    parseConfigJson(allocator, content, cfg) catch |err| {
        std.debug.print("warning: failed to parse {s}: {}\n", .{ config_path, err });
        return false;
    };

    if (cfg.path_owned) allocator.free(cfg.path);
    cfg.path = saved_path;
    cfg.path_owned = true;
    try makeEntriesAbsolute(allocator, cfg, dir_copy);
    return true;
}

/// Loads entries from config (CLI path takes priority over config "src")
fn loadConfigFromTargetPath(allocator: Allocator, cfg: *Config, target_path: []const u8) !void {
    const saved_path = try allocator.dupe(u8, cfg.path);
    errdefer allocator.free(saved_path);

    // Try target directory, then parent
    if (try tryLoadConfigFromDir(allocator, cfg, target_path, saved_path)) return;

    if (std.fs.path.dirname(target_path)) |parent| {
        const parent_copy = try allocator.dupe(u8, parent);
        defer allocator.free(parent_copy);
        if (try tryLoadConfigFromDir(allocator, cfg, parent_copy, saved_path)) return;
    }

    allocator.free(saved_path);
}

/// Convert relative entry paths to absolute paths based on config file location
fn makeEntriesAbsolute(allocator: Allocator, cfg: *Config, base_path: []const u8) !void {
    if (base_path.len == 0) return;

    var i: usize = 0;
    while (i < cfg.entries.items.len) : (i += 1) {
        const entry = cfg.entries.items[i];
        // Skip if already absolute
        if (entry.len > 0 and entry[0] == '/') continue;

        // Make relative path absolute
        const abs_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ base_path, entry },
        );
        allocator.free(entry);
        cfg.entries.items[i] = abs_path;
    }
}

/// Parse JSON string value starting at opening quote
fn parseJsonString(content: []const u8, start: usize) struct { val: []const u8, end: usize } {
    var i = start + 1;
    const val_start = i;
    while (i < content.len and content[i] != '"') i += 1;
    return .{ .val = content[val_start..i], .end = i + 1 };
}

/// Skip unknown JSON value (string, array, or object)
fn skipJsonValue(content: []const u8, start: usize) usize {
    var i = start;
    if (i >= content.len) return i;
    if (content[i] == '"') {
        i += 1;
        while (i < content.len and content[i] != '"') i += 1;
        return i + 1;
    }
    const open: u8 = if (content[i] == '[') '[' else if (content[i] == '{') '{' else return i;
    const close: u8 = if (open == '[') ']' else '}';
    var depth: usize = 1;
    i += 1;
    while (i < content.len and depth > 0) : (i += 1) {
        if (content[i] == open) depth += 1;
        if (content[i] == close) depth -= 1;
    }
    return i;
}

/// Set threshold value by key name
fn setThresholdValue(th: *Thresholds, k: []const u8, num: usize) void {
    if (mem.eql(u8, k, "max_lines")) th.max_function_lines = num;
    if (mem.eql(u8, k, "max_nesting")) th.max_nesting_depth = num;
    if (mem.eql(u8, k, "max_params")) th.max_params = num;
    if (mem.eql(u8, k, "max_branches")) th.max_branches = num;
    if (mem.eql(u8, k, "max_line_length")) th.max_line_length = num;
    if (mem.eql(u8, k, "max_file_bytes")) th.max_file_bytes = num;
}

/// Parse threshold key-value pair
fn parseThresholdPair(content: []const u8, start: usize, th: *Thresholds) usize {
    var i = start;
    if (i >= content.len or content[i] != '"') return i + 1;
    const key_result = parseJsonString(content, i);
    i = key_result.end;
    while (i < content.len and content[i] != ':') i += 1;
    i += 1;
    while (i < content.len and (content[i] == ' ' or content[i] == '\t')) i += 1;
    const num_start = i;
    while (i < content.len and content[i] >= '0' and content[i] <= '9') i += 1;
    const num = std.fmt.parseInt(usize, content[num_start..i], 10) catch return i;
    setThresholdValue(th, key_result.val, num);
    return i;
}

/// Parse array of strings into appropriate config list
fn parseConfigArray(
    allocator: Allocator,
    content: []const u8,
    start: usize,
    key: []const u8,
    cfg: *Config,
) !usize {
    var i = start + 1;
    while (i < content.len and content[i] != ']') {
        i = skipWhitespace(content, i, true);
        if (i >= content.len or content[i] == ']') break;
        if (content[i] != '"') {
            i += 1;
            continue;
        }
        const result = parseJsonString(content, i);
        const val = try allocator.dupe(u8, result.val);
        const is_entries = mem.eql(u8, key, "entries");
        const is_exclude = mem.eql(u8, key, "exclude");
        const is_orphan_ex = mem.eql(u8, key, "orphan_exclude");
        const is_disable = mem.eql(u8, key, "disable");
        const is_enable = mem.eql(u8, key, "enable");
        if (is_entries) try cfg.entries.append(allocator, val);
        if (is_exclude) try cfg.exclude.append(allocator, val);
        if (is_orphan_ex) try cfg.orphan_exclude.append(allocator, val);
        if (is_disable) try cfg.disabled_rules.append(allocator, val);
        if (is_enable) try cfg.enabled_rules.append(allocator, val);
        i = result.end;
    }
    return i + 1;
}

/// Parse thresholds object
fn parseThresholdsObject(content: []const u8, start: usize, th: *Thresholds) usize {
    var i = start + 1;
    while (i < content.len and content[i] != '}') {
        i = skipWhitespace(content, i, true);
        if (content[i] == '}') break;
        i = parseThresholdPair(content, i, th);
    }
    return i + 1;
}

/// Handle a single config key-value pair
fn handleConfigKey(
    allocator: Allocator,
    content: []const u8,
    start: usize,
    key: []const u8,
    cfg: *Config,
) !usize {
    if (mem.eql(u8, key, "src") and content[start] == '"') {
        const result = parseJsonString(content, start);
        if (cfg.path_owned) allocator.free(cfg.path);
        cfg.path = try allocator.dupe(u8, result.val);
        cfg.path_owned = true;
        return result.end;
    }
    if (isArrayKey(key) and content[start] == '[') {
        return try parseConfigArray(allocator, content, start, key, cfg);
    }
    if (mem.eql(u8, key, "thresholds") and content[start] == '{') {
        return parseThresholdsObject(content, start, &cfg.thresholds);
    }
    return skipJsonValue(content, start);
}

fn parseConfigJson(allocator: Allocator, content: []const u8, cfg: *Config) !void {
    var i: usize = 0;
    while (i < content.len and content[i] != '{') i += 1;
    if (i >= content.len) return;
    i += 1;
    while (i < content.len) {
        i = skipWhitespace(content, i, true);
        if (i >= content.len or content[i] == '}') break;
        if (content[i] != '"') {
            i += 1;
            continue;
        }
        const key_result = parseJsonString(content, i);
        i = key_result.end;
        while (i < content.len and content[i] != ':') i += 1;
        i = skipWhitespace(content, i + 1, false);
        i = try handleConfigKey(allocator, content, i, key_result.val, cfg);
    }
}

fn isArrayKey(key: []const u8) bool {
    if (mem.eql(u8, key, "entries")) return true;
    if (mem.eql(u8, key, "exclude")) return true;
    if (mem.eql(u8, key, "orphan_exclude")) return true;
    if (mem.eql(u8, key, "disable")) return true;
    if (mem.eql(u8, key, "enable")) return true;
    return false;
}

fn writeDefaultConfig() !void {
    const default_config =
        \\{
        \\  "src": "src",
        \\  "entries": ["src/main.zig", "build.zig"],
        \\  "exclude": ["test", "vendor"],
        \\  "orphan_exclude": ["_test.zig", "/test/", "/tests/"],
        \\  "disable": [],
        \\  "enable": [],
        \\  "thresholds": {
        \\    "max_lines": 50,
        \\    "max_nesting": 4,
        \\    "max_params": 5,
        \\    "max_branches": 10,
        \\    "max_line_length": 100
        \\  }
        \\}
        \\
    ;

    const file = fs.cwd().createFile(CONFIG_FILENAME, .{ .exclusive = true }) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.debug.print("{s} already exists\n", .{CONFIG_FILENAME});
            return;
        }
        return err;
    };
    defer file.close();
    try file.writeAll(default_config);
    std.debug.print("Created {s}\n", .{CONFIG_FILENAME});
}

/// URL for ephor package (used by install command)
const EPHOR_PACKAGE_URL = "https://bitbucket.org/rhyoslabs/ephor/get/main.tar.gz";

/// Code snippet to add to build.zig
const EPHOR_BUILD_SNIPPET =
    \\
    \\    // === Ephor Static Analysis ===
    \\    const ephor_dep = b.dependency("ephor", .{
    \\        .target = target,
    \\        .optimize = .ReleaseSafe,
    \\    });
    \\    const ephor_exe = ephor_dep.artifact("ephor");
    \\    const ephor_cmd = b.addRunArtifact(ephor_exe);
    \\    ephor_cmd.addArgs(&.{ "check", "src/" });
    \\    const ephor_step = b.step("ephor", "Run ephor static analysis");
    \\    ephor_step.dependOn(&ephor_cmd.step);
    \\
;

/// Run the install command: adds ephor to project's build system
fn runInstallCommand(allocator: Allocator) !void {
    // Check if build.zig.zon exists
    const has_zon = blk: {
        fs.cwd().access("build.zig.zon", .{}) catch break :blk false;
        break :blk true;
    };

    if (!has_zon) {
        std.debug.print(
            \\No build.zig.zon found in current directory.
            \\
            \\To add ephor to your project:
            \\
            \\1. Create build.zig.zon with:
            \\
            \\   .{{
            \\       .name = .my_project,
            \\       .version = "0.1.0",
            \\       .dependencies = .{{
            \\           .ephor = .{{
            \\               .url = "{s}",
            \\               // Run 'zig build' to get the hash
            \\           }},
            \\       }},
            \\       .paths = .{{ "build.zig", "build.zig.zon", "src" }},
            \\   }}
            \\
            \\2. Then run: ephor install
            \\
        , .{EPHOR_PACKAGE_URL});
        return;
    }

    // Run zig fetch --save to add the dependency
    std.debug.print("Adding ephor dependency to build.zig.zon...\n", .{});

    var child = std.process.Child.init(
        &.{ "zig", "fetch", "--save=ephor", EPHOR_PACKAGE_URL },
        allocator,
    );

    const term = try child.spawnAndWait();

    if (term.Exited != 0) {
        std.debug.print(
            \\
            \\Failed to fetch ephor package. You can add it manually:
            \\
            \\1. Add to build.zig.zon dependencies:
            \\   .ephor = .{{
            \\       .url = "{s}",
            \\       // Run 'zig build' to get the hash
            \\   }},
            \\
        , .{EPHOR_PACKAGE_URL});
        return;
    }

    std.debug.print("Done! Added ephor to build.zig.zon\n\n", .{});

    // Now try to patch build.zig
    const patched = patchBuildZig(allocator) catch |err| {
        std.debug.print("Could not auto-patch build.zig: {}\n", .{err});
        std.debug.print("\nAdd this to your build.zig manually:{s}\n", .{EPHOR_BUILD_SNIPPET});
        std.debug.print("Then run: zig build ephor\n", .{});
        return;
    };

    if (patched) |line| {
        std.debug.print("Added ephor step to build.zig at line {d}\n\n", .{line});
        std.debug.print("Run: zig build ephor\n", .{});
    } else {
        std.debug.print("Ephor step already exists in build.zig\n\n", .{});
        std.debug.print("Run: zig build ephor\n", .{});
    }
}

/// Patch build.zig to add ephor step. Returns line number where inserted, or null if already exists.
fn patchBuildZig(allocator: Allocator) !?usize {
    const file = fs.cwd().openFile("build.zig", .{ .mode = .read_only }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("No build.zig found in current directory.\n", .{});
            return err;
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
    defer allocator.free(content);

    // Check if ephor is already integrated
    if (mem.indexOf(u8, content, "b.dependency(\"ephor\"") != null or
        mem.indexOf(u8, content, "b.dependency( \"ephor\"") != null)
    {
        return null; // Already has ephor
    }

    // Find insertion point: after last b.installArtifact() or before final }
    var lines: std.ArrayListUnmanaged([]const u8) = .{};
    defer lines.deinit(allocator);

    var line_iter = mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        try lines.append(allocator, line);
    }

    // Find best insertion point
    var insert_after: ?usize = null;
    var last_install_artifact: ?usize = null;
    var build_fn_end: ?usize = null;
    var brace_depth: i32 = 0;
    var in_build_fn = false;

    for (lines.items, 0..) |line, idx| {
        const trimmed = mem.trim(u8, line, " \t");

        // Track if we're in the build function
        if (mem.indexOf(u8, trimmed, "pub fn build(") != null or
            mem.indexOf(u8, trimmed, "fn build(") != null)
        {
            in_build_fn = true;
        }

        if (in_build_fn) {
            // Count braces to find function end
            for (trimmed) |c| {
                if (c == '{') brace_depth += 1;
                if (c == '}') {
                    brace_depth -= 1;
                    if (brace_depth == 0) {
                        build_fn_end = idx;
                        in_build_fn = false;
                    }
                }
            }

            // Look for installArtifact calls
            if (mem.indexOf(u8, line, "installArtifact(") != null or
                mem.indexOf(u8, line, "b.installArtifact(") != null)
            {
                last_install_artifact = idx;
            }
        }
    }

    // Prefer inserting after last installArtifact, otherwise before build function end
    if (last_install_artifact) |idx| {
        insert_after = idx;
    } else if (build_fn_end) |idx| {
        insert_after = if (idx > 0) idx - 1 else 0;
    }

    if (insert_after == null) {
        std.debug.print("Could not find insertion point in build.zig\n", .{});
        return error.NoInsertionPoint;
    }

    // Build new content
    var new_content: std.ArrayListUnmanaged(u8) = .{};
    defer new_content.deinit(allocator);

    for (lines.items, 0..) |line, idx| {
        try new_content.appendSlice(allocator, line);
        try new_content.append(allocator, '\n');

        if (idx == insert_after.?) {
            try new_content.appendSlice(allocator, EPHOR_BUILD_SNIPPET);
        }
    }

    // Write back to file
    const out_file = try fs.cwd().createFile("build.zig", .{});
    defer out_file.close();
    try out_file.writeAll(new_content.items);

    return insert_after.? + 2; // +2 for 1-based line number and the blank line
}

/// Run the upgrade command: updates ephor dependency in build.zig.zon
fn runUpgradeCommand(allocator: Allocator) !void {
    // Check if build.zig.zon exists and has ephor dependency
    const has_ephor = blk: {
        const file = fs.cwd().openFile("build.zig.zon", .{ .mode = .read_only }) catch break :blk false;
        defer file.close();
        const content = file.readToEndAlloc(allocator, 64 * 1024) catch break :blk false;
        defer allocator.free(content);
        break :blk mem.indexOf(u8, content, ".ephor") != null;
    };

    if (!has_ephor) {
        std.debug.print(
            \\No ephor dependency found in build.zig.zon.
            \\
            \\Run 'ephor install' first to add ephor to your project.
            \\
        , .{});
        return;
    }

    std.debug.print("Upgrading ephor to latest version...\n", .{});

    // Run zig fetch --save to update the dependency (fetches latest and updates hash)
    var child = std.process.Child.init(
        &.{ "zig", "fetch", "--save=ephor", EPHOR_PACKAGE_URL },
        allocator,
    );

    const term = try child.spawnAndWait();

    if (term.Exited != 0) {
        std.debug.print("Failed to upgrade ephor.\n", .{});
        return;
    }

    std.debug.print(
        \\Done! Ephor updated to latest version.
        \\
        \\Run 'zig build ephor' to verify.
        \\
    , .{});
}

/// Current ephor version (set at compile time)
const EPHOR_VERSION = "0.7.4";

/// URL to check for latest version
const EPHOR_VERSION_URL = "https://bitbucket.org/rhyoslabs/ephor/raw/main/build.zig.zon";

/// Check for new version at startup (non-blocking, best effort)
/// NOTE: Version check requires the repo to be public. Once published,
/// this will fetch build.zig.zon from EPHOR_VERSION_URL to compare versions.
fn checkForUpdates(allocator: Allocator) void {
    _ = allocator;
    // TODO: Enable once repo is public
    // Version checking is disabled until the repo is published to Bitbucket.
    // Once public, this will:
    // 1. Check ~/.ephor_update_check for cached version (once per day)
    // 2. Fetch latest build.zig.zon from repo
    // 3. Compare versions and show update notice if newer
}

// ============================================================================
// Argument Parsing Helpers
// ============================================================================

fn parseCommand(cmd: []const u8) ?Command {
    const cmds = [_]struct { name: []const u8, cmd: Command }{
        .{ .name = "orphans", .cmd = .orphans },
        .{ .name = "memory", .cmd = .memory },
        .{ .name = "errors", .cmd = .errors },
        .{ .name = "unused", .cmd = .unused },
        .{ .name = "complexity", .cmd = .complexity },
        .{ .name = "fmt-check", .cmd = .fmt_check },
        .{ .name = "stats", .cmd = .stats },
        .{ .name = "check", .cmd = .check },
        .{ .name = "runtime", .cmd = .runtime },
        .{ .name = "init", .cmd = .init },
        .{ .name = "install", .cmd = .install },
        .{ .name = "upgrade", .cmd = .upgrade },
        .{ .name = "update", .cmd = .upgrade }, // Alias
        .{ .name = "--help", .cmd = .help },
        .{ .name = "-h", .cmd = .help },
        .{ .name = "--version", .cmd = .version },
        .{ .name = "-v", .cmd = .version },
    };
    for (cmds) |c| {
        if (mem.eql(u8, cmd, c.name)) return c.cmd;
    }
    return null;
}

fn parseThreshold(arg: []const u8, prefix: []const u8, default: usize) ?usize {
    if (!mem.startsWith(u8, arg, prefix)) return null;
    return std.fmt.parseInt(usize, arg[prefix.len..], 10) catch default;
}

/// Build a path with optional prefix (skips prefix if ".")
fn buildPathWithPrefix(allocator: Allocator, prefix: []const u8, suffix: []const u8) ![]u8 {
    const is_dot = prefix.len == 1 and prefix[0] == '.';
    if (is_dot) {
        return try allocator.dupe(u8, suffix);
    }
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, suffix });
}

fn detectTargetEntries(allocator: Allocator, cfg: *Config) !void {
    for (cfg.entries.items) |e| allocator.free(e);
    cfg.entries.clearRetainingCapacity();
    try loadConfigFromTargetPath(allocator, cfg, cfg.path);
    if (cfg.entries.items.len > 0) return;

    // Track already-added entries
    var added = std.StringHashMap(void).init(allocator);
    defer added.deinit();

    // Standard entry point files in target path
    const files = [_][]const u8{ "main.zig", "lib.zig", "root.zig" };
    for (files) |f| {
        const full = try buildPathWithPrefix(allocator, cfg.path, f);
        fs.cwd().access(full, .{}) catch {
            allocator.free(full);
            continue;
        };
        try cfg.entries.append(allocator, full);
        try added.put(full, {});
    }

    // Also check src/ subdirectory
    const src_files = [_][]const u8{ "src/main.zig", "src/lib.zig", "src/root.zig" };
    for (src_files) |sf| {
        const full = try buildPathWithPrefix(allocator, cfg.path, sf);
        fs.cwd().access(full, .{}) catch {
            allocator.free(full);
            continue;
        };
        if (!added.contains(full)) {
            try cfg.entries.append(allocator, full);
            try added.put(full, {});
        } else {
            allocator.free(full);
        }
    }

    // Parse build.zig in target path for additional entries
    const build_zig_path = try buildPathWithPrefix(allocator, cfg.path, "build.zig");
    defer allocator.free(build_zig_path);
    try extractBuildZigEntriesFromPath(allocator, cfg, build_zig_path, cfg.path, &added);

    // Scan common multi-entry directories in target path
    // Based on patterns found in community projects (ghostty, sig, tigerbeetle, zap, zls, etc.)
    const multi_entry_dirs = [_][]const u8{
        "examples",  "example",   "samples",    "experiments",
        "tools",     "test",      "tests",      "fuzz",
        "benchmark", "benches",   "scripts",    "lib",
        "clients",   "drivers",   "apps",       "cmd",
        "bin",       "ci",        "user",
    };
    for (multi_entry_dirs) |dir| {
        const dir_path = try buildPathWithPrefix(allocator, cfg.path, dir);
        defer allocator.free(dir_path);
        try scanDirForEntriesWithPrefix(allocator, cfg, dir_path, cfg.path, &added);
    }
}

/// Extract entry points from build.zig by parsing common patterns
fn extractBuildZigEntries(allocator: Allocator, cfg: *Config) !void {
    const content = fs.cwd().readFileAlloc(allocator, "build.zig", 1024 * 1024) catch return;
    defer allocator.free(content);

    // Track already-added entries to avoid duplicates
    var added = std.StringHashMap(void).init(allocator);
    defer added.deinit();
    for (cfg.entries.items) |e| {
        added.put(e, {}) catch {};
    }

    var lines = mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        // Pattern 1: .root_source_file = b.path("path/to/file.zig")
        // Pattern 2: .root_source_file = .{ .path = "path/to/file.zig" }
        // Pattern 3: @import("src/something.zig")
        try extractPathFromLine(allocator, cfg, line, &added);
    }
}

/// Extract a .zig path from a build.zig line
fn extractPathFromLine(
    allocator: Allocator,
    cfg: *Config,
    line: []const u8,
    added: *std.StringHashMap(void),
) !void {
    // Pattern: b.path("...")
    if (mem.indexOf(u8, line, "b.path(\"")) |idx| {
        const start = idx + 8; // len of 'b.path("'
        if (extractQuotedPath(line, start)) |path| {
            try addEntryIfValid(allocator, cfg, path, added);
        }
    }
    // Pattern: .path = "..."
    if (mem.indexOf(u8, line, ".path = \"")) |idx| {
        const start = idx + 9; // len of '.path = "'
        if (extractQuotedPath(line, start)) |path| {
            try addEntryIfValid(allocator, cfg, path, added);
        }
    }
    // Pattern: @import("src/...") at top of file (build module imports)
    if (mem.indexOf(u8, line, "@import(\"src/")) |idx| {
        const start = idx + 9; // len of '@import("'
        if (extractQuotedPath(line, start)) |path| {
            try addEntryIfValid(allocator, cfg, path, added);
        }
    }
}

/// Extract path string between quotes
fn extractQuotedPath(line: []const u8, start: usize) ?[]const u8 {
    if (start >= line.len) return null;
    const end_quote = mem.indexOf(u8, line[start..], "\"") orelse return null;
    const path = line[start .. start + end_quote];
    // Only return .zig files
    if (!mem.endsWith(u8, path, ".zig")) return null;
    // Skip standard library imports
    if (mem.startsWith(u8, path, "std")) return null;
    if (mem.startsWith(u8, path, "builtin")) return null;
    return path;
}

/// Add entry if the file exists and isn't already added
fn addEntryIfValid(
    allocator: Allocator,
    cfg: *Config,
    path: []const u8,
    added: *std.StringHashMap(void),
) !void {
    if (added.contains(path)) return;
    fs.cwd().access(path, .{}) catch return;
    const duped = try allocator.dupe(u8, path);
    try cfg.entries.append(allocator, duped);
    try added.put(duped, {});
}

/// Add entry with prefix if the file exists
fn addEntryWithPrefix(
    allocator: Allocator,
    cfg: *Config,
    path: []const u8,
    prefix: []const u8,
    added: *std.StringHashMap(void),
) !void {
    // When prefix is ".", don't add it (avoid "./src/file.zig" paths)
    const is_dot = prefix.len == 1 and prefix[0] == '.';
    const full_path = if (is_dot)
        try allocator.dupe(u8, path)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, path });
    defer allocator.free(full_path);
    if (added.contains(full_path)) return;
    fs.cwd().access(full_path, .{}) catch return;
    const duped = try allocator.dupe(u8, full_path);
    try cfg.entries.append(allocator, duped);
    try added.put(duped, {});
}

/// Extract entry points from a build.zig file at a specific path
fn extractBuildZigEntriesFromPath(
    allocator: Allocator,
    cfg: *Config,
    build_path: []const u8,
    prefix: []const u8,
    added: *std.StringHashMap(void),
) !void {
    const content = fs.cwd().readFileAlloc(allocator, build_path, 1024 * 1024) catch return;
    defer allocator.free(content);

    var lines = mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        // Pattern: b.path("...")
        if (mem.indexOf(u8, line, "b.path(\"")) |idx| {
            const start = idx + 8;
            if (extractQuotedPath(line, start)) |path| {
                try addEntryWithPrefix(allocator, cfg, path, prefix, added);
            }
        }
        // Pattern: .path = "..."
        if (mem.indexOf(u8, line, ".path = \"")) |idx| {
            const start = idx + 9;
            if (extractQuotedPath(line, start)) |path| {
                try addEntryWithPrefix(allocator, cfg, path, prefix, added);
            }
        }
        // Pattern: @import("src/...")
        if (mem.indexOf(u8, line, "@import(\"src/")) |idx| {
            const start = idx + 9;
            if (extractQuotedPath(line, start)) |path| {
                try addEntryWithPrefix(allocator, cfg, path, prefix, added);
            }
        }
    }
}

/// Scan directory with prefix for entry paths
fn scanDirForEntriesWithPrefix(
    allocator: Allocator,
    cfg: *Config,
    dir_path: []const u8,
    prefix: []const u8,
    added: *std.StringHashMap(void),
) !void {
    var dir = fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            const subdir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            defer allocator.free(subdir);
            try scanDirForEntriesWithPrefix(allocator, cfg, subdir, prefix, added);
        } else if (entry.kind == .file and mem.endsWith(u8, entry.name, ".zig")) {
            const is_entry = mem.eql(u8, entry.name, "main.zig") or
                mem.eql(u8, entry.name, "lib.zig") or
                mem.eql(u8, entry.name, "root.zig") or
                mem.endsWith(u8, entry.name, "_test.zig");
            if (is_entry) {
                const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
                if (!added.contains(full)) {
                    fs.cwd().access(full, .{}) catch {
                        allocator.free(full);
                        continue;
                    };
                    try cfg.entries.append(allocator, full);
                    try added.put(full, {});
                } else {
                    allocator.free(full);
                }
            }
        }
    }
}

/// Scan a directory for .zig entry points (main.zig, lib.zig, root.zig)
fn scanDirForEntries(
    allocator: Allocator,
    cfg: *Config,
    dir_path: []const u8,
    added: *std.StringHashMap(void),
) !void {
    var dir = fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            // Recurse into subdirectories
            const subdir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            defer allocator.free(subdir);
            try scanDirForEntries(allocator, cfg, subdir, added);
        } else if (entry.kind == .file and mem.endsWith(u8, entry.name, ".zig")) {
            // Check for entry point files
            const is_entry = mem.eql(u8, entry.name, "main.zig") or
                mem.eql(u8, entry.name, "lib.zig") or
                mem.eql(u8, entry.name, "root.zig") or
                mem.endsWith(u8, entry.name, "_test.zig");
            if (is_entry) {
                const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
                try addEntryIfValid(allocator, cfg, path, added);
                allocator.free(path);
            }
        }
    }
}

fn detectStandardEntries(allocator: Allocator, cfg: *Config) !void {
    // Track already-added entries
    var added = std.StringHashMap(void).init(allocator);
    defer added.deinit();

    const entries = [_][]const u8{ "src/main.zig", "src/lib.zig", "src/root.zig", "build.zig" };
    for (entries) |e| {
        fs.cwd().access(e, .{}) catch continue;
        const duped = try allocator.dupe(u8, e);
        try cfg.entries.append(allocator, duped);
        try added.put(duped, {});
    }

    // Parse build.zig for additional entry points
    try extractBuildZigEntries(allocator, cfg);

    // Update added set with build.zig entries
    for (cfg.entries.items) |e| {
        added.put(e, {}) catch {};
    }

    // Scan common multi-entry directories
    // Based on patterns found in community projects
    const multi_entry_dirs = [_][]const u8{
        "examples",  "example",   "samples",    "experiments",
        "tools",     "test",      "tests",      "fuzz",
        "benchmark", "benches",   "scripts",    "lib",
        "clients",   "drivers",   "apps",       "cmd",
        "bin",       "ci",        "user",
    };
    for (multi_entry_dirs) |dir| {
        try scanDirForEntries(allocator, cfg, dir, &added);
    }

    // Auto-discover test files in src/
    var dir = fs.cwd().openDir("src", .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const is_test_file = entry.kind == .file and mem.endsWith(u8, entry.name, "_test.zig");
        if (!is_test_file) continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "src/{s}",
            .{entry.name},
        );
        if (!added.contains(path)) {
            try cfg.entries.append(allocator, path);
            try added.put(path, {});
        } else {
            allocator.free(path);
        }
    }
}

/// Parse simple flags (returns true if handled)
fn parseSimpleFlag(arg: []const u8, cfg: *Config) bool {
    if (mem.eql(u8, arg, "-V") or mem.eql(u8, arg, "--verbose")) {
        cfg.verbose = true;
        return true;
    }
    if (mem.eql(u8, arg, "-s") or mem.eql(u8, arg, "--summary")) {
        cfg.show_summary = true;
        return true;
    }
    if (mem.eql(u8, arg, "--format=json") or mem.eql(u8, arg, "-f=json")) {
        cfg.format = .json;
        return true;
    }
    if (mem.eql(u8, arg, "--format=text") or mem.eql(u8, arg, "-f=text")) {
        cfg.format = .text;
        return true;
    }
    if (mem.eql(u8, arg, "--build") or mem.eql(u8, arg, "-b")) {
        cfg.init_build = true;
        return true;
    }
    return false;
}

/// Parse threshold arguments (returns true if handled)
fn parseThresholdArg(arg: []const u8, th: *Thresholds) bool {
    if (parseThreshold(arg, "--max-lines=", 50)) |v| {
        th.max_function_lines = v;
        return true;
    }
    if (parseThreshold(arg, "--max-nesting=", 4)) |v| {
        th.max_nesting_depth = v;
        return true;
    }
    if (parseThreshold(arg, "--max-params=", 5)) |v| {
        th.max_params = v;
        return true;
    }
    if (parseThreshold(arg, "--max-line-length=", 100)) |v| {
        th.max_line_length = v;
        return true;
    }
    if (parseThreshold(arg, "--max-file-bytes=", 0)) |v| {
        th.max_file_bytes = if (v > 0) v else null;
        return true;
    }
    return false;
}

/// Parse a single CLI argument
fn parseCliArg(
    allocator: Allocator,
    arg: []const u8,
    cfg: *Config,
    cli_entries: *bool,
) !void {
    if (mem.startsWith(u8, arg, "--entry=")) {
        if (!cli_entries.*) {
            for (cfg.entries.items) |e| allocator.free(e);
            cfg.entries.clearRetainingCapacity();
            cli_entries.* = true;
        }
        try cfg.entries.append(allocator, try allocator.dupe(u8, arg[8..]));
        return;
    }
    if (parseSimpleFlag(arg, cfg)) return;
    if (parseThresholdArg(arg, &cfg.thresholds)) return;
    if (mem.startsWith(u8, arg, "--disable=")) {
        try cfg.disabled_rules.append(allocator, try allocator.dupe(u8, arg[10..]));
        return;
    }
    if (mem.startsWith(u8, arg, "--enable=")) {
        try cfg.enabled_rules.append(allocator, try allocator.dupe(u8, arg[9..]));
        return;
    }
    if (arg[0] != '-') {
        if (cfg.path_owned) allocator.free(cfg.path);
        cfg.path = try allocator.dupe(u8, arg);
        cfg.path_owned = true;
    }
}

fn parseArgs(allocator: Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    var cfg = Config{
        .command = .help,
        .path = "src",
        .path_owned = false,
        .entries = .{},
        .exclude = .{},
        .orphan_exclude = .{},
        .disabled_rules = .{},
        .enabled_rules = .{},
        .verbose = false,
        .show_summary = false,
        .format = .text,
        .thresholds = .{},
        .init_build = false,
    };
    try loadConfigFile(allocator, &cfg);
    var cli_entries = false;
    if (args.next()) |cmd| {
        if (parseCommand(cmd)) |c| {
            cfg.command = c;
        } else {
            if (cfg.path_owned) allocator.free(cfg.path);
            cfg.path = try allocator.dupe(u8, cmd);
            cfg.path_owned = true;
            cfg.command = .check;
        }
    }
    while (args.next()) |arg| try parseCliArg(allocator, arg, &cfg, &cli_entries);
    if (cfg.path_owned and !mem.eql(u8, cfg.path, "src")) try detectTargetEntries(allocator, &cfg);
    if (cfg.entries.items.len == 0) try detectStandardEntries(allocator, &cfg);
    return cfg;
}

fn printHelp() void {
    const help =
        \\Ephor v0.7.2 - The overseer of your Zig code
        \\
        \\Static + Dynamic analysis for Zig (complements zig fmt/build/test)
        \\
        \\OUTPUT FORMAT:
        \\  path:line:col: severity[rule-id]: message
        \\  Compatible with GCC, clang, ESLint, IntelliJ IDEA, VS Code
        \\
        \\USAGE: ephor <command> [path] [options]
        \\
        \\COMMANDS:
        \\  init        Create ephor.json config file
        \\  install     Add ephor to project's build.zig (runs zig fetch)
        \\  upgrade     Update ephor to latest version (alias: update)
        \\  check       Run all static checks (default)
        \\  runtime     Run tests with memory diagnostics (dynamic analysis)
        \\  orphans     Files not imported from entry points
        \\  memory      Alloc without defer patterns
        \\  errors      Silent catch {} discards
        \\  unused      Unused imports/declarations
        \\  complexity  Function complexity metrics
        \\  fmt-check   Files needing zig fmt (runs zig fmt --check)
        \\  stats       Project statistics
        \\
        \\OPTIONS:
        \\  --entry=<file>       Entry point (default: src/main.zig)
        \\  --format=text|json   Output format (default: text)
        \\  --disable=<rule>     Disable rule (e.g., ZA301, ZA1)
        \\  --enable=<rule>      Enable rule (overrides disable)
        \\  --max-lines=N        Max function lines (default: 50)
        \\  --max-nesting=N      Max nesting depth (default: 4)
        \\  --max-params=N       Max parameters (default: 5)
        \\  --max-line-length=N  Max columns per line (default: 100)
        \\  --max-file-bytes=N   Max file size in bytes (optional)
        \\  -V, --verbose        Verbose output
        \\  -s, --summary        Show summary at end
        \\  -b, --build          With 'init': also show build.zig integration
        \\
        \\CONFIG FILE (ephor.json):
        \\  {
        \\    "src": "src",
        \\    "entries": ["src/main.zig", "build.zig"],
        \\    "exclude": ["test", "vendor"],
        \\    "disable": ["ZA301"],
        \\    "enable": ["ZA702"],
        \\    "thresholds": {
        \\      "max_lines": 50,
        \\      "max_nesting": 4,
        \\      "max_params": 5,
        \\      "max_branches": 10,
        \\      "max_line_length": 100,
        \\      "max_file_bytes": 25000
        \\    }
        \\  }
        \\
        \\INLINE DISABLE (in source code):
        \\  // ephor:disable ZA201           (disable rule on this line)
        \\  // ephor:disable-next-line ZA201 (disable rule on next line)
        \\  // ephor:disable                 (disable all rules on line)
        \\
        \\RULE IDS:
        \\  ZA1xx  Memory     (ZA101: alloc-no-defer, ZA102: create-no-defer,
        \\                     ZA103: alloc-no-errdefer, ZA104: memory-leak,
        \\                     ZA105: use-after-free, ZA106: double-free)
        \\  ZA2xx  Errors     (ZA201: silent-catch, ZA202: catch-unreachable,
        \\                     ZA203: orelse-unreachable, ZA204: undefined-usage,
        \\                     ZA205: ignored-error)
        \\  ZA8xx  NullSafety (ZA801: unsafe-optional-unwrap, ZA802: unsafe-deref)
        \\  ZA9xx  Panic      (ZA901: decrement-no-guard, ZA902: subtraction-overflow,
        \\                     ZA903: index-arithmetic)
        \\  ZA3xx  Complexity (ZA301: func-too-long, ZA302: nesting-too-deep,
        \\                     ZA303: too-many-params, ZA304: too-many-branches)
        \\  ZA4xx  Unused     (ZA401: unused-import, ZA402: unused-const,
        \\                     ZA403: unused-var)
        \\  ZA5xx  Structure  (ZA501: orphan-file)
        \\  ZA6xx  Format     (ZA601: needs-format)
        \\  ZA7xx  Style      (ZA701: line-too-long, ZA702: file-too-long, ZA703: naming)
        \\  ZR1xx  Runtime    (ZR101: memory-leak, ZR102: use-after-free,
        \\                     ZR103: double-free, ZR104: invalid-free)
        \\
        \\RUNTIME ANALYSIS (ephor runtime):
        \\  Runs 'zig build test' with GeneralPurposeAllocator diagnostics enabled.
        \\  Detects actual memory leaks, use-after-free, double-free at runtime.
        \\  Requires project to use std.testing.allocator or accept allocator param.
        \\
        \\INTELLIJ IDEA SETUP:
        \\  1. Settings > Tools > External Tools > Add
        \\  2. Program: /path/to/ephor
        \\  3. Arguments: check $FileDir$
        \\  4. Output filters: $FILE_PATH$:$LINE$:$COLUMN$:.*
        \\
        \\EXAMPLES:
        \\  ephor init                          # Create config file
        \\  ephor check                         # Run static analysis
        \\  ephor runtime                       # Run dynamic analysis (tests)
        \\  ephor check src/                    # Explicit path
        \\  ephor memory --disable=ZA102       # Disable specific rule
        \\  ephor check --enable=ZA702         # Enable specific rule
        \\
        \\Ephor - Rhyos Labs - https://bitbucket.org/rhyoslabs/ephor
        \\
    ;
    std.debug.print("{s}", .{help});
}

// ============================================================================
// Output
// ============================================================================

/// Check if issue should be printed based on config filters
fn shouldPrintIssue(issue: Issue, cfg: *const Config) bool {
    if (!std.mem.startsWith(u8, issue.file, cfg.path)) return false;
    if (cfg.isRuleDisabled(issue.rule)) return false;
    if (cfg.isPathExcluded(issue.file)) return false;
    return true;
}

fn printIssues(
    issues: []const Issue,
    base_path: []const u8,
    format: OutputFormat,
    title: []const u8,
    cfg: *const Config,
) usize {
    var count: usize = 0;
    for (issues) |issue| {
        if (shouldPrintIssue(issue, cfg)) count += 1;
    }
    if (format == .json) {
        std.debug.print(
            "{{\n  \"analyzer\": \"{s}\",\n  \"count\": {d},\n  \"issues\": [\n",
            .{ title, count },
        );
        var printed: usize = 0;
        for (issues) |issue| {
            if (!shouldPrintIssue(issue, cfg)) continue;
            printed += 1;
            issue.printJson(base_path, printed == count);
        }
        std.debug.print("  ]\n}}\n", .{});
    } else {
        for (issues) |issue| {
            if (!shouldPrintIssue(issue, cfg)) continue;
            issue.printText(base_path);
        }
    }
    return count;
}

fn printStats(s: ProjectStats, format: OutputFormat) void {
    if (format == .json) {
        std.debug.print(
            \\{{
            \\  "files": {d},
            \\  "total_lines": {d},
            \\  "code_lines": {d},
            \\  "comment_lines": {d},
            \\  "blank_lines": {d},
            \\  "public_functions": {d},
            \\  "tests": {d},
            \\  "files_with_tests": {d},
            \\  "not_implemented": {d},
            \\  "todos": {d}
            \\}}
            \\
        , .{
            s.total_files,
            s.total_lines,
            s.code_lines,
            s.comment_lines,
            s.blank_lines,
            s.pub_fn_count,
            s.test_count,
            s.files_with_tests,
            s.not_implemented_count,
            s.todo_count,
        });
    } else {
        std.debug.print(
            \\ephor stats
            \\
            \\Files:          {d}
            \\Total Lines:    {d}
            \\  Code:         {d}
            \\  Comments:     {d}
            \\  Blank:        {d}
            \\
            \\Public funcs:   {d}
            \\Tests:          {d}
            \\Files w/tests:  {d} ({d}%)
            \\
            \\NotImplemented: {d}
            \\TODO/FIXME:     {d}
            \\
        , .{
            s.total_files,
            s.total_lines,
            s.code_lines,
            s.comment_lines,
            s.blank_lines,
            s.pub_fn_count,
            s.test_count,
            s.files_with_tests,
            if (s.total_files > 0) s.files_with_tests * 100 / s.total_files else 0,
            s.not_implemented_count,
            s.todo_count,
        });
    }
}

const IssueCounts = struct {
    orphan: usize = 0,
    memory: usize = 0,
    err: usize = 0,
    unused: usize = 0,
    complexity: usize = 0,
    fmt: usize = 0,
    style: usize = 0,
    null_safety: usize = 0,
    panic: usize = 0,
};

fn printSummary(counts: IssueCounts, s: ProjectStats, format: OutputFormat) void {
    const total = counts.orphan + counts.memory + counts.err + counts.unused +
        counts.complexity + counts.fmt + counts.style + counts.null_safety + counts.panic;

    if (format == .json) {
        std.debug.print(
            \\{{
            \\  "summary": {{
            \\    "files": {d},
            \\    "code_lines": {d},
            \\    "issues": {{
            \\      "orphans": {d},
            \\      "memory": {d},
            \\      "errors": {d},
            \\      "unused": {d},
            \\      "complexity": {d},
            \\      "format": {d},
            \\      "style": {d},
            \\      "null_safety": {d},
            \\      "panic": {d},
            \\      "total": {d}
            \\    }},
            \\    "quality": {{
            \\      "not_implemented": {d},
            \\      "todos": {d}
            \\    }},
            \\    "status": "{s}"
            \\  }}
            \\}}
            \\
        , .{
            s.total_files,
            s.code_lines,
            counts.orphan,
            counts.memory,
            counts.err,
            counts.unused,
            counts.complexity,
            counts.fmt,
            counts.style,
            counts.null_safety,
            counts.panic,
            total,
            s.not_implemented_count,
            s.todo_count,
            if (total == 0) "ok" else "issues_found",
        });
    } else {
        std.debug.print(
            \\
            \\ephor summary
            \\
            \\Files: {d} | Code: {d} lines
            \\
            \\Issues:
            \\  Orphans:    {d}
            \\  Memory:     {d}
            \\  Errors:     {d}
            \\  Unused:     {d}
            \\  Complexity: {d}
            \\  Format:     {d}
            \\  Style:      {d}
            \\  NullSafety: {d}
            \\  Panic:      {d}
            \\  TOTAL:      {d}
            \\
            \\Quality: NotImplemented={d} TODO/FIXME={d}
            \\
            \\STATUS: {s}
            \\
        , .{
            s.total_files,
            s.code_lines,
            counts.orphan,
            counts.memory,
            counts.err,
            counts.unused,
            counts.complexity,
            counts.fmt,
            counts.style,
            counts.null_safety,
            counts.panic,
            total,
            s.not_implemented_count,
            s.todo_count,
            if (total == 0) "OK" else "ISSUES FOUND",
        });
    }
}

// ============================================================================
// Helper Functions for Main
// ============================================================================

/// Sort issues by file path for consistent output
fn sortIssuesByFile(issues: []Issue) void {
    std.mem.sort(Issue, issues, {}, struct {
        fn f(_: void, a: Issue, b: Issue) bool {
            return std.mem.order(u8, a.file, b.file) == .lt;
        }
    }.f);
}

/// Scan a path (file or directory) into the import graph
fn scanPath(g: *ImportGraph, path: []const u8) !void {
    const is_file = blk: {
        const stat = fs.cwd().statFile(path) catch break :blk false;
        break :blk stat.kind == .file;
    };
    if (is_file) {
        try g.scanSingleFile(path);
    } else {
        try g.scanDirectory(path);
    }
}

/// Run a single analyzer command and exit with appropriate code
fn runSingleAnalyzer(
    alloc: Allocator,
    cfg: *const Config,
    base_path: []const u8,
    comptime analyzer_fn: anytype,
    comptime needs_thresholds: bool,
    name: []const u8,
) !void {
    var g = ImportGraph.init(alloc);
    defer g.deinit();
    try scanPath(&g, cfg.path);

    var issues = if (needs_thresholds)
        try analyzer_fn(alloc, &g, cfg.thresholds)
    else
        try analyzer_fn(alloc, &g);
    defer deinitIssues(&issues, alloc);

    const count = printIssues(issues.items, base_path, cfg.format, name, cfg);
    if (count > 0) std.process.exit(1);
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var cfg = try parseArgs(alloc);
    defer cfg.deinit(alloc);

    // Check for updates on analysis commands (not on help/version/init/install/upgrade)
    switch (cfg.command) {
        .help, .version, .init, .install, .upgrade => {},
        else => checkForUpdates(alloc),
    }

    // Get absolute base path for relative path calculation
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_path = std.fs.cwd().realpath(cfg.path, &base_buf) catch cfg.path;

    switch (cfg.command) {
        .help => printHelp(),
        .version => std.debug.print("Ephor v{s} - The overseer of your Zig code\n", .{EPHOR_VERSION}),
        .init => {
            writeDefaultConfig() catch |err| {
                std.debug.print("error: failed to create config: {}\n", .{err});
                std.process.exit(1);
            };
            // If --build flag, also print build integration info
            if (cfg.init_build) {
                runInstallCommand(alloc) catch |err| {
                    std.debug.print("error: failed to run install: {}\n", .{err});
                    std.process.exit(1);
                };
            }
        },

        .install => runInstallCommand(alloc) catch |err| {
            std.debug.print("error: failed to install: {}\n", .{err});
            std.process.exit(1);
        },

        .upgrade => runUpgradeCommand(alloc) catch |err| {
            std.debug.print("error: failed to upgrade: {}\n", .{err});
            std.process.exit(1);
        },

        .orphans => {
            if (cfg.entries.items.len == 0) {
                std.debug.print("error: no entry points found\n", .{});
                std.debug.print("  hint: create ephor.json with 'entries' array\n", .{});
                std.debug.print("  run: ephor init\n", .{});
                std.process.exit(1);
            }
            if (cfg.verbose) {
                std.debug.print("Detected {d} entry points:\n", .{cfg.entries.items.len});
                for (cfg.entries.items) |e| std.debug.print("  - {s}\n", .{e});
            }
            var g = ImportGraph.init(alloc);
            defer g.deinit();
            try scanPath(&g, cfg.path);
            for (cfg.entries.items) |e| try g.markReachable(e);
            var issues = try g.getOrphanIssues(alloc, &cfg);
            defer deinitIssues(&issues, alloc);
            sortIssuesByFile(issues.items);

            const count = printIssues(issues.items, base_path, cfg.format, "orphans", &cfg);
            if (count > 0) std.process.exit(1);
        },

        .memory => {
            var g = ImportGraph.init(alloc);
            defer g.deinit();
            try scanPath(&g, cfg.path);
            var issues = try analyzeCFGMemory(alloc, &g);
            defer deinitIssues(&issues, alloc);
            const count = printIssues(issues.items, base_path, cfg.format, "memory", &cfg);
            if (count > 0) std.process.exit(1);
        },

        .errors => {
            var g = ImportGraph.init(alloc);
            defer g.deinit();
            try scanPath(&g, cfg.path);
            var issues = try analyzeErrors(alloc, &g);
            defer deinitIssues(&issues, alloc);
            const count = printIssues(issues.items, base_path, cfg.format, "errors", &cfg);
            if (count > 0) std.process.exit(1);
        },

        .unused => {
            var g = ImportGraph.init(alloc);
            defer g.deinit();
            try scanPath(&g, cfg.path);
            var issues = try analyzeUnused(alloc, &g);
            defer deinitIssues(&issues, alloc);
            const count = printIssues(issues.items, base_path, cfg.format, "unused", &cfg);
            if (count > 0) std.process.exit(1);
        },

        .complexity => {
            var g = ImportGraph.init(alloc);
            defer g.deinit();
            try scanPath(&g, cfg.path);
            var issues = try analyzeComplexity(alloc, &g, cfg.thresholds);
            defer deinitIssues(&issues, alloc);
            const count = printIssues(issues.items, base_path, cfg.format, "complexity", &cfg);
            if (count > 0) std.process.exit(1);
        },

        .fmt_check => {
            var issues = try runFmtCheck(alloc, cfg.path);
            defer deinitIssues(&issues, alloc);
            const count = printIssues(issues.items, base_path, cfg.format, "format", &cfg);
            if (count > 0) std.process.exit(1);
        },

        .stats => {
            var g = ImportGraph.init(alloc);
            defer g.deinit();
            try scanPath(&g, cfg.path);
            printStats(g.getStats(), cfg.format);
        },

        .runtime => {
            var issues = try runRuntimeAnalysis(alloc, cfg.path, cfg.verbose);
            defer deinitIssues(&issues, alloc);
            const count = printIssues(issues.items, base_path, cfg.format, "runtime", &cfg);
            if (count > 0) std.process.exit(1);
        },

        .check => {
            if (cfg.entries.items.len == 0) {
                std.debug.print("error: no entry points found\n", .{});
                std.debug.print("  hint: create ephor.json with 'entries' array\n", .{});
                std.debug.print("  run: ephor init\n", .{});
                std.process.exit(1);
            }
            var g = ImportGraph.init(alloc);
            defer g.deinit();

            try scanPath(&g, cfg.path);

            // Also scan entry point files to build complete import graph
            // This ensures orphan detection works when checking subdirectories
            for (cfg.entries.items) |e| {
                // Only scan if not already in scanned path
                if (!std.mem.startsWith(u8, e, cfg.path)) {
                    // Entry file may not exist, that's ok - just skip it
                    g.scanSingleFile(e) catch |err| {
                        if (cfg.verbose) {
                            std.debug.print(
                                "note: entry {s} not found: {}\n",
                                .{ e, err },
                            );
                        }
                    };
                }
            }
            for (cfg.entries.items) |e| try g.markReachable(e);

            var orphan_issues = try g.getOrphanIssues(alloc, &cfg);
            defer deinitIssues(&orphan_issues, alloc);
            sortIssuesByFile(orphan_issues.items);

            // CFG-based memory analysis (ZA101-ZA106)
            // Covers: alloc/create without defer, errdefer gaps, leaks, UAF, double-free
            var cfg_mem_issues = try analyzeCFGMemory(alloc, &g);
            defer deinitIssues(&cfg_mem_issues, alloc);

            var err_issues = try analyzeErrors(alloc, &g);
            defer deinitIssues(&err_issues, alloc);

            var unused_issues = try analyzeUnused(alloc, &g);
            defer deinitIssues(&unused_issues, alloc);

            var cx_issues = try analyzeComplexity(alloc, &g, cfg.thresholds);
            defer deinitIssues(&cx_issues, alloc);

            var fmt_issues = try runFmtCheck(alloc, cfg.path);
            defer deinitIssues(&fmt_issues, alloc);

            var style_issues = try analyzeStyle(alloc, &g, cfg.thresholds);
            defer deinitIssues(&style_issues, alloc);

            var naming_issues = try analyzeNaming(alloc, &g);
            defer deinitIssues(&naming_issues, alloc);

            // Phase 5: Error and null safety (CFG-based, included in cfg_mem_issues)
            var ignored_err_issues = try analyzeIgnoredErrors(alloc, &g);
            defer deinitIssues(&ignored_err_issues, alloc);

            // Note: Null safety (ZA801/ZA802) and Panic (ZA9xx) are now CFG-based
            // and included in cfg_mem_issues. We filter them out for categorization.

            const stats = g.getStats();

            // Print all issues (returns filtered count)
            const orphan_count = printIssues(
                orphan_issues.items,
                base_path,
                cfg.format,
                "orphans",
                &cfg,
            );
            // Filter cfg_mem_issues by rule category
            var mem_only_issues = std.ArrayListUnmanaged(Issue){};
            defer mem_only_issues.deinit(alloc);
            var null_safety_issues = std.ArrayListUnmanaged(Issue){};
            defer null_safety_issues.deinit(alloc);
            var panic_issues = std.ArrayListUnmanaged(Issue){};
            defer panic_issues.deinit(alloc);

            for (cfg_mem_issues.items) |issue| {
                if (mem.startsWith(u8, issue.rule, "ZA8")) {
                    try null_safety_issues.append(alloc, issue);
                } else if (mem.startsWith(u8, issue.rule, "ZA9")) {
                    try panic_issues.append(alloc, issue);
                } else {
                    try mem_only_issues.append(alloc, issue);
                }
            }

            const mem_count = printIssues(
                mem_only_issues.items,
                base_path,
                cfg.format,
                "memory",
                &cfg,
            );
            const ignored_err_count = printIssues(
                ignored_err_issues.items,
                base_path,
                cfg.format,
                "errors",
                &cfg,
            );
            const err_count = printIssues(
                err_issues.items,
                base_path,
                cfg.format,
                "errors",
                &cfg,
            );
            const null_safety_count = printIssues(
                null_safety_issues.items,
                base_path,
                cfg.format,
                "null-safety",
                &cfg,
            );
            const panic_count = printIssues(
                panic_issues.items,
                base_path,
                cfg.format,
                "panic",
                &cfg,
            );
            const unused_count = printIssues(
                unused_issues.items,
                base_path,
                cfg.format,
                "unused",
                &cfg,
            );
            const cx_count = printIssues(
                cx_issues.items,
                base_path,
                cfg.format,
                "complexity",
                &cfg,
            );
            const fmt_count = printIssues(
                fmt_issues.items,
                base_path,
                cfg.format,
                "format",
                &cfg,
            );
            const naming_count = printIssues(
                naming_issues.items,
                base_path,
                cfg.format,
                "naming",
                &cfg,
            );
            const style_count = printIssues(
                style_issues.items,
                base_path,
                cfg.format,
                "style",
                &cfg,
            );

            if (cfg.show_summary) {
                printSummary(.{
                    .orphan = orphan_count,
                    .memory = mem_count,
                    .err = err_count + ignored_err_count,
                    .unused = unused_count,
                    .complexity = cx_count,
                    .fmt = fmt_count,
                    .style = style_count + naming_count,
                    .null_safety = null_safety_count,
                    .panic = panic_count,
                }, stats, cfg.format);
            }

            const total = orphan_count + mem_count +
                err_count + ignored_err_count +
                unused_count + cx_count + fmt_count +
                style_count + naming_count + null_safety_count + panic_count;
            if (total > 0) std.process.exit(1);
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "countOccurrences" {
    const input = "pub fn a() pub fn b() pub fn c()";
    try std.testing.expectEqual(@as(usize, 3), countOccurrences(input, "pub fn "));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences("no matches", "pub fn "));
}

test "countLines" {
    try std.testing.expectEqual(@as(usize, 1), countLines("single"));
    try std.testing.expectEqual(@as(usize, 3), countLines("a\nb\nc"));
}

test "isIdent" {
    try std.testing.expect(isIdent('a'));
    try std.testing.expect(isIdent('Z'));
    try std.testing.expect(isIdent('_'));
    try std.testing.expect(!isIdent(' '));
}

test "relativePath" {
    try std.testing.expectEqualStrings(
        "api/core.zig",
        relativePath("/home/user/project/src/api/core.zig", "/home/user/project/src"),
    );
    try std.testing.expectEqualStrings(
        "src/main.zig",
        relativePath("/foo/bar/src/main.zig", "/other/path"),
    );
}

// ============================================================================
// Phase 4: CFG Memory Analysis Tests (ZA104, ZA105, ZA106)
// ============================================================================

/// Helper to create test FileAnalysis with content
fn createTestFileAnalysis(
    allocator: Allocator,
    path: []const u8,
    content: []const u8,
) !FileAnalysis {
    return .{
        .path = try allocator.dupe(u8, path),
        .imports = .{},
        .content = try allocator.dupe(u8, content),
        .has_tests = false,
        .pub_function_count = 0,
        .line_count = countLines(content),
    };
}

test "analyzeCFGMemory detects use-after-free (ZA105)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create graph with a file containing use-after-free pattern
    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn bad_use_after_free(allocator: std.mem.Allocator) void {
        \\    const data = allocator.alloc(u8, 100) catch return;
        \\    allocator.free(data);
        \\    _ = data[0]; // Use after free!
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_uaf.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_uaf.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should detect the use-after-free
    var found_za105 = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_USE_AFTER_FREE)) {
            found_za105 = true;
            break;
        }
    }
    try std.testing.expect(found_za105);
}

test "analyzeCFGMemory no false positive for catch-free-return pattern (ZA105)" {
    // KEY TEST: This was the original false positive that motivated CFG-based analysis
    // Pattern: catch { free(x); return; } - free only on error path, data still valid after
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn valid_catch_pattern(allocator: std.mem.Allocator) !void {
        \\    const data = allocator.alloc(u8, 100) catch return error.Failed;
        \\    const result = riskyOperation() catch {
        \\        allocator.free(data);
        \\        return error.Failed;
        \\    };
        \\    // data is STILL VALID here - catch path returned, didn't reach this line
        \\    process(data);
        \\    _ = result;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_catch_free_return.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_catch_free_return.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should NOT detect use-after-free - data is still valid after catch block
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_catch_free_return.zig") and
            mem.eql(u8, issue.rule, RULE_USE_AFTER_FREE))
        {
            // False positive found - this is the bug that CFG should prevent
            std.debug.print("FALSE POSITIVE: {s}:{d}: {s}\n", .{ issue.file, issue.line, issue.message });
            try std.testing.expect(false);
        }
    }
}

test "analyzeCFGMemory detects double-free (ZA106)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn bad_double_free(allocator: std.mem.Allocator) void {
        \\    const data = allocator.alloc(u8, 100) catch return;
        \\    allocator.free(data);
        \\    allocator.free(data); // Double free!
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_double_free.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_double_free.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should detect the double-free
    var found_za106 = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_DOUBLE_FREE)) {
            found_za106 = true;
            break;
        }
    }
    try std.testing.expect(found_za106);
}

test "analyzeCFGMemory no false positive for proper defer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn good_allocation(allocator: std.mem.Allocator) void {
        \\    const data = allocator.alloc(u8, 100) catch return;
        \\    defer allocator.free(data);
        \\    process(data);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_good.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_good.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should NOT detect issues for properly deferred allocation
    for (issues.items) |issue| {
        // Filter to issues from our test file only
        if (mem.eql(u8, issue.file, "test_good.zig")) {
            // If we find ZA105 or ZA106 in properly written code, that's a false positive
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_USE_AFTER_FREE));
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_DOUBLE_FREE));
        }
    }
}

test "analyzeCFGMemory no false positive for switch arm frees (ZA106)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // Free in different switch arms is NOT double-free
    const test_content =
        \\fn switch_free(allocator: std.mem.Allocator, x: enum { a, b }) void {
        \\    const data = allocator.alloc(u8, 100) catch return;
        \\    switch (x) {
        \\        .a => allocator.free(data),
        \\        .b => allocator.free(data),
        \\    }
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_switch_free.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_switch_free.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should NOT detect double-free for switch arm frees
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_switch_free.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_DOUBLE_FREE));
        }
    }
}

test "analyzeCFGMemory no false positive for catch/orelse frees (ZA106)" {
    // This tests a standard Zig idiom for handling !?T (error union of optional).
    // When a function returns !?T, you need BOTH catch (error) and orelse (null).
    // These branches are MUTUALLY EXCLUSIVE by language design - only one executes.
    // Freeing in both branches is CORRECT cleanup, not double-free.
    //
    // Pattern:
    //   const result = tryGetOptionalValue() catch { cleanup(); return err; }
    //                                        orelse { cleanup(); return null_err; };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn catch_orelse_free(allocator: std.mem.Allocator) !void {
        \\    const arena = allocator.create(Arena) catch return error.OutOfMemory;
        \\    // getValue returns !?T - can fail with error OR return null
        \\    const result = getValue() catch {
        \\        // Error path - cleanup and return error
        \\        arena.deinit();
        \\        allocator.destroy(arena);
        \\        return error.Failed;
        \\    } orelse {
        \\        // Null path - cleanup and return different error
        \\        arena.deinit();
        \\        allocator.destroy(arena);
        \\        return error.NullValue;
        \\    };
        \\    _ = result;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_catch_orelse.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_catch_orelse.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should NOT detect double-free for catch/orelse branch frees
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_catch_orelse.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_DOUBLE_FREE));
        }
    }
}

test "analyzeCFGErrdeferCoverage detects missing errdefer (ZA103)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // Missing errdefer before second try
    const test_content =
        \\fn bad_errdefer(alloc: std.mem.Allocator) !void {
        \\    const data = try alloc.alloc(u8, 100);
        \\    // MISSING errdefer here!
        \\    const more = try alloc.alloc(u8, 100);
        \\    errdefer alloc.free(more);
        \\    _ = data;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_errdefer.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_errdefer.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should detect the missing errdefer
    var found_za103 = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER)) {
            found_za103 = true;
            break;
        }
    }
    try std.testing.expect(found_za103);
}

test "analyzeCFGErrdeferCoverage no false positive for proper errdefer (ZA103)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // Proper errdefer immediately after allocation
    const test_content =
        \\fn good_errdefer(alloc: std.mem.Allocator) !void {
        \\    const data = try alloc.alloc(u8, 100);
        \\    errdefer alloc.free(data);
        \\    const more = try alloc.alloc(u8, 100);
        \\    errdefer alloc.free(more);
        \\    process(data, more);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_good_errdefer.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_good_errdefer.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should NOT detect ZA103 for properly errdeferred allocation
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_good_errdefer.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER));
        }
    }
}

// ============================================================================
// Phase 5: Error Analysis Tests (ZA205)
// ============================================================================

test "analyzeIgnoredErrors detects discarded error union (ZA205)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn bad_discard() void {
        \\    _ = might_fail(); // Discards error union!
        \\}
        \\fn might_fail() !void {
        \\    return;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_discard.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_discard.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should detect the discarded error
    var found_za205 = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            found_za205 = true;
            break;
        }
    }
    try std.testing.expect(found_za205);
}

test "analyzeIgnoredErrors no false positive for try" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn good_try() !void {
        \\    try might_fail(); // Properly propagated
        \\}
        \\fn might_fail() !void {
        \\    return;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_good_try.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_good_try.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should NOT report ZA205 for try usage
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_good_try.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_IGNORED_ERROR));
        }
    }
}

test "analyzeIgnoredErrors no false positive for catch" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn good_catch() void {
        \\    const result = might_fail() catch |err| {
        \\        log.err("Failed: {}", .{err});
        \\        return;
        \\    };
        \\    _ = result;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_good_catch.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_good_catch.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should NOT report ZA205 for explicit catch
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_good_catch.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_IGNORED_ERROR));
        }
    }
}

// ============================================================================
// Phase 5: Null Safety Tests (ZA801, ZA802)
// ============================================================================

test "analyzeNullSafety detects unsafe optional unwrap (ZA801)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn bad_unwrap() void {
        \\    const opt: ?u32 = null;
        \\    const val = opt.?.value; // Unsafe unwrap!
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_unwrap.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_unwrap.zig"), {});

    var issues = try analyzeNullSafety(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should detect unsafe unwrap
    var found_za801 = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_OPTIONAL_UNWRAP_UNSAFE)) {
            found_za801 = true;
            break;
        }
    }
    try std.testing.expect(found_za801);
}

test "analyzeNullSafety no false positive for safe unwrap with orelse" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn safe_unwrap() void {
        \\    const opt: ?u32 = null;
        \\    const val = opt orelse 0; // Safe with orelse
        \\    _ = val;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_safe.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_safe.zig"), {});

    var issues = try analyzeNullSafety(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should NOT report issues for safe unwrap
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_safe.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_OPTIONAL_UNWRAP_UNSAFE));
        }
    }
}

test "analyzeNullSafety no false positive for if check" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn safe_if_check() void {
        \\    const opt: ?u32 = get_optional();
        \\    if (opt) |val| {
        \\        process(val);
        \\    }
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_if.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_if.zig"), {});

    var issues = try analyzeNullSafety(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should NOT report issues for safe if check
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_if.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_OPTIONAL_UNWRAP_UNSAFE));
        }
    }
}

test "analyzeNullSafety detects unsafe deref of maybe_ variable (ZA802)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn bad_deref() void {
        \\    const maybe_ptr: ?*u32 = null;
        \\    const val = maybe_ptr.*; // Unsafe deref!
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_deref.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_deref.zig"), {});

    var issues = try analyzeNullSafety(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should detect unsafe deref of maybe_ prefixed optional
    var found_za802 = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_ORELSE_QUESTION_UNSAFE)) {
            found_za802 = true;
            break;
        }
    }
    try std.testing.expect(found_za802);
}

// ============================================================================
// Config Tests
// ============================================================================

test "Config.isRuleEnabled respects explicit enable" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cfg = Config{
        .command = .check,
        .path = "src",
        .path_owned = false,
        .entries = .{},
        .exclude = .{},
        .orphan_exclude = .{},
        .disabled_rules = .{},
        .enabled_rules = .{},
        .verbose = false,
        .show_summary = false,
        .format = .text,
        .thresholds = .{},
        .init_build = false,
    };
    defer cfg.deinit(allocator);

    // Enable ZA702 explicitly
    try cfg.enabled_rules.append(allocator, try allocator.dupe(u8, "ZA702"));

    // ZA702 is OFF by default but should be ON when explicitly enabled
    try std.testing.expect(cfg.isRuleEnabled("ZA702"));
}

test "Config.isRuleEnabled respects disable prefix" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cfg = Config{
        .command = .check,
        .path = "src",
        .path_owned = false,
        .entries = .{},
        .exclude = .{},
        .orphan_exclude = .{},
        .disabled_rules = .{},
        .enabled_rules = .{},
        .verbose = false,
        .show_summary = false,
        .format = .text,
        .thresholds = .{},
        .init_build = false,
    };
    defer cfg.deinit(allocator);

    // Disable all ZA3xx rules
    try cfg.disabled_rules.append(allocator, try allocator.dupe(u8, "ZA3"));

    // All ZA3xx rules should be disabled
    try std.testing.expect(!cfg.isRuleEnabled("ZA301"));
    try std.testing.expect(!cfg.isRuleEnabled("ZA302"));
    try std.testing.expect(!cfg.isRuleEnabled("ZA303"));
    try std.testing.expect(!cfg.isRuleEnabled("ZA304"));

    // Other rules should still be enabled
    try std.testing.expect(cfg.isRuleEnabled("ZA101"));
    try std.testing.expect(cfg.isRuleEnabled("ZA201"));
}

test "Config.isRuleEnabled enable overrides disable" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cfg = Config{
        .command = .check,
        .path = "src",
        .path_owned = false,
        .entries = .{},
        .exclude = .{},
        .orphan_exclude = .{},
        .disabled_rules = .{},
        .enabled_rules = .{},
        .verbose = false,
        .show_summary = false,
        .format = .text,
        .thresholds = .{},
        .init_build = false,
    };
    defer cfg.deinit(allocator);

    // Disable all ZA3xx rules
    try cfg.disabled_rules.append(allocator, try allocator.dupe(u8, "ZA3"));
    // But explicitly enable ZA301
    try cfg.enabled_rules.append(allocator, try allocator.dupe(u8, "ZA301"));

    // ZA301 should be enabled (explicit enable wins)
    try std.testing.expect(cfg.isRuleEnabled("ZA301"));
    // Other ZA3xx still disabled
    try std.testing.expect(!cfg.isRuleEnabled("ZA302"));
}

test "isInlineDisabled detects disable comment" {
    const content =
        \\const x = 1;
        \\const y = foo() catch {}; // ephor:disable ZA201
        \\const z = 3;
    ;

    // Line 2 has disable for ZA201
    try std.testing.expect(isInlineDisabled(content, 2, "ZA201"));
    // Line 1 doesn't have disable
    try std.testing.expect(!isInlineDisabled(content, 1, "ZA201"));
    // ZA202 is not disabled on line 2
    try std.testing.expect(!isInlineDisabled(content, 2, "ZA202"));
}

test "isInlineDisabled detects disable-next-line" {
    const content =
        \\const x = 1;
        \\// ephor:disable-next-line ZA201
        \\const y = foo() catch {};
        \\const z = 3;
    ;

    // Line 3 should be disabled by the comment on line 2
    try std.testing.expect(isInlineDisabled(content, 3, "ZA201"));
    // Line 4 is not covered
    try std.testing.expect(!isInlineDisabled(content, 4, "ZA201"));
}

test "checkSilentCatch detects catch {}" {
    // Basic catch {} should be detected
    const issue = checkSilentCatch("foo() catch {}", "test.zig", 1);
    try std.testing.expect(issue != null);
    try std.testing.expectEqualStrings("ZA201", issue.?.rule);
}

test "checkSilentCatch skips defer context" {
    // Same-line defer should not be detected
    const issue = checkSilentCatch("defer foo() catch {}", "test.zig", 1);
    try std.testing.expect(issue == null);
}

test "analyzeErrors detects silent catch (ZA201)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn bad_silent_catch() void {
        \\    foo() catch {};
        \\}
        \\fn foo() !void {}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_silent_catch.zig", test_content);
    try graph.files.put(analysis.path, analysis);

    var issues = try analyzeErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should detect the silent catch
    var found_za201 = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_SILENT_CATCH)) {
            found_za201 = true;
            break;
        }
    }
    try std.testing.expect(found_za201);
}

test "analyzeCFGDeferCoverage detects defer only in conditional branch" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test content: defer only in if-true branch
    const test_content =
        \\fn bad_conditional_defer(allocator: std.mem.Allocator, condition: bool) void {
        \\    const data = allocator.alloc(u8, 100) catch return;
        \\    if (condition) {
        \\        defer allocator.free(data);
        \\        process(data);
        \\    }
        \\}
    ;

    // Build CFG and analyze
    var lines_list = std.ArrayListUnmanaged([]const u8){};
    defer lines_list.deinit(allocator);

    var line_iter = mem.splitScalar(u8, test_content, '\n');
    while (line_iter.next()) |line| {
        try lines_list.append(allocator, line);
    }

    var cfg = try buildCFG(allocator, "bad_conditional_defer", 1, lines_list.items);
    defer cfg.deinit();

    var issues = try analyzeCFGDeferCoverage(
        allocator,
        &cfg,
        lines_list.items,
        1,
        "test_conditional.zig",
    );
    defer deinitIssues(&issues, allocator);

    // Should detect that defer is not on all paths
    var found_issue = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER)) {
            found_issue = true;
            break;
        }
    }
    try std.testing.expect(found_issue);
}

test "analyzeCFGDeferCoverage no false positive for proper defer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test content: defer at proper scope
    const test_content =
        \\fn good_defer(allocator: std.mem.Allocator) void {
        \\    const data = allocator.alloc(u8, 100) catch return;
        \\    defer allocator.free(data);
        \\    process(data);
        \\}
    ;

    var lines_list = std.ArrayListUnmanaged([]const u8){};
    defer lines_list.deinit(allocator);

    var line_iter = mem.splitScalar(u8, test_content, '\n');
    while (line_iter.next()) |line| {
        try lines_list.append(allocator, line);
    }

    var cfg = try buildCFG(allocator, "good_defer", 1, lines_list.items);
    defer cfg.deinit();

    var issues = try analyzeCFGDeferCoverage(
        allocator,
        &cfg,
        lines_list.items,
        1,
        "test_good.zig",
    );
    defer deinitIssues(&issues, allocator);

    // Should NOT report issues for properly deferred allocation
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_good.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
        }
    }
}

// ============================================================================
// Integration Test: Bad Code Patterns (CFG-based)
// ============================================================================
// Tests realistic memory safety bugs that the CFG analysis should catch.
// These patterns compile but have subtle runtime issues.

test "integration: use-after-free patterns" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // Use-after-free patterns that compile but are bugs
    const uaf_code =
        \\const std = @import("std");
        \\
        \\fn uafSubscript(alloc: std.mem.Allocator) void {
        \\    const data = alloc.alloc(u8, 100) catch return;
        \\    alloc.free(data);
        \\    data[0] = 42;
        \\}
        \\
        \\fn uafPassToFn(alloc: std.mem.Allocator) void {
        \\    const buf = alloc.alloc(u8, 64) catch return;
        \\    alloc.free(buf);
        \\    process(buf);
        \\}
        \\fn process(d: []u8) void { _ = d; }
    ;

    const analysis = try createTestFileAnalysis(allocator, "uaf_test.zig", uaf_code);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "uaf_test.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var uaf_count: usize = 0;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "uaf_test.zig") and
            mem.eql(u8, issue.rule, RULE_USE_AFTER_FREE))
        {
            uaf_count += 1;
        }
    }
    // Should detect both UAF patterns
    try std.testing.expect(uaf_count >= 2);
}

test "integration: double-free patterns" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const df_code =
        \\const std = @import("std");
        \\
        \\fn doubleFree(alloc: std.mem.Allocator) void {
        \\    const data = alloc.alloc(u8, 100) catch return;
        \\    alloc.free(data);
        \\    alloc.free(data);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "df_test.zig", df_code);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "df_test.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var df_count: usize = 0;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "df_test.zig") and
            mem.eql(u8, issue.rule, RULE_DOUBLE_FREE))
        {
            df_count += 1;
        }
    }
    try std.testing.expect(df_count >= 1);
}

test "integration: undefined variable read" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Code that compiles but reads undefined value
    const undefined_lines = [_][]const u8{
        "fn readUndefined() u32 {",
        "    var x: u32 = undefined;",
        "    return x;", // This is a bug - x was never assigned
        "}",
    };

    var cfg = try buildCFG(allocator, "readUndefined", 1, &undefined_lines);
    defer cfg.deinit();

    var def_issues = try analyzeDefiniteAssignment(allocator, &cfg, &undefined_lines, 1);
    defer def_issues.deinit();

    // Should detect 'x' is read before assignment
    try std.testing.expect(def_issues.count() > 0);
}

test "integration: no false positive for valid catch-free-return" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // This is VALID code - free in catch that returns does NOT affect main path
    const valid_code =
        \\const std = @import("std");
        \\
        \\fn validPattern(alloc: std.mem.Allocator) !void {
        \\    const data = alloc.alloc(u8, 100) catch return error.OOM;
        \\    const x = risky() catch {
        \\        alloc.free(data);
        \\        return error.Failed;
        \\    };
        \\    process(data);
        \\    _ = x;
        \\    alloc.free(data);
        \\}
        \\fn risky() !u32 { return 42; }
        \\fn process(d: []u8) void { _ = d; }
    ;

    const analysis = try createTestFileAnalysis(allocator, "valid_catch.zig", valid_code);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "valid_catch.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should NOT have any UAF for this valid pattern
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "valid_catch.zig") and
            mem.eql(u8, issue.rule, RULE_USE_AFTER_FREE))
        {
            std.debug.print("FALSE POSITIVE: line {d}: {s}\n", .{ issue.line, issue.message });
            try std.testing.expect(false); // Fail if we find UAF in valid code
        }
    }
}
