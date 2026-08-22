//! Cordis Native — typed event model (sections IX–XI, XXI–XXII).
//!
//! TypeScript Cordis keys events by string name with a dynamic payload. Zig
//! upgrades this to **compile-time event types**: `on(Message, handler)` where
//! `handler` receives `*const Message`. The event's optional `Return` decl
//! drives dispatch semantics (`bail`/`serial`/`waterfall`).

const std = @import("std");
const Scope = @import("../core/scope.zig").Scope;

/// Dispatch strategies, mirroring Cordis' `emit/parallel/serial/bail/waterfall`.
pub const Mode = enum {
    emit,
    parallel,
    serial,
    bail,
    waterfall,
};

/// The value type a handler returns. Defaults to `void`; an event may declare
/// `pub const Return = T;` to enable value-returning dispatch.
pub fn ReturnOf(comptime E: type) type {
    if (@hasDecl(E, "Return")) return E.Return;
    return void;
}

/// A handler for event type `E`.
pub fn Handler(comptime E: type) type {
    return fn (*Scope, *const E) anyerror!ReturnOf(E);
}

/// Stable 64-bit key for an event type (its name).
pub fn eventKey(comptime E: type) u64 {
    var h = std.hash.Fnv1a_64.init();
    h.update(@typeName(E));
    return h.final();
}

/// Erase a typed `Handler` into the uniform listener call signature. The
/// wrapper recovers the concrete event pointer and, when a result slot is
/// provided, writes the typed return value back into it.
pub fn makeWrapper(
    comptime E: type,
    comptime handler: Handler(E),
) *const fn (*Scope, *const anyopaque, ?*anyopaque) anyerror!void {
    const wrapper = struct {
        fn run(s: *Scope, p: *const anyopaque, o: ?*anyopaque) anyerror!void {
            const ev: *const E = @ptrCast(@alignCast(p));
            const r = try handler(s, ev);
            if (o) |out| {
                const slot: *ReturnOf(E) = @ptrCast(@alignCast(out));
                slot.* = r;
            }
        }
    }.run;
    return wrapper;
}

pub const SubscribeOptions = struct {
    /// Higher priority listeners run first.
    priority: i32 = 0,
    /// Auto-remove after the first invocation.
    once: bool = false,
    /// If true, the listener fires regardless of scope isolation.
    global: bool = false,
};
