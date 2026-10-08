//! `Size`, the width and height an accessibility tree reports for a node.
//!
//! A size is an extent, never a position. It carries physical pixels, and the
//! origin and the down-pointing y axis belong to `Point` and `Rect`, which
//! live in `point.zig` and `rect.zig`. `Vec2` lives in `vec2.zig`, and
//! `sizeToVec2` is the one conversion this module makes into it.
//!
//! `Size` owns nothing and reaches no system resource, so no function here
//! takes an allocator or a `std.Io`. The `std.Io.Writer` in `format` is a byte
//! sink the caller already owns, not a capability this module acquires.
//!
//! `Size` crosses the C ABI as `accesskit_size`, so it is an `extern struct` and
//! the declaration order below is the byte layout. A plain `struct` would let
//! the compiler reorder its fields. The `comptime` block below pins the offsets
//! for every consumer of this module, and the two tests below repeat them,
//! because a runtime assertion names the field that moved and a comptime block
//! names the module.
//!
//! Eight upstream items have no Zig counterpart, and one item here is the
//! port's own. The other four geometry modules keep the same two registers, so
//! the five files read as one decision.
//!
//! - `Default` from the derive at `accesskit/src/geometry.rs:567` is the empty
//!   extent. `size_zero` is the named constant for that value, and the port has
//!   no `Default`.
//! - The four assign impls (`:602`, `:633`, `:666`, `:684`) exist because Rust
//!   makes `s *= f` an operation distinct from `s = s * f`. A Zig caller writes
//!   `s = s.scale(f)`, which is one spelling, not two.
//! - `impl Mul<Size> for f64` at `:612-619` computes what `scale` computes, so
//!   the port keeps the one operation.
//! - The two tuple conversions (`:691`, `:701`) exist because Rust has no
//!   named-field struct literal for a `(f64, f64)`. Zig has one,
//!   `.{ .width = w, .height = h }`, and it reads the same in both directions.
//!
//! One item here has no upstream counterpart.
//!
//! - The `comptime` block below pins the layout for every consumer of this
//!   module, including one that imports it in a non-test build.
const std = @import("std");
const Vec2 = @import("vec2.zig").Vec2;

/// A width and a height, both in physical pixels.
///
/// A `Size` is a value. It owns no storage, so a copy is independent, no
/// stable address is needed, and the value may be shared across threads.
///
/// Nothing here rejects a negative axis. `Rect.size()` returns a negative
/// width for a rectangle whose far corner sits before its near corner, and
/// that negative extent travels with the value.
pub const Size = extern struct {
    /// The width, in physical pixels.
    width: f64,
    /// The height, in physical pixels.
    height: f64,

    /// `self` plus `other`, one axis at a time. No axis reads the other axis
    /// of either operand.
    pub fn add(self: Size, other: Size) Size {
        return .{ .width = self.width + other.width, .height = self.height + other.height };
    }

    /// `self` minus `other`, one axis at a time.
    pub fn sub(self: Size, other: Size) Size {
        return .{ .width = self.width - other.width, .height = self.height - other.height };
    }

    /// Both axes multiplied by `s`. A negative `s` flips both signs.
    pub fn scale(self: Size, s: f64) Size {
        return .{ .width = self.width * s, .height = self.height * s };
    }

    /// Both axes divided by `s`. A zero `s` gives an infinity on each axis,
    /// and the call reports no error.
    ///
    /// The result is the correctly rounded quotient, which differs from a
    /// reciprocal multiply in the last bit for some inputs.
    pub fn divide(self: Size, s: f64) Size {
        // `Vec2.divide` multiplies by the reciprocal (geometry.rs:836-847); keep them apart.
        return .{ .width = self.width / s, .height = self.height / s };
    }

    /// Writes `{width}W×{height}H`, each number in the shortest decimal that
    /// reads back as the same `f64`. A caller reaches this through the `{f}`
    /// specifier of `std.Io.Writer.print`.
    ///
    /// `error.WriteFailed` leaves the writer holding an unspecified prefix of
    /// the text. Nothing is allocated.
    pub fn format(self: Size, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}W×{d}H", .{ self.width, self.height });
    }
};

/// The size whose two axes are both zero. Upstream names it `Size::ZERO` at
/// `accesskit/src/geometry.rs:580`.
pub const size_zero: Size = sizeInit(0, 0);

/// Builds a size from `width` and `height`, in that order. Neither value is
/// checked, so either may be negative.
///
/// Upstream declares this `const fn` at `accesskit/src/geometry.rs:584`. Every
/// Zig call that takes only comptime arguments is a comptime call as well.
pub fn sizeInit(width: f64, height: f64) Size {
    return .{ .width = width, .height = height };
}

/// Returns `value` read as a vector, with `width` becoming `x` and `height`
/// becoming `y`. Both types count physical pixels, so the conversion changes no
/// unit. `vec2ToSize` in `vec2.zig` is the reverse.
pub fn sizeToVec2(value: Size) Vec2 {
    return .{ .x = value.width, .y = value.height };
}

comptime {
    // The measured layout of `accesskit_size`, which
    // `accesskit-c/include/accesskit.h:1093-1102` declares as two `double`,
    // `width` first. A container-level `comptime` block does not have the bare
    // `assert` builtin on Zig 0.16.0, so these go through `std.debug.assert`,
    // and every number is one the two tests below already assert at run time.
    std.debug.assert(@sizeOf(Size) == 16);
    std.debug.assert(@alignOf(Size) == 8);
    std.debug.assert(@offsetOf(Size, "width") == 0);
    std.debug.assert(@offsetOf(Size, "height") == 8);
}

test "Size occupies 16 bytes with an alignment of 8" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Size));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Size));
}

test "Size stores width before height" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Size, "width"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Size, "height"));
}

test "sizeInit keeps width and height in order" {
    const size = sizeInit(3, 4);
    try std.testing.expectEqual(@as(f64, 3), size.width);
    try std.testing.expectEqual(@as(f64, 4), size.height);
}

test "size_zero has both axes at zero" {
    try std.testing.expectEqual(@as(f64, 0), size_zero.width);
    try std.testing.expectEqual(@as(f64, 0), size_zero.height);
}

test "sizeInit and size_zero are usable at comptime" {
    const total = comptime blk: {
        var sum = size_zero;
        for ([_]Size{ sizeInit(1, 2), sizeInit(3, 4) }) |size| sum = sum.add(size);
        break :blk sum;
    };
    try std.testing.expectEqual(@as(f64, 4), total.width);
    try std.testing.expectEqual(@as(f64, 6), total.height);
}

test "add and sub work on each axis" {
    const left = sizeInit(3, 4);
    const right = sizeInit(0.5, 0.25);

    const sum = left.add(right);
    try std.testing.expectEqual(@as(f64, 3.5), sum.width);
    try std.testing.expectEqual(@as(f64, 4.25), sum.height);

    const difference = left.sub(right);
    try std.testing.expectEqual(@as(f64, 2.5), difference.width);
    try std.testing.expectEqual(@as(f64, 3.75), difference.height);
}

test "scale multiplies both axes" {
    const scaled = sizeInit(3, -4).scale(2.5);
    try std.testing.expectEqual(@as(f64, 7.5), scaled.width);
    try std.testing.expectEqual(@as(f64, -10), scaled.height);
}

test "divide divides and does not multiply by the reciprocal" {
    const divided = sizeInit(0.3, 0.3).divide(0.1);
    // 0.3 / 0.1 rounds to 2.9999999999999996, and 0.3 * (1 / 0.1) is exactly
    // 3. The two differ by one unit in the last place, which is the whole
    // reason this method must not become a reciprocal multiply.
    try std.testing.expectEqual(@as(u64, 0x4007ffffffffffff), @as(u64, @bitCast(divided.width)));
    try std.testing.expectEqual(@as(u64, 0x4007ffffffffffff), @as(u64, @bitCast(divided.height)));

    const reciprocal = @as(f64, 0.3) * (1.0 / 0.1);
    try std.testing.expectEqual(@as(u64, 0x4008000000000000), @as(u64, @bitCast(reciprocal)));
}

test "divide by zero reports no error" {
    const divided = sizeInit(1, -1).divide(0);
    try std.testing.expectEqual(std.math.inf(f64), divided.width);
    try std.testing.expectEqual(-std.math.inf(f64), divided.height);
}

test "sizeToVec2 maps width to x and height to y" {
    const vector = sizeToVec2(sizeInit(3, 4));
    try std.testing.expectEqual(@as(f64, 3), vector.x);
    try std.testing.expectEqual(@as(f64, 4), vector.y);
}

test "format writes the width, a W, a times sign, the height and an H" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try sizeInit(1.5, 2.25).format(&writer);
    try std.testing.expectEqualStrings("1.5W×2.25H", writer.buffered());
}

test "format writes each axis in the shortest decimal that reads back" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try sizeInit(0.1, 1.0 / 3.0).format(&writer);
    try std.testing.expectEqualStrings("0.1W×0.3333333333333333H", writer.buffered());
}
