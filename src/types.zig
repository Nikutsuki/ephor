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

/// One hostile format unit: the input bytes it spans and the codepoint it
/// carries. A clean sequence reports len 0.
const HostileUnit = struct {
    len: usize,
    cp: u21,
};

/// Inclusive window for a lead byte's first continuation byte.
const ByteWindow = struct {
    min: u8,
    max: u8,
};

/// Byte length of the hostile sequence starting at `s[0]`, or 0 when the
/// byte is safe to print. Multi-byte format characters consume their full
/// UTF-8 sequence so one placeholder replaces the whole character.
fn hostileSeqLen(s: []const u8) usize {
    const b = s[0];
    if (b < 0x20 or b == 0x7F) return 1;
    return hostileUnit(s).len;
}

/// Classify the byte at `s[0]` against the hostile bidi and invisible
/// format set (EPH-I0579): U+061C Arabic Letter Mark, U+00AD soft hyphen,
/// U+200B..U+200F zero-width and bidi marks, U+2028/U+2029 line and
/// paragraph separators, U+202A..U+202E bidi embeddings and overrides,
/// U+2060..U+206F invisible operators, bidi isolates, and deprecated
/// shaping marks (the unassigned U+2065 included: filtering it is free
/// and conservative), U+FEFF BOM, U+FFF9..U+FFFB interlinear
/// annotation anchors, and the tag characters U+E0001 and
/// U+E0020..U+E007F. A truncated lead consumes the rest (invalid UTF-8
/// regardless) and reports U+FFFD. Shared by the terminal filter and the
/// JSON escaper so both reject the same set.
fn hostileUnit(s: []const u8) HostileUnit {
    switch (s[0]) {
        0xC2 => return c2Unit(s),
        0xD8 => return almUnit(s),
        0xE2 => return formatUnit(s),
        0xEF => return efUnit(s),
        0xF3 => return tagUnit(s),
        else => return .{ .len = 0, .cp = 0 },
    }
}

/// C1 controls (U+0080..U+009F) and U+00AD soft hyphen under the 0xC2
/// lead. U+0085 NEL is a line terminator and a log-forgery vector on its
/// own. A truncated lead consumes the rest: it is invalid UTF-8 regardless.
fn c2Unit(s: []const u8) HostileUnit {
    if (s.len < 2) return .{ .len = s.len, .cp = 0xFFFD };
    if (s[1] >= 0x80 and s[1] <= 0x9F) return .{ .len = 2, .cp = s[1] };
    if (s[1] == 0xAD) return .{ .len = 2, .cp = 0xAD };
    return .{ .len = 0, .cp = 0 };
}

/// U+061C Arabic Letter Mark (bidi) under the 0xD8 lead.
fn almUnit(s: []const u8) HostileUnit {
    if (s.len < 2) return .{ .len = s.len, .cp = 0xFFFD };
    if (s[1] == 0x9C) return .{ .len = 2, .cp = 0x061C };
    return .{ .len = 0, .cp = 0 };
}

/// Hostile U+20xx format characters under the 0xE2 lead.
fn formatUnit(s: []const u8) HostileUnit {
    if (s.len < 3) return .{ .len = s.len, .cp = 0xFFFD };
    if (s[1] == 0x80) return format80Unit(s);
    if (s[1] == 0x81 and s[2] >= 0xA0 and s[2] <= 0xAF)
        return .{ .len = 3, .cp = 0x2060 + @as(u21, s[2] - 0xA0) };
    return .{ .len = 0, .cp = 0 };
}

/// U+200B..U+200F and U+2028..U+202E under 0xE2 0x80.
fn format80Unit(s: []const u8) HostileUnit {
    if (s[2] >= 0x8B and s[2] <= 0x8F)
        return .{ .len = 3, .cp = 0x200B + @as(u21, s[2] - 0x8B) };
    if (s[2] >= 0xA8 and s[2] <= 0xAE)
        return .{ .len = 3, .cp = 0x2028 + @as(u21, s[2] - 0xA8) };
    return .{ .len = 0, .cp = 0 };
}

/// U+FEFF BOM and U+FFF9..U+FFFB interlinear annotation anchors under the
/// 0xEF lead.
fn efUnit(s: []const u8) HostileUnit {
    if (s.len < 3) return .{ .len = s.len, .cp = 0xFFFD };
    if (s[1] == 0xBB and s[2] == 0xBF) return .{ .len = 3, .cp = 0xFEFF };
    if (s[1] == 0xBF and s[2] >= 0xB9 and s[2] <= 0xBB)
        return .{ .len = 3, .cp = 0xFFF9 + @as(u21, s[2] - 0xB9) };
    return .{ .len = 0, .cp = 0 };
}

/// Tag characters under the 0xF3 lead: U+E0001 and U+E0020..U+E007F. The
/// unassigned gap U+E0002..U+E001F passes clean: no assigned character
/// exists there to attack with.
fn tagUnit(s: []const u8) HostileUnit {
    if (s.len < 4) return .{ .len = s.len, .cp = 0xFFFD };
    if (s[1] != 0xA0) return .{ .len = 0, .cp = 0 };
    if (s[2] == 0x80 and s[3] == 0x81) return .{ .len = 4, .cp = 0xE0001 };
    return tagRangeUnit(s);
}

/// U+E0020..U+E007F under 0xF3 0xA0, each bounded to valid continuation
/// bytes (0x80..0xBF): an out-of-range fourth byte is invalid UTF-8 and
/// passes clean here, so the JSON validator turns it into U+FFFD
/// (EPH-I1120).
fn tagRangeUnit(s: []const u8) HostileUnit {
    if (s[2] == 0x80 and s[3] >= 0xA0 and s[3] <= 0xBF)
        return .{ .len = 4, .cp = 0xE0020 + @as(u21, s[3] - 0xA0) };
    if (s[2] == 0x81 and s[3] >= 0x80 and s[3] <= 0xBF)
        return .{ .len = 4, .cp = 0xE0040 + @as(u21, s[3] - 0x80) };
    return .{ .len = 0, .cp = 0 };
}

/// Filter terminal-hostile bytes from attacker-derived text: C0 controls
/// (CR and LF included, so no byte forges a new log line), DEL, C1
/// controls, and the hostile bidi and invisible format set that
/// hostileUnit enumerates. Each hostile sequence becomes one visible '?'
/// so redaction gaps stay visible. Clean input borrows without
/// allocation. The filter assumes valid UTF-8: bare 0x80..0x9F bytes and
/// overlong lead bytes pass through, which is inert to a UTF-8 decoder.
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
/// spans, how many output bytes it emits, and which escaped form to
/// write. The classifier owns both counts so the two passes cannot drift.
const JsonEscape = struct {
    consumed: usize,
    emitted: usize,
    kind: Kind,
    named_char: u8 = 0,
    codepoint: u21 = 0,

    const Kind = enum {
        clean, // copy the bytes raw
        named, // two-character escape: backslash plus named_char
        unicode, // \uXXXX (BMP) or the \uDXXX\uDXXX surrogate pair
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
        return .{ .consumed = 1, .emitted = 2, .kind = .named, .named_char = c };
    }
    if (b < 0x20 or b == 0x7F) {
        return .{ .consumed = 1, .emitted = 6, .kind = .unicode, .codepoint = b };
    }
    if (b < 0x80) return .{ .consumed = 1, .emitted = 1, .kind = .clean };
    // Hostile format characters escape as their codepoint: \uXXXX inside
    // the BMP, the RFC 8259 surrogate pair beyond it.
    const hostile = hostileUnit(s);
    if (hostile.len != 0) {
        return .{
            .consumed = hostile.len,
            .emitted = jsonEscapeBytes(hostile.cp),
            .kind = .unicode,
            .codepoint = hostile.cp,
        };
    }
    // Other multi-byte bytes: well-formed sequences pass through whole;
    // invalid bytes become U+FFFD so the document stays strict UTF-8
    // (RFC 8259 section 8.1, EPH-I0580).
    const expect = utf8ExpectLen(b) orelse
        return .{ .consumed = 1, .emitted = 6, .kind = .unicode, .codepoint = 0xFFFD };
    if (!utf8Valid(s, expect))
        return .{ .consumed = 1, .emitted = 6, .kind = .unicode, .codepoint = 0xFFFD };
    return .{ .consumed = expect, .emitted = expect, .kind = .clean };
}

/// Output bytes of a codepoint's JSON escape: 6 for the BMP \uXXXX form,
/// 12 for the astral surrogate pair (RFC 8259 section 7).
fn jsonEscapeBytes(cp: u21) usize {
    return if (cp <= 0xFFFF) 6 else 12;
}

/// Expected UTF-8 sequence length for the lead byte `b` (b >= 0x80), or
/// null when `b` can never start a valid sequence: stray continuation
/// bytes, overlong leads 0xC0/0xC1, and out-of-range leads 0xF5..0xFF.
fn utf8ExpectLen(b: u8) ?usize {
    if (b >= 0xC2 and b <= 0xDF) return 2;
    if (b >= 0xE0 and b <= 0xEF) return 3;
    if (b >= 0xF0 and b <= 0xF4) return 4;
    return null;
}

/// Valid window for the first continuation byte of lead `b`. The narrow
/// entries pin the RFC 3629 range guards: 0xE0 rejects overlong forms,
/// 0xED rejects surrogates, 0xF0 rejects overlong forms, 0xF4 rejects
/// values beyond U+10FFFF.
fn utf8SecondWindow(lead: u8) ByteWindow {
    return switch (lead) {
        0xE0 => .{ .min = 0xA0, .max = 0xBF },
        0xED => .{ .min = 0x80, .max = 0x9F },
        0xF0 => .{ .min = 0x90, .max = 0xBF },
        0xF4 => .{ .min = 0x80, .max = 0x8F },
        else => .{ .min = 0x80, .max = 0xBF },
    };
}

/// True when the bytes at `s` form a well-formed UTF-8 sequence of
/// `expect` bytes: enough input, every continuation byte inside
/// 0x80..0xBF, and the first continuation inside the lead's window.
fn utf8Valid(s: []const u8, expect: usize) bool {
    if (s.len < expect) return false;
    const window = utf8SecondWindow(s[0]);
    if (s[1] < window.min or s[1] > window.max) return false;
    var i: usize = 2;
    while (i < expect) : (i += 1) {
        if (s[i] < 0x80 or s[i] > 0xBF) return false;
    }
    return true;
}

/// Write one escaped unit into `dst`, returning the bytes written. The
/// caller sized `dst` for exactly this unit.
fn writeJsonUnit(dst: []u8, unit: JsonEscape, src: []const u8) usize {
    switch (unit.kind) {
        .clean => {
            @memcpy(dst[0..unit.consumed], src[0..unit.consumed]);
            return unit.consumed;
        },
        .named => {
            dst[0] = '\\';
            dst[1] = unit.named_char;
            return 2;
        },
        .unicode => return writeJsonUnicode(dst, unit.codepoint),
    }
}

/// Write the JSON escape of `cp` into `dst`: `\uXXXX` (uppercase hex) for
/// a BMP codepoint, the `\uDXXX\uDXXX` surrogate pair for an astral one
/// (RFC 8259 section 7). Returns the bytes written.
fn writeJsonUnicode(dst: []u8, cp: u21) usize {
    if (cp <= 0xFFFF) {
        dst[0] = '\\';
        dst[1] = 'u';
        writeHex4(dst[2..6], @intCast(cp));
        return 6;
    }
    const pair = cp - 0x10000;
    dst[0] = '\\';
    dst[1] = 'u';
    writeHex4(dst[2..6], @intCast(0xD800 + (pair >> 10)));
    dst[6] = '\\';
    dst[7] = 'u';
    writeHex4(dst[8..12], @intCast(0xDC00 + (pair & 0x3FF)));
    return 12;
}

/// Write four uppercase hex digits of `v` into `dst`.
fn writeHex4(dst: []u8, v: u16) void {
    const hex = "0123456789ABCDEF";
    dst[0] = hex[(v >> 12) & 0xF];
    dst[1] = hex[(v >> 8) & 0xF];
    dst[2] = hex[(v >> 4) & 0xF];
    dst[3] = hex[v & 0xF];
}

/// Escape a string for embedding in JSON output: quotes, backslashes, and
/// control bytes use the standard escapes, bidi or invisible format
/// characters escape as \uXXXX (the surrogate-pair form beyond the BMP;
/// legal raw in JSON but hostile to humans and downstream tools), and
/// invalid UTF-8 bytes become \uFFFD so the document always satisfies
/// RFC 8259 section 8.1. Clean input borrows without allocation.
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
        out_len += unit.emitted;
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

/// Scan mode for the string/char-literal classifiers. `mline` is sticky: a
/// `\\` multiline opener swallows the rest of its line, so no later byte on
/// the line can leave string data (EPH-I0671).
const QuoteMode = enum { none, str, char, mline };

/// Advance the quote scan past one char. A backslash inside a literal also
/// skips the escaped char, so `i` can move two steps.
fn stepQuoteMode(mode: *QuoteMode, line: []const u8, i: *usize) void {
    const c = line[i.*];
    switch (mode.*) {
        .char => {
            if (c == '\\') i.* += 1;
            if (c == '\'') mode.* = .none;
        },
        .str => {
            if (c == '\\') i.* += 1;
            if (c == '"') mode.* = .none;
        },
        .mline => {},
        .none => {
            if (isMultilineOpenerAt(line, i.*)) mode.* = .mline;
            if (c == '\'') mode.* = .char;
            if (c == '"') mode.* = .str;
        },
    }
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

/// The hostile-set battery (EPH-I0579): every codepoint the filter claims,
/// expressed as inclusive ranges. The U+2060 range spans the unassigned
/// U+2065, which the filter covers conservatively.
const hostile_ranges = [_]struct { from: u21, to: u21 }{
    .{ .from = 0x061C, .to = 0x061C },
    .{ .from = 0x00AD, .to = 0x00AD },
    .{ .from = 0x200B, .to = 0x200F },
    .{ .from = 0x2028, .to = 0x202E },
    .{ .from = 0x2060, .to = 0x206F },
    .{ .from = 0xFEFF, .to = 0xFEFF },
    .{ .from = 0xFFF9, .to = 0xFFFB },
    .{ .from = 0xE0001, .to = 0xE0001 },
    .{ .from = 0xE0020, .to = 0xE007F },
};

/// Feed every hostile codepoint through one placeholder sanitizer and
/// assert the whole character collapses to `want`.
fn expectHostileSet(
    sanitize: fn (Allocator, []const u8) error{OutOfMemory}!Sanitized,
    want: []const u8,
    allocator: Allocator,
) !void {
    for (hostile_ranges) |r| {
        var cp = r.from;
        while (cp <= r.to) : (cp += 1) {
            const input = try std.fmt.allocPrint(allocator, "a{u}b", .{cp});
            defer allocator.free(input);
            var result = try sanitize(allocator, input);
            defer result.deinit(allocator);
            try std.testing.expectEqualStrings(want, result.slice);
        }
    }
}

test "sanitizeTerminal filters the full hostile set (EPH-I0579)" {
    try expectHostileSet(sanitizeTerminal, "a?b", std.testing.allocator);
}

test "sanitizeMarkdown filters the full hostile set (EPH-I0579)" {
    try expectHostileSet(sanitizeMarkdown, "a?b", std.testing.allocator);
}

test "sanitizeSnippet filters the full hostile set (EPH-I0579)" {
    try expectHostileSet(sanitizeSnippet, "a?b", std.testing.allocator);
}

test "escapeJson escapes the full hostile set (EPH-I0579)" {
    const allocator = std.testing.allocator;
    for (hostile_ranges) |r| {
        var cp = r.from;
        while (cp <= r.to) : (cp += 1) {
            const input = try std.fmt.allocPrint(allocator, "a{u}b", .{cp});
            defer allocator.free(input);
            var result = try escapeJson(allocator, input);
            defer result.deinit(allocator);
            // BMP members escape as \uXXXX; astral members as the RFC
            // 8259 section 7 surrogate pair.
            if (cp <= 0xFFFF) {
                const want = try std.fmt.allocPrint(allocator, "a\\u{X:0>4}b", .{cp});
                defer allocator.free(want);
                try std.testing.expectEqualStrings(want, result.slice);
            } else {
                const pair = cp - 0x10000;
                const hi: u16 = @intCast(0xD800 + (pair >> 10));
                const lo: u16 = @intCast(0xDC00 + (pair & 0x3FF));
                const want = try std.fmt.allocPrint(allocator, "a\\u{X:0>4}\\u{X:0>4}b", .{ hi, lo });
                defer allocator.free(want);
                try std.testing.expectEqualStrings(want, result.slice);
            }
        }
    }
}

test "escapeJson astral escapes re-parse to the original text (EPH-I0579)" {
    // The surrogate-pair escape must decode back to the original astral
    // codepoint in a strict JSON consumer.
    const allocator = std.testing.allocator;
    for ([_]u21{ 0xE0001, 0xE0020, 0xE003F, 0xE0040, 0xE007F }) |cp| {
        const input = try std.fmt.allocPrint(allocator, "a{u}b", .{cp});
        defer allocator.free(input);
        var result = try escapeJson(allocator, input);
        defer result.deinit(allocator);
        const wrapped = try std.fmt.allocPrint(allocator, "\"{s}\"", .{result.slice});
        defer allocator.free(wrapped);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, wrapped, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(input, parsed.value.string);
    }
}

test "escapeJson replaces invalid lead bytes with U+FFFD (EPH-I0580)" {
    // Bare lead bytes followed by non-matching bytes must not pass raw:
    // the lead becomes one \uFFFD and the trailing bytes classify on
    // their own, matching the truncated-tail behavior.
    const cases = [_]struct { input: []const u8, want: []const u8 }{
        .{ .input = "\xE2\x41\x42", .want = "\\uFFFDAB" },
        .{ .input = "x\xC2\x41y", .want = "x\\uFFFDAy" },
        .{ .input = "\xC2\x41\xC2\x85", .want = "\\uFFFDA\\u0085" },
        .{ .input = "\x80", .want = "\\uFFFD" },
        .{ .input = "a\x80b", .want = "a\\uFFFDb" },
        .{ .input = "\xC0\x41", .want = "\\uFFFDA" },
        .{ .input = "\xF5\x80\x80\x80", .want = "\\uFFFD\\uFFFD\\uFFFD\\uFFFD" },
        .{ .input = "\xE0\x80\x80", .want = "\\uFFFD\\uFFFD\\uFFFD" },
        .{ .input = "\xED\xA0\x80", .want = "\\uFFFD\\uFFFD\\uFFFD" },
        .{ .input = "\xF0\x80\x80\x80", .want = "\\uFFFD\\uFFFD\\uFFFD\\uFFFD" },
        .{ .input = "\xF4\x90\x80\x80", .want = "\\uFFFD\\uFFFD\\uFFFD\\uFFFD" },
        .{ .input = "\xE1\x80", .want = "\\uFFFD\\uFFFD" },
        // Tag-lead bytes with an out-of-range fourth byte are invalid
        // UTF-8: the lead falls to the validator and each byte becomes
        // U+FFFD (EPH-I1120).
        .{ .input = "\xF3\xA0\x80\xC5", .want = "\\uFFFD\\uFFFD\\uFFFD\\uFFFD" },
        .{ .input = "\xF3\xA0\x81\xC5", .want = "\\uFFFD\\uFFFD\\uFFFD\\uFFFD" },
        // Truncated hostile tails consume the rest as one U+FFFD, the
        // long-standing terminal-filter behavior on the JSON side.
        .{ .input = "ab\xE2\x80", .want = "ab\\uFFFD" },
        .{ .input = "x\xC2", .want = "x\\uFFFD" },
        .{ .input = "\xEF\xBB", .want = "\\uFFFD" },
        .{ .input = "\xF3\xA0\x80", .want = "\\uFFFD" },
    };
    for (cases) |case| {
        var result = try escapeJson(std.testing.allocator, case.input);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.want, result.slice);
    }
}

test "escapeJson passes valid multi-byte UTF-8 through raw (EPH-I0580)" {
    // Well-formed sequences stay byte-identical and borrow the input.
    const cases = [_][]const u8{
        "\xC2\xA9", // U+00A9 copyright
        "\xC2\xA0", // U+00A0 no-break space
        "\xE2\x82\xAC", // U+20AC euro
        "\xE1\x80\x80", // U+1000
        "\xE2\x80\x90", // U+2010 hyphen (hostile-set neighbor)
        "\xF0\x9F\x98\x80", // U+1F600 emoji
        "\xF3\xA0\x80\x82", // U+E0002 unassigned tag gap
    };
    for (cases) |input| {
        var result = try escapeJson(std.testing.allocator, input);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.owned);
        try std.testing.expectEqual(input.ptr, result.slice.ptr);
    }
}

test "skipWhitespace skips blanks and stops at code" {
    try std.testing.expectEqual(@as(usize, 5), skipWhitespace("  \t\r\nab", 0));
    try std.testing.expectEqual(@as(usize, 0), skipWhitespace("ab  ", 0));
    try std.testing.expectEqual(@as(usize, 2), skipWhitespace("  x", 1));
    try std.testing.expectEqual(@as(usize, 3), skipWhitespace("abc", 3));
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
