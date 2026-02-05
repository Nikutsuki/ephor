// Test case: Ownership transfer to collections
// When allocation is added to a collection, the collection owns it
// Expected: NO warning for ZA102/ZA104
const std = @import("std");

const Endpoint = struct {
    interface: Interface,

    const Interface = struct {
        path: []const u8,
        handler: *const fn () void,
    };

    fn init(path: []const u8, handler: *const fn () void) Endpoint {
        return .{ .interface = .{ .path = path, .handler = handler } };
    }
};

pub fn addEndpoint(
    allocator: std.mem.Allocator,
    endpoints: *std.ArrayList(*Endpoint.Interface),
    path: []const u8,
    handler: *const fn () void,
) !void {
    const bound = try allocator.create(Endpoint);
    bound.* = Endpoint.init(path, handler);
    // Ownership transferred to ArrayList - no defer needed for 'bound'
    try endpoints.append(&bound.interface);
}

pub fn addToHashMap(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap([]u8),
    key: []const u8,
) !void {
    const value = try allocator.alloc(u8, 100);
    // Ownership transferred to HashMap - no defer needed for 'value'
    try map.put(key, value);
}
