//! One owned `PropertyValue` per payload shape, built from a seeded draw.
//!
//! **What this module covers.** `PropertyValue` is the union at
//! `src/schema/props/table.zig:341` and it carries 29 variants. This module
//! has one arm per variant, so a variant added to the union without a builder
//! is a compile error here rather than a shape nothing exercises. The figure
//! 262 in `docs/11-accesskit-c-abi.md:147` is a different domain: it counts the
//! variants of the 17 bare-tag enums in `include/zaccesskit.h`, and this
//! harness reaches those through `abi.zig`.
//!
//! **The slice forms.** A value that owns a slice is built in one of four
//! shapes: empty, one element, the widest slice this harness admits, and a
//! length the generator chooses. Empty and maximal are the two ends a
//! hand-written fixture usually misses, because a fixture writes one length.
//!
//! **The bounds.** `max_slice_len` and `max_action_count` are the harness's own
//! bounds, named here so a loop that walks a slice or an action list has one to
//! point at. Every walk over the property domain is bounded by
//! `table.propertyIdCount`, which is the count of rows in `property_descriptors`
//! and the only bound the schema layer names for that domain.
//!
//! **Ownership.** Every function here allocates through the `gpa` it takes
//! first, and every value it returns is owned by the caller. A caller that does
//! not keep a value releases it with `PropertyValue.deinit`.

const std = @import("std");

const assert = std.debug.assert;
const random = @import("random.zig");
const Random = random.Random;

const table = @import("../../src/schema/props/table.zig");
const ids = @import("../../src/schema/ids.zig");
const values = @import("../../src/schema/values.zig");
const node_enums = @import("../../src/schema/node_enums.zig");
const affine_mod = @import("../../src/schema/geometry/affine.zig");
const rect_mod = @import("../../src/schema/geometry/rect.zig");

const PropertyValue = table.PropertyValue;
const PropertyValueTag = table.PropertyValueTag;

const NodeId = ids.NodeId;
const TreeId = ids.TreeId;
const nodeIdFromContent = ids.nodeIdFromContent;
const treeIdFromBytes = ids.treeIdFromBytes;

const CustomAction = values.CustomAction;
const TextSelection = values.TextSelection;
const TextPosition = values.TextPosition;
const Color = values.Color;
const TextDecoration = values.TextDecoration;
const TextDecorationStyle = node_enums.TextDecorationStyle;

const Affine = affine_mod.Affine;
const Rect = rect_mod.Rect;
const rectInit = rect_mod.rectInit;

/// The widest owned slice one generated value carries, in elements.
///
/// The bound is the harness's own. It is wide enough that a slice crosses more
/// than one growth of the owned list on every path the store takes, and narrow
/// enough that the whole sweep stays inside the four gibibytes `build.zig:34`
/// gives a test shard.
pub const max_slice_len: usize = 1024;

/// The widest custom-action list one generated value carries.
///
/// The bound is the harness's own. Every action owns its own description, so a
/// list of eight descriptions is eight allocations and eight releases, which is
/// what the deep teardown at `table.zig:831` walks.
pub const max_action_count: usize = 8;

/// The shape of the owned slice a generated value carries.
///
/// The walk over this domain is the four members below, so a loop that chooses
/// a form reads `SliceForm.count` and not a literal.
pub const SliceForm = enum {
    /// No element at all, which is a slice with a valid pointer and no bytes.
    empty,
    /// Exactly one element.
    single,
    /// `max_slice_len` elements.
    maximal,
    /// A length the generator chooses in `1..max_slice_len`.
    drawn,

    /// The number of members, and the bound for every walk over this domain.
    pub const count: usize = @typeInfo(SliceForm).@"enum".fields.len;
};

/// The slice length `form` asks `source` for.
///
/// A drawn form never asks for zero elements, so `empty` stays the only source
/// of an empty slice and a defect in the empty path cannot hide behind the
/// drawn one.
pub fn sliceLen(source: *Random, form: SliceForm) usize {
    return switch (form) {
        .empty => 0,
        .single => 1,
        .maximal => max_slice_len,
        .drawn => source.below(max_slice_len) + 1,
    };
}

/// One member of the enumerable domain `E`, chosen by a draw.
///
/// The walk over the domain is `std.enums.values(E).len` wide, which is the
/// member count the type itself declares.
pub fn pickEnum(comptime E: type, source: *Random) E {
    const members = comptime std.enums.values(E);
    comptime assert(members.len > 0);
    return members[source.below(members.len)];
}

/// A `NodeId` whose content is the next draw.
pub fn buildNodeId(source: *Random) NodeId {
    return nodeIdFromContent(source.next());
}

/// A `TreeId` whose sixteen bytes are the next two draws.
pub fn buildTreeId(source: *Random) TreeId {
    var bytes: [16]u8 = undefined;
    bytes[0..8].* = std.mem.toBytes(@as(u64, source.next()));
    bytes[8..16].* = std.mem.toBytes(@as(u64, source.next()));
    return treeIdFromBytes(bytes);
}

/// A `Color` whose four channels are the bytes of one draw.
pub fn buildColor(source: *Random) Color {
    const lanes: [4]u8 = @bitCast(source.next());
    return .{ .red = lanes[0], .green = lanes[1], .blue = lanes[2], .alpha = lanes[3] };
}

/// A `TextDecoration` whose style is one member of its domain and whose color
/// is a drawn color.
pub fn buildTextDecoration(source: *Random) TextDecoration {
    return .{
        .style = pickEnum(TextDecorationStyle, source),
        .color = buildColor(source),
    };
}

/// A `TextPosition` at a drawn node and a drawn character offset.
pub fn buildTextPosition(source: *Random) TextPosition {
    return .{ .node_id = buildNodeId(source), .character_index = source.next() };
}

/// A `TextSelection` over two drawn positions.
///
/// The two positions share a node half the time, which is the caret case the
/// schema layer calls out at `values.zig:176`, and they differ half the time,
/// which is the extent case.
pub fn buildTextSelection(source: *Random) TextSelection {
    const anchor = buildTextPosition(source);
    const focus = if (source.flag()) anchor else buildTextPosition(source);
    return .{ .anchor = anchor, .focus = focus };
}

/// An `Affine` whose six coefficients are the next six draws.
///
/// A coefficient can be NaN or infinite. `affine.inverse` answers NaN for a
/// singular map, so a non-finite coefficient is a value the tree can hold.
pub fn buildAffine(source: *Random) Affine {
    var coeffs: [6]f64 = undefined;
    var index: usize = 0;
    while (index < coeffs.len) : (index += 1) coeffs[index] = source.real();
    return affine_mod.affineNew(coeffs);
}

/// A `Rect` whose four edges are the next four draws.
///
/// The corners are not sorted, so the rectangle may be inverted. `rectInit`
/// documents that and no caller rejects it.
pub fn buildRect(source: *Random) Rect {
    return rectInit(source.real(), source.real(), source.real(), source.real());
}

/// One member of the property domain, chosen by a draw.
///
/// The walk over the domain is `table.propertyIdCount` wide, which is the count
/// of rows in `property_descriptors`.
pub fn pickPropertyId(source: *Random) table.PropertyId {
    return @enumFromInt(@as(u8, @intCast(source.below(table.propertyIdCount))));
}

/// An owned `std.ArrayList(u8)` of `len` drawn bytes.
pub fn buildBytes(
    gpa: std.mem.Allocator,
    source: *Random,
    len: usize,
) std.mem.Allocator.Error!std.ArrayList(u8) {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try list.ensureTotalCapacity(gpa, len);
    var index: usize = 0;
    while (index < len) : (index += 1) list.appendAssumeCapacity(@truncate(source.next()));
    return list;
}

/// An owned `std.ArrayList(NodeId)` of `len` drawn ids.
pub fn buildNodeIds(
    gpa: std.mem.Allocator,
    source: *Random,
    len: usize,
) std.mem.Allocator.Error!std.ArrayList(NodeId) {
    var list: std.ArrayList(NodeId) = .empty;
    errdefer list.deinit(gpa);
    try list.ensureTotalCapacity(gpa, len);
    var index: usize = 0;
    while (index < len) : (index += 1) list.appendAssumeCapacity(buildNodeId(source));
    return list;
}

/// An owned `std.ArrayList(f32)` of `len` drawn coordinates.
///
/// A coordinate is a value in the unit interval, so it is finite. The port
/// accepts a non-finite coordinate as well, and `coord_vec` carries the
/// difference between the two nowhere, so a finite draw covers the layout and
/// the length and leaves the sign of a NaN to the fuzzer target.
pub fn buildCoords(
    gpa: std.mem.Allocator,
    source: *Random,
    len: usize,
) std.mem.Allocator.Error!std.ArrayList(f32) {
    var list: std.ArrayList(f32) = .empty;
    errdefer list.deinit(gpa);
    try list.ensureTotalCapacity(gpa, len);
    var index: usize = 0;
    while (index < len) : (index += 1) {
        list.appendAssumeCapacity(@floatCast(source.real()));
    }
    return list;
}

/// An owned list of `len` custom actions, each with its own description.
///
/// Every description takes the slice form the caller names, so the empty, the
/// single and the maximal description are each walked through the deep teardown
/// at `table.zig:831`.
pub fn buildActions(
    gpa: std.mem.Allocator,
    source: *Random,
    len: usize,
    form: SliceForm,
) std.mem.Allocator.Error!std.ArrayList(CustomAction) {
    var list: std.ArrayList(CustomAction) = .empty;
    errdefer releaseActions(gpa, &list);
    try list.ensureTotalCapacity(gpa, len);
    var index: usize = 0;
    while (index < len) : (index += 1) {
        const description = try buildBytes(gpa, source, sliceLen(source, form));
        // `CustomAction.init` copies the bytes it is given, so the drawn
        // description is released here rather than handed to the action.
        defer description.deinit(gpa);
        list.appendAssumeCapacity(try CustomAction.init(
            gpa,
            @bitCast(@as(u32, @truncate(source.next()))),
            description.items,
        ));
    }
    return list;
}

/// Releases every description a list of actions owns, then the list itself.
///
/// The shape is the one `table.zig:831` uses. `std.ArrayList.deinit` frees the
/// list buffer only, so a teardown that stops there leaks one description per
/// action.
pub fn releaseActions(gpa: std.mem.Allocator, list: *std.ArrayList(CustomAction)) void {
    for (list.items) |*action| action.deinit(gpa);
    list.deinit(gpa);
}

/// An owned value under `tag`, with its slice in the shape `form` asks for.
///
/// The switch has one arm per member of `PropertyValueTag`, so the union cannot
/// grow a variant this function cannot build. `none` is returned as itself: the
/// port's absence carries no payload and the store never holds it, so a caller
/// that wants to store the result must not pass that tag.
///
/// On `error.OutOfMemory` nothing is returned and the caller holds no
/// allocation: every arm that allocates guards its own list with an `errdefer`.
pub fn buildValue(
    source: *Random,
    gpa: std.mem.Allocator,
    tag: PropertyValueTag,
    form: SliceForm,
) std.mem.Allocator.Error!PropertyValue {
    return switch (tag) {
        .none => .none,
        .node_id_vec => @unionInit(
            PropertyValue,
            @tagName(tag),
            try buildNodeIds(gpa, source, sliceLen(source, form)),
        ),
        .node_id => @unionInit(PropertyValue, @tagName(tag), buildNodeId(source)),
        .string => @unionInit(
            PropertyValue,
            @tagName(tag),
            try buildBytes(gpa, source, sliceLen(source, form)),
        ),
        .f64_ => @unionInit(PropertyValue, @tagName(tag), source.real()),
        .f32_ => @unionInit(PropertyValue, @tagName(tag), @as(f32, @floatCast(source.real()))),
        .usize_ => @unionInit(PropertyValue, @tagName(tag), source.next()),
        .color => @unionInit(PropertyValue, @tagName(tag), buildColor(source)),
        .text_decoration => @unionInit(
            PropertyValue,
            @tagName(tag),
            buildTextDecoration(source),
        ),
        .length_vec => @unionInit(
            PropertyValue,
            @tagName(tag),
            try buildBytes(gpa, source, sliceLen(source, form)),
        ),
        .coord_vec => @unionInit(
            PropertyValue,
            @tagName(tag),
            try buildCoords(gpa, source, sliceLen(source, form)),
        ),
        .bool_ => @unionInit(PropertyValue, @tagName(tag), source.flag()),
        .invalid => @unionInit(PropertyValue, @tagName(tag), pickEnum(node_enums.Invalid, source)),
        .toggled => @unionInit(PropertyValue, @tagName(tag), pickEnum(node_enums.Toggled, source)),
        .live => @unionInit(PropertyValue, @tagName(tag), pickEnum(node_enums.Live, source)),
        .text_direction => @unionInit(
            PropertyValue,
            @tagName(tag),
            pickEnum(node_enums.TextDirection, source),
        ),
        .orientation => @unionInit(
            PropertyValue,
            @tagName(tag),
            pickEnum(node_enums.Orientation, source),
        ),
        .sort_direction => @unionInit(
            PropertyValue,
            @tagName(tag),
            pickEnum(node_enums.SortDirection, source),
        ),
        .aria_current => @unionInit(
            PropertyValue,
            @tagName(tag),
            pickEnum(node_enums.AriaCurrent, source),
        ),
        .auto_complete => @unionInit(
            PropertyValue,
            @tagName(tag),
            pickEnum(node_enums.AutoComplete, source),
        ),
        .has_popup => @unionInit(PropertyValue, @tagName(tag), pickEnum(node_enums.HasPopup, source)),
        .list_style => @unionInit(
            PropertyValue,
            @tagName(tag),
            pickEnum(node_enums.ListStyle, source),
        ),
        .text_align => @unionInit(
            PropertyValue,
            @tagName(tag),
            pickEnum(node_enums.TextAlign, source),
        ),
        .vertical_offset => @unionInit(
            PropertyValue,
            @tagName(tag),
            pickEnum(node_enums.VerticalOffset, source),
        ),
        .affine => @unionInit(PropertyValue, @tagName(tag), buildAffine(source)),
        .rect => @unionInit(PropertyValue, @tagName(tag), buildRect(source)),
        .text_selection => @unionInit(PropertyValue, @tagName(tag), buildTextSelection(source)),
        .custom_action_vec => @unionInit(
            PropertyValue,
            @tagName(tag),
            try buildActions(gpa, source, source.below(max_action_count + 1), form),
        ),
        .tree_id => @unionInit(PropertyValue, @tagName(tag), buildTreeId(source)),
    };
}