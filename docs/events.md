# Events

Cordis' event system keys listeners by **string name** onto a dynamic payload. `zcordis`
keeps the same composition model but makes the event a **compile-time type**: you subscribe
with `on(MyEvent, handler)` and the handler receives `*const MyEvent`, checked by the
compiler. A separate dynamic path preserves the string-keyed form for C-ABI plugins.

## Types

An event is any type. Its optional `Return` declaration selects the dispatch semantics that
can carry a value:

```zig
const Message = struct { text: []const u8 };            // no Return -> handlers return void

const Score = struct {
    v: i32,
    pub const Return = i32;                              // enables bail / serial / waterfall
};
```

`event.ReturnOf(E)` is `E.Return` when declared, otherwise `void`. A handler is
`fn (*Scope, *const E) anyerror!ReturnOf(E)`.

`Return` must be a **public** declaration: `returnOf` probes it with `@hasDecl`, which
counts public declarations only.

## Subscribing

```zig
var ctx = try cordis.Context.init(alloc);
defer ctx.deinit();

_ = try ctx.on(Message, onMessage, .{ .priority = 10 });
_ = try ctx.root.on(Message, onMessage, .{});
```

```zig
pub const SubscribeOptions = struct {
    priority: i32 = 0,   // higher runs first
    once: bool = false,  // auto-unsubscribe after the first invocation
    global: bool = false, // fire regardless of scope isolation
};
```

`on` returns a `Disposable`. It is also attached to the subscribing scope, so the listener
lives exactly as long as that scope: disposing the scope revokes it with no manual
cleanup. The returned `Disposable` unsubscribes early (`d.call(d.ctx)`); calling it after
the scope has already disposed is a no-op.

## Scope-aware dispatch

A listener only receives an event emitted from a scope **at or below** the one that
subscribed it, unless it sets `global`:

```zig
const sub = try ctx.child("worker");
_ = try sub.on(Tick, onTick, .{});

try sub.emit(Tick, &t);    // fires: sub is within root, and the emitter is sub
try ctx.emit(Tick, &t);    // does NOT fire: the emitter (root) is not within sub
```

Dead scopes are skipped, so a listener owned by a disposed scope never runs even if a
snapshot of it was taken.

## Dispatch modes

| Mode | Behaviour |
| --- | --- |
| `emit` | Fire-and-forget. Every matching listener runs; the first error is returned afterwards. |
| `parallel` | One `std.Io` task per listener, all joined before returning; the first error is returned. Return values are ignored. |
| `serial` | Currently identical to `bail` (handlers are synchronous, so there is nothing to await). |
| `bail` | Runs in priority order and stops at the first "bailed" result, returning it (`null` if none). |
| `waterfall` | Chains listeners: each receives the running value and may overwrite it. Returns the final value, or `seed` if no listener ran. |

```zig
try ctx.emit(Message, &m);
try ctx.parallel(Message, &m);
const bailed = try ctx.bail(Score, &s);       // ?i32
const final = try ctx.waterfall(Score, &s, 0); // i32
```

### What counts as "bailed"

`dispatcher.isBailed` mirrors Cordis' truthiness rule:

| Result type | Bails when |
| --- | --- |
| `void` | never |
| optional | non-null |
| `bool` | true |
| pointer | non-null |
| integer / float | non-zero |
| enum | backing integer non-zero |

## Dynamic events (C ABI)

Plugins that are not Zig — C, C++, Rust, or WASM — address events by **name string** and
an opaque byte payload. This trades compile-time type safety for cross-language reach.

```zig
const cb: cordis.abi.DynCallback = struct {
    fn call(ud: ?*anyopaque, name: [*:0]const u8, payload: ?*const anyopaque, len: usize) callconv(.c) void { ... }
}.call;

const id = try ctx.events.subscribeDynamic(ctx.root, "greet", cb, &userdata);
ctx.events.emitDynamic(ctx.root, "greet", bytes.ptr, bytes.len);
ctx.events.unsubscribeDynamic(id);
```

Dynamic subscriptions are scope-owned in the same way: disposing the scope revokes them.
`unsubscribeDynamic` is idempotent and safe to call from inside a callback.

`emitDynamic` walks the subscriber list in chunks, **releasing the bus lock before each
callback**, because a callback is free to re-enter the bus (subscribe or unsubscribe). You
may therefore subscribe or unsubscribe from inside a dynamic callback.

## Concurrency

Handlers may run on other threads (`parallel`), and a scope may be disposed from another
thread while an `emit` is in flight. `EventBus` therefore:

- guards its listener lists with `std.Io.Mutex`, held only for the list edit;
- snapshots the matching listeners under that lock, then invokes them with it released,
  because handlers may re-enter the bus and `std.Io.Mutex` is not reentrant;
- collects that set into a **scratch buffer owned by the dispatch itself** — a stack array
  of `dispatcher.inline_listeners`, spilling to the heap only when there are more matches
  than fit. Nothing is allocated on the common path, and because each dispatch has its own
  scratch, a handler that re-enters `emit` cannot clobber the outer set. The set is sorted
  by priority only when it is not already ordered (the uncommon case: listeners default to
  priority 0 and are visited in registration order);
- holds a **reference** (`Listener.refs`) for every in-flight dispatch, so a concurrent
  `unsubscribe` cannot free a listener record an `emit` is still about to call.

`EventBus.deinit` assumes quiescence: run it after every plugin and effect is gone
(`Context.deinit` does).

## See also

- [Getting Started](getting-started.md) — Context, Scope, services.
- [Plugins](plugins.md) — the C-ABI and WASM plugin formats that use dynamic events.
