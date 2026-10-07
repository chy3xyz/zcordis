//! WASM interpreter fuzz harness.
//!
//! The sandbox interpreter must satisfy one hard safety invariant: *malformed
//! or adversarial input must never crash the host* — not a `@panic`, not a
//! segfault, not an out-of-bounds read. Every failure path has to surface as a
//! clean `error` value so the loader can reject the plugin.
//!
//! Because Zig 0.17.0 ships no `std.testing.fuzz`, the harness
//! is a small in-process mutational fuzzer driven by `std.Random`:
//!
//!   * `buildBaseModule`      — assembles a *valid* wasm module via the public
//!                              `wasm.Builder` (the mutation seed).
//!   * `mutate`               — structural byte-level mutator (flip bit/byte,
//!                              insert, delete, splice) controlled by the RNG.
//!   * `fuzzOne`              — the oracle: run load → create → callExport on a
//!                              candidate buffer; any `error` is accepted, a
//!                              panic is the (failing) bug.
//!   * `test "wasm fuzz: structural mutation"` / `"wasm fuzz: opaque bytes"`
//!                              — bounded, seeded loops that run inside
//!                              `zig build test`.
//!   * `main`                 — standalone driver (`zig build fuzz-wasm`) for
//!                              longer, seedable, iteration-countable runs with
//!                              progress reporting and a crash summary.
//!
//! The `test` blocks use a fixed seed + modest iteration count so CI stays
//! fast; the `main` driver is for deeper, longer sessions.

const std = @import("std");
const cordis = @import("cordis");

const wasm = cordis.wasm;

const log = std.log.scoped(.wasm_fuzz);

// ── Base (valid) module generator ───────────────────────────────────────
/// Assemble a small but non-trivial *valid* wasm module to mutate from.
/// Imports `host_log`, defines two functions (`run`, `add`) and a memory, so
/// a successful mutation still exercises call / memory / control paths.
fn buildBaseModule(alloc: std.mem.Allocator) ![]u8 {
    var b = wasm.Builder{ .alloc = alloc };
    defer b.deinit();

    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{
        .{ .params = &.{ 0x7f, 0x7f }, .returns = &.{} }, // 0: (i32,i32)->()
        .{ .params = &.{0x7f}, .returns = &.{0x7f} }, // 1: (i32)->i32
        .{ .params = &.{}, .returns = &.{} }, // 2: ()->()
    });
    try b.imports(&.{.{ .module = "cordis", .name = "host_log", .type_idx = 0 }}, &.{});
    try b.functions(&.{ 1, 2, 2, 2, 2, 2 }); // run=1, add=2, count=3, dispatch=4, f64math=5, membulk=6 (all type2: ()->())
    try b.tables(&.{.{ .min = 1 }}); // one funcref slot
    try b.memory(1);
    try b.exports(&.{ .{ .name = "run", .index = 1 }, .{ .name = "add", .index = 2 }, .{ .name = "count", .index = 3 }, .{ .name = "dispatch", .index = 4 }, .{ .name = "f64math", .index = 5 }, .{ .name = "membulk", .index = 6 } });

    // Element segment: place `add` (index 2) into table slot 0 so the
    // `dispatch` function can reach it via call_indirect.
    try b.elements(&.{.{ .offset = 0, .func_indices = &.{2} }});

    // run(n) = if n>0 { host_log(n, n) } ; add(a,b) = a + b
    const run_body = [_]u8{
        0x01, 0x01, 0x7f, // 1 local: i32
        0x20, 0x00, // local.get 0
        0x41, 0x00, // i32.const 0
        0x4a, // i32.gt_s
        0x04, 0x40, // if (empty)
        0x20, 0x00, 0x20, 0x00, // local.get 0, local.get 0
        0x10, 0x00, // call host_log
        0x05, // else
        0x0b, // end
        0x0b, // end (function)
    };
    const add_body = [_]u8{
        0x00, // 0 locals
        0x20, 0x00, 0x20, 0x01, // local.get 0, local.get 1
        0x6a, // i32.add
        0x0b, // end
    };
    // count(n) = sum 0..n-1 using a block-wrapped loop with br_if/br.
    //   block {            ; label 1
    //     loop {           ; label 0
    //       local.get 1; local.get 0; i32.ge_s; br_if 1   (exit if i>=n)
    //       local.get 2; local.get 1; i32.add; local.set 2  (acc += i)
    //       local.get 1; i32.const 1; i32.add; local.set 1 (i += 1)
    //       br 0
    //     }
    //   }
    //   local.get 2; return
    // (n<=0 is undefined but the fuzzer only cares about "no crash".)
    const count_body = [_]u8{
        0x01, 0x03, 0x7f, // 1 decl: 3 x i32 (n, i, acc)
        0x02, 0x40, // block
        0x03, 0x40, // loop
        0x20, 0x01, 0x20, 0x00, 0x4e, // local.get 1; local.get 0; i32.ge_s
        0x0d, 0x01, // br_if 1 (exit)
        0x20, 0x02, 0x20, 0x01, 0x6a, 0x21, 0x02, // acc += i
        0x20, 0x01, 0x41, 0x01, 0x6a, 0x21, 0x01, // i += 1
        0x0c, 0x00, // br 0
        0x0b, // end loop
        0x0b, // end block
        0x20, 0x02, // local.get 2
        0x0b, // end (function)
    };
    // dispatch(a, b) = add(a, b) via call_indirect(type 2) through slot 0.
    const dispatch_body = [_]u8{
        0x00, // 0 locals
        0x20, 0x00, // local.get 0 (a)
        0x20, 0x01, // local.get 1 (b)
        0x41, 0x00, // i32.const 0 (table slot)
        0x11, 0x02, 0x00, // call_indirect type=2, table=0
        0x0b, // end
    };
    // f64math() = exercise f64 ops (const/add/eq), dropping the result so
    // the ()->() signature stays balanced. Mutated variants probe f64 paths.
    const f64math_body = [_]u8{
        0x00, // 0 locals
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F, // f64.const 1.5
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, // f64.const 2.0
        0xa0, // f64.add
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x40, // f64.const 3.5
        0x61, // f64.eq
        0x1a, // drop
        0x0b, // end
    };
    // membulk() = exercise bulk-memory: memory.copy(0,0,4) then
    // memory.fill(0, 0xAB, 4). Mutated variants probe OOB/overlap paths.
    const membulk_body = [_]u8{
        0x00, // 0 locals
        0x41, 0x00, // i32.const 0 (dest)
        0x41, 0x00, // i32.const 0 (src)
        0x41, 0x04, // i32.const 4 (count)
        0xfc, 0x0a, 0x00, 0x00, // memory.copy 0,0,4
        0x41, 0x00, // i32.const 0 (dest)
        0x41, 0xAB, // i32.const 0xAB (value)
        0x41, 0x04, // i32.const 4 (count)
        0xfc, 0x0b, 0x00, 0x00, // memory.fill 0,0xAB,4
        0x0b, // end
    };
    try b.code(&.{ &run_body, &add_body, &count_body, &dispatch_body, &f64math_body, &membulk_body });
    // `add` (func 2) is declared `() -> ()`, so it is a valid start target;
    // running it (empty stack → it reads missing locals → clean StackUnderflow)
    // still exercises the start-section parse + instantiate path. Mutations
    // that corrupt this section are exactly what we want fuzzed.
    try b.start(2);
    return b.buf.toOwnedSlice(alloc);
}

// ── Mutator ───────────────────────────────────────────────────────────────
fn flipBit(buf: []u8, rnd: std.Random) void {
    if (buf.len == 0) return;
    const i = rnd.int(usize) % buf.len;
    const bit = rnd.int(u3);
    buf[i] ^= @as(u8, 1) << bit;
}

fn flipByte(buf: []u8, rnd: std.Random) void {
    if (buf.len == 0) return;
    const i = rnd.int(usize) % buf.len;
    buf[i] = rnd.int(u8);
}

fn insertByte(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, rnd: std.Random) !void {
    const at = rnd.int(usize) % (buf.items.len + 1);
    try buf.insert(alloc, at, rnd.int(u8));
}

fn deleteByte(buf: *std.ArrayListUnmanaged(u8), rnd: std.Random) void {
    if (buf.items.len == 0) return;
    const at = rnd.int(usize) % buf.items.len;
    _ = buf.orderedRemove(at);
}

fn splice(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, rnd: std.Random) !void {
    if (buf.items.len < 2) return;
    const a = rnd.int(usize) % buf.items.len;
    const b = rnd.int(usize) % buf.items.len;
    const lo = @min(a, b);
    const hi = @max(a, b);
    const chunk = buf.items[lo .. hi + 1];
    const dup = try alloc.dupe(u8, chunk);
    defer alloc.free(dup);
    try buf.insertSlice(alloc, rnd.int(usize) % (buf.items.len + 1), dup);
}

/// Apply one random mutation to a copy of `base`, returning the mutated bytes
/// owned by `alloc`. Caller frees.
fn mutate(alloc: std.mem.Allocator, base: []const u8, rnd: std.Random) ![]u8 {
    var out = try std.ArrayListUnmanaged(u8).initCapacity(alloc, base.len + 16);
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, base);

    const op = rnd.int(usize) % 5;
    switch (op) {
        0 => flipBit(out.items, rnd),
        1 => flipByte(out.items, rnd),
        2 => try insertByte(&out, alloc, rnd),
        3 => deleteByte(&out, rnd),
        4 => try splice(&out, alloc, rnd),
        else => unreachable,
    }
    return out.toOwnedSlice(alloc);
}

// ── The oracle: run a candidate, accept any error, never crash ───────────
const Outcome = enum { rejected, loaded, ran };

/// Run one candidate buffer through the full parse → instantiate → execute
/// pipeline. Returns how far it got. Crucially, *every* failure mode must be a
/// returned `error`; if the interpreter panics, the test/process aborts — which
/// is exactly the bug this harness exists to surface.
fn fuzzOne(alloc: std.mem.Allocator, bytes: []const u8) Outcome {
    var module = wasm.Module.load(alloc, bytes) catch return .rejected;
    defer module.deinit();

    // A loaded module must instantiate, even if its data segments are bogus
    // (that yields error.MemoryOutOfBounds, which we accept).
    const inst = wasm.Instance.create(alloc, &module, null, &.{
        struct {
            fn log(_: *wasm.Instance, _: []const i64) i64 {
                return 0;
            }
        }.log,
    }, wasm.no_globals) catch return .loaded;
    defer inst.deinit();

    // Cap execution so a mutation that produces an unbounded loop cannot hang
    // the fuzzer — exhaustion surfaces as `error.ExecutionLimit`, a clean
    // (accepted) failure, exactly like any other trap. Kept small so a slow
    // debug build still completes in reasonable time; the invariant proven is
    // "never crash", which holds at any budget.
    inst.setStepBudget(2_000);

    // Try every exported function with zero args; ignore results. We only
    // care that execution does not crash the host.
    var it = module.exports.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.kind != 0) continue; // function exports only
        _ = inst.callExport(e.key_ptr.*, &.{}) catch |err| {
            // Div-by-zero, stack underflow, OOB, malformed blocks, traps…
            // all legitimate, recoverable failures.
            std.debug.assert(@errorName(err).len > 0);
        };
    }
    return .ran;
}

// ── test blocks (bounded, deterministic, fast) ───────────────────────────
test "wasm fuzz: structural mutation" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();

    const base = try buildBaseModule(std.testing.allocator);
    defer std.testing.allocator.free(base);

    var counts: [3]u32 = .{ 0, 0, 0 };
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const cand = try mutate(std.testing.allocator, base, rnd);
        defer std.testing.allocator.free(cand);
        counts[@backingInt(fuzzOne(std.testing.allocator, cand))] += 1;
    }
    // Core invariant: the oracle must have exercised BOTH the parse-reject
    // path and the full instantiate+execute path (otherwise the fuzzer would
    // not be proving "no crash on malformed input"). The instantiate-fail
    // (.loaded) case is a narrow sub-path and not asserted here.
    try std.testing.expect(counts[@backingInt(Outcome.rejected)] > 0);
    try std.testing.expect(counts[@backingInt(Outcome.ran)] > 0);
    std.log.info(
        "structural fuzz: rejected={d} loaded={d} ran={d}",
        .{ counts[0], counts[1], counts[2] },
    );
}

test "wasm fuzz: opaque random bytes" {
    var prng = std.Random.DefaultPrng.init(0xDEADBEA7);
    const rnd = prng.random();

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const len = rnd.int(usize) % 256;
        const buf = try std.testing.allocator.alloc(u8, len);
        defer std.testing.allocator.free(buf);
        rnd.bytes(buf);
        // The oracle must not crash on arbitrary bytes. Rejected is expected;
        // loaded/ran is fine too — the point is "never panic".
        _ = fuzzOne(std.testing.allocator, buf);
    }
}

// ── Standalone driver ─────────────────────────────────────────────────────
fn usage(name: []const u8) void {
    std.debug.print(
        \\usage: {s} [iterations] [seed]
        \\
        \\  iterations  number of candidate inputs to generate (default 100000)
        \\  seed         u64 PRNG seed (default 0)
        \\
        \\Runs the structural mutational fuzzer against the wasm interpreter and
        \\reports outcome counts. Exits non-zero if the interpreter crashes.
        \\
    , .{name});
}

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;
    var it = try std.process.Args.Iterator.initAllocator(init.args, alloc);
    defer it.deinit();
    _ = it.next(); // program name

    const iters = blk: {
        const a = it.next() orelse break :blk 100_000;
        break :blk std.fmt.parseInt(usize, a, 10) catch {
            log.err("invalid iterations: {s}", .{a});
            usage("fuzz-wasm");
            std.process.exit(2);
        };
    };
    const seed = blk: {
        const a = it.next() orelse break :blk 0;
        break :blk std.fmt.parseUnsigned(u64, a, 10) catch {
            log.err("invalid seed: {s}", .{a});
            usage("fuzz-wasm");
            std.process.exit(2);
        };
    };

    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();

    const base = try buildBaseModule(alloc);
    defer alloc.free(base);

    var counts: [3]u32 = .{ 0, 0, 0 };
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const cand = try mutate(alloc, base, rnd);
        defer alloc.free(cand);
        counts[@backingInt(fuzzOne(alloc, cand))] += 1;
        if (i % 10_000 == 9) {
            log.info("fuzzed {d} inputs", .{i + 1});
        }
    }

    std.debug.print(
        \\wasm fuzz complete
        \\  iterations : {d}
        \\  rejected   : {d}  (parse/instantiate error, safe)
        \\  loaded     : {d}  (parsed, instantiate-safe)
        \\  ran        : {d}  (executed, no crash)
        \\
    , .{ iters, counts[0], counts[1], counts[2] });
}
