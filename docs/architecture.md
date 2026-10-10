# Architecture

`zcordis` is a **runtime kernel for composable plugins**. It reimplements Cordis' eight
core concepts in Zig, keeping the mental model of the TypeScript original while dropping
the GC and the dynamic typing.

```text
                       Context            (the kernel object, heap-allocated)
                          │
   ┌──────────────┬───────┴────────┬──────────────┬───────────────┐
   │              │                │              │               │
 Scope tree    EventBus        Scheduler      PluginManager    IoContext
 (arenas)      (listeners)     (effects)      (dependencies)   (std.Io)
```

## The eight concepts

| Concept | Lives in | Role |
| --- | --- | --- |
| **Context** | `src/core/context.zig` | Owns every subsystem. Heap-allocated and never copied, because the root `Scope` and every `std.Io` handle hold back-pointers into it. |
| **Scope** | `src/core/scope.zig` | A node in a tree, one arena per node. Services, events and effects hang off a scope, so disposing it tears down exactly what it created. |
| **Plugin** | `src/plugin/plugin.zig` | A named unit with declared dependencies and `init`/`dispose` entry points. |
| **Service** | `src/service/` | A typed value registered under a name on a scope. Lookup walks *up* the parent chain, so children see parent services and siblings do not. |
| **Event** | `src/event/` | A **compile-time type**, not a string. See [events.md](events.md). |
| **Effect** | `src/effect/` | Tracked, cancellable background work bound to a scope's lifetime. |
| **Dependency** | `src/plugin/dependency.zig` | A graph whose topological order becomes plugin init order (teardown is the reverse). A back-edge is `CordisError.DependencyCycle`. |
| **Lifecycle** | `src/core/scope.zig` | `created → active → disposing → disposed`, claimed atomically so a scope is torn down exactly once. |

## Scope tree and arenas

Each `Scope` owns a private arena. Nothing is reference-counted: a scope's allocations are
reclaimed wholesale when it is disposed, and disposal is deterministic and recursive:

```text
Scope.dispose()
  ├── children (reverse creation order, recursively)
  ├── Scheduler.cancelForScope(self)   → cancel + join every effect it spawned
  ├── service teardown closures
  ├── attached disposables (reverse registration order)
  └── arena.deinit()                   → mark disposed
```

That ordering is why teardown needs no manual cleanup anywhere: subscribing, spawning and
providing all register with the owning scope. See [plugins.md](plugins.md) for the one
place order matters to callers (the loader must outlive the context).

`Context.init` returns `*Context` rather than a value. Copying it would leave the root
scope's back-pointer and every derived `Io` handle dangling.

## Effects

An effect runs as a `std.Io` task (`std.Io.concurrent`), so the kernel does not invent its
own async runtime. Cancellation is deliberately **two mechanisms**:

- `Effect.cancelled` — an atomic flag the task polls, which is the only thing that works
  for a CPU-bound loop;
- `Future.cancel` — which interrupts a task parked in an `Io` call.

Cancellation points alone would miss the first case; the flag alone would make a task wait
out its full I/O timeout. See [effects.md](effects.md).

## Plugins: three phases

```text
Cordis Native (zcordis)
      ├── Native plugins   (Zig, in-process, manifest-driven)
      ├── C ABI plugins    (C / C++ / Rust via std.DynLib + generated header)
      └── WASM plugins     (sandboxed interpreter — no syscalls, host access only via imports)
```

All three are loaded through `src/loader/`, which is what makes runtime loading possible
despite Zig's imports being compile-time singletons: the C ABI path goes through
`std.DynLib`, and the WASM path through a self-written interpreter (`src/abi/wasm.zig`).

The interpreter is the project's largest component and its security boundary. It runs
untrusted code behind a host-function boundary and is built so that malformed or hostile
input yields a returned `error`, never a panic — enforced by a structural fuzzer
(`zig build fuzz-wasm`), not just by unit tests. See
[wasm-interpreter.md](wasm-interpreter.md).

## Where to start reading

```text
src/cordis.zig     public re-exports — the whole surface in one file
src/core/          context.zig → scope.zig → error.zig  (read in that order)
src/event/         event.zig (the typed model) → bus.zig → dispatcher.zig
src/effect/        effect.zig → scheduler.zig
src/plugin/        plugin.zig → dependency.zig → resolver.zig → manager.zig
src/loader/        loader.zig (the three phases) → manifest.zig / module.zig
src/abi/           c.zig (the contract) → wasm.zig (the interpreter)
```

## Concurrency

Effects and `parallel` event handlers run on `std.Io` tasks, so runtime state is touched
from several threads. The invariants that keep that sound — one lock per container, never
nested, never held across user code or a join, reference-counted listeners — are listed in
[`AGENTS.md`](../AGENTS.md) under "Concurrency".

**Known boundary:** `Scope.dispose` frees the scope's arena without coordinating with a
concurrent `spawn`/`subscribe` on that *same* scope. Give each thread its own scope rather
than tearing one down while another thread is still registering into it.
