//! Cordis Native — effect (section XI).
//!
//! An `Effect` is a tracked, cancellable unit of work. In Cordis, effects are
//! the bridge between a plugin's setup and the runtime's lifecycle: when the
//! owning scope dies, every effect it spawned is cancelled deterministically
//! instead of leaking a detached thread or timer.

pub const State = enum(u8) {
    created,
    running,
    completed,
    cancelled,
    failed,
};

pub const Effect = struct {
    id: u64,
    scope: *Scope,
    /// Read and written from three different threads — the spawner, the task
    /// itself, and whoever cancels — so it is atomic.
    state: std.atomic.Value(State),
    /// Set by `cancel`; long-running tasks poll this to cooperatively stop.
    ///
    /// `std.Io` cancellation only fires at *I/O cancellation points*, so a
    /// CPU-bound task would never observe it. This flag covers both kinds of
    /// task: loops poll it, while `future.cancel` interrupts a task parked in
    /// an `Io` call.
    cancelled: std.atomic.Value(bool),
    /// The concurrent task driving this effect on the runtime's `std.Io`.
    /// `null` once the effect has been awaited or cancelled.
    future: ?std.Io.Future(void),
    run: *const fn (*anyopaque, *Effect) anyerror!void,
    ctx: *anyopaque,
};

const std = @import("std");
const Scope = @import("../core/scope.zig").Scope;
