//! Cordis Native — Scope (the soul of Cordis, sections VII–VIII, XXIII).
//!
//! A `Scope` is Cordis' unit of **spatiotemporal composition**:
//!
//! * **Space** — it owns services, effects and event listeners in an isolated
//!   arena, so disposing it frees exactly what it created.
//! * **Time** — it carries a deterministic lifecycle
//!   (`created → active → disposing → disposed`) instead of relying on a GC.
//! * **Causality** — event listeners and effects registered on a scope are
//!   automatically revoked when the scope dies, eliminating the listener/timer
//!   leaks that plague GC-based frameworks.
//!
//! Scopes form a tree: `child` creates a sub-scope that sees its parent's
//! services but not its siblings'. This is the backbone of plugin isolation.

const std = @import("std");
const Effect = @import("../effect/effect.zig").Effect;

pub const State = enum {
    created,
    active,
    disposing,
    disposed,
};

/// A cleanup callback plus its userdata. Stored in a scope's disposable list
/// and invoked (in reverse registration order) when the scope disposes.
pub const Disposable = struct {
    ctx: *anyopaque,
    call: *const fn (*anyopaque) void,
};

/// Build a `Disposable` that calls `call(target)` on cleanup. `target` must
/// outlive the disposable (typically it lives in the same scope arena).
pub fn makeDisposable(
    comptime T: type,
    target: *T,
    comptime call: *const fn (*T) void,
) Disposable {
    const wrapper = struct {
        fn run(ptr: *anyopaque) void {
            call(@as(*T, @ptrCast(@alignCast(ptr))));
        }
    }.run;
    return .{ .ctx = target, .call = wrapper };
}

/// Ordered list of cleanup callbacks. `clear` runs them in reverse order so
/// teardown mirrors construction (last-registered, first-destroyed).
pub const DisposableList = struct {
    items: std.ArrayListUnmanaged(Disposable) = .{ .items = &.{}, .capacity = 0 },

    pub fn push(self: *DisposableList, alloc: std.mem.Allocator, d: Disposable) !void {
        try self.items.append(alloc, d);
    }

    pub fn remove(self: *DisposableList, alloc: std.mem.Allocator, d: Disposable) void {
        _ = alloc;
        for (self.items.items, 0..) |item, i| {
            if (item.ctx == d.ctx and item.call == d.call) {
                _ = self.items.orderedRemove(i);
                return;
            }
        }
    }

    pub fn clear(self: *DisposableList, alloc: std.mem.Allocator) void {
        while (self.items.items.len > 0) {
            const d = self.items.items[self.items.items.len - 1];
            self.items.items.len -= 1;
            d.call(d.ctx);
        }
        self.items.deinit(alloc);
        self.items = .{ .items = &.{}, .capacity = 0 };
    }
};

pub const Scope = struct {
    id: u64,
    name: []const u8,
    parent: ?*Scope,
    runtime: *Context,
    state: State = .created,
    /// This scope's private allocator. Freed wholesale on dispose, so every
    /// service/effect created here is reclaimed deterministically.
    arena: std.heap.ArenaAllocator,
    children: std.ArrayListUnmanaged(*Scope) = .{ .items = &.{}, .capacity = 0 },
    disposables: DisposableList = .{},
    services: service.ServiceMap,

    /// Allocate a new child (or root) scope. The *struct* lives in the
    /// parent's arena; the scope's own `arena` is backed by the runtime
    /// allocator, so disposing the child frees only its own allocations.
    pub fn create(
        runtime: *Context,
        parent: ?*Scope,
        name: []const u8,
        id: u64,
    ) !*Scope {
        const parent_arena = if (parent) |p| p.arena.allocator() else runtime.backing_allocator;
        const self = try parent_arena.create(Scope);
        self.* = Scope{
            .id = id,
            .name = undefined,
            .parent = parent,
            .runtime = runtime,
            .arena = std.heap.ArenaAllocator.init(runtime.backing_allocator),
            .services = .{},
        };
        // Dup the name into THIS scope's own arena, so it is reclaimed by
        // `arena.deinit()` along with everything else the scope owns. (For a
        // root scope the struct lives in `backing`, so without this the name
        // would leak — `Context.deinit` only frees the struct itself.)
        self.name = try self.arena.allocator().dupe(u8, name);
        if (parent) |p| try p.children.append(p.arena.allocator(), self);
        return self;
    }

    /// Allocator for things that should live as long as this scope.
    pub fn alloc(self: *Scope) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Create a sub-scope of this one.
    pub fn child(self: *Scope, name: []const u8) !*Scope {
        const id = self.runtime.nextScopeId();
        return create(self.runtime, self, name, id);
    }

    pub fn isAlive(self: *const Scope) bool {
        return self.state == .created or self.state == .active;
    }

    pub fn activate(self: *Scope) void {
        self.state = .active;
    }

    /// Provide a service value in this scope. Returns the typed pointer that
    /// was stored (allocated in this scope's arena).
    pub fn provide(
        self: *Scope,
        comptime T: type,
        name: []const u8,
        value: T,
        dispose_fn: ?Disposable,
    ) !*T {
        return service.provideIn(self.alloc(), &self.services, T, name, value, dispose_fn);
    }

    /// Resolve a service by walking this scope up to the root. Returns `null`
    /// if no live scope in the chain provides it under `name` with type `T`.
    pub fn get(self: *Scope, comptime T: type, name: []const u8) ?*T {
        var cur: ?*Scope = self;
        while (cur) |scope| {
            if (service.getFrom(T, scope.services, name)) |found| return found;
            cur = scope.parent;
        }
        return null;
    }

    /// Register a cleanup callback directly on this scope.
    pub fn attach(self: *Scope, d: Disposable) !void {
        try self.disposables.push(self.alloc(), d);
    }

    /// Run `setup`, which may return an optional `Disposable` (a teardown
    /// closure). This mirrors Cordis' `ctx.effect(() => dispose)`. The returned
    /// disposable is tracked by the scope and runs on dispose.
    pub fn effect(
        self: *Scope,
        comptime Setup: type,
        setup: *const fn (*Scope) anyerror!?Disposable,
    ) !void {
        _ = Setup;
        if (!self.isAlive()) return CordisError.InactiveEffect;
        const d = try setup(self);
        if (d) |disp| try self.attach(disp);
    }

    /// True if `self` is `ancestor` or lives below it in the tree. Used to
    /// implement scope-aware event filtering.
    pub fn isWithin(self: *const Scope, ancestor: *const Scope) bool {
        var cur: ?*const Scope = self;
        while (cur) |c| {
            if (c == ancestor) return true;
            cur = c.parent;
        }
        return false;
    }

    /// Spawn a cancellable background effect owned by this scope. The task is
    /// automatically cancelled when the scope is disposed.
    pub fn spawn(
        self: *Scope,
        comptime Ctx: type,
        ctx: *Ctx,
        comptime run: *const fn (*Ctx, *Effect) anyerror!void,
    ) !*Effect {
        return self.runtime.scheduler.spawn(Ctx, self, ctx, run);
    }

    // ── Event convenience (scoped to this scope) ─────────────────────────
    pub fn on(
        self: *Scope,
        comptime E: type,
        handler: anytype,
        opts: SubscribeOptions,
    ) !Disposable {
        return self.runtime.events.subscribe(E, self, handler, opts);
    }

    pub fn emit(self: *Scope, comptime E: type, payload: *const E) !void {
        return self.runtime.events.emit(E, self, payload);
    }

    pub fn parallel(self: *Scope, comptime E: type, payload: *const E) !void {
        return self.runtime.events.parallel(E, self, payload);
    }

    pub fn bail(self: *Scope, comptime E: type, payload: *const E) !?ReturnOf(E) {
        return self.runtime.events.bail(E, self, payload);
    }

    pub fn serial(self: *Scope, comptime E: type, payload: *const E) !?ReturnOf(E) {
        return self.runtime.events.serial(E, self, payload);
    }

    pub fn waterfall(
        self: *Scope,
        comptime E: type,
        payload: *const E,
        seed: ReturnOf(E),
    ) !ReturnOf(E) {
        return self.runtime.events.waterfall(E, self, payload, seed);
    }

    /// Dispose this scope and everything beneath it, in deterministic order:
    /// children → service teardowns → attached disposables → free arena.
    pub fn dispose(self: *Scope) void {
        if (self.state == .disposed) return;
        self.state = .disposing;

        // 1. Recurse into children (reverse = last-created, first-destroyed).
        while (self.children.items.len > 0) {
            const child_scope = self.children.items[self.children.items.len - 1];
            self.children.items.len -= 1;
            child_scope.dispose();
        }

        // 2. Cancel this scope's effects (event listeners are revoked via the
        //    disposables list below, since each subscription is scope-owned).
        self.runtime.scheduler.cancelForScope(self);

        // 3. Run service teardown closures.
        var svc_iter = self.services.iterator();
        while (svc_iter.next()) |entry| {
            if (entry.value_ptr.dispose) |d| d.call(d.ctx);
        }

        // 4. Run attached disposables in reverse registration order.
        self.disposables.clear(self.alloc());

        // 5. Free everything this scope allocated, then mark disposed.
        self.arena.deinit();
        self.state = .disposed;
    }
};

const service = @import("../service/service.zig");
const CordisError = @import("error.zig").CordisError;
const ReturnOf = @import("../event/event.zig").ReturnOf;
const SubscribeOptions = @import("../event/event.zig").SubscribeOptions;

test "scope hierarchy: child sees parent services, not siblings" {
    var ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Db = struct { n: u32 };
    _ = try ctx.root.provide(Db, "db", .{ .n = 7 }, null);

    const child = try ctx.root.child("child");
    try std.testing.expectEqual(@as(?*Db, null), child.get(Db, "db2"));
    try std.testing.expectEqual(@as(u32, 7), child.get(Db, "db").?.n);

    // A sibling does not see the child's services.
    const sibling = try ctx.root.child("sibling");
    _ = try sibling.provide(Db, "secret", .{ .n = 1 }, null);
    try std.testing.expectEqual(@as(?*Db, null), child.get(Db, "secret"));

    child.dispose();
    sibling.dispose();
}

test "scope dispose revokes services and runs disposables" {
    var ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    var leaked: bool = true;
    const Child = struct {
        fn cleanup(leaked_ptr: *bool) void {
            leaked_ptr.* = false;
        }
    };
    const s = try ctx.root.child("s");
    _ = try s.attach(makeDisposable(bool, &leaked, Child.cleanup));
    try std.testing.expect(leaked);
    s.dispose();
    try std.testing.expect(!leaked);
    try std.testing.expect(!s.isAlive());
}

const Context = @import("context.zig").Context;
