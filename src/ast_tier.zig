// Rhyos Labs - Ephor
// AST tier: checks that need a real parse tree (host std.Ast).
// Copyright (C) 2025 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

//! The line tier is fast but grammar-blind. This tier parses each file
//! with the host compiler's own std.Ast (ephor is compiled per Zig
//! version, so the grammar always matches the toolchain) and runs rules
//! that are impossible or unreliable line-based. It is strictly additive:
//! line-tier rules and their baselines are unaffected.
//!
//! Degradation contract: when a file's parse produces errors the tree is
//! partial and `AstContext.ok` is false — AST rules skip the file and the
//! line tier still covers it. Files that nest delimiters or prefix
//! operators past `max_nesting_depth` skip the same way before the parse
//! runs (EPH-I0191). Nothing is logged per file. Corpus runs touch
//! thousands of files.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const types = @import("types.zig");

const Issue = types.Issue;
const Ast = std.zig.Ast;
const NodeIndex = Ast.Node.Index;
const OptIndex = Ast.Node.OptionalIndex;

/// 1-based source position, matching Issue line/col conventions.
pub const LineCol = struct {
    line: usize,
    col: usize,
};

/// Parsed file plus its owned null-terminated source copy (Ast needs [:0]).
pub const AstContext = struct {
    tree: Ast,
    source: [:0]const u8,
    /// False when the parse produced errors: the tree is partial and AST
    /// rules must skip this file.
    ok: bool,

    /// Parses on a worker thread with a `parse_stack_bytes` stack: the
    /// hard half of the EPH-I0191 guarantee (EPH-I0268). Parser stack
    /// need grows with input size, so the byte cap plus this stack bound
    /// the worst case by construction, with no grammar assumptions. The
    /// caller blocks in join while the worker allocates, so every
    /// allocation happens-before the caller resumes: no concurrent
    /// allocator access. Direct use on untrusted input above
    /// `max_ast_file_bytes` still reopens the crash class. Production
    /// callers must go through `analyzeFileAstTier`.
    pub fn init(allocator: Allocator, source: []const u8) !AstContext {
        var job = ParseJob{ .allocator = allocator, .source = source };
        const worker = try std.Thread.spawn(
            .{ .stack_size = parse_stack_bytes },
            parseWorker,
            .{&job},
        );
        worker.join();
        if (job.err) |err| return err;
        return job.result.?;
    }

    pub fn deinit(self: *AstContext, allocator: Allocator) void {
        self.tree.deinit(allocator);
        allocator.free(self.source);
    }

    /// 1-based line/col of a node's first token.
    pub fn nodeLineCol(self: *const AstContext, node: NodeIndex) LineCol {
        const loc = self.tree.tokenLocation(0, self.tree.firstToken(node));
        return .{ .line = loc.line + 1, .col = loc.column + 1 };
    }
};

/// Per-run tier counters, collected only when requested via AstTierOut.
pub const Stats = struct {
    parsed: usize = 0,
    skipped: usize = 0,
};

/// Stack for the parse worker thread. The byte cap bounds the input and
/// the worst verified density is ten frames per byte pair, so 64 KiB of
/// source needs well under 512 MB even with chunky Parse.zig frames.
/// The OS commits stack pages lazily, so resident cost tracks real use.
const parse_stack_bytes: usize = 512 * 1024 * 1024;

/// Worker payload for the threaded parse. The result slot moves the
/// context back to the caller after join.
const ParseJob = struct {
    allocator: Allocator,
    source: []const u8,
    result: ?AstContext = null,
    err: ?anyerror = null,
};

fn parseWorker(job: *ParseJob) void {
    job.result = parseOnCurrentThread(job.allocator, job.source) catch |err| {
        job.err = err;
        return;
    };
}

fn parseOnCurrentThread(allocator: Allocator, source: []const u8) !AstContext {
    const zsource = try allocator.dupeZ(u8, source);
    errdefer allocator.free(zsource);
    var tree = try Ast.parse(allocator, zsource, .zig);
    errdefer tree.deinit(allocator);
    return .{
        .tree = tree,
        .source = zsource,
        .ok = tree.errors.len == 0,
    };
}

/// Sink for one file's AST-tier analysis: issues plus optional counters.
pub const AstTierOut = struct {
    issues: *std.ArrayListUnmanaged(Issue),
    stats: ?*Stats = null,
};

// ============================================================================
// Nesting budget (EPH-I0191)
// ============================================================================

/// Parse-recursion budget for the AST tier. The host parser recurses ten
/// frames per nesting level (verified in zig 0.16.0 Parse.zig: parseExpr →
/// parseExprPrecedence → parsePrefixExpr → parsePrimaryExpr →
/// parseCurlySuffixExpr → parseTypeExpr → parseErrorUnionExpr →
/// parseSuffixExpr → parsePrimaryTypeExpr → expectExpr). At that rate
/// 20-50k nested parens exhaust the 8 MB default stack and SIGSEGV
/// mid-run with no output. Prefix operators recurse two to five frames
/// each without any delimiter, so the pre-scan budgets them with the
/// same constant. Real code nests tens of levels, so 512 keeps a wide
/// margin.
pub const max_nesting_depth: usize = 512;

/// AST-tier input byte cap (EPH-I0268). Parser stack need grows with
/// input size, so this cap plus `parse_stack_bytes` bounds the worst
/// case by construction: the pre-scan and the grammar audit table are
/// the cheap first gate, this is the guarantee that needs no grammar
/// assumptions. 64 KiB sits past ZA702's exceptional-file threshold
/// (50 KB default), so real code is unaffected. Over-cap files degrade
/// to line-tier coverage, the same contract as parse errors.
pub const max_ast_file_bytes: usize = 64 * 1024;

/// Carried state for the pre-scan: two counters that estimate live
/// parser frames, plus the pending-arrow watch for `anyframe->`.
const NestingScan = struct {
    depth: usize = 0,
    run: usize = 0,
    /// Set while an `anyframe` keyword waits for its `->`. The word alone
    /// is a type operand, so the run parks here until the arrow decides.
    arrow_run: ?usize = null,
};

/// True when `source` would push the recursive host parser past `budget`.
/// One iterative pass with no allocation keeps two counters: delimiter
/// nesting and sequential right-recursion runs. The run counter
/// increments on `! - ~ & ? *`, on `-%`, on `[`, on `anyframe->`, and on
/// the right-recursive keywords (grammar-audit table below). It resets
/// only at statement boundaries (`;`, `=`, `,`), where the frames of a
/// prefix chain provably return. It never resets on whitespace,
/// identifiers, or delimiters: prefix frames stay live across the
/// operand, and error-union chains interleave operators with operands.
/// Over-counting is deliberate and fail-safe. Infix chains of `- & *`,
/// deep index chains, and keyword-dense statements can force a skip. A
/// skip degrades one file to line-tier coverage. An under-count defeats
/// only this gate. The byte cap and the parse stack absorb it
/// (EPH-I0268). Operators inside strings, char literals, `\\`
/// multiline bodies, and `//` comments are data and do not count.
///
/// Grammar-audit table (zig 0.16.0 Parse.zig; EPH-I0268). Every
/// production classified by how it consumes stack: nested (the depth
/// counter), sequential right-recursive (the run counter), or iterative
/// (not counted). The table is the union of the 0.15/0.16 grammars: a
/// production unknown to one version never matches there, and
/// over-counting fails safe. Re-audit this table on every new Zig
/// version.
///
///   parens / blocks / index brackets   nested            depth
///   sequential slice types `[]T`       right-recursive   run (via `[`)
///   prefix ops `! - ~ & ? * -%`        right-recursive   run
///   error union `T!U`                  right-recursive   run (via `!`)
///   try / anyframe->                   right-recursive   run
///   comptime/nosuspend/resume/         right-recursive   run
///   break/return (expression prefix)
///   if/while/for bodies                right-recursive   run
///   fn-type chains `fn() fn() void`    right-recursive   run (fn + `(`)
///   binary ops and/or/orelse/catch     left-assoc loop   not counted
///   switch prongs                      iterative list    not counted
///   defer/errdefer payloads            block statements  not counted
///   fn declarations `fn name(`         container loop    not counted
///   statement boundary `;` `=` `,`     frames return     resets run
///   strings/chars/comments/`\\` bodies data              masked
fn exceedsNestingBudget(source: []const u8, budget: usize) bool {
    var scan = NestingScan{};
    var lines = mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (lineCrossesBudget(line, &scan, budget)) return true;
    }
    return false;
}

/// Fold one line into `scan` and report true when a counter crosses
/// `budget`. Closers at zero depth clamp instead of underflowing.
fn lineCrossesBudget(line: []const u8, scan: *NestingScan, budget: usize) bool {
    var lit = types.LiteralState.forLine(line) orelse return false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        _ = lit.updateForChar(line, i) orelse continue;
        scanCodeChar(line, &i, scan);
        if (scan.depth > budget or scan.run > budget) return true;
    }
    return false;
}

/// Fold one code-context char into the scan. Advances `i` past
/// identifier tails and two-char operator forms so their parts never
/// double-count.
fn scanCodeChar(line: []const u8, i: *usize, scan: *NestingScan) void {
    const c = line[i.*];
    if (scan.arrow_run) |saved| {
        if (c == '>') {
            scan.run = saved + 1;
            scan.arrow_run = null;
            return;
        }
        // Whitespace and the arrow's `-` keep the watch alive.
        if (c == '-' or c == ' ' or c == '\t' or c == '\r') return;
        scan.arrow_run = null;
        scan.run = 0;
        // Fall through: the char that broke the arrow still counts.
    }
    switch (c) {
        '(', '{' => scan.depth += 1,
        '[' => {
            scan.depth += 1;
            // Sequential slice/array types (`[][]u8`) recurse per level
            // while their brackets balance within the level, invisible
            // to depth alone (audit table row 2). Index chains
            // over-count here. Over-counting skips. An under-count is
            // absorbed by the byte cap and the parse stack (EPH-I0268).
            scan.run += 1;
        },
        ')', ']', '}' => {
            if (scan.depth > 0) scan.depth -= 1;
        },
        '!', '~', '&', '?', '*' => scan.run += 1,
        '-' => {
            // `-%` is one wrapping-negation token. Count it once.
            scan.run += 1;
            if (i.* + 1 < line.len and line[i.* + 1] == '%') i.* += 1;
        },
        ' ', '\t', '\r' => {},
        else => scanWordOrReset(line, i, scan),
    }
}

/// Identifiers keep the run: error-union chains interleave operands with
/// `!`, and infix `- & *` sequences must over-count toward a safe skip.
/// Only statement boundaries (`;`, `=`, `,`) reset: every other non-word
/// char can sit inside an operand (`.` `@` `:` in types) where parent
/// operator frames are still live (audit table, hole A). Right-recursive
/// keywords increment. `anyframe` arms the arrow watch.
fn scanWordOrReset(line: []const u8, i: *usize, scan: *NestingScan) void {
    if (!types.isIdent(line[i.*])) {
        const c = line[i.*];
        if (c == ';' or c == '=' or c == ',') scan.run = 0;
        return;
    }
    const start = i.*;
    while (i.* + 1 < line.len and types.isIdent(line[i.* + 1])) i.* += 1;
    const word = line[start .. i.* + 1];
    if (mem.eql(u8, word, "fn")) {
        // A declaration `fn name(` is one iterative frame in the
        // container loop. The type form `fn (` recurses per level
        // (audit table, fn-type chains), so only that form counts.
        if (nextNonSpaceIsParen(line, i.*)) scan.run += 1;
        return;
    }
    if (isRightRecursiveKeyword(word)) scan.run += 1;
    if (mem.eql(u8, word, "anyframe")) {
        scan.arrow_run = scan.run;
        scan.run = 0;
    }
}

/// True when the next non-space char after `i` is `(`: the fn-type form.
fn nextNonSpaceIsParen(line: []const u8, i: usize) bool {
    var j = i + 1;
    while (j < line.len and (line[j] == ' ' or line[j] == '\t' or line[j] == '\r')) j += 1;
    return j < line.len and line[j] == '(';
}

/// Keywords whose productions recurse into the following expression or
/// type without a delimiter (grammar-audit table, EPH-I0268). `fn` is
/// handled apart: only its type form recurses.
fn isRightRecursiveKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{
        "try",    "comptime", "nosuspend", "resume", "break",
        "return", "if",       "while",     "for",
    };
    for (keywords) |kw| {
        if (mem.eql(u8, word, kw)) return true;
    }
    return false;
}

// ============================================================================
// ZA111: returned-stack-reference
// ============================================================================
//
// Compiler-gap evidence (zig 0.16.0, `zig build-obj -fno-emit-bin` probes):
//   CAUGHT:   return &var_local;           (Sema errors on the bare form)
//   MISSED:   return &var.field;           (silent — stack UB)
//   MISSED:   return &var[i];              (silent, comptime index too)
//   MISSED:   return var[lo..hi];          (slice of local array — silent)
//   MISSED:   return &param;               (params are stack slots — silent)
//   MISSED:   return &param.field;         (silent)
//   MISSED:   const p = &var; return p;    (const alias — silent)
//   SAFE:     const x: u32 = 42; return &x; (comptime const → static memory)
//   SAFE:     comptime params / comptime-only typed params (→ static)
//   SAFE:     comptime var (comptime string-builder idiom → static memory)
// ZA111 covers exactly the MISSED forms; the bare-var form is skipped so
// ephor never duplicates a hard compile error.
//
// Precision policy (ephor's false-positive-elimination rule): a chained
// address-of is flagged only when every hop provably stays inside the
// stack frame. A hop through a pointer/slice(-typed) binding or field is
// safe (caller memory); an unresolvable hop (out-of-file type, inferred
// anonymous type, @field builtin) is SILENT, not flagged. Deferred forms
// (tracked): runtime-known const locals, out-param escape, labeled-block
// escape, payload-capture escape, @ptrCast evasion, named array aliases,
// var-alias pointer return, var slice-binding return, slice of array
// field, slice of array param.

const RULE_ZA111 = types.RULE_RETURNED_STACK_REF;

/// A `var` local: always a runtime stack slot.
const StackLocal = struct {
    name: []const u8,
    /// True only when the type is provably an array — slicing a slice
    /// copies a caller-owned pointer and must not be flagged.
    provably_array: bool,
    /// True when the binding's type is a pointer/slice. `&ptr.x` and
    /// `&ptr[i]` address memory BEHIND the pointer (owned by the caller),
    /// not the stack slot — only the bare slot address is escapable.
    is_pointer: bool,
    /// Explicit type annotation (or the type of an explicit init), .none
    /// when the type is inferred and unprovable.
    type_node: OptIndex,
};

/// A by-value function parameter: its slot lives on the stack frame.
const Param = struct {
    name: []const u8,
    is_pointer: bool,
    type_node: OptIndex,
};

/// A `const p = &x...;` binding: p's value points into root's stack slot.
const Alias = struct {
    name: []const u8,
    root: []const u8,
};

/// Per-function collected state for ZA111.
const FnScan = struct {
    locals: std.ArrayListUnmanaged(StackLocal) = .empty,
    aliases: std.ArrayListUnmanaged(Alias) = .empty,
    params: std.ArrayListUnmanaged(Param) = .empty,

    fn deinit(self: *FnScan, a: Allocator) void {
        self.locals.deinit(a);
        self.aliases.deinit(a);
        self.params.deinit(a);
    }

    fn localByName(self: *const FnScan, name: []const u8) ?StackLocal {
        for (self.locals.items) |l| {
            if (mem.eql(u8, l.name, name)) return l;
        }
        return null;
    }

    fn aliasRoot(self: *const FnScan, name: []const u8) ?[]const u8 {
        for (self.aliases.items) |al| {
            if (mem.eql(u8, al.name, name)) return al.root;
        }
        return null;
    }

    fn paramByName(self: *const FnScan, name: []const u8) ?Param {
        for (self.params.items) |p| {
            if (mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }
};

// ============================================================================
// Body walker
// ============================================================================
//
// std.Ast's Node.Data is an untagged union, so children are reached through
// the tree's typed full.* helpers (composite constructs) plus a per-tag
// shape switch (simple expressions). Nested container declarations are a
// hard boundary: their methods are separate functions, reached by the
// file-wide fn_decl scan — walking into them would misattribute their
// locals/returns to the enclosing function.
//
// Coverage policy: an unlisted tag pushes no children. That can only cause
// a missed detection (false negative), never a crash or a false positive.

const Walker = struct {
    a: Allocator,
    tree: *const Ast,
    stack: std.ArrayListUnmanaged(NodeIndex) = .empty,
    var_decls: std.ArrayListUnmanaged(NodeIndex) = .empty,
    returns: std.ArrayListUnmanaged(NodeIndex) = .empty,

    fn deinit(self: *Walker) void {
        self.stack.deinit(self.a);
        self.var_decls.deinit(self.a);
        self.returns.deinit(self.a);
    }

    fn push(self: *Walker, node: NodeIndex) !void {
        try self.stack.append(self.a, node);
    }

    fn pushOpt(self: *Walker, node: OptIndex) !void {
        try self.push(node.unwrap() orelse return);
    }

    /// DFS over one function body, recording var decls and returns.
    fn run(self: *Walker, body: NodeIndex) !void {
        try self.push(body);
        while (self.stack.pop()) |node| {
            switch (self.tree.nodeTag(node)) {
                .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                    try self.var_decls.append(self.a, node);
                },
                .@"return" => try self.returns.append(self.a, node),
                else => {},
            }
            try self.pushChildren(node);
        }
    }

    fn pushChildren(self: *Walker, node: NodeIndex) !void {
        const tag = self.tree.nodeTag(node);
        if (isBoundaryTag(tag)) return;
        if (try self.pushCompositeStmt(node)) return;
        if (try self.pushCompositeExpr(node)) return;
        try self.pushShaped(node);
    }

    /// Composite statement constructs, via the tree's typed helpers.
    fn pushCompositeStmt(self: *Walker, node: NodeIndex) !bool {
        const tree = self.tree;
        switch (tree.nodeTag(node)) {
            .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                const vd = tree.fullVarDecl(node) orelse return true;
                try self.pushOpt(vd.ast.type_node);
                try self.pushOpt(vd.ast.init_node);
            },
            .if_simple, .@"if" => {
                const f = tree.fullIf(node) orelse return true;
                try self.push(f.ast.cond_expr);
                try self.push(f.ast.then_expr);
                try self.pushOpt(f.ast.else_expr);
            },
            .while_simple, .while_cont, .@"while" => {
                const w = tree.fullWhile(node) orelse return true;
                try self.push(w.ast.cond_expr);
                try self.pushOpt(w.ast.cont_expr);
                try self.push(w.ast.then_expr);
                try self.pushOpt(w.ast.else_expr);
            },
            .for_simple, .@"for" => {
                const f = tree.fullFor(node) orelse return true;
                for (f.ast.inputs) |in| try self.push(in);
                try self.push(f.ast.then_expr);
                try self.pushOpt(f.ast.else_expr);
            },
            .@"switch", .switch_comma => {
                const s = tree.fullSwitch(node) orelse return true;
                try self.push(s.ast.condition);
                for (s.ast.cases) |c| try self.push(c);
            },
            .switch_case_one,
            .switch_case,
            .switch_case_inline_one,
            .switch_case_inline,
            => {
                const c = tree.fullSwitchCase(node) orelse return true;
                for (c.ast.values) |v| try self.push(v);
                try self.push(c.ast.target_expr);
            },
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                var buf: [2]NodeIndex = undefined;
                for (tree.blockStatements(&buf, node) orelse return true) |s| {
                    try self.push(s);
                }
            },
            else => return false,
        }
        return true;
    }

    /// Composite expression constructs, via the tree's typed helpers.
    fn pushCompositeExpr(self: *Walker, node: NodeIndex) !bool {
        const tree = self.tree;
        switch (tree.nodeTag(node)) {
            .call, .call_comma, .call_one, .call_one_comma => {
                var buf: [1]NodeIndex = undefined;
                const c = tree.fullCall(&buf, node) orelse return true;
                try self.push(c.ast.fn_expr);
                for (c.ast.params) |p| try self.push(p);
            },
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            => {
                var buf: [2]NodeIndex = undefined;
                for (tree.builtinCallParams(&buf, node) orelse return true) |p| {
                    try self.push(p);
                }
            },
            .struct_init,
            .struct_init_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            .struct_init_one,
            .struct_init_one_comma,
            => {
                var buf: [2]NodeIndex = undefined;
                const s = tree.fullStructInit(&buf, node) orelse return true;
                try self.pushOpt(s.ast.type_expr);
                for (s.ast.fields) |f| try self.push(f);
            },
            .array_init,
            .array_init_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            .array_init_one,
            .array_init_one_comma,
            => {
                var buf: [2]NodeIndex = undefined;
                const ai = tree.fullArrayInit(&buf, node) orelse return true;
                try self.pushOpt(ai.ast.type_expr);
                for (ai.ast.elements) |e| try self.push(e);
            },
            .slice_open, .slice, .slice_sentinel => {
                const s = tree.fullSlice(node) orelse return true;
                try self.push(s.ast.sliced);
                try self.push(s.ast.start);
                try self.pushOpt(s.ast.end);
                try self.pushOpt(s.ast.sentinel);
            },
            .array_type, .array_type_sentinel => {
                const at = tree.fullArrayType(node) orelse return true;
                try self.push(at.ast.elem_count);
                try self.pushOpt(at.ast.sentinel);
                try self.push(at.ast.elem_type);
            },
            else => return false,
        }
        return true;
    }

    /// Simple expressions: children follow directly from the tag's fixed
    /// data shape. Unlisted tags are leaves for this walk's purposes.
    fn pushShaped(self: *Walker, node: NodeIndex) !void {
        if (try self.pushShapedBinary(node)) return;
        const data = self.tree.nodeData(node);
        switch (self.tree.nodeTag(node)) {
            .field_access, .unwrap_optional, .grouped_expression => {
                try self.push(data.node_and_token[0]);
            },
            .address_of,
            .deref,
            .bool_not,
            .negation,
            .negation_wrap,
            .bit_not,
            .optional_type,
            .@"try",
            .@"comptime",
            .@"defer",
            .@"suspend",
            .@"resume",
            .@"nosuspend",
            => try self.push(data.node),
            .@"return" => try self.pushOpt(data.opt_node),
            .@"errdefer" => try self.push(data.opt_token_and_node[1]),
            .anyframe_type => try self.push(data.token_and_node[1]),
            .@"break", .@"continue" => {
                try self.pushOpt(data.opt_token_and_opt_node[1]);
            },
            .ptr_type_aligned, .ptr_type_sentinel => {
                const opt, const elem = data.opt_node_and_node;
                try self.pushOpt(opt);
                try self.push(elem);
            },
            .ptr_type, .ptr_type_bit_range, .assign_destructure => {
                try self.push(data.extra_and_node[1]);
            },
            else => {},
        }
    }

    /// Binary operators, assignments, ranges, catch/orelse, error unions —
    /// all `node_and_node` (verified against Parse.zig's operTable).
    fn pushShapedBinary(self: *Walker, node: NodeIndex) !bool {
        const tag = self.tree.nodeTag(node);
        const data = self.tree.nodeData(node);
        if (binary_like_tags.contains(tag)) {
            const lhs, const rhs = data.node_and_node;
            try self.push(lhs);
            try self.push(rhs);
            return true;
        }
        // `lhs..rhs` and open `lhs..` — the end is optional (shape is
        // node_and_opt_node, NOT node_and_node; verified against
        // Parse.zig forPrefix).
        if (tag == .for_range) {
            const lhs, const rhs = data.node_and_opt_node;
            try self.push(lhs);
            try self.pushOpt(rhs);
            return true;
        }
        return false;
    }
};

/// Tags whose data is `node_and_node` (binary ops, assignments, ranges,
/// catch/orelse, error unions — verified against Parse.zig's operTable).
const binary_like_tags = blk: {
    var set = std.EnumSet(Ast.Node.Tag).initEmpty();
    const tags = [_]Ast.Node.Tag{
        .assign,          .assign_mul,      .assign_div,      .assign_mod,
        .assign_add,      .assign_sub,      .assign_shl,      .assign_shl_sat,
        .assign_shr,      .assign_bit_and,  .assign_bit_xor,  .assign_bit_or,
        .assign_mul_wrap, .assign_add_wrap, .assign_sub_wrap, .assign_mul_sat,
        .assign_add_sat,  .assign_sub_sat,  .equal_equal,     .bang_equal,
        .less_than,       .greater_than,    .less_or_equal,   .greater_or_equal,
        .mul,             .div,             .mod,             .array_mult,
        .mul_wrap,        .mul_sat,         .add,             .sub,
        .array_cat,       .add_wrap,        .sub_wrap,        .add_sat,
        .sub_sat,         .shl,             .shl_sat,         .shr,
        .bit_and,         .bit_xor,         .bit_or,          .bool_and,
        .bool_or,         .@"orelse",       .@"catch",        .merge_error_sets,
        .switch_range,    .error_union,     .array_access,
    };
    for (tags) |t| set.insert(t);
    break :blk set;
};

/// Tags whose subtrees must not be entered during a fn-body walk.
fn isBoundaryTag(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .root,
        .test_decl,
        .error_set_decl,
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        .global_var_decl,
        .fn_decl,
        .fn_proto,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_proto_multi,
        .container_field,
        .container_field_init,
        .container_field_align,
        .asm_simple,
        .@"asm",
        .asm_input,
        .asm_output,
        => true,
        else => false,
    };
}

// ============================================================================
// Same-file type index (field-type resolution for chained address-of)
// ============================================================================
//
// `&v.words[i]` is stack UB when `words` is an array field but safe when
// it is a slice field — the syntax is identical, only the field type
// differs. This index maps type names to their container declarations so
// chain hops can be resolved. It is deliberately not a semantic layer:
// only same-file, name-resolvable types participate; everything else is
// .unknown and the caller stays silent.

const TypeIndex = struct {
    map: std.StringHashMapUnmanaged(NodeIndex) = .empty,

    fn deinit(self: *TypeIndex, a: Allocator) void {
        self.map.deinit(a);
    }

    fn lookup(self: *const TypeIndex, name: []const u8) ?NodeIndex {
        return self.map.get(name);
    }
};

fn isContainerDeclTag(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => true,
        else => false,
    };
}

/// Index every `const Name = struct/union/enum {...};` in the file,
/// including fn-local ones (a fn-local type's methods are analyzed with
/// their own function scans). Name collisions across scopes: last wins.
fn buildTypeIndex(a: Allocator, tree: *const Ast) !TypeIndex {
    var idx = TypeIndex{};
    errdefer idx.deinit(a);
    var i: usize = 1;
    while (i < tree.nodes.len) : (i += 1) {
        const node: NodeIndex = @enumFromInt(@as(u32, @intCast(i)));
        const vd = tree.fullVarDecl(node) orelse continue;
        const init = vd.ast.init_node.unwrap() orelse continue;
        if (!isContainerDeclTag(tree.nodeTag(init))) continue;
        try idx.map.put(a, tree.tokenSlice(vd.ast.mut_token + 1), init);
    }
    return idx;
}

/// The declared type node of a container field, when resolvable.
fn fieldTypeNode(tree: *const Ast, container: NodeIndex, field: []const u8) ?NodeIndex {
    var buf: [2]NodeIndex = undefined;
    const cd = tree.fullContainerDecl(&buf, container) orelse return null;
    for (cd.ast.members) |member| {
        switch (tree.nodeTag(member)) {
            .container_field, .container_field_init, .container_field_align => {},
            else => continue,
        }
        const name = tree.tokenSlice(tree.nodeMainToken(member));
        if (!mem.eql(u8, name, field)) continue;
        const cf = tree.fullContainerField(member) orelse return null;
        return cf.ast.type_expr.unwrap();
    }
    return null;
}

/// One step of chain resolution through a type expression.
const TypeStep = union(enum) {
    /// Pointer/slice: everything beyond is caller-owned memory.
    safe,
    /// Named type: resolvable further via the TypeIndex.
    named: []const u8,
    /// `[N]T` — an index hop stays inside the stack slot.
    array_elem: NodeIndex,
    /// `?T` — an unwrap hop stays inside the stack slot.
    optional_payload: NodeIndex,
    /// Unprovable from the AST — the caller stays silent.
    unknown,
};

fn classifyTypeNode(tree: *const Ast, node: NodeIndex) TypeStep {
    if (isPointerTypeExpr(tree, node)) return .safe;
    switch (tree.nodeTag(node)) {
        .identifier => {
            return .{ .named = tree.tokenSlice(tree.nodeMainToken(node)) };
        },
        .array_type, .array_type_sentinel => {
            const at = tree.fullArrayType(node) orelse return .unknown;
            return .{ .array_elem = at.ast.elem_type };
        },
        .optional_type => {
            return .{ .optional_payload = tree.nodeData(node).node };
        },
        else => return .unknown,
    }
}

fn stepThroughHop(tree: *const Ast, tidx: *const TypeIndex, cur: TypeStep, hop: Hop) TypeStep {
    switch (cur) {
        .safe, .unknown => return cur,
        .array_elem => |elem| {
            if (hop != .index) return .unknown;
            return classifyTypeNode(tree, elem);
        },
        .optional_payload => |payload| {
            if (hop != .unwrap) return .unknown;
            return classifyTypeNode(tree, payload);
        },
        .named => |name| {
            const container = tidx.lookup(name) orelse return .unknown;
            if (hop != .field) return .unknown;
            const ft = fieldTypeNode(tree, container, hop.field) orelse return .unknown;
            return classifyTypeNode(tree, ft);
        },
    }
}

const ChainSafety = enum { unsafe, safe, unknown };

/// Resolve whether a chained address-of provably stays inside the stack
/// frame. Hops are stored outermost-first, so resolution walks them in
/// reverse (root-adjacent hop first).
fn resolveChainSafety(
    tree: *const Ast,
    tidx: *const TypeIndex,
    info: ChainInfo,
    root_type: OptIndex,
) ChainSafety {
    if (info.overflow) return .unknown;
    const root_node = root_type.unwrap() orelse return .unknown;
    var cur = classifyTypeNode(tree, root_node);
    var hi = info.hop_count;
    while (hi > 0) {
        hi -= 1;
        cur = stepThroughHop(tree, tidx, cur, info.hops[hi]);
        switch (cur) {
            .safe => return .safe,
            .unknown => return .unknown,
            else => {},
        }
    }
    return .unsafe;
}

// ============================================================================
// ZA111 collection passes
// ============================================================================

/// Unwrap parenthesized expressions: `return (&x);` is `return &x;`.
fn unwrapGroup(tree: *const Ast, node: NodeIndex) NodeIndex {
    var cur = node;
    while (tree.nodeTag(cur) == .grouped_expression) {
        cur = tree.nodeData(cur).node_and_token[0];
    }
    return cur;
}

/// One hop of an address-of chain.
const Hop = union(enum) {
    field: []const u8,
    index,
    unwrap,
};

/// Peeled address-of chain: `s.a[i].?` roots at `s` with hops
/// [unwrap, index, field a] collected outermost-first (resolution walks
/// them in reverse). Chains longer than the buffer are unresolvable.
const ChainInfo = struct {
    root: []const u8 = "",
    hops: [8]Hop = undefined,
    hop_count: usize = 0,
    overflow: bool = false,
};

/// Peel one chain hop, advancing `cur` past it; null ends the chain.
fn peelHop(tree: *const Ast, cur: *NodeIndex) ?Hop {
    cur.* = unwrapGroup(tree, cur.*);
    switch (tree.nodeTag(cur.*)) {
        .field_access => {
            const tok = tree.nodeData(cur.*).node_and_token[1];
            cur.* = tree.nodeData(cur.*).node_and_token[0];
            return .{ .field = tree.tokenSlice(tok) };
        },
        .unwrap_optional => {
            cur.* = tree.nodeData(cur.*).node_and_token[0];
            return .unwrap;
        },
        .array_access => {
            cur.* = tree.nodeData(cur.*).node_and_node[0];
            return .index;
        },
        else => return null,
    }
}

fn chainInfo(tree: *const Ast, start: NodeIndex) ChainInfo {
    var info = ChainInfo{};
    var cur = start;
    while (peelHop(tree, &cur)) |hop| {
        if (info.hop_count >= info.hops.len) {
            info.overflow = true;
        } else {
            info.hops[info.hop_count] = hop;
            info.hop_count += 1;
        }
    }
    if (tree.nodeTag(cur) == .identifier) {
        info.root = tree.tokenSlice(tree.nodeMainToken(cur));
    }
    return info;
}

/// Params whose address is provably static or unprovable are excluded:
/// comptime params and comptime-only types live in constant memory, and
/// anytype params cannot be proven runtime from the AST alone.
fn collectParams(
    a: Allocator,
    tree: *const Ast,
    proto: NodeIndex,
    scan: *FnScan,
) !void {
    var buf: [1]NodeIndex = undefined;
    const fp = tree.fullFnProto(&buf, proto) orelse return;
    var it = fp.iterate(tree);
    while (it.next()) |param| {
        if (param.anytype_ellipsis3 != null) continue;
        const name_tok = param.name_token orelse continue;
        if (param.comptime_noalias) |t| {
            if (mem.eql(u8, tree.tokenSlice(t), "comptime")) continue;
        }
        var is_pointer = false;
        var type_node: OptIndex = .none;
        if (param.type_expr) |te| {
            if (isComptimeOnlyType(tree, te)) continue;
            is_pointer = isPointerTypeExpr(tree, te);
            type_node = te.toOptional();
        }
        try scan.params.append(a, .{
            .name = tree.tokenSlice(name_tok),
            .is_pointer = is_pointer,
            .type_node = type_node,
        });
    }
}

fn isComptimeOnlyType(tree: *const Ast, node: NodeIndex) bool {
    if (tree.nodeTag(node) != .identifier) return false;
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    const comptime_types = [_][]const u8{ "comptime_int", "comptime_float", "type" };
    for (comptime_types) |ct| {
        if (mem.eql(u8, name, ct)) return true;
    }
    return false;
}

/// True when a type expression is a pointer/slice type (`*T`, `[]T`,
/// `[*]T`, plus align/sentinel/bitrange variants). Optional-wrapped
/// pointers stay false: `&opt.?` addresses the payload inside the
/// optional's own stack slot, so it remains escapable.
fn isPointerTypeExpr(tree: *const Ast, node: NodeIndex) bool {
    return switch (tree.nodeTag(node)) {
        .ptr_type, .ptr_type_aligned, .ptr_type_sentinel, .ptr_type_bit_range => true,
        else => false,
    };
}

/// Phase 1: all `var` locals. `var` is always a runtime stack slot;
/// `const` locals are only tracked as aliases (a comptime-known const
/// lives in static memory — flagging it would be a false positive).
fn collectLocals(
    a: Allocator,
    tree: *const Ast,
    decls: []const NodeIndex,
    scan: *FnScan,
) !void {
    for (decls) |node| {
        const vd = tree.fullVarDecl(node) orelse continue;
        if (!mem.eql(u8, tree.tokenSlice(vd.ast.mut_token), "var")) continue;
        // `comptime var` lives in static memory (the comptime string-
        // builder idiom) — its address never refers to the stack frame.
        if (vd.comptime_token != null) continue;
        try scan.locals.append(a, .{
            .name = tree.tokenSlice(vd.ast.mut_token + 1),
            .provably_array = isArrayVarDecl(tree, vd),
            .is_pointer = isPointerVarDecl(tree, vd, scan),
            .type_node = varDeclTypeNode(tree, vd),
        });
    }
}

/// The best available type node for a var local: the explicit annotation,
/// or the type of an explicitly-typed init (`var s = S{...}`).
fn varDeclTypeNode(tree: *const Ast, vd: Ast.full.VarDecl) OptIndex {
    if (vd.ast.type_node != .none) return vd.ast.type_node;
    const init = vd.ast.init_node.unwrap() orelse return .none;
    var buf: [2]NodeIndex = undefined;
    if (tree.fullStructInit(&buf, init)) |si| return si.ast.type_expr;
    if (tree.fullArrayInit(&buf, init)) |ai| return ai.ast.type_expr;
    return .none;
}

/// Pointer-ness of a var local: explicit pointer annotation, an
/// address-of init (`var p = &x;` — address-of always yields a pointer),
/// or an inferred type copied from a binding already known to be a
/// pointer (`var q = p;`). Anything else inferred is unprovable from the
/// AST — treated as by-value.
fn isPointerVarDecl(tree: *const Ast, vd: Ast.full.VarDecl, scan: *const FnScan) bool {
    if (vd.ast.type_node.unwrap()) |t| return isPointerTypeExpr(tree, t);
    const init = vd.ast.init_node.unwrap() orelse return false;
    const e = unwrapGroup(tree, init);
    if (tree.nodeTag(e) == .address_of) return true;
    if (tree.nodeTag(e) != .identifier) return false;
    const name = tree.tokenSlice(tree.nodeMainToken(e));
    if (scan.paramByName(name)) |p| return p.is_pointer;
    // Local-to-local inference needs source order (use-before-decl is
    // impossible, so the source of the copy is always earlier). The
    // caller sorts decls by first token before this pass.
    if (scan.localByName(name)) |l| return l.is_pointer;
    return false;
}

fn declTokenLessThan(tree: *const Ast, a: NodeIndex, b: NodeIndex) bool {
    return tree.firstToken(a) < tree.firstToken(b);
}

/// Sort declarations into source order: the walker discovers them in
/// DFS pop order, but pointer inference and alias resolution rely on
/// use-before-decl ordering.
fn sortDeclsBySource(tree: *const Ast, decls: []NodeIndex) void {
    std.sort.pdq(NodeIndex, decls, tree, declTokenLessThan);
}

fn isArrayVarDecl(tree: *const Ast, vd: Ast.full.VarDecl) bool {
    if (vd.ast.type_node.unwrap()) |t| {
        switch (tree.nodeTag(t)) {
            .array_type, .array_type_sentinel => return true,
            else => {},
        }
    }
    const init = vd.ast.init_node.unwrap() orelse return false;
    return switch (tree.nodeTag(init)) {
        .array_init,
        .array_init_comma,
        .array_init_one,
        .array_init_one_comma,
        => true,
        else => false,
    };
}

/// Bundled immutable context for the collection passes (keeps ≤4 params).
const ScanCtx = struct {
    tree: *const Ast,
    tidx: *const TypeIndex,
};

/// Phase 2: const aliases (`const p = &x...;`). Fixed-point over the decl
/// list so transitive aliases (`const q = p;`) resolve regardless of the
/// walk's discovery order. Bounded by one round per declaration.
fn collectAliases(
    a: Allocator,
    sctx: ScanCtx,
    decls: []const NodeIndex,
    scan: *FnScan,
) !void {
    var progress = true;
    var rounds: usize = 0;
    while (progress and rounds <= decls.len) : (rounds += 1) {
        progress = false;
        for (decls) |node| {
            if (try tryCollectAlias(a, sctx, node, scan)) progress = true;
        }
    }
}

fn tryCollectAlias(
    a: Allocator,
    sctx: ScanCtx,
    node: NodeIndex,
    scan: *FnScan,
) !bool {
    const tree = sctx.tree;
    const vd = tree.fullVarDecl(node) orelse return false;
    if (!mem.eql(u8, tree.tokenSlice(vd.ast.mut_token), "const")) return false;
    const name = tree.tokenSlice(vd.ast.mut_token + 1);
    if (scan.aliasRoot(name) != null) return false;
    const init = vd.ast.init_node.unwrap() orelse return false;
    const root = aliasTarget(sctx.tree, sctx.tidx, scan, init) orelse return false;
    try scan.aliases.append(a, .{ .name = name, .root = root });
    return true;
}

/// The stack local or param an alias initializer points into, if provable.
/// A chained address resolved safe/unknown (`&ptr.x`, `&v.slice[i]`, or
/// unresolvable) does not point into the stack frame — no alias.
fn aliasTarget(
    tree: *const Ast,
    tidx: *const TypeIndex,
    scan: *const FnScan,
    init: NodeIndex,
) ?[]const u8 {
    const e = unwrapGroup(tree, init);
    switch (tree.nodeTag(e)) {
        .address_of => return aliasAddressTarget(tree, tidx, scan, e),
        .identifier => {
            const name = tree.tokenSlice(tree.nodeMainToken(e));
            return scan.aliasRoot(name);
        },
        else => return null,
    }
}

fn aliasAddressTarget(
    tree: *const Ast,
    tidx: *const TypeIndex,
    scan: *const FnScan,
    amp: NodeIndex,
) ?[]const u8 {
    const info = chainInfo(tree, tree.nodeData(amp).node);
    if (info.root.len == 0) return null;
    const bind = bindForRoot(info.root, scan) orelse return null;
    if (info.hop_count > 0 and !chainIsUnsafe(tree, tidx, info, bind)) return null;
    return info.root;
}

/// The chain-relevant view of a binding (param or local).
const Bind = struct {
    is_pointer: bool,
    type_node: OptIndex,
    /// Bare `&param` is missed by Sema (flag); bare `&var` is a hard
    /// compile error (never echo).
    is_param: bool,
};

/// Resolve a chain-root identifier to its binding, params first.
fn bindForRoot(name: []const u8, scan: *const FnScan) ?Bind {
    if (scan.paramByName(name)) |p| {
        return .{ .is_pointer = p.is_pointer, .type_node = p.type_node, .is_param = true };
    }
    if (scan.localByName(name)) |l| {
        return .{ .is_pointer = l.is_pointer, .type_node = l.type_node, .is_param = false };
    }
    return null;
}

fn chainIsUnsafe(
    tree: *const Ast,
    tidx: *const TypeIndex,
    info: ChainInfo,
    bind: Bind,
) bool {
    if (bind.is_pointer) return false;
    return resolveChainSafety(tree, tidx, info, bind.type_node) == .unsafe;
}

// ============================================================================
// ZA111 return classification + emission
// ============================================================================

const Finding = struct {
    /// Stack local or param the returned pointer/slice refers to.
    name: []const u8,
    /// Alias the pointer was returned through, when not returned directly.
    via: ?[]const u8,
    is_slice: bool,
    is_param: bool = false,
};

fn classifyReturn(
    tree: *const Ast,
    tidx: *const TypeIndex,
    scan: *const FnScan,
    node: NodeIndex,
) ?Finding {
    const expr = tree.nodeData(node).opt_node.unwrap() orelse return null;
    const e = unwrapGroup(tree, expr);
    return switch (tree.nodeTag(e)) {
        .address_of => classifyAddressOf(tree, tidx, scan, e),
        .slice_open, .slice, .slice_sentinel => classifySlice(tree, scan, e),
        .identifier => classifyAliasReturn(tree, scan, e),
        else => null,
    };
}

fn classifyAddressOf(
    tree: *const Ast,
    tidx: *const TypeIndex,
    scan: *const FnScan,
    amp: NodeIndex,
) ?Finding {
    const info = chainInfo(tree, tree.nodeData(amp).node);
    if (info.root.len == 0) return null;
    const bind = bindForRoot(info.root, scan) orelse return null;
    if (info.hop_count == 0) {
        // Bare &var is a hard compile error (Zig Sema) — never echo it.
        if (!bind.is_param) return null;
        return .{ .name = info.root, .via = null, .is_slice = false, .is_param = true };
    }
    if (!chainIsUnsafe(tree, tidx, info, bind)) return null;
    return .{ .name = info.root, .via = null, .is_slice = false, .is_param = bind.is_param };
}

fn classifySlice(tree: *const Ast, scan: *const FnScan, node: NodeIndex) ?Finding {
    const s = tree.fullSlice(node) orelse return null;
    const sliced = unwrapGroup(tree, s.ast.sliced);
    if (tree.nodeTag(sliced) != .identifier) return null;
    const name = tree.tokenSlice(tree.nodeMainToken(sliced));
    const local = scan.localByName(name) orelse return null;
    // Only provable arrays: slicing a slice copies the caller-owned pointer.
    if (!local.provably_array) return null;
    return .{ .name = name, .via = null, .is_slice = true };
}

fn classifyAliasReturn(tree: *const Ast, scan: *const FnScan, node: NodeIndex) ?Finding {
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    const root = scan.aliasRoot(name) orelse return null;
    return .{
        .name = root,
        .via = name,
        .is_slice = false,
        .is_param = scan.paramByName(root) != null,
    };
}

const Za111Ctx = struct {
    a: Allocator,
    actx: *const AstContext,
    tidx: *const TypeIndex,
    path: []const u8,
    out: *std.ArrayListUnmanaged(Issue),
};

fn emitZa111(ctx: *const Za111Ctx, node: NodeIndex, f: Finding) !void {
    const what = if (f.is_param) "parameter" else "local";
    const msg = if (f.via) |via|
        try std.fmt.allocPrint(ctx.a, "returned pointer '{s}' refers to stack {s} " ++
            "'{s}' — its storage expires when the function returns", .{ via, what, f.name })
    else if (f.is_slice)
        try std.fmt.allocPrint(ctx.a, "returned slice refers to stack array " ++
            "'{s}' — its storage expires when the function returns", .{f.name})
    else
        try std.fmt.allocPrint(ctx.a, "returned pointer refers to stack {s} " ++
            "'{s}' — its storage expires when the function returns", .{ what, f.name });
    const lc = ctx.actx.nodeLineCol(node);
    try ctx.out.append(ctx.a, .{
        .file = ctx.path,
        .line = lc.line,
        .col = lc.col,
        .severity = .err,
        .rule = RULE_ZA111,
        .message = msg,
        .message_owned = true,
        .help = "copy the value out, heap-allocate it, " ++
            "or have the caller provide the buffer",
    });
}

fn analyzeOneFn(
    ctx: *const Za111Ctx,
    proto: NodeIndex,
    body: NodeIndex,
) !void {
    var walker = Walker{ .a = ctx.a, .tree = &ctx.actx.tree };
    defer walker.deinit();
    try walker.run(body);
    sortDeclsBySource(&ctx.actx.tree, walker.var_decls.items);

    const sctx = ScanCtx{ .tree = &ctx.actx.tree, .tidx = ctx.tidx };
    var scan = FnScan{};
    defer scan.deinit(ctx.a);
    try collectParams(ctx.a, sctx.tree, proto, &scan);
    try collectLocals(ctx.a, sctx.tree, walker.var_decls.items, &scan);
    try collectAliases(ctx.a, sctx, walker.var_decls.items, &scan);

    for (walker.returns.items) |ret| {
        const f = classifyReturn(sctx.tree, sctx.tidx, &scan, ret) orelse continue;
        try emitZa111(ctx, ret, f);
    }
}

fn analyzeFileZa111(ctx: *const Za111Ctx) !void {
    const tree = &ctx.actx.tree;
    var i: usize = 1;
    while (i < tree.nodes.len) : (i += 1) {
        const node: NodeIndex = @enumFromInt(@as(u32, @intCast(i)));
        if (tree.nodeTag(node) != .fn_decl) continue;
        const proto, const body = tree.nodeData(node).node_and_node;
        try analyzeOneFn(ctx, proto, body);
    }
}

/// Run every AST-tier rule over one file. Files with parse errors, deep
/// nesting, or a size past `max_ast_file_bytes` are skipped. The line
/// tier still covers them. Only allocation and thread-spawn errors are
/// propagated.
pub fn analyzeFileAstTier(
    a: Allocator,
    out: AstTierOut,
    path: []const u8,
    content: []const u8,
) !void {
    // Parser stack need grows with input size (EPH-I0191). The byte cap
    // bounds it by construction. The parse thread's big stack
    // (parse_stack_bytes) holds the rest.
    if (content.len > max_ast_file_bytes) {
        if (out.stats) |s| s.skipped += 1;
        return;
    }
    // Deep delimiter or operator nesting SIGSEGVs the recursive host
    // parser mid-run (EPH-I0191). Degrade to line-tier coverage, the
    // same contract as parse errors.
    if (exceedsNestingBudget(content, max_nesting_depth)) {
        if (out.stats) |s| s.skipped += 1;
        return;
    }
    var actx = try AstContext.init(a, content);
    defer actx.deinit(a);
    if (!actx.ok) {
        if (out.stats) |s| s.skipped += 1;
        return;
    }
    if (out.stats) |s| s.parsed += 1;
    var tidx = try buildTypeIndex(a, &actx.tree);
    defer tidx.deinit(a);
    var ctx = Za111Ctx{
        .a = a,
        .actx = &actx,
        .tidx = &tidx,
        .path = path,
        .out = out.issues,
    };
    try analyzeFileZa111(&ctx);
}

// ============================================================================
// Tests
// ============================================================================

fn runZa111(a: Allocator, content: []const u8) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    errdefer types.deinitIssues(&issues, a);
    try analyzeFileAstTier(a, .{ .issues = &issues }, "test.zig", content);
    return issues;
}

fn expectZa111(
    issues: []const Issue,
    line: usize,
    needle: []const u8,
) !void {
    try std.testing.expectEqual(@as(usize, 1), issues.len);
    const issue = issues[0];
    try std.testing.expectEqualStrings("ZA111", issue.rule);
    try std.testing.expectEqual(line, issue.line);
    try std.testing.expect(issue.severity == .err);
    try std.testing.expect(mem.indexOf(u8, issue.message, needle) != null);
}

test "AstContext: parse errors mark ok=false, valid source parses" {
    const a = std.testing.allocator;
    var bad = try AstContext.init(a, "fn broken( {");
    defer bad.deinit(a);
    try std.testing.expect(!bad.ok);
    try std.testing.expect(bad.tree.errors.len > 0);

    var good = try AstContext.init(a, "fn f() void {}\n");
    defer good.deinit(a);
    try std.testing.expect(good.ok);
}

test "AstContext: nodeLineCol is 1-based" {
    const a = std.testing.allocator;
    var ctx = try AstContext.init(a, "fn f() void {\n    var x = 1;\n    _ = x;\n}\n");
    defer ctx.deinit(a);
    var decl: ?NodeIndex = null;
    var i: usize = 1;
    while (i < ctx.tree.nodes.len) : (i += 1) {
        const n: NodeIndex = @enumFromInt(@as(u32, @intCast(i)));
        if (ctx.tree.nodeTag(n) == .fn_decl) decl = n;
    }
    const lc = ctx.nodeLineCol(decl.?);
    try std.testing.expectEqual(@as(usize, 1), lc.line);
    try std.testing.expectEqual(@as(usize, 1), lc.col);
}

test "ZA111: field of local var fires" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\const S = struct { a: u32, b: u32 };
        \\fn f() *u32 {
        \\    var s: S = .{ .a = 1, .b = 2 };
        \\    return &s.a;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 4, "'s'");
}

test "ZA111: element of local array fires" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\fn f(i: usize) *u32 {
        \\    var arr: [4]u32 = .{ 1, 2, 3, 4 };
        \\    return &arr[i];
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 3, "'arr'");
}

test "ZA111: slice of local array fires" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\fn f() []u32 {
        \\    var arr: [4]u32 = .{ 1, 2, 3, 4 };
        \\    return arr[0..2];
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 3, "stack array 'arr'");
}

test "ZA111: bare param address fires" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\fn f(x: u32) *const u32 {
        \\    return &x;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 2, "'x'");
}

test "ZA111: param field address fires" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\const S = struct { a: u32 };
        \\fn f(s: S) *const u32 {
        \\    return &s.a;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 3, "'s'");
}

test "ZA111: const alias of var fires" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\fn f() *u32 {
        \\    var x: u32 = 42;
        \\    const p = &x;
        \\    return p;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 4, "'p'");
    try std.testing.expect(mem.indexOf(u8, issues.items[0].message, "'x'") != null);
}

test "ZA111: transitive alias fires" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\fn f() *u32 {
        \\    var x: u32 = 42;
        \\    const p = &x;
        \\    const q = p;
        \\    return q;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 5, "'q'");
}

test "ZA111: bare var address is silent (compiler-owned)" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\fn f() *u32 {
        \\    var x: u32 = 42;
        \\    return (&x);
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "ZA111: comptime const and comptime-flavored params are silent" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\fn f() *const u32 {
        \\    const x: u32 = 42;
        \\    return &x;
        \\}
        \\fn g(comptime x: u32) *const u32 {
        \\    return &x;
        \\}
        \\fn h(t: type) *const type {
        \\    return &t;
        \\}
        \\fn u(x: anytype) *const u32 {
        \\    return &x;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "ZA111: global var is silent" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\var g: u32 = 42;
        \\fn f() *u32 {
        \\    return &g;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "ZA111: slice of non-array is silent" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\fn f(s: []u32) []u32 {
        \\    return s[0..1];
        \\}
        \\fn g() []u32 {
        \\    var s: []u32 = undefined;
        \\    return s[0..1];
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "ZA111: malformed source is skipped without crashing" {
    const a = std.testing.allocator;
    var issues = try runZa111(a, "fn broken( {");
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "ZA111: nested container method is analyzed with its own locals" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\const S = struct { a: u32 };
        \\fn outer() *u32 {
        \\    var s: S = .{ .a = 1 };
        \\    const T = struct {
        \\        fn m() *u32 {
        \\            var inner_s: S = .{ .a = 2 };
        \\            return &inner_s.a;
        \\        }
        \\    };
        \\    _ = T;
        \\    return &s.a;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 2), issues.items.len);
    // Node-array order is not source order — match by line, not position.
    var found_inner = false;
    var found_outer = false;
    for (issues.items) |issue| {
        const hit_inner = issue.line == 7 and
            mem.indexOf(u8, issue.message, "'inner_s'") != null;
        const hit_outer = issue.line == 11 and
            mem.indexOf(u8, issue.message, "'s'") != null;
        found_inner = found_inner or hit_inner;
        found_outer = found_outer or hit_outer;
    }
    try std.testing.expect(found_inner);
    try std.testing.expect(found_outer);
}

test "ZA111: return inside nested blocks fires" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\const S = struct { a: u32 };
        \\fn f(c: bool) *u32 {
        \\    if (c) {
        \\        var s: S = .{ .a = 1 };
        \\        return &s.a;
        \\    }
        \\    unreachable;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 5, "'s'");
}

test "ZA111: while loop body fires" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\const S = struct { a: u32 };
        \\fn f(c: bool) *u32 {
        \\    while (c) {
        \\        var s: S = .{ .a = 1 };
        \\        return &s.a;
        \\    }
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 5, "'s'");
}

test "ZA111: chained address through pointer param is silent" {
    const a = std.testing.allocator;
    // The ephor ConcurrencyScanState.current pattern: self is a pointer,
    // so &self.x[i] addresses caller-owned memory behind it — not the
    // stack frame. This was the first dogfood false positive.
    var issues = try runZa111(a,
        \\const R = struct { items: [4]u32, len: usize };
        \\fn current(self: *R) *u32 {
        \\    return &self.items[self.len - 1];
        \\}
        \\fn alias_form(self: *R) *u32 {
        \\    const a = &self.items;
        \\    return a;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "ZA111: bare address of pointer param fires (slot, not pointee)" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\fn f(p: *u32) **u32 {
        \\    return &p;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 2, "'p'");
}

test "ZA111: pointer-typed var chained address is silent" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\fn f(p: *u32, i: usize) *u32 {
        \\    var q: *u32 = p;
        \\    var r = q;
        \\    return &r[i];
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "ZA111: comptime var is silent (comptime string-builder idiom)" {
    const a = std.testing.allocator;
    // The tigerbeetle ruby_bindings to_snake_case pattern: a comptime
    // var lives in static memory, so slicing it is the standard idiom.
    var issues = try runZa111(a,
        \\fn to_snake(comptime input: []const u8) []const u8 {
        \\    comptime var output: [input.len * 2]u8 = undefined;
        \\    comptime var len: usize = 0;
        \\    inline for (input) |c| {
        \\        output[len] = c;
        \\        len += 1;
        \\    }
        \\    return output[0..len];
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "ZA111: address-of-init var is a pointer (tigerbeetle forest pattern)" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\const G = struct { objects: u32, ids: u32 };
        \\const F = struct { g: G };
        \\fn tree_for_id(forest: *F, comptime id: u32) *u32 {
        \\    var groove = &@field(forest.g, "g");
        \\    return &groove.objects;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "ZA111: slice-field chain is silent (tigerbeetle cache pattern)" {
    const a = std.testing.allocator;
    // `self` is by-value, but `words` is a slice field — the element
    // address points into caller-owned backing, not the stack copy.
    var issues = try runZa111(a,
        \\const P = struct { words: []u32 };
        \\fn word(self: P, index: u64) *u32 {
        \\    return &self.words[index];
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "ZA111: array-field chain fires (resolved unsafe)" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\const S = struct { arr: [4]u32, n: usize };
        \\fn f(self: S) *u32 {
        \\    return &self.arr[self.n];
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 3, "'self'");
}

test "ZA111: explicit-type init fires, unknown-type init is silent" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\const S = struct { a: u32 };
        \\fn makeS() S {
        \\    return .{ .a = 1 };
        \\}
        \\fn fires() *u32 {
        \\    var s = S{ .a = 1 };
        \\    return &s.a;
        \\}
        \\fn silent() *u32 {
        \\    var s = makeS();
        \\    return &s.a;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 7, "'s'");
}

test "ZA111: optional-unwrap chain fires" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\const S = struct { a: u32 };
        \\fn f(s: ?S) *const u32 {
        \\    return &s.?.a;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 3, "'s'");
}

// ============================================================================
// Nesting budget tests (EPH-I0191)
// ============================================================================

test "exceedsNestingBudget: boundary is exactly at budget" {
    try std.testing.expect(!exceedsNestingBudget("(((1))", 4));
    try std.testing.expect(!exceedsNestingBudget("((((1))))", 4));
    try std.testing.expect(exceedsNestingBudget("(((((1)))))", 4));
}

test "exceedsNestingBudget: empty source is within budget" {
    try std.testing.expect(!exceedsNestingBudget("", 0));
}

test "exceedsNestingBudget: literal and comment delimiters do not count" {
    const src =
        \\const a = "(((((((((((";
        \\const b = "escaped \" (((( still string";
        \\const c = '(';
        \\const d = '}';
        \\// (((( comment (((( ))))
        \\\\ (((( multiline string body
        \\const e = f(1, g[2], .{ .x = 3 });
    ;
    // Code nesting peaks at 2 (call holding index holding init). Literal
    // and comment delimiters would push it past 12 if they counted.
    try std.testing.expect(!exceedsNestingBudget(src, 2));
}

test "exceedsNestingBudget: mixed bracket kinds share one counter" {
    try std.testing.expect(exceedsNestingBudget("([{([", 4));
    // Mismatched closers still decrement: the peak here is exactly 4.
    try std.testing.expect(!exceedsNestingBudget("([{(}])", 4));
}

test "exceedsNestingBudget: unbalanced closers clamp at zero" {
    // A usize counter would panic on underflow without the clamp.
    try std.testing.expect(!exceedsNestingBudget("))) ] }}", 1));
    try std.testing.expect(!exceedsNestingBudget(")(", 1));
    try std.testing.expect(exceedsNestingBudget(")((", 1));
}

/// Valid Zig with `n` nested grouped expressions: `const x = (((1)));`.
/// The shape stays parseable at any depth, so only the budget decides
/// skip vs parse.
fn buildNestedParens(a: Allocator, n: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "const x = ");
    try buf.appendNTimes(a, '(', n);
    try buf.append(a, '1');
    try buf.appendNTimes(a, ')', n);
    try buf.append(a, ';');
    return buf.toOwnedSlice(a);
}

/// Parts of a synthetic operator-run file: `head` + `op`×n + `tail`.
const RunSpec = struct {
    head: []const u8,
    op: []const u8,
    tail: []const u8,
};

/// Valid Zig with `n` repetitions of `spec.op` between head and tail.
/// The shapes stay parseable at any count, so only the budget decides
/// skip vs parse.
fn buildRun(a: Allocator, spec: RunSpec, n: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, spec.head);
    for (0..n) |_| try buf.appendSlice(a, spec.op);
    try buf.appendSlice(a, spec.tail);
    return buf.toOwnedSlice(a);
}

/// Run the AST tier over `src` and assert the parse/skip counters. A
/// skip or a parse must never produce issues from these synthetic files.
fn expectTierCounters(src: []const u8, want_parsed: usize, want_skipped: usize) !void {
    const a = std.testing.allocator;
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    defer types.deinitIssues(&issues, a);
    var stats = Stats{};
    try analyzeFileAstTier(a, .{ .issues = &issues, .stats = &stats }, "run.zig", src);
    try std.testing.expectEqual(want_parsed, stats.parsed);
    try std.testing.expectEqual(want_skipped, stats.skipped);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "EPH-I0191: over-budget nesting skips the AST tier, counted in stats" {
    const a = std.testing.allocator;
    const src = try buildNestedParens(a, max_nesting_depth + 1);
    defer a.free(src);
    try expectTierCounters(src, 0, 1);
}

test "EPH-I0191: within-budget nesting parses and counts as parsed" {
    const a = std.testing.allocator;
    const src = try buildNestedParens(a, max_nesting_depth - 1);
    defer a.free(src);
    try expectTierCounters(src, 1, 0);
}

test "exceedsNestingBudget: prefix runs span whitespace and newlines" {
    try std.testing.expect(exceedsNestingBudget("!  \n\n  !\t! x", 2));
    try std.testing.expect(!exceedsNestingBudget("!  \n\n  !\t! x", 3));
}

test "exceedsNestingBudget: run resets at statement boundaries" {
    try std.testing.expect(!exceedsNestingBudget("!a; !b; !c;", 1));
    try std.testing.expect(exceedsNestingBudget("!!!!!a; !b;", 4));
    try std.testing.expect(!exceedsNestingBudget("!!!!!a; !b;", 5));
}

test "exceedsNestingBudget: error-union chains accumulate across operands" {
    // Each `!` recurses through expectTypeExpr (Parse.zig
    // parseErrorUnionExpr), so the operands between operators must not
    // reset the run. A reset-on-operand rule peaks at 1 here and misses
    // the whole class.
    const src = "const x: anyerror!anyerror!anyerror!u8 = undefined;";
    try std.testing.expect(exceedsNestingBudget(src, 2));
    try std.testing.expect(!exceedsNestingBudget(src, 3));
}

test "exceedsNestingBudget: infix operator chains over-count toward a skip" {
    // `-` is infix here and the real parse stays flat. The counter cannot
    // tell infix from prefix, so it accumulates: over-count forces a safe
    // skip, never an under-count.
    try std.testing.expect(exceedsNestingBudget("const x = a - b - c - d - e;", 3));
    try std.testing.expect(!exceedsNestingBudget("const x = a - b - c - d - e;", 4));
}

test "exceedsNestingBudget: keyword and two-char prefix forms count" {
    try std.testing.expect(exceedsNestingBudget("const x = try try try f();", 2));
    try std.testing.expect(exceedsNestingBudget("const x = -% -% -% y;", 2));
    try std.testing.expect(exceedsNestingBudget("const x: anyframe->anyframe->u8 = undefined;", 1));
    // An arrow split across lines still completes the operator.
    try std.testing.expect(exceedsNestingBudget("const x: anyframe\n->anyframe\n->u8 = undefined;", 1));
    // A bare `anyframe` is a type operand, not an operator.
    try std.testing.expect(!exceedsNestingBudget("var af: anyframe = undefined;", 0));
}

test "exceedsNestingBudget: prefix operators in literal contexts do not count" {
    const src =
        \\const a = "!!!!!!";
        \\const b = '!';
        \\// !!!!!!
        \\\\ !!!!!!
        \\const c = !x;
    ;
    try std.testing.expect(!exceedsNestingBudget(src, 1));
    try std.testing.expect(exceedsNestingBudget(src, 0));
}

test "exceedsNestingBudget: delimiters do not reset the run" {
    // Prefix frames stay live while the parenthesized operand parses, so
    // `(` must not bound the run. Otherwise 512 parens holding 40 `!`
    // each pass both counters and still overflow the stack.
    try std.testing.expect(exceedsNestingBudget("!!(!!(!!x)))", 5));
    try std.testing.expect(!exceedsNestingBudget("!!(!!(!!x)))", 6));
}

test "EPH-I0191: prefix-not run over budget skips the AST tier" {
    const a = std.testing.allocator;
    const src = try buildRun(a, .{
        .head = "const x = ",
        .op = "!",
        .tail = " true;",
    }, max_nesting_depth + 1);
    defer a.free(src);
    try expectTierCounters(src, 0, 1);
}

test "EPH-I0191: optional-type run over budget skips the AST tier" {
    const a = std.testing.allocator;
    const src = try buildRun(a, .{
        .head = "const x: ",
        .op = "?",
        .tail = "u8 = undefined;",
    }, max_nesting_depth + 1);
    defer a.free(src);
    try expectTierCounters(src, 0, 1);
}

test "EPH-I0191: error-union run over budget skips the AST tier" {
    const a = std.testing.allocator;
    const src = try buildRun(a, .{
        .head = "const x: anyerror",
        .op = "!anyerror",
        .tail = " = undefined;",
    }, max_nesting_depth + 1);
    defer a.free(src);
    try expectTierCounters(src, 0, 1);
}

test "EPH-I0191: anyframe-arrow run over budget skips the AST tier" {
    const a = std.testing.allocator;
    const src = try buildRun(a, .{
        .head = "const x: ",
        .op = "anyframe->",
        .tail = "u8 = undefined;",
    }, max_nesting_depth + 1);
    defer a.free(src);
    try expectTierCounters(src, 0, 1);
}

test "EPH-I0191: within-budget prefix run parses and counts as parsed" {
    const a = std.testing.allocator;
    const src = try buildRun(a, .{
        .head = "const x = ",
        .op = "!",
        .tail = " true;",
    }, max_nesting_depth - 1);
    defer a.free(src);
    try expectTierCounters(src, 1, 0);
}

// ============================================================================
// Grammar-audit table tests (EPH-I0268)
// ============================================================================

test "exceedsNestingBudget: sequential slice types count in the run (hole C)" {
    // `[][][]u8` recurses per level while its brackets balance within
    // the level, so depth alone misses it.
    try std.testing.expect(exceedsNestingBudget("const x: [][][]u8 = undefined;", 2));
    try std.testing.expect(!exceedsNestingBudget("const x: [][][]u8 = undefined;", 3));
}

test "exceedsNestingBudget: index chains over-count toward a skip" {
    // `a[0][1][2][3]` is a flat parse, but `[` also counts in the run.
    // Over-counting skips. An under-count is absorbed by the byte cap
    // and the parse stack (EPH-I0268).
    try std.testing.expect(exceedsNestingBudget("const x = a[0][1][2][3];", 3));
    try std.testing.expect(!exceedsNestingBudget("const x = a[0][1][2][3];", 4));
}

test "exceedsNestingBudget: qualified error-union operands keep the run (hole A)" {
    // `.` sits inside the operand while the parent `!` frames are live,
    // so it must not reset. A reset-on-non-ident rule peaks at 1 here.
    try std.testing.expect(exceedsNestingBudget("const x: a.b!a.b!a.b!u8 = undefined;", 2));
    try std.testing.expect(!exceedsNestingBudget("const x: a.b!a.b!a.b!u8 = undefined;", 3));
}

test "exceedsNestingBudget: right-recursive keywords count (holes B and E)" {
    try std.testing.expect(exceedsNestingBudget("const x = comptime comptime comptime true;", 2));
    try std.testing.expect(!exceedsNestingBudget("const x = comptime comptime comptime true;", 3));
    try std.testing.expect(exceedsNestingBudget("if (a) if (b) if (c) x;", 2));
    try std.testing.expect(!exceedsNestingBudget("if (a) if (b) if (c) x;", 3));
}

test "exceedsNestingBudget: fn-type chains count, declarations do not (hole D)" {
    try std.testing.expect(exceedsNestingBudget("const x: fn() fn() fn() void = undefined;", 2));
    try std.testing.expect(!exceedsNestingBudget("const x: fn() fn() fn() void = undefined;", 3));
    // A declaration is one iterative frame in the container loop. Its
    // parens still count in depth, so the run budget is not the binding
    // constraint here.
    try std.testing.expect(!exceedsNestingBudget("fn f() void {}", 1));
}

test "exceedsNestingBudget: left-assoc binary chains and statement streams stay flat" {
    // `and` is an iterative same-precedence loop, not recursion.
    try std.testing.expect(!exceedsNestingBudget("const x = a and b and c and d;", 0));
    // Sequential statements reset at `;`: a long file of small statements
    // peaks at a run of 1.
    try std.testing.expect(!exceedsNestingBudget("if (a) b(); if (c) d();", 1));
    try std.testing.expect(exceedsNestingBudget("if (a) b(); if (c) d();", 0));
}

test "EPH-I0191: qualified error-union run over budget skips the AST tier (hole A)" {
    const a = std.testing.allocator;
    const src = try buildRun(a, .{
        .head = "const x: a.b",
        .op = "!a.b",
        .tail = "!u8 = undefined;",
    }, max_nesting_depth + 1);
    defer a.free(src);
    try expectTierCounters(src, 0, 1);
}

test "EPH-I0191: keyword run over budget skips the AST tier (hole B)" {
    const a = std.testing.allocator;
    const src = try buildRun(a, .{
        .head = "const x = ",
        .op = "comptime ",
        .tail = "true;",
    }, max_nesting_depth + 1);
    defer a.free(src);
    try expectTierCounters(src, 0, 1);
}

test "EPH-I0191: slice-type run over budget skips the AST tier (hole C)" {
    const a = std.testing.allocator;
    const src = try buildRun(a, .{
        .head = "const x: ",
        .op = "[]",
        .tail = "u8 = undefined;",
    }, max_nesting_depth + 1);
    defer a.free(src);
    try expectTierCounters(src, 0, 1);
}

test "EPH-I0191: fn-type run over budget skips the AST tier (hole D)" {
    const a = std.testing.allocator;
    const src = try buildRun(a, .{
        .head = "const x: ",
        .op = "fn() ",
        .tail = "void = undefined;",
    }, max_nesting_depth + 1);
    defer a.free(src);
    try expectTierCounters(src, 0, 1);
}

test "EPH-I0191: if-body run over budget skips the AST tier (hole E)" {
    const a = std.testing.allocator;
    const src = try buildRun(a, .{
        .head = "const x = ",
        .op = "if (a) ",
        .tail = "true;",
    }, max_nesting_depth + 1);
    defer a.free(src);
    try expectTierCounters(src, 0, 1);
}

/// Valid Zig of `n` sequential if-statements inside one function.
fn buildSequentialIfs(a: Allocator, n: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "fn f() void {\n");
    for (0..n) |_| try buf.appendSlice(a, "if (a) b();\n");
    try buf.append(a, '}');
    return buf.toOwnedSlice(a);
}

/// Valid Zig of `n` distinctly-named function declarations.
fn buildFnDecls(a: Allocator, n: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    for (0..n) |k| {
        const line = try std.fmt.allocPrint(a, "fn f{d}() void {{}}\n", .{k});
        defer a.free(line);
        try buf.appendSlice(a, line);
    }
    return buf.toOwnedSlice(a);
}

test "EPH-I0191: sequential if-statements parse (statement boundaries reset)" {
    const a = std.testing.allocator;
    const src = try buildSequentialIfs(a, max_nesting_depth + 100);
    defer a.free(src);
    try expectTierCounters(src, 1, 0);
}

test "EPH-I0191: function declarations parse (container loop is iterative)" {
    const a = std.testing.allocator;
    const src = try buildFnDecls(a, max_nesting_depth + 100);
    defer a.free(src);
    try expectTierCounters(src, 1, 0);
}

test "EPH-I0191: within-budget fn-type chain parses" {
    try expectTierCounters("const x: fn() fn() void = undefined;", 1, 0);
}

/// Valid Zig padded with comment bytes to exactly `total` bytes.
fn buildPaddedSource(a: Allocator, total: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    const head = "fn f() void {}\n//";
    try buf.appendSlice(a, head);
    try buf.appendNTimes(a, 'x', total - head.len);
    return buf.toOwnedSlice(a);
}

test "EPH-I0268: over-cap file skips the AST tier, counted in stats" {
    const a = std.testing.allocator;
    const src = try buildPaddedSource(a, max_ast_file_bytes + 1);
    defer a.free(src);
    try expectTierCounters(src, 0, 1);
}

test "EPH-I0268: at-cap file parses" {
    const a = std.testing.allocator;
    const src = try buildPaddedSource(a, max_ast_file_bytes);
    defer a.free(src);
    try expectTierCounters(src, 1, 0);
}

test "EPH-I0268: init parses nesting past the default thread stack" {
    const a = std.testing.allocator;
    // 20k nested parens need ~40-100 MB of parse stack at the verified
    // ten frames per level: past the 16 MB default thread stack, inside
    // parse_stack_bytes, and under the byte cap. Without the worker
    // thread this input SIGSEGVs the default stack. Do not run it
    // against a pre-thread build: the crash kills the test runner.
    const src = try buildNestedParens(a, 20_000);
    defer a.free(src);
    var actx = try AstContext.init(a, src);
    defer actx.deinit(a);
    try std.testing.expect(actx.ok);
}

/// Valid Zig of one switch with `n` distinctly-tagged prongs.
fn buildSwitchProngs(a: Allocator, n: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "fn f(x: u16) u16 { return switch (x) {\n");
    for (0..n) |k| {
        const line = try std.fmt.allocPrint(a, "{d} => 1,\n", .{k});
        defer a.free(line);
        try buf.appendSlice(a, line);
    }
    try buf.appendSlice(a, "else => 0, }; }");
    return buf.toOwnedSlice(a);
}

test "EPH-I0268: switch prongs parse (iterative list, not counted)" {
    const a = std.testing.allocator;
    const src = try buildSwitchProngs(a, max_nesting_depth + 100);
    defer a.free(src);
    try expectTierCounters(src, 1, 0);
}

/// Valid Zig of `n` defer and `n` errdefer statements in one function.
fn buildDeferStatements(a: Allocator, n: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "fn f() !void {\n");
    for (0..n) |_| try buf.appendSlice(a, "defer b();\nerrdefer b();\n");
    try buf.append(a, '}');
    return buf.toOwnedSlice(a);
}

test "EPH-I0268: defer and errdefer payloads parse (block statements, not counted)" {
    const a = std.testing.allocator;
    const src = try buildDeferStatements(a, max_nesting_depth + 100);
    defer a.free(src);
    try expectTierCounters(src, 1, 0);
}
