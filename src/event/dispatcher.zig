//! Cordis Native — dispatch helpers (section IX).
//!
//! Pure helpers shared by `EventBus`: candidate selection (scope filtering +
//! priority ordering) and the "bail" predicate that decides whether a handler
//! result should short-circuit `bail`/`serial`.

const std = @import("std");
const Scope = @import("../core/scope.zig").Scope;
const EventBus = @import("bus.zig").EventBus;
const Listener = @import("listener.zig").Listener;
const event = @import("event.zig");

/// Whether `value` should be treated as "bailed" (short-circuits dispatch).
/// Mirrors Cordis' `isBailed`: `null` / `false` / null-pointer do not bail,
/// while any truthy scalar (non-zero integer/float, non-zero enum) does.
pub fn isBailed(comptime R: type, value: R) bool {
    if (R == void) return false;
    if (@typeInfo(R) == .optional) return value != null;
    if (R == bool) return value;
    if (@typeInfo(R) == .pointer) return value != null;
    if (@typeInfo(R) == .int or @typeInfo(R) == .float) return value != 0;
    return false;
}

/// Snapshot the listeners that should receive an `E` emitted from
/// `emit_scope`, filtered by scope and sorted by descending priority. The
/// caller must free the returned slice with `bus.alloc`.
pub fn collect(
    self: *EventBus,
    comptime E: type,
    emit_scope: *Scope,
) ![]*Listener {
    var list: std.ArrayListUnmanaged(*Listener) = .{ .items = &.{}, .capacity = 0 };
    errdefer list.deinit(self.alloc);
    const key = event.eventKey(E);
    for (self.listeners.items) |l| {
        if (l.removed) continue;
        if (l.event_hash != key) continue;
        if (!l.scope.isAlive()) continue;
        // Scope-aware filtering: a non-global listener only fires for emits at
        // or below the scope that subscribed (scope-aware event system).
        if (!l.global and !emit_scope.isWithin(l.scope)) continue;
        try list.append(self.alloc, l);
    }
    std.mem.sort(*Listener, list.items, {}, struct {
        fn less(_: void, a: *Listener, b: *Listener) bool {
            return a.priority > b.priority;
        }
    }.less);
    return try list.toOwnedSlice(self.alloc);
}
