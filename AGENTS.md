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
zig fmt src/ tests/ examples/        # MUST be run before committing Zig changes
```

The exact versions use Zig `0.17.0-dev.1567+f0354179a` (installed via `zigup`).
If `zig` is on a different nightly, treat compile errors as a signal to check
the toolchain, not just the code.

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
2. **Runaway loops are bounded.** The interpreter enforces a step budget via
   `Instance.setStepBudget`. New execution paths must advance `pc` and respect
   the budget.
3. **No double `advance`.** When a handler reads its own immediate bytes, the
   decoder already advances `frame.pc`; the handler must not `advance` again
   (this silently runs off the function body). Verify against existing op
   handlers before adding new ones.
4. **Use the `Builder` test helper, not hand-rolled bytes**, when writing WASM
   tests. It emits spec-correct SLEB128/ULEB128 and section framing
   (`Builder.i32Const`, `f64Const`, `types`, `imports`, `code`, …). Hand-writing
   `i64.const`/`f64.const` as little-endian bytes is a common mistake — those
   are SLEB128.

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
