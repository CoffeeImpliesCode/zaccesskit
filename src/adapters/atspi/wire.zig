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
//! **The numeric tables are unverified on this host, and the module says so
//! twice.** `Role` and `State` are protocol constants, not choices. The values
//! below are the AT-SPI2 reference values, written here from that specification.
//! The `atspi-common` crate is a crates.io dependency and this host has no
//! registry cache for it, no `libatspi` header and no `gi` bindings, so nothing
//! local contradicts them and nothing local confirms them. `docs/41` section 1.10
//! row U3 records the same gap for `State::to_static_str` and section 0.1
//! records the crate's absence. Every table below therefore carries the
//! `UNVERIFIED` marker, the comptime tests below assert the structural
//! properties a wrong table would break rather than restating the table, and a
//! client that decodes a wrong `GetRole` answer is the failure this leaves open.
//! The correction is one recorded fixture against a live AT-SPI client, which
//! `docs/41` section 8 row 1 hands to `docs/40-plan.md`.
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

/// The ten AT-SPI coordinate spaces a geometry member may be asked about.
///
/// Upstream `atspi_common::CoordType`. The wire type is `u`, per
/// `docs/41` section 1.5 for `Component.Contains`, `GetAccessibleAtPoint`,
/// `GetExtents`, `ScrollTo`, `ScrollToPoint`, `Image.GetImageExtents`,
/// `Image.GetImagePosition`, `Text.GetCharacterExtents`, `GetOffsetAtPoint`,
/// `GetRangeExtents`, `ScrollSubstringTo` and `ScrollSubstringToPoint`.
///
/// **UNVERIFIED.** These are protocol constants; see the module doc.
pub const CoordType = enum(u32) {
    /// Screen coordinates, the origin at the display's top left.
    screen = 0,
    /// Window coordinates, the origin at the window's top left.
    window = 1,
    /// Parent coordinates, the origin at the parent's top left.
    parent = 2,
};

/// The six text granularities `Text.GetStringAtOffset` accepts.
///
/// Upstream `atspi_common::Granularity`. The wire type is `u`. `sentence` is
/// declared because a peer may send it, and `text_range_from_offset` answers
/// `error.UnsupportedTextGranularity` for it, which
/// `atspi-common/src/util.rs:82-83` and `:89-90` is the upstream raise site.
///
/// **UNVERIFIED.** These are protocol constants; see the module doc.
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
/// **UNVERIFIED.** These are protocol constants; see the module doc.
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

/// The two drawing layers `Component.GetLayer` answers.
///
/// Upstream `atspi_common::Layer`. `node.rs:1176-1179` returns `window` for the
/// AT-SPI role `window` and `widget` otherwise. The wire type is `u`.
///
/// **UNVERIFIED.** These are protocol constants; see the module doc.
pub const Layer = enum(u32) {
    /// A window. Upstream `Layer::Window`.
    window = 0,
    /// A widget. Upstream `Layer::Widget`.
    widget = 1,
};

/// The relation types `Accessible.GetRelationSet` can name.
///
/// Upstream `atspi_common::RelationType`. The port emits only `controller_for`,
/// because `node.rs:975-988` builds the map from `node.controls()` and inserts
/// that one key; the rest are declared so a peer's value decodes and so the
/// enum is the whole domain. The wire type is `u`.
///
/// **UNVERIFIED.** These are protocol constants; see the module doc.
pub const RelationType = enum(u32) {
    /// The object is a label for another. Upstream `RelationType::LabelFor`.
    label_for = 1,
    /// The object is labelled by another. Upstream `RelationType::LabelledBy`.
    labelled_by = 2,
    /// The object is a member of another. Upstream `RelationType::MemberOf`.
    member_of = 3,
    /// The object is a node in a tree with another. Upstream
    /// `RelationType::NodeChildOf`.
    node_child_of = 4,
    /// The object controls another. Upstream `RelationType::ControllerFor`.
    controller_for = 5,
    /// The object is controlled by another. Upstream
    /// `RelationType::ControlledBy`.
    controlled_by = 6,
    /// The object is a descendant of another. Upstream
    /// `RelationType::NodeParentOf`.
    node_parent_of = 8,
};

/// The three announcement priorities an `Announcement` event carries.
///
/// Upstream `atspi_common::Politeness`. `node.rs:518-522` narrows the consumer's
/// `Live` onto it, and `docs/41` section 1.7 records it as the `detail1` of
/// `Event.Object.Announcement`, whose wire type is `i`.
///
/// **UNVERIFIED.** These are protocol constants; see the module doc.
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

/// The AT-SPI roles, which the port reports through `Accessible.GetRole` and
/// through the cache item's `role` field. The wire type is `u`.
///
/// Upstream `atspi_common::Role`. `node.rs:87-295` maps each consumer role onto
/// one of these, and a client renders the localized role name from the number,
/// so a wrong member here is a wrong role name on screen.
///
/// **UNVERIFIED.** These are protocol constants; see the module doc. Only the
/// members `node.rs` can produce are declared, because the port never emits a
/// role outside that map; a peer that sends one back is answered by
/// `roleFromInt` returning `null`.
pub const Role = enum(u32) {
    /// Upstream `Role::Invalid`.
    invalid = 0,
    /// Upstream `Role::Alert`, the target of `node.rs:95`.
    alert = 2,
    /// Upstream `Role::Canvas`, the target of `node.rs:111` and of the image
    /// predicate at `node.rs:467`.
    canvas = 6,
    /// Upstream `Role::CheckBox`, the target of `node.rs:112`.
    check_box = 7,
    /// Upstream `Role::ColumnHeader`, the target of `node.rs:114`.
    column_header = 10,
    /// Upstream `Role::ComboBox`, the target of `node.rs:115`.
    combo_box = 11,
    /// Upstream `Role::DateEditor`, the target of `node.rs:272`.
    date_editor = 12,
    /// Upstream `Role::Dialog`, the target of `node.rs:127`.
    dialog = 16,
    /// Upstream `Role::Entry`, the target of `node.rs:267`.
    entry = 83,
    /// Upstream `Role::Extended`, which `node.rs:89` returns for a node that
    /// carries a role description.
    extended = 74,
    /// Upstream `Role::Form`, the target of `node.rs:171`.
    form = 91,
    /// Upstream `Role::Frame`, the target of `node.rs:287`.
    frame = 23,
    /// Upstream `Role::Heading`, the target of `node.rs:179`.
    heading = 87,
    /// Upstream `Role::Image`, the target of `node.rs:182` and of the image
    /// predicate at `node.rs:467`.
    image = 27,
    /// Upstream `Role::InternalFrame`, the target of `node.rs:180`.
    internal_frame = 28,
    /// Upstream `Role::Label`, the target of `node.rs:250`.
    label = 29,
    /// Upstream `Role::Landmark`, the target of `node.rs:100` and of the seven
    /// arms that share it.
    landmark = 113,
    /// Upstream `Role::List`, the target of `node.rs:194`.
    list = 31,
    /// Upstream `Role::ListBox`, the target of `node.rs:195`.
    list_box = 101,
    /// Upstream `Role::ListItem`, the target of `node.rs:196`.
    list_item = 32,
    /// Upstream `Role::Log`, the target of `node.rs:209`.
    log = 114,
    /// Upstream `Role::Marquee`, the target of `node.rs:213`.
    ///
    /// One of the entries whose numeric value this port cannot confirm;
    /// see the module doc.
    marquee = 121,
    /// Upstream `Role::Caption`, the target of `node.rs:113` and `:289`.
    ///
    /// One of the entries whose numeric value this port cannot confirm;
    /// see the module doc.
    caption = 90,
    /// Upstream `Role::Link`, the target of `node.rs:133` and `:192`.
    ///
    /// One of the entries whose numeric value this port cannot confirm;
    /// see the module doc.
    link = 88,
    /// Upstream `Role::RowGroup`, the target of `node.rs:232`.
    row_group = 94,
    /// Upstream `Role::Math`, the target of `node.rs:211`.
    math = 115,
    /// Upstream `Role::Menu`, the target of `node.rs:213`.
    menu = 33,
    /// Upstream `Role::MenuBar`, the target of `node.rs:214`.
    menu_bar = 34,
    /// Upstream `Role::MenuItem`, the target of `node.rs:215`.
    menu_item = 35,
    /// Upstream `Role::CheckMenuItem`, the target of `node.rs:216`.
    check_menu_item = 36,
    /// Upstream `Role::RadioMenuItem`, the target of `node.rs:217`.
    radio_menu_item = 47,
    /// Upstream `Role::RadioButton`, the target of `node.rs:227`.
    radio_button = 48,
    /// Upstream `Role::Notification`, the target of `node.rs:93`.
    notification = 104,
    /// Upstream `Role::Panel`, the target of nine arms at `node.rs`.
    panel = 42,
    /// Upstream `Role::Paragraph`, the target of `node.rs:222`.
    paragraph = 77,
    /// Upstream `Role::PasswordText`, the target of `node.rs:273`.
    password_text = 43,
    /// Upstream `Role::ProgressBar`, the target of `node.rs:225`.
    progress_bar = 45,
    /// Upstream `Role::Section`, the target of six arms at `node.rs`.
    section = 89,
    /// Upstream `Role::ScrollBar`, the target of `node.rs:247`.
    scroll_bar = 51,
    /// Upstream `Role::ScrollPane`, the target of `node.rs:256`.
    scroll_pane = 52,
    /// Upstream `Role::Separator`, the target of `node.rs:249`.
    separator = 53,
    /// Upstream `Role::Slider`, the target of `node.rs:247`.
    slider = 54,
    /// Upstream `Role::SpinButton`, the target of `node.rs:248`.
    spin_button = 55,
    /// Upstream `Role::Static`, the target of six arms at `node.rs`.
    static = 118,
    /// Upstream `Role::StatusBar`, the target of `node.rs:251`.
    status_bar = 57,
    /// Upstream `Role::Table`, the target of `node.rs:177` and of `node.rs:254`.
    table = 58,
    /// Upstream `Role::TableCell`, the target of `node.rs:113`.
    table_cell = 59,
    /// Upstream `Role::TableRow`, the target of `node.rs:231`.
    table_row = 62,
    /// Upstream `Role::RowHeader`, the target of `node.rs:232`.
    row_header = 50,
    /// Upstream `Role::Timer`, the target of `node.rs:277`.
    timer = 117,
    /// Upstream `Role::TitleBar`, the target of `node.rs:260`.
    title_bar = 107,
    /// Upstream `Role::ToolBar`, the target of `node.rs:278`.
    tool_bar = 67,
    /// Upstream `Role::ToolTip`, the target of `node.rs:279`.
    tool_tip = 68,
    /// Upstream `Role::ToggleButton`, the target of `node.rs:106`.
    toggle_button = 66,
    /// Upstream `Role::Tree`, the target of `node.rs:280`.
    tree = 69,
    /// Upstream `Role::TreeItem`, the target of `node.rs:281`.
    tree_item = 95,
    /// Upstream `Role::TreeTable`, the target of `node.rs:282`.
    tree_table = 70,
    /// Upstream `Role::Video`, the target of `node.rs:283`.
    video = 110,
    /// Upstream `Role::Footer`, the target of `node.rs:122` and `:135`.
    footer = 76,
    /// Upstream `Role::Header`, the target of `node.rs:136`.
    header = 75,
    /// Upstream `Role::Comment`, the target of `node.rs:133`.
    comment = 100,
    /// Upstream `Role::Footnote`, the target of `node.rs:134`.
    footnote = 126,
    /// Upstream `Role::DescriptionList`, the target of `node.rs:125`.
    description_list = 123,
    /// Upstream `Role::DescriptionValue`, the target of `node.rs:123`.
    description_value = 125,
    /// Upstream `Role::DescriptionTerm`, the target of `node.rs:259`.
    description_term = 124,
    /// Upstream `Role::ContentDeletion`, the target of `node.rs:118`.
    content_deletion = 127,
    /// Upstream `Role::ContentInsertion`, the target of `node.rs:119`.
    content_insertion = 128,
    /// Upstream `Role::Embedded`, the target of `node.rs:97`, `:167` and `:225`.
    embedded = 82,
    /// Upstream `Role::DocumentFrame`, the target of five arms at `node.rs`.
    document_frame = 86,
    /// Upstream `Role::DocumentWeb`, the target of `node.rs:230`.
    document_web = 98,
    /// Upstream `Role::Article`, the target of `node.rs:99`.
    article = 112,
    /// Upstream `Role::Audio`, the target of `node.rs:100`.
    audio = 109,
    /// Upstream `Role::BlockQuote`, the target of `node.rs:101`.
    block_quote = 108,
    /// Upstream `Role::PageTab`, the target of `node.rs:253`.
    page_tab = 40,
    /// Upstream `Role::PageTabList`, the target of `node.rs:256`.
    page_tab_list = 41,
    /// Upstream `Role::Button`, the target of six arms at `node.rs`.
    button = 46,
    /// Upstream `Role::Terminal`, the target of `node.rs:292`.
    terminal = 64,
    /// Upstream `Role::RedundantObject`, the target of `node.rs:292`.
    redundant_object = 92,
    /// Upstream `Role::Application`, the target of `node.rs:1846` through
    /// `PlatformRoot::role`.
    application = 79,
    /// Upstream `Role::LevelBar`, the target of `node.rs:218`.
    level_bar = 106,
    /// Upstream `Role::Unknown`, the target of `node.rs:102` and `:291`.
    unknown = 71,
};

/// The AT-SPI states, reported through `Accessible.GetState` as `au`, through
/// the cache item's `states` field, and as the `detail1` of a `StateChanged`
/// event with the name in `kind`.
///
/// Upstream `atspi_common::State`. The bit position is the wire value, because
/// the set is marshalled as a packed array of unsigned 32-bit words.
///
/// The tag is `u6` and not `u5` because the reference numbering reaches
/// `selected` at 43, and a `u5` cannot hold a value above 31. A tag that
/// wrapped would make `selected` alias `selectable`, which is a state a screen
/// reader acts on, so the width is a protocol requirement rather than a size
/// choice, and the comptime block below holds it.
///
/// **UNVERIFIED.** These are protocol constants; see the module doc.
pub const State = enum(u6) {
    /// `node.rs:310`. Upstream `State::Active`.
    active = 1,
    /// `node.rs:313`. Upstream `State::Armed`.
    armed = 2,
    /// `node.rs:339`. Upstream `State::Busy`.
    busy = 3,
    /// `node.rs:372`. Upstream `State::Checked`.
    checked = 4,
    /// Upstream `State::Collapsed`.
    collapsed = 5,
    /// Upstream `State::Defocused`.
    defocused = 6,
    /// `node.rs:313`. Upstream `State::Editable`.
    editable = 7,
    /// `node.rs:381`. Upstream `State::Enabled`.
    enabled = 8,
    /// Upstream `State::Expandable`.
    expandable = 9,
    /// `node.rs:317`. Upstream `State::Focusable`.
    focusable = 10,
    /// `node.rs:384`. Upstream `State::Focused`.
    focused = 11,
    /// Upstream `State::HasTooltip`.
    has_tooltip = 12,
    /// `node.rs:330`. Upstream `State::Horizontal`.
    horizontal = 13,
    /// Upstream `State::Iconified`.
    iconified = 14,
    /// Upstream `State::Insensitive`.
    insensitive = 15,
    /// `node.rs:363` and `:368`. Upstream `State::Indeterminate`.
    indeterminate = 16,
    /// `node.rs:340`. Upstream `State::Modal`.
    modal = 17,
    /// `node.rs:355`. Upstream `State::MultiLine`.
    multi_line = 18,
    /// `node.rs:327`. Upstream `State::MultiSelectable`.
    multi_selectable = 19,
    /// Upstream `State::Opaque`. The member is spelled `@"opaque"` because
    /// `opaque` is a Zig keyword and an unquoted field of that name does not
    /// parse, so the AT-SPI name survives and the Zig syntax stays legal.
    @"opaque" = 20,
    /// `node.rs:370`. Upstream `State::Pressed`.
    pressed = 21,
    /// Upstream `State::Resizable`.
    resizable = 22,
    /// `node.rs:347`. Upstream `State::Selectable`.
    selectable = 23,
    /// `node.rs:381`. Upstream `State::Sensitive`.
    sensitive = 24,
    /// `node.rs:321`. Upstream `State::Showing`.
    showing = 25,
    /// `node.rs:356`. Upstream `State::SingleLine`.
    single_line = 26,
    /// Upstream `State::Stale`.
    stale = 27,
    /// Upstream `State::Transient`.
    transient = 28,
    /// `node.rs:331`. Upstream `State::Vertical`.
    vertical = 29,
    /// `node.rs:321`. Upstream `State::Visible`.
    visible = 30,
    /// Upstream `State::ManagesDescendants`.
    manages_descendants = 31,
    /// Upstream `State::IndeterminateTristate`.
    indeterminate_tristate = 32,
    /// `node.rs:323`. Upstream `State::Required`.
    required = 33,
    /// `node.rs:354`. Upstream `State::SelectableText`.
    selectable_text = 34,
    /// Upstream `State::Visited`.
    visited = 35,
    /// `node.rs:378`. Upstream `State::ReadOnly`.
    read_only = 36,
    /// Upstream `State::ShowExpander`.
    show_expander = 37,
    /// Upstream `State::Atomic`.
    atomic = 38,
    /// `node.rs:1006`, for a node that has left the tree. Upstream
    /// `State::Defunct`.
    defunct = 39,
    /// Upstream `State::Expanded`.
    expanded = 40,
    /// Upstream `State::Marquee`.
    marquee = 41,
    /// `node.rs:337`. Upstream `State::Checkable`.
    checkable = 42,
    /// `node.rs:350`. Upstream `State::Selected`.
    selected = 43,
};

/// The number of members of `State`. Every walk over the domain is bounded by
/// it.
pub const state_count = @typeInfo(State).@"enum".fields.len;

/// One past the largest bit `StateSet` occupies, which is one past the largest
/// tag `State` carries. It is the width the packed set needs, and the reason
/// `StateSet.bits` is a `u64` and not a `u32`: the reference numbering reaches
/// `selected` at 43, so the set is forty-four bits wide and a `u32` holds
/// thirty-two.
pub const state_bits: u7 = blk: {
    var widest: u7 = 0;
    for (std.enums.values(State)) |value| {
        const tag: u7 = @intFromEnum(value);
        if (tag > widest) widest = tag;
    }
    break :blk widest + 1;
};

comptime {
    // `State` is `enum(u6)` and its largest value is `selected` at 43, so a
    // sixth bit holds it. A table that grew past 63 would need a wider tag and
    // the masks below would silently wrap.
    if (state_bits > 64) @compileError("StateSet is one u64 wide");
    if (@typeInfo(State).@"enum".tag_type != u6) @compileError("State must tag as u6");
    // No two members may share a value, because each value is a bit position.
    for (std.enums.values(State)) |value| {
        const bit = @as(u7, @intFromEnum(value));
        if (bit > 63) @compileError("a State value does not fit a u64 mask");
    }
}

/// The static name `StateChanged` carries in its `kind` argument, as
/// `bus.rs:361-366` emits it.
///
/// Upstream is `atspi_common::State::to_static_str`, which `docs/41` section
/// 1.10 row U3 records as unverifiable on this host: the crate is a crates.io
/// dependency and there is no registry cache here. The names below are the
/// libatspi spellings, which is what a screen reader matches against, and the
/// comptime test below checks that every member has one rather than restating
/// the table.
///
/// **UNVERIFIED.** See the module doc.
pub fn stateName(value: State) [:0]const u8 {
    return switch (value) {
        .active => "active",
        .armed => "armed",
        .busy => "busy",
        .checked => "checked",
        .collapsed => "collapsed",
        .defocused => "defocused",
        .editable => "editable",
        .enabled => "enabled",
        .expandable => "expandable",
        .focusable => "focusable",
        .focused => "focused",
        .has_tooltip => "has-tooltip",
        .horizontal => "horizontal",
        .iconified => "iconified",
        .insensitive => "insensitive",
        .indeterminate => "indeterminate",
        .modal => "modal",
        .multi_line => "multiline",
        .multi_selectable => "multiselectable",
        .@"opaque" => "opaque",
        .pressed => "pressed",
        .resizable => "resizable",
        .selectable => "selectable",
        .sensitive => "sensitive",
        .showing => "showing",
        .single_line => "single-line",
        .stale => "stale",
        .transient => "transient",
        .vertical => "vertical",
        .visible => "visible",
        .manages_descendants => "manages-descendants",
        .indeterminate_tristate => "indeterminate-tristate",
        .required => "required",
        .selectable_text => "selectable-text",
        .visited => "visited",
        .read_only => "read-only",
        .show_expander => "show-expander",
        .atomic => "atomic",
        .defunct => "defunct",
        .expanded => "expanded",
        .marquee => "marquee",
        .checkable => "checkable",
        .selected => "selected",
    };
}

/// The set of states one node reports, packed one bit per `State`.
///
/// Upstream `atspi_common::StateSet`. `node.rs:301-389` inserts into it,
/// `node.rs:609` takes the symmetric difference of two of them, and
/// `Accessible.GetState` marshals it as an array of unsigned 32-bit words.
///
/// **UNVERIFIED.** These are protocol constants; see the module doc.
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
    return std.enums.fromInt(Layer, value);
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

test "every Interface name is distinct, because the tag is the bit position" {
    var names: [interface_count][:0]const u8 = undefined;
    inline for (comptime std.enums.values(Interface)) |value| {
        const name = interfaceName(value);
        for (names[0..@intFromEnum(value)]) |seen| {
            try testing.expect(!std.mem.eql(u8, seen, name));
        }
        names[@intFromEnum(value)] = name;
    }
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

test "an empty interface set marshals as an empty array" {
    // `GetInterfaces` answers `as`, and `Accessible.GetInterfaces` on a node with
    // no optional interface still has `Accessible` in its set, so this asserts
    // the zero value rather than a member.
    const set = InterfaceSet.empty;
    try testing.expectEqual(@as(u32, 0), set.bits);
}

test "every State member has a static name for the StateChanged kind field" {
    // The sweep is the point: a member added without a name is a compile error,
    // which is what `AGENTS.md` section 3 asks for over an enumerable domain.
    inline for (comptime std.enums.values(State)) |value| {
        const name = stateName(value);
        try testing.expect(name.len > 0);
    }
}

test "the state names libatspi spells with hyphens are spelled with hyphens" {
    // A screen reader matches these strings, so the three names with a hyphen are
    // the ones a transcription gets wrong.
    try testing.expectEqualStrings("read-only", stateName(.read_only));
    try testing.expectEqualStrings("single-line", stateName(.single_line));
    try testing.expectEqualStrings("has-tooltip", stateName(.has_tooltip));
    try testing.expectEqualStrings("multiselectable", stateName(.multi_selectable));
    try testing.expectEqualStrings("selectable-text", stateName(.selectable_text));
}

test "no two State members share a bit position" {
    // Each value is a bit index, so a duplicate would make one state hide
    // another. The comptime block above checks the width; this checks the table.
    var seen: u64 = 0;
    inline for (comptime std.enums.values(State)) |value| {
        const bit = @as(u64, 1) << @as(u6, @intFromEnum(value));
        try testing.expectEqual(@as(u64, 0), seen & bit);
        seen |= bit;
    }
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
    // Tag order, which is the reference numbering and not the order the two sets
    // were built in. `enabled` is 8 and `focused` is 11, so `enabled` comes
    // first. The test used to assert the insertion order, which a set does not
    // have and which `difference` never promised.
    try testing.expectEqual(State.enabled, delta[0]);
    try testing.expectEqual(State.focused, delta[1]);
}

test "the defunct set is the one-member set node.rs:1006 returns" {
    try testing.expect(StateSet.defunct.contains(.defunct));
    try testing.expect(!StateSet.defunct.contains(.visible));
    try testing.expectEqual(@as(u64, 0), StateSet.empty.bits);
}

test "a peer value outside the declared domain decodes to null rather than a guess" {
    try testing.expect(roleFromInt(9999) == null);
    try testing.expect(roleFromInt(0) == .invalid);
    try testing.expect(granularityFromInt(2) == .sentence);
    try testing.expect(scrollTypeFromInt(7) == null);
    try testing.expect(coordTypeFromInt(3) == null);
    try testing.expect(layerFromInt(1) == .widget);
}

test "the Politeness domain is the three values an announcement can carry" {
    try testing.expectEqual(@as(i32, 0), @intFromEnum(Politeness.none));
    try testing.expectEqual(@as(i32, 1), @intFromEnum(Politeness.polite));
    try testing.expectEqual(@as(i32, 2), @intFromEnum(Politeness.assertive));
}
