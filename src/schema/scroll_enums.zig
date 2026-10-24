//! `ScrollUnit` and `ScrollHint` from the AccessKit core, ported from
//! `accesskit/src/lib.rs:3271-3298`.
//!
//! The module holds the two `#[repr(u8)]` enums, their tag spellings, and the
//! byte and string conversions. It opens no file, allocates nothing, and takes
//! no `io`, because a value here carries nothing but its byte.
//!
//! Four functions here have no upstream counterpart.
//! `scrollUnitToStaticStr`, `scrollUnitFromInt`, `scrollHintToStaticStr` and
//! `scrollHintFromInt` are port additions. The AT-SPI codec and the C boundary
//! need a checked byte-to-tag gate and a name for each tag, and upstream
//! declares neither. Upstream gives the two types nothing but the `Clone`,
//! `Copy`, `Debug`, `PartialEq` and `Eq` derives. The serde, schemars and pyo3
//! attributes at `accesskit/src/lib.rs:3271-3297` generate no port code.

const std = @import("std");

/// The amount by which to scroll in the direction specified by one of the
/// `Action.scroll_up`, `Action.scroll_down`, `Action.scroll_left`, and
/// `Action.scroll_right` actions.
pub const ScrollUnit = enum(u8) {
    /// One item of a list, one line of text for a vertical scroll, one
    /// character for a horizontal scroll, or an approximation of one of these.
    /// A wire byte of 0 decodes to this tag.
    item = 0,
    /// The amount of content that fits in the viewport.
    page = 1,
};

/// A suggestion about where the node being scrolled into view should be
/// positioned relative to the edges of the scrollable container.
///
/// A corner tag names two edges of the viewport, and an edge tag names one.
pub const ScrollHint = enum(u8) {
    /// The node goes to the top and the left edge at once. A wire byte of 0
    /// decodes to this tag.
    top_left = 0,
    /// The node goes to the bottom and the right edge at once.
    bottom_right = 1,
    /// The node goes to the top edge.
    top_edge = 2,
    /// The node goes to the bottom edge.
    bottom_edge = 3,
    /// The node goes to the left edge.
    left_edge = 4,
    /// The node goes to the right edge.
    right_edge = 5,
};

/// The tag spelling of `value`, taken from `docs/10-accesskit-core.md:837`, so
/// a decoded byte and a written literal read the same.
///
/// The result points into the binary image. It is never released, and the call
/// neither allocates nor blocks.
///
/// The result is the Zig tag spelling, not a serde name. `item` and `page` are
/// the camelCase forms as well, so the two names agree here, and the port keeps
/// no other name (`docs/10-accesskit-core.md:817-819`).
pub fn scrollUnitToStaticStr(value: ScrollUnit) []const u8 {
    return switch (value) {
        .item => "item",
        .page => "page",
    };
}

/// The tag that the wire byte `value` declares, or `null` when no variant
/// declares it.
///
/// The check happens here, so a byte that declares no tag is rejected instead
/// of becoming a value that `scrollUnitToStaticStr` cannot name.
///
/// The byte is the enum discriminant, so the serde camelCase name plays no part
/// in it.
pub fn scrollUnitFromInt(value: u8) ?ScrollUnit {
    return switch (value) {
        0 => .item,
        1 => .page,
        else => null,
    };
}

/// The tag spelling of `value`, taken from `docs/10-accesskit-core.md:838`, so
/// a decoded byte and a written literal read the same.
///
/// The result points into the binary image. It is never released, and the call
/// neither allocates nor blocks.
///
/// The result is the Zig tag spelling, not the serde camelCase name. The
/// camelCase forms are `topLeft`, `bottomRight`, `topEdge`, `bottomEdge`,
/// `leftEdge` and `rightEdge`, and the port produces none of them
/// (`docs/10-accesskit-core.md:817-819`).
pub fn scrollHintToStaticStr(value: ScrollHint) []const u8 {
    return switch (value) {
        .top_left => "top_left",
        .bottom_right => "bottom_right",
        .top_edge => "top_edge",
        .bottom_edge => "bottom_edge",
        .left_edge => "left_edge",
        .right_edge => "right_edge",
    };
}

/// The tag that the wire byte `value` declares, or `null` when no variant
/// declares it.
///
/// The check happens here, so a byte that declares no tag is rejected instead
/// of becoming a value that `scrollHintToStaticStr` cannot name.
///
/// The byte is the enum discriminant, so the serde camelCase name plays no part
/// in it.
pub fn scrollHintFromInt(value: u8) ?ScrollHint {
    return switch (value) {
        0 => .top_left,
        1 => .bottom_right,
        2 => .top_edge,
        3 => .bottom_edge,
        4 => .left_edge,
        5 => .right_edge,
        else => null,
    };
}

comptime {
    // The declaration order is wire-visible: `accesskit-c/include/accesskit.h:497`
    // fixes the six `ScrollHint` constants in the same order, and the wire
    // encoding of `ScrollUnit` depends on the order upstream declares. Pin the
    // count and the discriminant of every tag, so a reordering tag fails to
    // compile instead of changing the bytes on the wire.
    for (@typeInfo(ScrollUnit).@"enum".field_values, 0..) |field_value, index| {
        std.debug.assert(field_value == index);
    }
    for (@typeInfo(ScrollHint).@"enum".field_values, 0..) |field_value, index| {
        std.debug.assert(field_value == index);
    }
    std.debug.assert(@typeInfo(ScrollUnit).@"enum".field_names.len == 2);
    std.debug.assert(@typeInfo(ScrollHint).@"enum".field_names.len == 6);

    // Rule L2: a `#[repr(u8)]` enum crosses the C ABI as one byte.
    std.debug.assert(@sizeOf(ScrollUnit) == 1);
    std.debug.assert(@alignOf(ScrollUnit) == 1);
    std.debug.assert(@sizeOf(ScrollHint) == 1);
    std.debug.assert(@alignOf(ScrollHint) == 1);
}

test "ScrollUnit keeps the upstream layout and tag order" {
    try std.testing.expectEqual(@as(u8, 1), @sizeOf(ScrollUnit));
    try std.testing.expectEqual(@as(u8, 1), @alignOf(ScrollUnit));

    const upstream_order = [_]ScrollUnit{ .item, .page };
    for (upstream_order, 0..) |tag, index| {
        try std.testing.expectEqual(@as(u8, @intCast(index)), @backingInt(tag));
    }
}

test "ScrollHint keeps the upstream layout and tag order" {
    try std.testing.expectEqual(@as(u8, 1), @sizeOf(ScrollHint));
    try std.testing.expectEqual(@as(u8, 1), @alignOf(ScrollHint));

    const upstream_order = [_]ScrollHint{
        .top_left,
        .bottom_right,
        .top_edge,
        .bottom_edge,
        .left_edge,
        .right_edge,
    };
    for (upstream_order, 0..) |tag, index| {
        try std.testing.expectEqual(@as(u8, @intCast(index)), @backingInt(tag));
    }
}

test "scrollUnitToStaticStr names each variant" {
    try std.testing.expectEqualStrings("item", scrollUnitToStaticStr(.item));
    try std.testing.expectEqualStrings("page", scrollUnitToStaticStr(.page));
}

test "scrollHintToStaticStr names each variant" {
    try std.testing.expectEqualStrings("top_left", scrollHintToStaticStr(.top_left));
    try std.testing.expectEqualStrings("bottom_right", scrollHintToStaticStr(.bottom_right));
    try std.testing.expectEqualStrings("top_edge", scrollHintToStaticStr(.top_edge));
    try std.testing.expectEqualStrings("bottom_edge", scrollHintToStaticStr(.bottom_edge));
    try std.testing.expectEqualStrings("left_edge", scrollHintToStaticStr(.left_edge));
    try std.testing.expectEqualStrings("right_edge", scrollHintToStaticStr(.right_edge));
}

test "scrollUnitFromInt rejects every discriminant no variant declares" {
    try std.testing.expectEqual(@as(?ScrollUnit, null), scrollUnitFromInt(2));
    try std.testing.expectEqual(@as(?ScrollUnit, null), scrollUnitFromInt(255));
}

test "scrollHintFromInt rejects every discriminant no variant declares" {
    try std.testing.expectEqual(@as(?ScrollHint, null), scrollHintFromInt(6));
    try std.testing.expectEqual(@as(?ScrollHint, null), scrollHintFromInt(255));
}

test "every ScrollUnit byte round trips through its tag spelling" {
    inline for (@typeInfo(ScrollUnit).@"enum".field_names, @typeInfo(ScrollUnit).@"enum".field_values) |field_name, field_value| {
        const tag: ScrollUnit = @fromBackingInt(@intCast(field_value));
        try std.testing.expectEqual(tag, scrollUnitFromInt(@intCast(field_value)).?);
        try std.testing.expectEqualStrings(field_name, scrollUnitToStaticStr(tag));
    }
}

test "every ScrollHint byte round trips through its tag spelling" {
    inline for (@typeInfo(ScrollHint).@"enum".field_names, @typeInfo(ScrollHint).@"enum".field_values) |field_name, field_value| {
        const tag: ScrollHint = @fromBackingInt(@intCast(field_value));
        try std.testing.expectEqual(tag, scrollHintFromInt(@intCast(field_value)).?);
        try std.testing.expectEqualStrings(field_name, scrollHintToStaticStr(tag));
    }
}
