//! Cordis Native — minimal WASM (MVP) plugin runtime (phase 3).
//!
//! A small, self-contained interpreter for a controlled subset of the WebAssembly
//! MVP binary format. It exists to run sandboxed plugins: the only way a WASM
//! plugin can touch the outside world is through host functions it imports
//! (module `"cordis"`), which the loader wires to the `Context` — the plugin
//! has no syscalls and no direct access to host memory.
//!
//! Supported subset (everything else traps with `error.UnsupportedOpcode`):
//!   control   nop, unreachable, block, loop, if/else/end, br, br_if,
//!             br_table, call, call_indirect, return, select, drop
//!   variable  local.get/set/tee, global.get/set
//!   table     (single funcref table); element section populates it and
//!             call_indirect dispatches through it with type checks
//!   memory    i32/i64 loads & stores (1/2/4/8-byte, signed/zero), memory.size/grow
//!   const     i32.const, i64.const, f32.const, f64.const
//!   i32       eqz/eq/ne/lt_s/lt_u/gt_s/gt_u/le_s/le_u/ge_s/ge_u,
//!             add/sub/mul/div_s/div_u/rem_s/rem_u/and/or/xor/shl/shr_s/shr_u,
//!             clz/ctz/popcnt, extend8_s/extend16_s, wrap_i64
//!   i64       eqz/eq/ne/lt_s/lt_u/gt_s/gt_u/le_s/le_u/ge_s/ge_u,
//!             add/sub/mul/div_s/div_u/rem_s/rem_u/and/or/xor/shl/shr_s/shr_u,
//!             clz/ctz/popcnt, extend_i32_s/extend_i32_u, extend8_s/extend16_s
//!   f32       eq/ne/lt/gt/le/ge, abs/neg/ceil/floor/trunc/nearest/sqrt,
//!             add/sub/mul/div/min/max/copysign, convert_i32_s/convert_i32_u,
//!             reinterpret_i32, trunc_f32_s/trunc_f32_u (i32 & i64)
//!   f64       eq/ne/lt/gt/le/ge, abs/neg/ceil/floor/trunc/nearest/sqrt,
//!             add/sub/mul/div/min/max/copysign, convert_i32_s/convert_i32_u,
//!             promote_f32, reinterpret_i64, trunc_f64_s/trunc_f64_u (i32 & i64),
//!             i64.reinterpret_f64, f64.load/f64.store
//!   bulk      memory.copy, memory.fill (0xfc prefix, MVP single-memory form)
//!
//! Notably absent: f32.convert_i64_s/u, f32.demote_f64, f64.convert_i64_s/u,
//! and the saturating / non-trapping truncations remain unsupported.
//!
//! `Module.load` borrows the input bytes; the caller must keep them alive for
//! as long as the module (and any instance) exists.

const std = @import("std");

pub const page_size = std.wasm.page_size; // 64 KiB

/// Errors that can be raised by the supported arithmetic operations.
const ArithError = error{DivisionByZero};

/// Error raised by `trunc_*` conversions when the source float is NaN or out
/// of the representable integer range (WASM traps with the same semantics).
const ConvError = error{InvalidConversion};

/// True iff `a` is an IEEE-754 NaN (exponent all-ones, non-zero mantissa).
/// Implemented via bit ops so it works for any build mode without relying on
/// `std.math.isNan` availability.
fn f32IsNan(a: f32) bool {
    const bits: u32 = @bitCast(a);
    return (bits & 0x7F800000) == 0x7F800000 and (bits & 0x007FFFFF) != 0;
}

/// True iff `a` is an IEEE-754 double NaN (exponent all-ones, non-zero mantissa).
fn f64IsNan(a: f64) bool {
    const bits: u64 = @bitCast(a);
    return (bits & 0x7FF0000000000000) == 0x7FF0000000000000 and (bits & 0x000FFFFFFFFFFFFF) != 0;
}

// ── Binary format constants ─────────────────────────────────────────────
const section_type = 1;
const section_import = 2;
const section_function = 3;
const section_table = 4;
const section_memory = 5;
const section_global = 6;
const section_export = 7;
const section_start = 8;
const section_code = 10;
const section_data = 11;
const section_element = 9;

const ext_kind_function = 0;
const ext_kind_table = 1;
const ext_kind_global = 3;

/// WASM MVP table element type: only `funcref` (0x70) is allowed.
const table_elem_funcref: u8 = 0x70;

// ── Reader ──────────────────────────────────────────────────────────────
const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn byte(self: *Reader) !u8 {
        if (self.pos >= self.bytes.len) return error.TrailingData;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }

    fn bytesN(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.bytes.len) return error.TrailingData;
        defer self.pos += n;
        return self.bytes[self.pos .. self.pos + n];
    }

    fn name(self: *Reader) ![]const u8 {
        const len = try self.uleb();
        return self.bytesN(len);
    }

    fn uleb(self: *Reader) !u32 {
        var result: u32 = 0;
        var shift: u5 = 0;
        while (true) {
            const b = try self.byte();
            if (shift == 28 and (b & 0x70) != 0) return error.TooBig;
            result |= @as(u32, b & 0x7f) << shift;
            if ((b & 0x80) == 0) return result;
            shift +%= 7;
        }
    }

    /// Decode a signed LEB128 into an i64 (sign-extended).
    fn sleb(self: *Reader) !i64 {
        var result: i64 = 0;
        var shift: u6 = 0;
        var b: u8 = undefined;
        while (true) {
            b = try self.byte();
            if (shift == 63 and (b & 0x7e) != 0) return error.TooBig;
            result |= @as(i64, b & 0x7f) << shift;
            shift +%= 7;
            if ((b & 0x80) == 0) break;
        }
        if (shift < 64 and (b & 0x40) != 0) result |= -(@as(i64, 1) << shift);
        return result;
    }
};

// ── Module model ────────────────────────────────────────────────────────
/// Parse a constant init expression; only `i32.const <n> end` is supported.
fn parseInitExpr(r: *Reader) !i64 {
    const op = try r.byte();
    if (op != 0x41) return error.UnsupportedInitExpr;
    const value = try r.sleb();
    if (try r.byte() != 0x0b) return error.BadInitExpr;
    return value;
}

pub const FuncType = struct {
    params: []const u8, // valtype bytes (0x7f = i32, 0x7e = i64)
    returns: []const u8,
};

pub const FuncImport = struct {
    module: []const u8,
    name: []const u8,
    type_idx: u32,
};

pub const TableDef = struct {
    elemtype: u8,
    min: u32,
    max: ?u32,
};

pub const TableImport = struct {
    module: []const u8,
    name: []const u8,
    elemtype: u8,
};

pub const GlobalDef = struct {
    valtype: u8,
    mutable: bool,
    init: i64,
};

/// A declared `global` import (`ext_kind_global` in the import section). The
/// host must supply a matching initial value at instantiation (see
/// `HostGlobal`). Imported globals occupy the low indices of the instance's
/// flat global array, ahead of the module's own defined globals.
pub const GlobalImport = struct {
    module: []const u8,
    name: []const u8,
    valtype: u8,
    mutable: bool,
};

pub const Export = struct {
    kind: u8,
    index: u32,
};

pub const CodeEntry = struct {
    local_types: []u8, // decoded per-function local valtypes (owned)
    body: []const u8, // includes the trailing `end` (borrowed)
};

pub const DataSegment = struct {
    offset: u32,
    bytes: []const u8,
};

/// An active element segment (MVP `flags == 0` form): copies `func_indices`
/// into table slot `[offset, offset + len)` at instantiation. Post-MVP
/// segment forms (passive / declarative / reftypes) are rejected at parse.
pub const ElementSegment = struct {
    /// Table index the segment targets. MVP restricts this to 0 (single table).
    table_index: u32,
    /// Initial offset (resolved from the segment's init expression).
    offset: u32,
    /// Function indices to place in the table, owned by the module allocator.
    func_indices: []u32,
};

pub const Module = struct {
    alloc: std.mem.Allocator,
    types: std.ArrayListUnmanaged(FuncType) = .empty,
    /// func_idx → type_idx; defined functions only (imports occupy the low
    /// indices).
    func_types: std.ArrayListUnmanaged(u32) = .empty,
    imports: std.ArrayListUnmanaged(FuncImport) = .empty,
    /// Defined tables (table section). MVP allows at most one.
    tables: std.ArrayListUnmanaged(TableDef) = .empty,
    /// Imported tables (import section, kind == ext_kind_table).
    table_imports: std.ArrayListUnmanaged(TableImport) = .empty,
    memory_min: u32 = 0,
    /// The `max` the memory section declared, if any (limits flag bit 0). This is
    /// the module's own hard cap on `memory.grow`; `null` means it declared none,
    /// leaving only the spec's 2^16-page ceiling.
    memory_max: ?u32 = null,
    /// Imported globals (import section, kind == ext_kind_global). Occupy the
    /// low global indices, ahead of `globals` (defined globals).
    global_imports: std.ArrayListUnmanaged(GlobalImport) = .empty,
    globals: std.ArrayListUnmanaged(GlobalDef) = .empty,
    exports: std.StringHashMapUnmanaged(Export) = .{},
    codes: std.ArrayListUnmanaged(CodeEntry) = .empty,
    data_segments: std.ArrayListUnmanaged(DataSegment) = .empty,
    /// Active element segments (element section). May be empty if the module
    /// declares no table or no segments.
    elements: std.ArrayListUnmanaged(ElementSegment) = .empty,
    /// `start` section: the function index run automatically at instantiation.
    /// `null` when the module has no start function. The referenced function
    /// must have type `[] -> []` (validated at instantiation time).
    start: ?u32 = null,

    pub fn load(alloc: std.mem.Allocator, bytes: []const u8) !Module {
        var self: Module = .{ .alloc = alloc };
        errdefer self.deinit();

        var r = Reader{ .bytes = bytes };
        if (!std.mem.eql(u8, try r.bytesN(4), &std.wasm.magic)) return error.BadMagic;
        if (!std.mem.eql(u8, try r.bytesN(4), &std.wasm.version)) return error.BadVersion;

        while (r.pos < r.bytes.len) {
            const id = try r.byte();
            const size = try r.uleb();
            const payload = try r.bytesN(size);
            var pr = Reader{ .bytes = payload };
            switch (id) {
                section_type => try self.parseTypes(&pr),
                section_import => try self.parseImports(&pr),
                section_function => try self.parseFunctions(&pr),
                section_table => try self.parseTables(&pr),
                section_memory => try self.parseMemory(&pr),
                section_global => try self.parseGlobals(&pr),
                section_export => try self.parseExports(&pr),
                section_start => try self.parseStart(&pr),
                section_code => try self.parseCode(&pr),
                section_element => try self.parseElement(&pr),
                section_data => try self.parseData(&pr),
                else => {}, // custom (0) and unknown sections are ignored
            }
        }
        return self;
    }

    pub fn deinit(self: *Module) void {
        for (self.codes.items) |c| self.alloc.free(c.local_types);
        self.codes.deinit(self.alloc);
        var it = self.exports.iterator();
        while (it.next()) |e| self.alloc.free(e.key_ptr.*);
        self.exports.deinit(self.alloc);
        self.data_segments.deinit(self.alloc);
        // `global_imports[].module`/`name` are borrowed slices into the caller's
        // buffer (same convention as `imports[].module`/`name`), so they are not
        // freed here — doing so would corrupt the owner's memory.
        self.global_imports.deinit(self.alloc);
        self.globals.deinit(self.alloc);
        self.imports.deinit(self.alloc);
        self.tables.deinit(self.alloc);
        self.table_imports.deinit(self.alloc);
        for (self.elements.items) |e| self.alloc.free(e.func_indices);
        self.elements.deinit(self.alloc);
        self.func_types.deinit(self.alloc);
        self.types.deinit(self.alloc);
    }

    fn parseTypes(self: *Module, r: *Reader) !void {
        const count = try r.uleb();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (try r.byte() != 0x60) return error.BadType;
            const nparams = try r.uleb();
            const params = try r.bytesN(nparams);
            const nret = try r.uleb();
            const returns = try r.bytesN(nret);
            if (nret > 1) return error.MultiValueUnsupported;
            for (params) |p| if (!isValtype(p)) return error.BadType;
            for (returns) |p| if (!isValtype(p)) return error.BadType;
            try self.types.append(self.alloc, .{ .params = params, .returns = returns });
        }
    }

    fn parseImports(self: *Module, r: *Reader) !void {
        const count = try r.uleb();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const module = try r.name();
            const name = try r.name();
            const kind = try r.byte();
            switch (kind) {
                ext_kind_function => {
                    const type_idx = try r.uleb();
                    try self.imports.append(self.alloc, .{
                        .module = module,
                        .name = name,
                        .type_idx = type_idx,
                    });
                },
                ext_kind_table => {
                    const elemtype = try r.byte();
                    // Consume the table limits so parsing continues cleanly.
                    const flags = try r.uleb();
                    _ = try r.uleb(); // min
                    if ((flags & 0x01) != 0) _ = try r.uleb(); // max
                    if (elemtype != table_elem_funcref) return error.BadTable;
                    if (self.table_imports.items.len >= 1) return error.MultiTableUnsupported;
                    try self.table_imports.append(self.alloc, .{
                        .module = module,
                        .name = name,
                        .elemtype = elemtype,
                    });
                },
                ext_kind_global => {
                    const valtype = try r.byte();
                    if (!isValtype(valtype)) return error.BadType;
                    const mutable = (try r.byte()) != 0;
                    try self.global_imports.append(self.alloc, .{
                        .module = module,
                        .name = name,
                        .valtype = valtype,
                        .mutable = mutable,
                    });
                },
                else => return error.UnsupportedImport,
            }
        }
    }

    fn parseFunctions(self: *Module, r: *Reader) !void {
        const count = try r.uleb();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try self.func_types.append(self.alloc, try r.uleb());
        }
    }

    fn parseTables(self: *Module, r: *Reader) !void {
        const count = try r.uleb();
        if (count > 1) return error.MultiTableUnsupported;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (self.tables.items.len >= 1) return error.MultiTableUnsupported;
            const elemtype = try r.byte();
            if (elemtype != table_elem_funcref) return error.UnsupportedTable;
            const flags = try r.uleb();
            const min = try r.uleb();
            var max: ?u32 = null;
            if ((flags & 0x01) != 0) {
                max = try r.uleb();
                if (max.? < min) return error.BadTable;
            }
            try self.tables.append(self.alloc, .{ .elemtype = elemtype, .min = min, .max = max });
        }
    }

    fn parseMemory(self: *Module, r: *Reader) !void {
        const count = try r.uleb();
        if (count > 1) return error.MultiMemoryUnsupported;
        const flags = try r.uleb();
        const min = try r.uleb();
        // Limits flag bit 0 means a `max` follows. Keep it rather than skipping
        // it: it is the module's own cap on `memory.grow`, and a host that
        // inspects a module's declared footprint relies on it being honoured.
        if ((flags & 0x01) != 0) self.memory_max = try r.uleb();
        self.memory_min = min;
    }

    fn parseGlobals(self: *Module, r: *Reader) !void {
        const count = try r.uleb();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const valtype = try r.byte();
            if (!isValtype(valtype)) return error.BadType;
            const mutable = (try r.byte()) != 0;
            const init = try parseInitExpr(r);
            try self.globals.append(self.alloc, .{ .valtype = valtype, .mutable = mutable, .init = init });
        }
    }

    fn parseExports(self: *Module, r: *Reader) !void {
        const count = try r.uleb();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const name = try r.name();
            const kind = try r.byte();
            const index = try r.uleb();
            if (kind == ext_kind_function or kind == ext_kind_global) {
                const owned = try self.alloc.dupe(u8, name);
                // Use getOrPut so a *duplicate* export name (which a malformed
                // or fuzzed module can produce) discards the new key instead of
                // leaking the previously-stored one when `put` clobbers it.
                const gop = try self.exports.getOrPut(self.alloc, owned);
                if (gop.found_existing) {
                    self.alloc.free(owned);
                } else {
                    gop.value_ptr.* = .{ .kind = kind, .index = index };
                }
            }
        }
    }

    /// `start` section: a single `varuint32` function index. MVP allows at
    /// most one; a second start section is rejected as malformed.
    fn parseStart(self: *Module, r: *Reader) !void {
        if (self.start != null) return error.DuplicateStart;
        const idx = try r.uleb();
        // Consume any trailing bytes (a malformed module could oversize the
        // section); a non-terminated reader here would be a trunc/length bug.
        if (r.pos != r.bytes.len) return error.MalformedStart;
        self.start = idx;
    }

    fn parseCode(self: *Module, r: *Reader) !void {
        const count = try r.uleb();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const body_size = try r.uleb();
            const body = try r.bytesN(body_size);
            var br = Reader{ .bytes = body };

            const decls = try br.uleb();
            var local_count: usize = 0;
            var j: usize = 0;
            while (j < decls) : (j += 1) {
                const n = try br.uleb();
                const valtype = try br.byte();
                if (!isValtype(valtype)) return error.BadType;
                local_count += n;
            }
            const local_types = try self.alloc.alloc(u8, local_count);
            errdefer self.alloc.free(local_types);

            var scan = Reader{ .bytes = body };
            _ = try scan.uleb();
            var k: usize = 0;
            j = 0;
            while (j < decls) : (j += 1) {
                const n = try scan.uleb();
                const valtype = try scan.byte();
                var m: usize = 0;
                while (m < n) : (m += 1) {
                    local_types[k] = valtype;
                    k += 1;
                }
            }
            // `br.pos` is now at the first real opcode: strip the local-decl
            // header so pc=0 executes code, not the decl-count byte.
            try self.codes.append(self.alloc, .{ .local_types = local_types, .body = body[br.pos..] });
        }
    }

    fn parseData(self: *Module, r: *Reader) !void {
        const count = try r.uleb();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const flags = try r.uleb();
            if ((flags & 0x01) != 0) return error.ActiveDataOnly;
            const offset = try parseInitExpr(r);
            const len = try r.uleb();
            const bytes = try r.bytesN(len);
            try self.data_segments.append(self.alloc, .{
                .offset = @intCast(offset),
                .bytes = bytes,
            });
        }
    }

    /// Parse the element section (id 9). Only the MVP *active* element segment
    /// is supported. Two encodings appear in the wild and both are accepted:
    ///   * classic MVP:   `offset_expr`, `count`, `count` × funcidx
    ///   * reftypes form: `flags=0`, `0x00` (funcref), `offset_expr`,
    ///                    `count`, `count` × funcidx
    /// Any other form (passive/declarative/reftypes tables) is rejected.
    fn parseElement(self: *Module, r: *Reader) !void {
        const count = try r.uleb();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            // Peek the first byte: flags==0 (the reftypes active form) has a
            // leading 0x00, whereas the classic MVP segment's offset init expr
            // begins with a non-zero opcode (i32.const == 0x41), so the two
            // encodings are unambiguous without a real peek.
            const first = try r.byte();
            const table_index: u32 = 0;
            if (first == 0x00) {
                // reftypes active form: `flags=0`, then elemkind (must be funcref).
                if (try r.byte() != 0x00) return error.UnsupportedElement;
            } else {
                // classic MVP: rewind so the offset init expr parses cleanly.
                r.pos -= 1;
            }
            const offset = try parseInitExpr(r);
            if (offset < 0) return error.BadElementOffset;
            const n = try r.uleb();
            const func_indices = try self.alloc.alloc(u32, n);
            errdefer self.alloc.free(func_indices);
            var j: usize = 0;
            while (j < n) : (j += 1) {
                func_indices[j] = try r.uleb();
            }
            try self.elements.append(self.alloc, .{
                .table_index = table_index,
                .offset = @intCast(offset),
                .func_indices = func_indices,
            });
        }
    }

    fn isValtype(b: u8) bool {
        return b == 0x7f or b == 0x7e; // i32, i64
    }

    // ── Type helpers ────────────────────────────────────────────────────
    pub fn importCount(self: *const Module) usize {
        return self.imports.items.len;
    }

    /// Number of imported globals (occupied at the low end of the global index
    /// space, ahead of the module's defined globals).
    pub fn globalImportCount(self: *const Module) usize {
        return self.global_imports.items.len;
    }

    pub fn totalFuncCount(self: *const Module) usize {
        return self.imports.items.len + self.codes.items.len;
    }

    /// Type of the function at index `func_idx` (imports first).
    pub fn funcType(self: *const Module, func_idx: u32) !FuncType {
        const total = self.totalFuncCount();
        // A module with no functions (no imports and no defined code) cannot
        // satisfy any index, and `0 >= 0` would otherwise slip past the guard
        // and index an empty slice.
        if (total == 0 or func_idx >= total) return error.BadTypeIndex;
        const type_idx = if (func_idx < self.imports.items.len)
            self.imports.items[func_idx].type_idx
        else blk: {
            const local = func_idx - @as(u32, @intCast(self.imports.items.len));
            // A function index in the "defined" range but with no defined
            // functions (e.g. the function/code section was mutated away)
            // must not index an empty slice.
            if (self.func_types.items.len == 0 or local >= self.func_types.items.len)
                return error.BadTypeIndex;
            break :blk self.func_types.items[local];
        };
        if (self.types.items.len == 0 or type_idx >= self.types.items.len) return error.BadTypeIndex;
        return self.types.items[type_idx];
    }
};

/// True iff two function types are equal (same parameter and result valtypes
/// in order). Used by `call_indirect` to validate the callee against the
/// immediate type index.
fn funcTypesEqual(a: FuncType, b: FuncType) bool {
    if (a.params.len != b.params.len or a.returns.len != b.returns.len) return false;
    if (a.params.len > 0 and !std.mem.eql(u8, a.params, b.params)) return false;
    if (a.returns.len > 0 and !std.mem.eql(u8, a.returns, b.returns)) return false;
    return true;
}

// ── Instance + VM ───────────────────────────────────────────────────────
/// A host function. `args` are the imported function's parameters in
/// declaration order; the return value is the (single) i32/i64 result.
pub const HostFn = *const fn (*Instance, []const i64) i64;

/// Initial value + mutability the host supplies for a `global` import, indexed
/// by the order the imports appear in the import section (imports first, ahead
/// of defined globals). `mutable` lets the host refuse writes to an imported
/// global the module declared mutable; if omitted it defaults to the module's
/// declared mutability at link time (see `Instance.create`).
pub const HostGlobal = struct {
    value: i64,
    mutable: bool = true,
};

/// Typed empty slice for passing "no imported globals" to `Instance.create`.
/// An inline `&.{}` cannot infer a struct-element slice type when combined with
/// another empty list in the same call, so call sites use this constant.
pub const no_globals: []const HostGlobal = &.{};

const Label = struct {
    /// `true` for a `loop`; `br` to a loop jumps back to `loop_start`, while
    /// `br` to a block/if falls through past its matching `end`.
    is_loop: bool,
    /// For a loop: the first instruction inside it (br target). For a
    /// block/if: the pc right after the blocktype byte — the origin to scan
    /// from when locating the matching `end`.
    loop_start: usize,
    /// Operand-stack depth at block entry; `br` unwinds to this (plus `arity`
    /// result values for a forward branch to a block/if).
    stack_depth: usize,
    /// Number of result values the block produces (0 or 1 in this subset).
    arity: u32,
};

const Frame = struct {
    func_idx: u32,
    locals: []i64,
    body: []const u8,
    pc: usize,
    base: usize, // operand-stack depth at entry
    labels: std.ArrayListUnmanaged(Label),
};

pub const Instance = struct {
    alloc: std.mem.Allocator,
    module: *const Module,
    host_ctx: ?*anyopaque,
    memory: std.ArrayListUnmanaged(u8) = .empty,
    globals: std.ArrayListUnmanaged(i64) = .empty,
    host_fns: []const HostFn,
    /// Host-supplied initial values for imported globals, in import order
    /// (low global indices). Empty when the module imports no globals.
    host_globals: []const HostGlobal,
    /// Per-global mutability flag (parallel to `globals`), so `global.set`
    /// can reject writes to an immutable global (imported or defined).
    global_mut: std.ArrayListUnmanaged(bool) = .empty,

    /// The single function table (funcref). Each slot is `null` when
    /// uninitialized (so `call_indirect` can trap on an empty slot) or the
    /// function index the slot dispatches to. Sized from the module's table
    /// definition (or imported table); empty when no table is declared.
    table: std.ArrayListUnmanaged(?u32) = .empty,

    stack: std.ArrayListUnmanaged(i64) = .empty,
    frames: std.ArrayListUnmanaged(Frame) = .empty,

    /// Execution budget: max instructions executed across all calls on this
    /// instance. Bounds worst-case runtime for untrusted plugins (e.g. an
    /// adversarial infinite `loop`/`br`); exhaustion yields `ExecutionLimit`.
    step_budget: usize = 10_000_000,

    /// Maximum depth of the frame stack. The step budget bounds *time*, not
    /// *memory*: a self-recursive module would otherwise grow `frames` (and each
    /// frame's `locals`) until the allocator or the budget gave out. No real
    /// module needs anything near this.
    max_call_depth: usize = 1024,

    pub fn create(
        alloc: std.mem.Allocator,
        module: *const Module,
        host_ctx: ?*anyopaque,
        host_fns: []const HostFn,
        host_globals: []const HostGlobal,
    ) !*Instance {
        const self = try alloc.create(Instance);
        errdefer self.deinit();
        self.* = .{ .alloc = alloc, .module = module, .host_ctx = host_ctx, .host_fns = host_fns, .host_globals = host_globals };

        try self.memory.appendNTimes(alloc, 0, @as(usize, module.memory_min) * page_size);
        // Imported globals occupy the low indices. The host must supply a value
        // for each; a missing value is a link error (never a panic).
        try self.globals.ensureTotalCapacity(alloc, module.global_imports.items.len + module.globals.items.len);
        if (module.global_imports.items.len > host_globals.len) return error.HostGlobalMissing;
        for (module.global_imports.items, 0..) |gi, i| {
            // The host may mark a supplied global immutable; if so it overrides
            // the import's declared mutability so `global.set` traps correctly.
            try self.global_mut.append(alloc, host_globals[i].mutable and gi.mutable);
            self.globals.appendAssumeCapacity(host_globals[i].value);
        }
        for (module.globals.items) |g| {
            try self.global_mut.append(alloc, g.mutable);
            self.globals.appendAssumeCapacity(g.init);
        }

        for (module.data_segments.items) |seg| {
            const end = @as(usize, seg.offset) + seg.bytes.len;
            if (end > self.memory.items.len) return error.MemoryOutOfBounds;
            @memcpy(self.memory.items[seg.offset .. @as(usize, seg.offset) + seg.bytes.len], seg.bytes);
        }

        // Build the function table. MVP allows at most one table (defined or
        // imported); `table_index` on element segments is therefore always 0.
        const table_count = module.tables.items.len + module.table_imports.items.len;
        if (table_count > 0) {
            const min = if (module.tables.items.len > 0)
                module.tables.items[0].min
            else blk: {
                // Imported tables contribute only a minimum size; re-validate
                // the (already parse-checked) single-table invariant defensively.
                break :blk 0;
            };
            try self.table.ensureTotalCapacity(alloc, min);
            var s: u32 = 0;
            while (s < min) : (s += 1) self.table.appendAssumeCapacity(null);
            // Apply active element segments: copy each funcidx into its slot.
            for (module.elements.items) |seg| {
                if (seg.table_index != 0) return error.BadElementTable;
                if (seg.offset +% seg.func_indices.len > self.table.items.len)
                    return error.ElementOutOfBounds;
                var k: usize = 0;
                while (k < seg.func_indices.len) : (k += 1) {
                    self.table.items[seg.offset + k] = seg.func_indices[k];
                }
            }
        }

        // Run the `start` function (if any) now that memory, globals, and the
        // table all exist. The spec requires its type be `[] -> []`; reject
        // anything else rather than risk a malformed-call stack imbalance.
        if (module.start) |start_idx| {
            const sft = try self.module.funcType(start_idx);
            if (sft.params.len != 0 or sft.returns.len != 0) return error.BadStartType;
            _ = try self.callFunction(start_idx, &.{});
            // A start function leaves no result; clear the operand stack so the
            // subsequent exported-call protocol (which also assumes an empty
            // stack) starts clean.
            self.stack.items.len = 0;
        }
        return self;
    }

    pub fn deinit(self: *Instance) void {
        for (self.frames.items) |*f| f.labels.deinit(self.alloc);
        self.frames.deinit(self.alloc);
        self.stack.deinit(self.alloc);
        self.globals.deinit(self.alloc);
        self.global_mut.deinit(self.alloc);
        self.table.deinit(self.alloc);
        self.memory.deinit(self.alloc);
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    /// Bytes of linear memory at `[ptr, ptr+len)`.
    pub fn bytes(self: *Instance, ptr: u32, len: u32) ![]const u8 {
        const end: usize = @as(usize, ptr) + len;
        if (end > self.memory.items.len) return error.MemoryOutOfBounds;
        return self.memory.items[ptr..end];
    }

    /// Read a NUL-terminated string from linear memory.
    pub fn readString(self: *Instance, ptr: u32) ![]const u8 {
        const mem = self.memory.items;
        if (ptr >= mem.len) return error.MemoryOutOfBounds;
        var end: usize = ptr;
        while (end < mem.len and mem[end] != 0) : (end += 1) {}
        return mem[ptr..end];
    }

    /// Call a function by its export name. Returns its single result (0 if the
    /// function has none).
    /// Cap the number of instructions executed across all calls on this
    /// instance (default 10M). Use this to sandbox untrusted plugins so a
    /// runaway `loop`/`br` cannot hang the host.
    pub fn setStepBudget(self: *Instance, budget: usize) void {
        self.step_budget = budget;
    }

    /// Cap the frame-stack depth (default 1024). The step budget bounds a
    /// runaway program in *time* but not in *memory*, so this is the bound that
    /// keeps deep recursion from growing `frames` without limit.
    pub fn setMaxCallDepth(self: *Instance, depth: usize) void {
        self.max_call_depth = depth;
    }

    pub fn callExport(self: *Instance, name: []const u8, args: []const i64) !i64 {
        const exp = self.module.exports.get(name) orelse return error.UnknownExport;
        if (exp.kind != ext_kind_function) return error.NotAFunction;
        const result = try self.callFunction(exp.index, args);
        // A top-level call leaves its result slot on the operand stack; drop it.
        self.stack.items.len = 0;
        return result;
    }

    fn callFunction(self: *Instance, func_idx: u32, args: []const i64) !i64 {
        const ft = try self.module.funcType(func_idx);
        if (args.len != ft.params.len) return error.ArityMismatch;
        try self.stack.ensureUnusedCapacity(self.alloc, args.len);
        for (args) |a| self.stack.appendAssumeCapacity(a);

        if (func_idx < self.module.importCount()) {
            // Defend against a loader that supplies fewer host functions than
            // the module declares imports: reject rather than panic on an
            // out-of-bounds host_fns index (sandbox safety).
            if (func_idx >= self.host_fns.len) return error.HostFnMissing;
            const host = self.host_fns[func_idx];
            const result = host(self, args);
            self.stack.items.len -= args.len;
            if (ft.returns.len == 1) try self.stack.append(self.alloc, result);
            return result;
        }
        return self.runDefined(func_idx, args);
    }

    fn runDefined(self: *Instance, func_idx: u32, args: []const i64) !i64 {
        const ft = try self.module.funcType(func_idx);
        const code = self.module.codes.items[func_idx - @as(u32, @intCast(self.module.importCount()))];

        const total = ft.params.len + code.local_types.len;
        const locals = try self.alloc.alloc(i64, total);
        for (args, 0..) |a, i| locals[i] = a;
        for (code.local_types, 0..) |_, i| locals[ft.params.len + i] = 0;

        const frame: Frame = .{
            .func_idx = func_idx,
            .locals = locals,
            .body = code.body,
            .pc = 0,
            .base = self.stack.items.len - args.len,
            .labels = .empty,
        };
        self.stack.items.len = frame.base;
        try self.frames.append(self.alloc, frame);
        errdefer self.freeTopFrame();

        while (true) {
            const result = try self.step();
            if (result) |r| return r;
        }
    }

    /// Free the top frame (locals + labels) and pop it. Used on error unwind.
    fn freeTopFrame(self: *Instance) void {
        if (self.frames.items.len == 0) return;
        const top = self.frames.items.len - 1;
        self.frames.items[top].labels.deinit(self.alloc);
        self.alloc.free(self.frames.items[top].locals);
        _ = self.frames.pop();
    }

    /// Execute one instruction of the current frame. Returns the function
    /// result when the frame's function returns.
    fn step(self: *Instance) !?i64 {
        if (self.step_budget == 0) return error.ExecutionLimit;
        self.step_budget -= 1;
        const top = self.frames.items.len - 1;
        const frame = self.frames.items[top];
        if (frame.pc >= frame.body.len) return error.InvalidOpcode;
        const op = frame.body[frame.pc];
        switch (op) {
            0x00 => return error.Trap, // unreachable
            0x01 => self.advance(1), // nop
            0x02 => try self.opBlock(), // block
            0x03 => try self.opLoop(), // loop
            0x04 => try self.opIf(), // if
            0x05 => try self.opElse(), // else
            0x0b => return self.opEnd(), // end
            0x0c => {
                if (try self.opBr()) |ret| return ret;
            },
            0x0d => {
                if (try self.opBrIf()) |ret| return ret;
            },
            0x0e => {
                if (try self.opBrTable()) |ret| return ret;
            },
            0x0f => return self.opReturn(), // return
            0x10 => try self.opCall(), // call
            0x11 => try self.opCallIndirect(), // call_indirect
            0x1a => { // drop
                _ = try self.stackPop();
                self.advance(1);
            },
            0x1b => try self.opSelect(), // select
            0x20 => try self.opLocalGet(),
            0x21 => try self.opLocalSet(),
            0x22 => try self.opLocalTee(),
            0x23 => try self.opGlobalGet(),
            0x24 => try self.opGlobalSet(),
            0x28 => try self.opLoad(4, true), // i32.load
            0x29 => try self.opLoadI64(8, true), // i64.load
            0x2a => try self.opLoad(4, true), // f32.load (same bits as i32.load)
            0x2b => try self.opLoadF64(), // f64.load
            0x2c => try self.opLoad(1, true), // i32.load8_s
            0x2d => try self.opLoad(1, false), // i32.load8_u
            0x2e => try self.opLoad(2, true), // i32.load16_s
            0x2f => try self.opLoad(2, false), // i32.load16_u
            0x30 => try self.opLoadI64(1, true), // i64.load8_s
            0x31 => try self.opLoadI64(1, false), // i64.load8_u
            0x32 => try self.opLoadI64(2, true), // i64.load16_s
            0x33 => try self.opLoadI64(2, false), // i64.load16_u
            0x34 => try self.opLoadI64(4, true), // i64.load32_s
            0x35 => try self.opLoadI64(4, false), // i64.load32_u
            0x36 => try self.opStore(4), // i32.store
            0x37 => try self.opStoreI64(8), // i64.store
            0x39 => try self.opStoreF64(), // f64.store
            0x3a => try self.opStore(1), // i32.store8
            0x3b => try self.opStore(2), // i32.store16
            0x3c => try self.opStoreI64(1), // i64.store8
            0x3d => try self.opStoreI64(2), // i64.store16
            0x3e => try self.opStoreI64(4), // i64.store32
            0x3f => try self.opMemorySize(), // memory.size
            0x40 => try self.opMemoryGrow(), // memory.grow
            0x41 => try self.opI32Const(), // i32.const
            0x42 => try self.opI64Const(), // i64.const
            0x43 => try self.opF32Const(), // f32.const
            0x44 => try self.opF64Const(), // f64.const
            0xfc => try self.opBulkMemory(), // bulk-memory prefix (memory.copy/fill)
            0x45 => try self.opUnary(binopEqlZero), // i32.eqz
            0x46 => try self.opBinaryCmp(cmpEq), // i32.eq
            0x47 => try self.opBinaryCmp(cmpNe), // i32.ne
            0x48 => try self.opBinaryCmp(cmpLtS), // i32.lt_s
            0x49 => try self.opBinaryCmp(cmpLtU), // i32.lt_u
            0x4a => try self.opBinaryCmp(cmpGtS), // i32.gt_s
            0x4b => try self.opBinaryCmp(cmpGtU), // i32.gt_u
            0x4c => try self.opBinaryCmp(cmpLeS), // i32.le_s
            0x4d => try self.opBinaryCmp(cmpLeU), // i32.le_u
            0x4e => try self.opBinaryCmp(cmpGeS), // i32.ge_s
            0x4f => try self.opBinaryCmp(cmpGeU), // i32.ge_u
            0x50 => try self.opI64Unary(i64EqlZero), // i64.eqz
            0x51 => try self.opI64BinaryCmp(i64Eq), // i64.eq
            0x52 => try self.opI64BinaryCmp(i64Ne), // i64.ne
            0x53 => try self.opI64BinaryCmp(i64LtS), // i64.lt_s
            0x54 => try self.opI64BinaryCmp(i64LtU), // i64.lt_u
            0x55 => try self.opI64BinaryCmp(i64GtS), // i64.gt_s
            0x56 => try self.opI64BinaryCmp(i64GtU), // i64.gt_u
            0x57 => try self.opI64BinaryCmp(i64LeS), // i64.le_s
            0x58 => try self.opI64BinaryCmp(i64LeU), // i64.le_u
            0x59 => try self.opI64BinaryCmp(i64GeS), // i64.ge_s
            0x5a => try self.opI64BinaryCmp(i64GeU), // i64.ge_u
            0x5b => try self.opF32Cmp(f32Eq), // f32.eq
            0x5c => try self.opF32Cmp(f32Ne), // f32.ne
            0x5d => try self.opF32Cmp(f32Lt), // f32.lt
            0x5e => try self.opF32Cmp(f32Gt), // f32.gt
            0x5f => try self.opF32Cmp(f32Le), // f32.le
            0x60 => try self.opF32Cmp(f32Ge), // f32.ge
            0x61 => try self.opF64Cmp(f64Eq), // f64.eq
            0x62 => try self.opF64Cmp(f64Ne), // f64.ne
            0x63 => try self.opF64Cmp(f64Lt), // f64.lt
            0x64 => try self.opF64Cmp(f64Gt), // f64.gt
            0x65 => try self.opF64Cmp(f64Le), // f64.le
            0x66 => try self.opF64Cmp(f64Ge), // f64.ge
            0x6a => try self.opBinary(arithAdd), // i32.add
            0x6b => try self.opBinary(arithSub), // i32.sub
            0x6c => try self.opBinary(arithMul), // i32.mul
            0x6d => try self.opBinary(arithDivS), // i32.div_s
            0x6e => try self.opBinary(arithDivU), // i32.div_u
            0x6f => try self.opBinary(arithRemS), // i32.rem_s
            0x70 => try self.opBinary(arithRemU), // i32.rem_u
            0x71 => try self.opBinary(arithAnd), // i32.and
            0x72 => try self.opBinary(arithOr), // i32.or
            0x73 => try self.opBinary(arithXor), // i32.xor
            0x74 => try self.opBinary(arithShl), // i32.shl
            0x75 => try self.opBinary(arithShrS), // i32.shr_s
            0x76 => try self.opBinary(arithShrU), // i32.shr_u
            0x67 => try self.opI32Clz(), // i32.clz
            0x68 => try self.opI32Ctz(), // i32.ctz
            0x69 => try self.opI32Popcnt(), // i32.popcnt
            0x7c => try self.opI64Binary(i64Add), // i64.add
            0x7d => try self.opI64Binary(i64Sub), // i64.sub
            0x7e => try self.opI64Binary(i64Mul), // i64.mul
            0x7f => try self.opI64Binary(i64DivS), // i64.div_s
            0x80 => try self.opI64Binary(i64DivU), // i64.div_u
            0x81 => try self.opI64Binary(i64RemS), // i64.rem_s
            0x82 => try self.opI64Binary(i64RemU), // i64.rem_u
            0x83 => try self.opI64Binary(i64And), // i64.and
            0x84 => try self.opI64Binary(i64Or), // i64.or
            0x85 => try self.opI64Binary(i64Xor), // i64.xor
            0x86 => try self.opI64Binary(i64Shl), // i64.shl
            0x87 => try self.opI64Binary(i64ShrS), // i64.shr_s
            0x88 => try self.opI64Binary(i64ShrU), // i64.shr_u
            0x79 => try self.opI64Clz(), // i64.clz
            0x7a => try self.opI64Ctz(), // i64.ctz
            0x7b => try self.opI64Popcnt(), // i64.popcnt
            0x8b => try self.opF32Unary(f32Abs), // f32.abs
            0x8c => try self.opF32Unary(f32Neg), // f32.neg
            0x8d => try self.opF32Unary(f32Ceil), // f32.ceil
            0x8e => try self.opF32Unary(f32Floor), // f32.floor
            0x8f => try self.opF32Unary(f32Trunc), // f32.trunc
            0x90 => try self.opF32Unary(f32Nearest), // f32.nearest
            0x91 => try self.opF32Unary(f32Sqrt), // f32.sqrt
            0x92 => try self.opF32Binary(f32Add), // f32.add
            0x93 => try self.opF32Binary(f32Sub), // f32.sub
            0x94 => try self.opF32Binary(f32Mul), // f32.mul
            0x95 => try self.opF32Binary(f32Div), // f32.div
            0x96 => try self.opF32Binary(f32Min), // f32.min
            0x97 => try self.opF32Binary(f32Max), // f32.max
            0x98 => try self.opF32Binary(f32Copysign), // f32.copysign
            0x99 => try self.opF64Unary(f64Abs), // f64.abs
            0x9a => try self.opF64Unary(f64Neg), // f64.neg
            0x9b => try self.opF64Unary(f64Ceil), // f64.ceil
            0x9c => try self.opF64Unary(f64Floor), // f64.floor
            0x9d => try self.opF64Unary(f64Trunc), // f64.trunc
            0x9e => try self.opF64Unary(f64Nearest), // f64.nearest
            0x9f => try self.opF64Unary(f64Sqrt), // f64.sqrt
            0xa0 => try self.opF64Binary(f64Add), // f64.add
            0xa1 => try self.opF64Binary(f64Sub), // f64.sub
            0xa2 => try self.opF64Binary(f64Mul), // f64.mul
            0xa3 => try self.opF64Binary(f64Div), // f64.div
            0xa4 => try self.opF64Binary(f64Min), // f64.min
            0xa5 => try self.opF64Binary(f64Max), // f64.max
            0xa6 => try self.opF64Binary(f64Copysign), // f64.copysign
            // numeric conversions (spec opcode layout)
            0xa7 => try self.opI32WrapI64(), // i32.wrap_i64
            0xa8 => try self.opI32TruncF32S(), // i32.trunc_f32_s
            0xa9 => try self.opI32TruncF32U(), // i32.trunc_f32_u
            0xaa => try self.opI32TruncF64S(), // i32.trunc_f64_s
            0xab => try self.opI32TruncF64U(), // i32.trunc_f64_u
            0xac => try self.opI64ExtendI32S(), // i64.extend_i32_s
            0xad => try self.opI64ExtendI32U(), // i64.extend_i32_u
            0xae => try self.opI64TruncF32S(), // i64.trunc_f32_s
            0xaf => try self.opI64TruncF32U(), // i64.trunc_f32_u
            0xb0 => try self.opI64TruncF64S(), // i64.trunc_f64_s
            0xb1 => try self.opI64TruncF64U(), // i64.trunc_f64_u
            0xb2 => try self.opF32ConvertI32S(), // f32.convert_i32_s
            0xb3 => try self.opF32ConvertI32U(), // f32.convert_i32_u
            0xb7 => try self.opF64ConvertI32S(), // f64.convert_i32_s
            0xb8 => try self.opF64ConvertI32U(), // f64.convert_i32_u
            0xbb => try self.opF64PromoteF32(), // f64.promote_f32
            0xbc => try self.opI32ReinterpretF32(), // i32.reinterpret_f32
            0xbd => try self.opI64ReinterpretF64(), // i64.reinterpret_f64
            0xbe => try self.opF32ReinterpretI32(), // f32.reinterpret_i32
            0xbf => try self.opF64ReinterpretI64(), // f64.reinterpret_i64
            0xc0 => try self.opI32Extend8S(), // i32.extend8_s
            0xc1 => try self.opI32Extend16S(), // i32.extend16_s
            0xc2 => try self.opI64Extend8S(), // i64.extend8_s
            0xc3 => try self.opI64Extend16S(), // i64.extend16_s
            // 0xb4/b5 = f32.convert_i64_s/u, 0xb6 = f32.demote_f64,
            // 0xb9/bA = f64.convert_i64_s/u, 0xbB = f64.promote_f32 —
            // not yet wired; fall through to UnsupportedOpcode.
            else => return error.UnsupportedOpcode,
        }
        return null;
    }

    fn advance(self: *Instance, n: usize) void {
        self.frames.items[self.frames.items.len - 1].pc += n;
    }

    fn stackPush(self: *Instance, v: i64) !void {
        try self.stack.append(self.alloc, v);
    }

    fn stackPop(self: *Instance) !i64 {
        const frame = self.frames.items[self.frames.items.len - 1];
        if (self.stack.items.len == frame.base) return error.StackUnderflow;
        const v = self.stack.items[self.stack.items.len - 1];
        self.stack.items.len -= 1;
        return v;
    }

    // ── Instruction implementations ─────────────────────────────────────

    fn opI32Const(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        const v = try r.sleb();
        try self.stackPush(@as(i32, @truncate(v)));
        self.frames.items[top].pc = r.pos;
    }

    fn opI64Const(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        try self.stackPush(try r.sleb());
        self.frames.items[top].pc = r.pos;
    }

    fn opLocalGet(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        const idx = try r.uleb();
        if (self.frames.items[top].locals.len == 0 or idx >= self.frames.items[top].locals.len) return error.LocalIndexOutOfBounds;
        try self.stackPush(self.frames.items[top].locals[idx]);
        self.frames.items[top].pc = r.pos;
    }

    fn opLocalSet(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        const idx = try r.uleb();
        if (self.frames.items[top].locals.len == 0 or idx >= self.frames.items[top].locals.len) return error.LocalIndexOutOfBounds;
        const v = try self.stackPop();
        self.frames.items[top].locals[idx] = v;
        self.frames.items[top].pc = r.pos;
    }

    fn opLocalTee(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        const idx = try r.uleb();
        if (self.frames.items[top].locals.len == 0 or idx >= self.frames.items[top].locals.len) return error.LocalIndexOutOfBounds;
        const v = try self.stackPop();
        self.frames.items[top].locals[idx] = v;
        try self.stackPush(v);
        self.frames.items[top].pc = r.pos;
    }

    fn opGlobalGet(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        const idx = try r.uleb();
        if (self.globals.items.len == 0 or idx >= self.globals.items.len) return error.GlobalIndexOutOfBounds;
        try self.stackPush(self.globals.items[idx]);
        self.frames.items[top].pc = r.pos;
    }

    fn opGlobalSet(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        const idx = try r.uleb();
        if (self.globals.items.len == 0 or idx >= self.globals.items.len) return error.GlobalIndexOutOfBounds;
        if (idx >= self.global_mut.items.len or !self.global_mut.items[idx]) return error.GlobalImmutable;
        self.globals.items[idx] = try self.stackPop();
        self.frames.items[top].pc = r.pos;
    }

    fn opCall(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        const callee = try r.uleb();
        self.frames.items[top].pc = r.pos; // resume here when the callee returns

        const ft = try self.module.funcType(callee);
        if (ft.params.len > self.stack.items.len) return error.StackUnderflow;

        if (callee < self.module.importCount()) {
            if (callee >= self.host_fns.len) return error.HostFnMissing;
            const arg_start = self.stack.items.len - ft.params.len;
            const args = self.stack.items[arg_start..];
            const result = self.host_fns[callee](self, args);
            self.stack.items.len = arg_start;
            if (ft.returns.len == 1) try self.stackPush(result);
            return;
        }

        // Defined callee: build its frame.
        // Bound the call depth. The frame stack is heap-allocated and otherwise
        // limited only by the step budget, which bounds *time* and not
        // *memory*: an adversarial self-recursive module would grow `frames`
        // (and each frame's `locals`) into the gigabytes before it tripped.
        if (self.frames.items.len >= self.max_call_depth) return error.CallDepthExceeded;
        const code = self.module.codes.items[callee - @as(u32, @intCast(self.module.importCount()))];
        const total = ft.params.len + code.local_types.len;
        const locals = try self.alloc.alloc(i64, total);
        errdefer self.alloc.free(locals);
        const arg_start = self.stack.items.len - ft.params.len;
        for (ft.params, 0..) |_, i| locals[i] = self.stack.items[arg_start + i];
        for (code.local_types, 0..) |_, i| locals[ft.params.len + i] = 0;

        const new_frame = Frame{
            .func_idx = callee,
            .locals = locals,
            .body = code.body,
            .pc = 0,
            .base = arg_start,
            .labels = .empty,
        };
        self.stack.items.len = arg_start;
        try self.frames.append(self.alloc, new_frame);
    }

    fn opCallIndirect(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        const type_idx = try r.uleb();
        const table_idx = try r.uleb();
        self.frames.items[top].pc = r.pos; // resume here when the callee returns

        // MVP has exactly one table, so any non-zero table index is invalid.
        if (table_idx != 0) return error.CallIndirectBadTable;
        if (self.table.items.len == 0) return error.CallIndirectOutOfBounds;

        // The table index is the top operand.
        const i = try self.stackPop();
        const slot = @as(u32, @truncate(@as(u64, @bitCast(i))));
        if (slot >= self.table.items.len) return error.CallIndirectOutOfBounds;
        const callee = self.table.items[slot] orelse return error.CallIndirectUninitialized;

        // Validate the callee's type matches the immediate type index. The
        // actual function type must equal `types[type_idx]` exactly (params
        // and results); a mismatch is a trap, not a panic.
        if (type_idx >= self.module.types.items.len) return error.CallIndirectTypeMismatch;
        const expected = self.module.types.items[type_idx];
        const ft = try self.module.funcType(callee);
        if (!funcTypesEqual(expected, ft)) return error.CallIndirectTypeMismatch;

        // From here the handling is identical to a direct call (opCall) with a
        // resolved callee.
        if (ft.params.len > self.stack.items.len) return error.StackUnderflow;

        if (callee < self.module.importCount()) {
            if (callee >= self.host_fns.len) return error.HostFnMissing;
            const arg_start = self.stack.items.len - ft.params.len;
            const args = self.stack.items[arg_start..];
            const result = self.host_fns[callee](self, args);
            self.stack.items.len = arg_start;
            if (ft.returns.len == 1) try self.stackPush(result);
            return;
        }

        // Bound the call depth. The frame stack is heap-allocated and otherwise
        // limited only by the step budget, which bounds *time* and not
        // *memory*: an adversarial self-recursive module would grow `frames`
        // (and each frame's `locals`) into the gigabytes before it tripped.
        if (self.frames.items.len >= self.max_call_depth) return error.CallDepthExceeded;
        const code = self.module.codes.items[callee - @as(u32, @intCast(self.module.importCount()))];
        const total = ft.params.len + code.local_types.len;
        const locals = try self.alloc.alloc(i64, total);
        errdefer self.alloc.free(locals);
        const arg_start = self.stack.items.len - ft.params.len;
        for (ft.params, 0..) |_, j| locals[j] = self.stack.items[arg_start + j];
        for (code.local_types, 0..) |_, j| locals[ft.params.len + j] = 0;

        const new_frame = Frame{
            .func_idx = callee,
            .locals = locals,
            .body = code.body,
            .pc = 0,
            .base = arg_start,
            .labels = .empty,
        };
        self.stack.items.len = arg_start;
        try self.frames.append(self.alloc, new_frame);
    }

    fn opIf(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        const cond = try self.stackPop();
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        const arity = try readBlockArity(&r);
        const after = r.pos;

        try self.frames.items[top].labels.append(self.alloc, .{
            .is_loop = false,
            .loop_start = after,
            .stack_depth = self.stack.items.len,
            .arity = arity,
        });

        if (cond == 0) {
            const target = skipToElseOrEnd(self.frames.items[top].body, after) orelse return error.MalformedBlocks;
            // If a matching `else` exists, jump to its first instruction (past
            // the `else` opcode); otherwise skip straight to the `end`.
            self.frames.items[top].pc = if (self.frames.items[top].body[target] == 0x05) target + 1 else target;
        } else {
            self.frames.items[top].pc = after;
        }
    }

    fn opElse(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        const target = skipToEnd(self.frames.items[top].body, self.frames.items[top].pc + 1) orelse return error.MalformedBlocks;
        self.frames.items[top].pc = target;
    }

    fn opBlock(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        const arity = try readBlockArity(&r);
        try self.frames.items[top].labels.append(self.alloc, .{
            .is_loop = false,
            .loop_start = r.pos,
            .stack_depth = self.stack.items.len,
            .arity = arity,
        });
        self.frames.items[top].pc = r.pos;
    }

    fn opLoop(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        const arity = try readBlockArity(&r);
        try self.frames.items[top].labels.append(self.alloc, .{
            .is_loop = true,
            .loop_start = r.pos,
            .stack_depth = self.stack.items.len,
            .arity = arity,
        });
        self.frames.items[top].pc = r.pos;
    }

    /// Branch to label `l` (0 = innermost). Unwinds the operand stack to the
    /// label's entry depth, then either jumps back to a loop start or falls
    /// through past the matching `end`.
    fn doBranch(self: *Instance, l: u32) !?i64 {
        const top = self.frames.items.len - 1;
        const labels = &self.frames.items[top].labels;
        if (l >= labels.items.len) return error.MalformedBlocks;
        const label = labels.items[labels.items.len - 1 - l];
        // A forward `br` to a block/if must preserve its `arity` result values
        // (they sit on top of `stack_depth`); `br` to a loop restarts it with
        // no result, so only `stack_depth` is kept.
        const keep = label.stack_depth + label.arity;
        if (keep > self.stack.items.len) return error.StackUnderflow;
        self.stack.items.len = keep;
        if (label.is_loop) {
            // A backward `br` to a loop restarts it in place; the loop's own
            // label must stay live so the next iteration can branch again.
            self.frames.items[top].pc = label.loop_start;
        } else {
            // A forward `br` to a block/if unwinds the control stack up to and
            // including the target label: the target and every label nested
            // inside it are popped, otherwise the trailing `end` would wrongly
            // pop the target's label instead of exiting the function.
            labels.items.len = labels.items.len - 1 - l;
            const end = skipToEnd(self.frames.items[top].body, label.loop_start) orelse return error.MalformedBlocks;
            // `br` to the implicit outermost block (the function body) exits the
            // function — `end + 1` would fall off the end of the body.
            if (end + 1 >= self.frames.items[top].body.len) return self.opReturn();
            self.frames.items[top].pc = end + 1; // resume after the `end`
        }
        return null;
    }

    fn opBr(self: *Instance) !?i64 {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        const l = try r.uleb();
        return self.doBranch(l);
    }

    fn opBrIf(self: *Instance) !?i64 {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        const l = try r.uleb();
        self.frames.items[top].pc = r.pos; // resume here if the branch is not taken
        const cond = try self.stackPop();
        if (cond != 0) return self.doBranch(l);
        return null;
    }

    /// `br_table`: pops an i32 index, then jumps to the i-th entry of the
    /// target list if `i < count`, else to the trailing default label. Targets
    /// are relative label depths, identical to `br`/`br_if`, so branching to
    /// them is delegated to `doBranch`.
    fn opBrTable(self: *Instance) !?i64 {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        const count = try r.uleb();
        const idx = @as(u32, @truncate(@as(u64, @bitCast(try self.stackPop()))));
        // Walk the whole immediate (count targets + a default) so it is fully
        // consumed for pc; the chosen target is whichever matched the index.
        var chosen: u32 = 0;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const t = try r.uleb();
            if (i == idx) chosen = t;
        }
        const default_label = try r.uleb();
        if (idx >= count) chosen = default_label;
        self.frames.items[top].pc = r.pos;
        return self.doBranch(chosen);
    }

    /// On `end`: pop a control label, or return from the function when none.
    fn opEnd(self: *Instance) !?i64 {
        const top = self.frames.items.len - 1;
        if (self.frames.items[top].labels.items.len > 0) {
            self.frames.items[top].labels.items.len -= 1;
            self.frames.items[top].pc += 1; // fall through block end
            return null;
        }
        return self.opReturn();
    }

    fn opReturn(self: *Instance) !?i64 {
        const frame = self.frames.items[self.frames.items.len - 1];
        const ft = try self.module.funcType(frame.func_idx);
        // A `return` (or `br` to the function body) with too few operands on
        // the stack for the declared result count is malformed; guard the
        // subtraction so it cannot wrap `usize` and panic in safe builds.
        if (ft.returns.len > self.stack.items.len) return error.StackUnderflow;
        const ret_start = self.stack.items.len - ft.returns.len;
        const result: i64 = if (ft.returns.len == 1) self.stack.items[ret_start] else 0;

        self.freeTopFrame();
        if (self.frames.items.len == 0) {
            if (ft.returns.len == 1) try self.stackPush(result);
            return result;
        }
        if (ft.returns.len == 1) try self.stackPush(result);
        return null;
    }

    fn opLoad(self: *Instance, size: usize, signed: bool) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        _ = try r.uleb(); // align
        const offset = try r.uleb();
        self.frames.items[top].pc = r.pos;

        const addr32 = @as(u32, @truncate(@as(u64, @bitCast(try self.stackPop()))));
        // Use u64 for the address arithmetic so a huge `offset` cannot wrap
        // `usize` and trap on overflow in safe builds.
        const end: u64 = @as(u64, addr32) + offset + size;
        if (end > self.memory.items.len) return error.MemoryOutOfBounds;
        const addr = @as(usize, addr32 + offset);
        var v: u64 = 0;
        var i: usize = 0;
        while (i < size) : (i += 1) {
            v |= @as(u64, self.memory.items[addr + i]) << @intCast(8 * i);
        }
        // Extend the low `size` bytes to a full 32-bit `i32` (the WASM i32
        // result). Size 4 is already 32-bit; narrower loads sign/zero-extend.
        const result: i64 = switch (size) {
            4 => @as(i32, @truncate(@as(i64, @bitCast(v)))),
            2 => blk: {
                const lo16: u32 = @truncate(v);
                const ext: i32 = if (signed) blk2: {
                    // Sign-extend the low 16 bits: shift into the i32 sign
                    // position, then arithmetic-shift back (preserves sign).
                    const shifted: i32 = @bitCast(lo16 << 16);
                    break :blk2 shifted >> 16;
                } else @bitCast(lo16);
                break :blk ext;
            },
            1 => blk: {
                const lo8: u32 = @truncate(v);
                const ext: i32 = if (signed) blk3: {
                    const shifted: i32 = @bitCast(lo8 << 24);
                    break :blk3 shifted >> 24;
                } else @bitCast(lo8);
                break :blk ext;
            },
            else => @as(i32, @truncate(@as(i64, @bitCast(v)))),
        };
        try self.stackPush(result);
    }

    fn opStore(self: *Instance, size: usize) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        _ = try r.uleb(); // align
        const offset = try r.uleb();
        self.frames.items[top].pc = r.pos;

        const value = try self.stackPop();
        const addr32 = @as(u32, @truncate(@as(u64, @bitCast(try self.stackPop()))));
        // Use u64 for the address arithmetic so a huge `offset` cannot wrap
        // `usize` and trap on overflow in safe builds.
        const end: u64 = @as(u64, addr32) + offset + size;
        if (end > self.memory.items.len) return error.MemoryOutOfBounds;
        const addr = @as(usize, addr32 + offset);
        var i: usize = 0;
        while (i < size) : (i += 1) {
            self.memory.items[addr + i] = @truncate(@as(u64, @bitCast(value)) >> @intCast(8 * i));
        }
    }

    // i64 variants of load/store. The operand stack holds `i64`; the loaded
    // value is sign/zero-extended from the low `size` bytes to a full 64-bit
    // `i64` (rather than truncated to i32 like the i32 ops).
    fn opLoadI64(self: *Instance, size: usize, signed: bool) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        _ = try r.uleb(); // align
        const offset = try r.uleb();
        self.frames.items[top].pc = r.pos;

        const addr32 = @as(u32, @truncate(@as(u64, @bitCast(try self.stackPop()))));
        const end: u64 = @as(u64, addr32) + offset + size;
        if (end > self.memory.items.len) return error.MemoryOutOfBounds;
        const addr = @as(usize, addr32 + offset);
        var raw: u64 = 0;
        var i: usize = 0;
        while (i < size) : (i += 1) {
            raw |= @as(u64, self.memory.items[addr + i]) << @intCast(8 * i);
        }
        const result: i64 = if (signed) blk: {
            // Sign-extend `raw` from `size*8` bits to a full 64-bit `i64`.
            // A full-width load (size == 8) is already 64-bit. For narrower
            // loads, shift the low `bits` left into the sign position, then
            // arithmetic-shift right; arithmetic `>>` on `i64` is sign-
            // preserving, which `u64 >>` (logical) would NOT be.
            if (size == 8) break :blk @bitCast(raw);
            const bits: u6 = @intCast(size * 8);
            const shift_amt: u6 = @intCast(64 - @as(u32, bits));
            const as_i64: i64 = @bitCast(raw);
            break :blk (as_i64 << shift_amt) >> shift_amt;
        } else @as(i64, @intCast(raw));
        try self.stackPush(result);
    }

    fn opStoreI64(self: *Instance, size: usize) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        _ = try r.uleb(); // align
        const offset = try r.uleb();
        self.frames.items[top].pc = r.pos;

        const value = try self.stackPop();
        const addr32 = @as(u32, @truncate(@as(u64, @bitCast(try self.stackPop()))));
        const end: u64 = @as(u64, addr32) + offset + size;
        if (end > self.memory.items.len) return error.MemoryOutOfBounds;
        const addr = @as(usize, addr32 + offset);
        var i: usize = 0;
        while (i < size) : (i += 1) {
            self.memory.items[addr + i] = @truncate(@as(u64, @bitCast(value)) >> @intCast(8 * i));
        }
    }

    fn opLoadF64(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        _ = try r.uleb(); // align
        const offset = try r.uleb();
        self.frames.items[top].pc = r.pos;

        const addr32 = @as(u32, @truncate(@as(u64, @bitCast(try self.stackPop()))));
        const end: u64 = @as(u64, addr32) + offset + 8;
        if (end > self.memory.items.len) return error.MemoryOutOfBounds;
        const addr = @as(usize, addr32 + offset);
        var raw: u64 = 0;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            raw |= @as(u64, self.memory.items[addr + i]) << @intCast(8 * i);
        }
        try self.pushF64(@bitCast(raw));
    }

    fn opStoreF64(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        _ = try r.uleb(); // align
        const offset = try r.uleb();
        self.frames.items[top].pc = r.pos;

        const value = try self.stackPop();
        const addr32 = @as(u32, @truncate(@as(u64, @bitCast(try self.stackPop()))));
        const end: u64 = @as(u64, addr32) + offset + 8;
        if (end > self.memory.items.len) return error.MemoryOutOfBounds;
        const addr = @as(usize, addr32 + offset);
        const bits: u64 = @bitCast(value);
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            self.memory.items[addr + i] = @truncate(bits >> @intCast(8 * i));
        }
    }

    // f32 helpers. The operand stack stores f32 as its 32-bit IEEE-754 bit
    // pattern zero-extended into i64 (same layout as i32), so we bitCast the
    // low 32 bits to `f32`, compute, then bitCast back to `u32` and widen.
    fn popF32(self: *Instance) !f32 {
        const raw_i64 = try self.stackPop();
        const lo32: u32 = @truncate(@as(u64, @bitCast(raw_i64)));
        return @bitCast(lo32);
    }

    fn pushF32(self: *Instance, v: f32) !void {
        try self.stackPush(@as(i64, @intCast(@as(u32, @bitCast(v)))));
    }

    fn opF32Const(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        const raw = try r.bytesN(4); // 4 raw little-endian IEEE-754 bytes
        var u: u32 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) u |= @as(u32, raw[i]) << @intCast(8 * i);
        self.frames.items[top].pc = r.pos;
        try self.pushF32(@bitCast(u));
    }

    // f64 variants. The operand stack stores f64 as its full 64-bit IEEE-754
    // bit pattern in the i64 slot (no truncation needed, unlike f32 which
    // zero-extends into i64).
    fn popF64(self: *Instance) !f64 {
        return @bitCast(try self.stackPop());
    }

    fn pushF64(self: *Instance, v: f64) !void {
        try self.stackPush(@bitCast(v));
    }

    fn opF64Const(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        const raw = try r.bytesN(8); // 8 raw little-endian IEEE-754 bytes
        var u: u64 = 0;
        var i: usize = 0;
        while (i < 8) : (i += 1) u |= @as(u64, raw[i]) << @intCast(8 * i);
        self.frames.items[top].pc = r.pos;
        try self.pushF64(@bitCast(u));
    }

    fn opF32Unary(self: *Instance, comptime f: fn (f32) f32) !void {
        const a = try self.popF32();
        try self.pushF32(f(a));
        self.advance(1);
    }

    fn opF32Binary(self: *Instance, comptime f: fn (f32, f32) f32) !void {
        const b = try self.popF32();
        const a = try self.popF32();
        try self.pushF32(f(a, b));
        self.advance(1);
    }

    fn opF32Cmp(self: *Instance, comptime f: fn (f32, f32) bool) !void {
        const b = try self.popF32();
        const a = try self.popF32();
        try self.stackPush(if (f(a, b)) 1 else 0);
        self.advance(1);
    }

    fn opF64Unary(self: *Instance, comptime f: fn (f64) f64) !void {
        const a = try self.popF64();
        try self.pushF64(f(a));
        self.advance(1);
    }

    fn opF64Binary(self: *Instance, comptime f: fn (f64, f64) f64) !void {
        const b = try self.popF64();
        const a = try self.popF64();
        try self.pushF64(f(a, b));
        self.advance(1);
    }

    fn opF64Cmp(self: *Instance, comptime f: fn (f64, f64) bool) !void {
        const b = try self.popF64();
        const a = try self.popF64();
        try self.stackPush(if (f(a, b)) 1 else 0);
        self.advance(1);
    }

    // select (0x1b): untyped MVP form. Pops c (i32 cond, top of stack),
    // then val1, then val2; pushes val1 if c != 0 else val2. The three values
    // are kept as raw i64 bit patterns — select is type-agnostic so we must
    // not reinterpret them by type. (The typed `select t` post-MVP form is
    // not supported.)
    fn opSelect(self: *Instance) !void {
        const c = try self.stackPop();
        const val1 = try self.stackPop();
        const val2 = try self.stackPop();
        try self.stackPush(if (c != 0) val1 else val2);
        self.advance(1);
    }

    // ── Numeric conversions & bit-counts (P0: f64-dependent ops omitted) ──
    fn opI32Clz(self: *Instance) !void {
        const a = @as(u32, @bitCast(@as(i32, @truncate(try self.stackPop()))));
        try self.stackPush(@as(i64, @intCast(@clz(a))));
        self.advance(1);
    }
    fn opI32Ctz(self: *Instance) !void {
        const a = @as(u32, @bitCast(@as(i32, @truncate(try self.stackPop()))));
        try self.stackPush(@as(i64, @intCast(@ctz(a))));
        self.advance(1);
    }
    fn opI32Popcnt(self: *Instance) !void {
        const a = @as(u32, @bitCast(@as(i32, @truncate(try self.stackPop()))));
        try self.stackPush(@as(i64, @intCast(@popCount(a))));
        self.advance(1);
    }
    fn opI64Clz(self: *Instance) !void {
        const a = @as(u64, @bitCast(try self.stackPop()));
        try self.stackPush(@as(i64, @intCast(@clz(a))));
        self.advance(1);
    }
    fn opI64Ctz(self: *Instance) !void {
        const a = @as(u64, @bitCast(try self.stackPop()));
        try self.stackPush(@as(i64, @intCast(@ctz(a))));
        self.advance(1);
    }
    fn opI64Popcnt(self: *Instance) !void {
        const a = @as(u64, @bitCast(try self.stackPop()));
        try self.stackPush(@as(i64, @intCast(@popCount(a))));
        self.advance(1);
    }

    fn opI32WrapI64(self: *Instance) !void {
        const a = try self.stackPop();
        try self.stackPush(@as(i64, @as(i32, @truncate(a))));
        self.advance(1);
    }
    fn opI64ExtendI32S(self: *Instance) !void {
        const a = @as(i32, @truncate(try self.stackPop()));
        try self.stackPush(@as(i64, a));
        self.advance(1);
    }
    fn opI64ExtendI32U(self: *Instance) !void {
        const a = @as(u32, @bitCast(@as(i32, @truncate(try self.stackPop()))));
        try self.stackPush(@as(i64, @intCast(a)));
        self.advance(1);
    }
    fn opI32Extend8S(self: *Instance) !void {
        const a = @as(i32, @truncate(try self.stackPop()));
        try self.stackPush(@as(i64, @as(i32, @as(i8, @truncate(a)))));
        self.advance(1);
    }
    fn opI32Extend16S(self: *Instance) !void {
        const a = @as(i32, @truncate(try self.stackPop()));
        try self.stackPush(@as(i64, @as(i32, @as(i16, @truncate(a)))));
        self.advance(1);
    }
    fn opI64Extend8S(self: *Instance) !void {
        const a = try self.stackPop();
        try self.stackPush(@as(i64, @as(i8, @truncate(a))));
        self.advance(1);
    }
    fn opI64Extend16S(self: *Instance) !void {
        const a = try self.stackPop();
        try self.stackPush(@as(i64, @as(i16, @truncate(a))));
        self.advance(1);
    }

    fn opF32ReinterpretI32(self: *Instance) !void {
        const a = @as(u32, @bitCast(@as(i32, @truncate(try self.stackPop()))));
        try self.pushF32(@bitCast(a));
        self.advance(1);
    }
    fn opI32ReinterpretF32(self: *Instance) !void {
        const a = try self.popF32();
        try self.stackPush(@as(i64, @intCast(@as(u32, @bitCast(a)))));
        self.advance(1);
    }

    // Float→int truncation. WASM traps on NaN and on values outside the
    // representable range; `@intFromFloat` on those would panic in safe mode,
    // so we guard explicitly. The bounds below are exact for f32 inputs
    // (the only f32 values below -2^31 / at/above 2^31 are already out of
    // range, and likewise for i64 at ±2^63).
    fn opI32TruncF32S(self: *Instance) !void {
        const a = try self.popF32();
        if (f32IsNan(a) or a < -2147483648.0 or a >= 2147483648.0) return error.InvalidConversion;
        try self.stackPush(@as(i64, @intCast(@as(i32, @intFromFloat(a)))));
        self.advance(1);
    }
    fn opI32TruncF32U(self: *Instance) !void {
        const a = try self.popF32();
        if (f32IsNan(a) or a < 0.0 or a >= 4294967296.0) return error.InvalidConversion;
        const u: u32 = @intFromFloat(a);
        try self.stackPush(@as(i64, @intCast(u)));
        self.advance(1);
    }
    fn opI64TruncF32S(self: *Instance) !void {
        const a = try self.popF32();
        if (f32IsNan(a) or a < -9223372036854775808.0 or a >= 9223372036854775808.0) return error.InvalidConversion;
        try self.stackPush(@as(i64, @intFromFloat(a)));
        self.advance(1);
    }
    fn opI64TruncF32U(self: *Instance) !void {
        const a = try self.popF32();
        if (f32IsNan(a) or a < 0.0 or a >= 18446744073709551616.0) return error.InvalidConversion;
        const u: u64 = @intFromFloat(a);
        try self.stackPush(@as(i64, @intCast(u)));
        self.advance(1);
    }
    fn opF32ConvertI32S(self: *Instance) !void {
        const a = @as(i32, @truncate(try self.stackPop()));
        try self.pushF32(@floatFromInt(a));
        self.advance(1);
    }
    fn opF32ConvertI32U(self: *Instance) !void {
        const a = @as(u32, @bitCast(@as(i32, @truncate(try self.stackPop()))));
        try self.pushF32(@floatFromInt(a));
        self.advance(1);
    }
    fn opF64ConvertI32S(self: *Instance) !void {
        const a = @as(i32, @truncate(try self.stackPop()));
        try self.pushF64(@floatFromInt(a));
        self.advance(1);
    }
    fn opF64ConvertI32U(self: *Instance) !void {
        const a = @as(u32, @bitCast(@as(i32, @truncate(try self.stackPop()))));
        try self.pushF64(@floatFromInt(a));
        self.advance(1);
    }

    // f64 conversions. Truncations guard NaN and range like the f32 variants.
    fn opI32TruncF64S(self: *Instance) !void {
        const a = try self.popF64();
        if (f64IsNan(a) or a < -2147483648.0 or a >= 2147483648.0) return error.InvalidConversion;
        try self.stackPush(@as(i64, @intCast(@as(i32, @intFromFloat(a)))));
        self.advance(1);
    }
    fn opI32TruncF64U(self: *Instance) !void {
        const a = try self.popF64();
        if (f64IsNan(a) or a < 0.0 or a >= 4294967296.0) return error.InvalidConversion;
        const u: u32 = @intFromFloat(a);
        try self.stackPush(@as(i64, @intCast(u)));
        self.advance(1);
    }
    fn opI64TruncF64S(self: *Instance) !void {
        const a = try self.popF64();
        if (f64IsNan(a) or a < -9223372036854775808.0 or a >= 9223372036854775808.0) return error.InvalidConversion;
        try self.stackPush(@as(i64, @intFromFloat(a)));
        self.advance(1);
    }
    fn opI64TruncF64U(self: *Instance) !void {
        const a = try self.popF64();
        if (f64IsNan(a) or a < 0.0 or a >= 18446744073709551616.0) return error.InvalidConversion;
        const u: u64 = @intFromFloat(a);
        try self.stackPush(@as(i64, @intCast(u)));
        self.advance(1);
    }
    fn opF64PromoteF32(self: *Instance) !void {
        const a = try self.popF32();
        try self.pushF64(a); // f32 → f64 is exact and lossless
        self.advance(1);
    }
    fn opF64ReinterpretI64(self: *Instance) !void {
        const a = try self.stackPop();
        try self.pushF64(@bitCast(a));
        self.advance(1);
    }
    fn opI64ReinterpretF64(self: *Instance) !void {
        const a = try self.popF64();
        try self.stackPush(@bitCast(a));
        self.advance(1);
    }

    fn opMemorySize(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        _ = try r.byte(); // reserved 0x00
        self.frames.items[top].pc = r.pos;
        try self.stackPush(@intCast(self.memory.items.len / page_size));
    }

    fn opMemoryGrow(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        _ = try r.byte(); // reserved 0x00
        self.frames.items[top].pc = r.pos;

        // The operand is an i32 pushed sign-extended, so a "negative" value is
        // really a huge unsigned delta. Reinterpret it with `@bitCast`, never a
        // checked `@intCast`: the latter panics on the negative case, which
        // would crash the host on well-formed WASM.
        const delta = @as(u32, @truncate(@as(u64, @bitCast(try self.stackPop()))));
        const old_pages = self.memory.items.len / page_size;
        // Compute in u64 so a huge `delta` cannot wrap `usize` and trap.
        const new_pages = @as(u64, old_pages) + delta;

        // A growth that violates a limit is a normal *result* (-1), not a trap:
        // the spec reduces `memory.grow` to -1 whenever the new size would
        // exceed either the maximum the module declared or the 2^16-page
        // ceiling on linear memory.
        const spec_max_pages: u64 = 65536;
        const limit: u64 = self.module.memory_max orelse spec_max_pages;
        if (new_pages > limit or new_pages > spec_max_pages) {
            try self.stackPush(-1);
            return;
        }

        // A host allocator refusal is an embedder-level condition rather than a
        // WASM-level one, so it stays a visible error instead of hiding behind
        // the spec's -1.
        self.memory.ensureTotalCapacity(self.alloc, @as(usize, new_pages) * page_size) catch return error.MemoryOutOfBounds;
        self.memory.items.len = @as(usize, new_pages) * page_size;
        try self.stackPush(@intCast(old_pages));
    }

    // Bulk-memory proposal (MVP forms): the `0xfc` prefix byte is followed by
    // a sub-opcode byte and a memarg (align LEB + memory-index LEB). The MVP
    // supports a single memory, so the memory-index must be 0 and is validated.
    fn opBulkMemory(self: *Instance) !void {
        const top = self.frames.items.len - 1;
        var r = Reader{ .bytes = self.frames.items[top].body, .pos = self.frames.items[top].pc + 1 };
        const sub = try r.byte(); // sub-opcode: 0x0a = memory.copy, 0x0b = memory.fill
        _ = try r.uleb(); // align (reserved in MVP)
        const mem_idx = try r.uleb(); // memory index (must be 0 in MVP)
        if (mem_idx != 0) return error.InvalidMemoryIndex;
        self.frames.items[top].pc = r.pos;

        switch (sub) {
            0x0a => try self.opMemoryCopy(),
            0x0b => try self.opMemoryFill(),
            else => return error.UnsupportedOpcode,
        }
    }

    // memory.copy: stack is [dest, src, count] with `count` on top. Overlapping
    // regions must copy like `memmove`. Bounds-checked with u64 to avoid
    // usize overflow.
    fn opMemoryCopy(self: *Instance) !void {
        const count_raw = @as(u32, @truncate(@as(u64, @bitCast(try self.stackPop()))));
        const src_raw = @as(u32, @truncate(@as(u64, @bitCast(try self.stackPop()))));
        const dest_raw = @as(u32, @truncate(@as(u64, @bitCast(try self.stackPop()))));
        const memlen: u64 = self.memory.items.len;
        const dest: u64 = dest_raw;
        const src: u64 = src_raw;
        const count: u64 = count_raw;
        if (dest + count > memlen or src + count > memlen) return error.MemoryOutOfBounds;
        const d: usize = @intCast(dest);
        const s: usize = @intCast(src);
        if (d == s) {
            // nothing to do (count may be 0)
        } else if (d < s or d >= s + count) {
            var i: usize = 0;
            while (i < count) : (i += 1) self.memory.items[d + i] = self.memory.items[s + i];
        } else {
            // overlapping with dest after src: copy backward
            var i: usize = count;
            while (i > 0) {
                i -= 1;
                self.memory.items[d + i] = self.memory.items[s + i];
            }
        }
    }

    // memory.fill: stack is [dest, value(i32), count] with `count` on top.
    // Fills `count` bytes at `dest` with the low byte of `value`. Bounds-checked
    // with u64.
    fn opMemoryFill(self: *Instance) !void {
        const count_raw = @as(u32, @truncate(@as(u64, @bitCast(try self.stackPop()))));
        const value_raw = @as(u32, @bitCast(@as(i32, @truncate(try self.stackPop()))));
        const dest_raw = @as(u32, @truncate(@as(u64, @bitCast(try self.stackPop()))));
        const memlen: u64 = self.memory.items.len;
        const dest: u64 = dest_raw;
        const count: u64 = count_raw;
        if (dest + count > memlen) return error.MemoryOutOfBounds;
        const byte: u8 = @truncate(value_raw);
        const d: usize = @intCast(dest);
        var i: usize = 0;
        while (i < count) : (i += 1) self.memory.items[d + i] = byte;
    }

    fn opBinary(self: *Instance, comptime f: fn (i32, i32) ArithError!i64) !void {
        const b = @as(i32, @truncate(try self.stackPop()));
        const a = @as(i32, @truncate(try self.stackPop()));
        try self.stackPush(try f(a, b));
        self.advance(1);
    }

    fn opBinaryCmp(self: *Instance, comptime f: fn (i32, i32) bool) !void {
        const b = @as(i32, @truncate(try self.stackPop()));
        const a = @as(i32, @truncate(try self.stackPop()));
        try self.stackPush(if (f(a, b)) 1 else 0);
        self.advance(1);
    }

    fn opUnary(self: *Instance, comptime f: fn (i32) bool) !void {
        const a = @as(i32, @truncate(try self.stackPop()));
        try self.stackPush(if (f(a)) 1 else 0);
        self.advance(1);
    }

    // i64 variants: the operand stack holds `i64`, so these read/push raw
    // `i64` without the i32 truncation the i32 helpers apply.
    fn opI64Unary(self: *Instance, comptime f: fn (i64) bool) !void {
        const a = try self.stackPop();
        try self.stackPush(if (f(a)) 1 else 0);
        self.advance(1);
    }

    fn opI64BinaryCmp(self: *Instance, comptime f: fn (i64, i64) bool) !void {
        const b = try self.stackPop();
        const a = try self.stackPop();
        try self.stackPush(if (f(a, b)) 1 else 0);
        self.advance(1);
    }

    fn opI64Binary(self: *Instance, comptime f: fn (i64, i64) ArithError!i64) !void {
        const b = try self.stackPop();
        const a = try self.stackPop();
        try self.stackPush(try f(a, b));
        self.advance(1);
    }

    const binopEqlZero = struct {
        fn f(a: i32) bool {
            return a == 0;
        }
    }.f;
    const cmpEq = struct {
        fn f(a: i32, b: i32) bool {
            return a == b;
        }
    }.f;
    const cmpNe = struct {
        fn f(a: i32, b: i32) bool {
            return a != b;
        }
    }.f;
    const cmpLtS = struct {
        fn f(a: i32, b: i32) bool {
            return a < b;
        }
    }.f;
    const cmpLtU = struct {
        fn f(a: i32, b: i32) bool {
            return @as(u32, @bitCast(a)) < @as(u32, @bitCast(b));
        }
    }.f;
    const cmpGtS = struct {
        fn f(a: i32, b: i32) bool {
            return a > b;
        }
    }.f;
    const cmpGtU = struct {
        fn f(a: i32, b: i32) bool {
            return @as(u32, @bitCast(a)) > @as(u32, @bitCast(b));
        }
    }.f;
    const cmpLeS = struct {
        fn f(a: i32, b: i32) bool {
            return a <= b;
        }
    }.f;
    const cmpLeU = struct {
        fn f(a: i32, b: i32) bool {
            return @as(u32, @bitCast(a)) <= @as(u32, @bitCast(b));
        }
    }.f;
    const cmpGeS = struct {
        fn f(a: i32, b: i32) bool {
            return a >= b;
        }
    }.f;
    const cmpGeU = struct {
        fn f(a: i32, b: i32) bool {
            return @as(u32, @bitCast(a)) >= @as(u32, @bitCast(b));
        }
    }.f;

    const arithAdd = struct {
        fn f(a: i32, b: i32) ArithError!i64 {
            return a +% b;
        }
    }.f;
    const arithSub = struct {
        fn f(a: i32, b: i32) ArithError!i64 {
            return a -% b;
        }
    }.f;
    const arithMul = struct {
        fn f(a: i32, b: i32) ArithError!i64 {
            return a *% b;
        }
    }.f;
    const arithDivS = struct {
        fn f(a: i32, b: i32) ArithError!i64 {
            if (b == 0) return error.DivisionByZero;
            return @divTrunc(a, b);
        }
    }.f;
    const arithDivU = struct {
        fn f(a: i32, b: i32) ArithError!i64 {
            const ua: u32 = @bitCast(a);
            const ub: u32 = @bitCast(b);
            if (ub == 0) return error.DivisionByZero;
            return @as(i32, @intCast(@divTrunc(ua, ub)));
        }
    }.f;
    const arithRemS = struct {
        fn f(a: i32, b: i32) ArithError!i64 {
            if (b == 0) return error.DivisionByZero;
            return @rem(a, b);
        }
    }.f;
    const arithRemU = struct {
        fn f(a: i32, b: i32) ArithError!i64 {
            const ua: u32 = @bitCast(a);
            const ub: u32 = @bitCast(b);
            if (ub == 0) return error.DivisionByZero;
            return @as(i32, @intCast(@rem(ua, ub)));
        }
    }.f;
    const arithAnd = struct {
        fn f(a: i32, b: i32) ArithError!i64 {
            return a & b;
        }
    }.f;
    const arithOr = struct {
        fn f(a: i32, b: i32) ArithError!i64 {
            return a | b;
        }
    }.f;
    const arithXor = struct {
        fn f(a: i32, b: i32) ArithError!i64 {
            return a ^ b;
        }
    }.f;
    const arithShl = struct {
        fn f(a: i32, b: i32) ArithError!i64 {
            return @intCast(@as(u32, @bitCast(a)) << @as(u5, @truncate(@as(u32, @bitCast(b)))));
        }
    }.f;
    const arithShrS = struct {
        fn f(a: i32, b: i32) ArithError!i64 {
            return a >> @as(u5, @truncate(@as(u32, @bitCast(b))));
        }
    }.f;
    const arithShrU = struct {
        fn f(a: i32, b: i32) ArithError!i64 {
            const ua: u32 = @bitCast(a);
            const sh: u5 = @truncate(@as(u32, @bitCast(b)));
            return @as(i32, @intCast(ua >> sh));
        }
    }.f;

    // ── i64 operators (raw i64, no truncation) ──
    const i64EqlZero = struct {
        fn f(a: i64) bool {
            return a == 0;
        }
    }.f;
    const i64Eq = struct {
        fn f(a: i64, b: i64) bool {
            return a == b;
        }
    }.f;
    const i64Ne = struct {
        fn f(a: i64, b: i64) bool {
            return a != b;
        }
    }.f;
    const i64LtS = struct {
        fn f(a: i64, b: i64) bool {
            return a < b;
        }
    }.f;
    const i64LtU = struct {
        fn f(a: i64, b: i64) bool {
            return @as(u64, @bitCast(a)) < @as(u64, @bitCast(b));
        }
    }.f;
    const i64GtS = struct {
        fn f(a: i64, b: i64) bool {
            return a > b;
        }
    }.f;
    const i64GtU = struct {
        fn f(a: i64, b: i64) bool {
            return @as(u64, @bitCast(a)) > @as(u64, @bitCast(b));
        }
    }.f;
    const i64LeS = struct {
        fn f(a: i64, b: i64) bool {
            return a <= b;
        }
    }.f;
    const i64LeU = struct {
        fn f(a: i64, b: i64) bool {
            return @as(u64, @bitCast(a)) <= @as(u64, @bitCast(b));
        }
    }.f;
    const i64GeS = struct {
        fn f(a: i64, b: i64) bool {
            return a >= b;
        }
    }.f;
    const i64GeU = struct {
        fn f(a: i64, b: i64) bool {
            return @as(u64, @bitCast(a)) >= @as(u64, @bitCast(b));
        }
    }.f;
    const i64Add = struct {
        fn f(a: i64, b: i64) ArithError!i64 {
            return a +% b;
        }
    }.f;
    const i64Sub = struct {
        fn f(a: i64, b: i64) ArithError!i64 {
            return a -% b;
        }
    }.f;
    const i64Mul = struct {
        fn f(a: i64, b: i64) ArithError!i64 {
            return a *% b;
        }
    }.f;
    const i64DivS = struct {
        fn f(a: i64, b: i64) ArithError!i64 {
            if (b == 0) return error.DivisionByZero;
            return @divTrunc(a, b);
        }
    }.f;
    const i64DivU = struct {
        fn f(a: i64, b: i64) ArithError!i64 {
            const ua: u64 = @bitCast(a);
            const ub: u64 = @bitCast(b);
            if (ub == 0) return error.DivisionByZero;
            return @as(i64, @bitCast(@divTrunc(ua, ub)));
        }
    }.f;
    const i64RemS = struct {
        fn f(a: i64, b: i64) ArithError!i64 {
            if (b == 0) return error.DivisionByZero;
            return @rem(a, b);
        }
    }.f;
    const i64RemU = struct {
        fn f(a: i64, b: i64) ArithError!i64 {
            const ua: u64 = @bitCast(a);
            const ub: u64 = @bitCast(b);
            if (ub == 0) return error.DivisionByZero;
            return @as(i64, @bitCast(@rem(ua, ub)));
        }
    }.f;
    const i64And = struct {
        fn f(a: i64, b: i64) ArithError!i64 {
            return a & b;
        }
    }.f;
    const i64Or = struct {
        fn f(a: i64, b: i64) ArithError!i64 {
            return a | b;
        }
    }.f;
    const i64Xor = struct {
        fn f(a: i64, b: i64) ArithError!i64 {
            return a ^ b;
        }
    }.f;
    const i64Shl = struct {
        fn f(a: i64, b: i64) ArithError!i64 {
            return a << @as(u6, @truncate(@as(u64, @bitCast(b))));
        }
    }.f;
    const i64ShrS = struct {
        fn f(a: i64, b: i64) ArithError!i64 {
            return a >> @as(u6, @truncate(@as(u64, @bitCast(b))));
        }
    }.f;
    const i64ShrU = struct {
        fn f(a: i64, b: i64) ArithError!i64 {
            const ua: u64 = @bitCast(a);
            const sh: u6 = @truncate(@as(u64, @bitCast(b)));
            return @as(i64, @bitCast(ua >> sh));
        }
    }.f;

    // ── f32 operators (stored on the i64 operand stack as the low 32 bits,
    //    i.e. the IEEE-754 bit pattern zero-extended into i64 — same layout
    //    as i32 values) ──
    const f32Abs = struct {
        fn f(a: f32) f32 {
            return if (a < 0) -a else a;
        }
    }.f;
    const f32Neg = struct {
        fn f(a: f32) f32 {
            return -a;
        }
    }.f;
    const f32Sqrt = struct {
        fn f(a: f32) f32 {
            return @sqrt(a);
        }
    }.f;
    const f32Ceil = struct {
        fn f(a: f32) f32 {
            return @ceil(a);
        }
    }.f;
    const f32Floor = struct {
        fn f(a: f32) f32 {
            return @floor(a);
        }
    }.f;
    const f32Trunc = struct {
        fn f(a: f32) f32 {
            return @trunc(a);
        }
    }.f;
    const f32Nearest = struct {
        fn f(a: f32) f32 {
            return @round(a);
        }
    }.f;
    const f32Add = struct {
        fn f(a: f32, b: f32) f32 {
            return a + b;
        }
    }.f;
    const f32Sub = struct {
        fn f(a: f32, b: f32) f32 {
            return a - b;
        }
    }.f;
    const f32Mul = struct {
        fn f(a: f32, b: f32) f32 {
            return a * b;
        }
    }.f;
    const f32Div = struct {
        fn f(a: f32, b: f32) f32 {
            return a / b;
        }
    }.f;
    const f32Min = struct {
        fn f(a: f32, b: f32) f32 {
            return @min(a, b);
        }
    }.f;
    const f32Max = struct {
        fn f(a: f32, b: f32) f32 {
            return @max(a, b);
        }
    }.f;
    const f32Copysign = struct {
        fn f(a: f32, b: f32) f32 {
            const a_bits: u32 = @bitCast(a);
            const b_bits: u32 = @bitCast(b);
            const sign: u32 = b_bits & 0x80000000;
            return @bitCast((a_bits & 0x7FFFFFFF) | sign);
        }
    }.f;
    const f32Eq = struct {
        fn f(a: f32, b: f32) bool {
            return a == b;
        }
    }.f;
    const f32Ne = struct {
        fn f(a: f32, b: f32) bool {
            return a != b;
        }
    }.f;
    const f32Lt = struct {
        fn f(a: f32, b: f32) bool {
            return a < b;
        }
    }.f;
    const f32Gt = struct {
        fn f(a: f32, b: f32) bool {
            return a > b;
        }
    }.f;
    const f32Le = struct {
        fn f(a: f32, b: f32) bool {
            return a <= b;
        }
    }.f;
    const f32Ge = struct {
        fn f(a: f32, b: f32) bool {
            return a >= b;
        }
    }.f;

    // f64 helpers (mirror the f32 ones; operate on 64-bit IEEE-754 values).
    const f64Abs = struct {
        fn f(a: f64) f64 {
            return if (a < 0) -a else a;
        }
    }.f;
    const f64Neg = struct {
        fn f(a: f64) f64 {
            return -a;
        }
    }.f;
    const f64Sqrt = struct {
        fn f(a: f64) f64 {
            return @sqrt(a);
        }
    }.f;
    const f64Ceil = struct {
        fn f(a: f64) f64 {
            return @ceil(a);
        }
    }.f;
    const f64Floor = struct {
        fn f(a: f64) f64 {
            return @floor(a);
        }
    }.f;
    const f64Trunc = struct {
        fn f(a: f64) f64 {
            return @trunc(a);
        }
    }.f;
    const f64Nearest = struct {
        fn f(a: f64) f64 {
            return @round(a);
        }
    }.f;
    const f64Add = struct {
        fn f(a: f64, b: f64) f64 {
            return a + b;
        }
    }.f;
    const f64Sub = struct {
        fn f(a: f64, b: f64) f64 {
            return a - b;
        }
    }.f;
    const f64Mul = struct {
        fn f(a: f64, b: f64) f64 {
            return a * b;
        }
    }.f;
    const f64Div = struct {
        fn f(a: f64, b: f64) f64 {
            return a / b;
        }
    }.f;
    const f64Min = struct {
        fn f(a: f64, b: f64) f64 {
            return @min(a, b);
        }
    }.f;
    const f64Max = struct {
        fn f(a: f64, b: f64) f64 {
            return @max(a, b);
        }
    }.f;
    const f64Copysign = struct {
        fn f(a: f64, b: f64) f64 {
            const a_bits: u64 = @bitCast(a);
            const b_bits: u64 = @bitCast(b);
            const sign: u64 = b_bits & 0x8000000000000000;
            return @bitCast((a_bits & 0x7FFFFFFFFFFFFFFF) | sign);
        }
    }.f;
    const f64Eq = struct {
        fn f(a: f64, b: f64) bool {
            return a == b;
        }
    }.f;
    const f64Ne = struct {
        fn f(a: f64, b: f64) bool {
            return a != b;
        }
    }.f;
    const f64Lt = struct {
        fn f(a: f64, b: f64) bool {
            return a < b;
        }
    }.f;
    const f64Gt = struct {
        fn f(a: f64, b: f64) bool {
            return a > b;
        }
    }.f;
    const f64Le = struct {
        fn f(a: f64, b: f64) bool {
            return a <= b;
        }
    }.f;
    const f64Ge = struct {
        fn f(a: f64, b: f64) bool {
            return a >= b;
        }
    }.f;
};

/// Read a blocktype from `r` and return its result arity (0 or 1).
///
/// In the MVP the blocktype is a single byte: `0x40` (empty → 0) or a value
/// type `0x7f` (i32) / `0x7e` (i64) → 1. A multi-byte s33 (high bit set on the
/// first byte — used for multi-value / type-index encodings) is consumed and
/// rejected, keeping the single-result invariant that holds elsewhere.
/// NOTE: we read the raw byte rather than `sleb`, because the WASM s33 space
/// treats `0x40` as the positive value 64 ("empty"), not -64 as plain sleb128
/// would decode it.
fn readBlockArity(r: *Reader) !u32 {
    const first = try r.byte();
    if (first & 0x80 != 0) {
        // Multi-byte s33: consume the remaining continuation bytes, then reject.
        var b = first;
        while (b & 0x80 != 0) b = try r.byte();
        return error.BlockResultUnsupported;
    }
    return switch (first) {
        0x40 => 0, // empty
        0x7f, 0x7e => 1, // i32, i64
        else => error.BlockResultUnsupported,
    };
}

// ── Block scanning (used by if/else and the skip helpers) ───────────────
/// Length of the immediate following the opcode at `pc`, or `null` if the
/// opcode is unknown or its immediate would read past the end of `body`
/// (a malformed-module signal the skip helpers turn into `MalformedBlocks`).
fn immediateLen(body: []const u8, pc: usize) ?usize {
    if (pc >= body.len) return null;
    const op = body[pc];
    return switch (op) {
        0x01, 0x05, 0x0b, 0x0f, 0x1a, 0x1b => 0, // nop, else, end, return, drop, select
        0x43 => 4, // f32.const: 4 raw IEEE-754 bytes
        0x44 => 8, // f64.const: 8 raw IEEE-754 bytes
        0x45...0x66, 0x6a...0xa6 => 0, // i32 + i64 + f32 + f64 comparisons and arithmetic
        0x67...0x69, 0xa7...0xc3 => 0, // i32 clz/ctz/popcnt + numeric conversions + extends
        0x02, 0x03, 0x04 => 1, // block/loop/if: blocktype byte
        0x0c,
        0x0d,
        0x10, // br, br_if, call
        0x20...0x24, // local/global get/set/tee
        => lebLen(body, pc + 1),
        0x0e => brTableLen(body, pc + 1), // br_table: count + targets + default
        0x11 => blk: { // call_indirect: type_idx LEB + table_idx LEB
            const a = lebLen(body, pc + 1) orelse break :blk null;
            const b = lebLen(body, pc + 1 + a) orelse break :blk null;
            break :blk a + b;
        },
        0x28...0x3e => blk: {
            const a = lebLen(body, pc + 1) orelse break :blk null;
            const b = lebLen(body, pc + 1 + a) orelse break :blk null;
            break :blk a + b;
        }, // memarg
        0x3f, 0x40 => 1, // memory.size/grow reserved byte
        0x41, 0x42 => slebLen(body, pc + 1),
        0xfc => blk: { // bulk-memory prefix: sub-opcode + memarg (align + memidx LEBs)
            const sub_pos = pc + 1;
            if (sub_pos >= body.len) break :blk null;
            const a = lebLen(body, sub_pos + 1) orelse break :blk null; // align LEB
            const b = lebLen(body, sub_pos + 1 + a) orelse break :blk null; // memidx LEB
            break :blk 1 + a + b;
        },
        else => null,
    };
}

fn lebLen(bytes: []const u8, start: usize) ?usize {
    if (start >= bytes.len) return null;
    var i = start;
    while (i < bytes.len and bytes[i] & 0x80 != 0) : (i += 1) {}
    if (i >= bytes.len) return null; // ran off the end without a terminator
    return i - start + 1;
}

/// Length of a `br_table` immediate: `count` (LEB), then `count` target LEBs,
/// then one default LEB. Returns `null` if any LEB runs off the end of `body`.
fn brTableLen(bytes: []const u8, start: usize) ?usize {
    var pos = start;
    // Decode the `count` LEB into a value while advancing over it.
    var count: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (pos >= bytes.len) return null;
        const b = bytes[pos];
        if (shift == 28 and (b & 0x70) != 0) return null; // overlong / overflow
        count |= @as(u32, b & 0x7f) << shift;
        pos += 1;
        if (b & 0x80 == 0) break;
        shift +%= 7;
    }
    // Skip `count` target labels plus the single default label that follows.
    var i: u32 = 0;
    while (i <= count) : (i += 1) {
        const ln = lebLen(bytes, pos) orelse return null;
        pos += ln;
    }
    return pos - start;
}

fn slebLen(bytes: []const u8, start: usize) ?usize {
    if (start >= bytes.len) return null;
    var i = start;
    while (i < bytes.len) {
        const b = bytes[i];
        i += 1;
        if (b & 0x80 == 0) break;
    } else return null; // loop finished without a terminator byte
    return i - start;
}

/// Scan `body` from `pc` for the `else`/`end` matching the enclosing `if`.
/// Returns the offset of the first `else` at depth 0, else the matching `end`.
fn skipToElseOrEnd(body: []const u8, pc: usize) ?usize {
    var depth: usize = 0;
    var i = pc;
    while (i < body.len) {
        const op = body[i];
        if (op == 0x02 or op == 0x03 or op == 0x04) {
            depth += 1;
            i += 2; // opcode + blocktype
        } else if (op == 0x05) {
            if (depth == 0) return i;
            i += 1;
        } else if (op == 0x0b) {
            if (depth == 0) return i;
            depth -= 1;
            i += 1;
        } else {
            const len = immediateLen(body, i) orelse return null;
            i += 1 + len;
        }
    }
    return null;
}

/// Scan `body` from `pc` for the `end` matching the enclosing block.
fn skipToEnd(body: []const u8, pc: usize) ?usize {
    var depth: usize = 0;
    var i = pc;
    while (i < body.len) {
        const op = body[i];
        if (op == 0x02 or op == 0x03 or op == 0x04) {
            depth += 1;
            i += 2; // opcode + blocktype
        } else if (op == 0x0b) {
            if (depth == 0) return i;
            depth -= 1;
            i += 1;
        } else {
            const len = immediateLen(body, i) orelse return null;
            i += 1 + len;
        }
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────
const testing = std.testing;

pub const FuncTypeSpec = struct { params: []const u8, returns: []const u8 };
pub const ImportSpec = struct { module: []const u8, name: []const u8, type_idx: u32 };

/// A `global` import spec for `Builder.imports`.
pub const GlobalImportSpec = struct { module: []const u8, name: []const u8, valtype: u8, mutable: bool = false };

/// A defined `global` spec for `Builder.globals`. The init expression is a
/// compile-time constant; only i32/i64 constants are supported in this subset.
pub const GlobalSpec = struct { valtype: u8, mutable: bool = false, init: i64 };
pub const ExportSpec = struct { name: []const u8, index: u32 };

/// A tiny allocating builder that assembles a wasm binary for tests.
pub const Builder = struct {
    alloc: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    /// Sections are recorded here and `buf` is rebuilt from them in ascending id
    /// order, so callers may emit sections in any order and still get a module
    /// the WASM binary format accepts. Appending in call order silently produced
    /// out-of-spec modules — a start section after code, say — which the parser
    /// here tolerates but which then mis-instantiates for reasons that have
    /// nothing to do with the payload under test.
    sections: std.ArrayListUnmanaged(Section) = .empty,
    /// Bytes written before the first section: the magic + version header.
    prefix_len: usize = 0,

    const Section = struct { id: u8, bytes: []u8 };

    pub fn deinit(self: *Builder) void {
        for (self.sections.items) |s| self.alloc.free(s.bytes);
        self.sections.deinit(self.alloc);
        self.buf.deinit(self.alloc);
    }

    pub fn emitByte(self: *Builder, b: u8) !void {
        try self.buf.append(self.alloc, b);
    }

    pub fn raw(self: *Builder, b: []const u8) !void {
        try self.buf.appendSlice(self.alloc, b);
    }

    pub fn uleb(self: *Builder, v: u32) !void {
        var n = v;
        while (true) {
            var b: u8 = @truncate(n & 0x7f);
            n >>= 7;
            if (n != 0) b |= 0x80;
            try self.emitByte(b);
            if (n == 0) break;
        }
    }

    /// Emit a signed LEB128 integer (used by `i32.const`/`i64.const`).
    pub fn sleb(self: *Builder, v: anytype) !void {
        // Work in a signed 64-bit register so the arithmetic-shift sign
        // extension behaves correctly regardless of the input width.
        var n: i64 = @intCast(v);
        while (true) {
            const byte = @as(u8, @truncate(@as(u64, @bitCast(n))));
            const low7 = byte & 0x7f;
            n >>= 7;
            // Done when the remaining bits are all 0 (positive) or all 1
            // (negative), i.e. the sign bit of `n` matches what `low7` already
            // carries.
            if ((n == 0 and (low7 & 0x40) == 0) or (n == -1 and (low7 & 0x40) != 0)) {
                try self.emitByte(@as(u8, low7));
                break;
            }
            try self.emitByte(low7 | 0x80);
        }
    }

    pub fn op(self: *Builder, code_byte: u8) !void {
        try self.emitByte(code_byte);
    }

    pub fn i32Const(self: *Builder, v: i32) !void {
        try self.emitByte(0x41);
        try self.sleb(v);
    }

    pub fn i64Const(self: *Builder, v: i64) !void {
        try self.emitByte(0x42);
        try self.sleb(v);
    }

    /// Emit `f32.const` from its raw IEEE-754 bit pattern (little-endian).
    pub fn f32ConstBits(self: *Builder, bits: u32) !void {
        try self.emitByte(0x43);
        var i: usize = 0;
        while (i < 4) : (i += 1) try self.emitByte(@truncate(bits >> @intCast(8 * i)));
    }

    /// Emit `i32.const` from its raw bit pattern (e.g. to load float bits).
    pub fn i32ConstBits(self: *Builder, bits: u32) !void {
        try self.emitByte(0x41);
        try self.sleb(@as(i32, @bitCast(bits)));
    }

    pub fn f32Const(self: *Builder, v: f32) !void {
        try self.f32ConstBits(@bitCast(v));
    }

    /// Emit `f64.const` from its raw IEEE-754 bit pattern (little-endian, 8 bytes).
    pub fn f64ConstBits(self: *Builder, bits: u64) !void {
        try self.emitByte(0x44);
        var i: usize = 0;
        while (i < 8) : (i += 1) try self.emitByte(@truncate(bits >> @intCast(8 * i)));
    }

    pub fn f64Const(self: *Builder, v: f64) !void {
        try self.f64ConstBits(@bitCast(v));
    }

    pub fn name(self: *Builder, s: []const u8) !void {
        try self.uleb(@intCast(s.len));
        try self.raw(s);
    }

    /// Add a section to the module. Sections are kept sorted by id no matter what
    /// order callers add them in, because the WASM binary format requires ids to
    /// ascend (type 1, import 2, function 3, table 4, memory 5, global 6,
    /// export 7, start 8, element 9, code 10, data 11).
    pub fn section(self: *Builder, id: u8, payload: []const u8) !void {
        if (self.sections.items.len == 0) self.prefix_len = self.buf.items.len;

        var bytes: std.ArrayListUnmanaged(u8) = .empty;
        errdefer bytes.deinit(self.alloc);
        try bytes.append(self.alloc, id);
        var size: usize = payload.len;
        while (true) {
            const b: u8 = @truncate(size & 0x7f);
            size >>= 7;
            try bytes.append(self.alloc, if (size != 0) b | 0x80 else b);
            if (size == 0) break;
        }
        try bytes.appendSlice(self.alloc, payload);

        const owned = try bytes.toOwnedSlice(self.alloc);
        var at: usize = 0;
        while (at < self.sections.items.len and self.sections.items[at].id <= id) : (at += 1) {}
        self.sections.insert(self.alloc, at, .{ .id = id, .bytes = owned }) catch |e| {
            self.alloc.free(owned);
            return e;
        };

        self.buf.shrinkRetainingCapacity(self.prefix_len);
        for (self.sections.items) |s| try self.buf.appendSlice(self.alloc, s.bytes);
    }

    pub fn types(self: *Builder, ts: []const FuncTypeSpec) !void {
        var p = Builder{ .alloc = self.alloc };
        defer p.deinit();
        try p.uleb(@intCast(ts.len));
        for (ts) |t| {
            try p.emitByte(0x60);
            try p.uleb(@intCast(t.params.len));
            try p.raw(t.params);
            try p.uleb(@intCast(t.returns.len));
            try p.raw(t.returns);
        }
        try self.section(1, p.buf.items);
    }

    pub fn imports(self: *Builder, imps: []const ImportSpec, gimps: []const GlobalImportSpec) !void {
        var p = Builder{ .alloc = self.alloc };
        defer p.deinit();
        try p.uleb(@intCast(imps.len + gimps.len));
        for (imps) |imp| {
            try p.name(imp.module);
            try p.name(imp.name);
            try p.emitByte(0x00); // kind: function
            try p.uleb(imp.type_idx);
        }
        for (gimps) |g| {
            try p.name(g.module);
            try p.name(g.name);
            try p.emitByte(0x03); // kind: global
            try p.emitByte(g.valtype);
            try p.emitByte(if (g.mutable) @as(u8, 1) else 0);
        }
        try self.section(2, p.buf.items);
    }

    /// Defined `global` section (id 6). Each global is a constant init expr
    /// (an i32/i64 const followed by `end`) plus a mutability flag.
    pub fn globals(self: *Builder, gs: []const GlobalSpec) !void {
        var p = Builder{ .alloc = self.alloc };
        defer p.deinit();
        try p.uleb(@intCast(gs.len));
        for (gs) |g| {
            try p.emitByte(g.valtype);
            try p.emitByte(if (g.mutable) @as(u8, 1) else 0);
            if (g.valtype == 0x7e) {
                try p.i64Const(g.init); // i64.const
            } else {
                try p.i32Const(@intCast(g.init)); // i32.const (truncates to i32)
            }
            try p.emitByte(0x0b); // end of init expr
        }
        try self.section(6, p.buf.items);
    }

    pub fn functions(self: *Builder, type_indices: []const u32) !void {
        var p = Builder{ .alloc = self.alloc };
        defer p.deinit();
        try p.uleb(@intCast(type_indices.len));
        for (type_indices) |t| try p.uleb(t);
        try self.section(3, p.buf.items);
    }

    pub fn memory(self: *Builder, min_pages: u32) !void {
        var p = Builder{ .alloc = self.alloc };
        defer p.deinit();
        try p.uleb(1);
        try p.emitByte(0);
        try p.uleb(min_pages);
        try self.section(5, p.buf.items);
    }

    /// Declare linear memory with an explicit `max` (limits flags `0x01`), which
    /// the interpreter enforces as a hard cap on `memory.grow`.
    pub fn memoryWithMax(self: *Builder, min_pages: u32, max_pages: u32) !void {
        var p = Builder{ .alloc = self.alloc };
        defer p.deinit();
        try p.uleb(1);
        try p.emitByte(0x01); // flags: min and max present
        try p.uleb(min_pages);
        try p.uleb(max_pages);
        try self.section(5, p.buf.items);
    }

    /// A defined table: `min` elements, optional `max`. `funcref` element type
    /// (0x70) is implied — the only type the interpreter accepts.
    pub const TableSpec = struct { min: u32, max: ?u32 = null };

    pub fn tables(self: *Builder, ts: []const TableSpec) !void {
        var p = Builder{ .alloc = self.alloc };
        defer p.deinit();
        try p.uleb(@intCast(ts.len));
        for (ts) |t| {
            try p.emitByte(0x70); // elemtype: funcref
            if (t.max) |max| {
                try p.emitByte(0x01); // flags: max present
                try p.uleb(t.min);
                try p.uleb(max);
            } else {
                try p.emitByte(0x00); // flags: no max
                try p.uleb(t.min);
            }
        }
        try self.section(4, p.buf.items);
    }

    pub fn exports(self: *Builder, exps: []const ExportSpec) !void {
        var p = Builder{ .alloc = self.alloc };
        defer p.deinit();
        try p.uleb(@intCast(exps.len));
        for (exps) |e| {
            try p.name(e.name);
            try p.emitByte(0x00); // kind: function
            try p.uleb(e.index);
        }
        try self.section(7, p.buf.items);
    }

    /// `start` section: a single function index run automatically at
    /// instantiation. The referenced function must have type `[] -> []`.
    pub fn start(self: *Builder, func_idx: u32) !void {
        var p = Builder{ .alloc = self.alloc };
        defer p.deinit();
        try p.uleb(func_idx);
        try self.section(8, p.buf.items);
    }

    pub fn code(self: *Builder, bodies: []const []const u8) !void {
        var p = Builder{ .alloc = self.alloc };
        defer p.deinit();
        try p.uleb(@intCast(bodies.len));
        for (bodies) |b| {
            try p.uleb(@intCast(b.len));
            try p.raw(b);
        }
        try self.section(10, p.buf.items);
    }

    pub const DataSeg = struct { offset: u32, bytes: []const u8 };

    /// Active data segments at memory index 0, each with an `i32.const`
    /// offset expression (offsets must fit a positive LEB).
    pub fn data(self: *Builder, segments: []const DataSeg) !void {
        var p = Builder{ .alloc = self.alloc };
        defer p.deinit();
        try p.uleb(@intCast(segments.len));
        for (segments) |seg| {
            try p.emitByte(0x00); // active, memory index 0
            try p.emitByte(0x41); // i32.const
            try p.uleb(seg.offset);
            try p.emitByte(0x0b); // end
            try p.uleb(@intCast(seg.bytes.len));
            try p.raw(seg.bytes);
        }
        try self.section(11, p.buf.items);
    }

    pub const ElementSeg = struct { offset: u32, func_indices: []const u32 };

    /// Active element segments targeting table 0 (classic MVP encoding: an
    /// `i32.const` offset expression, then `count`, then `count` function
    /// indices). Offsets must be non-negative and fit a positive LEB.
    pub fn elements(self: *Builder, segments: []const ElementSeg) !void {
        var p = Builder{ .alloc = self.alloc };
        defer p.deinit();
        try p.uleb(@intCast(segments.len));
        for (segments) |seg| {
            try p.emitByte(0x41); // i32.const (offset init expr)
            try p.uleb(seg.offset);
            try p.emitByte(0x0b); // end
            try p.uleb(@intCast(seg.func_indices.len));
            for (seg.func_indices) |idx| try p.uleb(idx);
        }
        try self.section(9, p.buf.items);
    }
};

test "module magic/version validation" {
    try testing.expectError(error.BadMagic, Module.load(testing.allocator, &.{ 0, 0, 0, 0 }));
    try testing.expectError(error.BadVersion, Module.load(testing.allocator, &.{ 0, 0x61, 0x73, 0x6d, 2, 0, 0, 0 }));
}

test "host import call and i32 arithmetic" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{
        .{ .params = &.{ 0x7f, 0x7f }, .returns = &.{} }, // 0: (i32,i32)->()
        .{ .params = &.{0x7f}, .returns = &.{0x7f} }, // 1: (i32)->(i32)
        .{ .params = &.{}, .returns = &.{} }, // 2: ()->()
    });
    try b.imports(&.{.{ .module = "cordis", .name = "host_log", .type_idx = 0 }}, &.{});
    try b.functions(&.{ 2, 1 }); // f0=add, f1=compute
    try b.exports(&.{ .{ .name = "add", .index = 1 }, .{ .name = "compute", .index = 2 } });
    // add: i32.const 20, i32.const 22, call 0, drop, end
    const add_body = [_]u8{ 0x00, 0x41, 0x14, 0x41, 0x16, 0x10, 0x00, 0x0b };
    // compute(n) = n * 2 + 1; 1 local decl (1 i32)
    const compute_body = [_]u8{ 0x01, 0x01, 0x7f, 0x20, 0x00, 0x41, 0x02, 0x6c, 0x41, 0x01, 0x6a, 0x0b };
    try b.code(&.{ &add_body, &compute_body });

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();

    var host_val: i32 = 0;
    const Host = struct {
        val: *i32,
        fn log(inst: *Instance, args: []const i64) i64 {
            const self: *@This() = @ptrCast(@alignCast(inst.host_ctx.?));
            self.val.* = @intCast(args[0] + args[1]);
            return 0;
        }
    };
    var host = Host{ .val = &host_val };
    const hf: []const HostFn = &.{Host.log};
    const hg: []const HostGlobal = &.{};
    var inst = try Instance.create(testing.allocator, &module, &host, hf, hg);
    defer inst.deinit();

    _ = try inst.callExport("add", &.{});
    try testing.expectEqual(@as(i32, 42), host_val);

    try testing.expectEqual(@as(i64, 41), try inst.callExport("compute", &.{20}));
    try testing.expectEqual(@as(i64, -1), try inst.callExport("compute", &.{-1}));
}

test "select picks val1 when cond != 0 and val2 when cond == 0" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    // pick(cond, val1, val2) -> i32: pushes val2, val1, cond, then select.
    // Stack pop order in opSelect is (c, val2, val1), so we push val2 first,
    // then val1, then cond so the top is the condition.
    try b.types(&.{
        .{ .params = &.{ 0x7f, 0x7f, 0x7f }, .returns = &.{0x7f} },
    });
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "pick", .index = 0 }});
    var v = Builder{ .alloc = testing.allocator };
    defer v.deinit();
    try v.emitByte(0x00); // 0 locals
    try v.emitByte(0x20);
    try v.uleb(2); // local.get 2 -> val2
    try v.emitByte(0x20);
    try v.uleb(1); // local.get 1 -> val1
    try v.emitByte(0x20);
    try v.uleb(0); // local.get 0 -> cond
    try v.op(0x1b); // select
    try v.op(0x0b); // end
    try b.code(&.{v.buf.items});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();

    // cond=true -> val1 (param 1); cond=false -> val2 (param 2)
    try testing.expectEqual(@as(i64, 111), try inst.callExport("pick", &.{ 1, 111, 222 }));
    try testing.expectEqual(@as(i64, 222), try inst.callExport("pick", &.{ 0, 111, 222 }));
    // select is type-agnostic: even f32 bit patterns pass through unchanged
    try testing.expectEqual(@as(i64, 0x53900000), try inst.callExport("pick", &.{ 1, 0x53900000, 0 }));
}

test "stack underflow: select with missing operand" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{
        .{ .params = &.{0x7f}, .returns = &.{} },
    });
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "sel", .index = 0 }});
    var v = Builder{ .alloc = testing.allocator };
    defer v.deinit();
    try v.emitByte(0x00);
    try v.i32Const(1); // only the cond on stack
    try v.op(0x1b); // select -> underflow
    try v.op(0x0b);
    try b.code(&.{v.buf.items});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.StackUnderflow, inst.callExport("sel", &.{0}));
}

test "if/else with locals" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{0x7f}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "sign", .index = 0 }});
    // sign(n): local[0]=n, local[1]=result; if n>0 {1} else {-1}; return local[1]
    const body = [_]u8{
        0x01, 0x02, 0x7f, // 1 decl: 2 x i32
        0x20, 0x00, // local.get 0
        0x41, 0x00, // i32.const 0
        0x4a, // i32.gt_s
        0x04, 0x40, // if (empty)
        0x41, 0x01, // i32.const 1
        0x21, 0x01, // local.set 1
        0x05, // else
        0x41, 0x7f, // i32.const -1
        0x21, 0x01, // local.set 1
        0x0b, // end
        0x20, 0x01, // local.get 1
        0x0b, // end (function)
    };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();

    try testing.expectEqual(@as(i64, 1), try inst.callExport("sign", &.{5}));
    try testing.expectEqual(@as(i64, -1), try inst.callExport("sign", &.{-3}));
    try testing.expectEqual(@as(i64, -1), try inst.callExport("sign", &.{0}));
}

test "linear memory store/load round-trip" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{
        .{ .params = &.{ 0x7f, 0x7f }, .returns = &.{} }, // 0: store(addr, val)
        .{ .params = &.{0x7f}, .returns = &.{0x7f} }, // 1: load(addr)
    });
    try b.functions(&.{ 0, 1 });
    try b.memory(1);
    try b.exports(&.{ .{ .name = "store", .index = 0 }, .{ .name = "load", .index = 1 } });
    // store: local.get 0, local.get 1, i32.store align=2 offset=0
    const store_body = [_]u8{ 0x00, 0x20, 0x00, 0x20, 0x01, 0x36, 0x02, 0x00, 0x0b };
    // load: local.get 0, i32.load align=2 offset=0
    const load_body = [_]u8{ 0x00, 0x20, 0x00, 0x28, 0x02, 0x00, 0x0b };
    try b.code(&.{ &store_body, &load_body });

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();

    _ = try inst.callExport("store", &.{ 4, 1234 });
    try testing.expectEqual(@as(i64, 1234), try inst.callExport("load", &.{4}));
}

// ── Edge cases: malformed input and trap conditions ──────────────────────

test "stack underflow: drop on empty stack" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    const body = [_]u8{ 0x00, 0x1a, 0x0b }; // (0 locals) drop, end
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.StackUnderflow, inst.callExport("run", &.{}));
}

test "stack underflow: binary op with one operand" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // i32.const 7, i32.add, end  (add needs 2 operands, only 1 present)
    const body = [_]u8{ 0x00, 0x41, 0x07, 0x6a, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.StackUnderflow, inst.callExport("run", &.{}));
}

test "unreachable opcode traps" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "boom", .index = 0 }});
    const body = [_]u8{ 0x00, 0x00, 0x0b }; // (0 locals) unreachable, end
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.Trap, inst.callExport("boom", &.{}));
}

test "division by zero traps" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // i32.const 10, i32.const 0, i32.div_s, drop, end
    const body = [_]u8{ 0x00, 0x41, 0x0a, 0x41, 0x00, 0x6d, 0x1a, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.DivisionByZero, inst.callExport("run", &.{}));
}

test "remainder by zero traps" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // i32.const 10, i32.const 0, i32.rem_s, drop, end
    const body = [_]u8{ 0x00, 0x41, 0x0a, 0x41, 0x00, 0x6f, 0x1a, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.DivisionByZero, inst.callExport("run", &.{}));
}

test "memory load out of bounds" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.memory(1); // 1 page = 65536 bytes
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // i32.const (65536-1)=65535, i32.load (needs 4 bytes), drop, end
    const body = [_]u8{ 0x00, 0x41, 0xff, 0xff, 0x03, 0x28, 0x02, 0x00, 0x1a, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.MemoryOutOfBounds, inst.callExport("run", &.{}));
}

test "memory store out of bounds" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.memory(1);
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // i32.const 65536, i32.const 1, i32.store, end  (addr 65536 + 4 > 65536)
    const body = [_]u8{ 0x00, 0x41, 0x80, 0x80, 0x04, 0x41, 0x01, 0x36, 0x02, 0x00, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.MemoryOutOfBounds, inst.callExport("run", &.{}));
}

test "memory.grow beyond the page ceiling returns -1" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }}); // () -> i32
    try b.functions(&.{0});
    try b.memory(1);
    try b.exports(&.{.{ .name = "grow", .index = 0 }});
    // i32.const <delta>, memory.grow, end — a delta far past the 2^16-page
    // ceiling on linear memory.
    const body = [_]u8{ 0x00, 0x41, 0xb0, 0x82, 0x04, 0x40, 0x00, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    // A failed growth is a result, not a trap.
    try testing.expectEqual(@as(i64, -1), try inst.callExport("grow", &.{}));
    try testing.expectEqual(@as(usize, page_size), inst.memory.items.len);
}

test "memory.grow honours the module's declared maximum" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }}); // () -> i32
    try b.functions(&.{0});
    try b.memoryWithMax(1, 2); // (memory 1 2)
    try b.exports(&.{.{ .name = "grow", .index = 0 }});
    // i32.const 1, memory.grow, end
    const body = [_]u8{ 0x00, 0x41, 0x01, 0x40, 0x00, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    try testing.expectEqual(@as(?u32, 2), module.memory_max);
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();

    // Growing onto the declared maximum succeeds and reports the old size.
    try testing.expectEqual(@as(i64, 1), try inst.callExport("grow", &.{}));
    try testing.expectEqual(@as(usize, 2 * page_size), inst.memory.items.len);

    // One page further exceeds the *declared* maximum (well short of the spec
    // ceiling), so the result is -1 and the memory is left untouched.
    try testing.expectEqual(@as(i64, -1), try inst.callExport("grow", &.{}));
    try testing.expectEqual(@as(usize, 2 * page_size), inst.memory.items.len);
}

test "memory.grow within bounds succeeds" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.memory(1);
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // i32.const 1, memory.grow, drop, end  (1 -> 2 pages)
    const body = [_]u8{ 0x00, 0x41, 0x01, 0x40, 0x00, 0x1a, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    _ = try inst.callExport("run", &.{});
    // Expected after grow: 2 pages = 131072 bytes.
    try testing.expectEqual(@as(usize, 2 * page_size), inst.memory.items.len);
}

// `i32.const` is pushed sign-extended, so the operand of `memory.grow` can be a
// negative i64. Reinterpreting it must not be a checked cast: `@intCast(-1)` to
// u64 is illegal behaviour and panics in a safe build, which would crash the
// host on well-formed WASM. Treat it as the huge unsigned delta the spec says
// it is, i.e. a growth request that fails with -1.
test "memory.grow with a negative delta must not crash the host" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }}); // () -> i32
    try b.functions(&.{0});
    try b.memory(1);
    try b.exports(&.{.{ .name = "grow", .index = 0 }});
    // i32.const -1, memory.grow, end
    const body = [_]u8{ 0x00, 0x41, 0x7f, 0x40, 0x00, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, -1), try inst.callExport("grow", &.{}));
    try testing.expectEqual(@as(usize, page_size), inst.memory.items.len);
}

// The step budget bounds time, not memory. A self-recursive module grows the
// frame stack (and each frame's locals) first, so the depth limit is what turns
// runaway recursion into an error instead of gigabytes of frames.
test "unbounded recursion is stopped by the call-depth limit" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "recurse", .index = 0 }});
    // call 0, end
    const body = [_]u8{ 0x00, 0x10, 0x00, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.CallDepthExceeded, inst.callExport("recurse", &.{}));
}

test "ordinary nested calls stay well inside the call-depth limit" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }}); // () -> i32
    try b.functions(&.{ 0, 0 });
    try b.exports(&.{.{ .name = "outer", .index = 0 }});
    // outer: call 1, end         — delegates to inner
    // inner: i32.const 7, end    — yields 7
    const outer = [_]u8{ 0x00, 0x10, 0x01, 0x0b };
    const inner = [_]u8{ 0x00, 0x41, 0x07, 0x0b };
    try b.code(&.{ &outer, &inner });

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 7), try inst.callExport("outer", &.{}));
}

test "unsupported opcode traps" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // 0xff is not a supported opcode; the VM must trap rather than panic.
    const body = [_]u8{ 0x00, 0xff, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.UnsupportedOpcode, inst.callExport("run", &.{}));
}

test "block/end executes and returns" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{0x7f}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // run(n): block { n } end -> n
    const body = [_]u8{ 0x01, 0x00, 0x7f, 0x20, 0x00, 0x02, 0x40, 0x20, 0x00, 0x0b, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 7), try inst.callExport("run", &.{7}));
}

test "loop with br_if counts down (sum 0..n)" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    // (i32 n) -> i32 sum
    try b.types(&.{.{ .params = &.{0x7f}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "sum", .index = 0 }});
    // locals: [0]=n, [1]=i(0), [2]=acc(0)
    // block {            ; label 1 (outer), exit target
    //   loop {           ; label 0 (inner), restart target
    //     local.get 1; local.get 0; i32.ge_s; br_if 1  (exit if i>=n)
    //     local.get 2; local.get 1; i32.add; local.set 2  (acc += i)
    //     local.get 1; i32.const 1; i32.add; local.set 1  (i += 1)
    //     br 0           (restart loop)
    //   }
    // }
    // local.get 2; return
    const body = [_]u8{
        0x01, 0x03, 0x7f, // 1 decl: 3 x i32
        0x02, 0x40, // block (outer)
        0x03, 0x40, // loop (inner)
        0x20, 0x01, 0x20, 0x00, 0x4e, // local.get 1; local.get 0; i32.ge_s
        0x0d, 0x01, // br_if 1 (exit block)
        0x20, 0x02, 0x20, 0x01, 0x6a, 0x21, 0x02, // acc = acc + i
        0x20, 0x01, 0x41, 0x01, 0x6a, 0x21, 0x01, // i = i + 1
        0x0c, 0x00, // br 0 (restart loop)
        0x0b, // end loop
        0x0b, // end block
        0x20, 0x02, // local.get 2 (acc)
        0x0f, // return
    };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 0), try inst.callExport("sum", &.{0}));
    try testing.expectEqual(@as(i64, 3), try inst.callExport("sum", &.{3})); // 0+1+2
    try testing.expectEqual(@as(i64, 36), try inst.callExport("sum", &.{9})); // 0+..+8
}

test "nested block with br exits the targeted block" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    // () -> i32 ; result is 1 if br 0 hits outer block, 2 if inner.
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // block {            ; label 1 (outer)
    //   block {          ; label 0 (inner)
    //     i32.const 2    ; would be the inner result
    //     br 1           ; jump to outer block end
    //   end
    //   i32.const 1      ; skipped because br 1 exited
    //   return
    // } end
    // i32.const 99 ; skipped
    // return
    const body = [_]u8{
        0x00, // no locals
        0x02, 0x40, // block (outer)
        0x02, 0x40, // block (inner)
        0x41, 0x02, // i32.const 2
        0x0c, 0x01, // br 1 -> outer end
        0x0b, // end inner
        0x41, 0x01, // i32.const 1
        0x0f, // return (skipped)
        0x0b, // end outer
        0x41, 0x2a, // i32.const 42 (skipped)
        0x0f, // return
    };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    // br 1 exits the outer block, leaving stack empty; the function falls
    // through to `i32.const 42; return` — so result is 42, proving br 1
    // skipped the inner-block's `i32.const 1; return`.
    try testing.expectEqual(@as(i64, 42), try inst.callExport("run", &.{}));
}

test "br with out-of-range label is rejected" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // block { br 5 } end  — label 5 does not exist; must reject, not crash.
    const body = [_]u8{ 0x00, 0x02, 0x40, 0x0c, 0x05, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.MalformedBlocks, inst.callExport("run", &.{}));
}

test "block with i32 result type executes and returns the value" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // block (result i32) i32.const 7 end → 7
    const body = [_]u8{ 0x00, 0x02, 0x7f, 0x41, 0x07, 0x0b, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 7), try inst.callExport("run", &.{}));
}

test "block result is carried through br" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // block (result i32) i32.const 9 br 0 end → br carries the value out.
    const body = [_]u8{ 0x00, 0x02, 0x7f, 0x41, 0x09, 0x0c, 0x00, 0x0b, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 9), try inst.callExport("run", &.{}));
}

test "loop with i32 result type returns the value" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // loop (result i32) i32.const 5 end → 5
    const body = [_]u8{ 0x00, 0x03, 0x7f, 0x41, 0x05, 0x0b, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 5), try inst.callExport("run", &.{}));
}

test "if with i32 result type returns the branch value" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // i32.const 1; if (result i32) i32.const 42 end → 42 (true branch)
    const body = [_]u8{ 0x00, 0x41, 0x01, 0x04, 0x7f, 0x41, 0x2a, 0x0b, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 42), try inst.callExport("run", &.{}));
}

test "multi-value block type is rejected" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // A multi-value / type-index blocktype (s33 negative, e.g. 0x7d = -3) is
    // not supported by this single-result subset.
    const body = [_]u8{ 0x00, 0x02, 0x7d, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.BlockResultUnsupported, inst.callExport("run", &.{}));
}

test "infinite loop is bounded by the execution budget" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // loop { br 0 } — an unconditional infinite loop.
    const body = [_]u8{ 0x00, 0x03, 0x40, 0x0c, 0x00, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    inst.setStepBudget(1000);
    try testing.expectError(error.ExecutionLimit, inst.callExport("run", &.{}));
}

test "explicit budget allows a bounded loop to complete" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // loop { br 0 } — bounded by a generous budget must still hit the limit
    // here (it never terminates), so use a *terminating* loop instead:
    // block { loop { br 1 } } — br 1 exits the block on the first iteration.
    const body = [_]u8{ 0x00, 0x02, 0x40, 0x03, 0x40, 0x0c, 0x01, 0x0b, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    inst.setStepBudget(1000); // plenty for a 2-instruction loop
    try testing.expectEqual(@as(i64, 0), try inst.callExport("run", &.{}));
}

test "malformed if/else: missing end" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // i32.const 0, if (empty)  — cond is false, so the VM must scan for a
    // matching `else`/`end` but the body ends immediately: MalformedBlocks.
    const body = [_]u8{ 0x00, 0x41, 0x00, 0x04, 0x40 };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.MalformedBlocks, inst.callExport("run", &.{}));
}

test "call to out-of-range function index" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // call 9 (no such function), end
    const body = [_]u8{ 0x00, 0x10, 0x09, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.BadTypeIndex, inst.callExport("run", &.{}));
}

test "local.get out of bounds" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // no locals; local.get 3, drop, end
    const body = [_]u8{ 0x00, 0x20, 0x03, 0x1a, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.LocalIndexOutOfBounds, inst.callExport("run", &.{}));
}

test "global.get out of bounds" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // no globals; global.get 0, drop, end
    const body = [_]u8{ 0x00, 0x23, 0x00, 0x1a, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.GlobalIndexOutOfBounds, inst.callExport("run", &.{}));
}

test "call with wrong arity is rejected" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    // callee takes 2 i32 params; the exported wrapper passes 0.
    try b.types(&.{
        .{ .params = &.{}, .returns = &.{} }, // 0: wrapper
        .{ .params = &.{ 0x7f, 0x7f }, .returns = &.{} }, // 1: callee
    });
    try b.functions(&.{ 0, 1 });
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // wrapper: call 1 (expects 2 args, stack empty), end
    const wrapper = [_]u8{ 0x00, 0x10, 0x01, 0x0b };
    // callee: (i32,i32)->() does nothing
    const callee = [_]u8{ 0x00, 0x0b };
    try b.code(&.{ &wrapper, &callee });

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.StackUnderflow, inst.callExport("run", &.{}));
}

test "global import with unsupported valtype is rejected at parse" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    // Import section: kind 0x03 (global) with an unsupported valtype (0x7d =
    // f32, which the MVP subset does not accept). The import is parsed but its
    // valtype is rejected as `BadType`.
    var p = Builder{ .alloc = testing.allocator };
    defer p.deinit();
    try p.uleb(1);
    try p.name("cordis");
    try p.name("g");
    try p.emitByte(0x03); // kind: global
    try p.emitByte(0x7d); // valtype: f32 (unsupported)
    try p.emitByte(0x00);
    try b.section(2, p.buf.items);

    try testing.expectError(error.BadType, Module.load(testing.allocator, b.buf.items));
}

test "multi-value return type is rejected at parse" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{ 0x7f, 0x7f } }}); // 2 returns
    try testing.expectError(error.MultiValueUnsupported, Module.load(testing.allocator, b.buf.items));
}

// ── Table section coverage (id 4) ────────────────────────────────────────
// The interpreter has no `call_indirect` or element-section support, so tables
// are parsed/validated but never dispatched. The contract is: a valid single
// table loads cleanly, and any malformed/unsupported table is rejected with an
// error rather than crashing the parser.

test "valid single table loads and is recorded" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    // table: 1 element, no max (funcref implied by Builder.tables)
    try b.tables(&.{.{ .min = 1 }});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    const body = [_]u8{ 0x00, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    try testing.expectEqual(@as(usize, 1), module.tables.items.len);
    try testing.expectEqual(@as(u32, 1), module.tables.items[0].min);
    try testing.expectEqual(@as(?u32, null), module.tables.items[0].max);
    // A module carrying a table still instantiates and runs.
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 0), try inst.callExport("run", &.{}));
}

test "table with min and max loads" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.tables(&.{.{ .min = 2, .max = 8 }});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    const body = [_]u8{ 0x00, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    try testing.expectEqual(@as(usize, 1), module.tables.items.len);
    try testing.expectEqual(@as(u32, 2), module.tables.items[0].min);
    try testing.expectEqual(@as(?u32, 8), module.tables.items[0].max);
}

test "table with max < min is rejected" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    // Hand-rolled table section: funcref, flags=1 (max present), min=10, max=3
    const payload = [_]u8{ 0x01, 0x70, 0x01, 0x0a, 0x03 };
    try b.section(4, &payload);
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    const body = [_]u8{ 0x00, 0x0b };
    try b.code(&.{&body});

    try testing.expectError(error.BadTable, Module.load(testing.allocator, b.buf.items));
}

test "unsupported table element type is rejected" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    // funcref is 0x70; 0x71 (externref) is unsupported in MVP.
    const payload = [_]u8{ 0x01, 0x71, 0x00, 0x01 };
    try b.section(4, &payload);
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    const body = [_]u8{ 0x00, 0x0b };
    try b.code(&.{&body});

    try testing.expectError(error.UnsupportedTable, Module.load(testing.allocator, b.buf.items));
}

test "more than one table is rejected" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    // count=2, two valid funcref tables
    const payload = [_]u8{ 0x02, 0x70, 0x00, 0x01, 0x70, 0x00, 0x01 };
    try b.section(4, &payload);
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    const body = [_]u8{ 0x00, 0x0b };
    try b.code(&.{&body});

    try testing.expectError(error.MultiTableUnsupported, Module.load(testing.allocator, b.buf.items));
}

test "table import with bad element type is rejected" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    // Import section: 1 import, module "m", name "t", kind=table(1),
    // elemtype=0x71 (unsupported), limits flags=0 min=1.
    const payload = [_]u8{ 0x01, 0x01, 0x6d, 0x01, 0x74, 0x01, 0x71, 0x00, 0x01 };
    try b.section(2, &payload);
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    const body = [_]u8{ 0x00, 0x0b };
    try b.code(&.{&body});

    try testing.expectError(error.BadTable, Module.load(testing.allocator, b.buf.items));
}

test "table import is accepted and recorded" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    // Import section: 1 import, module "m", name "t", kind=table(1),
    // elemtype=0x70 (funcref), limits flags=0 min=1.
    const payload = [_]u8{ 0x01, 0x01, 0x6d, 0x01, 0x74, 0x01, 0x70, 0x00, 0x01 };
    try b.section(2, &payload);
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    const body = [_]u8{ 0x00, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    try testing.expectEqual(@as(usize, 1), module.table_imports.items.len);
    try testing.expectEqual(@as(u8, 0x70), module.table_imports.items[0].elemtype);
}

// Shared module shape for call_indirect tests:
//   types   0: (i32,i32)->i32   1: (i32,i32)->i32   2: (i32)->i32
//   funcs   0: add (type0)       1: sub (type0)      2: unary (type2)
//   table   min 1, element places `sub` (index 1) at slot 0
//   dispatch(a,b) = call_indirect(type0) over slot 0 → invokes sub(a,b)
fn buildCallIndirectModule(alloc: std.mem.Allocator, with_element: bool) !struct { module: *Module, inst: *Instance, buf: []u8 } {
    var b = Builder{ .alloc = alloc };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{
        .{ .params = &.{ 0x7f, 0x7f }, .returns = &.{0x7f} }, // 0: (i32,i32)->i32
        .{ .params = &.{ 0x7f, 0x7f }, .returns = &.{0x7f} }, // 1: (i32,i32)->i32
        .{ .params = &.{0x7f}, .returns = &.{0x7f} }, // 2: (i32)->i32
    });
    try b.functions(&.{ 0, 0, 1, 0 }); // add, sub, unary, dispatch
    try b.tables(&.{.{ .min = 1 }});
    if (with_element) {
        // Place `sub` (func index 1) into table slot 0.
        try b.elements(&.{.{ .offset = 0, .func_indices = &.{1} }});
    }
    try b.exports(&.{ .{ .name = "add", .index = 0 }, .{ .name = "sub", .index = 1 }, .{ .name = "unary", .index = 2 }, .{ .name = "dispatch", .index = 3 } });
    // Code entries must match function indices 0..3 in order.
    // add(a,b) = a + b
    const add_body = [_]u8{ 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b };
    // sub(a,b) = a - b
    const sub_body = [_]u8{ 0x00, 0x20, 0x00, 0x20, 0x01, 0x6b, 0x0b };
    // unary(a) = a + 1
    const unary_body = [_]u8{ 0x00, 0x20, 0x00, 0x41, 0x01, 0x6a, 0x0b };
    // dispatch(a,b): local.get 0, local.get 1, i32.const 0, call_indirect type0
    const dispatch_body = [_]u8{ 0x00, 0x20, 0x00, 0x20, 0x01, 0x41, 0x00, 0x11, 0x00, 0x00, 0x0b };
    try b.code(&.{ &add_body, &sub_body, &unary_body, &dispatch_body });

    // The module borrows `b.buf`, so transfer ownership of the bytes to the
    // caller (otherwise deiniting `b` here would leave dangling code bodies).
    const buf = try b.buf.toOwnedSlice(alloc);

    const module_ptr = try alloc.create(Module);
    module_ptr.* = try Module.load(alloc, buf);
    const inst = try Instance.create(alloc, module_ptr, null, &.{}, no_globals);
    return .{ .module = module_ptr, .inst = inst, .buf = buf };
}

test "call_indirect dispatches through the table to the right function" {
    const built = try buildCallIndirectModule(testing.allocator, true);
    defer {
        built.module.deinit();
        testing.allocator.destroy(built.module);
        testing.allocator.free(built.buf);
    }
    defer built.inst.deinit();
    // dispatch(10, 3) → call_indirect slot 0 → sub(10, 3) = 7
    try testing.expectEqual(@as(i64, 7), try built.inst.callExport("dispatch", &.{ 10, 3 }));
    // A direct call confirms add is intact.
    try testing.expectEqual(@as(i64, 13), try built.inst.callExport("add", &.{ 10, 3 }));
}

test "call_indirect with a type mismatch traps" {
    const built = try buildCallIndirectModule(testing.allocator, true);
    defer {
        built.module.deinit();
        testing.allocator.destroy(built.module);
        testing.allocator.free(built.buf);
    }
    defer built.inst.deinit();
    // dispatch uses immediate type 0; build a sibling that calls indirect with
    // type 2 (unary, one param) against the same slot (which holds a 2-param
    // function) → the type check must trap, never dispatch wrongly.
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{
        .{ .params = &.{ 0x7f, 0x7f }, .returns = &.{0x7f} },
        .{ .params = &.{0x7f}, .returns = &.{0x7f} },
    });
    try b.functions(&.{0});
    try b.tables(&.{.{ .min = 1 }});
    try b.elements(&.{.{ .offset = 0, .func_indices = &.{0} }});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // local.get 0, local.get 1, i32.const 0, call_indirect type1 (1 param)
    const body = [_]u8{ 0x00, 0x20, 0x00, 0x20, 0x01, 0x41, 0x00, 0x11, 0x01, 0x00, 0x0b };
    try b.code(&.{&body});
    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.CallIndirectTypeMismatch, inst.callExport("run", &.{ 1, 2 }));
}

test "call_indirect with an out-of-bounds table index traps" {
    const built = try buildCallIndirectModule(testing.allocator, true);
    defer {
        built.module.deinit();
        testing.allocator.destroy(built.module);
        testing.allocator.free(built.buf);
    }
    defer built.inst.deinit();
    // call_indirect with slot 5 (table has 1 slot) must trap, not read OOB.
    // Stack layout for call_indirect is [arg0, arg1, slot]; the slot must be
    // on top so it is the last operand popped.
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{ 0x7f, 0x7f }, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.tables(&.{.{ .min = 1 }});
    try b.elements(&.{.{ .offset = 0, .func_indices = &.{0} }});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // i32.const 0 (arg0), i32.const 0 (arg1), i32.const 5 (slot), call_indirect type0
    const body = [_]u8{ 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x05, 0x11, 0x00, 0x00, 0x0b };
    try b.code(&.{&body});
    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.CallIndirectOutOfBounds, inst.callExport("run", &.{ 0, 0 }));
}

test "call_indirect through an uninitialized table slot traps" {
    // Table of 1 slot but NO element segment → slot 0 is null.
    const built = try buildCallIndirectModule(testing.allocator, false);
    defer {
        built.module.deinit();
        testing.allocator.destroy(built.module);
        testing.allocator.free(built.buf);
    }
    defer built.inst.deinit();
    try testing.expectError(error.CallIndirectUninitialized, built.inst.callExport("dispatch", &.{ 1, 2 }));
}

test "br_table selects target by index, defaults out-of-range" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{0x7f}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // f(x): if x == 0, br_table picks the inner label (target 0) → falls to
    // `i32.const 100; return`; if x >= 1 (out of the single target range) it
    // falls through to the default (outer label) skipping that and returning
    // `i32.const 200`. Structure:
    //   block {            ; outer (arity 0)
    //     block {          ; inner (arity 0)
    //       local.get 0
    //       br_table 0 1   ; count=1, target[0]=0, default=1
    //     }
    //     i32.const 100; return
    //   }
    //   i32.const 200; return
    const body = [_]u8{
        0x00, // 0 locals
        0x02, 0x40, // block (outer)
        0x02, 0x40, // block (inner)
        0x20, 0x00, // local.get 0
        0x0e, 0x01, 0x00, 0x01, // br_table: count=1, target[0]=0, default=1
        0x0b, // end inner
        0x41, 0xe4, 0x00, // i32.const 100  (SLEB: 100 needs 2 bytes)
        0x0f, // return
        0x0b, // end outer
        0x41, 0xc8, 0x01, // i32.const 200
        0x0f, // return
    };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();

    // x == 0 → index 0 → inner target → returns 100.
    const r0 = try inst.callExport("run", &.{0});
    try testing.expectEqual(@as(i64, 100), r0);
    // x >= 1 → out of target range → default (outer) → skips to 200.
    try testing.expectEqual(@as(i64, 200), try inst.callExport("run", &.{1}));
    try testing.expectEqual(@as(i64, 200), try inst.callExport("run", &.{255}));
}

test "br_table with multiple targets branches to the matching one" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{0x7f}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // f(x): br_table with count=2 → target[0]=0, target[1]=1, default=2.
    //   block {            ; label 2
    //     block {          ; label 1
    //       block {        ; label 0
    //         local.get 0
    //         br_table 0 1 2  ; cnt=2, targets=[0,1], default=2
    //       }
    //       i32.const 11; return   ; reached if target 0 (innermost)
    //     }
    //     i32.const 22; return      ; reached if target 1
    //   }
    //   i32.const 33; return         ; reached if default 2 (x >= 2)
    const body = [_]u8{
        0x00, // 0 locals
        0x02, 0x40, // block (label 2 / outer)
        0x02, 0x40, // block (label 1)
        0x02, 0x40, // block (label 0 / innermost)
        0x20, 0x00, // local.get 0
        0x0e, 0x02, 0x00, 0x01, 0x02, // br_table: cnt=2, [0,1], default=2
        0x0b, // end innermost
        0x41, 0x0b, // i32.const 11
        0x0f, // return
        0x0b, // end (label 1)
        0x41, 0x16, // i32.const 22
        0x0f, // return
        0x0b, // end (label 2 / outer)
        0x41, 0x21, // i32.const 33
        0x0f, // return
    };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();

    try testing.expectEqual(@as(i64, 11), try inst.callExport("run", &.{0}));
    try testing.expectEqual(@as(i64, 22), try inst.callExport("run", &.{1}));
    try testing.expectEqual(@as(i64, 33), try inst.callExport("run", &.{2}));
    try testing.expectEqual(@as(i64, 33), try inst.callExport("run", &.{99}));
}

test "i64 local.get + i64.add returns the sum" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{0x7e}, .returns = &.{0x7e} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // local.get 0; i64.const 1; i64.add → arg + 1
    const body = [_]u8{ 0x00, 0x20, 0x00, 0x42, 0x01, 0x7c, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 10000000001), try inst.callExport("run", &.{10000000000}));
}

test "i64.eq is true for equal operands, false otherwise" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // i64.const 7; i64.const 7; i64.eq → 1
    const body = [_]u8{ 0x00, 0x42, 0x07, 0x42, 0x07, 0x51, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "i64.lt_s compares signed" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // i64.const -1; i64.const 1; i64.lt_s → 1 (-1 < 1)
    const body = [_]u8{ 0x00, 0x42, 0x7f, 0x42, 0x01, 0x53, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "i64.shl shifts left" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7e} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // i64.const 1; i64.const 10; i64.shl → 1024
    const body = [_]u8{ 0x00, 0x42, 0x01, 0x42, 0x0a, 0x86, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1024), try inst.callExport("run", &.{}));
}

test "i64 div by zero is trapped" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7e} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // i64.const 5; i64.const 0; i64.div_s → trap
    const body = [_]u8{ 0x00, 0x42, 0x05, 0x42, 0x00, 0x7f, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.DivisionByZero, inst.callExport("run", &.{}));
}

test "block with i64 result type returns the value" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7e} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // block (result i64) i64.const 42 end → 42
    const body = [_]u8{ 0x00, 0x02, 0x7e, 0x42, 0x2a, 0x0b, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 42), try inst.callExport("run", &.{}));
}

test "i64.load reads 8 little-endian bytes from a data segment" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7e} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    try b.memory(1);
    // 8 bytes little-endian = 0x0102030405060708
    const bytes = [_]u8{ 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01 };
    try b.data(&.{.{ .offset = 0, .bytes = &bytes }});
    // i32.const 0; i64.load → 0x0102030405060708
    const body = [_]u8{ 0x00, 0x41, 0x00, 0x29, 0x00, 0x00, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 0x0102030405060708), try inst.callExport("run", &.{}));
}

test "i64.store then i64.load round-trips the value" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{0x7e}, .returns = &.{0x7e} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    try b.memory(1);
    // i32.const 0; local.get 0; i64.store(0); i32.const 0; i64.load(0); return
    const body = [_]u8{ 0x00, 0x41, 0x00, 0x20, 0x00, 0x37, 0x00, 0x00, 0x41, 0x00, 0x29, 0x00, 0x00, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 0x0102030405060708), try inst.callExport("run", &.{0x0102030405060708}));
}

test "i64.load8_s sign-extends a single byte" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{0x7e}, .returns = &.{0x7e} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    try b.memory(1);
    // i32.const 0; local.get 0; i64.store8(0); i32.const 0; i64.load8_s(0); return
    const body = [_]u8{ 0x00, 0x41, 0x00, 0x20, 0x00, 0x3c, 0x00, 0x00, 0x41, 0x00, 0x30, 0x00, 0x00, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, -1), try inst.callExport("run", &.{0xFF}));
}

test "i32.load16_u zero-extends a 16-bit value" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    try b.memory(1);
    // little-endian 0x1234 at offset 0
    const bytes = [_]u8{ 0x34, 0x12 };
    try b.data(&.{.{ .offset = 0, .bytes = &bytes }});
    // i32.const 0; i32.load16_u → 0x1234
    const body = [_]u8{ 0x00, 0x41, 0x00, 0x2f, 0x00, 0x00, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 0x1234), try inst.callExport("run", &.{}));
}

test "i32.load16_s sign-extends a negative 16-bit value" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    try b.memory(1);
    // little-endian 0xFFFF (=-1 as i16) at offset 0
    const bytes = [_]u8{ 0xff, 0xff };
    try b.data(&.{.{ .offset = 0, .bytes = &bytes }});
    // i32.const 0; i32.load16_s → -1
    const body = [_]u8{ 0x00, 0x41, 0x00, 0x2e, 0x00, 0x00, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, -1), try inst.callExport("run", &.{}));
}

test "i32.store16 then i32.load16 round-trips" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{0x7f}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    try b.memory(1);
    // i32.const 0; local.get 0; i32.store16(0); i32.const 0; i32.load16_u(0); return
    const body = [_]u8{ 0x00, 0x41, 0x00, 0x20, 0x00, 0x3b, 0x00, 0x00, 0x41, 0x00, 0x2f, 0x00, 0x00, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    // value 0x1234 stored as 16 bits, high 16 bits must not leak through.
    try testing.expectEqual(@as(i64, 0x1234), try inst.callExport("run", &.{0x1234}));
}

test "f32.const + f32.eq returns true for equal values" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // f32.const 1.5; f32.const 1.5; f32.eq → 1  (1.5 = 0x3FC00000)
    const body = [_]u8{ 0x00, 0x43, 0x00, 0x00, 0xC0, 0x3F, 0x43, 0x00, 0x00, 0xC0, 0x3F, 0x5b, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "f32.add sums two constants" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // f32.const 1.5; f32.const 2.0; f32.add; f32.const 3.5; f32.eq → 1
    const body = [_]u8{ 0x00, 0x43, 0x00, 0x00, 0xC0, 0x3F, 0x43, 0x00, 0x00, 0x00, 0x40, 0x92, 0x43, 0x00, 0x00, 0x60, 0x40, 0x5b, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "f32.lt compares ordered" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // f32.const 1.0; f32.const 2.0; f32.lt → 1
    const body = [_]u8{ 0x00, 0x43, 0x00, 0x00, 0x80, 0x3F, 0x43, 0x00, 0x00, 0x00, 0x40, 0x5d, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "f32.sqrt of 4.0 is 2.0" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // f32.const 4.0; f32.sqrt; f32.const 2.0; f32.eq → 1
    const body = [_]u8{ 0x00, 0x43, 0x00, 0x00, 0x80, 0x40, 0x91, 0x43, 0x00, 0x00, 0x00, 0x40, 0x5b, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "f32.neg negates" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // f32.const 2.0; f32.neg; f32.const -2.0; f32.eq → 1
    const body = [_]u8{ 0x00, 0x43, 0x00, 0x00, 0x00, 0x40, 0x8c, 0x43, 0x00, 0x00, 0x00, 0xC0, 0x5b, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "f32.min returns the smaller operand" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // f32.const 3.0; f32.const 1.0; f32.min; f32.const 1.0; f32.eq → 1
    const body = [_]u8{ 0x00, 0x43, 0x00, 0x00, 0x40, 0x40, 0x43, 0x00, 0x00, 0x80, 0x3F, 0x96, 0x43, 0x00, 0x00, 0x80, 0x3F, 0x5b, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

// ── f64 ops ─────────────────────────────────────────────────────────────

test "f64.const + f64.eq returns true for equal values" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // f64.const 1.5; f64.const 1.5; f64.eq → 1  (1.5 = 0x3FF8000000000000)
    const body = [_]u8{ 0x00, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F, 0x61, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "f64.add sums two constants" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // f64.const 1.5; f64.const 2.0; f64.add; f64.const 3.5; f64.eq → 1
    const body = [_]u8{
        0x00,
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F, // f64.const 1.5
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, // f64.const 2.0
        0xa0, // f64.add
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x40, // f64.const 3.5
        0x61, 0x0b, // f64.eq; end
    };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "f64.lt compares ordered" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // f64.const 1.0; f64.const 2.0; f64.lt → 1
    const body = [_]u8{
        0x00,
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F, // f64.const 1.0
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, // f64.const 2.0
        0x63, 0x0b, // f64.lt; end
    };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "f64.sqrt of 4.0 is 2.0" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // f64.const 4.0; f64.sqrt; f64.const 2.0; f64.eq → 1
    const body = [_]u8{
        0x00,
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x40, // f64.const 4.0
        0x9f, // f64.sqrt
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, // f64.const 2.0
        0x61, 0x0b, // f64.eq; end
    };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "f64.neg negates" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // f64.const 2.0; f64.neg; f64.const -2.0; f64.eq → 1
    const body = [_]u8{
        0x00,
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, // f64.const 2.0
        0x9a, // f64.neg
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, // f64.const -2.0
        0x61, 0x0b, // f64.eq; end
    };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "f64.min returns the smaller operand" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // f64.const 3.0; f64.const 1.0; f64.min; f64.const 1.0; f64.eq → 1
    const body = [_]u8{
        0x00,
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x40, // f64.const 3.0
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F, // f64.const 1.0
        0xa4, // f64.min
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F, // f64.const 1.0
        0x61, 0x0b, // f64.eq; end
    };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "f64.load reads a double from memory" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    try b.memory(1);
    // little-endian 1.5 = 0x3FF8000000000000
    const bytes = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F };
    try b.data(&.{.{ .offset = 0, .bytes = &bytes }});
    // i32.const 0; f64.load; f64.const 1.5; f64.eq → 1
    const body = [_]u8{ 0x00, 0x41, 0x00, 0x2b, 0x00, 0x00, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F, 0x61, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "f64.convert_i32_s widens an integer" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // i32.const 7; f64.convert_i32_s (0xb7); f64.const 7.0; f64.eq → 1
    const body = [_]u8{
        0x00,
        0x41, 0x07, // i32.const 7
        0xb7, // f64.convert_i32_s
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1C, 0x40, // f64.const 7.0
        0x61, 0x0b, // f64.eq; end
    };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "f64.promote_f32 widens a single float" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // f32.const 1.5; f64.promote_f32; f64.const 1.5; f64.eq → 1
    const body = [_]u8{
        0x00,
        0x43, 0x00, 0x00, 0xC0, 0x3F, // f32.const 1.5
        0xbb, // f64.promote_f32
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F, // f64.const 1.5
        0x61, 0x0b, // f64.eq; end
    };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "f64.reinterpret_i64 round-trips bits" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    var v = Builder{ .alloc = b.alloc };
    defer v.deinit();
    try v.emitByte(0x00); // locals count (0)
    try v.i64Const(@as(i64, 0x3FF8000000000000)); // i64.const bit pattern of 1.5
    try v.op(0xbf); // f64.reinterpret_i64
    try v.f64Const(1.5); // f64.const 1.5
    try v.op(0x61); // f64.eq
    try v.op(0x0b);
    try b.code(&.{v.buf.items});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "i32.trunc_f64_s truncates a double" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // f64.const 3.9; i32.trunc_f64_s; i32.const 3; i32.eq → 1
    const body = [_]u8{
        0x00,
        0x44, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x0B, 0x40, // f64.const 3.9
        0xaa, // i32.trunc_f64_s
        0x41, 0x03, // i32.const 3
        0x46, 0x0b, // i32.eq; end
    };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "f32.load reads a float from memory" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    try b.memory(1);
    // little-endian 1.5 = 0x3FC00000
    const bytes = [_]u8{ 0x00, 0x00, 0xC0, 0x3F };
    try b.data(&.{.{ .offset = 0, .bytes = &bytes }});
    // i32.const 0; f32.load; f32.const 1.5; f32.eq → 1
    const body = [_]u8{ 0x00, 0x41, 0x00, 0x2a, 0x00, 0x00, 0x43, 0x00, 0x00, 0xC0, 0x3F, 0x5b, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

// ── P0 numeric conversions ─────────────────────────────────────────────
// These build function bodies with the Builder helpers (i32Const/i64Const/
// f32Const/op) so the SLEB encodings are always correct.

test "i32.clz/ctz/popcnt of known values" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    var v = Builder{ .alloc = b.alloc };
    defer v.deinit();
    try v.emitByte(0x00); // locals count (0)
    try v.i32Const(1);
    try v.op(0x67); // clz → 31
    try v.i32Const(1);
    try v.op(0x68); // ctz → 0
    try v.i32Const(1);
    try v.op(0x69); // popcnt → 1
    try v.op(0x6a); // add 31+0
    try v.op(0x6a); // add +1 → 32
    try v.op(0x0b);
    try b.code(&.{v.buf.items});
    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 32), try inst.callExport("run", &.{}));
}

test "i64.clz/ctz/popcnt of known values" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    var v = Builder{ .alloc = b.alloc };
    defer v.deinit();
    try v.emitByte(0x00); // locals count (0)
    try v.i64Const(1);
    try v.op(0x79); // clz → 63
    try v.i64Const(1);
    try v.op(0x7a); // ctz → 0
    try v.i64Const(1);
    try v.op(0x7b); // popcnt → 1
    try v.op(0x6a); // add 63+0
    try v.op(0x6a); // add +1 → 64
    try v.op(0x0b);
    try b.code(&.{v.buf.items});
    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 64), try inst.callExport("run", &.{}));
}

test "i32.wrap_i64 keeps low 32 bits" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    var v = Builder{ .alloc = b.alloc };
    defer v.deinit();
    try v.emitByte(0x00); // locals count (0)
    try v.i64Const(0x1_00000001);
    try v.op(0xa7); // i32.wrap_i64 → 1
    try v.op(0x0b);
    try b.code(&.{v.buf.items});
    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "i64.extend_i32_s sign-extends and extend_i32_u zero-extends" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7e} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    var v = Builder{ .alloc = b.alloc };
    defer v.deinit();
    try v.emitByte(0x00); // locals count (0)
    try v.i32Const(-1);
    try v.op(0xad); // i64.extend_i32_u → 0xffffffff
    try v.op(0x0b);
    try b.code(&.{v.buf.items});
    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 0xffffffff), try inst.callExport("run", &.{}));
}

test "i64.extend_i32_s sign-extends negative" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7e} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    var v = Builder{ .alloc = b.alloc };
    defer v.deinit();
    try v.emitByte(0x00); // locals count (0)
    try v.i32Const(-1);
    try v.op(0xac); // i64.extend_i32_s → -1
    try v.op(0x0b);
    try b.code(&.{v.buf.items});
    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, -1), try inst.callExport("run", &.{}));
}

test "i32.extend8_s / extend16_s sign-extend" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    var v = Builder{ .alloc = b.alloc };
    defer v.deinit();
    try v.emitByte(0x00); // locals count (0)
    try v.i32Const(-128);
    try v.op(0xc0); // extend8_s → -128
    try v.i32Const(-32768);
    try v.op(0xc1); // extend16_s → -32768
    try v.op(0x6a); // add → -32896
    try v.op(0x0b);
    try b.code(&.{v.buf.items});
    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, -32896), try inst.callExport("run", &.{}));
}

test "i64.extend8_s / extend16_s sign-extend" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7e} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    var v = Builder{ .alloc = b.alloc };
    defer v.deinit();
    try v.emitByte(0x00); // locals count (0)
    try v.i64Const(0xFF);
    try v.op(0xc2); // extend8_s → -1
    try v.i64Const(0xFFFF);
    try v.op(0xc3); // extend16_s → -1
    try v.op(0x7c); // i64.add → -2
    try v.op(0x0b);
    try b.code(&.{v.buf.items});
    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, -2), try inst.callExport("run", &.{}));
}

test "f32.reinterpret_i32 and i32.reinterpret_f32 round-trip bits" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    var v = Builder{ .alloc = b.alloc };
    defer v.deinit();
    try v.emitByte(0x00); // locals count (0)
    try v.i32ConstBits(0x3FC00000);
    try v.op(0xbe); // f32.reinterpret_i32 (1.5)
    try v.op(0xbc); // i32.reinterpret_f32 → 0x3FC00000
    try v.op(0x0b);
    try b.code(&.{v.buf.items});
    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 0x3FC00000), try inst.callExport("run", &.{}));
}

test "f32.convert_i32_s converts -5 to -5.0, compared" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    var v = Builder{ .alloc = b.alloc };
    defer v.deinit();
    try v.emitByte(0x00); // locals count (0)
    try v.i32Const(-5);
    try v.op(0xb2); // f32.convert_i32_s
    try v.f32Const(-5.0);
    try v.op(0x5b); // f32.eq → 1
    try v.op(0x0b);
    try b.code(&.{v.buf.items});
    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1), try inst.callExport("run", &.{}));
}

test "i32.trunc_f32_s truncates 3.5 to 3" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    var v = Builder{ .alloc = b.alloc };
    defer v.deinit();
    try v.emitByte(0x00); // locals count (0)
    try v.i32ConstBits(0x40600000); // 3.5
    try v.op(0xbe); // f32.reinterpret_i32
    try v.op(0xa8); // i32.trunc_f32_s → 3
    try v.op(0x0b);
    try b.code(&.{v.buf.items});
    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 3), try inst.callExport("run", &.{}));
}

test "i32.trunc_f32_s traps on NaN" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    var v = Builder{ .alloc = b.alloc };
    defer v.deinit();
    try v.emitByte(0x00); // locals count (0)
    try v.i32ConstBits(0x7FC00000); // NaN
    try v.op(0xbe);
    try v.op(0xa8); // i32.trunc_f32_s → trap
    try v.op(0x0b);
    try b.code(&.{v.buf.items});
    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.InvalidConversion, inst.callExport("run", &.{}));
}

test "i64.trunc_f32_u of 2^40 stays in range" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7e} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    var v = Builder{ .alloc = b.alloc };
    defer v.deinit();
    try v.emitByte(0x00); // locals count (0)
    try v.f32Const(1099511627776.0); // 2^40 (exactly representable in f32)
    try v.op(0xaf); // i64.trunc_f32_u
    try v.op(0x0b);
    try b.code(&.{v.buf.items});
    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 1099511627776), try inst.callExport("run", &.{}));
}

test "start section runs at instantiation and mutates memory" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    // type 0: [] -> []  (start function, stores 42 at addr 0)
    // type 1: [] -> [i32]  (read, loads addr 0)
    try b.types(&.{
        .{ .params = &.{}, .returns = &.{} },
        .{ .params = &.{}, .returns = &.{0x7f} },
    });
    try b.functions(&.{ 0, 1 });
    try b.memory(1);
    try b.exports(&.{.{ .name = "read", .index = 1 }});
    // start body: i32.const 0; i32.const 42; i32.store offset=0 align=2; end
    const start_body = [_]u8{ 0x00, 0x41, 0x00, 0x41, 0x2a, 0x36, 0x02, 0x00, 0x0b };
    // read body: i32.const 0; i32.load offset=0 align=2; end
    const read_body = [_]u8{ 0x00, 0x41, 0x00, 0x28, 0x02, 0x00, 0x0b };
    try b.code(&.{ &start_body, &read_body });
    // start = function 0 (the [] -> [] one)
    try b.start(0);

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    // The store happens during create(); if start did not run, addr 0 is 0.
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();

    try testing.expectEqual(@as(i64, 42), try inst.callExport("read", &.{}));
}

test "start section is optional: instance works without one" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.memory(1);
    try b.exports(&.{.{ .name = "read", .index = 0 }});
    // read body: i32.const 0; i32.load; end  — memory was never written, so 0.
    const read_body = [_]u8{ 0x00, 0x41, 0x00, 0x28, 0x02, 0x00, 0x0b };
    try b.code(&.{&read_body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();

    try testing.expectEqual(@as(i64, 0), try inst.callExport("read", &.{}));
}

test "start function with non-empty type is rejected" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    // type 0: [] -> [i32]  — NOT a valid start signature.
    try b.types(&.{.{ .params = &.{}, .returns = &.{0x7f} }});
    try b.functions(&.{0});
    try b.memory(1);
    const body = [_]u8{ 0x00, 0x41, 0x07, 0x0b }; // i32.const 7; end
    try b.code(&.{&body});
    try b.start(0);

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    // Instantiation must reject the mis-typed start function rather than run it.
    try testing.expectError(error.BadStartType, Instance.create(testing.allocator, &module, null, &.{}, &.{}));
}

test "start function can call another function" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    // type 0: [] -> []  (start)
    // type 1: [] -> []  (helper: stores 99 at addr 0, then returns)
    // type 2: [] -> [i32]  (read)
    try b.types(&.{
        .{ .params = &.{}, .returns = &.{} },
        .{ .params = &.{}, .returns = &.{} },
        .{ .params = &.{}, .returns = &.{0x7f} },
    });
    try b.functions(&.{ 0, 1, 2 });
    try b.memory(1);
    try b.exports(&.{.{ .name = "read", .index = 2 }});
    // start (func 0): call 1; end
    const start_body = [_]u8{ 0x00, 0x10, 0x01, 0x0b };
    // helper (func 1): i32.const 0; i32.const 99; i32.store; end
    const helper_body = [_]u8{ 0x00, 0x41, 0x00, 0x41, 0xe3, 0x00, 0x36, 0x02, 0x00, 0x0b };
    // read (func 2): i32.const 0; i32.load; end
    const read_body = [_]u8{ 0x00, 0x41, 0x00, 0x28, 0x02, 0x00, 0x0b };
    try b.code(&.{ &start_body, &helper_body, &read_body });
    try b.start(0);

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();

    try testing.expectEqual(@as(i64, 99), try inst.callExport("read", &.{}));
}

test "imported mutable global: get returns host value, set updates it" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{
        .{ .params = &.{}, .returns = &.{0x7f} }, // 0: read  ()->i32
        .{ .params = &.{}, .returns = &.{} }, // 1: set7  ()->()
    });
    try b.imports(
        &.{},
        &.{.{ .module = "cordis", .name = "g", .valtype = 0x7f, .mutable = true }},
    );
    try b.functions(&.{ 0, 1 });
    try b.exports(&.{
        .{ .name = "read", .index = 0 },
        .{ .name = "set7", .index = 1 },
    });
    // read: global.get 0; end
    const read_body = [_]u8{ 0x00, 0x23, 0x00, 0x0b };
    // set7: i32.const 7; global.set 0; end
    const set_body = [_]u8{ 0x00, 0x41, 0x07, 0x24, 0x00, 0x0b };
    try b.code(&.{ &read_body, &set_body });

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(
        testing.allocator,
        &module,
        null,
        &.{},
        &.{.{ .value = 42, .mutable = true }},
    );
    defer inst.deinit();

    try testing.expectEqual(@as(i64, 42), try inst.callExport("read", &.{}));
    _ = try inst.callExport("set7", &.{});
    try testing.expectEqual(@as(i64, 7), try inst.callExport("read", &.{}));
}

test "imported immutable global rejects global.set" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }}); // 0: write ()->()
    try b.imports(
        &.{},
        &.{.{ .module = "cordis", .name = "g", .valtype = 0x7f, .mutable = false }},
    );
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "write", .index = 0 }});
    // write: i32.const 1; global.set 0; end
    const body = [_]u8{ 0x00, 0x41, 0x01, 0x24, 0x00, 0x0b };
    try b.code(&.{&body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    // Host also marks it immutable: set must trap.
    var inst = try Instance.create(
        testing.allocator,
        &module,
        null,
        &.{},
        &.{.{ .value = 0, .mutable = false }},
    );
    defer inst.deinit();
    try testing.expectError(error.GlobalImmutable, inst.callExport("write", &.{}));
}

test "missing host global value is a link error" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.imports(
        &.{},
        &.{.{ .module = "cordis", .name = "g", .valtype = 0x7f, .mutable = true }},
    );
    try b.functions(&.{0});
    try b.code(&.{&[_]u8{ 0x00, 0x0b }});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    // No host_globals supplied for the imported global → link error.
    try testing.expectError(error.HostGlobalMissing, Instance.create(testing.allocator, &module, null, &.{}, no_globals));
}

test "defined global: get, set (mutable), and immutable trap" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{
        .{ .params = &.{}, .returns = &.{0x7f} }, // 0: read ()->i32
        .{ .params = &.{}, .returns = &.{} }, // 1: set9 ()->()
    });
    try b.functions(&.{ 0, 1 });
    try b.exports(&.{
        .{ .name = "read", .index = 0 },
        .{ .name = "set9", .index = 1 },
    });
    // Two defined globals: [0] mutable i32 init 5, [1] immutable i32 init 0.
    try b.globals(&.{
        .{ .valtype = 0x7f, .mutable = true, .init = 5 },
        .{ .valtype = 0x7f, .mutable = false, .init = 0 },
    });
    // read: global.get 0; end
    const read_body = [_]u8{ 0x00, 0x23, 0x00, 0x0b };
    // set9: i32.const 9; global.set 0; end
    const set_body = [_]u8{ 0x00, 0x41, 0x09, 0x24, 0x00, 0x0b };
    try b.code(&.{ &read_body, &set_body });

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();

    try testing.expectEqual(@as(i64, 5), try inst.callExport("read", &.{}));
    _ = try inst.callExport("set9", &.{});
    try testing.expectEqual(@as(i64, 9), try inst.callExport("read", &.{}));
    // Writing to the immutable global [1] must trap.
    var b2 = Builder{ .alloc = testing.allocator };
    defer b2.deinit();
    try b2.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b2.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b2.functions(&.{0});
    try b2.globals(&.{.{ .valtype = 0x7f, .mutable = false, .init = 0 }});
    try b2.exports(&.{.{ .name = "w", .index = 0 }});
    // w: i32.const 1; global.set 0; end
    try b2.code(&.{&[_]u8{ 0x00, 0x41, 0x01, 0x24, 0x00, 0x0b }});
    var m2 = try Module.load(testing.allocator, b2.buf.items);
    defer m2.deinit();
    var gi2 = try Instance.create(testing.allocator, &m2, null, &.{}, no_globals);
    defer gi2.deinit();
    try testing.expectError(error.GlobalImmutable, gi2.callExport("w", &.{}));
}

test "imported global occupies index 0 ahead of defined global at index 1" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{
        .{ .params = &.{}, .returns = &.{0x7f} }, // 0: read ()->i32
    });
    // Imported global (index 0) plus a defined global (index 1).
    try b.imports(
        &.{},
        &.{.{ .module = "cordis", .name = "g", .valtype = 0x7f, .mutable = false }},
    );
    try b.globals(&.{.{ .valtype = 0x7f, .mutable = false, .init = 11 }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "read", .index = 0 }});
    // read: global.get 0; global.get 1; i32.add; end  → host(7) + defined(11) = 18
    const read_body = [_]u8{ 0x00, 0x23, 0x00, 0x23, 0x01, 0x6a, 0x0b };
    try b.code(&.{&read_body});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(
        testing.allocator,
        &module,
        null,
        &.{},
        &.{.{ .value = 7, .mutable = false }},
    );
    defer inst.deinit();
    try testing.expectEqual(@as(i64, 18), try inst.callExport("read", &.{}));
}

// ── bulk-memory (memory.copy / memory.fill) ──────────────────────────────

test "memory.copy moves bytes and returns nothing" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    try b.memory(1);
    const seed = [_]u8{ 0xA1, 0xA2, 0xA3, 0xA4 };
    try b.data(&.{.{ .offset = 0, .bytes = &seed }});
    // memory.copy: dest=4, src=0, count=4  (copies 0..3 → 4..7)
    var v = Builder{ .alloc = b.alloc };
    defer v.deinit();
    try v.emitByte(0x00);
    try v.i32Const(4);
    try v.i32Const(0);
    try v.i32Const(4);
    try v.emitByte(0xfc);
    try v.emitByte(0x0a);
    try v.uleb(0);
    try v.uleb(0);
    try v.op(0x0b);
    try b.code(&.{v.buf.items});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    _ = try inst.callExport("run", &.{});
    try testing.expectEqual(@as(u8, 0xA1), inst.memory.items[4]);
    try testing.expectEqual(@as(u8, 0xA2), inst.memory.items[5]);
    try testing.expectEqual(@as(u8, 0xA3), inst.memory.items[6]);
    try testing.expectEqual(@as(u8, 0xA4), inst.memory.items[7]);
}

test "memory.copy handles overlapping source/dest like memmove" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    try b.memory(1);
    const seed = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    try b.data(&.{.{ .offset = 0, .bytes = &seed }});
    // memory.copy: dest=1, src=0, count=3 → expects 11 11 22 33 (forward copy
    // would wrongly give 11 11 11 11)
    var v = Builder{ .alloc = b.alloc };
    defer v.deinit();
    try v.emitByte(0x00);
    try v.i32Const(1);
    try v.i32Const(0);
    try v.i32Const(3);
    try v.emitByte(0xfc);
    try v.emitByte(0x0a);
    try v.uleb(0);
    try v.uleb(0);
    try v.op(0x0b);
    try b.code(&.{v.buf.items});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    _ = try inst.callExport("run", &.{});
    try testing.expectEqual(@as(u8, 0x11), inst.memory.items[0]);
    try testing.expectEqual(@as(u8, 0x11), inst.memory.items[1]);
    try testing.expectEqual(@as(u8, 0x22), inst.memory.items[2]);
    try testing.expectEqual(@as(u8, 0x33), inst.memory.items[3]);
}

test "memory.fill sets count bytes to the value" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    try b.memory(1);
    // memory.fill: dest=0, value=0xAB, count=4
    var v = Builder{ .alloc = b.alloc };
    defer v.deinit();
    try v.emitByte(0x00);
    try v.i32Const(0);
    try v.i32Const(0xAB);
    try v.i32Const(4);
    try v.emitByte(0xfc);
    try v.emitByte(0x0b);
    try v.uleb(0);
    try v.uleb(0);
    try v.op(0x0b);
    try b.code(&.{v.buf.items});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    _ = try inst.callExport("run", &.{});
    try testing.expectEqual(@as(u8, 0xAB), inst.memory.items[0]);
    try testing.expectEqual(@as(u8, 0xAB), inst.memory.items[1]);
    try testing.expectEqual(@as(u8, 0xAB), inst.memory.items[2]);
    try testing.expectEqual(@as(u8, 0xAB), inst.memory.items[3]);
}

test "memory.copy out-of-bounds traps" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    try b.memory(1);
    // memory.copy: dest=65533, src=0, count=4 → end=65537 > 65536 → trap
    var v = Builder{ .alloc = b.alloc };
    defer v.deinit();
    try v.emitByte(0x00);
    try v.i32Const(65533);
    try v.i32Const(0);
    try v.i32Const(4);
    try v.emitByte(0xfc);
    try v.emitByte(0x0a);
    try v.uleb(0);
    try v.uleb(0);
    try v.op(0x0b);
    try b.code(&.{v.buf.items});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.MemoryOutOfBounds, inst.callExport("run", &.{}));
}

test "memory.fill out-of-bounds traps" {
    var b = Builder{ .alloc = testing.allocator };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    try b.memory(1);
    // memory.fill: dest=65535, value=0, count=2 → end=65537 > 65536 → trap
    var v = Builder{ .alloc = b.alloc };
    defer v.deinit();
    try v.emitByte(0x00);
    try v.i32Const(65535);
    try v.i32Const(0);
    try v.i32Const(2);
    try v.emitByte(0xfc);
    try v.emitByte(0x0b);
    try v.uleb(0);
    try v.uleb(0);
    try v.op(0x0b);
    try b.code(&.{v.buf.items});

    var module = try Module.load(testing.allocator, b.buf.items);
    defer module.deinit();
    var inst = try Instance.create(testing.allocator, &module, null, &.{}, no_globals);
    defer inst.deinit();
    try testing.expectError(error.MemoryOutOfBounds, inst.callExport("run", &.{}));
}
