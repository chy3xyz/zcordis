//! Cordis Native — dependency resolver (sections XIV–XV).
//!
//! Builds a `Graph` from a slice of `Plugin`s and returns the init order. A
//! plugin's `depends_on` entries must name other loaded plugins, otherwise
//! `MissingDependency` is raised.

const std = @import("std");
const Graph = @import("dependency.zig").Graph;
const Plugin = @import("plugin.zig").Plugin;

pub const CordisError = @import("../core/error.zig").CordisError;

/// Resolve `plugins` into an initialization order (dependency indices first).
/// Returns a slice of plugin indices; caller frees with `alloc`.
pub fn resolve(alloc: std.mem.Allocator, plugins: []const Plugin) ![]usize {
    var g = Graph.init(alloc);
    defer g.deinit();

    for (plugins) |p| _ = try g.addNode(p.name);

    for (plugins, 0..) |p, i| {
        for (p.depends_on) |dep_name| {
            const j = findIndex(plugins, dep_name) orelse return CordisError.MissingDependency;
            try g.addEdge(i, j);
        }
    }

    return try g.topoSort();
}

fn findIndex(plugins: []const Plugin, name: []const u8) ?usize {
    for (plugins, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) return i;
    }
    return null;
}
