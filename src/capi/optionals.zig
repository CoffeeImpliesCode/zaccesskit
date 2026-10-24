//! The C ABI's twenty-five `accesskit_opt_*` forms: what "absent" means for
//! each of them, and the proof that a legitimate zero and an absent property
//! are two different answers rather than one.
//!
//! **What this file is, and what it deliberately is not.** A registry, not an
//! export. `include/zaccesskit.h` declares **no function whose name begins with
//! `accesskit_opt_`**: every one of the twenty-five forms appears only as a
//! `typedef struct` and as a return or argument type, and the functions that
//! mention one are the typed getters and setters in `src/capi/node.zig` and
//! `src/capi/tree_info.zig`. **There is therefore no `accesskit_opt_*`
//! declaration in the header for this file to back, and it declares no
//! `export fn`.** What it owns is the one thing nobody else owns: the absence
//! convention, written down once per form and checked.
//!
//! **Why the convention is not in `marshal.zig`, which builds every one of
//! them.** `marshal.zig` owns the `extern struct` declarations and the
//! twenty-four conversions, and its `optional_rows` table already carries each
//! form's payload type and payload offset. What no file carried is the *claim*:
//! the header repeats, twenty-five times, that "The port writes a zero value
//! into `value` in the false case, so a reader who ignores the flag reads a
//! defined zero rather than uninitialised storage. That is a diagnostic aid
//! rather than a contract, and a diagnostic aid nobody checks is a comment. So
//! this file names the representation per form, states the zero, and proves the
//! second half — that present-and-zero and absent are distinguishable — which is
//! the half a reader of a C header cannot check and the half that is usually
//! missing.
//!
//! **The two absence conventions, and why there are two.** Twenty-four of the
//! twenty-five are one shape: `has_value` false and every other field zero,
//! which is `marshal.wrapOptional`'s null path. **`accesskit_opt_coords` is the
//! exception**, because its absent form is not "a null pointer": it is
//! `length` 0 with a *non-null* `values`, so a reader that ignores the flag
//! reads an empty list rather than a dangling pointer. The header promises the
//! same for `accesskit_node_children` at `include/zaccesskit.h:2304`, and this
//! file pins the promise for the optional that carries it.
//!
//! **How the distinguishability is proved, and what it does and does not say.**
//! For each of the twenty-five, the absent value and a *legitimate zero* — a
//! value with `has_value` true and every other field zero — are built and
//! compared. They must differ, and the tests below show that the flag byte at
//! offset 0 is the *only* thing that differs. So the flag is the whole carrier
//! of presence, and a reader who reads the flag cannot confuse a zero with an
//! absence. What this does **not** say is that a reader who ignores the flag can:
//! the header calls that a diagnostic aid, and a proof that the two agree in
//! every byte but one is the strongest thing that can be true of a form that
//! writes a zero in both cases.
//!
//! **The `const char *` plus `size_t` pair.** The header declares twenty-five
//! setters that take a byte pointer and a byte count instead of a C string, and
//! `pair_rows` below names all twenty-five with their lines. The rule they share
//! is two sentences long and the header states it on each of them: the length
//! bounds the read, so `value` need not be NUL-terminated, and a byte string is
//! stored **up to the first NUL byte**, because a value holding one cannot come
//! back out of a `char *` getter without losing its tail. The implementation is
//! `marshal.c_bytes_to_slice` for the read and `marshal.dup_c_string` for the
//! truncation, and `marshal.zig` owns both and tests both. **This file records
//! the rule and the count and does not restate those tests.** It also records
//! which of the twenty-five have an export today: the two tree-info pairs are in
//! `src/capi/tree_info.zig` and the custom-action pair is in
//! `src/capi/action_request.zig`, and the twenty-one node pairs and the one macOS
//! pair belong to `src/capi/node.zig` and `src/capi/platform.zig`, which are not
//! this file's to write.
//!
//! **The `comptime` bound.** Two loops run over a domain. The first is the
//! sweep over `OptionalDomain` in the `comptime` block, whose bound is
//! `optional_domain_count`, which is twenty-five and is read off the type. The
//! second is the walk over `optional_rows` in the tests, whose bound is the same
//! count, and the test that walks `pair_rows` is bounded by `pair_count`, which
//! is twenty-five and is read off the table rather than repeated. Nothing else
//! in this file loops over a domain.
//!
//! **What this file does not do.** It declares no type, because
//! `src/capi/marshal.zig` declares all twenty-five and a second declaration of
//! one is a duplicate symbol at the link. It defines no conversion, for the same
//! reason and because `marshal.zig` owns every one. It allocates nothing, takes
//! no allocator, reads no clock, names no `zio`, holds no global and writes no
//! byte. Every table here is `const` and lives in the binary image, so a reader
//! reaches a form's name without a release.

const std = @import("std");

const marshal = @import("marshal.zig");

const testing = std.testing;

/// The twenty-five `accesskit_opt_*` forms, in header order.
///
/// The members are this file's key for a row, and the order is the order the
/// declarations stand in `include/zaccesskit.h`: twenty-four between lines 1082
/// and 1586, and `accesskit_opt_action_data` at 1674.
/// `optional_domain_count` reads the count off this type, and the `comptime`
/// block checks that `optional_rows` has one row per member in this order, so a
/// twenty-sixth form is a build failure here.
pub const OptionalDomain = enum {
    /// `accesskit_opt_node_id`, at `include/zaccesskit.h:1082`.
    node_id,
    /// `accesskit_opt_tree_id`, at `:1105`.
    tree_id,
    /// `accesskit_opt_double`, at `:1120`.
    double,
    /// `accesskit_opt_float`, at `:1135`.
    float,
    /// `accesskit_opt_index`, at `:1150`.
    index,
    /// `accesskit_opt_color`, at `:1179`.
    color,
    /// `accesskit_opt_text_decoration`, at `:1209`.
    text_decoration,
    /// `accesskit_opt_coords`, at `:1242`. The one form whose absent value is
    /// not "a null pointer", for the reason this module's doc records.
    coords,
    /// `accesskit_opt_bool`, at `:1258`.
    bool,
    /// `accesskit_opt_invalid`, at `:1273`.
    invalid,
    /// `accesskit_opt_toggled`, at `:1288`.
    toggled,
    /// `accesskit_opt_live`, at `:1303`.
    live,
    /// `accesskit_opt_text_direction`, at `:1318`.
    text_direction,
    /// `accesskit_opt_orientation`, at `:1333`.
    orientation,
    /// `accesskit_opt_sort_direction`, at `:1348`.
    sort_direction,
    /// `accesskit_opt_aria_current`, at `:1363`.
    aria_current,
    /// `accesskit_opt_auto_complete`, at `:1378`.
    auto_complete,
    /// `accesskit_opt_has_popup`, at `:1393`.
    has_popup,
    /// `accesskit_opt_list_style`, at `:1408`.
    list_style,
    /// `accesskit_opt_text_align`, at `:1423`.
    text_align,
    /// `accesskit_opt_vertical_offset`, at `:1438`.
    vertical_offset,
    /// `accesskit_opt_rect`, at `:1481`.
    rect,
    /// `accesskit_opt_text_selection`, at `:1517`.
    text_selection,
    /// `accesskit_opt_lresult`, at `:1586`, behind `_WIN32`. The type is
    /// declared on every target and its pin is written against `isize`, so a
    /// non-Windows build carries the form without exporting a function that
    /// returns it.
    lresult,
    /// `accesskit_opt_action_data`, at `:1674`. Declared in
    /// `src/schema/update.zig` and re-exported by `marshal.zig`, because the
    /// action payload crosses in one pass and a second declaration of the form
    /// would be a second layout to keep in step.
    action_data,
};

/// How many members `OptionalDomain` has: twenty-five, one per C form.
///
/// This is the compile-time bound on every loop over the optional domain, read
/// off the type so a member added to it is counted without an edit here.
pub const optional_domain_count: u32 = @intCast(@typeInfo(OptionalDomain).@"enum".field_names.len);

/// How the port spells "absent" for a form.
pub const AbsentKind = enum {
    /// `has_value` false and every other field zero. This is
    /// `marshal.wrapOptional`'s null path, and it is what twenty-four of the
    /// twenty-five forms do.
    zeroed_payload,

    /// `has_value` false, `length` 0, and a **non-null** `values` pointing at
    /// an empty array. This is `accesskit_opt_coords`' own null path, and the
    /// header's promise for it is at `include/zaccesskit.h:1229-1246`.
    empty_list,
};

/// One `accesskit_opt_*` form and how its absence is spelled.
///
/// A row is `const` data in the binary image. Nothing here is released and
/// nothing here borrows the allocator, so a reader can hold a `c_name` for as
/// long as it likes.
pub const OptionalRow = struct {
    /// This row's member of `OptionalDomain`, which is how a caller finds it.
    key: OptionalDomain,
    /// The form's name as the header spells it.
    c_name: []const u8,
    /// The line the `typedef struct` stands on in `include/zaccesskit.h`.
    header_line: u32,
    /// The `extern struct` behind the form. Declared by `marshal.zig` for
    /// twenty-four of them and by `src/schema/update.zig` for
    /// `accesskit_opt_action_data`, and re-exported by `marshal.zig` so that
    /// this file names the form without declaring it.
    c_type: type,
    /// How the port spells absent for this form.
    absent_kind: AbsentKind,
};

/// Every `accesskit_opt_*` form the header declares, in header order.
///
/// The table names each form and points at the type that implements it. It does
/// not restate the payload type or the payload offset, because
/// `marshal.zig`'s own table already carries both and two tables for one form
/// are two things to keep in step.
pub const optional_rows: [optional_domain_count]OptionalRow = .{
    .{
        .key = .node_id,
        .c_name = "accesskit_opt_node_id",
        .header_line = 1082,
        .c_type = marshal.COptNodeId,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .tree_id,
        .c_name = "accesskit_opt_tree_id",
        .header_line = 1105,
        .c_type = marshal.COptTreeId,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .double,
        .c_name = "accesskit_opt_double",
        .header_line = 1120,
        .c_type = marshal.COptDouble,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .float,
        .c_name = "accesskit_opt_float",
        .header_line = 1135,
        .c_type = marshal.COptFloat,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .index,
        .c_name = "accesskit_opt_index",
        .header_line = 1150,
        .c_type = marshal.COptIndex,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .color,
        .c_name = "accesskit_opt_color",
        .header_line = 1179,
        .c_type = marshal.COptColor,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .text_decoration,
        .c_name = "accesskit_opt_text_decoration",
        .header_line = 1209,
        .c_type = marshal.COptTextDecoration,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .coords,
        .c_name = "accesskit_opt_coords",
        .header_line = 1242,
        .c_type = marshal.COptCoords,
        .absent_kind = .empty_list,
    },
    .{
        .key = .bool,
        .c_name = "accesskit_opt_bool",
        .header_line = 1258,
        .c_type = marshal.COptBool,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .invalid,
        .c_name = "accesskit_opt_invalid",
        .header_line = 1273,
        .c_type = marshal.COptInvalid,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .toggled,
        .c_name = "accesskit_opt_toggled",
        .header_line = 1288,
        .c_type = marshal.COptToggled,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .live,
        .c_name = "accesskit_opt_live",
        .header_line = 1303,
        .c_type = marshal.COptLive,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .text_direction,
        .c_name = "accesskit_opt_text_direction",
        .header_line = 1318,
        .c_type = marshal.COptTextDirection,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .orientation,
        .c_name = "accesskit_opt_orientation",
        .header_line = 1333,
        .c_type = marshal.COptOrientation,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .sort_direction,
        .c_name = "accesskit_opt_sort_direction",
        .header_line = 1348,
        .c_type = marshal.COptSortDirection,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .aria_current,
        .c_name = "accesskit_opt_aria_current",
        .header_line = 1363,
        .c_type = marshal.COptAriaCurrent,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .auto_complete,
        .c_name = "accesskit_opt_auto_complete",
        .header_line = 1378,
        .c_type = marshal.COptAutoComplete,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .has_popup,
        .c_name = "accesskit_opt_has_popup",
        .header_line = 1393,
        .c_type = marshal.COptHasPopup,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .list_style,
        .c_name = "accesskit_opt_list_style",
        .header_line = 1408,
        .c_type = marshal.COptListStyle,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .text_align,
        .c_name = "accesskit_opt_text_align",
        .header_line = 1423,
        .c_type = marshal.COptTextAlign,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .vertical_offset,
        .c_name = "accesskit_opt_vertical_offset",
        .header_line = 1438,
        .c_type = marshal.COptVerticalOffset,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .rect,
        .c_name = "accesskit_opt_rect",
        .header_line = 1481,
        .c_type = marshal.COptRect,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .text_selection,
        .c_name = "accesskit_opt_text_selection",
        .header_line = 1517,
        .c_type = marshal.COptTextSelection,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .lresult,
        .c_name = "accesskit_opt_lresult",
        .header_line = 1586,
        .c_type = marshal.COptLResult,
        .absent_kind = .zeroed_payload,
    },
    .{
        .key = .action_data,
        .c_name = "accesskit_opt_action_data",
        .header_line = 1674,
        .c_type = marshal.COptActionData,
        .absent_kind = .zeroed_payload,
    },
};

/// The row for `key`.
///
/// `comptime`, so a caller names the row and the compiler picks it; there is no
/// run-time lookup and no run-time failure. The returned value is a copy of
/// `const` data and is never released.
pub fn rowFor(comptime key: OptionalDomain) OptionalRow {
    return optional_rows[@backingInt(key)];
}

/// Each row's C type name, in `OptionalDomain` order.
///
/// `optional_rows` cannot be indexed at run time, because a `type` field has no
/// run-time form, so a test that has to name the form it failed on reads this
/// instead. Built from the table rather than written out, so the two cannot
/// disagree.
pub const row_names: [optional_domain_count][]const u8 = blk: {
    var collected: [optional_domain_count][]const u8 = undefined;
    for (optional_rows, 0..) |row, index| collected[index] = row.c_name;
    break :blk collected;
};

/// One `const char *` plus `size_t` setter the header declares.
pub const PairRow = struct {
    /// The setter's name as the header spells it.
    c_name: []const u8,
    /// The line the declaration stands on in `include/zaccesskit.h`.
    header_line: u32,
};

/// Every `const char *` plus `size_t` setter, in header order.
///
/// Twenty-five rows and no more: twenty-one `accesskit_node_set_*` pairs, the
/// custom-action pair, the two tree-info pairs, and the one macOS focus-forwarder
/// pair. The rule each of them states is this module's doc's, and the
/// implementation is `marshal.c_bytes_to_slice` and `marshal.dup_c_string`.
pub const pair_rows = [_]PairRow{
    .{ .c_name = "accesskit_node_set_label_with_length", .header_line = 2868 },
    .{ .c_name = "accesskit_node_set_description_with_length", .header_line = 2908 },
    .{ .c_name = "accesskit_node_set_value_with_length", .header_line = 2949 },
    .{ .c_name = "accesskit_node_set_access_key_with_length", .header_line = 2989 },
    .{ .c_name = "accesskit_node_set_author_id_with_length", .header_line = 3031 },
    .{ .c_name = "accesskit_node_set_class_name_with_length", .header_line = 3073 },
    .{ .c_name = "accesskit_node_set_font_family_with_length", .header_line = 3115 },
    .{ .c_name = "accesskit_node_set_html_id_with_length", .header_line = 3157 },
    .{ .c_name = "accesskit_node_set_html_tag_with_length", .header_line = 3197 },
    .{ .c_name = "accesskit_node_set_inner_html_with_length", .header_line = 3239 },
    .{ .c_name = "accesskit_node_set_keyboard_shortcut_with_length", .header_line = 3283 },
    .{ .c_name = "accesskit_node_set_language_with_length", .header_line = 3324 },
    .{ .c_name = "accesskit_node_set_placeholder_with_length", .header_line = 3366 },
    .{ .c_name = "accesskit_node_set_role_description_with_length", .header_line = 3410 },
    .{ .c_name = "accesskit_node_set_state_description_with_length", .header_line = 3453 },
    .{ .c_name = "accesskit_node_set_tooltip_with_length", .header_line = 3494 },
    .{ .c_name = "accesskit_node_set_url_with_length", .header_line = 3532 },
    .{ .c_name = "accesskit_node_set_row_index_text_with_length", .header_line = 3573 },
    .{ .c_name = "accesskit_node_set_column_index_text_with_length", .header_line = 3616 },
    .{ .c_name = "accesskit_node_set_braille_label_with_length", .header_line = 3657 },
    .{ .c_name = "accesskit_node_set_braille_role_description_with_length", .header_line = 3702 },
    .{ .c_name = "accesskit_custom_action_set_description_with_length", .header_line = 5072 },
    .{ .c_name = "accesskit_tree_info_set_toolkit_name_with_length", .header_line = 5206 },
    .{ .c_name = "accesskit_tree_info_set_toolkit_version_with_length", .header_line = 5252 },
    .{
        .c_name = "accesskit_macos_add_focus_forwarder_to_window_class_with_length",
        .header_line = 6257,
    },
};

/// How many `const char *` plus `size_t` setters the header declares: 25.
///
/// This is the compile-time bound on every loop over the pair domain, read off
/// the table rather than repeated, and the `comptime` block pins it against the
/// header's own count.
pub const pair_count: u32 = @intCast(pair_rows.len);

comptime {
    // The distinctness sweeps below are quadratic in twenty-five, which is past
    // the 1000 backwards branches the evaluator allows by default. The quota is
    // raised once here rather than per sweep, because a per-sweep quota would
    // let one sweep's exhaustion look like another's failure.
    @setEvalBranchQuota(200_000);
    // The two bounds this file's loops run over, pinned against the header's
    // own numbers: twenty-five optional forms and twenty-five byte-pair setters.
    if (optional_domain_count != 25) @compileError("the header declares 25 optional forms");
    if (pair_count != 25) @compileError("the header declares 25 byte-pair setters");

    // `optional_rows` has one row per member of `OptionalDomain`, in this order,
    // so a twenty-sixth form is a build failure here rather than a row nobody
    // reads. Every row's name begins with the prefix a C consumer writes, and
    // every row names a type that carries the flag at offset 0: a form whose
    // flag is anywhere but the first byte is a form whose absent value is not
    // the first byte, and the two differ only in that byte below.
    for (std.enums.values(OptionalDomain), 0..) |member, index| {
        std.debug.assert(optional_rows[index].key == member);
        std.debug.assert(std.mem.startsWith(
            u8,
            optional_rows[index].c_name,
            "accesskit_opt_",
        ));
        std.debug.assert(@offsetOf(optional_rows[index].c_type, "has_value") == 0);
    }

    // The twenty-five `accesskit_opt_*` names are distinct, and so are the
    // twenty-five pair names. A duplicate in either is a copy-and-paste error
    // that would leave one form or one setter unnamed in the record.
    for (optional_rows, 0..) |row, index| {
        for (optional_rows[index + 1 ..]) |other| {
            if (std.mem.eql(u8, row.c_name, other.c_name)) {
                @compileError("two rows name the same optional form");
            }
        }
    }
    for (pair_rows, 0..) |row, index| {
        for (pair_rows[index + 1 ..]) |other| {
            if (std.mem.eql(u8, row.c_name, other.c_name)) {
                @compileError("two rows name the same byte-pair setter");
            }
        }
    }
}

// --- the absence convention -----------------------------------------------------

/// The value the port hands back for `C` when the property is unset.
///
/// The twenty-four `zeroed_payload` forms are `has_value` false over a zeroed
/// payload, which is what `marshal.wrapOptional` writes and what the header
/// describes at `include/zaccesskit.h:1072-1080`. The one `empty_list` form is
/// `marshal.opt_coords_to_c(null)`, which is the same flag over a *non-null*
/// empty list rather than over a zeroed pointer.
fn absentValue(comptime C: type, comptime kind: AbsentKind) C {
    @setEvalBranchQuota(20_000);
    // `kind` is comptime, so the other prong is never analysed: the `.empty_list`
    // value only has the type `COptCoords` and the `.zeroed_payload` body works
    // for every form.
    if (kind == .empty_list) {
        const listed: C = marshal.opt_coords_to_c(null);
        return listed;
    }
    var out: C = std.mem.zeroes(C);
    out.has_value = false;
    return out;
}

/// The legitimate zero for `C`: present, with every other field zero.
///
/// The absent value with the flag flipped, and nothing else. This is the state a
/// reader must be able to tell from absent, and it is a state the schema can
/// reach: a zero node id, a zero rect, a false flag, an empty text selection.
fn presentZero(comptime C: type, comptime kind: AbsentKind) C {
    var out = absentValue(C, kind);
    out.has_value = true;
    return out;
}

/// The bytes of `value` from offset 1 on, which is everything but the flag.
///
/// The comparison is over the raw bytes rather than through `std.meta.eql`
/// because `std.meta.eql` skips padding, and padding is exactly what this
/// comparison must include: a form whose absent value left a padding byte
/// uninitialised would differ from its present-zero in a byte the flag does not
/// account for, and a reader copying the struct would copy that byte too.
fn payloadBytes(comptime C: type, value: C) *const [@sizeOf(C) - 1]u8 {
    const all: *const [@sizeOf(C)]u8 = @ptrCast(&value);
    return all[1..];
}

// --- tests ----------------------------------------------------------------------

test "the table holds the twenty-five optionals the header declares" {
    try testing.expectEqual(@as(u32, 25), optional_domain_count);
    try testing.expectEqual(optional_domain_count, optional_rows.len);
    try testing.expectEqual(@as(u32, 25), pair_count);
}

test "a legitimate zero is distinguishable from absent, for every optional" {
    // The half that is usually missing. For each of the twenty-five, the absent
    // value and a present value whose payload is all zeros must be different
    // values, and the flag byte at offset 0 must be the only thing that differs.
    // A reader that reads the flag therefore cannot confuse a zero with an
    // absence, and a form whose flag moved would fail the offset assertion in
    // the `comptime` block above rather than here.
    // `inline for`, because a row's `c_type` is a `type` and a `type` has no
    // run-time form: this sweep can only resolve while the module is analysed,
    // and what it resolves is the whole twenty-five.
    inline for (optional_rows) |row| {
        const c_type = row.c_type;
        const absent = absentValue(c_type, row.absent_kind);
        const present = presentZero(c_type, row.absent_kind);

        // The comparison is over the raw bytes and not through `std.meta.eql`,
        // for two reasons. One of the twenty-five wraps an untagged
        // `extern union`, which `std.meta.eql` refuses outright; and `eql` skips
        // padding, which is exactly the byte a zeroed-but-uninitialised absent
        // value would leave wrong and a reader copying the struct would copy.
        testing.expect(std.mem.asBytes(&absent)[0] != std.mem.asBytes(&present)[0]) catch {
            std.debug.print("{s} reads the same either way\n", .{row.c_name});
            return error.ZeroEqualsAbsent;
        };
        try testing.expect(!absent.has_value);
        try testing.expect(present.has_value);
        try testing.expectEqualSlices(
            u8,
            payloadBytes(c_type, absent),
            payloadBytes(c_type, present),
        );
    }
}

test "an absent optional's payload is a defined zero, never uninitialised storage" {
    // The other half, and the one the header calls a diagnostic aid: a reader
    // who ignores the flag reads a zero, not whatever was in the storage. This
    // is the zeroed payload, byte for byte, and for the one list-shaped form it
    // is an empty list with a non-null pointer, which the test below pins.
    inline for (optional_rows) |row| {
        if (row.absent_kind == .empty_list) continue;
        const c_type = row.c_type;
        const absent = absentValue(c_type, row.absent_kind);
        var zeroed: c_type = std.mem.zeroes(c_type);
        zeroed.has_value = false;
        try testing.expectEqualSlices(u8, std.mem.asBytes(&absent), std.mem.asBytes(&zeroed));
    }
}

test "an absent coordinate list is an empty list and not a null pointer" {
    // `include/zaccesskit.h:1229-1246` is the header's sentence and
    // `include/zaccesskit.h:2304` is the same promise for the node-id list: an
    // unset list gives a length of 0 with a *non-null* pointer, so a reader that
    // ignores the flag reads an empty list rather than dereferences nothing.
    const absent = absentValue(marshal.COptCoords, .empty_list);
    try testing.expect(!absent.has_value);
    try testing.expectEqual(@as(usize, 0), absent.length);
    try testing.expect(absent.values != null);

    // The present zero of the same form differs in the flag and nowhere else, so
    // a present empty list and an absent one are still two answers.
    const present = presentZero(marshal.COptCoords, .empty_list);
    try testing.expect(present.has_value);
    try testing.expectEqual(@as(usize, 0), present.length);
    try testing.expectEqual(absent.values, present.values);
    try testing.expect(std.mem.asBytes(&absent)[0] != std.mem.asBytes(&present)[0]);
}

test "the twenty-five byte-pair setters are twenty-five distinct declarations" {
    // The count and the distinctness, which is the part of the record a table
    // can prove about itself. Whether each has an export is a different
    // question, and this module's doc says which files answer it.
    try testing.expectEqual(@as(u32, 25), pair_count);
    for (pair_rows, 0..) |row, index| {
        try testing.expect(row.header_line > 0);
        try testing.expect(std.mem.endsWith(u8, row.c_name, "_with_length"));
        for (pair_rows[index + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, row.c_name, other.c_name));
            // The header declares them in line order, so a row out of order is a
            // row whose line number and name have drifted apart.
            try testing.expect(row.header_line < other.header_line);
        }
    }
}

test "the byte-pair rule stops at the caller's length and at the first NUL" {
    // The rule every row of `pair_rows` states, proved once against the two
    // conversions that implement it. `marshal.zig` tests each of the two on its
    // own; what neither can show is the two of them together, and the two
    // together are the case that loses a tail. `c_bytes_to_slice` cuts at the
    // caller's length *and* at the first NUL inside that length, and
    // `dup_c_string` then copies what is left. A copy made from the caller's
    // length instead would be released at a length it was not allocated at,
    // which is heap corruption rather than a wrong answer.
    const gpa = testing.allocator;
    const raw = "ab\x00cd";

    // Five bytes were offered and two were read: the NUL inside the length ends
    // the value, because a value holding one cannot come back out of a `char *`
    // getter without losing its tail.
    const read = marshal.c_bytes_to_slice(raw.ptr, 5);
    try testing.expectEqual(@as(usize, 2), read.len);
    try testing.expectEqualStrings("ab", read);

    // The copy the setter would make, released the way `accesskit_string_free`
    // releases it: the release is at the *copied* length, which is the length
    // the allocation was made at, so the two agree.
    const copy = try marshal.dup_c_string(gpa, read);
    defer marshal.string_free(gpa, @constCast(copy));
    try testing.expectEqualStrings("ab", std.mem.span(copy));

    // A length shorter than the buffer and with no NUL before its end stops at
    // the length, and reads the same two bytes by the other route.
    const short = marshal.c_bytes_to_slice(raw.ptr, 2);
    try testing.expectEqual(@as(usize, 2), short.len);
    try testing.expectEqualStrings("ab", short);

    // A length of zero is an empty value and not an absent one, which is the
    // `Some("")` upstream keeps distinct from `None`.
    const empty = marshal.c_bytes_to_slice(raw.ptr, 0);
    try testing.expectEqual(@as(usize, 0), empty.len);
}
