# Plugins

A **plugin** is a named unit that declares its dependencies, then runs an `init`
against a fresh `Scope`. Everything the plugin registers — services, events,
effects — lives in that scope and is torn down deterministically when the plugin
is unloaded. There is no manual cleanup.

Cordis Native supports three plugin formats:

| Format | Loader entry point | Source |
| --- | --- | --- |
| Native Zig (compile-time) | `cordis.loader.loadFromManifest` | `src/loader/loader.zig` |
| C ABI (dynamic shared library) | `cordis.loader.loadFromFile` | `src/abi/c.zig` |
| WASM (interpreter) | `cordis.loader.loadFromWasmBytes` / `loadFromWasmFile` | `src/abi/wasm.zig` |

All three register an ordinary `cordis.Plugin` and participate in the same
dependency-ordered startup (`ctx.start()`) and teardown.

## The `Plugin` type

```zig
pub const Plugin = struct {
    name: []const u8,
    depends_on: []const []const u8 = &.{},
    provides: []const []const u8 = &.{},
    init: *const fn (*Scope) anyerror!void,
    dispose: ?*const fn (*Scope) void = null,

    pub fn make(name: []const u8, init: *const fn (*Scope) anyerror!void) Plugin;
};
```

- `init(scope)` is where the plugin provides services, subscribes to events, and
  spawns effects. The `scope` passed in is the plugin's own isolated scope.
- `depends_on` lists plugin names that must finish `init` first. The
  `PluginManager` topologically sorts startup.
- `dispose(scope)` runs during reverse-order teardown.

## 1. Native Zig plugins

The simplest form: a plain Zig `init` function, registered at compile time.

```zig
const LoggerPlugin = struct {
    fn init(scope: *cordis.Scope) !void {
        const lg = scope.get(Logger, "logger").?;     // sees context-provided service
        std.debug.print("logger-plugin (sees {s})\n", .{lg.tag});
    }
};

try ctx.load(.{ .name = "logger-plugin", .init = LoggerPlugin.init });

const BotPlugin = struct {
    fn init(scope: *cordis.Scope) !void {
        _ = scope.get(Logger, "logger") orelse return error.NoLogger;
    }
};
try ctx.load(.{
    .name = "bot-plugin",
    .init = BotPlugin.init,
    .depends_on = &.{"logger-plugin"},
});

try ctx.start();   // runs inits in dependency order
```

For a parsed `Manifest` (e.g. from a config file), use:

```zig
pub fn loadFromManifest(
    ctx: *Context,
    m: Manifest,
    init_fn: *const fn (*Scope) anyerror!void,
    dispose_fn: ?*const fn (*Scope) void,
) !void
```

## 2. C ABI plugins (dynamic shared library)

A C-ABI plugin is a shared library (`libgreet-plugin.so` / `.dylib` / `.dll`)
that exports a manifest and init/dispose entry points, and talks to the host
**only** through a `CordisHostApi` function table. This keeps the ABI stable and
lets plugins be written in any C-compatible language.

### The contract (`src/abi/c.zig`)

The C header is generated from `src/abi/c.zig` and installed to
`zig-out/include/cordis_plugin.h` on build. Its essentials:

```c
typedef struct CordisHostApi CordisHostApi;

typedef void (*cordis_dyn_cb)(void* userdata, const char* name,
                              const void* payload, size_t len);

struct CordisHostApi {
    int  (*emit)(void* host, const char* name, const void* payload, size_t len);
    int  (*subscribe)(void* host, const char* name, cordis_dyn_cb cb, void* userdata);
    int  (*unsubscribe)(void* host, int sub_id);
    void (*log)(void* host, const char* msg);
};

typedef struct {
    const char* name;
    const char* version;
    const char** depends_on; /* null-terminated array */
} CordisPluginManifest;

extern const CordisPluginManifest CordisPluginManifest;
int  CordisPluginInit(void* host, const CordisHostApi* api);
void CordisPluginDispose(void* host, const CordisHostApi* api);
```

The symbols the host looks up:

```zig
pub const manifest_symbol: [:0]const u8 = "CordisPluginManifest";
pub const init_symbol:     [:0]const u8 = "CordisPluginInit";
pub const dispose_symbol:  [:0]const u8 = "CordisPluginDispose";
```

`host` is an **opaque** pointer to the runtime `Context`. The plugin must treat
it as opaque and only interact through `api`.

### Minimal plugin (see `examples/plugins/greet_plugin.zig`)

```zig
const std = @import("std");

const HostApi = extern struct {
    emit: *const fn (?*anyopaque, [*:0]const u8, ?*const anyopaque, usize) callconv(.c) c_int,
    subscribe: *const fn (?*anyopaque, [*:0]const u8, DynCallback, ?*anyopaque) callconv(.c) c_int,
    unsubscribe: *const fn (?*anyopaque, c_int) callconv(.c) c_int,
    log: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) void,
};
const DynCallback = *const fn (?*anyopaque, [*:0]const u8, ?*const anyopaque, usize) callconv(.c) void;

const empty_deps: [0:null]?[*:0]const u8 = .{};
export const CordisPluginManifest = ManifestExported{
    .name = "greet-plugin", .version = "0.2.0", .depends_on = &empty_deps,
};

var g_host: ?*anyopaque = null;
var g_api: ?*const HostApi = null;

export fn CordisPluginInit(host: ?*anyopaque, api: *const HostApi) callconv(.c) c_int {
    g_host = host; g_api = api;
    _ = api.subscribe(host, "greet", onGreet, null);
    api.log(host, "greet-plugin subscribed");
    return 0;
}

export fn CordisPluginDispose(host: ?*anyopaque, api: *const HostApi) callconv(.c) void {
    _ = host; _ = api;
}
```

### Host side

```zig
var ctx = try cordis.Context.init(alloc);
defer cordis.loader.deinit();   // MUST run AFTER ctx.deinit (see teardown below)
defer ctx.deinit();

try cordis.loader.loadFromFile(alloc, ctx, plugin_path);
try ctx.start();
```

`loadFromFile` reads `CordisPluginManifest`, resolves the init/dispose symbols,
and registers a `Plugin` whose thunks dispatch into the shared library. The
plugin participates in normal dependency-ordered startup/teardown.

## 3. WASM plugins (interpreter)

A WASM plugin runs inside the self-written MVP interpreter (`src/abi/wasm.zig`).
Its only contact with the outside world is two host imports:

- `cordis.host_log(ptr, len)` — print a string from linear memory
- `cordis.host_emit(name_ptr, name_len, payload_ptr, payload_len)` — emit a
  dynamic event

These are routed to the `Context` by the loader bridge. See
[`wasm-interpreter.md`](wasm-interpreter.md) for the full support matrix.

### Host side

```zig
var ctx = try cordis.Context.init(alloc);
defer cordis.loader.deinit();   // keep module mapped until ctx tears down
defer ctx.deinit();

const bytes = try std.fs.cwd().readFileAlloc(alloc, "plugin.wasm", 1 << 20);
defer alloc.free(bytes);
try cordis.loader.loadFromWasmBytes(alloc, ctx, bytes);
try ctx.start();
```

`loadFromWasmBytes` / `loadFromWasmFile` read the `plugin_name` and
`plugin_version` exports to fill the manifest, then register a `Plugin` whose
`init` calls the wasm `init` export and whose `dispose` calls `dispose`.

> **Sandbox invariant:** malformed wasm must return an `error`, never crash the
> host. The interpreter enforces a step budget
> (`Instance.setStepBudget`) to bound runaway loops. Treat a host abort as a
> security bug — see `SECURITY.md`.

## Teardown order (critical)

When you use the loader, the deferred teardown order is **not** symmetric:

```zig
defer cordis.loader.deinit();   // registered first  -> runs LAST
defer ctx.deinit();             // registered second -> runs FIRST
```

`ctx.deinit()` disposes every plugin scope, which invokes each plugin's
`dispose` (including the C `CordisPluginDispose` / wasm `dispose` export). Those
symbols must stay **mapped** until after the scope teardown — so
`loader.deinit()` (which closes the shared libraries / frees interpreter
bridges) must run *after* `ctx.deinit()`.

```zig
var ctx = try cordis.Context.init(alloc);
defer cordis.loader.deinit();   // closes modules; keep mapped during ctx teardown
defer ctx.deinit();             // disposes plugin scopes -> calls plugin.dispose
```

## Where to go next

- [Getting Started](getting-started.md) — Context, Scope, services, events.
- [Effects](effects.md) — cancellable background work tied to a scope.
- [WASM interpreter reference](wasm-interpreter.md) — opcodes, f64, bulk-memory, `Builder` API.
