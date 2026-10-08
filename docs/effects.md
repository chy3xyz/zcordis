# Effects and I/O

An **Effect** is a tracked, cancellable unit of background work. In Cordis,
effects are the bridge between a plugin's setup and the runtime's lifecycle:
when the owning scope dies, every effect it spawned is cancelled deterministically
instead of leaking a detached thread or timer.

The runtime is built **around** `std.Io` (specifically `std.Io.Threaded`) rather
than inventing its own async runtime. See `src/io/io.zig`.

## I/O context

`Context.io()` returns the process-global `std.Io` handle. Pass it to any
`std.Io` operation (files, sockets, timers) used by plugins.

```zig
var ctx = try cordis.Context.init(alloc);
defer ctx.deinit();

const io = ctx.io();              // std.Io
// use `io` for async I/O inside effects
```

The handle is backed by `std.Io.Threaded`, owned by the `Context`'s
`IoContext`. Because `Context` is heap-allocated, the `Io` handle stays at a
stable address for the process lifetime — safe to store inside effects and
services.

## Spawning an effect

Spawn a cancellable effect on a scope via `Scope.spawn` (or the scheduler
directly):

```zig
const Ticker = struct { ticks: u32 = 0, io: std.Io };
const ticker = try ctx.root.alloc().create(Ticker);
ticker.* = .{ .io = ctx.io() };

const run = struct {
    fn tick(t: *Ticker, eff: *cordis.Effect) !void {
        while (!eff.cancelled.load(.seq_cst) and t.ticks < 3) {
            t.ticks += 1;
            std.Io.sleep(t.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
        }
        std.debug.print("ticker ran {} ticks\n", .{t.ticks});
    }
}.tick;

_ = try ctx.root.spawn(Ticker, ticker, run);
```

Signatures:

```zig
pub fn Scope.spawn(
    self: *Scope,
    comptime Ctx: type,
    ctx: *Ctx,
    comptime run: *const fn (*Ctx, *Effect) anyerror!void,
) !*Effect

pub fn Scheduler.spawn(
    self: *Scheduler,
    comptime Ctx: type,
    scope: *Scope,
    ctx: *Ctx,
    comptime run: *const fn (*Ctx, *Effect) anyerror!void,
) !*Effect
```

- `Ctx` is the user context type (erased internally); `ctx` is a pointer to one.
- `run` is launched as a task on the runtime's `std.Io` (via
  `std.Io.concurrent`), cooperatively cancellable via `eff.cancelled`.
- The returned `*Effect` is owned by the scheduler and freed on completion or
  cancellation.

## The `Effect` type

```zig
pub const State = enum(u8) { created, running, completed, cancelled, failed };

pub const Effect = struct {
    id: u64,
    scope: *Scope,
    state: std.atomic.Value(State),     // spawner, task and canceller all write it
    cancelled: std.atomic.Value(bool),  // poll to cooperatively stop
    future: ?std.Io.Future(void),       // the running task; null once joined
    run: *const fn (*anyopaque, *Effect) anyerror!void,
    ctx: *anyopaque,
};
```

Long-running effects **must** poll `eff.cancelled.load(.seq_cst)` and return
when set. The scheduler then cancels and joins the task, so a non-yielding loop
that ignores `cancelled` will block teardown.

The flag and `std.Io` cancellation are **complementary, and both are needed**.
`std.Io` cancellation only fires at *I/O cancellation points*, so a CPU-bound
loop would never observe it — hence the flag. Conversely, a task parked in a
long `std.Io.sleep` (or a socket read) would otherwise wait out its full
timeout — hence `future.cancel`, which interrupts it immediately. `Future.cancel`
is also what releases the task's heap allocation; the scheduler drives it for
*every* effect, including one whose task already finished on its own.

## Scope-bound cancellation

Disposing a scope cancels every effect it spawned:

```zig
const sub = try ctx.child("worker");
_ = try sub.spawn(Worker, &w, Worker.run);
// ...
sub.dispose();   // cancels Worker.effect, joins its task, frees it
```

`Scheduler.cancelForScope(scope)` is invoked automatically by
`Scope.dispose`. This is what prevents the leaked-task and leaked-timer problems
that plague GC-based frameworks: an effect's lifetime is bound to its scope's
lifetime.

Manual cancellation is also available:

```zig
pub fn Scheduler.cancel(self: *Scheduler, eff: *Effect) void
```

## The `Task` abstraction

`Task(Ctx)` is a small type-erased closure bundling a context pointer and a run
function, so you can store and spawn effects as values:

```zig
pub fn Task(comptime Ctx: type) type {
    return struct {
        ctx: *Ctx,
        run: *const fn (*Ctx, *Effect) anyerror!void,
        pub fn spawn(self: Task(Ctx), sched: *Scheduler, scope: *Scope) !*Effect;
    };
}
```

```zig
var task = cordis.Task(Ticker){ .ctx = ticker, .run = run };
_ = try task.spawn(&ctx.scheduler, ctx.root);
```

## Lifecycle summary

| Action | What happens |
| --- | --- |
| `scope.spawn(...)` | effect starts as a `std.Io` task, tracked by the scheduler |
| effect returns | state → `completed`, freed by scheduler |
| `eff.cancelled` set | effect should poll and return; scheduler joins + frees |
| `scope.dispose()` | `cancelForScope` cancels + joins all the scope's effects |
| `Context.deinit()` | scheduler cancels anything still alive, then tears down |

## Where to go next

- [Getting Started](getting-started.md) — Context, Scope, services, events.
- [Plugins](plugins.md) — native, C-ABI, and WASM plugins; teardown order.
- [WASM interpreter reference](wasm-interpreter.md) — the built-in interpreter.
