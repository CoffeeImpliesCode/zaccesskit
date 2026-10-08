//! The AT-SPI wire enumerations, the two bit-set domains, and the interface
//! names the port exports.
//!
//! **Upstream.** `accesskit_atspi_common/src/lib.rs:21-24` re-exports
//! `CoordType`, `Granularity`, `InterfaceSet`, `Layer`, `RelationType`, `Role`,
//! `ScrollType`, `State` and `StateSet` from the `atspi-common` crate.
//! `docs/41-atspi-build-map.md` section 1.4 records `au` for `Accessible.GetState`
//! and section 1.5 records `u` for every other enumerated member.
//!
//! **How many enums this file declares, and why it is nine and not ten.**
//! `docs/41` section 2.2 says "the ten wire enums". Nine are declared here. The
//! tenth would be `Live`, which upstream reads from `accesskit::Live` at
//! `atspi-common/src/node.rs:517` and immediately narrows to
//! `atspi_common::Politeness` at `node.rs:518-522`. The consumer layer already
//! carries `schema.node_enums.Live`, so declaring a second one here would be the
//! alias `AGENTS.md` section 2 forbids. `Politeness` is the value that reaches
//! the wire, as `docs/41` section 1.7 records for `Announcement`'s `detail1`.
//!
//! **Numeric authority.** The canonical domains follow `atspi-common` 0.13.0:
//! https://docs.rs/atspi-common/0.13.0/src/atspi_common/role.rs.html#337-467
//! https://docs.rs/atspi-common/0.13.0/src/atspi_common/state.rs.html#18-276
//! https://docs.rs/atspi-common/0.13.0/src/atspi_common/relation_type.rs.html#6-121
//! https://docs.rs/atspi-common/0.13.0/src/atspi_common/lib.rs.html#71-201
//! Tests use literal protocol numbers, masks, and published state-array bytes.
//! Source agreement does not establish native-client interoperability.
//!
//! **Sets.** `InterfaceSet` and `StateSet` are bit sets, which is what
//! `atspi-common`'s `InterfaceSet` and `StateSet` are: upstream inserts and
//! contains with a bit per member, and `node.rs:609` takes their symmetric
//! difference. `au` and `as` are the marshalled forms, a packed `u32` array.

const std = @import("std");

/// The interface name of `org.a11y.atspi.Accessible`, which every node object
/// and the root object export. `docs/41` section 1.4.
pub const interface_accessible: [:0]const u8 = "org.a11y.atspi.Accessible";

/// The interface name of `org.a11y.atspi.Application`, exported on the root path
/// only. `docs/41` section 1.3.
pub const interface_application: [:0]const u8 = "org.a11y.atspi.Application";

/// The interface name of `org.a11y.atspi.Action`. `docs/41` section 1.5.
pub const interface_action: [:0]const u8 = "org.a11y.atspi.Action";

/// The interface name of `org.a11y.atspi.Component`. `docs/41` section 1.5.
pub const interface_component: [:0]const u8 = "org.a11y.atspi.Component";

/// The interface name of `org.a11y.atspi.Document`. `docs/41` section 1.5.
pub const interface_document: [:0]const u8 = "org.a11y.atspi.Document";

/// The interface name of `org.a11y.atspi.EditableText`. `docs/41` section 1.5.
pub const interface_editable_text: [:0]const u8 = "org.a11y.atspi.EditableText";

/// The interface name of `org.a11y.atspi.Hyperlink`. `docs/41` section 1.5.
pub const interface_hyperlink: [:0]const u8 = "org.a11y.atspi.Hyperlink";

/// The interface name of `org.a11y.atspi.Image`. `docs/41` section 1.5.
pub const interface_image: [:0]const u8 = "org.a11y.atspi.Image";

/// The interface name of `org.a11y.atspi.Selection`. `docs/41` section 1.5.
pub const interface_selection: [:0]const u8 = "org.a11y.atspi.Selection";

/// The interface name of `org.a11y.atspi.Text`. `docs/41` section 1.5.
pub const interface_text: [:0]const u8 = "org.a11y.atspi.Text";

/// The interface name of `org.a11y.atspi.Value`. `docs/41` section 1.5.
pub const interface_value: [:0]const u8 = "org.a11y.atspi.Value";

/// The interface name of `org.a11y.atspi.Cache`, exported on the cache path.
/// `docs/41` section 1.6.
pub const interface_cache: [:0]const u8 = "org.a11y.atspi.Cache";

/// The interface name of `org.a11y.Bus`, the peer the adapter calls `GetAddress`
/// on. `docs/41` section 1.2.
pub const interface_bus: [:0]const u8 = "org.a11y.Bus";

/// The interface name of `org.a11y.Status`, the peer whose `IsEnabled` property
/// change the adapter subscribes to on the session bus. `docs/41` section 1.8.
pub const interface_status: [:0]const u8 = "org.a11y.Status";

/// The path the accessibility bus answers `GetAddress` on. `docs/41` section
/// 1.1, from `bus.rs:45`.
pub const bus_path: [:0]const u8 = "/org/a11y/bus";

/// The nine AT-SPI interfaces a node object may export, plus the two the root
/// and the cache export.
///
/// `atspi-common` models this as a bit per interface, which is what
/// `node.rs:484-514` inserts into and what the cache item's `ifaces` field
/// carries, so the enum is the bit position.
pub const Interface = enum(u5) {
    /// `org.a11y.atspi.Accessible`. Upstream `Interface::Accessible`.
    accessible = 0,
    /// `org.a11y.atspi.Action`. Upstream `Interface::Action`.
    action = 1,
    /// `org.a11y.atspi.Application`. Upstream `Interface::Application`.
    application = 2,
    /// `org.a11y.atspi.Cache`. Upstream `Interface::Cache`.
    cache = 3,
    /// `org.a11y.atspi.Component`. Upstream `Interface::Component`.
    component = 4,
    /// `org.a11y.atspi.Document`. Upstream `Interface::Document`.
    document = 5,
    /// `org.a11y.atspi.EditableText`. Upstream `Interface::EditableText`.
    editable_text = 6,
    /// `org.a11y.atspi.Hyperlink`. Upstream `Interface::Hyperlink`.
    hyperlink = 7,
    /// `org.a11y.atspi.Image`. Upstream `Interface::Image`.
    image = 8,
    /// `org.a11y.atspi.Selection`. Upstream `Interface::Selection`.
    selection = 9,
    /// `org.a11y.atspi.Text`. Upstream `Interface::Text`.
    text = 10,
    /// `org.a11y.atspi.Value`. Upstream `Interface::Value`.
    value = 11,
};

/// The number of members of `Interface`, and so the width of `InterfaceSet`.
/// Every walk over the domain is bounded by it.
pub const interface_count = @typeInfo(Interface).@"enum".fields.len;

/// The D-Bus interface string `Interface` names.
///
/// This is the one function in the adapter that maps an enum tag to a protocol
/// string, because `docs/41` section 2.1 rule 3 allows only one module to know
/// the interface list and this is the module that declares it.
///
/// **Errors.** This function does not fail.
pub fn interfaceName(value: Interface) [:0]const u8 {
    return switch (value) {
        .accessible => interface_accessible,
        .action => interface_action,
        .application => interface_application,
        .cache => interface_cache,
        .component => interface_component,
        .document => interface_document,
        .editable_text => interface_editable_text,
        .hyperlink => interface_hyperlink,
        .image => interface_image,
        .selection => interface_selection,
        .text => interface_text,
        .value => interface_value,
    };
}

/// The set of interfaces one object exports, packed one bit per `Interface`.
///
/// Upstream `atspi_common::InterfaceSet`. `node.rs:485` inserts `Accessible`
/// unconditionally and `node.rs:487-512` adds the rest, and `node.rs:1843` builds
/// the root's set as `Accessible | Application`.
pub const InterfaceSet = struct {
    /// The packed bits. A set is a `u32` because the domain is twelve wide and a
    /// wider type would carry bits no member can set.
    bits: u32 = 0,

    /// The empty set. Upstream `InterfaceSet::empty`.
    pub const empty: InterfaceSet = .{ .bits = 0 };

    /// The tag of `Interface`, which is its bit position in `bits`.
    fn mask(value: Interface) u32 {
        return @as(u32, 1) << @as(u5, @intFromEnum(value));
    }

    /// True when `set` carries `value`. Upstream `InterfaceSet::contains`.
    pub fn contains(set: InterfaceSet, value: Interface) bool {
        return set.bits & mask(value) != 0;
    }

    /// Adds `value` to `set`. Upstream `InterfaceSet::insert`.
    pub fn insert(set: *InterfaceSet, value: Interface) void {
        set.bits |= mask(value);
    }

    /// The members of `set`, in tag order, into `out`.
    ///
    /// The slice is at most `interface_count` long, because the domain is
    /// `interface_count` wide, and every entry of it is a comptime constant.
    /// **Errors.** This function does not fail.
    pub fn members(set: InterfaceSet, out: *[interface_count]Interface) []const Interface {
        var len: usize = 0;
        inline for (comptime std.enums.values(Interface)) |value| {
            if (set.contains(value)) {
                out[len] = value;
                len += 1;
            }
        }
        return out[0..len];
    }

    /// The members `left` and `right` disagree on, into `out`.
    ///
    /// Upstream `atspi-common/src/adapter.rs:308-314` computes this as a
    /// symmetric difference and sends only the delta on an update, so the list
    /// is bounded by `interface_count` and no more.
    ///
    /// **Errors.** This function does not fail.
    pub fn difference(
        left: InterfaceSet,
        right: InterfaceSet,
        out: *[interface_count]Interface,
    ) []const Interface {
        var len: usize = 0;
        inline for (comptime std.enums.values(Interface)) |value| {
            if (left.contains(value) != right.contains(value)) {
                out[len] = value;
                len += 1;
            }
        }
        return out[0..len];
    }
};

comptime {
    // The mask shift is a `u5` because the widest bit this module sets is bit
    // eleven, and a domain wider than thirty-two would not fit the `u32` above.
    if (interface_count > 32) @compileError("InterfaceSet is one u32 wide");
}

/// The three AT-SPI coordinate spaces a geometry member may be asked about.
///
/// Upstream `atspi_common::CoordType`. The wire type is `u`, per
/// `docs/41` section 1.5 for `Component.Contains`, `GetAccessibleAtPoint`,
/// `GetExtents`, `ScrollTo`, `ScrollToPoint`, `Image.GetImageExtents`,
/// `Image.GetImagePosition`, `Text.GetCharacterExtents`, `GetOffsetAtPoint`,
/// `GetRangeExtents`, `ScrollSubstringTo` and `ScrollSubstringToPoint`.
///
/// Source: `atspi-common` 0.13.0 `lib.rs:71-81`.
pub const CoordType = enum(u32) {
    /// Screen coordinates, the origin at the display's top left.
    screen = 0,
    /// Window coordinates, the origin at the window's top left.
    window = 1,
    /// Parent coordinates, the origin at the parent's top left.
    parent = 2,
};

/// The five text granularities `Text.GetStringAtOffset` accepts.
///
/// Upstream `atspi_common::Granularity`. The wire type is `u`. `sentence` is
/// declared because a peer may send it, and `text_range_from_offset` answers
/// `error.UnsupportedTextGranularity` for it, which
/// `atspi-common/src/util.rs:82-83` and `:89-90` is the upstream raise site.
///
/// Source: `atspi-common` 0.13.0 `lib.rs:97-111`.
pub const Granularity = enum(u32) {
    /// One character. Upstream `Granularity::Char`.
    char = 0,
    /// One word. Upstream `Granularity::Word`.
    word = 1,
    /// One sentence, which the consumer text layer does not define.
    sentence = 2,
    /// One line. Upstream `Granularity::Line`.
    line = 3,
    /// One paragraph. Upstream `Granularity::Paragraph`.
    paragraph = 4,
};

/// The seven scroll edges `Component.ScrollTo` and
/// `Text.ScrollSubstringTo` accept.
///
/// Upstream `atspi_common::ScrollType`. The wire type is `u`.
///
/// Source: `atspi-common` 0.13.0 `lib.rs:152-169`.
pub const ScrollType = enum(u32) {
    /// The top left corner. Upstream `ScrollType::TopLeft`.
    top_left = 0,
    /// The bottom right corner. Upstream `ScrollType::BottomRight`.
    bottom_right = 1,
    /// The top edge. Upstream `ScrollType::TopEdge`.
    top_edge = 2,
    /// The bottom edge. Upstream `ScrollType::BottomEdge`.
    bottom_edge = 3,
    /// The left edge. Upstream `ScrollType::LeftEdge`.
    left_edge = 4,
    /// The right edge. Upstream `ScrollType::RightEdge`.
    right_edge = 5,
    /// No particular edge. Upstream `ScrollType::Anywhere`.
    anywhere = 6,
};

/// The complete drawing-layer domain for `Component.GetLayer`, encoded as `u`.
/// Source: `atspi-common` 0.13.0 `lib.rs:128-150`.
pub const Layer = enum(u32) {
    invalid = 0,
    background = 1,
    canvas = 2,
    widget = 3,
    mdi = 4,
    popup = 5,
    overlay = 6,
    window = 7,
};

/// The complete relation domain for `Accessible.GetRelationSet`, encoded as `u`.
/// Source: `atspi-common` 0.13.0 `relation_type.rs:6-121`.
pub const RelationType = enum(u32) {
    /// No meaningful relationship.
    @"null" = 0,
    label_for = 1,
    labelled_by = 2,
    controller_for = 3,
    controlled_by = 4,
    member_of = 5,
    tooltip_for = 6,
    node_child_of = 7,
    node_parent_of = 8,
    extended = 9,
    flows_to = 10,
    flows_from = 11,
    subwindow_of = 12,
    embeds = 13,
    embedded_by = 14,
    popup_for = 15,
    parent_window_of = 16,
    description_for = 17,
    described_by = 18,
    details = 19,
    details_for = 20,
    error_message = 21,
    error_for = 22,
};

/// The three announcement priorities an `Announcement` event carries.
///
/// Upstream `atspi_common::Politeness`. `node.rs:518-522` narrows the consumer's
/// `Live` onto it, and `docs/41` section 1.7 records it as the `detail1` of
/// `Event.Object.Announcement`, whose wire type is `i`.
///
/// Source: `atspi-common` 0.13.0 `lib.rs:178-200`.
pub const Politeness = enum(i32) {
    /// The region does not announce. Upstream `Politeness::None`.
    none = 0,
    /// The region announces at the polite priority. Upstream
    /// `Politeness::Polite`.
    polite = 1,
    /// The region announces at the assertive priority. Upstream
    /// `Politeness::Assertive`.
    assertive = 2,
};

/// The complete role domain for `Accessible.GetRole` and cache-item `role`, encoded as `u`.
/// Source: `atspi-common` 0.13.0 `role.rs:337-467`.
pub const Role = enum(u32) {
    invalid = 0,
    accelerator_label = 1,
    alert = 2,
    animation = 3,
    arrow = 4,
    calendar = 5,
    canvas = 6,
    check_box = 7,
    check_menu_item = 8,
    color_chooser = 9,
    column_header = 10,
    combo_box = 11,
    date_editor = 12,
    desktop_icon = 13,
    desktop_frame = 14,
    dial = 15,
    dialog = 16,
    directory_pane = 17,
    drawing_area = 18,
    file_chooser = 19,
    filler = 20,
    focus_traversable = 21,
    font_chooser = 22,
    frame = 23,
    glass_pane = 24,
    html_container = 25,
    icon = 26,
    image = 27,
    internal_frame = 28,
    label = 29,
    layered_pane = 30,
    list = 31,
    list_item = 32,
    menu = 33,
    menu_bar = 34,
    menu_item = 35,
    option_pane = 36,
    page_tab = 37,
    page_tab_list = 38,
    panel = 39,
    password_text = 40,
    popup_menu = 41,
    progress_bar = 42,
    button = 43,
    radio_button = 44,
    radio_menu_item = 45,
    root_pane = 46,
    row_header = 47,
    scroll_bar = 48,
    scroll_pane = 49,
    separator = 50,
    slider = 51,
    spin_button = 52,
    split_pane = 53,
    status_bar = 54,
    table = 55,
    table_cell = 56,
    table_column_header = 57,
    table_row_header = 58,
    tearoff_menu_item = 59,
    terminal = 60,
    text = 61,
    toggle_button = 62,
    tool_bar = 63,
    tool_tip = 64,
    tree = 65,
    tree_table = 66,
    unknown = 67,
    viewport = 68,
    window = 69,
    extended = 70,
    header = 71,
    footer = 72,
    paragraph = 73,
    ruler = 74,
    application = 75,
    autocomplete = 76,
    editbar = 77,
    embedded = 78,
    entry = 79,
    chart = 80,
    caption = 81,
    document_frame = 82,
    heading = 83,
    page = 84,
    section = 85,
    redundant_object = 86,
    form = 87,
    link = 88,
    input_method_window = 89,
    table_row = 90,
    tree_item = 91,
    document_spreadsheet = 92,
    document_presentation = 93,
    document_text = 94,
    document_web = 95,
    document_email = 96,
    comment = 97,
    list_box = 98,
    grouping = 99,
    image_map = 100,
    notification = 101,
    info_bar = 102,
    level_bar = 103,
    title_bar = 104,
    block_quote = 105,
    audio = 106,
    video = 107,
    definition = 108,
    article = 109,
    landmark = 110,
    log = 111,
    marquee = 112,
    math = 113,
    rating = 114,
    timer = 115,
    static = 116,
    math_fraction = 117,
    math_root = 118,
    subscript = 119,
    superscript = 120,
    description_list = 121,
    description_term = 122,
    description_value = 123,
    footnote = 124,
    content_deletion = 125,
    content_insertion = 126,
    mark = 127,
    suggestion = 128,
    push_button_menu = 129,
};

/// The complete state domain, with each tag equal to its packed-state bit position.
/// `Accessible.GetState` and cache states encode the set as two `u32` words.
/// Source: `atspi-common` 0.13.0 `state.rs:18-221,494-508`.
pub const State = enum(u6) {
    invalid = 0,
    active = 1,
    armed = 2,
    busy = 3,
    checked = 4,
    collapsed = 5,
    defunct = 6,
    editable = 7,
    enabled = 8,
    expandable = 9,
    expanded = 10,
    focusable = 11,
    focused = 12,
    has_tooltip = 13,
    horizontal = 14,
    iconified = 15,
    modal = 16,
    multi_line = 17,
    multi_selectable = 18,
    @"opaque" = 19,
    pressed = 20,
    resizable = 21,
    selectable = 22,
    selected = 23,
    sensitive = 24,
    showing = 25,
    single_line = 26,
    stale = 27,
    transient = 28,
    vertical = 29,
    visible = 30,
    manages_descendants = 31,
    indeterminate = 32,
    required = 33,
    truncated = 34,
    animated = 35,
    invalid_entry = 36,
    supports_autocompletion = 37,
    selectable_text = 38,
    is_default = 39,
    visited = 40,
    checkable = 41,
    has_popup = 42,
    read_only = 43,
};

/// The number of members of `State`. Every walk over the domain is bounded by
/// it.
pub const state_count = @typeInfo(State).@"enum".fields.len;

/// One past the highest canonical state bit, including `read_only` at 43.
/// A packed state set needs a `u64` because this exceeds one `u32`.
pub const state_bits: u7 = blk: {
    var widest: u7 = 0;
    for (std.enums.values(State)) |value| {
        const tag: u7 = @intFromEnum(value);
        if (tag > widest) widest = tag;
    }
    break :blk widest + 1;
};

comptime {
    // The highest canonical state bit is `read_only` at 43.
    if (state_bits > 64) @compileError("StateSet is one u64 wide");
    for (std.enums.values(State)) |value| {
        const bit: u7 = @intFromEnum(value);
        if (bit > 63) @compileError("a State value does not fit a u64 mask");
    }
}

/// The static `StateChanged` name from `atspi-common` 0.13.0 `state.rs:231-276`.
pub fn stateName(value: State) [:0]const u8 {
    return switch (value) {
        .invalid => "invalid",
        .active => "active",
        .armed => "armed",
        .busy => "busy",
        .checked => "checked",
        .collapsed => "collapsed",
        .defunct => "defunct",
        .editable => "editable",
        .enabled => "enabled",
        .expandable => "expandable",
        .expanded => "expanded",
        .focusable => "focusable",
        .focused => "focused",
        .has_tooltip => "has-tooltip",
        .horizontal => "horizontal",
        .iconified => "iconified",
        .modal => "modal",
        .multi_line => "multi-line",
        .multi_selectable => "multiselectable",
        .@"opaque" => "opaque",
        .pressed => "pressed",
        .resizable => "resizable",
        .selectable => "selectable",
        .selected => "selected",
        .sensitive => "sensitive",
        .showing => "showing",
        .single_line => "single-line",
        .stale => "stale",
        .transient => "transient",
        .vertical => "vertical",
        .visible => "visible",
        .manages_descendants => "manages-descendants",
        .indeterminate => "indeterminate",
        .required => "required",
        .truncated => "truncated",
        .animated => "animated",
        .invalid_entry => "invalid-entry",
        .supports_autocompletion => "supports-autocompletion",
        .selectable_text => "selectable-text",
        .is_default => "is-default",
        .visited => "visited",
        .checkable => "checkable",
        .has_popup => "has-popup",
        .read_only => "read-only",
    };
}

/// Highest accepted role code from the pinned canonical domain.
pub const role_code_max: u32 = @intFromEnum(Role.push_button_menu);
/// Highest accepted state bit position from the pinned canonical domain.
pub const state_code_max: u32 = @intFromEnum(State.read_only);
/// Highest accepted drawing-layer code from the pinned canonical domain.
pub const layer_code_max: u32 = @intFromEnum(Layer.window);
/// Highest accepted relation code from the pinned canonical domain.
pub const relation_type_code_max: u32 = @intFromEnum(RelationType.error_for);

/// The set of defined state bits. Bits outside this mask are invalid peer input.
pub const state_mask: u64 = blk: {
    var bits: u64 = 0;
    for (std.enums.values(State)) |value| {
        bits |= @as(u64, 1) << @intFromEnum(value);
    }
    break :blk bits;
};

/// `StateSet.fromWords` rejects a packed set with an undefined state bit.
pub const StateMaskError = error{InvalidStateMask};

/// The set of states one node reports, packed one bit per `State`.
///
/// Upstream `atspi_common::StateSet`. `node.rs:301-389` inserts into it,
/// `node.rs:609` takes the symmetric difference of two of them, and
/// `Accessible.GetState` marshals it as an array of unsigned 32-bit words.
pub const StateSet = struct {
    /// The packed bits, one per tag of `State`. A `u64` and not a `u32`,
    /// because `state_bits` is forty-four and a `u32` holds thirty-two.
    bits: u64 = 0,

    /// The empty set. Upstream `StateSet::empty`, and `node.rs:1856` returns it
    /// for the root object.
    pub const empty: StateSet = .{ .bits = 0 };

    /// The one-member set for `State::Defunct`, which `node.rs:1006` returns for
    /// a node whose context has gone.
    pub const defunct: StateSet = singleton(.defunct);

    /// The two protocol words, least-significant word first. Allocates nothing.
    /// Source: `atspi-common` 0.13.0 `state.rs:494-508`.
    pub fn toWords(set: StateSet) [2]u32 {
        return .{ @truncate(set.bits), @truncate(set.bits >> 32) };
    }

    /// Decodes two protocol words without allocation.
    /// `error.InvalidStateMask` rejects undefined bits without returning a partial set.
    /// Source: `atspi-common` 0.13.0 `state.rs:372-376,478-484`.
    pub fn fromWords(words: [2]u32) StateMaskError!StateSet {
        const bits = @as(u64, words[0]) | (@as(u64, words[1]) << 32);
        if (bits & ~state_mask != 0) return error.InvalidStateMask;
        return .{ .bits = bits };
    }

    /// The tag of `State`, which is its bit position in `bits`.
    fn mask(value: State) u64 {
        return @as(u64, 1) << @as(u6, @intFromEnum(value));
    }

    /// The set holding only `value`. Upstream `From<State> for StateSet`, at
    /// `node.rs:1007`.
    pub fn singleton(value: State) StateSet {
        return .{ .bits = mask(value) };
    }

    /// True when `set` carries `value`. Upstream `StateSet::contains`, at
    /// `node.rs:368` and `:372`.
    pub fn contains(set: StateSet, value: State) bool {
        return set.bits & mask(value) != 0;
    }

    /// Adds `value` to `set`. Upstream `StateSet::insert`.
    pub fn insert(set: *StateSet, value: State) void {
        set.bits |= mask(value);
    }

    /// The members `left` and `right` disagree on, into `out`.
    ///
    /// Upstream takes the symmetric difference of two `StateSet`s at
    /// `node.rs:609` and emits one `StateChanged` per member, so the list is
    /// bounded by `state_count`.
    ///
    /// **Errors.** This function does not fail.
    pub fn difference(
        left: StateSet,
        right: StateSet,
        out: *[state_count]State,
    ) []const State {
        var len: usize = 0;
        inline for (comptime std.enums.values(State)) |value| {
            if (left.contains(value) != right.contains(value)) {
                out[len] = value;
                len += 1;
            }
        }
        return out[0..len];
    }
};

/// The tag `value` carries, or `null` when no tag does.
///
/// A peer sends `u32` for `GetRole`, `GetLayer`, `CoordType`, `Granularity`,
/// `ScrollType` and `RelationType`, so a number this port does not declare is a
/// value it must answer `null` to rather than a value it must guess at.
///
/// **Errors.** This function does not fail.
pub fn roleFromInt(value: u32) ?Role {
    if (value > role_code_max) return null;
    return std.enums.fromInt(Role, value);
}

/// The tag `value` carries, or `null` when no tag does. Same contract as
/// `roleFromInt`, for `CoordType`.
///
/// **Errors.** This function does not fail.
pub fn coordTypeFromInt(value: u32) ?CoordType {
    return std.enums.fromInt(CoordType, value);
}

/// The tag `value` carries, or `null` when no tag does. Same contract as
/// `roleFromInt`, for `Granularity`.
///
/// **Errors.** This function does not fail.
pub fn granularityFromInt(value: u32) ?Granularity {
    return std.enums.fromInt(Granularity, value);
}

/// The tag `value` carries, or `null` when no tag does. Same contract as
/// `roleFromInt`, for `ScrollType`.
///
/// **Errors.** This function does not fail.
pub fn scrollTypeFromInt(value: u32) ?ScrollType {
    return std.enums.fromInt(ScrollType, value);
}

/// The tag `value` carries, or `null` when no tag does. Same contract as
/// `roleFromInt`, for `Layer`.
///
/// **Errors.** This function does not fail.
pub fn layerFromInt(value: u32) ?Layer {
    if (value > layer_code_max) return null;
    return std.enums.fromInt(Layer, value);
}

/// The canonical state bit position, or `null` for an undefined position.
pub fn stateFromInt(value: u32) ?State {
    if (value > state_code_max) return null;
    return std.enums.fromInt(State, value);
}

/// The canonical relation, or `null` for an undefined code.
pub fn relationTypeFromInt(value: u32) ?RelationType {
    if (value > relation_type_code_max) return null;
    return std.enums.fromInt(RelationType, value);
}

const testing = std.testing;

test "every Interface member has the D-Bus name the reference declares" {
    // `docs/41` section 1.5 names ten node interfaces and section 1.6 the cache,
    // plus the application on the root path. A port that misspelled one would
    // export an interface no client asks for.
    try testing.expectEqualStrings("org.a11y.atspi.Accessible", interfaceName(.accessible));
    try testing.expectEqualStrings("org.a11y.atspi.Action", interfaceName(.action));
    try testing.expectEqualStrings("org.a11y.atspi.Application", interfaceName(.application));
    try testing.expectEqualStrings("org.a11y.atspi.Cache", interfaceName(.cache));
    try testing.expectEqualStrings("org.a11y.atspi.Component", interfaceName(.component));
    try testing.expectEqualStrings("org.a11y.atspi.Document", interfaceName(.document));
    try testing.expectEqualStrings("org.a11y.atspi.EditableText", interfaceName(.editable_text));
    try testing.expectEqualStrings("org.a11y.atspi.Hyperlink", interfaceName(.hyperlink));
    try testing.expectEqualStrings("org.a11y.atspi.Image", interfaceName(.image));
    try testing.expectEqualStrings("org.a11y.atspi.Selection", interfaceName(.selection));
    try testing.expectEqualStrings("org.a11y.atspi.Text", interfaceName(.text));
    try testing.expectEqualStrings("org.a11y.atspi.Value", interfaceName(.value));
}


test "the root object's interface set is Accessible or Application" {
    // `node.rs:1843`.
    var set = InterfaceSet.empty;
    set.insert(.accessible);
    set.insert(.application);
    try testing.expect(set.contains(.accessible));
    try testing.expect(set.contains(.application));
    try testing.expect(!set.contains(.text));
}

test "the interface difference is the symmetric difference" {
    var left = InterfaceSet.empty;
    left.insert(.accessible);
    left.insert(.text);

    var right = InterfaceSet.empty;
    right.insert(.accessible);
    right.insert(.value);

    var out: [interface_count]Interface = undefined;
    const delta = left.difference(right, &out);
    try testing.expectEqual(@as(usize, 2), delta.len);
    try testing.expectEqual(Interface.text, delta[0]);
    try testing.expectEqual(Interface.value, delta[1]);
}



test "the state set difference is what node.rs:609 iterates over" {
    var old = StateSet.empty;
    old.insert(.focused);
    old.insert(.visible);

    var new = StateSet.empty;
    new.insert(.visible);
    new.insert(.enabled);

    var out: [state_count]State = undefined;
    const delta = old.difference(new, &out);
    try testing.expectEqual(@as(usize, 2), delta.len);
    // The canonical `enabled` bit precedes the canonical `focused` bit.
    try testing.expectEqual(State.enabled, delta[0]);
    try testing.expectEqual(State.focused, delta[1]);
}

test "the defunct set is the one-member set node.rs:1006 returns" {
    try testing.expect(StateSet.defunct.contains(.defunct));
    try testing.expect(!StateSet.defunct.contains(.visible));
}

test "a peer value outside the declared domain decodes to null rather than a guess" {
    try testing.expect(roleFromInt(9999) == null);
    try testing.expect(roleFromInt(0) == .invalid);
    try testing.expect(granularityFromInt(2) == .sentence);
    try testing.expect(scrollTypeFromInt(7) == null);
    try testing.expect(coordTypeFromInt(3) == null);
    try testing.expect(layerFromInt(8) == null);
}

test "the Politeness domain is the three values an announcement can carry" {
    try testing.expectEqual(@as(i32, 0), @intFromEnum(Politeness.none));
    try testing.expectEqual(@as(i32, 1), @intFromEnum(Politeness.polite));
    try testing.expectEqual(@as(i32, 2), @intFromEnum(Politeness.assertive));
}

test "AT-SPI protocol regression: role reply numbers and recorded little-endian bytes" {
    // Source: atspi-common 0.13.0 role.rs:337-467. These literal D-Bus `u`
    // payloads are transcribed from that table, not captured from a live client.
    const cases = [_]struct { role: Role, code: u32, bytes: [4]u8 }{
        .{ .role = .button, .code = 43, .bytes = .{ 43, 0, 0, 0 } },
        .{ .role = .application, .code = 75, .bytes = .{ 75, 0, 0, 0 } },
        .{ .role = .password_text, .code = 40, .bytes = .{ 40, 0, 0, 0 } },
        .{ .role = .radio_button, .code = 44, .bytes = .{ 44, 0, 0, 0 } },
        .{ .role = .scroll_bar, .code = 48, .bytes = .{ 48, 0, 0, 0 } },
        .{ .role = .entry, .code = 79, .bytes = .{ 79, 0, 0, 0 } },
        .{ .role = .content_insertion, .code = 126, .bytes = .{ 126, 0, 0, 0 } },
        .{ .role = .root_pane, .code = 46, .bytes = .{ 46, 0, 0, 0 } },
        .{ .role = .document_text, .code = 94, .bytes = .{ 94, 0, 0, 0 } },
    };
    for (cases) |case| {
        const code = @intFromEnum(case.role);
        try testing.expectEqual(case.code, code);
        try testing.expectEqual(case.role, roleFromInt(case.code).?);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, code, .little);
        try testing.expectEqualSlices(u8, &case.bytes, &bytes);
    }
}

test "AT-SPI protocol regression: layer and relation client numbers" {
    // Source: atspi-common 0.13.0 lib.rs:128-150 and relation_type.rs:6-121.
    try testing.expectEqual(@as(u32, 3), @intFromEnum(Layer.widget));
    try testing.expectEqual(@as(u32, 7), @intFromEnum(Layer.window));
    try testing.expectEqual(Layer.widget, layerFromInt(3).?);
    try testing.expectEqual(Layer.window, layerFromInt(7).?);
    try testing.expectEqual(@as(u32, 3), @intFromEnum(RelationType.controller_for));
    try testing.expectEqual(@as(u32, 4), @intFromEnum(RelationType.controlled_by));
    try testing.expectEqual(@as(u32, 5), @intFromEnum(RelationType.member_of));
    try testing.expectEqual(@as(u32, 7), @intFromEnum(RelationType.node_child_of));
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, @intFromEnum(RelationType.controller_for), .little);
    try testing.expectEqualSlices(u8, &.{ 3, 0, 0, 0 }, &bytes);
    try testing.expectEqual(RelationType.controller_for, relationTypeFromInt(3).?);
    try testing.expectEqual(RelationType.member_of, relationTypeFromInt(5).?);
    std.mem.writeInt(u32, &bytes, @intFromEnum(Layer.widget), .little);
    try testing.expectEqualSlices(u8, &.{ 3, 0, 0, 0 }, &bytes);
    std.mem.writeInt(u32, &bytes, @intFromEnum(Layer.window), .little);
    try testing.expectEqualSlices(u8, &.{ 7, 0, 0, 0 }, &bytes);
}

test "AT-SPI protocol regression: packed states retain focus and second-word semantics" {
    // Source: atspi-common 0.13.0 state.rs:18-221,494-508. The masks are
    // recorded literal expectations for Accessible.GetState and cache states.
    const cases = [_]struct { state: State, words: [2]u32 }{
        .{ .state = .focusable, .words = .{ 0x00000800, 0 } },
        .{ .state = .focused, .words = .{ 0x00001000, 0 } },
        .{ .state = .read_only, .words = .{ 0, 0x00000800 } },
        .{ .state = .indeterminate, .words = .{ 0, 1 } },
        .{ .state = .defunct, .words = .{ 0x00000040, 0 } },
        .{ .state = .expanded, .words = .{ 0x00000400, 0 } },
        .{ .state = .selected, .words = .{ 0x00800000, 0 } },
        .{ .state = .selectable_text, .words = .{ 0, 0x00000040 } },
        .{ .state = .checkable, .words = .{ 0, 0x00000200 } },
    };
    for (cases) |case| {
        const set = StateSet.singleton(case.state);
        const words = set.toWords();
        try testing.expectEqualSlices(u32, &case.words, &words);
        const decoded = try StateSet.fromWords(case.words);
        try testing.expectEqual(set.bits, decoded.bits);
        try testing.expect(set.contains(case.state));
    }
    var set = StateSet.singleton(.focusable);
    set.insert(.focused);
    set.insert(.indeterminate);
    set.insert(.read_only);
    try testing.expectEqual(@as(u64, 0x0000080100001800), set.bits);
    var bytes: [12]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], 8, .little);
    std.mem.writeInt(u32, bytes[4..8], @truncate(set.bits), .little);
    std.mem.writeInt(u32, bytes[8..12], @truncate(set.bits >> 32), .little);
    try testing.expectEqualSlices(u8, &.{ 8, 0, 0, 0, 0, 24, 0, 0, 1, 8, 0, 0 }, &bytes);
    // The upstream test publishes this exact Indeterminate array fixture.
    // https://docs.rs/atspi-common/0.13.0/src/atspi_common/state.rs.html#610-620
    const indeterminate = StateSet.singleton(.indeterminate);
    std.mem.writeInt(u32, bytes[4..8], @truncate(indeterminate.bits), .little);
    std.mem.writeInt(u32, bytes[8..12], @truncate(indeterminate.bits >> 32), .little);
    try testing.expectEqualSlices(u8, &.{ 8, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0 }, &bytes);
}

test "AT-SPI canonical domains: complete role decoding at runtime and comptime" {
    try testCanonicalRoles();
    comptime {
        @setEvalBranchQuota(100000);
        try testCanonicalRoles();
    }
}

fn testCanonicalRoles() error{TestUnexpectedResult, TestExpectedEqual}!void {
    // Pinned source supplies each code and role independently of the production enum.
    // https://docs.rs/atspi-common/0.13.0/src/atspi_common/role.rs.html#337-467
    const cases = [_]struct { value: Role, code: u32 }{
        .{ .value = .invalid, .code = 0 },
        .{ .value = .accelerator_label, .code = 1 },
        .{ .value = .alert, .code = 2 },
        .{ .value = .animation, .code = 3 },
        .{ .value = .arrow, .code = 4 },
        .{ .value = .calendar, .code = 5 },
        .{ .value = .canvas, .code = 6 },
        .{ .value = .check_box, .code = 7 },
        .{ .value = .check_menu_item, .code = 8 },
        .{ .value = .color_chooser, .code = 9 },
        .{ .value = .column_header, .code = 10 },
        .{ .value = .combo_box, .code = 11 },
        .{ .value = .date_editor, .code = 12 },
        .{ .value = .desktop_icon, .code = 13 },
        .{ .value = .desktop_frame, .code = 14 },
        .{ .value = .dial, .code = 15 },
        .{ .value = .dialog, .code = 16 },
        .{ .value = .directory_pane, .code = 17 },
        .{ .value = .drawing_area, .code = 18 },
        .{ .value = .file_chooser, .code = 19 },
        .{ .value = .filler, .code = 20 },
        .{ .value = .focus_traversable, .code = 21 },
        .{ .value = .font_chooser, .code = 22 },
        .{ .value = .frame, .code = 23 },
        .{ .value = .glass_pane, .code = 24 },
        .{ .value = .html_container, .code = 25 },
        .{ .value = .icon, .code = 26 },
        .{ .value = .image, .code = 27 },
        .{ .value = .internal_frame, .code = 28 },
        .{ .value = .label, .code = 29 },
        .{ .value = .layered_pane, .code = 30 },
        .{ .value = .list, .code = 31 },
        .{ .value = .list_item, .code = 32 },
        .{ .value = .menu, .code = 33 },
        .{ .value = .menu_bar, .code = 34 },
        .{ .value = .menu_item, .code = 35 },
        .{ .value = .option_pane, .code = 36 },
        .{ .value = .page_tab, .code = 37 },
        .{ .value = .page_tab_list, .code = 38 },
        .{ .value = .panel, .code = 39 },
        .{ .value = .password_text, .code = 40 },
        .{ .value = .popup_menu, .code = 41 },
        .{ .value = .progress_bar, .code = 42 },
        .{ .value = .button, .code = 43 },
        .{ .value = .radio_button, .code = 44 },
        .{ .value = .radio_menu_item, .code = 45 },
        .{ .value = .root_pane, .code = 46 },
        .{ .value = .row_header, .code = 47 },
        .{ .value = .scroll_bar, .code = 48 },
        .{ .value = .scroll_pane, .code = 49 },
        .{ .value = .separator, .code = 50 },
        .{ .value = .slider, .code = 51 },
        .{ .value = .spin_button, .code = 52 },
        .{ .value = .split_pane, .code = 53 },
        .{ .value = .status_bar, .code = 54 },
        .{ .value = .table, .code = 55 },
        .{ .value = .table_cell, .code = 56 },
        .{ .value = .table_column_header, .code = 57 },
        .{ .value = .table_row_header, .code = 58 },
        .{ .value = .tearoff_menu_item, .code = 59 },
        .{ .value = .terminal, .code = 60 },
        .{ .value = .text, .code = 61 },
        .{ .value = .toggle_button, .code = 62 },
        .{ .value = .tool_bar, .code = 63 },
        .{ .value = .tool_tip, .code = 64 },
        .{ .value = .tree, .code = 65 },
        .{ .value = .tree_table, .code = 66 },
        .{ .value = .unknown, .code = 67 },
        .{ .value = .viewport, .code = 68 },
        .{ .value = .window, .code = 69 },
        .{ .value = .extended, .code = 70 },
        .{ .value = .header, .code = 71 },
        .{ .value = .footer, .code = 72 },
        .{ .value = .paragraph, .code = 73 },
        .{ .value = .ruler, .code = 74 },
        .{ .value = .application, .code = 75 },
        .{ .value = .autocomplete, .code = 76 },
        .{ .value = .editbar, .code = 77 },
        .{ .value = .embedded, .code = 78 },
        .{ .value = .entry, .code = 79 },
        .{ .value = .chart, .code = 80 },
        .{ .value = .caption, .code = 81 },
        .{ .value = .document_frame, .code = 82 },
        .{ .value = .heading, .code = 83 },
        .{ .value = .page, .code = 84 },
        .{ .value = .section, .code = 85 },
        .{ .value = .redundant_object, .code = 86 },
        .{ .value = .form, .code = 87 },
        .{ .value = .link, .code = 88 },
        .{ .value = .input_method_window, .code = 89 },
        .{ .value = .table_row, .code = 90 },
        .{ .value = .tree_item, .code = 91 },
        .{ .value = .document_spreadsheet, .code = 92 },
        .{ .value = .document_presentation, .code = 93 },
        .{ .value = .document_text, .code = 94 },
        .{ .value = .document_web, .code = 95 },
        .{ .value = .document_email, .code = 96 },
        .{ .value = .comment, .code = 97 },
        .{ .value = .list_box, .code = 98 },
        .{ .value = .grouping, .code = 99 },
        .{ .value = .image_map, .code = 100 },
        .{ .value = .notification, .code = 101 },
        .{ .value = .info_bar, .code = 102 },
        .{ .value = .level_bar, .code = 103 },
        .{ .value = .title_bar, .code = 104 },
        .{ .value = .block_quote, .code = 105 },
        .{ .value = .audio, .code = 106 },
        .{ .value = .video, .code = 107 },
        .{ .value = .definition, .code = 108 },
        .{ .value = .article, .code = 109 },
        .{ .value = .landmark, .code = 110 },
        .{ .value = .log, .code = 111 },
        .{ .value = .marquee, .code = 112 },
        .{ .value = .math, .code = 113 },
        .{ .value = .rating, .code = 114 },
        .{ .value = .timer, .code = 115 },
        .{ .value = .static, .code = 116 },
        .{ .value = .math_fraction, .code = 117 },
        .{ .value = .math_root, .code = 118 },
        .{ .value = .subscript, .code = 119 },
        .{ .value = .superscript, .code = 120 },
        .{ .value = .description_list, .code = 121 },
        .{ .value = .description_term, .code = 122 },
        .{ .value = .description_value, .code = 123 },
        .{ .value = .footnote, .code = 124 },
        .{ .value = .content_deletion, .code = 125 },
        .{ .value = .content_insertion, .code = 126 },
        .{ .value = .mark, .code = 127 },
        .{ .value = .suggestion, .code = 128 },
        .{ .value = .push_button_menu, .code = 129 },
    };
    for (cases) |case| {
        try testing.expectEqual(case.code, @intFromEnum(case.value));
        try testing.expectEqual(@as(?Role, case.value), roleFromInt(case.code));
    }
    inline for (comptime std.enums.values(Role)) |value| {
        const code = @intFromEnum(value);
        try testing.expect(code < cases.len);
        try testing.expectEqual(value, cases[code].value);
    }
    try testing.expect(roleFromInt(130) == null);
    try testing.expect(roleFromInt(131) == null);
    try testing.expect(roleFromInt(std.math.maxInt(u32)) == null);
}

test "AT-SPI canonical domains: complete state codes masks and event names" {
    try testCanonicalStates();
    comptime {
        @setEvalBranchQuota(100000);
        try testCanonicalStates();
    }
}

fn testCanonicalStates() error{TestUnexpectedResult, TestExpectedEqual, InvalidStateMask}!void {
    // Bit order and names: pinned atspi-common 0.13.0 state.rs:18-276.
    // https://docs.rs/atspi-common/0.13.0/src/atspi_common/state.rs.html#18-276
    const cases = [_]struct { value: State, code: u32, words: [2]u32, name: []const u8 }{
        .{ .value = .invalid, .code = 0, .words = .{ 0x00000001, 0x00000000 }, .name = "invalid" },
        .{ .value = .active, .code = 1, .words = .{ 0x00000002, 0x00000000 }, .name = "active" },
        .{ .value = .armed, .code = 2, .words = .{ 0x00000004, 0x00000000 }, .name = "armed" },
        .{ .value = .busy, .code = 3, .words = .{ 0x00000008, 0x00000000 }, .name = "busy" },
        .{ .value = .checked, .code = 4, .words = .{ 0x00000010, 0x00000000 }, .name = "checked" },
        .{ .value = .collapsed, .code = 5, .words = .{ 0x00000020, 0x00000000 }, .name = "collapsed" },
        .{ .value = .defunct, .code = 6, .words = .{ 0x00000040, 0x00000000 }, .name = "defunct" },
        .{ .value = .editable, .code = 7, .words = .{ 0x00000080, 0x00000000 }, .name = "editable" },
        .{ .value = .enabled, .code = 8, .words = .{ 0x00000100, 0x00000000 }, .name = "enabled" },
        .{ .value = .expandable, .code = 9, .words = .{ 0x00000200, 0x00000000 }, .name = "expandable" },
        .{ .value = .expanded, .code = 10, .words = .{ 0x00000400, 0x00000000 }, .name = "expanded" },
        .{ .value = .focusable, .code = 11, .words = .{ 0x00000800, 0x00000000 }, .name = "focusable" },
        .{ .value = .focused, .code = 12, .words = .{ 0x00001000, 0x00000000 }, .name = "focused" },
        .{ .value = .has_tooltip, .code = 13, .words = .{ 0x00002000, 0x00000000 }, .name = "has-tooltip" },
        .{ .value = .horizontal, .code = 14, .words = .{ 0x00004000, 0x00000000 }, .name = "horizontal" },
        .{ .value = .iconified, .code = 15, .words = .{ 0x00008000, 0x00000000 }, .name = "iconified" },
        .{ .value = .modal, .code = 16, .words = .{ 0x00010000, 0x00000000 }, .name = "modal" },
        .{ .value = .multi_line, .code = 17, .words = .{ 0x00020000, 0x00000000 }, .name = "multi-line" },
        .{ .value = .multi_selectable, .code = 18, .words = .{ 0x00040000, 0x00000000 }, .name = "multiselectable" },
        .{ .value = .@"opaque", .code = 19, .words = .{ 0x00080000, 0x00000000 }, .name = "opaque" },
        .{ .value = .pressed, .code = 20, .words = .{ 0x00100000, 0x00000000 }, .name = "pressed" },
        .{ .value = .resizable, .code = 21, .words = .{ 0x00200000, 0x00000000 }, .name = "resizable" },
        .{ .value = .selectable, .code = 22, .words = .{ 0x00400000, 0x00000000 }, .name = "selectable" },
        .{ .value = .selected, .code = 23, .words = .{ 0x00800000, 0x00000000 }, .name = "selected" },
        .{ .value = .sensitive, .code = 24, .words = .{ 0x01000000, 0x00000000 }, .name = "sensitive" },
        .{ .value = .showing, .code = 25, .words = .{ 0x02000000, 0x00000000 }, .name = "showing" },
        .{ .value = .single_line, .code = 26, .words = .{ 0x04000000, 0x00000000 }, .name = "single-line" },
        .{ .value = .stale, .code = 27, .words = .{ 0x08000000, 0x00000000 }, .name = "stale" },
        .{ .value = .transient, .code = 28, .words = .{ 0x10000000, 0x00000000 }, .name = "transient" },
        .{ .value = .vertical, .code = 29, .words = .{ 0x20000000, 0x00000000 }, .name = "vertical" },
        .{ .value = .visible, .code = 30, .words = .{ 0x40000000, 0x00000000 }, .name = "visible" },
        .{ .value = .manages_descendants, .code = 31, .words = .{ 0x80000000, 0x00000000 }, .name = "manages-descendants" },
        .{ .value = .indeterminate, .code = 32, .words = .{ 0x00000000, 0x00000001 }, .name = "indeterminate" },
        .{ .value = .required, .code = 33, .words = .{ 0x00000000, 0x00000002 }, .name = "required" },
        .{ .value = .truncated, .code = 34, .words = .{ 0x00000000, 0x00000004 }, .name = "truncated" },
        .{ .value = .animated, .code = 35, .words = .{ 0x00000000, 0x00000008 }, .name = "animated" },
        .{ .value = .invalid_entry, .code = 36, .words = .{ 0x00000000, 0x00000010 }, .name = "invalid-entry" },
        .{ .value = .supports_autocompletion, .code = 37, .words = .{ 0x00000000, 0x00000020 }, .name = "supports-autocompletion" },
        .{ .value = .selectable_text, .code = 38, .words = .{ 0x00000000, 0x00000040 }, .name = "selectable-text" },
        .{ .value = .is_default, .code = 39, .words = .{ 0x00000000, 0x00000080 }, .name = "is-default" },
        .{ .value = .visited, .code = 40, .words = .{ 0x00000000, 0x00000100 }, .name = "visited" },
        .{ .value = .checkable, .code = 41, .words = .{ 0x00000000, 0x00000200 }, .name = "checkable" },
        .{ .value = .has_popup, .code = 42, .words = .{ 0x00000000, 0x00000400 }, .name = "has-popup" },
        .{ .value = .read_only, .code = 43, .words = .{ 0x00000000, 0x00000800 }, .name = "read-only" },
    };
    for (cases) |case| {
        try testing.expectEqual(case.code, @intFromEnum(case.value));
        try testing.expectEqual(@as(?State, case.value), stateFromInt(case.code));
        const set = StateSet.singleton(case.value);
        const words = set.toWords();
        try testing.expectEqualSlices(u32, &case.words, &words);
        const decoded = try StateSet.fromWords(case.words);
        try testing.expectEqual(set.bits, decoded.bits);
        try testing.expect(decoded.contains(case.value));
        try testing.expectEqualStrings(case.name, stateName(case.value));
    }
    inline for (comptime std.enums.values(State)) |value| {
        const code = @intFromEnum(value);
        try testing.expect(code < cases.len);
        try testing.expectEqual(value, cases[code].value);
    }
    const all = try StateSet.fromWords(.{ 0xffffffff, 0x00000fff });
    var changed: [state_count]State = undefined;
    const difference = all.difference(StateSet.empty, &changed);
    try testing.expectEqual(cases.len, difference.len);
    for (cases, 0..) |case, index| {
        try testing.expectEqual(case.value, difference[index]);
    }
    try testing.expect(stateFromInt(44) == null);
    try testing.expect(stateFromInt(63) == null);
    try testing.expect(stateFromInt(64) == null);
    try testing.expect(stateFromInt(std.math.maxInt(u32)) == null);
}

test "AT-SPI canonical domains: complete layers and relations at runtime and comptime" {
    try testCanonicalLayersAndRelations();
    comptime {
        @setEvalBranchQuota(100000);
        try testCanonicalLayersAndRelations();
    }
}

fn testCanonicalLayersAndRelations() error{TestUnexpectedResult, TestExpectedEqual}!void {
    // Pinned source: lib.rs:128-150 and relation_type.rs:6-121.
    const layers = [_]struct { value: Layer, code: u32 }{
        .{ .value = .invalid, .code = 0 },
        .{ .value = .background, .code = 1 },
        .{ .value = .canvas, .code = 2 },
        .{ .value = .widget, .code = 3 },
        .{ .value = .mdi, .code = 4 },
        .{ .value = .popup, .code = 5 },
        .{ .value = .overlay, .code = 6 },
        .{ .value = .window, .code = 7 },
    };
    for (layers) |case| {
        try testing.expectEqual(case.code, @intFromEnum(case.value));
        try testing.expectEqual(@as(?Layer, case.value), layerFromInt(case.code));
    }
    inline for (comptime std.enums.values(Layer)) |value| {
        const code = @intFromEnum(value);
        try testing.expect(code < layers.len);
        try testing.expectEqual(value, layers[code].value);
    }
    const relations = [_]struct { value: RelationType, code: u32 }{
        .{ .value = .@"null", .code = 0 },
        .{ .value = .label_for, .code = 1 },
        .{ .value = .labelled_by, .code = 2 },
        .{ .value = .controller_for, .code = 3 },
        .{ .value = .controlled_by, .code = 4 },
        .{ .value = .member_of, .code = 5 },
        .{ .value = .tooltip_for, .code = 6 },
        .{ .value = .node_child_of, .code = 7 },
        .{ .value = .node_parent_of, .code = 8 },
        .{ .value = .extended, .code = 9 },
        .{ .value = .flows_to, .code = 10 },
        .{ .value = .flows_from, .code = 11 },
        .{ .value = .subwindow_of, .code = 12 },
        .{ .value = .embeds, .code = 13 },
        .{ .value = .embedded_by, .code = 14 },
        .{ .value = .popup_for, .code = 15 },
        .{ .value = .parent_window_of, .code = 16 },
        .{ .value = .description_for, .code = 17 },
        .{ .value = .described_by, .code = 18 },
        .{ .value = .details, .code = 19 },
        .{ .value = .details_for, .code = 20 },
        .{ .value = .error_message, .code = 21 },
        .{ .value = .error_for, .code = 22 },
    };
    for (relations) |case| {
        try testing.expectEqual(case.code, @intFromEnum(case.value));
        try testing.expectEqual(@as(?RelationType, case.value), relationTypeFromInt(case.code));
    }
    inline for (comptime std.enums.values(RelationType)) |value| {
        const code = @intFromEnum(value);
        try testing.expect(code < relations.len);
        try testing.expectEqual(value, relations[code].value);
    }
    try testing.expect(layerFromInt(8) == null);
    try testing.expect(layerFromInt(std.math.maxInt(u32)) == null);
    try testing.expect(relationTypeFromInt(23) == null);
    try testing.expect(relationTypeFromInt(std.math.maxInt(u32)) == null);
}

test "AT-SPI canonical domains: state masks reject each unknown high bit" {
    try testStateMaskBoundary();
    comptime {
        @setEvalBranchQuota(100000);
        try testStateMaskBoundary();
    }
}

fn testStateMaskBoundary() error{
    TestUnexpectedResult,
    TestExpectedEqual,
    TestExpectedError,
    InvalidStateMask,
}!void {
    const all = try StateSet.fromWords(.{ 0xffffffff, 0x00000fff });
    const words = all.toWords();
    try testing.expectEqualSlices(u32, &.{ 0xffffffff, 0x00000fff }, &words);
    const empty = try StateSet.fromWords(.{ 0, 0 });
    try testing.expectEqual(@as(u64, 0), empty.bits);
    const unknown_bit_first = 44;
    const packed_bit_count = 64;
    for (unknown_bit_first..packed_bit_count) |bit| {
        const high_word = @as(u32, 1) << @as(u5, @intCast(bit - 32));
        try testing.expectError(error.InvalidStateMask, StateSet.fromWords(.{ 0, high_word }));
        try testing.expectError(
            error.InvalidStateMask,
            StateSet.fromWords(.{ 0xffffffff, 0x00000fff | high_word }),
        );
    }
    try testing.expectError(
        error.InvalidStateMask,
        StateSet.fromWords(.{ 0xffffffff, 0xffffffff }),
    );
    // The source publishes these `au` bytes at state.rs:568,583,598,613,628.
    const fixtures = [_]struct { bytes: [12]u8, bits: u64 }{
        .{ .bytes = .{ 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .bits = 0 },
        .{ .bytes = .{ 8, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0 }, .bits = 1 },
        .{ .bytes = .{ 8, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0 }, .bits = 0x80000000 },
        .{ .bytes = .{ 8, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0 }, .bits = 0x100000000 },
        .{ .bytes = .{ 8, 0, 0, 0, 0, 24, 0, 0, 0, 0, 0, 0 }, .bits = 0x1800 },
    };
    for (fixtures) |fixture| {
        try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, fixture.bytes[0..4], .little));
        const decoded = try StateSet.fromWords(.{
            std.mem.readInt(u32, fixture.bytes[4..8], .little),
            std.mem.readInt(u32, fixture.bytes[8..12], .little),
        });
        try testing.expectEqual(fixture.bits, decoded.bits);
        var encoded: [12]u8 = undefined;
        std.mem.writeInt(u32, encoded[0..4], 8, .little);
        const decoded_words = decoded.toWords();
        std.mem.writeInt(u32, encoded[4..8], decoded_words[0], .little);
        std.mem.writeInt(u32, encoded[8..12], decoded_words[1], .little);
        try testing.expectEqualSlices(u8, &fixture.bytes, &encoded);
    }
}

test "AT-SPI canonical domains: fuzz decoder boundaries and packed masks" {
    try testing.fuzz({}, testWireDomainFuzz, .{});
}

fn testWireDomainFuzz(_: void, smith: *testing.Smith) error{
    TestUnexpectedResult,
    TestExpectedEqual,
    TestExpectedError,
    InvalidStateMask,
}!void {
    const code = smith.value(u32);
    if (code < 130) {
        try testing.expectEqual(code, @intFromEnum(roleFromInt(code).?));
    } else {
        try testing.expect(roleFromInt(code) == null);
    }
    if (code < 44) {
        try testing.expectEqual(code, @as(u32, @intFromEnum(stateFromInt(code).?)));
    } else {
        try testing.expect(stateFromInt(code) == null);
    }
    if (code < 8) {
        try testing.expectEqual(code, @intFromEnum(layerFromInt(code).?));
    } else {
        try testing.expect(layerFromInt(code) == null);
    }
    if (code < 23) {
        try testing.expectEqual(code, @intFromEnum(relationTypeFromInt(code).?));
    } else {
        try testing.expect(relationTypeFromInt(code) == null);
    }
    const words = [2]u32{ smith.value(u32), smith.value(u32) };
    if (words[1] < 0x1000) {
        const decoded = try StateSet.fromWords(words);
        const encoded = decoded.toWords();
        try testing.expectEqualSlices(u32, &words, &encoded);
    } else {
        try testing.expectError(error.InvalidStateMask, StateSet.fromWords(words));
    }
}

test "AT-SPI canonical domains: unchanged coordinate granularity scroll and politeness" {
    try testUnchangedDomains();
    comptime {
        @setEvalBranchQuota(100000);
        try testUnchangedDomains();
    }
}

fn testUnchangedDomains() error{TestUnexpectedResult, TestExpectedEqual}!void {
    // Pinned source: atspi-common 0.13.0 lib.rs:71-81,97-111,152-200.
    const coordinates = [_]CoordType{ .screen, .window, .parent };
    const granularities = [_]Granularity{ .char, .word, .sentence, .line, .paragraph };
    const scroll_types = [_]ScrollType{
        .top_left, .bottom_right, .top_edge, .bottom_edge, .left_edge, .right_edge, .anywhere,
    };
    const priorities = [_]Politeness{ .none, .polite, .assertive };
    for (coordinates, 0..) |value, code| {
        try testing.expectEqual(@as(u32, @intCast(code)), @intFromEnum(value));
        try testing.expectEqual(@as(?CoordType, value), coordTypeFromInt(@intCast(code)));
    }
    for (granularities, 0..) |value, code| {
        try testing.expectEqual(@as(u32, @intCast(code)), @intFromEnum(value));
        try testing.expectEqual(@as(?Granularity, value), granularityFromInt(@intCast(code)));
    }
    for (scroll_types, 0..) |value, code| {
        try testing.expectEqual(@as(u32, @intCast(code)), @intFromEnum(value));
        try testing.expectEqual(@as(?ScrollType, value), scrollTypeFromInt(@intCast(code)));
    }
    for (priorities, 0..) |value, code| {
        try testing.expectEqual(@as(i32, @intCast(code)), @intFromEnum(value));
        try testing.expectEqual(@as(?Politeness, value), std.enums.fromInt(Politeness, code));
    }
    try testing.expect(coordTypeFromInt(3) == null);
    try testing.expect(granularityFromInt(5) == null);
    try testing.expect(scrollTypeFromInt(7) == null);
    try testing.expect(coordTypeFromInt(std.math.maxInt(u32)) == null);
    try testing.expect(granularityFromInt(std.math.maxInt(u32)) == null);
    try testing.expect(scrollTypeFromInt(std.math.maxInt(u32)) == null);
    try testing.expect(std.enums.fromInt(Politeness, @as(i32, -1)) == null);
    try testing.expect(std.enums.fromInt(Politeness, @as(i32, 3)) == null);
}
