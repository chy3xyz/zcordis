# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-10-10

First tagged release. `0.1.0` was declared in `build.zig.zon` but never tagged,
so this is the first version published as a package. It requires **Zig 0.17.0**
stable.

### Fixed

**Sandbox** — `SECURITY.md` promises that malformed or hostile WASM never crashes
the host. Two ways it could:

- `memory.grow` passed a sign-extended i32 operand through a checked `@intCast`,
  so `i32.const -1; memory.grow` — 16 bytes of well-formed WASM — panicked the
  host. The operand is now reinterpreted with `@bitCast`, like every other
  i32→unsigned site in the interpreter.
- The module's declared memory `max` was parsed and discarded, so growth was
  bounded only by the 2^16-page ceiling. A module declaring `(memory 1 1)` could
  therefore grow to 4 GiB. The `max` is now stored and enforced, and a refused
  growth is the spec's result (`-1`) rather than a trap — uniformly for both
  limits. A host allocator refusal stays an `error`, being an embedder-level
  condition rather than a WASM-level one.

**Interpreter**

- Added `Instance.setMaxCallDepth` (default 1024). The step budget bounds time,
  not memory: unbounded self-recursion grew the frame stack — plus one `locals`
  allocation per frame — into the gigabytes before the budget ever tripped.

**Fuzzer** — it ran 100k iterations clean while the `memory.grow` panic above was
reachable:

- The base module now drives adversarial operands (`growedge`, `loadneg`,
  `copyneg`, `recurse`) and a declared memory max on **every** iteration, and the
  harness asserts the pristine base parses, instantiates and runs. That assertion
  exposed why those paths had never been driven: the base module's own
  `i32.const 0xAB` was missing its SLEB128 terminator, so instantiating it always
  failed and no export had ever executed. Executed candidates went from 300 to
  roughly 27,000 per 100k iterations.
- `zig build fuzz-wasm -- <iterations> [seed]` now forwards its arguments. Zig
  0.17 requires an explicit `addPassthruArgs()`; without it both the iteration
  count and the seed were silently ignored.
- `Builder.section` orders sections by id rather than call order, so it can no
  longer emit the out-of-spec layout (a start section after code) that parses but
  then mis-instantiates.

### Changed — breaking

- `Scope.spawn` returns `error.InactiveEffect` for a scope whose teardown has
  begun, matching `Scope.effect`; registering into a scope mid-teardown would
  otherwise leak the effect or race the arena free.
- `EventBus.parallel` honours `once`, as `emit`/`bail`/`waterfall` already did.
- `Scope.effect(setup)` — the unused `comptime Setup: type` parameter is gone.
- `Effect.state` is `std.atomic.Value(State)` rather than `State`, since the
  spawner, the task and the canceller all touch it.
- `resolveDependencies` returns `error.DependencyCycle`, not a bare
  `error.Cycle`.
- `CordisError` no longer declares the unused `ServiceNotFound` and
  `EffectCompleted`, and the uncalled `cycleError` helper is gone.

### Performance

- Event dispatch no longer allocates per emit: `dispatcher.collect` fills a
  caller-owned stack scratch, spilling to the heap only when there are more
  matches than fit, and skips the priority sort when the set is already ordered.
  `emit` with four listeners went from 107 ns to 26 ns (ReleaseFast). Each
  dispatch owning its scratch is also what keeps a re-entrant `emit` from
  clobbering the outer set.

### Added

- `zig build bench` — a self-validating micro-benchmark harness. It prints its
  build mode and refuses to report numbers for a workload that did not actually
  run.
- `docs/architecture.md` — the eight core concepts, the scope/arena model, and
  the three plugin phases.
- `docs/events.md` — typed and dynamic events, scope-aware dispatch, the five
  dispatch modes, and the concurrency rules.
- `SECURITY.md` now documents the three independent resource bounds
  (instructions, call depth, linear memory).
- CI: the `zig fmt --check` gate `AGENTS.md` already required, a benchmark smoke
  step, and a macOS job — the only platform that exercises `loader_test`'s
  `.dylib` branch.

### Notes

- Measured, deliberately not changed: `cancelForScope` rescans the scheduler's
  effect list once per effect it cancels, but scaling is linear to 200 effects —
  task teardown (~6 µs each) dominates the scan (~1 ns) by three orders of
  magnitude.
- Known boundary: `Scope.dispose` frees a scope's arena without coordinating with
  a concurrent `spawn`/`subscribe` on that *same* scope. Give each thread its own
  scope rather than tearing one down while another thread is still registering
  into it.

[Unreleased]: https://github.com/chy3xyz/zcordis/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/chy3xyz/zcordis/releases/tag/v0.2.0
