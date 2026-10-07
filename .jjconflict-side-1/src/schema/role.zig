//! The type of an accessibility node.
//!
//! One enum and no other declaration. It carries no name table, no ARIA
//! mapping and no serialiser: a node holds the tag as one byte, and the sweep
//! over the whole property domain belongs to `schema/props/table.zig`.
//!
//! ```zig
//! const schema = @import("zaccesskit").schema;
//!
//! var role: schema.Role = .unknown;
//! role = .link;
//! ```
//!
//! Nothing here allocates, blocks or owns a resource, so there is nothing for
//! a caller to release.

const std = @import("std");

/// The type of an accessibility node.
///
/// Most of these roles come from the ARIA specification, and the list is
/// largely taken from Chromium. Unlike Chromium's alphabetized list, it is
/// ordered roughly by expected usage frequency, `Role.unknown` excepted,
/// because a serialization format whose integers use a variable-length
/// encoding spends fewer bytes on the roles that occur often.
///
/// **The declaration order is the wire format.** A serialized role is
/// `@intFromEnum` of the tag, so inserting, removing or moving a tag renumbers
/// every tag after it. Every discriminant is therefore written out, which
/// turns a reordering that kept the old numbers into a duplicate-value compile
/// error instead of a silent change to every serialized tree. Upstream states
/// the ordering rule at `lib.rs:37` through `lib.rs:46`;
/// `docs/15-tree-semantics.md` section 1.1 records every discriminant with the
/// specification that defines the role.
pub const Role = enum(u8) {
    /// The type is not known. This is the default tag, and the one a node
    /// carries when a platform reported no better answer.
    unknown = 0,

    /// A run of text with per-character positions and widths. Only
    /// `Role.text_run` carries the per-character geometry properties.
    text_run = 1,

    cell = 2,
    /// A short text that names or describes another object. Its own text is
    /// carried by its `value` property, not by its `label` property.
    label = 3,
    image = 4,
    link = 5,
    row = 6,
    list_item = 7,

    /// The bullet, number or other marker of a list item. It has no children of
    /// its own.
    list_marker = 8,

    tree_item = 9,
    list_box_option = 10,
    menu_item = 11,
    /// An option inside a native `select` element that acts as a menu.
    /// Chromium-only; ARIA has no role for it.
    menu_list_option = 12,
    paragraph = 13,

    /// A generic container that assistive technologies should ignore and filter
    /// out of a platform accessibility tree. The equivalent of the ARIA `none`
    /// or `presentation` role, or of an HTML `div` with no role.
    generic_container = 14,

    check_box = 15,
    radio_button = 16,
    text_input = 17,
    button = 18,
    /// Shares the ARIA role `button`. Chromium distinguishes a default button,
    /// and ARIA has no state that carries the distinction.
    default_button = 19,
    /// A nameless container that has no semantic meaning of its own. The web
    /// equivalent is the ARIA role `generic`.
    pane = 20,
    row_header = 21,
    column_header = 22,
    row_group = 23,
    list = 24,
    table = 25,

    // Layout-only table parts. Each exists only for layout, and assistive
    // technology should ignore it. ARIA defines no role for any of them.
    layout_table_cell = 26,
    layout_table_row = 27,
    layout_table = 28,

    /// The ARIA role spelled `switch`, carrying a trailing underscore because
    /// `switch` is a Zig keyword. The ARIA spelling is the name a caller looks
    /// the role up by, so no other name is better, and the underscore matches
    /// the other forced spellings in the port such as `f64_` and `bool_`.
    switch_ = 29,
    menu = 30,

    // Chromium's remaining text-entry roles. ARIA has `textbox` and `searchbox`
    // and nothing for a date, a week or a password field, so each of these is a
    // tag of its own.
    multiline_text_input = 31,
    search_input = 32,
    date_input = 33,
    date_time_input = 34,
    week_input = 35,
    month_input = 36,
    time_input = 37,
    email_input = 38,
    number_input = 39,
    password_input = 40,
    phone_number_input = 41,
    url_input = 42,

    /// An abbreviation, that is, an abbreviated form of a word or phrase.
    abbr = 43,
    alert = 44,
    alert_dialog = 45,
    application = 46,
    article = 47,
    audio = 48,
    banner = 49,
    blockquote = 50,
    canvas = 51,
    caption = 52,
    /// The insertion point inside an editable text control.
    caret = 53,
    /// A fragment of computer code. Zig also has a builtin named `code`, and a
    /// builtin is not a keyword, so the field takes its bare spelling.
    code = 54,
    /// A control that opens a colour picker.
    color_well = 55,
    combo_box = 56,
    editable_combo_box = 57,
    complementary = 58,
    /// Content expressing reaction to other content.
    comment = 59,
    content_deletion = 60,
    content_insertion = 61,
    content_info = 62,
    definition = 63,
    /// A list of terms and their definitions. Chromium-only; ARIA defines no
    /// role for it.
    description_list = 64,
    /// A disclosure widget. ARIA has no dedicated role; the AAM equivalent is
    /// `group`.
    details = 65,
    dialog = 66,
    /// The triangle that shows and hides content. Chromium-only.
    disclosure_triangle = 67,
    document = 68,
    /// An embedded foreign document, a PDF in practice.
    embedded_object = 69,
    emphasis = 70,
    feed = 71,
    figure_caption = 72,
    figure = 73,
    footer = 74,
    form = 75,
    grid = 76,
    grid_cell = 77,
    group = 78,
    header = 79,
    heading = 80,
    /// An inline frame. Zig has a builtin named `iframe`, and a builtin is not a
    /// keyword, so the field takes its bare spelling.
    iframe = 81,
    /// An inline frame whose content must be hidden from assistive technology.
    iframe_presentational = 82,
    /// A candidate word from an input method editor.
    ime_candidate = 83,
    /// A keyboard or a key row. Chromium-only.
    keyboard = 84,
    /// The caption of a fieldset or of a figure. Chromium-only.
    legend = 85,
    /// A hard line break inside text. Chromium-only.
    line_break = 86,
    list_box = 87,
    log = 88,
    main = 89,
    /// Content highlighted for reference, because of its relevance to the
    /// enclosing context.
    mark = 90,
    marquee = 91,
    math = 92,
    menu_bar = 93,
    menu_item_check_box = 94,
    menu_item_radio = 95,
    /// The popup list of a native `select` element. Chromium-only.
    menu_list_popup = 96,
    meter = 97,
    navigation = 98,
    /// A section whose content is parenthetic or ancillary to the main content.
    note = 99,
    /// A plugin object. Chromium-only.
    plugin_object = 100,
    /// Progress for a task that takes a long time. The web equivalent is the
    /// ARIA role `progressbar`.
    progress_indicator = 101,
    radio_group = 102,
    region = 103,
    /// The root of a web document. What Chromium calls this, ARIA calls
    /// `document`.
    root_web_area = 104,
    /// The base text that a ruby annotation annotates. Chromium-only.
    ruby = 105,
    /// The text inside a ruby annotation. Chromium-only.
    ruby_annotation = 106,
    scroll_bar = 107,
    /// A scrollable container. Chromium-only; ARIA defines no role for it.
    scroll_view = 108,
    search = 109,
    /// Content relevant to an author-specified purpose and important enough to
    /// be navigable. What Chromium calls this, ARIA calls `region`.
    section = 110,
    section_footer = 111,
    section_header = 112,
    slider = 113,
    spin_button = 114,
    /// A divider that separates sections of content or groups of menu items.
    splitter = 115,
    /// A live region carrying advisory information, not important enough to
    /// raise an alert.
    status = 116,
    strong = 117,
    /// A single proposed change to content.
    suggestion = 118,
    /// The root element of an SVG document. Chromium-only.
    svg_root = 119,
    tab = 120,
    tab_list = 121,
    tab_panel = 122,
    term = 123,
    time = 124,
    /// A live region counting elapsed time towards a start or a deadline, and
    /// not a point in time as `Role.time` is.
    timer = 125,
    /// The title bar of a window. Chromium-only.
    title_bar = 126,
    toolbar = 127,
    tooltip = 128,
    tree = 129,
    tree_grid = 130,
    video = 131,
    /// A WebKit web view. Chromium-only.
    web_view = 132,
    /// A window. ARIA 1.2 lists `window` as an abstract role that an author
    /// must not use, and ARIA 1.3 removes it, so a port maps it to
    /// `Role.application` or `Role.group` (`docs/15-tree-semantics.md` section
    /// 1.2).
    window = 133,

    // Chromium's PDF roles. `pdf_root` is what ARIA calls `document`.
    /// A clickable highlight rectangle inside a PDF. Chromium-only.
    pdf_actionable_highlight = 134,
    pdf_root = 135,

    // WAI-ARIA Graphics Module 1.0. Upstream cites the rawgit URL at
    // `lib.rs:212`, and rawgit no longer exists; the live document is
    // https://www.w3.org/TR/graphics-aam-1.0/#mapping_role_table.
    graphics_document = 136,
    graphics_object = 137,
    graphics_symbol = 138,

    // DPUB-ARIA 1.0, at https://www.w3.org/TR/dpub-aam-1.0/#mapping_role_table.
    doc_abstract = 139,
    doc_acknowledgements = 140,
    doc_afterword = 141,
    doc_appendix = 142,
    doc_back_link = 143,
    doc_biblio_entry = 144,
    doc_bibliography = 145,
    doc_biblio_ref = 146,
    doc_chapter = 147,
    doc_colophon = 148,
    doc_conclusion = 149,
    doc_cover = 150,
    doc_credit = 151,
    doc_credits = 152,
    doc_dedication = 153,
    doc_endnote = 154,
    doc_endnotes = 155,
    doc_epigraph = 156,
    doc_epilogue = 157,
    doc_errata = 158,
    doc_example = 159,
    doc_footnote = 160,
    doc_foreword = 161,
    doc_glossary = 162,
    doc_gloss_ref = 163,
    doc_index = 164,
    doc_introduction = 165,
    doc_note_ref = 166,
    doc_notice = 167,
    doc_page_break = 168,

    // Chromium's PDF running-footer and running-header roles. DPUB-ARIA 1.0
    // defines 39 roles and the DPUB-AAM role mapping carries neither of these,
    // so neither has an authoritative meaning
    // (`docs/15-tree-semantics.md` section 1.2). Both are here because
    // dropping a tag renumbers every tag after it, not because a specification
    // defines them.
    /// A running footer inside a PDF. Carried for wire-order compatibility; no
    /// specification defines the role.
    doc_page_footer = 169,
    /// A running header inside a PDF. Carried for wire-order compatibility; no
    /// specification defines the role.
    doc_page_header = 170,

    doc_page_list = 171,
    doc_part = 172,
    doc_preface = 173,
    doc_prologue = 174,
    doc_pullquote = 175,
    doc_qna = 176,
    doc_subtitle = 177,
    doc_tip = 178,
    doc_toc = 179,

    /// Behaves like an ARIA grid, but exists so that Chromium's `TableView` and
    /// its subclasses can be exposed correctly on certain platforms.
    list_grid = 180,

    /// A multi-line document that asks assistive technologies for the behaviour
    /// of a VT-100-style terminal.
    terminal = 181,
};

comptime {
    const info = @typeInfo(Role).@"enum";

    // These pin the wire format: the tag count, that the type stays
    // exhaustive, and which tag sits at each end. The sweep that proves every
    // tag is reachable belongs to `schema/props/table.zig`, which owns the
    // property domain.
    std.debug.assert(info.fields.len == 182);
    std.debug.assert(info.is_exhaustive);
    std.debug.assert(std.mem.eql(u8, info.fields[0].name, "unknown"));
    std.debug.assert(std.mem.eql(u8, info.fields[info.fields.len - 1].name, "terminal"));

    // Every discriminant sits at its declaration index, so a tag inserted in
    // the middle without renumbering the tags after it is a compile error that
    // names the tag, rather than a silent change to every serialized tree.
    for (info.fields, 0..) |field, index| {
        std.debug.assert(field.value == index);
    }
}

test "Role carries the 182 tags upstream declares" {
    comptime {
        std.debug.assert(@typeInfo(Role).@"enum".fields.len == 182);
        std.debug.assert(@sizeOf(Role) == 1);
        std.debug.assert(@alignOf(Role) == 1);
    }
}

test "the discriminants upstream pins" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Role.unknown));
    // `GenericContainer` is `lib.rs:85`, the fifteenth tag. An anchor inside
    // the range catches the reordering that the two endpoints cannot.
    try std.testing.expectEqual(@as(u8, 14), @intFromEnum(Role.generic_container));
    try std.testing.expectEqual(@as(u8, 181), @intFromEnum(Role.terminal));
}
