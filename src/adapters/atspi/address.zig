//! Connectable D-Bus Unix addresses, as defined by the D-Bus specification's
//! "Server Addresses" and "Unix Domain Sockets" sections:
//! https://dbus.freedesktop.org/doc/dbus-specification.html#addresses
//!
//! This module accepts path and abstract socket names. Listen-only options
//! are invalid. It validates and discards the optional server GUID.
//! Values use D-Bus percent escaping, not URL query escaping.
//! Linux reserves one of the 108 sun_path bytes for a terminator or abstract prefix.
//! Decoded names must contain 1 through 107 nonzero bytes.

const std = @import("std");

/// The complete error set for a candidate address.
pub const Error = error{
    OutOfMemory,
    InvalidAddress,
    UnsupportedTransport,
    AddressTooLong,
};

const name_length_max = 107;

/// One decoded socket name. This value owns name, but does not own a socket.
pub const Address = struct {
    kind: Kind,
    name: []u8,

    pub const Kind = enum { path, abstract };

    /// Release name exactly once with the allocator supplied to Iterator.next.
    pub fn deinit(self: *Address, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        self.* = undefined;
    }
};

/// An iterator that borrows a D-Bus address list.
/// Keep the input alive and unchanged until iteration ends.
pub const Iterator = struct {
    remaining: ?[]const u8,

    /// Borrow the list without allocation or validation.
    /// An empty list contains one invalid candidate, not zero candidates.
    pub fn init(input: []const u8) Iterator {
        return .{ .remaining = input };
    }

    /// Decode one candidate into a name owned by gpa. Null means exhaustion.
    /// Each call consumes one candidate, including calls that return an error.
    /// The caller can continue after an invalid or unsupported candidate.
    /// OutOfMemory also consumes its candidate. Restart the iterator to retry.
    /// InvalidAddress means syntax, options, GUID, empty name, or NUL is invalid.
    /// AddressTooLong means the decoded socket name exceeds 107 bytes.
    pub fn next(self: *Iterator, gpa: std.mem.Allocator) Error!?Address {
        const remaining = self.remaining orelse return null;
        const candidate = if (std.mem.findScalar(u8, remaining, ';')) |separator| blk: {
            self.remaining = remaining[separator + 1 ..];
            break :blk remaining[0..separator];
        } else blk: {
            self.remaining = null;
            break :blk remaining;
        };
        const parsed = try parse(gpa, candidate);
        return parsed;
    }
};

fn parse(gpa: std.mem.Allocator, candidate: []const u8) Error!Address {
    const colon = std.mem.findScalar(u8, candidate, ':') orelse
        return error.InvalidAddress;
    const transport = candidate[0..colon];
    if (transport.len == 0) return error.InvalidAddress;
    for (transport) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') {
            return error.InvalidAddress;
        }
    }
    if (!std.mem.eql(u8, transport, "unix")) return error.UnsupportedTransport;

    var name_buffer: [name_length_max]u8 = undefined;
    var name: ?[]const u8 = null;
    var kind: Address.Kind = .path;
    var has_guid = false;
    var options = std.mem.splitScalar(u8, candidate[colon + 1 ..], ',');
    while (options.next()) |option| {
        const equals = std.mem.findScalar(u8, option, '=') orelse
            return error.InvalidAddress;
        const key = option[0..equals];
        const value = option[equals + 1 ..];
        if (std.mem.eql(u8, key, "path") or std.mem.eql(u8, key, "abstract")) {
            if (name != null) return error.InvalidAddress;
            kind = if (std.mem.eql(u8, key, "path")) .path else .abstract;
            name = try decodeInto(value, &name_buffer);
            if (name.?.len == 0) return error.InvalidAddress;
        } else if (std.mem.eql(u8, key, "guid")) {
            if (has_guid) return error.InvalidAddress;
            has_guid = true;
            var guid_buffer: [32]u8 = undefined;
            const guid = decodeInto(value, &guid_buffer) catch return error.InvalidAddress;
            if (guid.len != guid_buffer.len) return error.InvalidAddress;
            for (guid) |byte| {
                if (hexDigit(byte) == null) return error.InvalidAddress;
            }
        } else {
            return error.InvalidAddress;
        }
    }
    const decoded_name = name orelse return error.InvalidAddress;
    return .{ .kind = kind, .name = try gpa.dupe(u8, decoded_name) };
}

/// Decode into bounded stack storage so validation needs no allocation.
fn decodeInto(
    encoded: []const u8,
    buffer: []u8,
) error{ InvalidAddress, AddressTooLong }![]const u8 {
    var input_index: usize = 0;
    var output_count: usize = 0;
    while (input_index < encoded.len) {
        const byte = encoded[input_index];
        const decoded = if (byte == '%') blk: {
            if (encoded.len - input_index < 3) return error.InvalidAddress;
            const high = hexDigit(encoded[input_index + 1]) orelse return error.InvalidAddress;
            const low = hexDigit(encoded[input_index + 2]) orelse return error.InvalidAddress;
            input_index += 3;
            break :blk (high << 4) | low;
        } else blk: {
            if (!isUnescapedByte(byte)) return error.InvalidAddress;
            input_index += 1;
            break :blk byte;
        };
        if (decoded == 0) return error.InvalidAddress;
        if (output_count == buffer.len) return error.AddressTooLong;
        buffer[output_count] = decoded;
        output_count += 1;
    }
    return buffer[0..output_count];
}

fn hexDigit(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn isUnescapedByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '-', '_', '/', '.', '*' => true,
        else => false,
    };
}

test "percent decoding accepts both hex cases and escapes address delimiters" {
    var iterator = Iterator.init("unix:path=%2ftmp/a%2Cb%3Bc%3Dd%25%20%5C%2A");
    var address = (try iterator.next(std.testing.allocator)).?;
    defer address.deinit(std.testing.allocator);
    try std.testing.expectEqual(Address.Kind.path, address.kind);
    try std.testing.expectEqualStrings("/tmp/a,b;c=d% \\*", address.name);
    try std.testing.expect((try iterator.next(std.testing.allocator)) == null);
}

test "percent decoding preserves every nonzero byte without UTF8 conversion" {
    const hex = "0123456789ABCDEF";
    var input = "unix:abstract=%00".*;
    for (1..256) |value| {
        input[input.len - 2] = hex[value >> 4];
        input[input.len - 1] = hex[value & 15];
        var iterator = Iterator.init(&input);
        var address = (try iterator.next(std.testing.allocator)).?;
        defer address.deinit(std.testing.allocator);
        try std.testing.expectEqual(Address.Kind.abstract, address.kind);
        try std.testing.expectEqual(@as(usize, 1), address.name.len);
        try std.testing.expectEqual(@as(u8, @intCast(value)), address.name[0]);
    }
}

test "semicolon alternatives return independent owned names in order" {
    var input = "unix:path=/tmp/first;unix:abstract=second".*;
    var iterator = Iterator.init(&input);
    var first = (try iterator.next(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    var second = (try iterator.next(std.testing.allocator)).?;
    defer second.deinit(std.testing.allocator);
    @memset(&input, 'x');
    try std.testing.expectEqual(Address.Kind.path, first.kind);
    try std.testing.expectEqualStrings("/tmp/first", first.name);
    try std.testing.expectEqual(Address.Kind.abstract, second.kind);
    try std.testing.expectEqualStrings("second", second.name);
    try std.testing.expect((try iterator.next(std.testing.allocator)) == null);
    try std.testing.expect((try iterator.next(std.testing.allocator)) == null);
}

test "GUID is validated after decoding in either option order then discarded" {
    const inputs = [_][]const u8{
        "unix:path=/tmp/bus,guid=0123456789abcdef0123456789ABCDEF",
        "unix:guid=%30%31%32%33%34%35%36%37%38%39abcdef0123456789ABCDEF,abstract=bus",
    };
    for (inputs, 0..) |input, index| {
        var iterator = Iterator.init(input);
        var address = (try iterator.next(std.testing.allocator)).?;
        defer address.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(if (index == 0) "/tmp/bus" else "bus", address.name);
    }
}

test "duplicate conflicting unknown and listen-only options are invalid" {
    const inputs = [_][]const u8{
        "unix:path=/a,path=/a",
        "unix:abstract=a,abstract=a",
        "unix:path=/a,abstract=b",
        "unix:abstract=a,path=/b",
        "unix:path=/a,guid=0123456789abcdef0123456789abcdef,guid=0123456789abcdef0123456789abcdef",
        "unix:path=/a,unknown=b",
        "unix:tmpdir=/tmp",
        "unix:dir=/tmp",
        "unix:runtime=yes",
        "unix:path=/a,tmpdir=/tmp",
        "unix:%70ath=/a",
    };
    for (inputs) |input| {
        var iterator = Iterator.init(input);
        try std.testing.expectError(error.InvalidAddress, iterator.next(std.testing.allocator));
    }
}

test "malformed syntax escaping GUID and NUL return InvalidAddress" {
    const inputs = [_][]const u8{
        "",
        "unix",
        ":path=/a",
        "unix:",
        "unix:path",
        "unix:=/a",
        "unix:path=",
        "unix:abstract=",
        "unix:guid=0123456789abcdef0123456789abcdef",
        "unix:path=/a,",
        "unix:,path=/a",
        "unix:path=/a,,guid=a",
        "unix:path=/a=b",
        "unix:path=/a%",
        "unix:path=/a%0",
        "unix:path=/a%GG",
        "unix:path=/a b",
        "unix:path=/a\\b",
        "unix:path=/a\x00b",
        "unix:path=/a%00b",
        "unix:abstract=a%00b",
        "unix:abstract=\x80",
        "unix:abstract=\n",
        "unix:path=/a,guid=",
        "unix:path=/a,guid=0123456789abcdef0123456789abcde",
        "unix:path=/a,guid=0123456789abcdef0123456789abcdef0",
        "unix:path=/a,guid=0123456789abcdef0123456789abcdeg",
        "unix:path=/a,guid=0123456789abcdef0123456789abcd%00f",
    };
    for (inputs) |input| {
        var iterator = Iterator.init(input);
        try std.testing.expectError(error.InvalidAddress, iterator.next(std.testing.allocator));
    }
}

test "filesystem paths use socket path semantics not D Bus object path grammar" {
    const names = [_][]const u8{ "/", "relative", "/tmp/.bus-42", "/tmp/*" };
    for (names) |name| {
        const input = try std.mem.concat(std.testing.allocator, u8, &.{ "unix:path=", name });
        defer std.testing.allocator.free(input);
        var iterator = Iterator.init(input);
        var address = (try iterator.next(std.testing.allocator)).?;
        defer address.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(name, address.name);
    }
}

test "socket name length limits apply to decoded bytes and reserve a NUL byte" {
    const maximum_inputs = [_][]const u8{
        "unix:path=/" ++ ("a" ** 106),
        "unix:abstract=" ++ ("a" ** 107),
        "unix:abstract=" ++ ("%61" ** 107),
    };
    for (maximum_inputs) |input| {
        var iterator = Iterator.init(input);
        var address = (try iterator.next(std.testing.allocator)).?;
        defer address.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 107), address.name.len);
    }
    const oversized_inputs = [_][]const u8{
        "unix:path=/" ++ ("a" ** 107),
        "unix:abstract=" ++ ("a" ** 108),
        "unix:abstract=" ++ ("%61" ** 108),
    };
    for (oversized_inputs) |input| {
        var iterator = Iterator.init(input);
        try std.testing.expectError(error.AddressTooLong, iterator.next(std.testing.allocator));
    }
}

test "unsupported and malformed alternatives consume one candidate not the list" {
    var iterator = Iterator.init("tcp:host=localhost,port=1;unix:path=/a%GG;unix:abstract=ok");
    try std.testing.expectError(error.UnsupportedTransport, iterator.next(std.testing.allocator));
    try std.testing.expectError(error.InvalidAddress, iterator.next(std.testing.allocator));
    var address = (try iterator.next(std.testing.allocator)).?;
    defer address.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", address.name);
    try std.testing.expect((try iterator.next(std.testing.allocator)) == null);

    const unsupported = [_][]const u8{ "launchd:env=a", "autolaunch:", "nonce-tcp:host=a" };
    for (unsupported) |input| {
        var other = Iterator.init(input);
        try std.testing.expectError(error.UnsupportedTransport, other.next(std.testing.allocator));
    }
}

test "empty alternatives are invalid including leading trailing and repeated separators" {
    var iterator = Iterator.init(";unix:abstract=a;;");
    try std.testing.expectError(error.InvalidAddress, iterator.next(std.testing.allocator));
    var address = (try iterator.next(std.testing.allocator)).?;
    defer address.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidAddress, iterator.next(std.testing.allocator));
    try std.testing.expectError(error.InvalidAddress, iterator.next(std.testing.allocator));
    try std.testing.expect((try iterator.next(std.testing.allocator)) == null);
}

fn allocationSweep(gpa: std.mem.Allocator) !void {
    var iterator = Iterator.init(
        "unix:guid=0123456789abcdef0123456789abcdef,path=%2Ftmp%2Fbus;unix:abstract=a%3Bb",
    );
    var first = (try iterator.next(gpa)).?;
    defer first.deinit(gpa);
    var second = (try iterator.next(gpa)).?;
    defer second.deinit(gpa);
    try std.testing.expectEqualStrings("/tmp/bus", first.name);
    try std.testing.expectEqualStrings("a;b", second.name);
    try std.testing.expect((try iterator.next(gpa)) == null);
}

test "fail N releases every earlier candidate allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationSweep, .{});
}

test "OutOfMemory consumes only the failed candidate" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var iterator = Iterator.init("unix:path=/a;unix:abstract=b");
    try std.testing.expectError(error.OutOfMemory, iterator.next(failing.allocator()));
    var address = (try iterator.next(std.testing.allocator)).?;
    defer address.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("b", address.name);
}

test "invalid input is validated before allocating an owned name" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var iterator = Iterator.init("unix:path=/a,guid=invalid;unix:path=/a%GG");
    try std.testing.expectError(error.InvalidAddress, iterator.next(failing.allocator()));
    try std.testing.expectError(error.InvalidAddress, iterator.next(failing.allocator()));
}
