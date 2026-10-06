//! The node wrapper and the iOS-only element filter, upstream
//! `AK/ios/src/node.rs:61-122` and `AK/ios/src/filters.rs:27-52`.
//!
//! **What this module is.** `NodeWrapper` is the one-field newtype over a
//! `NodeRef` at `AK/ios/src/node.rs:61`, and `hasNonScrollAction` and
//! `canBeFocused` are two of its methods, at `:102-113` and `:115-122`.
//! `filterForIsAccessibilityElement` is the iOS refinement of the common filter,
//! at `AK/ios/src/filters.rs:27-52`.
//!
//! **Why the filter is here and not in `root.zig`.** `root.zig:127-140` records
//! the decision: the refinement decides whether one node is an accessibility
//! element rather than which nodes are visible, and its only caller is the
//! `isAccessibilityElement` selector at `AK/ios/src/node.rs:232-236`. So it
//! belongs to the node layer, and this module is the node layer.
//!
//! **What is not here.** The other eight methods of the wrapper need a
//! `PlatformNode`, so they are the node class, which is not ported. `label` is
//! already answered by `consumer.node_ref.strings.label`, which
//! `root.zig:1560` is the caller of. `traits` and `containerType` need the
//! `UIAccessibilityTraits` and `UIAccessibilityContainerType` values that
//! `uikit.zig` declares non-exhaustive.
//!
//! **The filter.** It is the one `FilterFn` the module hands to a walk, and it is
//! `consumer.filter.commonFilter`, the same value `root.zig:142` builds. This
//! module builds its own rather than importing `root.zig`, because `root.zig`
//! imports nothing here and a module that imports the adapter body would close a
//! cycle. The two are the same function over the same node, and the test at the
//! end of this file drives both over one tree and compares them.
//!
//! **The loop bounds.** Two walks are written here. `canBeFocused` reads ten
//! actions and six properties and writes no loop, because a `while` over a list
//! would hide which action answered. `filterForIsAccessibilityElement` walks the
//! filtered children, whose bound is the number of filtered children, and the
//! inner walk asks one child whether it has any, which is one step.

const std = @import("std");

const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");

const NodeRef = consumer.node_id.NodeRef;
const FilterFn = consumer.filter.FilterFn;
const FilterResult = consumer.filter.FilterResult;
const QueryError = consumer.tree_state.QueryError;
const testing = std.testing;

/// What the two methods and the filter can report.
///
/// Upstream writes `has_non_scroll_action` and `can_be_focused` as `bool` and
/// `filter_for_is_accessibility_element` as `FilterResult`, because every call
/// inside them reaches no walk that can fail. The port's `supportsAction` walks
/// to a filtered parent and `filteredChildren` walks the tree, and both report
/// `QueryError`, so all three return it and no caller has to invent a `catch`.
pub const NodeError = QueryError;

/// The filter every walk in this module reads, `AK/ios/src/filters.rs:8`.
///
/// `AK/ios/src/filters.rs:8` re-exports `accesskit_consumer::common_filter`
/// under the name `filter`, and both functions below hand that one to every walk
/// they make. The context is `null` because the common filter reads only the node.
fn commonFilter(context: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    std.debug.assert(context == null);
    return consumer.filter.commonFilter(node);
}

/// The `FilterFn` value over `commonFilter`.
pub const common_filter: FilterFn = .{ .context = null, .filter = commonFilter };

/// One tree node with the two answers `AK/ios/src/node.rs:102-122` gives it.
pub const NodeWrapper = struct {
    /// The node the answers are read from.
    node: NodeRef,

    /// A wrapper over `node`.
    pub fn init(node: NodeRef) NodeWrapper {
        return .{ .node = node };
    }

    /// Whether the node accepts an action that is not a scroll, at
    /// `AK/ios/src/node.rs:102-113`.
    ///
    /// The ten actions are upstream's and the order is upstream's, and the `or`
    /// chain is short-circuited the same way, so a node that accepts `Click`
    /// asks one question and a node that accepts none asks ten. `ScrollUp` and
    /// `ScrollDown` are absent because a scroll is answered by the scroll
    /// selector instead, at `AK/ios/src/node.rs:359-391`.
    pub fn hasNonScrollAction(self: NodeWrapper) NodeError!bool {
        const actions = [_]schema.Action{
            .click,
            .focus,
            .increment,
            .decrement,
            .expand,
            .collapse,
            .custom_action,
            .replace_selected_text,
            .set_text_selection,
            .set_value,
        };
        for (actions) |action| {
            if (try consumer.node_ref.predicates.supportsAction(self.node, action, common_filter)) {
                return true;
            }
        }
        return false;
    }

    /// Whether the node is a candidate for focus, at `AK/ios/src/node.rs:115-122`.
    ///
    /// The six tests are upstream's and the order is upstream's. `hasLabel` and
    /// `hasDescription` are the consumer's own predicates and walk the
    /// `labelled_by` contributors, so a node whose label comes from another node
    /// answers `true` here.
    pub fn canBeFocused(self: NodeWrapper) NodeError!bool {
        const strings = consumer.node_ref.strings;
        const properties = consumer.node_ref.properties;
        if (try strings.hasLabel(self.node)) return true;
        if (properties.toggled(self.node) != null) return true;
        if (try consumer.node_ref.set_state.hasValue(self.node)) return true;
        if (properties.numericValue(self.node) != null) return true;
        if (strings.hasDescription(self.node)) return true;
        return self.hasNonScrollAction();
    }
};

/// Whether `node` is an accessibility element rather than a container, at
/// `AK/ios/src/filters.rs:27-52`.
///
/// **The rule and why it exists.** A node with focusable children must not be an
/// accessibility element, or VoiceOver ignores the children. A node with its own
/// interaction semantics is always a leaf element, because its descendants
/// contribute to its label and exposing them separately lets VoiceOver focus the
/// label and skip the actionable parent. So a node that acts, that has a value or
/// a toggled state is an element whatever it holds below, and a node that only
/// holds labelling children is not.
///
/// The four steps are upstream's: run the common filter, return its answer unless
/// it includes the node, return `include` when the node acts or has a value,
/// return `exclude_node` when any filtered child can be focused or has filtered
/// children of its own, and return `include`.
pub fn filterForIsAccessibilityElement(node: NodeRef) NodeError!FilterResult {
    const common = try consumer.filter.commonFilter(node);
    if (common != .include) return common;

    const properties = consumer.node_ref.properties;
    const wrapper = NodeWrapper.init(node);
    if (try wrapper.hasNonScrollAction()) return .include;
    if (properties.toggled(node) != null) return .include;
    if (try consumer.node_ref.set_state.hasValue(node)) return .include;
    if (properties.numericValue(node) != null) return .include;

    var cursor = try consumer.node_ref.hierarchy.filteredChildren(node, common_filter);
    while (try cursor.next()) |child| {
        const child_wrapper = NodeWrapper.init(child);
        if (try child_wrapper.canBeFocused()) return .exclude_node;
        var grandchildren = try consumer.node_ref.hierarchy.filteredChildren(
            child,
            common_filter,
        );
        if (try grandchildren.next() != null) return .exclude_node;
    }
    return .include;
}

// --- tests ----------------------------------------------------------------------

/// One node of the fixture tree the tests walk.
const Spec = struct {
    /// The identifier inside the root tree.
    local: u64,
    /// The role the node declares.
    role: schema.Role = .generic_container,
    /// The children of the node, in order.
    children: []const u64 = &.{},
    /// The label the node carries, or none.
    label: ?[]const u8 = null,
    /// The description the node carries, or none.
    description: ?[]const u8 = null,
    /// The value the node carries, or none.
    value: ?[]const u8 = null,
    /// The toggled state the node carries, or none.
    toggled: ?schema.Toggled = null,
    /// The numeric value the node carries, or none.
    numeric_value: ?f64 = null,
    /// The actions the node declares it supports.
    actions: []const schema.Action = &.{},
};

/// Builds the tree `specs` describes, rooted at `root_local`.
fn buildTree(gpa: std.mem.Allocator, root_local: u64, specs: []const Spec) !consumer.tree.Tree {
    var update: schema.TreeUpdate = .{};
    errdefer update.deinit(gpa);
    for (specs) |spec| {
        var node = schema.Node.init(gpa, spec.role);
        if (spec.label) |text| try schema.strings.setLabel(&node.properties, text);
        if (spec.description) |text| {
            try schema.strings.setDescription(&node.properties, text);
        }
        if (spec.value) |text| try schema.strings.setValue(&node.properties, text);
        if (spec.toggled) |state| try schema.enums.setToggled(&node.properties, state);
        if (spec.numeric_value) |number| {
            try schema.numbers.setNumericValue(&node.properties, number);
        }
        for (spec.actions) |action| node.addAction(action);
        const child_ids = try gpa.alloc(schema.NodeId, spec.children.len);
        defer gpa.free(child_ids);
        for (spec.children, 0..) |child, slot| child_ids[slot] = .{ .value = child };
        try schema.ids_props.setChildren(&node.properties, child_ids);
        try update.pushNode(gpa, .{ .value = spec.local }, node);
    }
    update.tree = schema.TreeInfo.init(.{ .value = root_local });
    update.focus = .{ .value = root_local };
    const built = consumer.tree.Tree.init(gpa, update, true);
    // `Tree.init` released the update on every path, so the binding is emptied
    // before the `errdefer` above can run a second release over freed memory.
    update = .{};
    return built catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.TreeRejectedTheUpdate,
    };
}

/// The node `local` in `tree`, or an error rather than a trap.
fn nodeOf(tree: *const consumer.tree.Tree, local: u64) !NodeRef {
    const state = tree.stateOf();
    return state.nodeById(state.rootId().withSameTree(.{ .value = local })) orelse
        error.MissingNode;
}

test "a node that acts answers a non-scroll action and a label answers focus" {
    // `AK/ios/src/node.rs:103-112` is the chain of ten and `:116-121` the chain
    // of six. The fixture gives one node each action in turn, so the short
    // circuit is what keeps the question count low.
    const gpa = testing.allocator;
    const actions = [_]schema.Action{
        .click,
        .focus,
        .increment,
        .decrement,
        .expand,
        .collapse,
        .custom_action,
        .replace_selected_text,
        .set_text_selection,
        .set_value,
    };
    var specs = std.ArrayList(Spec).empty;
    defer specs.deinit(gpa);
    try specs.append(gpa, .{
        .local = 1,
        .role = .window,
        .children = blk: {
            var ids: [11]u64 = undefined;
            for (&ids, 0..) |*slot, index| slot.* = @intCast(2 + index);
            break :blk ids[0..];
        },
    });
    for (actions, 0..) |action, index| {
        try specs.append(gpa, .{
            .local = @intCast(2 + index),
            .role = .button,
            .actions = &.{action},
        });
    }
    // A thirteenth node accepts nothing at all.
    try specs.append(gpa, .{ .local = 12, .role = .generic_container });
    var tree = try buildTree(gpa, 1, specs.items);
    defer tree.deinit();

    for (actions, 0..) |_, index| {
        const node = try nodeOf(&tree, @intCast(2 + index));
        try testing.expect(try NodeWrapper.init(node).hasNonScrollAction());
        // Every one of them acts, so every one of them is a focus candidate even
        // with no label, no value and no toggled state.
        try testing.expect(try NodeWrapper.init(node).canBeFocused());
    }
    const inert = try nodeOf(&tree, 12);
    try testing.expect(!try NodeWrapper.init(inert).hasNonScrollAction());
    try testing.expect(!try NodeWrapper.init(inert).canBeFocused());
}

test "each of the six focus tests answers on its own" {
    // `AK/ios/src/node.rs:116-121` short-circuits at the first test that answers,
    // so a fixture with one property at a time reaches one test each.
    const gpa = testing.allocator;
    const specs = [_]Spec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3, 4, 5, 6, 7, 8 } },
        .{ .local = 2, .role = .label, .label = "name" },
        .{ .local = 3, .role = .switch_, .toggled = .true_ },
        .{ .local = 4, .role = .text_input, .value = "typed" },
        .{ .local = 5, .role = .slider, .numeric_value = 2 },
        .{ .local = 6, .role = .generic_container, .description = "hint" },
        .{ .local = 7, .role = .button, .actions = &.{.click} },
        // The seventh node answers none of the six, so it is the `false` arm.
        .{ .local = 8, .role = .generic_container },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    const expected = [_]bool{ true, true, true, true, true, true, false };
    for (expected, 0..) |wanted, index| {
        const node = try nodeOf(&tree, @intCast(2 + index));
        try testing.expectEqual(wanted, try NodeWrapper.init(node).canBeFocused());
    }
}

test "a node with focusable children is not an element and a node that acts is" {
    // `AK/ios/src/filters.rs:33-49`. The container holds a labelled child, so it
    // is not an element; the button is one because it acts, whatever it holds.
    // Every container is a `pane` and not a `generic_container`, because the
    // common filter drops a `generic_container` before this filter reads a
    // child, and the three answers below are about the child walk.
    const gpa = testing.allocator;
    const specs = [_]Spec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3, 4 } },
        .{ .local = 2, .role = .pane, .children = &.{5} },
        .{ .local = 3, .role = .pane, .children = &.{6} },
        .{ .local = 4, .role = .pane, .children = &.{7} },
        .{ .local = 5, .role = .label, .label = "name" },
        .{ .local = 6, .role = .button, .actions = &.{.click} },
        .{ .local = 7, .role = .image },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    // Node 2 holds a labelled child, so VoiceOver must be able to reach it.
    try testing.expectEqual(
        FilterResult.exclude_node,
        try filterForIsAccessibilityElement(try nodeOf(&tree, 2)),
    );
    // Node 3 holds a button, which can be focused, so it is a container too.
    try testing.expectEqual(
        FilterResult.exclude_node,
        try filterForIsAccessibilityElement(try nodeOf(&tree, 3)),
    );
    // Node 4 holds a leaf image with no label and no action, so the image only
    // labels its parent and the parent stays the element.
    try testing.expectEqual(
        FilterResult.include,
        try filterForIsAccessibilityElement(try nodeOf(&tree, 4)),
    );
}

test "the common filter answers first and its answer is returned unchanged" {
    // `AK/ios/src/filters.rs:28-31` is the early return. A node the common filter
    // drops is dropped by this one whatever it holds below, so the fixture gives
    // the dropped node a focusable child.
    const gpa = testing.allocator;
    const specs = [_]Spec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3 } },
        .{ .local = 2, .role = .generic_container, .children = &.{4} },
        .{ .local = 3, .role = .generic_container },
        .{ .local = 4, .role = .label, .label = "name" },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    // The container is a `generic_container`, so the common filter drops it, and
    // the focusable child it holds never reaches the child walk.
    const container = try nodeOf(&tree, 2);
    const common = try consumer.filter.commonFilter(container);
    try testing.expectEqual(FilterResult.exclude_node, common);
    try testing.expectEqual(
        common,
        try filterForIsAccessibilityElement(container),
    );
    // The root keeps the label below its two dropped containers, because the
    // cursor descends into a child the common filter answers `exclude_node`
    // for, so the root walks a focusable child and is not an element either.
    try testing.expectEqual(
        FilterResult.exclude_node,
        try filterForIsAccessibilityElement(try nodeOf(&tree, 1)),
    );
}

test "a node with a value or a toggled state is an element whatever it holds" {
    // `AK/ios/src/filters.rs:34-40` returns `include` before the child walk, so a
    // container that acts is an element and its children are collapsed into its
    // label, which is what the doc comment at `filters.rs:17-22` says.
    const gpa = testing.allocator;
    const specs = [_]Spec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3, 4, 5 } },
        .{ .local = 2, .role = .pane, .children = &.{6}, .value = "all" },
        .{ .local = 3, .role = .switch_, .children = &.{7}, .toggled = .false_ },
        .{ .local = 4, .role = .slider, .numeric_value = 3 },
        .{ .local = 5, .role = .button, .children = &.{8}, .actions = &.{.click} },
        .{ .local = 6, .role = .label, .label = "name" },
        .{ .local = 7, .role = .label, .label = "off" },
        .{ .local = 8, .role = .label, .label = "press" },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    for ([_]u64{ 2, 3, 4, 5 }) |local| {
        try testing.expectEqual(
            FilterResult.include,
            try filterForIsAccessibilityElement(try nodeOf(&tree, local)),
        );
    }
}

test "the filter of this module is the common filter over the same tree" {
    // `AK/ios/src/filters.rs:8` names one filter and both functions use it. The
    // two values are built in two modules, so this compares their answers node by
    // node rather than asserting that two declarations match.
    const gpa = testing.allocator;
    const specs = [_]Spec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3, 4, 5 } },
        .{ .local = 2, .role = .button, .actions = &.{.click} },
        .{ .local = 3, .role = .label, .label = "name" },
        .{ .local = 4, .role = .image },
        .{ .local = 5, .role = .generic_container, .children = &.{6} },
        .{ .local = 6, .role = .label, .label = "inner" },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    for ([_]u64{ 1, 2, 3, 4, 5, 6 }) |local| {
        const node = try nodeOf(&tree, local);
        try testing.expectEqual(
            try consumer.filter.commonFilter(node),
            try common_filter.call(node),
        );
    }
}
