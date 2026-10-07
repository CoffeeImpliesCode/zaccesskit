//! `Point`, the position type of the AccessKit geometry model, ported from
//! `accesskit/src/geometry.rs:207-330`.
//!
//! The module publishes `Point`, the `point_origin` constant, the conversion
//! `pointToVec2`, and the behaviour `Point` has: the three arithmetic methods
//! and `format`. It allocates nothing, blocks on nothing, reads no clock and
//! holds no state, so no function here takes an allocator or an `io`. A
//! `Point` owns nothing, so there is nothing for a consumer to release.
//!
//! `format` is a member of `Point` and not a file-scope function, because the
//! `{f}` format specifier reaches a value as `value.format(writer)`.
//!
//! `Point` is an `extern struct`: 16 bytes at alignment 8, `x` at offset 0 and
//! `y` at offset 8. That is the layout `accesskit_point` has in
//! `accesskit-c/include/accesskit.h:998-1007`, so a `callconv(.C)` signature on
//! either side of the C seam agrees without a wrapper. A plain `struct` would
//! measure the same today and is still wrong, because only `extern` pins the
//! field order.
//!
//! Shortest use:
//!
//! ```zig
//! const geometry = @import("point.zig");
//! const moved = geometry.pointInit(10, 20).addVec2(.{ .x = 3, .y = 4 });
//! ```
//!
//! Nine upstream items are deliberately not carried, because Zig spells the
//! operation once and needs no second name for it.
//!
//! - `Point::ZERO` (`:221`) holds the value `Point::ORIGIN` (`:224`) already
//!   holds, so `point_origin` is the single name for both.
//! - The four assign impls (`:262`, `:278`, `:294`, `:310`) exist because Rust
//!   makes `p += q` an operation distinct from `p = p + q`. A Zig caller writes
//!   `p = p.addVec2(v)`, which is one spelling, not two.
//! - The two tuple arithmetic impls (`:285` and `:301`, their assign forms
//!   already listed above) take a bare `(f64, f64)`. `pointToVec2` reads a
//!   `Point` as that vector, so `addVec2` and `subVec2` cover them.
//! - The two tuple conversions (`:239`, `:246`) exist because Rust has no
//!   named-field struct literal for a `(f64, f64)`. Zig has one,
//!   `.{ .x = x, .y = y }`, and it reads the same in both directions.
//!
//! One item here has no upstream counterpart, and the other four geometry
//! modules keep the same two registers, so the five files read as one decision.
//!
//! - The `comptime` block below pins the layout for every consumer of this
//!   module, including one that imports it in a non-test build.

const std = @import("std");
const Vec2 = @import("vec2.zig").Vec2;

/// A position in the tree container's coordinate space.
///
/// Any `f64` is a valid coordinate: upstream applies no range check and this
/// port adds none, so a `NaN` or an infinity reaches the arithmetic unchanged.
/// The value owns nothing and borrows nothing, a copy is independent of the
/// original, and it may be passed across threads.
pub const Point = extern struct {
    /// Physical pixels, growing rightward from the container's origin.
    x: f64,

    /// Physical pixels, growing downward from the container's origin.
    y: f64,

    /// The point reached by moving `self` by `v`.
    ///
    /// `self` is unchanged; the caller assigns the result.
    pub fn addVec2(self: Point, v: Vec2) Point {
        return .{ .x = self.x + v.x, .y = self.y + v.y };
    }

    /// The point reached by moving `self` back by `v`.
    ///
    /// `self` is unchanged; the caller assigns the result.
    pub fn subVec2(self: Point, v: Vec2) Point {
        return .{ .x = self.x - v.x, .y = self.y - v.y };
    }

    /// The displacement that carries `other` onto `self`.
    ///
    /// This is the one subtraction on `Point` that yields a vector, because the
    /// difference between two positions is a translation and not a position.
    pub fn subPoint(self: Point, other: Point) Vec2 {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    /// Writes `self` as `(x, y)`.
    ///
    /// This is a member because the `{f}` format specifier reaches it as
    /// `value.format(writer)`, so a `Point` nested in another printable value
    /// only formats if this is here. The shape is the upstream `fmt::Debug`
    /// output at `accesskit/src/geometry.rs:328`; the bytes differ, because
    /// Rust's `{:?}` prints `1.0` and `{d}` prints `1`. Debug formatting is not
    /// ABI and nothing parses it, so the port takes the Zig spelling.
    ///
    /// Fails with `error.WriteFailed` when `writer` runs out of room, having
    /// written the prefix that fitted. Allocates nothing and retains nothing.
    pub fn format(self: Point, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("({d}, {d})", .{ self.x, self.y });
    }
};

/// The point (0, 0), the top-left corner of the tree container.
///
/// Upstream declares this value twice, as `Point::ZERO`
/// (`accesskit/src/geometry.rs:221`) and as `Point::ORIGIN`
/// (`accesskit/src/geometry.rs:224`). This is the single name for both, and
/// `Point` carries no `Default` in its place.
pub const point_origin: Point = pointInit(0.0, 0.0);

/// A point `x` across and `y` down from the container's origin.
///
/// Usable at comptime, as the upstream `const fn new` is.
pub fn pointInit(x: f64, y: f64) Point {
    return .{ .x = x, .y = y };
}

/// The same two numbers read as a translation.
///
/// `Point` and `Vec2` are the same shape and differ only in what they mean, so
/// this copies both fields and changes nothing else. It is also the reading of
/// a `Point` as the `(f64, f64)` pair the deleted tuple impls took.
pub fn pointToVec2(self: Point) Vec2 {
    return .{ .x = self.x, .y = self.y };
}

comptime {
    // `docs/19-geometry-and-text.md` section 3.3 measured these numbers with
    // `@sizeOf`, `@alignOf` and `@offsetOf`, and section 3.2 explains why a
    // plain `struct` is not an acceptable substitute. A container-level
    // `comptime` block does not have the bare `assert` builtin on Zig 0.16.0,
    // so these go through `std.debug.assert`.
    std.debug.assert(@sizeOf(Point) == 16);
    std.debug.assert(@alignOf(Point) == 8);
    std.debug.assert(@offsetOf(Point, "x") == 0);
    std.debug.assert(@offsetOf(Point, "y") == 8);
    const info = @typeInfo(Point);
    std.debug.assert(info == .@"struct");
    std.debug.assert(info.@"struct".layout == .@"extern");
}

test "Point keeps the layout accesskit_point promises" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Point));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Point));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Point, "x"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Point, "y"));
}

test "Point is an extern struct and not a plain one" {
    const info = @typeInfo(Point);
    try std.testing.expect(info == .@"struct");
    try std.testing.expect(info.@"struct".layout == .@"extern");
}

test "point_origin is the point (0, 0) that both upstream names hold" {
    // Upstream declares the value twice, as `Point::ZERO` at
    // `accesskit/src/geometry.rs:221` and as `Point::ORIGIN` at `:224`, and
    // both are `Point::new(0., 0.)`. The port keeps one name for the pair, so
    // both coordinates must be zero.
    try std.testing.expectEqual(@as(f64, 0.0), point_origin.x);
    try std.testing.expectEqual(@as(f64, 0.0), point_origin.y);
}

test "pointInit is usable at comptime" {
    const p: Point = pointInit(1.5, -2.5);
    try std.testing.expectEqual(@as(f64, 1.5), p.x);
    try std.testing.expectEqual(@as(f64, -2.5), p.y);
}

test "pointToVec2 keeps both coordinates" {
    // The axes differ, so a swap cannot pass.
    const v: Vec2 = pointToVec2(pointInit(1.5, -2.5));
    try std.testing.expect(@TypeOf(v) == Vec2);
    try std.testing.expectEqual(@as(f64, 1.5), v.x);
    try std.testing.expectEqual(@as(f64, -2.5), v.y);
}

test "addVec2 moves the point forward" {
    const moved: Point = pointInit(10, 20).addVec2(.{ .x = 3, .y = 4 });
    try std.testing.expectEqual(@as(f64, 13), moved.x);
    try std.testing.expectEqual(@as(f64, 24), moved.y);
}

test "subVec2 moves the point back" {
    const moved: Point = pointInit(10, 20).subVec2(.{ .x = 3, .y = 4 });
    try std.testing.expectEqual(@as(f64, 7), moved.x);
    try std.testing.expectEqual(@as(f64, 16), moved.y);
}

test "addVec2 and subVec2 undo each other" {
    const start: Point = pointInit(-7.5, 0.25);
    const there: Point = start.addVec2(.{ .x = 11, .y = -3 });
    const back: Point = there.subVec2(.{ .x = 11, .y = -3 });
    try std.testing.expectEqual(start, back);
}

test "subPoint yields a Vec2 displacement" {
    const d: Vec2 = pointInit(10, 20).subPoint(pointInit(3, 4));
    try std.testing.expect(@TypeOf(d) == Vec2);
    try std.testing.expectEqual(@as(f64, 7), d.x);
    try std.testing.expectEqual(@as(f64, 16), d.y);
}

test "a point moved by addVec2 and back by subVec2 is unchanged" {
    // Covers the caller-side form the deleted assign impls would have named.
    var p: Point = pointInit(10, 20);
    p = p.addVec2(.{ .x = 3, .y = 4 });
    try std.testing.expectEqual(@as(f64, 13), p.x);
    try std.testing.expectEqual(@as(f64, 24), p.y);
    p = p.subVec2(.{ .x = 3, .y = 4 });
    try std.testing.expectEqual(@as(f64, 10), p.x);
    try std.testing.expectEqual(@as(f64, 20), p.y);
}

test "format writes the upstream Debug shape" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try pointInit(1, 2).format(&writer);
    try std.testing.expectEqualStrings("(1, 2)", writer.buffered());
}

test "a Point prints through the {f} specifier" {
    // `{f}` reaches a value as `value.format(writer)`, so this stops compiling
    // the day `format` moves back out to file scope.
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.print("{f}", .{pointInit(1, 2)});
    try std.testing.expectEqualStrings("(1, 2)", writer.buffered());
}

test "format reports a short writer as error.WriteFailed" {
    var buffer: [3]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, pointInit(1234, 5678).format(&writer));
}
