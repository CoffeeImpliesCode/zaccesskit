//! Pinned Unix application.rs:13-38. Replies own copied toolkit metadata.
//! The registry may write any signed Id; before assignment it reads as -1.
const std = @import("std");
const h = @import("root.zig");
const app_context = @import("../app_context.zig");
const node = @import("../node.zig");
const Context = h.Context;
const Value = h.Value;
const Error = h.Error;
const Method = h.Method;
const Property = h.Property;

pub const methods: []const Method = &.{};
pub const properties: []const Property = &.{
    .{ .name = "ToolkitName", .signature = "s" },
    .{ .name = "Version", .signature = "s" },
    .{ .name = "AtspiVersion", .signature = "s" },
    .{ .name = "Id", .signature = "i", .writable = true },
};

pub fn call(_: *Context, _: []const u8, _: []const Value) Error![]const Value {
    return error.UnknownMethod;
}

pub fn get(ctx: *Context, name: []const u8) Error!Value {
    const known = for (properties) |property| {
        if (std.mem.eql(u8, name, property.name)) break true;
    } else false;
    if (!known) return error.UnknownProperty;
    if (std.mem.eql(u8, name, "AtspiVersion")) return ctx.string("2.1");
    const root = try ctx.platformRoot();
    if (std.mem.eql(u8, name, "ToolkitName")) return ctx.string(root.toolkitName());
    if (std.mem.eql(u8, name, "Version")) return ctx.string(root.toolkitVersion());
    if (std.mem.eql(u8, name, "Id")) return .{ .int32 = root.id() };
    return error.UnknownProperty;
}

pub fn set(ctx: *Context, name: []const u8, value: Value) Error!void {
    if (std.mem.eql(u8, name, "Id")) {
        _ = try ctx.platformRoot();
        node.PlatformRoot.setId(ctx.app, try h.int32(value));
        return;
    }
    for (properties) |property| {
        if (std.mem.eql(u8, name, property.name)) return error.PropertyReadOnly;
    }
    return error.UnknownProperty;
}

// Property replies must be independent of mutable application metadata.
test "AT-SPI Application exact versions registry Id and owned replies" {
    const gpa = std.testing.allocator;
    var app = try app_context.AppContext.init(gpa, "Example");
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: h.Context = .{
        .arena = arena.allocator(), .node = null, .root = node.PlatformRoot.init(&app),
        .app = &app, .bus_name = ":1.42",
        .desktop = .{ .bus_name = ":1.0", .path = "/org/a11y/atspi/accessible/root" },
    };
    try std.testing.expectEqual(@as(i32, -1), (try get(&ctx, "Id")).int32);
    try std.testing.expectEqualStrings("", (try get(&ctx, "ToolkitName")).string);
    try std.testing.expectEqualStrings("", (try get(&ctx, "Version")).string);
    try app.setToolkitName("Fixture Toolkit");
    try app.setToolkitVersion("7.4");
    const toolkit = try get(&ctx, "ToolkitName");
    const version = try get(&ctx, "Version");
    try std.testing.expectEqualStrings("2.1", (try get(&ctx, "AtspiVersion")).string);
    try set(&ctx, "Id", .{ .int32 = 81 });
    try std.testing.expectEqual(@as(i32, 81), (try get(&ctx, "Id")).int32);
    try set(&ctx, "Id", .{ .int32 = -19 });
    try std.testing.expectEqual(@as(i32, -19), app.id.?);
    try app.setToolkitName("Replacement");
    try app.setToolkitVersion("8.0");
    try std.testing.expectEqualStrings("Fixture Toolkit", toolkit.string);
    try std.testing.expectEqualStrings("7.4", version.string);
    try std.testing.expectError(error.UnknownProperty, get(&ctx, "ToolkitVersion"));
    try std.testing.expectError(error.UnknownProperty, set(&ctx, "Other", .{ .int32 = 1 }));
    try std.testing.expectError(error.PropertyReadOnly, set(&ctx, "Version", .{ .string = "x" }));
    try std.testing.expectError(error.InvalidArgs, set(&ctx, "Id", .{ .uint32 = 1 }));
    try std.testing.expectError(error.UnknownMethod, call(&ctx, "GetVersion", &.{}));
}

fn applicationAllocationCase(gpa: std.mem.Allocator) !void {
    var app = try app_context.AppContext.init(std.testing.allocator, "Example");
    defer app.deinit();
    try app.setToolkitVersion("Owned version");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: h.Context = .{
        .arena = arena.allocator(), .node = null, .root = node.PlatformRoot.init(&app),
        .app = &app, .bus_name = ":1.42",
        .desktop = .{ .bus_name = "", .path = "/org/a11y/atspi/null" },
    };
    try std.testing.expectEqualStrings("Owned version", (try get(&ctx, "Version")).string);
}

test "AT-SPI Application reply allocation fail-N" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, applicationAllocationCase, .{});
}
