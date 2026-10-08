//! Single-owner AT-SPI path snapshots from the application's live tree registry.
//! This module owns no bus, clock, or I/O. `sync` publishes a complete snapshot
//! and retains interface deltas until the pump calls `clearChanges`.
//! Descendants use common `node.rs:1930-1971`. Interface deltas match common
//! `adapter.rs:308-314`. Paths use Unix `atspi/object_id.rs:33-44`.
const std = @import("std");
const app_context = @import("app_context.zig");
const node = @import("node.zig");
const object_id = @import("object_id.zig");
const wire = @import("wire.zig");
const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const window_bounds = @import("window_bounds.zig");
const h = @import("interfaces/root.zig");
const dbus = @import("dbus.zig");

/// A dispatch callback owns the request on success and every error path.
pub const ActionDeliveryError = error{
    OutOfMemory, InteriorNul, CallbackFailed, Closed, Reentrant,
};

/// Runs on the owner pump. The callback must not reenter dispatch.
pub const ActionSink = struct {
    /// Borrowed callback state. It must outlive this installed sink.
    context: ?*anyopaque,
    /// Takes ownership of the request on success and on every error path.
    raise: *const fn (?*anyopaque, schema.ActionRequest) ActionDeliveryError!void,
};

/// One atomic UTF-8 replacement in Unicode scalar positions. The callback
/// borrows this request and replacement only through its return.
pub const EditableTextRequest = struct {
    target: consumer.tree_index.FullNodeId,
    start_scalar: u32,
    end_scalar: u32,
    replacement_utf8: []const u8,
};

/// Optional host capability, separate from stock schema ActionData. Runs after
/// the query releases tree borrows. False rejects the edit; it is not success.
pub const EditableTextSink = struct {
    context: ?*anyopaque,
    raise: *const fn (?*anyopaque, *const EditableTextRequest) ActionDeliveryError!bool,
};

/// A snapshot handle. `node` borrows its registered context, or is null for constants.
pub const Entry = struct {
    id: object_id.ObjectId,
    interfaces: wire.InterfaceSet,
    node: ?node.PlatformNode = null,
};

/// Only changed interface bits. The register owns `path` until `clearChanges`.
pub const Change = struct {
    path: []const u8,
    id: object_id.ObjectId,
    added: wire.InterfaceSet,
    removed: wire.InterfaceSet,
};

/// Failure leaves both the previous snapshot and pending deltas unchanged.
pub const SyncError = node.NodeError || std.mem.Allocator.Error || error{RegisterLimit};

/// The pump must serialize registry updates, lookup, sync, and teardown.
/// This value owns its map keys and delta paths. Copies are not independent owners.
/// The allocator and application must outlive this value. Do not mutate `paths`.
pub const Register = struct {
    gpa: std.mem.Allocator,
    app: *app_context.AppContext,
    /// Borrowed connection identity, supplied after Hello.
    bus_name: []const u8 = "",
    /// Borrowed machine identity, supplied by the lifecycle owner.
    machine_id: []const u8 = "",
    /// Borrowed registry response, supplied after Embed.
    desktop: h.ObjectReference = .{},
    /// Null means no action callback is installed.
    sink: ?ActionSink = null,
    /// Null preserves stock unsupported positioned editing behavior.
    editable_text_sink: ?EditableTextSink = null,
    /// Dispatch and the transport writer must use the same configured limits.
    limits: dbus.Limits = .{},
    /// Owned keys and snapshot entries. Iterators expire at sync or reset.
    paths: std.StringHashMapUnmanaged(Entry) = .empty,
    /// Pending deltas accumulate across sync calls until clearChanges.
    changes: std.ArrayList(Change) = .empty,

    /// Bounds include the root/cache and all raw tree nodes before filtering.
    pub const max_objects = 65536;
    /// The pump must consume deltas before this pending-change limit is reached.
    pub const max_changes = 65536;

    /// Allocates nothing. Root and cache paths are immediately available.
    pub fn init(gpa: std.mem.Allocator, app: *app_context.AppContext) Register {
        return .{ .gpa = gpa, .app = app };
    }

    /// Releases owned map and delta storage once. Borrowed fields are not released.
    pub fn deinit(self: *Register) void {
        self.reset();
        self.* = undefined;
    }

    /// Drops the snapshot and pending deltas, retaining attachment metadata.
    /// Root and cache remain available without allocating another snapshot.
    pub fn reset(self: *Register) void {
        releasePaths(self.gpa, &self.paths);
        self.clearChanges();
        self.changes.deinit(self.gpa);
        self.changes = .empty;
    }

    /// Releases pending delta paths. Snapshot iterators remain valid.
    pub fn clearChanges(self: *Register) void {
        for (self.changes.items) |change| releasePath(self.gpa, change.path);
        self.changes.clearRetainingCapacity();
    }

    /// Returns current interfaces, not a stale cached optional mask.
    /// Removed adapters are checked before any stored context pointer is followed.
    pub fn lookup(self: *const Register, path: []const u8) ?Entry {
        if (constantEntry(path)) |entry| return entry;
        const cached = self.paths.get(path) orelse return null;
        const pair = switch (cached.id) {
            .node => |value| value,
            else => return null,
        };
        const adapter_count_max = self.app.adapters.items.len;
        for (self.app.adapters.items[0..adapter_count_max]) |adapter| {
            if (adapter.id != pair.adapter) continue;
            const platform = adapter.context.platformNode(adapter.id, pair.node);
            const interfaces = platform.interfaces() catch return null;
            return .{ .id = cached.id, .interfaces = interfaces, .node = platform };
        }
        return null;
    }

    /// Rebuilds from actual PlatformRoot descendants and commits only after all
    /// allocations and queries succeed. RegisterLimit rejects an oversized tree
    /// or delta queue before publication. Unchanged masks produce no delta.
    pub fn sync(self: *Register) SyncError!void {
        var raw_object_count: usize = 2;
        const adapter_count_max = self.app.adapters.items.len;
        if (adapter_count_max > max_objects - 2) return error.RegisterLimit;
        for (self.app.adapters.items[0..adapter_count_max]) |adapter| {
            const node_count = adapter.context.state.nodes.count();
            if (!adapter.context.state.nodes.contains(adapter.context.rootId())) {
                return error.Defunct;
            }
            if (node_count > max_objects - raw_object_count) return error.RegisterLimit;
            raw_object_count += node_count;
        }

        var next: std.StringHashMapUnmanaged(Entry) = .empty;
        errdefer releasePaths(self.gpa, &next);
        try insertEntry(self.gpa, &next, constantEntry(object_id.root_path).?);
        try insertEntry(self.gpa, &next, constantEntry(object_id.cache_path).?);
        var descendants = try self.app.platformRoot().mapDescendants(
            self.gpa,
            syncNode,
        );
        defer descendants.deinit(self.gpa);
        if (descendants.items.len > max_objects - 2) return error.RegisterLimit;
        for (descendants.items) |platform| {
            try insertEntry(self.gpa, &next, .{
                .id = .{ .node = .{ .adapter = platform.adapter_id, .node = platform.id } },
                .interfaces = try platform.interfaces(),
                .node = platform,
            });
        }

        var delta: std.ArrayList(Change) = .empty;
        defer {
            for (delta.items) |change| releasePath(self.gpa, change.path);
            delta.deinit(self.gpa);
        }
        var next_iterator = next.iterator();
        while (next_iterator.next()) |item| {
            const old: ?Entry = if (self.paths.get(item.key_ptr.*)) |entry|
                entry
            else
                constantEntry(item.key_ptr.*);
            const old_mask: wire.InterfaceSet = if (old) |value| value.interfaces else .empty;
            try self.collectChange(
                &delta,
                item.key_ptr.*,
                item.value_ptr.id,
                old_mask,
                item.value_ptr.interfaces,
            );
        }
        var old_iterator = self.paths.iterator();
        while (old_iterator.next()) |item| {
            if (next.contains(item.key_ptr.*)) continue;
            try self.collectChange(
                &delta,
                item.key_ptr.*,
                item.value_ptr.id,
                item.value_ptr.interfaces,
                .empty,
            );
        }
        try self.changes.ensureUnusedCapacity(self.gpa, delta.items.len);
        self.changes.appendSliceAssumeCapacity(delta.items);
        delta.items.len = 0;
        releasePaths(self.gpa, &self.paths);
        self.paths = next;
    }

    fn collectChange(
        self: *Register,
        delta: *std.ArrayList(Change),
        path: []const u8,
        id: object_id.ObjectId,
        old: wire.InterfaceSet,
        new: wire.InterfaceSet,
    ) SyncError!void {
        const added: wire.InterfaceSet = .{ .bits = new.bits & ~old.bits };
        const removed: wire.InterfaceSet = .{ .bits = old.bits & ~new.bits };
        if (added.bits == 0 and removed.bits == 0) return;
        if (self.changes.items.len > max_changes) return error.RegisterLimit;
        if (delta.items.len >= max_changes - self.changes.items.len) return error.RegisterLimit;
        const owned_path = try self.gpa.dupeZ(u8, path);
        errdefer self.gpa.free(owned_path);
        try delta.append(self.gpa, .{
            .path = owned_path,
            .id = id,
            .added = added,
            .removed = removed,
        });
    }
};

fn constantEntry(path: []const u8) ?Entry {
    var interfaces: wire.InterfaceSet = .empty;
    if (std.mem.eql(u8, path, object_id.root_path)) {
        interfaces.insert(.accessible);
        interfaces.insert(.application);
        return .{ .id = .root, .interfaces = interfaces };
    }
    if (std.mem.eql(u8, path, object_id.cache_path)) {
        interfaces.insert(.cache);
        return .{ .id = .cache, .interfaces = interfaces };
    }
    return null;
}

fn syncNode(platform: node.PlatformNode, _: usize, _: usize) node.PlatformNode {
    return platform;
}

fn insertEntry(
    gpa: std.mem.Allocator,
    paths: *std.StringHashMapUnmanaged(Entry),
    entry: Entry,
) std.mem.Allocator.Error!void {
    const path = try entry.id.path(gpa);
    errdefer gpa.free(path);
    const result = try paths.getOrPut(gpa, path);
    if (result.found_existing) gpa.free(path);
    result.value_ptr.* = entry;
}

fn releasePath(gpa: std.mem.Allocator, path: []const u8) void {
    // ObjectId.path and delta copies include the sentinel in their allocation.
    gpa.free(path.ptr[0..path.len :0]);
}

fn releasePaths(gpa: std.mem.Allocator, paths: *std.StringHashMapUnmanaged(Entry)) void {
    var iterator = paths.keyIterator();
    while (iterator.next()) |path| releasePath(gpa, path.*);
    paths.deinit(gpa);
    paths.* = .empty;
}

fn registerTree(gpa: std.mem.Allocator, role: schema.Role, child: bool) !consumer.tree.Tree {
    var update: schema.TreeUpdate = .{};
    var transferred = false;
    errdefer if (!transferred) update.deinit(gpa);
    var root = schema.Node.init(gpa, .window);
    var root_transferred = false;
    errdefer if (!root_transferred) root.deinit();
    if (child) try schema.ids_props.setChildren(&root.properties, &.{.{ .value = 1 }});
    root_transferred = true;
    try update.pushNode(gpa, .{ .value = 0 }, root);
    if (child) try update.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, role));
    update.tree = schema.TreeInfo.init(.{ .value = 0 });
    update.focus = .{ .value = 0 };
    transferred = true;
    return consumer.tree.Tree.init(gpa, update, true);
}

fn registerContext(state: *const consumer.tree_state.TreeState, app: *app_context.AppContext) app_context.NodeContext {
    return .{
        .state = state,
        .app = app,
        .bounds = window_bounds.WindowBounds.empty,
        .sink = null,
        .gpa = std.testing.allocator,
    };
}

test "register root and cache are live without allocation" {
    var app = try app_context.AppContext.init(std.testing.allocator, null);
    defer app.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var register = Register.init(failing.allocator(), &app);
    defer register.deinit();
    const root = register.lookup(object_id.root_path).?;
    const cache = register.lookup(object_id.cache_path).?;
    try std.testing.expect(root.id == .root);
    try std.testing.expect(root.interfaces.contains(.accessible));
    try std.testing.expect(root.interfaces.contains(.application));
    try std.testing.expect(cache.id == .cache);
    try std.testing.expect(cache.interfaces.contains(.cache));
    try std.testing.expect(register.lookup("/missing") == null);
    try std.testing.expectEqual(@as(u32, 0), register.paths.count());
}

test "register derives dynamic interface XOR and rejects removed live paths" {
    const gpa = std.testing.allocator;
    var button_tree = try registerTree(gpa, .button, true);
    defer button_tree.deinit();
    var image_tree = try registerTree(gpa, .image, true);
    defer image_tree.deinit();
    var empty_tree = try registerTree(gpa, .window, false);
    defer empty_tree.deinit();
    var app = try app_context.AppContext.init(gpa, null);
    defer app.deinit();
    var context = registerContext(button_tree.stateOf(), &app);
    try app.pushAdapter(7, &context);
    var register = Register.init(gpa, &app);
    defer register.deinit();
    try register.sync();
    const path = "/org/a11y/atspi/accessible/7/1";
    const first = register.lookup(path).?;
    try std.testing.expect(first.node != null);
    try std.testing.expect(first.interfaces.contains(.accessible));
    try std.testing.expect(!first.interfaces.contains(.image));
    const old_mask = first.interfaces;
    register.clearChanges();
    try register.sync();
    try std.testing.expectEqual(@as(usize, 0), register.changes.items.len);
    context.state = image_tree.stateOf();
    try std.testing.expect(register.lookup(path).?.interfaces.contains(.image));
    try register.sync();
    const new_mask = register.lookup(path).?.interfaces;
    try std.testing.expectEqual(@as(usize, 1), register.changes.items.len);
    const change = register.changes.items[0];
    try std.testing.expectEqualStrings(path, change.path);
    inline for (std.meta.tags(wire.Interface)) |interface| {
        try std.testing.expectEqual(!old_mask.contains(interface) and new_mask.contains(interface), change.added.contains(interface));
        try std.testing.expectEqual(old_mask.contains(interface) and !new_mask.contains(interface), change.removed.contains(interface));
    }
    context.state = empty_tree.stateOf();
    try std.testing.expect(register.lookup(path) == null);
    try register.sync();
    try std.testing.expectEqual(@as(usize, 2), register.changes.items.len);
    try std.testing.expect(!register.paths.contains(path));
    try std.testing.expectEqualStrings(path, register.changes.items[1].path);
    register.clearChanges();
    app.removeAdapter(7);
    try std.testing.expect(register.lookup("/org/a11y/atspi/accessible/7/0") == null);
    try register.sync();
    try std.testing.expectEqual(@as(u32, 2), register.paths.count());
    try std.testing.expectEqual(@as(usize, 1), register.changes.items.len);
    register.reset();
    try std.testing.expectEqual(@as(u32, 0), register.paths.count());
    try std.testing.expectEqual(@as(usize, 0), register.changes.items.len);
    try std.testing.expect(register.lookup(object_id.root_path) != null);
    try std.testing.expect(register.lookup(object_id.cache_path) != null);
}

fn registerFailAllocation(gpa: std.mem.Allocator) !void {
    const backing = std.testing.allocator;
    var tree = try registerTree(backing, .image, true);
    defer tree.deinit();
    var app = try app_context.AppContext.init(backing, null);
    defer app.deinit();
    var context = registerContext(tree.stateOf(), &app);
    try app.pushAdapter(7, &context);
    var register = Register.init(gpa, &app);
    defer register.deinit();
    register.sync() catch |err| {
        try std.testing.expectEqual(@as(u32, 0), register.paths.count());
        try std.testing.expectEqual(@as(usize, 0), register.changes.items.len);
        try std.testing.expect(register.lookup(object_id.root_path) != null);
        return err;
    };
    try std.testing.expectEqual(@as(u32, 4), register.paths.count());
    try std.testing.expectEqual(@as(usize, 2), register.changes.items.len);
    app.removeAdapter(7);
    register.sync() catch |err| {
        try std.testing.expectEqual(@as(u32, 4), register.paths.count());
        try std.testing.expectEqual(@as(usize, 2), register.changes.items.len);
        return err;
    };
    try std.testing.expectEqual(@as(u32, 2), register.paths.count());
    try std.testing.expectEqual(@as(usize, 4), register.changes.items.len);
}

test "register sync fail N preserves previous snapshot and pending changes" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, registerFailAllocation, .{});
}

test "register rejects oversized registry before snapshot publication" {
    const gpa = std.testing.allocator;
    var tree = try registerTree(gpa, .image, true);
    defer tree.deinit();
    var app = try app_context.AppContext.init(gpa, null);
    defer app.deinit();
    var context = registerContext(tree.stateOf(), &app);
    const adapter_count_max = Register.max_objects / 2;
    for (0..adapter_count_max) |adapter_id| try app.pushAdapter(adapter_id, &context);
    var register = Register.init(gpa, &app);
    defer register.deinit();
    try std.testing.expectError(error.RegisterLimit, register.sync());
    try std.testing.expectEqual(@as(u32, 0), register.paths.count());
    try std.testing.expectEqual(@as(usize, 0), register.changes.items.len);
    try std.testing.expect(register.lookup(object_id.root_path) != null);
}

test "register defunct root leaves snapshot and pending deltas unchanged" {
    const gpa = std.testing.allocator;
    var tree = try registerTree(gpa, .image, true);
    defer tree.deinit();
    var app = try app_context.AppContext.init(gpa, null);
    defer app.deinit();
    var context = registerContext(tree.stateOf(), &app);
    try app.pushAdapter(7, &context);
    var register = Register.init(gpa, &app);
    defer register.deinit();
    try register.sync();
    var defunct: consumer.tree_state.TreeState = .{};
    defer defunct.deinit(gpa);
    context.state = &defunct;
    try std.testing.expect(register.lookup("/org/a11y/atspi/accessible/7/0") == null);
    try std.testing.expectError(error.Defunct, register.sync());
    try std.testing.expectEqual(@as(u32, 4), register.paths.count());
    try std.testing.expectEqual(@as(usize, 2), register.changes.items.len);
}

test "register reset retains borrowed attachment identity and desktop" {
    const gpa = std.testing.allocator;
    var tree = try registerTree(gpa, .image, true);
    defer tree.deinit();
    var app = try app_context.AppContext.init(gpa, null);
    defer app.deinit();
    var context = registerContext(tree.stateOf(), &app);
    try app.pushAdapter(7, &context);
    var register = Register.init(gpa, &app);
    defer register.deinit();
    register.bus_name = ":1.23";
    register.machine_id = "0123456789abcdef0123456789abcdef";
    register.desktop = .{ .bus_name = ":1.1", .path = object_id.root_path };
    try register.sync();
    register.reset();
    try std.testing.expectEqualStrings(":1.23", register.bus_name);
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef",
        register.machine_id,
    );
    try std.testing.expectEqualStrings(":1.1", register.desktop.bus_name);
    try std.testing.expectEqualStrings(object_id.root_path, register.desktop.path);
    try std.testing.expect(register.app == &app);
    try std.testing.expect(register.lookup("/org/a11y/atspi/accessible/7/1") == null);
    try std.testing.expect(register.lookup(object_id.cache_path).?.interfaces.contains(.cache));
    try register.sync();
    try std.testing.expect(register.lookup("/org/a11y/atspi/accessible/7/1") != null);
}
