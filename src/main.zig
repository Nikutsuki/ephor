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
const mem = std.mem;
const Allocator = mem.Allocator;

/// Compatibility layer for std.fs APIs removed in Zig 0.16.0.
const fs = struct {
    pub const path = std.Io.Dir.path;
    pub const max_path_bytes = std.Io.Dir.max_path_bytes;
    pub const Dir = CompatDir;

    pub fn cwd() CompatDir {
        return .{};
    }

    pub const CompatDir = struct {
        pub fn access(_: CompatDir, sub_path: []const u8, options: std.Io.Dir.AccessOptions) !void {
            return std.Io.Dir.cwd().access(global_io.?, sub_path, options);
        }
        pub fn openFile(_: CompatDir, sub_path: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
            return std.Io.Dir.cwd().openFile(global_io.?, sub_path, options);
        }
        pub fn openDir(_: CompatDir, sub_path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
            return std.Io.Dir.cwd().openDir(global_io.?, sub_path, options);
        }
        pub fn readFileAlloc(_: CompatDir, allocator: Allocator, sub_path: []const u8, max_bytes: usize) ![]u8 {
            return std.Io.Dir.cwd().readFileAlloc(global_io.?, sub_path, allocator, .limited(max_bytes));
        }
        pub fn createFile(_: CompatDir, sub_path: []const u8, flags: std.Io.Dir.CreateFileOptions) !std.Io.File {
            return std.Io.Dir.cwd().createFile(global_io.?, sub_path, flags);
        }
        pub fn statFile(_: CompatDir, sub_path: []const u8) !std.Io.Dir.Stat {
            return std.Io.Dir.cwd().statFile(global_io.?, sub_path, .{});
        }
        pub fn realpath(_: CompatDir, sub_path: []const u8, out_buffer: []u8) ![]u8 {
            const n = try std.Io.Dir.cwd().realPathFile(global_io.?, sub_path, out_buffer);
            return out_buffer[0..n];
        }
        pub fn realpathAlloc(_: CompatDir, allocator: Allocator, sub_path: []const u8) ![:0]u8 {
            return std.Io.Dir.cwd().realPathFileAlloc(global_io.?, allocator, sub_path);
        }
        pub fn iterate(_: CompatDir) std.Io.Dir.Iterator {
            return std.Io.Dir.cwd().iterate();
        }
        pub fn writeFile(_: CompatDir, sub_path: []const u8, data: []const u8, flags: std.Io.Dir.CreateFileOptions) !void {
            return std.Io.Dir.cwd().writeFile(global_io.?, .{ .sub_path = sub_path, .data = data, .flags = flags });
        }
    };
};

/// Global I/O handle for child process and file operations.
var global_io: ?std.Io = null;

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
const RULE_USE_AFTER_FREE = types.RULE_USE_AFTER_FREE;
const RULE_DOUBLE_FREE = types.RULE_DOUBLE_FREE;
const RULE_SILENT_CATCH = types.RULE_SILENT_CATCH;
const RULE_CATCH_UNREACHABLE = types.RULE_CATCH_UNREACHABLE;
const RULE_ORELSE_UNREACHABLE = types.RULE_ORELSE_UNREACHABLE;
const RULE_UNDEFINED_USAGE = types.RULE_UNDEFINED_USAGE;
const RULE_IGNORED_ERROR = types.RULE_IGNORED_ERROR;
const RULE_EXIT_BYPASSES_DEFER = types.RULE_EXIT_BYPASSES_DEFER;
const RULE_CATCH_UNDEFINED = types.RULE_CATCH_UNDEFINED;
const RULE_PANIC = types.RULE_PANIC;
const RULE_FUNC_TOO_LONG = types.RULE_FUNC_TOO_LONG;
const RULE_NESTING_TOO_DEEP = types.RULE_NESTING_TOO_DEEP;
const RULE_TOO_MANY_PARAMS = types.RULE_TOO_MANY_PARAMS;
const RULE_TOO_MANY_BRANCHES = types.RULE_TOO_MANY_BRANCHES;
const RULE_CYCLOMATIC = types.RULE_CYCLOMATIC;
const RULE_COGNITIVE = types.RULE_COGNITIVE;
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

const ReturnKind = types.ReturnKind;
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
            .allocations = .empty,
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
            .blocks = .empty,
            .edges = .empty,
            .entry_block = 0,
            .exit_blocks = .empty,
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
            .alloc_gen = .empty,
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
fn isUnbalancedCatchBlock(trimmed: []const u8) bool {
    if (mem.indexOf(u8, trimmed, "catch ") == null) return false;
    if (mem.indexOf(u8, trimmed, "{") == null) return false;
    var open: usize = 0;
    var close: usize = 0;
    for (trimmed) |c| {
        if (c == '{') open += 1;
        if (c == '}') close += 1;
    }
    return open > close;
}

fn isSwitchArmLine(trimmed: []const u8) bool {
    if (mem.indexOf(u8, trimmed, "=>") == null) return false;
    return mem.startsWith(u8, trimmed, ".") or
        mem.startsWith(u8, trimmed, "else =>") or
        mem.indexOf(u8, trimmed, ", .") != null;
}

fn detectCFPattern(t: []const u8) CFPattern {
    const trimmed = mem.trim(u8, t, " \t\r");

    for (cf_patterns) |p| {
        if (p.exact) {
            if (mem.eql(u8, trimmed, p.prefix)) return p.result;
        } else {
            if (mem.startsWith(u8, trimmed, p.prefix)) return p.result;
        }
    }

    if (isUnbalancedCatchBlock(trimmed)) return .catch_start;
    if (mem.indexOf(u8, trimmed, "try ") != null) return .try_expr;
    if (isSwitchArmLine(trimmed)) return .switch_arm;
    return .none;
}

/// Build CFG from function lines
/// State passed through CFG building for each line
const CFGBuildCtx = struct {
    cfg: *ControlFlowGraph,
    block_stack: *std.ArrayListUnmanaged(StackEntry),
    allocator: Allocator,
    current_block: usize,
    func_line: usize,

    fn setStartLine(self: *CFGBuildCtx, line: usize) void {
        self.cfg.blocks.items[self.current_block].start_line = line;
    }

    fn handleBranch(self: *CFGBuildCtx, bt: BlockType, line: usize) !void {
        const true_block = try self.cfg.addBlock();
        const false_block = try self.cfg.addBlock();
        try self.cfg.addEdge(self.current_block, true_block, .branch_true);
        try self.cfg.addEdge(self.current_block, false_block, .branch_false);
        const origin = if (bt == .while_block or bt == .for_block)
            self.current_block
        else
            @as(usize, 0);
        try self.block_stack.append(self.allocator, .{
            .block_type = bt,
            .merge_block = false_block,
            .catch_origin_block = origin,
        });
        self.current_block = true_block;
        self.setStartLine(line);
    }

    fn handleReturn(self: *CFGBuildCtx) !void {
        self.cfg.blocks.items[self.current_block].is_return = true;
        try self.cfg.exit_blocks.append(self.allocator, self.current_block);
    }

    fn handleSwitchStart(self: *CFGBuildCtx) !void {
        const merge_block = try self.cfg.addBlock();
        try self.block_stack.append(self.allocator, .{
            .block_type = .switch_block,
            .merge_block = merge_block,
            .catch_origin_block = self.current_block,
        });
    }

    fn handleSwitchArm(self: *CFGBuildCtx, line: usize) !void {
        for (self.block_stack.items, 0..) |entry, i| {
            if (entry.block_type != .switch_block) continue;
            const switch_entry = self.block_stack.items[i];
            const switch_header = switch_entry.catch_origin_block;
            if (self.current_block != switch_header and
                !self.cfg.blocks.items[self.current_block].is_return)
            {
                try self.cfg.addEdge(self.current_block, switch_entry.merge_block, .sequential);
            }
            const arm_block = try self.cfg.addBlock();
            try self.cfg.addEdge(switch_header, arm_block, .branch_true);
            self.current_block = arm_block;
            self.setStartLine(line);
            break;
        }
    }

    fn handleElse(self: *CFGBuildCtx, t: []const u8, line: usize) !void {
        if (self.block_stack.items.len == 0) return;
        const entry = self.block_stack.pop() orelse return;
        const else_block = entry.merge_block;
        const merge_block = try self.cfg.addBlock();
        try self.cfg.addEdge(self.current_block, merge_block, .sequential);
        if (hasInlineElseReturn(t)) {
            self.cfg.blocks.items[else_block].start_line = line;
            self.cfg.blocks.items[else_block].end_line = line;
            self.cfg.blocks.items[else_block].is_return = true;
            try self.cfg.exit_blocks.append(self.allocator, else_block);
            self.current_block = merge_block;
            self.cfg.blocks.items[self.current_block].start_line = line + 1;
        } else {
            try self.block_stack.append(self.allocator, .{
                .block_type = .else_block,
                .merge_block = merge_block,
                .catch_origin_block = 0,
            });
            self.current_block = else_block;
            self.setStartLine(line);
        }
    }

    fn handleBlockEnd(self: *CFGBuildCtx, line: usize) !void {
        if (self.block_stack.items.len == 0) return;
        const entry = self.block_stack.pop() orelse return;
        switch (entry.block_type) {
            .catch_block => {
                if (!self.cfg.blocks.items[self.current_block].is_return)
                    try self.cfg.addEdge(self.current_block, entry.merge_block, .sequential);
                self.current_block = entry.merge_block;
                self.setStartLine(line + 1);
            },
            .while_block, .for_block => {
                try self.cfg.addEdge(self.current_block, entry.catch_origin_block, .loop_back);
                self.current_block = entry.merge_block;
                self.setStartLine(line + 1);
            },
            .switch_block => {
                if (!self.cfg.blocks.items[self.current_block].is_return)
                    try self.cfg.addEdge(self.current_block, entry.merge_block, .sequential);
                self.current_block = entry.merge_block;
                self.setStartLine(line + 1);
            },
            else => {
                try self.cfg.addEdge(self.current_block, entry.merge_block, .sequential);
                self.current_block = entry.merge_block;
                self.setStartLine(line + 1);
            },
        }
    }

    fn handleCatchStart(self: *CFGBuildCtx, line: usize) !void {
        const origin_block = self.current_block;
        const continuation_block = try self.cfg.addBlock();
        const catch_block = try self.cfg.addBlock();
        self.cfg.blocks.items[catch_block].is_catch_block = true;
        try self.cfg.addEdge(origin_block, continuation_block, .sequential);
        try self.cfg.addEdge(origin_block, catch_block, .error_path);
        try self.block_stack.append(self.allocator, .{
            .block_type = .catch_block,
            .merge_block = continuation_block,
            .catch_origin_block = origin_block,
        });
        self.current_block = catch_block;
        self.setStartLine(line);
    }
};

fn hasInlineElseReturn(t: []const u8) bool {
    const else_pos = mem.indexOf(u8, t, "else") orelse return false;
    const after_else = mem.trimStart(u8, t[else_pos + 4 ..], " \t");
    return mem.startsWith(u8, after_else, "return ");
}

fn buildCFG(
    allocator: Allocator,
    func_name: []const u8,
    func_line: usize,
    lines: []const []const u8,
) !ControlFlowGraph {
    var cfg = ControlFlowGraph.init(allocator, func_name, func_line);
    const current_block = try cfg.addBlock();
    cfg.entry_block = current_block;
    cfg.blocks.items[current_block].start_line = func_line;

    var block_stack = std.ArrayListUnmanaged(StackEntry).empty;
    defer block_stack.deinit(allocator);

    var ctx = CFGBuildCtx{
        .cfg = &cfg,
        .block_stack = &block_stack,
        .allocator = allocator,
        .current_block = current_block,
        .func_line = func_line,
    };

    for (lines, 0..) |line, idx| {
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;
        const pattern = detectCFPattern(t);
        cfg.blocks.items[ctx.current_block].end_line = func_line + idx;
        const al = func_line + idx;
        switch (pattern) {
            .if_start => try ctx.handleBranch(.if_block, al),
            .while_start => try ctx.handleBranch(.while_block, al),
            .for_start => try ctx.handleBranch(.for_block, al),
            .switch_start => try ctx.handleSwitchStart(),
            .switch_arm => try ctx.handleSwitchArm(al),
            .else_start, .else_if => try ctx.handleElse(t, al),
            .return_stmt => try ctx.handleReturn(),
            .block_end => try ctx.handleBlockEnd(al),
            .catch_start => try ctx.handleCatchStart(al),
            else => {},
        }
    }

    if (cfg.exit_blocks.items.len == 0)
        try cfg.exit_blocks.append(allocator, ctx.current_block);
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
    // Check cleanup patterns from compat layer (excludes .deinit which is bulk cleanup)
    for (compat.getCleanupPatterns()) |pat| {
        // Only check .free( and .destroy( — not .deinit( (bulk cleanup, not per-alloc)
        if (mem.eql(u8, pat, ".deinit(")) continue;
        if (mem.indexOf(u8, t, pat)) |pos| {
            if (!isPatternInString(t, pos)) return true;
        }
    }
    return false;
}

/// Check if line has any cleanup pattern (.free, .destroy, .deinit) NOT inside a string
fn hasRealCleanupPattern(t: []const u8) bool {
    for (compat.getCleanupPatterns()) |pat| {
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

/// Check if the first argument after an opening paren looks like a Zig type.
/// `std.mem.Allocator.alloc(comptime T: type, n: usize)` always has a type
/// as its first argument. Non-memory `.alloc()` methods (e.g. SPIR-V register
/// allocation) take runtime values instead.
///
/// Zig types look like:
///   - Primitive: u8, u16, u32, u64, usize, i8, i16, i32, i64, isize, bool, void, f16, f32, f64
///   - User-defined: starts with uppercase (MyStruct, Allocator, Id)
///   - Pointer/slice: [], [*], *
///   - Optional: ?Type
///   - Array: [N]Type
///   - @import or @Type builtins
///
/// Non-types (runtime values) look like:
///   - Lowercase identifiers that aren't primitives (object_ty_id, result, count)
///   - Null, numeric literals
fn hasTypeFirstArg(t: []const u8, open_paren_end: usize) bool {
    if (open_paren_end >= t.len) return false;

    // Skip whitespace after the opening paren
    var pos = open_paren_end;
    while (pos < t.len and (t[pos] == ' ' or t[pos] == '\t')) pos += 1;
    if (pos >= t.len) return false;

    const c = t[pos];

    // Pointer/slice/array type constructors: [], [*], *
    if (c == '[' or c == '*') return true;

    // Optional type: ?Type
    if (c == '?') return true;

    // Builtin type: @import, @Type, @Vector, etc.
    if (c == '@') return true;

    // Close paren = no args = not std.mem.Allocator.alloc
    if (c == ')') return false;

    // Numeric literal or null = runtime value, not a type
    if (c >= '0' and c <= '9') return false;
    if (mem.startsWith(u8, t[pos..], "null")) return false;

    // Extract the identifier
    var id_end = pos;
    while (id_end < t.len and (isIdent(t[id_end]) or t[id_end] == '.')) id_end += 1;
    if (id_end == pos) return false;
    const first_arg = t[pos..id_end];

    // Uppercase first char = user-defined type (MyStruct, Allocator, etc.)
    if (c >= 'A' and c <= 'Z') return true;

    // Primitive numeric types: u8, u16, u32, u64, usize, i8, i16, i32, i64, isize
    if ((c == 'u' or c == 'i') and first_arg.len >= 2) {
        if (mem.eql(u8, first_arg, "usize") or mem.eql(u8, first_arg, "isize")) return true;
        // u8, u16, u32, u64, u128, i8, i16, i32, i64, i128
        if (first_arg.len >= 2 and first_arg[1] >= '0' and first_arg[1] <= '9') return true;
    }

    // Other primitive types
    if (mem.eql(u8, first_arg, "bool") or
        mem.eql(u8, first_arg, "void") or
        mem.eql(u8, first_arg, "anyopaque") or
        mem.eql(u8, first_arg, "comptime_int") or
        mem.eql(u8, first_arg, "comptime_float"))
    {
        return true;
    }

    // Float types: f16, f32, f64, f80, f128
    if (c == 'f' and first_arg.len >= 2 and first_arg[1] >= '0' and first_arg[1] <= '9') return true;

    // If we got here with a lowercase identifier that's not a primitive,
    // it's likely a runtime variable (e.g. object_ty_id, result, count)
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

/// Check if a variable is the DIRECT target of a free/destroy call.
/// Returns true for: varname.free(, varname.destroy(,
///   allocator.free(varname), allocator.destroy(varname)
/// Returns false for: varname.field.free( (field freed, not var)
fn isDirectFreeOfVar(t: []const u8, var_name: []const u8) bool {
    var search_start: usize = 0;
    while (mem.indexOf(u8, t[search_start..], var_name)) |rel_pos| {
        const var_pos = search_start + rel_pos;
        search_start = var_pos + var_name.len;

        // Word boundary checks
        if (var_pos + var_name.len < t.len and isIdent(t[var_pos + var_name.len])) continue;
        if (var_pos > 0 and isIdent(t[var_pos - 1])) continue;
        if (var_pos > 0 and t[var_pos - 1] == '.') continue; // struct field

        const after_var = var_pos + var_name.len;

        // Pattern 1: varname.free( or varname.destroy( (direct free)
        if (after_var < t.len and t[after_var] == '.') {
            const rest = t[after_var + 1 ..];
            if (mem.startsWith(u8, rest, "free(") or mem.startsWith(u8, rest, "destroy(") or
                mem.startsWith(u8, rest, "deinit("))
            {
                return true;
            }
            // varname.field.something - intermediate field access, not a direct free
            continue;
        }

        // Pattern 2: allocator.free(varname) or allocator.destroy(varname)
        if (var_pos >= 1 and t[var_pos - 1] == '(') {
            const before_paren = mem.trimEnd(u8, t[0 .. var_pos - 1], " ");
            if (mem.endsWith(u8, before_paren, ".free") or
                mem.endsWith(u8, before_paren, ".destroy"))
            {
                return true;
            }
        }
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
    const trimmed = mem.trimStart(u8, after, " \t");
    // Only direct assignment: `name = value`
    // NOT subscript: `name[i] = value` (this is a USE of name)
    if (mem.startsWith(u8, trimmed, "==")) return false;
    if (mem.startsWith(u8, trimmed, "[")) return false; // Subscript is a USE
    return mem.startsWith(u8, trimmed, "=");
}

/// Check if a line contains a direct reassignment of var_name: `var_name = ...`
/// Used to detect when a freed variable is reassigned to new memory.
/// Skips `==` (comparison), `[` (subscript), string literals, and field access.
fn hasDirectReassignment(t: []const u8, var_name: []const u8) bool {
    var s: usize = 0;
    while (mem.indexOf(u8, t[s..], var_name)) |rel| {
        const pos = s + rel;
        s = pos + var_name.len;
        // Word boundary checks
        if (pos + var_name.len < t.len and isIdent(t[pos + var_name.len])) continue;
        if (pos > 0 and isIdent(t[pos - 1])) continue;
        if (pos > 0 and t[pos - 1] == '.') continue; // field access
        if (isInsideString(t, pos)) continue;
        // Check for direct assignment (not ==, not subscript)
        if (isDirectAssignment(t, var_name, pos)) return true;
    }
    return false;
}

/// Check if var_name is reassigned on any line between from_line and to_line (exclusive).
/// Used by cross-block UAF detection to suppress false positives when a freed variable
/// is reassigned to new memory before the next use.
fn hasReassignmentBetween(
    lines: []const []const u8,
    func_line: usize,
    from_line: usize,
    to_line: usize,
    var_name: []const u8,
) bool {
    if (from_line == 0 or from_line >= to_line) return false;
    for (from_line + 1..to_line) |ln| {
        if (ln < func_line) continue;
        const idx = ln - func_line;
        if (idx >= lines.len) continue;
        const t = mem.trim(u8, lines[idx], " \t\r");
        if (hasDirectReassignment(t, var_name)) return true;
    }
    return false;
}

/// Check if position is an assignment target (not a read) - includes subscript
/// Check if text starts with `=` but not `==`
fn isAssignmentOp(text: []const u8) bool {
    if (!mem.startsWith(u8, text, "=")) return false;
    return !mem.startsWith(u8, text, "==");
}

/// Find closing bracket and check if `=` follows. Returns true if assignment.
fn hasAssignmentAfterBracket(text: []const u8) ?bool {
    var depth: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '[') depth += 1 else if (c == ']') {
            if (depth > 0) depth -= 1;
            if (depth == 0) {
                const after = mem.trimStart(u8, text[i + 1 ..], " \t");
                if (isAssignmentOp(after)) return true;
                // Continue through chained field.index access
                // e.g., [col].v[row] = sum
                if (after.len > 0 and (after[0] == '.' or after[0] == '['))
                    return hasAssignmentAfterChain(after);
                return false;
            }
        }
    }
    return null; // No closing bracket found
}

/// Follow chained .field and [index] access to find assignment
fn hasAssignmentAfterChain(text: []const u8) ?bool {
    var pos: usize = 0;
    while (pos < text.len) {
        if (text[pos] == '.') {
            pos += 1;
            while (pos < text.len and isIdent(text[pos])) pos += 1;
        } else if (text[pos] == '[') {
            var depth: usize = 0;
            for (text[pos..], 0..) |c, i| {
                if (c == '[') depth += 1 else if (c == ']') {
                    if (depth > 0) depth -= 1;
                    if (depth == 0) {
                        pos += i + 1;
                        break;
                    }
                }
            } else return null;
        } else {
            const after = mem.trimStart(u8, text[pos..], " \t");
            return isAssignmentOp(after);
        }
    }
    return null;
}

fn isAssignmentTarget(t: []const u8, name: []const u8, pos: usize) bool {
    if (pos + name.len >= t.len) return false;
    const after = t[pos + name.len ..];
    const trimmed = mem.trimStart(u8, after, " \t");
    if (isAssignmentOp(trimmed)) return true;

    // Field chain: name.field = value or name.field.sub = value
    if (mem.startsWith(u8, trimmed, ".")) {
        var j: usize = 0;
        while (j < trimmed.len and trimmed[j] == '.') {
            j += 1;
            while (j < trimmed.len and isIdent(trimmed[j])) j += 1;
        }
        const after_fields = mem.trimStart(u8, trimmed[j..], " \t");
        if (isAssignmentOp(after_fields)) return true;
        if (mem.startsWith(u8, after_fields, "["))
            return hasAssignmentAfterBracket(after_fields) orelse false;
        if (mem.startsWith(u8, after_fields, "*"))
            return isAssignmentOp(mem.trimStart(u8, after_fields[1..], " \t"));
    }

    // Subscript: name[i] = value or name[i][j] = value
    if (mem.startsWith(u8, trimmed, "[")) {
        return hasAssignmentAfterBracket(trimmed) orelse false;
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
        const pos = mem.indexOf(u8, t, name) orelse continue;
        if (isAssignmentTarget(t, name, pos)) continue;
        try issues.put(name, line);
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
    var preds: std.ArrayListUnmanaged(usize) = .empty;
    for (cfg.edges.items) |edge| {
        if (edge.to == block_id) try preds.append(allocator, edge.from);
    }
    return preds;
}

/// Check if a variable has an unconditional fill before any use
/// Returns true if filled before use, false if used first or no fill found
fn isConditionalStart(check_line: []const u8) bool {
    return mem.startsWith(u8, check_line, "if ") or
        mem.startsWith(u8, check_line, "if(") or
        mem.startsWith(u8, check_line, "else ") or
        mem.startsWith(u8, check_line, "else{");
}

fn isRealUseOfVar(check_line: []const u8, name: []const u8) bool {
    const pos = mem.indexOf(u8, check_line, name) orelse return false;
    const end_pos = pos + name.len;
    const is_word = (pos == 0 or !isIdent(check_line[pos - 1])) and
        (end_pos >= check_line.len or !isIdent(check_line[end_pos]));
    if (!is_word) return false;
    if (end_pos + 4 <= check_line.len and
        mem.eql(u8, check_line[end_pos .. end_pos + 4], ".len")) return false;
    if (isFillPattern(check_line, name)) return false;
    if (isAssignmentTarget(check_line, name, pos)) return false;
    if (mem.startsWith(u8, check_line, "var ")) return false;
    if (mem.startsWith(u8, check_line, "const ")) return false;
    return true;
}

fn countCloseBraces(check_line: []const u8, depth: usize) usize {
    var d = depth;
    for (check_line) |c| {
        if (c == '}' and d > 0) d -= 1;
    }
    return d;
}

fn isLoopStart(check_line: []const u8) bool {
    return mem.startsWith(u8, check_line, "while ") or
        mem.startsWith(u8, check_line, "for ");
}

fn hasUnconditionalFillBeforeUse(
    lines: []const []const u8,
    start_idx: usize,
    name: []const u8,
) bool {
    var nesting_depth: usize = 0;
    for (start_idx..lines.len) |check_idx| {
        const check_line = mem.trim(u8, lines[check_idx], " \t\r");
        if (isConditionalStart(check_line)) nesting_depth += 1;
        nesting_depth = countCloseBraces(check_line, nesting_depth);
        if (nesting_depth == 0 or isLoopStart(check_line)) {
            if (isFillPattern(check_line, name)) return true;
        }
        if (isRealUseOfVar(check_line, name) and nesting_depth == 0) return false;
        if (mem.startsWith(u8, check_line, "return ")) break;
        if (mem.eql(u8, check_line, "}")) break;
    }
    return false;
}

/// Compute gen set: which blocks assign a variable (includes loop fill patterns)
/// State for tracking for-loop scope during gen-set computation
const ForLoopTracker = struct {
    in_loop: bool = false,
    start_bid: ?usize = null,

    fn checkForStart(
        self: *ForLoopTracker,
        t: []const u8,
        cfg: *ControlFlowGraph,
        line: usize,
    ) void {
        if (mem.startsWith(u8, t, "for ") or mem.startsWith(u8, t, "for(")) {
            self.in_loop = true;
            self.start_bid = findBlockForLine(cfg, line);
        }
    }

    fn checkLoopEnd(self: *ForLoopTracker, t: []const u8) void {
        if (!self.in_loop or mem.indexOf(u8, t, "}") == null) return;
        var brace_count: i32 = 0;
        for (t) |c| {
            if (c == '{') brace_count += 1;
            if (c == '}') brace_count -= 1;
        }
        if (brace_count < 0) self.in_loop = false;
    }

    fn checkIndexedAssign(
        self: *const ForLoopTracker,
        t: []const u8,
        var_name: []const u8,
        gen: []bool,
    ) void {
        if (!self.in_loop) return;
        const pos = mem.indexOf(u8, t, var_name) orelse return;
        const end_pos = pos + var_name.len;
        if (end_pos >= t.len) return;
        // Pattern: var_name[...] = (direct indexed assignment)
        if (t[end_pos] == '[') {
            if (self.start_bid) |bid| gen[bid] = true;
            return;
        }
        // Pattern: var_name.field[...] = (field access + indexed)
        // Handles: result.v[col].v[row] = sum
        if (t[end_pos] == '.' and isAssignmentTarget(t, var_name, pos)) {
            if (self.start_bid) |bid| gen[bid] = true;
        }
    }
};

fn computeGenSetForVar(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    var_name: []const u8,
    num_blocks: usize,
) ![]bool {
    const gen = try allocator.alloc(bool, num_blocks);
    errdefer allocator.free(gen);
    @memset(gen, false);

    var tracker = ForLoopTracker{};
    for (lines, 0..) |line, idx| {
        const actual_line = func_line + idx;
        const t = mem.trim(u8, line, " \t\r");
        tracker.checkForStart(t, cfg, actual_line);
        tracker.checkIndexedAssign(t, var_name, gen);
        tracker.checkLoopEnd(t);

        if (isAssignmentTarget(t, var_name, 0) or isFillPattern(t, var_name)) {
            if (findBlockForLine(cfg, actual_line)) |bid| gen[bid] = true;
        }
        if (hasAddressOfVar(t, var_name)) {
            if (findBlockForLine(cfg, actual_line)) |bid| gen[bid] = true;
        }
    }
    return gen;
}

/// Check if a line takes the address of a variable (&var_name)
/// This indicates out-parameter usage where the variable may be assigned
fn hasAddressOfVar(t: []const u8, var_name: []const u8) bool {
    var search_start: usize = 0;
    while (search_start + 1 + var_name.len <= t.len) {
        const amp_pos = mem.indexOf(u8, t[search_start..], "&") orelse return false;
        const pos = search_start + amp_pos;
        search_start = pos + 1;

        // Must be immediately followed by var_name (no space)
        if (pos + 1 + var_name.len > t.len) continue;
        if (!mem.eql(u8, t[pos + 1 .. pos + 1 + var_name.len], var_name)) continue;

        // Check word boundary after var_name
        const end = pos + 1 + var_name.len;
        if (end < t.len and isIdent(t[end])) continue;

        // Make sure it's not inside a string or comment
        if (isInsideString(t, pos)) continue;
        if (mem.indexOf(u8, t[0..pos], "//")) |_| continue;

        return true;
    }
    return false;
}

/// Check if a line calls a method on a variable: var_name.method(
/// This covers patterns like: x.mul(...), x.initCapacity(...), x.div(...)
fn isAllIdent(s: []const u8) bool {
    for (s) |c| {
        if (!isIdent(c)) return false;
    }
    return true;
}

fn isMethodCallAt(t: []const u8, abs_pos: usize, var_name: []const u8) bool {
    if (abs_pos > 0 and isIdent(t[abs_pos - 1])) return false;
    const after = abs_pos + var_name.len;
    if (after >= t.len or t[after] != '.') return false;
    const rest = t[after + 1 ..];
    const paren = mem.indexOf(u8, rest, "(") orelse return false;
    const method_name = rest[0..paren];
    if (method_name.len == 0 or !isAllIdent(method_name)) return false;
    if (isInsideString(t, abs_pos)) return false;
    if (mem.indexOf(u8, t[0..abs_pos], "//") != null) return false;
    return true;
}

fn hasMethodCallOnVar(t: []const u8, var_name: []const u8) bool {
    var search_start: usize = 0;
    while (search_start + var_name.len + 2 <= t.len) {
        const pos = mem.indexOf(u8, t[search_start..], var_name) orelse return false;
        const abs_pos = search_start + pos;
        search_start = abs_pos + 1;
        if (isMethodCallAt(t, abs_pos, var_name)) return true;
    }
    return false;
}

/// Check if a line has an inline assembly output constraint for a variable.
/// Pattern: asm (...: [_] "={reg}" (var_name), ...)
fn hasAsmConstraintBefore(t: []const u8, abs_pos: usize) bool {
    if (abs_pos < 2) return false;
    const before = t[0..abs_pos];
    if (mem.lastIndexOf(u8, before, "\"") == null) return false;
    // "=" is write-only output, "~" is clobber, "+" is read-write output
    return mem.indexOf(u8, before, "\"=") != null or
        mem.indexOf(u8, before, "\"~") != null or
        mem.indexOf(u8, before, "\"+") != null;
}

fn hasAsmOutputVar(t: []const u8, var_name: []const u8) bool {
    // Check for asm output constraint on same line (single-line asm)
    // or on a continuation line of multi-line asm (constraint line without "asm" keyword)
    const has_asm = mem.indexOf(u8, t, "asm") != null;
    const has_output_constraint = mem.indexOf(u8, t, "\"=") != null or
        mem.indexOf(u8, t, "\"+") != null or
        mem.indexOf(u8, t, "\"~") != null;
    if (!has_asm and !has_output_constraint) return false;
    var search_start: usize = 0;
    while (search_start + 1 + var_name.len + 1 <= t.len) {
        const paren_pos = mem.indexOf(u8, t[search_start..], "(") orelse return false;
        const abs_pos = search_start + paren_pos;
        search_start = abs_pos + 1;
        const after = abs_pos + 1;
        if (after + var_name.len > t.len) continue;
        if (!mem.eql(u8, t[after .. after + var_name.len], var_name)) continue;
        const end = after + var_name.len;
        if (end >= t.len or t[end] != ')') continue;
        if (hasAsmConstraintBefore(t, abs_pos)) return true;
    }
    return false;
}

/// Detect comptime field assignment: @field(var_name, ...) = ...
/// This pattern is used in inline for/while loops over struct fields to populate a variable.
/// Handles both single-line: @field(result, field.name) = value
/// And multi-line: @field(result, switch (i) { ... }) = value
fn hasComptimeFieldAssignment(t: []const u8, var_name: []const u8) bool {
    const prefix = "@field(";
    var search_start: usize = 0;
    while (search_start + prefix.len + var_name.len + 1 <= t.len) {
        const pos = mem.indexOf(u8, t[search_start..], prefix) orelse return false;
        const abs_pos = search_start + pos;
        search_start = abs_pos + 1;

        // Check if inside string or comment
        if (isInsideString(t, abs_pos)) continue;
        if (mem.indexOf(u8, t[0..abs_pos], "//")) |_| continue;

        // After @field(, expect var_name followed by comma or )
        const after_paren = abs_pos + prefix.len;
        if (after_paren + var_name.len > t.len) continue;
        if (!mem.eql(u8, t[after_paren .. after_paren + var_name.len], var_name)) continue;

        // After var_name, expect comma or whitespace (not another identifier char)
        const after_name = after_paren + var_name.len;
        if (after_name >= t.len) continue;
        const next_ch = t[after_name];
        if (next_ch != ',' and next_ch != ')' and next_ch != ' ' and next_ch != '\t') continue;

        // @field(var_name, ...) found - this indicates comptime field population.
        // The closing ) and = may be on a later line (multi-line switch expression).
        return true;
    }
    return false;
}

/// Track comptime block depth by counting braces
const ComptimeState = struct {
    depth: usize = 0,
    brace_depth: usize = 0,

    fn update(self: *ComptimeState, t: []const u8) void {
        if (mem.indexOf(u8, t, "comptime ") != null or mem.indexOf(u8, t, "comptime{") != null) {
            self.depth += 1;
            self.brace_depth = 0;
            for (t) |c| {
                if (c == '{') self.brace_depth += 1;
            }
        }
        if (self.depth > 0) self.updateBraces(t);
    }

    fn updateBraces(self: *ComptimeState, t: []const u8) void {
        for (t) |c| {
            if (c == '{') self.brace_depth += 1;
            if (c == '}' and self.brace_depth > 0) {
                self.brace_depth -= 1;
                if (self.brace_depth == 0 and self.depth > 0) self.depth -= 1;
            }
        }
    }
};

/// Check if `= undefined` token is a complete token (not part of a longer identifier)
fn isCompleteUndefinedToken(t: []const u8, col: usize) bool {
    const after_undefined = col + "= undefined".len;
    if (after_undefined >= t.len) return true;
    const next_char = t[after_undefined];
    return !isIdent(next_char);
}

/// Collect variables declared with `= undefined`, skipping comptime blocks
/// Returns map of var_name -> declaration line
fn collectUndefinedVars(
    allocator: Allocator,
    lines: []const []const u8,
    func_line: usize,
) !std.StringHashMap(usize) {
    var undef_vars = std.StringHashMap(usize).init(allocator);
    var ct = ComptimeState{};

    for (lines, 0..) |line, idx| {
        const t = mem.trim(u8, line, " \t\r");
        ct.update(t);
        if (ct.depth > 0) continue;

        const col = mem.indexOf(u8, t, "= undefined") orelse continue;
        if (!isCompleteUndefinedToken(t, col)) continue;
        if (isInsideString(t, col)) continue;
        if (isStructFieldUndefined(t, col)) continue;

        const name = extractVarDeclName(t) orelse continue;
        if (hasUnconditionalFillBeforeUse(lines, idx + 1, name)) continue;
        try undef_vars.put(name, func_line + idx);
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

    var undef_vars = try collectUndefinedVars(
        allocator,
        lines,
        func_line,
    );
    defer undef_vars.deinit();
    if (undef_vars.count() == 0) return issues;

    try removeAddressOfVars(allocator, &undef_vars, lines);
    if (undef_vars.count() == 0) return issues;

    try removeIndirectlyInitVars(allocator, &undef_vars, lines);
    if (undef_vars.count() == 0) return issues;

    const num_blocks = cfg.blocks.items.len;
    if (num_blocks == 0) return issues;

    var var_iter = undef_vars.iterator();
    while (var_iter.next()) |entry| {
        const var_name = entry.key_ptr.*;
        const var_line = entry.value_ptr.*;
        try checkVarDefiniteAssignment(
            allocator,
            cfg,
            lines,
            func_line,
            var_name,
            var_line,
            num_blocks,
            &issues,
        );
    }

    return issues;
}

/// Remove vars passed by reference (&var) - can't track pointer writes.
fn removeAddressOfVars(
    allocator: Allocator,
    undef_vars: *std.StringHashMap(usize),
    lines: []const []const u8,
) !void {
    var remove = std.ArrayListUnmanaged([]const u8).empty;
    defer remove.deinit(allocator);
    var it = undef_vars.iterator();
    while (it.next()) |entry| {
        const vn = entry.key_ptr.*;
        for (lines) |line| {
            const t = mem.trim(u8, line, " \t\r");
            if (isCommentOrMultilineString(t)) continue;
            if (!hasAddressOfVar(t, vn)) continue;
            try remove.append(allocator, vn);
            break;
        }
    }
    for (remove.items) |vn| _ = undef_vars.remove(vn);
}

/// Remove vars initialized via method call, asm, or comptime field.
fn removeIndirectlyInitVars(
    allocator: Allocator,
    undef_vars: *std.StringHashMap(usize),
    lines: []const []const u8,
) !void {
    var remove = std.ArrayListUnmanaged([]const u8).empty;
    defer remove.deinit(allocator);
    var it = undef_vars.iterator();
    while (it.next()) |entry| {
        const vn = entry.key_ptr.*;
        if (isIndirectlyInitialized(lines, vn))
            try remove.append(allocator, vn);
    }
    for (remove.items) |vn| _ = undef_vars.remove(vn);
}

fn isIndirectlyInitialized(
    lines: []const []const u8,
    vn: []const u8,
) bool {
    var in_inline_for = false;
    var in_for_loop: usize = 0;
    for (lines) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;
        if (hasMethodCallOnVar(t, vn)) return true;
        if (hasAsmOutputVar(t, vn)) return true;
        if (hasComptimeFieldAssignment(t, vn)) return true;
        if (hasSlicePassToFunction(t, vn)) return true;
        if (isInlineForAssignment(t, vn, &in_inline_for))
            return true;
        // Track for-loop depth and detect array element assignment
        // inside for loops: for (...) |...| { ... args[i] = ...; }
        if (mem.startsWith(u8, t, "for ") or
            mem.startsWith(u8, t, "for("))
        {
            for (t) |c| {
                if (c == '{') in_for_loop += 1;
            }
        } else if (in_for_loop > 0) {
            for (t) |c| {
                if (c == '{') in_for_loop += 1;
                if (c == '}' and in_for_loop > 0) in_for_loop -= 1;
            }
            if (in_for_loop > 0 and isArrayIndexAssignment(t, vn))
                return true;
        }
    }
    return false;
}

/// Check if a line assigns to a variable via array indexing: `var_name[...] = ...`
fn isArrayIndexAssignment(t: []const u8, vn: []const u8) bool {
    var pos: usize = 0;
    while (mem.indexOfPos(u8, t, pos, vn)) |vpos| {
        // Word boundary check
        if (vpos > 0 and isIdent(t[vpos - 1])) {
            pos = vpos + vn.len;
            continue;
        }
        const end = vpos + vn.len;
        if (end >= t.len) {
            pos = end;
            continue;
        }
        if (isIdent(t[end])) {
            pos = end;
            continue;
        }
        // Check for `var_name[`
        if (t[end] == '[') return true;
        pos = end;
    }
    return false;
}

/// Check if a mutable slice of the variable is passed to a function call.
/// Pattern: func(var_name[0..]) or func(var_name[0..N])
/// Passing a mutable slice allows the callee to write into the array,
/// effectively initializing it (e.g., reader.readSliceShort(buf[0..])).
fn hasSlicePassToFunction(t: []const u8, vn: []const u8) bool {
    var pos: usize = 0;
    while (mem.indexOfPos(u8, t, pos, vn)) |vpos| {
        // Word boundary check before
        if (vpos > 0 and isIdent(t[vpos - 1])) {
            pos = vpos + vn.len;
            continue;
        }
        const end = vpos + vn.len;
        if (end >= t.len) {
            pos = end;
            continue;
        }
        // Word boundary check after
        if (isIdent(t[end])) {
            pos = end;
            continue;
        }
        // Skip if inside string or comment
        if (isInsideString(t, vpos)) {
            pos = end;
            continue;
        }
        if (mem.indexOf(u8, t[0..vpos], "//") != null) return false;
        // Check for var_name[ pattern (slice creation)
        if (t[end] != '[') {
            pos = end;
            continue;
        }
        // Must NOT be an assignment target (var_name[i] = ...),
        // which is a write, not a read-via-slice-pass.
        // We specifically want var_name[...] passed as a function argument.
        // Check if the enclosing context is a function call argument.
        // Look backwards for a '(' that indicates we're inside a function call.
        if (vpos > 0) {
            var depth: usize = 0;
            var j = vpos;
            while (j > 0) {
                j -= 1;
                if (t[j] == ')') depth += 1;
                if (t[j] == '(') {
                    if (depth == 0) return true;
                    depth -= 1;
                }
            }
        }
        pos = end;
    }
    return false;
}

/// Check if variable is assigned inside an inline for loop
/// Pattern: inline for (...) |...| { ... var_name.field = ... }
fn isInlineForAssignment(
    t: []const u8,
    vn: []const u8,
    in_inline_for: *bool,
) bool {
    if (mem.startsWith(u8, t, "inline for ") or
        mem.startsWith(u8, t, "inline for("))
    {
        in_inline_for.* = true;
    }
    if (!in_inline_for.*) return false;
    // Check if variable is being assigned via field/index access
    if (mem.indexOf(u8, t, vn)) |pos| {
        const end = pos + vn.len;
        if (end < t.len and (t[end] == '.' or t[end] == '[')) {
            if (isAssignmentTarget(t, vn, pos)) return true;
        }
    }
    // Track when inline for ends (simplified: close brace at line start)
    if (mem.eql(u8, t, "}") or mem.startsWith(u8, t, "} ")) {
        in_inline_for.* = false;
    }
    return false;
}

/// Run data flow analysis for one variable.
fn checkVarDefiniteAssignment(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    var_name: []const u8,
    var_line: usize,
    num_blocks: usize,
    issues: *std.StringHashMap(usize),
) !void {
    const def_entry = try allocator.alloc(bool, num_blocks);
    defer allocator.free(def_entry);
    const def_exit = try allocator.alloc(bool, num_blocks);
    defer allocator.free(def_exit);
    @memset(def_entry, false);
    @memset(def_exit, false);

    const gen = try computeGenSetForVar(
        allocator,
        cfg,
        lines,
        func_line,
        var_name,
        num_blocks,
    );
    defer allocator.free(gen);

    runDefiniteAssignmentWorklist(
        cfg,
        gen,
        def_entry,
        def_exit,
        num_blocks,
    );

    for (lines, 0..) |line, idx| {
        const al = func_line + idx;
        if (al <= var_line) continue;
        const t = mem.trim(u8, line, " \t\r");
        const bid = findBlockForLine(cfg, al) orelse continue;
        if (def_entry[bid] or gen[bid]) continue;
        if (!hasVarRead(t, var_name)) continue;
        // Check if the read is inside a correlated guard: the same if-condition
        // that gates the read also gates an earlier assignment of the variable.
        if (isCorrelatedGuardRead(lines, idx, var_name)) continue;
        // Check if the read is inside a null-guard on a variable that is only
        // set non-null in blocks that also assign the flagged variable.
        if (isNullGuardCorrelatedRead(lines, idx, var_name)) continue;
        // Check if all paths that don't assign the variable have early returns.
        // e.g., if (A) { k = 1; } else if (B) { k = 2; } else { return; }
        if (hasEarlyReturnOnUnassignedPaths(lines, var_name, idx)) continue;
        // Check if the read is on the RHS of an `or` short-circuit in a
        // condition where the LHS guards against the variable being
        // uninitialized.
        // e.g., if (param_group_t == null or i > param_group_end) {
        //            param_group_end = ...; }
        if (isOrShortCircuitSafe(lines, idx, var_name)) continue;
        try issues.put(var_name, al);
        break;
    }
}

/// Check if a variable read at `read_idx` is inside an if-block whose condition
/// also guards an earlier assignment to the same variable.
/// Pattern: if (cond) { x = val; } ... if (cond) { use(x); }
/// Also handles: for (...) { if (cond) { x = val; } } if (guard) |_| { use(x); }
/// where `guard` is a correlated variable assigned together with `x`.
fn isCorrelatedGuardRead(
    lines: []const []const u8,
    read_idx: usize,
    var_name: []const u8,
) bool {
    // Check all enclosing if conditions, not just the nearest one.
    // This handles nested ifs like:
    //   if (cy.Trace and cond) {  // outer
    //       if (x != tempRetainedStart) {  // inner - nearest
    // We need to check the outer condition too.
    var search_from = read_idx;
    while (search_from > 0) {
        const guard_cond = findEnclosingIfCondition(
            lines,
            search_from,
        ) orelse break;

        for (0..read_idx) |i| {
            const t = mem.trim(u8, lines[i], " \t\r");
            if (isCommentOrMultilineString(t)) continue;
            if (!hasIfCondition(t, guard_cond)) continue;
            if (blockContainsAssignment(
                lines,
                i + 1,
                read_idx,
                var_name,
            )) return true;
        }

        // Walk back further past the if we just found to check
        // outer enclosing ifs
        const if_line = findEnclosingIfLine(lines, search_from) orelse break;
        if (if_line == 0) break;
        search_from = if_line;
    }
    return false;
}

/// Check if a brace-delimited block starting at `start` contains an assignment
/// to `var_name`. Stops at `limit` or when the block closes.
fn blockContainsAssignment(
    lines: []const []const u8,
    start: usize,
    limit: usize,
    var_name: []const u8,
) bool {
    var block_depth: usize = 1;
    var j = start;
    while (j < limit and block_depth > 0) : (j += 1) {
        const inner = mem.trim(u8, lines[j], " \t\r");
        block_depth = computeBraceDepth(inner, block_depth);
        if (mem.indexOf(u8, inner, var_name)) |vpos| {
            if (isAssignmentTarget(inner, var_name, vpos)) return true;
        }
    }
    return false;
}

/// Compute brace depth for a line given initial depth, returning new depth.
fn computeBraceDepth(t: []const u8, initial: usize) usize {
    var depth = initial;
    for (t) |c| {
        if (c == '{') depth += 1;
        if (c == '}' and depth > 0) depth -= 1;
    }
    return depth;
}

/// Check if a variable read is inside a null-guard block for a correlated variable.
/// Pattern:
///   var guard: ?T = null;
///   var x = undefined;
///   ... if (cond) { guard = val; x = val2; } ...
///   if (guard) |_| { use(x); }
///
/// The variable `x` is safe to read because `guard` is only non-null when `x`
/// was also assigned in the same block.
fn isNullGuardCorrelatedRead(
    lines: []const []const u8,
    read_idx: usize,
    var_name: []const u8,
) bool {
    const guard_cond = findEnclosingIfCondition(lines, read_idx) orelse return false;
    if (!isNullInitializedVar(lines, guard_cond)) return false;
    return allGuardAssignsCorrelate(lines, read_idx, guard_cond, var_name);
}

/// Check if a variable is declared as `var name ... = null` anywhere in the lines.
fn isNullInitializedVar(lines: []const []const u8, name: []const u8) bool {
    for (lines) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;
        if (!mem.startsWith(u8, t, "var ")) continue;
        const after_var = t[4..];
        if (!mem.startsWith(u8, after_var, name)) continue;
        if (after_var.len > name.len and isIdent(after_var[name.len])) continue;
        if (mem.indexOf(u8, t, "= null") != null) return true;
    }
    return false;
}

/// Check that every non-null assignment to the guard also assigns the variable.
fn allGuardAssignsCorrelate(
    lines: []const []const u8,
    limit: usize,
    guard: []const u8,
    var_name: []const u8,
) bool {
    for (0..limit) |i| {
        const t = mem.trim(u8, lines[i], " \t\r");
        if (isCommentOrMultilineString(t)) continue;
        if (!isGuardAssignment(t, guard)) continue;
        if (mem.indexOf(u8, t, "= null") != null) continue;
        if (!isVarAssignedNearby(lines, i, var_name, 10)) return false;
    }
    return true;
}

/// Check if a line assigns to the guard variable (word-boundary aware).
fn isGuardAssignment(t: []const u8, guard: []const u8) bool {
    const gpos = mem.indexOf(u8, t, guard) orelse return false;
    if (gpos > 0 and isIdent(t[gpos - 1])) return false;
    if (gpos + guard.len < t.len and isIdent(t[gpos + guard.len])) return false;
    if (gpos > 0 and t[gpos - 1] == '.') return false;
    return isAssignmentTarget(t, guard, gpos);
}

/// Check if a variable is assigned within `radius` lines of `center_idx`.
fn isVarAssignedNearby(
    lines: []const []const u8,
    center_idx: usize,
    var_name: []const u8,
    radius: usize,
) bool {
    const start = if (center_idx > radius) center_idx - radius else 0;
    const end = @min(center_idx + radius, lines.len);
    for (start..end) |i| {
        const t = mem.trim(u8, lines[i], " \t\r");
        if (isCommentOrMultilineString(t)) continue;
        if (mem.indexOf(u8, t, var_name)) |vpos| {
            if (vpos > 0 and isIdent(t[vpos - 1])) continue;
            if (vpos + var_name.len < t.len and isIdent(t[vpos + var_name.len])) continue;
            if (isAssignmentTarget(t, var_name, vpos)) return true;
        }
    }
    return false;
}

/// Extract the condition from an enclosing if-statement by walking backwards.
/// Returns the condition string (e.g., "big" from "if (big) {") or null.
fn findEnclosingIfCondition(
    lines: []const []const u8,
    read_idx: usize,
) ?[]const u8 {
    // Walk backwards to find the nearest enclosing if
    var depth: usize = 0;
    var i = read_idx;
    while (i > 0) {
        i -= 1;
        const t = mem.trim(u8, lines[i], " \t\r");
        if (isCommentOrMultilineString(t)) continue;

        // Count braces backwards: } increases depth, { decreases
        for (t) |c| {
            if (c == '}') depth += 1;
            if (c == '{' and depth > 0) depth -= 1;
        }

        // At depth 0, look for if-statement
        if (depth == 0) {
            if (extractIfCondition(t)) |cond| return cond;
        }
    }
    return null;
}

/// Find the line index of the nearest enclosing if-statement by walking
/// backwards. Returns the line index or null if not found.
fn findEnclosingIfLine(
    lines: []const []const u8,
    read_idx: usize,
) ?usize {
    var depth: usize = 0;
    var i = read_idx;
    while (i > 0) {
        i -= 1;
        const t = mem.trim(u8, lines[i], " \t\r");
        if (isCommentOrMultilineString(t)) continue;

        for (t) |c| {
            if (c == '}') depth += 1;
            if (c == '{' and depth > 0) depth -= 1;
        }

        if (depth == 0) {
            if (extractIfCondition(t) != null) return i;
        }
    }
    return null;
}

/// Extract the condition text from an if-statement line.
/// "if (big) {" -> "big", "if (minWindow) |other| {" -> "minWindow"
fn extractIfCondition(t: []const u8) ?[]const u8 {
    // Must start with "if " or "} else if " or "if("
    var rest: []const u8 = undefined;
    if (mem.startsWith(u8, t, "if ") or mem.startsWith(u8, t, "if(")) {
        rest = t[2..];
    } else if (mem.startsWith(u8, t, "} else if ") or mem.startsWith(u8, t, "} else if(")) {
        rest = t[9..];
    } else {
        return null;
    }
    rest = mem.trimStart(u8, rest, " \t");
    if (rest.len == 0 or rest[0] != '(') return null;
    // Find matching close paren
    var paren_depth: usize = 0;
    for (rest, 0..) |c, ci| {
        if (c == '(') paren_depth += 1;
        if (c == ')') {
            paren_depth -= 1;
            if (paren_depth == 0) {
                return mem.trim(u8, rest[1..ci], " \t");
            }
        }
    }
    return null;
}

/// Check if a line contains an if-statement with the given condition.
fn hasIfCondition(t: []const u8, cond: []const u8) bool {
    const line_cond = extractIfCondition(t) orelse return false;
    return mem.eql(u8, line_cond, cond);
}

/// Check if all code paths that don't assign `var_name` before `read_idx`
/// contain an early return/break/continue, making the variable definitely assigned
/// at the read point.
///
/// Scans forward through the function lines to find if/else-if/else chains.
/// For each complete chain (must have else or else-if ending), checks whether
/// every branch either assigns the variable or exits.
///
/// Pattern: if (A) { x = 1; } else if (B) { x = 2; } else { return; }
fn hasEarlyReturnOnUnassignedPaths(
    lines: []const []const u8,
    var_name: []const u8,
    read_idx: usize,
) bool {
    // Forward scan: find if/else chains and check branch properties
    var i: usize = 0;
    while (i < read_idx) {
        const t = mem.trim(u8, lines[i], " \t\r");
        if (isCommentOrMultilineString(t)) {
            i += 1;
            continue;
        }

        // Look for if-start at the current nesting level
        if (!isIfStart(t)) {
            i += 1;
            continue;
        }

        // Found an if-start. Collect all branches of this if/else chain.
        if (checkIfElseChainComplete(lines, i, read_idx, var_name))
            return true;

        // Skip past this if block to avoid re-processing
        i = skipBracedBlock(lines, i, read_idx);
        i += 1;
    }
    return false;
}

fn isIfStart(t: []const u8) bool {
    return mem.startsWith(u8, t, "if ") or mem.startsWith(u8, t, "if(");
}

fn isElseIfLine(t: []const u8) bool {
    return mem.startsWith(u8, t, "} else if") or
        mem.startsWith(u8, t, "else if ") or
        mem.startsWith(u8, t, "else if(");
}

fn isElseLine(t: []const u8) bool {
    return mem.startsWith(u8, t, "} else {") or
        mem.startsWith(u8, t, "} else{") or
        mem.eql(u8, t, "else {") or
        mem.eql(u8, t, "else{");
}

/// Skip past a braced block starting at `start_idx`, returning the index of
/// the closing `}` (or `limit-1` if not found).
fn skipBracedBlock(
    lines: []const []const u8,
    start_idx: usize,
    limit: usize,
) usize {
    var depth: usize = 0;
    var found_open = false;
    for (start_idx..limit) |i| {
        const t = mem.trim(u8, lines[i], " \t\r");
        const prev_depth = depth;
        depth = computeBraceDepth(t, depth);
        if (!found_open and depth > prev_depth) found_open = true;
        if (found_open and depth == 0) return i;
    }
    return if (limit > 0) limit - 1 else 0;
}

/// Check a complete if/else-if/else chain starting at `if_start`.
/// Returns true if the variable is definitely assigned after the chain
/// (every branch either assigns it or exits).
const BranchList = struct {
    starts: [32]usize = undefined,
    ends: [32]usize = undefined,
    count: usize = 0,

    fn add(self: *BranchList, start: usize, end: usize) bool {
        if (self.count >= 32) return false;
        self.starts[self.count] = start;
        self.ends[self.count] = end;
        self.count += 1;
        return true;
    }
};

/// Result of tracking braces through a line with zero-detection.
const BraceZeroResult = struct {
    depth: usize,
    found_open: bool,
    touched_zero: bool,
};

/// Track braces through a line, detecting if depth passes through 0.
fn trackBracesWithZeroDetect(
    t: []const u8,
    initial_depth: usize,
    initial_open: bool,
) BraceZeroResult {
    var depth = initial_depth;
    var found_open = initial_open;
    var touched_zero = false;
    for (t) |c| {
        if (c == '{') {
            depth += 1;
            if (!found_open) found_open = true;
        }
        if (c == '}' and depth > 0) {
            depth -= 1;
            if (found_open and depth == 0) touched_zero = true;
        }
    }
    return .{
        .depth = depth,
        .found_open = found_open,
        .touched_zero = touched_zero,
    };
}

/// Try to continue an if/else chain from the next line after a block closes.
/// Returns the index to continue from, or null if chain ends.
fn tryChainContinuation(
    lines: []const []const u8,
    current: usize,
    limit: usize,
) ?usize {
    const next_idx = skipCommentLines(lines, current + 1, limit);
    if (next_idx >= limit) return null;
    const next_t = mem.trim(u8, lines[next_idx], " \t\r");
    if (isElseIfLine(next_t) or isElseLine(next_t)) return next_idx;
    return null;
}

/// State for parsing an if/else chain into branches.
const ChainParseState = struct {
    branches: BranchList = BranchList{},
    depth: usize = 0,
    found_open: bool = false,
    branch_start: usize = 0,
    has_else: bool = false,
    i: usize = 0,
    done: bool = false,
    overflow: bool = false,

    /// Process a single line in the chain. Returns the next index to
    /// use for the outer loop (may skip ahead for next-line continuations).
    fn processLine(
        self: *ChainParseState,
        lines: []const []const u8,
        limit: usize,
    ) void {
        const t = mem.trim(u8, lines[self.i], " \t\r");
        if (isCommentOrMultilineString(t)) return;

        const r = trackBracesWithZeroDetect(t, self.depth, self.found_open);
        self.depth = r.depth;
        self.found_open = r.found_open;
        if (!r.touched_zero) return;

        if (!self.branches.add(self.branch_start, self.i)) {
            self.overflow = true;
            self.done = true;
            return;
        }

        if (self.depth > 0) {
            if (isElseLine(t)) self.has_else = true;
            self.branch_start = self.i;
            return;
        }

        self.handleNextLineContinuation(lines, limit);
    }

    fn handleNextLineContinuation(
        self: *ChainParseState,
        lines: []const []const u8,
        limit: usize,
    ) void {
        const next_idx = tryChainContinuation(
            lines,
            self.i,
            limit,
        ) orelse {
            self.done = true;
            return;
        };
        const next_t = mem.trim(u8, lines[next_idx], " \t\r");
        if (isElseLine(next_t)) self.has_else = true;
        self.branch_start = next_idx;
        self.i = next_idx;
        const nr = trackBracesWithZeroDetect(
            next_t,
            self.depth,
            self.found_open,
        );
        self.depth = nr.depth;
        self.found_open = nr.found_open;
    }
};

fn checkIfElseChainComplete(
    lines: []const []const u8,
    if_start: usize,
    limit: usize,
    var_name: []const u8,
) bool {
    var state = ChainParseState{
        .branch_start = if_start,
        .i = if_start,
    };

    while (state.i < limit) : (state.i += 1) {
        state.processLine(lines, limit);
        if (state.done) break;
    }

    if (state.overflow) return false;
    if (!state.has_else or state.branches.count < 2) return false;
    return validateBranchCoverage(lines, &state.branches, var_name);
}

/// Collect else-if and else branches following an if block.
/// Returns true if the chain ends with a final else.
fn collectElseBranches(
    lines: []const []const u8,
    block_end: *usize,
    limit: usize,
    branches: *BranchList,
) bool {
    while (block_end.* + 1 < limit) {
        const close_t = mem.trim(u8, lines[block_end.*], " \t\r");
        const next_idx = skipCommentLines(lines, block_end.* + 1, limit);
        if (next_idx >= limit) break;
        const next_t = mem.trim(u8, lines[next_idx], " \t\r");

        // "} else if" or "} else" on the closing line itself
        if (isElseIfLine(close_t) or isElseLine(close_t)) {
            const prev_end = branches.ends[branches.count - 1];
            block_end.* = skipBracedBlock(lines, block_end.*, limit);
            if (block_end.* >= limit) return false;
            if (!branches.add(prev_end, block_end.*)) return false;
            if (isElseLine(close_t)) return true;
            continue;
        }

        // "else if" or "else" on the NEXT non-comment line (separated from })
        if (isElseIfLine(next_t) or isElseLine(next_t)) {
            block_end.* = skipBracedBlock(lines, next_idx, limit);
            if (block_end.* >= limit) return false;
            if (!branches.add(next_idx, block_end.*)) return false;
            if (isElseLine(next_t)) return true;
            continue;
        }
        break;
    }
    return false;
}

/// Skip comment and multiline-string lines starting at `start`.
fn skipCommentLines(lines: []const []const u8, start: usize, limit: usize) usize {
    var idx = start;
    while (idx < limit) {
        if (!isCommentOrMultilineString(mem.trim(u8, lines[idx], " \t\r"))) break;
        idx += 1;
    }
    return idx;
}

/// Validate that every branch assigns the variable or exits.
fn validateBranchCoverage(
    lines: []const []const u8,
    branches: *const BranchList,
    var_name: []const u8,
) bool {
    var has_assignment = false;
    for (0..branches.count) |bi| {
        const assigns = branchAssignsVar(lines, branches.starts[bi], branches.ends[bi], var_name);
        const exits = branchHasExit(lines, branches.starts[bi], branches.ends[bi]);
        if (!assigns and !exits) return false;
        if (assigns) has_assignment = true;
    }
    return has_assignment;
}

/// Check if a branch (lines[start..end]) assigns the variable.
fn branchAssignsVar(
    lines: []const []const u8,
    start: usize,
    end: usize,
    var_name: []const u8,
) bool {
    const actual_end = @min(end, lines.len - 1);
    for (start..actual_end + 1) |i| {
        const t = mem.trim(u8, lines[i], " \t\r");
        if (isCommentOrMultilineString(t)) continue;
        // Check for assignment at any position in the line
        if (mem.indexOf(u8, t, var_name)) |vpos| {
            if (vpos > 0 and isIdent(t[vpos - 1])) continue;
            if (vpos + var_name.len < t.len and isIdent(t[vpos + var_name.len])) continue;
            if (isAssignmentTarget(t, var_name, vpos)) return true;
        }
    }
    return false;
}

/// Check if a branch has an unconditional exit (return/break/continue/unreachable).
fn branchHasExit(
    lines: []const []const u8,
    start: usize,
    end: usize,
) bool {
    const actual_end = @min(end, lines.len - 1);
    var depth: usize = 0;
    for (start..actual_end + 1) |i| {
        const t = mem.trim(u8, lines[i], " \t\r");
        if (isCommentOrMultilineString(t)) continue;
        depth = computeBraceDepth(t, depth);
        if (depth <= 1 and isExitStatement(t)) return true;
    }
    return false;
}

fn isExitStatement(t: []const u8) bool {
    return mem.startsWith(u8, t, "return ") or
        mem.startsWith(u8, t, "return;") or
        mem.eql(u8, t, "return") or
        mem.startsWith(u8, t, "break;") or
        mem.startsWith(u8, t, "continue;") or
        mem.eql(u8, t, "unreachable;") or
        mem.eql(u8, t, "unreachable,");
}

/// Check if a variable read is safe due to `or` short-circuit evaluation.
/// Pattern: `if (guard == null or i > var_name)` where the variable is
/// assigned inside the if-block body. When `guard == null` is true, the
/// RHS (`i > var_name`) is never evaluated, so the read is safe. When
/// `guard != null`, the variable was assigned in a prior iteration.
fn isOrShortCircuitSafe(
    lines: []const []const u8,
    read_idx: usize,
    var_name: []const u8,
) bool {
    const t = mem.trim(u8, lines[read_idx], " \t\r");
    // The read must be in an if-condition containing " or "
    const or_pos = mem.indexOf(u8, t, " or ") orelse return false;
    // The variable read must be on the RIGHT side of " or "
    const vpos = mem.indexOf(u8, t, var_name) orelse return false;
    if (vpos <= or_pos) return false;
    // Word boundary check
    if (vpos > 0 and isIdent(t[vpos - 1])) return false;
    if (vpos + var_name.len < t.len and
        isIdent(t[vpos + var_name.len])) return false;
    // Must be in an if-condition
    if (!mem.startsWith(u8, t, "if ") and
        !mem.startsWith(u8, t, "if(")) return false;
    // The variable must be assigned inside the if-block body
    if (read_idx + 1 < lines.len) {
        return blockContainsAssignment(
            lines,
            read_idx + 1,
            @min(read_idx + 20, lines.len),
            var_name,
        );
    }
    return false;
}

fn runDefiniteAssignmentWorklist(
    cfg: *ControlFlowGraph,
    gen: []const bool,
    def_entry: []bool,
    def_exit: []bool,
    num_blocks: usize,
) void {
    const max = @min(num_blocks, std.math.maxInt(usize) / 2 - 1) *| 2 +| 1;
    var changed = true;
    var iters: usize = 0;
    while (changed and iters < max) : (iters += 1) {
        changed = false;
        for (0..num_blocks) |bid| {
            const new_in = computeBlockEntry(cfg, def_exit, bid);
            const new_out = gen[bid] or new_in;
            if (def_entry[bid] == new_in and def_exit[bid] == new_out) continue;
            def_entry[bid] = new_in;
            def_exit[bid] = new_out;
            changed = true;
        }
    }
}

fn computeBlockEntry(
    cfg: *ControlFlowGraph,
    def_exit: []const bool,
    bid: usize,
) bool {
    var result: bool = true;
    var has_pred = false;
    for (cfg.edges.items) |edge| {
        if (edge.to != bid) continue;
        if (edge.kind == .loop_back) continue;
        // Skip return blocks - they never flow to the merge point,
        // so they shouldn't affect definite assignment analysis.
        // e.g., if (A) { x = 1; } else { return; } // x is definitely assigned here
        if (edge.from < cfg.blocks.items.len and
            cfg.blocks.items[edge.from].is_return) continue;
        has_pred = true;
        if (!def_exit[edge.from]) result = false;
    }
    return if (has_pred) result else false;
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

        // Skip if inside a string literal
        // e.g., std.mem.eql(u8, field_name, "range") is not a read of var range
        if (isInsideString(t, i)) continue;

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
/// Track a single defer/errdefer keyword depth for one line.
/// Returns updated depth after processing braces on the line.
fn trackBlockDepth(t: []const u8, depth: usize) usize {
    var d = depth;
    for (t) |c| {
        if (c == '{') d += 1;
        if (c == '}' and d > 0) d -= 1;
    }
    return d;
}

/// Process one line for errdefer/defer block tracking.
fn markDeferLine(
    t: []const u8,
    idx: usize,
    markers: []bool,
    depth: *usize,
    start_prefix1: []const u8,
    start_prefix2: []const u8,
) void {
    if (mem.startsWith(u8, t, start_prefix1) or mem.startsWith(u8, t, start_prefix2)) {
        depth.* += 1;
        depth.* = trackBlockDepth(t, depth.*);
        markers[idx] = true;
        return;
    }
    if (depth.* > 0) {
        markers[idx] = true;
        depth.* = trackBlockDepth(t, depth.*);
    }
}

fn markDeferAndErrdeferBlocks(allocator: Allocator, lines: []const []const u8) !DeferBlockMarkers {
    const in_errdefer = try allocator.alloc(bool, lines.len);
    errdefer allocator.free(in_errdefer);
    const in_defer = try allocator.alloc(bool, lines.len);
    @memset(in_errdefer, false);
    @memset(in_defer, false);

    var errdefer_depth: usize = 0;
    var defer_depth: usize = 0;
    for (lines, 0..) |line, idx| {
        const t = mem.trim(u8, line, " \t\r");
        markDeferLine(t, idx, in_errdefer, &errdefer_depth, "errdefer ", "errdefer{");
        if (!in_errdefer[idx])
            markDeferLine(t, idx, in_defer, &defer_depth, "defer {", "defer{");
    }
    return .{ .in_defer = in_defer, .in_errdefer = in_errdefer };
}

/// Analyze memory states through CFG for path-sensitive use-after-free and double-free
/// This properly handles patterns like: catch { free(x); return; }
/// where the free only occurs on the early-return path, not the main path
fn analyzeOneAllocSafety(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
    alloc_info: *CFGAllocation,
    in_defer: []const bool,
    in_errdefer: []const bool,
    num_blocks: usize,
    issues: *std.ArrayListUnmanaged(Issue),
    aliases: *const std.StringHashMapUnmanaged([]const u8),
) !void {
    var bstate = try initAndScanFreeState(
        allocator,
        cfg,
        lines,
        func_line,
        alloc_info,
        in_defer,
        in_errdefer,
        num_blocks,
    );
    defer bstate.deinit(allocator);
    try detectUseAfterFree(
        allocator,
        cfg,
        lines,
        func_line,
        file_path,
        alloc_info.name,
        alloc_info,
        in_errdefer,
        in_defer,
        &bstate,
        issues,
        aliases,
    );
    try detectDoubleFree(
        allocator,
        cfg,
        lines,
        func_line,
        file_path,
        alloc_info.name,
        alloc_info,
        in_defer,
        in_errdefer,
        &bstate,
        issues,
    );
}

fn initAndScanFreeState(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    alloc_info: *CFGAllocation,
    in_defer: []const bool,
    in_errdefer: []const bool,
    num_blocks: usize,
) !BlockFreeState {
    var bstate = try initBlockFreeState(allocator, num_blocks);
    scanBlocksForFreeOps(
        cfg,
        lines,
        func_line,
        alloc_info.name,
        in_defer,
        in_errdefer,
        alloc_info,
        &bstate,
    );
    return bstate;
}

fn analyzeCFGMemorySafety(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
    file_no_free_fields: ?*const std.StringHashMapUnmanaged(void),
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    var allocs = try collectMemSafetyAllocs(allocator, lines, func_line, file_no_free_fields);
    defer allocs.deinit();
    if (allocs.count() == 0) return issues;
    const num_blocks = cfg.blocks.items.len;
    if (num_blocks == 0) return issues;

    // Build alias map: alias_name -> original_alloc_name
    // Tracks patterns like `const alias = data;` where `data` is a tracked allocation
    var aliases = try collectAliases(allocator, lines, &allocs);
    defer aliases.deinit(allocator);

    const markers = try markDeferAndErrdeferBlocks(allocator, lines);
    defer allocator.free(markers.in_defer);
    defer allocator.free(markers.in_errdefer);

    var alloc_iter = allocs.iterator();
    while (alloc_iter.next()) |entry| {
        try analyzeOneAllocSafety(
            allocator,
            cfg,
            lines,
            func_line,
            file_path,
            entry.value_ptr,
            markers.in_defer,
            markers.in_errdefer,
            num_blocks,
            &issues,
            &aliases,
        );
    }
    return issues;
}

/// Collect variable aliases for tracked allocations.
/// Scans for `const alias = original;` or `var alias = original;` patterns
/// where `original` is a tracked allocation name. Returns alias_name -> original_name map.
fn collectAliases(
    a: Allocator,
    lines: []const []const u8,
    allocs: *const std.StringHashMap(CFGAllocation),
) !std.StringHashMapUnmanaged([]const u8) {
    var aliases = std.StringHashMapUnmanaged([]const u8){};

    for (lines) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;

        // Match: const X = Y; or var X = Y;
        if (!mem.startsWith(u8, t, "const ") and !mem.startsWith(u8, t, "var ")) continue;
        const name = extractVarDeclName(t) orelse continue;

        // Don't track if this name is itself an allocation (not an alias)
        if (allocs.contains(name)) continue;

        const eq_pos = mem.indexOf(u8, t, " = ") orelse continue;
        var rhs = mem.trim(u8, t[eq_pos + 3 ..], " \t");

        // Strip trailing semicolon
        if (rhs.len > 0 and rhs[rhs.len - 1] == ';') rhs = rhs[0 .. rhs.len - 1];
        rhs = mem.trim(u8, rhs, " \t");

        // RHS must be a simple identifier (the original variable name)
        if (rhs.len == 0) continue;
        var all_ident = true;
        for (rhs) |c| {
            if (!isIdent(c)) {
                all_ident = false;
                break;
            }
        }
        if (!all_ident) continue;

        // Check if RHS is a tracked allocation
        if (allocs.contains(rhs)) {
            try aliases.put(a, name, rhs);
        }
    }

    return aliases;
}

/// Per-block free tracking state for memory safety analysis.
const BlockFreeState = struct {
    freed_in_block: []bool,
    block_returns_after_free: []bool,
    freed_line_in_block: []usize,

    fn deinit(self: *BlockFreeState, a: Allocator) void {
        a.free(self.freed_in_block);
        a.free(self.block_returns_after_free);
        a.free(self.freed_line_in_block);
    }
};

fn initBlockFreeState(
    a: Allocator,
    n: usize,
) !BlockFreeState {
    var s: BlockFreeState = undefined;
    s.freed_in_block = try a.alloc(bool, n);
    s.block_returns_after_free = try a.alloc(bool, n);
    s.freed_line_in_block = try a.alloc(usize, n);
    @memset(s.freed_in_block, false);
    @memset(s.block_returns_after_free, false);
    @memset(s.freed_line_in_block, 0);
    return s;
}

fn collectMemSafetyAllocs(
    allocator: Allocator,
    lines: []const []const u8,
    func_line: usize,
    file_no_free_fields: ?*const std.StringHashMapUnmanaged(void),
) !std.StringHashMap(CFGAllocation) {
    // Build type-tracked allocator sets (stdlib types only)
    var local_no_free_fields = try collectNoFreeFieldNames(allocator, lines);
    defer local_no_free_fields.deinit(allocator);
    var no_free_names = try collectNoFreeAllocatorNames(allocator, lines, file_no_free_fields);
    defer no_free_names.deinit(allocator);
    var all_alloc_names = try collectAllAllocatorNames(allocator, lines);
    defer all_alloc_names.deinit(allocator);

    var allocs = std.StringHashMap(CFGAllocation).init(allocator);
    for (lines, 0..) |line, idx| {
        const actual_line = func_line + idx;
        const t = mem.trim(u8, line, " \t\r");
        // Type-based allocation detection: .alloc() or .create() on tracked allocators
        const alloc_call = findAllocCall(t, &all_alloc_names) orelse continue;
        // Skip allocations from type-tracked no-free allocators (stdlib types only)
        const alloc_name = extractAllocatorName(t) orelse "";
        if (alloc_name.len > 0 and no_free_names.contains(alloc_name)) continue;
        if (isNoFreeCallChainFull(t, &no_free_names, &local_no_free_fields)) continue;
        if (isNoFreeFieldChain(t, &local_no_free_fields)) continue;
        // Check file-level no-free fields (struct definitions outside this function)
        if (file_no_free_fields) |fields| {
            if (isNoFreeCallChainFull(t, &no_free_names, fields)) continue;
            if (isNoFreeFieldChain(t, fields)) continue;
        }
        // For standalone/method-style calls where allocator is an argument (not receiver),
        // check the first-arg allocator for no-free suppression
        if (extractStandaloneAllocator(t)) |standalone_alloc| {
            if (no_free_names.contains(standalone_alloc)) continue;
            if (isArenaName(standalone_alloc)) continue;
        } else if (extractMultilineFirstArg(t, lines, idx)) |ml_alloc| {
            if (no_free_names.contains(ml_alloc)) continue;
            if (isArenaName(ml_alloc)) continue;
        }
        // Dotted first-arg arena heuristic: allocPrint(cg.module.arena, ...)
        if (isFirstArgArena(t)) continue;
        const name = extractVarDeclName(t) orelse continue;
        try allocs.put(name, .{
            .name = name,
            .alloc_line = actual_line,
            .alloc_col = alloc_call.col + 1,
            .state = .allocated,
            .is_create = alloc_call.is_create,
        });
    }
    return allocs;
}

fn shouldSkipForFreeAnalysis(
    t: []const u8,
    idx: usize,
    in_defer: []const bool,
    in_errdefer: []const bool,
) bool {
    if (in_errdefer[idx]) return true;
    if (in_defer[idx]) return true;
    if (mem.startsWith(u8, t, "defer ")) return true;
    return isCommentOrMultilineString(t);
}

const BlockScanResult = struct {
    free_seen: bool = false,
    return_after: bool = false,
    free_line: usize = 0,
};

fn scanBlockForFreeOp(
    block: BasicBlock,
    lines: []const []const u8,
    func_line: usize,
    var_name: []const u8,
    in_defer: []const bool,
    in_errdefer: []const bool,
) BlockScanResult {
    var r = BlockScanResult{};
    for (block.start_line..block.end_line + 1) |ln| {
        if (ln < func_line) continue;
        const idx = ln - func_line;
        if (idx >= lines.len) continue;
        const t = mem.trim(u8, lines[idx], " \t\r");
        if (shouldSkipForFreeAnalysis(t, idx, in_defer, in_errdefer))
            continue;
        if (hasRealFreePattern(t) and isDirectFreeOfVar(t, var_name)) {
            r.free_seen = true;
            r.free_line = ln;
        }
        if (r.free_seen and mem.startsWith(u8, t, "return"))
            r.return_after = true;
    }
    return r;
}

fn scanBlocksForFreeOps(
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    var_name: []const u8,
    in_defer: []const bool,
    in_errdefer: []const bool,
    alloc_info: *CFGAllocation,
    bstate: *BlockFreeState,
) void {
    for (cfg.blocks.items, 0..) |block, bid| {
        if (block.start_line == 0 or
            block.start_line > block.end_line) continue;
        const r = scanBlockForFreeOp(
            block,
            lines,
            func_line,
            var_name,
            in_defer,
            in_errdefer,
        );
        bstate.freed_in_block[bid] = r.free_seen;
        bstate.freed_line_in_block[bid] = r.free_line;
        bstate.block_returns_after_free[bid] = r.return_after;
        if (r.free_seen and alloc_info.freed_line == 0)
            alloc_info.freed_line = r.free_line;
    }
}

fn isExclusiveBranchLine(t: []const u8) bool {
    if (mem.indexOf(u8, t, "=>") != null) return true;
    if (mem.indexOf(u8, t, "} orelse {") != null) return true;
    if (mem.indexOf(u8, t, "} orelse return") != null) return true;
    if (mem.startsWith(u8, t, "orelse {")) return true;
    if (mem.indexOf(u8, t, "} else {") != null) return true;
    return false;
}

fn hasExclusiveBranchBetween(
    lines: []const []const u8,
    from_line: usize,
    to_line: usize,
    func_line: usize,
) bool {
    if (from_line == 0 or from_line >= to_line) return false;
    for (from_line + 1..to_line) |ln| {
        if (ln < func_line) continue;
        const idx = ln - func_line;
        if (idx >= lines.len) continue;
        const t = mem.trim(u8, lines[idx], " \t\r");
        if (isExclusiveBranchLine(t)) return true;
    }
    return false;
}

fn findVarUseOnLine(t: []const u8, vn: []const u8) ?usize {
    var s: usize = 0;
    while (mem.indexOf(u8, t[s..], vn)) |rel| {
        const pos = s + rel;
        s = pos + vn.len;
        if (pos + vn.len < t.len and isIdent(t[pos + vn.len]))
            continue;
        if (pos > 0 and isIdent(t[pos - 1])) continue;
        if (pos > 0 and t[pos - 1] == '.') continue;
        // Capture binding: |var| in for/while/switch/catch creates a new binding
        if (pos > 0 and t[pos - 1] == '|') continue;
        if (isInsideString(t, pos)) continue;
        if (isDirectAssignment(t, vn, pos)) continue;
        return pos;
    }
    return null;
}

const SameBlockFreeResult = struct {
    freed: bool,
    intervening_return: bool,
};

fn checkSameBlockFree(
    lines: []const []const u8,
    func_line: usize,
    block_start: usize,
    actual_line: usize,
    var_name: []const u8,
    alloc_info: *CFGAllocation,
    in_defer: []const bool,
    in_errdefer: []const bool,
) SameBlockFreeResult {
    var freed = false;
    var ret = false;
    for (block_start..actual_line) |cl| {
        if (cl < func_line) continue;
        const ci = cl - func_line;
        if (ci >= lines.len) continue;
        const ct = mem.trim(u8, lines[ci], " \t\r");
        if (shouldSkipForFreeAnalysis(ct, ci, in_defer, in_errdefer))
            continue;
        if (hasRealFreePattern(ct) and isDirectFreeOfVar(ct, var_name)) {
            freed = true;
            alloc_info.freed_line = cl;
        }
        // Reassignment after free: `var_name = ...` resets freed state
        // (the variable now points to new memory, not the freed allocation)
        if (freed and hasDirectReassignment(ct, var_name)) {
            freed = false;
        }
        if (freed and mem.startsWith(u8, ct, "return")) ret = true;
    }
    return .{ .freed = freed, .intervening_return = ret };
}

fn appendUAFIssue(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    file_path: []const u8,
    line: usize,
    col: usize,
    var_name: []const u8,
    freed_line: usize,
) !void {
    const msg = try std.fmt.allocPrint(
        allocator,
        "use-after-free: '{s}' freed on {d}",
        .{ var_name, freed_line },
    );
    try issues.append(allocator, .{
        .file = file_path,
        .line = line,
        .col = col + 1,
        .severity = .err,
        .rule = RULE_USE_AFTER_FREE,
        .message = msg,
        .message_owned = true,
        .help = "don't access freed memory",
    });
}

fn checkPredecessorsFreed(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    bid: usize,
    bstate: *const BlockFreeState,
) !bool {
    var preds = try getBlockPredecessors(cfg, bid, allocator);
    defer preds.deinit(allocator);
    if (preds.items.len == 0) return false;
    var def_freed = true;
    var any_normal = false;
    for (preds.items) |pred| {
        if (bstate.block_returns_after_free[pred]) continue;
        any_normal = true;
        if (!bstate.freed_in_block[pred]) def_freed = false;
    }
    return any_normal and def_freed;
}

fn isUAFSkipLine(t: []const u8) bool {
    if (mem.startsWith(u8, t, "const ") or mem.startsWith(u8, t, "var ")) return true;
    if (hasRealFreePattern(t)) return true;
    if (mem.startsWith(u8, t, "defer")) return true;
    return isCommentOrMultilineString(t);
}

fn checkLineForUAF(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
    var_name: []const u8,
    alloc_info: *CFGAllocation,
    in_defer: []const bool,
    in_errdefer: []const bool,
    bstate: *const BlockFreeState,
    issues: *std.ArrayListUnmanaged(Issue),
    t: []const u8,
    actual_line: usize,
) !void {
    const use_col = findVarUseOnLine(t, var_name) orelse return;
    const bid = findBlockForLine(cfg, actual_line) orelse return;
    const bs = cfg.blocks.items[bid].start_line;
    if (bs == 0 or bs > actual_line) return;
    if (try checkSameBlockUAF(
        allocator,
        lines,
        func_line,
        bs,
        actual_line,
        var_name,
        alloc_info,
        in_defer,
        in_errdefer,
        use_col,
        file_path,
        issues,
    )) return;
    const preds_freed = try checkPredecessorsFreed(allocator, cfg, bid, bstate);
    if (preds_freed and alloc_info.freed_line > 0) {
        // Check for reassignment between the free and this use
        if (hasReassignmentBetween(lines, func_line, alloc_info.freed_line, actual_line, var_name))
            return;
        try appendUAFIssue(
            allocator,
            issues,
            file_path,
            actual_line,
            use_col,
            var_name,
            alloc_info.freed_line,
        );
    }
}

/// Check if a variable was freed in the same block; emit UAF if so.
fn checkSameBlockUAF(
    allocator: Allocator,
    lines: []const []const u8,
    func_line: usize,
    block_start: usize,
    actual_line: usize,
    var_name: []const u8,
    alloc_info: *CFGAllocation,
    in_defer: []const bool,
    in_errdefer: []const bool,
    use_col: usize,
    file_path: []const u8,
    issues: *std.ArrayListUnmanaged(Issue),
) !bool {
    const sbf = checkSameBlockFree(
        lines,
        func_line,
        block_start,
        actual_line,
        var_name,
        alloc_info,
        in_defer,
        in_errdefer,
    );
    if (!sbf.freed or sbf.intervening_return) return false;
    try appendUAFIssue(
        allocator,
        issues,
        file_path,
        actual_line,
        use_col,
        var_name,
        alloc_info.freed_line,
    );
    return true;
}

fn detectUseAfterFree(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
    var_name: []const u8,
    alloc_info: *CFGAllocation,
    in_errdefer: []const bool,
    in_defer: []const bool,
    bstate: *const BlockFreeState,
    issues: *std.ArrayListUnmanaged(Issue),
    aliases: *const std.StringHashMapUnmanaged([]const u8),
) !void {
    // Check direct uses of the freed variable
    for (lines, 0..) |line, idx| {
        if (in_errdefer[idx]) continue;
        const t = mem.trim(u8, line, " \t\r");
        if (isUAFSkipLine(t)) continue;
        try checkLineForUAF(
            allocator,
            cfg,
            lines,
            func_line,
            file_path,
            var_name,
            alloc_info,
            in_defer,
            in_errdefer,
            bstate,
            issues,
            t,
            func_line + idx,
        );
    }

    // Check uses of aliases after the original is freed.
    // The free was on the ORIGINAL variable, not the alias. So we can't reuse
    // checkLineForUAF (which scans for free of the passed var_name).
    // Instead: if original was freed, any use of an alias after the free line is UAF.
    if (alloc_info.freed_line == 0) return; // Original not freed, no alias UAF possible
    var alias_iter = aliases.iterator();
    while (alias_iter.next()) |entry| {
        const alias_name = entry.key_ptr.*;
        const original = entry.value_ptr.*;
        if (!mem.eql(u8, original, var_name)) continue;

        for (lines, 0..) |line, idx| {
            const actual_line = func_line + idx;
            if (actual_line <= alloc_info.freed_line) continue;
            if (in_errdefer[idx]) continue;
            if (in_defer[idx]) continue;
            const t = mem.trim(u8, line, " \t\r");
            if (isUAFSkipLine(t)) continue;

            // Skip the alias definition line itself
            if (mem.startsWith(u8, t, "const ") or mem.startsWith(u8, t, "var ")) {
                if (extractVarDeclName(t)) |decl_name| {
                    if (mem.eql(u8, decl_name, alias_name)) continue;
                }
            }

            const use_col = findVarUseOnLine(t, alias_name) orelse continue;
            try appendUAFIssue(
                allocator,
                issues,
                file_path,
                actual_line,
                use_col,
                alias_name,
                alloc_info.freed_line,
            );
            break; // One UAF per alias is sufficient
        }
    }
}

fn appendDoubleFreeIssue(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    file_path: []const u8,
    t: []const u8,
    line: usize,
    var_name: []const u8,
    freed_line: usize,
    severity: Severity,
    help: []const u8,
) !void {
    var col: usize = 0;
    for (compat.getCleanupPatterns()) |pat| {
        if (mem.eql(u8, pat, ".deinit(")) continue;
        if (mem.indexOf(u8, t, pat)) |pos| {
            col = pos;
            break;
        }
    }
    const pfx = if (severity == .warning) "conditional " else "";
    const msg = try std.fmt.allocPrint(
        allocator,
        "{s}double-free: '{s}' freed on {d}",
        .{ pfx, var_name, freed_line },
    );
    try issues.append(allocator, .{
        .file = file_path,
        .line = line,
        .col = col + 1,
        .severity = severity,
        .rule = RULE_DOUBLE_FREE,
        .message = msg,
        .message_owned = true,
        .help = help,
    });
}

fn isDoubleFreeSkipLine(t: []const u8) bool {
    if (mem.startsWith(u8, t, "defer ") or mem.startsWith(u8, t, "errdefer ")) return true;
    return isCommentOrMultilineString(t);
}

fn checkLineForDoubleFree(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
    var_name: []const u8,
    alloc_info: *CFGAllocation,
    in_defer: []const bool,
    in_errdefer: []const bool,
    bstate: *const BlockFreeState,
    issues: *std.ArrayListUnmanaged(Issue),
    t: []const u8,
    actual_line: usize,
) !void {
    const bid = findBlockForLine(cfg, actual_line) orelse return;
    const bs = cfg.blocks.items[bid].start_line;
    if (bs == 0 or bs > actual_line) return;
    if (try checkSameBlockDoubleFree(
        allocator,
        lines,
        func_line,
        bs,
        actual_line,
        var_name,
        alloc_info,
        in_defer,
        in_errdefer,
        file_path,
        t,
        issues,
    )) return;
    try detectCrossBlockDoubleFree(
        allocator,
        cfg,
        lines,
        func_line,
        file_path,
        t,
        actual_line,
        bid,
        var_name,
        alloc_info,
        bstate,
        issues,
    );
}

/// Check same-block double free and emit issue if found; returns true if freed.
fn checkSameBlockDoubleFree(
    allocator: Allocator,
    lines: []const []const u8,
    func_line: usize,
    block_start: usize,
    actual_line: usize,
    var_name: []const u8,
    alloc_info: *CFGAllocation,
    in_defer: []const bool,
    in_errdefer: []const bool,
    file_path: []const u8,
    t: []const u8,
    issues: *std.ArrayListUnmanaged(Issue),
) !bool {
    const sbf = checkSameBlockFree(
        lines,
        func_line,
        block_start,
        actual_line,
        var_name,
        alloc_info,
        in_defer,
        in_errdefer,
    );
    if (!sbf.freed) return false;
    const freed = alloc_info.freed_line;
    if (!hasExclusiveBranchBetween(lines, freed, actual_line, func_line)) {
        try appendDoubleFreeIssue(
            allocator,
            issues,
            file_path,
            t,
            actual_line,
            var_name,
            freed,
            .err,
            "remove duplicate free",
        );
    }
    return true;
}

fn detectDoubleFree(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
    var_name: []const u8,
    alloc_info: *CFGAllocation,
    in_defer: []const bool,
    in_errdefer: []const bool,
    bstate: *const BlockFreeState,
    issues: *std.ArrayListUnmanaged(Issue),
) !void {
    for (lines, 0..) |line, idx| {
        const t = mem.trim(u8, line, " \t\r");
        if (isDoubleFreeSkipLine(t)) continue;
        if (!hasRealFreePattern(t)) continue;
        if (!isDirectFreeOfVar(t, var_name)) continue;
        try checkLineForDoubleFree(
            allocator,
            cfg,
            lines,
            func_line,
            file_path,
            var_name,
            alloc_info,
            in_defer,
            in_errdefer,
            bstate,
            issues,
            t,
            func_line + idx,
        );
    }
}

/// Result from analyzing predecessor free state
const PredFreeAnalysis = struct {
    def_freed: bool,
    any_freed: bool,
    any_normal: bool,
    freed_pred_line: usize,
};

/// Analyze predecessor blocks to determine free state
fn analyzePredFreeState(
    preds: []const usize,
    bstate: *const BlockFreeState,
) PredFreeAnalysis {
    var result = PredFreeAnalysis{
        .def_freed = true,
        .any_freed = false,
        .any_normal = false,
        .freed_pred_line = 0,
    };
    for (preds) |pred| {
        if (bstate.block_returns_after_free[pred]) continue;
        result.any_normal = true;
        if (bstate.freed_in_block[pred]) {
            result.any_freed = true;
            const pl = bstate.freed_line_in_block[pred];
            if (pl > result.freed_pred_line) result.freed_pred_line = pl;
        } else {
            result.def_freed = false;
        }
    }
    return result;
}

fn detectCrossBlockDoubleFree(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
    t: []const u8,
    actual_line: usize,
    bid: usize,
    var_name: []const u8,
    alloc_info: *CFGAllocation,
    bstate: *const BlockFreeState,
    issues: *std.ArrayListUnmanaged(Issue),
) !void {
    var preds = try getBlockPredecessors(cfg, bid, allocator);
    defer preds.deinit(allocator);
    if (preds.items.len == 0) return;

    const pa = analyzePredFreeState(preds.items, bstate);
    if (!pa.any_freed or !pa.any_normal) return;

    const ref = if (pa.freed_pred_line > 0)
        pa.freed_pred_line
    else
        alloc_info.freed_line;
    if (hasExclusiveBranchBetween(lines, ref, actual_line, func_line))
        return;

    try emitCrossBlockDoubleFree(
        allocator,
        issues,
        file_path,
        t,
        actual_line,
        var_name,
        ref,
        pa,
    );
}

fn emitCrossBlockDoubleFree(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    file_path: []const u8,
    t: []const u8,
    actual_line: usize,
    var_name: []const u8,
    ref: usize,
    pa: PredFreeAnalysis,
) !void {
    if (pa.def_freed) {
        try appendDoubleFreeIssue(
            allocator,
            issues,
            file_path,
            t,
            actual_line,
            var_name,
            ref,
            .err,
            "remove duplicate free",
        );
    } else if (pa.any_freed) {
        try appendDoubleFreeIssue(
            allocator,
            issues,
            file_path,
            t,
            actual_line,
            var_name,
            ref,
            .warning,
            "move free outside conditional",
        );
    }
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
/// Check if function has a parameter with a no-free allocator TYPE annotation.
/// Checks parameter TYPE (e.g., `: *ArenaAllocator`, `: std.mem.Allocator` backed by arena),
/// not parameter NAME (which is developer-chosen and unreliable).
fn hasNoFreeAllocatorParameter(lines: []const []const u8) bool {
    // Check first 10 lines (function signature may span multiple lines)
    const no_free_ptrs = compat.getNoFreeTypePtrs();
    for (lines[0..@min(10, lines.len)]) |line| {
        const t = mem.trim(u8, line, " \t\r");
        // Parameter typed as no-free allocator pointer (compat layer)
        for (no_free_ptrs) |ptr_pat| {
            if (mem.indexOf(u8, t, ptr_pat) != null) return true;
        }
        // Stop scanning at function body start
        if (mem.indexOf(u8, t, ") ") != null and mem.indexOf(u8, t, "{") != null) break;
    }
    return false;
}

/// Collect allocations from function lines for CFG analysis
fn collectCFGAllocations(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    file_no_free_fields: ?*const std.StringHashMapUnmanaged(void),
) !std.ArrayListUnmanaged(CFGAlloc) {
    var allocs = std.ArrayListUnmanaged(CFGAlloc).empty;

    // Pre-scan: build type-tracked allocator sets
    var local_no_free_fields = try collectNoFreeFieldNames(allocator, lines);
    defer local_no_free_fields.deinit(allocator);
    var no_free_names = try collectNoFreeAllocatorNames(allocator, lines, file_no_free_fields);
    defer no_free_names.deinit(allocator);
    var all_alloc_names = try collectAllAllocatorNames(allocator, lines);
    defer all_alloc_names.deinit(allocator);

    for (lines, 0..) |line, idx| {
        const actual_line = func_line + idx;
        const t = mem.trim(u8, line, " \t\r");

        // Detect allocations using type-based detection for .create()
        const alloc_info = findAllocCall(t, &all_alloc_names) orelse continue;

        // Skip allocations from type-tracked no-free allocators (stdlib types only)
        const aname = extractAllocatorName(t) orelse "";
        if (aname.len > 0 and no_free_names.contains(aname)) continue;
        if (isNoFreeCallChainFull(t, &no_free_names, &local_no_free_fields)) continue;
        if (isNoFreeFieldChain(t, &local_no_free_fields)) continue;
        // Check file-level no-free fields (struct definitions outside this function)
        if (file_no_free_fields) |fields| {
            if (isNoFreeCallChainFull(t, &no_free_names, fields)) continue;
            if (isNoFreeFieldChain(t, fields)) continue;
        }
        // For standalone/method-style calls where allocator is an argument (not receiver),
        // check the first-arg allocator for no-free suppression
        if (extractStandaloneAllocator(t)) |standalone_alloc| {
            if (no_free_names.contains(standalone_alloc)) continue;
            if (isArenaName(standalone_alloc)) continue;
        } else if (extractMultilineFirstArg(t, lines, idx)) |ml_alloc| {
            // Multiline: allocPrint(\n    arena, ...) — first arg on next line
            if (no_free_names.contains(ml_alloc)) continue;
            if (isArenaName(ml_alloc)) continue;
        }
        // Dotted first-arg arena heuristic: allocPrint(cg.module.arena, ...)
        if (isFirstArgArena(t)) continue;

        const name = extractVarDeclName(t) orelse continue;
        const block = findBlockForLine(cfg, actual_line) orelse continue;

        try allocs.append(allocator, .{
            .name = name,
            .line = actual_line,
            .col = alloc_info.col + 1,
            .block = block,
            .is_create = alloc_info.is_create,
        });
    }

    return allocs;
}

/// Check for immediate defer after multi-line allocations
/// Returns true if allocation should be removed (has immediate defer)
/// Find where a multi-line allocation statement ends (semicolon at brace depth 0)
fn findAllocStatementEnd(lines: []const []const u8, start: usize) usize {
    var brace_depth: i32 = 0;
    for (start..lines.len) |idx| {
        const scan_line = mem.trim(u8, lines[idx], " \t\r");
        brace_depth += countBraceBalance(scan_line);
        if (mem.indexOf(u8, scan_line, ";") != null and brace_depth <= 0)
            return idx;
    }
    return start;
}

fn countBraceBalance(line: []const u8) i32 {
    var balance: i32 = 0;
    for (line) |c| {
        if (c == '{' or c == '(') balance += 1;
        if (c == '}' or c == ')') balance -= 1;
    }
    return balance;
}

/// Check nearby lines after allocation for a matching defer
fn hasNearbyDefer(
    lines: []const []const u8,
    alloc_end_idx: usize,
    alloc_indent: usize,
    name: []const u8,
) bool {
    const search_end = @min(alloc_end_idx + 6, lines.len);
    for (alloc_end_idx + 1..search_end) |check_idx| {
        const raw_line = lines[check_idx];
        const scan_line = mem.trim(u8, raw_line, " \t\r");
        if (scan_line.len == 0) continue;
        const check_indent = countIndent(raw_line);
        if (check_indent < alloc_indent) break;
        if (!isDeferOrErrdefer(scan_line)) continue;
        if (check_indent != alloc_indent) continue;
        if (hasRealCleanupPattern(scan_line) and
            mem.indexOf(u8, scan_line, name) != null) return true;
    }
    return false;
}

/// Check if a trimmed line starts with defer or errdefer
fn isDeferOrErrdefer(t: []const u8) bool {
    return mem.startsWith(u8, t, "defer ") or mem.startsWith(u8, t, "errdefer ") or
        mem.startsWith(u8, t, "errdefer{") or mem.startsWith(u8, t, "defer{");
}

/// Scan for a defer/errdefer at an OUTER scope that frees this variable
fn hasOuterScopeDefer(lines: []const []const u8, alloc_indent: usize, name: []const u8) bool {
    for (0..lines.len) |check_idx| {
        const raw_line = lines[check_idx];
        const scan_line = mem.trim(u8, raw_line, " \t\r");
        if (!isDeferOrErrdefer(scan_line)) continue;
        if (countIndent(raw_line) >= alloc_indent) continue;
        if (hasRealCleanupPattern(scan_line) and
            mem.indexOf(u8, scan_line, name) != null) return true;
    }
    return false;
}

fn hasImmediateDefer(
    alloc: *CFGAlloc,
    lines: []const []const u8,
    func_line: usize,
) bool {
    const alloc_idx = alloc.line - func_line;
    if (alloc_idx >= lines.len) return false;
    const alloc_indent = countIndent(lines[alloc_idx]);
    const alloc_end_idx = findAllocStatementEnd(lines, alloc_idx);
    if (hasNearbyDefer(lines, alloc_end_idx, alloc_indent, alloc.name)) return true;
    return hasOuterScopeDefer(lines, alloc_indent, alloc.name);
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
fn tryAddOwner(
    allocator: Allocator,
    owner_vars: *std.ArrayListUnmanaged(OwnerVar),
    name: []const u8,
) !void {
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

fn extractConstOwnerName(t: []const u8) ?[]const u8 {
    if (!mem.startsWith(u8, t, "const ") or
        mem.indexOf(u8, t, "{") == null) return null;
    var end: usize = 6;
    while (end < t.len and isIdent(t[end])) end += 1;
    return if (end > 6) t[6..end] else null;
}

fn extractDerefOwnerName(t: []const u8) ?[]const u8 {
    if (mem.indexOf(u8, t, ".* = ") == null or
        mem.indexOf(u8, t, "{") == null) return null;
    var end: usize = 0;
    while (end < t.len and isIdent(t[end])) end += 1;
    return if (end > 0) t[0..end] else null;
}

fn trackOwnerVariables(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    alloc_name: []const u8,
) !std.ArrayListUnmanaged(OwnerVar) {
    var owner_vars = std.ArrayListUnmanaged(OwnerVar).empty;
    try owner_vars.append(allocator, .{ .name = alloc_name });

    for (cfg.blocks.items) |block| {
        if (block.start_line == 0 or block.start_line > block.end_line) continue;
        for (block.start_line..block.end_line + 1) |line_num| {
            if (line_num < func_line) continue;
            const idx = line_num - func_line;
            if (idx >= lines.len) continue;
            const t = mem.trim(u8, lines[idx], " \t\r");
            if (!hasOwnerAppearance(owner_vars.items, t)) continue;
            if (extractConstOwnerName(t)) |name|
                try tryAddOwner(allocator, &owner_vars, name);
            if (extractDerefOwnerName(t)) |name|
                try tryAddOwner(allocator, &owner_vars, name);
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
        if (!containsIdentifier(t, ov.name)) continue;

        // Direct return of owner variable
        if (mem.startsWith(u8, t, "return ")) return true;

        // Labeled break transfers ownership out of a block
        if (mem.startsWith(u8, t, "break :")) return true;

        // Container ownership transfer: .append(data), .put(key, data)
        // Owner var must appear as an ARGUMENT (after the method pattern),
        // not as the LHS of a declaration receiving the return value.
        if (!mem.startsWith(u8, t, "const ") and !mem.startsWith(u8, t, "var ")) {
            for (compat.getContainerOwnershipMethods()) |pattern| {
                if (mem.indexOf(u8, t, pattern)) |pat_pos| {
                    // Check that owner var appears after the method call opening paren
                    const after_method = pat_pos + pattern.len;
                    if (after_method < t.len) {
                        if (containsIdentifier(t[after_method..], ov.name)) return true;
                    }
                }
            }
        }

        // Realloc consumes the old pointer: .realloc(old, new_size)
        // Owner var must be an argument to realloc, not the result
        if (mem.indexOf(u8, t, ".realloc(")) |realloc_pos| {
            const after_paren = realloc_pos + ".realloc(".len;
            if (after_paren < t.len and
                containsIdentifier(t[after_paren..], ov.name))
                return true;
        }

        // Pointer deref assignment: out.* = data (transfers to caller)
        if (mem.indexOf(u8, t, ".* = ") != null) {
            if (mem.indexOf(u8, t, " = ")) |eq_pos| {
                const lhs = mem.trim(u8, t[0..eq_pos], " \t");
                // Only if the owner var is on the RHS (being transferred)
                if (!mem.startsWith(u8, lhs, "const ") and
                    !mem.startsWith(u8, lhs, "var ") and
                    mem.endsWith(u8, lhs, ".*") and
                    !containsIdentifier(lhs, ov.name))
                    return true;
            }
        }

        // Stored in any struct field (identifier.field = value)
        if (mem.indexOf(u8, t, " = ")) |eq_pos| {
            const lhs = mem.trim(u8, t[0..eq_pos], " \t");
            // Skip const/var declarations (those are local)
            if (!mem.startsWith(u8, t, "const ") and !mem.startsWith(u8, t, "var ")) {
                // Pointer dereference init: name.* = .{...} writes TO allocated memory
                if (mem.endsWith(u8, lhs, ".*") and containsIdentifier(lhs, ov.name)) continue;
                // LHS with a dot = struct field storage (e.g., self.x, ctx.y, result.z, node.data)
                if (mem.indexOf(u8, lhs, ".") != null) return true;
                // Skip discard patterns: _ = value
                if (mem.eql(u8, lhs, "_")) continue;
                // Simple identifier = module-level variable assignment
                if (lhs.len > 0) return true;
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
    file_no_free_fields: ?*const std.StringHashMapUnmanaged(void),
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .empty;

    // Skip functions that take a no-free allocator by TYPE (e.g., *ArenaAllocator parameter)
    if (hasNoFreeAllocatorParameter(lines)) return issues;

    // Phase 1: Collect allocations
    var allocs = try collectCFGAllocations(allocator, cfg, lines, func_line, file_no_free_fields);
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
    has_direct_free: []bool,

    fn deinit(self: *BlockCoverageState, allocator: Allocator) void {
        allocator.free(self.has_defer);
        allocator.free(self.ownership_transferred);
        allocator.free(self.free_and_return);
        allocator.free(self.has_direct_free);
    }

    fn isBlockCovered(self: BlockCoverageState, bid: usize) bool {
        return self.has_defer[bid] or self.ownership_transferred[bid] or
            self.free_and_return[bid] or self.has_direct_free[bid];
    }

    fn anyDeferExists(self: BlockCoverageState) bool {
        for (self.has_defer) |has| {
            if (has) return true;
        }
        return false;
    }

    fn anyOwnershipTransferred(self: BlockCoverageState) bool {
        for (self.ownership_transferred) |transferred| {
            if (transferred) return true;
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
        .has_direct_free = try allocator.alloc(bool, num_blocks),
    };
    @memset(state.has_defer, false);
    @memset(state.ownership_transferred, false);
    @memset(state.free_and_return, false);
    @memset(state.has_direct_free, false);

    for (cfg.blocks.items, 0..) |block, bid| {
        if (block.start_line == 0 or block.start_line > block.end_line) continue;
        scanSingleBlock(&state, block, bid, lines, func_line, alloc_name, owner_vars);
    }
    return state;
}

/// Scan a single CFG block for defer/free/return/ownership patterns
fn scanSingleBlock(
    state: *BlockCoverageState,
    block: anytype,
    bid: usize,
    lines: []const []const u8,
    func_line: usize,
    alloc_name: []const u8,
    owner_vars: []const OwnerVar,
) void {
    var freed = false;
    var return_after = false;
    var defer_depth: usize = 0;

    for (block.start_line..block.end_line + 1) |line_num| {
        if (line_num < func_line) continue;
        const idx = line_num - func_line;
        if (idx >= lines.len) continue;
        const t = mem.trim(u8, lines[idx], " \t\r");
        const is_defer = isDeferOrErrdefer(t);
        const has_free = hasRealFreePattern(t) and containsIdentifier(t, alloc_name);

        // Track multi-line defer/errdefer blocks: defer { ... } / errdefer { ... }
        if (is_defer and (mem.indexOf(u8, t, "{") != null)) {
            defer_depth = countBraceDepth(t, 0);
        } else if (defer_depth > 0) {
            defer_depth = countBraceDepth(t, defer_depth);
        }
        const in_defer_block = is_defer or defer_depth > 0;

        if (in_defer_block and has_free) state.has_defer[bid] = true;
        if (!in_defer_block and !mem.startsWith(u8, t, "errdefer ") and has_free) {
            freed = true;
            state.has_direct_free[bid] = true;
        }
        if (freed and mem.startsWith(u8, t, "return")) return_after = true;
        if (checkOwnershipInLine(t, owner_vars)) state.ownership_transferred[bid] = true;
    }
    if (freed and return_after) state.free_and_return[bid] = true;
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
        if (state.isBlockCovered(bid)) covered[bid] = true;
    }

    var changed = true;
    var iters: usize = 0;
    const max_iters = num_blocks * 2 + 1;
    while (changed and iters < max_iters) : (iters += 1) {
        changed = false;
        for (0..num_blocks) |bid| {
            if (covered[bid]) continue;
            if (!tryPropagateCoverage(cfg, covered, bid)) continue;
            covered[bid] = true;
            changed = true;
        }
    }
    return covered;
}

/// Check if a block should be marked covered based on successor coverage
fn tryPropagateCoverage(cfg: *ControlFlowGraph, covered: []bool, bid: usize) bool {
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
        if (isExitBlock(cfg, bid)) return false;
    }
    return has_succ and all_succs_covered;
}

/// Check if a block ID is in the exit blocks list
fn isExitBlock(cfg: *ControlFlowGraph, bid: usize) bool {
    for (cfg.exit_blocks.items) |exit_bid| {
        if (exit_bid == bid) return true;
    }
    return false;
}

/// Check defer coverage for a single allocation using CFG dataflow
/// Build a partial-coverage issue for an alloc that has defer on some but not all paths
fn buildPartialCoverageIssue(file_path: []const u8, alloc: CFGAlloc) Issue {
    return Issue{
        .file = file_path,
        .line = alloc.line,
        .col = alloc.col,
        .severity = .warning,
        .rule = if (alloc.is_create) RULE_CREATE_NO_DEFER else RULE_ALLOC_NO_DEFER,
        .message = if (alloc.is_create)
            "defer destroy() not on all code paths"
        else
            "defer free() not on all code paths",
        .help = "move defer to outer scope or add defer on all branches",
    };
}

fn checkDeferCoverageForAlloc(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
    alloc: CFGAlloc,
    num_blocks: usize,
) !?Issue {
    var owner_vars = try trackOwnerVariables(allocator, cfg, lines, func_line, alloc.name);
    defer owner_vars.deinit(allocator);

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

    const covered = try propagateCoverageBackward(allocator, cfg, state, num_blocks);
    defer allocator.free(covered);

    const alloc_block_covered = covered[alloc.block];

    // If ownership is transferred anywhere (e.g., allocation returned to caller),
    // the caller is responsible for cleanup - not a missing defer.
    if (alloc_block_covered or state.anyOwnershipTransferred())
        return null;

    // Fallback: linear scan for defer free anywhere in the function.
    // The CFG block analysis can miss multi-line defers that span block boundaries.
    if (hasDeferFreeInFunction(lines, alloc.name))
        return null;

    return buildPartialCoverageIssue(file_path, alloc);
}

/// Find the indent level of an allocation line by name
fn findAllocIndent(lines: []const []const u8, alloc_name: []const u8) usize {
    for (lines) |line| {
        const t = mem.trim(u8, line, " \t\r");
        // Check for .alloc( or .create( (not in string, not Type factory)
        if (findAllocCall(t, null) != null and containsIdentifier(t, alloc_name))
            return countIndent(line);
    }
    return 0;
}

/// Process a single line during defer-free scan, returns true if free found in valid defer
fn checkDeferFreeLine(
    line: []const u8,
    t: []const u8,
    alloc_name: []const u8,
    alloc_indent: usize,
    defer_depth: *usize,
    skip_depth: *usize,
) bool {
    // Skip mode: inside a defer block at deeper scope than alloc
    if (skip_depth.* > 0) {
        skip_depth.* = countBraceDepth(t, skip_depth.*);
        return false;
    }

    const is_defer_start = isDeferOrErrdefer(t);
    if (is_defer_start)
        return handleDeferStart(line, t, alloc_name, alloc_indent, defer_depth, skip_depth);

    if (defer_depth.* > 0) {
        if (hasRealFreePattern(t) and containsIdentifier(t, alloc_name))
            return true;
        defer_depth.* = countBraceDepth(t, defer_depth.*);
    }
    return false;
}

/// Handle a defer statement start during defer-free scan
fn handleDeferStart(
    line: []const u8,
    t: []const u8,
    alloc_name: []const u8,
    alloc_indent: usize,
    defer_depth: *usize,
    skip_depth: *usize,
) bool {
    // Only consider defers at same or outer scope as the allocation
    if (countIndent(line) > alloc_indent) {
        if (mem.indexOf(u8, t, "{") != null)
            skip_depth.* = countBraceDepth(t, 0);
        return false;
    }
    // Single-line defer with free
    if (hasRealFreePattern(t) and containsIdentifier(t, alloc_name))
        return true;
    // Multi-line defer block start at same/outer scope
    if (mem.indexOf(u8, t, "{") != null)
        defer_depth.* = countBraceDepth(t, 0);
    return false;
}

/// Linear scan for a defer block containing .free(name) or .destroy(name) at the
/// same or outer scope as the allocation. Handles multi-line defer { ... } blocks.
fn hasDeferFreeInFunction(
    lines: []const []const u8,
    alloc_name: []const u8,
) bool {
    const alloc_indent = findAllocIndent(lines, alloc_name);
    var defer_depth: usize = 0;
    var skip_depth: usize = 0;

    for (lines) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;
        if (checkDeferFreeLine(line, t, alloc_name, alloc_indent, &defer_depth, &skip_depth))
            return true;
    }
    return false;
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

/// Check if function uses any no-free allocator type (type-based detection).
/// Scans for stdlib type initialization patterns — not variable names.
fn hasNoFreeAllocatorType(lines: []const []const u8) bool {
    // Check for no-free allocator TYPE initialization patterns (compat layer)
    const no_free_pats = compat.getNoFreeInitPatterns();
    for (lines) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;
        for (no_free_pats) |pat| {
            if (mem.indexOf(u8, t, pat) != null) return true;
        }
    }
    // Also check for no-free allocator TYPE in parameter annotations
    return hasNoFreeAllocatorParameter(lines);
}

/// Check if line contains a try allocation (not in no-free allocator)
fn isTryAllocation(t: []const u8) bool {
    const has_try = mem.indexOf(u8, t, "try ") != null;
    if (!has_try) return false;
    if (!mem.startsWith(u8, t, "const ") and
        !mem.startsWith(u8, t, "var ")) return false;

    // Check all allocation method patterns from compat layer
    return findAllocCall(t, null) != null;
}

/// Check ownership transfer for errdefer analysis
fn checkErrdeferOwnershipTransfer(
    alloc: *TryAlloc,
    lines: []const []const u8,
    func_line: usize,
) void {
    const alloc_idx = alloc.line - func_line;
    if (alloc_idx >= lines.len) return;

    // Start from line AFTER the allocation — the allocation line itself
    // can't be an ownership transfer of its own result (e.g., toOwnedSlice
    // on the alloc line would falsely match container_ownership_methods)
    const start = alloc_idx + 1;
    if (start >= lines.len) return;
    for (lines[start..]) |line| {
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

/// State for multi-line errdefer/defer block collection
const BlockCollectState = struct {
    depth: usize = 0,
    start: usize = 0,
    content: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *BlockCollectState, a: Allocator) void {
        self.content.deinit(a);
    }
};

/// Continue collecting a multi-line errdefer/defer block.
/// Returns true if still inside the block.
fn continueBlockCollection(
    t: []const u8,
    bs: *BlockCollectState,
    errdefers: *std.ArrayListUnmanaged(ErrdeferInfo),
    allocator: Allocator,
) !bool {
    if (bs.depth == 0) return false;
    try bs.content.appendSlice(allocator, t);
    try bs.content.append(allocator, ' ');
    for (t) |c| {
        if (c == '{') bs.depth += 1;
        if (c == '}' and bs.depth > 0) bs.depth -= 1;
        if (bs.depth == 0) {
            try tryAppendCleanupInfo(bs.content.items, bs.start, errdefers, allocator);
            bs.content.clearRetainingCapacity();
        }
    }
    return true;
}

/// Collect a try allocation from a line, skipping arena/no-free.
fn collectTryAllocFromLine(
    t: []const u8,
    actual_line: usize,
    try_allocs: *std.ArrayListUnmanaged(TryAlloc),
    try_lines: *std.ArrayListUnmanaged(usize),
    allocator: Allocator,
    no_free_names: *const std.StringHashMapUnmanaged(void),
    no_free_fields: *const std.StringHashMapUnmanaged(void),
) !void {
    // Skip allocations from type-tracked no-free allocators (stdlib types only)
    const aname_e = extractAllocatorName(t) orelse "";
    if (aname_e.len > 0 and no_free_names.contains(aname_e)) {
        try try_lines.append(allocator, actual_line);
        return;
    }
    if (isNoFreeCallChainFull(t, no_free_names, no_free_fields)) {
        try try_lines.append(allocator, actual_line);
        return;
    }
    if (isNoFreeFieldChain(t, no_free_fields)) {
        try try_lines.append(allocator, actual_line);
        return;
    }
    if (extractVarDeclName(t)) |name| {
        const alloc_info = findAllocCall(t, null) orelse return;
        try try_allocs.append(allocator, .{
            .name = name,
            .line = actual_line,
            .col = alloc_info.col + 1,
            .is_create = alloc_info.is_create,
        });
    }
}

/// Start collecting an errdefer/defer block.
fn tryAppendCleanupInfo(
    items: []const u8,
    line_num: usize,
    errdefers: *std.ArrayListUnmanaged(ErrdeferInfo),
    allocator: Allocator,
) !void {
    if (!hasRealCleanupPattern(items)) return;
    try errdefers.append(allocator, .{
        .line = line_num,
        .content = try allocator.dupe(u8, items),
    });
}

fn collectDeferFromLine(
    t: []const u8,
    actual_line: usize,
    bs: *BlockCollectState,
    errdefers: *std.ArrayListUnmanaged(ErrdeferInfo),
    allocator: Allocator,
) !void {
    const is_errdefer = mem.startsWith(u8, t, "errdefer ");
    const is_defer = mem.startsWith(u8, t, "defer ");
    if (!is_errdefer and !is_defer) return;

    const prefix_len: usize = if (is_errdefer) 9 else 6;
    const content = if (prefix_len < t.len) t[prefix_len..] else "";

    if (!mem.startsWith(u8, content, "{")) {
        try tryAppendCleanupInfo(t, actual_line, errdefers, allocator);
        return;
    }
    bs.start = actual_line;
    bs.depth = 1;
    bs.content.clearRetainingCapacity();
    try bs.content.appendSlice(allocator, content);
    try bs.content.append(allocator, ' ');
    for (content[1..]) |c| {
        if (c == '{') bs.depth += 1;
        if (c == '}' and bs.depth > 0) bs.depth -= 1;
    }
    if (bs.depth == 0) {
        try tryAppendCleanupInfo(bs.content.items, actual_line, errdefers, allocator);
        bs.content.clearRetainingCapacity();
    }
}

/// Check for errdefer gaps and report issues.
fn findMatchingErrdefer(
    errdefers_list: []const ErrdeferInfo,
    name: []const u8,
) ?usize {
    for (errdefers_list) |ed| {
        if (containsIdentifier(ed.content, name)) return ed.line;
    }
    return null;
}

fn hasErrdeferGap(
    alloc: *const TryAlloc,
    errdefer_line: usize,
    try_lines: []const usize,
) bool {
    for (try_lines) |try_line| {
        if (try_line <= alloc.line) continue;
        if (alloc.has_errdefer and errdefer_line > alloc.line and
            errdefer_line < try_line) continue;
        if (!alloc.has_errdefer or errdefer_line >= try_line)
            return true;
    }
    return false;
}

fn checkErrdeferGaps(
    allocator: Allocator,
    try_allocs: []TryAlloc,
    errdefers_list: []const ErrdeferInfo,
    try_lines: []const usize,
    file_path: []const u8,
    issues: *std.ArrayListUnmanaged(Issue),
) !void {
    for (try_allocs) |*alloc| {
        if (alloc.has_errdefer) continue;
        var errdefer_line: usize = 0;
        if (findMatchingErrdefer(errdefers_list, alloc.name)) |el| {
            errdefer_line = el;
            alloc.has_errdefer = true;
        }
        if (!hasErrdeferGap(alloc, errdefer_line, try_lines)) continue;
        try issues.append(allocator, .{
            .file = file_path,
            .line = alloc.line,
            .col = alloc.col,
            .severity = .warning,
            .rule = RULE_ALLOC_NO_ERRDEFER,
            .message = "allocation without errdefer " ++
                "before next try",
            .help = "add errdefer immediately " ++
                "after allocation",
        });
    }
}

/// Collected errdefer analysis state from scanning function lines
const ErrdeferScanState = struct {
    try_allocs: std.ArrayListUnmanaged(TryAlloc),
    errdefers: std.ArrayListUnmanaged(ErrdeferInfo),
    try_lines_list: std.ArrayListUnmanaged(usize),
    bs: BlockCollectState,

    fn deinit(self: *ErrdeferScanState, allocator: Allocator) void {
        self.try_allocs.deinit(allocator);
        for (self.errdefers.items) |e| allocator.free(e.content);
        self.errdefers.deinit(allocator);
        self.try_lines_list.deinit(allocator);
        self.bs.deinit(allocator);
    }
};

/// Scan lines for try-allocations and errdefer statements
fn scanErrdeferLines(
    allocator: Allocator,
    lines: []const []const u8,
    func_line: usize,
    file_no_free_fields: ?*const std.StringHashMapUnmanaged(void),
) !ErrdeferScanState {
    var state = ErrdeferScanState{
        .try_allocs = .empty,
        .errdefers = .empty,
        .try_lines_list = .empty,
        .bs = .{},
    };

    // Pre-scan: build set of no-free allocator names by tracking type-based
    // initialization and .allocator() aliases
    var local_no_free_fields = try collectNoFreeFieldNames(allocator, lines);
    defer local_no_free_fields.deinit(allocator);
    var no_free_names = try collectNoFreeAllocatorNames(allocator, lines, file_no_free_fields);
    defer no_free_names.deinit(allocator);
    // Merge file-level fields: use file-level if available, else local only
    const effective_fields = file_no_free_fields orelse &local_no_free_fields;

    for (lines, 0..) |line, idx| {
        const actual_line = func_line + idx;
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;
        if (try continueBlockCollection(
            t,
            &state.bs,
            &state.errdefers,
            allocator,
        )) continue;
        const has_try = mem.indexOf(u8, t, "try ") != null;
        if (has_try and isTryAllocation(t)) {
            // Check standalone first-arg allocator (single-line and multiline)
            const standalone_skip = blk: {
                if (extractStandaloneAllocator(t)) |sa| {
                    if (no_free_names.contains(sa)) break :blk true;
                    if (isArenaName(sa)) break :blk true;
                } else if (extractMultilineFirstArg(t, lines, idx)) |ml| {
                    if (no_free_names.contains(ml)) break :blk true;
                    if (isArenaName(ml)) break :blk true;
                }
                // Dotted first-arg arena heuristic
                if (isFirstArgArena(t)) break :blk true;
                break :blk false;
            };
            if (!standalone_skip) {
                try collectTryAllocFromLine(
                    t,
                    actual_line,
                    &state.try_allocs,
                    &state.try_lines_list,
                    allocator,
                    &no_free_names,
                    effective_fields,
                );
            } else {
                try state.try_lines_list.append(allocator, actual_line);
            }
        }
        try collectDeferFromLine(
            t,
            actual_line,
            &state.bs,
            &state.errdefers,
            allocator,
        );
        if (has_try) try state.try_lines_list.append(allocator, actual_line);
    }
    return state;
}

/// CFG-based errdefer coverage analysis (ZA103)
fn analyzeCFGErrdeferCoverage(
    allocator: Allocator,
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
    fn_returns_error: bool,
    file_no_free_fields: ?*const std.StringHashMapUnmanaged(void),
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    if (!fn_returns_error) return issues;
    if (hasNoFreeAllocatorType(lines)) return issues;

    var state = try scanErrdeferLines(allocator, lines, func_line, file_no_free_fields);
    defer state.deinit(allocator);

    if (state.try_allocs.items.len == 0) return issues;
    for (state.try_allocs.items) |*alloc| {
        checkErrdeferOwnershipTransfer(alloc, lines, func_line);
    }
    try checkErrdeferGaps(
        allocator,
        state.try_allocs.items,
        state.errdefers.items,
        state.try_lines_list.items,
        file_path,
        &issues,
    );
    return issues;
}

// ============================================================================
// Import Graph
// ============================================================================

const ImportGraph = struct {
    allocator: Allocator,
    files: std.StringHashMap(FileAnalysis),
    reachable: std.StringHashMap(void),
    /// Reverse index: resolved (realpath) → `files` key.
    /// Enables O(1) lookup in `findImportsForPath` — without it, every
    /// recursive reachability step called realpath() on every file in
    /// the graph, producing O(N²) openat storms (millions of syscalls
    /// on ~1,400-file codebases). Neither key nor value is owned here;
    /// both alias the `files` map's entries.
    resolved_to_key: std.StringHashMapUnmanaged([]const u8),
    scan_root: ?[]const u8,

    fn init(allocator: Allocator) ImportGraph {
        return .{
            .allocator = allocator,
            .files = std.StringHashMap(FileAnalysis).init(allocator),
            .reachable = std.StringHashMap(void).init(allocator),
            .resolved_to_key = .empty,
            .scan_root = null,
        };
    }

    /// Returns true if resolved path is within the scan root (or no root set).
    fn isWithinScanRoot(self: *const ImportGraph, resolved: []const u8) bool {
        const root = self.scan_root orelse return true;
        return mem.startsWith(u8, resolved, root);
    }

    fn deinit(self: *ImportGraph) void {
        // resolved_to_key aliases entries owned by self.files — just
        // drop the table, don't free the slices.
        self.resolved_to_key.deinit(self.allocator);

        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            var analysis = entry.value_ptr.*;
            analysis.deinit(self.allocator);
        }
        self.files.deinit();

        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
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
        defer dir.close(global_io.?);
        try self.scanRecursive(dir, dir_path, 0);
    }

    fn scanSingleFile(self: *ImportGraph, file_path: []const u8) !void {
        if (mem.endsWith(u8, file_path, ".zig")) {
            const path_copy = try self.allocator.dupe(u8, file_path);
            try self.analyzeFile(path_copy);
            self.allocator.free(path_copy);
        }
    }

    fn scanRecursive(self: *ImportGraph, dir: std.Io.Dir, base: []const u8, depth: u16) !void {
        if (depth > 32) return;
        var iter = dir.iterate();
        while (try iter.next(global_io.?)) |entry| {
            const path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ base, entry.name },
            );

            switch (entry.kind) {
                .file => {
                    defer self.allocator.free(path);
                    if (mem.endsWith(u8, entry.name, ".zig"))
                        try self.analyzeFile(path);
                },
                .directory => {
                    defer self.allocator.free(path);
                    if (isScanSkipDir(entry.name)) continue;
                    var subdir = dir.openDir(
                        global_io.?,
                        entry.name,
                        .{ .iterate = true },
                    ) catch continue;
                    defer subdir.close(global_io.?);
                    try self.scanRecursive(subdir, path, depth + 1);
                },
                else => self.allocator.free(path),
            }
        }
    }

    fn analyzeFile(self: *ImportGraph, file_path: []const u8) !void {
        const max_size = 10 * 1024 * 1024;
        const content = fs.cwd().readFileAlloc(self.allocator, file_path, max_size) catch {
            return;
        };
        const has_tests = mem.indexOf(u8, content, "test \"") != null;
        const pub_fn_count = types.countOccurrences(content, "pub fn ");
        const path_copy = try self.allocator.dupe(u8, file_path);
        const resolved_copy = blk: {
            var buf: [fs.max_path_bytes]u8 = undefined;
            const r = fs.cwd().realpath(file_path, &buf) catch {
                break :blk path_copy;
            };
            break :blk self.allocator.dupe(u8, r) catch path_copy;
        };
        var analysis = FileAnalysis{
            .path = path_copy,
            .resolved_path = resolved_copy,
            .imports = .empty,
            .content = content,
            .has_tests = has_tests,
            .pub_function_count = pub_fn_count,
            .line_count = types.countLines(content),
        };
        try self.extractImports(content, file_path, &analysis);
        try self.files.put(analysis.path, analysis);
        if (resolved_copy.ptr != path_copy.ptr) {
            try self.resolved_to_key.put(
                self.allocator,
                resolved_copy,
                path_copy,
            );
        }
    }

    /// Extract variable name after "const "
    fn extractVarName(content: []const u8, start: usize) ?[]const u8 {
        var end = start;
        while (end < content.len) : (end += 1) {
            const c = content[end];
            if (c == ' ' or c == '=' or c == ':' or c == '\n') break;
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

    /// Check if "const " at position i is at the start of a statement
    /// (not inside a parameter type like "arg: ?[]const u8").
    fn isConstStatementStart(content: []const u8, i: usize) bool {
        if (i == 0) return true;
        if (i >= 4 and mem.eql(u8, content[i - 4 .. i], "pub ")) return true;
        // Walk backwards to find the start of this line
        var j = i;
        while (j > 0 and content[j - 1] != '\n') j -= 1;
        // Check if only whitespace before "const"
        var k = j;
        while (k < i) : (k += 1) {
            if (content[k] != ' ' and content[k] != '\t') return false;
        }
        return true;
    }

    /// Try to extract a const import at position i, recording it in analysis.
    fn tryRecordConstImport(
        self: *ImportGraph,
        content: []const u8,
        file_path: []const u8,
        analysis: *FileAnalysis,
        i: usize,
        line_num: usize,
        col: usize,
    ) !void {
        const is_pub = i >= 4 and mem.eql(u8, content[i - 4 .. i], "pub ");
        const name_start = i + 6;
        const var_name = extractVarName(content, name_start) orelse return;
        const path_start = name_start + var_name.len;
        const import_path = findImportPath(content, path_start) orelse return;
        if (mem.eql(u8, import_path, "std")) return;
        if (mem.eql(u8, import_path, "builtin")) return;

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

    fn extractImports(
        self: *ImportGraph,
        content: []const u8,
        file_path: []const u8,
        analysis: *FileAnalysis,
    ) !void {
        var line_num: usize = 1;
        var col: usize = 1;
        var i: usize = 0;
        var in_comment = false;

        while (i < content.len) : ({
            col += 1;
            i += 1;
        }) {
            if (content[i] == '\n') {
                line_num += 1;
                col = 1;
                in_comment = false;
                continue;
            }
            if (!in_comment and i + 1 < content.len and
                content[i] == '/' and content[i + 1] == '/')
            {
                in_comment = true;
                continue;
            }
            if (in_comment) continue;

            const not_const = i + 6 >= content.len or
                !mem.eql(u8, content[i .. i + 6], "const ");
            if (not_const) continue;
            if (!isConstStatementStart(content, i)) continue;

            try self.tryRecordConstImport(
                content,
                file_path,
                analysis,
                i,
                line_num,
                col,
            );
        }

        try self.extractBareImports(content, file_path, analysis);
    }

    /// Check if an import path is already recorded in the analysis.
    fn hasImportPath(analysis: *const FileAnalysis, path: []const u8) bool {
        for (analysis.imports.items) |existing| {
            if (mem.eql(u8, existing.path, path)) return true;
        }
        return false;
    }

    /// Try to add a bare import (not preceded by const) to analysis.
    fn tryAddBareImport(
        self: *ImportGraph,
        file_path: []const u8,
        analysis: *FileAnalysis,
        imp: []const u8,
    ) !void {
        if (mem.eql(u8, imp, "std")) return;
        if (mem.eql(u8, imp, "builtin")) return;
        if (hasImportPath(analysis, imp)) return;
        const resolved = try self.resolveImport(file_path, imp);
        try analysis.imports.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, imp),
            .resolved = resolved,
            .name = try self.allocator.dupe(u8, "_"),
            .line = 0,
            .col = 0,
            .is_pub = false,
        });
    }

    /// Extract @import("...") patterns that aren't preceded by `const`
    /// Catches switch arms like `=> @import("x.zig")`, array inits, etc.
    fn extractBareImports(
        self: *ImportGraph,
        content: []const u8,
        file_path: []const u8,
        analysis: *FileAnalysis,
    ) !void {
        const import_tag = "@import(\"";
        var pos: usize = 0;
        var in_line_comment = false;

        while (pos < content.len) {
            if (content[pos] == '\n') {
                in_line_comment = false;
                pos += 1;
                continue;
            }
            if (!in_line_comment and pos + 1 < content.len and
                content[pos] == '/' and content[pos + 1] == '/')
            {
                in_line_comment = true;
                pos += 2;
                continue;
            }
            if (in_line_comment) {
                pos += 1;
                continue;
            }

            if (pos + import_tag.len < content.len and
                mem.eql(u8, content[pos .. pos + import_tag.len], import_tag))
            {
                const path_start = pos + import_tag.len;
                var path_end = path_start;
                while (path_end < content.len and content[path_end] != '"') {
                    path_end += 1;
                }
                if (path_end > path_start) {
                    try self.tryAddBareImport(
                        file_path,
                        analysis,
                        content[path_start..path_end],
                    );
                }
                pos = path_end + 1;
                continue;
            }
            pos += 1;
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
        const resolved = fs.cwd().realpath(full, &buf) catch return null;
        if (!self.isWithinScanRoot(resolved)) return null;
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

    /// Find the build root directory containing build.zig.
    fn findBuildRoot(
        self: *ImportGraph,
        cfg: *const Config,
        buf: *[fs.max_path_bytes]u8,
    ) ?[]const u8 {
        // 1. Check entries for build.zig
        for (cfg.entries.items) |e| {
            if (mem.endsWith(u8, e, "build.zig")) {
                const dir = std.fs.path.dirname(e) orelse ".";
                return fs.cwd().realpath(dir, buf) catch continue;
            }
        }
        // 2. Try parent of target path
        const trimmed = mem.trimEnd(u8, cfg.path, "/");
        if (self.checkBuildZigAt(
            std.fs.path.dirname(trimmed) orelse ".",
            buf,
        )) |r| return r;
        // 3. Try target path itself
        return self.checkBuildZigAt(trimmed, buf);
    }

    /// Check if dir/build.zig exists and return realpath of dir.
    fn checkBuildZigAt(
        self: *ImportGraph,
        dir: []const u8,
        buf: *[fs.max_path_bytes]u8,
    ) ?[]const u8 {
        const check = std.fmt.allocPrint(
            self.allocator,
            "{s}/build.zig",
            .{dir},
        ) catch return null;
        defer self.allocator.free(check);
        fs.cwd().access(check, .{}) catch return null;
        return fs.cwd().realpath(dir, buf) catch null;
    }

    /// Scan already-loaded content for b.path("...zig") and pathJoin refs, marking reachable.
    fn scanContentBuildPathRefs(
        self: *ImportGraph,
        content: []const u8,
        build_root: []const u8,
    ) void {
        const bp_tag = "b.path(\"";
        var pos: usize = 0;
        while (pos + bp_tag.len < content.len) {
            const rest = content[pos..];
            const rel = mem.indexOf(u8, rest, bp_tag) orelse break;
            const str_start = pos + rel + bp_tag.len;
            var str_end = str_start;
            while (str_end < content.len and content[str_end] != '"') str_end += 1;
            if (str_end > str_start) {
                self.tryMarkBuildPath(
                    content[str_start..str_end],
                    build_root,
                );
            }
            pos = str_end + 1;
        }
        // Also scan for pathJoin(&.{ "dir", "file.zig" }) patterns
        self.scanContentPathJoinRefs(content, build_root);
    }

    /// Scan content for pathJoin(&.{ ... }) patterns and mark .zig results reachable.
    fn scanContentPathJoinRefs(
        self: *ImportGraph,
        content: []const u8,
        build_root: []const u8,
    ) void {
        const tag = "pathJoin(&.{";
        var pos: usize = 0;
        while (pos + tag.len < content.len) {
            const rest = content[pos..];
            const rel = mem.indexOf(u8, rest, tag) orelse break;
            const abs_pos = pos + rel + tag.len;
            if (extractPathJoin(self.allocator, content, abs_pos - 1)) |joined| {
                defer self.allocator.free(joined);
                self.tryMarkBuildPath(joined, build_root);
            }
            pos = abs_pos;
        }
    }

    /// Resolve a single b.path ref and mark it reachable if it's a .zig file.
    fn tryMarkBuildPath(
        self: *ImportGraph,
        ref_path: []const u8,
        build_root: []const u8,
    ) void {
        if (!mem.endsWith(u8, ref_path, ".zig")) return;
        const full = std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ build_root, ref_path },
        ) catch return;
        defer self.allocator.free(full);
        var rbuf: [fs.max_path_bytes]u8 = undefined;
        const resolved = fs.cwd().realpath(full, &rbuf) catch return;
        if (!self.isWithinScanRoot(resolved)) return;
        if (!self.reachable.contains(resolved)) {
            self.markReachableRecursive(resolved) catch return;
        }
    }

    /// After markReachable, scan reachable files for b.path("...") references
    /// and mark those targets as reachable too.
    fn markBuildPathReferences(self: *ImportGraph, cfg: *const Config) !void {
        var root_buf: [fs.max_path_bytes]u8 = undefined;
        const build_root = self.findBuildRoot(cfg, &root_buf) orelse return;

        // Snapshot reachable paths to avoid modify-while-iterate
        var to_scan: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_scan.deinit(self.allocator);
        var iter = self.reachable.iterator();
        while (iter.next()) |entry| {
            try to_scan.append(self.allocator, entry.key_ptr.*);
        }

        for (to_scan.items) |path| {
            const content = fs.cwd().readFileAlloc(
                self.allocator,
                path,
                4 * 1024 * 1024,
            ) catch continue;
            defer self.allocator.free(content);
            self.scanContentBuildPathRefs(content, build_root);
        }

        try self.discoverNestedBuildFiles(cfg);
        try self.markBuildModuleDirectories(cfg);
    }

    /// Check if an import looks like an unresolved module name.
    fn isUnresolvedModuleName(
        self: *ImportGraph,
        imp: types.ImportInfo,
    ) bool {
        if (imp.resolved) |resolved| {
            if (self.findImportsForPath(resolved) != null) return false;
        }
        if (mem.endsWith(u8, imp.path, ".zig")) return false;
        if (mem.indexOf(u8, imp.path, ".") != null) return false;
        if (mem.indexOf(u8, imp.path, "/") != null) return false;
        if (mem.eql(u8, imp.path, "std")) return false;
        if (mem.eql(u8, imp.path, "builtin")) return false;
        return true;
    }

    /// Collect unresolved module names from reachable files.
    fn collectUnresolvedModuleNames(
        self: *ImportGraph,
        module_names: *std.StringHashMapUnmanaged(void),
    ) void {
        var file_iter = self.files.iterator();
        while (file_iter.next()) |entry| {
            // Use cached resolved_path — realpath() was called once at
            // ingest. Calling it per iteration here cost O(N) openat
            // syscalls per pass on every invocation.
            if (!self.reachable.contains(entry.value_ptr.resolved_path)) continue;
            for (entry.value_ptr.imports.items) |imp| {
                if (!self.isUnresolvedModuleName(imp)) continue;
                if (module_names.contains(imp.path)) continue;
                self.tryAddModuleName(module_names, imp.path);
            }
        }
    }

    fn tryAddModuleName(
        self: *ImportGraph,
        module_names: *std.StringHashMapUnmanaged(void),
        path: []const u8,
    ) void {
        const d = self.allocator.dupe(u8, path) catch return;
        module_names.put(self.allocator, d, {}) catch {
            self.allocator.free(d);
        };
    }

    /// Resolve a directory path and add it as a search root if valid.
    fn addSearchRoot(
        self: *ImportGraph,
        dir: []const u8,
        buf: *[fs.max_path_bytes]u8,
        roots: *[2][]const u8,
        rc: *usize,
    ) void {
        const r = fs.cwd().realpath(dir, buf) catch return;
        const o = self.allocator.dupe(u8, r) catch return;
        roots[rc.*] = o;
        rc.* += 1;
    }

    /// Scan reachable files for unresolved module-name imports
    /// and resolve them to matching directories in the project tree.
    fn markBuildModuleDirectories(
        self: *ImportGraph,
        cfg: *const Config,
    ) !void {
        var module_names: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var fi = module_names.iterator();
            while (fi.next()) |fe| self.allocator.free(fe.key_ptr.*);
            module_names.deinit(self.allocator);
        }

        self.collectUnresolvedModuleNames(&module_names);
        if (module_names.count() == 0) return;

        const trimmed = mem.trimEnd(u8, cfg.path, "/");
        var search_roots: [2][]const u8 = undefined;
        var rc: usize = 0;
        var rb1: [fs.max_path_bytes]u8 = undefined;
        self.addSearchRoot(
            std.fs.path.dirname(trimmed) orelse ".",
            &rb1,
            &search_roots,
            &rc,
        );
        var rb2: [fs.max_path_bytes]u8 = undefined;
        self.addSearchRoot(trimmed, &rb2, &search_roots, &rc);
        defer for (search_roots[0..rc]) |r| self.allocator.free(r);

        var mi = module_names.iterator();
        while (mi.next()) |me| {
            for (search_roots[0..rc]) |root| {
                self.findAndMarkModuleDir(root, me.key_ptr.*, 3) catch continue;
            }
        }
    }

    /// Search for a directory matching mod_name and mark all .zig
    /// files inside it as reachable. Depth-limited.
    fn findAndMarkModuleDir(
        self: *ImportGraph,
        search_dir: []const u8,
        mod_name: []const u8,
        depth: usize,
    ) !void {
        if (depth == 0) return;
        var dir = fs.cwd().openDir(
            search_dir,
            .{ .iterate = true },
        ) catch return;
        defer dir.close(global_io.?);
        var iter = dir.iterate();
        while (try iter.next(global_io.?)) |entry| {
            if (entry.kind != .directory) continue;
            if (isSkippableDir(entry.name)) continue;
            const full = std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ search_dir, entry.name },
            ) catch continue;
            defer self.allocator.free(full);
            if (mem.eql(u8, entry.name, mod_name)) {
                self.markAllZigFilesReachable(full) catch continue;
            } else {
                self.findAndMarkModuleDir(
                    full,
                    mod_name,
                    depth - 1,
                ) catch continue;
            }
        }
    }

    /// Discover nested build.zig files in subdirectories and mark their
    /// @import and b.path references as reachable.
    fn discoverNestedBuildFiles(self: *ImportGraph, cfg: *const Config) !void {
        const trimmed = mem.trimEnd(u8, cfg.path, "/");
        var rbuf: [fs.max_path_bytes]u8 = undefined;
        const target_abs = fs.cwd().realpath(trimmed, &rbuf) catch return;
        const target_owned = self.allocator.dupe(u8, target_abs) catch return;
        defer self.allocator.free(target_owned);

        self.scanForNestedBuildZig(target_owned) catch return;
    }

    /// Common directories to skip during traversal
    const skip_dirs = [_][]const u8{
        ".git",       "zig-out",   "zig-cache",
        ".zig-cache", ".build",    "node_modules",
        "deps",       ".packages", "vendor",
    };

    fn isScanSkipDir(name: []const u8) bool {
        if (name.len > 0 and name[0] == '.') return true;
        return mem.eql(u8, name, "zig-cache") or
            mem.eql(u8, name, "zig-out");
    }

    fn isSkippableDir(name: []const u8) bool {
        // Skip all dot-prefixed directories (hidden dirs: .git, .zig-cache,
        // .zig-global-cache, .tmp, .claude, etc.). direnv-per-project layouts
        // produce many such dirs under the scan root — failing to skip them
        // caused severe slowdowns in recursive traversals (thousands of
        // openat/realpath calls into cache directories).
        if (name.len > 0 and name[0] == '.') return true;
        for (skip_dirs) |d| {
            if (mem.eql(u8, name, d)) return true;
        }
        return false;
    }

    /// Handle a subdirectory found during nested build.zig scanning
    fn handleNestedSubdir(self: *ImportGraph, subdir: []const u8) void {
        const build_path = std.fmt.allocPrint(
            self.allocator,
            "{s}/build.zig",
            .{subdir},
        ) catch return;
        defer self.allocator.free(build_path);

        if (fs.cwd().access(build_path, .{})) |_| {
            var buf2: [fs.max_path_bytes]u8 = undefined;
            if (fs.cwd().realpath(build_path, &buf2)) |resolved| {
                if (!self.reachable.contains(resolved))
                    self.markReachableRecursive(resolved) catch return;
            } else |_| {}
            self.markAllZigFilesReachable(subdir) catch return;
        } else |_| {}
    }

    fn scanForNestedBuildZig(self: *ImportGraph, dir_path: []const u8) !void {
        var dir = fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close(global_io.?);
        var iter = dir.iterate();
        while (try iter.next(global_io.?)) |entry| {
            if (entry.kind != .directory) continue;
            if (isSkippableDir(entry.name)) continue;
            const subdir = std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ dir_path, entry.name },
            ) catch continue;
            defer self.allocator.free(subdir);
            self.handleNestedSubdir(subdir);
            if (isBuildManagedDir(entry.name))
                self.markAllZigFilesReachable(subdir) catch continue;
            self.scanForNestedBuildZig(subdir) catch continue;
        }
    }

    /// Scan all reachable files under a sub-project directory for b.path() references
    fn scanSubprojectBuildPaths(self: *ImportGraph, subdir: []const u8) !void {
        var rbuf: [fs.max_path_bytes]u8 = undefined;
        const abs_subdir = fs.cwd().realpath(subdir, &rbuf) catch return;

        // Snapshot reachable paths to check which are in this sub-project
        var to_scan: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_scan.deinit(self.allocator);
        {
            var iter = self.reachable.iterator();
            while (iter.next()) |entry| {
                if (!mem.startsWith(u8, entry.key_ptr.*, abs_subdir)) continue;
                try to_scan.append(self.allocator, entry.key_ptr.*);
            }
        }
        for (to_scan.items) |path| {
            self.scanFileBuildPathRefs(path, subdir) catch continue;
        }
    }

    /// Scan a specific file for b.path("...") references and resolve them
    /// relative to the given base directory
    /// Resolve a b.path() .zig reference and mark as reachable
    fn resolveAndMarkBuildPath(
        self: *ImportGraph,
        base_dir: []const u8,
        ref_path: []const u8,
    ) void {
        if (!mem.endsWith(u8, ref_path, ".zig")) return;
        const full = std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ base_dir, ref_path },
        ) catch return;
        defer self.allocator.free(full);
        var rbuf: [fs.max_path_bytes]u8 = undefined;
        const resolved = fs.cwd().realpath(full, &rbuf) catch return;
        if (!self.isWithinScanRoot(resolved)) return;
        if (!self.reachable.contains(resolved))
            self.markReachableRecursive(resolved) catch return;
    }

    fn scanFileBuildPathRefs(
        self: *ImportGraph,
        file_path: []const u8,
        base_dir: []const u8,
    ) !void {
        const content = fs.cwd().readFileAlloc(
            self.allocator,
            file_path,
            4 * 1024 * 1024,
        ) catch return;
        defer self.allocator.free(content);

        const bp_tag = "b.path(\"";
        var pos: usize = 0;
        while (pos + bp_tag.len < content.len) {
            const rest = content[pos..];
            const rel = mem.indexOf(u8, rest, bp_tag) orelse break;
            const str_start = pos + rel + bp_tag.len;
            var str_end = str_start;
            while (str_end < content.len and content[str_end] != '"') str_end += 1;
            if (str_end > str_start)
                self.resolveAndMarkBuildPath(base_dir, content[str_start..str_end]);
            pos = str_end + 1;
        }
    }

    /// Check if a directory name is commonly managed by the build system
    /// (contains files referenced via b.path() or .root_src in build.zig)
    fn isBuildManagedDir(name: []const u8) bool {
        const managed = [_][]const u8{
            "lib", "tools", "test", "compiler_rt",
        };
        for (managed) |m| {
            if (mem.eql(u8, name, m)) return true;
        }
        return false;
    }

    /// Mark all .zig files under a directory as reachable (for nested build.zig sub-projects
    /// where we can't statically resolve b.path(variable) calls)
    fn markAllZigFilesReachable(self: *ImportGraph, dir_path: []const u8) !void {
        self.markZigFilesRecursive(dir_path) catch return;
    }

    /// Mark a single .zig file as reachable via realpath resolution
    fn markSingleZigFile(self: *ImportGraph, dir_path: []const u8, name: []const u8) void {
        const full = std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ dir_path, name },
        ) catch return;
        defer self.allocator.free(full);
        var rbuf: [fs.max_path_bytes]u8 = undefined;
        const resolved = fs.cwd().realpath(full, &rbuf) catch return;
        if (!self.reachable.contains(resolved))
            self.markReachableRecursive(resolved) catch return;
    }

    fn markZigFilesRecursive(self: *ImportGraph, dir_path: []const u8) !void {
        var dir = fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close(global_io.?);
        var iter = dir.iterate();
        while (try iter.next(global_io.?)) |entry| {
            if (entry.kind == .file and mem.endsWith(u8, entry.name, ".zig"))
                self.markSingleZigFile(dir_path, entry.name);
            if (entry.kind != .directory or isSkippableDir(entry.name))
                continue;
            const sub = std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ dir_path, entry.name },
            ) catch continue;
            defer self.allocator.free(sub);
            self.markZigFilesRecursive(sub) catch continue;
        }
    }

    fn findImportsForPath(self: *ImportGraph, path: []const u8) ?[]ImportInfo {
        // Fast path: resolved → key via reverse index (O(1)).
        if (self.resolved_to_key.get(path)) |key| {
            if (self.files.getPtr(key)) |entry| return entry.imports.items;
        }
        // Fallback: path may already be a files key (no realpath needed),
        // or may be a path form we haven't indexed. A single pointer
        // lookup on the primary map handles the former; we deliberately
        // do NOT call realpath on every file here — that's what blew up.
        if (self.files.getPtr(path)) |entry| return entry.imports.items;
        return null;
    }

    fn getOrphanIssues(
        self: *ImportGraph,
        allocator: Allocator,
        cfg: *const Config,
    ) !std.ArrayListUnmanaged(Issue) {
        var issues: std.ArrayListUnmanaged(Issue) = .empty;
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;

            // Skip files matching orphan_exclude patterns
            if (isOrphanExcluded(key, cfg)) continue;

            // Use cached resolved_path instead of per-iteration realpath.
            if (self.reachable.contains(entry.value_ptr.resolved_path)) continue;
            try issues.append(allocator, .{
                .file = key,
                .line = 1,
                .col = 1,
                .severity = .warning,
                .rule = RULE_ORPHAN_FILE,
                .message = "file not imported",
                .help = "add @import() or remove if unused",
            });
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
            // Comptime concat avoids self-matching when ephor scans its own source
            const ni_count = countOccurrences(a.content, "error.Not" ++ "Implemented");
            s.not_implemented_count += ni_count;
            const todo = countOccurrences(a.content, "TO" ++ "DO");
            const fixme = countOccurrences(a.content, "FIX" ++ "ME");
            s.todo_count += todo + fixme;

            var lines = mem.splitScalar(u8, a.content, '\n');
            while (lines.next()) |line| {
                const t = mem.trim(u8, line, " \t\r");
                if (t.len == 0)
                    s.blank_lines += 1
                else if (mem.startsWith(u8, t, "//"))
                    s.comment_lines += 1
                else
                    s.code_lines += 1;
            }
        }
        return s;
    }
};

// ============================================================================
// Memory Analysis Helpers
// ============================================================================

/// Build a set of variable names that hold no-free allocators by tracking
/// type-based initialization patterns in the function body.
/// Build set of variable names holding no-free allocators by tracking
/// TYPE-BASED initialization patterns (Zig stdlib types only).
/// Tracks: FixedBufferAllocator, ArenaAllocator, StackFallbackAllocator
/// Also tracks .allocator() aliases and struct field aliases.
fn collectNoFreeAllocatorNames(
    a: Allocator,
    lines: []const []const u8,
    file_no_free_fields: ?*const std.StringHashMapUnmanaged(void),
) !std.StringHashMapUnmanaged(void) {
    var names = std.StringHashMapUnmanaged(void){};

    // Scan function signature for arena-named Allocator parameters.
    // Check first ~10 lines for parameter declarations like `arena: Allocator`
    // or `arena: std.mem.Allocator` in the function signature.
    const sig_limit = @min(lines.len, 10);
    for (lines[0..sig_limit]) |line| {
        const t = mem.trim(u8, line, " \t\r");
        // Stop scanning once we hit the function body (lines starting with real code)
        if (mem.startsWith(u8, t, "const ") or mem.startsWith(u8, t, "var ") or
            mem.startsWith(u8, t, "defer ") or mem.startsWith(u8, t, "if ") or
            mem.startsWith(u8, t, "return ") or mem.startsWith(u8, t, "try "))
            break;
        // Look for ALL `arena: Allocator` or `arena: std.mem.Allocator` patterns on the line.
        // A function signature may have multiple params: fn foo(gpa: Allocator, arena: Allocator)
        {
            var search_start: usize = 0;
            while (mem.indexOf(u8, t[search_start..], ": ")) |rel_pos| {
                const colon_pos = search_start + rel_pos;
                // Extract parameter name (ident chars before the colon)
                var pname_start = colon_pos;
                while (pname_start > 0 and isIdent(t[pname_start - 1])) pname_start -= 1;
                const pname = t[pname_start..colon_pos];
                if (pname.len > 0 and isArenaName(pname)) {
                    const type_str = mem.trim(u8, t[colon_pos + 2 ..], " \t,)");
                    if (isAllocatorType(type_str)) {
                        try names.put(a, pname, {});
                    }
                }
                search_start = colon_pos + 2;
            }
        }
    }

    // No-free allocator type init patterns from stdlib vocabulary (compat layer)
    const no_free_inits = compat.getNoFreeInitPatterns();

    for (lines) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;
        if (!(mem.startsWith(u8, t, "const ") or mem.startsWith(u8, t, "var "))) continue;
        const name = extractVarDeclName(t) orelse continue;

        // Track variables initialized with known no-free allocator types
        for (no_free_inits) |init_pat| {
            if (mem.indexOf(u8, t, init_pat) != null) {
                try names.put(a, name, {});
                break;
            }
        }

        // Anonymous init syntax (Zig 0.15+): `var fba: std.heap.FixedBufferAllocator = .init(`
        // The type annotation declares the no-free type but `.init(` doesn't match
        // the normal `FixedBufferAllocator.init(` pattern.
        if (!names.contains(name)) {
            if (mem.indexOf(u8, t, "= .init(") != null or mem.indexOf(u8, t, "= .{") != null) {
                // Check if the type annotation is a no-free allocator type
                if (mem.indexOf(u8, t, ": ")) |colon_pos| {
                    const after_colon = mem.trim(u8, t[colon_pos + 2 ..], " \t");
                    const field_type_patterns = compat.getNoFreeFieldTypePatterns();
                    for (field_type_patterns) |pat| {
                        if (mem.startsWith(u8, after_colon, pat)) {
                            try names.put(a, name, {});
                            break;
                        }
                    }
                }
            }
        }

        // Track local variables named "arena" as no-free allocators:
        // `const arena = session.arena;`, `const arena = s.owner.allocator;`,
        // `const arena = b.allocator;` etc.
        // Naming a variable "arena" is a strong convention signal in Zig that
        // it's backed by an arena allocator. False negative risk is near-zero.
        const eq_pos = mem.indexOf(u8, t, " = ") orelse continue;
        var rhs = mem.trim(u8, t[eq_pos + 3 ..], " \t");
        if (mem.startsWith(u8, rhs, "try ")) rhs = rhs[4..];

        if (!names.contains(name)) {
            if (isArenaName(name)) {
                try names.put(a, name, {});
                continue;
            }
        }

        // Track .allocator() aliases: const X = Y.allocator()
        // where Y is a tracked no-free allocator variable (or Y.field is)
        const dot_alloc = mem.indexOf(u8, rhs, ".allocator()") orelse continue;
        const source = rhs[0..dot_alloc];
        if (source.len == 0) continue;

        // Check if source is a tracked no-free variable (simple identifier)
        var all_ident = true;
        for (source) |c| {
            if (!isIdent(c)) {
                all_ident = false;
                break;
            }
        }
        if (all_ident and names.contains(source)) {
            try names.put(a, name, {});
            continue;
        }

        // Check dotted sources: self.arena.allocator(), x.fba.allocator()
        // The last segment before .allocator() might be a tracked no-free var
        // or a file-level no-free field (e.g. arena declared as ArenaAllocator or
        // as Allocator with arena name in a struct definition).
        if (mem.lastIndexOf(u8, source, ".")) |last_dot| {
            const field = source[last_dot + 1 ..];
            if (field.len > 0) {
                if (names.contains(field)) {
                    try names.put(a, name, {});
                    continue;
                }
                if (file_no_free_fields) |fields| {
                    if (fields.contains(field)) {
                        try names.put(a, name, {});
                        continue;
                    }
                }
            }
        }
    }

    return names;
}

/// Collect struct field names whose declared type is a no-free allocator.
/// Scans the entire file for struct field declarations matching stdlib no-free
/// allocator types (e.g. `arena: std.heap.ArenaAllocator,`).
/// Type-based only — matches on declared types, never on field names.
fn collectNoFreeFieldNames(a: Allocator, lines: []const []const u8) !std.StringHashMapUnmanaged(void) {
    var names = std.StringHashMapUnmanaged(void){};
    const field_type_patterns = compat.getNoFreeFieldTypePatterns();

    for (lines) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;

        // Match struct field declarations: `field_name: TypePattern`
        // Must contain `: ` (field declaration syntax) but NOT `const ` or `var `
        // (those are variable declarations handled by collectNoFreeAllocatorNames)
        if (mem.startsWith(u8, t, "const ") or mem.startsWith(u8, t, "var ")) continue;
        if (mem.startsWith(u8, t, "pub const ") or mem.startsWith(u8, t, "pub var ")) continue;

        // Look for `identifier: type_pattern` pattern
        const colon_pos = mem.indexOf(u8, t, ": ") orelse continue;
        if (colon_pos == 0) continue;

        // Extract field name (everything before the colon must be a valid identifier)
        const field_name = t[0..colon_pos];
        var valid_field = true;
        for (field_name) |c| {
            if (!isIdent(c)) {
                valid_field = false;
                break;
            }
        }
        if (!valid_field or field_name.len == 0) continue;

        // Check if the type after `: ` matches a no-free allocator type
        const type_part = mem.trim(u8, t[colon_pos + 2 ..], " \t");
        for (field_type_patterns) |pat| {
            if (mem.startsWith(u8, type_part, pat)) {
                // Verify the match is a complete type (followed by , or = or end)
                if (type_part.len == pat.len or
                    type_part[pat.len] == ',' or
                    type_part[pat.len] == ' ' or
                    type_part[pat.len] == '=')
                {
                    try names.put(a, field_name, {});
                    break;
                }
            }
        }

        // Name-based heuristic: fields named "arena" (or containing "arena")
        // with type Allocator/std.mem.Allocator/mem.Allocator are treated as no-free.
        // In the Zig ecosystem, arena-named Allocator fields are always backed by
        // ArenaAllocator — naming a GPA-backed allocator "arena" would be a severe
        // convention violation.
        if (!names.contains(field_name) and isArenaName(field_name)) {
            if (isAllocatorType(type_part)) {
                try names.put(a, field_name, {});
            }
        }
    }

    return names;
}

/// Check if a field/param name indicates an arena allocator.
/// Matches "arena" exactly or names containing "arena" (e.g. "child_arena").
fn isArenaName(name: []const u8) bool {
    if (mem.eql(u8, name, "arena")) return true;
    if (mem.indexOf(u8, name, "arena") != null) return true;
    return false;
}

/// Check if a type string is an Allocator type (not ArenaAllocator/FixedBufferAllocator).
/// Matches: Allocator, std.mem.Allocator, mem.Allocator
fn isAllocatorType(type_part: []const u8) bool {
    const allocator_types = [_][]const u8{
        "Allocator",
        "std.mem.Allocator",
        "mem.Allocator",
    };
    for (allocator_types) |at| {
        if (mem.startsWith(u8, type_part, at)) {
            // Verify complete type (followed by terminator char or end of string)
            if (type_part.len == at.len) return true;
            const next = type_part[at.len];
            if (next == ',' or next == ' ' or next == '=' or
                next == ')' or next == '}' or next == ';')
            {
                return true;
            }
        }
    }
    return false;
}

/// Content-based version of collectNoFreeFieldNames for file-level scanning.
/// Splits content by newlines and delegates to the line-based version.
fn collectNoFreeFieldNamesFromContent(
    a: Allocator,
    content: []const u8,
) !std.StringHashMapUnmanaged(void) {
    // Split content into lines
    var file_lines = std.ArrayListUnmanaged([]const u8).empty;
    defer file_lines.deinit(a);
    var line_iter = mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        try file_lines.append(a, line);
    }
    return collectNoFreeFieldNames(a, file_lines.items);
}

/// Check if an allocation call is through a struct field chain where one
/// segment is a known no-free allocator field (type-based or name-based detection).
/// Matches patterns like: self.arena.alloc(...), ctx.fba.dupe(...)
/// where `arena`/`fba` were declared as no-free allocator types in a struct,
/// OR where the segment is named "arena" (name-based cross-file heuristic).
fn isNoFreeFieldChain(t: []const u8, no_free_fields: *const std.StringHashMapUnmanaged(void)) bool {
    // Find the allocation method position
    var method_pos: ?usize = null;
    for (compat.getAllocMethodPatterns()) |pat| {
        if (mem.indexOf(u8, t, pat)) |pos| {
            if (method_pos == null or pos < method_pos.?)
                method_pos = pos;
        }
    }
    const end = method_pos orelse return false;
    if (end == 0) return false;

    // Walk backwards to extract the full receiver chain (e.g. "self.arena")
    var start = end;
    while (start > 0 and (isIdent(t[start - 1]) or t[start - 1] == '.')) {
        start -= 1;
    }
    if (start >= end) return false;
    const chain = t[start..end];

    // Must be a dotted chain (not just a bare identifier)
    if (mem.indexOf(u8, chain, ".") == null) return false;

    // Check each segment of the chain against known no-free field names
    // AND against the arena name heuristic (cross-file support)
    var iter_start: usize = 0;
    while (iter_start < chain.len) {
        // Find next dot or end of chain
        const dot_pos = mem.indexOf(u8, chain[iter_start..], ".") orelse (chain.len - iter_start);
        const segment = chain[iter_start .. iter_start + dot_pos];
        if (segment.len > 0) {
            // Type-based: field declared as no-free allocator type
            if (no_free_fields.count() > 0 and no_free_fields.contains(segment)) {
                return true;
            }
            // Name-based: field named "arena" — cross-file heuristic.
            // The struct definition may be in another file (e.g., Sema.zig defines
            // `arena: Allocator` but Sema/arith.zig uses `sema.arena.alloc()`).
            if (isArenaName(segment)) {
                return true;
            }
        }
        iter_start += dot_pos + 1;
    }

    return false;
}

/// Build set of ALL allocator variable names (both no-free and need-free).
/// Used to determine if `.create()` receiver is an allocator.
/// Tracks stdlib type initializations + .allocator() calls + global singletons.
fn collectAllAllocatorNames(a: Allocator, lines: []const []const u8) !std.StringHashMapUnmanaged(void) {
    var names = std.StringHashMapUnmanaged(void){};

    // All allocator type init patterns from stdlib vocabulary (compat layer)
    const alloc_inits = compat.getAllInitPatterns();

    // Global singleton allocators from stdlib vocabulary (compat layer)
    const global_allocs = compat.getGlobalAllocNames();

    for (lines) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;
        if (!(mem.startsWith(u8, t, "const ") or mem.startsWith(u8, t, "var "))) continue;
        const name = extractVarDeclName(t) orelse continue;

        // Track variables initialized with known allocator types
        for (alloc_inits) |init_pat| {
            if (mem.indexOf(u8, t, init_pat) != null) {
                try names.put(a, name, {});
                break;
            }
        }

        // Track variables assigned global singleton allocators
        const eq_pos = mem.indexOf(u8, t, " = ") orelse continue;
        const rhs = mem.trim(u8, t[eq_pos + 3 ..], " \t;");
        for (global_allocs) |g| {
            if (mem.endsWith(u8, rhs, g)) {
                try names.put(a, name, {});
                break;
            }
        }

        // Track .allocator() aliases: const X = Y.allocator()
        // where Y is any tracked allocator variable
        if (mem.indexOf(u8, rhs, ".allocator()") != null) {
            const dot_pos = mem.indexOf(u8, rhs, ".allocator()").?;
            const source = rhs[0..dot_pos];
            if (source.len > 0) {
                var all_ident = true;
                for (source) |c| {
                    if (!isIdent(c)) {
                        all_ident = false;
                        break;
                    }
                }
                if (all_ident and names.contains(source)) {
                    try names.put(a, name, {});
                }
            }
        }
    }

    // Also track function parameters typed as Allocator
    for (lines[0..@min(10, lines.len)]) |line| {
        const t = mem.trim(u8, line, " \t\r");
        // Parameter with Allocator type: "name: Allocator" or "name: std.mem.Allocator"
        if (mem.indexOf(u8, t, ": Allocator") != null or
            mem.indexOf(u8, t, ": std.mem.Allocator") != null or
            mem.indexOf(u8, t, ": *Allocator") != null or
            mem.indexOf(u8, t, ":Allocator") != null)
        {
            // Extract parameter name (word before the colon)
            if (mem.indexOf(u8, t, ": Allocator") orelse
                mem.indexOf(u8, t, ": std.mem.Allocator") orelse
                mem.indexOf(u8, t, ": *Allocator") orelse
                mem.indexOf(u8, t, ":Allocator")) |colon_pos|
            {
                var start = colon_pos;
                while (start > 0 and (isIdent(t[start - 1]) or t[start - 1] == '_')) start -= 1;
                if (start < colon_pos) {
                    const param_name = t[start..colon_pos];
                    if (param_name.len > 0) try names.put(a, param_name, {});
                }
            }
        }
        // Stop at function body
        if (mem.indexOf(u8, t, ") ") != null and mem.indexOf(u8, t, "{") != null) break;
    }

    return names;
}

/// Scan file content to find functions called with no-free allocator arguments.
/// Enables cross-function propagation: if `foo(arena_var)` where arena_var is
/// tracked as no-free, then `foo` receives a no-free allocator parameter.
/// This fixes false positives where arena is passed as std.mem.Allocator interface.
fn buildNoFreeParamFunctions(a: Allocator, content: []const u8) !std.StringHashMapUnmanaged(void) {
    var result = std.StringHashMapUnmanaged(void){};

    // Step 1: Collect all no-free allocator variable names at file scope
    var no_free_vars = std.StringHashMapUnmanaged(void){};
    defer no_free_vars.deinit(a);

    const no_free_inits = compat.getNoFreeInitPatterns();
    var lines = mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;
        if (!(mem.startsWith(u8, t, "const ") or mem.startsWith(u8, t, "var "))) continue;
        const name = extractVarDeclName(t) orelse continue;

        for (no_free_inits) |pat| {
            if (mem.indexOf(u8, t, pat) != null) {
                try no_free_vars.put(a, name, {});
                break;
            }
        }

        // Track .allocator() aliases of tracked no-free vars
        const eq_pos = mem.indexOf(u8, t, " = ") orelse continue;
        var rhs = mem.trim(u8, t[eq_pos + 3 ..], " \t");
        if (mem.startsWith(u8, rhs, "try ")) rhs = rhs[4..];
        const dot_alloc = mem.indexOf(u8, rhs, ".allocator()") orelse continue;
        const source = rhs[0..dot_alloc];
        if (source.len == 0) continue;
        var all_ident = true;
        for (source) |c| {
            if (!isIdent(c)) {
                all_ident = false;
                break;
            }
        }
        if (all_ident and no_free_vars.contains(source)) {
            try no_free_vars.put(a, name, {});
        }
    }

    if (no_free_vars.count() == 0) return result;

    // Step 2: Content-based scan for function calls with no-free var arguments
    // Handles multi-line function calls (common in Zig code)
    var cpos: usize = 0;
    while (cpos < content.len) {
        const paren_pos = mem.indexOfScalarPos(u8, content, cpos, '(') orelse break;
        cpos = paren_pos + 1;

        // Extract function name before the paren
        if (paren_pos == 0) continue;
        var fn_start: usize = paren_pos;
        while (fn_start > 0 and isIdent(content[fn_start - 1])) fn_start -= 1;
        if (fn_start == paren_pos) continue;

        const func_name = content[fn_start..paren_pos];
        // Skip method calls (preceded by dot)
        if (fn_start > 0 and content[fn_start - 1] == '.') continue;
        // Skip type constructors (uppercase first letter)
        if (func_name[0] >= 'A' and func_name[0] <= 'Z') continue;
        // Skip keywords
        if (mem.eql(u8, func_name, "try") or mem.eql(u8, func_name, "if") or
            mem.eql(u8, func_name, "while") or mem.eql(u8, func_name, "for") or
            mem.eql(u8, func_name, "catch") or mem.eql(u8, func_name, "switch") or
            mem.eql(u8, func_name, "return") or mem.eql(u8, func_name, "fn") or
            mem.eql(u8, func_name, "test")) continue;
        // Skip function definitions: check for "fn " or "pub fn " before name
        if (fn_start >= 3 and mem.eql(u8, content[fn_start - 3 .. fn_start], "fn ")) continue;
        if (fn_start >= 7 and mem.eql(u8, content[fn_start - 7 .. fn_start], "pub fn ")) continue;

        // Find matching closing paren (handles multi-line calls)
        var close: usize = paren_pos + 1;
        var depth: usize = 0;
        const max_scan = @min(content.len, paren_pos + 2000); // Limit scan range
        while (close < max_scan) : (close += 1) {
            if (content[close] == '(') {
                depth += 1;
            } else if (content[close] == ')') {
                if (depth == 0) break;
                depth -= 1;
            }
        }
        if (close >= max_scan) continue;

        const args = content[paren_pos + 1 .. close];

        // Check if any no-free var is referenced in the arguments
        var nfi = no_free_vars.iterator();
        while (nfi.next()) |nf_entry| {
            const nf_name = nf_entry.key_ptr.*;
            var search_pos: usize = 0;
            while (search_pos < args.len) {
                const found = mem.indexOfPos(u8, args, search_pos, nf_name) orelse break;
                const end = found + nf_name.len;
                const before_ok = found == 0 or !isIdent(args[found - 1]);
                const after_ok = end >= args.len or
                    !isIdent(args[end]);
                if (before_ok and after_ok) {
                    try result.put(a, func_name, {});
                    break;
                }
                search_pos = end;
            }
            if (result.contains(func_name)) break;
        }
    }

    return result;
}

// ============================================================================
// TypeContext: Return-type-aware detection infrastructure
// ============================================================================

/// Classify a return type string (text after closing `)` in a fn signature).
fn classifyReturnType(ret: []const u8) ReturnKind {
    const t = mem.trim(u8, ret, " \t\r");
    if (t.len == 0) return .unknown;
    if (mem.eql(u8, t, "void")) return .void_type;
    if (mem.eql(u8, t, "noreturn")) return .noreturn_type;
    // Error union: starts with '!' or contains '!' before the type
    if (t[0] == '!') return .error_union;
    // "ErrorSet!T" or "anyerror!T" patterns
    if (mem.indexOf(u8, t, "!") != null) return .error_union;
    if (t[0] == '?') return .optional;
    return .value;
}

/// Type-aware context for resolving return types of method calls and functions.
/// Replaces the flat `StringHashMapUnmanaged(void)` stdlib_vars with richer info.
const TypeContext = struct {
    /// "StructName" -> ("methodName" -> ReturnKind)
    struct_methods: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(ReturnKind)),
    /// "functionName" -> ReturnKind (top-level/file-scope functions)
    function_returns: std.StringHashMapUnmanaged(ReturnKind),
    /// "varName" -> "TypeName" (from declarations)
    var_types: std.StringHashMapUnmanaged([]const u8),
    /// "varName" -> void (known stdlib vars, for vocab fallback)
    stdlib_vars: std.StringHashMapUnmanaged(void),

    fn init() TypeContext {
        return .{
            .struct_methods = .empty,
            .function_returns = .empty,
            .var_types = .empty,
            .stdlib_vars = .empty,
        };
    }

    fn deinit(self: *TypeContext, a: Allocator) void {
        var it = self.struct_methods.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(a);
        }
        self.struct_methods.deinit(a);
        self.function_returns.deinit(a);
        self.var_types.deinit(a);
        self.stdlib_vars.deinit(a);
    }
};

/// Result of extracting a method call from a line
const MethodCall = struct { receiver: []const u8, method: []const u8 };

/// Extract receiver.method from a line containing a method call.
/// Scans for "identifier.identifier(" patterns. Returns the last such match.
fn extractMethodCall(t: []const u8) ?MethodCall {
    var result: ?MethodCall = null;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (t[i] != '.') continue;
        // Extract method name after dot
        const method_start = i + 1;
        var method_end = method_start;
        while (method_end < t.len and isIdent(t[method_end])) method_end += 1;
        if (method_end == method_start) continue;
        if (method_end >= t.len or t[method_end] != '(') continue;
        // Extract receiver before dot
        const target = extractMethodTarget(t, i) orelse continue;
        result = .{ .receiver = target, .method = t[method_start..method_end] };
    }
    return result;
}

/// Resolve the return kind for a call expression on a trimmed line.
/// Checks TypeContext in order: parsed struct methods, parsed functions, then unknown.
fn resolveReturnKind(ctx: *const TypeContext, t: []const u8) ReturnKind {
    // Try method call resolution: receiver.method(
    if (extractMethodCall(t)) |call| {
        if (ctx.var_types.get(call.receiver)) |type_name| {
            if (ctx.struct_methods.get(type_name)) |methods| {
                if (methods.get(call.method)) |rk| return rk;
            }
        }
    }
    // Try standalone function call: _ = funcName(
    if (mem.startsWith(u8, t, "_ = ")) {
        const after = t[4..];
        const paren = mem.indexOf(u8, after, "(") orelse return .unknown;
        const name = after[0..paren];
        // Must be a simple identifier (no dots = not a method call)
        if (mem.indexOf(u8, name, ".") != null) return .unknown;
        if (name.len == 0) return .unknown;
        var all_ident = true;
        for (name) |c| {
            if (!isIdent(c)) {
                all_ident = false;
                break;
            }
        }
        if (all_ident) {
            if (ctx.function_returns.get(name)) |rk| return rk;
        }
    }
    return .unknown;
}

/// Extract return type text from a function signature line.
/// Given a line like "pub fn foo(self: *T, x: u32) !void {", returns "!void".
/// Returns null if no valid return type can be extracted.
fn extractFnReturnType(t: []const u8) ?[]const u8 {
    // Find the fn keyword to ensure we're looking at a function
    const fn_pos = mem.indexOf(u8, t, "fn ") orelse return null;
    // Find the opening paren of params
    const open_paren = mem.indexOfScalarPos(u8, t, fn_pos, '(') orelse return null;
    // Walk to find the matching closing paren (handle nested parens)
    var depth: usize = 0;
    var close_paren: ?usize = null;
    for (t[open_paren..], 0..) |c, offset| {
        if (c == '(') depth += 1;
        if (c == ')') {
            depth -= 1;
            if (depth == 0) {
                close_paren = open_paren + offset;
                break;
            }
        }
    }
    const cp = close_paren orelse return null;
    // Text between close paren and opening brace is the return type
    const after_close = t[cp + 1 ..];
    // Find the opening brace (or end of line for declarations without body)
    const brace = mem.indexOfScalar(u8, after_close, '{') orelse after_close.len;
    const ret_text = mem.trim(u8, after_close[0..brace], " \t\r");
    if (ret_text.len == 0) return null;
    return ret_text;
}

/// Extract the self-parameter type name from a method signature.
/// For "fn foo(self: *MyStruct, ...)" returns "MyStruct".
/// For "fn foo(self: *const MyStruct)" returns "MyStruct".
/// For "fn foo(self: MyStruct)" returns "MyStruct".
fn extractSelfTypeName(t: []const u8) ?[]const u8 {
    // Find the parameter list opening
    const open_paren = mem.indexOfScalar(u8, t, '(') orelse return null;
    // Find self parameter
    const after_paren = t[open_paren + 1 ..];
    const trimmed = mem.trim(u8, after_paren, " \t");
    if (!mem.startsWith(u8, trimmed, "self")) return null;
    // Must be followed by : or , or )
    if (trimmed.len <= 4) return null;
    if (trimmed[4] != ':' and trimmed[4] != ' ') return null;
    // Find the colon after self
    const colon_pos = mem.indexOfScalar(u8, trimmed, ':') orelse return null;
    const type_text = mem.trim(u8, trimmed[colon_pos + 1 ..], " \t");
    // Strip pointer markers: *Type, *const Type
    var name_start: usize = 0;
    if (type_text.len > 0 and type_text[0] == '*') {
        name_start = 1;
        const remaining = type_text[1..];
        if (mem.startsWith(u8, remaining, "const ")) {
            name_start = 7; // past "*const "
        }
    }
    // Extract the type name (identifier chars until comma, paren, or space)
    var name_end = name_start;
    while (name_end < type_text.len and isIdent(type_text[name_end])) name_end += 1;
    if (name_end <= name_start) return null;
    return type_text[name_start..name_end];
}

/// Extract the function name from a fn declaration line.
/// "pub fn foo(...)" -> "foo", "fn bar(...)" -> "bar"
fn extractFnName(t: []const u8) ?[]const u8 {
    const fn_pos = mem.indexOf(u8, t, "fn ") orelse return null;
    const after_fn = t[fn_pos + 3 ..];
    var end: usize = 0;
    while (end < after_fn.len and isIdent(after_fn[end])) end += 1;
    if (end == 0) return null;
    return after_fn[0..end];
}

/// Extract the type name from a variable declaration's right-hand side.
/// Handles: `var x: TypeName = ...`, `var x = TypeName.init(...)`, `var x = TypeName{...}`
fn extractVarTypeName(t: []const u8) ?[]const u8 {
    // Must be a var/const declaration
    const is_var = mem.startsWith(u8, t, "var ");
    const is_const = mem.startsWith(u8, t, "const ");
    if (!is_var and !is_const) return null;

    // Check for explicit type annotation: var x: TypeName = ...
    const prefix_len: usize = if (is_var) 4 else 6;
    var name_end = prefix_len;
    while (name_end < t.len and isIdent(t[name_end])) name_end += 1;
    if (name_end <= prefix_len) return null;
    const after_name = mem.trim(u8, t[name_end..], " \t");
    if (after_name.len > 0 and after_name[0] == ':') {
        // Explicit type annotation
        const type_start_raw = after_name[1..];
        const type_start = mem.trim(u8, type_start_raw, " \t");
        // Skip pointer/optional markers for the type name
        var ts: usize = 0;
        if (ts < type_start.len and type_start[ts] == '*') ts += 1;
        if (ts < type_start.len and type_start[ts] == '?') ts += 1;
        var te: usize = ts;
        while (te < type_start.len and isIdent(type_start[te])) te += 1;
        if (te > ts) return type_start[ts..te];
    }

    // Check for TypeName.init( or TypeName{ patterns
    const eq_pos = mem.indexOf(u8, t, " = ") orelse return null;
    const rhs = mem.trim(u8, t[eq_pos + 3 ..], " \t");
    if (rhs.len == 0) return null;
    // Must start with uppercase (type names are PascalCase in Zig)
    if (rhs[0] < 'A' or rhs[0] > 'Z') return null;
    // Extract the type identifier
    var rhs_end: usize = 0;
    while (rhs_end < rhs.len and isIdent(rhs[rhs_end])) rhs_end += 1;
    if (rhs_end == 0) return null;
    // Must be followed by .init(, {, or ( (generic type)
    if (rhs_end >= rhs.len) return null;
    const next_char = rhs[rhs_end];
    if (next_char == '{' or next_char == '(') return rhs[0..rhs_end];
    if (next_char == '.') {
        // TypeName.init( or TypeName.method(
        return rhs[0..rhs_end];
    }
    return null;
}

/// Build TypeContext from file content. Parses struct method signatures,
/// variable type declarations, and top-level function signatures.
/// Also builds stdlib_vars (same as collectStdlibVarNames).
fn parseFileTypeContext(a: Allocator, content: []const u8) !TypeContext {
    var ctx = TypeContext.init();

    const container_inits = compat.getStdlibContainerInitPatterns();
    const allocator_inits = compat.getAllInitPatterns();

    // Track type scope (struct/enum/union) via brace depth
    var current_type: ?[]const u8 = null;
    var type_brace_depth: usize = 0;
    var brace_depth: usize = 0;

    var lines = mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) {
            // Still track braces in comments? No — skip entirely
            continue;
        }

        // Track brace depth
        for (t) |c| {
            if (c == '{') brace_depth += 1;
            if (c == '}') {
                if (brace_depth > 0) brace_depth -= 1;
            }
        }

        // Detect type scope: struct, enum, union — all can have methods in Zig
        if (mem.indexOf(u8, t, "= struct {") != null or
            mem.indexOf(u8, t, "= struct{") != null or
            mem.indexOf(u8, t, "= packed struct {") != null or
            mem.indexOf(u8, t, "= extern struct {") != null or
            mem.indexOf(u8, t, "= enum {") != null or
            mem.indexOf(u8, t, "= enum(") != null or
            mem.indexOf(u8, t, "= union(") != null or
            mem.indexOf(u8, t, "= union {") != null or
            mem.indexOf(u8, t, "= packed union {") != null or
            mem.indexOf(u8, t, "= extern union {") != null)
        {
            if (mem.startsWith(u8, t, "const ") or mem.startsWith(u8, t, "pub const ")) {
                const name_start = if (mem.startsWith(u8, t, "pub const ")) @as(usize, 10) else 6;
                var name_end = name_start;
                while (name_end < t.len and isIdent(t[name_end])) name_end += 1;
                if (name_end > name_start) {
                    current_type = t[name_start..name_end];
                    type_brace_depth = brace_depth;
                }
            }
        }

        // Exit type scope when braces close
        if (current_type != null and brace_depth < type_brace_depth) {
            current_type = null;
        }

        // Parse function/method signatures
        if (mem.indexOf(u8, t, "fn ") != null and mem.indexOf(u8, t, "(") != null) {
            const ret_text = extractFnReturnType(t) orelse continue;
            const rk = classifyReturnType(ret_text);
            const fn_name = extractFnName(t) orelse continue;

            if (current_type) |type_name| {
                // Check if this is a method (has self parameter)
                if (extractSelfTypeName(t) != null) {
                    // Register as type method
                    const gop = try ctx.struct_methods.getOrPut(a, type_name);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .empty;
                    }
                    try gop.value_ptr.put(a, fn_name, rk);
                }
            } else {
                // Top-level function
                try ctx.function_returns.put(a, fn_name, rk);
            }
            // Don't try to also parse as a var decl
            continue;
        }

        // Parse variable declarations for type info
        if (mem.startsWith(u8, t, "var ") or mem.startsWith(u8, t, "const ")) {
            const var_name = extractVarDeclName(t) orelse continue;

            // Check for type name
            if (extractVarTypeName(t)) |type_name| {
                try ctx.var_types.put(a, var_name, type_name);
            }

            // Also build stdlib_vars (same logic as checkStdlibVarLine)
            for (container_inits) |init_pat| {
                if (mem.indexOf(u8, t, init_pat) != null) {
                    try ctx.stdlib_vars.put(a, var_name, {});
                    break;
                }
            } else {
                for (allocator_inits) |init_pat| {
                    if (mem.indexOf(u8, t, init_pat) != null) {
                        try ctx.stdlib_vars.put(a, var_name, {});
                        break;
                    }
                }
            }
        }
    }
    return ctx;
}

/// Line-based variant for function-scoped analysis (memory path).
fn parseFileTypeContextFromLines(a: Allocator, lines: []const []const u8) !TypeContext {
    var ctx = TypeContext.init();

    const container_inits = compat.getStdlibContainerInitPatterns();
    const allocator_inits = compat.getAllInitPatterns();

    for (lines) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;

        // Parse variable declarations
        if (mem.startsWith(u8, t, "var ") or mem.startsWith(u8, t, "const ")) {
            const var_name = extractVarDeclName(t) orelse continue;

            if (extractVarTypeName(t)) |type_name| {
                try ctx.var_types.put(a, var_name, type_name);
            }

            // Build stdlib_vars
            for (container_inits) |init_pat| {
                if (mem.indexOf(u8, t, init_pat) != null) {
                    try ctx.stdlib_vars.put(a, var_name, {});
                    break;
                }
            } else {
                for (allocator_inits) |init_pat| {
                    if (mem.indexOf(u8, t, init_pat) != null) {
                        try ctx.stdlib_vars.put(a, var_name, {});
                        break;
                    }
                }
            }
        }
    }
    return ctx;
}

/// Extract the variable name a method is called on by walking backwards
/// from the dot position. For "list.clear(" with dot_pos pointing at the '.',
/// walks back through identifier chars to find "list".
/// For "self.list.clear(" returns "list" (stops at the previous dot).
fn extractMethodTarget(t: []const u8, dot_pos: usize) ?[]const u8 {
    if (dot_pos == 0) return null;
    const end = dot_pos;
    var start = dot_pos;
    while (start > 0 and isIdent(t[start - 1])) start -= 1;
    if (start >= end) return null;
    return t[start..end];
}

/// Type-aware method pattern matching.
/// - Universal patterns (don't start with '.') always apply: "debug.print", "assert("
/// - Method patterns (start with '.') only match when the receiver variable is a
///   confirmed stdlib type tracked in stdlib_vars.
/// When stdlib_vars is null, falls back to legacy substring matching (current behavior).
fn isMethodOnStdlibVar(
    t: []const u8,
    stdlib_vars: ?*const std.StringHashMapUnmanaged(void),
    patterns: []const []const u8,
) bool {
    const vars = stdlib_vars orelse {
        // Legacy fallback: no type info, use substring matching
        for (patterns) |pat| {
            if (mem.indexOf(u8, t, pat) != null) return true;
        }
        return false;
    };

    for (patterns) |pat| {
        if (!mem.startsWith(u8, pat, ".")) {
            // Universal pattern (debug.print, assert, etc.) — always apply
            if (mem.indexOf(u8, t, pat) != null) return true;
            continue;
        }
        // Method pattern — verify target is a tracked stdlib variable
        const pos = mem.indexOf(u8, t, pat) orelse continue;
        const target = extractMethodTarget(t, pos) orelse continue;
        if (vars.contains(target)) return true;
    }
    return false;
}

/// Check if line uses .allocator().{alloc_method}() chain from a tracked no-free source.
/// Detects patterns like: fba_var.allocator().alloc(...), arena_var.allocator().create(...)
fn isNoFreeCallChain(
    t: []const u8,
    no_free_names: *const std.StringHashMapUnmanaged(void),
) bool {
    return isNoFreeCallChainFull(t, no_free_names, null);
}

/// Check if allocation is through a no-free allocator call chain:
/// X.allocator().method() where X is a tracked no-free variable or field.
fn isNoFreeCallChainFull(
    t: []const u8,
    no_free_names: *const std.StringHashMapUnmanaged(void),
    no_free_fields: ?*const std.StringHashMapUnmanaged(void),
) bool {
    const chain_marker = ".allocator().";
    const pos = mem.indexOf(u8, t, chain_marker) orelse return false;

    // Verify what follows is an allocator method (short names from compat layer)
    const after = t[pos + chain_marker.len ..];
    var is_alloc_method = false;
    for (compat.getAllocMethodShortNames()) |short_name| {
        // Check "methodName(" pattern after the chain marker
        if (after.len > short_name.len and
            mem.startsWith(u8, after, short_name) and
            after[short_name.len] == '(')
        {
            is_alloc_method = true;
            break;
        }
    }
    if (!is_alloc_method) return false;

    // Extract source variable/field name before .allocator()
    var start = pos;
    while (start > 0 and isIdent(t[start - 1])) start -= 1;
    if (start >= pos) return false;
    const source = t[start..pos];

    // Check local variable names (e.g. arena.allocator().alloc())
    if (no_free_names.contains(source)) return true;

    // Check struct field names (e.g. self.arena.allocator().alloc())
    // The source before .allocator() is a field name in a dotted chain
    if (no_free_fields) |fields| {
        if (fields.contains(source)) return true;
    }

    // Name-based heuristic: if the immediate source before .allocator() is named
    // "arena" (or contains "arena"), treat as no-free (cross-file support).
    if (isArenaName(source)) return true;

    return false;
}

/// Zig language construct patterns indicating ownership transfer (not stdlib-specific)
const ownership_lang_patterns = [_][]const u8{
    "break :", // Labeled block break - ownership to block result
    ".* = ", // Out-parameter assignment (C FFI)
    "@ptrCast", // Pointer cast
    "@alignCast", // Alignment cast
    ".ptr", // Slice reassignment
    ".realloc(", // Realloc consumes old pointer
};

/// Check if ownership is transferred via cast, reassignment, or container method
fn isOwnershipTransfer(t: []const u8, alloc_name: []const u8) bool {
    if (mem.indexOf(u8, t, alloc_name) == null) return false;
    // Check Zig language construct patterns
    for (ownership_lang_patterns) |pattern| {
        if (mem.indexOf(u8, t, pattern) == null) continue;
        // ".* = " is only an ownership transfer when alloc_name is on the RHS.
        // When alloc_name is on the LHS (e.g., node.* = .{...}), it's
        // initialization of allocated memory, not a transfer.
        if (mem.eql(u8, pattern, ".* = ")) {
            if (mem.indexOf(u8, t, " = ")) |eq_pos| {
                const rhs = t[eq_pos + 3 ..];
                if (mem.indexOf(u8, rhs, alloc_name) != null) return true;
            }
            continue;
        }
        return true;
    }
    // Check stdlib container methods (compat layer)
    for (compat.getContainerOwnershipMethods()) |pattern| {
        if (mem.indexOf(u8, t, pattern) != null) return true;
    }
    return false;
}

/// Check if allocation is stored in a struct field (ownership transferred to struct)
/// Patterns: self.field = alloc_name, this.field = alloc_name, identifier.field = alloc_name
fn isStructFieldStorage(t: []const u8, alloc_name: []const u8) bool {
    if (mem.indexOf(u8, t, alloc_name) == null) return false;

    // Check for any struct.field = alloc_name (not just self.)
    if (mem.indexOf(u8, t, " = ")) |eq_pos| {
        // LHS must have a dot (struct field access)
        const lhs = mem.trim(u8, t[0..eq_pos], " \t");
        if (mem.indexOf(u8, lhs, ".") == null) return false;

        // Check if alloc_name appears after the =
        if (mem.indexOf(u8, t, alloc_name)) |name_pos| {
            if (name_pos > eq_pos) return true;
        }
    }
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

/// Extract the allocator name from an allocation line
fn extractAllocatorName(t: []const u8) ?[]const u8 {
    // Find first allocation method position using compat layer patterns
    var first_pos: ?usize = null;
    for (compat.getAllocMethodPatterns()) |pat| {
        if (mem.indexOf(u8, t, pat)) |pos| {
            if (first_pos == null or pos < first_pos.?)
                first_pos = pos;
        }
    }

    // Walk backwards to find the allocator name
    const end = first_pos orelse return null;
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

/// Patterns where allocator is the first function argument (not the receiver).
/// Used to extract the allocator name for no-free suppression on stdlib functions
/// like `std.fmt.allocPrint(allocator, ...)` or `list.toOwnedSlice(allocator)`.
const first_arg_alloc_patterns = [_][]const u8{
    ".allocPrint(",
    ".allocPrintSentinel(",
    ".toOwnedSlice(",
    ".toOwnedSliceSentinel(",
    ".cloneWithAllocator(",
    ".readFileAlloc(",
    ".readFileAllocOptions(",
    ".readToEndAlloc(",
    ".readToEndAllocOptions(",
    ".readAllAlloc(",
    ".selfExePathAlloc(",
    ".selfExeDirPathAlloc(",
    ".realpathAlloc(",
    ".replaceOwned(",
    ".concatWithSentinel(",
    ".stringifyAlloc(",
};

/// Extract the allocator name from the first argument of a standalone or
/// method-style allocating function call where the allocator is an argument,
/// not the receiver. Handles patterns like:
///   std.fmt.allocPrint(allocator, ...)
///   list.toOwnedSlice(allocator)
///   std.mem.concat(allocator, u8, ...)
///   mem.join(allocator, ...)
fn extractStandaloneAllocator(t: []const u8) ?[]const u8 {
    // Check qualified patterns (allocator is the first arg for all)
    for (compat.getQualifiedAllocFnPatterns()) |pat| {
        if (mem.indexOf(u8, t, pat)) |pos| {
            return extractFirstArgIdent(t, pos + pat.len);
        }
    }
    // Check method patterns where allocator is the first arg
    for (first_arg_alloc_patterns) |pat| {
        if (mem.indexOf(u8, t, pat)) |pos| {
            return extractFirstArgIdent(t, pos + pat.len);
        }
    }
    return null;
}

/// Extract a simple identifier starting at `start` (first arg before comma/paren).
fn extractFirstArgIdent(t: []const u8, start: usize) ?[]const u8 {
    var s = start;
    while (s < t.len and (t[s] == ' ' or t[s] == '\t')) s += 1;
    if (s >= t.len) return null;
    const ident_start = s;
    while (s < t.len and isIdent(t[s])) s += 1;
    if (s == ident_start) return null;
    return t[ident_start..s];
}

/// Extract the full dotted expression starting at `start` (e.g., `cg.module.arena`).
/// Returns everything up to the first non-ident, non-dot character.
fn extractFirstArgDotted(t: []const u8, start: usize) ?[]const u8 {
    var s = start;
    while (s < t.len and (t[s] == ' ' or t[s] == '\t')) s += 1;
    if (s >= t.len) return null;
    const ident_start = s;
    while (s < t.len and (isIdent(t[s]) or t[s] == '.')) s += 1;
    if (s == ident_start) return null;
    // Don't end with a dot
    if (t[s - 1] == '.') s -= 1;
    if (s == ident_start) return null;
    return t[ident_start..s];
}

/// Check if a dotted first-arg expression contains an arena-named segment.
/// Handles patterns like `std.fmt.allocPrint(cg.module.arena, ...)`
fn isFirstArgArena(t: []const u8) bool {
    // Try all standalone allocator extraction patterns
    var arg_start: ?usize = null;
    for (compat.getQualifiedAllocFnPatterns()) |pat| {
        if (mem.indexOf(u8, t, pat)) |pos| {
            arg_start = pos + pat.len;
            break;
        }
    }
    if (arg_start == null) {
        for (first_arg_alloc_patterns) |pat| {
            if (mem.indexOf(u8, t, pat)) |pos| {
                arg_start = pos + pat.len;
                break;
            }
        }
    }
    const start = arg_start orelse return false;
    const dotted = extractFirstArgDotted(t, start) orelse return false;

    // Check if any segment of the dotted expression is arena-named
    var iter_pos: usize = 0;
    while (iter_pos < dotted.len) {
        const dot = mem.indexOf(u8, dotted[iter_pos..], ".") orelse (dotted.len - iter_pos);
        const segment = dotted[iter_pos .. iter_pos + dot];
        if (segment.len > 0 and isArenaName(segment)) return true;
        iter_pos += dot + 1;
    }
    return false;
}

/// Extract the first argument of a multiline allocating call.
/// When a line ends with an allocating pattern like `allocPrint(` and the first
/// argument is on the next line, extract that identifier from the next line.
/// Handles: `std.fmt.allocPrint(\n    arena,` and similar patterns.
fn extractMultilineFirstArg(t: []const u8, lines: []const []const u8, idx: usize) ?[]const u8 {
    // Check if the line contains an allocating pattern that ends at the line boundary
    // (i.e., extractStandaloneAllocator returned null because the arg is on the next line)
    var has_alloc_pattern = false;
    for (compat.getQualifiedAllocFnPatterns()) |pat| {
        if (mem.indexOf(u8, t, pat) != null) {
            has_alloc_pattern = true;
            break;
        }
    }
    if (!has_alloc_pattern) {
        for (first_arg_alloc_patterns) |pat| {
            if (mem.indexOf(u8, t, pat) != null) {
                has_alloc_pattern = true;
                break;
            }
        }
    }
    if (!has_alloc_pattern) return null;

    // Check that the line ends with an open paren (possibly with trailing whitespace)
    const trimmed = mem.trimEnd(u8, t, " \t\r");
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != '(') return null;

    // Look at the next line for the first argument
    if (idx + 1 >= lines.len) return null;
    const next_line = mem.trim(u8, lines[idx + 1], " \t\r");
    return extractFirstArgIdent(next_line, 0);
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

/// Detect direct field assignment: var.field = try allocator.alloc(...)
/// This handles patterns like ctx.editing_buffer = try self.allocator.alloc(...)
fn isDirectFieldAssignment(t: []const u8, alloc_name: []const u8) bool {
    // Look for pattern: identifier.field = ... alloc_name
    const eq_pos = mem.indexOf(u8, t, " = ") orelse return false;
    const lhs = t[0..eq_pos];
    const rhs = t[eq_pos + 3 ..];

    // LHS should be identifier.field (e.g., ctx.editing_buffer, self.buffer)
    if (mem.indexOf(u8, lhs, ".") == null) return false;

    // RHS should contain an allocation method pattern (skip patterns in strings)
    var has_alloc = false;
    for (compat.getAllocMethodPatterns()) |pat| {
        if (hasPatternNotInString(rhs, pat)) {
            has_alloc = true;
            break;
        }
    }
    if (!has_alloc) {
        for (compat.getQualifiedAllocFnPatterns()) |pat| {
            if (hasPatternNotInString(rhs, pat)) {
                has_alloc = true;
                break;
            }
        }
    }
    if (!has_alloc) return false;

    // Check if lhs field name matches alloc_name (e.g., ctx.editing_buffer with editing_buffer)
    if (mem.indexOf(u8, lhs, alloc_name) != null) return true;

    return false;
}

/// Detect ownership transfer via function call argument
/// Uses general approach: if alloc_name appears as argument to any function call,
/// ownership may have been transferred. This is project-agnostic.
fn isOwnershipTransferCall(t: []const u8, alloc_name: []const u8) bool {
    return isFunctionArgTransfer(t, alloc_name);
}

/// Detect function argument ownership transfer
/// Catches: someFunc(alloc_name, ...) or someFunc(..., alloc_name) or someFunc(alloc_name)
/// Excludes: alloc_name.method() and alloc_name[...] and simple comparisons
/// Walk backward from a position to find the enclosing function call name.
/// Returns true if it's a non-allocation function call (ownership transfer).
/// Allocation function names (from compat layer) don't count as ownership transfer.
fn isNonAllocFnCallAt(t: []const u8, paren_pos: usize) bool {
    if (paren_pos == 0) return false;
    var name_end = paren_pos;
    while (name_end > 0 and t[name_end - 1] == ' ') name_end -= 1;
    if (name_end == 0 or !isIdent(t[name_end - 1])) return false;
    var fname_start = name_end - 1;
    while (fname_start > 0 and isIdent(t[fname_start - 1])) fname_start -= 1;
    const fname = t[fname_start..name_end];
    for (compat.getAllocMethodShortNames()) |afn| {
        if (mem.eql(u8, fname, afn)) return false;
    }
    return true;
}

fn isInsideFunctionCallArg(t: []const u8, pos: usize) bool {
    var depth: usize = 0;
    var i = pos;
    while (i > 0) {
        i -= 1;
        if (t[i] == ')') {
            depth += 1;
        } else if (t[i] == '(') {
            if (depth > 0) {
                depth -= 1;
                continue;
            }
            return isNonAllocFnCallAt(t, i);
        }
    }
    return false;
}

fn isFunctionArgTransfer(t: []const u8, alloc_name: []const u8) bool {
    var search_start: usize = 0;
    while (mem.indexOf(u8, t[search_start..], alloc_name)) |rel_pos| {
        const pos = search_start + rel_pos;
        search_start = pos + alloc_name.len;
        if (pos > 0 and isIdent(t[pos - 1])) continue;
        if (pos + alloc_name.len < t.len and isIdent(t[pos + alloc_name.len])) continue;
        if (isInsideFunctionCallArg(t, pos)) return true;
    }
    return false;
}

/// Detect module-level variable assignment (singleton/global pattern)
/// Pattern: identifier = alloc_name (no const/var keyword, not field assignment)
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

    // Skip field assignments (any identifier.field pattern — ownership transfer, not module-level)
    if (mem.indexOf(u8, lhs, ".") != null) return false;

    // LHS is a simple identifier = module-level variable assignment
    // Ensure alloc_name appears on RHS
    const rhs = t[eq_pos + 3 ..];
    return mem.indexOf(u8, rhs, alloc_name) != null;
}

/// Detect direct module-level allocation (not a local var, not a field)
/// Pattern: identifier = try allocator.alloc/create(...) where identifier is module-level
fn isDirectModuleLevelAlloc(t: []const u8) bool {
    // Must have an assignment
    const eq_pos = mem.indexOf(u8, t, " = ") orelse return false;

    // Must not be a const/var declaration (those are local)
    if (mem.startsWith(u8, t, "const ") or mem.startsWith(u8, t, "var ")) return false;

    // Extract lhs (the assigned-to variable)
    const lhs = mem.trim(u8, t[0..eq_pos], " \t");
    if (lhs.len == 0) return false;

    // Skip any field assignment (identifier.field — ownership transfer, not module-level)
    if (mem.indexOf(u8, lhs, ".") != null) return false;

    // LHS must be a valid identifier (letters, numbers, underscores)
    for (lhs) |c| {
        if (!isIdent(c)) return false;
    }

    // RHS must contain an allocation method pattern (skip patterns in strings)
    const rhs = t[eq_pos + 3 ..];
    for (compat.getAllocMethodPatterns()) |pat| {
        if (hasPatternNotInString(rhs, pat)) return true;
    }
    for (compat.getQualifiedAllocFnPatterns()) |pat| {
        if (hasPatternNotInString(rhs, pat)) return true;
    }
    return false;
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
fn isSafeToDiscard(t: []const u8, type_ctx: ?*const TypeContext) bool {
    // Stdlib cleanup patterns (void methods: .free, .destroy, .deinit) — always safe
    for (compat.getCleanupPatterns()) |pat| {
        if (mem.indexOf(u8, t, pat) != null) return true;
    }
    // Return-type resolution (definitive when available)
    if (type_ctx) |ctx| {
        const rk = resolveReturnKind(ctx, t);
        switch (rk) {
            .void_type, .value, .optional, .noreturn_type => return true,
            .error_union => return false,
            .unknown => {}, // fall through to vocab
        }
    }
    // Stdlib safe methods — type-aware: method patterns (.clear, .next, etc.)
    // only match when receiver is a tracked stdlib variable
    const stdlib_vars_ptr = if (type_ctx) |ctx| &ctx.stdlib_vars else null;
    if (isMethodOnStdlibVar(t, stdlib_vars_ptr, compat.getSafeMethodPatterns())) return true;
    // Non-stdlib patterns (parser internals, C FFI)
    const non_stdlib_safe = [_][]const u8{
        ".parseEscapeSequence(", // Parser returning parsed value
        "A(", // C FFI / Windows API (uppercase)
    };
    for (non_stdlib_safe) |pattern| {
        if (mem.indexOf(u8, t, pattern) != null) return true;
    }
    // C FFI: _ = ExternalFunction(...) - uppercase function name after _ =
    if (t.len > 4) {
        const after_discard = t[4..]; // Skip "_ = "
        if (after_discard.len > 0 and after_discard[0] >= 'A' and after_discard[0] <= 'Z') {
            // Starts with uppercase - likely C FFI or extern function
            return true;
        }
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
    if (!in_block) return .{ .in_test = false, .depth = brace_depth };
    for (t) |c| {
        if (c == '{') brace_depth += 1;
        if (c == '}') {
            if (brace_depth > 0) brace_depth -= 1;
            if (brace_depth == 0) in_block = false;
        }
    }
    return .{ .in_test = in_block, .depth = brace_depth };
}

/// Check for silent catch patterns (ZA201)
/// Skip note in defer/errdefer contexts (best-effort cleanup)
fn checkSilentCatch(
    t: []const u8,
    path: []const u8,
    line: usize,
    func_name: []const u8,
    preceding_lines: ?[]const []const u8,
) ?Issue {
    if (mem.startsWith(u8, t, "defer ") or
        mem.startsWith(u8, t, "errdefer ")) return null;
    // Suppress in cleanup/shutdown functions — catch {} is intentional best-effort
    if (isCleanupFunction(func_name)) return null;
    // Suppress when the called method is a cleanup/best-effort operation
    if (isCleanupMethodCall(t)) return null;
    // Suppress explicit discard: `_ = expr catch {}` — caller intentionally ignores both value and error
    if (isDiscardedCatch(t)) return null;
    // Suppress catch {} on continuation lines of multi-line defer expressions
    if (isDeferCatchMultiline(t, preceding_lines)) return null;
    // Suppress writer/stream catch {} — uses paren-balanced lookback for multi-line
    if (isStreamWriteCatchMultiline(t, preceding_lines)) return null;
    const found = findSilentCatchCol(t) orelse return null;
    return .{
        .file = path,
        .line = line,
        .col = found.col + 1,
        .severity = .note,
        .rule = RULE_SILENT_CATCH,
        .message = found.msg,
        .help = "use catch |err| with logging, or propagate with try",
    };
}

/// Check if function name indicates a cleanup/shutdown context where catch {} is expected.
fn isCleanupFunction(name: []const u8) bool {
    if (name.len == 0) return false;
    const cleanup_names = [_][]const u8{
        "deinit", "cleanup", "shutdown", "close", "destroy", "teardown",
    };
    for (cleanup_names) |cn| {
        if (mem.eql(u8, name, cn)) return true;
    }
    // Also match names containing these substrings (e.g., "shutdownLeader", "cleanupResources")
    const cleanup_substrings = [_][]const u8{
        "deinit", "cleanup", "shutdown",
    };
    for (cleanup_substrings) |sub| {
        if (mem.indexOf(u8, name, sub) != null) return true;
    }
    return false;
}

/// Check if the called method on the line is a cleanup/best-effort operation.
/// Matches `.leaseRevoke(`, `.close(`, `.cleanup(`, `.shutdown(`, etc.
/// Case-insensitive substring match (camelCase: `leaseRevoke` matches "revoke").
fn isCleanupMethodCall(t: []const u8) bool {
    const cleanup_keywords = [_][]const u8{
        "revoke",  "close",   "cleanup",  "shutdown",   "deinit",
        "release", "destroy", "teardown", "disconnect",
    };
    // Find method calls: look for .methodName( patterns
    var pos: usize = 0;
    while (mem.indexOfScalarPos(u8, t, pos, '.')) |dot| {
        pos = dot + 1;
        if (pos >= t.len) break;
        // Extract method name after the dot
        var end = pos;
        while (end < t.len and isIdent(t[end])) end += 1;
        if (end == pos) continue;
        if (end >= t.len or t[end] != '(') continue;
        const method = t[pos..end];
        // Check if method name contains any cleanup keyword (case-insensitive)
        if (containsCleanupKeyword(method, &cleanup_keywords)) {
            if (!isInsideString(t, dot)) return true;
        }
    }
    return false;
}

/// Case-insensitive substring check: does `name` contain any of the keywords?
/// Handles camelCase (e.g., "leaseRevoke" contains "revoke" via "Revoke").
fn containsCleanupKeyword(name: []const u8, keywords: []const []const u8) bool {
    // Convert to lowercase buffer for comparison
    var lower_buf: [128]u8 = undefined;
    if (name.len > lower_buf.len) return false;
    for (name, 0..) |c, i| {
        lower_buf[i] = std.ascii.toLower(c);
    }
    const lower = lower_buf[0..name.len];
    for (keywords) |kw| {
        if (mem.indexOf(u8, lower, kw) != null) return true;
    }
    return false;
}

fn findSilentCatchCol(t: []const u8) ?struct { col: usize, msg: []const u8 } {
    if (mem.indexOf(u8, t, "catch {}")) |col| {
        if (!isInsideString(t, col) and !isInsideWhileCondition(t, col))
            return .{ .col = col, .msg = "silent catch {} discards error" };
    } else if (mem.indexOf(u8, t, "catch |_| {}")) |col| {
        if (!isInsideString(t, col) and !isInsideWhileCondition(t, col))
            return .{ .col = col, .msg = "silent catch |_| {} discards error" };
    }
    return null;
}

/// Check if `catch {}` at `pos` is inside a while/if/for condition (paren-balanced).
/// Suppresses ZA201 for patterns like `while (iter.next() catch {}) |val|`
/// where catch converts error union to optional for the while loop.
fn isInsideWhileCondition(t: []const u8, pos: usize) bool {
    // Must have a control-flow keyword before the catch
    const has_while = mem.indexOf(u8, t, "while (") != null;
    const has_if = mem.indexOf(u8, t, "if (") != null;
    const has_for = mem.indexOf(u8, t, "for (") != null;
    if (!has_while and !has_if and !has_for) return false;

    // Count paren depth at the catch position — if depth > 0, catch is inside condition parens
    var depth: isize = 0;
    for (t[0..pos]) |c| {
        if (c == '(') depth += 1;
        if (c == ')') depth -= 1;
    }
    return depth > 0;
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
    // Stdlib container mutation methods from compat vocab
    const modifying_methods = compat.getModifyingMethodPatterns();
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
fn isUndefinedContinuation(t: []const u8, col: usize) bool {
    const after = col + "= undefined".len;
    if (after >= t.len) return false;
    return isIdent(t[after]);
}

fn isInTrailingComment(t: []const u8, col: usize) bool {
    const comment_start = mem.indexOf(u8, t, "//") orelse return false;
    return col > comment_start and !isInsideString(t, comment_start);
}

fn checkUndefinedUsage(
    t: []const u8,
    path: []const u8,
    line: usize,
    pending: *?PendingUndefined,
) ?Issue {
    if (pending.* != null)
        return handlePendingUndefined(t, path, line, pending);
    const col = mem.indexOf(u8, t, "= undefined") orelse return null;
    if (isUndefinedContinuation(t, col)) return null;
    if (isInsideString(t, col)) return null;
    if (isInTrailingComment(t, col)) return null;
    if (isStructFieldPattern(t, col)) return null;
    if (isCleanupUndefinedPattern(t, col)) return null;
    if (extractVarDeclName(t)) |name| {
        pending.* = .{ .name = name, .line = line, .col = col + 1 };
        return null;
    }
    if (isStructFieldDefault(t, col)) return null;
    return makeUndefinedIssue(path, line, col + 1);
}

/// Detect struct type field defaults: `field_name: Type = undefined`
/// Not a variable declaration - no `var`/`const` prefix.
/// Has pattern: `identifier: type_expr = undefined`
fn isStructFieldDefault(t: []const u8, undefined_col: usize) bool {
    // Must not start with var/const (those are variable declarations)
    if (mem.startsWith(u8, t, "var ") or mem.startsWith(u8, t, "const ")) return false;
    // Look for a colon between start and the `= undefined`
    // Pattern: `identifier: type = undefined`
    if (undefined_col == 0) return false;
    var i: usize = 0;
    while (i < undefined_col) : (i += 1) {
        if (t[i] == ':') {
            // Verify identifier before colon
            if (i > 0 and (isIdent(t[i - 1]) or t[i - 1] == '@' or t[i - 1] == '"')) {
                return true;
            }
        }
    }
    return false;
}

/// Check for discarded error union results
fn checkDiscardedResult(
    t: []const u8,
    path: []const u8,
    line: usize,
    type_ctx: ?*const TypeContext,
) ?Issue {
    const starts_discard = mem.startsWith(u8, t, "_ = ");
    const has_call = mem.indexOf(u8, t, "()") != null;
    if (!starts_discard or !has_call) return null;
    if (compat.containsOptionalMethod(t)) return null;
    if (isSafeToDiscard(t, type_ctx)) return null;
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
        .rule = RULE_IGNORED_ERROR,
        .message = "function result discarded with '_ ='",
        .help = "if error union, use try/catch; if intentional discard, this can be ignored",
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
    // Track if current function has any defer statements (for ZA206)
    has_defer_in_func: bool = false,
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

/// Track brace depth for a block, returning updated in_block and depth.
/// Used by defer, catch, and function tracking.
const BraceTrackResult = struct { in_block: bool, depth: usize };

fn trackBraceBlock(t: []const u8, in_block: bool, depth: usize) BraceTrackResult {
    var d = depth;
    var active = in_block;
    for (t) |c| {
        if (c == '{') d += 1;
        if (c == '}' and d > 0) {
            d -= 1;
            if (d == 0) active = false;
        }
    }
    return .{ .in_block = active, .depth = d };
}

/// Start tracking a new block (reset depth, count braces on opening line)
fn startBraceBlock(t: []const u8) BraceTrackResult {
    return trackBraceBlock(t, true, 0);
}

/// Track defer/errdefer blocks for silent catch exclusion
fn trackDeferBlock(t: []const u8, state: *ErrorAnalysisState) void {
    if (mem.startsWith(u8, t, "defer ") or mem.startsWith(u8, t, "errdefer ")) {
        state.has_defer_in_func = true;
        if (mem.indexOf(u8, t, "{") != null) {
            const r = startBraceBlock(t);
            state.in_defer_block = r.in_block;
            state.defer_brace_depth = r.depth;
        }
        return;
    }
    if (state.in_defer_block) {
        const r = trackBraceBlock(t, true, state.defer_brace_depth);
        state.in_defer_block = r.in_block;
        state.defer_brace_depth = r.depth;
    }
}

/// Detect if line starts a catch block (not a silent catch {})
fn isCatchBlockStart(t: []const u8) bool {
    if (mem.indexOf(u8, t, "catch |") != null) return true;
    return mem.indexOf(u8, t, "} catch {") != null and mem.indexOf(u8, t, "catch {}") == null;
}

/// Track catch blocks for error recovery context detection
fn trackCatchBlock(t: []const u8, state: *ErrorAnalysisState) void {
    if (isCatchBlockStart(t)) {
        if (mem.indexOf(u8, t, "{") != null) {
            const r = startBraceBlock(t);
            state.in_catch_block = r.in_block;
            state.catch_brace_depth = r.depth;
        }
        return;
    }
    if (state.in_catch_block) {
        const r = trackBraceBlock(t, true, state.catch_brace_depth);
        state.in_catch_block = r.in_block;
        state.catch_brace_depth = r.depth;
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
    if (extractFuncName(t)) |name| {
        state.current_func_name = name;
        state.func_brace_depth = 0;
        state.has_defer_in_func = false;
        for (t) |c| {
            if (c == '{') state.func_brace_depth += 1;
        }
        return;
    }
    if (state.current_func_name.len == 0) return;
    const r = trackBraceBlock(t, true, state.func_brace_depth);
    state.func_brace_depth = r.depth;
    if (!r.in_block) state.current_func_name = "";
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
        mem.indexOf(u8, path, "/tests/") != null;
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
    in_test: bool,
    pending: *?PendingUndefined,
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    type_ctx: ?*const TypeContext,
    func_name: []const u8,
    preceding_lines: ?[]const []const u8,
) !void {
    // ZA201 (silent catch) - only from line-based analyzer
    if (!in_defer) {
        if (checkSilentCatch(t, path, ln, func_name, preceding_lines)) |i| {
            try issues.append(allocator, i);
        }
    }
    // ZA202: catch unreachable — suppress in test blocks (intentional assertions)
    if (!in_test) {
        if (checkCatchUnreachable(t, path, ln, preceding_lines)) |i| {
            try issues.append(allocator, i);
        }
    }
    // ZA203: orelse unreachable — suppress in test blocks (intentional assertions)
    if (!in_test) {
        if (checkLineOrelseUnreachable(t, path, ln)) |i| {
            try issues.append(allocator, i);
        }
    }
    // ZA207: catch undefined (dangerous — converts errors to UB)
    if (checkCatchUndefined(t, path, ln)) |i| {
        try issues.append(allocator, i);
    }
    // Always resolve pending undefineds (even at module boundary) to avoid
    // losing ZA204 issues when skip_undefined transitions from false→true.
    // handlePendingUndefined checks fill patterns and scope boundaries.
    if (pending.* != null) {
        if (handlePendingUndefined(t, path, ln, pending)) |i| {
            try issues.append(allocator, i);
        }
    }
    // Only track NEW undefineds when not in test/module-level context
    // and when no pending is active (handlePendingUndefined already ran above)
    if (!skip_undefined and pending.* == null) {
        // checkUndefinedUsage: only detects new "= undefined" when pending is null
        if (checkUndefinedUsage(t, path, ln, pending)) |i| {
            try issues.append(allocator, i);
        }
    }
    if (checkDiscardedResult(t, path, ln, type_ctx)) |i| try issues.append(allocator, i);
    // ZA208: @panic() detection — suppress in test blocks and test files
    if (!in_test and !isTestFilePath(path)) {
        if (checkPanic(t, path, ln)) |i| {
            try issues.append(allocator, i);
        }
    }
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
        if (state.pending_undefined) |pending|
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
    const fields = state.pending_struct_fields[0..state.pending_field_count];
    for (fields) |pf| {
        try reportUnfilledField(issues, allocator, path, &pf);
    }
}

/// ZA206: Check for std.process.exit() bypassing defers
fn checkExitBypassesDefer(
    t: []const u8,
    _: []const u8,
    path: []const u8,
    line_num: usize,
    has_defer: bool,
    func_name: []const u8,
) ?Issue {
    if (!has_defer or func_name.len == 0) return null;
    const has_exit = mem.indexOf(u8, t, "std.process.exit(") != null or
        mem.indexOf(u8, t, "process.exit(") != null or
        mem.indexOf(u8, t, "std.posix.exit(") != null or
        mem.indexOf(u8, t, "posix.exit(") != null;
    if (!has_exit) return null;

    const exit_pos = mem.indexOf(u8, t, "exit(") orelse 0;
    if (isInsideString(t, exit_pos)) return null;

    return .{
        .file = path,
        .line = line_num,
        .col = exit_pos + 1,
        .severity = .warning,
        .rule = RULE_EXIT_BYPASSES_DEFER,
        .message = "exit() bypasses all defers in current scope",
        .help = "set a flag and exit at end of function, or " ++
            "return error to let defers run",
    };
}

/// Update error analysis state for a single line (tracking only)
fn updateErrorState(
    t: []const u8,
    line: []const u8,
    state: *ErrorAnalysisState,
    path: []const u8,
) struct { skip_undefined: bool } {
    const ts = trackTestBlock(t, state.in_test_block, state.test_brace_depth);
    state.in_test_block = ts.in_test;
    state.test_brace_depth = ts.depth;
    const in_test = isInTestContext(path, state.in_test_block);

    if (isStaticStorageStruct(t)) {
        state.in_static_struct = true;
        state.static_struct_depth = 0;
    }
    if (state.in_static_struct) trackStaticStructBraces(t, state);

    const skip = in_test or isTestFilePath(path) or
        isModuleLevelDecl(line) or state.in_static_struct;

    trackFunctionContext(t, state);
    trackDeferBlock(t, state);
    return .{ .skip_undefined = skip };
}

/// Analyze a single file for error issues
fn analyzeFileErrors(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    a: FileAnalysis,
) !void {
    // Build type-aware context for this file (struct methods, var types, stdlib vars)
    var type_ctx = try parseFileTypeContext(allocator, a.content);
    defer type_ctx.deinit(allocator);

    // Collect all lines for preceding-line lookback (ZA202 multi-line suppression)
    var all_lines_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer all_lines_list.deinit(allocator);
    var line_iter = mem.splitScalar(u8, a.content, '\n');
    while (line_iter.next()) |l| {
        try all_lines_list.append(allocator, l);
    }
    const all_lines = all_lines_list.items;

    var state = ErrorAnalysisState{};

    for (all_lines, 0..) |line, line_idx| {
        const line_num = line_idx + 1;
        const t = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(t)) continue;

        const s = updateErrorState(t, line, &state, a.path);

        if (!s.skip_undefined) {
            trackStructLiteral(t, line_num, &state);
            activatePendingFields(&state);
            try checkPendingFields(t, a.path, &state, issues, allocator);
        }
        const preceding: ?[]const []const u8 = if (line_idx > 0) all_lines[0..line_idx] else null;
        const in_test = isInTestContext(a.path, state.in_test_block);
        try checkLineErrors(
            t,
            a.path,
            line_num,
            s.skip_undefined,
            state.in_defer_block,
            in_test,
            &state.pending_undefined,
            issues,
            allocator,
            &type_ctx,
            state.current_func_name,
            preceding,
        );

        if (checkExitBypassesDefer(
            t,
            a.content,
            a.path,
            line_num,
            state.has_defer_in_func,
            state.current_func_name,
        )) |issue| {
            try issues.append(allocator, issue);
        }
    }
    try reportEndOfFileIssues(&state, a.path, issues, allocator);
}

fn analyzeErrors(
    allocator: Allocator,
    graph: *ImportGraph,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
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
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    var iter = graph.files.iterator();
    while (iter.next()) |entry| {
        const a = entry.value_ptr.*;
        // Skip auto-generated C import/translation files (many false positives)
        if (isCImportFile(a.path, a.content)) continue;
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
    is_data_dispatch: bool = false,
    cyclomatic: usize = 1,
    cognitive: usize = 0,
    cog_nest: usize = 0,
    cog_markers: u32 = 0,
};

/// Count function parameters by counting colons at depth 1.
/// Excludes `self` parameter — it's implicit in method call syntax and not
/// a semantic parameter chosen by the caller.
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
    // Subtract self parameter if present — `fn foo(self: *T, ...)` counts self as 1
    if (hasSelfParam(t, p)) {
        if (params > 0) params -= 1;
    }
    return params;
}

/// Check if function signature has a `self` parameter (first param after open paren).
fn hasSelfParam(t: []const u8, paren_pos: usize) bool {
    if (paren_pos + 1 >= t.len) return false;
    const after = mem.trim(u8, t[paren_pos + 1 ..], " \t");
    return mem.startsWith(u8, after, "self:") or
        mem.startsWith(u8, after, "self,") or
        mem.startsWith(u8, after, "self)");
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

/// Count cyclomatic complexity decision points per line (McCabe).
/// CCN = sum of all decision points in a function + 1 (entry point).
fn countLineCyclomatic(t: []const u8) usize {
    var c: usize = 0;
    // else if counts as 1 (not if+else separately)
    if (mem.indexOf(u8, t, "else if") != null) {
        c += 1;
    } else {
        if (mem.indexOf(u8, t, "if ") != null) c += 1;
        // standalone else (not else if, not else =>, not part of orelse)
        if (mem.indexOf(u8, t, "else ") != null and
            mem.indexOf(u8, t, "else =>") == null and
            mem.indexOf(u8, t, "orelse") == null) c += 1;
    }
    if (hasNonInline(t, "while ", "inline while")) c += 1;
    if (hasNonInline(t, "for ", "inline for")) c += 1;
    if (mem.indexOf(u8, t, "switch ") != null) c += 1;
    if (mem.indexOf(u8, t, " catch ") != null) c += 1;
    if (mem.indexOf(u8, t, "try ") != null) c += 1;
    if (mem.indexOf(u8, t, "orelse") != null) c += 1;
    if (mem.indexOf(u8, t, " and ") != null) c += 1;
    if (mem.indexOf(u8, t, " or ") != null) c += 1;
    return c;
}

/// Count cognitive complexity cost for a line based on current nesting level.
fn countLineCognitive(t: []const u8, cog_nest: usize) usize {
    var cost: usize = 0;
    // else if counts as 1, not as both if and else if
    if (mem.indexOf(u8, t, "else if") != null) {
        cost += 1 + cog_nest;
    } else {
        if (mem.indexOf(u8, t, "if ") != null) cost += 1 + cog_nest;
    }
    if (hasNonInline(t, "while ", "inline while")) cost += 1 + cog_nest;
    if (hasNonInline(t, "for ", "inline for")) cost += 1 + cog_nest;
    if (mem.indexOf(u8, t, "switch ") != null) cost += 1 + cog_nest;
    if (mem.indexOf(u8, t, " catch ") != null) cost += 1 + cog_nest;
    if (mem.indexOf(u8, t, "try ") != null) cost += 1 + cog_nest;
    // else (not else if, not else =>, and not a substring of orelse)
    if (mem.indexOf(u8, t, "else ") != null and
        mem.indexOf(u8, t, "else if") == null and
        mem.indexOf(u8, t, "else =>") == null and
        mem.indexOf(u8, t, "orelse") == null)
    {
        cost += 1 + cog_nest;
    }
    // Secondary — no nesting impact
    if (mem.indexOf(u8, t, "orelse") != null) cost += 1;
    if (mem.indexOf(u8, t, " and ") != null) cost += 1;
    if (mem.indexOf(u8, t, " or ") != null) cost += 1;
    return cost;
}

/// Check if line opens a cognitive-nesting-increasing scope (has control keyword + {)
fn opensCognitiveScope(t: []const u8) bool {
    if (mem.indexOf(u8, t, "{") == null) return false;
    return mem.indexOf(u8, t, "if ") != null or
        mem.indexOf(u8, t, "switch ") != null or
        mem.indexOf(u8, t, "while ") != null or
        mem.indexOf(u8, t, "for ") != null or
        mem.indexOf(u8, t, " catch ") != null or
        mem.indexOf(u8, t, "try ") != null;
}

/// Calculate limit with type factory multiplier
fn calcLimit(base: usize, is_factory: bool, mult: usize) usize {
    return if (is_factory) base * mult else base;
}

/// Calculate branch limit with type factory (3x) and data dispatch (8x) multipliers.
/// Data dispatch functions (JSON deserialization, config loading) naturally have
/// one branch per field — this is inherent, not a complexity smell.
fn branchLimit(base: usize, is_type_factory: bool, is_data_dispatch: bool) usize {
    if (is_type_factory) return base * 3;
    if (is_data_dispatch) return base * 8;
    return base;
}

/// Check if function name indicates a data-dispatch pattern where high branch counts
/// are inherent (JSON deserialization, env var mapping, config loading).
/// These functions have 1 branch per field/variable — linear, not complex.
fn isDataDispatchFunction(name: []const u8) bool {
    if (name.len == 0) return false;
    // Exact matches
    const dispatch_names = [_][]const u8{
        "fromJson",   "fromJsonObject", "parseJson",    "deserialize",
        "toJson",     "serialize",      "applyEnvVar",  "parseEnv",
        "loadConfig", "parseConfig",    "handleConfig",
    };
    for (dispatch_names) |dn| {
        if (mem.eql(u8, name, dn)) return true;
    }
    // Prefix matches — parse*, apply*, decode*, encode*
    const dispatch_prefixes = [_][]const u8{
        "parse", "apply", "decode", "encode",
    };
    for (dispatch_prefixes) |prefix| {
        if (mem.startsWith(u8, name, prefix) and name.len > prefix.len) return true;
    }
    // Substring matches for common patterns
    const dispatch_substrings = [_][]const u8{
        "fromJson",    "FromJson",    "parseJson", "ParseJson",
        "deserialize", "Deserialize", "serialize", "Serialize",
    };
    for (dispatch_substrings) |sub| {
        if (mem.indexOf(u8, name, sub) != null) return true;
    }
    return false;
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
    const suffix: []const u8 = if (state.is_type_factory) " [tf]" else if (state.is_data_dispatch) " [dd]" else "";
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
) [6]ComplexityCheck {
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
            .limit = branchLimit(th.max_branches, is_tf, state.is_data_dispatch),
            .metric = "branches",
            .help = "simplify logic",
        },
        .{
            .rule = RULE_CYCLOMATIC,
            .actual = state.cyclomatic,
            .limit = th.max_cyclomatic,
            .metric = "cyclomatic complexity",
            .help = "reduce decision points",
        },
        .{
            .rule = RULE_COGNITIVE,
            .actual = state.cognitive,
            .limit = th.max_cognitive,
            .metric = "cognitive complexity",
            .help = "flatten or extract nested logic",
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

    var end = pos + 3;
    while (end < t.len and isIdent(t[end])) end += 1;
    const name = t[pos + 3 .. end];
    state.* = .{
        .in_fn = true,
        .fn_start = line_num,
        .fn_col = pos + 1,
        .is_type_factory = isTypeFactory(t),
        .is_data_dispatch = isDataDispatchFunction(name),
        .params = countFnParams(t),
        .fn_name = name,
        .cyclomatic = 1,
    };
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
        const pos = lit.updateForChar(t, i) orelse {
            // Skip char literal content
            if (lit.in_chr and i + 1 < t.len) i += 1;
            continue;
        };
        if (updateBraceState(t[pos], is_switch, &first, state))
            return true;
    }
    return false;
}

fn updateBraceState(
    c: u8,
    is_switch: bool,
    first: *bool,
    state: *ComplexityState,
) bool {
    if (c == '{' and !(is_switch and first.*)) {
        state.nest += 1;
        if (state.nest > state.max_nest) state.max_nest = state.nest;
        first.* = false;
    }
    if (c == '}' and state.nest > 0) {
        state.nest -= 1;
        if (state.nest == 0) return true;
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
        state.cyclomatic += countLineCyclomatic(t);
        state.cognitive += countLineCognitive(t, state.cog_nest);

        // Track cognitive nesting: control structures open new scopes
        const cog_before = state.cog_nest;
        if (opensCognitiveScope(t)) {
            state.cog_nest += 1;
            if (state.nest < 32) state.cog_markers |= @as(u32, 1) << @intCast(state.nest);
        }
        if (!trackBraceNesting(t, &state)) continue;

        // Function ended — check if we need to unwind cognitive nesting
        while (state.cog_nest > 0) state.cog_nest -= 1;
        _ = cog_before;

        try reportComplexityIssues(issues, allocator, a.path, &state, th);
        state = .{
            .cyclomatic = 1,
        };
    }
}

fn analyzeComplexity(
    allocator: Allocator,
    graph: *ImportGraph,
    th: Thresholds,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
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
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    var iter = graph.files.iterator();

    while (iter.next()) |entry| {
        const a = entry.value_ptr.*;

        // ZA702: File too long (off by default, enable with --enable=ZA702)
        if (a.content.len > th.max_file_bytes)
            try reportFileTooLong(
                &issues,
                allocator,
                a.path,
                a.content.len,
                th.max_file_bytes,
            );

        // ZA701: Line too long
        var line_num: usize = 1;
        var lines = mem.splitScalar(u8, a.content, '\n');
        while (lines.next()) |line| {
            defer line_num += 1;
            const trimmed = mem.trimStart(u8, line, " \t");
            if (mem.startsWith(u8, trimmed, "\\\\")) continue;

            const visible_len = calculateVisibleLength(line);
            if (visible_len <= th.max_line_length) continue;
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
    content: []const u8,
    t_start: usize,
) !void {
    const plen: usize = if (mem.startsWith(u8, t, "pub const ")) 10 else 6;
    var end = plen;
    while (end < t.len and isIdent(t[end])) end += 1;
    if (end <= plen) return;
    const name = t[plen..end];
    if (name.len > 0 and name[0] == '_') return;

    // Cheap line-only classification first. The multi-line closure check is
    // expensive (byte-scans the full type body), so only run it on lines that
    // look like type defs AND would actually be reported for naming.
    if (isTypeDefinitionLine(t)) {
        if (isTitleCase(name)) return;
        // Non-TitleCase name on a type-looking line — check if it's actually a
        // closure-wrapping function alias (`const x = struct { fn ... }.call;`).
        if (isClosureFunctionAlias(t, content, t_start)) {
            if (!isCamelCase(name))
                try reportNamingIssue(issues, allocator, .{
                    .path = path,
                    .line = line_num,
                    .col = plen + 1,
                    .kind = "function",
                    .name = name,
                    .expected = "camelCase",
                });
            return;
        }
        try reportNamingIssue(issues, allocator, .{
            .path = path,
            .line = line_num,
            .col = plen + 1,
            .kind = "type",
            .name = name,
            .expected = "TitleCase",
        });
        return;
    }
    if (!isValidConstName(t, name))
        try reportNamingIssue(issues, allocator, .{
            .path = path,
            .line = line_num,
            .col = plen + 1,
            .kind = "constant",
            .name = name,
            .expected = "snake_case",
        });
}

/// Detect if a var declaration holds a function pointer (callable).
/// Matches: explicit fn-pointer type annotation or qualified name assignment
/// (`mod.funcName`). Style guide: "If x is callable, then x should be camelCase."
fn isFunctionPointerVar(t: []const u8) bool {
    // Explicit function pointer type annotations.
    // Modern Zig (0.10+) requires `*const fn(...)`; bare `fn(...)` is kept for
    // legacy/type-expression forms.
    const fn_type_patterns = [_][]const u8{
        ": *const fn(",  ": *const fn (",
        ": ?*const fn(", ": ?*const fn (",
        ": *fn(",        ": *fn (",
        ": ?*fn(",       ": ?*fn (",
        ": fn(",         ": fn (",
        ":*const fn(",   ":*const fn (",
        ":?*const fn(",  ":?*const fn (",
        ":*fn(",         ":*fn (",
        ":?*fn(",        ":?*fn (",
        ":fn(",          ":fn (",
    };
    for (fn_type_patterns) |p| {
        if (mem.indexOf(u8, t, p) != null) return true;
    }
    // Qualified function assignment: `var x = mod.someFn;`
    // Require the RHS to be a pure qualified identifier path ending in a
    // camelCase segment. This rejects method calls (`.init(x)`), enum/struct
    // literals (`.empty`, `.{...}`), and instance type exprs
    // (`std.Foo(T).bar`). Bare identifiers (no dot) remain ambiguous.
    const eq_pos = mem.indexOf(u8, t, "= ") orelse return false;
    const rhs = mem.trim(u8, t[eq_pos + 2 ..], " \t;");
    if (rhs.len == 0) return false;
    if (rhs[0] == '.') return false;
    const last_dot = mem.lastIndexOfScalar(u8, rhs, '.') orelse return false;
    const last_seg = rhs[last_dot + 1 ..];
    if (last_seg.len == 0) return false;
    for (last_seg) |c| if (!isIdent(c)) return false;
    const lhs = rhs[0..last_dot];
    for (lhs) |c| if (!isIdent(c) and c != '.') return false;
    return isCamelCase(last_seg);
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
    // Function pointer vars use camelCase per style guide
    if (isFunctionPointerVar(t)) {
        if (!isCamelCase(name)) {
            try reportNamingIssue(issues, allocator, .{
                .path = path,
                .line = line_num,
                .col = prefix + 1,
                .kind = "function pointer",
                .name = name,
                .expected = "camelCase",
            });
        }
        return;
    }
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

/// Check if a function's return type is literally `type` (or `!type`).
/// Uses paren balancing to find the closing `)` of the param list,
/// then checks the return type token that follows.
fn fnReturnsType(t: []const u8, after_name: usize) bool {
    // Find opening paren of param list
    var i = after_name;
    while (i < t.len and t[i] != '(') : (i += 1) {}
    if (i >= t.len) return false;

    // Balance parens to find matching close
    var depth: usize = 1;
    i += 1;
    while (i < t.len and depth > 0) : (i += 1) {
        if (t[i] == '(') depth += 1;
        if (t[i] == ')') depth -= 1;
    }
    if (depth != 0) return false;

    // i is now just past the closing ')'
    // Skip whitespace
    while (i < t.len and (t[i] == ' ' or t[i] == '\t')) : (i += 1) {}

    // Skip optional '!' for error union return types
    if (i < t.len and t[i] == '!') i += 1;

    // Check if return type is literally "type" as a standalone word
    if (i + 4 <= t.len and mem.eql(u8, t[i .. i + 4], "type")) {
        // Ensure it's not a prefix of a longer identifier
        if (i + 4 >= t.len or !isIdent(t[i + 4])) return true;
    }
    return false;
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
    const returns_type = fnReturnsType(t, end);
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

/// Check error value (`error.MyError`) and error set member naming.
/// Error values are not types; the style guide says "Otherwise, x should be snake_case."
fn checkErrorNaming(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    t: []const u8,
    line_num: usize,
    in_error_block: bool,
) !void {
    // 1. Check error values: error.MyError
    var pos: usize = 0;
    while (pos < t.len) {
        const err_pos = mem.indexOfPos(u8, t, pos, "error.") orelse break;
        // Ensure 'error.' is a standalone keyword, not part of a larger identifier
        const at_start = err_pos == 0 or !isIdent(t[err_pos - 1]);
        if (!at_start) {
            pos = err_pos + 6;
            continue;
        }
        // Skip if inside a string literal
        if (isInsideString(t, err_pos)) {
            pos = err_pos + 6;
            continue;
        }
        // Extract identifier after 'error.'
        var end = err_pos + 6;
        while (end < t.len and isIdent(t[end])) end += 1;
        if (end <= err_pos + 6) {
            pos = err_pos + 6;
            continue;
        }
        const name = t[err_pos + 6 .. end];
        if (name.len > 0 and name[0] == '_') {
            pos = end;
            continue;
        }
        if (!isSnakeCase(name)) {
            try reportNamingIssue(issues, allocator, .{
                .path = path,
                .line = line_num,
                .col = err_pos + 7,
                .kind = "error value",
                .name = name,
                .expected = "snake_case",
            });
        }
        pos = end;
    }

    // 2. Check error set members inside error { ... }
    if (!in_error_block) return;

    // Find where the error set body starts on this line.
    // For lines like `const E = error{ Foo, Bar }`, only check after `error{`.
    // For continuation lines (no `error` keyword), check the whole line.
    var scan_start: usize = 0;
    var epos: usize = 0;
    while (epos < t.len) {
        const found = mem.indexOfPos(u8, t, epos, "error") orelse break;
        const at_start = found == 0 or !isIdent(t[found - 1]);
        if (at_start) {
            var after = found + 5;
            while (after < t.len and (t[after] == ' ' or t[after] == '\t')) after += 1;
            if (after < t.len and t[after] == '{') {
                scan_start = after + 1;
                break;
            }
        }
        epos = found + 5;
    }

    var i: usize = scan_start;
    while (i < t.len) {
        // Skip whitespace
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
        if (i >= t.len) break;

        // Skip braces (opening/closing)
        if (t[i] == '{' or t[i] == '}') {
            i += 1;
            continue;
        }

        // Skip comments
        if (t[i] == '/' and i + 1 < t.len and t[i + 1] == '/') break;

        // Skip string literals (simplified: anything starting with ")
        if (t[i] == '"') {
            i += 1;
            while (i < t.len and t[i] != '"') {
                if (t[i] == '\\' and i + 1 < t.len) i += 1;
                i += 1;
            }
            if (i < t.len) i += 1;
            continue;
        }

        // Extract identifier
        const start = i;
        while (i < t.len and isIdent(t[i])) i += 1;
        if (i <= start) {
            i += 1;
            continue;
        }
        const name = t[start..i];
        if (name.len > 0 and name[0] == '_') {
            // skip optional trailing comma
            while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
            if (i < t.len and t[i] == ',') i += 1;
            continue;
        }
        if (!isSnakeCase(name)) {
            try reportNamingIssue(issues, allocator, .{
                .path = path,
                .line = line_num,
                .col = start + 1,
                .kind = "error set member",
                .name = name,
                .expected = "snake_case",
            });
        }
        // skip optional trailing comma
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
        if (i < t.len and t[i] == ',') i += 1;
    }
}

fn analyzeNaming(
    allocator: Allocator,
    graph: *ImportGraph,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    var iter = graph.files.iterator();

    while (iter.next()) |entry| {
        const a = entry.value_ptr.*;
        const content = a.content;
        var line_num: usize = 1;
        var line_start: usize = 0;
        var error_block_depth: usize = 0;

        while (line_start <= content.len) {
            const newline = mem.indexOfScalarPos(u8, content, line_start, '\n') orelse content.len;
            const line = content[line_start..newline];
            // Compute trimmed slice's offset within content (for multi-line lookahead).
            var lead: usize = 0;
            while (lead < line.len and (line[lead] == ' ' or line[lead] == '\t' or line[lead] == '\r')) : (lead += 1) {}
            const t = mem.trim(u8, line, " \t\r");
            const t_start = line_start + lead;

            // Determine if this line is inside an error block.
            // We are inside if we were already inside one, OR if this line opens one.
            var has_error_open = false;
            var pos: usize = 0;
            while (pos < t.len) {
                const found = mem.indexOfPos(u8, t, pos, "error") orelse break;
                const at_start = found == 0 or !isIdent(t[found - 1]);
                if (at_start) {
                    var after = found + 5;
                    while (after < t.len and (t[after] == ' ' or t[after] == '\t')) after += 1;
                    if (after < t.len and t[after] == '{') {
                        has_error_open = true;
                        break;
                    }
                }
                pos = found + 5;
            }
            const in_error_block = error_block_depth > 0 or has_error_open;

            if (!isCommentOrMultilineString(t)) {
                if (mem.startsWith(u8, t, "const ") or mem.startsWith(u8, t, "pub const "))
                    try checkConstNaming(&issues, allocator, a.path, t, line_num, content, t_start);
                if (mem.startsWith(u8, t, "var ") or mem.startsWith(u8, t, "pub var "))
                    try checkVarNaming(&issues, allocator, a.path, t, line_num);
                if (mem.indexOf(u8, t, "fn ") != null)
                    try checkFnNaming(&issues, allocator, a.path, t, line_num);
                try checkErrorNaming(&issues, allocator, a.path, t, line_num, in_error_block);
            }

            // Update error block depth for subsequent lines.
            var i: usize = 0;
            while (i < t.len) {
                if (i + 5 <= t.len and mem.eql(u8, t[i .. i + 5], "error")) {
                    const at_start = i == 0 or !isIdent(t[i - 1]);
                    if (at_start) {
                        var after = i + 5;
                        while (after < t.len and (t[after] == ' ' or t[after] == '\t')) after += 1;
                        if (after < t.len and t[after] == '{') {
                            error_block_depth += 1;
                            i = after + 1;
                            continue;
                        }
                    }
                }
                if (error_block_depth > 0) {
                    if (t[i] == '{') error_block_depth += 1;
                    if (t[i] == '}') {
                        if (error_block_depth > 0) error_block_depth -= 1;
                    }
                }
                i += 1;
            }

            if (newline == content.len) break;
            line_start = newline + 1;
            line_num += 1;
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

/// Cheap line-only check: does the declaration RHS look like a type definition?
/// Does NOT distinguish a real type def from a closure-wrapper function alias —
/// use `isClosureFunctionAlias` to disambiguate when naming would be reported.
fn isTypeDefinitionLine(line: []const u8) bool {
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

/// Full check including multi-line closure-wrapper disambiguation.
/// Returns true only for real type definitions, not function aliases.
fn isTypeDefinition(line: []const u8, content: []const u8, line_offset: usize) bool {
    if (!isTypeDefinitionLine(line)) return false;
    return !isClosureFunctionAlias(line, content, line_offset);
}

/// True when `const x = struct { fn ... }.call;` (function alias). Mirrors
/// the keyword scan in `isTypeDefinition`, but returns true ONLY for the closure
/// case (struct/enum/union/opaque body whose matching `}` is followed by `.ident`).
fn isClosureFunctionAlias(line: []const u8, content: []const u8, line_offset: usize) bool {
    const eq_pos = mem.indexOf(u8, line, "=") orelse return false;
    const after_eq = line[eq_pos + 1 ..];
    const quote_pos = mem.indexOf(u8, after_eq, "\"");

    const type_kws = [_]struct { kw: []const u8, chk: bool }{
        .{ .kw = " struct", .chk = true },        .{ .kw = " enum", .chk = true },
        .{ .kw = " union", .chk = true },         .{ .kw = " opaque", .chk = true },
        .{ .kw = " packed struct", .chk = true }, .{ .kw = " packed union", .chk = true },
        .{ .kw = " extern struct", .chk = true }, .{ .kw = " extern union", .chk = true },
    };

    for (type_kws) |pat| {
        const pos = mem.indexOf(u8, after_eq, pat.kw) orelse continue;
        if (quote_pos != null and quote_pos.? < pos) continue;
        if (!isValidTypeBoundary(after_eq, pos + pat.kw.len, pat.chk)) continue;
        const kw_end_global = line_offset + eq_pos + 1 + pos + pat.kw.len;
        if (isClosureWrappingType(content, kw_end_global)) return true;
    }
    return false;
}

/// Returns true if the type body starting near `kw_end` is followed by `.ident`
/// after its matching `}` — the closure-wrapper pattern used for function aliases.
fn isClosureWrappingType(content: []const u8, kw_end: usize) bool {
    if (kw_end >= content.len) return false;
    var i = kw_end;
    // Skip optional `(...)` after the keyword (e.g. `enum(u8)`, `packed struct(u32)`)
    // and any whitespace, until we land on the type body's opening `{`.
    while (i < content.len) {
        const c = content[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            i += 1;
            continue;
        }
        if (c == '(') {
            var pdepth: usize = 1;
            i += 1;
            while (i < content.len and pdepth > 0) : (i += 1) {
                const cc = content[i];
                if (cc == '(') pdepth += 1 else if (cc == ')') pdepth -= 1;
            }
            continue;
        }
        break;
    }
    if (i >= content.len or content[i] != '{') return false;

    // Trace matching `}` with rudimentary string/char/comment/multiline-string skipping.
    var depth: usize = 0;
    var in_str = false;
    var in_char = false;
    var in_line_comment = false;
    var in_ml_str = false;
    while (i < content.len) : (i += 1) {
        const c = content[i];
        if (in_line_comment or in_ml_str) {
            if (c == '\n') {
                in_line_comment = false;
                in_ml_str = false;
            }
            continue;
        }
        if (in_str) {
            if (c == '\\' and i + 1 < content.len) {
                i += 1;
                continue;
            }
            if (c == '"') in_str = false;
            continue;
        }
        if (in_char) {
            if (c == '\\' and i + 1 < content.len) {
                i += 1;
                continue;
            }
            if (c == '\'') in_char = false;
            continue;
        }
        if (c == '/' and i + 1 < content.len and content[i + 1] == '/') {
            in_line_comment = true;
            i += 1;
            continue;
        }
        if (c == '\\' and i + 1 < content.len and content[i + 1] == '\\') {
            in_ml_str = true;
            i += 1;
            continue;
        }
        if (c == '"') {
            in_str = true;
            continue;
        }
        if (c == '\'') {
            in_char = true;
            continue;
        }
        if (c == '{') {
            depth += 1;
            continue;
        }
        if (c == '}') {
            if (depth == 0) return false;
            depth -= 1;
            if (depth == 0) {
                var j = i + 1;
                while (j < content.len) : (j += 1) {
                    const cc = content[j];
                    if (cc == ' ' or cc == '\t' or cc == '\r' or cc == '\n') continue;
                    return cc == '.';
                }
                return false;
            }
        }
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
    fn_is_noreturn: bool = false,
    // Test block context tracking
    in_test_block: bool = false,
    test_brace_depth: usize = 0,
    // Whether current function started inside a test block
    func_in_test: bool = false,
    // File-level: functions that receive no-free allocators at call sites
    no_free_param_fns: ?*const std.StringHashMapUnmanaged(void) = null,
    // File-level: struct field names declared with no-free allocator types
    no_free_fields: ?*const std.StringHashMapUnmanaged(void) = null,
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

    // Detect noreturn functions - memory leaks don't matter in noreturn
    state.fn_is_noreturn = mem.indexOf(u8, t, "noreturn") != null;

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
/// Convert definite assignment issues to ZA607 warnings
fn emitDefiniteAssignmentIssues(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    def_issues: *std.StringHashMap(usize),
    file_path: []const u8,
) !void {
    var def_iter = def_issues.iterator();
    while (def_iter.next()) |entry| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "variable '{s}' potentially read " ++
                "before assignment",
            .{entry.key_ptr.*},
        );
        try issues.append(allocator, .{
            .file = file_path,
            .line = entry.value_ptr.*,
            .col = 1,
            .severity = .warning,
            .rule = "ZA607",
            .message = msg,
            .help = "ensure variable is assigned " ++
                "on all code paths",
            .message_owned = true,
        });
    }
}

/// Run memory-related CFG analyses
fn runCFGMemoryAnalyses(
    a: Allocator,
    out: *std.ArrayListUnmanaged(Issue),
    cfg: *ControlFlowGraph,
    fl: []const []const u8,
    fstart: usize,
    fp: []const u8,
    fn_ret_err: bool,
    in_test: bool,
    is_no_free_recipient: bool,
    no_free_fields: ?*const std.StringHashMapUnmanaged(void),
) !void {
    var r1 = try analyzeCFGMemorySafety(a, cfg, fl, fstart, fp, no_free_fields);
    defer r1.deinit(a);
    try out.appendSlice(a, r1.items);
    var r2 = if (is_no_free_recipient)
        std.ArrayListUnmanaged(Issue).empty
    else
        try analyzeCFGDeferCoverage(a, cfg, fl, fstart, fp, no_free_fields);
    defer r2.deinit(a);
    try out.appendSlice(a, r2.items);
    var r3 = if (in_test or is_no_free_recipient)
        std.ArrayListUnmanaged(Issue).empty
    else
        try analyzeCFGErrdeferCoverage(a, fl, fstart, fp, fn_ret_err, no_free_fields);
    defer r3.deinit(a);
    try out.appendSlice(a, r3.items);
}

/// Run safety and error CFG analyses
fn runCFGSafetyAnalyses(
    a: Allocator,
    out: *std.ArrayListUnmanaged(Issue),
    cfg: *ControlFlowGraph,
    fl: []const []const u8,
    fstart: usize,
    fp: []const u8,
    fn_name: []const u8,
    in_test: bool,
) !void {
    var r1 = try analyzeCFGNullSafety(a, cfg, fl, fstart, fp);
    defer r1.deinit(a);
    try out.appendSlice(a, r1.items);
    var r2 = try analyzeCFGPanicPatterns(a, cfg, fl, fstart, fp);
    defer r2.deinit(a);
    try out.appendSlice(a, r2.items);
    var r3 = try analyzeCFGErrors(
        a,
        cfg,
        fl,
        fstart,
        fp,
        fn_name,
        in_test,
    );
    defer r3.deinit(a);
    try out.appendSlice(a, r3.items);
}

/// Run definite-assignment analysis and emit issues
fn runDefiniteAssignmentAnalysis(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    cfg: *ControlFlowGraph,
    func_lines_items: []const []const u8,
    func_start: usize,
    file_path: []const u8,
) !void {
    var def_issues = try analyzeDefiniteAssignment(
        allocator,
        cfg,
        func_lines_items,
        func_start,
    );
    defer def_issues.deinit();
    try emitDefiniteAssignmentIssues(allocator, issues, &def_issues, file_path);
}

fn processFunction(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    file_path: []const u8,
    func_name: []const u8,
    func_start: usize,
    func_lines_items: []const []const u8,
    fn_returns_error: bool,
    is_in_test_context: bool,
    no_free_param_fns: ?*const std.StringHashMapUnmanaged(void),
    no_free_fields: ?*const std.StringHashMapUnmanaged(void),
) !void {
    // Check if this function receives a no-free allocator via call-site propagation
    const is_no_free_recipient = if (no_free_param_fns) |fns| fns.contains(func_name) else false;

    var cfg = try buildCFG(allocator, func_name, func_start, func_lines_items);
    defer cfg.deinit();

    try runDefiniteAssignmentAnalysis(
        allocator,
        issues,
        &cfg,
        func_lines_items,
        func_start,
        file_path,
    );
    try runCFGMemoryAnalyses(
        allocator,
        issues,
        &cfg,
        func_lines_items,
        func_start,
        file_path,
        fn_returns_error,
        is_in_test_context,
        is_no_free_recipient,
        no_free_fields,
    );
    try runCFGSafetyAnalyses(
        allocator,
        issues,
        &cfg,
        func_lines_items,
        func_start,
        file_path,
        func_name,
        is_in_test_context,
    );
}

/// Analyze a single file for CFG memory issues
fn analyzeCFGFile(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    content: []const u8,
    file_path: []const u8,
) !void {
    // Pre-scan: find functions called with no-free allocator args (arena propagation)
    var no_free_fns = try buildNoFreeParamFunctions(allocator, content);
    defer no_free_fns.deinit(allocator);

    // Pre-scan: collect struct field names declared with no-free allocator types
    // (e.g. `arena: std.heap.ArenaAllocator,`) for field-chain suppression
    var no_free_fields = try collectNoFreeFieldNamesFromContent(allocator, content);
    defer no_free_fields.deinit(allocator);

    var state = CFGState{
        .no_free_param_fns = &no_free_fns,
        .no_free_fields = &no_free_fields,
    };
    var line_num: usize = 1;
    var line_iter = mem.splitScalar(u8, content, '\n');
    var func_lines = std.ArrayListUnmanaged([]const u8).empty;
    defer func_lines.deinit(allocator);
    var prev = CFGPrevFunc{};

    while (line_iter.next()) |line| {
        defer line_num += 1;
        const t = mem.trim(u8, line, " \t\r");
        const is_comment = isCommentOrMultilineString(t);

        if (!is_comment) {
            const ts = trackTestBlock(t, state.in_test_block, state.test_brace_depth);
            state.in_test_block = ts.in_test;
            state.test_brace_depth = ts.depth;
            try handleCFGFuncDetection(
                allocator,
                issues,
                file_path,
                &state,
                &prev,
                &func_lines,
                t,
                line_num,
            );
        }
        if (!state.in_func) continue;
        try func_lines.append(allocator, line);

        if (is_comment) continue;
        if (!trackCFGBraces(t, &state)) continue;

        try finishCFGFunction(
            allocator,
            issues,
            file_path,
            &state,
            &func_lines,
        );
    }
}

fn finishCFGFunction(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    file_path: []const u8,
    state: *CFGState,
    func_lines: *std.ArrayListUnmanaged([]const u8),
) !void {
    const in_test = state.func_in_test or isInTestContext(file_path, false);
    try processFunction(
        allocator,
        issues,
        file_path,
        state.func_name,
        state.func_start,
        func_lines.items,
        state.fn_returns_error,
        in_test,
        state.no_free_param_fns,
        state.no_free_fields,
    );
    state.in_func = false;
    func_lines.clearRetainingCapacity();
}

/// Saved state for the previous function during CFG file analysis
const CFGPrevFunc = struct {
    name: []const u8 = "",
    start: usize = 0,
    in_test: bool = false,
};

/// Handle function detection and nested function processing in CFG file analysis
fn handleCFGFuncDetection(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    file_path: []const u8,
    state: *CFGState,
    prev: *CFGPrevFunc,
    func_lines: *std.ArrayListUnmanaged([]const u8),
    t: []const u8,
    line_num: usize,
) !void {
    const was_in_func = state.in_func;
    prev.name = state.func_name;
    prev.start = state.func_start;
    prev.in_test = state.func_in_test;
    const found_nested = detectCFGFuncStart(t, state, line_num);

    if (state.in_func and !was_in_func) {
        state.func_in_test = state.in_test_block;
    } else if (found_nested) {
        state.func_in_test = state.in_test_block;
        if (func_lines.items.len >= 3) {
            try processFunction(
                allocator,
                issues,
                file_path,
                prev.name,
                prev.start,
                func_lines.items,
                false,
                prev.in_test,
                state.no_free_param_fns,
                state.no_free_fields,
            );
        }
        if (func_lines.items.len > 0) func_lines.clearRetainingCapacity();
    }
}

/// Build a simplified CFG for a function and analyze memory flow
fn analyzeCFGMemory(
    allocator: Allocator,
    graph: *ImportGraph,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    var iter = graph.files.iterator();
    while (iter.next()) |entry| {
        try analyzeCFGFile(allocator, &issues, entry.value_ptr.content, entry.key_ptr.*);
    }
    return issues;
}

// ============================================================================
// Memory Analysis Helpers
// ============================================================================

fn countBraceDepth(t: []const u8, depth: usize) usize {
    var d = depth;
    for (t) |c| {
        if (c == '{') d += 1;
        if (c == '}' and d > 0) d -= 1;
    }
    return d;
}

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

/// Check if line contains allocation call using vocab from compat layer.
/// For .create(), uses tracked allocator set to verify receiver is an allocator
/// (common method name on non-allocator types). All other alloc methods are
/// allocator-specific enough to detect without type-based verification.
fn findAllocCall(
    t: []const u8,
    alloc_names: ?*const std.StringHashMapUnmanaged(void),
) ?struct { col: usize, is_create: bool } {
    for (compat.getAllocMethodPatterns()) |pattern| {
        const col = mem.indexOf(u8, t, pattern) orelse continue;
        if (isPatternInString(t, col)) continue;
        if (isTypeAllocFactory(t, col)) continue;

        const is_create = mem.eql(u8, pattern, ".create(");
        if (is_create) {
            // .create() needs type-based check — too common on non-allocators
            if (!isAllocatorCreateTypeBased(t, col, alloc_names))
                continue;
        }
        // .alloc() first arg must look like a Zig type — non-allocator structs
        // can have .alloc() methods (e.g. SPIR-V CodeGen register allocation).
        if (mem.eql(u8, pattern, ".alloc(")) {
            if (!hasTypeFirstArg(t, col + pattern.len))
                continue;
        }
        return .{ .col = col, .is_create = is_create };
    }

    // Check qualified function patterns (e.g. "mem.concat(", "mem.join(")
    for (compat.getQualifiedAllocFnPatterns()) |pattern| {
        const col = mem.indexOf(u8, t, pattern) orelse continue;
        if (isPatternInString(t, col)) continue;
        return .{ .col = col, .is_create = false };
    }

    return null;
}

/// Determine if .create() at the given position is called on an allocator.
/// Type-based: checks if receiver is in tracked allocator variable set or is uppercase (factory).
fn isAllocatorCreateTypeBased(t: []const u8, create_pos: usize, alloc_names: ?*const std.StringHashMapUnmanaged(void)) bool {
    const name = extractCreateCaller(t, create_pos) orelse return false;
    // Uppercase first letter = Type.create() factory method, NOT an allocator
    if (name.len > 0 and name[0] >= 'A' and name[0] <= 'Z') return false;
    // Check tracked allocator variable set (type-based)
    if (alloc_names) |names| {
        return names.contains(name);
    }
    // Fallback when no tracked set available: check known stdlib globals (compat layer)
    for (compat.getGlobalAllocNames()) |g| {
        if (mem.eql(u8, name, g)) return true;
    }
    return false;
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
fn isSafeBuiltin(t: []const u8, type_ctx: ?*const TypeContext) bool {
    // Zig builtins (version-aware via compat layer)
    if (compat.containsBuiltin(t)) return true;
    // Return-type resolution (definitive when available)
    if (type_ctx) |ctx| {
        const rk = resolveReturnKind(ctx, t);
        switch (rk) {
            .void_type, .value, .optional, .noreturn_type => return true,
            .error_union => return false,
            .unknown => {}, // fall through to vocab
        }
    }
    // Stdlib safe methods — type-aware
    const stdlib_vars_ptr = if (type_ctx) |ctx| &ctx.stdlib_vars else null;
    if (isMethodOnStdlibVar(t, stdlib_vars_ptr, compat.getSafeMethodPatterns())) return true;
    // Non-stdlib safe patterns (struct field access)
    if (mem.indexOf(u8, t, ".len") != null) return true;
    if (mem.indexOf(u8, t, ".items") != null) return true;
    return compat.containsOptionalMethod(t);
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
fn isKnownVoidFunction(t: []const u8, type_ctx: ?*const TypeContext) bool {
    // Stdlib cleanup patterns (.free, .destroy, .deinit) — always void
    for (compat.getCleanupPatterns()) |pat| {
        if (mem.indexOf(u8, t, pat) != null) return true;
    }
    // Return-type resolution (definitive when available)
    if (type_ctx) |ctx| {
        const rk = resolveReturnKind(ctx, t);
        switch (rk) {
            .void_type, .noreturn_type => return true,
            .error_union, .value, .optional => return false,
            .unknown => {}, // fall through to vocab
        }
    }
    // Stdlib void methods — type-aware: .clear, .close, .reset only on stdlib vars;
    // debug.print, assert always apply (universal patterns)
    const stdlib_vars_ptr = if (type_ctx) |ctx| &ctx.stdlib_vars else null;
    if (isMethodOnStdlibVar(t, stdlib_vars_ptr, compat.getVoidMethodPatterns())) return true;
    // log.* with word boundary (std.log.info, std.log.warn, etc.)
    if (mem.indexOf(u8, t, "log.")) |pos| {
        if (pos == 0 or !isIdent(t[pos - 1])) return true;
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
    type_ctx: ?*const TypeContext,
) !void {
    const is_discard = mem.startsWith(u8, t, "_ = ") and mem.indexOf(u8, t, "(") != null;
    if (!is_discard or hasErrorHandling(t) or isSafeBuiltin(t, type_ctx)) return;
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
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    var iter = graph.files.iterator();
    while (iter.next()) |entry| {
        const content = entry.value_ptr.content;
        const file_path = entry.key_ptr.*;
        if (mem.endsWith(u8, file_path, "cimport.zig")) continue;
        if (isCImportFile(file_path, content)) continue;
        try analyzeIgnoredErrorsInFile(allocator, &issues, file_path, content);
    }
    return issues;
}

/// Count braces on a defer-starting line (skip the first opening brace)
fn countDeferStartBraces(t: []const u8) usize {
    var depth: usize = 1;
    var saw_first = false;
    for (t) |c| {
        if (c == '{' and !saw_first)
            saw_first = true
        else if (c == '{')
            depth += 1;
        if (c == '}' and depth > 0) depth -= 1;
    }
    return depth;
}

/// Update defer depth by counting braces on a line inside a defer block
fn updateDeferBraceDepth(t: []const u8, depth: usize) usize {
    var d = depth;
    for (t) |c| {
        if (c == '{') d += 1;
        if (c == '}' and d > 0) d -= 1;
    }
    return d;
}

/// Analyze a single file for ignored errors (ZA205)
fn analyzeIgnoredErrorsInFile(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    file_path: []const u8,
    content: []const u8,
) !void {
    // Build type-aware context for this file (struct methods, var types, stdlib vars)
    var type_ctx = try parseFileTypeContext(allocator, content);
    defer type_ctx.deinit(allocator);

    var line_num: usize = 1;
    var defer_depth: usize = 0;
    var line_iter = mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        defer line_num += 1;
        const t = mem.trim(u8, line, " \t\r");
        if (t.len == 0 or isCommentOrMultilineString(t)) continue;

        if (mem.startsWith(u8, t, "defer ") or mem.startsWith(u8, t, "errdefer ")) {
            if (mem.indexOf(u8, t, "{") == null) continue;
            defer_depth = countDeferStartBraces(t);
            continue;
        }
        if (defer_depth > 0) {
            defer_depth = updateDeferBraceDepth(t, defer_depth);
            continue;
        }
        try checkIgnoredError(allocator, issues, file_path, t, line_num, &type_ctx);
    }
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
/// Phase 1: Identify null checks in each block
/// Check if a line is a conditional that contains a null check
fn isNullCheckConditional(t: []const u8) bool {
    return mem.startsWith(u8, t, "if (") or
        mem.startsWith(u8, t, "} else if (") or
        mem.startsWith(u8, t, "while (");
}

fn collectNullChecksPerBlock(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    checked: []std.StringHashMapUnmanaged(void),
) !void {
    for (cfg.blocks.items, 0..) |block, bid| {
        if (block.start_line == 0 or
            block.start_line > block.end_line) continue;
        try collectNullChecksInBlock(
            allocator,
            lines,
            func_line,
            block.start_line,
            block.end_line,
            &checked[bid],
        );
    }
}

/// Collect null-checked variables from conditionals within a single block
fn collectNullChecksInBlock(
    allocator: Allocator,
    lines: []const []const u8,
    func_line: usize,
    start_line: usize,
    end_line: usize,
    checked: *std.StringHashMapUnmanaged(void),
) !void {
    for (start_line..end_line + 1) |ln| {
        if (ln < func_line) continue;
        const idx = ln - func_line;
        if (idx >= lines.len) continue;
        const t = mem.trim(u8, lines[idx], " \t\r");
        if (isCommentOrMultilineString(t)) continue;
        if (!isNullCheckConditional(t)) continue;
        const var_name = extractNullCheckedVar(t) orelse continue;
        try checked.put(allocator, var_name, {});
    }
}

/// Intersect predecessor null-check sets into a block
/// Copy all entries from a source hash map into an intersection map
fn initIntersectionFromMap(
    allocator: Allocator,
    intersection: *std.StringHashMapUnmanaged(void),
    source: *const std.StringHashMapUnmanaged(void),
) !void {
    var it = source.iterator();
    while (it.next()) |e| {
        try intersection.put(allocator, e.key_ptr.*, {});
    }
}

/// Remove entries from intersection that are not present in the pred set
fn removeAbsentKeys(
    allocator: Allocator,
    intersection: *std.StringHashMapUnmanaged(void),
    pred_set: *const std.StringHashMapUnmanaged(void),
) !void {
    var rm = std.ArrayListUnmanaged([]const u8).empty;
    defer rm.deinit(allocator);
    var it = intersection.iterator();
    while (it.next()) |e| {
        if (!pred_set.contains(e.key_ptr.*))
            try rm.append(allocator, e.key_ptr.*);
    }
    for (rm.items) |key| _ = intersection.remove(key);
}

fn intersectPredChecks(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    bid: usize,
    checked: []std.StringHashMapUnmanaged(void),
) !bool {
    var preds = std.ArrayListUnmanaged(usize).empty;
    defer preds.deinit(allocator);
    for (cfg.edges.items) |edge| {
        if (edge.to == bid) try preds.append(allocator, edge.from);
    }
    if (preds.items.len == 0) return false;

    var intersection: std.StringHashMapUnmanaged(void) = .empty;
    defer intersection.deinit(allocator);
    for (preds.items, 0..) |pred, pi| {
        if (pi == 0) {
            try initIntersectionFromMap(allocator, &intersection, &checked[pred]);
        } else {
            try removeAbsentKeys(allocator, &intersection, &checked[pred]);
        }
    }
    var any_changed = false;
    var it = intersection.iterator();
    while (it.next()) |e| {
        const gop = try checked[bid].getOrPut(allocator, e.key_ptr.*);
        if (!gop.found_existing) any_changed = true;
    }
    return any_changed;
}

/// Check for unsafe .? unwrap on a line
fn checkOptionalUnwrap(
    allocator: Allocator,
    t: []const u8,
    line_num: usize,
    idx: usize,
    lines: []const []const u8,
    file_path: []const u8,
    checked_set: *const std.StringHashMapUnmanaged(void),
    issues: *std.ArrayListUnmanaged(Issue),
) !void {
    const col = mem.indexOf(u8, t, ".?") orelse return;
    if (isInSafeContext(t)) return;
    if (!isUnsafeUnwrapUsage(t, col)) return;
    const var_name = extractUnwrappedVar(t, col) orelse return;
    if (checked_set.contains(var_name)) return;
    if (hasEarlyReturnNullGuard(lines, idx, var_name)) return;
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

/// Check for unsafe .* deref on optional pointer (maybe_/opt_ prefix)
fn checkOptionalDeref(
    allocator: Allocator,
    t: []const u8,
    line_num: usize,
    file_path: []const u8,
    checked_set: *const std.StringHashMapUnmanaged(void),
    issues: *std.ArrayListUnmanaged(Issue),
) !void {
    const col = mem.indexOf(u8, t, ".*") orelse return;
    const before = t[0..col];
    const has_opt = mem.indexOf(u8, before, "maybe_") != null or
        mem.indexOf(u8, before, "opt_") != null;
    if (!has_opt or isInSafeContext(t)) return;
    const var_name = extractDerefVar(t, col) orelse return;
    if (checked_set.contains(var_name)) return;
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

/// Phase 3: Check for unsafe unwraps on a line
fn checkLineForUnsafeUnwrap(
    allocator: Allocator,
    t: []const u8,
    line_num: usize,
    idx: usize,
    lines: []const []const u8,
    file_path: []const u8,
    checked_set: *const std.StringHashMapUnmanaged(void),
    issues: *std.ArrayListUnmanaged(Issue),
) !void {
    try checkOptionalUnwrap(
        allocator,
        t,
        line_num,
        idx,
        lines,
        file_path,
        checked_set,
        issues,
    );
    try checkOptionalDeref(
        allocator,
        t,
        line_num,
        file_path,
        checked_set,
        issues,
    );
}

/// Propagate null checks across CFG until fixpoint
fn propagateNullChecks(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    checked: []std.StringHashMapUnmanaged(void),
    num_blocks: usize,
) !void {
    var iters: usize = 0;
    var changed = true;
    while (changed and iters < 100) {
        changed = false;
        iters += 1;
        for (0..num_blocks) |bid| {
            if (try intersectPredChecks(allocator, cfg, bid, checked))
                changed = true;
        }
    }
}

/// Scan all CFG blocks for unsafe unwraps using checked sets
fn scanBlocksForUnsafeUnwraps(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
    checked: []std.StringHashMapUnmanaged(void),
    issues: *std.ArrayListUnmanaged(Issue),
) !void {
    for (cfg.blocks.items, 0..) |block, bid| {
        if (block.start_line == 0 or
            block.start_line > block.end_line) continue;
        for (block.start_line..block.end_line + 1) |ln| {
            if (ln < func_line) continue;
            const idx = ln - func_line;
            if (idx >= lines.len) continue;
            const t = mem.trim(u8, lines[idx], " \t\r");
            if (isCommentOrMultilineString(t)) continue;
            try checkLineForUnsafeUnwrap(
                allocator,
                t,
                ln,
                idx,
                lines,
                file_path,
                &checked[bid],
                issues,
            );
        }
    }
}

fn analyzeCFGNullSafety(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    const num_blocks = cfg.blocks.items.len;
    if (num_blocks == 0) return issues;

    const checked = try allocator.alloc(
        std.StringHashMapUnmanaged(void),
        num_blocks,
    );
    defer {
        for (checked) |*map| map.deinit(allocator);
        allocator.free(checked);
    }
    for (checked) |*map| map.* = .empty;

    try collectNullChecksPerBlock(allocator, cfg, lines, func_line, checked);
    try propagateNullChecks(allocator, cfg, checked, num_blocks);
    try scanBlocksForUnsafeUnwraps(
        allocator,
        cfg,
        lines,
        func_line,
        file_path,
        checked,
        &issues,
    );
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
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    const is_test_ctx = mem.startsWith(u8, func_name, "test ") or
        is_in_test_context;

    for (cfg.blocks.items) |block| {
        if (block.start_line == 0 or block.start_line > block.end_line) continue;

        for (block.start_line..block.end_line + 1) |line_num| {
            if (line_num < func_line) continue;
            const idx = line_num - func_line;
            if (idx >= lines.len) continue;

            const t = mem.trim(u8, lines[idx], " \t\r");
            if (isCommentOrMultilineString(t)) continue;
            if (is_test_ctx) continue;

            const preceding: ?[]const []const u8 = if (idx > 0) lines[0..idx] else null;
            if (checkCatchUnreachable(t, file_path, line_num, preceding)) |issue|
                try issues.append(allocator, issue);
            if (checkOrelseUnreachable(
                t,
                file_path,
                line_num,
                lines,
                idx,
                func_line,
            )) |issue|
                try issues.append(allocator, issue);
        }
    }

    return issues;
}

/// ZA202: catch unreachable will panic on error
/// Accepts preceding lines context for multi-line expression lookback.
fn checkCatchUnreachable(
    t: []const u8,
    file_path: []const u8,
    line_num: usize,
    preceding_lines: ?[]const []const u8,
) ?Issue {
    const col = mem.indexOf(u8, t, "catch unreachable") orelse return null;
    if (isInsideString(t, col)) return null;
    // Suppress inside @TypeOf() — compile-time only, never executed at runtime
    if (isInsideTypeOf(t, col, preceding_lines)) return null;
    // Suppress bufPrint/bufPrintZ — only error is NoSpaceLeft, provably safe
    if (isBufPrintCatchUnreachable(t, preceding_lines)) return null;
    // Suppress stdlib functions called with string literals (parseIp("0.0.0.0", ...))
    if (isSafeStdlibLiteralCall(t, preceding_lines)) return null;
    return .{
        .file = file_path,
        .line = line_num,
        .col = col + 1,
        .severity = .note,
        .rule = RULE_CATCH_UNREACHABLE,
        .message = "catch unreachable will panic on error",
        .help = "use explicit error handling",
    };
}

/// Find the call-site line for a `) catch ...` by paren-balanced lookback.
/// Starting from the current line, counts unmatched `)` backwards through
/// preceding lines until the opening `(` is found. Returns the line containing
/// the function call, or null if no match within the expression.
fn findCallSiteLine(t: []const u8, preceding_lines: ?[]const []const u8) ?[]const u8 {
    // Count unmatched parens on current line (left of "catch")
    var depth: isize = 0;
    for (t) |c| {
        if (c == '(') depth += 1;
        if (c == ')') depth -= 1;
    }
    // If balanced or more opens than closes, call site is this line
    if (depth >= 0) return t;
    // Unmatched closes → call started on a preceding line. Walk back.
    const prev = preceding_lines orelse return null;
    var idx = prev.len;
    while (idx > 0) {
        idx -= 1;
        const pl = mem.trim(u8, prev[idx], " \t\r");
        if (isCommentOrMultilineString(pl)) continue;
        for (pl) |c| {
            if (c == '(') depth += 1;
            if (c == ')') depth -= 1;
        }
        if (depth >= 0) return pl;
    }
    return null;
}

/// Check if `catch unreachable` is inside a @TypeOf() expression (compile-time only).
/// Walks backwards through preceding lines accumulating paren depth. If a line
/// contains `@TypeOf(` while cumulative depth shows we're still inside its parens,
/// the catch unreachable is compile-time only and safe to suppress.
fn isInsideTypeOf(t: []const u8, pos: usize, preceding_lines: ?[]const []const u8) bool {
    // Check current line first (fast path) — scan left of `catch unreachable`
    var i = pos;
    while (i > 0) {
        i -= 1;
        if (i + 8 <= t.len and mem.eql(u8, t[i .. i + 8], "@TypeOf(")) return true;
        if (i + 7 <= t.len and mem.eql(u8, t[i .. i + 7], "@typeOf(")) return true;
    }
    // Multi-line: accumulate paren depth from current line backwards.
    // If we find @TypeOf( on a line where depth > 0, we're nested inside it.
    const prev = preceding_lines orelse return false;
    var depth: isize = 0;
    for (t) |c| {
        if (c == '(') depth += 1;
        if (c == ')') depth -= 1;
    }
    var idx = prev.len;
    while (idx > 0) {
        idx -= 1;
        const pl = mem.trim(u8, prev[idx], " \t\r");
        if (isCommentOrMultilineString(pl)) continue;
        for (pl) |c| {
            if (c == '(') depth += 1;
            if (c == ')') depth -= 1;
        }
        if (depth > 0 and (mem.indexOf(u8, pl, "@TypeOf(") != null or
            mem.indexOf(u8, pl, "@typeOf(") != null)) return true;
        // Stop at statement boundaries (no paren nesting left to resolve)
        if (depth <= 0 and (mem.endsWith(u8, pl, ";") or mem.endsWith(u8, pl, "{"))) break;
    }
    return false;
}

/// Check if `catch unreachable` comes from a bufPrint/bufPrintZ call.
/// These functions only return error.NoSpaceLeft — programmers size the buffer
/// to fit max output, making catch unreachable provably correct.
/// Uses paren-balanced lookback for multi-line calls.
fn isBufPrintCatchUnreachable(t: []const u8, preceding_lines: ?[]const []const u8) bool {
    if (hasBufPrintCall(t)) return true;
    const call_line = findCallSiteLine(t, preceding_lines) orelse return false;
    return hasBufPrintCall(call_line);
}

/// Check if `catch unreachable` comes from a stdlib function that is provably
/// safe when called with a string literal argument (e.g., parseIp("0.0.0.0", port)).
fn isSafeStdlibLiteralCall(t: []const u8, preceding_lines: ?[]const []const u8) bool {
    const call_line = findCallSiteLine(t, preceding_lines) orelse return false;
    const safe_fns = [_][]const u8{
        "parseIp(",  "parseIp4(",      "parseIp6(",
        "parseInt(", "parseUnsigned(",
    };
    for (safe_fns) |fn_name| {
        if (mem.indexOf(u8, call_line, fn_name)) |pos| {
            if (!isInsideString(call_line, pos)) {
                // Verify first argument is a string literal
                const after = call_line[pos + fn_name.len ..];
                const trimmed = mem.trim(u8, after, " \t");
                if (mem.startsWith(u8, trimmed, "\"")) return true;
            }
        }
    }
    return false;
}

/// Check if a line contains a bufPrint or bufPrintZ call (not inside a string).
fn hasBufPrintCall(t: []const u8) bool {
    if (mem.indexOf(u8, t, "bufPrint(")) |pos| {
        if (!isInsideString(t, pos)) return true;
    }
    if (mem.indexOf(u8, t, "bufPrintZ(")) |pos| {
        if (!isInsideString(t, pos)) return true;
    }
    return false;
}

/// Check if a catch {} follows a writer/stream method call, looking back
/// through preceding lines via paren-balanced lookback for multi-line calls.
fn isStreamWriteCatchMultiline(t: []const u8, preceding_lines: ?[]const []const u8) bool {
    if (isStreamWriteCall(t)) return true;
    const call_line = findCallSiteLine(t, preceding_lines) orelse return false;
    return isStreamWriteCall(call_line);
}

/// Check if `catch {}` is on a continuation line of a multi-line defer expression.
/// Covers patterns like:
///   defer std.fs.cwd()
///       .openFile("x", .{})
///       .close() catch {};
fn isDeferCatchMultiline(t: []const u8, preceding_lines: ?[]const []const u8) bool {
    _ = t;
    const prev = preceding_lines orelse return false;
    // Walk backwards through preceding lines looking for `defer ` or `errdefer `
    // within the same expression (stop at semicolons and closing braces)
    var idx = prev.len;
    while (idx > 0) {
        idx -= 1;
        const pl = mem.trim(u8, prev[idx], " \t\r");
        if (pl.len == 0) continue;
        if (isCommentOrMultilineString(pl)) continue;
        if (mem.startsWith(u8, pl, "defer ") or mem.startsWith(u8, pl, "errdefer ")) return true;
        // Stop at statement boundaries — the defer can't be further back
        if (mem.endsWith(u8, pl, ";") or mem.endsWith(u8, pl, "{") or mem.endsWith(u8, pl, "}")) return false;
    }
    return false;
}

/// Check if `catch {}` result is explicitly discarded: `_ = expr catch {}`
/// The `_ = ` prefix means the caller intentionally ignores both value and error.
fn isDiscardedCatch(t: []const u8) bool {
    return mem.startsWith(u8, t, "_ = ");
}

/// Check if a line contains a writer/stream write method call (not inside a string).
fn isStreamWriteCall(t: []const u8) bool {
    const write_patterns = [_][]const u8{
        ".print(",           ".writeAll(",         ".writeByte(",
        ".writeInt(",        ".writeBytesNTimes(", ".writeSep(",
        ".writeByteNTimes(",
    };
    for (write_patterns) |pat| {
        if (mem.indexOf(u8, t, pat)) |pos| {
            if (!isInsideString(t, pos)) return true;
        }
    }
    return false;
}

/// ZA203: orelse unreachable will panic on null
fn checkOrelseUnreachable(
    t: []const u8,
    file_path: []const u8,
    line_num: usize,
    lines: []const []const u8,
    idx: usize,
    func_line: usize,
) ?Issue {
    const col = mem.indexOf(u8, t, "orelse unreachable") orelse return null;
    if (isInsideString(t, col)) return null;

    if (extractOrelseVar(t, col)) |name| {
        if (hasNullGuard(lines, idx, func_line, name)) return null;
    }
    return .{
        .file = file_path,
        .line = line_num,
        .col = col + 1,
        .severity = .note,
        .rule = RULE_ORELSE_UNREACHABLE,
        .message = "orelse unreachable will panic",
        .help = "use explicit null handling",
    };
}

/// ZA203 (line-based): orelse unreachable without null guard analysis
/// Used by checkLineErrors for the `errors` subcommand path.
fn checkLineOrelseUnreachable(
    t: []const u8,
    file_path: []const u8,
    line_num: usize,
) ?Issue {
    const col = mem.indexOf(u8, t, "orelse unreachable") orelse return null;
    if (isInsideString(t, col)) return null;
    return .{
        .file = file_path,
        .line = line_num,
        .col = col + 1,
        .severity = .note,
        .rule = RULE_ORELSE_UNREACHABLE,
        .message = "orelse unreachable will panic",
        .help = "use explicit null handling",
    };
}

/// ZA207: catch undefined converts errors to undefined behavior
fn checkCatchUndefined(
    t: []const u8,
    file_path: []const u8,
    line_num: usize,
) ?Issue {
    // Match "catch undefined" but not "catch |_| undefined" or "catch |err| undefined"
    const col = mem.indexOf(u8, t, "catch undefined") orelse return null;
    if (isInsideString(t, col)) return null;
    // Ensure it's "catch undefined" not "catch |...| undefined"
    const after_catch = t[col + 5 ..]; // skip "catch"
    const trimmed = mem.trimStart(u8, after_catch, " \t");
    if (trimmed.len > 0 and trimmed[0] == '|') return null;
    return .{
        .file = file_path,
        .line = line_num,
        .col = col + 1,
        .severity = .warning,
        .rule = RULE_CATCH_UNDEFINED,
        .message = "catch undefined converts errors to undefined behavior",
        .help = "handle the error explicitly or use catch |err| { ... }",
    };
}

/// ZA208: @panic() will crash the program
fn checkPanic(
    t: []const u8,
    file_path: []const u8,
    line_num: usize,
) ?Issue {
    const col = mem.indexOf(u8, t, "@panic(") orelse return null;
    if (isInsideString(t, col)) return null;
    return .{
        .file = file_path,
        .line = line_num,
        .col = col + 1,
        .severity = .note,
        .rule = RULE_PANIC,
        .message = "@panic() will crash the program",
        .help = "consider returning an error instead, or document why panic is necessary",
    };
}

/// Extract variable name before "orelse unreachable"
/// Pattern: "x orelse unreachable" or "x.field orelse unreachable"
fn extractOrelseVar(t: []const u8, orelse_col: usize) ?[]const u8 {
    if (orelse_col == 0) return null;
    // Walk backward from "orelse" to find the variable name
    var end = orelse_col;
    // Skip whitespace before "orelse"
    while (end > 0 and t[end - 1] == ' ') end -= 1;
    if (end == 0) return null;
    // Walk backward through identifier chars (and dots for field access)
    var start = end;
    while (start > 0 and (isIdent(t[start - 1]) or t[start - 1] == '.'))
        start -= 1;
    if (start >= end) return null;
    const name = t[start..end];
    // Strip leading dot if present
    if (name.len > 0 and name[0] == '.') return name[1..];
    return name;
}

/// Check if a variable has a null guard earlier in the function
/// Patterns: "if (name == null) return/continue/break"
///           "if (name == null) { return/continue/break"
/// Check if a line or its successor has an early exit after a null check
fn hasNullCheckExit(line: []const u8, lines: []const []const u8, i: usize, limit: usize) bool {
    if (hasExitStatement(line)) return true;
    if (i + 1 >= limit) return false;
    const next = mem.trim(u8, lines[i + 1], " \t\r");
    return mem.startsWith(u8, next, "return") or
        mem.startsWith(u8, next, "continue") or
        mem.startsWith(u8, next, "break");
}

fn hasNullGuard(
    lines: []const []const u8,
    current_idx: usize,
    func_line: usize,
    name: []const u8,
) bool {
    _ = func_line;
    var i = current_idx;
    while (i > 0) {
        i -= 1;
        const line = mem.trim(u8, lines[i], " \t\r");
        if (isCommentOrMultilineString(line)) continue;
        if (mem.indexOf(u8, line, name) == null) continue;
        if (mem.indexOf(u8, line, "== null") == null) continue;
        if (hasNullCheckExit(line, lines, i, current_idx)) return true;
    }
    return false;
}

/// Extract variable name portion before a null-check keyword position
fn extractVarFromNullCheck(after_paren: []const u8, pos: usize) ?[]const u8 {
    const var_part = mem.trim(u8, after_paren[0..pos], " \t");
    if (var_part.len > 0 and isIdent(var_part[0])) return var_part;
    return null;
}

/// Extract variable name from null check pattern
/// Patterns: "if (x != null)", "if (x) |_|", "while (x != null)"
/// Also handles early return: "if (x == null) return" (negated check)
fn extractNullCheckedVar(t: []const u8) ?[]const u8 {
    // Find opening paren
    const open_paren = mem.indexOf(u8, t, "(") orelse return null;
    const after_paren = t[open_paren + 1 ..];

    // Pattern: x != null
    if (mem.indexOf(u8, after_paren, " != null")) |ne_pos|
        if (extractVarFromNullCheck(after_paren, ne_pos)) |v| return v;

    // Pattern: x == null with early return/continue/break
    // Zig idiom: if (x == null) return; guarantees x is non-null after
    if (mem.indexOf(u8, after_paren, " == null)")) |eq_pos| {
        const has_exit = mem.indexOf(u8, t, "return") != null or
            mem.indexOf(u8, t, "continue") != null or
            mem.indexOf(u8, t, "break") != null;
        if (has_exit)
            if (extractVarFromNullCheck(after_paren, eq_pos)) |v| return v;
    }

    // Pattern: if (x) |_| - capture means x is non-null inside
    if (mem.indexOf(u8, after_paren, ") |")) |pipe_pos|
        if (extractVarFromNullCheck(after_paren, pipe_pos)) |v| return v;

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

/// Check if a line has `var_name == null)` pattern
fn hasNullEqualityCheck(ctx: []const u8, var_name: []const u8) bool {
    const var_pos = mem.indexOf(u8, ctx, var_name) orelse return false;
    const after = ctx[var_pos + var_name.len ..];
    return mem.startsWith(u8, after, " == null)") or
        mem.startsWith(u8, after, " == null )");
}

/// Check for early return null guard on prior lines
fn hasEarlyReturnNullGuard(
    lines: []const []const u8,
    current_idx: usize,
    var_name: []const u8,
) bool {
    const check_start = if (current_idx > 20) current_idx - 20 else 0;
    var i = current_idx;
    while (i > check_start) {
        i -= 1;
        const ctx = mem.trim(u8, lines[i], " \t\r");
        if (isCommentOrMultilineString(ctx)) continue;
        if (mem.indexOf(u8, ctx, "fn ") != null and mem.indexOf(u8, ctx, "(") != null) return false;
        if (!hasNullEqualityCheck(ctx, var_name)) continue;
        if (hasExitStatement(ctx)) return true;
        const check_end = @min(i + 4, current_idx);
        if (hasExitInFollowingBlock(lines, i + 1, check_end)) return true;
    }
    return false;
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

/// Phase 1: Identify guard patterns in each CFG block
/// Scan a range of lines for guard patterns, adding to the given map
fn scanLinesForGuards(
    allocator: Allocator,
    lines: []const []const u8,
    func_line: usize,
    start: usize,
    end: usize,
    guards: *std.StringHashMapUnmanaged(void),
) !void {
    for (start..end + 1) |line_num| {
        if (line_num < func_line) continue;
        const idx = line_num - func_line;
        if (idx >= lines.len) continue;
        const t = mem.trim(u8, lines[idx], " \t\r");
        if (isCommentOrMultilineString(t)) continue;
        const var_name = extractGuardedVar(t) orelse continue;
        try guards.put(allocator, var_name, {});
    }
}

fn collectBlockGuards(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    lines: []const []const u8,
    func_line: usize,
    guarded_per_block: []std.StringHashMapUnmanaged(void),
) !void {
    for (cfg.blocks.items, 0..) |block, bid| {
        if (block.start_line == 0 or block.start_line > block.end_line) continue;
        try scanLinesForGuards(
            allocator,
            lines,
            func_line,
            block.start_line,
            block.end_line,
            &guarded_per_block[bid],
        );
    }
}

/// Check if predecessor block has both true and false branch edges
fn hasBothBranches(cfg: *ControlFlowGraph, pred: usize) bool {
    var has_true: bool = false;
    var has_false: bool = false;
    for (cfg.edges.items) |e| {
        if (e.from == pred) {
            if (e.kind == .branch_true) has_true = true;
            if (e.kind == .branch_false) has_false = true;
        }
    }
    return has_true and has_false;
}

const PredInfo = struct { block: usize, via_true_branch: bool };

/// Intersect first predecessor's guards into the intersection set
fn initIntersectionFromPred(
    allocator: Allocator,
    intersection: *std.StringHashMapUnmanaged(void),
    guarded_per_block: []std.StringHashMapUnmanaged(void),
    pred_info: PredInfo,
    pred_has_both: bool,
) !void {
    var iter = guarded_per_block[pred_info.block].iterator();
    while (iter.next()) |entry| {
        if (pred_has_both and !pred_info.via_true_branch) continue;
        try intersection.put(allocator, entry.key_ptr.*, {});
    }
}

/// Remove guards from intersection not in a subsequent predecessor
fn narrowIntersection(
    allocator: Allocator,
    intersection: *std.StringHashMapUnmanaged(void),
    guarded_per_block: []std.StringHashMapUnmanaged(void),
    pred_info: PredInfo,
    pred_has_both: bool,
) !void {
    var to_remove = std.ArrayListUnmanaged([]const u8).empty;
    defer to_remove.deinit(allocator);
    var iter = intersection.iterator();
    while (iter.next()) |entry| {
        var has = guarded_per_block[pred_info.block].contains(entry.key_ptr.*);
        if (pred_has_both and !pred_info.via_true_branch) has = false;
        if (!has) try to_remove.append(allocator, entry.key_ptr.*);
    }
    for (to_remove.items) |key| _ = intersection.remove(key);
}

/// Collect predecessor block info for a given block ID
fn collectPredecessors(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    bid: usize,
) !std.ArrayListUnmanaged(PredInfo) {
    var preds = std.ArrayListUnmanaged(PredInfo).empty;
    for (cfg.edges.items) |edge| {
        if (edge.to != bid) continue;
        try preds.append(allocator, .{
            .block = edge.from,
            .via_true_branch = edge.kind == .branch_true,
        });
    }
    return preds;
}

/// Compute guard intersection from all predecessors of a block
fn computePredIntersection(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    guarded_per_block: []std.StringHashMapUnmanaged(void),
    preds: []const PredInfo,
) !std.StringHashMapUnmanaged(void) {
    var intersection: std.StringHashMapUnmanaged(void) = .empty;
    for (preds, 0..) |pi, i| {
        const both = hasBothBranches(cfg, pi.block);
        if (i == 0) {
            try initIntersectionFromPred(
                allocator,
                &intersection,
                guarded_per_block,
                pi,
                both,
            );
        } else {
            try narrowIntersection(
                allocator,
                &intersection,
                guarded_per_block,
                pi,
                both,
            );
        }
    }
    return intersection;
}

/// Merge intersection into a block's guard set, returning true if changed
fn mergeIntoBlock(
    allocator: Allocator,
    intersection: *std.StringHashMapUnmanaged(void),
    block_guards: *std.StringHashMapUnmanaged(void),
) !bool {
    var any_new = false;
    var iter = intersection.iterator();
    while (iter.next()) |entry| {
        const gop = try block_guards.getOrPut(allocator, entry.key_ptr.*);
        if (!gop.found_existing) any_new = true;
    }
    return any_new;
}

/// Phase 2: Propagate guard state through CFG (forward dataflow)
fn propagateGuardsThroughCFG(
    allocator: Allocator,
    cfg: *ControlFlowGraph,
    guarded_per_block: []std.StringHashMapUnmanaged(void),
) !void {
    var changed = true;
    var iterations: usize = 0;
    while (changed and iterations < 100) {
        changed = false;
        iterations += 1;
        for (cfg.blocks.items, 0..) |_, bid| {
            var preds = try collectPredecessors(allocator, cfg, bid);
            defer preds.deinit(allocator);
            if (preds.items.len == 0) continue;

            var intersection = try computePredIntersection(
                allocator,
                cfg,
                guarded_per_block,
                preds.items,
            );
            defer intersection.deinit(allocator);

            if (try mergeIntoBlock(
                allocator,
                &intersection,
                &guarded_per_block[bid],
            )) changed = true;
        }
    }
}

/// Check if a decrement is guarded by various patterns
fn isDecrementGuarded(
    t: []const u8,
    lines: []const []const u8,
    idx: usize,
    var_name: []const u8,
    guarded: *const std.StringHashMapUnmanaged(void),
) bool {
    if (guarded.contains(var_name)) return true;
    if (hasGuardOnLine(t, var_name)) return true;
    if (hasBreakGuardOnPriorLines(lines, idx, var_name)) return true;
    if (isSignedVarInContext(lines, idx, var_name)) return true;
    if (hasPairedIncrementInLines(lines[0..idx], var_name)) return true;
    if (isInComptimeBlock(lines, idx)) return true;
    if (hasAssertGeGuard(lines, idx, var_name)) return true;
    if (hasEnclosingVarGuard(lines, idx, var_name)) return true;
    if (hasElseBranchGuard(lines, idx)) return true;
    return false;
}

/// Check if array base.len is guarded via CFG
fn isArrayLenCFGGuarded(
    t: []const u8,
    guarded: *const std.StringHashMapUnmanaged(void),
) bool {
    const base = extractArrayBaseFromIndexArithmetic(t) orelse return false;
    var buf: [128]u8 = undefined;
    if (base.len + 4 > buf.len) return false;
    @memcpy(buf[0..base.len], base);
    @memcpy(buf[base.len..][0..4], ".len");
    return guarded.contains(buf[0 .. base.len + 4]);
}

/// Check if array index arithmetic is guarded by various patterns
fn isArrayIndexGuarded(
    t: []const u8,
    lines: []const []const u8,
    idx: usize,
    guarded: *const std.StringHashMapUnmanaged(void),
) bool {
    if (mem.indexOf(u8, t, "-|") != null) return true;
    if (hasIndexGuardOnLine(t)) return true;
    if (hasShortCircuitGuardOnPriorLines(lines, idx)) return true;
    if (isArrayLenCFGGuarded(t, guarded)) return true;
    if (hasEndsWithStartsWithGuard(lines, idx)) return true;
    if (hasElseBranchGuard(lines, idx)) return true;
    if (isInComptimeBlock(lines, idx)) return true;
    if (hasEarlyReturnLengthGuard(lines, idx, t)) return true;
    if (hasLoopInitGuard(lines, idx, t)) return true;
    if (hasEnclosingBlockGuard(lines, idx, t)) return true;
    return false;
}

/// ZA901: Check for unguarded decrement on a single line
fn checkDecrementOverflow(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    t: []const u8,
    lines: []const []const u8,
    idx: usize,
    line_num: usize,
    file_path: []const u8,
    guarded: *const std.StringHashMapUnmanaged(void),
    reported: *std.AutoHashMap(usize, void),
) !void {
    const col = mem.indexOf(u8, t, "-= 1") orelse return;
    if (isInsideString(t, col)) return;
    const var_name = extractDecrementVar(t, col) orelse return;
    if (isDecrementGuarded(t, lines, idx, var_name, guarded)) return;
    try issues.append(allocator, .{
        .file = file_path,
        .line = line_num,
        .col = col + 1,
        .severity = .warning,
        .rule = RULE_DECREMENT_WITHOUT_CHECK,
        .message = "decrement without overflow guard may panic",
        .help = "add guard (if/while/assert x > 0) " ++
            "or use saturating arithmetic (-|)",
    });
    try reported.put(line_num, {});
}

/// ZA903: Check for unguarded array index arithmetic
fn checkArrayIndexOverflow(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    t: []const u8,
    lines: []const []const u8,
    idx: usize,
    line_num: usize,
    file_path: []const u8,
    guarded: *const std.StringHashMapUnmanaged(void),
    reported: *std.AutoHashMap(usize, void),
) !void {
    const col = hasArrayIndexSubtraction(t) orelse return;
    if (isInsideString(t, col)) return;
    if (isArrayIndexGuarded(t, lines, idx, guarded)) return;
    try issues.append(allocator, .{
        .file = file_path,
        .line = line_num,
        .col = col + 1,
        .severity = .warning,
        .rule = RULE_INDEX_ARITHMETIC,
        .message = "arithmetic in array index may overflow",
        .help = "ensure index arithmetic cannot underflow" ++
            ", or use saturating subtraction -|",
    });
    try reported.put(line_num, {});
}

/// Phase 3: Check for unguarded panic patterns in a single block
fn checkPanicPatternsInBlock(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    lines: []const []const u8,
    func_line: usize,
    file_path: []const u8,
    block_start: usize,
    block_end: usize,
    guarded: *const std.StringHashMapUnmanaged(void),
    reported: *std.AutoHashMap(usize, void),
) !void {
    for (block_start..block_end + 1) |line_num| {
        if (line_num < func_line or reported.contains(line_num)) continue;
        const idx = line_num - func_line;
        if (idx >= lines.len) continue;
        const t = mem.trim(u8, lines[idx], " \t\r");
        if (isCommentOrMultilineString(t)) continue;
        if (mem.indexOf(u8, t, "testing.expect") != null) continue;
        try checkDecrementOverflow(
            allocator,
            issues,
            t,
            lines,
            idx,
            line_num,
            file_path,
            guarded,
            reported,
        );
        try checkArrayIndexOverflow(
            allocator,
            issues,
            t,
            lines,
            idx,
            line_num,
            file_path,
            guarded,
            reported,
        );
    }
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
    var issues: std.ArrayListUnmanaged(Issue) = .empty;

    const num_blocks = cfg.blocks.items.len;
    if (num_blocks == 0) return issues;

    var guarded_per_block = try allocator.alloc(
        std.StringHashMapUnmanaged(void),
        num_blocks,
    );
    defer {
        for (guarded_per_block) |*m| m.deinit(allocator);
        allocator.free(guarded_per_block);
    }
    for (guarded_per_block) |*m| m.* = .empty;

    try collectBlockGuards(allocator, cfg, lines, func_line, guarded_per_block);
    try propagateGuardsThroughCFG(allocator, cfg, guarded_per_block);

    var reported_lines = std.AutoHashMap(usize, void).init(allocator);
    defer reported_lines.deinit();

    for (cfg.blocks.items, 0..) |block, bid| {
        if (block.start_line == 0 or block.start_line > block.end_line) continue;
        try checkPanicPatternsInBlock(
            allocator,
            &issues,
            lines,
            func_line,
            file_path,
            block.start_line,
            block.end_line,
            &guarded_per_block[bid],
            &reported_lines,
        );
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

    // Pattern: x > variable or x >= variable (not just literal 0)
    // Handles: while (i > check_start), if (x > min_val)
    const var_guard_patterns = [_][]const u8{ "> ", ">= " };
    for (var_guard_patterns) |pattern| {
        if (mem.indexOf(u8, t, pattern)) |pos| {
            // Check that RHS is an identifier (not a literal 0 - already handled above)
            const rhs_start = pos + pattern.len;
            if (rhs_start < t.len and isIdent(t[rhs_start])) {
                // Extract LHS variable
                var end = pos;
                while (end > 0 and t[end - 1] == ' ') end -= 1;
                var start = end;
                while (start > 0 and (isIdent(t[start - 1]) or t[start - 1] == '.')) {
                    start -= 1;
                }
                if (start < end) return t[start..end];
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
        const var_pos = mem.indexOf(u8, ctx, var_name) orelse continue;
        const after_var = ctx[var_pos + var_name.len ..];
        for (signed_types) |stype| {
            if (mem.startsWith(u8, after_var, stype)) return true;
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
        const var_pos = mem.indexOf(u8, ctx, var_name) orelse continue;
        const after_var = ctx[var_pos + var_name.len ..];
        if (mem.startsWith(u8, after_var, " += 1") or mem.startsWith(u8, after_var, "+=1"))
            return true;
    }
    return false;
}

/// Check for short-circuit guard on prior lines (multi-line expressions)
/// Pattern: assert(offset == 0 or switch { .x => values[offset - 1] });
/// Based on Zig short-circuit evaluation - RHS only evaluated when LHS fails
fn hasShortCircuitPattern(ctx: []const u8) bool {
    const pats = [_][]const u8{ "== 0 or", "!= 0 and", "> 0 and" };
    for (pats) |p| {
        if (mem.indexOf(u8, ctx, p) != null) return true;
    }
    return false;
}

fn isFuncBoundary(ctx: []const u8) bool {
    return mem.indexOf(u8, ctx, "fn ") != null and
        mem.indexOf(u8, ctx, "(") != null;
}

/// Result from scanning a line for delimiter balance and guard match
const DelimScanResult = struct {
    close_parens: usize,
    close_braces: usize,
    found_guard: bool,
};

/// Scan a line's characters updating delimiter counts, checking for guard at unmatched open-paren
fn scanLineDelimiters(ctx: []const u8, parens: usize, braces: usize) DelimScanResult {
    var cp = parens;
    var cb = braces;
    for (ctx) |c| {
        if (c == ')') cp += 1;
        if (c == '(' and cp > 0) cp -= 1;
        if (c == '(' and cp == 0 and hasShortCircuitPattern(ctx))
            return .{ .close_parens = cp, .close_braces = cb, .found_guard = true };
        if (c == '}') cb += 1;
        if (c == '{' and cb > 0) cb -= 1;
    }
    return .{ .close_parens = cp, .close_braces = cb, .found_guard = false };
}

fn hasShortCircuitGuardOnPriorLines(lines: []const []const u8, current_idx: usize) bool {
    var close_parens: usize = 0;
    var close_braces: usize = 0;
    var line_idx = current_idx;

    while (line_idx > 0) {
        line_idx -= 1;
        const ctx = mem.trim(u8, lines[line_idx], " \t\r");
        if (isCommentOrMultilineString(ctx)) continue;
        const r = scanLineDelimiters(ctx, close_parens, close_braces);
        if (r.found_guard) return true;
        close_parens = r.close_parens;
        close_braces = r.close_braces;
        if ((close_parens > 0 or close_braces > 0) and
            hasShortCircuitPattern(ctx)) return true;
        if (close_parens == 0 and close_braces == 0 and
            ctx.len > 0 and ctx[ctx.len - 1] == ';') break;
        if (isFuncBoundary(ctx)) break;
    }
    return false;
}

/// Check for endsWith/startsWith guard on prior lines
/// Zig semantics: mem.endsWith(str, suffix) implies str.len >= suffix.len
/// Pattern: assert(mem.endsWith(var, "X")) on prior line protects var.len - "X".len
fn hasEndsWithStartsWithGuard(lines: []const []const u8, current_idx: usize) bool {
    // Look back within the same block (up to function boundary)
    const check_start = if (current_idx > 10) current_idx - 10 else 0;
    for (lines[check_start..current_idx]) |line| {
        const ctx = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(ctx)) continue;
        // Stop at function boundary
        if (mem.indexOf(u8, ctx, "fn ") != null and mem.indexOf(u8, ctx, "(") != null) return false;

        // Check for endsWith or startsWith patterns in assert
        // Pattern: assert(mem.endsWith(...)) or std.debug.assert(std.mem.endsWith(...))
        if (mem.indexOf(u8, ctx, "endsWith(") != null or
            mem.indexOf(u8, ctx, "startsWith(") != null)
        {
            // If there's an assert on this line, it's a guard
            if (mem.indexOf(u8, ctx, "assert(") != null) return true;
            if (mem.indexOf(u8, ctx, "assert (") != null) return true;
            // Also check for conditional early returns: if (!endsWith) return;
            if (mem.indexOf(u8, ctx, "return") != null) return true;
        }
    }
    return false;
}

/// Check for break/continue guard on prior lines within same loop body
/// Pattern: while (true) { if (x == 0) break; x -= 1; }
/// Based on Zig control flow semantics - break/continue/return exits prevent reaching decrement
/// Check if a line starts a loop keyword (at same or outer scope level)
fn isLoopBoundary(ctx: []const u8) bool {
    if (mem.startsWith(u8, ctx, "while ") or mem.startsWith(u8, ctx, "while(")) return true;
    if (mem.startsWith(u8, ctx, "for ") or mem.startsWith(u8, ctx, "for(")) return true;
    return false;
}

/// Check if a line has an exit statement (break/continue/return)
fn hasExitStatement(ctx: []const u8) bool {
    if (mem.indexOf(u8, ctx, "break") != null) return true;
    if (mem.indexOf(u8, ctx, "continue") != null) return true;
    if (mem.indexOf(u8, ctx, "return") != null) return true;
    return false;
}

/// Check if a multi-line block following a guard has an exit statement
fn hasExitInFollowingBlock(lines: []const []const u8, start: usize, limit: usize) bool {
    var j = start;
    while (j < limit) : (j += 1) {
        const inner = mem.trim(u8, lines[j], " \t\r");
        if (hasExitStatement(inner)) return true;
        if (mem.eql(u8, inner, "}")) break;
    }
    return false;
}

fn trackBraceDepthBackward(ctx: []const u8, depth: i32) i32 {
    var d = depth;
    for (ctx) |c| {
        if (c == '}') d += 1;
        if (c == '{') d -= 1;
    }
    return d;
}

fn isZeroCheckGuard(
    ctx: []const u8,
    var_name: []const u8,
    lines: []const []const u8,
    line_idx: usize,
    current_idx: usize,
) bool {
    if (mem.indexOf(u8, ctx, var_name) == null) return false;
    if (mem.indexOf(u8, ctx, "== 0)") == null) return false;
    if (hasExitStatement(ctx)) return true;
    const block_end = if (line_idx + 6 < current_idx) line_idx + 6 else current_idx;
    return hasExitInFollowingBlock(lines, line_idx + 1, block_end);
}

fn hasBreakGuardOnPriorLines(
    lines: []const []const u8,
    current_idx: usize,
    var_name: []const u8,
) bool {
    const check_start = if (current_idx > 10) current_idx - 10 else 0;
    var brace_depth: i32 = 0;
    var i = current_idx;
    while (i > check_start) {
        i -= 1;
        const ctx = mem.trim(u8, lines[i], " \t\r");
        if (isCommentOrMultilineString(ctx)) continue;
        brace_depth = trackBraceDepthBackward(ctx, brace_depth);
        if (isFuncBoundary(ctx)) return false;
        if (brace_depth >= 0 and isLoopBoundary(ctx)) return false;
        if (isZeroCheckGuard(ctx, var_name, lines, i, current_idx)) return true;
    }
    return false;
}

/// Check if current line is inside a comptime block
/// Comptime code is evaluated at compile time - the compiler catches overflow errors
fn isInComptimeBlock(lines: []const []const u8, current_idx: usize) bool {
    var brace_depth: i32 = 0;
    var i = current_idx;
    while (i > 0) {
        i -= 1;
        const ctx = mem.trim(u8, lines[i], " \t\r");
        if (isCommentOrMultilineString(ctx)) continue;
        // Count braces going backward
        for (ctx) |c| {
            if (c == '}') brace_depth += 1;
            if (c == '{') brace_depth -= 1;
        }
        // If we're at negative depth, we're inside an enclosing block
        if (brace_depth < 0) {
            // Check if this line contains "comptime" before the opening brace
            if (mem.indexOf(u8, ctx, "comptime") != null) return true;
            // Reset - we're inside a non-comptime block
            return false;
        }
        // Stop at function boundary
        if (mem.indexOf(u8, ctx, "fn ") != null and mem.indexOf(u8, ctx, "(") != null) return false;
    }
    return false;
}

/// Check for assert(var >= n) on prior lines as guard for var -= n
/// Pattern: assert(item.meta.ref >= n); ... item.meta.ref -= n;
fn hasAssertGeGuard(lines: []const []const u8, current_idx: usize, var_name: []const u8) bool {
    const check_start = if (current_idx > 5) current_idx - 5 else 0;
    for (lines[check_start..current_idx]) |line| {
        const ctx = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(ctx)) continue;
        if (mem.indexOf(u8, ctx, "fn ") != null and mem.indexOf(u8, ctx, "(") != null) return false;

        // Check for assert(var >= ...) pattern
        if (mem.indexOf(u8, ctx, "assert") != null and mem.indexOf(u8, ctx, var_name) != null) {
            if (mem.indexOf(u8, ctx, ">=") != null) return true;
            if (mem.indexOf(u8, ctx, "> ") != null) return true;
        }
    }
    return false;
}

/// Check if a line has a .len comparison guard pattern
fn hasLenGuardPattern(ctx: []const u8) bool {
    const len_guard_pats = [_][]const u8{ "< ", "<= ", "== 0", "== 1" };
    for (len_guard_pats) |pat| {
        if (mem.indexOf(u8, ctx, pat) != null) return true;
    }
    return false;
}

/// Check for early-return length guards that protect array index arithmetic
fn isLenGuardLine(ctx: []const u8) bool {
    if (mem.indexOf(u8, ctx, ".len") == null) return false;
    return lineHasIf(ctx) and hasLenGuardPattern(ctx);
}

fn hasEarlyReturnLengthGuard(
    lines: []const []const u8,
    current_idx: usize,
    current_line: []const u8,
) bool {
    _ = current_line;
    const check_start = if (current_idx > 30) current_idx - 30 else 0;
    var i = check_start;
    while (i < current_idx) : (i += 1) {
        const ctx = mem.trim(u8, lines[i], " \t\r");
        if (isCommentOrMultilineString(ctx)) continue;
        if (isFuncBoundary(ctx)) return false;
        if (!isLenGuardLine(ctx)) continue;
        if (hasExitStatement(ctx)) return true;
        const block_end = if (i + 6 < current_idx) i + 6 else current_idx;
        if (hasExitInFollowingBlock(lines, i + 1, block_end)) return true;
    }
    return false;
}

/// Extract index variable and subtrahend from [VAR - N] pattern
const IdxSub = struct { idx_var: []const u8, subtrahend: usize };

fn extractIndexSubtraction(line: []const u8) ?IdxSub {
    const bpos = mem.indexOf(u8, line, "[") orelse return null;
    const spos = mem.indexOf(u8, line, " - ") orelse return null;
    if (spos <= bpos) return null;
    const idx_var = mem.trim(u8, line[bpos + 1 .. spos], " ");
    if (idx_var.len == 0 or !isIdent(idx_var[0])) return null;
    var sub_end = spos + 3;
    while (sub_end < line.len and
        line[sub_end] >= '0' and line[sub_end] <= '9')
    {
        sub_end += 1;
    }
    if (sub_end == spos + 3) return null;
    const val = std.fmt.parseInt(
        usize,
        line[spos + 3 .. sub_end],
        10,
    ) catch return null;
    return .{ .idx_var = idx_var, .subtrahend = val };
}

/// Check if init value after = is >= subtrahend (direct or via + offset)
fn initValueExceedsSubtrahend(ctx: []const u8, subtrahend: usize) bool {
    const eq_pos = mem.lastIndexOf(u8, ctx, "= ") orelse return false;
    const after_eq = mem.trim(u8, ctx[eq_pos + 2 ..], " ;");
    if (after_eq.len == 0) return false;
    if (after_eq[0] >= '0' and after_eq[0] <= '9') {
        const init_val = std.fmt.parseInt(usize, after_eq, 10) catch return false;
        if (init_val >= subtrahend) return true;
    }
    if (mem.indexOf(u8, after_eq, "+ ")) |plus_pos| {
        const after_plus = mem.trim(u8, after_eq[plus_pos + 2 ..], " ;");
        if (after_plus.len > 0 and after_plus[0] >= '0' and after_plus[0] <= '9') {
            const offset = std.fmt.parseInt(usize, after_plus, 10) catch return false;
            if (offset >= subtrahend) return true;
        }
    }
    return false;
}

/// Check if loop initialization guarantees minimum index value
fn hasLoopInitGuard(lines: []const []const u8, current_idx: usize, current_line: []const u8) bool {
    const info = extractIndexSubtraction(current_line) orelse return false;
    const check_start = if (current_idx > 20) current_idx - 20 else 0;
    for (lines[check_start..current_idx]) |line| {
        const ctx = mem.trim(u8, line, " \t\r");
        if (isCommentOrMultilineString(ctx)) continue;
        if (mem.indexOf(u8, ctx, "fn ") != null and mem.indexOf(u8, ctx, "(") != null) return false;

        const has_var = mem.indexOf(u8, ctx, "var ") != null;
        const has_const = mem.indexOf(u8, ctx, "const ") != null;
        const has_decl = has_var or has_const;
        if (!has_decl) continue;
        if (mem.indexOf(u8, ctx, info.idx_var) == null) continue;
        if (mem.indexOf(u8, ctx, "= ") == null) continue;
        if (initValueExceedsSubtrahend(ctx, info.subtrahend)) return true;
    }
    return false;
}

/// Extract the subtraction variable from an array index pattern [VAR - N]
/// Returns the variable name between [ and -
fn extractIndexSubVar(t: []const u8) ?[]const u8 {
    const bracket_pos = mem.indexOf(u8, t, "[") orelse return null;
    const sub_pos = mem.indexOf(u8, t, " - ") orelse return null;
    if (sub_pos <= bracket_pos) return null;
    const idx_var = mem.trim(u8, t[bracket_pos + 1 .. sub_pos], " ");
    if (idx_var.len == 0 or !isIdent(idx_var[0])) return null;
    // Make sure it's a simple identifier (no dots for .len which are handled elsewhere)
    return idx_var;
}

/// Check if a line has a conditional (if/while) with comparison guard for a variable
fn hasConditionalGuardForVar(ctx: []const u8, var_name: []const u8) bool {
    if (mem.indexOf(u8, ctx, var_name) == null) return false;
    const has_cond = mem.indexOf(u8, ctx, "if ") != null or
        mem.indexOf(u8, ctx, "if(") != null or
        mem.indexOf(u8, ctx, "while ") != null or
        mem.indexOf(u8, ctx, "while(") != null;
    if (!has_cond) return false;
    return hasComparisonGuardPattern(ctx);
}

/// Walk backwards through enclosing blocks, checking for a guarded variable
fn hasEnclosingGuardForVar(
    lines: []const []const u8,
    current_idx: usize,
    var_name: []const u8,
) bool {
    var brace_depth: i32 = 0;
    var i = current_idx;
    while (i > 0) {
        i -= 1;
        const ctx = mem.trim(u8, lines[i], " \t\r");
        if (isCommentOrMultilineString(ctx)) continue;
        for (ctx) |c| {
            if (c == '}') brace_depth += 1;
            if (c == '{') brace_depth -= 1;
        }
        if (brace_depth < 0) {
            if (hasConditionalGuardForVar(ctx, var_name)) return true;
            brace_depth = 0;
        }
        if (mem.indexOf(u8, ctx, "fn ") != null and mem.indexOf(u8, ctx, "(") != null) return false;
    }
    return false;
}

/// Check if current line is inside an enclosing block guarded by if/while (var > 0)
fn hasEnclosingBlockGuard(
    lines: []const []const u8,
    current_idx: usize,
    current_line: []const u8,
) bool {
    const sub_var = extractIndexSubVar(current_line) orelse return false;
    return hasEnclosingGuardForVar(lines, current_idx, sub_var);
}

/// Check if current line is inside an enclosing block guarded by if/while (var > 0) for decrements
fn hasEnclosingVarGuard(lines: []const []const u8, current_idx: usize, var_name: []const u8) bool {
    return hasEnclosingGuardForVar(lines, current_idx, var_name);
}

/// Check if bracket contents are a safe zero-based range pattern [0 .. x - N]
fn isSafeZeroBasedRange(inside: []const u8) bool {
    const range_pos = mem.indexOf(u8, inside, "..") orelse return false;
    const sub_pos = mem.indexOf(u8, inside, " - ") orelse return false;
    if (sub_pos <= range_pos) return false;
    return mem.eql(u8, mem.trim(u8, inside[0..range_pos], " "), "0");
}

/// Check for array index subtraction pattern [x - y]
/// Returns position of subtraction if unsafe, null if safe or not found
fn hasArrayIndexSubtraction(t: []const u8) ?usize {
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (t[i] != '[') continue;
        const end = findMatchingBracket(t, i) orelse continue;
        const inside = t[i + 1 .. end];
        if (isSafeZeroBasedRange(inside)) {
            i = end;
            continue;
        }
        if (mem.indexOf(u8, inside, " - ")) |sub_pos| {
            return i + sub_pos + 1;
        }
        i = end;
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

/// Check for else/else-if branch guards
/// Check if a line contains an if statement
fn lineHasIf(ctx: []const u8) bool {
    return mem.indexOf(u8, ctx, "if (") != null or mem.indexOf(u8, ctx, "if(") != null;
}

/// Check if an if-condition line has comparison patterns that imply a guard in the else branch
fn ifConditionImpliesElseGuard(if_ctx: []const u8) bool {
    if (!lineHasIf(if_ctx)) return false;
    const guard_pats = [_][]const u8{ ".len < ", " < ", ".len <= ", " <= ", "== 0)", "== 0 " };
    for (guard_pats) |pat| {
        if (mem.indexOf(u8, if_ctx, pat) != null) return true;
    }
    return false;
}

/// Check if an if-condition line has comparison patterns for else-if guards
fn ifConditionImpliesElseIfGuard(if_ctx: []const u8) bool {
    if (!lineHasIf(if_ctx)) return false;
    return mem.indexOf(u8, if_ctx, " <= ") != null or mem.indexOf(u8, if_ctx, " < ") != null;
}

/// Search backward from a line to find the matching if-statement, counting braces
fn findMatchingIfLine(lines: []const []const u8, start_idx: usize) ?[]const u8 {
    var depth: i32 = 1;
    var j = start_idx;
    while (j > 0 and depth > 0) {
        j -= 1;
        const ctx = mem.trim(u8, lines[j], " \t\r");
        if (isCommentOrMultilineString(ctx)) continue;
        for (ctx) |c| {
            if (c == '}') depth += 1;
            if (c == '{') depth -= 1;
        }
        if (depth == 0) return ctx;
    }
    return null;
}

/// Check if the line is an else block opener
fn isElseBlock(ctx: []const u8) bool {
    return mem.indexOf(u8, ctx, "} else ") != null or mem.indexOf(u8, ctx, "} else{") != null;
}

/// Check if the line is an else-if block opener
fn isElseIfBlock(ctx: []const u8) bool {
    return mem.indexOf(u8, ctx, "} else if") != null or mem.indexOf(u8, ctx, "}else if") != null;
}

/// Pattern: if (x < N) { ... } else { ... } - in else branch, x >= N is guaranteed
fn checkElseGuardForCtx(lines: []const []const u8, ctx: []const u8, i: usize) bool {
    if (isElseBlock(ctx)) {
        const if_ctx = findMatchingIfLine(lines, i) orelse return false;
        return ifConditionImpliesElseGuard(if_ctx);
    }
    if (isElseIfBlock(ctx)) {
        const if_ctx = findMatchingIfLine(lines, i) orelse return false;
        return ifConditionImpliesElseIfGuard(if_ctx);
    }
    return false;
}

fn countCurlyBalance(line: []const u8) i32 {
    var b: i32 = 0;
    for (line) |c| {
        if (c == '{') b += 1;
        if (c == '}') b -= 1;
    }
    return b;
}

fn hasElseBranchGuard(lines: []const []const u8, current_idx: usize) bool {
    var brace_depth: i32 = 0;
    var i = current_idx;
    while (i > 0) {
        i -= 1;
        const ctx = mem.trim(u8, lines[i], " \t\r");
        if (isCommentOrMultilineString(ctx)) continue;
        brace_depth += countCurlyBalance(ctx);
        if (brace_depth <= 0) continue;
        return checkElseGuardForCtx(lines, ctx, i);
    }
    return false;
}

/// Check for index guard patterns on same line
/// Check for basic short-circuit or loop guard patterns on a line
fn hasBasicIndexGuard(t: []const u8) bool {
    if (mem.indexOf(u8, t, "while") != null and mem.indexOf(u8, t, "> 0") != null) return true;
    const basic_pats = [_][]const u8{ "== 0 or", "!= 0 and", "!=0 and", "endsWith", "startsWith" };
    for (basic_pats) |pat| {
        if (mem.indexOf(u8, t, pat) != null) return true;
    }
    return false;
}

/// Check for comparison guard combined with `and` keyword
fn hasAndComparisonGuard(t: []const u8) bool {
    if (mem.indexOf(u8, t, " and ") == null) return false;
    const cmp_pats = [_][]const u8{ " > ", " >= ", " != " };
    for (cmp_pats) |pat| {
        if (mem.indexOf(u8, t, pat) != null) return true;
    }
    return false;
}

/// Check for if-else expression guard patterns
fn hasIfElseExprGuard(t: []const u8) bool {
    if (mem.indexOf(u8, t, " else ") == null) return false;
    if (!lineHasIf(t)) return false;
    if (mem.indexOf(u8, t, ".len < ") != null) return true;
    if (mem.indexOf(u8, t, ".len <= ") != null) return true;
    return hasComparisonBeforeElse(t);
}

/// Check if a comparison operator appears before the else keyword
fn hasComparisonBeforeElse(t: []const u8) bool {
    const else_pos = mem.indexOf(u8, t, " else ") orelse return false;
    const ops = [_][]const u8{ "== 0)", " < ", " <= " };
    for (ops) |op| {
        if (mem.indexOf(u8, t, op)) |pos| {
            if (pos < else_pos) return true;
        }
    }
    return false;
}

fn hasIndexGuardOnLine(t: []const u8) bool {
    if (hasBasicIndexGuard(t)) return true;
    if (hasAndComparisonGuard(t)) return true;
    if (mem.indexOf(u8, t, "if (") != null) {
        if (mem.indexOf(u8, t, "> ") != null or mem.indexOf(u8, t, ">= ") != null) return true;
    }
    return hasIfElseExprGuard(t);
}

/// ZA801/ZA802: Detect unsafe optional unwrapping (legacy line-based - kept for comparison)
fn analyzeNullSafety(
    allocator: Allocator,
    graph: *ImportGraph,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
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
/// Check if there's a guard on surrounding lines for a variable
fn hasGuardInContext(
    t: []const u8,
    context_lines: []const []const u8,
    current_idx: usize,
    var_name: []const u8,
) bool {
    if (hasGuardOnLine(t, var_name)) return true;
    const check_start = if (current_idx > 5) current_idx - 5 else 0;
    for (context_lines[check_start..current_idx]) |ctx_line| {
        const ctx = mem.trim(u8, ctx_line, " \t\r");
        if (hasGuardOnLine(ctx, var_name)) return true;
    }
    return false;
}

/// Check if decrement is safe due to type, pairing, comptime, or enclosing guards
fn isDecrementSafe(
    context_lines: []const []const u8,
    current_idx: usize,
    var_name: []const u8,
) bool {
    const cs = if (current_idx > 10) current_idx - 10 else 0;
    if (isSignedTypeDecl(context_lines[cs .. current_idx + 1], var_name)) return true;
    if (hasPairedIncrement(context_lines[0..current_idx], var_name)) return true;
    if (isInComptimeBlock(context_lines, current_idx)) return true;
    if (hasAssertGeGuard(context_lines, current_idx, var_name)) return true;
    if (hasEnclosingVarGuard(context_lines, current_idx, var_name)) return true;
    if (hasElseBranchGuard(context_lines, current_idx)) return true;
    return false;
}

fn checkDecrementWithoutGuard(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    t: []const u8,
    line_num: usize,
    context_lines: []const []const u8,
    current_idx: usize,
) !void {
    const decrement_patterns = [_][]const u8{ "-= 1", " -= 1" };
    for (decrement_patterns) |pattern| {
        const col = mem.indexOf(u8, t, pattern) orelse continue;
        if (isInsideString(t, col)) continue;
        const var_name = extractDecrementVar(t, col) orelse continue;

        if (hasGuardInContext(t, context_lines, current_idx, var_name)) continue;
        if (isDecrementSafe(context_lines, current_idx, var_name)) continue;

        try issues.append(allocator, .{
            .file = path,
            .line = line_num,
            .col = col + 1,
            .severity = .warning,
            .rule = RULE_DECREMENT_WITHOUT_CHECK,
            .message = "decrement without overflow guard may panic",
            .help = "add guard (if/while/assert x > 0), " ++
                "use saturating arithmetic (-|), " ++
                "or document caller contract",
        });
        return;
    }
}

/// Check if there's a paired increment for a variable (x += 1 before x -= 1)
/// or if the variable was initialized to a positive value (x = 1, x = N > 0)
/// Check if after_var text matches an increment pattern (x += 1, x = ... + 1)
fn isIncrementPattern(after_var: []const u8) bool {
    return mem.startsWith(u8, after_var, " += 1") or
        mem.startsWith(u8, after_var, "+=1") or
        mem.startsWith(u8, after_var, " += 1;") or
        (mem.startsWith(u8, after_var, " = ") and
            mem.indexOf(u8, after_var, "+ 1") != null);
}

/// Check if a var/const declaration has a positive initial value
fn isPositiveInit(ctx: []const u8, after_var: []const u8) bool {
    if (!mem.startsWith(u8, ctx, "var ") and !mem.startsWith(u8, ctx, "const "))
        return false;
    return mem.indexOf(u8, after_var, "= 1") != null or
        mem.indexOf(u8, after_var, "= 2") != null or
        mem.indexOf(u8, after_var, "= 3") != null or
        mem.indexOf(u8, after_var, ": usize = 1") != null or
        mem.indexOf(u8, after_var, ":usize = 1") != null;
}

fn hasPairedIncrement(context_lines: []const []const u8, var_name: []const u8) bool {
    var i = context_lines.len;
    while (i > 0) {
        i -= 1;
        const ctx = mem.trim(u8, context_lines[i], " \t\r");
        if (isFuncBoundary(ctx)) return false;
        const var_pos = mem.indexOf(u8, ctx, var_name) orelse continue;
        const after_var = ctx[var_pos + var_name.len ..];
        if (isIncrementPattern(after_var)) return true;
        if (isPositiveInit(ctx, after_var)) return true;
    }
    return false;
}

/// Check if variable is declared as a signed integer type in context
fn isSignedTypeDecl(context_lines: []const []const u8, var_name: []const u8) bool {
    const signed_types = [_][]const u8{ ": i8", ": i16", ": i32", ": i64", ": i128", ": isize" };
    for (context_lines) |ctx_line| {
        const ctx = mem.trim(u8, ctx_line, " \t\r");
        // Look for "var varname: iXX" or "const varname: iXX"
        const var_pos = mem.indexOf(u8, ctx, var_name) orelse continue;
        const after_var = ctx[var_pos + var_name.len ..];
        for (signed_types) |stype| {
            if (mem.startsWith(u8, after_var, stype)) return true;
        }
    }
    return false;
}

/// Common comparison patterns that guard against underflow
const guard_comparison_pats = [_][]const u8{
    "> 0", ">0", "> 1", ">1", ">= 1", ">=1", "!= 0", "!=0",
};

/// Check if line contains any comparison guard pattern
fn hasComparisonGuardPattern(line: []const u8) bool {
    for (guard_comparison_pats) |pat| {
        if (mem.indexOf(u8, line, pat) != null) return true;
    }
    return false;
}

/// Check if a line contains a guard for a variable
fn hasGuardOnLine(line: []const u8, var_name: []const u8) bool {
    if (mem.indexOf(u8, line, var_name) == null) return false;
    if (hasComparisonGuardPattern(line)) return true;
    if (mem.indexOf(u8, line, "while") != null and mem.indexOf(u8, line, ">") != null) return true;
    if (mem.indexOf(u8, line, "== 0") != null and hasExitStatement(line)) return true;
    if (mem.indexOf(u8, line, "== 0 or") != null) return true;
    if (mem.indexOf(u8, line, "assert") != null and hasComparisonGuardPattern(line)) return true;
    if (mem.indexOf(u8, line, "debug.assert") != null) {
        if (mem.indexOf(u8, line, ">") != null or mem.indexOf(u8, line, "!=") != null) return true;
    }
    return false;
}

/// Find the matching closing bracket, returning its index
fn findMatchingBracket(t: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var j = start + 1;
    while (j < t.len) : (j += 1) {
        if (t[j] == '[') depth += 1;
        if (t[j] == ']') {
            if (depth == 1) return j;
            depth -= 1;
        }
    }
    return null;
}

/// Check if current line has an inline subtraction guard (while/short-circuit)
fn hasInlineSubtractionGuard(t: []const u8) bool {
    if (mem.indexOf(u8, t, "while") != null and mem.indexOf(u8, t, "> 0") != null) return true;
    if (mem.indexOf(u8, t, "== 0 or") != null) return true;
    return false;
}

/// Check if context lines have a bounds-checking guard for subtraction
fn hasBoundsGuardInContext(context_lines: []const []const u8, current_idx: usize) bool {
    const check_start = if (current_idx > 5) current_idx - 5 else 0;
    const guard_pats = [_][]const u8{ ">=", "> ", ".len", "endsWith", "startsWith" };
    for (context_lines[check_start..current_idx]) |ctx_line| {
        const ctx = mem.trim(u8, ctx_line, " \t\r");
        for (guard_pats) |pat| {
            if (mem.indexOf(u8, ctx, pat) != null) return true;
        }
    }
    return false;
}

/// Check a bracket expression for unguarded subtraction
fn checkBracketSubtraction(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    t: []const u8,
    line_num: usize,
    context_lines: []const []const u8,
    current_idx: usize,
    bracket_start: usize,
    bracket_end: usize,
) !bool {
    const inside = t[bracket_start + 1 .. bracket_end];
    const sub_pos = mem.indexOf(u8, inside, " - ") orelse return false;
    if (mem.trim(u8, inside[0..sub_pos], " ").len == 0) return false;
    if (mem.indexOf(u8, inside, "-|") != null) return false;

    if (hasInlineSubtractionGuard(t)) return false;
    if (hasBoundsGuardInContext(context_lines, current_idx)) return false;

    try issues.append(allocator, .{
        .file = path,
        .line = line_num,
        .col = bracket_start + sub_pos + 2,
        .severity = .warning,
        .rule = RULE_INDEX_ARITHMETIC,
        .message = "arithmetic in array index may overflow",
        .help = "ensure index arithmetic cannot underflow, or use saturating subtraction -|",
    });
    return true;
}

/// Check for range subtraction: for (a..b - 1)
fn checkRangeSubtraction(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    t: []const u8,
    line_num: usize,
    context_lines: []const []const u8,
    current_idx: usize,
) !void {
    const range_pos = mem.indexOf(u8, t, "..") orelse return;
    const after_range = t[range_pos + 2 ..];
    const sub_in_range = mem.indexOf(u8, after_range, " - ") orelse return;
    if (mem.indexOf(u8, after_range[0..sub_in_range], ")") != null) return;

    const check_start = if (current_idx > 5) current_idx - 5 else 0;
    const range_guard_pats = [_][]const u8{ ">=", "> 0", "endsWith", "startsWith" };
    for (context_lines[check_start..current_idx]) |ctx_line| {
        const ctx = mem.trim(u8, ctx_line, " \t\r");
        for (range_guard_pats) |pat| {
            if (mem.indexOf(u8, ctx, pat) != null) return;
        }
        if (mem.indexOf(u8, ctx, "== 0") != null and mem.indexOf(u8, ctx, "return") != null) return;
    }

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

/// Check for subtraction that may overflow (ZA902)
fn checkSubtractionOverflow(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    path: []const u8,
    t: []const u8,
    line_num: usize,
    context_lines: []const []const u8,
    current_idx: usize,
) !void {
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (t[i] != '[') continue;
        const end = findMatchingBracket(t, i) orelse continue;
        const found = try checkBracketSubtraction(
            issues,
            allocator,
            path,
            t,
            line_num,
            context_lines,
            current_idx,
            i,
            end,
        );
        if (found) return;
        i = end;
    }
    try checkRangeSubtraction(issues, allocator, path, t, line_num, context_lines, current_idx);
}

/// ZA9xx: Detect potential panic/overflow patterns
fn analyzePanicPatterns(
    allocator: Allocator,
    graph: *ImportGraph,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    var iter = graph.files.iterator();

    while (iter.next()) |entry| {
        const file_path = entry.key_ptr.*;
        var line_num: usize = 1;
        var lines_list: std.ArrayListUnmanaged([]const u8) = .empty;
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

            try checkDecrementWithoutGuard(
                &issues,
                allocator,
                file_path,
                t,
                line_num,
                context_lines,
                idx,
            );
            try checkSubtractionOverflow(
                &issues,
                allocator,
                file_path,
                t,
                line_num,
                context_lines,
                idx,
            );
        }
    }

    return issues;
}

fn runFmtCheck(allocator: Allocator, path: []const u8) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .empty;

    const result = std.process.run(allocator, global_io.?, .{
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
        if (t.len == 0 or !mem.endsWith(u8, t, ".zig")) continue;
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

    return issues;
}

// ============================================================================
// Runtime Analysis (Dynamic Analysis via Test Execution)
// ============================================================================

/// Run tests with Zig's GeneralPurposeAllocator and parse memory diagnostics
fn parseCommandIntoArgv(cmd: []const u8, argv_buf: *[64][]const u8) usize {
    var in_quote = false;
    var start: usize = 0;
    var argc: usize = 0;
    for (cmd, 0..) |c, i| {
        if (c == '"' or c == '\'') {
            in_quote = !in_quote;
        } else if (c == ' ' and !in_quote and i > start) {
            argv_buf[argc] = cmd[start..i];
            argc += 1;
            start = i + 1;
        } else if (c == ' ' and !in_quote) {
            start = i + 1;
        }
    }
    if (start < cmd.len) {
        argv_buf[argc] = cmd[start..];
        argc += 1;
    }
    return argc;
}

fn buildRuntimeArgv(
    custom_command: ?[]const u8,
    argv_buf: *[64][]const u8,
    verbose: bool,
) usize {
    if (custom_command) |cmd| {
        if (verbose)
            std.debug.print("Running: {s} (with GPA diagnostics)\n", .{cmd});
        return parseCommandIntoArgv(cmd, argv_buf);
    }
    argv_buf[0] = "zig";
    argv_buf[1] = "build";
    argv_buf[2] = "test";
    if (verbose)
        std.debug.print("Running: zig build test (with GPA diagnostics)\n", .{});
    return 3;
}

fn reportCommandFailure(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    is_custom: bool,
) !void {
    const help_msg = if (is_custom)
        "check command output for details"
    else
        "run 'zig build test' to see details";
    try issues.append(allocator, .{
        .file = "build.zig",
        .line = 1,
        .col = 1,
        .severity = .err,
        .rule = RULE_RUNTIME_TEST_FAILURE,
        .message = "command failed",
        .help = help_msg,
    });
}

fn runRuntimeAnalysis(
    allocator: Allocator,
    path: []const u8,
    verbose: bool,
    custom_command: ?[]const u8,
) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    var argv_buf: [64][]const u8 = undefined;
    const argv_len = buildRuntimeArgv(custom_command, &argv_buf, verbose);

    const result = std.process.run(allocator, global_io.?, .{
        .argv = argv_buf[0..argv_len],
        .cwd = .{ .path = path },
        .stdout_limit = .limited(10 * 1024 * 1024),
        .stderr_limit = .limited(10 * 1024 * 1024),
    }) catch |err| {
        const cmd_str = custom_command orelse "zig build test";
        std.debug.print("error: cannot run {s}: {}\n", .{ cmd_str, err });
        return issues;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try parseGPADiagnostics(allocator, &issues, result.stderr, verbose);
    try parseTestOutput(allocator, &issues, result.stdout, verbose);

    if (result.term.exited != 0 and issues.items.len == 0)
        try reportCommandFailure(allocator, &issues, custom_command != null);

    return issues;
}

/// Check if line matches any of the given patterns (case-insensitive via pairs)
fn matchesAnyPattern(t: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pat| {
        if (mem.indexOf(u8, t, pat) != null) return true;
    }
    return false;
}

/// Emit a simple runtime issue (file=runtime, line=1)
fn emitRuntimeIssue(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    rule: []const u8,
    message: []const u8,
    help: []const u8,
) !void {
    try issues.append(allocator, .{
        .file = "runtime",
        .line = 1,
        .col = 1,
        .severity = .err,
        .rule = rule,
        .message = message,
        .help = help,
    });
}

/// Emit a runtime issue with file location extracted from the line
fn emitLocatedIssue(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
    t: []const u8,
    rule: []const u8,
    message: []const u8,
    help: []const u8,
) !void {
    const loc = extractFileLocation(t);
    try issues.append(allocator, .{
        .file = loc.file,
        .line = loc.line,
        .col = 1,
        .severity = .err,
        .rule = rule,
        .message = message,
        .help = help,
    });
}

/// Handle memory leak detection with next-line stack trace
fn handleMemoryLeak(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    line_iter: *mem.SplitIterator(u8, .scalar),
    verbose: bool,
    t: []const u8,
) !void {
    if (verbose) std.debug.print("GPA: {s}\n", .{t});
    var msg: []const u8 = "memory leak detected at runtime";
    var owned = false;
    const loc = if (line_iter.next()) |next_line|
        extractFileLocation(mem.trim(u8, next_line, " \t\r"))
    else
        FileLocation{ .file = "unknown", .line = 0 };
    if (loc.line > 0) {
        msg = try std.fmt.allocPrint(
            allocator,
            "memory leak at {s}:{d}",
            .{ loc.file, loc.line },
        );
        owned = true;
        if (verbose) std.debug.print("  at: {s}:{d}\n", .{ loc.file, loc.line });
    }
    try issues.append(allocator, .{
        .file = "runtime",
        .line = 1,
        .col = 1,
        .severity = .err,
        .rule = RULE_RUNTIME_MEMORY_LEAK,
        .message = msg,
        .help = "allocation not freed - check for missing defer or error path",
        .message_owned = owned,
    });
}

/// Parse GPA memory diagnostics from stderr
fn parseGPADiagnostics(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    stderr_output: []const u8,
    verbose: bool,
) !void {
    var line_iter = mem.splitScalar(u8, stderr_output, '\n');

    while (line_iter.next()) |line| {
        const t = mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;

        try classifyGPALine(allocator, issues, &line_iter, verbose, t);
    }
}

/// Classify and handle a single GPA diagnostic line
const GPAClassification = struct {
    patterns: []const []const u8,
    rule: []const u8,
    message: []const u8,
    help: []const u8,
    located: bool,
};

const gpa_classifications = [_]GPAClassification{
    .{
        .patterns = &.{ "double free", "Double free" },
        .rule = RULE_RUNTIME_DOUBLE_FREE,
        .message = "double free detected at runtime",
        .help = "memory freed twice - check defer order and error paths",
        .located = true,
    },
    .{
        .patterns = &.{ "use after free", "Use after free", "freed memory" },
        .rule = RULE_RUNTIME_USE_AFTER_FREE,
        .message = "use after free detected at runtime",
        .help = "accessing memory after it was freed",
        .located = true,
    },
    .{
        .patterns = &.{ "Invalid free", "invalid free" },
        .rule = RULE_RUNTIME_DOUBLE_FREE,
        .message = "invalid free detected - memory was not allocated",
        .help = "freeing memory that was never allocated or already freed",
        .located = true,
    },
    .{
        .patterns = &.{ "Segmentation fault", "segmentation fault", "SIGSEGV" },
        .rule = RULE_RUNTIME_PANIC,
        .message = "segmentation fault - invalid memory access",
        .help = "check for null pointer dereference, use after free, or buffer overflow",
        .located = false,
    },
    .{
        .patterns = &.{ "stack overflow", "Stack overflow" },
        .rule = RULE_RUNTIME_PANIC,
        .message = "stack overflow - infinite recursion or large stack allocation",
        .help = "check for unbounded recursion or use heap allocation for large data",
        .located = false,
    },
    .{
        .patterns = &.{ "OutOfMemory", "out of memory" },
        .rule = RULE_RUNTIME_PANIC,
        .message = "out of memory - allocation failed",
        .help = "check for memory leaks or reduce memory usage",
        .located = false,
    },
};

fn classifyGPALine(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    line_iter: *mem.SplitIterator(u8, .scalar),
    verbose: bool,
    t: []const u8,
) !void {
    const leak_pats = [_][]const u8{ "memory leak", "Memory leak", "leaked:" };
    if (matchesAnyPattern(t, &leak_pats))
        return handleMemoryLeak(allocator, issues, line_iter, verbose, t);
    for (gpa_classifications) |cls| {
        if (!matchesAnyPattern(t, cls.patterns)) continue;
        if (verbose) std.debug.print("GPA: {s}\n", .{t});
        if (cls.located) return emitLocatedIssue(
            issues,
            allocator,
            t,
            cls.rule,
            cls.message,
            cls.help,
        );
        return emitRuntimeIssue(issues, allocator, cls.rule, cls.message, cls.help);
    }
}

/// Parse test output for failures and panics
fn isPanicLine(t: []const u8) bool {
    if (mem.indexOf(u8, t, "panic:") != null) return true;
    return mem.indexOf(u8, t, "thread ") != null and
        mem.indexOf(u8, t, " panic:") != null;
}

fn emitTestIssue(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    t: []const u8,
    rule: []const u8,
    message: []const u8,
    help: []const u8,
) !void {
    const loc = extractFileLocation(t);
    try issues.append(allocator, .{
        .file = loc.file,
        .line = loc.line,
        .col = 1,
        .severity = .err,
        .rule = rule,
        .message = message,
        .help = help,
    });
}

fn handlePanicLine(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    t: []const u8,
    verbose: bool,
) !void {
    if (verbose) std.debug.print("PANIC: {s}\n", .{t});
    try emitTestIssue(
        allocator,
        issues,
        t,
        RULE_RUNTIME_PANIC,
        "panic detected during test execution",
        "runtime panic - check for integer overflow, null pointer, or unreachable",
    );
}

fn handleFailLine(
    allocator: Allocator,
    issues: *std.ArrayListUnmanaged(Issue),
    t: []const u8,
    verbose: bool,
) !void {
    if (verbose) std.debug.print("TEST FAIL: {s}\n", .{t});
    try emitTestIssue(
        allocator,
        issues,
        t,
        RULE_RUNTIME_TEST_FAILURE,
        "test failed",
        "check test assertions and expected values",
    );
}

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
        if (isPanicLine(t))
            try handlePanicLine(allocator, issues, t, verbose);
        if (mem.startsWith(u8, t, "FAIL"))
            try handleFailLine(allocator, issues, t, verbose);
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
                    const line_slice = text[file_end + 1 .. line_end];
                    const line_num = std.fmt.parseInt(usize, line_slice, 10) catch 0;
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

/// Default orphan exclusion path patterns (contains-match)
const orphan_exclude_dirs = [_][]const u8{
    "/test/",       "/tests/",   "/testing/",
    "/examples/",   "/example/", "/bench/",
    "/benchmarks/", "/demo/",    "/demos/",
    "/samples/",    "/tools/",   "/mods/",
    "/init/",       "/deps/",    "/vendor/",
    "/.packages/",  "/tool/",    "/user/",
    "/apps/",       "/app/",     "/cmd/",
};

/// Check if a path matches any of the orphan exclusion directory patterns
fn matchesOrphanDirPattern(path: []const u8) bool {
    for (orphan_exclude_dirs) |pat| {
        if (mem.indexOf(u8, path, pat) != null) return true;
    }
    return false;
}

/// Check if file path should be excluded from orphan detection
fn isOrphanExcluded(path: []const u8, cfg: *const Config) bool {
    if (cfg.orphan_exclude.items.len > 0) {
        for (cfg.orphan_exclude.items) |pattern| {
            if (mem.endsWith(u8, path, pattern)) return true;
            if (mem.indexOf(u8, path, pattern) != null) return true;
        }
        return false;
    }
    if (mem.endsWith(u8, path, "_test.zig")) return true;
    if (mem.endsWith(u8, path, "/build.zig")) return true;
    if (mem.eql(u8, path, "build.zig")) return true;
    if (mem.endsWith(u8, path, "/build_options.zig")) return true;
    return matchesOrphanDirPattern(path);
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

    // Skip any file with C translation markers (not just /deps/)
    // Auto-generated C bindings can be anywhere (e.g., capy's gtk.zig)
    if (mem.indexOf(u8, content, "__builtin_") != null or
        mem.indexOf(u8, content, "enum_unnamed_") != null or
        mem.indexOf(u8, content, "@cImport") != null)
    {
        return true;
    }
    return false;
}

/// Check if a line has an ignore/disable directive for rule
/// Supports: // ephor:ignore ZA201, // ephor:disable ZA201
/// Check if a single line contains an ephor:ignore or ephor:disable directive
/// that matches the given rule.
fn checkLineIgnore(line: []const u8, rule: []const u8) bool {
    const ignore_pos = mem.indexOf(u8, line, "// ephor:ignore");
    const disable_pos = mem.indexOf(u8, line, "// ephor:disable");
    const pos = ignore_pos orelse disable_pos orelse return false;
    _ = pos;
    // If the rule is mentioned, it's disabled
    if (mem.indexOf(u8, line, rule) != null) return true;
    // If no specific rule after directive, it disables all rules on this line
    // But not if it's a variant like "disable-next-line" or "ignore-file"
    const has_specific_ignore = mem.indexOf(u8, line, "ephor:ignore ") != null;
    const has_specific_disable = mem.indexOf(u8, line, "ephor:disable ") != null;
    const has_variant = mem.indexOf(u8, line, "ephor:disable-") != null;
    const has_file_ignore = mem.indexOf(u8, line, "ephor:ignore-file") != null;
    if (has_file_ignore) return false;
    if (has_specific_ignore or has_specific_disable or has_variant) return false;
    return true;
}

/// Check if a file-level ignore directive matches a rule.
fn checkFileIgnoreRule(line: []const u8, rule: []const u8) bool {
    if (mem.indexOf(u8, line, rule) != null) return true;
    if (mem.indexOf(u8, line, "ephor:ignore-file ")) |start_pos| {
        const after = line[start_pos + "ephor:ignore-file ".len ..];
        const trimmed = mem.trimStart(u8, after, " \t");
        if (trimmed.len > 0) return false;
    }
    return true;
}

/// Check if a line/block/file has an inline ignore directive for the given rule.
///
/// Supports three forms:
///   1. Same-line:  `code(); // ephor:ignore ZA201` — suppresses that line only
///   2. Scope-aware: `// ephor:ignore ZA201` on a comment-only line before a function
///      or block — automatically suppresses the entire scope (tracks braces)
///      If the next line doesn't open a scope, suppresses just the next line.
///   3. File-level: `// ephor:ignore-file ZA201` — suppresses entire file
fn isInlineDisabled(content: []const u8, line_num: usize, rule: []const u8) bool {
    // First pass: check for file-level ignores (can appear anywhere in file)
    var file_lines = mem.splitScalar(u8, content, '\n');
    while (file_lines.next()) |line| {
        if (mem.indexOf(u8, line, "ephor:ignore-file") != null) {
            if (checkFileIgnoreRule(line, rule)) return true;
        }
    }

    // Second pass: check same-line, previous-line, and scope-aware ignores
    var current_line: usize = 1;
    var lines = mem.splitScalar(u8, content, '\n');
    var prev_line: ?[]const u8 = null;
    // Track scope-aware ignore blocks: when a comment-only ignore line precedes
    // a line that opens a brace scope, we track depth until the scope closes.
    var scope_ignore_depth: usize = 0;
    var in_scope_ignore = false;
    while (lines.next()) |line| {
        defer {
            prev_line = line;
            current_line += 1;
        }

        // Track brace depth for scope-aware ignores
        if (in_scope_ignore) {
            for (line) |ch| {
                if (ch == '{') scope_ignore_depth += 1;
                if (ch == '}') {
                    if (scope_ignore_depth > 0) {
                        scope_ignore_depth -= 1;
                        if (scope_ignore_depth == 0) {
                            // Scope closed — this line is the last suppressed line
                            if (current_line == line_num) return true;
                            in_scope_ignore = false;
                            break;
                        }
                    }
                }
            }
            if (in_scope_ignore and current_line == line_num) return true;
            // Check if prev_line was a comment-only ignore that starts a new scope
            // (don't re-check, the scope tracking handles it)
            continue;
        }

        // Check if this is a comment-only ignore line that starts scope tracking
        if (prev_line) |pl| {
            const prev_trimmed = mem.trimStart(u8, pl, " \t");
            if (mem.startsWith(u8, prev_trimmed, "//") and checkLineIgnore(pl, rule)) {
                // Previous line has an ignore directive — check if THIS line opens a scope
                if (mem.indexOf(u8, line, "{") != null) {
                    // Count net brace depth on this line
                    scope_ignore_depth = 0;
                    for (line) |bch| {
                        if (bch == '{') scope_ignore_depth += 1;
                        if (bch == '}') {
                            if (scope_ignore_depth > 0) scope_ignore_depth -= 1;
                        }
                    }
                    if (scope_ignore_depth > 0) {
                        in_scope_ignore = true;
                    }
                    // This line is suppressed (it's the first line of the ignored scope)
                    if (current_line == line_num) return true;
                    continue;
                }
            }
        }

        if (current_line != line_num) continue;

        // Same-line: // ephor:ignore ZA201
        if (checkLineIgnore(line, rule)) return true;

        // Previous-line without scope: suppresses just this one line
        if (prev_line) |pl| {
            const prev_trimmed = mem.trimStart(u8, pl, " \t");
            if (mem.startsWith(u8, prev_trimmed, "//") and checkLineIgnore(pl, rule)) return true;
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
    export_path: ?[]const u8, // --export=<filepath> to save issues to file
    known_issues_path: ?[]const u8, // --known-issues=<filepath> to filter known true positives
    known_issues: std.ArrayListUnmanaged([]const u8), // Loaded known issues (file:line format)
    auto_approve: bool, // --yes: skip interactive confirmation prompts
    runtime_command: ?[]const u8, // --command=<cmd> for runtime analysis
    install_version: ?[]const u8, // --version=X.Y.Z for install/upgrade

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
        if (self.export_path) |p| allocator.free(p);
        if (self.known_issues_path) |p| allocator.free(p);
        for (self.known_issues.items) |k| allocator.free(k);
        self.known_issues.deinit(allocator);
        if (self.runtime_command) |c| allocator.free(c);
        if (self.install_version) |v| allocator.free(v);
    }

    /// Determine if a rule is enabled considering enable list and disable list
    /// Priority: explicit enable > explicit disable > defaults
    /// Check if a rule matches any entry in a list (exact or prefix)
    fn matchesRuleList(
        list: []const []const u8,
        rule: []const u8,
    ) bool {
        for (list) |entry| {
            if (mem.eql(u8, entry, rule)) return true;
            if (entry.len < rule.len and mem.startsWith(u8, rule, entry))
                return true;
        }
        return false;
    }

    /// Rules/prefixes that are OFF by default
    const off_by_default_prefixes = [_][]const u8{ "ZAV", "ZA8", "ZA9" };

    /// Check if a rule is off by default (prefix or exact match)
    fn isOffByDefault(self: *const Config, rule: []const u8) bool {
        _ = self;
        if (mem.eql(u8, rule, RULE_FILE_TOO_LONG))
            return true;
        for (off_by_default_prefixes) |prefix| {
            if (mem.startsWith(u8, rule, prefix)) return true;
        }
        if (mem.eql(u8, rule, RULE_IGNORED_ERROR)) return true;
        if (mem.eql(u8, rule, RULE_UNDEFINED_USAGE)) return true;
        return false;
    }

    fn isRuleEnabled(self: *const Config, rule: []const u8) bool {
        if (matchesRuleList(self.enabled_rules.items, rule)) return true;
        if (matchesRuleList(self.disabled_rules.items, rule)) return false;
        return !self.isOffByDefault(rule);
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
    const content = fs.cwd().readFileAlloc(allocator, CONFIG_FILENAME, 64 * 1024) catch return;
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

    const content = fs.cwd().readFileAlloc(allocator, config_path, 64 * 1024) catch return false;
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

/// Loads entries from config (CLI path takes priority over config "path_dir")
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
    if (mem.eql(u8, k, "max_lines") or mem.eql(u8, k, "max_function_lines")) th.max_function_lines = num;
    if (mem.eql(u8, k, "max_nesting")) th.max_nesting_depth = num;
    if (mem.eql(u8, k, "max_params")) th.max_params = num;
    if (mem.eql(u8, k, "max_branches")) th.max_branches = num;
    if (mem.eql(u8, k, "max_line_length")) th.max_line_length = num;
    if (mem.eql(u8, k, "max_file_bytes")) th.max_file_bytes = num;
    if (mem.eql(u8, k, "max_cyclomatic")) th.max_cyclomatic = num;
    if (mem.eql(u8, k, "max_cognitive")) th.max_cognitive = num;
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
        i = skipWhitespaceAndComments(content, i);
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
        i = skipWhitespaceAndComments(content, i);
        if (i >= content.len or content[i] == '}') break;
        i = parseThresholdPair(content, i, th);
    }
    return if (i < content.len) i + 1 else i;
}

/// Handle a single config key-value pair
fn handleConfigKey(
    allocator: Allocator,
    content: []const u8,
    start: usize,
    key: []const u8,
    cfg: *Config,
) !usize {
    const is_path_dir_key = mem.eql(u8, key, "path_dir") or
        mem.eql(u8, key, "code") or mem.eql(u8, key, "src") or mem.eql(u8, key, "root");
    if (is_path_dir_key and content[start] == '"') {
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

/// Skip a // line comment, returning the index after the newline (or content.len)
fn skipLineComment(content: []const u8, start: usize) usize {
    var i = start;
    while (i < content.len and content[i] != '\n') i += 1;
    return if (i < content.len) i + 1 else i;
}

/// Skip whitespace and // line comments (used during JSON config parsing)
fn skipWhitespaceAndComments(content: []const u8, start: usize) usize {
    var i = start;
    while (i < content.len) {
        const c = content[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ',') {
            i += 1;
        } else if (i + 1 < content.len and content[i] == '/' and content[i + 1] == '/') {
            i = skipLineComment(content, i + 2);
        } else {
            break;
        }
    }
    return i;
}

fn parseConfigJson(allocator: Allocator, content: []const u8, cfg: *Config) !void {
    var i: usize = 0;
    while (i < content.len and content[i] != '{') i += 1;
    if (i >= content.len) return;
    i += 1;
    while (i < content.len) {
        i = skipWhitespaceAndComments(content, i);
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

fn handleConfigCreateError(err: anyerror) !void {
    if (err == error.PathAlreadyExists) {
        std.debug.print("{s} already exists\n", .{CONFIG_FILENAME});
        return;
    }
    return err;
}

fn writeDefaultConfig() !void {
    const default_config =
        \\{
        \\  // Directory to analyze - auto-detected from build.zig during install
        \\  // (e.g., "src", "lib", "app", or "." for project root)
        \\  "path_dir": "src",
        \\
        \\  // Entry points for import graph analysis (orphan detection)
        \\  // Add your main files and build.zig here
        \\  "entries": ["src/main.zig", "build.zig"],
        \\
        \\  // Directories to exclude from analysis
        \\  "exclude": ["test", "vendor", "third_party"],
        \\
        \\  // Patterns to exclude from orphan detection only
        \\  "orphan_exclude": ["_test.zig", "/test/", "/tests/"],
        \\
        \\  // Rules to disable (by ID or category prefix)
        \\  // Examples: "ZA301" (single rule), "ZA3" (all complexity), "ZA7" (all style)
        \\  //
        \\  // Available rules:
        \\  //   ZA1xx Memory:     ZA101 alloc-no-defer, ZA102 create-no-defer,
        \\  //                     ZA103 alloc-no-errdefer,
        \\  //                     ZA105 use-after-free, ZA106 double-free
        \\  //   ZA2xx ErrHandle:  ZA201 silent-catch (note), ZA202 catch-unreachable (note),
        \\  //                     ZA203 orelse-unreachable (note), ZA204 undefined (note),
        \\  //                     ZA205 ignored-error (note), ZA206 exit-bypasses-defer,
        \\  //                     ZA207 catch-undefined, ZA208 panic (note)
        \\  //   ZA3xx Complexity: ZA301 func-too-long, ZA302 nesting-too-deep,
        \\  //                     ZA303 too-many-params, ZA304 too-many-branches,
        \\  //                     ZA305 cyclomatic, ZA306 cognitive
        \\  //   ZA4xx Unused:     ZA401 unused-import, ZA402 unused-const, ZA403 unused-var
        \\  //   ZA5xx Structure:  ZA501 orphan-file
        \\  //   ZA6xx Format:     ZA601 needs-format
        \\  //   ZA7xx Style:      ZA701 line-too-long, ZA702 file-too-long, ZA703 naming
        \\  //   ZA8xx NullSafety: ZA801 unsafe-optional-unwrap
        \\  //   ZA9xx Panic:      ZA901 decrement-overflow, ZA902 subtraction-overflow,
        \\  //                     ZA903 index-arithmetic
        \\  "disable": [],
        \\
        \\  // Rules to explicitly enable (overrides disable)
        \\  "enable": [],
        \\
        \\  // Configurable thresholds
        \\  "thresholds": {
        \\    "max_lines": 50,
        \\    "max_nesting": 3,
        \\    "max_params": 4,
        \\    "max_branches": 12,
        \\    "max_line_length": 100,
        \\    "max_cyclomatic": 15,
        \\    "max_cognitive": 15
        \\  }
        \\}
        \\
    ;

    fs.cwd().writeFile(CONFIG_FILENAME, default_config, .{ .exclusive = true }) catch |err| return handleConfigCreateError(err);
    std.debug.print("Created {s}\n", .{CONFIG_FILENAME});
}

/// Detect the path_dir from build.zig by finding root_source_file patterns.
/// Returns an allocator-owned string. Caller must free.
fn detectPathDirFromBuildZig(allocator: Allocator) []const u8 {
    const content = fs.cwd().readFileAlloc(
        allocator,
        "build.zig",
        1024 * 1024,
    ) catch |err| {
        std.debug.print(
            "error: no build.zig found: {}\n" ++
                "  hint: run from project root, or: ephor check <dir>\n",
            .{err},
        );
        return allocator.dupe(u8, ".") catch ".";
    };

    const result = findPathDirInContent(content);
    const duped = allocator.dupe(u8, result) catch {
        allocator.free(content);
        return allocator.dupe(u8, ".") catch ".";
    };
    allocator.free(content);
    return duped;
}

/// Scan build.zig content for root_source_file pattern, return dir portion.
/// Returns a slice into `content` - caller must dupe before freeing content.
fn findPathDirInContent(content: []const u8) []const u8 {
    const patterns = [_][]const u8{ "root_source_file", ".root_src" };
    var lines = mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        for (patterns) |pattern| {
            const pat_idx = mem.indexOf(u8, line, pattern) orelse continue;
            const rest = line[pat_idx..];
            const q1 = mem.indexOf(u8, rest, "\"") orelse continue;
            const after_q1 = q1 + 1;
            if (after_q1 >= rest.len) continue;
            const q2 = mem.indexOf(u8, rest[after_q1..], "\"") orelse continue;
            const path = rest[after_q1 .. after_q1 + q2];
            if (!mem.endsWith(u8, path, ".zig")) continue;
            if (std.fs.path.dirname(path)) |dir| return dir;
            return ".";
        }
    }
    std.debug.print(
        "warning: could not detect source directory from build.zig\n" ++
            "  hint: specify a path: ephor check <dir>, or create ephor.json with 'ephor init'\n",
        .{},
    );
    return ".";
}

/// Collect entry points from build.zig for the install config.
/// Returns entries as a list of strings (caller frees with allocator).
fn collectInstallEntries(
    allocator: Allocator,
    root_dir: []const u8,
) !std.ArrayListUnmanaged([]const u8) {
    var entries: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (entries.items) |e| allocator.free(e);
        entries.deinit(allocator);
    }

    var added = std.StringHashMap(void).init(allocator);
    defer added.deinit();

    // Add standard entry from root_source_file detection
    const main_path = if (mem.eql(u8, root_dir, "."))
        try allocator.dupe(u8, "main.zig")
    else
        try std.fmt.allocPrint(allocator, "{s}/main.zig", .{root_dir});

    const main_exists = blk: {
        fs.cwd().access(main_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (main_exists) {
        try added.put(main_path, {});
        try entries.append(allocator, main_path);
    } else {
        allocator.free(main_path);
    }

    // Always add build.zig as entry
    const build_zig = try allocator.dupe(u8, "build.zig");
    if (!added.contains(build_zig)) {
        try added.put(build_zig, {});
        try entries.append(allocator, build_zig);
    } else {
        allocator.free(build_zig);
    }

    return entries;
}

/// Create ephor.json during install with auto-detected path_dir and entries.
/// Returns the detected path_dir string (static, not owned) for display.
fn createInstallConfig(allocator: Allocator, ver: []const u8) ![]const u8 {
    // Don't overwrite existing config
    fs.cwd().access(CONFIG_FILENAME, .{}) catch {
        // File doesn't exist - create it
        const root_dir = detectPathDirFromBuildZig(allocator);
        var entries = try collectInstallEntries(allocator, root_dir);
        defer {
            for (entries.items) |e| allocator.free(e);
            entries.deinit(allocator);
        }

        // Build entries JSON array string
        var entries_json: std.ArrayListUnmanaged(u8) = .empty;
        defer entries_json.deinit(allocator);
        try entries_json.append(allocator, '[');
        for (entries.items, 0..) |entry, i| {
            if (i > 0) try entries_json.appendSlice(allocator, ", ");
            try entries_json.append(allocator, '"');
            try entries_json.appendSlice(allocator, entry);
            try entries_json.append(allocator, '"');
        }
        try entries_json.append(allocator, ']');

        // Write config with version field
        const config_content = try std.fmt.allocPrint(allocator,
            \\{{
            \\  // Installed ephor version
            \\  "version": "{s}",
            \\
            \\  // Directory to analyze - auto-detected from build.zig
            \\  // (e.g., "src", "lib", "app", or "." for project root)
            \\  "path_dir": "{s}",
            \\
            \\  // Entry points for import graph analysis (orphan detection)
            \\  "entries": {s},
            \\
            \\  // Directories to exclude from analysis
            \\  "exclude": ["test", "vendor", "third_party"],
            \\
            \\  // Patterns to exclude from orphan detection only
            \\  "orphan_exclude": ["_test.zig", "/test/", "/tests/"],
            \\
            \\  // Rules to disable (by ID or category prefix)
            \\  "disable": [],
            \\
            \\  // Rules to explicitly enable (overrides disable)
            \\  "enable": [],
            \\
            \\  // Configurable thresholds
            \\  "thresholds": {{
            \\    "max_lines": 50,
            \\    "max_nesting": 3,
            \\    "max_params": 4,
            \\    "max_branches": 12,
            \\    "max_line_length": 100,
            \\    "max_cyclomatic": 15,
            \\    "max_cognitive": 15
            \\  }}
            \\}}
            \\
        , .{ ver, root_dir, entries_json.items });
        defer allocator.free(config_content);

        try fs.cwd().writeFile(CONFIG_FILENAME, config_content, .{});

        std.debug.print("Created {s} (version: {s}, path_dir: {s})\n", .{
            CONFIG_FILENAME, ver, root_dir,
        });
        return root_dir;
    };
    // Config already exists - update version if needed
    updateConfigVersion(allocator, ver);
    std.debug.print("{s} already exists (skipped)\n", .{CONFIG_FILENAME});
    return "src";
}

/// Base URL for ephor repository (used to construct versioned package URLs)
const EPHOR_REPO_BASE = "https://codeberg.org/RhyosLabs/ephor";

/// Build a versioned package URL for install/upgrade.
/// If version is null, defaults to EPHOR_VERSION (the binary's own version).
/// Returns an allocated string that the caller must free.
fn buildPackageUrl(allocator: Allocator, ver: ?[]const u8) ![]const u8 {
    const v = ver orelse EPHOR_VERSION;
    return std.fmt.allocPrint(allocator, "{s}/archive/v{s}.tar.gz", .{ EPHOR_REPO_BASE, v });
}

/// Code snippet to add to build.zig
const EPHOR_BUILD_SNIPPET =
    \\
    \\    // === Ephor Static Analysis ===
    \\    const ephor_dep = b.dependency("ephor", .{
    \\        .target = target,
    \\        .optimize = .ReleaseSafe,
    \\    });
    \\    const ephor_exe = ephor_dep.artifact("ephor");
    \\    const ephor_step = b.step("ephor", "Run ephor static analysis");
    \\    ephor_step.dependOn(&b.addRunArtifact(ephor_exe).step);
    \\
;

/// Print instructions when build.zig.zon is missing during install.
fn printMissingProjectFileHelp(file: []const u8) void {
    std.debug.print(
        "error: no {s} found in current directory\n" ++
            "\n" ++
            "  Ephor requires a Zig project with build.zig and build.zig.zon.\n" ++
            "  To initialize a Zig project, run:\n" ++
            "\n" ++
            "    zig init\n" ++
            "\n" ++
            "  Then re-run the install:\n" ++
            "    curl -fsSL {s}/raw/main/install.sh | sh\n" ++
            "\n",
        .{ file, EPHOR_REPO_BASE },
    );
}

/// Print fallback instructions when zig fetch fails.
fn printFetchFailedHelp(package_url: []const u8) void {
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
    , .{package_url});
}

/// Run the install command: adds ephor to project's build system.
/// If install_version is provided, installs that specific version;
/// otherwise defaults to the binary's own version (EPHOR_VERSION).
/// Check that build.zig and build.zig.zon exist. Returns false
/// and prints help if either is missing.
fn checkProjectPrerequisites() bool {
    const has_build_zig = blk: {
        fs.cwd().access("build.zig", .{}) catch break :blk false;
        break :blk true;
    };
    if (!has_build_zig) {
        printMissingProjectFileHelp("build.zig");
        return false;
    }
    const has_zon = blk: {
        fs.cwd().access("build.zig.zon", .{}) catch break :blk false;
        break :blk true;
    };
    if (!has_zon) {
        printMissingProjectFileHelp("build.zig.zon");
        return false;
    }
    return true;
}

fn runInstallCommand(allocator: Allocator, install_version: ?[]const u8) !void {
    const ver = install_version orelse EPHOR_VERSION;

    if (!checkProjectPrerequisites()) return;

    const package_url = try buildPackageUrl(allocator, install_version);
    defer allocator.free(package_url);

    std.debug.print("Installing ephor v{s}...\n", .{ver});

    const url_z = try allocator.dupeZ(u8, package_url);
    defer allocator.free(url_z);

    var child = try std.process.spawn(global_io.?, .{
        .argv = &.{ "zig", "fetch", "--save=ephor", url_z },
    });
    const term = try child.wait(global_io.?);
    if (term.exited != 0) {
        printFetchFailedHelp(package_url);
        return;
    }

    std.debug.print("Added ephor v{s} to build.zig.zon\n\n", .{ver});

    const patched = patchBuildZig(allocator) catch |err| {
        std.debug.print("Could not auto-patch build.zig: {}\n", .{err});
        std.debug.print("\nAdd this to your build.zig manually:{s}\n", .{EPHOR_BUILD_SNIPPET});
        std.debug.print("Then run: zig build ephor\n", .{});
        return;
    };

    if (patched) |line| {
        std.debug.print("Added ephor step to build.zig at line {d}\n", .{line});
    } else {
        std.debug.print("Ephor step already exists in build.zig\n", .{});
    }

    _ = createInstallConfig(allocator, ver) catch |err| {
        std.debug.print("Could not create {s}: {}\n", .{ CONFIG_FILENAME, err });
    };

    std.debug.print("Run: zig build ephor\n", .{});
}

/// Patch build.zig to add ephor step. Returns line number
/// where inserted, or null if already exists.
/// Build function scan state for finding insertion point
const BuildFnScan = struct {
    last_install_artifact: ?usize = null,
    build_fn_end: ?usize = null,
    brace_depth: i32 = 0,
    in_build_fn: bool = false,
};

/// Scan build.zig lines for insertion point
fn findBuildZigInsertionPoint(line_items: []const []const u8) ?usize {
    var scan = BuildFnScan{};
    for (line_items, 0..) |line, idx| {
        const trimmed = mem.trim(u8, line, " \t");
        if (!scan.in_build_fn) {
            const is_build_fn = mem.indexOf(u8, trimmed, "pub fn build(") != null or
                mem.indexOf(u8, trimmed, "fn build(") != null;
            if (is_build_fn) scan.in_build_fn = true;
        }
        if (!scan.in_build_fn) continue;

        updateBuildFnScanBraces(&scan, trimmed, idx);
        if (mem.indexOf(u8, line, "installArtifact(") != null) scan.last_install_artifact = idx;
    }
    if (scan.last_install_artifact) |idx| return idx;
    if (scan.build_fn_end) |idx| return if (idx > 0) idx - 1 else 0;
    return null;
}

/// Track brace depth and detect build function end
fn updateBuildFnScanBraces(scan: *BuildFnScan, trimmed: []const u8, idx: usize) void {
    for (trimmed) |c| {
        if (c == '{') scan.brace_depth += 1;
        if (c == '}') {
            scan.brace_depth -= 1;
            if (scan.brace_depth == 0) {
                scan.build_fn_end = idx;
                scan.in_build_fn = false;
            }
        }
    }
}

fn patchBuildZig(allocator: Allocator) !?usize {
    const content = fs.cwd().readFileAlloc(allocator, "build.zig", 1024 * 1024) catch |err| {
        if (err == error.FileNotFound)
            std.debug.print("No build.zig found in current directory.\n", .{});
        return err;
    };
    defer allocator.free(content);

    if (mem.indexOf(u8, content, "b.dependency(\"ephor\"") != null or
        mem.indexOf(u8, content, "b.dependency( \"ephor\"") != null) return null;

    var line_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer line_list.deinit(allocator);
    var line_iter = mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| try line_list.append(allocator, line);

    const insert_after = findBuildZigInsertionPoint(line_list.items) orelse {
        std.debug.print("Could not find insertion point in build.zig\n", .{});
        return error.NoInsertionPoint;
    };

    var new_content: std.ArrayListUnmanaged(u8) = .empty;
    defer new_content.deinit(allocator);
    for (line_list.items, 0..) |line, idx| {
        try new_content.appendSlice(allocator, line);
        try new_content.append(allocator, '\n');
        if (idx == insert_after) try new_content.appendSlice(allocator, EPHOR_BUILD_SNIPPET);
    }

    try fs.cwd().writeFile("build.zig", new_content.items, .{});
    return insert_after + 2;
}

/// Run the upgrade command: updates ephor dependency in build.zig.zon.
/// If install_version is provided, upgrades to that specific version;
/// otherwise defaults to the binary's own version (EPHOR_VERSION).
fn runUpgradeCommand(allocator: Allocator, install_version: ?[]const u8) !void {
    // If no explicit version, fetch the latest from Codeberg tags API
    const fetched_ver = if (install_version == null) fetchLatestVersion(allocator) else null;
    defer if (fetched_ver) |fv| allocator.free(fv);
    const ver = install_version orelse (fetched_ver orelse EPHOR_VERSION);
    const package_url = try buildPackageUrl(allocator, ver);
    defer allocator.free(package_url);

    // Check if build.zig.zon exists and has ephor dependency
    const has_ephor = blk: {
        const content = fs.cwd().readFileAlloc(allocator, "build.zig.zon", 64 * 1024) catch break :blk false;
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

    std.debug.print("Upgrading ephor to v{s}...\n", .{ver});

    const url_z = try allocator.dupeZ(u8, package_url);
    defer allocator.free(url_z);

    // Run zig fetch --save to update the dependency
    var child = try std.process.spawn(global_io.?, .{
        .argv = &.{ "zig", "fetch", "--save=ephor", url_z },
    });

    const term = try child.wait(global_io.?);

    if (term.exited != 0) {
        std.debug.print("Failed to upgrade ephor to v{s}.\n", .{ver});
        return;
    }

    // Update version in ephor.json if it exists
    updateConfigVersion(allocator, ver);

    // Update build.zig integration to match current canonical block
    updateBuildZigIntegration(allocator);

    std.debug.print(
        \\Done! Ephor updated to v{s}.
        \\
        \\Run 'zig build ephor' to verify.
        \\
    , .{ver});
}

/// Update the "version" field in ephor.json if the file exists.
/// Best-effort: silently does nothing if file is missing or cannot be updated.
fn updateConfigVersion(allocator: Allocator, ver: []const u8) void {
    const content = fs.cwd().readFileAlloc(
        allocator,
        CONFIG_FILENAME,
        64 * 1024,
    ) catch return;
    defer allocator.free(content);

    const new_content = buildVersionUpdatedConfig(allocator, content, ver) orelse return;
    defer allocator.free(new_content);

    writeConfigFile(new_content) catch return;
    std.debug.print("Updated {s} (version: {s})\n", .{ CONFIG_FILENAME, ver });
}

/// Build config content with the version field replaced or inserted.
/// Returns allocated string on success, null if content cannot be processed.
fn buildVersionUpdatedConfig(
    allocator: Allocator,
    content: []const u8,
    ver: []const u8,
) ?[]const u8 {
    const key = "\"version\"";
    if (mem.indexOf(u8, content, key)) |key_pos| {
        return replaceVersionValue(allocator, content, key_pos + key.len, ver);
    }
    return insertVersionField(allocator, content, ver);
}

/// Replace the value of an existing "version" key at the given offset.
fn replaceVersionValue(
    allocator: Allocator,
    content: []const u8,
    after_key: usize,
    ver: []const u8,
) ?[]const u8 {
    // Find opening quote of value
    var i = after_key;
    while (i < content.len and content[i] != '"') i += 1;
    if (i >= content.len) return null;
    const val_start = i + 1;
    // Find closing quote
    var j = val_start;
    while (j < content.len and content[j] != '"') j += 1;
    if (j >= content.len) return null;

    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        content[0..val_start],
        ver,
        content[j..],
    }) catch null;
}

/// Insert a "version" field after the opening brace when none exists.
fn insertVersionField(
    allocator: Allocator,
    content: []const u8,
    ver: []const u8,
) ?[]const u8 {
    const brace_pos = mem.indexOf(u8, content, "{") orelse return null;
    return std.fmt.allocPrint(allocator, "{s}\n  \"version\": \"{s}\",{s}", .{
        content[0 .. brace_pos + 1],
        ver,
        content[brace_pos + 1 ..],
    }) catch null;
}

/// Write content to the config file (ephor.json).
fn writeConfigFile(content: []const u8) !void {
    try fs.cwd().writeFile(CONFIG_FILENAME, content, .{});
}

/// Canonical ephor build.zig integration block.
/// This is the source of truth — upgrade replaces the entire ephor section with this.
/// When the integration needs to change, update this block and bump the version.
const EPHOR_BUILD_BLOCK =
    \\    // Ephor static analysis
    \\    const ephor_dep = b.dependency("ephor", .{ .target = target, .optimize = .ReleaseSafe });
    \\    const ephor_artifact = ephor_dep.artifact("ephor");
    \\    const ephor_cmd = b.addRunArtifact(ephor_artifact);
    \\    if (b.args) |args| {
    \\        ephor_cmd.addArgs(args);
    \\    }
    \\    const ephor_step = b.step("ephor", "Run ephor static analysis");
    \\    ephor_step.dependOn(&ephor_cmd.step);
    \\
    \\    // Ephor upgrade
    \\    const ephor_upgrade_cmd = b.addRunArtifact(ephor_artifact);
    \\    ephor_upgrade_cmd.addArgs(&.{"upgrade"});
    \\    const ephor_upgrade_step = b.step("ephor-upgrade", "Upgrade ephor to latest version");
    \\    ephor_upgrade_step.dependOn(&ephor_upgrade_cmd.step);
;

/// Update the ephor build steps in build.zig to match the current canonical block.
/// Finds the ephor section by its start/end markers and replaces it entirely.
/// Supports both the old snippet marker (// === Ephor Static Analysis ===) and
/// the new canonical block marker (// Ephor static analysis).
/// Best-effort: silently does nothing if build.zig is missing or has no ephor section.
fn updateBuildZigIntegration(allocator: Allocator) void {
    const content = fs.cwd().readFileAlloc(allocator, "build.zig", 512 * 1024) catch return;
    defer allocator.free(content);

    // Try multiple marker pairs: (start_marker, end_marker)
    const MarkerPair = struct { start: []const u8, end: []const u8 };
    const markers = &[_]MarkerPair{
        .{
            .start = "    // Ephor static analysis",
            .end = "ephor_upgrade_step.dependOn(&ephor_upgrade_cmd.step);",
        },
        .{
            .start = "    // === Ephor Static Analysis ===",
            .end = "ephor_step.dependOn(&b.addRunArtifact(ephor_exe).step);",
        },
    };

    var start_pos: ?usize = null;
    var block_end: ?usize = null;

    for (markers) |m| {
        if (mem.indexOf(u8, content, m.start)) |sp| {
            const end_search_start = sp + m.start.len;
            if (mem.indexOf(u8, content[end_search_start..], m.end)) |ep| {
                start_pos = sp;
                block_end = end_search_start + ep + m.end.len;
                break;
            }
        }
    }

    const sp = start_pos orelse return;
    const be = block_end orelse return;

    // Extract current block and compare
    const current_block = content[sp..be];
    if (mem.eql(u8, current_block, EPHOR_BUILD_BLOCK)) return;

    // Replace the block
    const new_content = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        content[0..sp],
        EPHOR_BUILD_BLOCK,
        content[be..],
    }) catch return;
    defer allocator.free(new_content);

    fs.cwd().writeFile("build.zig", new_content, .{}) catch return;

    std.debug.print("Updated build.zig (ephor build steps)\n", .{});
}

/// Current ephor version (set at compile time)
const EPHOR_VERSION = "0.12.8";

/// URL to check for latest version
const EPHOR_VERSION_URL = "https://codeberg.org/RhyosLabs/ephor/raw/branch/main/build.zig.zon";

/// Stored update notification (printed after analysis output)
var update_notification: ?[]const u8 = null;

/// Check for new version (best effort, never blocks on failure).
/// Always fetches latest version from remote — no local cache.
fn checkForUpdates(allocator: Allocator) void {
    const latest = fetchLatestVersion(allocator) orelse {
        std.debug.print("warning: could not fetch latest ephor version, continuing with v{s}\n", .{EPHOR_VERSION});
        return;
    };
    defer allocator.free(latest);
    if (!isNewerVersion(EPHOR_VERSION, latest)) return;
    const msg = std.fmt.allocPrint(
        allocator,
        "  ephor v{s} available (current: v{s}). Run: zig build ephor-upgrade  ",
        .{ latest, EPHOR_VERSION },
    ) catch return;
    defer allocator.free(msg);

    const border = allocator.alloc(u8, msg.len) catch return;
    defer allocator.free(border);
    @memset(border, '#');

    update_notification = std.fmt.allocPrint(
        allocator,
        "\n{s}\n{s}\n{s}\n",
        .{ border, msg, border },
    ) catch null;
}

/// Fetch latest version from the Codeberg tags API (not cached raw files).
/// Falls back to parsing build.zig.zon from main branch if tags API fails.
fn fetchLatestVersion(allocator: Allocator) ?[]const u8 {
    // Primary: use tags API (sorted by date, most recent first)
    const api_url = "https://codeberg.org/api/v1/repos/RhyosLabs/ephor/tags?limit=1";
    const api_result = std.process.run(allocator, global_io.?, .{
        .argv = &.{ "curl", "-sL", "--max-time", "5", api_url },
    }) catch return fetchVersionFromZon(allocator);
    defer allocator.free(api_result.stdout);
    defer allocator.free(api_result.stderr);

    if (api_result.stdout.len > 0) {
        if (parseVersionFromTagsApi(allocator, api_result.stdout)) |ver| return ver;
    }

    // Fallback: parse build.zig.zon from main branch
    return fetchVersionFromZon(allocator);
}

/// Fetch version by parsing build.zig.zon from the main branch (CDN-cached fallback).
fn fetchVersionFromZon(allocator: Allocator) ?[]const u8 {
    const result = std.process.run(allocator, global_io.?, .{
        .argv = &.{ "curl", "-sL", "--max-time", "3", EPHOR_VERSION_URL },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stdout.len == 0) return null;
    return parseVersionFromZon(allocator, result.stdout);
}

/// Parse version from Codeberg tags API JSON response.
/// Looks for `"name": "vX.Y.Z"` pattern.
fn parseVersionFromTagsApi(allocator: Allocator, json: []const u8) ?[]const u8 {
    // Find "name": "vX.Y.Z" — the first match is the latest tag
    const name_marker = "\"name\":";
    const idx = mem.indexOf(u8, json, name_marker) orelse return null;
    var pos = idx + name_marker.len;
    // Skip whitespace
    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) : (pos += 1) {}
    if (pos >= json.len or json[pos] != '"') return null;
    pos += 1; // skip opening quote
    const end = mem.indexOfPos(u8, json, pos, "\"") orelse return null;
    const tag_name = json[pos..end];
    // Strip leading 'v' if present
    const ver = if (tag_name.len > 0 and tag_name[0] == 'v') tag_name[1..] else tag_name;
    if (ver.len == 0) return null;
    return allocator.dupe(u8, ver) catch null;
}

/// Parse `.version = "X.Y.Z"` from build.zig.zon content.
fn parseVersionFromZon(allocator: Allocator, content: []const u8) ?[]const u8 {
    const marker = ".version";
    var pos: usize = 0;
    while (pos < content.len) {
        const idx = mem.indexOfPos(u8, content, pos, marker) orelse return null;
        pos = idx + marker.len;
        // Skip whitespace and '='
        while (pos < content.len and (content[pos] == ' ' or
            content[pos] == '=' or content[pos] == '\t')) : (pos += 1)
        {}
        if (pos >= content.len or content[pos] != '"') continue;
        pos += 1; // skip opening quote
        const end = mem.indexOfPos(u8, content, pos, "\"") orelse return null;
        const ver = content[pos..end];
        if (ver.len == 0) return null;
        return allocator.dupe(u8, ver) catch null;
    }
    return null;
}

/// Compare two semver strings. Returns true if remote > local.
fn isNewerVersion(local: []const u8, remote: []const u8) bool {
    const l = parseSemver(local) orelse return false;
    const r = parseSemver(remote) orelse return false;
    if (r[0] != l[0]) return r[0] > l[0];
    if (r[1] != l[1]) return r[1] > l[1];
    return r[2] > l[2];
}

/// Parse "X.Y.Z" into [3]u32. Returns null on failure.
fn parseSemver(ver: []const u8) ?[3]u32 {
    var parts: [3]u32 = .{ 0, 0, 0 };
    var it = mem.splitScalar(u8, ver, '.');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 3) return null;
        // Strip any suffix like "-dev" from the last part
        const clean = if (mem.indexOfScalar(u8, part, '-')) |dash|
            part[0..dash]
        else
            part;
        parts[i] = std.fmt.parseInt(u32, clean, 10) catch return null;
        i += 1;
    }
    if (i < 3) return null;
    return parts;
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
        .{ .name = "help", .cmd = .help },
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

/// Try to add entry files from a list of candidate paths (dedup via added map)
fn tryAddEntryFiles(
    allocator: Allocator,
    cfg: *Config,
    candidates: []const []const u8,
    added: *std.StringHashMap(void),
) !void {
    for (candidates) |f| {
        const full = try buildPathWithPrefix(allocator, cfg.path, f);
        fs.cwd().access(full, .{}) catch {
            allocator.free(full);
            continue;
        };
        if (added.contains(full)) {
            allocator.free(full);
            continue;
        }
        try cfg.entries.append(allocator, full);
        try added.put(full, {});
    }
}

/// Scan build.zig files in target and parent directories
fn scanBuildZigEntries(
    allocator: Allocator,
    cfg: *Config,
    added: *std.StringHashMap(void),
) !void {
    const build_zig_path = try buildPathWithPrefix(allocator, cfg.path, "build.zig");
    defer allocator.free(build_zig_path);
    try extractBuildZigEntriesFromPath(allocator, cfg, build_zig_path, cfg.path, added, 0);

    const parent = std.fs.path.dirname(mem.trimEnd(u8, cfg.path, "/")) orelse ".";
    const parent_build = try std.fmt.allocPrint(allocator, "{s}/build.zig", .{parent});
    defer allocator.free(parent_build);
    try extractBuildZigEntriesFromPath(allocator, cfg, parent_build, parent, added, 0);
}

fn detectTargetEntries(allocator: Allocator, cfg: *Config) !void {
    for (cfg.entries.items) |e| allocator.free(e);
    cfg.entries.clearRetainingCapacity();
    try loadConfigFromTargetPath(allocator, cfg, cfg.path);
    if (cfg.entries.items.len > 0) return;

    var added = std.StringHashMap(void).init(allocator);
    defer added.deinit();

    const files = [_][]const u8{ "main.zig", "lib.zig", "root.zig" };
    try tryAddEntryFiles(allocator, cfg, &files, &added);
    const src_files = [_][]const u8{ "src/main.zig", "src/lib.zig", "src/root.zig" };
    try tryAddEntryFiles(allocator, cfg, &src_files, &added);

    try scanBuildZigEntries(allocator, cfg, &added);

    const multi_entry_dirs = [_][]const u8{
        "examples",  "example", "samples", "experiments",
        "tools",     "test",    "tests",   "fuzz",
        "benchmark", "benches", "scripts", "lib",
        "clients",   "drivers", "apps",    "cmd",
        "bin",       "ci",      "user",
    };
    for (multi_entry_dirs) |dir| {
        const dir_path = try buildPathWithPrefix(allocator, cfg.path, dir);
        defer allocator.free(dir_path);
        try scanDirForEntriesWithPrefix(allocator, cfg, dir_path, cfg.path, &added, 0);
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
        try added.put(e, {});
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
    // Pattern: .path("...") - matches b.path("..."), dep.path("..."), dep.builder.path("...")
    if (mem.indexOf(u8, line, ".path(\"")) |idx| {
        const start = idx + 7; // len of '.path("'
        if (extractQuotedPath(line, start)) |path|
            try addEntryIfValid(allocator, cfg, path, added);
    }
    // Pattern: .path = "..." or .root_src = "..." or .root_source_file = "..."
    const path_patterns = [_]struct { tag: []const u8, len: usize }{
        .{ .tag = ".path = \"", .len = 9 },
        .{ .tag = ".root_src = \"", .len = 13 },
        .{ .tag = ".root_source_file = \"", .len = 20 },
    };
    for (path_patterns) |pat| {
        const idx = mem.indexOf(u8, line, pat.tag) orelse continue;
        const start = idx + pat.len;
        if (extractQuotedPath(line, start)) |path|
            try addEntryIfValid(allocator, cfg, path, added);
    }
    // Pattern: @import("...") in build.zig (build module imports, entry points)
    var search_pos: usize = 0;
    while (mem.indexOf(u8, line[search_pos..], "@import(\"")) |rel_idx| {
        const idx = search_pos + rel_idx;
        const start = idx + 9; // len of '@import("'
        if (extractQuotedPath(line, start)) |path|
            try addEntryIfValid(allocator, cfg, path, added);
        search_pos = start;
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

/// Extract a joined path from a pathJoin(&.{ "seg1", "seg2", ... }) pattern.
/// Returns the joined path (e.g. "seg1/seg2/file.zig") or null.
/// Caller must free the returned slice.
/// Find the brace-delimited inner content of a pathJoin(&.{ ... }) call.
fn findPathJoinInner(line: []const u8, start: usize) ?[]const u8 {
    if (start >= line.len) return null;
    const rest = line[start..];
    const brace = mem.indexOf(u8, rest, "{") orelse return null;
    const after_brace = start + brace + 1;
    if (after_brace >= line.len) return null;
    const close_brace = mem.indexOf(u8, line[after_brace..], "}") orelse return null;
    return line[after_brace .. after_brace + close_brace];
}

const PathJoinResult = struct { count: usize, total_len: usize };

/// Parse quoted string segments from pathJoin inner content.
fn parsePathJoinSegments(
    inner: []const u8,
    segments: *[16][]const u8,
) PathJoinResult {
    var count: usize = 0;
    var total_len: usize = 0;
    var pos: usize = 0;
    while (pos < inner.len and count < 16) {
        const q1 = mem.indexOf(u8, inner[pos..], "\"") orelse break;
        const str_start = pos + q1 + 1;
        if (str_start >= inner.len) break;
        const q2 = mem.indexOf(u8, inner[str_start..], "\"") orelse break;
        const seg = inner[str_start .. str_start + q2];
        if (seg.len > 0) {
            segments[count] = seg;
            total_len += seg.len;
            count += 1;
        }
        pos = str_start + q2 + 1;
    }
    return .{ .count = count, .total_len = total_len };
}

/// Join path segments with '/' separator into an allocated string.
/// Returns null if not a .zig path. Caller must free result.
fn joinPathSegments(
    allocator: Allocator,
    segments: []const []const u8,
    total_len: usize,
) ?[]const u8 {
    const sep_count = segments.len - 1;
    const joined = allocator.alloc(u8, total_len + sep_count) catch return null;
    var offset: usize = 0;
    for (segments, 0..) |seg, i| {
        @memcpy(joined[offset .. offset + seg.len], seg);
        offset += seg.len;
        if (i < sep_count) {
            joined[offset] = '/';
            offset += 1;
        }
    }
    if (!mem.endsWith(u8, joined, ".zig")) {
        allocator.free(joined);
        return null;
    }
    return joined;
}

/// Extract a joined path from a pathJoin(&.{ "seg1", "seg2", ... }) pattern.
/// Returns the joined path (e.g. "seg1/seg2/file.zig") or null.
/// Caller must free the returned slice.
fn extractPathJoin(allocator: Allocator, line: []const u8, start: usize) ?[]const u8 {
    const inner = findPathJoinInner(line, start) orelse return null;
    var segments: [16][]const u8 = undefined;
    const result = parsePathJoinSegments(inner, &segments);
    if (result.count == 0) return null;
    return joinPathSegments(allocator, segments[0..result.count], result.total_len);
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

/// Extract path-tag based entries from a build.zig line
fn extractPathTagEntries(
    allocator: Allocator,
    cfg: *Config,
    line: []const u8,
    prefix: []const u8,
    added: *std.StringHashMap(void),
) !void {
    const path_tags = [_]struct { tag: []const u8, len: usize }{
        .{ .tag = ".path = \"", .len = 9 },
        .{ .tag = ".root_src = \"", .len = 13 },
        .{ .tag = ".root_source_file = \"", .len = 20 },
    };
    for (path_tags) |pat| {
        const idx = mem.indexOf(u8, line, pat.tag) orelse continue;
        if (extractQuotedPath(line, idx + pat.len)) |path|
            try addEntryWithPrefix(allocator, cfg, path, prefix, added);
    }
}

/// Extract pathJoin(&.{ "dir", "file.zig" }) entries from a build.zig line
fn extractPathJoinEntries(
    allocator: Allocator,
    cfg: *Config,
    line: []const u8,
    prefix: []const u8,
    added: *std.StringHashMap(void),
) !void {
    const tag = "pathJoin(&.{";
    var pos: usize = 0;
    while (pos < line.len) {
        const idx = mem.indexOf(u8, line[pos..], tag) orelse break;
        const abs_pos = pos + idx + tag.len;
        if (extractPathJoin(allocator, line, abs_pos - 1)) |joined| {
            defer allocator.free(joined);
            try addEntryWithPrefix(allocator, cfg, joined, prefix, added);
        }
        pos = abs_pos;
    }
}

/// Check if an import path is a valid zig file import (not std/builtin)
fn isValidZigImport(imp_path: []const u8) bool {
    if (!mem.endsWith(u8, imp_path, ".zig")) return false;
    if (mem.eql(u8, imp_path, "std")) return false;
    if (mem.eql(u8, imp_path, "builtin")) return false;
    return true;
}

/// Follow @import entries in a build.zig line and recurse into nested modules
fn followImportsInLine(
    allocator: Allocator,
    cfg: *Config,
    line: []const u8,
    build_path: []const u8,
    prefix: []const u8,
    added: *std.StringHashMap(void),
    depth: u8,
) !void {
    var imp_pos: usize = 0;
    while (mem.indexOf(u8, line[imp_pos..], "@import(\"")) |rel| {
        const istart = imp_pos + rel + 9;
        defer imp_pos = istart;
        const imp_path = extractQuotedPath(line, istart) orelse continue;
        if (!isValidZigImport(imp_path)) continue;
        try addEntryWithPrefix(allocator, cfg, imp_path, prefix, added);
        try recurseNestedBuildModule(allocator, cfg, build_path, imp_path, prefix, added, depth);
    }
}

/// Resolve and recurse into a nested build module
fn recurseNestedBuildModule(
    allocator: Allocator,
    cfg: *Config,
    build_path: []const u8,
    imp_path: []const u8,
    prefix: []const u8,
    added: *std.StringHashMap(void),
    depth: u8,
) Allocator.Error!void {
    const cur_dir = std.fs.path.dirname(build_path) orelse ".";
    const nested = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cur_dir, imp_path });
    defer allocator.free(nested);
    extractBuildZigEntriesFromPath(allocator, cfg, nested, prefix, added, depth + 1) catch {
        if (cfg.verbose) std.debug.print(
            "note: could not parse nested build module {s}\n",
            .{nested},
        );
    };
}

/// Extract entry points from a build.zig file at a specific path
fn extractBuildZigEntriesFromPath(
    allocator: Allocator,
    cfg: *Config,
    build_path: []const u8,
    prefix: []const u8,
    added: *std.StringHashMap(void),
    depth: u8,
) !void {
    // Prevent stack overflow from circular @import chains (e.g., A imports B imports A)
    if (depth > 4) return;

    const content = fs.cwd().readFileAlloc(allocator, build_path, 1024 * 1024) catch return;
    defer allocator.free(content);

    var line_iter = mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (mem.indexOf(u8, line, ".path(\"")) |idx| {
            if (extractQuotedPath(line, idx + 7)) |path|
                try addEntryWithPrefix(allocator, cfg, path, prefix, added);
        }
        // Handle b.pathJoin(&.{ "dir", "file.zig" }) patterns
        try extractPathJoinEntries(allocator, cfg, line, prefix, added);
        try extractPathTagEntries(allocator, cfg, line, prefix, added);
        try followImportsInLine(allocator, cfg, line, build_path, prefix, added, depth);
    }
}

/// Check if a file name is an entry point
fn isEntryPointFile(name: []const u8) bool {
    if (mem.eql(u8, name, "main.zig")) return true;
    if (mem.eql(u8, name, "lib.zig")) return true;
    if (mem.eql(u8, name, "root.zig")) return true;
    return mem.endsWith(u8, name, "_test.zig");
}

/// Add an entry from a directory scan, checking access and dedup
fn addDirEntry(
    allocator: Allocator,
    cfg: *Config,
    dir_path: []const u8,
    name: []const u8,
    added: *std.StringHashMap(void),
    check_access: bool,
) !void {
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name });
    if (added.contains(full)) {
        allocator.free(full);
        return;
    }
    if (check_access) {
        fs.cwd().access(full, .{}) catch {
            allocator.free(full);
            return;
        };
    }
    try cfg.entries.append(allocator, full);
    try added.put(full, {});
}

/// Scan directory with prefix for entry paths
fn scanDirForEntriesWithPrefix(
    allocator: Allocator,
    cfg: *Config,
    dir_path: []const u8,
    prefix: []const u8,
    added: *std.StringHashMap(void),
    depth: u8,
) !void {
    if (depth > 16) return;
    var dir = fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close(global_io.?);
    var iter = dir.iterate();
    while (try iter.next(global_io.?)) |entry| {
        if (entry.kind == .file and isEntryPointFile(entry.name)) {
            addDirEntry(allocator, cfg, dir_path, entry.name, added, true) catch continue;
        }
        if (entry.kind != .directory) continue;
        const subdir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(subdir);
        try scanDirForEntriesWithPrefix(allocator, cfg, subdir, prefix, added, depth + 1);
    }
}

/// Scan a directory for .zig entry points (main.zig, lib.zig, root.zig)
fn scanDirForEntries(
    allocator: Allocator,
    cfg: *Config,
    dir_path: []const u8,
    added: *std.StringHashMap(void),
    depth: u8,
) !void {
    if (depth > 16) return;
    var dir = fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close(global_io.?);
    var iter = dir.iterate();
    while (try iter.next(global_io.?)) |entry| {
        if (entry.kind == .file and isEntryPointFile(entry.name)) {
            addDirEntry(allocator, cfg, dir_path, entry.name, added, false) catch continue;
        }
        if (entry.kind != .directory) continue;
        const subdir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(subdir);
        try scanDirForEntries(allocator, cfg, subdir, added, depth + 1);
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
        try added.put(e, {});
    }

    // Scan common multi-entry directories
    // Based on patterns found in community projects
    const multi_entry_dirs = [_][]const u8{
        "examples",  "example", "samples", "experiments",
        "tools",     "test",    "tests",   "fuzz",
        "benchmark", "benches", "scripts", "lib",
        "clients",   "drivers", "apps",    "cmd",
        "bin",       "ci",      "user",
    };
    for (multi_entry_dirs) |dir| {
        try scanDirForEntries(allocator, cfg, dir, &added, 0);
    }

    // Auto-discover test files in src/
    var dir = fs.cwd().openDir("src", .{ .iterate = true }) catch return;
    defer dir.close(global_io.?);
    var iter = dir.iterate();
    while (try iter.next(global_io.?)) |entry| {
        const is_test_file = entry.kind == .file and mem.endsWith(u8, entry.name, "_test.zig");
        if (!is_test_file) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.name});
        if (added.contains(path)) {
            allocator.free(path);
            continue;
        }
        try cfg.entries.append(allocator, path);
        try added.put(path, {});
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
    if (mem.eql(u8, arg, "--yes") or mem.eql(u8, arg, "-y")) {
        cfg.auto_approve = true;
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
    if (parseThreshold(arg, "--max-nesting=", 3)) |v| {
        th.max_nesting_depth = v;
        return true;
    }
    if (parseThreshold(arg, "--max-params=", 4)) |v| {
        th.max_params = v;
        return true;
    }
    if (parseThreshold(arg, "--max-branches=", 12)) |v| {
        th.max_branches = v;
        return true;
    }
    if (parseThreshold(arg, "--max-line-length=", 100)) |v| {
        th.max_line_length = v;
        return true;
    }
    if (parseThreshold(arg, "--max-file-bytes=", 50_000)) |v| {
        th.max_file_bytes = v;
        return true;
    }
    return false;
}

/// Parse a single CLI argument
/// Handle --entry= CLI argument
fn handleEntryArg(
    allocator: Allocator,
    arg: []const u8,
    cfg: *Config,
    cli_entries: *bool,
) !void {
    if (!cli_entries.*) {
        for (cfg.entries.items) |e| allocator.free(e);
        cfg.entries.clearRetainingCapacity();
        cli_entries.* = true;
    }
    try cfg.entries.append(allocator, try allocator.dupe(u8, arg[8..]));
}

/// Handle --disable=, --enable=, list-appending CLI arguments
fn handleListArg(
    allocator: Allocator,
    arg: []const u8,
    cfg: *Config,
) !bool {
    if (mem.startsWith(u8, arg, "--disable=")) {
        try cfg.disabled_rules.append(allocator, try allocator.dupe(u8, arg[10..]));
        return true;
    }
    if (mem.startsWith(u8, arg, "--enable=")) {
        try cfg.enabled_rules.append(allocator, try allocator.dupe(u8, arg[9..]));
        return true;
    }
    return false;
}

/// Set an optional path field, freeing the old value if present
fn setOptionalPath(
    allocator: Allocator,
    field: *?[]const u8,
    value: []const u8,
) !bool {
    if (field.*) |old| allocator.free(old);
    field.* = try allocator.dupe(u8, value);
    return true;
}

/// Handle --export=, --known-issues=, --command= (optional path arguments)
fn handleOptionalPathArg(
    allocator: Allocator,
    arg: []const u8,
    cfg: *Config,
) !bool {
    if (mem.startsWith(u8, arg, "--export="))
        return setOptionalPath(allocator, &cfg.export_path, arg[9..]);
    if (mem.startsWith(u8, arg, "--known-issues="))
        return setOptionalPath(allocator, &cfg.known_issues_path, arg[15..]);
    if (mem.startsWith(u8, arg, "--command="))
        return setOptionalPath(allocator, &cfg.runtime_command, arg[10..]);
    if (mem.startsWith(u8, arg, "--version="))
        return setOptionalPath(allocator, &cfg.install_version, arg[10..]);
    return false;
}

fn parseCliArg(
    allocator: Allocator,
    arg: []const u8,
    cfg: *Config,
    cli_entries: *bool,
) !void {
    if (mem.startsWith(u8, arg, "--entry="))
        return handleEntryArg(allocator, arg, cfg, cli_entries);
    if (parseSimpleFlag(arg, cfg)) return;
    if (parseThresholdArg(arg, &cfg.thresholds)) return;
    if (try handleListArg(allocator, arg, cfg)) return;
    if (try handleOptionalPathArg(allocator, arg, cfg)) return;
    if (arg[0] != '-') {
        if (cfg.path_owned) allocator.free(cfg.path);
        cfg.path = try allocator.dupe(u8, arg);
        cfg.path_owned = true;
    }
}

fn parseArgs(allocator: Allocator, proc_args: std.process.Args) !Config {
    var args = try proc_args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    var cfg = Config{
        .command = .check,
        .path = "src",
        .path_owned = false,
        .entries = .empty,
        .exclude = .empty,
        .orphan_exclude = .empty,
        .disabled_rules = .empty,
        .enabled_rules = .empty,
        .verbose = false,
        .show_summary = false,
        .format = .text,
        .thresholds = .{},
        .init_build = false,
        .export_path = null,
        .known_issues_path = null,
        .known_issues = .empty,
        .auto_approve = false,
        .runtime_command = null,
        .install_version = null,
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

    // Strip trailing slashes from path to prevent double-slash in output
    // (e.g., "src/" + "/main.zig" would produce "src//main.zig")
    if (cfg.path_owned) {
        var path = cfg.path;
        while (path.len > 1 and path[path.len - 1] == '/') {
            path = path[0 .. path.len - 1];
        }
        if (path.len != cfg.path.len) {
            const trimmed = try allocator.dupe(u8, path);
            allocator.free(cfg.path);
            cfg.path = trimmed;
        }
    }

    // If path wasn't set by config or CLI, auto-detect from build.zig
    // (only for commands that analyze code, not install/upgrade/help/version)
    const needs_path = switch (cfg.command) {
        .install, .upgrade, .help, .version => false,
        else => true,
    };
    if (needs_path and !cfg.path_owned) {
        const detected = detectPathDirFromBuildZig(allocator);
        cfg.path = detected;
        cfg.path_owned = true;
    }

    if (cfg.path_owned and !mem.eql(u8, cfg.path, "src")) try detectTargetEntries(allocator, &cfg);
    if (cfg.entries.items.len == 0) try detectStandardEntries(allocator, &cfg);
    return cfg;
}

fn printHelp() void {
    std.debug.print("Ephor v{s} - The overseer of your Zig code\n\n", .{EPHOR_VERSION});
    const help =
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
        \\  install     Add ephor to project's build.zig (version-pinned)
        \\  upgrade     Upgrade ephor to a new version (alias: update)
        \\  check       Run all static checks (default)
        \\  runtime     Run tests with memory diagnostics (dynamic analysis)
        \\  orphans     Files not imported from entry points
        \\  memory      Alloc without defer patterns
        \\  errors      Error handling patterns (ZA201-ZA208)
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
        \\  --max-nesting=N      Max nesting depth (default: 3)
        \\  --max-params=N       Max parameters (default: 4)
        \\  --max-branches=N     Max branches per function (default: 12)
        \\  --max-line-length=N  Max columns per line (default: 100)
        \\  --max-file-bytes=N   Max file size in bytes (optional)
        \\  -V, --verbose        Verbose output
        \\  -s, --summary        Show summary at end
        \\  -b, --build          With 'init': also show build.zig integration
        \\  --export=<file>      Export issues to file with code snippets
        \\  --known-issues=<file> Filter out known true positives (file:line format)
        \\  --command=<cmd>      For 'runtime': custom command instead of 'zig build test'
        \\  -y, --yes            Skip interactive confirmation (e.g., runtime approval)
        \\  --version=<X.Y.Z>   For 'install'/'upgrade': pin a specific version
        \\
        \\INSTALL/UPGRADE EXAMPLES:
        \\  ephor install                    # Install current binary version
        \\  ephor install --version=0.12.8   # Install specific version
        \\  ephor upgrade                    # Upgrade to current binary version
        \\  ephor upgrade --version=0.12.8   # Upgrade to specific version
        \\
        \\RUNTIME COMMAND EXAMPLES:
        \\  ephor runtime .                         # Run 'zig build test'
        \\  ephor runtime . --command="./myapp"     # Run custom command
        \\  ephor runtime . --command="zig run src/main.zig"
        \\
        \\KNOWN ISSUES FILE FORMAT:
        \\  # One issue per line, format: file:line
        \\  # Lines starting with # are comments
        \\  src/main.zig:123
        \\  src/util.zig:456
        \\
        \\CONFIG FILE (ephor.json):
        \\  {
        \\    "version": "0.12.8",
        \\    "path_dir": "src",
        \\    "entries": ["src/main.zig", "build.zig"],
        \\    "exclude": ["test", "vendor"],
        \\    "disable": ["ZA301"],
        \\    "enable": ["ZA702"],
        \\    "thresholds": {
        \\      "max_lines": 50,
        \\      "max_nesting": 3,
        \\      "max_params": 4,
        \\      "max_branches": 12,
        \\      "max_line_length": 100,
        \\      "max_cyclomatic": 15,
        \\      "max_cognitive": 15
        \\      "max_file_bytes": 50000
        \\    }
        \\  }
        \\
        \\INLINE IGNORE (in source code):
        \\  // ephor:ignore ZA201       (same line or next line)
        \\  // ephor:ignore ZA201       (above fn/block: suppresses entire scope)
        \\  // ephor:ignore-file ZA201  (suppresses rule for entire file)
        \\  // ephor:ignore             (omit rule to suppress all)
        \\
        \\RULE IDS:
        \\  ZA1xx  Memory     (ZA101: alloc-no-defer, ZA102: create-no-defer,
        \\                     ZA103: alloc-no-errdefer,
        \\                     ZA105: use-after-free, ZA106: double-free)
        \\  ZA2xx  ErrHandle  (ZA201: silent-catch, ZA202: catch-unreachable,
        \\                     ZA203: orelse-unreachable, ZA204: undefined,
        \\                     ZA205: ignored-error, ZA206: exit-bypasses-defer)
        \\  ZA8xx  NullSafety (ZA801: unsafe-optional-unwrap, ZA802: unsafe-deref)
        \\  ZA9xx  Panic      (ZA901: decrement-no-guard, ZA902: subtraction-overflow,
        \\                     ZA903: index-arithmetic)
        \\  ZA3xx  Complexity (ZA301: func-too-long, ZA302: nesting-too-deep,
        \\                     ZA303: too-many-params, ZA304: too-many-branches,
        \\                     ZA305: cyclomatic, ZA306: cognitive)
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
        \\Ephor - Rhyos Labs - https://codeberg.org/RhyosLabs/ephor
        \\
    ;
    std.debug.print("{s}", .{help});
}

// ============================================================================
// Known Issues / Export
// ============================================================================

/// Load known issues from file (file:line format, one per line)
/// Supports .ephor-ignore auto-detection or --known-issues=<path>
fn loadKnownIssues(allocator: Allocator, cfg: *Config) !void {
    const path = cfg.known_issues_path orelse blk: {
        // Auto-detect .ephor-ignore in project root
        const ignore_path = try std.fs.path.join(allocator, &.{ cfg.path, ".ephor-ignore" });
        defer allocator.free(ignore_path);
        if (fs.cwd().access(ignore_path, .{})) |_| {
            cfg.known_issues_path = try allocator.dupe(u8, ignore_path);
            break :blk cfg.known_issues_path.?;
        } else |_| {
            return; // No known issues file
        }
    };

    const content = fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch return;
    defer allocator.free(content);

    // Track how many keys we've successfully added for cleanup on error
    var keys_added: usize = 0;
    errdefer {
        // On error, clean up any keys we already added
        for (cfg.known_issues.items[0..keys_added]) |k| {
            allocator.free(k);
        }
        cfg.known_issues.shrinkRetainingCapacity(0);
    }

    var iter = mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue; // Comment
        // Format: file:line or file:line:rule
        // We store just file:line for matching
        const key = try allocator.dupe(u8, trimmed);
        errdefer allocator.free(key);
        try cfg.known_issues.append(allocator, key);
        keys_added += 1;
    }
}

/// Check if an issue is in the known issues list
fn isKnownIssue(issue: Issue, cfg: *const Config) bool {
    if (cfg.known_issues.items.len == 0) return false;

    // Build key in format "file:line"
    var buf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}:{d}", .{ issue.file, issue.line }) catch return false;

    // Linear search through known issues
    for (cfg.known_issues.items) |known| {
        if (mem.eql(u8, known, key)) return true;
    }
    return false;
}

/// Export issues to a file with code snippets
/// Write a code snippet around a given line from a file
fn writeCodeSnippet(
    allocator: Allocator,
    output: *std.ArrayListUnmanaged(u8),
    issue_file: []const u8,
    issue_line: usize,
) !void {
    const content = fs.cwd().readFileAlloc(allocator, issue_file, 10 * 1024 * 1024) catch return;
    defer allocator.free(content);

    var line_iter = mem.splitScalar(u8, content, '\n');
    var line_num: usize = 1;
    try output.print(allocator, "```zig\n", .{});

    const start_line = if (issue_line > 2) issue_line - 2 else 1;
    const end_line = issue_line + 2;

    while (line_iter.next()) |line| {
        defer line_num += 1;
        if (line_num > end_line) break;
        if (line_num < start_line) continue;
        const prefix: []const u8 = if (line_num == issue_line) ">>> " else "    ";
        try output.print(allocator, "{s}{d}: {s}\n", .{ prefix, line_num, line });
    }
    try output.print(allocator, "```\n\n", .{});
}

/// Write a single issue entry to the export writer
fn writeExportIssue(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), issue: Issue, base_path: []const u8) !void {
    const rel_path = types.relativePath(issue.file, base_path);
    try output.print(allocator, "## {s}:{d}:{d} [{s}]\n", .{
        rel_path, issue.line, issue.col, issue.rule,
    });
    try output.print(allocator, "**{s}**: {s}\n", .{
        @tagName(issue.severity), issue.message,
    });
    if (issue.help) |help| {
        try output.print(allocator, "**Help**: {s}\n", .{help});
    }
    try writeCodeSnippet(allocator, output, issue.file, issue.line);
    try output.print(allocator, "---\n\n", .{});
}

fn exportIssues(
    allocator: Allocator,
    export_path: []const u8,
    all_issues: []const Issue,
    cfg: *const Config,
    graph: ?*const ImportGraph,
) !usize {
    var file = try fs.cwd().createFile(export_path, .{});
    defer file.close(global_io.?);

    var output = std.ArrayListUnmanaged(u8).empty;
    defer output.deinit(allocator);

    const ts: u64 = @intCast(std.Io.Clock.Timestamp.now(global_io.?, .real).raw.toSeconds());
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = ts };
    const day_secs = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    try output.print(allocator, "# Ephor Issues Export\n", .{});
    try output.print(allocator, "# Generated: {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC\n", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
    var filtered_count: usize = 0;
    for (all_issues) |issue| {
        if (shouldPrintIssue(issue, cfg, graph)) filtered_count += 1;
    }
    try output.print(allocator, "# Total issues: {d}\n\n", .{filtered_count});

    for (all_issues) |issue| {
        if (!shouldPrintIssue(issue, cfg, graph)) continue;
        try writeExportIssue(allocator, &output, issue, cfg.path);
    }
    try file.writeStreamingAll(global_io.?, output.items);
    return filtered_count;
}

// ============================================================================
// Output
// ============================================================================

/// Check if issue should be printed based on config filters
fn shouldPrintIssue(issue: Issue, cfg: *const Config, graph: ?*const ImportGraph) bool {
    // Runtime issues (ZR1xx) use absolute paths from stack traces - skip path filter
    const is_runtime_issue = std.mem.startsWith(u8, issue.rule, "ZR1");
    if (!is_runtime_issue and !std.mem.startsWith(u8, issue.file, cfg.path)) return false;
    if (cfg.isRuleDisabled(issue.rule)) return false;
    if (!is_runtime_issue and cfg.isPathExcluded(issue.file)) return false;
    if (isKnownIssue(issue, cfg)) return false;
    // Check inline ignore/disable comments in source
    if (graph) |g| {
        if (g.files.get(issue.file)) |analysis| {
            if (isInlineDisabled(analysis.content, issue.line, issue.rule)) return false;
        }
    }
    return true;
}

/// Print issues and return count of actionable issues (warnings + errors only).
/// Notes are printed but do NOT count toward the exit code.
const PrintCounts = struct {
    warnings: usize = 0,
    notes: usize = 0,

    fn add(self: PrintCounts, other: PrintCounts) PrintCounts {
        return .{
            .warnings = self.warnings + other.warnings,
            .notes = self.notes + other.notes,
        };
    }
};

fn printIssues(
    issues: []const Issue,
    base_path: []const u8,
    format: OutputFormat,
    title: []const u8,
    cfg: *const Config,
    graph: ?*const ImportGraph,
) PrintCounts {
    var total_printable: usize = 0;
    var counts = PrintCounts{};
    for (issues) |issue| {
        if (!shouldPrintIssue(issue, cfg, graph)) continue;
        total_printable += 1;
        if (issue.severity == .note) counts.notes += 1 else counts.warnings += 1;
    }
    if (format == .json) {
        std.debug.print(
            "{{\n  \"analyzer\": \"{s}\",\n  \"count\": {d},\n  \"issues\": [\n",
            .{ title, total_printable },
        );
        var printed: usize = 0;
        for (issues) |issue| {
            if (!shouldPrintIssue(issue, cfg, graph)) continue;
            printed += 1;
            issue.printJson(base_path, printed == total_printable);
        }
        std.debug.print("  ]\n}}\n", .{});
    } else {
        for (issues) |issue| {
            if (!shouldPrintIssue(issue, cfg, graph)) continue;
            issue.printText(base_path);
        }
    }
    return counts;
}

fn printResultFooter(total: PrintCounts) void {
    if (total.warnings == 0 and total.notes == 0) return;
    std.debug.print("\nephor: ", .{});
    if (total.warnings > 0) {
        std.debug.print("{d} warning{s}", .{
            total.warnings,
            if (total.warnings == 1) "" else "s",
        });
        if (total.notes > 0) std.debug.print(", ", .{});
    }
    if (total.notes > 0) {
        std.debug.print("{d} note{s}", .{
            total.notes,
            if (total.notes == 1) "" else "s",
        });
    }
    std.debug.print(" found\n", .{});
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
            \\{s}:     {d}
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
            @as([]const u8, "TO" ++ "DO/FIX" ++ "ME"),
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
            \\Quality: NotImplemented={d} {s}={d}
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
            @as([]const u8, "TO" ++ "DO/FIX" ++ "ME"),
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

// ============================================================================
// Main
// ============================================================================

pub fn main(init: std.process.Init) !void {
    global_io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var cfg = try parseArgs(alloc, init.minimal.args);
    defer cfg.deinit(alloc);

    // Track if we should exit with error (checked at end of main after defers)
    var should_exit_error = false;

    // Check for updates on analysis commands (not on help/version/init/install/upgrade)
    switch (cfg.command) {
        .help, .version, .init, .install, .upgrade => {},
        else => checkForUpdates(alloc),
    }

    // Get absolute base path for relative path calculation
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_path = fs.cwd().realpath(cfg.path, &base_buf) catch cfg.path;

    switch (cfg.command) {
        .help => printHelp(),
        .version => std.debug.print(
            "Ephor v{s} - The overseer of your Zig code\n",
            .{EPHOR_VERSION},
        ),
        .init => {
            writeDefaultConfig() catch |err| {
                std.debug.print("error: failed to create config: {}\n", .{err});
                should_exit_error = true;
            };
            // If --build flag, also print build integration info
            if (cfg.init_build and !should_exit_error) {
                runInstallCommand(alloc, cfg.install_version) catch |err| {
                    std.debug.print("error: failed to run install: {}\n", .{err});
                    should_exit_error = true;
                };
            }
        },

        .install => runInstallCommand(alloc, cfg.install_version) catch |err| {
            std.debug.print("error: failed to install: {}\n", .{err});
            should_exit_error = true;
        },

        .upgrade => runUpgradeCommand(alloc, cfg.install_version) catch |err| {
            std.debug.print("error: failed to upgrade: {}\n", .{err});
            should_exit_error = true;
        },

        .orphans => {
            if (cfg.entries.items.len == 0) {
                std.debug.print("error: no entry points found\n", .{});
                std.debug.print("  hint: create ephor.json with 'entries' array\n", .{});
                std.debug.print("  run: ephor init\n", .{});
                should_exit_error = true;
            } else {
                if (cfg.verbose) {
                    std.debug.print("Detected {d} entry points:\n", .{cfg.entries.items.len});
                    for (cfg.entries.items) |e| std.debug.print("  - {s}\n", .{e});
                }
                var g = ImportGraph.init(alloc);
                defer g.deinit();
                g.scan_root = base_path;
                try scanPath(&g, cfg.path);
                for (cfg.entries.items) |e| try g.markReachable(e);
                try g.markBuildPathReferences(&cfg);
                var issues = try g.getOrphanIssues(alloc, &cfg);
                defer deinitIssues(&issues, alloc);
                sortIssuesByFile(issues.items);

                const c = printIssues(issues.items, base_path, cfg.format, "orphans", &cfg, &g);
                _ = c;
            }
        },

        .memory => {
            var g = ImportGraph.init(alloc);
            defer g.deinit();
            g.scan_root = base_path;
            try scanPath(&g, cfg.path);
            var issues = try analyzeCFGMemory(alloc, &g);
            defer deinitIssues(&issues, alloc);
            const c = printIssues(issues.items, base_path, cfg.format, "memory", &cfg, &g);
            _ = c;
        },

        .errors => {
            var g = ImportGraph.init(alloc);
            defer g.deinit();
            g.scan_root = base_path;
            try scanPath(&g, cfg.path);
            var issues = try analyzeErrors(alloc, &g);
            defer deinitIssues(&issues, alloc);
            // ZA205: discarded error union results
            var ignored = try analyzeIgnoredErrors(alloc, &g);
            defer deinitIssues(&ignored, alloc);
            // Merge ignored errors into issues for unified output
            for (ignored.items) |item| {
                try issues.append(alloc, item);
            }
            // Clear ignored without deiniting items (now owned by issues)
            ignored.items.len = 0;
            const c = printIssues(issues.items, base_path, cfg.format, "errors", &cfg, &g);
            _ = c;
        },

        .unused => {
            var g = ImportGraph.init(alloc);
            defer g.deinit();
            g.scan_root = base_path;
            try scanPath(&g, cfg.path);
            var issues = try analyzeUnused(alloc, &g);
            defer deinitIssues(&issues, alloc);
            const c = printIssues(issues.items, base_path, cfg.format, "unused", &cfg, &g);
            _ = c;
        },

        .complexity => {
            var g = ImportGraph.init(alloc);
            defer g.deinit();
            g.scan_root = base_path;
            try scanPath(&g, cfg.path);
            var issues = try analyzeComplexity(alloc, &g, cfg.thresholds);
            defer deinitIssues(&issues, alloc);
            const c = printIssues(issues.items, base_path, cfg.format, "complexity", &cfg, &g);
            _ = c;
        },

        .fmt_check => {
            var issues = try runFmtCheck(alloc, cfg.path);
            defer deinitIssues(&issues, alloc);
            const c = printIssues(issues.items, base_path, cfg.format, "format", &cfg, null);
            _ = c;
        },

        .stats => {
            var g = ImportGraph.init(alloc);
            defer g.deinit();
            g.scan_root = base_path;
            try scanPath(&g, cfg.path);
            printStats(g.getStats(), cfg.format);
        },

        .runtime => {
            if (!cfg.auto_approve) {
                const cmd_str = cfg.runtime_command orelse "zig build test";
                std.debug.print(
                    \\
                    \\WARNING: Runtime analysis will COMPILE AND EXECUTE code in:
                    \\  {s}
                    \\
                    \\Command: {s}
                    \\
                    \\This runs untrusted code with your user privileges.
                    \\Only run this on projects you trust.
                    \\
                    \\Proceed? [y/N]
                , .{ base_path, cmd_str });
                var read_buf: [16]u8 = undefined;
                var stdin_reader = std.Io.File.stdin().reader(global_io.?, &read_buf);
                const n = stdin_reader.interface.readSliceShort(&read_buf) catch 0;
                if (n == 0 or (read_buf[0] != 'y' and read_buf[0] != 'Y')) {
                    std.debug.print("Aborted.\n", .{});
                    return;
                }
            }
            var issues = try runRuntimeAnalysis(alloc, cfg.path, cfg.verbose, cfg.runtime_command);
            defer deinitIssues(&issues, alloc);
            const c = printIssues(issues.items, base_path, cfg.format, "runtime", &cfg, null);
            _ = c;
        },

        .check => {
            if (cfg.entries.items.len == 0) {
                std.debug.print("error: no entry points found\n", .{});
                std.debug.print("  hint: create ephor.json with 'entries' array\n", .{});
                std.debug.print("  run: ephor init\n", .{});
                should_exit_error = true;
            }

            if (!should_exit_error) {
                // Load known issues for filtering
                try loadKnownIssues(alloc, &cfg);

                var g = ImportGraph.init(alloc);
                defer g.deinit();
                g.scan_root = base_path;

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
                try g.markBuildPathReferences(&cfg);

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
                    &g,
                );
                // Filter cfg_mem_issues by rule category
                var mem_only_issues = std.ArrayListUnmanaged(Issue).empty;
                defer mem_only_issues.deinit(alloc);
                var null_safety_issues = std.ArrayListUnmanaged(Issue).empty;
                defer null_safety_issues.deinit(alloc);
                var panic_issues = std.ArrayListUnmanaged(Issue).empty;
                defer panic_issues.deinit(alloc);

                for (cfg_mem_issues.items) |issue| {
                    if (mem.startsWith(u8, issue.rule, "ZA8")) {
                        try null_safety_issues.append(alloc, issue);
                    } else if (mem.startsWith(u8, issue.rule, "ZA9")) {
                        try panic_issues.append(alloc, issue);
                    } else if (mem.startsWith(u8, issue.rule, "ZA2")) {
                        // ZA2xx covered by analyzeErrors — skip to avoid duplicates
                        continue;
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
                    &g,
                );
                const ignored_err_count = printIssues(
                    ignored_err_issues.items,
                    base_path,
                    cfg.format,
                    "errors",
                    &cfg,
                    &g,
                );
                const err_count = printIssues(
                    err_issues.items,
                    base_path,
                    cfg.format,
                    "errors",
                    &cfg,
                    &g,
                );
                const null_safety_count = printIssues(
                    null_safety_issues.items,
                    base_path,
                    cfg.format,
                    "null-safety",
                    &cfg,
                    &g,
                );
                const panic_count = printIssues(
                    panic_issues.items,
                    base_path,
                    cfg.format,
                    "panic",
                    &cfg,
                    &g,
                );
                const unused_count = printIssues(
                    unused_issues.items,
                    base_path,
                    cfg.format,
                    "unused",
                    &cfg,
                    &g,
                );
                const cx_count = printIssues(
                    cx_issues.items,
                    base_path,
                    cfg.format,
                    "complexity",
                    &cfg,
                    &g,
                );
                const fmt_count = printIssues(
                    fmt_issues.items,
                    base_path,
                    cfg.format,
                    "format",
                    &cfg,
                    &g,
                );
                const naming_count = printIssues(
                    naming_issues.items,
                    base_path,
                    cfg.format,
                    "naming",
                    &cfg,
                    &g,
                );
                const style_count = printIssues(
                    style_issues.items,
                    base_path,
                    cfg.format,
                    "style",
                    &cfg,
                    &g,
                );

                // Accumulate totals
                const total = orphan_count
                    .add(mem_count).add(ignored_err_count)
                    .add(err_count).add(null_safety_count)
                    .add(panic_count).add(unused_count)
                    .add(cx_count).add(fmt_count)
                    .add(naming_count).add(style_count);

                if (cfg.show_summary) {
                    printSummary(.{
                        .orphan = orphan_count.warnings,
                        .memory = mem_count.warnings,
                        .err = err_count.warnings + ignored_err_count.warnings,
                        .unused = unused_count.warnings,
                        .complexity = cx_count.warnings,
                        .fmt = fmt_count.warnings,
                        .style = style_count.warnings + naming_count.warnings,
                        .null_safety = null_safety_count.warnings,
                        .panic = panic_count.warnings,
                    }, stats, cfg.format);
                }

                // Print summary footer
                printResultFooter(total);

                // Export issues to file if requested
                if (cfg.export_path) |export_path| {
                    // Collect all issues into one list for export
                    var all_issues = std.ArrayListUnmanaged(Issue).empty;
                    defer all_issues.deinit(alloc);

                    for (orphan_issues.items) |i| try all_issues.append(alloc, i);
                    for (mem_only_issues.items) |i| try all_issues.append(alloc, i);
                    for (err_issues.items) |i| try all_issues.append(alloc, i);
                    for (ignored_err_issues.items) |i| try all_issues.append(alloc, i);
                    for (unused_issues.items) |i| try all_issues.append(alloc, i);
                    for (cx_issues.items) |i| try all_issues.append(alloc, i);
                    for (fmt_issues.items) |i| try all_issues.append(alloc, i);
                    for (style_issues.items) |i| try all_issues.append(alloc, i);
                    for (naming_issues.items) |i| try all_issues.append(alloc, i);
                    for (null_safety_issues.items) |i| try all_issues.append(alloc, i);
                    for (panic_issues.items) |i| try all_issues.append(alloc, i);

                    if (exportIssues(alloc, export_path, all_issues.items, &cfg, &g)) |exported_count| {
                        std.debug.print(
                            "exported {d} issues to {s}\n",
                            .{ exported_count, export_path },
                        );
                    } else |err| {
                        std.debug.print("error: failed to export issues: {}\n", .{err});
                    }
                }

                // Analysis results are informational - don't fail the build
            }
        },
    }

    // Print update notification after all analysis output
    if (update_notification) |msg| {
        std.debug.print("{s}", .{msg});
        alloc.free(msg);
        update_notification = null;
    }

    // Exit with error code AFTER all defers have run (cfg.deinit, gpa.deinit)
    // This is at the end of main() so defers execute first, then we exit
    // ephor:disable-next-line ZA206
    if (should_exit_error) std.process.exit(1);
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

test "ImportGraph.isSkippableDir skips dot-prefixed directories" {
    // Hardcoded skip list must still match.
    try std.testing.expect(ImportGraph.isSkippableDir(".git"));
    try std.testing.expect(ImportGraph.isSkippableDir("zig-out"));
    try std.testing.expect(ImportGraph.isSkippableDir("node_modules"));
    try std.testing.expect(ImportGraph.isSkippableDir("vendor"));

    // Regression: any dot-prefixed dir must be skipped. direnv-per-project
    // caches and project-local scratch dirs previously caused recursive
    // traversals to walk thousands of cache entries.
    try std.testing.expect(ImportGraph.isSkippableDir(".zig-global-cache"));
    try std.testing.expect(ImportGraph.isSkippableDir(".zig-cache-ephor"));
    try std.testing.expect(ImportGraph.isSkippableDir(".zig-cache-test"));
    try std.testing.expect(ImportGraph.isSkippableDir(".tmp"));
    try std.testing.expect(ImportGraph.isSkippableDir(".claude"));

    // Non-hidden, non-listed dirs must still be traversable.
    try std.testing.expect(!ImportGraph.isSkippableDir("src"));
    try std.testing.expect(!ImportGraph.isSkippableDir("lib"));
    try std.testing.expect(!ImportGraph.isSkippableDir("tests"));
}

// ============================================================================
// Phase 4: CFG Memory Analysis Tests (ZA105, ZA106)
// ============================================================================

/// Helper to create test FileAnalysis with content
fn createTestFileAnalysis(
    allocator: Allocator,
    path: []const u8,
    content: []const u8,
) !FileAnalysis {
    const path_copy = try allocator.dupe(u8, path);
    return .{
        .path = path_copy,
        .resolved_path = path_copy,
        .imports = .empty,
        .content = try allocator.dupe(u8, content),
        .has_tests = false,
        .pub_function_count = 0,
        .line_count = countLines(content),
    };
}

test "analyzeCFGMemory detects use-after-free (ZA105)" {
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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

    const analysis = try createTestFileAnalysis(
        allocator,
        "test_catch_free_return.zig",
        test_content,
    );
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
            std.debug.print(
                "FALSE POSITIVE: {s}:{d}: {s}\n",
                .{ issue.file, issue.line, issue.message },
            );
            try std.testing.expect(false);
        }
    }
}

test "analyzeCFGMemory detects double-free (ZA106)" {
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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

    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
// TypeContext / Return-Type-Aware Detection Integration Tests (ZA205)
// Tests that the TypeContext parsing correctly suppresses or flags discarded
// results based on the actual return type of user-defined methods/functions.
// ============================================================================

test "ZA205 type-aware: user-defined void method NOT flagged" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const content =
        \\const MyLogger = struct {
        \\    data: u32,
        \\    pub fn clear(self: *MyLogger) void {
        \\        self.data = 0;
        \\    }
        \\};
        \\fn use() void {
        \\    var logger = MyLogger{ .data = 42 };
        \\    _ = logger.clear();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_void_method.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_void_method.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // _ = logger.clear() should NOT be flagged (parsed void return)
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            std.debug.print("UNEXPECTED ZA205 at line {d}: {s}\n", .{ issue.line, issue.message });
            try std.testing.expect(false);
        }
    }
}

test "ZA205 type-aware: user-defined error method IS flagged" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const content =
        \\const FlushableLogger = struct {
        \\    data: u32,
        \\    pub fn flush(self: *FlushableLogger) !void {
        \\        _ = self;
        \\    }
        \\};
        \\fn use() void {
        \\    var flogger = FlushableLogger{ .data = 0 };
        \\    _ = flogger.flush();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_error_method.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_error_method.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // _ = flogger.flush() SHOULD be flagged (parsed !void return)
    var found = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "ZA205 type-aware: standalone void function NOT flagged" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const content =
        \\fn helper() void {}
        \\fn use() void {
        \\    _ = helper();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_void_fn.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_void_fn.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            std.debug.print("UNEXPECTED ZA205 at line {d}: {s}\n", .{ issue.line, issue.message });
            try std.testing.expect(false);
        }
    }
}

test "ZA205 type-aware: standalone error function IS flagged" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const content =
        \\fn riskyOp() !void {
        \\    return;
        \\}
        \\fn use() void {
        \\    _ = riskyOp();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_error_fn.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_error_fn.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var found = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "ZA205 type-aware: value-returning method NOT flagged" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const content =
        \\const Counter = struct {
        \\    val: u32,
        \\    pub fn count(self: *const Counter) u32 {
        \\        return self.val;
        \\    }
        \\};
        \\fn use() void {
        \\    var c = Counter{ .val = 5 };
        \\    _ = c.count();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_value_method.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_value_method.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            std.debug.print("UNEXPECTED ZA205 at line {d}: {s}\n", .{ issue.line, issue.message });
            try std.testing.expect(false);
        }
    }
}

test "ZA205 type-aware: optional-returning method NOT flagged" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const content =
        \\const Cache = struct {
        \\    val: u32,
        \\    pub fn lookup(self: *const Cache) ?u32 {
        \\        _ = self;
        \\        return null;
        \\    }
        \\};
        \\fn use() void {
        \\    var cache = Cache{ .val = 0 };
        \\    _ = cache.lookup();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_optional_method.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_optional_method.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            std.debug.print("UNEXPECTED ZA205 at line {d}: {s}\n", .{ issue.line, issue.message });
            try std.testing.expect(false);
        }
    }
}

test "ZA205 type-aware: stdlib ArrayList method NOT flagged" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const content =
        \\const std = @import("std");
        \\fn use() void {
        \\    var list: std.ArrayListUnmanaged(u32) = .empty;
        \\    _ = list.pop();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_stdlib_method.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_stdlib_method.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            std.debug.print("UNEXPECTED ZA205 at line {d}: {s}\n", .{ issue.line, issue.message });
            try std.testing.expect(false);
        }
    }
}

test "ZA205 type-aware: mixed struct void and error methods" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // Struct has both void and error-returning methods
    // Only the error-returning one should be flagged
    const content =
        \\const Service = struct {
        \\    state: u32,
        \\    pub fn reset(self: *Service) void {
        \\        self.state = 0;
        \\    }
        \\    pub fn connect(self: *Service) !void {
        \\        _ = self;
        \\    }
        \\    pub fn getStatus(self: *const Service) u32 {
        \\        return self.state;
        \\    }
        \\};
        \\fn use() void {
        \\    var svc = Service{ .state = 0 };
        \\    _ = svc.reset();
        \\    _ = svc.connect();
        \\    _ = svc.getStatus();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_mixed_methods.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_mixed_methods.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should have exactly 1 ZA205: for svc.connect() (!void)
    // reset() is void, getStatus() is u32 — both safe
    var za205_count: usize = 0;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            za205_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), za205_count);
}

test "ZA205 type-aware: user .clear() returning !void IS flagged (overrides vocab)" {
    // CRITICAL: This is the key test for TypeContext. The old code would NOT flag
    // this because .clear( matches safe_method_patterns vocab. The new code MUST
    // flag it because TypeContext resolves .clear() to error_union for this struct.
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const content =
        \\const ErrorCleaner = struct {
        \\    data: u32,
        \\    pub fn clear(self: *ErrorCleaner) !void {
        \\        _ = self;
        \\    }
        \\};
        \\fn use() void {
        \\    var cleaner = ErrorCleaner{ .data = 0 };
        \\    _ = cleaner.clear();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_error_clear.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_error_clear.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // _ = cleaner.clear() MUST be flagged — clear() returns !void on this type
    // This is the scenario where TypeContext overrides the vocab safe_method_patterns
    var found = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "ZA205 type-aware: stdlib .clear() still NOT flagged (vocab fallback)" {
    // Verify that stdlib containers' .clear() is still suppressed via vocab
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const content =
        \\const std = @import("std");
        \\fn use() void {
        \\    var list: std.ArrayListUnmanaged(u32) = .empty;
        \\    _ = list.clear();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_stdlib_clear.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_stdlib_clear.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            std.debug.print("UNEXPECTED ZA205 at line {d}: {s}\n", .{ issue.line, issue.message });
            try std.testing.expect(false);
        }
    }
}

test "ZA205 type-aware: unknown receiver falls through to legacy" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // Variable type can't be determined (comes from function param)
    // Should fall through to legacy pattern matching
    const content =
        \\fn use(x: anytype) void {
        \\    _ = x.next();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_unknown_type.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_unknown_type.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // .next() is in the optional_methods vocab, so should NOT be flagged
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            std.debug.print("UNEXPECTED ZA205 at line {d}: {s}\n", .{ issue.line, issue.message });
            try std.testing.expect(false);
        }
    }
}

test "ZA205 type-aware: enum void method NOT flagged" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const content =
        \\const State = enum {
        \\    active,
        \\    inactive,
        \\    pub fn reset(self: *State) void {
        \\        self.* = .inactive;
        \\    }
        \\};
        \\fn use() void {
        \\    var s: State = .active;
        \\    _ = s.reset();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_enum_void.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_enum_void.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            std.debug.print("UNEXPECTED ZA205 at line {d}: {s}\n", .{ issue.line, issue.message });
            try std.testing.expect(false);
        }
    }
}

test "ZA205 type-aware: enum error method IS flagged" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const content =
        \\const State = enum {
        \\    active,
        \\    inactive,
        \\    pub fn tryTransition(self: *State) !void {
        \\        _ = self;
        \\        return;
        \\    }
        \\};
        \\fn use() void {
        \\    var s: State = .active;
        \\    _ = s.tryTransition();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_enum_error.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_enum_error.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var found_za205 = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            found_za205 = true;
            break;
        }
    }
    try std.testing.expect(found_za205);
}

test "ZA205 type-aware: union void method NOT flagged" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const content =
        \\const Result = union(enum) {
        \\    ok: u32,
        \\    fail: void,
        \\    pub fn discard(self: *Result) void {
        \\        self.* = .{ .fail = {} };
        \\    }
        \\};
        \\fn use() void {
        \\    var r: Result = .{ .ok = 42 };
        \\    _ = r.discard();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_union_void.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_union_void.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            std.debug.print("UNEXPECTED ZA205 at line {d}: {s}\n", .{ issue.line, issue.message });
            try std.testing.expect(false);
        }
    }
}

test "ZA205 type-aware: union error method IS flagged" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const content =
        \\const Result = union(enum) {
        \\    ok: u32,
        \\    fail: void,
        \\    pub fn tryUnwrap(self: Result) !u32 {
        \\        return switch (self) {
        \\            .ok => |v| v,
        \\            .fail => error.Failed,
        \\        };
        \\    }
        \\};
        \\fn use() void {
        \\    const r: Result = .{ .ok = 42 };
        \\    _ = r.tryUnwrap();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_union_error.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_union_error.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var found_za205 = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            found_za205 = true;
            break;
        }
    }
    try std.testing.expect(found_za205);
}

test "ZA205 type-aware: enum value method NOT flagged" {
    // Enum method that returns a value (not error union) — safe to discard
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const content =
        \\const Color = enum {
        \\    red,
        \\    green,
        \\    blue,
        \\    pub fn toInt(self: Color) u8 {
        \\        return switch (self) {
        \\            .red => 0,
        \\            .green => 1,
        \\            .blue => 2,
        \\        };
        \\    }
        \\};
        \\fn use() void {
        \\    const c: Color = .red;
        \\    _ = c.toInt();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_enum_value.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_enum_value.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            std.debug.print("UNEXPECTED ZA205 at line {d}: {s}\n", .{ issue.line, issue.message });
            try std.testing.expect(false);
        }
    }
}

test "ZA205 type-aware: packed struct method works" {
    // Packed structs are used in real code (hardware registers, protocol headers)
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const content =
        \\const Flags = packed struct {
        \\    readable: bool,
        \\    writable: bool,
        \\    _padding: u6 = 0,
        \\    pub fn clear(self: *Flags) void {
        \\        self.readable = false;
        \\        self.writable = false;
        \\    }
        \\};
        \\fn use() void {
        \\    var f = Flags{ .readable = true, .writable = true };
        \\    _ = f.clear();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_packed_struct.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_packed_struct.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            std.debug.print("UNEXPECTED ZA205 at line {d}: {s}\n", .{ issue.line, issue.message });
            try std.testing.expect(false);
        }
    }
}

test "ZA205 type-aware: extern struct method works" {
    // Extern structs used for C FFI
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const content =
        \\const CHandle = extern struct {
        \\    fd: i32,
        \\    pub fn close(self: *CHandle) void {
        \\        self.fd = -1;
        \\    }
        \\    pub fn read(self: *CHandle) !u32 {
        \\        _ = self;
        \\        return 0;
        \\    }
        \\};
        \\fn use() void {
        \\    var h = CHandle{ .fd = 3 };
        \\    _ = h.close();
        \\    _ = h.read();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_extern_struct.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_extern_struct.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // close() returns void — NOT flagged
    // read() returns !u32 — SHOULD be flagged
    var za205_count: usize = 0;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            za205_count += 1;
        }
    }
    // Only read() should trigger ZA205
    try std.testing.expectEqual(@as(usize, 1), za205_count);
}

test "ZA205 type-aware: noreturn function NOT flagged" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const content =
        \\const Processor = struct {
        \\    data: u32,
        \\    pub fn halt(self: *Processor) noreturn {
        \\        _ = self;
        \\        while (true) {}
        \\    }
        \\};
        \\fn use() void {
        \\    var p = Processor{ .data = 0 };
        \\    _ = p.halt();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_noreturn.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_noreturn.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            std.debug.print("UNEXPECTED ZA205 at line {d}: {s}\n", .{ issue.line, issue.message });
            try std.testing.expect(false);
        }
    }
}

test "ZA205 type-aware: multiple user types in same file resolved independently" {
    // Real Zig files define multiple types. Each type's methods must resolve independently.
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const content =
        \\const Logger = struct {
        \\    level: u8,
        \\    pub fn clear(self: *Logger) void {
        \\        self.level = 0;
        \\    }
        \\};
        \\const Connection = enum {
        \\    open,
        \\    closed,
        \\    pub fn close(self: *Connection) void {
        \\        self.* = .closed;
        \\    }
        \\};
        \\const Parser = union(enum) {
        \\    idle: void,
        \\    parsing: u32,
        \\    pub fn parse(self: *Parser) !u32 {
        \\        _ = self;
        \\        return 42;
        \\    }
        \\};
        \\fn use() void {
        \\    var log: Logger = .{ .level = 5 };
        \\    _ = log.clear();
        \\    var conn: Connection = .open;
        \\    _ = conn.close();
        \\    var parser: Parser = .{ .idle = {} };
        \\    _ = parser.parse();
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_multi_types.zig", content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_multi_types.zig"), {});

    var issues = try analyzeIgnoredErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Logger.clear() -> void: NOT flagged
    // Connection.close() -> void: NOT flagged
    // Parser.parse() -> !u32: FLAGGED
    var za205_count: usize = 0;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_IGNORED_ERROR)) {
            za205_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), za205_count);
}

// ============================================================================
// Phase 5: Null Safety Tests (ZA801, ZA802)
// ============================================================================

test "analyzeNullSafety detects unsafe optional unwrap (ZA801)" {
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cfg = Config{
        .command = .check,
        .path = "src",
        .path_owned = false,
        .entries = .empty,
        .exclude = .empty,
        .orphan_exclude = .empty,
        .disabled_rules = .empty,
        .enabled_rules = .empty,
        .verbose = false,
        .show_summary = false,
        .format = .text,
        .thresholds = .{},
        .init_build = false,
        .export_path = null,
        .known_issues_path = null,
        .known_issues = .empty,
        .auto_approve = false,
        .runtime_command = null,
        .install_version = null,
    };
    defer cfg.deinit(allocator);

    // Enable ZA702 explicitly
    try cfg.enabled_rules.append(allocator, try allocator.dupe(u8, "ZA702"));

    // ZA702 is OFF by default but should be ON when explicitly enabled
    try std.testing.expect(cfg.isRuleEnabled("ZA702"));
}

test "Config.isRuleEnabled respects disable prefix" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cfg = Config{
        .command = .check,
        .path = "src",
        .path_owned = false,
        .entries = .empty,
        .exclude = .empty,
        .orphan_exclude = .empty,
        .disabled_rules = .empty,
        .enabled_rules = .empty,
        .verbose = false,
        .show_summary = false,
        .format = .text,
        .thresholds = .{},
        .init_build = false,
        .export_path = null,
        .known_issues_path = null,
        .known_issues = .empty,
        .auto_approve = false,
        .runtime_command = null,
        .install_version = null,
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
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cfg = Config{
        .command = .check,
        .path = "src",
        .path_owned = false,
        .entries = .empty,
        .exclude = .empty,
        .orphan_exclude = .empty,
        .disabled_rules = .empty,
        .enabled_rules = .empty,
        .verbose = false,
        .show_summary = false,
        .format = .text,
        .thresholds = .{},
        .init_build = false,
        .export_path = null,
        .known_issues_path = null,
        .known_issues = .empty,
        .auto_approve = false,
        .runtime_command = null,
        .install_version = null,
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

test "ephor:ignore suppresses same-line issue" {
    const content =
        \\const x = foo() catch {}; // ephor:ignore ZA201
        \\const y = foo() catch {};
    ;
    // Line 1 ignored
    try std.testing.expect(isInlineDisabled(content, 1, "ZA201"));
    // Line 2 not ignored
    try std.testing.expect(!isInlineDisabled(content, 2, "ZA201"));
}

test "ephor:ignore on previous line suppresses next line" {
    const content =
        \\// ephor:ignore ZA203
        \\const x = val orelse unreachable;
        \\const y = val orelse unreachable;
    ;
    // Line 2 suppressed by comment on line 1
    try std.testing.expect(isInlineDisabled(content, 2, "ZA203"));
    // Line 3 not covered
    try std.testing.expect(!isInlineDisabled(content, 3, "ZA203"));
}

test "ephor:ignore without rule suppresses all rules on line" {
    const content =
        \\const x = foo() catch {}; // ephor:ignore
    ;
    try std.testing.expect(isInlineDisabled(content, 1, "ZA201"));
    try std.testing.expect(isInlineDisabled(content, 1, "ZA202"));
    try std.testing.expect(isInlineDisabled(content, 1, "ZA101"));
}

test "ephor:ignore with specific rule only suppresses that rule" {
    const content =
        \\const x = foo() catch {}; // ephor:ignore ZA201
    ;
    try std.testing.expect(isInlineDisabled(content, 1, "ZA201"));
    try std.testing.expect(!isInlineDisabled(content, 1, "ZA202"));
}

test "ephor:ignore works for ZA202 catch unreachable" {
    const content =
        \\// ephor:ignore ZA202
        \\const x = getData() catch unreachable;
    ;
    try std.testing.expect(isInlineDisabled(content, 2, "ZA202"));
}

test "ephor:ignore works for ZA101 memory warning" {
    const content =
        \\const buf = try alloc.alloc(u8, 1024); // ephor:ignore ZA101
    ;
    try std.testing.expect(isInlineDisabled(content, 1, "ZA101"));
}

test "ephor:ignore above function suppresses entire scope" {
    const content =
        \\const a = foo() catch {};
        \\// ephor:ignore ZA201
        \\fn bad_function() void {
        \\    bar() catch {};
        \\    baz() catch {};
        \\}
        \\const b = qux() catch {};
    ;
    // Line 1: before ignore — not suppressed
    try std.testing.expect(!isInlineDisabled(content, 1, "ZA201"));
    // Line 3: function declaration line — suppressed (scope starts here)
    try std.testing.expect(isInlineDisabled(content, 3, "ZA201"));
    // Line 4: inside function body — suppressed
    try std.testing.expect(isInlineDisabled(content, 4, "ZA201"));
    // Line 5: inside function body — suppressed
    try std.testing.expect(isInlineDisabled(content, 5, "ZA201"));
    // Line 6: closing brace — suppressed (last line of scope)
    try std.testing.expect(isInlineDisabled(content, 6, "ZA201"));
    // Line 7: after function — not suppressed
    try std.testing.expect(!isInlineDisabled(content, 7, "ZA201"));
}

test "ephor:ignore above scope only suppresses matching rule" {
    const content =
        \\// ephor:ignore ZA201
        \\fn my_fn() void {
        \\    foo() catch {};
        \\    const x = val orelse unreachable;
        \\}
    ;
    // ZA201 suppressed inside scope
    try std.testing.expect(isInlineDisabled(content, 3, "ZA201"));
    // ZA203 NOT suppressed — different rule
    try std.testing.expect(!isInlineDisabled(content, 4, "ZA203"));
}

test "ephor:ignore above scope without rule suppresses all rules" {
    const content =
        \\// ephor:ignore
        \\fn my_fn() void {
        \\    foo() catch {};
        \\    const x = val orelse unreachable;
        \\}
    ;
    try std.testing.expect(isInlineDisabled(content, 3, "ZA201"));
    try std.testing.expect(isInlineDisabled(content, 4, "ZA203"));
}

test "ephor:ignore scope works with nested braces" {
    const content =
        \\// ephor:ignore ZA201
        \\fn outer() void {
        \\    if (true) {
        \\        foo() catch {};
        \\    }
        \\    bar() catch {};
        \\}
        \\const after = baz() catch {};
    ;
    // Lines 2-7: inside outer function scope — all suppressed
    try std.testing.expect(isInlineDisabled(content, 2, "ZA201"));
    try std.testing.expect(isInlineDisabled(content, 4, "ZA201"));
    try std.testing.expect(isInlineDisabled(content, 6, "ZA201"));
    try std.testing.expect(isInlineDisabled(content, 7, "ZA201"));
    // Line 8: after scope — not suppressed
    try std.testing.expect(!isInlineDisabled(content, 8, "ZA201"));
}

test "ephor:ignore-file suppresses entire file" {
    const content =
        \\// ephor:ignore-file ZA201
        \\const a = foo() catch {};
        \\fn something() void {
        \\    baz() catch {};
        \\}
    ;
    try std.testing.expect(isInlineDisabled(content, 2, "ZA201"));
    try std.testing.expect(isInlineDisabled(content, 4, "ZA201"));
    // Different rule NOT suppressed
    try std.testing.expect(!isInlineDisabled(content, 2, "ZA202"));
}

test "ephor:ignore-file without rule suppresses all rules" {
    const content =
        \\// ephor:ignore-file
        \\const a = foo() catch {};
        \\const b = val orelse unreachable;
    ;
    try std.testing.expect(isInlineDisabled(content, 2, "ZA201"));
    try std.testing.expect(isInlineDisabled(content, 3, "ZA203"));
    try std.testing.expect(isInlineDisabled(content, 2, "ZA101"));
}

test "ephor:ignore-file works from anywhere in file" {
    const content =
        \\const a = foo() catch {};
        \\// ephor:ignore-file ZA201
        \\const b = bar() catch {};
    ;
    // Even line 1 (before the directive) is suppressed
    try std.testing.expect(isInlineDisabled(content, 1, "ZA201"));
    try std.testing.expect(isInlineDisabled(content, 3, "ZA201"));
}

test "ephor:ignore before non-scope line suppresses just next line" {
    const content =
        \\// ephor:ignore ZA201
        \\const a = foo() catch {};
        \\const b = bar() catch {};
    ;
    // Line 2: next line after ignore (no scope opened) — suppressed
    try std.testing.expect(isInlineDisabled(content, 2, "ZA201"));
    // Line 3: not covered
    try std.testing.expect(!isInlineDisabled(content, 3, "ZA201"));
}

test "checkSilentCatch detects catch {}" {
    // Basic catch {} should be detected
    const issue = checkSilentCatch("foo() catch {}", "test.zig", 1, "processData", null);
    try std.testing.expect(issue != null);
    try std.testing.expectEqualStrings("ZA201", issue.?.rule);
}

test "checkSilentCatch skips defer context" {
    // Same-line defer should not be detected
    const issue = checkSilentCatch("defer foo() catch {}", "test.zig", 1, "init", null);
    try std.testing.expect(issue == null);
}

test "analyzeErrors detects silent catch (ZA201)" {
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var lines_list = std.ArrayListUnmanaged([]const u8).empty;
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
        null,
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
    var gpa = std.heap.DebugAllocator(.{}){};
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

    var lines_list = std.ArrayListUnmanaged([]const u8).empty;
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
        null,
    );
    defer deinitIssues(&issues, allocator);

    // Should NOT report issues for properly deferred allocation
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_good.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
        }
    }
}

test "analyzeCFGDeferCoverage detects alloc with no defer at all" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test content: allocation with no defer, no free, no ownership transfer
    const test_content =
        \\fn leaky(alloc: std.mem.Allocator) !void {
        \\    const data = try alloc.alloc(u8, 100);
        \\    _ = data;
        \\}
    ;

    var lines_list = std.ArrayListUnmanaged([]const u8).empty;
    defer lines_list.deinit(allocator);

    var line_iter = mem.splitScalar(u8, test_content, '\n');
    while (line_iter.next()) |line| {
        try lines_list.append(allocator, line);
    }

    var cfg_graph = try buildCFG(allocator, "leaky", 1, lines_list.items);
    defer cfg_graph.deinit();

    var issues = try analyzeCFGDeferCoverage(
        allocator,
        &cfg_graph,
        lines_list.items,
        1,
        "test_no_defer.zig",
        null,
    );
    defer deinitIssues(&issues, allocator);

    // Should detect that allocation has no defer at all
    var found_issue = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER)) {
            found_issue = true;
            break;
        }
    }
    try std.testing.expect(found_issue);
}

// ============================================================================
// Integration Test: Bad Code Patterns (CFG-based)
// ============================================================================
// Tests realistic memory safety bugs that the CFG analysis should catch.
// These patterns compile but have subtle runtime issues.

test "integration: use-after-free patterns" {
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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

// ============================================================================
// Update Check Tests
// ============================================================================

test "isNewerVersion detects newer versions" {
    try std.testing.expect(isNewerVersion("0.7.4", "0.8.0"));
    try std.testing.expect(isNewerVersion("0.7.4", "0.7.5"));
    try std.testing.expect(isNewerVersion("0.7.4", "1.0.0"));
    try std.testing.expect(!isNewerVersion("0.7.4", "0.7.4"));
    try std.testing.expect(!isNewerVersion("0.7.4", "0.7.3"));
    try std.testing.expect(!isNewerVersion("0.7.4", "0.6.9"));
    try std.testing.expect(!isNewerVersion("1.0.0", "0.99.99"));
}

test "isNewerVersion handles dev suffix" {
    try std.testing.expect(isNewerVersion("0.7.4", "0.8.0-dev"));
    try std.testing.expect(!isNewerVersion("0.8.0", "0.8.0-dev"));
}

test "parseSemver parses valid versions" {
    const v = parseSemver("1.2.3").?;
    try std.testing.expectEqual(@as(u32, 1), v[0]);
    try std.testing.expectEqual(@as(u32, 2), v[1]);
    try std.testing.expectEqual(@as(u32, 3), v[2]);
}

test "parseSemver rejects invalid versions" {
    try std.testing.expect(parseSemver("abc") == null);
    try std.testing.expect(parseSemver("1.2") == null);
    try std.testing.expect(parseSemver("") == null);
}

test "parseVersionFromZon extracts version" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const zon_content =
        \\.{
        \\    .name = .ephor,
        \\    .version = "0.9.0",
        \\    .fingerprint = 0x12345,
        \\}
    ;

    const ver = parseVersionFromZon(allocator, zon_content).?;
    defer allocator.free(ver);
    try std.testing.expectEqualStrings("0.9.0", ver);
}

test "parseVersionFromZon returns null for missing version" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const bad_content = ".{ .name = .ephor }";
    try std.testing.expect(parseVersionFromZon(allocator, bad_content) == null);
}

test "fnReturnsType detects literal type return" {
    // Returns type → TitleCase required
    try std.testing.expect(fnReturnsType("fn Point(T: type) type {", 8));
    try std.testing.expect(fnReturnsType("fn ShortList(comptime T: type, comptime n: usize) type {", 12));
    try std.testing.expect(fnReturnsType("pub fn MakeStruct(comptime T: type) type {", 12));
}

test "fnReturnsType detects error union type return" {
    // Returns !type → still TitleCase
    try std.testing.expect(fnReturnsType("fn MakeType(x: u32) !type {", 11));
}

test "fnReturnsType rejects non-type returns" {
    // Returns T, not type → camelCase
    try std.testing.expect(!fnReturnsType("fn foo(T: type) T {", 6));
    try std.testing.expect(!fnReturnsType("fn doubleIt(comptime T: type, value: T) T {", 11));
    try std.testing.expect(!fnReturnsType("fn init(allocator: std.mem.Allocator) !Self {", 7));
    try std.testing.expect(!fnReturnsType("fn parse() !void {", 8));
    try std.testing.expect(!fnReturnsType("fn getValue() u32 {", 11));
}

test "fnReturnsType handles nested fn type params" {
    // Inner fn returns type, but outer fn returns void → camelCase
    try std.testing.expect(!fnReturnsType("fn register(cb: fn(type) type, x: u32) void {", 11));
}

test "fnReturnsType rejects type-prefixed identifiers" {
    // "typedef" is not "type"
    try std.testing.expect(!fnReturnsType("fn foo() typedef {", 6));
}

test "isFunctionPointerVar detects fn type annotation" {
    try std.testing.expect(isFunctionPointerVar("var callback: fn(u32) void = myFunc;"));
    try std.testing.expect(isFunctionPointerVar("var callback: fn (u32) void = myFunc;"));
    try std.testing.expect(isFunctionPointerVar("var cb :fn(u32) void = myFunc;"));
    try std.testing.expect(isFunctionPointerVar("var cb :fn (u32) void = myFunc;"));
}

test "isFunctionPointerVar detects qualified function assignment" {
    try std.testing.expect(isFunctionPointerVar("var handler = module.handleRequest;"));
    try std.testing.expect(isFunctionPointerVar("var cb = std.debug.print;"));
}

test "isFunctionPointerVar rejects normal vars" {
    try std.testing.expect(!isFunctionPointerVar("var my_count: u32 = 0;"));
    try std.testing.expect(!isFunctionPointerVar("var buffer: [100]u8 = undefined;"));
    try std.testing.expect(!isFunctionPointerVar("var name = SOME_CONSTANT;"));
}

test "isFunctionPointerVar detects modern *const fn pointer types" {
    try std.testing.expect(isFunctionPointerVar("var cb: *const fn(u32) void = myFunc;"));
    try std.testing.expect(isFunctionPointerVar("var cb: *const fn (u32) void = myFunc;"));
    try std.testing.expect(isFunctionPointerVar("var cb: ?*const fn(u32) void = null;"));
    try std.testing.expect(isFunctionPointerVar("var cb: ?*const fn (u32) void = null;"));
    try std.testing.expect(isFunctionPointerVar("var cb: *fn(u32) void = myFunc;"));
    try std.testing.expect(isFunctionPointerVar("var cb: ?*fn(u32) void = null;"));
}

test "isFunctionPointerVar rejects method call initializer" {
    // std.atomic.Value(bool).init(false) — `.init(...)` is a call, not a fn reference
    try std.testing.expect(!isFunctionPointerVar(
        "var g_initialized = std.atomic.Value(bool).init(false);",
    ));
}

test "isFunctionPointerVar rejects enum literal / .empty initializer" {
    // `.empty` is a field access / sentinel value, not a function pointer
    try std.testing.expect(!isFunctionPointerVar(
        "var g_validator_cache: std.AutoHashMapUnmanaged(u64, Info) = .empty;",
    ));
    try std.testing.expect(!isFunctionPointerVar("var x = .foo;"));
    try std.testing.expect(!isFunctionPointerVar("var x = .{ .a = 1 };"));
}

test "isFunctionPointerVar rejects qualified method call on generic type" {
    // Generic type construction then method call — parens in qualifier path
    try std.testing.expect(!isFunctionPointerVar(
        "var x = std.AutoHashMapUnmanaged(u64, Info).empty;",
    ));
}

// ============================================================================
// ZA703 Closure-Wrapper / Type-Definition Classification Tests
// ============================================================================

test "isTypeDefinition: real type defs detected" {
    const c1 = "const Foo = struct {};";
    try std.testing.expect(isTypeDefinition(c1, c1, 0));
    const c2 = "const Color = enum { red, green };";
    try std.testing.expect(isTypeDefinition(c2, c2, 0));
    const c3 = "const Tag = union { a: u32, b: u64 };";
    try std.testing.expect(isTypeDefinition(c3, c3, 0));
    const c4 = "const Bits = packed struct(u32) { a: u16, b: u16 };";
    try std.testing.expect(isTypeDefinition(c4, c4, 0));
}

test "isTypeDefinition: single-line closure NOT a type def" {
    const c = "const readBytes = struct { fn call() void {} }.call;";
    try std.testing.expect(!isTypeDefinition(c, c, 0));
}

test "isTypeDefinition: multi-line closure NOT a type def" {
    const content =
        "const readBytes = struct {\n" ++
        "    fn call() void {}\n" ++
        "}.call;\n";
    // First line is what the analyzer trims and passes as `t`.
    const line = "const readBytes = struct {";
    try std.testing.expect(!isTypeDefinition(line, content, 0));
}

test "isTypeDefinition: nested braces inside closure body still resolved correctly" {
    const content =
        "const wrap = struct {\n" ++
        "    fn call(a: u32) u32 {\n" ++
        "        if (a > 0) { return a; } else { return 0; }\n" ++
        "    }\n" ++
        "}.call;\n";
    const line = "const wrap = struct {";
    try std.testing.expect(!isTypeDefinition(line, content, 0));
}

test "isTypeDefinition: multi-line REAL type def still detected" {
    const content =
        "const Foo = struct {\n" ++
        "    field: u32,\n" ++
        "};\n";
    const line = "const Foo = struct {";
    try std.testing.expect(isTypeDefinition(line, content, 0));
}

test "isTypeDefinition: array literal of anonymous struct not a type def" {
    // `[_]struct { ... }{ ... }` has no space before `struct`, so the keyword
    // pattern ` struct` must NOT match.
    const c = "const keys = [_]struct { name: []const u8 }{ .{ .name = \"a\" } };";
    try std.testing.expect(!isTypeDefinition(c, c, 0));
}

test "isClosureFunctionAlias: detects multi-line closure" {
    const content =
        "const readBytes = struct {\n" ++
        "    fn call() void {}\n" ++
        "}.call;\n";
    const line = "const readBytes = struct {";
    try std.testing.expect(isClosureFunctionAlias(line, content, 0));
}

test "isClosureFunctionAlias: rejects real type def" {
    const c = "const Foo = struct { x: u32 };";
    try std.testing.expect(!isClosureFunctionAlias(c, c, 0));
}

// ============================================================================
// TypeContext / Return-Type-Aware Detection Tests
// ============================================================================

test "classifyReturnType identifies void" {
    try std.testing.expectEqual(ReturnKind.void_type, classifyReturnType("void"));
    try std.testing.expectEqual(ReturnKind.void_type, classifyReturnType("  void  "));
}

test "classifyReturnType identifies error unions" {
    try std.testing.expectEqual(ReturnKind.error_union, classifyReturnType("!void"));
    try std.testing.expectEqual(ReturnKind.error_union, classifyReturnType("!u32"));
    try std.testing.expectEqual(ReturnKind.error_union, classifyReturnType("anyerror!T"));
    try std.testing.expectEqual(ReturnKind.error_union, classifyReturnType("Error!void"));
}

test "classifyReturnType identifies optionals" {
    try std.testing.expectEqual(ReturnKind.optional, classifyReturnType("?u32"));
    try std.testing.expectEqual(ReturnKind.optional, classifyReturnType("?T"));
}

test "classifyReturnType identifies noreturn" {
    try std.testing.expectEqual(ReturnKind.noreturn_type, classifyReturnType("noreturn"));
}

test "classifyReturnType identifies values" {
    try std.testing.expectEqual(ReturnKind.value, classifyReturnType("u32"));
    try std.testing.expectEqual(ReturnKind.value, classifyReturnType("Response"));
    try std.testing.expectEqual(ReturnKind.value, classifyReturnType("bool"));
}

test "classifyReturnType returns unknown for empty" {
    try std.testing.expectEqual(ReturnKind.unknown, classifyReturnType(""));
    try std.testing.expectEqual(ReturnKind.unknown, classifyReturnType("   "));
}

test "extractFnReturnType parses simple signatures" {
    const r1 = extractFnReturnType("fn foo() void {");
    try std.testing.expect(r1 != null);
    try std.testing.expectEqualStrings("void", r1.?);

    const r2 = extractFnReturnType("pub fn bar(x: u32) !void {");
    try std.testing.expect(r2 != null);
    try std.testing.expectEqualStrings("!void", r2.?);

    const r3 = extractFnReturnType("fn baz(self: *Self) u32 {");
    try std.testing.expect(r3 != null);
    try std.testing.expectEqualStrings("u32", r3.?);
}

test "extractFnReturnType handles nested parens" {
    const r = extractFnReturnType("fn foo(cb: fn(u32) void, x: u32) !void {");
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("!void", r.?);
}

test "extractSelfTypeName extracts pointer self types" {
    const t1 = extractSelfTypeName("fn foo(self: *MyStruct) void {");
    try std.testing.expect(t1 != null);
    try std.testing.expectEqualStrings("MyStruct", t1.?);

    const t2 = extractSelfTypeName("fn foo(self: *const MyStruct) void {");
    try std.testing.expect(t2 != null);
    try std.testing.expectEqualStrings("MyStruct", t2.?);

    const t3 = extractSelfTypeName("fn foo(x: u32) void {");
    try std.testing.expect(t3 == null);
}

test "extractFnName extracts function names" {
    try std.testing.expectEqualStrings("foo", extractFnName("fn foo() void {").?);
    try std.testing.expectEqualStrings("bar", extractFnName("pub fn bar(x: u32) !void {").?);
    try std.testing.expect(extractFnName("const x = 42;") == null);
}

test "extractVarTypeName extracts explicit type annotations" {
    const t1 = extractVarTypeName("var x: MyStruct = .{};");
    try std.testing.expect(t1 != null);
    try std.testing.expectEqualStrings("MyStruct", t1.?);
}

test "extractVarTypeName extracts TypeName.init patterns" {
    const t1 = extractVarTypeName("var list = ArrayList(u8).init(allocator);");
    // ArrayList starts with uppercase, followed by (, so type is "ArrayList"
    try std.testing.expect(t1 != null);
    try std.testing.expectEqualStrings("ArrayList", t1.?);
}

test "extractVarTypeName extracts struct literal patterns" {
    const t1 = extractVarTypeName("var state = ErrorAnalysisState{};");
    try std.testing.expect(t1 != null);
    try std.testing.expectEqualStrings("ErrorAnalysisState", t1.?);
}

test "extractVarTypeName returns null for non-type RHS" {
    try std.testing.expect(extractVarTypeName("var x = some_func();") == null);
    try std.testing.expect(extractVarTypeName("var x = 42;") == null);
}

test "extractMethodCall extracts receiver and method" {
    const r1 = extractMethodCall("_ = list.clear()");
    try std.testing.expect(r1 != null);
    try std.testing.expectEqualStrings("list", r1.?.receiver);
    try std.testing.expectEqualStrings("clear", r1.?.method);

    const r2 = extractMethodCall("_ = logger.reset()");
    try std.testing.expect(r2 != null);
    try std.testing.expectEqualStrings("logger", r2.?.receiver);
    try std.testing.expectEqualStrings("reset", r2.?.method);
}

test "extractMethodCall returns null for non-method calls" {
    try std.testing.expect(extractMethodCall("_ = someFunction()") == null);
    try std.testing.expect(extractMethodCall("const x = 42;") == null);
}

// ============================================================================
// ZA703 Error Naming Tests
// ============================================================================

test "checkErrorNaming: snake_case error values pass" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    defer deinitIssues(&issues, a);

    try checkErrorNaming(&issues, a, "test.zig", "return error.file_not_found;", 1, false);
    try checkErrorNaming(&issues, a, "test.zig", "return error.out_of_memory;", 1, false);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "checkErrorNaming: CamelCase error values are flagged" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    defer deinitIssues(&issues, a);

    try checkErrorNaming(&issues, a, "test.zig", "return error.FileNotFound;", 1, false);
    try std.testing.expectEqual(@as(usize, 1), issues.items.len);
    try std.testing.expectEqualStrings("error value 'FileNotFound' should be snake_case", issues.items[0].message);
}

test "checkErrorNaming: error set members must be snake_case" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    defer deinitIssues(&issues, a);

    // Single-line error set
    try checkErrorNaming(&issues, a, "test.zig", "error{ FileNotFound, access_denied }", 1, true);
    try std.testing.expectEqual(@as(usize, 1), issues.items.len);
    try std.testing.expectEqualStrings("error set member 'FileNotFound' should be snake_case", issues.items[0].message);
}

test "checkErrorNaming: underscore-prefixed error names are exempt" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    defer deinitIssues(&issues, a);

    try checkErrorNaming(&issues, a, "test.zig", "error{ _FileNotFound, _internal }", 1, true);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "checkErrorNaming: does not flag someerror.foo as error value" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    defer deinitIssues(&issues, a);

    try checkErrorNaming(&issues, a, "test.zig", "const x = someerror.foo;", 1, false);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "checkErrorNaming: does not flag error. inside string literal" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    defer deinitIssues(&issues, a);

    try checkErrorNaming(&issues, a, "test.zig", "const msg = \"error.FileNotFound\";", 1, false);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "resolveReturnKind resolves struct method returns" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var ctx = TypeContext.init();
    defer ctx.deinit(a);

    // Register a struct method: MyLogger.clear -> void
    var methods = std.StringHashMapUnmanaged(ReturnKind){};
    try methods.put(a, "clear", .void_type);
    try methods.put(a, "flush", .error_union);
    try ctx.struct_methods.put(a, "MyLogger", methods);

    // Register var type: logger -> MyLogger
    try ctx.var_types.put(a, "logger", "MyLogger");

    // _ = logger.clear() should resolve to void
    const rk1 = resolveReturnKind(&ctx, "_ = logger.clear()");
    try std.testing.expectEqual(ReturnKind.void_type, rk1);

    // _ = logger.flush() should resolve to error_union
    const rk2 = resolveReturnKind(&ctx, "_ = logger.flush()");
    try std.testing.expectEqual(ReturnKind.error_union, rk2);

    // _ = unknown.clear() should resolve to unknown (receiver not tracked)
    const rk3 = resolveReturnKind(&ctx, "_ = unknown.clear()");
    try std.testing.expectEqual(ReturnKind.unknown, rk3);
}

test "resolveReturnKind resolves standalone functions" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var ctx = TypeContext.init();
    defer ctx.deinit(a);

    try ctx.function_returns.put(a, "helper", .void_type);
    try ctx.function_returns.put(a, "riskyOp", .error_union);

    const rk1 = resolveReturnKind(&ctx, "_ = helper()");
    try std.testing.expectEqual(ReturnKind.void_type, rk1);

    const rk2 = resolveReturnKind(&ctx, "_ = riskyOp()");
    try std.testing.expectEqual(ReturnKind.error_union, rk2);

    const rk3 = resolveReturnKind(&ctx, "_ = unknownFunc()");
    try std.testing.expectEqual(ReturnKind.unknown, rk3);
}

test "parseFileTypeContext builds struct methods" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const content =
        \\const MyStruct = struct {
        \\    pub fn clear(self: *MyStruct) void {
        \\    }
        \\    pub fn process(self: *MyStruct) !void {
        \\    }
        \\    pub fn count(self: *const MyStruct) u32 {
        \\    }
        \\};
    ;

    var ctx = try parseFileTypeContext(a, content);
    defer ctx.deinit(a);

    const methods = ctx.struct_methods.get("MyStruct");
    try std.testing.expect(methods != null);
    try std.testing.expectEqual(ReturnKind.void_type, methods.?.get("clear").?);
    try std.testing.expectEqual(ReturnKind.error_union, methods.?.get("process").?);
    try std.testing.expectEqual(ReturnKind.value, methods.?.get("count").?);
}

test "parseFileTypeContext builds var types" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const content =
        \\var logger: MyLogger = .{};
        \\var state = ErrorState{};
        \\const config = Config.init();
    ;

    var ctx = try parseFileTypeContext(a, content);
    defer ctx.deinit(a);

    try std.testing.expectEqualStrings("MyLogger", ctx.var_types.get("logger").?);
    try std.testing.expectEqualStrings("ErrorState", ctx.var_types.get("state").?);
    try std.testing.expectEqualStrings("Config", ctx.var_types.get("config").?);
}

test "parseFileTypeContext builds stdlib vars" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const content =
        \\var list: std.ArrayListUnmanaged(u32) = .empty;
        \\var map = StringHashMap(u32).init(a);
    ;

    var ctx = try parseFileTypeContext(a, content);
    defer ctx.deinit(a);

    try std.testing.expect(ctx.stdlib_vars.contains("list"));
    try std.testing.expect(ctx.stdlib_vars.contains("map"));
}

test "parseFileTypeContext builds top-level functions" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const content =
        \\fn helper() void {
        \\}
        \\fn riskyOp() !u32 {
        \\}
        \\pub fn getValue() u32 {
        \\}
    ;

    var ctx = try parseFileTypeContext(a, content);
    defer ctx.deinit(a);

    try std.testing.expectEqual(ReturnKind.void_type, ctx.function_returns.get("helper").?);
    try std.testing.expectEqual(ReturnKind.error_union, ctx.function_returns.get("riskyOp").?);
    try std.testing.expectEqual(ReturnKind.value, ctx.function_returns.get("getValue").?);
}

test "parseFileTypeContext parses enum methods" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const content =
        \\const State = enum {
        \\    active,
        \\    inactive,
        \\    pub fn reset(self: *State) void {
        \\        self.* = .inactive;
        \\    }
        \\    pub fn tryTransition(self: *State) !void {
        \\        _ = self;
        \\        return;
        \\    }
        \\};
    ;

    var ctx = try parseFileTypeContext(a, content);
    defer ctx.deinit(a);

    const methods = ctx.struct_methods.get("State").?;
    try std.testing.expectEqual(ReturnKind.void_type, methods.get("reset").?);
    try std.testing.expectEqual(ReturnKind.error_union, methods.get("tryTransition").?);
}

test "parseFileTypeContext parses union methods" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const content =
        \\const Result = union(enum) {
        \\    ok: u32,
        \\    fail: void,
        \\    pub fn unwrap(self: Result) u32 {
        \\        return switch (self) {
        \\            .ok => |v| v,
        \\            .fail => 0,
        \\        };
        \\    }
        \\    pub fn tryUnwrap(self: Result) !u32 {
        \\        _ = self;
        \\        return 42;
        \\    }
        \\};
    ;

    var ctx = try parseFileTypeContext(a, content);
    defer ctx.deinit(a);

    const methods = ctx.struct_methods.get("Result").?;
    try std.testing.expectEqual(ReturnKind.value, methods.get("unwrap").?);
    try std.testing.expectEqual(ReturnKind.error_union, methods.get("tryUnwrap").?);
}

test "parseFileTypeContext parses packed and extern types" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const content =
        \\const Flags = packed struct {
        \\    a: bool,
        \\    pub fn clear(self: *Flags) void {
        \\        _ = self;
        \\    }
        \\};
        \\const CHandle = extern struct {
        \\    fd: i32,
        \\    pub fn read(self: *CHandle) !u32 {
        \\        _ = self;
        \\        return 0;
        \\    }
        \\};
    ;

    var ctx = try parseFileTypeContext(a, content);
    defer ctx.deinit(a);

    const flag_methods = ctx.struct_methods.get("Flags").?;
    try std.testing.expectEqual(ReturnKind.void_type, flag_methods.get("clear").?);

    const handle_methods = ctx.struct_methods.get("CHandle").?;
    try std.testing.expectEqual(ReturnKind.error_union, handle_methods.get("read").?);
}

test "isSafeToDiscard uses TypeContext for user-defined void methods" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var ctx = TypeContext.init();
    defer ctx.deinit(a);

    // Register: MyLogger.clear returns void
    var methods = std.StringHashMapUnmanaged(ReturnKind){};
    try methods.put(a, "clear", .void_type);
    try ctx.struct_methods.put(a, "MyLogger", methods);
    try ctx.var_types.put(a, "logger", "MyLogger");

    // _ = logger.clear() should be safe (parsed void)
    try std.testing.expect(isSafeToDiscard("_ = logger.clear()", &ctx));
}

test "isSafeToDiscard rejects user-defined error methods" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var ctx = TypeContext.init();
    defer ctx.deinit(a);

    // Register: MyLogger.clear returns !void
    var methods = std.StringHashMapUnmanaged(ReturnKind){};
    try methods.put(a, "clear", .error_union);
    try ctx.struct_methods.put(a, "MyLogger", methods);
    try ctx.var_types.put(a, "logger", "MyLogger");

    // _ = logger.clear() should NOT be safe (error_union)
    try std.testing.expect(!isSafeToDiscard("_ = logger.clear()", &ctx));
}

test "buildNoFreeParamFunctions detects single-line call" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const content =
        \\var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        \\const alloc = arena.allocator();
        \\try doStuff(alloc, 42);
    ;
    var result = try buildNoFreeParamFunctions(a, content);
    defer result.deinit(a);

    try std.testing.expect(result.contains("doStuff"));
}

test "buildNoFreeParamFunctions detects multi-line call" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const content =
        \\var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        \\checksum +%= try run_benchmark(
        \\    &bench,
        \\    scenario.name,
        \\    searches,
        \\    arena.allocator(),
        \\    &prng,
        \\);
    ;
    var result = try buildNoFreeParamFunctions(a, content);
    defer result.deinit(a);

    try std.testing.expect(result.contains("run_benchmark"));
}

test "buildNoFreeParamFunctions skips function definitions" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const content =
        \\var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        \\fn doStuff(arena: std.mem.Allocator) !void {
        \\}
    ;
    var result = try buildNoFreeParamFunctions(a, content);
    defer result.deinit(a);

    // "doStuff" should NOT be detected — it's a definition, not a call
    try std.testing.expect(!result.contains("doStuff"));
}

// ============================================================================
// findAllocCall pattern detection tests
// ============================================================================

test "findAllocCall detects .dupe(" {
    const result = findAllocCall("    const copy = try allocator.dupe(u8, original);", null);
    try std.testing.expect(result != null);
    try std.testing.expect(!result.?.is_create);
}

test "findAllocCall detects .dupeZ(" {
    const result = findAllocCall("    const copy = try allocator.dupeZ(u8, original);", null);
    try std.testing.expect(result != null);
    try std.testing.expect(!result.?.is_create);
}

test "findAllocCall detects .allocPrint(" {
    const result = findAllocCall("    const msg = try std.fmt.allocPrint(allocator, \"{d}\", .{42});", null);
    try std.testing.expect(result != null);
}

test "findAllocCall detects .toOwnedSlice(" {
    const result = findAllocCall("    const slice = try list.toOwnedSlice();", null);
    try std.testing.expect(result != null);
}

test "findAllocCall detects .readFileAlloc(" {
    const result = findAllocCall("    const data = try dir.readFileAlloc(allocator, \"file.txt\", 1024);", null);
    try std.testing.expect(result != null);
}

test "findAllocCall detects .realpathAlloc(" {
    const result = findAllocCall("    const path = try std.fs.cwd().realpathAlloc(allocator, \".\");", null);
    try std.testing.expect(result != null);
}

test "findAllocCall detects .stringifyAlloc(" {
    const result = findAllocCall("    const json = try std.json.stringifyAlloc(allocator, value, .{});", null);
    try std.testing.expect(result != null);
}

test "findAllocCall detects .replaceOwned(" {
    const result = findAllocCall("    const out = try std.mem.replaceOwned(u8, allocator, input, \"a\", \"b\");", null);
    try std.testing.expect(result != null);
}

test "findAllocCall detects .concatWithSentinel(" {
    const result = findAllocCall("    const out = try allocator.concatWithSentinel(u8, slices, 0);", null);
    try std.testing.expect(result != null);
}

test "findAllocCall detects mem.concat(" {
    const result = findAllocCall("    const merged = try std.mem.concat(allocator, u8, &.{a, b});", null);
    try std.testing.expect(result != null);
}

test "findAllocCall detects mem.join(" {
    const result = findAllocCall("    const joined = try std.mem.join(allocator, \", \", parts);", null);
    try std.testing.expect(result != null);
}

test "findAllocCall detects process.getEnvVarOwned(" {
    const result = findAllocCall("    const home = try std.process.getEnvVarOwned(allocator, \"HOME\");", null);
    try std.testing.expect(result != null);
}

test "findAllocCall detects fs.getAppDataDir(" {
    const result = findAllocCall("    const dir = try std.fs.getAppDataDir(allocator, \"myapp\");", null);
    try std.testing.expect(result != null);
}

test "findAllocCall does NOT detect .clone(" {
    const result = findAllocCall("    const copy = try list.clone();", null);
    try std.testing.expect(result == null);
}

test "findAllocCall does NOT detect .append(" {
    const result = findAllocCall("    try list.append(allocator, item);", null);
    try std.testing.expect(result == null);
}

// ============================================================================
// analyzeCFGDeferCoverage tests for non-basic alloc patterns (ZA101/ZA102)
// ============================================================================

test "analyzeCFGDeferCoverage detects dupe with no defer (ZA101)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_content =
        \\fn leaky_dupe(alloc: std.mem.Allocator) !void {
        \\    const data = try alloc.dupe(u8, "hello");
        \\    _ = data;
        \\}
    ;

    var lines_list = std.ArrayListUnmanaged([]const u8).empty;
    defer lines_list.deinit(allocator);

    var line_iter = mem.splitScalar(u8, test_content, '\n');
    while (line_iter.next()) |line| {
        try lines_list.append(allocator, line);
    }

    var cfg = try buildCFG(allocator, "leaky_dupe", 1, lines_list.items);
    defer cfg.deinit();

    var issues = try analyzeCFGDeferCoverage(
        allocator,
        &cfg,
        lines_list.items,
        1,
        "test_dupe_no_defer.zig",
        null,
    );
    defer deinitIssues(&issues, allocator);

    var found_issue = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER)) {
            found_issue = true;
            break;
        }
    }
    try std.testing.expect(found_issue);
}

test "analyzeCFGDeferCoverage detects allocPrint with no defer (ZA101)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_content =
        \\fn leaky_print(alloc: std.mem.Allocator) !void {
        \\    const msg = try std.fmt.allocPrint(alloc, "hi {d}", .{42});
        \\    _ = msg;
        \\}
    ;

    var lines_list = std.ArrayListUnmanaged([]const u8).empty;
    defer lines_list.deinit(allocator);

    var line_iter = mem.splitScalar(u8, test_content, '\n');
    while (line_iter.next()) |line| {
        try lines_list.append(allocator, line);
    }

    var cfg = try buildCFG(allocator, "leaky_print", 1, lines_list.items);
    defer cfg.deinit();

    var issues = try analyzeCFGDeferCoverage(
        allocator,
        &cfg,
        lines_list.items,
        1,
        "test_allocPrint_no_defer.zig",
        null,
    );
    defer deinitIssues(&issues, allocator);

    var found_issue = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER)) {
            found_issue = true;
            break;
        }
    }
    try std.testing.expect(found_issue);
}

test "analyzeCFGDeferCoverage no false positive for dupe with defer (ZA101)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_content =
        \\fn good_dupe(alloc: std.mem.Allocator) !void {
        \\    const data = try alloc.dupe(u8, "hello");
        \\    defer alloc.free(data);
        \\    process(data);
        \\}
    ;

    var lines_list = std.ArrayListUnmanaged([]const u8).empty;
    defer lines_list.deinit(allocator);

    var line_iter = mem.splitScalar(u8, test_content, '\n');
    while (line_iter.next()) |line| {
        try lines_list.append(allocator, line);
    }

    var cfg = try buildCFG(allocator, "good_dupe", 1, lines_list.items);
    defer cfg.deinit();

    var issues = try analyzeCFGDeferCoverage(
        allocator,
        &cfg,
        lines_list.items,
        1,
        "test_dupe_good.zig",
        null,
    );
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_dupe_good.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
        }
    }
}

test "analyzeCFGDeferCoverage no false positive for allocPrint with defer (ZA101)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_content =
        \\fn good_print(alloc: std.mem.Allocator) !void {
        \\    const msg = try std.fmt.allocPrint(alloc, "hi {d}", .{42});
        \\    defer alloc.free(msg);
        \\    process(msg);
        \\}
    ;

    var lines_list = std.ArrayListUnmanaged([]const u8).empty;
    defer lines_list.deinit(allocator);

    var line_iter = mem.splitScalar(u8, test_content, '\n');
    while (line_iter.next()) |line| {
        try lines_list.append(allocator, line);
    }

    var cfg = try buildCFG(allocator, "good_print", 1, lines_list.items);
    defer cfg.deinit();

    var issues = try analyzeCFGDeferCoverage(
        allocator,
        &cfg,
        lines_list.items,
        1,
        "test_allocPrint_good.zig",
        null,
    );
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_allocPrint_good.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
        }
    }
}

// ============================================================================
// analyzeCFGErrdeferCoverage tests for non-basic patterns (ZA103)
// ============================================================================

test "analyzeCFGErrdeferCoverage detects missing errdefer for dupe (ZA103)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn bad_errdefer_dupe(alloc: std.mem.Allocator) !void {
        \\    const data = try alloc.dupe(u8, "hello");
        \\    const more = try alloc.dupe(u8, "world");
        \\    defer alloc.free(data);
        \\    defer alloc.free(more);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_dupe_errdefer.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_dupe_errdefer.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var found_za103 = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER)) {
            found_za103 = true;
            break;
        }
    }
    try std.testing.expect(found_za103);
}

test "analyzeCFGErrdeferCoverage no false positive for dupe with errdefer (ZA103)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn good_errdefer_dupe(alloc: std.mem.Allocator) !void {
        \\    const data = try alloc.dupe(u8, "hello");
        \\    errdefer alloc.free(data);
        \\    const more = try alloc.dupe(u8, "world");
        \\    errdefer alloc.free(more);
        \\    process(data, more);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_dupe_good_errdefer.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_dupe_good_errdefer.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_dupe_good_errdefer.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER));
        }
    }
}

test "analyzeCFGErrdeferCoverage detects missing errdefer for allocPrint (ZA103)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn bad_errdefer_print(alloc: std.mem.Allocator) !void {
        \\    const msg = try std.fmt.allocPrint(alloc, "val={d}", .{42});
        \\    const more = try alloc.alloc(u8, 50);
        \\    defer alloc.free(msg);
        \\    defer alloc.free(more);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_print_errdefer.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_print_errdefer.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var found_za103 = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER)) {
            found_za103 = true;
            break;
        }
    }
    try std.testing.expect(found_za103);
}

// ============================================================================
// ZA101 additional unit tests: qualified functions, container methods, transfers
// ============================================================================

test "analyzeCFGDeferCoverage detects mem.concat with no defer (ZA101)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_content =
        \\fn leaky_concat(alloc: std.mem.Allocator) !void {
        \\    const data = try std.mem.concat(alloc, u8, &.{"a", "b"});
        \\    _ = data;
        \\}
    ;

    var lines_list = std.ArrayListUnmanaged([]const u8).empty;
    defer lines_list.deinit(allocator);

    var line_iter = mem.splitScalar(u8, test_content, '\n');
    while (line_iter.next()) |line| {
        try lines_list.append(allocator, line);
    }

    var cfg = try buildCFG(allocator, "leaky_concat", 1, lines_list.items);
    defer cfg.deinit();

    var issues = try analyzeCFGDeferCoverage(
        allocator,
        &cfg,
        lines_list.items,
        1,
        "test_concat_no_defer.zig",
        null,
    );
    defer deinitIssues(&issues, allocator);

    var found_issue = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER)) {
            found_issue = true;
            break;
        }
    }
    try std.testing.expect(found_issue);
}

test "analyzeCFGDeferCoverage detects toOwnedSlice with no defer (ZA101)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_content =
        \\fn leaky_owned(alloc: std.mem.Allocator) !void {
        \\    var list = std.ArrayList(u8).init(alloc);
        \\    defer list.deinit();
        \\    try list.appendSlice("hello");
        \\    const data = try list.toOwnedSlice();
        \\    _ = data;
        \\}
    ;

    var lines_list = std.ArrayListUnmanaged([]const u8).empty;
    defer lines_list.deinit(allocator);

    var line_iter = mem.splitScalar(u8, test_content, '\n');
    while (line_iter.next()) |line| {
        try lines_list.append(allocator, line);
    }

    var cfg = try buildCFG(allocator, "leaky_owned", 1, lines_list.items);
    defer cfg.deinit();

    var issues = try analyzeCFGDeferCoverage(
        allocator,
        &cfg,
        lines_list.items,
        1,
        "test_owned_no_defer.zig",
        null,
    );
    defer deinitIssues(&issues, allocator);

    var found_issue = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER)) {
            found_issue = true;
            break;
        }
    }
    try std.testing.expect(found_issue);
}

test "analyzeCFGDeferCoverage no false positive for arena allocator (ZA101)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn arena_usage() !void {
        \\    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        \\    defer arena.deinit();
        \\    const alloc = arena.allocator();
        \\    const data = try alloc.alloc(u8, 100);
        \\    _ = data;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_arena_skip.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_arena_skip.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_arena_skip.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
        }
    }
}

test "analyzeCFGDeferCoverage no false positive for ownership transfer via return (ZA101)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_content =
        \\fn factory(alloc: std.mem.Allocator) ![]u8 {
        \\    const data = try alloc.alloc(u8, 100);
        \\    return data;
        \\}
    ;

    var lines_list = std.ArrayListUnmanaged([]const u8).empty;
    defer lines_list.deinit(allocator);

    var line_iter = mem.splitScalar(u8, test_content, '\n');
    while (line_iter.next()) |line| {
        try lines_list.append(allocator, line);
    }

    var cfg = try buildCFG(allocator, "factory", 1, lines_list.items);
    defer cfg.deinit();

    var issues = try analyzeCFGDeferCoverage(
        allocator,
        &cfg,
        lines_list.items,
        1,
        "test_return_transfer.zig",
        null,
    );
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_return_transfer.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
        }
    }
}

test "analyzeCFGDeferCoverage no false positive for return toOwnedSlice (ZA101)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // Pattern: return list.toOwnedSlice(allocator) — ownership transferred to caller
    const code =
        \\const std = @import("std");
        \\
        \\fn getItems(alloc: std.mem.Allocator) ![]u8 {
        \\    var list = std.ArrayList(u8).init(alloc);
        \\    errdefer list.deinit();
        \\    try list.append(alloc, 42);
        \\    return list.toOwnedSlice(alloc);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_owned_return.zig", code);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_owned_return.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_owned_return.zig") and
            mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER))
        {
            std.debug.print("unexpected ZA101: {s} line {d}\n", .{ issue.message, issue.line });
            try std.testing.expect(false);
        }
    }
}

test "analyzeCFGDeferCoverage no false positive for const + return toOwnedSlice (ZA101)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // Pattern: const data = list.toOwnedSlice(alloc); return data
    const code =
        \\const std = @import("std");
        \\
        \\fn getFiltered(alloc: std.mem.Allocator) ![]u8 {
        \\    var list = std.ArrayList(u8).init(alloc);
        \\    errdefer list.deinit();
        \\    try list.append(alloc, 1);
        \\    const data = try list.toOwnedSlice(alloc);
        \\    return data;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_owned_const.zig", code);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_owned_const.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_owned_const.zig") and
            mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER))
        {
            std.debug.print("unexpected ZA101: {s} line {d}\n", .{ issue.message, issue.line });
            try std.testing.expect(false);
        }
    }
}

// ============================================================================
// ZA102 unit tests: create() without destroy
// ============================================================================

test "analyzeCFGDeferCoverage detects create with no destroy (ZA102)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn leaky_create(allocator: std.mem.Allocator) !void {
        \\    const node = try allocator.create(Node);
        \\    _ = node;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_create_no_destroy.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_create_no_destroy.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var found_za102 = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_CREATE_NO_DEFER)) {
            found_za102 = true;
            break;
        }
    }
    try std.testing.expect(found_za102);
}

test "analyzeCFGDeferCoverage no false positive for create with defer destroy (ZA102)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn good_create(allocator: std.mem.Allocator) !void {
        \\    const node = try allocator.create(Node);
        \\    defer allocator.destroy(node);
        \\    node.* = .{ .value = 42, .next = null };
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_create_good.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_create_good.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_create_good.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_CREATE_NO_DEFER));
        }
    }
}

test "analyzeCFGDeferCoverage no false positive for create with ownership transfer (ZA102)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_content =
        \\fn create_factory(allocator: std.mem.Allocator) !*Node {
        \\    const node = try allocator.create(Node);
        \\    node.* = .{ .value = 1, .next = null };
        \\    return node;
        \\}
    ;

    var lines_list = std.ArrayListUnmanaged([]const u8).empty;
    defer lines_list.deinit(allocator);

    var line_iter = mem.splitScalar(u8, test_content, '\n');
    while (line_iter.next()) |line| {
        try lines_list.append(allocator, line);
    }

    var cfg = try buildCFG(allocator, "create_factory", 1, lines_list.items);
    defer cfg.deinit();

    var issues = try analyzeCFGDeferCoverage(
        allocator,
        &cfg,
        lines_list.items,
        1,
        "test_create_return.zig",
        null,
    );
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_create_return.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_CREATE_NO_DEFER));
        }
    }
}

test "analyzeCFGDeferCoverage no false positive for create on arena allocator (ZA102)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn arena_create() !void {
        \\    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        \\    defer arena.deinit();
        \\    const alloc = arena.allocator();
        \\    const node = try alloc.create(Node);
        \\    _ = node;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_arena_create.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_arena_create.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_arena_create.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_CREATE_NO_DEFER));
        }
    }
}

// ============================================================================
// ZA103 additional tests: qualified functions, arena skip
// ============================================================================

test "analyzeCFGErrdeferCoverage detects missing errdefer for mem.concat (ZA103)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn bad_errdefer_concat(alloc: std.mem.Allocator) !void {
        \\    const data = try std.mem.concat(alloc, u8, &.{"a", "b"});
        \\    const more = try alloc.alloc(u8, 50);
        \\    defer alloc.free(data);
        \\    defer alloc.free(more);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_concat_errdefer.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_concat_errdefer.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var found_za103 = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER)) {
            found_za103 = true;
            break;
        }
    }
    try std.testing.expect(found_za103);
}

test "analyzeCFGErrdeferCoverage no false positive for arena allocator (ZA103)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn arena_no_errdefer() !void {
        \\    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        \\    defer arena.deinit();
        \\    const alloc = arena.allocator();
        \\    const data = try alloc.alloc(u8, 100);
        \\    const more = try alloc.alloc(u8, 200);
        \\    _ = data;
        \\    _ = more;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_arena_errdefer.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_arena_errdefer.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_arena_errdefer.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER));
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
        }
    }
}

// ============================================================================
// ZA105/ZA106 additional tests: alias UAF, defer safety
// ============================================================================

test "analyzeCFGMemory detects use-after-free with subscript access (ZA105)" {
    // Tests direct UAF: free(data) then data[idx] = val
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn uaf_subscript(allocator: std.mem.Allocator) void {
        \\    const data = allocator.alloc(u8, 100) catch return;
        \\    allocator.free(data);
        \\    data[0] = 42; // UAF: accessing freed memory
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_subscript_uaf.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_subscript_uaf.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var found_za105 = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_subscript_uaf.zig") and
            mem.eql(u8, issue.rule, RULE_USE_AFTER_FREE))
        {
            found_za105 = true;
            break;
        }
    }
    try std.testing.expect(found_za105);
}

test "analyzeCFGMemory no false positive for defer free (ZA105)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn proper_defer(allocator: std.mem.Allocator) void {
        \\    const data = allocator.alloc(u8, 100) catch return;
        \\    defer allocator.free(data);
        \\    data[0] = 42; // Valid: data is alive, defer runs AFTER function exits
        \\    process(data);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_defer_safe.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_defer_safe.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_defer_safe.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_USE_AFTER_FREE));
        }
    }
}

test "analyzeCFGMemory detects use-after-free through alias (ZA105)" {
    // Tests alias UAF: const alias = data; free(data); use(alias);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn alias_uaf(allocator: std.mem.Allocator) !void {
        \\    const data = try allocator.alloc(u8, 100);
        \\    const alias = data;
        \\    allocator.free(data);
        \\    process(alias);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_alias_uaf.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_alias_uaf.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var found_za105 = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_alias_uaf.zig") and
            mem.eql(u8, issue.rule, RULE_USE_AFTER_FREE))
        {
            found_za105 = true;
            break;
        }
    }
    try std.testing.expect(found_za105);
}

test "analyzeCFGMemory no FP for arena field chain (ZA101)" {
    // Arena accessed through struct field: self.arena.allocator().alloc()
    // Type-based detection: field declared as std.heap.ArenaAllocator
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\const std = @import("std");
        \\const Analyser = struct {
        \\    arena: std.heap.ArenaAllocator,
        \\    data: []const u8,
        \\};
        \\fn arena_field_alloc(self: *Analyser) !void {
        \\    const data = try self.arena.allocator().alloc(u8, 100);
        \\    process(data);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_arena_field.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_arena_field.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // No ZA101/ZA102/ZA103 should fire for arena field chain allocations
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_arena_field.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_CREATE_NO_DEFER));
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER));
        }
    }
}

test "analyzeCFGMemory no FP for FixedBufferAllocator field chain (ZA101)" {
    // FixedBufferAllocator accessed through struct field
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\const std = @import("std");
        \\const Parser = struct {
        \\    fba: std.heap.FixedBufferAllocator,
        \\    input: []const u8,
        \\};
        \\fn fba_field_alloc(parser: *Parser) !void {
        \\    const data = try parser.fba.allocator().alloc(u8, 64);
        \\    process(data);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_fba_field.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_fba_field.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_fba_field.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_CREATE_NO_DEFER));
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER));
        }
    }
}

// ============================================================================
// Arena Allocator Name-Based Heuristic Tests
// ============================================================================

test "no FP for struct field arena: Allocator (name-based heuristic, ZA101)" {
    // Field named "arena" with type Allocator (not ArenaAllocator) should be
    // treated as no-free. This is the Zig compiler's pervasive pattern:
    // const Sema = struct { arena: Allocator, ... };
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\const std = @import("std");
        \\const Allocator = std.mem.Allocator;
        \\const Sema = struct {
        \\    arena: Allocator,
        \\    gpa: Allocator,
        \\};
        \\fn analyze(sema: *Sema) !void {
        \\    const data = try sema.arena.alloc(u8, 100);
        \\    process(data);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_arena_name_field.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_arena_name_field.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_arena_name_field.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_CREATE_NO_DEFER));
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER));
        }
    }
}

test "no FP for function parameter arena: Allocator (ZA101)" {
    // Function parameter named "arena" with type Allocator should be no-free.
    // Pattern: fn foo(arena: Allocator) !void { arena.alloc(...) }
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\const std = @import("std");
        \\fn processData(arena: std.mem.Allocator) !void {
        \\    const data = try arena.alloc(u8, 256);
        \\    compute(data);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_arena_param.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_arena_param.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_arena_param.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER));
        }
    }
}

test "no FP for deep field chain self.ctx.arena.alloc (ZA101)" {
    // Deep chain: self.ctx.arena.alloc() where arena field is Allocator type
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\const std = @import("std");
        \\const Allocator = std.mem.Allocator;
        \\const Ctx = struct {
        \\    arena: Allocator,
        \\};
        \\const Worker = struct {
        \\    ctx: *Ctx,
        \\};
        \\fn doWork(self: *Worker) !void {
        \\    const buf = try self.ctx.arena.alloc(u8, 64);
        \\    process(buf);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_arena_deep_chain.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_arena_deep_chain.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_arena_deep_chain.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER));
        }
    }
}

test "no FP for allocPrint with arena param (ZA101)" {
    // std.fmt.allocPrint(arena, ...) where arena is a function parameter
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\const std = @import("std");
        \\fn formatName(arena: std.mem.Allocator, name: []const u8) ![]u8 {
        \\    const result = try std.fmt.allocPrint(arena, "Hello {s}", .{name});
        \\    return result;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_arena_allocprint.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_arena_allocprint.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_arena_allocprint.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER));
        }
    }
}

test "non-arena param allocator: Allocator SHOULD trigger ZA101" {
    // A parameter named "allocator" (not "arena") should still trigger warnings.
    // This verifies the heuristic is name-specific, not over-broad.
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\const std = @import("std");
        \\fn processData(alloc: std.mem.Allocator) !void {
        \\    const data = try alloc.alloc(u8, 256);
        \\    compute(data);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_non_arena_param.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_non_arena_param.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    // Should find at least one ZA101 or ZA103 for the non-arena allocator
    var found_memory_issue = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_non_arena_param.zig")) {
            if (mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER) or
                mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER))
            {
                found_memory_issue = true;
                break;
            }
        }
    }
    try std.testing.expect(found_memory_issue);
}

test "arena param no FP for ZA103 errdefer (name-based)" {
    // Arena-named parameter should not trigger ZA103 either
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\const std = @import("std");
        \\fn buildNode(arena: std.mem.Allocator) !*Node {
        \\    const node = try arena.create(Node);
        \\    return node;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_arena_za103.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_arena_za103.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_arena_za103.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER));
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_CREATE_NO_DEFER));
        }
    }
}

test "anonymous init syntax for FixedBufferAllocator (ZA101)" {
    // var fba: std.heap.FixedBufferAllocator = .init(&buf);
    // Zig 0.15+ anonymous init syntax
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\const std = @import("std");
        \\fn useFixedBuffer() !void {
        \\    var buf: [4096]u8 = undefined;
        \\    var fba: std.heap.FixedBufferAllocator = .init(&buf);
        \\    const alloc = fba.allocator();
        \\    const data = try alloc.alloc(u8, 100);
        \\    process(data);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_anon_init_fba.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_anon_init_fba.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_anon_init_fba.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
        }
    }
}

test "no FP for arena param used as receiver and first-arg (ZA103)" {
    // Reproduces git.zig pattern: fn init(arena: Allocator, ...) with arena.dupe() and allocPrint(arena, ...)
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\const std = @import("std");
        \\const Allocator = std.mem.Allocator;
        \\fn init(arena: Allocator, name: []const u8) ![]u8 {
        \\    const scheme = try arena.dupe(u8, name);
        \\    const user = try std.fmt.allocPrint(arena, "{s}", .{name});
        \\    _ = scheme;
        \\    return user;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_arena_param_mixed.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_arena_param_mixed.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_arena_param_mixed.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_CREATE_NO_DEFER));
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER));
        }
    }
}

test "no FP for arena as non-first parameter (ZA103)" {
    // Reproduces Value.zig pattern: fn sqrt(val, float_type, arena: Allocator, pt)
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\const std = @import("std");
        \\const Allocator = std.mem.Allocator;
        \\pub fn sqrt(val: u32, float_type: u32, arena: Allocator, pt: u32) ![]u8 {
        \\    const result_data = try arena.alloc(u8, float_type);
        \\    _ = val;
        \\    _ = pt;
        \\    return result_data;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_arena_third_param.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_arena_third_param.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_arena_third_param.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER));
        }
    }
}

test "no FP for multiline allocPrint with arena (ZA101)" {
    // Reproduces glibc.zig pattern: allocPrint(\n    arena,\n    fmt, ...)
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\const std = @import("std");
        \\fn buildStubs(gpa: std.mem.Allocator) !void {
        \\    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
        \\    defer arena_allocator.deinit();
        \\    const arena = arena_allocator.allocator();
        \\    const msg = try std.fmt.allocPrint(
        \\        arena,
        \\        "hello {s}",
        \\        .{"world"},
        \\    );
        \\    process(msg);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_multiline_allocprint.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_multiline_allocprint.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_multiline_allocprint.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER));
        }
    }
}

test "no FP for allocPrint with arena alias from ArenaAllocator (ZA101)" {
    // Reproduces glibc.zig pattern: arena_allocator.allocator() alias used in allocPrint
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\const std = @import("std");
        \\fn buildStubs(gpa: std.mem.Allocator) !void {
        \\    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
        \\    defer arena_allocator.deinit();
        \\    const arena = arena_allocator.allocator();
        \\    const msg = try std.fmt.allocPrint(arena, "hello {s}", .{"world"});
        \\    process(msg);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_arena_alias_allocprint.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_arena_alias_allocprint.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_arena_alias_allocprint.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER));
        }
    }
}

test "no FP for local arena alias from struct field access (ZA101)" {
    // Reproduces git.zig pattern: const arena = session.arena; arena.alloc(...)
    // where Session has arena: Allocator field
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\const std = @import("std");
        \\const Allocator = std.mem.Allocator;
        \\const Session = struct {
        \\    arena: Allocator,
        \\    data: []u8,
        \\};
        \\fn processSession(session: *Session) !void {
        \\    const arena = session.arena;
        \\    const buf = try arena.alloc(u8, 1024);
        \\    process(buf);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_local_arena_alias.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_local_arena_alias.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_local_arena_alias.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
        }
    }
}

test "no FP for non-memory alloc method (ZA103)" {
    // Non-allocator structs can have .alloc() methods (e.g. SPIR-V register allocation).
    // These should NOT trigger ZA101/ZA103 since they don't allocate heap memory.
    // std.mem.Allocator.alloc() always takes a type as first arg (u8, MyStruct, etc.).
    // Non-memory .alloc() takes runtime values (ids, counts, etc.).
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\const std = @import("std");
        \\const CodeGen = struct {
        \\    data: []u8,
        \\    pub fn alloc(self: *CodeGen, ty_id: u32, init: ?u32) !u32 {
        \\        _ = self; _ = ty_id; _ = init;
        \\        return 42;
        \\    }
        \\};
        \\fn emitCode(cg: *CodeGen) !void {
        \\    const tmp_id = try cg.alloc(object_ty_id, null);
        \\    const result_id = try cg.alloc(child_ty_id, null);
        \\    process(tmp_id, result_id);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_nonmem_alloc.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_nonmem_alloc.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_nonmem_alloc.zig")) {
            // Non-memory .alloc() should NOT trigger memory warnings
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER));
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_ALLOC_NO_ERRDEFER));
        }
    }
}

test "real alloc with type arg still triggers (ZA101)" {
    // Ensure that real allocator.alloc(u8, 100) still triggers warnings
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\const std = @import("std");
        \\fn leaky(allocator: std.mem.Allocator) !void {
        \\    const buf = try allocator.alloc(u8, 1024);
        \\    process(buf);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_real_alloc.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_real_alloc.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var found_memory_warning = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_real_alloc.zig") and
            mem.eql(u8, issue.rule, RULE_ALLOC_NO_DEFER))
        {
            found_memory_warning = true;
        }
    }
    try std.testing.expect(found_memory_warning);
}

// ============================================================================
// ZA204 Tests — `= undefined` detection
// ============================================================================

test "ZA204 fires for unfilled var undefined" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\const std = @import("std");
        \\fn foo() void {
        \\    var x: u32 = undefined;
        \\    _ = x;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_za204.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_za204.zig"), {});

    var issues = try analyzeErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var found = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_UNDEFINED_USAGE) and
            mem.eql(u8, issue.file, "test_za204.zig"))
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "ZA204 no FP for memset after undefined" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\const std = @import("std");
        \\fn foo() void {
        \\    var buf: [256]u8 = undefined;
        \\    @memset(&buf, 0);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_za204_fill.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_za204_fill.zig"), {});

    var issues = try analyzeErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_za204_fill.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_UNDEFINED_USAGE));
        }
    }
}

// ============================================================================
// ZA202/ZA203 Tests — catch/orelse unreachable via errors path
// ============================================================================

test "ZA202 catch unreachable fires via analyzeErrors" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn foo() void {
        \\    const x = bar() catch unreachable;
        \\    _ = x;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_za202.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_za202.zig"), {});

    var issues = try analyzeErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var found = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_CATCH_UNREACHABLE) and
            mem.eql(u8, issue.file, "test_za202.zig"))
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "ZA203 orelse unreachable fires via analyzeErrors" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn foo(opt: ?u32) void {
        \\    const x = opt orelse unreachable;
        \\    _ = x;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_za203.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_za203.zig"), {});

    var issues = try analyzeErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var found = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_ORELSE_UNREACHABLE) and
            mem.eql(u8, issue.file, "test_za203.zig"))
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

// ============================================================================
// ZA207 Tests — catch undefined
// ============================================================================

test "ZA207 catch undefined fires" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn foo() void {
        \\    const x = bar() catch undefined;
        \\    _ = x;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_za207.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_za207.zig"), {});

    var issues = try analyzeErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var found = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_CATCH_UNDEFINED) and
            mem.eql(u8, issue.file, "test_za207.zig"))
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "ZA207 catch |_| undefined does NOT fire" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn foo() void {
        \\    const x = bar() catch |_| undefined;
        \\    _ = x;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_za207_no_fp.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_za207_no_fp.zig"), {});

    var issues = try analyzeErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_za207_no_fp.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_CATCH_UNDEFINED));
        }
    }
}

// ============================================================================
// ZA208 Tests — @panic detection
// ============================================================================

test "ZA208 @panic fires in non-test context" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn foo() void {
        \\    @panic("something went wrong");
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_za208.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_za208.zig"), {});

    var issues = try analyzeErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var found = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_PANIC) and
            mem.eql(u8, issue.file, "test_za208.zig"))
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "ZA208 @panic does NOT fire in test block" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\test "my test" {
        \\    @panic("expected in test");
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_za208_test.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_za208_test.zig"), {});

    var issues = try analyzeErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.file, "test_za208_test.zig")) {
            try std.testing.expect(!mem.eql(u8, issue.rule, RULE_PANIC));
        }
    }
}

// ============================================================================
// ZA206 Tests — exit() bypasses defers (expanded for posix.exit)
// ============================================================================

test "ZA206 std.posix.exit fires" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn cleanup() void {
        \\    defer allocator.free(data);
        \\    std.posix.exit(1);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_za206_posix.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_za206_posix.zig"), {});

    var issues = try analyzeErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var found = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_EXIT_BYPASSES_DEFER) and
            mem.eql(u8, issue.file, "test_za206_posix.zig"))
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "ZA105: no false positive on variable reassignment after free" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // Pattern: free(x); x = try alloc(); use(x) — NOT use-after-free
    const code =
        \\const std = @import("std");
        \\
        \\fn processLoop(alloc: std.mem.Allocator) !void {
        \\    var buf = try alloc.alloc(u8, 64);
        \\    alloc.free(buf);
        \\    buf = try alloc.alloc(u8, 128);
        \\    process(buf);
        \\    alloc.free(buf);
        \\}
        \\fn process(d: []u8) void { _ = d; }
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_reassign.zig", code);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_reassign.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_USE_AFTER_FREE) and
            mem.eql(u8, issue.file, "test_reassign.zig"))
        {
            std.debug.print("unexpected ZA105: {s} line {d}\n", .{ issue.message, issue.line });
            try std.testing.expect(false);
        }
    }
}

test "ZA105: no false positive on for-loop capture variable" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // Pattern: for (items) |item| { alloc.free(item); } — NOT use-after-free
    // The capture |item| creates a new binding, not a use of a prior "item"
    const code =
        \\const std = @import("std");
        \\
        \\fn cleanup(alloc: std.mem.Allocator) !void {
        \\    const item = try alloc.alloc(u8, 32);
        \\    alloc.free(item);
        \\    const items = try alloc.alloc([]u8, 4);
        \\    for (items) |item| {
        \\        alloc.free(item);
        \\    }
        \\    alloc.free(items);
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_capture.zig", code);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_capture.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_USE_AFTER_FREE) and
            mem.eql(u8, issue.file, "test_capture.zig"))
        {
            std.debug.print("unexpected ZA105: {s} line {d}\n", .{ issue.message, issue.line });
            try std.testing.expect(false);
        }
    }
}

test "ZA105: still detects real use-after-free with reassignment check" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // Real UAF: free(x); use(x) — no reassignment between
    const code =
        \\const std = @import("std");
        \\
        \\fn realUAF(alloc: std.mem.Allocator) void {
        \\    const data = alloc.alloc(u8, 100) catch return;
        \\    alloc.free(data);
        \\    process(data);
        \\}
        \\fn process(d: []u8) void { _ = d; }
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_real_uaf.zig", code);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_real_uaf.zig"), {});

    var issues = try analyzeCFGMemory(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var uaf_found = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_USE_AFTER_FREE) and
            mem.eql(u8, issue.file, "test_real_uaf.zig"))
        {
            uaf_found = true;
            break;
        }
    }
    try std.testing.expect(uaf_found);
}

test "findVarUseOnLine skips capture bindings" {
    // |item| capture — not a use
    try std.testing.expect(findVarUseOnLine("for (items) |item| {", "item") == null);
    // |key, value| multi-capture
    try std.testing.expect(findVarUseOnLine("switch (x) { |val| => {},", "val") == null);
    // catch |err| capture
    try std.testing.expect(findVarUseOnLine("} catch |err| {", "err") == null);
    // Normal use — should still be detected
    try std.testing.expect(findVarUseOnLine("process(item);", "item") != null);
    // Use in free — findVarUseOnLine still finds it (filtered by isUAFSkipLine)
    try std.testing.expect(findVarUseOnLine("alloc.free(item);", "item") != null);
}

test "hasDirectReassignment detects variable reassignment" {
    try std.testing.expect(hasDirectReassignment("buf = try alloc.alloc(u8, 128);", "buf"));
    try std.testing.expect(hasDirectReassignment("x = newValue();", "x"));
    // Not a reassignment: comparison
    try std.testing.expect(!hasDirectReassignment("if (buf == null) return;", "buf"));
    // Not a reassignment: subscript access
    try std.testing.expect(!hasDirectReassignment("buf[0] = 42;", "buf"));
    // Not a reassignment: field access
    try std.testing.expect(!hasDirectReassignment("self.buf = data;", "buf"));
    // Not present at all
    try std.testing.expect(!hasDirectReassignment("other = 5;", "buf"));
}

// ============================================================================
// ZA202 Suppression Tests — @TypeOf and bufPrint
// ============================================================================

test "ZA202 suppressed inside @TypeOf" {
    // @TypeOf(expr catch unreachable) is compile-time only, never executed
    const issue = checkCatchUnreachable(
        "const T = @TypeOf(pool.query(\"\", &.{}) catch unreachable);",
        "test.zig",
        1,
        null,
    );
    try std.testing.expect(issue == null);
}

test "ZA202 suppressed for bufPrint same-line" {
    // bufPrint(...) catch unreachable — only error is NoSpaceLeft
    const issue = checkCatchUnreachable(
        "const s = std.fmt.bufPrint(&buf, \"{d}\", .{val}) catch unreachable;",
        "test.zig",
        1,
        null,
    );
    try std.testing.expect(issue == null);
}

test "ZA202 suppressed for bufPrintZ same-line" {
    const issue = checkCatchUnreachable(
        "const s = std.fmt.bufPrintZ(&buf, \"{d}\", .{val}) catch unreachable;",
        "test.zig",
        1,
        null,
    );
    try std.testing.expect(issue == null);
}

test "ZA202 suppressed for bufPrint multi-line" {
    // Multi-line: bufPrint( is on a preceding line, catch unreachable on current
    const prev = [_][]const u8{
        "return std.fmt.bufPrint(",
        "    &buf,",
        "    \"0x{x}\",",
        "    .{block_num},",
    };
    const issue = checkCatchUnreachable(
        ") catch unreachable;",
        "test.zig",
        5,
        &prev,
    );
    try std.testing.expect(issue == null);
}

test "ZA202 NOT suppressed for regular catch unreachable" {
    // Normal catch unreachable should still fire
    const issue = checkCatchUnreachable(
        "const x = bar() catch unreachable;",
        "test.zig",
        1,
        null,
    );
    try std.testing.expect(issue != null);
}

test "ZA202 NOT suppressed for non-bufPrint multi-line" {
    // Some other multi-line call — should still fire
    const prev = [_][]const u8{
        "const result = someOtherFunction(",
        "    arg1,",
    };
    const issue = checkCatchUnreachable(
        ") catch unreachable;",
        "test.zig",
        3,
        &prev,
    );
    try std.testing.expect(issue != null);
}

// ============================================================================
// ZA201 Suppression Tests — cleanup functions and writer catch {}
// ============================================================================

test "ZA201 suppressed in deinit function" {
    const issue = checkSilentCatch("resource.revoke() catch {}", "test.zig", 1, "deinit", null);
    try std.testing.expect(issue == null);
}

test "ZA201 suppressed in shutdown function" {
    const issue = checkSilentCatch("lease.revoke() catch {}", "test.zig", 1, "shutdown", null);
    try std.testing.expect(issue == null);
}

test "ZA201 suppressed in cleanup function" {
    const issue = checkSilentCatch("conn.close() catch {}", "test.zig", 1, "cleanup", null);
    try std.testing.expect(issue == null);
}

test "ZA201 suppressed for writer.print catch {}" {
    const issue = checkSilentCatch(
        "writer.print(\"{{\\\"key\\\":\\\"{s}\\\"}}\", .{val}) catch {}",
        "test.zig",
        1,
        "handleRequest",
        null,
    );
    try std.testing.expect(issue == null);
}

test "ZA201 suppressed for writer.writeAll catch {}" {
    const issue = checkSilentCatch(
        "writer.writeAll(data) catch {}",
        "test.zig",
        1,
        "streamResponse",
        null,
    );
    try std.testing.expect(issue == null);
}

test "ZA201 NOT suppressed in regular function" {
    const issue = checkSilentCatch("foo() catch {}", "test.zig", 1, "processData", null);
    try std.testing.expect(issue != null);
}

// ============================================================================
// Enhancement 1: ZA202/ZA203 suppressed in test blocks
// ============================================================================

test "ZA202 suppressed in test block via analyzeErrors" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // catch unreachable inside a test block should NOT fire ZA202
    const test_content =
        \\const std = @import("std");
        \\test "my test" {
        \\    const x = bar() catch unreachable;
        \\    _ = x;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "za202_test_block.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "za202_test_block.zig"), {});

    var issues = try analyzeErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_CATCH_UNREACHABLE)) {
            return error.TestUnexpectedResult; // Should not fire in test block
        }
    }
}

test "ZA203 suppressed in test block via analyzeErrors" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // orelse unreachable inside a test block should NOT fire ZA203
    const test_content =
        \\const std = @import("std");
        \\test "my test" {
        \\    const x = std.mem.indexOf(u8, "hello", "lo") orelse unreachable;
        \\    _ = x;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "za203_test_block.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "za203_test_block.zig"), {});

    var issues = try analyzeErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_ORELSE_UNREACHABLE)) {
            return error.TestUnexpectedResult; // Should not fire in test block
        }
    }
}

test "ZA202 still fires outside test block" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const test_content =
        \\fn foo() void {
        \\    const x = bar() catch unreachable;
        \\    _ = x;
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "za202_nontst.zig", test_content);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "za202_nontst.zig"), {});

    var issues = try analyzeErrors(allocator, &graph);
    defer deinitIssues(&issues, allocator);

    var found = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_CATCH_UNREACHABLE)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

// ============================================================================
// Enhancement 3: ZA201 suppressed for while(expr catch {}) |val|
// ============================================================================

test "ZA201 suppressed for while condition catch {}" {
    // while (iter.next() catch {}) |val| — catch converts error to optional
    const issue = checkSilentCatch(
        "while (iter.next() catch {}) |val| {",
        "test.zig",
        1,
        "process",
        null,
    );
    try std.testing.expect(issue == null);
}

test "ZA201 suppressed for if condition catch {}" {
    const issue = checkSilentCatch(
        "if (getData() catch {}) |data| {",
        "test.zig",
        1,
        "process",
        null,
    );
    try std.testing.expect(issue == null);
}

test "ZA201 NOT suppressed for catch {} outside condition" {
    // Regular statement — should still fire
    const issue = checkSilentCatch(
        "const x = foo() catch {};",
        "test.zig",
        1,
        "process",
        null,
    );
    try std.testing.expect(issue != null);
}

// ============================================================================
// Enhancement 4: ZA201 suppressed for multi-line defer catch {}
// ============================================================================

test "ZA201 suppressed for multi-line defer catch {}" {
    const prev = [_][]const u8{
        "defer std.fs.cwd()",
        "    .openFile(\"x\", .{})",
    };
    const issue = checkSilentCatch(
        ".close() catch {}",
        "test.zig",
        3,
        "init",
        &prev,
    );
    // .close() is a cleanup method — already suppressed by isCleanupMethodCall
    try std.testing.expect(issue == null);
}

test "ZA201 suppressed for multi-line defer non-cleanup catch {}" {
    const prev = [_][]const u8{
        "defer obj",
        "    .flush()",
    };
    const issue = checkSilentCatch(
        "    .finalize() catch {}",
        "test.zig",
        3,
        "init",
        &prev,
    );
    // Not a recognized cleanup method, but continuation of defer expression
    try std.testing.expect(issue == null);
}

// ============================================================================
// Enhancement 5: configurable threshold alias
// ============================================================================

test "setThresholdValue accepts max_function_lines alias" {
    var th = Thresholds{};
    setThresholdValue(&th, "max_function_lines", 75);
    try std.testing.expectEqual(@as(usize, 75), th.max_function_lines);
}

test "setThresholdValue accepts max_lines" {
    var th = Thresholds{};
    setThresholdValue(&th, "max_lines", 60);
    try std.testing.expectEqual(@as(usize, 60), th.max_function_lines);
}

// ============================================================================
// Enhancement 2: word-boundary matching in checkOwnershipInLine
// ============================================================================

test "isInsideWhileCondition detects catch in while parens" {
    try std.testing.expect(isInsideWhileCondition("while (iter.next() catch {}) |val| {", 19));
}

test "isInsideWhileCondition rejects catch outside parens" {
    try std.testing.expect(!isInsideWhileCondition("const x = foo() catch {};", 16));
}

// ============================================================================
// ZA304 Suppression Tests — data dispatch functions
// ============================================================================

test "isDataDispatchFunction recognizes fromJson" {
    try std.testing.expect(isDataDispatchFunction("fromJson"));
    try std.testing.expect(isDataDispatchFunction("fromJsonObject"));
    try std.testing.expect(isDataDispatchFunction("parseJson"));
    try std.testing.expect(isDataDispatchFunction("deserialize"));
    try std.testing.expect(isDataDispatchFunction("loadConfig"));
    try std.testing.expect(isDataDispatchFunction("applyEnvVar"));
    // Prefix matches
    try std.testing.expect(isDataDispatchFunction("parseBlock"));
    try std.testing.expect(isDataDispatchFunction("parseTransaction"));
    try std.testing.expect(isDataDispatchFunction("parseReceipt"));
    try std.testing.expect(isDataDispatchFunction("parseLog"));
    try std.testing.expect(isDataDispatchFunction("decodeHeader"));
    try std.testing.expect(isDataDispatchFunction("encodeResponse"));
    try std.testing.expect(isDataDispatchFunction("applyConfig"));
}

test "isDataDispatchFunction rejects regular names" {
    try std.testing.expect(!isDataDispatchFunction("processBlock"));
    try std.testing.expect(!isDataDispatchFunction("handleRequest"));
    try std.testing.expect(!isDataDispatchFunction("init"));
    try std.testing.expect(!isDataDispatchFunction(""));
}

test "branchLimit applies 8x for data dispatch" {
    try std.testing.expectEqual(@as(usize, 96), branchLimit(12, false, true));
    try std.testing.expectEqual(@as(usize, 36), branchLimit(12, true, false));
    try std.testing.expectEqual(@as(usize, 12), branchLimit(12, false, false));
}

test "ZA304 suppressed for fromJson with many branches" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // fromJson with 20 branches (20 > 12 default, but 20 < 48 dispatch limit)
    const code =
        \\fn fromJson(obj: anytype) @This() {
        \\    if (obj.get("f1")) |v| { _ = v; }
        \\    if (obj.get("f2")) |v| { _ = v; }
        \\    if (obj.get("f3")) |v| { _ = v; }
        \\    if (obj.get("f4")) |v| { _ = v; }
        \\    if (obj.get("f5")) |v| { _ = v; }
        \\    if (obj.get("f6")) |v| { _ = v; }
        \\    if (obj.get("f7")) |v| { _ = v; }
        \\    if (obj.get("f8")) |v| { _ = v; }
        \\    if (obj.get("f9")) |v| { _ = v; }
        \\    if (obj.get("f10")) |v| { _ = v; }
        \\    if (obj.get("f11")) |v| { _ = v; }
        \\    if (obj.get("f12")) |v| { _ = v; }
        \\    if (obj.get("f13")) |v| { _ = v; }
        \\    if (obj.get("f14")) |v| { _ = v; }
        \\    if (obj.get("f15")) |v| { _ = v; }
        \\    if (obj.get("f16")) |v| { _ = v; }
        \\    if (obj.get("f17")) |v| { _ = v; }
        \\    if (obj.get("f18")) |v| { _ = v; }
        \\    if (obj.get("f19")) |v| { _ = v; }
        \\    if (obj.get("f20")) |v| { _ = v; }
        \\    return .{};
        \\}
    ;

    const analysis = try createTestFileAnalysis(allocator, "test_dispatch.zig", code);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "test_dispatch.zig"), {});

    var issues = try analyzeComplexity(allocator, &graph, .{});
    defer deinitIssues(&issues, allocator);

    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_TOO_MANY_BRANCHES) and
            mem.eql(u8, issue.file, "test_dispatch.zig"))
        {
            std.debug.print("unexpected ZA304 for fromJson: {s}\n", .{issue.message});
            try std.testing.expect(false);
        }
    }
}

// ============================================================================
// ZA303 Tests — self parameter exclusion
// ============================================================================

test "countFnParams excludes self parameter" {
    // Method with self + 3 params = 3 semantic params (not 4)
    try std.testing.expectEqual(@as(usize, 3), countFnParams("fn query(self: *Pool, sql: []const u8, params: anytype, opts: Options) !Result"));
    // Method with self + 2 params = 2 semantic params
    try std.testing.expectEqual(@as(usize, 2), countFnParams("fn exec(self: *Pool, sql: []const u8, params: anytype) !void"));
    // Free function with 3 params = 3 (no self to exclude)
    try std.testing.expectEqual(@as(usize, 3), countFnParams("fn process(a: u32, b: u32, c: u32) void"));
    // Method with just self = 0 semantic params
    try std.testing.expectEqual(@as(usize, 0), countFnParams("fn deinit(self: *Self) void"));
}

test "isInsideTypeOf detects @TypeOf context" {
    try std.testing.expect(isInsideTypeOf("const T = @TypeOf(foo() catch unreachable);", 30, null));
    try std.testing.expect(!isInsideTypeOf("const x = foo() catch unreachable;", 22, null));
}

test "isInsideTypeOf detects multi-line @TypeOf with inner call spanning lines" {
    // Inner function call spans multiple lines, catch unreachable on the last
    const prev = [_][]const u8{
        "const ReceiptsHolder = @TypeOf(",
        "    block_fetcher.fetchBlockReceipts(",
    };
    const line = "        undefined, 0) catch unreachable,";
    const col = mem.indexOf(u8, line, "catch unreachable").?;
    try std.testing.expect(isInsideTypeOf(line, col, &prev));
    // No preceding context
    try std.testing.expect(!isInsideTypeOf(line, col, null));
}

test "isInsideTypeOf detects balanced-paren line inside @TypeOf" {
    // pipeline.zig pattern: current line has balanced parens but is inside @TypeOf
    const prev2 = [_][]const u8{
        "const ReceiptsHolder = @TypeOf(",
    };
    const line = "block_fetcher.fetchBlockReceipts(undefined, 0) catch unreachable,";
    const col = mem.indexOf(u8, line, "catch unreachable").?;
    try std.testing.expect(isInsideTypeOf(line, col, &prev2));
    // Same line but no @TypeOf wrapper — should NOT suppress
    const prev3 = [_][]const u8{
        "const result = someFunction(",
    };
    try std.testing.expect(!isInsideTypeOf(line, col, &prev3));
}

test "isBufPrintCatchUnreachable detects same-line pattern" {
    try std.testing.expect(isBufPrintCatchUnreachable("std.fmt.bufPrint(&buf, \"{d}\", .{x}) catch unreachable", null));
    try std.testing.expect(isBufPrintCatchUnreachable("std.fmt.bufPrintZ(&buf, \"{d}\", .{x}) catch unreachable", null));
    try std.testing.expect(!isBufPrintCatchUnreachable(") catch unreachable;", null));
}

test "isBufPrintCatchUnreachable detects multi-line pattern" {
    const prev = [_][]const u8{
        "return std.fmt.bufPrint(",
        "    &buf,",
        "    \"0x{x}\",",
        "    .{block_num},",
    };
    // catch unreachable is on the closing line, bufPrint( is 4 lines back
    try std.testing.expect(isBufPrintCatchUnreachable(") catch unreachable;", &prev));
}

test "hasBufPrintCall detects bufPrint patterns" {
    try std.testing.expect(hasBufPrintCall("return std.fmt.bufPrint(&buf, fmt, args)"));
    try std.testing.expect(hasBufPrintCall("const s = bufPrintZ(&buf, \"{d}\", .{x})"));
    try std.testing.expect(!hasBufPrintCall(") catch unreachable;"));
}

test "isCleanupFunction matches cleanup names" {
    try std.testing.expect(isCleanupFunction("deinit"));
    try std.testing.expect(isCleanupFunction("cleanup"));
    try std.testing.expect(isCleanupFunction("shutdown"));
    try std.testing.expect(isCleanupFunction("close"));
    try std.testing.expect(isCleanupFunction("destroy"));
    try std.testing.expect(isCleanupFunction("shutdownLeader"));
    try std.testing.expect(isCleanupFunction("cleanupResources"));
    try std.testing.expect(!isCleanupFunction("processData"));
    try std.testing.expect(!isCleanupFunction("init"));
    try std.testing.expect(!isCleanupFunction(""));
}

test "isStreamWriteCall matches writer patterns" {
    try std.testing.expect(isStreamWriteCall("writer.print(\"data\") catch {}"));
    try std.testing.expect(isStreamWriteCall("writer.writeAll(buf) catch {}"));
    try std.testing.expect(isStreamWriteCall("writer.writeByte(0x0a) catch {}"));
    try std.testing.expect(!isStreamWriteCall("foo() catch {}"));
    try std.testing.expect(!isStreamWriteCall("db.query() catch {}"));
}

test "hasSelfParam detects self parameter" {
    try std.testing.expect(hasSelfParam("fn query(self: *Pool, sql: []const u8)", 8));
    try std.testing.expect(hasSelfParam("fn deinit(self: *Self)", 9));
    try std.testing.expect(!hasSelfParam("fn process(a: u32, b: u32)", 10));
}

test "isCleanupMethodCall matches cleanup method names" {
    try std.testing.expect(isCleanupMethodCall("self.client.leaseRevoke(lid) catch {}"));
    try std.testing.expect(isCleanupMethodCall("conn.close() catch {}"));
    try std.testing.expect(isCleanupMethodCall("resource.cleanup() catch {}"));
    try std.testing.expect(isCleanupMethodCall("pool.destroy() catch {}"));
    try std.testing.expect(isCleanupMethodCall("session.disconnect() catch {}"));
    try std.testing.expect(!isCleanupMethodCall("db.query() catch {}"));
    try std.testing.expect(!isCleanupMethodCall("api.fetch() catch {}"));
}

test "isStreamWriteCall matches writeSep pattern" {
    try std.testing.expect(isStreamWriteCall("ctr.writeSep(writer) catch {}"));
}

// ============================================================================
// ZA305/ZA306 — Cyclomatic and Cognitive Complexity Tests
// ============================================================================

// --- Unit tests for helper functions ---

test "countLineCyclomatic counts all decision points" {
    // Control flow keywords
    try std.testing.expectEqual(@as(usize, 1), countLineCyclomatic("if (x) {"));
    try std.testing.expectEqual(@as(usize, 1), countLineCyclomatic("} else if (y) {"));
    try std.testing.expectEqual(@as(usize, 1), countLineCyclomatic("} else {"));
    try std.testing.expectEqual(@as(usize, 1), countLineCyclomatic("for (items) |item| {"));
    try std.testing.expectEqual(@as(usize, 1), countLineCyclomatic("switch (x) {"));
    // Error handling
    try std.testing.expectEqual(@as(usize, 1), countLineCyclomatic("try foo();"));
    try std.testing.expectEqual(@as(usize, 1), countLineCyclomatic("x catch |e| {"));
    // Null coalescing and logical operators
    try std.testing.expectEqual(@as(usize, 1), countLineCyclomatic("const v = x orelse return;"));
    try std.testing.expectEqual(@as(usize, 2), countLineCyclomatic("if (a and b) {"));
    try std.testing.expectEqual(@as(usize, 2), countLineCyclomatic("if (a or b) {"));
    // Multiple decision points on one line
    try std.testing.expectEqual(@as(usize, 2), countLineCyclomatic("if (a and b) |v| {"));
    try std.testing.expectEqual(@as(usize, 2), countLineCyclomatic("try foo() catch |e| { return e; };"));
    // No decision points
    try std.testing.expectEqual(@as(usize, 0), countLineCyclomatic("var x: u32 = 0;"));
    try std.testing.expectEqual(@as(usize, 0), countLineCyclomatic("_ = allocator;"));
    try std.testing.expectEqual(@as(usize, 0), countLineCyclomatic("return .{};"));
    // Inline loops excluded (checked via hasNonInline)
    try std.testing.expectEqual(@as(usize, 0), countLineCyclomatic("inline for (fields) |f| {"));
    try std.testing.expectEqual(@as(usize, 0), countLineCyclomatic("inline while (cond) {"));
}

test "countLineCognitive weights by nesting and counts else/orelse" {
    // Top level (nest=0): 1 cost each
    try std.testing.expectEqual(@as(usize, 1), countLineCognitive("if (x) {", 0));
    try std.testing.expectEqual(@as(usize, 1), countLineCognitive("while (true) {", 0));
    try std.testing.expectEqual(@as(usize, 1), countLineCognitive("for (items) |item| {", 0));
    try std.testing.expectEqual(@as(usize, 1), countLineCognitive("switch (x) {", 0));
    try std.testing.expectEqual(@as(usize, 1), countLineCognitive("try foo();", 0));
    try std.testing.expectEqual(@as(usize, 1), countLineCognitive("x catch |e| {", 0));
    // else costs 1 at current nest but doesn't increase nesting
    try std.testing.expectEqual(@as(usize, 1), countLineCognitive("} else {", 0));
    // Nest level 3: 1 + 3 = 4
    try std.testing.expectEqual(@as(usize, 4), countLineCognitive("if (x) {", 3));
    try std.testing.expectEqual(@as(usize, 4), countLineCognitive("while (true) {", 3));
    // orelse always costs 1 regardless of nesting
    try std.testing.expectEqual(@as(usize, 1), countLineCognitive("x orelse return;", 0));
    try std.testing.expectEqual(@as(usize, 1), countLineCognitive("x orelse return;", 3));
    // and/or always cost 1 regardless of nesting
    try std.testing.expectEqual(@as(usize, 2), countLineCognitive("if (a and b) {", 0));
    try std.testing.expectEqual(@as(usize, 7), countLineCognitive("if (a and b) {", 5));
    // Non-branching lines cost 0
    try std.testing.expectEqual(@as(usize, 0), countLineCognitive("var x: u32 = 0;", 0));
    try std.testing.expectEqual(@as(usize, 0), countLineCognitive("x += 1;", 3));
}

test "opensCognitiveScope detects control keyword + brace" {
    try std.testing.expect(opensCognitiveScope("if (x) {"));
    try std.testing.expect(opensCognitiveScope("while (true) {"));
    try std.testing.expect(opensCognitiveScope("for (items) |item| {"));
    try std.testing.expect(opensCognitiveScope("switch (x) {"));
    try std.testing.expect(opensCognitiveScope("try foo() catch |e| {"));
    try std.testing.expect(!opensCognitiveScope("var x: u32 = 0;"));
    try std.testing.expect(!opensCognitiveScope("if (x) return;"));
    try std.testing.expect(!opensCognitiveScope("} else {"));
}

// --- Integration tests with exact counts ---

fn checkNoCyclomaticWarnings(issues: []const Issue, path: []const u8) !void {
    for (issues) |issue| {
        if (mem.eql(u8, issue.rule, RULE_CYCLOMATIC) and mem.eql(u8, issue.file, path)) {
            std.debug.print("unexpected ZA305 for {s}: {s}\n", .{ path, issue.message });
            return error.UnexpectedWarning;
        }
    }
}

fn checkNoCognitiveWarnings(issues: []const Issue, path: []const u8) !void {
    for (issues) |issue| {
        if (mem.eql(u8, issue.rule, RULE_COGNITIVE) and mem.eql(u8, issue.file, path)) {
            std.debug.print("unexpected ZA306 for {s}: {s}\n", .{ path, issue.message });
            return error.UnexpectedWarning;
        }
    }
}

test "ZA305: empty function has CCN 1, no warning" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const code = \\fn empty() void {}
    ;
    const analysis = try createTestFileAnalysis(allocator, "empty.zig", code);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "empty.zig"), {});

    var issues = try analyzeComplexity(allocator, &graph, .{});
    defer deinitIssues(&issues, allocator);
    try checkNoCyclomaticWarnings(issues.items, "empty.zig");
    try checkNoCognitiveWarnings(issues.items, "empty.zig");
}

test "ZA305: 5-decision-point function no warning at default threshold" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // 5 decision points (4 if + 1 while) → CCN = 6, below default 15
    const code =
        \\fn moderate(x: u32) u32 {
        \\    if (x == 0) return 1;
        \\    if (x == 1) return 2;
        \\    if (x == 2) return 3;
        \\    if (x == 3) return 4;
        \\    var i: u32 = 0;
        \\    while (i < 10) { i += 1; }
        \\    return 0;
        \\}
    ;
    const analysis = try createTestFileAnalysis(allocator, "moderate.zig", code);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "moderate.zig"), {});

    var issues = try analyzeComplexity(allocator, &graph, .{});
    defer deinitIssues(&issues, allocator);
    try checkNoCyclomaticWarnings(issues.items, "moderate.zig");
}

test "ZA305: 20-flat-if function triggers cyclomatic at lowered threshold" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // 20 flat if statements → CCN = 21, triggers at threshold 5
    const code =
        \\fn too_many(x: u32) u32 {
        \\    if (x == 0) return 0;
        \\    if (x == 1) return 1;
        \\    if (x == 2) return 2;
        \\    if (x == 3) return 3;
        \\    if (x == 4) return 4;
        \\    if (x == 5) return 5;
        \\    if (x == 6) return 6;
        \\    if (x == 7) return 7;
        \\    if (x == 8) return 8;
        \\    if (x == 9) return 9;
        \\    if (x == 10) return 10;
        \\    if (x == 11) return 11;
        \\    if (x == 12) return 12;
        \\    if (x == 13) return 13;
        \\    if (x == 14) return 14;
        \\    if (x == 15) return 15;
        \\    if (x == 16) return 16;
        \\    if (x == 17) return 17;
        \\    if (x == 18) return 18;
        \\    if (x == 19) return 19;
        \\    return 0;
        \\}
    ;
    const analysis = try createTestFileAnalysis(allocator, "too_many.zig", code);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "too_many.zig"), {});

    const th = Thresholds{ .max_cyclomatic = 5 };
    var issues = try analyzeComplexity(allocator, &graph, th);
    defer deinitIssues(&issues, allocator);

    var found = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_CYCLOMATIC) and mem.eql(u8, issue.file, "too_many.zig")) {
            found = true;
            try std.testing.expect(mem.containsAtLeast(u8, issue.message, 1, "cyclomatic complexity"));
        }
    }
    try std.testing.expect(found);
}

test "ZA306: flat branches have low cognitive, no warning" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // 10 flat if-else at top level → cognitive = ~10 (below 15)
    const code =
        \\fn flat(x: u32) u32 {
        \\    if (x == 0) return 1
        \\    else if (x == 1) return 2
        \\    else if (x == 2) return 3
        \\    else if (x == 3) return 4
        \\    else if (x == 4) return 5
        \\    else if (x == 5) return 6
        \\    else if (x == 6) return 7
        \\    else if (x == 7) return 8
        \\    else if (x == 8) return 9
        \\    else return 0;
        \\}
    ;
    const analysis = try createTestFileAnalysis(allocator, "flat.zig", code);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "flat.zig"), {});

    var issues = try analyzeComplexity(allocator, &graph, .{});
    defer deinitIssues(&issues, allocator);
    try checkNoCognitiveWarnings(issues.items, "flat.zig");
}

test "ZA306: nested structures produce higher cognitive than flat" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // while(nest1) > for(nest2) > if(nest3) > if(nest4)
    // Cognitive: 1 + 2 + 3 + 4 = 10 (below 15, no warning)
    const code =
        \\fn deep(x: u32) void {
        \\    while (true) {
        \\        for (items) |item| {
        \\            if (item == x) {
        \\                if (x > 10) {
        \\                    return;
        \\                }
        \\            }
        \\        }
        \\    }
        \\}
    ;
    const analysis = try createTestFileAnalysis(allocator, "deep.zig", code);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "deep.zig"), {});

    var issues = try analyzeComplexity(allocator, &graph, .{});
    defer deinitIssues(&issues, allocator);
    // Cognitive = 1+2+3+4 = 10, below 15
    try checkNoCognitiveWarnings(issues.items, "deep.zig");
}

test "ZA306: very deep nesting triggers cognitive at lowered threshold" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // 5 levels of nesting → 1+2+3+4+5 = 15, at threshold
    // 6 levels → 1+2+3+4+5+6 = 21, over threshold
    const code =
        \\fn very_deep(x: u32) void {
        \\    if (x > 0) {
        \\        if (x > 1) {
        \\            if (x > 2) {
        \\                if (x > 3) {
        \\                    if (x > 4) {
        \\                        if (x > 5) {
        \\                            if (x > 6) {
        \\                                return;
        \\                            }
        \\                        }
        \\                    }
        \\                }
        \\            }
        \\        }
        \\    }
        \\}
    ;
    const analysis = try createTestFileAnalysis(allocator, "very_deep.zig", code);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "very_deep.zig"), {});

    const th = Thresholds{ .max_cognitive = 10 };
    var issues = try analyzeComplexity(allocator, &graph, th);
    defer deinitIssues(&issues, allocator);

    var found = false;
    for (issues.items) |issue| {
        if (mem.eql(u8, issue.rule, RULE_COGNITIVE) and mem.eql(u8, issue.file, "very_deep.zig")) {
            found = true;
            try std.testing.expect(mem.containsAtLeast(u8, issue.message, 1, "cognitive complexity"));
        }
    }
    try std.testing.expect(found);
}

test "ZA305: try and catch contribute to cyclomatic" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // 3 try + 1 catch = 4 decision points, CCN = 5, below 15
    const code =
        \\fn load() !void {
        \\    try open();
        \\    try read();
        \\    try write() catch |e| { return e; };
        \\}
    ;
    const analysis = try createTestFileAnalysis(allocator, "load.zig", code);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "load.zig"), {});

    var issues = try analyzeComplexity(allocator, &graph, .{});
    defer deinitIssues(&issues, allocator);
    try checkNoCyclomaticWarnings(issues.items, "load.zig");
}

test "ZA305/ZA306: orelse is cyclomatic but low cognitive" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    // 20 orelse chains → cyclomatic high, cognitive moderate
    const code =
        \\fn coalesce() u32 {
        \\    const a = x orelse y orelse z orelse 0;
        \\    const b = p orelse q orelse r orelse 0;
        \\    const c = m orelse n orelse o orelse 0;
        \\    const d = i orelse j orelse k orelse 0;
        \\    const e = u orelse v orelse w orelse 0;
        \\    return a + b + c + d + e;
        \\}
    ;
    const analysis = try createTestFileAnalysis(allocator, "orelse.zig", code);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "orelse.zig"), {});

    const th = Thresholds{ .max_cyclomatic = 5, .max_cognitive = 4 };
    var issues = try analyzeComplexity(allocator, &graph, th);
    defer deinitIssues(&issues, allocator);

    var found_cyclo = false;
    var found_cog = false;
    for (issues.items) |issue| {
        if (!mem.eql(u8, issue.file, "orelse.zig")) continue;
        if (mem.eql(u8, issue.rule, RULE_CYCLOMATIC)) found_cyclo = true;
        if (mem.eql(u8, issue.rule, RULE_COGNITIVE)) found_cog = true;
    }
    // orelse adds to cyclomatic (20 → triggers at threshold 10)
    try std.testing.expect(found_cyclo);
    // orelse costs 1 each regardless of nesting → 20 → triggers at threshold 5
    try std.testing.expect(found_cog);
}

test "ZA305/ZA306: simple function has CCN=1 cognitive=0" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    const code =
        \\fn add(a: u32, b: u32) u32 {
        \\    return a + b;
        \\}
    ;
    const analysis = try createTestFileAnalysis(allocator, "add.zig", code);
    try graph.files.put(analysis.path, analysis);
    try graph.reachable.put(try allocator.dupe(u8, "add.zig"), {});

    // Low threshold to catch any false positive
    const th = Thresholds{ .max_cyclomatic = 1, .max_cognitive = 0 };
    var issues = try analyzeComplexity(allocator, &graph, th);
    defer deinitIssues(&issues, allocator);
    try checkNoCyclomaticWarnings(issues.items, "add.zig");
    try checkNoCognitiveWarnings(issues.items, "add.zig");
}
