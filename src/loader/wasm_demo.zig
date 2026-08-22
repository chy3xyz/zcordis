//! Cordis Native — a small WASM plugin used by the loader demo and tests.
//!
//! Built with `wasm.Builder`, this module is a *real* wasm binary (assembled at
//! runtime) that the interpreter executes. It imports `host_log` and `host_emit`
//! from module `"cordis"` and exports the plugin lifecycle:
//!
//! ```text
//! init()  → host_log("hello from wasm plugin"); host_emit("wasm.hello", "hi")
//! dispose() → (no-op)
//! plugin_name() / plugin_version() → pointer to a NUL-terminated string
//! ```
//!
//! Data layout in linear memory:
//! ```text
//!  0  "greet-wasm\0"              (11)
//! 16  "hello from wasm plugin\0"  (24)
//! 40  "0.1.0\0"                   (6)
//! 48  "wasm.hello\0"              (11)
//! 60  "hi\0"                      (2)
//! ```

const std = @import("std");
const wasm = @import("../abi/wasm.zig");

/// Assemble the demo plugin into an owned byte slice (caller frees).
pub fn build(alloc: std.mem.Allocator) ![]u8 {
    var b = wasm.Builder{ .alloc = alloc };
    defer b.deinit();

    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

    // Types: 0=(i32,i32)->(), 1=(i32,i32,i32,i32)->(), 2=()->(), 3=()->(i32)
    try b.types(&.{
        .{ .params = &.{ 0x7f, 0x7f }, .returns = &.{} },
        .{ .params = &.{ 0x7f, 0x7f, 0x7f, 0x7f }, .returns = &.{} },
        .{ .params = &.{}, .returns = &.{} },
        .{ .params = &.{}, .returns = &.{0x7f} },
    });

    // Imports occupy function indices 0 (host_log) and 1 (host_emit).
    try b.imports(&.{
        .{ .module = "cordis", .name = "host_log", .type_idx = 0 },
        .{ .module = "cordis", .name = "host_emit", .type_idx = 1 },
    }, &.{});

    // Defined functions start at index 2: init, dispose, plugin_name, version.
    try b.functions(&.{ 2, 2, 3, 3 });
    try b.memory(1);
    try b.exports(&.{
        .{ .name = "init", .index = 2 },
        .{ .name = "dispose", .index = 3 },
        .{ .name = "plugin_name", .index = 4 },
        .{ .name = "plugin_version", .index = 5 },
    });

    // init(): host_log(16, 24); host_emit(48, 11, 60, 2)
    const init_body = [_]u8{
        0x00, // 0 local decls
        0x41, 0x10, 0x41, 0x18, 0x10, 0x00, // i32.const 16, 24; call 0
        0x41, 0x30, 0x41, 0x0b, 0x41, 0x3c, 0x41, 0x02, 0x10, 0x01, // i32.const 48,11,60,2; call 1
        0x0b, // end
    };
    const dispose_body = [_]u8{ 0x00, 0x0b };
    const name_body = [_]u8{ 0x00, 0x41, 0x00, 0x0b }; // i32.const 0
    const version_body = [_]u8{ 0x00, 0x41, 0x28, 0x0b }; // i32.const 40
    try b.code(&.{ &init_body, &dispose_body, &name_body, &version_body });

    try b.data(&.{
        .{ .offset = 0, .bytes = "greet-wasm\x00" },
        .{ .offset = 16, .bytes = "hello from wasm plugin\x00" },
        .{ .offset = 40, .bytes = "0.1.0\x00" },
        .{ .offset = 48, .bytes = "wasm.hello\x00" },
        .{ .offset = 60, .bytes = "hi\x00" },
    });

    return b.buf.toOwnedSlice(alloc);
}
