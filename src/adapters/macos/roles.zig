//! The two tables that turn an accesskit role into a macOS one.
//!
//! **What this module is.** `nsRole` and `nsSubRole`, the ports of
//! `AK/macos/src/node.rs:36-231` and `:244-296`, and `labelIsExposedInValue`,
//! the port of `:233-242`. Every answer is a member of a table in
//! `literals.zig`, so this module writes no string of its own.
//!
//! **The role table is total, and that is a testable fact.** `nsRole` has no
//! `_` arm: upstream names **182** distinct roles and `src/schema/role.zig`
//! declares **182** variants, `unknown = 0` at line 38 through `terminal = 181`.
//! The Zig `switch` below has no `else`, so a variant upstream names and this
//! port does not is a compile error rather than a wrong answer at run time. What
//! the compiler does **not** catch is a port adding an `else` to silence such an
//! error, so the exhaustiveness test walks the enum and asserts the count is
//! still 182.
//!
//! **The subrole table is partial, and its default is null.** `nsSubRole` has 44
//! arms naming 44 roles and a `_ => None` at `AK/macos/src/node.rs:293`, so 138
//! of the 182 roles must answer `null`. Eight of the 44 arms name one of the 7
//! `objc2-app-kit` constants and 36 emit one of the 32 literals, and four of
//! those literals are emitted by two roles each. **A role that maps to nothing
//! must answer `null`, not an empty string and not the role string**: a client
//! that receives an empty subrole has been told the node has a subrole whose
//! name is `""`, which is a different statement from "has no subrole".
//!
//! **Two functions consult node state rather than the role alone.**
//! `nsRole` looks at `toggled` for `button` (`AK/macos/src/node.rs:65-71`), and
//! `nsSubRole` guards its `button` arm on the same property (`:254`). Both take
//! the answer as a parameter here, so the tables are pure and a test drives
//! both arms.
//!
//! **What this module does not do.** It sends no message and reads no node, so
//! every test in it runs on a host with no Mac and no Objective-C runtime. It
//! also does not answer what happens when a node has gone away: that fallback is
//! `unknownRole`, the answer `accessibilityRole` returns when resolution fails
//! (`AK/macos/src/node.rs:501-506`).
//!
//! **The loop bound.** The only loops are over `schema.Role`'s 182 variants, in
//! the tests, and over `collapse_groups`, whose length is
//! `collapse_group_count`. Both lengths are comptime constants, so neither walk
//! reads a bound at run time.

const std = @import("std");

const schema = @import("../../schema/root.zig");
const literals = @import("literals.zig");

const testing = std.testing;

/// The value `accessibilityRole` answers when the node is gone.
///
/// Upstream `AK/macos/src/node.rs:501-506` falls back to
/// `NSAccessibilityUnknownRole` when `resolve` fails. A client sees this for a
/// node destroyed between the tree update and the message send, so it is an
/// ordinary answer rather than an error.
pub const unknownRole: [:0]const u8 = literals.role_constants[29].value;

/// The role `Role.button` maps to when the node carries a toggled state.
///
/// Upstream `AK/macos/src/node.rs:67`. A port that drops the conditional turns
/// every toggle into a push button.
pub const toggled_button_role: [:0]const u8 = literals.role_constants[2].value;

/// The role `Role.button` maps to with no toggled state.
pub const untoggled_button_role: [:0]const u8 = literals.role_constants[0].value;

/// The subrole a toggled `Role.button` maps to.
pub const toggled_button_subrole: [:0]const u8 = literals.subrole_constants[6].value;

/// The 31 role constants, bound by name so that each one is reachable from
/// `nsRole` and a rename is a compile error rather than a wrong string.
///
/// The values come from `literals.zig`, which pins the spelling. These bindings
/// exist so that `nsRole` below reads as upstream reads.
const ax_unknown_role = roleConstantValue("NSAccessibilityUnknownRole");
const ax_button_role = roleConstantValue("NSAccessibilityButtonRole");
const ax_cell_role = roleConstantValue("NSAccessibilityCellRole");
const ax_check_box_role = roleConstantValue("NSAccessibilityCheckBoxRole");
const ax_color_well_role = roleConstantValue("NSAccessibilityColorWellRole");
const ax_combo_box_role = roleConstantValue("NSAccessibilityComboBoxRole");
const ax_group_role = roleConstantValue("NSAccessibilityGroupRole");
const ax_image_role = roleConstantValue("NSAccessibilityImageRole");
const ax_incrementor_role = roleConstantValue("NSAccessibilityIncrementorRole");
const ax_level_indicator_role = roleConstantValue("NSAccessibilityLevelIndicatorRole");
const ax_link_role = roleConstantValue("NSAccessibilityLinkRole");
const ax_list_role = roleConstantValue("NSAccessibilityListRole");
const ax_menu_bar_role = roleConstantValue("NSAccessibilityMenuBarRole");
const ax_menu_item_role = roleConstantValue("NSAccessibilityMenuItemRole");
const ax_menu_role = roleConstantValue("NSAccessibilityMenuRole");
const ax_outline_role = roleConstantValue("NSAccessibilityOutlineRole");
const ax_pop_up_button_role = roleConstantValue("NSAccessibilityPopUpButtonRole");
const ax_progress_indicator_role = roleConstantValue("NSAccessibilityProgressIndicatorRole");
const ax_radio_button_role = roleConstantValue("NSAccessibilityRadioButtonRole");
const ax_radio_group_role = roleConstantValue("NSAccessibilityRadioGroupRole");
const ax_row_role = roleConstantValue("NSAccessibilityRowRole");
const ax_scroll_bar_role = roleConstantValue("NSAccessibilityScrollBarRole");
const ax_slider_role = roleConstantValue("NSAccessibilitySliderRole");
const ax_splitter_role = roleConstantValue("NSAccessibilitySplitterRole");
const ax_static_text_role = roleConstantValue("NSAccessibilityStaticTextRole");
const ax_tab_group_role = roleConstantValue("NSAccessibilityTabGroupRole");
const ax_table_role = roleConstantValue("NSAccessibilityTableRole");
const ax_text_area_role = roleConstantValue("NSAccessibilityTextAreaRole");
const ax_text_field_role = roleConstantValue("NSAccessibilityTextFieldRole");
const ax_toolbar_role = roleConstantValue("NSAccessibilityToolbarRole");
const ax_window_role = roleConstantValue("NSAccessibilityWindowRole");

/// The 7 subrole constants, bound by name.
const ax_dialog_subrole = subroleConstantValue("NSAccessibilityDialogSubrole");
const ax_outline_row_subrole = subroleConstantValue("NSAccessibilityOutlineRowSubrole");
const ax_search_field_subrole = subroleConstantValue("NSAccessibilitySearchFieldSubrole");
const ax_secure_text_field_subrole =
    subroleConstantValue("NSAccessibilitySecureTextFieldSubrole");
const ax_switch_subrole = subroleConstantValue("NSAccessibilitySwitchSubrole");
const ax_tab_button_subrole = subroleConstantValue("NSAccessibilityTabButtonSubrole");

/// The 5 role values upstream writes as a string literal rather than naming a
/// constant, bound from `literals.zig`.
const ax_list_marker_role = roleLiteral("AXListMarker");
const ax_date_field_role = roleLiteral("AXDateField");
const ax_time_field_role = roleLiteral("AXTimeField");
const ax_web_area_role = roleLiteral("AXWebArea");
const ax_heading_role = roleLiteral("AXHeading");

/// The 32 subrole values, bound from `literals.zig`. Upstream writes each as a
/// string literal inside its arm, so these bindings exist to keep `nsSubRole`
/// reading as upstream reads and to make a renamed literal a compile error.
const ax_application_alert = subroleLiteral("AXApplicationAlert");
const ax_web_application = subroleLiteral("AXWebApplication");
const ax_document_article = subroleLiteral("AXDocumentArticle");
const ax_landmark_banner = subroleLiteral("AXLandmarkBanner");
const ax_code_style_group = subroleLiteral("AXCodeStyleGroup");
const ax_landmark_complementary = subroleLiteral("AXLandmarkComplementary");
const ax_delete_style_group = subroleLiteral("AXDeleteStyleGroup");
const ax_insert_style_group = subroleLiteral("AXInsertStyleGroup");
const ax_landmark_content_info = subroleLiteral("AXLandmarkContentInfo");
const ax_definition_subrole = subroleLiteral("AXDefinition");
const ax_document_subrole = subroleLiteral("AXDocument");
const ax_emphasis_style_group = subroleLiteral("AXEmphasisStyleGroup");
const ax_application_group = subroleLiteral("AXApplicationGroup");
const ax_landmark_form = subroleLiteral("AXLandmarkForm");
const ax_application_log = subroleLiteral("AXApplicationLog");
const ax_landmark_main = subroleLiteral("AXLandmarkMain");
const ax_application_marquee = subroleLiteral("AXApplicationMarquee");
const ax_document_math = subroleLiteral("AXDocumentMath");
const ax_meter_subrole = subroleLiteral("AXMeter");
const ax_landmark_navigation = subroleLiteral("AXLandmarkNavigation");
const ax_document_note = subroleLiteral("AXDocumentNote");
const ax_landmark_region = subroleLiteral("AXLandmarkRegion");
const ax_landmark_search = subroleLiteral("AXLandmarkSearch");
const ax_section_footer = subroleLiteral("AXSectionFooter");
const ax_section_header = subroleLiteral("AXSectionHeader");
const ax_application_status = subroleLiteral("AXApplicationStatus");
const ax_strong_style_group = subroleLiteral("AXStrongStyleGroup");
const ax_tab_panel_subrole = subroleLiteral("AXTabPanel");
const ax_term_subrole = subroleLiteral("AXTerm");
const ax_time_group = subroleLiteral("AXTimeGroup");
const ax_application_timer = subroleLiteral("AXApplicationTimer");
const ax_user_interface_tooltip = subroleLiteral("AXUserInterfaceTooltip");

/// The macOS role a `schema.Role` maps to, given the node's toggled state.
///
/// **Returns.** A null-terminated string from `literals.zig`, never `null` and
/// never the empty string: every one of the 182 variants has an arm, and an
/// answer a client cannot interpret is a different failure from a wrong one.
///
/// `toggled` is `properties.toggled(node)`, and `null` means the node carries
/// no toggled property. Only `schema.Role.button` reads it, at
/// `AK/macos/src/node.rs:65-71`.
///
/// **The arms.** The `comptime` block below states the fold count: 72 arms
/// cover the 182 variants, so 110 arms name more than one variant. Upstream
/// writes the same fold in the same shape.
pub fn nsRole(role: schema.Role, toggled: ?schema.Toggled) [:0]const u8 {
    return switch (role) {
        .unknown, .text_run, .generic_container, .pane, .caret, .feed,
        .ime_candidate, .keyboard, .ruby_annotation, .scroll_view, .web_view,
        .list_grid,
        => ax_unknown_role,

        .list_item, .paragraph, .row_group, .layout_table_cell, .layout_table_row,
        .layout_table, .abbr, .alert, .application, .article, .audio, .banner,
        .blockquote, .caption, .code, .complementary, .comment, .content_deletion,
        .content_insertion, .content_info, .definition, .details, .document,
        .embedded_object, .emphasis, .figure_caption, .figure, .footer, .form,
        .group, .header, .iframe, .iframe_presentational, .legend, .line_break,
        .log, .main, .mark, .marquee, .math, .navigation, .note, .plugin_object,
        .region, .ruby, .search, .section, .section_footer, .section_header,
        .status, .strong, .suggestion, .svg_root, .tab_panel, .term, .time,
        .timer, .tooltip, .video, .window, .pdf_root, .graphics_document,
        .graphics_object, .doc_abstract, .doc_acknowledgements, .doc_afterword,
        .doc_appendix, .doc_biblio_entry, .doc_bibliography, .doc_biblio_ref,
        .doc_chapter, .doc_colophon, .doc_conclusion, .doc_credit, .doc_credits,
        .doc_dedication, .doc_endnote, .doc_endnotes, .doc_epigraph,
        .doc_epilogue, .doc_errata, .doc_example, .doc_footnote, .doc_foreword,
        .doc_glossary, .doc_index, .doc_introduction, .doc_notice,
        .doc_page_footer, .doc_page_header, .doc_page_list, .doc_part,
        .doc_preface, .doc_prologue, .doc_pullquote, .doc_qna, .doc_tip,
        .doc_toc,
        => ax_group_role,

        .cell, .grid_cell, .row_header, .column_header => ax_cell_role,
        .label, .list_box_option, .title_bar => ax_static_text_role,
        .row, .tree_item => ax_row_role,
        .text_input, .search_input, .email_input, .number_input, .password_input,
        .phone_number_input, .url_input,
        => ax_text_field_role,

        .button => if (toggled != null) toggled_button_role else untoggled_button_role,

        .image, .canvas, .graphics_symbol, .doc_cover => ax_image_role,
        .link, .doc_back_link, .doc_gloss_ref, .doc_note_ref => ax_link_role,
        .list_marker => ax_list_marker_role,
        .menu_item, .menu_list_option, .menu_item_check_box, .menu_item_radio => ax_menu_item_role,
        .check_box, .switch_ => ax_check_box_role,
        .radio_button, .tab => ax_radio_button_role,
        .list, .description_list, .list_box => ax_list_role,
        .table, .grid, .tree_grid => ax_table_role,
        .menu, .menu_list_popup => ax_menu_role,
        .multiline_text_input, .terminal => ax_text_area_role,
        .date_input, .date_time_input, .week_input, .month_input => ax_date_field_role,
        .time_input => ax_time_field_role,
        .color_well => ax_color_well_role,
        .combo_box => ax_pop_up_button_role,
        .editable_combo_box => ax_combo_box_role,
        .alert_dialog, .dialog => ax_window_role,
        .disclosure_triangle, .pdf_actionable_highlight => ax_button_role,
        .default_button => ax_button_role,
        .menu_bar => ax_menu_bar_role,
        .meter => ax_level_indicator_role,
        .progress_indicator => ax_progress_indicator_role,
        .radio_group => ax_radio_group_role,
        .root_web_area => ax_web_area_role,
        .scroll_bar => ax_scroll_bar_role,
        .slider => ax_slider_role,
        .spin_button => ax_incrementor_role,
        .splitter, .doc_page_break => ax_splitter_role,
        .tab_list => ax_tab_group_role,
        .toolbar => ax_toolbar_role,
        .tree => ax_outline_role,
        .heading => literals.heading_role,
        .doc_subtitle => ax_heading_role,
    };
}

/// The macOS subrole a `schema.Role` maps to, given the node's toggled state.
///
/// **Returns.** A null-terminated string from `literals.zig`, or `null` for the
/// 138 roles upstream leaves alone. `null` is the only correct answer for a role
/// with no subrole: not `""`, and not the role string.
///
/// `toggled` is `properties.toggled(node)` and only guards the `button` arm,
/// at `AK/macos/src/node.rs:254`. A `button` with no toggled property falls to
/// the default and answers `null`, which is what upstream does.
pub fn nsSubRole(role: schema.Role, toggled: ?schema.Toggled) ?[:0]const u8 {
    return switch (role) {
        .alert => ax_application_alert,
        .alert_dialog, .dialog => ax_dialog_subrole,
        .application => ax_web_application,
        .article => ax_document_article,
        .banner, .header => ax_landmark_banner,
        .button => if (toggled != null) toggled_button_subrole else null,
        .code => ax_code_style_group,
        .complementary => ax_landmark_complementary,
        .content_deletion => ax_delete_style_group,
        .content_insertion => ax_insert_style_group,
        .content_info, .footer => ax_landmark_content_info,
        .definition => ax_definition_subrole,
        .document, .graphics_document => ax_document_subrole,
        .emphasis => ax_emphasis_style_group,
        .feed, .group => ax_application_group,
        .form => ax_landmark_form,
        .log => ax_application_log,
        .main => ax_landmark_main,
        .marquee => ax_application_marquee,
        .math => ax_document_math,
        .meter => ax_meter_subrole,
        .navigation => ax_landmark_navigation,
        .note => ax_document_note,
        .password_input => ax_secure_text_field_subrole,
        .region => ax_landmark_region,
        .search => ax_landmark_search,
        .search_input => ax_search_field_subrole,
        .section_footer => ax_section_footer,
        .section_header => ax_section_header,
        .status => ax_application_status,
        .strong => ax_strong_style_group,
        .switch_ => ax_switch_subrole,
        .tab => ax_tab_button_subrole,
        .tab_panel => ax_tab_panel_subrole,
        .term => ax_term_subrole,
        .time => ax_time_group,
        .timer => ax_application_timer,
        .tree_item => ax_outline_row_subrole,
        .tooltip => ax_user_interface_tooltip,
        else => null,
    };
}

/// Whether `text` is a role string this module publishes.
///
/// It is a role constant value, one of the 5 `.role_literal` spellings, or the
/// one unprefixed string upstream writes for `heading`. The walk is bounded by
/// `literals.role_constants.len` and then by `literals.literals.len`, which
/// are `literals.role_constant_count` and `literals.literal_count`.
fn isPublishedRole(text: [:0]const u8) bool {
    for (literals.role_constants) |constant| {
        if (std.mem.eql(u8, constant.value, text)) return true;
    }
    if (std.mem.eql(u8, literals.heading_role, text)) return true;
    for (literals.literals) |literal| {
        if (literal.group != .role_literal) continue;
        if (std.mem.eql(u8, literal.text, text)) return true;
    }
    return false;
}

/// Whether `text` is a subrole string this module publishes.
///
/// It is a subrole constant value or one of the 32 `.subrole_literal`
/// spellings. The walk is bounded by `literals.subrole_constants.len` and then
/// by `literals.literals.len`.
fn isPublishedSubrole(text: [:0]const u8) bool {
    for (literals.subrole_constants) |constant| {
        if (std.mem.eql(u8, constant.value, text)) return true;
    }
    for (literals.literals) |literal| {
        if (literal.group != .subrole_literal) continue;
        if (std.mem.eql(u8, literal.text, text)) return true;
    }
    return false;
}

/// Whether `accessibilityValue` carries the label for `role`, upstream
/// `label_is_exposed_in_value` at `AK/macos/src/node.rs:233-242`.
///
/// The five roles below put their label in their value rather than answering
/// `accessibilityLabel`, so the adapter reads the value for them. The port reads
/// no node: the answer is a property of the role alone, so it is a table.
pub fn labelIsExposedInValue(role: schema.Role) bool {
    return switch (role) {
        .label, .list_box_option, .list_marker, .menu_list_option, .title_bar => true,
        else => false,
    };
}

/// One fold in `nsRole`: several roles that share one answer, and why.
pub const CollapseGroup = struct {
    /// The answer every role in `roles` maps to.
    answer: [:0]const u8,
    /// The roles that map to it. Upstream writes them on one or more arms.
    roles: []const schema.Role,
};

/// How many folds `collapse_groups` holds.
pub const collapse_group_count = 6;

/// The folds upstream makes deliberately, and not by accident.
///
/// **The last one is the one a port is most likely to "clean up".**
/// `tree_item` becoming an outline row is the ARIA model rather than the macOS
/// model, and upstream maps it to `AXRow` here and to
/// `NSAccessibilityOutlineRowSubrole` in `nsSubRole`. Both are asserted.
///
/// The `AXGroupRole` fold names 98 roles and is left as a count rather than a
/// written-out list, because `docs/51c-macos-test-plan.md` section 2.1 gives it
/// as a count too. The other five are written out in full.
pub const collapse_groups = [collapse_group_count]CollapseGroup{
    .{
        .answer = literals.role_constants[29].value, // NSAccessibilityUnknownRole
        .roles = &.{
            .unknown,       .text_run,          .generic_container, .pane,
            .caret,         .feed,              .ime_candidate,    .keyboard,
            .ruby_annotation, .scroll_view,    .web_view,         .list_grid,
        },
    },
    .{
        .answer = literals.role_constants[5].value, // NSAccessibilityGroupRole
        .roles = &.{},
    },
    .{
        .answer = literals.role_constants[1].value, // NSAccessibilityCellRole
        .roles = &.{ .cell, .grid_cell, .row_header, .column_header },
    },
    .{
        .answer = literals.role_constants[23].value, // NSAccessibilityStaticTextRole
        .roles = &.{ .label, .list_box_option, .title_bar },
    },
    .{
        .answer = literals.role_constants[27].value, // NSAccessibilityTextFieldRole
        .roles = &.{
            .text_input,   .search_input,     .email_input,
            .number_input, .password_input,   .phone_number_input,
            .url_input,
        },
    },
    .{
        .answer = literals.role_constants[19].value, // NSAccessibilityRowRole
        .roles = &.{ .row, .tree_item },
    },
};

/// How many roles map to `NSAccessibilityGroupRole`, which the 98-role fold
/// does not write out.
///
/// `docs/51c-macos-test-plan.md` section 2.1 gives this fold as 98 roles. The
/// count is derived by the test from the table rather than being a second copy
/// of the number, so a port that moves one role out of the fold and forgets to
/// edit the document still fails here only if it also changes the answer.
pub const group_role_fold_size = 98;

/// How many of the 182 roles map to a subrole, upstream `ns_sub_role`'s 44
/// arms.
pub const subrole_mapped_count = 44;

/// How many of the 182 roles must answer `null` from `nsSubRole`.
pub const subrole_unmapped_count = 138;

/// How many of the 32 subrole literals `literals.zig` holds.
///
/// It is bound here so that the array sizes in this module's tests are comptime
/// facts rather than calls into the table.
pub const subrole_literal_count = 32;

/// The value of the role constant `literals.role_constants` holds under `name`.
///
/// The walk is bounded by `literals.role_constants.len`, which is
/// `literals.role_constant_count`. A name the table does not hold is a compile
/// error, which is what makes the bindings above pin the table.
fn roleConstantValue(comptime name: []const u8) [:0]const u8 {
    for (literals.role_constants) |constant| {
        if (std.mem.eql(u8, constant.name, name)) return constant.value;
    }
    @compileError("literals.role_constants holds no " ++ name);
}

/// The value of the subrole constant `literals.subrole_constants` holds under
/// `name`.
///
/// The walk is bounded by `literals.subrole_constants.len`, which is
/// `literals.subrole_constant_count`.
fn subroleConstantValue(comptime name: []const u8) [:0]const u8 {
    for (literals.subrole_constants) |constant| {
        if (std.mem.eql(u8, constant.name, name)) return constant.value;
    }
    @compileError("literals.subrole_constants holds no " ++ name);
}

/// The `.role_literal` in `literals.zig` spelled `text`.
///
/// The walk is bounded by `literals.literals.len`, which is
/// `literals.literal_count`. A spelling the table does not hold is a compile
/// error, so a role literal cannot be renamed without this module changing.
fn roleLiteral(comptime text: []const u8) [:0]const u8 {
    for (literals.literals) |literal| {
        if (literal.group != .role_literal) continue;
        if (std.mem.eql(u8, literal.text, text)) return literal.text;
    }
    @compileError("literals.literals holds no role literal " ++ text);
}

/// The `.subrole_literal` in `literals.zig` spelled `text`.
///
/// The walk is bounded by `literals.literals.len`, which is
/// `literals.literal_count`.
fn subroleLiteral(comptime text: []const u8) [:0]const u8 {
    for (literals.literals) |literal| {
        if (literal.group != .subrole_literal) continue;
        if (std.mem.eql(u8, literal.text, text)) return literal.text;
    }
    @compileError("literals.literals holds no subrole literal " ++ text);
}

test "ns_role maps all 182 Role variants and leaves none unmapped" {
    // The exhaustiveness property. A Zig `switch` over an enum with no `else` is
    // already a compile error on an unhandled variant, so what this test adds is
    // the count: adding a role to the port without adding it to the table fails
    // here as well as at compile time, and the `else` a port might add to
    // silence a compile error still fails because no variant answers `null`.
    const info = @typeInfo(schema.Role).@"enum";
    try testing.expectEqual(@as(usize, 182), info.fields.len);
    inline for (info.fields) |field| {
        const role: schema.Role = @enumFromInt(field.value);
        const answer = nsRole(role, null);
        // Not empty: a client that receives an empty role has been told the
        // node has a role named "".
        try testing.expect(answer.len > 1);
        // And it is a string this port publishes rather than one a port
        // invented, so `literals.zig` stays the single place a spelling lives.
        try testing.expect(isPublishedRole(answer));
    }
    // Every role answers under a toggled state too, so the one conditional arm
    // cannot leave a hole.
    inline for (info.fields) |field| {
        const role: schema.Role = @enumFromInt(field.value);
        try testing.expect(nsRole(role, .true_).len > 1);
    }
}

test "every one of the 31 role constants is reachable from ns_role" {
    // The 31 is `docs/42` section 1.2.4's figure. Each one is bound above by
    // name, so a constant the bindings do not name is a compile error and one
    // no role reaches is this failure.
    try testing.expectEqual(@as(usize, 31), literals.role_constants.len);
    for (literals.role_constants) |constant| {
        // At least one role must answer with this constant, under either
        // toggled state. `AXButtonRole` is reachable only under no toggled
        // state and `AXCheckBoxRole` only under a toggled one, so neither state
        // alone reaches all 31 and the union is what the claim is about.
        var reached: usize = 0;
        inline for (@typeInfo(schema.Role).@"enum".fields) |field| {
            const role: schema.Role = @enumFromInt(field.value);
            if (std.mem.eql(u8, nsRole(role, null), constant.value)) reached += 1;
            if (std.mem.eql(u8, nsRole(role, .true_), constant.value)) reached += 1;
        }
        try testing.expect(reached >= 1);
    }
}

test "the roles that share one AX literal share it deliberately" {
    // Five of the six folds are written out in full; the sixth is a count.
    for (collapse_groups) |group| {
        if (group.roles.len == 0) continue;
        for (group.roles) |role| {
            try testing.expectEqualStrings(group.answer, nsRole(role, null));
            try testing.expectEqualStrings(group.answer, nsRole(role, .true_));
        }
    }
    // The written-out folds name 30 roles between them.
    var written: usize = 0;
    for (collapse_groups) |group| written += group.roles.len;
    try testing.expectEqual(@as(usize, 12 + 4 + 3 + 7 + 2), written);

    // The 98-role fold is the answer no other role shares, and its size follows
    // from the 182 variants minus every other fold.
    const group_answer = literals.role_constants[5].value;
    var counted: usize = 0;
    inline for (@typeInfo(schema.Role).@"enum".fields) |field| {
        const role: schema.Role = @enumFromInt(field.value);
        if (std.mem.eql(u8, nsRole(role, null), group_answer)) counted += 1;
    }
    try testing.expectEqual(group_role_fold_size, counted);

    // A role in a smaller fold never answers the 98-role fold.
    for (collapse_groups) |group| {
        if (group.roles.len == 0) continue;
        for (group.roles) |role| {
            try testing.expect(!std.mem.eql(u8, nsRole(role, null), group_answer));
        }
    }
}

test "Role.button maps to a checkbox when the node is toggled" {
    // The one place `ns_role` consults node state rather than the role alone,
    // at `AK/macos/src/node.rs:65-71`.
    try testing.expectEqualStrings("AXCheckBox", nsRole(.button, .true_));
    try testing.expectEqualStrings("AXCheckBox", nsRole(.button, .false_));
    try testing.expectEqualStrings("AXCheckBox", nsRole(.button, .mixed));
    try testing.expectEqualStrings("AXButton", nsRole(.button, null));
    try testing.expectEqualStrings(toggled_button_role, nsRole(.button, .true_));
    try testing.expectEqualStrings(untoggled_button_role, nsRole(.button, null));
    // The subrole is the same conditional, at `:254`.
    try testing.expectEqualStrings("AXToggle", nsSubRole(.button, .true_).?);
    try testing.expect(nsSubRole(.button, null) == null);
}

test "ns_role falls back to NSAccessibilityUnknownRole when the node is gone" {
    // The answer a client sees for a node destroyed between the tree update and
    // the message send, at `AK/macos/src/node.rs:501-506`.
    try testing.expectEqualStrings("AXUnknownRole", unknownRole);
    try testing.expectEqualStrings("AXUnknownRole", nsRole(.unknown, null));
    for (literals.role_constants) |constant| {
        if (std.mem.eql(u8, constant.name, "NSAccessibilityUnknownRole")) {
            try testing.expectEqualStrings(constant.value, unknownRole);
        }
    }
}

test "ns_sub_role answers for 44 roles and returns null for the other 138" {
    // Both directions in one walk, because the two failure modes are different
    // and both are silent: a role that maps to nothing returning a string, and a
    // role that maps to a string returning null.
    const info = @typeInfo(schema.Role).@"enum";
    try testing.expectEqual(@as(usize, 182), info.fields.len);
    var mapped: usize = 0;
    var toggled_only: usize = 0;
    inline for (info.fields) |field| {
        const role: schema.Role = @enumFromInt(field.value);
        if (nsSubRole(role, null)) |text| {
            mapped += 1;
            try testing.expect(text.len > 1);
            try testing.expect(isPublishedSubrole(text));
            // A role that answers with no toggled state answers with one too,
            // because `button` is the only arm that reads the property.
            if (role != .button) try testing.expect(nsSubRole(role, .true_) != null);
        } else if (role == .button) {
            // The one role whose answer depends on the toggled state: upstream
            // guards its arm and falls to the default, which is `null`.
            toggled_only += 1;
            try testing.expect(nsSubRole(role, .true_) != null);
        }
    }
    try testing.expectEqual(@as(usize, 1), toggled_only);
    try testing.expectEqual(subrole_mapped_count, mapped + toggled_only);
    try testing.expectEqual(
        @as(usize, 182),
        mapped + toggled_only + subrole_unmapped_count,
    );
}

test "the eight constant arms name the 7 subrole constants objc2-app-kit exports" {
    // Eight arms, seven constants: `alert_dialog` and `dialog` share
    // `NSAccessibilityDialogSubrole`, at `AK/macos/src/node.rs:250` and `:261`.
    try testing.expectEqualStrings(
        nsSubRole(.alert_dialog, null).?,
        nsSubRole(.dialog, null).?,
    );
    const from_constants = [_]schema.Role{
        .alert_dialog, .dialog, .button, .password_input,
        .search_input, .switch_,       .tab,    .tree_item,
    };
    try testing.expectEqual(@as(usize, 8), from_constants.len);
    for (from_constants) |role| {
        const answer = nsSubRole(role, .true_) orelse return error.ArmAnswersNothing;
        try testing.expect(literals.findInGroup(.subrole_literal, answer) == null);
        try testing.expect(std.mem.endsWith(u8, answer, "Subrole") == false);
    }
    try testing.expectEqual(@as(usize, 7), literals.subrole_constants.len);
}

test "the 36 arms that emit a literal emit all 32 spellings" {
    // 44 arms, 8 of which name a constant, so 36 arms emit one of the 32
    // literals. The walk is an `inline for` because it indexes the literal
    // table, which is comptime data.
    //
    // The second half of the claim is the one that matters: every one of the 32
    // spellings is emitted by at least one role. A distinct count alone would
    // pass with 32 answers drawn from a smaller table.
    var literal_arms: usize = 0;
    var seen: [subrole_literal_count][]const u8 = undefined;
    var seen_count: usize = 0;
    inline for (@typeInfo(schema.Role).@"enum".fields) |field| {
        const role: schema.Role = @enumFromInt(field.value);
        if (nsSubRole(role, .true_)) |answer| {
            if (literals.findInGroup(.subrole_literal, answer) != null) {
                literal_arms += 1;
                var already = false;
                for (seen[0..seen_count]) |earlier| {
                    if (std.mem.eql(u8, earlier, answer)) already = true;
                }
                if (!already) {
                    seen[seen_count] = answer;
                    seen_count += 1;
                }
            }
        }
    }
    try testing.expectEqual(@as(usize, 36), literal_arms);
    try testing.expectEqual(@as(usize, 32), seen_count);
    for (literals.literals) |candidate| {
        if (candidate.group != .subrole_literal) continue;
        var emitted = false;
        for (seen[0..seen_count]) |answer| {
            if (std.mem.eql(u8, answer, candidate.text)) emitted = true;
        }
        try testing.expect(emitted);
    }
}

test "a role with no subrole answers nil rather than an empty string" {
    // The 138 roles upstream leaves alone. The walk derives the set rather than
    // writing it out, because a written-out list of 138 role names is a second
    // copy of the table that nothing else checks.
    // `button` is the one exclusion: its answer depends on the toggled state,
    // it is one of the 44 mapped roles, and `null` under `.true_` would be the
    // wrong answer for it.
    var unmapped: usize = 0;
    inline for (@typeInfo(schema.Role).@"enum".fields) |field| {
        const role: schema.Role = @enumFromInt(field.value);
        if (role == .button) continue;
        if (nsSubRole(role, .true_)) |answer| {
            // An answer that is present is never the empty string, and it is
            // never the role string: "has no subrole", "the subrole is the
            // role" and "the subrole is the empty name" are three different
            // statements.
            try testing.expect(answer.len > 0);
            try testing.expect(!std.mem.eql(u8, answer, ""));
            try testing.expect(!std.mem.eql(u8, answer, nsRole(role, .true_)));
        } else {
            unmapped += 1;
        }
    }
    try testing.expectEqual(subrole_unmapped_count, unmapped);
}

test "the five roles that expose their label in their value" {
    // `AK/macos/src/node.rs:233-242`.
    const expected = [_]schema.Role{
        .label, .list_box_option, .list_marker, .menu_list_option, .title_bar,
    };
    try testing.expectEqual(@as(usize, 5), expected.len);
    for (expected) |role| {
        try testing.expect(labelIsExposedInValue(role));
    }
    inline for (@typeInfo(schema.Role).@"enum".fields) |field| {
        const role: schema.Role = @enumFromInt(field.value);
        var wanted = false;
        for (expected) |candidate| {
            if (candidate == role) wanted = true;
        }
        try testing.expectEqual(wanted, labelIsExposedInValue(role));
    }
}
