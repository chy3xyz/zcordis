# WASM MVP Interpreter — Support Reference

Runtime: `src/abi/wasm.zig` (self-contained interpreter for a controlled subset of the
WebAssembly MVP binary format). Plugins are sandboxed: a WASM plugin can only touch the
outside world through host functions it imports (module `"cordis"`), wired to `Context` by
the loader. No syscalls, no direct host-memory access.

This document records the **f64** and **bulk-memory** additions (the last two MVP gaps),
and the spec-opcode correction that landed alongside them. The full supported-opcode
matrix is at the end.

---

## 1. f64 instructions

Added as a mirror of the existing `f32` design. The operand stack stores `i64`; an `f64`
value is kept as its **full 64-bit IEEE-754 bit pattern** in the i64 slot (no truncation,
unlike `f32` which zero-extends its 32-bit pattern into i64).

- `popF64` / `pushF64` bitCast the i64 slot through `u64`.
- `f64.abs` is `if (a < 0) -a else a` (a signed-zero-safe bit merge is
  `((a_bits & 0x7FFFFFFFFFFFFFFF) | (b_bits & 0x8000000000000000))` for copysign).
- `@sqrt` / `@ceil` / `@floor` / `@trunc` / `@round` are valid Zig scalar builtins and are
  used directly.

### Implemented opcodes

| Opcode | Instruction            | Notes |
|--------|------------------------|-------|
| `0x44` | `f64.const`            | 8 raw little-endian IEEE-754 bytes (immediate) |
| `0x2b` | `f64.load`             | new `opLoadF64`, 8-byte width |
| `0x39` | `f64.store`            | new `opStoreF64`, 8-byte width |
| `0x61` | `f64.eq`               | returns `i32` 0/1 |
| `0x62` | `f64.ne`               | |
| `0x63` | `f64.lt`               | |
| `0x64` | `f64.gt`               | |
| `0x65` | `f64.le`               | |
| `0x66` | `f64.ge`               | |
| `0x99` | `f64.abs`              | |
| `0x9a` | `f64.neg`              | |
| `0x9b` | `f64.ceil`             | |
| `0x9c` | `f64.floor`            | |
| `0x9d` | `f64.trunc`            | |
| `0x9e` | `f64.nearest`          | |
| `0x9f` | `f64.sqrt`             | |
| `0xa0` | `f64.add`              | |
| `0xa1` | `f64.sub`              | |
| `0xa2` | `f64.mul`              | |
| `0xa3` | `f64.div`              | |
| `0xa4` | `f64.min`              | |
| `0xa5` | `f64.max`              | |
| `0xa6` | `f64.copysign`         | |
| `0xb7` | `f64.convert_i32_s`    | |
| `0xb8` | `f64.convert_i32_u`    | |
| `0xbb` | `f64.promote_f32`      | exact, lossless f32→f64 |
| `0xbf` | `f64.reinterpret_i64`  | bit-reinterpret |
| `0xbd` | `i64.reinterpret_f64`  | bit-reinterpret |
| `0xaa` | `i32.trunc_f64_s`      | traps on NaN / out-of-range |
| `0xab` | `i32.trunc_f64_u`      | traps on NaN / out-of-range |
| `0xb0` | `i64.trunc_f64_s`      | traps on NaN / out-of-range |
| `0xb1` | `i64.trunc_f64_u`      | traps on NaN / out-of-range |

`f64` **block results** are still rejected (`readBlockArity` treats `0x7c` as unsupported),
so f64 unit tests assert via `f64.eq` (which yields an `i32`).

### Builder helpers

- `Builder.f64Const(v: f64)` — emits `f64.const` from a float value.
- `Builder.f64ConstBits(bits: u64)` — emits `f64.const` from a raw bit pattern.

Always use these; never hand-write the 8-byte little-endian IEEE-754 literal in tests.

---

## 2. Bulk-memory: `memory.copy` / `memory.fill`

Implemented via the `0xfc` prefix byte (bulk-memory proposal, MVP single-memory form).

### Dispatch

`opBulkMemory` reads:

1. `body[pc+1]` — the sub-opcode byte,
2. a `memarg` (align LEB + memory-index LEB). In the MVP only one memory exists, so the
   memory-index **must be 0**; any other value traps with `error.InvalidMemoryIndex`.

| Sub-opcode | Instruction     | Handler          |
|------------|-----------------|------------------|
| `0x0a`     | `memory.copy`   | `opMemoryCopy`   |
| `0x0b`     | `memory.fill`   | `opMemoryFill`   |
| other      | —               | `error.UnsupportedOpcode` |

### Stack order (critical)

The operand stack order follows the spec: `count` is on **top**.

- `memory.copy`: pops `[count, src, dest]`
- `memory.fill`: pops `[count, value, dest]`

Getting this backwards silently produces wrong results (and would pass a naive test by
coincidence only when `dest == count`).

### Bounds & semantics

- All addresses are checked in `u64` (`dest + count > memlen` or `src + count > memlen`)
  so a huge `count`/`offset` cannot wrap `usize` and panic in safe builds. Out of bounds
  traps with `error.MemoryOutOfBounds`.
- `opMemoryCopy` implements **`memmove` semantics**: copy forward when `dest < src` or there
  is no overlap (`dest >= src + count`); otherwise copy **backward** (the overlapping
  `dest > src` case). This matches the WASM spec requirement that overlapping copies behave
  like `memmove`.
- `opMemoryFill` writes the **low byte** of the `i32` value `count` times.

### Implementation gotcha

`opBulkMemory` already advances `frame.pc` to `r.pos` (past the memarg). The leaf handlers
`opMemoryCopy` / `opMemoryFill` must **not** call `self.advance(1)` again — doing so runs the
next step off the end of the function body and surfaces as `error.InvalidOpcode`.

### Builder / test recipe

A bulk-memory instruction is emitted as:

```zig
try v.i32Const(dest);
try v.i32Const(src);   // for memory.copy; for memory.fill use the value
try v.i32Const(count);
try v.emitByte(0xfc);
try v.emitByte(0x0a); // memory.copy, or 0x0b for memory.fill
try v.uleb(0);         // align (reserved)
try v.uleb(0);         // memory index (must be 0)
```

`immediateLen` has a `0xfc =>` arm computing `1 + alignLEB + memidxLEB` (returns `null` on
OOB → `error.MalformedBlocks`).

---

## 3. Spec-opcode correction (important)

Before these additions, the interpreter's `0xa7`–`0xbf` conversion / reinterpret / extend
opcodes used an **ad-hoc layout** that was *internally consistent* (its own tests passed) but
**not compliant** with real `wat2wasm` output:

| Instruction             | old (ad-hoc) | spec-correct (now) |
|-------------------------|--------------|--------------------|
| `f32.reinterpret_i32`   | `0xb8`       | `0xbe`             |
| `i32.reinterpret_f32`   | `0xb9`       | `0xbc`             |
| `i64.reinterpret_f64`   | (absent)     | `0xbd`             |
| `f64.reinterpret_i64`   | (absent)     | `0xbf`             |
| `i32.extend8_s`         | `0xbc`       | `0xc0`             |
| `i32.extend16_s`        | `0xbd`       | `0xc1`             |
| `i64.extend8_s`         | `0xbe`       | `0xc2`             |
| `i64.extend16_s`        | `0xbf`       | `0xc3`             |

While wiring f64, the **entire** `0xa7`–`0xbf` and `0xc0`–`0xc3` range was realigned to the
WASM spec, and all affected unit tests were updated to the correct opcodes. If you ever feed
modules produced by an external `wat2wasm`/compiler, the spec layout is what matters — do not
reintroduce the old ad-hoc mapping.

---

## 4. Verification

- `zig test src/abi/wasm.zig` — f64 + bulk-memory unit tests (12 f64, 5 bulk-memory) plus
  the corrected-opcode tests.
- `zig test src/cordis.zig` — plugin-layer tests (unchanged behavior).
- `zig build fuzz-wasm -- <iterations>` — structural mutational fuzzer. The fuzz base module
  gained `f64math()` and `membulk()` `() -> ()` exports so the fuzzer structurally exercises
  the f64 and bulk-memory code paths every iteration.

Sandbox invariant: **malformed input must never crash the host** — every failure mode is a
returned `error` (`UnsupportedOpcode`, `MemoryOutOfBounds`, `InvalidMemoryIndex`,
`MalformedBlocks`, `InvalidConversion`, `ExecutionLimit`, …), never a panic/abort.

---

## 5. Full supported-opcode matrix

```text
control   nop, unreachable, block, loop, if/else/end, br, br_if,
          br_table, call, call_indirect, return, select, drop
variable  local.get/set/tee, global.get/set
table     (single funcref table); element section populates it and
          call_indirect dispatches through it with type checks
memory    i32/i64 loads & stores (1/2/4/8-byte, signed/zero),
          f32.load, f64.load, f64.store, memory.size/grow
const     i32.const, i64.const, f32.const, f64.const
i32       eqz/eq/ne/lt_s/lt_u/gt_s/gt_u/le_s/le_u/ge_s/ge_u,
          add/sub/mul/div_s/div_u/rem_s/rem_u/and/or/xor/shl/shr_s/shr_u,
          clz/ctz/popcnt, extend8_s/extend16_s, wrap_i64
i64       eqz/eq/ne/lt_s/lt_u/gt_s/gt_u/le_s/le_u/ge_s/ge_u,
          add/sub/mul/div_s/div_u/rem_s/rem_u/and/or/xor/shl/shr_s/shr_u,
          clz/ctz/popcnt, extend_i32_s/extend_i32_u, extend8_s/extend16_s
f32       eq/ne/lt/gt/le/ge, abs/neg/ceil/floor/trunc/nearest/sqrt,
          add/sub/mul/div/min/max/copysign, convert_i32_s/convert_i32_u,
          reinterpret_i32, trunc_f32_s/trunc_f32_u (i32 & i64)
f64       eq/ne/lt/gt/le/ge, abs/neg/ceil/floor/trunc/nearest/sqrt,
          add/sub/mul/div/min/max/copysign, convert_i32_s/convert_i32_u,
          promote_f32, reinterpret_i64, trunc_f64_s/trunc_f64_u (i32 & i64),
          i64.reinterpret_f64, f64.load/f64.store
bulk      memory.copy, memory.fill (0xfc prefix, MVP single-memory form)
start     start section (id 8): runs a [] -> [] function at instantiation
globals   defined globals + imported globals (mutable/immutable enforced)
```

### Notably absent

- `f32.convert_i64_s/u`, `f32.demote_f64`, `f64.convert_i64_s/u`
- saturating / non-trapping (`*.trunc_sat_*`) truncations
- `f32`/`f64` block results (a function or block may not use f32/f64 as a result type)
- reference-types / multi-memory / SIMD / exception-handling
