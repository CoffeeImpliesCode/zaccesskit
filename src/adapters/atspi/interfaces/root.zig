//! Typed, arena-owned AT-SPI replies over the consumer's real node/root queries.
//! This module performs no I/O and owns no transport or tree. Callers serialize
//! tree updates with dispatch and release the reply arena after the writer ends.
const std = @import("std");
const dbus = @import("../dbus.zig");
const node = @import("../node.zig");
const app_context = @import("../app_context.zig");
const object_id = @import("../object_id.zig");
const wire = @import("../wire.zig");
const FullNodeId = @import("../../../consumer/tree_index.zig").FullNodeId;

pub const Value = dbus.Value;
pub const Error = node.NodeError || error{
    InvalidArgs, NotSupported, UnknownMethod, UnknownProperty, PropertyReadOnly,
    /// A Properties target fails the D-Bus InterfaceName grammar before lookup.
    InvalidInterfaceName,
    /// A live object does not expose the requested well-formed interface.
    UnknownInterface,
    UnknownObject, ReplyLimit, MachineIdUnavailable,
};

/// Metadata is also the authority used for argument checking and introspection.
pub const Method = struct { name: []const u8, input: []const u8, output: []const u8 };
pub const Property = struct {
    name: []const u8,
    signature: []const u8,
    writable: bool = false,
};

/// A borrowed bus/object path pair. Empty bus and null path mean no object.
pub const ObjectReference = struct {
    bus_name: []const u8 = "",
    path: []const u8 = "/org/a11y/atspi/null",
};

/// One request's query view. Mutable output belongs to `arena`; immutable wire
/// constants may share static storage. The app, node context and root borrow
/// single-pump-owned state; null node/root means that view is absent. No helper
/// calls user code. `arena` must be the reply's bulk-lifetime arena allocator.
pub const Context = struct {
    arena: std.mem.Allocator,
    node: ?node.PlatformNode = null,
    root: ?node.PlatformRoot = null,
    app: *app_context.AppContext,
    bus_name: []const u8,
    desktop: ObjectReference = .{},
    /// Must match the writer's limits. Exhaustion returns ReplyLimit before
    /// copying a string or allocating an oversized value vector.
    limits: dbus.Limits = .{},

    pub fn platformNode(self: *Context) Error!node.PlatformNode {
        const value = self.node orelse return error.UnknownObject;
        _ = try value.resolve();
        return value;
    }

    pub fn platformRoot(self: *Context) Error!node.PlatformRoot {
        return self.root orelse error.UnknownObject;
    }

    /// Copies the value vector; children must already belong to the arena.
    pub fn values(self: *Context, input: []const Value) Error![]const Value {
        if (input.len > @min(reply_values_max, self.limits.max_values)) return error.ReplyLimit;
        return self.arena.dupe(Value, input);
    }

    pub fn string(self: *Context, input: []const u8) Error!Value {
        if (input.len > self.limits.max_string_bytes) return error.ReplyLimit;
        return .{ .string = try self.arena.dupe(u8, input) };
    }

    pub fn structure(self: *Context, fields: []const Value) Error!Value {
        return .{ .structure = try self.values(fields) };
    }

    pub fn array(self: *Context, signature: []const u8, input: []const Value) Error!Value {
        return .{ .array = .{
            .element_signature = signature, .values = try self.values(input),
        } };
    }

    pub fn variant(self: *Context, signature: []const u8, input: Value) Error!Value {
        const held = try self.arena.create(dbus.Variant);
        held.* = .{ .signature = signature, .value = input };
        return .{ .variant = held };
    }

    pub fn dictionaryEntry(self: *Context, key: Value, value: Value) Error!Value {
        return .{ .dict_entry = try self.values(&.{ key, value }) };
    }

    pub fn reference(self: *Context, ref: ObjectReference) Error!Value {
        if (ref.path.len > self.limits.max_string_bytes) return error.ReplyLimit;
        return self.structure(&.{
            try self.string(ref.bus_name),
            .{ .object_path = try self.arena.dupe(u8, ref.path) },
        });
    }

    pub fn object(self: *Context, id: object_id.ObjectId) Error!Value {
        return self.structure(&.{
            try self.string(self.bus_name),
            .{ .object_path = try id.path(self.arena) },
        });
    }

    pub fn nodeObject(self: *Context, id: ?FullNodeId) Error!Value {
        const actual = id orelse return self.reference(.{});
        const platform = try self.platformNode();
        return self.object(.{ .node = .{ .adapter = platform.adapter_id, .node = actual } });
    }

    /// Iterates only the fixed attribute set, copying values before it is freed.
    pub fn attributes(self: *Context, set: anytype) Error!Value {
        if (set.count > set.items.len) return error.ReplyLimit;
        var out: std.ArrayList(Value) = .empty;
        for (set.items[0..set.count]) |slot| {
            const entry = slot orelse continue;
            try out.append(self.arena, try self.dictionaryEntry(
                try self.string(entry.key), try self.string(entry.value),
            ));
        }
        return self.array("{ss}", out.items);
    }

    pub fn states(self: *Context, set: wire.StateSet) Error!Value {
        const words = set.toWords();
        return self.array("u", &.{
            .{ .uint32 = words[0] },
            .{ .uint32 = words[1] },
        });
    }

    pub fn interfaces(self: *Context, set: wire.InterfaceSet) Error!Value {
        var members: [wire.interface_count]wire.Interface = undefined;
        var values_buffer: [wire.interface_count]Value = undefined;
        const found = set.members(&members);
        for (found, 0..) |interface, index| {
            // Interface names are immutable wire constants, not borrowed tree
            // strings. Sharing them avoids one copy per interface per cache row.
            const name = wire.interfaceName(interface);
            if (name.len > self.limits.max_string_bytes) return error.ReplyLimit;
            values_buffer[index] = .{ .string = name };
        }
        return self.array("s", values_buffer[0..found.len]);
    }

    pub fn rect(self: *Context, value: @import("../wire/rect.zig").Rect) Error!Value {
        return self.structure(&.{
            .{ .int32 = value.x }, .{ .int32 = value.y },
            .{ .int32 = value.width }, .{ .int32 = value.height },
        });
    }
};

/// Query and introspection output vectors cannot exceed the object-register cap.
pub const reply_values_max = 65536;

pub fn int32(value: Value) error{InvalidArgs}!i32 {
    return switch (value) { .int32 => |held| held, else => error.InvalidArgs };
}
pub fn uint32(value: Value) error{InvalidArgs}!u32 {
    return switch (value) { .uint32 => |held| held, else => error.InvalidArgs };
}
pub fn boolean(value: Value) error{InvalidArgs}!bool {
    return switch (value) { .boolean => |held| held, else => error.InvalidArgs };
}
pub fn text(value: Value) error{InvalidArgs}![]const u8 {
    return switch (value) { .string => |held| held, else => error.InvalidArgs };
}
pub fn nonnegative(value: i32) error{InvalidArgs}!usize {
    if (value < 0) return error.InvalidArgs;
    return @intCast(value);
}

/// Checks recursive argument tags with the transport's bounded signature parser.
pub fn expect(args: []const Value, signature: []const u8) error{InvalidArgs}!void {
    dbus.validateBody(signature, args) catch return error.InvalidArgs;
}

/// Exact counterpart namespaces; transport-independent implementation authority.
pub const implementations = struct {
    pub const accessible = @import("accessible.zig");
    pub const action = @import("action.zig");
    pub const application = @import("application.zig");
    pub const cache = @import("cache.zig");
    pub const component = @import("component.zig");
    pub const document = @import("document.zig");
    pub const editable_text = @import("editable_text.zig");
    pub const hyperlink = @import("hyperlink.zig");
    pub const image = @import("image.zig");
    pub const selection = @import("selection.zig");
    pub const text = @import("text.zig");
    pub const value = @import("value.zig");
};

test "interface values retain copied object references and string contents" {
    var app = try @import("../app_context.zig").AppContext.init(std.testing.allocator, "App");
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: Context = .{ .arena = arena.allocator(), .app = &app, .bus_name = ":1.72" };
    var source = [_]u8{ 'H', 'i' };
    const value = try ctx.string(&source);
    source[0] = 'X';
    try std.testing.expectEqualStrings("Hi", value.string);
    const ref = try ctx.object(.root);
    try std.testing.expectEqualStrings(":1.72", ref.structure[0].string);
    try std.testing.expectEqualStrings("/org/a11y/atspi/accessible/root", ref.structure[1].object_path);
    const null_ref = try ctx.nodeObject(null);
    try std.testing.expectEqualStrings("", null_ref.structure[0].string);
    try std.testing.expectEqualStrings("/org/a11y/atspi/null", null_ref.structure[1].object_path);
}

test "interface argument validation rejects wrong tags and negative child indexes" {
    try std.testing.expectError(error.InvalidArgs, int32(.{ .uint32 = 1 }));
    try std.testing.expectError(error.InvalidArgs, nonnegative(-1));
    try std.testing.expectEqual(@as(usize, 0), try nonnegative(0));
}

test "interface replies reject writer size exhaustion before allocating payloads" {
    var app = try app_context.AppContext.init(std.testing.allocator, null);
    defer app.deinit();
    var storage: [0]u8 = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    var ctx: Context = .{
        .arena = allocator.allocator(), .app = &app, .bus_name = ":1.2",
        .limits = .{ .max_string_bytes = 2, .max_values = 1 },
    };
    try std.testing.expectError(error.ReplyLimit, ctx.string("long"));
    try std.testing.expectError(error.ReplyLimit, ctx.values(&.{
        .{ .int32 = 1 }, .{ .int32 = 2 },
    }));
    try std.testing.expectError(error.OutOfMemory, ctx.string("ok"));
}
