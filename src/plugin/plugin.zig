//! Cordis Native — plugin (sections VI, XVIII, XX).
//!
//! A plugin is a named unit that declares its dependencies, then runs an `init`
//! against a fresh `Scope`. Everything the plugin registers (services, events,
//! effects) lives in that scope and is torn down deterministically when the
//! plugin is unloaded — no manual cleanup required.

const std = @import("std");
const Scope = @import("../core/scope.zig").Scope;

pub const Plugin = struct {
    name: []const u8,
    /// Names of other plugins that must finish `init` before this one starts.
    depends_on: []const []const u8 = &.{},
    /// Service names this plugin contributes (documentation / ordering aid).
    provides: []const []const u8 = &.{},
    init: *const fn (*Scope) anyerror!void,
    dispose: ?*const fn (*Scope) void = null,

    /// Convenience constructor.
    pub fn make(
        name: []const u8,
        init: *const fn (*Scope) anyerror!void,
    ) Plugin {
        return .{ .name = name, .init = init };
    }
};
