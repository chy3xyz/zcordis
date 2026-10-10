//! zcordis micro-benchmarks — run with `zig build bench`.
//!
//! Deliberately *not* a statistical harness: each case prints one wall-clock
//! ns/op figure for a path the runtime spends time in, so a regression shows up
//! as a changed number instead of as silence. Compare runs on the same machine
//! and in the same build mode; `zig build bench -Doptimize=fast` is what makes
//! the absolute numbers meaningful.
//!
//! Cases are annotated `(alloc)` where the path allocates per call by design —
//! they exist so that cost stays visible rather than assumed.
//!
//! Before measuring anything, `main` exercises every workload once. A benchmark
//! whose workload silently fails measures nothing, so that check turns a
//! vacuous run into a visible failure instead of a plausible-looking number.

const std = @import("std");
const cordis = @import("cordis");

const Io = std.Io;

const Msg = struct { x: u32 };
const Hits = struct { n: u32 = 0 };

fn onMsg(s: *cordis.Scope, m: *const Msg) !void {
    _ = m;
    s.get(Hits, "hits").?.n +%= 1;
}

const EffCtx = struct {};
const EffState = struct { ctx: *cordis.Context, eff_ctx: *EffCtx };
const DisposeState = struct { ctx: *cordis.Context, eff_ctx: *EffCtx, per_scope: u32 };

fn effRun(c: *EffCtx, eff: *cordis.Effect) !void {
    _ = c;
    _ = eff;
}

fn hostLog(_: *cordis.wasm.Instance, _: []const i64) i64 {
    return 0;
}
fn hostEmit(_: *cordis.wasm.Instance, _: []const i64) i64 {
    return 0;
}

/// Everything a case needs, so bodies stay capture-free (Zig has no closures).
const Setup = struct {
    ctx: *cordis.Context,
    alloc: std.mem.Allocator,
    bytes: []const u8,
    hosts: []const cordis.wasm.HostFn,
    msg: Msg = .{ .x = 1 },
};

fn clockNs(io: Io) i96 {
    // `.awake` is the monotonic clock (CLOCK_MONOTONIC / CLOCK_UPTIME_RAW).
    return Io.Timestamp.now(io, .awake).nanoseconds;
}

/// Run `body(state, i)` `iters` times and print ns/op.
fn bench(
    io: Io,
    name: []const u8,
    comptime iters: u32,
    state: anytype,
    comptime body: fn (@TypeOf(state), u32) void,
) void {
    const t0 = clockNs(io);
    var i: u32 = 0;
    while (i < iters) : (i += 1) body(state, i);
    // `.awake` is monotonic, so the delta cannot be negative; clamp anyway so a
    // clock hiccup cannot panic the harness.
    const per: u64 = @intCast(@max(@divTrunc(clockNs(io) - t0, @as(i96, iters)), 0));
    std.debug.print("  {s:<34} {d:>9} ns/op   ({d} iters)\n", .{ name, per, iters });
}

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const alloc = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == 0);

    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();

    _ = try ctx.provide(Hits, "hits", .{}, null);
    // Four listeners, so `emit` has a non-trivial set to collect and order.
    var subs: [4]cordis.Disposable = undefined;
    for (&subs) |*d| d.* = try ctx.on(Msg, onMsg, .{});
    // Sanity: prove the emit workload actually reaches its handlers, so the
    // figure below cannot be fast merely because nothing ran.
    {
        const hits = ctx.get(Hits, "hits").?;
        const before = hits.n;
        var probe = Msg{ .x = 1 };
        try ctx.emit(Msg, &probe);
        if (hits.n != before + @as(u32, subs.len)) return error.EmitDidNotDispatch;
    }

    const bytes = try cordis.loader.wasm_demo.build(alloc);
    defer alloc.free(bytes);
    const hosts = [_]cordis.wasm.HostFn{ hostLog, hostEmit };

    // Sanity: prove the wasm workload does real work before timing it.
    {
        var m = try cordis.wasm.Module.load(alloc, bytes);
        defer m.deinit();
        var inst = try cordis.wasm.Instance.create(alloc, &m, null, &hosts, cordis.wasm.no_globals);
        defer inst.deinit();
        _ = try inst.callExport("init", &.{});
    }

    const mode = @import("builtin").mode;
    std.debug.print("\nzcordis benchmarks  (build mode: {s})\n", .{@tagName(mode)});
    if (mode == .debug) {
        std.debug.print(
            "WARNING: this is a debug build — allocation-heavy figures are dominated by\n" ++
                "         the SafeAllocator. Re-run with -Doptimize=fast for real numbers.\n",
            .{},
        );
    }
    std.debug.print("\n", .{});

    var s = Setup{ .ctx = ctx, .alloc = alloc, .bytes = bytes, .hosts = &hosts };

    bench(io, "emit, 4 listeners", 200_000, &s, struct {
        fn f(st: *Setup, _: u32) void {
            st.ctx.emit(Msg, &st.msg) catch {};
        }
    }.f);

    bench(io, "subscribe + unsubscribe (alloc)", 20_000, &s, struct {
        fn f(st: *Setup, _: u32) void {
            const d = st.ctx.on(Msg, onMsg, .{}) catch return;
            d.call(d.ctx);
        }
    }.f);

    var eff_ctx = EffCtx{};
    var es = EffState{ .ctx = ctx, .eff_ctx = &eff_ctx };
    bench(io, "spawn + cancel an effect", 3_000, &es, struct {
        fn f(st: *EffState, _: u32) void {
            const e = st.ctx.root.spawn(EffCtx, st.eff_ctx, effRun) catch return;
            st.ctx.scheduler.cancel(e);
        }
    }.f);

    // The scope-disposal path: `cancelForScope` walks the scheduler's effect list
    // once per effect it cancels, so this scaling is what makes that quadratic
    // term visible. Compare against 10x the listeners below: a linear path would
    // scale with the effect count, a quadratic one with its square.
    var ds = DisposeState{ .ctx = ctx, .eff_ctx = &eff_ctx, .per_scope = 20 };
    bench(io, "dispose scope holding 20 effects", 200, &ds, struct {
        fn f(st: *DisposeState, _: u32) void {
            const scope = st.ctx.child("bench20") catch return;
            var i: u32 = 0;
            while (i < st.per_scope) : (i += 1) {
                _ = scope.spawn(EffCtx, st.eff_ctx, effRun) catch {};
            }
            scope.dispose();
        }
    }.f);

    ds.per_scope = 200;
    bench(io, "dispose scope holding 200 effects", 100, &ds, struct {
        fn f(st: *DisposeState, _: u32) void {
            const scope = st.ctx.child("bench200") catch return;
            var i: u32 = 0;
            while (i < st.per_scope) : (i += 1) {
                _ = scope.spawn(EffCtx, st.eff_ctx, effRun) catch {};
            }
            scope.dispose();
        }
    }.f);

    bench(io, "Module.load: wasm parse (alloc)", 20_000, &s, struct {
        fn f(st: *Setup, _: u32) void {
            var m = cordis.wasm.Module.load(st.alloc, st.bytes) catch return;
            m.deinit();
        }
    }.f);

    bench(io, "wasm load+instantiate+init", 20_000, &s, struct {
        fn f(st: *Setup, _: u32) void {
            var m = cordis.wasm.Module.load(st.alloc, st.bytes) catch return;
            defer m.deinit();
            var inst = cordis.wasm.Instance.create(st.alloc, &m, null, st.hosts, cordis.wasm.no_globals) catch return;
            defer inst.deinit();
            _ = inst.callExport("init", &.{}) catch {};
        }
    }.f);

    std.debug.print("\n", .{});
}
