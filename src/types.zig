// Rhyos Labs - Ephor
// Shared types for all analyzer modules
// Copyright (C) 2025 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ============================================================================
// Rule IDs (for suppression and documentation)
// ============================================================================

// ZA1xx - Memory
pub const RULE_ALLOC_NO_DEFER = "ZA101";
pub const RULE_CREATE_NO_DEFER = "ZA102";
pub const RULE_ALLOC_NO_ERRDEFER = "ZA103";
pub const RULE_USE_AFTER_FREE = "ZA105";
pub const RULE_DOUBLE_FREE = "ZA106";
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

// ZA5xx - Structure
pub const RULE_ORPHAN_FILE = "ZA501";
pub const RULE_FILE_TOO_LARGE = "ZA502";

// ZA6xx - Formatting (ZA607 is a semantic definite-assignment check that kept
// its ZA6xx ID for backward compatibility with existing inline-ignores)
pub const RULE_NEEDS_FORMAT = "ZA601";
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

/// Which convention ZA703 enforces for error values and error set members.
/// The stdlib and virtually all community code use TitleCase error names, so
/// that is the default; snake_case preserves the pre-flip ZA703 behavior for
/// projects that adopted it.
pub const ErrorNaming = enum {
    title_case, // error.FileNotFound (default, community standard)
    snake_case, // error.file_not_found (pre-flip ZA703 default)

    pub fn str(self: ErrorNaming) []const u8 {
        return switch (self) {
            .title_case => "TitleCase",
            .snake_case => "snake_case",
        };
    }

    /// "PascalCase" is accepted as an alias for TitleCase (common spelling).
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
        // File-level issues (line=1, col=1) show just filename, no confusing :1:1
        if (self.line == 1 and self.col == 1) {
            try out.print("{s}: {s}[{s}]: {s}\n", .{
                rel.slice,
                self.severity.str(),
                self.rule,
                msg.slice,
            });
        } else {
            try out.print("{s}:{d}:{d}: {s}[{s}]: {s}\n", .{
                rel.slice,
                self.line,
                self.col,
                self.severity.str(),
                self.rule,
                msg.slice,
            });
        }
        if (self.help) |h| {
            var help = try sanitizeTerminal(out.allocator, h);
            defer help.deinit(out.allocator);
            try out.print("  help: {s}\n", .{help.slice});
        }
    }

    /// Render the JSON object form into `out`. Every repo-derived field
    /// passes through escapeJson so quote, backslash, and control bytes in
    /// filenames or messages cannot break the document (EPH-I0146).
    pub fn formatJson(
        self: Issue,
        base_path: []const u8,
        is_last: bool,
        out: *OutBuf,
    ) !void {
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
        if (is_last) {
            try out.print("  }}\n", .{});
        } else {
            try out.print("  }},\n", .{});
        }
    }

    /// Print the text form to stderr. Buffers through formatText so each
    /// finding lands in one write.
    pub fn printText(self: Issue, allocator: Allocator, base_path: []const u8) void {
        var out = OutBuf{ .allocator = allocator };
        defer out.deinit();
        self.formatText(base_path, &out) catch {
            // OOM mid-format: emit a bare notice rather than drop the
            // finding silently.
            std.debug.print("ephor: out of memory printing {s} finding\n", .{
                self.rule,
            });
            return;
        };
        std.debug.print("{s}", .{out.buf.items});
    }

    /// Print the JSON object form to stderr (see printText).
    pub fn printJson(
        self: Issue,
        allocator: Allocator,
        base_path: []const u8,
        is_last: bool,
    ) void {
        var out = OutBuf{ .allocator = allocator };
        defer out.deinit();
        self.formatJson(base_path, is_last, &out) catch {
            std.debug.print("ephor: out of memory printing {s} finding\n", .{
                self.rule,
            });
            return;
        };
        std.debug.print("{s}", .{out.buf.items});
    }
};

// ============================================================================
// Output Sanitization (RED5: EPH-I0146, I0147, I0148, I0149, I0162)
// ============================================================================

/// Sanitized output: borrows the input when it was clean, owns an allocated
/// copy when any byte was replaced. deinit frees only the owned copy.
pub const Sanitized = struct {
    slice: []const u8,
    owned: bool,

    /// Free the owned copy, if any. Safe to call on borrowed results.
    pub fn deinit(self: *Sanitized, allocator: Allocator) void {
        if (self.owned) allocator.free(self.slice);
        self.owned = false;
    }
};

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

/// Byte length of the hostile sequence starting at `s[0]`, or 0 when the
/// byte is safe to print. Multi-byte format characters consume their full
/// UTF-8 sequence so one placeholder replaces the whole character.
fn hostileSeqLen(s: []const u8) usize {
    const b = s[0];
    if (b < 0x20 or b == 0x7F) return 1;
    if (b == 0xC2) return c1SeqLen(s);
    if (b == 0xE2) return formatSeqLen(s);
    if (b == 0xEF) return bomSeqLen(s);
    return 0;
}

/// C1 controls (U+0080..U+009F) arrive UTF-8 encoded as 0xC2 0x80..0x9F.
/// U+0085 NEL is a line terminator and a log-forgery vector on its own. A
/// truncated lead byte consumes the rest: it is invalid UTF-8 regardless.
fn c1SeqLen(s: []const u8) usize {
    if (s.len < 2) return s.len;
    if (s[1] >= 0x80 and s[1] <= 0x9F) return 2;
    return 0;
}

/// Hostile format characters under the 0xE2 lead (see formatCodepoint).
fn formatSeqLen(s: []const u8) usize {
    if (s.len < 3) return s.len;
    if (formatCodepoint(s) != null) return 3;
    return 0;
}

/// U+FEFF (zero-width no-break space, BOM) under the 0xEF lead.
fn bomSeqLen(s: []const u8) usize {
    if (s.len < 3) return s.len;
    if (s[1] == 0xBB and s[2] == 0xBF) return 3;
    return 0;
}

/// Codepoint of a hostile U+20xx format character (s[0] == 0xE2, s.len >=
/// 3), or null when the sequence is clean: U+200E/U+200F bidi marks,
/// U+2028/U+2029 line and paragraph separators, U+202A..U+202E bidi
/// embeddings and overrides, U+2066..U+2069 bidi isolates. Shared by the
/// terminal filter and the JSON escaper so both reject the same set.
fn formatCodepoint(s: []const u8) ?u21 {
    if (s[1] == 0x80 and s[2] >= 0xA8 and s[2] <= 0xAE) {
        return 0x2028 + @as(u21, s[2] - 0xA8);
    }
    if (s[1] == 0x80 and (s[2] == 0x8E or s[2] == 0x8F)) {
        return 0x200E + @as(u21, s[2] - 0x8E);
    }
    if (s[1] == 0x81 and s[2] >= 0xA6 and s[2] <= 0xA9) {
        return 0x2066 + @as(u21, s[2] - 0xA6);
    }
    return null;
}

/// Filter terminal-hostile bytes from attacker-derived text: C0 controls
/// (CR and LF included, so no byte forges a new log line), DEL, C1
/// controls, bidi and invisible format characters. Each hostile sequence
/// becomes one visible '?' so redaction gaps stay visible. Clean input
/// borrows without allocation. The filter assumes valid UTF-8: bare
/// 0x80..0x9F bytes and overlong lead bytes pass through, which is inert
/// to a UTF-8 decoder.
pub fn sanitizeTerminal(
    allocator: Allocator,
    input: []const u8,
) error{OutOfMemory}!Sanitized {
    var out_len: usize = 0;
    var dirty = false;
    var i: usize = 0;
    while (i < input.len) {
        const skip = hostileSeqLen(input[i..]);
        if (skip == 0) {
            i += 1;
        } else {
            dirty = true;
            i += skip;
        }
        out_len += 1;
    }
    if (!dirty) return .{ .slice = input, .owned = false };
    const buf = try allocator.alloc(u8, out_len);
    errdefer allocator.free(buf);
    i = 0;
    var o: usize = 0;
    while (i < input.len) {
        const skip = hostileSeqLen(input[i..]);
        if (skip == 0) {
            buf[o] = input[i];
            i += 1;
        } else {
            buf[o] = '?';
            i += skip;
        }
        o += 1;
    }
    return .{ .slice = buf, .owned = true };
}

/// One classified input unit for JSON escaping: how many input bytes it
/// spans and which escaped form to emit.
const JsonEscape = struct {
    consumed: usize,
    kind: Kind,
    named_char: u8 = 0,
    codepoint: u21 = 0,

    const Kind = enum {
        clean, // copy the byte raw
        named, // two-character escape: backslash plus named_char
        unicode, // \uXXXX of codepoint
    };
};

/// The escape letter for bytes with a two-character JSON escape.
fn jsonNamedEscape(b: u8) ?u8 {
    return switch (b) {
        '"' => '"',
        '\\' => '\\',
        0x08 => 'b',
        0x09 => 't',
        0x0A => 'n',
        0x0C => 'f',
        0x0D => 'r',
        else => null,
    };
}

/// Classify the unit at `s[0]` for JSON escaping.
fn classifyJsonUnit(s: []const u8) JsonEscape {
    const b = s[0];
    if (jsonNamedEscape(b)) |c| {
        return .{ .consumed = 1, .kind = .named, .named_char = c };
    }
    if (b < 0x20 or b == 0x7F) {
        return .{ .consumed = 1, .kind = .unicode, .codepoint = b };
    }
    if (b == 0xC2) return classifyJsonC1(s);
    if (b == 0xE2) return classifyJsonFormat(s);
    if (b == 0xEF) return classifyJsonBom(s);
    return .{ .consumed = 1, .kind = .clean };
}

/// C1 controls escape as their codepoint (U+0080..U+009F); a truncated
/// lead byte becomes U+FFFD.
fn classifyJsonC1(s: []const u8) JsonEscape {
    if (s.len < 2) {
        return .{ .consumed = 1, .kind = .unicode, .codepoint = 0xFFFD };
    }
    if (s[1] >= 0x80 and s[1] <= 0x9F) {
        return .{ .consumed = 2, .kind = .unicode, .codepoint = s[1] };
    }
    return .{ .consumed = 1, .kind = .clean };
}

/// Hostile U+20xx format characters escape as their codepoint; a truncated
/// sequence becomes one U+FFFD.
fn classifyJsonFormat(s: []const u8) JsonEscape {
    if (s.len < 3) {
        return .{ .consumed = s.len, .kind = .unicode, .codepoint = 0xFFFD };
    }
    const cp = formatCodepoint(s) orelse {
        return .{ .consumed = 1, .kind = .clean };
    };
    return .{ .consumed = 3, .kind = .unicode, .codepoint = cp };
}

/// U+FEFF escapes as its codepoint; a truncated 0xEF lead becomes U+FFFD.
fn classifyJsonBom(s: []const u8) JsonEscape {
    if (s.len < 3) {
        return .{ .consumed = s.len, .kind = .unicode, .codepoint = 0xFFFD };
    }
    if (s[1] == 0xBB and s[2] == 0xBF) {
        return .{ .consumed = 3, .kind = .unicode, .codepoint = 0xFEFF };
    }
    return .{ .consumed = 1, .kind = .clean };
}

/// Write one escaped unit into `dst`, returning the bytes written. The
/// caller sized `dst` for exactly this unit.
fn writeJsonUnit(dst: []u8, unit: JsonEscape, src: []const u8) usize {
    switch (unit.kind) {
        .clean => {
            dst[0] = src[0];
            return 1;
        },
        .named => {
            dst[0] = '\\';
            dst[1] = unit.named_char;
            return 2;
        },
        .unicode => return writeJsonUnicode(dst, unit.codepoint),
    }
}

/// Write `\uXXXX` (uppercase hex) into `dst`, returning 6.
fn writeJsonUnicode(dst: []u8, cp: u21) usize {
    const hex = "0123456789ABCDEF";
    dst[0] = '\\';
    dst[1] = 'u';
    dst[2] = hex[@intCast((cp >> 12) & 0xF)];
    dst[3] = hex[@intCast((cp >> 8) & 0xF)];
    dst[4] = hex[@intCast((cp >> 4) & 0xF)];
    dst[5] = hex[@intCast(cp & 0xF)];
    return 6;
}

/// Escape a string for embedding in JSON output: quotes, backslashes, and
/// control bytes use the standard escapes, and bidi or invisible format
/// characters escape as \uXXXX (legal raw in JSON but hostile to humans
/// and downstream tools). Clean input borrows without allocation.
pub fn escapeJson(
    allocator: Allocator,
    input: []const u8,
) error{OutOfMemory}!Sanitized {
    var out_len: usize = 0;
    var dirty = false;
    var i: usize = 0;
    while (i < input.len) {
        const unit = classifyJsonUnit(input[i..]);
        if (unit.kind != .clean) dirty = true;
        out_len += switch (unit.kind) {
            .clean => 1,
            .named => 2,
            .unicode => 6,
        };
        i += unit.consumed;
    }
    if (!dirty) return .{ .slice = input, .owned = false };
    const buf = try allocator.alloc(u8, out_len);
    errdefer allocator.free(buf);
    i = 0;
    var o: usize = 0;
    while (i < input.len) {
        const unit = classifyJsonUnit(input[i..]);
        o += writeJsonUnit(buf[o..], unit, input[i..]);
        i += unit.consumed;
    }
    return .{ .slice = buf, .owned = true };
}

/// ASCII punctuation with markdown meaning. Export fields backslash-escape
/// these so attacker filenames and prose cannot forge emphasis, links,
/// code spans, images, raw HTML, headings, or tables in issues.md
/// (EPH-I0162).
const markdown_escape_chars = "\\`*_[]<>#!|";

/// True when `b` carries markdown meaning in export fields.
fn isMarkdownMeta(b: u8) bool {
    return mem.indexOfScalar(u8, markdown_escape_chars, b) != null;
}

/// Filter terminal-hostile bytes and backslash-escape markdown
/// metacharacters for the markdown export fields, so attacker filenames
/// and prose cannot forge emphasis, links, code spans, images, raw HTML,
/// headings, or tables (EPH-I0162). Clean input borrows without allocation.
pub fn sanitizeMarkdown(
    allocator: Allocator,
    input: []const u8,
) error{OutOfMemory}!Sanitized {
    var out_len: usize = 0;
    var dirty = false;
    var i: usize = 0;
    while (i < input.len) {
        const skip = hostileSeqLen(input[i..]);
        if (skip != 0) {
            dirty = true;
            out_len += 1;
            i += skip;
        } else if (isMarkdownMeta(input[i])) {
            dirty = true;
            out_len += 2;
            i += 1;
        } else {
            out_len += 1;
            i += 1;
        }
    }
    if (!dirty) return .{ .slice = input, .owned = false };
    const buf = try allocator.alloc(u8, out_len);
    errdefer allocator.free(buf);
    i = 0;
    var o: usize = 0;
    while (i < input.len) {
        const skip = hostileSeqLen(input[i..]);
        if (skip != 0) {
            buf[o] = '?';
            o += 1;
            i += skip;
        } else if (isMarkdownMeta(input[i])) {
            buf[o] = '\\';
            buf[o + 1] = input[i];
            o += 2;
            i += 1;
        } else {
            buf[o] = input[i];
            o += 1;
            i += 1;
        }
    }
    return .{ .slice = buf, .owned = true };
}

/// Length of the backtick run at `s[0]` (s[0] == '`').
fn backtickRun(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and s[n] == '`') n += 1;
    return n;
}

/// Sanitize one source line for export snippet embedding: the
/// sanitizeTerminal control filter plus each backtick of a fence-capable
/// run (three or more) replaced with '?'. Shorter runs stay readable
/// because they cannot close the export fence (EPH-I0162).
pub fn sanitizeSnippet(
    allocator: Allocator,
    input: []const u8,
) error{OutOfMemory}!Sanitized {
    var out_len: usize = 0;
    var dirty = false;
    var i: usize = 0;
    while (i < input.len) {
        const unit = snippetUnit(input[i..]);
        dirty = dirty or unit.dirty;
        out_len += unit.emitted;
        i += unit.consumed;
    }
    if (!dirty) return .{ .slice = input, .owned = false };
    const buf = try allocator.alloc(u8, out_len);
    errdefer allocator.free(buf);
    i = 0;
    var o: usize = 0;
    while (i < input.len) {
        const skip = hostileSeqLen(input[i..]);
        if (skip != 0) {
            buf[o] = '?';
            o += 1;
            i += skip;
            continue;
        }
        if (input[i] == '`') {
            const run = backtickRun(input[i..]);
            if (run >= 3) {
                @memset(buf[o .. o + run], '?');
            } else {
                @memcpy(buf[o .. o + run], input[i .. i + run]);
            }
            o += run;
            i += run;
            continue;
        }
        buf[o] = input[i];
        o += 1;
        i += 1;
    }
    return .{ .slice = buf, .owned = true };
}

/// One classified input unit for sanitizeSnippet pass one: input bytes
/// consumed, output bytes emitted, and whether the unit changes under
/// sanitization. Hostile sequences collapse to one placeholder; backtick
/// runs keep their length either way.
const SnippetUnit = struct {
    consumed: usize,
    emitted: usize,
    dirty: bool,
};

/// Classify the unit at `s[0]` for sanitizeSnippet.
fn snippetUnit(s: []const u8) SnippetUnit {
    const skip = hostileSeqLen(s);
    if (skip != 0) {
        return .{ .consumed = skip, .emitted = 1, .dirty = true };
    }
    if (s[0] != '`') return .{ .consumed = 1, .emitted = 1, .dirty = false };
    const run = backtickRun(s);
    return .{ .consumed = run, .emitted = run, .dirty = run >= 3 };
}

pub const Thresholds = struct {
    max_function_lines: usize = 50,
    max_nesting_depth: usize = 3,
    max_params: usize = 4,
    max_branches: usize = 12,
    max_line_length: usize = 100,
    max_file_bytes: usize = 50_000,
    max_cyclomatic: usize = 15,
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
    /// observe parse outcomes. The .check flow owns that merge.
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

pub fn relativePath(path: []const u8, base: []const u8) []const u8 {
    if (mem.startsWith(u8, path, base)) {
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

pub fn countLines(content: []const u8) usize {
    var count: usize = 1;
    for (content) |c| {
        if (c == '\n') count += 1;
    }
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

/// Check if position `col` is inside a string literal. Escape handling: an
/// odd backslash run before a quote keeps the quote as character data, an
/// even run keeps it as a delimiter. Char literal spans (`'...'`, with `\'`
/// and `\\` escapes) never toggle string state: the `"` inside `'"'` stays
/// character data (EPH-I0104). A `\\` multiline opener in code position
/// makes the rest of the line string data, so positions past the opener
/// report inside-string (EPH-I0671).
pub fn isInsideString(line: []const u8, col: usize) bool {
    var mode: enum { none, str, char, mline } = .none;
    var i: usize = 0;
    while (i < col and i < line.len) : (i += 1) {
        const c = line[i];
        switch (mode) {
            .char => {
                if (c == '\\') i += 1;
                if (c == '\'') mode = .none;
            },
            .str => {
                if (c == '\\') i += 1;
                if (c == '"') mode = .none;
            },
            .mline => {},
            .none => {
                if (isMultilineOpenerAt(line, i)) mode = .mline;
                if (c == '\'') mode = .char;
                if (c == '"') mode = .str;
            },
        }
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

    /// `mline` is sticky: a `\\` multiline opener swallows the rest of its
    /// line, so no later byte on the line can leave string data (EPH-I0671).
    const QuoteMode = enum { none, str, char, mline };

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
            const c = self.line[self.scanned];
            switch (self.mode) {
                .char => {
                    if (c == '\\') self.scanned += 1;
                    if (c == '\'') self.mode = .none;
                },
                .str => {
                    if (c == '\\') self.scanned += 1;
                    if (c == '"') self.mode = .none;
                },
                .mline => {},
                .none => {
                    if (isMultilineOpenerAt(self.line, self.scanned)) self.mode = .mline;
                    if (c == '\'') self.mode = .char;
                    if (c == '"') self.mode = .str;
                },
            }
        }
        return self.mode == .str or self.mode == .mline;
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

/// Check if a rule is disabled via inline comment
pub fn isInlineDisabled(
    content: []const u8,
    line_num: usize,
    rule: []const u8,
) bool {
    var lines = mem.splitScalar(u8, content, '\n');
    var current_line: usize = 1;

    while (lines.next()) |line| {
        if (current_line == line_num or current_line == line_num - 1) {
            if (checkDisableComment(line, rule)) return true;
        }
        if (current_line > line_num) break;
        current_line += 1;
    }
    return false;
}

fn checkDisableComment(line: []const u8, rule: []const u8) bool {
    const patterns = [_][]const u8{
        "// ephor-disable",
        "// zig-lint-disable",
        "// nolint",
    };

    for (patterns) |pattern| {
        const idx = mem.indexOf(u8, line, pattern) orelse continue;
        const rest = line[idx + pattern.len ..];
        // Disabled all rules
        if (rest.len == 0 or rest[0] == '\n' or rest[0] == '\r') {
            return true;
        }
        // Check specific rule
        if (mem.indexOf(u8, rest, rule) != null) return true;
        // "next-line" applies to next line
        if (mem.indexOf(u8, rest, "next-line") != null) return true;
    }
    return false;
}

pub fn skipWhitespace(
    content: []const u8,
    start: usize,
    skip_comma: bool,
) usize {
    var i = start;
    while (i < content.len) : (i += 1) {
        const c = content[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
        if (skip_comma and c == ',') continue;
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

test "countOccurrences counts correctly" {
    try std.testing.expectEqual(@as(usize, 3), countOccurrences("ababa", "a"));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences("ababa", "ab"));
}

test "countLines counts newlines" {
    try std.testing.expectEqual(@as(usize, 3), countLines("a\nb\nc"));
    try std.testing.expectEqual(@as(usize, 1), countLines("no newlines"));
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

// ============================================================================
// Output Sanitization Tests (EPH-I0146, I0147, I0148, I0149, I0162)
// ============================================================================

test "sanitizeTerminal borrows clean input without allocation" {
    const input = "clean-ascii/path.zig";
    var result = try sanitizeTerminal(std.testing.allocator, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.owned);
    try std.testing.expectEqual(input.ptr, result.slice.ptr);
}

test "sanitizeTerminal replaces C0 controls and DEL with placeholders" {
    var result = try sanitizeTerminal(std.testing.allocator, "a\x00b\x1Bc\x7Fd");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.owned);
    try std.testing.expectEqualStrings("a?b?c?d", result.slice);
}

test "sanitizeTerminal never lets CR or LF survive" {
    var result = try sanitizeTerminal(std.testing.allocator, "one\ntwo\rthree\r\n");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("one?two?three??", result.slice);
    try std.testing.expect(std.mem.indexOfScalar(u8, result.slice, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, result.slice, '\r') == null);
}

test "sanitizeTerminal strips CSI escape sequences" {
    var result = try sanitizeTerminal(std.testing.allocator, "ok\x1b[1;31mred\x1b[0m");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ok?[1;31mred?[0m", result.slice);
}

test "sanitizeTerminal replaces bidi and separator format characters" {
    // U+202E RLO, U+2028 LS, U+2066 LRI, U+200E LRM, U+FEFF: one
    // placeholder each.
    var result = try sanitizeTerminal(
        std.testing.allocator,
        "a\u{202e}\u{2028}\u{2066}\u{200e}\u{feff}b",
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a?????b", result.slice);
}

test "sanitizeTerminal keeps valid UTF-8 but filters C1 controls" {
    // C2 A9 (copyright) is a clean two-byte character and borrows.
    var clean = try sanitizeTerminal(std.testing.allocator, "a\xc2\xa9b");
    defer clean.deinit(std.testing.allocator);
    try std.testing.expect(!clean.owned);
    // C2 85 (NEL) is a C1 line terminator and is replaced.
    var nel = try sanitizeTerminal(std.testing.allocator, "a\xc2\x85b");
    defer nel.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a?b", nel.slice);
}

test "sanitizeTerminal replaces truncated UTF-8 tails" {
    var result = try sanitizeTerminal(std.testing.allocator, "ab\xe2\x80");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ab?", result.slice);
}

test "escapeJson borrows clean input without allocation" {
    const input = "plain text 123";
    var result = try escapeJson(std.testing.allocator, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.owned);
    try std.testing.expectEqual(input.ptr, result.slice.ptr);
}

test "escapeJson escapes quotes, backslashes, and control bytes" {
    var result = try escapeJson(std.testing.allocator, "a\"b\\c\x1b\nd");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\u001B\\nd", result.slice);
}

test "escapeJson escapes bidi and C1 characters as codepoints" {
    var result = try escapeJson(
        std.testing.allocator,
        "x\u{202e}\u{2066}\u{feff}\xc2\x85y",
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("x\\u202E\\u2066\\uFEFF\\u0085y", result.slice);
}

test "sanitizeMarkdown escapes metacharacters and filters controls" {
    var result = try sanitizeMarkdown(std.testing.allocator, "a*b_[c]\n`x`");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a\\*b\\_\\[c\\]?\\`x\\`", result.slice);
}

test "sanitizeMarkdown borrows clean input" {
    const input = "plain-file.zig";
    var result = try sanitizeMarkdown(std.testing.allocator, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.owned);
}

test "sanitizeSnippet strips fence-capable backtick runs" {
    var result = try sanitizeSnippet(std.testing.allocator, "code ```zig fence ```");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("code ???zig fence ???", result.slice);
}

test "sanitizeSnippet keeps short backtick runs and filters controls" {
    var result = try sanitizeSnippet(std.testing.allocator, "a `b` ``c`` \x07d");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a `b` ``c`` ?d", result.slice);
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

test "formatText sanitizes help and drops position for file-level issues" {
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
        "f.zig: note[ZA501]: orphan\n  help: drop it?now\n",
        out.buf.items,
    );
}

test "formatJson escapes attacker bytes and the result parses" {
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
    try issue.formatJson("/repo", true, &out);
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

test "formatJson emits a trailing comma unless last" {
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
    try issue.formatJson("/repo", true, &last);
    try std.testing.expect(mem.endsWith(u8, last.buf.items, "  }\n"));
    var mid = OutBuf{ .allocator = std.testing.allocator };
    defer mid.deinit();
    try issue.formatJson("/repo", false, &mid);
    try std.testing.expect(mem.endsWith(u8, mid.buf.items, "  },\n"));
}

test "printText writes a sanitized line to stderr" {
    const issue = Issue{
        .file = "ev\x1bil.zig",
        .line = 5,
        .col = 1,
        .severity = .warning,
        .rule = "ZT101",
        .message = "m",
        .help = null,
    };
    // ZT105 coverage: the direct call is the point. stderr itself is
    // uncapturable, so the content assertion rides the formatText core.
    issue.printText(std.testing.allocator, "/repo");
    var out = OutBuf{ .allocator = std.testing.allocator };
    defer out.deinit();
    try issue.formatText("/repo", &out);
    try std.testing.expect(std.mem.indexOfScalar(u8, out.buf.items, 0x1B) == null);
}

test "printJson writes an escaped object to stderr" {
    const issue = Issue{
        .file = "q\".zig",
        .line = 1,
        .col = 1,
        .severity = .note,
        .rule = "ZA501",
        .message = "m",
        .help = null,
    };
    issue.printJson(std.testing.allocator, "/repo", true);
    var out = OutBuf{ .allocator = std.testing.allocator };
    defer out.deinit();
    try issue.formatJson("/repo", true, &out);
    try std.testing.expect(mem.indexOf(u8, out.buf.items, "q\".zig") == null);
    try std.testing.expect(mem.indexOf(u8, out.buf.items, "q\\\".zig") != null);
}
