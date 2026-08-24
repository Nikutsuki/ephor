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
//! Degradation guarantee: when a file's parse produces errors the tree is
//! partial and `AstContext.ok` is false — AST rules skip the file and the
//! line tier still covers it. Files that nest delimiters or prefix
//! operators past `max_nesting_depth` skip the same way before the parse
//! runs (EPH-I0191). A refused parse thread skips the file too
//! (EPH-I0597). Nothing is logged per file. Corpus runs touch thousands
//! of files.
//!
//! ZA111 (returned-stack-reference) lives in ast_tier_za111.zig, split
//! out so each half stays under the 64 KiB AST-tier input cap
//! (EPH-I0601): the file that implements the rule must stay small
//! enough for the rule to analyze it. This file owns the parse, the
//! nesting pre-scan, and the per-file pipeline.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const types = @import("types.zig");
const za111 = @import("ast_tier_za111.zig");

const Issue = types.Issue;
const Ast = std.zig.Ast;
const NodeIndex = Ast.Node.Index;

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
    /// callers must go through `analyzeFileAstTier`. A refusal to create
    /// the worker thread surfaces as `error.ThreadSpawnFailed`; the tier
    /// turns it into a counted skip (EPH-I0597).
    pub fn init(allocator: Allocator, source: []const u8) !AstContext {
        return switch (runGuardedParse(allocator, source, spawnParseWorker)) {
            .ok => |ctx| ctx,
            .spawn_refused => error.ThreadSpawnFailed,
            .err => |err| err,
        };
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
    /// Files whose AST analysis completed. A file that fails mid-analysis
    /// (allocation) is not counted here (EPH-I0600).
    parsed: usize = 0,
    /// Files degraded to line-tier coverage: parse errors, deep nesting,
    /// a size past the byte cap, or a refused parse thread (EPH-I0597).
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

/// How one guarded parse ended. A spawn refusal is separated from
/// worker-side errors: the tier degrades the file on a refusal but
/// propagates allocation errors (EPH-I0597).
const ParseOutcome = union(enum) {
    ok: AstContext,
    /// The worker thread could not be created. Parsing on the caller's
    /// stack would reopen the EPH-I0191 crash class, so the file
    /// degrades to line-tier coverage instead.
    spawn_refused,
    /// The worker ran and failed (allocation).
    err: anyerror,
};

/// Creates the parse worker thread. Split out so the degrade contract
/// is testable: tests inject a refusing spawner (EPH-I0597).
///
/// Worker-thread contract (F10, EPH-I0697): the worker must never call
/// compat helpers. compat.cached_tables is a plain unsynchronized lazy
/// global, and its race-freedom rests on compat being reachable from
/// the main thread only (the thread-safety comment in compat.zig names
/// the same invariant). The join-then-resume shape makes the worker
/// the process's only concurrent code: keep it allocator- and Ast-only.
fn spawnParseWorker(job: *ParseJob) anyerror!std.Thread {
    return std.Thread.spawn(.{ .stack_size = parse_stack_bytes }, parseWorker, .{job});
}

/// One guarded parse through the injectable spawner. The caller joins
/// the worker before it resumes, so every allocation happens-before
/// the caller: no concurrent allocator access.
fn runGuardedParse(
    allocator: Allocator,
    source: []const u8,
    spawn: *const fn (*ParseJob) anyerror!std.Thread,
) ParseOutcome {
    var job = ParseJob{ .allocator = allocator, .source = source };
    const worker = spawn(&job) catch return .spawn_refused;
    worker.join();
    if (job.err) |err| return .{ .err = err };
    return .{ .ok = job.result.? };
}

/// The tier's view of a parse outcome: a spawn refusal degrades to a
/// counted skip (an environment failure, not a file defect), and
/// worker-side errors propagate (EPH-I0597).
fn resolveParseOutcome(outcome: ParseOutcome, stats: ?*Stats) !?AstContext {
    return switch (outcome) {
        .ok => |ctx| ctx,
        .spawn_refused => {
            if (stats) |s| s.skipped += 1;
            return null;
        },
        .err => |err| err,
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
/// to line-tier coverage, the same guarantee as parse errors.
pub const max_ast_file_bytes: usize = 64 * 1024;

/// Carried state for the pre-scan: two counters that estimate live
/// parser frames, plus the pending-arrow watch for `anyframe->` and the
/// pending-fn watch for the fn-type paren (EPH-I0598).
const NestingScan = struct {
    depth: usize = 0,
    run: usize = 0,
    /// Set while an `anyframe` keyword waits for its `->`. The word alone
    /// is a type operand, so the run parks here until the arrow decides.
    arrow_run: ?usize = null,
    /// Set while a `fn` waits for its `(`: the type form's paren may sit
    /// on a later line, so the next non-blank code char decides
    /// (EPH-I0598).
    pending_fn: bool = false,
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
///   await                              no keyword        identifier
///                                      (async removed in 0.15; verified
///                                      absent from the 0.16.0 stdlib:
///                                      no tokenizer keyword, no
///                                      Parse.zig production, no Ast
///                                      tag — EPH-I0591)
///   suspend payloads                   statement prefix  not counted
///                                      (KEYWORD_suspend
///                                      BlockExprStatement — one frame
///                                      per keyword, `;` resets, cannot
///                                      chain; the defer/errdefer class)
///   if/while/for bodies                right-recursive   run
///   fn-type chains `fn() fn() void`    right-recursive   run (fn + `(`,
///                                      the paren may sit on a later
///                                      line — EPH-I0598)
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
        if (scan.pending_fn) resolvePendingFn(scan, line[i]);
        scanCodeChar(line, &i, scan);
        if (scan.depth > budget or scan.run > budget) return true;
    }
    return false;
}

/// Resolve a `fn` split from its `(` across a line break (EPH-I0598).
/// A `(` counts the type form; any other non-blank char is the
/// declaration form or garbage. Blank chars keep the watch alive across
/// blank lines, matching the same-line lookahead's whitespace skip.
fn resolvePendingFn(scan: *NestingScan, c: u8) void {
    if (c == ' ' or c == '\t' or c == '\r') return;
    scan.pending_fn = false;
    if (c == '(') scan.run += 1;
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
        // The frames parked before the bare `anyframe` operand stay
        // live after the operand completes: restore them instead of
        // discarding them (EPH-I0599).
        scan.run = saved;
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
        ')', ']', '}' => scan.depth -|= 1,
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
        if (nextNonSpaceIsParen(line, i.*)) {
            scan.run += 1;
            return;
        }
        // `fn` with no `(` on this line: the paren may sit on a later
        // line. Park the decision until the next non-blank code char
        // (EPH-I0598).
        scan.pending_fn = true;
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
/// handled apart: only its type form recurses. `await` is absent by
/// design: async was removed in 0.15 and the 0.16.0 stdlib has no await
/// keyword (EPH-I0591). `suspend` is a statement-level production with a
/// BlockExprStatement operand — the defer/errdefer class, not a chain
/// (EPH-I0591).
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

/// Run every AST-tier rule over one file. Files with parse errors, deep
/// nesting, a size past `max_ast_file_bytes`, or a refused parse thread
/// are skipped and counted; the line tier still covers them. Allocation
/// errors propagate (EPH-I0597).
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
    // same guarantee as parse errors.
    if (exceedsNestingBudget(content, max_nesting_depth)) {
        if (out.stats) |s| s.skipped += 1;
        return;
    }
    const outcome = runGuardedParse(a, content, spawnParseWorker);
    var parsed = try resolveParseOutcome(outcome, out.stats) orelse return;
    defer parsed.deinit(a);
    if (!parsed.ok) {
        if (out.stats) |s| s.skipped += 1;
        return;
    }
    var tidx = try za111.buildTypeIndex(a, &parsed.tree);
    defer tidx.deinit(a);
    var ctx = za111.Za111Ctx{
        .a = a,
        .tree = &parsed.tree,
        .tidx = &tidx,
        .path = path,
        .out = out.issues,
    };
    try za111.analyzeFileZa111(&ctx);
    // A file counts parsed only when its analysis completes: an OOM
    // mid-analysis must not count the file as analyzed (EPH-I0600).
    if (out.stats) |s| s.parsed += 1;
}

// ============================================================================
// Tests
// ============================================================================

test {
    // Test-reference idiom: the ast_tier_za111 split's tests must join
    // the suite (EPH-I0601). Body-only references do not force analysis
    // of test declarations.
    _ = za111;
}

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

/// Test seam: a spawner that always refuses, standing in for an
/// environment that cannot create the parse thread (EPH-I0597).
fn refusingSpawn(job: *ParseJob) anyerror!std.Thread {
    _ = job;
    return error.TestThreadRefused;
}

test "spawn refusal degrades the file to a counted skip (EPH-I0597)" {
    const a = std.testing.allocator;
    const outcome = runGuardedParse(a, "fn f() void {}\n", refusingSpawn);
    try std.testing.expect(outcome == .spawn_refused);
    var stats = Stats{};
    const parsed = try resolveParseOutcome(outcome, &stats);
    try std.testing.expect(parsed == null);
    try std.testing.expectEqual(@as(usize, 0), stats.parsed);
    try std.testing.expectEqual(@as(usize, 1), stats.skipped);
}

test "guarded parse runs the worker and yields the context (EPH-I0597)" {
    const a = std.testing.allocator;
    var outcome = runGuardedParse(a, "fn f() void {}\n", spawnParseWorker);
    switch (outcome) {
        .ok => |*ctx| ctx.deinit(a),
        .spawn_refused => return error.TestExpectedSpawn,
        .err => |err| return err,
    }
}

test "F12 guard: both AST-tier halves stay under the ZA111 byte cap (EPH-I0601)" {
    try std.testing.expect(@embedFile("ast_tier.zig").len <= max_ast_file_bytes);
    try std.testing.expect(@embedFile("ast_tier_za111.zig").len <= max_ast_file_bytes);
    // EPH-I1123: pin the AST tier's pre-scan siblings too. LiteralState
    // lives in types.zig, and sanitize.zig split out of it in the I1123
    // fix. A re-crossing would silently drop the rule's own second home.
    try std.testing.expect(@embedFile("types.zig").len <= max_ast_file_bytes);
    try std.testing.expect(@embedFile("sanitize.zig").len <= max_ast_file_bytes);
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

test "ZA111: slice field address without index fires (EPH-I0590)" {
    const a = std.testing.allocator;
    // `&self.words` addresses the slice FIELD inside the stack copy of
    // self, not the caller-owned backing. The index form above is safe;
    // this form is stack UB the compiler also misses.
    var issues = try runZa111(a,
        \\const P = struct { words: []u32 };
        \\fn word(self: P) *[]u32 {
        \\    return &self.words;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 3, "'self'");
}

test "ZA111: pointer field address fires (EPH-I0590)" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\const P = struct { p: *u32 };
        \\fn slot(self: P) **u32 {
        \\    return &self.p;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 3, "'self'");
}

test "ZA111: optional pointer payload address fires (EPH-I0590)" {
    const a = std.testing.allocator;
    var issues = try runZa111(a,
        \\fn slot(opt: ?*u32) **u32 {
        \\    return &opt.?;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 2, "'opt'");
}

test "ZA111: slice slot fields fire, backing memory stays silent (EPH-I1122)" {
    const a = std.testing.allocator;
    // &v.len / &v.ptr on a by-value slice (or many pointer) address the
    // len/ptr components of the fat-pointer stack copy — real stack UB.
    // The pre-fix short-circuit (bind.is_pointer => silent) missed every
    // slot shape while correctly keeping the backing-memory neighbors
    // silent: &v[i] addresses caller-owned memory, &v[i].len addresses an
    // element's own field, &p.len on a *R addresses the pointee's field,
    // and an inferred local's type is unprovable (FN-only).
    var issues = try runZa111(a,
        \\fn len_slot(v: []u32) *usize {
        \\    return &v.len;
        \\}
        \\fn ptr_slot(v: []u32) *[*]u32 {
        \\    return &v.ptr;
        \\}
        \\fn many_len_slot(p: [*]u32) *usize {
        \\    return &p.len;
        \\}
        \\fn backing(v: []u32) *u32 {
        \\    return &v[0];
        \\}
        \\fn element_field(v: [][]u32) *usize {
        \\    return &v[0].len;
        \\}
        \\fn alias_form(v: []u32) *usize {
        \\    const q = &v.len;
        \\    return q;
        \\}
        \\const R = struct { len: usize };
        \\fn pointee_field(p: *R) *usize {
        \\    return &p.len;
        \\}
        \\fn inferred(v: []u32) *usize {
        \\    var w = v;
        \\    return &w.len;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    // The four slot-address shapes fire (the alias reports on its return
    // line); the four neighbor shapes stay silent.
    try std.testing.expectEqual(@as(usize, 4), issues.items.len);
    var lines: [4]usize = undefined;
    for (issues.items, 0..) |issue, i| {
        try std.testing.expectEqualStrings("ZA111", issue.rule);
        try std.testing.expect(issue.severity == .err);
        lines[i] = issue.line;
    }
    try std.testing.expect(std.mem.indexOfScalar(usize, &lines, 2) != null);
    try std.testing.expect(std.mem.indexOfScalar(usize, &lines, 5) != null);
    try std.testing.expect(std.mem.indexOfScalar(usize, &lines, 8) != null);
    try std.testing.expect(std.mem.indexOfScalar(usize, &lines, 18) != null);
}

test "ZA111: fn-local type collision resolves per fn (EPH-I0592)" {
    const a = std.testing.allocator;
    // Two disjoint fn-local types share the name S. A last-wins index
    // resolves one fn's chain against the other's type: the slice S
    // would silence the array fn (false negative) or the array S would
    // fire in the slice fn (false positive). Per-fn scoping keeps the
    // slice fn silent and fires only the array fn.
    var issues = try runZa111(a,
        \\fn slice_shape(v: S) *u32 {
        \\    const S = struct { s: []u32 };
        \\    return &v.s[0];
        \\}
        \\fn array_shape(v: S) *u32 {
        \\    const S = struct { s: [4]u32 };
        \\    return &v.s[0];
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 7, "'v'");
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

test "ZA111: await parses as an identifier, no walker arm needed (EPH-I0596)" {
    const a = std.testing.allocator;
    // `await` is a plain identifier in 0.16 (async removed in 0.15), so
    // the walker treats it as a leaf. This pins that await-named code
    // parses and that the walk keeps finding the real finding.
    var issues = try runZa111(a,
        \\fn f() *u32 {
        \\    const await = 42;
        \\    _ = await;
        \\    var s: S = .{ .a = 1 };
        \\    return &s.a;
        \\}
        \\const S = struct { a: u32 };
    );
    defer types.deinitIssues(&issues, a);
    try expectZa111(issues.items, 5, "'s'");
}

test "ZA111: destructured binding chains stay silent (untyped lhs, EPH-I0596)" {
    const a = std.testing.allocator;
    // Destructured `var` bindings enter FnScan as by-value locals, but
    // their lhs patterns carry no type node, so chains resolve silent
    // under the precision policy. This pins the honest limit and guards
    // the new lhs push against crashes on real destructure trees.
    var issues = try runZa111(a,
        \\const S = struct { a: u32 };
        \\fn f(pair: [2]S) *u32 {
        \\    var x, var y = pair;
        \\    return &x.a;
        \\}
    );
    defer types.deinitIssues(&issues, a);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
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

test "exceedsNestingBudget: fn-type split across lines counts (EPH-I0598)" {
    // The type form is `fn (`: with the paren on the next line the
    // lookahead crosses the break and counts like the single-line form.
    // Two chained fn types drive the run past the `(`'s own depth, so
    // only the crossed-line lookahead can cross the budget.
    try std.testing.expect(exceedsNestingBudget("const x: fn\n() fn() void = undefined;", 1));
    try std.testing.expect(!exceedsNestingBudget("const x: fn\n() fn() void = undefined;", 2));
    // The single-line chain crosses the same budget.
    try std.testing.expect(exceedsNestingBudget("const x: fn () fn () void = undefined;", 1));
    // A declaration split across the break does not count.
    try std.testing.expect(!exceedsNestingBudget("fn\nname() void {}", 1));
}

test "exceedsNestingBudget: broken anyframe watch restores the parked run (EPH-I0599)" {
    // Frames parked before a bare `anyframe` operand stay live after
    // the operand: a non-arrow break restores them instead of
    // discarding them, so chains past the break keep counting.
    try std.testing.expect(exceedsNestingBudget("?anyframe.x*", 1));
    try std.testing.expect(!exceedsNestingBudget("?anyframe.x*", 2));
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

test "parsed counts only fully analyzed files (EPH-I0600)" {
    const src =
        \\const S = struct { a: u32 };
        \\fn f() *u32 {
        \\    var s: S = undefined;
        \\    return &s.a;
        \\}
    ;
    // A clean run parses and analyzes the file.
    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    {
        var issues: std.ArrayListUnmanaged(Issue) = .empty;
        defer types.deinitIssues(&issues, probe.allocator());
        var stats = Stats{};
        try analyzeFileAstTier(probe.allocator(), .{ .issues = &issues, .stats = &stats }, "test.zig", src);
        try std.testing.expectEqual(@as(usize, 1), stats.parsed);
        try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    }
    const total_allocs = probe.allocations;
    // Every induced allocation failure must leave `parsed` at zero: a
    // file counts parsed only when its analysis completes.
    var fail_index: usize = 0;
    while (fail_index < total_allocs) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var issues: std.ArrayListUnmanaged(Issue) = .empty;
        defer types.deinitIssues(&issues, failing.allocator());
        var stats = Stats{};
        const err = analyzeFileAstTier(
            failing.allocator(),
            .{ .issues = &issues, .stats = &stats },
            "test.zig",
            src,
        ) catch |e| e;
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqual(@as(usize, 0), stats.parsed);
    }
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

test "exceedsNestingBudget: await does not count (no 0.16 keyword, EPH-I0591)" {
    // `await` is a plain identifier in 0.15/0.16 (async removed in 0.15,
    // verified absent from the 0.16.0 stdlib). A keyword entry for it
    // would count a non-production. If a future Zig version restores
    // await as a right-recursive prefix, this pin fails and the table
    // must be re-audited. (Paren-free: parens count in depth, not run.)
    try std.testing.expect(!exceedsNestingBudget("await await await x", 0));
}

test "exceedsNestingBudget: suspend statements do not count (EPH-I0591)" {
    // `suspend` parses KEYWORD_suspend BlockExprStatement — the
    // defer/errdefer class: one frame per keyword, `;` resets, and the
    // statements cannot chain. Counting it would only over-count.
    try std.testing.expect(!exceedsNestingBudget("suspend x; suspend x; suspend x;", 0));
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
