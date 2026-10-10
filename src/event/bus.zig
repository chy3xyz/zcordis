//! Cordis Native — event bus (section IX).
//!
//! Holds all registered listeners and implements the five dispatch modes.
//! Listeners are type-erased; dispatch is instantiated per event type so the
//! handler still receives a strongly-typed payload.

const std = @import("std");
const Scope = @import("../core/scope.zig").Scope;
const Disposable = @import("../core/scope.zig").Disposable;
const makeDisposable = @import("../core/scope.zig").makeDisposable;
const Listener = @import("listener.zig").Listener;
const unsubscribe = @import("listener.zig").unsubscribe;
const event = @import("event.zig");
const dispatcher = @import("dispatcher.zig");
const DynCallback = @import("../abi/c.zig").DynCallback;

pub const EventBus = struct {
    alloc: std.mem.Allocator,
    /// The runtime's `std.Io`, used to run `parallel` handlers concurrently and
    /// to park on `mutex`.
    io: std.Io,
    /// Guards `listeners`, `dyn_listeners` and `next_sub_id`.
    ///
    /// Never held while a handler or dynamic callback runs: those are user code
    /// that may re-enter the bus (`subscribe`/`unsubscribe`), and
    /// `std.Io.Mutex` is not reentrant.
    mutex: std.Io.Mutex = .init,
    listeners: std.ArrayListUnmanaged(*Listener) = .empty,
    /// Dynamic (C-ABI) listeners: string-keyed events with byte payloads.
    dyn_listeners: std.ArrayListUnmanaged(DynListener) = .empty,
    next_sub_id: usize = 1,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) EventBus {
        return .{ .alloc = alloc, .io = io };
    }

    pub fn deinit(self: *EventBus) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // Teardown is quiescent by construction (`Context.deinit` has already
        // disposed every plugin and cancelled every effect), so no dispatch can
        // still hold a reference to a listener we free here.
        for (self.listeners.items) |l| self.alloc.destroy(l);
        self.listeners.deinit(self.alloc);
        for (self.dyn_listeners.items) |*l| self.alloc.free(l.name);
        self.dyn_listeners.deinit(self.alloc);
    }

    /// Subscribe `handler` to event type `E` on `scope`. The returned
    /// `Disposable` unsubscribes early; it is also auto-registered on the
    /// scope, so disposing the scope revokes it automatically.
    ///
    /// The bus lock covers the append only: `scope.attach` takes the scope's own
    /// lock, and the two are never held at once (see `EventBus.mutex`).
    pub fn subscribe(
        self: *EventBus,
        comptime E: type,
        scope: *Scope,
        handler: event.Handler(E),
        opts: event.SubscribeOptions,
    ) !Disposable {
        const listener = try self.alloc.create(Listener);
        const disp = makeDisposable(Listener, listener, unsubscribe);
        listener.* = .{
            .event_hash = event.eventKey(E),
            .scope = scope,
            .priority = opts.priority,
            .once = opts.once,
            .global = opts.global,
            .call = event.makeWrapper(E, handler),
            .removed = false,
            .disp = disp,
        };

        self.mutex.lockUncancelable(self.io);
        self.listeners.append(self.alloc, listener) catch |e| {
            self.mutex.unlock(self.io);
            self.alloc.destroy(listener);
            return e;
        };
        self.mutex.unlock(self.io);

        try scope.attach(disp);
        return disp;
    }

    /// Fire-and-forget: invoke every matching listener in priority order.
    pub fn emit(self: *EventBus, comptime E: type, emit_scope: *Scope, payload: *const E) !void {
        var scratch: [dispatcher.inline_listeners]*Listener = undefined;
        const snap = try dispatcher.collect(self, E, emit_scope, &scratch);
        defer snap.release(self);
        var first_err: ?anyerror = null;
        for (snap.items) |l| {
            if (l.removed) continue;
            l.call(emit_scope, payload, null) catch |e| {
                if (first_err == null) first_err = e;
            };
            if (l.once) unsubscribe(l);
        }
        if (first_err) |e| return e;
    }

    /// Invoke all listeners concurrently; aggregate the first error. Return
    /// values are ignored (as in Cordis' `parallel`).
    pub fn parallel(self: *EventBus, comptime E: type, emit_scope: *Scope, payload: *const E) !void {
        var scratch: [dispatcher.inline_listeners]*Listener = undefined;
        const snap = try dispatcher.collect(self, E, emit_scope, &scratch);
        defer snap.release(self);
        if (snap.items.len == 0) return;

        const jobs = try self.alloc.alloc(ParallelJob, snap.items.len);
        defer self.alloc.free(jobs);
        const futures = try self.alloc.alloc(std.Io.Future(void), snap.items.len);
        defer self.alloc.free(futures);
        const errs = try self.alloc.alloc(?anyerror, snap.items.len);
        defer self.alloc.free(errs);
        for (errs) |*e| e.* = null;

        var started: usize = 0;
        // If a later `concurrent` call fails, join the tasks already running so
        // that none outlives this function's buffers.
        errdefer {
            for (futures[0..started]) |*f| f.await(self.io);
        }
        for (snap.items, 0..) |l, i| {
            jobs[i] = .{ .listener = l, .scope = emit_scope, .payload = payload, .err = &errs[i] };
            futures[i] = try std.Io.concurrent(self.io, runParallel, .{&jobs[i]});
            started += 1;
        }
        for (futures[0..started]) |*f| f.await(self.io);

        // `once` applies here too: parallel invokes each listener exactly once, so
        // the auto-removal that `emit`/`bail`/`waterfall` perform applies as well.
        // Done after the join; the snapshot's references keep each record alive
        // until `snap.release` below.
        for (snap.items) |l| {
            if (l.once) unsubscribe(l);
        }

        for (errs) |e| if (e) |err| return err;
    }

    /// Invoke listeners in order; stop at the first "bailed" (truthy) result.
    /// Returns that result, or `null` if none bailed.
    pub fn bail(self: *EventBus, comptime E: type, emit_scope: *Scope, payload: *const E) !?event.ReturnOf(E) {
        var scratch: [dispatcher.inline_listeners]*Listener = undefined;
        const snap = try dispatcher.collect(self, E, emit_scope, &scratch);
        defer snap.release(self);
        var slot: event.ReturnOf(E) = undefined;
        for (snap.items) |l| {
            if (l.removed) continue;
            l.call(emit_scope, payload, &slot) catch {};
            if (dispatcher.isBailed(event.ReturnOf(E), slot)) {
                if (l.once) unsubscribe(l);
                return slot;
            }
            if (l.once) unsubscribe(l);
        }
        return null;
    }

    /// Like `bail`, but each handler is awaited; returns the first bailed
    /// result (here handlers are synchronous, so it is equivalent to `bail`).
    pub fn serial(self: *EventBus, comptime E: type, emit_scope: *Scope, payload: *const E) !?event.ReturnOf(E) {
        return self.bail(E, emit_scope, payload);
    }

    /// Chain listeners: each receives the running value; the final value is
    /// returned. The payload is shared (read-only) across all handlers.
    pub fn waterfall(
        self: *EventBus,
        comptime E: type,
        emit_scope: *Scope,
        payload: *const E,
        seed: event.ReturnOf(E),
    ) !event.ReturnOf(E) {
        var scratch: [dispatcher.inline_listeners]*Listener = undefined;
        const snap = try dispatcher.collect(self, E, emit_scope, &scratch);
        defer snap.release(self);
        var slot: event.ReturnOf(E) = seed;
        for (snap.items) |l| {
            if (l.removed) continue;
            l.call(emit_scope, payload, &slot) catch {};
            if (l.once) unsubscribe(l);
        }
        return slot;
    }

    // ── Dynamic (string-keyed, byte-payload) events ─────────────────────
    // The C ABI bridge: plugins address events by name string and opaque
    // bytes, trading away Zig's compile-time type safety for cross-language
    // reach.

    /// Subscribe `cb` to dynamic event `name`. The subscription is scoped and
    /// auto-revoked when `scope` disposes. Returns a subscription id for
    /// `unsubscribeDynamic`.
    pub fn subscribeDynamic(
        self: *EventBus,
        scope: *Scope,
        name: []const u8,
        cb: DynCallback,
        userdata: ?*anyopaque,
    ) !usize {
        const owned = try self.alloc.dupe(u8, name);

        self.mutex.lockUncancelable(self.io);
        const sub_id = self.next_sub_id;
        self.next_sub_id += 1;
        self.dyn_listeners.append(self.alloc, .{
            .name = owned,
            .scope = scope,
            .cb = cb,
            .userdata = userdata,
            .sub_id = sub_id,
        }) catch |e| {
            self.mutex.unlock(self.io);
            // Roll the name allocation back here, where it is unambiguously
            // ours. (An `errdefer` would also fire on the `scope.attach` failure
            // below, freeing a name the list still points at.)
            self.alloc.free(owned);
            return e;
        };
        self.mutex.unlock(self.io);

        // Auto-revoke on scope dispose (same guarantee as typed listeners).
        const Unsub = struct { bus: *EventBus, id: usize };
        const u = try scope.alloc().create(Unsub);
        u.* = .{ .bus = self, .id = sub_id };
        const disp = makeDisposable(Unsub, u, struct {
            fn run(x: *Unsub) void {
                x.bus.unsubscribeDynamic(x.id);
            }
        }.run);
        try scope.attach(disp);
        return sub_id;
    }

    /// Remove a dynamic subscription by id (idempotent).
    pub fn unsubscribeDynamic(self: *EventBus, sub_id: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.dyn_listeners.items, 0..) |*l, i| {
            if (l.sub_id == sub_id and !l.removed) {
                l.removed = true;
                self.alloc.free(l.name);
                _ = self.dyn_listeners.orderedRemove(i);
                return;
            }
        }
    }

    /// Fire dynamic event `name` (sentinel-terminated) with `len` raw payload
    /// bytes to every live, in-scope subscriber.
    ///
    /// The callbacks are C functions that may re-enter the bus
    /// (`subscribeDynamic`/`unsubscribeDynamic`), and `std.Io.Mutex` is not
    /// reentrant — so the lock must be released before any callback runs. The
    /// list is walked in small chunks: matching callbacks are gathered under the
    /// lock, then invoked unlocked. A chunk only captures the callback and its
    /// userdata, since the payload name comes from `name` and the scope
    /// filtering happens while collecting. (A callback that unsubscribes an
    /// entry this walk has not reached yet can shift the remaining indices; this
    /// stays safe, and a re-entrant unsubscribe during a fire-and-forget emit is
    /// already the racy case.)
    pub fn emitDynamic(
        self: *EventBus,
        emit_scope: *Scope,
        name: [:0]const u8,
        payload: ?*const anyopaque,
        len: usize,
    ) void {
        const Sink = struct { cb: DynCallback, userdata: ?*anyopaque };
        var chunk: [8]Sink = undefined;
        var cursor: usize = 0;
        while (true) {
            var n: usize = 0;
            var done = false;
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                while (cursor < self.dyn_listeners.items.len) {
                    const l = self.dyn_listeners.items[cursor];
                    cursor += 1;
                    if (l.removed) continue;
                    if (!std.mem.eql(u8, l.name, name)) continue;
                    if (!l.scope.isAlive()) continue;
                    if (!emit_scope.isWithin(l.scope)) continue;
                    chunk[n] = .{ .cb = l.cb, .userdata = l.userdata };
                    n += 1;
                    if (n == chunk.len) break;
                }
                done = cursor >= self.dyn_listeners.items.len;
            }
            for (chunk[0..n]) |s| s.cb(s.userdata, name.ptr, payload, len);
            if (done) return;
        }
    }
};

/// One `parallel` dispatch: a listener plus the slot where it reports an error.
/// Kept as a single struct parameter so it can be handed to
/// `std.Io.concurrent`, whose argument tuple mirrors the function signature.
const ParallelJob = struct {
    listener: *Listener,
    scope: *Scope,
    payload: *const anyopaque,
    err: *?anyerror,
};

fn runParallel(job: *ParallelJob) void {
    job.listener.call(job.scope, job.payload, null) catch |e| {
        job.err.* = e;
    };
}

/// A dynamic (C-ABI) subscription. `name` is owned by the bus and freed when
/// the subscription is removed (or the bus deinitializes).
const DynListener = struct {
    name: []const u8,
    scope: *Scope,
    cb: DynCallback,
    userdata: ?*anyopaque,
    sub_id: usize,
    removed: bool = false,
};
