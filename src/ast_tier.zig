// Rhyos Labs - Ephor
// AST tier: checks that need a real parse tree (host std.Ast).
// Copyright (C) 2025 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

//! The line tier is fast but grammar-blind. This tier parses each file
//! with the host std.Ast (the grammar always matches the toolchain) and
//! runs rules that are impossible line-based. It is strictly additive.
//!
//! Degradation guarantee: a parse error makes the tree partial and
//! `AstContext.ok` false — AST rules skip the file and the line tier
//! still covers it. Deep delimiter/prefix nesting skips before the parse
//! runs (EPH-I0191). A refused thread skips too (EPH-I0597).
//!
//! ZA111 (returned-stack-reference) lives in ast_tier_za111.zig, split
//! out so each half stays under the 256 KiB AST-tier input cap
//! (EPH-I0601; raised from 64 KiB by EPH-I1300). This file owns the
//! parse, the nesting pre-scan, and the per-file pipeline. EPH-I0046
//! extension tests live in ast_tier_za111_tests.zig and the I1297
//! tier-pipeline battery in ast_tier_pipeline_tests.zig for the same
//! cap.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const types = @import("types.zig");
const za111 = @import("ast_tier_za111.zig");
const za111_tests = @import("ast_tier_za111_tests.zig");
const pipeline_tests = @import("ast_tier_pipeline_tests.zig");

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
    /// the worst case by construction. The caller joins the worker, so
    /// no concurrent allocator access. Direct use on input above
    /// `max_ast_file_bytes` reopens the crash class: production callers
    /// must go through `analyzeFileAstTier`. A refused worker surfaces
    /// as `error.ThreadSpawnFailed` and counts as a skip (EPH-I0597).
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
    /// Files degraded to line-tier coverage: the sum of the four class
    /// counters. The classes make a skip diagnosable without
    /// instrumentation (EPH-I1297, REL-P1-VERIFY-3).
    skipped: usize = 0,
    /// Degraded because the file exceeds `max_ast_file_bytes`.
    skipped_cap: usize = 0,
    /// Degraded because the nesting pre-scan crossed the budget.
    skipped_nesting: usize = 0,
    /// Degraded because the host parser reported errors (ZA503).
    skipped_parse: usize = 0,
    /// Degraded because the parse worker thread refused to spawn.
    skipped_spawn: usize = 0,
};

/// The four AST-tier skip classes (EPH-I1297): one counter per class
/// makes a degraded file diagnosable without instrumentation.
const SkipClass = enum { cap, nesting, parse, spawn };

/// Count one skip in the total and in its class. The pairing lives here
/// so the sum invariant (skipped == the four classes) holds by
/// construction (EPH-I1297).
fn countSkip(stats: ?*Stats, class: SkipClass) void {
    const s = stats orelse return;
    s.skipped += 1;
    switch (class) {
        .cap => s.skipped_cap += 1,
        .nesting => s.skipped_nesting += 1,
        .parse => s.skipped_parse += 1,
        .spawn => s.skipped_spawn += 1,
    }
}

/// Stack for the parse worker thread (EPH-I0191, EPH-I0268, EPH-I1300).
/// The byte cap bounds the input. Both paren forms share the ten-frame-
/// per-level density: the expr-paren cycle is the chain documented
/// above with the nesting budget (:231-240), and the grouped-type
/// cycle is the same ten frames offset by the type entry
/// (parseTypeExpr → ... → parseCurlySuffixExpr → parseTypeExpr in the
/// pinned Parse.zig). A file of N bytes can drive at most N/2 nesting
/// levels, so the worst case is 5 × N frames for either chain and the
/// pair budgets 1,638 B per frame
/// (2 GiB / (5 × 262,144)). Both chains fit 2 GiB at the worst legal
/// nesting: the 131,072-level grouped-type probe parses this stack in
/// both build modes (PROBE_OK), and the expr-paren bisection tops out
/// at 1.47 GiB in Debug. Per-frame (the ten-frame convention):
/// ReleaseSafe 297.6-314.6 B, Debug 1,206.4-1,216.3 B — the Debug
/// margin is 1.35×, not the 3.28× the earlier 200-500 B range implied.
/// Attribution-free per level: the budget is 16,384 B per level against
/// a Debug-measured ~12.1 KB per level. The pair re-derives together: a
/// cap raise without the stack raise reopens the SIGSEGV class, and a
/// config-driven cap with no safety ceiling is the same defect. The OS
/// commits stack pages lazily, so resident cost tracks real use; the
/// caller joins before the next spawn, so the reservation is transient.
/// The 2 GiB reservation assumes a 64-bit target.
const parse_stack_bytes: usize = 2 * 1024 * 1024 * 1024;

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
    /// degrades to line-tier coverage.
    spawn_refused,
    /// The worker ran and failed (allocation).
    err: anyerror,
};

/// Creates the parse worker thread. Split out so tests inject a
/// refusing spawner (EPH-I0597).
///
/// Worker-thread contract (F10, EPH-I0697): the worker must never call
/// compat helpers. compat.cached_tables is a plain unsynchronized lazy
/// global, and its race-freedom rests on compat being reachable from
/// the main thread only (the thread-safety comment in compat.zig names
/// the same invariant). The join-then-resume shape makes the worker
/// the only concurrent code: keep it allocator- and Ast-only.
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
            countSkip(stats, .spawn);
            return null;
        },
        .err => |err| err,
    };
}

/// Sink for one file's AST-tier analysis: issues plus optional counters.
/// `parse_issues` (optional) receives one ZA503 warning per file the
/// parser rejects (EPH-I0742. Helpers live in types.zig).
pub const AstTierOut = struct {
    issues: *std.ArrayListUnmanaged(Issue),
    stats: ?*Stats = null,
    parse_issues: ?*std.ArrayListUnmanaged(Issue) = null,
};

// ============================================================================
// Nesting budget (EPH-I0191)
// ============================================================================

/// Parse-recursion budget for the AST tier. The host parser recurses ten
/// frames per nesting level (verified in zig 0.16.0 Parse.zig: parseExpr →
/// parseExprPrecedence → parsePrefixExpr → parsePrimaryExpr →
/// parseCurlySuffixExpr → parseTypeExpr → parseErrorUnionExpr →
/// parseSuffixExpr → parsePrimaryTypeExpr → expectExpr). At that rate
/// 20-50k nested parens exhaust the 8 MB default stack and SIGSEGV with
/// no output. Prefix operators recurse two to five frames each, so the
/// pre-scan budgets them with the same constant. Real code nests tens
/// of levels, so 512 keeps a wide margin.
pub const max_nesting_depth: usize = 512;

/// AST-tier input byte cap (EPH-I0268, EPH-I1300). Parser stack need
/// grows with input size, so this cap plus `parse_stack_bytes` bounds
/// the worst case by construction. This bound is the tier's own: the
/// config key `max_file_bytes` (the ZA702 threshold) does not widen it,
/// which silently dropped ZA111 coverage on 34 zig-pulse files in
/// 0.15.0 (EPH-I1297, REL-P1-VERIFY-3). EPH-I1300 re-derived the pair:
/// the cap quadruples from 64 KiB to 256 KiB and `parse_stack_bytes`
/// quadruples with it, holding the identical per-frame budget at the
/// verified ten-frames-per-byte-pair density. The 256 KiB cap
/// re-admits the 0.15.x-skipped files (window_driver 228 KB,
/// peer_manager 143 KB, and 78 corpus files across the four gate
/// corpora). Over-cap files degrade to line-tier coverage like parse
/// errors.
pub const max_ast_file_bytes: usize = 256 * 1024;

/// Carried state for the pre-scan: the live-frame counters, the
/// `anyframe->` arrow watch, and the fn-type paren watch (EPH-I0598).
const NestingScan = struct {
    depth: usize = 0,
    run: usize = 0,
    /// A bare `anyframe` operand parks the run until its `->` decides.
    arrow_run: ?usize = null,
    /// A `fn` waits for its `(`: the type form's paren may sit on a
    /// later line, so the next non-blank code char decides (EPH-I0598).
    pending_fn: bool = false,
};

/// True when `source` would push the recursive host parser past `budget`.
/// One iterative pass with no allocation keeps two counters: delimiter
/// nesting and sequential right-recursion runs. The run increments on
/// `! - ~ & ? *`, `-%`, `[`, `anyframe->`, and the right-recursive
/// keywords (grammar-audit table below). It resets only at statement
/// boundaries (`;`, `,`, a bare `=`), where the frames of a prefix chain
/// provably return. Two-char `=` tokens are not boundaries (EPH-I0269):
/// the while-continue shape keeps its while frame live across the `+=`,
/// and a reset there under-counts live frames. It never resets on
/// whitespace, identifiers, or delimiters: prefix frames stay live
/// across the operand. Over-counting is deliberate and fail-safe.
/// Infix `- & *` chains, deep index chains, and keyword-dense statements
/// can force a skip (line-tier coverage only). An under-count defeats
/// only this gate; the byte cap and the parse stack absorb it
/// (EPH-I0268). Operators inside strings, chars, `\\` bodies, and `//`
/// comments are data and do not count.
///
/// Grammar-audit table (zig 0.16.0 Parse.zig, EPH-I0268). Every
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
///                                      (async removed in 0.15, verified
///                                      absent from the 0.16.0 stdlib —
///                                      EPH-I0591)
///   suspend payloads                   statement prefix  not counted
///                                      (BlockExprStatement — one frame
///                                      per keyword, `;` resets, the
///                                      defer/errdefer class)
///   if/while/for bodies                right-recursive   run
///   fn-type chains `fn() fn() void`    right-recursive   run (fn + `(`,
///                                      the paren may sit on a later
///                                      line — EPH-I0598)
///   binary ops and/or/orelse/catch     left-assoc loop   not counted
///   switch prongs                      iterative list    not counted
///   defer/errdefer payloads            block statements  not counted
///   fn declarations `fn name(`         container loop    not counted
///   statement boundary `;` `,` or a    frames return     resets run
///   bare `=` (two-char `=` tokens      (EPH-I0269)
///   are not boundaries: the while-
///   continue shape keeps its frame
///   live across `+=`)
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

/// Resolve a `fn` split from its `(` across a line break (EPH-I0598):
/// a `(` counts the type form, any other non-blank char is the
/// declaration form, and blank chars keep the watch alive.
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
    if (scanArrowWatchChar(c, scan)) return;
    switch (c) {
        '(', '{' => scan.depth += 1,
        ')', ']', '}' => scan.depth -|= 1,
        ' ', '\t', '\r' => {},
        else => scanOtherChar(line, i, scan, c),
    }
}

/// The anyframe arrow watch (EPH-I0599): true while `c` stays inside
/// the watch. A break restores the parked frames and returns false so
/// the char still counts.
fn scanArrowWatchChar(c: u8, scan: *NestingScan) bool {
    const saved = scan.arrow_run orelse return false;
    if (c == '>') {
        scan.run = saved + 1;
        scan.arrow_run = null;
        return true;
    }
    // Whitespace and the arrow's `-` keep the watch alive.
    if (c == '-' or c == ' ' or c == '\t' or c == '\r') return true;
    scan.arrow_run = null;
    // Frames parked before the bare `anyframe` operand stay live after
    // the operand completes: restore them (EPH-I0599).
    scan.run = saved;
    return false;
}

/// The run-incrementing chars: `[`, the unary markers, and `-` (with
/// its `-%` wrapping form). Any other char routes to the word scan.
fn scanOtherChar(line: []const u8, i: *usize, scan: *NestingScan, c: u8) void {
    switch (c) {
        '[' => {
            scan.depth += 1;
            // Sequential slice/array types (`[][]u8`) recurse per level
            // with brackets balancing within one level, invisible to
            // depth alone (audit table row 2). Over-counting skips. An
            // Under-count is absorbed by the cap and parse stack
            // (EPH-I0268).
            scan.run += 1;
        },
        '!', '~', '&', '?', '*' => scan.run += 1,
        '-' => {
            // `-%` is one wrapping-negation token.
            scan.run += 1;
            if (i.* + 1 < line.len and line[i.* + 1] == '%') i.* += 1;
        },
        else => scanWordOrReset(line, i, scan),
    }
}

/// Identifiers keep the run: error-union chains interleave operands
/// with `!`, and infix `- & *` sequences over-count toward a safe skip.
/// Only statement boundaries (`;`, `,`, a bare `=`) reset — other
/// non-word chars can sit inside an operand with live parent frames
/// (hole A). Two-char `=` tokens keep the run (EPH-I0269).
/// Right-recursive keywords increment. `anyframe` arms the arrow watch.
fn scanWordOrReset(line: []const u8, i: *usize, scan: *NestingScan) void {
    if (!types.isIdent(line[i.*])) {
        if (isRunBoundary(line, i.*)) scan.run = 0;
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

/// True when the char at `i` ends the prefix chain: `;`, `,`, or a bare
/// `=`. Two-char `=` tokens are not boundaries (EPH-I0269): the
/// while-continue shape `while (c) : (i += 1)` keeps its while frame
/// live across the `+=` (an early reset under-counts the frames).
fn isRunBoundary(line: []const u8, i: usize) bool {
    const c = line[i];
    if (c == ';' or c == ',') return true;
    if (c != '=') return false;
    return !isEqPartOfTwoCharToken(line, i);
}

/// True when the `=` at `i` belongs to a two-char token: a compound
/// assignment (`+=`), a comparison (`==`), or the switch-prong arrow
/// `=>`. The token's other half sits immediately before the `=` (after
/// it, for `==` and `=>`), so the neighbor byte marks it (EPH-I0269).
fn isEqPartOfTwoCharToken(line: []const u8, i: usize) bool {
    const compound_prev = "+-*/%&|^!<>==";
    const compound_next = "=>";
    if (i > 0 and mem.indexOfScalar(u8, compound_prev, line[i - 1]) != null) return true;
    if (i + 1 < line.len and mem.indexOfScalar(u8, compound_next, line[i + 1]) != null) return true;
    return false;
}

/// True when the next non-space char after `i` is `(`: the fn-type form.
fn nextNonSpaceIsParen(line: []const u8, i: usize) bool {
    var j = i + 1;
    while (j < line.len and (line[j] == ' ' or line[j] == '\t' or line[j] == '\r')) j += 1;
    return j < line.len and line[j] == '(';
}

/// Keywords whose productions recurse into the following expression or
/// type without a delimiter (grammar-audit table, EPH-I0268). `fn` is
/// handled apart: only its type form recurses. `await` is absent (async
/// removed in 0.15; the 0.16.0 stdlib has no await keyword, EPH-I0591).
/// `suspend` is statement-level — the defer/errdefer class.
fn isRightRecursiveKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{
        "try",    "comptime", "nosuspend", "resume", "break",
        "return", "if",       "while",     "for",
    };
    return for (keywords) |kw| {
        if (mem.eql(u8, word, kw)) break true;
    } else false;
}

/// Run every AST-tier rule over one file. The four skip classes — cap,
/// nesting, parse errors, spawn refusal — are counted separately so a
/// skip is diagnosable (EPH-I1297). The line tier still covers skipped
/// files. Allocation errors propagate (EPH-I0597).
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
        countSkip(out.stats, .cap);
        return;
    }
    // Deep delimiter or operator nesting SIGSEGVs the recursive host
    // parser mid-run (EPH-I0191). Degrade to line-tier coverage like
    // parse errors.
    if (exceedsNestingBudget(content, max_nesting_depth)) {
        countSkip(out.stats, .nesting);
        return;
    }
    const outcome = runGuardedParse(a, content, spawnParseWorker);
    var parsed = try resolveParseOutcome(outcome, out.stats) orelse return;
    defer parsed.deinit(a);
    if (!parsed.ok) {
        countSkip(out.stats, .parse);
        try types.noteParseError(out.parse_issues, a, path, &parsed.tree);
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

// The suite-join shim is an include, not a test: its body calls nothing
// by design (EPH-I0601). ZT106 names test blocks whose body carries no
// call site, so the shim carries the same directive the main.zig shim
// carries (EPH-I1152).
// ephor:ignore ZT106
test {
    // Test-reference idiom: the ast_tier_za111 split's tests must join
    // the suite (EPH-I0601). Body-only references do not force analysis
    // of test declarations. The za111_tests half joins the same way
    // (EPH-I0046).
    _ = za111;
    _ = za111_tests;
    _ = pipeline_tests;
}

pub fn runZa111(a: Allocator, content: []const u8) !std.ArrayListUnmanaged(Issue) {
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    errdefer types.deinitIssues(&issues, a);
    try analyzeFileAstTier(a, .{ .issues = &issues }, "test.zig", content);
    return issues;
}

pub fn expectZa111(
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
    try std.testing.expectEqual(@as(usize, 1), stats.skipped_spawn);
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
    try std.testing.expect(@embedFile("ast_tier_za111_tests.zig").len <= max_ast_file_bytes);
    try std.testing.expect(@embedFile("ast_tier_za111_walk.zig").len <= max_ast_file_bytes);
    try std.testing.expect(@embedFile("ast_tier_pipeline_tests.zig").len <= max_ast_file_bytes);
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
    // self, not the caller-owned backing. The index form above is safe.
    // This form is stack UB the compiler also misses.
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

test "exceedsNestingBudget: !anyframe arrow-break restores the parked run (EPH-I0269)" {
    // The `!` prefix parks while a bare `anyframe` operand resolves, and
    // the non-arrow break restores the parked frames (EPH-I0599). The
    // `!anyframe` spelling is the pre-scan under-count shape the issue
    // names. `?anyframe` above pins the same restore via the `?` prefix.
    try std.testing.expect(exceedsNestingBudget("!anyframe.x*", 1));
    try std.testing.expect(!exceedsNestingBudget("!anyframe.x*", 2));
}

test "exceedsNestingBudget: two-char = tokens keep the run, bare = resets (EPH-I0269)" {
    // The while-continue shape keeps its while frame live across the
    // `+=`. Reading the compound token's `=` as a boundary reset the run
    // while the frames stayed on the parser stack (under-count). Nested
    // chains pin the fix: the run reaches 2 across `+=`, `==`, `>=`.
    const chained = "while (a) : (b += 1) while (c) : (d += 1) f();";
    try std.testing.expect(exceedsNestingBudget(chained, 1));
    try std.testing.expect(!exceedsNestingBudget(chained, 2));
    // Comparison forms carry the same live frame.
    try std.testing.expect(exceedsNestingBudget("if (a == b) if (c == d) f();", 1));
    try std.testing.expect(!exceedsNestingBudget("if (a == b) if (c == d) f();", 2));
    try std.testing.expect(exceedsNestingBudget("while (i >= 10) while (j >= 10) f();", 1));
    try std.testing.expect(!exceedsNestingBudget("while (i >= 10) while (j >= 10) f();", 2));
    // The switch-prong arrow `=>` never resets a live outer chain.
    try std.testing.expect(exceedsNestingBudget("if (a) switch (x) { 1 => try f() };", 1));
    try std.testing.expect(!exceedsNestingBudget("if (a) switch (x) { 1 => try f() };", 2));
    // A bare assignment still resets: each `!` run ends at the `=`.
    try std.testing.expect(!exceedsNestingBudget("!!!!x = !!!!y;", 4));
}

/// Valid Zig with `n` nested grouped expressions: `const x = (((1)));`.
/// One exactly-sized allocation (head + 2n + 2) filled in place — the
/// `**` repeat needs a comptime factor (EPH-I1232). The caller frees.
fn buildNestedParens(a: Allocator, n: usize) ![]u8 {
    const head = "const x = ";
    const buf = try a.alloc(u8, head.len + 2 * n + 2);
    errdefer a.free(buf);
    @memcpy(buf[0..head.len], head);
    @memset(buf[head.len .. head.len + n], '(');
    buf[head.len + n] = '1';
    @memset(buf[head.len + n + 1 .. head.len + 2 * n + 1], ')');
    buf[head.len + 2 * n + 1] = ';';
    return buf;
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
        try analyzeFileAstTier(
            probe.allocator(),
            .{ .issues = &issues, .stats = &stats },
            "test.zig",
            src,
        );
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

test "EPH-I0191: over-budget nesting skips with the nesting class" {
    const a = std.testing.allocator;
    const src = try buildNestedParens(a, max_nesting_depth + 1);
    defer a.free(src);
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    defer types.deinitIssues(&issues, a);
    var stats = Stats{};
    try analyzeFileAstTier(a, .{ .issues = &issues, .stats = &stats }, "run.zig", src);
    try std.testing.expectEqual(@as(usize, 0), stats.parsed);
    try std.testing.expectEqual(@as(usize, 1), stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), stats.skipped_nesting);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped_cap);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped_parse);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped_spawn);
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
    const split_arrow = "const x: anyframe\n->anyframe\n->u8 = undefined;";
    try std.testing.expect(exceedsNestingBudget(split_arrow, 1));
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

/// Valid Zig padded with comment bytes to exactly `total` bytes. Pub so
/// the split-out test batteries reuse it without a duplicated block
/// (ZA504, EPH-I1297).
pub fn buildPaddedSource(a: Allocator, total: usize) ![]u8 {
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

test "EPH-I1300: a >64 KiB file parses again (REL-P2-VERIFY-3)" {
    // The 0.15.x cap skipped every file past 64 KiB (EPH-I1297). The
    // re-derived 256 KiB cap re-admits them: a 200 KiB valid file
    // parses with no skip class.
    const a = std.testing.allocator;
    const src = try buildPaddedSource(a, 200 * 1024);
    defer a.free(src);
    try expectTierCounters(src, 1, 0);
}

test "EPH-I1300: the cap-sized nesting worst case parses on the worker" {
    // 131,072 nesting levels hold the cap's full byte-pair budget (2n
    // delimiter bytes). The worker's 2 GiB stack must hold them: at
    // the verified ten frames per level this is the cap's worst case
    // by construction (EPH-I0191), and without the worker thread it
    // SIGSEGVs any default thread stack. Do not run it against a
    // pre-thread build: the crash kills the test runner.
    const a = std.testing.allocator;
    const src = try buildNestedParens(a, 131_072);
    defer a.free(src);
    try std.testing.expect(src.len >= max_ast_file_bytes);
    var actx = try AstContext.init(a, src);
    defer actx.deinit(a);
    try std.testing.expect(actx.ok);
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
