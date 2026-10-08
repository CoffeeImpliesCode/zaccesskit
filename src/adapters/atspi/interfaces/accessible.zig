//! Pinned Unix accessible.rs:33-145,166-245. Root intentionally omits the
//! localized role and attribute methods. Desktop, tree text, IDs and containers
//! are copied into the request arena before the caller releases the tree guard.
const std = @import("std");
const h = @import("root.zig");
const platform = @import("../node.zig");
const app_context = @import("../app_context.zig");
const consumer = @import("../../../consumer/root.zig");
const schema = @import("../../../schema/root.zig");
const wire = @import("../wire.zig");
const FullNodeId = consumer.tree_index.FullNodeId;
const Context = h.Context;
const Value = h.Value;
const Error = h.Error;
const Method = h.Method;
const Property = h.Property;

pub const methods: []const Method = &.{
    .{ .name = "GetChildAtIndex", .input = "i", .output = "(so)" },
    .{ .name = "GetChildren", .input = "", .output = "a(so)" },
    .{ .name = "GetIndexInParent", .input = "", .output = "i" },
    .{ .name = "GetRelationSet", .input = "", .output = "a(ua(so))" },
    .{ .name = "GetRole", .input = "", .output = "u" },
    .{ .name = "GetState", .input = "", .output = "au" },
    .{ .name = "GetApplication", .input = "", .output = "(so)" },
    .{ .name = "GetInterfaces", .input = "", .output = "as" },
    .{ .name = "GetLocalizedRoleName", .input = "", .output = "s" },
    .{ .name = "GetAttributes", .input = "", .output = "a{ss}" },
};
pub const root_methods: []const Method = methods[0..8];
pub const properties: []const Property = &.{
    .{ .name = "Name", .signature = "s" },
    .{ .name = "Description", .signature = "s" },
    .{ .name = "Parent", .signature = "(so)" },
    .{ .name = "ChildCount", .signature = "i" },
    .{ .name = "Locale", .signature = "s" },
    .{ .name = "AccessibleId", .signature = "s" },
};

pub fn call(ctx: *Context, member: []const u8, args: []const Value) Error![]const Value {
    const exposed = if (ctx.node == null) root_methods else methods;
    for (exposed) |method| {
        if (!std.mem.eql(u8, member, method.name)) continue;
        try h.expect(args, method.input);
        const result = if (ctx.node != null)
            try callNode(ctx, member, args)
        else
            try callRoot(ctx, member, args);
        return ctx.values(&.{result});
    }
    return error.UnknownMethod;
}

fn callNode(ctx: *Context, member: []const u8, args: []const Value) Error!Value {
    if (std.mem.eql(u8, member, "GetApplication")) return ctx.object(.root);
    if (std.mem.eql(u8, member, "GetState")) {
        // Upstream state deliberately returns the defunct bit after node removal.
        const node = ctx.node orelse return error.UnknownObject;
        return ctx.states(try node.state());
    }
    if (std.mem.eql(u8, member, "GetChildAtIndex")) {
        const index = try h.nonnegative(try h.int32(args[0]));
        const node = try ctx.platformNode();
        return ctx.nodeObject(try node.childAtIndex(index));
    }
    const node = try ctx.platformNode();
    if (std.mem.eql(u8, member, "GetChildren")) {
        var children = try node.mapChildren(ctx.arena, childIdentity);
        defer children.deinit(ctx.arena);
        if (children.items.len > h.reply_values_max) return error.ReplyLimit;
        const refs = try ctx.arena.alloc(Value, children.items.len);
        for (children.items, 0..) |id, index| refs[index] = try ctx.nodeObject(id);
        return ctx.array("(so)", refs);
    }
    if (std.mem.eql(u8, member, "GetIndexInParent")) return .{ .int32 = try node.indexInParent() };
    if (std.mem.eql(u8, member, "GetRelationSet")) {
        var relations = try node.relationSet(ctx.arena);
        defer relations.deinit(ctx.arena);
        const controlled = relations.controller_for.items;
        if (controlled.len == 0) return ctx.array("(ua(so))", &.{});
        if (controlled.len > h.reply_values_max) return error.ReplyLimit;
        const targets = try ctx.arena.alloc(Value, controlled.len);
        for (controlled, 0..) |id, index| targets[index] = try ctx.nodeObject(id);
        const relation = try ctx.structure(&.{
            .{ .uint32 = @intFromEnum(wire.RelationType.controller_for) },
            try ctx.array("(so)", targets),
        });
        return ctx.array("(ua(so))", &.{relation});
    }
    if (std.mem.eql(u8, member, "GetRole")) return .{ .uint32 = @intFromEnum(try node.role()) };
    if (std.mem.eql(u8, member, "GetInterfaces")) return ctx.interfaces(try node.interfaces());
    if (std.mem.eql(u8, member, "GetLocalizedRoleName")) {
        return ctx.string(try node.localizedRoleName());
    }
    if (std.mem.eql(u8, member, "GetAttributes")) {
        var attributes = try node.attributes(ctx.arena);
        defer attributes.deinit(ctx.arena);
        return ctx.attributes(attributes);
    }
    return error.UnknownMethod;
}

fn callRoot(ctx: *Context, member: []const u8, args: []const Value) Error!Value {
    const root = try ctx.platformRoot();
    if (std.mem.eql(u8, member, "GetChildAtIndex")) {
        const index = try h.nonnegative(try h.int32(args[0]));
        const child = root.childIdAtIndex(index) orelse return ctx.reference(.{});
        return ctx.object(.{ .node = .{ .adapter = child.adapter_id, .node = child.id } });
    }
    if (std.mem.eql(u8, member, "GetChildren")) {
        const entries = root.app.adapters.items;
        if (entries.len > h.reply_values_max) return error.ReplyLimit;
        const refs = try ctx.arena.alloc(Value, entries.len);
        for (entries, 0..) |entry, index| {
            refs[index] = try ctx.object(.{ .node = .{
                .adapter = entry.id, .node = entry.context.state.rootId(),
            } });
        }
        return ctx.array("(so)", refs);
    }
    if (std.mem.eql(u8, member, "GetIndexInParent")) return .{ .int32 = root.indexInParent() };
    if (std.mem.eql(u8, member, "GetRelationSet")) return ctx.array("(ua(so))", &.{});
    if (std.mem.eql(u8, member, "GetRole")) return .{ .uint32 = @intFromEnum(root.role()) };
    if (std.mem.eql(u8, member, "GetState")) return ctx.states(root.state());
    if (std.mem.eql(u8, member, "GetApplication")) return ctx.object(.root);
    if (std.mem.eql(u8, member, "GetInterfaces")) return ctx.interfaces(root.interfaces());
    return error.UnknownMethod;
}

fn childIdentity(id: FullNodeId) FullNodeId {
    return id;
}

pub fn get(ctx: *Context, name: []const u8) Error!Value {
    const known = for (properties) |property| {
        if (std.mem.eql(u8, name, property.name)) break true;
    } else false;
    if (!known) return error.UnknownProperty;
    if (std.mem.eql(u8, name, "Locale")) return ctx.string("");
    if (ctx.node != null) {
        const node = try ctx.platformNode();
        if (std.mem.eql(u8, name, "Name")) {
            var text = try node.name(ctx.arena);
            defer text.deinit(ctx.arena);
            return ctx.string(text.items);
        }
        if (std.mem.eql(u8, name, "Description")) {
            var text = try node.description(ctx.arena);
            defer text.deinit(ctx.arena);
            return ctx.string(text.items);
        }
        if (std.mem.eql(u8, name, "Parent")) {
            return ctx.object((try node.parent()).objectId(node.adapter_id));
        }
        if (std.mem.eql(u8, name, "ChildCount")) return .{ .int32 = try node.childCount() };
        if (std.mem.eql(u8, name, "AccessibleId")) return ctx.string(try node.accessibleId());
    } else {
        const root = try ctx.platformRoot();
        if (std.mem.eql(u8, name, "Name")) return ctx.string(root.name());
        if (std.mem.eql(u8, name, "Description")) return ctx.string(root.description());
        if (std.mem.eql(u8, name, "Parent")) return ctx.reference(ctx.desktop);
        if (std.mem.eql(u8, name, "ChildCount")) return .{ .int32 = try root.childCount() };
        if (std.mem.eql(u8, name, "AccessibleId")) return ctx.string("");
    }
    return error.UnknownProperty;
}

pub fn set(_: *Context, name: []const u8, _: Value) Error!void {
    for (properties) |property| {
        if (std.mem.eql(u8, name, property.name)) return error.PropertyReadOnly;
    }
    return error.UnknownProperty;
}

pub const TestFixture = struct {
    state: consumer.tree_state.TreeState = .{},
    app: app_context.AppContext = undefined,
    context: app_context.NodeContext = undefined,

    pub fn id(value: u64) consumer.tree_index.FullNodeId {
        return .init(.{ .value = value }, .init(0));
    }

    pub fn init(self: *TestFixture, gpa: std.mem.Allocator) !void {
        self.* = .{};
        self.app = try app_context.AppContext.init(gpa, "Example application");
        errdefer self.app.deinit();
        errdefer self.state.deinit(gpa);
        const index = try self.state.tree_index_map.getOrCreateIndex(gpa, schema.tree_id_root);
        try std.testing.expectEqual(@as(u32, 0), index.value());
        self.state.root_id = id(0);
        self.state.focus_id = id(0);
        self.state.info = schema.TreeInfo.init(.{ .value = 0 });
        {
            var window = schema.Node.init(gpa, .window);
            errdefer window.deinit();
            try schema.ids_props.setChildren(&window.properties, &.{.{ .value = 1 }});
            try schema.strings.setLabel(&window.properties, "Example window");
            try self.state.nodes.put(gpa, id(0), .{ .parent_and_index = null, .data = window });
        }
        {
            var image = schema.Node.init(gpa, .image);
            errdefer image.deinit();
            try schema.strings.setLabel(&image.properties, "Diagram");
            try schema.strings.setDescription(&image.properties, "A tree diagram");
            try schema.strings.setRoleDescription(&image.properties, "diagram");
            try schema.strings.setAuthorId(&image.properties, "diagram-id");
            try schema.ids_props.setControls(&image.properties, &.{.{ .value = 0 }});
            try self.state.nodes.put(gpa, id(1), .{
                .parent_and_index = .{ .parent_id = id(0), .index = 0 }, .data = image,
            });
        }
        self.context = .{
            .state = &self.state, .app = &self.app, .bounds = .empty, .sink = null, .gpa = gpa,
        };
        try self.app.pushAdapter(7, &self.context);
    }

    pub fn deinit(self: *TestFixture) void {
        self.state.deinit(self.context.gpa);
        self.app.deinit();
    }

    pub fn request(self: *TestFixture, arena: std.mem.Allocator, node_id: ?u64) h.Context {
        return .{
            .arena = arena,
            .node = if (node_id) |value| platform.PlatformNode.init(&self.context, 7, id(value)) else null,
            .root = platform.PlatformRoot.init(&self.app), .app = &self.app, .bus_name = ":1.42",
            .desktop = .{ .bus_name = ":1.0", .path = "/org/a11y/atspi/accessible/root" },
        };
    }
};

fn expectObject(value: h.Value, bus_name: []const u8, path: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 2), value.structure.len);
    try std.testing.expectEqualStrings(bus_name, value.structure[0].string);
    try std.testing.expectEqualStrings(path, value.structure[1].object_path);
}

// Root and node Accessible intentionally differ in their exported members.
test "AT-SPI Accessible root and node real queries and boundary indexes" {
    var fixture: TestFixture = .{};
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root = fixture.request(arena.allocator(), null);
    var window = fixture.request(arena.allocator(), 0);
    var image = fixture.request(arena.allocator(), 1);
    try std.testing.expectEqualStrings("Example application", (try get(&root, "Name")).string);
    try std.testing.expectEqualStrings("", (try get(&root, "Description")).string);
    try std.testing.expectEqualStrings("", (try get(&root, "Locale")).string);
    try std.testing.expectEqualStrings("", (try get(&image, "Locale")).string);
    try std.testing.expectEqualStrings("", (try get(&root, "AccessibleId")).string);
    try std.testing.expectEqual(@as(u32, 79), (try call(&root, "GetRole", &.{}))[0].uint32);
    const root_states = (try call(&root, "GetState", &.{}))[0].array.values;
    try std.testing.expectEqual(@as(usize, 2), root_states.len);
    try std.testing.expectEqual(@as(u32, 0), root_states[0].uint32);
    try std.testing.expectEqual(@as(u32, 0), root_states[1].uint32);
    try std.testing.expectEqual(@as(usize, 0),
        (try call(&root, "GetRelationSet", &.{}))[0].array.values.len);
    try expectObject((try call(&image, "GetApplication", &.{}))[0],
        ":1.42", "/org/a11y/atspi/accessible/root");
    try expectObject(try get(&root, "Parent"), ":1.0", "/org/a11y/atspi/accessible/root");
    try std.testing.expectEqual(@as(i32, 1), (try get(&root, "ChildCount")).int32);
    try expectObject((try call(&root, "GetChildAtIndex", &.{.{ .int32 = 0 }}))[0],
        ":1.42", "/org/a11y/atspi/accessible/7/0");
    try expectObject((try call(&window, "GetChildAtIndex", &.{.{ .int32 = 0 }}))[0],
        ":1.42", "/org/a11y/atspi/accessible/7/1");
    try expectObject((try call(&root, "GetChildAtIndex", &.{.{ .int32 = 1 }}))[0],
        "", "/org/a11y/atspi/null");
    try std.testing.expectError(error.InvalidArgs,
        call(&root, "GetChildAtIndex", &.{.{ .int32 = -1 }}));
    try std.testing.expectError(error.InvalidArgs,
        call(&window, "GetChildAtIndex", &.{.{ .int32 = -1 }}));
    try std.testing.expectEqual(@as(i32, -1), (try call(&root, "GetIndexInParent", &.{}))[0].int32);
    try std.testing.expectEqual(@as(i32, 0), (try call(&image, "GetIndexInParent", &.{}))[0].int32);
    try expectObject(try get(&window, "Parent"), ":1.42", "/org/a11y/atspi/accessible/root");
    try expectObject(try get(&image, "Parent"), ":1.42", "/org/a11y/atspi/accessible/7/0");
    try std.testing.expectEqualStrings("Diagram", (try get(&image, "Name")).string);
    try std.testing.expectEqualStrings("A tree diagram", (try get(&image, "Description")).string);
    try std.testing.expectEqualStrings("diagram-id", (try get(&image, "AccessibleId")).string);
    try std.testing.expectEqualStrings("diagram",
        (try call(&image, "GetLocalizedRoleName", &.{}))[0].string);
    try std.testing.expectError(error.UnknownMethod, call(&root, "GetLocalizedRoleName", &.{}));
    try std.testing.expectError(error.UnknownMethod, call(&root, "GetAttributes", &.{}));
    try std.testing.expectError(error.UnknownProperty, get(&image, "Other"));
    try std.testing.expectError(error.PropertyReadOnly, set(&image, "Name", .{ .string = "x" }));
    const relations = (try call(&image, "GetRelationSet", &.{}))[0].array;
    try std.testing.expectEqualStrings("(ua(so))", relations.element_signature);
    try std.testing.expectEqual(@as(usize, 1), relations.values.len);
    try expectObject(relations.values[0].structure[1].array.values[0],
        ":1.42", "/org/a11y/atspi/accessible/7/0");
    const children = (try call(&window, "GetChildren", &.{}))[0].array;
    try std.testing.expectEqualStrings("(so)", children.element_signature);
    try std.testing.expectEqual(@as(usize, 1), children.values.len);
    try expectObject(children.values[0], ":1.42", "/org/a11y/atspi/accessible/7/1");
}

fn accessibleAllocationCase(gpa: std.mem.Allocator) !void {
    var fixture: TestFixture = .{};
    try fixture.init(std.testing.allocator);
    var fixture_live = true;
    defer if (fixture_live) fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var image = fixture.request(arena.allocator(), 1);
    var root = fixture.request(arena.allocator(), null);
    const name = try get(&image, "Name");
    const description = try get(&image, "Description");
    const author_id = try get(&image, "AccessibleId");
    const parent = try get(&image, "Parent");
    const root_name = try get(&root, "Name");
    const relations = (try call(&image, "GetRelationSet", &.{}))[0];
    const children = (try call(&root, "GetChildren", &.{}))[0];
    const attributes = (try call(&image, "GetAttributes", &.{}))[0];
    fixture.deinit();
    fixture_live = false;
    try std.testing.expectEqualStrings("Diagram", name.string);
    try std.testing.expectEqualStrings("A tree diagram", description.string);
    try std.testing.expectEqualStrings("diagram-id", author_id.string);
    try std.testing.expectEqualStrings("Example application", root_name.string);
    try expectObject(parent, ":1.42", "/org/a11y/atspi/accessible/7/0");
    try expectObject(relations.array.values[0].structure[1].array.values[0],
        ":1.42", "/org/a11y/atspi/accessible/7/0");
    try expectObject(children.array.values[0], ":1.42", "/org/a11y/atspi/accessible/7/0");
    try std.testing.expectEqualStrings("{ss}", attributes.array.element_signature);
}

test "AT-SPI Accessible reply lifetime and fail-N" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, accessibleAllocationCase, .{});
}

test "AT-SPI Accessible stale state reports defunct while identity queries stay constant" {
    var fixture: TestFixture = .{};
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = fixture.request(arena.allocator(), 99);
    const states = (try call(&ctx, "GetState", &.{}))[0].array.values;
    try std.testing.expectEqual(@as(u32, @truncate(wire.StateSet.defunct.bits)), states[0].uint32);
    try std.testing.expectEqual(@as(u32, @truncate(wire.StateSet.defunct.bits >> 32)),
        states[1].uint32);
    try expectObject((try call(&ctx, "GetApplication", &.{}))[0],
        ":1.42", "/org/a11y/atspi/accessible/root");
    try std.testing.expectEqualStrings("", (try get(&ctx, "Locale")).string);
    try std.testing.expectError(error.Defunct, get(&ctx, "AccessibleId"));
    try std.testing.expectError(error.UnknownProperty, get(&ctx, "Other"));
    try std.testing.expectError(error.InvalidArgs,
        call(&ctx, "GetChildAtIndex", &.{.{ .int32 = -1 }}));
}
