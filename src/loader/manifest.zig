//! Cordis Native — plugin manifest (phase 2).
//!
//! A plugin package describes itself in a small line-based manifest. The
//! loader uses it to register the plugin without compile-time wiring, keeping
//! the door open for a C-ABI / WASM plugin marketplace later.
//!
//! Format:
//! ```text
//! # comment
//! name = my-plugin
//! version = 0.1.0
//! depends_on = logger, config
//! ```
//! `depends_on` may span multiple lines; unknown keys are ignored so older
//! hosts can load newer manifests.

const std = @import("std");

pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
    depends_on: []const []const u8,

    pub fn deinit(self: *Manifest, alloc: std.mem.Allocator) void {
        for (self.depends_on) |d| alloc.free(d);
        alloc.free(self.depends_on);
        alloc.free(self.version);
        alloc.free(self.name);
        self.* = undefined;
    }
};

/// Parse a manifest buffer into an owned `Manifest`. The caller owns all
/// returned strings (free with `Manifest.deinit`).
pub fn parse(alloc: std.mem.Allocator, text: []const u8) !Manifest {
    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var deps: std.ArrayListUnmanaged([]const u8) = .{ .items = &.{}, .capacity = 0 };

    errdefer {
        if (name) |n| alloc.free(n);
        if (version) |v| alloc.free(v);
        for (deps.items) |d| alloc.free(d);
        deps.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidManifestLine;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "name")) {
            if (name != null) return error.DuplicateField;
            name = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "version")) {
            if (version != null) return error.DuplicateField;
            version = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "depends_on")) {
            var it = std.mem.splitScalar(u8, val, ',');
            while (it.next()) |dep| {
                const trimmed = std.mem.trim(u8, dep, " \t");
                if (trimmed.len == 0) continue;
                try deps.append(alloc, try alloc.dupe(u8, trimmed));
            }
        }
        // Unknown keys are ignored (forward-compatible manifests).
    }

    const n = name orelse return error.MissingName;
    const v = version orelse try alloc.dupe(u8, "");
    version = v; // let the errdefer above own it in case `toOwnedSlice` fails
    return .{
        .name = n,
        .version = v,
        .depends_on = try deps.toOwnedSlice(alloc),
    };
}

test "parse a complete manifest" {
    var m = try parse(std.testing.allocator,
        \\name = greet-plugin
        \\version = 0.1.0
        \\depends_on = logger, config
    );
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("greet-plugin", m.name);
    try std.testing.expectEqualStrings("0.1.0", m.version);
    try std.testing.expectEqual(@as(usize, 2), m.depends_on.len);
    try std.testing.expectEqualStrings("logger", m.depends_on[0]);
    try std.testing.expectEqualStrings("config", m.depends_on[1]);
}

test "parse ignores comments, blanks and unknown keys" {
    var m = try parse(std.testing.allocator,
        \\# comment
        \\
        \\name = demo
        \\future-key = whatever
    );
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("demo", m.name);
    try std.testing.expectEqual(@as(usize, 0), m.depends_on.len);
}

test "parse rejects missing name" {
    try std.testing.expectError(error.MissingName, parse(std.testing.allocator, "version = 1.0.0\n"));
}

test "parse rejects duplicate fields" {
    try std.testing.expectError(
        error.DuplicateField,
        parse(std.testing.allocator, "name = a\nname = b\n"),
    );
}
