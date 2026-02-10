// Zig Version Compatibility Layer
//
// This module provides version-specific API compatibility for Ephor.
// To add support for a new Zig version:
//   1. Create a new file: vX_YZ.zig (e.g., v0_17.zig)
//   2. Implement all the required arrays and functions
//   3. Add import below and register in version_registry
//
// The linter will automatically detect the Zig version and use the appropriate
// compatibility layer.
//
// Each version module exports:
//   - builtins: All @builtin functions
//   - optional_methods: Methods returning ?T (safe to discard)
//   - error_methods: Methods returning !T (should not be discarded)
//   - alloc_patterns: Allocation method patterns
//   - create_patterns: Create method patterns
//   - free_patterns: Deallocation patterns
//   - destroy_patterns: Destroy method patterns
//   - panic_patterns: Patterns that may cause runtime panics
//   - undefined_patterns: Undefined usage patterns
//   - keywords: Language keywords
//   - breaking_changes: Changes from previous version
//   - deprecated_patterns: Old patterns needing updates
//   - std_modules: Standard library module structure
//   - Helper functions for pattern checking

const std = @import("std");
const builtin = @import("builtin");

// Import all supported version modules
pub const v0_15 = @import("v0_15.zig");
pub const v0_16 = @import("v0_16.zig");

/// Version information parsed from Zig version string
pub const VersionInfo = struct {
    major: u16,
    minor: u16,
    patch: u16,
    dev: bool,

    pub fn format(
        self: VersionInfo,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{d}.{d}.{d}", .{
            self.major,
            self.minor,
            self.patch,
        });
        if (self.dev) try writer.writeAll("-dev");
    }
};

/// Parse version string like "0.15.2" or "0.16.0-dev"
pub fn parseVersion(version_str: []const u8) !VersionInfo {
    var info = VersionInfo{ .major = 0, .minor = 0, .patch = 0, .dev = false };

    // Check for -dev suffix
    var str = version_str;
    if (std.mem.endsWith(u8, str, "-dev")) {
        info.dev = true;
        str = str[0 .. str.len - 4];
    }

    var parts = std.mem.splitScalar(u8, str, '.');
    if (parts.next()) |major| {
        info.major = std.fmt.parseInt(u16, major, 10) catch 0;
    }
    if (parts.next()) |minor| {
        info.minor = std.fmt.parseInt(u16, minor, 10) catch 0;
    }
    if (parts.next()) |patch| {
        info.patch = std.fmt.parseInt(u16, patch, 10) catch 0;
    }

    return info;
}

/// Get the current Zig version at comptime
pub fn getCurrentVersion() VersionInfo {
    return comptime parseVersion(builtin.zig_version_string) catch .{
        .major = 0,
        .minor = 0,
        .patch = 0,
        .dev = false,
    };
}

/// Version compatibility interface
/// Each version module must export these functions
pub const VersionCompat = struct {
    /// Version identifier (e.g., "0.15", "0.16")
    version_id: []const u8,

    /// Minimum supported patch version
    min_patch: u16,

    /// Maximum supported patch version (255 = any)
    max_patch: u16,

    /// HashMap put signature changed between versions
    /// True if hashmap.put takes (allocator, key, value) vs (key, value)
    hashmap_put_has_allocator: bool,

    /// ArrayList append signature
    /// Returns true if append takes (allocator, item) vs (item)
    arraylist_append_has_allocator: bool,

    /// Get version-specific notes for diagnostics
    notes: []const u8,
};

/// Registry of all supported Zig versions
/// Add new versions here - order from newest to oldest
pub const version_registry = [_]VersionCompat{
    // Zig 0.16.x (future)
    .{
        .version_id = "0.16",
        .min_patch = 0,
        .max_patch = 255,
        .hashmap_put_has_allocator = false,
        .arraylist_append_has_allocator = true,
        .notes = "Zig 0.16.x - API changes TBD",
    },
    // Zig 0.15.x (current)
    .{
        .version_id = "0.15",
        .min_patch = 0,
        .max_patch = 255,
        .hashmap_put_has_allocator = false,
        .arraylist_append_has_allocator = true,
        .notes = "Zig 0.15.x - ArrayList.append(allocator, item)",
    },
};

/// Get compatibility info for the current Zig version
pub fn getCompat() ?VersionCompat {
    const version = getCurrentVersion();
    return getCompatForVersion(version);
}

/// Get compatibility info for a specific version
pub fn getCompatForVersion(version: VersionInfo) ?VersionCompat {
    for (version_registry) |compat| {
        // Parse the version_id
        var parts = std.mem.splitScalar(u8, compat.version_id, '.');
        const major_str = parts.next() orelse "0";
        const minor_str = parts.next() orelse "0";
        const reg_major = std.fmt.parseInt(u16, major_str, 10) catch 0;
        const reg_minor = std.fmt.parseInt(u16, minor_str, 10) catch 0;

        if (version.major == reg_major and version.minor == reg_minor) {
            const in_range = version.patch >= compat.min_patch and
                version.patch <= compat.max_patch;
            if (in_range) return compat;
        }
    }
    return null;
}

/// Check if current Zig version is supported
pub fn isVersionSupported() bool {
    return getCompat() != null;
}

/// Get human-readable version support string
pub fn getSupportedVersionsString() []const u8 {
    return "0.15.x, 0.16.x";
}

// ============================================================================
// Version-aware pattern checking functions
// These delegate to the appropriate version module
// ============================================================================

/// Check if line contains an optional-returning method (version-aware)
/// Used by ZA205/ZA201 analyzers to avoid false positives
pub fn containsOptionalMethod(line: []const u8) bool {
    const version = getCurrentVersion();
    if (version.minor >= 16) {
        return v0_16.containsOptionalMethod(line);
    }
    // Default to 0.15.x
    return v0_15.containsOptionalMethod(line);
}

/// Check if line contains an error-returning method (version-aware)
/// Used by ZA205 to detect discarded error returns
pub fn containsErrorMethod(line: []const u8) bool {
    const version = getCurrentVersion();
    if (version.minor >= 16) {
        return v0_16.containsErrorMethod(line);
    }
    return v0_15.containsErrorMethod(line);
}

/// Check if line contains an allocation pattern (version-aware)
/// Used by ZA101/ZA102 for memory leak detection
pub fn containsAllocation(line: []const u8) bool {
    const version = getCurrentVersion();
    if (version.minor >= 16) {
        return v0_16.containsAllocation(line);
    }
    return v0_15.containsAllocation(line);
}

/// Check if line contains a builtin function (version-aware)
pub fn containsBuiltin(line: []const u8) bool {
    const version = getCurrentVersion();
    if (version.minor >= 16) {
        return v0_16.containsBuiltin(line);
    }
    return v0_15.containsBuiltin(line);
}

/// Check for deprecated patterns (version-aware)
/// Returns replacement suggestion if found
pub fn checkDeprecated(line: []const u8) ?v0_15.DeprecatedPattern {
    const version = getCurrentVersion();
    if (version.minor < 16) return v0_15.checkDeprecated(line);
    // Both versions use compatible DeprecatedPattern struct
    const dep = v0_16.checkDeprecated(line) orelse return null;
    return .{
        .pattern = dep.pattern,
        .replacement = dep.replacement,
        .rule = dep.rule,
    };
}

// ============================================================================
// Direct access to version-specific arrays
// ============================================================================

/// Get the optional methods list for the current version
pub fn getOptionalMethods() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) {
        return &v0_16.optional_methods;
    }
    return &v0_15.optional_methods;
}

/// Get the error methods list for the current version
pub fn getErrorMethods() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) {
        return &v0_16.error_methods;
    }
    return &v0_15.error_methods;
}

/// Get the builtin functions list for the current version
pub fn getBuiltins() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) {
        return &v0_16.builtins;
    }
    return &v0_15.builtins;
}

/// Get the allocation patterns for the current version
pub fn getAllocPatterns() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) {
        return &v0_16.alloc_patterns;
    }
    return &v0_15.alloc_patterns;
}

/// Get the create patterns for the current version
pub fn getCreatePatterns() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) {
        return &v0_16.create_patterns;
    }
    return &v0_15.create_patterns;
}

/// Get the free patterns for the current version
pub fn getFreePatterns() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) {
        return &v0_16.free_patterns;
    }
    return &v0_15.free_patterns;
}

/// Get the destroy patterns for the current version
pub fn getDestroyPatterns() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) {
        return &v0_16.destroy_patterns;
    }
    return &v0_15.destroy_patterns;
}

/// Get the keywords list for the current version
pub fn getKeywords() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) {
        return &v0_16.keywords;
    }
    return &v0_15.keywords;
}

/// Get the breaking changes list for the current version
pub fn getBreakingChanges() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) {
        return &v0_16.breaking_changes;
    }
    return &v0_15.breaking_changes;
}

/// Get the std modules list for the current version
pub fn getStdModules() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) {
        return &v0_16.std_modules;
    }
    return &v0_15.std_modules;
}

// ============================================================================
// Vocabulary access - Stdlib allocator types, methods, and patterns
// Single source of truth routed through version-specific modules
// ============================================================================

/// Init patterns for allocator types that don't need per-allocation free
pub fn getNoFreeInitPatterns() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) return v0_16.no_free_init_patterns;
    return v0_15.no_free_init_patterns;
}

/// Init patterns for ALL allocator types (no-free + needs-free)
pub fn getAllInitPatterns() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) return v0_16.all_init_patterns;
    return v0_15.all_init_patterns;
}

/// Names of global singleton allocators
pub fn getGlobalAllocNames() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) return v0_16.global_alloc_names;
    return v0_15.global_alloc_names;
}

/// Allocation method patterns for line matching (e.g. ".alloc(")
pub fn getAllocMethodPatterns() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) return v0_16.alloc_method_patterns;
    return v0_15.alloc_method_patterns;
}

/// Short names for allocation methods (identifier matching, e.g. "alloc")
pub fn getAllocMethodShortNames() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) return v0_16.alloc_method_short_names;
    return v0_15.alloc_method_short_names;
}

/// Qualified stdlib function patterns that allocate (e.g. "mem.concat(")
/// These have generic names that need module prefix to avoid false positives.
pub fn getQualifiedAllocFnPatterns() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) return v0_16.qualified_alloc_fn_patterns;
    return v0_15.qualified_alloc_fn_patterns;
}

/// Cleanup/deallocation patterns (.free, .destroy, .deinit)
pub fn getCleanupPatterns() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) return v0_16.cleanup_pattern_strs;
    return v0_15.cleanup_pattern_strs;
}

/// Container methods that transfer ownership (store/consume passed values)
pub fn getContainerOwnershipMethods() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) return v0_16.container_ownership_methods;
    return v0_15.container_ownership_methods;
}

/// Pointer type patterns for no-free allocator parameter detection
pub fn getNoFreeTypePtrs() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) return v0_16.no_free_type_ptrs;
    return v0_15.no_free_type_ptrs;
}

/// Stdlib methods safe to discard (void or value-returning, not !T)
pub fn getSafeMethodPatterns() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) return v0_16.safe_method_patterns;
    return v0_15.safe_method_patterns;
}

/// Stdlib void methods (subset of safe methods)
pub fn getVoidMethodPatterns() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) return v0_16.void_method_patterns;
    return v0_15.void_method_patterns;
}

/// Stdlib container mutation methods (fill/modify receiver)
pub fn getModifyingMethodPatterns() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) return v0_16.modifying_method_patterns;
    return v0_15.modifying_method_patterns;
}

/// Stdlib container type init patterns (for type-based detection)
pub fn getStdlibContainerInitPatterns() []const []const u8 {
    const version = getCurrentVersion();
    if (version.minor >= 16) return v0_16.stdlib_container_init_patterns;
    return v0_15.stdlib_container_init_patterns;
}

// ============================================================================
// Tests
// ============================================================================

test "parseVersion parses standard version" {
    const v = try parseVersion("0.15.2");
    try std.testing.expectEqual(@as(u16, 0), v.major);
    try std.testing.expectEqual(@as(u16, 15), v.minor);
    try std.testing.expectEqual(@as(u16, 2), v.patch);
    try std.testing.expect(!v.dev);
}

test "parseVersion parses dev version" {
    const v = try parseVersion("0.16.0-dev");
    try std.testing.expectEqual(@as(u16, 0), v.major);
    try std.testing.expectEqual(@as(u16, 16), v.minor);
    try std.testing.expectEqual(@as(u16, 0), v.patch);
    try std.testing.expect(v.dev);
}

test "getCurrentVersion returns valid version" {
    const v = getCurrentVersion();
    try std.testing.expect(v.major == 0);
    try std.testing.expect(v.minor >= 15);
}

test "getCompat returns compat for current version" {
    const compat = getCompat();
    try std.testing.expect(compat != null);
}

test "containsOptionalMethod detects optional patterns" {
    try std.testing.expect(containsOptionalMethod("_ = args.next()"));
    try std.testing.expect(containsOptionalMethod("if (map.get(key)) |v|"));
    try std.testing.expect(!containsOptionalMethod("try file.read(buf)"));
}

test "containsErrorMethod detects error patterns" {
    try std.testing.expect(containsErrorMethod("try file.read(buf)"));
    try std.testing.expect(containsErrorMethod("try allocator.alloc(u8, 100)"));
    try std.testing.expect(!containsErrorMethod("_ = iter.next()"));
}

test "containsAllocation detects allocation patterns" {
    try std.testing.expect(containsAllocation("try allocator.alloc(u8, 100)"));
    try std.testing.expect(containsAllocation("try allocator.create(Node)"));
    try std.testing.expect(!containsAllocation("const x = 42"));
}

test "getOptionalMethods returns non-empty list" {
    const methods = getOptionalMethods();
    try std.testing.expect(methods.len > 0);
}

test "getBuiltins returns non-empty list" {
    const builtins_list = getBuiltins();
    try std.testing.expect(builtins_list.len > 0);
}

test "getNoFreeInitPatterns returns non-empty list" {
    const patterns = getNoFreeInitPatterns();
    try std.testing.expect(patterns.len > 0);
}

test "getAllInitPatterns returns non-empty list" {
    const patterns = getAllInitPatterns();
    try std.testing.expect(patterns.len > 0);
    // Should include both no-free and needs-free types
    try std.testing.expect(patterns.len > getNoFreeInitPatterns().len);
}

test "getGlobalAllocNames includes testing.allocator" {
    const names = getGlobalAllocNames();
    var found = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "testing.allocator")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "getAllocMethodPatterns includes dupe" {
    const patterns = getAllocMethodPatterns();
    var found = false;
    for (patterns) |p| {
        if (std.mem.eql(u8, p, ".dupe(")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "getCleanupPatterns returns non-empty list" {
    const patterns = getCleanupPatterns();
    try std.testing.expect(patterns.len > 0);
}

test "getContainerOwnershipMethods returns non-empty list" {
    const methods = getContainerOwnershipMethods();
    try std.testing.expect(methods.len > 0);
}

test "getNoFreeTypePtrs returns non-empty list" {
    const ptrs = getNoFreeTypePtrs();
    try std.testing.expect(ptrs.len > 0);
}

test "getSafeMethodPatterns returns non-empty list" {
    const patterns = getSafeMethodPatterns();
    try std.testing.expect(patterns.len > 0);
}

test "getVoidMethodPatterns returns non-empty list" {
    const patterns = getVoidMethodPatterns();
    try std.testing.expect(patterns.len > 0);
    // Void patterns should be a subset of safe patterns
    try std.testing.expect(patterns.len < getSafeMethodPatterns().len);
}

test "getModifyingMethodPatterns returns non-empty list" {
    const patterns = getModifyingMethodPatterns();
    try std.testing.expect(patterns.len > 0);
    // Should include common container methods
    var found_append = false;
    var found_put = false;
    for (patterns) |p| {
        if (std.mem.eql(u8, p, ".append(")) found_append = true;
        if (std.mem.eql(u8, p, ".put(")) found_put = true;
    }
    try std.testing.expect(found_append);
    try std.testing.expect(found_put);
}

test "getStdlibContainerInitPatterns returns non-empty list" {
    const patterns = getStdlibContainerInitPatterns();
    try std.testing.expect(patterns.len > 0);
    var found_arraylist = false;
    for (patterns) |p| {
        if (std.mem.eql(u8, p, "ArrayList(")) found_arraylist = true;
    }
    try std.testing.expect(found_arraylist);
}
