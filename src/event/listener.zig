//! Cordis Native — event listener (section IX).
//!
//! A listener is the erased record stored in the `EventBus`. It is owned by the
//! bus but its lifetime is tied to the subscribing `Scope`: on scope disposal
//! the scope's disposable list calls `unsubscribe`, which removes the listener
//! from the bus and frees it. This is the "scope-aware event system" from
//! a dead scope can never fire a callback.

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
    /// References keeping this record alive: one for the registration itself,
    /// plus one per in-flight dispatch that has snapshotted it.
    ///
    /// `dispatcher.collect` takes a reference under the bus lock and the
    /// dispatching path drops it via `releaseRef` afterwards. Without this, a
    /// concurrent `unsubscribe` (e.g. another thread disposing the owning scope)
    /// would free a listener an `emit` is still about to call.
    refs: std.atomic.Value(u32) = .init(1),
};

/// Drop one reference, freeing the listener when it was the last.
pub fn releaseRef(listener: *Listener) void {
    const bus = &listener.scope.runtime.events;
    if (listener.refs.fetchSub(1, .acq_rel) == 1) bus.alloc.destroy(listener);
}

/// Remove `listener` from its bus and drop its registration reference.
/// Idempotent: safe to call after the scope has already been disposed.
pub fn unsubscribe(listener: *Listener) void {
    const bus = &listener.scope.runtime.events;

    // Mark and unlink under the bus lock, so a concurrent `collect` either takes
    // its reference before we get here, or never sees this listener at all.
    bus.mutex.lockUncancelable(bus.io);
    if (listener.removed) {
        bus.mutex.unlock(bus.io);
        return;
    }
    listener.removed = true;
    for (bus.listeners.items, 0..) |l, i| {
        if (l == listener) {
            _ = bus.listeners.orderedRemove(i);
            break;
        }
    }
    bus.mutex.unlock(bus.io);

    // Drop the disposable from the owning scope so it is not invoked again. The
    // scope's list has its own lock, never held together with the bus's.
    const scope = listener.scope;
    scope.disposables.remove(scope.runtime.io(), scope.alloc(), listener.disp);

    releaseRef(listener);
}
