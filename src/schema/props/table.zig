//! The property domain, the property value, and the store that holds them.
//!
//! `PropertyId` is the wire order: 87 property identifiers and no sentinel.
//! Absence is a `null` from `Properties.get`, which is a state a caller can
//! reach, where an `Unset` variant with no writer would be one it cannot.
//! `PropertyValue` is the payload union, one variant per payload shape.
//! `Properties` is the store, and it holds a sorted slice of id and value
//! pairs.
//!
//! **How to read `property_descriptors`.** One row per property, carrying the
//! property's `id`, the `PropertyValueTag` its payload uses, and that payload
//! type. It does the three jobs a Rust `macro_rules!` did that a Zig function
//! cannot, and each has one reader:
//!
//! * The id-to-payload-type relation: `PropertyPayloadType` reads the row for
//!   an id, and `propertyValueTagOf` reads the same relation at run time
//!   through `property_value_tags_by_id`.
//! * The member count: `propertyDescriptorCount` is `property_descriptors.len`.
//! * The bound for every loop over the property domain: `propertyIdCount` is
//!   `propertyDescriptorCount`, and a loop over the domain reads
//!   `while (index < propertyIdCount)`.
//!
//! The table is `comptime`-only, because a row holds a `type`. The `comptime`
//! block below pins that every tag of `PropertyId` appears exactly once, so a
//! property added without a row and a row written twice are both compile
//! errors. That is the compile-time property the 27 upstream `macro_rules!`
//! definitions gave the Rust type checker.
//!
//! **A row with no accessor behind it, and why the block below cannot see it.**
//! Every check in that block reads `property_descriptors` alone, so all of them
//! pass for a property that has a row and no getter, setter or clearer: the
//! row is well formed and the property exists. Such a property is reachable
//! only through `Properties.set`, whose sole assertion is `value != .none`.
//! `assertFamilyReachable` closes that, and its own section below explains how
//! seven local statements become a partition of the domain.
//!
//! **A function that returns a type is named in the type namespace.** Zig's own
//! rule, which this module keeps: `PropertyPayloadType` and
//! `PropertyValuePayloadType` answer `type`, so they take `PascalCase` even
//! though every other function here is `camelCase`. A future edit that lowers
//! them to `camelCase` to match their neighbours is a regression.
//!
//! **What this module does not carry, and why.**
//!
//! * `PropertyIndices`, the `[u8; 87]` slot array at
//!   `accesskit/src/lib.rs:1062`, and the `Unset` sentinel that indexed it, are
//!   both deleted. The store holds a sorted slice, so a cleared property
//!   LEAVES that slice, and absence is a `null` from `get` rather than a byte
//!   that compares equal to 87. Dropping the sentinel also makes an
//!   out-of-range property a compile error: with 87 tags `PropertyId` cannot
//!   hold 87, so no store call can name a property that does not exist.
//! * `PropertyValue::Affine(Box<Affine>)` and
//!   `PropertyValue::TextSelection(Box<TextSelection>)` at
//!   `accesskit/src/lib.rs:881` and `:883` hold plain values. A pointer in a
//!   union payload needs a recursive teardown, because releasing one value
//!   then has to reach through the pointer, and it costs one allocation per
//!   node per update for a type the union already holds inline.
//! * Upstream's position-based equality is deleted. Upstream compared two
//!   `Properties` through `PropertyIndices` slot positions
//!   (`accesskit/src/lib.rs:1084-1094`), and the 0.25.0 change that reuses
//!   property buffers on clone broke the slot correspondence that comparison
//!   relied on. A sorted slice makes the comparison structural: the same ids
//!   with the same payloads, whatever order either store was written in.
//!
//! **This is the core form of the value, not the C ABI form.** The ABI form
//! `docs/31-c-abi-design.md` section 4.0 describes holds only fixed-size
//! C-representable types, so a string crosses as `[*c]const u8` and a list as
//! `[*c]T` beside a count, because Zig 0.16.0 rejects an `extern union` with a
//! slice or a plain struct in it — the measured diagnostic is `extern unions
//! cannot contain fields of type 'array_list.Aligned(NodeId,null)'`. That ABI
//! union is built in `src/capi/marshal.zig`, which is the one place the two
//! meet, and `capi/marshal.zig` converts rather than stores. A `[*c]` pointer
//! never belongs in `Properties`: everything below uses the ergonomic form, an
//! owned `std.ArrayList` and an inline value, and nothing here crosses the C
//! boundary.
//!
//! **Offsets.** `PropertyValue` and `Property` are a tagged union and a plain
//! struct, so Zig 0.16.0 is free to reorder their fields. Only `@sizeOf` and
//! `@alignOf` are asserted below. No field offset is asserted for a type that
//! does not cross the C ABI.
//!
//! Nothing here blocks, so no function takes `io`. The store owns the
//! allocator it was created with, so `Properties.deinit` takes none and no
//! caller can allocate through one allocator and free through another.
//! Releasing a store is `deinit` once, which releases every value it holds;
//! copying a store is never a second owner.

const std = @import("std");

const ids = @import("../ids.zig");
const node_enums = @import("../node_enums.zig");
const values = @import("../values.zig");
const affine = @import("../geometry/affine.zig");
const rect = @import("../geometry/rect.zig");

const NodeId = ids.NodeId;
const nodeIdFromContent = ids.nodeIdFromContent;
const TreeId = ids.TreeId;
const treeIdFromBytes = ids.treeIdFromBytes;
const CustomAction = values.CustomAction;
const TextSelection = values.TextSelection;
const Color = values.Color;
const TextDecoration = values.TextDecoration;

const Invalid = node_enums.Invalid;
const Toggled = node_enums.Toggled;
const Live = node_enums.Live;
const TextDirection = node_enums.TextDirection;
const Orientation = node_enums.Orientation;
const SortDirection = node_enums.SortDirection;
const AriaCurrent = node_enums.AriaCurrent;
const AutoComplete = node_enums.AutoComplete;
const HasPopup = node_enums.HasPopup;
const ListStyle = node_enums.ListStyle;
const TextAlign = node_enums.TextAlign;
const VerticalOffset = node_enums.VerticalOffset;

const Affine = affine.Affine;
const affine_identity = affine.affine_identity;
const Rect = rect.Rect;
const rectInit = rect.rectInit;

/// The 18 one-bit flags a node carries beside its properties.
///
/// A flag is not a `PropertyId`: the flags live in one `u32` on `Node`
/// (`accesskit/src/lib.rs:1109`) and have no `PropertyValue` variant, because
/// a cleared flag is a clear bit rather than an absent entry. The
/// discriminant is the bit position, and it is the wire order.
pub const Flag = enum(u8) {
    hidden = 0,
    multiselectable = 1,
    required = 2,
    visited = 3,
    busy = 4,
    live_atomic = 5,
    modal = 6,
    touch_transparent = 7,
    read_only = 8,
    disabled = 9,
    italic = 10,
    clips_children = 11,
    is_line_breaking_object = 12,
    is_page_breaking_object = 13,
    is_spelling_error = 14,
    is_grammar_error = 15,
    is_search_match = 16,
    is_suggestion = 17,

    /// The flag count, checked against `lib.rs:802-819`.
    pub const count: usize = 18;
};

comptime {
    std.debug.assert(@typeInfo(Flag).@"enum".field_names.len == Flag.count);
    std.debug.assert(@backingInt(Flag.is_suggestion) == Flag.count - 1);
}

/// The bound on any walk over `Flag`.
pub const flagCount: usize = Flag.count;

/// The one-bit `u32` mask that carries `flag`.
///
/// This is the port of `Flag::mask` (`accesskit/src/lib.rs:823`), which is a
/// method upstream because `Flag` is a type it owns. A conversion lives at
/// file scope here, prefixed by the type it converts.
pub fn flagMask(flag: Flag) u32 {
    return @as(u32, 1) << @as(u5, @intCast(@backingInt(flag)));
}

/// True when `flag_set` carries the bit for `flag`.
pub fn flagSetContains(flag_set: u32, flag: Flag) bool {
    return flag_set & flagMask(flag) != 0;
}

/// The bits of `left` and `right` together. It carries the same unknown bits
/// `flagSetDifference` carries them.
pub fn flagSetUnion(left: u32, right: u32) u32 {
    return left | right;
}

/// The bits of `left` with the bits of `right` removed.
pub fn flagSetDifference(left: u32, right: u32) u32 {
    return left & ~right;
}

/// Every flag whose bit `flag_set` carries, ascending by discriminant.
///
/// `out` is filled at most `flagCount` deep and the result is the prefix that
/// was written, so a caller reads the count off the slice rather than off a
/// sentinel. The walk is bounded by `flagCount` and terminates.
pub fn flagSetMembers(flag_set: u32, out: *[flagCount]Flag) []const Flag {
    var len: usize = 0;
    inline for (comptime std.enums.values(Flag)) |flag| {
        if (flagSetContains(flag_set, flag)) {
            out[len] = flag;
            len += 1;
        }
    }
    return out[0..len];
}

/// The identifier of one property a node may carry.
///
/// The discriminants are copied unchanged from
/// `accesskit/src/lib.rs:895-1005`, and the order is the wire order: a port
/// that reorders them changes the serialized numbers. Upstream's last variant
/// is the `Unset` sentinel at `accesskit/src/lib.rs:1008`; it is not carried
/// here, because a fixed byte array needs a "no slot" marker and a sorted
/// slice does not.
pub const PropertyId = enum(u8) {
    // NodeIdVec
    children = 0,
    controls = 1,
    details = 2,
    described_by = 3,
    flow_to = 4,
    labelled_by = 5,
    owns = 6,
    radio_group = 7,

    // NodeId
    active_descendant = 8,
    error_message = 9,
    in_page_link_target = 10,
    member_of = 11,
    next_on_line = 12,
    previous_on_line = 13,
    popup_for = 14,

    // String
    label = 15,
    description = 16,
    value = 17,
    access_key = 18,
    author_id = 19,
    class_name = 20,
    font_family = 21,
    html_id = 22,
    html_tag = 23,
    inner_html = 24,
    keyboard_shortcut = 25,
    language = 26,
    placeholder = 27,
    role_description = 28,
    state_description = 29,
    tooltip = 30,
    url = 31,
    row_index_text = 32,
    column_index_text = 33,
    braille_label = 34,
    braille_role_description = 35,

    // f64
    scroll_x = 36,
    scroll_x_min = 37,
    scroll_x_max = 38,
    scroll_y = 39,
    scroll_y_min = 40,
    scroll_y_max = 41,
    numeric_value = 42,
    min_numeric_value = 43,
    max_numeric_value = 44,
    numeric_value_step = 45,
    numeric_value_jump = 46,

    // f32
    font_size = 47,
    font_weight = 48,

    // usize
    row_count = 49,
    column_count = 50,
    row_index = 51,
    column_index = 52,
    row_span = 53,
    column_span = 54,
    level = 55,
    size_of_set = 56,
    position_in_set = 57,

    // Color
    color_value = 58,
    background_color = 59,
    foreground_color = 60,

    // TextDecoration
    overline = 61,
    strikethrough = 62,
    underline = 63,

    // LengthVec
    character_lengths = 64,
    word_starts = 65,

    // CoordVec
    character_positions = 66,
    character_widths = 67,

    // bool
    expanded = 68,
    selected = 69,

    // Unique enums
    invalid = 70,
    toggled = 71,
    live = 72,
    text_direction = 73,
    orientation = 74,
    sort_direction = 75,
    aria_current = 76,
    auto_complete = 77,
    has_popup = 78,
    list_style = 79,
    text_align = 80,
    vertical_offset = 81,

    // Other
    transform = 82,
    bounds = 83,
    text_selection = 84,
    custom_actions = 85,
    tree_id = 86,
};

/// Every tag `PropertyId` carries, which is every property and nothing else.
pub const propertyIdTagCount: usize = @typeInfo(PropertyId).@"enum".field_names.len;

/// The tag carrying `value`, or `null` when no tag does.
///
/// A byte at or past `propertyIdTagCount` names no property and is rejected
/// here rather than producing a value no switch can name.
pub fn propertyIdFromInt(value: u8) ?PropertyId {
    if (value >= propertyIdTagCount) return null;
    return @fromBackingInt(@intCast(value));
}

/// The payload of one property: its shape, and nothing else.
///
/// The variant order is copied from `accesskit/src/lib.rs:856-886`. `none` is
/// the port's absence, and the port never stores it: a cleared property leaves
/// the slice instead. `f64_`, `f32_` and `bool_` keep a trailing underscore
/// because each collides with a Zig primitive keyword, exactly as
/// `node_enums.zig` uses `true_` and `inline_`.
///
/// The union is the ergonomic form, never the C ABI form: a string is an
/// owned `std.ArrayList(u8)` and a list is an owned `std.ArrayList(T)`, so a
/// copy of a value shares one buffer and one `deinit` releases it. See the
/// module comment on where the ABI form lives.
pub const PropertyValue = union(enum) {
    /// The value a getter sees for a property the store does not hold. The
    /// store never stores it, so it needs no release.
    none,
    node_id_vec: std.ArrayList(NodeId),
    node_id: NodeId,
    string: std.ArrayList(u8),
    f64_: f64,
    f32_: f32,
    usize_: usize,
    color: Color,
    text_decoration: TextDecoration,
    length_vec: std.ArrayList(u8),
    coord_vec: std.ArrayList(f32),
    bool_: bool,
    invalid: Invalid,
    toggled: Toggled,
    live: Live,
    text_direction: TextDirection,
    orientation: Orientation,
    sort_direction: SortDirection,
    aria_current: AriaCurrent,
    auto_complete: AutoComplete,
    has_popup: HasPopup,
    list_style: ListStyle,
    text_align: TextAlign,
    vertical_offset: VerticalOffset,
    affine: Affine,
    rect: Rect,
    text_selection: TextSelection,
    custom_action_vec: std.ArrayList(CustomAction),
    tree_id: TreeId,

    /// The tag `self` carries.
    ///
    /// Reading the tag through a member rather than through `@tagName` keeps
    /// every switch over the payload domain exhaustive: a new variant added
    /// to `PropertyValue` is a compile error at each of them. The result is a
    /// copy of one byte, not a copy of the payload.
    pub fn getTag(self: PropertyValue) PropertyValueTag {
        return std.meta.activeTag(self);
    }

    /// Releases the buffers `self` owns through `gpa`, and leaves `self` dead.
    ///
    /// The allocator must be the one the store holding `self` was created
    /// with. Every arm runs, because `self` is overwritten rather than kept,
    /// so the value is unreadable afterwards and a second call is a double
    /// free. A caller that reads a field anyway gets a trap in Debug rather
    /// than a slice into a buffer the switch above released.
    pub fn deinit(self: *PropertyValue, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .none => {},
            .node_id_vec => |*list| list.deinit(gpa),
            .node_id => {},
            .string => |*bytes| bytes.deinit(gpa),
            .f64_ => {},
            .f32_ => {},
            .usize_ => {},
            .color => {},
            .text_decoration => {},
            .length_vec => |*bytes| bytes.deinit(gpa),
            .coord_vec => |*points| points.deinit(gpa),
            .bool_ => {},
            .invalid => {},
            .toggled => {},
            .live => {},
            .text_direction => {},
            .orientation => {},
            .sort_direction => {},
            .aria_current => {},
            .auto_complete => {},
            .has_popup => {},
            .list_style => {},
            .text_align => {},
            .vertical_offset => {},
            .affine => {},
            .rect => {},
            .text_selection => {},
            .custom_action_vec => |*actions| deinitActions(gpa, actions),
            .tree_id => {},
        }
        // SAFETY: every buffer this union owns was released by the switch above,
        // and no statement after it reads `self`. A caller that reads a field
        // anyway gets a trap in Debug instead of a slice into a freed buffer.
        self.* = undefined;
    }

    /// Whether both values carry the same tag and the same payload.
    ///
    /// A `f64` or `f32` payload holding NaN answers `false` against itself,
    /// because upstream's derived `PartialEq` on `PropertyValue`
    /// (`accesskit/src/lib.rs:855`) compares the floats that way. Owned
    /// payloads are compared by their bytes and their elements, never by their
    /// addresses, so two equal values in two different buffers answer `true`.
    pub fn eql(self: PropertyValue, other: PropertyValue) bool {
        if (getTag(self) != getTag(other)) return false;
        return switch (self) {
            .none => true,
            .node_id_vec => |own| eqlNodeIds(own.items, other.node_id_vec.items),
            .node_id => |own| own.eql(other.node_id),
            .string => |own| std.mem.eql(u8, own.items, other.string.items),
            .f64_ => |own| own == other.f64_,
            .f32_ => |own| own == other.f32_,
            .usize_ => |own| own == other.usize_,
            .color => |own| own.eql(other.color),
            .text_decoration => |own| own.eql(other.text_decoration),
            .length_vec => |own| std.mem.eql(u8, own.items, other.length_vec.items),
            .coord_vec => |own| std.mem.eql(f32, own.items, other.coord_vec.items),
            .bool_ => |own| own == other.bool_,
            .invalid => |own| own == other.invalid,
            .toggled => |own| own == other.toggled,
            .live => |own| own == other.live,
            .text_direction => |own| own == other.text_direction,
            .orientation => |own| own == other.orientation,
            .sort_direction => |own| own == other.sort_direction,
            .aria_current => |own| own == other.aria_current,
            .auto_complete => |own| own == other.auto_complete,
            .has_popup => |own| own == other.has_popup,
            .list_style => |own| own == other.list_style,
            .text_align => |own| own == other.text_align,
            .vertical_offset => |own| own == other.vertical_offset,
            .affine => |own| std.meta.eql(own, other.affine),
            .rect => |own| std.meta.eql(own, other.rect),
            .text_selection => |own| own.eql(other.text_selection),
            .custom_action_vec => |own| eqlActions(own.items, other.custom_action_vec.items),
            .tree_id => |own| own.eql(other.tree_id),
        };
    }

    /// Writes `self` to `writer` as its tag name and its payload.
    ///
    /// A method rather than a file-scope function so a caller holding the
    /// union can write `value.format(writer)`. `{f}` does NOT reach it:
    /// `std/Io/Writer.zig:1077` resolves `{f}` through the value's tag type
    /// first, which on Zig 0.16.0 lands on the union's tag enum rather than on
    /// the union, so the member call is the only spelling that works here.
    pub fn format(self: PropertyValue, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .none => try writer.writeAll("none"),
            .node_id_vec => |list| try writer.print("node_id_vec({d})", .{list.items.len}),
            .node_id => |value| try writer.print("node_id({d})", .{value.value}),
            .string => |bytes| try writer.print("string({d})", .{bytes.items.len}),
            .f64_ => |value| try writer.print("f64({d})", .{value}),
            .f32_ => |value| try writer.print("f32({d})", .{value}),
            .usize_ => |value| try writer.print("usize({d})", .{value}),
            .color => |value| try writer.print(
                "color(#{x:0>2}{x:0>2}{x:0>2}{x:0>2})",
                .{ value.red, value.green, value.blue, value.alpha },
            ),
            .text_decoration => |value| try writer.print(
                "text_decoration({s},{d})",
                .{ @tagName(value.style), value.color.red },
            ),
            .length_vec => |bytes| try writer.print("length_vec({d})", .{bytes.items.len}),
            .coord_vec => |points| try writer.print("coord_vec({d})", .{points.items.len}),
            .bool_ => |value| try writer.print("bool({})", .{value}),
            .invalid => |value| try writer.print("invalid({s})", .{@tagName(value)}),
            .toggled => |value| try writer.print("toggled({s})", .{@tagName(value)}),
            .live => |value| try writer.print("live({s})", .{@tagName(value)}),
            .text_direction => |value| try writer.print("text_direction({s})", .{@tagName(value)}),
            .orientation => |value| try writer.print("orientation({s})", .{@tagName(value)}),
            .sort_direction => |value| try writer.print("sort_direction({s})", .{@tagName(value)}),
            .aria_current => |value| try writer.print("aria_current({s})", .{@tagName(value)}),
            .auto_complete => |value| try writer.print("auto_complete({s})", .{@tagName(value)}),
            .has_popup => |value| try writer.print("has_popup({s})", .{@tagName(value)}),
            .list_style => |value| try writer.print("list_style({s})", .{@tagName(value)}),
            .text_align => |value| try writer.print("text_align({s})", .{@tagName(value)}),
            .vertical_offset => |value| try writer.print("vertical_offset({s})", .{
                @tagName(value),
            }),
            .affine => |value| try writer.print("affine({d})", .{value.coeffs[0]}),
            .rect => |value| try writer.print(
                "rect({d},{d},{d},{d})",
                .{ value.x0, value.y0, value.x1, value.y1 },
            ),
            .text_selection => |value| try writer.print(
                "text_selection({d},{d})",
                .{ value.anchor.character_index, value.focus.character_index },
            ),
            .custom_action_vec => |actions| try writer.print("custom_action_vec({d})", .{
                actions.items.len,
            }),
            .tree_id => |value| try writer.print("tree_id({x})", .{&value.bytes}),
        }
    }
};

/// The tag `PropertyValue` carries.
pub const PropertyValueTag = std.meta.Tag(PropertyValue);

comptime {
    // The tag domain is a 29-value `enum(u8)` at offset 0 under rule L2. The
    // payload starts at offset 8 because the strictest payload alignment is 8,
    // from `NodeId`, `f64`, `usize`, `Rect` and `Affine`. The largest payload
    // is `Affine` at 48 bytes, so the union ends at 56. `docs/10` section 2
    // predicts 40 by naming `Rect` the largest payload; it is not, because
    // upstream boxes `Affine` and this port does not.
    std.debug.assert(@sizeOf(PropertyValue) == 56);
    std.debug.assert(@alignOf(PropertyValue) == 8);
    std.debug.assert(@sizeOf(PropertyValueTag) == 1);
    std.debug.assert(@sizeOf([1]PropertyValue) == 56);
}

/// The payload type `tag` carries.
///
/// A `comptime` read of the tag domain, so a caller may write
/// `propertyValueFrom(.string, owned)` and have the compiler check the
/// pairing. `none` carries `void`, because absence has no payload.
pub fn PropertyValuePayloadType(comptime tag: PropertyValueTag) type {
    return switch (tag) {
        .none => void,
        .node_id_vec => std.ArrayList(NodeId),
        .node_id => NodeId,
        .string => std.ArrayList(u8),
        .f64_ => f64,
        .f32_ => f32,
        .usize_ => usize,
        .color => Color,
        .text_decoration => TextDecoration,
        .length_vec => std.ArrayList(u8),
        .coord_vec => std.ArrayList(f32),
        .bool_ => bool,
        .invalid => Invalid,
        .toggled => Toggled,
        .live => Live,
        .text_direction => TextDirection,
        .orientation => Orientation,
        .sort_direction => SortDirection,
        .aria_current => AriaCurrent,
        .auto_complete => AutoComplete,
        .has_popup => HasPopup,
        .list_style => ListStyle,
        .text_align => TextAlign,
        .vertical_offset => VerticalOffset,
        .affine => Affine,
        .rect => Rect,
        .text_selection => TextSelection,
        .custom_action_vec => std.ArrayList(CustomAction),
        .tree_id => TreeId,
    };
}

/// The number of tags `PropertyValue` carries.
///
/// A decoder compares against this rather than against the size of the tag
/// type, because a tag type is one byte and this is 29.
pub fn propertyValueTagCount() usize {
    return @typeInfo(PropertyValueTag).@"enum".field_names.len;
}

/// A value carrying `payload` under `tag`.
///
/// The payload type comes from `PropertyValuePayloadType`, so a call that
/// pairs a payload with the wrong tag is a compile error. `none` needs no
/// payload and ignores one: `propertyValueFrom(.none, {})`.
pub fn propertyValueFrom(
    comptime tag: PropertyValueTag,
    payload: PropertyValuePayloadType(tag),
) PropertyValue {
    if (tag == .none) return .none;
    return @unionInit(PropertyValue, @tagName(tag), payload);
}

/// A deep copy of `source` through `gpa`, independent of it.
///
/// The port of `PropertyValue::clone` (`accesskit/src/lib.rs:1012`), which
/// upstream hand-wrote in 0.25.0 so the two paths of `clone` and `clone_from`
/// could not drift. A copy is at file scope because it produces a value rather
/// than answering a question about one.
///
/// On `error.OutOfMemory` nothing is returned and the caller keeps every
/// buffer `source` holds.
pub fn propertyValueClone(
    gpa: std.mem.Allocator,
    source: PropertyValue,
) std.mem.Allocator.Error!PropertyValue {
    return switch (source) {
        .none => .none,
        .node_id_vec => |list| .{ .node_id_vec = try cloneList(NodeId, gpa, list.items) },
        .node_id => |value| .{ .node_id = value },
        .string => |bytes| .{ .string = try cloneList(u8, gpa, bytes.items) },
        .f64_ => |value| .{ .f64_ = value },
        .f32_ => |value| .{ .f32_ = value },
        .usize_ => |value| .{ .usize_ = value },
        .color => |value| .{ .color = value },
        .text_decoration => |value| .{ .text_decoration = value },
        .length_vec => |bytes| .{ .length_vec = try cloneList(u8, gpa, bytes.items) },
        .coord_vec => |points| .{ .coord_vec = try cloneList(f32, gpa, points.items) },
        .bool_ => |value| .{ .bool_ = value },
        .invalid => |value| .{ .invalid = value },
        .toggled => |value| .{ .toggled = value },
        .live => |value| .{ .live = value },
        .text_direction => |value| .{ .text_direction = value },
        .orientation => |value| .{ .orientation = value },
        .sort_direction => |value| .{ .sort_direction = value },
        .aria_current => |value| .{ .aria_current = value },
        .auto_complete => |value| .{ .auto_complete = value },
        .has_popup => |value| .{ .has_popup = value },
        .list_style => |value| .{ .list_style = value },
        .text_align => |value| .{ .text_align = value },
        .vertical_offset => |value| .{ .vertical_offset = value },
        .affine => |value| .{ .affine = value },
        .rect => |value| .{ .rect = value },
        .text_selection => |value| .{ .text_selection = value },
        .custom_action_vec => |actions| .{
            .custom_action_vec = try cloneActions(gpa, actions.items),
        },
        .tree_id => |value| .{ .tree_id = value },
    };
}

/// Copies `source` into `dest`, keeping `dest`'s buffers where it can.
///
/// The port of `PropertyValue::clone_from`
/// (`accesskit/src/lib.rs:1046`), and the reason that function is hand-written
/// at all. Every owned payload reuses `dest`'s allocation when `dest` already
/// carries the same tag, which is what makes cloning a whole store a second
/// time cost no store-level allocation.
///
/// `dest` may be `source`: `propertyValueCloneInto(gpa, &value, value)` asks
/// for a copy of a value into itself, and nothing forbids a caller from
/// writing it. That is a no-op, and the first statement below says so, because
/// every arm releases what it is about to rebuild from and a self-clone has
/// nothing left to rebuild.
///
/// On `error.OutOfMemory` a reused custom-action payload remains unchanged.
/// Other reused list payloads are empty and still owned by `dest` if their
/// append fails. Every earlier entry of the store is unchanged.
pub fn propertyValueCloneInto(
    gpa: std.mem.Allocator,
    dest: *PropertyValue,
    source: PropertyValue,
) std.mem.Allocator.Error!void {
    // The one case that is not two values. A caller may pass one value twice,
    // and then `dest` *is* `source`: every arm below would release the
    // descriptions and the buffer it is about to read back out of, and the
    // first append can move that buffer out from under the loop. There is
    // nothing to copy, so the answer is to do nothing, before any teardown.
    if (sameOwnedBuffer(dest.*, source)) return;

    // A destination carrying a different tag owns something the assignment
    // below would drop on the floor, so it is released first. A destination
    // carrying the same tag keeps its allocation, which is the whole point.
    const reuse = dest.getTag() == source.getTag();
    switch (source) {
        .none => dest.* = .none,
        .node_id_vec => |list| {
            if (reuse) {
                dest.*.node_id_vec.clearRetainingCapacity();
                try dest.*.node_id_vec.appendSlice(gpa, list.items);
            } else {
                dest.* = .{ .node_id_vec = try cloneList(NodeId, gpa, list.items) };
            }
        },
        .node_id => |value| dest.* = .{ .node_id = value },
        .string => |bytes| {
            if (reuse) {
                dest.*.string.clearRetainingCapacity();
                try dest.*.string.appendSlice(gpa, bytes.items);
            } else {
                dest.* = .{ .string = try cloneList(u8, gpa, bytes.items) };
            }
        },
        .f64_ => |value| dest.* = .{ .f64_ = value },
        .f32_ => |value| dest.* = .{ .f32_ = value },
        .usize_ => |value| dest.* = .{ .usize_ = value },
        .color => |value| dest.* = .{ .color = value },
        .text_decoration => |value| dest.* = .{ .text_decoration = value },
        .length_vec => |bytes| {
            if (reuse) {
                dest.*.length_vec.clearRetainingCapacity();
                try dest.*.length_vec.appendSlice(gpa, bytes.items);
            } else {
                dest.* = .{ .length_vec = try cloneList(u8, gpa, bytes.items) };
            }
        },
        .coord_vec => |points| {
            if (reuse) {
                dest.*.coord_vec.clearRetainingCapacity();
                try dest.*.coord_vec.appendSlice(gpa, points.items);
            } else {
                dest.* = .{ .coord_vec = try cloneList(f32, gpa, points.items) };
            }
        },
        .bool_ => |value| dest.* = .{ .bool_ = value },
        .invalid => |value| dest.* = .{ .invalid = value },
        .toggled => |value| dest.* = .{ .toggled = value },
        .live => |value| dest.* = .{ .live = value },
        .text_direction => |value| dest.* = .{ .text_direction = value },
        .orientation => |value| dest.* = .{ .orientation = value },
        .sort_direction => |value| dest.* = .{ .sort_direction = value },
        .aria_current => |value| dest.* = .{ .aria_current = value },
        .auto_complete => |value| dest.* = .{ .auto_complete = value },
        .has_popup => |value| dest.* = .{ .has_popup = value },
        .list_style => |value| dest.* = .{ .list_style = value },
        .text_align => |value| dest.* = .{ .text_align = value },
        .vertical_offset => |value| dest.* = .{ .vertical_offset = value },
        .affine => |value| dest.* = .{ .affine = value },
        .rect => |value| dest.* = .{ .rect = value },
        .text_selection => |value| dest.* = .{ .text_selection = value },
        .custom_action_vec => |actions| {
            if (reuse) {
                var kept = dest.*.custom_action_vec;
                // Copy the descriptions before any teardown or buffer growth.
                // Allocation failure must leave the old actions owned by `dest`.
                var rebuilt: std.ArrayList(CustomAction) = .empty;
                errdefer deinitActions(gpa, &rebuilt);
                for (actions.items) |action| {
                    var fresh = try CustomAction.init(gpa, action.id, action.description.items);
                    errdefer fresh.deinit(gpa);
                    try rebuilt.append(gpa, fresh);
                }

                // Reserve before teardown so the ownership transfer cannot fail.
                try kept.ensureTotalCapacity(gpa, rebuilt.items.len);
                for (kept.items) |*action| action.deinit(gpa);
                kept.clearRetainingCapacity();
                kept.appendSliceAssumeCapacity(rebuilt.items);
                // The descriptions now belong to `kept`. Release only the header.
                rebuilt.deinit(gpa);
                dest.* = .{ .custom_action_vec = kept };
            } else {
                dest.* = .{ .custom_action_vec = try cloneActions(gpa, actions.items) };
            }
        },
        .tree_id => |value| dest.* = .{ .tree_id = value },
    }
}

/// Whether `left` and `right` are one value rather than two, buffer included.
///
/// `propertyValueCloneInto` takes `source` by value and `dest` by pointer, so
/// the caller decides whether they are the same: `&value` and `value` name one
/// object. Only the arms that own a payload can answer true, because only they
/// release anything the rebuild reads; every other arm holds a value type, so
/// assigning one over the other changes nothing.
fn sameOwnedBuffer(left: PropertyValue, right: PropertyValue) bool {
    if (left.getTag() != right.getTag()) return false;
    return switch (left) {
        .node_id_vec => |list| sameListBuffer(list, right.node_id_vec),
        .string => |bytes| sameListBuffer(bytes, right.string),
        .length_vec => |bytes| sameListBuffer(bytes, right.length_vec),
        .coord_vec => |points| sameListBuffer(points, right.coord_vec),
        .custom_action_vec => |actions| sameListBuffer(actions, right.custom_action_vec),
        .none,
        .node_id,
        .f64_,
        .f32_,
        .usize_,
        .color,
        .text_decoration,
        .bool_,
        .invalid,
        .toggled,
        .live,
        .text_direction,
        .orientation,
        .sort_direction,
        .aria_current,
        .auto_complete,
        .has_popup,
        .list_style,
        .text_align,
        .vertical_offset,
        .affine,
        .rect,
        .text_selection,
        .tree_id,
        => false,
    };
}

/// Whether two lists name one buffer, compared by pointer and by length.
///
/// Two empty lists of one type name the same address, and a clone between them
/// copies nothing either way, so the answer holds for that case too.
fn sameListBuffer(left: anytype, right: anytype) bool {
    return left.items.ptr == right.items.ptr and left.items.len == right.items.len;
}

/// Releases every description the actions own, then the list itself.
///
/// `std.ArrayList(CustomAction).deinit` frees the list buffer only, so a
/// teardown that stops there leaks one description per action.
fn deinitActions(gpa: std.mem.Allocator, actions: *std.ArrayList(CustomAction)) void {
    for (actions.items) |*action| action.deinit(gpa);
    actions.deinit(gpa);
}

fn eqlNodeIds(left: []const NodeId, right: []const NodeId) bool {
    if (left.len != right.len) return false;
    for (left, right) |own, their| {
        if (!own.eql(their)) return false;
    }
    return true;
}

fn eqlActions(left: []const CustomAction, right: []const CustomAction) bool {
    if (left.len != right.len) return false;
    for (left, right) |own, their| {
        if (!own.eql(their)) return false;
    }
    return true;
}

fn cloneList(
    comptime T: type,
    gpa: std.mem.Allocator,
    items: []const T,
) std.mem.Allocator.Error!std.ArrayList(T) {
    var owned: std.ArrayList(T) = .empty;
    errdefer owned.deinit(gpa);
    try owned.appendSlice(gpa, items);
    return owned;
}

fn cloneActions(
    gpa: std.mem.Allocator,
    items: []const CustomAction,
) std.mem.Allocator.Error!std.ArrayList(CustomAction) {
    var owned: std.ArrayList(CustomAction) = .empty;
    errdefer deinitActions(gpa, &owned);
    for (items) |action| {
        var fresh = try CustomAction.init(gpa, action.id, action.description.items);
        errdefer fresh.deinit(gpa);
        try owned.append(gpa, fresh);
    }
    return owned;
}

/// One property and the value the store holds for it.
pub const Property = struct {
    id: PropertyId,
    value: PropertyValue,

    /// Releases `value` through `gpa` and leaves `self` unusable.
    pub fn deinit(self: *Property, gpa: std.mem.Allocator) void {
        self.value.deinit(gpa);
        self.* = undefined;
    }
};

/// One row of the property table: which property, and what shape its payload
/// is.
pub const PropertyDescriptor = struct {
    id: PropertyId,
    tag: PropertyValueTag,
    payload: type,
};

/// One row per property, in `PropertyId` order.
///
/// This is the single home of the property domain outside `PropertyId` itself,
/// and it replaces the 27 `macro_rules!` definitions at
/// `accesskit/src/lib.rs:1170-1778`. Upstream wrote the relation out three
/// times — in the `PropertyId` block comments at `:894-1005`, in the
/// deserializer at `:2891-3001`, and in the schemars output at `:3044-3153` —
/// and this is the one place the port keeps it.
///
/// A row holds a `type`, so this array is `comptime` data. Run-time readers
/// use `property_value_tags_by_id`, which is derived from it.
pub const property_descriptors = [_]PropertyDescriptor{
    // NodeIdVec
    .{ .id = .children, .tag = .node_id_vec, .payload = std.ArrayList(NodeId) },
    .{ .id = .controls, .tag = .node_id_vec, .payload = std.ArrayList(NodeId) },
    .{ .id = .details, .tag = .node_id_vec, .payload = std.ArrayList(NodeId) },
    .{ .id = .described_by, .tag = .node_id_vec, .payload = std.ArrayList(NodeId) },
    .{ .id = .flow_to, .tag = .node_id_vec, .payload = std.ArrayList(NodeId) },
    .{ .id = .labelled_by, .tag = .node_id_vec, .payload = std.ArrayList(NodeId) },
    .{ .id = .owns, .tag = .node_id_vec, .payload = std.ArrayList(NodeId) },
    .{ .id = .radio_group, .tag = .node_id_vec, .payload = std.ArrayList(NodeId) },

    // NodeId
    .{ .id = .active_descendant, .tag = .node_id, .payload = NodeId },
    .{ .id = .error_message, .tag = .node_id, .payload = NodeId },
    .{ .id = .in_page_link_target, .tag = .node_id, .payload = NodeId },
    .{ .id = .member_of, .tag = .node_id, .payload = NodeId },
    .{ .id = .next_on_line, .tag = .node_id, .payload = NodeId },
    .{ .id = .previous_on_line, .tag = .node_id, .payload = NodeId },
    .{ .id = .popup_for, .tag = .node_id, .payload = NodeId },

    // String
    .{ .id = .label, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .description, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .value, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .access_key, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .author_id, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .class_name, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .font_family, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .html_id, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .html_tag, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .inner_html, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .keyboard_shortcut, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .language, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .placeholder, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .role_description, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .state_description, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .tooltip, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .url, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .row_index_text, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .column_index_text, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .braille_label, .tag = .string, .payload = std.ArrayList(u8) },
    .{ .id = .braille_role_description, .tag = .string, .payload = std.ArrayList(u8) },

    // f64
    .{ .id = .scroll_x, .tag = .f64_, .payload = f64 },
    .{ .id = .scroll_x_min, .tag = .f64_, .payload = f64 },
    .{ .id = .scroll_x_max, .tag = .f64_, .payload = f64 },
    .{ .id = .scroll_y, .tag = .f64_, .payload = f64 },
    .{ .id = .scroll_y_min, .tag = .f64_, .payload = f64 },
    .{ .id = .scroll_y_max, .tag = .f64_, .payload = f64 },
    .{ .id = .numeric_value, .tag = .f64_, .payload = f64 },
    .{ .id = .min_numeric_value, .tag = .f64_, .payload = f64 },
    .{ .id = .max_numeric_value, .tag = .f64_, .payload = f64 },
    .{ .id = .numeric_value_step, .tag = .f64_, .payload = f64 },
    .{ .id = .numeric_value_jump, .tag = .f64_, .payload = f64 },

    // f32
    .{ .id = .font_size, .tag = .f32_, .payload = f32 },
    .{ .id = .font_weight, .tag = .f32_, .payload = f32 },

    // usize
    .{ .id = .row_count, .tag = .usize_, .payload = usize },
    .{ .id = .column_count, .tag = .usize_, .payload = usize },
    .{ .id = .row_index, .tag = .usize_, .payload = usize },
    .{ .id = .column_index, .tag = .usize_, .payload = usize },
    .{ .id = .row_span, .tag = .usize_, .payload = usize },
    .{ .id = .column_span, .tag = .usize_, .payload = usize },
    .{ .id = .level, .tag = .usize_, .payload = usize },
    .{ .id = .size_of_set, .tag = .usize_, .payload = usize },
    .{ .id = .position_in_set, .tag = .usize_, .payload = usize },

    // Color
    .{ .id = .color_value, .tag = .color, .payload = Color },
    .{ .id = .background_color, .tag = .color, .payload = Color },
    .{ .id = .foreground_color, .tag = .color, .payload = Color },

    // TextDecoration
    .{ .id = .overline, .tag = .text_decoration, .payload = TextDecoration },
    .{ .id = .strikethrough, .tag = .text_decoration, .payload = TextDecoration },
    .{ .id = .underline, .tag = .text_decoration, .payload = TextDecoration },

    // LengthVec
    .{ .id = .character_lengths, .tag = .length_vec, .payload = std.ArrayList(u8) },
    .{ .id = .word_starts, .tag = .length_vec, .payload = std.ArrayList(u8) },

    // CoordVec
    .{ .id = .character_positions, .tag = .coord_vec, .payload = std.ArrayList(f32) },
    .{ .id = .character_widths, .tag = .coord_vec, .payload = std.ArrayList(f32) },

    // bool
    .{ .id = .expanded, .tag = .bool_, .payload = bool },
    .{ .id = .selected, .tag = .bool_, .payload = bool },

    // Unique enums
    .{ .id = .invalid, .tag = .invalid, .payload = Invalid },
    .{ .id = .toggled, .tag = .toggled, .payload = Toggled },
    .{ .id = .live, .tag = .live, .payload = Live },
    .{ .id = .text_direction, .tag = .text_direction, .payload = TextDirection },
    .{ .id = .orientation, .tag = .orientation, .payload = Orientation },
    .{ .id = .sort_direction, .tag = .sort_direction, .payload = SortDirection },
    .{ .id = .aria_current, .tag = .aria_current, .payload = AriaCurrent },
    .{ .id = .auto_complete, .tag = .auto_complete, .payload = AutoComplete },
    .{ .id = .has_popup, .tag = .has_popup, .payload = HasPopup },
    .{ .id = .list_style, .tag = .list_style, .payload = ListStyle },
    .{ .id = .text_align, .tag = .text_align, .payload = TextAlign },
    .{ .id = .vertical_offset, .tag = .vertical_offset, .payload = VerticalOffset },

    // Other
    .{ .id = .transform, .tag = .affine, .payload = Affine },
    .{ .id = .bounds, .tag = .rect, .payload = Rect },
    .{ .id = .text_selection, .tag = .text_selection, .payload = TextSelection },
    .{ .id = .custom_actions, .tag = .custom_action_vec, .payload = std.ArrayList(CustomAction) },
    .{ .id = .tree_id, .tag = .tree_id, .payload = TreeId },
};

/// The number of rows in `property_descriptors`: the member count of the
/// property domain.
pub const propertyDescriptorCount: usize = property_descriptors.len;

/// The number of properties, and the `comptime` bound every loop over the
/// property domain uses. The `comptime` block below pins it at 87.
pub const propertyIdCount: usize = propertyDescriptorCount;

/// The run-time projection of `property_descriptors`, holding only the tag of
/// each row so it can be indexed at run time. It is derived from the table, so
/// the two cannot disagree.
pub const property_value_tags_by_id: [propertyIdCount]PropertyValueTag = tags: {
    var collected: [propertyIdCount]PropertyValueTag = undefined;
    for (property_descriptors, 0..) |row, index| collected[index] = row.tag;
    break :tags collected;
};

/// The row for `id`. Every tag has one, so the discriminant indexes the table
/// directly. `comptime`, because a row holds a `type`.
pub fn propertyDescriptor(comptime id: PropertyId) PropertyDescriptor {
    return property_descriptors[@backingInt(id)];
}

/// The payload tag `id` carries, read from the table's run-time projection.
pub fn propertyValueTagOf(id: PropertyId) PropertyValueTag {
    return property_value_tags_by_id[@backingInt(id)];
}

/// How many rows of `property_descriptors` carry each payload tag, indexed by
/// the tag's discriminant.
///
/// The second run-time projection of the table, derived from it the same way
/// `property_value_tags_by_id` is, so the two cannot disagree. It exists for
/// `assertFamilyReachable`: a family sweeping all 87 rows to find the ones it
/// owns costs 87 backwards branches per family and all seven families share
/// one comptime branch quota, while summing the per-tag counts costs one
/// addition per tag the family owns.
pub const property_counts_by_tag: [propertyValueTagCount()]usize = counts: {
    var collected = @as([propertyValueTagCount()]usize, @splat(0));
    for (property_descriptors) |row| collected[@backingInt(row.tag)] += 1;
    break :counts collected;
};

/// The payload type `id` carries, read from its row.
///
/// `comptime`, so a caller may write a generic accessor over the domain and
/// pin the return type at the call site.
pub fn PropertyPayloadType(comptime id: PropertyId) type {
    return propertyDescriptor(id).payload;
}

// -- Family reachability ----------------------------------------------------
//
// The seven accessor families in this directory partition the payload tags,
// and a partition is the only thing that makes "every property has an
// accessor" a build-time fact rather than a review habit. Each family declares
// the properties it publishes a getter, a setter and a clearer for.
//
// `assertFamilyReachable` holds the three claims that are about one family,
// and every family calls it:
//
// 0. No id twice, so a family's length is the number of properties it claims.
// 1. Every id the family declares carries a tag that family owns.
// 2. Every descriptor row carrying a tag that family owns is declared by it.
//
// `assertTagsPartitioned` holds the one claim that is about all seven at
// once, and this module's comptime block calls it once:
//
// 3. Every descriptor row's tag is owned by exactly one family.
//
// Claims 1 and 2 make each family a complete statement about its own tags, so
// claim 3 turns seven local statements into a partition of the whole domain: a
// new descriptor row on an existing tag fails its owner, and a new descriptor
// row on a new tag fails because no family owns that tag. Either way a row with
// no accessor behind it is a compile error, which is what the rest of this
// module's comptime checks could not say.
//
// **Why the family owns tags rather than naming properties.** A tag names one
// payload shape and one accessor family reads it, so a family's tag set is
// short and fixed by the 27 upstream macro families, while its property list
// moves every time a property is added. Assigning ownership by tag is what
// lets claim 2 be a completeness check rather than a restatement: a new row on
// an owned tag has no way to appear without the owning family failing.
//
// **What this does not cover, and why.** The C surface in
// `src/capi/node_properties.zig` is an independent copy: it pins 87 and 294
// from `export_names`, never from `propertyIdCount`, so a property added here
// and not there is invisible to both halves. Bridging the two would mean the
// schema table reading a generated export list, which inverts the dependency
// from a pure value layer onto a code generator. `zig build capi-parity`
// compares the header against `src/capi/*.zig` and is where that half is
// checked, so the gap is named rather than closed.

/// The accessor families that own payload tags.
///
/// `flags.zig` is absent on purpose: the 18 flags live in one `u32` on `Node`,
/// are not `PropertyId` tags and carry no `PropertyValue` variant, so no
/// descriptor row can name one.
pub const Family = enum {
    ids,
    numbers,
    strings,
    enums,
    colors,
    vectors,
    option,
};

/// How many families there are, and the `comptime` bound on the sweeps that
/// walk them.
pub const familyCount: usize = @typeInfo(Family).@"enum".field_names.len;

/// The payload tags `family` owns, and no other family does.
///
/// The 28 tags listed across the seven arms plus `PropertyValueTag.none` are
/// the whole tag domain, which `propertyValueTagCount()` pins at 29. That
/// arithmetic is why claim 3 of `assertFamilyReachable` can be exhaustive: a
/// tag in no family is a tag no row can carry, so a new `PropertyValue` variant
/// has to appear in one of these arms or claim 3 fires on the first row that
/// uses it.
pub fn familyTags(comptime family: Family) []const PropertyValueTag {
    return switch (family) {
        .ids => &.{ .node_id, .node_id_vec },
        .numbers => &.{ .f64_, .f32_, .usize_ },
        .strings => &.{.string},
        .enums => &.{
            .bool_,
            .invalid,
            .toggled,
            .live,
            .text_direction,
            .orientation,
            .sort_direction,
            .aria_current,
            .auto_complete,
            .has_popup,
            .list_style,
            .text_align,
            .vertical_offset,
        },
        .colors => &.{ .color, .text_decoration },
        .vectors => &.{ .length_vec, .coord_vec, .custom_action_vec },
        .option => &.{ .affine, .rect, .text_selection, .tree_id },
    };
}

/// The family that owns each payload tag, or `null` when no family does.
///
/// Built once, here, so both halves of the reachability claim read a lookup
/// rather than each sweeping the seven tag lists: seven comptime blocks share
/// one branch quota, and a per-family scan of the 13-tag enums list across 87
/// descriptor rows is 1131 branches, which exhausts it on the third family
/// analysed. This table is 29 entries wide and is built in 28 steps.
const family_by_tag: [propertyValueTagCount()]?Family = owners: {
    var collected = @as([propertyValueTagCount()]?Family, @splat(null));
    for (std.enums.values(Family)) |family| {
        for (familyTags(family)) |tag| {
            if (collected[@backingInt(tag)]) |first| {
                @compileError(std.fmt.comptimePrint(
                    "tag `{s}` is owned by props/{s}.zig and props/{s}.zig; one family each",
                    .{ @tagName(tag), @tagName(first), @tagName(family) },
                ));
            }
            collected[@backingInt(tag)] = family;
        }
    }
    break :owners collected;
};

/// Whether `claimed` names `id`. A `comptime` domain, read only on the path
/// where the count check has already failed.
fn declaresId(comptime claimed: []const PropertyId, id: PropertyId) bool {
    for (claimed) |candidate| {
        if (candidate == id) return true;
    }
    return false;
}

/// Holds `claimed` to the properties whose descriptor tag `family` owns, and
/// fails the build otherwise.
///
/// `comptime` and never called at run time, because each of the three claims it
/// cannot hold ends in `@compileError`. `claimed` is taken by value rather
/// than as a slice so its length is a comptime value and the loop unrolls: a
/// loop over a slice of unknown length is not unrolled, and seven of those
/// against the default quota of 1000 branches is what exhausted it.
///
/// **Claim 2 is a count, not a sweep.** Claim 1 says every id in `claimed`
/// carries a tag this family owns and claim 0 says the ids are distinct, so
/// `claimed` is a subset of the descriptor rows carrying an owned tag. A subset
/// of the same cardinality is the set, so `claimed.len` equal to the sum of
/// `property_counts_by_tag` over the family's tags says every such row is
/// claimed without reading any of them. That matters because the seven families
/// share one comptime branch quota and a per-family sweep of all 87 rows
/// exhausts it on the third family analysed.
pub fn assertFamilyReachable(comptime family: Family, comptime claimed: anytype) void {
    // The default comptime branch quota is 1000 for one evaluation, and this
    // body is evaluated once per family, so the seven of them between them
    // exceed it. It is set once and for all rather than tuned down to the
    // smallest passing number: a quota is a budget, not a bound, and a figure
    // derived from the domain would break the build the day a family's table
    // grew by one row.
    //
    // The quota is set here rather than at the seven call sites so the figure
    // and the code it covers stay in one place.
    @setEvalBranchQuota(1_000_000);
    const name = @tagName(family);

    // Claim 0: no id twice. A duplicate plus a missing row would leave
    // `claimed.len` equal to the owned row count and let the defect through,
    // so this is a claim of its own rather than part of claim 2.
    //
    // The seen set is a bitmask rather than a `propertyDescriptorCount` array
    // of booleans and rather than a pairwise comparison, because writing one
    // entry of a comptime array copies the whole array and comparing every
    // pair costs `claimed.len` squared. `PropertyId` is dense and `u128` holds
    // 128 discriminants, so one shift and one or per id is enough for any
    // domain this table could hold.
    var seen: u128 = 0;
    for (claimed, 0..) |id, index| {
        const bit = @as(u128, 1) << @intCast(@backingInt(id));
        if (seen & bit != 0) {
            @compileError(std.fmt.comptimePrint(
                "props/{s}.zig lists `{s}` at entry {d} and again; one entry per property",
                .{ name, @tagName(id), index },
            ));
        }
        seen |= bit;

        // Claim 1: every declared id carries a tag this family owns, read from
        // the table the seven families built between them. Without it a family
        // could claim a property and read the wrong arm, and a second family
        // could also claim it and both would be checked against nothing.
        const tag = propertyValueTagOf(id);
        if (family_by_tag[@backingInt(tag)] != family) {
            @compileError(std.fmt.comptimePrint(
                "props/{s}.zig claims `{s}`, whose descriptor row carries tag `{s}`; " ++
                    "props/{s}.zig owns that tag",
                .{
                    name,
                    @tagName(id),
                    @tagName(tag),
                    if (family_by_tag[@backingInt(tag)]) |owner| @tagName(owner) else "no family",
                },
            ));
        }
    }

    // The rows carrying a tag this family owns, counted over the family's tags
    // rather than over `claimed`. Summing per claimed id would count a tag with
    // three rows once for each of the three properties that share it, which is
    // 9 where the table holds 3.
    var owned_rows: usize = 0;
    for (familyTags(family)) |tag| owned_rows += property_counts_by_tag[@backingInt(tag)];

    // Claim 2, by the bijection argued above.
    if (claimed.len != owned_rows) {
        // Name the row rather than the counts alone. This sweep reads all
        // `propertyDescriptorCount` rows, which is the cost the count check
        // exists to avoid, so it runs only on this path.
        for (property_descriptors, 0..) |row, index| {
            if (family_by_tag[@backingInt(row.tag)] == family and
                !declaresId(&claimed, row.id))
            {
                @compileError(std.fmt.comptimePrint(
                    "descriptor row {d} is `{s}` and carries tag `{s}`, which " ++
                        "props/{s}.zig owns; that family declares no accessor for it",
                    .{ index, @tagName(row.id), @tagName(row.tag), name },
                ));
            }
        }
        @compileError(std.fmt.comptimePrint(
            "props/{s}.zig lists {d} properties but {d} carry a tag it owns",
            .{ name, claimed.len, owned_rows },
        ));
    }
}

/// Holds the seven tag lists above to a partition of the tag domain, and fails
/// the build otherwise.
///
/// One call, from this module's own comptime block, because the claim is about
/// the seven families together and not about any one of them.
pub fn assertTagsPartitioned() void {
    comptime {
        // `none` is the absence tag: no descriptor row carries it and no family
        // publishes an accessor for it, so it stays unowned by design.
        if (family_by_tag[@backingInt(PropertyValueTag.none)] != null) {
            @compileError("PropertyValueTag.none is the absence tag and no family owns it");
        }
        for (property_descriptors, 0..) |row, index| {
            if (family_by_tag[@backingInt(row.tag)] == null) {
                @compileError(std.fmt.comptimePrint(
                    "descriptor row {d} is `{s}` and carries tag `{s}`, which no " ++
                        "family owns; add the tag to one arm of `familyTags`",
                    .{ index, @tagName(row.id), @tagName(row.tag) },
                ));
            }
        }
    }
}

/// The properties one node carries.
///
/// The store holds a sorted slice of id and value pairs rather than
/// upstream's `PropertyIndices` byte array over a slot vector
/// (`accesskit/src/lib.rs:1071-1074`), and a cleared property LEAVES the
/// slice. That is the whole difference, and it buys three things: absence is
/// an empty slice instead of a byte equal to 87; two stores compare
/// structurally instead of through slot positions; and a lookup is a binary
/// search over at most 87 entries instead of one byte read plus one index.
///
/// `Properties` owns the allocator it was created with, so `deinit` takes none
/// and no caller can allocate through one allocator and free through another.
/// The store owns every value it holds, and `deinit` is the one release.
pub const Properties = struct {
    /// The allocator every write and every release of this store goes
    /// through. A store is bound to it for its whole life.
    gpa: std.mem.Allocator,
    /// Ascending by `@intFromEnum(id)`, at most `propertyIdCount` deep. A
    /// cleared property is absent from the slice, so no entry is a placeholder.
    items: std.ArrayList(Property),

    /// An empty store. There is no `Default`, because a default store would
    /// have to name an allocator.
    pub fn init(gpa: std.mem.Allocator) Properties {
        return .{ .gpa = gpa, .items = .empty };
    }

    /// Releases every value the store holds and the slice itself.
    ///
    /// The allocator the store was created with is not released. The store is
    /// unusable afterward and a second call is a double free. Every pointer a
    /// `get`, a `find` or a `getOrInsert` returned is invalid afterward.
    pub fn deinit(self: *Properties) void {
        for (self.items.items) |*entry| entry.deinit(self.gpa);
        self.items.deinit(self.gpa);
        self.items = .empty;
    }

    /// How many properties the store holds, at most `propertyIdCount`.
    pub fn count(self: *const Properties) usize {
        return self.items.items.len;
    }

    /// The position `id` occupies, or `null` when the store does not hold it.
    ///
    /// The slice is sorted, so this is a binary search. A caller that wants a
    /// position rather than a value, to walk a store alongside another one,
    /// reads it here instead of recomputing the search.
    pub fn find(self: *const Properties, id: PropertyId) ?usize {
        const position = self.insertionIndex(id);
        if (position >= self.items.items.len) return null;
        if (@backingInt(self.items.items[position].id) != @backingInt(id)) return null;
        return position;
    }

    /// The value the store holds for `id`, or `null` when it holds none.
    ///
    /// The result borrows the store. It is invalidated by the next `set`,
    /// `clear`, `getOrInsert` or `deinit` on that store, and by nothing else.
    /// The returned pointer is not a second owner: releasing it would release
    /// the store's buffer.
    pub fn get(self: *const Properties, id: PropertyId) ?*const PropertyValue {
        const index = self.find(id) orelse return null;
        return &self.items.items[index].value;
    }

    /// The value the store holds for `id`, inserting `default` first when it
    /// holds none, and returning a pointer into the slice.
    ///
    /// The port of `Properties::get_mut` (`accesskit/src/lib.rs:1122-1136`),
    /// and the reason the port's pushers are amortised O(1) rather than
    /// quadratic: the caller appends to the returned list in place instead of
    /// copying it back. `default` is COPIED into the store, so the caller
    /// keeps ownership of the value it passed.
    ///
    /// The returned pointer is invalidated by the next `set`, `clear`,
    /// `getOrInsert` or `deinit` on that store, because an insert into the
    /// middle of the sorted slice shifts it. Do not hold it across another
    /// write to the same store.
    ///
    /// On `error.OutOfMemory` nothing is inserted and the store is exactly as
    /// it was; the caller still owns `default`.
    pub fn getOrInsert(
        self: *Properties,
        id: PropertyId,
        default: PropertyValue,
    ) std.mem.Allocator.Error!*PropertyValue {
        if (self.find(id)) |index| return &self.items.items[index].value;
        std.debug.assert(default != .none);
        var fresh = try propertyValueClone(self.gpa, default);
        errdefer fresh.deinit(self.gpa);
        const index = self.insertionIndex(id);
        try self.items.insert(self.gpa, index, .{ .id = id, .value = fresh });
        return &self.items.items[index].value;
    }

    /// Stores `value` under `id`, replacing whatever was there, and takes
    /// ownership of `value` on success.
    ///
    /// Replacing a value releases the one it displaced through the store's
    /// allocator. A value carrying the tag `none` is rejected at the assertion:
    /// a cleared property leaves the slice, so `clear` is how a property goes
    /// away.
    ///
    /// On `error.OutOfMemory` nothing is written, the store is exactly as it
    /// was, and the caller still owns `value` — which is why an owning setter
    /// guards its freshly built payload with `errdefer`.
    pub fn set(
        self: *Properties,
        id: PropertyId,
        value: PropertyValue,
    ) std.mem.Allocator.Error!void {
        std.debug.assert(value != .none);
        if (self.find(id)) |index| {
            self.items.items[index].value.deinit(self.gpa);
            self.items.items[index].value = value;
            return;
        }
        try self.items.insert(self.gpa, self.insertionIndex(id), .{ .id = id, .value = value });
    }

    /// Removes `id` from the store and releases the value it held.
    ///
    /// A property the store does not hold is already absent, so the call is a
    /// no-op and not an error. This is the port of `Properties::clear`
    /// (`accesskit/src/lib.rs:1148`), which upstream implemented by writing
    /// `PropertyValue::None` over the slot; the port writes nothing at all.
    ///
    /// Every pointer a `get`, a `find` or a `getOrInsert` returned is
    /// invalidated, because the slice shifts.
    pub fn clear(self: *Properties, id: PropertyId) void {
        const index = self.find(id) orelse return;
        self.items.items[index].deinit(self.gpa);
        _ = self.items.orderedRemove(index);
    }

    /// Whether both stores hold the same properties with the same values.
    ///
    /// Structural, not positional: it is true exactly when the two ids and
    /// their payloads match, whatever order either store was written in. A
    /// property one store holds and the other does not answers `false`, which
    /// is how a cleared property compares unequal to one that was never set.
    /// Upstream reached the same answer by comparing slot positions
    /// (`accesskit/src/lib.rs:1084-1094`) and needed commit `05ea5c5` to keep
    /// it correct once clone buffer reuse broke the correspondence.
    pub fn eql(a: *const Properties, b: *const Properties) bool {
        if (a.items.items.len != b.items.items.len) return false;
        for (a.items.items, b.items.items) |own, their| {
            if (own.id != their.id) return false;
            if (!own.value.eql(their.value)) return false;
        }
        return true;
    }

    /// A deep copy of this store through `gpa`, bound to `gpa`.
    ///
    /// The port of `Properties::clone` (`accesskit/src/lib.rs:1157`). The
    /// result shares no buffer with the source, and releasing the result
    /// releases nothing of the source.
    pub fn clone(self: Properties, gpa: std.mem.Allocator) std.mem.Allocator.Error!Properties {
        var fresh: Properties = .init(gpa);
        errdefer fresh.deinit();
        try self.cloneInto(&fresh);
        return fresh;
    }

    /// Replaces `out` with a copy of this store, keeping `out`'s buffers
    /// wherever the same property is already present.
    ///
    /// The port of `Properties::clone_from`
    /// (`accesskit/src/lib.rs:1164`), which exists because 0.25.0 started
    /// reusing the destination's buffers on clone. Both lists are sorted, so
    /// one pass pairs them by id: an id in both hands over its allocation, an
    /// id only in `out` is released, and an id only in the source is copied.
    /// Source-only ids enter at their sorted positions so getters remain valid,
    /// including after an allocation failure.
    /// A second clone of a whole store therefore costs no allocation at all.
    ///
    /// Everything the source owns is copied through `out.gpa`, so `out` is
    /// released through one allocator and holds nothing from another.
    ///
    /// On `error.OutOfMemory` the entries already handled are the finished
    /// ones, the rest of `out` is unchanged, and no entry of the source is
    /// half copied.
    pub fn cloneInto(self: Properties, out: *Properties) std.mem.Allocator.Error!void {
        var index: usize = 0;
        var source_index: usize = 0;
        while (index < out.items.items.len and source_index < self.items.items.len) {
            const order = std.math.order(
                @backingInt(out.items.items[index].id),
                @backingInt(self.items.items[source_index].id),
            );
            switch (order) {
                .eq => {
                    try propertyValueCloneInto(
                        out.gpa,
                        &out.items.items[index].value,
                        self.items.items[source_index].value,
                    );
                    index += 1;
                    source_index += 1;
                },
                .lt => {
                    out.items.items[index].deinit(out.gpa);
                    _ = out.items.orderedRemove(index);
                },
                .gt => {
                    var fresh = try propertyValueClone(
                        out.gpa,
                        self.items.items[source_index].value,
                    );
                    errdefer fresh.deinit(out.gpa);
                    try out.items.insert(out.gpa, index, .{
                        .id = self.items.items[source_index].id,
                        .value = fresh,
                    });
                    index += 1;
                    source_index += 1;
                },
            }
        }
        // Whatever `out` still holds past `index` is not in the source.
        while (index < out.items.items.len) {
            out.items.items[index].deinit(out.gpa);
            _ = out.items.orderedRemove(index);
        }
        // Whatever the source still holds is not in `out`.
        while (source_index < self.items.items.len) : (source_index += 1) {
            var fresh = try propertyValueClone(out.gpa, self.items.items[source_index].value);
            errdefer fresh.deinit(out.gpa);
            try out.items.append(out.gpa, .{
                .id = self.items.items[source_index].id,
                .value = fresh,
            });
        }
    }

    /// The position `id` would occupy, which is where an insert belongs.
    fn insertionIndex(self: *const Properties, id: PropertyId) usize {
        const needle = @backingInt(id);
        var low: usize = 0;
        var high: usize = self.items.items.len;
        // The midpoint is floored rather than exact, so an odd bound is not a
        // panic, and it is computed without the addition that could overflow.
        // Either rounding halves the bound, so the loop runs at most
        // ceil(log2(len + 1)) times and terminates.
        while (low < high) {
            const middle = low + @divFloor(high - low, 2);
            if (@backingInt(self.items.items[middle].id) < needle) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return low;
    }
};

comptime {
    // Every tag of `PropertyId` appears exactly once, so a property added
    // without a row and a row written twice are both compile errors. This is
    // the exhaustiveness the 27 upstream `macro_rules!` definitions gave the
    // Rust type checker for free.
    if (@typeInfo(PropertyId).@"enum".field_names.len != propertyDescriptorCount) {
        @compileError(std.fmt.comptimePrint(
            "PropertyId carries {d} tags and property_descriptors holds {d} rows; the " ++
                "contract is one row per property",
            .{ @typeInfo(PropertyId).@"enum".field_names.len, propertyDescriptorCount },
        ));
    }

    var seen = @as([propertyDescriptorCount]bool, @splat(false));
    for (property_descriptors) |row| {
        const index = @backingInt(row.id);
        if (index >= propertyDescriptorCount) {
            @compileError(std.fmt.comptimePrint(
                "the descriptor for `{s}` carries discriminant {d}, which is outside " ++
                    "the {d} properties",
                .{ @tagName(row.id), index, propertyDescriptorCount },
            ));
        }
        if (seen[index]) {
            @compileError(std.fmt.comptimePrint(
                "the descriptor for `{s}` appears more than once",
                .{@tagName(row.id)},
            ));
        }
        seen[index] = true;
    }
    for (seen, 0..) |present, index| {
        if (!present) {
            @compileError(std.fmt.comptimePrint(
                "the property with discriminant {d} has no descriptor row",
                .{index},
            ));
        }
    }

    // A row's declared payload must be the payload its tag carries, or one
    // property reads back through one spelling and writes through another.
    for (property_descriptors) |row| {
        if (PropertyValuePayloadType(row.tag) != row.payload) {
            @compileError(std.fmt.comptimePrint(
                "the descriptor for `{s}` names tag `{s}` with a payload that is not " ++
                    "that tag's",
                .{ @tagName(row.id), @tagName(row.tag) },
            ));
        }
    }

    // The domain is dense from 0, so a row can be indexed by discriminant
    // rather than searched.
    for (property_descriptors, 0..) |row, index| {
        if (@backingInt(row.id) != index) {
            @compileError(std.fmt.comptimePrint(
                "the descriptor at position {d} is `{s}`; the rows must stay in " ++
                    "PropertyId order so the discriminant indexes them",
                .{ index, @tagName(row.id) },
            ));
        }
    }

    std.debug.assert(propertyIdCount == 87);
    std.debug.assert(propertyIdTagCount == propertyIdCount);
    std.debug.assert(propertyValueTagCount() == 29);

    // The seven families partition the payload tags, so every row above is
    // reachable through the family that owns its tag. The per-family half of
    // that claim lives in each family's own module, because only the family
    // knows which properties it publishes accessors for.
    assertTagsPartitioned();
    // `Property` and `Properties` are plain structs and nothing outside this
    // module depends on their size, so no pin is taken on either. Only
    // `PropertyValue` is pinned: its size is the largest payload plus the tag,
    // it is the figure the module comment explains against `docs/10`, and it
    // is what every `std.ArrayList(Property)` allocation is sized from.
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// The property at `index`, for a `comptime`-only table and a run-time loop.
fn propertyAt(index: usize) PropertyId {
    std.debug.assert(index < propertyIdCount);
    return @fromBackingInt(@intCast(@as(u8, @intCast(index))));
}

/// One stored value per payload shape, built by hand so a test can name a
/// concrete payload the comptime table can never synthesise.
fn sampleValue(comptime tag: PropertyValueTag, gpa: std.mem.Allocator) !PropertyValue {
    return switch (tag) {
        .none => propertyValueFrom(.none, {}),
        .node_id_vec => propertyValueFrom(.node_id_vec, try sampleNodes(gpa)),
        .node_id => propertyValueFrom(.node_id, nodeIdFromContent(7)),
        .string => propertyValueFrom(.string, try sampleBytes(gpa, "label")),
        .f64_ => propertyValueFrom(.f64_, 1.5),
        .f32_ => propertyValueFrom(.f32_, 2.5),
        .usize_ => propertyValueFrom(.usize_, 3),
        .color => propertyValueFrom(.color, .{ .red = 10, .green = 20, .blue = 30, .alpha = 40 }),
        .text_decoration => propertyValueFrom(.text_decoration, .{
            .style = .dotted,
            .color = .{ .red = 1, .green = 2, .blue = 3, .alpha = 4 },
        }),
        .length_vec => propertyValueFrom(.length_vec, try sampleBytes(gpa, "xy")),
        .coord_vec => propertyValueFrom(.coord_vec, try samplePoints(gpa)),
        .bool_ => propertyValueFrom(.bool_, true),
        .invalid => propertyValueFrom(.invalid, .grammar),
        .toggled => propertyValueFrom(.toggled, .true_),
        .live => propertyValueFrom(.live, .polite),
        .text_direction => propertyValueFrom(.text_direction, .left_to_right),
        .orientation => propertyValueFrom(.orientation, .horizontal),
        .sort_direction => propertyValueFrom(.sort_direction, .ascending),
        .aria_current => propertyValueFrom(.aria_current, .page),
        .auto_complete => propertyValueFrom(.auto_complete, .inline_),
        .has_popup => propertyValueFrom(.has_popup, .menu),
        .list_style => propertyValueFrom(.list_style, .disc),
        .text_align => propertyValueFrom(.text_align, .left),
        .vertical_offset => propertyValueFrom(.vertical_offset, .subscript),
        .affine => propertyValueFrom(.affine, affine_identity),
        .rect => propertyValueFrom(.rect, rectInit(1.0, 2.0, 3.0, 4.0)),
        .text_selection => propertyValueFrom(.text_selection, sampleSelection()),
        .custom_action_vec => propertyValueFrom(.custom_action_vec, try sampleActionList(gpa)),
        .tree_id => propertyValueFrom(.tree_id, treeIdFromBytes(@splat(9))),
    };
}

fn sampleNodes(gpa: std.mem.Allocator) !std.ArrayList(NodeId) {
    return cloneList(NodeId, gpa, &.{ nodeIdFromContent(1), nodeIdFromContent(2) });
}

fn sampleBytes(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList(u8) {
    return cloneList(u8, gpa, text);
}

fn samplePoints(gpa: std.mem.Allocator) !std.ArrayList(f32) {
    return cloneList(f32, gpa, &.{ 1.0, 2.0 });
}

fn sampleActionList(gpa: std.mem.Allocator) !std.ArrayList(CustomAction) {
    var owned: std.ArrayList(CustomAction) = .empty;
    errdefer owned.deinit(gpa);
    var fresh = try CustomAction.init(gpa, 5, "drag");
    errdefer fresh.deinit(gpa);
    try owned.append(gpa, fresh);
    return owned;
}

fn sampleSelection() TextSelection {
    const anchor: values.TextPosition = .{ .node_id = nodeIdFromContent(1), .character_index = 4 };
    return .{ .anchor = anchor, .focus = anchor };
}

/// A store holding every property, which is what the sweep tests start from.
fn populatedStore() !Properties {
    var properties: Properties = .init(testing.allocator);
    errdefer properties.deinit();
    // `inline for` because a descriptor row carries a `type`, which is a
    // comptime value, so the table cannot be indexed at run time.
    inline for (property_descriptors) |row| {
        try properties.set(row.id, try sampleValue(row.tag, testing.allocator));
    }
    return properties;
}

test "PropertyId carries exactly 87 properties and no sentinel" {
    try testing.expectEqual(@as(usize, 87), propertyIdCount);
    try testing.expectEqual(@as(usize, 87), propertyIdTagCount);
    // The last real property is 86, so 87 names nothing at all.
    try testing.expectEqual(@as(u8, 86), @backingInt(PropertyId.tree_id));
    try testing.expectEqual(PropertyValueTag.affine, propertyDescriptor(.transform).tag);
    try testing.expectEqual(std.ArrayList(NodeId), PropertyPayloadType(.children));
    try testing.expectEqual(bool, PropertyPayloadType(.expanded));
}

test "PropertyIdFromInt rejects every byte past the last property" {
    try testing.expectEqual(PropertyId.children, propertyIdFromInt(0).?);
    try testing.expectEqual(PropertyId.tree_id, propertyIdFromInt(86).?);
    try testing.expect(propertyIdFromInt(87) == null);
    try testing.expect(propertyIdFromInt(88) == null);
    try testing.expect(propertyIdFromInt(255) == null);
}

test "every descriptor row reads its own id back through both projections" {
    // `inline for` for the reason `populatedStore` gives.
    inline for (property_descriptors, 0..) |row, index| {
        const id = propertyAt(index);
        try testing.expectEqual(id, row.id);
        try testing.expectEqual(row.tag, propertyDescriptor(row.id).tag);
        try testing.expectEqual(row.tag, propertyValueTagOf(id));
        try testing.expectEqual(row.tag, property_value_tags_by_id[index]);
        try testing.expectEqual(row.payload, PropertyPayloadType(row.id));
    }
}

test "the families in docs/10 section 1.5 land on the rows they name" {
    // 8 NodeIdVec, 7 NodeId, 21 String, 11 f64, 2 f32, 9 usize, 3 Color,
    // 3 TextDecoration, 2 LengthVec, 2 CoordVec, 2 bool, 12 unique enums and
    // 5 others. A property moved between families moves one of these.
    const expected = [_]struct { tag: PropertyValueTag, count: usize }{
        .{ .tag = .node_id_vec, .count = 8 },
        .{ .tag = .node_id, .count = 7 },
        .{ .tag = .string, .count = 21 },
        .{ .tag = .f64_, .count = 11 },
        .{ .tag = .f32_, .count = 2 },
        .{ .tag = .usize_, .count = 9 },
        .{ .tag = .color, .count = 3 },
        .{ .tag = .text_decoration, .count = 3 },
        .{ .tag = .length_vec, .count = 2 },
        .{ .tag = .coord_vec, .count = 2 },
        .{ .tag = .bool_, .count = 2 },
        .{ .tag = .invalid, .count = 1 },
        .{ .tag = .toggled, .count = 1 },
        .{ .tag = .live, .count = 1 },
        .{ .tag = .text_direction, .count = 1 },
        .{ .tag = .orientation, .count = 1 },
        .{ .tag = .sort_direction, .count = 1 },
        .{ .tag = .aria_current, .count = 1 },
        .{ .tag = .auto_complete, .count = 1 },
        .{ .tag = .has_popup, .count = 1 },
        .{ .tag = .list_style, .count = 1 },
        .{ .tag = .text_align, .count = 1 },
        .{ .tag = .vertical_offset, .count = 1 },
        .{ .tag = .affine, .count = 1 },
        .{ .tag = .rect, .count = 1 },
        .{ .tag = .text_selection, .count = 1 },
        .{ .tag = .custom_action_vec, .count = 1 },
        .{ .tag = .tree_id, .count = 1 },
    };
    var sum: usize = 0;
    for (expected) |family| {
        var seen: usize = 0;
        for (property_value_tags_by_id) |tag| {
            if (tag == family.tag) seen += 1;
        }
        try testing.expectEqual(family.count, seen);
        sum += seen;
    }
    try testing.expectEqual(propertyIdCount, sum);
}

test "the layout matches what Zig 0.16.0 measured" {
    try testing.expectEqual(@as(usize, 56), @sizeOf(PropertyValue));
    try testing.expectEqual(@as(usize, 8), @alignOf(PropertyValue));
    try testing.expectEqual(@as(usize, 1), @sizeOf(PropertyValueTag));
    try testing.expectEqual(@as(usize, 56), @sizeOf([1]PropertyValue));
    // Nothing here asserts the size of `Property` or `Properties`: they are
    // plain structs, nothing outside this module depends on their layout, and
    // Zig 0.16.0 is free to reorder their fields.
    try testing.expect(@sizeOf(Property) > @sizeOf([1]PropertyValue));
}

test "every property round trips through set, get and clear" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    inline for (property_descriptors, 0..) |row, index| {
        // The store takes ownership of `written`, so it is the store that
        // releases it; `expected` is this test's own copy and is released
        // here.
        const written = try sampleValue(row.tag, testing.allocator);
        try properties.set(row.id, written);

        // The rows went in ascending, so the sorted slice must be too.
        try testing.expectEqual(index, properties.find(row.id).?);

        // No print on the failure path: the test runner treats anything a
        // passing test writes to stderr as a logged error, and this arm runs in
        // tests that pass. `expectEqual` below already names the value.
        const read_back = properties.get(row.id) orelse return error.NoSuchKey;
        try testing.expectEqual(row.tag, read_back.getTag());
        var expected = try sampleValue(row.tag, testing.allocator);
        defer expected.deinit(testing.allocator);
        try testing.expect(expected.eql(read_back.*));
    }
    try testing.expectEqual(propertyIdCount, properties.count());

    // Every one of them clears to absent, which is the half of the round trip
    // a read-only sweep would miss.
    inline for (property_descriptors) |row| {
        properties.clear(row.id);
        try testing.expect(properties.get(row.id) == null);
    }
    try testing.expectEqual(@as(usize, 0), properties.count());
}

test "an odd search span finds the property it names" {
    // Four entries make `high - low` odd for every middle probe, which is the
    // span that made a checked midpoint trap instead of rounding down.
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    inline for (property_descriptors[0..4]) |row| {
        try properties.set(row.id, try sampleValue(row.tag, testing.allocator));
    }
    inline for (property_descriptors[0..4], 0..) |row, position| {
        try testing.expectEqual(position, properties.find(row.id).?);
    }
    // The neighbour beyond the last one is absent, not mis-placed.
    try testing.expect(properties.find(propertyAt(4)) == null);
    try testing.expectEqual(@as(usize, 4), properties.count());
}

test "an insert at every position of a small store lands in that position" {
    // Four properties, and every removal in rank order, because the
    // sorted-insert path is the one where an off-by-one in the binary search
    // is silent whenever the span happens to be even.
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    inline for (property_descriptors[0..4]) |row| {
        try properties.set(row.id, try sampleValue(row.tag, testing.allocator));
    }
    try testing.expectEqual(@as(usize, 4), properties.count());
    inline for (property_descriptors[0..4], 0..) |row, position| {
        try testing.expectEqual(position, properties.find(row.id).?);
        try testing.expectEqual(row.id, properties.items.items[position].id);
    }
    inline for (property_descriptors[0..4]) |row| {
        properties.clear(row.id);
        try testing.expect(properties.get(row.id) == null);
    }
    try testing.expectEqual(@as(usize, 0), properties.count());
}

test "a cleared property is absent, not a placeholder" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try properties.set(.label, propertyValueFrom(.string, try sampleBytes(testing.allocator, "a")));
    try testing.expectEqual(@as(usize, 1), properties.count());

    properties.clear(.label);
    try testing.expectEqual(@as(usize, 0), properties.count());
    try testing.expect(properties.get(.label) == null);
    try testing.expect(properties.find(.label) == null);
    // Clearing again is the same as never having set it.
    properties.clear(.label);
    try testing.expectEqual(@as(usize, 0), properties.count());
}

test "every property is absent again once it is cleared" {
    var properties = try populatedStore();
    defer properties.deinit();
    try testing.expectEqual(propertyIdCount, properties.count());

    var index: usize = 0;
    while (index < propertyIdCount) : (index += 1) {
        const id = propertyAt(index);
        properties.clear(id);
        try testing.expect(properties.get(id) == null);
    }
    try testing.expectEqual(@as(usize, 0), properties.count());
}

test "the store keeps its slice sorted whatever order it is written in" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    // Written back to front, so an unsorted store would fail the next check.
    const backwards = comptime blk: {
        var collected: [propertyIdCount]PropertyId = undefined;
        for (property_descriptors, 0..) |row, index| {
            collected[propertyIdCount - 1 - index] = row.id;
        }
        break :blk collected;
    };
    inline for (comptime backwards) |id| {
        try properties.set(id, try sampleValue(propertyDescriptor(id).tag, testing.allocator));
    }

    var previous: u8 = 0;
    var first = true;
    for (properties.items.items) |entry| {
        const current = @backingInt(entry.id);
        if (!first) try testing.expect(current > previous);
        previous = current;
        first = false;
    }
    // Every property is still findable, and its slot is its rank.
    var rank: usize = 0;
    while (rank < propertyIdCount) : (rank += 1) {
        try testing.expectEqual(rank, properties.find(propertyAt(rank)).?);
    }
}

test "equality is structural, so write order does not decide it" {
    var forward: Properties = .init(testing.allocator);
    defer forward.deinit();
    var backward: Properties = .init(testing.allocator);
    defer backward.deinit();

    inline for (property_descriptors, 0..) |low_row, index| {
        const high_row = property_descriptors[propertyIdCount - 1 - index];
        try forward.set(low_row.id, try sampleValue(low_row.tag, testing.allocator));
        try backward.set(high_row.id, try sampleValue(high_row.tag, testing.allocator));
    }

    // Both stores end up in the same sorted order whatever order they were
    // written in, and they still compare equal, which is what makes the
    // comparison structural rather than positional.
    try testing.expect(forward.items.items.len == backward.items.items.len);
    try testing.expect(forward.eql(&backward));
    // A subset is not equal to the whole, which is the other half of the
    // answer: equality is not "no property differs".
    var subset: Properties = .init(testing.allocator);
    defer subset.deinit();
    inline for (property_descriptors[0..4]) |row| {
        try subset.set(row.id, try sampleValue(row.tag, testing.allocator));
    }
    try testing.expect(!subset.eql(&forward));

    backward.clear(.label);
    try testing.expect(!forward.eql(&backward));

    var never_set: Properties = .init(testing.allocator);
    defer never_set.deinit();
    try testing.expect(never_set.eql(&never_set));
    try testing.expect(!forward.eql(&never_set));
}

test "getOrInsert appends in place instead of copying the list back" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    // The first push creates the entry and the second appends to the same
    // buffer. The pointer address not moving is the property that makes the
    // push amortised O(1); a copy-then-set push would reallocate every time.
    const first = try properties.getOrInsert(.children, propertyValueFrom(.node_id_vec, .empty));
    try first.node_id_vec.append(properties.gpa, nodeIdFromContent(1));
    const address_after_first = first.node_id_vec.items.ptr;
    const second = try properties.getOrInsert(.children, propertyValueFrom(.node_id_vec, .empty));
    try testing.expectEqual(address_after_first, second.node_id_vec.items.ptr);
    try second.node_id_vec.append(properties.gpa, nodeIdFromContent(2));

    try testing.expectEqual(@as(usize, 1), properties.count());
    const stored = properties.get(.children) orelse return error.ChildrenAbsent;
    try testing.expectEqual(@as(usize, 2), stored.node_id_vec.items.len);
    try testing.expectEqual(@as(u64, 1), stored.node_id_vec.items[0].value);
    try testing.expectEqual(@as(u64, 2), stored.node_id_vec.items[1].value);
}

test "getOrInsert leaves the store unchanged when it cannot allocate" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try properties.set(.label, propertyValueFrom(.string, try sampleBytes(
        testing.allocator,
        "kept",
    )));

    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    // The store runs on the failing allocator, because that is the whole
    // point: `getOrInsert` must allocate the copy of `default` through
    // `self.gpa` and so must refuse.
    var guarded: Properties = .init(failing.allocator());
    defer guarded.deinit();
    // The default is the caller's on the failure path, so this test releases
    // it. That is the guarantee every owning setter's `errdefer` rests on.
    var fallback = propertyValueFrom(.string, try sampleBytes(testing.allocator, "new"));
    defer fallback.deinit(testing.allocator);
    const outcome = guarded.getOrInsert(.description, fallback);
    try testing.expectError(error.OutOfMemory, outcome);
    try testing.expectEqual(@as(usize, 0), guarded.count());
    try testing.expect(guarded.find(.description) == null);

    try testing.expectEqualStrings("kept", properties.get(.label).?.string.items);
}

test "set writes nothing when it cannot allocate" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try properties.set(.label, propertyValueFrom(.string, try sampleBytes(
        testing.allocator,
        "first",
    )));

    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var guarded: Properties = .init(failing.allocator());
    defer guarded.deinit();
    // The value is built through the real allocator, so the only allocation
    // the store attempts is the one that grows `items`.
    var second = propertyValueFrom(.string, try sampleBytes(testing.allocator, "second"));
    defer second.deinit(testing.allocator);
    const outcome = guarded.set(.label, second);
    try testing.expectError(error.OutOfMemory, outcome);
    try testing.expectEqual(@as(usize, 0), guarded.count());
    try testing.expect(guarded.find(.label) == null);

    // The store that could allocate is untouched by the one that could not.
    try testing.expectEqualStrings("first", properties.get(.label).?.string.items);
}

test "a refused write leaves the store exactly as it was" {
    // The value handed to `set` is built through the real allocator, so the
    // store and only the store can fail. `fail_index` names how many
    // allocations succeed first; how many properties that admits depends on
    // how the slice grew, so the assertion is on what the store holds rather
    // than on a count derived from the allocator.
    var fail_index: usize = 0;
    while (fail_index <= 3) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(
            testing.allocator,
            .{ .fail_index = fail_index },
        );
        var guarded: Properties = .init(failing.allocator());
        defer guarded.deinit();

        var accepted: usize = 0;
        inline for (comptime property_descriptors[0..4]) |row| {
            var held = try sampleValue(row.tag, testing.allocator);
            const outcome = guarded.set(row.id, held);
            if (outcome == error.OutOfMemory) {
                // The documented contract, exercised: the store kept every
                // property it already held, wrote nothing for this one, and
                // handed the value back to the caller.
                held.deinit(testing.allocator);
                break;
            }
            try outcome;
            // Ownership has moved to the store, so `held` is not released
            // here. An `errdefer` spanning the call would be a double free.
            accepted += 1;
        }

        try testing.expectEqual(accepted, guarded.count());
        var rank: usize = 0;
        while (rank < 4) : (rank += 1) {
            const present = guarded.find(propertyAt(rank)) != null;
            try testing.expectEqual(rank < accepted, present);
        }
        // Whatever the store did accept is still releasable exactly once,
        // which the testing allocator's leak check proves at the end of this
        // test.
    }
}

test "set replaces a value and releases the one it displaced" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try properties.set(.label, propertyValueFrom(.string, try sampleBytes(
        testing.allocator,
        "first",
    )));
    const held = properties.get(.label) orelse return error.LabelAbsent;
    const first_address = held.string.items.ptr;

    try properties.set(.label, propertyValueFrom(.string, try sampleBytes(
        testing.allocator,
        "second",
    )));
    try testing.expectEqual(@as(usize, 1), properties.count());
    try testing.expectEqualStrings("second", properties.get(.label).?.string.items);
    // The replacement released the old buffer rather than keeping it alive.
    try testing.expect(!std.mem.eql(u8, "first", properties.get(.label).?.string.items));
    try testing.expect(first_address != properties.get(.label).?.string.items.ptr);
}

test "clone copies every property and shares no buffer" {
    var source = try populatedStore();
    defer source.deinit();

    var copy = try source.clone(testing.allocator);
    defer copy.deinit();
    try testing.expect(source.eql(&copy));
    try testing.expectEqual(propertyIdCount, copy.count());

    // Distinct buffers for every owned payload, so releasing one store leaves
    // the other whole.
    const source_bytes =
        (source.get(.label) orelse return error.SourceLabelAbsent).string.items.ptr;
    const copy_bytes = (copy.get(.label) orelse return error.CopyLabelAbsent).string.items.ptr;
    try testing.expect(source_bytes != copy_bytes);
    try testing.expectEqualStrings("label", copy.get(.label).?.string.items);

    // A shared buffer would follow this write to the copy.
    try copy.set(.label, propertyValueFrom(.string, try sampleBytes(testing.allocator, "changed")));
    try testing.expectEqualStrings("label", source.get(.label).?.string.items);
    try testing.expect(!source.eql(&copy));
}

test "cloneInto reuses the destination buffers and drops what is gone" {
    var source: Properties = .init(testing.allocator);
    defer source.deinit();
    try source.set(.label, propertyValueFrom(.string, try sampleBytes(testing.allocator, "label")));
    try source.set(.value, propertyValueFrom(.string, try sampleBytes(testing.allocator, "value")));

    var out: Properties = .init(testing.allocator);
    defer out.deinit();
    try out.set(.label, propertyValueFrom(.string, try sampleBytes(testing.allocator, "label")));
    try out.set(.description, propertyValueFrom(.string, try sampleBytes(
        testing.allocator,
        "gone",
    )));
    const kept_buffer =
        (out.get(.label) orelse return error.DestinationLabelAbsent).string.items.ptr;

    try source.cloneInto(&out);
    try testing.expect(source.eql(&out));
    // The id both stores held kept its allocation; the one only the
    // destination had was released.
    try testing.expectEqual(kept_buffer, out.get(.label).?.string.items.ptr);
    try testing.expect(out.find(.description) == null);

    // Cloning again allocates nothing, which is the point of the reuse.
    const before = out.items.items[0].value.string.items.ptr;
    try source.cloneInto(&out);
    try testing.expect(source.eql(&out));
    try testing.expectEqual(before, out.get(.label).?.string.items.ptr);
}

test "cloneInto sorted merge preserves scroll getters including zero maximum" {
    // New maxima must remain findable between updated scroll positions.
    const numbers = @import("numbers.zig");
    var source: Properties = .init(testing.allocator);
    defer source.deinit();
    try numbers.setScrollX(&source, 0.0);
    try numbers.setScrollXMax(&source, 0.0);
    try numbers.setScrollY(&source, 9.0);
    try numbers.setScrollYMax(&source, 30.0);

    var out: Properties = .init(testing.allocator);
    defer out.deinit();
    try numbers.setScrollX(&out, -2.0);
    try numbers.setScrollY(&out, 4.0);

    try source.cloneInto(&out);
    try testing.expectEqual(@as(?f64, 0.0), numbers.scrollX(&out));
    try testing.expectEqual(@as(?f64, 0.0), numbers.scrollXMax(&out));
    try testing.expectEqual(@as(?f64, 9.0), numbers.scrollY(&out));
    try testing.expectEqual(@as(?f64, 30.0), numbers.scrollYMax(&out));
    try testing.expectEqual(@as(usize, 4), out.count());
    try testing.expect(source.eql(&out));
    for (out.items.items[0 .. out.count() - 1], out.items.items[1..]) |left, right| {
        try testing.expect(@backingInt(left.id) < @backingInt(right.id));
    }
}

test "cloneInto sorted merge owns interleaved strings through allocation failures" {
    // Sweep insertion, payload cloning, reuse, and removal with real stores.
    const Exercise = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var source: Properties = .init(testing.allocator);
            defer source.deinit();
            const source_ids = [_]PropertyId{
                .label,      .value,       .access_key, .author_id,
                .class_name, .font_family, .html_id,    .html_tag,
            };
            for (source_ids) |id| {
                try source.set(id, propertyValueFrom(
                    .string,
                    try sampleBytes(testing.allocator, @tagName(id)),
                ));
            }
            var seed: Properties = .init(testing.allocator);
            defer seed.deinit();
            for ([_]PropertyId{ .description, .value, .class_name, .tooltip }) |id| {
                try seed.set(id, propertyValueFrom(
                    .string,
                    try sampleBytes(testing.allocator, "old destination"),
                ));
            }
            var out = try seed.clone(gpa);
            defer out.deinit();
            const kept_buffer = out.get(.class_name).?.string.items.ptr;

            source.cloneInto(&out) catch |err| {
                // Even a partial copy must keep unique, searchable entries.
                for (out.items.items, 0..) |entry, index| {
                    if (index > 0) {
                        try testing.expect(
                            @backingInt(out.items.items[index - 1].id) < @backingInt(entry.id),
                        );
                    }
                    try testing.expectEqual(index, out.find(entry.id).?);
                }
                return err;
            };
            try testing.expect(source.eql(&out));
            try testing.expectEqual(source_ids.len, out.count());
            try testing.expectEqual(kept_buffer, out.get(.class_name).?.string.items.ptr);
            try testing.expect(out.get(.description) == null);
            try testing.expect(out.get(.tooltip) == null);
            for (source_ids, 0..) |id, index| {
                try testing.expectEqual(index, out.find(id).?);
                try testing.expectEqualStrings(@tagName(id), out.get(id).?.string.items);
                try testing.expect(
                    source.get(id).?.string.items.ptr != out.get(id).?.string.items.ptr,
                );
            }
            const inserted_buffer = out.get(.label).?.string.items.ptr;
            try source.cloneInto(&out);
            try testing.expect(source.eql(&out));
            try testing.expectEqual(inserted_buffer, out.get(.label).?.string.items.ptr);
            try testing.expectEqual(kept_buffer, out.get(.class_name).?.string.items.ptr);
            source.clear(.label);
            try testing.expectEqualStrings("label", out.get(.label).?.string.items);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Exercise.run, .{});
}

test "propertyValueCloneInto reuses the destination list buffer" {
    var first = propertyValueFrom(.string, try sampleBytes(testing.allocator, "abcdef"));
    defer first.deinit(testing.allocator);
    const address = first.string.items.ptr;

    var source = propertyValueFrom(.string, try sampleBytes(testing.allocator, "uvwxyz"));
    defer source.deinit(testing.allocator);
    try propertyValueCloneInto(testing.allocator, &first, source);

    try testing.expectEqual(address, first.string.items.ptr);
    try testing.expectEqualStrings("uvwxyz", first.string.items);
    try testing.expectEqual(@as(usize, 6), first.string.items.len);
}

test "propertyValueCloneInto into a different payload shape replaces the value" {
    var dest = propertyValueFrom(.node_id, nodeIdFromContent(1));
    defer dest.deinit(testing.allocator);

    var source = propertyValueFrom(.string, try sampleBytes(testing.allocator, "text"));
    defer source.deinit(testing.allocator);
    try propertyValueCloneInto(testing.allocator, &dest, source);

    try testing.expectEqual(PropertyValueTag.string, dest.getTag());
    try testing.expectEqualStrings("text", dest.string.items);
}

test "cloning a custom-action value into itself leaves the actions whole" {
    const gpa = testing.allocator;
    // The list is built inside a block so the guard that releases it on
    // failure cannot outlive the move into the value below.
    const actions = built: {
        var list: std.ArrayList(CustomAction) = .empty;
        errdefer deinitActions(gpa, &list);
        try list.ensureTotalCapacity(gpa, 2);
        try list.append(gpa, try CustomAction.init(gpa, 1, "first"));
        try list.append(gpa, try CustomAction.init(gpa, 2, "second"));
        // Capacity down to the length, so the first append of any rebuild
        // moves the buffer. That is the state the guard exists for: without
        // it the teardown frees every description and the rebuild reads them
        // back out of a buffer the growth has already released.
        list.shrinkRetainingCapacity(list.items.len);
        break :built list;
    };

    var value = propertyValueFrom(.custom_action_vec, actions);
    defer value.deinit(gpa);
    const first_buffer = value.custom_action_vec.items[0].description.items.ptr;

    // The one call nothing forbids: one value, passed twice.
    try propertyValueCloneInto(gpa, &value, value);

    try testing.expectEqual(@as(usize, 2), value.custom_action_vec.items.len);
    try testing.expectEqual(@as(i32, 1), value.custom_action_vec.items[0].id);
    try testing.expectEqualStrings("first", value.custom_action_vec.items[0].description.items);
    try testing.expectEqual(@as(i32, 2), value.custom_action_vec.items[1].id);
    try testing.expectEqualStrings("second", value.custom_action_vec.items[1].description.items);
    // A self-clone is a no-op rather than a copy, so the buffer the value
    // already held is the one it still holds. That is what separates the guard
    // from a rebuild that merely came out with the right contents.
    try testing.expectEqual(first_buffer, value.custom_action_vec.items[0].description.items.ptr);
}

test "a store released twice leaks nothing and a fresh one is empty" {
    var properties: Properties = .init(testing.allocator);
    try properties.set(.label, propertyValueFrom(.string, try sampleBytes(testing.allocator, "a")));
    try properties.set(.children, propertyValueFrom(.node_id_vec, try sampleNodes(
        testing.allocator,
    )));
    try properties.set(.custom_actions, propertyValueFrom(.custom_action_vec, try sampleActionList(
        testing.allocator,
    )));
    try properties.set(.transform, propertyValueFrom(.affine, affine_identity));
    try properties.set(.word_starts, propertyValueFrom(.length_vec, try sampleBytes(
        testing.allocator,
        "ab",
    )));
    try properties.set(.character_positions, propertyValueFrom(.coord_vec, try samplePoints(
        testing.allocator,
    )));
    properties.deinit();
    // The testing allocator's leak check at the end of this test is the
    // evidence that every owned payload was released exactly once.
    try testing.expectEqual(@as(usize, 0), properties.count());
    properties.deinit();
}

test "value equality reads payload bytes and never buffer addresses" {
    var one = propertyValueFrom(.string, try sampleBytes(testing.allocator, "same"));
    defer one.deinit(testing.allocator);
    var two = propertyValueFrom(.string, try sampleBytes(testing.allocator, "same"));
    defer two.deinit(testing.allocator);

    try testing.expect(one.string.items.ptr != two.string.items.ptr);
    try testing.expect(one.eql(two));

    var other = propertyValueFrom(.string, try sampleBytes(testing.allocator, "other"));
    defer other.deinit(testing.allocator);
    try testing.expect(!one.eql(other));
    // A different tag holding the same bytes is a different value.
    var same_bytes = propertyValueFrom(.length_vec, try sampleBytes(testing.allocator, "same"));
    defer same_bytes.deinit(testing.allocator);
    try testing.expect(!one.eql(same_bytes));
    try testing.expect(!one.eql(.none));
    try testing.expect(one.eql(one));
}

test "node id list equality compares ids and lengths" {
    var short_list = propertyValueFrom(.node_id_vec, try sampleNodes(testing.allocator));
    defer short_list.deinit(testing.allocator);
    var same = try propertyValueClone(testing.allocator, short_list);
    defer same.deinit(testing.allocator);
    var longer = propertyValueFrom(.node_id_vec, .empty);
    defer longer.deinit(testing.allocator);
    try longer.node_id_vec.append(testing.allocator, nodeIdFromContent(3));

    try testing.expect(short_list.eql(same));
    try testing.expect(!short_list.eql(longer));
    same.node_id_vec.items[0] = nodeIdFromContent(99);
    try testing.expect(!short_list.eql(same));
}

test "NaN payloads compare unequal, as the derived PartialEq did" {
    const nan = std.math.nan(f64);
    try testing.expect(!propertyValueFrom(.f64_, nan).eql(propertyValueFrom(.f64_, nan)));
    try testing.expect(propertyValueFrom(.f64_, 0.0).eql(propertyValueFrom(.f64_, -0.0)));
}

test "custom action equality compares the identifier and the description" {
    var one = propertyValueFrom(.custom_action_vec, try sampleActionList(testing.allocator));
    defer one.deinit(testing.allocator);
    var same = try propertyValueClone(testing.allocator, one);
    defer same.deinit(testing.allocator);
    try testing.expect(one.eql(same));

    var other_id: std.ArrayList(CustomAction) = .empty;
    errdefer deinitActions(testing.allocator, &other_id);
    var fresh = try CustomAction.init(testing.allocator, 6, "drag");
    errdefer fresh.deinit(testing.allocator);
    try other_id.append(testing.allocator, fresh);
    try testing.expect(!one.eql(propertyValueFrom(.custom_action_vec, other_id)));
    // The list buffer alone would leave `fresh`'s description behind.
    deinitActions(testing.allocator, &other_id);
}

test "every PropertyValue tag has a payload type and a tag name" {
    inline for (comptime std.enums.values(PropertyValueTag)) |tag| {
        const payload_type = PropertyValuePayloadType(tag);
        // `none` is the only tag without a payload of its own.
        try testing.expectEqual(tag == .none, payload_type == void);
    }
    try testing.expectEqualStrings("f64_", @tagName(PropertyValueTag.f64_));
    try testing.expectEqualStrings("bool_", @tagName(PropertyValueTag.bool_));
}

test "flag masks are one bit each and a set round trips" {
    inline for (comptime std.enums.values(Flag)) |flag| {
        const mask = flagMask(flag);
        // One bit, and it is the flag's own position.
        try testing.expectEqual(mask & (mask -% 1), 0);
        try testing.expectEqual(@as(u32, 1) << @as(u5, @intCast(@backingInt(flag))), mask);
        try testing.expect(flagSetContains(mask, flag));
        try testing.expectEqual(mask, flagSetDifference(mask, 0));
        try testing.expectEqual(mask, flagSetUnion(0, mask));
    }

    var set: u32 = 0;
    var out: [flagCount]Flag = undefined;
    try testing.expectEqual(@as(usize, 0), flagSetMembers(set, &out).len);
    inline for (comptime std.enums.values(Flag)) |flag| set = flagSetUnion(set, flagMask(flag));
    try testing.expectEqual(@as(usize, flagCount), flagSetMembers(set, &out).len);
    try testing.expectEqual(Flag.hidden, out[0]);
    try testing.expectEqual(Flag.is_suggestion, out[flagCount - 1]);
    try testing.expectEqual(@as(usize, 0), @popCount(flagSetDifference(set, set)));
}

test "the 18 flag bit positions are dense and reach 17" {
    try testing.expectEqual(@as(usize, 18), flagCount);
    try testing.expectEqual(@as(u8, 17), @backingInt(Flag.is_suggestion));
    // Every position in 0 to 17 is claimed by exactly one flag, which is what
    // makes the discriminant the bit position.
    var claimed: u32 = 0;
    inline for (comptime std.enums.values(Flag)) |flag| {
        const mask = flagMask(flag);
        try testing.expectEqual(@as(u32, 0), claimed & mask);
        claimed |= mask;
    }
    try testing.expectEqual(@as(u32, 0x0003ffff), claimed);
}

test "format names the tag of a payload" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    var label = propertyValueFrom(.string, try sampleBytes(testing.allocator, "hello"));
    defer label.deinit(testing.allocator);
    try label.format(&writer);
    try testing.expectEqualStrings("string(5)", buffer[0..writer.end]);

    // The writer appends, so each comparison starts where the last one ended.
    const after_string = writer.end;
    // `{f}` does not reach a union's member on 0.16, so this calls the method.
    try propertyValueFrom(.f64_, 1.5).format(&writer);
    const after_number = writer.end;
    const absent: PropertyValue = .none;
    try absent.format(&writer);
    try testing.expectEqualStrings("f64(1.5)", buffer[after_string..after_number]);
    try testing.expectEqualStrings("none", buffer[after_number..writer.end]);

    var kids = propertyValueFrom(.node_id_vec, try sampleNodes(testing.allocator));
    defer kids.deinit(testing.allocator);
    try kids.format(&writer);
    try testing.expectEqualStrings("node_id_vec(2)", buffer[after_number + 4 .. writer.end]);
}
