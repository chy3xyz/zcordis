//! Cordis Native — root Context (the kernel object, sections IV, XVI, XXIX).
//!
//! `Context` is the single kernel object that owns every subsystem:
//!
//! ```text
//! Context
//!   ├── io         (std.Io runtime)
//!   ├── root       (the root Scope)
//!   ├── events     (EventBus)
//!   ├── scheduler  (Effect Scheduler)
//!   └── plugins    (PluginManager)
//! ```
//!
//! Plugins, services, events and effects all hang off a `Scope` (usually a
//! plugin's sub-scope), so disposing the context deterministically tears down
//! the entire composition tree.

const std = @import("std");

const IoContext = @import("../io/io.zig").IoContext;
const Scope = @import("scope.zig").Scope;
const Disposable = @import("scope.zig").Disposable;
const EventBus = @import("../event/bus.zig").EventBus;
const Scheduler = @import("../effect/scheduler.zig").Scheduler;
const PluginManager = @import("../plugin/manager.zig").PluginManager;
const Plugin = @import("../plugin/plugin.zig").Plugin;

pub const Context = struct {
    backing_allocator: std.mem.Allocator,
    io_ctx: IoContext,
    events: EventBus,
    scheduler: Scheduler,
    plugins: PluginManager,
    root: *Scope,
    /// Atomic: `child()` may be called from several threads at once.
    scope_counter: std.atomic.Value(u64) = .init(0),

    /// The `Context` owns every subsystem and is heap-allocated so that the
    /// root `Scope`'s `runtime` back-pointer (and every `Io` handle derived
    /// from `self.io()`) points at a *stable* address for the lifetime of the
    /// process. Returning it by value would copy it out of `init`'s stack frame,
    /// leaving those pointers dangling (the bug that caused the original
    /// segfault).
    pub fn init(backing: std.mem.Allocator) !*Context {
        const self = try backing.create(Context);
        self.* = .{
            .backing_allocator = backing,
            .io_ctx = try IoContext.init(backing),
            .events = undefined,
            .scheduler = undefined,
            .plugins = PluginManager.init(backing),
            .root = undefined,
        };
        // Build the event bus and the scheduler against the *stable* `Io` handle
        // (points at `self.io_ctx.threaded`, which is now heap-resident).
        self.events = EventBus.init(backing, self.io());
        self.scheduler = Scheduler.init(backing, self.io());
        const root = try Scope.create(self, null, "root", 1);
        root.activate();
        self.root = root;
        return self;
    }

    pub fn deinit(self: *Context) void {
        const alloc = self.backing_allocator;
        // Reverse-order plugin teardown first (calls plugin.dispose + scope dispose).
        self.plugins.disposeAll();
        // Cancel any remaining effects, then tear down the scope tree.
        self.scheduler.deinit();
        self.root.dispose();
        // The root Scope struct itself lives in `alloc` (not in its own arena),
        // so free it explicitly before destroying the Context.
        alloc.destroy(self.root);
        self.events.deinit();
        self.plugins.deinit();
        self.io_ctx.deinit();
        alloc.destroy(self);
    }

    pub fn io(self: *Context) std.Io {
        return self.io_ctx.io();
    }

    /// Monotonic id source for scopes.
    pub fn nextScopeId(self: *Context) u64 {
        // `.monotonic` suffices: ids need to be unique, not ordered.
        return self.scope_counter.fetchAdd(1, .monotonic) + 1;
    }

    // ── Service convenience ────────────────────────────────────────────
    pub fn provide(
        self: *Context,
        comptime T: type,
        name: []const u8,
        value: T,
        dispose: ?Disposable,
    ) !*T {
        return self.root.provide(T, name, value, dispose);
    }

    pub fn get(self: *Context, comptime T: type, name: []const u8) ?*T {
        return self.root.get(T, name);
    }

    pub fn child(self: *Context, name: []const u8) !*Scope {
        return self.root.child(name);
    }

    // ── Event convenience (on the root scope) ──────────────────────────
    pub fn on(
        self: *Context,
        comptime E: type,
        handler: anytype,
        opts: @import("../event/event.zig").SubscribeOptions,
    ) !Disposable {
        return self.events.subscribe(E, self.root, handler, opts);
    }

    pub fn emit(self: *Context, comptime E: type, payload: *const E) !void {
        return self.events.emit(E, self.root, payload);
    }

    pub fn parallel(self: *Context, comptime E: type, payload: *const E) !void {
        return self.events.parallel(E, self.root, payload);
    }

    pub fn bail(self: *Context, comptime E: type, payload: *const E) !?@import("../event/event.zig").ReturnOf(E) {
        return self.events.bail(E, self.root, payload);
    }

    pub fn serial(self: *Context, comptime E: type, payload: *const E) !?@import("../event/event.zig").ReturnOf(E) {
        return self.events.serial(E, self.root, payload);
    }

    pub fn waterfall(
        self: *Context,
        comptime E: type,
        payload: *const E,
        seed: @import("../event/event.zig").ReturnOf(E),
    ) !@import("../event/event.zig").ReturnOf(E) {
        return self.events.waterfall(E, self.root, payload, seed);
    }

    // ── Plugin convenience ─────────────────────────────────────────────
    pub fn load(self: *Context, plugin: Plugin) !void {
        try self.plugins.load(plugin);
    }

    pub fn start(self: *Context) !void {
        try self.plugins.start(self);
    }
};
