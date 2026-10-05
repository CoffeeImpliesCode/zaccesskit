//! The per-node pass of one tree update.
//!
//! **Invariant.** When `applyUpdate` returns without an error, every node the
//! update names sits in `state.nodes` with its parent, its index and its data
//! settled, and no id is named by two children lists.
//!
//! **What survives an update, and what does not.** A node the state already
//! holds keeps its entry and its property buffers: an update writes the new data
//! into the old store with `Node.cloneInto`, which keeps every buffer whose
//! shape matches, so a node's identity and its memory both survive. A node the
//! update adds is deep-copied out of the update rather than moved out of it,
//! because `TreeUpdate.deinit` releases every entry it holds and a state sharing
//! those buffers with the update would free them twice. The price is one property
//! copy per added node, which upstream does not pay because upstream moves.
//!
//! What does not survive is `NodeState.parent_and_index`, which is rewritten
//! whenever a node moves, and a node the graft pass removes, which is gone from
//! `state.nodes` before `applyUpdate` returns. A `NodeRef` a caller took before
//! an update is therefore stale after it whatever the node did, which
//! `node_id.zig` states at the borrow.
//!
//! **What an error leaves.** The pass writes `state` as it walks, exactly as
//! upstream does, and does not roll back. On any `UpdateError` the state is
//! half applied: a node the pass added is in the map, a node it rewrote carries
//! the new data, and the two pending maps are discarded with the scratch. The
//! caller's protection is the shape `Tree` gives it. `applyUpdate` runs on
//! `Tree.next_state`, a scratch copy, and `Tree.process_changes` folds it into
//! `Tree.state` only after the whole update returns without an error, so the tree
//! an application reads is exactly the tree it read before. Two rejections are
//! decided before the first write at all, `error.SubtreeWithoutGraft` and
//! `error.SubtreeDoesNotExist`, so those two leave even the scratch untouched.
//!
//! **The graft pass is the last thing this file does.** `docs/33` section 3
//! forbids this file from importing `tree.zig` and from importing
//! `tree_validate.zig`, and the two calls upstream ends `update` with at
//! `tree.rs:483` and `tree.rs:485` therefore live in `tree.zig`, which is the only
//! module above every pass. They run after this pass and after the graft pass,
//! because a validator called before the last mutation proves nothing.
//!
//! **Argument order.** `applyUpdate` and `addNode` are free functions that
//! allocate, so they take `gpa` first per `AGENTS.md:99`. `state` is a parameter
//! and not a receiver, because Zig declares a method only inside the struct body
//! it belongs to and `tree_state.zig` owns `TreeState`.
//!
//! **The upstream range this file covers.** `docs/33` section 1.1 gives it
//! `tree.rs:124-260`, and the split falls inside the per-node loop. This file
//! keeps the whole loop, `:229-315`, and the two orphan checks at `:317-330`,
//! because both are the loop's own termination and neither is a graft concern.
//! `tree_grafts.zig` therefore begins at `tree.rs:332`. Every line of both
//! recorded ranges has a counterpart in one of the two files, and neither file
//! carries an item the other owns.
//!
//! Upstream: `accesskit_consumer/src/tree.rs:124-330`.

const std = @import("std");

const schema = @import("../schema/root.zig");
const tree_grafts = @import("tree_grafts.zig");
const tree_index = @import("tree_index.zig");
const tree_state = @import("tree_state.zig");

const FullNodeId = tree_index.FullNodeId;
const ParentAndIndex = tree_index.ParentAndIndex;
const TreeIndex = tree_index.TreeIndex;

const InternalChanges = tree_state.InternalChanges;
const TreeState = tree_state.TreeState;
const UpdateError = tree_state.UpdateError;

const GraftScratch = tree_grafts.GraftScratch;
const Node = schema.Node;
const NodeId = schema.NodeId;
const TreeId = schema.TreeId;
const TreeUpdate = schema.TreeUpdate;
const tree_id_root = schema.tree_id_root;

const testing = std.testing;

/// The nodes an update named that neither the state nor a children list reached.
/// Each value is a header over the update's own node, so the map is not a second
/// owner and `addNode` deep-copies what it takes out.
const PendingNodes = std.array_hash_map.Auto(FullNodeId, Node);
/// The child ids an update named that no node in the update, and no children
/// list already in the state, accounts for yet.
const PendingChildren = std.array_hash_map.Auto(FullNodeId, ParentAndIndex);

/// Applies one update to `state` and, when `changes` is not `null`, records what
/// it changed in it.
///
/// `update` is transferred in and released on every path, including the failing
/// ones, through `TreeUpdate.deinit` and through nothing else. The caller's
/// binding is spent and must not be released again.
///
/// `gpa` is the allocator every map this pass builds and every buffer the state
/// gains is grown with, and it must be the allocator `update` was built with.
///
/// Two rejections leave `state` untouched: `error.SubtreeWithoutGraft` and
/// `error.SubtreeDoesNotExist`. Every other tag leaves the pass half applied and
/// the state unsatisfying I1 to I4, so the caller drops the state. The module doc
/// says which shape makes that safe, and a test in this file pins it.
///
/// Nothing here recomputes the effective focus or validates the tree. `tree.zig`
/// does both after this pass and the graft pass, which is the one place in the
/// layer where that order is load bearing.
pub fn applyUpdate(
    gpa: std.mem.Allocator,
    state: *TreeState,
    update: TreeUpdate,
    changes: ?*InternalChanges,
) UpdateError!void {
    // Zig binds a parameter immutably and `TreeUpdate.deinit` takes the address of
    // a mutable value, so the handle the caller transfers is rebound to a local
    // the callee can release. Both names below are one value.
    var released = update;
    defer released.deinit(gpa);

    const tree_number = try state.tree_index_map.getOrCreateIndex(gpa, update.tree_id);
    const tree_focus = FullNodeId.init(update.focus, tree_number);

    var scratch = GraftScratch.init(gpa, update.tree_id, tree_focus);
    defer scratch.deinit();

    // Upstream `tree.rs:131-148`. Both conditions are checked before anything is
    // written, so both leave the state as the caller passed it.
    if (!update.tree_id.eql(tree_id_root)) {
        if (update.tree != null and !state.graft_parents.contains(update.tree_id))
            return error.SubtreeWithoutGraft;
        if (!state.subtrees.contains(update.tree_id) and update.tree == null)
            return error.SubtreeDoesNotExist;
    }

    // Upstream `tree.rs:150-166`. The root of the tree moves here, and the root
    // it replaces joins `unreachable` for the graft pass to remove.
    if (update.tree) |tree| {
        const new_root = mapId(tree.root, tree_number);
        if (retiredRoot(state, update.tree_id, new_root, tree.root)) |retired| {
            try scratch.unreachable_ids.put(gpa, retired, {});
        }
        if (update.tree_id.eql(tree_id_root)) {
            state.root_id = new_root;
            state.info = tree;
        }
        scratch.new_tree_root = new_root;
    }

    // Upstream `tree.rs:168-175`. A node with this local id is the root of the
    // tree this update names, whichever of the three sources the name came from.
    const root_local: NodeId = if (scratch.new_tree_root) |new_root|
        new_root.local
    else if (state.subtrees.get(update.tree_id)) |subtree|
        subtree.root.local
    else
        state.info.root;

    var pending_nodes: PendingNodes = .empty;
    defer pending_nodes.deinit(gpa);
    var pending_children: PendingChildren = .empty;
    defer pending_children.deinit(gpa);

    for (update.nodes.items) |*entry| {
        const node_id = mapId(entry.node_id, tree_number);
        _ = scratch.unreachable_ids.fetchOrderedRemove(node_id);

        for (schema.ids_props.children(&entry.node.properties), 0..) |child_id, child_index| {
            const mapped_child_id = mapId(child_id, tree_number);
            if (scratch.seen_child_ids.contains(mapped_child_id)) return error.DuplicateChild;
            try scratch.seen_child_ids.put(gpa, mapped_child_id, {});
            _ = scratch.unreachable_ids.fetchOrderedRemove(mapped_child_id);
            const parent_and_index: ParentAndIndex = .{
                .parent_id = node_id,
                .index = child_index,
            };
            if (state.nodes.getPtr(mapped_child_id)) |child_state| {
                if (!isSameParent(child_state.parent_and_index, parent_and_index)) {
                    child_state.parent_and_index = parent_and_index;
                    if (changes) |recorded| {
                        try recorded.updated_node_ids.put(gpa, mapped_child_id, {});
                    }
                }
            } else if (pending_nodes.fetchSwapRemove(mapped_child_id)) |found| {
                // The child's own data arrived before the parent that names it.
                try addNode(
                    gpa,
                    state,
                    &scratch,
                    changes,
                    parent_and_index,
                    mapped_child_id,
                    &found.value,
                );
            } else {
                try pending_children.put(gpa, mapped_child_id, parent_and_index);
            }
        }

        if (state.nodes.getPtr(node_id)) |node_state| {
            if (entry.node_id.eql(root_local)) node_state.parent_and_index = null;
            for (schema.ids_props.children(&node_state.data.properties)) |child_id| {
                const mapped = mapId(child_id, tree_number);
                if (scratch.seen_child_ids.contains(mapped)) continue;
                try scratch.unreachable_ids.put(gpa, mapped, {});
            }
            if (!node_state.data.eql(&entry.node)) {
                const claimed = schema.option.treeId(&entry.node.properties);
                // Upstream `tree.rs:271-278`. A graft node takes its only child
                // from the subtree it carries, never from its own list.
                if (claimed != null and schema.ids_props.children(&entry.node.properties).len != 0)
                    return error.GraftWithChildren;
                const retired = schema.option.treeId(&node_state.data.properties);
                if (!isSameTreeId(retired, claimed)) {
                    if (retired) |subtree_id| try scratch.retireGraft(subtree_id);
                    if (claimed) |subtree_id| try scratch.recordGraft(subtree_id, node_id);
                }
                // The reuse line. The store keeps every buffer whose shape
                // matches, so an updated node keeps the memory it already had.
                try entry.node.cloneInto(&node_state.data);
                if (changes) |recorded| try recorded.updated_node_ids.put(gpa, node_id, {});
            }
        } else if (pending_children.fetchSwapRemove(node_id)) |held| {
            try addNode(gpa, state, &scratch, changes, held.value, node_id, &entry.node);
        } else if (entry.node_id.eql(root_local)) {
            try addNode(gpa, state, &scratch, changes, null, node_id, &entry.node);
        } else {
            try pending_nodes.put(gpa, node_id, entry.node);
        }
    }

    // Upstream `tree.rs:317-330`. Both maps empty means every node the update
    // named is either already in the state or was a children list entry of a node
    // that is, which is what the invariant claims.
    if (pending_nodes.count() != 0) return error.OrphanNode;
    if (pending_children.count() != 0) return error.OrphanChild;

    try scratch.resolve(state, changes);
}

/// The node whose root this update replaces, or `null` when nothing is retired.
/// Upstream `tree.rs:150-166`.
///
/// `new_root_local` is `tree.root` and is compared against `state.info.root`
/// rather than against `new_root`, because the two differ only by tree index and
/// the update's own root is the one the platform sent.
fn retiredRoot(
    state: *const TreeState,
    tree_id: TreeId,
    new_root: FullNodeId,
    new_root_local: NodeId,
) ?FullNodeId {
    if (tree_id.eql(tree_id_root)) {
        if (new_root_local.eql(state.info.root)) return null;
        return state.root_id;
    }
    const subtree = state.subtrees.get(tree_id) orelse return null;
    if (sameNode(subtree.root, new_root)) return null;
    return subtree.root;
}

/// Inserts `id` under `parent_and_index`, claiming a graft first when `data`
/// names a subtree. Upstream `add_node` at `tree.rs:201-227`.
///
/// `data` is one of the update's nodes by reference and is deep-copied, because
/// `TreeUpdate.deinit` releases every node it holds. An entry already under `id`
/// is released before the put, which is what upstream's `insert` does when it
/// returns and drops the value it displaced.
///
/// `error.GraftWithChildren` when `data` names a subtree and also names children
/// of its own, which is upstream's `panic!` at `tree.rs:211`. This file's other
/// `tree.rs:273` site is the rewrite path, which checks the same condition.
fn addNode(
    gpa: std.mem.Allocator,
    state: *TreeState,
    scratch: *GraftScratch,
    changes: ?*InternalChanges,
    parent_and_index: ?ParentAndIndex,
    id: FullNodeId,
    data: *const Node,
) UpdateError!void {
    if (schema.option.treeId(&data.properties)) |subtree_id| {
        if (schema.ids_props.children(&data.properties).len != 0) return error.GraftWithChildren;
        try scratch.recordGraft(subtree_id, id);
    }
    var owned = try Node.clone(gpa, data);
    errdefer owned.deinit();
    if (state.nodes.getPtr(id)) |overwritten| overwritten.data.deinit();
    try state.nodes.put(gpa, id, .{ .parent_and_index = parent_and_index, .data = owned });
    if (changes) |recorded| try recorded.added_node_ids.put(gpa, id, {});
}

/// The node named by a local id inside one tree. Upstream's `map_id` closure at
/// `tree.rs:126`; this layer forbids a closure, so the tree number is a
/// parameter. Upstream calls the value `tree_index`, which this file cannot use
/// for it because `tree_index` names the module the type comes from.
fn mapId(local_id: NodeId, tree_number: TreeIndex) FullNodeId {
    return FullNodeId.init(local_id, tree_number);
}

/// Whether `found` is the same parent and the same index as `wanted`, which is
/// the comparison at `tree.rs:241`. A node that has no parent is never the same
/// as one that has.
fn isSameParent(found: ?ParentAndIndex, wanted: ParentAndIndex) bool {
    const held = found orelse return false;
    return sameNode(held.parent_id, wanted.parent_id) and held.index == wanted.index;
}

/// Whether two names are the same node. Zig has no `==` for a struct, and
/// `tree_index.zig` declares no equality on `FullNodeId`, so the two halves are
/// compared here rather than by a second spelling of equality added to the
/// module that owns the type.
fn sameNode(found: FullNodeId, wanted: FullNodeId) bool {
    return found.local.eql(wanted.local) and found.tree_index == wanted.tree_index;
}

/// Whether two optional tree ids name the same subtree, which is the comparison
/// at `tree.rs:281`. An absent id is the same only as another absent id.
fn isSameTreeId(found: ?TreeId, wanted: ?TreeId) bool {
    const held = found orelse return wanted == null;
    const other = wanted orelse return false;
    return held.eql(other);
}

// --- What upstream declares here and this file does not ------------------------
//
// `tree.rs:126` declares `map_id` as a closure over `tree_index`. Rule C2 in
// `docs/33` section 3 bans a closure, so `mapId` is a free function and each call
// names the tree number. The call reads `mapId(entry.node_id, tree_number)`
// instead of `map_id(entry.node_id)`, which is the price of the rule.
//
// `tree.rs:318-321` and `tree.rs:325-328` report an orphan through `ShortNodeList`
// (`tree.rs:713-733`), which prints at most ten local ids. This file drops that
// text: the port answers `error.OrphanNode` and `error.OrphanChild`, a Zig error
// carries no payload, and this layer has no diagnostic channel. The ids are still
// reachable, in the two pending maps, for a caller that wants to report them.
//
// The `panic!` sites `:135`, `:142`, `:188`, `:191`, `:211`, `:236`, `:273`,
// `:318` and `:325` become the tags of `UpdateError` named at each line above.
// Upstream's message text is dropped with `ShortNodeList`, for the same reason.
//
// `tree.rs:183-199` (`record_graft`) and `tree.rs:353-481` (the removal and graft
// resolution) belong to `tree_grafts.zig`, which owns the graft chain, and this
// file calls one function of each rather than copying them.
//
// `tree.rs:229-315` iterates a `HashMap<NodeId, Node>`, whose order `hashbrown`
// reseeds per process. The port iterates `TreeUpdate.nodes`, an array, so the
// order is a function of the update. The pass has no order requirement: a node
// arrives before or after the node naming it and both orders place every node.

// --- What each test below pins -------------------------------------------------
//
// Each line names the branch the test reaches and what would make it fail. A test
// whose fixture cannot reach its branch is worse than no test, so the fixture is
// named in the same line.
//
//   * every node the update names lands        the `pending_nodes` drain at
//     `tree.rs:247`, reached because node 1 names node 2. Fails if the parent or
//     the index is not written, or if a node the update names is left pending.
//   * a node neither the state nor a list reaches    `error.OrphanNode`, reached
//     because node 9 is named by nobody. Fails if the pass accepts it.
//   * a child id that no node names             `error.OrphanChild`, reached
//     because node 2 is reached and its child 7 is not named back. Fails if the
//     orphan check runs in the wrong order or not at all.
//   * one child id named by two parents         `error.DuplicateChild`. Fails if
//     the seen set is not consulted.
//   * a graft node that names children          `error.GraftWithChildren` in
//     `addNode`, reached because node 6 is reached as a child of node 1. Fails if
//     the check moves to the graft pass, where the node is already inserted.
//   * a subtree with no graft node              `error.SubtreeWithoutGraft`, the
//     first decision the pass makes. Fails if the precondition runs after a write.
//   * an existing node is rewritten in place    the reuse line at `tree.rs:289`.
//     Fails if the node is reported as added, or if its parent moved.
//   * an orphan stops the graft pass            the order of `tree.rs:317-330` and
//     the graft pass. Fails if a graft reaches `graft_parents` before the check.
//   * an error leaves the pass half applied      the failure contract in the
//     module doc. Fails if the pass starts rolling back.
//   * a graft node arrives before its subtree   both graft directions across two
//     updates. Fails if the subtree root does not hang at index 0.

// --- Tests ---------------------------------------------------------------------

/// Adds a node with one role and no other property.
fn pushNode(gpa: std.mem.Allocator, update: *TreeUpdate, local: u64, role: schema.Role) !void {
    try update.pushNode(gpa, .{ .value = local }, Node.init(gpa, role));
}

/// Adds a node whose `children` list names `children`.
fn pushParent(
    gpa: std.mem.Allocator,
    update: *TreeUpdate,
    local: u64,
    role: schema.Role,
    children: []const NodeId,
) !void {
    var node = Node.init(gpa, role);
    errdefer node.deinit();
    try schema.ids_props.setChildren(&node.properties, children);
    try update.pushNode(gpa, .{ .value = local }, node);
}

/// Adds a node whose `tree_id` property names `subtree`.
fn pushGraft(
    gpa: std.mem.Allocator,
    update: *TreeUpdate,
    local: u64,
    subtree: TreeId,
    children: []const NodeId,
) !void {
    var node = Node.init(gpa, .generic_container);
    errdefer node.deinit();
    try schema.option.setTreeId(&node.properties, subtree);
    try schema.ids_props.setChildren(&node.properties, children);
    try update.pushNode(gpa, .{ .value = local }, node);
}

/// A state holding one root node and nothing else, which is the smallest state
/// the pass can be driven against.
///
/// `info` carries the root's local id and the index map has registered the root
/// tree, because `applyUpdate` reads the root from `state.info.root` when the
/// update carries no tree data, and `Tree.init` is what makes both true.
fn rootOnly(gpa: std.mem.Allocator, root_local: u64) !TreeState {
    var state: TreeState = .{};
    errdefer state.deinit(gpa);
    state.info = schema.TreeInfo.init(.{ .value = root_local });
    state.root_id = FullNodeId.init(.{ .value = root_local }, TreeIndex.init(0));
    state.focus_id = state.root_id;
    _ = try state.tree_index_map.getOrCreateIndex(gpa, tree_id_root);
    try state.nodes.put(gpa, state.root_id, .{
        .parent_and_index = null,
        .data = Node.init(gpa, .generic_container),
    });
    return state;
}

/// Stores a node in `state` directly, with the parent the pass would give it and
/// no children of its own.
fn putChildOf(
    gpa: std.mem.Allocator,
    state: *TreeState,
    local: u64,
    role: schema.Role,
    parent_local: u64,
    index: usize,
) !void {
    const id = FullNodeId.init(.{ .value = local }, TreeIndex.init(0));
    try state.nodes.put(gpa, id, .{
        .parent_and_index = .{
            .parent_id = FullNodeId.init(.{ .value = parent_local }, TreeIndex.init(0)),
            .index = index,
        },
        .data = Node.init(gpa, role),
    });
}

test "every node the update names lands with its parent and its index" {
    const gpa = testing.allocator;
    var state = try rootOnly(gpa, 1);
    defer state.deinit(gpa);

    var update: TreeUpdate = .{};
    try pushParent(gpa, &update, 1, .generic_container, &.{.{ .value = 2 }});
    try pushParent(gpa, &update, 2, .group, &.{ .{ .value = 3 }, .{ .value = 4 } });
    try pushNode(gpa, &update, 3, .button);
    try pushNode(gpa, &update, 4, .label);
    var changes: InternalChanges = .{};
    defer changes.deinit(gpa);
    try applyUpdate(gpa, &state, update, &changes);

    // Nodes 3 and 4 arrive before node 2 names them, so the pass places them from
    // `pending_nodes` and the children loop then writes the parent and the index.
    for ([_]u64{ 3, 4 }, 0..) |local, index| {
        const id = FullNodeId.init(.{ .value = local }, TreeIndex.init(0));
        const parent = state.nodes.get(id).?.parent_and_index.?;
        const group = FullNodeId.init(.{ .value = 2 }, TreeIndex.init(0));
        try testing.expectEqual(group, parent.parent_id);
        try testing.expectEqual(index, parent.index);
    }
    try testing.expectEqual(@as(usize, 4), state.nodes.count());
    try testing.expectEqual(@as(usize, 3), changes.added_node_ids.count());
    try testing.expectEqual(@as(usize, 0), changes.removed_node_ids.count());
}

test "a node neither the state nor a children list reaches is refused" {
    const gpa = testing.allocator;
    var state = try rootOnly(gpa, 1);
    defer state.deinit(gpa);

    var update: TreeUpdate = .{};
    try pushNode(gpa, &update, 1, .generic_container);
    // Node 9 names nothing and nothing names it, so it can only stay pending.
    try pushNode(gpa, &update, 9, .button);
    try testing.expectError(error.OrphanNode, applyUpdate(gpa, &state, update, null));

    try testing.expect(!state.nodes.contains(FullNodeId.init(.{ .value = 9 }, .init(0))));
}

test "a child id that no node in the update names is refused" {
    const gpa = testing.allocator;
    var state = try rootOnly(gpa, 1);
    defer state.deinit(gpa);

    var update: TreeUpdate = .{};
    try pushParent(gpa, &update, 1, .generic_container, &.{.{ .value = 2 }});
    try pushParent(gpa, &update, 2, .group, &.{.{ .value = 7 }});
    try testing.expectError(error.OrphanChild, applyUpdate(gpa, &state, update, null));
}

test "one child id named by two parents is refused" {
    const gpa = testing.allocator;
    var state = try rootOnly(gpa, 1);
    defer state.deinit(gpa);

    var update: TreeUpdate = .{};
    try pushParent(gpa, &update, 1, .generic_container, &.{.{ .value = 2 }});
    try pushParent(gpa, &update, 2, .group, &.{.{ .value = 3 }});
    try pushParent(gpa, &update, 4, .group, &.{.{ .value = 3 }});
    try pushNode(gpa, &update, 3, .button);
    // The invariant's third clause. Upstream's `panic!` at `tree.rs:236`.
    try testing.expectError(error.DuplicateChild, applyUpdate(gpa, &state, update, null));
}

test "a graft node that also names children of its own is refused" {
    const gpa = testing.allocator;
    var state = try rootOnly(gpa, 1);
    defer state.deinit(gpa);
    const subtree = schema.treeIdFromBytes(.{5} ** 16);

    var update: TreeUpdate = .{};
    try pushParent(gpa, &update, 1, .generic_container, &.{.{ .value = 6 }});
    try pushGraft(gpa, &update, 6, subtree, &.{.{ .value = 2 }});
    try pushNode(gpa, &update, 2, .button);
    // Upstream's `panic!` at `tree.rs:211`.
    try testing.expectError(error.GraftWithChildren, applyUpdate(gpa, &state, update, null));
}

test "a subtree update with no graft node in the parent tree is refused before any write" {
    const gpa = testing.allocator;
    var state = try rootOnly(gpa, 1);
    defer state.deinit(gpa);

    var update: TreeUpdate = .{};
    update.tree_id = schema.treeIdFromBytes(.{5} ** 16);
    update.tree = schema.TreeInfo.init(.{ .value = 50 });
    try pushNode(gpa, &update, 50, .generic_container);
    // The rejection is the first thing the pass decides, so the state is exactly
    // what it was: upstream's `panic!` at `tree.rs:135`.
    try testing.expectError(error.SubtreeWithoutGraft, applyUpdate(gpa, &state, update, null));
    try testing.expectEqual(@as(usize, 1), state.nodes.count());
}

test "an existing node is rewritten in place and reported as an update, not an addition" {
    const gpa = testing.allocator;
    var state = try rootOnly(gpa, 1);
    defer state.deinit(gpa);
    try putChildOf(gpa, &state, 2, .group, 1, 0);

    var update: TreeUpdate = .{};
    try pushParent(gpa, &update, 1, .generic_container, &.{.{ .value = 2 }});
    try pushNode(gpa, &update, 2, .list);
    var changes: InternalChanges = .{};
    defer changes.deinit(gpa);
    try applyUpdate(gpa, &state, update, &changes);

    const id = FullNodeId.init(.{ .value = 2 }, TreeIndex.init(0));
    try testing.expectEqual(schema.Role.list, state.nodes.get(id).?.data.role);
    // The entry was reused, so the rewrite is an update. A port that removed the
    // node and added it again would report it in both sets and would release the
    // buffers this rewrite kept.
    try testing.expect(changes.updated_node_ids.contains(id));
    try testing.expect(!changes.added_node_ids.contains(id));
    try testing.expectEqual(@as(usize, 2), state.nodes.count());
    const parent = state.nodes.get(id).?.parent_and_index.?;
    try testing.expectEqual(FullNodeId.init(.{ .value = 1 }, TreeIndex.init(0)), parent.parent_id);
}

test "an orphan stops the pass before the graft it also declared is installed" {
    const gpa = testing.allocator;
    var state = try rootOnly(gpa, 1);
    defer state.deinit(gpa);

    var update: TreeUpdate = .{};
    try pushParent(gpa, &update, 1, .generic_container, &.{.{ .value = 6 }});
    try pushGraft(gpa, &update, 6, schema.treeIdFromBytes(.{5} ** 16), &.{});
    try pushNode(gpa, &update, 9, .button);
    try testing.expectError(error.OrphanNode, applyUpdate(gpa, &state, update, null));

    // The orphan check runs before the graft pass, so nothing the update claimed
    // reached the state. A graft pass that ran first would have installed it.
    try testing.expectEqual(@as(usize, 0), state.graft_parents.count());
}

test "an error leaves the pass half applied, which is what the scratch state is for" {
    const gpa = testing.allocator;
    var state = try rootOnly(gpa, 1);
    defer state.deinit(gpa);

    var update: TreeUpdate = .{};
    try pushParent(gpa, &update, 1, .generic_container, &.{.{ .value = 2 }});
    // This node is placed while the pass walks. The rejection comes afterwards.
    try pushParent(gpa, &update, 2, .group, &.{.{ .value = 3 }});
    try pushNode(gpa, &update, 3, .button);
    try pushNode(gpa, &update, 9, .label);
    try testing.expectError(error.OrphanNode, applyUpdate(gpa, &state, update, null));

    // This is the documented behaviour, not a defect: the pass writes as it
    // walks and does not roll back, so a caller that applies an update to the
    // state an application reads would see a half-applied tree. `Tree` never
    // does that, because it passes `next_state` and folds it in only on success.
    const placed = FullNodeId.init(.{ .value = 3 }, TreeIndex.init(0));
    try testing.expect(state.nodes.contains(placed));
    try testing.expect(!state.nodes.contains(FullNodeId.init(.{ .value = 9 }, .init(0))));
}

test "a graft node arrives first and the subtree that follows hangs under it" {
    const gpa = testing.allocator;
    var state = try rootOnly(gpa, 1);
    defer state.deinit(gpa);
    const subtree = schema.treeIdFromBytes(.{5} ** 16);
    const graft_id = FullNodeId.init(.{ .value = 6 }, TreeIndex.init(0));

    // The subtree arrives first and the parent tree carries nothing for it, which
    // is upstream's `panic!` at `tree.rs:135`.
    var early: TreeUpdate = .{};
    early.tree_id = subtree;
    early.tree = schema.TreeInfo.init(.{ .value = 50 });
    try pushNode(gpa, &early, 50, .generic_container);
    try testing.expectError(error.SubtreeWithoutGraft, applyUpdate(gpa, &state, early, null));

    // The graft node arrives with no children of its own, the only form `addNode`
    // accepts for a node that carries a subtree.
    var update: TreeUpdate = .{};
    try pushParent(gpa, &update, 1, .generic_container, &.{.{ .value = 6 }});
    try pushGraft(gpa, &update, 6, subtree, &.{});
    var changes: InternalChanges = .{};
    defer changes.deinit(gpa);
    try applyUpdate(gpa, &state, update, &changes);
    try testing.expectEqual(graft_id, state.graft_parents.get(subtree).?);

    // The subtree follows, and its root hangs under the graft node at index 0,
    // which is the invariant `tree_grafts.zig` states.
    var late: TreeUpdate = .{};
    late.tree_id = subtree;
    late.tree = schema.TreeInfo.init(.{ .value = 50 });
    try pushNode(gpa, &late, 50, .generic_container);
    try applyUpdate(gpa, &state, late, &changes);

    const subtree_root = FullNodeId.init(.{ .value = 50 }, TreeIndex.init(1));
    const parent = state.nodes.get(subtree_root).?.parent_and_index.?;
    try testing.expectEqual(graft_id, parent.parent_id);
    try testing.expectEqual(@as(usize, 0), parent.index);
}
