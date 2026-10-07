//! The two-component vector the coordinate transforms are built from.
//!
//! A `Vec2` carries a translation, or the difference between two `Point`
//! values. `vec2ToPoint` and `vec2ToSize` reinterpret it without changing a
//! bit, and the `Point` and `Size` modules reinterpret back the other way. The
//! type crosses the C ABI as `accesskit_vec2`, so the `comptime` block at the
//! end of this file pins the layout a C caller relies on.
//!
//! Nothing here allocates, blocks, reads a clock or reports an error: every
//! operation is arithmetic on two `f64` values. Pixel-to-logical-pixel
//! conversion and the platform types stay at the adapter edge.
//!
//! Seven upstream impls have no Zig counterpart, following
//! `docs/19-geometry-and-text.md` section 8.2, which the geometry modules use
//! as one rule:
//!
//! - `Vec2 += Vec2`, `accesskit/src/geometry.rs:773-781`, and
//!   `Vec2 -= Vec2`, `:795-803`. Zig assigns to a mutable local, so a caller
//!   writes `v = v.add(other)` and `v = v.sub(other)`.
//! - `Vec2 *= f64`, `:817-825`, and `Vec2 /= f64`, `:849-854`, likewise, as
//!   `v = v.scale(scalar)` and `v = v.divide(scalar)`.
//! - `f64 * Vec2`, `:827-834`, and both tuple conversions, `:747-759`. The
//!   reversed operand order computes what `scale` computes, and Zig has a
//!   named-field struct literal where Rust needs a tuple.

const std = @import("std");

const point = @import("point.zig");
const size = @import("size.zig");

/// A two-component vector, used as a translation or as the difference between
/// two `Point` values.
///
/// Both fields hold any `f64`, so a NaN or an infinity is a legal value and no
/// call here rejects one. A copy is independent; a `Vec2` owns nothing and
/// borrows nothing.
pub const Vec2 = extern struct {
    /// Horizontal offset, in the same pixel unit as `Point.x`.
    x: f64,

    /// Vertical offset, in the same pixel unit as `Point.y`, which grows
    /// downward.
    y: f64,

    /// Returns the component-wise sum of the two vectors.
    pub fn add(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    /// Returns the component-wise difference `self - other`.
    pub fn sub(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    /// Returns this vector with both components multiplied by `scalar`.
    pub fn scale(self: Vec2, scalar: f64) Vec2 {
        return .{ .x = self.x * scalar, .y = self.y * scalar };
    }

    /// Returns this vector multiplied by `1 / scalar`, which is a reciprocal
    /// multiply and not a divide. For some inputs the result differs by one
    /// unit in the last place from the one `self.x / scalar` gives.
    ///
    /// The scalar division on `Size` is a true divide, and the two round
    /// differently, so the two operations must stay separate. Upstream keeps
    /// them apart at `accesskit/src/geometry.rs:836-847` and `:643-653`.
    pub fn divide(self: Vec2, scalar: f64) Vec2 {
        // Upstream multiplies by the reciprocal; a divide here is a wrong
        // result, not a slower equivalent.
        return self.scale(1.0 / scalar);
    }

    /// Returns this vector with both components negated.
    pub fn negate(self: Vec2) Vec2 {
        return .{ .x = -self.x, .y = -self.y };
    }
};

/// The vector (0, 0), the offset that leaves a position unchanged. It stands
/// in for the `Default` derive at `accesskit/src/geometry.rs:713`, which the
/// port drops for an explicit constant.
pub const vec2_zero: Vec2 = .{ .x = 0, .y = 0 };

/// Returns the vector with the two given components.
///
/// Evaluable at comptime, as the upstream `const fn` at
/// `accesskit/src/geometry.rs:730` is.
pub fn vec2Init(x: f64, y: f64) Vec2 {
    return .{ .x = x, .y = y };
}

/// Returns `value` as a `Point`. Both components are copied unchanged, so the
/// reinterpretation is exact and loses no precision.
pub fn vec2ToPoint(value: Vec2) point.Point {
    return point.pointInit(value.x, value.y);
}

/// Returns `value` as a `Size`, mapping `x` to `width` and `y` to `height`.
/// Both components are copied unchanged.
pub fn vec2ToSize(value: Vec2) size.Size {
    return size.sizeInit(value.x, value.y);
}

comptime {
    // The C header declares `accesskit_vec2` as two `double`, so a change to
    // either number here is a change to the ABI, not to the layout.
    std.debug.assert(@sizeOf(Vec2) == 16);
    std.debug.assert(@alignOf(Vec2) == 8);
    std.debug.assert(@offsetOf(Vec2, "x") == 0);
    std.debug.assert(@offsetOf(Vec2, "y") == 8);
}

const testing = std.testing;

test "vec2Init keeps both components and vec2_zero is the origin" {
    const v = vec2Init(3.5, -4.25);
    try testing.expectEqual(@as(f64, 3.5), v.x);
    try testing.expectEqual(@as(f64, -4.25), v.y);
    try testing.expectEqual(@as(f64, 0.0), vec2_zero.x);
    try testing.expectEqual(@as(f64, 0.0), vec2_zero.y);
}

test "the two conversions put the first component on the first field" {
    const v = vec2Init(6.0, -2.0);

    const p = vec2ToPoint(v);
    try testing.expectEqual(@as(f64, 6.0), p.x);
    try testing.expectEqual(@as(f64, -2.0), p.y);

    const s = vec2ToSize(v);
    try testing.expectEqual(@as(f64, 6.0), s.width);
    try testing.expectEqual(@as(f64, -2.0), s.height);
}

test "add and sub are component-wise against another Vec2" {
    const a = vec2Init(10.0, -3.0);
    const b = vec2Init(4.5, 8.25);

    const sum = a.add(b);
    try testing.expectEqual(@as(f64, 14.5), sum.x);
    try testing.expectEqual(@as(f64, 5.25), sum.y);

    const diff = b.sub(a);
    try testing.expectEqual(@as(f64, -5.5), diff.x);
    try testing.expectEqual(@as(f64, 11.25), diff.y);
}

test "sub undoes add, so a translation composes and cancels" {
    const v = vec2Init(7.5, -2.25);
    const move = vec2Init(4.0, 6.5);

    const there = v.add(move);
    try testing.expectEqual(@as(f64, 11.5), there.x);
    try testing.expectEqual(@as(f64, 4.25), there.y);

    const back = there.sub(move);
    try testing.expectEqual(v.x, back.x);
    try testing.expectEqual(v.y, back.y);
}

test "scale multiplies both components by the one scalar" {
    const scaled = vec2Init(1.5, -4.0).scale(3.0);
    try testing.expectEqual(@as(f64, 4.5), scaled.x);
    try testing.expectEqual(@as(f64, -12.0), scaled.y);
}

test "scale is a multiply and not a divide" {
    const scaled = vec2Init(10.0, -8.0).scale(4.0);
    try testing.expectEqual(@as(f64, 40.0), scaled.x);
    try testing.expectEqual(@as(f64, -32.0), scaled.y);
    try testing.expect(scaled.x != 10.0 / 4.0);
    try testing.expect(scaled.y != -8.0 / 4.0);
}

test "divide multiplies by the reciprocal and is not a true divide" {
    const v = vec2Init(3.0, 7.0);
    const scaled = v.divide(10.0);

    // `1 / 10` is not representable, so the reciprocal multiply lands one
    // unit in the last place away from the divide, on both components. The
    // expected values are written out because Zig folds `3.0 * 0.1` at
    // comptime through exact rational arithmetic, which gives 0.3 and would
    // make this assertion pass against a plain divide.
    try testing.expectEqual(@as(f64, 0.30000000000000004), scaled.x);
    try testing.expectEqual(@as(f64, 0.7000000000000001), scaled.y);

    // The rule the implementation follows, stated on the vector: divide is
    // scale by the reciprocal.
    try testing.expectEqual(v.scale(1.0 / 10.0).x, scaled.x);
    try testing.expectEqual(v.scale(1.0 / 10.0).y, scaled.y);

    // The last two assertions fail the day divide becomes a real division.
    try testing.expect(scaled.x != 3.0 / 10.0);
    try testing.expect(scaled.y != 7.0 / 10.0);
}

test "the reciprocal multiply is exact for a power-of-two scalar" {
    const v = vec2Init(3.0, -7.0);
    const round_trip = v.divide(4.0).scale(4.0);
    try testing.expectEqual(v.x, round_trip.x);
    try testing.expectEqual(v.y, round_trip.y);
}

test "negate flips both signs and undoes itself" {
    const v = vec2Init(2.5, -6.0);

    const n = v.negate();
    try testing.expectEqual(@as(f64, -2.5), n.x);
    try testing.expectEqual(@as(f64, 6.0), n.y);

    const back = n.negate();
    try testing.expectEqual(v.x, back.x);
    try testing.expectEqual(v.y, back.y);
}

test "a NaN component is a legal value and propagates" {
    const scaled = vec2Init(std.math.nan(f64), 2.0).scale(2.0);
    try testing.expect(std.math.isNan(scaled.x));
    try testing.expectEqual(@as(f64, 4.0), scaled.y);
}

test "divide by zero yields an infinity and a NaN, and does not trap" {
    // 1 / 0 is +inf, and upstream multiplies by it, so a zero component
    // becomes NaN. Neither is an error here.
    const scaled = vec2Init(3.0, 0.0).divide(0.0);
    try testing.expect(std.math.isPositiveInf(scaled.x));
    try testing.expect(std.math.isNan(scaled.y));
}
