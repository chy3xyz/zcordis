//! Integration tests for Scope: hierarchy, services visibility, lifecycle and
//! deterministic disposal ordering.

const std = @import("std");
const cordis = @import("cordis");

test "scope hierarchy: child sees parent services, not siblings" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Db = struct { n: u32 };
    _ = try ctx.provide(Db, "db", .{ .n = 7 }, null);

    const child = try ctx.root.child("child");
    try std.testing.expectEqual(@as(?*Db, null), child.get(Db, "db2"));
    try std.testing.expectEqual(@as(u32, 7), child.get(Db, "db").?.n);

    // A sibling does not see the child's services.
    const sibling = try ctx.root.child("sibling");
    _ = try sibling.provide(Db, "secret", .{ .n = 1 }, null);
    try std.testing.expectEqual(@as(?*Db, null), child.get(Db, "secret"));

    child.dispose();
    sibling.dispose();
}

test "child scope disposal does not disturb the parent" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Db = struct { n: u32 };
    _ = try ctx.root.provide(Db, "db", .{ .n = 3 }, null);

    const child = try ctx.root.child("child");
    _ = try child.provide(Db, "db", .{ .n = 9 }, null);
    try std.testing.expectEqual(@as(u32, 9), child.get(Db, "db").?.n);

    child.dispose();
    // Parent still resolves its own (different) value.
    try std.testing.expectEqual(@as(u32, 3), ctx.root.get(Db, "db").?.n);
    try std.testing.expect(ctx.root.isAlive());
}

test "scope dispose runs disposables in reverse registration order" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    // A bundle carries enough state to record the fire order.
    const Bundle = struct { slot: u32, seq: *u32, order: *[3]u32 };
    const fire = struct {
        fn run(b: *Bundle) void {
            b.seq.* += 1;
            b.order[b.slot] = b.seq.*;
        }
    };

    var seq: u32 = 0;
    var order: [3]u32 = .{ 0, 0, 0 };
    var b0 = Bundle{ .slot = 0, .seq = &seq, .order = &order };
    var b1 = Bundle{ .slot = 1, .seq = &seq, .order = &order };
    var b2 = Bundle{ .slot = 2, .seq = &seq, .order = &order };

    const s = try ctx.root.child("s");
    _ = try s.attach(cordis.makeDisposable(Bundle, &b0, fire.run));
    _ = try s.attach(cordis.makeDisposable(Bundle, &b1, fire.run));
    _ = try s.attach(cordis.makeDisposable(Bundle, &b2, fire.run));
    s.dispose();

    // Last-registered runs first → b2=1, b1=2, b0=3.
    try std.testing.expectEqual(@as(u32, 1), order[2]);
    try std.testing.expectEqual(@as(u32, 2), order[1]);
    try std.testing.expectEqual(@as(u32, 3), order[0]);
    try std.testing.expect(!s.isAlive());
}

test "scope.effect attaches the setup's disposable and rejects a dead scope" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    // The flag lives on the test's stack, so it is still readable after the
    // scope's arena has been freed. Handlers reach it through a service.
    var fired: bool = false;
    const Flag = struct { out: *bool };

    const s = try ctx.root.child("s");
    _ = try s.provide(Flag, "flag", .{ .out = &fired }, null);

    const setup = struct {
        fn run(scope: *cordis.Scope) anyerror!?cordis.Disposable {
            const f = scope.get(Flag, "flag").?;
            return cordis.makeDisposable(Flag, f, struct {
                fn dispose(x: *Flag) void {
                    x.out.* = true;
                }
            }.dispose);
        }
    }.run;

    try s.effect(void, setup);
    try std.testing.expect(!fired);

    s.dispose();
    try std.testing.expect(fired);

    // A disposed scope refuses to take on new effects.
    try std.testing.expectError(cordis.CordisError.InactiveEffect, s.effect(void, setup));
}
