const std = @import("std");
const h = @import("root.zig");
const schema = @import("../../../schema/root.zig");
const TestFixture = @import("text.zig").TestFixture;
const Context = h.Context;
const Value = h.Value;
const Error = h.Error;
const Method = h.Method;
const Property = h.Property;

pub const methods: []const Method = &.{
    .{ .name = "SetTextContents", .input = "s", .output = "b" },
    .{ .name = "InsertText", .input = "isi", .output = "b" },
    .{ .name = "CopyText", .input = "ii", .output = "" },
    .{ .name = "CutText", .input = "ii", .output = "b" },
    .{ .name = "DeleteText", .input = "ii", .output = "b" },
    .{ .name = "PasteText", .input = "i", .output = "b" },
};

pub const properties: []const Property = &.{};

pub fn call(ctx: *Context, member: []const u8, args: []const Value) Error![]const Value {
    for (methods) |method| {
        if (std.mem.eql(u8, member, method.name)) {
            try h.expect(args, method.input);
            if (!std.mem.eql(u8, member, "SetTextContents")) return error.NotSupported;
            const node = try ctx.platformNode();
            return ctx.values(&.{.{ .boolean = try node.setTextContents(try h.text(args[0])) }});
        }
    }
    return error.UnknownMethod;
}

pub fn get(_: *Context, _: []const u8) Error!Value {
    return error.UnknownProperty;
}

pub fn set(_: *Context, _: []const u8, _: Value) Error!void {
    return error.UnknownProperty;
}

test "EditableText wire copies Unicode contents into a real SetValue action" {
    var fixture: TestFixture = undefined;
    try fixture.init(std.testing.allocator, .text_input);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = fixture.context(arena.allocator());
    var contents = [_]u8{ 0xc3, 0xa9, '!' };
    const reply = try call(&ctx, "SetTextContents", &.{.{ .string = &contents }});
    try std.testing.expect(try h.boolean(reply[0]));
    contents[2] = '?';
    const request = fixture.last_action.?;
    try std.testing.expectEqual(schema.Action.set_value, request.action);
    try std.testing.expectEqual(@as(u64, 0), request.target_node.value);
    try std.testing.expectEqualStrings("é!", request.data.?.value);
}

test "EditableText wire unsupported methods preserve exact typed errors" {
    var fixture: TestFixture = undefined;
    try fixture.init(std.testing.allocator, .text_input);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = fixture.context(arena.allocator());
    try std.testing.expectError(error.NotSupported, call(&ctx, "InsertText", &.{
        .{ .int32 = -1 }, .{ .string = "é" }, .{ .int32 = -1 },
    }));
    try std.testing.expectError(error.NotSupported, call(&ctx, "CopyText", &.{
        .{ .int32 = 0 }, .{ .int32 = 1 },
    }));
    try std.testing.expectError(error.NotSupported, call(&ctx, "CutText", &.{
        .{ .int32 = 0 }, .{ .int32 = 1 },
    }));
    try std.testing.expectError(error.NotSupported, call(&ctx, "DeleteText", &.{
        .{ .int32 = 0 }, .{ .int32 = 1 },
    }));
    try std.testing.expectError(error.NotSupported, call(&ctx, "PasteText", &.{.{ .int32 = 0 }}));
    try std.testing.expectError(error.InvalidArgs, call(&ctx, "InsertText", &.{
        .{ .int32 = 0 }, .{ .string = "é" },
    }));
    try std.testing.expectEqual(@as(usize, 0), fixture.action_count);
    try std.testing.expectError(error.UnknownMethod, call(&ctx, "Missing", &.{}));
    try std.testing.expectError(error.UnknownProperty, get(&ctx, "Missing"));
    try std.testing.expectError(error.UnknownProperty, set(&ctx, "Missing", .{ .int32 = 0 }));
}

test "EditableText wire missing action sink does not leak its owned contents" {
    var fixture: TestFixture = undefined;
    try fixture.init(std.testing.allocator, .text_input);
    defer fixture.deinit();
    fixture.node_context.sink = null;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = fixture.context(arena.allocator());
    try std.testing.expectError(error.NoActionSink, call(&ctx, "SetTextContents", &.{
        .{ .string = "Missing sink é😀" },
    }));
    try std.testing.expectEqual(@as(usize, 0), fixture.action_count);
}

test "EditableText wire read only nodes reject contents without an action" {
    var fixture: TestFixture = undefined;
    try fixture.init(std.testing.allocator, .label);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = fixture.context(arena.allocator());
    const reply = try call(&ctx, "SetTextContents", &.{.{ .string = "Must not replace" }});
    try std.testing.expect(!try h.boolean(reply[0]));
    try std.testing.expectEqual(@as(usize, 0), fixture.action_count);
}

fn allocatingEditableTextWire(gpa: std.mem.Allocator) !void {
    var fixture: TestFixture = undefined;
    try fixture.init(gpa, .text_input);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx = fixture.context(arena.allocator());
    const reply = try call(&ctx, "SetTextContents", &.{.{ .string = "Owned é😀 contents" }});
    try std.testing.expect(try h.boolean(reply[0]));
    try std.testing.expectEqualStrings("Owned é😀 contents", fixture.last_action.?.data.?.value);
}

test "EditableText wire SetTextContents releases every fail N request and reply" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocatingEditableTextWire, .{});
}
