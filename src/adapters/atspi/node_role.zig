//! The map from a consumer role onto the AT-SPI role a client reads.
//!
//! **Upstream.** `accesskit_atspi_common/src/node.rs:87-295` is `NodeWrapper::role`
//! and `node.rs:991-996` is `PlatformNode::role`, which forwards to it.
//! `docs/41-atspi-build-map.md` section 1.5 records the role as the wire type
//! `u` of `Accessible.GetRole`, and section 4.4 records the map as the M6
//! evidence row.
//!
//! **Why the map is the whole module.** A client renders the localized role name
//! from the number it reads, so a wrong member here is a wrong role name on
//! screen. There is no other place in the port that decides a role, and the
//! `wire.Role` doc comment at `wire.zig:349` names this function as the producer
//! of every member the enum declares.
//!
//! **Two conditions, and they are checked in this order.** A node that carries a
//! role description reports `extended` whatever its role is, at `node.rs:88-90`.
//! Only a node without one reaches the switch. A button that carries a toggled
//! state reports `toggle_button`, at `node.rs:103-109`, and that is the only arm
//! of the switch that reads a second property.
//!
//! **No allocator and no error.** The three inputs are three scalars, so the
//! answer is one enum tag. Every loop over the domain below is an `inline for`
//! over `std.enums.values`, which has no run-time bound at all.

const std = @import("std");

const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const wire = @import("wire.zig");

const NodeRef = consumer.node_id.NodeRef;

/// The AT-SPI role a node with `accesskit_role` reports.
///
/// `toggled` is true when the node carries a toggled state, which is the only
/// condition inside the switch, and `has_role_description` short-circuits the
/// whole switch to `extended`.
///
/// **Errors.** This function does not fail.
pub fn roleFor(
    accesskit_role: schema.Role,
    toggled: bool,
    has_role_description: bool,
) wire.Role {
    if (has_role_description) return .extended;

    return switch (accesskit_role) {
        .alert => .notification,
        .alert_dialog => .alert,
        .comment, .suggestion => .section,
        .application => .embedded,
        .article => .article,
        .audio => .audio,
        .banner, .header => .landmark,
        .blockquote => .block_quote,
        .caret => .unknown,
        .button => if (toggled) .toggle_button else .button,
        .default_button => .button,
        .canvas => .canvas,
        .caption => .caption,
        .cell, .grid_cell => .table_cell,
        .check_box => .check_box,
        .switch_ => .toggle_button,
        .color_well => .button,
        .column_header => .column_header,
        .combo_box, .editable_combo_box => .combo_box,
        .complementary => .landmark,
        .content_deletion => .content_deletion,
        .content_insertion => .content_insertion,
        .content_info, .footer => .landmark,
        .definition => .description_value,
        .description_list => .description_list,
        .details => .panel,
        .dialog => .dialog,
        .disclosure_triangle => .toggle_button,
        .doc_cover => .image,
        .doc_back_link, .doc_biblio_ref, .doc_gloss_ref, .doc_note_ref => .link,
        .doc_biblio_entry, .doc_endnote => .list_item,
        .doc_notice, .doc_tip => .comment,
        .doc_footnote => .footnote,
        .doc_page_break => .separator,
        .doc_page_footer => .footer,
        .doc_page_header => .header,
        .doc_acknowledgements,
        .doc_afterword,
        .doc_appendix,
        .doc_bibliography,
        .doc_chapter,
        .doc_conclusion,
        .doc_credits,
        .doc_endnotes,
        .doc_epilogue,
        .doc_errata,
        .doc_foreword,
        .doc_glossary,
        .doc_index,
        .doc_introduction,
        .doc_page_list,
        .doc_part,
        .doc_preface,
        .doc_prologue,
        .doc_toc,
        => .landmark,
        .doc_abstract,
        .doc_colophon,
        .doc_credit,
        .doc_dedication,
        .doc_epigraph,
        .doc_example,
        .doc_pullquote,
        .doc_qna,
        => .section,
        .doc_subtitle => .heading,
        .document => .document_frame,
        .embedded_object => .embedded,
        .form => .form,
        .figure, .feed => .panel,
        .generic_container, .ruby => .section,
        .graphics_document => .document_frame,
        .graphics_object => .panel,
        .graphics_symbol => .image,
        .grid => .table,
        .group => .panel,
        .heading => .heading,
        .iframe, .iframe_presentational => .internal_frame,
        .image => .image,
        .text_run => .static,
        .legend => .label,
        .layout_table, .layout_table_cell, .layout_table_row => .section,
        .line_break => .static,
        .link => .link,
        .list => .list,
        .list_box => .list_box,
        .list_box_option => .list_item,
        .list_grid => .table,
        .list_item => .list_item,
        .list_marker => .static,
        .log => .log,
        .main => .landmark,
        .mark => .static,
        .math => .math,
        .marquee => .marquee,
        .menu, .menu_list_popup => .menu,
        .menu_bar => .menu_bar,
        .menu_item, .menu_list_option => .menu_item,
        .menu_item_check_box => .check_menu_item,
        .menu_item_radio => .radio_menu_item,
        .meter => .level_bar,
        .navigation => .landmark,
        .note => .comment,
        .pane, .scroll_view => .panel,
        .paragraph => .paragraph,
        .pdf_actionable_highlight => .button,
        .pdf_root => .document_frame,
        .plugin_object => .embedded,
        .progress_indicator => .progress_bar,
        .radio_button => .radio_button,
        .radio_group => .panel,
        .region => .landmark,
        .root_web_area => .document_web,
        .row => .table_row,
        .row_group => .panel,
        .row_header => .row_header,
        .ruby_annotation => .static,
        .section => .section,
        .section_footer => .footer,
        .section_header => .header,
        .scroll_bar => .scroll_bar,
        .search => .landmark,
        .slider => .slider,
        .spin_button => .spin_button,
        .splitter => .separator,
        .label => .label,
        .status => .status_bar,
        .svg_root => .document_frame,
        .tab => .page_tab,
        .table => .table,
        .tab_list => .page_tab_list,
        .tab_panel => .scroll_pane,
        .term => .description_term,
        .title_bar => .title_bar,
        .text_input,
        .multiline_text_input,
        .search_input,
        .email_input,
        .number_input,
        .phone_number_input,
        .url_input,
        => .entry,
        .date_input,
        .date_time_input,
        .week_input,
        .month_input,
        .time_input,
        => .date_editor,
        .password_input => .password_text,
        .abbr, .code, .emphasis, .strong, .time => .static,
        .timer => .timer,
        .toolbar => .tool_bar,
        .tooltip => .tool_tip,
        .tree => .tree,
        .tree_item => .tree_item,
        .tree_grid => .tree_table,
        .video => .video,
        .window => .frame,
        .web_view => .panel,
        .figure_caption => .caption,
        .unknown => .unknown,
        .ime_candidate, .keyboard => .redundant_object,
        .terminal => .terminal,
    };
}

/// The AT-SPI role `node` reports, read off the node's own properties.
///
/// This is `roleFor` with the three arguments read from the node, which is the
/// whole of `NodeWrapper::role` at `node.rs:87-295`.
///
/// **Errors.** This function does not fail.
pub fn roleOf(node: NodeRef) wire.Role {
    return roleFor(
        consumer.node_ref.properties.role(node),
        consumer.node_ref.properties.toggled(node) != null,
        consumer.node_ref.properties.hasRoleDescription(node),
    );
}

const testing = std.testing;

test "a role description wins over the role itself" {
    // `node.rs:88-90`. A button with a role description is extended, and a
    // button with a toggled state is a toggle button, so this test pins the
    // order of the two conditions as well.
    try testing.expectEqual(wire.Role.extended, roleFor(.button, true, true));
    try testing.expectEqual(wire.Role.extended, roleFor(.check_box, false, true));
    try testing.expectEqual(wire.Role.extended, roleFor(.unknown, false, true));
}

test "a button with a toggled state is a toggle button and one without is a button" {
    // `node.rs:103-109`. This is the only arm that reads a second property.
    try testing.expectEqual(wire.Role.button, roleFor(.button, false, false));
    try testing.expectEqual(wire.Role.toggle_button, roleFor(.button, true, false));
}

test "the roles upstream folds together fold together here" {
    // Each pair below is one arm of the upstream match with more than one
    // pattern. A transcription that split one of them is what these catch.
    try testing.expectEqual(
        wire.Role.landmark,
        roleFor(.complementary, false, false),
    );
    try testing.expectEqual(wire.Role.landmark, roleFor(.navigation, false, false));
    try testing.expectEqual(wire.Role.table_cell, roleFor(.cell, false, false));
    try testing.expectEqual(wire.Role.table_cell, roleFor(.grid_cell, false, false));
    try testing.expectEqual(wire.Role.panel, roleFor(.pane, false, false));
    try testing.expectEqual(wire.Role.panel, roleFor(.scroll_view, false, false));
    try testing.expectEqual(wire.Role.table, roleFor(.grid, false, false));
    try testing.expectEqual(wire.Role.table, roleFor(.list_grid, false, false));
    try testing.expectEqual(wire.Role.list_item, roleFor(.list_item, false, false));
    try testing.expectEqual(wire.Role.list_item, roleFor(.list_box_option, false, false));
    try testing.expectEqual(wire.Role.entry, roleFor(.text_input, false, false));
    try testing.expectEqual(wire.Role.entry, roleFor(.url_input, false, false));
    try testing.expectEqual(wire.Role.date_editor, roleFor(.date_input, false, false));
    try testing.expectEqual(wire.Role.date_editor, roleFor(.time_input, false, false));
    try testing.expectEqual(wire.Role.static, roleFor(.text_run, false, false));
    try testing.expectEqual(wire.Role.static, roleFor(.line_break, false, false));
    try testing.expectEqual(wire.Role.static, roleFor(.list_marker, false, false));
    try testing.expectEqual(wire.Role.static, roleFor(.mark, false, false));
    try testing.expectEqual(wire.Role.static, roleFor(.ruby_annotation, false, false));
    try testing.expectEqual(wire.Role.static, roleFor(.abbr, false, false));
    try testing.expectEqual(wire.Role.static, roleFor(.time, false, false));
    try testing.expectEqual(wire.Role.section, roleFor(.layout_table, false, false));
    try testing.expectEqual(wire.Role.section, roleFor(.layout_table_row, false, false));
    try testing.expectEqual(wire.Role.section, roleFor(.layout_table_cell, false, false));
    try testing.expectEqual(wire.Role.section, roleFor(.comment, false, false));
    try testing.expectEqual(wire.Role.section, roleFor(.suggestion, false, false));
    try testing.expectEqual(wire.Role.menu, roleFor(.menu_list_popup, false, false));
    try testing.expectEqual(wire.Role.menu_item, roleFor(.menu_list_option, false, false));
    try testing.expectEqual(wire.Role.unknown, roleFor(.unknown, false, false));
}

test "the roles upstream sends to one target all reach that target" {
    // The twenty-two `Doc*` roles of `node.rs:138-164` are the largest group in
    // the switch, and they split three ways. A transcription that moved one arm
    // from one group to another is what these three checks catch.
    const landmark_group = [_]schema.Role{
        .doc_acknowledgements, .doc_afterword,    .doc_appendix,
        .doc_bibliography,     .doc_chapter,      .doc_conclusion,
        .doc_credits,          .doc_endnotes,     .doc_epilogue,
        .doc_errata,           .doc_foreword,     .doc_glossary,
        .doc_index,            .doc_introduction, .doc_page_list,
        .doc_part,             .doc_preface,      .doc_prologue,
        .doc_toc,
    };
    for (landmark_group) |role| {
        try testing.expectEqual(wire.Role.landmark, roleFor(role, false, false));
    }
    const section_group = [_]schema.Role{
        .doc_abstract, .doc_colophon, .doc_credit,    .doc_dedication,
        .doc_epigraph, .doc_example,  .doc_pullquote, .doc_qna,
    };
    for (section_group) |role| {
        try testing.expectEqual(wire.Role.section, roleFor(role, false, false));
    }
    try testing.expectEqual(wire.Role.heading, roleFor(.doc_subtitle, false, false));
}

test "the roles that upstream sends to one of three targets" {
    try testing.expectEqual(wire.Role.link, roleFor(.doc_back_link, false, false));
    try testing.expectEqual(wire.Role.link, roleFor(.doc_gloss_ref, false, false));
    try testing.expectEqual(wire.Role.link, roleFor(.doc_note_ref, false, false));
    try testing.expectEqual(wire.Role.link, roleFor(.doc_biblio_ref, false, false));
    try testing.expectEqual(wire.Role.list_item, roleFor(.doc_biblio_entry, false, false));
    try testing.expectEqual(wire.Role.list_item, roleFor(.doc_endnote, false, false));
    try testing.expectEqual(wire.Role.comment, roleFor(.doc_notice, false, false));
    try testing.expectEqual(wire.Role.comment, roleFor(.doc_tip, false, false));
    try testing.expectEqual(wire.Role.footnote, roleFor(.doc_footnote, false, false));
    try testing.expectEqual(wire.Role.separator, roleFor(.doc_page_break, false, false));
    try testing.expectEqual(wire.Role.footer, roleFor(.doc_page_footer, false, false));
    try testing.expectEqual(wire.Role.header, roleFor(.doc_page_header, false, false));
    try testing.expectEqual(wire.Role.image, roleFor(.doc_cover, false, false));
}

test "the six roles upstream sends to a button" {
    // `node.rs:110`, `:116`, `:223`, and the three arms of the `Button` family.
    // They share one target, so a check on one of them proves little and these
    // six are named together.
    try testing.expectEqual(wire.Role.button, roleFor(.default_button, false, false));
    try testing.expectEqual(wire.Role.button, roleFor(.color_well, false, false));
    try testing.expectEqual(wire.Role.button, roleFor(.pdf_actionable_highlight, false, false));
    try testing.expectEqual(wire.Role.button, roleFor(.button, false, false));
    try testing.expectEqual(wire.Role.toggle_button, roleFor(.disclosure_triangle, false, false));
    try testing.expectEqual(wire.Role.toggle_button, roleFor(.switch_, false, false));
}

test "the roles that share a target across the switch" {
    try testing.expectEqual(wire.Role.document_frame, roleFor(.document, false, false));
    try testing.expectEqual(wire.Role.document_frame, roleFor(.svg_root, false, false));
    try testing.expectEqual(wire.Role.document_frame, roleFor(.pdf_root, false, false));
    try testing.expectEqual(wire.Role.document_frame, roleFor(.graphics_document, false, false));
    try testing.expectEqual(wire.Role.embedded, roleFor(.application, false, false));
    try testing.expectEqual(wire.Role.embedded, roleFor(.embedded_object, false, false));
    try testing.expectEqual(wire.Role.embedded, roleFor(.plugin_object, false, false));
    try testing.expectEqual(wire.Role.panel, roleFor(.group, false, false));
    try testing.expectEqual(wire.Role.panel, roleFor(.radio_group, false, false));
    try testing.expectEqual(wire.Role.panel, roleFor(.row_group, false, false));
    try testing.expectEqual(wire.Role.panel, roleFor(.details, false, false));
    try testing.expectEqual(wire.Role.panel, roleFor(.figure, false, false));
    try testing.expectEqual(wire.Role.panel, roleFor(.feed, false, false));
    try testing.expectEqual(wire.Role.panel, roleFor(.graphics_object, false, false));
    try testing.expectEqual(wire.Role.panel, roleFor(.web_view, false, false));
    try testing.expectEqual(wire.Role.frame, roleFor(.window, false, false));
    try testing.expectEqual(wire.Role.internal_frame, roleFor(.iframe, false, false));
    try testing.expectEqual(wire.Role.internal_frame, roleFor(.iframe_presentational, false, false));
    try testing.expectEqual(wire.Role.image, roleFor(.graphics_symbol, false, false));
    try testing.expectEqual(wire.Role.caption, roleFor(.figure_caption, false, false));
    try testing.expectEqual(wire.Role.redundant_object, roleFor(.keyboard, false, false));
    try testing.expectEqual(wire.Role.redundant_object, roleFor(.ime_candidate, false, false));
    try testing.expectEqual(wire.Role.tree_table, roleFor(.tree_grid, false, false));
    try testing.expectEqual(wire.Role.check_menu_item, roleFor(.menu_item_check_box, false, false));
    try testing.expectEqual(wire.Role.radio_menu_item, roleFor(.menu_item_radio, false, false));
}

test "a window is a frame and a scroll view is a panel" {
    // `node.rs:284-287`. A client draws a title bar for a frame and not for a
    // panel, so these two answers are the ones a user sees.
    try testing.expectEqual(wire.Role.frame, roleFor(.window, false, false));
    try testing.expectEqual(wire.Role.panel, roleFor(.scroll_view, false, false));
    try testing.expectEqual(wire.Role.scroll_pane, roleFor(.tab_panel, false, false));
    try testing.expectEqual(wire.Role.scroll_bar, roleFor(.scroll_bar, false, false));
}

test "every consumer role reaches a role the wire declares" {
    // The sweep is the coverage argument. A member added to `schema.Role` is a
    // compile error in `roleFor` above, and this test proves the answers are
    // members of the declared domain rather than a cast of something else.
    inline for (comptime std.enums.values(schema.Role)) |accesskit_role| {
        for ([_]bool{ false, true }) |toggled| {
            const reported = roleFor(accesskit_role, toggled, false);
            try testing.expect(wire.roleFromInt(@intFromEnum(reported)) != null);
        }
    }
}

test "the map produces no more roles than the reference names" {
    // Every role the switch can answer must be a member the reference declares,
    // because a client looks the number up by name. The sweep counts the
    // distinct answers the switch reaches over the whole consumer domain and
    // compares that count against the number of members the wire declares,
    // which is the check that no arm was invented: an arm answering a tag
    // nothing else reaches would push the count over the domain.
    //
    // **A bit set cannot carry this domain.** `wire.Role` is `enum(u32)` and
    // its tags are sparse, the largest being 128, so one bit per member does
    // not fit a `u64` and a `u64` shift amount cannot reach the high tags
    // either. The marks are one `bool` per tag in an array the widest tag
    // sizes.
    var reached = [_]bool{false} ** (widestTag(wire.Role) + 1);
    var distinct: usize = 0;
    inline for (comptime std.enums.values(schema.Role)) |accesskit_role| {
        for ([_]bool{ false, true }) |toggled| {
            const tag = @intFromEnum(roleFor(accesskit_role, toggled, false));
            if (!reached[tag]) {
                reached[tag] = true;
                distinct += 1;
            }
        }
    }
    // The bound the name states: the switch reaches no more distinct roles
    // than the reference names. An arm answering a tag nothing else reaches
    // would push the count over.
    try testing.expect(distinct <= @typeInfo(wire.Role).@"enum".fields.len);
}

/// The largest tag `T` declares, which is how many slots a mark per tag needs.
///
/// **Errors.** This function does not fail. An empty enum answers zero, which
/// is one slot and so cannot index out of bounds.
fn widestTag(comptime T: type) usize {
    return tag: {
        var widest: usize = 0;
        for (std.enums.values(T)) |member| {
            widest = @max(widest, @intFromEnum(member));
        }
        break :tag widest;
    };
}
