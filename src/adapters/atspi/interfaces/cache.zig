//! Pinned Unix cache.rs:31-112. The application tuple precedes every window's
//! visible preorder descendants. Node names fill short_name; descriptions fill name.
//! Every outgoing field is arena-owned, including event items for removed nodes.
const std = @import("std");
const h = @import("root.zig");
const platform = @import("../node.zig");
const wire = @import("../wire.zig");
const Fixture = @import("accessible.zig").TestFixture;
const Context = h.Context;
const Value = h.Value;
const Error = h.Error;
const Method = h.Method;
const Property = h.Property;

pub const item_signature = "((so)(so)(so)iiassusau)";
pub const methods: []const Method = &.{
    .{ .name = "GetItems", .input = "", .output = "a" ++ item_signature },
};
pub const properties: []const Property = &.{};

pub fn call(ctx: *Context, member: []const u8, args: []const Value) Error![]const Value {
    if (!std.mem.eql(u8, member, "GetItems")) return error.UnknownMethod;
    try h.expect(args, "");
    const root = try ctx.platformRoot();
    var nodes = try root.mapDescendantCacheNodes(ctx.arena, releaseCacheNode, retainCacheNode);
    // Descendant snapshots and reply values share this one owned arena. Their
    // text buffers transfer directly into the reply instead of being copied.
    defer nodes.deinit(ctx.arena);
    if (nodes.items.len >= h.reply_values_max) return error.ReplyLimit;
    const items = try ctx.arena.alloc(Value, nodes.items.len + 1);
    items[0] = try applicationCacheItem(ctx, root);
    for (nodes.items, 0..) |*entry, index| {
        if (entry.name.len > ctx.limits.max_string_bytes or
            entry.description.len > ctx.limits.max_string_bytes) return error.ReplyLimit;
        items[index + 1] = try cacheItemWithText(ctx, entry, .{ .string = entry.name }, .{ .string = entry.description });
    }
    return ctx.values(&.{try ctx.array(item_signature, items)});
}

/// Copies a complete CacheNode without resolving it. Native removal/add events
/// may hold the snapshot after its live tree path disappears. The caller retains
/// both input text buffers; the result and all nested values belong to ctx.arena.
pub fn cacheItem(ctx: *Context, cache: *const platform.CacheNode) Error!Value {
    return cacheItemWithText(ctx, cache, try ctx.string(cache.name), try ctx.string(cache.description));
}

fn cacheItemWithText(ctx: *Context, cache: *const platform.CacheNode, short_name: Value, name: Value) Error!Value {
    const object = try ctx.object(.{ .node = .{
        .adapter = cache.adapter_id,
        .node = cache.id,
    } });
    const app = try ctx.object(.root);
    const parent = try ctx.object(cache.parent.objectId(cache.adapter_id));
    return ctx.structure(&.{
        object,                              app,                                     parent,
        .{ .int32 = cache.index_in_parent }, .{ .int32 = cache.child_count },         try ctx.interfaces(cache.interfaces),
        short_name,                          .{ .uint32 = @intFromEnum(cache.role) }, name,
        try ctx.states(cache.states),
    });
}

fn applicationCacheItem(ctx: *Context, root: platform.PlatformRoot) Error!Value {
    const object = try ctx.object(.root);
    return ctx.structure(&.{
        object,                             object,                                   try ctx.reference(ctx.desktop),
        .{ .int32 = root.indexInParent() }, .{ .int32 = try root.childCount() },      try ctx.interfaces(root.interfaces()),
        try ctx.string(root.name()),        .{ .uint32 = @intFromEnum(root.role()) }, try ctx.string(root.description()),
        try ctx.states(root.state()),
    });
}

fn retainCacheNode(_: std.mem.Allocator, entry: platform.CacheNode) error{}!platform.CacheNode {
    return entry;
}

fn releaseCacheNode(gpa: std.mem.Allocator, entry: *platform.CacheNode) void {
    entry.deinit(gpa);
}

pub fn get(_: *Context, _: []const u8) Error!Value {
    return error.UnknownProperty;
}

pub fn set(_: *Context, _: []const u8, _: Value) Error!void {
    return error.UnknownProperty;
}

fn expectCacheObject(value: h.Value, bus_name: []const u8, path: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 2), value.structure.len);
    try std.testing.expectEqualStrings(bus_name, value.structure[0].string);
    try std.testing.expectEqualStrings(path, value.structure[1].object_path);
}

// Validate the full tuple and parent-first ordering, not merely an item count.
fn cacheAllocationCase(gpa: std.mem.Allocator) !void {
    var fixture: Fixture = .{};
    try fixture.init(std.testing.allocator);
    var fixture_live = true;
    defer if (fixture_live) fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx = fixture.request(arena.allocator(), null);
    const reply = try call(&ctx, "GetItems", &.{});
    fixture.deinit();
    fixture_live = false;
    try std.testing.expectEqual(@as(usize, 1), reply.len);
    const items = reply[0].array;
    try std.testing.expectEqualStrings("((so)(so)(so)iiassusau)", items.element_signature);
    try std.testing.expectEqual(@as(usize, 3), items.values.len);
    const root = items.values[0].structure;
    try std.testing.expectEqual(@as(usize, 10), root.len);
    try expectCacheObject(root[0], ":1.42", "/org/a11y/atspi/accessible/root");
    try expectCacheObject(root[1], ":1.42", "/org/a11y/atspi/accessible/root");
    try expectCacheObject(root[2], ":1.0", "/org/a11y/atspi/accessible/root");
    try std.testing.expectEqual(@as(i32, -1), root[3].int32);
    try std.testing.expectEqual(@as(i32, 1), root[4].int32);
    try std.testing.expectEqualStrings("s", root[5].array.element_signature);
    try std.testing.expectEqual(@as(usize, 2), root[5].array.values.len);
    try std.testing.expectEqualStrings("org.a11y.atspi.Accessible", root[5].array.values[0].string);
    try std.testing.expectEqualStrings("org.a11y.atspi.Application", root[5].array.values[1].string);
    try std.testing.expectEqualStrings("Example application", root[6].string);
    try std.testing.expectEqual(@intFromEnum(wire.Role.application), root[7].uint32);
    try std.testing.expectEqualStrings("", root[8].string);
    try std.testing.expectEqualStrings("u", root[9].array.element_signature);
    try std.testing.expectEqual(@as(usize, 2), root[9].array.values.len);
    try std.testing.expectEqual(@as(u32, 0), root[9].array.values[0].uint32);
    try std.testing.expectEqual(@as(u32, 0), root[9].array.values[1].uint32);
    const window = items.values[1].structure;
    try expectCacheObject(window[0], ":1.42", "/org/a11y/atspi/accessible/7/0");
    try expectCacheObject(window[2], ":1.42", "/org/a11y/atspi/accessible/root");
    try std.testing.expectEqual(@as(i32, 0), window[3].int32);
    try std.testing.expectEqual(@as(i32, 1), window[4].int32);
    try std.testing.expectEqual(@as(u32, 23), window[7].uint32);
    try std.testing.expectEqualStrings("Example window", window[6].string);
    try std.testing.expectEqualStrings("", window[8].string);
    const image = items.values[2].structure;
    try expectCacheObject(image[0], ":1.42", "/org/a11y/atspi/accessible/7/1");
    try expectCacheObject(image[1], ":1.42", "/org/a11y/atspi/accessible/root");
    try expectCacheObject(image[2], ":1.42", "/org/a11y/atspi/accessible/7/0");
    try std.testing.expectEqual(@as(i32, 0), image[3].int32);
    try std.testing.expectEqual(@as(i32, 0), image[4].int32);
    try std.testing.expectEqualStrings("Diagram", image[6].string);
    // The fixture's role description selects Extended, not the Image role.
    // AccessKit 466e24e252103f4d82bd6fbab98141b551e46e0c:
    // adapters/atspi-common/src/node.rs:87-90.
    // https://docs.rs/atspi-common/0.13.0/src/atspi_common/role.rs.html (Extended = 70).
    try std.testing.expectEqual(@as(u32, 70), image[7].uint32);
    try std.testing.expectEqualStrings("A tree diagram", image[8].string);
    try std.testing.expectEqualStrings("u", image[9].array.element_signature);
    try std.testing.expectEqual(@as(usize, 2), image[9].array.values.len);
}

test "AT-SPI Cache complete owned root and descendants tuple fail-N" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cacheAllocationCase, .{});
}

test "AT-SPI Cache unknown members are typed errors" {
    var fixture: Fixture = .{};
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = fixture.request(arena.allocator(), null);
    try std.testing.expectError(error.UnknownMethod, call(&ctx, "Other", &.{}));
    try std.testing.expectError(error.UnknownProperty, get(&ctx, "Items"));
    try std.testing.expectError(error.UnknownProperty, set(&ctx, "Items", .{ .int32 = 1 }));
}

test "AT-SPI Cache preserves adapter registration and descendant ordering" {
    var fixture: Fixture = .{};
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    try fixture.app.pushAdapter(11, &fixture.context);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = fixture.request(arena.allocator(), null);
    const items = (try call(&ctx, "GetItems", &.{}))[0].array.values;
    try std.testing.expectEqual(@as(usize, 5), items.len);
    try std.testing.expectEqual(@as(i32, 2), items[0].structure[4].int32);
    try expectCacheObject(items[1].structure[0], ":1.42", "/org/a11y/atspi/accessible/7/0");
    try expectCacheObject(items[2].structure[0], ":1.42", "/org/a11y/atspi/accessible/7/1");
    try expectCacheObject(items[3].structure[0], ":1.42", "/org/a11y/atspi/accessible/11/0");
    try expectCacheObject(items[4].structure[0], ":1.42", "/org/a11y/atspi/accessible/11/1");
    try std.testing.expectEqual(@as(i32, 1), items[3].structure[3].int32);
    try expectCacheObject(items[4].structure[2], ":1.42", "/org/a11y/atspi/accessible/11/0");
}

fn removedCacheAllocationCase(gpa: std.mem.Allocator) !void {
    var fixture: Fixture = .{};
    try fixture.init(std.testing.allocator);
    var fixture_live = true;
    defer if (fixture_live) fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx = fixture.request(arena.allocator(), 1);
    var cache = try ctx.node.?.cacheNode();
    var cache_live = true;
    defer if (cache_live) cache.deinit(std.testing.allocator);
    fixture.deinit();
    fixture_live = false;
    ctx.node = null;
    ctx.root = null;
    var bus_name = [_]u8{ ':', '1', '.', '4', '2' };
    ctx.bus_name = &bus_name;
    const item = try cacheItem(&ctx, &cache);
    cache.deinit(std.testing.allocator);
    cache_live = false;
    @memset(&bus_name, 'x');
    const fields = item.structure;
    try expectCacheObject(fields[0], ":1.42", "/org/a11y/atspi/accessible/7/1");
    try expectCacheObject(fields[1], ":1.42", "/org/a11y/atspi/accessible/root");
    try expectCacheObject(fields[2], ":1.42", "/org/a11y/atspi/accessible/7/0");
    try std.testing.expectEqualStrings("Diagram", fields[6].string);
    try std.testing.expectEqualStrings("A tree diagram", fields[8].string);
}

test "AT-SPI Cache event item survives node removal and fail-N" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, removedCacheAllocationCase, .{});
}
