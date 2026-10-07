//! `Rect`, the axis-aligned box of the AccessKit geometry module.
//!
//! Import route: `@import("schema/geometry/rect.zig")`. The module publishes
//! `Rect`, `rect_zero`, `rectInit`, `rectFromPoints`, `rectFromOriginSize`,
//! `rectSize`, `NarrowError` and `toI32Checked`, and reads `Point`, `Size` and
//! `Vec2` from the three sibling modules.
//!
//! Nothing here allocates, blocks or reads a clock, so no function takes an
//! allocator or an `io`, and `Rect` has no teardown.
//!
//! `Rect` carries no transform. Upstream holds the `Transform` property as
//! `Option<Box<Affine>>` at `accesskit/src/lib.rs:881` and `:2521`, and
//! `docs/30-port-design.md` section 3.4 drops that `Box` for an optional
//! borrowed `Affine`. The decision is about the property payload and not about
//! the box, so it lands with the option properties in `schema/props/option.zig`
//! and not here.
//!
//! `extern struct` is required rather than cosmetic, because the compiler is
//! free to reorder a plain `struct` and these offsets are a contract.
//! `accesskit_rect` in the C header is four `double` at offsets 0, 8, 16 and
//! 24, which is 32 bytes at alignment 8. Those numbers were measured for the C
//! header and then for this Zig form, in `docs/19-geometry-and-text.md`
//! sections 2.2 and 3.3. They are not predictions from the plain-struct layout
//! rule, and the `comptime` block below pins them.
//!
//! One upstream item has no Zig counterpart, and three items here are the
//! port's own. The other four geometry modules keep the same two registers, so
//! the five files read as one decision.
//!
//! - `Default` from the derive at `accesskit/src/geometry.rs:333` is the empty
//!   box. `rect_zero` is the named constant for that value, and the port has no
//!   `Default`.
//!
//! Three items here have no upstream counterpart.
//!
//! - `formatOriginSize` is the alternate arm of `impl fmt::Debug for Rect` at
//!   `:380-386`. Rust reaches that arm through `f.alternate()`, which Zig has no
//!   name for, so the port exposes a second named member and reaches it with
//!   `std.fmt.alt`.
//! - `NarrowError` and `toI32Checked` have no counterpart in the upstream
//!   range. They are the port's own addition, and they sit in this file so a
//!   checked narrowing has one name in the crate. Upstream narrows an `f64` to
//!   an `i32` with `as` at `adapters/atspi-common/src/rect.rs:28-37` and
//!   `adapters/android/src/node.rs:247-250`, and `as` saturates. The doc on
//!   `toI32Checked` states the consequence.
//! - The `comptime` block below pins the layout for every consumer of this
//!   module, including one that imports it in a non-test build.

const std = @import("std");

const size_module = @import("size.zig");

const Point = @import("point.zig").Point;
const Size = size_module.Size;
const Vec2 = @import("vec2.zig").Vec2;

comptime {
    // The ABI contract, measured for `accesskit_rect` in
    // `docs/19-geometry-and-text.md` section 2.2 and re-measured for the Zig
    // form in section 3.3.
    std.debug.assert(@sizeOf(Rect) == 32);
    std.debug.assert(@alignOf(Rect) == 8);
    std.debug.assert(@offsetOf(Rect, "x0") == 0);
    std.debug.assert(@offsetOf(Rect, "y0") == 8);
    std.debug.assert(@offsetOf(Rect, "x1") == 16);
    std.debug.assert(@offsetOf(Rect, "y1") == 24);
}

/// An axis-aligned box held as its two opposite corners.
///
/// `rectInit` keeps the four coordinates in the order the caller gave them, so
/// an inverted box is a valid value with a negative `width` or `height`. Use
/// `rectFromPoints`, `rectFromOriginSize` or `abs` for an ordered box.
///
/// Coordinates are physical pixels in a y-down space with the origin at the top
/// left of the tree container, so `x0` is the left edge and `y0` is the top
/// edge. `contains` treats both far edges as exclusive.
///
/// `Rect` owns nothing. It is four `f64` values, so a copy is independent of
/// the original and no method on it releases anything.
pub const Rect = extern struct {
    /// Left edge, as the caller stored it. An inverted box keeps its larger x
    /// here, so read `minX` when the smallest x is what the caller needs.
    x0: f64,
    /// Top edge in the y-down space, stored the way `x0` is.
    y0: f64,
    /// Right edge, stored as given. `width` is `x1 - x0`, so an inverted box
    /// reports a negative width.
    x1: f64,
    /// Bottom edge in the y-down space, stored the way `x1` is.
    y1: f64,

    /// The stored `x0` and `y0` as a point.
    ///
    /// This is the corner the box was built with and not the smallest one, so
    /// it differs from `minX` and `minY` on an inverted box. Upstream called it
    /// `origin`, and that name hid the difference from a caller who wanted the
    /// minimum corner.
    pub fn topLeft(self: Rect) Point {
        return .{ .x = self.x0, .y = self.y0 };
    }

    /// The smaller of `x0` and `x1`, so not `x0` on an inverted box.
    pub fn minX(self: Rect) f64 {
        return @min(self.x0, self.x1);
    }

    /// The larger of `x0` and `x1`, which differs from `x1` on an inverted box.
    pub fn maxX(self: Rect) f64 {
        return @max(self.x0, self.x1);
    }

    /// The smaller of `y0` and `y1`, so not `y0` on an inverted box.
    pub fn minY(self: Rect) f64 {
        return @min(self.y0, self.y1);
    }

    /// The larger of `y0` and `y1`, which differs from `y1` on an inverted box.
    pub fn maxY(self: Rect) f64 {
        return @max(self.y0, self.y1);
    }

    /// `x1 - x0`. Nothing forbids a negative width.
    pub fn width(self: Rect) f64 {
        return self.x1 - self.x0;
    }

    /// `y1 - y0`. Nothing forbids a negative height.
    pub fn height(self: Rect) f64 {
        return self.y1 - self.y0;
    }

    /// `width` times `height`. The sign follows the inversion, so an inverted
    /// box reports a positive area. Read `isEmpty` for emptiness.
    pub fn area(self: Rect) f64 {
        return self.width() * self.height();
    }

    /// Whether `area` is exactly zero. A negative area is not emptiness, so an
    /// inverted box with a non-zero area is not empty.
    pub fn isEmpty(self: Rect) bool {
        return self.area() == 0.0;
    }

    /// The same extents with the corners ordered, so `width` and `height` are
    /// non-negative.
    pub fn abs(self: Rect) Rect {
        return rectInit(
            @min(self.x0, self.x1),
            @min(self.y0, self.y1),
            @max(self.x0, self.x1),
            @max(self.y0, self.y1),
        );
    }

    /// The box at `origin` with the extent of this one.
    ///
    /// A negative extent of this box leaves the result inverted.
    pub fn withOrigin(self: Rect, origin: Point) Rect {
        return rectFromOriginSize(origin, rectSize(self));
    }

    /// The box at this stored corner with the extent `size`.
    ///
    /// A negative extent in `size` leaves the result inverted, because the
    /// stored corner is the one that moves and not the minimum.
    pub fn withSize(self: Rect, size: Size) Rect {
        return rectFromOriginSize(self.topLeft(), size);
    }

    /// Whether `point` lies inside this box, with both far edges excluded.
    ///
    /// A zero-area box therefore claims no point, not even a point sitting on
    /// its own stored corner.
    pub fn contains(self: Rect, point: Point) bool {
        return point.x >= self.x0 and point.x < self.x1 and
            point.y >= self.y0 and point.y < self.y1;
    }

    /// The smallest box that encloses both inputs.
    ///
    /// The result is valid only when both inputs have a non-negative width and
    /// height. Nothing is normalised here, so an inverted input decides the
    /// result on that axis.
    pub fn unionRect(self: Rect, other: Rect) Rect {
        return rectInit(
            @min(self.x0, other.x0),
            @min(self.y0, other.y0),
            @max(self.x1, other.x1),
            @max(self.y1, other.y1),
        );
    }

    /// The smallest box that encloses this box and `pt`.
    ///
    /// The perimeter of a zero-area box counts, so a succession of calls over a
    /// series of points encloses every one of them. The result is valid only
    /// when this box has a non-negative width and height.
    pub fn unionPoint(self: Rect, pt: Point) Rect {
        return rectInit(
            @min(self.x0, pt.x),
            @min(self.y0, pt.y),
            @max(self.x1, pt.x),
            @max(self.y1, pt.y),
        );
    }

    /// The overlap of two boxes, clamped so the width and height are
    /// non-negative.
    ///
    /// An input with a negative width or height yields a zero-area result, and
    /// two boxes that touch along an edge intersect in a zero-area box on that
    /// edge.
    pub fn intersect(self: Rect, other: Rect) Rect {
        const x0 = @max(self.x0, other.x0);
        const y0 = @max(self.y0, other.y0);
        const x1 = @min(self.x1, other.x1);
        const y1 = @min(self.y1, other.y1);
        return rectInit(x0, y0, @max(x1, x0), @max(y1, y0));
    }

    /// All four corners moved by `v`, so the box keeps its extents.
    pub fn addVec2(self: Rect, v: Vec2) Rect {
        return rectInit(self.x0 + v.x, self.y0 + v.y, self.x1 + v.x, self.y1 + v.y);
    }

    /// All four corners moved back by `v`.
    pub fn subVec2(self: Rect, v: Vec2) Rect {
        return rectInit(self.x0 - v.x, self.y0 - v.y, self.x1 - v.x, self.y1 - v.y);
    }

    /// Writes the four corners as `Rect { x0: …, y0: …, x1: …, y1: … }`. Each
    /// coordinate is written by `{d}`, so a whole number carries no decimal
    /// point.
    pub fn format(self: Rect, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Rect {{ x0: {d}, y0: {d}, x1: {d}, y1: {d} }}", .{
            self.x0,
            self.y0,
            self.x1,
            self.y1,
        });
    }

    /// Writes the stored corner and the extent as
    /// `Rect { origin: (x, y), size: wW×hH }`. Reach it through
    /// `std.fmt.alt(rect, .formatOriginSize)`.
    ///
    /// The corner and the extent reach this line through the `format` of
    /// `Point` and `Size`, so their text is theirs and not a second copy here.
    pub fn formatOriginSize(self: Rect, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Rect {{ origin: {f}, size: {f} }}", .{
            self.topLeft(),
            rectSize(self),
        });
    }
};

/// The empty box at the container origin.
///
/// Its area is zero, so `isEmpty` reports `true`, and `contains` claims no
/// point because both far edges are exclusive.
pub const rect_zero: Rect = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

/// A box from its two opposite corners, kept in the order given.
///
/// The corners are not sorted, so the result may be inverted.
pub fn rectInit(x0: f64, y0: f64, x1: f64, y1: f64) Rect {
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

/// The box that encloses `p0` and `p1`.
///
/// The corners are ordered before the box is returned, so the width and the
/// height are non-negative whichever order the two points arrive in.
pub fn rectFromPoints(p0: Point, p1: Point) Rect {
    return rectInit(p0.x, p0.y, p1.x, p1.y).abs();
}

/// The box at `origin` with the extent `size`.
///
/// The corners are ordered before the box is returned, so a negative extent
/// still yields a non-negative width and height.
pub fn rectFromOriginSize(origin: Point, size: Size) Rect {
    return rectFromPoints(origin, origin.addVec2(size_module.sizeToVec2(size)));
}

/// The width and height of `self` as an extent, which is negative on an
/// inverted box.
///
/// Upstream called this `size`, and `Node` already owns that name. It is a
/// conversion rather than an operation on the value, so it sits at file scope
/// beside `rectFromPoints` and `rectFromOriginSize`.
pub fn rectSize(self: Rect) Size {
    return .{ .width = self.width(), .height = self.height() };
}

/// Failure modes of `toI32Checked`.
pub const NarrowError = error{
    /// The value is not finite, or it lies outside the `i32` range.
    OutOfRange,
};

/// `value` truncated toward zero as an `i32`.
///
/// Returns `error.OutOfRange` when `value` is not finite or does not fit in an
/// `i32`. Upstream narrows a `Rect` with `as` at
/// `adapters/atspi-common/src/rect.rs:31` and `adapters/android/src/node.rs:247`,
/// and `as` saturates, so a port that copied it would publish a wrong rectangle
/// on a large display. Nothing is allocated and nothing is retained.
pub fn toI32Checked(value: f64) NarrowError!i32 {
    if (!std.math.isFinite(value)) return error.OutOfRange;
    if (value >= 2147483648.0 or value < -2147483648.0) return error.OutOfRange;
    return @intFromFloat(value);
}

const testing = std.testing;

test "the layout is the C header layout" {
    // The comptime block above is the compile-time gate. This test adds the
    // four-box stride, which is what proves there is no tail padding.
    try testing.expectEqual(@as(usize, 32), @sizeOf(Rect));
    try testing.expectEqual(@as(usize, 8), @alignOf(Rect));
    try testing.expectEqual(@as(usize, 0), @offsetOf(Rect, "x0"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Rect, "y0"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Rect, "x1"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(Rect, "y1"));
    try testing.expectEqual(@as(usize, 128), @sizeOf([4]Rect));
}

test "negative coordinates give a positive extent" {
    const r = rectInit(-10, -20, 30, 40);
    try testing.expectEqual(@as(f64, 40), r.width());
    try testing.expectEqual(@as(f64, 60), r.height());
    try testing.expectEqual(@as(f64, 2400), r.area());
    try testing.expect(!r.isEmpty());
    try testing.expect(r.contains(.{ .x = -10, .y = -20 }));
    try testing.expect(r.contains(.{ .x = 29.999, .y = 39.999 }));
    try testing.expect(!r.contains(.{ .x = 30, .y = 40 }));
}

test "a zero-area box claims no point and stays put under unionPoint" {
    const r = rectInit(5, 7, 5, 7);
    try testing.expectEqual(@as(f64, 0), r.width());
    try testing.expectEqual(@as(f64, 0), r.height());
    try testing.expectEqual(@as(f64, 0), r.area());
    try testing.expect(r.isEmpty());
    try testing.expectEqual(Point{ .x = 5, .y = 7 }, r.topLeft());
    try testing.expect(!r.contains(.{ .x = 5, .y = 7 }));
    try testing.expectEqual(r, r.unionPoint(.{ .x = 5, .y = 7 }));
}

test "an inverted box reports its stored corner and a positive area" {
    const r = rectInit(80, 60, 20, 10);
    try testing.expectEqual(@as(f64, -60), r.width());
    try testing.expectEqual(@as(f64, -50), r.height());
    try testing.expectEqual(@as(f64, 3000), r.area());
    try testing.expect(!r.isEmpty());
    try testing.expectEqual(Point{ .x = 80, .y = 60 }, r.topLeft());
    try testing.expectEqual(Size{ .width = -60, .height = -50 }, rectSize(r));
    try testing.expectEqual(@as(f64, 20), r.minX());
    try testing.expectEqual(@as(f64, 80), r.maxX());
    try testing.expectEqual(@as(f64, 10), r.minY());
    try testing.expectEqual(@as(f64, 60), r.maxY());
    try testing.expectEqual(rectInit(20, 10, 80, 60), r.abs());
}

test "rectFromPoints orders the corners whichever order they arrive in" {
    const low: Point = .{ .x = 80, .y = 60 };
    const high: Point = .{ .x = 20, .y = 10 };
    const forward = rectFromPoints(low, high);
    const reverse = rectFromPoints(high, low);
    try testing.expectEqual(forward, reverse);
    try testing.expectEqual(@as(f64, 20), reverse.x0);
    try testing.expectEqual(@as(f64, 10), reverse.y0);
    try testing.expectEqual(@as(f64, 80), reverse.x1);
    try testing.expectEqual(@as(f64, 60), reverse.y1);
    try testing.expectEqual(@as(f64, 60), reverse.width());
    try testing.expectEqual(@as(f64, 50), reverse.height());
}

test "an inverted box intersects to a zero-area box on its own corner" {
    const inverted = rectInit(80, 60, 20, 10);
    const other = rectInit(-10, -20, 30, 40);
    const shared = inverted.intersect(other);
    try testing.expectEqual(rectInit(80, 60, 80, 60), shared);
    try testing.expect(shared.isEmpty());
    try testing.expectEqual(other, other.unionRect(inverted));
}

test "unionRect of disjoint boxes still encloses both" {
    const left = rectInit(0, 0, 10, 10);
    const right = rectInit(100, 200, 110, 210);
    const joined = left.unionRect(right);
    try testing.expectEqual(@as(f64, 0), joined.x0);
    try testing.expectEqual(@as(f64, 0), joined.y0);
    try testing.expectEqual(@as(f64, 110), joined.x1);
    try testing.expectEqual(@as(f64, 210), joined.y1);
    try testing.expect(joined.contains(.{ .x = 5, .y = 5 }));
    try testing.expect(joined.contains(.{ .x = 105, .y = 205 }));
    try testing.expect(!left.contains(.{ .x = 105, .y = 205 }));
}

test "boxes that touch along an edge intersect to a zero-area box there" {
    const left = rectInit(0, 0, 10, 10);
    const right = rectInit(10, 0, 20, 10);
    const shared = left.intersect(right);
    try testing.expectEqual(rectInit(10, 0, 10, 10), shared);
    try testing.expectEqual(@as(f64, 0), shared.width());
    try testing.expectEqual(@as(f64, 10), shared.height());
    try testing.expectEqual(@as(f64, 0), shared.area());
    try testing.expect(shared.isEmpty());
    try testing.expect(!shared.contains(.{ .x = 10, .y = 5 }));
}

test "a box that overflows its parent is not clipped by Rect itself" {
    const parent = rectInit(0, 0, 100, 50);
    const child = rectInit(90, 40, 140, 90);
    try testing.expectEqual(rectInit(90, 40, 100, 50), child.intersect(parent));
    try testing.expectEqual(rectInit(0, 0, 140, 90), parent.unionRect(child));
    try testing.expect(parent.contains(.{ .x = 95, .y = 45 }));
    try testing.expect(!parent.contains(.{ .x = 105, .y = 45 }));
    try testing.expect(child.contains(.{ .x = 95, .y = 45 }));
}

test "a succession of unionPoint calls encloses every point" {
    try testing.expectEqual(rectInit(0, 0, 0, 0), rect_zero);
    try testing.expect(rect_zero.isEmpty());
    try testing.expectEqual(rect_zero, rect_zero.unionPoint(.{ .x = 0, .y = 0 }));
    const walked = rect_zero
        .unionPoint(.{ .x = 5, .y = 0 })
        .unionPoint(.{ .x = 5, .y = 7 })
        .unionPoint(.{ .x = -3, .y = 7 });
    try testing.expectEqual(rectInit(-3, 0, 5, 7), walked);
    try testing.expectEqual(@as(f64, 8), walked.width());
    try testing.expectEqual(@as(f64, 7), walked.height());
}

test "addVec2 and subVec2 move every corner together" {
    const r = rectInit(1, 2, 3, 4);
    const v: Vec2 = .{ .x = 10, .y = -5 };
    const moved = r.addVec2(v);
    try testing.expectEqual(rectInit(11, -3, 13, -1), moved);
    try testing.expectEqual(r, moved.subVec2(v));
    try testing.expectEqual(@as(f64, 2), moved.width());
    try testing.expectEqual(@as(f64, 2), moved.height());
}

test "withOrigin keeps the extent and withSize keeps the stored corner" {
    const r = rectInit(1, 2, 3, 4);
    const moved = r.withOrigin(.{ .x = 10, .y = 20 });
    try testing.expectEqual(rectInit(10, 20, 12, 22), moved);
    try testing.expectEqual(@as(f64, 2), moved.width());
    const resized = r.withSize(.{ .width = 5, .height = 7 });
    try testing.expectEqual(rectInit(1, 2, 6, 9), resized);
    try testing.expectEqual(Point{ .x = 1, .y = 2 }, resized.topLeft());
}

test "rectFromOriginSize orders a negative extent" {
    const r = rectFromOriginSize(.{ .x = 10, .y = 20 }, .{ .width = -4, .height = -6 });
    try testing.expectEqual(rectInit(6, 14, 10, 20), r);
    try testing.expectEqual(@as(f64, 4), r.width());
    try testing.expectEqual(@as(f64, 6), r.height());
}

test "toI32Checked truncates toward zero" {
    try testing.expectEqual(@as(i32, 0), try toI32Checked(-0.9));
    try testing.expectEqual(@as(i32, 9), try toI32Checked(9.75));
    try testing.expectEqual(@as(i32, -9), try toI32Checked(-9.75));
    try testing.expectEqual(@as(i32, 30000000), try toI32Checked(3.0e7));
    try testing.expectEqual(std.math.minInt(i32), try toI32Checked(-2147483648.0));
    try testing.expectEqual(std.math.maxInt(i32), try toI32Checked(2147483647.0));
}

test "toI32Checked rejects what an i32 cannot hold" {
    try testing.expectError(error.OutOfRange, toI32Checked(1.0e19));
    try testing.expectError(error.OutOfRange, toI32Checked(-1.0e19));
    try testing.expectError(error.OutOfRange, toI32Checked(std.math.inf(f64)));
    try testing.expectError(error.OutOfRange, toI32Checked(-std.math.inf(f64)));
    try testing.expectError(error.OutOfRange, toI32Checked(std.math.nan(f64)));
}

test "every NarrowError member is reachable" {
    inline for (@typeInfo(NarrowError).error_set.?) |member| {
        const rejecting: f64 = if (std.mem.eql(u8, member.name, "OutOfRange")) 1.0e19 else 0.0;
        try testing.expectError(@field(NarrowError, member.name), toI32Checked(rejecting));
    }
}

test "format writes the four corners" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try rectInit(1, 2, 3, 4).format(&writer);
    try testing.expectEqualStrings("Rect { x0: 1, y0: 2, x1: 3, y1: 4 }", writer.buffered());
}

test "formatOriginSize writes the stored corner and the extent" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.print("{f}", .{std.fmt.alt(rectInit(1, 2, 3, 4), .formatOriginSize)});
    try testing.expectEqualStrings(
        "Rect { origin: (1, 2), size: 2W×2H }",
        writer.buffered(),
    );
}
