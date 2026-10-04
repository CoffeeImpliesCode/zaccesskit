//! `Rect`: the four-`i32` box every AT-SPI geometry member carries on the wire.
//!
//! **Upstream.** `accesskit_atspi_common/src/rect.rs:9-37` declares the struct,
//! `rect.rs:20-26` the `INVALID` constant, and `rect.rs:28-37` the conversion
//! from `accesskit::Rect`. `docs/41-atspi-build-map.md` section 1.5 records
//! `(iiii)` as the wire type of `Component.GetExtents`, `Image.GetImageExtents`,
//! `Image.GetImagePosition`, `Text.GetCharacterExtents` and
//! `Text.GetRangeExtents`.
//!
//! **Why `ser` is hand-written.** Upstream derives `zvariant::Type`, which is
//! what produced `(iiii)`. A Zig port has no derive, so the struct carries the
//! signature as a `comptime` constant and a `ser` method that writes the four
//! members in order. That is the substitution `docs/41` section 2.2 names for the
//! deleted `Type` impls, and `docs/41` section 3.2 names `GO/value.zig:249` and
//! `:295` as the two goose entry points that read `SIGNATURE` back.
//!
//! **Wire layout.** A D-Bus struct is aligned to eight and each member to four,
//! so the four `i32` members are contiguous and the box occupies sixteen bytes.
//! `zigAlignOf(Rect)` is four, not eight, because the struct holds no pointer
//! and no eight-byte member. That is a Zig layout property and says nothing
//! about the wire, which `dbusAlignOf` fixes at eight.

const std = @import("std");

const goose = @import("goose");
const DBusWriter = goose.core.value.DBusWriter;

/// A rectangle in AT-SPI coordinates, as four signed 32-bit integers.
///
/// The wire type is `(iiii)`, in the field order `x`, `y`, `width`, `height`.
/// Upstream `rect.rs:12-17`.
pub const Rect = struct {
    /// The wire signature of `Rect`. Read back by `goose.core.value.Value`, so a
    /// peer that decodes a `GetExtents` reply checks it against this.
    pub const SIGNATURE: [:0]const u8 = "(iiii)";

    /// Left edge, in the coordinate space the caller asked for.
    /// Upstream `rect.rs:13`.
    x: i32,
    /// Top edge, in the same space. Upstream `rect.rs:14`.
    y: i32,
    /// Extent rightward from `x`. Upstream `rect.rs:15`.
    width: i32,
    /// Extent downward from `y`. Upstream `rect.rs:16`.
    height: i32,

    /// The box upstream returns for a node with no geometry: all four members
    /// are `-1`. Upstream `rect.rs:20-26`, `Rect::INVALID`.
    pub const invalid: Rect = .{ .x = -1, .y = -1, .width = -1, .height = -1 };

    /// Builds a box from its four members, in the wire order.
    ///
    /// No value is checked, so a caller may build the invalid box through this
    /// function as well as through `invalid`.
    ///
    /// **Errors.** This function does not fail.
    pub fn init(x: i32, y: i32, width: i32, height: i32) Rect {
        return .{ .x = x, .y = y, .width = width, .height = height };
    }

    /// True when this is the invalid box. Upstream compares the whole struct,
    /// so a box that happens to carry `-1` in every member answers `true` too.
    ///
    /// **Errors.** This function does not fail.
    pub fn isInvalid(self: Rect) bool {
        return self.x == -1 and self.y == -1 and self.width == -1 and self.height == -1;
    }

    /// Writes the four members in the order `x`, `y`, `width`, `height`.
    ///
    /// The struct is eight-aligned on the wire and each member is four-aligned,
    /// so this is `padTo(8)` followed by four contiguous little-endian writes.
    /// The order is the contract: a peer that read `width` where `height` was
    /// written would decode a box that is wrong in two members at once.
    ///
    /// **Errors.** `error.OutOfMemory` from `DBusWriter.buffer`, which is the
    /// goose writer's own set and is the only failure on this path.
    pub fn ser(self: Rect, w: *DBusWriter) !void {
        try w.padTo(8);
        try w.writeInt(i32, self.x);
        try w.writeInt(i32, self.y);
        try w.writeInt(i32, self.width);
        try w.writeInt(i32, self.height);
    }
};

/// The signature goose derives for `Rect` from the four `i32` members alone,
/// checked against the declared constant. A port that declared `(iiii)` over a
/// differently ordered struct would pass the first test and fail this one.
const derived_signature: [:0]const u8 = blk: {
    const len = goose.core.value.Value.reprLength(Rect);
    var buf: [len]u8 = undefined;
    goose.core.value.Value.getRepr(Rect, len, 0, &buf);
    break :blk buf[0..len :0];
};

test "Rect marshals as (iiii)" {
    try std.testing.expectEqualStrings("(iiii)", Rect.SIGNATURE);
}

test "goose derives the declared signature from the struct, not the reverse" {
    try std.testing.expectEqualStrings(Rect.SIGNATURE, derived_signature);
}

test "the four members reach the wire in the order x, y, width, height" {
    const gpa = std.testing.allocator;

    var encoder = try goose.message.BodyEncoder.encode(gpa, Rect.init(10, 20, 30, 40));
    defer encoder.deinit();

    try std.testing.expectEqualStrings("(iiii)", encoder.signature());
    const body = encoder.body();
    try std.testing.expectEqual(@as(usize, 16), body.len);

    // Four contiguous little-endian `i32` values, in declaration order. A port
    // that wrote `width` second would put 30 here instead of 20.
    try std.testing.expectEqual(@as(i32, 10), readI32(body, 0));
    try std.testing.expectEqual(@as(i32, 20), readI32(body, 4));
    try std.testing.expectEqual(@as(i32, 30), readI32(body, 8));
    try std.testing.expectEqual(@as(i32, 40), readI32(body, 12));
}

test "the invalid box writes four minus ones" {
    const gpa = std.testing.allocator;

    var encoder = try goose.message.BodyEncoder.encode(gpa, Rect.invalid);
    defer encoder.deinit();

    const body = encoder.body();
    try std.testing.expectEqual(@as(i32, -1), readI32(body, 0));
    try std.testing.expectEqual(@as(i32, -1), readI32(body, 4));
    try std.testing.expectEqual(@as(i32, -1), readI32(body, 8));
    try std.testing.expectEqual(@as(i32, -1), readI32(body, 12));
}

test "a peer decoding the body reads the four members back unchanged" {
    const gpa = std.testing.allocator;

    const original = Rect.init(-7, 9, -1, 2147483647);
    var encoder = try goose.message.BodyEncoder.encode(gpa, original);
    defer encoder.deinit();

    var decoder = goose.message.BodyDecoder.init(
        gpa,
        encoder.body(),
        encoder.signature(),
        .little,
    );
    const decoded = try decoder.decode(Rect);

    try std.testing.expectEqual(original.x, decoded.x);
    try std.testing.expectEqual(original.y, decoded.y);
    try std.testing.expectEqual(original.width, decoded.width);
    try std.testing.expectEqual(original.height, decoded.height);
}

test "isInvalid answers true only for the all minus one box" {
    try std.testing.expect(Rect.invalid.isInvalid());
    try std.testing.expect(!Rect.init(-1, -1, -1, 0).isInvalid());
    try std.testing.expect(!Rect.init(0, 0, 0, 0).isInvalid());
}

/// Reads the little-endian `i32` at `offset`.
///
/// `BodyEncoder` writes little endian at `value.zig:22`, and the four members
/// of a `(iiii)` are contiguous, so the byte at `offset` is the low byte of
/// the member. Reading rather than trusting that is what makes the
/// argument-order test above a test.
fn readI32(body: []const u8, offset: usize) i32 {
    return std.mem.readInt(i32, body[offset..][0..4], .little);
}
