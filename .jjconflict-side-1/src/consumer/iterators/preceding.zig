//! The cursors over the siblings that precede a node, and the other half of
//! the filtered siblings.
//!
//! Upstream: `accesskit_consumer/src/iterators.rs:170-253` for
//! `PrecedingSiblings` and `:409-471` for `PrecedingFilteredSiblings`.
//!
//! **The iterator representation is stated once, in `iterators/children.zig`.**
//! That file owns `ChildIdsIterator` and carries the contract every cursor in
//! the directory shares: no cursor writes to the tree, so an abandoned
//! iteration leaves nothing behind, and a cursor's borrow of a `children`
//! slice and of a `TreeState` ends at the next call that can grow
//! `TreeState.nodes`. Read that file for the rule; it is not repeated here.
//!
//! **The filtered sibling rule is stated once, in `iterators/following.zig`.**
//! That file owns `FilteredSiblingsIterator` and derives the back end of a
//! filtered cursor from the nearest ancestor of the node the walk starts at,
//! without asking the filter about that ancestor. Read that module doc for the
//! rule and for why the filter cannot answer that question.
//!
//! **Why a sibling cursor reads the state itself.** `PrecedingSiblings::new` at
//! `iterators.rs:179-201` calls `node.parent_and_index()`, then
//! `parent.is_graft()` and then `parent.data().children()`. The first is
//! `node_ref/hierarchy.zig`, the second is `node_ref/properties.zig`, and both
//! are at L5 while this file is L4, so the cursor reads
//! `NodeState.parent_and_index` and the `children` property directly.
//! `docs/33` section 1.3 blesses that pattern for exactly this case.
//!
//! **Why the walk runs backwards.** The first sibling that precedes `node` is
//! the one at `index - 1`, so `index` zero leaves the front index at zero
//! under `saturating_sub` and marks the cursor spent. The back index starts at
//! zero and rises. That is upstream `iterators.rs:186-188`, and it is why
//! `len` here is `front + 1 - back` rather than the sum its following
//! counterpart uses.
//!
//! **What a graft parent yields.** Nothing. A graft node has exactly one
//! child, the root of its subtree, so there is no list to walk and no sibling
//! to name. That is upstream `iterators.rs:184-186`, and `parent` being `null`
//! yields nothing for the same reason.
//!
//! **What this module does not do.** It allocates nothing, so no function here
//! takes an allocator. It takes no `io`, reads no clock and holds no global.

const std = @import("std");

const schema = @import("../../schema/root.zig");
const tree_index = @import("../tree_index.zig");
const tree_state = @import("../tree_state.zig");
const node_id_mod = @import("../node_id.zig");
const filter_mod = @import("../filter.zig");
const children_mod = @import("children.zig");
const following_mod = @import("following.zig");
const sibling_scan = @import("sibling_scan.zig");

const FullNodeId = tree_index.FullNodeId;
const NodeId = schema.NodeId;
const NodeRef = node_id_mod.NodeRef;
const TreeState = tree_state.TreeState;
const FilterFn = filter_mod.FilterFn;
const FilterResult = filter_mod.FilterResult;
const QueryError = tree_state.QueryError;
const treeWalkStepBound = tree_state.treeWalkStepBound;

const testing = std.testing;

// --- The unfiltered preceding-sibling cursors -------------------------------

/// The ids of the siblings that precede a node, back to front. Upstream
/// `struct PrecedingSiblings`, `iterators.rs:170-176`.
///
/// The value owns nothing. It copies the `children` slice of the parent node
/// and its `FullNodeId`, and borrows the parent's property store, so the slice
/// is invalidated by the next write to that property. A copy is a second
/// cursor over the same ids and must not be advanced and expected to agree
/// with the original.
pub const PrecedingSiblingIdsIterator = struct {
    /// The tree every yielded id is read in, which is the tree of the node
    /// whose siblings these are. A copy, so it outlives the cursor.
    node_id: FullNodeId,

    /// The parent's `children` property. Empty when the cursor yields nothing,
    /// which is the case for a graft parent and for a node with no parent.
    /// Borrowed from the store, so a write to that property invalidates it.
    children: []const NodeId,

    /// The index `next` reads, which falls as the cursor advances.
    front: usize,

    /// The index `nextBack` reads, which rises as the cursor retreats.
    back: usize,

    /// Set once the front and the back meet, so a spent cursor stays spent.
    /// Upstream's `done` at `iterators.rs:192`.
    done: bool,

    /// The next preceding sibling id, or `null` once the cursor is spent. The
    /// front falls only while there is more to read, which is upstream's
    /// `if !self.done { self.front_position -= 1; }` at `iterators.rs:217-219`.
    pub fn next(self: *PrecedingSiblingIdsIterator) ?FullNodeId {
        if (self.done) return null;
        self.done = self.front == self.back;
        if (self.front >= self.children.len) return null;
        const local = self.children[self.front];
        if (!self.done) self.front -= 1;
        return self.node_id.withSameTree(local);
    }

    /// The last unconsumed preceding sibling id, or `null` once the cursor is
    /// spent. The back rises past the end of the list, which is upstream's
    /// `self.back_position += 1;` at `iterators.rs:245`.
    pub fn nextBack(self: *PrecedingSiblingIdsIterator) ?FullNodeId {
        if (self.done) return null;
        self.done = self.back == self.front;
        if (self.back >= self.children.len) return null;
        const local = self.children[self.back];
        self.back += 1;
        return self.node_id.withSameTree(local);
    }

    /// How many ids are still unconsumed. Upstream's `size_hint` at
    /// `iterators.rs:224-230` computes this number, and
    /// `ExactSizeIterator` at `:251` consumes it as `len`.
    pub fn len(self: *const PrecedingSiblingIdsIterator) usize {
        if (self.done) return 0;
        return self.front + 1 - self.back;
    }
};

/// The preceding sibling ids of the node named `node_id` under `parent`.
///
/// `parent` is `null` at the top of the tree and the cursor then yields
/// nothing, which is upstream `iterators.rs:190-192`. A graft `parent` yields
/// nothing for the reason in the module doc, and a node at index zero is spent
/// from the start, which is upstream `iterators.rs:188`.
pub fn precedingSiblingIds(
    parent: ?NodeRef,
    id: FullNodeId,
) PrecedingSiblingIdsIterator {
    const parent_node = parent orelse return emptySiblings(id);
    if (schema.option.treeId(&parent_node.data().properties) != null) {
        return emptySiblings(id);
    }
    const listed = schema.ids_props.children(&parent_node.data().properties);
    if (listed.len == 0) return emptySiblings(id);
    // Upstream reads this as `node.parent_and_index()` at `iterators.rs:180`, so
    // the index comes from the node's own entry rather than the parent's.
    const child = NodeRef.init(parent_node.tree_state, id) orelse
        return emptySiblings(id);
    const slot = child.state.parent_and_index orelse return emptySiblings(id);
    return .{
        .node_id = id,
        .children = listed,
        .front = slot.index -| 1,
        .back = 0,
        .done = slot.index == 0,
    };
}

/// The nodes of the siblings that precede a node. Upstream
/// `preceding_sibling_ids` mapped through the state's lookup, `node.rs:223-229`.
///
/// The value owns nothing. It copies the id cursor and borrows the state the
/// lookups go through, so both borrows end at the next call that can grow
/// `TreeState.nodes`.
pub const PrecedingSiblingsIterator = struct {
    /// The id cursor this one looks each id up from. A copy, so the two advance
    /// together.
    ids: PrecedingSiblingIdsIterator,

    /// The state the lookups go through. Borrowed, so it must outlive the
    /// cursor and the borrow ends at the next call that can grow
    /// `TreeState.nodes`.
    tree_state: *const TreeState,

    /// How many ids the wrapped cursor had when this one was built. A skipped
    /// id costs a step even though it costs no item, so the loop bound cannot
    /// be the count of ids still left: that falls as the loop runs and the
    /// loop would stop before the gap.
    budget: usize,

    /// The next preceding sibling node, or `null` once the cursor is spent. An
    /// id the state holds no entry for is skipped, which is invariant I2
    /// broken; upstream unwraps the same lookup at `node.rs:228` and panics.
    pub fn next(self: *PrecedingSiblingsIterator) ?NodeRef {
        var steps: usize = 0;
        while (steps < self.budget) : (steps += 1) {
            const id = self.ids.next() orelse return null;
            if (NodeRef.init(self.tree_state, id)) |node| return node;
        }
        return null;
    }

    /// The last unconsumed preceding sibling node, or `null` once the cursor is
    /// spent. Skips a missing entry on the same terms as `next`.
    pub fn nextBack(self: *PrecedingSiblingsIterator) ?NodeRef {
        var steps: usize = 0;
        while (steps < self.budget) : (steps += 1) {
            const id = self.ids.nextBack() orelse return null;
            if (NodeRef.init(self.tree_state, id)) |node| return node;
        }
        return null;
    }
};

/// The preceding sibling nodes of `ids`, each looked up in `state`. Upstream
/// `node.rs:223-229`.
///
/// `ids` must have been built from a node in `state`, so the two agree about
/// which tree every sibling id names.
pub fn precedingSiblings(
    ids: PrecedingSiblingIdsIterator,
    state: *const TreeState,
) PrecedingSiblingsIterator {
    return .{ .ids = ids, .tree_state = state, .budget = ids.len() };
}

// --- The filtered siblings, read backwards ----------------------------------

/// The siblings that precede `node` and that `filter` includes.
///
/// The type is `following.zig`'s `FilteredSiblingsIterator` with the direction
/// set to `preceding`: upstream spells it as a second struct at
/// `iterators.rs:409-414` with identical fields, and this constructor is the
/// only place the two differ.
///
/// The front is the first included node before `node`. The back is the first
/// included child of the nearest ancestor of `node` at all, derived the way
/// `following.zig`'s module doc derives it. Upstream reads it from
/// `node.filtered_parent(&filter).and_then(|parent| parent.first_filtered_child(&filter))`
/// at `iterators.rs:419-422`, which needs a filter that includes an ancestor
/// and this `FilterFn` cannot promise one.
///
/// Returns `error.TreeCycle` when a walk behind either end overruns
/// `treeWalkStepBound(nodes.count())`, and `error.NoSuchNode` when the state
/// holds no entry for an id a `children` list names.
pub fn precedingFilteredSiblings(
    node: NodeRef,
    filter: FilterFn,
) QueryError!following_mod.FilteredSiblingsIterator {
    const front = try sibling_scan.previousFilteredSibling(node, filter);
    // The back is the first included child of the nearest ancestor at all, for
    // the reason `following.zig`'s module doc gives.
    const ancestor = parentOf(node);
    const back = if (ancestor) |parent|
        try children_mod.firstFilteredChild(parent, filter)
    else
        null;
    return .{
        .filter = filter,
        .front = front,
        .back = back,
        .done = front == null or back == null,
        .direction = .preceding,
    };
}

// --- The private step ---------------------------------------------------------

/// The cursor that yields nothing, which is what a graft parent and a node
/// with no parent both produce.
fn emptySiblings(id: FullNodeId) PrecedingSiblingIdsIterator {
    return .{
        .node_id = id,
        .children = &.{},
        .front = 0,
        .back = 0,
        .done = true,
    };
}

/// The parent of `node`, or `null` at the top of the tree. Upstream
/// `node.rs:133-136`.
///
/// `parent` is `node_ref/hierarchy.zig`, which is at L5 and imports this file,
/// so this reads `NodeState.parent_and_index` directly. It is the step the
/// back end of a filtered cursor is derived from, and it asks no filter.
fn parentOf(node: NodeRef) ?NodeRef {
    const slot = node.state.parent_and_index orelse return null;
    return NodeRef.init(node.tree_state, slot.parent_id);
}

// --- What upstream declares here and this file does not -----------------------

// `iterators.rs:170-201` is one struct with a private `new`, and `docs/33`
// section 8 gives the operation to `node_ref/hierarchy.zig`. The struct and its
// fields move here and the constructor becomes the free function
// `precedingSiblingIds`, because `node_ref/hierarchy.zig` is at L5 and
// imports this file.
//
// `iterators.rs:224-230` is `size_hint`, and `:251-253` are the
// `ExactSizeIterator` and `FusedIterator` markers. Zig has neither trait, so
// `len` is the whole of `size_hint` and the `done` flag carries the fused
// guarantee.
//
// `iterators.rs:409-471` is `PrecedingFilteredSiblings`. Its state is
// identical to `FollowingFilteredSiblings` and its `next` calls
// `previous_filtered_sibling` where that calls `next_filtered_sibling`, so it
// is one type with a direction. Nothing is dropped by the merge: the two
// upstream structs differ only in which scan each end calls.

// --- The tests ----------------------------------------------------------------

/// A state one test builds a node at a time. The state owns every node, so one
/// `deinit` releases all of them and a test cannot leak one by forgetting it.
const Fixture = struct {
    gpa: std.mem.Allocator,
    state: TreeState = .{},

    /// Releases the map and every node's property buffers.
    fn deinit(self: *Fixture) void {
        self.state.deinit(self.gpa);
        // SAFETY: `state.deinit` released every buffer the fixture owned, and
        // no statement after it reads `self`.
        self.* = undefined;
    }

    /// Stores one node and returns its id. `parent` is `null` for a root and
    /// `index` is the position the node claims in that parent's `children`
    /// list.
    fn add(
        self: *Fixture,
        local: u64,
        parent: ?FullNodeId,
        index: usize,
        role: schema.Role,
    ) !FullNodeId {
        const id = FullNodeId.init(.{ .value = local }, .init(0));
        try self.state.nodes.put(self.gpa, id, .{
            .parent_and_index = if (parent) |p|
                .{ .parent_id = p, .index = index }
            else
                null,
            .data = schema.Node.init(self.gpa, role),
        });
        return id;
    }

    /// Writes the local ids `locals` as the node's `children` property.
    fn setChildren(self: *Fixture, id: FullNodeId, locals: []const u64) !void {
        const list = try self.gpa.alloc(NodeId, locals.len);
        defer self.gpa.free(list);
        for (locals, list) |local, *slot| slot.* = .{ .value = local };
        const entry = try self.slotOf(id);
        try schema.ids_props.setChildren(&entry.data.properties, list);
    }

    fn ref(self: *Fixture, id: FullNodeId) !NodeRef {
        return NodeRef.init(&self.state, id) orelse error.NodeMissingFromState;
    }

    /// The state entry for `id`, so a test can write the node the state owns.
    fn slotOf(self: *Fixture, id: FullNodeId) !*tree_state.NodeState {
        return self.state.nodes.getPtr(id) orelse error.NodeMissingFromState;
    }
};

/// Includes every node, so the cursor under test is the only thing that can
/// end the walk.
fn includeAll(_: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    _ = node;
    return .include;
}

/// Excludes a `group` by opening it and a `button` by closing it, so one
/// filter exercises both branches of the filtered walk.
fn excludeByRole(_: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    return switch (node.data().role) {
        .group => .exclude_node,
        .button => .exclude_subtree,
        else => .include,
    };
}

fn includeAllFilter() FilterFn {
    return .{ .context = null, .filter = includeAll };
}

fn roleFilter() FilterFn {
    return .{ .context = null, .filter = excludeByRole };
}

/// Rejects every node, which closes every branch.
fn excludeEveryNode(_: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    _ = node;
    return .exclude_subtree;
}

fn excludeEveryFilter() FilterFn {
    return .{ .context = null, .filter = excludeEveryNode };
}

/// Collects the local ids a preceding-sibling cursor yields from the front.
fn collectPreceding(
    gpa: std.mem.Allocator,
    node: NodeRef,
) !std.ArrayList(u64) {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(gpa);
    var ids = precedingSiblingIds(parentOf(node), node.id());
    const bound = ids.len();
    var cursor = precedingSiblings(ids, node.tree_state);
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        const sibling = cursor.next() orelse break;
        try out.append(gpa, sibling.id().local.value);
    }
    return out;
}

test "a lone node and a root yield no preceding sibling" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .group);
    const only = try fixture.add(1, root, 0, .button);
    try fixture.setChildren(root, &.{1});

    var from_only = precedingSiblingIds(parentOf(try fixture.ref(only)), only);
    try testing.expect(from_only.next() == null);
    try testing.expect(from_only.nextBack() == null);
    try testing.expectEqual(@as(usize, 0), from_only.len());

    // A root has no parent, so its cursor is empty on the same grounds.
    var from_root = precedingSiblingIds(parentOf(try fixture.ref(root)), root);
    try testing.expect(from_root.next() == null);
    try testing.expectEqual(@as(usize, 0), from_root.len());
}

test "preceding sibling ids cover every earlier sibling from either end" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .group);
    for ([_]u64{ 1, 2, 3, 4 }) |local| {
        _ = try fixture.add(local, root, local - 1, .button);
    }
    try fixture.setChildren(root, &.{ 1, 2, 3, 4 });

    const third = FullNodeId.init(.{ .value = 3 }, .init(0));
    var front: std.ArrayList(u64) = .empty;
    defer front.deinit(gpa);
    var cursor = precedingSiblingIds(parentOf(try fixture.ref(third)), third);
    const bound = cursor.len();
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        const id = cursor.next() orelse break;
        try front.append(gpa, id.local.value);
    }
    try testing.expectEqualSlices(u64, &.{ 2, 1 }, front.items);

    var back: std.ArrayList(u64) = .empty;
    defer back.deinit(gpa);
    var reversed = precedingSiblingIds(parentOf(try fixture.ref(third)), third);
    taken = 0;
    while (taken < bound) : (taken += 1) {
        const id = reversed.nextBack() orelse break;
        try back.append(gpa, id.local.value);
    }
    try testing.expectEqualSlices(u64, &.{ 1, 2 }, back.items);

    // Two ends on one cursor meet without repeating an item, which is the
    // invariant the `front` and `back` indices carry.
    var meeting = precedingSiblingIds(parentOf(try fixture.ref(third)), third);
    const second = meeting.next() orelse return error.NoSibling;
    try testing.expectEqual(@as(u64, 2), second.local.value);
    const leading = meeting.next() orelse return error.NoSibling;
    try testing.expectEqual(@as(u64, 1), leading.local.value);
    try testing.expect(meeting.next() == null);
    try testing.expect(meeting.nextBack() == null);

    // The first sibling has nothing before it, and `len` agrees.
    const first = FullNodeId.init(.{ .value = 1 }, .init(0));
    var spent = precedingSiblingIds(parentOf(try fixture.ref(first)), first);
    try testing.expectEqual(@as(usize, 0), spent.len());
    try testing.expect(spent.next() == null);
}

test "a graft parent yields no preceding sibling even with a child of its own" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .group);
    const graft = try fixture.add(1, root, 0, .group);
    _ = try fixture.add(2, graft, 0, .button);
    try fixture.setChildren(root, &.{1});
    try fixture.setChildren(graft, &.{2});
    const entry = try fixture.slotOf(graft);
    try schema.option.setTreeId(&entry.data.properties, schema.treeIdFromBytes(.{7} ** 16));

    // A graft node has one child and no siblings, so upstream `iterators.rs:184-186`
    // yields nothing. A cursor that read the `children` property first would
    // report node 2.
    var cursor = precedingSiblingIds(parentOf(try fixture.ref(graft)), graft);
    try testing.expect(cursor.next() == null);
    try testing.expectEqual(@as(usize, 0), cursor.len());
}

test "the node-returning cursor agrees with the id one" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .group);
    _ = try fixture.add(1, root, 0, .button);
    // The index a node records must match its position in the list, so node 2
    // claims index 2 and not the 1 the second `add` would give it.
    _ = try fixture.add(2, root, 2, .button);
    try fixture.setChildren(root, &.{ 9, 1, 2 });
    const last = FullNodeId.init(.{ .value = 2 }, .init(0));

    // `9` names no node, so upstream panics at `node.rs:228` and this skips
    // it rather than stopping at the gap.
    var nodes = try collectPreceding(gpa, try fixture.ref(last));
    defer nodes.deinit(gpa);
    try testing.expectEqualSlices(u64, &.{1}, nodes.items);
}

test "the filtered preceding cursor opens an excluded node and closes a subtree" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    // The root is a `paragraph`, which `roleFilter` includes, so this is the
    // case where the filter and the ancestor agree on which node the back end
    // is read from. A root the filter excludes is a different case, and it is
    // the subject of `a filter that matches no ancestor still walks the
    // document's children`.
    const root = try fixture.add(0, null, 0, .paragraph);
    _ = try fixture.add(1, root, 0, .paragraph);
    const container = try fixture.add(2, root, 1, .group);
    _ = try fixture.add(3, container, 0, .paragraph);
    const closed = try fixture.add(4, root, 2, .button);
    const last = try fixture.add(5, root, 3, .paragraph);
    try fixture.setChildren(root, &.{ 1, 2, 4, 5 });
    try fixture.setChildren(container, &.{3});
    try fixture.setChildren(closed, &.{});

    // Each drain loop is bounded by `treeWalkStepBound(nodes.count())`: every
    // item a cursor yields is a distinct node, and one more step than the node
    // count would mean the cursor had repeated one.
    const bound = treeWalkStepBound(fixture.state.nodes.count());
    var front: std.ArrayList(u64) = .empty;
    defer front.deinit(gpa);
    var cursor = try precedingFilteredSiblings(try fixture.ref(last), roleFilter());
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        const node = (try cursor.next()) orelse break;
        try front.append(gpa, node.id().local.value);
    }
    // Node 3 appears only because `exclude_node` on `container` opened it, and
    // `closed` is absent because `exclude_subtree` closed it. `last` is where
    // the walk starts, so it is not in the answer either.
    try testing.expectEqualSlices(u64, &.{ 3, 1 }, front.items);

    var back: std.ArrayList(u64) = .empty;
    defer back.deinit(gpa);
    var reversed = try precedingFilteredSiblings(try fixture.ref(last), roleFilter());
    taken = 0;
    while (taken < bound) : (taken += 1) {
        const node = (try reversed.nextBack()) orelse break;
        try back.append(gpa, node.id().local.value);
    }
    try testing.expectEqualSlices(u64, &.{ 1, 3 }, back.items);

    // A filter that includes everything reaches the closed sibling too. Node 3
    // is a child of `container` and not a sibling of `last`, so it is absent
    // from this answer: an all-inclusive filter includes `container` itself, so
    // the scan never opens it.
    var inclusive: std.ArrayList(u64) = .empty;
    defer inclusive.deinit(gpa);
    var all = try precedingFilteredSiblings(try fixture.ref(last), includeAllFilter());
    taken = 0;
    while (taken < bound) : (taken += 1) {
        const node = (try all.next()) orelse break;
        try inclusive.append(gpa, node.id().local.value);
    }
    try testing.expectEqualSlices(u64, &.{ 4, 2, 1 }, inclusive.items);

    // A filter that excludes everything ends the cursor at once and reports no
    // error, because that is a choice by the filter and not a cycle.
    var none = try precedingFilteredSiblings(try fixture.ref(last), excludeEveryFilter());
    try testing.expect((try none.next()) == null);
    try testing.expect((try none.nextBack()) == null);
}

test "a cycle in the parent chain reaches the filtered cursor bound" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .group);
    const first = try fixture.add(1, root, 0, .group);
    const second = try fixture.add(2, first, 0, .group);
    try fixture.setChildren(root, &.{1});
    try fixture.setChildren(first, &.{2});
    // `second` lists no child. Listing `1` here would close a second cycle,
    // `1 -> 2 -> 1` through the `children` property rather than through
    // `parent_and_index`, and the back end of a filtered cursor descends
    // children, so that walk would report `error.TreeCycle` before the parent
    // chain under test was ever reached. The cycle under test is the one
    // `parent_and_index` closes, below.
    try fixture.setChildren(second, &.{});

    // The root points back into its own subtree, so the parent chain visits
    // second, first, root, second for ever. The front scan walks that chain
    // and the cursor construction reports the tag rather than running on.
    const cyclic = try fixture.slotOf(root);
    cyclic.parent_and_index = .{
        .parent_id = second,
        .index = 0,
    };
    try testing.expectError(
        error.TreeCycle,
        precedingFilteredSiblings(try fixture.ref(second), roleFilter()),
    );

    // The positive half, one step short of the bound: break the cycle at the
    // root and the same call answers. `exclude_node` on the root stops the walk
    // there, so the answer is `null`.
    const broken = try fixture.slotOf(root);
    broken.parent_and_index = null;
    var built = try precedingFilteredSiblings(try fixture.ref(second), roleFilter());
    try testing.expect((try built.next()) == null);

    // A cycle through the `children` property is the other bound this
    // constructor reaches, and the back end is what reaches it: the front scan
    // has already answered `null` by then. Opening `second` back up closes
    // `1 -> 2 -> 1`, and the walk down from the nearest ancestor reports the
    // tag rather than descending it for ever.
    try fixture.setChildren(second, &.{1});
    try testing.expectError(
        error.TreeCycle,
        precedingFilteredSiblings(try fixture.ref(second), roleFilter()),
    );
}

/// Includes a `paragraph` and opens every other role, so a `document` root is
/// visited and skipped and no ancestor of a `paragraph` matches. This is the
/// shape `text/hit_test.zig`'s `textRunFilter` has over a document.
fn includeParagraphOnly(_: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    return switch (node.data().role) {
        .paragraph => .include,
        else => .exclude_node,
    };
}

fn paragraphFilter() FilterFn {
    return .{ .context = null, .filter = includeParagraphOnly };
}

/// Opens every node rather than closing one, so the walk runs to the end of
/// the tree before it answers `null`.
fn excludeEveryNodeAndOpenIt(_: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    _ = node;
    return .exclude_node;
}

fn excludeAllFilter() FilterFn {
    return .{ .context = null, .filter = excludeEveryNodeAndOpenIt };
}

test "a filter that matches no ancestor still walks the document's children" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    // The root is a `document`, which `paragraphFilter` opens without
    // including, so the ancestor the back end needs matches nothing. A back
    // end read from `filteredParent` was `null` here, the cursor was spent
    // before its first item, and this walk yielded nothing.
    const root = try fixture.add(0, null, 0, .document);
    _ = try fixture.add(1, root, 0, .paragraph);
    const second = try fixture.add(2, root, 1, .paragraph);
    try fixture.setChildren(root, &.{ 1, 2 });

    const start = try fixture.ref(second);
    const bound = treeWalkStepBound(fixture.state.nodes.count());

    var cursor = try precedingFilteredSiblings(start, paragraphFilter());
    // Both ends are reachable: the front is the first child and the back is
    // the first included child of the document, which is the same node.
    const front_id = (cursor.front orelse return error.NoSibling).id();
    const back_id = (cursor.back orelse return error.NoSibling).id();
    try testing.expectEqual(@as(u64, 1), front_id.local.value);
    try testing.expectEqual(@as(u64, 1), back_id.local.value);
    try testing.expect(!cursor.done);

    var ahead: std.ArrayList(u64) = .empty;
    defer ahead.deinit(gpa);
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        const node = (try cursor.next()) orelse break;
        try ahead.append(gpa, node.id().local.value);
    }
    try testing.expectEqualSlices(u64, &.{1}, ahead.items);
    try testing.expect(cursor.done);
    try testing.expect((try cursor.next()) == null);
    try testing.expect((try cursor.nextBack()) == null);

    // The other end reaches the same node and stops there.
    var behind: std.ArrayList(u64) = .empty;
    defer behind.deinit(gpa);
    var reversed = try precedingFilteredSiblings(start, paragraphFilter());
    taken = 0;
    while (taken < bound) : (taken += 1) {
        const node = (try reversed.nextBack()) orelse break;
        try behind.append(gpa, node.id().local.value);
    }
    try testing.expectEqualSlices(u64, &.{1}, behind.items);
    try testing.expect(reversed.done);
    try testing.expect((try reversed.nextBack()) == null);
}

test "a filter that includes nothing yields nothing and reports done" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .document);
    _ = try fixture.add(1, root, 0, .paragraph);
    const second = try fixture.add(2, root, 1, .paragraph);
    try fixture.setChildren(root, &.{ 1, 2 });

    // The back end is derived from an ancestor whether or not the filter
    // includes one, and a filter that includes nothing has no included child
    // of that ancestor either. So both ends are spent and the cursor says so
    // rather than asking again.
    const start = try fixture.ref(second);
    var cursor = try precedingFilteredSiblings(start, excludeAllFilter());
    try testing.expect(cursor.front == null);
    try testing.expect(cursor.back == null);
    try testing.expect(cursor.done);

    const bound = treeWalkStepBound(fixture.state.nodes.count());
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        try testing.expect((try cursor.next()) == null);
    }

    var reversed = try precedingFilteredSiblings(start, excludeAllFilter());
    taken = 0;
    while (taken < bound) : (taken += 1) {
        try testing.expect((try reversed.nextBack()) == null);
    }
}

test "a filter that includes the parent finds the back end it found before" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    // The positive half of the ancestor step. An inclusive filter matches the
    // document as well as its children, so the ancestor the back end is
    // derived from is the ancestor the old code filtered for, and the two
    // derivations cannot disagree.
    const root = try fixture.add(0, null, 0, .document);
    _ = try fixture.add(1, root, 0, .paragraph);
    const second = try fixture.add(2, root, 1, .paragraph);
    try fixture.setChildren(root, &.{ 1, 2 });

    const start = try fixture.ref(second);
    const bound = treeWalkStepBound(fixture.state.nodes.count());

    var cursor = try precedingFilteredSiblings(start, includeAllFilter());
    const back_id = (cursor.back orelse return error.NoSibling).id();
    try testing.expectEqual(@as(u64, 1), back_id.local.value);

    var ahead: std.ArrayList(u64) = .empty;
    defer ahead.deinit(gpa);
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        const node = (try cursor.next()) orelse break;
        try ahead.append(gpa, node.id().local.value);
    }
    try testing.expectEqualSlices(u64, &.{1}, ahead.items);

    var behind: std.ArrayList(u64) = .empty;
    defer behind.deinit(gpa);
    var reversed = try precedingFilteredSiblings(start, includeAllFilter());
    taken = 0;
    while (taken < bound) : (taken += 1) {
        const node = (try reversed.nextBack()) orelse break;
        try behind.append(gpa, node.id().local.value);
    }
    try testing.expectEqualSlices(u64, &.{1}, behind.items);
}
