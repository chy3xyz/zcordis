//! Cordis Native — cancellation token (section XI).
//!
//! A cooperative cancellation flag shared between the scheduler and a running
//! task. Long effects should poll `isCancelled` in their loop to exit promptly
//! when the owning scope is disposed.

const std = @import("std");

pub const Token = struct {
    flag: *std.atomic.Value(bool),

    pub fn isCancelled(self: Token) bool {
        return self.flag.load(.seq_cst);
    }
};

/// Build a `Token` that views an effect's cancellation flag.
pub fn fromEffect(eff: *Effect) Token {
    return .{ .flag = &eff.cancelled };
}

const Effect = @import("effect.zig").Effect;
