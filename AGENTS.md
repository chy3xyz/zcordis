# AGENTS.md — for AI coding agents

Guidance for automated coding agents working in `zcordis` (Cordis Native): a
Zig 0.17 reimplementation of the Cordis plugin meta-framework, with a
self-written WASM MVP interpreter. Read `README.md` and the `docs/` directory for the
project's intent and design rationale; this file is the quick operational
cheat-sheet.

## Build / test / fuzz commands

```bash
zig build            # build the static `cordis` library + all example artifacts
zig build test       # run unit tests (src/cordis.zig test {}) + integration tests (tests/)
zig build run        # run the basic composition example
zig build run-loader # build + run a C-ABI plugin example (needs the greet-plugin .so)
zig build run-wasm   # build + run a WASM plugin in the interpreter
zig build fuzz-wasm -- 100000        # fuzz the WASM interpreter (args: [iterations] [seed])
zig build bench                      # micro-benchmarks (add -Doptimize=fast for usable numbers)
zig fmt src/ tests/ examples/        # MUST be run before committing Zig changes
```

The project targets Zig `0.17.0` stable (installed via `zigup`), matching the
version pinned in CI. If `zig` is on a different nightly, treat compile errors
as a signal to check the toolchain, not just the code.

## Repo map

```text
src/cordis.zig        public re-exports (Context, Scope, Event, Plugin, loader, abi, wasm)
src/core/             context.zig, scope.zig, error.zig
src/service/          service.zig (registry helpers), registry.zig
src/event/            event.zig (typed model), bus.zig, dispatcher.zig, listener.zig
src/effect/           effect.zig, scheduler.zig, task.zig, cancellation.zig
src/loader/           loader.zig (C ABI + WASM), manifest.zig, module.zig, wasm_demo.zig
src/abi/              c.zig (C ABI contract + generated header), wasm.zig (interpreter)
src/io/               io.zig (IoContext over std.Io.Threaded)
examples/             basic.zig, loader.zig, wasm_loader.zig, plugins/greet_plugin.zig
tests/                tests.zig (integration), wasm_fuzz.zig (fuzz driver)
docs/                 wasm-interpreter.md (English), getting-started.md, plugins.md, effects.md
```

Files cross-import via relative paths (`@import("../core/scope.zig")`) under one
module namespace `cordis`; there is no per-directory module setup.

## Hard rules (sandbox-invariant, non-negotiable)

1. **Malformed input must never crash the host.** The WASM interpreter
   (`src/abi/wasm.zig`) and the loader must return an `error` for every bad
   input — never `unreachable`, `panic`, `@panic`, or an out-of-bounds memory
   access. Host crashes / sandbox escapes are security bugs (see `SECURITY.md`).
2. **Runaway loops and recursion are bounded.** The interpreter enforces a step
   budget via `Instance.setStepBudget` and a frame-stack cap via
   `Instance.setMaxCallDepth` — time and memory are separate axes, and the budget
   does not bound recursion depth. New execution paths must advance `pc` and
   respect both.
3. **No double `advance`.** When a handler reads its own immediate bytes, the
   decoder already advances `frame.pc`; the handler must not `advance` again
   (this silently runs off the function body). Verify against existing op
   handlers before adding new ones.
4. **Use the `Builder` test helper, not hand-rolled bytes**, when writing WASM
   tests. It emits spec-correct SLEB128/ULEB128 and section framing
   (`Builder.i32Const`, `f64Const`, `types`, `imports`, `code`, …). Hand-writing
   `i64.const`/`f64.const` as little-endian bytes is a common mistake — those
   are SLEB128. So are `i32.const` bytes whose high bit is set: a bare `0xAB` in
   `0x41, 0xAB` is a *continuation* byte, so it swallows the next byte and
   desynchronises every instruction after it. (That exact mistake sat in the
   fuzz harness's base module and quietly stopped it instantiating, which is why
   its exports were never actually executed.)
5. **`Builder.section` sorts sections by id for you**, so call order does not
   matter. It cannot produce the out-of-spec layout (a start section after code,
   say) that still parses but then mis-instantiates for reasons unrelated to the
   payload under test. Getting that order wrong used to be the caller's problem,
   and the fuzz harness's base module got it wrong.

## Conventions

- `Context` is heap-allocated and returned as `*Context` from `Context.init`;
  never copy it by value (its `Scope`/`Io` back-pointers would dangle).
- Teardown order when using the loader:

  ```zig
  defer loader.deinit();   // AFTER ctx.deinit — keep plugin symbols mapped
  defer ctx.deinit();      // until plugin scopes are disposed
  ```

  `loader.deinit()` closes every module and frees plugin manifest data; it must
  run after `Context.deinit()` so that a plugin's `dispose` symbol stays mapped
  while its scope is torn down.
- Events are **compile-time typed**: `on(MyEvent, handler)` where
  `handler` is `fn(*Scope, *const MyEvent) anyerror!ReturnOf(MyEvent)`. An event
  may declare `pub const Return = T;` to enable `bail`/`serial`/`waterfall`.
  Dynamic (string-keyed) events go through `subscribeDynamic`/`emitDynamic`.
- Services are scoped: `scope.provide(T, name, value, dispose?)` /
  `scope.get(T, name)` walks the parent chain. Children see parent services;
  siblings do not.

## Concurrency

Effects and `parallel` handlers run as `std.Io` tasks, so runtime state is
touched from several threads. Six invariants keep that sound; breaking any of
them reintroduces a race, a deadlock, or a use-after-free.

1. **One lock per container, all `std.Io.Mutex`.** `Scheduler.mutex` guards
   `effects`/`next_id`; `EventBus.mutex` guards
   `listeners`/`dyn_listeners`/`next_sub_id`; `Scope.children_mutex` guards a
   scope's child list; `DisposableList.mutex` guards a scope's disposables. Take
   them with `lockUncancelable(io)`: they are held only for bounded list edits,
   so a cancellation point inside bookkeeping buys nothing.
2. **Cross-thread flags are atomic, not locked.** `Effect.state`, `Scope.state`,
   `Listener.refs` and `Context.scope_counter`. `Scope.dispose` claims the
   teardown with a `swap` rather than a read-then-write, so two concurrent
   disposals cannot both free the arena.
3. **Never hold two locks at once.** `subscribe` touches both the bus and the
   scope, and `Scope.dispose` runs disposables that re-enter the bus — holding
   both would close a lock cycle. Each container is locked and released on its
   own.
4. **Never hold a lock across user code or a join.** Task bodies, event handlers
   and dynamic callbacks may call back into the runtime, and `std.Io.Mutex` is
   not reentrant. Snapshot under the lock, then run outside it —
   `cancelForScope`, `dispatcher.collect`, `emitDynamic` and
   `DisposableList.clear` all follow this shape. The dispatch scratch is owned
   by the dispatch (a stack array in the calling method), never a shared bus
   member, so a handler that re-enters `emit` cannot clobber the outer set.
5. **Only the thread that unlinks an effect owns it.** `Scheduler.cancel` must
   return immediately when `unlinkLocked` says the effect was already gone: a
   peer that won the unlink is cancelling and freeing it, and a second
   `Future.cancel` on the same future hits `Threaded.cancel`'s `unreachable`.
6. **Never free a listener a dispatch may still hold.** `Listener.refs` counts
   one registration reference plus one per in-flight `collect`; `unsubscribe`
   drops only the registration. Destroying directly reintroduces a
   use-after-free between `emit` and a concurrent scope dispose.

Known boundary: `Scope.dispose` still frees the scope's arena without
coordinating with a concurrent `spawn`/`subscribe` on that *same* scope. Give
each thread its own scope rather than tearing one down while another thread is
still registering into it.

## When documenting

- Put framework usage / developer docs under `docs/` in **English**.
- Keep `docs/wasm-interpreter.md` as the authoritative WASM opcode/feature
  reference; update it when interpreter support changes.
- `README.md` carries the docs index table — add new docs there.

## Verification before declaring done

- `zig fmt` clean on every touched Zig file.
- `zig build test` green.
- If you touched the interpreter, also run `zig build fuzz-wasm -- 100000` and
  confirm 0 crashes/host aborts.
- If you touched the scheduler, the event bus, a scope's disposable list, or
  `Listener`, note that `zig build test` carries cross-thread stress tests: they
  corrupt or hang when a lock, a snapshot release, or a listener reference is
  dropped.
