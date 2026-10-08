const std = @import("std");
const h = @import("root.zig");
const Context = h.Context;
const Value = h.Value;
const Error = h.Error;
const Method = h.Method;
const Property = h.Property;

pub const methods: []const Method = &.{
    .{ .name = "GetDescription", .input = "i", .output = "s" },
    .{ .name = "GetName", .input = "i", .output = "s" },
    .{ .name = "GetLocalizedName", .input = "i", .output = "s" },
    .{ .name = "GetKeyBinding", .input = "i", .output = "s" },
    .{ .name = "GetActions", .input = "", .output = "a(sss)" },
    .{ .name = "DoAction", .input = "i", .output = "b" },
};
pub const properties: []const Property = &.{
    .{ .name = "NActions", .signature = "i" },
};

pub fn call(ctx: *Context, member: []const u8, args: []const Value) Error![]const Value {
    for (methods) |method| {
        if (!std.mem.eql(u8, method.name, member)) continue;
        try h.expect(args, method.input);
        const node = ctx.node orelse return error.UnknownObject;
        if (std.mem.eql(u8, member, "GetActions")) {
            var actions = try node.actions();
            defer actions.deinit();
            var entries: [@import("../node_interfaces.zig").action_slots]Value = undefined;
            for (actions.items[0..actions.count], 0..) |action, index| {
                entries[index] = try ctx.structure(&.{
                    try ctx.string(action.localized_name),
                    try ctx.string(action.description),
                    try ctx.string(action.key_binding),
                });
            }
            return ctx.values(&.{try ctx.array("(sss)", entries[0..actions.count])});
        }
        const index = try h.int32(args[0]);
        _ = try h.nonnegative(index);
        if (std.mem.eql(u8, member, "DoAction")) {
            return ctx.values(&.{.{ .boolean = try node.doAction(index) }});
        }
        if (std.mem.eql(u8, member, "GetName") or
            std.mem.eql(u8, member, "GetLocalizedName"))
        {
            return ctx.values(&.{try ctx.string(try node.actionName(index))});
        }
        return ctx.values(&.{try ctx.string("")});
    }
    return error.UnknownMethod;
}

pub fn get(ctx: *Context, name: []const u8) Error!Value {
    if (!std.mem.eql(u8, name, "NActions")) return error.UnknownProperty;
    return .{ .int32 = try (try ctx.platformNode()).nActions() };
}

pub fn set(_: *Context, name: []const u8, _: Value) Error!void {
    if (std.mem.eql(u8, name, "NActions")) return error.PropertyReadOnly;
    return error.UnknownProperty;
}

// Nonzero indices must not invoke the click exposed as the sole action.
test "action wire validates index and raises real click only for zero" {
    const TestFixture = @import("component.zig").TestFixture;
    var fixture: TestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var ctx = fixture.context(1);
    try std.testing.expectEqual(@as(i32, 1), (try get(&ctx, "NActions")).int32);
    const names = try call(&ctx, "GetActions", &.{});
    try std.testing.expectEqualStrings("(sss)", names[0].array.element_signature);
    try std.testing.expectEqual(@as(usize, 1), names[0].array.values.len);
    try std.testing.expectEqualStrings("click", names[0].array.values[0].structure[0].string);
    const absent = try call(&ctx, "DoAction", &.{.{ .int32 = 1 }});
    try std.testing.expect(!absent[0].boolean);
    try std.testing.expect(fixture.last_action == null);
    try std.testing.expectError(error.InvalidArgs, call(&ctx, "DoAction", &.{.{ .int32 = -1 }}));
    const result = try call(&ctx, "DoAction", &.{.{ .int32 = 0 }});
    try std.testing.expect(result[0].boolean);
    try std.testing.expectEqual(.click, fixture.last_action.?.action);
    try std.testing.expectEqual(@as(u64, 1), fixture.last_action.?.target_node.value);
    for ([_][]const u8{ "GetDescription", "GetName", "GetLocalizedName", "GetKeyBinding" }) |name| {
        try std.testing.expectError(error.InvalidArgs, call(&ctx, name, &.{.{ .int32 = -1 }}));
    }
}

// Unknown names are protocol errors, not empty successful replies.
test "counterpart wire rejects unknown names readonly writes and wrong argument shapes" {
    const TestFixture = @import("component.zig").TestFixture;
    var fixture: TestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var ctx = fixture.context(1);
    inline for (.{
        @This(), @import("component.zig"), @import("hyperlink.zig"),
        @import("image.zig"), @import("selection.zig"), @import("value.zig"),
    }) |interface| {
        try std.testing.expectError(error.UnknownMethod, interface.call(&ctx, "Missing", &.{}));
        try std.testing.expectError(error.UnknownProperty, interface.get(&ctx, "Missing"));
        try std.testing.expectError(error.UnknownProperty, interface.set(
            &ctx, "Missing", .{ .double = 1 },
        ));
        for (interface.properties) |property| {
            if (!property.writable) {
                try std.testing.expectError(error.PropertyReadOnly, interface.set(
                    &ctx, property.name, .{ .double = 1 },
                ));
            }
        }
        for (interface.methods) |method| {
            if (method.input.len != 0) {
                try std.testing.expectError(error.InvalidArgs, interface.call(
                    &ctx, method.name, &.{},
                ));
            } else {
                try std.testing.expectError(error.InvalidArgs, interface.call(
                    &ctx, method.name, &.{.{ .int32 = 0 }},
                ));
            }
        }
    }
    const name = try call(&ctx, "GetName", &.{.{ .int32 = 0 }});
    const localized = try call(&ctx, "GetLocalizedName", &.{.{ .int32 = 0 }});
    const description = try call(&ctx, "GetDescription", &.{.{ .int32 = 0 }});
    const binding = try call(&ctx, "GetKeyBinding", &.{.{ .int32 = 0 }});
    try std.testing.expectEqualStrings("click", name[0].string);
    try std.testing.expectEqualStrings("click", localized[0].string);
    try std.testing.expectEqualStrings("", description[0].string);
    try std.testing.expectEqualStrings("", binding[0].string);
}

// These upstream branches do not consult the tree; object lookup remains dispatch's job.
test "action wire preserves tree independent replies for a retained defunct handle" {
    const TestFixture = @import("component.zig").TestFixture;
    var fixture: TestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var ctx = fixture.context(999);
    const nonzero = try call(&ctx, "DoAction", &.{.{ .int32 = 1 }});
    try std.testing.expect(!nonzero[0].boolean);
    try std.testing.expect(fixture.last_action == null);
    const description = try call(&ctx, "GetDescription", &.{.{ .int32 = 0 }});
    const binding = try call(&ctx, "GetKeyBinding", &.{.{ .int32 = 0 }});
    try std.testing.expectEqualStrings("", description[0].string);
    try std.testing.expectEqualStrings("", binding[0].string);
    try std.testing.expectError(error.Defunct, call(&ctx, "DoAction", &.{.{ .int32 = 0 }}));
    try std.testing.expectError(error.InvalidArgs, call(&ctx, "DoAction", &.{.{ .int32 = -1 }}));
}
