//! Integration tests for the typed Service container.

const std = @import("std");
const cordis = @import("cordis");

test "typed service provide/get with type-safe lookup" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Logger = struct { tag: []const u8 };
    _ = try ctx.provide(Logger, "logger", .{ .tag = "app" }, null);

    const got = ctx.get(Logger, "logger").?;
    try std.testing.expectEqualSlices(u8, "app", got.tag);

    // A different type under the same key is rejected (no silent cast).
    const Other = struct { tag: []const u8 };
    try std.testing.expectEqual(@as(?*Other, null), ctx.get(Other, "logger"));
}

test "service override replaces the stored value" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Cfg = struct { v: i32 };
    _ = try ctx.provide(Cfg, "cfg", .{ .v = 1 }, null);
    _ = try ctx.provide(Cfg, "cfg", .{ .v = 2 }, null);

    try std.testing.expectEqual(@as(i32, 2), ctx.get(Cfg, "cfg").?.v);
}

test "service teardown closure runs on scope dispose" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    var disposed: bool = false;
    const Res = struct {
        fn cleanup(flag: *bool) void {
            flag.* = true;
        }
    };

    const Conn = struct { id: u32 };
    _ = try ctx.root.provide(
        Conn,
        "conn",
        .{ .id = 1 },
        cordis.makeDisposable(bool, &disposed, Res.cleanup),
    );

    try std.testing.expect(!disposed);
    ctx.root.dispose();
    try std.testing.expect(disposed);
}
