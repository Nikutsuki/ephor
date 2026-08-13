// Rhyos Labs - Ephor
// Shared vocabulary types for Zig stdlib knowledge
// Copyright (C) 2025-2026 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

//! Vocabulary types for version-specific Zig stdlib patterns.
//!
//! These struct types define the shape of vocabulary entries used by
//! version-specific modules (v0_15.zig, v0_16.zig, etc.) to describe
//! Zig stdlib allocator types, methods, and patterns.
//!
//! No data lives here — only types. Data is in version-specific files.

/// Zig stdlib allocator type (e.g. ArenaAllocator, GeneralPurposeAllocator)
pub const AllocatorType = struct {
    /// Short name: "ArenaAllocator"
    name: []const u8,
    /// Fully qualified: "std.heap.ArenaAllocator"
    full_path: []const u8,
    /// Init pattern for line matching: "ArenaAllocator.init("
    init_pattern: []const u8,
    /// false for arena/FBA (no per-allocation free needed), true for GPA etc.
    needs_free: bool,
    /// Cleanup method: ".deinit()" or "" if none required
    cleanup_method: []const u8,
};

/// Zig stdlib global singleton allocator (e.g. page_allocator, c_allocator)
pub const GlobalAllocator = struct {
    /// Short name: "page_allocator"
    name: []const u8,
    /// Fully qualified: "std.heap.page_allocator"
    full_path: []const u8,
    /// Raw global allocators always need per-allocation free
    needs_free: bool,
};

/// Allocator method that produces owned memory (e.g. .alloc, .create, .dupe)
pub const AllocMethod = struct {
    /// Pattern for line matching: ".alloc("
    pattern: []const u8,
    /// Identifier name: "alloc" (for function-name matching)
    short_name: []const u8,
    /// true for alloc/dupe (returns []T), false for create (returns *T)
    returns_slice: bool,
    /// Matching cleanup: ".free(" for slices, ".destroy(" for pointers
    cleanup: []const u8,
};

/// Cleanup/deallocation method (e.g. .free, .destroy, .deinit)
pub const CleanupMethod = struct {
    /// Pattern for line matching: ".free("
    pattern: []const u8,
    /// true if return value is void (safe to discard)
    is_void: bool,
};

/// Stdlib container method that may transfer ownership (e.g. .append, .put)
pub const ContainerMethod = struct {
    /// Pattern for line matching: ".append("
    pattern: []const u8,
    /// true if method stores/consumes the passed value
    takes_ownership: bool,
    /// true if method returns void
    is_void: bool,
};

/// Stdlib method whose return value is safe to discard (void, T, or ?T — not !T)
/// Used by isSafeToDiscard and isSafeBuiltin
pub const SafeMethod = struct {
    /// Pattern for line matching: ".clear("
    pattern: []const u8,
    /// true if method returns void (known void)
    is_void: bool,
};

/// A deprecated pattern and its modern replacement.
/// Shared so every version module's checkDeprecated returns the same type.
pub const DeprecatedPattern = struct {
    /// Text to match: "std.ChildProcess"
    pattern: []const u8,
    /// Replacement text for the diagnostic
    replacement: []const u8,
    /// Rule identifier for the diagnostic: "ZAV102"
    rule: []const u8,
};
