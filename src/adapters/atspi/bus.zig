//! Native D-Bus startup and owned Unix connections. The pump owns post-startup I/O.
//! Source mapping: AccessKit 466e24e252103f4d82bd6fbab98141b551e46e0c
//! adapters/unix/src/atspi/bus.rs:37-70 (connection startup), :84-129 (Embed desktop),
//! and context.rs:169-219 (Status monitoring). D-Bus specification v0.43 defines
//! EXTERNAL authentication, Hello, sender identities and service-activation calls.
//! zio 2662fdc45997611b962b560c513c16963475a01b net.zig:685-773,1206-1257 provides
//! public Unix streams; runtime.zig:1816,260 provides explicit owned tasks.
const std = @import("std");
const zio = @import("zio");
const dbus = @import("dbus.zig");
const address = @import("address.zig");

test "EXTERNAL encodes decimal uid bytes as hexadecimal with initial NUL" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "\x00AUTH EXTERNAL 30\r\n", authCommand(0, &buffer));
    try std.testing.expectEqualSlices(u8, "\x00AUTH EXTERNAL 3333313536\r\n", authCommand(33156, &buffer));
    try std.testing.expectEqualSlices(u8, "\x00AUTH EXTERNAL 34323934393637323935\r\n", authCommand(std.math.maxInt(u32), &buffer));
}

test "EXTERNAL accepts only OK and a full hexadecimal GUID" {
    try validateAuth("OK 0123456789abcdef0123456789ABCDEF\r\n");
    const rejected = [_][]const u8{
        "REJECTED EXTERNAL\r\n",                         "DATA\r\n",                                "OK\r\n",
        "OK 0123456789abcdef0123456789abcde\r\n",        "OK 0123456789abcdef0123456789abcdeg\r\n", "OK 0123456789abcdef0123456789abcdef\n",
        "OK 0123456789abcdef0123456789abcdef extra\r\n",
    };
    for (rejected) |line| try std.testing.expectError(error.AuthenticationFailed, validateAuth(line));
}

test "reply matching excludes signals methods and unrelated reply serials" {
    try std.testing.expect(matchesReply(.{ .kind = .method_return, .reply_serial = 7 }, 7));
    try std.testing.expect(matchesReply(.{ .kind = .error_reply, .reply_serial = 7 }, 7));
    try std.testing.expect(!matchesReply(.{ .kind = .method_return, .reply_serial = 6 }, 7));
    try std.testing.expect(!matchesReply(.{ .kind = .signal, .reply_serial = 7 }, 7));
    try std.testing.expect(!matchesReply(.{ .kind = .method_call, .reply_serial = 7 }, 7));
}

test "status property Get requires exactly one boolean variant" {
    const enabled: dbus.Variant = .{ .signature = "b", .value = .{ .boolean = true } };
    const disabled: dbus.Variant = .{ .signature = "b", .value = .{ .boolean = false } };
    try std.testing.expect(try statusEnabled(.{ .kind = .method_return, .signature = "v", .body = &.{.{ .variant = &enabled }} }));
    try std.testing.expect(!try statusEnabled(.{ .kind = .method_return, .signature = "v", .body = &.{.{ .variant = &disabled }} }));
    try std.testing.expectError(error.InvalidReply, statusEnabled(.{ .kind = .method_return, .signature = "b", .body = &.{.{ .boolean = true }} }));
}

test "PropertiesChanged selects IsEnabled and identifies invalidation" {
    const enabled: dbus.Variant = .{ .signature = "b", .value = .{ .boolean = true } };
    const pair = [_]dbus.Value{ .{ .string = "IsEnabled" }, .{ .variant = &enabled } };
    const entries = [_]dbus.Value{.{ .dict_entry = &pair }};
    const body = [_]dbus.Value{
        .{ .string = "org.a11y.Status" },
        .{ .array = .{ .element_signature = "{sv}", .values = &entries } },
        .{ .array = .{ .element_signature = "s", .values = &.{} } },
    };
    var message: dbus.Message = .{ .kind = .signal, .path = "/org/a11y/bus", .interface = "org.freedesktop.DBus.Properties", .member = "PropertiesChanged", .signature = "sa{sv}as", .body = &body };
    try std.testing.expectEqual(@as(?bool, true), try statusChange(message));
    try std.testing.expect(!try statusInvalidated(message));
    var invalidated_body = body;
    invalidated_body[1].array.values = &.{};
    invalidated_body[2].array.values = &.{.{ .string = "IsEnabled" }};
    message.body = &invalidated_body;
    try std.testing.expectEqual(@as(?bool, null), try statusChange(message));
    try std.testing.expect(try statusInvalidated(message));
    message.path = "/other";
    try std.testing.expectEqual(@as(?bool, null), try statusChange(message));
    try std.testing.expect(!try statusInvalidated(message));
}

test "Embed supplies own unique bus name and configured root as one structure" {
    var fields: [2]dbus.Value = undefined;
    var body: [1]dbus.Value = undefined;
    const request = embedRequest(":1.42", "/org/a11y/atspi/accessible/root", &fields, &body);
    try std.testing.expectEqualStrings("org.a11y.atspi.Registry", request.destination.?);
    try std.testing.expectEqualStrings("org.a11y.atspi.Socket", request.interface.?);
    try std.testing.expectEqualStrings("Embed", request.member.?);
    try std.testing.expectEqualStrings("(so)", request.signature);
    try std.testing.expectEqualStrings(":1.42", request.body[0].structure[0].string);
    try std.testing.expectEqualStrings("/org/a11y/atspi/accessible/root", request.body[0].structure[1].object_path);
}

fn retainedReferenceSweep(gpa: std.mem.Allocator) !void {
    var reference = try RetainedReference.init(gpa, .{ .bus_name = ":1.2", .path = "/org/a11y/atspi/accessible/root" });
    defer reference.deinit(gpa);
    try std.testing.expectEqualStrings(":1.2", reference.value().bus_name);
    var diagnostic = Diagnostic{};
    defer diagnostic.deinit(gpa);
    try diagnostic.set(gpa, "org.freedesktop.DBus.Error.ServiceUnknown");
    try std.testing.expectEqualStrings("org.freedesktop.DBus.Error.ServiceUnknown", diagnostic.name.?);
}

test "retained desktop and remote error diagnostics release every fail N allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, retainedReferenceSweep, .{});
}

const AuthTranscript = struct {
    input: []const u8,
    cursor: usize = 0,
    output: [128]u8 = undefined,
    output_length: usize = 0,

    fn readExact(self: *AuthTranscript, bytes: []u8) Error!void {
        if (bytes.len > self.input.len - self.cursor) return error.EndOfStream;
        @memcpy(bytes, self.input[self.cursor..][0..bytes.len]);
        self.cursor += bytes.len;
    }

    fn writeBytes(self: *AuthTranscript, bytes: []const u8) Error!void {
        if (bytes.len > self.output.len - self.output_length) return error.AuthenticationFailed;
        @memcpy(self.output[self.output_length..][0..bytes.len], bytes);
        self.output_length += bytes.len;
    }
};

test "authentication transcript sends BEGIN without FD negotiation and leaves binary bytes unread" {
    var transport: AuthTranscript = .{
        .input = "OK 0123456789abcdef0123456789abcdef\r\nl",
    };
    try authenticateTransport(&transport, 33156);
    try std.testing.expectEqualSlices(u8, "\x00AUTH EXTERNAL 3333313536\r\nBEGIN\r\n", transport.output[0..transport.output_length]);
    try std.testing.expectEqual(@as(u8, 'l'), transport.input[transport.cursor]);
}

test "authentication bounds line bytes and propagates truncated transcript" {
    var oversized: AuthTranscript = .{ .input = "x" ** auth_line_bytes_max };
    try std.testing.expectError(error.AuthenticationLineTooLong, authenticateTransport(&oversized, 1));
    var truncated: AuthTranscript = .{ .input = "OK 0123" };
    try std.testing.expectError(error.EndOfStream, authenticateTransport(&truncated, 1));
}

test "serial exhaustion never reuses a serial or produces zero" {
    var connection: Connection = undefined;
    connection.next_serial = std.math.maxInt(u32) - 1;
    try std.testing.expectEqual(std.math.maxInt(u32) - 1, try connection.nextSerial());
    try std.testing.expectEqual(std.math.maxInt(u32), try connection.nextSerial());
    try std.testing.expectError(error.SerialExhausted, connection.nextSerial());
}

test "Unix address preserves all 107 abstract name bytes including prefix" {
    var name = [_]u8{'x'} ** 107;
    const endpoint = try unixAddress(.{ .kind = .abstract, .name = &name });
    try std.testing.expectEqual(@as(u8, 0), endpoint.un.path[0]);
    try std.testing.expectEqualSlices(u8, &name, endpoint.un.path[1..]);
    const filesystem = try unixAddress(.{ .kind = .path, .name = &name });
    try std.testing.expectEqualSlices(u8, &name, filesystem.un.path[0..107]);
    try std.testing.expectEqual(@as(u8, 0), filesystem.un.path[107]);
}

fn busOwnershipSweep(gpa: std.mem.Allocator) !void {
    var bus: Bus = .{ .gpa = gpa, .io = .failing, .runtime = undefined, .uid = 1, .limits = .{}, .root_path = try gpa.dupe(u8, registry_root) };
    defer bus.deinit();
    const name_change: dbus.Message = .{
        .kind = .signal,
        .sender = "org.freedesktop.DBus",
        .path = "/org/freedesktop/DBus",
        .interface = "org.freedesktop.DBus",
        .member = "NameOwnerChanged",
        .signature = "sss",
        .body = &.{ .{ .string = "org.a11y.Bus" }, .{ .string = "" }, .{ .string = ":1.42" } },
    };
    try std.testing.expect(try bus.refreshStatusOwner(name_change));
    try std.testing.expect(bus.isStatusSender(.{ .kind = .signal, .sender = ":1.42" }));
    try std.testing.expect(!bus.isStatusSender(.{ .kind = .signal, .sender = ":1.43" }));
    var spoof = name_change;
    spoof.sender = ":1.43";
    try std.testing.expect(!try bus.refreshStatusOwner(spoof));
    try bus.updateAddress(.{ .kind = .method_return, .signature = "s", .body = &.{.{ .string = "unix:abstract=initial" }} });
    bus.updateAddress(.{ .kind = .method_return, .signature = "s", .body = &.{.{ .string = "unix:abstract=replacement" }} }) catch |err| {
        try std.testing.expectEqualStrings("unix:abstract=initial", bus.accessibility_address.?);
        return err;
    };
    try std.testing.expectEqualStrings("unix:abstract=replacement", bus.accessibility_address.?);
}

test "status sender ownership and address replacement release each fail N allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, busOwnershipSweep, .{});
}

test "Embed retains the exact desktop reference including a well known bus name" {
    const fields = [_]dbus.Value{ .{ .string = "org.a11y.atspi.Registry" }, .{ .object_path = "/org/a11y/atspi/accessible/root" } };
    const reference = try desktopReply(.{ .kind = .method_return, .signature = "(so)", .body = &.{.{ .structure = &fields }} });
    try std.testing.expectEqualStrings("org.a11y.atspi.Registry", reference.bus_name);
    try std.testing.expectEqualStrings("/org/a11y/atspi/accessible/root", reference.path);
}

fn explicitAddressSweep(gpa: std.mem.Allocator) !void {
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("DBUS_SESSION_BUS_ADDRESS", "unix:path=/unavailable/session");
    var runtime: zio.Runtime = undefined;
    var diagnostic: Diagnostic = .empty;
    defer diagnostic.deinit(gpa);
    var bus = try Bus.init(gpa, .failing, &runtime, .{
        .environ = &environ,
        .uid = 33156,
        .accessibility_address = "unix:abstract=explicit",
        .root_path = "/configured/root",
        .failure_diagnostic = &diagnostic,
    }, null);
    defer bus.deinit();
    try std.testing.expect(diagnostic.name == null);
    try std.testing.expect(bus.enabled);
    try std.testing.expect(bus.force_enabled);
    try std.testing.expect(bus.session == null);
    try std.testing.expect(!bus.isActive());
    try std.testing.expectEqualStrings("/configured/root", bus.root_path);
    try std.testing.expectEqualStrings("unix:abstract=explicit", bus.accessibility_address.?);
}

test "explicit address forces enabled without a session and constructor fails atomically" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, explicitAddressSweep, .{});
}

fn failedConstructorSweep(gpa: std.mem.Allocator) !void {
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var runtime: zio.Runtime = undefined;
    var diagnostic: Diagnostic = .empty;
    defer diagnostic.deinit(gpa);
    var unexpected = Bus.init(gpa, .failing, &runtime, .{
        .environ = &environ,
        .uid = 1,
        .failure_diagnostic = &diagnostic,
    }, null) catch |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(error.MissingSessionAddress, err);
        try std.testing.expect(diagnostic.name == null);
        return;
    };
    unexpected.deinit();
    return error.TestUnexpectedSuccess;
}

test "failed initialization transfers empty diagnostics and releases partial construction" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, failedConstructorSweep, .{});
}

fn ownedFrameSweep(gpa: std.mem.Allocator) !void {
    const recorded = [_]u8{
        'l', 2, 0,   1, 4, 0, 0, 0, 2, 0, 0,   0, 15, 0,   0, 0,
        5,   1, 'u', 0, 1, 0, 0, 0, 8, 1, 'g', 0, 1,  'u', 0, 0,
        42,  0, 0,   0,
    };
    var transcript: AuthTranscript = .{ .input = &recorded };
    var frame = try readOwnedFrom(gpa, &transcript, .{});
    defer frame.deinit();
    try std.testing.expectEqualSlices(u8, &recorded, frame.bytes);
    try std.testing.expectEqual(@as(u32, 42), frame.message.body[0].uint32);
}

test "reading frames transfers one arena and releases every failed allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ownedFrameSweep, .{});
}

fn asyncRemoteErrorSweep(gpa: std.mem.Allocator) !void {
    var bus: Bus = .{ .gpa = gpa, .io = .failing, .runtime = undefined, .uid = 1, .limits = .{}, .root_path = try gpa.dupe(u8, registry_root) };
    defer bus.deinit();
    var name = "org.example.CustomError".*;
    try bus.checkReplyError(.{ .kind = .method_return });
    bus.checkReplyError(.{ .kind = .error_reply, .error_name = &name }) catch |err| {
        if (err != error.RemoteError) return err;
    };
    @memset(&name, 'x');
    try std.testing.expectEqualStrings("org.example.CustomError", bus.remoteErrorName().?);
}

test "asynchronous remote errors retain exact independent names and fail N safely" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, asyncRemoteErrorSweep, .{});
}

fn diagnosticTransferSweep(gpa: std.mem.Allocator) !void {
    var bus: Bus = .{ .gpa = gpa, .io = .failing, .runtime = undefined, .uid = 1, .limits = .{}, .root_path = try gpa.dupe(u8, registry_root) };
    defer bus.deinit();
    bus.checkReplyError(.{ .kind = .error_reply, .error_name = "org.example.EmbedFailure" }) catch |err| {
        if (err != error.RemoteError) return err;
    };
    var diagnostic = bus.takeDiagnostic();
    defer diagnostic.deinit(gpa);
    try std.testing.expect(bus.remoteErrorName() == null);
    bus.deinit();
    try std.testing.expectEqualStrings("org.example.EmbedFailure", diagnostic.name.?);
}

test "taking a diagnostic transfers ownership beyond bus destruction without allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, diagnosticTransferSweep, .{});
}

fn startupRelaySweep(gpa: std.mem.Allocator) !void {
    var bus: Bus = .{ .gpa = gpa, .io = .failing, .runtime = undefined, .uid = 1, .limits = .{}, .root_path = try gpa.dupe(u8, registry_root) };
    defer bus.deinit();
    bus.status_owner = try gpa.dupe(u8, ":1.42");
    var relay: StartupRelay = .{ .native = &bus, .upstream = null };
    const enabled: dbus.Variant = .{ .signature = "b", .value = .{ .boolean = true } };
    const pair = [_]dbus.Value{ .{ .string = "IsEnabled" }, .{ .variant = &enabled } };
    const body = [_]dbus.Value{ .{ .string = status_interface }, .{ .array = .{ .element_signature = "{sv}", .values = &.{.{ .dict_entry = &pair }} } }, .{ .array = .{ .element_signature = "s", .values = &.{} } } };
    var signal: dbus.Message = .{ .kind = .signal, .sender = ":1.42", .path = bus_path, .interface = properties_interface, .member = "PropertiesChanged", .signature = "sa{sv}as", .body = &body };
    try relay.process(signal);
    try std.testing.expect(!bus.enabled);
    bus.startup_owner_snapshot = true;
    try relay.process(signal);
    try std.testing.expect(bus.enabled);
    bus.enabled = false;
    signal.sender = ":1.43";
    try relay.process(signal);
    try std.testing.expect(!bus.enabled);
    signal.sender = ":1.42";
    bus.force_enabled = true;
    try relay.process(signal);
    try std.testing.expect(!bus.enabled);
    bus.force_enabled = false;
    try relay.process(.{ .kind = .signal, .sender = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "NameOwnerChanged", .signature = "sss", .body = &.{ .{ .string = "org.a11y.Bus" }, .{ .string = ":1.42" }, .{ .string = ":1.43" } } });
    try std.testing.expect(bus.startup_owner_changed);
    try std.testing.expect(!bus.enabled);
    try std.testing.expectEqualStrings(":1.43", bus.status_owner.?);
}

test "startup relay authenticates status transitions after owner snapshot and retains owner changes" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, startupRelaySweep, .{});
}

const RelayRequestProbe = struct {
    expected_bus: *Bus,
    expected_connection: *Connection,
    exact_bus: bool = false,
    exact_connection: bool = false,
    exact_message: bool = false,
    calls: usize = 0,
    failure: ?Error = null,

    fn dispatch(
        context: *anyopaque,
        native: *Bus,
        connection: *Connection,
        message: dbus.Message,
    ) Error!void {
        const self: *RelayRequestProbe = @ptrCast(@alignCast(context));
        self.exact_bus = native == self.expected_bus;
        self.exact_connection = connection == self.expected_connection;
        self.exact_message = message.kind == .method_call and
            message.serial == 42 and std.mem.eql(u8, message.member orelse "", "Set");
        self.calls += 1;
        if (self.failure) |err| return err;
    }
};

fn requestRelayForwarding(comptime Relay: type) !void {
    var native: Bus = .{ .gpa = std.testing.allocator, .io = .failing, .runtime = undefined, .uid = 1, .limits = .{}, .root_path = try std.testing.allocator.dupe(u8, registry_root) };
    defer native.deinit();
    var connection: Connection = undefined;
    var probe: RelayRequestProbe = .{
        .expected_bus = &native,
        .expected_connection = &connection,
    };
    var relay: Relay = .{ .native = &native, .upstream = .{ .context = &probe, .dispatch = &RelayRequestProbe.dispatch } };
    const hook: ConnectionRequestHook = .{ .context = &relay, .dispatch = &Relay.dispatch };
    const message: dbus.Message = .{ .kind = .method_call, .serial = 42, .path = registry_root, .interface = properties_interface, .member = "Set" };
    try hook.dispatch(hook.context, &connection, message);
    try std.testing.expect(probe.exact_bus);
    try std.testing.expect(probe.exact_connection);
    try std.testing.expect(probe.exact_message);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    inline for (@typeInfo(Error).error_set.?) |failure| {
        const err: Error = @field(Error, failure.name);
        probe.failure = err;
        try std.testing.expectError(err, hook.dispatch(hook.context, &connection, message));
        try std.testing.expect(probe.exact_bus);
        try std.testing.expect(probe.exact_connection);
        try std.testing.expect(probe.exact_message);
    }
    try std.testing.expectEqual(@as(usize, 1 + @typeInfo(Error).error_set.?.len), probe.calls);
}

test "session startup relay forwards the exact local Bus and every request error" {
    // The real relay borrows constructor-local state, without a transport replacement.
    try requestRelayForwarding(StartupRelay);
}

test "a11y bound request hook forwards the exact current Bus and every request error" {
    // The real wrapper keeps the current Bus available before Hello or Embed returns.
    try requestRelayForwarding(BoundRequestHook);
}

test "a11y bound request hook does not process session Status signals" {
    var native: Bus = .{ .gpa = std.testing.allocator, .io = .failing, .runtime = undefined, .uid = 1, .limits = .{}, .root_path = try std.testing.allocator.dupe(u8, registry_root) };
    defer native.deinit();
    native.status_owner = try std.testing.allocator.dupe(u8, ":1.42");
    native.startup_owner_snapshot = true;
    var relay: BoundRequestHook = .{ .native = &native, .upstream = null };
    var connection: Connection = undefined;
    const enabled: dbus.Variant = .{ .signature = "b", .value = .{ .boolean = true } };
    const pair = [_]dbus.Value{ .{ .string = "IsEnabled" }, .{ .variant = &enabled } };
    try BoundRequestHook.dispatch(&relay, &connection, .{
        .kind = .signal,
        .sender = ":1.42",
        .path = bus_path,
        .interface = properties_interface,
        .member = "PropertiesChanged",
        .signature = "sa{sv}as",
        .body = &.{ .{ .string = status_interface }, .{ .array = .{ .element_signature = "{sv}", .values = &.{.{ .dict_entry = &pair }} } }, .{ .array = .{ .element_signature = "s", .values = &.{} } } },
    });
    try BoundRequestHook.dispatch(&relay, &connection, .{
        .kind = .signal,
        .sender = "org.freedesktop.DBus",
        .path = "/org/freedesktop/DBus",
        .interface = "org.freedesktop.DBus",
        .member = "NameOwnerChanged",
        .signature = "sss",
        .body = &.{ .{ .string = "org.a11y.Bus" }, .{ .string = ":1.42" }, .{ .string = ":1.43" } },
    });
    try std.testing.expect(!native.enabled);
    try std.testing.expect(!native.startup_owner_changed);
    try std.testing.expectEqualStrings(":1.42", native.status_owner.?);
}

test "service bootstrap accepts only started or already running uint32 replies" {
    for ([_]u32{ 1, 2 }) |result| {
        try validateActivationReply(.{ .kind = .method_return, .signature = "u", .body = &.{.{ .uint32 = result }} });
    }
    try std.testing.expectError(error.InvalidReply, validateActivationReply(.{
        .kind = .method_return,
        .signature = "u",
        .body = &.{.{ .uint32 = 0 }},
    }));
    try std.testing.expectError(error.InvalidReply, validateActivationReply(.{
        .kind = .method_return,
        .signature = "b",
        .body = &.{.{ .boolean = true }},
    }));
}

const properties_interface = "org.freedesktop.DBus.Properties";
const bus_path = "/org/a11y/bus";
const status_interface = "org.a11y.Status";
const registry_root = "/org/a11y/atspi/accessible/root";
const auth_line_bytes_max = 512;
const startup_frames_max = 4096;

fn authCommand(uid: u32, buffer: *[64]u8) []const u8 {
    var decimal: [10]u8 = undefined;
    const digits = std.fmt.bufPrint(&decimal, "{d}", .{uid}) catch unreachable;
    const prefix = "\x00AUTH EXTERNAL ";
    @memcpy(buffer[0..prefix.len], prefix);
    const hex = "0123456789abcdef";
    for (digits, 0..) |byte, index| {
        buffer[prefix.len + 2 * index] = hex[byte >> 4];
        buffer[prefix.len + 2 * index + 1] = hex[byte & 15];
    }
    const end = prefix.len + 2 * digits.len;
    @memcpy(buffer[end..][0..2], "\r\n");
    return buffer[0 .. end + 2];
}

fn validateAuth(line: []const u8) error{AuthenticationFailed}!void {
    if (line.len != 37) return error.AuthenticationFailed;
    if (!std.mem.startsWith(u8, line, "OK ")) return error.AuthenticationFailed;
    if (!std.mem.endsWith(u8, line, "\r\n")) return error.AuthenticationFailed;
    for (line[3..35]) |byte| {
        if (!std.ascii.isHex(byte)) return error.AuthenticationFailed;
    }
}

fn matchesReply(message: dbus.Message, serial: u32) bool {
    return (message.kind == .method_return or message.kind == .error_reply) and
        message.reply_serial == serial;
}

/// Parses the Properties.Get(IsEnabled) reply; rejects other signatures and types.
pub fn statusEnabled(message: dbus.Message) Error!bool {
    if (message.kind != .method_return or
        !std.mem.eql(u8, message.signature, "v") or message.body.len != 1)
        return error.InvalidReply;
    return booleanVariant(message.body[0]);
}

fn booleanVariant(value: dbus.Value) Error!bool {
    const variant = switch (value) {
        .variant => |variant| variant,
        else => return error.InvalidReply,
    };
    if (!std.mem.eql(u8, variant.signature, "b")) return error.InvalidReply;
    return switch (variant.value) {
        .boolean => |enabled| enabled,
        else => error.InvalidReply,
    };
}

fn isStatusSignal(message: dbus.Message) bool {
    return message.kind == .signal and
        equalOptional(message.path, bus_path) and
        equalOptional(message.interface, properties_interface) and
        equalOptional(message.member, "PropertiesChanged");
}

fn equalOptional(value: ?[]const u8, expected: []const u8) bool {
    return if (value) |text| std.mem.eql(u8, text, expected) else false;
}

fn validateStatusSignal(message: dbus.Message) Error!bool {
    if (!isStatusSignal(message)) return false;
    if (!std.mem.eql(u8, message.signature, "sa{sv}as") or message.body.len != 3)
        return error.InvalidReply;
    const interface = switch (message.body[0]) {
        .string => |text| text,
        else => return error.InvalidReply,
    };
    if (!std.mem.eql(u8, interface, status_interface)) return false;
    switch (message.body[1]) {
        .array => |entries| {
            if (!std.mem.eql(u8, entries.element_signature, "{sv}")) return error.InvalidReply;
        },
        else => return error.InvalidReply,
    }
    switch (message.body[2]) {
        .array => |entries| {
            if (!std.mem.eql(u8, entries.element_signature, "s")) return error.InvalidReply;
        },
        else => return error.InvalidReply,
    }
    return true;
}

/// Returns the changed IsEnabled value, or null for unrelated/missing changes.
/// Invalidation is reported separately by `statusInvalidated`.
pub fn statusChange(message: dbus.Message) Error!?bool {
    if (!try validateStatusSignal(message)) return null;
    for (message.body[1].array.values) |entry| {
        const pair = switch (entry) {
            .dict_entry => |pair| pair,
            else => return error.InvalidReply,
        };
        if (pair.len != 2) return error.InvalidReply;
        const key = switch (pair[0]) {
            .string => |text| text,
            else => return error.InvalidReply,
        };
        if (std.mem.eql(u8, key, "IsEnabled")) return try booleanVariant(pair[1]);
    }
    return null;
}

/// Tells the session reader to issue a fresh Get using asynchronous serial correlation.
pub fn statusInvalidated(message: dbus.Message) Error!bool {
    if (!try validateStatusSignal(message)) return false;
    for (message.body[2].array.values) |entry| {
        const key = switch (entry) {
            .string => |text| text,
            else => return error.InvalidReply,
        };
        if (std.mem.eql(u8, key, "IsEnabled")) return true;
    }
    return false;
}

/// Header and static borrowed body for Get(IsEnabled), without a serial.
pub fn statusRequest() dbus.Message {
    return .{ .kind = .method_call, .destination = "org.a11y.Bus", .path = bus_path, .interface = properties_interface, .member = "Get", .signature = "ss", .body = &.{
        .{ .string = status_interface }, .{ .string = "IsEnabled" },
    } };
}

/// Header for asynchronous rediscovery when the accessibility service owner changes.
pub fn getAddressRequest() dbus.Message {
    return .{ .kind = .method_call, .destination = "org.a11y.Bus", .path = bus_path, .interface = "org.a11y.Bus", .member = "GetAddress" };
}

fn unixAddress(candidate: address.Address) Error!zio.net.UnixAddress {
    if (candidate.kind == .path) return try zio.net.UnixAddress.init(candidate.name);
    // init reserves a pathname terminator; abstract addresses instead use that
    // byte as their namespace prefix and may occupy every remaining sun_path byte.
    var endpoint = try zio.net.UnixAddress.init("");
    if (candidate.name.len > endpoint.un.path.len - 1) return error.AddressTooLong;
    @memcpy(endpoint.un.path[1..][0..candidate.name.len], candidate.name);
    return endpoint;
}

fn embedRequest(
    unique_name: []const u8,
    root_path: []const u8,
    fields: *[2]dbus.Value,
    body: *[1]dbus.Value,
) dbus.Message {
    fields.* = .{ .{ .string = unique_name }, .{ .object_path = root_path } };
    body.* = .{.{ .structure = fields }};
    return .{ .kind = .method_call, .destination = "org.a11y.atspi.Registry", .path = registry_root, .interface = "org.a11y.atspi.Socket", .member = "Embed", .signature = "(so)", .body = body };
}

const RetainedReference = struct {
    bus_name: []u8,
    path: []u8,

    fn init(gpa: std.mem.Allocator, reference: dbus.ObjectReference) Error!RetainedReference {
        const bus_name = try gpa.dupe(u8, reference.bus_name);
        errdefer gpa.free(bus_name);
        const path = try gpa.dupe(u8, reference.path);
        return .{ .bus_name = bus_name, .path = path };
    }

    fn value(self: RetainedReference) dbus.ObjectReference {
        return .{ .bus_name = self.bus_name, .path = self.path };
    }

    fn deinit(self: *RetainedReference, gpa: std.mem.Allocator) void {
        gpa.free(self.bus_name);
        gpa.free(self.path);
        self.* = undefined;
    }
};

/// An owned remote-error name. Initialize to `.empty`; release with the allocator
/// that supplied it. Copies share storage and are not independent owners.
pub const Diagnostic = struct {
    name: ?[]u8 = null,

    pub const empty: Diagnostic = .{ .name = null };

    fn set(self: *Diagnostic, gpa: std.mem.Allocator, name: []const u8) Error!void {
        const owned = try gpa.dupe(u8, name);
        self.deinit(gpa);
        self.name = owned;
    }

    /// Releases a retained name and resets to empty; repeated calls are safe.
    pub fn deinit(self: *Diagnostic, gpa: std.mem.Allocator) void {
        if (self.name) |name| gpa.free(name);
        self.name = null;
    }
};

fn ResultError(comptime function: type) type {
    return @typeInfo(@typeInfo(function).@"fn".return_type.?).error_union.error_set;
}

/// Transport and codec errors retain their original tags. RemoteError's name
/// is owned by the connection diagnostic until the next call or destroy.
pub const Error = dbus.CodecError || address.Error ||
    ResultError(@TypeOf(zio.net.UnixAddress.init)) ||
    ResultError(@TypeOf(zio.net.UnixAddress.connect)) ||
    ResultError(@TypeOf(zio.net.Stream.read)) ||
    ResultError(@TypeOf(zio.net.Stream.write)) || error{
    AuthenticationFailed,
    AuthenticationLineTooLong,
    EndOfStream,
    InvalidReply,
    RemoteError,
    ActivationFailed,
    SerialExhausted,
    StartupFrameLimit,
    MissingSessionAddress,
    NotAttached,
    InvalidUniqueName,
    Disconnected,
    RuntimeShutdown,
    InvalidPlacement,
    ContextTooLarge,
    ResultTooLarge,
    Closed,
};

/// Startup dispatch runs on the calling runtime task. Bus, connection, and message
/// are borrowed only until dispatch returns, including a constructor-local Bus.
/// It may send signals and replies, but must not call/read/detach/deinit/destroy.
pub const RequestHook = struct {
    context: *anyopaque,
    dispatch: *const fn (*anyopaque, *Bus, *Connection, dbus.Message) Error!void,
};

/// Low-level startup dispatch borrows the connection and message on the calling
/// runtime task until dispatch returns. It may write, but must not call/read/destroy.
pub const ConnectionRequestHook = struct {
    context: *anyopaque,
    dispatch: *const fn (*anyopaque, *Connection, dbus.Message) Error!void,
};

/// Post-startup send runs synchronously through the pump's ordered writer.
/// The writer borrows header/body until returning, including write completion.
pub const WriterHook = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, dbus.Message, *const dbus.OwnedBody) Error!void,
};

/// One authenticated connection with a single reader and a single ordered writer.
/// All I/O calls run on tasks of the supplied runtime; gpa/io/runtime outlive it.
/// The caller releases each returned OwnedFrame and destroys this owner once,
/// only after the pump has joined every task using it. Copies are not new owners.
pub const Connection = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    runtime: *zio.Runtime,
    stream: zio.net.Stream,
    limits: dbus.Limits,
    next_serial: u32 = 1,
    unique_name: ?[]u8 = null,
    diagnostic: Diagnostic = .{},

    /// Tries address alternatives in order and authenticates EXTERNAL.
    /// Call hello before using it as a bus connection. The address/uid are borrowed
    /// only here. Failure frees partial state; allocation/cancellation stop immediately.
    pub fn open(
        gpa: std.mem.Allocator,
        io: std.Io,
        runtime: *zio.Runtime,
        address_text: []const u8,
        uid: u32,
        limits: dbus.Limits,
    ) Error!*Connection {
        var iterator = address.Iterator.init(address_text);
        var last_error: Error = error.InvalidAddress;
        // Each iteration consumes one finite address alternative.
        while (true) {
            var candidate = (iterator.next(gpa) catch |err| {
                if (err == error.OutOfMemory) return err;
                last_error = err;
                continue;
            }) orelse return last_error;
            defer candidate.deinit(gpa);
            const connection = openCandidate(gpa, io, runtime, candidate, uid, limits) catch |err| {
                if (err == error.OutOfMemory or err == error.Canceled) return err;
                last_error = err;
                continue;
            };
            return connection;
        }
    }

    fn openCandidate(
        gpa: std.mem.Allocator,
        io: std.Io,
        runtime: *zio.Runtime,
        candidate: address.Address,
        uid: u32,
        limits: dbus.Limits,
    ) Error!*Connection {
        const unix_address = try unixAddress(candidate);
        const stream = try unix_address.connect(.{ .timeout = .none });
        errdefer stream.socket.close();
        const connection = try gpa.create(Connection);
        errdefer gpa.destroy(connection);
        connection.* = .{ .gpa = gpa, .io = io, .runtime = runtime, .stream = stream, .limits = limits };
        errdefer {
            if (connection.unique_name) |unique_name| gpa.free(unique_name);
            connection.diagnostic.deinit(gpa);
        }
        try authenticate(connection, uid);
        return connection;
    }

    /// Says Hello and retains the actual daemon-assigned unique name. Before the
    /// pump starts, call once after open. Remote errors leave diagnostics owned here.
    pub fn hello(self: *Connection, hook: ?ConnectionRequestHook) Error!void {
        if (self.unique_name != null) return;
        var reply = try self.call(.{
            .kind = .method_call,
            .destination = "org.freedesktop.DBus",
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "Hello",
        }, hook);
        defer reply.deinit();
        const unique_name = try stringReply(reply.message);
        if (!validUniqueName(unique_name)) return error.InvalidUniqueName;
        self.unique_name = try self.gpa.dupe(u8, unique_name);
    }

    /// Closes the stream and frees retained name/diagnostic and this allocation.
    /// It is invalid to call this while another task still accesses the connection.
    pub fn destroy(self: *Connection) void {
        self.stream.socket.close();
        if (self.unique_name) |unique_name| self.gpa.free(unique_name);
        self.diagnostic.deinit(self.gpa);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Allocates a never-reused nonzero serial. Single-writer operation.
    pub fn nextSerial(self: *Connection) error{SerialExhausted}!u32 {
        const serial = self.next_serial;
        if (serial == 0) return error.SerialExhausted;
        self.next_serial = if (serial == std.math.maxInt(u32)) 0 else serial + 1;
        return serial;
    }

    /// Reads one bounded binary frame; returned storage is caller-owned.
    /// A failed partial read leaves framing unusable: stop and destroy, do not retry.
    pub fn readOwned(self: *Connection) Error!dbus.OwnedFrame {
        return readOwnedFrom(self.gpa, self, self.limits);
    }

    fn readExact(self: *Connection, bytes: []u8) Error!void {
        var offset: usize = 0;
        // Every successful read advances offset by at least one byte.
        while (offset < bytes.len) {
            const count = try self.stream.read(bytes[offset..], .none);
            if (count == 0) return error.EndOfStream;
            offset += count;
        }
    }

    /// Writes the complete borrowed bytes before returning. Only the pump writer
    /// (or startup owner before that writer exists) may call this.
    pub fn writeBytes(self: *Connection, bytes: []const u8) Error!void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const count = try self.stream.write(bytes[offset..], .none);
            if (count == 0) return error.EndOfStream;
            offset += count;
        }
    }

    /// Encodes a borrowed message and completes its write. Zero serial allocates
    /// the next serial; explicit serials must have come from `nextSerial`.
    pub fn writeMessage(self: *Connection, message: dbus.Message) Error!void {
        var outgoing = message;
        if (outgoing.serial == 0) outgoing.serial = try self.nextSerial();
        const bytes = try dbus.encode(self.gpa, outgoing, .little, self.limits);
        defer self.gpa.free(bytes);
        try self.writeBytes(bytes);
    }

    /// Startup-only synchronous call, matching return/error by reply serial.
    /// Dispatches intervening messages through hook while their frame stays live.
    /// Null hook discards unsolicited frames. Never call once a pump reader owns I/O.
    pub fn call(
        self: *Connection,
        request: dbus.Message,
        hook: ?ConnectionRequestHook,
    ) Error!dbus.OwnedFrame {
        self.diagnostic.deinit(self.gpa);
        var outgoing = request;
        if (outgoing.serial == 0) outgoing.serial = try self.nextSerial();
        try self.writeMessage(outgoing);
        for (0..startup_frames_max) |_| {
            var frame = try self.readOwned();
            if (matchesReply(frame.message, outgoing.serial)) {
                if (frame.message.kind == .error_reply) {
                    defer frame.deinit();
                    const name = frame.message.error_name orelse return error.InvalidReply;
                    try self.diagnostic.set(self.gpa, name);
                    return error.RemoteError;
                }
                return frame;
            }
            defer frame.deinit();
            if (hook) |dispatch_hook| try dispatch_hook.dispatch(
                dispatch_hook.context,
                self,
                frame.message,
            );
        }
        return error.StartupFrameLimit;
    }

    /// Borrow the last remote name; invalidated by the next call or destroy.
    pub fn remoteErrorName(self: *const Connection) ?[]const u8 {
        return self.diagnostic.name;
    }
};

fn authenticate(connection: *Connection, uid: u32) Error!void {
    return authenticateTransport(connection, uid);
}

fn authenticateTransport(connection: anytype, uid: u32) Error!void {
    var command: [64]u8 = undefined;
    try connection.writeBytes(authCommand(uid, &command));
    var line: [auth_line_bytes_max]u8 = undefined;
    for (0..line.len) |index| {
        try connection.readExact(line[index..][0..1]);
        if (line[index] == '\n') {
            try validateAuth(line[0 .. index + 1]);
            // FD negotiation is deliberately absent: the codec refuses unix_fd.
            try connection.writeBytes("BEGIN\r\n");
            return;
        }
    }
    return error.AuthenticationLineTooLong;
}

fn readOwnedFrom(
    gpa: std.mem.Allocator,
    transport: anytype,
    limits: dbus.Limits,
) Error!dbus.OwnedFrame {
    var fixed_header: [16]u8 = undefined;
    try transport.readExact(&fixed_header);
    const frame_length = try dbus.frameLength(fixed_header, limits);
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const bytes = try arena.allocator().alloc(u8, frame_length);
    @memcpy(bytes[0..16], &fixed_header);
    try transport.readExact(bytes[16..]);
    // Success transfers both raw bytes and decoding nodes with this same arena.
    return try dbus.decodeInArena(arena, bytes, limits);
}

fn stringReply(message: dbus.Message) Error![]const u8 {
    if (message.kind != .method_return or
        !std.mem.eql(u8, message.signature, "s") or message.body.len != 1)
        return error.InvalidReply;
    return switch (message.body[0]) {
        .string => |text| text,
        else => error.InvalidReply,
    };
}

fn validUniqueName(name: []const u8) bool {
    if (name.len < 4 or name.len > 255 or name[0] != ':') return false;
    var has_dot = false;
    var component_length: usize = 0;
    for (name[1..]) |byte| {
        if (byte == '.') {
            if (component_length == 0) return false;
            has_dot = true;
            component_length = 0;
        } else {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-')
                return false;
            component_length += 1;
        }
    }
    return has_dot and component_length != 0;
}

/// Startup configuration. Environment and uid come from the application, never
/// a global process lookup. Address overrides take precedence over the environment.
pub const Options = struct {
    root_path: []const u8 = registry_root,
    /// Null reads DBUS_SESSION_BUS_ADDRESS unless accessibility_address is explicit,
    /// in which case monitoring is disabled. Set explicitly to request monitoring.
    session_address: ?[]const u8 = null,
    /// Null reads AT_SPI_BUS_ADDRESS, then calls org.a11y.Bus.GetAddress.
    /// An explicit nonempty override forces accessibility enabled.
    accessibility_address: ?[]const u8 = null,
    environ: *const std.process.Environ.Map,
    uid: u32,
    limits: dbus.Limits = .{},
    /// Optional caller-owned, initially empty output. On init failure ownership
    /// transfers here without allocation; release with init's gpa. Null requests
    /// the error tag only. Success leaves this output empty.
    failure_diagnostic: ?*Diagnostic = null,
};

/// Owns persistent session monitoring and an optional accessibility connection.
/// One Bus has one owner; copying does not transfer ownership. gpa/io/runtime and
/// hook contexts outlive it. Call attach, activate objects, embed, then install
/// the pump writer. Stop/join pump I/O before detach/deinit. Closing a11y, rather
/// than Unembed or claiming a well-known name, removes the registry membership.
pub const Bus = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    runtime: *zio.Runtime,
    session: ?*Connection = null,
    accessibility: ?*Connection = null,
    enabled: bool = false,
    uid: u32,
    limits: dbus.Limits,
    root_path: []u8,
    accessibility_address: ?[]u8 = null,
    status_owner: ?[]u8 = null,
    /// The startup owner snapshot is established; earlier signals are superseded.
    startup_owner_snapshot: bool = false,
    /// The pump must refresh owner/status/address before initial attachment.
    startup_owner_changed: bool = false,
    force_enabled: bool = false,
    /// Nonempty configured/environment addresses are stable overrides, not discovery.
    address_overridden: bool = false,
    embedded: bool = false,
    desktop: ?RetainedReference = null,
    request_hook: ?RequestHook = null,
    writer_hook: ?WriterHook = null,
    diagnostic: Diagnostic = .{},

    /// Performs session Hello, installs signal matches, gets IsEnabled and the
    /// a11y address, and retains the session. No reader tasks may exist yet.
    /// An explicit a11y address forces enabled. A null session_address then skips
    /// monitoring even when the environment has a session address. Failure frees
    /// partial state and transfers an optional failure diagnostic to its caller.
    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        runtime: *zio.Runtime,
        options: Options,
        hook: ?RequestHook,
    ) Error!Bus {
        if (options.failure_diagnostic) |diagnostic| {
            std.debug.assert(diagnostic.name == null);
        }
        var self: Bus = .{ .gpa = gpa, .io = io, .runtime = runtime, .uid = options.uid, .limits = options.limits, .root_path = try gpa.dupe(u8, options.root_path), .request_hook = hook, .force_enabled = options.accessibility_address != null };
        errdefer self.deinit();
        errdefer {
            if (options.failure_diagnostic) |diagnostic| {
                diagnostic.* = self.takeDiagnostic();
            }
        }
        const override = options.accessibility_address orelse
            options.environ.get("AT_SPI_BUS_ADDRESS");
        if (override) |text| {
            if (text.len != 0) {
                self.accessibility_address = try gpa.dupe(u8, text);
                self.address_overridden = true;
            }
        }
        if (self.force_enabled and self.accessibility_address == null)
            return error.InvalidAddress;
        if (self.force_enabled and options.session_address == null) {
            self.enabled = true;
            return self;
        }
        const session_address = options.session_address orelse
            options.environ.get("DBUS_SESSION_BUS_ADDRESS");
        if (session_address) |text| {
            if (text.len == 0) return error.InvalidAddress;
            self.session = try Connection.open(gpa, io, runtime, text, options.uid, options.limits);
            try self.sessionHello();
            const matches = [_][]const u8{
                "type='signal',sender='org.a11y.Bus',path='/org/a11y/bus'," ++
                    "interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'," ++
                    "arg0='org.a11y.Status'",
                "type='signal',sender='org.freedesktop.DBus'," ++
                    "path='/org/freedesktop/DBus',interface='org.freedesktop.DBus'," ++
                    "member='NameOwnerChanged',arg0='org.a11y.Bus'",
            };
            for (matches) |rule| {
                var reply = try self.sessionCall(.{
                    .kind = .method_call,
                    .destination = "org.freedesktop.DBus",
                    .path = "/org/freedesktop/DBus",
                    .interface = "org.freedesktop.DBus",
                    .member = "AddMatch",
                    .signature = "s",
                    .body = &.{.{ .string = rule }},
                });
                defer reply.deinit();
                if (!std.mem.eql(u8, reply.message.signature, "") or reply.message.body.len != 0)
                    return error.InvalidReply;
            }
            var activation_reply = try self.sessionCall(.{
                .kind = .method_call,
                .destination = "org.freedesktop.DBus",
                .path = "/org/freedesktop/DBus",
                .interface = "org.freedesktop.DBus",
                .member = "StartServiceByName",
                .signature = "su",
                .body = &.{ .{ .string = "org.a11y.Bus" }, .{ .uint32 = 0 } },
            });
            defer activation_reply.deinit();
            try validateActivationReply(activation_reply.message);
            var owner_reply = try self.sessionCall(.{
                .kind = .method_call,
                .destination = "org.freedesktop.DBus",
                .path = "/org/freedesktop/DBus",
                .interface = "org.freedesktop.DBus",
                .member = "GetNameOwner",
                .signature = "s",
                .body = &.{.{ .string = "org.a11y.Bus" }},
            });
            defer owner_reply.deinit();
            const owner_name = try stringReply(owner_reply.message);
            if (!validUniqueName(owner_name)) return error.InvalidUniqueName;
            self.status_owner = try gpa.dupe(u8, owner_name);
            self.startup_owner_snapshot = true;
            var status_reply = try self.sessionCall(statusRequest());
            defer status_reply.deinit();
            self.enabled = try statusEnabled(status_reply.message);
            if (self.accessibility_address == null) {
                var address_reply = try self.sessionCall(.{
                    .kind = .method_call,
                    .destination = "org.a11y.Bus",
                    .path = bus_path,
                    .interface = "org.a11y.Bus",
                    .member = "GetAddress",
                });
                defer address_reply.deinit();
                const text_address = try stringReply(address_reply.message);
                if (text_address.len == 0) return error.InvalidAddress;
                self.accessibility_address = try gpa.dupe(u8, text_address);
            }
        } else if (!self.force_enabled) {
            return error.MissingSessionAddress;
        }
        if (self.force_enabled) self.enabled = true;
        return self;
    }

    fn sessionHello(self: *Bus) Error!void {
        const session = self.session orelse return error.Disconnected;
        var relay: StartupRelay = .{ .native = self, .upstream = self.request_hook };
        session.hello(.{
            .context = &relay,
            .dispatch = &StartupRelay.dispatch,
        }) catch |err| {
            try self.latchDiagnostic(session);
            return err;
        };
    }

    fn sessionCall(self: *Bus, request: dbus.Message) Error!dbus.OwnedFrame {
        const session = self.session orelse return error.Disconnected;
        var relay: StartupRelay = .{ .native = self, .upstream = self.request_hook };
        return session.call(request, .{
            .context = &relay,
            .dispatch = &StartupRelay.dispatch,
        }) catch |err| {
            try self.latchDiagnostic(session);
            return err;
        };
    }

    fn latchDiagnostic(self: *Bus, connection: *Connection) Error!void {
        if (connection.diagnostic.name != null) {
            self.diagnostic.deinit(self.gpa);
            self.diagnostic = connection.diagnostic;
            connection.diagnostic = .empty;
        }
    }

    /// Opens and authenticates the a11y connection and retains its actual Hello name.
    /// Does not register objects or Embed. It is not active until embed succeeds.
    pub fn attach(self: *Bus) Error!void {
        if (self.accessibility != null) return;
        if (!self.enabled) return error.ActivationFailed;
        const text = self.accessibility_address orelse return error.ActivationFailed;
        self.accessibility = try Connection.open(
            self.gpa,
            self.io,
            self.runtime,
            text,
            self.uid,
            self.limits,
        );
        const connection = self.accessibility.?;
        var relay: BoundRequestHook = .{ .native = self, .upstream = self.request_hook };
        connection.hello(.{
            .context = &relay,
            .dispatch = &BoundRequestHook.dispatch,
        }) catch |err| {
            defer self.detach();
            try self.latchDiagnostic(connection);
            return err;
        };
    }

    /// Embeds exactly (own unique name, root_path) and retains the returned desktop.
    /// Objects must already be active so intervening Properties.Set can dispatch.
    /// Uses only the startup reader, before installing the post-startup writer.
    pub fn embed(self: *Bus, root_path: []const u8) Error!void {
        const connection = self.accessibility orelse return error.NotAttached;
        if (self.embedded) return;
        var fields: [2]dbus.Value = undefined;
        var body: [1]dbus.Value = undefined;
        var relay: BoundRequestHook = .{ .native = self, .upstream = self.request_hook };
        var reply = connection.call(embedRequest(
            connection.unique_name.?,
            root_path,
            &fields,
            &body,
        ), .{ .context = &relay, .dispatch = &BoundRequestHook.dispatch }) catch |err| {
            try self.latchDiagnostic(connection);
            return err;
        };
        defer reply.deinit();
        const reference = try desktopReply(reply.message);
        self.desktop = try RetainedReference.init(self.gpa, reference);
        self.embedded = true;
    }

    /// Reports registry attachment, not merely an open/authenticated connection.
    pub fn isActive(self: *const Bus) bool {
        return self.accessibility != null and self.embedded;
    }

    /// Borrows the actual Hello name until detach/deinit, or null when unattached.
    pub fn uniqueName(self: *const Bus) ?[]const u8 {
        const connection = self.accessibility orelse return null;
        return connection.unique_name;
    }

    /// Borrows the desktop returned by Embed until detach/deinit.
    pub fn desktopReference(self: *const Bus) ?dbus.ObjectReference {
        return if (self.desktop) |desktop| desktop.value() else null;
    }

    /// Installs or clears the pump's synchronous ordered writer; hook context must
    /// stay live until cleared and any in-flight send has completed.
    pub fn installWriter(self: *Bus, hook: ?WriterHook) void {
        self.writer_hook = hook;
    }

    /// Borrows header/body until the pump writer completes the actual write.
    /// Before installing a writer, only the startup owner may call: it writes
    /// directly and synchronously so activation events precede Embed.
    pub fn send(
        self: *Bus,
        header: dbus.Message,
        body: *const dbus.OwnedBody,
    ) Error!void {
        const connection = self.accessibility orelse return error.NotAttached;
        if (self.writer_hook) |writer| {
            try writer.write(writer.context, header, body);
        } else {
            var message = header;
            message.signature = body.signature;
            message.body = body.values;
            try connection.writeMessage(message);
        }
    }

    /// Accepts status signals only from the daemon-confirmed unique owner, never
    /// from a directed signal that bypassed the AddMatch sender filter.
    pub fn isStatusSender(self: *const Bus, message: dbus.Message) bool {
        const owner = self.status_owner orelse return false;
        return equalOptional(message.sender, owner);
    }

    /// Applies authenticated NameOwnerChanged, retaining the replacement owner.
    /// Returns true on a recognized event. Owner loss disables non-forced mode;
    /// the pump re-queries IsEnabled asynchronously when a replacement appears.
    pub fn refreshStatusOwner(self: *Bus, message: dbus.Message) Error!bool {
        if (message.kind != .signal or
            !equalOptional(message.sender, "org.freedesktop.DBus") or
            !equalOptional(message.path, "/org/freedesktop/DBus") or
            !equalOptional(message.interface, "org.freedesktop.DBus") or
            !equalOptional(message.member, "NameOwnerChanged")) return false;
        if (!std.mem.eql(u8, message.signature, "sss") or message.body.len != 3)
            return error.InvalidReply;
        for (message.body) |value| {
            if (value != .string) return error.InvalidReply;
        }
        if (!std.mem.eql(u8, message.body[0].string, "org.a11y.Bus")) return false;
        const new_owner = message.body[2].string;
        if (new_owner.len != 0 and !validUniqueName(new_owner)) return error.InvalidUniqueName;
        const owned = if (new_owner.len == 0) null else try self.gpa.dupe(u8, new_owner);
        if (self.status_owner) |owner| self.gpa.free(owner);
        self.status_owner = owned;
        if (!self.force_enabled) self.enabled = false;
        return true;
    }

    /// Checks an asynchronously correlated reply and retains its exact remote
    /// error name independently of the reply frame. Allocation failure leaves
    /// the previous diagnostic intact and returns OutOfMemory instead.
    pub fn checkReplyError(self: *Bus, reply: dbus.Message) Error!void {
        if (reply.kind != .error_reply) return;
        const name = reply.error_name orelse return error.InvalidReply;
        try self.diagnostic.set(self.gpa, name);
        return error.RemoteError;
    }

    /// Commits an asynchronously correlated GetAddress reply. Configuration
    /// overrides are unchanged. Allocation failure leaves the old address intact.
    pub fn updateAddress(self: *Bus, reply: dbus.Message) Error!void {
        try self.checkReplyError(reply);
        if (self.address_overridden) return;
        const text = try stringReply(reply);
        if (text.len == 0) return error.InvalidAddress;
        const owned = try self.gpa.dupe(u8, text);
        if (self.accessibility_address) |old| self.gpa.free(old);
        self.accessibility_address = owned;
    }

    /// Borrows the name until the next remote error, takeDiagnostic, or deinit.
    pub fn remoteErrorName(self: *const Bus) ?[]const u8 {
        return self.diagnostic.name;
    }

    /// Transfers the retained diagnostic to the caller without allocation and
    /// empties this owner. The caller releases it with this Bus's gpa.
    pub fn takeDiagnostic(self: *Bus) Diagnostic {
        const diagnostic = self.diagnostic;
        self.diagnostic = .empty;
        return diagnostic;
    }

    /// Closes only a11y and discards its membership/name/desktop; session survives.
    /// The pump must first cancel and join all tasks using that connection.
    pub fn detach(self: *Bus) void {
        self.writer_hook = null;
        self.embedded = false;
        if (self.desktop) |*desktop| desktop.deinit(self.gpa);
        self.desktop = null;
        if (self.accessibility) |connection| connection.destroy();
        self.accessibility = null;
    }

    /// Frees every owned connection/string. All pump tasks must already be joined.
    /// Repeated deinit on this same value is safe; copied values remain invalid.
    pub fn deinit(self: *Bus) void {
        self.detach();
        if (self.session) |connection| connection.destroy();
        self.session = null;
        if (self.accessibility_address) |text| self.gpa.free(text);
        self.accessibility_address = null;
        if (self.status_owner) |owner| self.gpa.free(owner);
        self.status_owner = null;
        self.gpa.free(self.root_path);
        self.root_path = &.{};
        self.diagnostic.deinit(self.gpa);
    }
};

fn desktopReply(message: dbus.Message) Error!dbus.ObjectReference {
    if (message.kind != .method_return or
        !std.mem.eql(u8, message.signature, "(so)") or message.body.len != 1)
        return error.InvalidReply;
    const fields = switch (message.body[0]) {
        .structure => |fields| fields,
        else => return error.InvalidReply,
    };
    if (fields.len != 2) return error.InvalidReply;
    const name = switch (fields[0]) {
        .string => |text| text,
        else => return error.InvalidReply,
    };
    const path = switch (fields[1]) {
        .object_path => |text| text,
        else => return error.InvalidReply,
    };
    if (name.len == 0) return error.InvalidReply;
    return .{ .bus_name = name, .path = path };
}

// This wrapper borrows the current Bus only during a11y Hello or Embed.
// Session Status signals must not change state through the a11y connection.
const BoundRequestHook = struct {
    native: *Bus,
    upstream: ?RequestHook,

    fn dispatch(
        context: *anyopaque,
        connection: *Connection,
        message: dbus.Message,
    ) Error!void {
        const self: *BoundRequestHook = @ptrCast(@alignCast(context));
        if (self.upstream) |hook| try hook.dispatch(
            hook.context,
            self.native,
            connection,
            message,
        );
    }
};

const StartupRelay = struct {
    native: *Bus,
    upstream: ?RequestHook,

    fn process(self: *StartupRelay, message: dbus.Message) Error!void {
        if (message.kind != .signal or !self.native.startup_owner_snapshot) return;
        if (try self.native.refreshStatusOwner(message)) {
            self.native.startup_owner_changed = true;
            return;
        }
        if (!self.native.isStatusSender(message)) return;
        if (self.native.force_enabled) return;
        if (try statusChange(message)) |enabled| self.native.enabled = enabled;
        if (try statusInvalidated(message)) self.native.startup_owner_changed = true;
    }

    fn dispatch(
        context: *anyopaque,
        connection: *Connection,
        message: dbus.Message,
    ) Error!void {
        const self: *StartupRelay = @ptrCast(@alignCast(context));
        try self.process(message);
        if (message.kind == .method_call) {
            if (self.upstream) |hook| try hook.dispatch(
                hook.context,
                self.native,
                connection,
                message,
            );
        }
    }
};

fn validateActivationReply(reply: dbus.Message) Error!void {
    if (reply.kind != .method_return or
        !std.mem.eql(u8, reply.signature, "u") or reply.body.len != 1)
        return error.InvalidReply;
    const result = switch (reply.body[0]) {
        .uint32 => |value| value,
        else => return error.InvalidReply,
    };
    if (result != 1 and result != 2) return error.InvalidReply;
}
