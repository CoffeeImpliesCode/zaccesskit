const std = @import("std");
const h = @import("root.zig");
const wire = @import("../wire.zig");
const Context = h.Context;
const Value = h.Value;
const Error = h.Error;
const Method = h.Method;
const Property = h.Property;

pub const methods: []const Method = &.{
    .{ .name = "Contains", .input = "iiu", .output = "b" },
    .{ .name = "GetAccessibleAtPoint", .input = "iiu", .output = "(so)" },
    .{ .name = "GetExtents", .input = "u", .output = "(iiii)" },
    .{ .name = "GetLayer", .input = "", .output = "u" },
    .{ .name = "GrabFocus", .input = "", .output = "b" },
    .{ .name = "ScrollTo", .input = "u", .output = "b" },
    .{ .name = "ScrollToPoint", .input = "uii", .output = "b" },
};
pub const properties: []const Property = &.{};

pub fn call(ctx: *Context, member: []const u8, args: []const Value) Error![]const Value {
    for (methods) |method| {
        if (!std.mem.eql(u8, member, method.name)) continue;
        try h.expect(args, method.input);
        const node = try ctx.platformNode();
        if (std.mem.eql(u8, member, "Contains")) {
            const coord = wire.coordTypeFromInt(try h.uint32(args[2])) orelse
                return error.InvalidArgs;
            return ctx.values(&.{.{ .boolean = try node.contains(
                try h.int32(args[0]),
                try h.int32(args[1]),
                coord,
            ) }});
        }
        if (std.mem.eql(u8, member, "GetAccessibleAtPoint")) {
            const coord = wire.coordTypeFromInt(try h.uint32(args[2])) orelse
                return error.InvalidArgs;
            return ctx.values(&.{try ctx.nodeObject(try node.accessibleAtPoint(
                try h.int32(args[0]),
                try h.int32(args[1]),
                coord,
            ))});
        }
        if (std.mem.eql(u8, member, "GetExtents")) {
            const coord = wire.coordTypeFromInt(try h.uint32(args[0])) orelse
                return error.InvalidArgs;
            return ctx.values(&.{try ctx.rect(try node.extents(coord))});
        }
        if (std.mem.eql(u8, member, "GetLayer")) {
            return ctx.values(&.{.{ .uint32 = @intFromEnum(try node.layer()) }});
        }
        if (std.mem.eql(u8, member, "GrabFocus")) {
            return ctx.values(&.{.{ .boolean = try node.grabFocus() }});
        }
        if (std.mem.eql(u8, member, "ScrollTo")) {
            const scroll = wire.scrollTypeFromInt(try h.uint32(args[0])) orelse
                return error.InvalidArgs;
            return ctx.values(&.{.{ .boolean = try node.scrollTo(scroll) }});
        }
        const coord = wire.coordTypeFromInt(try h.uint32(args[0])) orelse
            return error.InvalidArgs;
        return ctx.values(&.{.{ .boolean = try node.scrollToPoint(
            coord,
            try h.int32(args[1]),
            try h.int32(args[2]),
        ) }});
    }
    return error.UnknownMethod;
}

pub fn get(_: *Context, _: []const u8) Error!Value {
    return error.UnknownProperty;
}

pub fn set(_: *Context, _: []const u8, _: Value) Error!void {
    return error.UnknownProperty;
}

// The fixture materializes consumer nodes; the sink retains real schema actions.
pub const TestFixture = if (@import("builtin").is_test) struct {
    const schema = @import("../../../schema/root.zig");
    const consumer = @import("../../../consumer/root.zig");
    const platform = @import("../node.zig");
    const app_context = @import("../app_context.zig");
    state: consumer.tree_state.TreeState = .{},
    app: app_context.AppContext,
    node_context: app_context.NodeContext = undefined,
    arena: std.heap.ArenaAllocator,
    last_action: ?schema.ActionRequest = null,

    pub fn id(value: u64) consumer.tree_index.FullNodeId {
        return .init(.{ .value = value }, .init(0));
    }

    pub fn init(self: *@This()) !void {
        const gpa = std.testing.allocator;
        self.* = .{
            .app = try app_context.AppContext.init(gpa, "Wire fixture"),
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        errdefer self.deinit();
        _ = try self.state.tree_index_map.getOrCreateIndex(gpa, schema.tree_id_root);
        self.state.root_id = id(0);
        self.state.focus_id = id(0);
        self.state.info = schema.TreeInfo.init(.{ .value = 0 });
        {
            var root_node = schema.Node.init(gpa, .window);
            errdefer root_node.deinit();
            try schema.ids_props.setChildren(&root_node.properties, &.{
                .{ .value = 1 }, .{ .value = 2 },
            });
            try self.insert(0, null, 0, root_node);
        }
        {
            var image_node = schema.Node.init(gpa, .image);
            errdefer image_node.deinit();
            image_node.addAction(.click);
            try schema.strings.setDescription(&image_node.properties, "A diagram");
            try schema.strings.setUrl(&image_node.properties, "https://example.test/diagram");
            try schema.option.setBounds(&image_node.properties, schema.rectInit(10, 20, 50, 60));
            try schema.numbers.setNumericValue(&image_node.properties, 4.5);
            try schema.numbers.setNumericValueStep(&image_node.properties, 0.25);
            try self.insert(1, 0, 0, image_node);
        }
        {
            var list = schema.Node.init(gpa, .list_box);
            errdefer list.deinit();
            try schema.ids_props.setChildren(&list.properties, &.{
                .{ .value = 3 }, .{ .value = 4 },
            });
            try self.insert(2, 0, 1, list);
        }
        for ([_]bool{ true, false }, 0..) |selected, index| {
            var item = schema.Node.init(gpa, .list_box_option);
            errdefer item.deinit();
            item.addAction(.click);
            try schema.enums.setSelected(&item.properties, selected);
            try self.insert(@intCast(index + 3), 2, index, item);
        }
        self.node_context = .{
            .state = &self.state,
            .app = &self.app,
            .bounds = .init(
                schema.rectInit(100, 200, 300, 400),
                schema.rectInit(105, 210, 295, 395),
            ),
            .sink = .{ .context = self, .raise = receive },
            .gpa = gpa,
        };
    }

    fn insert(self: *@This(), value: u64, parent: ?u64, index: usize, data: schema.Node) !void {
        try self.state.nodes.put(std.testing.allocator, id(value), .{
            .parent_and_index = if (parent) |parent_id|
                .{ .parent_id = id(parent_id), .index = index }
            else
                null,
            .data = data,
        });
    }

    fn receive(pointer: ?*anyopaque, request: schema.ActionRequest) void {
        const self: *@This() = @ptrCast(@alignCast(pointer.?));
        if (self.last_action) |*previous| previous.deinit(std.testing.allocator);
        self.last_action = request;
    }

    pub fn context(self: *@This(), value: u64) Context {
        return .{
            .arena = self.arena.allocator(),
            .node = platform.PlatformNode.init(&self.node_context, 7, id(value)),
            .root = null,
            .app = &self.app,
            .bus_name = ":1.42",
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.last_action) |*request| request.deinit(std.testing.allocator);
        self.state.deinit(std.testing.allocator);
        self.app.deinit();
        self.arena.deinit();
    }
} else void;

// Query actual geometry with the window offset and preserve the nested Rect wire type.
test "component wire geometry preserves screen coordinates and hit object identity" {
    var fixture: TestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var ctx = fixture.context(1);
    const extents = try call(&ctx, "GetExtents", &.{.{ .uint32 = 0 }});
    try std.testing.expectEqual(@as(usize, 1), extents.len);
    try std.testing.expectEqualDeep(&[_]Value{
        .{ .int32 = 115 }, .{ .int32 = 230 }, .{ .int32 = 40 }, .{ .int32 = 40 },
    }, extents[0].structure);
    const contains = try call(&ctx, "Contains", &.{
        .{ .int32 = 120 }, .{ .int32 = 235 }, .{ .uint32 = 0 },
    });
    try std.testing.expect(contains[0].boolean);
    const hit = try call(&ctx, "GetAccessibleAtPoint", &.{
        .{ .int32 = 120 }, .{ .int32 = 235 }, .{ .uint32 = 0 },
    });
    const expected = try ctx.nodeObject(TestFixture.id(1));
    try std.testing.expectEqualDeep(expected, hit[0]);
    try std.testing.expectError(error.InvalidArgs, call(&ctx, "GetExtents", &.{
        .{ .uint32 = 99 },
    }));
    try std.testing.expectError(error.InvalidArgs, call(&ctx, "ScrollTo", &.{
        .{ .uint32 = 99 },
    }));
}

// The scroll target must be converted into AccessKit parent coordinates, not echoed.
test "component wire scroll point raises converted application action" {
    var fixture: TestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var ctx = fixture.context(1);
    const result = try call(&ctx, "ScrollToPoint", &.{
        .{ .uint32 = 0 }, .{ .int32 = 120 }, .{ .int32 = 235 },
    });
    try std.testing.expect(result[0].boolean);
    const request = fixture.last_action.?;
    try std.testing.expectEqual(.scroll_to_point, request.action);
    try std.testing.expectEqual(@as(u64, 1), request.target_node.value);
    try std.testing.expectEqual(@as(f64, 15), request.data.?.scroll_to_point.x);
    try std.testing.expectEqual(@as(f64, 25), request.data.?.scroll_to_point.y);
    const layer = try call(&ctx, "GetLayer", &.{});
    try std.testing.expectEqual(@as(u32, 3), layer[0].uint32);
    const focused = try call(&ctx, "GrabFocus", &.{});
    try std.testing.expect(focused[0].boolean);
    try std.testing.expectEqual(.focus, fixture.last_action.?.action);
    const scrolled = try call(&ctx, "ScrollTo", &.{.{ .uint32 = 6 }});
    try std.testing.expect(scrolled[0].boolean);
    try std.testing.expectEqual(.scroll_into_view, fixture.last_action.?.action);
    try std.testing.expect(fixture.last_action.?.data == null);
}

fn allocatingGeometryReply(gpa: std.mem.Allocator) !void {
    var fixture: TestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx = fixture.context(1);
    ctx.arena = arena.allocator();
    const extents = try call(&ctx, "GetExtents", &.{.{ .uint32 = 0 }});
    try std.testing.expectEqual(@as(i32, 115), extents[0].structure[0].int32);
    const hit = try call(&ctx, "GetAccessibleAtPoint", &.{
        .{ .int32 = 120 }, .{ .int32 = 235 }, .{ .uint32 = 0 },
    });
    try std.testing.expectEqualStrings(":1.42", hit[0].structure[0].string);
}

// Each partial reply lives in the request arena and must be released on allocation failure.
test "component wire allocation failure releases geometry and object reply" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocatingGeometryReply,
        .{},
    );
}
