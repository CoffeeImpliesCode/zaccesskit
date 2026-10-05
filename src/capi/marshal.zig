//! The conversions between the port's Zig types and the header's `extern
//! struct` forms. Every other module under `src/capi/` imports from here and
//! defines no conversion of its own.
//!
//! **Upstream.** `accesskit-c` does this work in four places and this module
//! ports them. `accesskit-c/src/lib.rs:83-156` is the shim box plumbing, where
//! an owning Rust type is handed to C behind a pointer.
//! `accesskit-c/src/lib.rs:160-204` is the shim optional structs, which is the
//! flag-and-payload shape this header repeats twenty-three times.
//! `accesskit-c/src/common.rs:783-798` is the custom-action deep copy, and
//! `accesskit-c/src/common.rs:1084-1090` is the `Drop` that releases the
//! `char *` an action payload owns. The conversions themselves are written by
//! the `impl_*` macro families at `accesskit-c/src/common.rs:29-389`; this port
//! writes them out because a macro cannot hold a comptime layout pin. The
//! callback adapters at `accesskit-c/src/common.rs:1133-1234` stay in
//! `src/capi/root.zig`.
//!
//! **What the header actually declares.** `include/zaccesskit.h` is 6581 lines
//! and declares 498 functions, 40 laid-out structs and exactly one union: the
//! anonymous union inside `accesskit_action_data` at lines 1623-1648, which
//! `src/schema/update.zig:313` already owns. **There is no
//! `accesskit_platform_*` union and no `accesskit_property_value` type in this
//! header.** The brief that named them names upstream's `PlatformValue`, which
//! upstream reaches through a D-Bus or JNI message body and this port's header
//! replaces with one typed getter per property. Nothing here converts one,
//! because nothing declares one.
//!
//! **Line numbers.** Every header line below is measured from the file as it
//! stands. `docs/40-capi-build-map.md` section 1 cites a 6572-line header and
//! every line it names from `accesskit_node_ids` onward is 9 lower than the
//! file's, because the header grew by 9 lines before that point. The sizes,
//! alignments and payload offsets are unaffected and are quoted from the map
//! and from the header's own table at lines 6509-6549, which agree.
//!
//! **What was checked against what.** `zig translate-c` runs clean on this
//! host, so the header's own types are available as generated Zig and a
//! disagreement with them is real. Every one of the 39 layouts below was
//! compiled against the translator's output and asserted equal on `@sizeOf`,
//! `@alignOf` and the payload `@offsetOf`: 39 of 39 agree. Two field
//! *spellings* differ from the generated names and neither is a layout
//! difference, so both are recorded rather than changed. `TextPosition`'s
//! `node_id` is the header's `node`, which
//! `src/schema/values.zig:35-38` records as a deliberate departure from rule
//! Z4 because `node` alone is ambiguous beside the other node-bearing types;
//! it is one `uint64_t` at offset 0 either way. `CActionData.payload` is the
//! header's anonymous union, which has no name for the translator to carry
//! and which it therefore calls `unnamed_0`. The 40th layout,
//! `accesskit_opt_lresult`, has no generated counterpart on a host that is not
//! Windows, which is why its pin is written against `isize`.
//!
//! **The two directions, and why one of them has no name.** Every form here
//! crosses outward only: the port's getters produce them and no C caller hands
//! one back, because the matching setter takes the bare payload
//! (`accesskit_node_set_color_value` takes `struct accesskit_color`, not
//! `struct accesskit_opt_color`). So each conversion is one function in one
//! direction, and each test writes the header's bytes at the header's offsets
//! and reads them back through the port's own field names. That second half is
//! the direction a one-way test cannot reach, and it is the half that fails if
//! a field moves. `actionDataFromC` is the one form that genuinely arrives
//! from C, and it crosses both ways.
//!
//! **Naming.** One function per header type that needs a conversion, named
//! after that type in `snake_case` with the direction as a suffix: the header's
//! `accesskit_opt_double` gives `opt_double_to_c`. Where a conversion is a
//! single field copy with no struct of its own, this module publishes a `const`
//! instead of a function.
//!
//! **Every `pub` declaration this module owns**, and nothing else. Four
//! groups, in the order a caller meets them.
//!
//! 1. **The 27 C aggregate types.** `CNodeIds`, `COptNodeId`, `COptTreeId`,
//!    `COptDouble`, `COptFloat`, `COptIndex`, `COptColor`,
//!    `COptTextDecoration`, `COptBool`, `COptInvalid`, `COptToggled`,
//!    `COptLive`, `COptTextDirection`, `COptOrientation`, `COptSortDirection`,
//!    `COptAriaCurrent`, `COptAutoComplete`, `COptHasPopup`, `COptListStyle`,
//!    `COptTextAlign`, `COptVerticalOffset`, `COptRect`, `COptTextSelection`,
//!    `COptCoords`, `CCustomActions`, `COptLResult`, `CustomActionHandle`.
//! 2. **The 24 optional conversions.** `opt_node_id_to_c`,
//!    `opt_tree_id_to_c`, `opt_double_to_c`, `opt_float_to_c`,
//!    `opt_index_to_c`, `opt_color_to_c`, `opt_text_decoration_to_c`,
//!    `opt_bool_to_c`, `opt_invalid_to_c`, `opt_toggled_to_c`, `opt_live_to_c`,
//!    `opt_text_direction_to_c`, `opt_orientation_to_c`,
//!    `opt_sort_direction_to_c`, `opt_aria_current_to_c`,
//!    `opt_auto_complete_to_c`, `opt_has_popup_to_c`, `opt_list_style_to_c`,
//!    `opt_text_align_to_c`, `opt_vertical_offset_to_c`, `opt_rect_to_c`,
//!    `opt_text_selection_to_c`, `opt_coords_to_c`, `opt_lresult_to_c`.
//! 3. **The list, string and handle conversions.** `node_ids_to_c`,
//!    `lengths_to_c`, `dup_c_string`, `string_free`, `c_string_to_slice`,
//!    `c_bytes_to_slice`, `custom_actions_to_c`, `custom_actions_deinit`.
//! 4. **The four action-data forms `src/schema/update.zig` already owns,**
//!    re-exported rather than written twice, as `docs/40-capi-build-map.md`
//!    section 8 step 2 requires: `CActionData`, `COptActionData`,
//!    `CActionRequest`, `actionDataToC`, `actionDataFromC`,
//!    `cActionDataDeinit`, `cActionRequestDeinit`.
//!
//! Three error sets go with them and are named rather than inferred, because a
//! caller has to tell which of them can reach `accesskit_last_error`:
//! `DupCStringError`, `CustomActionsToCError`, and the two
//! `src/schema/update.zig` owns beside its own functions.
//!
//! **The comptime bounds.** Three loops run over domains and all three are a
//! `for` over a comptime tuple inside a `comptime` block, so each bound is the
//! tuple's length and each is asserted: 23 flag-and-payload optionals (`optional_rows`), 40
//! laid-out structs (`laid_out_structs`) and 31 payload offsets
//! (`payload_rows`). The counts come from the header: 25 `accesskit_opt_*`
//! structs, of which two are held out below because their payload is not a
//! single `value`, and 40 `typedef struct NAME { … } NAME;` bodies of which one
//! is `_WIN32`-only and so 39 exist on this host.
//!
//! **What this module does not own.** The runtime channel —
//! `accesskit_set_allocator`, `accesskit_last_error` and the `accesskit_error`
//! tag slot — belongs to `src/capi/root.zig`; `docs/40-capi-build-map.md`
//! section 2 assigns all three there and marks their conversion "none (owns the
//! channel)". The four function-pointer typedefs of
//! `accesskit-c/include/accesskit.h:1707-1748` cross as `?*anyopaque` and a
//! `callconv(.c)` pointer with nothing to convert, and belong to the platform
//! adapters. `ACCESSKIT_TREE_ID_ROOT` is `schema.tree_id_root`, an
//! `extern struct` already.
//!
//! Nothing here reads a clock, names `zio`, takes an `io`, or holds a global.
//! Two functions allocate and both take `gpa` first.

const std = @import("std");

const schema = @import("../schema/root.zig");

const testing = std.testing;

// --- The Zig types the conversions go between ---------------------------------

const Color = schema.Color;
const CustomAction = schema.CustomAction;
const Invalid = schema.Invalid;
const NodeId = schema.NodeId;
const Rect = schema.Rect;
const TextDecoration = schema.TextDecoration;
const TextSelection = schema.TextSelection;
const TreeId = schema.TreeId;

/// The one thing the header says the port writes into an absent optional's
/// payload: a zero. `accesskit-c/include/accesskit.h:1062-1067` spells it out,
/// and calls it a diagnostic aid rather than a contract. The pointer is
/// non-null for the same reason `accesskit_node_children` promises a non-null
/// `values` for an unset list.
const no_coords: [0]f32 = .{};

// --- The optional forms --------------------------------------------------------
// `accesskit-c/include/accesskit.h:1060-1428`. One shape, twenty-three times
// here: `bool has_value` at offset 0, then the payload at the offset the
// header's table publishes. Two of the header's twenty-five
// `accesskit_opt_*` structs are declared beside this table rather than in it,
// because their payload is not a single `value`: `accesskit_opt_coords` at
// `:1229` carries `length` and `values`, and `accesskit_opt_action_data` at
// `:1661` is already an `extern struct` in `src/schema/update.zig:350`.

/// One row of `optional_rows`, in header order.
const OptionalRow = struct {
    /// The C type name the header gives the struct, for the failure message.
    c_name: []const u8,
    /// The `extern struct` this module declares for it.
    c_type: type,
    /// The Zig type the payload is a copy of. Never a slice.
    payload: type,
    /// The offset the header's table publishes for the payload field.
    payload_offset: usize,
};

/// The 23 flag-and-payload optionals, in the header's declaration order.
///
/// The bound is this tuple's length: the header declares 25
/// `accesskit_opt_*` structs, this holds the 22 that are portable and the one
/// that is `_WIN32`-only, and the two whose payload is not a single `value`
/// are declared outside it. The test `the optional table covers every optional
/// the header declares` is what checks that arithmetic against the table.
const optional_rows = [_]OptionalRow{
    .{
        .c_name = "accesskit_opt_node_id",
        .c_type = COptNodeId,
        .payload = NodeId,
        .payload_offset = 8,
    },
    .{
        .c_name = "accesskit_opt_tree_id",
        .c_type = COptTreeId,
        .payload = TreeId,
        .payload_offset = 1,
    },
    .{
        .c_name = "accesskit_opt_double",
        .c_type = COptDouble,
        .payload = f64,
        .payload_offset = 8,
    },
    .{ .c_name = "accesskit_opt_float", .c_type = COptFloat, .payload = f32, .payload_offset = 4 },
    .{
        .c_name = "accesskit_opt_index",
        .c_type = COptIndex,
        .payload = usize,
        .payload_offset = 8,
    },
    .{
        .c_name = "accesskit_opt_color",
        .c_type = COptColor,
        .payload = Color,
        .payload_offset = 1,
    },
    .{
        .c_name = "accesskit_opt_text_decoration",
        .c_type = COptTextDecoration,
        .payload = TextDecoration,
        .payload_offset = 1,
    },
    .{ .c_name = "accesskit_opt_bool", .c_type = COptBool, .payload = bool, .payload_offset = 1 },
    .{
        .c_name = "accesskit_opt_invalid",
        .c_type = COptInvalid,
        .payload = Invalid,
        .payload_offset = 1,
    },
    .{
        .c_name = "accesskit_opt_toggled",
        .c_type = COptToggled,
        .payload = schema.Toggled,
        .payload_offset = 1,
    },
    .{
        .c_name = "accesskit_opt_live",
        .c_type = COptLive,
        .payload = schema.Live,
        .payload_offset = 1,
    },
    .{
        .c_name = "accesskit_opt_text_direction",
        .c_type = COptTextDirection,
        .payload = schema.TextDirection,
        .payload_offset = 1,
    },
    .{
        .c_name = "accesskit_opt_orientation",
        .c_type = COptOrientation,
        .payload = schema.Orientation,
        .payload_offset = 1,
    },
    .{
        .c_name = "accesskit_opt_sort_direction",
        .c_type = COptSortDirection,
        .payload = schema.SortDirection,
        .payload_offset = 1,
    },
    .{
        .c_name = "accesskit_opt_aria_current",
        .c_type = COptAriaCurrent,
        .payload = schema.AriaCurrent,
        .payload_offset = 1,
    },
    .{
        .c_name = "accesskit_opt_auto_complete",
        .c_type = COptAutoComplete,
        .payload = schema.AutoComplete,
        .payload_offset = 1,
    },
    .{
        .c_name = "accesskit_opt_has_popup",
        .c_type = COptHasPopup,
        .payload = schema.HasPopup,
        .payload_offset = 1,
    },
    .{
        .c_name = "accesskit_opt_list_style",
        .c_type = COptListStyle,
        .payload = schema.ListStyle,
        .payload_offset = 1,
    },
    .{
        .c_name = "accesskit_opt_text_align",
        .c_type = COptTextAlign,
        .payload = schema.TextAlign,
        .payload_offset = 1,
    },
    .{
        .c_name = "accesskit_opt_vertical_offset",
        .c_type = COptVerticalOffset,
        .payload = schema.VerticalOffset,
        .payload_offset = 1,
    },
    .{ .c_name = "accesskit_opt_rect", .c_type = COptRect, .payload = Rect, .payload_offset = 8 },
    .{
        .c_name = "accesskit_opt_text_selection",
        .c_type = COptTextSelection,
        .payload = TextSelection,
        .payload_offset = 8,
    },
    .{
        .c_name = "accesskit_opt_lresult",
        .c_type = COptLResult,
        .payload = isize,
        .payload_offset = 8,
    },
};

/// The list-shaped optional. `accesskit-c/include/accesskit.h:1229-1233`.
///
/// It is the one optional with no `value` field, so it does not appear in
/// `optional_rows`: the payload the header's table publishes is `values` at
/// offset 16, and `length` sits between the flag and it at offset 8.
pub const COptCoords = extern struct {
    /// `bool has_value;` at `:1230`. False when the property is unset.
    has_value: bool,
    /// `size_t length;` at `:1231`. An element count, not a byte count.
    length: usize,
    /// `const float *values;` at `:1232`. Borrows the array the node owns; the
    /// node must stay alive and this list unmodified while a caller reads it,
    /// and no function releases it.
    values: [*c]const f32,
};

// --- The 40 laid-out structs ---------------------------------------------------
// The header's own table, `accesskit-c/include/accesskit.h:6509-6549`, plus the
// three rows it names outside that table: the two action-data forms at
// `:6547-6549` and the `_WIN32`-only `accesskit_opt_lresult` it says at `:6551`
// it leaves out. So 37 rows plus three, and 39 of the 40 exist on this host.
// Sizes and alignments are the header's measured numbers and
// `docs/40-capi-build-map.md` section 3.2's independent ones; they agree on all
// 37 the header prints.

/// One row of `laid_out_structs`.
const LayoutRow = struct {
    /// The name the header publishes the row under.
    c_name: []const u8,
    /// The Zig type the port crosses for it, whichever module declares it.
    zig_type: type,
    /// `@sizeOf`, measured.
    size: usize,
    /// `@alignOf`, measured. Spelled out because `align` is a Zig keyword.
    alignment: u29,
};

/// The 40 laid-out aggregates, in the header's table order.
///
/// The bound is this tuple's length: 37 rows are the header's printed table, two
/// are the action-data forms it names after it at `:6547-6549`, and one is the
/// `_WIN32`-only `accesskit_opt_lresult` the table says it omits at `:6551`.
const laid_out_structs = [_]LayoutRow{
    .{ .c_name = "accesskit_node_ids", .zig_type = CNodeIds, .size = 16, .alignment = 8 },
    .{ .c_name = "accesskit_opt_node_id", .zig_type = COptNodeId, .size = 16, .alignment = 8 },
    .{ .c_name = "accesskit_tree_id", .zig_type = TreeId, .size = 16, .alignment = 1 },
    .{ .c_name = "accesskit_opt_tree_id", .zig_type = COptTreeId, .size = 17, .alignment = 1 },
    .{ .c_name = "accesskit_opt_double", .zig_type = COptDouble, .size = 16, .alignment = 8 },
    .{ .c_name = "accesskit_opt_float", .zig_type = COptFloat, .size = 8, .alignment = 4 },
    .{ .c_name = "accesskit_opt_index", .zig_type = COptIndex, .size = 16, .alignment = 8 },
    .{ .c_name = "accesskit_color", .zig_type = Color, .size = 4, .alignment = 1 },
    .{ .c_name = "accesskit_opt_color", .zig_type = COptColor, .size = 5, .alignment = 1 },
    .{
        .c_name = "accesskit_text_decoration",
        .zig_type = TextDecoration,
        .size = 5,
        .alignment = 1,
    },
    .{
        .c_name = "accesskit_opt_text_decoration",
        .zig_type = COptTextDecoration,
        .size = 6,
        .alignment = 1,
    },
    .{ .c_name = "accesskit_lengths", .zig_type = CLengths, .size = 16, .alignment = 8 },
    .{ .c_name = "accesskit_opt_coords", .zig_type = COptCoords, .size = 24, .alignment = 8 },
    .{ .c_name = "accesskit_opt_bool", .zig_type = COptBool, .size = 2, .alignment = 1 },
    .{ .c_name = "accesskit_opt_invalid", .zig_type = COptInvalid, .size = 2, .alignment = 1 },
    .{ .c_name = "accesskit_opt_toggled", .zig_type = COptToggled, .size = 2, .alignment = 1 },
    .{ .c_name = "accesskit_opt_live", .zig_type = COptLive, .size = 2, .alignment = 1 },
    .{
        .c_name = "accesskit_opt_text_direction",
        .zig_type = COptTextDirection,
        .size = 2,
        .alignment = 1,
    },
    .{
        .c_name = "accesskit_opt_orientation",
        .zig_type = COptOrientation,
        .size = 2,
        .alignment = 1,
    },
    .{
        .c_name = "accesskit_opt_sort_direction",
        .zig_type = COptSortDirection,
        .size = 2,
        .alignment = 1,
    },
    .{
        .c_name = "accesskit_opt_aria_current",
        .zig_type = COptAriaCurrent,
        .size = 2,
        .alignment = 1,
    },
    .{
        .c_name = "accesskit_opt_auto_complete",
        .zig_type = COptAutoComplete,
        .size = 2,
        .alignment = 1,
    },
    .{ .c_name = "accesskit_opt_has_popup", .zig_type = COptHasPopup, .size = 2, .alignment = 1 },
    .{ .c_name = "accesskit_opt_list_style", .zig_type = COptListStyle, .size = 2, .alignment = 1 },
    .{ .c_name = "accesskit_opt_text_align", .zig_type = COptTextAlign, .size = 2, .alignment = 1 },
    .{
        .c_name = "accesskit_opt_vertical_offset",
        .zig_type = COptVerticalOffset,
        .size = 2,
        .alignment = 1,
    },
    .{ .c_name = "accesskit_affine", .zig_type = schema.Affine, .size = 48, .alignment = 8 },
    .{ .c_name = "accesskit_rect", .zig_type = Rect, .size = 32, .alignment = 8 },
    .{ .c_name = "accesskit_opt_rect", .zig_type = COptRect, .size = 40, .alignment = 8 },
    .{
        .c_name = "accesskit_text_position",
        .zig_type = schema.TextPosition,
        .size = 16,
        .alignment = 8,
    },
    .{
        .c_name = "accesskit_text_selection",
        .zig_type = TextSelection,
        .size = 32,
        .alignment = 8,
    },
    .{
        .c_name = "accesskit_opt_text_selection",
        .zig_type = COptTextSelection,
        .size = 40,
        .alignment = 8,
    },
    .{
        .c_name = "accesskit_custom_actions",
        .zig_type = CCustomActions,
        .size = 16,
        .alignment = 8,
    },
    .{ .c_name = "accesskit_point", .zig_type = schema.Point, .size = 16, .alignment = 8 },
    .{ .c_name = "accesskit_vec2", .zig_type = schema.Vec2, .size = 16, .alignment = 8 },
    .{ .c_name = "accesskit_size", .zig_type = schema.Size, .size = 16, .alignment = 8 },
    .{
        .c_name = "accesskit_opt_action_data",
        .zig_type = schema.COptActionData,
        .size = 48,
        .alignment = 8,
    },
    .{
        .c_name = "accesskit_action_request",
        .zig_type = schema.CActionRequest,
        .size = 80,
        .alignment = 8,
    },
    .{
        .c_name = "accesskit_action_data",
        .zig_type = schema.CActionData,
        .size = 40,
        .alignment = 8,
    },
    .{ .c_name = "accesskit_opt_lresult", .zig_type = COptLResult, .size = 16, .alignment = 8 },
};

/// One row of `payload_rows`: the offset of one named field.
const PayloadRow = struct {
    /// The name the header publishes the aggregate under.
    c_name: []const u8,
    /// The Zig type that crosses for it.
    zig_type: type,
    /// The field the header's prose column names: `value` on an optional,
    /// `values` on a list, and `-` where the type has no payload field.
    field: []const u8,
    /// The offset the header publishes for it.
    offset: usize,
};

/// The 31 payload offsets the header's prose column publishes.
///
/// The bound is this tuple's length, and `the payload table covers every
/// aggregate that names a payload` asserts it against the count of aggregates
/// in `laid_out_structs` that do: 40 less the nine the header's column prints
/// as `-`, which are `accesskit_tree_id`, `accesskit_color`,
/// `accesskit_text_decoration`, `accesskit_affine`, `accesskit_rect`,
/// `accesskit_text_position`, `accesskit_point`, `accesskit_vec2` and
/// `accesskit_size`. Two rows carry the corrected field, and say so.
const payload_rows = [_]PayloadRow{
    .{ .c_name = "accesskit_node_ids", .zig_type = CNodeIds, .field = "values", .offset = 8 },
    .{ .c_name = "accesskit_opt_node_id", .zig_type = COptNodeId, .field = "value", .offset = 8 },
    .{ .c_name = "accesskit_opt_tree_id", .zig_type = COptTreeId, .field = "value", .offset = 1 },
    .{ .c_name = "accesskit_opt_double", .zig_type = COptDouble, .field = "value", .offset = 8 },
    .{ .c_name = "accesskit_opt_float", .zig_type = COptFloat, .field = "value", .offset = 4 },
    .{ .c_name = "accesskit_opt_index", .zig_type = COptIndex, .field = "value", .offset = 8 },
    .{ .c_name = "accesskit_opt_color", .zig_type = COptColor, .field = "value", .offset = 1 },
    .{
        .c_name = "accesskit_opt_text_decoration",
        .zig_type = COptTextDecoration,
        .field = "value",
        .offset = 1,
    },
    .{ .c_name = "accesskit_lengths", .zig_type = CLengths, .field = "values", .offset = 8 },
    .{ .c_name = "accesskit_opt_coords", .zig_type = COptCoords, .field = "values", .offset = 16 },
    .{ .c_name = "accesskit_opt_bool", .zig_type = COptBool, .field = "value", .offset = 1 },
    .{ .c_name = "accesskit_opt_invalid", .zig_type = COptInvalid, .field = "value", .offset = 1 },
    .{ .c_name = "accesskit_opt_toggled", .zig_type = COptToggled, .field = "value", .offset = 1 },
    .{ .c_name = "accesskit_opt_live", .zig_type = COptLive, .field = "value", .offset = 1 },
    .{
        .c_name = "accesskit_opt_text_direction",
        .zig_type = COptTextDirection,
        .field = "value",
        .offset = 1,
    },
    .{
        .c_name = "accesskit_opt_orientation",
        .zig_type = COptOrientation,
        .field = "value",
        .offset = 1,
    },
    .{
        .c_name = "accesskit_opt_sort_direction",
        .zig_type = COptSortDirection,
        .field = "value",
        .offset = 1,
    },
    .{
        .c_name = "accesskit_opt_aria_current",
        .zig_type = COptAriaCurrent,
        .field = "value",
        .offset = 1,
    },
    .{
        .c_name = "accesskit_opt_auto_complete",
        .zig_type = COptAutoComplete,
        .field = "value",
        .offset = 1,
    },
    .{
        .c_name = "accesskit_opt_has_popup",
        .zig_type = COptHasPopup,
        .field = "value",
        .offset = 1,
    },
    .{
        .c_name = "accesskit_opt_list_style",
        .zig_type = COptListStyle,
        .field = "value",
        .offset = 1,
    },
    .{
        .c_name = "accesskit_opt_text_align",
        .zig_type = COptTextAlign,
        .field = "value",
        .offset = 1,
    },
    .{
        .c_name = "accesskit_opt_vertical_offset",
        .zig_type = COptVerticalOffset,
        .field = "value",
        .offset = 1,
    },
    .{ .c_name = "accesskit_opt_rect", .zig_type = COptRect, .field = "value", .offset = 8 },
    .{
        .c_name = "accesskit_opt_text_selection",
        .zig_type = COptTextSelection,
        .field = "value",
        .offset = 8,
    },
    .{
        .c_name = "accesskit_custom_actions",
        .zig_type = CCustomActions,
        .field = "values",
        .offset = 8,
    },
    .{
        .c_name = "accesskit_opt_action_data",
        .zig_type = schema.COptActionData,
        .field = "value",
        .offset = 8,
    },
    .{
        .c_name = "accesskit_action_data",
        .zig_type = schema.CActionData,
        .field = "payload",
        .offset = 8,
    },
    // Two rows where the header's printed column names a field a reader would
    // not find, and `docs/40-capi-build-map.md` section 3.2 corrects both.
    // `accesskit_text_selection` prints 16, and 16 is `focus`; the type has no
    // `value` field and its prose rule at `:6496-6498` would print `-`. The
    // offset is real and worth pinning, so the row names the field that is
    // there. `accesskit_action_request` prints 1, and offset 1 is
    // `target_tree`, a `uint8_t[16]` of alignment 1, because `action` is one
    // byte at offset 0; the payload field is `data`, measured at 32.
    .{
        .c_name = "accesskit_text_selection",
        .zig_type = TextSelection,
        .field = "focus",
        .offset = 16,
    },
    .{
        .c_name = "accesskit_action_request",
        .zig_type = schema.CActionRequest,
        .field = "data",
        .offset = 32,
    },
    .{ .c_name = "accesskit_opt_lresult", .zig_type = COptLResult, .field = "value", .offset = 8 },
};

// --- The list and handle forms the header declares ----------------------------

/// `struct accesskit_node_ids` from `accesskit-c/include/accesskit.h:1046-1057`.
///
/// Returned by eight getters. `values` borrows the array the node owns: the node
/// must stay alive and the list unmodified for as long as a caller reads it,
/// and the caller never releases it.
pub const CNodeIds = extern struct {
    /// `size_t length;` at `:1050`. An element count, not a byte count.
    length: usize,
    /// `const accesskit_node_id *values;` at `:1056`.
    values: [*c]const NodeId,
};

/// `struct accesskit_lengths` from `accesskit-c/include/accesskit.h:1204-1215`.
///
/// Returned by two getters, and borrowed on the same terms as `CNodeIds`.
pub const CLengths = extern struct {
    /// `size_t length;` at `:1208`.
    length: usize,
    /// `const uint8_t *values;` at `:1214`. UTF-8 encoded character lengths in
    /// bytes, one per character, in text order.
    values: [*c]const u8,
};

/// The handle a `struct accesskit_custom_action *` is in the port.
///
/// The header declares the type opaque at
/// `accesskit-c/include/accesskit.h:920`, so there is no layout to convert and
/// the pointer crosses unchanged. This is the one conversion in this module
/// that is a bare alias, which is why it is a `const` and not a function.
pub const CustomActionHandle = *CustomAction;

/// `struct accesskit_custom_actions` from
/// `accesskit-c/include/accesskit.h:1512-1524`.
///
/// A value returned by `accesskit_node_custom_actions` owns the array and
/// every action in it, and `accesskit_custom_actions_free` releases all of
/// them. An array passed to `accesskit_node_set_custom_actions` is only
/// borrowed, so the same struct means two different ownership rules depending
/// on which direction it travelled.
pub const CCustomActions = extern struct {
    /// `size_t length;` at `:1516`.
    length: usize,
    /// `struct accesskit_custom_action **values;` at `:1523`. The element type
    /// is the opaque handle, so a slot is nullable even though every slot a
    /// port writes is not.
    values: [*c]?*CustomAction,
};

/// `struct accesskit_opt_node_id` from `accesskit-c/include/accesskit.h:1069-1072`.
pub const COptNodeId = extern struct {
    has_value: bool,
    value: NodeId,
};

/// `struct accesskit_opt_tree_id` from `accesskit-c/include/accesskit.h:1092-1095`.
///
/// The only optional whose payload is itself an `extern struct` of alignment 1,
/// so its payload lands at offset 1 and the aggregate measures 17 bytes at
/// alignment 1. Every other optional in this module has a payload aligned to 4
/// or 8.
pub const COptTreeId = extern struct {
    has_value: bool,
    value: TreeId,
};

/// `struct accesskit_opt_double` from `accesskit-c/include/accesskit.h:1107-1110`.
pub const COptDouble = extern struct {
    has_value: bool,
    value: f64,
};

/// `struct accesskit_opt_float` from `accesskit-c/include/accesskit.h:1122-1125`.
pub const COptFloat = extern struct {
    has_value: bool,
    value: f32,
};

/// `struct accesskit_opt_index` from `accesskit-c/include/accesskit.h:1137-1143`.
pub const COptIndex = extern struct {
    has_value: bool,
    /// A count, not an index into any table the header defines.
    value: usize,
};

/// `struct accesskit_opt_color` from `accesskit-c/include/accesskit.h:1166-1169`.
pub const COptColor = extern struct {
    has_value: bool,
    value: Color,
};

/// `struct accesskit_opt_text_decoration` from
/// `accesskit-c/include/accesskit.h:1196-1199`.
pub const COptTextDecoration = extern struct {
    has_value: bool,
    value: TextDecoration,
};

/// `struct accesskit_opt_bool` from `accesskit-c/include/accesskit.h:1245-1248`.
pub const COptBool = extern struct {
    has_value: bool,
    value: bool,
};

/// `struct accesskit_opt_invalid` from
/// `accesskit-c/include/accesskit.h:1260-1263`.
pub const COptInvalid = extern struct {
    has_value: bool,
    value: Invalid,
};

/// `struct accesskit_opt_toggled` from
/// `accesskit-c/include/accesskit.h:1275-1278`.
pub const COptToggled = extern struct {
    has_value: bool,
    value: schema.Toggled,
};

/// `struct accesskit_opt_live` from `accesskit-c/include/accesskit.h:1290-1293`.
pub const COptLive = extern struct {
    has_value: bool,
    value: schema.Live,
};

/// `struct accesskit_opt_text_direction` from
/// `accesskit-c/include/accesskit.h:1305-1308`.
pub const COptTextDirection = extern struct {
    has_value: bool,
    value: schema.TextDirection,
};

/// `struct accesskit_opt_orientation` from
/// `accesskit-c/include/accesskit.h:1320-1323`.
pub const COptOrientation = extern struct {
    has_value: bool,
    value: schema.Orientation,
};

/// `struct accesskit_opt_sort_direction` from
/// `accesskit-c/include/accesskit.h:1335-1338`.
pub const COptSortDirection = extern struct {
    has_value: bool,
    value: schema.SortDirection,
};

/// `struct accesskit_opt_aria_current` from
/// `accesskit-c/include/accesskit.h:1350-1353`.
pub const COptAriaCurrent = extern struct {
    has_value: bool,
    value: schema.AriaCurrent,
};

/// `struct accesskit_opt_auto_complete` from
/// `accesskit-c/include/accesskit.h:1365-1368`.
pub const COptAutoComplete = extern struct {
    has_value: bool,
    value: schema.AutoComplete,
};

/// `struct accesskit_opt_has_popup` from
/// `accesskit-c/include/accesskit.h:1380-1383`.
pub const COptHasPopup = extern struct {
    has_value: bool,
    value: schema.HasPopup,
};

/// `struct accesskit_opt_list_style` from
/// `accesskit-c/include/accesskit.h:1395-1398`.
pub const COptListStyle = extern struct {
    has_value: bool,
    value: schema.ListStyle,
};

/// `struct accesskit_opt_text_align` from
/// `accesskit-c/include/accesskit.h:1410-1413`.
pub const COptTextAlign = extern struct {
    has_value: bool,
    value: schema.TextAlign,
};

/// `struct accesskit_opt_vertical_offset` from
/// `accesskit-c/include/accesskit.h:1425-1428`.
pub const COptVerticalOffset = extern struct {
    has_value: bool,
    value: schema.VerticalOffset,
};

/// `struct accesskit_opt_rect` from `accesskit-c/include/accesskit.h:1468-1471`.
pub const COptRect = extern struct {
    has_value: bool,
    value: Rect,
};

/// `struct accesskit_opt_text_selection` from
/// `accesskit-c/include/accesskit.h:1504-1507`.
pub const COptTextSelection = extern struct {
    has_value: bool,
    value: TextSelection,
};

/// `struct accesskit_opt_lresult` from
/// `accesskit-c/include/accesskit.h:1573-1580`, the one optional the header
/// declares under `#if defined(_WIN32)`.
///
/// **`LRESULT` is a pointer-sized integer, and the header's published numbers
/// are the 64-bit ones.** `LRESULT` is `LONG_PTR`, so `accesskit_opt_lresult`
/// measures 16 bytes at alignment 8 with the payload at offset 8 on a 64-bit
/// target, which is what `docs/40-capi-build-map.md` section 3.2 recorded, and
/// 8 bytes at alignment 4 with the payload at offset 4 on a 32-bit one. The
/// header says so at `:6551`: the type is absent from its printed table
/// because it exists only under `_WIN32`, and a target that measures it
/// differently needs the conformance test rather than that table.
///
/// So the port declares `value` as `isize` and pins the layout against
/// `@sizeOf(isize)` rather than against a literal. That is the only honest
/// pin available off a Windows host: it is 16/8/8 wherever the header's
/// measured 16/8/8 was measured, and it follows `LRESULT` wherever else. The
/// declaration is unconditional so the conversion is reachable and testable on
/// the host that exists; nothing exports an `accesskit_windows_*` symbol unless
/// `src/adapters/windows/` exists, so an unconditional Zig type costs no
/// symbol.
pub const COptLResult = extern struct {
    has_value: bool,
    value: isize,
};

// --- The optional conversions --------------------------------------------------

/// The C form of `value`, absent when it is `null`.
///
/// One function rather than twenty-three, so the absent case is written once.
/// The header's rule for the absent case is at
/// `accesskit-c/include/accesskit.h:1062-1067`: write a zero into the payload
/// so a reader who ignores the flag reads a defined zero rather than
/// uninitialised storage. It calls that a diagnostic aid and not a contract,
/// and it is written the same way for every optional.
fn wrapOptional(comptime C: type, comptime Payload: type, value: ?Payload) C {
    if (value) |held| return .{ .has_value = true, .value = held };
    return .{ .has_value = false, .value = std.mem.zeroes(Payload) };
}

/// `accesskit_opt_node_id` for `value`. `accesskit_node_active_descendant`
/// and six siblings return it.
pub fn opt_node_id_to_c(value: ?NodeId) COptNodeId {
    return wrapOptional(COptNodeId, NodeId, value);
}

/// `accesskit_opt_tree_id` for `value`. `accesskit_node_tree_id` returns it.
pub fn opt_tree_id_to_c(value: ?TreeId) COptTreeId {
    return wrapOptional(COptTreeId, TreeId, value);
}

/// `accesskit_opt_double` for `value`. Eleven getters return it.
pub fn opt_double_to_c(value: ?f64) COptDouble {
    return wrapOptional(COptDouble, f64, value);
}

/// `accesskit_opt_float` for `value`. `accesskit_node_font_size` and
/// `accesskit_node_font_weight` return it.
pub fn opt_float_to_c(value: ?f32) COptFloat {
    return wrapOptional(COptFloat, f32, value);
}

/// `accesskit_opt_index` for `value`. Nine getters return it.
pub fn opt_index_to_c(value: ?usize) COptIndex {
    return wrapOptional(COptIndex, usize, value);
}

/// `accesskit_opt_color` for `value`. `accesskit_node_color_value`,
/// `accesskit_node_background_color` and `accesskit_node_foreground_color`
/// return it.
pub fn opt_color_to_c(value: ?Color) COptColor {
    return wrapOptional(COptColor, Color, value);
}

/// `accesskit_opt_text_decoration` for `value`. The overline, strikethrough and
/// underline getters return it.
pub fn opt_text_decoration_to_c(value: ?TextDecoration) COptTextDecoration {
    return wrapOptional(COptTextDecoration, TextDecoration, value);
}

/// `accesskit_opt_bool` for `value`. `accesskit_node_is_expanded` and
/// `accesskit_node_is_selected` return it.
pub fn opt_bool_to_c(value: ?bool) COptBool {
    return wrapOptional(COptBool, bool, value);
}

/// `accesskit_opt_invalid` for `value`. `accesskit_node_invalid` returns it.
pub fn opt_invalid_to_c(value: ?Invalid) COptInvalid {
    return wrapOptional(COptInvalid, Invalid, value);
}

/// `accesskit_opt_toggled` for `value`. `accesskit_node_toggled` returns it.
pub fn opt_toggled_to_c(value: ?schema.Toggled) COptToggled {
    return wrapOptional(COptToggled, schema.Toggled, value);
}

/// `accesskit_opt_live` for `value`. `accesskit_node_live` returns it.
pub fn opt_live_to_c(value: ?schema.Live) COptLive {
    return wrapOptional(COptLive, schema.Live, value);
}

/// `accesskit_opt_text_direction` for `value`. `accesskit_node_text_direction`
/// returns it.
pub fn opt_text_direction_to_c(value: ?schema.TextDirection) COptTextDirection {
    return wrapOptional(COptTextDirection, schema.TextDirection, value);
}

/// `accesskit_opt_orientation` for `value`. `accesskit_node_orientation`
/// returns it.
pub fn opt_orientation_to_c(value: ?schema.Orientation) COptOrientation {
    return wrapOptional(COptOrientation, schema.Orientation, value);
}

/// `accesskit_opt_sort_direction` for `value`. `accesskit_node_sort_direction`
/// returns it.
pub fn opt_sort_direction_to_c(value: ?schema.SortDirection) COptSortDirection {
    return wrapOptional(COptSortDirection, schema.SortDirection, value);
}

/// `accesskit_opt_aria_current` for `value`. `accesskit_node_aria_current`
/// returns it.
pub fn opt_aria_current_to_c(value: ?schema.AriaCurrent) COptAriaCurrent {
    return wrapOptional(COptAriaCurrent, schema.AriaCurrent, value);
}

/// `accesskit_opt_auto_complete` for `value`. `accesskit_node_auto_complete`
/// returns it.
pub fn opt_auto_complete_to_c(value: ?schema.AutoComplete) COptAutoComplete {
    return wrapOptional(COptAutoComplete, schema.AutoComplete, value);
}

/// `accesskit_opt_has_popup` for `value`. `accesskit_node_has_popup` returns it.
pub fn opt_has_popup_to_c(value: ?schema.HasPopup) COptHasPopup {
    return wrapOptional(COptHasPopup, schema.HasPopup, value);
}

/// `accesskit_opt_list_style` for `value`. `accesskit_node_list_style` returns
/// it.
pub fn opt_list_style_to_c(value: ?schema.ListStyle) COptListStyle {
    return wrapOptional(COptListStyle, schema.ListStyle, value);
}

/// `accesskit_opt_text_align` for `value`. `accesskit_node_text_align` returns
/// it.
pub fn opt_text_align_to_c(value: ?schema.TextAlign) COptTextAlign {
    return wrapOptional(COptTextAlign, schema.TextAlign, value);
}

/// `accesskit_opt_vertical_offset` for `value`. `accesskit_node_vertical_offset`
/// returns it.
pub fn opt_vertical_offset_to_c(value: ?schema.VerticalOffset) COptVerticalOffset {
    return wrapOptional(COptVerticalOffset, schema.VerticalOffset, value);
}

/// `accesskit_opt_rect` for `value`. `accesskit_node_bounds` returns it.
pub fn opt_rect_to_c(value: ?Rect) COptRect {
    return wrapOptional(COptRect, Rect, value);
}

/// `accesskit_opt_text_selection` for `value`. `accesskit_node_text_selection`
/// returns it.
///
/// The parameter is a borrow because `src/schema/props/option.zig:162`
/// returns `?*const TextSelection`: upstream reads this property through the
/// `option_ref_type_getters` family at `accesskit/src/lib.rs:1977`, which
/// returns references, and the port keeps that split. The result copies the
/// selection out, so nothing the caller does next to the node can change it.
pub fn opt_text_selection_to_c(value: ?*const TextSelection) COptTextSelection {
    return if (value) |held|
        .{ .has_value = true, .value = held.* }
    else
        .{ .has_value = false, .value = std.mem.zeroes(TextSelection) };
}

/// `accesskit_opt_coords` for `value`. `accesskit_node_character_positions` and
/// `accesskit_node_character_widths` return it.
///
/// `values` borrows `value`; the node must stay alive and the list unmodified
/// while a caller reads it. An absent value gets `length` 0 and a non-null
/// `values` pointing at `no_coords`, which reads as an empty list rather than
/// as a dangling pointer.
pub fn opt_coords_to_c(value: ?[]const f32) COptCoords {
    const held = value orelse return .{
        .has_value = false,
        .length = 0,
        .values = &no_coords,
    };
    return .{ .has_value = true, .length = held.len, .values = held.ptr };
}

/// `accesskit_opt_lresult` for `value`. `accesskit_windows_adapter_handle_wm_getobject`
/// returns it, and that is the only C declaration that reads the field.
pub fn opt_lresult_to_c(value: ?isize) COptLResult {
    return wrapOptional(COptLResult, isize, value);
}

// --- The list conversions -----------------------------------------------------

/// `accesskit_node_ids` for `values`. Eight getters return it.
///
/// The result borrows `values` and owns nothing. An empty slice still yields a
/// non-null `values`, because a Zig slice's pointer is never null, and the
/// header promises exactly that for an unset property at
/// `accesskit-c/include/accesskit.h:2304`: "An unset property gives
/// `length == 0` with a non-null `values`."
pub fn node_ids_to_c(values: []const NodeId) CNodeIds {
    return .{ .length = values.len, .values = values.ptr };
}

/// `accesskit_lengths` for `values`. `accesskit_node_character_lengths` and
/// `accesskit_node_word_starts` return it.
///
/// Borrowed on the same terms as `node_ids_to_c`. The payload is bytes, not
/// indices: `values` is `const uint8_t *` at
/// `accesskit-c/include/accesskit.h:1214`.
pub fn lengths_to_c(values: []const u8) CLengths {
    return .{ .length = values.len, .values = values.ptr };
}

// --- The string pair and the strings a getter returns -------------------------

/// The failures `dup_c_string` reports.
pub const DupCStringError = error{
    /// `gpa` could not supply `text.len + 1` bytes. Nothing was allocated and
    /// the caller owns nothing, so an export that catches this returns `null`
    /// and sets the `accesskit_error` tag.
    OutOfMemory,
};

/// A NUL-terminated copy of `text` in memory `gpa` owns.
///
/// `gpa` releases the result with `string_free`, or with `gpa.free` through
/// `std.mem.span`. The result is never null: an empty `text` allocates one byte
/// and returns a pointer to it, because the header distinguishes only between
/// a `char *` and a null, and a null means "unset" or "out of memory" to the
/// caller. `gpa` is first because this is an allocating free function
/// (`AGENTS.md:99`).
///
/// **A `text` holding a NUL is cut at the first one.** A `char *` ends at its
/// first 0 byte, so no spelling carries the tail, and the header states the
/// rule for the whole family rather than for one call.
/// `accesskit_custom_action_set_description_with_length` at
/// `accesskit-c/include/accesskit.h:5050-5053` puts it as: "A byte string is
/// stored up to the first NUL byte, because a value holding one cannot come
/// back out of a `char *` getter without losing its tail." The same sentence
/// is on `accesskit_node_set_description_with_length` at `:2890-2892` and on
/// every other member of the twenty-five.
///
/// So this is the same cut the twenty-five `_with_length` setters make, and
/// making it here is what lets a value written through `c_bytes_to_slice` come
/// back out of a getter unchanged. It is also what makes `string_free` sound:
/// `gpa.free` needs the length, and `std.mem.span` can only find it from the
/// terminator, so a copy that kept a byte past a NUL would be freed at the
/// wrong length. Copying the bytes whole and trusting the caller to read them
/// back is not an option `char *` offers.
pub fn dup_c_string(gpa: std.mem.Allocator, text: []const u8) DupCStringError![*:0]u8 {
    const end = std.mem.indexOfScalar(u8, text, 0) orelse text.len;
    const buffer = try gpa.allocSentinel(u8, end, 0);
    @memcpy(buffer[0..end], text[0..end]);
    return buffer.ptr;
}

/// Releases a string `dup_c_string` produced.
///
/// This is `accesskit_string_free`, and it is the only legal release for a
/// `char *` this library returned: the header says so at
/// `accesskit-c/include/accesskit.h:2819-2822`, and it says a second call is a
/// double free and a `null` terminates the process, so neither is handled here.
/// `gpa` must be the allocator `dup_c_string` was given. `value` is unusable
/// afterwards.
pub fn string_free(gpa: std.mem.Allocator, value: [*c]u8) void {
    gpa.free(std.mem.span(value));
}

/// The bytes `value` names, for a `(const char *)` argument.
///
/// The twenty-five setters that take a bare `const char *` all read the
/// string up to its NUL, and none of them says a null is a legal argument, so
/// the parameter is not optional: a C caller that passes null has passed
/// something the header does not describe, and the port does not invent an
/// answer for it.
pub fn c_string_to_slice(value: [*:0]const u8) []const u8 {
    return std.mem.span(value);
}

/// The bytes a `(const char *, size_t)` argument contributes, for the
/// twenty-five `*_with_length` setters.
///
/// The pair reaches further than the bare form, and all twenty-five
/// declarations then state the same rule about what happens to the bytes past
/// the first NUL. `accesskit_node_set_description_with_length` at
/// `accesskit-c/include/accesskit.h:2887-2892` puts it as: "A byte string is
/// stored up to the first NUL byte, because a value holding one cannot come
/// back out of a `char *` getter without losing its tail."
/// `accesskit_custom_action_set_description_with_length` at `:5048-5053` says
/// the same, and so does every other member of the family. That rule belongs to
/// the shape of the pair rather than to any one setter, so it lives here, in
/// the one function all twenty-five call. Writing it twenty-five times is how
/// the twenty-fifth would differ.
///
/// So this returns `value[0..length]` shortened to the first NUL byte in it,
/// which is at most `length` bytes. It never reads past `length`, so a buffer
/// that is not NUL-terminated is fine; a `length` past the end of the caller's
/// buffer is the caller's defect and is not checked here.
///
/// **It is not a UTF-8 decode.** Upstream reads this pair with
/// `String::from_utf8_lossy` (`accesskit-c/src/lib.rs:216-224`), which replaces
/// invalid sequences with U+FFFD. This header does not describe that: it says
/// "Copies `length` bytes", the only three places it mentions UTF-8 are
/// `accesskit_lengths.values` at `:1210`, `accesskit_opt_coords` at `:1219` and
/// `accesskit_text_position.character_index` at `:1480`, and none of them is a
/// stored string. Every store this header names is a byte string. So the port
/// copies bytes, and a property that must be valid UTF-8 is the caller's
/// business.
pub fn c_bytes_to_slice(value: [*c]const u8, length: usize) []const u8 {
    const given = value[0..length];
    const end = std.mem.indexOfScalar(u8, given, 0) orelse given.len;
    return given[0..end];
}

// --- The custom-action deep copy ----------------------------------------------

/// The failures `custom_actions_to_c` reports.
pub const CustomActionsToCError = error{
    /// `gpa` could not supply the outer struct, the pointer array, or one of
    /// the action copies. On that path nothing survives and the caller owns
    /// nothing, which the `errdefer` chain below is what establishes.
    OutOfMemory,
};

/// A deep copy of `actions` in the form `accesskit_node_custom_actions` returns.
///
/// This is upstream's `accesskit-c/src/common.rs:783-798`, and the header states
/// the ownership at `accesskit-c/include/accesskit.h:5071-5079`: the result
/// owns the outer struct, the array and every action in it, and
/// `accesskit_custom_actions_free` releases all of them. Nothing in it borrows
/// from the node, so the node may be released first.
///
/// An empty `actions` is a valid result: the header says "An empty list has
/// `length == 0`, never a `null` result", so this never returns null except on
/// `error.OutOfMemory`. `gpa` is first (`AGENTS.md:99`).
pub fn custom_actions_to_c(
    gpa: std.mem.Allocator,
    actions: []const CustomAction,
) CustomActionsToCError!*CCustomActions {
    const outer = try gpa.create(CCustomActions);
    errdefer gpa.destroy(outer);

    // A zero-length allocation still hands back a non-null pointer, which is
    // what keeps `values` non-null for an empty list.
    const owned = try gpa.alloc(?*CustomAction, actions.len);
    errdefer gpa.free(owned);

    // An allocation that fails partway leaves the slots above the failure
    // uninitialised, so the release loop counts what it wrote rather than what
    // it allocated. That is the difference between a clean failure and a read
    // of undefined storage.
    var written: usize = 0;
    errdefer {
        var index: usize = 0;
        while (index < written) : (index += 1) {
            const held = owned[index].?;
            held.deinit(gpa);
            gpa.destroy(held);
        }
    }

    while (written < actions.len) : (written += 1) {
        const source = actions[written];
        const fresh = try gpa.create(CustomAction);
        fresh.* = CustomAction.init(gpa, source.id, source.description.items) catch |err| {
            gpa.destroy(fresh);
            return err;
        };
        owned[written] = fresh;
    }

    outer.* = .{ .length = owned.len, .values = owned.ptr };
    return outer;
}

/// Releases a `CCustomActions` and every action in it, exactly once.
///
/// This is `accesskit_custom_actions_free`
/// (`accesskit-c/include/accesskit.h:5068`). `gpa` must be the allocator
/// `custom_actions_to_c` was given. Every action goes with the list, so a
/// caller must not release one itself afterwards. `value` is unusable after
/// this call and a second call is a double free.
pub fn custom_actions_deinit(gpa: std.mem.Allocator, value: *CCustomActions) void {
    const owned = value.values[0..value.length];
    for (owned) |slot| {
        const held = slot.?;
        held.deinit(gpa);
        gpa.destroy(held);
    }
    gpa.free(owned);
    gpa.destroy(value);
}

// --- The four forms `src/schema/update.zig` already owns -----------------------
// `docs/40-capi-build-map.md` section 8 step 2 says four of the conversion
// recipes already exist and must be re-exported rather than written twice.
// `accesskit_action_data` is the only payload-carrying enum the header has and
// the only anonymous union, so it is the one form that crosses in both
// directions: the port builds it for a C action handler and reads it back from
// one.

/// `struct accesskit_action_data`. `accesskit-c/include/accesskit.h:1621-1649`.
pub const CActionData = schema.CActionData;

/// `struct accesskit_opt_action_data`.
/// `accesskit-c/include/accesskit.h:1661-1669`.
pub const COptActionData = schema.COptActionData;

/// `struct accesskit_action_request`.
/// `accesskit-c/include/accesskit.h:1675-1693`.
pub const CActionRequest = schema.CActionRequest;

/// `update.zig`'s `ActionData` into the C form, allocating the `char *` the
/// `value` variant carries.
pub const actionDataToC = schema.actionDataToC;

/// `update.zig`'s `ActionData` out of the C form, copying the `char *` the
/// `value` variant carries. `value` keeps its own buffer.
pub const actionDataFromC = schema.actionDataFromC;

/// Releases the `char *` a `CActionData` of the `value` tag owns.
pub const cActionDataDeinit = schema.cActionDataDeinit;

/// Releases the `char *` a `CActionRequest`'s payload owns, and nothing else.
/// This is `accesskit_action_request_free`.
pub const cActionRequestDeinit = schema.cActionRequestDeinit;

// --- The layout pins ----------------------------------------------------------

comptime {
    // The sizes and alignments the header's own table prints, at
    // `accesskit-c/include/accesskit.h:6509-6549`, and the payload offsets it
    // prints beside them. `docs/40-capi-build-map.md` section 3.2 measured the
    // same 37 sizes and 28 offsets independently and agrees on every one. A
    // field added to, removed from or reordered in any type below is a compile
    // failure here rather than a C caller reading a different number.
    //
    // The bound is each table's length, asserted in the tests named below.
    for (laid_out_structs) |row| {
        std.debug.assert(@sizeOf(row.zig_type) == row.size);
        std.debug.assert(@alignOf(row.zig_type) == row.alignment);
    }
    for (payload_rows) |row| {
        std.debug.assert(@offsetOf(row.zig_type, row.field) == row.offset);
    }

    // `accesskit_tree_id` is the one aggregate whose payload field has an
    // alignment below its own, and that is what makes `accesskit_opt_tree_id`
    // measure 17 rather than 24. Both facts are needed by hand, because no
    // general rule in the table above states them.
    std.debug.assert(@alignOf(TreeId) == 1);
    std.debug.assert(@offsetOf(COptTreeId, "value") == @sizeOf(bool));

    // `accesskit_opt_lresult` follows `LRESULT`, which is pointer-sized, so the
    // 16/8/8 the map recorded is the 64-bit measurement and the pin has to be
    // written against `isize` rather than against the literal. See the type's
    // doc comment.
    std.debug.assert(@alignOf(COptLResult) == @alignOf(isize));
    std.debug.assert(@sizeOf(COptLResult) == std.mem.alignForward(
        usize,
        @sizeOf(bool) + @sizeOf(isize),
        @alignOf(isize),
    ));

    // Every optional is the flag and the payload, so the flag is always first.
    // This is the declaration order, not a measurement, and the measurement
    // above is what agrees with it.
    for (optional_rows) |row| {
        std.debug.assert(@offsetOf(row.c_type, "has_value") == 0);
        std.debug.assert(@sizeOf(bool) == 1);
        std.debug.assert(@offsetOf(row.c_type, "value") == row.payload_offset);
        // The payload must fit inside the aggregate and respect its own
        // alignment, which is what `docs/31-c-abi-design.md` section 4.0
        // states as the layout rule the port must satisfy.
        std.debug.assert(row.payload_offset + @sizeOf(row.payload) <= @sizeOf(row.c_type));
        std.debug.assert(row.payload_offset % @alignOf(row.payload) == 0);
    }

    // The list-shaped optional has three fields rather than two, so it is
    // pinned by hand.
    std.debug.assert(@offsetOf(COptCoords, "has_value") == 0);
    std.debug.assert(@offsetOf(COptCoords, "length") == 8);
    std.debug.assert(@offsetOf(COptCoords, "values") == 16);

    // Both lists are a count then a pointer, in that order.
    std.debug.assert(@offsetOf(CNodeIds, "length") == 0);
    std.debug.assert(@offsetOf(CNodeIds, "values") == 8);
    std.debug.assert(@offsetOf(CLengths, "length") == 0);
    std.debug.assert(@offsetOf(CLengths, "values") == 8);
    std.debug.assert(@offsetOf(CCustomActions, "length") == 0);
    std.debug.assert(@offsetOf(CCustomActions, "values") == 8);

    // The three table lengths, each the count of a thing the header states
    // rather than a number chosen here.
    //
    // 40: the header declares 40 `typedef struct NAME { … } NAME;` bodies, of
    // which `accesskit_opt_lresult` is `_WIN32`-only, so 39 exist on this host
    // and the table carries all 40. 37 of them are the header's printed
    // conformance table at `:6509-6549`; the other three are the action-data
    // forms it names after that table at `:6547-6549` and the one it says it
    // omits at `:6551`.
    std.debug.assert(laid_out_structs.len == 40);
    //
    // 31: 40 rows less the nine the header's payload column prints as `-`,
    // which are `accesskit_tree_id`, `accesskit_color`,
    // `accesskit_text_decoration`, `accesskit_affine`, `accesskit_rect`,
    // `accesskit_text_position`, `accesskit_point`, `accesskit_vec2` and
    // `accesskit_size`. Every other row has a field whose offset is a number
    // the header or the map measured.
    std.debug.assert(payload_rows.len == 31);
    //
    // 23: the header declares 24 `accesskit_opt_*` structs, 22 of them a flag
    // and a payload, one `accesskit_opt_coords` which is a flag, a count and a
    // pointer, and one `accesskit_opt_lresult` behind `_WIN32`. This table
    // holds the 22 and the `_WIN32`-only one; `COptCoords` is declared beside
    // it because its payload is `values` and not `value`.
    std.debug.assert(optional_rows.len == 23);
}

// --- Test helpers -------------------------------------------------------------

/// The `@sizeOf(T)` bytes at `value`, in memory order.
///
/// This is what a C reader sees and what a C caller writes, so a test that
/// fills a `T` through it is exercising the header's offsets rather than the
/// port's field names.
fn cBytesOf(comptime T: type, value: *T) []u8 {
    return @as([*]u8, @ptrCast(value))[0..@sizeOf(T)];
}

/// Writes `value` into `target` at `offset`, the way a C caller fills a field.
fn writeBits(comptime T: type, target: []u8, offset: usize, value: T) void {
    var source: T = value;
    const bits = std.mem.asBytes(&source);
    @memcpy(target[offset..][0..bits.len], bits);
}

// --- Tests --------------------------------------------------------------------

test "every laid-out aggregate measures what the header measures" {
    // The header's conformance table, `accesskit-c/include/accesskit.h:6509-6549`.
    // The `comptime` block above makes a wrong number a build failure; this
    // repeats the same 40 rows at run time so a failing run names the type in
    // the message rather than in a comptime trace.
    inline for (laid_out_structs, 0..) |row, index| {
        _ = index;
        testing.expectEqual(row.size, @sizeOf(row.zig_type)) catch |err| {
            std.debug.print("{s}: {s}\n", .{ row.c_name, @errorName(err) });
            return err;
        };
        testing.expectEqual(row.alignment, @alignOf(row.zig_type)) catch |err| {
            std.debug.print("{s}: {s}\n", .{ row.c_name, @errorName(err) });
            return err;
        };
    }
}

test "every payload offset is the offset the header publishes" {
    inline for (payload_rows) |row| {
        const found = @offsetOf(row.zig_type, row.field);
        testing.expectEqual(row.offset, found) catch |err| {
            std.debug.print("{s}.{s}: {s}\n", .{ row.c_name, row.field, @errorName(err) });
            return err;
        };
    }
}

test "the optional table covers every optional the header declares" {
    // The header declares 25 `accesskit_opt_*` structs. Twenty-two are a flag
    // and a payload and are rows here; the twenty-third here is
    // `accesskit_opt_lresult`, which is declared only under `_WIN32`; and the
    // other two, `accesskit_opt_coords` and `accesskit_opt_action_data`, are
    // declared outside this table because their payload is not a `value`.
    const header_optionals = 25;
    try testing.expectEqual(header_optionals - 2, optional_rows.len);

    // So no row here may be one the header holds outside the table.
    inline for (optional_rows) |row| {
        try testing.expect(!std.mem.eql(u8, row.c_name, "accesskit_opt_coords"));
        try testing.expect(!std.mem.eql(u8, row.c_name, "accesskit_opt_action_data"));
    }
}

test "the payload table covers every aggregate that names a payload" {
    // Nine of the 40 rows are the ones the header's own payload column prints
    // as `-`, and every other row has a measured offset.
    const without_payload = 9;
    try testing.expectEqual(laid_out_structs.len - without_payload, payload_rows.len);

    // No aggregate is in the payload table twice, which is what would happen if
    // a type were added to both this table and `laid_out_structs` twice.
    inline for (payload_rows, 0..) |row, index| {
        inline for (payload_rows, 0..) |other, other_index| {
            if (index == other_index) continue;
            try testing.expect(!std.mem.eql(u8, row.c_name, other.c_name));
        }
    }
}

test "the optional payloads fall at the three offsets the header describes" {
    // The whole shape in one assertion: an optional's payload lands at 1 when
    // it is a byte or a `uint8_t` alias, at 4 when it is an `f32`, and at 8
    // when it is aligned to a pointer. Nothing else occurs, so a row that
    // drifted to a fourth offset would fail here.
    const header_offsets = [_]usize{ 1, 4, 8 };
    inline for (optional_rows) |row| {
        var known = false;
        inline for (header_offsets) |offset| {
            if (row.payload_offset == offset) known = true;
        }
        try testing.expect(known);

        // And the offset follows the payload's own alignment, which is the rule
        // `docs/31-c-abi-design.md` section 4.0 states the port must satisfy.
        try testing.expectEqual(@as(usize, 0), row.payload_offset % @alignOf(row.payload));
    }
}

test "the list-shaped optional is the one optional with no value field" {
    // `accesskit_opt_coords` has three fields, and that is the only reason it is
    // not a row in `optional_rows`: the header's payload column at
    // `accesskit-c/include/accesskit.h:6523` names `values` for it, and every
    // other optional's payload is `value`. So the flag is at 0, the count
    // fills the hole the flag left, and the payload lands at 16.
    try testing.expectEqual(@as(usize, 0), @offsetOf(COptCoords, "has_value"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(COptCoords, "length"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(COptCoords, "values"));
    try testing.expectEqual(@as(usize, 24), @sizeOf(COptCoords));

    // Every optional this table does hold has exactly two fields.
    inline for (optional_rows) |row| {
        try testing.expectEqual(@as(usize, 2), @typeInfo(row.c_type).@"struct".fields.len);
    }
}

test "accesskit_node_ids matches the header in both directions" {
    const ids = [_]NodeId{ .{ .value = 1 }, .{ .value = 2 }, .{ .value = 3 } };

    // Zig to header: the count and the pointer are where a C reader looks.
    const out = node_ids_to_c(&ids);
    try testing.expectEqual(@as(usize, 3), out.length);
    try testing.expectEqual(@as(usize, 8), @offsetOf(CNodeIds, "values"));
    try testing.expectEqual(@as(u64, 1), out.values[0].value);
    try testing.expectEqual(@as(u64, 3), out.values[2].value);

    // Header to Zig: bytes written the way a C caller writes them, read back
    // through the port's own field names.
    var written: CNodeIds = undefined;
    const bytes = cBytesOf(CNodeIds, &written);
    writeBits(usize, bytes, 0, 2);
    writeBits(usize, bytes, 8, @intFromPtr(&ids));
    try testing.expectEqual(@as(usize, 2), written.length);
    try testing.expectEqual(@as(u64, 2), written.values[1].value);
}

test "an unset node-id list is zero long with a non-null values" {
    // `accesskit-c/include/accesskit.h:2304` promises exactly this.
    const empty = node_ids_to_c(&[_]NodeId{});
    try testing.expectEqual(@as(usize, 0), empty.length);
    try testing.expect(@intFromPtr(empty.values) != 0);
}

test "accesskit_opt_node_id matches the header in both directions" {
    const present = opt_node_id_to_c(.{ .value = 7 });
    try testing.expect(present.has_value);
    try testing.expectEqual(@as(u64, 7), present.value.value);
    try testing.expectEqual(@as(usize, 0), @offsetOf(COptNodeId, "has_value"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(COptNodeId, "value"));

    var written: COptNodeId = undefined;
    const bytes = cBytesOf(COptNodeId, &written);
    writeBits(bool, bytes, 0, true);
    writeBits(u64, bytes, 8, 0x0123_4567_89ab_cdef);
    try testing.expect(written.has_value);
    try testing.expectEqual(@as(u64, 0x0123_4567_89ab_cdef), written.value.value);

    const absent = opt_node_id_to_c(null);
    try testing.expect(!absent.has_value);
    try testing.expectEqual(@as(u64, 0), absent.value.value);
}

test "accesskit_opt_tree_id matches the header in both directions" {
    // The one optional whose payload has an alignment below its own: 17 bytes
    // at alignment 1, payload at offset 1.
    const id = schema.treeIdFromBytes(.{ 1, 2, 3, 4 } ** 4);
    const present = opt_tree_id_to_c(id);
    try testing.expect(present.has_value);
    try testing.expectEqualSlices(u8, &id.bytes, &present.value.bytes);
    try testing.expectEqual(@as(usize, 1), @offsetOf(COptTreeId, "value"));

    var written: COptTreeId = undefined;
    const bytes = cBytesOf(COptTreeId, &written);
    writeBits(bool, bytes, 0, true);
    writeBits(u8, bytes, 1, 0xab);
    writeBits(u8, bytes, 16, 0xcd);
    try testing.expect(written.has_value);
    try testing.expectEqual(@as(u8, 0xab), written.value.bytes[0]);
    try testing.expectEqual(@as(u8, 0xcd), written.value.bytes[15]);

    const absent = opt_tree_id_to_c(null);
    try testing.expect(!absent.has_value);
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 16, &absent.value.bytes);
}

test "accesskit_opt_double matches the header in both directions" {
    const present = opt_double_to_c(-0.5);
    try testing.expect(present.has_value);
    try testing.expectEqual(@as(f64, -0.5), present.value);
    try testing.expectEqual(@as(usize, 8), @offsetOf(COptDouble, "value"));

    var written: COptDouble = undefined;
    const bytes = cBytesOf(COptDouble, &written);
    writeBits(bool, bytes, 0, true);
    writeBits(f64, bytes, 8, -0.5);
    try testing.expect(written.has_value);
    try testing.expectEqual(@as(f64, -0.5), written.value);

    const absent = opt_double_to_c(null);
    try testing.expect(!absent.has_value);
    try testing.expectEqual(@as(f64, 0.0), absent.value);
}

test "accesskit_opt_float matches the header in both directions" {
    // 8 bytes at alignment 4 with the payload at offset 4: the one optional
    // whose payload is neither a pointer nor a byte.
    const present = opt_float_to_c(1.5);
    try testing.expect(present.has_value);
    try testing.expectEqual(@as(f32, 1.5), present.value);
    try testing.expectEqual(@as(usize, 4), @offsetOf(COptFloat, "value"));

    var written: COptFloat = undefined;
    const bytes = cBytesOf(COptFloat, &written);
    writeBits(bool, bytes, 0, true);
    writeBits(f32, bytes, 4, 1.5);
    try testing.expect(written.has_value);
    try testing.expectEqual(@as(f32, 1.5), written.value);

    const absent = opt_float_to_c(null);
    try testing.expect(!absent.has_value);
    try testing.expectEqual(@as(f32, 0.0), absent.value);
}

test "accesskit_opt_index matches the header in both directions" {
    const present = opt_index_to_c(4096);
    try testing.expect(present.has_value);
    try testing.expectEqual(@as(usize, 4096), present.value);
    try testing.expectEqual(@as(usize, 8), @offsetOf(COptIndex, "value"));

    var written: COptIndex = undefined;
    const bytes = cBytesOf(COptIndex, &written);
    writeBits(bool, bytes, 0, true);
    writeBits(usize, bytes, 8, 4096);
    try testing.expect(written.has_value);
    try testing.expectEqual(@as(usize, 4096), written.value);

    const absent = opt_index_to_c(null);
    try testing.expect(!absent.has_value);
    try testing.expectEqual(@as(usize, 0), absent.value);
}

test "accesskit_opt_bool matches the header in both directions" {
    const present = opt_bool_to_c(false);
    try testing.expect(present.has_value);
    try testing.expect(!present.value);
    try testing.expectEqual(@as(usize, 1), @offsetOf(COptBool, "value"));

    var written: COptBool = undefined;
    const bytes = cBytesOf(COptBool, &written);
    writeBits(bool, bytes, 0, true);
    writeBits(bool, bytes, 1, true);
    try testing.expect(written.has_value);
    try testing.expect(written.value);

    // An absent optional and a present `false` are two different answers, and
    // the header's two fields are what keep them apart.
    const absent = opt_bool_to_c(null);
    try testing.expect(!absent.has_value);
    try testing.expect(!absent.value);
    try testing.expect(present.has_value);
}

test "accesskit_opt_color matches the header in both directions" {
    const held: Color = .{ .red = 1, .green = 2, .blue = 3, .alpha = 4 };
    const present = opt_color_to_c(held);
    try testing.expect(present.has_value);
    try testing.expect(present.value.eql(held));
    try testing.expectEqual(@as(usize, 1), @offsetOf(COptColor, "value"));

    var written: COptColor = undefined;
    const bytes = cBytesOf(COptColor, &written);
    writeBits(bool, bytes, 0, true);
    writeBits(u8, bytes, 1, 0x11);
    writeBits(u8, bytes, 4, 0x44);
    try testing.expect(written.has_value);
    try testing.expectEqual(@as(u8, 0x11), written.value.red);
    try testing.expectEqual(@as(u8, 0x44), written.value.alpha);

    const absent = opt_color_to_c(null);
    try testing.expect(!absent.has_value);
    try testing.expectEqual(@as(u8, 0), absent.value.alpha);
}

test "accesskit_opt_text_decoration matches the header in both directions" {
    const held: TextDecoration = .{
        .style = .dotted,
        .color = .{ .red = 9, .green = 8, .blue = 7, .alpha = 6 },
    };
    const present = opt_text_decoration_to_c(held);
    try testing.expect(present.has_value);
    try testing.expect(present.value.eql(held));
    try testing.expectEqual(@as(usize, 1), @offsetOf(COptTextDecoration, "value"));

    var written: COptTextDecoration = undefined;
    const bytes = cBytesOf(COptTextDecoration, &written);
    writeBits(bool, bytes, 0, true);
    writeBits(u8, bytes, 1, @intFromEnum(schema.TextDecorationStyle.dotted));
    writeBits(u8, bytes, 5, 0x5a);
    try testing.expect(written.has_value);
    try testing.expectEqual(schema.TextDecorationStyle.dotted, written.value.style);
    try testing.expectEqual(@as(u8, 0x5a), written.value.color.alpha);

    const absent = opt_text_decoration_to_c(null);
    try testing.expect(!absent.has_value);
    try testing.expectEqual(@as(u8, 0), absent.value.color.alpha);
}

test "accesskit_lengths matches the header in both directions" {
    const lengths = [_]u8{ 1, 2, 1, 1 };

    const out = lengths_to_c(&lengths);
    try testing.expectEqual(@as(usize, 4), out.length);
    try testing.expectEqual(@as(usize, 8), @offsetOf(CLengths, "values"));
    try testing.expectEqual(@as(u8, 2), out.values[1]);

    var written: CLengths = undefined;
    const bytes = cBytesOf(CLengths, &written);
    writeBits(usize, bytes, 0, 3);
    writeBits(usize, bytes, 8, @intFromPtr(&lengths));
    try testing.expectEqual(@as(usize, 3), written.length);
    try testing.expectEqual(@as(u8, 1), written.values[2]);

    const empty = lengths_to_c(&[_]u8{});
    try testing.expectEqual(@as(usize, 0), empty.length);
    try testing.expect(@intFromPtr(empty.values) != 0);
}

test "accesskit_opt_coords matches the header in both directions" {
    // The list-shaped optional: 24 bytes, a flag, a count, then the pointer.
    const coords = [_]f32{ 1.0, 2.5, 3.0 };
    const present = opt_coords_to_c(&coords);
    try testing.expect(present.has_value);
    try testing.expectEqual(@as(usize, 3), present.length);
    try testing.expectEqual(@as(f32, 2.5), present.values[1]);
    try testing.expectEqual(@as(usize, 8), @offsetOf(COptCoords, "length"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(COptCoords, "values"));

    var written: COptCoords = undefined;
    const bytes = cBytesOf(COptCoords, &written);
    writeBits(bool, bytes, 0, true);
    writeBits(usize, bytes, 8, 2);
    writeBits(usize, bytes, 16, @intFromPtr(&coords));
    try testing.expect(written.has_value);
    try testing.expectEqual(@as(usize, 2), written.length);
    try testing.expectEqual(@as(f32, 1.0), written.values[0]);

    // Absent reads as an empty list rather than as a null the header never
    // promises for this type.
    const absent = opt_coords_to_c(null);
    try testing.expect(!absent.has_value);
    try testing.expectEqual(@as(usize, 0), absent.length);
    try testing.expect(@intFromPtr(absent.values) != 0);
}

test "accesskit_opt_rect matches the header in both directions" {
    const held = schema.rectInit(1, 2, 3, 4);
    const present = opt_rect_to_c(held);
    try testing.expect(present.has_value);
    try testing.expectEqual(held.x0, present.value.x0);
    try testing.expectEqual(@as(usize, 8), @offsetOf(COptRect, "value"));

    var written: COptRect = undefined;
    const bytes = cBytesOf(COptRect, &written);
    writeBits(bool, bytes, 0, true);
    writeBits(f64, bytes, 8, 10.5);
    writeBits(f64, bytes, 32, 20.5);
    try testing.expect(written.has_value);
    try testing.expectEqual(@as(f64, 10.5), written.value.x0);
    try testing.expectEqual(@as(f64, 20.5), written.value.y1);

    const absent = opt_rect_to_c(null);
    try testing.expect(!absent.has_value);
    try testing.expectEqual(@as(f64, 0.0), absent.value.y1);
}

test "accesskit_opt_text_selection matches the header in both directions" {
    const held: TextSelection = .{
        .anchor = .{ .node_id = .{ .value = 1 }, .character_index = 2 },
        .focus = .{ .node_id = .{ .value = 1 }, .character_index = 5 },
    };

    // The borrow is copied out, so the caller may release the node next.
    const present = opt_text_selection_to_c(&held);
    try testing.expect(present.has_value);
    try testing.expect(present.value.eql(held));
    try testing.expectEqual(@as(usize, 8), @offsetOf(COptTextSelection, "value"));

    var written: COptTextSelection = undefined;
    const bytes = cBytesOf(COptTextSelection, &written);
    writeBits(bool, bytes, 0, true);
    // `COptTextSelection.value` is at 8, `anchor` at 0 inside it and `focus` at
    // 16 inside it, so `anchor.node_id` is at 8 and `focus.character_index` at
    // 32. Every one of those four offsets is the header's declaration order
    // with nothing left over, which is the whole claim being tested.
    writeBits(u64, bytes, 8, 99);
    writeBits(usize, bytes, 32, 4);
    try testing.expect(written.has_value);
    try testing.expectEqual(@as(u64, 99), written.value.anchor.node_id.value);
    try testing.expectEqual(@as(usize, 4), written.value.focus.character_index);

    const absent = opt_text_selection_to_c(null);
    try testing.expect(!absent.has_value);
    try testing.expectEqual(@as(usize, 0), absent.value.focus.character_index);
}

test "accesskit_opt_lresult follows LRESULT rather than a literal size" {
    // The header's 16/8/8 is the 64-bit measurement; this asserts the port's
    // 16/8/8 on the 64-bit host and that it would follow `isize` elsewhere.
    try testing.expectEqual(@alignOf(isize), @alignOf(COptLResult));
    try testing.expectEqual(std.mem.alignForward(
        usize,
        @sizeOf(bool) + @sizeOf(isize),
        @alignOf(isize),
    ), @sizeOf(COptLResult));
    try testing.expectEqual(@as(usize, 8), @offsetOf(COptLResult, "value"));

    const present = opt_lresult_to_c(-3);
    try testing.expect(present.has_value);
    try testing.expectEqual(@as(isize, -3), present.value);

    var written: COptLResult = undefined;
    const bytes = cBytesOf(COptLResult, &written);
    writeBits(bool, bytes, 0, true);
    writeBits(isize, bytes, 8, -3);
    try testing.expect(written.has_value);
    try testing.expectEqual(@as(isize, -3), written.value);

    const absent = opt_lresult_to_c(null);
    try testing.expect(!absent.has_value);
    try testing.expectEqual(@as(isize, 0), absent.value);
}

test "accesskit_custom_actions matches the header in both directions" {
    var held = [_]CustomAction{
        try CustomAction.init(testing.allocator, 1, "first"),
        try CustomAction.init(testing.allocator, 2, "second"),
    };
    defer for (&held) |*action| action.deinit(testing.allocator);

    const out = try custom_actions_to_c(testing.allocator, &held);
    defer custom_actions_deinit(testing.allocator, out);

    try testing.expectEqual(@as(usize, 2), out.length);
    try testing.expectEqual(@as(usize, 8), @offsetOf(CCustomActions, "values"));
    try testing.expectEqual(@as(i32, 1), out.values[0].?.id);
    try testing.expectEqualStrings("second", out.values[1].?.description.items);

    var written: CCustomActions = undefined;
    const bytes = cBytesOf(CCustomActions, &written);
    writeBits(usize, bytes, 0, 1);
    writeBits(usize, bytes, 8, @intFromPtr(out.values));
    try testing.expectEqual(@as(usize, 1), written.length);
    try testing.expectEqual(@as(i32, 1), written.values[0].?.id);
}

test "the custom-action copy is deep and releases each action once" {
    var source = try CustomAction.init(testing.allocator, 7, "drag me");
    defer source.deinit(testing.allocator);
    const one = [_]CustomAction{source};

    const out = try custom_actions_to_c(testing.allocator, &one);
    // Editing the source after the copy must not reach the copy, which is what
    // the header promises at `:5075-5076`.
    source.id = 9;
    source.description.clearRetainingCapacity();

    try testing.expectEqual(@as(i32, 7), out.values[0].?.id);
    try testing.expectEqualStrings("drag me", out.values[0].?.description.items);

    // The outer struct and both descriptions are the only allocations, and
    // `custom_actions_deinit` is the only thing that frees them. A leak here
    // fails the test rather than passing silently.
    custom_actions_deinit(testing.allocator, out);
}

test "an empty custom-action list is a list and not a null" {
    // `accesskit-c/include/accesskit.h:5074`: "An empty list has `length == 0`,
    // never a `null` result."
    const out = try custom_actions_to_c(testing.allocator, &.{});
    defer custom_actions_deinit(testing.allocator, out);

    try testing.expectEqual(@as(usize, 0), out.length);
    try testing.expect(@intFromPtr(out.values) != 0);
}

test "the custom-action copy releases everything it made when an allocation fails" {
    // Fail-N from 0 to the last success, which is what `AGENTS.md:101` asks of
    // every allocating function. Each index is one allocation: the outer
    // struct, the pointer array, then one action and one description per
    // element, so a failure at any index must leave nothing behind.
    var held = [_]CustomAction{
        try CustomAction.init(testing.allocator, 1, "one"),
        try CustomAction.init(testing.allocator, 2, "two"),
    };
    defer for (&held) |*action| action.deinit(testing.allocator);

    const allocation_count = 2 + 2 * held.len;
    for (0..allocation_count) |fail_index| {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const result = custom_actions_to_c(failing.allocator(), &held);
        if (result) |out| {
            custom_actions_deinit(failing.allocator(), out);
        } else |err| {
            try testing.expectEqual(CustomActionsToCError.OutOfMemory, err);
        }
        // A leak on any of these paths is the defect this test exists for.
        // `allocations` counts every successful allocation and `deallocations`
        // every free, both cumulative, so a balanced path leaves them equal.
        try testing.expectEqual(failing.allocations, failing.deallocations);
    }
}

test "a string getter cuts at the first NUL and frees at that length" {
    const gpa = testing.allocator;
    const text = "a longer string with \x00 and a tail";

    const copy = try dup_c_string(gpa, text);
    defer string_free(gpa, copy);

    // A C caller reads it with `printf("%s")`, which stops at the first NUL,
    // and so does `string_free`, which is what the header means at `:5050-5053`
    // by a value that "cannot come back out of a `char *` getter without losing
    // its tail". The tail is dropped on the way out, and the copy is one byte
    // longer than the string a C reader sees.
    try testing.expectEqualStrings("a longer string with ", std.mem.span(copy));
    try testing.expectEqual(@as(u8, 0), copy[23]);
    try testing.expectEqualStrings("a longer string with ", c_string_to_slice(copy));

    // The setter and the getter make the same cut, so a value written through
    // the pair reads back out of the getter unchanged. That is the property the
    // header's sentence exists to protect.
    const stored = try gpa.dupe(u8, c_bytes_to_slice(text, text.len));
    defer gpa.free(stored);
    const round_tripped = try dup_c_string(gpa, stored);
    defer string_free(gpa, round_tripped);
    try testing.expectEqualStrings(c_bytes_to_slice(text, text.len), std.mem.span(round_tripped));
}

test "a string with no NUL is copied whole" {
    const gpa = testing.allocator;
    const text = "no interior nul here";

    const copy = try dup_c_string(gpa, text);
    defer string_free(gpa, copy);

    try testing.expectEqualStrings(text, std.mem.span(copy));
}

test "an empty string is one NUL byte and never a null pointer" {
    const gpa = testing.allocator;
    const copy = try dup_c_string(gpa, "");
    defer string_free(gpa, copy);

    try testing.expectEqual(@as(usize, 0), std.mem.span(copy).len);
    try testing.expect(@intFromPtr(copy) != 0);
}

test "duplicating a string reports every allocation failure" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        DupCStringError.OutOfMemory,
        dup_c_string(failing.allocator(), "text"),
    );
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "the string pair stops at the first NUL and at the caller's length" {
    // The header's rule for all twenty-five `_with_length` declarations, at
    // `:2887-2892` and `:5048-5053`: a byte string is stored up to the first
    // NUL byte. A buffer that holds none is taken whole, to the length the
    // caller supplied.
    const gpa = testing.allocator;
    const plain = "12345";
    try testing.expectEqualStrings("12345", c_bytes_to_slice(plain, 5));
    try testing.expectEqualStrings("123", c_bytes_to_slice(plain, 3));
    try testing.expectEqual(@as(usize, 0), c_bytes_to_slice(plain, 0).len);

    // The truncation, from a buffer whose first NUL is inside the length the
    // caller gave. `value` need not be NUL-terminated, so this one ends in `d`.
    const with_nul = "ab\x00cd";
    try testing.expectEqualStrings("ab", c_bytes_to_slice(with_nul, 5));
    // A NUL the caller excluded by its length is not a truncation: the length
    // is checked first, so the bytes at it are never read.
    try testing.expectEqualStrings("ab", c_bytes_to_slice(with_nul, 2));

    // The two forms together are the whole pair the header describes: the
    // bare form reads to the terminator, the pair reads to the length and then
    // to the first NUL inside it. Neither decodes, and neither allocates, so
    // the caller's buffer stays the caller's.
    const copy = try dup_c_string(gpa, with_nul);
    defer string_free(gpa, copy);
    try testing.expectEqualStrings("ab", c_string_to_slice(copy));
}

test "an action payload round trips through the C form in both directions" {
    const gpa = testing.allocator;

    const cases = [_]schema.ActionData{
        .{ .custom_action = 3 },
        .{ .value = try gpa.dupe(u8, "label") },
        .{ .numeric_value = 1.25 },
        .{ .scroll_unit = .item },
        .{ .scroll_hint = .top_left },
        .{ .scroll_to_point = schema.pointInit(1, 2) },
        .{ .set_scroll_offset = schema.pointInit(3, 4) },
        .{ .set_text_selection = .{
            .anchor = .{ .node_id = .{ .value = 1 }, .character_index = 0 },
            .focus = .{ .node_id = .{ .value = 1 }, .character_index = 2 },
        } },
    };
    for (cases) |source| {
        var in_c: schema.ActionData = source;
        defer schema.actionDataDeinit(gpa, &in_c);

        var crossed = try schema.actionDataToC(gpa, in_c);
        var back = try schema.actionDataFromC(gpa, crossed);
        defer schema.actionDataDeinit(gpa, &back);
        schema.cActionDataDeinit(gpa, &crossed);

        switch (source) {
            .value => |text| try testing.expectEqualStrings(text, back.value),
            .custom_action => |id| try testing.expectEqual(id, back.custom_action),
            .numeric_value => |number| try testing.expectEqual(number, back.numeric_value),
            .scroll_unit => |unit| try testing.expectEqual(unit, back.scroll_unit),
            .scroll_hint => |hint| try testing.expectEqual(hint, back.scroll_hint),
            .scroll_to_point => |point| {
                try testing.expectEqual(point.x, back.scroll_to_point.x);
            },
            .set_scroll_offset => |point| {
                try testing.expectEqual(point.y, back.set_scroll_offset.y);
            },
            .set_text_selection => |range| {
                try testing.expect(range.eql(back.set_text_selection));
            },
        }
    }
}

test "an action request reaches a C handler and comes back released" {
    // The one form that crosses in both directions inside a struct: the port
    // builds the request a C handler receives, and reads the same bytes back
    // out of one. `accesskit-c/include/accesskit.h:1717-1723` is the half that
    // matters here: the callback owns the request and releases it with
    // `accesskit_action_request_free` before it returns.
    const gpa = testing.allocator;
    const text = try gpa.dupe(u8, "cut");
    defer gpa.free(text);
    const payload = try schema.actionDataToC(gpa, .{ .value = text });
    const request: schema.CActionRequest = .{
        .action = .click,
        .target_tree = schema.tree_id_root,
        .target_node = .{ .value = 42 },
        .data = .{ .has_value = true, .value = payload },
    };

    // A C handler reads the four fields by name and gets the four values.
    try testing.expectEqual(@as(u8, 1), @sizeOf(@TypeOf(request.action)));
    try testing.expectEqual(schema.Action.click, request.action);
    try testing.expect(schema.tree_id_root.eql(request.target_tree));
    try testing.expectEqual(@as(u64, 42), request.target_node.value);
    try testing.expect(request.data.has_value);
    try testing.expectEqualStrings("cut", std.mem.span(request.data.value.payload.value.?));

    // And the same bytes read back into the core form.
    var read_back = try schema.actionDataFromC(gpa, request.data.value);
    defer schema.actionDataDeinit(gpa, &read_back);
    try testing.expectEqualStrings("cut", read_back.value);

    // `accesskit_action_request_free` releases the string the request owns and
    // nothing else. A second call through the same pointer would double free,
    // so the teardown happens exactly once.
    var given = request;
    schema.cActionRequestDeinit(gpa, &given);
}

test "an action request with no payload releases nothing" {
    // `has_value` false is an ordinary answer, not a failure, and the header
    // says the request owns nothing on that path.
    const gpa = testing.allocator;
    var request: schema.CActionRequest = .{
        .action = .focus,
        .target_tree = schema.tree_id_root,
        .target_node = .{ .value = 1 },
        .data = .{ .has_value = false, .value = std.mem.zeroes(schema.CActionData) },
    };
    schema.cActionRequestDeinit(gpa, &request);
}

test "every re-export above names a declaration that exists" {
    // A re-export nothing references analyses nothing, so a broken alias would
    // compile to nothing and the sweep would pass over it.
    std.testing.refAllDecls(@This());
}
