//! Cordis Native — typed service registry (sections V–VI, XXI–XXII).
//!
//! In TypeScript Cordis a service is a dynamic property (`ctx.database`).
//! Zig has no dynamic properties, so we key services by a name (string) and
//! resolve them with **compile-time type safety**: `Scope.get(Database, "db")`
//! returns `*Database` or `null`, and a type mismatch is a compile/lookup
//! error rather than a runtime `undefined`.
//!
//! Services are scoped: each `Scope` holds its own map; `get` walks up the
//! parent chain (the `root` scope is the top). Disposal of a scope discards
//! its map, so lookups never observe a dead service.

const std = @import("std");

pub const Entry = struct {
    /// Pointer to the service value, allocated in the owning scope's arena.
    value: *anyopaque,
    /// Hash of the declared service type name, used to validate `get`.
    type_hash: u64,
    /// Optional cleanup closure, run when the owning scope disposes.
    dispose: ?Disposable,
};

const Disposable = @import("../core/scope.zig").Disposable;

pub const ServiceMap = std.AutoHashMapUnmanaged(u64, Entry);

/// Hash a service name into a 64-bit key.
pub fn nameKey(name: []const u8) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(name);
    return hasher.final();
}

/// Hash a type's name so `get(T)` can reject `get(Other)` on the same name.
fn typeKey(comptime T: type) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(@typeName(T));
    return hasher.final();
}

/// Provide `value` under `name` in `map`, allocating the stored copy in
/// `alloc`. Returns the typed pointer that callers should use.
pub fn provideIn(
    alloc: std.mem.Allocator,
    map: *ServiceMap,
    comptime T: type,
    name: []const u8,
    value: T,
    dispose: ?Disposable,
) !*T {
    const slot = try alloc.create(T);
    slot.* = value;
    const gop = try map.getOrPut(alloc, nameKey(name));
    if (gop.found_existing) {
        // Overwriting an existing service in the same scope: free the old copy.
        // (Service replacement is rare; the old dispose closure is dropped.)
        alloc.destroy(@as(*T, @ptrCast(@alignCast(gop.value_ptr.value))));
    }
    gop.value_ptr.* = .{
        .value = slot,
        .type_hash = typeKey(T),
        .dispose = dispose,
    };
    return slot;
}

/// Look up `name` in a single `map`, returning a typed pointer or `null`.
pub fn getFrom(
    comptime T: type,
    map: ServiceMap,
    name: []const u8,
) ?*T {
    const entry = map.get(nameKey(name)) orelse return null;
    if (entry.type_hash != typeKey(T)) return null;
    return @as(*T, @ptrCast(@alignCast(entry.value)));
}

test "provideIn / getFrom round-trip with type safety" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const alloc = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == 0);

    var map: ServiceMap = .{};
    defer map.deinit(alloc);

    const DB = struct { url: []const u8 };
    const db = try provideIn(alloc, &map, DB, "db", .{ .url = "postgres://x" }, null);
    try std.testing.expectEqualSlices(u8, "postgres://x", db.url);

    const got = getFrom(DB, map, "db");
    try std.testing.expect(got != null);
    try std.testing.expectEqualSlices(u8, "postgres://x", got.?.url);

    // Wrong type name → lookup fails (type safety, not silent cast).
    const Wrong = struct { url: []const u8 };
    try std.testing.expect(getFrom(Wrong, map, "db") == null);

    // `provideIn` allocated the stored value copy; free it (in production this
    // is reclaimed by the owning scope's arena on dispose).
    alloc.destroy(db);
}
