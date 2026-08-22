//! Cordis Native — service registry container (section V).
//!
//! Thin container type used by `Scope`. The actual typed provide/get logic
//! lives in `service.zig`; this module exists so the layout mirrors `dev.md`
//! (a `ServiceRegistry` abstraction distinct from the `Service` value type).

const std = @import("std");
const svc = @import("service.zig");

pub const Entry = svc.Entry;
pub const ServiceMap = svc.ServiceMap;
pub const nameKey = svc.nameKey;
pub const provideIn = svc.provideIn;
pub const getFrom = svc.getFrom;

/// A `Scope`'s service registry. Built on a hash map keyed by name, with
/// type-hash validation for compile-time-safe `get(T)`.
pub const ServiceRegistry = struct {
    map: ServiceMap = .{},

    pub fn provide(
        self: *ServiceRegistry,
        alloc: std.mem.Allocator,
        comptime T: type,
        name: []const u8,
        value: T,
        dispose: ?Disposable,
    ) !*T {
        return provideIn(alloc, &self.map, T, name, value, dispose);
    }

    pub fn get(self: ServiceRegistry, comptime T: type, name: []const u8) ?*T {
        return getFrom(T, self.map, name);
    }

    pub fn deinit(self: *ServiceRegistry, alloc: std.mem.Allocator) void {
        self.map.deinit(alloc);
    }
};

const Disposable = @import("../core/scope.zig").Disposable;
