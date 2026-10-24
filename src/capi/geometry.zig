//! The geometry surface of the C ABI: 49 exported functions over the five
//! geometry value types.
//!
//! **What this module is for.** It gives each of the 49 `accesskit_*`
//! declarations in the geometry block of `include/zaccesskit.h:5374-5698` a
//! body, and it is the only place in the port where a C caller reaches the
//! geometry arithmetic. The arithmetic itself is not here: the port of
//! `accesskit/src/geometry.rs` lives in `src/schema/geometry/`, and every
//! function below is one call into it.
//!
//! **Upstream range.** `accesskit/src/geometry.rs:22-866`, which is the whole
//! of that file's public geometry: `pub struct Affine` at `:22` through
//! `impl Neg for Vec2` at `:856-866`. Every one of the 49 declarations is a
//! named call into that range, and every doc comment below carries the line it
//! came from. The two upstream items in the range that this module does not
//! reach are the property getters and setters, which are the node family's:
//! `accesskit_node_transform` at `include/zaccesskit.h:4917`,
//! `accesskit_node_set_transform` at `:4926`,
//! `accesskit_node_set_bounds` at `:4952` and `accesskit_node_bounds` at
//! `:4943`.
//!
//! **The ABI claim, and every field in ABI order.** The C names below are the
//! header's, the sizes and alignments are the header's own table at
//! `include/zaccesskit.h:6536-6547`, and the field order is the order the
//! header declares, which is the order a C caller reads:
//!
//! | Header type | Zig type | Size | Align | Fields in ABI order |
//! |---|---|---:|---:|---|
//! | `accesskit_affine` | `Affine` | 48 | 8 | `double _0[6]` |
//! | `accesskit_rect` | `Rect` | 32 | 8 | `double x0; double y0; double x1; double y1;` |
//! | `accesskit_point` | `Point` | 16 | 8 | `double x; double y;` |
//! | `accesskit_vec2` | `Vec2` | 16 | 8 | `double x; double y;` |
//! | `accesskit_size` | `Size` | 16 | 8 | `double width; double height;` |
//!
//! One name differs between the two columns. The header spells the affine
//! coefficients `_0` because C has no tuple type, and the port spells them
//! `coeffs`. Both are one `double[6]` at offset 0, so the two spellings are the
//! same six bytes. The other four types agree field for field. The `comptime`
//! block below pins the sizes, the alignments and every field offset, so a
//! field added to one of these types, or a pair of them reordered, is a build
//! failure rather than a silent ABI change.
//!
//! **Which exports and which import route.** All 49 are `export fn` under the C
//! calling convention, and the export identifier is the C symbol, so a caller
//! links them by the name the header gives. A Zig consumer reaches them through
//! `@import("zaccesskit").capi.geometry` once `src/root.zig` publishes the
//! `capi` namespace; nothing in this module is reached any other way.
//!
//! **What this module deliberately does not do.** It does not compute. It holds
//! no `Affine` algebra, no rectangle arithmetic and no conversion between the
//! five types, because `src/schema/geometry/` holds all of it and a second copy
//! would be a second place to keep in sync. It does not own a `Node` and it does
//! not read a property, because the geometry properties are the node family's.
//! It does not allocate, so it takes no allocator and a C caller has nothing to
//! release: every one of the 49 returns a value or a `bool`, and the seventeen
//! that take a pointer borrow it for the call and retain nothing.
//!
//! **Null.** Seventeen of the 49 take `const struct accesskit_rect *` or
//! `const struct accesskit_affine *`. The header states what each answers for a
//! null pointer, and each body here returns that value rather than reading
//! through the pointer. A null therefore never reaches the arithmetic, and no
//! null answer is a failure report.
//!
//! **Loops.** The two sweeps in this file are the `comptime` signature check
//! below and `countFamily`, and both walk `export_signatures`, whose bound is
//! its own length and is 49. There is no other loop here and no iteration at
//! run time. The `Affine` operations that upstream writes as a chain over six
//! coefficients, `is_finite` and `is_nan`, are six fixed terms in
//! `src/schema/geometry/affine.zig:217-237`, and this module only calls them.
//!
//! **The shortest sequence that uses this module.**
//!
//! ```zig
//! const a = accesskit_affine_translate(.{ .x = 3.0, .y = 4.0 });
//! const p = accesskit_affine_transform_point(a, .{ .x = 1.0, .y = 1.0 });
//! // p is the point (4, 5).
//! ```
//!
//! A C consumer writes the same call as `accesskit_affine_transform_point(a, p)`
//! and reads the two `double` out of the returned `struct accesskit_point`.

const std = @import("std");

const schema = @import("../schema/root.zig");
const affine_mod = @import("../schema/geometry/affine.zig");
const point_mod = @import("../schema/geometry/point.zig");
const rect_mod = @import("../schema/geometry/rect.zig");
const size_mod = @import("../schema/geometry/size.zig");
const vec2_mod = @import("../schema/geometry/vec2.zig");

const Affine = schema.Affine;
const Point = schema.Point;
const Rect = schema.Rect;
const Size = schema.Size;
const Vec2 = schema.Vec2;

comptime {
    // The C declaration, per field. `accesskit_affine` is `double _0[6]` at
    // `include/zaccesskit.h:1440-1442`, `accesskit_rect` is four `double` at
    // `:1451-1456`, `accesskit_point` is two at `:1533-1536`, `accesskit_vec2`
    // is two at `:1545-1548` and `accesskit_size` is two at `:1557-1560`. The
    // sizes and alignments are the header's table at `:6536-6547`.
    //
    // A container-level `comptime` block has no bare `assert` builtin on Zig
    // 0.16.0, so these go through `std.debug.assert`. Every number here is one
    // the tests below also assert at run time, against bytes.
    std.debug.assert(@sizeOf(Affine) == 48);
    std.debug.assert(@alignOf(Affine) == 8);
    std.debug.assert(@offsetOf(Affine, "coeffs") == 0);

    std.debug.assert(@sizeOf(Rect) == 32);
    std.debug.assert(@alignOf(Rect) == 8);
    std.debug.assert(@offsetOf(Rect, "x0") == 0);
    std.debug.assert(@offsetOf(Rect, "y0") == 8);
    std.debug.assert(@offsetOf(Rect, "x1") == 16);
    std.debug.assert(@offsetOf(Rect, "y1") == 24);

    std.debug.assert(@sizeOf(Point) == 16);
    std.debug.assert(@alignOf(Point) == 8);
    std.debug.assert(@offsetOf(Point, "x") == 0);
    std.debug.assert(@offsetOf(Point, "y") == 8);

    std.debug.assert(@sizeOf(Vec2) == 16);
    std.debug.assert(@alignOf(Vec2) == 8);
    std.debug.assert(@offsetOf(Vec2, "x") == 0);
    std.debug.assert(@offsetOf(Vec2, "y") == 8);

    std.debug.assert(@sizeOf(Size) == 16);
    std.debug.assert(@alignOf(Size) == 8);
    std.debug.assert(@offsetOf(Size, "width") == 0);
    std.debug.assert(@offsetOf(Size, "height") == 8);
}

// --- The affine transform ------------------------------------------------------

/// The transform that leaves every point where it is. Upstream
/// `Affine::IDENTITY` at `accesskit/src/geometry.rs:26`, and the C declaration
/// is `include/zaccesskit.h:5377`. The result is a value, so a C caller has
/// nothing to release.
export fn accesskit_affine_identity() callconv(.c) Affine {
    return affine_mod.affine_identity;
}

/// The transform that mirrors across the x axis. Upstream `Affine::FLIP_Y` at
/// `accesskit/src/geometry.rs:30`, and the C declaration is
/// `include/zaccesskit.h:5382`.
export fn accesskit_affine_flip_y() callconv(.c) Affine {
    return affine_mod.affine_flip_y;
}

/// The transform that mirrors across the y axis. Upstream `Affine::FLIP_X` at
/// `accesskit/src/geometry.rs:33`, and the C declaration is
/// `include/zaccesskit.h:5387`.
export fn accesskit_affine_flip_x() callconv(.c) Affine {
    return affine_mod.affine_flip_x;
}

/// The transform that scales every distance by `s`. Upstream `Affine::scale`
/// at `accesskit/src/geometry.rs:59`, and the C declaration is
/// `include/zaccesskit.h:5392`. `s` is a factor in logical pixels per logical
/// pixel, so it is unitless, and no value of it is rejected.
export fn accesskit_affine_scale(s: f64) callconv(.c) Affine {
    return affine_mod.affineScale(s);
}

/// The transform that scales the x axis by `s_x` and the y axis by `s_y`.
/// Upstream `Affine::scale_non_uniform` at `accesskit/src/geometry.rs:66`, and
/// the C declaration is `include/zaccesskit.h:5398`. The two factors are the
/// x axis and then the y axis, and neither is checked.
export fn accesskit_affine_scale_non_uniform(s_x: f64, s_y: f64) callconv(.c) Affine {
    return affine_mod.affineScaleNonUniform(.{ .x = s_x, .y = s_y });
}

/// The transform that moves every point by `p`. Upstream
/// `Affine::translate` at `accesskit/src/geometry.rs:72`, and the C declaration
/// is `include/zaccesskit.h:5404`. The two components are logical pixels.
export fn accesskit_affine_translate(p: Vec2) callconv(.c) Affine {
    return affine_mod.affineTranslate(p);
}

/// The transform that maps the unit square onto `rect`. Upstream
/// `Affine::map_unit_square` at `accesskit/src/geometry.rs:81`, and the C
/// declaration is `include/zaccesskit.h:5410`. A `rect` with a negative width or
/// height gives a negative scale on that axis, and a non-finite corner gives a
/// non-finite coefficient.
export fn accesskit_affine_map_unit_square(rect: Rect) callconv(.c) Affine {
    return affine_mod.affineMapUnitSquare(rect);
}

/// The determinant of `affine`, the factor by which it scales area. Upstream
/// `Affine::determinant` at `accesskit/src/geometry.rs:92`, and the C
/// declaration is `include/zaccesskit.h:5415`. The result is in logical pixels
/// squared per logical pixel squared, and it is zero for a singular transform.
export fn accesskit_affine_determinant(affine: Affine) callconv(.c) f64 {
    return affine_mod.determinant(affine);
}

/// The transform that undoes `affine`. Upstream `Affine::inverse` at
/// `accesskit/src/geometry.rs:99`, and the C declaration is
/// `include/zaccesskit.h:5424`. A singular `affine` has no inverse, and the six
/// coefficients are then not finite, which
/// `accesskit_affine_is_finite` reports. That is not an error and the call
/// reports none.
export fn accesskit_affine_inverse(affine: Affine) callconv(.c) Affine {
    return affine_mod.inverse(affine);
}

/// The smallest rectangle containing `rect` after `affine` has been applied to
/// it. Upstream `Affine::transform_rect_bbox` at
/// `accesskit/src/geometry.rs:118`, and the C declaration is
/// `include/zaccesskit.h:5431`. The result always has a non-negative width and a
/// non-negative height, and it is the transformed rectangle itself when the map
/// is axis-aligned. It is not finite when a corner transforms to a non-finite
/// point.
export fn accesskit_affine_transform_rect_bbox(affine: Affine, rect: Rect) callconv(.c) Rect {
    return affine_mod.transformRectBbox(affine, rect);
}

/// Whether every coefficient of `affine` is a finite number. Upstream
/// `Affine::is_finite` at `accesskit/src/geometry.rs:128`, and the C declaration
/// is `include/zaccesskit.h:5439`. `null` answers `false` rather than reading
/// the pointer. A NaN coefficient and an infinite coefficient both answer
/// `false`.
export fn accesskit_affine_is_finite(affine: ?*const Affine) callconv(.c) bool {
    const value = affine orelse return false;
    return affine_mod.isFinite(value.*);
}

/// Whether any coefficient of `affine` is a NaN. Upstream `Affine::is_nan` at
/// `accesskit/src/geometry.rs:139`, and the C declaration is
/// `include/zaccesskit.h:5446`. `null` answers `false` rather than reading the
/// pointer. An infinite coefficient is not a NaN and answers `false`.
export fn accesskit_affine_is_nan(affine: ?*const Affine) callconv(.c) bool {
    const value = affine orelse return false;
    return affine_mod.isNan(value.*);
}

/// The transform that applies `b` and then `a`. Upstream `Affine::mul` in
/// `impl Mul for Affine` at `accesskit/src/geometry.rs:172`, and the C
/// declaration is `include/zaccesskit.h:5455`. Upstream states the order as
/// `mulPoint(mul(a, b), p)` equalling `mulPoint(a, mulPoint(b, p))` at `:46-51`,
/// so the right-hand transform applies first. The header prose at
/// `include/zaccesskit.h:5449` reads "applies `a` and then `b`", which is the
/// reverse of what the implementation and every C consumer of upstream do, so
/// this comment follows the implementation. The result is a 48-byte aggregate,
/// so on the x86-64 System V convention it travels through a hidden pointer.
export fn accesskit_affine_mul(a: Affine, b: Affine) callconv(.c) Affine {
    return affine_mod.mul(a, b);
}

/// `point` after `affine` has been applied to it. Upstream `Affine::mul` in
/// `impl Mul<Point> for Affine` at `accesskit/src/geometry.rs:160`, and the C
/// declaration is `include/zaccesskit.h:5462`. The result is not finite when a
/// coefficient and a coordinate are large enough to overflow their product or
/// their sum.
export fn accesskit_affine_transform_point(affine: Affine, point: Point) callconv(.c) Point {
    return affine_mod.mulPoint(affine, point);
}

// --- The point -----------------------------------------------------------------

/// `point` read as a vector, so `x` and `y` keep their values. Upstream
/// `Point::to_vec2` at `accesskit/src/geometry.rs:234`, and the C declaration is
/// `include/zaccesskit.h:5468`. The two components are logical pixels, and the
/// copy loses no precision.
export fn accesskit_point_to_vec2(point: Point) callconv(.c) Vec2 {
    return point_mod.pointToVec2(point);
}

/// `point` moved by `vec`. Upstream `Point::add` in `impl Add<Vec2> for Point` at
/// `accesskit/src/geometry.rs:257`, and the C declaration is
/// `include/zaccesskit.h:5473`. Both components are logical pixels.
export fn accesskit_point_add_vec2(point: Point, vec: Vec2) callconv(.c) Point {
    return point.addVec2(vec);
}

/// `point` moved back by `vec`. Upstream `Point::sub` in `impl Sub<Vec2> for
/// Point` at `accesskit/src/geometry.rs:273`, and the C declaration is
/// `include/zaccesskit.h:5479`. Both components are logical pixels.
export fn accesskit_point_sub_vec2(point: Point, vec: Vec2) callconv(.c) Point {
    return point.subVec2(vec);
}

/// The vector from `b` to `a`. Upstream `Point::sub` in `impl Sub<Point> for
/// Point` at `accesskit/src/geometry.rs:321`, and the C declaration is
/// `include/zaccesskit.h:5485`. Both components are logical pixels.
export fn accesskit_point_sub_point(a: Point, b: Point) callconv(.c) Vec2 {
    return a.subPoint(b);
}

// --- The rectangle -------------------------------------------------------------

/// The rectangle with the two given corners. Upstream `Rect::new` at
/// `accesskit/src/geometry.rs:403`, and the C declaration is
/// `include/zaccesskit.h:5491`. The four values are kept in the order they are
/// given, so an inverted box is a valid result and reports a negative `width`
/// or `height`. Use `accesskit_rect_from_points` for an ordered box.
export fn accesskit_rect_new(x0: f64, y0: f64, x1: f64, y1: f64) callconv(.c) Rect {
    return rect_mod.rectInit(x0, y0, x1, y1);
}

/// The smallest rectangle with `p0` and `p1` as corners. Upstream
/// `Rect::from_points` at `accesskit/src/geometry.rs:411`, and the C declaration
/// is `include/zaccesskit.h:5497`. The corners are ordered, so the result never
/// has a negative width or height.
export fn accesskit_rect_from_points(p0: Point, p1: Point) callconv(.c) Rect {
    return rect_mod.rectFromPoints(p0, p1);
}

/// The rectangle with `origin` as its top-left corner and `size` as its extent.
/// Upstream `Rect::from_origin_size` at `accesskit/src/geometry.rs:421`, and the
/// C declaration is `include/zaccesskit.h:5505`. A negative width or height in
/// `size` gives a negative extent, and the result is then inverted.
export fn accesskit_rect_from_origin_size(origin: Point, size: Size) callconv(.c) Rect {
    return rect_mod.rectFromOriginSize(origin, size);
}

/// `rect` moved so that `origin` is its top-left corner, with its size
/// unchanged. Upstream `Rect::with_origin` at `accesskit/src/geometry.rs:428`,
/// and the C declaration is `include/zaccesskit.h:5513`. The extent travels
/// with the value, so a negative extent in `rect` leaves the result inverted.
export fn accesskit_rect_with_origin(rect: Rect, origin: Point) callconv(.c) Rect {
    return rect.withOrigin(origin);
}

/// `rect` resized to `size` about its top-left corner. Upstream `Rect::with_size`
/// at `accesskit/src/geometry.rs:434`, and the C declaration is
/// `include/zaccesskit.h:5519`. The corner that stays put is the stored `x0`
/// and `y0`, not the minimum corner, so a negative extent in `size` leaves the
/// result inverted.
export fn accesskit_rect_with_size(rect: Rect, size: Size) callconv(.c) Rect {
    return rect.withSize(size);
}

/// The width of `rect` in logical pixels, which is `x1 - x0`. Upstream
/// `Rect::width` at `accesskit/src/geometry.rs:442`, and the C declaration is
/// `include/zaccesskit.h:5527`. `null` answers `0` rather than reading the
/// pointer. Nothing forbids a negative width.
export fn accesskit_rect_width(rect: ?*const Rect) callconv(.c) f64 {
    const value = rect orelse return 0.0;
    return value.width();
}

/// The height of `rect` in logical pixels, which is `y1 - y0`. Upstream
/// `Rect::height` at `accesskit/src/geometry.rs:450`, and the C declaration is
/// `include/zaccesskit.h:5534`. `null` answers `0` rather than reading the
/// pointer. Nothing forbids a negative height.
export fn accesskit_rect_height(rect: ?*const Rect) callconv(.c) f64 {
    const value = rect orelse return 0.0;
    return value.height();
}

/// The left edge of `rect` in logical pixels, which is the smaller of `x0` and
/// `x1`. Upstream `Rect::min_x` at `accesskit/src/geometry.rs:456`, and the C
/// declaration is `include/zaccesskit.h:5541`. `null` answers `0` rather than
/// reading the pointer.
export fn accesskit_rect_min_x(rect: ?*const Rect) callconv(.c) f64 {
    const value = rect orelse return 0.0;
    return value.minX();
}

/// The right edge of `rect` in logical pixels, which is the larger of `x0` and
/// `x1`. Upstream `Rect::max_x` at `accesskit/src/geometry.rs:462`, and the C
/// declaration is `include/zaccesskit.h:5548`. `null` answers `0` rather than
/// reading the pointer.
export fn accesskit_rect_max_x(rect: ?*const Rect) callconv(.c) f64 {
    const value = rect orelse return 0.0;
    return value.maxX();
}

/// The top edge of `rect` in logical pixels, which is the smaller of `y0` and
/// `y1`. Upstream `Rect::min_y` at `accesskit/src/geometry.rs:468`, and the C
/// declaration is `include/zaccesskit.h:5555`. `null` answers `0` rather than
/// reading the pointer.
export fn accesskit_rect_min_y(rect: ?*const Rect) callconv(.c) f64 {
    const value = rect orelse return 0.0;
    return value.minY();
}

/// The bottom edge of `rect` in logical pixels, which is the larger of `y0` and
/// `y1`. Upstream `Rect::max_y` at `accesskit/src/geometry.rs:474`, and the C
/// declaration is `include/zaccesskit.h:5562`. `null` answers `0` rather than
/// reading the pointer.
export fn accesskit_rect_max_y(rect: ?*const Rect) callconv(.c) f64 {
    const value = rect orelse return 0.0;
    return value.maxY();
}

/// The top-left corner of `rect` as a point, which is the stored `x0` and `y0`.
/// Upstream `Rect::origin` at `accesskit/src/geometry.rs:483`, and the C
/// declaration is `include/zaccesskit.h:5570`. This is the corner the box was
/// built with and not the minimum one, so it differs from
/// `accesskit_rect_min_x` and `accesskit_rect_min_y` on an inverted box. `null`
/// answers the point at the origin.
export fn accesskit_rect_origin(rect: ?*const Rect) callconv(.c) Point {
    const value = rect orelse return point_mod.point_origin;
    return value.topLeft();
}

/// The width and height of `rect` as a size. Upstream `Rect::size` at
/// `accesskit/src/geometry.rs:489`, and the C declaration is
/// `include/zaccesskit.h:5577`. Both are logical pixels, and both are signed, so
/// an inverted box reports a negative width or height. `null` answers the zero
/// size.
export fn accesskit_rect_size(rect: ?*const Rect) callconv(.c) Size {
    const value = rect orelse return size_mod.size_zero;
    return rect_mod.rectSize(value.*);
}

/// `rect` with every negative edge moved to the other side, so the result has no
/// negative width or height. Upstream `Rect::abs` at
/// `accesskit/src/geometry.rs:498`, and the C declaration is
/// `include/zaccesskit.h:5585`. The result has the same extents as the input.
/// `null` answers the zero rectangle.
export fn accesskit_rect_abs(rect: ?*const Rect) callconv(.c) Rect {
    const value = rect orelse return rect_mod.rect_zero;
    return value.abs();
}

/// The area of `rect` in squared logical pixels, which is the width times the
/// height. Upstream `Rect::area` at `accesskit/src/geometry.rs:505`, and the C
/// declaration is `include/zaccesskit.h:5592`. The sign follows the inversion, so
/// an inverted box reports a positive area. `null` answers `0` rather than
/// reading the pointer.
export fn accesskit_rect_area(rect: ?*const Rect) callconv(.c) f64 {
    const value = rect orelse return 0.0;
    return value.area();
}

/// Whether `rect` encloses no area, which is its area being exactly zero.
/// Upstream `Rect::is_empty` at `accesskit/src/geometry.rs:513`, and the C
/// declaration is `include/zaccesskit.h:5599`. A negative area is not emptiness,
/// so an inverted box with a non-zero area is not empty. `null` answers `true`,
/// because the zero rectangle encloses no area.
export fn accesskit_rect_is_empty(rect: ?*const Rect) callconv(.c) bool {
    const value = rect orelse return true;
    return value.isEmpty();
}

/// Whether `point` lies inside `rect`, with both far edges excluded. Upstream
/// `Rect::contains` at `accesskit/src/geometry.rs:519`, and the C declaration is
/// `include/zaccesskit.h:5606`. A zero-area box therefore claims no point, not
/// even a point on its own stored corner. `null` answers `false` rather than
/// reading the pointer.
export fn accesskit_rect_contains(rect: ?*const Rect, point: Point) callconv(.c) bool {
    const value = rect orelse return false;
    return value.contains(point);
}

/// The smallest rectangle holding both `rect` and `other`. Upstream `Rect::union`
/// at `accesskit/src/geometry.rs:527`, and the C declaration is
/// `include/zaccesskit.h:5614`. The result is valid only when both inputs have a
/// non-negative width and height, because nothing is normalised. `null` answers
/// the zero rectangle and ignores `other`.
export fn accesskit_rect_union(rect: ?*const Rect, other: Rect) callconv(.c) Rect {
    const value = rect orelse return rect_mod.rect_zero;
    return value.unionRect(other);
}

/// The smallest rectangle holding `rect` and `pt`. Upstream `Rect::union_pt` at
/// `accesskit/src/geometry.rs:543`, and the C declaration is
/// `include/zaccesskit.h:5623`. The perimeter of a zero-area box counts, so a
/// succession of these calls over a series of points encloses every one of
/// them. The result is valid only when `rect` has a non-negative width and
/// height. `null` answers the zero rectangle and ignores `pt`.
export fn accesskit_rect_union_pt(rect: ?*const Rect, pt: Point) callconv(.c) Rect {
    const value = rect orelse return rect_mod.rect_zero;
    return value.unionPoint(pt);
}

/// The overlap of `rect` and `other`. Upstream `Rect::intersect` at
/// `accesskit/src/geometry.rs:557`, and the C declaration is
/// `include/zaccesskit.h:5633`. The result always has a non-negative width and
/// height. Where the two do not overlap, the result is the zero-area rectangle
/// at the clamped near corner, so it is the zero rectangle at that corner and
/// not the zero rectangle at the origin. An input with a negative width or
/// height also gives a zero-area result. `null` answers the zero rectangle and
/// ignores `other`.
export fn accesskit_rect_intersect(rect: ?*const Rect, other: Rect) callconv(.c) Rect {
    const value = rect orelse return rect_mod.rect_zero;
    return value.intersect(other);
}

/// `rect` moved by `translation`, so it keeps its extents. Upstream `Rect::add`
/// in `impl Add<Vec2> for Rect` at `accesskit/src/geometry.rs:364`, and the C
/// declaration is `include/zaccesskit.h:5640`. All four corners move, and both
/// components of `translation` are logical pixels.
export fn accesskit_rect_translate(rect: Rect, translation: Vec2) callconv(.c) Rect {
    return rect.addVec2(translation);
}

// --- The size ------------------------------------------------------------------

/// `size` read as a vector, with the width as `x` and the height as `y`. Upstream
/// `Size::to_vec2` at `accesskit/src/geometry.rs:591`, and the C declaration is
/// `include/zaccesskit.h:5647`. Both types count logical pixels, so the reading
/// changes no unit.
export fn accesskit_size_to_vec2(size: Size) callconv(.c) Vec2 {
    return size_mod.sizeToVec2(size);
}

/// `size` with both dimensions multiplied by `scalar`. Upstream `Size::mul` in
/// `impl Mul<f64> for Size` at `accesskit/src/geometry.rs:625`, and the C
/// declaration is `include/zaccesskit.h:5652`. A negative `scalar` flips both
/// signs, and no value of it is rejected.
export fn accesskit_size_scale(size: Size, scalar: f64) callconv(.c) Size {
    return size.scale(scalar);
}

/// The size that adds `a` to `b` dimension by dimension. Upstream `Size::add` in
/// `impl Add<Size> for Size` at `accesskit/src/geometry.rs:658`, and the C
/// declaration is `include/zaccesskit.h:5658`. Both dimensions are logical
/// pixels.
export fn accesskit_size_add(a: Size, b: Size) callconv(.c) Size {
    return a.add(b);
}

/// The size that subtracts `b` from `a` dimension by dimension. Upstream
/// `Size::sub` in `impl Sub<Size> for Size` at `accesskit/src/geometry.rs:676`,
/// and the C declaration is `include/zaccesskit.h:5664`. Both dimensions are
/// logical pixels.
export fn accesskit_size_sub(a: Size, b: Size) callconv(.c) Size {
    return a.sub(b);
}

// --- The vector ---------------------------------------------------------------

/// The vector read as a point. Upstream `Vec2::to_point` at
/// `accesskit/src/geometry.rs:736`, and the C declaration is
/// `include/zaccesskit.h:5670`. Both components are copied unchanged, so the
/// reading is exact and loses no precision.
export fn accesskit_vec2_to_point(vec2: Vec2) callconv(.c) Point {
    return vec2_mod.vec2ToPoint(vec2);
}

/// The vector read as a size, with `x` as the width and `y` as the height.
/// Upstream `Vec2::to_size` at `accesskit/src/geometry.rs:742`, and the C
/// declaration is `include/zaccesskit.h:5675`. Both components are copied
/// unchanged.
export fn accesskit_vec2_to_size(vec2: Vec2) callconv(.c) Size {
    return vec2_mod.vec2ToSize(vec2);
}

/// The vector that adds `a` to `b`. Upstream `Vec2::add` in `impl Add for Vec2`
/// at `accesskit/src/geometry.rs:765`, and the C declaration is
/// `include/zaccesskit.h:5680`. Both components are logical pixels.
export fn accesskit_vec2_add(a: Vec2, b: Vec2) callconv(.c) Vec2 {
    return a.add(b);
}

/// The vector that subtracts `b` from `a`. Upstream `Vec2::sub` in `impl Sub for
/// Vec2` at `accesskit/src/geometry.rs:787`, and the C declaration is
/// `include/zaccesskit.h:5686`. Both components are logical pixels.
export fn accesskit_vec2_sub(a: Vec2, b: Vec2) callconv(.c) Vec2 {
    return a.sub(b);
}

/// `vec` multiplied by `scalar`. Upstream `Vec2::mul` in `impl Mul<f64> for Vec2`
/// at `accesskit/src/geometry.rs:809`, and the C declaration is
/// `include/zaccesskit.h:5692`. A negative `scalar` flips both signs, and no
/// value of it is rejected.
export fn accesskit_vec2_scale(vec: Vec2, scalar: f64) callconv(.c) Vec2 {
    return vec.scale(scalar);
}

/// `vec` with both components negated. Upstream `Vec2::neg` in `impl Neg for
/// Vec2` at `accesskit/src/geometry.rs:860`, and the C declaration is
/// `include/zaccesskit.h:5698`. Both components are logical pixels.
export fn accesskit_vec2_neg(vec: Vec2) callconv(.c) Vec2 {
    return vec.negate();
}

// --- The header forms, and the round trip ---------------------------------------
//
// The five mirrors below are second `extern struct` types, not aliases. A round
// trip is only a proof of the layout when the two sides are two types, because
// an alias would make the test compare a value with itself and pass whatever
// the layout was. The mirrors carry the header's own field names, so
// `accesskit_affine` spells its array `_0` and the Zig type spells it `coeffs`.
//
// These five types and the ten functions that convert between them exist for
// the tests below. The 49 exports do not use them, because the Zig types and
// the header types are the same `extern struct` and the conversion is an
// identity.

/// `struct accesskit_affine` as `include/zaccesskit.h:1440-1442` declares it.
const CAffine = extern struct {
    /// `double _0[6];`
    _0: [6]f64,
};

/// `struct accesskit_rect` as `include/zaccesskit.h:1451-1456` declares it.
const CRect = extern struct {
    /// `double x0;`
    x0: f64,
    /// `double y0;`
    y0: f64,
    /// `double x1;`
    x1: f64,
    /// `double y1;`
    y1: f64,
};

/// `struct accesskit_point` as `include/zaccesskit.h:1533-1536` declares it.
const CPoint = extern struct {
    /// `double x;`
    x: f64,
    /// `double y;`
    y: f64,
};

/// `struct accesskit_vec2` as `include/zaccesskit.h:1545-1548` declares it.
const CVec2 = extern struct {
    /// `double x;`
    x: f64,
    /// `double y;`
    y: f64,
};

/// `struct accesskit_size` as `include/zaccesskit.h:1557-1560` declares it.
const CSize = extern struct {
    /// `double width;`
    width: f64,
    /// `double height;`
    height: f64,
};

/// The header form of an `Affine`, coefficient for coefficient.
fn affineToC(value: Affine) CAffine {
    return .{ ._0 = value.coeffs };
}

/// The Zig form of a header `Affine`, coefficient for coefficient.
fn affineFromC(value: CAffine) Affine {
    return .{ .coeffs = value._0 };
}

/// The header form of a `Rect`, field for field in the header's order.
fn rectToC(value: Rect) CRect {
    return .{ .x0 = value.x0, .y0 = value.y0, .x1 = value.x1, .y1 = value.y1 };
}

/// The Zig form of a header `Rect`, field for field in the header's order.
fn rectFromC(value: CRect) Rect {
    return .{ .x0 = value.x0, .y0 = value.y0, .x1 = value.x1, .y1 = value.y1 };
}

/// The header form of a `Point`, field for field.
fn pointToC(value: Point) CPoint {
    return .{ .x = value.x, .y = value.y };
}

/// The Zig form of a header `Point`, field for field.
fn pointFromC(value: CPoint) Point {
    return .{ .x = value.x, .y = value.y };
}

/// The header form of a `Vec2`, field for field.
fn vec2ToC(value: Vec2) CVec2 {
    return .{ .x = value.x, .y = value.y };
}

/// The Zig form of a header `Vec2`, field for field.
fn vec2FromC(value: CVec2) Vec2 {
    return .{ .x = value.x, .y = value.y };
}

/// The header form of a `Size`, field for field.
fn sizeToC(value: Size) CSize {
    return .{ .width = value.width, .height = value.height };
}

/// The Zig form of a header `Size`, field for field.
fn sizeFromC(value: CSize) Size {
    return .{ .width = value.width, .height = value.height };
}

/// The `f64` that starts at `offset` of `bytes`, in the host's own byte order.
/// The tests pass a comptime offset inside a slice they sized, so the read is in
/// range by construction and the byte order cancels out.
fn readF64At(comptime offset: usize, bytes: []const u8) f64 {
    const chunk: *align(1) const f64 = @ptrCast(bytes[offset..].ptr);
    return chunk.*;
}

const testing = std.testing;

// --- The layout ---------------------------------------------------------------

test "the affine coefficients sit at offset 0 as one double[6]" {
    const value = affine_mod.affineNew(.{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 });
    const bytes = std.mem.asBytes(&value);
    try testing.expectEqual(@as(usize, 48), bytes.len);
    try testing.expectEqual(@as(f64, 1.0), readF64At(0, bytes));
    try testing.expectEqual(@as(f64, 2.0), readF64At(8, bytes));
    try testing.expectEqual(@as(f64, 3.0), readF64At(16, bytes));
    try testing.expectEqual(@as(f64, 4.0), readF64At(24, bytes));
    try testing.expectEqual(@as(f64, 5.0), readF64At(32, bytes));
    try testing.expectEqual(@as(f64, 6.0), readF64At(40, bytes));
}

test "the rect fields sit at 0, 8, 16 and 24 as x0, y0, x1, y1" {
    const value = rect_mod.rectInit(-0.5, 1.25, 8.0, -16.75);
    const bytes = std.mem.asBytes(&value);
    try testing.expectEqual(@as(usize, 32), bytes.len);
    try testing.expectEqual(@as(f64, -0.5), readF64At(0, bytes));
    try testing.expectEqual(@as(f64, 1.25), readF64At(8, bytes));
    try testing.expectEqual(@as(f64, 8.0), readF64At(16, bytes));
    try testing.expectEqual(@as(f64, -16.75), readF64At(24, bytes));
}

test "the point fields sit at 0 and 8 as x then y" {
    const value = point_mod.pointInit(3.5, -4.25);
    const bytes = std.mem.asBytes(&value);
    try testing.expectEqual(@as(usize, 16), bytes.len);
    try testing.expectEqual(@as(f64, 3.5), readF64At(0, bytes));
    try testing.expectEqual(@as(f64, -4.25), readF64At(8, bytes));
}

test "the vec2 fields sit at 0 and 8 as x then y" {
    const value = vec2_mod.vec2Init(-1.0, 2.0);
    const bytes = std.mem.asBytes(&value);
    try testing.expectEqual(@as(usize, 16), bytes.len);
    try testing.expectEqual(@as(f64, -1.0), readF64At(0, bytes));
    try testing.expectEqual(@as(f64, 2.0), readF64At(8, bytes));
}

test "the size fields sit at 0 and 8 as width then height" {
    const value = size_mod.sizeInit(1024.5, -768.25);
    const bytes = std.mem.asBytes(&value);
    try testing.expectEqual(@as(usize, 16), bytes.len);
    try testing.expectEqual(@as(f64, 1024.5), readF64At(0, bytes));
    try testing.expectEqual(@as(f64, -768.25), readF64At(8, bytes));
}

// --- The round trip, both ways -------------------------------------------------

test "an affine crosses to the header form and back without losing a byte" {
    const zig_value = affine_mod.affineNew(.{ 1.5, -2.25, 0.0, 4.0, -5.5, 6.75 });
    const c_value = affineToC(zig_value);
    try testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&zig_value),
        std.mem.asBytes(&c_value),
    );
    const back = affineFromC(c_value);
    try testing.expectEqual(@as(f64, 1.5), back.coeffs[0]);
    try testing.expectEqual(@as(f64, -2.25), back.coeffs[1]);
    try testing.expectEqual(@as(f64, 0.0), back.coeffs[2]);
    try testing.expectEqual(@as(f64, 4.0), back.coeffs[3]);
    try testing.expectEqual(@as(f64, -5.5), back.coeffs[4]);
    try testing.expectEqual(@as(f64, 6.75), back.coeffs[5]);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&zig_value), std.mem.asBytes(&back));
}

test "an affine carries a NaN coefficient across the round trip unchanged" {
    // A NaN is not equal to itself, so an equality assertion cannot see one
    // survive. The byte comparison is what settles it.
    const zig_value = affine_mod.affineNew(.{ std.math.nan(f64), 0.0, 0.0, 1.0, 0.0, 0.0 });
    const c_value = affineToC(zig_value);
    try testing.expect(std.math.isNan(c_value._0[0]));
    const back = affineFromC(c_value);
    try testing.expect(std.math.isNan(back.coeffs[0]));
    try testing.expectEqualSlices(u8, std.mem.asBytes(&zig_value), std.mem.asBytes(&back));
}

test "a rect crosses to the header form and back without losing a byte" {
    const zig_value = rect_mod.rectInit(-0.5, 1.25, 8.0, -16.75);
    const c_value = rectToC(zig_value);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&zig_value), std.mem.asBytes(&c_value));
    const back = rectFromC(c_value);
    try testing.expectEqual(@as(f64, -0.5), back.x0);
    try testing.expectEqual(@as(f64, 1.25), back.y0);
    try testing.expectEqual(@as(f64, 8.0), back.x1);
    try testing.expectEqual(@as(f64, -16.75), back.y1);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&zig_value), std.mem.asBytes(&back));
}

test "a point crosses to the header form and back without losing a byte" {
    const zig_value = point_mod.pointInit(3.5, -4.25);
    const c_value = pointToC(zig_value);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&zig_value), std.mem.asBytes(&c_value));
    const back = pointFromC(c_value);
    try testing.expectEqual(@as(f64, 3.5), back.x);
    try testing.expectEqual(@as(f64, -4.25), back.y);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&zig_value), std.mem.asBytes(&back));
}

test "a vec2 crosses to the header form and back without losing a byte" {
    const zig_value = vec2_mod.vec2Init(-1.0, 2.0);
    const c_value = vec2ToC(zig_value);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&zig_value), std.mem.asBytes(&c_value));
    const back = vec2FromC(c_value);
    try testing.expectEqual(@as(f64, -1.0), back.x);
    try testing.expectEqual(@as(f64, 2.0), back.y);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&zig_value), std.mem.asBytes(&back));
}

test "a size crosses to the header form and back without losing a byte" {
    const zig_value = size_mod.sizeInit(1024.5, -768.25);
    const c_value = sizeToC(zig_value);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&zig_value), std.mem.asBytes(&c_value));
    const back = sizeFromC(c_value);
    try testing.expectEqual(@as(f64, 1024.5), back.width);
    try testing.expectEqual(@as(f64, -768.25), back.height);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&zig_value), std.mem.asBytes(&back));
}

test "a point and a vec2 of the same numbers are the same sixteen bytes" {
    // The header declares both as two `double`, and the two types differ only in
    // what they mean. A port that gave one of them a different layout would pass
    // every per-type test above and break here.
    const as_point = accesskit_point_to_vec2(.{ .x = 7.0, .y = -8.0 });
    const as_vec2 = accesskit_vec2_scale(.{ .x = 7.0, .y = -8.0 }, 1.0);
    const point_bytes = std.mem.asBytes(&as_point);
    const vec2_bytes = std.mem.asBytes(&as_vec2);
    try testing.expectEqualSlices(u8, point_bytes, vec2_bytes);
}

test "a rect returned by the C entry point is the bytes the caller wrote" {
    // The round trip through the exported surface, not through a helper. A C
    // caller writes four doubles and reads four doubles, and this says the two
    // sets are the same set in the same order.
    const written: Rect = .{ .x0 = 11.0, .y0 = 22.0, .x1 = 33.0, .y1 = 44.0 };
    const result = accesskit_rect_abs(&written);
    const c_result = rectToC(result);
    try testing.expectEqual(@as(f64, 11.0), c_result.x0);
    try testing.expectEqual(@as(f64, 22.0), c_result.y0);
    try testing.expectEqual(@as(f64, 33.0), c_result.x1);
    try testing.expectEqual(@as(f64, 44.0), c_result.y1);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&written), std.mem.asBytes(&c_result));
}

// --- The signatures ------------------------------------------------------------

/// One row per geometry declaration: the C symbol, the export, and the
/// signature `include/zaccesskit.h:5374-5698` gives it.
///
/// The bound on the sweep below is `export_signatures.len`, which is 49, one
/// row per declaration. Each row is a comptime-known tuple, so the sweep
/// visits exactly those 49 and nothing else.
const export_signatures = .{
    .{ "accesskit_affine_identity", accesskit_affine_identity, fn () callconv(.c) Affine },
    .{ "accesskit_affine_flip_y", accesskit_affine_flip_y, fn () callconv(.c) Affine },
    .{ "accesskit_affine_flip_x", accesskit_affine_flip_x, fn () callconv(.c) Affine },
    .{ "accesskit_affine_scale", accesskit_affine_scale, fn (f64) callconv(.c) Affine },
    .{
        "accesskit_affine_scale_non_uniform",
        accesskit_affine_scale_non_uniform,
        fn (f64, f64) callconv(.c) Affine,
    },
    .{
        "accesskit_affine_translate",
        accesskit_affine_translate,
        fn (Vec2) callconv(.c) Affine,
    },
    .{
        "accesskit_affine_map_unit_square",
        accesskit_affine_map_unit_square,
        fn (Rect) callconv(.c) Affine,
    },
    .{
        "accesskit_affine_determinant",
        accesskit_affine_determinant,
        fn (Affine) callconv(.c) f64,
    },
    .{ "accesskit_affine_inverse", accesskit_affine_inverse, fn (Affine) callconv(.c) Affine },
    .{
        "accesskit_affine_transform_rect_bbox",
        accesskit_affine_transform_rect_bbox,
        fn (Affine, Rect) callconv(.c) Rect,
    },
    .{
        "accesskit_affine_is_finite",
        accesskit_affine_is_finite,
        fn (?*const Affine) callconv(.c) bool,
    },
    .{
        "accesskit_affine_is_nan",
        accesskit_affine_is_nan,
        fn (?*const Affine) callconv(.c) bool,
    },
    .{ "accesskit_affine_mul", accesskit_affine_mul, fn (Affine, Affine) callconv(.c) Affine },
    .{
        "accesskit_affine_transform_point",
        accesskit_affine_transform_point,
        fn (Affine, Point) callconv(.c) Point,
    },
    .{ "accesskit_point_to_vec2", accesskit_point_to_vec2, fn (Point) callconv(.c) Vec2 },
    .{
        "accesskit_point_add_vec2",
        accesskit_point_add_vec2,
        fn (Point, Vec2) callconv(.c) Point,
    },
    .{
        "accesskit_point_sub_vec2",
        accesskit_point_sub_vec2,
        fn (Point, Vec2) callconv(.c) Point,
    },
    .{
        "accesskit_point_sub_point",
        accesskit_point_sub_point,
        fn (Point, Point) callconv(.c) Vec2,
    },
    .{ "accesskit_rect_new", accesskit_rect_new, fn (f64, f64, f64, f64) callconv(.c) Rect },
    .{
        "accesskit_rect_from_points",
        accesskit_rect_from_points,
        fn (Point, Point) callconv(.c) Rect,
    },
    .{
        "accesskit_rect_from_origin_size",
        accesskit_rect_from_origin_size,
        fn (Point, Size) callconv(.c) Rect,
    },
    .{
        "accesskit_rect_with_origin",
        accesskit_rect_with_origin,
        fn (Rect, Point) callconv(.c) Rect,
    },
    .{
        "accesskit_rect_with_size",
        accesskit_rect_with_size,
        fn (Rect, Size) callconv(.c) Rect,
    },
    .{ "accesskit_rect_width", accesskit_rect_width, fn (?*const Rect) callconv(.c) f64 },
    .{ "accesskit_rect_height", accesskit_rect_height, fn (?*const Rect) callconv(.c) f64 },
    .{ "accesskit_rect_min_x", accesskit_rect_min_x, fn (?*const Rect) callconv(.c) f64 },
    .{ "accesskit_rect_max_x", accesskit_rect_max_x, fn (?*const Rect) callconv(.c) f64 },
    .{ "accesskit_rect_min_y", accesskit_rect_min_y, fn (?*const Rect) callconv(.c) f64 },
    .{ "accesskit_rect_max_y", accesskit_rect_max_y, fn (?*const Rect) callconv(.c) f64 },
    .{ "accesskit_rect_origin", accesskit_rect_origin, fn (?*const Rect) callconv(.c) Point },
    .{ "accesskit_rect_size", accesskit_rect_size, fn (?*const Rect) callconv(.c) Size },
    .{ "accesskit_rect_abs", accesskit_rect_abs, fn (?*const Rect) callconv(.c) Rect },
    .{ "accesskit_rect_area", accesskit_rect_area, fn (?*const Rect) callconv(.c) f64 },
    .{
        "accesskit_rect_is_empty",
        accesskit_rect_is_empty,
        fn (?*const Rect) callconv(.c) bool,
    },
    .{
        "accesskit_rect_contains",
        accesskit_rect_contains,
        fn (?*const Rect, Point) callconv(.c) bool,
    },
    .{
        "accesskit_rect_union",
        accesskit_rect_union,
        fn (?*const Rect, Rect) callconv(.c) Rect,
    },
    .{
        "accesskit_rect_union_pt",
        accesskit_rect_union_pt,
        fn (?*const Rect, Point) callconv(.c) Rect,
    },
    .{
        "accesskit_rect_intersect",
        accesskit_rect_intersect,
        fn (?*const Rect, Rect) callconv(.c) Rect,
    },
    .{
        "accesskit_rect_translate",
        accesskit_rect_translate,
        fn (Rect, Vec2) callconv(.c) Rect,
    },
    .{ "accesskit_size_to_vec2", accesskit_size_to_vec2, fn (Size) callconv(.c) Vec2 },
    .{ "accesskit_size_scale", accesskit_size_scale, fn (Size, f64) callconv(.c) Size },
    .{ "accesskit_size_add", accesskit_size_add, fn (Size, Size) callconv(.c) Size },
    .{ "accesskit_size_sub", accesskit_size_sub, fn (Size, Size) callconv(.c) Size },
    .{ "accesskit_vec2_to_point", accesskit_vec2_to_point, fn (Vec2) callconv(.c) Point },
    .{ "accesskit_vec2_to_size", accesskit_vec2_to_size, fn (Vec2) callconv(.c) Size },
    .{ "accesskit_vec2_add", accesskit_vec2_add, fn (Vec2, Vec2) callconv(.c) Vec2 },
    .{ "accesskit_vec2_sub", accesskit_vec2_sub, fn (Vec2, Vec2) callconv(.c) Vec2 },
    .{ "accesskit_vec2_scale", accesskit_vec2_scale, fn (Vec2, f64) callconv(.c) Vec2 },
    .{ "accesskit_vec2_neg", accesskit_vec2_neg, fn (Vec2) callconv(.c) Vec2 },
};

comptime {
    // A signature that drifts from the header is a build failure and not a run
    // that returns a wrong number. A transform whose result became a `Point`
    // where the header declares `void`, a pointer where the header declares a
    // value, and a dropped parameter are all caught here.
    for (export_signatures, 0..) |row, index| {
        if (@TypeOf(row[1]) != row[2]) {
            @compileError("geometry export signature does not match " ++
                "include/zaccesskit.h: " ++ std.fmt.comptimePrint("{d}", .{index}));
        }
    }
}

/// The rows whose C symbol starts with `prefix`.
///
/// The bound is `export_signatures.len`, which is 49.
fn countFamily(prefix: []const u8) usize {
    var count: usize = 0;
    inline for (export_signatures) |row| {
        if (std.mem.startsWith(u8, row[0], prefix)) count += 1;
    }
    return count;
}

test "the signature table names all 49 geometry declarations by family" {
    // The `comptime` block above is the per-row type check. This is the census:
    // a declaration added to this module without a row, and a row added for a
    // declaration that is not there, each move one of these six numbers.
    try testing.expectEqual(@as(usize, 49), export_signatures.len);
    try testing.expectEqual(@as(usize, 14), countFamily("accesskit_affine_"));
    try testing.expectEqual(@as(usize, 21), countFamily("accesskit_rect_"));
    try testing.expectEqual(@as(usize, 4), countFamily("accesskit_point_"));
    try testing.expectEqual(@as(usize, 4), countFamily("accesskit_size_"));
    try testing.expectEqual(@as(usize, 6), countFamily("accesskit_vec2_"));
}

// --- The behaviour, one group per type ----------------------------------------

test "identity leaves a point where it is" {
    const identity = accesskit_affine_identity();
    try testing.expectEqual(@as(f64, 1.0), identity.coeffs[0]);
    try testing.expectEqual(@as(f64, 0.0), identity.coeffs[1]);
    try testing.expectEqual(@as(f64, 0.0), identity.coeffs[2]);
    try testing.expectEqual(@as(f64, 1.0), identity.coeffs[3]);
    try testing.expectEqual(@as(f64, 0.0), identity.coeffs[4]);
    try testing.expectEqual(@as(f64, 0.0), identity.coeffs[5]);
    const moved = accesskit_affine_transform_point(identity, .{ .x = 3.0, .y = 7.0 });
    try testing.expectEqual(@as(f64, 3.0), moved.x);
    try testing.expectEqual(@as(f64, 7.0), moved.y);
}

test "flip_y mirrors across the x axis and flip_x across the y axis" {
    const where: Point = .{ .x = 2.0, .y = 5.0 };
    const over_x = accesskit_affine_transform_point(accesskit_affine_flip_y(), where);
    try testing.expectEqual(@as(f64, 2.0), over_x.x);
    try testing.expectEqual(@as(f64, -5.0), over_x.y);
    const over_y = accesskit_affine_transform_point(accesskit_affine_flip_x(), where);
    try testing.expectEqual(@as(f64, -2.0), over_y.x);
    try testing.expectEqual(@as(f64, 5.0), over_y.y);
}

test "scale multiplies both coordinates and scales area by its square" {
    const scaled = accesskit_affine_transform_point(
        accesskit_affine_scale(3.0),
        .{ .x = 2.0, .y = 5.0 },
    );
    try testing.expectEqual(@as(f64, 6.0), scaled.x);
    try testing.expectEqual(@as(f64, 15.0), scaled.y);
    try testing.expectEqual(
        @as(f64, 9.0),
        accesskit_affine_determinant(accesskit_affine_scale(3.0)),
    );
}

test "scale_non_uniform puts s_x on the x axis and s_y on the y axis" {
    const transform = accesskit_affine_scale_non_uniform(2.0, 10.0);
    try testing.expectEqual(@as(f64, 2.0), transform.coeffs[0]);
    try testing.expectEqual(@as(f64, 10.0), transform.coeffs[3]);
    const scaled = accesskit_affine_transform_point(transform, .{ .x = 2.0, .y = 5.0 });
    try testing.expectEqual(@as(f64, 4.0), scaled.x);
    try testing.expectEqual(@as(f64, 50.0), scaled.y);
    try testing.expectEqual(@as(f64, 20.0), accesskit_affine_determinant(transform));
}

test "translate moves every point by the vector and keeps unit scale" {
    const transform = accesskit_affine_translate(.{ .x = 3.0, .y = 4.0 });
    const moved = accesskit_affine_transform_point(transform, .{ .x = 1.0, .y = 1.0 });
    try testing.expectEqual(@as(f64, 4.0), moved.x);
    try testing.expectEqual(@as(f64, 5.0), moved.y);
    try testing.expectEqual(@as(f64, 1.0), accesskit_affine_determinant(transform));
}

test "map_unit_square carries the width, the height and the near corner" {
    const transform = accesskit_affine_map_unit_square(accesskit_rect_new(2.0, 3.0, 12.0, 8.0));
    try testing.expectEqual(@as(f64, 10.0), transform.coeffs[0]);
    try testing.expectEqual(@as(f64, 0.0), transform.coeffs[1]);
    try testing.expectEqual(@as(f64, 0.0), transform.coeffs[2]);
    try testing.expectEqual(@as(f64, 5.0), transform.coeffs[3]);
    try testing.expectEqual(@as(f64, 2.0), transform.coeffs[4]);
    try testing.expectEqual(@as(f64, 3.0), transform.coeffs[5]);
    const far_corner = accesskit_affine_transform_point(transform, .{ .x = 1.0, .y = 1.0 });
    try testing.expectEqual(@as(f64, 12.0), far_corner.x);
    try testing.expectEqual(@as(f64, 8.0), far_corner.y);
}

test "determinant is a times d minus c times b" {
    const general = affine_mod.affineNew(.{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 });
    try testing.expectEqual(@as(f64, -2.0), accesskit_affine_determinant(general));
    try testing.expectEqual(
        @as(f64, 1.0),
        accesskit_affine_determinant(accesskit_affine_identity()),
    );
}

test "inverse undoes the transform it came from" {
    const original = accesskit_affine_scale_non_uniform(2.0, 4.0);
    const undo = accesskit_affine_inverse(original);
    const start: Point = .{ .x = 5.0, .y = -6.0 };
    const there = accesskit_affine_transform_point(original, start);
    try testing.expectEqual(@as(f64, 10.0), there.x);
    try testing.expectEqual(@as(f64, -24.0), there.y);
    const back = accesskit_affine_transform_point(undo, there);
    try testing.expectEqual(@as(f64, 5.0), back.x);
    try testing.expectEqual(@as(f64, -6.0), back.y);
}

test "inverse of a singular transform holds values that are not finite" {
    const undo = accesskit_affine_inverse(accesskit_affine_scale(0.0));
    try testing.expect(!accesskit_affine_is_finite(&undo));
    try testing.expect(accesskit_affine_is_nan(&undo));
}

test "is_finite and is_nan separate an infinity from a NaN and answer null with false" {
    try testing.expect(!accesskit_affine_is_finite(null));
    try testing.expect(!accesskit_affine_is_nan(null));
    const infinite = affine_mod.affineNew(.{ 1.0, 0.0, 0.0, 1.0, 0.0, std.math.inf(f64) });
    try testing.expect(!accesskit_affine_is_finite(&infinite));
    try testing.expect(!accesskit_affine_is_nan(&infinite));
    const not_a_number = affine_mod.affineNew(.{ 1.0, 0.0, 0.0, 1.0, std.math.nan(f64), 0.0 });
    try testing.expect(!accesskit_affine_is_finite(&not_a_number));
    try testing.expect(accesskit_affine_is_nan(&not_a_number));
}

test "transform_rect_bbox encloses the four transformed corners" {
    const rect = accesskit_rect_new(1.0, 2.0, 5.0, 6.0);
    const unchanged = accesskit_affine_transform_rect_bbox(accesskit_affine_identity(), rect);
    try testing.expectEqual(@as(f64, 1.0), unchanged.x0);
    try testing.expectEqual(@as(f64, 2.0), unchanged.y0);
    try testing.expectEqual(@as(f64, 5.0), unchanged.x1);
    try testing.expectEqual(@as(f64, 6.0), unchanged.y1);

    const doubled = accesskit_affine_transform_rect_bbox(accesskit_affine_scale(2.0), rect);
    try testing.expectEqual(@as(f64, 2.0), doubled.x0);
    try testing.expectEqual(@as(f64, 4.0), doubled.y0);
    try testing.expectEqual(@as(f64, 10.0), doubled.x1);
    try testing.expectEqual(@as(f64, 12.0), doubled.y1);

    const mirrored = accesskit_affine_transform_rect_bbox(accesskit_affine_flip_y(), rect);
    try testing.expectEqual(@as(f64, 1.0), mirrored.x0);
    try testing.expectEqual(@as(f64, -6.0), mirrored.y0);
    try testing.expectEqual(@as(f64, 5.0), mirrored.x1);
    try testing.expectEqual(@as(f64, -2.0), mirrored.y1);
}

test "mul composes so that the right-hand transform applies first" {
    // Upstream states `mulPoint(mul(a, b), p)` equalling
    // `mulPoint(a, mulPoint(b, p))`, so the right-hand transform is the one
    // that applies first. Translating by (3, 4) and then scaling by two sends
    // the origin to (6, 8); the other order sends it to (3, 4). This pair of
    // assertions is what tells the two orders apart.
    const scaled_after = accesskit_affine_mul(
        accesskit_affine_scale(2.0),
        accesskit_affine_translate(.{ .x = 3.0, .y = 4.0 }),
    );
    const first = accesskit_affine_transform_point(scaled_after, .{ .x = 0.0, .y = 0.0 });
    try testing.expectEqual(@as(f64, 6.0), first.x);
    try testing.expectEqual(@as(f64, 8.0), first.y);

    const translated_after = accesskit_affine_mul(
        accesskit_affine_translate(.{ .x = 3.0, .y = 4.0 }),
        accesskit_affine_scale(2.0),
    );
    const second = accesskit_affine_transform_point(translated_after, .{ .x = 0.0, .y = 0.0 });
    try testing.expectEqual(@as(f64, 3.0), second.x);
    try testing.expectEqual(@as(f64, 4.0), second.y);
}

test "point_to_vec2 keeps both numbers" {
    const read = accesskit_point_to_vec2(.{ .x = 3.5, .y = -4.25 });
    try testing.expectEqual(@as(f64, 3.5), read.x);
    try testing.expectEqual(@as(f64, -4.25), read.y);
}

test "point_add_vec2 moves forward and point_sub_vec2 moves back" {
    const start: Point = .{ .x = 10.0, .y = 20.0 };
    const offset: Vec2 = .{ .x = 1.5, .y = -2.5 };
    const forward = accesskit_point_add_vec2(start, offset);
    try testing.expectEqual(@as(f64, 11.5), forward.x);
    try testing.expectEqual(@as(f64, 17.5), forward.y);
    const back = accesskit_point_sub_vec2(forward, offset);
    try testing.expectEqual(@as(f64, 10.0), back.x);
    try testing.expectEqual(@as(f64, 20.0), back.y);
}

test "point_sub_point answers the vector from b to a" {
    const from_b_to_a = accesskit_point_sub_point(
        .{ .x = 10.0, .y = 20.0 },
        .{ .x = 4.0, .y = 5.0 },
    );
    try testing.expectEqual(@as(f64, 6.0), from_b_to_a.x);
    try testing.expectEqual(@as(f64, 15.0), from_b_to_a.y);
}

test "rect_new keeps the four corners in the order it is given" {
    const inverted = accesskit_rect_new(9.0, 8.0, 2.0, 1.0);
    try testing.expectEqual(@as(f64, 9.0), inverted.x0);
    try testing.expectEqual(@as(f64, 8.0), inverted.y0);
    try testing.expectEqual(@as(f64, 2.0), inverted.x1);
    try testing.expectEqual(@as(f64, 1.0), inverted.y1);
    try testing.expectEqual(@as(f64, -7.0), accesskit_rect_width(&inverted));
    try testing.expectEqual(@as(f64, -7.0), accesskit_rect_height(&inverted));
}

test "rect_from_points orders the corners whichever order they arrive in" {
    const forward = accesskit_rect_from_points(.{ .x = 1.0, .y = 2.0 }, .{ .x = 5.0, .y = 6.0 });
    try testing.expectEqual(@as(f64, 1.0), forward.x0);
    try testing.expectEqual(@as(f64, 2.0), forward.y0);
    try testing.expectEqual(@as(f64, 5.0), forward.x1);
    try testing.expectEqual(@as(f64, 6.0), forward.y1);
    const reversed = accesskit_rect_from_points(.{ .x = 5.0, .y = 6.0 }, .{ .x = 1.0, .y = 2.0 });
    try testing.expectEqual(@as(f64, 1.0), reversed.x0);
    try testing.expectEqual(@as(f64, 6.0), reversed.y1);
    try testing.expectEqual(@as(f64, 4.0), accesskit_rect_width(&reversed));
}

test "rect_from_origin_size puts the extent on the far corner" {
    const rect = accesskit_rect_from_origin_size(
        .{ .x = 2.0, .y = 3.0 },
        .{ .width = 10.0, .height = 5.0 },
    );
    try testing.expectEqual(@as(f64, 2.0), rect.x0);
    try testing.expectEqual(@as(f64, 3.0), rect.y0);
    try testing.expectEqual(@as(f64, 12.0), rect.x1);
    try testing.expectEqual(@as(f64, 8.0), rect.y1);
}

test "rect_with_origin moves the corner and keeps the extent" {
    const moved = accesskit_rect_with_origin(
        accesskit_rect_new(1.0, 1.0, 5.0, 4.0),
        .{ .x = 100.0, .y = 200.0 },
    );
    try testing.expectEqual(@as(f64, 100.0), moved.x0);
    try testing.expectEqual(@as(f64, 200.0), moved.y0);
    try testing.expectEqual(@as(f64, 104.0), moved.x1);
    try testing.expectEqual(@as(f64, 203.0), moved.y1);
    try testing.expectEqual(@as(f64, 4.0), accesskit_rect_width(&moved));
}

test "rect_with_size keeps the stored corner and takes the new extent" {
    const resized = accesskit_rect_with_size(
        accesskit_rect_new(1.0, 2.0, 5.0, 6.0),
        .{ .width = 20.0, .height = 10.0 },
    );
    try testing.expectEqual(@as(f64, 1.0), resized.x0);
    try testing.expectEqual(@as(f64, 2.0), resized.y0);
    try testing.expectEqual(@as(f64, 21.0), resized.x1);
    try testing.expectEqual(@as(f64, 12.0), resized.y1);
}

test "the six edge readers take the minimum and the maximum on an inverted box" {
    const inverted = accesskit_rect_new(9.0, 8.0, 2.0, 1.0);
    try testing.expectEqual(@as(f64, 2.0), accesskit_rect_min_x(&inverted));
    try testing.expectEqual(@as(f64, 9.0), accesskit_rect_max_x(&inverted));
    try testing.expectEqual(@as(f64, 1.0), accesskit_rect_min_y(&inverted));
    try testing.expectEqual(@as(f64, 8.0), accesskit_rect_max_y(&inverted));
}

test "rect_origin is the stored corner and rect_size carries the sign" {
    const inverted = accesskit_rect_new(9.0, 8.0, 2.0, 1.0);
    const corner = accesskit_rect_origin(&inverted);
    try testing.expectEqual(@as(f64, 9.0), corner.x);
    try testing.expectEqual(@as(f64, 8.0), corner.y);
    const extent = accesskit_rect_size(&inverted);
    try testing.expectEqual(@as(f64, -7.0), extent.width);
    try testing.expectEqual(@as(f64, -7.0), extent.height);
}

test "rect_abs moves a negative edge to the other side and keeps the extents" {
    const inverted = accesskit_rect_new(9.0, 8.0, 2.0, 1.0);
    try testing.expectEqual(@as(f64, 49.0), accesskit_rect_area(&inverted));
    const ordered = accesskit_rect_abs(&inverted);
    try testing.expectEqual(@as(f64, 2.0), ordered.x0);
    try testing.expectEqual(@as(f64, 1.0), ordered.y0);
    try testing.expectEqual(@as(f64, 9.0), ordered.x1);
    try testing.expectEqual(@as(f64, 8.0), ordered.y1);
    try testing.expectEqual(@as(f64, 7.0), accesskit_rect_width(&ordered));
    try testing.expectEqual(@as(f64, 7.0), accesskit_rect_height(&ordered));
}

test "rect_is_empty answers true only for a zero area" {
    const collapsed = accesskit_rect_new(0.0, 0.0, 0.0, 5.0);
    try testing.expect(accesskit_rect_is_empty(&collapsed));
    const full = accesskit_rect_new(0.0, 0.0, 2.0, 3.0);
    try testing.expect(!accesskit_rect_is_empty(&full));
    const inverted = accesskit_rect_new(9.0, 8.0, 2.0, 1.0);
    try testing.expect(!accesskit_rect_is_empty(&inverted));
}

test "rect_contains excludes both far edges" {
    const rect = accesskit_rect_new(0.0, 0.0, 10.0, 10.0);
    try testing.expect(accesskit_rect_contains(&rect, .{ .x = 0.0, .y = 0.0 }));
    try testing.expect(accesskit_rect_contains(&rect, .{ .x = 9.5, .y = 9.5 }));
    try testing.expect(!accesskit_rect_contains(&rect, .{ .x = 10.0, .y = 5.0 }));
    try testing.expect(!accesskit_rect_contains(&rect, .{ .x = 5.0, .y = 10.0 }));
    try testing.expect(!accesskit_rect_contains(&rect, .{ .x = -0.5, .y = 5.0 }));
    const collapsed = accesskit_rect_new(0.0, 0.0, 0.0, 0.0);
    try testing.expect(!accesskit_rect_contains(&collapsed, .{ .x = 0.0, .y = 0.0 }));
}

test "rect_union takes the extremes of both boxes" {
    const a = accesskit_rect_new(0.0, 0.0, 4.0, 4.0);
    const b = accesskit_rect_new(2.0, -3.0, 6.0, 1.0);
    const both = accesskit_rect_union(&a, b);
    try testing.expectEqual(@as(f64, 0.0), both.x0);
    try testing.expectEqual(@as(f64, -3.0), both.y0);
    try testing.expectEqual(@as(f64, 6.0), both.x1);
    try testing.expectEqual(@as(f64, 4.0), both.y1);
}

test "rect_union_pt counts the perimeter of a zero-area box" {
    const collapsed = accesskit_rect_new(1.0, 1.0, 1.0, 1.0);
    const grown = accesskit_rect_union_pt(&collapsed, .{ .x = 4.0, .y = -2.0 });
    try testing.expectEqual(@as(f64, 1.0), grown.x0);
    try testing.expectEqual(@as(f64, -2.0), grown.y0);
    try testing.expectEqual(@as(f64, 4.0), grown.x1);
    try testing.expectEqual(@as(f64, 1.0), grown.y1);
}

test "rect_intersect clamps to the overlap and then to a zero area" {
    const a = accesskit_rect_new(0.0, 0.0, 10.0, 10.0);
    const b = accesskit_rect_new(5.0, 5.0, 20.0, 20.0);
    const overlap = accesskit_rect_intersect(&a, b);
    try testing.expectEqual(@as(f64, 5.0), overlap.x0);
    try testing.expectEqual(@as(f64, 5.0), overlap.y0);
    try testing.expectEqual(@as(f64, 10.0), overlap.x1);
    try testing.expectEqual(@as(f64, 10.0), overlap.y1);
    try testing.expectEqual(@as(f64, 25.0), accesskit_rect_area(&overlap));

    const far = accesskit_rect_new(100.0, 100.0, 200.0, 200.0);
    const none = accesskit_rect_intersect(&a, far);
    try testing.expectEqual(@as(f64, 100.0), none.x0);
    try testing.expectEqual(@as(f64, 100.0), none.y0);
    try testing.expectEqual(@as(f64, 100.0), none.x1);
    try testing.expectEqual(@as(f64, 100.0), none.y1);
    try testing.expect(accesskit_rect_is_empty(&none));
}

test "rect_translate moves all four corners and keeps the extent" {
    const moved = accesskit_rect_translate(
        accesskit_rect_new(1.0, 2.0, 5.0, 8.0),
        .{ .x = 10.0, .y = -20.0 },
    );
    try testing.expectEqual(@as(f64, 11.0), moved.x0);
    try testing.expectEqual(@as(f64, -18.0), moved.y0);
    try testing.expectEqual(@as(f64, 15.0), moved.x1);
    try testing.expectEqual(@as(f64, -12.0), moved.y1);
    try testing.expectEqual(@as(f64, 4.0), accesskit_rect_width(&moved));
}

test "a null rectangle answers the value the header names for it" {
    try testing.expectEqual(@as(f64, 0.0), accesskit_rect_width(null));
    try testing.expectEqual(@as(f64, 0.0), accesskit_rect_height(null));
    try testing.expectEqual(@as(f64, 0.0), accesskit_rect_min_x(null));
    try testing.expectEqual(@as(f64, 0.0), accesskit_rect_max_x(null));
    try testing.expectEqual(@as(f64, 0.0), accesskit_rect_min_y(null));
    try testing.expectEqual(@as(f64, 0.0), accesskit_rect_max_y(null));
    try testing.expectEqual(@as(f64, 0.0), accesskit_rect_area(null));

    const corner = accesskit_rect_origin(null);
    try testing.expectEqual(@as(f64, 0.0), corner.x);
    try testing.expectEqual(@as(f64, 0.0), corner.y);

    const extent = accesskit_rect_size(null);
    try testing.expectEqual(@as(f64, 0.0), extent.width);
    try testing.expectEqual(@as(f64, 0.0), extent.height);

    try testing.expect(accesskit_rect_is_empty(null));
    try testing.expect(!accesskit_rect_contains(null, .{ .x = 0.0, .y = 0.0 }));

    const zero = rectToC(rect_mod.rect_zero);
    try testing.expectEqual(zero, rectToC(accesskit_rect_abs(null)));
    try testing.expectEqual(
        zero,
        rectToC(accesskit_rect_union(null, accesskit_rect_new(5.0, 5.0, 9.0, 9.0))),
    );
    try testing.expectEqual(zero, rectToC(accesskit_rect_union_pt(null, .{ .x = 5.0, .y = 5.0 })));
    try testing.expectEqual(
        zero,
        rectToC(accesskit_rect_intersect(null, accesskit_rect_new(1.0, 1.0, 2.0, 2.0))),
    );
}

test "a null rectangle is the zero rectangle byte for byte" {
    // `null` is documented to answer the zero rectangle. This compares the 32
    // bytes, so a null branch that returned a rectangle with any other corner
    // fails here.
    const from_null = accesskit_rect_abs(null);
    const from_zero = rect_mod.rect_zero;
    try testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&from_zero),
        std.mem.asBytes(&from_null),
    );
}

test "size_to_vec2 puts the width on x and the height on y" {
    const read = accesskit_size_to_vec2(.{ .width = 30.0, .height = 40.0 });
    try testing.expectEqual(@as(f64, 30.0), read.x);
    try testing.expectEqual(@as(f64, 40.0), read.y);
}

test "size_scale, size_add and size_sub work one dimension at a time" {
    const doubled = accesskit_size_scale(.{ .width = 3.0, .height = 5.0 }, 2.0);
    try testing.expectEqual(@as(f64, 6.0), doubled.width);
    try testing.expectEqual(@as(f64, 10.0), doubled.height);

    const sum = accesskit_size_add(
        .{ .width = 10.0, .height = 20.0 },
        .{ .width = 1.5, .height = -0.5 },
    );
    try testing.expectEqual(@as(f64, 11.5), sum.width);
    try testing.expectEqual(@as(f64, 19.5), sum.height);

    const difference = accesskit_size_sub(
        .{ .width = 10.0, .height = 20.0 },
        .{ .width = 1.5, .height = -0.5 },
    );
    try testing.expectEqual(@as(f64, 8.5), difference.width);
    try testing.expectEqual(@as(f64, 20.5), difference.height);
}

test "vec2_to_point and vec2_to_size copy both components unchanged" {
    const as_point = accesskit_vec2_to_point(.{ .x = 1.25, .y = -2.5 });
    try testing.expectEqual(@as(f64, 1.25), as_point.x);
    try testing.expectEqual(@as(f64, -2.5), as_point.y);
    const as_size = accesskit_vec2_to_size(.{ .x = 1.25, .y = -2.5 });
    try testing.expectEqual(@as(f64, 1.25), as_size.width);
    try testing.expectEqual(@as(f64, -2.5), as_size.height);
}

test "vec2_add, vec2_sub, vec2_scale and vec2_neg work componentwise" {
    const a: Vec2 = .{ .x = 10.0, .y = 20.0 };
    const b: Vec2 = .{ .x = 1.5, .y = -0.5 };
    const sum = accesskit_vec2_add(a, b);
    try testing.expectEqual(@as(f64, 11.5), sum.x);
    try testing.expectEqual(@as(f64, 19.5), sum.y);
    const difference = accesskit_vec2_sub(a, b);
    try testing.expectEqual(@as(f64, 8.5), difference.x);
    try testing.expectEqual(@as(f64, 20.5), difference.y);
    const scaled = accesskit_vec2_scale(b, 4.0);
    try testing.expectEqual(@as(f64, 6.0), scaled.x);
    try testing.expectEqual(@as(f64, -2.0), scaled.y);
    const negated = accesskit_vec2_neg(b);
    try testing.expectEqual(@as(f64, -1.5), negated.x);
    try testing.expectEqual(@as(f64, 0.5), negated.y);
}

test "the two points and the two vectors are inverse readings of each other" {
    const original: Size = .{ .width = 7.5, .height = 9.25 };
    const as_vec2 = accesskit_size_to_vec2(original);
    try testing.expectEqual(@as(f64, 7.5), as_vec2.x);
    try testing.expectEqual(@as(f64, 9.25), as_vec2.y);

    const back_to_size = accesskit_vec2_to_size(as_vec2);
    try testing.expectEqual(@as(f64, 7.5), back_to_size.width);
    try testing.expectEqual(@as(f64, 9.25), back_to_size.height);

    const as_point = accesskit_vec2_to_point(as_vec2);
    try testing.expectEqual(@as(f64, 7.5), as_point.x);
    try testing.expectEqual(@as(f64, 9.25), as_point.y);

    const back_to_vec2 = accesskit_point_to_vec2(as_point);
    try testing.expectEqual(@as(f64, 7.5), back_to_vec2.x);
    try testing.expectEqual(@as(f64, 9.25), back_to_vec2.y);
}
