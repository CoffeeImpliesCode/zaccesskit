const std = @import("std");
const h = @import("root.zig");
const Context = h.Context;
const Value = h.Value;
const Error = h.Error;
const Method = h.Method;
const Property = h.Property;

pub const methods: []const Method = &.{
    .{ .name = "GetSelectedChild", .input = "i", .output = "(so)" },
    .{ .name = "SelectChild", .input = "i", .output = "b" },
    .{ .name = "DeselectSelectedChild", .input = "i", .output = "b" },
    .{ .name = "IsChildSelected", .input = "i", .output = "b" },
    .{ .name = "SelectAll", .input = "", .output = "b" },
    .{ .name = "ClearSelection", .input = "", .output = "b" },
    .{ .name = "DeselectChild", .input = "i", .output = "b" },
};
pub const properties: []const Property = &.{
    .{ .name = "NSelectedChildren", .signature = "i" },
};

pub fn call(ctx: *Context, member: []const u8, args: []const Value) Error![]const Value {
    for (methods) |method| {
        if (!std.mem.eql(u8, member, method.name)) continue;
        try h.expect(args, method.input);
        if (std.mem.eql(u8, member, "SelectAll")) {
            const node = ctx.node orelse return error.UnknownObject;
            return ctx.values(&.{.{ .boolean = try node.selectAll() }});
        }
        if (std.mem.eql(u8, member, "ClearSelection")) {
            const node = ctx.node orelse return error.UnknownObject;
            return ctx.values(&.{.{ .boolean = try node.clearSelection() }});
        }
        const node = try ctx.platformNode();
        const index = try h.nonnegative(try h.int32(args[0]));
        if (std.mem.eql(u8, member, "GetSelectedChild")) {
            return ctx.values(&.{try ctx.nodeObject(try node.selectedChild(index))});
        }
        if (std.mem.eql(u8, member, "SelectChild")) {
            return ctx.values(&.{.{ .boolean = try node.selectChild(index) }});
        }
        if (std.mem.eql(u8, member, "DeselectSelectedChild")) {
            return ctx.values(&.{.{ .boolean = try node.deselectSelectedChild(index) }});
        }
        if (std.mem.eql(u8, member, "IsChildSelected")) {
            return ctx.values(&.{.{ .boolean = try node.isChildSelected(index) }});
        }
        return ctx.values(&.{.{ .boolean = try node.deselectChild(index) }});
    }
    return error.UnknownMethod;
}

pub fn get(ctx: *Context, name: []const u8) Error!Value {
    if (!std.mem.eql(u8, name, "NSelectedChildren")) return error.UnknownProperty;
    return .{ .int32 = try (try ctx.platformNode()).nSelectedChildren() };
}

pub fn set(_: *Context, name: []const u8, _: Value) Error!void {
    if (std.mem.eql(u8, name, "NSelectedChildren")) return error.PropertyReadOnly;
    return error.UnknownProperty;
}

// Selected-child indices enumerate selected items, not the unfiltered children.
test "selection wire selected child returns exact object and preserves bounds" {
    const TestFixture = @import("component.zig").TestFixture;
    var fixture: TestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var ctx = fixture.context(2);
    try std.testing.expectEqual(@as(i32, 1), (try get(&ctx, "NSelectedChildren")).int32);
    const child = try call(&ctx, "GetSelectedChild", &.{.{ .int32 = 0 }});
    try std.testing.expectEqualDeep(try ctx.nodeObject(TestFixture.id(3)), child[0]);
    const absent = try call(&ctx, "GetSelectedChild", &.{.{ .int32 = 1 }});
    try std.testing.expectEqualDeep(try ctx.nodeObject(null), absent[0]);
    try std.testing.expectError(error.InvalidArgs, call(&ctx, "GetSelectedChild", &.{
        .{ .int32 = -1 },
    }));
    const selected = try call(&ctx, "IsChildSelected", &.{.{ .int32 = 0 }});
    try std.testing.expect(selected[0].boolean);
    const not_selected = try call(&ctx, "IsChildSelected", &.{.{ .int32 = 1 }});
    try std.testing.expect(!not_selected[0].boolean);
    const select = try call(&ctx, "SelectChild", &.{.{ .int32 = 1 }});
    try std.testing.expect(select[0].boolean);
    try std.testing.expectEqual(.click, fixture.last_action.?.action);
    try std.testing.expectEqual(@as(u64, 4), fixture.last_action.?.target_node.value);
    const select_all = try call(&ctx, "SelectAll", &.{});
    const clear = try call(&ctx, "ClearSelection", &.{});
    try std.testing.expect(!select_all[0].boolean);
    try std.testing.expect(!clear[0].boolean);
    try std.testing.expectEqual(@as(u64, 4), fixture.last_action.?.target_node.value);
}

// Deselect uses the selected-index domain; invalid indices retain the query errors.
test "selection wire deselects exact child and validates every signed index" {
    const TestFixture = @import("component.zig").TestFixture;
    var fixture: TestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var ctx = fixture.context(2);
    const deselect = try call(&ctx, "DeselectSelectedChild", &.{.{ .int32 = 0 }});
    try std.testing.expect(deselect[0].boolean);
    try std.testing.expectEqual(@as(u64, 3), fixture.last_action.?.target_node.value);
    const deselect_child = try call(&ctx, "DeselectChild", &.{.{ .int32 = 0 }});
    try std.testing.expect(deselect_child[0].boolean);
    try std.testing.expectEqual(@as(u64, 3), fixture.last_action.?.target_node.value);
    for ([_][]const u8{
        "SelectChild", "DeselectSelectedChild", "IsChildSelected", "DeselectChild",
    }) |member| {
        try std.testing.expectError(error.InvalidArgs, call(&ctx, member, &.{.{ .int32 = -1 }}));
        try std.testing.expectError(error.Defunct, call(&ctx, member, &.{.{ .int32 = 2 }}));
    }
    ctx = fixture.context(999);
    const bulk = try call(&ctx, "SelectAll", &.{});
    const clear = try call(&ctx, "ClearSelection", &.{});
    try std.testing.expect(!bulk[0].boolean);
    try std.testing.expect(!clear[0].boolean);
}
