// Zig Version Compatibility Layer
//
// This module provides version-specific API compatibility for Ephor.
// To add support for a new Zig version:
//   1. Create a new file: vX_YZ.zig (e.g., v0_17.zig)
//   2. Implement all the required arrays and functions
//   3. Add the import below, a Tables constant, and a knownTablesFor arm
//   4. Bump newest_supported_minor so the fallback clamps to the new tables
//
// Dispatch is a hardcoded switch by design (EPH-I0229): the per-version
// modules are the only source of pattern tables. A version with no exact
// tables falls back to the nearest supported tables — a newer version
// clamps to the newest, an older version clamps to the oldest — and ephor
// warns once per process when the fallback applies.
//
// Table selection depends on the compiler that BUILT ephor
// (getCurrentVersion reads the build toolchain's version at comptime),
// never the scanned project's toolchain: the resolved tables serve every
// scanned project (F17).
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
const vocab = @import("vocab.zig");

// Import all supported version modules
pub const v0_15 = @import("v0_15.zig");
pub const v0_16 = @import("v0_16.zig");

/// Version information parsed from Zig version string
pub const VersionInfo = struct {
    major: u16,
    minor: u16,
    patch: u16,
    dev: bool,

    pub fn format(self: VersionInfo, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}.{d}.{d}", .{
            self.major,
            self.minor,
            self.patch,
        });
        if (self.dev) try writer.writeAll("-dev");
    }
};

/// Parse a Zig version string like "0.15.2" or "0.16.0-dev.1645+<commit>".
/// A dev toolchain reports "X.Y.Z-dev.N+<commit>" (builtin.zig_version_string):
/// everything from the first "-dev" is build metadata, so it sets dev and
/// never reaches the numeric parts. A malformed numeric component clamps to
/// zero by design: the dispatch consumes only major and minor, and every
/// real toolchain string has them well-formed (F12).
pub fn parseVersion(version_str: []const u8) VersionInfo {
    var info = VersionInfo{ .major = 0, .minor = 0, .patch = 0, .dev = false };

    // Cut the dev metadata: "0.16.0-dev.1645+<commit>" parses as 0.16.0
    // with dev set. indexOf (not endsWith) matches the real dev-string
    // shape, where metadata follows "-dev" (F12).
    var str = version_str;
    if (std.mem.indexOf(u8, str, "-dev")) |dev_at| {
        info.dev = true;
        str = str[0..dev_at];
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

/// The Zig version of the compiler that BUILT ephor, not the version of
/// the project being scanned. The value is a comptime constant of the
/// build toolchain, and the resolved tables then serve every scanned
/// project regardless of its own toolchain. Table selection is build-time
/// by design; per-target selection would start here (F17).
pub fn getCurrentVersion() VersionInfo {
    return comptime parseVersion(builtin.zig_version_string);
}

/// Every pattern table and predicate one version module supplies.
/// tables_0_15 and tables_0_16 are the whole dispatch table: the getters
/// read fields instead of switching on the version at every call site.
const Tables = struct {
    /// Module version label ("0.15", "0.16") for the fallback warning.
    version_label: []const u8,
    builtins: []const []const u8,
    optional_methods: []const []const u8,
    error_methods: []const []const u8,
    alloc_patterns: []const []const u8,
    create_patterns: []const []const u8,
    free_patterns: []const []const u8,
    destroy_patterns: []const []const u8,
    keywords: []const []const u8,
    breaking_changes: []const []const u8,
    std_modules: []const []const u8,
    no_free_init_patterns: []const []const u8,
    no_free_field_type_patterns: []const []const u8,
    all_init_patterns: []const []const u8,
    global_alloc_names: []const []const u8,
    alloc_method_patterns: []const []const u8,
    alloc_method_short_names: []const []const u8,
    qualified_alloc_fn_patterns: []const []const u8,
    /// The module's cleanup_pattern_strs list.
    cleanup_patterns: []const []const u8,
    container_ownership_methods: []const []const u8,
    no_free_type_ptrs: []const []const u8,
    safe_method_patterns: []const []const u8,
    void_method_patterns: []const []const u8,
    modifying_method_patterns: []const []const u8,
    stdlib_container_init_patterns: []const []const u8,
    managed_container_type_patterns: []const []const u8,
    contains_optional_method: *const fn (line: []const u8) bool,
    contains_error_method: *const fn (line: []const u8) bool,
    contains_allocation: *const fn (line: []const u8) bool,
    contains_builtin: *const fn (line: []const u8) bool,
    check_deprecated: *const fn (line: []const u8) ?vocab.DeprecatedPattern,
};

/// Table set for Zig 0.15.x. The knownTablesFor dispatch references this set.
const tables_0_15 = Tables{
    .version_label = v0_15.version,
    .builtins = &v0_15.builtins,
    .optional_methods = &v0_15.optional_methods,
    .error_methods = &v0_15.error_methods,
    .alloc_patterns = &v0_15.alloc_patterns,
    .create_patterns = &v0_15.create_patterns,
    .free_patterns = &v0_15.free_patterns,
    .destroy_patterns = &v0_15.destroy_patterns,
    .keywords = &v0_15.keywords,
    .breaking_changes = &v0_15.breaking_changes,
    .std_modules = &v0_15.std_modules,
    .no_free_init_patterns = v0_15.no_free_init_patterns,
    .no_free_field_type_patterns = v0_15.no_free_field_type_patterns,
    .all_init_patterns = v0_15.all_init_patterns,
    .global_alloc_names = v0_15.global_alloc_names,
    .alloc_method_patterns = v0_15.alloc_method_patterns,
    .alloc_method_short_names = v0_15.alloc_method_short_names,
    .qualified_alloc_fn_patterns = v0_15.qualified_alloc_fn_patterns,
    .cleanup_patterns = v0_15.cleanup_pattern_strs,
    .container_ownership_methods = v0_15.container_ownership_methods,
    .no_free_type_ptrs = v0_15.no_free_type_ptrs,
    .safe_method_patterns = v0_15.safe_method_patterns,
    .void_method_patterns = v0_15.void_method_patterns,
    .modifying_method_patterns = v0_15.modifying_method_patterns,
    .stdlib_container_init_patterns = v0_15.stdlib_container_init_patterns,
    .managed_container_type_patterns = v0_15.managed_container_type_patterns,
    .contains_optional_method = v0_15.containsOptionalMethod,
    .contains_error_method = v0_15.containsErrorMethod,
    .contains_allocation = v0_15.containsAllocation,
    .contains_builtin = v0_15.containsBuiltin,
    .check_deprecated = v0_15.checkDeprecated,
};

/// Table set for Zig 0.16.x. The knownTablesFor dispatch references this set.
const tables_0_16 = Tables{
    .version_label = v0_16.version,
    .builtins = &v0_16.builtins,
    .optional_methods = &v0_16.optional_methods,
    .error_methods = &v0_16.error_methods,
    .alloc_patterns = &v0_16.alloc_patterns,
    .create_patterns = &v0_16.create_patterns,
    .free_patterns = &v0_16.free_patterns,
    .destroy_patterns = &v0_16.destroy_patterns,
    .keywords = &v0_16.keywords,
    .breaking_changes = &v0_16.breaking_changes,
    .std_modules = &v0_16.std_modules,
    .no_free_init_patterns = v0_16.no_free_init_patterns,
    .no_free_field_type_patterns = v0_16.no_free_field_type_patterns,
    .all_init_patterns = v0_16.all_init_patterns,
    .global_alloc_names = v0_16.global_alloc_names,
    .alloc_method_patterns = v0_16.alloc_method_patterns,
    .alloc_method_short_names = v0_16.alloc_method_short_names,
    .qualified_alloc_fn_patterns = v0_16.qualified_alloc_fn_patterns,
    .cleanup_patterns = v0_16.cleanup_pattern_strs,
    .container_ownership_methods = v0_16.container_ownership_methods,
    .no_free_type_ptrs = v0_16.no_free_type_ptrs,
    .safe_method_patterns = v0_16.safe_method_patterns,
    .void_method_patterns = v0_16.void_method_patterns,
    .modifying_method_patterns = v0_16.modifying_method_patterns,
    .stdlib_container_init_patterns = v0_16.stdlib_container_init_patterns,
    .managed_container_type_patterns = v0_16.managed_container_type_patterns,
    .contains_optional_method = v0_16.containsOptionalMethod,
    .contains_error_method = v0_16.containsErrorMethod,
    .contains_allocation = v0_16.containsAllocation,
    .contains_builtin = v0_16.containsBuiltin,
    .check_deprecated = v0_16.checkDeprecated,
};

/// Minor version of the newest supported Zig release. An unknown newer
/// version clamps to this version's tables.
const newest_supported_minor = 16;

/// Tables plus whether the version matched exactly.
const Resolution = struct {
    tables: Tables,
    /// False only for an exact major.minor match with a supported version.
    used_fallback: bool,
};

/// Resolve a Zig version to its pattern tables. Pure: no warning and no
/// cache, so tests can probe any version. resolveVersion compares the
/// major version first, so the minor number alone cannot misroute a
/// future 1.x.
fn resolveVersion(version: VersionInfo) Resolution {
    if (knownTablesFor(version)) |tables| {
        return .{ .tables = tables, .used_fallback = false };
    }
    return .{ .tables = fallbackTablesFor(version), .used_fallback = true };
}

/// Exact-match dispatch over the supported versions. The only switch over
/// the version set: a new Zig version adds one arm here.
fn knownTablesFor(version: VersionInfo) ?Tables {
    if (version.major != 0) return null;
    return switch (version.minor) {
        15 => tables_0_15,
        16 => tables_0_16,
        else => null,
    };
}

/// Fallback policy for a version with no exact tables: anything newer than
/// the newest supported release (including a future 1.x) clamps to the
/// newest tables. Anything older clamps to the oldest tables.
fn fallbackTablesFor(version: VersionInfo) Tables {
    const is_newer = version.major > 0 or version.minor > newest_supported_minor;
    return if (is_newer) tables_0_16 else tables_0_15;
}

/// Resolved tables for the running compiler. The resolve runs once per
/// process: the first call also records the unknown-version fallback when
/// it applies. The plain global is race-free because compat is read only
/// from the main thread: the process's only non-test worker is the parse
/// worker (ast_tier.zig:54), which spawns per file, calls only Ast.parse
/// (never compat), and joins before analysis resumes (ast_tier.zig:59);
/// a test-only chain-walk thread (spawn at main.zig:42440) joins before
/// any compat access and never touches compat either (F10).
var cached_tables: ?Tables = null;

/// Pending unknown-version fallback state (EPH-I1054): currentTables
/// sets the flag when the running compiler needs fallback tables; main
/// consumes it once per run through takeUnknownVersionWarning() and
/// prints the message on the CLI diagnostics channel, whose json_stream
/// latch keeps it off the JSON machine stream. compat cannot reach
/// main's diagnostics helpers without a circular import, so the flag
/// defers the print instead of writing to raw stderr here.
var pending_unknown_version_warning: bool = false;

/// Record that the running compiler needed fallback tables (EPH-I1054).
/// The message itself is printed by main's epilogue, never here.
pub fn markUnknownVersionFallback() void {
    pending_unknown_version_warning = true;
}

/// Consume the pending fallback warning (EPH-I1054). main calls this
/// once per run; a consumed flag never fires again.
pub fn takeUnknownVersionWarning() bool {
    const pending = pending_unknown_version_warning;
    pending_unknown_version_warning = false;
    return pending;
}

// Comptime-built "X.Y.x, ..." list enumerated from the dispatch itself:
// each arm of knownTablesFor contributes its version_label, so the
// supported-versions string can never drift from the switch (F11).
// newest_supported_minor bounds the probe loop (checklist item 4). The
// by-value struct copy clears the comptime-var provenance: a
// container-scope const must not slice a comptime var's storage directly.
const BuiltVersionsString = struct { bytes: [256]u8, len: usize };
const built_versions_string = blk: {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    var minor: u16 = 0;
    while (minor <= newest_supported_minor) : (minor += 1) {
        const version = VersionInfo{ .major = 0, .minor = minor, .patch = 0, .dev = false };
        if (knownTablesFor(version)) |tables| {
            if (pos > 0) {
                @memcpy(buf[pos..][0..2], ", ");
                pos += 2;
            }
            @memcpy(buf[pos..][0..tables.version_label.len], tables.version_label);
            pos += tables.version_label.len;
            @memcpy(buf[pos..][0..2], ".x");
            pos += 2;
        }
    }
    break :blk BuiltVersionsString{ .bytes = buf, .len = pos };
};
const supported_versions_string = built_versions_string.bytes[0..built_versions_string.len];

/// Human-readable list of the supported Zig versions.
/// Feeds the unknown-version warning. Derived from the dispatch arms, so
/// a new version appears here when its switch arm lands (F11).
pub fn getSupportedVersionsString() []const u8 {
    return supported_versions_string;
}

/// Build the fallback warning text. Parameterized so tests can pin the
/// wording for any version; the production text is the comptime call in
/// unknown_version_warning_text.
pub fn formatUnknownVersionWarning(
    comptime version: VersionInfo,
    comptime fallback_label: []const u8,
) []const u8 {
    const supported_versions = comptime getSupportedVersionsString();
    return std.fmt.comptimePrint(
        "WARNING: ephor does not have pattern tables for Zig {f}. " ++
            "ephor uses the Zig {s} tables, so results can be inaccurate. " ++
            "Run ephor with a supported Zig version: {s}.\n",
        .{ version, fallback_label, supported_versions },
    );
}

/// Resolution of the running compiler, evaluated once at comptime: the
/// version is a comptime constant, so the fallback decision and its
/// warning text cost nothing at runtime.
const running_resolution = resolveVersion(getCurrentVersion());

/// Warning text for a fallback-tables build (EPH-I1054). Comptime-built
/// from the running version and the fallback label; empty on a supported
/// build, where the warning can never fire. main prints it through
/// cliDiag when takeUnknownVersionWarning() returns true.
pub const unknown_version_warning_text: []const u8 = if (running_resolution.used_fallback)
    formatUnknownVersionWarning(getCurrentVersion(), running_resolution.tables.version_label)
else
    "";

/// Tables for the running compiler, resolved once. The unknown-version
/// fallback record happens inside this resolve, not in the pure
/// resolveVersion.
fn currentTables() Tables {
    if (cached_tables) |tables| return tables;
    const version = getCurrentVersion();
    const resolution = resolveVersion(version);
    if (resolution.used_fallback) {
        markUnknownVersionFallback();
    }
    cached_tables = resolution.tables;
    return resolution.tables;
}

// ============================================================================
// Version-aware pattern checking functions
// These delegate to the appropriate version module
// ============================================================================

/// Check if line contains an optional-returning method (version-aware)
/// Used by ZA205/ZA201 analyzers to avoid false positives
pub fn containsOptionalMethod(line: []const u8) bool {
    return currentTables().contains_optional_method(line);
}

/// Check if line contains an error-returning method (version-aware)
/// Used by ZA205 to detect discarded error returns
pub fn containsErrorMethod(line: []const u8) bool {
    return currentTables().contains_error_method(line);
}

/// Check if line contains an allocation pattern (version-aware)
/// Used by ZA101/ZA102 for memory leak detection
pub fn containsAllocation(line: []const u8) bool {
    return currentTables().contains_allocation(line);
}

/// Check if line contains a builtin function (version-aware)
pub fn containsBuiltin(line: []const u8) bool {
    return currentTables().contains_builtin(line);
}

/// Check for deprecated patterns (version-aware)
/// Returns replacement suggestion if found
pub fn checkDeprecated(line: []const u8) ?vocab.DeprecatedPattern {
    return currentTables().check_deprecated(line);
}

// ============================================================================
// Direct access to version-specific arrays
// ============================================================================

/// Get the optional methods list for the current version
pub fn getOptionalMethods() []const []const u8 {
    return currentTables().optional_methods;
}

/// Get the error methods list for the current version
pub fn getErrorMethods() []const []const u8 {
    return currentTables().error_methods;
}

/// Get the builtin functions list for the current version
pub fn getBuiltins() []const []const u8 {
    return currentTables().builtins;
}

/// Get the allocation patterns for the current version
pub fn getAllocPatterns() []const []const u8 {
    return currentTables().alloc_patterns;
}

/// Get the create patterns for the current version
pub fn getCreatePatterns() []const []const u8 {
    return currentTables().create_patterns;
}

/// Get the free patterns for the current version
pub fn getFreePatterns() []const []const u8 {
    return currentTables().free_patterns;
}

/// Get the destroy patterns for the current version
pub fn getDestroyPatterns() []const []const u8 {
    return currentTables().destroy_patterns;
}

/// Get the keywords list for the current version
pub fn getKeywords() []const []const u8 {
    return currentTables().keywords;
}

/// Get the breaking changes list for the current version
pub fn getBreakingChanges() []const []const u8 {
    return currentTables().breaking_changes;
}

/// Get the std modules list for the current version
pub fn getStdModules() []const []const u8 {
    return currentTables().std_modules;
}

// ============================================================================
// Vocabulary access - Stdlib allocator types, methods, and patterns
// Single source of truth routed through version-specific modules
// ============================================================================

/// Init patterns for allocator types that don't need per-allocation free
pub fn getNoFreeInitPatterns() []const []const u8 {
    return currentTables().no_free_init_patterns;
}

/// Struct field type patterns for no-free allocators.
/// Used to detect fields like `arena: std.heap.ArenaAllocator,` so that
/// allocations through field chains (e.g. self.arena.alloc()) are suppressed.
/// Type-based only — never matches on field names, only on declared types.
pub fn getNoFreeFieldTypePatterns() []const []const u8 {
    return currentTables().no_free_field_type_patterns;
}

/// Init patterns for ALL allocator types (no-free + needs-free)
pub fn getAllInitPatterns() []const []const u8 {
    return currentTables().all_init_patterns;
}

/// Names of global singleton allocators
pub fn getGlobalAllocNames() []const []const u8 {
    return currentTables().global_alloc_names;
}

/// Allocation method patterns for line matching (e.g. ".alloc(")
pub fn getAllocMethodPatterns() []const []const u8 {
    return currentTables().alloc_method_patterns;
}

/// Short names for allocation methods (identifier matching, e.g. "alloc")
pub fn getAllocMethodShortNames() []const []const u8 {
    return currentTables().alloc_method_short_names;
}

/// Qualified stdlib function patterns that allocate (e.g. "mem.concat(")
/// These have generic names that need module prefix to avoid false positives.
pub fn getQualifiedAllocFnPatterns() []const []const u8 {
    return currentTables().qualified_alloc_fn_patterns;
}

/// Cleanup/deallocation patterns (.free, .destroy, .deinit)
pub fn getCleanupPatterns() []const []const u8 {
    return currentTables().cleanup_patterns;
}

/// Container methods that transfer ownership (store/consume passed values)
pub fn getContainerOwnershipMethods() []const []const u8 {
    return currentTables().container_ownership_methods;
}

/// Pointer type patterns for no-free allocator parameter detection
pub fn getNoFreeTypePtrs() []const []const u8 {
    return currentTables().no_free_type_ptrs;
}

/// Stdlib methods safe to discard (void or value-returning, not !T)
pub fn getSafeMethodPatterns() []const []const u8 {
    return currentTables().safe_method_patterns;
}

/// Stdlib void methods (subset of safe methods)
pub fn getVoidMethodPatterns() []const []const u8 {
    return currentTables().void_method_patterns;
}

/// Stdlib container mutation methods (fill/modify receiver)
pub fn getModifyingMethodPatterns() []const []const u8 {
    return currentTables().modifying_method_patterns;
}

/// Stdlib container type init patterns (for type-based detection)
pub fn getStdlibContainerInitPatterns() []const []const u8 {
    return currentTables().stdlib_container_init_patterns;
}

/// Managed-container type families (heap backing store; by-value copy aliases)
pub fn getManagedContainerTypePatterns() []const []const u8 {
    return currentTables().managed_container_type_patterns;
}

// ============================================================================
// Tests
// ============================================================================

test "parseVersion parses standard version" {
    const v = parseVersion("0.15.2");
    try std.testing.expectEqual(@as(u16, 0), v.major);
    try std.testing.expectEqual(@as(u16, 15), v.minor);
    try std.testing.expectEqual(@as(u16, 2), v.patch);
    try std.testing.expect(!v.dev);
}

test "parseVersion parses dev version" {
    const v = parseVersion("0.16.0-dev");
    try std.testing.expectEqual(@as(u16, 0), v.major);
    try std.testing.expectEqual(@as(u16, 16), v.minor);
    try std.testing.expectEqual(@as(u16, 0), v.patch);
    try std.testing.expect(v.dev);
}

test "parseVersion parses a real dev toolchain string (EPH-I0611)" {
    // builtin.zig_version_string's shape on a dev build: metadata after
    // "-dev" must set dev and must not leak into the numeric parts.
    const v = parseVersion("0.16.0-dev.1645+abcdef0123456789");
    try std.testing.expectEqual(@as(u16, 0), v.major);
    try std.testing.expectEqual(@as(u16, 16), v.minor);
    try std.testing.expectEqual(@as(u16, 0), v.patch);
    try std.testing.expect(v.dev);
}

test "parseVersion clamps a malformed component to zero (EPH-I0611)" {
    // Documented behavior: a bad numeric component becomes 0, never an
    // error. The dispatch consumes only major and minor.
    const v = parseVersion("0.16.notanumber");
    try std.testing.expectEqual(@as(u16, 0), v.major);
    try std.testing.expectEqual(@as(u16, 16), v.minor);
    try std.testing.expectEqual(@as(u16, 0), v.patch);
    try std.testing.expect(!v.dev);
}

test "getCurrentVersion returns valid version" {
    const v = getCurrentVersion();
    try std.testing.expect(v.major == 0);
    try std.testing.expect(v.minor >= 15);
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

test "getNoFreeFieldTypePatterns returns non-empty list" {
    const patterns = getNoFreeFieldTypePatterns();
    try std.testing.expect(patterns.len > 0);
    // Must include ArenaAllocator patterns
    var found_arena = false;
    for (patterns) |p| {
        if (std.mem.eql(u8, p, "std.heap.ArenaAllocator")) {
            found_arena = true;
            break;
        }
    }
    try std.testing.expect(found_arena);
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

test "getSupportedVersionsString derives from the dispatch arms (EPH-I0610)" {
    // Exact content, not substrings: the string must track the dispatch.
    try std.testing.expectEqualStrings("0.15.x, 0.16.x", getSupportedVersionsString());
}

test "unknown-version warning is pending until taken once (EPH-I1054)" {
    // The flag is file-global: consume any residue a fallback build's
    // earlier currentTables() call left behind.
    _ = takeUnknownVersionWarning();
    try std.testing.expect(!takeUnknownVersionWarning());
    markUnknownVersionFallback();
    try std.testing.expect(takeUnknownVersionWarning());
    try std.testing.expect(!takeUnknownVersionWarning());
}

test "fallback warning text names the fallback label and the supported versions (EPH-I1054)" {
    const text = formatUnknownVersionWarning(
        .{ .major = 0, .minor = 17, .patch = 0, .dev = false },
        "0.16",
    );
    try std.testing.expect(std.mem.indexOf(u8, text, "Zig 0.17.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Zig 0.16 tables") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "0.15.x, 0.16.x") != null);
}

test "resolveVersion maps 0.15.x to the 0.15 tables without fallback" {
    const r = resolveVersion(.{ .major = 0, .minor = 15, .patch = 2, .dev = false });
    try std.testing.expect(!r.used_fallback);
    try std.testing.expectEqualStrings("0.15", r.tables.version_label);
    try std.testing.expectEqual(
        @intFromPtr(&v0_15.keywords),
        @intFromPtr(r.tables.keywords.ptr),
    );
}

test "resolveVersion maps 0.16.x-dev to the 0.16 tables without fallback" {
    const r = resolveVersion(.{ .major = 0, .minor = 16, .patch = 0, .dev = true });
    try std.testing.expect(!r.used_fallback);
    try std.testing.expectEqualStrings("0.16", r.tables.version_label);
    try std.testing.expectEqual(
        @intFromPtr(&v0_16.keywords),
        @intFromPtr(r.tables.keywords.ptr),
    );
}

test "resolveVersion clamps 0.17 to the newest tables with fallback" {
    const r = resolveVersion(.{ .major = 0, .minor = 17, .patch = 0, .dev = false });
    try std.testing.expect(r.used_fallback);
    try std.testing.expectEqualStrings("0.16", r.tables.version_label);
}

test "resolveVersion clamps 0.14 to the oldest tables with fallback" {
    const r = resolveVersion(.{ .major = 0, .minor = 14, .patch = 2, .dev = false });
    try std.testing.expect(r.used_fallback);
    try std.testing.expectEqualStrings("0.15", r.tables.version_label);
}

test "resolveVersion compares the major version before the minor" {
    // 1.0 has minor 0: a minor-only dispatch would clamp it to the oldest
    // tables. The major comparison clamps it to the newest tables instead.
    const r = resolveVersion(.{ .major = 1, .minor = 0, .patch = 0, .dev = false });
    try std.testing.expect(r.used_fallback);
    try std.testing.expectEqualStrings("0.16", r.tables.version_label);
}

test "resolveVersion resolves the running compiler without fallback" {
    // Fails when ephor builds with an untested Zig: add the new table set.
    const r = resolveVersion(getCurrentVersion());
    try std.testing.expect(!r.used_fallback);
}

test "getErrorMethods returns non-empty list" {
    const methods = getErrorMethods();
    try std.testing.expect(methods.len > 0);
    var found_read = false;
    for (methods) |m| {
        if (std.mem.eql(u8, m, ".read(")) found_read = true;
    }
    try std.testing.expect(found_read);
}

test "getAllocPatterns returns non-empty list" {
    const patterns = getAllocPatterns();
    try std.testing.expect(patterns.len > 0);
    var found_alloc = false;
    for (patterns) |p| {
        if (std.mem.eql(u8, p, ".alloc(")) found_alloc = true;
    }
    try std.testing.expect(found_alloc);
}

test "getCreatePatterns covers create call forms" {
    const patterns = getCreatePatterns();
    try std.testing.expect(patterns.len > 0);
    var found = false;
    for (patterns) |p| {
        if (std.mem.eql(u8, p, ".create(")) found = true;
    }
    try std.testing.expect(found);
}

test "getFreePatterns covers free call forms" {
    const patterns = getFreePatterns();
    try std.testing.expect(patterns.len > 0);
    var found = false;
    for (patterns) |p| {
        if (std.mem.eql(u8, p, ".free(")) found = true;
    }
    try std.testing.expect(found);
}

test "getDestroyPatterns covers destroy call forms" {
    const patterns = getDestroyPatterns();
    try std.testing.expect(patterns.len > 0);
    var found = false;
    for (patterns) |p| {
        if (std.mem.eql(u8, p, ".destroy(")) found = true;
    }
    try std.testing.expect(found);
}

test "getKeywords includes core declaration keywords" {
    const kws = getKeywords();
    try std.testing.expect(kws.len > 0);
    var found_fn = false;
    var found_const = false;
    for (kws) |k| {
        if (std.mem.eql(u8, k, "fn ")) found_fn = true;
        if (std.mem.eql(u8, k, "const ")) found_const = true;
    }
    try std.testing.expect(found_fn);
    try std.testing.expect(found_const);
}

test "getBreakingChanges returns non-empty list" {
    try std.testing.expect(getBreakingChanges().len > 0);
}

test "getStdModules includes std.mem" {
    const modules = getStdModules();
    try std.testing.expect(modules.len > 0);
    var found = false;
    for (modules) |m| {
        if (std.mem.eql(u8, m, "std.mem")) found = true;
    }
    try std.testing.expect(found);
}

test "getAllocMethodShortNames includes alloc and create" {
    const names = getAllocMethodShortNames();
    try std.testing.expect(names.len > 0);
    var found_alloc = false;
    var found_create = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "alloc")) found_alloc = true;
        if (std.mem.eql(u8, n, "create")) found_create = true;
    }
    try std.testing.expect(found_alloc);
    try std.testing.expect(found_create);
}
