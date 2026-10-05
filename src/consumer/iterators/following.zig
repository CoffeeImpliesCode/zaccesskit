//! The cursors over the siblings that follow a node, and one of the two
//! filtered siblings.
//!
//! Upstream: `accesskit_consumer/src/iterators.rs:79-165` for
//! `FollowingSiblings` and `:341-403` for `FollowingFilteredSiblings`.
//!
//! **The iterator representation is stated once, in `iterators/children.zig`.**
//! That file owns `ChildIdsIterator` and carries the contract every cursor in
//! the directory shares: no cursor writes to the tree, so an abandoned
//! iteration leaves nothing behind, and a cursor's borrow of a `children`
//! slice and of a `TreeState` ends at the next call that can grow
//! `TreeState.nodes`. Read that file for the rule; it is not repeated here.
//!
//! **How a filtered cursor's back end is derived.** The filter answers "may
//! this node be a sibling in the walk", never "may this node be the walk's far
//! end". The front is the next node the filter includes, read by a scan in
//! `sibling_scan.zig`. The back is found without asking the filter about an
//! ancestor at all: it is the last included child of `node`'s nearest ancestor,
//! whatever role that ancestor has. A filter that includes only leaves
//! therefore still walks, which is the shape of every text-run filter: it
//! matches no ancestor of a text run, and a back end read from
//! `children.zig`'s `filteredParent` was `null` for every document, so the
//! cursor set `done` on its first line and both ends yielded `null`.
//!
//! Upstream reaches the same back end by another route. `iterators.rs:351-353`
//! reads `node.filtered_parent(&filter).and_then(|parent|
//! parent.last_filtered_child(&filter))`, and `text_node_filter` at
//! `text.rs:932-938` includes the root precisely so that step succeeds. That
//! clause has no home in a `FilterFn`, which carries no context: naming a root
//! in the context would make the caller responsible for keeping it alive
//! across every walk the cursor makes, so a caller that drops the cursor early
//! and a caller that consumes it in the same call would owe different things.
//! Deriving the ancestor instead of filtering for it keeps the back end
//! independent of which roles a filter names, which a second role-based filter
//! naming `Role.document` would not: `Role.label` and `Role.terminal` satisfy
//! `supportsTextRanges` upstream too, so the filters that break this way are
//! not one.
//!
//! **Why a sibling cursor reads the state itself.** `FollowingSiblings::new` at
//! `iterators.rs:88-114` calls `node.parent_and_index()`, then `parent.is_graft()`
//! and then `parent.data().children()`. The first is
//! `node_ref/hierarchy.zig`, the second is `node_ref/properties.zig`, and both
//! are at L5 while this file is L4, so the cursor reads
//! `NodeState.parent_and_index` and the `children` property directly.
//! `docs/33` section 1.3 blesses that pattern for exactly this case.
//! `following_sibling_ids` therefore takes the parent and the node id rather
//! than a `NodeRef`, because its caller already has both.
//!
//! **What a graft parent yields.** Nothing. A graft node has exactly one
//! child, the root of its subtree, so there is no list to walk and no sibling
//! to name. That is upstream `iterators.rs:92-94` and `:184-186`, and
//! `parent` being `null` yields nothing for the same reason.
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

// --- The unfiltered following-sibling cursors --------------------------------

/// The ids of the siblings that follow a node, front to back. Upstream
/// `struct FollowingSiblings`, `iterators.rs:79-85`.
///
/// The value owns nothing. It copies the `children` slice of the parent node
/// and its `FullNodeId`, and borrows the parent's property store, so the slice
/// is invalidated by the next write to that property. A copy is a second
/// cursor over the same ids and must not be advanced and expected to agree
/// with the original.
pub const FollowingSiblingIdsIterator = struct {
    /// The tree every yielded id is read in, which is the tree of the node
    /// whose siblings these are. A copy, so it outlives the cursor.
    node_id: FullNodeId,

    /// The parent's `children` property. Empty when the cursor yields nothing,
    /// which is the case for a graft parent and for a node with no parent.
    /// Borrowed from the store, so a write to that property invalidates it.
    children: []const NodeId,

    /// The next index `next` reads.
    front: usize,

    /// The last index `nextBack` reads, inclusive.
    back: usize,

    /// Set once the front and the back meet, so a spent cursor stays spent.
    /// Upstream's `done` at `iterators.rs:100`.
    done: bool,

    /// The next following sibling id, or `null` once the cursor is spent.
    pub fn next(self: *FollowingSiblingIdsIterator) ?FullNodeId {
        if (self.done) return null;
        self.done = self.front == self.back;
        if (self.front >= self.children.len) return null;
        const local = self.children[self.front];
        self.front += 1;
        return self.node_id.withSameTree(local);
    }

    /// The last unconsumed following sibling id, or `null` once the cursor is
    /// spent. Consumes the back index on success.
    pub fn nextBack(self: *FollowingSiblingIdsIterator) ?FullNodeId {
        if (self.done) return null;
        self.done = self.back == self.front;
        if (self.back >= self.children.len) return null;
        const local = self.children[self.back];
        self.back -= 1;
        return self.node_id.withSameTree(local);
    }
    /// How many ids are still unconsumed. Upstream's `size_hint` at
    /// `iterators.rs:136-142` computes this number, and
    /// `ExactSizeIterator` at `:163` consumes it as `len`. The back index is
    /// inclusive, which is where the `+ 1` comes from.
    pub fn len(self: *const FollowingSiblingIdsIterator) usize {
        if (self.done) return 0;
        return self.back + 1 - self.front;
    }
};

/// The following sibling ids of the node named `node_id` under `parent`.
///
/// `parent` is `null` at the top of the tree and the cursor then yields
/// nothing, which is upstream `iterators.rs:104-106`. A graft `parent` yields
/// nothing for the reason in the module doc.
pub fn following_sibling_ids(
    parent: ?NodeRef,
    id: FullNodeId,
) FollowingSiblingIdsIterator {
    const parent_node = parent orelse return emptySiblings(id);
    if (schema.option.treeId(&parent_node.data().properties) != null) {
        return emptySiblings(id);
    }
    const listed = schema.ids_props.children(&parent_node.data().properties);
    if (listed.len == 0) return emptySiblings(id);
    // Upstream reads this as `node.parent_and_index()` at `iterators.rs:89`, so
    // the index comes from the node's own entry rather than the parent's.
    const child = NodeRef.init(parent_node.tree_state, id) orelse
        return emptySiblings(id);
    const slot = child.state.parent_and_index orelse return emptySiblings(id);
    const front = slot.index + 1;
    return .{
        .node_id = id,
        .children = listed,
        .front = front,
        .back = listed.len - 1,
        .done = front > listed.len - 1,
    };
}

/// The nodes of the siblings that follow a node. Upstream
/// `following_sibling_ids` mapped through the state's lookup, `node.rs:202-208`.
///
/// The value owns nothing. It copies the id cursor and borrows the state the
/// lookups go through, so both borrows end at the next call that can grow
/// `TreeState.nodes`.
pub const FollowingSiblingsIterator = struct {
    /// The id cursor this one looks each id up from. A copy, so the two advance
    /// together.
    ids: FollowingSiblingIdsIterator,

    /// The state the lookups go through. Borrowed, so it must outlive the
    /// cursor and the borrow ends at the next call that can grow
    /// `TreeState.nodes`.
    tree_state: *const TreeState,

    /// How many ids the wrapped cursor had when this one was built. A skipped
    /// id costs a step even though it costs no item, so the loop bound cannot
    /// be the count of ids still left: that falls as the loop runs and the
    /// loop would stop before the gap.
    budget: usize,

    /// The next following sibling node, or `null` once the cursor is spent. An
    /// id the state holds no entry for is skipped, which is invariant I2
    /// broken; upstream unwraps the same lookup at `node.rs:207` and panics.
    pub fn next(self: *FollowingSiblingsIterator) ?NodeRef {
        var steps: usize = 0;
        while (steps < self.budget) : (steps += 1) {
            const id = self.ids.next() orelse return null;
            if (NodeRef.init(self.tree_state, id)) |node| return node;
        }
        return null;
    }

    /// The last unconsumed following sibling node, or `null` once the cursor is
    /// spent. Skips a missing entry on the same terms as `next`.
    pub fn nextBack(self: *FollowingSiblingsIterator) ?NodeRef {
        var steps: usize = 0;
        while (steps < self.budget) : (steps += 1) {
            const id = self.ids.nextBack() orelse return null;
            if (NodeRef.init(self.tree_state, id)) |node| return node;
        }
        return null;
    }
};

/// The following sibling nodes of `ids`, each looked up in `state`. Upstream
/// `node.rs:202-208`.
///
/// `ids` must have been built from a node in `state`, so the two agree about
/// which tree every sibling id names.
pub fn followingSiblings(
    ids: FollowingSiblingIdsIterator,
    state: *const TreeState,
) FollowingSiblingsIterator {
    return .{ .ids = ids, .tree_state = state, .budget = ids.len() };
}

// --- The filtered siblings ----------------------------------------------------

/// Which end of the filtered order a cursor walks towards. Upstream spells
/// this as two structs, `FollowingFilteredSiblings` at `iterators.rs:341` and
/// `PrecedingFilteredSiblings` at `:409`, with identical fields and opposite
/// step functions. One struct with a direction carries the same state and
/// names the one thing that differs.
pub const ScanDirection = enum {
    /// Step forwards with `nextFilteredSibling`, which opens an excluded node
    /// and closes an excluded subtree.
    following,
    /// Step backwards with `previousFilteredSibling`, which reads each level
    /// back to front.
    preceding,
};

/// The siblings that follow or precede a node and that `filter` includes. One
/// type for both directions; the constructor in `preceding.zig` sets the
/// direction.
///
/// The value owns nothing and takes no allocator: `filter` is a plain function
/// pointer and the two ends are borrowed `NodeRef` handles. Dropping the
/// cursor early writes nothing; see `iterators/children.zig` for what a write
/// invalidates.
pub const FilteredSiblingsIterator = struct {
    /// The test applied to every node the cursor visits. It is a pointer, so
    /// the function it names must outlive the cursor.
    filter: FilterFn,

    /// The next node to yield from the front, or `null` when the front is
    /// spent.
    front: ?NodeRef,

    /// The next node to yield from the back, or `null` when the back is
    /// spent. It bounds the front, so the two never cross. A constructor reads
    /// it from the nearest ancestor of the node the walk starts at, without
    /// consulting the filter about that ancestor; the module doc gives why.
    back: ?NodeRef,

    /// Set once the front and the back meet or one of them is exhausted, so a
    /// spent cursor stays spent. Upstream's `done` at `iterators.rs:357`.
    done: bool,

    /// Which way the scan steps between calls.
    direction: ScanDirection,

    /// The next included sibling from the front, or `null` once the cursor is
    /// spent. Returns `error.TreeCycle` when the scan behind it overruns
    /// `treeWalkStepBound(nodes.count())`, and `error.NoSuchNode` when the
    /// state holds no entry for an id a `children` list names.
    pub fn next(self: *FilteredSiblingsIterator) QueryError!?NodeRef {
        if (self.done) return null;
        self.done = endsMeet(self.front, self.back);
        const current = self.front;
        self.front = try self.step(self.front);
        return current;
    }

    /// The next included sibling from the back, or `null` once the cursor is
    /// spent. The errors are the ones `next` reports.
    pub fn nextBack(self: *FilteredSiblingsIterator) QueryError!?NodeRef {
        if (self.done) return null;
        self.done = endsMeet(self.front, self.back);
        const current = self.back;
        self.back = try self.stepBack(self.back);
        return current;
    }

    /// The scan from the front, which is the forward scan in a following
    /// cursor and the backward scan in a preceding one.
    fn step(self: *const FilteredSiblingsIterator, from: ?NodeRef) QueryError!?NodeRef {
        return switch (self.direction) {
            .following => try sibling_scan.nextFilteredSibling(from, self.filter),
            .preceding => try sibling_scan.previousFilteredSibling(from, self.filter),
        };
    }

    /// The scan from the back, which is the mirror of `step`.
    fn stepBack(self: *const FilteredSiblingsIterator, from: ?NodeRef) QueryError!?NodeRef {
        return switch (self.direction) {
            .following => try sibling_scan.previousFilteredSibling(from, self.filter),
            .preceding => try sibling_scan.nextFilteredSibling(from, self.filter),
        };
    }
};

/// The siblings that follow `node` and that `filter` includes. Upstream
/// `FollowingFilteredSiblings::new`, `iterators.rs:348-361`.
///
/// The front is the first included node after `node`. The back is the last
/// included child of the nearest ancestor of `node` at all, derived the way
/// the module doc derives it. Upstream reads it from
/// `node.filtered_parent(&filter).and_then(|parent| parent.last_filtered_child(&filter))`
/// at `iterators.rs:351-353`, which needs a filter that includes an ancestor
/// and this `FilterFn` cannot promise one.
///
/// Returns `error.TreeCycle` when a walk behind either end overruns its bound,
/// and `error.NoSuchNode` when the state holds no entry for an id a `children`
/// list names.
pub fn following_filtered_siblings(
    node: NodeRef,
    filter: FilterFn,
) QueryError!FilteredSiblingsIterator {
    const front = try sibling_scan.nextFilteredSibling(node, filter);
    // The back is the last included child of the nearest ancestor at all. The
    // filter is not asked about the ancestor, because a filter written over
    // leaf roles answers `null` for every ancestor there is and the cursor
    // would then be spent before it started.
    const ancestor = parentOf(node);
    const back = if (ancestor) |parent|
        try children_mod.lastFilteredChild(parent, filter)
    else
        null;
    return .{
        .filter = filter,
        .front = front,
        .back = back,
        .done = front == null or back == null,
        .direction = .following,
    };
}

// --- The private steps --------------------------------------------------------

/// The cursor that yields nothing, which is what a graft parent and a node
/// with no parent both produce.
fn emptySiblings(id: FullNodeId) FollowingSiblingIdsIterator {
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

/// True when the front and the back of a filtered cursor have met or one of
/// them is spent. Upstream writes this as the `zip` at `iterators.rs:370-375`.
fn endsMeet(front: ?NodeRef, back: ?NodeRef) bool {
    const one = front orelse return true;
    const other = back orelse return true;
    return sameNode(one.id(), other.id());
}

/// True when two ids name the same node. `FullNodeId` is a plain struct and
/// declares no `eql`, so the comparison is structural and local.
fn sameNode(a: FullNodeId, b: FullNodeId) bool {
    return a.local.eql(b.local) and a.tree_index == b.tree_index;
}

// --- What upstream declares here and this file does not -----------------------

// `iterators.rs:79-115` is one struct with a private `new`, and `docs/33`
// section 8 gives the operation to `node_ref/hierarchy.zig`. The struct and its
// fields move here and the constructor becomes the free function
// `following_sibling_ids`, because `node_ref/hierarchy.zig` is at L5 and
// imports this file.
//
// `iterators.rs:136-142` is `size_hint`, and `:163-165` are the
// `ExactSizeIterator` and `FusedIterator` markers. Zig has neither trait, so
// `len` is the whole of `size_hint` and the `done` flag carries the fused
// guarantee.
//
// `iterators.rs:409-471` is `PrecedingFilteredSiblings`. Its state and both of
// its step functions are the mirror of what this file declares, so it is one
// type here with a `direction`, and `preceding.zig` holds the constructor that
// sets the direction. Nothing is dropped by the merge: `iterators.rs:418` and
// `:422` differ from `iterators.rs:350` and `:354` only in which scan each
// end calls.

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
        try schema.ids_props.setChildren(&self.state.nodes.getPtr(id).?.data.properties, list);
    }

    /// Appends one local id to the node's `children` property, growing the
    /// list the store already holds.
    fn pushChild(self: *Fixture, id: FullNodeId, local: u64) !void {
        try schema.ids_props.pushChild(
            &self.state.nodes.getPtr(id).?.data.properties,
            .{ .value = local },
        );
    }

    fn ref(self: *Fixture, id: FullNodeId) !NodeRef {
        return NodeRef.init(&self.state, id) orelse error.NodeMissingFromState;
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

/// Collects the local ids a following-sibling cursor yields from the front.
fn collectFollowing(
    gpa: std.mem.Allocator,
    node: NodeRef,
) !std.ArrayList(u64) {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(gpa);
    var ids = following_sibling_ids(parentOf(node), node.id());
    const bound = ids.len();
    var cursor = followingSiblings(ids, node.tree_state);
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        const sibling = cursor.next() orelse break;
        try out.append(gpa, sibling.id().local.value);
    }
    return out;
}

test "a lone node and a root yield no following sibling" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .group);
    const only = try fixture.add(1, root, 0, .button);
    try fixture.setChildren(root, &.{1});

    var from_only = following_sibling_ids(parentOf(try fixture.ref(only)), only);
    try testing.expect(from_only.next() == null);
    try testing.expect(from_only.nextBack() == null);
    try testing.expectEqual(@as(usize, 0), from_only.len());

    // A root has no parent, so its cursor is empty on the same grounds.
    var from_root = following_sibling_ids(parentOf(try fixture.ref(root)), root);
    try testing.expect(from_root.next() == null);
    try testing.expectEqual(@as(usize, 0), from_root.len());
}

test "following sibling ids cover every later sibling from either end" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .group);
    for ([_]u64{ 1, 2, 3, 4 }) |local| {
        _ = try fixture.add(local, root, local - 1, .button);
    }
    try fixture.setChildren(root, &.{ 1, 2, 3, 4 });

    const second = FullNodeId.init(.{ .value = 2 }, .init(0));
    var front: std.ArrayList(u64) = .empty;
    defer front.deinit(gpa);
    var cursor = following_sibling_ids(parentOf(try fixture.ref(second)), second);
    const bound = cursor.len();
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        const id = cursor.next() orelse break;
        try front.append(gpa, id.local.value);
    }
    try testing.expectEqualSlices(u64, &.{ 3, 4 }, front.items);

    var back: std.ArrayList(u64) = .empty;
    defer back.deinit(gpa);
    var reversed = following_sibling_ids(parentOf(try fixture.ref(second)), second);
    taken = 0;
    while (taken < bound) : (taken += 1) {
        const id = reversed.nextBack() orelse break;
        try back.append(gpa, id.local.value);
    }
    try testing.expectEqualSlices(u64, &.{ 4, 3 }, back.items);

    // Two ends on one cursor meet without repeating an item, which is the
    // invariant the `front` and `back` indices carry.
    var meeting = following_sibling_ids(parentOf(try fixture.ref(second)), second);
    const third = meeting.next() orelse return error.NoSibling;
    try testing.expectEqual(@as(u64, 3), third.local.value);
    const fourth = meeting.nextBack() orelse return error.NoSibling;
    try testing.expectEqual(@as(u64, 4), fourth.local.value);
    try testing.expect(meeting.next() == null);
    try testing.expect(meeting.nextBack() == null);
    try testing.expectEqual(@as(usize, 0), meeting.len());

    // The last sibling has nothing behind it, and `len` agrees.
    const last = FullNodeId.init(.{ .value = 4 }, .init(0));
    var spent = following_sibling_ids(parentOf(try fixture.ref(last)), last);
    try testing.expectEqual(@as(usize, 0), spent.len());
    try testing.expect(spent.next() == null);
}

test "a graft parent yields no following sibling even with a child of its own" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .group);
    const graft = try fixture.add(1, root, 0, .group);
    _ = try fixture.add(2, graft, 0, .button);
    try fixture.setChildren(root, &.{1});
    try fixture.setChildren(graft, &.{2});
    try schema.option.setTreeId(
        &fixture.state.nodes.getPtr(graft).?.data.properties,
        schema.treeIdFromBytes(.{7} ** 16),
    );

    // A graft node has one child and no siblings, so upstream `iterators.rs:92-94`
    // yields nothing. A cursor that read the `children` property first would
    // report node 2.
    var cursor = following_sibling_ids(parentOf(try fixture.ref(graft)), graft);
    try testing.expect(cursor.next() == null);
    try testing.expectEqual(@as(usize, 0), cursor.len());
}

test "the node-returning cursor agrees with the id one" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .group);
    const first = try fixture.add(1, root, 0, .button);
    _ = try fixture.add(2, root, 1, .button);
    try fixture.setChildren(root, &.{ 1, 2, 9 });

    // `9` names no node, so upstream panics at `node.rs:207` and this skips
    // it rather than stopping at the gap. Reading from the root would answer
    // nothing at all, because the root has no parent.
    var nodes = try collectFollowing(gpa, try fixture.ref(first));
    defer nodes.deinit(gpa);
    try testing.expectEqualSlices(u64, &.{2}, nodes.items);
}

test "the filtered following cursor opens an excluded node and closes a subtree" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    // The root is a `paragraph`, which `roleFilter` includes, so this is the
    // case where the filter and the ancestor agree on which node the back end
    // is read from. A root the filter excludes is a different case, and it is
    // the subject of `a filter that matches no ancestor still walks the
    // document's children`.
    const root = try fixture.add(0, null, 0, .paragraph);
    const first = try fixture.add(1, root, 0, .paragraph);
    const container = try fixture.add(2, root, 1, .group);
    _ = try fixture.add(3, container, 0, .paragraph);
    const closed = try fixture.add(4, root, 2, .button);
    const trailing = try fixture.add(5, root, 3, .paragraph);
    try fixture.setChildren(root, &.{ 1, 2, 4, 5 });
    try fixture.setChildren(container, &.{3});
    try fixture.setChildren(closed, &.{});
    _ = trailing;

    // `first` is where the cursor starts, so it is not in the answer. Node 3
    // appears only because `exclude_node` on `container` opened it, and node 4
    // is absent because `exclude_subtree` closed it.
    // Each drain loop is bounded by `treeWalkStepBound(nodes.count())`: every
    // item a cursor yields is a distinct node, and one more step than the node
    // count would mean the cursor had repeated one.
    const bound = treeWalkStepBound(fixture.state.nodes.count());
    var front: std.ArrayList(u64) = .empty;
    defer front.deinit(gpa);
    var cursor = try following_filtered_siblings(try fixture.ref(first), roleFilter());
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        const node = (try cursor.next()) orelse break;
        try front.append(gpa, node.id().local.value);
    }
    try testing.expectEqualSlices(u64, &.{ 3, 5 }, front.items);

    var back: std.ArrayList(u64) = .empty;
    defer back.deinit(gpa);
    var reversed = try following_filtered_siblings(try fixture.ref(first), roleFilter());
    taken = 0;
    while (taken < bound) : (taken += 1) {
        const node = (try reversed.nextBack()) orelse break;
        try back.append(gpa, node.id().local.value);
    }
    try testing.expectEqualSlices(u64, &.{ 5, 3 }, back.items);

    // A filter that includes everything reaches the closed sibling too. Node
    // 3 is a child of `container` and not a sibling of `first`, so it is absent
    // from this answer: an all-inclusive filter includes `container` itself, so
    // the scan never opens it.
    var inclusive: std.ArrayList(u64) = .empty;
    defer inclusive.deinit(gpa);
    var all = try following_filtered_siblings(try fixture.ref(first), includeAllFilter());
    taken = 0;
    while (taken < bound) : (taken += 1) {
        const node = (try all.next()) orelse break;
        try inclusive.append(gpa, node.id().local.value);
    }
    try testing.expectEqualSlices(u64, &.{ 2, 4, 5 }, inclusive.items);

    // A filter that excludes everything ends the cursor at once and reports no
    // error, because that is a choice by the filter and not a cycle.
    var none = try following_filtered_siblings(try fixture.ref(first), excludeEveryFilter());
    try testing.expect((try none.next()) == null);
    try testing.expect((try none.nextBack()) == null);
}

test "an abandoned filtered iteration writes nothing and a later read sees the write" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .group);
    const first = try fixture.add(1, root, 0, .paragraph);
    _ = try fixture.add(2, root, 1, .paragraph);
    try fixture.setChildren(root, &.{ 1, 2 });

    // Take one item and drop the cursor. Nothing below releases anything,
    // because nothing below allocated.
    {
        var abandoned = try following_filtered_siblings(try fixture.ref(first), includeAllFilter());
        _ = try abandoned.next();
    }

    // Write to the tree, then read it again from a fresh handle. Growing
    // `TreeState.nodes` may move every entry, so the handles the abandoned
    // cursor held are gone, which is what section 4 of the contract says a
    // `NodeRef` borrow means.
    _ = try fixture.add(3, root, 2, .button);
    try fixture.pushChild(root, 3);

    var after: std.ArrayList(u64) = .empty;
    defer after.deinit(gpa);
    var rebuilt = try following_filtered_siblings(try fixture.ref(first), includeAllFilter());
    var taken: usize = 0;
    while (taken < treeWalkStepBound(fixture.state.nodes.count())) : (taken += 1) {
        const node = (try rebuilt.next()) orelse break;
        try after.append(gpa, node.id().local.value);
    }
    try testing.expectEqualSlices(u64, &.{ 2, 3 }, after.items);

    // The abandoned iteration left the tree itself intact.
    const listed = schema.ids_props.children(&fixture.state.nodes.getPtr(root).?.data.properties);
    try testing.expectEqual(@as(usize, 3), listed.len);
    try testing.expectEqual(@as(u64, 3), listed[2].value);
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
    const first = try fixture.add(1, root, 0, .paragraph);
    _ = try fixture.add(2, root, 1, .paragraph);
    try fixture.setChildren(root, &.{ 1, 2 });

    const start = try fixture.ref(first);
    const bound = treeWalkStepBound(fixture.state.nodes.count());

    var cursor = try following_filtered_siblings(start, paragraphFilter());
    // Both ends are reachable: the front is the second child and the back is
    // the last included child of the document, which is the same node.
    const front_id = (cursor.front orelse return error.NoSibling).id();
    const back_id = (cursor.back orelse return error.NoSibling).id();
    try testing.expectEqual(@as(u64, 2), front_id.local.value);
    try testing.expectEqual(@as(u64, 2), back_id.local.value);
    try testing.expect(!cursor.done);

    var ahead: std.ArrayList(u64) = .empty;
    defer ahead.deinit(gpa);
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        const node = (try cursor.next()) orelse break;
        try ahead.append(gpa, node.id().local.value);
    }
    try testing.expectEqualSlices(u64, &.{2}, ahead.items);
    try testing.expect(cursor.done);
    try testing.expect((try cursor.next()) == null);
    try testing.expect((try cursor.nextBack()) == null);

    // The other end reaches the same node and stops there.
    var behind: std.ArrayList(u64) = .empty;
    defer behind.deinit(gpa);
    var reversed = try following_filtered_siblings(start, paragraphFilter());
    taken = 0;
    while (taken < bound) : (taken += 1) {
        const node = (try reversed.nextBack()) orelse break;
        try behind.append(gpa, node.id().local.value);
    }
    try testing.expectEqualSlices(u64, &.{2}, behind.items);
    try testing.expect(reversed.done);
    try testing.expect((try reversed.nextBack()) == null);
}

test "a filter that includes nothing yields nothing and reports done" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .document);
    const first = try fixture.add(1, root, 0, .paragraph);
    _ = try fixture.add(2, root, 1, .paragraph);
    try fixture.setChildren(root, &.{ 1, 2 });

    // The back end is derived from an ancestor whether or not the filter
    // includes one, and a filter that includes nothing has no included child
    // of that ancestor either. So both ends are spent and the cursor says so
    // rather than asking again: a cursor that re-derives its far end on every
    // call would walk the tree once per call.
    const start = try fixture.ref(first);
    var cursor = try following_filtered_siblings(start, excludeAllFilter());
    try testing.expect(cursor.front == null);
    try testing.expect(cursor.back == null);
    try testing.expect(cursor.done);

    const bound = treeWalkStepBound(fixture.state.nodes.count());
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        try testing.expect((try cursor.next()) == null);
    }

    var reversed = try following_filtered_siblings(start, excludeAllFilter());
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
    const first = try fixture.add(1, root, 0, .paragraph);
    _ = try fixture.add(2, root, 1, .paragraph);
    try fixture.setChildren(root, &.{ 1, 2 });

    const start = try fixture.ref(first);
    const bound = treeWalkStepBound(fixture.state.nodes.count());

    var cursor = try following_filtered_siblings(start, includeAllFilter());
    const back_id = (cursor.back orelse return error.NoSibling).id();
    try testing.expectEqual(@as(u64, 2), back_id.local.value);

    var ahead: std.ArrayList(u64) = .empty;
    defer ahead.deinit(gpa);
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        const node = (try cursor.next()) orelse break;
        try ahead.append(gpa, node.id().local.value);
    }
    try testing.expectEqualSlices(u64, &.{2}, ahead.items);

    var behind: std.ArrayList(u64) = .empty;
    defer behind.deinit(gpa);
    var reversed = try following_filtered_siblings(start, includeAllFilter());
    taken = 0;
    while (taken < bound) : (taken += 1) {
        const node = (try reversed.nextBack()) orelse break;
        try behind.append(gpa, node.id().local.value);
    }
    try testing.expectEqualSlices(u64, &.{2}, behind.items);
}
