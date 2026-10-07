//! The 2D affine transform that one accessibility node carries.
//!
//! `Affine` is six `f64` coefficients, and it is an `extern struct` because
//! the C ABI carries it as `accesskit_affine`, which
//! `accesskit-c/include/accesskit.h:934-936` declares as
//! `struct { double _0[6]; }`.
//!
//! A consumer imports `@import("schema/geometry/affine.zig")`. The types this
//! module names come from `point.zig`, `rect.zig` and `vec2.zig` beside it,
//! and `zig test src/schema/geometry/affine.zig` runs the tests in this file.
//!
//! This module holds arithmetic only. It allocates nothing, so it takes no
//! allocator. It reads no clock, no `io` and no global state.
//!
//! Four upstream items have no Zig counterpart, and three items here are the
//! port's own. The other four geometry modules keep the same two registers, so
//! the five files read as one decision.
//!
//! - `use core::{fmt, ops::{…}}` at `accesskit/src/geometry.rs:12-15` imports
//!   the operator traits. Zig has no operator overloading, so there is no trait
//!   to import.
//! - `Debug` from the derive at `:18` gives `Affine` an upstream `format`. The
//!   port declares none, because nothing in the port renders an `Affine`.
//! - `impl Default for Affine` at `:149-154` answers `IDENTITY`. The port has
//!   no `Default`, and `affine_identity` is the named constant for that value.
//! - `impl MulAssign for Affine` at `:184-189` exists because Rust spells
//!   `a *= b` apart from `a = a * b`. A Zig caller writes `a = mul(a, b)`, so
//!   the one operation keeps the one spelling.
//!
//! Three items here have no upstream counterpart.
//!
//! - The field `coeffs` names the tuple field `.0` of `pub struct Affine([f64;
//!   6])` at `:22`, because a tuple struct field has no name in Zig and
//!   `@offsetOf` needs one. The field is public here where the upstream field
//!   is private, so a caller reads one coefficient without copying all six,
//!   and `coeffs` at file scope, the port of `as_coeffs` at `:87`, reads the
//!   whole array. `Point`, `Rect`, `Size` and `Vec2` carry genuinely public
//!   upstream fields, so this is the only one of the five where the port
//!   widens visibility.
//! - `ScaleAxes` takes the two factors of `scale_non_uniform` at `:66` as one
//!   argument, because two bare `f64` cannot say which axis is which. The C
//!   entry point still takes two bare doubles, and `capi/marshal.zig` unpacks
//!   them into the struct.
//! - The `comptime` block below pins the layout for every consumer of this
//!   module, including one that imports it in a non-test build.

const std = @import("std");

const Point = @import("point.zig").Point;
const Vec2 = @import("vec2.zig").Vec2;
const Rect = @import("rect.zig").Rect;

// `rect.zig` keeps the operations on a `Rect` value with the type, and only
// the constructors at file scope, so this module reaches the two it needs by
// different spellings.
const rectFromPoints = @import("rect.zig").rectFromPoints;

/// A 2D affine transform, held as the six coefficients of the augmented
/// matrix
///
/// ```text
/// | a c e |
/// | b d f |
/// | 0 0 1 |
/// ```
///
/// `coeffs` is `(a, b, c, d, e, f)` in that order. The order is transposed
/// against PostScript and Direct2D, and `mul` composes so that
/// `mulPoint(mul(a, b), p)` and `mulPoint(a, mulPoint(b, p))`
/// agree.
///
/// Every coefficient is `f64` in physical pixels. Any of the six may be
/// non-finite, because `inverse` answers NaN for a singular map and no
/// operation here rejects one. A copy holds its own six coefficients and
/// shares no storage with the original.
pub const Affine = extern struct {
    /// The six coefficients `(a, b, c, d, e, f)` of the augmented matrix.
    ///
    /// The field is public where the upstream tuple field is private. The
    /// module doc records that as the one visibility the port widens.
    coeffs: [6]f64,
};

comptime {
    // The measured layout of `struct { double _0[6]; }` at the pin. The
    // one-element array rules out tail padding, because an element stride
    // exceeds its size only when the size already satisfies the alignment.
    std.debug.assert(@sizeOf(Affine) == 48);
    std.debug.assert(@alignOf(Affine) == 8);
    std.debug.assert(@offsetOf(Affine, "coeffs") == 0);
    std.debug.assert(@sizeOf([1]Affine) == 48);
    std.debug.assert(@sizeOf(ScaleAxes) == 16);
    std.debug.assert(@alignOf(ScaleAxes) == 8);
}

/// The identity transform. An `Affine` of six zeroes is not this value, so a
/// caller that wants the identity takes the constant.
pub const affine_identity: Affine = .{ .coeffs = .{ 1.0, 0.0, 0.0, 1.0, 0.0, 0.0 } };

/// Mirror on the y axis, for turning a y-up space into the y-down space
/// AccessKit expects.
pub const affine_flip_y: Affine = .{ .coeffs = .{ 1.0, 0.0, 0.0, -1.0, 0.0, 0.0 } };

/// Mirror on the x axis. `affine_flip_y` mirrors the other axis.
pub const affine_flip_x: Affine = .{ .coeffs = .{ -1.0, 0.0, 0.0, 1.0, 0.0, 0.0 } };

/// Wraps six coefficients `(a, b, c, d, e, f)` exactly as they are given.
///
/// The caller owns the order and the meaning of the six values. Nothing here
/// checks them, so any of the six may be non-finite.
pub fn affineNew(c: [6]f64) Affine {
    return .{ .coeffs = c };
}

/// Scale by `s` on both axes, with no translation. `affine_identity` is this
/// function at `s = 1.0`.
pub fn affineScale(s: f64) Affine {
    return .{ .coeffs = .{ s, 0.0, 0.0, s, 0.0, 0.0 } };
}

/// The per-axis scale factors `affineScaleNonUniform` takes. Two bare `f64`
/// arguments cannot say which axis is which, and the two land in `coeffs` 0
/// and 3, where a transposed pair still looks like a valid map.
///
/// The struct is `extern` so the compiler keeps `x` before `y`. It is a Zig
/// argument type only: `accesskit_affine_scale_non_uniform` still takes two
/// bare doubles at `accesskit-c/include/accesskit.h:2422-2423`, and
/// `capi/marshal.zig` unpacks the two doubles into this struct.
pub const ScaleAxes = extern struct {
    x: f64,
    y: f64,
};

/// Scale by `axes.x` on the x axis and by `axes.y` on the y axis, with no
/// translation. `affineScale` is this function when the two factors agree.
pub fn affineScaleNonUniform(axes: ScaleAxes) Affine {
    return .{ .coeffs = .{ axes.x, 0.0, 0.0, axes.y, 0.0, 0.0 } };
}

/// Translate by `p`, with unit scale on both axes and no rotation.
pub fn affineTranslate(p: Vec2) Affine {
    return .{ .coeffs = .{ 1.0, 0.0, 0.0, 1.0, p.x, p.y } };
}

/// Maps the unit square onto `rect`, so output drawn into the unit square
/// fills `rect`.
///
/// The x axis carries the width of `rect`, the y axis carries its height,
/// and the translation carries the stored `rect.x0` and `rect.y0`. Push the
/// result onto a transform stack. A `rect` with a negative width or height
/// gives a negative scale on that axis, and a `rect` with an infinite corner
/// gives a non-finite coefficient.
pub fn affineMapUnitSquare(rect: Rect) Affine {
    return .{ .coeffs = .{
        rect.width(),
        0.0,
        0.0,
        rect.height(),
        rect.x0,
        rect.y0,
    } };
}

/// The six coefficients `(a, b, c, d, e, f)`, read back in declaration order.
/// The result is a copy, so a caller may keep it after the transform is gone.
pub fn coeffs(self: Affine) [6]f64 {
    return self.coeffs;
}

/// The determinant of the linear part, `a * d - c * b`.
///
/// A determinant of zero means the map is singular, and `inverse` then
/// answers NaN. The result is also non-finite when a coefficient is, or when
/// the two products overflow.
pub fn determinant(self: Affine) f64 {
    const c = self.coeffs;
    return c[0] * c[3] - c[1] * c[2];
}

/// The analytic inverse, so that `mul(self, inverse(self))` is the identity
/// whenever `determinant` is not zero.
///
/// Every coefficient is NaN when `determinant` is zero. A zero determinant
/// is not an error and this function does not report one. A non-finite
/// coefficient or an overflow in the products also gives a non-finite
/// result.
pub fn inverse(self: Affine) Affine {
    const c = self.coeffs;
    const inv_det = 1.0 / determinant(self);
    return .{ .coeffs = .{
        inv_det * c[3],
        -inv_det * c[1],
        -inv_det * c[2],
        inv_det * c[0],
        inv_det * (c[2] * c[5] - c[3] * c[4]),
        inv_det * (c[1] * c[4] - c[0] * c[5]),
    } };
}

/// The smallest rectangle that encloses `rect` after `self` transforms it.
///
/// The function transforms all four corners, then boxes the two corners that
/// share `x0` and the two that share `x1`, then unites the two boxes. The
/// result always has a non-negative width and a non-negative height, and it
/// is the transformed rectangle itself when the map is axis-aligned. The
/// result is non-finite when a corner transforms to a non-finite point.
pub fn transformRectBbox(self: Affine, rect: Rect) Rect {
    const p00 = mulPoint(self, .{ .x = rect.x0, .y = rect.y0 });
    const p01 = mulPoint(self, .{ .x = rect.x0, .y = rect.y1 });
    const p10 = mulPoint(self, .{ .x = rect.x1, .y = rect.y0 });
    const p11 = mulPoint(self, .{ .x = rect.x1, .y = rect.y1 });
    return rectFromPoints(p00, p01).unionRect(rectFromPoints(p10, p11));
}

/// `true` when all six coefficients are finite. A NaN coefficient and an
/// infinite coefficient both answer `false`.
pub fn isFinite(self: Affine) bool {
    const c = self.coeffs;
    return std.math.isFinite(c[0]) and
        std.math.isFinite(c[1]) and
        std.math.isFinite(c[2]) and
        std.math.isFinite(c[3]) and
        std.math.isFinite(c[4]) and
        std.math.isFinite(c[5]);
}

/// `true` when at least one of the six coefficients is NaN. An infinite
/// coefficient answers `false`.
pub fn isNan(self: Affine) bool {
    const c = self.coeffs;
    return std.math.isNan(c[0]) or
        std.math.isNan(c[1]) or
        std.math.isNan(c[2]) or
        std.math.isNan(c[3]) or
        std.math.isNan(c[4]) or
        std.math.isNan(c[5]);
}

/// Applies `self` to `other`, which is the port of `Affine * Point`. The name
/// carries `Point` because the two operands are different types.
///
/// The result is non-finite when a coefficient and a coordinate are large
/// enough to overflow their product or their sum.
pub fn mulPoint(self: Affine, other: Point) Point {
    return .{
        .x = self.coeffs[0] * other.x + self.coeffs[2] * other.y + self.coeffs[4],
        .y = self.coeffs[1] * other.x + self.coeffs[3] * other.y + self.coeffs[5],
    };
}

/// Composes `self` with `other`, so `other` applies first.
///
/// `mulPoint(mul(self, other), p)` equals
/// `mulPoint(self, mulPoint(other, p))`. Composing `affineScale(2.0)`
/// with `affineTranslate(p)` therefore doubles a translated point. The result
/// is non-finite when two coefficients overflow their product.
pub fn mul(self: Affine, other: Affine) Affine {
    const a = self.coeffs;
    const b = other.coeffs;
    return .{ .coeffs = .{
        a[0] * b[0] + a[2] * b[1],
        a[1] * b[0] + a[3] * b[1],
        a[0] * b[2] + a[2] * b[3],
        a[1] * b[2] + a[3] * b[3],
        a[0] * b[4] + a[2] * b[5] + a[4],
        a[1] * b[4] + a[3] * b[5] + a[5],
    } };
}

/// Multiplies every coefficient of `other` by `scalar`, the port of
/// `f64 * Affine`. The scalar is on the left of the multiplication, so it is
/// the first parameter.
///
/// A zero coefficient becomes NaN when `scalar` is infinite, so the result is
/// non-finite for that pair even though `other` is finite.
pub fn scale(scalar: f64, other: Affine) Affine {
    const c = other.coeffs;
    return .{ .coeffs = .{
        scalar * c[0],
        scalar * c[1],
        scalar * c[2],
        scalar * c[3],
        scalar * c[4],
        scalar * c[5],
    } };
}

test "affine layout matches the C declaration" {
    try std.testing.expectEqual(48, @sizeOf(Affine));
    try std.testing.expectEqual(8, @alignOf(Affine));
    try std.testing.expectEqual(0, @offsetOf(Affine, "coeffs"));
    try std.testing.expectEqual(48, @sizeOf([1]Affine));
}

test "affineNew keeps the six coefficients in declaration order" {
    const a = affineNew(.{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 });
    try std.testing.expectEqual(1.0, a.coeffs[0]);
    try std.testing.expectEqual(2.0, a.coeffs[1]);
    try std.testing.expectEqual(3.0, a.coeffs[2]);
    try std.testing.expectEqual(4.0, a.coeffs[3]);
    try std.testing.expectEqual(5.0, a.coeffs[4]);
    try std.testing.expectEqual(6.0, a.coeffs[5]);
    try std.testing.expectEqual([6]f64{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 }, coeffs(a));
}

test "the three module constants hold the upstream coefficients" {
    try std.testing.expectEqual([6]f64{ 1.0, 0.0, 0.0, 1.0, 0.0, 0.0 }, affine_identity.coeffs);
    try std.testing.expectEqual([6]f64{ 1.0, 0.0, 0.0, -1.0, 0.0, 0.0 }, affine_flip_y.coeffs);
    try std.testing.expectEqual([6]f64{ -1.0, 0.0, 0.0, 1.0, 0.0, 0.0 }, affine_flip_x.coeffs);
}

test "affineScale sets both diagonal slots" {
    const uniform = affineScale(3.0).coeffs;
    try std.testing.expectEqual([6]f64{ 3.0, 0.0, 0.0, 3.0, 0.0, 0.0 }, uniform);
}

test "affineScaleNonUniform puts each axis factor on its own axis" {
    // The two factors differ by a factor of 20, so a transposed pair cannot
    // hide inside a rounding difference.
    const split = affineScaleNonUniform(.{ .x = 2.0, .y = 40.0 });
    try std.testing.expectEqual([6]f64{ 2.0, 0.0, 0.0, 40.0, 0.0, 0.0 }, split.coeffs);
    const swapped = affineScaleNonUniform(.{ .x = 40.0, .y = 2.0 });
    try std.testing.expectEqual([6]f64{ 40.0, 0.0, 0.0, 2.0, 0.0, 0.0 }, swapped.coeffs);
}

test "affineTranslate puts the vector in the last two coefficients" {
    const t = affineTranslate(.{ .x = -3.0, .y = 7.0 });
    try std.testing.expectEqual(-3.0, t.coeffs[4]);
    try std.testing.expectEqual(7.0, t.coeffs[5]);
    try std.testing.expectEqual(1.0, t.coeffs[0]);
    try std.testing.expectEqual(1.0, t.coeffs[3]);
}

test "determinant is a times d minus c times b" {
    try std.testing.expectEqual(1.0, determinant(affine_identity));
    try std.testing.expectEqual(4.0, determinant(affineScale(2.0)));
    try std.testing.expectEqual(-1.0, determinant(affine_flip_y));
    try std.testing.expectEqual(0.0, determinant(affineNew(.{ 1.0, 2.0, 2.0, 4.0, 0.0, 0.0 })));
}

test "inverse of a uniform scale is the reciprocal scale, signed zero included" {
    // The bit patterns are the ones recorded at Zig 0.16.0 in
    // docs/19-geometry-and-text.md:1178. Equality does not see the sign of
    // zero, so the comparison is on the bits.
    const inv = inverse(affineScale(2.0));
    try std.testing.expectEqual(@as(u64, 0x3fe0000000000000), @as(u64, @bitCast(inv.coeffs[0])));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(inv.coeffs[1])));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(inv.coeffs[2])));
    try std.testing.expectEqual(@as(u64, 0x3fe0000000000000), @as(u64, @bitCast(inv.coeffs[3])));
    try std.testing.expectEqual(@as(u64, 0x0), @as(u64, @bitCast(inv.coeffs[4])));
    try std.testing.expectEqual(@as(u64, 0x0), @as(u64, @bitCast(inv.coeffs[5])));
}

test "a singular map inverts to NaN and reports nothing" {
    const inv = inverse(affineNew(.{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }));
    try std.testing.expect(isNan(inv));
    try std.testing.expect(!isFinite(inv));
    try std.testing.expect(std.math.isNan(inv.coeffs[0]));
    try std.testing.expect(std.math.isNan(inv.coeffs[5]));
}

test "a map times its inverse is the identity" {
    const a = mul(affineScale(2.0), affineTranslate(.{ .x = 5.0, .y = -7.0 }));
    try std.testing.expectEqual([6]f64{ 1.0, 0.0, 0.0, 1.0, 0.0, 0.0 }, mul(a, inverse(a)).coeffs);
}

test "composition applies the right operand first" {
    const p: Point = .{ .x = 1.0, .y = 1.0 };
    const shift = affineTranslate(.{ .x = 1.0, .y = 1.0 });
    const scaled = mulPoint(mul(affineScale(2.0), shift), p);
    try std.testing.expectEqual(4.0, scaled.x);
    try std.testing.expectEqual(4.0, scaled.y);
    const translated = mulPoint(mul(shift, affineScale(2.0)), p);
    try std.testing.expectEqual(3.0, translated.x);
    try std.testing.expectEqual(3.0, translated.y);
}

test "mul composes a general pair of maps coefficient by coefficient" {
    // Every coefficient is distinct, so no entry can be swapped for another
    // without a test noticing. An axis-aligned pair leaves the off-diagonal
    // products at zero and hides a wrong index.
    const a = affineNew(.{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 });
    const b = affineNew(.{ 7.0, 8.0, 9.0, 10.0, 11.0, 12.0 });
    const composed = mul(a, b);
    try std.testing.expectEqual([6]f64{ 31.0, 46.0, 39.0, 58.0, 52.0, 76.0 }, composed.coeffs);
    // The same six numbers as a matrix product of the augmented matrices.
    const via_point = mulPoint(a, mulPoint(b, .{ .x = 1.0, .y = 1.0 }));
    const direct = mulPoint(composed, .{ .x = 1.0, .y = 1.0 });
    try std.testing.expectEqual(direct.x, via_point.x);
    try std.testing.expectEqual(direct.y, via_point.y);
}

test "the product of two maps matches applying them in turn" {
    const round_count = 8;
    const turn = affineNew(.{ 0.0, 1.0, -1.0, 0.0, 0.0, 0.0 });
    const moved = affineTranslate(.{ .x = 2.0, .y = -5.0 });
    const a = mul(turn, mul(affineScale(3.0), moved));
    const shifted = affineTranslate(.{ .x = -1.0, .y = 4.0 });
    const b = mul(affineScaleNonUniform(.{ .x = 2.0, .y = 0.5 }), mul(shifted, turn));
    var p: Point = .{ .x = 1.0, .y = 2.0 };
    var i: usize = 0;
    while (i < round_count) : (i += 1) {
        const grouped = mulPoint(mul(a, b), p);
        const nested = mulPoint(a, mulPoint(b, p));
        try std.testing.expectEqual(grouped.x, nested.x);
        try std.testing.expectEqual(grouped.y, nested.y);
        p = .{ .x = p.x * 1.5 - 0.25, .y = p.y * 0.5 + 3.0 };
    }
}

test "mulPoint of the identity and of the two mirrors" {
    const p: Point = .{ .x = 3.0, .y = 4.0 };
    const same = mulPoint(affine_identity, p);
    try std.testing.expectEqual(3.0, same.x);
    try std.testing.expectEqual(4.0, same.y);
    const on_y = mulPoint(affine_flip_y, p);
    try std.testing.expectEqual(3.0, on_y.x);
    try std.testing.expectEqual(-4.0, on_y.y);
    const on_x = mulPoint(affine_flip_x, p);
    try std.testing.expectEqual(-3.0, on_x.x);
    try std.testing.expectEqual(4.0, on_x.y);
}

test "transformRectBbox under identity and under flipY" {
    const r: Rect = .{ .x0 = 1.0, .y0 = 2.0, .x1 = 3.0, .y1 = 4.0 };
    const same = transformRectBbox(affine_identity, r);
    try std.testing.expectEqual(1.0, same.x0);
    try std.testing.expectEqual(2.0, same.y0);
    try std.testing.expectEqual(3.0, same.x1);
    try std.testing.expectEqual(4.0, same.y1);
    const flipped = transformRectBbox(affine_flip_y, r);
    try std.testing.expectEqual(1.0, flipped.x0);
    try std.testing.expectEqual(-4.0, flipped.y0);
    try std.testing.expectEqual(3.0, flipped.x1);
    try std.testing.expectEqual(-2.0, flipped.y1);
}

test "transformRectBbox keeps the width and the height non-negative under a rotation" {
    // A quarter turn sends `(x, y)` to `(-y, x)`, so the two corners that
    // shared `x0` now share `y` instead. Only the per-axis union keeps the
    // two resulting boxes from inverting.
    const turned = affineNew(.{ 0.0, 1.0, -1.0, 0.0, 0.0, 0.0 });
    const box = transformRectBbox(turned, .{ .x0 = 1.0, .y0 = 2.0, .x1 = 3.0, .y1 = 4.0 });
    try std.testing.expectEqual(-4.0, box.x0);
    try std.testing.expectEqual(1.0, box.y0);
    try std.testing.expectEqual(-2.0, box.x1);
    try std.testing.expectEqual(3.0, box.y1);
    try std.testing.expect(box.width() >= 0.0);
    try std.testing.expect(box.height() >= 0.0);
}

test "affineMapUnitSquare sends the unit square corners onto the rectangle corners" {
    const r: Rect = .{ .x0 = 10.0, .y0 = 20.0, .x1 = 30.0, .y1 = 60.0 };
    const m = affineMapUnitSquare(r);
    const near_corner = mulPoint(m, .{ .x = 0.0, .y = 0.0 });
    try std.testing.expectEqual(r.x0, near_corner.x);
    try std.testing.expectEqual(r.y0, near_corner.y);
    const far_corner = mulPoint(m, .{ .x = 1.0, .y = 1.0 });
    try std.testing.expectEqual(r.x1, far_corner.x);
    try std.testing.expectEqual(r.y1, far_corner.y);
    const box = transformRectBbox(m, .{ .x0 = 0.0, .y0 = 0.0, .x1 = 1.0, .y1 = 1.0 });
    try std.testing.expectEqual(r.x0, box.x0);
    try std.testing.expectEqual(r.y0, box.y0);
    try std.testing.expectEqual(r.x1, box.x1);
    try std.testing.expectEqual(r.y1, box.y1);
}

test "scale multiplies all six coefficients" {
    const mirrored = scale(3.0, affine_flip_y);
    const moved = scale(-2.0, affineTranslate(.{ .x = 3.0, .y = -3.0 }));
    try std.testing.expectEqual([6]f64{ 3.0, 0.0, 0.0, -3.0, 0.0, 0.0 }, mirrored.coeffs);
    try std.testing.expectEqual([6]f64{ -2.0, 0.0, 0.0, -2.0, -6.0, 6.0 }, moved.coeffs);
}

test "scale answers NaN where an infinite scalar meets a zero coefficient" {
    const scaled = scale(std.math.inf(f64), affine_identity);
    try std.testing.expect(isNan(scaled));
    try std.testing.expect(!isFinite(scaled));
    try std.testing.expect(std.math.isNan(scaled.coeffs[1]));
}

test "isFinite and isNan read the sixth coefficient too" {
    try std.testing.expect(isFinite(affine_identity));
    try std.testing.expect(!isNan(affine_identity));
    var a = affine_identity;
    a.coeffs[5] = std.math.inf(f64);
    try std.testing.expect(!isFinite(a));
    try std.testing.expect(!isNan(a));
    a.coeffs[5] = std.math.nan(f64);
    try std.testing.expect(!isFinite(a));
    try std.testing.expect(isNan(a));
    a.coeffs[5] = 0.0;
    try std.testing.expect(isFinite(a));
    try std.testing.expect(!isNan(a));
}
