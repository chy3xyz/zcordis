//! Cordis Native — event listener (section IX).
//!
//! A listener is the erased record stored in the `EventBus`. It is owned by the
//! bus but its lifetime is tied to the subscribing `Scope`: on scope disposal
//! the scope's disposable list calls `unsubscribe`, which removes the listener
//! from the bus and frees it. This is the "scope-aware event system" from
//! `dev.md` §X — a dead scope can never fire a callback.

const std = @import("std");
const Scope = @import("../core/scope.zig").Scope;
const Disposable = @import("../core/scope.zig").Disposable;

pub const Listener = struct {
    event_hash: u64,
    scope: *Scope,
    priority: i32,
    once: bool,
    global: bool,
    call: *const fn (*Scope, *const anyopaque, ?*anyopaque) anyerror!void,
    removed: bool = false,
    /// The disposable that unsubscribes this listener (also kept in the scope's
    /// disposable list so disposal cleans it up).
    disp: Disposable,
};

/// Remove `listener` from its bus and free it. Idempotent: safe to call after
/// the scope has already been disposed.
pub fn unsubscribe(listener: *Listener) void {
    if (listener.removed) return;
    listener.removed = true;

    const bus = &listener.scope.runtime.events;
    for (bus.listeners.items, 0..) |l, i| {
        if (l == listener) {
            _ = bus.listeners.orderedRemove(i);
            break;
        }
    }
    // Drop the disposable from the owning scope so it is not invoked again.
    listener.scope.disposables.remove(listener.scope.alloc(), listener.disp);
    bus.alloc.destroy(listener);
}
