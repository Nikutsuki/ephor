// Rhyos Labs - Ephor
// Output sanitization: terminal, JSON, and markdown-export filters.
// Copyright (C) 2025 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

//! Output sanitization lives here, split out of types.zig so each file
//! stays under the 256 KiB ZA111 input cap (EPH-I1123): the file that
//! implements the memory rule must stay small enough for the rule to
//! analyze it. The split is mechanical: no behavior changed.
//! types.zig re-exports Sanitized, sanitizeTerminal, escapeJson,
//! sanitizeMarkdown, and sanitizeSnippet so the types.* API surface is
//! unchanged.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

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
/// format set (EPH-I0579, EPH-I0217): U+061C Arabic Letter Mark, U+00AD
/// soft hyphen, U+0600..U+0605 Arabic number signs, U+06DD End of Ayah,
/// U+070F Syriac Abbreviation Mark, U+0890..U+0891 Arabic pound and
/// piastre marks, U+08E2 disputed End of Ayah, U+180E Mongolian Vowel
/// Separator, U+200B..U+200F zero-width and bidi marks, U+2028/U+2029
/// line and paragraph separators, U+202A..U+202E bidi embeddings and
/// overrides, U+2060..U+206F invisible operators, bidi isolates, and
/// deprecated shaping marks (the unassigned U+2065 included: filtering
/// it is free and conservative), U+FE00..U+FE0F variation selectors
/// (Mn class, invisible shaping marks — outside Cf but named by
/// EPH-I0217's evidence), U+FEFF BOM, U+FFF9..U+FFFB interlinear
/// annotation anchors, the Kaithi number signs U+110BD/U+110CD, the
/// Egyptian hieroglyph format controls U+13430..U+1343F, the shorthand
/// format letters U+1BCA0..U+1BCA3, the musical symbol controls
/// U+1D173..U+1D17A, and the tag characters U+E0001 and
/// U+E0020..U+E007F. A truncated lead consumes the rest (invalid UTF-8
/// regardless) and reports U+FFFD. Shared by the terminal filter and the
/// JSON escaper so both reject the same set.
/// Hostile-unit classifiers indexed by lead byte. The comptime table keeps
/// the dispatcher at one branch (the dogfood ratchet stays flat, and the
/// EPH-I0217 extension doubles the hostile lead count without touching the
/// dispatch complexity). The slots are `*const fn` pointers: a bare `fn`
/// type is comptime-only, and the dispatcher indexes with a runtime byte.
const hostile_leads = blk: {
    var table = [_]?*const fn ([]const u8) HostileUnit{null} ** 256;
    table[0xC2] = c2Unit;
    table[0xD8] = d8Unit;
    table[0xDB] = dbUnit;
    table[0xDC] = dcUnit;
    table[0xE0] = e0Unit;
    table[0xE1] = e1Unit;
    table[0xE2] = formatUnit;
    table[0xEF] = efUnit;
    table[0xF0] = f0Unit;
    table[0xF3] = tagUnit;
    break :blk table;
};

/// Classify the byte at `s[0]` against the hostile set (the classifier
/// table above). A hostile sequence reports its length and codepoint. A
/// Clean byte reports len 0.
fn hostileUnit(s: []const u8) HostileUnit {
    const unit_fn = hostile_leads[s[0]] orelse return .{ .len = 0, .cp = 0 };
    return unit_fn(s);
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

/// U+0600..U+0605 Arabic number signs and U+061C Arabic Letter Mark
/// (bidi) under the 0xD8 lead.
fn d8Unit(s: []const u8) HostileUnit {
    if (s.len < 2) return .{ .len = s.len, .cp = 0xFFFD };
    if (s[1] >= 0x80 and s[1] <= 0x85)
        return .{ .len = 2, .cp = 0x0600 + @as(u21, s[1] - 0x80) };
    if (s[1] == 0x9C) return .{ .len = 2, .cp = 0x061C };
    return .{ .len = 0, .cp = 0 };
}

/// U+06DD Arabic End of Ayah under the 0xDB lead.
fn dbUnit(s: []const u8) HostileUnit {
    if (s.len < 2) return .{ .len = s.len, .cp = 0xFFFD };
    if (s[1] == 0x9D) return .{ .len = 2, .cp = 0x06DD };
    return .{ .len = 0, .cp = 0 };
}

/// U+070F Syriac Abbreviation Mark under the 0xDC lead.
fn dcUnit(s: []const u8) HostileUnit {
    if (s.len < 2) return .{ .len = s.len, .cp = 0xFFFD };
    if (s[1] == 0x8F) return .{ .len = 2, .cp = 0x070F };
    return .{ .len = 0, .cp = 0 };
}

/// U+0890..U+0891 Arabic pound and piastre marks and U+08E2 disputed End
/// of Ayah under the 0xE0 lead.
fn e0Unit(s: []const u8) HostileUnit {
    if (s.len < 3) return .{ .len = s.len, .cp = 0xFFFD };
    if (s[1] == 0xA2 and s[2] >= 0x90 and s[2] <= 0x91)
        return .{ .len = 3, .cp = 0x0890 + @as(u21, s[2] - 0x90) };
    if (s[1] == 0xA3 and s[2] == 0xA2) return .{ .len = 3, .cp = 0x08E2 };
    return .{ .len = 0, .cp = 0 };
}

/// U+180E Mongolian Vowel Separator under the 0xE1 lead.
fn e1Unit(s: []const u8) HostileUnit {
    if (s.len < 3) return .{ .len = s.len, .cp = 0xFFFD };
    if (s[1] == 0xA0 and s[2] == 0x8E) return .{ .len = 3, .cp = 0x180E };
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

/// U+FE00..U+FE0F variation selectors (invisible shaping marks, Mn class
/// but named by EPH-I0217's evidence), U+FEFF BOM, and U+FFF9..U+FFFB
/// interlinear annotation anchors under the 0xEF lead.
fn efUnit(s: []const u8) HostileUnit {
    if (s.len < 3) return .{ .len = s.len, .cp = 0xFFFD };
    if (s[1] == 0xB8 and s[2] >= 0x80 and s[2] <= 0x8F)
        return .{ .len = 3, .cp = 0xFE00 + @as(u21, s[2] - 0x80) };
    if (s[1] == 0xBB and s[2] == 0xBF) return .{ .len = 3, .cp = 0xFEFF };
    if (s[1] == 0xBF and s[2] >= 0xB9 and s[2] <= 0xBB)
        return .{ .len = 3, .cp = 0xFFF9 + @as(u21, s[2] - 0xB9) };
    return .{ .len = 0, .cp = 0 };
}

/// The Kaithi number signs U+110BD/U+110CD, the Egyptian hieroglyph
/// format controls U+13430..U+1343F, the shorthand format letters
/// U+1BCA0..U+1BCA3, and the musical symbol controls U+1D173..U+1D17A
/// under the 0xF0 lead.
fn f0Unit(s: []const u8) HostileUnit {
    if (s.len < 4) return .{ .len = s.len, .cp = 0xFFFD };
    if (s[1] == 0x91 and s[2] == 0x82 and s[3] == 0xBD)
        return .{ .len = 4, .cp = 0x110BD };
    if (s[1] == 0x91 and s[2] == 0x83 and s[3] == 0x8D)
        return .{ .len = 4, .cp = 0x110CD };
    if (s[1] == 0x93 and s[2] == 0x90 and s[3] >= 0xB0 and s[3] <= 0xBF)
        return .{ .len = 4, .cp = 0x13430 + @as(u21, s[3] - 0xB0) };
    if (s[1] == 0x9B and s[2] == 0xB2 and s[3] >= 0xA0 and s[3] <= 0xA3)
        return .{ .len = 4, .cp = 0x1BCA0 + @as(u21, s[3] - 0xA0) };
    if (s[1] == 0x9D and s[2] == 0x85 and s[3] >= 0xB3 and s[3] <= 0xBA)
        return .{ .len = 4, .cp = 0x1D173 + @as(u21, s[3] - 0xB3) };
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
    return twoPassSanitize(allocator, input, terminalUnit, writePlaceholderOrCopy);
}

/// Classify the unit at `s[0]` for sanitizeTerminal: every unit emits
/// one output byte, and a hostile sequence consumes its full UTF-8 run.
fn terminalUnit(s: []const u8) SanitizeUnit {
    const skip = hostileSeqLen(s);
    if (skip == 0) return .{ .consumed = 1, .emitted = 1 };
    return .{ .consumed = skip, .emitted = 1, .dirty = true };
}

/// Writer shared by sanitizeTerminal and sanitizeSnippet: a changed unit
/// becomes one '?' per emitted byte. A clean unit copies its bytes raw.
fn writePlaceholderOrCopy(dst: []u8, src: []const u8, unit: SanitizeUnit) usize {
    if (unit.dirty) {
        @memset(dst[0..unit.emitted], '?');
    } else {
        @memcpy(dst[0..unit.emitted], src[0..unit.emitted]);
    }
    return unit.emitted;
}

/// One classified input unit for the two-pass sanitizers: the input
/// bytes the unit spans, the output bytes it emits, the escaped form to
/// write (JSON only), and whether the unit changes under sanitization.
/// The classifier owns both counts so the two passes cannot drift. The
/// terminal, markdown, and snippet units use only the first three
/// fields. The JSON units use the rest.
const SanitizeUnit = struct {
    consumed: usize,
    emitted: usize,
    dirty: bool = false,
    kind: Kind = .clean,
    named_char: u8 = 0,
    codepoint: u21 = 0,

    const Kind = enum {
        clean, // copy the bytes raw
        named, // two-character escape: backslash plus named_char
        unicode, // \uXXXX (BMP) or the \uDXXX\uDXXX surrogate pair
    };
};

/// Shared two-pass body: classify every input unit to size the output,
/// borrow the input when nothing changed, then classify again to write.
/// Each sanitizer supplies only its classifier and writer. The loop, the
/// borrow-or-allocate decision, and the allocation discipline live here
/// once (EPH-I1232: four sibling copies collapsed).
fn twoPassSanitize(
    allocator: Allocator,
    input: []const u8,
    classify: *const fn ([]const u8) SanitizeUnit,
    write: *const fn ([]u8, []const u8, SanitizeUnit) usize,
) error{OutOfMemory}!Sanitized {
    var out_len: usize = 0;
    var dirty = false;
    var i: usize = 0;
    while (i < input.len) {
        const unit = classify(input[i..]);
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
        const unit = classify(input[i..]);
        o += write(buf[o..], input[i..], unit);
        i += unit.consumed;
    }
    return .{ .slice = buf, .owned = true };
}

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
fn classifyJsonUnit(s: []const u8) SanitizeUnit {
    const b = s[0];
    if (jsonNamedEscape(b)) |c| {
        return .{ .consumed = 1, .emitted = 2, .kind = .named, .named_char = c, .dirty = true };
    }
    if (b < 0x20 or b == 0x7F) {
        return .{ .consumed = 1, .emitted = 6, .kind = .unicode, .codepoint = b, .dirty = true };
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
            .dirty = true,
        };
    }
    // Other multi-byte bytes: well-formed sequences pass through whole.
    // Invalid bytes become U+FFFD so the document stays strict UTF-8
    // (RFC 8259 section 8.1, EPH-I0580).
    const expect = utf8ExpectLen(b) orelse return invalidJsonUnit();
    if (!utf8Valid(s, expect)) return invalidJsonUnit();
    return .{ .consumed = expect, .emitted = expect, .kind = .clean };
}

/// One invalid-byte unit: a single input byte becomes the six-byte
/// \uFFFD escape.
fn invalidJsonUnit() SanitizeUnit {
    return .{
        .consumed = 1,
        .emitted = 6,
        .kind = .unicode,
        .codepoint = 0xFFFD,
        .dirty = true,
    };
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
fn writeJsonUnit(dst: []u8, src: []const u8, unit: SanitizeUnit) usize {
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
/// characters escape as \uXXXX (the surrogate-pair form beyond the BMP,
/// legal raw in JSON but hostile to humans and downstream tools), and
/// invalid UTF-8 bytes become \uFFFD so the document always satisfies
/// RFC 8259 section 8.1. Clean input borrows without allocation.
pub fn escapeJson(
    allocator: Allocator,
    input: []const u8,
) error{OutOfMemory}!Sanitized {
    return twoPassSanitize(allocator, input, classifyJsonUnit, writeJsonUnit);
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
    return twoPassSanitize(allocator, input, markdownUnit, writeMarkdownUnit);
}

/// Classify the unit at `s[0]` for sanitizeMarkdown: a hostile sequence
/// collapses to one placeholder, a metacharacter escapes to two output
/// bytes, and a clean byte copies raw.
fn markdownUnit(s: []const u8) SanitizeUnit {
    const skip = hostileSeqLen(s);
    if (skip != 0) return .{ .consumed = skip, .emitted = 1, .dirty = true };
    if (isMarkdownMeta(s[0])) return .{ .consumed = 1, .emitted = 2, .dirty = true };
    return .{ .consumed = 1, .emitted = 1 };
}

/// Writer for sanitizeMarkdown: a metacharacter unit escapes with a
/// backslash, every other changed unit (hostile) collapses to '?', and a
/// clean unit copies raw. The metacharacter test reads `src[0]`: hostile
/// bytes never sit in the markdown set, so the test discriminates
/// exactly.
fn writeMarkdownUnit(dst: []u8, src: []const u8, unit: SanitizeUnit) usize {
    if (!unit.dirty) {
        @memcpy(dst[0..unit.emitted], src[0..unit.emitted]);
        return unit.emitted;
    }
    if (isMarkdownMeta(src[0])) {
        dst[0] = '\\';
        dst[1] = src[0];
        return unit.emitted;
    }
    dst[0] = '?';
    return unit.emitted;
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
    return twoPassSanitize(allocator, input, snippetUnit, writePlaceholderOrCopy);
}

/// Classify the unit at `s[0]` for sanitizeSnippet: hostile sequences
/// collapse to one placeholder. Backtick runs keep their length either
/// way, marked dirty from three backticks up.
fn snippetUnit(s: []const u8) SanitizeUnit {
    const skip = hostileSeqLen(s);
    if (skip != 0) {
        return .{ .consumed = skip, .emitted = 1, .dirty = true };
    }
    if (s[0] != '`') return .{ .consumed = 1, .emitted = 1 };
    const run = backtickRun(s);
    return .{ .consumed = run, .emitted = run, .dirty = run >= 3 };
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

/// The hostile-set battery (EPH-I0579, EPH-I0217): every codepoint the
/// filter claims, expressed as inclusive ranges. The U+2060 range spans
/// the unassigned U+2065, which the filter covers conservatively, and the
/// U+FE00 range covers the Mn-class variation selectors named by the
/// EPH-I0217 evidence. The set is the full Unicode Cf class (Unicode 16)
/// plus the variation selectors.
const hostile_ranges = [_]struct { from: u21, to: u21 }{
    .{ .from = 0x061C, .to = 0x061C },
    .{ .from = 0x00AD, .to = 0x00AD },
    .{ .from = 0x0600, .to = 0x0605 },
    .{ .from = 0x06DD, .to = 0x06DD },
    .{ .from = 0x070F, .to = 0x070F },
    .{ .from = 0x0890, .to = 0x0891 },
    .{ .from = 0x08E2, .to = 0x08E2 },
    .{ .from = 0x180E, .to = 0x180E },
    .{ .from = 0x200B, .to = 0x200F },
    .{ .from = 0x2028, .to = 0x202E },
    .{ .from = 0x2060, .to = 0x206F },
    .{ .from = 0xFE00, .to = 0xFE0F },
    .{ .from = 0xFEFF, .to = 0xFEFF },
    .{ .from = 0xFFF9, .to = 0xFFFB },
    .{ .from = 0x110BD, .to = 0x110BD },
    .{ .from = 0x110CD, .to = 0x110CD },
    .{ .from = 0x13430, .to = 0x1343F },
    .{ .from = 0x1BCA0, .to = 0x1BCA3 },
    .{ .from = 0x1D173, .to = 0x1D17A },
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

test "sanitizeTerminal filters the EPH-I0217 Cf members (spot pins)" {
    // One spot pin per new lead the EPH-I0217 extension added, beside the
    // battery that walks every range. Each invisible character collapses
    // to one visible placeholder.
    const cases = [_]struct { input: []const u8, want: []const u8 }{
        .{ .input = "a\xD8\x80b", .want = "a?b" }, // U+0600 Arabic Number Sign
        .{ .input = "a\xDB\x9Db", .want = "a?b" }, // U+06DD End of Ayah
        .{ .input = "a\xDC\x8Fb", .want = "a?b" }, // U+070F Syriac Abbreviation Mark
        .{ .input = "a\xE0\xA2\x90b", .want = "a?b" }, // U+0890 Arabic Pound Mark Above
        .{ .input = "a\xE0\xA3\xA2b", .want = "a?b" }, // U+08E2 Disputed End of Ayah
        .{ .input = "a\xE1\xA0\x8Eb", .want = "a?b" }, // U+180E Mongolian Vowel Separator
        .{ .input = "a\xEF\xB8\x8Fb", .want = "a?b" }, // U+FE0F Variation Selector-16
        .{ .input = "a\xF0\x91\x82\xBDb", .want = "a?b" }, // U+110BD Kaithi Number Sign
        .{ .input = "a\xF0\x93\x90\xBFb", .want = "a?b" }, // U+1343F hieroglyph control
        .{ .input = "a\xF0\x9B\xB2\xA0b", .want = "a?b" }, // U+1BCA0 Shorthand Format
        .{ .input = "a\xF0\x9D\x85\xBAb", .want = "a?b" }, // U+1D17A Musical Symbol
    };
    for (cases) |case| {
        var result = try sanitizeTerminal(std.testing.allocator, case.input);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.want, result.slice);
    }
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
            // BMP members escape as \uXXXX. Astral members as the RFC
            // 8259 section 7 surrogate pair.
            if (cp <= 0xFFFF) {
                const want = try std.fmt.allocPrint(allocator, "a\\u{X:0>4}b", .{cp});
                defer allocator.free(want);
                try std.testing.expectEqualStrings(want, result.slice);
            } else {
                const pair = cp - 0x10000;
                const hi: u16 = @intCast(0xD800 + (pair >> 10));
                const lo: u16 = @intCast(0xDC00 + (pair & 0x3FF));
                const want = try std.fmt.allocPrint(
                    allocator,
                    "a\\u{X:0>4}\\u{X:0>4}b",
                    .{ hi, lo },
                );
                defer allocator.free(want);
                try std.testing.expectEqualStrings(want, result.slice);
            }
        }
    }
}

test "escapeJson astral escapes re-parse to the original text (EPH-I0579)" {
    // The surrogate-pair escape must decode back to the original astral
    // codepoint in a strict JSON consumer. The I0217 members pin the new
    // astral leads (Kaithi, musical symbols) on the same property.
    const allocator = std.testing.allocator;
    for ([_]u21{ 0xE0001, 0xE0020, 0xE003F, 0xE0040, 0xE007F, 0x110BD, 0x1D173 }) |cp| {
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
        // Tag-lead bytes with an out-of-range fourth byte are invalid
        // UTF-8: the lead falls to the validator and each byte becomes
        // U+FFFD (EPH-I1120).
        .{ .input = "\xF3\xA0\x80\xC5", .want = "\\uFFFD\\uFFFD\\uFFFD\\uFFFD" },
        .{ .input = "\xF3\xA0\x81\xC5", .want = "\\uFFFD\\uFFFD\\uFFFD\\uFFFD" },
        // Truncated hostile tails consume the rest as one U+FFFD, the
        // long-standing terminal-filter behavior on the JSON side. The
        // EPH-I0217 leads join the same policy: a truncated 0xE1 lead is
        // one U+FFFD like the pre-existing 0xE2/0xEF/0xF3 forms.
        .{ .input = "ab\xE2\x80", .want = "ab\\uFFFD" },
        .{ .input = "x\xC2", .want = "x\\uFFFD" },
        .{ .input = "\xEF\xBB", .want = "\\uFFFD" },
        .{ .input = "\xF3\xA0\x80", .want = "\\uFFFD" },
        .{ .input = "\xE1\x80", .want = "\\uFFFD" },
        .{ .input = "\xF0\x91\x82", .want = "\\uFFFD" },
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
