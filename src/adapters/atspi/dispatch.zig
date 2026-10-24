//! Single-owner AT-SPI method dispatch with owned replies and checked actions.
//! The pump must serialize tree/register mutations with `handle`. Query code
//! borrows the tree only inside `query`; user callbacks run after it returns.
const std = @import("std");
const dbus = @import("dbus.zig");
const objects = @import("objects.zig");
const h = @import("interfaces/root.zig");
const wire = @import("wire.zig");

const schema = @import("../../schema/root.zig");
const node = @import("node.zig");
const app_context = @import("app_context.zig");
const object_id = @import("object_id.zig");
const adapter_error = @import("error.zig");
const tree_index = @import("../../consumer/tree_index.zig");
const tree = @import("../../consumer/tree.zig");
const implementations = h.implementations;

/// Consumes no request memory. Returned storage is caller-owned until writer
/// completion, then `reply.body.deinit()` releases it exactly once. Query reply
/// allocation and measurement precede the action callback. A checked delivery
/// failure can require an error-reply allocation after delivery has begun.
/// Oversized queries become Failed; an oversized error propagates its codec tag.
/// Request storage must remain live through return, including synchronous host callbacks.
/// Captured edit bytes borrow that storage; no request slices escape in the reply.
pub fn handle(
    gpa: std.mem.Allocator,
    register: *objects.Register,
    request: dbus.Message,
) dbus.CodecError!dbus.OwnedReply {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    var captured: CapturedAction = .{ .gpa = register.gpa };
    defer captured.deinit();
    var context: h.Context = .{
        .arena = arena.allocator(),
        .app = register.app,
        .bus_name = register.bus_name,
        .desktop = register.desktop,
        .limits = register.limits,
        .editable_text_sink = if (register.editable_text_sink != null) .{
            .context = &captured,
            .raise = CapturedAction.receiveEdit,
        } else null,
    };
    var reply = query(register, request, &context, &captured) catch |err| blk: {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        break :blk try errorReply(&context, request, err);
    };
    measureReply(reply, request, register.limits) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        reply = try errorReply(&context, request, err);
        try measureReply(reply, request, register.limits);
    };
    if (captured.overflow) {
        reply = try errorReply(&context, request, error.ReplyLimit);
        try measureReply(reply, request, register.limits);
    } else if (reply.error_name == null) {
        if (captured.request) |action| {
            const sink = register.sink orelse {
                reply = try errorReply(&context, request, error.NoActionSink);
                try measureReply(reply, request, register.limits);
                return finish(arena, reply);
            };
            // Ownership transfers on both success and checked-delivery failure.
            captured.request = null;
            sink.raise(sink.context, action) catch |err| {
                reply = try errorReply(&context, request, err);
                try measureReply(reply, request, register.limits);
            };
        } else if (captured.edit) |edit| {
            // Capture exists only when this serialized register installed a host hook.
            const sink = register.editable_text_sink.?;
            const accepted = sink.raise(sink.context, &edit) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                reply = try errorReply(&context, request, err);
                try measureReply(reply, request, register.limits);
                return finish(arena, reply);
            };
            if (!accepted) {
                reply = try errorReply(&context, request, error.CallbackFailed);
                try measureReply(reply, request, register.limits);
            }
        }
    }
    return finish(arena, reply);
}

const QueryReply = struct {
    signature: []const u8,
    values: []const dbus.Value,
    error_name: ?[]const u8 = null,
};

fn finish(arena: *std.heap.ArenaAllocator, reply: QueryReply) dbus.OwnedReply {
    return .{ .body = .{
        .arena = arena,
        .signature = reply.signature,
        .values = reply.values,
    }, .error_name = reply.error_name };
}

fn measureReply(reply: QueryReply, request: dbus.Message, limits: dbus.Limits) dbus.CodecError!void {
    // The pump supplies the actual serial; its encoded width is always u32.
    _ = try dbus.measureMessage(.{
        .kind = if (reply.error_name == null) .method_return else .error_reply,
        .serial = 1,
        .reply_serial = request.serial,
        .destination = request.sender,
        .error_name = reply.error_name,
        .signature = reply.signature,
        .body = reply.values,
    }, limits);
}

/// Owns the standard change body for an actual getter readback, never the Set
/// argument. The native owner sends it before acknowledging a successful Set.
pub fn propertiesChangedBody(
    gpa: std.mem.Allocator,
    interface_name: []const u8,
    property_name: []const u8,
    readback_variant: dbus.Value,
    limits: dbus.Limits,
) dbus.CodecError!dbus.OwnedBody {
    const entry = [_]dbus.Value{ .{ .string = property_name }, readback_variant };
    const entries = [_]dbus.Value{.{ .dict_entry = &entry }};
    const values = [_]dbus.Value{
        .{ .string = interface_name },
        .{ .array = .{ .element_signature = "{sv}", .values = &entries } },
        .{ .array = .{ .element_signature = "s", .values = &.{} } },
    };
    _ = try dbus.measureBody("sa{sv}as", &values, limits);
    return dbus.OwnedBody.init(gpa, "sa{sv}as", &values);
}

const CapturedAction = struct {
    gpa: std.mem.Allocator,
    request: ?schema.ActionRequest = null,
    edit: ?objects.EditableTextRequest = null,
    overflow: bool = false,

    fn receive(pointer: ?*anyopaque, action: schema.ActionRequest) void {
        const self: *CapturedAction = @ptrCast(@alignCast(pointer.?));
        if (self.request != null or self.edit != null) {
            // Pinned methods emit at most one request. Bound a future extension
            // without losing a second request or allowing callbacks under query.
            var rejected = action;
            rejected.deinit(self.gpa);
            self.overflow = true;
            return;
        }
        self.request = action;
    }

    fn receiveEdit(pointer: ?*anyopaque, request: *const objects.EditableTextRequest) objects.ActionDeliveryError!bool {
        const self: *CapturedAction = @ptrCast(@alignCast(pointer.?));
        if (self.request != null or self.edit != null) {
            self.overflow = true;
            return true;
        }
        self.edit = request.*;
        return true;
    }

    fn deinit(self: *CapturedAction) void {
        if (self.request) |*action| action.deinit(self.gpa);
        self.* = .{ .gpa = self.gpa };
    }
};

fn query(
    register: *objects.Register,
    request: dbus.Message,
    ctx: *h.Context,
    captured: *CapturedAction,
) h.Error!QueryReply {
    defer ctx.node = null;
    if (request.kind != .method_call) return error.InvalidArgs;
    const path = request.path orelse return error.InvalidArgs;
    const member = request.member orelse return error.InvalidArgs;
    const interface_name = request.interface orelse return error.InvalidArgs;
    const entry = register.lookup(path);
    if (std.mem.eql(u8, interface_name, "org.freedesktop.DBus.Introspectable")) {
        if (!std.mem.eql(u8, member, "Introspect")) return error.UnknownMethod;
        try signature(request, "");
        return .{ .signature = "s", .values = try ctx.values(&.{
            try introspection(ctx, register, path, entry),
        }) };
    }
    if (std.mem.eql(u8, interface_name, "org.freedesktop.DBus.Peer")) {
        if (entry == null and !(try hasLiveChild(register, path))) return error.UnknownObject;
        try signature(request, "");
        if (std.mem.eql(u8, member, "Ping")) {
            return .{ .signature = "", .values = &.{} };
        }
        if (std.mem.eql(u8, member, "GetMachineId")) {
            if (register.machine_id.len == 0) return error.MachineIdUnavailable;
            return .{ .signature = "s", .values = try ctx.values(&.{
                try ctx.string(register.machine_id),
            }) };
        }
        return error.UnknownMethod;
    }
    var query_context: app_context.NodeContext = undefined;
    if (entry) |object| {
        if (object.node) |platform| {
            query_context = platform.context.*;
            query_context.sink = .{ .context = captured, .raise = CapturedAction.receive };
            // Action storage remains in the adapter allocator domain, not the reply.
            query_context.gpa = captured.gpa;
            ctx.node = node.PlatformNode.init(&query_context, platform.adapter_id, platform.id);
        }
        if (object.id == .root or object.id == .cache) {
            ctx.root = node.PlatformRoot.init(register.app);
        }
    }
    if (std.mem.eql(u8, interface_name, "org.freedesktop.DBus.Properties")) {
        if (entry == null and !(try hasLiveChild(register, path))) return error.UnknownObject;
        const mask: wire.InterfaceSet = if (entry) |object| object.interfaces else .empty;
        return properties(ctx, mask, request, member);
    }
    const object = entry orelse {
        if (try hasLiveChild(register, path)) return error.UnknownInterface;
        return error.UnknownObject;
    };
    const interface = try findInterface(object.interfaces, interface_name);
    const metadata = methods(interface, ctx.node == null);
    for (metadata) |method| {
        if (!std.mem.eql(u8, member, method.name)) continue;
        try signature(request, method.input);
        return .{ .signature = method.output, .values = try call(interface, ctx, member, request.body) };
    }
    return error.UnknownMethod;
}

fn signature(request: dbus.Message, expected: []const u8) error{InvalidArgs}!void {
    if (!std.mem.eql(u8, request.signature, expected)) return error.InvalidArgs;
    try h.expect(request.body, expected);
}

fn standardInterface(name: []const u8) bool {
    return std.mem.eql(u8, name, "org.freedesktop.DBus.Peer") or
        std.mem.eql(u8, name, "org.freedesktop.DBus.Introspectable") or
        std.mem.eql(u8, name, "org.freedesktop.DBus.Properties");
}

fn propertyInterfaceName(value: dbus.Value) h.Error![]const u8 {
    const name = try h.text(value);
    if (name.len == 0 or name.len > 255) return error.InvalidInterfaceName;
    var segment_start = true;
    var dotted = false;
    for (name) |byte| {
        if (byte == '.') {
            if (segment_start) return error.InvalidInterfaceName;
            dotted = true;
            segment_start = true;
        } else {
            const letter = std.ascii.isAlphabetic(byte) or byte == '_';
            if (!letter) {
                if (segment_start or !std.ascii.isDigit(byte)) return error.InvalidInterfaceName;
            }
            segment_start = false;
        }
    }
    if (segment_start or !dotted) return error.InvalidInterfaceName;
    return name;
}

fn findInterface(interface_set: wire.InterfaceSet, name: []const u8) error{UnknownInterface}!wire.Interface {
    inline for (comptime std.enums.values(wire.Interface)) |interface| {
        if (std.mem.eql(u8, name, wire.interfaceName(interface))) {
            if (!interface_set.contains(interface)) return error.UnknownInterface;
            return interface;
        }
    }
    return error.UnknownInterface;
}

fn methods(interface: wire.Interface, is_root: bool) []const h.Method {
    return switch (interface) {
        .accessible => if (is_root) implementations.accessible.root_methods else implementations.accessible.methods,
        .action => implementations.action.methods,
        .application => implementations.application.methods,
        .cache => implementations.cache.methods,
        .component => implementations.component.methods,
        .document => implementations.document.methods,
        .editable_text => implementations.editable_text.methods,
        .hyperlink => implementations.hyperlink.methods,
        .image => implementations.image.methods,
        .selection => implementations.selection.methods,
        .text => implementations.text.methods,
        .value => implementations.value.methods,
    };
}

fn propertyMetadata(interface: wire.Interface) []const h.Property {
    return switch (interface) {
        inline else => |tag| @field(implementations, @tagName(tag)).properties,
    };
}

fn call(
    interface: wire.Interface,
    ctx: *h.Context,
    member: []const u8,
    args: []const dbus.Value,
) h.Error![]const dbus.Value {
    return switch (interface) {
        inline else => |tag| @field(implementations, @tagName(tag)).call(ctx, member, args),
    };
}

fn get(interface: wire.Interface, ctx: *h.Context, name: []const u8) h.Error!dbus.Value {
    return switch (interface) {
        inline else => |tag| @field(implementations, @tagName(tag)).get(ctx, name),
    };
}

fn set(interface: wire.Interface, ctx: *h.Context, name: []const u8, value: dbus.Value) h.Error!void {
    return switch (interface) {
        inline else => |tag| @field(implementations, @tagName(tag)).set(ctx, name, value),
    };
}

fn properties(ctx: *h.Context, mask: wire.InterfaceSet, request: dbus.Message, member: []const u8) h.Error!QueryReply {
    if (std.mem.eql(u8, member, "Get")) {
        try signature(request, "ss");
        const target = try propertyInterfaceName(request.body[0]);
        if (standardInterface(target)) return error.UnknownProperty;
        const interface = try findInterface(mask, target);
        const name = try h.text(request.body[1]);
        for (propertyMetadata(interface)) |property| {
            if (!std.mem.eql(u8, name, property.name)) continue;
            const value = try get(interface, ctx, name);
            return .{ .signature = "v", .values = try ctx.values(&.{
                try ctx.variant(property.signature, value),
            }) };
        }
        return error.UnknownProperty;
    }
    if (std.mem.eql(u8, member, "Set")) {
        try signature(request, "ssv");
        const target = try propertyInterfaceName(request.body[0]);
        if (standardInterface(target)) return error.UnknownProperty;
        const interface = try findInterface(mask, target);
        const name = try h.text(request.body[1]);
        const variant = request.body[2].variant;
        for (propertyMetadata(interface)) |property| {
            if (!std.mem.eql(u8, name, property.name)) continue;
            if (!property.writable) return error.PropertyReadOnly;
            if (!std.mem.eql(u8, variant.signature, property.signature)) return error.InvalidArgs;
            try h.expect(&.{variant.value}, property.signature);
            try set(interface, ctx, name, variant.value);
            return .{ .signature = "", .values = &.{} };
        }
        return error.UnknownProperty;
    }
    if (std.mem.eql(u8, member, "GetAll")) {
        try signature(request, "s");
        const target = try propertyInterfaceName(request.body[0]);
        if (standardInterface(target)) {
            return .{ .signature = "a{sv}", .values = try ctx.values(&.{
                try ctx.array("{sv}", &.{}),
            }) };
        }
        const interface = try findInterface(mask, target);
        var values: std.ArrayList(dbus.Value) = .empty;
        for (propertyMetadata(interface)) |property| {
            // zbus_macros 5.19.0 iface.rs:2350-2419 omits failed getters
            // from GetAll; Get still returns their typed error. Allocation
            // exhaustion is not a Rust getter error and must remain observable.
            const value = get(interface, ctx, property.name) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                continue;
            };
            try values.append(ctx.arena, try ctx.dictionaryEntry(
                try ctx.string(property.name),
                try ctx.variant(property.signature, value),
            ));
        }
        return .{ .signature = "a{sv}", .values = try ctx.values(&.{
            try ctx.array("{sv}", values.items),
        }) };
    }
    return error.UnknownMethod;
}

fn errorReply(
    ctx: *h.Context,
    request: dbus.Message,
    err: (h.Error || objects.ActionDeliveryError || dbus.CodecError),
) error{OutOfMemory}!QueryReply {
    const path = request.path orelse "";
    const mapped: adapter_error.DbusError = switch (err) {
        error.Defunct, error.UnknownObject => .{
            .name = adapter_error.error_unknown_object,
            .message = path,
        },
        error.UnsupportedInterface, error.UnknownInterface => .{
            .name = "org.freedesktop.DBus.Error.UnknownInterface",
            .message = "",
        },
        error.InvalidArgs, error.IndexOutOfRange => .{
            .name = adapter_error.error_invalid_args,
            .message = "Invalid arguments.",
        },
        error.InvalidInterfaceName => .{
            .name = "org.freedesktop.zbus.Error",
            .message = "Invalid interface name. See " ++
                "https://dbus.freedesktop.org/doc/dbus-specification.html" ++
                "#message-protocol-names-interface",
        },
        error.NotSupported => .{
            .name = adapter_error.error_not_supported,
            .message = "Operation is not supported.",
        },
        error.UnknownMethod => .{
            .name = "org.freedesktop.DBus.Error.UnknownMethod",
            .message = "Unknown method.",
        },
        error.UnknownProperty => .{
            .name = "org.freedesktop.DBus.Error.UnknownProperty",
            .message = "",
        },
        error.PropertyReadOnly => .{
            .name = "org.freedesktop.DBus.Error.PropertyReadOnly",
            .message = "Property is read-only.",
        },
        error.TooManyChildren, error.TooManyCharacters, error.UnsupportedTextGranularity => adapter_error.mapError(
            path,
            @errorCast(err),
        ),
        else => .{ .name = adapter_error.error_failed, .message = @errorName(err) },
    };
    const message = if (err == error.UnknownProperty)
        try std.fmt.allocPrint(ctx.arena, "Unknown property '{s}'", .{request.body[1].string})
    else if (err == error.UnknownInterface or err == error.UnsupportedInterface) blk: {
        const interface_name = request.interface orelse "";
        const target = if (std.mem.eql(u8, interface_name, "org.freedesktop.DBus.Properties"))
            request.body[0].string
        else
            interface_name;
        break :blk try std.fmt.allocPrint(ctx.arena, "Unknown interface '{s}'", .{target});
    } else try ctx.arena.dupe(u8, mapped.message);
    const body = try ctx.arena.dupe(dbus.Value, &.{.{ .string = message }});
    return .{ .signature = "s", .values = body, .error_name = mapped.name };
}

const standard_xml =
    "<interface name=\"org.freedesktop.DBus.Introspectable\">" ++
    "<method name=\"Introspect\"><arg type=\"s\" direction=\"out\"/></method></interface>" ++
    "<interface name=\"org.freedesktop.DBus.Properties\">" ++
    "<method name=\"Get\"><arg type=\"s\" direction=\"in\"/><arg type=\"s\" direction=\"in\"/>" ++
    "<arg type=\"v\" direction=\"out\"/></method>" ++
    "<method name=\"Set\"><arg type=\"s\" direction=\"in\"/><arg type=\"s\" direction=\"in\"/>" ++
    "<arg type=\"v\" direction=\"in\"/></method>" ++
    "<method name=\"GetAll\"><arg type=\"s\" direction=\"in\"/><arg type=\"a{sv}\" direction=\"out\"/>" ++
    "</method><signal name=\"PropertiesChanged\"><arg type=\"s\"/>" ++
    "<arg type=\"a{sv}\"/><arg type=\"as\"/></signal>" ++
    "</interface><interface name=\"org.freedesktop.DBus.Peer\">" ++
    "<method name=\"Ping\"/><method name=\"GetMachineId\"><arg type=\"s\" direction=\"out\"/>" ++
    "</method></interface>";

fn appendXml(
    arena: std.mem.Allocator,
    list: *std.ArrayList(u8),
    pieces: []const []const u8,
) error{OutOfMemory}!void {
    for (pieces) |piece| try list.appendSlice(arena, piece);
}

fn appendArgs(
    arena: std.mem.Allocator,
    list: *std.ArrayList(u8),
    sig: []const u8,
    direction: []const u8,
) h.Error!void {
    var position: usize = 0;
    var steps: usize = 0;
    while (position < sig.len) : (steps += 1) {
        if (steps >= 255) return error.ReplyLimit;
        const part = dbus.signatureNext(sig, &position) catch return error.InvalidArgs;
        const arg = part orelse return error.InvalidArgs;
        try appendXml(arena, list, &.{ "<arg type=\"", arg, "\" direction=\"", direction, "\"/>" });
    }
}

fn addChild(
    arena: std.mem.Allocator,
    children: *std.ArrayList([]const u8),
    parent: []const u8,
    candidate: []const u8,
) h.Error!void {
    const name = childName(parent, candidate) orelse return;
    for (children.items) |existing| if (std.mem.eql(u8, name, existing)) return;
    if (children.items.len >= h.reply_values_max) return error.ReplyLimit;
    try children.append(arena, name);
}

fn childName(parent: []const u8, candidate: []const u8) ?[]const u8 {
    if (parent.len == 0 or parent[0] != '/') return null;
    if (!std.mem.startsWith(u8, candidate, parent)) return null;
    var suffix = candidate[parent.len..];
    if (parent.len != 1) {
        if (suffix.len == 0 or suffix[0] != '/') return null;
        suffix = suffix[1..];
    }
    if (suffix.len == 0) return null;
    const end = std.mem.indexOfScalar(u8, suffix, '/') orelse suffix.len;
    if (end == 0) return null;
    return suffix[0..end];
}

fn hasLiveChild(register: *objects.Register, path: []const u8) h.Error!bool {
    if (childName(path, object_id.root_path) != null) return true;
    if (childName(path, object_id.cache_path) != null) return true;
    var iterator = register.paths.iterator();
    var remaining: usize = register.paths.count();
    while (iterator.next()) |item| {
        if (remaining == 0) return error.ReplyLimit;
        remaining -= 1;
        if (register.lookup(item.key_ptr.*) == null) continue;
        if (childName(path, item.key_ptr.*) != null) return true;
    }
    return false;
}

fn introspection(
    ctx: *h.Context,
    register: *objects.Register,
    path: []const u8,
    entry: ?objects.Entry,
) h.Error!dbus.Value {
    if (path.len == 0 or path[0] != '/') return error.UnknownObject;
    var children: std.ArrayList([]const u8) = .empty;
    try addChild(ctx.arena, &children, path, object_id.root_path);
    try addChild(ctx.arena, &children, path, object_id.cache_path);
    var iterator = register.paths.iterator();
    var remaining: usize = register.paths.count();
    while (iterator.next()) |item| {
        if (remaining == 0) return error.ReplyLimit;
        remaining -= 1;
        // A stale map entry must not re-advertise a removed object.
        if (register.lookup(item.key_ptr.*) == null) continue;
        try addChild(ctx.arena, &children, path, item.key_ptr.*);
    }
    if (entry == null and children.items.len == 0) return error.UnknownObject;
    var xml: std.ArrayList(u8) = .empty;
    try xml.appendSlice(ctx.arena, "<node>");
    if (entry) |object| {
        try xml.appendSlice(ctx.arena, standard_xml);
        var interfaces: [wire.interface_count]wire.Interface = undefined;
        for (object.interfaces.members(&interfaces)) |interface| {
            try appendXml(ctx.arena, &xml, &.{
                "<interface name=\"", wire.interfaceName(interface), "\">",
            });
            for (methods(interface, object.node == null)) |method| {
                try appendXml(ctx.arena, &xml, &.{ "<method name=\"", method.name, "\">" });
                try appendArgs(ctx.arena, &xml, method.input, "in");
                try appendArgs(ctx.arena, &xml, method.output, "out");
                try xml.appendSlice(ctx.arena, "</method>");
            }
            for (propertyMetadata(interface)) |property| {
                try appendXml(ctx.arena, &xml, &.{
                    "<property name=\"",
                    property.name,
                    "\" type=\"",
                    property.signature,
                    "\" access=\"",
                    if (property.writable) "readwrite" else "read",
                    "\"/>",
                });
            }
            if (interface == .cache) {
                try xml.appendSlice(
                    ctx.arena,
                    "<signal name=\"AddAccessible\"><arg type=\"((so)(so)(so)iiassusau)\"/></signal>" ++
                        "<signal name=\"RemoveAccessible\"><arg type=\"(so)\"/></signal>",
                );
            }
            try xml.appendSlice(ctx.arena, "</interface>");
        }
    } else {
        try xml.appendSlice(ctx.arena, standard_xml);
    }
    for (children.items) |child| {
        try appendXml(ctx.arena, &xml, &.{ "<node name=\"", child, "\"/>" });
    }
    try xml.appendSlice(ctx.arena, "</node>");
    return .{ .string = xml.items };
}
test "AT-SPI dispatcher returns owned value properties and named invalid argument errors" {
    const Fixture = @import("interfaces/component.zig").TestFixture;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.app.pushAdapter(7, &fixture.node_context);
    var register = objects.Register.init(std.testing.allocator, &fixture.app);
    defer register.deinit();
    register.bus_name = ":1.42";
    try register.sync();
    var ctx = fixture.context(1);
    const reference = try ctx.nodeObject(Fixture.id(1));
    var reply = try handle(std.testing.allocator, &register, .{
        .kind = .method_call,
        .flags = 0,
        .serial = 1,
        .path = reference.structure[1].object_path,
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Get",
        .signature = "ss",
        .body = &.{
            .{ .string = wire.interface_value }, .{ .string = "CurrentValue" },
        },
    });
    defer reply.body.deinit();
    try std.testing.expectEqualStrings("v", reply.body.signature);
    try std.testing.expectEqualStrings("d", reply.body.values[0].variant.signature);
    try std.testing.expectEqual(@as(f64, 4.5), reply.body.values[0].variant.value.double);
    var invalid = try handle(std.testing.allocator, &register, .{
        .kind = .method_call,
        .flags = 0,
        .serial = 2,
        .path = reference.structure[1].object_path,
        .interface = wire.interface_component,
        .member = "GetExtents",
        .signature = "i",
        .body = &.{.{ .int32 = 0 }},
    });
    defer invalid.body.deinit();
    try std.testing.expectEqualStrings("org.freedesktop.DBus.Error.InvalidArgs", invalid.error_name.?);
}

test "AT-SPI dispatcher rejects unsupported interfaces and removed object paths" {
    const Fixture = @import("interfaces/component.zig").TestFixture;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.app.pushAdapter(7, &fixture.node_context);
    var register = objects.Register.init(std.testing.allocator, &fixture.app);
    defer register.deinit();
    register.bus_name = ":1.42";
    try register.sync();
    var ctx = fixture.context(1);
    const reference = try ctx.nodeObject(Fixture.id(1));
    const path = reference.structure[1].object_path;
    var wrong = try handle(std.testing.allocator, &register, .{
        .kind = .method_call,
        .flags = 0,
        .serial = 3,
        .path = path,
        .interface = wire.interface_document,
        .member = "GetLocale",
        .signature = "",
        .body = &.{},
    });
    defer wrong.body.deinit();
    try std.testing.expectEqualStrings("org.freedesktop.DBus.Error.UnknownInterface", wrong.error_name.?);
    try std.testing.expectEqualStrings("Unknown interface 'org.a11y.atspi.Document'", wrong.body.values[0].string);
    fixture.app.removeAdapter(7);
    try register.sync();
    var removed = try handle(std.testing.allocator, &register, .{
        .kind = .method_call,
        .flags = 0,
        .serial = 4,
        .path = path,
        .interface = wire.interface_accessible,
        .member = "GetRole",
        .signature = "",
        .body = &.{},
    });
    defer removed.body.deinit();
    try std.testing.expectEqualStrings("org.freedesktop.DBus.Error.UnknownObject", removed.error_name.?);
}

test "AT-SPI introspection publishes exact dynamic method types and removes dead children" {
    const Fixture = implementations.component.TestFixture;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.app.pushAdapter(7, &fixture.node_context);
    var register = objects.Register.init(std.testing.allocator, &fixture.app);
    defer register.deinit();
    register.bus_name = ":1.42";
    try register.sync();
    var ctx = fixture.context(1);
    const ref = try ctx.nodeObject(Fixture.id(1));
    var reply = try handle(std.testing.allocator, &register, .{
        .kind = .method_call,
        .flags = 0,
        .serial = 5,
        .path = ref.structure[1].object_path,
        .interface = "org.freedesktop.DBus.Introspectable",
        .member = "Introspect",
        .signature = "",
        .body = &.{},
    });
    defer reply.body.deinit();
    const xml = reply.body.values[0].string;
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            xml,
            "<method name=\"GetImageSize\"><arg type=\"i\" direction=\"out\"/>" ++
                "<arg type=\"i\" direction=\"out\"/></method>",
        ) != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, xml, "org.a11y.atspi.Document") == null);
    var root_reply = try handle(std.testing.allocator, &register, .{
        .kind = .method_call,
        .flags = 0,
        .serial = 6,
        .path = object_id.root_path,
        .interface = "org.freedesktop.DBus.Introspectable",
        .member = "Introspect",
        .signature = "",
        .body = &.{},
    });
    defer root_reply.body.deinit();
    const root_xml = root_reply.body.values[0].string;
    try std.testing.expect(
        std.mem.indexOf(u8, root_xml, "<property name=\"Version\" type=\"s\" access=\"read\"/>") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, root_xml, "ToolkitVersion") == null);
    try std.testing.expect(std.mem.indexOf(u8, root_xml, "GetAttributes") == null);
    fixture.app.removeAdapter(7);
    try register.sync();
    var removed_parent = try handle(std.testing.allocator, &register, .{
        .kind = .method_call,
        .flags = 0,
        .serial = 7,
        .path = "/org/a11y/atspi/accessible/7",
        .interface = "org.freedesktop.DBus.Introspectable",
        .member = "Introspect",
        .signature = "",
        .body = &.{},
    });
    defer removed_parent.body.deinit();
    try std.testing.expectEqualStrings(adapter_error.error_unknown_object, removed_parent.error_name.?);
}

test "AT-SPI property Id roundtrip and peer machine identity use live owner values" {
    var app = try app_context.AppContext.init(std.testing.allocator, "Native fixture");
    defer app.deinit();
    var register = objects.Register.init(std.testing.allocator, &app);
    defer register.deinit();
    register.bus_name = ":1.82";
    register.machine_id = "0102030405060708090a0b0c0d0e0f10";
    const id_variant: dbus.Variant = .{ .signature = "i", .value = .{ .int32 = 23 } };
    var set_reply = try handle(std.testing.allocator, &register, .{
        .kind = .method_call,
        .flags = 0,
        .serial = 8,
        .path = object_id.root_path,
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Set",
        .signature = "ssv",
        .body = &.{
            .{ .string = wire.interface_application }, .{ .string = "Id" },
            .{ .variant = &id_variant },
        },
    });
    defer set_reply.body.deinit();
    try std.testing.expect(set_reply.error_name == null);
    var id_reply = try handle(std.testing.allocator, &register, .{
        .kind = .method_call,
        .flags = 0,
        .serial = 9,
        .path = object_id.root_path,
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Get",
        .signature = "ss",
        .body = &.{
            .{ .string = wire.interface_application }, .{ .string = "Id" },
        },
    });
    defer id_reply.body.deinit();
    try std.testing.expectEqual(@as(i32, 23), id_reply.body.values[0].variant.value.int32);
    var peer = try handle(std.testing.allocator, &register, .{
        .kind = .method_call,
        .flags = 0,
        .serial = 10,
        .path = object_id.root_path,
        .interface = "org.freedesktop.DBus.Peer",
        .member = "GetMachineId",
        .signature = "",
        .body = &.{},
    });
    defer peer.body.deinit();
    register.machine_id = "";
    try std.testing.expectEqualStrings("0102030405060708090a0b0c0d0e0f10", peer.body.values[0].string);
}

const CheckedActionProbe = struct {
    register: *objects.Register,
    failed: bool,
    observed: ?f64 = null,

    fn receive(pointer: ?*anyopaque, request: schema.ActionRequest) objects.ActionDeliveryError!void {
        const self: *CheckedActionProbe = @ptrCast(@alignCast(pointer.?));
        var held = request;
        defer held.deinit(self.register.gpa);
        self.observed = held.data.?.numeric_value;
        // Real callbacks may remove a tree. Mutation here must not leave a
        // borrowed query pointer in the outgoing property result.
        self.register.app.removeAdapter(7);
        if (self.failed) return error.CallbackFailed;
    }
};

test "AT-SPI dispatch settles checked callback failure after releasing the query view" {
    const Fixture = implementations.component.TestFixture;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.app.pushAdapter(7, &fixture.node_context);
    var register = objects.Register.init(std.testing.allocator, &fixture.app);
    defer register.deinit();
    register.bus_name = ":1.42";
    try register.sync();
    var probe: CheckedActionProbe = .{ .register = &register, .failed = true };
    register.sink = .{ .context = &probe, .raise = CheckedActionProbe.receive };
    var ctx = fixture.context(1);
    const ref = try ctx.nodeObject(Fixture.id(1));
    const variant: dbus.Variant = .{ .signature = "d", .value = .{ .double = 9.25 } };
    var reply = try handle(std.testing.allocator, &register, .{
        .kind = .method_call,
        .flags = 0,
        .serial = 11,
        .path = ref.structure[1].object_path,
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Set",
        .signature = "ssv",
        .body = &.{
            .{ .string = wire.interface_value }, .{ .string = "CurrentValue" },
            .{ .variant = &variant },
        },
    });
    defer reply.body.deinit();
    try std.testing.expectEqual(@as(f64, 9.25), probe.observed.?);
    try std.testing.expectEqualStrings(adapter_error.error_failed, reply.error_name.?);
    try std.testing.expectEqualStrings("CallbackFailed", reply.body.values[0].string);
    try std.testing.expect(register.lookup(ref.structure[1].object_path) == null);
}

fn dispatchAllocationFailure(gpa: std.mem.Allocator) !void {
    const Fixture = implementations.component.TestFixture;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.app.pushAdapter(7, &fixture.node_context);
    var register = objects.Register.init(std.testing.allocator, &fixture.app);
    defer register.deinit();
    register.bus_name = ":1.42";
    try register.sync();
    var reply = try handle(gpa, &register, .{
        .kind = .method_call,
        .flags = 0,
        .serial = 12,
        .path = object_id.root_path,
        .interface = wire.interface_accessible,
        .member = "GetChildren",
        .signature = "",
        .body = &.{},
    });
    defer reply.body.deinit();
    try std.testing.expectEqualStrings("a(so)", reply.body.signature);
    const child = reply.body.values[0].array.values[0].structure;
    try std.testing.expectEqualStrings(":1.42", child[0].string);
    try std.testing.expectEqualStrings("/org/a11y/atspi/accessible/7/0", child[1].object_path);
}

test "AT-SPI dispatcher releases owned reply allocations under fail N" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, dispatchAllocationFailure, .{});
}

test "AT-SPI GetAll publishes exact application dictionary without fake unsupported values" {
    var app = try app_context.AppContext.init(std.testing.allocator, "Properties fixture");
    defer app.deinit();
    app.toolkit_name = try std.testing.allocator.dupe(u8, "Toolkit");
    app.toolkit_version = try std.testing.allocator.dupe(u8, "9.2");
    var register = objects.Register.init(std.testing.allocator, &app);
    defer register.deinit();
    register.bus_name = ":1.42";
    var reply = try handle(std.testing.allocator, &register, .{
        .kind = .method_call,
        .flags = 0,
        .serial = 13,
        .path = object_id.root_path,
        .interface = "org.freedesktop.DBus.Properties",
        .member = "GetAll",
        .signature = "s",
        .body = &.{
            .{ .string = wire.interface_application },
        },
    });
    defer reply.body.deinit();
    const expected = [_]struct { []const u8, []const u8 }{
        .{ "ToolkitName", "Toolkit" }, .{ "Version", "9.2" }, .{ "AtspiVersion", "2.1" },
    };
    const values = reply.body.values[0].array;
    try std.testing.expectEqualStrings("{sv}", values.element_signature);
    try std.testing.expectEqual(@as(usize, 4), values.values.len);
    for (expected, 0..) |pair, index| {
        const entry = values.values[index].dict_entry;
        try std.testing.expectEqualStrings(pair[0], entry[0].string);
        try std.testing.expectEqualStrings("s", entry[1].variant.signature);
        try std.testing.expectEqualStrings(pair[1], entry[1].variant.value.string);
    }
    const id = values.values[3].dict_entry;
    try std.testing.expectEqualStrings("Id", id[0].string);
    try std.testing.expectEqualStrings("i", id[1].variant.signature);
    try std.testing.expectEqual(@as(i32, -1), id[1].variant.value.int32);
}

test "AT-SPI dispatcher reports oversized typed reply as Failed before the writer" {
    const Fixture = implementations.component.TestFixture;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.app.pushAdapter(7, &fixture.node_context);
    var register = objects.Register.init(std.testing.allocator, &fixture.app);
    defer register.deinit();
    register.bus_name = ":1.42";
    register.limits.max_array_bytes = 256;
    try register.sync();
    var reply = try handle(std.testing.allocator, &register, .{
        .kind = .method_call,
        .serial = 14,
        .path = object_id.cache_path,
        .interface = wire.interface_cache,
        .member = "GetItems",
        .signature = "",
        .body = &.{},
    });
    defer reply.body.deinit();
    try std.testing.expectEqualStrings(adapter_error.error_failed, reply.error_name.?);
    try std.testing.expectEqualStrings("s", reply.body.signature);
    try std.testing.expectEqualStrings("LimitExceeded", reply.body.values[0].string);
    try std.testing.expectEqual(@as(i32, 1), try fixture.app.childCount());
}

test "AT-SPI Unicode query roundtrips owned request and reply wire bodies" {
    try unicodeQueryWireRoundtrip(std.testing.allocator);
}

test "AT-SPI Unicode query wire roundtrip releases every allocation under fail N" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, unicodeQueryWireRoundtrip, .{});
}

fn unicodeQueryWireRoundtrip(gpa: std.mem.Allocator) !void {
    // The reply must survive both its decoded request and the real consumer tree.
    var reply = reply: {
        var fixture: implementations.text.TestFixture = undefined;
        try fixture.init(gpa, .text_input);
        defer fixture.deinit();
        try fixture.app.pushAdapter(7, &fixture.node_context);
        var register = objects.Register.init(gpa, &fixture.app);
        defer register.deinit();
        register.bus_name = ":1.42";
        try register.sync();
        const id: object_id.ObjectId = .{ .node = .{
            .adapter = 7,
            .node = .init(.{ .value = 0 }, .init(0)),
        } };
        const path = try id.path(gpa);
        defer gpa.free(path);
        const request_bytes = try dbus.encode(gpa, .{
            .kind = .method_call,
            .serial = 31,
            .sender = ":1.55",
            .path = path,
            .interface = wire.interface_text,
            .member = "GetStringAtOffset",
            .signature = "iu",
            .body = &.{ .{ .int32 = 3 }, .{ .uint32 = 0 } },
        }, .little, .{});
        defer gpa.free(request_bytes);
        var request_frame = try dbus.decode(gpa, request_bytes, .{});
        defer request_frame.deinit();
        break :reply try handle(gpa, &register, request_frame.message);
    };
    defer reply.body.deinit();
    try std.testing.expect(reply.error_name == null);
    const reply_bytes = try dbus.encode(gpa, .{
        .kind = .method_return,
        .serial = 32,
        .reply_serial = 31,
        .destination = ":1.55",
        .error_name = reply.error_name,
        .signature = reply.body.signature,
        .body = reply.body.values,
    }, .little, .{});
    defer gpa.free(reply_bytes);
    var reply_frame = try dbus.decode(gpa, reply_bytes, .{});
    defer reply_frame.deinit();
    const message = reply_frame.message;
    try std.testing.expectEqual(dbus.Kind.method_return, message.kind);
    try std.testing.expectEqual(@as(u32, 32), message.serial);
    try std.testing.expectEqual(@as(?u32, 31), message.reply_serial);
    try std.testing.expectEqualStrings(":1.55", message.destination.?);
    try std.testing.expectEqualStrings("sii", message.signature);
    try std.testing.expectEqual(@as(usize, 3), message.body.len);
    try std.testing.expectEqualStrings("é", message.body[0].string);
    try std.testing.expectEqual(@as(i32, 3), message.body[1].int32);
    try std.testing.expectEqual(@as(i32, 5), message.body[2].int32);
    try std.testing.expect(message.error_name == null);
}

test "AT-SPI standard discovery serves live nodes and virtual parents with exact errors" {
    try standardDiscoveryRoundtrip(std.testing.allocator);
}

test "AT-SPI standard discovery releases owned replies under fail N" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, standardDiscoveryRoundtrip, .{});
}

fn standardDiscoveryRoundtrip(gpa: std.mem.Allocator) !void {
    // Every request goes through the register over a committed consumer tree.
    var fixture: implementations.text.TestFixture = undefined;
    try fixture.init(gpa, .text_input);
    defer fixture.deinit();
    try fixture.app.pushAdapter(7, &fixture.node_context);
    var register = objects.Register.init(gpa, &fixture.app);
    defer register.deinit();
    register.bus_name = ":1.42";
    register.machine_id = "0102030405060708090a0b0c0d0e0f10";
    try register.sync();
    const paths = [_][]const u8{
        object_id.root_path,          "/org/a11y/atspi/accessible/7/0", "/",
        "/org",                       "/org/a11y",                      "/org/a11y/atspi",
        "/org/a11y/atspi/accessible", "/org/a11y/atspi/accessible/7",
    };
    const standard_names = [_][]const u8{
        "org.freedesktop.DBus.Peer",       "org.freedesktop.DBus.Introspectable",
        "org.freedesktop.DBus.Properties",
    };
    const value: dbus.Variant = .{ .signature = "i", .value = .{ .int32 = 23 } };
    for (paths) |path| {
        var ping = try handle(gpa, &register, .{
            .kind = .method_call,
            .serial = 41,
            .path = path,
            .interface = "org.freedesktop.DBus.Peer",
            .member = "Ping",
        });
        defer ping.body.deinit();
        try std.testing.expect(ping.error_name == null);
        try std.testing.expectEqualStrings("", ping.body.signature);
        try std.testing.expectEqual(@as(usize, 0), ping.body.values.len);
        var machine = try handle(gpa, &register, .{
            .kind = .method_call,
            .serial = 42,
            .path = path,
            .interface = "org.freedesktop.DBus.Peer",
            .member = "GetMachineId",
        });
        defer machine.body.deinit();
        try std.testing.expect(machine.error_name == null);
        try std.testing.expectEqualStrings("s", machine.body.signature);
        try std.testing.expectEqualStrings("0102030405060708090a0b0c0d0e0f10", machine.body.values[0].string);
        var xml = try handle(gpa, &register, .{
            .kind = .method_call,
            .serial = 43,
            .path = path,
            .interface = "org.freedesktop.DBus.Introspectable",
            .member = "Introspect",
        });
        defer xml.body.deinit();
        try std.testing.expect(xml.error_name == null);
        try std.testing.expect(
            std.mem.indexOf(
                u8,
                xml.body.values[0].string,
                "<signal name=\"PropertiesChanged\"><arg type=\"s\"/>" ++
                    "<arg type=\"a{sv}\"/><arg type=\"as\"/></signal>",
            ) != null,
        );
        for (standard_names) |target| {
            try std.testing.expect(std.mem.indexOf(u8, xml.body.values[0].string, target) != null);
            var all = try handle(gpa, &register, .{
                .kind = .method_call,
                .serial = 44,
                .path = path,
                .interface = "org.freedesktop.DBus.Properties",
                .member = "GetAll",
                .signature = "s",
                .body = &.{.{ .string = target }},
            });
            defer all.body.deinit();
            try std.testing.expect(all.error_name == null);
            try std.testing.expectEqualStrings("a{sv}", all.body.signature);
            try std.testing.expectEqual(@as(usize, 1), all.body.values.len);
            try std.testing.expectEqualStrings("{sv}", all.body.values[0].array.element_signature);
            try std.testing.expectEqual(@as(usize, 0), all.body.values[0].array.values.len);
            for ([_][]const u8{ "Get", "Set" }) |member| {
                const args = [_]dbus.Value{
                    .{ .string = target }, .{ .string = "P" }, .{ .variant = &value },
                };
                const is_set = std.mem.eql(u8, member, "Set");
                var missing = try handle(gpa, &register, .{
                    .kind = .method_call,
                    .serial = 45,
                    .path = path,
                    .interface = "org.freedesktop.DBus.Properties",
                    .member = member,
                    .signature = if (is_set) "ssv" else "ss",
                    .body = if (is_set) &args else args[0..2],
                });
                defer missing.body.deinit();
                try std.testing.expectEqualStrings("org.freedesktop.DBus.Error.UnknownProperty", missing.error_name.?);
                try std.testing.expectEqualStrings("s", missing.body.signature);
                try std.testing.expectEqual(@as(usize, 1), missing.body.values.len);
                try std.testing.expectEqualStrings("Unknown property 'P'", missing.body.values[0].string);
            }
        }
        var long_name = @as([256]u8, @splat('a'));
        long_name[1] = '.';
        const invalid_names = [_][]const u8{
            "",          "Undotted", ".org.Name", "org.Name.", "org..Name", "org.1Name",
            "org.Na-me",
            "org.é",
            &long_name,
        };
        for (invalid_names) |target| {
            for ([_][]const u8{ "GetAll", "Get", "Set" }) |member| {
                const args = [_]dbus.Value{
                    .{ .string = target }, .{ .string = "P" }, .{ .variant = &value },
                };
                const count: usize = if (std.mem.eql(u8, member, "GetAll"))
                    1
                else if (std.mem.eql(u8, member, "Get"))
                    2
                else
                    3;
                var invalid = try handle(gpa, &register, .{
                    .kind = .method_call,
                    .serial = 46,
                    .path = path,
                    .interface = "org.freedesktop.DBus.Properties",
                    .member = member,
                    .signature = switch (count) {
                        1 => "s",
                        2 => "ss",
                        else => "ssv",
                    },
                    .body = args[0..count],
                });
                defer invalid.body.deinit();
                try std.testing.expectEqualStrings("org.freedesktop.zbus.Error", invalid.error_name.?);
                try std.testing.expectEqualStrings("s", invalid.body.signature);
                try std.testing.expectEqualStrings("Invalid interface name. See " ++
                    "https://dbus.freedesktop.org/doc/dbus-specification.html" ++
                    "#message-protocol-names-interface", invalid.body.values[0].string);
            }
        }
        for ([_][]const u8{ "org.example.Unknown", "_org._Name9", long_name[0..255] }) |target| {
            var unknown = try handle(gpa, &register, .{
                .kind = .method_call,
                .serial = 47,
                .path = path,
                .interface = "org.freedesktop.DBus.Properties",
                .member = "GetAll",
                .signature = "s",
                .body = &.{.{ .string = target }},
            });
            defer unknown.body.deinit();
            try std.testing.expectEqualStrings("org.freedesktop.DBus.Error.UnknownInterface", unknown.error_name.?);
            var expected_buffer: [300]u8 = undefined;
            const expected = try std.fmt.bufPrint(&expected_buffer, "Unknown interface '{s}'", .{target});
            try std.testing.expectEqualStrings(expected, unknown.body.values[0].string);
            var direct = try handle(gpa, &register, .{
                .kind = .method_call,
                .serial = 49,
                .path = path,
                .interface = target,
                .member = "UnknownMethod",
            });
            defer direct.body.deinit();
            try std.testing.expectEqualStrings("org.freedesktop.DBus.Error.UnknownInterface", direct.error_name.?);
            try std.testing.expectEqualStrings(expected, direct.body.values[0].string);
        }
    }
    fixture.app.removeAdapter(7);
    try register.sync();
    for ([_][]const u8{
        "/org/a11y/atspi/accessible/7/0", "/org/a11y/atspi/accessible/7",
        "/org/a11y/atspi/accessible/70",  "/org/a11y/atspi/accessible/root/child",
        "/org/a11y/atspi/accessible/",    "/org/a11y/atsp",
    }) |path| {
        var removed = try handle(gpa, &register, .{
            .kind = .method_call,
            .serial = 48,
            .path = path,
            .interface = "org.freedesktop.DBus.Peer",
            .member = "Ping",
        });
        defer removed.body.deinit();
        try std.testing.expectEqualStrings(adapter_error.error_unknown_object, removed.error_name.?);
        try std.testing.expectEqualStrings(path, removed.body.values[0].string);
    }
}

test "AT-SPI optional positioned wire edits mutate the real Unicode consumer tree" {
    try positionedEditingRoundtrip(std.testing.allocator);
}

test "AT-SPI positioned FIFO edits use the live host model before consumer publication" {
    try positionedDeferredPublicationRoundtrip(std.testing.allocator);
}

test "AT-SPI positioned edit capability refuses disabled and read only consumer nodes" {
    try positionedEditabilityRoundtrip(std.testing.allocator);
}

test "AT-SPI optional positioned wire edits release every allocation under fail N" {
    // SafeAllocator remapping can change the allocation count between runs.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), positionedEditingRoundtrip, .{});
    try std.testing.checkAllAllocationFailures(backing.allocator(), positionedDeferredPublicationRoundtrip, .{});
    try std.testing.checkAllAllocationFailures(backing.allocator(), positionedEditabilityRoundtrip, .{});
}

const PositionedEditingHost = struct {
    fixture: *implementations.text.TestFixture,
    gpa: std.mem.Allocator,
    live_text: std.ArrayList(u8),
    publish: bool = true,
    count: usize = 0,
    accept: bool = true,
    failure: ?objects.ActionDeliveryError = null,
    expected_replacement: []const u8 = "Ω😀",
    replacement_matched: bool = false,
    start_scalar: u32 = 0,
    end_scalar: u32 = 0,
    target: ?tree_index.FullNodeId = null,

    fn receive(pointer: ?*anyopaque, request: *const objects.EditableTextRequest) objects.ActionDeliveryError!bool {
        const self: *PositionedEditingHost = @ptrCast(@alignCast(pointer.?));
        self.count += 1;
        self.start_scalar = request.start_scalar;
        self.end_scalar = request.end_scalar;
        self.target = request.target;
        self.replacement_matched = std.mem.eql(u8, self.expected_replacement, request.replacement_utf8);
        if (self.failure) |err| return err;
        if (!self.accept) return false;
        const scalar_count = std.unicode.utf8CountCodepoints(self.live_text.items) catch return error.CallbackFailed;
        if (request.end_scalar > scalar_count) return false;
        const start_byte = scalarByteOffset(self.live_text.items, request.start_scalar);
        const end_byte = scalarByteOffset(self.live_text.items, request.end_scalar);
        var contents: std.ArrayList(u8) = .empty;
        defer contents.deinit(self.gpa);
        try contents.appendSlice(self.gpa, self.live_text.items[0..start_byte]);
        try contents.appendSlice(self.gpa, request.replacement_utf8);
        try contents.appendSlice(self.gpa, self.live_text.items[end_byte..]);
        std.mem.swap(std.ArrayList(u8), &self.live_text, &contents);
        if (!self.publish) return true;
        var lengths: std.ArrayList(u8) = .empty;
        defer lengths.deinit(self.gpa);
        const view = std.unicode.Utf8View.init(self.live_text.items) catch return error.CallbackFailed;
        var iterator = view.iterator();
        while (iterator.nextCodepointSlice()) |scalar| {
            try lengths.append(self.gpa, @intCast(scalar.len));
        }
        var run = schema.Node.init(self.gpa, .text_run);
        var run_transferred = false;
        errdefer if (!run_transferred) run.deinit();
        try schema.strings.setValue(&run.properties, self.live_text.items);
        try schema.vectors.setCharacterLengths(&run.properties, lengths.items);
        var update: schema.TreeUpdate = .{};
        var update_transferred = false;
        errdefer if (!update_transferred) update.deinit(self.gpa);
        run_transferred = true;
        try update.pushNode(self.gpa, .{ .value = 1 }, run);
        update.focus = .{ .value = 0 };
        const handler: tree.TreeChangeHandler = .{ .ptr = self };
        update_transferred = true;
        self.fixture.tree.updateAndProcessChanges(update, &handler) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.CallbackFailed;
        };
        self.fixture.node_context.state = self.fixture.tree.stateOf();
        return true;
    }
};

fn scalarByteOffset(text: []const u8, offset: u32) usize {
    var position: usize = 0;
    var remaining = offset;
    while (position < text.len and remaining != 0) : (remaining -= 1) {
        // Both the decoded wire string and the host model contain valid UTF-8.
        position += std.unicode.utf8ByteSequenceLength(text[position]) catch unreachable;
    }
    std.debug.assert(remaining == 0);
    return position;
}

fn positionedWireRequest(
    gpa: std.mem.Allocator,
    register: *objects.Register,
    member: []const u8,
    signature_text: []const u8,
    values: []const dbus.Value,
) dbus.CodecError!dbus.OwnedReply {
    const bytes = try dbus.encode(gpa, .{
        .kind = .method_call,
        .serial = 61,
        .sender = ":1.55",
        .path = "/org/a11y/atspi/accessible/7/0",
        .interface = wire.interface_editable_text,
        .member = member,
        .signature = signature_text,
        .body = values,
    }, .little, .{});
    defer gpa.free(bytes);
    var frame = try dbus.decode(gpa, bytes, .{});
    defer frame.deinit();
    return handle(gpa, register, frame.message);
}

fn positionedTextReadback(gpa: std.mem.Allocator, register: *objects.Register, expected: []const u8) !void {
    var text_reply = try handle(gpa, register, .{
        .kind = .method_call,
        .serial = 62,
        .path = "/org/a11y/atspi/accessible/7/0",
        .interface = wire.interface_text,
        .member = "GetText",
        .signature = "ii",
        .body = &.{ .{ .int32 = 0 }, .{ .int32 = -1 } },
    });
    defer text_reply.body.deinit();
    try std.testing.expect(text_reply.error_name == null);
    try std.testing.expectEqualStrings("s", text_reply.body.signature);
    try std.testing.expectEqualStrings(expected, text_reply.body.values[0].string);
}

fn positionedEditingRoundtrip(gpa: std.mem.Allocator) !void {
    // Owned replies outlive decoded frames; the host commits actual tree updates.
    var fixture: implementations.text.TestFixture = undefined;
    try fixture.init(gpa, .text_input);
    defer fixture.deinit();
    try fixture.app.pushAdapter(7, &fixture.node_context);
    var register = objects.Register.init(gpa, &fixture.app);
    defer register.deinit();
    register.bus_name = ":1.42";
    try register.sync();
    const platform = node.PlatformNode.init(&fixture.node_context, 7, .init(.{ .value = 0 }, .init(0)));
    var host: PositionedEditingHost = .{
        .fixture = &fixture,
        .gpa = gpa,
        .live_text = try platform.text(0, -1),
    };
    defer host.live_text.deinit(gpa);
    var stock = try positionedWireRequest(gpa, &register, "InsertText", "isi", &.{
        .{ .int32 = 3 },
        .{ .string = "Ω😀" },
        .{ .int32 = 6 },
    });
    defer stock.body.deinit();
    try std.testing.expectEqualStrings(adapter_error.error_not_supported, stock.error_name.?);
    var stock_delete = try positionedWireRequest(gpa, &register, "DeleteText", "ii", &.{
        .{ .int32 = 0 }, .{ .int32 = 1 },
    });
    defer stock_delete.body.deinit();
    try std.testing.expectEqualStrings(adapter_error.error_not_supported, stock_delete.error_name.?);
    try positionedTextReadback(gpa, &register, "Aé😀éZ");
    register.editable_text_sink = .{ .context = &host, .raise = PositionedEditingHost.receive };
    var inserted = try positionedWireRequest(gpa, &register, "InsertText", "isi", &.{
        .{ .int32 = 3 },
        .{ .string = "Ω😀" },
        .{ .int32 = 6 },
    });
    defer inserted.body.deinit();
    try std.testing.expect(inserted.error_name == null);
    try std.testing.expectEqualStrings("b", inserted.body.signature);
    try std.testing.expect(inserted.body.values[0].boolean);
    try std.testing.expectEqual(@as(usize, 1), host.count);
    try std.testing.expectEqual(@as(u32, 3), host.start_scalar);
    try std.testing.expectEqual(@as(u32, 3), host.end_scalar);
    try std.testing.expectEqual(@as(u64, 0), host.target.?.local.value);
    try std.testing.expectEqual(@as(u32, 0), host.target.?.tree_index.value());
    try std.testing.expect(host.replacement_matched);
    try positionedTextReadback(gpa, &register, "Aé😀Ω😀éZ");
    host.expected_replacement = "";
    var deleted = try positionedWireRequest(gpa, &register, "DeleteText", "ii", &.{
        .{ .int32 = 1 }, .{ .int32 = 3 },
    });
    defer deleted.body.deinit();
    try std.testing.expect(deleted.error_name == null);
    try std.testing.expect(deleted.body.values[0].boolean);
    try std.testing.expectEqual(@as(usize, 2), host.count);
    try std.testing.expectEqual(@as(u32, 1), host.start_scalar);
    try std.testing.expectEqual(@as(u32, 3), host.end_scalar);
    try std.testing.expect(host.replacement_matched);
    try positionedTextReadback(gpa, &register, "AΩ😀éZ");
    for ([_][2]i32{ .{ -1, 2 }, .{ 4, 2 } }) |span| {
        var invalid = try positionedWireRequest(gpa, &register, "DeleteText", "ii", &.{
            .{ .int32 = span[0] }, .{ .int32 = span[1] },
        });
        defer invalid.body.deinit();
        try std.testing.expectEqualStrings(adapter_error.error_invalid_args, invalid.error_name.?);
        try std.testing.expectEqual(@as(usize, 2), host.count);
        try positionedTextReadback(gpa, &register, "AΩ😀éZ");
    }
    var negative = try positionedWireRequest(gpa, &register, "InsertText", "isi", &.{
        .{ .int32 = -1 },
        .{ .string = "Ω😀" },
        .{ .int32 = 6 },
    });
    defer negative.body.deinit();
    try std.testing.expectEqualStrings(adapter_error.error_invalid_args, negative.error_name.?);
    try std.testing.expectEqual(@as(usize, 2), host.count);
    var negative_length = try positionedWireRequest(gpa, &register, "InsertText", "isi", &.{
        .{ .int32 = 0 },
        .{ .string = "Ω😀" },
        .{ .int32 = -1 },
    });
    defer negative_length.body.deinit();
    try std.testing.expectEqualStrings(adapter_error.error_invalid_args, negative_length.error_name.?);
    try std.testing.expectEqual(@as(usize, 2), host.count);
    var past_live_delete = try positionedWireRequest(gpa, &register, "DeleteText", "ii", &.{
        .{ .int32 = 0 }, .{ .int32 = 7 },
    });
    defer past_live_delete.body.deinit();
    try std.testing.expectEqualStrings(adapter_error.error_failed, past_live_delete.error_name.?);
    try std.testing.expectEqualStrings("CallbackFailed", past_live_delete.body.values[0].string);
    try std.testing.expectEqual(@as(usize, 3), host.count);
    var past_live_insert = try positionedWireRequest(gpa, &register, "InsertText", "isi", &.{
        .{ .int32 = 7 },
        .{ .string = "Ω😀" },
        .{ .int32 = 6 },
    });
    defer past_live_insert.body.deinit();
    try std.testing.expectEqualStrings(adapter_error.error_failed, past_live_insert.error_name.?);
    try std.testing.expectEqualStrings("CallbackFailed", past_live_insert.body.values[0].string);
    try std.testing.expectEqual(@as(usize, 4), host.count);
    try positionedTextReadback(gpa, &register, "AΩ😀éZ");
    host.accept = false;
    var rejected = try positionedWireRequest(gpa, &register, "DeleteText", "ii", &.{
        .{ .int32 = 0 }, .{ .int32 = 1 },
    });
    defer rejected.body.deinit();
    try std.testing.expectEqualStrings(adapter_error.error_failed, rejected.error_name.?);
    try std.testing.expectEqualStrings("CallbackFailed", rejected.body.values[0].string);
    try std.testing.expectEqual(@as(usize, 5), host.count);
    try positionedTextReadback(gpa, &register, "AΩ😀éZ");
    host.failure = error.Closed;
    var failed = try positionedWireRequest(gpa, &register, "DeleteText", "ii", &.{
        .{ .int32 = 0 }, .{ .int32 = 1 },
    });
    defer failed.body.deinit();
    try std.testing.expectEqualStrings(adapter_error.error_failed, failed.error_name.?);
    try std.testing.expectEqualStrings("Closed", failed.body.values[0].string);
    try std.testing.expectEqual(@as(usize, 6), host.count);
    try positionedTextReadback(gpa, &register, "AΩ😀éZ");
    host.failure = null;
    host.accept = true;
    var zero = try positionedWireRequest(gpa, &register, "InsertText", "isi", &.{
        .{ .int32 = 0 },
        .{ .string = "Ω😀" },
        .{ .int32 = 0 },
    });
    defer zero.body.deinit();
    try std.testing.expect(zero.error_name == null);
    try std.testing.expect(zero.body.values[0].boolean);
    try std.testing.expectEqual(@as(usize, 7), host.count);
    try std.testing.expect(host.replacement_matched);
    try positionedTextReadback(gpa, &register, "AΩ😀éZ");
    host.expected_replacement = "Ω";
    var prefix = try positionedWireRequest(gpa, &register, "InsertText", "isi", &.{
        .{ .int32 = 0 },
        .{ .string = "Ω😀" },
        .{ .int32 = 2 },
    });
    defer prefix.body.deinit();
    try std.testing.expect(prefix.error_name == null);
    try std.testing.expect(prefix.body.values[0].boolean);
    try std.testing.expectEqual(@as(usize, 8), host.count);
    try std.testing.expect(host.replacement_matched);
    try positionedTextReadback(gpa, &register, "ΩAΩ😀éZ");
    for ([_]i32{ 1, 3 }) |byte_length| {
        var split = try positionedWireRequest(gpa, &register, "InsertText", "isi", &.{
            .{ .int32 = 0 },
            .{ .string = "Ω😀" },
            .{ .int32 = byte_length },
        });
        defer split.body.deinit();
        try std.testing.expectEqualStrings(adapter_error.error_invalid_args, split.error_name.?);
        try std.testing.expectEqual(@as(usize, 8), host.count);
        try positionedTextReadback(gpa, &register, "ΩAΩ😀éZ");
    }
    host.expected_replacement = "Ω😀";
    var clipped = try positionedWireRequest(gpa, &register, "InsertText", "isi", &.{
        .{ .int32 = 0 },
        .{ .string = "Ω😀" },
        .{ .int32 = std.math.maxInt(i32) },
    });
    defer clipped.body.deinit();
    try std.testing.expect(clipped.error_name == null);
    try std.testing.expect(clipped.body.values[0].boolean);
    try std.testing.expectEqual(@as(usize, 9), host.count);
    try std.testing.expect(host.replacement_matched);
    try positionedTextReadback(gpa, &register, "Ω😀ΩAΩ😀éZ");
}

fn positionedDeferredPublicationRoundtrip(gpa: std.mem.Allocator) !void {
    // FIFO requests reach the live model even while the published tree is stale.
    var fixture: implementations.text.TestFixture = undefined;
    try fixture.init(gpa, .text_input);
    defer fixture.deinit();
    try fixture.app.pushAdapter(7, &fixture.node_context);
    var register = objects.Register.init(gpa, &fixture.app);
    defer register.deinit();
    register.bus_name = ":1.42";
    try register.sync();
    const platform = node.PlatformNode.init(&fixture.node_context, 7, .init(.{ .value = 0 }, .init(0)));
    var host: PositionedEditingHost = .{
        .fixture = &fixture,
        .gpa = gpa,
        .live_text = try platform.text(0, -1),
        .publish = false,
    };
    defer host.live_text.deinit(gpa);
    register.editable_text_sink = .{ .context = &host, .raise = PositionedEditingHost.receive };
    var first = try positionedWireRequest(gpa, &register, "InsertText", "isi", &.{
        .{ .int32 = 6 },
        .{ .string = "Ω😀" },
        .{ .int32 = 6 },
    });
    defer first.body.deinit();
    try std.testing.expect(first.error_name == null);
    try std.testing.expect(first.body.values[0].boolean);
    try std.testing.expectEqual(@as(usize, 1), host.count);
    try positionedTextReadback(gpa, &register, "Aé😀éZ");
    host.expected_replacement = "Ω";
    var second = try positionedWireRequest(gpa, &register, "InsertText", "isi", &.{
        .{ .int32 = 8 },
        .{ .string = "Ω" },
        .{ .int32 = 2 },
    });
    defer second.body.deinit();
    try std.testing.expect(second.error_name == null);
    try std.testing.expect(second.body.values[0].boolean);
    try std.testing.expectEqual(@as(usize, 2), host.count);
    try std.testing.expectEqual(@as(u32, 8), host.start_scalar);
    try std.testing.expectEqual(@as(u32, 8), host.end_scalar);
    try std.testing.expect(host.replacement_matched);
    try positionedTextReadback(gpa, &register, "Aé😀éZ");
    host.publish = true;
    host.expected_replacement = "";
    var publish = try positionedWireRequest(gpa, &register, "InsertText", "isi", &.{
        .{ .int32 = 9 }, .{ .string = "" }, .{ .int32 = 0 },
    });
    defer publish.body.deinit();
    try std.testing.expect(publish.error_name == null);
    try std.testing.expect(publish.body.values[0].boolean);
    try std.testing.expectEqual(@as(usize, 3), host.count);
    try std.testing.expect(host.replacement_matched);
    try positionedTextReadback(gpa, &register, "Aé😀éZΩ😀Ω");
}

fn positionedEditabilityRoundtrip(gpa: std.mem.Allocator) !void {
    // Full root-node updates preserve children and selection while changing flags.
    for ([_]bool{ false, true }) |disabled| {
        var fixture: implementations.text.TestFixture = undefined;
        try fixture.init(gpa, .text_input);
        defer fixture.deinit();
        const id = tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
        const old_root = fixture.tree.stateOf().nodeById(id).?;
        var root = try schema.Node.clone(gpa, old_root.data());
        var root_transferred = false;
        errdefer if (!root_transferred) root.deinit();
        if (disabled) schema.flags.setDisabled(&root.flags, true) else schema.flags.setReadOnly(&root.flags, true);
        var update: schema.TreeUpdate = .{};
        var update_transferred = false;
        errdefer if (!update_transferred) update.deinit(gpa);
        update.focus = .{ .value = 0 };
        root_transferred = true;
        try update.pushNode(gpa, .{ .value = 0 }, root);
        const handler: tree.TreeChangeHandler = .{ .ptr = &fixture };
        update_transferred = true;
        try fixture.tree.updateAndProcessChanges(update, &handler);
        fixture.node_context.state = fixture.tree.stateOf();
        try fixture.app.pushAdapter(7, &fixture.node_context);
        var register = objects.Register.init(gpa, &fixture.app);
        defer register.deinit();
        register.bus_name = ":1.42";
        try register.sync();
        const platform = node.PlatformNode.init(&fixture.node_context, 7, id);
        var host: PositionedEditingHost = .{
            .fixture = &fixture,
            .gpa = gpa,
            .live_text = try platform.text(0, -1),
        };
        defer host.live_text.deinit(gpa);
        register.editable_text_sink = .{ .context = &host, .raise = PositionedEditingHost.receive };
        var insert = try positionedWireRequest(gpa, &register, "InsertText", "isi", &.{
            .{ .int32 = 0 },
            .{ .string = "Ω😀" },
            .{ .int32 = 6 },
        });
        defer insert.body.deinit();
        try std.testing.expect(insert.error_name == null);
        try std.testing.expectEqualStrings("b", insert.body.signature);
        try std.testing.expect(!insert.body.values[0].boolean);
        var delete = try positionedWireRequest(gpa, &register, "DeleteText", "ii", &.{
            .{ .int32 = 0 }, .{ .int32 = 1 },
        });
        defer delete.body.deinit();
        try std.testing.expect(delete.error_name == null);
        try std.testing.expectEqualStrings("b", delete.body.signature);
        try std.testing.expect(!delete.body.values[0].boolean);
        try std.testing.expectEqual(@as(usize, 0), host.count);
        try positionedTextReadback(gpa, &register, "Aé😀éZ");
    }
}

test "AT-SPI positioned edit reply limits prevent host mutation before delivery" {
    var fixture: implementations.text.TestFixture = undefined;
    try fixture.init(std.testing.allocator, .text_input);
    defer fixture.deinit();
    try fixture.app.pushAdapter(7, &fixture.node_context);
    var register = objects.Register.init(std.testing.allocator, &fixture.app);
    defer register.deinit();
    register.bus_name = ":1.42";
    try register.sync();
    const platform = node.PlatformNode.init(&fixture.node_context, 7, .init(.{ .value = 0 }, .init(0)));
    var host: PositionedEditingHost = .{
        .fixture = &fixture,
        .gpa = std.testing.allocator,
        .live_text = try platform.text(0, -1),
    };
    defer host.live_text.deinit(std.testing.allocator);
    register.editable_text_sink = .{ .context = &host, .raise = PositionedEditingHost.receive };
    register.limits.max_frame_bytes = 32;
    try std.testing.expectError(
        error.LimitExceeded,
        positionedWireRequest(
            std.testing.allocator,
            &register,
            "InsertText",
            "isi",
            &.{
                .{ .int32 = 3 },
                .{ .string = "Ω😀" },
                .{ .int32 = 6 },
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), host.count);
    register.limits = .{};
    try positionedTextReadback(std.testing.allocator, &register, "Aé😀éZ");
}
