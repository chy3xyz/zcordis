//! Cordis Native — plugin manager (sections XVIII, XX).
//!
//! Loads plugins, resolves their dependency graph, and starts them in
//! topological order. Each plugin gets its own scope; unloading runs the
//! plugins' `dispose` callbacks in reverse order and then disposes the scopes.

const std = @import("std");
const Scope = @import("../core/scope.zig").Scope;
const Plugin = @import("plugin.zig").Plugin;
const resolver = @import("resolver.zig");

pub const Context = @import("../core/context.zig").Context;

pub const PluginManager = struct {
    alloc: std.mem.Allocator,
    plugins: std.ArrayListUnmanaged(Plugin) = .empty,
    /// Per-plugin scopes, aligned with `order` (initialization order).
    scopes: std.ArrayListUnmanaged(*Scope) = .empty,
    order: std.ArrayListUnmanaged(usize) = .empty,

    pub fn init(alloc: std.mem.Allocator) PluginManager {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *PluginManager) void {
        self.plugins.deinit(self.alloc);
        self.scopes.deinit(self.alloc);
        self.order.deinit(self.alloc);
    }

    pub fn load(self: *PluginManager, plugin: Plugin) !void {
        try self.plugins.append(self.alloc, plugin);
    }

    /// Resolve dependencies and initialize all loaded plugins in order.
    pub fn start(self: *PluginManager, ctx: *Context) !void {
        const order = try resolver.resolve(self.alloc, self.plugins.items);
        defer self.alloc.free(order);

        for (order) |idx| {
            const plugin = self.plugins.items[idx];
            const scope = try ctx.root.child(plugin.name);
            scope.activate();
            try plugin.init(scope);
            try self.scopes.append(self.alloc, scope);
            try self.order.append(self.alloc, idx);
        }
    }

    /// Tear down all plugins in reverse initialization order.
    pub fn disposeAll(self: *PluginManager) void {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = self.scopes.items[i];
            const plugin = self.plugins.items[self.order.items[i]];
            if (plugin.dispose) |dispose| dispose(scope);
            scope.dispose();
        }
        self.scopes.deinit(self.alloc);
        self.scopes = .empty;
        self.order.deinit(self.alloc);
        self.order = .empty;
    }
};
