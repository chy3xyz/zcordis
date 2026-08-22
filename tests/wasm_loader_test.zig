//! Integration tests for WASM plugin loading: the interpreter runs a real
//! (assembled) wasm module whose init/dispose are wired into the plugin
//! lifecycle, and whose `host_emit` import round-trips through the host.

const std = @import("std");
const cordis = @import("cordis");

var g_wasm_hellos: u32 = 0;

test "wasm plugin: load → init emits via host → dispose on teardown" {
    g_wasm_hellos = 0;
    {
        var ctx = try cordis.Context.init(std.testing.allocator);
        defer ctx.deinit();

        const bytes = try cordis.loader.wasm_demo.build(std.testing.allocator);
        defer std.testing.allocator.free(bytes);

        const onHello: cordis.abi.DynCallback = struct {
            fn call(userdata: ?*anyopaque, name: [*:0]const u8, payload: ?*const anyopaque, len: usize) callconv(.c) void {
                _ = userdata;
                _ = name;
                if (payload) |p| {
                    const text = @as([*]const u8, @ptrCast(p))[0..len];
                    std.debug.assert(text.len == 2 and text[0] == 'h' and text[1] == 'i');
                }
                g_wasm_hellos += 1;
            }
        }.call;

        _ = try ctx.events.subscribeDynamic(ctx.root, "wasm.hello", onHello, null);
        try cordis.loader.loadFromWasmBytes(std.testing.allocator, ctx, bytes);
        try ctx.start();

        // The plugin's init() export ran and emitted `wasm.hello` through the
        // host_emit import bridge.
        try std.testing.expect(g_wasm_hellos > 0);
    } // ctx.deinit() disposes the plugin scope → wasm dispose export runs
    cordis.loader.deinit(); // free module + instance + owned bytes
}

test "wasm module manifest via exports" {
    const bytes = try cordis.loader.wasm_demo.build(std.testing.allocator);
    defer std.testing.allocator.free(bytes);

    var module = try cordis.wasm.Module.load(std.testing.allocator, bytes);
    defer module.deinit();

    // The plugin exports init/dispose/plugin_name/plugin_version.
    try std.testing.expect(module.exports.contains("init"));
    try std.testing.expect(module.exports.contains("dispose"));
    try std.testing.expect(module.exports.contains("plugin_name"));
    try std.testing.expectEqual(@as(usize, 2), module.importCount()); // host_log, host_emit
}
