const std = @import("std");
const consumer = @import("consumer/root.zig");
const schema = @import("schema/root.zig");
const atspi = @import("adapters/atspi/node.zig");
const app_context = @import("adapters/atspi/app_context.zig");
const windows_util = @import("adapters/windows/util.zig");

pub fn main(init: std.process.Init) SmokeError!void {
    const snapshot = blk: {
        var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
        defer std.debug.assert(debug_allocator.deinit() == .ok);
        break :blk try collectSnapshot(debug_allocator.allocator());
    };
    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &stdout_writer.interface;
    try writer.writeAll("PASS cache preorder=[");
    const entry_count_max = snapshot.ids.len;
    for (0..entry_count_max) |index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}:{d}", .{ snapshot.adapters[index], snapshot.ids[index] });
    }
    try writer.writeAll("] indices=[");
    for (0..entry_count_max) |index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{snapshot.indices[index]});
    }
    try writer.writeAll("] children=[");
    for (0..entry_count_max) |index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{snapshot.counts[index]});
    }
    try writer.writeAll("] focused=[");
    for (0..entry_count_max) |index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{@intFromBool(snapshot.focused[index])});
    }
    try writer.print("] name=\"{s}\" description=\"{s}\" toolkit_utf16=[", .{
        &snapshot.name, &snapshot.description,
    });
    const unit_count_max = snapshot.toolkit.len;
    for (0..unit_count_max) |index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{snapshot.toolkit[index]});
    }
    try writer.print("] aria=\"{s}\"\n", .{&snapshot.aria});
    try writer.flush();
}

const SmokeError = consumer.tree.UpdateError || atspi.NodeError ||
    windows_util.DescriptionError || std.Io.Writer.Error || error{SnapshotMismatch};

const Snapshot = struct {
    adapters: [6]usize,
    ids: [6]u64,
    indices: [6]i32,
    counts: [6]i32,
    focused: [6]bool,
    name: [14]u8,
    description: [20]u8,
    toolkit: [7]u16,
    aria: [22]u8,
};

fn collectSnapshot(gpa: std.mem.Allocator) SmokeError!Snapshot {
    var first = try makeTree(gpa, true);
    defer first.deinit();
    var second = try makeTree(gpa, false);
    defer second.deinit();
    var app = try app_context.AppContext.init(gpa, "Correction smoke");
    defer app.deinit();
    const first_context = makeContext(gpa, &app, first.stateOf());
    const second_context = makeContext(gpa, &app, second.stateOf());
    try app.pushAdapter(7, &first_context);
    try app.pushAdapter(11, &second_context);
    var output = try atspi.PlatformRoot.init(&app).mapDescendantCacheNodes(
        gpa,
        mapDescendantCacheNodes_release_callback,
        mapDescendantCacheNodes_callback,
    );
    defer {
        const entry_count_max = output.items.len;
        for (output.items[0..entry_count_max]) |*entry| {
            mapDescendantCacheNodes_release_callback(gpa, entry);
        }
        output.deinit(gpa);
    }

    const expected_ids = [_]u64{ 0, 2, 5, 0, 2, 5 };
    const expected_indices = [_]i32{ 0, 0, 1, 1, 0, 1 };
    const expected_counts = [_]i32{ 2, 0, 0, 2, 0, 0 };
    try require(output.items.len == expected_ids.len);
    var snapshot: Snapshot = undefined;
    const entry_count_max = expected_ids.len;
    for (output.items[0..entry_count_max], 0..) |entry, index| {
        const expected_id: consumer.tree_index.FullNodeId = .init(
            .{ .value = expected_ids[index] },
            .init(0),
        );
        try require(std.meta.eql(expected_id, entry.id));
        try require(entry.adapter_id == @as(usize, if (index < 3) 7 else 11));
        try require(entry.index_in_parent == expected_indices[index]);
        try require(entry.child_count == expected_counts[index]);
        try require(entry.states.contains(.focused) == (index == 1));
        if (index == 0 or index == 3) {
            try require(entry.parent == .root);
            try require(entry.states.contains(.active) == (index == 0));
        } else {
            try require(entry.parent.eql(.{ .node = .init(.{ .value = 0 }, .init(0)) }));
        }
        snapshot.adapters[index] = entry.adapter_id;
        snapshot.ids[index] = entry.id.local.value;
        snapshot.indices[index] = entry.index_in_parent;
        snapshot.counts[index] = entry.child_count;
        snapshot.focused[index] = entry.states.contains(.focused);
    }
    // The collector's temporary storage is gone; these buffers must still be owned by output.
    try require(std.mem.eql(u8, output.items[1].name, "Retained image"));
    try require(std.mem.eql(u8, output.items[4].name, "Retained image"));
    try require(std.mem.eql(u8, output.items[1].description, "Retained description"));
    @memcpy(&snapshot.name, output.items[1].name);
    @memcpy(&snapshot.description, output.items[1].description);

    const toolkit = try windows_util.toolkitDescription(gpa, first.stateOf());
    defer gpa.free(toolkit);
    const expected_units = [_]u16{ 0xe9, 0xd83d, 0xde00, 32, 0x3b2, 46, 49 };
    try require(std.mem.eql(u16, toolkit, &expected_units));
    @memcpy(&snapshot.toolkit, toolkit);

    var properties = windows_util.AriaProperties.init();
    defer properties.deinit(gpa);
    try require(!properties.hasProperties());
    try windows_util.AriaProperties.writeBoolProperty(gpa, &properties, "disabled", false);
    try windows_util.AriaProperties.writeUsizeProperty(gpa, &properties, "level", 7);
    try require(properties.hasProperties());
    const aria = try windows_util.AriaProperties.toOwnedSlice(gpa, &properties);
    defer gpa.free(aria);
    try require(!properties.hasProperties());
    try require(std.mem.eql(u8, aria, "disabled=false;level=7"));
    @memcpy(&snapshot.aria, aria);
    return snapshot;
}

fn makeTree(gpa: std.mem.Allocator, focused: bool) consumer.tree.UpdateError!consumer.tree.Tree {
    var update: schema.TreeUpdate = .{};
    var update_transferred = false;
    errdefer if (!update_transferred) update.deinit(gpa);
    const roles = [_]schema.Role{
        .window, .generic_container, .image, .group, .button, .button,
    };
    const node_count_max = roles.len;
    for (roles[0..node_count_max], 0..) |role, index| {
        var data = schema.Node.init(gpa, role);
        var data_transferred = false;
        errdefer if (!data_transferred) data.deinit();
        switch (index) {
            0 => {
                try schema.ids_props.setChildren(&data.properties, &.{
                    .{ .value = 1 }, .{ .value = 3 }, .{ .value = 5 },
                });
                try schema.strings.setLabel(&data.properties, "Window");
            },
            1 => try schema.ids_props.setChildren(&data.properties, &.{.{ .value = 2 }}),
            2 => {
                try schema.strings.setLabel(&data.properties, "Retained image");
                try schema.strings.setDescription(&data.properties, "Retained description");
            },
            3 => {
                schema.flags.setHidden(&data.flags, true);
                try schema.ids_props.setChildren(&data.properties, &.{.{ .value = 4 }});
            },
            else => {},
        }
        // Both consuming calls release their inputs on failure as well as on success.
        data_transferred = true;
        try update.pushNode(gpa, .{ .value = @intCast(index) }, data);
    }
    var info = schema.TreeInfo.init(.{ .value = 0 });
    info.toolkit_name = "é😀";
    info.toolkit_version = "β.1";
    update.tree = info;
    update.focus = .{ .value = 2 };
    update_transferred = true;
    return consumer.tree.Tree.init(gpa, update, focused);
}

fn makeContext(
    gpa: std.mem.Allocator,
    app: *const app_context.AppContext,
    state: *const consumer.tree_state.TreeState,
) app_context.NodeContext {
    return .{
        .state = state,
        .app = app,
        .bounds = .init(
            schema.rectInit(100, 200, 300, 400),
            schema.rectInit(105, 210, 295, 395),
        ),
        .sink = null,
        .gpa = gpa,
    };
}

fn mapDescendantCacheNodes_callback(
    _: std.mem.Allocator,
    entry: atspi.CacheNode,
) error{}!atspi.CacheNode {
    return entry;
}

fn mapDescendantCacheNodes_release_callback(
    gpa: std.mem.Allocator,
    entry: *atspi.CacheNode,
) void {
    entry.deinit(gpa);
}

fn require(condition: bool) error{SnapshotMismatch}!void {
    if (!condition) return error.SnapshotMismatch;
}
