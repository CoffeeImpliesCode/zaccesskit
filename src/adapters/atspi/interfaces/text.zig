const std = @import("std");
const h = @import("root.zig");
const schema = @import("../../../schema/root.zig");
const consumer = @import("../../../consumer/root.zig");
const platform = @import("../node.zig");
const AppContext = @import("../app_context.zig").AppContext;
const NodeContext = @import("../app_context.zig").NodeContext;
const wire = @import("../wire.zig");
const Context = h.Context;
const Value = h.Value;
const Error = h.Error;
const Method = h.Method;
const Property = h.Property;

pub const methods: []const Method = &.{
    .{ .name = "GetStringAtOffset", .input = "iu", .output = "sii" },
    .{ .name = "GetText", .input = "ii", .output = "s" },
    .{ .name = "SetCaretOffset", .input = "i", .output = "b" },
    .{ .name = "GetAttributeValue", .input = "is", .output = "s" },
    .{ .name = "GetAttributes", .input = "i", .output = "a{ss}ii" },
    .{ .name = "GetDefaultAttributes", .input = "", .output = "a{ss}" },
    .{ .name = "GetCharacterExtents", .input = "iu", .output = "(iiii)" },
    .{ .name = "GetOffsetAtPoint", .input = "iiu", .output = "i" },
    .{ .name = "GetNSelections", .input = "", .output = "i" },
    .{ .name = "GetSelection", .input = "i", .output = "ii" },
    .{ .name = "AddSelection", .input = "ii", .output = "b" },
    .{ .name = "RemoveSelection", .input = "i", .output = "b" },
    .{ .name = "SetSelection", .input = "iii", .output = "b" },
    .{ .name = "GetRangeExtents", .input = "iiu", .output = "(iiii)" },
    .{ .name = "GetAttributeRun", .input = "ib", .output = "a{ss}ii" },
    .{ .name = "ScrollSubstringTo", .input = "iiu", .output = "b" },
    .{ .name = "ScrollSubstringToPoint", .input = "iiuii", .output = "b" },
};

pub const properties: []const Property = &.{
    .{ .name = "CharacterCount", .signature = "i" },
    .{ .name = "CaretOffset", .signature = "i" },
};

/// Unicode conversion, range normalization and mutation payloads belong to PlatformNode.
/// Only the reply copies below survive the borrowed node/tree view.
pub fn call(ctx: *Context, member: []const u8, args: []const Value) Error![]const Value {
    for (methods) |method| {
        if (std.mem.eql(u8, member, method.name)) {
            try h.expect(args, method.input);
            break;
        }
    } else return error.UnknownMethod;
    const node = try ctx.platformNode();
    if (std.mem.eql(u8, member, "GetStringAtOffset")) {
        var result = try node.stringAtOffset(try h.int32(args[0]), try enumArg(
            wire.Granularity,
            args[1],
        ));
        defer result.text.deinit(node.context.gpa);
        return ctx.values(&.{
            try ctx.string(result.text.items),
            .{ .int32 = result.start_offset },
            .{ .int32 = result.end_offset },
        });
    }
    if (std.mem.eql(u8, member, "GetText")) {
        var result = try node.text(try h.int32(args[0]), try h.int32(args[1]));
        defer result.deinit(node.context.gpa);
        return ctx.values(&.{try ctx.string(result.items)});
    }
    if (std.mem.eql(u8, member, "SetCaretOffset")) {
        return ctx.values(&.{.{ .boolean = try node.setCaretOffset(try h.int32(args[0])) }});
    }
    if (std.mem.eql(u8, member, "GetAttributeValue")) {
        const result = try node.textAttributeValue(try h.int32(args[0]), try h.text(args[1]));
        defer node.context.gpa.free(result);
        return ctx.values(&.{try ctx.string(result)});
    }
    if (std.mem.eql(u8, member, "GetAttributes")) {
        var result = try node.textAttributes(try h.int32(args[0]));
        defer result.attributes.deinit(node.context.gpa);
        return attributeRun(ctx, result);
    }
    if (std.mem.eql(u8, member, "GetDefaultAttributes")) {
        var result = try node.defaultTextAttributes();
        defer result.deinit(node.context.gpa);
        return ctx.values(&.{try ctx.attributes(result)});
    }
    if (std.mem.eql(u8, member, "GetCharacterExtents")) {
        return ctx.values(&.{try ctx.rect(try node.characterExtents(
            try h.int32(args[0]),
            try enumArg(wire.CoordType, args[1]),
        ))});
    }
    if (std.mem.eql(u8, member, "GetOffsetAtPoint")) {
        return ctx.values(&.{.{ .int32 = try node.offsetAtPoint(
            try h.int32(args[0]),
            try h.int32(args[1]),
            try enumArg(wire.CoordType, args[2]),
        ) }});
    }
    if (std.mem.eql(u8, member, "GetNSelections")) {
        return ctx.values(&.{.{ .int32 = try node.nSelections() }});
    }
    if (std.mem.eql(u8, member, "GetSelection")) {
        const result = try node.selection(try h.int32(args[0]));
        return ctx.values(&.{
            .{ .int32 = result.start_offset }, .{ .int32 = result.end_offset },
        });
    }
    if (std.mem.eql(u8, member, "AddSelection")) {
        return ctx.values(&.{.{ .boolean = try node.addSelection(
            try h.int32(args[0]),
            try h.int32(args[1]),
        ) }});
    }
    if (std.mem.eql(u8, member, "RemoveSelection")) {
        return ctx.values(&.{.{ .boolean = try node.removeSelection(try h.int32(args[0])) }});
    }
    if (std.mem.eql(u8, member, "SetSelection")) {
        return ctx.values(&.{.{ .boolean = try node.setSelection(
            try h.int32(args[0]),
            try h.int32(args[1]),
            try h.int32(args[2]),
        ) }});
    }
    if (std.mem.eql(u8, member, "GetRangeExtents")) {
        return ctx.values(&.{try ctx.rect(try node.rangeExtents(
            try h.int32(args[0]),
            try h.int32(args[1]),
            try enumArg(wire.CoordType, args[2]),
        ))});
    }
    if (std.mem.eql(u8, member, "GetAttributeRun")) {
        var result = try node.textAttributeRun(try h.int32(args[0]), try h.boolean(args[1]));
        defer result.attributes.deinit(node.context.gpa);
        return attributeRun(ctx, result);
    }
    if (std.mem.eql(u8, member, "ScrollSubstringTo")) {
        return ctx.values(&.{.{ .boolean = try node.scrollSubstringTo(
            try h.int32(args[0]),
            try h.int32(args[1]),
            try enumArg(wire.ScrollType, args[2]),
        ) }});
    }
    if (std.mem.eql(u8, member, "ScrollSubstringToPoint")) {
        return ctx.values(&.{.{ .boolean = try node.scrollSubstringToPoint(
            try h.int32(args[0]),
            try h.int32(args[1]),
            try enumArg(wire.CoordType, args[2]),
            try h.int32(args[3]),
            try h.int32(args[4]),
        ) }});
    }
    return error.UnknownMethod;
}

pub fn get(ctx: *Context, name: []const u8) Error!Value {
    if (std.mem.eql(u8, name, "CharacterCount")) {
        return .{ .int32 = try (try ctx.platformNode()).characterCount() };
    }
    if (std.mem.eql(u8, name, "CaretOffset")) {
        return .{ .int32 = try (try ctx.platformNode()).caretOffset() };
    }
    return error.UnknownProperty;
}

pub fn set(_: *Context, name: []const u8, _: Value) Error!void {
    for (properties) |property| {
        if (std.mem.eql(u8, name, property.name)) return error.PropertyReadOnly;
    }
    return error.UnknownProperty;
}

fn enumArg(comptime T: type, value: Value) Error!T {
    return std.enums.fromInt(T, try h.uint32(value)) orelse error.InvalidArgs;
}

fn attributeRun(ctx: *Context, result: platform.TextAttributeRun) Error![]const Value {
    return ctx.values(&.{
        try ctx.attributes(result.attributes),
        .{ .int32 = result.start_offset },
        .{ .int32 = result.end_offset },
    });
}

// The fixture uses a committed consumer tree, not a replacement text implementation.
pub const TestFixture = struct {
    tree: consumer.tree.Tree,
    app: AppContext,
    node_context: NodeContext,
    last_action: ?schema.ActionRequest = null,
    action_count: usize = 0,

    pub fn init(self: *TestFixture, gpa: std.mem.Allocator, role: schema.Role) !void {
        var update: schema.TreeUpdate = .{};
        var transferred = false;
        errdefer if (!transferred) update.deinit(gpa);
        var root_node = schema.Node.init(gpa, role);
        var root_transferred = false;
        errdefer if (!root_transferred) root_node.deinit();
        try schema.ids_props.setChildren(&root_node.properties, &.{.{ .value = 1 }});
        try schema.strings.setFontFamily(&root_node.properties, "Default Sans");
        try schema.strings.setUrl(&root_node.properties, "https://example.test/doc");
        try schema.option.setTextSelection(&root_node.properties, .{
            .anchor = .{ .node_id = .{ .value = 1 }, .character_index = 1 },
            .focus = .{ .node_id = .{ .value = 1 }, .character_index = 3 },
        });
        root_transferred = true;
        try update.pushNode(gpa, .{ .value = 0 }, root_node);
        var run = schema.Node.init(gpa, .text_run);
        var run_transferred = false;
        errdefer if (!run_transferred) run.deinit();
        try schema.strings.setValue(&run.properties, "Aé😀éZ");
        try schema.strings.setFontFamily(&run.properties, "Unicode Sans");
        try schema.vectors.setCharacterLengths(&run.properties, &.{ 1, 2, 4, 3, 1 });
        try schema.vectors.setWordStarts(&run.properties, &.{0});
        try schema.vectors.setCharacterPositions(&run.properties, &.{ 0, 10, 20, 30, 40 });
        try schema.vectors.setCharacterWidths(&run.properties, &.{ 10, 10, 10, 10, 10 });
        try schema.enums.setTextDirection(&run.properties, .left_to_right);
        try schema.option.setBounds(&run.properties, schema.rectInit(0, 0, 50, 20));
        run_transferred = true;
        try update.pushNode(gpa, .{ .value = 1 }, run);
        update.tree = schema.TreeInfo.init(.{ .value = 0 });
        update.focus = .{ .value = 0 };
        transferred = true;
        self.tree = try consumer.tree.Tree.init(gpa, update, true);
        errdefer self.tree.deinit();
        self.app = try AppContext.init(gpa, "Wire fixture");
        self.last_action = null;
        self.action_count = 0;
        self.node_context = .{
            .state = self.tree.stateOf(),
            .app = &self.app,
            .bounds = .empty,
            .sink = .{ .context = self, .raise = receive },
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *TestFixture) void {
        if (self.last_action) |*request| request.deinit(self.node_context.gpa);
        self.app.deinit();
        self.tree.deinit();
    }

    pub fn context(self: *TestFixture, arena: std.mem.Allocator) Context {
        return .{
            .arena = arena,
            .node = platform.PlatformNode.init(&self.node_context, 7, .init(.{ .value = 0 }, .init(0))),
            .app = &self.app,
            .bus_name = ":1.42",
        };
    }

    fn receive(pointer: ?*anyopaque, request: schema.ActionRequest) void {
        const self: *TestFixture = @ptrCast(@alignCast(pointer.?));
        if (self.last_action) |*previous| previous.deinit(self.node_context.gpa);
        self.last_action = request;
        self.action_count += 1;
    }
};

fn attribute(values: Value, name: []const u8) ![]const u8 {
    for (values.array.values) |entry| {
        if (std.mem.eql(u8, try h.text(entry.dict_entry[0]), name)) {
            return h.text(entry.dict_entry[1]);
        }
    }
    return error.TestUnexpectedResult;
}

test "Text wire uses Unicode scalar offsets and flattened tuple results" {
    var fixture: TestFixture = undefined;
    try fixture.init(std.testing.allocator, .text_input);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = fixture.context(arena.allocator());
    try std.testing.expectEqual(@as(i32, 6), try h.int32(try get(&ctx, "CharacterCount")));
    try std.testing.expectEqual(@as(i32, 3), try h.int32(try get(&ctx, "CaretOffset")));
    const text_reply = try call(&ctx, "GetText", &.{ .{ .int32 = 1 }, .{ .int32 = 3 } });
    try std.testing.expectEqualStrings("é😀", try h.text(text_reply[0]));
    const end_reply = try call(&ctx, "GetText", &.{ .{ .int32 = 3 }, .{ .int32 = -1 } });
    try std.testing.expectEqualStrings("éZ", try h.text(end_reply[0]));
    const reversed = try call(&ctx, "GetText", &.{ .{ .int32 = 3 }, .{ .int32 = 1 } });
    try std.testing.expectEqualStrings("", try h.text(reversed[0]));
    const char_reply = try call(&ctx, "GetStringAtOffset", &.{
        .{ .int32 = 3 }, .{ .uint32 = @intFromEnum(wire.Granularity.char) },
    });
    try std.testing.expectEqual(@as(usize, 3), char_reply.len);
    try std.testing.expectEqualStrings("é", try h.text(char_reply[0]));
    try std.testing.expectEqual(@as(i32, 3), try h.int32(char_reply[1]));
    try std.testing.expectEqual(@as(i32, 5), try h.int32(char_reply[2]));
    const selection = try call(&ctx, "GetSelection", &.{.{ .int32 = 0 }});
    try std.testing.expectEqual(@as(usize, 2), selection.len);
    try std.testing.expectEqual(@as(i32, 1), try h.int32(selection[0]));
    try std.testing.expectEqual(@as(i32, 3), try h.int32(selection[1]));
    const selection_count = try call(&ctx, "GetNSelections", &.{});
    try std.testing.expectEqual(@as(i32, 1), try h.int32(selection_count[0]));
    const missing = try call(&ctx, "GetSelection", &.{.{ .int32 = -1 }});
    try std.testing.expectEqual(@as(i32, -1), try h.int32(missing[0]));
    try std.testing.expectEqual(@as(i32, -1), try h.int32(missing[1]));
    const attrs = try call(&ctx, "GetAttributes", &.{.{ .int32 = 1 }});
    try std.testing.expectEqual(@as(usize, 3), attrs.len);
    try std.testing.expectEqualStrings("Unicode Sans", try attribute(attrs[0], "family-name"));
    try std.testing.expectEqual(@as(i32, 0), try h.int32(attrs[1]));
    try std.testing.expectEqual(@as(i32, 6), try h.int32(attrs[2]));
    const defaults = try call(&ctx, "GetDefaultAttributes", &.{});
    try std.testing.expectEqualStrings("Default Sans", try attribute(defaults[0], "family-name"));
    const character_box = try call(&ctx, "GetCharacterExtents", &.{
        .{ .int32 = 1 }, .{ .uint32 = 1 },
    });
    try std.testing.expectEqualDeep(Value{ .structure = &.{
        .{ .int32 = 10 }, .{ .int32 = 0 }, .{ .int32 = 10 }, .{ .int32 = 20 },
    } }, character_box[0]);
    const range_box = try call(&ctx, "GetRangeExtents", &.{
        .{ .int32 = 1 }, .{ .int32 = 3 }, .{ .uint32 = 1 },
    });
    try std.testing.expectEqualDeep(Value{ .structure = &.{
        .{ .int32 = 10 }, .{ .int32 = 0 }, .{ .int32 = 20 }, .{ .int32 = 20 },
    } }, range_box[0]);
    const point = try call(&ctx, "GetOffsetAtPoint", &.{
        .{ .int32 = 15 }, .{ .int32 = 15 }, .{ .uint32 = 1 },
    });
    try std.testing.expectEqual(@as(i32, 1), try h.int32(point[0]));
    const unknown_attribute = try call(&ctx, "GetAttributeValue", &.{
        .{ .int32 = 1 }, .{ .string = "unknown" },
    });
    try std.testing.expectEqualStrings("", try h.text(unknown_attribute[0]));
}

test "Text wire preserves range errors and validates wire enums" {
    var fixture: TestFixture = undefined;
    try fixture.init(std.testing.allocator, .text_input);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = fixture.context(arena.allocator());
    try std.testing.expectError(error.IndexOutOfRange, call(&ctx, "GetText", &.{
        .{ .int32 = -1 }, .{ .int32 = 2 },
    }));
    try std.testing.expectError(error.IndexOutOfRange, call(&ctx, "GetText", &.{
        .{ .int32 = 0 }, .{ .int32 = 7 },
    }));
    try std.testing.expectError(error.IndexOutOfRange, call(&ctx, "SetCaretOffset", &.{.{ .int32 = -1 }}));
    try std.testing.expectError(error.InvalidArgs, call(&ctx, "GetStringAtOffset", &.{
        .{ .int32 = 0 }, .{ .uint32 = 99 },
    }));
    try std.testing.expectError(error.UnsupportedTextGranularity, call(&ctx, "GetStringAtOffset", &.{
        .{ .int32 = 0 }, .{ .uint32 = @intFromEnum(wire.Granularity.sentence) },
    }));
    try std.testing.expectError(error.InvalidArgs, call(&ctx, "GetRangeExtents", &.{
        .{ .int32 = 0 }, .{ .int32 = 2 }, .{ .uint32 = 99 },
    }));
    try std.testing.expectError(error.InvalidArgs, call(&ctx, "ScrollSubstringTo", &.{
        .{ .int32 = 0 }, .{ .int32 = 2 }, .{ .uint32 = 99 },
    }));
    try std.testing.expectError(error.InvalidArgs, call(&ctx, "GetText", &.{
        .{ .int32 = 0 }, .{ .uint32 = 2 },
    }));
    try std.testing.expectError(error.InvalidArgs, call(&ctx, "GetText", &.{}));
    try std.testing.expectError(error.UnknownMethod, call(&ctx, "Missing", &.{}));
    try std.testing.expectError(error.UnknownProperty, get(&ctx, "Missing"));
    try std.testing.expectError(error.PropertyReadOnly, set(&ctx, "CaretOffset", .{ .int32 = 1 }));
}

test "Text wire replies survive destruction of the borrowed consumer tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = result: {
        var fixture: TestFixture = undefined;
        try fixture.init(std.testing.allocator, .text_input);
        defer fixture.deinit();
        var ctx = fixture.context(arena.allocator());
        break :result .{
            .text = try call(&ctx, "GetText", &.{ .{ .int32 = 0 }, .{ .int32 = -1 } }),
            .attributes = try call(&ctx, "GetAttributes", &.{.{ .int32 = 1 }}),
        };
    };
    try std.testing.expectEqualStrings("Aé😀éZ", try h.text(result.text[0]));
    try std.testing.expectEqualStrings(
        "Unicode Sans",
        try attribute(result.attributes[0], "family-name"),
    );
}

test "Text wire mutations deliver real Unicode selections and scroll actions" {
    var fixture: TestFixture = undefined;
    try fixture.init(std.testing.allocator, .text_input);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = fixture.context(arena.allocator());
    const added = try call(&ctx, "AddSelection", &.{ .{ .int32 = 1 }, .{ .int32 = 5 } });
    try std.testing.expect(try h.boolean(added[0]));
    const selection = fixture.last_action.?.data.?.set_text_selection;
    try std.testing.expectEqual(@as(u64, 1), selection.anchor.node_id.value);
    try std.testing.expectEqual(@as(usize, 1), selection.anchor.character_index);
    try std.testing.expectEqual(@as(usize, 4), selection.focus.character_index);
    const caret = try call(&ctx, "SetCaretOffset", &.{.{ .int32 = 2 }});
    try std.testing.expect(try h.boolean(caret[0]));
    const collapsed = fixture.last_action.?.data.?.set_text_selection;
    try std.testing.expectEqual(@as(usize, 2), collapsed.anchor.character_index);
    try std.testing.expectEqual(collapsed.anchor, collapsed.focus);
    const removed = try call(&ctx, "RemoveSelection", &.{.{ .int32 = 0 }});
    try std.testing.expect(try h.boolean(removed[0]));
    const count = fixture.action_count;
    const unsupported = try call(&ctx, "SetSelection", &.{
        .{ .int32 = 1 }, .{ .int32 = 0 }, .{ .int32 = 2 },
    });
    try std.testing.expect(!try h.boolean(unsupported[0]));
    try std.testing.expectEqual(count, fixture.action_count);
    const scrolled = try call(&ctx, "ScrollSubstringTo", &.{
        .{ .int32 = 0 }, .{ .int32 = 2 }, .{ .uint32 = 0 },
    });
    try std.testing.expect(try h.boolean(scrolled[0]));
    try std.testing.expectEqual(schema.Action.scroll_into_view, fixture.last_action.?.action);
    try std.testing.expectEqual(@as(u64, 1), fixture.last_action.?.target_node.value);
    const point = try call(&ctx, "ScrollSubstringToPoint", &.{
        .{ .int32 = 0 },   .{ .int32 = 2 },   .{ .uint32 = 1 },
        .{ .int32 = 100 }, .{ .int32 = 200 },
    });
    try std.testing.expect(try h.boolean(point[0]));
    try std.testing.expectEqual(schema.Action.scroll_to_point, fixture.last_action.?.action);
    try std.testing.expectEqual(@as(f64, 100), fixture.last_action.?.data.?.scroll_to_point.x);
    try std.testing.expectEqual(@as(f64, 200), fixture.last_action.?.data.?.scroll_to_point.y);
}

fn allocatingTextWire(gpa: std.mem.Allocator) !void {
    var fixture: TestFixture = undefined;
    try fixture.init(gpa, .text_input);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx = fixture.context(arena.allocator());
    _ = try call(&ctx, "GetText", &.{ .{ .int32 = 0 }, .{ .int32 = -1 } });
    _ = try call(&ctx, "GetStringAtOffset", &.{ .{ .int32 = 1 }, .{ .uint32 = 0 } });
    _ = try call(&ctx, "GetAttributeValue", &.{ .{ .int32 = 1 }, .{ .string = "family-name" } });
    _ = try call(&ctx, "GetAttributes", &.{.{ .int32 = 1 }});
    _ = try call(&ctx, "GetAttributeRun", &.{ .{ .int32 = 1 }, .{ .boolean = false } });
    _ = try call(&ctx, "GetAttributeRun", &.{ .{ .int32 = 1 }, .{ .boolean = true } });
    _ = try call(&ctx, "GetDefaultAttributes", &.{});
    _ = try call(&ctx, "SetCaretOffset", &.{.{ .int32 = 2 }});
    _ = try call(&ctx, "GetNSelections", &.{});
    _ = try call(&ctx, "GetSelection", &.{.{ .int32 = 0 }});
    _ = try call(&ctx, "AddSelection", &.{ .{ .int32 = 1 }, .{ .int32 = 5 } });
    _ = try call(&ctx, "RemoveSelection", &.{.{ .int32 = 0 }});
    _ = try call(&ctx, "SetSelection", &.{
        .{ .int32 = 0 }, .{ .int32 = 1 }, .{ .int32 = 5 },
    });
    _ = try call(&ctx, "ScrollSubstringTo", &.{
        .{ .int32 = 0 }, .{ .int32 = 2 }, .{ .uint32 = 0 },
    });
    _ = try call(&ctx, "ScrollSubstringToPoint", &.{
        .{ .int32 = 0 },   .{ .int32 = 2 },   .{ .uint32 = 1 },
        .{ .int32 = 100 }, .{ .int32 = 200 },
    });
    _ = try call(&ctx, "GetCharacterExtents", &.{ .{ .int32 = 1 }, .{ .uint32 = 1 } });
    _ = try call(&ctx, "GetRangeExtents", &.{
        .{ .int32 = 1 }, .{ .int32 = 3 }, .{ .uint32 = 1 },
    });
    _ = try call(&ctx, "GetOffsetAtPoint", &.{
        .{ .int32 = 15 }, .{ .int32 = 15 }, .{ .uint32 = 1 },
    });
}

test "Text wire owns replies and releases every fail N partial query" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocatingTextWire, .{});
}
