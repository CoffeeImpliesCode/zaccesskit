//! The predicates that answer a yes-or-no question about a `NodeRef`.
//!
//! Upstream range: `accesskit_consumer/src/node.rs:562-716`, plus `node.rs:89-113`,
//! `node.rs:469-480`, `node.rs:861` and `node.rs:881`. The closing note names every
//! item that sits outside those lines and why.
//!
//! **Where a predicate gets its type.** Every predicate here takes the node
//! handle and reads through the same accessor modules `properties.zig` uses, on
//! `node.data().properties` and `node.data().flags`. Nothing in this file keeps
//! a copy of a property, and no predicate takes a value a caller may have
//! cached. A reader who finds a predicate reading a private copy of the label
//! has found a second source of truth, and there is none here. Where this module
//! needs a raw read that upstream declares as a `NodeRef` method in its range,
//! it calls the `properties.zig` forward of the same name.
//!
//! **Six of these grew an error union, and every one of them grew it for the
//! same reason.** `isClickable`, `isInvocable`, `supportsAction`,
//! `supportsIncrement` and `supportsDecrement` ask about an action the node or
//! one of its filtered ancestors accepts, so they need `filteredParent`, and
//! `filteredParent` walks a bounded chain and reports exhaustion.
//! `docs/33` section 7 row 5 names the bound and the tag, so these five return
//! `QueryError!bool` where upstream returned `bool`.
//! `sizeOfSetFromContainer` returns `QueryError!?usize` for the same reason.
//!
//! **The closure in `is_focused` is gone.** Upstream `node.rs:90` writes
//! `dominated_by_active_descendant` as a closure capturing `self`, and rule C1
//! bans a capture in this layer because it hides the sequence of reads. It is
//! `node_id.activeDescendant` below, which takes the node it asks about.
//!
//! **What this module does not do.** It allocates nothing, so no function here
//! takes an allocator and a caller releases nothing after any call. It does not
//! block, so no function here takes `io`. It opens no file, reads no clock and
//! holds no global. `schema/props/` owns every property accessor, so this file
//! declares none.

const std = @import("std");

const schema = @import("../../schema/root.zig");
const filter = @import("../filter.zig");
const hierarchy = @import("../node_ref/hierarchy.zig");
const node_id = @import("../node_id.zig");
const properties = @import("properties.zig");
const tree_index = @import("../tree_index.zig");
const tree_state = @import("../tree_state.zig");

const FilterFn = filter.FilterFn;
const FilterResult = filter.FilterResult;
const NodeRef = node_id.NodeRef;
const Node = schema.Node;
const QueryError = tree_state.QueryError;
const treeWalkStepBound = tree_state.treeWalkStepBound;

const enums = schema.enums;
const flags = schema.flags;
const ids_props = schema.ids_props;
const numbers = schema.numbers;

const testing = std.testing;

/// Whether this node and an ancestor hold the focus, which upstream reads the
/// recorded focus and the `active_descendant` chain.
///
/// `false` when the host reports no focus, which is different from the tree
/// recording a focus the host has not taken.
pub fn isFocused(node: NodeRef) bool {
    const focus_id = node.tree_state.focusId() orelse return false;
    const focus = node.tree_state.nodeById(focus_id) orelse return false;
    // The focused node keeps the focus itself unless it hands the focus to the
    // descendant it names, so the two arms read the same value differently.
    if (std.meta.eql(focus_id, node.id())) return node_id.activeDescendant(focus) == null;
    const active = node_id.activeDescendant(focus) orelse return false;
    return std.meta.eql(active.id(), node.id());
}

/// Whether the tree records this node as the focus, whether or not the host
/// reports that focus. This is the raw `TreeState.focus` field.
pub fn isFocusedInTree(node: NodeRef) bool {
    return std.meta.eql(node.tree_state.focusIdInTree(), node.id());
}

/// Whether this node accepts the focus action or is the recorded focus.
pub fn isFocusable(node: NodeRef, parent_filter: FilterFn) QueryError!bool {
    return (try supportsAction(node, .focus, parent_filter)) or isFocusedInTree(node);
}

/// Whether this node is one of the roles that accept typed text, so it is
/// read-only-by-default only when it says so.
pub fn isTextInput(node: NodeRef) bool {
    return switch (properties.role(node)) {
        .text_input,
        .multiline_text_input,
        .search_input,
        .date_input,
        .date_time_input,
        .week_input,
        .month_input,
        .time_input,
        .email_input,
        .number_input,
        .password_input,
        .phone_number_input,
        .url_input,
        .editable_combo_box,
        .spin_button,
        => true,
        else => false,
    };
}

/// Whether this node is a text input that holds more than one line.
pub fn isMultiline(node: NodeRef) bool {
    return properties.role(node) == .multiline_text_input;
}

/// The orientation this node lays its content out in.
///
/// A node that states `orientation` answers with it. A list box and a tab list
/// answer from their role when the property is absent, because neither role has
/// a direction to lay out. Every other role answers `null`, and `null` is not a
/// direction.
pub fn orientation(node: NodeRef) ?schema.Orientation {
    if (enums.orientation(&node.data().properties)) |stored| return stored;
    return switch (properties.role(node)) {
        .list_box => .vertical,
        .tab_list => .horizontal,
        else => null,
    };
}

/// Whether this node is a dialog window.
pub fn isDialog(node: NodeRef) bool {
    return switch (properties.role(node)) {
        .alert_dialog, .dialog => true,
        else => false,
    };
}

/// Whether this node is a dialog that blocks what is behind it.
pub fn isModal(node: NodeRef) bool {
    return flags.isModal(node.data().flags);
}

/// Whether this node accepts a click, or has a filtered parent that reports its
/// children accept one.
///
/// The action comes from what the provider declared, never from the role. A
/// provider that forgot `add_action` gets the fall back an assistive technology
/// would apply itself, which is better than a click the provider ignores.
pub fn isClickable(node: NodeRef, parent_filter: FilterFn) QueryError!bool {
    return supportsAction(node, .click, parent_filter);
}

/// Whether this node is selectable, which means it carries the selection state
/// at all. A stored `false` is selectable: the attribute is present.
pub fn isSelectable(node: NodeRef) bool {
    return properties.isSelected(node) != null and !properties.isDisabled(node);
}

/// Whether this node lets more than one of its children be selected at a time.
pub fn isMultiselectable(node: NodeRef) bool {
    return flags.isMultiselectable(node.data().flags);
}

/// The nearest `size_of_set` on the filtered ancestor chain, or `null` when no
/// ancestor states one.
///
/// The chain is bounded by `treeWalkStepBound`. A cycle among ancestors that
/// the filter includes is reported as `error.TreeCycle`, and so is a cycle the
/// filter walks past, which `filteredParent` finds first.
pub fn sizeOfSetFromContainer(node: NodeRef, parent_filter: FilterFn) QueryError!?usize {
    const bound = treeWalkStepBound(node.tree_state.nodes.count());
    var ancestor = try hierarchy.filteredParent(node, parent_filter);
    var step: usize = 0;
    while (step < bound) : (step += 1) {
        const candidate = ancestor orelse return null;
        if (sizeOfSet(candidate)) |size| return size;
        ancestor = try hierarchy.filteredParent(candidate, parent_filter);
    }
    return error.TreeCycle;
}

/// The total number of items this node's container holds, or `null` when the
/// node states none. This is the node's own value and not an inherited one.
pub fn sizeOfSet(node: NodeRef) ?usize {
    return numbers.sizeOfSet(&node.data().properties);
}

/// The index of this node in its container's item list, or `null` when the node
/// states none. This is the node's own value and not an inherited one.
pub fn positionInSet(node: NodeRef) ?usize {
    return numbers.positionInSet(&node.data().properties);
}

/// The order this node's items are sorted in, or `null` when the node states
/// none.
pub fn sortDirection(node: NodeRef) ?schema.SortDirection {
    return enums.sortDirection(&node.data().properties);
}

/// Whether this node is a toggle, which means it states a pressed state. A
/// stored value of either tag makes it a toggle.
pub fn supportsToggle(node: NodeRef) bool {
    return properties.toggled(node) != null;
}

/// Whether this node opens a popup or expands and collapses, judged by what it
/// states first and by its role second.
pub fn supportsExpandCollapse(node: NodeRef) bool {
    if (properties.hasPopup(node) != null) return true;
    if (enums.isExpanded(&node.data().properties) != null) return true;
    return switch (properties.role(node)) {
        .combo_box, .editable_combo_box, .disclosure_triangle, .tree_item => true,
        else => false,
    };
}

/// Whether activating this node does something without keeping any state.
///
/// A control that keeps state when activated is a toggle or an
/// expand-collapse control, and a control that only takes focus is neither: the
/// invoke action would be a second name for the set-focus action. The action
/// comes from what the provider declared, never from the role, for the reason
/// `isClickable` gives.
pub fn isInvocable(node: NodeRef, parent_filter: FilterFn) QueryError!bool {
    if (!try isClickable(node, parent_filter)) return false;
    if (isTextInput(node)) return false;
    if (isDocumentOrTerminal(node)) return false;
    if (supportsToggle(node)) return false;
    if (supportsExpandCollapse(node)) return false;
    return properties.isSelected(node) == null;
}

/// Whether this node accepts `action`, or whether a filtered parent reports that
/// its children do.
///
/// The parent's answer is `child_supports_action`, which is the bit mask the
/// provider filled in for the children it does not hold itself, so the walk is
/// one step and not a chain.
pub fn supportsAction(
    node: NodeRef,
    action: schema.Action,
    parent_filter: FilterFn,
) QueryError!bool {
    if (node.data().supportsAction(action)) return true;
    const parent = try hierarchy.filteredParent(node, parent_filter) orelse return false;
    return parent.data().childSupportsAction(action);
}

/// Whether this node accepts the increment action.
pub fn supportsIncrement(node: NodeRef, parent_filter: FilterFn) QueryError!bool {
    return supportsAction(node, .increment, parent_filter);
}

/// Whether this node accepts the decrement action.
pub fn supportsDecrement(node: NodeRef, parent_filter: FilterFn) QueryError!bool {
    return supportsAction(node, .decrement, parent_filter);
}

/// The filter upstream hands to `FilteredChildren` when a node carries no
/// `labelled_by` list and its role asks for one from its descendants. Upstream
/// declares it as the private `descendant_label_filter` at `node.rs:710`, and
/// `docs/33` section 8 puts it in this module, so it is published here.
///
/// A label and an image name something, a generic container contributes nothing
/// but must not end the search, and anything else ends it.
pub fn descendantLabelFilter(node: NodeRef) FilterResult {
    return switch (properties.role(node)) {
        .label, .image => .include,
        .generic_container => .exclude_node,
        else => .exclude_subtree,
    };
}

/// Whether this node is read only, which is true when the node says so, when
/// its role is read only by default, and when its role has no read-only state to
/// set at all.
pub fn isReadOnly(node: NodeRef) bool {
    if (properties.rawIsReadOnly(node)) return true;
    return shouldHaveReadOnlyStateByDefault(node) or !isReadOnlySupported(node);
}

/// Whether this node is read only or disabled. A disabled node is read only
/// because it accepts no input either way.
pub fn isReadOnlyOrDisabled(node: NodeRef) bool {
    return isReadOnly(node) or properties.isDisabled(node);
}

/// Whether this node has a read-only state for the provider to set. A role that
/// does not is read only whatever the node says.
pub fn isReadOnlySupported(node: NodeRef) bool {
    if (isTextInput(node)) return true;
    return switch (properties.role(node)) {
        .check_box,
        .color_well,
        .combo_box,
        .grid,
        .list_box,
        .menu_item_check_box,
        .menu_item_radio,
        .menu_list_popup,
        .radio_button,
        .radio_group,
        .slider,
        .switch_,
        .tree_grid,
        => true,
        else => false,
    };
}

/// Whether this node's role is one whose read-only state is true unless the
/// provider sets it, so a platform that reads no state still shows the node as
/// read only.
pub fn shouldHaveReadOnlyStateByDefault(node: NodeRef) bool {
    return switch (properties.role(node)) {
        .article,
        .definition,
        .description_list,
        .document,
        .graphics_document,
        .image,
        .list,
        .list_item,
        .pdf_root,
        .progress_indicator,
        .root_web_area,
        .term,
        .timer,
        .toolbar,
        .tooltip,
        => true,
        else => false,
    };
}

/// Whether this node's role is a document or a terminal, which activation does
/// nothing useful to.
fn isDocumentOrTerminal(node: NodeRef) bool {
    return switch (properties.role(node)) {
        .document, .terminal => true,
        else => false,
    };
}

// Upstream's `NodeRef::active_descendant` at `node.rs:966` is
// `node_id.activeDescendant`. It is not inlined here: two callers in two
// modules need it, so a second copy would be a second source of truth.

// -- Tests --

/// The filter that keeps every node, so a walk under test is the walk itself
/// and not the filter.
fn keepEveryNode(context: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    _ = context;
    _ = node;
    return .include;
}

/// `keepEveryNode` as a `FilterFn`. `consumer/filter.zig` declares `FilterFn` as
/// a context plus a test rather than as a bare function pointer, because a
/// filter needing per-call state takes the context and a filter reading only the
/// node passes `null`.
const include_all: FilterFn = .{ .context = null, .filter = keepEveryNode };

/// A tree built for the tests. It owns every node it holds, so `deinit`
/// releases them.
///
/// **Build the whole tree before taking a handle.** A handle borrows an entry of
/// `TreeState.nodes`, and `add` can grow the map, and growing the map moves its
/// entries. `docs/33` section 4 states that rule, so every test below adds its
/// nodes and then asks `nodeAt` for the handles it needs.
const Fixture = struct {
    gpa: std.mem.Allocator,
    state: tree_state.TreeState,

    fn init(gpa: std.mem.Allocator) Fixture {
        return .{ .gpa = gpa, .state = .{} };
    }

    fn deinit(self: *Fixture) void {
        self.state.deinit(self.gpa);
        // SAFETY: `state.deinit` released every buffer the fixture owned, and
        // no statement after it reads `self`.
        self.* = undefined;
    }

    /// Puts a clone of `source` at `content`, under `parent` or at the root.
    /// `parent` may name a node that is not in the state yet, which is how the
    /// cycle tests close a chain.
    fn add(self: *Fixture, content: u64, parent: ?u64, source: *const Node) !void {
        try self.state.nodes.put(self.gpa, fullNodeId(content), .{
            .parent_and_index = if (parent) |parent_content| tree_index.ParentAndIndex{
                .parent_id = fullNodeId(parent_content),
                .index = 0,
            } else null,
            .data = try Node.clone(self.gpa, source),
        });
    }

    /// Records `content` as the focus and reports the host as focused.
    fn focusHost(self: *Fixture, content: u64) void {
        self.state.focus_id = fullNodeId(content);
        self.state.is_host_focused = true;
    }
};

/// The handle for the node whose local id content is `content`. Take it after
/// the last `add`.
fn nodeAt(fixture: *const Fixture, content: u64) NodeRef {
    return fixture.state.nodeById(fullNodeId(content)).?;
}

/// The size `sizeOfSetFromContainer` finds for the node at `content`, so a test
/// line stays short enough to read.
fn inheritedSize(fixture: *const Fixture, content: u64) QueryError!?usize {
    return sizeOfSetFromContainer(nodeAt(fixture, content), include_all);
}

fn fullNodeId(content: u64) tree_index.FullNodeId {
    return tree_index.FullNodeId.init(schema.nodeIdFromContent(content), .init(0));
}

/// A node with one role and nothing else.
fn bare(gpa: std.mem.Allocator, role: schema.Role) Node {
    return Node.init(gpa, role);
}

test "the text input and dialog predicates answer their roles and not a neighbour's" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var single = bare(gpa, .text_input);
    defer single.deinit();
    var multi = bare(gpa, .multiline_text_input);
    defer multi.deinit();
    var dialog_node = bare(gpa, .dialog);
    defer dialog_node.deinit();
    var alert = bare(gpa, .alert_dialog);
    defer alert.deinit();
    var button = bare(gpa, .button);
    defer button.deinit();

    try fixture.add(1, null, &single);
    try fixture.add(2, null, &multi);
    try fixture.add(3, null, &dialog_node);
    try fixture.add(4, null, &alert);
    try fixture.add(5, null, &button);

    try testing.expect(isTextInput(nodeAt(&fixture, 1)));
    try testing.expect(isTextInput(nodeAt(&fixture, 2)));
    try testing.expect(!isTextInput(nodeAt(&fixture, 5)));
    try testing.expect(isMultiline(nodeAt(&fixture, 2)));
    try testing.expect(!isMultiline(nodeAt(&fixture, 1)));
    try testing.expect(isDialog(nodeAt(&fixture, 3)));
    try testing.expect(isDialog(nodeAt(&fixture, 4)));
    try testing.expect(!isDialog(nodeAt(&fixture, 5)));
}

test "orientation falls back to the role and the stored value wins" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var list_box = bare(gpa, .list_box);
    defer list_box.deinit();
    var tab_list = bare(gpa, .tab_list);
    defer tab_list.deinit();
    var button = bare(gpa, .button);
    defer button.deinit();
    var stated = bare(gpa, .list_box);
    defer stated.deinit();
    try enums.setOrientation(&stated.properties, .horizontal);

    try fixture.add(1, null, &list_box);
    try fixture.add(2, null, &tab_list);
    try fixture.add(3, null, &button);
    try fixture.add(4, null, &stated);

    try testing.expectEqual(@as(?schema.Orientation, .vertical), orientation(nodeAt(&fixture, 1)));
    const tab = nodeAt(&fixture, 2);
    try testing.expectEqual(@as(?schema.Orientation, .horizontal), orientation(tab));
    try testing.expectEqual(@as(?schema.Orientation, null), orientation(nodeAt(&fixture, 3)));
    // A stored orientation overrides the role, which is the order upstream's
    // `or_else` fixes.
    const with_stored = nodeAt(&fixture, 4);
    try testing.expectEqual(@as(?schema.Orientation, .horizontal), orientation(with_stored));
}

test "the modal and multiselectable flags answer their bits" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var plain = bare(gpa, .list_box);
    defer plain.deinit();
    var modal_node = bare(gpa, .dialog);
    defer modal_node.deinit();
    flags.setModal(&modal_node.flags, true);
    var multi_node = bare(gpa, .list_box);
    defer multi_node.deinit();
    flags.setMultiselectable(&multi_node.flags, true);

    try fixture.add(1, null, &plain);
    try fixture.add(2, null, &modal_node);
    try fixture.add(3, null, &multi_node);

    try testing.expect(!isModal(nodeAt(&fixture, 1)));
    try testing.expect(!isMultiselectable(nodeAt(&fixture, 1)));
    try testing.expect(isModal(nodeAt(&fixture, 2)));
    try testing.expect(!isMultiselectable(nodeAt(&fixture, 2)));
    try testing.expect(isMultiselectable(nodeAt(&fixture, 3)));
}

test "isSelectable needs the selection state and an enabled node" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var unselected = bare(gpa, .list_box_option);
    defer unselected.deinit();
    try enums.setSelected(&unselected.properties, false);
    var no_attribute = bare(gpa, .list_box_option);
    defer no_attribute.deinit();
    var disabled_node = bare(gpa, .list_box_option);
    defer disabled_node.deinit();
    try enums.setSelected(&disabled_node.properties, true);
    flags.setDisabled(&disabled_node.flags, true);
    var editable = bare(gpa, .text_input);
    defer editable.deinit();
    try enums.setSelected(&editable.properties, true);

    try fixture.add(1, null, &unselected);
    try fixture.add(2, null, &no_attribute);
    try fixture.add(3, null, &disabled_node);
    try fixture.add(4, null, &editable);

    // A stored `false` is selectable: the attribute is present.
    try testing.expect(isSelectable(nodeAt(&fixture, 1)));
    try testing.expect(!isSelectable(nodeAt(&fixture, 2)));
    try testing.expect(!isSelectable(nodeAt(&fixture, 3)));
    try testing.expect(isSelectable(nodeAt(&fixture, 4)));
    // A disabled node is read only, whatever its selection state.
    try testing.expect(isReadOnlyOrDisabled(nodeAt(&fixture, 3)));
    // `list_box_option` has no read-only state, so it reads as read only.
    try testing.expect(isReadOnlyOrDisabled(nodeAt(&fixture, 1)));
    // A text input has one, and this node does not set it.
    try testing.expect(!isReadOnlyOrDisabled(nodeAt(&fixture, 4)));
}

test "the set and sort reads answer the stored value and null when unset" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var bare_node = bare(gpa, .list_box_option);
    defer bare_node.deinit();
    var stated = bare(gpa, .list_box_option);
    defer stated.deinit();
    try numbers.setSizeOfSet(&stated.properties, 4);
    try numbers.setPositionInSet(&stated.properties, 2);
    try enums.setSortDirection(&stated.properties, .descending);

    try fixture.add(1, null, &bare_node);
    try fixture.add(2, null, &stated);

    try testing.expectEqual(@as(?usize, null), sizeOfSet(nodeAt(&fixture, 1)));
    try testing.expectEqual(@as(?usize, null), positionInSet(nodeAt(&fixture, 1)));
    try testing.expectEqual(@as(?schema.SortDirection, null), sortDirection(nodeAt(&fixture, 1)));
    try testing.expectEqual(@as(?usize, 4), sizeOfSet(nodeAt(&fixture, 2)));
    try testing.expectEqual(@as(?usize, 2), positionInSet(nodeAt(&fixture, 2)));
    const sorted = nodeAt(&fixture, 2);
    try testing.expectEqual(@as(?schema.SortDirection, .descending), sortDirection(sorted));
}

test "supportsToggle and supportsExpandCollapse read the state and then the role" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var plain = bare(gpa, .button);
    defer plain.deinit();
    var toggled_node = bare(gpa, .button);
    defer toggled_node.deinit();
    try enums.setToggled(&toggled_node.properties, .false_);
    var popup_node = bare(gpa, .button);
    defer popup_node.deinit();
    try enums.setHasPopup(&popup_node.properties, .listbox);
    var expanded_node = bare(gpa, .button);
    defer expanded_node.deinit();
    try enums.setExpanded(&expanded_node.properties, false);
    var role_node = bare(gpa, .tree_item);
    defer role_node.deinit();

    try fixture.add(1, null, &plain);
    try fixture.add(2, null, &toggled_node);
    try fixture.add(3, null, &popup_node);
    try fixture.add(4, null, &expanded_node);
    try fixture.add(5, null, &role_node);

    try testing.expect(!supportsToggle(nodeAt(&fixture, 1)));
    // Either toggle tag makes a toggle.
    try testing.expect(supportsToggle(nodeAt(&fixture, 2)));
    try testing.expect(!supportsToggle(nodeAt(&fixture, 3)));

    try testing.expect(!supportsExpandCollapse(nodeAt(&fixture, 1)));
    try testing.expect(supportsExpandCollapse(nodeAt(&fixture, 3)));
    // An expansion state of `false` still counts: the node states one.
    try testing.expect(supportsExpandCollapse(nodeAt(&fixture, 4)));
    try testing.expect(supportsExpandCollapse(nodeAt(&fixture, 5)));
}

test "the action predicates answer the node's own masks and then the parent's" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var parent = bare(gpa, .group);
    defer parent.deinit();
    parent.addChildAction(.focus);
    parent.addChildAction(.increment);
    var child = bare(gpa, .text_input);
    defer child.deinit();
    var clickable = bare(gpa, .button);
    defer clickable.deinit();
    clickable.addAction(.click);
    var silent = bare(gpa, .button);
    defer silent.deinit();

    try fixture.add(1, null, &parent);
    try fixture.add(2, 1, &child);
    try fixture.add(3, null, &clickable);
    try fixture.add(4, 1, &silent);

    try testing.expect(try isClickable(nodeAt(&fixture, 3), include_all));
    try testing.expect(!try isClickable(nodeAt(&fixture, 4), include_all));
    // The node states nothing, and its parent reports the action for its
    // children, which is the second half of the walk.
    try testing.expect(try supportsAction(nodeAt(&fixture, 2), .focus, include_all));
    try testing.expect(!try supportsAction(nodeAt(&fixture, 2), .click, include_all));
    try testing.expect(try supportsIncrement(nodeAt(&fixture, 2), include_all));
    try testing.expect(!try supportsDecrement(nodeAt(&fixture, 2), include_all));
}

test "isInvocable excludes every control that keeps state or only takes focus" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var plain = bare(gpa, .button);
    defer plain.deinit();
    plain.addAction(.click);
    var text_field = bare(gpa, .text_input);
    defer text_field.deinit();
    text_field.addAction(.click);
    var toggle = bare(gpa, .button);
    defer toggle.deinit();
    toggle.addAction(.click);
    try enums.setToggled(&toggle.properties, .true_);
    var document_node = bare(gpa, .document);
    defer document_node.deinit();
    document_node.addAction(.click);
    var selectable = bare(gpa, .button);
    defer selectable.deinit();
    selectable.addAction(.click);
    try enums.setSelected(&selectable.properties, true);
    var silent = bare(gpa, .button);
    defer silent.deinit();

    try fixture.add(1, null, &plain);
    try fixture.add(2, null, &text_field);
    try fixture.add(3, null, &toggle);
    try fixture.add(4, null, &document_node);
    try fixture.add(5, null, &selectable);
    try fixture.add(6, null, &silent);

    try testing.expect(try isInvocable(nodeAt(&fixture, 1), include_all));
    try testing.expect(!try isInvocable(nodeAt(&fixture, 2), include_all));
    try testing.expect(!try isInvocable(nodeAt(&fixture, 3), include_all));
    try testing.expect(!try isInvocable(nodeAt(&fixture, 4), include_all));
    try testing.expect(!try isInvocable(nodeAt(&fixture, 5), include_all));
    try testing.expect(!try isInvocable(nodeAt(&fixture, 6), include_all));
}

test "isFocused follows the recorded focus and the active descendant chain" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var root = bare(gpa, .document);
    defer root.deinit();
    var middle = bare(gpa, .group);
    defer middle.deinit();
    var leaf = bare(gpa, .text_input);
    defer leaf.deinit();

    try fixture.add(1, null, &root);
    try fixture.add(2, 1, &middle);
    try fixture.add(3, 2, &leaf);

    // No host focus yet, so no node is focused even though none is recorded.
    try testing.expect(!isFocused(nodeAt(&fixture, 1)));
    try testing.expect(!isFocusedInTree(nodeAt(&fixture, 1)));

    fixture.focusHost(2);
    try testing.expect(isFocused(nodeAt(&fixture, 2)));
    try testing.expect(isFocusedInTree(nodeAt(&fixture, 2)));
    try testing.expect(!isFocused(nodeAt(&fixture, 1)));
    try testing.expect(!isFocusedInTree(nodeAt(&fixture, 3)));

    // The focus is taken, so a host that reports no focus still leaves
    // `isFocusedInTree` answering from the raw field.
    fixture.state.is_host_focused = false;
    try testing.expect(!isFocused(nodeAt(&fixture, 2)));
    try testing.expect(isFocusedInTree(nodeAt(&fixture, 2)));
    fixture.state.is_host_focused = true;

    // A focused node that names an active descendant hands the focus to it, and
    // the node itself is then not focused. The property is stored before the
    // node is cloned into the tree, because the tree holds a copy.
    var root_with_active = bare(gpa, .document);
    defer root_with_active.deinit();
    try ids_props.setActiveDescendant(&root_with_active.properties, schema.nodeIdFromContent(9));
    var active_leaf = bare(gpa, .text_input);
    defer active_leaf.deinit();
    try fixture.add(4, null, &root_with_active);
    try fixture.add(9, 4, &active_leaf);
    fixture.focusHost(4);

    try testing.expect(isFocused(nodeAt(&fixture, 9)));
    try testing.expect(!isFocused(nodeAt(&fixture, 4)));
    try testing.expect(isFocusedInTree(nodeAt(&fixture, 4)));
}

test "isFocusable answers the focus action or the recorded focus" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var with_action = bare(gpa, .button);
    defer with_action.deinit();
    with_action.addAction(.focus);
    var focused_node = bare(gpa, .button);
    defer focused_node.deinit();
    var silent = bare(gpa, .button);
    defer silent.deinit();

    try fixture.add(1, null, &with_action);
    try fixture.add(2, null, &focused_node);
    try fixture.add(3, null, &silent);
    fixture.state.focus_id = fullNodeId(2);
    fixture.state.is_host_focused = true;

    try testing.expect(try isFocusable(nodeAt(&fixture, 1), include_all));
    try testing.expect(try isFocusable(nodeAt(&fixture, 2), include_all));
    try testing.expect(!try isFocusable(nodeAt(&fixture, 3), include_all));
}

test "sizeOfSetFromContainer takes the nearest ancestor that states a size" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var root = bare(gpa, .list_box);
    defer root.deinit();
    try numbers.setSizeOfSet(&root.properties, 9);
    var middle = bare(gpa, .group);
    defer middle.deinit();
    try numbers.setSizeOfSet(&middle.properties, 4);
    var leaf = bare(gpa, .list_box_option);
    defer leaf.deinit();

    try fixture.add(1, null, &root);
    try fixture.add(2, 1, &middle);
    try fixture.add(3, 2, &leaf);

    try testing.expectEqual(@as(?usize, 4), try inheritedSize(&fixture, 3));
    try testing.expectEqual(@as(?usize, 9), try inheritedSize(&fixture, 2));
    // The root has no parent, so the walk ends with `null` rather than a value.
    try testing.expectEqual(@as(?usize, null), try inheritedSize(&fixture, 1));
}

test "sizeOfSetFromContainer answers null when no ancestor states a size" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var root = bare(gpa, .list_box);
    defer root.deinit();
    var leaf = bare(gpa, .list_box_option);
    defer leaf.deinit();

    try fixture.add(1, null, &root);
    try fixture.add(2, 1, &leaf);

    try testing.expectEqual(@as(?usize, null), try inheritedSize(&fixture, 2));
}

test "sizeOfSetFromContainer reports error.TreeCycle when the ancestors repeat" {
    // Two nodes and a bound of two. Each `filteredParent` call stops at once,
    // because the filter includes the parent, so only this module's own step
    // count catches the repeat.
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var first = bare(gpa, .group);
    defer first.deinit();
    var second = bare(gpa, .group);
    defer second.deinit();

    try fixture.add(1, 2, &first);
    try fixture.add(2, 1, &second);

    try testing.expectEqual(@as(usize, 2), treeWalkStepBound(fixture.state.nodes.count()));
    try testing.expectError(error.TreeCycle, inheritedSize(&fixture, 1));
}

test "descendantLabelFilter includes a label and an image and skips a generic container's subtree" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var label = bare(gpa, .label);
    defer label.deinit();
    var image = bare(gpa, .image);
    defer image.deinit();
    var container = bare(gpa, .generic_container);
    defer container.deinit();
    var button = bare(gpa, .button);
    defer button.deinit();

    try fixture.add(1, null, &label);
    try fixture.add(2, null, &image);
    try fixture.add(3, null, &container);
    try fixture.add(4, 3, &button);

    try testing.expectEqual(FilterResult.include, descendantLabelFilter(nodeAt(&fixture, 1)));
    try testing.expectEqual(FilterResult.include, descendantLabelFilter(nodeAt(&fixture, 2)));
    try testing.expectEqual(FilterResult.exclude_node, descendantLabelFilter(nodeAt(&fixture, 3)));
    const below_container = nodeAt(&fixture, 4);
    try testing.expectEqual(FilterResult.exclude_subtree, descendantLabelFilter(below_container));
}

test "isReadOnly follows the bit, the default roles and the unsupported roles" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var stated = bare(gpa, .button);
    defer stated.deinit();
    flags.setReadOnly(&stated.flags, true);
    var default_role = bare(gpa, .list_item);
    defer default_role.deinit();
    var unsupported = bare(gpa, .button);
    defer unsupported.deinit();
    var supported = bare(gpa, .text_input);
    defer supported.deinit();
    var supported_widget = bare(gpa, .check_box);
    defer supported_widget.deinit();

    try fixture.add(1, null, &stated);
    try fixture.add(2, null, &default_role);
    try fixture.add(3, null, &unsupported);
    try fixture.add(4, null, &supported);
    try fixture.add(5, null, &supported_widget);

    try testing.expect(isReadOnly(nodeAt(&fixture, 1)));
    try testing.expect(!isReadOnlySupported(nodeAt(&fixture, 1)));
    try testing.expect(shouldHaveReadOnlyStateByDefault(nodeAt(&fixture, 2)));
    try testing.expect(isReadOnly(nodeAt(&fixture, 2)));
    // A role with no read-only state is read only whatever the node says.
    try testing.expect(isReadOnly(nodeAt(&fixture, 3)));
    try testing.expect(!isReadOnly(nodeAt(&fixture, 4)));
    try testing.expect(isReadOnlySupported(nodeAt(&fixture, 4)));
    try testing.expect(!isReadOnly(nodeAt(&fixture, 5)));
    try testing.expect(isReadOnlySupported(nodeAt(&fixture, 5)));
    try testing.expect(!shouldHaveReadOnlyStateByDefault(nodeAt(&fixture, 5)));
}

// -- The range, and the six moves --

// Every item in `node.rs:562-716` has a counterpart here, and the table lives in
// `docs/30-port-design.md`. Six of them are not in that range:
//
// - `isReadOnly` at `node.rs:469`, `isReadOnlyOrDisabled` at `:478`,
//   `isReadOnlySupported` at `:861` and `shouldHaveReadOnlyStateByDefault` at
//   `:881`. `isReadOnly` reaches `isReadOnlySupported`, which reaches
//   `isTextInput` at `:562`. `docs/33` section 1.1 row 9 forbids
//   `predicates.zig` under `properties.zig`, so the chain cannot run the other
//   way. Upstream's only caller of the two helpers is `isReadOnly` at `:474`,
//   so nothing else moves with them.
// - `isFocused` at `node.rs:89`, `isFocusedInTree` at `:107` and
//   `isFocusable` at `:111`. All three sit inside the `hierarchy.zig` range and
//   all three belong with `supportsAction` at `:687`, which `isFocusable`
//   calls. `hierarchy.zig` cannot import this module, so the chain cannot run
//   the other way.
//
// Two items upstream declares at `node.rs:920` and `:938` are **not** here.
// `isItemLike` and `isContainerWithSelectableChildren` are pure role matches
// over `properties.role` whose only callers are `items` and
// `selectionContainer` in `node_ref/containers.zig`, and `containers.zig`
// cannot import `set_state.zig` where those two lines nominally sit. They
// therefore live in `node_ref/containers.zig`, beside their only caller.
//
// Nothing upstream is deleted. Five predicates return `QueryError!bool` where
// upstream returned `bool`, and `sizeOfSetFromContainer` returns
// `QueryError!?usize` where upstream returned `Option<usize>`, because the five
// need `filteredParent`, which `docs/33` section 7 row 5 requires to report
// exhaustion as `error.TreeCycle`.
