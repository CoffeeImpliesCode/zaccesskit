//! The module root for the harness under `test/fuzz/`.
//!
//! **Why this file sits at the repository root.** A module's package root is
//! the directory that holds its root source file, and a file may only reach a
//! path under that root. `test/fuzz/abi.zig` embeds `include/zaccesskit.h` and
//! the four harness files import `src/` through `../../src/`, so a module
//! rooted at `test/fuzz/property_table.zig` reports `import of file outside
//! module path` for every one of them. The package root has to be the
//! repository root, and the only way to get it is a root source file that is a
//! direct child of the repository root.
//! `[OBSERVED: zig 0.16.0 test test/fuzz/property_table.zig, every @import of
//! ../../src reported as outside the module path]`
//!
//! **What the reference does.** `zig test` collects the `test` blocks of every
//! file the compilation analyses, so importing the harness here is enough for
//! its tests, and the tests of `test/fuzz/random.zig` beside it, to run. The
//! count is larger than the harness alone, because the harness imports
//! `src/schema/` and `src/consumer/` and those files carry tests of their own.
//! `[OBSERVED: zig 0.16.0 test fuzz_root.zig, "All 351 tests passed.",
//! "1 fuzz tests found.", Debug and ReleaseSafe]`
//!
//! **What `build.zig` builds.** Two `addTest` calls rooted here, one Debug and
//! one ReleaseSafe, both on the `test` step and both on the `fuzz` step, so the
//! house gate runs the corpus replay. See `build.zig` for the reason the step
//! is not built from `-ffuzz`.

const std = @import("std");
const dbus = @import("src/adapters/atspi/dbus.zig");
const signature = @import("src/adapters/atspi/dbus_signature.zig");
const address = @import("src/adapters/atspi/address.zig");
const bus = @import("src/adapters/atspi/bus.zig");

test {
    _ = @import("test/fuzz/property_table.zig");
}

// Replay the committed descriptors, not a second copy of their transport bytes.
test "AT-SPI fuzz corpus verifies four hashes outcomes and fixed points" {
    try std.testing.expectEqual(@as(usize, 4), dbus.corpus.len);
    for (dbus.corpus) |entry| {
        try std.testing.expectEqual(entry.length, entry.bytes.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(entry.bytes, &digest, .{});
        try std.testing.expectEqualSlices(u8, &entry.sha256, &digest);
        if (entry.expected_error) |expected| {
            try std.testing.expectError(expected,
                dbus.decode(std.testing.allocator, entry.bytes, .{}));
        } else {
            var frame = try dbus.decode(std.testing.allocator, entry.bytes, .{});
            defer frame.deinit();
            try std.testing.expectEqual(dbus.Kind.method_return, frame.message.kind);
            try std.testing.expectEqual(@as(?u32, 1), frame.message.reply_serial);
            try std.testing.expectEqualStrings("u", frame.message.signature);
            try std.testing.expectEqual(@as(u32, 42), frame.message.body[0].uint32);
            const endian: std.builtin.Endian = switch (entry.bytes[0]) {
                'l' => .little,
                'B' => .big,
                else => return error.TestUnexpectedResult,
            };
            const encoded = try dbus.encode(std.testing.allocator, frame.message, endian, .{});
            defer std.testing.allocator.free(encoded);
            try std.testing.expectEqualSlices(u8, entry.bytes, encoded);
        }
        try fuzzWire(entry.bytes);
        // Every truncation and every single-byte inversion exercises actual decoding.
        for (0..entry.bytes.len) |index| {
            try fuzzWire(entry.bytes[0..index]);
            var changed: [transport_input_bytes_max]u8 = undefined;
            @memcpy(changed[0..entry.bytes.len], entry.bytes);
            changed[index] ^= 0xff;
            try fuzzWire(changed[0..entry.bytes.len]);
        }
    }
}

// These are grammar and socket-name outcomes, not module reachability assertions.
test "AT-SPI fuzz signature and address seeds exercise real boundaries" {
    for ([_][]const u8{ "", "ybnqiuxtdsoghv", "(is)ua{sv}", "a{sa{sv}}", "a", "()" })
        |seed| try fuzzSignature(seed);
    try signature.validate("(is)ua{sv}", 16);
    try std.testing.expectError(error.InvalidSignature, signature.validate("a", 16));
    try std.testing.expectError(error.LimitExceeded, signature.validate("a{sv}", 1));
    const seeds = [_][]const u8{
        "",
        "unix:path=%2ftmp/a%2Cb%3Bc%3Dd",
        "tcp:host=localhost;unix:path=/a%GG;unix:abstract=ok",
        "unix:abstract=" ++ ("%61" ** 107),
        "unix:abstract=" ++ ("a" ** 108),
    };
    for (seeds) |seed| try fuzzAddress(seed);
    var iterator = address.Iterator.init(seeds[1]);
    var decoded = (try iterator.next(std.testing.allocator)).?;
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/tmp/a,b;c=d", decoded.name);
    try std.testing.expect((try iterator.next(std.testing.allocator)) == null);
}

// A decoded PropertiesChanged frame must preserve its semantic result on re-encoding.
test "AT-SPI fuzz wire status decoding preserves changed and invalidated values" {
    const enabled: dbus.Variant = .{ .signature = "b", .value = .{ .boolean = true } };
    const pair = [_]dbus.Value{ .{ .string = "IsEnabled" }, .{ .variant = &enabled } };
    const entries = [_]dbus.Value{.{ .dict_entry = &pair }};
    const message: dbus.Message = .{
        .kind = .signal, .serial = 1, .path = "/org/a11y/bus",
        .interface = "org.freedesktop.DBus.Properties", .member = "PropertiesChanged",
        .signature = "sa{sv}as", .body = &.{
            .{ .string = "org.a11y.Status" },
            .{ .array = .{ .element_signature = "{sv}", .values = &entries } },
            .{ .array = .{ .element_signature = "s", .values = &.{
                .{ .string = "IsEnabled" },
            } } },
        },
    };
    inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |endian| {
        const bytes = try dbus.encode(std.testing.allocator, message, endian, .{});
        defer std.testing.allocator.free(bytes);
        var frame = try dbus.decode(std.testing.allocator, bytes, .{});
        defer frame.deinit();
        try std.testing.expectEqual(@as(?bool, true), try bus.statusChange(frame.message));
        try std.testing.expect(try bus.statusInvalidated(frame.message));
        try fuzzWire(bytes);
    }
}

test "AT-SPI bounded wire signature and address decoder fuzz" {
    try std.testing.fuzz(@as(void, {}), fuzzTransport, .{});
}

test {
    // Import its executable ownership, cancellation and queue-drain regressions.
    _ = @import("src/adapters/atspi/pump.zig");
}

const transport_input_bytes_max = 4096;
const transport_limits: dbus.Limits = .{
    .max_frame_bytes = transport_input_bytes_max,
    .max_array_bytes = transport_input_bytes_max,
    .max_string_bytes = transport_input_bytes_max,
    .max_depth = 16,
    .max_values = 256,
};

fn fuzzTransport(_: void, smith: *std.testing.Smith) !void {
    var bytes: [transport_input_bytes_max]u8 = undefined;
    const length = smith.slice(&bytes);
    const input = bytes[0..length];
    try fuzzWire(input);
    try fuzzSignature(input);
    try fuzzAddress(input);
}

fn fuzzWire(bytes: []const u8) !void {
    try std.testing.expect(bytes.len <= transport_input_bytes_max);
    // The real codec boundary owns the canonical encode/decode/encode oracle.
    try dbus.fuzzInput(std.testing.allocator, bytes);
    var frame = dbus.decode(std.testing.allocator, bytes, transport_limits) catch |err| {
        // This exhaustive switch keeps the accepted malformed-input outcomes finite.
        switch (err) {
            error.OutOfMemory => return err,
            error.Truncated, error.InvalidEndian, error.InvalidMessageType,
            error.InvalidProtocolVersion, error.InvalidSerial, error.InvalidHeader,
            error.MissingHeader, error.DuplicateHeader, error.InvalidPadding,
            error.InvalidSignature, error.SignatureMismatch, error.InvalidBoolean,
            error.InvalidString, error.InvalidObjectPath, error.InvalidLength,
            error.TrailingBytes, error.LimitExceeded, error.UnsupportedUnixFd => return,
        }
    };
    defer frame.deinit();
    const before = try observeStatus(frame.message);
    const encoded = try dbus.encode(std.testing.allocator, frame.message, .little, .{});
    defer std.testing.allocator.free(encoded);
    var canonical = try dbus.decode(std.testing.allocator, encoded, .{});
    defer canonical.deinit();
    const after = try observeStatus(canonical.message);
    try std.testing.expectEqual(before.enabled, after.enabled);
    try std.testing.expectEqual(before.change, after.change);
    try std.testing.expectEqual(before.malformed_change, after.malformed_change);
    try std.testing.expectEqual(before.invalidated, after.invalidated);
}

const StatusObservation = struct {
    enabled: ?bool,
    change: ?bool,
    malformed_change: bool = false,
    invalidated: ?bool,
};

fn observeStatus(message: dbus.Message) !StatusObservation {
    var malformed_change = false;
    const change: ?bool = bus.statusChange(message) catch |err| switch (err) {
        error.InvalidReply => blk: {
            malformed_change = true;
            break :blk null;
        },
        else => return err,
    };
    return .{
        .enabled = bus.statusEnabled(message) catch |err| switch (err) {
            error.InvalidReply => null,
            else => return err,
        },
        .change = change,
        .malformed_change = malformed_change,
        .invalidated = bus.statusInvalidated(message) catch |err| switch (err) {
            error.InvalidReply => null,
            else => return err,
        },
    };
}

fn fuzzSignature(bytes: []const u8) !void {
    signature.validate(bytes, 16) catch |err| switch (err) {
        error.InvalidSignature, error.LimitExceeded => return,
    };
    // Success bounds the input to 255 bytes; every type consumes at least one.
    var position: usize = 0;
    var type_count: usize = 0;
    for (0..255) |_| {
        if (position == bytes.len) break;
        const start = position;
        const end = try signature.typeEnd(bytes, start, 16);
        const next = (try dbus.signatureNext(bytes, &position)).?;
        try std.testing.expect(end > start);
        try std.testing.expectEqual(end, position);
        try std.testing.expectEqualSlices(u8, bytes[start..end], next);
        try signature.single(next, 16);
        try std.testing.expectEqual(next.len, try signature.elementEnd(next, 0, 16));
        try std.testing.expectEqual(try signature.alignment(bytes[start]),
            try signature.alignment(next[0]));
        type_count += 1;
    }
    try std.testing.expectEqual(bytes.len, position);
    try std.testing.expect((try dbus.signatureNext(bytes, &position)) == null);
    if (type_count == 1) {
        try signature.single(bytes, 16);
    } else {
        try std.testing.expectError(error.InvalidSignature, signature.single(bytes, 16));
    }
}

fn expectAddressProgress(before: []const u8, after: ?[]const u8) !void {
    if (after) |remaining| try std.testing.expect(remaining.len < before.len);
}

fn fuzzAddress(bytes: []const u8) !void {
    try std.testing.expect(bytes.len <= transport_input_bytes_max);
    var iterator = address.Iterator.init(bytes);
    // Even an all-semicolon input has only input length plus one candidates.
    for (0..bytes.len + 1) |_| {
        const before = iterator.remaining orelse break;
        var decoded = (iterator.next(std.testing.allocator) catch |err| {
            try expectAddressProgress(before, iterator.remaining);
            switch (err) {
                error.OutOfMemory => return err,
                error.InvalidAddress, error.UnsupportedTransport, error.AddressTooLong => continue,
            }
        }).?;
        defer decoded.deinit(std.testing.allocator);
        try expectAddressProgress(before, iterator.remaining);
        try std.testing.expect(decoded.name.len > 0);
        try std.testing.expect(decoded.name.len <= 107);
        // Re-escape every byte to preserve non-UTF8 names and list delimiters.
        var canonical: [14 + 107 * 3]u8 = undefined;
        const prefix: []const u8 = switch (decoded.kind) {
            .path => "unix:path=",
            .abstract => "unix:abstract=",
        };
        @memcpy(canonical[0..prefix.len], prefix);
        const hex = "0123456789ABCDEF";
        var length = prefix.len;
        for (decoded.name) |byte| {
            try std.testing.expect(byte != 0);
            canonical[length] = '%';
            canonical[length + 1] = hex[byte >> 4];
            canonical[length + 2] = hex[byte & 15];
            length += 3;
        }
        var replay = address.Iterator.init(canonical[0..length]);
        var fixed_point = (try replay.next(std.testing.allocator)).?;
        defer fixed_point.deinit(std.testing.allocator);
        try std.testing.expectEqual(decoded.kind, fixed_point.kind);
        try std.testing.expectEqualSlices(u8, decoded.name, fixed_point.name);
        try std.testing.expect((try replay.next(std.testing.allocator)) == null);
    }
    try std.testing.expect(iterator.remaining == null);
    try std.testing.expect((try iterator.next(std.testing.allocator)) == null);
}
