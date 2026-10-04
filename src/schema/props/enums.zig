//! The fourteen boolean and enum node properties of
//! `accesskit/src/lib.rs:2427-2506`, the hand expansion of the two macro
//! families `bool_property_methods!` and `unique_enum_property_methods!`.
//!
//! Each property is three free functions whose first parameter is the property
//! store, because a Zig declaration is a method only inside the struct body and
//! `schema/node.zig` owns `Node`. A caller writes `enums.toggled(node.properties())`
//! and every property keeps its own static type at the call site. The names are
//! the rule Z2 spelling of the identifiers the two invocations list, so
//! `is_expanded` becomes `isExpanded` and `aria_current` becomes `ariaCurrent`.
//!
//! **A setter takes the enum, never a byte.** The Rust setter takes the enum
//! type (`accesskit/src/lib.rs:1790`), and the `<type>FromInt` gate in
//! `schema/node_enums.zig` already turns a byte into a tag for the only two
//! places a bare byte arrives, the C seam and the D-Bus codec. Calling that
//! gate again here would make the same check two sources of truth, so no
//! function in this module returns an error a rejected byte could produce.
//!
//! **A property upstream stores as an enum stays an enum.** `orientation` and
//! `verticalOffset` carry two tags each, and ARIA gives both a third, so
//! neither is a `bool`. Only `isExpanded` and `isSelected` store a `bool`.
//!
//! **Every default is a named tag.** The fifth entry of each
//! `unique_enum_property_methods!` row is the tag upstream writes in its test,
//! and this module publishes it as `<property>_default`. Eleven of the twelve name
//! a tag other than discriminant 0. For ten of them the zero tag is the absence
//! of a statement, so a getter that returned it would be indistinguishable from
//! a missing property. `Invalid.true_` is the eleventh: it reports invalidity
//! without naming its kind. The twelfth, `has_popup_default`, is the zero tag
//! `menu`, which is the value `aria-haspopup` takes when the author writes
//! nothing. The two boolean properties have no default tag. An absent read is
//! `null`, and `null` means the state does not apply, which is not `false`.
//!
//! `TextDecorationStyle`, the thirteenth enum in `schema/node_enums.zig`, is
//! carried by `TextDecoration` and belongs to `props/colors.zig`. The eighteen
//! flags belong to `props/flags.zig`. No function here blocks, so none takes
//! `io`. A `bool` and a one-byte tag own no storage, so no setter here needs an
//! `errdefer`. The setters in `props/strings.zig` and `props/vectors.zig` do
//! need one, because a string or a list owns an allocation. No function here
//! takes an allocator: `Properties` carries the one it was created with, and
//! every write goes through it.

const std = @import("std");

const node_enums = @import("../node_enums.zig");
const table = @import("table.zig");

/// One row per `bool_property_methods!` entry, read from
/// `accesskit/src/lib.rs:2427-2450`.
const BoolProperty = struct {
    /// The property identifier every function in this family names.
    id: table.PropertyId,
    /// The upstream variant name, so a compile error names the property that
    /// moved rather than the module that reads it.
    upstream_name: []const u8,
};

/// One row per `unique_enum_property_methods!` entry, read from
/// `accesskit/src/lib.rs:2452-2506`.
const EnumProperty = struct {
    /// The property identifier, which is also the `PropertyValue` payload tag.
    id: table.PropertyId,
    /// The upstream enum type name, for a compile error that names the type.
    upstream_name: []const u8,
    /// The enum the payload tag must carry.
    enum_type: type,
    /// The Zig spelling of the tag the upstream fifth entry names as the
    /// default. A default that is not a tag of `enum_type` is a defect.
    default_tag: []const u8,
};

/// The two boolean properties, in upstream declaration order.
const bool_properties = [_]BoolProperty{
    .{ .id = .expanded, .upstream_name = "Expanded" },
    .{ .id = .selected, .upstream_name = "Selected" },
};

/// The twelve enum properties, in upstream declaration order.
const enum_properties = [_]EnumProperty{
    .{
        .id = .invalid,
        .upstream_name = "Invalid",
        .enum_type = node_enums.Invalid,
        .default_tag = "grammar",
    },
    .{
        .id = .toggled,
        .upstream_name = "Toggled",
        .enum_type = node_enums.Toggled,
        .default_tag = "true_",
    },
    .{
        .id = .live,
        .upstream_name = "Live",
        .enum_type = node_enums.Live,
        .default_tag = "polite",
    },
    .{
        .id = .text_direction,
        .upstream_name = "TextDirection",
        .enum_type = node_enums.TextDirection,
        .default_tag = "right_to_left",
    },
    .{
        .id = .orientation,
        .upstream_name = "Orientation",
        .enum_type = node_enums.Orientation,
        .default_tag = "vertical",
    },
    .{
        .id = .sort_direction,
        .upstream_name = "SortDirection",
        .enum_type = node_enums.SortDirection,
        .default_tag = "descending",
    },
    .{
        .id = .aria_current,
        .upstream_name = "AriaCurrent",
        .enum_type = node_enums.AriaCurrent,
        .default_tag = "true_",
    },
    .{
        .id = .auto_complete,
        .upstream_name = "AutoComplete",
        .enum_type = node_enums.AutoComplete,
        .default_tag = "list",
    },
    .{
        .id = .has_popup,
        .upstream_name = "HasPopup",
        .enum_type = node_enums.HasPopup,
        .default_tag = "menu",
    },
    .{
        .id = .list_style,
        .upstream_name = "ListStyle",
        .enum_type = node_enums.ListStyle,
        .default_tag = "disc",
    },
    .{
        .id = .text_align,
        .upstream_name = "TextAlign",
        .enum_type = node_enums.TextAlign,
        .default_tag = "right",
    },
    .{
        .id = .vertical_offset,
        .upstream_name = "VerticalOffset",
        .enum_type = node_enums.VerticalOffset,
        .default_tag = "superscript",
    },
};

/// The row naming `id`, or a compile error naming the property that has none.
/// The published defaults read their tag through this, so a constant and its row
/// cannot drift apart.
fn enumRow(comptime id: table.PropertyId) EnumProperty {
    inline for (enum_properties) |row| {
        if (row.id == id) return row;
    }
    @compileError(std.fmt.comptimePrint(
        "no unique_enum_property_methods! row names the property {s}",
        .{@tagName(id)},
    ));
}

/// The tag of `T` whose Zig name is `name`, or a compile error naming the enum
/// that does not declare it.
fn tagByName(comptime T: type, comptime name: []const u8) T {
    inline for (0..T.count) |value| {
        const tag: T = @enumFromInt(@as(u8, @intCast(value)));
        if (std.mem.eql(u8, @tagName(tag), name)) return tag;
    }
    @compileError(std.fmt.comptimePrint(
        "{s} declares no tag '{s}'",
        .{ @typeName(T), name },
    ));
}

/// The tag `accesskit/src/lib.rs:2457` names for `Invalid`: the input carries a
/// grammar error. The zero tag `true_` reports invalidity without naming a kind.
pub const invalid_default: node_enums.Invalid =
    tagByName(node_enums.Invalid, enumRow(.invalid).default_tag);

/// The tag `accesskit/src/lib.rs:2467` names for `Toggled`: the control is
/// checked. The zero tag `false_` is what an unchecked control reads as.
pub const toggled_default: node_enums.Toggled =
    tagByName(node_enums.Toggled, enumRow(.toggled).default_tag);

/// The tag `accesskit/src/lib.rs:2472` names for `Live`: a live region announces
/// at the polite priority. The zero tag `off` means the region is not announced.
pub const live_default: node_enums.Live =
    tagByName(node_enums.Live, enumRow(.live).default_tag);

/// The tag `accesskit/src/lib.rs:2474` names for `TextDirection`: the text runs
/// right to left. The zero tag is the direction of a language that states none.
pub const text_direction_default: node_enums.TextDirection =
    tagByName(node_enums.TextDirection, enumRow(.text_direction).default_tag);

/// The tag `accesskit/src/lib.rs:2479` names for `Orientation`: the control
/// stands vertically. The zero tag is the orientation of a control that states
/// none, such as a toolbar or a separator.
pub const orientation_default: node_enums.Orientation =
    tagByName(node_enums.Orientation, enumRow(.orientation).default_tag);

/// The tag `accesskit/src/lib.rs:2484` names for `SortDirection`: the column
/// sorts from the largest value up. The zero tag is the order of a table that
/// states no sort.
pub const sort_direction_default: node_enums.SortDirection =
    tagByName(node_enums.SortDirection, enumRow(.sort_direction).default_tag);

/// The tag `accesskit/src/lib.rs:2489` names for `AriaCurrent`: the node is the
/// current item of its set. The zero tag `false_` states that it is not, which
/// is a different claim from naming it as the current one.
pub const aria_current_default: node_enums.AriaCurrent =
    tagByName(node_enums.AriaCurrent, enumRow(.aria_current).default_tag);

/// The tag `accesskit/src/lib.rs:2494` names for `AutoComplete`: the prediction
/// appears as a list. The zero tag `inline_` completes inside the field instead.
pub const auto_complete_default: node_enums.AutoComplete =
    tagByName(node_enums.AutoComplete, enumRow(.auto_complete).default_tag);

/// The tag `accesskit/src/lib.rs:2499` names for `HasPopup`, and it is the zero
/// tag: `menu` is the value `aria-haspopup` takes when the author writes nothing.
pub const has_popup_default: node_enums.HasPopup =
    tagByName(node_enums.HasPopup, enumRow(.has_popup).default_tag);

/// The tag `accesskit/src/lib.rs:2501` names for `ListStyle`: the marker is a
/// filled disc. The zero tag `circle` is an outline marker.
pub const list_style_default: node_enums.ListStyle =
    tagByName(node_enums.ListStyle, enumRow(.list_style).default_tag);

/// The tag `accesskit/src/lib.rs:2503` names for `TextAlign`: the text runs to
/// the right margin. The zero tag is the alignment of a text run that states
/// none.
pub const text_align_default: node_enums.TextAlign =
    tagByName(node_enums.TextAlign, enumRow(.text_align).default_tag);

/// The tag `accesskit/src/lib.rs:2505` names for `VerticalOffset`: the text sits
/// above the baseline. The zero tag `subscript` sits below it. Neither tag means
/// the text sits on the baseline, because an absent property is how a node says
/// that.
pub const vertical_offset_default: node_enums.VerticalOffset =
    tagByName(node_enums.VerticalOffset, enumRow(.vertical_offset).default_tag);

/// Whether this node is expanded, collapsed, or neither. `null` means the state
/// does not apply to this node.
///
/// Setting the value to `false` means the node is collapsed. Omitting the
/// property means neither, so a getter that answered `false` for an absent
/// property would report a node as collapsed.
///
/// ARIA equivalent: <https://www.w3.org/TR/wai-aria-1.2/#aria-expanded>
pub fn isExpanded(properties: *const table.Properties) ?bool {
    const stored = properties.get(.expanded) orelse return null;
    return switch (stored.*) {
        .bool_ => |value| value,
        else => null,
    };
}

/// Stores `value` as the expansion state, replacing any state already stored.
pub fn setExpanded(properties: *table.Properties, value: bool) std.mem.Allocator.Error!void {
    try properties.set(.expanded, .{ .bool_ = value });
}

/// Drops the expansion state, so a later read is `null` and not `false`.
pub fn clearExpanded(properties: *table.Properties) void {
    properties.clear(.expanded);
}

/// Whether this node is selected or unselected. `null` means the concept of
/// selected does not apply to this node.
///
/// The absence of the property, rather than `false`, carries that meaning. Set it
/// to `false` only when it is right for a screen reader to announce "not
/// selected": the ambiguity of the flag in platform accessibility APIs has made an
/// extraneous "not selected" announcement a common annoyance.
///
/// ARIA equivalent: <https://www.w3.org/TR/wai-aria-1.2/#aria-selected>
pub fn isSelected(properties: *const table.Properties) ?bool {
    const stored = properties.get(.selected) orelse return null;
    return switch (stored.*) {
        .bool_ => |value| value,
        else => null,
    };
}

/// Stores `value` as the selection state, replacing any state already stored.
pub fn setSelected(properties: *table.Properties, value: bool) std.mem.Allocator.Error!void {
    try properties.set(.selected, .{ .bool_ = value });
}

/// Drops the selection state, so a later read is `null` and not `false`.
pub fn clearSelected(properties: *table.Properties) void {
    properties.clear(.selected);
}

/// Whether this node's input is invalid, and whether the error is about spelling
/// or grammar. `null` means the property is not set.
///
/// ARIA equivalent: <https://www.w3.org/TR/wai-aria-1.2/#aria-invalid>
pub fn invalid(properties: *const table.Properties) ?node_enums.Invalid {
    const stored = properties.get(.invalid) orelse return null;
    return switch (stored.*) {
        .invalid => |value| value,
        else => null,
    };
}

/// Stores `value` as the invalid state, replacing any state already stored.
pub fn setInvalid(
    properties: *table.Properties,
    value: node_enums.Invalid,
) std.mem.Allocator.Error!void {
    try properties.set(.invalid, .{ .invalid = value });
}

/// Drops the invalid state, so a later read is `null`.
pub fn clearInvalid(properties: *table.Properties) void {
    properties.clear(.invalid);
}

/// The checked or pressed state of a toggle control. `null` means the property is
/// not set.
///
/// ARIA states checked and pressed separately and this value is read against the
/// node's role, so one tag set serves both roles. `Toggled.mixed` has no boolean
/// spelling, which is why the property is an enum and not a `bool`.
///
/// ARIA equivalents: <https://www.w3.org/TR/wai-aria-1.2/#aria-checked> and
/// <https://www.w3.org/TR/wai-aria-1.2/#aria-pressed>
pub fn toggled(properties: *const table.Properties) ?node_enums.Toggled {
    const stored = properties.get(.toggled) orelse return null;
    return switch (stored.*) {
        .toggled => |value| value,
        else => null,
    };
}

/// Stores `value` as the toggle state, replacing any state already stored.
pub fn setToggled(
    properties: *table.Properties,
    value: node_enums.Toggled,
) std.mem.Allocator.Error!void {
    try properties.set(.toggled, .{ .toggled = value });
}

/// Drops the toggle state, so a later read is `null`.
pub fn clearToggled(properties: *table.Properties) void {
    properties.clear(.toggled);
}

/// The priority with which updates to this live region are announced. `null`
/// means the property is not set.
///
/// ARIA equivalent: <https://www.w3.org/TR/wai-aria-1.2/#aria-live>
pub fn live(properties: *const table.Properties) ?node_enums.Live {
    const stored = properties.get(.live) orelse return null;
    return switch (stored.*) {
        .live => |value| value,
        else => null,
    };
}

/// Stores `value` as the announcement priority, replacing any priority already
/// stored.
pub fn setLive(
    properties: *table.Properties,
    value: node_enums.Live,
) std.mem.Allocator.Error!void {
    try properties.set(.live, .{ .live = value });
}

/// Drops the announcement priority, so a later read is `null`.
pub fn clearLive(properties: *table.Properties) void {
    properties.clear(.live);
}

/// The direction in which this node's text is laid out. `null` means the property
/// is not set, and not that the text runs left to right.
pub fn textDirection(properties: *const table.Properties) ?node_enums.TextDirection {
    const stored = properties.get(.text_direction) orelse return null;
    return switch (stored.*) {
        .text_direction => |value| value,
        else => null,
    };
}

/// Stores `value` as the text direction, replacing any direction already stored.
pub fn setTextDirection(
    properties: *table.Properties,
    value: node_enums.TextDirection,
) std.mem.Allocator.Error!void {
    try properties.set(.text_direction, .{ .text_direction = value });
}

/// Drops the text direction, so a later read is `null`.
pub fn clearTextDirection(properties: *table.Properties) void {
    properties.clear(.text_direction);
}

/// Whether this node is oriented horizontally or vertically. `null` means the
/// property is not set.
///
/// This is an enum and not a `bool` because ARIA gives `aria-orientation` a third
/// value, `undefined`, and a port that collapsed the two tags here would have
/// nowhere to put it.
///
/// ARIA equivalent: <https://www.w3.org/TR/wai-aria-1.2/#aria-orientation>
pub fn orientation(properties: *const table.Properties) ?node_enums.Orientation {
    const stored = properties.get(.orientation) orelse return null;
    return switch (stored.*) {
        .orientation => |value| value,
        else => null,
    };
}

/// Stores `value` as the orientation, replacing any orientation already stored.
pub fn setOrientation(
    properties: *table.Properties,
    value: node_enums.Orientation,
) std.mem.Allocator.Error!void {
    try properties.set(.orientation, .{ .orientation = value });
}

/// Drops the orientation, so a later read is `null`.
pub fn clearOrientation(properties: *table.Properties) void {
    properties.clear(.orientation);
}

/// The direction in which items are sorted by this row or column header. `null`
/// means the property is not set, which is not the same as an ascending sort.
///
/// ARIA equivalent: <https://www.w3.org/TR/wai-aria-1.2/#aria-sort>
pub fn sortDirection(properties: *const table.Properties) ?node_enums.SortDirection {
    const stored = properties.get(.sort_direction) orelse return null;
    return switch (stored.*) {
        .sort_direction => |value| value,
        else => null,
    };
}

/// Stores `value` as the sort direction, replacing any direction already stored.
pub fn setSortDirection(
    properties: *table.Properties,
    value: node_enums.SortDirection,
) std.mem.Allocator.Error!void {
    try properties.set(.sort_direction, .{ .sort_direction = value });
}

/// Drops the sort direction, so a later read is `null`.
pub fn clearSortDirection(properties: *table.Properties) void {
    properties.clear(.sort_direction);
}

/// Whether and how this node represents the current item within a set. `null`
/// means the property is not set.
///
/// ARIA equivalent: <https://www.w3.org/TR/wai-aria-1.2/#aria-current>
pub fn ariaCurrent(properties: *const table.Properties) ?node_enums.AriaCurrent {
    const stored = properties.get(.aria_current) orelse return null;
    return switch (stored.*) {
        .aria_current => |value| value,
        else => null,
    };
}

/// Stores `value` as the current-item state, replacing any state already stored.
pub fn setAriaCurrent(
    properties: *table.Properties,
    value: node_enums.AriaCurrent,
) std.mem.Allocator.Error!void {
    try properties.set(.aria_current, .{ .aria_current = value });
}

/// Drops the current-item state, so a later read is `null`.
pub fn clearAriaCurrent(properties: *table.Properties) void {
    properties.clear(.aria_current);
}

/// How predictions are presented while the user enters text. `null` means the
/// property is not set.
///
/// ARIA equivalent: <https://www.w3.org/TR/wai-aria-1.2/#aria-autocomplete>
pub fn autoComplete(properties: *const table.Properties) ?node_enums.AutoComplete {
    const stored = properties.get(.auto_complete) orelse return null;
    return switch (stored.*) {
        .auto_complete => |value| value,
        else => null,
    };
}

/// Stores `value` as the prediction style, replacing any style already stored.
pub fn setAutoComplete(
    properties: *table.Properties,
    value: node_enums.AutoComplete,
) std.mem.Allocator.Error!void {
    try properties.set(.auto_complete, .{ .auto_complete = value });
}

/// Drops the prediction style, so a later read is `null`.
pub fn clearAutoComplete(properties: *table.Properties) void {
    properties.clear(.auto_complete);
}

/// The type of interactive popup that this node can trigger. `null` means the
/// property is not set.
///
/// ARIA equivalent: <https://www.w3.org/TR/wai-aria-1.2/#aria-haspopup>
pub fn hasPopup(properties: *const table.Properties) ?node_enums.HasPopup {
    const stored = properties.get(.has_popup) orelse return null;
    return switch (stored.*) {
        .has_popup => |value| value,
        else => null,
    };
}

/// Stores `value` as the popup type, replacing any type already stored.
pub fn setHasPopup(
    properties: *table.Properties,
    value: node_enums.HasPopup,
) std.mem.Allocator.Error!void {
    try properties.set(.has_popup, .{ .has_popup = value });
}

/// Drops the popup type, so a later read is `null`.
pub fn clearHasPopup(properties: *table.Properties) void {
    properties.clear(.has_popup);
}

/// The list marker style. Upstream carries this on list items only. `null` means
/// the property is not set.
pub fn listStyle(properties: *const table.Properties) ?node_enums.ListStyle {
    const stored = properties.get(.list_style) orelse return null;
    return switch (stored.*) {
        .list_style => |value| value,
        else => null,
    };
}

/// Stores `value` as the list marker style, replacing any style already stored.
pub fn setListStyle(
    properties: *table.Properties,
    value: node_enums.ListStyle,
) std.mem.Allocator.Error!void {
    try properties.set(.list_style, .{ .list_style = value });
}

/// Drops the list marker style, so a later read is `null`.
pub fn clearListStyle(properties: *table.Properties) void {
    properties.clear(.list_style);
}

/// How this node's text is aligned horizontally. `null` means the property is not
/// set, and not that the text is left aligned.
pub fn textAlign(properties: *const table.Properties) ?node_enums.TextAlign {
    const stored = properties.get(.text_align) orelse return null;
    return switch (stored.*) {
        .text_align => |value| value,
        else => null,
    };
}

/// Stores `value` as the horizontal alignment, replacing any alignment already
/// stored.
pub fn setTextAlign(
    properties: *table.Properties,
    value: node_enums.TextAlign,
) std.mem.Allocator.Error!void {
    try properties.set(.text_align, .{ .text_align = value });
}

/// Drops the horizontal alignment, so a later read is `null`.
pub fn clearTextAlign(properties: *table.Properties) void {
    properties.clear(.text_align);
}

/// Whether this node's text is rendered as subscript or superscript. `null` means
/// the text sits on the baseline.
///
/// This is an enum and not a `bool` because neither tag is the baseline: an
/// absent property is how a node reports baseline text, so the two tags cannot
/// carry the whole domain.
pub fn verticalOffset(properties: *const table.Properties) ?node_enums.VerticalOffset {
    const stored = properties.get(.vertical_offset) orelse return null;
    return switch (stored.*) {
        .vertical_offset => |value| value,
        else => null,
    };
}

/// Stores `value` as the vertical offset, replacing any offset already stored.
pub fn setVerticalOffset(
    properties: *table.Properties,
    value: node_enums.VerticalOffset,
) std.mem.Allocator.Error!void {
    try properties.set(.vertical_offset, .{ .vertical_offset = value });
}

/// Drops the vertical offset, so a later read is `null`.
pub fn clearVerticalOffset(properties: *table.Properties) void {
    properties.clear(.vertical_offset);
}

comptime {
    // The two invocations carry two entries and twelve, per docs section 1.5. A
    // row added here without an upstream entry, or an entry left without a row,
    // changes the number of functions this module publishes.
    if (bool_properties.len + enum_properties.len != 14) {
        @compileError(std.fmt.comptimePrint(
            "{d} rows, and the two invocations at accesskit/src/lib.rs:2427-2546 carry 14",
            .{bool_properties.len + enum_properties.len},
        ));
    }

    // Every function in this file names a `PropertyValue` payload tag directly,
    // so each row's tag must exist and must carry the type the row declares.
    for (bool_properties) |row| {
        const payload = "bool_";
        var found = false;
        for (@typeInfo(table.PropertyValue).@"union".fields) |field| {
            if (std.mem.eql(u8, field.name, payload)) {
                found = true;
                if (field.type != bool) {
                    @compileError(std.fmt.comptimePrint(
                        "PropertyValue.{s} carries {s}, and {s} stores a bool",
                        .{ payload, @typeName(field.type), row.upstream_name },
                    ));
                }
            }
        }
        if (!found) {
            @compileError(std.fmt.comptimePrint(
                "PropertyValue has no payload '{s}' for {s}",
                .{ payload, row.upstream_name },
            ));
        }
    }

    for (enum_properties) |row| {
        // The payload tag of an enum property is its own property identifier, so
        // a table that renames one without the other breaks every function here.
        var found = false;
        for (@typeInfo(table.PropertyValue).@"union".fields) |field| {
            if (std.mem.eql(u8, field.name, @tagName(row.id))) {
                found = true;
                if (field.type != row.enum_type) {
                    @compileError(std.fmt.comptimePrint(
                        "PropertyValue.{s} carries {s}, and {s} stores {s}",
                        .{
                            @tagName(row.id),
                            @typeName(field.type),
                            row.upstream_name,
                            @typeName(row.enum_type),
                        },
                    ));
                }
            }
        }
        if (!found) {
            @compileError(std.fmt.comptimePrint(
                "PropertyValue has no payload '{s}' for {s}",
                .{ @tagName(row.id), row.upstream_name },
            ));
        }
    }

    // Two rows that name one identifier publish two functions over one slot, so
    // the second set overwrites the first.
    for (bool_properties) |bool_row| {
        for (enum_properties) |enum_row_value| {
            if (bool_row.id == enum_row_value.id) {
                @compileError(std.fmt.comptimePrint(
                    "{s} and {s} name the same property identifier",
                    .{ bool_row.upstream_name, enum_row_value.upstream_name },
                ));
            }
        }
    }
}

/// Stores every tag of `T` in turn, reads each one back, and clears the property
/// between tags. A setter that stores one tag and drops the rest fails on the
/// second tag, and a clearer that does nothing fails on the read after it.
fn expectEveryTag(
    comptime T: type,
    comptime set: fn (*table.Properties, T) std.mem.Allocator.Error!void,
    comptime get: fn (*const table.Properties) ?T,
    comptime clear: fn (*table.Properties) void,
    properties: *table.Properties,
) !void {
    inline for (0..T.count) |value| {
        const tag: T = @enumFromInt(@as(u8, @intCast(value)));
        try set(properties, tag);
        try std.testing.expectEqual(@as(?T, tag), get(properties));
        clear(properties);
        try std.testing.expectEqual(@as(?T, null), get(properties));
    }
}

test "an absent expansion state reads null, not false" {
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    try std.testing.expectEqual(@as(?bool, null), isExpanded(&properties));
}

test "expanded round trips through both values" {
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    try setExpanded(&properties, true);
    try std.testing.expectEqual(@as(?bool, true), isExpanded(&properties));
    try setExpanded(&properties, false);
    try std.testing.expectEqual(@as(?bool, false), isExpanded(&properties));
}

test "clearing expanded reads false rather than the value before the clear" {
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    try setExpanded(&properties, true);
    clearExpanded(&properties);
    try std.testing.expectEqual(@as(?bool, null), isExpanded(&properties));
    try std.testing.expect(!(isExpanded(&properties) orelse false));
}

test "an absent selection state reads null, not false" {
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    try std.testing.expectEqual(@as(?bool, null), isSelected(&properties));
}

test "selected round trips through both values" {
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    try setSelected(&properties, true);
    try std.testing.expectEqual(@as(?bool, true), isSelected(&properties));
    try setSelected(&properties, false);
    try std.testing.expectEqual(@as(?bool, false), isSelected(&properties));
}

test "clearing selected reads false rather than the value before the clear" {
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    try setSelected(&properties, true);
    clearSelected(&properties);
    try std.testing.expectEqual(@as(?bool, null), isSelected(&properties));
    try std.testing.expect(!(isSelected(&properties) orelse false));
}

test "invalid round trips through every tag" {
    // The byte a C caller reads for the tag accesskit/src/lib.rs:2457 names.
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(invalid_default));
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    try expectEveryTag(node_enums.Invalid, setInvalid, invalid, clearInvalid, &properties);
}

test "toggled round trips through every tag" {
    // The byte a C caller reads for the tag accesskit/src/lib.rs:2467 names.
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(toggled_default));
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    try expectEveryTag(node_enums.Toggled, setToggled, toggled, clearToggled, &properties);
}

test "live round trips through every tag" {
    // The byte a C caller reads for the tag accesskit/src/lib.rs:2472 names.
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(live_default));
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    try expectEveryTag(node_enums.Live, setLive, live, clearLive, &properties);
}

test "textDirection round trips through every tag" {
    // The byte a C caller reads for the tag accesskit/src/lib.rs:2474 names.
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(text_direction_default));
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    try expectEveryTag(
        node_enums.TextDirection,
        setTextDirection,
        textDirection,
        clearTextDirection,
        &properties,
    );
}

test "orientation round trips through every tag" {
    // The byte a C caller reads for the tag accesskit/src/lib.rs:2479 names.
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(orientation_default));
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    try expectEveryTag(
        node_enums.Orientation,
        setOrientation,
        orientation,
        clearOrientation,
        &properties,
    );
}

test "sortDirection round trips through every tag" {
    // The byte a C caller reads for the tag accesskit/src/lib.rs:2484 names.
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(sort_direction_default));
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    try expectEveryTag(
        node_enums.SortDirection,
        setSortDirection,
        sortDirection,
        clearSortDirection,
        &properties,
    );
}

test "ariaCurrent round trips through every tag" {
    // The byte a C caller reads for the tag accesskit/src/lib.rs:2489 names.
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(aria_current_default));
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    try expectEveryTag(
        node_enums.AriaCurrent,
        setAriaCurrent,
        ariaCurrent,
        clearAriaCurrent,
        &properties,
    );
}

test "autoComplete round trips through every tag" {
    // The byte a C caller reads for the tag accesskit/src/lib.rs:2494 names.
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(auto_complete_default));
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    try expectEveryTag(
        node_enums.AutoComplete,
        setAutoComplete,
        autoComplete,
        clearAutoComplete,
        &properties,
    );
}

test "hasPopup round trips through every tag" {
    // The zero tag, which is the one accesskit/src/lib.rs:2499 names.
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(has_popup_default));
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    try expectEveryTag(node_enums.HasPopup, setHasPopup, hasPopup, clearHasPopup, &properties);
}

test "listStyle round trips through every tag" {
    // The byte a C caller reads for the tag accesskit/src/lib.rs:2501 names.
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(list_style_default));
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    try expectEveryTag(node_enums.ListStyle, setListStyle, listStyle, clearListStyle, &properties);
}

test "textAlign round trips through every tag" {
    // The byte a C caller reads for the tag accesskit/src/lib.rs:2503 names.
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(text_align_default));
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    try expectEveryTag(node_enums.TextAlign, setTextAlign, textAlign, clearTextAlign, &properties);
}

test "verticalOffset round trips through every tag" {
    // The byte a C caller reads for the tag accesskit/src/lib.rs:2505 names.
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(vertical_offset_default));
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    try expectEveryTag(
        node_enums.VerticalOffset,
        setVerticalOffset,
        verticalOffset,
        clearVerticalOffset,
        &properties,
    );
}

test "an enum property does not read the zero tag of another enum property" {
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    // `Orientation.horizontal` and `VerticalOffset.subscript` both carry zero,
    // so a store that used the wrong identifier would pass every test above.
    try setOrientation(&properties, .horizontal);
    try std.testing.expectEqual(
        @as(?node_enums.VerticalOffset, null),
        verticalOffset(&properties),
    );
    try std.testing.expectEqual(
        @as(?node_enums.Orientation, .horizontal),
        orientation(&properties),
    );

    clearOrientation(&properties);
    try setVerticalOffset(&properties, .subscript);
    try std.testing.expectEqual(
        @as(?node_enums.Orientation, null),
        orientation(&properties),
    );
    try std.testing.expectEqual(
        @as(?node_enums.VerticalOffset, .subscript),
        verticalOffset(&properties),
    );
}

test "a boolean property does not read an enum property" {
    var properties: table.Properties = .init(std.testing.allocator);
    defer properties.deinit();

    // `Toggled.true_` and the boolean `true` share a byte, so a store of one read
    // back through the other would pass a single round trip.
    try setToggled(&properties, .true_);
    try std.testing.expectEqual(@as(?bool, null), isExpanded(&properties));
    try std.testing.expectEqual(@as(?node_enums.Toggled, .true_), toggled(&properties));

    clearToggled(&properties);
    try setExpanded(&properties, true);
    try std.testing.expectEqual(@as(?node_enums.Toggled, null), toggled(&properties));
    try std.testing.expectEqual(@as(?bool, true), isExpanded(&properties));
}
