//! Cordis Native — task abstraction (section XI).
//!
//! A `Task` binds a user context and a run function into a single value that
//! the scheduler can spawn. This is the type-erased closure the scheduler
//! accepts; `Scheduler.spawn` is the ergonomic entry point.

const std = @import("std");
const Effect = @import("effect.zig").Effect;

/// A unit of work parameterized by a user context type `Ctx`.
pub fn Task(comptime Ctx: type) type {
    return struct {
        ctx: *Ctx,
        run: *const fn (*Ctx, *Effect) anyerror!void,

        /// Spawn this task under `scope` via the given scheduler.
        pub fn spawn(self: Task(Ctx), sched: *Scheduler, scope: *Scope) !*Effect {
            return sched.spawn(Ctx, scope, self.ctx, self.run);
        }
    };
}

const Scheduler = @import("scheduler.zig").Scheduler;
const Scope = @import("../core/scope.zig").Scope;
