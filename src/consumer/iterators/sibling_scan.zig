//! The two filtered walks every filtered cursor in `iterators/` steps with.
//!
//! Upstream: `accesskit_consumer/src/iterators.rs:255-294` for
//! `next_filtered_sibling` and `:296-335` for `previous_filtered_sibling`.
//!
//! **What a scan is.** A scan answers one question: starting from a node,
//! which is the next node in the depth-first order that `filter` includes? It
//! returns that node, or `null` when the order holds no more of them. It is a
//! step, not a cursor: a cursor holds the scan between two calls, and this
//! module holds no state at all.
//!
//! **The iterator representation is stated once, in `iterators/children.zig`.**
//! That file owns `ChildIdsIterator`, which is the cursor these two walks step
//! over, and it carries the contract every cursor in the directory shares: no
//! cursor writes to the tree, so an abandoned iteration leaves nothing behind,
//! and a cursor's borrow of a `children` slice and of a `TreeState` ends at
//! the next call that can grow `TreeState.nodes`. Read that file for the rule.
//!
//! **The bound, and why one number serves both scans.** `docs/33` section 7
//! names `treeWalkStepBound(node_count)` for these two loops at
//! `iterators.rs:261` and `:302`, and the closing list in that section
//! confirms one bound rather than two. I read both walks and they are mirror
//! images, so the same argument bounds them and they take the same value.
//! The derivation:
//!
//! Each iteration moves to a node the walk has not yet visited as a candidate,
//! or ascends to a parent and then leaves that parent's whole subtree to the
//! right. A forward scan descends into the first child of a node the filter
//! excludes with `exclude_node`, advances to the next following sibling, and
//! on reaching the end of a level ascends to the parent to continue the level
//! above. Once a scan has ascended past a node it never returns to that node's
//! subtree, because the next move is to the right at the higher level. A node
//! is therefore a candidate at most once and an ascent target at most once,
//! and the step count cannot exceed the number of nodes the state holds. A
//! state that repeats a node in a parent chain, which invariant I1 rules out,
//! asks for a `node_count + 1`th step, and the count catches the repeat.
//!
//! That argument is `treeWalkStepBound`, and the tag is `error.TreeCycle`. The
//! test `a parent cycle reaches the scan bound and reports TreeCycle` builds
//! that cycle and asks for one step past the bound. Its positive half breaks
//! the cycle and asks again, so a bound that fires early fails too.
//!
//! **What this module does not do.** It allocates nothing, so no function here
//! takes an allocator. It takes no `io`, reads no clock and holds no global.
//! It does not call `node_ref/hierarchy.zig`, which is at L5: a scan reads
//! `NodeState.parent_and_index` and the `children` property directly, the
//! pattern `docs/33` section 1.3 blesses for a module below the parent query.

const std = @import("std");

const schema = @import("../../schema/root.zig");
const tree_index = @import("../tree_index.zig");
const tree_state = @import("../tree_state.zig");
const node_id = @import("../node_id.zig");
const filter_mod = @import("../filter.zig");
const children_mod = @import("children.zig");
const following_mod = @import("following.zig");
const preceding_mod = @import("preceding.zig");

const FullNodeId = tree_index.FullNodeId;
const NodeRef = node_id.NodeRef;
const TreeState = tree_state.TreeState;
const FilterFn = filter_mod.FilterFn;
const FilterResult = filter_mod.FilterResult;
const QueryError = tree_state.QueryError;
const treeWalkStepBound = tree_state.treeWalkStepBound;

const testing = std.testing;

// --- The two scans ------------------------------------------------------------

/// The first node after `node`, in depth-first pre-order, that `filter`
/// includes, or `null` when there is none. Upstream
/// `next_filtered_sibling`, `iterators.rs:255-294`.
///
/// A node the filter returns `exclude_node` for is opened and the scan
/// continues inside it, which is why a walk crosses a subtree boundary. A node
/// it returns `exclude_subtree` for is skipped with everything below it.
/// `null` means the order is exhausted, not that the filter rejected
/// everything.
///
/// Returns `error.TreeCycle` past `treeWalkStepBound(nodes.count())` steps and
/// `error.NoSuchNode` when the state holds no entry for an id a `children`
/// list names. Neither leaves anything to release.
pub fn nextFilteredSibling(node: ?NodeRef, filter: FilterFn) QueryError!?NodeRef {
    const start = node orelse return null;
    const bound = treeWalkStepBound(start.tree_state.nodes.count());
    var steps: usize = 0;
    var current = start;
    var consider_children = false;
    // The bound is the loop test rather than a check inside an open loop, so
    // the loop ends by exhausting its count and reporting the tag.
    while (steps < bound) : (steps += 1) {
        if (consider_children) {
            var kids = childrenOf(current);
            if (kids.next()) |child| {
                const result = try filter.call(child);
                current = child;
                if (result == .include) return child;
                consider_children = result == .exclude_node;
                continue;
            }
        }
        var siblings = followingSiblingIdsOf(current);
        if (siblings.next()) |sibling| {
            const sibling_node = NodeRef.init(current.tree_state, sibling) orelse
                return error.NoSuchNode;
            const result = try filter.call(sibling_node);
            current = sibling_node;
            if (result == .include) return sibling_node;
            // Upstream sets this only on `exclude_node`, so an
            // `exclude_subtree` result leaves the previous value standing.
            if (result == .exclude_node) consider_children = true;
            continue;
        }
        const parent = parentOf(current) orelse return null;
        current = parent;
        if (try filter.call(parent) != .exclude_node) return null;
        consider_children = false;
    }
    return error.TreeCycle;
}

/// The last node before `node`, in depth-first pre-order, that `filter`
/// includes, or `null` when there is none. Upstream
/// `previous_filtered_sibling`, `iterators.rs:296-335`.
///
/// The mirror of `nextFilteredSibling`, so it takes the same bound and returns
/// the same tags. It reads the children of each level back to front.
pub fn previousFilteredSibling(node: ?NodeRef, filter: FilterFn) QueryError!?NodeRef {
    const start = node orelse return null;
    const bound = treeWalkStepBound(start.tree_state.nodes.count());
    var steps: usize = 0;
    var current = start;
    var consider_children = false;
    while (steps < bound) : (steps += 1) {
        if (consider_children) {
            var kids = childrenOf(current);
            if (kids.nextBack()) |child| {
                const result = try filter.call(child);
                current = child;
                if (result == .include) return child;
                consider_children = result == .exclude_node;
                continue;
            }
        }
        var siblings = precedingSiblingIdsOf(current);
        if (siblings.next()) |sibling| {
            const sibling_node = NodeRef.init(current.tree_state, sibling) orelse
                return error.NoSuchNode;
            const result = try filter.call(sibling_node);
            current = sibling_node;
            if (result == .include) return sibling_node;
            if (result == .exclude_node) consider_children = true;
            continue;
        }
        const parent = parentOf(current) orelse return null;
        current = parent;
        if (try filter.call(parent) != .exclude_node) return null;
        consider_children = false;
    }
    return error.TreeCycle;
}

// --- The private steps --------------------------------------------------------

/// The children of `node` as nodes. Upstream `current.children()` at
/// `iterators.rs:262` and `:303`.
///
/// The graft decision is made here because `isGraft` and `graftChildId` are in
/// `node_ref/properties.zig` and `node_ref/hierarchy.zig`, both at L5.
fn childrenOf(node: NodeRef) children_mod.ChildrenIterator {
    const is_graft = schema.option.treeId(&node.data().properties) != null;
    return children_mod.children(
        children_mod.child_ids(node, is_graft, graftChildOf(node)),
        node.tree_state,
    );
}

/// The following sibling ids of `node`. Upstream
/// `current.following_siblings()` at `iterators.rs:270`, reached through
/// `FollowingSiblings::new` at `iterators.rs:88-114`.
fn followingSiblingIdsOf(node: NodeRef) following_mod.FollowingSiblingIdsIterator {
    return following_mod.following_sibling_ids(parentOf(node), node.id());
}

/// The preceding sibling ids of `node`. Upstream
/// `current.preceding_siblings()` at `iterators.rs:311`, reached through
/// `PrecedingSiblings::new` at `iterators.rs:179-201`.
fn precedingSiblingIdsOf(node: NodeRef) preceding_mod.PrecedingSiblingIdsIterator {
    return preceding_mod.preceding_sibling_ids(parentOf(node), node.id());
}

/// The parent of `node`, or `null` at the top of the tree. Reads
/// `NodeState.parent_and_index` directly, because `node_ref/hierarchy.zig` is
/// at L5 and this module is below it.
fn parentOf(node: NodeRef) ?NodeRef {
    const slot = node.state.parent_and_index orelse return null;
    return NodeRef.init(node.tree_state, slot.parent_id);
}

/// The one child of a graft node, which is the root of its subtree. Upstream
/// `node.rs:161-166`.
fn graftChildOf(node: NodeRef) ?FullNodeId {
    const tree_id = schema.option.treeId(&node.data().properties) orelse return null;
    return node.tree_state.subtreeRoot(tree_id);
}

// --- What upstream declares here and this file does not -----------------------

// `iterators.rs:255` and `:296` are private to the Rust module. The three
// filtered cursors call them, so they are file-scope functions here. They are
// `pub` only because `iterators/children.zig`, `following.zig` and
// `preceding.zig` are three files where Rust had one, and a declaration one
// file cannot reach is not a declaration.

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
        const list = try self.gpa.alloc(schema.NodeId, locals.len);
        defer self.gpa.free(list);
        for (locals, list) |local, *slot| slot.* = .{ .value = local };
        try schema.ids_props.setChildren(&self.state.nodes.getPtr(id).?.data.properties, list);
    }

    fn ref(self: *Fixture, id: FullNodeId) !NodeRef {
        return NodeRef.init(&self.state, id) orelse error.NodeMissingFromState;
    }
};

/// Includes every node, so the walk is the only thing that can end it.
fn includeAll(_: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    _ = node;
    return .include;
}

/// Excludes a `group` by opening it and a `button` by closing it, so one
/// filter exercises both branches of the walk.
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

/// Walks forward from `node` and collects every local id it answers.
///
/// The loop is bounded by `treeWalkStepBound(nodes.count())`: each step reaches
/// a node the walk has not reached, so a walk over `node_count` nodes ends
/// there, and a step past that reports the tag rather than running on. `limit`
/// stops earlier, and a test uses it to check one step short of the bound.
fn forwardFrom(
    gpa: std.mem.Allocator,
    node: NodeRef,
    filter: FilterFn,
    limit: ?usize,
) !std.ArrayList(u64) {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(gpa);
    var current: ?NodeRef = node;
    const bound = treeWalkStepBound(node.tree_state.nodes.count());
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        if (limit) |cap| if (taken >= cap) break;
        const found = try nextFilteredSibling(current, filter) orelse break;
        try out.append(gpa, found.id().local.value);
        current = found;
    }
    return out;
}

/// Walks backward from `node` and collects every local id it answers. The bound
/// is the one `forwardFrom` derives, because the two walks are mirror images.
fn backwardFrom(
    gpa: std.mem.Allocator,
    node: NodeRef,
    filter: FilterFn,
    limit: ?usize,
) !std.ArrayList(u64) {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(gpa);
    var current: ?NodeRef = node;
    const bound = treeWalkStepBound(node.tree_state.nodes.count());
    var taken: usize = 0;
    while (taken < bound) : (taken += 1) {
        if (limit) |cap| if (taken >= cap) break;
        const found = try previousFilteredSibling(current, filter) orelse break;
        try out.append(gpa, found.id().local.value);
        current = found;
    }
    return out;
}

test "a scan on a lone node and on no node answers null" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const only = try fixture.add(0, null, 0, .button);
    const only_node = try fixture.ref(only);

    // Nothing follows a lone node and nothing precedes it, so both scans
    // answer null on the smallest tree there is.
    try testing.expect((try nextFilteredSibling(only_node, includeAllFilter())) == null);
    try testing.expect((try previousFilteredSibling(only_node, includeAllFilter())) == null);
    try testing.expect((try nextFilteredSibling(null, includeAllFilter())) == null);
    try testing.expect((try previousFilteredSibling(null, includeAllFilter())) == null);
}

test "a forward scan visits every later node and enters an opened one" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    // The root is a `paragraph` so the filter includes it, and the scan starts
    // at node 0 rather than at the root, because a scan from the root has no
    // parent to climb to and so answers `null` at once.
    const root = try fixture.add(0, null, 0, .paragraph);
    const start = try fixture.add(1, root, 0, .paragraph);
    const opened = try fixture.add(2, root, 1, .group);
    _ = try fixture.add(3, opened, 0, .paragraph);
    const closed = try fixture.add(4, root, 2, .button);
    const last = try fixture.add(5, root, 3, .paragraph);
    try fixture.setChildren(root, &.{ 1, 2, 4, 5 });
    try fixture.setChildren(opened, &.{3});
    try fixture.setChildren(closed, &.{});

    // The scan arrives at node 2 as a sibling, so `exclude_node` on it opens the
    // node and node 3 enters the answer although it is nobody's sibling. Node 2
    // itself is not in the answer: `exclude_node` means the node is dropped and
    // only what is under it is kept. Node 4 is skipped whole because it is a
    // `button`.
    var walked = try forwardFrom(gpa, try fixture.ref(start), roleFilter(), null);
    defer walked.deinit(gpa);
    try testing.expectEqualSlices(u64, &.{ 3, 5 }, walked.items);

    // A scan that starts at the excluded node never opens it, because the scan
    // descends into a node only on arriving at it as a sibling or a child.
    // Upstream starts its `consider_children` flag at `false` at
    // `iterators.rs:260`, and this is where that shows.
    var from_opened = try forwardFrom(gpa, try fixture.ref(opened), roleFilter(), null);
    defer from_opened.deinit(gpa);
    try testing.expectEqualSlices(u64, &.{5}, from_opened.items);

    // A filter that includes everything reaches node 2, node 3's parent, and
    // then stops at node 2 rather than descending into it. Upstream returns a
    // node as soon as the filter includes it, at `iterators.rs:266`, so it
    // never sets `consider_children` for that node. Node 3 is in the answer
    // above only because the role filter dropped node 2 and opened it.
    var inclusive = try forwardFrom(gpa, try fixture.ref(start), includeAllFilter(), null);
    defer inclusive.deinit(gpa);
    try testing.expectEqualSlices(u64, &.{ 2, 4, 5 }, inclusive.items);

    // The last sibling ends the order, and the root has no parent to ascend to,
    // so both answer null.
    const after_last = try nextFilteredSibling(try fixture.ref(last), includeAllFilter());
    try testing.expect(after_last == null);
    const after_root = try nextFilteredSibling(try fixture.ref(root), includeAllFilter());
    try testing.expect(after_root == null);
}

test "a backward scan visits every earlier node and enters an opened one" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    // The root is a `paragraph` so the filter includes it, and the scan starts
    // at node 5, the last child. A scan from the root answers `null` at once,
    // because the root has no preceding sibling and no parent to climb to.
    const root = try fixture.add(0, null, 0, .paragraph);
    const start = try fixture.add(1, root, 0, .paragraph);
    const opened = try fixture.add(2, root, 1, .group);
    _ = try fixture.add(3, opened, 0, .paragraph);
    const closed = try fixture.add(4, root, 2, .button);
    const last = try fixture.add(5, root, 3, .paragraph);
    try fixture.setChildren(root, &.{ 1, 2, 4, 5 });
    try fixture.setChildren(opened, &.{3});
    try fixture.setChildren(closed, &.{});

    // The scan arrives at node 2 as a sibling, so `exclude_node` on it opens the
    // node and node 3 enters the answer although it is nobody's sibling. Node 2
    // itself is not in the answer, because `exclude_node` drops the node and
    // keeps only what is under it. Reading the level back to front is what puts
    // node 4, which is a `button` and is skipped whole, ahead of node 1.
    var out = try backwardFrom(gpa, try fixture.ref(last), roleFilter(), null);
    defer out.deinit(gpa);
    try testing.expectEqualSlices(u64, &.{ 3, 1 }, out.items);

    // A scan that starts at the excluded node never opens it, because the scan
    // descends into a node only on arriving at it as a sibling or a child.
    // Upstream starts its `consider_children` flag at `false` at
    // `iterators.rs:301`, and this is where that shows.
    var from_opened = try backwardFrom(gpa, try fixture.ref(opened), roleFilter(), null);
    defer from_opened.deinit(gpa);
    try testing.expectEqualSlices(u64, &.{1}, from_opened.items);

    // A filter that includes everything drops node 2's own subtree from the
    // answer, because upstream returns a node as soon as the filter includes it
    // at `iterators.rs:307` and so never sets `consider_children` for it. Node
    // 3 is in the answer above only because the role filter dropped node 2 and
    // opened it.
    var inclusive = try backwardFrom(gpa, try fixture.ref(last), includeAllFilter(), null);
    defer inclusive.deinit(gpa);
    try testing.expectEqualSlices(u64, &.{ 4, 2, 1 }, inclusive.items);

    const before_first = try previousFilteredSibling(try fixture.ref(start), includeAllFilter());
    try testing.expect(before_first == null);
    const before_root = try previousFilteredSibling(try fixture.ref(root), includeAllFilter());
    try testing.expect(before_root == null);
}

test "a filter that excludes everything answers null and reports no error" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root = try fixture.add(0, null, 0, .group);
    const first = try fixture.add(1, root, 0, .paragraph);
    _ = try fixture.add(2, root, 1, .paragraph);
    try fixture.setChildren(root, &.{ 1, 2 });

    // Excluding everything is a choice by the filter and not a cycle, so the
    // answer is null rather than `error.TreeCycle`. The walk starts at node 1,
    // because a walk from the root has no sibling and no parent to reach.
    const no_forward = try nextFilteredSibling(try fixture.ref(first), excludeEveryFilter());
    try testing.expect(no_forward == null);
    const no_backward = try previousFilteredSibling(try fixture.ref(first), excludeEveryFilter());
    try testing.expect(no_backward == null);

    // One scan short of an exhaustive answer still answers, so a bound that
    // fired early would fail the next line.
    var one = try forwardFrom(gpa, try fixture.ref(first), includeAllFilter(), 1);
    defer one.deinit(gpa);
    try testing.expectEqualSlices(u64, &.{2}, one.items);
}

test "a child cycle reaches the scan bound and reports TreeCycle" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    // Node 1 lists node 2 and node 2 lists node 1, so the two `children` lists
    // point at each other. That is what invariant I2 rules out.
    const root = try fixture.add(0, null, 0, .paragraph);
    const first = try fixture.add(1, root, 0, .group);
    const second = try fixture.add(2, root, 1, .group);
    try fixture.setChildren(root, &.{ 1, 2 });
    try fixture.setChildren(first, &.{2});
    try fixture.setChildren(second, &.{1});

    // `exclude_node` on both nodes keeps the scan descending, so it steps
    // first, second, first, second for ever. Nothing but the bound ends the
    // walk, which is what this test proves: without `treeWalkStepBound` the
    // call would not return at all.
    try testing.expectError(
        error.TreeCycle,
        nextFilteredSibling(try fixture.ref(first), roleFilter()),
    );
    try testing.expectError(
        error.TreeCycle,
        previousFilteredSibling(try fixture.ref(second), roleFilter()),
    );

    // The positive half, one step short of the bound: break the cycle at node
    // 2 and the forward walk answers. The role filter reports nothing, because
    // both nodes are `group` and `exclude_node` drops the node and keeps only
    // what is under it, and node 1 has nothing under it once node 2 is empty.
    try fixture.setChildren(second, &.{});
    var forward = try forwardFrom(gpa, try fixture.ref(first), roleFilter(), null);
    defer forward.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), forward.items.len);

    // The filter that includes everything does reach node 2, so the emptiness
    // above is the filter and not a walk that stopped early.
    var inclusive = try forwardFrom(gpa, try fixture.ref(first), includeAllFilter(), null);
    defer inclusive.deinit(gpa);
    try testing.expectEqualSlices(u64, &.{2}, inclusive.items);
}
