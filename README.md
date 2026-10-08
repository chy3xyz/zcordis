# zcordis

**Cordis Native** — a from-scratch, dependency-free rewrite of the
[Cordis](https://github.com/cordiverse/cordis) meta-framework in **Zig 0.17**.

`zcordis` is a native, typed, and deterministic **runtime kernel for composable
plugins**. It reimplements Cordis' eight core concepts (Context, Scope, Plugin,
Service, Event, Effect, Dependency, Lifecycle) as a focus on *semantic*
compatibility with the TypeScript original — same mental model, none of the
runtime GC, and a plugin system that spans native code, C ABI shared libraries,
and a sandboxed WebAssembly interpreter.

```text
Cordis Native (zcordis)
      │
      ├── Native plugins        (Zig, in-process)
      ├── C ABI plugins         (C / C++ / Rust via DynamicLib)
      └── WASM plugins          (sandboxed interpreter — no syscalls, host access only via imports)
```

## Why

Cordis is, at its heart, a **composable plugin runtime**. The JavaScript
implementation is excellent, but it carries the cost of a GC'd, dynamically-typed
host. Zig lets `zcordis` keep Cordis' composition model while being:

- **Typed end-to-end** — plugin contracts are checked at compile time.
- **Deterministic** — arena-per-scope allocation with explicit teardown; no hidden
  lifetime surprises.
- **Sandboxable** — the WASM plugin path runs untrusted code behind a host-function
  boundary. Malformed input never crashes the host (see [sandbox invariants](#sandbox-invariants)).

## Status

Early but functional. All eight core subsystems and the three plugin phases from the
design doc are implemented and verified:

| Phase | Feature | Status |
|-------|---------|--------|
| 1 | Native manifest plugins | ✅ |
| 2 | C ABI plugins (`std.DynLib` + generated C header) | ✅ |
| 3 | WASM plugins (minimal MVP interpreter) | ✅ (i32/i64/f32/f64, bulk-memory, tables, globals) |

See [`docs/getting-started.md`](docs/getting-started.md) for the quickstart and
[`docs/wasm-interpreter.md`](docs/wasm-interpreter.md) for the interpreter reference.

## Requirements

- **Zig 0.17.0** stable or newer (`zig version` → `0.17.0`).
- No third-party dependencies. `libc` is linked only for the example loaders and the
  C-plugin ABI.

## Build & test

```sh
zig build                 # build the library + example loaders
zig build run             # run the basic composition example
zig build run-loader      # load a C ABI plugin dynamically
zig build run-wasm        # run a WASM plugin in the interpreter
zig build run-harness     # run the DeepSeek-Harness-style agent example

zig build test            # all unit + integration tests
zig test src/cordis.zig   # kernel tests
zig test src/abi/wasm.zig # WASM interpreter tests
```

### WASM interpreter fuzz harness

`zcordis` ships a structural mutational fuzzer for the WASM interpreter that asserts the
sandbox invariant holds — malformed input must return a clean `error`, never panic:

```sh
zig build fuzz-wasm -- 100000        # 100k iterations
zig build fuzz-wasm -- 100000 12345  # with a fixed decimal seed
```

## Using zcordis

Add it as a Zig package (the library module is named `cordis`):

```zig
const cordis = @import("cordis");

pub fn main() !void {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const alloc = gpa.allocator();
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    // ... register services, load plugins, subscribe to events
}
```

The WASM plugin ABI header for C/C++/Rust authors is emitted to
`zig-out/include/cordis_plugin.h` on every build (generated from `src/abi/c.zig`).

## Documentation

| Document | Audience |
|----------|----------|
| [`docs/getting-started.md`](docs/getting-started.md) | Quickstart — Context, Scope, services, typed + dynamic events. |
| [`docs/plugins.md`](docs/plugins.md) | Native, C-ABI, and WASM plugins; loader teardown order. |
| [`docs/effects.md`](docs/effects.md) | Effect / Scheduler / Task, scope-bound cancellation, I/O. |
| [`docs/harness-example.md`](docs/harness-example.md) | DeepSeek-Harness-style agent runtime — usage guide: add tools, swap the model adapter, add listeners/plugins, stop conditions. |
| [`docs/wasm-interpreter.md`](docs/wasm-interpreter.md) | WASM MVP opcode support, f64 + bulk-memory, sandbox invariants, Builder/test recipes. |
| [`AGENTS.md`](AGENTS.md) | Operational cheat-sheet for AI coding agents. |
| [`llms.txt`](llms.txt) | LLM context index pointing at all the docs above. |

## Examples

| Example | Run | What it shows |
| --- | --- | --- |
| `examples/basic.zig` | `zig build run` | Minimal composition: services, events, scope auto-revoke, an effect, plugins. |
| `examples/loader.zig` + `examples/plugins/greet_plugin.zig` | `zig build run-loader` | Loading a C-ABI shared library plugin at runtime. |
| `examples/wasm_loader.zig` | `zig build run-wasm` | Running a WASM plugin in the interpreter. |
| `examples/harness.zig` | `zig build run-harness` | DeepSeek-Harness-style "everything is a plugin" agent loop. |

## Sandbox invariants

The WASM interpreter is built to **never crash on malformed input**. Every failure mode
is a returned `error` — `UnsupportedOpcode`, `MemoryOutOfBounds`, `InvalidMemoryIndex`,
`MalformedBlocks`, `InvalidConversion`, `ExecutionLimit`, etc. — never a panic or abort.
An execution-step budget bounds adversarial infinite loops (`error.ExecutionLimit`). This
is enforced continuously by the fuzz harness, not just by unit tests.

## Contributing

Contributions are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the build/test/fuzz
workflow, code style, and PR process. By contributing you agree your contributions are
licensed under the MIT License.

## Security

Found a way to crash the host or escape the WASM sandbox? Please follow
[`SECURITY.md`](SECURITY.md) — private disclosure, no public issues for vulns.

## License

[MIT](LICENSE). © 2026 zcordis contributors.
