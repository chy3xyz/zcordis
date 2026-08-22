//! Cordis Native — plugin loader (dev.md §18: phase 2, C ABI plugins).
//!
//! Loads plugins at runtime instead of compile-time imports. The C-ABI path
//! opens a shared library, reads its exported `CordisPluginManifest`, and
//! registers a normal `Plugin` whose init/dispose dispatch into the library.
//!
//! ```text
//! Plugin
//!   ├── Native Zig   (phase 1: `loadFromManifest`)   ✅
//!   └── C ABI        (phase 2: `loadFromFile`)       ← this module
//! ```
//!
//! The native `Plugin.init` signature is a plain function pointer (no
//! userdata), so resolved C symbols are stashed in a process-lifetime bridge
//! keyed by plugin name; the thunks look themselves up by `scope.name`. Clean
//! everything up with `deinit()` after the Context is torn down.

const std = @import("std");
const Scope = @import("../core/scope.zig").Scope;
const Context = @import("../core/context.zig").Context;
const Module = @import("module.zig").Module;
const abi = @import("../abi/c.zig");
const wasm = @import("../abi/wasm.zig");

pub const Manifest = @import("manifest.zig").Manifest;
pub const parseManifest = @import("manifest.zig").parse;
pub const wasm_demo = @import("wasm_demo.zig");

/// The plugin's host handle: the runtime `Context` (kept opaque to plugins).
const Host = *Context;

/// Static HostApi handed to every plugin. The vtable functions recover the
/// `Context` from the opaque `host` pointer, so one table serves all plugins.
const host_api: abi.HostApi = .{
    .emit = apiEmit,
    .subscribe = apiSubscribe,
    .unsubscribe = apiUnsubscribe,
    .log = apiLog,
};

fn apiEmit(host: ?*anyopaque, name: [*:0]const u8, payload: ?*const anyopaque, len: usize) callconv(.c) c_int {
    const ctx: Host = @ptrCast(@alignCast(host.?));
    ctx.events.emitDynamic(ctx.root, std.mem.span(name), payload, len);
    return 0;
}

fn apiSubscribe(host: ?*anyopaque, name: [*:0]const u8, cb: abi.DynCallback, userdata: ?*anyopaque) callconv(.c) c_int {
    const ctx: Host = @ptrCast(@alignCast(host.?));
    const id = ctx.events.subscribeDynamic(ctx.root, std.mem.span(name), cb, userdata) catch return -1;
    return @intCast(id);
}

fn apiUnsubscribe(host: ?*anyopaque, sub_id: c_int) callconv(.c) c_int {
    const ctx: Host = @ptrCast(@alignCast(host.?));
    ctx.events.unsubscribeDynamic(@intCast(sub_id));
    return 0;
}

fn apiLog(host: ?*anyopaque, msg: [*:0]const u8) callconv(.c) void {
    _ = host;
    std.debug.print("[plugin] {s}\n", .{std.mem.span(msg)});
}

const ManifestData = struct {
    alloc: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    depends_on: []const []const u8,

    fn fromC(alloc: std.mem.Allocator, c: abi.CManifest) !ManifestData {
        const name = try alloc.dupe(u8, std.mem.span(c.name));
        errdefer alloc.free(name);
        const version = try alloc.dupe(u8, std.mem.span(c.version));
        errdefer alloc.free(version);
        var deps: std.ArrayListUnmanaged([]const u8) = .{ .items = &.{}, .capacity = 0 };
        errdefer deps.deinit(alloc);
        var it = c.depends_on;
        while (it[0]) |d| : (it += 1) {
            try deps.append(alloc, try alloc.dupe(u8, std.mem.span(d)));
        }
        return .{
            .alloc = alloc,
            .name = name,
            .version = version,
            .depends_on = try deps.toOwnedSlice(alloc),
        };
    }

    fn deinit(self: *ManifestData) void {
        for (self.depends_on) |d| self.alloc.free(d);
        self.alloc.free(self.depends_on);
        self.alloc.free(self.version);
        self.alloc.free(self.name);
    }
};

const BridgeEntry = struct {
    module: Module,
    data: ManifestData,
    init: abi.InitFn,
    dispose: ?abi.DisposeFn,
};

/// Loaded C-ABI plugins keyed by plugin name. The map buffer is backed by the
/// page allocator (process-lifetime, not leak-tracked); the per-plugin strings
/// are allocated by the caller's allocator and freed by `deinit`.
var g_bridge: std.hash_map.StringHashMapUnmanaged(BridgeEntry) = .{};

fn cInitThunk(scope: *Scope) anyerror!void {
    const entry = g_bridge.get(scope.name) orelse return error.PluginInitFailed;
    if (entry.init(scope.runtime, &host_api) != 0) return error.PluginInitFailed;
}

fn cDisposeThunk(scope: *Scope) void {
    if (g_bridge.get(scope.name)) |entry| {
        if (entry.dispose) |d| d(scope.runtime, &host_api);
    }
}

/// Close every loaded module and free its manifest data. Call AFTER the
/// `Context` has been torn down (the plugin's dispose symbol must stay mapped
/// while plugin scopes are disposed).
pub fn deinit() void {
    deinitCBridge();
    deinitWasmBridge();
}

fn deinitCBridge() void {
    var it = g_bridge.iterator();
    while (it.next()) |e| {
        e.value_ptr.module.deinit();
        e.value_ptr.data.deinit();
    }
    g_bridge.deinit(std.heap.page_allocator);
    g_bridge = .{};
}

fn deinitWasmBridge() void {
    var it = g_wasm_bridge.iterator();
    while (it.next()) |e| {
        const alloc = e.value_ptr.alloc;
        e.value_ptr.instance.deinit();
        e.value_ptr.module.deinit();
        alloc.destroy(e.value_ptr.module);
        alloc.free(e.value_ptr.bytes);
        alloc.free(e.value_ptr.version);
        alloc.free(e.value_ptr.name);
    }
    g_wasm_bridge.deinit(std.heap.page_allocator);
    g_wasm_bridge = .{};
}

/// Load a C-ABI plugin from a shared library and register it on `ctx`. The
/// plugin participates in the normal dependency-ordered startup and teardown.
pub fn loadFromFile(alloc: std.mem.Allocator, ctx: *Context, path: []const u8) !void {
    var module = try Module.open(path);
    errdefer module.deinit();

    const cman = module.lookup(*const abi.CManifest, abi.manifest_symbol) orelse return error.MissingManifest;
    const init_fn = module.lookup(abi.InitFn, abi.init_symbol) orelse return error.MissingInit;
    const dispose_fn = module.lookup(abi.DisposeFn, abi.dispose_symbol);

    var data = try ManifestData.fromC(alloc, cman.*);
    errdefer data.deinit();

    try g_bridge.put(std.heap.page_allocator, data.name, .{
        .module = module,
        .data = data,
        .init = init_fn,
        .dispose = dispose_fn,
    });
    errdefer _ = g_bridge.remove(data.name);

    try ctx.load(.{
        .name = data.name,
        .depends_on = data.depends_on,
        .init = cInitThunk,
        .dispose = cDisposeThunk,
    });
}

/// Register a plugin fully described by a parsed `Manifest` (the native Zig
/// path — no dynamic library). `init_fn`/`dispose_fn` are plain Zig function
/// pointers; `depends_on` ordering is handled by the PluginManager.
pub fn loadFromManifest(
    ctx: *Context,
    m: Manifest,
    init_fn: *const fn (*Scope) anyerror!void,
    dispose_fn: ?*const fn (*Scope) void,
) !void {
    try ctx.load(.{
        .name = m.name,
        .depends_on = m.depends_on,
        .init = init_fn,
        .dispose = dispose_fn,
    });
}

// ── WASM plugins (dev.md §19, phase 3) ─────────────────────────────────
// A WASM plugin runs inside the interpreter (`abi/wasm.zig`). Its only
// contact with the outside world is the two host imports below, which the
// bridge routes to the `Context`. This mirrors the C-ABI `HostApi` model.

const WasmBridgeEntry = struct {
    alloc: std.mem.Allocator,
    bytes: []u8, // owned copy of the wasm binary (Module borrows it)
    module: *wasm.Module,
    instance: *wasm.Instance,
    name: []const u8,
    version: []const u8,
};

var g_wasm_bridge: std.hash_map.StringHashMapUnmanaged(WasmBridgeEntry) = .{};

fn wasmHostLog(inst: *wasm.Instance, args: []const i64) i64 {
    const ptr: u32 = @intCast(args[0]);
    const len: u32 = @intCast(args[1]);
    const bytes = inst.bytes(ptr, len) catch return -1;
    std.debug.print("[wasm] {s}\n", .{bytes});
    return 0;
}

fn wasmHostEmit(inst: *wasm.Instance, args: []const i64) i64 {
    const ctx: *Context = @ptrCast(@alignCast(inst.host_ctx.?));
    const raw = inst.bytes(@intCast(args[0]), @intCast(args[1])) catch return -1;
    const name = raw[0 .. std.mem.indexOfScalar(u8, raw, 0) orelse raw.len];
    const owned: [:0]u8 = inst.alloc.allocSentinel(u8, name.len, 0) catch return -1;
    @memcpy(owned[0..name.len], name);
    defer inst.alloc.free(owned);
    const payload: ?*const anyopaque = if (args[3] == 0)
        null
    else blk: {
        const bytes = inst.bytes(@intCast(args[2]), @intCast(args[3])) catch return -1;
        break :blk @ptrCast(bytes.ptr);
    };
    ctx.events.emitDynamic(ctx.root, owned, payload, @intCast(args[3]));
    return 0;
}

fn wasmInitThunk(scope: *Scope) anyerror!void {
    const entry = g_wasm_bridge.get(scope.name) orelse return error.PluginInitFailed;
    _ = try entry.instance.callExport("init", &.{});
}

fn wasmDisposeThunk(scope: *Scope) void {
    if (g_wasm_bridge.get(scope.name)) |entry| {
        _ = entry.instance.callExport("dispose", &.{}) catch {};
    }
}

/// Load a WASM plugin from an in-memory binary and register it on `ctx`.
/// Reads `plugin_name`/`plugin_version` exports to fill the manifest; the
/// plugin participates in normal dependency-ordered startup and teardown.
pub fn loadFromWasmBytes(alloc: std.mem.Allocator, ctx: *Context, bytes: []const u8) !void {
    const owned = try alloc.dupe(u8, bytes);
    errdefer alloc.free(owned);

    const module = try alloc.create(wasm.Module);
    errdefer alloc.destroy(module);
    module.* = try wasm.Module.load(alloc, owned);
    errdefer module.deinit();

    const host_fns = [_]wasm.HostFn{ wasmHostLog, wasmHostEmit };
    const instance = try wasm.Instance.create(alloc, module, ctx, &host_fns, &.{});
    errdefer instance.deinit();

    const name_ptr: u32 = @intCast(try instance.callExport("plugin_name", &.{}));
    const version_ptr: u32 = @intCast(try instance.callExport("plugin_version", &.{}));
    const name = try alloc.dupe(u8, try instance.readString(name_ptr));
    errdefer alloc.free(name);
    const version = try alloc.dupe(u8, try instance.readString(version_ptr));
    errdefer alloc.free(version);

    try g_wasm_bridge.put(std.heap.page_allocator, name, .{
        .alloc = alloc,
        .bytes = owned,
        .module = module,
        .instance = instance,
        .name = name,
        .version = version,
    });
    errdefer _ = g_wasm_bridge.remove(name);

    try ctx.load(.{
        .name = name,
        .depends_on = &.{},
        .init = wasmInitThunk,
        .dispose = wasmDisposeThunk,
    });
}

/// Load a WASM plugin from a `.wasm` file.
pub fn loadFromWasmFile(alloc: std.mem.Allocator, ctx: *Context, path: []const u8) !void {
    const bytes = try std.fs.cwd().readFileAlloc(alloc, path, 1 << 20);
    defer alloc.free(bytes);
    try loadFromWasmBytes(alloc, ctx, bytes);
}
