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
