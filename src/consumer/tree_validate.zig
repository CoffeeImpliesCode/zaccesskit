//! The global invariant checks over one `TreeState`.
//!
//! Upstream holds two operations at `accesskit_consumer/src/tree.rs:86-123`.
//! `validate_global` asserts that the root and the focus are keys of `nodes`.
//! `compute_effective_focus` follows the graft chain from the root subtree until
//! it reaches a node that names no tree. Both are free functions here, taking
//! the state first. `TreeState` is declared in `tree_state.zig`, and only the
//! file that declares a struct body may carry methods on it.
//!
//! **The run-time half.** Both membership checks read the contents of a hash map
//! that the update algorithm grew at run time, so neither can be a `comptime`
//! assertion. The map is keyed on `FullNodeId` and both fields carry that type,
//! so each check is one lookup and no conversion can fail. That shape is the
//! whole of what the compiler knows about them.
//!
//! **The compile-time half.** Two facts hold for every value of every shape, and
//! the `comptime` block below pins them. Both membership fields are
//! non-optional `FullNodeId` values. A default `TreeState` names one id twice
//! while its default `nodes` map holds nothing, so a default value is the
//! shortest failing fixture for both checks. The third fact, that the graft
//! chain is one step longer than the subtree count, is pinned in
//! `tree_state.zig` beside `graftChainStepBound`, which that file declares
//! because `tree_apply.zig` and `tree.zig` need it and neither may import this
//! one. A reader who cannot tell the halves apart trusts the wrong ones and
//! skips the two that decide whether a tree is usable.
//!
//! **The failure is an error, never a panic.** Upstream panics at tree.rs:88,
//! :91 and :112 and follows the graft chain with no bound at tree.rs:101-120.
//! Rule C8 bans `unreachable`, so each panic becomes a tag of `UpdateError` and
//! the unbounded walk becomes `error.GraftChainTooLong`. Invariants I1 and I2 of
//! `docs/33-consumer-interface-contract.md` section 2 make
//! `error.RootNotInTree` unreachable after a successful update, because `update`
//! inserts every node an update names and writes `root` from `tree.root`.
//! Invariant I4 does the same for `error.FocusNotInTree`. The update path
//! returns `error.SubtreeDoesNotExist` when a subtree is updated before its tree
//! data, so a graft node never exists without the subtree it names and
//! `error.GraftWithoutSubtree` is unreachable too. The port returns the error
//! anyway. An invariant is a property the type system does not check, and a
//! caller that cannot see the check must still be able to handle its failure.
//!
//! This module owns neither `TreeState` nor `UpdateError` nor the graft-chain
//! bound. `tree_state.zig` declares all three, `tree_apply.zig` and
//! `tree_grafts.zig` write the state, and `tree.zig` calls the checks after every
//! mutation, because a validator that runs before the last write proves nothing.
//! Nothing here allocates, so no function takes an allocator, and nothing here
//! blocks, so none takes `io`.

const std = @import("std");

const schema = @import("../schema/root.zig");
const tree_index = @import("tree_index.zig");
const tree_state = @import("tree_state.zig");

const FullNodeId = tree_index.FullNodeId;
const TreeState = tree_state.TreeState;
const UpdateError = tree_state.UpdateError;
const graftChainStepBound = tree_state.graftChainStepBound;

const testing = std.testing;

comptime {
    // Both membership fields are non-optional `FullNodeId` values, so each check
    // is one lookup against the map's key type and neither field needs an
    // unwrap. A field that became optional or a bare `NodeId` stops the checks
    // compiling, and this records why the check is written as it is.
    std.debug.assert(@FieldType(TreeState, "root_id") == FullNodeId);
    std.debug.assert(@FieldType(TreeState, "focus_id") == FullNodeId);

    // Nothing in the type system fills `nodes`, so a default `TreeState` names
    // an id that no key holds. This is why a default value is the shortest
    // fixture for `error.RootNotInTree` and `error.FocusNotInTree`.
    const fresh: TreeState = .{};
    std.debug.assert(fresh.root_id.local.value == fresh.focus_id.local.value);
    std.debug.assert(fresh.root_id.tree_index.value() == fresh.focus_id.tree_index.value());
}

/// Checks the two global invariants of `docs/33-consumer-interface-contract.md`
/// section 2 that upstream checks here.
///
/// Reads only, allocates nothing and leaves `state` as it was on every path.
/// Returns `error.RootNotInTree` when `state.rootId()` is not a key of
/// `state.nodes`, and `error.FocusNotInTree` when `state.focusIdInTree()` is not.
/// Those two are the only tags of `UpdateError` this function can reach. The
/// root is checked first, so a state that violates both reports the root.
///
/// Upstream panics at tree.rs:88 and :91.
pub fn validateGlobal(state: *const TreeState) UpdateError!void {
    if (!state.hasNode(state.rootId())) return error.RootNotInTree;
    if (!state.hasNode(state.focusIdInTree())) return error.FocusNotInTree;
}

/// The focus an application sees: the root subtree's focus followed through every
/// graft node until it reaches a node that names no tree.
///
/// Returns `state.focusIdInTree()` when `state.subtrees` registers no root
/// tree, which is the state before any graft arrives. The walk also ends on a
/// focus that names no `NodeState`, and returns that id: only `validateGlobal`
/// reports a missing node, so a caller that needs both runs this and then that.
///
/// Returns `error.GraftWithoutSubtree` when a node on the chain names a tree
/// with no `SubtreeState`, and `error.GraftChainTooLong` when the chain takes
/// more than `graftChainStepBound` steps. Those two are the only tags of
/// `UpdateError` beyond `validateGlobal`'s that this function can reach, and
/// `state` is unchanged on both paths.
///
/// Upstream panics at tree.rs:112 and loops without a bound at tree.rs:101-120.
pub fn computeEffectiveFocus(state: *const TreeState) UpdateError!FullNodeId {
    const root_subtree = state.subtrees.get(schema.tree_id_root) orelse
        return state.focusIdInTree();

    var current_focus = root_subtree.focus;
    var step: usize = 0;
    const step_bound = graftChainStepBound(state.subtrees.count());
    while (step < step_bound) : (step += 1) {
        const node_state = state.nodes.get(current_focus) orelse break;
        const subtree_id = schema.option.treeId(&node_state.data.properties) orelse break;
        const subtree = state.subtrees.get(subtree_id) orelse return error.GraftWithoutSubtree;
        current_focus = subtree.focus;
    } else return error.GraftChainTooLong;

    return current_focus;
}

/// The id for `local_content` inside the tree `TreeIndex.init(0)` names first.
fn nodeId(local_content: u64) FullNodeId {
    return FullNodeId.init(schema.nodeIdFromContent(local_content), tree_index.TreeIndex.init(0));
}

/// A tree id whose sixteen bytes are zero except the last, so a test can name
/// two trees without writing a literal that differs in one byte.
fn treeIdFromLastByte(last_byte: u8) schema.TreeId {
    var bytes: [16]u8 = @splat(0);
    bytes[15] = last_byte;
    return schema.treeIdFromBytes(bytes);
}

/// Inserts a node with no parent and no properties. `role` only has to name a
/// member, because nothing here reads it.
fn addNode(state: *TreeState, id: FullNodeId, role: schema.Role) !void {
    var node = schema.Node.init(testing.allocator, role);
    errdefer node.deinit();
    try state.nodes.put(testing.allocator, id, .{
        .parent_and_index = null,
        .data = node,
    });
}

/// Inserts a graft node, which is a node whose only property is the tree it
/// names. Upstream reads that property at tree.rs:108 to decide whether to
/// follow the graft chain through it.
fn addGraftNode(state: *TreeState, id: FullNodeId, tree_id: schema.TreeId) !void {
    var node = schema.Node.init(testing.allocator, .generic_container);
    errdefer node.deinit();
    try schema.option.setTreeId(&node.properties, tree_id);
    try state.nodes.put(testing.allocator, id, .{
        .parent_and_index = null,
        .data = node,
    });
}

test "validateGlobal reports a root that no NodeState carries" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);

    try addNode(&state, nodeId(1), .generic_container);
    state.root_id = nodeId(7);
    state.focus_id = nodeId(1);

    try testing.expectError(error.RootNotInTree, validateGlobal(&state));

    // The same root passes once a node carries it, so the tag names the root
    // and not a state that has no nodes at all.
    try addNode(&state, nodeId(7), .window);
    try validateGlobal(&state);
}

test "validateGlobal reports a focus that no NodeState carries" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);

    try addNode(&state, nodeId(1), .generic_container);
    state.root_id = nodeId(1);
    state.focus_id = nodeId(9);

    try testing.expectError(error.FocusNotInTree, validateGlobal(&state));

    // A legal focus makes the state legal, so the check is about the focus and
    // not about the root it shares with the first test.
    try addNode(&state, nodeId(9), .window);
    try validateGlobal(&state);
}

test "validateGlobal reports the root when both ids are missing" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);

    // No node at all, so the state violates both invariants. Upstream checks
    // the root first at tree.rs:87, and the order is the contract a caller
    // matching on one tag depends on.
    state.root_id = nodeId(7);
    state.focus_id = nodeId(9);

    try testing.expectError(error.RootNotInTree, validateGlobal(&state));
}

test "computeEffectiveFocus keeps the focus when no root subtree is registered" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);

    // Node 2 is a graft node that no subtree names, so a walk that started
    // anyway would report `error.GraftWithoutSubtree`. Upstream returns
    // `self.focus` at tree.rs:103.
    try addNode(&state, nodeId(1), .window);
    state.focus_id = nodeId(1);
    try addGraftNode(&state, nodeId(2), treeIdFromLastByte(1));

    const effective = try computeEffectiveFocus(&state);

    try testing.expectEqual(nodeId(1), effective);
}

test "computeEffectiveFocus follows one graft into the subtree it names" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);

    const subtree_a = treeIdFromLastByte(1);
    // Node 1 is the root subtree's focus and names subtree A, so the walk must
    // leave it. Node 2 is the focus inside A and names no tree, so the walk
    // must stop there rather than report a missing subtree.
    try addGraftNode(&state, nodeId(1), subtree_a);
    try addNode(&state, nodeId(2), .window);
    try state.subtrees.put(testing.allocator, schema.tree_id_root, .{
        .root = nodeId(1),
        .focus = nodeId(1),
    });
    try state.subtrees.put(testing.allocator, subtree_a, .{
        .root = nodeId(2),
        .focus = nodeId(2),
    });

    const effective = try computeEffectiveFocus(&state);

    try testing.expectEqual(nodeId(2), effective);
}

test "computeEffectiveFocus reports a graft node whose subtree is not registered" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);

    // Node 1 names subtree A, and only the root tree is registered, so the walk
    // reaches a graft node it cannot follow. Upstream panics at tree.rs:112.
    try addGraftNode(&state, nodeId(1), treeIdFromLastByte(1));
    try state.subtrees.put(testing.allocator, schema.tree_id_root, .{
        .root = nodeId(1),
        .focus = nodeId(1),
    });

    try testing.expectError(error.GraftWithoutSubtree, computeEffectiveFocus(&state));
}

test "computeEffectiveFocus reports a graft chain longer than its bound" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);

    const subtree_a = treeIdFromLastByte(1);
    // Node 1 is the root subtree's focus and names A. Node 2 is A's focus and
    // names the root tree, so each step lands on a graft node and the walk
    // never reaches a node naming no tree. `graftChainStepBound` counts the two
    // registered subtrees, so the third step exhausts it.
    try addGraftNode(&state, nodeId(1), subtree_a);
    try addGraftNode(&state, nodeId(2), schema.tree_id_root);
    try state.subtrees.put(testing.allocator, schema.tree_id_root, .{
        .root = nodeId(1),
        .focus = nodeId(1),
    });
    try state.subtrees.put(testing.allocator, subtree_a, .{
        .root = nodeId(2),
        .focus = nodeId(2),
    });

    try testing.expectEqual(@as(usize, 3), graftChainStepBound(state.subtrees.count()));
    try testing.expectError(error.GraftChainTooLong, computeEffectiveFocus(&state));
}

test "computeEffectiveFocus stops at a focus that names no NodeState" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);

    // The root subtree's focus is not in `nodes`, so the walk ends at tree.rs:107
    // and returns that id. Node 1 holds the root, so `validateGlobal` passes the
    // root check and reaches the focus: the two functions answer different
    // questions about the same tree, and only one of them reports a missing
    // focus. The recorded focus is node 0 and the subtree's focus is node 9, so
    // an answer of node 0 would show the walk ignored the subtree.
    try addNode(&state, nodeId(1), .window);
    state.root_id = nodeId(1);
    state.focus_id = nodeId(0);
    try state.subtrees.put(testing.allocator, schema.tree_id_root, .{
        .root = nodeId(1),
        .focus = nodeId(9),
    });

    const effective = try computeEffectiveFocus(&state);

    try testing.expectEqual(nodeId(9), effective);
    try testing.expectError(error.FocusNotInTree, validateGlobal(&state));
}