const std = @import("std");
const h = @import("root.zig");
const Context = h.Context;
const Value = h.Value;
const Error = h.Error;
const Method = h.Method;
const Property = h.Property;

pub const methods: []const Method = &.{};
pub const properties: []const Property = &.{
    .{ .name = "MinimumValue", .signature = "d" },
    .{ .name = "MaximumValue", .signature = "d" },
    .{ .name = "MinimumIncrement", .signature = "d" },
    .{ .name = "CurrentValue", .signature = "d", .writable = true },
};

pub fn call(_: *Context, _: []const u8, _: []const Value) Error![]const Value {
    return error.UnknownMethod;
}

pub fn get(ctx: *Context, name: []const u8) Error!Value {
    for (properties) |property| {
        if (!std.mem.eql(u8, name, property.name)) continue;
        const node = try ctx.platformNode();
        if (std.mem.eql(u8, name, "MinimumValue")) {
            return .{ .double = try node.minimumValue() };
        }
        if (std.mem.eql(u8, name, "MaximumValue")) {
            return .{ .double = try node.maximumValue() };
        }
        if (std.mem.eql(u8, name, "MinimumIncrement")) {
            return .{ .double = try node.minimumIncrement() };
        }
        return .{ .double = try node.currentValue() };
    }
    return error.UnknownProperty;
}

pub fn set(ctx: *Context, name: []const u8, value: Value) Error!void {
    for (properties) |property| {
        if (!std.mem.eql(u8, name, property.name)) continue;
        if (!property.writable) return error.PropertyReadOnly;
        try h.expect(&.{value}, "d");
        return (try ctx.platformNode()).setCurrentValue(value.double);
    }
    return error.UnknownProperty;
}

// Setting the property raises the schema action without fabricating a tree update.
test "value wire setter raises numeric action and leaves current tree authoritative" {
    const TestFixture = @import("component.zig").TestFixture;
    var fixture: TestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var ctx = fixture.context(1);
    try std.testing.expectEqual(@as(f64, 4.5), (try get(&ctx, "CurrentValue")).double);
    try std.testing.expectEqual(@as(f64, 0.25), (try get(&ctx, "MinimumIncrement")).double);
    try std.testing.expectEqual(-std.math.floatMax(f64), (try get(&ctx, "MinimumValue")).double);
    try std.testing.expectEqual(std.math.floatMax(f64), (try get(&ctx, "MaximumValue")).double);
    try set(&ctx, "CurrentValue", .{ .double = 7.25 });
    const request = fixture.last_action.?;
    try std.testing.expectEqual(.set_value, request.action);
    try std.testing.expectEqual(@as(u64, 1), request.target_node.value);
    try std.testing.expectEqual(@as(f64, 7.25), request.data.?.numeric_value);
    try std.testing.expectEqual(@as(f64, 4.5), (try get(&ctx, "CurrentValue")).double);
    try std.testing.expectError(error.InvalidArgs, set(&ctx, "CurrentValue", .{ .int32 = 7 }));
    try std.testing.expectError(error.PropertyReadOnly, set(&ctx, "MinimumValue", .{ .double = 0 }));
    try std.testing.expectError(error.UnknownProperty, get(&ctx, "Missing"));
    fixture.node_context.sink = null;
    try std.testing.expectError(error.NoActionSink, set(&ctx, "CurrentValue", .{ .double = 8 }));
}
