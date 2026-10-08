//! Cordis Native — dependency graph (section XIV).
//!
//! A directed graph where an edge `from → to` means "`from` depends on `to`"
//! (so `to` must be initialized first). `topoSort` returns a valid init order
//! or `CordisError.DependencyCycle` if the graph is not a DAG.

const std = @import("std");
const CordisError = @import("../core/error.zig").CordisError;

pub const Graph = struct {
    alloc: std.mem.Allocator,
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    /// node index → list of dependency node indices.
    edges: std.AutoHashMapUnmanaged(usize, std.ArrayListUnmanaged(usize)) = .{},

    pub fn init(alloc: std.mem.Allocator) Graph {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Graph) void {
        var it = self.edges.iterator();
        while (it.next()) |e| e.value_ptr.deinit(self.alloc);
        self.edges.deinit(self.alloc);
        self.names.deinit(self.alloc);
    }

    pub fn addNode(self: *Graph, name: []const u8) !usize {
        const idx = self.names.items.len;
        try self.names.append(self.alloc, name);
        try self.edges.put(self.alloc, idx, .empty);
        return idx;
    }

    pub fn addEdge(self: *Graph, from: usize, to: usize) !void {
        const list = self.edges.getPtr(from).?;
        // Skip duplicate edges.
        for (list.items) |d| if (d == to) return;
        try list.append(self.alloc, to);
    }

    /// Kahn-free DFS topological sort with cycle detection. Returns node indices
    /// in initialization order (dependencies first).
    pub fn topoSort(self: *Graph) ![]usize {
        const n = self.names.items.len;
        const color = try self.alloc.alloc(Color, n);
        defer self.alloc.free(color);
        @memset(color, .white);
        var order: std.ArrayListUnmanaged(usize) = .empty;
        errdefer order.deinit(self.alloc);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (color[i] == .white) {
                try self.dfs(i, color, &order);
            }
        }
        return try order.toOwnedSlice(self.alloc);
    }

    fn dfs(self: *Graph, node: usize, color: []Color, order: *std.ArrayList(usize)) !void {
        color[node] = .gray;
        const maybe = self.edges.get(node);
        const deps: []const usize = if (maybe) |d| d.items else &.{};
        for (deps) |dep| {
            switch (color[dep]) {
                .white => try self.dfs(dep, color, order),
                .gray => return CordisError.DependencyCycle, // back-edge → cycle
                .black => {},
            }
        }
        color[node] = .black;
        try order.append(self.alloc, node);
    }

    const Color = enum { white, gray, black };
};
