//! `Rect`: the four-`i32` box every AT-SPI geometry member carries on the wire.
//!
//! **Upstream.** `accesskit_atspi_common/src/rect.rs:9-37` declares the struct,
//! `rect.rs:20-26` the `INVALID` constant, and `rect.rs:28-37` the conversion
//! from `accesskit::Rect`. `docs/41-atspi-build-map.md` section 1.5 records
//! `(iiii)` as the wire type of `Component.GetExtents`,
//! `Image.GetImageExtents`, `Image.GetImagePosition`,
//! `Text.GetCharacterExtents` and `Text.GetRangeExtents`.
//!
//! **Why `ser` is hand-written.** Upstream derives `zvariant::Type`, and that
//! derive is what produced `(iiii)`. A Zig port has no derive, so the struct
//! carries the signature as a `comptime` constant and a `ser` method that
//! appends the four members to a message body. `docs/12` section 11 records
//! this substitution: a hand-written marshal per wire type, checked against
//! recorded bytes.
//!
//! **Why the body is a byte buffer and not a transport type.** A D-Bus body is
//! bytes on the wire. `docs/12` section 9.1 records that the smallest honest
//! fix for a body the library cannot marshal is a hand-written marshal function
//! in Zig, so `ser` appends to a caller-owned buffer and names no library. The
//! connection that carries those bytes is not this module's concern.
//!
//! **Wire layout.** The D-Bus specification, section "Byte order and
//! alignment", says a struct starts on an 8-byte boundary and that each of its
//! members is then aligned naturally. Four `i32` members are 4-aligned and
//! follow one another with no padding between them, so the box occupies sixteen
//! bytes. `zigAlignOf(Rect)` is four rather than eight, because the struct holds
//! no pointer and no eight-byte member. That is a Zig layout property and says
//! nothing about the wire, which the specification fixes at eight.

const std = @import("std");

/// A rectangle in AT-SPI coordinates, as four signed 32-bit integers.
///
/// The wire type is `(iiii)`, in the field order `x`, `y`, `width`, `height`.
/// Upstream `rect.rs:12-17`.
pub const Rect = struct {
    /// The wire signature of `Rect`. Every member that answers a peer checks
    /// its decoder against this one constant.
    pub const signature: [:0]const u8 = "(iiii)";

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

    /// Appends the four members in the order `x`, `y`, `width`, `height`.
    ///
    /// The struct is eight-aligned on the wire and each member is four-aligned,
    /// so this pads to eight and then writes four contiguous little-endian
    /// values. The order is the contract: a peer that read `width` where
    /// `height` was written would decode a box that is wrong in two members at
    /// once.
    ///
    /// The bytes are appended to `out`, which the caller owns and releases.
    ///
    /// **Errors.** `error.OutOfMemory` from `out`.
    pub fn ser(
        self: Rect,
        gpa: std.mem.Allocator,
        out: *std.ArrayList(u8),
    ) std.mem.Allocator.Error!void {
        try padTo(8, gpa, out);
        try writeI32(gpa, out, self.x);
        try writeI32(gpa, out, self.y);
        try writeI32(gpa, out, self.width);
        try writeI32(gpa, out, self.height);
    }
};

comptime {
    // `(iiii)` names four signed 32-bit members. A struct that grew a fifth
    // member, or changed one of them, would still print a signature no peer can
    // decode, so the arity and the type of each member are checked here.
    const fields = @typeInfo(Rect).@"struct";
    if (fields.field_names.len != 4) {
        @compileError("the (iiii) signature names exactly four members");
    }
    for (fields.field_types) |field_type| {
        if (!isI32(field_type)) {
            @compileError("every (iiii) member is an i32");
        }
    }
}

/// True when `T` is `i32`, which is the only member type `(iiii)` allows.
fn isI32(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => |info| info.bits == 32 and info.signedness == .signed,
        else => false,
    };
}

/// Appends zero bytes until the body length is a multiple of `alignment`.
///
/// The D-Bus specification pads to the minimum that aligns the value that
/// follows and forbids both a shorter pad and a longer one. Eight and four are
/// the only two alignments this module passes: eight for a struct and four for
/// a string.
///
/// **Errors.** `error.OutOfMemory` from `out`.
fn padTo(
    comptime alignment: usize,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!void {
    if (alignment != 4 and alignment != 8) {
        @compileError("a D-Bus struct is 8-aligned and a string is 4-aligned");
    }
    const missing = alignment - (out.items.len % alignment);
    if (missing == alignment) return;
    try out.appendNTimes(gpa, 0, missing);
}

/// Appends `value` as four little-endian bytes.
///
/// A D-Bus body is little endian on the wire, which is what the byte tests
/// below assume.
///
/// **Errors.** `error.OutOfMemory` from `out`.
fn writeI32(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: i32,
) std.mem.Allocator.Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, &bytes, value, .little);
    try out.appendSlice(gpa, &bytes);
}

/// Reads the little-endian `i32` at `offset`, which is how a peer walks an
/// `(iiii)`.
///
/// The four members of a `(iiii)` are contiguous, so the byte at `offset` is
/// the low byte of the member. Reading rather than trusting that is what makes
/// the argument-order test above a test.
fn readI32(body: []const u8, offset: usize) i32 {
    return std.mem.readInt(i32, body[offset..][0..4], .little);
}

/// Writes one box into a body this helper owns.
///
/// **Errors.** `error.OutOfMemory` from the body.
fn writeInvalidBox(gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try Rect.invalid.ser(gpa, &body);
}

test "Rect marshals as (iiii)" {
    try std.testing.expectEqualStrings("(iiii)", Rect.signature);
}

test "the four members reach the wire in the order x, y, width, height" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    try Rect.init(10, 20, 30, 40).ser(gpa, &body);

    // Four contiguous little-endian `i32` values, in declaration order. A port
    // that wrote `width` second would put 30 here instead of 20.
    try std.testing.expectEqual(@as(usize, 16), body.items.len);
    try std.testing.expectEqual(@as(i32, 10), readI32(body.items, 0));
    try std.testing.expectEqual(@as(i32, 20), readI32(body.items, 4));
    try std.testing.expectEqual(@as(i32, 30), readI32(body.items, 8));
    try std.testing.expectEqual(@as(i32, 40), readI32(body.items, 12));
}

test "a box that follows an odd member starts on the next eight-byte boundary" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    // A member before the box leaves the body on an offset that is not a
    // multiple of eight, and the struct alignment is what puts the box back on
    // one. A port that wrote the four members without the padding would decode
    // a box shifted by one byte, wrong in all four members.
    try body.appendSlice(gpa, "ab");
    try Rect.init(1, 2, 3, 4).ser(gpa, &body);

    try std.testing.expectEqual(@as(usize, 24), body.items.len);
    try std.testing.expectEqual(@as(i32, 1), readI32(body.items, 8));
    try std.testing.expectEqual(@as(i32, 2), readI32(body.items, 12));
    try std.testing.expectEqual(@as(i32, 3), readI32(body.items, 16));
    try std.testing.expectEqual(@as(i32, 4), readI32(body.items, 20));
}

test "an already aligned body takes no padding at all" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    try body.appendNTimes(gpa, 0, 8);
    try Rect.init(1, 2, 3, 4).ser(gpa, &body);

    // The body was already eight-aligned, so the box starts where the previous
    // member ended and the pad is absent. A `padTo` that always padded would
    // add eight bytes here and a peer would read the box one alignment late.
    try std.testing.expectEqual(@as(usize, 24), body.items.len);
    try std.testing.expectEqual(@as(i32, 1), readI32(body.items, 8));
    try std.testing.expectEqual(@as(i32, 4), readI32(body.items, 20));
}

test "the invalid box writes four minus ones" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    try Rect.invalid.ser(gpa, &body);

    try std.testing.expectEqual(@as(i32, -1), readI32(body.items, 0));
    try std.testing.expectEqual(@as(i32, -1), readI32(body.items, 4));
    try std.testing.expectEqual(@as(i32, -1), readI32(body.items, 8));
    try std.testing.expectEqual(@as(i32, -1), readI32(body.items, 12));
}

test "a peer reading the body takes the four members back unchanged" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    const original = Rect.init(-7, 9, -1, 2147483647);
    try original.ser(gpa, &body);

    try std.testing.expectEqual(original.x, readI32(body.items, 0));
    try std.testing.expectEqual(original.y, readI32(body.items, 4));
    try std.testing.expectEqual(original.width, readI32(body.items, 8));
    try std.testing.expectEqual(original.height, readI32(body.items, 12));
}

test "isInvalid answers true only for the all minus one box" {
    try std.testing.expect(Rect.invalid.isInvalid());
    try std.testing.expect(!Rect.init(-1, -1, -1, 0).isInvalid());
    try std.testing.expect(!Rect.init(0, 0, 0, 0).isInvalid());
}

test "every allocation failure of ser is reported and never swallowed" {
    // `ser` writes into a body the caller owns, so a failure leaves whatever was
    // already written in place and the caller releases it. What must not happen
    // is a swallowed failure, so the sweep fails one allocation at a time up to
    // the first that succeeds.
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        writeInvalidBox,
        .{},
    );
}
