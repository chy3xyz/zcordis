//! Integration tests for the Effect Scheduler: cancellable background effects
//! and scope-owned lifecycle.

const std = @import("std");
const cordis = @import("cordis");

test "effect runs, then is cancelled and joined on scope dispose" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Allocate the task state on the test allocator (NOT the scope arena) so we
    // can still observe it after the scope is disposed.
    const Ticker = struct { ticks: u32 = 0, io: std.Io };
    const ticker = try std.testing.allocator.create(Ticker);
    defer std.testing.allocator.destroy(ticker);
    ticker.* = .{ .io = ctx.io() };

    const Run = struct {
        fn run(t: *Ticker, eff: *cordis.Effect) !void {
            while (!eff.cancelled.load(.seq_cst) and t.ticks < 5) {
                t.ticks += 1;
                std.Io.sleep(t.io, std.Io.Duration.fromMilliseconds(5), .real) catch {};
            }
        }
    };

    _ = try ctx.root.spawn(Ticker, ticker, Run.run);
    // Let it tick a few times.
    std.Io.sleep(ctx.io(), std.Io.Duration.fromMilliseconds(30), .real) catch {};
    try std.testing.expect(ticker.ticks > 0);

    // Disposing the owning scope must cancel and join the effect cleanly.
    ctx.root.dispose();
    try std.testing.expect(ticker.ticks >= 1);
}

test "effect cancellation flag is observable from the task" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Flag = struct { seen_cancel: bool = false, io: std.Io };
    const flag = try std.testing.allocator.create(Flag);
    defer std.testing.allocator.destroy(flag);
    flag.* = .{ .io = ctx.io() };

    const Run = struct {
        fn run(f: *Flag, eff: *cordis.Effect) !void {
            // Busy-spin until cancelled (the scheduler sets the flag on dispose).
            while (!eff.cancelled.load(.seq_cst)) {
                std.Io.sleep(f.io, std.Io.Duration.fromMilliseconds(1), .real) catch {};
            }
            f.seen_cancel = true;
        }
    };

    _ = try ctx.root.spawn(Flag, flag, Run.run);
    ctx.root.dispose();
    try std.testing.expect(flag.seen_cancel);
}

// Hammer the scheduler's effect list from several threads at once. Without the
// scheduler lock, concurrent `spawn` (append) and `cancel` (ordered remove)
// interleave on the same `ArrayListUnmanaged` and corrupt it; the
// `SafeAllocator` behind `std.testing.allocator` then panics on the resulting
// double free / write-after-free, and any drop fails the leak check.
test "concurrent spawn and cancel from many threads keeps the scheduler intact" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Body = struct {};
    const Run = struct {
        fn run(b: *Body, eff: *cordis.Effect) !void {
            _ = b;
            // Park in an I/O call so cancellation interrupts real work.
            std.Io.sleep(eff.scope.runtime.io(), std.Io.Duration.fromMilliseconds(50), .real) catch {};
        }
    };

    const Hammer = struct {
        fn go(c: *cordis.Context, b: *Body, rounds: u32) void {
            var i: u32 = 0;
            while (i < rounds) : (i += 1) {
                const eff = c.root.spawn(Body, b, Run.run) catch continue;
                c.scheduler.cancel(eff);
            }
        }
    };

    var body = Body{};
    const rounds = 100;
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Hammer.go, .{ ctx, &body, rounds });
    for (threads) |t| t.join();
}

// Two threads racing to cancel the *same* effect. Only the thread that wins the
// unlink may drive the join: a loser that also called `Future.cancel` on the
// same future would trip `Threaded.cancel`'s `unreachable` (a double cancel) and
// race the winner's `destroy`.
test "concurrent cancel of one effect is safe" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Body = struct {};
    const Run = struct {
        fn run(b: *Body, eff: *cordis.Effect) !void {
            _ = b;
            // Park long enough that both cancellers arrive while it is live.
            std.Io.sleep(eff.scope.runtime.io(), std.Io.Duration.fromMilliseconds(20), .real) catch {};
        }
    };
    const Race = struct {
        fn go(c: *cordis.Context, e: *cordis.Effect) void {
            c.scheduler.cancel(e);
        }
    };

    var body = Body{};
    var i: u32 = 0;
    while (i < 400) : (i += 1) {
        const eff = try ctx.root.spawn(Body, &body, Run.run);
        var a = try std.Thread.spawn(.{}, Race.go, .{ ctx, eff });
        var b = try std.Thread.spawn(.{}, Race.go, .{ ctx, eff });
        a.join();
        b.join();
    }
}
