//! Who a node hangs from, who hangs from it, and how deep its subtree goes.
//!
//! Upstream `accesskit_consumer/src/node.rs:84-289`. The transforms, bounding
//! boxes and hit tests of the same `impl NodeRef` block are in
//! `node_ref/geometry.zig`, from `:291` to `:395`; the split is
//! `docs/30-port-design.md` section 3.2, and this file owns the ten hierarchy
//! queries that row names.
//!
//! **Every operation here is a free function whose first parameter is the
//! node.** `node_id.zig` declares the `NodeRef` body, so it is the only file
//! that may carry a `NodeRef` method and it carries only `id`, `data` and
//! `init`. A call reads `hierarchy.parent(node)`, not `node.parent()`.
//!
//! **Three decisions this file records.**
//!
//! - **The recursion in the subtree walks.** Six functions walk here: four that
//!   move one level at a time and the two that step to the deepest filtered
//!   child. Every level-at-a-time walk takes
//!   `treeWalkStepBound(node_count)` from `docs/33-consumer-interface-contract.md`
//!   section 7, and section 7.1 rows 5 to 8 name four of them by upstream line.
//!   Each step reaches a different node and the state holds at most
//!   `node_count` nodes, so a walk cannot take more steps than that. A step past
//!   the bound means a node is its own ancestor, which no update may produce,
//!   so the walk answers `error.TreeCycle` instead of looping. The two filtered
//!   walks add a second walk underneath, one level of the same size, so they
//!   carry the same bound in two places rather than a bound of their own.
//! - **The filtered-descendant step belongs to the cursor module.** Upstream
//!   declares `first_filtered_child` at `node.rs:1013` and
//!   `last_filtered_child` at `node.rs:1032`. `docs/33` section 1.3 puts them in
//!   `node_ref/containers.zig`, which is layer L6, and a L5 module cannot import
//!   it. `iterators/children.zig` is L4 and already walks children for
//!   `filtered_children`, so it holds both as `firstFilteredChild` and
//!   `lastFilteredChild`, and this file calls them. That leaves `filtered_children`
//!   and the two filtered-child walks reading one implementation, which is the
//!   point of the split.
//! - **The hit test is not here.** `node.rs:344-395` and the `Rect` geometry it
//!   needs are `node_ref/geometry.zig`. The text-level hit tests at
//!   `text.rs:932-978` are `text/hit_test.zig`, a different walk in a different
//!   layer, and nothing in this range reaches them.
//!
//! **What this file assumes from the modules that own the names.** Eight
//! iterator cursors come from `iterators/children.zig`,
//! `iterators/following.zig` and `iterators/preceding.zig`, and the constructor
//! calls in the section marked below are the only place this file names them.
//! `isGraft` is `node_ref/properties.zig`, because `docs/33` section 8 gives its
//! owning column there. `FilterFn` and `FilterResult` are `../filter.zig`,
//! because Main's placement ruling moved them out of `node_id.zig`. `QueryError`
//! and `treeWalkStepBound` are `../tree_state.zig`, because `TreeState.activeDialog`
//! returns the first and every module below L2 needs the second.
//!
//! **`data` at node.rs:85 is not declared here.** It is a `NodeRef` method and
//! `node_id.zig` declares it.
//!
//! Nothing here allocates, so no function takes an allocator. Upstream's two
//! filtered-child walks build a `vec![]` at `node.rs:1017`, and the L4 cursor
//! module holds that stack instead, so the walks here carry no `gpa`. No
//! function takes an `io`, this file reads no clock, and every constant here is
//! `const`.

const std = @import("std");

const schema = @import("../../schema/root.zig");
const tree_index = @import("../tree_index.zig");
const tree_state = @import("../tree_state.zig");
const node_id = @import("../node_id.zig");
const filter_mod = @import("../filter.zig");
const properties = @import("properties.zig");
const children_iterators = @import("../iterators/children.zig");
const following_iterators = @import("../iterators/following.zig");
const preceding_iterators = @import("../iterators/preceding.zig");

const Affine = schema.Affine;
const FullNodeId = tree_index.FullNodeId;
const NodeRef = node_id.NodeRef;
const TreeState = tree_state.TreeState;
const FilterFn = filter_mod.FilterFn;
const FilterResult = filter_mod.FilterResult;
const QueryError = tree_state.QueryError;
const treeWalkStepBound = tree_state.treeWalkStepBound;

const ChildIdsIterator = children_iterators.ChildIdsIterator;
const ChildrenIterator = children_iterators.ChildrenIterator;
const FilteredChildrenIterator = children_iterators.FilteredChildrenIterator;
const FilteredSiblingsIterator = following_iterators.FilteredSiblingsIterator;
const FollowingSiblingIdsIterator = following_iterators.FollowingSiblingIdsIterator;
const FollowingSiblingsIterator = following_iterators.FollowingSiblingsIterator;
const PrecedingSiblingIdsIterator = preceding_iterators.PrecedingSiblingIdsIterator;
const PrecedingSiblingsIterator = preceding_iterators.PrecedingSiblingsIterator;

const testing = std.testing;

// --- The queries --------------------------------------------------------------

/// Whether `node` is the root of its state. Upstream `node.rs:115-119`.
///
/// The test is against `TreeState.rootId` and not against the absence of a
/// parent, because upstream says why: a non-root node that lost its parent still
/// is not the root.
pub fn isRoot(node: NodeRef) bool {
    // `FullNodeId` is a plain struct and Zig derives nothing for it, so the
    // comparison is a field-wise one.
    return std.meta.eql(node.id(), node.tree_state.rootId());
}

/// The node this one hangs from, or `null` when the state records no parent.
/// Upstream `node.rs:126-131`.
///
/// The index in the parent's `children` list is not part of this answer.
/// `parentAndIndex` is the operation that carries it.
pub fn parentId(node: NodeRef) ?FullNodeId {
    const slot = node.state.parent_and_index orelse return null;
    return slot.parent_id;
}

/// The node this one hangs from, or `null` when there is none.
/// Upstream `node.rs:133-136`.
///
/// Upstream ends this with `.unwrap()` and panics. That unwrap is the boundary
/// assertion `tree_validate.zig` already makes for invariant I2, which says
/// every id named in some `children` list has a `NodeState`. A parent id with no
/// entry is a state that broke I2, and the signature `docs/33` section 8 pins
/// cannot carry an error, so this answers `null` and names the invariant
/// instead of the panic.
pub fn parent(node: NodeRef) ?NodeRef {
    const id = parentId(node) orelse return null;
    return NodeRef.init(node.tree_state, id);
}

/// The nearest ancestor of `node` that `filter` includes, or `null` when the
/// walk reaches the root first. Upstream `node.rs:138-149`.
///
/// The walk starts at the parent, so `node` itself is never tested and a filter
/// that includes nothing answers `null` rather than the root. Each step moves to
/// a different ancestor and the state holds at most `node_count` nodes, so a step
/// past `treeWalkStepBound(node_count)` means a node is its own ancestor. That
/// is `error.TreeCycle`, and `docs/33` section 7.1 row 5 is this walk.
pub fn filteredParent(node: NodeRef, filter: FilterFn) QueryError!?NodeRef {
    const bound = treeWalkStepBound(node.tree_state.nodes.count());
    var current = parent(node) orelse return null;
    var steps: usize = 0;
    while (try filter.call(current) != .include) {
        steps += 1;
        if (steps > bound) return error.TreeCycle;
        current = parent(current) orelse return null;
    }
    return current;
}

/// The parent and this node's index in the parent's `children` list, or `null`
/// when the state records no parent. Upstream `node.rs:151-158`.
///
/// The `.unwrap()` at `node.rs:156` is the same boundary assertion as the one in
/// `parent`: invariant I2 says the parent id has an entry, so a `null` here
/// means a broken state and not a missing parent.
pub fn parentAndIndex(node: NodeRef) ?struct { parent: NodeRef, index: usize } {
    const slot = node.state.parent_and_index orelse return null;
    const parent_node = NodeRef.init(node.tree_state, slot.parent_id) orelse return null;
    return .{ .parent = parent_node, .index = slot.index };
}

/// The single child of a graft node, which is the root of its subtree.
/// Upstream `node.rs:160-166`, `fn graft_child_id`.
///
/// A `null` answer means the graft node names a `tree_id` the state holds no
/// subtree for, which invariant I3 rules out. Upstream returns `None` in the
/// same case and says nothing.
fn graftChildId(node: NodeRef) ?FullNodeId {
    const tree_id = schema.option.treeId(&node.data().properties) orelse return null;
    return node.tree_state.subtreeRoot(tree_id);
}

/// The ids of `node`'s children, in the order the node lists them.
/// Upstream `node.rs:168-179`.
///
/// A graft node yields the one subtree root it has and a normal node yields its
/// `children` property, so the two upstream arms are one cursor with a
/// different start. The result copies the ids and borrows the `children` slice,
/// so it stays valid until the next write to that property.
pub fn childIds(node: NodeRef) ChildIdsIterator {
    // The graft arm is decided here because `isGraft` lives in
    // `node_ref/properties.zig` at L5 and the cursor lives at L4.
    return children_iterators.child_ids(
        node,
        properties.isGraft(node),
        graftChildId(node),
    );
}

/// The nodes of `node`'s children, in the order the node lists them.
/// Upstream `node.rs:181-187`, which is `child_ids` mapped through the state's
/// lookup.
///
/// The `.unwrap()` at `node.rs:186` is invariant I2 again: every id in a
/// `children` list has a `NodeState`. A cursor that cannot report that skips
/// the entry, and the cursor is not this file's type to change.
pub fn children(node: NodeRef) ChildrenIterator {
    return children_iterators.children(childIds(node), node.tree_state);
}

/// The children of `node` that `filter` includes. Upstream `node.rs:189-194`.
///
/// The cursor descends into a child the filter excludes with `exclude_node` and
/// skips the whole subtree of one it excludes with `exclude_subtree`, so the
/// order is a depth-first pre-order walk and not a scan of the list. The error
/// is the constructor's: it walks to both ends of the walk before it answers,
/// and either walk can overrun its bound.
pub fn filteredChildren(node: NodeRef, filter: FilterFn) QueryError!FilteredChildrenIterator {
    return children_iterators.filtered_children(node, filter);
}

/// The ids of the siblings that follow `node`. Upstream `node.rs:196-200`.
///
/// A graft node has exactly one child, so a graft parent yields nothing to
/// either sibling cursor, which is upstream `iterators.rs:92-94`. A node with no
/// parent yields nothing for the same reason.
pub fn followingSiblingIds(node: NodeRef) FollowingSiblingIdsIterator {
    return following_iterators.following_sibling_ids(parent(node), node.id());
}

/// The nodes of the siblings that follow `node`. Upstream `node.rs:202-208`,
/// which is `following_sibling_ids` mapped through the state's lookup.
pub fn followingSiblings(node: NodeRef) FollowingSiblingsIterator {
    return following_iterators.followingSiblings(followingSiblingIds(node), node.tree_state);
}

/// The siblings that follow `node` and that `filter` includes.
/// Upstream `node.rs:210-215`.
///
/// The walk crosses a subtree boundary, because `exclude_node` on a node says to
/// keep looking inside it. That walk is `iterators/sibling_scan.zig` and its
/// bound is `docs/33` section 7's, not this file's. The error is the
/// constructor's: it walks to both ends of the walk before it answers, and
/// either walk can overrun its bound.
pub fn followingFilteredSiblings(
    node: NodeRef,
    filter: FilterFn,
) QueryError!FilteredSiblingsIterator {
    return following_iterators.following_filtered_siblings(node, filter);
}

/// The ids of the siblings that precede `node`. Upstream `node.rs:217-221`.
pub fn precedingSiblingIds(node: NodeRef) PrecedingSiblingIdsIterator {
    return preceding_iterators.preceding_sibling_ids(parent(node), node.id());
}

/// The nodes of the siblings that precede `node`. Upstream `node.rs:223-229`.
pub fn precedingSiblings(node: NodeRef) PrecedingSiblingsIterator {
    return preceding_iterators.precedingSiblings(precedingSiblingIds(node), node.tree_state);
}

/// The siblings that precede `node` and that `filter` includes.
/// Upstream `node.rs:231-236`.
///
/// The mirror of `followingFilteredSiblings`, so it carries the same error for
/// the same reason: both ends of the walk are read before the cursor answers.
pub fn precedingFilteredSiblings(
    node: NodeRef,
    filter: FilterFn,
) QueryError!FilteredSiblingsIterator {
    return preceding_iterators.preceding_filtered_siblings(node, filter);
}

/// The node at the bottom of `node`'s first-child chain: the first child, then
/// that child's first child, and so on. Upstream `node.rs:238-244`.
///
/// `null` means `node` has no child. Each step of the loop moves to a different
/// node, so `treeWalkStepBound(node_count)` steps is the longest chain a
/// well-formed tree can hold and the step after it is `error.TreeCycle`.
/// `docs/33` section 7.1 row 6 is this walk.
pub fn deepestFirstChild(node: NodeRef) QueryError!?NodeRef {
    const bound = treeWalkStepBound(node.tree_state.nodes.count());
    var deepest = firstChild(node) orelse return null;
    var steps: usize = 0;
    while (firstChild(deepest)) |first_child| {
        steps += 1;
        if (steps > bound) return error.TreeCycle;
        deepest = first_child;
    }
    return deepest;
}

/// The node at the bottom of the filtered first-child chain.
/// Upstream `node.rs:246-255`, whose `loop` is at `:251`.
///
/// The step is `iterators/children.zig`'s `firstFilteredChild`, which is
/// upstream's own `first_filtered_child` and takes no allocator. Both it and the
/// chain carry `treeWalkStepBound(nodes.count())`, and both report
/// `error.TreeCycle`.
pub fn deepestFirstFilteredChild(node: NodeRef, filter: FilterFn) QueryError!?NodeRef {
    const bound = treeWalkStepBound(node.tree_state.nodes.count());
    var deepest = try children_iterators.firstFilteredChild(node, filter) orelse return null;
    var steps: usize = 0;
    while (try children_iterators.firstFilteredChild(deepest, filter)) |first_child| {
        steps += 1;
        if (steps > bound) return error.TreeCycle;
        deepest = first_child;
    }
    return deepest;
}

/// The node at the bottom of `node`'s last-child chain: the last child, then that
/// child's last child, and so on. Upstream `node.rs:257-263`.
///
/// The mirror of `deepestFirstChild`, so `docs/33` section 7.1 row 7 is this
/// walk and the bound is the same.
pub fn deepestLastChild(node: NodeRef) QueryError!?NodeRef {
    const bound = treeWalkStepBound(node.tree_state.nodes.count());
    var deepest = lastChild(node) orelse return null;
    var steps: usize = 0;
    while (lastChild(deepest)) |last_child| {
        steps += 1;
        if (steps > bound) return error.TreeCycle;
        deepest = last_child;
    }
    return deepest;
}

/// The node at the bottom of the filtered last-child chain.
/// Upstream `node.rs:265-274`, whose `loop` is at `:270`.
pub fn deepestLastFilteredChild(node: NodeRef, filter: FilterFn) QueryError!?NodeRef {
    const bound = treeWalkStepBound(node.tree_state.nodes.count());
    var deepest = try children_iterators.lastFilteredChild(node, filter) orelse return null;
    var steps: usize = 0;
    while (try children_iterators.lastFilteredChild(deepest, filter)) |last_child| {
        steps += 1;
        if (steps > bound) return error.TreeCycle;
        deepest = last_child;
    }
    return deepest;
}

/// Whether `node` is `ancestor` or sits below it. Upstream `node.rs:276-289`,
/// whose `loop` is at `:278`.
///
/// The walk starts at `node` and tests before it moves, so a node is a
/// descendant of itself, which is upstream's answer and the one an inclusive
/// containment test needs. Each step moves one level up, so the bound is
/// `treeWalkStepBound(node_count)` and `docs/33` section 7.1 row 8 is this walk.
/// The two parameters share a type and stay two parameters because neither name
/// leaves a doubt about which node is which.
pub fn isDescendantOf(node: NodeRef, ancestor: NodeRef) QueryError!bool {
    const bound = treeWalkStepBound(node.tree_state.nodes.count());
    var current = node;
    var steps: usize = 0;
    while (!std.meta.eql(current.id(), ancestor.id())) {
        steps += 1;
        if (steps > bound) return error.TreeCycle;
        current = parent(current) orelse return false;
    }
    return true;
}

// --- The private child steps --------------------------------------------------

/// The first child of `node`, or `null` when it has none. Upstream calls
/// `children().next()` at this position; the step is its own function because a
/// cursor's `next` takes a mutable pointer and a call on a temporary is not one.
fn firstChild(node: NodeRef) ?NodeRef {
    var cursor = children(node);
    return cursor.next();
}

/// The last child of `node`, or `null` when it has none. The mirror of
/// `firstChild`, for the same reason.
fn lastChild(node: NodeRef) ?NodeRef {
    var cursor = children(node);
    return cursor.nextBack();
}

/// The first following sibling id of `node`, or `null`. A cursor's `next` takes
/// a mutable pointer, so a call on a temporary is not one.
fn firstFollowingId(node: NodeRef) ?FullNodeId {
    var cursor = followingSiblingIds(node);
    return cursor.next();
}

/// The first preceding sibling id of `node`, or `null`. The mirror of
/// `firstFollowingId`.
fn firstPrecedingId(node: NodeRef) ?FullNodeId {
    var cursor = precedingSiblingIds(node);
    return cursor.next();
}

// --- The tests ----------------------------------------------------------------

/// A state one test builds a node at a time. The state owns every node, so one
/// `deinit` releases all of them and a test cannot leak one by forgetting it.
const Fixture = struct {
    gpa: std.mem.Allocator,
    state: TreeState = .{},

    /// Releases the map and every node's property buffers.
    fn deinit(self: *Fixture) void {
        self.state.deinit(self.gpa);
    }

    /// Stores one node and returns its id. `parent_id` is `null` for a root.
    fn add(self: *Fixture, local: u64, parent_id: ?FullNodeId) !FullNodeId {
        const id = FullNodeId.init(.{ .value = local }, .init(0));
        try self.state.nodes.put(self.gpa, id, .{
            .parent_and_index = if (parent_id) |p| .{ .parent_id = p, .index = 0 } else null,
            .data = schema.Node.init(self.gpa, .group),
        });
        return id;
    }

    /// Writes the local ids `locals` as the node's `children` property.
    fn setChildren(self: *Fixture, id: FullNodeId, locals: []const u64) !void {
        const list = try self.gpa.alloc(schema.NodeId, locals.len);
        defer self.gpa.free(list);
        for (locals, list) |local, *slot| slot.* = .{ .value = local };
        try schema.ids_props.setChildren(&self.state.nodes.getPtr(id).?.data.properties, list);
    }

    /// Sets the position this node holds in its parent's `children` list. A
    /// sibling cursor reads that position out of the state, so a test that
    /// wants a particular sibling writes it rather than leaving the default.
    fn setIndex(self: *Fixture, id: FullNodeId, index: usize) void {
        self.state.nodes.getPtr(id).?.parent_and_index.?.index = index;
    }

    /// Gives the node a role, so a filter can key off it.
    fn setRole(self: *Fixture, id: FullNodeId, role: schema.Role) void {
        self.state.nodes.getPtr(id).?.data.setRole(role);
    }

    fn ref(self: *Fixture, id: FullNodeId) !NodeRef {
        return NodeRef.init(&self.state, id) orelse error.NodeMissingFromState;
    }
};

/// Keeps every node, so a filter that includes everything is one call.
fn includeAll(_: ?*anyopaque, _: NodeRef) QueryError!FilterResult {
    return .include;
}

/// Excludes a `group` by name and a `button` by name, so one filter opens the
/// first and closes the second. A port that treated the two tags alike would
/// find the node under the `button` subtree.
fn excludeByRole(_: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    return switch (node.data().role) {
        .group => .exclude_node,
        .button => .exclude_subtree,
        else => .include,
    };
}

/// `includeAll` as `FilterFn` carries it. `FilterFn` is a struct and not a
/// bare function pointer, because a filter needing per-call state takes a
/// `context`.
fn includeAllFilter() FilterFn {
    return .{ .context = null, .filter = includeAll };
}

/// `excludeByRole` as `FilterFn` carries it.
fn roleFilter() FilterFn {
    return .{ .context = null, .filter = excludeByRole };
}

/// Asserts that two ids name the same node. `FullNodeId` is a plain struct and
/// Zig derives no `==` for it, so `expectEqual` cannot compare two of them.
fn expectSameId(want: FullNodeId, got: FullNodeId) !void {
    try testing.expect(std.meta.eql(want, got));
}


test "isRoot answers for the recorded root and for no other node" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null);
    const child = try fixture.add(1, root);
    const second_root = try fixture.add(2, null);

    try testing.expect(isRoot(try fixture.ref(root)));
    try testing.expect(!isRoot(try fixture.ref(child)));

    // A node with no parent that is not the recorded root. Upstream compares
    // against `root_id` rather than testing for the absence of a parent, so
    // this is the case that separates the two readings.
    try testing.expect(!isRoot(try fixture.ref(second_root)));
}

test "parentId and parent answer null at a root and the parent elsewhere" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null);
    const child = try fixture.add(1, root);
    const root_node = try fixture.ref(root);
    const child_node = try fixture.ref(child);

    try testing.expect(parentId(root_node) == null);
    try testing.expect(parent(root_node) == null);
    try expectSameId(root, parentId(child_node).?);
    try expectSameId(root, (parent(child_node) orelse return error.NoParent).id());
}

test "parent answers null for a parent id the state holds no node for" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const absent = FullNodeId.init(.{ .value = 40 }, .init(0));
    const child = try fixture.add(1, absent);
    const child_node = try fixture.ref(child);

    // Upstream unwraps here and panics. This pins what the port answers in the
    // state that breaks invariant I2.
    try testing.expectEqual(@as(u64, 40), parentId(child_node).?.local.value);
    try testing.expect(parent(child_node) == null);
    try testing.expect(parentAndIndex(child_node) == null);
}

test "parentAndIndex carries the position in the parent's children list" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null);
    _ = try fixture.add(1, root);
    const third = try fixture.add(2, root);
    fixture.state.nodes.getPtr(third).?.parent_and_index.?.index = 2;

    const slot = parentAndIndex(try fixture.ref(third)) orelse return error.NoParent;
    try expectSameId(root, slot.parent.id());
    try testing.expectEqual(@as(usize, 2), slot.index);
    try testing.expect(parentAndIndex(try fixture.ref(root)) == null);
}

test "filteredParent starts above the node and stops at the first included one" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null);
    const middle = try fixture.add(1, root);
    const leaf = try fixture.add(2, middle);

    const leaf_node = try fixture.ref(leaf);
    try expectSameId(middle,
        (try filteredParent(leaf_node, includeAllFilter())).?.id(),
    );
    try expectSameId(root,
        (try filteredParent(try fixture.ref(middle), includeAllFilter())).?.id(),
    );

    // A filter that excludes every ancestor reaches the top of the tree and
    // reports no parent, because the root itself is never tested.
    fixture.setRole(root, .group);
    fixture.setRole(middle, .group);
    try testing.expect((try filteredParent(leaf_node, roleFilter())) == null);

    // One level up the chain, the same filter now has an included node to find,
    // so the answer is not null for the wrong reason.
    fixture.setRole(middle, .list_item);
    try expectSameId(middle,
        (try filteredParent(leaf_node, roleFilter())).?.id(),
    );
}

test "filteredParent reaches its bound on a parent cycle and reports TreeCycle" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const first = try fixture.add(0, null);
    const second = try fixture.add(1, first);
    const third = try fixture.add(2, second);
    // Close the chain: 0 hangs from 1 and 1 hangs from 0.
    fixture.state.nodes.getPtr(first).?.parent_and_index = .{
        .parent_id = second,
        .index = 0,
    };
    fixture.state.nodes.getPtr(second).?.parent_and_index = .{
        .parent_id = first,
        .index = 0,
    };

    const first_node = try fixture.ref(first);
    fixture.setRole(first, .group);
    fixture.setRole(second, .group);
    fixture.setRole(third, .group);

    // Three nodes and a filter that includes nothing: the walk has no end and
    // only the bound stops it.
    try testing.expectError(error.TreeCycle, filteredParent(first_node, roleFilter()));

    // The positive half, one step short of the bound: break the cycle and the
    // same call answers.
    fixture.state.nodes.getPtr(second).?.parent_and_index = null;
    try testing.expect((try filteredParent(first_node, roleFilter())) == null);
}

test "children yields every listed child in order and nothing for a leaf" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null);
    _ = try fixture.add(1, root);
    _ = try fixture.add(2, root);
    _ = try fixture.add(3, root);
    const leaf = try fixture.add(4, root);
    try fixture.setChildren(root, &.{ 1, 2, 3 });
    try fixture.setChildren(leaf, &.{});

    const root_node = try fixture.ref(root);
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(gpa);
    var cursor = childIds(root_node);
    while (cursor.next()) |id| try ids.append(gpa, id.local.value);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, ids.items);
    try testing.expectEqual(@as(usize, 3), childIds(root_node).len());

    var nodes: std.ArrayList(u64) = .empty;
    defer nodes.deinit(gpa);
    var cursor_back = children(root_node);
    while (cursor_back.next()) |node| try nodes.append(gpa, node.id().local.value);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, nodes.items);
    try testing.expect(firstChild(try fixture.ref(leaf)) == null);
}

test "a graft node yields its subtree root instead of its children list" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null);
    const graft = try fixture.add(1, root);
    const subtree_root = try fixture.add(2, null);
    const tree_id = schema.treeIdFromBytes(.{ 1 } ** 16);
    try schema.option.setTreeId(
        &fixture.state.nodes.getPtr(graft).?.data.properties,
        tree_id,
    );
    try fixture.state.subtrees.put(gpa, tree_id, .{
        .root = subtree_root,
        .focus = subtree_root,
    });
    // A graft node also lists a child upstream, and the graft arm must win, so a
    // cursor that reads `children` first reports the wrong child.
    try fixture.setChildren(graft, &.{ 2 });

    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(gpa);
    var cursor = childIds(try fixture.ref(graft));
    while (cursor.next()) |id| try ids.append(gpa, id.local.value);
    try testing.expectEqualSlices(u64, &.{ 2 }, ids.items);
    try testing.expectEqual(@as(usize, 1), childIds(try fixture.ref(graft)).len());
}

test "the sibling cursors split the parent's list around the node" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null);
    const first_child = try fixture.add(1, root);
    _ = try fixture.add(2, root);
    const middle = try fixture.add(3, root);
    const last_child = try fixture.add(4, root);
    try fixture.setChildren(root, &.{ 1, 2, 3, 4 });
    for ([_]usize{ 0, 1, 2, 3 }) |position| {
        fixture.setIndex(FullNodeId.init(.{ .value = position + 1 }, .init(0)), position);
    }

    const middle_node = try fixture.ref(middle);
    const root_node = try fixture.ref(root);
    const first_node = try fixture.ref(first_child);

    var following: std.ArrayList(u64) = .empty;
    defer following.deinit(gpa);
    var ahead = followingSiblingIds(middle_node);
    while (ahead.next()) |id| try following.append(gpa, id.local.value);
    try testing.expectEqualSlices(u64, &.{4}, following.items);

    var behind: std.ArrayList(u64) = .empty;
    defer behind.deinit(gpa);
    var back = precedingSiblingIds(middle_node);
    while (back.next()) |id| try behind.append(gpa, id.local.value);
    try testing.expectEqualSlices(u64, &.{ 2, 1 }, behind.items);

    // The ends of the list, so an off-by-one in either cursor shows: the first
    // child has nothing before it and the last child has nothing after.
    try testing.expect(firstFollowingId(first_node) != null);
    try testing.expect(firstPrecedingId(first_node) == null);
    try testing.expect(firstFollowingId(try fixture.ref(last_child)) == null);
    try testing.expect(firstPrecedingId(try fixture.ref(last_child)) != null);

    // A root has no parent, so neither cursor yields.
    try testing.expect(firstFollowingId(root_node) == null);
    try testing.expect(firstPrecedingId(root_node) == null);
}

test "the node-returning sibling cursors agree with the id ones" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null);
    _ = try fixture.add(1, root);
    const middle = try fixture.add(2, root);
    _ = try fixture.add(3, root);
    try fixture.setChildren(root, &.{ 1, 2, 3 });
    for ([_]usize{ 0, 1, 2 }) |position| {
        fixture.setIndex(FullNodeId.init(.{ .value = position + 1 }, .init(0)), position);
    }

    var ahead: std.ArrayList(u64) = .empty;
    defer ahead.deinit(gpa);
    var cursor = followingSiblings(try fixture.ref(middle));
    while (cursor.next()) |node| try ahead.append(gpa, node.id().local.value);
    try testing.expectEqualSlices(u64, &.{3}, ahead.items);

    var behind: std.ArrayList(u64) = .empty;
    defer behind.deinit(gpa);
    var back = precedingSiblings(try fixture.ref(middle));
    while (back.next()) |node| try behind.append(gpa, node.id().local.value);
    try testing.expectEqualSlices(u64, &.{ 1 }, behind.items);
}

test "the filtered sibling cursors skip a node the filter excludes" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    // Four children around the node the test walks from. The one after it is
    // excluded with `exclude_subtree`, so the cursor must step over it rather
    // than stop at it.
    const root = try fixture.add(0, null);
    const first = try fixture.add(1, root);
    const middle = try fixture.add(2, root);
    const kept = try fixture.add(3, root);
    const closed = try fixture.add(4, root);
    try fixture.setChildren(root, &.{ 1, 2, 3, 4 });
    for ([_]usize{ 0, 1, 2, 3 }) |position| {
        fixture.setIndex(FullNodeId.init(.{ .value = position + 1 }, .init(0)), position);
    }
    fixture.setRole(root, .list_item);
    fixture.setRole(first, .list_item);
    fixture.setRole(kept, .list_item);
    fixture.setRole(closed, .button);

    var ahead: std.ArrayList(u64) = .empty;
    defer ahead.deinit(gpa);
    var cursor = try followingFilteredSiblings(try fixture.ref(middle), roleFilter());
    while (try cursor.next()) |node| try ahead.append(gpa, node.id().local.value);
    try testing.expectEqualSlices(u64, &.{3}, ahead.items);

    var behind: std.ArrayList(u64) = .empty;
    defer behind.deinit(gpa);
    var back = try precedingFilteredSiblings(try fixture.ref(middle), roleFilter());
    while (try back.next()) |node| try behind.append(gpa, node.id().local.value);
    try testing.expectEqualSlices(u64, &.{1}, behind.items);
}

test "filteredChildren descends into an excluded node and skips an excluded subtree" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null);
    const container = try fixture.add(1, root);
    const buried = try fixture.add(2, container);
    const kept = try fixture.add(3, root);
    const closed = try fixture.add(4, root);
    const sealed = try fixture.add(5, closed);
    try fixture.setChildren(root, &.{ 1, 3, 4 });
    try fixture.setChildren(container, &.{ 2 });
    try fixture.setChildren(kept, &.{});
    try fixture.setChildren(closed, &.{ 5 });
    try fixture.setChildren(sealed, &.{});
    fixture.setRole(container, .group);
    fixture.setRole(buried, .paragraph);
    fixture.setRole(kept, .list_item);
    fixture.setRole(closed, .button);
    fixture.setRole(sealed, .paragraph);

    const root_node = try fixture.ref(root);
    var collected: std.ArrayList(u64) = .empty;
    defer collected.deinit(gpa);
    var cursor = try filteredChildren(root_node, roleFilter());
    while (try cursor.next()) |node| try collected.append(gpa, node.id().local.value);
    // `buried` is reachable only because `exclude_node` on `container` opens it,
    // and `sealed` is absent only because `exclude_subtree` on `closed`
    // closes it. A port that mapped both tags to one answer gets one of these
    // two wrong.
    try testing.expectEqualSlices(u64, &.{ 2, 3 }, collected.items);
}

test "deepestFirstChild and deepestLastChild walk to the two ends of a chain" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null);
    const left = try fixture.add(1, root);
    const right = try fixture.add(2, root);
    const left_leaf = try fixture.add(3, left);
    const right_leaf = try fixture.add(4, right);
    try fixture.setChildren(root, &.{ 1, 2 });
    try fixture.setChildren(left, &.{ 3 });
    try fixture.setChildren(right, &.{ 4 });
    try fixture.setChildren(left_leaf, &.{});
    try fixture.setChildren(right_leaf, &.{});

    const root_node = try fixture.ref(root);
    try expectSameId(left_leaf, (try deepestFirstChild(root_node)).?.id());
    try expectSameId(right_leaf, (try deepestLastChild(root_node)).?.id());

    const leaf_node = try fixture.ref(left_leaf);
    try testing.expect((try deepestFirstChild(leaf_node)) == null);
    try testing.expect((try deepestLastChild(leaf_node)) == null);
}

test "the filtered deepest-child walks open an excluded node and close a subtree" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null);
    const container = try fixture.add(1, root);
    const buried = try fixture.add(2, container);
    const kept = try fixture.add(3, root);
    const closed = try fixture.add(4, root);
    const sealed = try fixture.add(5, closed);
    try fixture.setChildren(root, &.{ 1, 3, 4 });
    try fixture.setChildren(container, &.{ 2 });
    try fixture.setChildren(buried, &.{});
    try fixture.setChildren(kept, &.{});
    try fixture.setChildren(closed, &.{ 5 });
    try fixture.setChildren(sealed, &.{});
    fixture.setRole(container, .group);
    fixture.setRole(buried, .paragraph);
    fixture.setRole(kept, .list_item);
    fixture.setRole(closed, .button);
    fixture.setRole(sealed, .paragraph);

    const root_node = try fixture.ref(root);
    // The first and last children the filter includes are `buried` and `kept`,
    // and neither has a child the filter includes, so both walks stop there.
    try expectSameId(buried, (try deepestFirstFilteredChild(root_node, roleFilter())).?.id());
    try expectSameId(kept, (try deepestLastFilteredChild(root_node, roleFilter())).?.id());

    // Inside the closed subtree the walk still runs, because the filter is
    // consulted on the children and not on the subtree that was skipped.
    try expectSameId(sealed,
        (try deepestFirstFilteredChild(try fixture.ref(closed), roleFilter())).?.id(),
    );

    // With a filter that includes everything, the first child of the first
    // child is the answer, and no `exclude_node` opened anything.
    try expectSameId(buried,
        (try deepestFirstFilteredChild(root_node, includeAllFilter())).?.id(),
    );
}

test "a child cycle reaches the bound and reports TreeCycle" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    // Two nodes that list each other. The parent chain stays acyclic, so the
    // ancestry and transform walks are not the ones that see it.
    const first = try fixture.add(0, null);
    const second = try fixture.add(1, null);
    try fixture.setChildren(first, &.{1});
    try fixture.setChildren(second, &.{ 1 });

    const first_node = try fixture.ref(first);
    // Without a bound neither of these returns.
    try testing.expectError(error.TreeCycle, deepestFirstChild(first_node));
    try testing.expectError(error.TreeCycle, deepestLastChild(first_node));

    // The positive half, one step short of the bound.
    try fixture.setChildren(second, &.{});
    try expectSameId(second, (try deepestFirstChild(first_node)).?.id());
    try expectSameId(second, (try deepestLastChild(first_node)).?.id());
}

test "a filtered descendant walk over a cycle reaches its own bound" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const first = try fixture.add(0, null);
    const second = try fixture.add(1, null);
    try fixture.setChildren(first, &.{1});
    try fixture.setChildren(second, &.{ 1 });
    fixture.setRole(first, .group);
    fixture.setRole(second, .group);

    // The filter excludes both nodes with `exclude_node`, so the step descends
    // forever and only the step bound ends it.
    try testing.expectError(
        error.TreeCycle,
        deepestFirstFilteredChild(try fixture.ref(first), roleFilter()),
    );
    try testing.expectError(
        error.TreeCycle,
        deepestLastFilteredChild(try fixture.ref(first), roleFilter()),
    );
    // The positive half. The chain still cycles, so a filter that includes the
    // child would walk 0 to 1 to 0 for ever and reach the level bound; the
    // answer only comes from breaking the cycle and then including every node.
    try fixture.setChildren(second, &.{});
    try expectSameId(second,
        (try deepestFirstFilteredChild(try fixture.ref(first), includeAllFilter())).?.id(),
    );
    try expectSameId(second,
        (try deepestLastFilteredChild(try fixture.ref(first), includeAllFilter())).?.id(),
    );
}

test "isDescendantOf is inclusive of the node itself" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null);
    const middle = try fixture.add(1, root);
    const leaf = try fixture.add(2, middle);
    const leaf_node = try fixture.ref(leaf);

    try testing.expect(try isDescendantOf(leaf_node, try fixture.ref(root)));
    try testing.expect(try isDescendantOf(leaf_node, try fixture.ref(middle)));
    // Upstream tests before it moves, so a node is its own descendant.
    try testing.expect(try isDescendantOf(leaf_node, leaf_node));
    try testing.expect(!try isDescendantOf(try fixture.ref(root), leaf_node));
}

test "isDescendantOf on a parent cycle reaches the bound and reports TreeCycle" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const first = try fixture.add(0, null);
    const second = try fixture.add(1, first);
    const outside = try fixture.add(2, null);
    fixture.state.nodes.getPtr(first).?.parent_and_index = .{
        .parent_id = second,
        .index = 0,
    };
    fixture.state.nodes.getPtr(second).?.parent_and_index = .{
        .parent_id = first,
        .index = 0,
    };

    const first_node = try fixture.ref(first);
    try testing.expectError(error.TreeCycle, isDescendantOf(first_node, try fixture.ref(outside)));

    // The positive half: an ancestor that is on the chain stops the walk.
    try testing.expect(try isDescendantOf(first_node, try fixture.ref(second)));
}