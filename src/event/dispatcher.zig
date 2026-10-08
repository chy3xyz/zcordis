//! Cordis Native — dispatch helpers (section IX).
//!
//! Pure helpers shared by `EventBus`: candidate selection (scope filtering +
//! priority ordering) and the "bail" predicate that decides whether a handler
//! result should short-circuit `bail`/`serial`.

const std = @import("std");
const Scope = @import("../core/scope.zig").Scope;
const EventBus = @import("bus.zig").EventBus;
const Listener = @import("listener.zig").Listener;
const releaseRef = @import("listener.zig").releaseRef;
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
    // An enum has its own `@typeInfo` tag, not `.int`, so without this case the
    // "non-zero enum" the doc comment promises could never actually bail.
    if (@typeInfo(R) == .@"enum") return @backingInt(value) != 0;
    return false;
}

/// Snapshot the listeners that should receive an `E` emitted from
/// `emit_scope`, filtered by scope and sorted by descending priority. The
/// caller must free the returned slice with `bus.alloc.free` *after* calling
/// `EventBus.releaseSnapshot`, which drops the references taken here.
pub fn collect(
    self: *EventBus,
    comptime E: type,
    emit_scope: *Scope,
) ![]*Listener {
    var list: std.ArrayListUnmanaged(*Listener) = .empty;
    errdefer list.deinit(self.alloc);
    const key = event.eventKey(E);

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    errdefer {
        // Undo the references taken for the entries appended before the failure.
        for (list.items) |l| releaseRef(l);
    }
    for (self.listeners.items) |l| {
        if (l.removed) continue;
        if (l.event_hash != key) continue;
        if (!l.scope.isAlive()) continue;
        // Scope-aware filtering: a non-global listener only fires for emits at
        // or below the scope that subscribed (scope-aware event system).
        if (!l.global and !emit_scope.isWithin(l.scope)) continue;
        try list.append(self.alloc, l);
        // Take the reference *while holding the lock*, so a concurrent
        // `unsubscribe` cannot free the record before the caller has dispatched
        // to it.
        _ = l.refs.fetchAdd(1, .acq_rel);
    }
    std.mem.sort(*Listener, list.items, {}, struct {
        fn less(_: void, a: *Listener, b: *Listener) bool {
            return a.priority > b.priority;
        }
    }.less);
    return try list.toOwnedSlice(self.alloc);
}
