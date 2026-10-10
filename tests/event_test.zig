//! Integration tests for the typed Event system: scope-aware dispatch, the five
//! dispatch modes, and automatic revocation on scope disposal.

const std = @import("std");
const cordis = @import("cordis");

// Shared counters live in a service so handlers (fixed fn signature) can record
// activity without capturing test-local variables.
const Counters = struct { root_hits: u32 = 0, sub_hits: u32 = 0 };

test "emit reaches scope-aware listeners and auto-revokes on dispose" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Msg = struct { x: u32 };
    _ = try ctx.provide(Counters, "counters", .{}, null);

    const H = struct {
        fn root(s: *cordis.Scope, m: *const Msg) !void {
            _ = m;
            s.get(Counters, "counters").?.root_hits += 1;
        }
        fn sub(s: *cordis.Scope, m: *const Msg) !void {
            _ = m;
            s.get(Counters, "counters").?.sub_hits += 1;
        }
    };

    _ = try ctx.on(Msg, H.root, .{});
    const sub = try ctx.child("sub");
    _ = try sub.on(Msg, H.sub, .{});

    var m = Msg{ .x = 1 };
    try sub.emit(Msg, &m); // both root and sub fire (sub is within root)
    const c = ctx.get(Counters, "counters").?;
    try std.testing.expectEqual(@as(u32, 1), c.root_hits);
    try std.testing.expectEqual(@as(u32, 1), c.sub_hits);

    // Dispose the sub-scope: its listener must be revoked automatically.
    const before_root = c.root_hits;
    sub.dispose();
    try ctx.emit(Msg, &m); // only root fires now
    try std.testing.expectEqual(@as(u32, before_root + 1), c.root_hits);
    try std.testing.expectEqual(@as(u32, 1), c.sub_hits);
}

test "waterfall returns the last handler's value (seed overwritten)" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Score = struct {
        v: i32,
        pub const Return = i32;
    };
    const H = struct {
        fn scale(s: *cordis.Scope, e: *const Score) !i32 {
            _ = s;
            return e.v * 2;
        }
    };
    _ = try ctx.on(Score, H.scale, .{});

    var sc = Score{ .v = 5 };
    const result = try ctx.waterfall(Score, &sc, 100);
    try std.testing.expectEqual(@as(i32, 10), result);
}

test "bail returns the first truthy (bailed) value" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Score = struct {
        v: i32,
        pub const Return = i32;
    };
    const H = struct {
        fn zero(s: *cordis.Scope, e: *const Score) !i32 {
            _ = s;
            _ = e;
            return 0; // not a bail
        }
        fn answer(s: *cordis.Scope, e: *const Score) !i32 {
            _ = s;
            _ = e;
            return 42; // bails
        }
    };
    _ = try ctx.on(Score, H.zero, .{ .priority = 2 });
    _ = try ctx.on(Score, H.answer, .{ .priority = 1 });

    var sc = Score{ .v = 0 };
    const r = try ctx.bail(Score, &sc);
    try std.testing.expectEqual(@as(?i32, 42), r);
}

test "once listener fires a single time then auto-unsubscribes" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Msg = struct { x: u32 };
    _ = try ctx.provide(Counters, "counters", .{}, null);
    const H = struct {
        fn once(s: *cordis.Scope, m: *const Msg) !void {
            _ = m;
            s.get(Counters, "counters").?.root_hits += 1;
        }
    };
    _ = try ctx.on(Msg, H.once, .{ .once = true });

    var m = Msg{ .x = 1 };
    try ctx.emit(Msg, &m);
    try ctx.emit(Msg, &m);
    try std.testing.expectEqual(@as(u32, 1), ctx.get(Counters, "counters").?.root_hits);
}

test "dynamic events: C-style subscribe / emit / unsubscribe" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    var hits: u32 = 0;
    const cb: cordis.abi.DynCallback = struct {
        fn call(userdata: ?*anyopaque, name: [*:0]const u8, payload: ?*const anyopaque, len: usize) callconv(.c) void {
            _ = name;
            const h: *u32 = @ptrCast(@alignCast(userdata.?));
            h.* += 1;
            if (payload) |p| {
                // payload bytes must round-trip
                const bytes = @as([*]const u8, @ptrCast(p))[0..len];
                std.debug.assert(bytes.len == 2 and bytes[0] == 'h' and bytes[1] == 'i');
            }
        }
    }.call;

    const id = try ctx.events.subscribeDynamic(ctx.root, "greet", cb, &hits);
    const payload = "hi";
    ctx.events.emitDynamic(ctx.root, "greet", payload.ptr, payload.len);
    try std.testing.expectEqual(@as(u32, 1), hits);

    ctx.events.unsubscribeDynamic(id);
    ctx.events.emitDynamic(ctx.root, "greet", payload.ptr, payload.len);
    try std.testing.expectEqual(@as(u32, 1), hits);
}

test "dynamic events: scoped auto-revoke on scope dispose" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    var hits: u32 = 0;
    const cb: cordis.abi.DynCallback = struct {
        fn call(userdata: ?*anyopaque, name: [*:0]const u8, payload: ?*const anyopaque, len: usize) callconv(.c) void {
            _ = name;
            _ = payload;
            _ = len;
            const h: *u32 = @ptrCast(@alignCast(userdata.?));
            h.* += 1;
        }
    }.call;

    const sub = try ctx.child("sub");
    _ = try ctx.events.subscribeDynamic(sub, "greet", cb, &hits);
    const payload = "hi";

    // Emit from the sub-scope: the sub-scoped listener is within → fires.
    ctx.events.emitDynamic(sub, "greet", payload.ptr, payload.len);
    try std.testing.expectEqual(@as(u32, 1), hits);

    sub.dispose();
    ctx.events.emitDynamic(sub, "greet", payload.ptr, payload.len);
    try std.testing.expectEqual(@as(u32, 1), hits);
}

/// Concurrent `parallel` handlers must not race on shared state, so the
/// counters here are atomic (the sequential `emit` tests above use plain u32).
const ParCounters = struct {
    hits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

test "parallel runs every listener, then surfaces the first error" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Msg = struct { x: u32 };
    _ = try ctx.provide(ParCounters, "par", .{}, null);

    const H = struct {
        fn bump(s: *cordis.Scope, m: *const Msg) !void {
            _ = m;
            _ = s.get(ParCounters, "par").?.hits.fetchAdd(1, .seq_cst);
        }
        fn boom(s: *cordis.Scope, m: *const Msg) !void {
            _ = s;
            _ = m;
            return error.Kaboom;
        }
    };

    _ = try ctx.on(Msg, H.bump, .{});
    _ = try ctx.on(Msg, H.bump, .{});

    var m = Msg{ .x = 1 };
    try ctx.parallel(Msg, &m);
    try std.testing.expectEqual(@as(u32, 2), ctx.get(ParCounters, "par").?.hits.load(.seq_cst));

    // A failing listener must not stop the others, and its error must surface.
    _ = try ctx.on(Msg, H.boom, .{});
    try std.testing.expectError(error.Kaboom, ctx.parallel(Msg, &m));
    try std.testing.expectEqual(@as(u32, 4), ctx.get(ParCounters, "par").?.hits.load(.seq_cst));
}

/// Each handler waits (bounded) for the *other* to have entered. If `parallel`
/// dispatched them one after another, the first would spin out and fail with
/// `PeerNeverArrived`; only genuinely concurrent dispatch passes.
const Gate = struct {
    entered: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    both_seen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

test "parallel dispatches handlers concurrently, not one after another" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Msg = struct { x: u32 };
    _ = try ctx.provide(Gate, "gate", .{}, null);

    const H = struct {
        fn rendezvous(s: *cordis.Scope, m: *const Msg) !void {
            _ = m;
            const g = s.get(Gate, "gate").?;
            _ = g.entered.fetchAdd(1, .seq_cst);
            var spins: u32 = 0;
            while (g.entered.load(.seq_cst) < 2) : (spins += 1) {
                if (spins > 5000) return error.PeerNeverArrived;
                std.Io.sleep(s.runtime.io(), std.Io.Duration.fromMilliseconds(1), .real) catch {};
            }
            _ = g.both_seen.fetchAdd(1, .seq_cst);
        }
    };

    _ = try ctx.on(Msg, H.rendezvous, .{});
    _ = try ctx.on(Msg, H.rendezvous, .{});

    var m = Msg{ .x = 1 };
    try ctx.parallel(Msg, &m);
    try std.testing.expectEqual(@as(u32, 2), ctx.get(Gate, "gate").?.both_seen.load(.seq_cst));
}

// `parallel` invokes each listener exactly once per emit, so `once` must be
// honoured there too — the same auto-removal `emit`/`bail`/`waterfall` do.
test "parallel honours once" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Msg = struct { x: u32 };
    _ = try ctx.provide(ParCounters, "par", .{}, null);

    const H = struct {
        fn bump(s: *cordis.Scope, m: *const Msg) !void {
            _ = m;
            _ = s.get(ParCounters, "par").?.hits.fetchAdd(1, .seq_cst);
        }
    };
    _ = try ctx.on(Msg, H.bump, .{ .once = true });

    var m = Msg{ .x = 1 };
    try ctx.parallel(Msg, &m);
    try std.testing.expectEqual(@as(u32, 1), ctx.get(ParCounters, "par").?.hits.load(.seq_cst));

    // The listener must be gone by the second emit.
    try ctx.parallel(Msg, &m);
    try std.testing.expectEqual(@as(u32, 1), ctx.get(ParCounters, "par").?.hits.load(.seq_cst));
}

// Emit from the main thread while other threads churn subscriptions, so the
// snapshot an `emit` is dispatching to is being unsubscribed underneath it.
// This is what the bus lock and the listener reference count exist for: the
// lock keeps the list edit itself safe, and `Listener.refs` keeps a listener
// record alive until the in-flight `emit` has finished calling it.
test "emit stays sound while other threads churn subscriptions" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Msg = struct { x: u32 };
    const Sink = struct { hits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0) };
    _ = try ctx.provide(Sink, "sink", .{}, null);

    const H = struct {
        fn on(s: *cordis.Scope, m: *const Msg) !void {
            _ = m;
            _ = s.get(Sink, "sink").?.hits.fetchAdd(1, .seq_cst);
        }
    };

    // Subscribe on the long-lived root scope, then immediately unsubscribe:
    // these listeners are live in the bus while the emitter is dispatching, so
    // the emitter's snapshot genuinely races against their teardown.
    const Churn = struct {
        fn go(c: *cordis.Context, rounds: u32) void {
            var i: u32 = 0;
            while (i < rounds) : (i += 1) {
                const d = c.on(Msg, H.on, .{}) catch continue;
                d.call(d.ctx);
            }
        }
    };

    var churners: [3]std.Thread = undefined;
    for (&churners) |*t| t.* = try std.Thread.spawn(.{}, Churn.go, .{ ctx, 100 });

    var m = Msg{ .x = 1 };
    var rounds: u32 = 0;
    while (rounds < 300) : (rounds += 1) try ctx.emit(Msg, &m);

    for (churners) |t| t.join();
}

// `isBailed` must treat a non-zero enum as a bail. Enums carry their own
// `@typeInfo` tag rather than `.int`, so the integer case alone would let every
// enum return "not bailed" even though the documented contract says otherwise.
test "bail treats a non-zero enum result as a bail" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Verdict = enum(u8) { keep_going = 0, stop = 1 };
    const Ask = struct {
        v: u32,
        pub const Return = Verdict;
    };
    const H = struct {
        fn answer(s: *cordis.Scope, e: *const Ask) !Verdict {
            _ = s;
            return if (e.v == 0) .keep_going else .stop;
        }
    };
    _ = try ctx.on(Ask, H.answer, .{});

    var zero = Ask{ .v = 0 };
    try std.testing.expectEqual(@as(?Verdict, null), try ctx.bail(Ask, &zero));

    var one = Ask{ .v = 1 };
    try std.testing.expectEqual(@as(?Verdict, .stop), try ctx.bail(Ask, &one));
}

// `emitDynamic` releases the bus lock before invoking callbacks, so a callback
// may re-enter the bus. This pins both directions of that re-entrancy — a
// callback that unsubscribes itself, and one that adds a new subscriber, both
// mid-emit. Holding the lock across callbacks would deadlock here, because
// `std.Io.Mutex` is not reentrant.
test "dynamic callbacks may re-enter the bus during emit" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Shared = struct {
        bus: *cordis.EventBus,
        root: *cordis.Scope,
        self_id: usize = 0,
        other_hits: u32 = 0,
        added_id: ?usize = null,
    };
    var sh = Shared{ .bus = &ctx.events, .root = ctx.root };

    const H = struct {
        // Removes itself from the bus while the bus is dispatching to it.
        fn self_removing(ud: ?*anyopaque, name: [*:0]const u8, p: ?*const anyopaque, len: usize) callconv(.c) void {
            _ = name;
            _ = p;
            _ = len;
            const s: *Shared = @ptrCast(@alignCast(ud.?));
            s.bus.unsubscribeDynamic(s.self_id);
        }
        // Adds a fresh subscriber while the bus is dispatching.
        fn adding(ud: ?*anyopaque, name: [*:0]const u8, p: ?*const anyopaque, len: usize) callconv(.c) void {
            _ = p;
            _ = len;
            const s: *Shared = @ptrCast(@alignCast(ud.?));
            s.other_hits += 1;
            if (s.added_id == null) {
                s.added_id = s.bus.subscribeDynamic(s.root, std.mem.span(name), noop, null) catch null;
            }
        }
        fn noop(ud: ?*anyopaque, name: [*:0]const u8, p: ?*const anyopaque, len: usize) callconv(.c) void {
            _ = ud;
            _ = name;
            _ = p;
            _ = len;
        }
    };

    sh.self_id = try ctx.events.subscribeDynamic(ctx.root, "ping", H.self_removing, &sh);
    _ = try ctx.events.subscribeDynamic(ctx.root, "ping", H.adding, &sh);

    const payload = "x";
    ctx.events.emitDynamic(ctx.root, "ping", payload.ptr, payload.len);
    try std.testing.expectEqual(@as(u32, 1), sh.other_hits);
    try std.testing.expect(sh.added_id != null);

    // Second emit: the self-removing one is gone, the added one is live.
    ctx.events.emitDynamic(ctx.root, "ping", payload.ptr, payload.len);
    try std.testing.expectEqual(@as(u32, 2), sh.other_hits);
}
