# Security Policy

## Scope

`zcordis` includes a **WebAssembly interpreter** (`src/abi/wasm.zig`) intended to run
untrusted plugin code. The project's core safety claim is the **sandbox invariant**:

> Malformed or hostile WASM input must never crash the host process. Every failure is a
> returned `error`, never a panic or abort. Untrusted code reaches the host only through
> explicitly imported host functions.

The following are in scope for security reports:

- Any input to `Module.load` / `Instance.create` / `callExport` that causes a **panic,
  abort, segfault, integer overflow, or out-of-bounds memory access** in the host.
- Any path that lets WASM code **escape the interpreter** (e.g. reach host memory it was
  not given, or invoke a host function it did not import).
- Bypasses of the execution-step budget (`error.ExecutionLimit`) that allow an infinite
  loop to hang the host.

Out of scope:

- Bugs in plugins you write (native/C ABI code runs with full host privileges by design).
- DoS via legitimate-but-expensive computation that the step budget already bounds.
- Issues in the reference material under `_ref/` (third-party code, not built).

## Reporting a vulnerability

**Please do not open a public GitHub issue for a suspected vulnerability.**

Instead, report it privately:

- Open a **private security advisory** on the repository (GitHub → Security → Report a
  vulnerability), or
- Email the maintainers (see the repository's profile for the current contact).

Include:

1. A minimal reproduction (the WASM bytes or a `Builder` snippet, plus the host call).
2. The observed behavior vs. the expected sandbox behavior.
3. The Zig version (`zig version`) and platform.

We will acknowledge receipt within a few days, work with you on a fix, and coordinate
disclosure. Credit will be given in the release notes unless you prefer to remain anonymous.

## Hardening notes for integrators

- Always instantiate plugins with a bounded step budget for untrusted sources.
- Only wire the host imports a plugin actually needs; the import surface *is* the
  security boundary.
- Run untrusted WASM under an OS-level sandbox (seccomp / pledge / Landlock) as defense
  in depth — the interpreter boundary is necessary but not sufficient on its own.
