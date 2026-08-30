// Rhyos Labs - Ephor
// Shared types for all analyzer modules
// Copyright (C) 2025 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const sanitize = @import("sanitize.zig");

// ============================================================================
// Rule IDs (for suppression and documentation)
// ============================================================================

// ZA1xx - Memory
pub const RULE_ALLOC_NO_DEFER = "ZA101";
pub const RULE_CREATE_NO_DEFER = "ZA102";
pub const RULE_ALLOC_NO_ERRDEFER = "ZA103";
// ZA104 (memory leak) is RETIRED — removed in 0.11.0 when the non-CFG
// memory analysis path was deleted. Never reuse the ID: consumer
// inline-ignores reference it.
pub const RULE_USE_AFTER_FREE = "ZA105";
pub const RULE_DOUBLE_FREE = "ZA106";
// ZA107-ZA109: never issued. The numbering skipped straight to ZA110;
// no rule ever carried these IDs (verified against git history).
pub const RULE_MUST_RETURN_REF = "ZA110";
pub const RULE_RETURNED_STACK_REF = "ZA111";

// ZA2xx - Error handling patterns (warnings; ZA205/ZA208/ZA209/ZA210 are notes)
pub const RULE_SILENT_CATCH = "ZA201";
pub const RULE_CATCH_UNREACHABLE = "ZA202";
pub const RULE_ORELSE_UNREACHABLE = "ZA203";
pub const RULE_UNDEFINED_USAGE = "ZA204";
pub const RULE_IGNORED_ERROR = "ZA205";
pub const RULE_EXIT_BYPASSES_DEFER = "ZA206";
pub const RULE_CATCH_UNDEFINED = "ZA207";
pub const RULE_PANIC = "ZA208";
pub const RULE_USELESS_ERROR_RETURN = "ZA209";
pub const RULE_NO_CATCH_RETURN = "ZA210";

// ZA3xx - Complexity
pub const RULE_FUNC_TOO_LONG = "ZA301";
pub const RULE_NESTING_TOO_DEEP = "ZA302";
pub const RULE_TOO_MANY_PARAMS = "ZA303";
pub const RULE_TOO_MANY_BRANCHES = "ZA304";
pub const RULE_CYCLOMATIC = "ZA305";
pub const RULE_COGNITIVE = "ZA306";

// ZA4xx - Unused
pub const RULE_UNUSED_IMPORT = "ZA401";
pub const RULE_UNUSED_CONST = "ZA402";
pub const RULE_UNUSED_VAR = "ZA403";
// ZA404 is reserved for the unused-non-exported-fn rule (EPH-I1084, B135).
pub const RULE_UNUSED_PARAM = "ZA405";

// ZA5xx - Structure
pub const RULE_ORPHAN_FILE = "ZA501";
pub const RULE_FILE_TOO_LARGE = "ZA502";
// ZA503 (parse-error) carries no registry constant: it lives with the
// AST-tier helpers (EPH-I0742, see the ZA503 section below).
pub const RULE_DUPLICATED_BLOCK = "ZA504";
pub const RULE_PASSTHROUGH_WRAPPER = "ZA505";
pub const RULE_BOOL_FLAG_PARAM = "ZA506";

// ZA6xx - Formatting (ZA607 is a semantic definite-assignment check that kept
// its ZA6xx ID for backward compatibility with existing inline-ignores)
pub const RULE_NEEDS_FORMAT = "ZA601";
// ZA602-ZA606: never issued. The band jumps straight to ZA607, whose
// out-of-band ID is deliberate (see above).
pub const RULE_DEFINITE_ASSIGNMENT = "ZA607";

// ZA7xx - Style
pub const RULE_LINE_TOO_LONG = "ZA701";
pub const RULE_FILE_TOO_LONG = "ZA702";
pub const RULE_NAMING_CONVENTION = "ZA703";
// ZA704 (std.debug.print) is RETIRED — removed in 0.14.0 as intent-based
// (EPH-I0049). Never reuse the ID: consumer inline-ignores reference it.

// ZA8xx - Null Safety
pub const RULE_OPTIONAL_UNWRAP_UNSAFE = "ZA801";
pub const RULE_ORELSE_QUESTION_UNSAFE = "ZA802";

// ZA9xx - Panic/Overflow Detection
pub const RULE_DECREMENT_WITHOUT_CHECK = "ZA901";
// ZA902 is RETIRED — removed with the dead legacy line-based panic
// analyzer cluster (EPH-I0015, EPH-I0041): its only emitter never
// emitted. Never reuse the ID: consumer inline-ignores reference it.
pub const RULE_INDEX_ARITHMETIC = "ZA903";
pub const RULE_INTCAST_NO_BOUNDS = "ZA904";

// ZR1xx - Runtime Analysis (dynamic analysis via test execution)
pub const RULE_RUNTIME_MEMORY_LEAK = "ZR101";
pub const RULE_RUNTIME_DOUBLE_FREE = "ZR102";
pub const RULE_RUNTIME_USE_AFTER_FREE = "ZR103";
pub const RULE_RUNTIME_TEST_FAILURE = "ZR104";
pub const RULE_RUNTIME_PANIC = "ZR105";
pub const RULE_RUNTIME_SIGNAL_DEATH = "ZR106";

// ZT1xx - Tests
pub const RULE_TEST_LIE = "ZT101";
pub const RULE_TEST_NO_ASSERTIONS = "ZT102";
pub const RULE_TEST_TRIVIAL_ASSERT = "ZT103";
pub const RULE_TEST_SWALLOWED_ERROR = "ZT104";
pub const RULE_TEST_UNTESTED_PUBLIC_FN = "ZT105";
pub const RULE_TEST_NO_CALLS = "ZT106";

// ZC1xx - Concurrency
pub const RULE_LOCK_NO_DEFER_UNLOCK = "ZC101";
pub const RULE_DOUBLE_LOCK = "ZC102";
pub const RULE_UNLOCK_WITHOUT_LOCK = "ZC103";
pub const RULE_THREAD_NO_JOIN = "ZC104";

// ============================================================================
// Return Type Classification (for type-based detection)
// ============================================================================

pub const ReturnKind = enum {
    void_type, // void — safe to discard
    error_union, // !void, !T — NOT safe (ZA205)
    value, // u32, []u8 — safe to discard
    optional, // ?T — safe to discard
    noreturn_type, // noreturn — safe
    unknown, // can't determine — fall through to legacy
};

// ============================================================================
// Severity Levels
// ============================================================================

pub const Severity = enum {
    err, // error - should fail CI
    warning, // warning - should be fixed
    note, // note - informational

    pub fn str(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .note => "note",
        };
    }
};

// ============================================================================
// Output Formats
// ============================================================================

pub const OutputFormat = enum {
    text, // Standard GCC-style: path:line:col: severity[rule]: message
    json, // JSON array for IDE integration
};

// ============================================================================
// Strict CI Gating
// ============================================================================

/// Severity level at which findings fail the run (exit 1).
/// --strict is exactly .warning; .never keeps findings informational.
pub const FailOn = enum {
    never, // findings never fail the run (default)
    err, // fail only on error-severity findings
    warning, // fail on warnings + errors (== --strict)
    note, // fail on any finding, notes included

    pub fn str(self: FailOn) []const u8 {
        return switch (self) {
            .never => "never",
            .err => "error",
            .warning => "warning",
            .note => "note",
        };
    }

    /// Accepted spellings are the str() forms: never, error, warning,
    /// note (lowercase, exact). "err" and "warn" are rejected on purpose:
    /// the CI gate fails closed on a misspelled level (EPH-I0024), so the
    /// accepted set stays minimal and the runtime diagnostics name it
    /// verbatim (EPH-I0587).
    pub fn fromString(s: []const u8) ?FailOn {
        if (std.mem.eql(u8, s, "never")) return .never;
        if (std.mem.eql(u8, s, "error")) return .err;
        if (std.mem.eql(u8, s, "warning")) return .warning;
        if (std.mem.eql(u8, s, "note")) return .note;
        return null;
    }
};

// ============================================================================
// Error Naming Convention (ZA703)
// ============================================================================

/// Which convention ZA703 enforces for error-set member declarations.
/// Use sites of an error value never fire (EPH-I1075). The stdlib and
/// virtually all community code use TitleCase error names, so that is the
/// default; snake_case preserves the pre-flip ZA703 behavior for projects
/// that adopted it.
pub const ErrorNaming = enum {
    title_case, // error{ FileNotFound } (default, community standard)
    snake_case, // error{ file_not_found } (pre-flip ZA703 default)

    pub fn str(self: ErrorNaming) []const u8 {
        return switch (self) {
            .title_case => "TitleCase",
            .snake_case => "snake_case",
        };
    }

    /// "PascalCase" is accepted as an alias for TitleCase (common spelling).
    /// Accepted spellings: TitleCase, PascalCase, snake_case. "title_case"
    /// (the enum-tag spelling) is rejected: the accepted set is the str()
    /// forms plus the PascalCase alias (EPH-I0587).
    pub fn fromString(s: []const u8) ?ErrorNaming {
        if (std.mem.eql(u8, s, "TitleCase")) return .title_case;
        if (std.mem.eql(u8, s, "PascalCase")) return .title_case;
        if (std.mem.eql(u8, s, "snake_case")) return .snake_case;
        return null;
    }
};

// ============================================================================
// Core Types
// ============================================================================

pub const ImportInfo = struct {
    path: []const u8,
    resolved: ?[]const u8,
    name: []const u8,
    line: usize,
    col: usize,
    is_pub: bool = false, // True for `pub const X = @import()` re-exports
};

pub const Issue = struct {
    file: []const u8,
    line: usize,
    col: usize,
    severity: Severity,
    rule: []const u8,
    message: []const u8,
    /// Always borrowed: never heap-owned by this issue, and deinit never
    /// frees it (EPH-I0583). Producers point it at comptime literals or
    /// at buffers whose lifetime exceeds the issue's.
    help: ?[]const u8,
    message_owned: bool = false,
    /// True when `file` is heap-owned by this issue and deinit must free
    /// it. A finding parsed from child-process output outlives that
    /// output, so the producer dupes the name and sets this (EPH-I0196).
    file_owned: bool = false,

    pub fn deinit(self: *Issue, allocator: Allocator) void {
        if (self.message_owned) {
            allocator.free(self.message);
            self.message_owned = false;
        }
        if (self.file_owned) {
            allocator.free(self.file);
            self.file_owned = false;
        }
    }

    /// Render the GCC-style text form into `out`. Every repo-derived field
    /// (file, message, help) passes through sanitizeTerminal so hostile
    /// bytes cannot forge terminal control sequences or extra log lines
    /// (EPH-I0147, EPH-I0149).
    pub fn formatText(self: Issue, base_path: []const u8, out: *OutBuf) !void {
        const rel_path = relativePath(self.file, base_path);
        var rel = try sanitizeTerminal(out.allocator, rel_path);
        defer rel.deinit(out.allocator);
        var msg = try sanitizeTerminal(out.allocator, self.message);
        defer msg.deinit(out.allocator);
        // Every finding renders the positioned form, file-level findings
        // included (`path:1:1:`) (EPH-I0739). The pre-fix drop branch
        // keyed on (line == 1, col == 1), which also de-positioned REAL
        // findings at 1:1 and left file-level findings invisible to the
        // documented VS Code problemMatcher regex.
        try out.print("{s}:{d}:{d}: {s}[{s}]: {s}\n", .{
            rel.slice,
            self.line,
            self.col,
            self.severity.str(),
            self.rule,
            msg.slice,
        });
        if (self.help) |h| {
            var help = try sanitizeTerminal(out.allocator, h);
            defer help.deinit(out.allocator);
            try out.print("  help: {s}\n", .{help.slice});
        }
    }

    /// Render the JSON object core through the closing brace. Every
    /// repo-derived field passes through escapeJson so quote, backslash,
    /// and control bytes in filenames or messages cannot break the
    /// document (EPH-I0146). The two public entry points differ only in
    /// the terminator (EPH-I1121): the last array element closes the
    /// object, every other element carries the array comma.
    fn formatJsonObject(self: Issue, base_path: []const u8, out: *OutBuf) !void {
        const rel_path = relativePath(self.file, base_path);
        var rel = try escapeJson(out.allocator, rel_path);
        defer rel.deinit(out.allocator);
        var msg = try escapeJson(out.allocator, self.message);
        defer msg.deinit(out.allocator);
        try out.print("  {{\n", .{});
        try out.print("    \"file\": \"{s}\",\n", .{rel.slice});
        try out.print("    \"line\": {d},\n", .{self.line});
        try out.print("    \"column\": {d},\n", .{self.col});
        try out.print("    \"severity\": \"{s}\",\n", .{self.severity.str()});
        try out.print("    \"rule\": \"{s}\",\n", .{self.rule});
        try out.print("    \"message\": \"{s}\"", .{msg.slice});
        if (self.help) |h| {
            var help = try escapeJson(out.allocator, h);
            defer help.deinit(out.allocator);
            try out.print(",\n    \"help\": \"{s}\"\n", .{help.slice});
        } else {
            try out.print("\n", .{});
        }
        try out.print("  }}", .{});
    }

    /// Render the JSON object for the last array element: no trailing
    /// comma, so the array close follows it directly.
    pub fn formatJsonLast(self: Issue, base_path: []const u8, out: *OutBuf) !void {
        try self.formatJsonObject(base_path, out);
        try out.print("\n", .{});
    }

    /// Render the JSON object for a non-last array element: the trailing
    /// comma separates it from the next object.
    pub fn formatJsonEntry(self: Issue, base_path: []const u8, out: *OutBuf) !void {
        try self.formatJsonObject(base_path, out);
        try out.print(",\n", .{});
    }

    /// Print the text form to stderr. Buffers through formatText so each
    /// finding lands in one write. The writer seam (EPH-I0687):
    /// tests pass a capture writer, which keeps hostile fixture bytes off
    /// the green-run log (the EPH-I0288 noise class) and lets the test
    /// assert the printed bytes directly. Production passes null for the
    /// raw stderr path, byte-identical with the pre-seam output.
    pub fn printText(
        self: Issue,
        allocator: Allocator,
        base_path: []const u8,
        writer: ?*std.Io.Writer,
    ) void {
        var out = OutBuf{ .allocator = allocator };
        defer out.deinit();
        self.formatText(base_path, &out) catch {
            // OOM mid-format: emit a bare notice rather than drop the
            // finding silently.
            printWriteFallback("ephor: out of memory printing {s} finding\n", .{self.rule}, writer);
            return;
        };
        printWriteFallback("{s}", .{out.buf.items}, writer);
    }
};

/// Write through the writer seam (EPH-I0687): the capture
/// writer when one is supplied, raw stderr otherwise (the production
/// default, byte-identical with std.debug.print). A full capture buffer
/// fails the write and the caller's content assertion, so the WriteFailed
/// swallow is a truncation policy, not a silent error path.
fn printWriteFallback(comptime fmt: []const u8, args: anytype, writer: ?*std.Io.Writer) void {
    if (writer) |w| {
        w.print(fmt, args) catch |err| switch (err) {
            error.WriteFailed => {},
        };
    } else {
        std.debug.print(fmt, args);
    }
}

// ============================================================================
// Output Sanitization (RED5: EPH-I0146, I0147, I0148, I0149, I0162)
// ============================================================================
// The sanitizers moved to sanitize.zig so each file stays under the
// 64 KiB ZA111 input cap (EPH-I1123). The re-exports keep the types.*
// API surface unchanged for main.zig and the compat layer. OutBuf stays
// here: the Issue format cores own its private print helper.

pub const Sanitized = sanitize.Sanitized;
pub const sanitizeTerminal = sanitize.sanitizeTerminal;
pub const escapeJson = sanitize.escapeJson;
pub const sanitizeMarkdown = sanitize.sanitizeMarkdown;
pub const sanitizeSnippet = sanitize.sanitizeSnippet;

// ============================================================================
// ZA503 parse-error finding (EPH-I0742)
// ============================================================================
// A file the host parser rejects is a real defect; before this finding
// the AST tier skipped it in silence, so a syntax-broken file exited 0
// under every strictness. One warning per file, at the first non-note
// parse error. The helpers live here, not in ast_tier.zig, so
// ast_tier.zig stays under its 64 KiB ZA111 input cap (the F12 pin).

/// Byte cap on a rendered parse-error message: renderError prints one
/// short line per error, so the cap is a bound, not a budget.
pub const parse_error_message_cap_bytes: usize = 200;

/// The first non-note parse error of `tree`. Note entries annotate a
/// primary error, so the primary is the finding's anchor. A tree whose
/// errors are all notes falls back to the first entry.
fn firstRealParseError(tree: *const std.zig.Ast) std.zig.Ast.Error {
    for (tree.errors) |e| {
        if (!e.is_note) return e;
    }
    return tree.errors[0];
}

/// One ZA503 warning for a file the host parser rejects. The message
/// is the rendered primary error, capped; the location is the error
/// token's 1-based line/col. `file` borrows the caller's path, the
/// same lifetime pattern as the ZA111 findings.
pub fn parseErrorIssue(a: Allocator, path: []const u8, tree: *const std.zig.Ast) !Issue {
    const err = firstRealParseError(tree);
    // The Allocating writer owns the render buffer; toArrayList hands
    // the bytes to a managed list whose toOwnedSlice transfers them to
    // the issue (no fallible call follows the transfer).
    var aw = std.Io.Writer.Allocating.init(a);
    defer aw.deinit();
    try tree.renderError(err, &aw.writer);
    var list = aw.toArrayList();
    defer list.deinit(a);
    if (list.items.len > parse_error_message_cap_bytes) {
        list.shrinkRetainingCapacity(parse_error_message_cap_bytes - 3);
        try list.appendSlice(a, "...");
    }
    const loc = tree.tokenLocation(0, err.token);
    return .{
        .file = path,
        .line = loc.line + 1,
        .col = loc.column + 1,
        .severity = .warning,
        .rule = "ZA503",
        .message = try list.toOwnedSlice(a),
        .message_owned = true,
        .help = "fix the syntax error; the AST tier skipped this file",
    };
}

/// Append one ZA503 warning to the parse sink when it exists.
pub fn noteParseError(
    sink: ?*std.ArrayListUnmanaged(Issue),
    a: Allocator,
    path: []const u8,
    tree: *const std.zig.Ast,
) !void {
    if (sink) |s| {
        try s.append(a, try parseErrorIssue(a, path, tree));
    }
}

/// Buffered byte sink for the issue format cores: pairs the output list
/// with its allocator so formatter signatures stay within the param cap.
pub const OutBuf = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    allocator: Allocator,

    fn print(self: *OutBuf, comptime fmt: []const u8, args: anytype) !void {
        try self.buf.print(self.allocator, fmt, args);
    }

    /// Release the buffered bytes.
    pub fn deinit(self: *OutBuf) void {
        self.buf.deinit(self.allocator);
    }
};
pub const Thresholds = struct {
    max_function_lines: usize = 50,
    max_nesting_depth: usize = 3,
    max_params: usize = 4,
    max_branches: usize = 12,
    max_line_length: usize = 100,
    max_file_bytes: usize = 50_000,
    max_cyclomatic: usize = 10, // McCabe-canonical default; unified complexity standard (EPH-I0992)
    max_cognitive: usize = 15,
};

pub const ProjectStats = struct {
    total_files: usize = 0,
    total_lines: usize = 0,
    code_lines: usize = 0,
    comment_lines: usize = 0,
    blank_lines: usize = 0,
    test_count: usize = 0,
    pub_fn_count: usize = 0,
    not_implemented_count: usize = 0,
    todo_count: usize = 0,
    files_with_tests: usize = 0,
    /// AST-tier coverage (EPH-I0200). Zero unless the caller merges the
    /// ast_tier.Stats counters in: getStats walks content only and cannot
    /// observe parse outcomes. The .check flow owns that merge. The stats
    /// command never runs the AST tier, so its JSON omits both members
    /// (EPH-I0588): printing them would report a constant zero that reads
    /// as a parse run the command never performed.
    ast_parsed: usize = 0,
    ast_skipped: usize = 0,
};

pub const FileAnalysis = struct {
    path: []const u8,
    /// Cached realpath of `path`, resolved once at ingest time.
    /// When realpath fails (e.g. file no longer exists), this falls back
    /// to `path`. Avoids per-lookup realpath calls in the import graph —
    /// re-resolving on every `findImportsForPath` call scaled O(N²) and
    /// blew up to millions of openat syscalls on large codebases.
    resolved_path: []const u8,
    imports: std.ArrayListUnmanaged(ImportInfo),
    content: []const u8,
    has_tests: bool,
    pub_function_count: usize,
    line_count: usize,
    /// True when the head carries a generated-file banner (EPH-I1062).
    /// ZA701 and ZA703 stay silent on generated files; every other
    /// analyzer keeps full coverage.
    is_generated: bool,

    pub fn deinit(self: *FileAnalysis, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.resolved_path.ptr != self.path.ptr) {
            allocator.free(self.resolved_path);
        }
        for (self.imports.items) |import| {
            allocator.free(import.path);
            if (import.resolved) |r| allocator.free(r);
            allocator.free(import.name);
        }
        self.imports.deinit(allocator);
        allocator.free(self.content);
    }
};

// ============================================================================
// Utility Functions
// ============================================================================

/// Properly deinit an issues array, freeing any owned messages and owned file bytes
pub fn deinitIssues(
    issues: *std.ArrayListUnmanaged(Issue),
    allocator: Allocator,
) void {
    for (issues.items) |*issue| {
        issue.deinit(allocator);
    }
    issues.deinit(allocator);
}

/// Path separator test accepting both '/' and the host separator, so
/// containment checks behave on Windows, where both forms appear.
/// Private: only isPathAncestorOrEqual calls it.
fn isPathSep(c: u8) bool {
    return c == '/' or c == std.fs.path.sep;
}

/// Component-boundary "ancestor or same" test on two paths. A raw
/// startsWith would accept "/repo-evil" for root "/repo" (RED4-3 shape);
/// the byte after the matched prefix must be a separator. The test strips
/// trailing separators from `ancestor` first, so both forms of a directory
/// name match. Moved from main.zig (EPH-I0176) so relativePath can guard
/// its strip without importing main.zig. The B89 serialized tail adopted
/// this copy in main.zig and deleted the private duplicate there.
pub fn isPathAncestorOrEqual(ancestor: []const u8, path: []const u8) bool {
    var root = ancestor;
    while (root.len > 1 and isPathSep(root[root.len - 1]))
        root = root[0 .. root.len - 1];
    if (mem.eql(u8, root, path)) return true;
    if (root.len == 0 or path.len <= root.len) return false;
    if (!mem.startsWith(u8, path, root)) return false;
    return isPathSep(path[root.len]) or isPathSep(root[root.len - 1]);
}

pub fn relativePath(path: []const u8, base: []const u8) []const u8 {
    // Strip base only on a component boundary (EPH-I0176): a raw prefix
    // strip mangles "/repo-evil/x.zig" for base "/repo" into
    // "-evil/x.zig". A path outside the base renders in full instead.
    if (isPathAncestorOrEqual(base, path)) {
        var result = path[base.len..];
        while (result.len > 0 and result[0] == '/') {
            result = result[1..];
        }
        return if (result.len > 0) result else path;
    }
    return path;
}

pub fn countOccurrences(h: []const u8, n: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i + n.len <= h.len) : (i += 1) {
        if (mem.eql(u8, h[i .. i + n.len], n)) count += 1;
    }
    return count;
}

/// Line count of `content`: one per newline, plus one for a final line
/// that no newline terminates. A trailing newline closes the last line
/// instead of opening a phantom empty one (EPH-I0724). Empty content has
/// zero lines (EPH-I0586).
pub fn countLines(content: []const u8) usize {
    if (content.len == 0) return 0;
    var count: usize = 0;
    for (content) |c| {
        if (c == '\n') count += 1;
    }
    if (content[content.len - 1] != '\n') count += 1;
    return count;
}

pub fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// True when `t[i]` and `t[i + 1]` are both `\`, opening a multiline string.
/// The opener swallows the rest of the line: every later byte is string
/// data, so no code, comment, or directive can follow it on the line
/// (EPH-I0671). Call in code context only. Escape runs exist inside `"..."`
/// and `'...'` literals, so a `\` pair in code always opens a multiline
/// string in valid Zig. A lone trailing `\` (invalid Zig) returns false.
pub fn isMultilineOpenerAt(t: []const u8, i: usize) bool {
    return i + 1 < t.len and t[i] == '\\' and t[i + 1] == '\\';
}

/// Scan mode for the string/char-literal classifiers. `mline` is sticky: a
/// `\\` multiline opener swallows the rest of its line, so no later byte on
/// the line can leave string data (EPH-I0671).
const QuoteMode = enum { none, str, char, mline };

/// Advance the quote scan past one char. A backslash inside a literal also
/// skips the escaped char, so `i` can move two steps.
fn stepQuoteMode(mode: *QuoteMode, line: []const u8, i: *usize) void {
    const c = line[i.*];
    switch (mode.*) {
        .char => stepInsideQuote(mode, c, '\'', i),
        .str => stepInsideQuote(mode, c, '"', i),
        .mline => {},
        .none => stepFromCode(mode, line, i, c),
    }
}

/// One step inside a literal: a backslash skips the escaped char, and the
/// mode's closing quote returns to code (EPH-I0104).
fn stepInsideQuote(mode: *QuoteMode, c: u8, closer: u8, i: *usize) void {
    if (c == '\\') {
        i.* += 1;
        return;
    }
    if (c == closer) mode.* = .none;
}

/// One step in code: a `\\` opener starts a multiline tail (EPH-I0671),
/// and a quote opens its literal.
fn stepFromCode(mode: *QuoteMode, line: []const u8, i: *usize, c: u8) void {
    if (isMultilineOpenerAt(line, i.*)) {
        mode.* = .mline;
        return;
    }
    if (c == '\'') {
        mode.* = .char;
        return;
    }
    if (c == '"') mode.* = .str;
}

/// Check if position `col` is inside a string literal. Escape handling: an
/// odd backslash run before a quote keeps the quote as character data, an
/// even run keeps it as a delimiter. Char literal spans (`'...'`, with `\'`
/// and `\\` escapes) never toggle string state: the `"` inside `'"'` stays
/// character data (EPH-I0104). A `\\` multiline opener in code position
/// makes the rest of the line string data, so positions past the opener
/// report inside-string (EPH-I0671).
pub fn isInsideString(line: []const u8, col: usize) bool {
    var mode: QuoteMode = .none;
    var i: usize = 0;
    while (i < col and i < line.len) : (i += 1) {
        stepQuoteMode(&mode, line, &i);
    }
    return mode == .str or mode == .mline;
}

/// Incremental per-line string/char-literal classifier (EPH-I0153).
/// isInsideString rescans from column 0 per query, so a rule that tests k
/// candidates on one line costs O(k * line): one 10 MB single-line file
/// with 50k needles costs ~2.5e11 byte-ops per rule. Hot rules (hasToken,
/// findCatchSite, the complexity counters) query many positions per line.
/// This classifier walks the line once: each query continues the scan from
/// the previous position, so any non-decreasing query sequence on one line
/// costs O(line) total. Queries MUST NOT move backwards. The assert keeps a
/// regressing caller loud in Debug and ReleaseSafe.
pub const LineClassifier = struct {
    line: []const u8,
    scanned: usize = 0,
    mode: QuoteMode = .none,

    pub fn init(line: []const u8) LineClassifier {
        return .{ .line = line };
    }

    /// True when column `col` sits inside a string literal. Matches
    /// isInsideString exactly: the escape skip, the EPH-I0104 char-literal
    /// spans where a `"` stays character data, and the EPH-I0671 `\\`
    /// opener whose tail is string data. `col` must be at or after the
    /// previously queried column.
    pub fn isInsideString(self: *LineClassifier, col: usize) bool {
        std.debug.assert(col >= self.scanned);
        while (self.scanned < col and self.scanned < self.line.len) : (self.scanned += 1) {
            stepQuoteMode(&self.mode, self.line, &self.scanned);
        }
        return self.mode == .str or self.mode == .mline;
    }

    /// True when column `col` sits inside any literal: a string, a char
    /// literal, or a `\\` multiline tail. The opening quote byte reports
    /// false — the walk stops at `col` before processing it — so callers
    /// that mask delimiters must keep their explicit quote-byte checks.
    /// The walk can overshoot `col` by one byte when an escape precedes
    /// it (stepQuoteMode skips the escaped char), so callers must never
    /// query the same column twice: the second query's ascending assert
    /// fires. `col` must be at or after the previously queried column.
    pub fn isInsideLiteral(self: *LineClassifier, col: usize) bool {
        std.debug.assert(col >= self.scanned);
        while (self.scanned < col and self.scanned < self.line.len) : (self.scanned += 1) {
            stepQuoteMode(&self.mode, self.line, &self.scanned);
        }
        return self.mode == .str or self.mode == .char or self.mode == .mline;
    }
};

/// State for masking string/char literals, `\\` multiline tails, and
/// comments while parsing a line
pub const LiteralState = struct {
    in_str: bool = false,
    in_chr: bool = false,
    in_mline: bool = false,
    in_comment: bool = false,

    /// Start masking for one line. Returns null when the line is a
    /// multiline-string body — after optional leading whitespace, `\\` makes
    /// the whole line string data, so no position on it is code (Zig has no
    /// block comments, so this is the only whole-line data form).
    pub fn forLine(line: []const u8) ?LiteralState {
        const t = mem.trimStart(u8, line, " \t");
        if (mem.startsWith(u8, t, "\\\\")) return null;
        return .{};
    }

    /// Returns the position to process as code, or null when the char is
    /// string/char-literal data or comment text (including the delimiters
    /// themselves).
    pub fn updateForChar(self: *LiteralState, t: []const u8, i: usize) ?usize {
        if (self.in_comment or self.in_mline) return null;
        const c = t[i];
        // `//` opens a comment only in code context — inside a string or char
        // literal it is data. A comment swallows the rest of the line.
        if (c == '/' and !self.in_str and !self.in_chr and
            i + 1 < t.len and t[i + 1] == '/')
        {
            self.in_comment = true;
            return null;
        }
        // A `\\` opener in code position makes the rest of the line string
        // data (EPH-I0671). The in_str/in_chr guards keep escape runs inside
        // literals (`'\\'`, `"\\"`) from matching as openers.
        if (!self.in_str and !self.in_chr and isMultilineOpenerAt(t, i)) {
            self.in_mline = true;
            return null;
        }
        if (c == '\'' and !self.in_str) {
            if (hasEvenBackslashRun(t, i)) self.in_chr = !self.in_chr;
            return null;
        }
        if (c == '"' and !self.in_chr) {
            if (hasEvenBackslashRun(t, i)) self.in_str = !self.in_str;
            return null;
        }
        return if (self.in_str or self.in_chr) null else i;
    }
};

/// True when the backslash run immediately before `t[i]` has even length, so
/// a quote at `i` is a delimiter. An odd run escapes the quote (the middle
/// quote in `'\''`), making it content — toggling on escaped content quotes
/// leaves the state stuck and swallows the rest of the line. An even run
/// (the closing quote in `'\\'`, `"\\"`) leaves the quote a delimiter.
fn hasEvenBackslashRun(t: []const u8, i: usize) bool {
    var backslashes: usize = 0;
    var j = i;
    while (j > 0 and t[j - 1] == '\\') : (j -= 1) backslashes += 1;
    return backslashes % 2 == 0;
}

/// Skip blank bytes (space, tab, CR, LF) from `start`, returning the
/// index of the first non-blank byte. The dead isInlineDisabled/
/// checkDisableComment pair that once sat here was deleted (EPH-I0581):
/// production suppression uses main.zig's scope-aware implementation.
pub fn skipWhitespace(
    content: []const u8,
    start: usize,
) usize {
    var i = start;
    while (i < content.len) : (i += 1) {
        const c = content[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
        break;
    }
    return i;
}

// ============================================================================
// Tests
// ============================================================================

test "relativePath removes base" {
    const result = relativePath("/foo/bar/baz.zig", "/foo/bar");
    try std.testing.expectEqualStrings("baz.zig", result);
}

test "relativePath strips base only on a component boundary (EPH-I0176)" {
    // A raw prefix strip would mangle "/repo-evil/x.zig" for base
    // "/repo" into "-evil/x.zig"; the guarded form renders the full
    // path instead.
    try std.testing.expectEqualStrings(
        "/repo-evil/x.zig",
        relativePath("/repo-evil/x.zig", "/repo"),
    );
    try std.testing.expectEqualStrings("sub/file.zig", relativePath("/repo/sub/file.zig", "/repo"));
    try std.testing.expectEqualStrings("/repo", relativePath("/repo", "/repo"));
    try std.testing.expectEqualStrings("x.zig", relativePath("/repo/x.zig", "/repo/"));
    try std.testing.expectEqualStrings("x.zig", relativePath("/x.zig", "/"));
    // An empty base is no base: the guarded semantics return the path
    // unchanged (the deleted main.zig copy behaved the same, EPH-I0176).
    try std.testing.expectEqualStrings("/abs/x.zig", relativePath("/abs/x.zig", ""));
}

test "isPathAncestorOrEqual requires a component boundary (EPH-I0176)" {
    try std.testing.expect(isPathAncestorOrEqual("/repo", "/repo"));
    try std.testing.expect(isPathAncestorOrEqual("/repo", "/repo/sub/file"));
    try std.testing.expect(isPathAncestorOrEqual("/", "/anything"));
    try std.testing.expect(!isPathAncestorOrEqual("/repo", "/repo-evil/x"));
    try std.testing.expect(!isPathAncestorOrEqual("/repo/sub", "/repo"));
    try std.testing.expect(!isPathAncestorOrEqual("", "/repo"));
    try std.testing.expect(isPathAncestorOrEqual("/repo/", "/repo"));
    try std.testing.expect(isPathAncestorOrEqual("/repo/", "/repo/x"));
    try std.testing.expect(!isPathAncestorOrEqual("/repo/", "/repo-evil"));
}

test "countOccurrences counts correctly" {
    try std.testing.expectEqual(@as(usize, 3), countOccurrences("ababa", "a"));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences("ababa", "ab"));
}

test "countLines counts newlines" {
    try std.testing.expectEqual(@as(usize, 0), countLines(""));
    try std.testing.expectEqual(@as(usize, 3), countLines("a\nb\nc"));
    try std.testing.expectEqual(@as(usize, 1), countLines("no newlines"));
    // A trailing newline closes the last line instead of opening a
    // phantom one (EPH-I0724): "a\nb\nc\n" is 3 lines, not 4.
    try std.testing.expectEqual(@as(usize, 3), countLines("a\nb\nc\n"));
    try std.testing.expectEqual(@as(usize, 1), countLines("\n"));
    try std.testing.expectEqual(@as(usize, 2), countLines("\n\n"));
    try std.testing.expectEqual(@as(usize, 1), countLines("single\n"));
}

test "isInsideString detects strings" {
    try std.testing.expect(isInsideString("const x = \"hello", 14));
    try std.testing.expect(!isInsideString("const x = 42", 8));
}

test "isInsideString skips char literal spans" {
    // A `"` inside a char literal stays character data. It must not open
    // string state (EPH-I0104 review, Finding A).
    try std.testing.expect(!isInsideString("const q = '\"'; x = 1;", 15));
    // Escaped-quote (`'\''`) and backslash (`'\\'`) char literals close at
    // their final quote.
    try std.testing.expect(!isInsideString("const q = '\\''; x = 1;", 16));
    try std.testing.expect(!isInsideString("const q = '\\\\'; x = 1;", 16));
    // A string after a closed char literal still opens string state.
    try std.testing.expect(isInsideString("const q = 'a'; const s = \"x", 26));
    // Escape handling inside strings is unchanged: `\"` does not close.
    try std.testing.expect(isInsideString("const s = \"a \\\" b", 17));
}

/// Assert the incremental classifier agrees with the from-column-0 rescan
/// at every column of `line`, queried in ascending order (EPH-I0153).
fn expectClassifierParity(line: []const u8) !void {
    var cls = LineClassifier.init(line);
    var col: usize = 0;
    while (col <= line.len) : (col += 1) {
        try std.testing.expectEqual(isInsideString(line, col), cls.isInsideString(col));
    }
}

test "LineClassifier matches isInsideString on a shape battery" {
    // The battery pins parity, including the shapes where the state machine
    // surprises: comments do not mask quotes. A `\\` opener in code position
    // marks its whole tail string data in both machines (EPH-I0671).
    const shapes = [_][]const u8{
        "",
        "const x = 42;",
        "const s = \"hello\";",
        "const s = \"a \\\"nested\\\" b\";",
        "const q = '\"'; const s = \"x\";",
        "const q = '\\'';",
        "const q = '\\\\';",
        "// comment with \"quote",
        "\\\\ multiline \"body\"",
        "const s = \"unterminated",
        "const s = \"\\\\\";",
        "catch { // }",
        "\"starts with quote\"",
        "'",
        "\"",
        "fn f() void { s.print(\"{d}\", .{x}); } // \"trailing",
        "const s = \\\\ if (x) { foo(); }",
        "x = 1; \\\\ // not a comment",
        "const c = '\\\\'; const s = \\\\ tail",
    };
    for (shapes) |line| try expectClassifierParity(line);
}

test "isMultilineOpenerAt detects the two-backslash opener (EPH-I0671)" {
    // Target text: const s = \\ tail
    try std.testing.expect(isMultilineOpenerAt("const s = \\\\ tail", 10));
    // The second backslash is not itself an opener start.
    try std.testing.expect(!isMultilineOpenerAt("const s = \\\\ tail", 11));
    // A lone backslash (invalid Zig) and a backslash at end-of-line stay code.
    try std.testing.expect(!isMultilineOpenerAt("const s = \\x", 10));
    try std.testing.expect(!isMultilineOpenerAt("trail \\", 6));
    try std.testing.expect(!isMultilineOpenerAt("no backslash", 0));
}

test "isInsideString treats a mid-line multiline opener tail as string data (EPH-I0671)" {
    // Target text: const s = \\ if (x) { foo(); }
    const line = "const s = \\\\ if (x) { foo(); }";
    try std.testing.expect(!isInsideString(line, 9));
    try std.testing.expect(!isInsideString(line, 10));
    try std.testing.expect(isInsideString(line, 12));
    try std.testing.expect(isInsideString(line, line.len - 1));
}

test "LiteralState masks a mid-line multiline opener tail (EPH-I0671)" {
    // Target text: const s = \\ free(); // not a comment
    const line = "const s = \\\\ free(); // not a comment";
    var lit = LiteralState.forLine(line) orelse unreachable;
    try std.testing.expectEqual(@as(?usize, 0), lit.updateForChar(line, 0));
    try std.testing.expectEqual(@as(?usize, 9), lit.updateForChar(line, 9));
    try std.testing.expect(lit.updateForChar(line, 10) == null);
    try std.testing.expect(lit.updateForChar(line, 15) == null);
    // The `//` in the tail never opens a comment: it is string data.
    try std.testing.expect(lit.updateForChar(line, 23) == null);
    try std.testing.expect(!lit.in_comment);
}

test "LiteralState keeps escape runs inside char literals (EPH-I0671)" {
    // Target text: const c = '\\'; x = 1; — the backslash pair inside the
    // char literal is an escape run, not a multiline opener.
    const line = "const c = '\\\\'; x = 1;";
    var lit = LiteralState.forLine(line) orelse unreachable;
    var i: usize = 0;
    var tail_code = false;
    while (i < line.len) : (i += 1) {
        if (lit.updateForChar(line, i)) |pos| {
            if (pos > 14) tail_code = true;
        }
    }
    try std.testing.expect(!lit.in_mline);
    try std.testing.expect(tail_code);
}

test "LiteralState.forLine returns null for a multiline body line (EPH-I0585)" {
    // After optional leading whitespace, `\\` makes the whole line string
    // data: no position on it is code, so forLine reports no state.
    try std.testing.expect(LiteralState.forLine("\\\\ body") == null);
    try std.testing.expect(LiteralState.forLine("  \\\\ body") == null);
    try std.testing.expect(LiteralState.forLine("\t\\\\ body") == null);
    // Every other line carries code: empty, plain code, and a mid-line
    // opener (the opener is updateForChar's job, not forLine's).
    try std.testing.expect(LiteralState.forLine("") != null);
    try std.testing.expect(LiteralState.forLine("const x = 1;") != null);
    try std.testing.expect(LiteralState.forLine("x = \\\\") != null);
}

test "LiteralState masks delimiter bytes and reports code (EPH-I0585)" {
    // Target: const s = "ab"; x = 1; — the quotes themselves are masked
    // (null), and code positions resume after the closing delimiter.
    const line = "const s = \"ab\"; x = 1;";
    var lit = LiteralState.forLine(line) orelse unreachable;
    try std.testing.expectEqual(@as(?usize, 0), lit.updateForChar(line, 0));
    try std.testing.expect(lit.updateForChar(line, 10) == null);
    try std.testing.expect(lit.in_str);
    try std.testing.expect(lit.updateForChar(line, 11) == null);
    try std.testing.expect(lit.updateForChar(line, 13) == null);
    try std.testing.expect(!lit.in_str);
    try std.testing.expectEqual(@as(?usize, 14), lit.updateForChar(line, 14));

    // Target: const c = 'a'; x(); — same contract for char delimiters.
    const ch = "const c = 'a'; x();";
    var clit = LiteralState.forLine(ch) orelse unreachable;
    try std.testing.expect(clit.updateForChar(ch, 10) == null);
    try std.testing.expect(clit.in_chr);
    try std.testing.expect(clit.updateForChar(ch, 11) == null);
    try std.testing.expect(clit.updateForChar(ch, 12) == null);
    try std.testing.expect(!clit.in_chr);
    try std.testing.expectEqual(@as(?usize, 13), clit.updateForChar(ch, 13));

    // Target: x = 1; // c — both comment slashes and the tail are masked.
    const cm = "x = 1; // c";
    var mlit = LiteralState.forLine(cm) orelse unreachable;
    try std.testing.expect(mlit.updateForChar(cm, 7) == null);
    try std.testing.expect(mlit.in_comment);
    try std.testing.expect(mlit.updateForChar(cm, 8) == null);
    try std.testing.expect(mlit.updateForChar(cm, cm.len - 1) == null);
}

test "LiteralState honors odd and even backslash runs (EPH-I0585)" {
    // Target: const q = '\''; x = 1; — the escaped quote (odd run) stays
    // content, so the char literal closes at the final quote (even run).
    const line = "const q = '\\''; x = 1;";
    var lit = LiteralState.forLine(line) orelse unreachable;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const pos = lit.updateForChar(line, i);
        if (i == 12) {
            try std.testing.expectEqual(@as(?usize, null), pos);
            try std.testing.expect(lit.in_chr);
        }
        if (i == 13) try std.testing.expect(!lit.in_chr);
        if (i == 14) try std.testing.expectEqual(@as(?usize, 14), pos);
    }

    // Target: const s = "a \" b"; x(); — the escaped quote stays content.
    const str_line = "const s = \"a \\\" b\"; x();";
    var slit = LiteralState.forLine(str_line) orelse unreachable;
    i = 0;
    while (i < str_line.len) : (i += 1) {
        const pos = slit.updateForChar(str_line, i);
        if (i == 14) {
            try std.testing.expectEqual(@as(?usize, null), pos);
            try std.testing.expect(slit.in_str);
        }
        if (i == 17) try std.testing.expect(!slit.in_str);
        if (i == 18) try std.testing.expectEqual(@as(?usize, 18), pos);
    }

    // Target: const s = "a\\"; x(); — the even run closes the string.
    const even_close = "const s = \"a\\\\\"; x();";
    var elit = LiteralState.forLine(even_close) orelse unreachable;
    i = 0;
    while (i < even_close.len) : (i += 1) {
        const pos = elit.updateForChar(even_close, i);
        if (i == 14) try std.testing.expect(!elit.in_str);
        if (i == 15) try std.testing.expectEqual(@as(?usize, 15), pos);
    }
}

test "LiteralState keeps an unterminated literal masked (EPH-I0585)" {
    // No closing quote: every later byte is literal data, so the tail
    // positions return null and the literal flag stays set.
    const line = "const s = \"abc";
    var lit = LiteralState.forLine(line) orelse unreachable;
    var last: ?usize = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) last = lit.updateForChar(line, i);
    try std.testing.expect(last == null);
    try std.testing.expect(lit.in_str);
    const ch = "const c = 'a";
    var clit = LiteralState.forLine(ch) orelse unreachable;
    last = null;
    i = 0;
    while (i < ch.len) : (i += 1) last = clit.updateForChar(ch, i);
    try std.testing.expect(last == null);
    try std.testing.expect(clit.in_chr);
}

test "LiteralState never opens a comment inside a literal (EPH-I0585)" {
    // Target: const s = "http://x"; y = 1; — the `//` is string data, so
    // the comment never opens and code resumes after the real close.
    const line = "const s = \"http://x\"; y = 1;";
    var lit = LiteralState.forLine(line) orelse unreachable;
    var i: usize = 0;
    var tail_code = false;
    while (i < line.len) : (i += 1) {
        if (lit.updateForChar(line, i)) |pos| {
            if (pos >= 20) tail_code = true;
        }
    }
    try std.testing.expect(tail_code);
    try std.testing.expect(!lit.in_comment);
    // The comment form still opens in code context.
    const code = "x = 1; // real";
    var clit = LiteralState.forLine(code) orelse unreachable;
    var j: usize = 0;
    while (j < code.len) : (j += 1) _ = clit.updateForChar(code, j);
    try std.testing.expect(clit.in_comment);
}

test "hasEvenBackslashRun distinguishes delimiters from escaped quotes (EPH-I0585)" {
    // No backslash before the quote: even run, delimiter.
    try std.testing.expect(hasEvenBackslashRun("\"", 0));
    try std.testing.expect(hasEvenBackslashRun("x\"", 1));
    // One backslash: odd run, escaped content.
    try std.testing.expect(!hasEvenBackslashRun("\\\"", 1));
    // Two: even again, delimiter.
    try std.testing.expect(hasEvenBackslashRun("\\\\\"", 2));
    // Three: odd again.
    try std.testing.expect(!hasEvenBackslashRun("\\\\\\\"", 3));
}

test "LineClassifier bounds work to one walk per line" {
    // 1 MiB single-line string body with 10k ascending candidates: total
    // scanned bytes must stay <= line length (one walk), not candidates
    // times line length (EPH-I0153).
    const allocator = std.testing.allocator;
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(allocator);
    try line.appendSlice(allocator, "const s = \"");
    try line.appendNTimes(allocator, 'a', 1024 * 1024);
    try line.appendSlice(allocator, "\"; x();");

    var cls = LineClassifier.init(line.items);
    const candidates: usize = 10 * 1000;
    const stride = line.items.len / candidates;
    var col: usize = 12;
    var string_hits: usize = 0;
    for (0..candidates) |_| {
        if (cls.isInsideString(col)) string_hits += 1;
        col += stride;
    }
    try std.testing.expect(cls.scanned <= line.items.len);
    // The body is one long string: interior candidates classify inside.
    try std.testing.expect(string_hits > candidates / 2);
    // The code after the closing quote is outside.
    try std.testing.expect(!cls.isInsideString(line.items.len - 1));
}

test "ReturnKind has all expected variants" {
    const rk: ReturnKind = .void_type;
    try std.testing.expect(rk == .void_type);
    try std.testing.expect(ReturnKind.error_union != .void_type);
    try std.testing.expect(ReturnKind.value != .error_union);
    try std.testing.expect(ReturnKind.optional != .value);
    try std.testing.expect(ReturnKind.noreturn_type != .optional);
    try std.testing.expect(ReturnKind.unknown != .noreturn_type);
}

test "skipWhitespace skips blanks and stops at code" {
    try std.testing.expectEqual(@as(usize, 5), skipWhitespace("  \t\r\nab", 0));
    try std.testing.expectEqual(@as(usize, 0), skipWhitespace("ab  ", 0));
    try std.testing.expectEqual(@as(usize, 2), skipWhitespace("  x", 1));
    try std.testing.expectEqual(@as(usize, 3), skipWhitespace("abc", 3));
}

test "deinitIssues frees owned messages and leaves borrowed ones (EPH-I0585)" {
    const allocator = std.testing.allocator;
    var issues: std.ArrayListUnmanaged(Issue) = .empty;
    const owned = try allocator.dupe(u8, "owned message");
    try issues.append(allocator, .{
        .file = "borrowed.zig",
        .line = 1,
        .col = 1,
        .severity = .warning,
        .rule = "ZA201",
        .message = owned,
        .help = null,
        .message_owned = true,
    });
    try issues.append(allocator, .{
        .file = "borrowed.zig",
        .line = 2,
        .col = 1,
        .severity = .warning,
        .rule = "ZA201",
        .message = "borrowed message",
        .help = null,
    });
    deinitIssues(&issues, allocator);
    // std.testing.allocator fails the test when the owned message leaks
    // or when the borrowed message is freed (an invalid free).
}

test "FileAnalysis.deinit frees every owned field (EPH-I0585)" {
    const allocator = std.testing.allocator;
    // Distinct path and resolved_path: both freed.
    var fa = FileAnalysis{
        .path = try allocator.dupe(u8, "src/a.zig"),
        .resolved_path = try allocator.dupe(u8, "/repo/src/a.zig"),
        .imports = .empty,
        .content = try allocator.dupe(u8, "const x = 1;\n"),
        .has_tests = false,
        .pub_function_count = 0,
        .line_count = 1,
        .is_generated = false,
    };
    fa.deinit(allocator);

    // Realpath fallback: resolved_path and path share the pointer, so
    // deinit frees the buffer exactly once.
    const shared = try allocator.dupe(u8, "src/b.zig");
    var fb = FileAnalysis{
        .path = shared,
        .resolved_path = shared,
        .imports = .empty,
        .content = try allocator.dupe(u8, ""),
        .has_tests = false,
        .pub_function_count = 0,
        .line_count = 0,
        .is_generated = false,
    };
    fb.deinit(allocator);

    // Owned imports: path, name, and resolved all freed.
    var imports: std.ArrayListUnmanaged(ImportInfo) = .empty;
    try imports.append(allocator, .{
        .path = try allocator.dupe(u8, "std"),
        .resolved = try allocator.dupe(u8, "/zig/lib/std"),
        .name = try allocator.dupe(u8, "std"),
        .line = 3,
        .col = 1,
    });
    try imports.append(allocator, .{
        .path = try allocator.dupe(u8, "./mod"),
        .resolved = null,
        .name = try allocator.dupe(u8, "mod"),
        .line = 4,
        .col = 1,
    });
    var fc = FileAnalysis{
        .path = try allocator.dupe(u8, "src/c.zig"),
        .resolved_path = try allocator.dupe(u8, "/repo/src/c.zig"),
        .imports = imports,
        .content = try allocator.dupe(u8, "const y = 2;\n"),
        .has_tests = true,
        .pub_function_count = 1,
        .line_count = 1,
        .is_generated = false,
    };
    fc.deinit(allocator);
    // std.testing.allocator fails the test on any leak or double free.
}

test "formatText sanitizes hostile file and message bytes" {
    const issue = Issue{
        .file = "ev\nil.zig",
        .line = 3,
        .col = 2,
        .severity = .warning,
        .rule = "ZT101",
        .message = "bad \x1b[31mnews",
        .help = null,
    };
    var out = OutBuf{ .allocator = std.testing.allocator };
    defer out.deinit();
    try issue.formatText("/repo", &out);
    try std.testing.expectEqualStrings(
        "ev?il.zig:3:2: warning[ZT101]: bad ?[31mnews\n",
        out.buf.items,
    );
}

test "formatText sanitizes help and keeps the position for file-level issues (EPH-I0739)" {
    // File-level findings render the positioned form (`f.zig:1:1:`), so
    // the single documented VS Code problemMatcher regex matches every
    // finding line. The pre-fix drop branch printed no position here
    // (and also de-positioned real findings at 1:1).
    const issue = Issue{
        .file = "f.zig",
        .line = 1,
        .col = 1,
        .severity = .note,
        .rule = "ZA501",
        .message = "orphan",
        .help = "drop it\rnow",
    };
    var out = OutBuf{ .allocator = std.testing.allocator };
    defer out.deinit();
    try issue.formatText("/repo", &out);
    try std.testing.expectEqualStrings(
        "f.zig:1:1: note[ZA501]: orphan\n  help: drop it?now\n",
        out.buf.items,
    );
}

test "formatJsonLast escapes attacker bytes and the result parses" {
    const allocator = std.testing.allocator;
    const raw_file = "quo\"te\\back.zig";
    const issue = Issue{
        .file = raw_file,
        .line = 7,
        .col = 4,
        .severity = .warning,
        .rule = "ZA201",
        .message = "line one\nline two \u{202e}",
        .help = "fix\x1bit",
    };
    var out = OutBuf{ .allocator = allocator };
    defer out.deinit();
    try issue.formatJsonLast("/repo", &out);
    // Hostile bytes must not appear raw: the bidi override stays escaped.
    try std.testing.expect(std.mem.indexOf(u8, out.buf.items, "\u{202e}") == null);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        out.buf.items,
        .{},
    );
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings(raw_file, obj.get("file").?.string);
    try std.testing.expectEqualStrings(
        "line one\nline two \u{202e}",
        obj.get("message").?.string,
    );
    try std.testing.expectEqualStrings("fix\x1bit", obj.get("help").?.string);
}

test "formatJsonLast closes without a comma and formatJsonEntry carries one (EPH-I1121)" {
    // The byte pin covers both terminator forms: the last element closes
    // the array, every other element carries the separating comma.
    const issue = Issue{
        .file = "f.zig",
        .line = 1,
        .col = 1,
        .severity = .note,
        .rule = "ZA501",
        .message = "m",
        .help = null,
    };
    var last = OutBuf{ .allocator = std.testing.allocator };
    defer last.deinit();
    try issue.formatJsonLast("/repo", &last);
    try std.testing.expectEqualStrings(
        "  {\n" ++
            "    \"file\": \"f.zig\",\n" ++
            "    \"line\": 1,\n" ++
            "    \"column\": 1,\n" ++
            "    \"severity\": \"note\",\n" ++
            "    \"rule\": \"ZA501\",\n" ++
            "    \"message\": \"m\"\n" ++
            "  }\n",
        last.buf.items,
    );
    var mid = OutBuf{ .allocator = std.testing.allocator };
    defer mid.deinit();
    try issue.formatJsonEntry("/repo", &mid);
    try std.testing.expectEqualStrings(
        "  {\n" ++
            "    \"file\": \"f.zig\",\n" ++
            "    \"line\": 1,\n" ++
            "    \"column\": 1,\n" ++
            "    \"severity\": \"note\",\n" ++
            "    \"rule\": \"ZA501\",\n" ++
            "    \"message\": \"m\"\n" ++
            "  },\n",
        mid.buf.items,
    );
}

test "printText renders the sanitized line through the writer seam (EPH-I0687)" {
    const issue = Issue{
        .file = "ev\x1bil.zig",
        .line = 5,
        .col = 1,
        .severity = .warning,
        .rule = "ZT101",
        .message = "m",
        .help = null,
    };
    // The writer seam keeps the hostile fixture bytes off the green-run
    // log (EPH-I0687, the EPH-I0288 noise class) and lets the test assert
    // the printed bytes directly instead of riding the formatText core.
    // The expected line pins the sanitizer's replacement too: the ESC
    // byte (the \x1b escape in the fixture) renders as '?'.
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    issue.printText(std.testing.allocator, "/repo", &w);
    try std.testing.expectEqualStrings("ev?il.zig:5:1: warning[ZT101]: m\n", w.buffered());
}
