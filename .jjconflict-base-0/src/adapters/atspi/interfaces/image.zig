const std = @import("std");
const h = @import("root.zig");
const wire = @import("../wire.zig");
const Context = h.Context;
const Value = h.Value;
const Error = h.Error;
const Method = h.Method;
const Property = h.Property;

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
