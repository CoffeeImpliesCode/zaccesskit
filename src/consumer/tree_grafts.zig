//! The graft, removal and graft-resolution pass of one tree update.
//!
//! **Invariant.** When `GraftScratch.resolve` returns without an error the graft
//! chain is whole: every graft parent the update installed names its subtree
//! root at index 0, and every node the pass removed is one that no node the
//! state still holds names.
//!
//! **What survives an update, and what does not.** The pass never writes
//! `NodeState.data`, so a node it keeps holds the property buffers it held
//! before and a `NodeRef` a caller built from it names the same node after. It
//! does write `NodeState.parent_and_index`, on the subtree roots it rehangs and
//! on nothing else, so a caller that cached a parent or an index across an
//! update is stale. It deletes whole subtrees, and it releases a deleted node's
//! buffers here rather than at the end of `Tree.processChanges`, so a caller
//! that needs a removed node's properties reads them from the committed state.
//! That is what upstream's `node_removed` callback does, at `tree.rs:582` and
//! `tree.rs:674-677`.
//!
//! **What an error leaves.** `error.OutOfMemory` preserves every logical
//! mapping, though a reserve may already have grown its backing arrays.
//! All fallible allocation precedes the first logical write. A transactional
//! caller runs this pass on its private working state. Every other error
//! reports an update upstream would have panicked on; that working state may
//! be partly written and must be discarded or restored before reuse.
//! `docs/33-consumer-interface-contract.md` section 5 says the same of
//! `error.NodeMissingFromState`.
//!
//! **`error.NodeMissingFromState` is one member of `UpdateError`**, declared in
//! `tree_state.zig` beside the other fifteen tags, so a single `catch` over
//! `UpdateError` names it and a caller never has to catch two declarations of
//! one error. It answers for both ways a removal walk can run out: a step count
//! that reached the bound below, and a node the state does not hold. Upstream's
//! `.unwrap()` at `tree.rs:367` covered only the second, and the first has no
//! upstream site because upstream had no bound.
//!
//! **`UpdateError` lives in `tree_state.zig`, not in `tree.zig`.** A reader who
//! finds section 5 of the contract naming `tree.zig` beside this file's import
//! has found a real contradiction in the contract. Section 3 forbids this file
//! from importing `tree.zig` and from importing `tree_validate.zig`, and
//! `validateGlobal` returns two members of the same set, so `tree.zig` could not
//! own it either. `tree_state.zig` is the lowest module that returns it.
//!
//! **The three walks and their two bounds.** `docs/33` section 7.1 gives this
//! file three rows, rows 2, 3 and 4, and those rows resolve to the two bound
//! functions this file declares.
//!
//! `removalStepBound` is the bound of both removal walks, `tree.rs:354-380` and
//! `tree.rs:395-419`. The first walk removes one entry from `nodes` at every
//! step, and the count is captured before the first removal because the map
//! shrinks while the walk runs. The second walk also pops nodes a previous walk
//! already took, so its steps are pushes rather than removals, and a node pushes
//! each of its children once. A tree that repeats a node is therefore the only
//! way that count is reached.
//!
//! `subtreeRemovalBound` is the bound of the subtree removal cursor at
//! `tree.rs:425-445`. It re-reads the queue length at every iteration, because
//! the queue grows under it: a subtree the walk deletes queues the subtree
//! nested inside it. Each id enters the queue once, because the set behind the
//! queue refuses an id it has already seen, so the length is finite and running
//! out is the ordinary exit. No tag reports it and none is needed.
//!
//! **What this module deliberately does not do.** Upstream ends `update` with
//! `self.focus = self.compute_effective_focus()` and `self.validate_global()` at
//! `tree.rs:483-485`. Neither runs here. Section 3 forbids this file from
//! importing `tree_validate.zig`, and `tree.zig` is the only module above both,
//! so `tree.zig` calls `tree_validate.computeEffectiveFocus` and
//! `tree_validate.validateGlobal` between this pass and the fold.
//!
//! Upstream: `accesskit_consumer/src/tree.rs:332-486`.

const std = @import("std");

const schema = @import("../schema/root.zig");
const tree_index = @import("tree_index.zig");
const tree_state = @import("tree_state.zig");

const FullNodeId = tree_index.FullNodeId;
const ParentAndIndex = tree_index.ParentAndIndex;
const TreeIndex = tree_index.TreeIndex;

const InternalChanges = tree_state.InternalChanges;
const NodeIdSet = tree_state.NodeIdSet;
const TreeIdNodeMap = tree_state.TreeIdNodeMap;
const TreeIdSet = tree_state.TreeIdSet;
const TreeState = tree_state.TreeState;
const UpdateError = tree_state.UpdateError;

const Node = schema.Node;
const NodeId = schema.NodeId;
const TreeId = schema.TreeId;
const tree_id_root = schema.tree_id_root;

const assert = std.debug.assert;
const testing = std.testing;

/// Bounds 2 and 3 of 9 in `docs/33` section 7, and the bound of both removal
/// walks this file owns. Upstream `tree.rs:354-380` and `tree.rs:395-419`.
///
/// The count is taken at the call site and not read from the map, because the
/// map shrinks while the walk runs and a bound that fell with it would let the
/// walk stop early on a tree it was still walking.
pub fn removalStepBound(node_count_at_entry: usize) usize {
    return node_count_at_entry;
}

/// Bound 4 of 9 in `docs/33` section 7: the subtree removal cursor's limit at
/// one iteration. Upstream `tree.rs:425-445`.
///
/// The length is re-read at every iteration rather than captured, because the
/// queue grows under the cursor. Exhaustion is the ordinary exit, so this bound
/// reports nothing.
pub fn subtreeRemovalBound(list_len_at_this_iteration: usize) usize {
    return list_len_at_this_iteration;
}

comptime {
    // Both derivations at zero and at the `max_nodes_per_update` size the rest of
    // the layer pins its walks against.
    assert(removalStepBound(0) == 0);
    assert(removalStepBound(65_536) == 65_536);
    assert(subtreeRemovalBound(0) == 0);
    assert(subtreeRemovalBound(65_536) == 65_536);
    // Both are the identity on their argument, so neither is a constant and a
    // walk sized by the tree grows with the tree.
    assert(removalStepBound(65_536) > removalStepBound(0));
    assert(subtreeRemovalBound(65_536) > subtreeRemovalBound(0));
}

/// What one update's graft pass needs from the per-node pass, and the maps the
/// two passes share.
///
/// The value owns four maps. `deinit` releases all four, once, and `self.gpa`
/// must be the allocator that grew them. A copy is a handle to the same four
/// maps and not a second owner, so a copy must not be deinitialised.
///
/// One value serves exactly one update, and `resolve` empties nothing: the
/// caller releases it after `applyUpdate` returns, success or failure.
pub const GraftScratch = struct {
    /// The allocator that grew the four maps and that `deinit` releases them
    /// through. It is also what `resolve` reserves its walk buffers with, so
    /// injecting a failing allocator here is what makes the failure paths of
    /// the pass reachable.
    gpa: std.mem.Allocator,

    /// The tree this update applies to. It is `tree_id_root` for the main tree.
    tree_id: TreeId,

    /// The root the update gave `tree_id`, or `null` when the update carried no
    /// tree data. A subtree whose root changed had its old root put in
    /// `unreachable`, and the removal walk skips a child equal to this value
    /// because the subtree is arriving rather than leaving.
    new_tree_root: ?FullNodeId,

    /// The focus node the update named, mapped into `tree_id`'s namespace.
    tree_focus: FullNodeId,

    /// Every child id the per-node pass saw. A node the removal walk reaches
    /// whose id is here was reparented by this update, so removing it would
    /// delete a node the update just placed.
    seen_child_ids: NodeIdSet = .empty,

    /// The nodes the per-node pass could not reach any more. The removal walk
    /// starts from each of them. The field is `unreachable_ids` because
    /// `unreachable` is a Zig keyword and cannot name a member.
    unreachable_ids: NodeIdSet = .empty,

    /// The graft parent each subtree id gets from this update. `resolve`
    /// installs these, and skips the removal of a subtree this update is
    /// re-grafting rather than removing it and installing it again.
    pending_grafts: TreeIdNodeMap = .empty,

    /// The subtree ids whose graft went away, either because a node dropped its
    /// `tree_id` or because the removal walk took the node that carried it.
    /// `resolve` deletes each of these subtrees in turn.
    grafts_to_remove: TreeIdSet = .empty,

    /// A scratch for one update of `tree_id`, with nothing recorded yet.
    pub fn init(gpa: std.mem.Allocator, tree_id: TreeId, tree_focus: FullNodeId) GraftScratch {
        return .{ .gpa = gpa, .tree_id = tree_id, .tree_focus = tree_focus, .new_tree_root = null };
    }

    /// Releases the four maps. The value is unusable afterwards and a second
    /// call is a double free. `self.gpa` is not released.
    pub fn deinit(self: *GraftScratch) void {
        self.seen_child_ids.deinit(self.gpa);
        self.unreachable_ids.deinit(self.gpa);
        self.pending_grafts.deinit(self.gpa);
        self.grafts_to_remove.deinit(self.gpa);
        // SAFETY: the four maps above were released, which is everything the
        // value owned, and no statement after them reads `self`.
        self.* = undefined;
    }

    /// Records that `graft_node_id` claims `subtree_id`, replacing nothing:
    /// `error.DuplicateGraftParent` when this update already claimed it, and
    /// `error.CannotGraftTheRootTree` when the id names the main tree, which
    /// upstream's root tree is not a subtree of and therefore cannot be the
    /// child of any graft.
    ///
    /// Upstream `record_graft` at `tree.rs:182-199`, with its two `panic!` sites
    /// at `tree.rs:188` and `tree.rs:191`.
    pub fn recordGraft(
        self: *GraftScratch,
        subtree_id: TreeId,
        graft_node_id: FullNodeId,
    ) UpdateError!void {
        if (subtree_id.eql(tree_id_root)) return error.CannotGraftTheRootTree;
        if (self.pending_grafts.contains(subtree_id)) return error.DuplicateGraftParent;
        try self.pending_grafts.put(self.gpa, subtree_id, graft_node_id);
    }

    /// Records that the graft carrying `subtree_id` went away, so `resolve`
    /// deletes that subtree. Recording the same id twice is one deletion, and
    /// costs nothing. Upstream `grafts_to_remove.insert` at `tree.rs:283`.
    pub fn retireGraft(self: *GraftScratch, subtree_id: TreeId) std.mem.Allocator.Error!void {
        try self.grafts_to_remove.put(self.gpa, subtree_id, {});
    }

    /// Whether `resolve` has to add an entry to `state.subtrees`, which is the
    /// one insertion in the pass that can grow a map it does not own. The
    /// reserve below needs the answer before the first write.
    fn addsSubtreeEntry(self: *const GraftScratch, state: *const TreeState) bool {
        if (self.new_tree_root != null) return true;
        if (state.subtrees.contains(self.tree_id)) return false;
        // Upstream `tree.rs:343-351` adds the main tree's own entry when the
        // update carried no tree data and nothing recorded it before.
        return self.tree_id.eql(tree_id_root);
    }

    /// Records this update's focus and installs every graft parent it claims.
    ///
    /// `state` is written in the order `tree.rs:332-351`, `:353-393`, `:395-445`
    /// and `:447-481` write it, and the pass reads the sets `applyUpdate` filled.
    /// `changes` is `null` when the caller reports nothing, which is what
    /// `Tree.init` does.
    ///
    /// `error.OutOfMemory` preserves logical state; capacity may have grown.
    /// Every fallible allocation precedes the first logical write.
    /// `error.NodeMissingFromState` reports a
    /// removal walk that ran out of steps or reached a node the state does not
    /// hold, and `error.DuplicateGraftParent` reports a graft parent the state
    /// already held. Both leave `state` partly written. Its owner must restore
    /// or discard it. Public `Tree` restores its dirty working state before the
    /// next update or host-focus call.
    pub fn resolve(
        self: *GraftScratch,
        state: *TreeState,
        changes: ?*InternalChanges,
    ) UpdateError!void {
        const step_bound = removalStepBound(state.nodes.count());
        const will_walk = self.unreachable_ids.count() != 0 or self.grafts_to_remove.count() != 0;
        const will_install = self.pending_grafts.count() != 0;

        // Reserves may grow backing arrays, but logical mappings are not
        // written until they all succeed. Every later insert uses
        // `putAssumeCapacity` or `appendAssumeCapacity` covered here.
        var walks: WalkBuffers = .{};
        defer walks.deinit(self.gpa);
        if (will_walk) {
            try walks.stack.ensureTotalCapacity(self.gpa, step_bound);
            try walks.queue.ensureTotalCapacity(
                self.gpa,
                self.grafts_to_remove.count() + step_bound,
            );
            // The removal walk adds one id per node it deletes, and the queue
            // takes the same ids, so both are bounded by the node count.
            try self.grafts_to_remove.ensureUnusedCapacity(self.gpa, step_bound);
        }
        if (self.addsSubtreeEntry(state)) try state.subtrees.ensureUnusedCapacity(self.gpa, 1);
        if (will_install) {
            try state.graft_parents.ensureUnusedCapacity(self.gpa, self.pending_grafts.count());
        }
        if (changes) |recorded| {
            if (will_walk) try recorded.removed_node_ids.ensureUnusedCapacity(self.gpa, step_bound);
            // A metadata-only update still attaches its existing subtree root,
            // even when no graft is being installed. Added roots need no slot.
            const rewrites_root = if (self.new_tree_root) |root|
                state.graft_parents.contains(self.tree_id) and !recorded.added_node_ids.contains(root)
            else
                false;
            const updated_bound = self.pending_grafts.count() + @as(usize, @intFromBool(rewrites_root));
            if (updated_bound != 0)
                try recorded.updated_node_ids.ensureUnusedCapacity(self.gpa, updated_bound);
        }

        recordTreeFocus(self, state);
        try removeUnreachable(self, state, &walks, step_bound, changes);
        try dropOrphanedSubtrees(self, state, &walks, step_bound, changes);
        try installGraftParents(self, state, changes);
    }
};

/// The two buffers the removal walks share. They are one value because
/// `resolve` has to reserve both before its first write, and a caller that
/// passed them in would have to reserve them in the right order to get the same
/// guarantee. The value owns its two arrays; `deinit` releases them.
const WalkBuffers = struct {
    /// The nodes one removal walk has yet to visit. Each entry is one step.
    stack: std.ArrayList(FullNodeId) = .empty,
    /// The subtree ids the cursor has yet to look at. It grows under the cursor.
    queue: std.ArrayList(TreeId) = .empty,

    fn deinit(self: *WalkBuffers, gpa: std.mem.Allocator) void {
        self.stack.deinit(gpa);
        self.queue.deinit(gpa);
        // SAFETY: the two arrays above were released, which is everything the
        // value owned, and no statement after them reads `self`.
        self.* = undefined;
    }
};

/// Records where focus sits in `tree_id` after this update. Upstream
/// `tree.rs:332-351`. Writes `state.subtrees` only, and the insert is the one
/// `resolve` reserved room for.
fn recordTreeFocus(self: *const GraftScratch, state: *TreeState) void {
    if (self.new_tree_root) |new_root| {
        state.subtrees.putAssumeCapacity(
            self.tree_id,
            .{ .root = new_root, .focus = self.tree_focus },
        );
    }
    if (state.subtrees.getPtr(self.tree_id)) |subtree| {
        subtree.focus = self.tree_focus;
        return;
    }
    if (self.tree_id.eql(tree_id_root)) {
        state.subtrees.putAssumeCapacity(
            self.tree_id,
            .{ .root = state.root_id, .focus = self.tree_focus },
        );
    }
}

/// Removes every node no remaining node reaches. Upstream `tree.rs:353-393` and
/// its nested `traverse_unreachable` at `tree.rs:354-380`.
///
/// The step counter spans every root in `unreachable`, not one counter per root,
/// because every step removes a node and the two walks together remove at most
/// the `step_bound` nodes the map held on entry. A node that is already gone is
/// `error.NodeMissingFromState`, which is what upstream's `.unwrap()` at
/// `tree.rs:367` was.
fn removeUnreachable(
    self: *GraftScratch,
    state: *TreeState,
    walks: *WalkBuffers,
    step_bound: usize,
    changes: ?*InternalChanges,
) UpdateError!void {
    var steps: usize = 0;
    var roots = self.unreachable_ids.iterator();
    while (roots.next()) |root| {
        walks.stack.clearRetainingCapacity();
        walks.stack.appendAssumeCapacity(root.key_ptr.*);
        while (steps < step_bound) : (steps += 1) {
            const id = walks.stack.pop() orelse break;
            var removed = state.nodes.fetchSwapRemove(id) orelse
                return error.NodeMissingFromState;
            if (changes) |recorded| recorded.removed_node_ids.putAssumeCapacity(id, {});
            if (schema.option.treeId(&removed.value.data.properties)) |subtree_id| {
                self.grafts_to_remove.putAssumeCapacity(subtree_id, {});
            }
            for (schema.ids_props.children(&removed.value.data.properties)) |child| {
                const child_id = id.withSameTree(child);
                // A child this update named somewhere is a node the update just
                // placed, and a child that is the arriving subtree root is
                // arriving rather than leaving.
                if (self.seen_child_ids.contains(child_id)) continue;
                if (self.new_tree_root) |new_root| {
                    if (child_id.local.eql(new_root.local) and
                        child_id.tree_index == new_root.tree_index)
                    {
                        continue;
                    }
                }
                walks.stack.appendAssumeCapacity(child_id);
            }
            removed.value.data.deinit();
        }
        // A node still on the stack here is one the bound ran out on. Upstream
        // had neither a bound nor a tag, so this report is the port's own.
        if (walks.stack.items.len != 0) return error.NodeMissingFromState;
    }
}

/// Removes every subtree whose graft went away, and every subtree nested inside
/// one of those. Upstream `tree.rs:395-445` and its nested `traverse_subtree` at
/// `tree.rs:395-419`.
///
/// The cursor re-reads the queue length every iteration, which is what lets a
/// subtree removed here queue a further one. A pop that finds nothing continues,
/// because an earlier walk may have taken the node, and that is upstream's
/// `else { continue }` at `tree.rs:404-406`.
fn dropOrphanedSubtrees(
    self: *GraftScratch,
    state: *TreeState,
    walks: *WalkBuffers,
    step_bound: usize,
    changes: ?*InternalChanges,
) UpdateError!void {
    for (self.grafts_to_remove.keys()) |subtree_id| {
        walks.queue.appendAssumeCapacity(subtree_id);
    }
    var cursor: usize = 0;
    while (cursor < subtreeRemovalBound(walks.queue.items.len)) : (cursor += 1) {
        const subtree_id = walks.queue.items[cursor];
        // A subtree with no graft parent was never grafted, so there is nothing
        // to undo, and a subtree this update is re-grafting is installed rather
        // than deleted.
        if (state.graft_parents.fetchSwapRemove(subtree_id) == null) continue;
        if (self.pending_grafts.contains(subtree_id)) continue;
        const subtree = state.subtrees.fetchSwapRemove(subtree_id) orelse continue;

        walks.stack.clearRetainingCapacity();
        walks.stack.appendAssumeCapacity(subtree.value.root);
        var steps: usize = 0;
        while (steps < step_bound) : (steps += 1) {
            const id = walks.stack.pop() orelse break;
            var removed = state.nodes.fetchSwapRemove(id) orelse continue;
            if (changes) |recorded| recorded.removed_node_ids.putAssumeCapacity(id, {});
            if (schema.option.treeId(&removed.value.data.properties)) |nested| {
                if (!self.grafts_to_remove.contains(nested)) {
                    self.grafts_to_remove.putAssumeCapacity(nested, {});
                    walks.queue.appendAssumeCapacity(nested);
                }
            }
            for (schema.ids_props.children(&removed.value.data.properties)) |child| {
                walks.stack.appendAssumeCapacity(id.withSameTree(child));
            }
            removed.value.data.deinit();
        }
        if (walks.stack.items.len != 0) return error.NodeMissingFromState;
    }
}

/// Installs the graft parents this update claims, hanging each subtree root
/// under its graft node at index 0. Upstream `tree.rs:447-481`.
///
/// `error.DuplicateGraftParent` when `state.graft_parents` already names a
/// parent for one of the subtree ids, which is upstream's `panic!` at
/// `tree.rs:449`. A root the state does not hold is left alone, because
/// upstream's `if let Some(root_state)` at `tree.rs:459` also leaves it alone,
/// and the subtree is not yet pushed.
fn installGraftParents(
    self: *const GraftScratch,
    state: *TreeState,
    changes: ?*InternalChanges,
) UpdateError!void {
    var grafts = self.pending_grafts.iterator();
    while (grafts.next()) |entry| {
        const subtree_id = entry.key_ptr.*;
        const graft_node_id = entry.value_ptr.*;
        if (state.graft_parents.contains(subtree_id)) return error.DuplicateGraftParent;
        state.graft_parents.putAssumeCapacity(subtree_id, graft_node_id);
        rehangSubtreeRoot(state, subtree_id, graft_node_id, changes);
    }
    // Upstream `tree.rs:470-481`. The subtree this update just pushed hangs under
    // the graft node that claims `tree_id` itself, which is a different entry
    // from the ones above unless this update is also re-grafting its parent.
    const new_root = self.new_tree_root orelse return;
    const graft_node_id = state.graft_parents.get(self.tree_id) orelse return;
    setRootParent(state, changes, new_root, graft_node_id);
}

/// Hangs the root of `subtree_id` under `graft_node_id` at index 0, if the
/// subtree is registered and the state holds its root. Upstream `tree.rs:457-467`.
fn rehangSubtreeRoot(
    state: *TreeState,
    subtree_id: TreeId,
    graft_node_id: FullNodeId,
    changes: ?*InternalChanges,
) void {
    const subtree = state.subtrees.get(subtree_id) orelse return;
    setRootParent(state, changes, subtree.root, graft_node_id);
}

/// Writes the graft parent of a subtree root and records the rewrite unless the
/// same update added the node. Upstream `tree.rs:461-465` and `tree.rs:474-478`.
///
/// The insert is a `putAssumeCapacity` because `resolve` reserved
/// `updated_node_ids` before its first write to `state`.
fn setRootParent(
    state: *TreeState,
    changes: ?*InternalChanges,
    root: FullNodeId,
    graft_node_id: FullNodeId,
) void {
    const root_state = state.nodes.getPtr(root) orelse return;
    root_state.parent_and_index = ParentAndIndex{ .parent_id = graft_node_id, .index = 0 };
    if (changes) |recorded| {
        if (!recorded.added_node_ids.contains(root)) {
            recorded.updated_node_ids.putAssumeCapacity(root, {});
        }
    }
}

// --- What upstream declares here and this file does not ------------------------
//
// `tree.rs:182-199` declares `record_graft` as a free `fn` taking its maps, and
// `tree.rs:201-227` declares `add_node` the same way. Zig declares a method
// inside the struct body it belongs to, so `record_graft` became
// `GraftScratch.recordGraft`: the set it writes is a field of the value that
// owns it, and the call reads `scratch.recordGraft(id, node)`. `add_node` is
// left to `tree_apply.zig`, which owns the per-node pass and the `nodes` map it
// writes.
//
// `tree.rs:318-321` and `tree.rs:325-328` print their message through
// `ShortNodeList` (`tree.rs:713-733`), which lists at most ten ids. This file
// deletes that text: the port answers `error.OrphanNode` and
// `error.OrphanChild` from `tree_apply.zig`, a Zig error carries no payload, and
// the layer has no diagnostic channel. The ids are still available to a caller
// that wants them, in the two pending maps `tree_apply.zig` deinits.
//
// The thirteen `panic!` sites this file covers lose their message text the same
// way. `:188` becomes `error.CannotGraftTheRootTree`, `:191` and `:449` become
// `error.DuplicateGraftParent`, and `:211` and `:273` become
// `error.GraftWithChildren`. `:367` becomes `error.NodeMissingFromState`.

// --- Tests ---------------------------------------------------------------------

/// Stores a node with one role and no properties, and returns its id. A test
/// only needs the node to exist and to be findable by local id.
fn putNode(
    gpa: std.mem.Allocator,
    state: *TreeState,
    local: u64,
    number: u32,
    role: schema.Role,
) std.mem.Allocator.Error!FullNodeId {
    const id = FullNodeId.init(.{ .value = local }, TreeIndex.init(number));
    try state.nodes.put(gpa, id, .{ .parent_and_index = null, .data = Node.init(gpa, role) });
    return id;
}

fn setChildren(state: *TreeState, id: FullNodeId, children: []const NodeId) !void {
    const entry = state.nodes.getPtr(id) orelse return error.NodeMissingFromState;
    try schema.ids_props.setChildren(&entry.data.properties, children);
}

fn setTreeIdOn(state: *TreeState, id: FullNodeId, subtree: TreeId) !void {
    const entry = state.nodes.getPtr(id) orelse return error.NodeMissingFromState;
    try schema.option.setTreeId(&entry.data.properties, subtree);
}

fn subtreeOne() TreeId {
    return schema.treeIdFromBytes(.{1} ** 16);
}

fn subtreeTwo() TreeId {
    return schema.treeIdFromBytes(.{2} ** 16);
}

/// Asserts that two states hold the same tree: the same nodes with the same
/// parents, roles and properties, and the same graft bookkeeping. This is what
/// makes "the tree survived" a claim about content and not about a node count.
fn expectSameTree(expected: *const TreeState, actual: *const TreeState) !void {
    try testing.expectEqual(expected.root_id, actual.root_id);
    try testing.expectEqual(expected.focus_id, actual.focus_id);
    try testing.expectEqual(expected.is_host_focused, actual.is_host_focused);
    try testing.expectEqual(expected.nodes.count(), actual.nodes.count());
    try testing.expectEqual(expected.subtrees.count(), actual.subtrees.count());
    try testing.expectEqual(expected.graft_parents.count(), actual.graft_parents.count());

    var nodes = expected.nodes.iterator();
    while (nodes.next()) |entry| {
        const found = actual.nodes.getPtr(entry.key_ptr.*) orelse
            return error.NodeMissingFromState;
        try testing.expectEqualDeep(entry.value_ptr.parent_and_index, found.parent_and_index);
        try testing.expect(entry.value_ptr.data.eql(&found.data));
    }

    var subtrees = expected.subtrees.iterator();
    while (subtrees.next()) |entry| {
        const found = actual.subtrees.get(entry.key_ptr.*) orelse
            return error.NodeMissingFromState;
        try testing.expectEqualDeep(entry.value_ptr.*, found);
    }

    var grafts = expected.graft_parents.iterator();
    while (grafts.next()) |entry| {
        const found = actual.graft_parents.get(entry.key_ptr.*) orelse
            return error.NodeMissingFromState;
        try testing.expectEqualDeep(entry.value_ptr.*, found);
    }
}

/// A state holding a graft node, the subtree it carries, that subtree's root
/// and one child of that root. `graft_parents` and `subtrees` agree with it.
fn graftedTree(gpa: std.mem.Allocator) !TreeState {
    var state: TreeState = .{};
    errdefer state.deinit(gpa);
    state.root_id = FullNodeId.init(.{ .value = 1 }, TreeIndex.init(0));
    state.focus_id = state.root_id;

    const graft = try putNode(gpa, &state, 1, 0, .generic_container);
    const root = try putNode(gpa, &state, 10, 1, .group);
    const child = try putNode(gpa, &state, 11, 1, .button);
    try setChildren(&state, graft, &.{.{ .value = 10 }});
    try setTreeIdOn(&state, graft, subtreeOne());
    try setChildren(&state, root, &.{.{ .value = 11 }});
    const root_slot = state.nodes.getPtr(root) orelse return error.NodeMissingFromState;
    const child_slot = state.nodes.getPtr(child) orelse return error.NodeMissingFromState;
    root_slot.parent_and_index = .{ .parent_id = graft, .index = 0 };
    child_slot.parent_and_index = .{ .parent_id = root, .index = 0 };

    try state.graft_parents.put(gpa, subtreeOne(), graft);
    try state.subtrees.put(gpa, subtreeOne(), .{ .root = root, .focus = root });
    return state;
}

test "a graft chain the pass installs hangs the subtree root under its graft node" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    const graft = try putNode(gpa, &state, 1, 0, .generic_container);
    const root = try putNode(gpa, &state, 10, 1, .group);
    try state.subtrees.put(gpa, subtreeOne(), .{ .root = root, .focus = root });

    var scratch = GraftScratch.init(gpa, subtreeOne(), root);
    defer scratch.deinit();
    try scratch.recordGraft(subtreeOne(), graft);
    var changes: InternalChanges = .{};
    defer changes.deinit(gpa);
    try scratch.resolve(&state, &changes);

    try testing.expectEqual(graft, state.graft_parents.get(subtreeOne()).?);
    const entry = state.nodes.get(root) orelse return error.NodeMissingFromState;
    const parent = entry.parent_and_index orelse return error.NoParent;
    try testing.expectEqual(graft, parent.parent_id);
    try testing.expectEqual(@as(usize, 0), parent.index);
    // The rewrite is reported as an update unless this same update added the
    // node, which matches the guard at `tree.rs:462` and `tree.rs:475`.
    try testing.expect(changes.updated_node_ids.contains(root));
}

test "a second graft parent for one subtree is refused and names the conflict" {
    const gpa = testing.allocator;
    var state = try graftedTree(gpa);
    defer state.deinit(gpa);
    const other = try putNode(gpa, &state, 2, 0, .generic_container);

    var scratch = GraftScratch.init(gpa, subtreeOne(), state.root_id);
    defer scratch.deinit();
    try scratch.recordGraft(subtreeOne(), other);
    var changes: InternalChanges = .{};
    defer changes.deinit(gpa);

    // `record_graft` refuses a second claim inside one update, which is
    // `tree.rs:191`.
    try testing.expectError(
        error.DuplicateGraftParent,
        scratch.recordGraft(subtreeOne(), other),
    );
    try testing.expectError(error.DuplicateGraftParent, scratch.resolve(&state, &changes));
}

test "the root tree cannot be the child of a graft" {
    const gpa = testing.allocator;
    var scratch = GraftScratch.init(gpa, tree_id_root, FullNodeId.init(.{ .value = 0 }, .init(0)));
    defer scratch.deinit();

    // `tree.rs:188` panics on exactly this id.
    try testing.expectError(
        error.CannotGraftTheRootTree,
        scratch.recordGraft(tree_id_root, FullNodeId.init(.{ .value = 1 }, .init(0))),
    );
    try testing.expectEqual(@as(usize, 0), scratch.pending_grafts.count());
}

test "a retired graft takes its whole subtree and leaves the graft node alone" {
    const gpa = testing.allocator;
    var state = try graftedTree(gpa);
    defer state.deinit(gpa);
    const graft = state.graft_parents.get(subtreeOne()) orelse return error.NoGraftParent;
    const subtree = state.subtrees.get(subtreeOne()) orelse return error.NoSuchSubtree;
    const root = subtree.root;
    const child = FullNodeId.init(.{ .value = 11 }, TreeIndex.init(1));

    var scratch = GraftScratch.init(gpa, tree_id_root, state.root_id);
    defer scratch.deinit();
    try scratch.retireGraft(subtreeOne());
    var changes: InternalChanges = .{};
    defer changes.deinit(gpa);
    try scratch.resolve(&state, &changes);

    // The subtree is gone from both directions of the graft record.
    try testing.expectEqual(@as(usize, 0), state.graft_parents.count());
    // One entry is left, and it is the main tree's own, which `recordTreeFocus`
    // adds because the update named no tree data and none was there before.
    try testing.expect(!state.nodes.contains(root));
    try testing.expect(!state.nodes.contains(child));
    try testing.expect(state.nodes.contains(graft));
    try testing.expect(changes.removed_node_ids.contains(root));
    try testing.expect(changes.removed_node_ids.contains(child));
}

test "the cursor re-reads the queue, so a nested subtree goes with its parent" {
    const gpa = testing.allocator;
    var state = try graftedTree(gpa);
    defer state.deinit(gpa);
    const outer = state.graft_parents.get(subtreeOne()) orelse return error.NoGraftParent;
    const subtree = state.subtrees.get(subtreeOne()) orelse return error.NoSuchSubtree;
    const subtree_root = subtree.root;
    // The second graft sits inside the first subtree, which is the only place a
    // removal walk can meet it: the walk visits one tree index at a time.
    const nested_graft = FullNodeId.init(.{ .value = 12 }, TreeIndex.init(1));
    _ = try putNode(gpa, &state, 12, 1, .generic_container);
    try setTreeIdOn(&state, nested_graft, subtreeTwo());
    try setChildren(&state, subtree_root, &.{ .{ .value = 11 }, .{ .value = 12 } });
    const inner_root = FullNodeId.init(.{ .value = 20 }, TreeIndex.init(2));
    _ = try putNode(gpa, &state, 20, 2, .group);
    try state.graft_parents.put(gpa, subtreeTwo(), nested_graft);
    try state.subtrees.put(gpa, subtreeTwo(), .{ .root = inner_root, .focus = inner_root });

    var scratch = GraftScratch.init(gpa, tree_id_root, state.root_id);
    defer scratch.deinit();
    try scratch.retireGraft(subtreeOne());
    var changes: InternalChanges = .{};
    defer changes.deinit(gpa);
    try scratch.resolve(&state, &changes);

    // The queue held one id when the cursor started. A cursor that compared its
    // index against that one length would stop here and leave subtree two
    // standing, because deleting subtree one queues subtree two.
    try testing.expect(!state.nodes.contains(inner_root));
    try testing.expect(!state.nodes.contains(nested_graft));
    try testing.expect(!state.graft_parents.contains(subtreeTwo()));
    try testing.expect(!state.subtrees.contains(subtreeTwo()));
    try testing.expect(state.nodes.contains(outer));
}

test "a removal walk of exactly the bound finishes and removes both nodes" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    state.root_id = FullNodeId.init(.{ .value = 1 }, TreeIndex.init(0));
    state.focus_id = state.root_id;
    const parent = try putNode(gpa, &state, 1, 0, .group);
    const child = try putNode(gpa, &state, 2, 0, .button);
    try setChildren(&state, parent, &.{.{ .value = 2 }});

    var scratch = GraftScratch.init(gpa, tree_id_root, state.root_id);
    defer scratch.deinit();
    try scratch.unreachable_ids.put(gpa, parent, {});
    try scratch.resolve(&state, null);

    // Two nodes, two steps, and the bound is two. A bound one lower would have
    // reported an error on a tree it had finished.
    try testing.expectEqual(@as(usize, 0), state.nodes.count());
    try testing.expect(!state.nodes.contains(child));
}

test "a removal walk that repeats a node reports the bound it reached" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    state.root_id = FullNodeId.init(.{ .value = 1 }, TreeIndex.init(0));
    state.focus_id = state.root_id;
    const first = try putNode(gpa, &state, 1, 0, .group);
    const second = try putNode(gpa, &state, 2, 0, .button);
    // Two nodes that name each other. Nothing in the update protocol builds
    // this, which is the point: the walk meets user data and needs an argument
    // for stopping rather than an accident of the input.
    try setChildren(&state, first, &.{.{ .value = 2 }});
    try setChildren(&state, second, &.{.{ .value = 1 }});

    var scratch = GraftScratch.init(gpa, tree_id_root, state.root_id);
    defer scratch.deinit();
    try scratch.unreachable_ids.put(gpa, first, {});

    // Without `removalStepBound` the stack grows without end: each pop pushes
    // the node that names the node just popped, forever.
    try testing.expectError(error.NodeMissingFromState, scratch.resolve(&state, null));
}

test "a graft that runs out of memory leaves the tree exactly as it was" {
    const gpa = testing.allocator;
    var before = try graftedTree(gpa);
    defer before.deinit(gpa);

    // A graft does two things at once: it deletes a retired subtree and it
    // installs a graft parent, so a failure in any step of either has to leave
    // the whole tree alone.
    const retired_subtree = before.subtrees.get(subtreeOne()) orelse return error.NoSuchSubtree;
    const retired_root = retired_subtree.root;
    const arriving_graft = FullNodeId.init(.{ .value = 30 }, TreeIndex.init(0));
    const arriving_root = FullNodeId.init(.{ .value = 31 }, TreeIndex.init(1));
    _ = try putNode(gpa, &before, 30, 0, .generic_container);
    _ = try putNode(gpa, &before, 31, 1, .group);
    try before.subtrees.put(gpa, subtreeTwo(), .{ .root = arriving_root, .focus = arriving_root });
    // A node no remaining node names, so the removal walk has real work to do
    // and not only the subtree cursor.
    const stranded = FullNodeId.init(.{ .value = 40 }, TreeIndex.init(0));
    _ = try putNode(gpa, &before, 40, 0, .label);

    var scratch = GraftScratch.init(gpa, tree_id_root, before.root_id);
    defer scratch.deinit();
    try scratch.retireGraft(subtreeOne());
    try scratch.recordGraft(subtreeTwo(), arriving_graft);
    try scratch.unreachable_ids.put(gpa, stranded, {});
    const retired_count = scratch.grafts_to_remove.count();

    // One allocator below `testing.allocator` fails the Nth allocation and
    // forwards every free, so the leak check stays live across the whole loop.
    // A fresh wrapper each turn is what makes the index absolute: the wrapper
    // counts from zero, so raising only `alloc_index` on a shared one would let
    // the counter run past the trip-wire and succeed on the first turn.
    var failures: usize = 0;

    while (failures < 32) : (failures += 1) {
        var trial: TreeState = .{};
        defer trial.deinit(gpa);
        try trial.cloneInto(gpa, &before);

        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = failures });
        scratch.gpa = failing.allocator();
        if (scratch.resolve(&trial, null)) |_| {
            // The first index the pass never reaches. Every earlier one failed,
            // so every allocation the pass makes was covered by a case above.
            // A pass that allocated nothing would land here on the first turn
            // and prove nothing, so the count has to be above zero.
            try testing.expect(failures > 0);
            try testing.expect(!trial.nodes.contains(retired_root));
            try testing.expect(!trial.nodes.contains(stranded));
            try testing.expectEqual(
                FullNodeId.init(.{ .value = 30 }, TreeIndex.init(0)),
                trial.graft_parents.get(subtreeTwo()).?,
            );
            scratch.gpa = gpa;
            return;
        } else |err| {
            scratch.gpa = gpa;
            try testing.expectEqual(error.OutOfMemory, err);
            // The tree is the one the pass was handed, and the scratch's own
            // sets are as the caller left them, because nothing after the
            // reserve can run.
            try expectSameTree(&before, &trial);
            try testing.expectEqual(retired_count, scratch.grafts_to_remove.count());
        }
    }
    return error.TooManyAllocations;
}
