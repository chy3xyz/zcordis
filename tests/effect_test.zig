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
