//! The container accessors: the index paths that order a node among its
//! siblings, the selection container above it, and the item-like nodes below
//! it.
//!
//! Upstream `accesskit_consumer/src/node.rs:920-955` and `:997-1073`. Every
//! operation is a free function whose first parameter is the `NodeRef`, because
//! `consumer/node_id.zig` declares that struct and no other file in the layer
//! may carry its methods.
//!
//! **Every operation here walks, so every operation here is bounded.** The walks
//! take `treeWalkStepBound` from `consumer/tree_state.zig`, the bound
//! `docs/33` section 7 gives the ancestor and child walks, and each one answers
//! `error.TreeCycle` when it runs out. The derivation is the one in that
//! section: each step moves to a different node, the state holds at most
//! `node_count` nodes, and a cycle repeats a node, so the count catches the
//! repeat. `docs/33` section 7.1 names `node.rs:1004`, `:1018` and `:1037`
//! among the sites that take the bound. The two composed walks at `:1055` and
//! `:1064` are the same shape of walk and take the same bound, because an
//! unbounded walk over user data is a review finding whether or not the record
//! lists it.
//!
//! **The error set is `QueryError`, not `Allocator.Error`.** `docs/33` section 8
//! writes `Allocator.Error!ArrayList(usize)` for the two index paths. Section 7
//! lists `node.rs:1004` as an `error.TreeCycle` site, and `QueryError` carries
//! `OutOfMemory`, so the wider set is what the port returns and every caller the
//! table imagined still compiles.
//!
//! **`items` and `selectionContainer` compose two rules, and a closure is not
//! how it composes them.** Upstream builds a closure that wraps the caller's
//! filter with one extra rule and hands it to `filtered_children` or
//! `filtered_parent`. Rule C2 of `docs/33` section 3 forbids a closure here, and
//! a `FilterFn` carries a `context` rather than a capture, so the composed rule
//! is applied inside the walk instead. That is also the only place it can be
//! applied: an `exclude_node` answer means the walk descends into that node, so
//! a rule applied after the walk would reach a different set.
//!
//! **`items` returns the whole sequence rather than a lazy iterator.** Upstream
//! returns a double-ended iterator whose constructor already runs two complete
//! depth-first passes to find its front and its back, so upstream pays for the
//! subtree before the caller takes one element. Collecting the sequence once
//! costs one pass instead of two, and a caller that wants the end of the list
//! reads it backward from the returned list.
//!
//! **What this module does not do.** It opens no file, reads no clock and
//! reaches no runtime. The results that own memory take `gpa` first per
//! `AGENTS.md:99` and the caller releases them with the same `gpa`; every other
//! result borrows the state and dies with it. It declares no property accessor.
//!
//! **Port record.**
//!
//! * `node.rs:920-936`, `is_item_like`, and `node.rs:938-955`,
//!   `is_container_with_selectable_children`, are declared here rather than with
//!   the other role matches in `node_ref/predicates.zig`. Their only callers are
//!   `items` and `selectionContainer` below, and the edge that decides it is the
//!   one `docs/33` section 3 forbids: `containers.zig` may not import
//!   `node_ref/set_state.zig`, because that closes `containers` to `set_state`
//!   to `text/query` to `containers`. They are role matches over
//!   `properties.role` and nothing else, so a reader who finds one in this file
//!   should not move it.
//! * `node.rs:1013-1030`, `first_filtered_child`, and `node.rs:1032-1049`,
//!   `last_filtered_child`, are not declared here. `iterators/children.zig`
//!   already carries them, because `filtered_children` is built from them, and
//!   this file imports them from there rather than keeping a second copy.
//! * `node.rs:1076-1101`, `SpacePrefixingWriter`, is deleted and the record
//!   lives in `node_ref/strings.zig`, where the write is.
//!
//! **Interfaces this file assumes**, because a sibling owns each one:
//! `node_ref/hierarchy.zig` supplies `parent`, `parentAndIndex` and `children`;
//! `node_ref/properties.zig` supplies `role`; `iterators/children.zig` supplies
//! `firstFilteredChild`, `lastFilteredChild` and `FilteredChildrenIterator`;
//! and `consumer/filter.zig` supplies `FilterFn` and `FilterResult`.

const std = @import("std");
const schema = @import("../../schema/root.zig");
const node_id = @import("../node_id.zig");
const filter = @import("../filter.zig");
const tree_index = @import("../tree_index.zig");
const tree_state = @import("../tree_state.zig");
const children_iterator = @import("../iterators/children.zig");
const hierarchy = @import("hierarchy.zig");
const properties = @import("properties.zig");

const NodeRef = node_id.NodeRef;
const FullNodeId = tree_index.FullNodeId;
const TreeState = tree_state.TreeState;
const QueryError = tree_state.QueryError;
const FilterFn = filter.FilterFn;
const FilterResult = filter.FilterResult;
const Role = schema.Role;

// --- role predicates, node.rs:920-955 -------------------------------------------

/// Whether `node` is one a container presents as a selectable item.
///
/// Upstream `is_item_like`, `node.rs:920-936`. A role match and nothing else,
/// so it never fails and never allocates.
pub fn isItemLike(node: NodeRef) bool {
    return switch (properties.role(node)) {
        .article,
        .comment,
        .list_item,
        .menu_item,
        .menu_item_radio,
        .tab,
        .menu_item_check_box,
        .tree_item,
        .list_box_option,
        .menu_list_option,
        .radio_button,
        .term,
        => true,
        else => false,
    };
}

/// Whether `node` is a container whose children the user picks one of.
///
/// Upstream `is_container_with_selectable_children`, `node.rs:938-955`. A role
/// match and nothing else, so it never fails and never allocates.
pub fn isContainerWithSelectableChildren(node: NodeRef) bool {
    return switch (properties.role(node)) {
        .combo_box,
        .editable_combo_box,
        .grid,
        .list_box,
        .list_grid,
        .menu,
        .menu_bar,
        .menu_list_popup,
        .radio_group,
        .tab_list,
        .toolbar,
        .tree,
        .tree_grid,
        => true,
        else => false,
    };
}

// --- index paths, node.rs:997-1011 ----------------------------------------------

/// The index of `node` in every ancestor's `children` list, from the root down.
///
/// Upstream `index_path`, `node.rs:997-999`. The root answers an empty list,
/// because the root is in no `children` list.
///
/// **Bound.** The walk climbs one parent at a time, so it takes
/// `treeWalkStepBound`. `docs/33` section 7.1 names `node.rs:1004`, the loop
/// `relativeIndexPath` owns, as the site, and this delegates to it. A cyclic
/// parent chain answers `error.TreeCycle`. An ancestor that is not on the chain
/// is not reachable from here, because this always names the state root.
pub fn indexPath(gpa: std.mem.Allocator, node: NodeRef) QueryError!std.ArrayList(usize) {
    return try relativeIndexPath(gpa, node, node.tree_state.rootId());
}

/// The index of `node` in every ancestor's `children` list between `ancestor_id`
/// and `node`, rootmost ancestor first.
///
/// Upstream `relative_index_path`, `node.rs:1001-1011`. A node equal to
/// `ancestor_id` answers an empty list.
///
/// **`error.NoSuchNode`** when the walk reaches a node with no parent before it
/// reaches `ancestor_id`, which is upstream's `.unwrap()` at `node.rs:1005`: it
/// fires when `ancestor_id` is not an ancestor of `node`, most often because it
/// names another tree. **`error.TreeCycle`** when the parent chain repeats and
/// the bound runs out first.
///
/// Returns a buffer the caller owns and releases with the same `gpa`. On any
/// error nothing is allocated and there is nothing to release.
pub fn relativeIndexPath(
    gpa: std.mem.Allocator,
    node: NodeRef,
    ancestor_id: FullNodeId,
) QueryError!std.ArrayList(usize) {
    var path: std.ArrayList(usize) = .empty;
    errdefer path.deinit(gpa);
    var current = node;
    // Bounded by `treeWalkStepBound`: one step per ancestor, and a chain longer
    // than the node count repeats a node, which is a cycle.
    var budget = walkStepBudget(node);
    while (!std.meta.eql(current.id(), ancestor_id)) {
        if (budget == 0) return error.TreeCycle;
        budget -= 1;
        const step = hierarchy.parentAndIndex(current) orelse return error.NoSuchNode;
        try path.append(gpa, step.index);
        current = step.parent;
    }
    std.mem.reverse(usize, path.items);
    return path;
}

/// The steps the walks in this module may take before they answer
/// `error.TreeCycle`.
///
/// The bound is `treeWalkStepBound` from `consumer/tree_state.zig`, and the
/// derivation is `docs/33` section 7's: each step moves to a different node, the
/// state holds at most `node_count` nodes, and a cycle repeats a node, so the
/// count catches the repeat. The count is read once at entry, because the map
/// does not grow while a walk runs.
pub fn walkStepBudget(node: NodeRef) usize {
    return tree_state.treeWalkStepBound(node.tree_state.nodes.count());
}

// --- composed walks, node.rs:1051-1073 -------------------------------------------

/// The nearest ancestor of `node` that both passes `filter` and is a container
/// with selectable children, or `null` when there is none.
///
/// Upstream `selection_container`, `node.rs:1051-1062`. The upstream closure
/// turns an `include` answer for a node that is not a container into
/// `exclude_node`, so the walk keeps climbing, and it leaves every other answer
/// alone. A node with no parent answers `null` without asking the filter.
///
/// **Bound.** One climb per step, so the walk takes `treeWalkStepBound`.
pub fn selectionContainer(node: NodeRef, filter_fn: FilterFn) QueryError!?NodeRef {
    var budget = walkStepBudget(node);
    var current = hierarchy.parent(node) orelse return null;
    while (budget > 0) : (budget -= 1) {
        switch (try filter_fn.call(current)) {
            .include => {
                if (isContainerWithSelectableChildren(current)) return current;
            },
            .exclude_node, .exclude_subtree => {},
        }
        current = hierarchy.parent(current) orelse return null;
    }
    return error.TreeCycle;
}

/// The item-like nodes in `node`'s subtree that `filter` includes, in depth-first
/// pre-order.
///
/// Upstream `items`, `node.rs:1064-1073`. `filter` decides what the walk may
/// enter, and `isItemLike` decides what the sequence keeps, so a node the filter
/// includes but that is not item-like contributes nothing while its children are
/// still searched.
///
/// Allocates, so it takes `gpa` first. Returns a buffer the caller owns and
/// releases with the same `gpa`. **`error.TreeCycle`** when the bound runs out,
/// and on that error nothing is allocated.
///
/// **Bound.** One descent per answer that opens a child, which is every
/// `exclude_node` and every `include` for a node that is not item-like, so the
/// walk takes `treeWalkStepBound`.
pub fn items(
    gpa: std.mem.Allocator,
    node: NodeRef,
    filter_fn: FilterFn,
) QueryError!std.ArrayList(NodeRef) {
    var out: std.ArrayList(NodeRef) = .empty;
    errdefer out.deinit(gpa);
    try collectItemsWithin(gpa, node, filter_fn, &out, walkStepBudget(node));
    return out;
}

/// One level of `items`, with the budget it has left.
fn collectItemsWithin(
    gpa: std.mem.Allocator,
    node: NodeRef,
    filter_fn: FilterFn,
    out: *std.ArrayList(NodeRef),
    budget: usize,
) QueryError!void {
    if (budget == 0) return error.TreeCycle;
    var children = hierarchy.children(node);
    while (children.next()) |child| {
        switch (try filter_fn.call(child)) {
            // Upstream's composed filter at `node.rs:1068-1072` answers
            // `exclude_node` for a node the caller's filter includes but that
            // is not item-like, and `exclude_node` is the answer that opens the
            // node and searches below it. So the `.include` arm descends as
            // well, and dropping such a node without opening it would lose
            // every item-like node underneath it.
            .include => if (isItemLike(child)) {
                try out.append(gpa, child);
            } else {
                try collectItemsWithin(gpa, child, filter_fn, out, budget - 1);
            },
            .exclude_node => try collectItemsWithin(gpa, child, filter_fn, out, budget - 1),
            .exclude_subtree => {},
        }
    }
}

// --- tests ----------------------------------------------------------------------

const testing = std.testing;
const test_allocator = testing.allocator;

const Node = schema.Node;
const NodeId = schema.NodeId;
const ParentAndIndex = tree_index.ParentAndIndex;

fn nodeId(raw: u64) NodeId {
    return .{ .value = raw };
}

fn fullNodeId(id: NodeId) FullNodeId {
    return FullNodeId.init(id, .init(0));
}

fn parentAndIndex(parent: NodeId, index: usize) ParentAndIndex {
    return .{ .parent_id = fullNodeId(parent), .index = index };
}

/// A `TreeState` with node 1 as its root and its focus. Every fixture puts the
/// nodes it uses, so the maps hold no other entry.
fn testState() TreeState {
    return .{
        .root_id = fullNodeId(nodeId(1)),
        .focus_id = fullNodeId(nodeId(1)),
    };
}

/// Adds one node under `id`. The state takes ownership of `node`, so the caller
/// must not release it. `parent` is `null` for a root.
fn put(state: *TreeState, id: NodeId, parent: ?ParentAndIndex, node: Node) !void {
    try state.nodes.put(test_allocator, fullNodeId(id), .{
        .parent_and_index = parent,
        .data = node,
    });
}

/// The `NodeRef` for `id`. Every fixture puts the node in first, so this never
/// answers `null` and a failed expectation is the fixture's own defect.
fn refOf(state: *TreeState, id: NodeId) !NodeRef {
    return NodeRef.init(state, fullNodeId(id)) orelse error.NodeMissingFromFixture;
}

/// The index path from `id` up to `ancestor`, allocated with the test allocator
/// so a call site in a test stays on one line.
fn pathBetween(state: *TreeState, id: NodeId, ancestor: NodeId) !std.ArrayList(usize) {
    return relativeIndexPath(test_allocator, try refOf(state, id), fullNodeId(ancestor));
}

/// A filter that lets every node through.
fn includeAll(_: ?*anyopaque, _: NodeRef) QueryError!FilterResult {
    return .include;
}

/// A filter that blocks every node and every subtree, so a walk using it never
/// descends.
fn excludeAll(_: ?*anyopaque, _: NodeRef) QueryError!FilterResult {
    return .exclude_subtree;
}

/// A filter that keeps a `list_box_option` and drops every other branch whole,
/// so a walk using it never descends past a node that is not an option.
fn optionOnly(_: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    return if (node.data().role == .list_box_option) .include else .exclude_subtree;
}

/// A filter that descends through everything except a `list_box_option`, so a
/// walk using it never stops on a well-formed tree and only the bound can stop
/// it on a cyclic one.
fn descendPastOptions(_: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    return if (node.data().role == .list_box_option) .include else .exclude_node;
}

test "indexPath is empty for the root and ordered for a descendant" {
    var state = testState();
    defer state.deinit(test_allocator);
    const root = Node.init(test_allocator, .list_box);
    try put(&state, nodeId(1), null, root);
    var middle = Node.init(test_allocator, .list_box);
    try schema.ids_props.setChildren(&middle.properties, &.{ nodeId(3), nodeId(4) });
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), middle);
    const first_child = Node.init(test_allocator, .list_box_option);
    try put(&state, nodeId(3), parentAndIndex(nodeId(2), 0), first_child);
    const second_child = Node.init(test_allocator, .list_box_option);
    try put(&state, nodeId(4), parentAndIndex(nodeId(2), 1), second_child);

    var root_path = try indexPath(test_allocator, try refOf(&state, nodeId(1)));
    defer root_path.deinit(test_allocator);
    try testing.expectEqual(@as(usize, 0), root_path.items.len);

    var child_path = try indexPath(test_allocator, try refOf(&state, nodeId(4)));
    defer child_path.deinit(test_allocator);
    try testing.expectEqual(@as(usize, 2), child_path.items.len);
    try testing.expectEqual(@as(usize, 0), child_path.items[0]);
    try testing.expectEqual(@as(usize, 1), child_path.items[1]);
}

test "relativeIndexPath stops at the named ancestor" {
    var state = testState();
    defer state.deinit(test_allocator);
    const root = Node.init(test_allocator, .list_box);
    try put(&state, nodeId(1), null, root);
    const middle = Node.init(test_allocator, .list_box);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), middle);
    const leaf = Node.init(test_allocator, .list_box_option);
    try put(&state, nodeId(3), parentAndIndex(nodeId(2), 1), leaf);

    var whole = try pathBetween(&state, nodeId(3), nodeId(1));
    defer whole.deinit(test_allocator);
    try testing.expectEqual(@as(usize, 2), whole.items.len);

    var near = try pathBetween(&state, nodeId(3), nodeId(2));
    defer near.deinit(test_allocator);
    try testing.expectEqual(@as(usize, 1), near.items.len);
    try testing.expectEqual(@as(usize, 1), near.items[0]);

    var self = try pathBetween(&state, nodeId(3), nodeId(3));
    defer self.deinit(test_allocator);
    try testing.expectEqual(@as(usize, 0), self.items.len);
}

test "relativeIndexPath answers error.NoSuchNode for an ancestor off the chain" {
    var state = testState();
    defer state.deinit(test_allocator);
    const root = Node.init(test_allocator, .list_box);
    try put(&state, nodeId(1), null, root);
    const leaf = Node.init(test_allocator, .list_box_option);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), leaf);

    try testing.expectError(error.NoSuchNode, pathBetween(&state, nodeId(2), nodeId(9)));
}

test "relativeIndexPath walks one step under the bound and answers it at one over" {
    var state = testState();
    defer state.deinit(test_allocator);
    // Two nodes whose parents name each other, so the walk needs three steps to
    // come back to where it started and never reaches the ancestor at all.
    const first = Node.init(test_allocator, .list_box);
    try put(&state, nodeId(1), parentAndIndex(nodeId(2), 0), first);
    const second = Node.init(test_allocator, .list_box);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), second);

    // The bound is the node count, which is two, and the cyclic walk needs one
    // step more than that before it could stop.
    try testing.expectEqual(@as(usize, 2), walkStepBudget(try refOf(&state, nodeId(1))));
    try testing.expectError(error.TreeCycle, pathBetween(&state, nodeId(1), nodeId(9)));

    // The positive half: one fewer step than the bound reaches the root.
    var straight = testState();
    defer straight.deinit(test_allocator);
    const chain_root = Node.init(test_allocator, .list_box);
    try put(&straight, nodeId(1), null, chain_root);
    const chain_middle = Node.init(test_allocator, .list_box);
    try put(&straight, nodeId(2), parentAndIndex(nodeId(1), 0), chain_middle);
    const chain_leaf = Node.init(test_allocator, .list_box_option);
    try put(&straight, nodeId(3), parentAndIndex(nodeId(2), 0), chain_leaf);

    var path = try pathBetween(&straight, nodeId(3), nodeId(1));
    defer path.deinit(test_allocator);
    try testing.expectEqual(@as(usize, 2), path.items.len);
}

test "isItemLike and isContainerWithSelectableChildren answer their role sets" {
    var state = testState();
    defer state.deinit(test_allocator);
    const option = Node.init(test_allocator, .list_box_option);
    try put(&state, nodeId(1), null, option);
    const container = Node.init(test_allocator, .list_box);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), container);
    const paragraph = Node.init(test_allocator, .paragraph);
    try put(&state, nodeId(3), parentAndIndex(nodeId(2), 0), paragraph);

    try testing.expect(isItemLike(try refOf(&state, nodeId(1))));
    try testing.expect(!isItemLike(try refOf(&state, nodeId(3))));
    try testing.expect(isContainerWithSelectableChildren(try refOf(&state, nodeId(2))));
    try testing.expect(!isContainerWithSelectableChildren(try refOf(&state, nodeId(3))));
}

test "firstFilteredChild descends through exclude_node and stops at include" {
    var state = testState();
    defer state.deinit(test_allocator);
    var root = Node.init(test_allocator, .list_box);
    try schema.ids_props.setChildren(&root.properties, &.{nodeId(2)});
    try put(&state, nodeId(1), null, root);
    var branch = Node.init(test_allocator, .generic_container);
    try schema.ids_props.setChildren(&branch.properties, &.{nodeId(3)});
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), branch);
    const leaf = Node.init(test_allocator, .list_box_option);
    try put(&state, nodeId(3), parentAndIndex(nodeId(2), 0), leaf);

    // `optionOnly` answers `exclude_subtree` for the branch, which would drop
    // node 3 along with it. The descent this test names needs `exclude_node`,
    // which opens the branch and keeps everything below it.
    const found = (try children_iterator.firstFilteredChild(
        try refOf(&state, nodeId(1)),
        .{ .context = null, .filter = descendPastOptions },
    )) orelse return error.ExpectedAnOption;
    try testing.expectEqual(nodeId(3), found.id().local);
}

test "firstFilteredChild answers null when the filter blocks every subtree" {
    var state = testState();
    defer state.deinit(test_allocator);
    var root = Node.init(test_allocator, .list_box);
    try schema.ids_props.setChildren(&root.properties, &.{nodeId(2)});
    try put(&state, nodeId(1), null, root);
    const leaf = Node.init(test_allocator, .list_box_option);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), leaf);

    const found = try children_iterator.firstFilteredChild(
        try refOf(&state, nodeId(1)),
        .{ .context = null, .filter = excludeAll },
    );
    try testing.expect(found == null);
}

test "firstFilteredChild answers error.TreeCycle on a cyclic subtree" {
    var state = testState();
    defer state.deinit(test_allocator);
    var first = Node.init(test_allocator, .list_box);
    try schema.ids_props.setChildren(&first.properties, &.{nodeId(2)});
    try put(&state, nodeId(1), null, first);
    var second = Node.init(test_allocator, .list_box);
    try schema.ids_props.setChildren(&second.properties, &.{nodeId(1)});
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), second);

    // The filter descends through every node, so the walk needs one step more
    // than the node count before it could stop.
    try testing.expectError(error.TreeCycle, children_iterator.firstFilteredChild(
        try refOf(&state, nodeId(1)),
        .{ .context = null, .filter = descendPastOptions },
    ));
}

test "lastFilteredChild answers the node the forward walk would miss" {
    var state = testState();
    defer state.deinit(test_allocator);
    var root = Node.init(test_allocator, .list_box);
    try schema.ids_props.setChildren(&root.properties, &.{ nodeId(2), nodeId(3) });
    try put(&state, nodeId(1), null, root);
    const first_child = Node.init(test_allocator, .generic_container);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), first_child);
    const second_child = Node.init(test_allocator, .list_box_option);
    try put(&state, nodeId(3), parentAndIndex(nodeId(1), 1), second_child);

    const found = (try children_iterator.lastFilteredChild(
        try refOf(&state, nodeId(1)),
        .{ .context = null, .filter = optionOnly },
    )) orelse return error.ExpectedAnOption;
    try testing.expectEqual(nodeId(3), found.id().local);
}

test "lastFilteredChild answers error.TreeCycle on a cyclic subtree" {
    var state = testState();
    defer state.deinit(test_allocator);
    var first = Node.init(test_allocator, .list_box);
    try schema.ids_props.setChildren(&first.properties, &.{nodeId(2)});
    try put(&state, nodeId(1), null, first);
    var second = Node.init(test_allocator, .list_box);
    try schema.ids_props.setChildren(&second.properties, &.{nodeId(1)});
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), second);

    try testing.expectError(error.TreeCycle, children_iterator.lastFilteredChild(
        try refOf(&state, nodeId(1)),
        .{ .context = null, .filter = descendPastOptions },
    ));
}

test "selectionContainer finds the nearest container with selectable children" {
    var state = testState();
    defer state.deinit(test_allocator);
    const root = Node.init(test_allocator, .generic_container);
    try put(&state, nodeId(1), null, root);
    const outer = Node.init(test_allocator, .toolbar);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), outer);
    const inner = Node.init(test_allocator, .list_box);
    try put(&state, nodeId(3), parentAndIndex(nodeId(2), 0), inner);
    const leaf = Node.init(test_allocator, .list_box_option);
    try put(&state, nodeId(4), parentAndIndex(nodeId(3), 0), leaf);

    const found = (try selectionContainer(
        try refOf(&state, nodeId(4)),
        .{ .context = null, .filter = includeAll },
    )) orelse return error.ExpectedAContainer;
    try testing.expectEqual(nodeId(3), found.id().local);
}

test "selectionContainer skips a container the filter rejects and stops at the root" {
    var state = testState();
    defer state.deinit(test_allocator);
    const root = Node.init(test_allocator, .generic_container);
    try put(&state, nodeId(1), null, root);
    const container = Node.init(test_allocator, .list_box);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), container);
    const leaf = Node.init(test_allocator, .list_box_option);
    try put(&state, nodeId(3), parentAndIndex(nodeId(2), 0), leaf);

    const blocked = try selectionContainer(
        try refOf(&state, nodeId(3)),
        .{ .context = null, .filter = excludeAll },
    );
    try testing.expect(blocked == null);

    // A node with no parent answers null without asking the filter at all.
    const at_root = try selectionContainer(
        try refOf(&state, nodeId(1)),
        .{ .context = null, .filter = includeAll },
    );
    try testing.expect(at_root == null);
}

test "selectionContainer answers error.TreeCycle on a cyclic parent chain" {
    var state = testState();
    defer state.deinit(test_allocator);
    // Neither node is a container with selectable children, so the walk never
    // stops at either of them and only the bound can stop it. A cycle of
    // qualifying containers answers the nearest one, as upstream does, and
    // never reaches the bound at all.
    const first = Node.init(test_allocator, .generic_container);
    try put(&state, nodeId(1), parentAndIndex(nodeId(2), 0), first);
    const second = Node.init(test_allocator, .generic_container);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), second);

    try testing.expectError(error.TreeCycle, selectionContainer(
        try refOf(&state, nodeId(1)),
        .{ .context = null, .filter = includeAll },
    ));
}

test "items keeps the item-like nodes and descends past the rest" {
    var state = testState();
    defer state.deinit(test_allocator);
    var root = Node.init(test_allocator, .list_box);
    try schema.ids_props.setChildren(&root.properties, &.{ nodeId(2), nodeId(4) });
    try put(&state, nodeId(1), null, root);
    var branch = Node.init(test_allocator, .generic_container);
    try schema.ids_props.setChildren(&branch.properties, &.{nodeId(3)});
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), branch);
    const nested_option = Node.init(test_allocator, .list_box_option);
    try put(&state, nodeId(3), parentAndIndex(nodeId(2), 0), nested_option);
    const option = Node.init(test_allocator, .list_box_option);
    try put(&state, nodeId(4), parentAndIndex(nodeId(1), 1), option);

    var found = try items(test_allocator, try refOf(&state, nodeId(1)), .{
        .context = null,
        .filter = includeAll,
    });
    defer found.deinit(test_allocator);
    try testing.expectEqual(@as(usize, 2), found.items.len);
    try testing.expectEqual(nodeId(3), found.items[0].id().local);
    try testing.expectEqual(nodeId(4), found.items[1].id().local);
}

test "items is empty when the filter blocks every subtree" {
    var state = testState();
    defer state.deinit(test_allocator);
    var root = Node.init(test_allocator, .list_box);
    try schema.ids_props.setChildren(&root.properties, &.{nodeId(2)});
    try put(&state, nodeId(1), null, root);
    const option = Node.init(test_allocator, .list_box_option);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), option);

    var found = try items(test_allocator, try refOf(&state, nodeId(1)), .{
        .context = null,
        .filter = excludeAll,
    });
    defer found.deinit(test_allocator);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "items answers error.TreeCycle on a cyclic subtree" {
    var state = testState();
    defer state.deinit(test_allocator);
    var first = Node.init(test_allocator, .list_box);
    try schema.ids_props.setChildren(&first.properties, &.{nodeId(2)});
    try put(&state, nodeId(1), null, first);
    var second = Node.init(test_allocator, .list_box);
    try schema.ids_props.setChildren(&second.properties, &.{nodeId(1)});
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), second);

    try testing.expectError(error.TreeCycle, items(
        test_allocator,
        try refOf(&state, nodeId(1)),
        .{ .context = null, .filter = descendPastOptions },
    ));
}
