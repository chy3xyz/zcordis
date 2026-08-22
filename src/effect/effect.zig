//! Cordis Native — effect (section XI).
//!
//! An `Effect` is a tracked, cancellable unit of work. In Cordis, effects are
//! the bridge between a plugin's setup and the runtime's lifecycle: when the
//! owning scope dies, every effect it spawned is cancelled deterministically
//! instead of leaking a detached thread or timer.

pub const State = enum {
    created,
    running,
    completed,
    cancelled,
    failed,
};

pub const Effect = struct {
    id: u64,
    scope: *Scope,
    state: State,
    /// Set by `cancel`; long-running tasks poll this to cooperatively stop.
    cancelled: std.atomic.Value(bool),
    thread: ?std.Thread,
    joinable: bool,
    run: *const fn (*anyopaque, *Effect) anyerror!void,
    ctx: *anyopaque,
};

const std = @import("std");
const Scope = @import("../core/scope.zig").Scope;
