//! Cordis Native — basic composition demo.
//!
//! Run with `zig build run`. Shows the four pillars from `dev.md`:
//!   * typed services (provide/get with compile-time type safety)
//!   * scope-aware events (auto-revoked on scope disposal)
//!   * cancellable effects (background task tied to a scope)
//!   * dependency-ordered plugins (topological init)

const std = @import("std");
const cordis = @import("cordis");

// Module-level counters so the event handlers (plain fn pointers) can record
// how many times they fired. Used to prove scope-aware auto-revocation.
var g_root_hits: u32 = 0;
var g_sub_hits: u32 = 0;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const alloc = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();

    // ── 1. Typed service ───────────────────────────────────────────────
    const Logger = struct { tag: []const u8 };
    _ = try ctx.provide(Logger, "logger", .{ .tag = "app" }, null);
    const lg = ctx.get(Logger, "logger").?;
    std.debug.print("[service] logger tag = {s}\n", .{lg.tag});

    // ── 2. Typed events ───────────────────────────────────────────────
    const Message = struct { content: []const u8 };
    const Score = struct {
        content: []const u8,
        pub const Return = i32;
    };

    // Counters so we can observe dispatch behaviour.
    const onMessage = struct {
        fn call(scope: *cordis.Scope, m: *const Message) !void {
            _ = scope;
            g_root_hits += 1;
            std.debug.print("[event] root got message: {s}\n", .{m.content});
        }
    }.call;
    _ = try ctx.on(Message, onMessage, .{});

    var msg = Message{ .content = "hello cordis" };
    try ctx.emit(Message, &msg);

    // Value-returning dispatch (waterfall over a score).
    const scorer = struct {
        fn call(scope: *cordis.Scope, s: *const Score) !i32 {
            _ = scope;
            _ = s;
            return 42;
        }
    }.call;
    _ = try ctx.on(Score, scorer, .{ .priority = 1 });

    var score = Score{ .content = "rate me" };
    const result = try ctx.waterfall(Score, &score, 0);
    std.debug.print("[event] waterfall score = {}\n", .{result});

    // ── 3. Scope-aware auto-revoke ─────────────────────────────────────
    const sub = try ctx.child("sub");
    const onSub = struct {
        fn call(scope: *cordis.Scope, m: *const Message) !void {
            _ = scope;
            g_sub_hits += 1;
            std.debug.print("[event] sub got message: {s}\n", .{m.content});
        }
    }.call;
    _ = try sub.on(Message, onSub, .{});

    // Emit on the sub-scope: BOTH root and sub listeners fire (sub is within).
    try sub.emit(Message, &msg);

    // Now dispose the sub-scope; its listener must be revoked automatically.
    sub.dispose();
    const before_root = g_root_hits;
    const before_sub = g_sub_hits;
    try ctx.emit(Message, &msg);
    std.debug.print(
        "[event] after sub disposed: root fired once = {}, sub listener revoked = {}\n",
        .{ g_root_hits == before_root + 1, g_sub_hits == before_sub },
    );

    // ── 4. Cancellable effect ─────────────────────────────────────────
    const Ticker = struct { ticks: u32 = 0, io: std.Io };
    const ticker = try ctx.root.alloc().create(Ticker);
    ticker.* = .{ .io = ctx.io() };
    const run = struct {
        fn tick(t: *Ticker, eff: *cordis.Effect) !void {
            while (!eff.cancelled.load(.seq_cst) and t.ticks < 3) {
                t.ticks += 1;
                std.Io.sleep(t.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
            }
            std.debug.print("[effect] ticker ran {} ticks\n", .{t.ticks});
        }
    }.tick;
    _ = try ctx.root.spawn(Ticker, ticker, run);

    // ── 5. Dependency-ordered plugins ─────────────────────────────────
    const LoggerPlugin = struct {
        fn init(scope: *cordis.Scope) !void {
            const lg2 = scope.get(Logger, "logger").?;
            std.debug.print("[plugin] logger-plugin (sees {s})\n", .{lg2.tag});
        }
    };
    const BotPlugin = struct {
        fn init(scope: *cordis.Scope) !void {
            const lg2 = scope.get(Logger, "logger") orelse return error.NoLogger;
            std.debug.print("[plugin] bot-plugin (depends on logger, sees {s})\n", .{lg2.tag});
        }
    };
    try ctx.load(.{ .name = "logger-plugin", .init = LoggerPlugin.init });
    try ctx.load(.{
        .name = "bot-plugin",
        .init = BotPlugin.init,
        .depends_on = &.{"logger-plugin"},
    });
    try ctx.start();

    std.debug.print("[demo] done — disposing context tears everything down\n", .{});
}
