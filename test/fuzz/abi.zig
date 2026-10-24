//! The C ABI layout conformance sweep, read out of the header itself.
//!
//! **Why read the header.** `docs/40-capi-build-map.md:1322` reports that a C
//! fixture measured 37 sizes and alignments and 28 payload offsets. Those
//! measurements were taken once, on one host, against one revision of the
//! header. This module re-derives the table from the header that is checked in
//! now, so a later edit to a struct cannot leave the recorded numbers stale,
//! and it checks every row against a Zig type where the schema layer has one.
//!
//! **What is checked against a Zig type.** The schema layer declares the
//! geometry, colour, decoration and text-selection types as `extern struct`
//! precisely because their offsets are a contract. Each of those has a row
//! here. The `accesskit_opt_*` rows and the list rows have no Zig counterpart
//! in the schema layer, because the C ABI form lives in `src/capi/` and this
//! harness measures the header rather than the exported symbols; it reads
//! their recorded numbers, reports them, and `zig build capi-parity` is the
//! step that compares the header against what `src/capi/` exports.
//!
//! **The per-tag projection.** `tagProjection` has one arm per member of
//! `PropertyValueTag`, so the union cannot gain a variant that no row of the
//! header covers. That is the answer to "a variant nobody measured is a variant
//! nobody knows": adding a variant without adding its projection is a compile
//! error here.
//!
//! **Where the numbers come from.** `include/zaccesskit.h:6507` states that the
//! table was measured on x86-64 Linux with the system C compiler. This module
//! compiles no C and re-measures nothing. It checks that the header still
//! declares what it declared and that the Zig types agree with it.

const std = @import("std");

const table = @import("../../src/schema/props/table.zig");
const ids = @import("../../src/schema/ids.zig");
const values = @import("../../src/schema/values.zig");
const affine_mod = @import("../../src/schema/geometry/affine.zig");
const rect_mod = @import("../../src/schema/geometry/rect.zig");
const point_mod = @import("../../src/schema/geometry/point.zig");
const vec2_mod = @import("../../src/schema/geometry/vec2.zig");
const size_mod = @import("../../src/schema/geometry/size.zig");

const PropertyValueTag = table.PropertyValueTag;

/// The header, read at compile time so a missing file is a build failure.
pub const header_text = @embedFile("../../include/zaccesskit.h");

/// The marker every row of the conformance table begins with.
///
/// The marker stops at the column gap and not at the type name, so the name a
/// row records still begins with `accesskit_` and matches what `tagProjection`
/// returns. The header's own column rule and four prose lines carry the same
/// marker; `parseOne` skips every line whose columns do not parse as numbers.
/// `[OBSERVED: 48 lines carry it and 39 of them are rows]`
const row_prefix = " *   ";

/// The widest table this parser will read.
///
/// The header declares 39 rows at `include/zaccesskit.h:6526` to `:6564`, so
/// 128 leaves room for a revision that grows the table and turns an overflow
/// into a compile error rather than a silent truncation.
pub const max_row_count: usize = 128;

/// One line of the conformance table in the header preamble.
pub const Row = struct {
    /// The C type name, for example `accesskit_opt_rect`.
    name: []const u8,
    /// The value the C compiler returned for `sizeof`.
    size: usize,
    /// The value the C compiler returned for `_Alignof`.
    alignment: usize,
    /// The offset the C compiler returned for the payload field, or `null`
    /// where the header writes `-` because the type has no payload field.
    payload_offset: ?usize,
};

/// The whole conformance table, with the count of rows that were read.
pub const Table = struct {
    // SAFETY: `parseOne` writes `rows[len]` and only then bumps `len`, and
    // every walk over the domain is `len` rows wide, so a `len`-bounded read
    // never reaches an unwritten row.
    rows: [max_row_count]Row = undefined,
    len: usize = 0,

    /// The row for `name`, or `null` when the header declares no such type.
    ///
    /// The walk over the domain is `len` rows wide, which is the count the
    /// parser recorded.
    pub fn find(self: *const Table, name: []const u8) ?Row {
        var index: usize = 0;
        while (index < self.len) : (index += 1) {
            if (std.mem.eql(u8, self.rows[index].name, name)) return self.rows[index];
        }
        return null;
    }

    /// How many rows carry a payload offset rather than `-`.
    ///
    /// The walk over the domain is `len` rows wide, which is the count the
    /// parser recorded.
    pub fn payloadRowCount(self: *const Table) usize {
        var total: usize = 0;
        var index: usize = 0;
        while (index < self.len) : (index += 1) {
            if (self.rows[index].payload_offset != null) total += 1;
        }
        return total;
    }

    /// How many rows name an `accesskit_opt_` type.
    ///
    /// These are the optional forms: a `has_value` byte beside a payload. The
    /// walk over the domain is `len` rows wide, which is the count the parser
    /// recorded.
    pub fn optionalRowCount(self: *const Table) usize {
        var total: usize = 0;
        var index: usize = 0;
        while (index < self.len) : (index += 1) {
            if (std.mem.startsWith(u8, self.rows[index].name, "accesskit_opt_")) total += 1;
        }
        return total;
    }
};

/// The failures `parseRows` reports. It fails with this and with nothing else.
pub const ParseError = error{
    /// The header declares more rows than `max_row_count` holds. The count is
    /// a build-time choice, so the fix is a larger bound and not a parser that
    /// drops rows it cannot place.
    TableTooLong,
};

/// Every conformance row the checked-in header declares.
///
/// The parse runs once per call site that names it. The header is embedded at
/// compile time, so a missing or moved header is a build failure rather than a
/// skip, and the table is rebuilt only if a test asks for it again.
pub fn parseRows(text: []const u8) ParseError!Table {
    var out: Table = .{};
    var line_start: usize = 0;
    while (line_start < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        if (std.mem.startsWith(u8, text[line_start..line_end], row_prefix)) {
            try parseOne(text[line_start..line_end], &out);
        }
        line_start = line_end + 1;
    }
    return out;
}

/// Reads one conformance row into the next free slot of `out`.
///
/// The four columns are the type name, the size, the alignment and the payload
/// offset or `-`. A line under the prefix that does not carry four such columns
/// is the dashed rule above the table rather than a row, so it is skipped.
fn parseOne(line: []const u8, out: *Table) ParseError!void {
    var fields: [4][]const u8 = undefined;
    if (splitFields(line[row_prefix.len..], &fields) != fields.len) return;

    const size = std.fmt.parseInt(usize, fields[1], 10) catch return;
    const alignment = std.fmt.parseInt(usize, fields[2], 10) catch return;
    const payload: ?usize = if (std.mem.eql(u8, fields[3], "-"))
        null
    else
        std.fmt.parseInt(usize, fields[3], 10) catch return;

    if (out.len == max_row_count) return error.TableTooLong;
    out.rows[out.len] = .{
        .name = fields[0],
        .size = size,
        .alignment = alignment,
        .payload_offset = payload,
    };
    out.len += 1;
}

fn splitFields(line: []const u8, out: *[4][]const u8) usize {
    var count: usize = 0;
    var rest = line;
    while (count < out.len) {
        rest = std.mem.trimStart(u8, rest, " \t");
        if (rest.len == 0) break;
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        out[count] = rest[0..end];
        rest = rest[end..];
        count += 1;
    }
    return count;
}

/// One header row beside the Zig type that must match it.
pub const ZigCheck = struct {
    /// The C type name, as the header spells it.
    header_name: []const u8,
    /// The Zig type the C side is a projection of.
    zig_type: type,
    /// The Zig field the header's payload column names, or `null` where the
    /// header writes `-`. The name is the `extern struct` field, so
    /// `@offsetOf` answers the C `offsetof` for the same member.
    payload_field: ?[]const u8,
};

/// Every row whose numbers a Zig type can answer today.
///
/// A row is here because the schema layer already declares the `extern struct`
/// the header describes. The `accesskit_opt_*` rows are not here, because the
/// optionals belong to the C ABI form that `src/capi/` will build.
pub const zig_checks = [_]ZigCheck{
    .{ .header_name = "accesskit_tree_id", .zig_type = ids.TreeId, .payload_field = null },
    .{ .header_name = "accesskit_color", .zig_type = values.Color, .payload_field = null },
    .{
        .header_name = "accesskit_text_decoration",
        .zig_type = values.TextDecoration,
        .payload_field = null,
    },
    .{ .header_name = "accesskit_affine", .zig_type = affine_mod.Affine, .payload_field = null },
    .{ .header_name = "accesskit_rect", .zig_type = rect_mod.Rect, .payload_field = null },
    .{
        .header_name = "accesskit_text_position",
        .zig_type = values.TextPosition,
        .payload_field = null,
    },
    .{
        .header_name = "accesskit_text_selection",
        .zig_type = values.TextSelection,
        .payload_field = "focus",
    },
    .{ .header_name = "accesskit_point", .zig_type = point_mod.Point, .payload_field = null },
    .{ .header_name = "accesskit_vec2", .zig_type = vec2_mod.Vec2, .payload_field = null },
    .{ .header_name = "accesskit_size", .zig_type = size_mod.Size, .payload_field = null },
};

/// The header row each payload tag projects onto.
///
/// One arm per member of `PropertyValueTag`, so the union cannot gain a variant
/// this table does not name. Twenty-six of the 29 tags name a row. The three
/// that do not are the ones the header carries without an aggregate of their
/// own: `none` is absence, `string` crosses as a `char *`
/// (`include/zaccesskit.h:2836`) and `affine` crosses as a pointer to a
/// returned value (`include/zaccesskit.h:4917`).
pub fn tagProjection(tag: PropertyValueTag) ?[]const u8 {
    return switch (tag) {
        .none => null,
        .node_id_vec => "accesskit_node_ids",
        .node_id => "accesskit_opt_node_id",
        .string => null,
        .f64_ => "accesskit_opt_double",
        .f32_ => "accesskit_opt_float",
        .usize_ => "accesskit_opt_index",
        .color => "accesskit_opt_color",
        .text_decoration => "accesskit_opt_text_decoration",
        .length_vec => "accesskit_lengths",
        .coord_vec => "accesskit_opt_coords",
        .bool_ => "accesskit_opt_bool",
        .invalid => "accesskit_opt_invalid",
        .toggled => "accesskit_opt_toggled",
        .live => "accesskit_opt_live",
        .text_direction => "accesskit_opt_text_direction",
        .orientation => "accesskit_opt_orientation",
        .sort_direction => "accesskit_opt_sort_direction",
        .aria_current => "accesskit_opt_aria_current",
        .auto_complete => "accesskit_opt_auto_complete",
        .has_popup => "accesskit_opt_has_popup",
        .list_style => "accesskit_opt_list_style",
        .text_align => "accesskit_opt_text_align",
        .vertical_offset => "accesskit_opt_vertical_offset",
        .affine => null,
        .rect => "accesskit_opt_rect",
        .text_selection => "accesskit_opt_text_selection",
        .custom_action_vec => "accesskit_custom_actions",
        .tree_id => "accesskit_opt_tree_id",
    };
}

/// How many members `PropertyValueTag` has, read from the type itself.
pub const tag_count: usize = @typeInfo(PropertyValueTag).@"enum".field_names.len;
