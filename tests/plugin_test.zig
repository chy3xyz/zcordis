//! Integration tests for the Plugin system: dependency-ordered initialization,
//! cycle detection and missing-dependency reporting.

const std = @import("std");
const cordis = @import("cordis");

test "plugins initialize in dependency order" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    var seq: u32 = 0;
    var log: [3]u32 = .{ 0, 0, 0 };

    const Marks = struct { seq: *u32, log: *[3]u32 };
    _ = try ctx.provide(Marks, "marks", .{ .seq = &seq, .log = &log }, null);

    const P = struct {
        fn mark(s: *cordis.Scope, slot: u32) !void {
            const m = s.get(Marks, "marks").?;
            m.seq.* += 1;
            m.log[slot] = m.seq.*;
        }
    };

    try ctx.load(.{ .name = "a", .init = struct {
        fn init(s: *cordis.Scope) !void {
            try P.mark(s, 0);
        }
    }.init });
    try ctx.load(.{ .name = "b", .init = struct {
        fn init(s: *cordis.Scope) !void {
            try P.mark(s, 1);
        }
    }.init, .depends_on = &.{"a"} });
    try ctx.load(.{ .name = "c", .init = struct {
        fn init(s: *cordis.Scope) !void {
            try P.mark(s, 2);
        }
    }.init, .depends_on = &.{ "a", "b" } });

    try ctx.start();

    // a before b before c.
    try std.testing.expectEqual(@as(u32, 1), log[0]);
    try std.testing.expectEqual(@as(u32, 2), log[1]);
    try std.testing.expectEqual(@as(u32, 3), log[2]);
}

test "resolver topo-orders dependencies (leaves last)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    const alloc = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const P = cordis.Plugin;
    const noop = struct {
        fn f(_: *cordis.Scope) !void {}
    }.f;
    const plugins = [_]P{
        .{ .name = "a", .init = noop },
        .{ .name = "b", .init = noop, .depends_on = &.{"a"} },
        .{ .name = "c", .init = noop, .depends_on = &.{ "a", "b" } },
    };
    const order = try cordis.resolveDependencies(alloc, &plugins);
    defer alloc.free(order);

    // c depends on a and b, so it must be initialized last.
    try std.testing.expectEqual(@as(usize, 2), order[order.len - 1]);
}

test "resolver detects dependency cycles" {
    var gpa = std.heap.DebugAllocator(.{}){};
    const alloc = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const P = cordis.Plugin;
    const noop = struct {
        fn f(_: *cordis.Scope) !void {}
    }.f;
    const plugins = [_]P{
        .{ .name = "x", .init = noop, .depends_on = &.{"y"} },
        .{ .name = "y", .init = noop, .depends_on = &.{"x"} },
    };
    const order = cordis.resolveDependencies(alloc, &plugins);
    try std.testing.expectError(error.Cycle, order);
}

test "resolver reports missing dependencies" {
    var gpa = std.heap.DebugAllocator(.{}){};
    const alloc = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const P = cordis.Plugin;
    const noop = struct {
        fn f(_: *cordis.Scope) !void {}
    }.f;
    const plugins = [_]P{
        .{ .name = "a", .init = noop, .depends_on = &.{"ghost"} },
    };
    const order = cordis.resolveDependencies(alloc, &plugins);
    try std.testing.expectError(cordis.CordisError.MissingDependency, order);
}
