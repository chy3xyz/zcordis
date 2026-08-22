# Contributing to zcordis

Thanks for your interest in improving `zcordis`! This document covers the workflow we
use. It's intentionally short — the goal is a low-friction, reviewable process.

## Getting started

```sh
zig version            # must be 0.17.0 or newer
zig build test         # run everything
zig build fuzz-wasm -- 100000   # optional: exercise the WASM interpreter
```

No external dependencies are required to build or test. Markdown docs are also
linted in CI with [markdownlint](https://github.com/igorshubovych/markdownlint-cli)
using the repo's `.markdownlint.jsonc` config. Run it locally with:

```sh
npm install -g markdownlint-cli
markdownlint README.md docs/*.md AGENTS.md llms.txt dev.md
```

## Project layout

| Path | Purpose |
|------|---------|
| `src/cordis.zig` | Library root (kernel + inline tests). |
| `src/loader/` | Plugin loaders (native, C ABI, WASM). |
| `src/abi/` | Plugin ABIs: `c.zig` (C header source), `wasm.zig` (WASM interpreter). |
| `examples/` | Runnable demos for each plugin phase. |
| `tests/` | Integration tests + the WASM fuzz harness. |
| `docs/` | Focused reference docs (e.g. the WASM interpreter support matrix). |
| `dev.md` | Design doc — read this before proposing architectural changes. |

## Making a change

1. **Discuss first for anything architectural.** Open an issue or PR draft before large
   changes to the core abstractions (Context, Scope, Event, Effect, Dependency). Small
   bug fixes and opcode additions don't need pre-approval.
2. **Keep the sandbox invariant.** The WASM interpreter must *never* panic on malformed
   input — every failure is a returned `error`. If you touch `src/abi/wasm.zig`, run the
   fuzz harness (`zig build fuzz-wasm -- 100000`) and confirm **0 crashes**.
3. **Add tests.** Unit tests live inline next to the code (`test { ... }`). WASM opcode
   additions should include a small round-trip test that builds the module with the
   `Builder` helpers and asserts the expected result.
4. **Use the Builder helpers, not literals.** In WASM tests, emit instructions via
   `Builder.i32Const` / `f64Const` / `sleb` / `op` — hand-written SLEB128 or IEEE-754
   byte literals are a frequent source of silent bugs.
5. **Update docs.** If your change affects the WASM support matrix, update
   [`docs/wasm-interpreter.md`](docs/wasm-interpreter.md). Public API changes should be
   reflected in the README where relevant.

## Code style

- `zig fmt` is the canonical formatter — run `zig fmt src` before committing.
- Prefer explicit, readable control flow over cleverness; the interpreter's correctness
  depends on clarity (bounds checks, operand-stack discipline).
- Comments explain *why*, not *what*. The wasm interpreter already carries a lot of
  hard-won lessons in its doc comments — extend them rather than papering over.

## Commit & PR

- Commits should be focused and reviewable.
- PRs should describe the *motivation* and the *verification* (which tests/fuzz runs
  passed).
- CI must be green: `zig build test`, the fuzz harness, and `markdownlint` on the docs
  (see `.github/workflows/ci.yml`).

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
