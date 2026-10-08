//! Cordis Native — dynamic plugin loading demo (phase 2).
//!
//! Loads a C ABI plugin (shared library) at runtime via `std.DynLib` and runs
//! it as a normal plugin scope. Demonstrates the bidirectional HostApi event
//! bridge: the plugin subscribes to `greet` and emits `plugin.hello`; the host
//! does the reverse. Run with `zig build run-loader`.

const std = @import("std");
const cordis = @import("cordis");

// Host-side dynamic-event counters (a plain fn can't capture test locals).
var g_plugin_hellos: u32 = 0;
var g_greet_echoes: u32 = 0;

const onPluginHello: cordis.abi.DynCallback = struct {
    fn call(userdata: ?*anyopaque, name: [*:0]const u8, payload: ?*const anyopaque, len: usize) callconv(.c) void {
        _ = userdata;
        _ = name;
        g_plugin_hellos += 1;
        if (payload) |p| {
            const text = @as([*]const u8, @ptrCast(p))[0..len];
            std.debug.print("[host] received 'plugin.hello': {s}\n", .{text});
        }
    }
}.call;

const onGreetEcho: cordis.abi.DynCallback = struct {
    fn call(userdata: ?*anyopaque, name: [*:0]const u8, payload: ?*const anyopaque, len: usize) callconv(.c) void {
        _ = userdata;
        _ = name;
        _ = payload;
        _ = len;
        g_greet_echoes += 1;
    }
}.call;

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const alloc = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == 0);

    var it = try std.process.Args.Iterator.initAllocator(init.args, alloc);
    defer it.deinit();
    _ = it.next(); // argv[0]: program name
    const plugin_path = it.next() orelse {
        std.debug.print("usage: zcordis-loader <plugin.dylib|plugin.so>\n", .{});
        return error.MissingPluginPath;
    };

    // Defer order matters: `ctx.deinit` must run BEFORE `loader.deinit` (the
    // plugin's dispose symbol must stay mapped while its scope is disposed).
    // LIFO: loader.deinit (registered 1st) runs last, ctx.deinit runs first.
    var ctx = try cordis.Context.init(alloc);
    defer cordis.loader.deinit();
    defer ctx.deinit();

    try cordis.loader.loadFromFile(alloc, ctx, plugin_path);

    // Subscribe BEFORE start: the plugin emits `plugin.hello` during its init.
    _ = try ctx.events.subscribeDynamic(ctx.root, "plugin.hello", onPluginHello, null);
    _ = try ctx.events.subscribeDynamic(ctx.root, "greet.echo", onGreetEcho, null);
    std.debug.print("[demo] plugin registered; starting dependency-ordered init\n", .{});

    try ctx.start();

    // Fire an event the plugin subscribed to during its init.
    const msg = "hello from host";
    ctx.events.emitDynamic(ctx.root, "greet", msg.ptr, msg.len);
    std.debug.print("[demo] emitted 'greet'; plugin should have echoed\n", .{});

    // Verify the event bridge worked in both directions.
    std.debug.print("[demo] plugin.hello fired {}x, greet.echo fired {}x\n", .{ g_plugin_hellos, g_greet_echoes });
    if (g_plugin_hellos == 0 or g_greet_echoes == 0) return error.EventBridgeFailed;
}
