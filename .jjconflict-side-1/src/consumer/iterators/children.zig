//! The child cursors: `ChildIdsIterator`, `ChildrenIterator` and
//! `FilteredChildrenIterator`, plus the three filtered steps they share.
//!
//! Upstream: `accesskit_consumer/src/iterators.rs:22-77` for `ChildIds` and
//! `:477-586` for `FilteredChildren`, with `first_filtered_child` at
//! `node.rs:1013` and `last_filtered_child` at `node.rs:1032`.
//!
//! **The iterator representation, stated once.** Every cursor in
//! `iterators/` is a plain Zig struct with a `next` method that returns
//! `?T`, and the four of them that upstream implements
//! `DoubleEndedIterator` also carry `nextBack`. Upstream's own state machine
//! is kept as fields rather than dropped: the `front` and `back` indices and
//! the `done` flag of `iterators.rs:79-115` are fields here, so the invariant
//! that a cursor never hands back the same item twice is visible in the value
//! rather than implied by a protocol trait. `FusedIterator` has no Zig
//! counterpart, so `done` is what makes a spent cursor stay spent.
//!
//! **What an abandoned iteration leaves behind: nothing, because no cursor
//! here writes.** `next`, `nextBack` and `len` move indices in the cursor's
//! own fields and read the property store. The three files in `iterators/`
//! therefore share this contract rather than each repeating it:
//!
//! - Dropping a cursor early, or stopping after one item, writes nothing to
//!   the tree and holds nothing the tree must release. There is no `deinit` on
//!   any cursor and no allocator parameter on any of them, because there is
//!   nothing to release.
//! - A cursor borrows the `children` slice of the node it was built from, and
//!   a `NodeRef` borrows its entry in `TreeState.nodes`. Both borrows end at
//!   the next call that can grow `TreeState.nodes` or rewrite that property,
//!   which is any `Tree.updateAndProcessChanges`. Build the cursor again from
//!   a freshly built `NodeRef` after an update, exactly as the section 4
//!   ownership sentences require for a `NodeRef`.
//! - A caller that resumes after a write must rebuild the cursor. Resuming a
//!   cursor built before the write reads a `children` slice the write may have
//!   reallocated.
//!
//! **Why the filtered steps live here.** `firstFilteredChild`,
//! `lastFilteredChild` and `filteredParent` are walks over the child cursor,
//! and `docs/33` section 1.3 places the first two in `node_ref/containers.zig`
//! and the third in `node_ref/hierarchy.zig`. Both are above L4 and this
//! module is L4, so `following.zig` and `preceding.zig` cannot import them.
//! They are declared here instead, and `node_ref/containers.zig` and
//! `node_ref/hierarchy.zig` should call these. The cost is that the L5 copies
//! and these three are two implementations of one walk until that happens.
//!
//! **The bounds.** `filteredParent` takes `treeWalkStepBound(nodes.count())`:
//! each step moves to a different ancestor, so an acyclic chain of
//! `node_count` nodes ends by finding no parent, and a chain that repeats a
//! node asks for a `node_count + 1`th step. That is `error.TreeCycle`.
//! `firstFilteredChild` and `lastFilteredChild` take the same bound, and the
//! ascent inside them takes it again: a step descends to a child the walk has
//! not seen, and an ascent step moves to a different ancestor. Both bounds are
//! named in `docs/33` section 7 for these upstream lines, and each has a test
//! that builds a parent cycle one step past the bound.
//!
//! **What this module does not do.** It allocates nothing, so no function here
//! takes an allocator. It takes no `io`, reads no clock and holds no global.
//! It does not open a filter of its own: `FilterFn` and `FilterResult` are
//! `../filter.zig`, and this module calls the filter it is given.
//!
//! **`childIds` takes its graft decision as a parameter.** `isGraft` and
//! `graftChildId` are `node_ref/properties.zig` and `node_ref/hierarchy.zig`,
//! both at L5, so the caller that already has them passes them in.

const std = @import("std");

const schema = @import("../../schema/root.zig");
const tree_index = @import("../tree_index.zig");
const tree_state = @import("../tree_state.zig");
const node_id = @import("../node_id.zig");
const filter_mod = @import("../filter.zig");
const sibling_scan = @import("sibling_scan.zig");

const FullNodeId = tree_index.FullNodeId;
const NodeId = schema.NodeId;
const NodeRef = node_id.NodeRef;
const TreeState = tree_state.TreeState;
const FilterFn = filter_mod.FilterFn;
const FilterResult = filter_mod.FilterResult;
const QueryError = tree_state.QueryError;
const treeWalkStepBound = tree_state.treeWalkStepBound;

const testing = std.testing;

// --- The unfiltered child cursors ---------------------------------------------

/// The ids of one node's children, in the order the node lists them.
/// Upstream `enum ChildIds`, `iterators.rs:22-28`.
///
/// The value owns nothing. It copies the `FullNodeId` of the node that lists
/// the children and borrows the `children` slice of that node's property
/// store, so the borrow ends at the next write to that property. A copy is a
/// second cursor over the same ids, so a copy must not be advanced
/// independently and expected to agree with the original.
pub const ChildIdsIterator = union(enum) {
    /// A node that lists its children. Each id is read in the tree of
    /// `parent_id`, which is the node that names it.
    normal: struct {
        /// The node whose `children` property holds the ids. Borrowed by copy:
        /// the value outlives the cursor.
        parent_id: FullNodeId,
        /// The node's `children` property. Borrowed from the store, so a write
        /// to that property invalidates the slice.
        children: []const NodeId,
        /// The next index `next` reads.
        front: usize,
        /// One past the last index `nextBack` reads.
        back: usize,
    },

    /// A graft node, which has at most one child: the root of its subtree.
    /// `null` means the graft node names a `tree_id` the state holds no
    /// subtree for, which invariant I3 rules out. Upstream returns `None` in
    /// the same case and says nothing.
    graft: ?FullNodeId,

    /// The id `next` would read, without consuming it.
    pub fn peek(self: *const ChildIdsIterator) ?FullNodeId {
        return switch (self.*) {
            .normal => |normal| if (normal.front < normal.back)
                normal.parent_id.withSameTree(normal.children[normal.front])
            else
                null,
            .graft => |child| child,
        };
    }

    /// The next child id, or `null` once the cursor is spent. Consumes the
    /// front index on success and leaves the cursor untouched otherwise.
    pub fn next(self: *ChildIdsIterator) ?FullNodeId {
        switch (self.*) {
            .normal => |*normal| {
                if (normal.front >= normal.back) return null;
                const local = normal.children[normal.front];
                normal.front += 1;
                return normal.parent_id.withSameTree(local);
            },
            .graft => |*child| {
                const found = child.* orelse return null;
                child.* = null;
                return found;
            },
        }
    }

    /// The last unconsumed child id, or `null` once the cursor is spent.
    /// Consumes the back index on success.
    pub fn nextBack(self: *ChildIdsIterator) ?FullNodeId {
        switch (self.*) {
            .normal => |*normal| {
                if (normal.front >= normal.back) return null;
                normal.back -= 1;
                return normal.parent_id.withSameTree(normal.children[normal.back]);
            },
            .graft => |*child| {
                const found = child.* orelse return null;
                child.* = null;
                return found;
            },
        }
    }

    /// How many ids are still unconsumed. Upstream `ExactSizeIterator::len`
    /// at `iterators.rs:65-72`.
    pub fn len(self: *const ChildIdsIterator) usize {
        return switch (self.*) {
            .normal => |normal| normal.back - normal.front,
            .graft => |child| @intFromBool(child != null),
        };
    }
};

/// The cursor over a node's child ids, built from the two graft answers the
/// caller already holds.
///
/// `is_graft` is `node_ref/properties.zig`'s `isGraft` and `graft_child_id`
/// is `node_ref/hierarchy.zig`'s `graftChildId`; both are at L5 and this
/// module is L4. `graft_child_id` is ignored unless `is_graft` is true.
pub fn childIds(
    node: NodeRef,
    is_graft: bool,
    graft_child_id: ?FullNodeId,
) ChildIdsIterator {
    if (is_graft) return .{ .graft = graft_child_id };
    const listed = schema.ids_props.children(&node.data().properties);
    return .{ .normal = .{
        .parent_id = node.id(),
        .children = listed,
        .front = 0,
        .back = listed.len,
    } };
}

/// The nodes of one node's children, in the order the node lists them.
/// Upstream `child_ids` mapped through the state's lookup, `node.rs:181-187`.
///
/// The value owns nothing and holds no allocator. It copies the child id
/// cursor and borrows the state the lookups go through, so both borrows end at
/// the next call that can grow `TreeState.nodes`.
pub const ChildrenIterator = struct {
    /// The id cursor this one looks each id up from. A copy, so the two advance
    /// together.
    ids: ChildIdsIterator,

    /// The state the lookups go through. Borrowed, so it must outlive the
    /// cursor and the borrow ends at the next call that can grow
    /// `TreeState.nodes`.
    tree_state: *const TreeState,

    /// How many ids the wrapped cursor had when this one was built. A skipped
    /// id costs a step even though it costs no item, so the loop bound cannot
    /// be the count of ids still left: that falls as the loop runs and the
    /// loop would stop before the gap.
    budget: usize,

    /// The next child node, or `null` once the cursor is spent. An id the
    /// state holds no entry for is skipped, which is invariant I2 broken;
    /// upstream unwraps the same lookup at `node.rs:186` and panics.
    pub fn next(self: *ChildrenIterator) ?NodeRef {
        var steps: usize = 0;
        while (steps < self.budget) : (steps += 1) {
            const id = self.ids.next() orelse return null;
            if (NodeRef.init(self.tree_state, id)) |node| return node;
        }
        return null;
    }

    /// The last unconsumed child node, or `null` once the cursor is spent.
    /// Skips a missing entry on the same terms as `next`.
    pub fn nextBack(self: *ChildrenIterator) ?NodeRef {
        var steps: usize = 0;
        while (steps < self.budget) : (steps += 1) {
            const id = self.ids.nextBack() orelse return null;
            if (NodeRef.init(self.tree_state, id)) |node| return node;
        }
        return null;
    }
};

/// The child nodes of `ids`, each looked up in `state`. Upstream
/// `node.rs:181-187`.
///
/// `ids` must have been built from a node in `state`, so the two agree about
/// which tree every child id names. Upstream's `.unwrap()` at `node.rs:186` is
/// invariant I2; the cursor here skips a missing entry.
pub fn children(ids: ChildIdsIterator, state: *const TreeState) ChildrenIterator {
    return .{ .ids = ids, .tree_state = state, .budget = ids.len() };
}

/// The first descendant of `node` that `filter` includes, in depth-first
/// pre-order, or `null` when it includes none. Upstream `node.rs:1013-1030`.
///
/// A node the filter returns `exclude_node` for is opened and its children
/// searched. A node it returns `exclude_subtree` for is skipped with
/// everything below it. `error.TreeCycle` when the walk takes more than
/// `treeWalkStepBound(nodes.count())` steps.
pub fn firstFilteredChild(node: NodeRef, filter: FilterFn) QueryError!?NodeRef {
    var steps: usize = 0;
    return firstFilteredDescendant(node, filter, &steps, treeWalkStepBound(
        node.tree_state.nodes.count(),
    ));
}

/// The last descendant of `node` that `filter` includes, reading the children
/// of each level back to front. Upstream `node.rs:1032-1049`.
///
/// The mirror of `firstFilteredChild`, so it takes the same bound and returns
/// the same tag.
pub fn lastFilteredChild(node: NodeRef, filter: FilterFn) QueryError!?NodeRef {
    var steps: usize = 0;
    return lastFilteredDescendant(node, filter, &steps, treeWalkStepBound(
        node.tree_state.nodes.count(),
    ));
}

/// The first child of `node` or of anything under it that `filter` includes,
/// in depth-first pre-order.
///
/// Upstream keeps a `Vec` of one cursor per level at `node.rs:1017` and pushes
/// onto it when a node is excluded with `exclude_node`. This descent is the
/// same walk expressed as recursion, so the cursor per level is the call frame
/// and nothing is allocated. `steps` is the walk's step count and is shared
/// across every level, so a state whose `children` lists form a cycle is
/// caught by the bound rather than by the stack.
fn firstFilteredDescendant(
    node: NodeRef,
    filter: FilterFn,
    steps: *usize,
    bound: usize,
) QueryError!?NodeRef {
    var ids = childIds(node, setsTreeId(node), graftChildOf(node));
    while (ids.next()) |id| {
        steps.* += 1;
        if (steps.* > bound) return error.TreeCycle;
        const child = NodeRef.init(node.tree_state, id) orelse return error.NoSuchNode;
        const result = try filter.call(child);
        switch (result) {
            .include => return child,
            .exclude_node => if (try firstFilteredDescendant(child, filter, steps, bound)) |found|
                return found,
            .exclude_subtree => {},
        }
    }
    return null;
}

/// The last child of `node` or of anything under it that `filter` includes,
/// reading each level back to front. The mirror of `firstFilteredDescendant`.
fn lastFilteredDescendant(
    node: NodeRef,
    filter: FilterFn,
    steps: *usize,
    bound: usize,
) QueryError!?NodeRef {
    var ids = childIds(node, setsTreeId(node), graftChildOf(node));
    while (ids.nextBack()) |id| {
        steps.* += 1;
        if (steps.* > bound) return error.TreeCycle;
        const child = NodeRef.init(node.tree_state, id) orelse return error.NoSuchNode;
        const result = try filter.call(child);
        switch (result) {
            .include => return child,
            .exclude_node => if (try lastFilteredDescendant(child, filter, steps, bound)) |found|
                return found,
            .exclude_subtree => {},
        }
    }
    return null;
}

/// The nearest ancestor of `node` that `filter` includes, or `null` when the
/// walk reaches the top of the tree first. Upstream `node.rs:138-149`.
///
/// The walk starts at the parent, so `node` itself is never tested.
/// `error.TreeCycle` when it takes more than
/// `treeWalkStepBound(nodes.count())` steps.
pub fn filteredParent(node: NodeRef, filter: FilterFn) QueryError!?NodeRef {
    const bound = treeWalkStepBound(node.tree_state.nodes.count());
    var steps: usize = 0;
    var current = parentOf(node) orelse return null;
    // The bound is the loop test rather than a check inside an open loop, so
    // the loop ends by exhausting its count and reporting the tag.
    while (steps < bound) : (steps += 1) {
        if (try filter.call(current) == .include) return current;
        current = parentOf(current) orelse return null;
    }
    return error.TreeCycle;
}

// --- The filtered child cursor ------------------------------------------------

/// The children of one node that a filter includes, in depth-first pre-order
/// across the excluded nodes it opens. Upstream `struct FilteredChildren`,
/// `iterators.rs:477-483`.
///
/// The value owns nothing and takes no allocator: `filter` is a plain
/// function pointer and the two ends are borrowed `NodeRef` handles. Dropping
/// the cursor early writes nothing; see the module doc for what a write
/// invalidates.
pub const FilteredChildrenIterator = struct {
    /// The test applied to every node the cursor visits. It is a pointer, so
    /// the function it names must outlive the cursor.
    filter: FilterFn,

    /// The next node to yield from the front, or `null` when the front is
    /// spent.
    front: ?NodeRef,

    /// The next node to yield from the back, or `null` when the back is
    /// spent. It bounds the front, so the two never cross.
    back: ?NodeRef,

    /// Set once the front and the back meet or one of them is exhausted, so a
    /// spent cursor stays spent. Upstream's `done` at `iterators.rs:494`.
    done: bool,

    /// The next included descendant of `node` from the front, or `null` once
    /// the cursor is spent. Advances the front, and returns
    /// `error.TreeCycle` when the scan behind it overruns its bound.
    pub fn next(self: *FilteredChildrenIterator) QueryError!?NodeRef {
        if (self.done) return null;
        self.done = endsMeet(self.front, self.back);
        const current = self.front;
        self.front = try sibling_scan.nextFilteredSibling(self.front, self.filter);
        return current;
    }

    /// The next included descendant of `node` from the back, or `null` once
    /// the cursor is spent. Advances the back, and returns `error.TreeCycle`
    /// on the same terms as `next`.
    pub fn nextBack(self: *FilteredChildrenIterator) QueryError!?NodeRef {
        if (self.done) return null;
        self.done = endsMeet(self.front, self.back);
        const current = self.back;
        self.back = try sibling_scan.previousFilteredSibling(self.back, self.filter);
        return current;
    }
};

/// The included children of `node`, in depth-first pre-order. Upstream
/// `FilteredChildren::new` at `iterators.rs:484-495`.
///
/// Returns `error.TreeCycle` when either endpoint walk overruns its bound, and
/// `error.NoSuchNode` when the state holds no entry for an id a `children`
/// list names.
pub fn filteredChildren(
    node: NodeRef,
    filter: FilterFn,
) QueryError!FilteredChildrenIterator {
    const front = try firstFilteredChild(node, filter);
    const back = try lastFilteredChild(node, filter);
    return .{
        .filter = filter,
        .front = front,
        .back = back,
        .done = front == null or back == null,
    };
}

// --- The private steps --------------------------------------------------------

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

/// The id examined after `finished` and everything below it, or `null` when
/// that exhausts the subtree of `root`.
/// The parent of `node`, or `null` at the top of the tree. Reads
/// `NodeState.parent_and_index` directly, the pattern `docs/33` section 1.3
/// blesses for a module below `node_ref/hierarchy.zig`.
fn parentOf(node: NodeRef) ?NodeRef {
    const slot = node.state.parent_and_index orelse return null;
    return NodeRef.init(node.tree_state, slot.parent_id);
}

/// True when the node sets the `tree_id` property, which is upstream
/// `NodeRef::is_graft` at `node.rs:122-124`. Read here rather than through
/// `node_ref/properties.zig`, which is at L5.
fn setsTreeId(node: NodeRef) bool {
    return schema.option.treeId(&node.data().properties) != null;
}

/// The one child of a graft node, which is the root of its subtree. Upstream
/// `node.rs:161-166`. A `null` answer names a `tree_id` the state holds no
/// subtree for, which invariant I3 rules out.
fn graftChildOf(node: NodeRef) ?FullNodeId {
    const tree_id = schema.option.treeId(&node.data().properties) orelse return null;
    return node.tree_state.subtreeRoot(tree_id);
}

// --- What upstream declares here and this file does not -----------------------

// `iterators.rs:45-48` and `:136-142` are `size_hint`, and `:562-568` and
// `:224-230` are its two siblings. Zig has no `size_hint`, and `len` is the
// exact answer both of them compute, so `len` is the whole of it.
//
// `iterators.rs:74`, `:163-165`, `:251-253`, `:403` and `:471` are the
// `FusedIterator` marker. There is no trait to implement, so the `done` flag
// of `FilteredChildrenIterator` and the index pair of the unfiltered cursors
// carry the guarantee the marker states.
//
// `iterators.rs:537-585` is `LabelledBy`. `docs/30-port-design.md` section 3.2
// gives `node.rs:719-824` to `node_ref/strings.zig`, which owns `labelled_by`,
// and this file's range `:477-586` ends inside that iterator. It is not
// translated here and this line is the record of that.

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

    /// Stores one node with `role` and returns its id. `parent` is `null` for
    /// a root, and `index` is the position the node claims in that parent's
    /// `children` list.
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

    /// Appends one local id to the node's `children` property, growing the
    /// list the store already holds.
    fn pushChild(self: *Fixture, id: FullNodeId, local: u64) !void {
        const entry = try self.slotOf(id);
        try schema.ids_props.pushChild(&entry.data.properties, .{ .value = local });
    }

    /// Gives the node the `tree_id` property, which makes it a graft node.
    fn setTreeId(self: *Fixture, id: FullNodeId, byte: u8) !void {
        const entry = try self.slotOf(id);
        try schema.option.setTreeId(&entry.data.properties, schema.treeIdFromBytes(.{byte} ** 16));
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

fn includeAllFilter() FilterFn {
    return .{ .context = null, .filter = includeAll };
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

fn roleFilter() FilterFn {
    return .{ .context = null, .filter = excludeByRole };
}

/// Collects every local id a cursor yields from the front.
fn collectFront(gpa: std.mem.Allocator, ids: ChildIdsIterator) !std.ArrayList(u64) {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(gpa);
    var cursor = ids;
    const bound = cursor.len();
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        const id = cursor.next() orelse break;
        try out.append(gpa, id.local.value);
    }
    return out;
}

test "a node with no children yields nothing from either end" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const leaf = try fixture.add(1, null, 0, .button);
    var ids = childIds(try fixture.ref(leaf), false, null);
    try testing.expect(ids.next() == null);
    try testing.expect(ids.nextBack() == null);
    try testing.expectEqual(@as(usize, 0), ids.len());

    // The unfiltered node cursor answers the same on a tree whose root is the
    // only node, so the empty case is not a property of the graft arm alone.
    const only = try fixture.add(2, null, 0, .group);
    var nodes = children(childIds(try fixture.ref(only), false, null), &fixture.state);
    try testing.expect(nodes.next() == null);
    try testing.expect(nodes.nextBack() == null);
}

test "child ids cover every listed child once, from either end" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .group);
    for ([_]u64{ 1, 2, 3, 4 }) |local| {
        _ = try fixture.add(local, root, local - 1, .button);
    }
    try fixture.setChildren(root, &.{ 1, 2, 3, 4 });

    var front = try collectFront(gpa, childIds(try fixture.ref(root), false, null));
    defer front.deinit(gpa);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4 }, front.items);

    var back: std.ArrayList(u64) = .empty;
    defer back.deinit(gpa);
    var reversed_ids = childIds(try fixture.ref(root), false, null);
    const bound = reversed_ids.len();
    var reversed = reversed_ids;
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        const id = reversed.nextBack() orelse break;
        try back.append(gpa, id.local.value);
    }
    try testing.expectEqualSlices(u64, &.{ 4, 3, 2, 1 }, back.items);

    // Two ends on one cursor meet in the middle without repeating an item,
    // which is the invariant the `front` and `back` indices carry.
    var meeting = childIds(try fixture.ref(root), false, null);
    try testing.expectEqual(@as(u64, 1), (meeting.next() orelse return error.NoChild).local.value);
    const fourth = meeting.nextBack() orelse return error.NoChild;
    try testing.expectEqual(@as(u64, 4), fourth.local.value);
    try testing.expectEqual(@as(u64, 2), (meeting.next() orelse return error.NoChild).local.value);
    try testing.expectEqual(@as(u64, 3), (meeting.next() orelse return error.NoChild).local.value);
    try testing.expect(meeting.next() == null);
    try testing.expect(meeting.nextBack() == null);
}

test "a graft node yields its subtree root instead of its children list" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const graft = try fixture.add(1, null, 0, .group);
    const subtree_root = FullNodeId.init(.{ .value = 0 }, .init(1));
    _ = try fixture.add(2, graft, 0, .document);
    try fixture.setTreeId(graft, 1);
    try fixture.setChildren(graft, &.{2});

    try fixture.state.subtrees.put(gpa, schema.treeIdFromBytes(.{1} ** 16), .{
        .root = subtree_root,
        .focus = subtree_root,
    });

    var ids = childIds(try fixture.ref(graft), true, subtree_root);
    try testing.expectEqual(subtree_root, (ids.next() orelse return error.NoChild));
    try testing.expect(ids.next() == null);
    try testing.expectEqual(@as(usize, 0), ids.len());

    // The same node read as a normal node lists `2`, so a cursor that read the
    // children property first reports the wrong child.
    var as_normal = childIds(try fixture.ref(graft), false, null);
    const listed = as_normal.next() orelse return error.NoChild;
    try testing.expectEqual(@as(u64, 2), listed.local.value);
}

test "the children cursor answers nodes and skips an id with no entry" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .group);
    _ = try fixture.add(1, root, 0, .button);
    _ = try fixture.add(2, root, 1, .button);
    try fixture.setChildren(root, &.{ 1, 7, 2 });

    var nodes: std.ArrayList(u64) = .empty;
    defer nodes.deinit(gpa);
    var ids = childIds(try fixture.ref(root), false, null);
    const bound = ids.len();
    var cursor = children(ids, &fixture.state);
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        const node = cursor.next() orelse break;
        try nodes.append(gpa, node.id().local.value);
    }

    // `7` names no node, so upstream panics at `node.rs:186` and this skips
    // it. A cursor that stopped at the gap would lose the child behind it.
    try testing.expectEqualSlices(u64, &.{ 1, 2 }, nodes.items);
}

test "the filtered children cursor opens an excluded node and closes a subtree" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .group);
    const container = try fixture.add(1, root, 0, .group);
    _ = try fixture.add(2, container, 0, .paragraph);
    const closed = try fixture.add(3, root, 1, .button);
    _ = try fixture.add(4, root, 2, .paragraph);
    try fixture.setChildren(root, &.{ 1, 3, 4 });
    try fixture.setChildren(container, &.{2});
    try fixture.setChildren(closed, &.{});

    const bound = treeWalkStepBound(fixture.state.nodes.count());
    var collected: std.ArrayList(u64) = .empty;
    defer collected.deinit(gpa);
    var cursor = try filteredChildren(try fixture.ref(root), roleFilter());
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        const node = (try cursor.next()) orelse break;
        try collected.append(gpa, node.id().local.value);
    }

    // `buried` appears only because `exclude_node` on `container` opened it,
    // and nothing below `closed` appears because `exclude_subtree` closed it.
    try testing.expectEqualSlices(u64, &.{ 2, 4 }, collected.items);

    var backwards: std.ArrayList(u64) = .empty;
    defer backwards.deinit(gpa);
    var reversed = try filteredChildren(try fixture.ref(root), roleFilter());
    taken = 0;
    while (taken < bound) : (taken += 1) {
        const node = (try reversed.nextBack()) orelse break;
        try backwards.append(gpa, node.id().local.value);
    }
    try testing.expectEqualSlices(u64, &.{ 4, 2 }, backwards.items);
}

test "a filter that includes everything and one that excludes everything" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .group);
    const first = try fixture.add(1, root, 0, .paragraph);
    _ = try fixture.add(2, root, 1, .paragraph);
    try fixture.setChildren(root, &.{ 1, 2 });

    // Each drain loop is bounded by `treeWalkStepBound(nodes.count())`: every
    // item the cursor yields is a distinct node, and one more step than the node
    // count would mean the cursor repeated one.
    const bound = treeWalkStepBound(fixture.state.nodes.count());
    var all: std.ArrayList(u64) = .empty;
    defer all.deinit(gpa);
    var inclusive = try filteredChildren(try fixture.ref(root), includeAllFilter());
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        const node = (try inclusive.next()) orelse break;
        try all.append(gpa, node.id().local.value);
    }
    try testing.expectEqualSlices(u64, &.{ 1, 2 }, all.items);

    // A filter that rejects every node answers nothing and reports no error,
    // because a filter that excludes everything is a choice, not a cycle.
    var none: std.ArrayList(u64) = .empty;
    defer none.deinit(gpa);
    var exclusive = try filteredChildren(try fixture.ref(root), excludeEveryFilter());
    taken = 0;
    while (taken < bound) : (taken += 1) {
        const node = (try exclusive.next()) orelse break;
        try none.append(gpa, node.id().local.value);
    }
    try testing.expectEqual(@as(usize, 0), none.items.len);
    try testing.expect((try exclusive.next()) == null);
    try testing.expect((try exclusive.nextBack()) == null);

    // The same on a node with children of its own, so the answer is not an
    // artifact of the root having a single level.
    const no_front = try firstFilteredChild(try fixture.ref(root), excludeEveryFilter());
    try testing.expect(no_front == null);
    const no_back = try lastFilteredChild(try fixture.ref(root), excludeEveryFilter());
    try testing.expect(no_back == null);
    _ = first;
}

/// Rejects every node, which is `exclude_subtree` and so closes every branch.
fn excludeEveryNode(_: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    _ = node;
    return .exclude_subtree;
}

fn excludeEveryFilter() FilterFn {
    return .{ .context = null, .filter = excludeEveryNode };
}

test "an abandoned iteration writes nothing and a later read sees the write" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .group);
    _ = try fixture.add(1, root, 0, .paragraph);
    _ = try fixture.add(2, root, 1, .paragraph);
    try fixture.setChildren(root, &.{ 1, 2 });

    // Take one item and drop the cursor on the floor. Nothing below releases
    // anything, because nothing below allocated.
    {
        var abandoned = try filteredChildren(try fixture.ref(root), includeAllFilter());
        _ = try abandoned.next();
    }

    // Add a third child and make it one the filter includes. Growing
    // `TreeState.nodes` may move every entry, so the handles the abandoned
    // cursor held are gone and a new one is built, which is what section 4 of
    // the contract requires of a `NodeRef`.
    const added = try fixture.add(3, root, 2, .button);
    _ = added;
    try fixture.pushChild(root, 3);

    var after: std.ArrayList(u64) = .empty;
    defer after.deinit(gpa);
    var rebuilt = try filteredChildren(try fixture.ref(root), includeAllFilter());
    var taken: usize = 0;
    while (taken < treeWalkStepBound(fixture.state.nodes.count())) : (taken += 1) {
        const node = (try rebuilt.next()) orelse break;
        try after.append(gpa, node.id().local.value);
    }
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, after.items);

    // The abandoned iteration also left the tree itself intact: a fresh read
    // of the property agrees with what the cursor reported.
    const entry = try fixture.slotOf(root);
    const listed = schema.ids_props.children(&entry.data.properties);
    try testing.expectEqual(@as(usize, 3), listed.len);
    try testing.expectEqual(@as(u64, 3), listed[2].value);
}

test "the filtered walks reach their bound on a parent cycle and report TreeCycle" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .group);
    const first = try fixture.add(1, root, 0, .group);
    const second = try fixture.add(2, first, 0, .group);
    try fixture.setChildren(root, &.{1});
    try fixture.setChildren(first, &.{2});
    try fixture.setChildren(second, &.{1});

    // The root points back into its own subtree, so the parent chain visits
    // second, first, root, second for ever. That is what invariant I1 rules
    // out, and each walk must report it rather than hang.
    const cyclic = try fixture.slotOf(root);
    cyclic.parent_and_index = .{
        .parent_id = second,
        .index = 0,
    };

    // `exclude_node` on every node keeps each descent going, so only the bound
    // ends any of the three walks.
    try testing.expectError(error.TreeCycle, filteredParent(try fixture.ref(second), roleFilter()));
    try testing.expectError(
        error.TreeCycle,
        firstFilteredChild(try fixture.ref(root), roleFilter()),
    );
    try testing.expectError(
        error.TreeCycle,
        lastFilteredChild(try fixture.ref(root), roleFilter()),
    );

    // The positive half, one step short of the bound: break both cycles, the
    // parent chain at the root and the descent at the far end, and the same
    // calls answer. `exclude_node` on every node is what made the descent
    // unbounded, so an empty list ends it.
    const broken = try fixture.slotOf(root);
    broken.parent_and_index = null;
    try fixture.setChildren(second, &.{});
    try testing.expect((try filteredParent(try fixture.ref(second), roleFilter())) == null);
    try testing.expect((try firstFilteredChild(try fixture.ref(root), roleFilter())) == null);
    try testing.expect((try lastFilteredChild(try fixture.ref(root), roleFilter())) == null);
}
