//! The 54 selectors a platform node answers, and the decisions behind them.
//!
//! **What this module is.** The type table for `AK/macos/src/node.rs:411-1330`
//! and the three pure decision functions that table feeds: which value
//! `accessibilityAttributeValue:` answers, what the four selectors that cannot
//! answer `nil` answer when the node is gone, and what
//! `isAccessibilitySelectorAllowed:` answers for a selector.
//!
//! **Why the table matters even though no message is sent here.** A wrong
//! `NSAccessibility*` constant name does not link and a wrong function signature
//! does not type-check, so those mistakes are loud. A selector name passed to
//! `builder.add_method` is not: `sel!` accepts any name, so a misspelt selector
//! is one the Objective-C runtime never installs and the host view silently
//! keeps its original behaviour. Same for the 4 selectors installed on the host
//! view at `AK/macos/src/subclass.rs:179`, `:183`, `:187` and `:191`. Those four
//! and the 43 literals in `literals.zig` are the whole of the adapter's silent
//! failure surface, and both are assertable on a host with no Mac.
//!
//! **24 of the 54 can answer `nil`, and 30 have a total answer.** The 24 are the
//! ones whose absent case is a distinct behaviour, and each selector below says
//! what its `nil` means. The 30 all answer whether or not the node resolves, and
//! four of those answer a sentinel rather than `nil` — `NSRect::ZERO`, an unknown
//! orientation, `0` and `NSRange{0, 0}`. Asserting those sentinels is what
//! distinguishes "unresolved" from "resolved to nothing": a port that answers
//! `nil` from these four is a change a client sees as a crash rather than as an
//! empty element.
//!
//! **What is compiled-and-tested here and what needs a Mac.** The table, the
//! group decomposition, the attribute dispatch, the sentinels, the action-name
//! round trip and the value-shape decision are all pure functions over a
//! `consumer.NodeRef`, so a synthetic tree drives every one of them on a Linux
//! host. **What needs a Mac** is that the strings are the ones AppKit accepts
//! and that the framework reads the answer: no macOS SDK is installed here, and
//! `zig build-exe -target aarch64-macos` fails at `-lobjc` with `unable to find
//! dynamic system library 'objc'`, recorded as `docs/16:1780` and as row H5 of
//! `docs/50-verification.md`. A green run here is evidence about the port's
//! tables and is not evidence that the adapter builds or works.
//!
//! **The loop bound.** Every walk in this module is over `selectors`, whose
//! length is `selector_count` and is a comptime constant, or over one answer
//! group's `selectors` slice, whose length that group carries. The two nested
//! walks in the distinctness and coverage tests are over `selectors` and are
//! therefore bounded by `selector_count` squared, which is a comptime fact.

const std = @import("std");

const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const literals = @import("literals.zig");
const util = @import("util.zig");

const NodeRef = consumer.node_id.NodeRef;
const QueryError = consumer.tree_state.QueryError;
const FilterFn = consumer.filter.FilterFn;
const FilterResult = consumer.filter.FilterResult;
const testing = std.testing;

/// The `NSAccessibilityOrientation` value a node answers when it is gone.
///
/// Upstream `AK/macos/src/node.rs:635`. `schema.Orientation` has only
/// `horizontal` and `vertical`, so "unknown" is not a tag of it and is held here
/// as the AppKit number. **Unverified**: no macOS SDK is installed on this host,
/// so `NSAccessibilityConstants.h` was not read.
pub const orientation_unknown: i32 = 0;

/// The `NSRect` a node answers when it is gone, upstream `:478`.
///
/// An `NSRect` is four `double`s at offsets 0, 8, 16 and 24, so this is four
/// zeroed doubles and nothing else.
pub const frame_zero: [4]f64 = .{ 0, 0, 0, 0 };

/// The `NSNumberOfCharacters` a node answers when it is gone, upstream `:756`.
pub const number_of_characters_zero: i64 = 0;

/// The `NSRange` a node answers for its selected text when it is gone, upstream
/// `:782`.
///
/// It is the `NsRange` of `util.zig:66` at the start of the document, so the
/// sentinel and the type the conversions answer cannot drift apart.
pub const selected_text_range_zero: util.NsRange = .{ .location = 0, .length = 0 };

/// What one of the 54 selectors returns.
///
/// The sixteen shapes are the sixteen distinct return types upstream writes over
/// `AK/macos/src/node.rs:411-1330`, with `Option<…>` and the bare type kept
/// apart. `nil_capable` is the property the table turns on: a shape carries a
/// `null` case exactly when upstream wrote `Option<…>`.
pub const ReturnShape = enum(u8) {
    /// `Option<Id<AnyObject>>`: a parent, a window or a top-level element.
    any_object,
    /// `Option<Id<NSArray<PlatformNode>>>`: a set of child nodes.
    node_array,
    /// `Option<Id<NSString>>`: a text attribute.
    string,
    /// `Option<Id<NSNumber>>`: a numeric bound.
    number,
    /// `Option<Id<NSURL>>`: the node's link target.
    url,
    /// `Option<Id<NSObject>>`: a value whose concrete class depends on the node.
    object,
    /// `Option<Id<NSAttributedString>>`: a styled text run.
    attributed_string,
    /// `Option<Id<NSAccessibilitySubrole>>`: the subrole.
    subrole,
    /// `bool`: a flag or the result of an action.
    bool_,
    /// `NSRange`: a range over the document.
    range,
    /// `NSInteger`: a count, a line number or a character index.
    integer,
    /// `NSRect`: a frame.
    rect,
    /// `void`: a selector that takes a value and sends back nothing.
    void_,
    /// `Id<NSAccessibilityRole>`: the role, which is never absent.
    role,
    /// `Id<NSArray<NSString>>`: the action names, which is never absent.
    string_array,
    /// `NSAccessibilityOrientation`: the orientation, which is never absent.
    orientation,
};

/// Whether a shape of this kind can answer `nil`.
///
/// It is a function of the shape alone because upstream writes `Option<…>`
/// exactly for the eight optional shapes, so the table does not need a second
/// flag that could disagree with the first.
pub fn isNilCapable(shape: ReturnShape) bool {
    return switch (shape) {
        .any_object,
        .node_array,
        .string,
        .number,
        .url,
        .object,
        .attributed_string,
        .subrole,
        => true,
        .bool_, .range, .integer, .rect, .void_, .role, .string_array, .orientation => false,
    };
}

/// The upstream Rust return type a shape is written as, for the record.
///
/// It is a table rather than a comment because a shape renamed without its
/// spelling changing would otherwise be invisible, and because it is the text a
/// reader checks the port against.
pub fn returnShapeRustType(shape: ReturnShape) [:0]const u8 {
    return switch (shape) {
        .any_object => "Option<Id<AnyObject>>",
        .node_array => "Option<Id<NSArray<PlatformNode>>>",
        .string => "Option<Id<NSString>>",
        .number => "Option<Id<NSNumber>>",
        .url => "Option<Id<NSURL>>",
        .object => "Option<Id<NSObject>>",
        .attributed_string => "Option<Id<NSAttributedString>>",
        .subrole => "Option<Id<NSAccessibilitySubrole>>",
        .bool_ => "bool",
        .range => "NSRange",
        .integer => "NSInteger",
        .rect => "NSRect",
        .void_ => "void",
        .role => "Id<NSAccessibilityRole>",
        .string_array => "Id<NSArray<NSString>>",
        .orientation => "NSAccessibilityOrientation",
    };
}

/// One selector a platform node answers.
pub const Selector = struct {
    /// The selector name, spelled as upstream spells it. A selector with a
    /// colon takes one argument, which is why the name keeps the colon.
    name: [:0]const u8,
    /// What the selector returns.
    returns: ReturnShape,
    /// The `AK/macos/src/node.rs` line of the `#[method]` attribute.
    upstream_line: u16,
};

/// How many selectors `selectors` holds.
pub const selector_count = 54;

/// The 54 selectors `PlatformNode` implements, in upstream's declaration order.
///
/// The 16 shapes hold 3, 7, 8, 2, 1, 1, 1, 1, 12, 5, 3, 2, 5, 1, 1 and 1
/// members, and 8 of the 16 can answer `nil` for 24 selectors in all.
pub const selectors = [selector_count]Selector{
    .{ .name = "accessibilityParent", .returns = .any_object, .upstream_line = 412 },
    .{ .name = "accessibilityWindow", .returns = .any_object, .upstream_line = 427 },
    .{ .name = "accessibilityTopLevelUIElement", .returns = .any_object, .upstream_line = 438 },
    .{ .name = "accessibilityChildren", .returns = .node_array, .upstream_line = 449 },
    .{
        .name = "accessibilityChildrenInNavigationOrder",
        .returns = .node_array,
        .upstream_line = 454,
    },
    .{ .name = "accessibilitySelectedChildren", .returns = .node_array, .upstream_line = 460 },
    .{ .name = "accessibilityFrame", .returns = .rect, .upstream_line = 477 },
    .{ .name = "accessibilityRole", .returns = .role, .upstream_line = 501 },
    .{ .name = "accessibilitySubrole", .returns = .subrole, .upstream_line = 508 },
    .{ .name = "accessibilityRoleDescription", .returns = .string, .upstream_line = 514 },
    .{ .name = "accessibilityIdentifier", .returns = .string, .upstream_line = 526 },
    .{ .name = "accessibilityTitle", .returns = .string, .upstream_line = 534 },
    .{ .name = "accessibilityHelp", .returns = .string, .upstream_line = 543 },
    .{ .name = "accessibilityPlaceholderValue", .returns = .string, .upstream_line = 552 },
    .{ .name = "accessibilityValue", .returns = .object, .upstream_line = 561 },
    .{ .name = "setAccessibilityValue:", .returns = .void_, .upstream_line = 580 },
    .{ .name = "accessibilityMinValue", .returns = .number, .upstream_line = 607 },
    .{ .name = "accessibilityMaxValue", .returns = .number, .upstream_line = 615 },
    .{ .name = "accessibilityURL", .returns = .url, .upstream_line = 623 },
    .{ .name = "accessibilityOrientation", .returns = .orientation, .upstream_line = 634 },
    .{ .name = "isAccessibilityElement", .returns = .bool_, .upstream_line = 646 },
    .{ .name = "isAccessibilityFocused", .returns = .bool_, .upstream_line = 652 },
    .{ .name = "isAccessibilityEnabled", .returns = .bool_, .upstream_line = 658 },
    .{ .name = "setAccessibilityFocused:", .returns = .void_, .upstream_line = 663 },
    .{ .name = "accessibilityPerformPress", .returns = .bool_, .upstream_line = 693 },
    .{ .name = "accessibilityPerformIncrement", .returns = .bool_, .upstream_line = 712 },
    .{ .name = "accessibilityPerformDecrement", .returns = .bool_, .upstream_line = 731 },
    .{ .name = "accessibilityNotifiesWhenDestroyed", .returns = .bool_, .upstream_line = 750 },
    .{ .name = "accessibilityNumberOfCharacters", .returns = .integer, .upstream_line = 755 },
    .{ .name = "accessibilitySelectedText", .returns = .string, .upstream_line = 767 },
    .{ .name = "accessibilitySelectedTextRange", .returns = .range, .upstream_line = 781 },
    .{ .name = "accessibilityInsertionPointLineNumber", .returns = .integer, .upstream_line = 794 },
    .{ .name = "accessibilityRangeForLine:", .returns = .range, .upstream_line = 807 },
    .{ .name = "accessibilityRangeForPosition:", .returns = .range, .upstream_line = 820 },
    .{ .name = "accessibilityStringForRange:", .returns = .string, .upstream_line = 840 },
    .{
        .name = "accessibilityAttributedStringForRange:",
        .returns = .attributed_string,
        .upstream_line = 854,
    },
    .{ .name = "accessibilityFrameForRange:", .returns = .rect, .upstream_line = 960 },
    .{ .name = "accessibilityLineForIndex:", .returns = .integer, .upstream_line = 985 },
    .{ .name = "accessibilityRangeForIndex:", .returns = .range, .upstream_line = 998 },
    .{ .name = "accessibilityStyleRangeForIndex:", .returns = .range, .upstream_line = 1011 },
    .{ .name = "setAccessibilitySelectedTextRange:", .returns = .void_, .upstream_line = 1031 },
    .{ .name = "isAccessibilityRequired", .returns = .bool_, .upstream_line = 1049 },
    .{ .name = "isAccessibilitySelected", .returns = .bool_, .upstream_line = 1055 },
    .{ .name = "setAccessibilitySelected:", .returns = .void_, .upstream_line = 1066 },
    .{ .name = "accessibilityAttributeValue:", .returns = .string, .upstream_line = 1090 },
    .{ .name = "accessibilityRows", .returns = .node_array, .upstream_line = 1106 },
    .{ .name = "accessibilitySelectedRows", .returns = .node_array, .upstream_line = 1122 },
    .{ .name = "accessibilityPerformPick", .returns = .bool_, .upstream_line = 1139 },
    .{ .name = "accessibilityLinkedUIElements", .returns = .node_array, .upstream_line = 1161 },
    .{ .name = "accessibilityTabs", .returns = .node_array, .upstream_line = 1178 },
    .{ .name = "isAccessibilityModal", .returns = .bool_, .upstream_line = 1194 },
    .{ .name = "accessibilityActionNames", .returns = .string_array, .upstream_line = 1207 },
    .{ .name = "accessibilityPerformAction:", .returns = .void_, .upstream_line = 1218 },
    .{ .name = "isAccessibilitySelectorAllowed:", .returns = .bool_, .upstream_line = 1234 },
};

/// How many of the 54 selectors can answer `nil`.
///
/// `docs/42` section 1.2 and `docs/51c-macos-test-plan.md` section 3.1 both give
/// 24. It is derived from `isNilCapable` rather than written out, so the two
/// numbers cannot drift apart.
pub const nil_capable_selector_count = 24;

/// How many of the 54 selectors have a total answer whatever the node does.
pub const total_selector_count = 30;

/// One of the 4 selectors installed on the host view by the subclassing
/// adapter, upstream `AK/macos/src/subclass.rs:179`, `:183`, `:187` and `:191`.
///
/// These four go to `builder.add_method`, so a misspelling is a selector the
/// Objective-C runtime never installs and the view silently keeps its original
/// behaviour. The test below pins the four spellings.
pub const host_view_selector_count = 4;

/// The 4 selectors the subclassing adapter installs on the host view, in
/// upstream's install order.
pub const host_view_selectors = [host_view_selector_count][:0]const u8{
    "superclass",
    "accessibilityChildren",
    "accessibilityFocusedUIElement",
    "accessibilityHitTest:",
};

/// The selector `add_focus_forwarder_to_window_class` installs, upstream
/// `AK/macos/src/patch.rs:39` through `:71`.
///
/// It is a fifth `add_method` site, on an `NSWindow` subclass rather than on the
/// host view, so it is held apart from `host_view_selectors`.
pub const focus_forwarder_selector: [:0]const u8 = "accessibilityFocusedUIElement";

/// How many of the 54 selectors are the one text-range arm of
/// `isAccessibilitySelectorAllowed:`.
pub const text_range_selector_count = 13;

/// The 13 selectors that share the `supports_text_ranges` answer, upstream
/// `AK/macos/src/node.rs:1249-1261`.
///
/// **These must stay one arm.** A port that splits them into 13 arms behaves
/// identically and is a large diff for nothing; a port that drops one behaves
/// differently and is the defect the count catches.
pub const text_range_selectors = [text_range_selector_count][:0]const u8{
    "accessibilityNumberOfCharacters",
    "accessibilitySelectedText",
    "accessibilitySelectedTextRange",
    "accessibilityInsertionPointLineNumber",
    "accessibilityRangeForLine:",
    "accessibilityRangeForPosition:",
    "accessibilityStringForRange:",
    "accessibilityAttributedStringForRange:",
    "accessibilityFrameForRange:",
    "accessibilityLineForIndex:",
    "accessibilityRangeForIndex:",
    "accessibilityStyleRangeForIndex:",
    "setAccessibilitySelectedTextRange:",
};

/// The answer `isAccessibilitySelectorAllowed:` gives for a selector.
///
/// The 14 tags are the 14 answers upstream reaches between `:1238` and `:1320`.
/// `always` is the tail arm of 27 selectors that the method does not test, and
/// `unlisted` is the fall-through: `resolve` fails and the method returns false.
pub const Answer = enum(u8) {
    /// `is_focusable(&filter)`, at `:1239`.
    is_focusable,
    /// `is_clickable(&filter)`, at `:1242`.
    is_clickable,
    /// `supports_increment(&filter)`, at `:1245`.
    supports_increment,
    /// `supports_decrement(&filter)`, at `:1248`.
    supports_decrement,
    /// `supports_text_ranges()`, at `:1262`.
    supports_text_ranges,
    /// text ranges and not read-only, or `supports_action(SetValue)`, at
    /// `:1265-1266`.
    set_value,
    /// `is_item_like()`, at `:1269`.
    is_item_like,
    /// `is_container_with_selectable_children()`, at `:1273`.
    is_container_with_selectable_children,
    /// clickable, item-like and selectable, at `:1277-1281`.
    selectable_item,
    /// `role() == Role::TabList`, at `:1284`.
    is_tab_list,
    /// `is_dialog()`, at `:1287`.
    is_dialog,
    /// any of the three braille or HTML attributes, at `:1290-1293`.
    has_any_attribute,
    /// `supports_url()`, at `:1296`.
    supports_url,
    /// `true`, the tail arm at `:1299-1320`.
    always,
    /// `false`, the `resolve` fall-through.
    unlisted,
};

/// The Rust expression one answer is written as, for the record.
pub fn answerExpression(answer: Answer) [:0]const u8 {
    return switch (answer) {
        .is_focusable => "node.is_focusable(&filter)",
        .is_clickable => "node.is_clickable(&filter)",
        .supports_increment => "node.supports_increment(&filter)",
        .supports_decrement => "node.supports_decrement(&filter)",
        .supports_text_ranges => "node.supports_text_ranges()",
        .set_value => "supports_text_ranges() && !is_read_only() || supports_action(SetValue)",
        .is_item_like => "NodeWrapper(node).is_item_like()",
        .is_container_with_selectable_children => "is_container_with_selectable_children()",
        .selectable_item => "is_clickable() && is_item_like() && is_selectable()",
        .is_tab_list => "node.role() == Role::TabList",
        .is_dialog => "node.is_dialog()",
        .has_any_attribute => "has_braille_label() || " ++
            "has_braille_role_description() || has_html_id()",
        .supports_url => "node.supports_url()",
        .always => "true",
        .unlisted => "false",
    };
}

/// One answer and the selectors that get it.
pub const AnswerGroup = struct {
    /// What the method answers for every selector in `selectors`.
    answer: Answer,
    /// The selectors, spelled as upstream spells them.
    selectors: []const [:0]const u8,
};

/// How many answer groups `answer_groups` holds.
pub const answer_group_count = 14;

/// Every selector of the 54, with the answer `isAccessibilitySelectorAllowed:`
/// gives it.
///
/// The groups cover all 54 selectors between them, which is the property the
/// test "the 14 groups cover all 54 selectors exactly once" checks. `always`
/// holds 27, `supports_text_ranges` holds the 13 that must stay one arm, and
/// every other group holds one or two.
pub const answer_groups = [answer_group_count]AnswerGroup{
    .{ .answer = .is_focusable, .selectors = &.{"setAccessibilityFocused:"} },
    .{ .answer = .is_clickable, .selectors = &.{"accessibilityPerformPress"} },
    .{ .answer = .supports_increment, .selectors = &.{"accessibilityPerformIncrement"} },
    .{ .answer = .supports_decrement, .selectors = &.{"accessibilityPerformDecrement"} },
    .{ .answer = .supports_text_ranges, .selectors = &text_range_selectors },
    .{ .answer = .set_value, .selectors = &.{"setAccessibilityValue:"} },
    .{ .answer = .is_item_like, .selectors = &.{"isAccessibilitySelected"} },
    .{
        .answer = .is_container_with_selectable_children,
        .selectors = &.{ "accessibilityRows", "accessibilitySelectedRows" },
    },
    .{
        .answer = .selectable_item,
        .selectors = &.{ "setAccessibilitySelected:", "accessibilityPerformPick" },
    },
    .{ .answer = .is_tab_list, .selectors = &.{"accessibilityTabs"} },
    .{ .answer = .is_dialog, .selectors = &.{"isAccessibilityModal"} },
    .{ .answer = .has_any_attribute, .selectors = &.{"accessibilityAttributeValue:"} },
    .{ .answer = .supports_url, .selectors = &.{"accessibilityURL"} },
    .{
        .answer = .always,
        .selectors = &.{
            "accessibilityParent",
            "accessibilityChildren",
            "accessibilityChildrenInNavigationOrder",
            "accessibilitySelectedChildren",
            "accessibilityFrame",
            "accessibilityRole",
            "accessibilitySubrole",
            "isAccessibilityEnabled",
            "accessibilityWindow",
            "accessibilityTopLevelUIElement",
            "accessibilityLinkedUIElements",
            "accessibilityRoleDescription",
            "accessibilityIdentifier",
            "accessibilityTitle",
            "accessibilityHelp",
            "accessibilityPlaceholderValue",
            "accessibilityValue",
            "accessibilityMinValue",
            "accessibilityMaxValue",
            "isAccessibilityRequired",
            "accessibilityOrientation",
            "isAccessibilityElement",
            "isAccessibilityFocused",
            "accessibilityNotifiesWhenDestroyed",
            "isAccessibilitySelectorAllowed:",
            "accessibilityActionNames",
            "accessibilityPerformAction:",
        },
    },
};

/// The 3 attributes `accessibilityAttributeValue:` recognises, upstream
/// `AK/macos/src/node.rs:1090-1104`.
///
/// Each one names the node method that supplies the value and the `has_…`
/// predicate that must also hold. **The `has_…` conjunct is the subtle part**:
/// a node with no braille label answers `nil` for `AXBrailleLabel` rather than
/// an empty `NSString`, and a port that drops the conjunct answers the empty
/// string, which a client reads as a blank label.
pub const attributes = [literals.attribute_name_count]Attribute{
    .{ .name = "AXBrailleLabel", .property = .braille_label, .has_property = .has_braille_label },
    .{
        .name = "AXBrailleRoleDescription",
        .property = .braille_role_description,
        .has_property = .has_braille_role_description,
    },
    .{ .name = "AXDOMIdentifier", .property = .html_id, .has_property = .has_html_id },
};

/// One attribute name and the node property that answers it.
pub const Attribute = struct {
    /// The attribute name, from `literals.literals`.
    name: [:0]const u8,
    /// Which node property supplies the value.
    property: Property,
    /// Which node predicate must also hold.
    has_property: Property,
};

/// The node properties the three attributes read.
pub const Property = enum(u8) {
    /// `Node.braille_label()`.
    braille_label,
    /// `Node.has_braille_label()`.
    has_braille_label,
    /// `Node.braille_role_description()`.
    braille_role_description,
    /// `Node.has_braille_role_description()`.
    has_braille_role_description,
    /// `Node.html_id()`.
    html_id,
    /// `Node.has_html_id()`.
    has_html_id,
};

/// The concrete class `accessibilityValue` answers for each value shape,
/// upstream `AK/macos/src/node.rs:561-579`.
///
/// The three shapes are indistinguishable to a client that only asks "is this a
/// string", and getting `bool` and `number` both right as `NSNumber` matters
/// because `setAccessibilityValue:` downcasts in the other direction with two
/// `downcast_ref` calls whose order decides the result for an `NSNumber`.
pub const ValueShape = enum(u8) {
    /// A `Toggled` value. `NSNumber` holding a boolean.
    boolean,
    /// A numeric value. `NSNumber` holding a number.
    number,
    /// A string value. `NSString`.
    string,
};

/// The class name `accessibilityValue` answers for `shape`.
pub fn valueClassName(shape: ValueShape) [:0]const u8 {
    return switch (shape) {
        .boolean, .number => "NSNumber",
        .string => "NSString",
    };
}

/// The value `accessibilityAttributeValue:` answers for `attribute` on `node`.
///
/// **Returns.** The attribute's text, or `null` when the attribute is unknown
/// **or** when it is known and the node has no value for it. The two cases are
/// the same answer upstream gives, and both are `null` rather than an empty
/// string.
pub fn attributeValue(attribute: []const u8, node: NodeRef) ?[]const u8 {
    for (attributes) |entry| {
        if (!std.mem.eql(u8, entry.name, attribute)) continue;
        // The `has_…` conjunct is what makes an absent value `null` rather than
        // an empty string.
        if (!hasProperty(node, entry.has_property)) return null;
        return readProperty(node, entry.property);
    }
    return null;
}

/// Whether `node` carries the property `property`.
///
/// It is the read side of the `has_…` conjunct. The walk is bounded by
/// `Property.count`, which is 6.
fn hasProperty(node: NodeRef, property: Property) bool {
    const properties = consumer.node_ref.properties;
    const set_state = consumer.node_ref.set_state;
    return switch (property) {
        .has_braille_label => properties.hasBrailleLabel(node),
        .has_braille_role_description => properties.hasBrailleRoleDescription(node),
        .has_html_id => set_state.hasHtmlId(node),
        .braille_label, .braille_role_description, .html_id => false,
    };
}

/// The text `node` holds for `property`, or `null`.
///
/// The walk is bounded by `Property.count`, which is 6. A property that is not a
/// value property answers `null` rather than reaching into the node.
fn readProperty(node: NodeRef, property: Property) ?[]const u8 {
    const properties = consumer.node_ref.properties;
    const set_state = consumer.node_ref.set_state;
    return switch (property) {
        .braille_label => properties.brailleLabel(node),
        .braille_role_description => properties.brailleRoleDescription(node),
        .html_id => set_state.htmlId(node),
        .has_braille_label, .has_braille_role_description, .has_html_id => null,
    };
}

/// The answer `isAccessibilitySelectorAllowed:` gives for `name` on `node`.
///
/// **Returns.** `true` or `false`. A selector the 54 do not name answers
/// `false`, which is the `resolve` fall-through upstream and is why a client
/// asking about a selector the adapter does not implement gets "no" rather than
/// a crash.
///
/// `name` may carry a null terminator; the comparison ignores it.
///
/// **Errors.** `error.QueryFailed` from any of the predicates below. The
/// consumer layer reports one tag for all of them and this module does not
/// discriminate, so the caller sees a failure and the tree is unchanged.
pub fn selectorAllowed(name: []const u8, node: NodeRef) QueryError!bool {
    const answer = answerFor(name) orelse return false;
    const predicates = consumer.node_ref.predicates;
    const containers = consumer.node_ref.containers;
    const properties = consumer.node_ref.properties;
    const strings = consumer.node_ref.strings;
    const text_query = consumer.text.query;
    const set_state = consumer.node_ref.set_state;

    return switch (answer) {
        .is_focusable => try predicates.isFocusable(node, parent_filter),
        .is_clickable => try predicates.isClickable(node, parent_filter),
        .supports_increment => try predicates.supportsIncrement(node, parent_filter),
        .supports_decrement => try predicates.supportsDecrement(node, parent_filter),
        .supports_text_ranges => try text_query.supportsTextRanges(node),
        .set_value => {
            const editable = try text_query.supportsTextRanges(node);
            if (editable and !predicates.isReadOnly(node)) return true;
            return predicates.supportsAction(node, .set_value, parent_filter);
        },
        .is_item_like => containers.isItemLike(node),
        .is_container_with_selectable_children => {
            return containers.isContainerWithSelectableChildren(node);
        },
        .selectable_item => {
            if (!try predicates.isClickable(node, parent_filter)) return false;
            if (!containers.isItemLike(node)) return false;
            return predicates.isSelectable(node);
        },
        .is_tab_list => properties.role(node) == .tab_list,
        .is_dialog => predicates.isDialog(node),
        .has_any_attribute => properties.hasBrailleLabel(node) or
            properties.hasBrailleRoleDescription(node) or
            set_state.hasHtmlId(node),
        .supports_url => strings.supportsUrl(node),
        .always => true,
        .unlisted => false,
    };
}

/// The answer the 54 selectors give `selector`, or `null` when `name` is not
/// one of them.
///
/// The walk is over `answer_groups`, whose length is `answer_group_count` and
/// then over that group's `selectors` slice, whose length the group carries.
/// `unlisted` is never returned for a name the table holds, because the tail
/// group covers every remaining selector of the 54.
pub fn answerFor(name: []const u8) ?Answer {
    for (answer_groups) |group| {
        for (group.selectors) |selector| {
            if (std.mem.eql(u8, selector, name)) return group.answer;
        }
    }
    return null;
}

/// The filter the predicates read, upstream `AK/macos/src/filters.rs:54-92`.
///
/// It is a value and not a global, so a test that builds a tree and applies the
/// adapter's own filter gets the same answers the adapter gets.
const parent_filter: FilterFn = .{ .context = null, .filter = commonFilterThunk };

/// Adapts `consumer.filter.commonFilter` to the `FilterFn` shape.
///
/// `context` is `null` for this filter because `commonFilter` reads only the
/// node. The walk it performs is bounded by `commonFilterStepBound` of the node
/// count, which the consumer layer derives.
fn commonFilterThunk(context: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    _ = context;
    return consumer.filter.commonFilter(node);
}

/// The action names `accessibilityActionNames` publishes, upstream
/// `AK/macos/src/node.rs:1207-1217`.
///
/// **It is empty, not `null`, when the node supports nothing.** The array is
/// constructed outside the `resolve` closure, so the unresolved path still
/// yields an empty array. That is the one selector among the 54 that returns a
/// non-optional empty value, and a port that returns `nil` here crashes a client
/// that indexes the array.
pub const no_action_names: [0][:0]const u8 = .{};

/// The one action name the adapter publishes.
pub const action_names_one = [1][:0]const u8{"AXScrollToVisible"};

/// The action names for a node that does, or does not, support
/// `scroll_into_view`.
///
/// **Returns.** A borrowed array, so the caller holds no memory and there is
/// nothing to release.
pub fn actionNames(supports_scroll_into_view: bool) []const [:0]const u8 {
    if (!supports_scroll_into_view) return &no_action_names;
    return &action_names_one;
}

/// The action `accessibilityPerformAction:` dispatches for `name`.
///
/// **Returns.** The action, or `null` when `name` is not the one name the
/// adapter published. Upstream compares against `SCROLL_TO_VISIBLE_ACTION` at
/// `:1221` and does nothing for any other string, so `null` here is what makes
/// the round trip total: every name `actionNames` publishes is dispatched and
/// every other name does nothing.
pub fn actionForName(name: []const u8) ?schema.Action {
    const published = action_names_one[0];
    if (!std.mem.eql(u8, published, name)) return null;
    return .scroll_into_view;
}

comptime {
    // `docs/42` section 1.2 gives the 54 and `docs/51c-macos-test-plan.md`
    // section 3.1 gives the 24. Both are checked here so a table that loses a
    // selector is a compile error naming the count.
    //
    // The quota is raised because the coverage walk below is
    // `answer_group_count` groups times 54 selector lookups, each of which is a
    // 54-step walk of its own. The bound is a comptime fact, so this does not
    // slow a run.
    @setEvalBranchQuota(200_000);
    if (selectors.len != selector_count) @compileError("the selector table lost a member");

    var nil_capable: usize = 0;
    for (selectors) |selector| {
        if (isNilCapable(selector.returns)) nil_capable += 1;
    }
    if (nil_capable != nil_capable_selector_count) {
        @compileError(std.fmt.comptimePrint(
            "{d} selectors can answer nil, the map gives {d}",
            .{ nil_capable, nil_capable_selector_count },
        ));
    }

    var covered: usize = 0;
    for (answer_groups) |group| {
        for (group.selectors) |name| {
            if (findSelector(name) == null) {
                @compileError(std.fmt.comptimePrint(
                    "group .{s} names {s}, which is not one of the 54",
                    .{ @tagName(group.answer), name },
                ));
            }
            covered += 1;
        }
    }
    if (covered != selector_count) {
        @compileError(std.fmt.comptimePrint(
            "the {d} groups cover {d} selectors, the table holds {d}",
            .{ answer_group_count, covered, selector_count },
        ));
    }
    if (host_view_selectors.len != host_view_selector_count) {
        @compileError("the host view selector table lost a member");
    }
    if (text_range_selectors.len != text_range_selector_count) {
        @compileError("the text range table lost a member");
    }
}

/// The selector spelled `name`, or `null` when the table holds no such selector.
///
/// `name` may carry a null terminator; the comparison ignores it. The walk is
/// bounded by `selectors.len`, which is `selector_count`.
pub fn findSelector(name: []const u8) ?Selector {
    for (selectors) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) return candidate;
    }
    return null;
}

/// How many selectors the table holds for `shape`.
pub fn countOfShape(shape: ReturnShape) usize {
    var total: usize = 0;
    for (selectors) |candidate| {
        if (candidate.returns == shape) total += 1;
    }
    return total;
}

test "the node implements 54 selectors, 24 of which can answer nil" {
    // Both counts against `docs/42`. A port that adds a selector and forgets to
    // add its row fails, and a port that drops one fails.
    try testing.expectEqual(@as(usize, 54), selectors.len);
    var nil_capable: usize = 0;
    for (selectors) |selector| {
        if (isNilCapable(selector.returns)) nil_capable += 1;
    }
    try testing.expectEqual(nil_capable_selector_count, nil_capable);
    try testing.expectEqual(@as(usize, 30), selectors.len - nil_capable);
    try testing.expectEqual(total_selector_count, selectors.len - nil_capable);
}

test "the 16 return shapes hold the counts upstream's tally gives" {
    // The table of shapes in `docs/51c-macos-test-plan.md` section 3.1, checked
    // one shape at a time so a reordering that keeps the total fails.
    const expected = [_]struct { ReturnShape, usize }{
        .{ .any_object, 3 },
        .{ .node_array, 7 },
        .{ .string, 8 },
        .{ .number, 2 },
        .{ .url, 1 },
        .{ .object, 1 },
        .{ .attributed_string, 1 },
        .{ .subrole, 1 },
        .{ .bool_, 12 },
        .{ .range, 5 },
        .{ .integer, 3 },
        .{ .rect, 2 },
        .{ .void_, 5 },
        .{ .role, 1 },
        .{ .string_array, 1 },
        .{ .orientation, 1 },
    };
    try testing.expectEqual(@as(usize, 16), expected.len);
    try testing.expectEqual(@as(usize, 16), @typeInfo(ReturnShape).@"enum".fields.len);
    var total: usize = 0;
    for (expected) |entry| {
        try testing.expectEqual(entry[1], countOfShape(entry[0]));
        total += entry[1];
    }
    try testing.expectEqual(selector_count, total);
    // The spelled Rust type of every shape is what upstream writes.
    inline for (@typeInfo(ReturnShape).@"enum".fields) |field| {
        const shape: ReturnShape = @enumFromInt(field.value);
        try testing.expect(returnShapeRustType(shape).len > 0);
    }
}

test "the four selectors installed on the host view are spelled as upstream spells them" {
    // `AK/macos/src/subclass.rs:179`, `:183`, `:187` and `:191`. These go to
    // `builder.add_method`, so a misspelling is a selector the runtime never
    // installs and the view silently keeps its original behaviour. Like the 43
    // literals, no compile catches it.
    try testing.expectEqual(@as(usize, 4), host_view_selectors.len);
    try testing.expectEqualStrings("superclass", host_view_selectors[0]);
    try testing.expectEqualStrings("accessibilityChildren", host_view_selectors[1]);
    try testing.expectEqualStrings("accessibilityFocusedUIElement", host_view_selectors[2]);
    try testing.expectEqualStrings("accessibilityHitTest:", host_view_selectors[3]);
    // The 4 are installed on the host view, not on a platform node, so three of
    // them name selectors the 54 do not implement. `accessibilityChildren` is
    // the exception: upstream implements it on both, and the subclass
    // overrides the host view's own.
    try testing.expect(findSelector("superclass") == null);
    try testing.expect(findSelector("accessibilityFocusedUIElement") == null);
    try testing.expect(findSelector("accessibilityHitTest:") == null);
    try testing.expect(findSelector(host_view_selectors[1]) != null);
    // The focus forwarder installs the third name on an `NSWindow` subclass.
    try testing.expectEqualStrings(host_view_selectors[2], focus_forwarder_selector);
}

test "the 14 groups cover all 54 selectors exactly once" {
    // The decomposition is a partition, so a selector in two groups or in none
    // is a failure. The walk is `answer_group_count` times the 54 names.
    var seen: [selector_count][]const u8 = undefined;
    var held: usize = 0;
    for (answer_groups) |group| {
        for (group.selectors) |name| {
            for (seen[0..held]) |earlier| {
                try testing.expect(!std.mem.eql(u8, earlier, name));
            }
            seen[held] = name;
            held += 1;
        }
    }
    try testing.expectEqual(selector_count, held);
    for (selectors) |selector| {
        var found = false;
        for (seen[0..held]) |name| {
            if (std.mem.eql(u8, name, selector.name)) found = true;
        }
        try testing.expect(found);
    }
    // A name outside the 54 is not in any group, so the method falls through.
    try testing.expect(answerFor("accessibilitySomethingElse") == null);
    try testing.expect(answerFor("superclass") == null);
}

test "the 13 text-range selectors stay one arm" {
    try testing.expectEqual(@as(usize, 13), text_range_selectors.len);
    for (text_range_selectors) |name| {
        try testing.expectEqual(
            Answer.supports_text_ranges,
            answerFor(name) orelse return error.TestUnexpectedResult,
        );
    }
    // Each is one of the 54, and each appears exactly once across the groups.
    for (text_range_selectors) |name| {
        try testing.expect(findSelector(name) != null);
    }
    // `setAccessibilityValue:` is in its own arm and not in this one.
    try testing.expectEqual(
        Answer.set_value,
        answerFor("setAccessibilityValue:") orelse return error.TestUnexpectedResult,
    );
    try testing.expect(findSelector("setAccessibilityValue:") != null);
}

test "the three attributes and their has-property conjuncts" {
    // `AK/macos/src/node.rs:1090-1104`. Every name comes from `literals.zig`, so
    // the spelling is pinned in one place.
    try testing.expectEqual(@as(usize, 3), attributes.len);
    for (attributes) |attribute| {
        try testing.expect(literals.findInGroup(.attribute_name, attribute.name) != null);
    }
    try testing.expectEqualStrings("AXBrailleLabel", attributes[0].name);
    try testing.expectEqualStrings("AXBrailleRoleDescription", attributes[1].name);
    try testing.expectEqualStrings("AXDOMIdentifier", attributes[2].name);
    // Each names a value property and a distinct `has_…` predicate, and the two
    // never name the same property: a pair that did would make the conjunct
    // vacuous.
    for (attributes) |attribute| {
        try testing.expect(attribute.property != attribute.has_property);
    }
    // `AXDOMIdentifier` is the one a port is most likely to "correct" into
    // `AXDomIdentifier` or `AXDOMID`. Upstream capitalises `DOM` and spells
    // `Identifier` in full.
    try testing.expect(!std.mem.eql(u8, attributes[2].name, "AXDomIdentifier"));
    try testing.expect(!std.mem.eql(u8, attributes[2].name, "AXDOMID"));
    try testing.expect(findSelector("accessibilityAttributeValue:") != null);
    try testing.expectEqual(
        Answer.has_any_attribute,
        answerFor("accessibilityAttributeValue:") orelse return error.TestUnexpectedResult,
    );
}

test "the four non-nil selectors answer their sentinel when the node is gone" {
    // `NSRect::ZERO` at `:478`, an unknown orientation at `:635`, `0` at
    // `:756` and `NSRange{0, 0}` at `:782`. Asserting the sentinels is what
    // distinguishes "unresolved" from "resolved to nothing", and a port that
    // returns `nil` from these four is a change a client sees as a crash.
    try testing.expectEqual([4]f64{ 0, 0, 0, 0 }, frame_zero);
    try testing.expectEqual(@as(i64, 0), number_of_characters_zero);
    try testing.expectEqual(util.NsRange{ .location = 0, .length = 0 }, selected_text_range_zero);
    try testing.expectEqual(@as(i32, 0), orientation_unknown);
    // The four are the total-answer shapes, so none of them can answer `nil`.
    for ([_][:0]const u8{
        "accessibilityFrame",
        "accessibilityOrientation",
        "accessibilityNumberOfCharacters",
        "accessibilitySelectedTextRange",
    }) |name| {
        const selector = findSelector(name) orelse return error.SelectorNotInTable;
        try testing.expect(!isNilCapable(selector.returns));
    }
    // A `schema.Orientation` has no unknown tag, so the sentinel cannot be one
    // of the two answers a live node gives.
    try testing.expectEqual(@as(usize, 2), @typeInfo(schema.Orientation).@"enum".fields.len);
}

test "accessibilityValue returns NSNumber for bool and number, NSString for string" {
    // The three shapes are indistinguishable to a client that only asks "is this
    // a string", and `setAccessibilityValue:` downcasts in the other direction
    // with two `downcast_ref` calls whose order decides the result for an
    // `NSNumber`.
    try testing.expectEqualStrings("NSNumber", valueClassName(.boolean));
    try testing.expectEqualStrings("NSNumber", valueClassName(.number));
    try testing.expectEqualStrings("NSString", valueClassName(.string));
    try testing.expectEqual(@as(usize, 3), @typeInfo(ValueShape).@"enum".fields.len);
}

test "accessibilityActionNames is empty rather than nil when no action is supported" {
    // Both arms of `:1207-1217`. A port returning `nil` here crashes a client
    // that indexes the array, and one returning a one-element array for an
    // unsupported node offers an action that does nothing.
    try testing.expectEqual(@as(usize, 0), actionNames(false).len);
    try testing.expectEqual(@as(usize, 1), actionNames(true).len);
    // The published name is the one `literals.zig` holds, in its own group.
    try testing.expectEqualStrings(
        literals.literals[literals.literal_count - 1].text,
        actionNames(true)[0],
    );
    try testing.expectEqualStrings("AXScrollToVisible", actionNames(true)[0]);
    // The selector itself is one of the 54 and sits in the always group, so a
    // client asking whether it may call it is always told yes.
    try testing.expect(findSelector("accessibilityActionNames") != null);
    try testing.expectEqual(
        Answer.always,
        answerFor("accessibilityActionNames") orelse return error.TestUnexpectedResult,
    );
}

test "the name published by accessibilityActionNames is the name performAction matches" {
    // The round trip from `literals.zig`. Without this the two halves can drift
    // into a pair that never matches, which is an action that is offered and
    // silently does nothing: the single most likely silent failure in the
    // adapter, because both halves are individually correct.
    const published = actionNames(true);
    try testing.expectEqual(@as(usize, 1), published.len);
    for (published) |name| {
        try testing.expectEqual(
            schema.Action.scroll_into_view,
            actionForName(name) orelse return error.TestUnexpectedResult,
        );
    }
    // Every other name dispatches nothing, which is what makes the pair total.
    try testing.expect(actionForName("AXPress") == null);
    try testing.expect(actionForName("AXScrollToVisible ") == null);
    try testing.expect(actionForName("axscrolltovisible") == null);
    try testing.expect(actionForName("") == null);
    // And the unsupported node publishes nothing, so nothing is dispatched.
    for (actionNames(false)) |name| {
        try testing.expect(actionForName(name) == null);
    }
}

test "every answer records the expression upstream writes for it" {
    // The 15 answers, 14 of which the 54 use. The spelling is what a reader
    // checks the port against.
    inline for (@typeInfo(Answer).@"enum".fields) |field| {
        const answer: Answer = @enumFromInt(field.value);
        try testing.expect(answerExpression(answer).len > 0);
    }
    // `unlisted` is the only answer no group names, because it is the
    // fall-through rather than a branch.
    var used: usize = 0;
    for (answer_groups) |group| {
        if (group.answer != .unlisted) used += 1;
    }
    try testing.expectEqual(answer_group_count, used);
    try testing.expectEqualStrings("false", answerExpression(.unlisted));
}
