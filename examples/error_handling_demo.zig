// Demonstration of all error handling patterns that ephor detects (ZA2xx)
// Run: ./zig-out/bin/ephor errors examples/ --enable=ZA204

const std = @import("std");

// =============================================================================
// ZA201: Silent catch {} discards error
// =============================================================================
fn silentCatch() void {
    const x = riskyOp() catch {};
    _ = x;
}

// =============================================================================
// ZA202: catch unreachable will panic on error
// =============================================================================
fn catchUnreachable() void {
    const x = riskyOp() catch unreachable;
    _ = x;
}

// =============================================================================
// ZA203: orelse unreachable will panic on null
// =============================================================================
fn orelseUnreachable(opt: ?u32) u32 {
    return opt orelse unreachable;
}

// =============================================================================
// ZA204: = undefined may leak sensitive data (off-by-default, use --enable=ZA204)
// =============================================================================
fn undefinedUsage() void {
    var x: u32 = undefined;
    _ = x;
}

// Good: fill pattern cancels ZA204
fn undefinedWithFill() void {
    var buf: [256]u8 = undefined;
    @memset(&buf, 0);
    _ = buf;
}

// =============================================================================
// ZA206: exit() bypasses defers (both std.process.exit and std.posix.exit)
// =============================================================================
fn exitBypassesDefer() void {
    defer cleanup();
    if (fatal_error) {
        std.process.exit(1);
    }
}

fn posixExitBypassesDefer() void {
    defer cleanup();
    if (fatal_error) {
        std.posix.exit(1);
    }
}

// =============================================================================
// ZA207: catch undefined converts errors to undefined behavior
// =============================================================================
fn catchUndefined() void {
    const x = riskyOp() catch undefined;
    _ = x;
}

// Good: catch |_| undefined is a different pattern (explicit error capture)
fn catchPipeUndefined() void {
    const x = riskyOp() catch |_| undefined;
    _ = x;
}

// =============================================================================
// ZA208: @panic() crash point (informational note)
// =============================================================================
fn panicDemo() void {
    @panic("unrecoverable error");
}

// =============================================================================
// Helpers (not analyzed - just for compilation context)
// =============================================================================
fn riskyOp() !u32 {
    return error.SomeError;
}

fn cleanup() void {}

var fatal_error: bool = false;
