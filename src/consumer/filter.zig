//! The two filters a platform applies before it shows the tree.
//!
//! Upstream `accesskit_consumer/src/filters.rs:11-101`. `commonFilter` is
//! `common_filter` at `:54`, `commonFilterWithRootException` is
//! `common_filter_with_root_exception` at `:94`, `FilterResult` is the enum at
//! `:10-15`, and the three helpers are `common_filter_base` at `:17`,
//! `common_filter_without_parent_checks` at `:39` and
//! `is_first_sibling_in_parent_bbox` at `:43`.
//!
//! **A filter answers for one node.** `include` keeps the node. `exclude_node`
//! drops the node and keeps everything below it. `exclude_subtree` drops the
//! node and everything below it. Upstream returns `ExcludeNode` for a graft
//! node and for the two roles `GenericContainer` and `TextRun`, because those
//! three are transparent and a caller must see what is inside them.
//!
//! **The filter reads state and reaches nothing else.** `commonFilter` takes a
//! `NodeRef` and every operation it performs is a read of the `TreeState` behind
//! that handle. Nothing here allocates, blocks or reads a clock, so no function
//! takes `gpa`, none takes `io` and none can name a platform handle. The filter
//! takes the state and not a `Tree`, a `TreeUpdate` or a platform context
//! because a second copy of the state is a second answer to the same question,
//! and an update between the two reads changes that answer under the caller.
//! One borrowed handle makes the answer a function of the tree the caller reads.
//!
//! **Walk 10, the parent chain of `filters.rs:60`.** Upstream recurses into
//! `common_filter(&parent)` with no bound. `docs/33` section 7 does not cover
//! that walk: section 7.1 rows 5 to 9 name `filteredParent`,
//! `deepestFirstChild`, `deepestLastChild`, `isDescendantOf`, `transform` and
//! `relativeTransform`, and the paragraph after that table names sixteen other
//! sites. `filters.rs:60` is on none of them, so this file names the bound
//! itself. `commonFilterStepBound` delegates to `treeWalkStepBound` from
//! `tree_state.zig`, because that function already carries this derivation:
//! each step moves to a different parent, the tree holds at most `node_count`
//! nodes, and a cycle repeats a node so the count catches the repeat. A step
//! past the bound is `error.TreeCycle`.
//!
//! **Which walk reports the cycle first.** `commonFilterBase` runs before the
//! recursion at every level, and the inherited `hidden` walk it calls uses the
//! same bound on the same chain. So a tree with a parent cycle answers
//! `error.TreeCycle` from that walk, and the check in `commonFilterWithin` is
//! the second line. Rule C7 wants the second line anyway, because the
//! termination argument of a walk belongs to the walk.
//!
//! **A callback in this project is a struct of a function pointer plus a
//! context pointer, never a bare function pointer.** Zig has no closure, so a
//! caller that needs per-call state has nowhere to put it otherwise, and a
//! bare `*const fn` cannot carry a lifetime or a state that outlives one call.
//! `schema/handlers.zig` gives the three application handlers that shape and
//! `FilterFn` gives it to a filter. Upstream passes a Rust closure at
//! `filters.rs:65` and `node.rs:189`, and a Rust closure captures by
//! reference, so the port names the same state and writes its lifetime down.
//!
//! **`docs/33` section 2's bare `*const fn (node: NodeRef) FilterResult` is
//! superseded on two counts.** The context field is the first. The error union
//! is the second: `commonFilter` is itself the filter upstream passes to
//! `filtered_children` and `filtered_parent`, at `iterators.rs:998`, `:1048`
//! and `:1055`, so it has to fit `FilterFn`. It calls `filteredParent` and the
//! two filtered sibling iterators, and every one of them reports
//! `error.TreeCycle`, so its return type is `QueryError!FilterResult`. A bare
//! `FilterResult` would force one of those errors to be discarded, and rule C8
//! bans that.
//!
//! **What this module does not own.** `NodeRef` is `node_id.zig`. The walks it
//! calls are `node_ref/hierarchy.zig`, `node_ref/properties.zig`,
//! `node_ref/predicates.zig`, `node_ref/geometry.zig` and `iterators/`. The
//! error set and the shared bound are `tree_state.zig`. This file declares the
//! filter vocabulary and the two filters, and nothing else.
//!
//! **Upstream items this file does not port.** The derive list at `filters.rs:10`
//! on `FilterResult` has no counterpart and needs none. A Zig enum copies by
//! assignment, compares with `==` and orders with `<` on its own, and no code
//! upstream hashes or formats a `FilterResult`: the sites that hold one are
//! `filters.rs:19`, `:23`, `:27`, `:33`, `:40`, `:60`, `:84` and `:91`.
//! `Debug` is the only derive with nothing to stand in for it.
//!
//! Two names changed shape. `is_first_sibling_in_parent_bbox` takes `impl
//! Iterator` upstream, and the port names the concrete `FilteredSiblingsIterator`
//! because both call sites pass that type and no other. The word `bbox` became
//! `box`, because the house rule does not abbreviate.

const std = @import("std");

const schema = @import("../schema/root.zig");

const tree_index = @import("tree_index.zig");
const tree_state = @import("tree_state.zig");
const node_id = @import("node_id.zig");
const hierarchy = @import("node_ref/hierarchy.zig");
const properties = @import("node_ref/properties.zig");
const predicates = @import("node_ref/predicates.zig");
const geometry = @import("node_ref/geometry.zig");
const following_iterators = @import("iterators/following.zig");

const FullNodeId = tree_index.FullNodeId;
const ParentAndIndex = tree_index.ParentAndIndex;
const NodeState = tree_state.NodeState;
const TreeState = tree_state.TreeState;
const QueryError = tree_state.QueryError;
const treeWalkStepBound = tree_state.treeWalkStepBound;
const NodeRef = node_id.NodeRef;
const FilteredSiblingsIterator = following_iterators.FilteredSiblingsIterator;

const Node = schema.Node;
const NodeId = schema.NodeId;
const Role = schema.Role;
const Rect = schema.Rect;

const assert = std.debug.assert;
const testing = std.testing;

/// The outcome of one filter test on one node. Upstream `filters.rs:10-15`.
///
/// Three tags, so `enum(u2)` and one byte.
pub const FilterResult = enum(u2) {
    /// Keep the node and everything below it.
    include,
    /// Drop the node. The node is transparent, so everything below it stays.
    exclude_node,
    /// Drop the node and everything below it.
    exclude_subtree,
};

/// A filter: the test one filtered walk applies to each node it visits.
///
/// `filter` runs on the calling thread, inside the walk that holds it, and it
/// receives `context` unchanged. The caller owns `context`, and it must stay
/// alive for every call the walk makes, because a walk calls the filter once
/// per node and keeps nothing after it returns. A callee that needs the state
/// after the call copies what it needs. `context` is `null` for a filter that
/// reads only the node.
pub const FilterFn = struct {
    /// State the callee reads, passed through unchanged and owned by the
    /// caller. `null` reaches the callee as `null`.
    context: ?*anyopaque,

    /// The test. Its first parameter is this type's `context` field.
    filter: *const fn (context: ?*anyopaque, node: NodeRef) QueryError!FilterResult,

    /// Applies `filter` to `node` with this value's `context`.
    ///
    /// `error.TreeCycle` means a walk the filter performed reached its bound.
    /// Nothing is written, so the state is the same before and after the call.
    pub fn call(self: FilterFn, node: NodeRef) QueryError!FilterResult {
        return self.filter(self.context, node);
    }
};

/// The steps `commonFilter` may take up the parent chain.
///
/// This is walk 10 of the layer and not one of the nine `docs/33` section 7.1
/// names, so the module doc carries the derivation and this function carries
/// the name. The value is `treeWalkStepBound` from `tree_state.zig`.
pub fn commonFilterStepBound(node_count: usize) usize {
    return treeWalkStepBound(node_count);
}

/// What one node decides on its own, or `null` when a walk decides it.
///
/// Upstream `common_filter_base` at `filters.rs:17-37`. `error.TreeCycle` comes
/// from the inherited `hidden` walk that `isHidden` performs on the same parent
/// chain, and it is the tag this module reports for a tree with a parent cycle.
fn commonFilterBase(node: NodeRef) QueryError!?FilterResult {
    // Focus outranks everything else, so a hidden node that holds the focus
    // stays visible. Upstream tests this at filters.rs:163.
    if (predicates.isFocused(node)) return .include;
    if (try properties.isHidden(node)) return .exclude_subtree;
    // A graft node is a transparent container pointing at a subtree, so it
    // leaves the filtered tree and its subtree does not. Upstream says so at
    // filters.rs:26.
    if (properties.isGraft(node)) return .exclude_node;
    const role = properties.role(node);
    if (role == .generic_container or role == .text_run) return .exclude_node;
    return null;
}

/// The filter the walk hands to `filteredParent` and to both sibling iterators.
///
/// Upstream `common_filter_without_parent_checks` at `filters.rs:39-41`. It
/// reads no parent, so it answers from `commonFilterBase` alone. The `context`
/// it declares is always `null`, and the assert makes a caller that supplies
/// state an error in a test rather than a silent discard in a release build.
fn commonFilterWithoutParentChecks(
    context: ?*anyopaque,
    node: NodeRef,
) QueryError!FilterResult {
    assert(context == null);
    return try commonFilterBase(node) orelse .include;
}

/// The filter the walk passes on, built once because it holds no state.
const without_parent_checks: FilterFn = .{
    .context = null,
    .filter = commonFilterWithoutParentChecks,
};

/// Whether the first of `siblings` sits inside `parent_box`.
///
/// Upstream `is_first_sibling_in_parent_bbox` at `filters.rs:43-52`. Only the
/// first sibling is tested, because one visible neighbour is enough to bring
/// the item on screen. A sibling with no box, or an empty cursor, answers
/// `false`, which is the ordinary outcome for the topmost child.
///
/// `error.TreeCycle` comes from the filtered sibling walk in `siblings`.
fn isFirstSiblingInsideParentBox(
    siblings: FilteredSiblingsIterator,
    parent_box: Rect,
) QueryError!bool {
    var cursor = siblings;
    const sibling = try cursor.next() orelse return false;
    const sibling_box = try geometry.boundingBox(sibling) orelse return false;
    return !sibling_box.intersect(parent_box).isEmpty();
}

/// The answer of the clipped-children rule, or `null` when the rule does not
/// exclude the node. Upstream `filters.rs:65-89`.
fn clippedOutByParent(node: NodeRef, filter: FilterFn) QueryError!?FilterResult {
    const parent = try hierarchy.filteredParent(node, filter) orelse return null;
    if (!properties.clipsChildren(parent)) return null;

    const node_box = try geometry.boundingBox(node) orelse return null;
    const parent_box = try geometry.boundingBox(parent) orelse return null;
    if (!node_box.intersect(parent_box).isEmpty()) return null;

    // A clipping parent keeps a child whose own box misses the parent box when a
    // neighbour is inside, so that a consumer can scroll the item into view.
    // Upstream says this at filters.rs:69-72, and `or` keeps the short circuit
    // that stops the walk at the first visible neighbour.
    const neighbour_inside = try isFirstSiblingInsideParentBox(
        try hierarchy.followingFilteredSiblings(node, filter),
        parent_box,
    ) or try isFirstSiblingInsideParentBox(
        try hierarchy.precedingFilteredSiblings(node, filter),
        parent_box,
    );
    if (neighbour_inside) return null;
    return .exclude_subtree;
}

/// `commonFilter` with its parent walk already sized. `remaining_steps` falls by
/// one per level, and zero means the chain has more nodes than the tree holds.
fn commonFilterWithin(
    node: NodeRef,
    remaining_steps: usize,
) QueryError!FilterResult {
    if (remaining_steps == 0) return error.TreeCycle;
    if (try commonFilterBase(node)) |decided| return decided;

    if (hierarchy.parent(node)) |parent| {
        if (try commonFilterWithin(parent, remaining_steps - 1) == .exclude_subtree) {
            return .exclude_subtree;
        }
    }

    if (try clippedOutByParent(node, without_parent_checks)) |clipped| return clipped;
    return .include;
}

/// The filter a platform applies to each node of the tree. Upstream
/// `common_filter` at `filters.rs:54-92`.
///
/// A node the base rule drops answers at once. Otherwise an excluded subtree
/// anywhere above the node excludes the node too, and a clipping parent whose
/// box misses the node box excludes the node unless a neighbour is on screen.
///
/// Returns `error.TreeCycle` when the parent chain is longer than
/// `commonFilterStepBound`. Nothing is written, so the state is the same before
/// and after the call.
pub fn commonFilter(node: NodeRef) QueryError!FilterResult {
    const bound = commonFilterStepBound(node.tree_state.nodes.count());
    return commonFilterWithin(node, bound);
}

/// `commonFilter`, except that the root is always included. Upstream
/// `common_filter_with_root_exception` at `filters.rs:94-99`.
///
/// The root is included before the base rule runs, so a hidden root or a
/// `GenericContainer` root stays. Every other node answers as `commonFilter`
/// answers. `error.TreeCycle` means what it means in `commonFilter`.
pub fn commonFilterWithRootException(node: NodeRef) QueryError!FilterResult {
    if (hierarchy.isRoot(node)) return .include;
    return commonFilter(node);
}

comptime {
    // The size pin at filters.rs:10-15 is what makes the three tags fit in one
    // byte, and a fourth tag would be a compile error rather than a silent
    // widen.
    assert(@sizeOf(FilterResult) == 1);

    // The bound is the node count, so a tree with no nodes cannot walk at all
    // and a tree with `n` nodes walks at most `n` steps.
    assert(commonFilterStepBound(0) == 0);
    assert(commonFilterStepBound(65_536) == 65_536);
}

// --- Tests ---------------------------------------------------------------------

/// The id of node `number` in tree 0, which every fixture below uses.
fn idOf(number: u64) FullNodeId {
    return FullNodeId.init(.{ .value = number }, .init(0));
}

/// Puts one node in `state`. `parent_and_index` is what the state records for
/// where the node hangs, and `null` makes it a root.
///
/// It returns nothing on purpose. Growing `nodes` moves its entries, so a handle
/// taken here goes stale at the next insert. A fixture that needs a handle calls
/// `refOf` once every node is in place.
fn addNode(
    state: *TreeState,
    id: FullNodeId,
    parent_and_index: ?ParentAndIndex,
    role: Role,
) !void {
    try state.nodes.put(testing.allocator, id, .{
        .parent_and_index = parent_and_index,
        .data = Node.init(testing.allocator, role),
    });
}

/// A handle to the node `id` names. Take it after the last insert into `state`,
/// because the next insert moves the map entry the handle points at.
fn refOf(state: *const TreeState, id: FullNodeId) !NodeRef {
    return NodeRef.init(state, id) orelse error.NodeMissingFromState;
}

/// The state entry for `id`, so a fixture can write the node the state owns.
/// `NodeRef` borrows the state as `const`, so a fixture that sets a property
/// reaches the map entry rather than the handle.
fn slotOf(state: *TreeState, id: FullNodeId) !*NodeState {
    return state.nodes.getPtr(id) orelse error.NodeMissingFromState;
}

/// Records `child` as the only child of the node `id` names, so the sibling
/// cursors can find it. The child already carries the matching
/// `parent_and_index`.
fn declareOnlyChild(state: *TreeState, id: FullNodeId, child: NodeId) !void {
    const slot = try slotOf(state, id);
    try schema.ids_props.setChildren(&slot.data.properties, &.{child});
}

/// Sets the `hidden` bit on the node `id` names.
fn hideNode(state: *TreeState, id: FullNodeId) !void {
    schema.flags.setHidden(&(try slotOf(state, id)).data.flags, true);
}

/// Records `box` as the bounds of the node `id` names.
fn setBoundsOf(state: *TreeState, id: FullNodeId, box: Rect) !void {
    try schema.option.setBounds(&(try slotOf(state, id)).data.properties, box);
}

/// Puts node 0 in `state` with role `root_role` and node 1 in it with role
/// `child_role`, records node 1 as node 0's only child, and returns a handle
/// to each. Building the pair in one call keeps the `children` list and the
/// `parent_and_index` of the child in step.
fn addParentAndChild(
    state: *TreeState,
    root_role: Role,
    child_role: Role,
) !struct { root: NodeRef, child: NodeRef } {
    try addNode(state, idOf(0), null, root_role);
    try addNode(state, idOf(1), .{ .parent_id = idOf(0), .index = 0 }, child_role);
    try declareOnlyChild(state, idOf(0), .{ .value = 1 });
    return .{ .root = try refOf(state, idOf(0)), .child = try refOf(state, idOf(1)) };
}

/// How many nodes the chain fixtures build. The bound is the node count, so a
/// chain of this length sits exactly at the bound and a larger value costs time
/// without testing anything new.
const chain_depth = 64;

/// A ring of `chain_depth` nodes where node `n` hangs from node `n + 1` and
/// node `chain_depth - 1` hangs from node 0, so no chain ever ends.
///
/// Returns the handle to node 0. The ring breaks invariant I1, because no node
/// is a root, and that is the state the walk has to survive.
fn addParentRing(state: *TreeState) !NodeRef {
    for (0..chain_depth) |level| {
        try addNode(state, idOf(@intCast(level)), .{
            .parent_id = idOf(@intCast((level + 1) % chain_depth)),
            .index = 0,
        }, .button);
    }
    for (0..chain_depth) |level| {
        const child: u64 = @intCast((level + chain_depth - 1) % chain_depth);
        try declareOnlyChild(state, idOf(@intCast(level)), .{ .value = child });
    }
    return refOf(state, idOf(0));
}

test "commonFilter includes a plain child of a window" {
    // Upstream `normal` at filters.rs:120-137.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const pair = try addParentAndChild(&state, .window, .button);
    try testing.expectEqual(FilterResult.include, try commonFilter(pair.child));
}

test "commonFilter excludes a hidden node and everything below it" {
    // Upstream `hidden` at filters.rs:139-160.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const pair = try addParentAndChild(&state, .window, .button);
    try hideNode(&state, pair.child.id());
    try testing.expectEqual(FilterResult.exclude_subtree, try commonFilter(pair.child));
}

test "commonFilter includes a hidden node that holds the focus" {
    // Upstream `hidden_but_focused` at filters.rs:162-183. The focus branch of
    // the base rule runs before the hidden branch, so a port that reorders them
    // excludes this node.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const pair = try addParentAndChild(&state, .window, .button);
    try hideNode(&state, pair.child.id());
    state.focus_id = pair.child.id();
    state.is_host_focused = true;

    try testing.expectEqual(FilterResult.include, try commonFilter(pair.child));
}

test "commonFilter drops a generic container but keeps what is inside it" {
    // Upstream `generic_container` at filters.rs:185-207. The root is the node
    // under test, so this is also the accept case for
    // `commonFilterWithRootException`.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const pair = try addParentAndChild(&state, .generic_container, .button);

    try testing.expectEqual(FilterResult.exclude_node, try commonFilter(pair.root));
    try testing.expectEqual(FilterResult.include, try commonFilterWithRootException(pair.root));
    try testing.expectEqual(FilterResult.include, try commonFilter(pair.child));
}

test "commonFilter drops a text run" {
    // Upstream `text_run` at filters.rs:251-268.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    try addNode(&state, idOf(0), null, .text_input);
    try addNode(&state, idOf(1), .{ .parent_id = idOf(0), .index = 0 }, .text_run);
    try declareOnlyChild(&state, idOf(0), .{ .value = 1 });

    const run = try refOf(&state, idOf(1));
    try testing.expectEqual(FilterResult.exclude_node, try commonFilter(run));
}

test "commonFilter drops a graft node" {
    // Upstream `graft_node` at filters.rs:396-420.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const pair = try addParentAndChild(&state, .window, .generic_container);
    try schema.option.setTreeId(
        &(try slotOf(&state, pair.child.id())).data.properties,
        schema.treeIdFromBytes(.{ 1 } ** 16),
    );

    try testing.expectEqual(FilterResult.exclude_node, try commonFilter(pair.child));
}

test "commonFilterWithRootException excludes a hidden node that is not the root" {
    // The reject case for the root exception. A port that returned `include`
    // for every node passes the accept case above and fails here.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const pair = try addParentAndChild(&state, .window, .button);
    try hideNode(&state, pair.child.id());

    const expected = FilterResult.exclude_subtree;
    try testing.expectEqual(expected, try commonFilterWithRootException(pair.child));
}

test "the walk ends at a root that has no children" {
    // The branch at filters.rs:59 where `parent` answers `null`. A port that
    // walked children here, or that called `filteredParent` first, takes a
    // different path.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    try addNode(&state, idOf(0), null, .button);
    const root = try refOf(&state, idOf(0));
    try testing.expectEqual(FilterResult.include, try commonFilter(root));
}

test "a hidden node above the walk drops the node below it" {
    // The branch at filters.rs:59-63 where the recursive answer is
    // `exclude_subtree`. Upstream `hidden_parent` at filters.rs:209-228.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const pair = try addParentAndChild(&state, .generic_container, .button);
    try hideNode(&state, pair.root.id());

    const expected = FilterResult.exclude_subtree;
    try testing.expectEqual(expected, try commonFilter(pair.root));
    try testing.expectEqual(expected, try commonFilter(pair.child));
}

test "a focus below a hidden node keeps the focus visible" {
    // Upstream `hidden_parent_but_focused` at filters.rs:230-249. The child is
    // excluded by its own base rule only because it is hidden, so the focus
    // branch has to run before it.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const pair = try addParentAndChild(&state, .generic_container, .button);
    try hideNode(&state, pair.root.id());
    state.focus_id = pair.child.id();
    state.is_host_focused = true;

    try testing.expectEqual(FilterResult.exclude_subtree, try commonFilter(pair.root));
    try testing.expectEqual(FilterResult.include, try commonFilter(pair.child));
}

/// Builds the clipping tree from `filters.rs:270-353`: a scroll view whose box
/// is 30 by 30 and whose eleven children sit above it, inside it and below it,
/// with two of them hidden.
fn addClippingTree(state: *TreeState) !void {
    const gpa = testing.allocator;
    try addNode(state, idOf(0), null, .scroll_view);

    const boxes = [_]?Rect{
        schema.rectInit(0, -30, 30, -20),
        schema.rectInit(0, -20, 30, -10),
        schema.rectInit(0, -10, 30, 0),
        null,
        schema.rectInit(0, 0, 30, 10),
        schema.rectInit(0, 10, 30, 20),
        schema.rectInit(0, 20, 30, 30),
        null,
        schema.rectInit(0, 30, 30, 40),
        schema.rectInit(0, 40, 30, 50),
        schema.rectInit(0, 50, 30, 60),
    };
    const children = try gpa.alloc(NodeId, boxes.len);
    defer gpa.free(children);
    for (0..boxes.len) |index| {
        const number: u64 = @intCast(index + 1);
        try addNode(state, idOf(number), .{ .parent_id = idOf(0), .index = index }, .unknown);
        children[index] = .{ .value = number };
    }
    for (boxes, 0..) |maybe_box, index| {
        const number: u64 = @intCast(index + 1);
        if (maybe_box) |child_box| {
            try setBoundsOf(state, idOf(number), child_box);
        } else {
            try hideNode(state, idOf(number));
        }
    }
    const root_slot = try slotOf(state, idOf(0));
    schema.flags.setClipsChildren(&root_slot.data.flags, true);
    try setBoundsOf(state, idOf(0), schema.rectInit(0, 0, 30, 30));
    try schema.ids_props.setChildren(&root_slot.data.properties, children);
}

test "a clipping parent drops the children whose boxes miss its box" {
    // Upstream `clipped_children_excluded_above` at filters.rs:355-360. The two
    // nodes above the top edge have no neighbour inside either, so the rule at
    // filters.rs:73-87 answers `exclude_subtree`.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try addClippingTree(&state);

    for ([_]u64{ 1, 2 }) |number| {
        const node = try refOf(&state, idOf(number));
        try testing.expectEqual(FilterResult.exclude_subtree, try commonFilter(node));
    }
}

test "a clipping parent keeps the child that touches its top edge" {
    // Upstream `clipped_children_included_above` at filters.rs:362-366. Node 3
    // has an empty intersection with the parent box, so the neighbour test is
    // what keeps it.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try addClippingTree(&state);

    const node = try refOf(&state, idOf(3));
    try testing.expectEqual(FilterResult.include, try commonFilter(node));
}

test "a clipping parent drops its hidden children" {
    // Upstream `clipped_children_hidden` at filters.rs:368-372. The base rule
    // answers before the geometry runs, so a hidden child never reaches the
    // neighbour test.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try addClippingTree(&state);

    for ([_]u64{ 4, 8 }) |number| {
        const node = try refOf(&state, idOf(number));
        try testing.expectEqual(FilterResult.exclude_subtree, try commonFilter(node));
    }
}

test "a clipping parent keeps the children inside its box" {
    // Upstream `clipped_children_visible` at filters.rs:374-381.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try addClippingTree(&state);

    for ([_]u64{ 5, 6, 7 }) |number| {
        const node = try refOf(&state, idOf(number));
        try testing.expectEqual(FilterResult.include, try commonFilter(node));
    }
}

test "a clipping parent keeps the first child below its box when a sibling is inside" {
    // Upstream `clipped_children_included_below` at filters.rs:383-387. Node 9
    // has an empty intersection with the parent box and the first following
    // filtered sibling is node 10, which is also outside, so the answer comes
    // from the preceding sibling node 7.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try addClippingTree(&state);

    const node = try refOf(&state, idOf(9));
    try testing.expectEqual(FilterResult.include, try commonFilter(node));
}

test "a clipping parent drops the trailing children that no sibling reaches" {
    // Upstream `clipped_children_excluded_below` at filters.rs:389-394. Nodes
    // 10 and 11 sit below the parent box and the neighbour on either side of
    // each of them is also outside, so the rule at filters.rs:84 answers.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try addClippingTree(&state);

    for ([_]u64{ 10, 11 }) |number| {
        const node = try refOf(&state, idOf(number));
        try testing.expectEqual(FilterResult.exclude_subtree, try commonFilter(node));
    }
}

test "the parent walk runs its full bound on a chain of node_count nodes" {
    // The positive half of the bound. The chain holds `chain_depth` nodes and
    // the bound is the node count, so the walk from the deepest node takes
    // exactly `commonFilterStepBound` steps and still answers.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    for (0..chain_depth) |level| {
        const number: u64 = @intCast(level);
        try addNode(&state, idOf(number), if (level == 0) null else .{
            .parent_id = idOf(number - 1),
            .index = 0,
        }, .button);
    }
    for (1..chain_depth) |level| {
        const number: u64 = @intCast(level);
        try declareOnlyChild(&state, idOf(number - 1), .{ .value = number });
    }

    const leaf = try refOf(&state, idOf(chain_depth - 1));
    try testing.expectEqual(@as(usize, chain_depth), state.nodes.count());
    try testing.expectEqual(
        @as(usize, chain_depth),
        commonFilterStepBound(state.nodes.count()),
    );
    try testing.expectEqual(FilterResult.include, try commonFilter(leaf));
}

test "a parent chain that never ends reports error.TreeCycle" {
    // The negative half of the bound. Without a bound on the walk this call
    // never returns, so the test fails by running forever rather than by
    // asserting.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const first = try addParentRing(&state);
    try testing.expectEqual(@as(usize, chain_depth), state.nodes.count());

    try testing.expectError(error.TreeCycle, commonFilter(first));
}

test "the recursion reports error.TreeCycle on a budget one step short" {
    // The bound the recursion itself applies, away from the inherited `hidden`
    // walk. `commonFilterBase` runs first and its own walk uses the same bound
    // on the same chain, so `commonFilter` reaches a cycle through that walk and
    // never reaches this check. Calling the step with a budget one step short
    // of the chain is the only way to observe it, and it is what stops the
    // counter from wrapping on a tree that grew by one node.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    try addNode(&state, idOf(0), null, .button);
    try addNode(&state, idOf(1), .{ .parent_id = idOf(0), .index = 0 }, .button);
    try declareOnlyChild(&state, idOf(0), .{ .value = 1 });
    const child = try refOf(&state, idOf(1));

    // Two nodes on the chain, so two steps answer it and one step cannot.
    try testing.expectEqual(FilterResult.include, try commonFilterWithin(child, 2));
    try testing.expectError(error.TreeCycle, commonFilterWithin(child, 1));
    try testing.expectError(error.TreeCycle, commonFilterWithin(child, 0));
}

test "the filter passed to the walk answers from the node alone" {
    // Upstream `common_filter_without_parent_checks` at filters.rs:39-41. Node 1
    // of the clipping tree is a plain `unknown` node whose only exclusion is the
    // geometry rule at filters.rs:73-87, so the walk filter includes it and
    // `commonFilter` does not. A port that made the walk filter call
    // `commonFilter` would answer `exclude_subtree` here, and `filteredParent`
    // would then walk past the clipping root and lose the neighbour test at
    // filters.rs:77.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try addClippingTree(&state);

    const node = try refOf(&state, idOf(1));
    try testing.expectEqual(FilterResult.include, try without_parent_checks.call(node));
    try testing.expectEqual(FilterResult.exclude_subtree, try commonFilter(node));
}

/// A filter whose answer for a non-root node depends on the state its context
/// carries, so a caller can see that the context reaches the callee. A `null`
/// context reads as zero.
fn readContext(context: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    const carried: u32 = if (context) |pointer|
        @as(*const u32, @ptrCast(@alignCast(pointer))).*
    else
        0;
    if (node.id().local.value == 0) return .include;
    return if (carried == 0) .exclude_node else .include;
}

test "FilterFn.call hands its context to the callee" {
    // The context is the reason `FilterFn` is a struct. A port that passed
    // `null` at the call site, or that dropped the field, fails here.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const pair = try addParentAndChild(&state, .button, .button);

    var carried: u32 = 0;
    const vtable: FilterFn = .{ .context = &carried, .filter = readContext };

    try testing.expectEqual(FilterResult.exclude_node, try vtable.call(pair.child));

    carried = 1;
    try testing.expectEqual(FilterResult.include, try vtable.call(pair.child));

    // The root takes the other branch, so a callee that ignored its context
    // and always answered `exclude_node` fails here.
    try testing.expectEqual(FilterResult.include, try vtable.call(pair.root));
}