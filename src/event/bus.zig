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
    listeners: std.ArrayListUnmanaged(*Listener) = .empty,
    /// Dynamic (C-ABI) listeners: string-keyed events with byte payloads.
    dyn_listeners: std.ArrayListUnmanaged(DynListener) = .empty,
    next_sub_id: usize = 1,

    pub fn init(alloc: std.mem.Allocator) EventBus {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *EventBus) void {
        for (self.listeners.items) |l| self.alloc.destroy(l);
        self.listeners.deinit(self.alloc);
        for (self.dyn_listeners.items) |*l| self.alloc.free(l.name);
        self.dyn_listeners.deinit(self.alloc);
    }

    /// Subscribe `handler` to event type `E` on `scope`. The returned
    /// `Disposable` unsubscribes early; it is also auto-registered on the
    /// scope, so disposing the scope revokes it automatically.
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
        try self.listeners.append(self.alloc, listener);
        try scope.attach(disp);
        return disp;
    }

    /// Fire-and-forget: invoke every matching listener in priority order.
    pub fn emit(self: *EventBus, comptime E: type, emit_scope: *Scope, payload: *const E) !void {
        const snap = try dispatcher.collect(self, E, emit_scope);
        defer self.alloc.free(snap);
        var first_err: ?anyerror = null;
        for (snap) |l| {
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
        const snap = try dispatcher.collect(self, E, emit_scope);
        defer self.alloc.free(snap);

        if (snap.len == 0) return;
        var errs = try self.alloc.alloc(?anyerror, snap.len);
        defer self.alloc.free(errs);
        for (errs) |*e| e.* = null;

        var threads: []std.Thread = try self.alloc.alloc(std.Thread, snap.len);
        defer self.alloc.free(threads);
        for (snap, 0..) |l, i| {
            threads[i] = try std.Thread.spawn(.{}, parallelRun, .{ l, emit_scope, payload, &errs[i] });
        }
        for (threads) |t| t.join();

        for (errs) |e| if (e) |err| return err;
    }

    /// Invoke listeners in order; stop at the first "bailed" (truthy) result.
    /// Returns that result, or `null` if none bailed.
    pub fn bail(self: *EventBus, comptime E: type, emit_scope: *Scope, payload: *const E) !?event.ReturnOf(E) {
        const snap = try dispatcher.collect(self, E, emit_scope);
        defer self.alloc.free(snap);
        var slot: event.ReturnOf(E) = undefined;
        for (snap) |l| {
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
        const snap = try dispatcher.collect(self, E, emit_scope);
        defer self.alloc.free(snap);
        var slot: event.ReturnOf(E) = seed;
        for (snap) |l| {
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
        errdefer self.alloc.free(owned);

        const sub_id = self.next_sub_id;
        self.next_sub_id += 1;
        try self.dyn_listeners.append(self.alloc, .{
            .name = owned,
            .scope = scope,
            .cb = cb,
            .userdata = userdata,
            .sub_id = sub_id,
        });

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
    pub fn emitDynamic(
        self: *EventBus,
        emit_scope: *Scope,
        name: [:0]const u8,
        payload: ?*const anyopaque,
        len: usize,
    ) void {
        for (self.dyn_listeners.items) |*l| {
            if (l.removed) continue;
            if (!std.mem.eql(u8, l.name, name)) continue;
            if (!l.scope.isAlive()) continue;
            if (!emit_scope.isWithin(l.scope)) continue;
            l.cb(l.userdata, name.ptr, payload, len);
        }
    }
};

fn parallelRun(l: *Listener, emit_scope: *Scope, payload: *const anyopaque, err: *?anyerror) void {
    l.call(emit_scope, payload, null) catch |e| {
        err.* = e;
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
