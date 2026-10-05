//! The three color properties and the three text-decoration properties, from
//! `color_property_methods!` at `accesskit/src/lib.rs:2316-2323` and
//! `text_decoration_property_methods!` at `:2325-2332`.
//!
//! Eighteen free functions, a getter, a setter and a clearer for each of the
//! six. The receiver is the store, `*Properties`, not `*Node`: Zig has no
//! operator overloading and no traits, so the reason upstream hangs 336
//! accessors on `Node` does not apply here, and a module cannot extend a type
//! it does not own. `schema/node.zig` keeps `Node` and its eleven written
//! methods and publishes no forwarder for these.
//!
//! Every function layers a typed read or a typed write over the generic
//! `Properties.get`, `Properties.set` and `Properties.clear`. This module
//! declares no second copy of those three and holds no part of the relation
//! between a `PropertyId` and a payload type, so that relation has exactly one
//! home: `props/table.zig`. A property whose id and payload disagree there
//! reaches this file as `null` rather than as a wrong value, because the
//! `else` arm below reads a mismatched payload as absent.
//!
//! The getter is a read and not a borrow. Upstream's `copy_type_getters` yields
//! `Option<Color>` and `Option<TextDecoration>` by value
//! (`accesskit/src/lib.rs:1251`), because a color is four bytes and a decoration
//! five, so nothing here borrows and nothing here must be released.
//!
//! `Color` and `TextDecoration` are declared in `schema/values.zig` and are not
//! declared here. Both are `extern struct`, because both cross the C ABI. The
//! `comptime` block below pins the size, the alignment and every field offset of
//! both against `accesskit-c/include/accesskit.h:754-759` and `:774-777`, and
//! pins the two optionals against `accesskit_opt_color` at `:766-769` and
//! `accesskit_opt_text_decoration` at `:784-787`.
//!
//! An absent color is not a black color. Every getter returns `null` when the
//! node declares no value, and `null` is not one of the values `Color` or
//! `TextDecoration` can hold. A setter may grow the store, so it returns
//! `error.OutOfMemory`; it takes no allocator, because `Properties` stores the
//! one that grows it (`docs/30` section 4.3). No payload is allocated: a color
//! is four bytes and a decoration five, held by value, so a caller releases
//! nothing beyond the `Properties` it already owns.
//!
//! No setter here guards an owning write with `errdefer`, because a color and
//! a decoration are inline values and a failed write has taken nothing to
//! release. Upstream's `owned_type_setters` needed the guard
//! (`accesskit/src/lib.rs:1261-1269`) because it took ownership of a `Box`, a
//! `String` or a `Vec` and could fail partway holding the replacement. The port
//! deletes the two `Box` payloads, so `props/strings.zig` and `props/vectors.zig`
//! are the two families that still own an allocation and still carry the
//! guard. These two families do not.
//!
//! This module reads no clock, opens no file, formats no string and takes no
//! `std.Io`, because none of the eighteen can block.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const node_enums = @import("../node_enums.zig");
const table = @import("table.zig");
const values = @import("../values.zig");

const Color = values.Color;
const Properties = table.Properties;
const TextDecoration = values.TextDecoration;
const TextDecorationStyle = node_enums.TextDecorationStyle;

/// The color selected in a node whose role is `Role.color_well`, or `null`
/// when the node declares none.
///
/// `null` names no color at all. It is not opaque black and not a fully
/// transparent black, and a node that stores either still reads back a value.
pub fn colorValue(properties: *const Properties) ?Color {
    const stored = properties.get(.color_value) orelse return null;
    // The `else` arm is upstream's own wildcard at `accesskit/src/lib.rs:1252`.
    // The store is keyed by property id, so a payload that does not match the
    // id is a defect in `table.zig` rather than a caller's mistake, and reading
    // it as absent says so instead of failing the caller.
    return switch (stored.*) {
        .color => |value| value,
        else => null,
    };
}

/// Stores `value` as this node's selected color, replacing any earlier one.
///
/// On `error.OutOfMemory` nothing is stored, so a later `colorValue` returns
/// what it held before this call.
pub fn setColorValue(properties: *Properties, value: Color) std.mem.Allocator.Error!void {
    return properties.set(.color_value, .{ .color = value });
}

/// Removes the selected color, so `colorValue` returns `null` afterwards. The
/// color removed is not handed back, and no later read sees it.
pub fn clearColorValue(properties: *Properties) void {
    properties.clear(.color_value);
}

/// The color behind this node, or `null` when the node declares none.
pub fn backgroundColor(properties: *const Properties) ?Color {
    const stored = properties.get(.background_color) orelse return null;
    return switch (stored.*) {
        .color => |value| value,
        else => null,
    };
}

/// Stores `value` as this node's background color, replacing any earlier one.
///
/// On `error.OutOfMemory` nothing is stored, so a later `backgroundColor`
/// returns what it held before this call.
pub fn setBackgroundColor(properties: *Properties, value: Color) std.mem.Allocator.Error!void {
    return properties.set(.background_color, .{ .color = value });
}

/// Removes the background color, so `backgroundColor` returns `null`
/// afterwards.
pub fn clearBackgroundColor(properties: *Properties) void {
    properties.clear(.background_color);
}

/// The color this node draws its text and glyphs in, or `null` when the node
/// declares none.
pub fn foregroundColor(properties: *const Properties) ?Color {
    const stored = properties.get(.foreground_color) orelse return null;
    return switch (stored.*) {
        .color => |value| value,
        else => null,
    };
}

/// Stores `value` as this node's foreground color, replacing any earlier one.
///
/// On `error.OutOfMemory` nothing is stored, so a later `foregroundColor`
/// returns what it held before this call.
pub fn setForegroundColor(properties: *Properties, value: Color) std.mem.Allocator.Error!void {
    return properties.set(.foreground_color, .{ .color = value });
}

/// Removes the foreground color, so `foregroundColor` returns `null`
/// afterwards.
pub fn clearForegroundColor(properties: *Properties) void {
    properties.clear(.foreground_color);
}

/// The style and color of the overline drawn over this node's text, or `null`
/// when the node draws none.
pub fn overline(properties: *const Properties) ?TextDecoration {
    const stored = properties.get(.overline) orelse return null;
    return switch (stored.*) {
        .text_decoration => |value| value,
        else => null,
    };
}

/// Stores `value` as this node's overline, replacing any earlier one.
///
/// On `error.OutOfMemory` nothing is stored, so a later `overline` returns what
/// it held before this call.
pub fn setOverline(properties: *Properties, value: TextDecoration) std.mem.Allocator.Error!void {
    return properties.set(.overline, .{ .text_decoration = value });
}

/// Removes the overline, so `overline` returns `null` afterwards.
pub fn clearOverline(properties: *Properties) void {
    properties.clear(.overline);
}

/// The style and color of the strikethrough drawn through this node's text, or
/// `null` when the node draws none.
pub fn strikethrough(properties: *const Properties) ?TextDecoration {
    const stored = properties.get(.strikethrough) orelse return null;
    return switch (stored.*) {
        .text_decoration => |value| value,
        else => null,
    };
}

/// Stores `value` as this node's strikethrough, replacing any earlier one.
///
/// On `error.OutOfMemory` nothing is stored, so a later `strikethrough` returns
/// what it held before this call.
pub fn setStrikethrough(
    properties: *Properties,
    value: TextDecoration,
) std.mem.Allocator.Error!void {
    return properties.set(.strikethrough, .{ .text_decoration = value });
}

/// Removes the strikethrough, so `strikethrough` returns `null` afterwards.
pub fn clearStrikethrough(properties: *Properties) void {
    properties.clear(.strikethrough);
}

/// The style and color of the underline drawn under this node's text, or `null`
/// when the node draws none.
pub fn underline(properties: *const Properties) ?TextDecoration {
    const stored = properties.get(.underline) orelse return null;
    return switch (stored.*) {
        .text_decoration => |value| value,
        else => null,
    };
}

/// Stores `value` as this node's underline, replacing any earlier one.
///
/// On `error.OutOfMemory` nothing is stored, so a later `underline` returns what
/// it held before this call.
pub fn setUnderline(properties: *Properties, value: TextDecoration) std.mem.Allocator.Error!void {
    return properties.set(.underline, .{ .text_decoration = value });
}

/// Removes the underline, so `underline` returns `null` afterwards.
pub fn clearUnderline(properties: *Properties) void {
    properties.clear(.underline);
}

comptime {
    // `typedef struct accesskit_color { uint8_t red; uint8_t green; uint8_t blue;
    // uint8_t alpha; } accesskit_color;` at
    // `accesskit-c/include/accesskit.h:754-759`. Four `uint8_t` members, so the
    // struct is four bytes at alignment 1 with no padding and the members keep
    // the source order an `extern struct` guarantees.
    assert(@sizeOf(Color) == 4);
    assert(@alignOf(Color) == 1);
    assert(@offsetOf(Color, "red") == 0);
    assert(@offsetOf(Color, "green") == 1);
    assert(@offsetOf(Color, "blue") == 2);
    assert(@offsetOf(Color, "alpha") == 3);

    // `typedef struct accesskit_text_decoration { accesskit_text_decoration_style
    // style; struct accesskit_color color; } accesskit_text_decoration;` at
    // `:774-777`, over `typedef uint8_t accesskit_text_decoration_style;` at
    // `:571`. One byte of style then four bytes of color, so five bytes at
    // alignment 1 and no padding between them.
    assert(@sizeOf(TextDecoration) == 5);
    assert(@alignOf(TextDecoration) == 1);
    assert(@offsetOf(TextDecoration, "style") == 0);
    assert(@offsetOf(TextDecoration, "color") == 1);

    // `accesskit_opt_color` at `:766-769` is `bool has_value; struct
    // accesskit_color value;`. `bool` is one byte in C and so is the tag of a
    // Zig optional with no niche, and the payload has alignment 1, so the tag
    // takes offset 0 and the payload starts at 1.
    assert(@sizeOf(?Color) == 5);
    assert(@alignOf(?Color) == 1);

    // `accesskit_opt_text_decoration` at `:784-787` is the same shape over the
    // five-byte payload, so one tag byte and five payload bytes.
    assert(@sizeOf(?TextDecoration) == 6);
    assert(@alignOf(?TextDecoration) == 1);
}

/// The six properties this family publishes a getter, a setter and a clearer
/// for, in upstream order: the three colors of `color_property_methods!` at
/// `accesskit/src/lib.rs:2316-2323`, then the three decorations of
/// `text_decoration_property_methods!` at `:2325-2332`.
///
/// This is the family's whole domain in one place, so
/// `table.assertFamilyReachable` can hold it against the descriptor table.
pub const property_ids = [_]table.PropertyId{
    .color_value,
    .background_color,
    .foreground_color,
    .overline,
    .strikethrough,
    .underline,
};

comptime {
    // The two invocations carry three entries each, so six. A row added here
    // without an upstream entry changes the number of functions this module
    // publishes, so the count is the check.
    assert(property_ids.len == 6);
    table.assertFamilyReachable(.colors, property_ids);
}

/// The color upstream's own test writes at `accesskit/src/lib.rs:1608`.
const opaque_white: Color = .{ .red = 255, .green = 255, .blue = 255, .alpha = 255 };
/// The decoration upstream's own test writes at `accesskit/src/lib.rs:1635-1643`.
const test_decoration: TextDecoration = .{
    .style = .dotted,
    .color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 255 },
};
/// A color the absence of which must not be mistaken for the absence of the
/// property: four zero bytes are a value, not a missing value.
const transparent_black: Color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 };

/// Drives one color property through absent, set, read and cleared, and reports
/// the first disagreement. `comptime` so each call site names three literal
/// functions and a wrong spelling is a compile error rather than a bad pointer.
fn expectColorAbsentThenPresentThenAbsent(
    comptime get: fn (*const Properties) ?Color,
    comptime set: fn (*Properties, Color) std.mem.Allocator.Error!void,
    comptime clear: fn (*Properties) void,
) !void {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try testing.expect(get(&properties) == null);

    try set(&properties, opaque_white);
    const read = get(&properties);
    try testing.expect(read != null);
    try testing.expect(read.?.eql(opaque_white));

    clear(&properties);
    try testing.expect(get(&properties) == null);
}

/// The decoration counterpart of `expectColorAbsentThenPresentThenAbsent`.
fn expectDecorationAbsentThenPresentThenAbsent(
    comptime get: fn (*const Properties) ?TextDecoration,
    comptime set: fn (*Properties, TextDecoration) std.mem.Allocator.Error!void,
    comptime clear: fn (*Properties) void,
) !void {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try testing.expect(get(&properties) == null);

    try set(&properties, test_decoration);
    const read = get(&properties);
    try testing.expect(read != null);
    try testing.expect(read.?.eql(test_decoration));

    clear(&properties);
    try testing.expect(get(&properties) == null);
}

test "colorValue is absent, round-trips opaque white, and clears back to absent" {
    try expectColorAbsentThenPresentThenAbsent(colorValue, setColorValue, clearColorValue);
}

test "backgroundColor is absent, round-trips opaque white, and clears back to absent" {
    try expectColorAbsentThenPresentThenAbsent(
        backgroundColor,
        setBackgroundColor,
        clearBackgroundColor,
    );
}

test "foregroundColor is absent, round-trips opaque white, and clears back to absent" {
    try expectColorAbsentThenPresentThenAbsent(
        foregroundColor,
        setForegroundColor,
        clearForegroundColor,
    );
}

test "overline is absent, round-trips a dotted black line, and clears back to absent" {
    try expectDecorationAbsentThenPresentThenAbsent(overline, setOverline, clearOverline);
}

test "strikethrough is absent, round-trips a dotted black line, and clears back to absent" {
    try expectDecorationAbsentThenPresentThenAbsent(
        strikethrough,
        setStrikethrough,
        clearStrikethrough,
    );
}

test "underline is absent, round-trips a dotted black line, and clears back to absent" {
    try expectDecorationAbsentThenPresentThenAbsent(underline, setUnderline, clearUnderline);
}

test "a color reads back as the four bytes a C caller sees, in declaration order" {
    const bytes: [4]u8 = @bitCast(opaque_white);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, &bytes);

    const mixed: Color = .{ .red = 1, .green = 2, .blue = 3, .alpha = 4 };
    const mixed_bytes: [4]u8 = @bitCast(mixed);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &mixed_bytes);

    const clear_bytes: [4]u8 = @bitCast(transparent_black);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &clear_bytes);
}

test "a decoration reads back as one style byte then the four color bytes" {
    const bytes: [5]u8 = @bitCast(test_decoration);
    // `ACCESSKIT_TEXT_DECORATION_STYLE_DOTTED` is 1 in
    // `accesskit-c/include/accesskit.h:565`, so the style occupies byte 0.
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 255 }, &bytes);
}

test "every color channel carries both ends of its u8 range through the getter" {
    // The channels are `u8`, so the range ends are 0 and 255. A port that
    // narrowed a channel to `f32` would round-trip 0 and 255 as well, so the
    // second half of this sweep uses the odd byte values 1 and 254 that no `f32`
    // holds exactly.
    const channel_ends = comptime [_]Color{
        .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 },
        .{ .red = 255, .green = 255, .blue = 255, .alpha = 255 },
        .{ .red = 0, .green = 255, .blue = 0, .alpha = 255 },
        .{ .red = 255, .green = 0, .blue = 255, .alpha = 0 },
        .{ .red = 1, .green = 0, .blue = 254, .alpha = 0 },
        .{ .red = 254, .green = 255, .blue = 1, .alpha = 255 },
        .{ .red = 0, .green = 1, .blue = 255, .alpha = 254 },
        .{ .red = 255, .green = 254, .blue = 0, .alpha = 1 },
    };

    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    inline for (channel_ends) |value| {
        try setColorValue(&properties, value);
        const read = colorValue(&properties);
        try testing.expect(read != null);
        try testing.expect(read.?.eql(value));

        clearColorValue(&properties);
        try testing.expect(colorValue(&properties) == null);
    }
}

test "every decoration style round-trips with its own discriminant" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    inline for (comptime std.enums.values(TextDecorationStyle), 0..) |style, discriminant| {
        try setUnderline(&properties, .{ .style = style, .color = opaque_white });

        const read = underline(&properties);
        try testing.expect(read != null);
        try testing.expect(read.?.style == style);
        try testing.expect(@intFromEnum(read.?.style) == discriminant);

        clearUnderline(&properties);
        try testing.expect(underline(&properties) == null);
    }
}

test "an all-zero color is a stored value, not an absent one" {
    // The defect this names is a port that collapses `null` into a default and
    // then reports a stored transparent black as absent. Only `null`
    // distinguishes the two states, so the assertion has to be on `null`.
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setBackgroundColor(&properties, transparent_black);

    const read = backgroundColor(&properties);
    try testing.expect(read != null);
    try testing.expect(read.?.alpha == 0);
    try testing.expect(read.?.eql(transparent_black));

    clearBackgroundColor(&properties);
    try testing.expect(backgroundColor(&properties) == null);
}

test "a decoration drawn in a transparent solid line is a stored decoration" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    const transparent_solid: TextDecoration = .{ .style = .solid, .color = transparent_black };
    try setStrikethrough(&properties, transparent_solid);

    const read = strikethrough(&properties);
    try testing.expect(read != null);
    try testing.expect(read.?.eql(transparent_solid));

    clearStrikethrough(&properties);
    try testing.expect(strikethrough(&properties) == null);
}

test "clearing one color leaves the other two untouched" {
    // A clearer that removed every slot, or a store keyed by payload type
    // instead of by property id, would take `background_color` with it.
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    const dim_grey: Color = .{ .red = 1, .green = 1, .blue = 1, .alpha = 1 };
    const mid_grey: Color = .{ .red = 2, .green = 2, .blue = 2, .alpha = 2 };

    try setColorValue(&properties, opaque_white);
    try setBackgroundColor(&properties, dim_grey);
    try setForegroundColor(&properties, mid_grey);

    clearColorValue(&properties);

    try testing.expect(colorValue(&properties) == null);

    const background = backgroundColor(&properties);
    try testing.expect(background != null);
    try testing.expect(background.?.eql(dim_grey));

    const foreground = foregroundColor(&properties);
    try testing.expect(foreground != null);
    try testing.expect(foreground.?.eql(mid_grey));
}

test "clearing one decoration leaves the other two untouched" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setOverline(&properties, test_decoration);
    try setStrikethrough(&properties, .{ .style = .dashed, .color = opaque_white });
    try setUnderline(&properties, .{ .style = .wavy, .color = opaque_white });

    clearOverline(&properties);

    try testing.expect(overline(&properties) == null);

    const struck = strikethrough(&properties);
    try testing.expect(struck != null);
    try testing.expect(struck.?.style == .dashed);

    const under = underline(&properties);
    try testing.expect(under != null);
    try testing.expect(under.?.style == .wavy);
}

test "a second set replaces the value the first one wrote" {
    // `Properties.set` overwrites the slot. A setter that appended instead, or
    // kept the first write, would still pass the absent-then-present sweep.
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setColorValue(&properties, opaque_white);
    const replacement: Color = .{ .red = 1, .green = 2, .blue = 3, .alpha = 4 };
    try setColorValue(&properties, replacement);

    const color = colorValue(&properties);
    try testing.expect(color != null);
    try testing.expect(color.?.eql(replacement));

    try setUnderline(&properties, test_decoration);
    const redrawn: TextDecoration = .{ .style = .wavy, .color = replacement };
    try setUnderline(&properties, redrawn);

    const line = underline(&properties);
    try testing.expect(line != null);
    try testing.expect(line.?.eql(redrawn));
}

test "a setter on a store that cannot grow reports OutOfMemory and stores nothing" {
    // The residue upstream's `copy_type_setters` has: the assignment to
    // `self.values[index]` only runs after the push succeeds, so a failed push
    // must leave no entry behind and must not read back as a silent success.
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var properties: Properties = .init(failing.allocator());
    defer properties.deinit();

    try testing.expectError(error.OutOfMemory, setColorValue(&properties, opaque_white));
    try testing.expect(colorValue(&properties) == null);

    var second: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var decorations: Properties = .init(second.allocator());
    defer decorations.deinit();

    try testing.expectError(error.OutOfMemory, setUnderline(&decorations, test_decoration));
    try testing.expect(underline(&decorations) == null);
}
