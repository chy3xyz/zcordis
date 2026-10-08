//! Cordis Native — dynamically loaded module (phase 2).
//!
//! Thin wrapper over `std.DynLib`: the host side of the C-ABI plugin contract.
//! A `Module` holds one open shared library; `lookup` resolves exported symbols
//! (the plugin's manifest + init/dispose entry points).

const std = @import("std");

pub const Module = struct {
    lib: std.DynLib,

    pub fn open(path: []const u8) !Module {
        return .{ .lib = try std.DynLib.open(path) };
    }

    pub fn deinit(self: *Module) void {
        self.lib.close();
    }

    /// Resolve an exported symbol as type `T` (a function or data pointer), or
    /// `null` if the library does not export it.
    pub fn lookup(self: *Module, comptime T: type, name: [:0]const u8) ?T {
        return self.lib.lookup(T, name);
    }
};

test "opening a missing library fails" {
    const path = switch (builtin.target.os.tag) {
        .macos, .ios, .tvos, .watchos => "no_such_plugin.dylib",
        .linux, .freebsd, .netbsd, .openbsd => "no_such_plugin.so",
        else => return error.SkipZigTest,
    };
    try std.testing.expectError(error.FileNotFound, Module.open(path));
}

const builtin = @import("builtin");
