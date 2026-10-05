const std = @import("std");
const scan = @import("scan.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    var tree = try scan.scanTree(gpa, io, "src");

    var total_edges: usize = 0;
    var total_aliases: usize = 0;
    for (tree.modules.values()) |m| {
        total_edges += m.edges.items.len;
        total_aliases += m.aliases.count();
    }
    std.debug.print("modules={d} total_edges={d} total_aliases={d} rejected={d}\n", .{
        tree.modules.count(), total_edges, total_aliases, tree.rejected.items.len,
    });

    const name = "src/consumer/tree_state.zig";
    const m = tree.get(name).?;
    std.debug.print("{s}: edges={d} aliases={d} pubs={d}\n", .{
        name, m.edges.items.len, m.aliases.count(), m.pub_names.count(),
    });
    for (m.aliases.keys()) |k| std.debug.print("   alias {s} = {s}\n", .{ k, m.aliases.get(k).? });
    for (m.edges.items) |e| {
        const o = scan.ownerOf(&tree, e.target, e.name, 0);
        std.debug.print("   edge {s} -> {s} owner={?s}\n", .{ e.name, e.target, o });
    }
}
