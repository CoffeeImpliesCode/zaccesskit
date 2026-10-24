//! The C ABI's property surface: the 291 `accesskit_node_*` accessors that go
//! through `schema.Node`'s property store, and the three node-lifetime
//! declarations that bracket them.
//!
//! **What this file is, and why `node.zig` promised it.** `schema.Node`
//! (`src/schema/node.zig:98-116`) has five fields, and `src/capi/node.zig` owns
//! every export that reads or writes the first four: the role, the two action
//! masks and the eighteen flags, sixty-six declarations in all. This file owns
//! every export that goes through the fifth, `properties`, which is the struct's
//! own seam. So the two files cannot disagree about which side of that line a
//! declaration falls on, and a reviewer reading one knows the other is not being
//! read.
//!
//! **The count, and how it was arrived at.** `include/zaccesskit.h` declares 294
//! `accesskit_node_*` declarations. Two hundred and ninety-one are property
//! accessors, and three are the node's lifetime: `accesskit_node_new` at
//! `:5134`, `accesskit_node_free` at `:5143` and `accesskit_node_debug` at
//! `:5153`. Those three are here because they are the declarations a property
//! accessor needs to be reachable at all, and no other module in this namespace
//! declares a `accesskit_node_*` symbol. `export_signatures` below carries one
//! row per declaration and the test at its foot asserts the count.
//!
//! **Where every declaration came from.** Each export's doc comment names the
//! `include/zaccesskit.h` line it ports, and the declaration itself is the C
//! symbol, so a caller links it by the name the header gives. Upstream's own
//! line is not repeated on every one: the node property family is one
//! `property_methods!` block over eight macro families
//! (`accesskit/src/lib.rs:1977-2067` and `:2508-2546`), and the port's split
//! into eight accessor modules is already recorded in `src/schema/node.zig`
//! and in each of `src/schema/props/`. What this file adds is the C line, which
//! is the line a C consumer reads.
//!
//! **The handle is the node.** Upstream's `node` is a zero-sized struct whose
//! only field is `_private: [u8; 0]` (`accesskit-c/src/common.rs:19-21`), and
//! `box_from_ptr` reinterprets it as a `Box<Node>`
//! (`accesskit-c/src/lib.rs:151-156`), so the C pointer IS a `*schema.Node`.
//! Every function here reaches the store through `node_module.node_of` and
//! `node_module.mutable_node`, which are the two reinterpreations `src/capi/node.zig`
//! already declares, so the alignment check and the null-handle ruling are one
//! decision in one place and not two.
//!
//! **The absence conventions, and where they are proved.** Five shapes answer
//! "unset" here and no two of them answer it the same way:
//!
//! - **A `char *` getter returns null.** The 21 string getters and
//!   `accesskit_node_debug` do, and `accesskit_last_error` separates that null
//!   from the one an allocation failure produces.
//! - **A flag-and-payload optional returns `has_value` false over a zeroed
//!   payload.** That is 52 of the exports, and `src/capi/optionals.zig` proves
//!   the shape for all 25 forms including that the flag byte at offset 0 is the
//!   only byte that differs between an absent property and a present one whose
//!   payload is zero.
//! - **A list without a flag returns `length == 0` over a non-null pointer.**
//!   The 8 node-identifier getters and the 2 `accesskit_lengths` getters have no
//!   flag to answer with, so an unset list and a set empty list are the same
//!   answer. That is upstream's shape, not a shortcut here: it stores a missing
//!   value as an empty slice (`accesskit/src/lib.rs:1234-1243`). A test below
//!   pins it, because it is the one accessor shape where a legitimate zero is
//!   *not* distinguishable from absent, and a reader who assumes otherwise is
//!   wrong here.
//! - **`accesskit_node_transform` returns a bare pointer, so null is absent.**
//!   Its doc comment at `include/zaccesskit.h:4911-4916` is copy-pasted from
//!   `accesskit_node_bounds` and talks about a `has_value` flag the return type
//!   does not have. The port implements null for absent and says so at the
//!   declaration, as `src/capi/node.zig` records as ruling 2.
//! - **`accesskit_node_custom_actions` allocates, so null is a failure.** An
//!   empty list is `length == 0`, never null, as `include/zaccesskit.h:5089`
//!   requires.
//!
//! **Two divergences from the header, both named at the declarations.** The first
//! is `ruling 1` of `src/capi/node.zig`: a void setter that can copy cannot
//! report an allocation failure through its return type, so it clears the tag on
//! entry, sets `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path and changes
//! nothing. Every setter and pusher below says so in its own doc comment. The
//! second is the borrow `accesskit_node_transform` returns: the header calls the
//! returned value a copy the caller owns, and the header declares no release
//! for one, so the only pointer the store can hand back is one into the node's
//! own slice. That declaration says what the pointer's lifetime is.
//!
//! **The `comptime` bounds.** Every loop over a declared domain carries its bound
//! here. Three run over the exports and none is at run time: the signature sweep
//! in the `comptime` block below `export_signatures`, whose bound is
//! `export_signatures.len` and is 294; `countFamily`, the census helper, whose
//! bound is that same length; and the sweep over `enum_gates`, whose bound is
//! `enum_gate_count` and is 13. Seven more run in the tests, one per property
//! table, and each reads its bound off the table rather than off a number: the
//! three sweeps over `optional_rows` are 52, and the sweeps over
//! `node_list_rows`, `length_rows`, `coord_rows`, `string_rows` and `push_rows`
//! are 8, 2, 2, 21 and 8. Two walks in the exports run over caller-supplied
//! storage rather than over a domain this file declares, and each is bounded by
//! the length the caller passed or by the list's own length:
//! `accesskit_node_set_custom_actions` walks the borrowed C array and then
//! `copies.items`, and `CountingPair.expectOneReleaseEach` walks its own map.
//!
//! **What this layer never does.** No `zio`, no `io: std.Io`, no clock, no global
//! state, no `unreachable` and no discarded error. `src/capi/handles.zig` owns
//! the handle and `src/capi/marshal.zig` owns the public canonical C types and
//! conversions. Private return packing below changes only the compiler's
//! return classification for 49 optional getters on PowerPC64 Linux musl ELFv2;
//! their C layouts and caller signatures do not change.
//! Private argument lowering covers the seven Color, TextDecoration and TreeId
//! setters on that target; geometry and selection arguments stay canonical.
//! `src/capi/allocation.zig` owns the allocator and the per-thread error tag.
//! The one pointer type this
//! file spells is the element type of a C `const accesskit_node_id *`, which is
//! `schema.NodeId`: an `extern struct` whose only field is the `uint64_t` the
//! header declares at `include/zaccesskit.h:177`, and the same type
//! `marshal.CNodeIds.values` already carries for the same wire type. Nothing here
//! reinterprets anything but that identity.
//!
//! **The shortest sequence that uses this file.**
//!
//! ```zig
//! const handle = accesskit_node_new(18) orelse return;
//! defer accesskit_node_free(handle);
//! accesskit_node_set_label(handle, "Save");
//! // accesskit_node_label(handle) is a `char *` the caller releases with
//! // accesskit_string_free.
//! ```

const std = @import("std");
const builtin = @import("builtin");

const action_request = @import("action_request.zig");
const allocation = @import("allocation.zig");
const handles = @import("handles.zig");
const marshal = @import("marshal.zig");
const node_module = @import("node.zig");
const powerpc_abi = @import("powerpc64_abi.zig");
const schema = @import("../schema/root.zig");

const testing = std.testing;

const Affine = schema.Affine;
const Color = schema.Color;
const CustomAction = schema.CustomAction;
const Node = schema.Node;
const NodeId = schema.NodeId;
const NodeIdContent = schema.NodeIdContent;
const Properties = schema.Properties;
const Rect = schema.Rect;
const TextDecoration = schema.TextDecoration;
const TextSelection = schema.TextSelection;
const TreeId = schema.TreeId;

const props_colors = schema.colors;
const props_enums = schema.enums;
const props_ids = schema.ids_props;
const props_numbers = schema.numbers;
const props_option = schema.option;
const props_strings = schema.strings;
const props_vectors = schema.vectors;

// Zig 0.16 misclassifies small bool/payload C returns on this target (GH #5).
// Dense words or scalar integer bits select the observed ELFv2 register return.
// Five/six-byte aggregates are right-justified, unlike the full eight-byte form.
// GNU ELFv1 and other unverified PowerPC targets keep the canonical types.
const dense_optional_return = powerpc_abi.needs_lowering;

const DenseReturn = extern struct {
    first: u64,
    second: u64,
};

fn OptionalReturn(comptime Canonical: type) type {
    if (!dense_optional_return) return Canonical;
    if (Canonical == marshal.COptNodeId or Canonical == marshal.COptIndex or
        Canonical == marshal.COptDouble)
    {
        std.debug.assert(@sizeOf(Canonical) == 16);
        std.debug.assert(@offsetOf(Canonical, "value") == 8);
        return DenseReturn;
    }
    if (Canonical == marshal.COptFloat) {
        std.debug.assert(@sizeOf(Canonical) == 8);
        std.debug.assert(@offsetOf(Canonical, "value") == 4);
        return u64;
    }
    if (Canonical == marshal.COptColor or Canonical == marshal.COptTextDecoration) {
        std.debug.assert(@alignOf(Canonical) == 1);
        std.debug.assert(@offsetOf(Canonical, "value") == 1);
        std.debug.assert(@sizeOf(Canonical) == if (Canonical == marshal.COptColor) 5 else 6);
        return u64;
    }
    const Value = @FieldType(Canonical, "value");
    if (Value == bool or @typeInfo(Value) == .@"enum") {
        std.debug.assert(@sizeOf(Canonical) == 2);
        std.debug.assert(@alignOf(Canonical) == 1);
        std.debug.assert(@offsetOf(Canonical, "value") == 1);
        return u16;
    }
    @compileError("unobserved optional C return representation");
}

fn colorReturnBits(color: Color) u64 {
    return (@as(u64, color.red) << 24) | (@as(u64, color.green) << 16) |
        (@as(u64, color.blue) << 8) | @as(u64, color.alpha);
}

fn optionalReturn(
    comptime Canonical: type,
    optional: ?@FieldType(Canonical, "value"),
) OptionalReturn(Canonical) {
    if (!dense_optional_return) {
        if (optional) |held| return .{ .has_value = true, .value = held };
        return .{ .has_value = false, .value = std.mem.zeroes(@FieldType(Canonical, "value")) };
    }
    const Return = OptionalReturn(Canonical);
    // Pack the property's primitive fields directly: no canonical temporary,
    // padding read, or access to an absent payload.
    const held = optional orelse
        return if (Return == DenseReturn) .{ .first = 0, .second = 0 } else 0;
    if (Return == DenseReturn) {
        const payload: u64 = if (Canonical == marshal.COptNodeId)
            held.value
        else if (Canonical == marshal.COptDouble)
            @bitCast(held)
        else
            @intCast(held);
        // The flag is the first byte in memory, not the low bit on big endian.
        const flag: u64 = if (builtin.cpu.arch.endian() == .big) 1 << 56 else 1;
        return .{ .first = flag, .second = payload };
    }
    if (Canonical == marshal.COptFloat) {
        return (@as(u64, 1) << 56) | @as(u32, @bitCast(held));
    }
    if (Canonical == marshal.COptColor) {
        return (@as(u64, 1) << 32) | colorReturnBits(held);
    }
    if (Canonical == marshal.COptTextDecoration) {
        return (@as(u64, 1) << 40) | (@as(u64, @backingInt(held.style)) << 32) |
            colorReturnBits(held.color);
    }
    const value: u16 = if (@FieldType(Canonical, "value") == bool)
        @intFromBool(held)
    else
        @backingInt(held);
    return (@as(u16, 1) << 8) | value;
}

// The same target also misclassifies Color/Decoration/TreeId arguments.
// Independent C calls proved low scalar bits for four/five bytes and two dense
// words for sixteen; the working HFA geometry and selection inputs stay native.
fn TargetArg(comptime Canonical: type) type {
    if (!dense_optional_return) return Canonical;
    if (Canonical == Color or Canonical == TextDecoration) return u64;
    if (Canonical == TreeId) return powerpc_abi.TreeIdValue;
    return Canonical;
}

fn decodeArg(comptime Canonical: type, value: TargetArg(Canonical)) Canonical {
    if (!dense_optional_return) return value;
    if (Canonical == TreeId) return powerpc_abi.treeIdFromValue(value);
    const color: Color = .{
        .red = @truncate(value >> 24),
        .green = @truncate(value >> 16),
        .blue = @truncate(value >> 8),
        .alpha = @truncate(value),
    };
    if (Canonical == Color) return color;
    return .{
        .style = @fromBackingInt(@intCast(@as(u8, @truncate(value >> 32)))),
        .color = color,
    };
}

/// Clears the per-thread failure tag, which every export here does on entry.
///
/// `include/zaccesskit.h:6502-6506` requires it: other functions clear both
/// diagnostics on entry. Without it a getter that answers "absent" would
/// inherit the tag of an earlier failing call, and a C caller could not tell the
/// two apart. It is one thread-local store and nothing else.
fn enter() void {
    allocation.clearError();
}

/// Records an out-of-memory failure in this module's diagnostic slot.
///
/// The C error domain also has `ACCESSKIT_ERROR_OPERATION_FAILED`
/// (`include/zaccesskit.h:1780-1784`); this module uses the OOM tag
/// (`include/zaccesskit.h:1782`).
fn note_oom() void {
    allocation.failWith(.out_of_memory);
}

/// The property store behind a read-only C handle.
///
/// A borrow of the node's own field, so every getter in this file reads the
/// block the caller already owns and allocates nothing of its own. Passing a null
/// handle is a caller defect the header does not describe, so this does not
/// answer for it.
fn properties_of(handle: *const handles.accesskit_node) *const Properties {
    return &node_module.node_of(handle).properties;
}

/// The property store behind a writable C handle.
///
/// The same reinterpretation as `properties_of`, reached through
/// `node.mutable_node` so the alignment check stays in one place. Writing through
/// the result touches the store the caller owns.
fn mutable_properties(handle: *handles.accesskit_node) *Properties {
    return &node_module.mutable_node(handle).properties;
}

/// Releases every action `list` holds and then `list` itself.
///
/// One `defer` in `accesskit_node_set_custom_actions` calls this, and it is
/// unconditional: the null-slot precondition, the failed clone, the failed
/// append and the failed store all leave a prefix of copies behind, and the
/// successful path does too, because the store copies each description rather
/// than adopting the clone this call made.
///
/// The walk is bounded by `list.items.len`, which is the number of clones the
/// loop above managed to make, so a clone is released exactly once and no slot
/// is read that was never written.
fn releaseActionCopies(gpa: std.mem.Allocator, list: *std.ArrayList(CustomAction)) void {
    for (list.items) |*action| action.deinit(gpa);
    list.deinit(gpa);
}

/// Ends the process for a call both headers say cannot succeed.
///
/// `include/zaccesskit.h:5140` is the sentence, and
/// `src/capi/tree_info.zig` and `src/capi/tree_update.zig` each carry the same
/// helper for the same reason.
/// `std.process.exit` rather than `panic` or `unreachable` because the house
/// rules forbid both on this boundary, and `exit` rather than `abort` because
/// `exit` hands the caller a status it can act on after the diagnostic below.
/// The write is `std.log`, not `std.debug.print`: the second is the debugging
/// channel, and this line is a deliberate end-of-process diagnostic.
fn terminate(comptime function_name: []const u8, reason: []const u8) noreturn {
    std.log.err("zaccesskit: {s}: {s}", .{ function_name, reason });
    std.process.exit(1);
}

/// The thirteen C enumerations this file decodes on the way in.
///
/// A setter for one of the twelve property enumerations takes a bare byte, and
/// the byte crosses as `u8` for the reason `src/capi/node.zig` records for a role
/// byte. That spelling is sound only while every tag fits in a `u8`, which is
/// what the `comptime` block below checks. `invalid` and `toggled` have the
/// `true_` variant upstream drops the trailing underscore from in C, and the
/// table carries the Zig spelling because that is what `@typeInfo` reports.
const enum_gates = [_]struct { c_name: []const u8, zig_type: type }{
    .{ .c_name = "accesskit_invalid", .zig_type = schema.Invalid },
    .{ .c_name = "accesskit_toggled", .zig_type = schema.Toggled },
    .{ .c_name = "accesskit_live", .zig_type = schema.Live },
    .{ .c_name = "accesskit_text_direction", .zig_type = schema.TextDirection },
    .{ .c_name = "accesskit_orientation", .zig_type = schema.Orientation },
    .{ .c_name = "accesskit_sort_direction", .zig_type = schema.SortDirection },
    .{ .c_name = "accesskit_aria_current", .zig_type = schema.AriaCurrent },
    .{ .c_name = "accesskit_auto_complete", .zig_type = schema.AutoComplete },
    .{ .c_name = "accesskit_has_popup", .zig_type = schema.HasPopup },
    .{ .c_name = "accesskit_list_style", .zig_type = schema.ListStyle },
    .{ .c_name = "accesskit_text_align", .zig_type = schema.TextAlign },
    .{ .c_name = "accesskit_vertical_offset", .zig_type = schema.VerticalOffset },
    .{ .c_name = "accesskit_role", .zig_type = schema.Role },
};

/// How many rows `enum_gates` has: 13.
///
/// Read off the table so a fourteenth enumeration added to it is counted without
/// an edit here, and it is the bound on the sweep in the `comptime` block.
const enum_gate_count: u32 = @intCast(enum_gates.len);

const export_names = [_][]const u8{
    "accesskit_node_new",
    "accesskit_node_free",
    "accesskit_node_debug",
    "accesskit_node_children",
    "accesskit_node_clear_children",
    "accesskit_node_clear_controls",
    "accesskit_node_clear_described_by",
    "accesskit_node_clear_details",
    "accesskit_node_clear_flow_to",
    "accesskit_node_clear_labelled_by",
    "accesskit_node_clear_owns",
    "accesskit_node_clear_radio_group",
    "accesskit_node_controls",
    "accesskit_node_described_by",
    "accesskit_node_details",
    "accesskit_node_flow_to",
    "accesskit_node_labelled_by",
    "accesskit_node_owns",
    "accesskit_node_push_child",
    "accesskit_node_push_controlled",
    "accesskit_node_push_described_by",
    "accesskit_node_push_detail",
    "accesskit_node_push_flow_to",
    "accesskit_node_push_labelled_by",
    "accesskit_node_push_owned",
    "accesskit_node_push_to_radio_group",
    "accesskit_node_radio_group",
    "accesskit_node_set_children",
    "accesskit_node_set_controls",
    "accesskit_node_set_described_by",
    "accesskit_node_set_details",
    "accesskit_node_set_flow_to",
    "accesskit_node_set_labelled_by",
    "accesskit_node_set_owns",
    "accesskit_node_set_radio_group",
    "accesskit_node_active_descendant",
    "accesskit_node_clear_active_descendant",
    "accesskit_node_clear_error_message",
    "accesskit_node_clear_in_page_link_target",
    "accesskit_node_clear_member_of",
    "accesskit_node_clear_next_on_line",
    "accesskit_node_clear_popup_for",
    "accesskit_node_clear_previous_on_line",
    "accesskit_node_error_message",
    "accesskit_node_in_page_link_target",
    "accesskit_node_member_of",
    "accesskit_node_next_on_line",
    "accesskit_node_popup_for",
    "accesskit_node_previous_on_line",
    "accesskit_node_set_active_descendant",
    "accesskit_node_set_error_message",
    "accesskit_node_set_in_page_link_target",
    "accesskit_node_set_member_of",
    "accesskit_node_set_next_on_line",
    "accesskit_node_set_popup_for",
    "accesskit_node_set_previous_on_line",
    "accesskit_node_clear_tree_id",
    "accesskit_node_set_tree_id",
    "accesskit_node_tree_id",
    "accesskit_node_access_key",
    "accesskit_node_author_id",
    "accesskit_node_braille_label",
    "accesskit_node_braille_role_description",
    "accesskit_node_class_name",
    "accesskit_node_clear_access_key",
    "accesskit_node_clear_author_id",
    "accesskit_node_clear_braille_label",
    "accesskit_node_clear_braille_role_description",
    "accesskit_node_clear_class_name",
    "accesskit_node_clear_column_index_text",
    "accesskit_node_clear_description",
    "accesskit_node_clear_font_family",
    "accesskit_node_clear_html_id",
    "accesskit_node_clear_html_tag",
    "accesskit_node_clear_inner_html",
    "accesskit_node_clear_keyboard_shortcut",
    "accesskit_node_clear_label",
    "accesskit_node_clear_language",
    "accesskit_node_clear_placeholder",
    "accesskit_node_clear_role_description",
    "accesskit_node_clear_row_index_text",
    "accesskit_node_clear_state_description",
    "accesskit_node_clear_tooltip",
    "accesskit_node_clear_url",
    "accesskit_node_clear_value",
    "accesskit_node_column_index_text",
    "accesskit_node_description",
    "accesskit_node_font_family",
    "accesskit_node_html_id",
    "accesskit_node_html_tag",
    "accesskit_node_inner_html",
    "accesskit_node_keyboard_shortcut",
    "accesskit_node_label",
    "accesskit_node_language",
    "accesskit_node_placeholder",
    "accesskit_node_role_description",
    "accesskit_node_row_index_text",
    "accesskit_node_set_access_key",
    "accesskit_node_set_access_key_with_length",
    "accesskit_node_set_author_id",
    "accesskit_node_set_author_id_with_length",
    "accesskit_node_set_braille_label",
    "accesskit_node_set_braille_label_with_length",
    "accesskit_node_set_braille_role_description",
    "accesskit_node_set_braille_role_description_with_length",
    "accesskit_node_set_class_name",
    "accesskit_node_set_class_name_with_length",
    "accesskit_node_set_column_index_text",
    "accesskit_node_set_column_index_text_with_length",
    "accesskit_node_set_description",
    "accesskit_node_set_description_with_length",
    "accesskit_node_set_font_family",
    "accesskit_node_set_font_family_with_length",
    "accesskit_node_set_html_id",
    "accesskit_node_set_html_id_with_length",
    "accesskit_node_set_html_tag",
    "accesskit_node_set_html_tag_with_length",
    "accesskit_node_set_inner_html",
    "accesskit_node_set_inner_html_with_length",
    "accesskit_node_set_keyboard_shortcut",
    "accesskit_node_set_keyboard_shortcut_with_length",
    "accesskit_node_set_label",
    "accesskit_node_set_label_with_length",
    "accesskit_node_set_language",
    "accesskit_node_set_language_with_length",
    "accesskit_node_set_placeholder",
    "accesskit_node_set_placeholder_with_length",
    "accesskit_node_set_role_description",
    "accesskit_node_set_role_description_with_length",
    "accesskit_node_set_row_index_text",
    "accesskit_node_set_row_index_text_with_length",
    "accesskit_node_set_state_description",
    "accesskit_node_set_state_description_with_length",
    "accesskit_node_set_tooltip",
    "accesskit_node_set_tooltip_with_length",
    "accesskit_node_set_url",
    "accesskit_node_set_url_with_length",
    "accesskit_node_set_value",
    "accesskit_node_set_value_with_length",
    "accesskit_node_state_description",
    "accesskit_node_tooltip",
    "accesskit_node_url",
    "accesskit_node_value",
    "accesskit_node_clear_column_count",
    "accesskit_node_clear_column_index",
    "accesskit_node_clear_column_span",
    "accesskit_node_clear_font_size",
    "accesskit_node_clear_font_weight",
    "accesskit_node_clear_level",
    "accesskit_node_clear_max_numeric_value",
    "accesskit_node_clear_min_numeric_value",
    "accesskit_node_clear_numeric_value",
    "accesskit_node_clear_numeric_value_jump",
    "accesskit_node_clear_numeric_value_step",
    "accesskit_node_clear_position_in_set",
    "accesskit_node_clear_row_count",
    "accesskit_node_clear_row_index",
    "accesskit_node_clear_row_span",
    "accesskit_node_clear_scroll_x",
    "accesskit_node_clear_scroll_x_max",
    "accesskit_node_clear_scroll_x_min",
    "accesskit_node_clear_scroll_y",
    "accesskit_node_clear_scroll_y_max",
    "accesskit_node_clear_scroll_y_min",
    "accesskit_node_clear_size_of_set",
    "accesskit_node_column_count",
    "accesskit_node_column_index",
    "accesskit_node_column_span",
    "accesskit_node_font_size",
    "accesskit_node_font_weight",
    "accesskit_node_level",
    "accesskit_node_max_numeric_value",
    "accesskit_node_min_numeric_value",
    "accesskit_node_numeric_value",
    "accesskit_node_numeric_value_jump",
    "accesskit_node_numeric_value_step",
    "accesskit_node_position_in_set",
    "accesskit_node_row_count",
    "accesskit_node_row_index",
    "accesskit_node_row_span",
    "accesskit_node_scroll_x",
    "accesskit_node_scroll_x_max",
    "accesskit_node_scroll_x_min",
    "accesskit_node_scroll_y",
    "accesskit_node_scroll_y_max",
    "accesskit_node_scroll_y_min",
    "accesskit_node_set_column_count",
    "accesskit_node_set_column_index",
    "accesskit_node_set_column_span",
    "accesskit_node_set_font_size",
    "accesskit_node_set_font_weight",
    "accesskit_node_set_level",
    "accesskit_node_set_max_numeric_value",
    "accesskit_node_set_min_numeric_value",
    "accesskit_node_set_numeric_value",
    "accesskit_node_set_numeric_value_jump",
    "accesskit_node_set_numeric_value_step",
    "accesskit_node_set_position_in_set",
    "accesskit_node_set_row_count",
    "accesskit_node_set_row_index",
    "accesskit_node_set_row_span",
    "accesskit_node_set_scroll_x",
    "accesskit_node_set_scroll_x_max",
    "accesskit_node_set_scroll_x_min",
    "accesskit_node_set_scroll_y",
    "accesskit_node_set_scroll_y_max",
    "accesskit_node_set_scroll_y_min",
    "accesskit_node_set_size_of_set",
    "accesskit_node_size_of_set",
    "accesskit_node_background_color",
    "accesskit_node_clear_background_color",
    "accesskit_node_clear_color_value",
    "accesskit_node_clear_foreground_color",
    "accesskit_node_clear_overline",
    "accesskit_node_clear_strikethrough",
    "accesskit_node_clear_underline",
    "accesskit_node_color_value",
    "accesskit_node_foreground_color",
    "accesskit_node_overline",
    "accesskit_node_set_background_color",
    "accesskit_node_set_color_value",
    "accesskit_node_set_foreground_color",
    "accesskit_node_set_overline",
    "accesskit_node_set_strikethrough",
    "accesskit_node_set_underline",
    "accesskit_node_strikethrough",
    "accesskit_node_underline",
    "accesskit_node_character_lengths",
    "accesskit_node_character_positions",
    "accesskit_node_character_widths",
    "accesskit_node_clear_character_lengths",
    "accesskit_node_clear_character_positions",
    "accesskit_node_clear_character_widths",
    "accesskit_node_clear_word_starts",
    "accesskit_node_set_character_lengths",
    "accesskit_node_set_character_positions",
    "accesskit_node_set_character_widths",
    "accesskit_node_set_word_starts",
    "accesskit_node_word_starts",
    "accesskit_node_clear_expanded",
    "accesskit_node_clear_selected",
    "accesskit_node_is_expanded",
    "accesskit_node_is_selected",
    "accesskit_node_set_expanded",
    "accesskit_node_set_selected",
    "accesskit_node_aria_current",
    "accesskit_node_auto_complete",
    "accesskit_node_clear_aria_current",
    "accesskit_node_clear_auto_complete",
    "accesskit_node_clear_has_popup",
    "accesskit_node_clear_invalid",
    "accesskit_node_clear_list_style",
    "accesskit_node_clear_live",
    "accesskit_node_clear_orientation",
    "accesskit_node_clear_sort_direction",
    "accesskit_node_clear_text_align",
    "accesskit_node_clear_text_direction",
    "accesskit_node_clear_toggled",
    "accesskit_node_clear_vertical_offset",
    "accesskit_node_has_popup",
    "accesskit_node_invalid",
    "accesskit_node_list_style",
    "accesskit_node_live",
    "accesskit_node_orientation",
    "accesskit_node_set_aria_current",
    "accesskit_node_set_auto_complete",
    "accesskit_node_set_has_popup",
    "accesskit_node_set_invalid",
    "accesskit_node_set_list_style",
    "accesskit_node_set_live",
    "accesskit_node_set_orientation",
    "accesskit_node_set_sort_direction",
    "accesskit_node_set_text_align",
    "accesskit_node_set_text_direction",
    "accesskit_node_set_toggled",
    "accesskit_node_set_vertical_offset",
    "accesskit_node_sort_direction",
    "accesskit_node_text_align",
    "accesskit_node_text_direction",
    "accesskit_node_toggled",
    "accesskit_node_vertical_offset",
    "accesskit_node_bounds",
    "accesskit_node_clear_bounds",
    "accesskit_node_clear_text_selection",
    "accesskit_node_clear_transform",
    "accesskit_node_set_bounds",
    "accesskit_node_set_text_selection",
    "accesskit_node_set_transform",
    "accesskit_node_text_selection",
    "accesskit_node_transform",
    "accesskit_node_clear_custom_actions",
    "accesskit_node_custom_actions",
    "accesskit_node_push_custom_action",
    "accesskit_node_set_custom_actions",
};
// --- The node lifetime -------------------------------------------------------

/// Returns a new node with `role` set, or null when the allocation failed.
///
/// `include/zaccesskit.h:5134`. The caller owns the node and releases it with
/// `accesskit_node_free`, once, unless ownership passes to
/// `accesskit_tree_update_push_node`. A null return means
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` and nothing else, so `accesskit_last_error`
/// carries nothing this call did not already say. Nothing is allocated on the
/// failure path: the one block is the only allocation, and a block the
/// allocator cannot supply leaves the store it would have held unbuilt.
///
/// `role` is a role byte and crosses as the `u8` the sibling
/// `accesskit_node_set_role` already takes, for the reason `node.zig` records.
/// A byte past the last of the 182 tags is a caller precondition this
/// declaration does not check for, and it answers null with the tag `.none`,
/// because a node with no role has no representation the rest of the header can
/// read.
export fn accesskit_node_new(role: u8) callconv(.c) ?*handles.accesskit_node {
    enter();
    const wanted = node_module.role_from_c(role) orelse return null;
    const gpa = allocation.allocator();
    const block = gpa.create(Node) catch {
        note_oom();
        return null;
    };
    block.* = Node.init(gpa, wanted);
    return @ptrCast(block);
}

/// Releases the node and every string and list it owns, exactly once.
///
/// `include/zaccesskit.h:5143`. The allocator that created it is not released.
/// The node is unusable after this call and a second call on the same pointer
/// is a double free. Passing null terminates the process, which is what
/// `include/zaccesskit.h:5140` states; the parameter is an optional pointer so
/// that the documented answer is the one this port reaches rather than a
/// dereference of null, and the two spellings are the same width in the calling
/// convention.
///
/// The release goes through the allocator the node's own store was built with,
/// because that is the allocator every property buffer came from, and through
/// the block's own. What that allocator is at the moment of the free is the
/// channel as it stands then: `allocation.zig:266-270` installs one pair for
/// the process, so a pair installed after `accesskit_node_new` receives these
/// releases. The header says the opposite at `include/zaccesskit.h:6469-6470` —
/// "an allocator installed after the first call has no effect on allocations
/// already made" — and for a `malloc`/`free` pair the two readings are the same
/// call. The store is still the right allocator to reach for, because it is the
/// one that owns the buffers, and it is the one that would be right if the
/// channel were ever pinned per store.
export fn accesskit_node_free(node: ?*handles.accesskit_node) callconv(.c) void {
    enter();
    const handle = node orelse terminate("accesskit_node_free", "the handle was null");
    const block: *Node = @ptrCast(@alignCast(handle));
    const gpa = block.properties.gpa;
    block.deinit();
    gpa.destroy(block);
}

/// Returns a text rendering of the node, or null when the text could not be
/// built.
///
/// `include/zaccesskit.h:5153`. Release the result with
/// `accesskit_string_free`, once, and never with `free`. The text borrows
/// nothing from the node once the call returns, so the node may be released
/// first.
///
/// A null return means `ACCESSKIT_ERROR_OUT_OF_MEMORY` and nothing else. The
/// text is `schema.Node`'s own rendering, so it names the role, the two action
/// sets, the flags and the properties that are set, in that order.
export fn accesskit_node_debug(node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 {
    enter();
    const gpa = allocation.allocator();
    var owning: std.Io.Writer.Allocating = .init(gpa);
    defer owning.deinit();
    node_module.node_of(node).format(&owning.writer) catch |err| switch (err) {
        // A writer that owns its buffer and grows it has one way to fail, the
        // `ensureUnusedCapacity` call behind `error.WriteFailed`, and that one
        // tag answers it.
        error.WriteFailed => {
            note_oom();
            return null;
        },
    };
    const text = owning.toOwnedSliceSentinel(0) catch {
        note_oom();
        return null;
    };
    // `deinit` above sees an empty buffer once the slice has taken the bytes, so
    // the two do not release them between them.
    return @ptrCast(text.ptr);
}

// --- The node identifier lists -----------------------------------------------

/// The `children` property as a list of node identifiers.
///
/// `include/zaccesskit.h:2320`. An unset property gives `length == 0` with a
/// non-null `values`, so a caller that ignores the length reads an empty list
/// rather than a dangling pointer.
///
/// The result borrows the node's own storage, so the node must stay alive and
/// its list unmodified for as long as the caller reads it, and no function
/// releases it. This is a borrow, so the getter allocates nothing, cannot fail,
/// and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_children(
    node: *const handles.accesskit_node,
) callconv(.c) marshal.CNodeIds {
    enter();
    return marshal.node_ids_to_c(props_ids.children(properties_of(node)));
}

/// Clears the `children` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2348`. The list leaves the store rather than becoming
/// an empty one, so the property is absent and the getter reports an empty
/// list. Returns nothing and cannot fail.
export fn accesskit_node_clear_children(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_ids.clearChildren(mutable_properties(node));
}

/// Clears the `controls` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2387`. The list leaves the store rather than becoming
/// an empty one, so the property is absent and the getter reports an empty
/// list. Returns nothing and cannot fail.
export fn accesskit_node_clear_controls(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_ids.clearControls(mutable_properties(node));
}

/// Clears the `described_by` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2465`. The list leaves the store rather than becoming
/// an empty one, so the property is absent and the getter reports an empty
/// list. Returns nothing and cannot fail.
export fn accesskit_node_clear_described_by(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_ids.clearDescribedBy(mutable_properties(node));
}

/// Clears the `details` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2425`. The list leaves the store rather than becoming
/// an empty one, so the property is absent and the getter reports an empty
/// list. Returns nothing and cannot fail.
export fn accesskit_node_clear_details(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_ids.clearDetails(mutable_properties(node));
}

/// Clears the `flow_to` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2503`. The list leaves the store rather than becoming
/// an empty one, so the property is absent and the getter reports an empty
/// list. Returns nothing and cannot fail.
export fn accesskit_node_clear_flow_to(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_ids.clearFlowTo(mutable_properties(node));
}

/// Clears the `labelled_by` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2543`. The list leaves the store rather than becoming
/// an empty one, so the property is absent and the getter reports an empty
/// list. Returns nothing and cannot fail.
export fn accesskit_node_clear_labelled_by(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_ids.clearLabelledBy(mutable_properties(node));
}

/// Clears the `owns` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2580`. The list leaves the store rather than becoming
/// an empty one, so the property is absent and the getter reports an empty
/// list. Returns nothing and cannot fail.
export fn accesskit_node_clear_owns(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_ids.clearOwns(mutable_properties(node));
}

/// Clears the `radio_group` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2620`. The list leaves the store rather than becoming
/// an empty one, so the property is absent and the getter reports an empty
/// list. Returns nothing and cannot fail.
export fn accesskit_node_clear_radio_group(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_ids.clearRadioGroup(mutable_properties(node));
}

/// The `controls` property as a list of node identifiers.
///
/// `include/zaccesskit.h:2359`. An unset property gives `length == 0` with a
/// non-null `values`, so a caller that ignores the length reads an empty list
/// rather than a dangling pointer.
///
/// The result borrows the node's own storage, so the node must stay alive and
/// its list unmodified for as long as the caller reads it, and no function
/// releases it. This is a borrow, so the getter allocates nothing, cannot fail,
/// and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_controls(
    node: *const handles.accesskit_node,
) callconv(.c) marshal.CNodeIds {
    enter();
    return marshal.node_ids_to_c(props_ids.controls(properties_of(node)));
}

/// The `described_by` property as a list of node identifiers.
///
/// `include/zaccesskit.h:2436`. An unset property gives `length == 0` with a
/// non-null `values`, so a caller that ignores the length reads an empty list
/// rather than a dangling pointer.
///
/// The result borrows the node's own storage, so the node must stay alive and
/// its list unmodified for as long as the caller reads it, and no function
/// releases it. This is a borrow, so the getter allocates nothing, cannot fail,
/// and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_described_by(
    node: *const handles.accesskit_node,
) callconv(.c) marshal.CNodeIds {
    enter();
    return marshal.node_ids_to_c(props_ids.describedBy(properties_of(node)));
}

/// The `details` property as a list of node identifiers.
///
/// `include/zaccesskit.h:2398`. An unset property gives `length == 0` with a
/// non-null `values`, so a caller that ignores the length reads an empty list
/// rather than a dangling pointer.
///
/// The result borrows the node's own storage, so the node must stay alive and
/// its list unmodified for as long as the caller reads it, and no function
/// releases it. This is a borrow, so the getter allocates nothing, cannot fail,
/// and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_details(
    node: *const handles.accesskit_node,
) callconv(.c) marshal.CNodeIds {
    enter();
    return marshal.node_ids_to_c(props_ids.details(properties_of(node)));
}

/// The `flow_to` property as a list of node identifiers.
///
/// `include/zaccesskit.h:2476`. An unset property gives `length == 0` with a
/// non-null `values`, so a caller that ignores the length reads an empty list
/// rather than a dangling pointer.
///
/// The result borrows the node's own storage, so the node must stay alive and
/// its list unmodified for as long as the caller reads it, and no function
/// releases it. This is a borrow, so the getter allocates nothing, cannot fail,
/// and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_flow_to(
    node: *const handles.accesskit_node,
) callconv(.c) marshal.CNodeIds {
    enter();
    return marshal.node_ids_to_c(props_ids.flowTo(properties_of(node)));
}

/// The `labelled_by` property as a list of node identifiers.
///
/// `include/zaccesskit.h:2514`. An unset property gives `length == 0` with a
/// non-null `values`, so a caller that ignores the length reads an empty list
/// rather than a dangling pointer.
///
/// The result borrows the node's own storage, so the node must stay alive and
/// its list unmodified for as long as the caller reads it, and no function
/// releases it. This is a borrow, so the getter allocates nothing, cannot fail,
/// and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_labelled_by(
    node: *const handles.accesskit_node,
) callconv(.c) marshal.CNodeIds {
    enter();
    return marshal.node_ids_to_c(props_ids.labelledBy(properties_of(node)));
}

/// The `owns` property as a list of node identifiers.
///
/// `include/zaccesskit.h:2554`. An unset property gives `length == 0` with a
/// non-null `values`, so a caller that ignores the length reads an empty list
/// rather than a dangling pointer.
///
/// The result borrows the node's own storage, so the node must stay alive and
/// its list unmodified for as long as the caller reads it, and no function
/// releases it. This is a borrow, so the getter allocates nothing, cannot fail,
/// and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_owns(node: *const handles.accesskit_node) callconv(.c) marshal.CNodeIds {
    enter();
    return marshal.node_ids_to_c(props_ids.owns(properties_of(node)));
}

/// Appends `item` to the node's `children`.
///
/// `include/zaccesskit.h:2339`. A push after the property was cleared starts a
/// new list holding only `item`, which is upstream's 0.25.0 fix
/// (`accesskit/src/lib.rs:1359-1365`).
///
/// **A void pusher that can fail.** On failure the list is unchanged and the
/// tag becomes `ACCESSKIT_ERROR_OUT_OF_MEMORY`. The pusher explicitly maps
/// both error arms to that tag. `PropertyTagMismatch` is documented at
/// `src/schema/props/vectors.zig:65-70` as unreachable through valid
/// property-store paths.
export fn accesskit_node_push_child(
    node: *handles.accesskit_node,
    item: NodeIdContent,
) callconv(.c) void {
    enter();
    const wanted = schema.nodeIdFromContent(item);
    props_ids.pushChild(mutable_properties(node), wanted) catch |err| switch (err) {
        error.OutOfMemory => note_oom(),
        error.PropertyTagMismatch => note_oom(),
    };
}

/// Appends `item` to the node's `controls`.
///
/// `include/zaccesskit.h:2378`. A push after the property was cleared starts a
/// new list holding only `item`, which is upstream's 0.25.0 fix
/// (`accesskit/src/lib.rs:1359-1365`).
///
/// **A void pusher that can fail.** On failure the list is unchanged and the
/// tag becomes `ACCESSKIT_ERROR_OUT_OF_MEMORY`. The pusher explicitly maps
/// both error arms to that tag. `PropertyTagMismatch` is documented at
/// `src/schema/props/vectors.zig:65-70` as unreachable through valid
/// property-store paths.
export fn accesskit_node_push_controlled(
    node: *handles.accesskit_node,
    item: NodeIdContent,
) callconv(.c) void {
    enter();
    const wanted = schema.nodeIdFromContent(item);
    props_ids.pushControlled(mutable_properties(node), wanted) catch |err| switch (err) {
        error.OutOfMemory => note_oom(),
        error.PropertyTagMismatch => note_oom(),
    };
}

/// Appends `item` to the node's `described_by`.
///
/// `include/zaccesskit.h:2456`. A push after the property was cleared starts a
/// new list holding only `item`, which is upstream's 0.25.0 fix
/// (`accesskit/src/lib.rs:1359-1365`).
///
/// **A void pusher that can fail.** On failure the list is unchanged and the
/// tag becomes `ACCESSKIT_ERROR_OUT_OF_MEMORY`. The pusher explicitly maps
/// both error arms to that tag. `PropertyTagMismatch` is documented at
/// `src/schema/props/vectors.zig:65-70` as unreachable through valid
/// property-store paths.
export fn accesskit_node_push_described_by(
    node: *handles.accesskit_node,
    item: NodeIdContent,
) callconv(.c) void {
    enter();
    const wanted = schema.nodeIdFromContent(item);
    props_ids.pushDescribedBy(mutable_properties(node), wanted) catch |err| switch (err) {
        error.OutOfMemory => note_oom(),
        error.PropertyTagMismatch => note_oom(),
    };
}

/// Appends `item` to the node's `details`.
///
/// `include/zaccesskit.h:2417`. A push after the property was cleared starts a
/// new list holding only `item`, which is upstream's 0.25.0 fix
/// (`accesskit/src/lib.rs:1359-1365`).
///
/// **A void pusher that can fail.** On failure the list is unchanged and the
/// tag becomes `ACCESSKIT_ERROR_OUT_OF_MEMORY`. The pusher explicitly maps
/// both error arms to that tag. `PropertyTagMismatch` is documented at
/// `src/schema/props/vectors.zig:65-70` as unreachable through valid
/// property-store paths.
export fn accesskit_node_push_detail(
    node: *handles.accesskit_node,
    item: NodeIdContent,
) callconv(.c) void {
    enter();
    const wanted = schema.nodeIdFromContent(item);
    props_ids.pushDetail(mutable_properties(node), wanted) catch |err| switch (err) {
        error.OutOfMemory => note_oom(),
        error.PropertyTagMismatch => note_oom(),
    };
}

/// Appends `item` to the node's `flow_to`.
///
/// `include/zaccesskit.h:2495`. A push after the property was cleared starts a
/// new list holding only `item`, which is upstream's 0.25.0 fix
/// (`accesskit/src/lib.rs:1359-1365`).
///
/// **A void pusher that can fail.** On failure the list is unchanged and the
/// tag becomes `ACCESSKIT_ERROR_OUT_OF_MEMORY`. The pusher explicitly maps
/// both error arms to that tag. `PropertyTagMismatch` is documented at
/// `src/schema/props/vectors.zig:65-70` as unreachable through valid
/// property-store paths.
export fn accesskit_node_push_flow_to(
    node: *handles.accesskit_node,
    item: NodeIdContent,
) callconv(.c) void {
    enter();
    const wanted = schema.nodeIdFromContent(item);
    props_ids.pushFlowTo(mutable_properties(node), wanted) catch |err| switch (err) {
        error.OutOfMemory => note_oom(),
        error.PropertyTagMismatch => note_oom(),
    };
}

/// Appends `item` to the node's `labelled_by`.
///
/// `include/zaccesskit.h:2534`. A push after the property was cleared starts a
/// new list holding only `item`, which is upstream's 0.25.0 fix
/// (`accesskit/src/lib.rs:1359-1365`).
///
/// **A void pusher that can fail.** On failure the list is unchanged and the
/// tag becomes `ACCESSKIT_ERROR_OUT_OF_MEMORY`. The pusher explicitly maps
/// both error arms to that tag. `PropertyTagMismatch` is documented at
/// `src/schema/props/vectors.zig:65-70` as unreachable through valid
/// property-store paths.
export fn accesskit_node_push_labelled_by(
    node: *handles.accesskit_node,
    item: NodeIdContent,
) callconv(.c) void {
    enter();
    const wanted = schema.nodeIdFromContent(item);
    props_ids.pushLabelledBy(mutable_properties(node), wanted) catch |err| switch (err) {
        error.OutOfMemory => note_oom(),
        error.PropertyTagMismatch => note_oom(),
    };
}

/// Appends `item` to the node's `owns`.
///
/// `include/zaccesskit.h:2572`. A push after the property was cleared starts a
/// new list holding only `item`, which is upstream's 0.25.0 fix
/// (`accesskit/src/lib.rs:1359-1365`).
///
/// **A void pusher that can fail.** On failure the list is unchanged and the
/// tag becomes `ACCESSKIT_ERROR_OUT_OF_MEMORY`. The pusher explicitly maps
/// both error arms to that tag. `PropertyTagMismatch` is documented at
/// `src/schema/props/vectors.zig:65-70` as unreachable through valid
/// property-store paths.
export fn accesskit_node_push_owned(
    node: *handles.accesskit_node,
    item: NodeIdContent,
) callconv(.c) void {
    enter();
    const wanted = schema.nodeIdFromContent(item);
    props_ids.pushOwned(mutable_properties(node), wanted) catch |err| switch (err) {
        error.OutOfMemory => note_oom(),
        error.PropertyTagMismatch => note_oom(),
    };
}

/// Appends `item` to the node's `radio_group`.
///
/// `include/zaccesskit.h:2611`. A push after the property was cleared starts a
/// new list holding only `item`, which is upstream's 0.25.0 fix
/// (`accesskit/src/lib.rs:1359-1365`).
///
/// **A void pusher that can fail.** On failure the list is unchanged and the
/// tag becomes `ACCESSKIT_ERROR_OUT_OF_MEMORY`. The pusher explicitly maps
/// both error arms to that tag. `PropertyTagMismatch` is documented at
/// `src/schema/props/vectors.zig:65-70` as unreachable through valid
/// property-store paths.
export fn accesskit_node_push_to_radio_group(
    node: *handles.accesskit_node,
    item: NodeIdContent,
) callconv(.c) void {
    enter();
    const wanted = schema.nodeIdFromContent(item);
    props_ids.pushToRadioGroup(mutable_properties(node), wanted) catch |err| switch (err) {
        error.OutOfMemory => note_oom(),
        error.PropertyTagMismatch => note_oom(),
    };
}

/// The `radio_group` property as a list of node identifiers.
///
/// `include/zaccesskit.h:2591`. An unset property gives `length == 0` with a
/// non-null `values`, so a caller that ignores the length reads an empty list
/// rather than a dangling pointer.
///
/// The result borrows the node's own storage, so the node must stay alive and
/// its list unmodified for as long as the caller reads it, and no function
/// releases it. This is a borrow, so the getter allocates nothing, cannot fail,
/// and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_radio_group(
    node: *const handles.accesskit_node,
) callconv(.c) marshal.CNodeIds {
    enter();
    return marshal.node_ids_to_c(props_ids.radioGroup(properties_of(node)));
}

/// Copies `length` identifiers from `values` into the node's `children`.
///
/// `include/zaccesskit.h:2331`. Nothing is retained and the caller keeps the
/// array. `values` may be null when `length` is 0 and must not be null
/// otherwise, so a null pointer with a non-zero length is a caller precondition
/// that `marshal.cArrayToSlice` asserts.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_children(
    node: *handles.accesskit_node,
    length: usize,
    values: [*c]const NodeId,
) callconv(.c) void {
    enter();
    const given = marshal.cArrayToSlice(NodeId, values, length);
    props_ids.setChildren(mutable_properties(node), given) catch note_oom();
}

/// Copies `length` identifiers from `values` into the node's `controls`.
///
/// `include/zaccesskit.h:2370`. Nothing is retained and the caller keeps the
/// array. `values` may be null when `length` is 0 and must not be null
/// otherwise, so a null pointer with a non-zero length is a caller precondition
/// that `marshal.cArrayToSlice` asserts.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_controls(
    node: *handles.accesskit_node,
    length: usize,
    values: [*c]const NodeId,
) callconv(.c) void {
    enter();
    const given = marshal.cArrayToSlice(NodeId, values, length);
    props_ids.setControls(mutable_properties(node), given) catch note_oom();
}

/// Copies `length` identifiers from `values` into the node's `described_by`.
///
/// `include/zaccesskit.h:2447`. Nothing is retained and the caller keeps the
/// array. `values` may be null when `length` is 0 and must not be null
/// otherwise, so a null pointer with a non-zero length is a caller precondition
/// that `marshal.cArrayToSlice` asserts.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_described_by(
    node: *handles.accesskit_node,
    length: usize,
    values: [*c]const NodeId,
) callconv(.c) void {
    enter();
    const given = marshal.cArrayToSlice(NodeId, values, length);
    props_ids.setDescribedBy(mutable_properties(node), given) catch note_oom();
}

/// Copies `length` identifiers from `values` into the node's `details`.
///
/// `include/zaccesskit.h:2409`. Nothing is retained and the caller keeps the
/// array. `values` may be null when `length` is 0 and must not be null
/// otherwise, so a null pointer with a non-zero length is a caller precondition
/// that `marshal.cArrayToSlice` asserts.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_details(
    node: *handles.accesskit_node,
    length: usize,
    values: [*c]const NodeId,
) callconv(.c) void {
    enter();
    const given = marshal.cArrayToSlice(NodeId, values, length);
    props_ids.setDetails(mutable_properties(node), given) catch note_oom();
}

/// Copies `length` identifiers from `values` into the node's `flow_to`.
///
/// `include/zaccesskit.h:2487`. Nothing is retained and the caller keeps the
/// array. `values` may be null when `length` is 0 and must not be null
/// otherwise, so a null pointer with a non-zero length is a caller precondition
/// that `marshal.cArrayToSlice` asserts.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_flow_to(
    node: *handles.accesskit_node,
    length: usize,
    values: [*c]const NodeId,
) callconv(.c) void {
    enter();
    const given = marshal.cArrayToSlice(NodeId, values, length);
    props_ids.setFlowTo(mutable_properties(node), given) catch note_oom();
}

/// Copies `length` identifiers from `values` into the node's `labelled_by`.
///
/// `include/zaccesskit.h:2525`. Nothing is retained and the caller keeps the
/// array. `values` may be null when `length` is 0 and must not be null
/// otherwise, so a null pointer with a non-zero length is a caller precondition
/// that `marshal.cArrayToSlice` asserts.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_labelled_by(
    node: *handles.accesskit_node,
    length: usize,
    values: [*c]const NodeId,
) callconv(.c) void {
    enter();
    const given = marshal.cArrayToSlice(NodeId, values, length);
    props_ids.setLabelledBy(mutable_properties(node), given) catch note_oom();
}

/// Copies `length` identifiers from `values` into the node's `owns`.
///
/// `include/zaccesskit.h:2564`. Nothing is retained and the caller keeps the
/// array. `values` may be null when `length` is 0 and must not be null
/// otherwise, so a null pointer with a non-zero length is a caller precondition
/// that `marshal.cArrayToSlice` asserts.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_owns(
    node: *handles.accesskit_node,
    length: usize,
    values: [*c]const NodeId,
) callconv(.c) void {
    enter();
    const given = marshal.cArrayToSlice(NodeId, values, length);
    props_ids.setOwns(mutable_properties(node), given) catch note_oom();
}

/// Copies `length` identifiers from `values` into the node's `radio_group`.
///
/// `include/zaccesskit.h:2602`. Nothing is retained and the caller keeps the
/// array. `values` may be null when `length` is 0 and must not be null
/// otherwise, so a null pointer with a non-zero length is a caller precondition
/// that `marshal.cArrayToSlice` asserts.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_radio_group(
    node: *handles.accesskit_node,
    length: usize,
    values: [*c]const NodeId,
) callconv(.c) void {
    enter();
    const given = marshal.cArrayToSlice(NodeId, values, length);
    props_ids.setRadioGroup(mutable_properties(node), given) catch note_oom();
}

// --- The single node identifiers and the tree identifier --------------------

/// The `active_descendant` property.
///
/// `include/zaccesskit.h:2629`. `has_value` is false when the property is
/// unset, and a copy of the result borrows nothing and needs no release. A set
/// property holding the zero identifier reads the same as no property at all
/// except for that flag byte, which is what `src/capi/optionals.zig` proves for
/// the form.
///
/// This is a borrow, so the getter allocates nothing, cannot fail, and leaves
/// the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_active_descendant(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptNodeId) {
    enter();
    return optionalReturn(
        marshal.COptNodeId,
        props_ids.activeDescendant(properties_of(node)),
    );
}

/// Clears the `active_descendant` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2646`. A property the store does not hold is already
/// absent, so a clear of one changes nothing. Returns nothing and cannot fail.
export fn accesskit_node_clear_active_descendant(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_ids.clearActiveDescendant(mutable_properties(node));
}

/// Clears the `error_message` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2672`. A property the store does not hold is already
/// absent, so a clear of one changes nothing. Returns nothing and cannot fail.
export fn accesskit_node_clear_error_message(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_ids.clearErrorMessage(mutable_properties(node));
}

/// Clears the `in_page_link_target` property, so the getter reports it as
/// unset.
///
/// `include/zaccesskit.h:2698`. A property the store does not hold is already
/// absent, so a clear of one changes nothing. Returns nothing and cannot fail.
export fn accesskit_node_clear_in_page_link_target(
    node: *handles.accesskit_node,
) callconv(.c) void {
    enter();
    props_ids.clearInPageLinkTarget(mutable_properties(node));
}

/// Clears the `member_of` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2724`. A property the store does not hold is already
/// absent, so a clear of one changes nothing. Returns nothing and cannot fail.
export fn accesskit_node_clear_member_of(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_ids.clearMemberOf(mutable_properties(node));
}

/// Clears the `next_on_line` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2750`. A property the store does not hold is already
/// absent, so a clear of one changes nothing. Returns nothing and cannot fail.
export fn accesskit_node_clear_next_on_line(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_ids.clearNextOnLine(mutable_properties(node));
}

/// Clears the `popup_for` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2802`. A property the store does not hold is already
/// absent, so a clear of one changes nothing. Returns nothing and cannot fail.
export fn accesskit_node_clear_popup_for(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_ids.clearPopupFor(mutable_properties(node));
}

/// Clears the `previous_on_line` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2776`. A property the store does not hold is already
/// absent, so a clear of one changes nothing. Returns nothing and cannot fail.
export fn accesskit_node_clear_previous_on_line(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_ids.clearPreviousOnLine(mutable_properties(node));
}

/// The `error_message` property.
///
/// `include/zaccesskit.h:2655`. `has_value` is false when the property is
/// unset, and a copy of the result borrows nothing and needs no release. A set
/// property holding the zero identifier reads the same as no property at all
/// except for that flag byte, which is what `src/capi/optionals.zig` proves for
/// the form.
///
/// This is a borrow, so the getter allocates nothing, cannot fail, and leaves
/// the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_error_message(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptNodeId) {
    enter();
    return optionalReturn(
        marshal.COptNodeId,
        props_ids.errorMessage(properties_of(node)),
    );
}

/// The `in_page_link_target` property.
///
/// `include/zaccesskit.h:2681`. `has_value` is false when the property is
/// unset, and a copy of the result borrows nothing and needs no release. A set
/// property holding the zero identifier reads the same as no property at all
/// except for that flag byte, which is what `src/capi/optionals.zig` proves for
/// the form.
///
/// This is a borrow, so the getter allocates nothing, cannot fail, and leaves
/// the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_in_page_link_target(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptNodeId) {
    enter();
    return optionalReturn(
        marshal.COptNodeId,
        props_ids.inPageLinkTarget(properties_of(node)),
    );
}

/// The `member_of` property.
///
/// `include/zaccesskit.h:2707`. `has_value` is false when the property is
/// unset, and a copy of the result borrows nothing and needs no release. A set
/// property holding the zero identifier reads the same as no property at all
/// except for that flag byte, which is what `src/capi/optionals.zig` proves for
/// the form.
///
/// This is a borrow, so the getter allocates nothing, cannot fail, and leaves
/// the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_member_of(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptNodeId) {
    enter();
    return optionalReturn(
        marshal.COptNodeId,
        props_ids.memberOf(properties_of(node)),
    );
}

/// The `next_on_line` property.
///
/// `include/zaccesskit.h:2733`. `has_value` is false when the property is
/// unset, and a copy of the result borrows nothing and needs no release. A set
/// property holding the zero identifier reads the same as no property at all
/// except for that flag byte, which is what `src/capi/optionals.zig` proves for
/// the form.
///
/// This is a borrow, so the getter allocates nothing, cannot fail, and leaves
/// the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_next_on_line(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptNodeId) {
    enter();
    return optionalReturn(
        marshal.COptNodeId,
        props_ids.nextOnLine(properties_of(node)),
    );
}

/// The `popup_for` property.
///
/// `include/zaccesskit.h:2785`. `has_value` is false when the property is
/// unset, and a copy of the result borrows nothing and needs no release. A set
/// property holding the zero identifier reads the same as no property at all
/// except for that flag byte, which is what `src/capi/optionals.zig` proves for
/// the form.
///
/// This is a borrow, so the getter allocates nothing, cannot fail, and leaves
/// the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_popup_for(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptNodeId) {
    enter();
    return optionalReturn(
        marshal.COptNodeId,
        props_ids.popupFor(properties_of(node)),
    );
}

/// The `previous_on_line` property.
///
/// `include/zaccesskit.h:2759`. `has_value` is false when the property is
/// unset, and a copy of the result borrows nothing and needs no release. A set
/// property holding the zero identifier reads the same as no property at all
/// except for that flag byte, which is what `src/capi/optionals.zig` proves for
/// the form.
///
/// This is a borrow, so the getter allocates nothing, cannot fail, and leaves
/// the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_previous_on_line(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptNodeId) {
    enter();
    return optionalReturn(
        marshal.COptNodeId,
        props_ids.previousOnLine(properties_of(node)),
    );
}

/// Sets the `active_descendant` property to `value`.
///
/// `include/zaccesskit.h:2637`. Nothing is retained and nothing is borrowed.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_active_descendant(
    node: *handles.accesskit_node,
    value: NodeIdContent,
) callconv(.c) void {
    enter();
    const wanted = schema.nodeIdFromContent(value);
    props_ids.setActiveDescendant(mutable_properties(node), wanted) catch note_oom();
}

/// Sets the `error_message` property to `value`.
///
/// `include/zaccesskit.h:2663`. Nothing is retained and nothing is borrowed.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_error_message(
    node: *handles.accesskit_node,
    value: NodeIdContent,
) callconv(.c) void {
    enter();
    const wanted = schema.nodeIdFromContent(value);
    props_ids.setErrorMessage(mutable_properties(node), wanted) catch note_oom();
}

/// Sets the `in_page_link_target` property to `value`.
///
/// `include/zaccesskit.h:2689`. Nothing is retained and nothing is borrowed.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_in_page_link_target(
    node: *handles.accesskit_node,
    value: NodeIdContent,
) callconv(.c) void {
    enter();
    const wanted = schema.nodeIdFromContent(value);
    props_ids.setInPageLinkTarget(mutable_properties(node), wanted) catch note_oom();
}

/// Sets the `member_of` property to `value`.
///
/// `include/zaccesskit.h:2715`. Nothing is retained and nothing is borrowed.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_member_of(
    node: *handles.accesskit_node,
    value: NodeIdContent,
) callconv(.c) void {
    enter();
    const wanted = schema.nodeIdFromContent(value);
    props_ids.setMemberOf(mutable_properties(node), wanted) catch note_oom();
}

/// Sets the `next_on_line` property to `value`.
///
/// `include/zaccesskit.h:2741`. Nothing is retained and nothing is borrowed.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_next_on_line(
    node: *handles.accesskit_node,
    value: NodeIdContent,
) callconv(.c) void {
    enter();
    const wanted = schema.nodeIdFromContent(value);
    props_ids.setNextOnLine(mutable_properties(node), wanted) catch note_oom();
}

/// Sets the `popup_for` property to `value`.
///
/// `include/zaccesskit.h:2793`. Nothing is retained and nothing is borrowed.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_popup_for(
    node: *handles.accesskit_node,
    value: NodeIdContent,
) callconv(.c) void {
    enter();
    const wanted = schema.nodeIdFromContent(value);
    props_ids.setPopupFor(mutable_properties(node), wanted) catch note_oom();
}

/// Sets the `previous_on_line` property to `value`.
///
/// `include/zaccesskit.h:2767`. Nothing is retained and nothing is borrowed.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_previous_on_line(
    node: *handles.accesskit_node,
    value: NodeIdContent,
) callconv(.c) void {
    enter();
    const wanted = schema.nodeIdFromContent(value);
    props_ids.setPreviousOnLine(mutable_properties(node), wanted) catch note_oom();
}

/// Clears the `tree_id` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2827`. Clearing it removes the grafted subtree unless
/// a new graft node arrives in the same update. Returns nothing and cannot
/// fail.
export fn accesskit_node_clear_tree_id(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_option.clearTreeId(mutable_properties(node));
}

/// Sets the `tree_id` property to `value`.
///
/// `include/zaccesskit.h:2819`. Nothing is retained and nothing is borrowed.
/// The consumer rejects the nil identifier as a graft target, so the check
/// belongs to the consumer and not here.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_tree_id(
    node: *handles.accesskit_node,
    value: TargetArg(TreeId),
) callconv(.c) void {
    enter();
    props_option.setTreeId(mutable_properties(node), decodeArg(TreeId, value)) catch note_oom();
}

/// The `tree_id` property.
///
/// `include/zaccesskit.h:2811`. `has_value` is false when the property is
/// unset. The nil identifier is a value a caller may store, so a set property
/// carrying the nil id and no property at all are two states and the flag is
/// what separates them.
///
/// This is a copy of sixteen bytes, so it stays valid after a later write. The
/// getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_tree_id(
    node: *const handles.accesskit_node,
) callconv(.c) marshal.COptTreeId {
    enter();
    return marshal.opt_tree_id_to_c(props_option.treeId(properties_of(node)));
}

// --- The strings --------------------------------------------------------------

/// A copy of the `access_key` property, or null when the property is unset.
///
/// `include/zaccesskit.h:2969`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_access_key(node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.accessKey(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// A copy of the `author_id` property, or null when the property is unset.
///
/// `include/zaccesskit.h:3011`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_author_id(node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.authorId(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// A copy of the `braille_label` property, or null when the property is unset.
///
/// `include/zaccesskit.h:3637`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_braille_label(node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.brailleLabel(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// A copy of the `braille_role_description` property, or null when the property
/// is unset.
///
/// `include/zaccesskit.h:3680`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_braille_role_description(
    node: *const handles.accesskit_node,
) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.brailleRoleDescription(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// A copy of the `class_name` property, or null when the property is unset.
///
/// `include/zaccesskit.h:3053`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_class_name(node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.className(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// Clears the `access_key` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2999`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_access_key(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearAccessKey(mutable_properties(node));
}

/// Clears the `author_id` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3041`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_author_id(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearAuthorId(mutable_properties(node));
}

/// Clears the `braille_label` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3667`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_braille_label(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearBrailleLabel(mutable_properties(node));
}

/// Clears the `braille_role_description` property, so the getter reports it as
/// unset.
///
/// `include/zaccesskit.h:3714`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_braille_role_description(
    node: *handles.accesskit_node,
) callconv(.c) void {
    enter();
    props_strings.clearBrailleRoleDescription(mutable_properties(node));
}

/// Clears the `class_name` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3083`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_class_name(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearClassName(mutable_properties(node));
}

/// Clears the `column_index_text` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3625`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_column_index_text(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearColumnIndexText(mutable_properties(node));
}

/// Clears the `description` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2918`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_description(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearDescription(mutable_properties(node));
}

/// Clears the `font_family` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3125`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_font_family(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearFontFamily(mutable_properties(node));
}

/// Clears the `html_id` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3165`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_html_id(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearHtmlId(mutable_properties(node));
}

/// Clears the `html_tag` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3207`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_html_tag(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearHtmlTag(mutable_properties(node));
}

/// Clears the `inner_html` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3249`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_inner_html(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearInnerHtml(mutable_properties(node));
}

/// Clears the `keyboard_shortcut` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3292`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_keyboard_shortcut(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearKeyboardShortcut(mutable_properties(node));
}

/// Clears the `label` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2876`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_label(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearLabel(mutable_properties(node));
}

/// Clears the `language` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3334`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_language(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearLanguage(mutable_properties(node));
}

/// Clears the `placeholder` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3376`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_placeholder(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearPlaceholder(mutable_properties(node));
}

/// Clears the `role_description` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3419`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_role_description(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearRoleDescription(mutable_properties(node));
}

/// Clears the `row_index_text` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3582`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_row_index_text(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearRowIndexText(mutable_properties(node));
}

/// Clears the `state_description` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3462`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_state_description(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearStateDescription(mutable_properties(node));
}

/// Clears the `tooltip` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3502`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_tooltip(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearTooltip(mutable_properties(node));
}

/// Clears the `url` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3540`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_url(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearUrl(mutable_properties(node));
}

/// Clears the `value` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:2957`. The library's copy of the bytes goes with it.
/// Returns nothing and cannot fail.
export fn accesskit_node_clear_value(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_strings.clearValue(mutable_properties(node));
}

/// A copy of the `column_index_text` property, or null when the property is
/// unset.
///
/// `include/zaccesskit.h:3594`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_column_index_text(
    node: *const handles.accesskit_node,
) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.columnIndexText(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// A copy of the `description` property, or null when the property is unset.
///
/// `include/zaccesskit.h:2888`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_description(node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.description(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// A copy of the `font_family` property, or null when the property is unset.
///
/// `include/zaccesskit.h:3095`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_font_family(node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.fontFamily(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// A copy of the `html_id` property, or null when the property is unset.
///
/// `include/zaccesskit.h:3137`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_html_id(node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.htmlId(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// A copy of the `html_tag` property, or null when the property is unset.
///
/// `include/zaccesskit.h:3177`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_html_tag(node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.htmlTag(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// A copy of the `inner_html` property, or null when the property is unset.
///
/// `include/zaccesskit.h:3219`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_inner_html(node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.innerHtml(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// A copy of the `keyboard_shortcut` property, or null when the property is
/// unset.
///
/// `include/zaccesskit.h:3261`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_keyboard_shortcut(
    node: *const handles.accesskit_node,
) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.keyboardShortcut(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// A copy of the `label` property, or null when the property is unset.
///
/// `include/zaccesskit.h:2849`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_label(node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.label(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// A copy of the `language` property, or null when the property is unset.
///
/// `include/zaccesskit.h:3304`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_language(node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.language(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// A copy of the `placeholder` property, or null when the property is unset.
///
/// `include/zaccesskit.h:3346`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_placeholder(node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.placeholder(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// A copy of the `role_description` property, or null when the property is
/// unset.
///
/// `include/zaccesskit.h:3388`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_role_description(
    node: *const handles.accesskit_node,
) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.roleDescription(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// A copy of the `row_index_text` property, or null when the property is unset.
///
/// `include/zaccesskit.h:3552`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_row_index_text(node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.rowIndexText(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// Copies the NUL-terminated `value` into the node's `access_key`.
///
/// `include/zaccesskit.h:2977`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_access_key(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setAccessKey(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `access_key`. `value`
/// need not be NUL-terminated.
///
/// `include/zaccesskit.h:2989`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_access_key_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setAccessKey(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `author_id`.
///
/// `include/zaccesskit.h:3019`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_author_id(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setAuthorId(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `author_id`. `value` need
/// not be NUL-terminated.
///
/// `include/zaccesskit.h:3031`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_author_id_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setAuthorId(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `braille_label`.
///
/// `include/zaccesskit.h:3645`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_braille_label(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setBrailleLabel(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `braille_label`. `value`
/// need not be NUL-terminated.
///
/// `include/zaccesskit.h:3657`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_braille_label_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setBrailleLabel(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's
/// `braille_role_description`.
///
/// `include/zaccesskit.h:3689`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_braille_role_description(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setBrailleRoleDescription(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's
/// `braille_role_description`. `value` need not be NUL-terminated.
///
/// `include/zaccesskit.h:3702`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_braille_role_description_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setBrailleRoleDescription(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `class_name`.
///
/// `include/zaccesskit.h:3061`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_class_name(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setClassName(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `class_name`. `value`
/// need not be NUL-terminated.
///
/// `include/zaccesskit.h:3073`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_class_name_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setClassName(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `column_index_text`.
///
/// `include/zaccesskit.h:3603`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_column_index_text(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setColumnIndexText(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `column_index_text`.
/// `value` need not be NUL-terminated.
///
/// `include/zaccesskit.h:3616`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_column_index_text_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setColumnIndexText(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `description`.
///
/// `include/zaccesskit.h:2896`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_description(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setDescription(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `description`. `value`
/// need not be NUL-terminated.
///
/// `include/zaccesskit.h:2908`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_description_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setDescription(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `font_family`.
///
/// `include/zaccesskit.h:3103`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_font_family(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setFontFamily(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `font_family`. `value`
/// need not be NUL-terminated.
///
/// `include/zaccesskit.h:3115`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_font_family_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setFontFamily(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `html_id`.
///
/// `include/zaccesskit.h:3145`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_html_id(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setHtmlId(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `html_id`. `value` need
/// not be NUL-terminated.
///
/// `include/zaccesskit.h:3157`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_html_id_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setHtmlId(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `html_tag`.
///
/// `include/zaccesskit.h:3185`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_html_tag(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setHtmlTag(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `html_tag`. `value` need
/// not be NUL-terminated.
///
/// `include/zaccesskit.h:3197`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_html_tag_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setHtmlTag(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `inner_html`.
///
/// `include/zaccesskit.h:3227`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_inner_html(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setInnerHtml(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `inner_html`. `value`
/// need not be NUL-terminated.
///
/// `include/zaccesskit.h:3239`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_inner_html_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setInnerHtml(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `keyboard_shortcut`.
///
/// `include/zaccesskit.h:3270`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_keyboard_shortcut(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setKeyboardShortcut(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `keyboard_shortcut`.
/// `value` need not be NUL-terminated.
///
/// `include/zaccesskit.h:3283`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_keyboard_shortcut_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setKeyboardShortcut(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `label`.
///
/// `include/zaccesskit.h:2857`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_label(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setLabel(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `label`. `value` need not
/// be NUL-terminated.
///
/// `include/zaccesskit.h:2868`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_label_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setLabel(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `language`.
///
/// `include/zaccesskit.h:3312`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_language(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setLanguage(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `language`. `value` need
/// not be NUL-terminated.
///
/// `include/zaccesskit.h:3324`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_language_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setLanguage(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `placeholder`.
///
/// `include/zaccesskit.h:3354`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_placeholder(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setPlaceholder(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `placeholder`. `value`
/// need not be NUL-terminated.
///
/// `include/zaccesskit.h:3366`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_placeholder_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setPlaceholder(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `role_description`.
///
/// `include/zaccesskit.h:3397`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_role_description(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setRoleDescription(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `role_description`.
/// `value` need not be NUL-terminated.
///
/// `include/zaccesskit.h:3410`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_role_description_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setRoleDescription(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `row_index_text`.
///
/// `include/zaccesskit.h:3560`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_row_index_text(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setRowIndexText(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `row_index_text`. `value`
/// need not be NUL-terminated.
///
/// `include/zaccesskit.h:3573`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_row_index_text_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setRowIndexText(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `state_description`.
///
/// `include/zaccesskit.h:3440`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_state_description(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setStateDescription(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `state_description`.
/// `value` need not be NUL-terminated.
///
/// `include/zaccesskit.h:3453`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_state_description_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setStateDescription(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `tooltip`.
///
/// `include/zaccesskit.h:3482`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_tooltip(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setTooltip(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `tooltip`. `value` need
/// not be NUL-terminated.
///
/// `include/zaccesskit.h:3494`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_tooltip_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setTooltip(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `url`.
///
/// `include/zaccesskit.h:3521`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_url(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setUrl(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `url`. `value` need not
/// be NUL-terminated.
///
/// `include/zaccesskit.h:3532`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_url_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setUrl(mutable_properties(node), stored) catch note_oom();
}

/// Copies the NUL-terminated `value` into the node's `value`.
///
/// `include/zaccesskit.h:2938`. Nothing is retained, so the caller keeps the
/// buffer and may release it as soon as this returns. The bytes are copied
/// verbatim and are not decoded: the header declares no encoding step, and
/// upstream's lossy decode at `accesskit-c/src/common.rs:216-224` would replace
/// invalid UTF-8 with U+FFFD, which is not what "copies" means here.
///
/// A `[*:0]` parameter has no interior zero byte, so this declaration never has
/// bytes to drop.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_value(
    node: *handles.accesskit_node,
    value: [*:0]const u8,
) callconv(.c) void {
    enter();
    const stored = marshal.c_string_to_slice(value);
    props_strings.setValue(mutable_properties(node), stored) catch note_oom();
}

/// Copies `length` bytes from `value` into the node's `value`. `value` need not
/// be NUL-terminated.
///
/// `include/zaccesskit.h:2949`. Nothing is retained and the caller keeps the
/// buffer. The bytes are stored up to the first NUL byte inside those `length`
/// bytes, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail. That is the header's own rule and it is also what
/// makes `accesskit_string_free` sound: the release finds the length with
/// `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
/// wrong length.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_value_with_length(
    node: *handles.accesskit_node,
    value: [*c]const u8,
    length: usize,
) callconv(.c) void {
    enter();
    const stored = marshal.c_bytes_to_slice(value, length);
    props_strings.setValue(mutable_properties(node), stored) catch note_oom();
}

/// A copy of the `state_description` property, or null when the property is
/// unset.
///
/// `include/zaccesskit.h:3431`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_state_description(
    node: *const handles.accesskit_node,
) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.stateDescription(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// A copy of the `tooltip` property, or null when the property is unset.
///
/// `include/zaccesskit.h:3474`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_tooltip(node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.tooltip(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// A copy of the `url` property, or null when the property is unset.
///
/// `include/zaccesskit.h:3513`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_url(node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.url(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

/// A copy of the `value` property, or null when the property is unset.
///
/// `include/zaccesskit.h:2930`. Release the result with
/// `accesskit_string_free`, once, and never with `free`, and never release a
/// string this library did not return. A null return covers two cases, an unset
/// property and a copy that did not fit in memory, and `accesskit_last_error`
/// tells them apart: the tag is `.none` for the first and `.out_of_memory` for
/// the second. Nothing survives the second.
///
/// A property holding an empty string comes back as a pointer to one zero byte,
/// which is not the null an unset property gives. The two are the states
/// upstream keeps apart by storing `Some("")` for an empty value
/// (`accesskit-c/src/lib.rs:217-218`).
export fn accesskit_node_value(node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 {
    enter();
    const stored = props_strings.value(properties_of(node)) orelse return null;
    return marshal.dup_c_string(allocation.allocator(), stored) catch {
        note_oom();
        return null;
    };
}

// --- The numbers -------------------------------------------------------------

/// Clears the `column_count` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4099`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_column_count(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearColumnCount(mutable_properties(node));
}

/// Clears the `column_index` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4150`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_column_index(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearColumnIndex(mutable_properties(node));
}

/// Clears the `column_span` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4201`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_column_span(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearColumnSpan(mutable_properties(node));
}

/// Clears the `font_size` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4023`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_font_size(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearFontSize(mutable_properties(node));
}

/// Clears the `font_weight` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4048`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_font_weight(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearFontWeight(mutable_properties(node));
}

/// Clears the `level` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4225`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_level(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearLevel(mutable_properties(node));
}

/// Clears the `max_numeric_value` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3946`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_max_numeric_value(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearMaxNumericValue(mutable_properties(node));
}

/// Clears the `min_numeric_value` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3920`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_min_numeric_value(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearMinNumericValue(mutable_properties(node));
}

/// Clears the `numeric_value` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3894`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_numeric_value(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearNumericValue(mutable_properties(node));
}

/// Clears the `numeric_value_jump` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3998`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_numeric_value_jump(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearNumericValueJump(mutable_properties(node));
}

/// Clears the `numeric_value_step` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3972`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_numeric_value_step(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearNumericValueStep(mutable_properties(node));
}

/// Clears the `position_in_set` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4277`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_position_in_set(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearPositionInSet(mutable_properties(node));
}

/// Clears the `row_count` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4073`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_row_count(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearRowCount(mutable_properties(node));
}

/// Clears the `row_index` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4124`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_row_index(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearRowIndex(mutable_properties(node));
}

/// Clears the `row_span` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4175`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_row_span(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearRowSpan(mutable_properties(node));
}

/// Clears the `scroll_x` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3739`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_scroll_x(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearScrollX(mutable_properties(node));
}

/// Clears the `scroll_x_max` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3791`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_scroll_x_max(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearScrollXMax(mutable_properties(node));
}

/// Clears the `scroll_x_min` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3765`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_scroll_x_min(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearScrollXMin(mutable_properties(node));
}

/// Clears the `scroll_y` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3816`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_scroll_y(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearScrollY(mutable_properties(node));
}

/// Clears the `scroll_y_max` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3868`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_scroll_y_max(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearScrollYMax(mutable_properties(node));
}

/// Clears the `scroll_y_min` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:3842`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_scroll_y_min(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearScrollYMin(mutable_properties(node));
}

/// Clears the `size_of_set` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4251`. A property the store does not hold is already
/// absent. Returns nothing and cannot fail.
export fn accesskit_node_clear_size_of_set(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_numbers.clearSizeOfSet(mutable_properties(node));
}

/// The `column_count` property.
///
/// `include/zaccesskit.h:4082`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding zero is a real state the tree uses, so the flag byte is
/// what tells it from an absence. A zero row index means the first row; no
/// sentinel stands for "unset", because absence is a state this store reaches.
///
/// The value is a `size_t`, a count and never an index into anything this
/// library owns. The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_column_count(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptIndex) {
    enter();
    return optionalReturn(
        marshal.COptIndex,
        props_numbers.columnCount(properties_of(node)),
    );
}

/// The `column_index` property.
///
/// `include/zaccesskit.h:4133`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding zero is a real state the tree uses, so the flag byte is
/// what tells it from an absence. A zero row index means the first row; no
/// sentinel stands for "unset", because absence is a state this store reaches.
///
/// The value is a `size_t`, a count and never an index into anything this
/// library owns. The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_column_index(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptIndex) {
    enter();
    return optionalReturn(
        marshal.COptIndex,
        props_numbers.columnIndex(properties_of(node)),
    );
}

/// The `column_span` property.
///
/// `include/zaccesskit.h:4184`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding zero is a real state the tree uses, so the flag byte is
/// what tells it from an absence. A zero row index means the first row; no
/// sentinel stands for "unset", because absence is a state this store reaches.
///
/// The value is a `size_t`, a count and never an index into anything this
/// library owns. The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_column_span(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptIndex) {
    enter();
    return optionalReturn(
        marshal.COptIndex,
        props_numbers.columnSpan(properties_of(node)),
    );
}

/// The `font_size` property.
///
/// `include/zaccesskit.h:4007`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding a zero `float` is a state a reader must be able to tell
/// from an absence; the flag byte is what tells it.
///
/// The value is a `float`, in points for a font size and in the same scale for
/// a font weight. The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_font_size(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptFloat) {
    enter();
    return optionalReturn(
        marshal.COptFloat,
        props_numbers.fontSize(properties_of(node)),
    );
}

/// The `font_weight` property.
///
/// `include/zaccesskit.h:4032`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding a zero `float` is a state a reader must be able to tell
/// from an absence; the flag byte is what tells it.
///
/// The value is a `float`, in points for a font size and in the same scale for
/// a font weight. The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_font_weight(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptFloat) {
    enter();
    return optionalReturn(
        marshal.COptFloat,
        props_numbers.fontWeight(properties_of(node)),
    );
}

/// The `level` property.
///
/// `include/zaccesskit.h:4210`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding zero is a real state the tree uses, so the flag byte is
/// what tells it from an absence. A zero row index means the first row; no
/// sentinel stands for "unset", because absence is a state this store reaches.
///
/// The value is a `size_t`, a count and never an index into anything this
/// library owns. The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_level(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptIndex) {
    enter();
    return optionalReturn(
        marshal.COptIndex,
        props_numbers.level(properties_of(node)),
    );
}

/// The `max_numeric_value` property.
///
/// `include/zaccesskit.h:3929`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding a zero `double` is a state a reader must be able to tell
/// from an absence; the flag byte is what tells it.
///
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range. The getter allocates
/// nothing, cannot fail, and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_max_numeric_value(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptDouble) {
    enter();
    return optionalReturn(
        marshal.COptDouble,
        props_numbers.maxNumericValue(properties_of(node)),
    );
}

/// The `min_numeric_value` property.
///
/// `include/zaccesskit.h:3903`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding a zero `double` is a state a reader must be able to tell
/// from an absence; the flag byte is what tells it.
///
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range. The getter allocates
/// nothing, cannot fail, and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_min_numeric_value(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptDouble) {
    enter();
    return optionalReturn(
        marshal.COptDouble,
        props_numbers.minNumericValue(properties_of(node)),
    );
}

/// The `numeric_value` property.
///
/// `include/zaccesskit.h:3877`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding a zero `double` is a state a reader must be able to tell
/// from an absence; the flag byte is what tells it.
///
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range. The getter allocates
/// nothing, cannot fail, and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_numeric_value(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptDouble) {
    enter();
    return optionalReturn(
        marshal.COptDouble,
        props_numbers.numericValue(properties_of(node)),
    );
}

/// The `numeric_value_jump` property.
///
/// `include/zaccesskit.h:3981`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding a zero `double` is a state a reader must be able to tell
/// from an absence; the flag byte is what tells it.
///
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range. The getter allocates
/// nothing, cannot fail, and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_numeric_value_jump(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptDouble) {
    enter();
    return optionalReturn(
        marshal.COptDouble,
        props_numbers.numericValueJump(properties_of(node)),
    );
}

/// The `numeric_value_step` property.
///
/// `include/zaccesskit.h:3955`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding a zero `double` is a state a reader must be able to tell
/// from an absence; the flag byte is what tells it.
///
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range. The getter allocates
/// nothing, cannot fail, and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_numeric_value_step(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptDouble) {
    enter();
    return optionalReturn(
        marshal.COptDouble,
        props_numbers.numericValueStep(properties_of(node)),
    );
}

/// The `position_in_set` property.
///
/// `include/zaccesskit.h:4260`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding zero is a real state the tree uses, so the flag byte is
/// what tells it from an absence. A zero row index means the first row; no
/// sentinel stands for "unset", because absence is a state this store reaches.
///
/// The value is a `size_t`, a count and never an index into anything this
/// library owns. The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_position_in_set(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptIndex) {
    enter();
    return optionalReturn(
        marshal.COptIndex,
        props_numbers.positionInSet(properties_of(node)),
    );
}

/// The `row_count` property.
///
/// `include/zaccesskit.h:4057`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding zero is a real state the tree uses, so the flag byte is
/// what tells it from an absence. A zero row index means the first row; no
/// sentinel stands for "unset", because absence is a state this store reaches.
///
/// The value is a `size_t`, a count and never an index into anything this
/// library owns. The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_row_count(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptIndex) {
    enter();
    return optionalReturn(
        marshal.COptIndex,
        props_numbers.rowCount(properties_of(node)),
    );
}

/// The `row_index` property.
///
/// `include/zaccesskit.h:4108`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding zero is a real state the tree uses, so the flag byte is
/// what tells it from an absence. A zero row index means the first row; no
/// sentinel stands for "unset", because absence is a state this store reaches.
///
/// The value is a `size_t`, a count and never an index into anything this
/// library owns. The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_row_index(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptIndex) {
    enter();
    return optionalReturn(
        marshal.COptIndex,
        props_numbers.rowIndex(properties_of(node)),
    );
}

/// The `row_span` property.
///
/// `include/zaccesskit.h:4159`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding zero is a real state the tree uses, so the flag byte is
/// what tells it from an absence. A zero row index means the first row; no
/// sentinel stands for "unset", because absence is a state this store reaches.
///
/// The value is a `size_t`, a count and never an index into anything this
/// library owns. The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_row_span(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptIndex) {
    enter();
    return optionalReturn(
        marshal.COptIndex,
        props_numbers.rowSpan(properties_of(node)),
    );
}

/// The `scroll_x` property.
///
/// `include/zaccesskit.h:3723`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding a zero `double` is a state a reader must be able to tell
/// from an absence; the flag byte is what tells it.
///
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range. The getter allocates
/// nothing, cannot fail, and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_scroll_x(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptDouble) {
    enter();
    return optionalReturn(
        marshal.COptDouble,
        props_numbers.scrollX(properties_of(node)),
    );
}

/// The `scroll_x_max` property.
///
/// `include/zaccesskit.h:3774`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding a zero `double` is a state a reader must be able to tell
/// from an absence; the flag byte is what tells it.
///
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range. The getter allocates
/// nothing, cannot fail, and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_scroll_x_max(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptDouble) {
    enter();
    return optionalReturn(
        marshal.COptDouble,
        props_numbers.scrollXMax(properties_of(node)),
    );
}

/// The `scroll_x_min` property.
///
/// `include/zaccesskit.h:3748`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding a zero `double` is a state a reader must be able to tell
/// from an absence; the flag byte is what tells it.
///
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range. The getter allocates
/// nothing, cannot fail, and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_scroll_x_min(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptDouble) {
    enter();
    return optionalReturn(
        marshal.COptDouble,
        props_numbers.scrollXMin(properties_of(node)),
    );
}

/// The `scroll_y` property.
///
/// `include/zaccesskit.h:3800`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding a zero `double` is a state a reader must be able to tell
/// from an absence; the flag byte is what tells it.
///
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range. The getter allocates
/// nothing, cannot fail, and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_scroll_y(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptDouble) {
    enter();
    return optionalReturn(
        marshal.COptDouble,
        props_numbers.scrollY(properties_of(node)),
    );
}

/// The `scroll_y_max` property.
///
/// `include/zaccesskit.h:3851`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding a zero `double` is a state a reader must be able to tell
/// from an absence; the flag byte is what tells it.
///
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range. The getter allocates
/// nothing, cannot fail, and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_scroll_y_max(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptDouble) {
    enter();
    return optionalReturn(
        marshal.COptDouble,
        props_numbers.scrollYMax(properties_of(node)),
    );
}

/// The `scroll_y_min` property.
///
/// `include/zaccesskit.h:3825`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding a zero `double` is a state a reader must be able to tell
/// from an absence; the flag byte is what tells it.
///
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range. The getter allocates
/// nothing, cannot fail, and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_scroll_y_min(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptDouble) {
    enter();
    return optionalReturn(
        marshal.COptDouble,
        props_numbers.scrollYMin(properties_of(node)),
    );
}

/// Sets the `column_count` property to `value`.
///
/// `include/zaccesskit.h:4090`. Nothing is retained and nothing is borrowed.
/// The value is a `size_t`, a count and never an index into anything this
/// library owns, and no value of it is rejected: a negative scroll offset and a
/// font size of zero are both values a caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_column_count(
    node: *handles.accesskit_node,
    value: usize,
) callconv(.c) void {
    enter();
    props_numbers.setColumnCount(mutable_properties(node), value) catch note_oom();
}

/// Sets the `column_index` property to `value`.
///
/// `include/zaccesskit.h:4141`. Nothing is retained and nothing is borrowed.
/// The value is a `size_t`, a count and never an index into anything this
/// library owns, and no value of it is rejected: a negative scroll offset and a
/// font size of zero are both values a caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_column_index(
    node: *handles.accesskit_node,
    value: usize,
) callconv(.c) void {
    enter();
    props_numbers.setColumnIndex(mutable_properties(node), value) catch note_oom();
}

/// Sets the `column_span` property to `value`.
///
/// `include/zaccesskit.h:4192`. Nothing is retained and nothing is borrowed.
/// The value is a `size_t`, a count and never an index into anything this
/// library owns, and no value of it is rejected: a negative scroll offset and a
/// font size of zero are both values a caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_column_span(
    node: *handles.accesskit_node,
    value: usize,
) callconv(.c) void {
    enter();
    props_numbers.setColumnSpan(mutable_properties(node), value) catch note_oom();
}

/// Sets the `font_size` property to `value`.
///
/// `include/zaccesskit.h:4015`. Nothing is retained and nothing is borrowed.
/// The value is a `float`, in points for a font size and in the same scale for
/// a font weight, and no value of it is rejected: a negative scroll offset and
/// a font size of zero are both values a caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_font_size(
    node: *handles.accesskit_node,
    value: f32,
) callconv(.c) void {
    enter();
    props_numbers.setFontSize(mutable_properties(node), value) catch note_oom();
}

/// Sets the `font_weight` property to `value`.
///
/// `include/zaccesskit.h:4040`. Nothing is retained and nothing is borrowed.
/// The value is a `float`, in points for a font size and in the same scale for
/// a font weight, and no value of it is rejected: a negative scroll offset and
/// a font size of zero are both values a caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_font_weight(
    node: *handles.accesskit_node,
    value: f32,
) callconv(.c) void {
    enter();
    props_numbers.setFontWeight(mutable_properties(node), value) catch note_oom();
}

/// Sets the `level` property to `value`.
///
/// `include/zaccesskit.h:4218`. Nothing is retained and nothing is borrowed.
/// The value is a `size_t`, a count and never an index into anything this
/// library owns, and no value of it is rejected: a negative scroll offset and a
/// font size of zero are both values a caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_level(
    node: *handles.accesskit_node,
    value: usize,
) callconv(.c) void {
    enter();
    props_numbers.setLevel(mutable_properties(node), value) catch note_oom();
}

/// Sets the `max_numeric_value` property to `value`.
///
/// `include/zaccesskit.h:3937`. Nothing is retained and nothing is borrowed.
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range, and no value of it is
/// rejected: a negative scroll offset and a font size of zero are both values a
/// caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_max_numeric_value(
    node: *handles.accesskit_node,
    value: f64,
) callconv(.c) void {
    enter();
    props_numbers.setMaxNumericValue(mutable_properties(node), value) catch note_oom();
}

/// Sets the `min_numeric_value` property to `value`.
///
/// `include/zaccesskit.h:3911`. Nothing is retained and nothing is borrowed.
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range, and no value of it is
/// rejected: a negative scroll offset and a font size of zero are both values a
/// caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_min_numeric_value(
    node: *handles.accesskit_node,
    value: f64,
) callconv(.c) void {
    enter();
    props_numbers.setMinNumericValue(mutable_properties(node), value) catch note_oom();
}

/// Sets the `numeric_value` property to `value`.
///
/// `include/zaccesskit.h:3885`. Nothing is retained and nothing is borrowed.
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range, and no value of it is
/// rejected: a negative scroll offset and a font size of zero are both values a
/// caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_numeric_value(
    node: *handles.accesskit_node,
    value: f64,
) callconv(.c) void {
    enter();
    props_numbers.setNumericValue(mutable_properties(node), value) catch note_oom();
}

/// Sets the `numeric_value_jump` property to `value`.
///
/// `include/zaccesskit.h:3989`. Nothing is retained and nothing is borrowed.
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range, and no value of it is
/// rejected: a negative scroll offset and a font size of zero are both values a
/// caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_numeric_value_jump(
    node: *handles.accesskit_node,
    value: f64,
) callconv(.c) void {
    enter();
    props_numbers.setNumericValueJump(mutable_properties(node), value) catch note_oom();
}

/// Sets the `numeric_value_step` property to `value`.
///
/// `include/zaccesskit.h:3963`. Nothing is retained and nothing is borrowed.
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range, and no value of it is
/// rejected: a negative scroll offset and a font size of zero are both values a
/// caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_numeric_value_step(
    node: *handles.accesskit_node,
    value: f64,
) callconv(.c) void {
    enter();
    props_numbers.setNumericValueStep(mutable_properties(node), value) catch note_oom();
}

/// Sets the `position_in_set` property to `value`.
///
/// `include/zaccesskit.h:4268`. Nothing is retained and nothing is borrowed.
/// The value is a `size_t`, a count and never an index into anything this
/// library owns, and no value of it is rejected: a negative scroll offset and a
/// font size of zero are both values a caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_position_in_set(
    node: *handles.accesskit_node,
    value: usize,
) callconv(.c) void {
    enter();
    props_numbers.setPositionInSet(mutable_properties(node), value) catch note_oom();
}

/// Sets the `row_count` property to `value`.
///
/// `include/zaccesskit.h:4065`. Nothing is retained and nothing is borrowed.
/// The value is a `size_t`, a count and never an index into anything this
/// library owns, and no value of it is rejected: a negative scroll offset and a
/// font size of zero are both values a caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_row_count(
    node: *handles.accesskit_node,
    value: usize,
) callconv(.c) void {
    enter();
    props_numbers.setRowCount(mutable_properties(node), value) catch note_oom();
}

/// Sets the `row_index` property to `value`.
///
/// `include/zaccesskit.h:4116`. Nothing is retained and nothing is borrowed.
/// The value is a `size_t`, a count and never an index into anything this
/// library owns, and no value of it is rejected: a negative scroll offset and a
/// font size of zero are both values a caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_row_index(
    node: *handles.accesskit_node,
    value: usize,
) callconv(.c) void {
    enter();
    props_numbers.setRowIndex(mutable_properties(node), value) catch note_oom();
}

/// Sets the `row_span` property to `value`.
///
/// `include/zaccesskit.h:4167`. Nothing is retained and nothing is borrowed.
/// The value is a `size_t`, a count and never an index into anything this
/// library owns, and no value of it is rejected: a negative scroll offset and a
/// font size of zero are both values a caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_row_span(
    node: *handles.accesskit_node,
    value: usize,
) callconv(.c) void {
    enter();
    props_numbers.setRowSpan(mutable_properties(node), value) catch note_oom();
}

/// Sets the `scroll_x` property to `value`.
///
/// `include/zaccesskit.h:3731`. Nothing is retained and nothing is borrowed.
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range, and no value of it is
/// rejected: a negative scroll offset and a font size of zero are both values a
/// caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_scroll_x(
    node: *handles.accesskit_node,
    value: f64,
) callconv(.c) void {
    enter();
    props_numbers.setScrollX(mutable_properties(node), value) catch note_oom();
}

/// Sets the `scroll_x_max` property to `value`.
///
/// `include/zaccesskit.h:3782`. Nothing is retained and nothing is borrowed.
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range, and no value of it is
/// rejected: a negative scroll offset and a font size of zero are both values a
/// caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_scroll_x_max(
    node: *handles.accesskit_node,
    value: f64,
) callconv(.c) void {
    enter();
    props_numbers.setScrollXMax(mutable_properties(node), value) catch note_oom();
}

/// Sets the `scroll_x_min` property to `value`.
///
/// `include/zaccesskit.h:3756`. Nothing is retained and nothing is borrowed.
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range, and no value of it is
/// rejected: a negative scroll offset and a font size of zero are both values a
/// caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_scroll_x_min(
    node: *handles.accesskit_node,
    value: f64,
) callconv(.c) void {
    enter();
    props_numbers.setScrollXMin(mutable_properties(node), value) catch note_oom();
}

/// Sets the `scroll_y` property to `value`.
///
/// `include/zaccesskit.h:3808`. Nothing is retained and nothing is borrowed.
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range, and no value of it is
/// rejected: a negative scroll offset and a font size of zero are both values a
/// caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_scroll_y(
    node: *handles.accesskit_node,
    value: f64,
) callconv(.c) void {
    enter();
    props_numbers.setScrollY(mutable_properties(node), value) catch note_oom();
}

/// Sets the `scroll_y_max` property to `value`.
///
/// `include/zaccesskit.h:3859`. Nothing is retained and nothing is borrowed.
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range, and no value of it is
/// rejected: a negative scroll offset and a font size of zero are both values a
/// caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_scroll_y_max(
    node: *handles.accesskit_node,
    value: f64,
) callconv(.c) void {
    enter();
    props_numbers.setScrollYMax(mutable_properties(node), value) catch note_oom();
}

/// Sets the `scroll_y_min` property to `value`.
///
/// `include/zaccesskit.h:3833`. Nothing is retained and nothing is borrowed.
/// The value is a `double`, in the unit the property names: logical pixels for
/// a scroll offset and a plain value for a numeric range, and no value of it is
/// rejected: a negative scroll offset and a font size of zero are both values a
/// caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_scroll_y_min(
    node: *handles.accesskit_node,
    value: f64,
) callconv(.c) void {
    enter();
    props_numbers.setScrollYMin(mutable_properties(node), value) catch note_oom();
}

/// Sets the `size_of_set` property to `value`.
///
/// `include/zaccesskit.h:4242`. Nothing is retained and nothing is borrowed.
/// The value is a `size_t`, a count and never an index into anything this
/// library owns, and no value of it is rejected: a negative scroll offset and a
/// font size of zero are both values a caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_size_of_set(
    node: *handles.accesskit_node,
    value: usize,
) callconv(.c) void {
    enter();
    props_numbers.setSizeOfSet(mutable_properties(node), value) catch note_oom();
}

/// The `size_of_set` property.
///
/// `include/zaccesskit.h:4234`. The value is copied, so it stays valid after a
/// later write. `has_value` is false when the property is unset, and a set
/// property holding zero is a real state the tree uses, so the flag byte is
/// what tells it from an absence. A zero row index means the first row; no
/// sentinel stands for "unset", because absence is a state this store reaches.
///
/// The value is a `size_t`, a count and never an index into anything this
/// library owns. The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_size_of_set(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptIndex) {
    enter();
    return optionalReturn(
        marshal.COptIndex,
        props_numbers.sizeOfSet(properties_of(node)),
    );
}

// --- The colours and the text decorations ------------------------------------

/// The `background_color` property.
///
/// `include/zaccesskit.h:4312`. `has_value` is false when the property is
/// unset. Each channel is a `uint8_t` where 255 is the channel at full
/// strength, so a fully transparent black is a set property holding four zero
/// bytes and is not an absent property.
///
/// The value is a copy of four bytes, so it stays valid after a later write.
/// The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_background_color(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptColor) {
    enter();
    return optionalReturn(
        marshal.COptColor,
        props_colors.backgroundColor(properties_of(node)),
    );
}

/// Clears the `background_color` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4329`. Returns nothing and cannot fail.
export fn accesskit_node_clear_background_color(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_colors.clearBackgroundColor(mutable_properties(node));
}

/// Clears the `color_value` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4303`. Returns nothing and cannot fail.
export fn accesskit_node_clear_color_value(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_colors.clearColorValue(mutable_properties(node));
}

/// Clears the `foreground_color` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4355`. Returns nothing and cannot fail.
export fn accesskit_node_clear_foreground_color(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_colors.clearForegroundColor(mutable_properties(node));
}

/// Clears the `overline` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4381`. Returns nothing and cannot fail.
export fn accesskit_node_clear_overline(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_colors.clearOverline(mutable_properties(node));
}

/// Clears the `strikethrough` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4407`. Returns nothing and cannot fail.
export fn accesskit_node_clear_strikethrough(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_colors.clearStrikethrough(mutable_properties(node));
}

/// Clears the `underline` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4433`. Returns nothing and cannot fail.
export fn accesskit_node_clear_underline(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_colors.clearUnderline(mutable_properties(node));
}

/// The `color_value` property.
///
/// `include/zaccesskit.h:4286`. `has_value` is false when the property is
/// unset. Each channel is a `uint8_t` where 255 is the channel at full
/// strength, so a fully transparent black is a set property holding four zero
/// bytes and is not an absent property.
///
/// The value is a copy of four bytes, so it stays valid after a later write.
/// The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_color_value(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptColor) {
    enter();
    return optionalReturn(
        marshal.COptColor,
        props_colors.colorValue(properties_of(node)),
    );
}

/// The `foreground_color` property.
///
/// `include/zaccesskit.h:4338`. `has_value` is false when the property is
/// unset. Each channel is a `uint8_t` where 255 is the channel at full
/// strength, so a fully transparent black is a set property holding four zero
/// bytes and is not an absent property.
///
/// The value is a copy of four bytes, so it stays valid after a later write.
/// The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_foreground_color(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptColor) {
    enter();
    return optionalReturn(
        marshal.COptColor,
        props_colors.foregroundColor(properties_of(node)),
    );
}

/// The `overline` property.
///
/// `include/zaccesskit.h:4364`. `has_value` is false when the property is
/// unset. A node carries one of these each for its overline, its strikethrough
/// and its underline, and a set decoration in the `none` style reads as
/// present, which is a different answer from absent.
///
/// The value is a copy of five bytes, so it stays valid after a later write.
/// The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_overline(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptTextDecoration) {
    enter();
    return optionalReturn(
        marshal.COptTextDecoration,
        props_colors.overline(properties_of(node)),
    );
}

/// Sets the `background_color` property to `value`.
///
/// `include/zaccesskit.h:4320`. Nothing is retained and nothing is borrowed.
/// Each channel is copied as it stands, so an alpha of 0 stores a fully
/// transparent colour rather than clearing the property.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_background_color(
    node: *handles.accesskit_node,
    value: TargetArg(Color),
) callconv(.c) void {
    enter();
    props_colors.setBackgroundColor(
        mutable_properties(node),
        decodeArg(Color, value),
    ) catch note_oom();
}

/// Sets the `color_value` property to `value`.
///
/// `include/zaccesskit.h:4294`. Nothing is retained and nothing is borrowed.
/// Each channel is copied as it stands, so an alpha of 0 stores a fully
/// transparent colour rather than clearing the property.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_color_value(
    node: *handles.accesskit_node,
    value: TargetArg(Color),
) callconv(.c) void {
    enter();
    props_colors.setColorValue(mutable_properties(node), decodeArg(Color, value)) catch note_oom();
}

/// Sets the `foreground_color` property to `value`.
///
/// `include/zaccesskit.h:4346`. Nothing is retained and nothing is borrowed.
/// Each channel is copied as it stands, so an alpha of 0 stores a fully
/// transparent colour rather than clearing the property.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_foreground_color(
    node: *handles.accesskit_node,
    value: TargetArg(Color),
) callconv(.c) void {
    enter();
    props_colors.setForegroundColor(
        mutable_properties(node),
        decodeArg(Color, value),
    ) catch note_oom();
}

/// Sets the `overline` property to `value`.
///
/// `include/zaccesskit.h:4372`. Nothing is retained and nothing is borrowed.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_overline(
    node: *handles.accesskit_node,
    value: TargetArg(TextDecoration),
) callconv(.c) void {
    enter();
    props_colors.setOverline(
        mutable_properties(node),
        decodeArg(TextDecoration, value),
    ) catch note_oom();
}

/// Sets the `strikethrough` property to `value`.
///
/// `include/zaccesskit.h:4398`. Nothing is retained and nothing is borrowed.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_strikethrough(
    node: *handles.accesskit_node,
    value: TargetArg(TextDecoration),
) callconv(.c) void {
    enter();
    props_colors.setStrikethrough(
        mutable_properties(node),
        decodeArg(TextDecoration, value),
    ) catch note_oom();
}

/// Sets the `underline` property to `value`.
///
/// `include/zaccesskit.h:4424`. Nothing is retained and nothing is borrowed.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_underline(
    node: *handles.accesskit_node,
    value: TargetArg(TextDecoration),
) callconv(.c) void {
    enter();
    props_colors.setUnderline(
        mutable_properties(node),
        decodeArg(TextDecoration, value),
    ) catch note_oom();
}

/// The `strikethrough` property.
///
/// `include/zaccesskit.h:4390`. `has_value` is false when the property is
/// unset. A node carries one of these each for its overline, its strikethrough
/// and its underline, and a set decoration in the `none` style reads as
/// present, which is a different answer from absent.
///
/// The value is a copy of five bytes, so it stays valid after a later write.
/// The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_strikethrough(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptTextDecoration) {
    enter();
    return optionalReturn(
        marshal.COptTextDecoration,
        props_colors.strikethrough(properties_of(node)),
    );
}

/// The `underline` property.
///
/// `include/zaccesskit.h:4416`. `has_value` is false when the property is
/// unset. A node carries one of these each for its overline, its strikethrough
/// and its underline, and a set decoration in the `none` style reads as
/// present, which is a different answer from absent.
///
/// The value is a copy of five bytes, so it stays valid after a later write.
/// The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_underline(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptTextDecoration) {
    enter();
    return optionalReturn(
        marshal.COptTextDecoration,
        props_colors.underline(properties_of(node)),
    );
}

// --- The per-character lists -------------------------------------------------

/// The `character_lengths` property as a list of per-character byte lengths.
///
/// `include/zaccesskit.h:4445`. An unset property gives `length == 0` with a
/// non-null `values`, so a caller that ignores the length reads an empty list
/// rather than a dangling pointer.
///
/// The result borrows the node's own storage, so the node must stay alive and
/// its list unmodified for as long as the caller reads it, and no function
/// releases it. This is a borrow, so the getter allocates nothing, cannot fail,
/// and leaves the tag `ACCESSKIT_ERROR_NONE`.
///
/// **An absent list and a set empty list read the same.** The header gives this
/// shape no flag, so `length == 0` is both answers and a non-empty list is the
/// only thing a reader can distinguish. That is upstream's shape: it stores a
/// missing value as an empty slice (`accesskit/src/lib.rs:1234-1243`), not as
/// an absent one.
export fn accesskit_node_character_lengths(
    node: *const handles.accesskit_node,
) callconv(.c) marshal.CLengths {
    enter();
    return marshal.lengths_to_c(props_vectors.characterLengths(properties_of(node)));
}

/// The `character_positions` property as a list of per-character positions or
/// widths.
///
/// `include/zaccesskit.h:4510`. `has_value` is false when the property is
/// unset. This is the one `accesskit_opt_*` form whose absent value is not a
/// zeroed pointer: the flag is false with `length == 0` and a non-null `values`
/// pointing at an empty list, so a reader that ignores the flag reads an empty
/// list rather than dereferences nothing.
///
/// The result borrows the node's own storage, so the node must stay alive and
/// its list unmodified for as long as the caller reads it, and no function
/// releases it. This is a borrow, so the getter allocates nothing, cannot fail,
/// and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_character_positions(
    node: *const handles.accesskit_node,
) callconv(.c) marshal.COptCoords {
    enter();
    return marshal.opt_coords_to_c(props_vectors.characterPositions(properties_of(node)));
}

/// The `character_widths` property as a list of per-character positions or
/// widths.
///
/// `include/zaccesskit.h:4543`. `has_value` is false when the property is
/// unset. This is the one `accesskit_opt_*` form whose absent value is not a
/// zeroed pointer: the flag is false with `length == 0` and a non-null `values`
/// pointing at an empty list, so a reader that ignores the flag reads an empty
/// list rather than dereferences nothing.
///
/// The result borrows the node's own storage, so the node must stay alive and
/// its list unmodified for as long as the caller reads it, and no function
/// releases it. This is a borrow, so the getter allocates nothing, cannot fail,
/// and leaves the tag `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_character_widths(
    node: *const handles.accesskit_node,
) callconv(.c) marshal.COptCoords {
    enter();
    return marshal.opt_coords_to_c(props_vectors.characterWidths(properties_of(node)));
}

/// Clears the `character_lengths` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4466`. The stored list is released, which invalidates
/// every slice the getter returned. Returns nothing and cannot fail.
export fn accesskit_node_clear_character_lengths(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_vectors.clearCharacterLengths(mutable_properties(node));
}

/// Clears the `character_positions` property, so the getter reports it as
/// unset.
///
/// `include/zaccesskit.h:4531`. The stored list is released, which invalidates
/// every slice the getter returned. Returns nothing and cannot fail.
export fn accesskit_node_clear_character_positions(
    node: *handles.accesskit_node,
) callconv(.c) void {
    enter();
    props_vectors.clearCharacterPositions(mutable_properties(node));
}

/// Clears the `character_widths` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4563`. The stored list is released, which invalidates
/// every slice the getter returned. Returns nothing and cannot fail.
export fn accesskit_node_clear_character_widths(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_vectors.clearCharacterWidths(mutable_properties(node));
}

/// Clears the `word_starts` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4497`. The stored list is released, which invalidates
/// every slice the getter returned. Returns nothing and cannot fail.
export fn accesskit_node_clear_word_starts(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_vectors.clearWordStarts(mutable_properties(node));
}

/// Copies `length` bytes from `values` into the node's `character_lengths`.
///
/// `include/zaccesskit.h:4456`. Nothing is retained. `values` may be null when
/// `length` is 0 and must not be null otherwise, so a null pointer with a non-
/// zero length is a caller precondition that `marshal.cArrayToSlice` asserts. On
/// success `character_lengths` is exactly the copied values.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_character_lengths(
    node: *handles.accesskit_node,
    length: usize,
    values: [*c]const u8,
) callconv(.c) void {
    enter();
    const given = marshal.cArrayToSlice(u8, values, length);
    props_vectors.setCharacterLengths(mutable_properties(node), given) catch note_oom();
}

/// Copies `length` measurements from `values` into the node's
/// `character_positions`.
///
/// `include/zaccesskit.h:4521`. Nothing is retained. `values` may be null when
/// `length` is 0 and must not be null otherwise. The measurements are copied as
/// they stand, and no value is rejected: a negative width and a non-finite
/// position are both values a caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_character_positions(
    node: *handles.accesskit_node,
    length: usize,
    values: [*c]const f32,
) callconv(.c) void {
    enter();
    const given = marshal.cArrayToSlice(f32, values, length);
    props_vectors.setCharacterPositions(mutable_properties(node), given) catch note_oom();
}

/// Copies `length` measurements from `values` into the node's
/// `character_widths`.
///
/// `include/zaccesskit.h:4554`. Nothing is retained. `values` may be null when
/// `length` is 0 and must not be null otherwise. The measurements are copied as
/// they stand, and no value is rejected: a negative width and a non-finite
/// position are both values a caller may write.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_character_widths(
    node: *handles.accesskit_node,
    length: usize,
    values: [*c]const f32,
) callconv(.c) void {
    enter();
    const given = marshal.cArrayToSlice(f32, values, length);
    props_vectors.setCharacterWidths(mutable_properties(node), given) catch note_oom();
}

/// Copies `length` bytes from `values` into the node's `word_starts`.
///
/// `include/zaccesskit.h:4488`. Nothing is retained. `values` may be null when
/// `length` is 0 and must not be null otherwise, so a null pointer with a non-
/// zero length is a caller precondition that `marshal.cArrayToSlice` asserts. On
/// success `word_starts` is exactly the copied values.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_word_starts(
    node: *handles.accesskit_node,
    length: usize,
    values: [*c]const u8,
) callconv(.c) void {
    enter();
    const given = marshal.cArrayToSlice(u8, values, length);
    props_vectors.setWordStarts(mutable_properties(node), given) catch note_oom();
}

/// The `word_starts` property as a list of per-character byte lengths.
///
/// `include/zaccesskit.h:4477`. An unset property gives `length == 0` with a
/// non-null `values`, so a caller that ignores the length reads an empty list
/// rather than a dangling pointer.
///
/// The result borrows the node's own storage, so the node must stay alive and
/// its list unmodified for as long as the caller reads it, and no function
/// releases it. This is a borrow, so the getter allocates nothing, cannot fail,
/// and leaves the tag `ACCESSKIT_ERROR_NONE`.
///
/// **An absent list and a set empty list read the same.** The header gives this
/// shape no flag, so `length == 0` is both answers and a non-empty list is the
/// only thing a reader can distinguish. That is upstream's shape: it stores a
/// missing value as an empty slice (`accesskit/src/lib.rs:1234-1243`), not as
/// an absent one.
export fn accesskit_node_word_starts(
    node: *const handles.accesskit_node,
) callconv(.c) marshal.CLengths {
    enter();
    return marshal.lengths_to_c(props_vectors.wordStarts(properties_of(node)));
}

// --- The booleans --------------------------------------------------------------

/// Clears the `expanded` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4588`. A set `false` is not the same state and does
/// not become one by this call; only the store is changed. Returns nothing and
/// cannot fail.
export fn accesskit_node_clear_expanded(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_enums.clearExpanded(mutable_properties(node));
}

/// Clears the `selected` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4613`. A set `false` is not the same state and does
/// not become one by this call; only the store is changed. Returns nothing and
/// cannot fail.
export fn accesskit_node_clear_selected(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_enums.clearSelected(mutable_properties(node));
}

/// The `expanded` property.
///
/// `include/zaccesskit.h:4572`. `has_value` is false when the property is
/// unset. The C name carries the `is_` the eighteen flags do not, because this
/// is a property and the eighteen are a separate bit set on the node.
///
/// **This is the one place a legitimate zero and an absence are two answers
/// that a reader must not confuse.** A `false` that is set is a different state
/// from a `false` that is not, and the flag byte is the only thing that
/// separates them; the port writes a zero into `value` in the false case so a
/// reader who ignores the flag reads a defined zero rather than uninitialised
/// storage, which the header calls a diagnostic aid
/// (`include/zaccesskit.h:1262-1266`).
///
/// The value is a copy of one byte, so it stays valid after a later write. The
/// getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_is_expanded(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptBool) {
    enter();
    return optionalReturn(
        marshal.COptBool,
        props_enums.isExpanded(properties_of(node)),
    );
}

/// The `selected` property.
///
/// `include/zaccesskit.h:4597`. `has_value` is false when the property is
/// unset. The C name carries the `is_` the eighteen flags do not, because this
/// is a property and the eighteen are a separate bit set on the node.
///
/// **This is the one place a legitimate zero and an absence are two answers
/// that a reader must not confuse.** A `false` that is set is a different state
/// from a `false` that is not, and the flag byte is the only thing that
/// separates them; the port writes a zero into `value` in the false case so a
/// reader who ignores the flag reads a defined zero rather than uninitialised
/// storage, which the header calls a diagnostic aid
/// (`include/zaccesskit.h:1262-1266`).
///
/// The value is a copy of one byte, so it stays valid after a later write. The
/// getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_is_selected(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptBool) {
    enter();
    return optionalReturn(
        marshal.COptBool,
        props_enums.isSelected(properties_of(node)),
    );
}

/// Sets the `expanded` property to `value`.
///
/// `include/zaccesskit.h:4580`. Nothing is retained and nothing is borrowed. A
/// `false` stores a set property holding `false`, which the getter reports with
/// `has_value` true; only `accesskit_node_clear_expanded` makes the property
/// absent.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_expanded(
    node: *handles.accesskit_node,
    value: bool,
) callconv(.c) void {
    enter();
    props_enums.setExpanded(mutable_properties(node), value) catch note_oom();
}

/// Sets the `selected` property to `value`.
///
/// `include/zaccesskit.h:4605`. Nothing is retained and nothing is borrowed. A
/// `false` stores a set property holding `false`, which the getter reports with
/// `has_value` true; only `accesskit_node_clear_selected` makes the property
/// absent.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_selected(
    node: *handles.accesskit_node,
    value: bool,
) callconv(.c) void {
    enter();
    props_enums.setSelected(mutable_properties(node), value) catch note_oom();
}

// --- The twelve single-valued enumerations -------------------------------------

/// The `aria_current` property.
///
/// `include/zaccesskit.h:4775`. `has_value` is false when the property is
/// unset. Each of the twelve is a wire enum whose tags are contiguous from
/// zero, so the `u8` the setter takes is wide enough for every tag and the
/// checked gate in `src/schema/node_enums.zig` is the boundary's safe decode;
/// `src/capi/property_value.zig` proves each gate answers for its own tags and
/// rejects the byte one past the end.
///
/// The value is a copy of one byte, so it stays valid after a later write. The
/// getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_aria_current(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptAriaCurrent) {
    enter();
    return optionalReturn(
        marshal.COptAriaCurrent,
        props_enums.ariaCurrent(properties_of(node)),
    );
}

/// The `auto_complete` property.
///
/// `include/zaccesskit.h:4801`. `has_value` is false when the property is
/// unset. Each of the twelve is a wire enum whose tags are contiguous from
/// zero, so the `u8` the setter takes is wide enough for every tag and the
/// checked gate in `src/schema/node_enums.zig` is the boundary's safe decode;
/// `src/capi/property_value.zig` proves each gate answers for its own tags and
/// rejects the byte one past the end.
///
/// The value is a copy of one byte, so it stays valid after a later write. The
/// getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_auto_complete(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptAutoComplete) {
    enter();
    return optionalReturn(
        marshal.COptAutoComplete,
        props_enums.autoComplete(properties_of(node)),
    );
}

/// Clears the `aria_current` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4792`. The enumeration's first tag is the value
/// upstream stores for an unset slot, and it is a real value here: only this
/// call makes the property absent, because the store holds no sentinel. Returns
/// nothing and cannot fail.
export fn accesskit_node_clear_aria_current(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_enums.clearAriaCurrent(mutable_properties(node));
}

/// Clears the `auto_complete` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4818`. The enumeration's first tag is the value
/// upstream stores for an unset slot, and it is a real value here: only this
/// call makes the property absent, because the store holds no sentinel. Returns
/// nothing and cannot fail.
export fn accesskit_node_clear_auto_complete(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_enums.clearAutoComplete(mutable_properties(node));
}

/// Clears the `has_popup` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4844`. The enumeration's first tag is the value
/// upstream stores for an unset slot, and it is a real value here: only this
/// call makes the property absent, because the store holds no sentinel. Returns
/// nothing and cannot fail.
export fn accesskit_node_clear_has_popup(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_enums.clearHasPopup(mutable_properties(node));
}

/// Clears the `invalid` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4638`. The enumeration's first tag is the value
/// upstream stores for an unset slot, and it is a real value here: only this
/// call makes the property absent, because the store holds no sentinel. Returns
/// nothing and cannot fail.
export fn accesskit_node_clear_invalid(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_enums.clearInvalid(mutable_properties(node));
}

/// Clears the `list_style` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4870`. The enumeration's first tag is the value
/// upstream stores for an unset slot, and it is a real value here: only this
/// call makes the property absent, because the store holds no sentinel. Returns
/// nothing and cannot fail.
export fn accesskit_node_clear_list_style(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_enums.clearListStyle(mutable_properties(node));
}

/// Clears the `live` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4688`. The enumeration's first tag is the value
/// upstream stores for an unset slot, and it is a real value here: only this
/// call makes the property absent, because the store holds no sentinel. Returns
/// nothing and cannot fail.
export fn accesskit_node_clear_live(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_enums.clearLive(mutable_properties(node));
}

/// Clears the `orientation` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4740`. The enumeration's first tag is the value
/// upstream stores for an unset slot, and it is a real value here: only this
/// call makes the property absent, because the store holds no sentinel. Returns
/// nothing and cannot fail.
export fn accesskit_node_clear_orientation(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_enums.clearOrientation(mutable_properties(node));
}

/// Clears the `sort_direction` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4766`. The enumeration's first tag is the value
/// upstream stores for an unset slot, and it is a real value here: only this
/// call makes the property absent, because the store holds no sentinel. Returns
/// nothing and cannot fail.
export fn accesskit_node_clear_sort_direction(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_enums.clearSortDirection(mutable_properties(node));
}

/// Clears the `text_align` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4896`. The enumeration's first tag is the value
/// upstream stores for an unset slot, and it is a real value here: only this
/// call makes the property absent, because the store holds no sentinel. Returns
/// nothing and cannot fail.
export fn accesskit_node_clear_text_align(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_enums.clearTextAlign(mutable_properties(node));
}

/// Clears the `text_direction` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4714`. The enumeration's first tag is the value
/// upstream stores for an unset slot, and it is a real value here: only this
/// call makes the property absent, because the store holds no sentinel. Returns
/// nothing and cannot fail.
export fn accesskit_node_clear_text_direction(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_enums.clearTextDirection(mutable_properties(node));
}

/// Clears the `toggled` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4663`. The enumeration's first tag is the value
/// upstream stores for an unset slot, and it is a real value here: only this
/// call makes the property absent, because the store holds no sentinel. Returns
/// nothing and cannot fail.
export fn accesskit_node_clear_toggled(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_enums.clearToggled(mutable_properties(node));
}

/// Clears the `vertical_offset` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4922`. The enumeration's first tag is the value
/// upstream stores for an unset slot, and it is a real value here: only this
/// call makes the property absent, because the store holds no sentinel. Returns
/// nothing and cannot fail.
export fn accesskit_node_clear_vertical_offset(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_enums.clearVerticalOffset(mutable_properties(node));
}

/// The `has_popup` property.
///
/// `include/zaccesskit.h:4827`. `has_value` is false when the property is
/// unset. Each of the twelve is a wire enum whose tags are contiguous from
/// zero, so the `u8` the setter takes is wide enough for every tag and the
/// checked gate in `src/schema/node_enums.zig` is the boundary's safe decode;
/// `src/capi/property_value.zig` proves each gate answers for its own tags and
/// rejects the byte one past the end.
///
/// The value is a copy of one byte, so it stays valid after a later write. The
/// getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_has_popup(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptHasPopup) {
    enter();
    return optionalReturn(
        marshal.COptHasPopup,
        props_enums.hasPopup(properties_of(node)),
    );
}

/// The `invalid` property.
///
/// `include/zaccesskit.h:4622`. `has_value` is false when the property is
/// unset. Each of the twelve is a wire enum whose tags are contiguous from
/// zero, so the `u8` the setter takes is wide enough for every tag and the
/// checked gate in `src/schema/node_enums.zig` is the boundary's safe decode;
/// `src/capi/property_value.zig` proves each gate answers for its own tags and
/// rejects the byte one past the end.
///
/// The value is a copy of one byte, so it stays valid after a later write. The
/// getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_invalid(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptInvalid) {
    enter();
    return optionalReturn(
        marshal.COptInvalid,
        props_enums.invalid(properties_of(node)),
    );
}

/// The `list_style` property.
///
/// `include/zaccesskit.h:4853`. `has_value` is false when the property is
/// unset. Each of the twelve is a wire enum whose tags are contiguous from
/// zero, so the `u8` the setter takes is wide enough for every tag and the
/// checked gate in `src/schema/node_enums.zig` is the boundary's safe decode;
/// `src/capi/property_value.zig` proves each gate answers for its own tags and
/// rejects the byte one past the end.
///
/// The value is a copy of one byte, so it stays valid after a later write. The
/// getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_list_style(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptListStyle) {
    enter();
    return optionalReturn(
        marshal.COptListStyle,
        props_enums.listStyle(properties_of(node)),
    );
}

/// The `live` property.
///
/// `include/zaccesskit.h:4672`. `has_value` is false when the property is
/// unset. Each of the twelve is a wire enum whose tags are contiguous from
/// zero, so the `u8` the setter takes is wide enough for every tag and the
/// checked gate in `src/schema/node_enums.zig` is the boundary's safe decode;
/// `src/capi/property_value.zig` proves each gate answers for its own tags and
/// rejects the byte one past the end.
///
/// The value is a copy of one byte, so it stays valid after a later write. The
/// getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_live(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptLive) {
    enter();
    return optionalReturn(
        marshal.COptLive,
        props_enums.live(properties_of(node)),
    );
}

/// The `orientation` property.
///
/// `include/zaccesskit.h:4723`. `has_value` is false when the property is
/// unset. Each of the twelve is a wire enum whose tags are contiguous from
/// zero, so the `u8` the setter takes is wide enough for every tag and the
/// checked gate in `src/schema/node_enums.zig` is the boundary's safe decode;
/// `src/capi/property_value.zig` proves each gate answers for its own tags and
/// rejects the byte one past the end.
///
/// The value is a copy of one byte, so it stays valid after a later write. The
/// getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_orientation(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptOrientation) {
    enter();
    return optionalReturn(
        marshal.COptOrientation,
        props_enums.orientation(properties_of(node)),
    );
}

/// Sets the `aria_current` property to `value`.
///
/// `include/zaccesskit.h:4783`. Nothing is retained and nothing is borrowed.
///
/// A `value` byte past the last tag of this enumeration is a caller
/// precondition and changes nothing, for the reason `src/capi/node.zig` records
/// as ruling 4: the header says nothing about such a byte and `accesskit_error`
/// cannot name that case, so the checked gate returns no variant, the export
/// returns, and the tag stays `ACCESSKIT_ERROR_NONE`.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_aria_current(
    node: *handles.accesskit_node,
    value: u8,
) callconv(.c) void {
    enter();
    const wanted = schema.ariaCurrentFromInt(value) orelse return;
    props_enums.setAriaCurrent(mutable_properties(node), wanted) catch note_oom();
}

/// Sets the `auto_complete` property to `value`.
///
/// `include/zaccesskit.h:4809`. Nothing is retained and nothing is borrowed.
///
/// A `value` byte past the last tag of this enumeration is a caller
/// precondition and changes nothing, for the reason `src/capi/node.zig` records
/// as ruling 4: the header says nothing about such a byte and `accesskit_error`
/// cannot name that case, so the checked gate returns no variant, the export
/// returns, and the tag stays `ACCESSKIT_ERROR_NONE`.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_auto_complete(
    node: *handles.accesskit_node,
    value: u8,
) callconv(.c) void {
    enter();
    const wanted = schema.autoCompleteFromInt(value) orelse return;
    props_enums.setAutoComplete(mutable_properties(node), wanted) catch note_oom();
}

/// Sets the `has_popup` property to `value`.
///
/// `include/zaccesskit.h:4835`. Nothing is retained and nothing is borrowed.
///
/// A `value` byte past the last tag of this enumeration is a caller
/// precondition and changes nothing, for the reason `src/capi/node.zig` records
/// as ruling 4: the header says nothing about such a byte and `accesskit_error`
/// cannot name that case, so the checked gate returns no variant, the export
/// returns, and the tag stays `ACCESSKIT_ERROR_NONE`.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_has_popup(
    node: *handles.accesskit_node,
    value: u8,
) callconv(.c) void {
    enter();
    const wanted = schema.hasPopupFromInt(value) orelse return;
    props_enums.setHasPopup(mutable_properties(node), wanted) catch note_oom();
}

/// Sets the `invalid` property to `value`.
///
/// `include/zaccesskit.h:4630`. Nothing is retained and nothing is borrowed.
///
/// A `value` byte past the last tag of this enumeration is a caller
/// precondition and changes nothing, for the reason `src/capi/node.zig` records
/// as ruling 4: the header says nothing about such a byte and `accesskit_error`
/// cannot name that case, so the checked gate returns no variant, the export
/// returns, and the tag stays `ACCESSKIT_ERROR_NONE`.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_invalid(
    node: *handles.accesskit_node,
    value: u8,
) callconv(.c) void {
    enter();
    const wanted = schema.invalidFromInt(value) orelse return;
    props_enums.setInvalid(mutable_properties(node), wanted) catch note_oom();
}

/// Sets the `list_style` property to `value`.
///
/// `include/zaccesskit.h:4861`. Nothing is retained and nothing is borrowed.
///
/// A `value` byte past the last tag of this enumeration is a caller
/// precondition and changes nothing, for the reason `src/capi/node.zig` records
/// as ruling 4: the header says nothing about such a byte and `accesskit_error`
/// cannot name that case, so the checked gate returns no variant, the export
/// returns, and the tag stays `ACCESSKIT_ERROR_NONE`.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_list_style(
    node: *handles.accesskit_node,
    value: u8,
) callconv(.c) void {
    enter();
    const wanted = schema.listStyleFromInt(value) orelse return;
    props_enums.setListStyle(mutable_properties(node), wanted) catch note_oom();
}

/// Sets the `live` property to `value`.
///
/// `include/zaccesskit.h:4680`. Nothing is retained and nothing is borrowed.
///
/// A `value` byte past the last tag of this enumeration is a caller
/// precondition and changes nothing, for the reason `src/capi/node.zig` records
/// as ruling 4: the header says nothing about such a byte and `accesskit_error`
/// cannot name that case, so the checked gate returns no variant, the export
/// returns, and the tag stays `ACCESSKIT_ERROR_NONE`.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_live(node: *handles.accesskit_node, value: u8) callconv(.c) void {
    enter();
    const wanted = schema.liveFromInt(value) orelse return;
    props_enums.setLive(mutable_properties(node), wanted) catch note_oom();
}

/// Sets the `orientation` property to `value`.
///
/// `include/zaccesskit.h:4731`. Nothing is retained and nothing is borrowed.
///
/// A `value` byte past the last tag of this enumeration is a caller
/// precondition and changes nothing, for the reason `src/capi/node.zig` records
/// as ruling 4: the header says nothing about such a byte and `accesskit_error`
/// cannot name that case, so the checked gate returns no variant, the export
/// returns, and the tag stays `ACCESSKIT_ERROR_NONE`.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_orientation(
    node: *handles.accesskit_node,
    value: u8,
) callconv(.c) void {
    enter();
    const wanted = schema.orientationFromInt(value) orelse return;
    props_enums.setOrientation(mutable_properties(node), wanted) catch note_oom();
}

/// Sets the `sort_direction` property to `value`.
///
/// `include/zaccesskit.h:4757`. Nothing is retained and nothing is borrowed.
///
/// A `value` byte past the last tag of this enumeration is a caller
/// precondition and changes nothing, for the reason `src/capi/node.zig` records
/// as ruling 4: the header says nothing about such a byte and `accesskit_error`
/// cannot name that case, so the checked gate returns no variant, the export
/// returns, and the tag stays `ACCESSKIT_ERROR_NONE`.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_sort_direction(
    node: *handles.accesskit_node,
    value: u8,
) callconv(.c) void {
    enter();
    const wanted = schema.sortDirectionFromInt(value) orelse return;
    props_enums.setSortDirection(mutable_properties(node), wanted) catch note_oom();
}

/// Sets the `text_align` property to `value`.
///
/// `include/zaccesskit.h:4887`. Nothing is retained and nothing is borrowed.
///
/// A `value` byte past the last tag of this enumeration is a caller
/// precondition and changes nothing, for the reason `src/capi/node.zig` records
/// as ruling 4: the header says nothing about such a byte and `accesskit_error`
/// cannot name that case, so the checked gate returns no variant, the export
/// returns, and the tag stays `ACCESSKIT_ERROR_NONE`.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_text_align(
    node: *handles.accesskit_node,
    value: u8,
) callconv(.c) void {
    enter();
    const wanted = schema.textAlignFromInt(value) orelse return;
    props_enums.setTextAlign(mutable_properties(node), wanted) catch note_oom();
}

/// Sets the `text_direction` property to `value`.
///
/// `include/zaccesskit.h:4705`. Nothing is retained and nothing is borrowed.
///
/// A `value` byte past the last tag of this enumeration is a caller
/// precondition and changes nothing, for the reason `src/capi/node.zig` records
/// as ruling 4: the header says nothing about such a byte and `accesskit_error`
/// cannot name that case, so the checked gate returns no variant, the export
/// returns, and the tag stays `ACCESSKIT_ERROR_NONE`.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_text_direction(
    node: *handles.accesskit_node,
    value: u8,
) callconv(.c) void {
    enter();
    const wanted = schema.textDirectionFromInt(value) orelse return;
    props_enums.setTextDirection(mutable_properties(node), wanted) catch note_oom();
}

/// Sets the `toggled` property to `value`.
///
/// `include/zaccesskit.h:4655`. Nothing is retained and nothing is borrowed.
///
/// A `value` byte past the last tag of this enumeration is a caller
/// precondition and changes nothing, for the reason `src/capi/node.zig` records
/// as ruling 4: the header says nothing about such a byte and `accesskit_error`
/// cannot name that case, so the checked gate returns no variant, the export
/// returns, and the tag stays `ACCESSKIT_ERROR_NONE`.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_toggled(
    node: *handles.accesskit_node,
    value: u8,
) callconv(.c) void {
    enter();
    const wanted = schema.toggledFromInt(value) orelse return;
    props_enums.setToggled(mutable_properties(node), wanted) catch note_oom();
}

/// Sets the `vertical_offset` property to `value`.
///
/// `include/zaccesskit.h:4913`. Nothing is retained and nothing is borrowed.
///
/// A `value` byte past the last tag of this enumeration is a caller
/// precondition and changes nothing, for the reason `src/capi/node.zig` records
/// as ruling 4: the header says nothing about such a byte and `accesskit_error`
/// cannot name that case, so the checked gate returns no variant, the export
/// returns, and the tag stays `ACCESSKIT_ERROR_NONE`.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_vertical_offset(
    node: *handles.accesskit_node,
    value: u8,
) callconv(.c) void {
    enter();
    const wanted = schema.verticalOffsetFromInt(value) orelse return;
    props_enums.setVerticalOffset(mutable_properties(node), wanted) catch note_oom();
}

/// The `sort_direction` property.
///
/// `include/zaccesskit.h:4749`. `has_value` is false when the property is
/// unset. Each of the twelve is a wire enum whose tags are contiguous from
/// zero, so the `u8` the setter takes is wide enough for every tag and the
/// checked gate in `src/schema/node_enums.zig` is the boundary's safe decode;
/// `src/capi/property_value.zig` proves each gate answers for its own tags and
/// rejects the byte one past the end.
///
/// The value is a copy of one byte, so it stays valid after a later write. The
/// getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_sort_direction(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptSortDirection) {
    enter();
    return optionalReturn(
        marshal.COptSortDirection,
        props_enums.sortDirection(properties_of(node)),
    );
}

/// The `text_align` property.
///
/// `include/zaccesskit.h:4879`. `has_value` is false when the property is
/// unset. Each of the twelve is a wire enum whose tags are contiguous from
/// zero, so the `u8` the setter takes is wide enough for every tag and the
/// checked gate in `src/schema/node_enums.zig` is the boundary's safe decode;
/// `src/capi/property_value.zig` proves each gate answers for its own tags and
/// rejects the byte one past the end.
///
/// The value is a copy of one byte, so it stays valid after a later write. The
/// getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_text_align(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptTextAlign) {
    enter();
    return optionalReturn(
        marshal.COptTextAlign,
        props_enums.textAlign(properties_of(node)),
    );
}

/// The `text_direction` property.
///
/// `include/zaccesskit.h:4697`. `has_value` is false when the property is
/// unset. Each of the twelve is a wire enum whose tags are contiguous from
/// zero, so the `u8` the setter takes is wide enough for every tag and the
/// checked gate in `src/schema/node_enums.zig` is the boundary's safe decode;
/// `src/capi/property_value.zig` proves each gate answers for its own tags and
/// rejects the byte one past the end.
///
/// The value is a copy of one byte, so it stays valid after a later write. The
/// getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_text_direction(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptTextDirection) {
    enter();
    return optionalReturn(
        marshal.COptTextDirection,
        props_enums.textDirection(properties_of(node)),
    );
}

/// The `toggled` property.
///
/// `include/zaccesskit.h:4647`. `has_value` is false when the property is
/// unset. Each of the twelve is a wire enum whose tags are contiguous from
/// zero, so the `u8` the setter takes is wide enough for every tag and the
/// checked gate in `src/schema/node_enums.zig` is the boundary's safe decode;
/// `src/capi/property_value.zig` proves each gate answers for its own tags and
/// rejects the byte one past the end.
///
/// The value is a copy of one byte, so it stays valid after a later write. The
/// getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_toggled(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptToggled) {
    enter();
    return optionalReturn(
        marshal.COptToggled,
        props_enums.toggled(properties_of(node)),
    );
}

/// The `vertical_offset` property.
///
/// `include/zaccesskit.h:4905`. `has_value` is false when the property is
/// unset. Each of the twelve is a wire enum whose tags are contiguous from
/// zero, so the `u8` the setter takes is wide enough for every tag and the
/// checked gate in `src/schema/node_enums.zig` is the boundary's safe decode;
/// `src/capi/property_value.zig` proves each gate answers for its own tags and
/// rejects the byte one past the end.
///
/// The value is a copy of one byte, so it stays valid after a later write. The
/// getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_vertical_offset(
    node: *const handles.accesskit_node,
) callconv(.c) OptionalReturn(marshal.COptVerticalOffset) {
    enter();
    return optionalReturn(
        marshal.COptVerticalOffset,
        props_enums.verticalOffset(properties_of(node)),
    );
}

// --- The text selection, the bounds and the transform -------------------------

/// The `bounds` property.
///
/// `include/zaccesskit.h:4959`. `has_value` is false when the property is
/// unset. The four coordinates are in logical pixels in the node's own
/// coordinate space, and `bounds` does not move that space: only `transform`
/// does.
///
/// The value is a copy of four `double` at 32 bytes, so it stays valid after a
/// later write. The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_bounds(node: *const handles.accesskit_node) callconv(.c) marshal.COptRect {
    enter();
    return marshal.opt_rect_to_c(props_option.bounds(properties_of(node)));
}

/// Clears the `bounds` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:4975`. Returns nothing and cannot fail.
export fn accesskit_node_clear_bounds(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_option.clearBounds(mutable_properties(node));
}

/// Clears the `text_selection` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:5001`. Returns nothing and cannot fail.
export fn accesskit_node_clear_text_selection(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_option.clearTextSelection(mutable_properties(node));
}

/// Clears the `transform` property, so the getter returns null.
///
/// `include/zaccesskit.h:4950`. This call may move the store's slice, so a
/// pointer from `accesskit_node_transform` taken before it is invalid
/// afterwards. Returns nothing and cannot fail.
export fn accesskit_node_clear_transform(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_option.clearTransform(mutable_properties(node));
}

/// Sets the `bounds` property to `value`.
///
/// `include/zaccesskit.h:4967`. Nothing is retained and nothing is borrowed. No
/// corner is checked, so a rectangle with `x1 < x0` is stored as it stands;
/// `accesskit_rect_abs` is what normalises one.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_bounds(
    node: *handles.accesskit_node,
    value: Rect,
) callconv(.c) void {
    enter();
    props_option.setBounds(mutable_properties(node), value) catch note_oom();
}

/// Sets the `text_selection` property to `value`.
///
/// `include/zaccesskit.h:4992`. Nothing is retained and nothing is borrowed. No
/// position is checked: the header says a node identifier and a character index
/// are what it is, and the consumer that resolves them is the layer that can
/// reject one.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_text_selection(
    node: *handles.accesskit_node,
    value: TextSelection,
) callconv(.c) void {
    enter();
    props_option.setTextSelection(mutable_properties(node), value) catch note_oom();
}

/// Sets the `transform` property to `value`.
///
/// `include/zaccesskit.h:4941`. Nothing is retained and nothing is borrowed.
/// The six coefficients are stored as they stand, so a transform with a non-
/// finite coefficient is stored rather than rejected;
/// `accesskit_affine_is_finite` is what reports one.
///
/// A write here may move the store's slice, so a pointer from
/// `accesskit_node_transform` taken before this call is invalid afterwards.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_transform(
    node: *handles.accesskit_node,
    value: Affine,
) callconv(.c) void {
    enter();
    props_option.setTransform(mutable_properties(node), value) catch note_oom();
}

/// The `text_selection` property.
///
/// `include/zaccesskit.h:4984`. `has_value` is false when the property is
/// unset. A selection with no extent is a caret and holds `anchor` equal to
/// `focus`, so a caret at the start of a node is a set property holding two
/// zero positions rather than an absent one.
///
/// The value is a copy of the two positions, so it stays valid after a later
/// write. The getter allocates nothing, cannot fail, and leaves the tag
/// `ACCESSKIT_ERROR_NONE`.
export fn accesskit_node_text_selection(
    node: *const handles.accesskit_node,
) callconv(.c) marshal.COptTextSelection {
    enter();
    return marshal.opt_text_selection_to_c(props_option.textSelection(properties_of(node)));
}

/// The `transform` property, or null when the property is unset.
///
/// `include/zaccesskit.h:4933`. There is no `has_value` field on this return
/// type: the pointer is the whole answer. The header calls the returned value a
/// copy the caller owns, and no declaration in the header releases one.
///
/// **A pointer that borrows, and why.** The store holds the six coefficients
/// inline, so the only pointer this can return is one into the node's own
/// property slice. It is valid while the node is alive and that property is
/// unmodified, and the next write to this node's store may move the slice and
/// invalidate it. There is no release to call, because the header declares
/// none, and no copy to keep, because a C caller reads the six `double` while
/// the node is alive. A caller that needs the transform to outlive the node
/// must copy the six coefficients itself.
export fn accesskit_node_transform(
    node: *const handles.accesskit_node,
) callconv(.c) ?*const Affine {
    enter();
    return props_option.transform(properties_of(node));
}

// --- The custom actions --------------------------------------------------------

/// Clears the `custom_actions` property, so the getter reports it as unset.
///
/// `include/zaccesskit.h:5124`. Every action the store holds goes with it,
/// including each description buffer, and a caller that still holds a pointer
/// to one of those actions has a dangling pointer. Returns nothing and cannot
/// fail.
export fn accesskit_node_clear_custom_actions(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    props_vectors.clearCustomActions(mutable_properties(node));
}

/// A deep copy of the node's custom actions, or null when the allocation
/// failed.
///
/// `include/zaccesskit.h:5094`. An empty list gives `length == 0`, never a null
/// result. Release the result with `accesskit_custom_actions_free`, once.
/// Nothing in it borrows from the node, so the node may be released first.
///
/// A null return means `ACCESSKIT_ERROR_OUT_OF_MEMORY` and nothing else.
/// Nothing survives that path: the copy registers each release before the
/// allocation that can fail.
export fn accesskit_node_custom_actions(
    node: *const handles.accesskit_node,
) callconv(.c) ?*marshal.CCustomActions {
    enter();
    return marshal.custom_actions_to_c(
        allocation.allocator(),
        props_vectors.customActions(properties_of(node)),
    ) catch {
        note_oom();
        return null;
    };
}

/// Appends `action` to the node's custom action list and takes ownership of it.
///
/// `include/zaccesskit.h:5115`. The caller must not release `action` after this
/// call and must not pass it again. The store releases the action and its
/// description when the node is released, or when a later set replaces the
/// list.
///
/// **Taking the caller's block is what makes this one a transfer rather than a
/// copy.** The description buffer moves into the store and the block this
/// library made for it goes straight back to the allocator that made it, so
/// there is one description buffer at the end rather than two. The block goes
/// back before the append, because the append owns the value and nothing else
/// may release it after that.
///
/// **A void pusher that can fail.** On failure the list is unchanged and the
/// tag becomes `ACCESSKIT_ERROR_OUT_OF_MEMORY`. The pusher explicitly maps
/// both error arms to that tag. `PropertyTagMismatch` is documented at
/// `src/schema/props/vectors.zig:65-70` as unreachable through valid
/// property-store paths.
export fn accesskit_node_push_custom_action(
    node: *handles.accesskit_node,
    action: marshal.CustomActionHandle,
) callconv(.c) void {
    enter();
    const store = mutable_properties(node);
    const gpa = allocation.allocator();
    const taken: CustomAction = marshal.actionFromHandle(action);
    gpa.destroy(action);
    props_vectors.pushCustomAction(store, taken) catch |err| switch (err) {
        error.OutOfMemory => note_oom(),
        error.PropertyTagMismatch => note_oom(),
    };
}

/// Copies every action in the array into the node.
///
/// `include/zaccesskit.h:5104`. This takes ownership of nothing: the caller
/// keeps the array and every action in it, releases each action with
/// `accesskit_custom_action_free`, and releases the array itself afterwards.
/// Every action in `values` is copied, so the node owns copies rather than the
/// caller's handles, which is upstream's shape at
/// `accesskit-c/src/common.rs:823`.
///
/// A null slot is a caller precondition this declaration does not describe, and
/// the port answers it as `src/capi/node.zig` records as ruling 4: the whole
/// call changes nothing and the tag stays `ACCESSKIT_ERROR_NONE`, because
/// `accesskit_error` cannot name that case.
///
/// **A void setter that can fail, which is a port-specific divergence.** The
/// header says "There is no failure path", and that holds upstream because
/// `accesskit-c` compiles with `panic = "abort"` and its property store aborts
/// on an allocation failure. Here the store returns `error.OutOfMemory` and a
/// void export has nowhere to report it, so this clears the tag on entry, sets
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY` on the failing path, and leaves the property
/// exactly as the caller found it. Nothing partial survives: the schema setter
/// builds its replacement before it releases the value it displaces.
export fn accesskit_node_set_custom_actions(
    node: *handles.accesskit_node,
    length: usize,
    values: [*c]const ?*CustomAction,
) callconv(.c) void {
    enter();
    const store = mutable_properties(node);
    const gpa = store.gpa;
    var copies: std.ArrayList(CustomAction) = .empty;
    // Every clone in here belongs to this call on every path out, including the
    // one that succeeds. `setCustomActions` copies each action again rather than
    // adopting it, so what it stores is never one of these description buffers
    // and none of them moves to the property.
    defer releaseActionCopies(gpa, &copies);
    for (marshal.cArrayToSlice(?*CustomAction, values, length)) |slot| {
        const handle = slot orelse return;
        var fresh = action_request.customActionClone(gpa, handle) catch {
            note_oom();
            return;
        };
        copies.append(gpa, fresh) catch {
            fresh.deinit(gpa);
            note_oom();
            return;
        };
    }
    props_vectors.setCustomActions(store, copies.items) catch {
        note_oom();
        return;
    };
}

// --- The signatures ----------------------------------------------------------------

/// One row per declaration: the export and the signature `include/zaccesskit.h`
/// gives it.
///
/// The C symbol is not in this table and is in `export_names` beside it, because
/// `zig fmt` drops a string literal from a tuple when any other cell in the same
/// tuple spells the same name, and every row here spells its own symbol as an
/// expression. A row that carried the name lost it to the formatter, which is a
/// silent change to a table a reader checks by name.
///
/// The bound on the sweep below is `export_signatures.len`, which is 294, one row
/// per header declaration. Each row is a comptime-known tuple, so the sweep
/// visits exactly those 294 and nothing else. A signature that drifts from the
/// header is a build failure and not a run that returns a wrong number: a getter
/// that started taking a pointer, a setter that lost its length and a pusher that
/// started returning a tag are all caught here.
const export_signatures = .{
    .{ accesskit_node_new, fn (role: u8) callconv(.c) ?*handles.accesskit_node },
    .{ accesskit_node_free, fn (node: ?*handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_debug, fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 },
    .{
        accesskit_node_children,
        fn (node: *const handles.accesskit_node) callconv(.c) marshal.CNodeIds,
    },
    .{ accesskit_node_clear_children, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_controls, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_described_by, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_details, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_flow_to, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_labelled_by, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_owns, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_radio_group, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_controls,
        fn (node: *const handles.accesskit_node) callconv(.c) marshal.CNodeIds,
    },
    .{
        accesskit_node_described_by,
        fn (node: *const handles.accesskit_node) callconv(.c) marshal.CNodeIds,
    },
    .{
        accesskit_node_details,
        fn (node: *const handles.accesskit_node) callconv(.c) marshal.CNodeIds,
    },
    .{
        accesskit_node_flow_to,
        fn (node: *const handles.accesskit_node) callconv(.c) marshal.CNodeIds,
    },
    .{
        accesskit_node_labelled_by,
        fn (node: *const handles.accesskit_node) callconv(.c) marshal.CNodeIds,
    },
    .{
        accesskit_node_owns,
        fn (node: *const handles.accesskit_node) callconv(.c) marshal.CNodeIds,
    },
    .{
        accesskit_node_push_child,
        fn (node: *handles.accesskit_node, item: NodeIdContent) callconv(.c) void,
    },
    .{
        accesskit_node_push_controlled,
        fn (node: *handles.accesskit_node, item: NodeIdContent) callconv(.c) void,
    },
    .{
        accesskit_node_push_described_by,
        fn (node: *handles.accesskit_node, item: NodeIdContent) callconv(.c) void,
    },
    .{
        accesskit_node_push_detail,
        fn (node: *handles.accesskit_node, item: NodeIdContent) callconv(.c) void,
    },
    .{
        accesskit_node_push_flow_to,
        fn (node: *handles.accesskit_node, item: NodeIdContent) callconv(.c) void,
    },
    .{
        accesskit_node_push_labelled_by,
        fn (node: *handles.accesskit_node, item: NodeIdContent) callconv(.c) void,
    },
    .{
        accesskit_node_push_owned,
        fn (node: *handles.accesskit_node, item: NodeIdContent) callconv(.c) void,
    },
    .{
        accesskit_node_push_to_radio_group,
        fn (node: *handles.accesskit_node, item: NodeIdContent) callconv(.c) void,
    },
    .{
        accesskit_node_radio_group,
        fn (node: *const handles.accesskit_node) callconv(.c) marshal.CNodeIds,
    },
    .{
        accesskit_node_set_children,
        fn (
            node: *handles.accesskit_node,
            length: usize,
            values: [*c]const NodeId,
        ) callconv(.c) void,
    },
    .{
        accesskit_node_set_controls,
        fn (
            node: *handles.accesskit_node,
            length: usize,
            values: [*c]const NodeId,
        ) callconv(.c) void,
    },
    .{
        accesskit_node_set_described_by,
        fn (
            node: *handles.accesskit_node,
            length: usize,
            values: [*c]const NodeId,
        ) callconv(.c) void,
    },
    .{
        accesskit_node_set_details,
        fn (
            node: *handles.accesskit_node,
            length: usize,
            values: [*c]const NodeId,
        ) callconv(.c) void,
    },
    .{
        accesskit_node_set_flow_to,
        fn (
            node: *handles.accesskit_node,
            length: usize,
            values: [*c]const NodeId,
        ) callconv(.c) void,
    },
    .{
        accesskit_node_set_labelled_by,
        fn (
            node: *handles.accesskit_node,
            length: usize,
            values: [*c]const NodeId,
        ) callconv(.c) void,
    },
    .{
        accesskit_node_set_owns,
        fn (
            node: *handles.accesskit_node,
            length: usize,
            values: [*c]const NodeId,
        ) callconv(.c) void,
    },
    .{
        accesskit_node_set_radio_group,
        fn (
            node: *handles.accesskit_node,
            length: usize,
            values: [*c]const NodeId,
        ) callconv(.c) void,
    },
    .{
        accesskit_node_active_descendant,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptNodeId),
    },
    .{
        accesskit_node_clear_active_descendant,
        fn (node: *handles.accesskit_node) callconv(.c) void,
    },
    .{ accesskit_node_clear_error_message, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_clear_in_page_link_target,
        fn (node: *handles.accesskit_node) callconv(.c) void,
    },
    .{ accesskit_node_clear_member_of, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_next_on_line, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_popup_for, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_clear_previous_on_line,
        fn (node: *handles.accesskit_node) callconv(.c) void,
    },
    .{
        accesskit_node_error_message,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptNodeId),
    },
    .{
        accesskit_node_in_page_link_target,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptNodeId),
    },
    .{
        accesskit_node_member_of,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptNodeId),
    },
    .{
        accesskit_node_next_on_line,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptNodeId),
    },
    .{
        accesskit_node_popup_for,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptNodeId),
    },
    .{
        accesskit_node_previous_on_line,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptNodeId),
    },
    .{
        accesskit_node_set_active_descendant,
        fn (node: *handles.accesskit_node, value: NodeIdContent) callconv(.c) void,
    },
    .{
        accesskit_node_set_error_message,
        fn (node: *handles.accesskit_node, value: NodeIdContent) callconv(.c) void,
    },
    .{
        accesskit_node_set_in_page_link_target,
        fn (node: *handles.accesskit_node, value: NodeIdContent) callconv(.c) void,
    },
    .{
        accesskit_node_set_member_of,
        fn (node: *handles.accesskit_node, value: NodeIdContent) callconv(.c) void,
    },
    .{
        accesskit_node_set_next_on_line,
        fn (node: *handles.accesskit_node, value: NodeIdContent) callconv(.c) void,
    },
    .{
        accesskit_node_set_popup_for,
        fn (node: *handles.accesskit_node, value: NodeIdContent) callconv(.c) void,
    },
    .{
        accesskit_node_set_previous_on_line,
        fn (node: *handles.accesskit_node, value: NodeIdContent) callconv(.c) void,
    },
    .{ accesskit_node_clear_tree_id, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_set_tree_id,
        fn (node: *handles.accesskit_node, value: TargetArg(TreeId)) callconv(.c) void,
    },
    .{
        accesskit_node_tree_id,
        fn (node: *const handles.accesskit_node) callconv(.c) marshal.COptTreeId,
    },
    .{ accesskit_node_access_key, fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 },
    .{ accesskit_node_author_id, fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 },
    .{
        accesskit_node_braille_label,
        fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8,
    },
    .{
        accesskit_node_braille_role_description,
        fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8,
    },
    .{ accesskit_node_class_name, fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 },
    .{ accesskit_node_clear_access_key, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_author_id, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_braille_label, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_clear_braille_role_description,
        fn (node: *handles.accesskit_node) callconv(.c) void,
    },
    .{ accesskit_node_clear_class_name, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_clear_column_index_text,
        fn (node: *handles.accesskit_node) callconv(.c) void,
    },
    .{ accesskit_node_clear_description, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_font_family, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_html_id, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_html_tag, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_inner_html, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_clear_keyboard_shortcut,
        fn (node: *handles.accesskit_node) callconv(.c) void,
    },
    .{ accesskit_node_clear_label, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_language, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_placeholder, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_clear_role_description,
        fn (node: *handles.accesskit_node) callconv(.c) void,
    },
    .{ accesskit_node_clear_row_index_text, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_clear_state_description,
        fn (node: *handles.accesskit_node) callconv(.c) void,
    },
    .{ accesskit_node_clear_tooltip, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_url, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_value, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_column_index_text,
        fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8,
    },
    .{ accesskit_node_description, fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 },
    .{ accesskit_node_font_family, fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 },
    .{ accesskit_node_html_id, fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 },
    .{ accesskit_node_html_tag, fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 },
    .{ accesskit_node_inner_html, fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 },
    .{
        accesskit_node_keyboard_shortcut,
        fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8,
    },
    .{ accesskit_node_label, fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 },
    .{ accesskit_node_language, fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 },
    .{ accesskit_node_placeholder, fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 },
    .{
        accesskit_node_role_description,
        fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8,
    },
    .{
        accesskit_node_row_index_text,
        fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8,
    },
    .{
        accesskit_node_set_access_key,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_access_key_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_author_id,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_author_id_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_braille_label,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_braille_label_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_braille_role_description,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_braille_role_description_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_class_name,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_class_name_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_column_index_text,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_column_index_text_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_description,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_description_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_font_family,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_font_family_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_html_id,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_html_id_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_html_tag,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_html_tag_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_inner_html,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_inner_html_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_keyboard_shortcut,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_keyboard_shortcut_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_label,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_label_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_language,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_language_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_placeholder,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_placeholder_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_role_description,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_role_description_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_row_index_text,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_row_index_text_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_state_description,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_state_description_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_tooltip,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_tooltip_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_url,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_url_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_value,
        fn (node: *handles.accesskit_node, value: [*:0]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_value_with_length,
        fn (node: *handles.accesskit_node, value: [*c]const u8, length: usize) callconv(.c) void,
    },
    .{
        accesskit_node_state_description,
        fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8,
    },
    .{ accesskit_node_tooltip, fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 },
    .{ accesskit_node_url, fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 },
    .{ accesskit_node_value, fn (node: *const handles.accesskit_node) callconv(.c) ?[*:0]u8 },
    .{ accesskit_node_clear_column_count, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_column_index, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_column_span, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_font_size, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_font_weight, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_level, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_clear_max_numeric_value,
        fn (node: *handles.accesskit_node) callconv(.c) void,
    },
    .{
        accesskit_node_clear_min_numeric_value,
        fn (node: *handles.accesskit_node) callconv(.c) void,
    },
    .{ accesskit_node_clear_numeric_value, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_clear_numeric_value_jump,
        fn (node: *handles.accesskit_node) callconv(.c) void,
    },
    .{
        accesskit_node_clear_numeric_value_step,
        fn (node: *handles.accesskit_node) callconv(.c) void,
    },
    .{ accesskit_node_clear_position_in_set, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_row_count, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_row_index, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_row_span, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_scroll_x, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_scroll_x_max, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_scroll_x_min, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_scroll_y, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_scroll_y_max, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_scroll_y_min, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_size_of_set, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_column_count,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptIndex),
    },
    .{
        accesskit_node_column_index,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptIndex),
    },
    .{
        accesskit_node_column_span,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptIndex),
    },
    .{
        accesskit_node_font_size,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptFloat),
    },
    .{
        accesskit_node_font_weight,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptFloat),
    },
    .{
        accesskit_node_level,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptIndex),
    },
    .{
        accesskit_node_max_numeric_value,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptDouble),
    },
    .{
        accesskit_node_min_numeric_value,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptDouble),
    },
    .{
        accesskit_node_numeric_value,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptDouble),
    },
    .{
        accesskit_node_numeric_value_jump,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptDouble),
    },
    .{
        accesskit_node_numeric_value_step,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptDouble),
    },
    .{
        accesskit_node_position_in_set,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptIndex),
    },
    .{
        accesskit_node_row_count,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptIndex),
    },
    .{
        accesskit_node_row_index,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptIndex),
    },
    .{
        accesskit_node_row_span,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptIndex),
    },
    .{
        accesskit_node_scroll_x,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptDouble),
    },
    .{
        accesskit_node_scroll_x_max,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptDouble),
    },
    .{
        accesskit_node_scroll_x_min,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptDouble),
    },
    .{
        accesskit_node_scroll_y,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptDouble),
    },
    .{
        accesskit_node_scroll_y_max,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptDouble),
    },
    .{
        accesskit_node_scroll_y_min,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptDouble),
    },
    .{
        accesskit_node_set_column_count,
        fn (node: *handles.accesskit_node, value: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_column_index,
        fn (node: *handles.accesskit_node, value: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_column_span,
        fn (node: *handles.accesskit_node, value: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_font_size,
        fn (node: *handles.accesskit_node, value: f32) callconv(.c) void,
    },
    .{
        accesskit_node_set_font_weight,
        fn (node: *handles.accesskit_node, value: f32) callconv(.c) void,
    },
    .{
        accesskit_node_set_level,
        fn (node: *handles.accesskit_node, value: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_max_numeric_value,
        fn (node: *handles.accesskit_node, value: f64) callconv(.c) void,
    },
    .{
        accesskit_node_set_min_numeric_value,
        fn (node: *handles.accesskit_node, value: f64) callconv(.c) void,
    },
    .{
        accesskit_node_set_numeric_value,
        fn (node: *handles.accesskit_node, value: f64) callconv(.c) void,
    },
    .{
        accesskit_node_set_numeric_value_jump,
        fn (node: *handles.accesskit_node, value: f64) callconv(.c) void,
    },
    .{
        accesskit_node_set_numeric_value_step,
        fn (node: *handles.accesskit_node, value: f64) callconv(.c) void,
    },
    .{
        accesskit_node_set_position_in_set,
        fn (node: *handles.accesskit_node, value: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_row_count,
        fn (node: *handles.accesskit_node, value: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_row_index,
        fn (node: *handles.accesskit_node, value: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_row_span,
        fn (node: *handles.accesskit_node, value: usize) callconv(.c) void,
    },
    .{
        accesskit_node_set_scroll_x,
        fn (node: *handles.accesskit_node, value: f64) callconv(.c) void,
    },
    .{
        accesskit_node_set_scroll_x_max,
        fn (node: *handles.accesskit_node, value: f64) callconv(.c) void,
    },
    .{
        accesskit_node_set_scroll_x_min,
        fn (node: *handles.accesskit_node, value: f64) callconv(.c) void,
    },
    .{
        accesskit_node_set_scroll_y,
        fn (node: *handles.accesskit_node, value: f64) callconv(.c) void,
    },
    .{
        accesskit_node_set_scroll_y_max,
        fn (node: *handles.accesskit_node, value: f64) callconv(.c) void,
    },
    .{
        accesskit_node_set_scroll_y_min,
        fn (node: *handles.accesskit_node, value: f64) callconv(.c) void,
    },
    .{
        accesskit_node_set_size_of_set,
        fn (node: *handles.accesskit_node, value: usize) callconv(.c) void,
    },
    .{
        accesskit_node_size_of_set,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptIndex),
    },
    .{
        accesskit_node_background_color,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptColor),
    },
    .{
        accesskit_node_clear_background_color,
        fn (node: *handles.accesskit_node) callconv(.c) void,
    },
    .{ accesskit_node_clear_color_value, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_clear_foreground_color,
        fn (node: *handles.accesskit_node) callconv(.c) void,
    },
    .{ accesskit_node_clear_overline, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_strikethrough, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_underline, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_color_value,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptColor),
    },
    .{
        accesskit_node_foreground_color,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptColor),
    },
    .{
        accesskit_node_overline,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptTextDecoration),
    },
    .{
        accesskit_node_set_background_color,
        fn (node: *handles.accesskit_node, value: TargetArg(Color)) callconv(.c) void,
    },
    .{
        accesskit_node_set_color_value,
        fn (node: *handles.accesskit_node, value: TargetArg(Color)) callconv(.c) void,
    },
    .{
        accesskit_node_set_foreground_color,
        fn (node: *handles.accesskit_node, value: TargetArg(Color)) callconv(.c) void,
    },
    .{
        accesskit_node_set_overline,
        fn (node: *handles.accesskit_node, value: TargetArg(TextDecoration)) callconv(.c) void,
    },
    .{
        accesskit_node_set_strikethrough,
        fn (node: *handles.accesskit_node, value: TargetArg(TextDecoration)) callconv(.c) void,
    },
    .{
        accesskit_node_set_underline,
        fn (node: *handles.accesskit_node, value: TargetArg(TextDecoration)) callconv(.c) void,
    },
    .{
        accesskit_node_strikethrough,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptTextDecoration),
    },
    .{
        accesskit_node_underline,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptTextDecoration),
    },
    .{
        accesskit_node_character_lengths,
        fn (node: *const handles.accesskit_node) callconv(.c) marshal.CLengths,
    },
    .{
        accesskit_node_character_positions,
        fn (node: *const handles.accesskit_node) callconv(.c) marshal.COptCoords,
    },
    .{
        accesskit_node_character_widths,
        fn (node: *const handles.accesskit_node) callconv(.c) marshal.COptCoords,
    },
    .{
        accesskit_node_clear_character_lengths,
        fn (node: *handles.accesskit_node) callconv(.c) void,
    },
    .{
        accesskit_node_clear_character_positions,
        fn (node: *handles.accesskit_node) callconv(.c) void,
    },
    .{
        accesskit_node_clear_character_widths,
        fn (node: *handles.accesskit_node) callconv(.c) void,
    },
    .{ accesskit_node_clear_word_starts, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_set_character_lengths,
        fn (node: *handles.accesskit_node, length: usize, values: [*c]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_character_positions,
        fn (node: *handles.accesskit_node, length: usize, values: [*c]const f32) callconv(.c) void,
    },
    .{
        accesskit_node_set_character_widths,
        fn (node: *handles.accesskit_node, length: usize, values: [*c]const f32) callconv(.c) void,
    },
    .{
        accesskit_node_set_word_starts,
        fn (node: *handles.accesskit_node, length: usize, values: [*c]const u8) callconv(.c) void,
    },
    .{
        accesskit_node_word_starts,
        fn (node: *const handles.accesskit_node) callconv(.c) marshal.CLengths,
    },
    .{ accesskit_node_clear_expanded, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_selected, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_is_expanded,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptBool),
    },
    .{
        accesskit_node_is_selected,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptBool),
    },
    .{
        accesskit_node_set_expanded,
        fn (node: *handles.accesskit_node, value: bool) callconv(.c) void,
    },
    .{
        accesskit_node_set_selected,
        fn (node: *handles.accesskit_node, value: bool) callconv(.c) void,
    },
    .{
        accesskit_node_aria_current,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptAriaCurrent),
    },
    .{
        accesskit_node_auto_complete,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptAutoComplete),
    },
    .{ accesskit_node_clear_aria_current, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_auto_complete, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_has_popup, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_invalid, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_list_style, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_live, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_orientation, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_sort_direction, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_text_align, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_text_direction, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_toggled, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_vertical_offset, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_has_popup,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptHasPopup),
    },
    .{
        accesskit_node_invalid,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptInvalid),
    },
    .{
        accesskit_node_list_style,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptListStyle),
    },
    .{
        accesskit_node_live,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptLive),
    },
    .{
        accesskit_node_orientation,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptOrientation),
    },
    .{
        accesskit_node_set_aria_current,
        fn (node: *handles.accesskit_node, value: u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_auto_complete,
        fn (node: *handles.accesskit_node, value: u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_has_popup,
        fn (node: *handles.accesskit_node, value: u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_invalid,
        fn (node: *handles.accesskit_node, value: u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_list_style,
        fn (node: *handles.accesskit_node, value: u8) callconv(.c) void,
    },
    .{ accesskit_node_set_live, fn (node: *handles.accesskit_node, value: u8) callconv(.c) void },
    .{
        accesskit_node_set_orientation,
        fn (node: *handles.accesskit_node, value: u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_sort_direction,
        fn (node: *handles.accesskit_node, value: u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_text_align,
        fn (node: *handles.accesskit_node, value: u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_text_direction,
        fn (node: *handles.accesskit_node, value: u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_toggled,
        fn (node: *handles.accesskit_node, value: u8) callconv(.c) void,
    },
    .{
        accesskit_node_set_vertical_offset,
        fn (node: *handles.accesskit_node, value: u8) callconv(.c) void,
    },
    .{
        accesskit_node_sort_direction,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptSortDirection),
    },
    .{
        accesskit_node_text_align,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptTextAlign),
    },
    .{
        accesskit_node_text_direction,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptTextDirection),
    },
    .{
        accesskit_node_toggled,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptToggled),
    },
    .{
        accesskit_node_vertical_offset,
        fn (node: *const handles.accesskit_node) callconv(.c) OptionalReturn(marshal.COptVerticalOffset),
    },
    .{
        accesskit_node_bounds,
        fn (node: *const handles.accesskit_node) callconv(.c) marshal.COptRect,
    },
    .{ accesskit_node_clear_bounds, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_text_selection, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{ accesskit_node_clear_transform, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_set_bounds,
        fn (node: *handles.accesskit_node, value: Rect) callconv(.c) void,
    },
    .{
        accesskit_node_set_text_selection,
        fn (node: *handles.accesskit_node, value: TextSelection) callconv(.c) void,
    },
    .{
        accesskit_node_set_transform,
        fn (node: *handles.accesskit_node, value: Affine) callconv(.c) void,
    },
    .{
        accesskit_node_text_selection,
        fn (node: *const handles.accesskit_node) callconv(.c) marshal.COptTextSelection,
    },
    .{
        accesskit_node_transform,
        fn (node: *const handles.accesskit_node) callconv(.c) ?*const Affine,
    },
    .{ accesskit_node_clear_custom_actions, fn (node: *handles.accesskit_node) callconv(.c) void },
    .{
        accesskit_node_custom_actions,
        fn (node: *const handles.accesskit_node) callconv(.c) ?*marshal.CCustomActions,
    },
    .{
        accesskit_node_push_custom_action,
        fn (node: *handles.accesskit_node, action: marshal.CustomActionHandle) callconv(.c) void,
    },
    .{
        accesskit_node_set_custom_actions,
        fn (
            node: *handles.accesskit_node,
            length: usize,
            values: [*c]const ?*CustomAction,
        ) callconv(.c) void,
    },
};

comptime {
    // The thirteen rows above, and the wire byte each one's setter takes. A
    // `u8` argument cannot carry a tag of 256 or more, so a fourteenth tag on any
    // of these enumerations is a compile error here rather than a value a caller
    // cannot write. `Role` is in the table because `accesskit_node_new` takes one
    // and `src/capi/node.zig` already narrows it the same way.
    if (enum_gate_count != 13) @compileError(
        "the header declares twelve property enumerations and one role enumeration",
    );
    for (enum_gates) |row| {
        if (@typeInfo(row.zig_type).@"enum".field_names.len > 256) @compileError(
            "a u8 argument cannot carry every tag of this enumeration",
        );
    }

    for (export_signatures, export_names, 0..) |row, name, index| {
        if (@TypeOf(row[0]) != row[1]) {
            @compileError("node property export signature does not match " ++
                std.fmt.comptimePrint("{s}", .{name}) ++
                " at row " ++ std.fmt.comptimePrint("{d}", .{index}));
        }
    }

    // Two spellings the sweep above cannot see, and both are ABI rather than
    // type. `accesskit_node_free` takes an optional pointer where the header
    // declares a plain one, and `accesskit_node_transform` returns one where the
    // header declares a plain pointer: a `?*T` and a `*T` are the same width and
    // the same register on every target this library supports, and the two
    // declarations are the only two where the port's null is a contract the
    // header states rather than a defect it does not describe.
}

/// The rows whose C symbol starts with `prefix`.
///
/// The bound is `export_signatures.len`, which is 294.
fn countFamily(prefix: []const u8) usize {
    var count: usize = 0;
    inline for (export_names) |name| {
        if (std.mem.startsWith(u8, name, prefix)) count += 1;
    }
    return count;
}

// --- The tests -----------------------------------------------------------------

/// A node as the C caller holds one, plus the ownership to release it.
///
/// The same shape `src/capi/node.zig` builds for its own tests, and the same
/// reason: the C consumer's contract is the return value of the export, so every
/// test below drives an export and reads what it handed back.
const Fixture = struct {
    /// The handle under test.
    handle: *handles.accesskit_node,

    /// Builds a node with `role` and nothing else, the way `accesskit_node_new`
    /// does, so a test starts from the state a C caller would see.
    fn init(gpa: std.mem.Allocator, role: schema.Role) !Fixture {
        const block = try gpa.create(Node);
        block.* = Node.init(gpa, role);
        return .{ .handle = @ptrCast(block) };
    }

    /// Releases the node and the block, which is what `accesskit_node_free` does.
    fn deinit(self: Fixture, gpa: std.mem.Allocator) void {
        const block: *Node = @ptrCast(@alignCast(self.handle));
        block.deinit();
        gpa.destroy(block);
    }
};

/// The first tag byte of a wire enumeration, which is the zero every setter row
/// writes.
fn firstTagByte(comptime T: type) u8 {
    const fields = @typeInfo(T).@"enum";
    return @intCast(fields.field_values[0]);
}

/// The last tag byte of a wire enumeration.
///
/// Every enumeration this file decodes has at least two tags, so this differs
/// from `firstTagByte` and a sample built from it can never collide with a zero.
fn lastTagByte(comptime T: type) u8 {
    const fields = @typeInfo(T).@"enum";
    return @intCast(fields.field_values[fields.field_names.len - 1]);
}

/// The text selection the selection row writes as its zero: a caret at the very
/// start of the node, which is a set property holding two zero positions.
fn zeroSelection() TextSelection {
    const start = schema.nodeIdFromContent(0);
    return .{
        .anchor = .{ .node_id = start, .character_index = 0 },
        .focus = .{ .node_id = start, .character_index = 0 },
    };
}

/// A selection no other row writes: a two-character extent across two nodes.
fn sampleSelection() TextSelection {
    return .{
        .anchor = .{ .node_id = schema.nodeIdFromContent(11), .character_index = 2 },
        .focus = .{ .node_id = schema.nodeIdFromContent(12), .character_index = 5 },
    };
}

/// The colour the colour and decoration rows write as their zero: four channels
/// at zero, which is a legitimate fully transparent black rather than an absence.
fn zeroColor() Color {
    return .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 };
}

/// A colour no other row writes, so a getter wired to a neighbour's property
/// answers another row's number.
fn sampleColor(channel: u8) Color {
    return .{ .red = channel, .green = channel, .blue = channel, .alpha = channel };
}

/// The text decoration the decoration rows write as their zero: the first style
/// over the zero colour.
fn zeroDecoration() TextDecoration {
    return .{ .style = firstTag(schema.TextDecorationStyle), .color = zeroColor() };
}

/// A decoration no other row writes.
fn sampleDecoration(channel: u8) TextDecoration {
    return .{
        .style = lastTag(schema.TextDecorationStyle),
        .color = sampleColor(channel),
    };
}

/// The first tag of a wire enumeration, as the enum.
///
/// `firstTagByte` answers the byte a setter takes; this answers the value a
/// struct field holds, and `TextDecoration.style` is one of those.
fn firstTag(comptime T: type) T {
    return @fromBackingInt(@intCast(firstTagByte(T)));
}

/// The last tag of a wire enumeration, as the enum.
fn lastTag(comptime T: type) T {
    return @fromBackingInt(@intCast(lastTagByte(T)));
}

/// A compile-time literal as the `[*:0]const u8` a `const char *` parameter is.
fn cText(comptime text: [:0]const u8) [*:0]const u8 {
    return text.ptr;
}

/// A `char *` a getter returned, read as the slice `expectEqualStrings` compares.
fn span(value: [*c]const u8) []const u8 {
    return std.mem.span(value);
}

/// Releases a `char *` a getter returned, which is what `accesskit_string_free`
/// does on the C side.
///
/// The declared allocator rather than a parameter, because that is the only
/// allocator every getter here allocated through: a release through any other
/// one is a mismatched free and not a slow one. The node under a test may well be
/// built from the testing allocator, and its strings still come from here.
fn releaseCString(value: [*c]const u8) void {
    marshal.string_free(allocation.allocator(), @ptrCast(@constCast(value)));
}

/// The declared-allocator pair `accesskit_set_allocator` installs, instrumented.
///
/// It forwards to `inner` and records two facts a leak check cannot: which
/// pointers it handed out and how many times each came back. Three tests need
/// that. The first needs to take the channel over so a node is built through it
/// and freed through it. The second needs the same channel to stop answering so a
/// setter's own allocation fails. The third needs two channels at once, so a
/// release that reached for the allocator as it stands rather than the one the
/// node was built with lands in the wrong one and is visible.
///
/// The pair is a C pair and not a `std.mem.Allocator`, so its release half is
/// handed a bare pointer with no length, exactly as
/// `include/zaccesskit.h:6473` declares it. That is why `live` carries the
/// length: a block has to go back at the length it was made at, and only the
/// allocator knows it.
const CountingPair = struct {
    /// The allocator behind the pair, which is what catches a release of a
    /// pointer it never handed out.
    inner: std.mem.Allocator,

    /// Every outstanding block, by address, with the length it was made at.
    live: std.AutoHashMapUnmanaged(usize, usize) = .empty,

    /// How many times each released pointer came back, by address.
    releases: std.AutoHashMapUnmanaged(usize, usize) = .empty,

    /// When true the allocation half answers nothing, which is how a test makes
    /// a setter's own allocation fail without touching any other allocator.
    refuse: bool = false,

    /// Puts `self` in the channel `accesskit_set_allocator` writes.
    fn install(self: *CountingPair) void {
        allocation.installAllocator(alloc, free, self);
    }

    /// Gives the channel back to the default C allocator, which is what a null
    /// for either half means at `include/zaccesskit.h:6459`.
    fn restore() void {
        allocation.installAllocator(null, null, null);
    }

    /// Releases this counter's own two maps through `inner`, never through the
    /// pair, because recording the counter's own release would count a pointer
    /// the tests under measurement never touched.
    fn release(self: *CountingPair) void {
        self.releases.deinit(self.inner);
        self.live.deinit(self.inner);
    }

    /// The only failure `expectOneReleaseEach` reports.
    const ReleaseCountError = error{ReleasedTwice};

    /// Asserts that every pointer the pair handed out came back, and that each
    /// came back once and once only, then reports how many distinct pointers that
    /// was.
    ///
    /// A double release is a failure and so is a block that never came back. The
    /// walk is bounded by `live.count()` plus `releases.count()`, which is the
    /// number of distinct addresses either map holds.
    fn expectOneReleaseEach(self: *CountingPair) ReleaseCountError!usize {
        var iterator = self.releases.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* != 1) {
                // No diagnostic here. This arm runs on a path a test
                // deliberately drives and passes, and the test runner treats
                // anything a passing test writes to stderr as a logged error,
                // so a print here turns the whole step red. The error name is
                // the record, which is what src/capi/tree_info.zig already
                // does.
                return error.ReleasedTwice;
            }
        }
        if (self.live.count() != 0) {
            return error.ReleasedTwice;
        }
        return self.releases.count();
    }

    /// The allocation half, the first parameter of the declaration at
    /// `include/zaccesskit.h:6472`.
    ///
    /// The header asks for memory aligned to at least 8 bytes, so this asks
    /// `inner` for exactly that rather than for a `[]u8`.
    fn alloc(size: usize, ctx: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *CountingPair = @ptrCast(@alignCast(ctx orelse return null));
        if (self.refuse) return null;
        const memory = self.inner.alignedAlloc(u8, .fromByteUnits(8), size) catch
            return null;
        _ = self.live.put(self.inner, @intFromPtr(memory.ptr), size) catch {
            self.inner.free(memory);
            return null;
        };
        return memory.ptr;
    }

    /// The block `held` names, at `byte_count` bytes.
    ///
    /// The length is not derivable from the pointer, because the C pair is
    /// handed only a pointer at `include/zaccesskit.h:6473`. `live` recorded
    /// the length the block was made at, and `free` on `inner` needs that same
    /// one, so the two halves of the pair meet here and nowhere else.
    fn blockAt(held: *anyopaque, byte_count: usize) []align(8) u8 {
        const base: [*]align(8) u8 = @ptrCast(@alignCast(held));
        return base[0..byte_count];
    }

    /// The release half, the second parameter of the declaration at
    /// `include/zaccesskit.h:6473`.
    ///
    /// The block goes back through `blockAt`, so it goes back at the length
    /// `live` recorded for it rather than at a length this frame guesses.
    fn free(ptr: ?*anyopaque, ctx: ?*anyopaque) callconv(.c) void {
        const self: *CountingPair = @ptrCast(@alignCast(ctx orelse return));
        const held = ptr orelse return;
        const address = @intFromPtr(held);
        const size = self.live.fetchRemove(address) orelse return;
        const slice = blockAt(held, size.value);
        const entry = self.releases.getOrPut(self.inner, address) catch {
            self.inner.free(slice);
            return;
        };
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
        self.inner.free(slice);
    }
};

/// The `accesskit_opt_*` getters and the setters that answer for them, one row
/// per property.
///
/// Each row is `{ getter, setter, clearer, zero, sample, c_name, expected }`.
/// The zero is
/// what the setter writes for the absent test, and the sample is a value no
/// other row writes, so a getter wired to a neighbour's property reads another
/// row's number rather than a right one by accident. The sixth element is the
/// payload the sample comes back as, and it differs from the fifth only for the
/// twelve enumerations, where the setter takes a byte and the getter answers an
/// enum.
///
/// `inline for` reaches the rows rather than a run-time loop, because each row's
/// getter has its own return type and a `type` has no run-time form.
///
/// The C name of each row is in `optional_names` beside this table and not in the
/// row, because `zig fmt` drops a string literal from a tuple when another cell
/// in the same tuple spells the same name, and every row spells its own symbol as
/// an expression. A name cell in the row does not survive formatting.
const optional_rows = .{
    .{
        accesskit_node_active_descendant,
        accesskit_node_set_active_descendant,
        accesskit_node_clear_active_descendant,
        @as(NodeIdContent, 0),
        @as(NodeIdContent, 1),
        schema.nodeIdFromContent(1),
    },
    .{
        accesskit_node_aria_current,
        accesskit_node_set_aria_current,
        accesskit_node_clear_aria_current,
        @as(u8, 0),
        lastTagByte(schema.AriaCurrent),
        schema.ariaCurrentFromInt(lastTagByte(schema.AriaCurrent)).?,
    },
    .{
        accesskit_node_auto_complete,
        accesskit_node_set_auto_complete,
        accesskit_node_clear_auto_complete,
        @as(u8, 0),
        lastTagByte(schema.AutoComplete),
        schema.autoCompleteFromInt(lastTagByte(schema.AutoComplete)).?,
    },
    .{
        accesskit_node_background_color,
        accesskit_node_set_background_color,
        accesskit_node_clear_background_color,
        zeroColor(),
        sampleColor(1),
        sampleColor(1),
    },
    .{
        accesskit_node_bounds,
        accesskit_node_set_bounds,
        accesskit_node_clear_bounds,
        Rect{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },
        Rect{ .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 },
        Rect{ .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 },
    },
    .{
        accesskit_node_color_value,
        accesskit_node_set_color_value,
        accesskit_node_clear_color_value,
        zeroColor(),
        sampleColor(2),
        sampleColor(2),
    },
    .{
        accesskit_node_column_count,
        accesskit_node_set_column_count,
        accesskit_node_clear_column_count,
        @as(usize, 0),
        @as(usize, 1),
        @as(usize, 1),
    },
    .{
        accesskit_node_column_index,
        accesskit_node_set_column_index,
        accesskit_node_clear_column_index,
        @as(usize, 0),
        @as(usize, 2),
        @as(usize, 2),
    },
    .{
        accesskit_node_column_span,
        accesskit_node_set_column_span,
        accesskit_node_clear_column_span,
        @as(usize, 0),
        @as(usize, 3),
        @as(usize, 3),
    },
    .{
        accesskit_node_error_message,
        accesskit_node_set_error_message,
        accesskit_node_clear_error_message,
        @as(NodeIdContent, 0),
        @as(NodeIdContent, 2),
        schema.nodeIdFromContent(2),
    },
    .{
        accesskit_node_font_size,
        accesskit_node_set_font_size,
        accesskit_node_clear_font_size,
        @as(f32, 0),
        @as(f32, 1) + 0.5,
        @as(f32, 1) + 0.5,
    },
    .{
        accesskit_node_font_weight,
        accesskit_node_set_font_weight,
        accesskit_node_clear_font_weight,
        @as(f32, 0),
        @as(f32, 2) + 0.5,
        @as(f32, 2) + 0.5,
    },
    .{
        accesskit_node_foreground_color,
        accesskit_node_set_foreground_color,
        accesskit_node_clear_foreground_color,
        zeroColor(),
        sampleColor(3),
        sampleColor(3),
    },
    .{
        accesskit_node_has_popup,
        accesskit_node_set_has_popup,
        accesskit_node_clear_has_popup,
        @as(u8, 0),
        lastTagByte(schema.HasPopup),
        schema.hasPopupFromInt(lastTagByte(schema.HasPopup)).?,
    },
    .{
        accesskit_node_in_page_link_target,
        accesskit_node_set_in_page_link_target,
        accesskit_node_clear_in_page_link_target,
        @as(NodeIdContent, 0),
        @as(NodeIdContent, 3),
        schema.nodeIdFromContent(3),
    },
    .{
        accesskit_node_invalid,
        accesskit_node_set_invalid,
        accesskit_node_clear_invalid,
        @as(u8, 0),
        lastTagByte(schema.Invalid),
        schema.invalidFromInt(lastTagByte(schema.Invalid)).?,
    },
    .{
        accesskit_node_is_expanded,
        accesskit_node_set_expanded,
        accesskit_node_clear_expanded,
        false,
        true,
        true,
    },
    .{
        accesskit_node_is_selected,
        accesskit_node_set_selected,
        accesskit_node_clear_selected,
        false,
        false,
        false,
    },
    .{
        accesskit_node_level,
        accesskit_node_set_level,
        accesskit_node_clear_level,
        @as(usize, 0),
        @as(usize, 4),
        @as(usize, 4),
    },
    .{
        accesskit_node_list_style,
        accesskit_node_set_list_style,
        accesskit_node_clear_list_style,
        @as(u8, 0),
        lastTagByte(schema.ListStyle),
        schema.listStyleFromInt(lastTagByte(schema.ListStyle)).?,
    },
    .{
        accesskit_node_live,
        accesskit_node_set_live,
        accesskit_node_clear_live,
        @as(u8, 0),
        lastTagByte(schema.Live),
        schema.liveFromInt(lastTagByte(schema.Live)).?,
    },
    .{
        accesskit_node_max_numeric_value,
        accesskit_node_set_max_numeric_value,
        accesskit_node_clear_max_numeric_value,
        @as(f64, 0),
        @as(f64, 1) + 0.5,
        @as(f64, 1) + 0.5,
    },
    .{
        accesskit_node_member_of,
        accesskit_node_set_member_of,
        accesskit_node_clear_member_of,
        @as(NodeIdContent, 0),
        @as(NodeIdContent, 4),
        schema.nodeIdFromContent(4),
    },
    .{
        accesskit_node_min_numeric_value,
        accesskit_node_set_min_numeric_value,
        accesskit_node_clear_min_numeric_value,
        @as(f64, 0),
        @as(f64, 2) + 0.5,
        @as(f64, 2) + 0.5,
    },
    .{
        accesskit_node_next_on_line,
        accesskit_node_set_next_on_line,
        accesskit_node_clear_next_on_line,
        @as(NodeIdContent, 0),
        @as(NodeIdContent, 5),
        schema.nodeIdFromContent(5),
    },
    .{
        accesskit_node_numeric_value,
        accesskit_node_set_numeric_value,
        accesskit_node_clear_numeric_value,
        @as(f64, 0),
        @as(f64, 3) + 0.5,
        @as(f64, 3) + 0.5,
    },
    .{
        accesskit_node_numeric_value_jump,
        accesskit_node_set_numeric_value_jump,
        accesskit_node_clear_numeric_value_jump,
        @as(f64, 0),
        @as(f64, 4) + 0.5,
        @as(f64, 4) + 0.5,
    },
    .{
        accesskit_node_numeric_value_step,
        accesskit_node_set_numeric_value_step,
        accesskit_node_clear_numeric_value_step,
        @as(f64, 0),
        @as(f64, 5) + 0.5,
        @as(f64, 5) + 0.5,
    },
    .{
        accesskit_node_orientation,
        accesskit_node_set_orientation,
        accesskit_node_clear_orientation,
        @as(u8, 0),
        lastTagByte(schema.Orientation),
        schema.orientationFromInt(lastTagByte(schema.Orientation)).?,
    },
    .{
        accesskit_node_overline,
        accesskit_node_set_overline,
        accesskit_node_clear_overline,
        zeroDecoration(),
        sampleDecoration(1),
        sampleDecoration(1),
    },
    .{
        accesskit_node_popup_for,
        accesskit_node_set_popup_for,
        accesskit_node_clear_popup_for,
        @as(NodeIdContent, 0),
        @as(NodeIdContent, 6),
        schema.nodeIdFromContent(6),
    },
    .{
        accesskit_node_position_in_set,
        accesskit_node_set_position_in_set,
        accesskit_node_clear_position_in_set,
        @as(usize, 0),
        @as(usize, 5),
        @as(usize, 5),
    },
    .{
        accesskit_node_previous_on_line,
        accesskit_node_set_previous_on_line,
        accesskit_node_clear_previous_on_line,
        @as(NodeIdContent, 0),
        @as(NodeIdContent, 7),
        schema.nodeIdFromContent(7),
    },
    .{
        accesskit_node_row_count,
        accesskit_node_set_row_count,
        accesskit_node_clear_row_count,
        @as(usize, 0),
        @as(usize, 6),
        @as(usize, 6),
    },
    .{
        accesskit_node_row_index,
        accesskit_node_set_row_index,
        accesskit_node_clear_row_index,
        @as(usize, 0),
        @as(usize, 7),
        @as(usize, 7),
    },
    .{
        accesskit_node_row_span,
        accesskit_node_set_row_span,
        accesskit_node_clear_row_span,
        @as(usize, 0),
        @as(usize, 8),
        @as(usize, 8),
    },
    .{
        accesskit_node_scroll_x,
        accesskit_node_set_scroll_x,
        accesskit_node_clear_scroll_x,
        @as(f64, 0),
        @as(f64, 6) + 0.5,
        @as(f64, 6) + 0.5,
    },
    .{
        accesskit_node_scroll_x_max,
        accesskit_node_set_scroll_x_max,
        accesskit_node_clear_scroll_x_max,
        @as(f64, 0),
        @as(f64, 7) + 0.5,
        @as(f64, 7) + 0.5,
    },
    .{
        accesskit_node_scroll_x_min,
        accesskit_node_set_scroll_x_min,
        accesskit_node_clear_scroll_x_min,
        @as(f64, 0),
        @as(f64, 8) + 0.5,
        @as(f64, 8) + 0.5,
    },
    .{
        accesskit_node_scroll_y,
        accesskit_node_set_scroll_y,
        accesskit_node_clear_scroll_y,
        @as(f64, 0),
        @as(f64, 9) + 0.5,
        @as(f64, 9) + 0.5,
    },
    .{
        accesskit_node_scroll_y_max,
        accesskit_node_set_scroll_y_max,
        accesskit_node_clear_scroll_y_max,
        @as(f64, 0),
        @as(f64, 10) + 0.5,
        @as(f64, 10) + 0.5,
    },
    .{
        accesskit_node_scroll_y_min,
        accesskit_node_set_scroll_y_min,
        accesskit_node_clear_scroll_y_min,
        @as(f64, 0),
        @as(f64, 11) + 0.5,
        @as(f64, 11) + 0.5,
    },
    .{
        accesskit_node_size_of_set,
        accesskit_node_set_size_of_set,
        accesskit_node_clear_size_of_set,
        @as(usize, 0),
        @as(usize, 9),
        @as(usize, 9),
    },
    .{
        accesskit_node_sort_direction,
        accesskit_node_set_sort_direction,
        accesskit_node_clear_sort_direction,
        @as(u8, 0),
        lastTagByte(schema.SortDirection),
        schema.sortDirectionFromInt(lastTagByte(schema.SortDirection)).?,
    },
    .{
        accesskit_node_strikethrough,
        accesskit_node_set_strikethrough,
        accesskit_node_clear_strikethrough,
        zeroDecoration(),
        sampleDecoration(2),
        sampleDecoration(2),
    },
    .{
        accesskit_node_text_align,
        accesskit_node_set_text_align,
        accesskit_node_clear_text_align,
        @as(u8, 0),
        lastTagByte(schema.TextAlign),
        schema.textAlignFromInt(lastTagByte(schema.TextAlign)).?,
    },
    .{
        accesskit_node_text_direction,
        accesskit_node_set_text_direction,
        accesskit_node_clear_text_direction,
        @as(u8, 0),
        lastTagByte(schema.TextDirection),
        schema.textDirectionFromInt(lastTagByte(schema.TextDirection)).?,
    },
    .{
        accesskit_node_text_selection,
        accesskit_node_set_text_selection,
        accesskit_node_clear_text_selection,
        zeroSelection(),
        sampleSelection(),
        sampleSelection(),
    },
    .{
        accesskit_node_toggled,
        accesskit_node_set_toggled,
        accesskit_node_clear_toggled,
        @as(u8, 0),
        lastTagByte(schema.Toggled),
        schema.toggledFromInt(lastTagByte(schema.Toggled)).?,
    },
    .{
        accesskit_node_tree_id,
        accesskit_node_set_tree_id,
        accesskit_node_clear_tree_id,
        schema.tree_id_root,
        TreeId{ .bytes = @splat(1) },
        TreeId{ .bytes = @splat(1) },
    },
    .{
        accesskit_node_underline,
        accesskit_node_set_underline,
        accesskit_node_clear_underline,
        zeroDecoration(),
        sampleDecoration(3),
        sampleDecoration(3),
    },
    .{
        accesskit_node_vertical_offset,
        accesskit_node_set_vertical_offset,
        accesskit_node_clear_vertical_offset,
        @as(u8, 0),
        lastTagByte(schema.VerticalOffset),
        schema.verticalOffsetFromInt(lastTagByte(schema.VerticalOffset)).?,
    },
};

const optional_names = [_][]const u8{
    "accesskit_node_active_descendant",
    "accesskit_node_aria_current",
    "accesskit_node_auto_complete",
    "accesskit_node_background_color",
    "accesskit_node_bounds",
    "accesskit_node_color_value",
    "accesskit_node_column_count",
    "accesskit_node_column_index",
    "accesskit_node_column_span",
    "accesskit_node_error_message",
    "accesskit_node_font_size",
    "accesskit_node_font_weight",
    "accesskit_node_foreground_color",
    "accesskit_node_has_popup",
    "accesskit_node_in_page_link_target",
    "accesskit_node_invalid",
    "accesskit_node_is_expanded",
    "accesskit_node_is_selected",
    "accesskit_node_level",
    "accesskit_node_list_style",
    "accesskit_node_live",
    "accesskit_node_max_numeric_value",
    "accesskit_node_member_of",
    "accesskit_node_min_numeric_value",
    "accesskit_node_next_on_line",
    "accesskit_node_numeric_value",
    "accesskit_node_numeric_value_jump",
    "accesskit_node_numeric_value_step",
    "accesskit_node_orientation",
    "accesskit_node_overline",
    "accesskit_node_popup_for",
    "accesskit_node_position_in_set",
    "accesskit_node_previous_on_line",
    "accesskit_node_row_count",
    "accesskit_node_row_index",
    "accesskit_node_row_span",
    "accesskit_node_scroll_x",
    "accesskit_node_scroll_x_max",
    "accesskit_node_scroll_x_min",
    "accesskit_node_scroll_y",
    "accesskit_node_scroll_y_max",
    "accesskit_node_scroll_y_min",
    "accesskit_node_size_of_set",
    "accesskit_node_sort_direction",
    "accesskit_node_strikethrough",
    "accesskit_node_text_align",
    "accesskit_node_text_direction",
    "accesskit_node_text_selection",
    "accesskit_node_toggled",
    "accesskit_node_tree_id",
    "accesskit_node_underline",
    "accesskit_node_vertical_offset",
};

/// The eight node-identifier lists: a getter, the setter that copies a whole
/// array in, and the clearer.
const node_list_rows = .{
    .{ accesskit_node_children, accesskit_node_set_children, accesskit_node_clear_children },
    .{ accesskit_node_controls, accesskit_node_set_controls, accesskit_node_clear_controls },
    .{
        accesskit_node_described_by,
        accesskit_node_set_described_by,
        accesskit_node_clear_described_by,
    },
    .{ accesskit_node_details, accesskit_node_set_details, accesskit_node_clear_details },
    .{ accesskit_node_flow_to, accesskit_node_set_flow_to, accesskit_node_clear_flow_to },
    .{
        accesskit_node_labelled_by,
        accesskit_node_set_labelled_by,
        accesskit_node_clear_labelled_by,
    },
    .{ accesskit_node_owns, accesskit_node_set_owns, accesskit_node_clear_owns },
    .{
        accesskit_node_radio_group,
        accesskit_node_set_radio_group,
        accesskit_node_clear_radio_group,
    },
};

/// The two `accesskit_lengths` properties, in the same three-column shape.
const length_rows = .{
    .{
        accesskit_node_character_lengths,
        accesskit_node_set_character_lengths,
        accesskit_node_clear_character_lengths,
    },
    .{
        accesskit_node_word_starts,
        accesskit_node_set_word_starts,
        accesskit_node_clear_word_starts,
    },
};

/// The two coordinate lists, in the same three-column shape.
const coord_rows = .{
    .{
        accesskit_node_character_positions,
        accesskit_node_set_character_positions,
        accesskit_node_clear_character_positions,
    },
    .{
        accesskit_node_character_widths,
        accesskit_node_set_character_widths,
        accesskit_node_clear_character_widths,
    },
};

/// The 21 string properties, in the same three-column shape.
const string_rows = .{
    .{ accesskit_node_access_key, accesskit_node_set_access_key, accesskit_node_clear_access_key },
    .{ accesskit_node_author_id, accesskit_node_set_author_id, accesskit_node_clear_author_id },
    .{
        accesskit_node_braille_label,
        accesskit_node_set_braille_label,
        accesskit_node_clear_braille_label,
    },
    .{
        accesskit_node_braille_role_description,
        accesskit_node_set_braille_role_description,
        accesskit_node_clear_braille_role_description,
    },
    .{ accesskit_node_class_name, accesskit_node_set_class_name, accesskit_node_clear_class_name },
    .{
        accesskit_node_column_index_text,
        accesskit_node_set_column_index_text,
        accesskit_node_clear_column_index_text,
    },
    .{
        accesskit_node_description,
        accesskit_node_set_description,
        accesskit_node_clear_description,
    },
    .{
        accesskit_node_font_family,
        accesskit_node_set_font_family,
        accesskit_node_clear_font_family,
    },
    .{ accesskit_node_html_id, accesskit_node_set_html_id, accesskit_node_clear_html_id },
    .{ accesskit_node_html_tag, accesskit_node_set_html_tag, accesskit_node_clear_html_tag },
    .{ accesskit_node_inner_html, accesskit_node_set_inner_html, accesskit_node_clear_inner_html },
    .{
        accesskit_node_keyboard_shortcut,
        accesskit_node_set_keyboard_shortcut,
        accesskit_node_clear_keyboard_shortcut,
    },
    .{ accesskit_node_label, accesskit_node_set_label, accesskit_node_clear_label },
    .{ accesskit_node_language, accesskit_node_set_language, accesskit_node_clear_language },
    .{
        accesskit_node_placeholder,
        accesskit_node_set_placeholder,
        accesskit_node_clear_placeholder,
    },
    .{
        accesskit_node_role_description,
        accesskit_node_set_role_description,
        accesskit_node_clear_role_description,
    },
    .{
        accesskit_node_row_index_text,
        accesskit_node_set_row_index_text,
        accesskit_node_clear_row_index_text,
    },
    .{
        accesskit_node_state_description,
        accesskit_node_set_state_description,
        accesskit_node_clear_state_description,
    },
    .{ accesskit_node_tooltip, accesskit_node_set_tooltip, accesskit_node_clear_tooltip },
    .{ accesskit_node_url, accesskit_node_set_url, accesskit_node_clear_url },
    .{ accesskit_node_value, accesskit_node_set_value, accesskit_node_clear_value },
};

/// The eight node-identifier pushers and the list each one appends to.
const push_rows = .{
    .{ accesskit_node_children, accesskit_node_push_child, accesskit_node_clear_children },
    .{ accesskit_node_controls, accesskit_node_push_controlled, accesskit_node_clear_controls },
    .{
        accesskit_node_described_by,
        accesskit_node_push_described_by,
        accesskit_node_clear_described_by,
    },
    .{ accesskit_node_details, accesskit_node_push_detail, accesskit_node_clear_details },
    .{ accesskit_node_flow_to, accesskit_node_push_flow_to, accesskit_node_clear_flow_to },
    .{
        accesskit_node_labelled_by,
        accesskit_node_push_labelled_by,
        accesskit_node_clear_labelled_by,
    },
    .{ accesskit_node_owns, accesskit_node_push_owned, accesskit_node_clear_owns },
    .{
        accesskit_node_radio_group,
        accesskit_node_push_to_radio_group,
        accesskit_node_clear_radio_group,
    },
};

/// The three identifiers the node-identifier tests copy in.
const sample_ids = [_]NodeId{.{ .value = 11 }};

/// The two byte lengths the `accesskit_lengths` tests copy in.
const sample_bytes = [_]u8{ 3, 4 };

/// The two measurements the coordinate-list tests copy in.
const sample_coords = [_]f32{ 1.5, 2.5 };

/// The empty arrays a list setter takes with `length` 0, which
/// `include/zaccesskit.h:2326` allows for the node-identifier lists and `:4459`
/// and `:4524` allow for the byte and measurement lists. The header says a null
/// pointer is allowed there; an empty array is the same zero-length read with an
/// address the C type can name.
const no_node_ids: [*]const NodeId = sample_ids[0..0].ptr;
const no_measurements: [*c]const f32 = sample_coords[0..0].ptr;
const empty_actions: [0]?*CustomAction = .{};
const no_actions: [*c]const ?*CustomAction = empty_actions[0..].ptr;

/// A caller-supplied action array as the `accesskit_custom_action *const *` the
/// header declares.
fn cActions(array: []const ?*CustomAction) [*c]const ?*CustomAction {
    return @ptrCast(array.ptr);
}

/// A custom action built the way a C caller builds one.
///
/// `src/capi/action_request.zig` builds the same value in
/// `accesskit_custom_action_new` and its release in
/// `accesskit_custom_action_free`, and neither half is `pub`, so a test here
/// reaches the schema type directly rather than across that boundary. The block
/// comes from the declared allocator because that is the only allocator
/// `accesskit_node_push_custom_action` and `accesskit_custom_action_free` release
/// it through: a handle built anywhere else would be freed through the wrong
/// pair the moment ownership moved.
fn newAction(id: c_int, description: [:0]const u8) !*CustomAction {
    const gpa = allocation.allocator();
    const handle = try gpa.create(CustomAction);
    errdefer gpa.destroy(handle);
    handle.* = try CustomAction.init(gpa, id, description);
    return handle;
}

/// Releases an action `newAction` built, which is what the C caller does with
/// `accesskit_custom_action_free`.
fn releaseAction(gpa: std.mem.Allocator, action: *CustomAction) void {
    action.deinit(gpa);
    gpa.destroy(action);
}

test "the signature table names all 294 node declarations by family" {
    // The `comptime` block above is the per-row signature check. This is the
    // census: a declaration implemented without a row, and a row written for a
    // declaration that is not there, each move one of these numbers. No
    // distinctness sweep is needed here, because Zig already rejects two
    // `export fn` of one name as a duplicate declaration rather than leaving it
    // to the link.
    try testing.expectEqual(@as(usize, 294), export_signatures.len);
    try testing.expectEqual(@as(usize, 1), countFamily("accesskit_node_new"));
    try testing.expectEqual(@as(usize, 1), countFamily("accesskit_node_free"));
    try testing.expectEqual(@as(usize, 1), countFamily("accesskit_node_debug"));
    try testing.expectEqual(@as(usize, 9), countFamily("accesskit_node_push_"));
    try testing.expectEqual(@as(usize, 87), countFamily("accesskit_node_clear_"));
    try testing.expectEqual(@as(usize, 2), countFamily("accesskit_node_is_"));
    try testing.expectEqual(@as(usize, 108), countFamily("accesskit_node_set_"));
}

// Test callers encode the canonical logical input independently of decodeArg.
fn optionalTestSet(comptime setter: anytype, handle: *handles.accesskit_node, value: anytype) void {
    const Value = @TypeOf(value);
    if (dense_optional_return and Value == TreeId) {
        const words: powerpc_abi.TreeIdValue = .{
            .first = std.mem.readInt(u64, value.bytes[0..8], .big),
            .second = std.mem.readInt(u64, value.bytes[8..16], .big),
        };
        setter(handle, words);
    } else if (dense_optional_return and (Value == Color or Value == TextDecoration)) {
        const color = if (Value == Color) value else value.color;
        const bytes = [4]u8{ color.red, color.green, color.blue, color.alpha };
        const payload: u64 = std.mem.readInt(u32, &bytes, .big);
        const encoded = if (Value == Color) payload else (@as(u64, @backingInt(value.style)) << 32) | payload;
        setter(handle, encoded);
    } else {
        setter(handle, value);
    }
}

// Decode the getter's actual return, using the row's independently declared
// logical value type rather than the implementation's canonical conversion.
fn optionalTestRead(comptime Value: type, answer: anytype) struct {
    has_value: bool,
    value: Value,
} {
    if (@TypeOf(answer) == DenseReturn) {
        return .{
            .has_value = answer.first != 0,
            .value = if (Value == NodeId)
                .{ .value = answer.second }
            else if (Value == f64)
                @bitCast(answer.second)
            else
                @intCast(answer.second),
        };
    }
    if (@TypeOf(answer) == u16) {
        const byte: u8 = @truncate(answer);
        return .{
            .has_value = answer >> 8 != 0,
            .value = if (Value == bool) byte != 0 else @fromBackingInt(@intCast(byte)),
        };
    }
    if (@TypeOf(answer) == u64) {
        if (Value == f32) {
            return .{ .has_value = answer >> 56 != 0, .value = @bitCast(@as(u32, @truncate(answer))) };
        }
        const color: Color = .{
            .red = @truncate(answer >> 24),
            .green = @truncate(answer >> 16),
            .blue = @truncate(answer >> 8),
            .alpha = @truncate(answer),
        };
        if (Value == Color) return .{ .has_value = answer >> 32 != 0, .value = color };
        return .{
            .has_value = answer >> 40 != 0,
            .value = .{ .style = @fromBackingInt(@intCast(@as(u8, @truncate(answer >> 32)))), .color = color },
        };
    }
    return .{ .has_value = answer.has_value, .value = answer.value };
}

fn optionalTestBytes(comptime Value: type, answer: anytype) []const u8 {
    const bytes = std.mem.asBytes(answer);
    if (@TypeOf(answer.*) == u64) {
        // C right-justifies the five/six-byte aggregate inside the register.
        if (Value == Color) return bytes[3..8];
        if (Value == TextDecoration) return bytes[2..8];
    }
    return bytes;
}

test "an unset optional reads as a flag byte over a zero, and a set zero is one byte from it" {
    // The absence convention, for all 52. A getter for a property nothing set
    // reports `has_value` false, its setter writes the zero and the getter then
    // reports `has_value` true, and the only byte that differs between the two
    // answers is the flag at offset 0. That last part is the half usually
    // missing: a reader who reads the flag cannot confuse a legitimate zero with
    // an absence, and a reader who does not reads a defined zero rather than
    // uninitialised storage.
    const gpa = testing.allocator;
    inline for (optional_rows, optional_names) |row, name| {
        // Each row's getter has its own return type, and the offsets below are
        // that type's own, which is the only reason this is `inline for`.
        const answer_type = @typeInfo(@TypeOf(row[0])).@"fn".return_type.?;
        const fixture = try Fixture.init(gpa, .button);
        defer fixture.deinit(gpa);

        const absent = row[0](fixture.handle);
        try testing.expect(!optionalTestRead(@TypeOf(row[5]), absent).has_value);

        optionalTestSet(row[1], fixture.handle, row[3]);
        const present = row[0](fixture.handle);
        try testing.expect(optionalTestRead(@TypeOf(row[5]), present).has_value);
        if (answer_type == DenseReturn) {
            // Independent C-layout metadata: bool byte 0, payload byte 8.
            try testing.expectEqual(@as(u64, 0), absent.first);
            try testing.expectEqual(@as(u64, 0), absent.second);
            try testing.expectEqual(@as(u64, 0x0100000000000000), present.first);
        }
        if (answer_type == u16) {
            try testing.expectEqual(@as(u16, 0), absent);
            try testing.expectEqual(@as(u16, 0x0100), present);
        }
        if (answer_type == u64) {
            const shift = if (@TypeOf(row[5]) == f32) 56 else if (@TypeOf(row[5]) == Color) 32 else 40;
            try testing.expectEqual(@as(u64, 0), absent);
            try testing.expectEqual(@as(u64, 1) << shift, present);
        }

        const before = optionalTestBytes(@TypeOf(row[5]), &absent);
        const after = optionalTestBytes(@TypeOf(row[5]), &present);
        testing.expect(before[0] != after[0]) catch {
            std.debug.print("{s} reads the same either way\n", .{name});
            return error.ZeroEqualsAbsent;
        };

        // Over the payload field and not over the whole struct, because five of
        // the twenty-five forms carry an 8-aligned payload after a one-byte flag
        // and so have seven padding bytes between them. Nothing writes those, and
        // the header promises nothing about them: `accesskit_opt_node_id` at
        // `include/zaccesskit.h:1069-1072` declares `bool has_value` then
        // `accesskit_node_id value`, and C puts the value at offset 8. Comparing
        // the whole struct would compare storage no reader is told to read.
        const payload_start = if (answer_type == DenseReturn)
            8
        else if (answer_type == u16)
            1
        else if (answer_type == u64)
            (if (@TypeOf(row[5]) == f32) 4 else 1)
        else
            @offsetOf(answer_type, "value");
        const payload_len = @sizeOf(@TypeOf(row[5]));
        try testing.expect(payload_start > 0);
        testing.expectEqualSlices(
            u8,
            before[payload_start..][0..payload_len],
            after[payload_start..][0..payload_len],
        ) catch {
            std.debug.print("{s} leaves a payload byte changed\n", .{name});
            return error.ZeroEqualsAbsent;
        };

        try testing.expect(allocation.lastError() == .none);
    }
}

test "eight-byte optional getters preserve high integers and exact floating-point bits" {
    // Exercise actual setters and exports, not only the return conversion.
    const gpa = testing.allocator;
    const fixture = try Fixture.init(gpa, .button);
    defer fixture.deinit(gpa);
    const double_bits = [_]u64{
        0x0000000000000000,
        0x8000000000000000,
        0x7ff0000000000000,
        0xfff0000000000000,
        0x7ff8123456789abc,
        0xfff8123456789abc,
        0x0000000000000001,
        0x7fefffffffffffff,
    };
    inline for (optional_rows) |row| {
        const Value = @TypeOf(row[5]);
        if (Value == f64) {
            for (double_bits) |bits| {
                optionalTestSet(row[1], fixture.handle, @as(f64, @bitCast(bits)));
                const answer = row[0](fixture.handle);
                const logical = optionalTestRead(Value, answer);
                try testing.expect(logical.has_value);
                try testing.expectEqual(bits, @as(u64, @bitCast(logical.value)));
                if (@TypeOf(answer) == DenseReturn) {
                    try testing.expectEqual(@as(u64, 0x0100000000000000), answer.first);
                    try testing.expectEqual(bits, answer.second);
                }
            }
        } else if (Value == NodeId or Value == usize) {
            const Input = @TypeOf(row[4]);
            const maximum = std.math.maxInt(Input);
            optionalTestSet(row[1], fixture.handle, maximum);
            const answer = row[0](fixture.handle);
            const logical = optionalTestRead(Value, answer);
            try testing.expect(logical.has_value);
            const content = if (Value == NodeId) logical.value.value else logical.value;
            try testing.expectEqual(maximum, content);
            if (@TypeOf(answer) == DenseReturn) {
                try testing.expectEqual(@as(u64, 0x0100000000000000), answer.first);
                try testing.expectEqual(@as(u64, maximum), answer.second);
            }
        }
        try testing.expect(allocation.lastError() == .none);
    }
}

test "optional exports retain all tags, byte order and exact float bits" {
    // Every row reaches its actual setter/getter pair. The expected values come
    // from the schema domain and input vectors, not the private return encoder.
    const gpa = testing.allocator;
    const fixture = try Fixture.init(gpa, .button);
    defer fixture.deinit(gpa);
    const float_bits = [_]u32{
        0x00000000, 0x80000000, 0x7f800000, 0xff800000,
        0x7fc12345, 0xffc12345, 0x00000001, 0x7f7fffff,
    };
    const colors = [_]Color{
        .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 },
        .{ .red = 255, .green = 255, .blue = 255, .alpha = 255 },
        .{ .red = 1, .green = 2, .blue = 3, .alpha = 4 },
        .{ .red = 255, .green = 128, .blue = 64, .alpha = 32 },
    };
    inline for (optional_rows) |row| {
        const Value = @TypeOf(row[5]);
        if (Value == f32) {
            for (float_bits) |bits| {
                optionalTestSet(row[1], fixture.handle, @as(f32, @bitCast(bits)));
                const logical = optionalTestRead(Value, row[0](fixture.handle));
                try testing.expect(logical.has_value);
                try testing.expectEqual(bits, @as(u32, @bitCast(logical.value)));
            }
        } else if (Value == Color) {
            for (colors) |color| {
                optionalTestSet(row[1], fixture.handle, color);
                const logical = optionalTestRead(Value, row[0](fixture.handle));
                try testing.expect(logical.has_value);
                try testing.expectEqual(color, logical.value);
            }
        } else if (Value == TextDecoration) {
            inline for (@typeInfo(schema.TextDecorationStyle).@"enum".field_values) |style_value| {
                for (colors) |color| {
                    const expected: TextDecoration = .{
                        .style = @fromBackingInt(@intCast(style_value)),
                        .color = color,
                    };
                    optionalTestSet(row[1], fixture.handle, expected);
                    const logical = optionalTestRead(Value, row[0](fixture.handle));
                    try testing.expect(logical.has_value);
                    try testing.expectEqual(expected, logical.value);
                }
            }
        } else if (Value == TreeId) {
            for ([_]u8{ 0, 1, 0x80, 0xff }) |seed| {
                const expected: TreeId = .{
                    .bytes = .{ seed, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, seed ^ 0xff },
                };
                optionalTestSet(row[1], fixture.handle, expected);
                const logical = optionalTestRead(Value, row[0](fixture.handle));
                try testing.expect(logical.has_value);
                try testing.expectEqualSlices(u8, &expected.bytes, &logical.value.bytes);
            }
        } else if (Value == bool) {
            for ([_]bool{ false, true }) |value| {
                optionalTestSet(row[1], fixture.handle, value);
                const logical = optionalTestRead(Value, row[0](fixture.handle));
                try testing.expect(logical.has_value);
                try testing.expectEqual(value, logical.value);
            }
        } else if (@typeInfo(Value) == .@"enum") {
            inline for (@typeInfo(Value).@"enum".field_values) |tag_value| {
                optionalTestSet(row[1], fixture.handle, @as(u8, @intCast(tag_value)));
                const logical = optionalTestRead(Value, row[0](fixture.handle));
                try testing.expect(logical.has_value);
                try testing.expectEqual(@as(Value, @fromBackingInt(@intCast(tag_value))), logical.value);
            }
        }
        row[2](fixture.handle);
        try testing.expect(!optionalTestRead(Value, row[0](fixture.handle)).has_value);
        try testing.expect(allocation.lastError() == .none);
    }
}

test "every optional getter reads the property its own setter wrote" {
    // The mis-wiring test. One node carries all 52 properties at once, each
    // written with a value no other row writes, and each getter is then asked
    // for its own. A getter that reached a neighbour's accessor answers another
    // row's number here and nowhere else, because on a node with nothing set
    // every optional reads absent.
    const gpa = testing.allocator;
    const fixture = try Fixture.init(gpa, .button);
    defer fixture.deinit(gpa);

    inline for (optional_rows) |row| {
        optionalTestSet(row[1], fixture.handle, row[4]);
    }
    inline for (optional_rows) |row| {
        const read = optionalTestRead(@TypeOf(row[5]), row[0](fixture.handle));
        try testing.expect(read.has_value);
        try testing.expectEqual(row[5], read.value);
    }
}

test "a cleared property reads absent again, for all 52 optionals" {
    // The clearer is the only name a C caller cannot reach with a setter and a
    // zero, and the store holds no sentinel: a cleared property leaves the slice
    // rather than becoming a zero. So a clear and a never-set are the same
    // answer, and both differ from a set zero.
    const gpa = testing.allocator;
    inline for (optional_rows) |row| {
        const fixture = try Fixture.init(gpa, .button);
        defer fixture.deinit(gpa);

        optionalTestSet(row[1], fixture.handle, row[3]);
        try testing.expect(optionalTestRead(@TypeOf(row[5]), row[0](fixture.handle)).has_value);

        row[2](fixture.handle);
        try testing.expect(!optionalTestRead(@TypeOf(row[5]), row[0](fixture.handle)).has_value);
        try testing.expect(allocation.lastError() == .none);
    }
}

test "a node-identifier list has no flag, so absent and set-empty read the same" {
    // The one accessor shape where a legitimate zero is *not* distinguishable
    // from absent, and the header says so on each of the eight. It is upstream's
    // shape too: a missing value reads as an empty slice
    // (`accesskit/src/lib.rs:1234-1243`). What a reader can distinguish is a
    // non-empty list, so that is what this asserts on both sides.
    const gpa = testing.allocator;
    inline for (node_list_rows) |row| {
        const fixture = try Fixture.init(gpa, .button);
        defer fixture.deinit(gpa);

        const unset = row[0](fixture.handle);
        try testing.expectEqual(@as(usize, 0), unset.length);
        try testing.expect(unset.values != null);

        row[1](fixture.handle, 0, no_node_ids);
        const emptied = row[0](fixture.handle);
        try testing.expectEqual(@as(usize, 0), emptied.length);
        try testing.expect(emptied.values != null);

        row[1](fixture.handle, 1, &sample_ids);
        const filled = row[0](fixture.handle);
        try testing.expectEqual(@as(usize, 1), filled.length);
        try testing.expectEqual(@as(NodeIdContent, 11), filled.values[0].value);

        row[2](fixture.handle);
        try testing.expectEqual(@as(usize, 0), row[0](fixture.handle).length);
        try testing.expect(allocation.lastError() == .none);
    }
}

test "each node-identifier pusher appends to its own list and only that one" {
    // The pusher is the only writer that grows a list in place. Every pusher
    // appends to a different property, so pushing through one and reading
    // another is what catches a pusher wired to a neighbour.
    const gpa = testing.allocator;
    const fixture = try Fixture.init(gpa, .button);
    defer fixture.deinit(gpa);

    inline for (push_rows) |row| {
        row[1](fixture.handle, 5);
    }
    inline for (push_rows) |row| {
        const read = row[0](fixture.handle);
        try testing.expectEqual(@as(usize, 1), read.length);
        try testing.expectEqual(@as(NodeIdContent, 5), read.values[0].value);
    }
    // A push after a clear starts a fresh list rather than resurrecting the old
    // one, which is upstream's 0.25.0 fix at `accesskit/src/lib.rs:1359-1365`.
    accesskit_node_clear_children(fixture.handle);
    accesskit_node_push_child(fixture.handle, 6);
    try testing.expectEqual(@as(usize, 1), accesskit_node_children(fixture.handle).length);
    try testing.expect(allocation.lastError() == .none);
}

test "a byte-length list reports a non-null pointer for an unset property" {
    // The same two-shape promise the node-identifier lists make, for the two
    // `accesskit_lengths` getters.
    const gpa = testing.allocator;
    inline for (length_rows) |row| {
        const fixture = try Fixture.init(gpa, .button);
        defer fixture.deinit(gpa);

        const unset = row[0](fixture.handle);
        try testing.expectEqual(@as(usize, 0), unset.length);
        try testing.expect(unset.values != null);

        row[1](fixture.handle, 2, &sample_bytes);
        const filled = row[0](fixture.handle);
        try testing.expectEqual(@as(usize, 2), filled.length);
        try testing.expectEqual(@as(u8, 3), filled.values[0]);
        try testing.expectEqual(@as(u8, 4), filled.values[1]);

        row[2](fixture.handle);
        try testing.expectEqual(@as(usize, 0), row[0](fixture.handle).length);
        try testing.expect(allocation.lastError() == .none);
    }
}

test "a coordinate list is the one optional whose absent value is an empty list" {
    // `include/zaccesskit.h:1229-1246` and `:4513-4516`. The flag is false with
    // `length == 0` and a non-null `values`, so a reader that ignores the flag
    // reads an empty list rather than dereferences nothing. A set empty list
    // differs from an absent one in the flag byte and nowhere else.
    const gpa = testing.allocator;
    inline for (coord_rows) |row| {
        const fixture = try Fixture.init(gpa, .button);
        defer fixture.deinit(gpa);

        const absent = row[0](fixture.handle);
        try testing.expect(!absent.has_value);
        try testing.expectEqual(@as(usize, 0), absent.length);
        try testing.expect(absent.values != null);

        row[1](fixture.handle, 0, no_measurements);
        const present = row[0](fixture.handle);
        try testing.expect(present.has_value);
        try testing.expectEqual(@as(usize, 0), present.length);
        try testing.expect(std.mem.asBytes(&absent)[0] != std.mem.asBytes(&present)[0]);

        row[1](fixture.handle, 2, &sample_coords);
        const filled = row[0](fixture.handle);
        try testing.expect(filled.has_value);
        try testing.expectEqual(@as(usize, 2), filled.length);
        try testing.expectEqual(@as(f32, 1.5), filled.values[0]);

        row[2](fixture.handle);
        try testing.expect(!row[0](fixture.handle).has_value);
        try testing.expect(allocation.lastError() == .none);
    }
}

test "a string getter answers null for unset and one zero byte for a set empty string" {
    // The 21 strings, and the two answers a `char *` has to keep apart. An unset
    // property and a failed copy both answer null and the failure tag separates
    // them; a set empty string answers a pointer to a single zero byte, which is
    // the `Some("")` upstream keeps distinct from `None`
    // (`accesskit-c/src/lib.rs:217-218`).
    const gpa = testing.allocator;
    inline for (string_rows) |row| {
        const fixture = try Fixture.init(gpa, .button);
        defer fixture.deinit(gpa);

        try testing.expect(row[0](fixture.handle) == null);
        try testing.expect(allocation.lastError() == .none);

        row[1](fixture.handle, cText(""));
        const empty = row[0](fixture.handle) orelse return error.GetterAnsweredNull;
        defer releaseCString(empty);
        try testing.expectEqual(@as(usize, 0), span(empty).len);

        row[1](fixture.handle, cText("value"));
        const filled = row[0](fixture.handle) orelse return error.GetterAnsweredNull;
        defer releaseCString(filled);
        try testing.expectEqualStrings("value", span(filled));

        row[2](fixture.handle);
        try testing.expect(row[0](fixture.handle) == null);
        try testing.expect(allocation.lastError() == .none);
    }
}

test "a byte string holding an interior NUL comes back cut at the first one" {
    // The rule the twenty `_with_length` setters state, and the reason
    // `accesskit_string_free` is sound: the release finds the length with
    // `std.mem.span`, so a copy keeping a byte past a NUL would be freed at the
    // wrong length.
    const gpa = testing.allocator;
    const fixture = try Fixture.init(gpa, .button);
    defer fixture.deinit(gpa);

    accesskit_node_set_label_with_length(fixture.handle, "ab\x00cd".ptr, 5);
    const copy = accesskit_node_label(fixture.handle) orelse return error.GetterAnsweredNull;
    defer releaseCString(copy);
    try testing.expectEqualStrings("ab", span(copy));
    try testing.expect(allocation.lastError() == .none);
}

test "the transform getter answers null for unset and borrows the node's own coefficients" {
    // The one pointer-returning property accessor. Absent is null, which is the
    // header's answer once its `has_value` sentence is read as the copy-paste it
    // is, and the value it returns is the node's own storage rather than a copy,
    // because the store holds the six coefficients inline.
    const gpa = testing.allocator;
    const fixture = try Fixture.init(gpa, .button);
    defer fixture.deinit(gpa);

    try testing.expect(accesskit_node_transform(fixture.handle) == null);

    const wanted: Affine = .{ .coeffs = .{ 2, 0, 0, 3, 4, 5 } };
    accesskit_node_set_transform(fixture.handle, wanted);
    const read = accesskit_node_transform(fixture.handle) orelse return error.GetterAnsweredNull;
    try testing.expectEqualSlices(f64, &wanted.coeffs, &read.coeffs);
    // Two reads answer the same address, which is what makes this a borrow of
    // the node's own storage rather than a fresh copy per call, and which is why
    // there is nothing to release. The store's payload is a separate heap block,
    // so there is no address range inside the node this can be checked against.
    const again = accesskit_node_transform(fixture.handle) orelse return error.GetterAnsweredNull;
    try testing.expectEqual(@intFromPtr(read), @intFromPtr(again));

    accesskit_node_clear_transform(fixture.handle);
    try testing.expect(accesskit_node_transform(fixture.handle) == null);
    try testing.expect(allocation.lastError() == .none);
}

test "the custom-actions getter answers an owned list, an empty one included" {
    // `include/zaccesskit.h:5089` requires `length == 0` rather than a null
    // result for an empty list, and every action in the result is a copy the
    // caller releases with `accesskit_custom_actions_free`. Nothing in the
    // result borrows from the node, so the node may go first.
    var channel: CountingPair = .{ .inner = testing.allocator };
    defer channel.release();
    channel.install();
    defer CountingPair.restore();

    const handle = accesskit_node_new(18) orelse return error.NodeNewFailed;
    defer accesskit_node_free(handle);

    const gpa = allocation.allocator();
    const empty = accesskit_node_custom_actions(handle) orelse return error.GetterAnsweredNull;
    try testing.expectEqual(@as(usize, 0), empty.length);
    try testing.expect(empty.values != null);
    marshal.custom_actions_deinit(gpa, empty);

    const first = try newAction(7, "Delete");
    accesskit_node_push_custom_action(handle, first);
    const second = try newAction(8, "Copy");
    accesskit_node_push_custom_action(handle, second);

    // The push took ownership, so the two handles are the node's now and the
    // test must not release them. The node's own copies are what the getter
    // answers.
    const listed = accesskit_node_custom_actions(handle) orelse return error.GetterAnsweredNull;
    try testing.expectEqual(@as(usize, 2), listed.length);
    try testing.expectEqual(@as(c_int, 7), listed.values[0].?.id);
    try testing.expectEqualStrings("Delete", listed.values[0].?.description.items);
    try testing.expectEqual(@as(c_int, 8), listed.values[1].?.id);
    marshal.custom_actions_deinit(gpa, listed);

    accesskit_node_clear_custom_actions(handle);
    const after = accesskit_node_custom_actions(handle) orelse return error.GetterAnsweredNull;
    try testing.expectEqual(@as(usize, 0), after.length);
    marshal.custom_actions_deinit(gpa, after);
    try testing.expect(allocation.lastError() == .none);
}

test "set_custom_actions copies the array and leaves the caller's handles alone" {
    // The header says this takes ownership of nothing. The node holds copies, so
    // the caller's two handles are still theirs afterwards and still release once
    // each. Releasing them twice, or not at all, is a double free or a leak, and
    // the counting pair reports both.
    var channel: CountingPair = .{ .inner = testing.allocator };
    defer channel.release();
    channel.install();
    defer CountingPair.restore();

    const handle = accesskit_node_new(18) orelse return error.NodeNewFailed;
    defer accesskit_node_free(handle);
    const gpa = allocation.allocator();

    const first = try newAction(1, "One");
    defer releaseAction(gpa, first);
    const second = try newAction(2, "Two");
    defer releaseAction(gpa, second);
    const array = [_]?*CustomAction{ first, second };

    accesskit_node_set_custom_actions(handle, array.len, cActions(&array));
    const listed = accesskit_node_custom_actions(handle) orelse return error.GetterAnsweredNull;
    defer marshal.custom_actions_deinit(gpa, listed);
    try testing.expectEqual(@as(usize, 2), listed.length);
    try testing.expectEqual(@as(c_int, 1), listed.values[0].?.id);
    try testing.expectEqualStrings("One", listed.values[0].?.description.items);
    // A copy, not the caller's own handle: the two must be different addresses,
    // because releasing the caller's handle must not touch what the node stores.
    try testing.expect(listed.values[0].? != first);
    try testing.expect(allocation.lastError() == .none);
}

test "set_custom_actions copies the descriptions, so the caller's handles stay their own" {
    // The address check in the test above cannot tell a copied description from
    // a shared one, because this layer clones the caller's actions before the
    // store sees them. What separates the two is what the caller may do with its
    // own handles afterwards: write through them, and the node's list must not
    // change; release them, and the node's list must still read. A boundary that
    // handed the caller's buffers to the property fails both.
    var channel: CountingPair = .{ .inner = testing.allocator };
    defer channel.release();
    channel.install();
    defer CountingPair.restore();

    const handle = accesskit_node_new(18) orelse return error.NodeNewFailed;
    defer accesskit_node_free(handle);
    const gpa = allocation.allocator();

    const first = try newAction(1, "One");
    const second = try newAction(2, "Two");
    const array = [_]?*CustomAction{ first, second };

    accesskit_node_set_custom_actions(handle, array.len, cActions(&array));
    const listed = accesskit_node_custom_actions(handle) orelse return error.GetterAnsweredNull;
    defer marshal.custom_actions_deinit(gpa, listed);
    try testing.expectEqual(@as(usize, 2), listed.length);
    try testing.expectEqualSlices(u8, "One", listed.values[0].?.description.items);
    try testing.expectEqualSlices(u8, "Two", listed.values[1].?.description.items);

    // Neither the handles nor the bytes behind them are the node's to read, so
    // writing through them changes nothing the node answers with.
    first.description.items[0] = 'Z';
    second.description.items[0] = 'Z';
    try testing.expectEqualSlices(u8, "One", listed.values[0].?.description.items);
    try testing.expectEqualSlices(u8, "Two", listed.values[1].?.description.items);

    // The header takes ownership of nothing, so the caller releases both it
    // built, once each, and the node's list reads back whole.
    releaseAction(gpa, first);
    releaseAction(gpa, second);
    try testing.expectEqual(@as(c_int, 1), listed.values[0].?.id);
    try testing.expectEqualSlices(u8, "One", listed.values[0].?.description.items);
    try testing.expectEqual(@as(c_int, 2), listed.values[1].?.id);
    try testing.expectEqualSlices(u8, "Two", listed.values[1].?.description.items);
    try testing.expect(allocation.lastError() == .none);
}

test "a null slot leaves the custom-action list untouched" {
    // A caller precondition the header does not describe, answered as ruling 4 of
    // `src/capi/node.zig` answers the out-of-range byte: the whole call changes
    // nothing and the tag stays `.none`.
    var channel: CountingPair = .{ .inner = testing.allocator };
    defer channel.release();
    channel.install();
    defer CountingPair.restore();

    const handle = accesskit_node_new(18) orelse return error.NodeNewFailed;
    defer accesskit_node_free(handle);
    const gpa = allocation.allocator();

    const pushed = try newAction(3, "Three");
    accesskit_node_push_custom_action(handle, pushed);
    const held = try newAction(4, "Four");
    defer releaseAction(gpa, held);
    const array = [_]?*CustomAction{ held, null };

    accesskit_node_set_custom_actions(handle, array.len, cActions(&array));
    const listed = accesskit_node_custom_actions(handle) orelse return error.GetterAnsweredNull;
    defer marshal.custom_actions_deinit(gpa, listed);
    try testing.expectEqual(@as(usize, 1), listed.length);
    try testing.expectEqual(@as(c_int, 3), listed.values[0].?.id);
    try testing.expect(allocation.lastError() == .none);
}

test "an out-of-range enumeration byte and an out-of-range role byte change nothing" {
    // Ruling 4, for the two gates this file owns: a byte past the last tag is a
    // caller precondition, and `accesskit_error` cannot name that case, so the
    // export leaves the property alone and the tag `.none`.
    const gpa = testing.allocator;
    const fixture = try Fixture.init(gpa, .button);
    defer fixture.deinit(gpa);

    accesskit_node_set_invalid(fixture.handle, lastTagByte(schema.Invalid));
    const held = optionalTestRead(schema.Invalid, accesskit_node_invalid(fixture.handle));
    try testing.expect(held.has_value);

    accesskit_node_set_invalid(fixture.handle, 200);
    const next = optionalTestRead(schema.Invalid, accesskit_node_invalid(fixture.handle));
    try testing.expectEqual(held.value, next.value);
    try testing.expect(allocation.lastError() == .none);

    // 200 is past the last of the 182 role tags, so `accesskit_node_new` with it
    // answers null and reports no failure: a node with no role has no
    // representation the rest of the header can read.
    try testing.expect(accesskit_node_new(200) == null);
    try testing.expect(allocation.lastError() == .none);
}

test "every block a node owns is released exactly once by accesskit_node_free" {
    // The property a C caller can act on: nothing the node owns survives the free,
    // and nothing is released twice. A node holds a block of its own, a
    // description buffer, a node-identifier list and a custom action here, so one
    // free has to answer for all four and the counter below sees every one.
    var channel: CountingPair = .{ .inner = testing.allocator };
    defer channel.release();
    channel.install();
    defer CountingPair.restore();

    const handle = accesskit_node_new(18) orelse return error.NodeNewFailed;
    accesskit_node_set_label(handle, cText("Save"));
    accesskit_node_set_children(handle, 1, &sample_ids);
    const held = try newAction(3, "Three");
    accesskit_node_push_custom_action(handle, held);
    try testing.expect(channel.live.count() > 0);

    accesskit_node_free(handle);
    CountingPair.restore();
    try testing.expectEqual(@as(usize, 0), channel.live.count());
    const released = try channel.expectOneReleaseEach();
    try testing.expect(released > 1);
}

test "a setter that cannot copy changes nothing and sets the failure tag" {
    // The port-specific divergence every setter here documents, driven by the
    // one allocator that stops answering. Upstream aborts here; the port reports
    // `ACCESSKIT_ERROR_OUT_OF_MEMORY` and leaves the property alone, which is
    // the only behaviour a void export can offer.
    var channel: CountingPair = .{ .inner = testing.allocator };
    defer channel.release();
    channel.install();
    defer CountingPair.restore();

    const handle = accesskit_node_new(18) orelse return error.NodeNewFailed;
    const gpa = allocation.allocator();

    // Two values written while the channel still answers, so the two failing
    // calls below have something they could have clobbered. Every other property
    // is left unset, because a write that replaces a value already in the store
    // needs no allocation and so succeeds even while the channel refuses; the
    // last case in this test is that fact, stated rather than assumed.
    accesskit_node_set_label(handle, cText("before"));
    accesskit_node_set_children(handle, 1, &sample_ids);
    accesskit_node_set_expanded(handle, true);

    channel.refuse = true;
    accesskit_node_set_label(handle, cText("a value that cannot be copied"));
    accesskit_node_set_label_with_length(handle, "abcdef".ptr, 6);
    accesskit_node_set_description(handle, cText("also cannot be copied"));
    accesskit_node_set_children(handle, 2, &sample_ids);
    accesskit_node_set_selected(handle, true);
    accesskit_node_set_invalid(handle, lastTagByte(schema.Invalid));
    accesskit_node_set_custom_actions(handle, 0, no_actions);
    // The two allocating getters report the same way, and so does the
    // constructor.
    try testing.expect(accesskit_node_description(handle) == null);
    try testing.expect(accesskit_node_custom_actions(handle) == null);
    try testing.expect(accesskit_node_new(18) == null);
    try testing.expect(allocation.lastError() == .out_of_memory);
    // A call that answered a caller precondition is not a failure, so it clears
    // the slot the way every other entry does.
    accesskit_node_set_invalid(handle, 200);
    try testing.expect(allocation.lastError() == .none);
    // A scalar setter writes over the value already in the store in place and
    // allocates nothing, so it succeeds while the channel refuses. A pusher is
    // the same when the list already has room, and the capacity a first copy
    // reserves is not this layer's to state. So the tag is a report about an
    // allocation that was needed and could not be made, not a promise that the
    // property did not change, and a C caller has to read it that way.
    accesskit_node_set_expanded(handle, true);
    try testing.expect(allocation.lastError() == .none);
    channel.refuse = false;

    // The two reads below release through the declared allocator as they go,
    // rather than in a `defer`, because the counter check at the foot is the
    // assertion and a `defer` would run after it.
    const label = accesskit_node_label(handle) orelse return error.GetterAnsweredNull;
    try testing.expectEqualStrings("before", span(label));
    releaseCString(label);
    const children = accesskit_node_children(handle);
    try testing.expectEqual(@as(usize, 1), children.length);
    try testing.expectEqual(@as(NodeIdContent, 11), children.values[0].value);
    try testing.expect(accesskit_node_description(handle) == null);
    const expanded = optionalTestRead(bool, accesskit_node_is_expanded(handle));
    try testing.expect(expanded.has_value);
    try testing.expect(expanded.value);
    try testing.expect(!optionalTestRead(bool, accesskit_node_is_selected(handle)).has_value);
    try testing.expect(!optionalTestRead(schema.Invalid, accesskit_node_invalid(handle)).has_value);
    const listed = accesskit_node_custom_actions(handle) orelse return error.GetterAnsweredNull;
    try testing.expectEqual(@as(usize, 0), listed.length);
    marshal.custom_actions_deinit(gpa, listed);

    // The free is here rather than in a `defer` because the counter check above
    // is the assertion and it has to see the free. Every block the node owns went
    // back exactly once, through the channel the node was built with.
    accesskit_node_free(handle);
    try testing.expectEqual(@as(usize, 0), channel.live.count());
    _ = try channel.expectOneReleaseEach();
}

test "a fresh node carries no property, so every getter answers its absent form" {
    // One node, every accessor. This is the sanity floor under every table above:
    // a getter that answered a value on a node nothing had been written to would
    // be reading something other than the store.
    var channel: CountingPair = .{ .inner = testing.allocator };
    defer channel.release();
    channel.install();
    defer CountingPair.restore();

    const handle = accesskit_node_new(18) orelse return error.NodeNewFailed;
    defer accesskit_node_free(handle);

    inline for (optional_rows) |row| {
        try testing.expect(!optionalTestRead(@TypeOf(row[5]), row[0](handle)).has_value);
    }
    inline for (node_list_rows) |row| {
        try testing.expectEqual(@as(usize, 0), row[0](handle).length);
        try testing.expect(row[0](handle).values != null);
    }
    inline for (length_rows) |row| {
        try testing.expectEqual(@as(usize, 0), row[0](handle).length);
        try testing.expect(row[0](handle).values != null);
    }
    inline for (coord_rows) |row| {
        try testing.expect(!row[0](handle).has_value);
    }
    inline for (string_rows) |row| {
        try testing.expect(row[0](handle) == null);
    }
    try testing.expect(accesskit_node_transform(handle) == null);
    const listed = accesskit_node_custom_actions(handle) orelse return error.GetterAnsweredNull;
    try testing.expectEqual(@as(usize, 0), listed.length);
    marshal.custom_actions_deinit(allocation.allocator(), listed);

    // And the node still carries none of them, so nothing above depended on a
    // read that answered from the handle rather than the store.
    inline for (optional_rows) |row| {
        try testing.expect(!optionalTestRead(@TypeOf(row[5]), row[0](handle)).has_value);
    }
    try testing.expect(allocation.lastError() == .none);
}

test "the failure tag survives only until the next call on this thread" {
    // `include/zaccesskit.h:6480-6481`. Two calls in a row must not report one
    // tag twice, so a C caller that polls the slot after a null cannot mistake an
    // older failure for the current one.
    const gpa = testing.allocator;
    const fixture = try Fixture.init(gpa, .button);
    defer fixture.deinit(gpa);

    allocation.failWith(.out_of_memory);
    try testing.expectEqual(@as(usize, 0), accesskit_node_children(fixture.handle).length);
    try testing.expect(allocation.lastError() == .none);

    allocation.failWith(.out_of_memory);
    try testing.expect(accesskit_node_label(fixture.handle) == null);
    try testing.expect(allocation.lastError() == .none);
}

test "the node debug text names the role and every property that is set" {
    // `accesskit_node_debug` is the 294th declaration and the only one whose
    // result is a rendering rather than a value. The text borrows nothing, so the
    // node may be released first, which is the ownership sentence at
    // `include/zaccesskit.h:5156-5159`.
    var channel: CountingPair = .{ .inner = testing.allocator };
    defer channel.release();
    channel.install();
    defer CountingPair.restore();

    const handle = accesskit_node_new(18) orelse return error.NodeNewFailed;
    defer accesskit_node_free(handle);

    accesskit_node_set_label(handle, cText("Save"));
    accesskit_node_set_expanded(handle, true);
    const text = accesskit_node_debug(handle) orelse return error.GetterAnsweredNull;
    defer releaseCString(text);
    // The whole text rather than three searches for a substring: the store
    // writes its properties in ascending `PropertyId` order, so `label` at 15
    // comes before `expanded` at 68, and each value is rendered through
    // `PropertyValue.format`, which spells a string as its byte count and a bool
    // as `bool(true)`.
    try testing.expectEqualStrings(
        "Node { role: button, label: string(4), expanded: bool(true) }",
        span(text),
    );
    try testing.expect(allocation.lastError() == .none);
}
