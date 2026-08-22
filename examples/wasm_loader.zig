//! Cordis Native — WASM plugin demo (dev.md §19, phase 3).
//!
//! Assembles a small WASM plugin in-memory, loads it through the interpreter,
//! and runs it as a normal plugin scope. The plugin's `init` calls the host
//! `host_log` import and emits the `wasm.hello` dynamic event, which this host
//! subscribed to before startup. Run with `zig build run-wasm`.

const std = @import("std");
const cordis = @import("cordis");

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    var gpa = std.heap.DebugAllocator(.{}){};
    const alloc = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const bytes = try cordis.loader.wasm_demo.build(alloc);
    defer alloc.free(bytes);

    var hellos: u32 = 0;
    const onHello: cordis.abi.DynCallback = struct {
        fn call(userdata: ?*anyopaque, name: [*:0]const u8, payload: ?*const anyopaque, len: usize) callconv(.c) void {
            _ = name;
            _ = payload;
            _ = len;
            const h: *u32 = @ptrCast(@alignCast(userdata.?));
            h.* += 1;
        }
    }.call;

    // Defer order: loader.deinit must run AFTER ctx.deinit (the wasm instance
    // must outlive the plugin scope teardown that calls its `dispose` export).
    var ctx = try cordis.Context.init(alloc);
    defer cordis.loader.deinit();
    defer ctx.deinit();

    // Subscribe before start: the plugin emits `wasm.hello` during its init.
    _ = try ctx.events.subscribeDynamic(ctx.root, "wasm.hello", onHello, &hellos);

    try cordis.loader.loadFromWasmBytes(alloc, ctx, bytes);
    std.debug.print("[demo] wasm plugin registered; starting\n", .{});

    try ctx.start();
    std.debug.print("[demo] wasm.hello fired {}x\n", .{hellos});
    if (hellos == 0) return error.WasmBridgeFailed;
    std.debug.print("[demo] wasm plugin lifecycle complete\n", .{});
}
