//! Cordis Native — a minimal C ABI plugin (dev.md §18, phase 2).
//!
//! Built as a shared library and loaded at runtime by the host via
//! `std.DynLib`. Implements the `abi/c.zig` contract: exports a manifest and
//! init/dispose entry points, and interacts with the host only through the
//! `CordisHostApi` function table it receives at init.
//!
//! This file deliberately re-declares the ABI types locally (the way a C
//! plugin would from `include/cordis_plugin.h`) to prove the contract is
//! standalone — no compile-time dependency on the host library.

const std = @import("std");

// ── Local mirror of abi/c.zig (the C contract, self-contained) ─────────
const HostApi = extern struct {
    emit: *const fn (host: ?*anyopaque, name: [*:0]const u8, payload: ?*const anyopaque, len: usize) callconv(.c) c_int,
    subscribe: *const fn (host: ?*anyopaque, name: [*:0]const u8, cb: DynCallback, userdata: ?*anyopaque) callconv(.c) c_int,
    unsubscribe: *const fn (host: ?*anyopaque, sub_id: c_int) callconv(.c) c_int,
    log: *const fn (host: ?*anyopaque, msg: [*:0]const u8) callconv(.c) void,
};

const DynCallback = *const fn (
    userdata: ?*anyopaque,
    name: [*:0]const u8,
    payload: ?*const anyopaque,
    len: usize,
) callconv(.c) void;

const ManifestExported = extern struct {
    name: [*:0]const u8,
    version: [*:0]const u8,
    depends_on: [*:null]const ?[*:0]const u8,
};

const empty_deps_arr: [0:null]?[*:0]const u8 = .{};
const empty_deps: [*:null]const ?[*:0]const u8 = &empty_deps_arr;

export const CordisPluginManifest: ManifestExported = .{
    .name = "greet-plugin",
    .version = "0.2.0",
    .depends_on = empty_deps,
};

// ── Plugin behaviour ────────────────────────────────────────────────────
// The event callback only receives userdata, so capture the host handles at
// init (a real C plugin would store them in a context struct instead).
var g_host: ?*anyopaque = null;
var g_api: ?*const HostApi = null;

fn onGreet(userdata: ?*anyopaque, name: [*:0]const u8, payload: ?*const anyopaque, len: usize) callconv(.c) void {
    _ = userdata;
    _ = name;
    if (payload) |p| {
        const text = @as([*]const u8, @ptrCast(p))[0..len];
        std.debug.print("[c-plugin] received 'greet': {s}\n", .{text});
        // Echo back to prove the host -> plugin -> host round trip.
        if (g_api) |api| if (g_host) |host| {
            _ = api.emit(host, "greet.echo", text.ptr, text.len);
        };
    }
}

export fn CordisPluginInit(host: ?*anyopaque, api: *const HostApi) callconv(.c) c_int {
    g_host = host;
    g_api = api;
    const sub_id = api.subscribe(host, "greet", onGreet, null);
    api.log(host, "greet-plugin subscribed to 'greet'");
    std.debug.print("[c-plugin] subscribed id = {}\n", .{sub_id});

    // Prove we can emit too: say hello on a custom event.
    const msg = "hello from the plugin";
    _ = api.emit(host, "plugin.hello", msg.ptr, msg.len);
    return 0;
}

export fn CordisPluginDispose(host: ?*anyopaque, api: *const HostApi) callconv(.c) void {
    _ = host;
    _ = api;
    std.debug.print("[c-plugin] greet-plugin dispose\n", .{});
}
