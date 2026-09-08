//! Cordis Native — effect scheduler (sections XII–XIII).
//!
//! The scheduler owns the set of live effects. It runs each effect on its own
//! thread (cooperatively cancellable via `effect.cancelled`) and guarantees
//! that disposing a scope cancels every effect it spawned. The runtime's
//! `std.Io` handle is carried here so spawned tasks can perform async I/O.

const std = @import("std");
const Scope = @import("../core/scope.zig").Scope;
const Effect = @import("effect.zig").Effect;

pub const Scheduler = struct {
    alloc: std.mem.Allocator,
    io: ?std.Io,
    effects: std.ArrayListUnmanaged(*Effect) = .empty,
    next_id: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, io: ?std.Io) Scheduler {
        return .{ .alloc = alloc, .io = io };
    }

    pub fn deinit(self: *Scheduler) void {
        // Cancel everything still alive.
        while (self.effects.items.len > 0) {
            const eff = self.effects.items[self.effects.items.len - 1];
            self.effects.items.len -= 1;
            if (eff.state == .completed or eff.state == .cancelled) {
                self.alloc.destroy(eff);
                continue;
            }
            eff.cancelled.store(true, .seq_cst);
            if (eff.joinable) eff.thread.?.join();
            self.alloc.destroy(eff);
        }
        self.effects.deinit(self.alloc);
        // `ArrayListUnmanaged.deinit` frees the buffer but leaves `.len` set, so
        // reset explicitly — otherwise a later `cancelForScope` would iterate a
        // dangling buffer (DebugAllocator fills freed memory with 0xaa).
        self.effects = .empty;
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
        eff.* = .{
            .id = self.genId(),
            .scope = scope,
            .state = .created,
            .cancelled = std.atomic.Value(bool).init(false),
            .thread = null,
            .joinable = false,
            .run = w,
            .ctx = ctx,
        };
        try self.effects.append(self.alloc, eff);

        eff.thread = try std.Thread.spawn(.{}, runThread, .{eff});
        eff.joinable = true;
        eff.state = .running;
        return eff;
    }

    /// Request cancellation of `eff`. Blocks until its thread has joined, then
    /// frees it.
    pub fn cancel(self: *Scheduler, eff: *Effect) void {
        if (eff.state == .completed or eff.state == .cancelled) {
            // Still need to free if not already freed. removeEffect handles it.
            if (self.removeEffect(eff)) self.alloc.destroy(eff);
            return;
        }
        eff.cancelled.store(true, .seq_cst);
        if (eff.joinable) {
            eff.thread.?.join();
            eff.joinable = false;
        }
        eff.state = .cancelled;
        if (self.removeEffect(eff)) self.alloc.destroy(eff);
    }

    /// Cancel and free all effects owned by `scope` (called on scope dispose).
    pub fn cancelForScope(self: *Scheduler, scope: *Scope) void {
        var i: usize = 0;
        while (i < self.effects.items.len) {
            const eff = self.effects.items[i];
            if (eff.scope == scope) {
                self.cancel(eff);
                // cancel removed it from the list; do not advance `i`.
            } else {
                i += 1;
            }
        }
    }

    fn removeEffect(self: *Scheduler, eff: *Effect) bool {
        for (self.effects.items, 0..) |e, idx| {
            if (e == eff) {
                _ = self.effects.orderedRemove(idx);
                return true;
            }
        }
        return false;
    }
};

fn runThread(eff: *Effect) void {
    eff.run(eff.ctx, eff) catch {
        eff.state = .failed;
    };
    if (!eff.cancelled.load(.seq_cst)) eff.state = .completed;
}
