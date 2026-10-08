//! Portable Windows text utilities from AccessKit at
//! `466e24e252103f4d82bd6fbab98141b551e46e0c`, `adapters/windows/src/util.rs`.
//! Reach these functions through the Windows namespace's `util` module.
//! Returned descriptions belong to the caller. ARIA buffers belong to one builder until transfer.
//!
//! This module performs no platform calls or I/O.

const std = @import("std");
const builtin = @import("builtin");
const TreeState = @import("../../consumer/tree_state.zig").TreeState;
const testing = std.testing;

/// An owned description could not be allocated or decoded as UTF-8.
pub const DescriptionError = error{ OutOfMemory, InvalidUtf8 };

/// Returns native UTF-16 code units without a terminator.
/// Upstream `toolkit_description`, `util.rs:413-424`, writes the name then an optional space/version.
/// A present empty version still adds the space. `TreeState` decides the fallback name.
/// The result copies the state strings. The caller releases it once with `gpa.free`.
/// Errors leave the state unchanged and release all temporary storage.
pub fn toolkitDescription(gpa: std.mem.Allocator, state: *const TreeState) DescriptionError![]u16 {
    const name = state.toolkitName();
    const version = state.toolkitVersion();
    var byte_count = name.len;
    if (version) |value| {
        byte_count = std.math.add(usize, byte_count, 1) catch return error.OutOfMemory;
        byte_count = std.math.add(usize, byte_count, value.len) catch return error.OutOfMemory;
    }
    _ = std.math.mul(usize, byte_count, @sizeOf(u16)) catch return error.OutOfMemory;

    var result: std.ArrayList(u16) = .empty;
    errdefer result.deinit(gpa);
    // A UTF-8 byte count is an upper bound on the number of UTF-16 code units.
    try result.ensureTotalCapacityPrecise(gpa, byte_count);
    const name_units = try std.unicode.utf8ToUtf16Le(result.allocatedSlice(), name);
    result.items.len = name_units;
    if (version) |value| {
        result.appendAssumeCapacity(std.mem.nativeToLittle(u16, ' '));
        const version_units = try std.unicode.utf8ToUtf16Le(
            result.allocatedSlice()[result.items.len..],
            value,
        );
        result.items.len += version_units;
    }
    if (comptime builtin.cpu.arch.endian() == .big) {
        const item_count = result.items.len;
        for (result.items[0..item_count]) |*unit| {
            unit.* = std.mem.littleToNative(u16, unit.*);
        }
    }
    return result.toOwnedSlice(gpa);
}

/// A complete property could not be allocated.
pub const PropertyError = error{OutOfMemory};

/// Owns bytes for upstream `AriaProperties`, `util.rs:433-436`.
/// `bytes` holds complete `name=value` pairs. `need_separator` records at least one completed pair.
/// Do not modify these fields or copy the builder as a second owner.
/// Use the same allocator for all writes, transfer, and `deinit`. No allocator is retained.
/// Input slices must not overlap `bytes`. Calls copy them and retain no input borrows.
/// Concurrent writes require caller synchronization.
pub const AriaProperties = struct {
    bytes: std.ArrayList(u8),
    need_separator: bool,

    /// Borrowed bytes for one call, copied verbatim without escaping.
    pub const Property = struct {
        name: []const u8,
        value: []const u8,
    };

    /// Starts empty without allocation. Upstream `new`, `util.rs:439-444`.
    pub fn init() AriaProperties {
        return .{ .bytes = .empty, .need_separator = false };
    }

    /// Releases the buffer once and resets this owner to the usable empty state.
    /// Copies made before release are invalid and must not be released separately.
    pub fn deinit(self: *AriaProperties, gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
        self.* = init();
    }

    /// Adds an exact `name=value` pair, with `;` only after a completed pair.
    /// Upstream `write_property`, `util.rs:446-455`. Empty names and values are accepted.
    /// Allocation or size overflow preserves all completed bytes and the separator state.
    /// Successful writes can invalidate slices into `bytes`.
    pub fn writeProperty(
        gpa: std.mem.Allocator,
        self: *AriaProperties,
        options: Property,
    ) PropertyError!void {
        std.debug.assert(self.need_separator == (self.bytes.items.len != 0));
        const punctuation: usize = if (self.need_separator) 2 else 1;
        const name_bytes = std.math.add(usize, punctuation, options.name.len) catch
            return error.OutOfMemory;
        const property_bytes = std.math.add(usize, name_bytes, options.value.len) catch
            return error.OutOfMemory;
        // Reserve the entire property before exposing even its separator.
        try self.bytes.ensureUnusedCapacity(gpa, property_bytes);
        if (self.need_separator) self.bytes.appendAssumeCapacity(';');
        self.bytes.appendSliceAssumeCapacity(options.name);
        self.bytes.appendAssumeCapacity('=');
        self.bytes.appendSliceAssumeCapacity(options.value);
        self.need_separator = true;
        std.debug.assert(self.need_separator == (self.bytes.items.len != 0));
    }

    /// Adds lowercase `true` or `false`. Upstream `write_bool_property`, `util.rs:457-459`.
    /// Has the same ownership and error guarantees as `writeProperty`.
    pub fn writeBoolProperty(
        gpa: std.mem.Allocator,
        self: *AriaProperties,
        name: []const u8,
        value: bool,
    ) PropertyError!void {
        try writeProperty(gpa, self, .{ .name = name, .value = if (value) "true" else "false" });
    }

    /// Adds unsigned decimal digits. Upstream `write_usize_property`, `util.rs:461-463`.
    /// Has the same ownership and error guarantees as `writeProperty`.
    pub fn writeUsizeProperty(
        gpa: std.mem.Allocator,
        self: *AriaProperties,
        name: []const u8,
        value: usize,
    ) PropertyError!void {
        var buffer: [@bitSizeOf(usize)]u8 = undefined;
        const decimal = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch
            unreachable; // A usize's binary bit count bounds its decimal digits, including zero.
        try writeProperty(gpa, self, .{ .name = name, .value = decimal });
    }

    /// Reports any completed property. Upstream `has_properties`, `util.rs:465-467`.
    pub fn hasProperties(self: *const AriaProperties) bool {
        return self.need_separator;
    }

    /// Transfers the bytes to the caller, which releases them once with `gpa.free`.
    /// Success resets this builder to empty. `error.OutOfMemory` preserves bytes and separator state.
    pub fn toOwnedSlice(gpa: std.mem.Allocator, self: *AriaProperties) error{OutOfMemory}![]u8 {
        const owned = try self.bytes.toOwnedSlice(gpa);
        self.need_separator = false;
        return owned;
    }
};

test "toolkit description preserves Unicode code units and version presence" {
    // Expected code units come from the source strings, not from another decoder.
    const Case = struct {
        name: ?[]const u8,
        version: ?[]const u8,
        expected: []const u16,
    };
    const cases = [_]Case{
        .{ .name = null, .version = "ignored", .expected = &.{ 65, 99, 99, 101, 115, 115, 75, 105, 116 } },
        .{ .name = "", .version = null, .expected = &.{} },
        .{ .name = "Qt", .version = null, .expected = &.{ 81, 116 } },
        .{ .name = "Qt", .version = "", .expected = &.{ 81, 116, 32 } },
        .{ .name = "", .version = "6", .expected = &.{ 32, 54 } },
        .{ .name = "é😀", .version = "β.1", .expected = &.{ 0xe9, 0xd83d, 0xde00, 32, 0x3b2, 46, 49 } },
        .{ .name = "A\x00B", .version = "1", .expected = &.{ 65, 0, 66, 32, 49 } },
    };
    const case_count = cases.len;
    for (cases[0..case_count]) |case| {
        var state: TreeState = .{};
        state.info.toolkit_name = case.name;
        state.info.toolkit_version = case.version;
        const owned = try toolkitDescription(testing.allocator, &state);
        defer testing.allocator.free(owned);
        try testing.expectEqualSlices(u16, case.expected, owned);
    }
}

test "ARIA empty and exact multiple properties have no invented escaping" {
    var properties = AriaProperties.init();
    defer properties.deinit(testing.allocator);
    try testing.expect(!properties.hasProperties());
    try testing.expectEqualStrings("", properties.bytes.items);
    try AriaProperties.writeProperty(testing.allocator, &properties, .{ .name = "", .value = "" });
    try testing.expect(properties.hasProperties());
    try testing.expectEqualStrings("=", properties.bytes.items);
    try AriaProperties.writeProperty(testing.allocator, &properties, .{ .name = "a;b", .value = "c=d\\é" });
    try AriaProperties.writeProperty(testing.allocator, &properties, .{ .name = "x", .value = "" });
    try testing.expectEqualStrings("=;a;b=c=d\\é;x=", properties.bytes.items);
    const owned = try AriaProperties.toOwnedSlice(testing.allocator, &properties);
    defer testing.allocator.free(owned);
    try testing.expectEqualStrings("=;a;b=c=d\\é;x=", owned);
    try testing.expect(!properties.hasProperties());
    try AriaProperties.writeProperty(testing.allocator, &properties, .{ .name = "new", .value = "value" });
    try testing.expectEqualStrings("new=value", properties.bytes.items);
}

test "ARIA booleans and usize use lowercase and exact decimal digits" {
    var properties = AriaProperties.init();
    defer properties.deinit(testing.allocator);
    try AriaProperties.writeBoolProperty(testing.allocator, &properties, "enabled", true);
    try AriaProperties.writeBoolProperty(testing.allocator, &properties, "hidden", false);
    try AriaProperties.writeUsizeProperty(testing.allocator, &properties, "zero", 0);
    try AriaProperties.writeUsizeProperty(testing.allocator, &properties, "max", std.math.maxInt(usize));
    const maximum = switch (@bitSizeOf(usize)) {
        32 => "4294967295",
        64 => "18446744073709551615",
        else => @compileError("Add the exact usize decimal fixture for this target."),
    };
    try testing.expectEqualStrings("enabled=true;hidden=false;zero=0;max=" ++ maximum, properties.bytes.items);
}

fn toolkitAllocationFailures(gpa: std.mem.Allocator) !void {
    var state: TreeState = .{};
    state.info.toolkit_name = "é😀";
    state.info.toolkit_version = "β.1";
    const owned = try toolkitDescription(gpa, &state);
    defer gpa.free(owned);
    try testing.expectEqualSlices(u16, &.{ 0xe9, 0xd83d, 0xde00, 32, 0x3b2, 46, 49 }, owned);
}

test "toolkit description fail-N releases all intermediate buffers" {
    try testing.checkAllAllocationFailures(testing.allocator, toolkitAllocationFailures, .{});
}

fn ariaAllocationFailures(gpa: std.mem.Allocator) !void {
    var properties = AriaProperties.init();
    defer properties.deinit(gpa);
    AriaProperties.writeProperty(gpa, &properties, .{ .name = "first", .value = "done" }) catch |failure| {
        try testing.expectEqualStrings("", properties.bytes.items);
        try testing.expect(!properties.hasProperties());
        return failure;
    };
    const large_value = "z" ** 256;
    AriaProperties.writeProperty(gpa, &properties, .{ .name = "second", .value = large_value }) catch |failure| {
        try testing.expectEqualStrings("first=done", properties.bytes.items);
        try testing.expect(properties.hasProperties());
        // The failed property added neither a separator nor a partial name.
        return failure;
    };
    const owned = AriaProperties.toOwnedSlice(gpa, &properties) catch |failure| {
        try testing.expectEqualStrings("first=done;second=" ++ large_value, properties.bytes.items);
        try testing.expect(properties.hasProperties());
        return failure;
    };
    defer gpa.free(owned);
    try testing.expectEqualStrings("first=done;second=" ++ large_value, owned);
    try testing.expect(!properties.hasProperties());
}

test "ARIA fail-N preserves completed properties separators and transfer ownership" {
    try testing.checkAllAllocationFailures(testing.allocator, ariaAllocationFailures, .{});
}

test "ARIA allocation failure does not leave a separator before a later retry" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    const gpa = failing.allocator();
    var properties = AriaProperties.init();
    defer properties.deinit(gpa);
    try testing.expectError(
        error.OutOfMemory,
        AriaProperties.writeProperty(gpa, &properties, .{ .name = "", .value = "" }),
    );
    try testing.expect(!properties.hasProperties());
    failing.fail_index = std.math.maxInt(usize);
    try AriaProperties.writeProperty(gpa, &properties, .{ .name = "first", .value = "done" });
    failing.fail_index = failing.alloc_index;
    try testing.expectError(
        error.OutOfMemory,
        AriaProperties.writeProperty(gpa, &properties, .{ .name = "second", .value = "z" ** 256 }),
    );
    try testing.expectEqualStrings("first=done", properties.bytes.items);
    try testing.expect(properties.hasProperties());
    failing.fail_index = std.math.maxInt(usize);
    try AriaProperties.writeProperty(gpa, &properties, .{ .name = "retry", .value = "ok" });
    try testing.expectEqualStrings("first=done;retry=ok", properties.bytes.items);
}

test "ARIA failed ownership transfer keeps completed bytes until a successful transfer" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{
        .resize_fail_index = 0,
    });
    const gpa = failing.allocator();
    var properties = AriaProperties.init();
    defer properties.deinit(gpa);
    try AriaProperties.writeProperty(gpa, &properties, .{ .name = "a", .value = "b" });
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, AriaProperties.toOwnedSlice(gpa, &properties));
    try testing.expectEqualStrings("a=b", properties.bytes.items);
    try testing.expect(properties.hasProperties());
    failing.fail_index = std.math.maxInt(usize);
    const owned = try AriaProperties.toOwnedSlice(gpa, &properties);
    defer gpa.free(owned);
    try testing.expectEqualStrings("a=b", owned);
    try testing.expectEqualStrings("", properties.bytes.items);
    try testing.expect(!properties.hasProperties());
}

fn ariaBoolAllocationFailures(gpa: std.mem.Allocator) !void {
    var properties = AriaProperties.init();
    defer properties.deinit(gpa);
    AriaProperties.writeBoolProperty(gpa, &properties, "on", true) catch |failure| {
        try testing.expect(!properties.hasProperties());
        try testing.expectEqualStrings("", properties.bytes.items);
        return failure;
    };
    try testing.expectEqualStrings("on=true", properties.bytes.items);
}

fn ariaUsizeAllocationFailures(gpa: std.mem.Allocator) !void {
    var properties = AriaProperties.init();
    defer properties.deinit(gpa);
    AriaProperties.writeUsizeProperty(gpa, &properties, "count", std.math.maxInt(usize)) catch |failure| {
        try testing.expect(!properties.hasProperties());
        try testing.expectEqualStrings("", properties.bytes.items);
        return failure;
    };
    try testing.expect(properties.hasProperties());
}

test "ARIA typed writers fail-N leave an empty builder usable and leak nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, ariaBoolAllocationFailures, .{});
    try testing.checkAllAllocationFailures(testing.allocator, ariaUsizeAllocationFailures, .{});
}

test "toolkit description rejects invalid UTF-8 in name and version" {
    var state: TreeState = .{};
    state.info.toolkit_name = "\xff";
    try testing.expectError(error.InvalidUtf8, toolkitDescription(testing.allocator, &state));
    state.info.toolkit_name = "a";
    state.info.toolkit_version = "\xf0\x9f";
    try testing.expectError(error.InvalidUtf8, toolkitDescription(testing.allocator, &state));
}
