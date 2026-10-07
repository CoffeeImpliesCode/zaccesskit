//! `NodeRef`: a borrowed handle to one node of a `TreeState`.
//!
//! A `NodeRef` names one node and holds two pointers into the state that owns
//! it. It allocates nothing and owns nothing, so it has no `deinit` and takes
//! no allocator. Every buffer a node carries belongs to `TreeState.nodes`, and
//! `Tree.deinit` releases them through the states it owns.
//!
//! **This file owns the `NodeRef` body.** Zig declares a method inside a struct
//! body, so only the module that owns a body may carry its methods. Every other
//! module under `src/consumer/` reaches a `NodeRef` operation as a free
//! function whose first parameter is the reference. `activeDescendant` below
//! is the one operation of that shape this file carries, and the layer graph
//! puts it here rather than the receiver rule: `tree_state.zig` calls it, and
//! it sits below every module that could otherwise hold it.
//!
//! **`FullNodeId` lives in `tree_index.zig` and `NodeState` in
//! `tree_state.zig`.** A data structure in each of those modules holds one of
//! them, so that module is the owner. This file names both and declares
//! neither. Moving either beside `NodeRef` reads tidier and makes the two
//! files import each other, so do not.
//!
//! **The borrow ends at the next call that can grow `TreeState.nodes`**, which
//! is an update that adds a node. Growing the map moves its entries, so a
//! `state` pointer taken before that update dangles. Build every `NodeRef`
//! again after an update.
//!
//! **A public field and a public method cannot share a name in Zig**, and a
//! parameter cannot shadow a method. Where a design asks for both, the method
//! keeps the name and the field is disambiguated, because section 8 pins the
//! method as the form a caller uses. So the member behind `id()` is `node_id`,
//! and so is the `init` parameter.
//!
//! Upstream: `accesskit_consumer/src/node.rs:77-82` for the type, with `data`
//! at `node.rs:85` and `id` at `node.rs:397`.

const std = @import("std");

const schema = @import("../schema/root.zig");
const tree_index = @import("tree_index.zig");
const tree_state = @import("tree_state.zig");

const FullNodeId = tree_index.FullNodeId;
const Node = schema.Node;
const NodeState = tree_state.NodeState;
const TreeState = tree_state.TreeState;

const testing = std.testing;

/// A borrowed handle to one node of one `TreeState`.
///
/// The value owns nothing, so it has no `deinit`. A copy is a second handle to
/// the same node, not a second owner of it, so there is nothing to release
/// twice.
pub const NodeRef = struct {
    /// The state that holds the node. A read through it reads the owner's
    /// storage, so the state must outlive every reference taken from it.
    tree_state: *const TreeState,

    /// The node this handle names. The value is two scalars and borrows
    /// nothing, so it stays usable after the handle it came from.
    node_id: FullNodeId,

    /// The node's entry in `tree_state.nodes`. Every handle to this node points
    /// at the same entry, so a write through one is visible through all of
    /// them.
    state: *const NodeState,

    /// The node this handle names, as a value that outlives the handle.
    pub fn id(self: NodeRef) FullNodeId {
        return self.node_id;
    }

    /// Borrows the node data, valid only as long as `self` is. The borrow ends
    /// at the next update that can grow `TreeState.nodes`.
    pub fn data(self: NodeRef) *const Node {
        return &self.state.data;
    }

    /// The only way to build one. `null` when `node_id` is not in
    /// `state.nodes`, because the state holds no entry for that node.
    pub fn init(state: *const TreeState, node_id: FullNodeId) ?NodeRef {
        const node_state = state.nodes.getPtr(node_id) orelse return null;
        return .{ .tree_state = state, .node_id = node_id, .state = node_state };
    }
};

/// The node `node`'s `active_descendant` property names, or `null`.
///
/// The id in the property is local to one tree, so it is resolved with
/// `node`'s own tree index and never in the root tree. `null` means the
/// property is unset, or that the `.and_then` at `node.rs:970` found no node
/// for the id. A miss is not an error, because the caller at `tree.rs:541`
/// turns it into the focused node itself. The result borrows the state `node`
/// borrows and ends when that borrow ends.
///
/// Upstream: `NodeRef::active_descendant`,
/// `accesskit_consumer/src/node.rs:966-971`.
pub fn activeDescendant(node: NodeRef) ?NodeRef {
    const local = schema.ids_props.activeDescendant(&node.data().properties) orelse
        return null;
    return NodeRef.init(node.tree_state, node.id().withSameTree(local));
}

/// Stores one parentless node under `id`. The state owns it from then on.
fn putNode(
    gpa: std.mem.Allocator,
    state: *TreeState,
    id: FullNodeId,
    role: schema.Role,
) std.mem.Allocator.Error!void {
    try state.nodes.put(gpa, id, .{
        .parent_and_index = null,
        .data = Node.init(gpa, role),
    });
}

/// Two nodes in one state, so a lookup that ignores the key is visible.
fn stateWithTwoNodes(gpa: std.mem.Allocator, state: *TreeState) std.mem.Allocator.Error!void {
    try putNode(gpa, state, FullNodeId.init(.{ .value = 11 }, .init(0)), .group);
    try putNode(gpa, state, FullNodeId.init(.{ .value = 22 }, .init(0)), .button);
}

test "NodeRef.init returns null when the state holds no node for the id" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const absent = FullNodeId.init(.{ .value = 99 }, .init(4));
    try testing.expect(NodeRef.init(&state, absent) == null);
}

test "NodeRef.init finds the entry the id names" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try stateWithTwoNodes(gpa, &state);

    const second = FullNodeId.init(.{ .value = 22 }, .init(0));
    const node = NodeRef.init(&state, second) orelse return error.NodeMissingFromState;

    // A lookup that ignored the key and took the first entry would answer
    // `.group` here, because the map keeps insertion order.
    try testing.expectEqual(schema.Role.button, node.data().role);
}

test "NodeRef.id returns the id the reference was built with" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try stateWithTwoNodes(gpa, &state);

    const first = FullNodeId.init(.{ .value = 11 }, .init(0));
    const second = FullNodeId.init(.{ .value = 22 }, .init(0));
    const one = NodeRef.init(&state, first) orelse return error.NodeMissingFromState;
    const two = NodeRef.init(&state, second) orelse return error.NodeMissingFromState;

    try testing.expectEqual(@as(u64, 11), one.id().local.value);
    try testing.expectEqual(@as(u64, 22), two.id().local.value);
    try testing.expectEqual(@as(u32, 0), one.id().tree_index.value());
}

test "NodeRef.data exposes the properties the state holds" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const id = FullNodeId.init(.{ .value = 5 }, .init(0));
    try putNode(gpa, &state, id, .button);
    const entry = state.nodes.getPtr(id) orelse return error.NodeMissingFromState;
    try schema.strings.setLabel(&entry.data.properties, "Save");

    const node = NodeRef.init(&state, id) orelse return error.NodeMissingFromState;
    const label = schema.strings.label(&node.data().properties) orelse return error.NoLabel;
    try testing.expectEqualStrings("Save", label);
}

test "a write through the owner is visible through every reference to the node" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const id = FullNodeId.init(.{ .value = 8 }, .init(2));
    try putNode(gpa, &state, id, .group);
    const first = NodeRef.init(&state, id) orelse return error.NodeMissingFromState;
    const second = NodeRef.init(&state, id) orelse return error.NodeMissingFromState;
    try testing.expectEqual(schema.Role.group, first.data().role);

    const owner = state.nodes.getPtr(id) orelse return error.NodeMissingFromState;
    owner.data.setRole(.button);
    try schema.strings.setLabel(&owner.data.properties, "Save");

    // A `NodeRef` that stored a copy of the node would still report `.group`
    // and no label here.
    try testing.expectEqual(schema.Role.button, first.data().role);
    try testing.expectEqual(schema.Role.button, second.data().role);
    const label = schema.strings.label(&first.data().properties) orelse return error.NoLabel;
    try testing.expectEqualStrings("Save", label);
}

test "activeDescendant returns null when the property is unset" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    const host = FullNodeId.init(.{ .value = 3 }, .init(0));
    try putNode(gpa, &state, host, .group);

    const node = NodeRef.init(&state, host) orelse return error.NodeMissingFromState;
    try testing.expect(activeDescendant(node) == null);
}

test "activeDescendant returns null when the named node is not in the state" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    const host = FullNodeId.init(.{ .value = 3 }, .init(0));
    try putNode(gpa, &state, host, .group);
    const entry = state.nodes.getPtr(host) orelse return error.NodeMissingFromState;
    try schema.ids_props.setActiveDescendant(&entry.data.properties, .{ .value = 404 });

    const node = NodeRef.init(&state, host) orelse return error.NodeMissingFromState;
    try testing.expect(activeDescendant(node) == null);
}

test "activeDescendant resolves the local id in the node's own tree" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    // Both trees hold local id 7, so a lookup in the root tree instead of the
    // node's own answers the wrong one.
    const in_root = FullNodeId.init(.{ .value = 7 }, .init(0));
    const in_graft = FullNodeId.init(.{ .value = 7 }, .init(1));
    const host = FullNodeId.init(.{ .value = 3 }, .init(1));
    try putNode(gpa, &state, in_root, .group);
    try putNode(gpa, &state, in_graft, .button);
    try putNode(gpa, &state, host, .group);
    const entry = state.nodes.getPtr(host) orelse return error.NodeMissingFromState;
    try schema.ids_props.setActiveDescendant(&entry.data.properties, .{ .value = 7 });

    const node = NodeRef.init(&state, host) orelse return error.NodeMissingFromState;
    const resolved = activeDescendant(node) orelse return error.NoActiveDescendant;
    try testing.expectEqual(schema.Role.button, resolved.data().role);
    try testing.expectEqual(@as(u64, 7), resolved.id().local.value);
    try testing.expectEqual(@as(u32, 1), resolved.id().tree_index.value());
}
