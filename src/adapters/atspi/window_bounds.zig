//! `WindowBounds`: the root window's two boxes, and the conversion from the
//! tree's `f64` geometry to the four `i32` members an AT-SPI box carries.
//!
//! **Upstream.** `accesskit_atspi_common/src/util.rs:9-134` declares
//! `WindowBounds` and its accessors. `docs/41-atspi-build-map.md` section 2.2
//! gives this module `util.rs:9-134` and section 1.5 records `(iiii)` as the
//! wire type of `Component.GetExtents`, `Image.GetImageExtents`,
//! `Image.GetImagePosition`, `Text.GetCharacterExtents` and
//! `Text.GetRangeExtents`.
//!
//! **Two boxes, and why both are kept.** `outer` is the frame the window manager
//! gives the application and `inner` is the area the application draws in. AT-SPI
//! reports `inner` as the node's extents and `outer` as the value of
//! `Component.GetLayer`'s companion, so neither is derivable from the other:
//! a window with a title bar has an inner box shorter than its outer one. The
//! type therefore stores both and never replaces one with the other.
//!
//! **The conversion, and its rounding rule.** The tree measures in `f64`
//! physical pixels and the wire carries `i32`. `toWire` rounds **toward zero**
//! through `@intFromFloat`, and this is the whole of the rounding rule: a
//! coordinate of `-0.5` becomes `0` and not `-1`, and a width of `10.9` becomes
//! `10`. Upstream reaches the same numbers through Rust's `as i32`, which is
//! also a truncation toward zero, so the port matches it exactly rather than
//! rounding to nearest. A conversion that rounded to nearest would put a
//! half-pixel error into every `GetExtents` answer, and a client that adds the
//! widths of a row of text would accumulate it.
//!
//! **Why the four members are an array and not a second `Rect`.**
//! `wire/rect.zig` declares `Rect`, the AT-SPI `(iiii)` box, and `docs/41`
//! section 2.1 rule 2 says one module declares a type. This module therefore
//! produces `[4]i32` in wire order and lets that module own the marshalling.
//! A second `Rect` here would be a second declaration of a wire type, and the
//! two would drift.
//!
//! **No allocator, no clock, no I/O.** Every function here is a pure function
//! of its arguments, so a test drives all of them without a runtime.

const std = @import("std");
const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const wire = @import("wire.zig");
const Point = schema.Point;
const Rect = schema.Rect;
const Size = schema.Size;

/// The four members of an AT-SPI box, in wire order: `x`, `y`, `width`,
/// `height`.
///
/// An array rather than a struct because the four members have no names on the
/// wire and because `wire/rect.zig` owns the named form. The index of each
/// member is its position, which is what the test below pins.
pub const Extent = [4]i32;

/// The index of `x` in an `Extent`.
pub const extent_x: usize = 0;
/// The index of `y` in an `Extent`.
pub const extent_y: usize = 1;
/// The index of `width` in an `Extent`.
pub const extent_width: usize = 2;
/// The index of `height` in an `Extent`.
pub const extent_height: usize = 3;

/// The root window's two boxes.
///
/// Upstream `util.rs:9-134`. The value owns nothing: both boxes are four `f64`
/// each, so a copy is independent of the original and no method releases
/// anything.
pub const WindowBounds = struct {
    /// The frame the window manager gave the window, including any decoration.
    outer: Rect,
    /// The area the application draws in.
    inner: Rect,

    /// Builds the pair. Upstream `WindowBounds::new`.
    ///
    /// No box is checked and none is ordered, so an inverted or empty pair is
    /// a legal value and this function does not call `abs`.
    ///
    /// **Errors.** This function does not fail.
    pub fn init(outer: Rect, inner: Rect) WindowBounds {
        return .{ .outer = outer, .inner = inner };
    }

    /// The empty pair: two boxes at the origin with no extent. Upstream
    /// `WindowBounds::default`, and what the adapter starts with before the
    /// application has reported a window.
    pub const empty: WindowBounds = .{
        .outer = rectAtOrigin(0, 0),
        .inner = rectAtOrigin(0, 0),
    };

    /// The frame box. Upstream `WindowBounds::outer`.
    ///
    /// **Errors.** This function does not fail.
    pub fn outerBox(self: WindowBounds) Rect {
        return self.outer;
    }

    /// The drawn box. Upstream `WindowBounds::inner`.
    ///
    /// **Errors.** This function does not fail.
    pub fn innerBox(self: WindowBounds) Rect {
        return self.inner;
    }

    /// The corner the window manager placed the frame at. Upstream
    /// `WindowBounds::window_origin`.
    ///
    /// **Errors.** This function does not fail.
    pub fn windowOrigin(self: WindowBounds) Point {
        return self.outer.topLeft();
    }

    /// The extent of the drawn box. Upstream `WindowBounds::viewport_size`.
    ///
    /// A negative extent travels with the value, because `Rect.width` is
    /// `x1 - x0` and this function does not call `abs`.
    ///
    /// **Errors.** This function does not fail.
    pub fn viewportSize(self: WindowBounds) Size {
        return .{ .width = self.inner.width(), .height = self.inner.height() };
    }

    /// Moves the drawn box to `position` and keeps its extent. Upstream
    /// `WindowBounds::set_inner_bounds_from_position`.
    ///
    /// The frame does not move, so this is the answer to a window manager that
    /// moved the client area inside a frame it did not resize.
    ///
    /// **Errors.** This function does not fail.
    pub fn setInnerBoundsFromPosition(self: *WindowBounds, position: Point) void {
        self.inner = self.inner.withOrigin(position);
    }

    /// Resizes the drawn box to `size` and keeps its corner. Upstream
    /// `WindowBounds::set_inner_bounds_from_size`.
    ///
    /// **Errors.** This function does not fail.
    pub fn setInnerBoundsFromSize(self: *WindowBounds, size: Size) void {
        self.inner = self.inner.withSize(size);
    }

    /// Reports `outer` and `inner` as the new pair, which is what
    /// `accesskit_unix_adapter_set_root_window_bounds` does.
    ///
    /// **Errors.** This function does not fail.
    pub fn set(self: *WindowBounds, outer: Rect, inner: Rect) void {
        self.* = init(outer, inner);
    }

    /// The corner the coordinate space `coord_type` counts from.
    ///
    /// Upstream `util.rs:43-56`. The three spaces answer three different
    /// corners, which is why a caller has to say which one it holds a point in:
    /// the screen space starts at the drawn box's own corner, the window space
    /// starts at the origin, and the parent space starts at the parent's own
    /// corner with the sign reversed so that adding it moves a child point into
    /// the space its parent is measured in.
    ///
    /// A `parent` of `null` under `.parent` answers the drawn box's corner, which
    /// is what the window root has: it has no parent to be measured against.
    ///
    /// **Errors.** `error.TreeCycle` from the walk that reads the parent's box.
    pub fn origin(
        self: WindowBounds,
        parent: ?consumer.node_id.NodeRef,
        coord_type: wire.CoordType,
    ) consumer.tree.QueryError!Point {
        return switch (coord_type) {
            .screen => self.inner.topLeft(),
            .window => .{ .x = 0, .y = 0 },
            .parent => {
                const node = parent orelse return self.inner.topLeft();
                // Upstream `unwrap_or_default()` at `util.rs:49` reads a box
                // with no extent as the origin, and a `f64` default is zero, so
                // a parent with no box has the origin as its corner too.
                const parent_box = try consumer.node_ref.geometry.boundingBox(node) orelse
                    return .{ .x = 0, .y = 0 };
                return .{ .x = -parent_box.x0, .y = -parent_box.y0 };
            },
        };
    }

    /// Moves a point from the tree's own space into the space `coord_type`
    /// counts from.
    ///
    /// Upstream `util.rs:23-31`. This is the direction every geometry answer
    /// travels, because the tree measures in its own space and a client asks in
    /// one of the three others.
    ///
    /// **Errors.** `error.TreeCycle` from the walk that reads the parent's box.
    pub fn accesskitPointToAtspiPoint(
        self: WindowBounds,
        point: Point,
        parent: ?consumer.node_id.NodeRef,
        coord_type: wire.CoordType,
    ) consumer.tree.QueryError!Point {
        const corner = try self.origin(parent, coord_type);
        return .{ .x = corner.x + point.x, .y = corner.y + point.y };
    }

    /// Moves a point from the space `coord_type` counts from into the tree's own
    /// space.
    ///
    /// Upstream `util.rs:33-41`. It is the inverse of
    /// `accesskitPointToAtspiPoint` on the same origin, which is what
    /// `Component.GetAccessibleAtPoint` and `Text.GetOffsetAtPoint` need before
    /// they ask the tree a question in the tree's own coordinates.
    ///
    /// **Errors.** `error.TreeCycle` from the walk that reads the parent's box.
    pub fn atspiPointToAccesskitPoint(
        self: WindowBounds,
        point: Point,
        parent: ?consumer.node_id.NodeRef,
        coord_type: wire.CoordType,
    ) consumer.tree.QueryError!Point {
        const corner = try self.origin(parent, coord_type);
        return .{ .x = point.x - corner.x, .y = point.y - corner.y };
    }
};

/// Builds a box at `(x, y)` with no extent, which is what `WindowBounds.empty`
/// and the tests need.
///
/// **Errors.** This function does not fail.
fn rectAtOrigin(x: f64, y: f64) Rect {
    return schema.rectInit(x, y, x, y);
}

/// The one failure a geometry conversion reports.
///
/// It is declared here and not borrowed from `std.mem.Allocator`, because
/// nothing in this module allocates and a conversion that cannot run out of
/// memory must not answer with a tag that says it did.
pub const GeometryError = error{
    /// A coordinate or an extent does not fit the `i32` the wire carries.
    GeometryOutOfRange,
};

/// Converts `box` into the four `i32` members an AT-SPI `(iiii)` carries, in
/// the order `x`, `y`, `width`, `height`.
///
/// The origin comes from `Rect.x0` and `Rect.y0` and the extents from
/// `Rect.width` and `Rect.height`, which is upstream `rect.rs:28-37` reading
/// the same four members. That pair is self-consistent on an inverted box:
/// `width` is `x1 - x0`, so a box stored with its larger x first reports the
/// larger x as the origin and a negative width, and `fromWire` rebuilds exactly
/// the box it was given. Reading `Rect.minX` here instead would order the
/// corner while leaving the extent signed, so the four members would no longer
/// describe the box `fromWire` returns.
///
/// **Errors.** `error.GeometryOutOfRange` from `truncate`.
pub fn toWire(box: Rect) GeometryError!Extent {
    return .{
        try truncate(box.x0),
        try truncate(box.y0),
        try truncate(box.width()),
        try truncate(box.height()),
    };
}

/// Converts the four `i32` members back into a `Rect`.
///
/// This is the inverse of `toWire` up to the rounding rule: a value `toWire`
/// truncated from a `f64` comes back as the `f64` that truncates to it, so
/// `fromWire(toWire(box))` equals `box` for every box whose four members are
/// whole numbers and is the truncation of `box` for every other one.
///
/// **Errors.** This function does not fail.
pub fn fromWire(members: Extent) Rect {
    const x: f64 = @floatFromInt(members[extent_x]);
    const y: f64 = @floatFromInt(members[extent_y]);
    const width: f64 = @floatFromInt(members[extent_width]);
    const height: f64 = @floatFromInt(members[extent_height]);
    return schema.rectInit(x, y, x + width, y + height);
}

/// Rounds `value` toward zero into the `i32` the wire carries.
///
/// `@intFromFloat` truncates toward zero, which is the same rule Rust's
/// `as i32` applies, so a port and upstream answer the same number for the same
/// `f64`. A value outside the `i32` range is a `f64` the caller cannot have
/// produced from a real window, and this function reports it rather than
/// producing a wrapped number a client would draw at the wrong place.
///
/// **Errors.** `error.GeometryOutOfRange` when `value` does not fit an `i32`.
pub fn truncate(value: f64) GeometryError!i32 {
    // Rust's `as i32` saturates rather than trapping, so upstream answers
    // `i32::MAX` for a coordinate past it. The port reports instead: a clamped
    // box is drawn at a place the application never put it, and a caller that
    // can see the failure answers with the invalid box the AT-SPI reference
    // defines, which is what a client is told to expect for geometry it cannot
    // have.
    const lowest: f64 = @floatFromInt(std.math.minInt(i32));
    const highest: f64 = @floatFromInt(std.math.maxInt(i32));
    if (!std.math.isFinite(value)) return error.GeometryOutOfRange;
    if (value < lowest or value > highest) return error.GeometryOutOfRange;
    return @intFromFloat(@trunc(value));
}

const testing = std.testing;

test "the empty pair is two boxes at the origin with no extent" {
    try testing.expectEqual(@as(f64, 0), WindowBounds.empty.outer.x0);
    try testing.expectEqual(@as(f64, 0), WindowBounds.empty.inner.y1);
    try testing.expectEqual(@as(f64, 0), WindowBounds.empty.viewportSize().width);
    try testing.expectEqual(@as(f64, 0), WindowBounds.empty.viewportSize().height);
}

test "the two boxes are kept apart, because neither is derivable from the other" {
    // A window with a title bar: the frame is wider than the drawn area.
    const bounds = WindowBounds.init(
        schema.rectInit(0, 0, 800, 600),
        schema.rectInit(0, 30, 800, 600),
    );

    try testing.expectEqual(@as(f64, 600), bounds.outer.height());
    try testing.expectEqual(@as(f64, 570), bounds.inner.height());
    try testing.expectEqual(@as(f64, 570), bounds.viewportSize().height);
}

test "set reports both boxes at once and replaces neither with the other" {
    var bounds = WindowBounds.empty;

    bounds.set(schema.rectInit(10, 20, 110, 220), schema.rectInit(10, 40, 110, 220));

    try testing.expectEqual(@as(f64, 10), bounds.outer.x0);
    try testing.expectEqual(@as(f64, 40), bounds.inner.y0);
    try testing.expectEqual(@as(f64, 100), bounds.outer.width());
    try testing.expectEqual(@as(f64, 180), bounds.inner.height());
}

test "moving the drawn box leaves the frame where it was" {
    var bounds = WindowBounds.init(
        schema.rectInit(0, 0, 800, 600),
        schema.rectInit(0, 30, 800, 600),
    );

    bounds.setInnerBoundsFromPosition(.{ .x = 5, .y = 35 });

    try testing.expectEqual(@as(f64, 0), bounds.outer.x0);
    try testing.expectEqual(@as(f64, 5), bounds.inner.x0);
    try testing.expectEqual(@as(f64, 35), bounds.inner.y0);
    // The extent survives the move, which is what makes this a move and not a
    // reset.
    try testing.expectEqual(@as(f64, 570), bounds.viewportSize().height);
}

test "resizing the drawn box keeps its corner" {
    var bounds = WindowBounds.init(
        schema.rectInit(0, 0, 800, 600),
        schema.rectInit(10, 30, 810, 630),
    );

    bounds.setInnerBoundsFromSize(.{ .width = 400, .height = 300 });

    try testing.expectEqual(@as(f64, 10), bounds.inner.x0);
    try testing.expectEqual(@as(f64, 30), bounds.inner.y0);
    try testing.expectEqual(@as(f64, 400), bounds.viewportSize().width);
}

test "windowOrigin is the frame corner, not the drawn one" {
    const bounds = WindowBounds.init(
        schema.rectInit(12, 34, 812, 634),
        schema.rectInit(12, 64, 812, 634),
    );

    try testing.expectEqual(@as(f64, 12), bounds.windowOrigin().x);
    try testing.expectEqual(@as(f64, 34), bounds.windowOrigin().y);
}

test "the four wire members are x, y, width, height in that order" {
    // The order is the contract: a peer that read `width` where `height` was
    // written decodes a box that is wrong in two members at once.
    const members = try toWire(schema.rectInit(10, 20, 40, 70));

    try testing.expectEqual(@as(i32, 10), members[extent_x]);
    try testing.expectEqual(@as(i32, 20), members[extent_y]);
    try testing.expectEqual(@as(i32, 30), members[extent_width]);
    try testing.expectEqual(@as(i32, 50), members[extent_height]);
}

test "an inverted box reports the stored corner and a negative extent" {
    // `Rect.x0` is the corner the box was built with and `Rect.width` is
    // `x1 - x0`, so the two agree and `fromWire` rebuilds the same box. Reading
    // `Rect.minX` here instead would put the smaller x in the first member and
    // leave a negative extent beside it, which describes a box that is not the
    // one that was stored.
    const stored = schema.rectInit(40, 70, 10, 20);
    const members = try toWire(stored);

    try testing.expectEqual(@as(i32, 40), members[extent_x]);
    try testing.expectEqual(@as(i32, 70), members[extent_y]);
    try testing.expectEqual(@as(i32, -30), members[extent_width]);
    try testing.expectEqual(@as(i32, -50), members[extent_height]);

    const rebuilt = fromWire(members);
    try testing.expectEqual(stored.x0, rebuilt.x0);
    try testing.expectEqual(stored.y0, rebuilt.y0);
    try testing.expectEqual(stored.x1, rebuilt.x1);
    try testing.expectEqual(stored.y1, rebuilt.y1);
}

test "the rounding rule is toward zero, not to nearest" {
    // A half-pixel coordinate truncates to zero, and a negative half-pixel
    // truncates to zero as well. Rounding to nearest would give 1 and -1 here.
    try testing.expectEqual(@as(i32, 0), try truncate(0.5));
    try testing.expectEqual(@as(i32, 0), try truncate(-0.5));
    try testing.expectEqual(@as(i32, 10), try truncate(10.9));
    try testing.expectEqual(@as(i32, -10), try truncate(-10.9));
    try testing.expectEqual(@as(i32, 0), try truncate(0.0));
}

test "a value outside the i32 range is reported rather than wrapped" {
    // A wrapped coordinate draws the box at the wrong place, and a reported
    // error lets the caller answer with the invalid box the AT-SPI reference
    // defines instead.
    try testing.expectError(error.GeometryOutOfRange, truncate(3_000_000_000.0));
    try testing.expectError(error.GeometryOutOfRange, truncate(-3_000_000_000.0));
}

test "the conversion round trips a box whose members are whole numbers" {
    const original = schema.rectInit(-7, 9, 41, 60);
    const members = try toWire(original);

    const recovered = fromWire(members);

    try testing.expectEqual(original.x0, recovered.x0);
    try testing.expectEqual(original.y0, recovered.y0);
    try testing.expectEqual(original.x1, recovered.x1);
    try testing.expectEqual(original.y1, recovered.y1);
}

test "fromWire rebuilds the box the four members name" {
    const recovered = fromWire(.{ 10, 20, 30, 50 });

    try testing.expectEqual(@as(f64, 10), recovered.x0);
    try testing.expectEqual(@as(f64, 20), recovered.y0);
    try testing.expectEqual(@as(f64, 30), recovered.width());
    try testing.expectEqual(@as(f64, 50), recovered.height());
}

test "the three coordinate spaces answer three different corners" {
    // `util.rs:43-56`. The screen space starts at the drawn box, the window
    // space at the origin and the parent space nowhere, because there is no
    // parent in this call.
    const bounds = WindowBounds.init(
        schema.rectInit(10, 20, 810, 620),
        schema.rectInit(12, 64, 812, 624),
    );

    const screen = try bounds.origin(null, .screen);
    try testing.expectEqual(@as(f64, 12), screen.x);
    try testing.expectEqual(@as(f64, 64), screen.y);

    const window_space = try bounds.origin(null, .window);
    try testing.expectEqual(@as(f64, 0), window_space.x);
    try testing.expectEqual(@as(f64, 0), window_space.y);

    const without_parent = try bounds.origin(null, .parent);
    try testing.expectEqual(screen.x, without_parent.x);
    try testing.expectEqual(screen.y, without_parent.y);
}

test "a point moves by the corner and comes back unchanged" {
    // `util.rs:23-41`. The two conversions are inverses on one origin, and the
    // round trip is the property a hit test depends on.
    const bounds = WindowBounds.init(
        schema.rectInit(10, 20, 810, 620),
        schema.rectInit(12, 64, 812, 624),
    );
    const start: Point = .{ .x = 30, .y = 40 };

    const on_screen = try bounds.accesskitPointToAtspiPoint(start, null, .screen);
    try testing.expectEqual(@as(f64, 42), on_screen.x);
    try testing.expectEqual(@as(f64, 104), on_screen.y);

    const back = try bounds.atspiPointToAccesskitPoint(on_screen, null, .screen);
    try testing.expectEqual(start.x, back.x);
    try testing.expectEqual(start.y, back.y);

    // The window space has the origin at zero, so the point does not move.
    const in_window = try bounds.accesskitPointToAtspiPoint(start, null, .window);
    try testing.expectEqual(start.x, in_window.x);
    try testing.expectEqual(start.y, in_window.y);
}

test "the parent space reverses the parent's own corner" {
    // `util.rs:47-53`. A child point is negative in the space its parent is
    // measured in, which is the half of the conversion a `GetAccessibleAtPoint`
    // on a child needs.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    // The map owns the node once `put` returns: `put` copies the value, and the
    // copy shares the one property buffer, so the local must not also release
    // it. `state.deinit` above walks the map and frees the store once, which is
    // the whole teardown. `consumer/tree_state.zig:234` names this trap.
    //
    // The box is written through the map's own entry for the same reason: a
    // local node and the map's entry would share one buffer. `setBounds` at
    // `schema/props/option.zig:140` takes `*Properties`, so the entry is taken
    // by pointer rather than by value.
    const parent_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    try state.nodes.put(gpa, parent_id, .{
        .parent_and_index = null,
        .data = schema.Node.init(gpa, .group),
    });
    const parent = state.nodes.getPtr(parent_id) orelse return error.TestExpectedEqual;
    try schema.option.setBounds(&parent.data.properties, schema.rectInit(100, 200, 300, 400));
    state.root_id = parent_id;
    state.focus_id = parent_id;
    state.is_host_focused = false;
    const parent_ref = consumer.node_id.NodeRef.init(&state, parent_id) orelse
        return error.TestExpectedEqual;

    const bounds = WindowBounds.empty;
    const corner = try bounds.origin(parent_ref, .parent);
    try testing.expectEqual(@as(f64, -100), corner.x);
    try testing.expectEqual(@as(f64, -200), corner.y);

    const child_point: Point = .{ .x = 20, .y = 30 };
    const moved = try bounds.accesskitPointToAtspiPoint(child_point, parent_ref, .parent);
    try testing.expectEqual(@as(f64, -80), moved.x);
    try testing.expectEqual(@as(f64, -170), moved.y);
}
