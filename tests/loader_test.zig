//! Integration tests for the Plugin Loader: manifest parsing and manifest-
//! driven registration. (The C-ABI `std.DynLib` path is exercised by the
//! `run-loader` example, since it needs a real shared library.)

const std = @import("std");
const cordis = @import("cordis");

// File-scope flags: nested plugin fns (plain function pointers) cannot capture
// test-local variables, so they record state here instead.
var g_inited: bool = false;
var g_disposed: bool = false;

test "manifest parse → loadFromManifest → plugin runs and disposes" {
    g_inited = false;
    g_disposed = false;
    {
        var ctx = try cordis.Context.init(std.testing.allocator);
        defer ctx.deinit();

        var m = try cordis.loader.parseManifest(std.testing.allocator,
            \\name = demo-plugin
            \\version = 1.0.0
        );
        defer m.deinit(std.testing.allocator);

        const P = struct {
            fn init(scope: *cordis.Scope) !void {
                _ = scope;
                g_inited = true;
            }
            fn dispose(scope: *cordis.Scope) void {
                _ = scope;
                g_disposed = true;
            }
        };
        try cordis.loader.loadFromManifest(ctx, m, P.init, P.dispose);
        try ctx.start();
        try std.testing.expect(g_inited);
    } // ctx.deinit() runs here → P.dispose
    try std.testing.expect(g_disposed);
}

test "manifest-driven plugin participates in dependency ordering" {
    var ctx = try cordis.Context.init(std.testing.allocator);
    defer ctx.deinit();

    var order: [2]u32 = .{ 0, 0 };
    var seq: u32 = 0;
    const State = struct { seq: *u32, order: *[2]u32 };
    _ = try ctx.provide(State, "state", .{ .seq = &seq, .order = &order }, null);

    const P = struct {
        fn init(scope: *cordis.Scope) !void {
            const st = scope.get(State, "state").?;
            st.seq.* += 1;
            if (std.mem.eql(u8, scope.name, "a")) {
                st.order[0] = st.seq.*;
            } else {
                st.order[1] = st.seq.*;
            }
        }
    };

    var ma = try cordis.loader.parseManifest(std.testing.allocator, "name = a\n");
    defer ma.deinit(std.testing.allocator);
    var mb = try cordis.loader.parseManifest(std.testing.allocator, "name = b\ndepends_on = a\n");
    defer mb.deinit(std.testing.allocator);

    try cordis.loader.loadFromManifest(ctx, ma, P.init, null);
    try cordis.loader.loadFromManifest(ctx, mb, P.init, null);
    try ctx.start();

    // a initializes before b (b depends on a) → a=1, b=2.
    try std.testing.expectEqual(@as(u32, 1), order[0]);
    try std.testing.expectEqual(@as(u32, 2), order[1]);
}
