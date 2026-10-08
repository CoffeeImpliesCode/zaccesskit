const std = @import("std");
const h = @import("root.zig");
const Context = h.Context;
const Value = h.Value;
const Error = h.Error;
const Method = h.Method;
const Property = h.Property;

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
