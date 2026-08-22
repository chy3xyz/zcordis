//! Cordis Native — I/O runtime wrapper.
//!
//! Per the design notes (sections XII–XIII), Cordis Native is built *around*
//! `std.Io` rather than inventing its own async runtime. This module owns a
//! `std.Io.Threaded` instance for the whole Cordis process and exposes it to
//! plugins/services via `Context.io`.
//!
//! The wrapped `Io` drives the Effect Scheduler (section XIII) and any
//! service that needs real async file/network/timer I/O.

const std = @import("std");

pub const IoContext = struct {
    threaded: std.Io.Threaded,
    /// Backing allocator used to create the threaded runtime. Retained so we
    /// can cleanly `deinit` the runtime.
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !IoContext {
        const threaded = std.Io.Threaded.init(allocator, .{
            .argv0 = .empty,
            .environ = .empty,
        });
        return .{
            .threaded = threaded,
            .allocator = allocator,
        };
    }

    /// The process-global async I/O handle. Pass this to `std.Io` operations
    /// (files, sockets, timers) used by plugins.
    pub fn io(self: *IoContext) std.Io {
        return self.threaded.io();
    }

    pub fn deinit(self: *IoContext) void {
        self.threaded.deinit();
    }
};

test "io context boots and exposes an Io handle" {
    var ctx = try IoContext.init(std.testing.allocator);
    defer ctx.deinit();
    // Just prove the handle is non-null-ish and usable for a no-op.
    _ = ctx.io();
}
