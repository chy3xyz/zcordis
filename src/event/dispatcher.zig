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
/// How many matching listeners a dispatch keeps in its own stack buffer before
/// spilling to the heap. Sized for the common case: most emits have a handful.
pub const inline_listeners = 8;

/// A collected dispatch set, owned by the caller for the duration of one dispatch.
///
/// `items` normally points into the caller's stack scratch, so the emit path does
/// no heap allocation at all. Because every dispatch owns its scratch, a handler
/// that re-enters `emit` cannot clobber the outer set — which is what makes a
/// stack buffer safe here, and why the bus cannot keep one shared scratch.
pub const Snapshot = struct {
    items: []*Listener,
    /// Set when `items` was spilled to the heap and must be freed on release.
    heap: bool = false,

    /// Drop the references `collect` took and free any heap spill. Every
    /// dispatching path must call this exactly once.
    pub fn release(self: Snapshot, bus: *EventBus) void {
        for (self.items) |l| releaseRef(l);
        if (self.heap) bus.alloc.free(self.items);
    }
};

/// Snapshot the listeners that should receive an `E` emitted from `emit_scope`,
/// filtered by scope and sorted by descending priority, into the caller's
/// `scratch` (spilling to the heap only when there are more matches than fit).
pub fn collect(
    self: *EventBus,
    comptime E: type,
    emit_scope: *Scope,
    scratch: []*Listener,
) !Snapshot {
    const key = event.eventKey(E);
    var n: usize = 0; // entries used in `scratch`
    var spill: std.ArrayListUnmanaged(*Listener) = .empty;
    var spilled = false;

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    errdefer {
        // Undo the references taken before the failure.
        for (scratch[0..n]) |l| releaseRef(l);
        for (spill.items) |l| releaseRef(l);
        spill.deinit(self.alloc);
    }

    for (self.listeners.items) |l| {
        if (l.removed) continue;
        if (l.event_hash != key) continue;
        if (!l.scope.isAlive()) continue;
        // Scope-aware filtering: a non-global listener only fires for emits at
        // or below the scope that subscribed (scope-aware event system).
        if (!l.global and !emit_scope.isWithin(l.scope)) continue;

        // Take the reference *while holding the lock*, so a concurrent
        // `unsubscribe` cannot free the record before the caller dispatches.
        _ = l.refs.fetchAdd(1, .acq_rel);

        if (spilled) {
            try spill.append(self.alloc, l);
        } else if (n < scratch.len) {
            scratch[n] = l;
            n += 1;
        } else {
            // First overflow: carry the stack entries into a heap buffer.
            try spill.appendSlice(self.alloc, scratch[0..n]);
            n = 0;
            spilled = true;
            try spill.append(self.alloc, l);
        }
    }

    const items: []*Listener = if (spilled) try spill.toOwnedSlice(self.alloc) else scratch[0..n];

    // Sorting is the uncommon case: listeners default to priority 0 and are
    // visited in registration order, so the set is usually already ordered.
    if (!isPriorityOrdered(items)) {
        std.mem.sort(*Listener, items, {}, struct {
            fn less(_: void, a: *Listener, b: *Listener) bool {
                return a.priority > b.priority;
            }
        }.less);
    }
    return .{ .items = items, .heap = spilled };
}

/// True when `items` is already in the non-increasing priority order dispatch
/// wants — an O(n) check that lets the common all-default-priority case skip an
/// O(n log n) sort.
fn isPriorityOrdered(items: []const *Listener) bool {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        if (items[i - 1].priority < items[i].priority) return false;
    }
    return true;
}
