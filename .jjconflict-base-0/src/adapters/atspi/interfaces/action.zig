const std = @import("std");
const h = @import("root.zig");
const Context = h.Context;
const Value = h.Value;
const Error = h.Error;
const Method = h.Method;
const Property = h.Property;

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
