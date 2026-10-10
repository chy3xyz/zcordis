# Getting Started

This guide walks through the four core pillars of Cordis Native (zcordis):

1. **Context / Scope** — the composition kernel
2. **Services** — typed, scope-aware dependency injection
3. **Events** — compile-time typed, scope-aware dispatch
4. **Plugins / Effects** — covered in [`plugins.md`](plugins.md) and [`effects.md`](effects.md)

It mirrors the runnable `examples/basic.zig`. All snippets assume:

```zig
const std = @import("std");
const cordis = @import("cordis");

var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
const alloc = gpa.allocator();
defer std.debug.assert(gpa.deinit() == 0);

var ctx = try cordis.Context.init(alloc);
defer ctx.deinit();
```

> **Note on lifecycle:** `Context.init` returns a heap-allocated `*Context`.
> Never copy it by value — its `Scope` and `std.Io` back-pointers must stay at
> a stable address for the process lifetime.

## 1. Context and Scope

A `Context` owns every subsystem (I/O runtime, root scope, event bus, effect
scheduler, plugin manager). Plugins, services, events, and effects all hang off
a `Scope`, so disposing the context deterministically tears down the whole tree.

A `Scope` is the unit of **spatiotemporal composition**:

- **Space** — it owns services, effects, and listeners in an isolated arena.
- **Time** — it carries a deterministic lifecycle (`created → active →
  disposing → disposed`) instead of relying on a GC.
- **Causality** — listeners and effects registered on a scope are revoked when
  the scope dies, eliminating the listener/timer leaks of GC frameworks.

Scopes form a tree. `child` creates a sub-scope that sees its parent's services
but not its siblings' — the backbone of plugin isolation.

```zig
var ctx = try cordis.Context.init(alloc);
defer ctx.deinit();

const sub = try ctx.child("sub");   // child of the root scope
defer sub.dispose();                 // deterministic, idempotent
```

`Scope` key methods:

| Method | Purpose |
| --- | --- |
| `Scope.create(runtime, parent, name, id)` | allocate a (root or child) scope |
| `scope.child(name)` | create a sub-scope |
| `scope.alloc()` | arena allocator living as long as the scope |
| `scope.provide` / `scope.get` | scoped services (see below) |
| `scope.on` / `scope.emit` / `scope.parallel` / `scope.bail` / `scope.serial` / `scope.waterfall` | scoped event dispatch |
| `scope.effect(setup)` | register a teardown closure |
| `scope.spawn(Ctx, ctx, run)` | spawn a scope-owned cancellable effect |
| `scope.dispose()` | tear down this scope and everything beneath it |

## 2. Services

Services are typed values provided under a string name. Resolution walks the
scope tree upward to the root, so a child sees everything its ancestors provide.

```zig
const Logger = struct { tag: []const u8 };

// Provide on the context (== root scope).
_ = try ctx.provide(Logger, "logger", .{ .tag = "app" }, null);

// Resolve anywhere in the tree.
const lg = ctx.get(Logger, "logger").?;
std.debug.print("logger tag = {s}\n", .{lg.tag});
```

Signature:

```zig
pub fn provide(self: *Scope, comptime T: type, name: []const u8, value: T, dispose: ?Disposable) !*T
pub fn get(self: *Scope, comptime T: type, name: []const u8) ?*T
```

- `T` is the **compile-time** value type — there is no `anyerror`/erased type at
  the call site; a wrong type simply fails to compile.
- `dispose` is an optional `Disposable` (see `cordis.makeDisposable`) run when
  the owning scope is disposed.
- Children see parent services; siblings do **not** see each other's services.

## 3. Events

Events are **compile-time typed**. You subscribe with `on(MyEvent, handler)`
where `handler` is:

```zig
fn (*Scope, *const MyEvent) anyerror!ReturnOf(MyEvent)
```

The event type itself is just a struct:

```zig
const Message = struct { content: []const u8 };

const onMessage = struct {
    fn call(scope: *cordis.Scope, m: *const Message) !void {
        _ = scope;
        std.debug.print("got: {s}\n", .{m.content});
    }
}.call;

_ = try ctx.on(Message, onMessage, .{});
var msg = Message{ .content = "hello cordis" };
try ctx.emit(Message, &msg);
```

### Dispatch modes

| Method | Semantics |
| --- | --- |
| `emit` | fire-and-forget, listeners run in priority order |
| `parallel` | fire-and-forget, listeners scheduled concurrently |
| `bail` | first non-`null` return short-circuits (returns `?Return`) |
| `serial` | listeners run in order; returns the last value (`?Return`) |
| `waterfall` | each listener receives the previous return as `seed` (`Return`) |

A value-returning event declares `pub const Return = T;`:

```zig
const Score = struct {
    content: []const u8,
    pub const Return = i32,
};

_ = try ctx.on(Score, scorer, .{ .priority = 1 });
var score = Score{ .content = "rate me" };
const result = try ctx.waterfall(Score, &score, 0);
```

### Subscribe options

```zig
pub const SubscribeOptions = struct {
    priority: i32 = 0,   // higher runs first
    once: bool = false,  // auto-remove after first invocation
    global: bool = false, // fire regardless of scope isolation
};
```

### Scope-aware auto-revocation

Listeners registered on a scope are owned by it. When the scope is disposed, its
listeners are revoked automatically — no manual unsubscribe:

```zig
const sub = try ctx.child("sub");
_ = try sub.on(Message, onSub, .{});
try sub.emit(Message, &msg);  // root AND sub listeners fire (sub is within root)

sub.dispose();                // sub's listener is now revoked
try ctx.emit(Message, &msg);  // only the root listener fires
```

A listener fires if the emitting scope `isWithin` the subscribing scope.

### Dynamic (string-keyed) events

For payloads not known at compile time (e.g. from C/WASM plugins), use the
dynamic API:

```zig
const id = ctx.events.subscribeDynamic(ctx.root, "c.hello", cb, userdata) catch return;
ctx.events.emitDynamic(ctx.root, "c.hello", payload_ptr, len);
ctx.events.unsubscribeDynamic(id);
```

The callback type is `abi.DynCallback` (`fn(userdata, name, payload, len) callconv(.c) void`).

## Where to go next

- [Plugins](plugins.md) — native manifest plugins, C-ABI plugins, WASM plugins.
- [Effects](effects.md) — cancellable background work tied to a scope.
- [WASM interpreter reference](wasm-interpreter.md) — opcode/feature matrix for the built-in interpreter.
