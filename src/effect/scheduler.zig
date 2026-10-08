//! Cordis Native — effect scheduler (sections XII–XIII).
//!
//! The scheduler owns the set of live effects. Each effect runs as a concurrent
//! task on the runtime's `std.Io` (cooperatively cancellable via
//! `effect.cancelled`), and disposing a scope cancels every effect it spawned.

const std = @import("std");
const Scope = @import("../core/scope.zig").Scope;
const Effect = @import("effect.zig").Effect;

pub const Scheduler = struct {
    alloc: std.mem.Allocator,
    /// The runtime's `std.Io`, used to run and cancel effect tasks. Always
    /// present: `Context` owns the `IoContext` and passes its handle in.
    io: std.Io,
    /// Guards `effects` and `next_id`, so a `spawn` on one thread cannot corrupt
    /// a concurrent `cancelForScope`/`cancel` on another.
    ///
    /// Never held across `cancelTask`: a task may itself call `spawn`/`cancel`,
    /// and joining it while holding the lock would close a cycle.
    mutex: std.Io.Mutex = .init,
    effects: std.ArrayListUnmanaged(*Effect) = .empty,
    next_id: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) Scheduler {
        return .{ .alloc = alloc, .io = io };
    }

    pub fn deinit(self: *Scheduler) void {
        // Cancel everything still alive. Pop under the lock, then join outside
        // it — see `cancelForScope` for why the lock must not span `cancelTask`.
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const maybe_eff = self.effects.pop();
            self.mutex.unlock(self.io);

            const eff = maybe_eff orelse break;
            self.cancelTask(eff);
            self.alloc.destroy(eff);
        }
        self.effects.deinit(self.alloc);
        // `ArrayListUnmanaged.deinit` poisons the list (`self.* = undefined`), so
        // reset explicitly — otherwise a later `cancelForScope` would read a
        // poisoned struct.
        self.effects = .empty;
    }

    /// Signal `eff` to stop and block until its task has finished. Shared by
    /// `cancel`, `cancelForScope` and `deinit`.
    ///
    /// This must run for *every* effect, including one whose task already
    /// finished on its own: the `std.Io` future owns a heap allocation that only
    /// `Future.cancel`/`await` releases, so skipping it leaks.
    fn cancelTask(self: *Scheduler, eff: *Effect) void {
        eff.cancelled.store(true, .seq_cst);
        if (eff.future) |*f| {
            // Requests cancellation at the task's next I/O cancellation point
            // and blocks until it returns — the structured-concurrency
            // replacement for the old `Thread.join`. On an already-finished
            // future this is just the join.
            f.cancel(self.io);
            eff.future = null;
        }
    }

    fn genId(self: *Scheduler) u64 {
        self.next_id += 1;
        return self.next_id;
    }

    /// Spawn `run(ctx, effect)` as a cancellable background effect on `scope`.
    pub fn spawn(
        self: *Scheduler,
        comptime Ctx: type,
        scope: *Scope,
        ctx: *Ctx,
        comptime run: *const fn (*Ctx, *Effect) anyerror!void,
    ) !*Effect {
        const wrapper = struct {
            fn w(p: *anyopaque, e: *Effect) anyerror!void {
                const c: *Ctx = @ptrCast(@alignCast(p));
                return run(c, e);
            }
        };
        const w = wrapper.w;

        const eff = try self.alloc.create(Effect);
        errdefer self.alloc.destroy(eff);

        // Register and start under one lock. Releasing it in between would let a
        // concurrent `cancelForScope` unlink and free the effect while `spawn`
        // was still about to write `eff.future` — a use-after-free.
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            eff.* = .{
                .id = self.genId(),
                .scope = scope,
                .state = .init(.created),
                .cancelled = std.atomic.Value(bool).init(false),
                .future = null,
                .run = w,
                .ctx = ctx,
            };
            try self.effects.append(self.alloc, eff);
            errdefer {
                _ = self.unlinkLocked(eff);
            }

            // `concurrent` rather than `async`: `async` may run the task inline
            // when the pool is saturated, which would re-enter this scheduler
            // mid-`spawn`. `concurrent` guarantees a separate thread, and the
            // default `concurrent_limit` is unlimited.
            eff.future = try std.Io.concurrent(self.io, runEffect, .{eff});
        }

        eff.state.store(.running, .release);
        return eff;
    }

    /// Request cancellation of `eff`. Blocks until its task has finished, then
    /// frees it.
    pub fn cancel(self: *Scheduler, eff: *Effect) void {
        // Unlink under the lock; join with it released (see `cancelForScope`).
        self.mutex.lockUncancelable(self.io);
        const linked = self.unlinkLocked(eff);
        self.mutex.unlock(self.io);

        // Winning the unlink is what grants ownership. If a peer `cancel`, or
        // `cancelForScope`/`deinit`, got here first, it is already cancelling and
        // freeing this effect: touching it would `Future.cancel` the same future
        // twice — explicitly not threadsafe, and `Threaded.cancel` answers that
        // with `unreachable` — and race its destruction.
        if (!linked) return;

        self.cancelTask(eff);
        // A task that already ran to completion keeps its `.completed` state;
        // anything else is reported as cancelled.
        if (eff.state.load(.acquire) != .completed) eff.state.store(.cancelled, .release);
        self.alloc.destroy(eff);
    }

    /// Cancel and free all effects owned by `scope` (called on scope dispose).
    pub fn cancelForScope(self: *Scheduler, scope: *Scope) void {
        // Unlink one matching effect under the lock, then join it with the lock
        // released. Looping this way keeps the critical section free of both
        // allocation and `cancelTask`, so a task that itself calls `spawn` or
        // `cancel` cannot deadlock against teardown.
        while (true) {
            self.mutex.lockUncancelable(self.io);
            var found: ?*Effect = null;
            for (self.effects.items) |eff| {
                if (eff.scope == scope) {
                    found = eff;
                    break;
                }
            }
            if (found) |eff| _ = self.unlinkLocked(eff);
            self.mutex.unlock(self.io);

            const eff = found orelse return;
            self.cancelTask(eff);
            if (eff.state.load(.acquire) != .completed) eff.state.store(.cancelled, .release);
            self.alloc.destroy(eff);
        }
    }

    /// Remove `eff` from the live list. Caller must hold `mutex`.
    fn unlinkLocked(self: *Scheduler, eff: *Effect) bool {
        for (self.effects.items, 0..) |e, idx| {
            if (e == eff) {
                _ = self.effects.orderedRemove(idx);
                return true;
            }
        }
        return false;
    }
};

/// The task body `std.Io` runs for each effect.
fn runEffect(eff: *Effect) void {
    eff.run(eff.ctx, eff) catch {
        eff.state.store(.failed, .release);
    };
    if (!eff.cancelled.load(.seq_cst)) eff.state.store(.completed, .release);
}
