//! The thirteen small property enums of `accesskit/src/lib.rs:417-700`, one per
//! stored node property.
//!
//! Each type is the wire form of one property: one byte that a C caller and a
//! D-Bus peer both read as a number. The tag order is the upstream declaration
//! order, because upstream has no other order, and `variant_counts` pins that
//! order and each tag count at compile time.
//!
//! This module exports the thirteen enum types, one `count` on each, one
//! checked `<type>FromInt` gate per type, and `toggledFromBool`. It holds no
//! conversion between a tag and a name, because upstream declares none for
//! these thirteen types. `ScrollUnit` and `ScrollHint` live in
//! `schema/scroll_enums.zig`. No declaration here reads a clock, allocates, or
//! takes an allocator or an `std.Io`.

const std = @import("std");

/// Whether this node is oriented horizontally or vertically.
///
/// ARIA equivalent: <https://www.w3.org/TR/wai-aria-1.2/#aria-orientation>
pub const Orientation = enum(u8) {
    /// E.g. most toolbars and separators.
    horizontal = 0,
    /// E.g. menu or combo box.
    vertical = 1,

    /// The tag count, checked against `lib.rs:417-422`.
    pub const count: usize = 2;
};

/// The direction in which this node's text is laid out.
pub const TextDirection = enum(u8) {
    left_to_right = 0,
    right_to_left = 1,
    top_to_bottom = 2,
    bottom_to_top = 3,

    /// The tag count, checked against `lib.rs:439-444`.
    pub const count: usize = 4;
};

/// Whether this node's input is invalid, and whether the error is related to
/// spelling or grammar. No tag means the property is absent, because the
/// property that carries this type is optional upstream, so `true_` at
/// discriminant 0 is a real state and not a zero value.
///
/// ARIA equivalent: <https://www.w3.org/TR/wai-aria-1.2/#aria-invalid>
pub const Invalid = enum(u8) {
    /// The name keeps a trailing underscore because `true` is a Zig keyword.
    true_ = 0,
    grammar = 1,
    spelling = 2,

    /// The tag count, checked against `lib.rs:465-469`.
    pub const count: usize = 3;
};

/// The checked or pressed state of a toggle control. ARIA states the two
/// separately and this value is read against the node's role.
///
/// ARIA equivalents: <https://www.w3.org/TR/wai-aria-1.2/#aria-checked> and
/// <https://www.w3.org/TR/wai-aria-1.2/#aria-pressed>
pub const Toggled = enum(u8) {
    /// The name keeps a trailing underscore because `false` is a Zig keyword.
    false_ = 0,
    /// The name keeps a trailing underscore because `true` is a Zig keyword.
    true_ = 1,
    mixed = 2,

    /// The tag count, checked against `lib.rs:486-490`.
    pub const count: usize = 3;
};

/// The direction in which items are sorted by this row or column header.
///
/// ARIA equivalent: <https://www.w3.org/TR/wai-aria-1.2/#aria-sort>
pub const SortDirection = enum(u8) {
    ascending = 0,
    descending = 1,
    other = 2,

    /// The tag count, checked against `lib.rs:517-521`.
    pub const count: usize = 3;
};

/// Whether and how this node represents the current item within a set.
///
/// ARIA equivalent: <https://www.w3.org/TR/wai-aria-1.2/#aria-current>
pub const AriaCurrent = enum(u8) {
    /// The name keeps a trailing underscore because `false` is a Zig keyword.
    false_ = 0,
    /// The name keeps a trailing underscore because `true` is a Zig keyword.
    true_ = 1,
    page = 2,
    step = 3,
    location = 4,
    date = 5,
    time = 6,

    /// The tag count, checked against `lib.rs:538-546`.
    pub const count: usize = 7;
};

/// How predictions are presented while the user enters text.
///
/// ARIA equivalent: <https://www.w3.org/TR/wai-aria-1.2/#aria-autocomplete>
pub const AutoComplete = enum(u8) {
    /// The name keeps a trailing underscore because `inline` is a Zig keyword.
    /// ARIA names this value `inline`, so the tag is not a rename.
    inline_ = 0,
    list = 1,
    both = 2,

    /// The tag count, checked against `lib.rs:563-567`.
    pub const count: usize = 3;
};

/// The priority with which updates to this live region are announced.
///
/// ARIA equivalent: <https://www.w3.org/TR/wai-aria-1.2/#aria-live>
pub const Live = enum(u8) {
    off = 0,
    polite = 1,
    assertive = 2,

    /// The tag count, checked against `lib.rs:584-588`.
    pub const count: usize = 3;
};

/// The type of interactive popup that this node can trigger.
///
/// ARIA equivalent: <https://www.w3.org/TR/wai-aria-1.2/#aria-haspopup>
pub const HasPopup = enum(u8) {
    menu = 0,
    listbox = 1,
    tree = 2,
    grid = 3,
    dialog = 4,

    /// The tag count, checked against `lib.rs:605-611`.
    pub const count: usize = 5;
};

/// The list marker style of a list item. Upstream carries it on list items
/// only.
pub const ListStyle = enum(u8) {
    circle = 0,
    disc = 1,
    image = 2,
    numeric = 3,
    square = 4,
    /// Language specific ordering (alpha, roman, cjk-ideographic, etc...)
    other = 5,

    /// The tag count, checked against `lib.rs:628-636`.
    pub const count: usize = 6;
};

/// How this node's text is aligned horizontally.
pub const TextAlign = enum(u8) {
    left = 0,
    right = 1,
    center = 2,
    justify = 3,

    /// The tag count, checked against `lib.rs:653-658`.
    pub const count: usize = 4;
};

/// Whether this node's text is rendered as subscript or superscript.
pub const VerticalOffset = enum(u8) {
    subscript = 0,
    superscript = 1,

    /// The tag count, checked against `lib.rs:675-678`.
    pub const count: usize = 2;
};

/// The line style that `TextDecoration` carries beside the color of an
/// overline, strikethrough or underline.
pub const TextDecorationStyle = enum(u8) {
    solid = 0,
    dotted = 1,
    dashed = 2,
    double = 3,
    wavy = 4,

    /// The tag count, checked against `lib.rs:695-701`.
    pub const count: usize = 5;
};

/// The toggle state a `bool` names. The `bool` domain is two values wide and
/// the tag domain is three, so no `bool` reaches `Toggled.mixed`.
pub fn toggledFromBool(value: bool) Toggled {
    return if (value) .true_ else .false_;
}

// The C seam and the D-Bus codec each receive one of these bytes, and neither
// may trust it, so each type owns the gate that turns a byte into a tag or
// rejects it. `std.meta.intToEnum` is not that gate: it does not check in
// ReleaseFast, where an invalid discriminant is undefined behaviour.

/// The tag carrying `value`, or `null` when no tag does. A byte at or past
/// `Orientation.count` is rejected.
pub fn orientationFromInt(value: u8) ?Orientation {
    return switch (value) {
        0 => .horizontal,
        1 => .vertical,
        else => null,
    };
}

/// The tag carrying `value`, or `null` when no tag does. A byte at or past
/// `TextDirection.count` is rejected.
pub fn textDirectionFromInt(value: u8) ?TextDirection {
    return switch (value) {
        0 => .left_to_right,
        1 => .right_to_left,
        2 => .top_to_bottom,
        3 => .bottom_to_top,
        else => null,
    };
}

/// The tag carrying `value`, or `null` when no tag does. A byte at or past
/// `Invalid.count` is rejected.
pub fn invalidFromInt(value: u8) ?Invalid {
    return switch (value) {
        0 => .true_,
        1 => .grammar,
        2 => .spelling,
        else => null,
    };
}

/// The tag carrying `value`, or `null` when no tag does. A byte at or past
/// `Toggled.count` is rejected.
pub fn toggledFromInt(value: u8) ?Toggled {
    return switch (value) {
        0 => .false_,
        1 => .true_,
        2 => .mixed,
        else => null,
    };
}

/// The tag carrying `value`, or `null` when no tag does. A byte at or past
/// `SortDirection.count` is rejected.
pub fn sortDirectionFromInt(value: u8) ?SortDirection {
    return switch (value) {
        0 => .ascending,
        1 => .descending,
        2 => .other,
        else => null,
    };
}

/// The tag carrying `value`, or `null` when no tag does. A byte at or past
/// `AriaCurrent.count` is rejected.
pub fn ariaCurrentFromInt(value: u8) ?AriaCurrent {
    return switch (value) {
        0 => .false_,
        1 => .true_,
        2 => .page,
        3 => .step,
        4 => .location,
        5 => .date,
        6 => .time,
        else => null,
    };
}

/// The tag carrying `value`, or `null` when no tag does. A byte at or past
/// `AutoComplete.count` is rejected.
pub fn autoCompleteFromInt(value: u8) ?AutoComplete {
    return switch (value) {
        0 => .inline_,
        1 => .list,
        2 => .both,
        else => null,
    };
}

/// The tag carrying `value`, or `null` when no tag does. A byte at or past
/// `Live.count` is rejected.
pub fn liveFromInt(value: u8) ?Live {
    return switch (value) {
        0 => .off,
        1 => .polite,
        2 => .assertive,
        else => null,
    };
}

/// The tag carrying `value`, or `null` when no tag does. A byte at or past
/// `HasPopup.count` is rejected.
pub fn hasPopupFromInt(value: u8) ?HasPopup {
    return switch (value) {
        0 => .menu,
        1 => .listbox,
        2 => .tree,
        3 => .grid,
        4 => .dialog,
        else => null,
    };
}

/// The tag carrying `value`, or `null` when no tag does. A byte at or past
/// `ListStyle.count` is rejected.
pub fn listStyleFromInt(value: u8) ?ListStyle {
    return switch (value) {
        0 => .circle,
        1 => .disc,
        2 => .image,
        3 => .numeric,
        4 => .square,
        5 => .other,
        else => null,
    };
}

/// The tag carrying `value`, or `null` when no tag does. A byte at or past
/// `TextAlign.count` is rejected.
pub fn textAlignFromInt(value: u8) ?TextAlign {
    return switch (value) {
        0 => .left,
        1 => .right,
        2 => .center,
        3 => .justify,
        else => null,
    };
}

/// The tag carrying `value`, or `null` when no tag does. A byte at or past
/// `VerticalOffset.count` is rejected.
pub fn verticalOffsetFromInt(value: u8) ?VerticalOffset {
    return switch (value) {
        0 => .subscript,
        1 => .superscript,
        else => null,
    };
}

/// The tag carrying `value`, or `null` when no tag does. A byte at or past
/// `TextDecorationStyle.count` is rejected.
pub fn textDecorationStyleFromInt(value: u8) ?TextDecorationStyle {
    return switch (value) {
        0 => .solid,
        1 => .dotted,
        2 => .dashed,
        3 => .double,
        4 => .wavy,
        else => null,
    };
}

/// One enum in this file with the tag count `accesskit/src/lib.rs:417-700`
/// declares for it.
const VariantCount = struct {
    enum_type: type,
    /// The upstream type name, so a compile error names the enum that moved.
    upstream_name: []const u8,
    count: usize,
};

/// The counts upstream declares, read from `lib.rs:417-700` one enum at a time.
/// The `comptime` block below compares each row with the type it names, so a tag
/// added, dropped or reordered fails the build instead of moving a wire number.
const variant_counts = [_]VariantCount{
    .{ .enum_type = Orientation, .upstream_name = "Orientation", .count = 2 },
    .{ .enum_type = TextDirection, .upstream_name = "TextDirection", .count = 4 },
    .{ .enum_type = Invalid, .upstream_name = "Invalid", .count = 3 },
    .{ .enum_type = Toggled, .upstream_name = "Toggled", .count = 3 },
    .{ .enum_type = SortDirection, .upstream_name = "SortDirection", .count = 3 },
    .{ .enum_type = AriaCurrent, .upstream_name = "AriaCurrent", .count = 7 },
    .{ .enum_type = AutoComplete, .upstream_name = "AutoComplete", .count = 3 },
    .{ .enum_type = Live, .upstream_name = "Live", .count = 3 },
    .{ .enum_type = HasPopup, .upstream_name = "HasPopup", .count = 5 },
    .{ .enum_type = ListStyle, .upstream_name = "ListStyle", .count = 6 },
    .{ .enum_type = TextAlign, .upstream_name = "TextAlign", .count = 4 },
    .{ .enum_type = VerticalOffset, .upstream_name = "VerticalOffset", .count = 2 },
    .{ .enum_type = TextDecorationStyle, .upstream_name = "TextDecorationStyle", .count = 5 },
};

comptime {
    for (variant_counts) |row| {
        const fields = @typeInfo(row.enum_type).@"enum".fields;
        if (fields.len != row.count) {
            @compileError(std.fmt.comptimePrint(
                "{s}: {d} tags in Zig, {d} declared at accesskit/src/lib.rs:417-700",
                .{ row.upstream_name, fields.len, row.count },
            ));
        }
        if (@sizeOf(row.enum_type) != 1) {
            @compileError(std.fmt.comptimePrint(
                "{s}: {d} bytes, rule L2 makes a fieldless enum(u8) one byte",
                .{ row.upstream_name, @sizeOf(row.enum_type) },
            ));
        }
        if (@alignOf(row.enum_type) != 1) {
            @compileError(std.fmt.comptimePrint(
                "{s}: aligned to {d}, rule L2 makes a fieldless enum(u8) aligned to 1",
                .{ row.upstream_name, @alignOf(row.enum_type) },
            ));
        }
        for (fields, 0..) |field, discriminant| {
            if (field.value != discriminant) {
                @compileError(std.fmt.comptimePrint(
                    "{s}.{s} carries {d}, and rule Z5 copies the upstream order",
                    .{ row.upstream_name, field.name, field.value },
                ));
            }
        }
    }
}

// The second sweep calls each gate at compile time. A gate that drops a tag, or
// that accepts the byte past the last tag, fails here rather than at the first
// byte a C caller sends.
fn expectTotalGate(comptime T: type, comptime count: usize, comptime from_int: anytype) void {
    inline for (0..count) |value| {
        const tag = from_int(@intCast(value)) orelse @compileError(std.fmt.comptimePrint(
            "{s}: the gate rejects its own tag {d}",
            .{ @typeName(T), value },
        ));
        if (@intFromEnum(tag) != value) @compileError(std.fmt.comptimePrint(
            "{s}: the gate maps byte {d} to tag {s}, which carries {d}",
            .{ @typeName(T), value, @tagName(tag), @intFromEnum(tag) },
        ));
    }
    if (from_int(@intCast(count)) != null) @compileError(std.fmt.comptimePrint(
        "{s}: the gate accepts byte {d}, which is past the last tag",
        .{ @typeName(T), count },
    ));
}

comptime {
    expectTotalGate(Orientation, 2, orientationFromInt);
    expectTotalGate(TextDirection, 4, textDirectionFromInt);
    expectTotalGate(Invalid, 3, invalidFromInt);
    expectTotalGate(Toggled, 3, toggledFromInt);
    expectTotalGate(SortDirection, 3, sortDirectionFromInt);
    expectTotalGate(AriaCurrent, 7, ariaCurrentFromInt);
    expectTotalGate(AutoComplete, 3, autoCompleteFromInt);
    expectTotalGate(Live, 3, liveFromInt);
    expectTotalGate(HasPopup, 5, hasPopupFromInt);
    expectTotalGate(ListStyle, 6, listStyleFromInt);
    expectTotalGate(TextAlign, 4, textAlignFromInt);
    expectTotalGate(VerticalOffset, 2, verticalOffsetFromInt);
    expectTotalGate(TextDecorationStyle, 5, textDecorationStyleFromInt);
}

// The two comptime sweeps make every legal byte and the first illegal byte true
// for any gate that compiles. They cannot call a gate with a byte no descriptor
// table produces, and that byte is what a hostile C caller sends. The sweep
// below walks the whole domain at run time. Every enum above is dense from 0,
// so the domain has no hole that needs a case of its own.
fn expectByteDomain(comptime E: type, comptime name: []const u8, comptime from_int: anytype) !void {
    const fields = @typeInfo(E).@"enum".fields;
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        const answer = from_int(byte);
        // Every failure names the enum, because `@compileError` cannot report a
        // byte.
        if (value < fields.len) {
            const found = answer orelse {
                std.log.info("{s}: byte {d} carries {s}, and the gate named nothing", .{
                    name,
                    byte,
                    fields[value].name,
                });
                return error.LegalByteRejected;
            };
            if (@intFromEnum(found) != byte) {
                std.log.info("{s}: byte {d} carries {s}, and the gate named {s}", .{
                    name,
                    byte,
                    fields[value].name,
                    @tagName(found),
                });
                return error.ByteNamesAnotherTag;
            }
        } else if (answer) |found| {
            std.log.info("{s}: byte {d} names {s}, and no tag carries it", .{
                name,
                byte,
                @tagName(found),
            });
            return error.TagPastTheLastByte;
        }
    }
}

test "every FromInt gate answers the whole byte domain" {
    try expectByteDomain(Orientation, "Orientation", orientationFromInt);
    try expectByteDomain(TextDirection, "TextDirection", textDirectionFromInt);
    try expectByteDomain(Invalid, "Invalid", invalidFromInt);
    try expectByteDomain(Toggled, "Toggled", toggledFromInt);
    try expectByteDomain(SortDirection, "SortDirection", sortDirectionFromInt);
    try expectByteDomain(AriaCurrent, "AriaCurrent", ariaCurrentFromInt);
    try expectByteDomain(AutoComplete, "AutoComplete", autoCompleteFromInt);
    try expectByteDomain(Live, "Live", liveFromInt);
    try expectByteDomain(HasPopup, "HasPopup", hasPopupFromInt);
    try expectByteDomain(ListStyle, "ListStyle", listStyleFromInt);
    try expectByteDomain(TextAlign, "TextAlign", textAlignFromInt);
    try expectByteDomain(VerticalOffset, "VerticalOffset", verticalOffsetFromInt);
    try expectByteDomain(TextDecorationStyle, "TextDecorationStyle", textDecorationStyleFromInt);
}

test "toggledFromBool maps the whole bool domain" {
    try std.testing.expectEqual(Toggled.false_, toggledFromBool(false));
    try std.testing.expectEqual(Toggled.true_, toggledFromBool(true));
}
