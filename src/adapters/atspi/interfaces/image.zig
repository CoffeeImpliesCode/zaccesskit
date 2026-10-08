const std = @import("std");
const h = @import("root.zig");
const wire = @import("../wire.zig");
const Context = h.Context;
const Value = h.Value;
const Error = h.Error;
const Method = h.Method;
const Property = h.Property;

pub const methods: []const Method = &.{
    .{ .name = "GetImageExtents", .input = "u", .output = "(iiii)" },
    .{ .name = "GetImagePosition", .input = "u", .output = "ii" },
    .{ .name = "GetImageSize", .input = "", .output = "ii" },
};
pub const properties: []const Property = &.{
    .{ .name = "ImageDescription", .signature = "s" },
    .{ .name = "ImageLocale", .signature = "s" },
};

pub fn call(ctx: *Context, member: []const u8, args: []const Value) Error![]const Value {
    for (methods) |method| {
        if (!std.mem.eql(u8, member, method.name)) continue;
        try h.expect(args, method.input);
        const node = try ctx.platformNode();
        if (std.mem.eql(u8, member, "GetImageSize")) {
            const size = try node.imageSize();
            return ctx.values(&.{
                .{ .int32 = size.width }, .{ .int32 = size.height },
            });
        }
        const coord = wire.coordTypeFromInt(try h.uint32(args[0])) orelse
            return error.InvalidArgs;
        if (std.mem.eql(u8, member, "GetImageExtents")) {
            return ctx.values(&.{try ctx.rect(try node.imageExtents(coord))});
        }
        const point = try node.imagePosition(coord);
        return ctx.values(&.{
            .{ .int32 = @intFromFloat(point.x) }, .{ .int32 = @intFromFloat(point.y) },
        });
    }
    return error.UnknownMethod;
}

pub fn get(ctx: *Context, name: []const u8) Error!Value {
    if (std.mem.eql(u8, name, "ImageLocale")) return error.NotSupported;
    if (!std.mem.eql(u8, name, "ImageDescription")) return error.UnknownProperty;
    const node = try ctx.platformNode();
    var description = try node.imageDescription(ctx.arena);
    defer description.deinit(ctx.arena);
    return .{ .string = try description.toOwnedSlice(ctx.arena) };
}

pub fn set(_: *Context, name: []const u8, _: Value) Error!void {
    for (properties) |property| {
        if (std.mem.eql(u8, name, property.name)) return error.PropertyReadOnly;
    }
    return error.UnknownProperty;
}

// A tuple method result has two body values, unlike the wrapped Rect structure.
test "image wire exposes geometry tuple and explicit unsupported locale" {
    const TestFixture = @import("component.zig").TestFixture;
    var fixture: TestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var ctx = fixture.context(1);
    const position = try call(&ctx, "GetImagePosition", &.{.{ .uint32 = 0 }});
    try std.testing.expectEqual(@as(usize, 2), position.len);
    try std.testing.expectEqual(@as(i32, 115), position[0].int32);
    try std.testing.expectEqual(@as(i32, 230), position[1].int32);
    const size = try call(&ctx, "GetImageSize", &.{});
    try std.testing.expectEqual(@as(usize, 2), size.len);
    try std.testing.expectEqual(@as(i32, 40), size[0].int32);
    try std.testing.expectEqual(@as(i32, 40), size[1].int32);
    const extents = try call(&ctx, "GetImageExtents", &.{.{ .uint32 = 0 }});
    try std.testing.expectEqualDeep(&[_]Value{
        .{ .int32 = 115 }, .{ .int32 = 230 }, .{ .int32 = 40 }, .{ .int32 = 40 },
    }, extents[0].structure);
    try std.testing.expectEqualStrings("A diagram", (try get(&ctx, "ImageDescription")).string);
    try std.testing.expectError(error.NotSupported, get(&ctx, "ImageLocale"));
    try std.testing.expectError(error.InvalidArgs, call(&ctx, "GetImagePosition", &.{
        .{ .uint32 = 99 },
    }));
}
