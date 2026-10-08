const std = @import("std");
const h = @import("root.zig");
const TestFixture = @import("text.zig").TestFixture;
const Context = h.Context;
const Value = h.Value;
const Error = h.Error;
const Method = h.Method;
const Property = h.Property;

pub const methods: []const Method = &.{
    .{ .name = "GetAttributeValue", .input = "s", .output = "s" },
    .{ .name = "GetAttributes", .input = "", .output = "a{ss}" },
    .{ .name = "GetLocale", .input = "", .output = "s" },
    .{ .name = "GetTextSelections", .input = "", .output = "a((so)i(so)ib)" },
    .{ .name = "SetTextSelections", .input = "a((so)i(so)ib)", .output = "b" },
};

pub const properties: []const Property = &.{
    .{ .name = "CurrentPageNumber", .signature = "i" },
    .{ .name = "PageCount", .signature = "i" },
};

pub fn call(ctx: *Context, member: []const u8, args: []const Value) Error![]const Value {
    for (methods) |method| {
        if (std.mem.eql(u8, member, method.name)) {
            try h.expect(args, method.input);
            if (std.mem.eql(u8, member, "GetAttributeValue")) {
                const node = try ctx.platformNode();
                return ctx.values(&.{.{
                    .string = try node.documentAttributeValue(ctx.arena, try h.text(args[0])),
                }});
            }
            if (std.mem.eql(u8, member, "GetAttributes")) {
                const node = try ctx.platformNode();
                var result = try node.documentAttributes(ctx.arena);
                defer result.deinit(ctx.arena);
                return ctx.values(&.{try ctx.attributes(result)});
            }
            return error.NotSupported;
        }
    }
    return error.UnknownMethod;
}

pub fn get(_: *Context, name: []const u8) Error!Value {
    for (properties) |property| {
        if (std.mem.eql(u8, name, property.name)) return error.NotSupported;
    }
    return error.UnknownProperty;
}

pub fn set(_: *Context, name: []const u8, _: Value) Error!void {
    for (properties) |property| {
        if (std.mem.eql(u8, name, property.name)) return error.PropertyReadOnly;
    }
    return error.UnknownProperty;
}

test "Document wire attributes use real document metadata and own strings" {
    var fixture: TestFixture = undefined;
    try fixture.init(std.testing.allocator, .root_web_area);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = fixture.context(arena.allocator());
    const reply = try call(&ctx, "GetAttributeValue", &.{.{ .string = "uri" }});
    try std.testing.expectEqualStrings("https://example.test/doc", try h.text(reply[0]));
    const unknown = try call(&ctx, "GetAttributeValue", &.{.{ .string = "unknown" }});
    try std.testing.expectEqualStrings("", try h.text(unknown[0]));
    const attrs = try call(&ctx, "GetAttributes", &.{});
    try std.testing.expectEqualStrings("{ss}", attrs[0].array.element_signature);
    var found = false;
    for (attrs[0].array.values) |entry| {
        if (std.mem.eql(u8, "URI", try h.text(entry.dict_entry[0]))) {
            found = true;
            try std.testing.expectEqualStrings(
                "https://example.test/doc",
                try h.text(entry.dict_entry[1]),
            );
        }
    }
    try std.testing.expect(found);
}

test "Document wire unsupported members return NotSupported without actions" {
    var fixture: TestFixture = undefined;
    try fixture.init(std.testing.allocator, .root_web_area);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = fixture.context(arena.allocator());
    try std.testing.expectError(error.NotSupported, get(&ctx, "CurrentPageNumber"));
    try std.testing.expectError(error.NotSupported, get(&ctx, "PageCount"));
    try std.testing.expectError(error.NotSupported, call(&ctx, "GetLocale", &.{}));
    try std.testing.expectError(error.NotSupported, call(&ctx, "GetTextSelections", &.{}));
    const selections = try ctx.array("((so)i(so)ib)", &.{});
    try std.testing.expectError(error.NotSupported, call(&ctx, "SetTextSelections", &.{selections}));
    try std.testing.expectEqual(@as(usize, 0), fixture.action_count);
    try std.testing.expectError(error.UnknownMethod, call(&ctx, "Missing", &.{}));
    try std.testing.expectError(error.UnknownProperty, get(&ctx, "Missing"));
    try std.testing.expectError(error.PropertyReadOnly, set(&ctx, "PageCount", .{ .int32 = 1 }));
    try std.testing.expectError(error.UnknownProperty, set(&ctx, "Missing", .{ .int32 = 1 }));
}

fn allocatingDocumentWire(gpa: std.mem.Allocator) !void {
    var fixture: TestFixture = undefined;
    try fixture.init(gpa, .root_web_area);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx = fixture.context(arena.allocator());
    const reply = try call(&ctx, "GetAttributeValue", &.{.{ .string = "URI" }});
    try std.testing.expectEqualStrings("https://example.test/doc", try h.text(reply[0]));
    _ = try call(&ctx, "GetAttributes", &.{});
}

test "Document wire owned attributes release every fail N partial query" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocatingDocumentWire, .{});
}

test "Document wire reply metadata survives destruction of the document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const reply = result: {
        var fixture: TestFixture = undefined;
        try fixture.init(std.testing.allocator, .root_web_area);
        defer fixture.deinit();
        var ctx = fixture.context(arena.allocator());
        break :result try call(&ctx, "GetAttributes", &.{});
    };
    for (reply[0].array.values) |entry| {
        if (std.mem.eql(u8, "URI", try h.text(entry.dict_entry[0]))) {
            try std.testing.expectEqualStrings(
                "https://example.test/doc",
                try h.text(entry.dict_entry[1]),
            );
            return;
        }
    }
    return error.TestUnexpectedResult;
}
