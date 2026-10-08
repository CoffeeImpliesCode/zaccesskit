const std = @import("std");
const h = @import("root.zig");
const Context = h.Context;
const Value = h.Value;
const Error = h.Error;
const Method = h.Method;
const Property = h.Property;

pub const methods: []const Method = &.{
    .{ .name = "GetObject", .input = "i", .output = "(so)" },
    .{ .name = "GetURI", .input = "i", .output = "s" },
    .{ .name = "IsValid", .input = "", .output = "b" },
};
pub const properties: []const Property = &.{
    .{ .name = "NAnchors", .signature = "i" },
    .{ .name = "StartIndex", .signature = "i" },
    .{ .name = "EndIndex", .signature = "i" },
};

pub fn call(ctx: *Context, member: []const u8, args: []const Value) Error![]const Value {
    for (methods) |method| {
        if (!std.mem.eql(u8, member, method.name)) continue;
        try h.expect(args, method.input);
        const node = try ctx.platformNode();
        if (std.mem.eql(u8, member, "IsValid")) {
            return ctx.values(&.{.{ .boolean = try node.hyperlinkIsValid() }});
        }
        const index = try h.int32(args[0]);
        _ = try h.nonnegative(index);
        if (std.mem.eql(u8, member, "GetObject")) {
            return ctx.values(&.{try ctx.nodeObject(try node.hyperlinkObject(index))});
        }
        return ctx.values(&.{try ctx.string(try node.uri(index))});
    }
    return error.UnknownMethod;
}

pub fn get(ctx: *Context, name: []const u8) Error!Value {
    for (properties) |property| {
        if (!std.mem.eql(u8, name, property.name)) continue;
        const node = try ctx.platformNode();
        if (std.mem.eql(u8, name, "NAnchors")) return .{ .int32 = try node.nAnchors() };
        if (std.mem.eql(u8, name, "StartIndex")) {
            return .{ .int32 = try node.hyperlinkStartIndex() };
        }
        return .{ .int32 = try node.hyperlinkEndIndex() };
    }
    return error.UnknownProperty;
}

pub fn set(_: *Context, name: []const u8, _: Value) Error!void {
    for (properties) |property| {
        if (std.mem.eql(u8, name, property.name)) return error.PropertyReadOnly;
    }
    return error.UnknownProperty;
}

// The single anchor is this live node; other positive indices yield absent values.
test "hyperlink wire preserves anchor identity URI and negative bounds" {
    const TestFixture = @import("component.zig").TestFixture;
    var fixture: TestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var ctx = fixture.context(1);
    try std.testing.expectEqual(@as(i32, 1), (try get(&ctx, "NAnchors")).int32);
    try std.testing.expectEqual(@as(i32, -1), (try get(&ctx, "StartIndex")).int32);
    try std.testing.expectEqual(@as(i32, -1), (try get(&ctx, "EndIndex")).int32);
    const object = try call(&ctx, "GetObject", &.{.{ .int32 = 0 }});
    try std.testing.expectEqualDeep(try ctx.nodeObject(TestFixture.id(1)), object[0]);
    const uri = try call(&ctx, "GetURI", &.{.{ .int32 = 0 }});
    try std.testing.expectEqualStrings("https://example.test/diagram", uri[0].string);
    const absent = try call(&ctx, "GetObject", &.{.{ .int32 = 1 }});
    try std.testing.expectEqualDeep(try ctx.nodeObject(null), absent[0]);
    const empty_uri = try call(&ctx, "GetURI", &.{.{ .int32 = 1 }});
    try std.testing.expectEqualStrings("", empty_uri[0].string);
    const valid = try call(&ctx, "IsValid", &.{});
    try std.testing.expect(valid[0].boolean);
    try std.testing.expectError(error.InvalidArgs, call(&ctx, "GetObject", &.{.{ .int32 = -1 }}));
    try std.testing.expectError(error.InvalidArgs, call(&ctx, "GetURI", &.{.{ .int32 = -1 }}));
}
