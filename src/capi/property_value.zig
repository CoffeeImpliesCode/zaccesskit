//! The C enumerations that cross this boundary: nineteen declarations and the
//! 272 tags they carry, in one table, with the bijection between a C enumerator
//! and a Zig variant proven in both directions.
//!
//! **What this file is.** A registry, not an export. `include/zaccesskit.h`
//! declares nineteen enumerations and **no function whose name carries an
//! enumerator**, so there is no `accesskit_*` declaration this file backs and it
//! declares no `export fn`. The bridge that brief named
//! `docs/40-capi-build-map.md` calls a `PropertyValue` crossing names upstream's
//! `PlatformValue` and `accesskit::PropertyValue`, and **neither type is in this
//! header**: `src/capi/marshal.zig` records the same absence for the union and
//! names upstream's `PlatformValue` as what the brief was reaching. What does
//! cross is the byte in each enumeration, and this file is where every one of
//! them is written down and checked. That is the part a count cannot reach: a
//! family of nineteen vanishing from one file is invisible to a test total, and
//! this table is what makes the next one visible.
//!
//! **The nineteen, and what they are.** Seventeen are the wire enums a node's
//! properties carry: `accesskit_action`, `accesskit_role`, the thirteen small
//! property enums, and `accesskit_scroll_unit` and `accesskit_scroll_hint`,
//! which ride inside an action payload. Eighteen is
//! `accesskit_action_data_Tag`, the discriminant of the action payload, and
//! nineteen is `accesskit_error`, the tag this port adds to the channel in
//! `src/capi/allocation.zig`. They are in the table in header order, and
//! `EnumDomain` is the same order; the `comptime` block at the foot of this file
//! asserts that the two agree member for member.
//!
//! **Why the table names both spellings.** A C enumerator and a Zig variant are
//! two names for one wire byte, and either can be wrong without the other
//! being wrong. The header spells every one of the 272 as `ACCESSKIT_`, then
//! the enumeration's own name in upper case, then `_`, then the variant's name
//! in upper case, with the trailing underscore a reserved Zig word carries
//! dropped: Zig `left_to_right` is `ACCESSKIT_TEXT_DIRECTION_LEFT_TO_RIGHT`, and
//! Zig `true_` is `ACCESSKIT_INVALID_TRUE`. The one spelling that departs is
//! the *type* name of `accesskit_action_data_Tag`, which drops its own `_Tag`
//! suffix from the tag names, and `c_prefix` is the field that records it. The
//! `comptime` block derives all 272 from the row and the variant name and
//! compares, so a C name that is unique but wrong still fails the build.
//!
//! **The two directions, and the difference between them.** Every C tag must
//! name exactly one Zig variant, and every Zig variant must name exactly one C
//! tag. The first is proved at compile time, by resolving each row's variant
//! name against its enum and checking that the variant carries the discriminant
//! the row places it at; the second is proved at run time by a test that walks
//! all 272 entries and holds each C name to appear once in the whole table. A
//! one-way check is a spot check wearing a total's name, so both halves are
//! here.
//!
//! **The gates, and the two rows with none.** Seventeen of the nineteen have a
//! checked byte-to-variant gate in the layer below: the fifteen `*FromInt`
//! gates `src/schema/node_enums.zig` and `src/schema/scroll_enums.zig` own, plus
//! `src/schema/action.zig`'s `actionFromInt` and `src/capi/node.zig`'s
//! `role_from_c`. The `comptime` block names each of them beside the row it
//! belongs to and checks that the gate answers for every tag in its own row and
//! rejects the byte one past the end. **The other two have no standalone gate,
//! deliberately.** `accesskit_action_data_Tag`'s decode lives inside
//! `schema.actionDataFromC`, which pairs each tag with the union member the
//! header lists at the same index, and a second decode here would be a second
//! answer to a question that one function already answers. `accesskit_error` has
//! no decoder at all: it crosses outward only, as the return of
//! `accesskit_last_error`. Both rows are covered instead by the contiguous-
//! discriminant sweep, which is the property that makes a range check a sound
//! decode and is what those two paths rely on.
//!
//! **The `comptime` bound.** Two loops run over a domain. The first is the
//! sweep over `EnumDomain` in the `comptime` block, whose bound is
//! `enumDomainCount`, which is nineteen and is read off the type. The second is
//! the flattening that builds `tag_entries`, whose bound is `tagCount`, which is
//! 272 and is read off `enum_rows` rather than repeated. Nothing else in this
//! file loops over a domain.
//!
//! **What this file deliberately does not do.** It does not decode, because the
//! layer below owns every decode; it does not convert, because
//! `src/capi/marshal.zig` owns every conversion and a second one is how two
//! copies drift; it does not allocate, take an allocator, read a clock, name
//! `zio`, hold a global or write a byte. Every table here is `const` and lives in
//! the binary image, so a caller can reach a tag name without a release and
//! without an allocator. Nothing here is exported, so nothing here is part of
//! the C ABI, and `src/capi/root.zig` is where that decision is visible.

const std = @import("std");

const allocation = @import("allocation.zig");
const node = @import("node.zig");
const schema = @import("../schema/root.zig");

const testing = std.testing;

/// The nineteen C enumerations, in header order.
///
/// The members are this file's key for a row, and the order is the order the
/// declarations stand in `include/zaccesskit.h`: the seventeen wire enums at
/// lines 220 to 876, then `accesskit_action_data_Tag` at 1606, then
/// `accesskit_error` at 1774. `enumDomainCount` reads the count off this type,
/// and the `comptime` block checks that `enum_rows` has one row per member in
/// this order, so a twentieth enumeration is a build failure here.
pub const EnumDomain = enum {
    /// `accesskit_action`, at `include/zaccesskit.h:220`.
    action,
    /// `accesskit_aria_current`, at `:288`.
    aria_current,
    /// `accesskit_auto_complete`, at `:316`.
    auto_complete,
    /// `accesskit_has_popup`, at `:340`.
    has_popup,
    /// `accesskit_invalid`, at `:367`.
    invalid,
    /// `accesskit_list_style`, at `:391`.
    list_style,
    /// `accesskit_live`, at `:421`.
    live,
    /// `accesskit_orientation`, at `:445`.
    orientation,
    /// `accesskit_role`, at `:482`.
    role,
    /// `accesskit_scroll_hint`, at `:702`.
    scroll_hint,
    /// `accesskit_scroll_unit`, at `:729`.
    scroll_unit,
    /// `accesskit_sort_direction`, at `:752`.
    sort_direction,
    /// `accesskit_text_align`, at `:776`.
    text_align,
    /// `accesskit_text_decoration_style`, at `:801`.
    text_decoration_style,
    /// `accesskit_text_direction`, at `:827`.
    text_direction,
    /// `accesskit_toggled`, at `:852`.
    toggled,
    /// `accesskit_vertical_offset`, at `:876`.
    vertical_offset,
    /// `accesskit_action_data_Tag`, at `:1606`. The `_Tag` suffix the type
    /// carries is absent from the eight enumerator names it declares, which is
    /// the one departure from the spelling rule this file's doc records.
    action_data_tag,
    /// `accesskit_error`, at `:1774`. The tag `accesskit_last_error` returns,
    /// and the only failing member of it is `ACCESSKIT_ERROR_OUT_OF_MEMORY`.
    error_tag,
};

/// How many members `EnumDomain` has: nineteen, one per C enumeration.
///
/// This is the compile-time bound on every loop over the enumeration domain,
/// read off the type so a member added to it is counted without an edit here.
pub const enumDomainCount: u32 = @intCast(@typeInfo(EnumDomain).@"enum".fields.len);

/// One C enumerator and the Zig variant it is the same wire byte as.
///
/// Both spellings are the header's and the schema's, read from each rather than
/// derived, so a disagreement between them is a disagreement between two
/// sources and not a rule that quietly disagrees with one of them.
pub const TagRow = struct {
    /// The enumerator as `include/zaccesskit.h` spells it.
    c_name: []const u8,
    /// The variant as the schema enum spells it, with the trailing underscore a
    /// reserved Zig word carries.
    zig_name: []const u8,
};

/// One C enumeration, the Zig enum behind it, and every tag in order.
///
/// A row is `const` data in the binary image. Nothing here is released and
/// nothing here borrows the allocator, so a reader can hold a `c_name` for as
/// long as it likes.
pub const EnumRow = struct {
    /// This row's member of `EnumDomain`, which is how a caller finds it.
    key: EnumDomain,
    /// The enumeration's name as the header spells it.
    c_name: []const u8,
    /// The line the declaration stands on in `include/zaccesskit.h`.
    header_line: u32,
    /// The part of a C enumerator that comes before the variant's own name,
    /// without the leading `ACCESSKIT_`.
    c_prefix: []const u8,
    /// The schema enum this row crosses to, or `allocation.Tag` for
    /// `accesskit_error`.
    zig_type: type,
    /// Every tag, in declaration order. Its length is the enumeration's width
    /// and the `comptime` block checks it against the enum's field count.
    tags: []const TagRow,
};

/// Every C enumeration this boundary crosses, in header order.
///
/// Nineteen rows and 272 tags between them. The table is the only copy of this
/// data in the repository: nothing else in `src/capi/` writes an enumerator
/// name, and nothing else in `src/capi/` lists an enumeration's width.
pub const enum_rows: [enumDomainCount]EnumRow = .{
    .{
        .key = .action,
        .c_name = "accesskit_action",
        .header_line = 220,
        .c_prefix = "ACTION",
        .zig_type = schema.Action,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_ACTION_CLICK", .zig_name = "click" },
            .{ .c_name = "ACCESSKIT_ACTION_FOCUS", .zig_name = "focus" },
            .{ .c_name = "ACCESSKIT_ACTION_BLUR", .zig_name = "blur" },
            .{ .c_name = "ACCESSKIT_ACTION_COLLAPSE", .zig_name = "collapse" },
            .{ .c_name = "ACCESSKIT_ACTION_EXPAND", .zig_name = "expand" },
            .{ .c_name = "ACCESSKIT_ACTION_CUSTOM_ACTION", .zig_name = "custom_action" },
            .{ .c_name = "ACCESSKIT_ACTION_DECREMENT", .zig_name = "decrement" },
            .{ .c_name = "ACCESSKIT_ACTION_INCREMENT", .zig_name = "increment" },
            .{ .c_name = "ACCESSKIT_ACTION_HIDE_TOOLTIP", .zig_name = "hide_tooltip" },
            .{ .c_name = "ACCESSKIT_ACTION_SHOW_TOOLTIP", .zig_name = "show_tooltip" },
            .{
                .c_name = "ACCESSKIT_ACTION_REPLACE_SELECTED_TEXT",
                .zig_name = "replace_selected_text",
            },
            .{ .c_name = "ACCESSKIT_ACTION_SCROLL_DOWN", .zig_name = "scroll_down" },
            .{ .c_name = "ACCESSKIT_ACTION_SCROLL_LEFT", .zig_name = "scroll_left" },
            .{ .c_name = "ACCESSKIT_ACTION_SCROLL_RIGHT", .zig_name = "scroll_right" },
            .{ .c_name = "ACCESSKIT_ACTION_SCROLL_UP", .zig_name = "scroll_up" },
            .{ .c_name = "ACCESSKIT_ACTION_SCROLL_INTO_VIEW", .zig_name = "scroll_into_view" },
            .{ .c_name = "ACCESSKIT_ACTION_SCROLL_TO_POINT", .zig_name = "scroll_to_point" },
            .{ .c_name = "ACCESSKIT_ACTION_SET_SCROLL_OFFSET", .zig_name = "set_scroll_offset" },
            .{ .c_name = "ACCESSKIT_ACTION_SET_TEXT_SELECTION", .zig_name = "set_text_selection" },
            .{
                .c_name = "ACCESSKIT_ACTION_SET_SEQUENTIAL_FOCUS_NAVIGATION_STARTING_POINT",
                .zig_name = "set_sequential_focus_navigation_starting_point",
            },
            .{ .c_name = "ACCESSKIT_ACTION_SET_VALUE", .zig_name = "set_value" },
            .{ .c_name = "ACCESSKIT_ACTION_SHOW_CONTEXT_MENU", .zig_name = "show_context_menu" },
        },
    },
    .{
        .key = .aria_current,
        .c_name = "accesskit_aria_current",
        .header_line = 288,
        .c_prefix = "ARIA_CURRENT",
        .zig_type = schema.AriaCurrent,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_ARIA_CURRENT_FALSE", .zig_name = "false_" },
            .{ .c_name = "ACCESSKIT_ARIA_CURRENT_TRUE", .zig_name = "true_" },
            .{ .c_name = "ACCESSKIT_ARIA_CURRENT_PAGE", .zig_name = "page" },
            .{ .c_name = "ACCESSKIT_ARIA_CURRENT_STEP", .zig_name = "step" },
            .{ .c_name = "ACCESSKIT_ARIA_CURRENT_LOCATION", .zig_name = "location" },
            .{ .c_name = "ACCESSKIT_ARIA_CURRENT_DATE", .zig_name = "date" },
            .{ .c_name = "ACCESSKIT_ARIA_CURRENT_TIME", .zig_name = "time" },
        },
    },
    .{
        .key = .auto_complete,
        .c_name = "accesskit_auto_complete",
        .header_line = 316,
        .c_prefix = "AUTO_COMPLETE",
        .zig_type = schema.AutoComplete,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_AUTO_COMPLETE_INLINE", .zig_name = "inline_" },
            .{ .c_name = "ACCESSKIT_AUTO_COMPLETE_LIST", .zig_name = "list" },
            .{ .c_name = "ACCESSKIT_AUTO_COMPLETE_BOTH", .zig_name = "both" },
        },
    },
    .{
        .key = .has_popup,
        .c_name = "accesskit_has_popup",
        .header_line = 340,
        .c_prefix = "HAS_POPUP",
        .zig_type = schema.HasPopup,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_HAS_POPUP_MENU", .zig_name = "menu" },
            .{ .c_name = "ACCESSKIT_HAS_POPUP_LISTBOX", .zig_name = "listbox" },
            .{ .c_name = "ACCESSKIT_HAS_POPUP_TREE", .zig_name = "tree" },
            .{ .c_name = "ACCESSKIT_HAS_POPUP_GRID", .zig_name = "grid" },
            .{ .c_name = "ACCESSKIT_HAS_POPUP_DIALOG", .zig_name = "dialog" },
        },
    },
    .{
        .key = .invalid,
        .c_name = "accesskit_invalid",
        .header_line = 367,
        .c_prefix = "INVALID",
        .zig_type = schema.Invalid,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_INVALID_TRUE", .zig_name = "true_" },
            .{ .c_name = "ACCESSKIT_INVALID_GRAMMAR", .zig_name = "grammar" },
            .{ .c_name = "ACCESSKIT_INVALID_SPELLING", .zig_name = "spelling" },
        },
    },
    .{
        .key = .list_style,
        .c_name = "accesskit_list_style",
        .header_line = 391,
        .c_prefix = "LIST_STYLE",
        .zig_type = schema.ListStyle,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_LIST_STYLE_CIRCLE", .zig_name = "circle" },
            .{ .c_name = "ACCESSKIT_LIST_STYLE_DISC", .zig_name = "disc" },
            .{ .c_name = "ACCESSKIT_LIST_STYLE_IMAGE", .zig_name = "image" },
            .{ .c_name = "ACCESSKIT_LIST_STYLE_NUMERIC", .zig_name = "numeric" },
            .{ .c_name = "ACCESSKIT_LIST_STYLE_SQUARE", .zig_name = "square" },
            .{ .c_name = "ACCESSKIT_LIST_STYLE_OTHER", .zig_name = "other" },
        },
    },
    .{
        .key = .live,
        .c_name = "accesskit_live",
        .header_line = 421,
        .c_prefix = "LIVE",
        .zig_type = schema.Live,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_LIVE_OFF", .zig_name = "off" },
            .{ .c_name = "ACCESSKIT_LIVE_POLITE", .zig_name = "polite" },
            .{ .c_name = "ACCESSKIT_LIVE_ASSERTIVE", .zig_name = "assertive" },
        },
    },
    .{
        .key = .orientation,
        .c_name = "accesskit_orientation",
        .header_line = 445,
        .c_prefix = "ORIENTATION",
        .zig_type = schema.Orientation,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_ORIENTATION_HORIZONTAL", .zig_name = "horizontal" },
            .{ .c_name = "ACCESSKIT_ORIENTATION_VERTICAL", .zig_name = "vertical" },
        },
    },
    .{
        .key = .role,
        .c_name = "accesskit_role",
        .header_line = 482,
        .c_prefix = "ROLE",
        .zig_type = schema.Role,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_ROLE_UNKNOWN", .zig_name = "unknown" },
            .{ .c_name = "ACCESSKIT_ROLE_TEXT_RUN", .zig_name = "text_run" },
            .{ .c_name = "ACCESSKIT_ROLE_CELL", .zig_name = "cell" },
            .{ .c_name = "ACCESSKIT_ROLE_LABEL", .zig_name = "label" },
            .{ .c_name = "ACCESSKIT_ROLE_IMAGE", .zig_name = "image" },
            .{ .c_name = "ACCESSKIT_ROLE_LINK", .zig_name = "link" },
            .{ .c_name = "ACCESSKIT_ROLE_ROW", .zig_name = "row" },
            .{ .c_name = "ACCESSKIT_ROLE_LIST_ITEM", .zig_name = "list_item" },
            .{ .c_name = "ACCESSKIT_ROLE_LIST_MARKER", .zig_name = "list_marker" },
            .{ .c_name = "ACCESSKIT_ROLE_TREE_ITEM", .zig_name = "tree_item" },
            .{ .c_name = "ACCESSKIT_ROLE_LIST_BOX_OPTION", .zig_name = "list_box_option" },
            .{ .c_name = "ACCESSKIT_ROLE_MENU_ITEM", .zig_name = "menu_item" },
            .{ .c_name = "ACCESSKIT_ROLE_MENU_LIST_OPTION", .zig_name = "menu_list_option" },
            .{ .c_name = "ACCESSKIT_ROLE_PARAGRAPH", .zig_name = "paragraph" },
            .{ .c_name = "ACCESSKIT_ROLE_GENERIC_CONTAINER", .zig_name = "generic_container" },
            .{ .c_name = "ACCESSKIT_ROLE_CHECK_BOX", .zig_name = "check_box" },
            .{ .c_name = "ACCESSKIT_ROLE_RADIO_BUTTON", .zig_name = "radio_button" },
            .{ .c_name = "ACCESSKIT_ROLE_TEXT_INPUT", .zig_name = "text_input" },
            .{ .c_name = "ACCESSKIT_ROLE_BUTTON", .zig_name = "button" },
            .{ .c_name = "ACCESSKIT_ROLE_DEFAULT_BUTTON", .zig_name = "default_button" },
            .{ .c_name = "ACCESSKIT_ROLE_PANE", .zig_name = "pane" },
            .{ .c_name = "ACCESSKIT_ROLE_ROW_HEADER", .zig_name = "row_header" },
            .{ .c_name = "ACCESSKIT_ROLE_COLUMN_HEADER", .zig_name = "column_header" },
            .{ .c_name = "ACCESSKIT_ROLE_ROW_GROUP", .zig_name = "row_group" },
            .{ .c_name = "ACCESSKIT_ROLE_LIST", .zig_name = "list" },
            .{ .c_name = "ACCESSKIT_ROLE_TABLE", .zig_name = "table" },
            .{ .c_name = "ACCESSKIT_ROLE_LAYOUT_TABLE_CELL", .zig_name = "layout_table_cell" },
            .{ .c_name = "ACCESSKIT_ROLE_LAYOUT_TABLE_ROW", .zig_name = "layout_table_row" },
            .{ .c_name = "ACCESSKIT_ROLE_LAYOUT_TABLE", .zig_name = "layout_table" },
            .{ .c_name = "ACCESSKIT_ROLE_SWITCH", .zig_name = "switch_" },
            .{ .c_name = "ACCESSKIT_ROLE_MENU", .zig_name = "menu" },
            .{
                .c_name = "ACCESSKIT_ROLE_MULTILINE_TEXT_INPUT",
                .zig_name = "multiline_text_input",
            },
            .{ .c_name = "ACCESSKIT_ROLE_SEARCH_INPUT", .zig_name = "search_input" },
            .{ .c_name = "ACCESSKIT_ROLE_DATE_INPUT", .zig_name = "date_input" },
            .{ .c_name = "ACCESSKIT_ROLE_DATE_TIME_INPUT", .zig_name = "date_time_input" },
            .{ .c_name = "ACCESSKIT_ROLE_WEEK_INPUT", .zig_name = "week_input" },
            .{ .c_name = "ACCESSKIT_ROLE_MONTH_INPUT", .zig_name = "month_input" },
            .{ .c_name = "ACCESSKIT_ROLE_TIME_INPUT", .zig_name = "time_input" },
            .{ .c_name = "ACCESSKIT_ROLE_EMAIL_INPUT", .zig_name = "email_input" },
            .{ .c_name = "ACCESSKIT_ROLE_NUMBER_INPUT", .zig_name = "number_input" },
            .{ .c_name = "ACCESSKIT_ROLE_PASSWORD_INPUT", .zig_name = "password_input" },
            .{
                .c_name = "ACCESSKIT_ROLE_PHONE_NUMBER_INPUT",
                .zig_name = "phone_number_input",
            },
            .{ .c_name = "ACCESSKIT_ROLE_URL_INPUT", .zig_name = "url_input" },
            .{ .c_name = "ACCESSKIT_ROLE_ABBR", .zig_name = "abbr" },
            .{ .c_name = "ACCESSKIT_ROLE_ALERT", .zig_name = "alert" },
            .{ .c_name = "ACCESSKIT_ROLE_ALERT_DIALOG", .zig_name = "alert_dialog" },
            .{ .c_name = "ACCESSKIT_ROLE_APPLICATION", .zig_name = "application" },
            .{ .c_name = "ACCESSKIT_ROLE_ARTICLE", .zig_name = "article" },
            .{ .c_name = "ACCESSKIT_ROLE_AUDIO", .zig_name = "audio" },
            .{ .c_name = "ACCESSKIT_ROLE_BANNER", .zig_name = "banner" },
            .{ .c_name = "ACCESSKIT_ROLE_BLOCKQUOTE", .zig_name = "blockquote" },
            .{ .c_name = "ACCESSKIT_ROLE_CANVAS", .zig_name = "canvas" },
            .{ .c_name = "ACCESSKIT_ROLE_CAPTION", .zig_name = "caption" },
            .{ .c_name = "ACCESSKIT_ROLE_CARET", .zig_name = "caret" },
            .{ .c_name = "ACCESSKIT_ROLE_CODE", .zig_name = "code" },
            .{ .c_name = "ACCESSKIT_ROLE_COLOR_WELL", .zig_name = "color_well" },
            .{ .c_name = "ACCESSKIT_ROLE_COMBO_BOX", .zig_name = "combo_box" },
            .{
                .c_name = "ACCESSKIT_ROLE_EDITABLE_COMBO_BOX",
                .zig_name = "editable_combo_box",
            },
            .{ .c_name = "ACCESSKIT_ROLE_COMPLEMENTARY", .zig_name = "complementary" },
            .{ .c_name = "ACCESSKIT_ROLE_COMMENT", .zig_name = "comment" },
            .{ .c_name = "ACCESSKIT_ROLE_CONTENT_DELETION", .zig_name = "content_deletion" },
            .{ .c_name = "ACCESSKIT_ROLE_CONTENT_INSERTION", .zig_name = "content_insertion" },
            .{ .c_name = "ACCESSKIT_ROLE_CONTENT_INFO", .zig_name = "content_info" },
            .{ .c_name = "ACCESSKIT_ROLE_DEFINITION", .zig_name = "definition" },
            .{ .c_name = "ACCESSKIT_ROLE_DESCRIPTION_LIST", .zig_name = "description_list" },
            .{ .c_name = "ACCESSKIT_ROLE_DETAILS", .zig_name = "details" },
            .{ .c_name = "ACCESSKIT_ROLE_DIALOG", .zig_name = "dialog" },
            .{ .c_name = "ACCESSKIT_ROLE_DISCLOSURE_TRIANGLE", .zig_name = "disclosure_triangle" },
            .{ .c_name = "ACCESSKIT_ROLE_DOCUMENT", .zig_name = "document" },
            .{ .c_name = "ACCESSKIT_ROLE_EMBEDDED_OBJECT", .zig_name = "embedded_object" },
            .{ .c_name = "ACCESSKIT_ROLE_EMPHASIS", .zig_name = "emphasis" },
            .{ .c_name = "ACCESSKIT_ROLE_FEED", .zig_name = "feed" },
            .{ .c_name = "ACCESSKIT_ROLE_FIGURE_CAPTION", .zig_name = "figure_caption" },
            .{ .c_name = "ACCESSKIT_ROLE_FIGURE", .zig_name = "figure" },
            .{ .c_name = "ACCESSKIT_ROLE_FOOTER", .zig_name = "footer" },
            .{ .c_name = "ACCESSKIT_ROLE_FORM", .zig_name = "form" },
            .{ .c_name = "ACCESSKIT_ROLE_GRID", .zig_name = "grid" },
            .{ .c_name = "ACCESSKIT_ROLE_GRID_CELL", .zig_name = "grid_cell" },
            .{ .c_name = "ACCESSKIT_ROLE_GROUP", .zig_name = "group" },
            .{ .c_name = "ACCESSKIT_ROLE_HEADER", .zig_name = "header" },
            .{ .c_name = "ACCESSKIT_ROLE_HEADING", .zig_name = "heading" },
            .{ .c_name = "ACCESSKIT_ROLE_IFRAME", .zig_name = "iframe" },
            .{
                .c_name = "ACCESSKIT_ROLE_IFRAME_PRESENTATIONAL",
                .zig_name = "iframe_presentational",
            },
            .{ .c_name = "ACCESSKIT_ROLE_IME_CANDIDATE", .zig_name = "ime_candidate" },
            .{ .c_name = "ACCESSKIT_ROLE_KEYBOARD", .zig_name = "keyboard" },
            .{ .c_name = "ACCESSKIT_ROLE_LEGEND", .zig_name = "legend" },
            .{ .c_name = "ACCESSKIT_ROLE_LINE_BREAK", .zig_name = "line_break" },
            .{ .c_name = "ACCESSKIT_ROLE_LIST_BOX", .zig_name = "list_box" },
            .{ .c_name = "ACCESSKIT_ROLE_LOG", .zig_name = "log" },
            .{ .c_name = "ACCESSKIT_ROLE_MAIN", .zig_name = "main" },
            .{ .c_name = "ACCESSKIT_ROLE_MARK", .zig_name = "mark" },
            .{ .c_name = "ACCESSKIT_ROLE_MARQUEE", .zig_name = "marquee" },
            .{ .c_name = "ACCESSKIT_ROLE_MATH", .zig_name = "math" },
            .{ .c_name = "ACCESSKIT_ROLE_MENU_BAR", .zig_name = "menu_bar" },
            .{ .c_name = "ACCESSKIT_ROLE_MENU_ITEM_CHECK_BOX", .zig_name = "menu_item_check_box" },
            .{ .c_name = "ACCESSKIT_ROLE_MENU_ITEM_RADIO", .zig_name = "menu_item_radio" },
            .{ .c_name = "ACCESSKIT_ROLE_MENU_LIST_POPUP", .zig_name = "menu_list_popup" },
            .{ .c_name = "ACCESSKIT_ROLE_METER", .zig_name = "meter" },
            .{ .c_name = "ACCESSKIT_ROLE_NAVIGATION", .zig_name = "navigation" },
            .{ .c_name = "ACCESSKIT_ROLE_NOTE", .zig_name = "note" },
            .{ .c_name = "ACCESSKIT_ROLE_PLUGIN_OBJECT", .zig_name = "plugin_object" },
            .{ .c_name = "ACCESSKIT_ROLE_PROGRESS_INDICATOR", .zig_name = "progress_indicator" },
            .{ .c_name = "ACCESSKIT_ROLE_RADIO_GROUP", .zig_name = "radio_group" },
            .{ .c_name = "ACCESSKIT_ROLE_REGION", .zig_name = "region" },
            .{ .c_name = "ACCESSKIT_ROLE_ROOT_WEB_AREA", .zig_name = "root_web_area" },
            .{ .c_name = "ACCESSKIT_ROLE_RUBY", .zig_name = "ruby" },
            .{ .c_name = "ACCESSKIT_ROLE_RUBY_ANNOTATION", .zig_name = "ruby_annotation" },
            .{ .c_name = "ACCESSKIT_ROLE_SCROLL_BAR", .zig_name = "scroll_bar" },
            .{ .c_name = "ACCESSKIT_ROLE_SCROLL_VIEW", .zig_name = "scroll_view" },
            .{ .c_name = "ACCESSKIT_ROLE_SEARCH", .zig_name = "search" },
            .{ .c_name = "ACCESSKIT_ROLE_SECTION", .zig_name = "section" },
            .{ .c_name = "ACCESSKIT_ROLE_SECTION_FOOTER", .zig_name = "section_footer" },
            .{ .c_name = "ACCESSKIT_ROLE_SECTION_HEADER", .zig_name = "section_header" },
            .{ .c_name = "ACCESSKIT_ROLE_SLIDER", .zig_name = "slider" },
            .{ .c_name = "ACCESSKIT_ROLE_SPIN_BUTTON", .zig_name = "spin_button" },
            .{ .c_name = "ACCESSKIT_ROLE_SPLITTER", .zig_name = "splitter" },
            .{ .c_name = "ACCESSKIT_ROLE_STATUS", .zig_name = "status" },
            .{ .c_name = "ACCESSKIT_ROLE_STRONG", .zig_name = "strong" },
            .{ .c_name = "ACCESSKIT_ROLE_SUGGESTION", .zig_name = "suggestion" },
            .{ .c_name = "ACCESSKIT_ROLE_SVG_ROOT", .zig_name = "svg_root" },
            .{ .c_name = "ACCESSKIT_ROLE_TAB", .zig_name = "tab" },
            .{ .c_name = "ACCESSKIT_ROLE_TAB_LIST", .zig_name = "tab_list" },
            .{ .c_name = "ACCESSKIT_ROLE_TAB_PANEL", .zig_name = "tab_panel" },
            .{ .c_name = "ACCESSKIT_ROLE_TERM", .zig_name = "term" },
            .{ .c_name = "ACCESSKIT_ROLE_TIME", .zig_name = "time" },
            .{ .c_name = "ACCESSKIT_ROLE_TIMER", .zig_name = "timer" },
            .{ .c_name = "ACCESSKIT_ROLE_TITLE_BAR", .zig_name = "title_bar" },
            .{ .c_name = "ACCESSKIT_ROLE_TOOLBAR", .zig_name = "toolbar" },
            .{ .c_name = "ACCESSKIT_ROLE_TOOLTIP", .zig_name = "tooltip" },
            .{ .c_name = "ACCESSKIT_ROLE_TREE", .zig_name = "tree" },
            .{ .c_name = "ACCESSKIT_ROLE_TREE_GRID", .zig_name = "tree_grid" },
            .{ .c_name = "ACCESSKIT_ROLE_VIDEO", .zig_name = "video" },
            .{ .c_name = "ACCESSKIT_ROLE_WEB_VIEW", .zig_name = "web_view" },
            .{ .c_name = "ACCESSKIT_ROLE_WINDOW", .zig_name = "window" },
            .{
                .c_name = "ACCESSKIT_ROLE_PDF_ACTIONABLE_HIGHLIGHT",
                .zig_name = "pdf_actionable_highlight",
            },
            .{ .c_name = "ACCESSKIT_ROLE_PDF_ROOT", .zig_name = "pdf_root" },
            .{ .c_name = "ACCESSKIT_ROLE_GRAPHICS_DOCUMENT", .zig_name = "graphics_document" },
            .{ .c_name = "ACCESSKIT_ROLE_GRAPHICS_OBJECT", .zig_name = "graphics_object" },
            .{ .c_name = "ACCESSKIT_ROLE_GRAPHICS_SYMBOL", .zig_name = "graphics_symbol" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_ABSTRACT", .zig_name = "doc_abstract" },
            .{
                .c_name = "ACCESSKIT_ROLE_DOC_ACKNOWLEDGEMENTS",
                .zig_name = "doc_acknowledgements",
            },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_AFTERWORD", .zig_name = "doc_afterword" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_APPENDIX", .zig_name = "doc_appendix" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_BACK_LINK", .zig_name = "doc_back_link" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_BIBLIO_ENTRY", .zig_name = "doc_biblio_entry" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_BIBLIOGRAPHY", .zig_name = "doc_bibliography" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_BIBLIO_REF", .zig_name = "doc_biblio_ref" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_CHAPTER", .zig_name = "doc_chapter" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_COLOPHON", .zig_name = "doc_colophon" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_CONCLUSION", .zig_name = "doc_conclusion" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_COVER", .zig_name = "doc_cover" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_CREDIT", .zig_name = "doc_credit" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_CREDITS", .zig_name = "doc_credits" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_DEDICATION", .zig_name = "doc_dedication" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_ENDNOTE", .zig_name = "doc_endnote" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_ENDNOTES", .zig_name = "doc_endnotes" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_EPIGRAPH", .zig_name = "doc_epigraph" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_EPILOGUE", .zig_name = "doc_epilogue" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_ERRATA", .zig_name = "doc_errata" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_EXAMPLE", .zig_name = "doc_example" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_FOOTNOTE", .zig_name = "doc_footnote" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_FOREWORD", .zig_name = "doc_foreword" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_GLOSSARY", .zig_name = "doc_glossary" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_GLOSS_REF", .zig_name = "doc_gloss_ref" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_INDEX", .zig_name = "doc_index" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_INTRODUCTION", .zig_name = "doc_introduction" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_NOTE_REF", .zig_name = "doc_note_ref" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_NOTICE", .zig_name = "doc_notice" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_PAGE_BREAK", .zig_name = "doc_page_break" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_PAGE_FOOTER", .zig_name = "doc_page_footer" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_PAGE_HEADER", .zig_name = "doc_page_header" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_PAGE_LIST", .zig_name = "doc_page_list" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_PART", .zig_name = "doc_part" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_PREFACE", .zig_name = "doc_preface" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_PROLOGUE", .zig_name = "doc_prologue" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_PULLQUOTE", .zig_name = "doc_pullquote" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_QNA", .zig_name = "doc_qna" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_SUBTITLE", .zig_name = "doc_subtitle" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_TIP", .zig_name = "doc_tip" },
            .{ .c_name = "ACCESSKIT_ROLE_DOC_TOC", .zig_name = "doc_toc" },
            .{ .c_name = "ACCESSKIT_ROLE_LIST_GRID", .zig_name = "list_grid" },
            .{ .c_name = "ACCESSKIT_ROLE_TERMINAL", .zig_name = "terminal" },
        },
    },
    .{
        .key = .scroll_hint,
        .c_name = "accesskit_scroll_hint",
        .header_line = 702,
        .c_prefix = "SCROLL_HINT",
        .zig_type = schema.ScrollHint,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_SCROLL_HINT_TOP_LEFT", .zig_name = "top_left" },
            .{ .c_name = "ACCESSKIT_SCROLL_HINT_BOTTOM_RIGHT", .zig_name = "bottom_right" },
            .{ .c_name = "ACCESSKIT_SCROLL_HINT_TOP_EDGE", .zig_name = "top_edge" },
            .{ .c_name = "ACCESSKIT_SCROLL_HINT_BOTTOM_EDGE", .zig_name = "bottom_edge" },
            .{ .c_name = "ACCESSKIT_SCROLL_HINT_LEFT_EDGE", .zig_name = "left_edge" },
            .{ .c_name = "ACCESSKIT_SCROLL_HINT_RIGHT_EDGE", .zig_name = "right_edge" },
        },
    },
    .{
        .key = .scroll_unit,
        .c_name = "accesskit_scroll_unit",
        .header_line = 729,
        .c_prefix = "SCROLL_UNIT",
        .zig_type = schema.ScrollUnit,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_SCROLL_UNIT_ITEM", .zig_name = "item" },
            .{ .c_name = "ACCESSKIT_SCROLL_UNIT_PAGE", .zig_name = "page" },
        },
    },
    .{
        .key = .sort_direction,
        .c_name = "accesskit_sort_direction",
        .header_line = 752,
        .c_prefix = "SORT_DIRECTION",
        .zig_type = schema.SortDirection,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_SORT_DIRECTION_ASCENDING", .zig_name = "ascending" },
            .{ .c_name = "ACCESSKIT_SORT_DIRECTION_DESCENDING", .zig_name = "descending" },
            .{ .c_name = "ACCESSKIT_SORT_DIRECTION_OTHER", .zig_name = "other" },
        },
    },
    .{
        .key = .text_align,
        .c_name = "accesskit_text_align",
        .header_line = 776,
        .c_prefix = "TEXT_ALIGN",
        .zig_type = schema.TextAlign,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_TEXT_ALIGN_LEFT", .zig_name = "left" },
            .{ .c_name = "ACCESSKIT_TEXT_ALIGN_RIGHT", .zig_name = "right" },
            .{ .c_name = "ACCESSKIT_TEXT_ALIGN_CENTER", .zig_name = "center" },
            .{ .c_name = "ACCESSKIT_TEXT_ALIGN_JUSTIFY", .zig_name = "justify" },
        },
    },
    .{
        .key = .text_decoration_style,
        .c_name = "accesskit_text_decoration_style",
        .header_line = 801,
        .c_prefix = "TEXT_DECORATION_STYLE",
        .zig_type = schema.TextDecorationStyle,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_TEXT_DECORATION_STYLE_SOLID", .zig_name = "solid" },
            .{ .c_name = "ACCESSKIT_TEXT_DECORATION_STYLE_DOTTED", .zig_name = "dotted" },
            .{ .c_name = "ACCESSKIT_TEXT_DECORATION_STYLE_DASHED", .zig_name = "dashed" },
            .{ .c_name = "ACCESSKIT_TEXT_DECORATION_STYLE_DOUBLE", .zig_name = "double" },
            .{ .c_name = "ACCESSKIT_TEXT_DECORATION_STYLE_WAVY", .zig_name = "wavy" },
        },
    },
    .{
        .key = .text_direction,
        .c_name = "accesskit_text_direction",
        .header_line = 827,
        .c_prefix = "TEXT_DIRECTION",
        .zig_type = schema.TextDirection,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_TEXT_DIRECTION_LEFT_TO_RIGHT", .zig_name = "left_to_right" },
            .{ .c_name = "ACCESSKIT_TEXT_DIRECTION_RIGHT_TO_LEFT", .zig_name = "right_to_left" },
            .{ .c_name = "ACCESSKIT_TEXT_DIRECTION_TOP_TO_BOTTOM", .zig_name = "top_to_bottom" },
            .{ .c_name = "ACCESSKIT_TEXT_DIRECTION_BOTTOM_TO_TOP", .zig_name = "bottom_to_top" },
        },
    },
    .{
        .key = .toggled,
        .c_name = "accesskit_toggled",
        .header_line = 852,
        .c_prefix = "TOGGLED",
        .zig_type = schema.Toggled,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_TOGGLED_FALSE", .zig_name = "false_" },
            .{ .c_name = "ACCESSKIT_TOGGLED_TRUE", .zig_name = "true_" },
            .{ .c_name = "ACCESSKIT_TOGGLED_MIXED", .zig_name = "mixed" },
        },
    },
    .{
        .key = .vertical_offset,
        .c_name = "accesskit_vertical_offset",
        .header_line = 876,
        .c_prefix = "VERTICAL_OFFSET",
        .zig_type = schema.VerticalOffset,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_VERTICAL_OFFSET_SUBSCRIPT", .zig_name = "subscript" },
            .{ .c_name = "ACCESSKIT_VERTICAL_OFFSET_SUPERSCRIPT", .zig_name = "superscript" },
        },
    },
    .{
        .key = .action_data_tag,
        .c_name = "accesskit_action_data_Tag",
        .header_line = 1606,
        .c_prefix = "ACTION_DATA",
        .zig_type = schema.ActionDataTag,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_ACTION_DATA_CUSTOM_ACTION", .zig_name = "custom_action" },
            .{ .c_name = "ACCESSKIT_ACTION_DATA_VALUE", .zig_name = "value" },
            .{ .c_name = "ACCESSKIT_ACTION_DATA_NUMERIC_VALUE", .zig_name = "numeric_value" },
            .{ .c_name = "ACCESSKIT_ACTION_DATA_SCROLL_UNIT", .zig_name = "scroll_unit" },
            .{ .c_name = "ACCESSKIT_ACTION_DATA_SCROLL_HINT", .zig_name = "scroll_hint" },
            .{ .c_name = "ACCESSKIT_ACTION_DATA_SCROLL_TO_POINT", .zig_name = "scroll_to_point" },
            .{
                .c_name = "ACCESSKIT_ACTION_DATA_SET_SCROLL_OFFSET",
                .zig_name = "set_scroll_offset",
            },
            .{
                .c_name = "ACCESSKIT_ACTION_DATA_SET_TEXT_SELECTION",
                .zig_name = "set_text_selection",
            },
        },
    },
    .{
        .key = .error_tag,
        .c_name = "accesskit_error",
        .header_line = 1774,
        .c_prefix = "ERROR",
        .zig_type = allocation.Tag,
        .tags = &.{
            .{ .c_name = "ACCESSKIT_ERROR_NONE", .zig_name = "none" },
            .{ .c_name = "ACCESSKIT_ERROR_OUT_OF_MEMORY", .zig_name = "out_of_memory" },
        },
    },
};

/// The row for `key`.
///
/// `comptime`, so a caller names the row and the compiler picks it; there is no
/// run-time lookup and no run-time failure. The returned value is a copy of
/// `const` data and is never released.
pub fn rowFor(comptime key: EnumDomain) EnumRow {
    return enum_rows[@intFromEnum(key)];
}

/// How many tags `enum_rows` carries between them: 272.
///
/// Read off the table rather than repeated, so a row that gains or loses a tag
/// is counted here with no edit, and the `comptime` block pins the result
/// against the number the header carries.
pub const tagCount: u32 = blk: {
    var total: u32 = 0;
    for (enum_rows) |row| total += @intCast(row.tags.len);
    break :blk total;
};

/// One entry of the flattened table, with everything a run-time check needs and
/// nothing a run-time check cannot have.
///
/// `zig_type` is deliberately absent: `@typeInfo` needs a comptime type, so a
/// run-time test reads the two facts the flatten step already resolved rather
/// than reflecting on a type it can only name at comptime.
pub const TagEntry = struct {
    /// The enumerator as the header spells it.
    c_name: []const u8,
    /// The variant as the schema enum spells it.
    zig_name: []const u8,
    /// The row's `c_prefix`, so a test can check the spelling without the table.
    c_prefix: []const u8,
    /// The wire byte this entry sits at, which is its index in its row and its
    /// value in its enum.
    discriminant: u32,
    /// Which row of `EnumDomain` this entry came from, so a run-time walk can
    /// tell one row's last tag from the next row's first.
    row_index: u32,
    /// How many tags the row this entry came from carries.
    row_length: u32,
    /// True when `zig_name` is a declared variant of the row's enum and it
    /// carries `discriminant`. A false here is a row that names a variant the
    /// enum does not declare, or names one at the wrong wire byte.
    resolved: bool,
};

/// `enum_rows` flattened into row order, one entry per tag, and the per-row
/// verdict a run-time test reads.
///
/// Both come from one pass so the two cannot disagree: the entries and the
/// verdicts are read off the same walk of the same table. The walk is the only
/// loop in this file that runs over the tag domain, and its bound is
/// `tagCount`, which is 272.
const flat = flatten();

/// The flattened table, one entry per tag, in row order.
///
/// The result is `const` data in the binary image: a reader holds a `c_name`
/// for as long as it likes and nothing here is released.
pub const tag_entries: [tagCount]TagEntry = flat.entries;

/// The flattened table and the per-row verdicts, in one pass.
fn flatten() struct { entries: [tagCount]TagEntry, rows_agree: [enumDomainCount]bool } {
    // The walk is one evaluation over 272 entries, which is past the 1000
    // backwards branches the evaluator allows by default. The quota is raised
    // rather than the walk split, because a split would let the two halves
    // disagree and a disagreement here is the whole thing this file exists to
    // catch.
    @setEvalBranchQuota(200_000);
    var collected: [tagCount]TagEntry = undefined;
    var verdicts: [enumDomainCount]bool = undefined;
    var at: usize = 0;
    for (enum_rows, 0..) |row, position| {
        const fields = fieldsOf(row.zig_type);
        var agrees = fields.len == row.tags.len;
        for (row.tags, 0..) |entry, index| {
            const resolved = index < fields.len and
                fields[index].value == index and
                std.mem.eql(u8, fields[index].name, entry.zig_name);
            agrees = agrees and resolved;
            collected[at] = .{
                .c_name = entry.c_name,
                .zig_name = entry.zig_name,
                .c_prefix = row.c_prefix,
                .discriminant = @intCast(index),
                .row_index = @intCast(position),
                .row_length = @intCast(row.tags.len),
                .resolved = resolved,
            };
            at += 1;
        }
        verdicts[position] = agrees;
    }
    return .{ .entries = collected, .rows_agree = verdicts };
}

/// Whether every row's tag count is its enum's field count and every row's
/// variant carries the wire byte the row places it at.
///
/// Computed once so the run-time test can read it, and recomputed here from the
/// same pass `tag_entries` came from rather than asserted twice.
pub const rows_agree: [enumDomainCount]bool = flat.rows_agree;

/// Each row's C type name and tag count, in `EnumDomain` order.
///
/// `enum_rows` cannot be indexed at run time, because a `type` field has no
/// run-time form, so a test that has to name the row it failed on, or count the
/// row's tags, reads these instead. Built from the table rather than written
/// out, so the two cannot disagree.
pub const row_names: [enumDomainCount][]const u8 = row_facts.names;

/// How many tags each row carries, in `EnumDomain` order.
pub const row_lengths: [enumDomainCount]u32 = row_facts.lengths;

const row_facts = struct {
    names: [enumDomainCount][]const u8,
    lengths: [enumDomainCount]u32,
}{
    .names = blk: {
        var collected: [enumDomainCount][]const u8 = undefined;
        for (enum_rows, 0..) |row, index| collected[index] = row.c_name;
        break :blk collected;
    },
    .lengths = blk: {
        var collected: [enumDomainCount]u32 = undefined;
        for (enum_rows, 0..) |row, index| collected[index] = @intCast(row.tags.len);
        break :blk collected;
    },
};

comptime {
    // Every walk in this block is over the whole 272-tag table at once, which is
    // past the 1000 backwards branches the evaluator allows by default. The
    // quota is raised once here rather than per check, because a per-check quota
    // would let one check's exhaustion look like another's failure.
    @setEvalBranchQuota(200_000);
    // The two bounds this file's loops run over, pinned against the header's
    // own numbers: nineteen enumerations, 272 enumerators between them.
    if (enumDomainCount != 19) @compileError("the header declares nineteen enumerations");
    if (tagCount != 272) @compileError("the header declares 272 enumerators");

    // `enum_rows` has one row per member of `EnumDomain`, in this order, so a
    // twentieth enumeration is a build failure here rather than a row nobody
    // reads.
    for (std.enums.values(EnumDomain), 0..) |member, index| {
        std.debug.assert(enum_rows[index].key == member);
        // Every row's type name is the header's own name, and every header
        // name begins with the prefix the C consumer writes.
        std.debug.assert(std.mem.startsWith(u8, enum_rows[index].c_name, "accesskit_"));
    }

    // The spelling rule, all 272 of them, and the resolution of every row's
    // variant name against its enum. This is the first half of the bijection:
    // every C tag names exactly one Zig variant, at the wire byte the header
    // numbers it.
    for (enum_rows) |row| assertSpelling(row);

    // The property that makes a range check a sound decode, for all nineteen
    // rows including the two with no gate of their own.
    for (std.enums.values(EnumDomain)) |member| assertContiguousDiscriminants(member);

    // The seventeen gates and the two rows with none. The seventeen lines
    // themselves live in `assertEveryGate`, which the test of that name calls,
    // so a gate that stopped answering for one of its own tags fails a named
    // test rather than a bare comptime error with no test attached.
    //
    // The two rows with no gate are named here so that their absence is a
    // decision on the record rather than an omission.
    // `accesskit_action_data_Tag` is decoded by `schema.actionDataFromC`, which
    // pairs each tag with the union member the header lists at the same index,
    // and `accesskit_error` crosses outward only. The contiguous-discriminant
    // sweep above covers both.
    std.debug.assert(rows_agree[@intFromEnum(EnumDomain.action_data_tag)]);
    std.debug.assert(rows_agree[@intFromEnum(EnumDomain.error_tag)]);
}

// --- the checks ----------------------------------------------------------------

/// The head every C enumerator in this header begins with.
///
/// A `[]const u8` and not a string literal, because the rule below copies it and
/// a literal carries a sentinel that a copy does not take.
const enumerator_head: []const u8 = "ACCESSKIT_";

/// The fields of `Tag`, in declaration order.
///
/// `comptime`, so the array is folded away and the checks below index it
/// directly. A row's tag at index `i` is the field at index `i` only once that
/// field's own name has been compared, which is what the checks do; resolving a
/// name by searching the array instead would make every row quadratic in its
/// own width and would spend the whole evaluation budget on `accesskit_role`
/// alone.
fn fieldsOf(comptime Tag: type) []const std.builtin.Type.EnumField {
    return @typeInfo(Tag).@"enum".fields;
}

/// The variant name with the trailing underscore a reserved Zig word carries
/// removed, which is the part a C enumerator spells.
fn cSuffix(comptime zig_name: []const u8) []const u8 {
    if (zig_name[zig_name.len - 1] == '_') return zig_name[0 .. zig_name.len - 1];
    return zig_name;
}

/// How many bytes the spelling rule produces for `zig_name` in `row`.
fn expectedCNameLength(comptime row: EnumRow, comptime zig_name: []const u8) usize {
    return enumerator_head.len + row.c_prefix.len + 1 + cSuffix(zig_name).len;
}

/// The C enumerator the spelling rule produces for `zig_name` in `row`.
///
/// `ACCESSKIT_` ++ the row's prefix ++ `_` ++ the variant's name in upper
/// case, with a trailing underscore dropped. The header spells all 272 this
/// way, and this is what makes a C name that is unique but wrong a build
/// failure rather than a test that passes.
fn expectedCName(
    comptime row: EnumRow,
    comptime zig_name: []const u8,
) [expectedCNameLength(row, zig_name)]u8 {
    @setEvalBranchQuota(20_000);
    const suffix = cSuffix(zig_name);
    const prefix_at = enumerator_head.len;
    const tail_at = prefix_at + row.c_prefix.len + 1;
    var out: [expectedCNameLength(row, zig_name)]u8 = undefined;
    @memcpy(out[0..prefix_at], enumerator_head);
    @memcpy(out[prefix_at .. prefix_at + row.c_prefix.len], row.c_prefix);
    out[prefix_at + row.c_prefix.len] = '_';
    for (suffix, 0..) |byte, index| {
        out[tail_at + index] = std.ascii.toUpper(byte);
    }
    return out;
}

/// Fails the build unless every tag in `row` names a declared variant of the
/// row's enum, at the wire byte the row places it at, spelled the way the
/// spelling rule produces.
fn assertSpelling(comptime row: EnumRow) void {
    @setEvalBranchQuota(200_000);
    const fields = fieldsOf(row.zig_type);
    for (row.tags, 0..) |entry, index| {
        if (index >= fields.len) @compileError("a row is wider than its enum");
        if (!std.mem.eql(u8, fields[index].name, entry.zig_name)) {
            @compileError("a row names a variant its enum does not declare, or not in order");
        }
        if (fields[index].value != index) {
            @compileError("a row is not at the wire byte its enum gives that variant");
        }
        if (!std.mem.eql(u8, &expectedCName(row, entry.zig_name), entry.c_name)) {
            @compileError("a C enumerator is not the spelling its variant produces");
        }
    }
}

/// Fails the build unless every variant of `key`'s enum carries the
/// discriminant its declaration index.
///
/// This is the property that makes a range check a sound decode, and it is what
/// the two rows with no gate of their own rely on: a C byte at or past the
/// field count names no variant, and a decode that compares against the count
/// needs nothing else.
fn assertContiguousDiscriminants(comptime key: EnumDomain) void {
    @setEvalBranchQuota(200_000);
    for (fieldsOf(rowFor(key).zig_type), 0..) |field, index| {
        if (field.value != index) {
            @compileError("a schema enum's discriminant is not its declaration index");
        }
    }
}

/// Fails the build unless `decode` answers for every tag in `key`'s row and
/// rejects the byte one past the end of it.
///
/// `decode` is the gate the layer below owns for this row, named at the call
/// site so that a gate this file stopped believing in is visible in the file
/// rather than implied by it. The last check is the one a round trip cannot
/// reach: every tag decoding correctly says nothing about what the gate does
/// with a byte no tag names, and an unchecked `@enumFromInt` there is
/// undefined behaviour in ReleaseFast rather than a `null`.
fn assertGate(comptime key: EnumDomain, comptime decode: anytype) void {
    @setEvalBranchQuota(200_000);
    const row = rowFor(key);
    const fields = fieldsOf(row.zig_type);
    for (row.tags, 0..) |entry, index| {
        if (index >= fields.len) @compileError("a row is wider than its enum");
        if (!std.mem.eql(u8, fields[index].name, entry.zig_name)) {
            @compileError("a row names a variant its enum does not declare, or not in order");
        }
        const wanted: row.zig_type = @field(row.zig_type, entry.zig_name);
        // The last row's own tag is the byte this loop is about, so a gate that
        // rejects it is a gate with a hole in it. That is a build failure, and
        // naming it is better than a panic nobody would see until runtime.
        const decoded = decode(@intCast(index)) orelse @compileError(
            "a gate rejects the byte its own row places there",
        );
        if (decoded != wanted) {
            @compileError("a gate does not decode the byte its own row places there");
        }
    }
    if (decode(@intCast(row.tags.len)) != null) {
        @compileError("a gate accepts a byte no tag names");
    }
}

// --- tests ---------------------------------------------------------------------

test "the table holds the nineteen enumerations the header declares" {
    try testing.expectEqual(@as(u32, 19), enumDomainCount);
    try testing.expectEqual(enumDomainCount, enum_rows.len);
    try testing.expectEqual(@as(u32, 272), tagCount);
    try testing.expectEqual(tagCount, tag_entries.len);
}

test "every C tag names exactly one Zig variant, at the byte the header numbers it" {
    // The first direction, over all 272 entries and not a sample. `resolved` is
    // the compile-time answer to "is `zig_name` a declared variant of this row's
    // enum, and does it carry the wire byte the row places it at", so a false
    // here is a tag with no variant behind it or a variant at the wrong byte.
    for (tag_entries) |entry| {
        testing.expect(entry.resolved) catch |err| {
            std.debug.print(
                "{s} names {s}, which the enum does not carry at wire byte {d}\n",
                .{ entry.c_name, entry.zig_name, entry.discriminant },
            );
            return err;
        };
        try testing.expect(entry.discriminant < entry.row_length);
    }

    // The wire bytes of each row are 0 to its width less one, once each. The
    // check above says every tag has a variant; this says no two tags in a row
    // claim the same byte, which is the failure the first half cannot see and
    // the one that would let a C caller send one byte and get two answers.
    var current: u32 = 0;
    var next_in_row: u32 = 0;
    for (tag_entries, 0..) |entry, position| {
        if (position != 0 and entry.row_index != current) {
            try testing.expectEqual(row_lengths[current], next_in_row);
            next_in_row = 0;
        }
        current = entry.row_index;
        try testing.expectEqual(next_in_row, entry.discriminant);
        next_in_row += 1;
    }
    try testing.expectEqual(row_lengths[current], next_in_row);
}

test "every Zig variant names exactly one C tag" {
    // The second direction, and the half a count cannot reach: a C name that
    // appears twice would give one C tag two variants, and a per-row check
    // would not see it because the two rows would each be internally
    // consistent. The walk is over the whole table, so a collision between two
    // rows is a collision.
    for (tag_entries, 0..) |entry, outer| {
        for (tag_entries[outer + 1 ..]) |other| {
            if (std.mem.eql(u8, entry.c_name, other.c_name)) {
                std.debug.print(
                    "{s} appears at two places: beside {s} and beside {s}\n",
                    .{ entry.c_name, entry.zig_name, other.zig_name },
                );
                return error.DuplicateCTag;
            }
        }
    }
}

test "every C tag is spelled the way the header spells it" {
    // A C name that is unique but wrong passes the test above, so the spelling
    // is checked here as a property of the run-time table and not only in the
    // `comptime` block: each name must be `ACCESSKIT_`, the row's prefix, `_`,
    // and the variant's own name in upper case.
    for (tag_entries) |entry| {
        const suffix = if (entry.zig_name[entry.zig_name.len - 1] == '_')
            entry.zig_name[0 .. entry.zig_name.len - 1]
        else
            entry.zig_name;
        const head_at = enumerator_head.len;
        const tail_at = head_at + entry.c_prefix.len + 1;
        try testing.expectEqual(tail_at + suffix.len, entry.c_name.len);
        try testing.expectEqualStrings(enumerator_head, entry.c_name[0..head_at]);
        try testing.expectEqualStrings(
            entry.c_prefix,
            entry.c_name[head_at .. head_at + entry.c_prefix.len],
        );
        try testing.expectEqual(@as(u8, '_'), entry.c_name[head_at + entry.c_prefix.len]);
        for (suffix, 0..) |byte, index| {
            try testing.expectEqual(std.ascii.toUpper(byte), entry.c_name[tail_at + index]);
        }
    }
}

test "every row's tag count is its enum's field count" {
    for (rows_agree, 0..) |agrees, index| {
        testing.expect(agrees) catch {
            std.debug.print("the row for {s} does not match its enum\n", .{
                row_names[index],
            });
            return error.RowDisagreesWithEnum;
        };
    }
}

test "every row's gate answers for every tag in the row and rejects one past it" {
    // Resolved while the module is analysed, so a gate that stopped answering
    // for one of its own tags fails *this test* by name rather than as a bare
    // comptime failure. The seventeen lines live in one function so the test
    // and the membership test below read the same seventeen.
    comptime assertEveryGate();
}

/// Fails the build unless all seventeen gates answer for their own rows.
///
/// Each line names the row and the gate together, so a row whose gate is
/// replaced, or a gate moved to a different row, is visible in the file rather
/// than implied by it. `accesskit_action_data_Tag` and `accesskit_error` are
/// not here and this module's doc says why: the first is decoded by
/// `schema.actionDataFromC` and the second crosses outward only, and the
/// contiguous-discriminant sweep in the `comptime` block covers both.
fn assertEveryGate() void {
    // The seventeen sweeps run in one evaluation, and `accesskit_role` alone is
    // 182 of the 255 tags they walk.
    @setEvalBranchQuota(200_000);
    assertGate(.action, schema.actionFromInt);
    assertGate(.aria_current, schema.ariaCurrentFromInt);
    assertGate(.auto_complete, schema.autoCompleteFromInt);
    assertGate(.has_popup, schema.hasPopupFromInt);
    assertGate(.invalid, schema.invalidFromInt);
    assertGate(.list_style, schema.listStyleFromInt);
    assertGate(.live, schema.liveFromInt);
    assertGate(.orientation, schema.orientationFromInt);
    assertGate(.role, node.role_from_c);
    assertGate(.scroll_hint, schema.scrollHintFromInt);
    assertGate(.scroll_unit, schema.scrollUnitFromInt);
    assertGate(.sort_direction, schema.sortDirectionFromInt);
    assertGate(.text_align, schema.textAlignFromInt);
    assertGate(.text_decoration_style, schema.textDecorationStyleFromInt);
    assertGate(.text_direction, schema.textDirectionFromInt);
    assertGate(.toggled, schema.toggledFromInt);
    assertGate(.vertical_offset, schema.verticalOffsetFromInt);
}

test "the seventeen gated rows and the two ungated rows are the whole table" {
    // `assertEveryGate` checks the seventeen gates. This holds the other half
    // of that decision: a row added to `EnumDomain` without a gate beside it
    // there, or a gate in the table for a row that has none, is a row nobody
    // has an opinion about. The two lists below and the seventeen lines in
    // `assertEveryGate` must therefore name the same seventeen rows, and the
    // only way to hold that is for every member to appear exactly once across
    // the two.
    const gated = [_]EnumDomain{
        .action,          .aria_current,          .auto_complete,  .has_popup,
        .invalid,         .list_style,            .live,           .orientation,
        .role,            .scroll_hint,           .scroll_unit,    .sort_direction,
        .text_align,      .text_decoration_style, .text_direction, .toggled,
        .vertical_offset,
    };
    const ungated = [_]EnumDomain{ .action_data_tag, .error_tag };
    try testing.expectEqual(@as(u32, 17), gated.len);
    try testing.expectEqual(@as(u32, 2), ungated.len);
    try testing.expectEqual(enumDomainCount, gated.len + ungated.len);

    // Every member appears exactly once across the two lists, so a new member
    // cannot slip past the seventeen and the two at the same time.
    for (std.enums.values(EnumDomain)) |member| {
        var seen: u32 = 0;
        for (gated) |listed| seen += @intFromBool(listed == member);
        for (ungated) |listed| seen += @intFromBool(listed == member);
        try testing.expectEqual(@as(u32, 1), seen);
    }
}
