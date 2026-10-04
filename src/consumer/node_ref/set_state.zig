//! The state a node declares and a caller reads back: its value, its live
//! region, the nodes it controls, and the one-line property forwards that no
//! other module in the layer reaches.
//!
//! Upstream `accesskit_consumer/src/node.rs:840-995`, less the items the port
//! record below sends elsewhere. Every operation is a free function whose first
//! parameter is the `NodeRef`, because `consumer/node_id.zig` declares that
//! struct and no other file in the layer may carry its methods.
//!
//! **What belongs here and what does not.** A value here is a small answer the
//! node itself gives: what it says, whether it announces changes, which nodes it
//! drives. A predicate that matches a role belongs to `node_ref/predicates.zig`
//! and a composed walk belongs to `node_ref/strings.zig` or
//! `node_ref/containers.zig`, because both of those modules sit below the text
//! layer and this one reaches it.
//!
//! **What this module does not do.** It opens no file, reads no clock and
//! reaches no runtime. Only `value` owns memory, so only `value` takes `gpa`
//! for its own result. Every borrowed result says in its doc comment what
//! invalidates it. It declares no property accessor, so `schema.strings`,
//! `schema.ids_props`, `schema.enums`, `schema.flags` and `schema.option` stay
//! the only writers of a property.
//!
//! **Port record.** Seven items leave this module, and each went where the
//! import graph puts it rather than where the line range fell.
//!
//! * `node.rs:861-879`, `is_read_only_supported`, and `node.rs:881-900`,
//!   `should_have_read_only_state_by_default`, are in
//!   `node_ref/predicates.zig`. `node_ref/properties.zig` reaches them through
//!   `is_read_only` at `:474`, and reaching them from here would close the
//!   cycle `properties` to `set_state` to `text/query` to `containers` to
//!   `predicates` to `properties`. They are role matches.
//! * `node.rs:912-914`, `is_selected`, is in `node_ref/properties.zig`. It is a
//!   one-line property forward, and `node_ref/predicates.zig` needs it from
//!   `is_invocable` at `:684` and from `is_selectable` at `:622`.
//! * `node.rs:920-936`, `is_item_like`, and `node.rs:938-955`,
//!   `is_container_with_selectable_children`, are in
//!   `node_ref/containers.zig`, their only caller. Reaching them from here
//!   would close the same cycle, because `containers` reaches the text layer
//!   through this module's `writeValue`.
//! * `node.rs:966-971`, `active_descendant`, is in `consumer/node_id.zig`.
//!   `consumer/tree_state.zig` and `node_ref/predicates.zig` both call it, and
//!   neither may import a module at layer 7, so it sits beside the `NodeRef`
//!   body that already owns the lookup it needs.
//!
//! **Interfaces this file assumes**, because a sibling owns each one:
//! `node_ref/hierarchy.zig` supplies `parent`; `node_ref/predicates.zig` supplies
//! `isMultiline`; `text/query.zig` supplies `supportsTextRanges` and
//! `documentRange`; `text/range.zig` supplies `writeText`; and
//! `consumer/tree_state.zig` supplies `QueryError` and `treeWalkStepBound`.

const std = @import("std");
const schema = @import("../../schema/root.zig");
const node_id = @import("../node_id.zig");
const tree_index = @import("../tree_index.zig");
const tree_state = @import("../tree_state.zig");
const hierarchy = @import("hierarchy.zig");
const predicates = @import("predicates.zig");
const query = @import("../text/query.zig");
const range = @import("../text/range.zig");

const NodeRef = node_id.NodeRef;
const FullNodeId = tree_index.FullNodeId;
const TreeState = tree_state.TreeState;
const QueryError = tree_state.QueryError;
const NodeId = schema.NodeId;
const Live = schema.Live;
const TextSelection = schema.TextSelection;

// --- value, node.rs:840-859 ------------------------------------------------------

/// The stored `value` property, or `null` when the node declares none.
///
/// Borrows the store's buffer, and the next `setValue` or `clearValue` on that
/// node releases it.
pub fn rawValue(node: NodeRef) ?[]const u8 {
    return schema.strings.value(&node.data().properties);
}

/// Whether `node` has a value to give, without building it.
///
/// This is the question `writeValue` answers while it writes, asked on its own.
/// It allocates nothing and writes nothing, so a caller can ask before it reads.
/// A node with no stored `value` and no document range answers `false`.
///
/// `error.TreeCycle` when the run walk behind `supportsTextRanges` reaches its
/// bound. A stored `value` answers without walking and without an error.
pub fn hasValue(node: NodeRef) QueryError!bool {
    if (rawValue(node) != null) return true;
    return try query.supportsTextRanges(node) and !predicates.isMultiline(node);
}

/// The value of `node`, written to `writer`.
///
/// Takes `gpa` first because the document-range branch allocates the range's
/// ordering keys. Returns whether anything was written. A node with a stored
/// `value` writes that value. A node with none but with a document range and no
/// multiline role writes the text of that range. Every other node writes nothing
/// and answers `false`.
///
/// On `error.WriteFailed` the writer holds a prefix of the value and the caller
/// must discard it.
pub fn writeValue(
    gpa: std.mem.Allocator,
    node: NodeRef,
    writer: *std.Io.Writer,
) (QueryError || std.Io.Writer.Error)!bool {
    if (rawValue(node)) |text| {
        try writer.writeAll(text);
        return true;
    }
    if (try query.supportsTextRanges(node) and !predicates.isMultiline(node)) {
        try range.writeText(gpa, try query.documentRange(gpa, node), writer);
        return true;
    }
    return false;
}

/// The value of `node` as a buffer the caller owns.
///
/// Allocates, so it takes `gpa` first. A `null` return means `writeValue` wrote
/// nothing, so there is nothing to release. The caller releases the buffer with
/// the same `gpa`. On any error nothing is allocated.
pub fn value(
    gpa: std.mem.Allocator,
    node: NodeRef,
) (QueryError || std.Io.Writer.Error)!?std.ArrayList(u8) {
    var collecting: std.Io.Writer.Allocating = .init(gpa);
    defer collecting.deinit();
    // `Allocating` reports a failed growth as `error.WriteFailed`, because a
    // `std.Io.Writer` carries one error tag. This collecting writer is the only
    // writer in the chain below, so that tag is exactly `error.OutOfMemory`.
    const wrote = writeValue(gpa, node, &collecting.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };
    if (!wrote) return null;
    return collecting.toArrayList();
}

// --- live, node.rs:906-910 -------------------------------------------------------

/// The nearest `live` value on `node` or on one of its ancestors, or `.off`.
///
/// Upstream `node.rs:906-910`. The walk stops at the node that declares the
/// property, so the answer is the nearest declaration above `node` and never a
/// merge of two.
///
/// **Bound.** The walk climbs one parent at a time, so it takes
/// `treeWalkStepBound` from `consumer/tree_state.zig`, and the derivation is
/// `docs/33` section 7's: each step moves to a different node, the state holds
/// at most `node_count` nodes, and a cycle repeats a node, so the count catches
/// the repeat. A cyclic parent chain answers `error.TreeCycle` instead of
/// recursing until the stack runs out.
pub fn live(node: NodeRef) QueryError!Live {
    return try liveWithin(node, tree_state.treeWalkStepBound(node.tree_state.nodes.count()));
}

/// One step of `live`, with the budget it has left.
fn liveWithin(node: NodeRef, budget: usize) QueryError!Live {
    if (schema.enums.live(&node.data().properties)) |stored| return stored;
    const parent = hierarchy.parent(node) orelse return .off;
    if (budget == 0) return error.TreeCycle;
    return try liveWithin(parent, budget - 1);
}

// --- controls, node.rs:957-964 ---------------------------------------------------

/// The nodes `node` controls, in the order the `controls` property lists them.
///
/// Upstream `node.rs:957-964`. `next` walks the list forward and `nextBack`
/// walks it backward, so a caller may take the list from either end. Upstream
/// returns an opaque double-ended iterator; this names its two cursors, because
/// a caller must be able to see that the whole list is still there.
pub fn controls(node: NodeRef) ControlsIterator {
    const ids = schema.ids_props.controls(&node.data().properties);
    return .{
        .tree_state = node.tree_state,
        .node_id = node.node_id,
        .ids = ids,
        .front = 0,
        .back = ids.len,
    };
}

/// The controlled nodes of one node. Upstream `impl DoubleEndedIterator<Item =
/// NodeRef>`, `node.rs:963`.
///
/// The value borrows the controlling node's property store through `ids` and
/// the state through `tree_state`, so it is only valid while both are. Rebuild
/// it after an update.
pub const ControlsIterator = struct {
    /// Where the controlled nodes are looked up. Borrowed from the `NodeRef`
    /// `controls` was called on.
    tree_state: *const TreeState,
    /// The controlling node. Every id in `ids` names a node in this node's
    /// tree, so the iterator resolves each one with `withSameTree`.
    node_id: FullNodeId,
    /// Borrows the controlling node's property store.
    ids: []const NodeId,
    /// The index `next` reads next, counted from the front.
    front: usize,
    /// One past the index `nextBack` reads next, so the two cursors meet and
    /// every id is yielded exactly once.
    back: usize,

    /// The next controlled node in property order, or `null` when the list is
    /// exhausted from the front.
    ///
    /// **An id the state does not hold answers `error.NoSuchNode`.** Upstream
    /// unwraps the same lookup at `node.rs:963`, and a `.unwrap()` in a port is
    /// a named error rather than a panic.
    pub fn next(self: *ControlsIterator) QueryError!?NodeRef {
        if (self.front >= self.back) return null;
        const local = self.ids[self.front];
        self.front += 1;
        return self.resolve(local);
    }

    /// The next controlled node in reverse property order, or `null` when the
    /// list is exhausted from the back.
    ///
    /// **An id the state does not hold answers `error.NoSuchNode`,** for the
    /// reason `next` gives.
    pub fn nextBack(self: *ControlsIterator) QueryError!?NodeRef {
        if (self.front >= self.back) return null;
        self.back -= 1;
        return self.resolve(self.ids[self.back]);
    }

    /// The node `local` names inside the controlling node's own tree.
    fn resolve(self: *ControlsIterator, local: NodeId) QueryError!?NodeRef {
        const found = NodeRef.init(self.tree_state, self.node_id.withSameTree(local)) orelse
            return error.NoSuchNode;
        return found;
    }
};

// --- one-line property forwards, node.rs:902-995 ---------------------------------

/// Whether the node declares itself required. Upstream `node.rs:902-904`.
///
/// A flag with no stored value, so this never fails and never allocates.
pub fn isRequired(node: NodeRef) bool {
    return schema.flags.isRequired(node.data().flags);
}

/// Whether a touch passes through this node to what is below it. Upstream
/// `node.rs:916-918`. A flag, so this never fails and never allocates.
pub fn isTouchTransparent(node: NodeRef) bool {
    return schema.flags.isTouchTransparent(node.data().flags);
}

/// The stored `text_selection`, or `null` when the node declares none.
///
/// Borrows the store's payload, and the next `setTextSelection` or
/// `clearTextSelection` on that node releases it.
pub fn rawTextSelection(node: NodeRef) ?*const TextSelection {
    return schema.option.textSelection(&node.data().properties);
}

/// The stored `author_id`, or `null` when the node declares none.
///
/// Borrows the store's buffer, and the next `setAuthorId` or `clearAuthorId` on
/// that node releases it.
pub fn authorId(node: NodeRef) ?[]const u8 {
    return schema.strings.authorId(&node.data().properties);
}

/// The stored `html_id`, or `null` when the node declares none.
///
/// Borrows the store's buffer, and the next `setHtmlId` or `clearHtmlId` on
/// that node releases it.
pub fn htmlId(node: NodeRef) ?[]const u8 {
    return schema.strings.htmlId(&node.data().properties);
}

/// Whether the node declares an `html_id`. Upstream `node.rs:989-991`.
pub fn hasHtmlId(node: NodeRef) bool {
    return schema.strings.htmlId(&node.data().properties) != null;
}

/// The stored `class_name`, or `null` when the node declares none.
///
/// Borrows the store's buffer, and the next `setClassName` or `clearClassName`
/// on that node releases it.
pub fn className(node: NodeRef) ?[]const u8 {
    return schema.strings.className(&node.data().properties);
}

// --- tests ----------------------------------------------------------------------

const testing = std.testing;
const test_allocator = testing.allocator;

const Node = schema.Node;
const ParentAndIndex = tree_index.ParentAndIndex;

fn nodeId(raw: u64) NodeId {
    return .{ .value = raw };
}

fn fullNodeId(id: NodeId) FullNodeId {
    return FullNodeId.init(id, .init(0));
}

fn parentAndIndex(parent: NodeId, index: usize) ParentAndIndex {
    return .{ .parent_id = fullNodeId(parent), .index = index };
}

/// A `TreeState` with node 1 as its root and its focus. Every fixture puts the
/// nodes it uses, so the maps hold no other entry.
fn testState() TreeState {
    return .{
        .root_id = fullNodeId(nodeId(1)),
        .focus_id = fullNodeId(nodeId(1)),
    };
}

/// Adds one node under `id`. The state takes ownership of `node`, so the caller
/// must not release it. `parent` is `null` for a root.
fn put(state: *TreeState, id: NodeId, parent: ?ParentAndIndex, node: Node) !void {
    try state.nodes.put(test_allocator, fullNodeId(id), .{
        .parent_and_index = parent,
        .data = node,
    });
}

/// The `NodeRef` for `id`. Every fixture puts the node in first, so this never
/// answers `null` and a failed expectation is the fixture's own defect.
fn refOf(state: *TreeState, id: NodeId) !NodeRef {
    return NodeRef.init(state, fullNodeId(id)) orelse error.NodeMissingFromFixture;
}

test "rawValue reads the stored property and clears to null" {
    var state = testState();
    defer state.deinit(test_allocator);
    var node = Node.init(test_allocator, .text_input);
    try schema.strings.setValue(&node.properties, "typed");
    try put(&state, nodeId(1), null, node);

    const node_ref = try refOf(&state, nodeId(1));
    const text = rawValue(node_ref) orelse return error.ExpectedTheStoredValue;
    try testing.expectEqualStrings("typed", text);
    schema.strings.clearValue(&state.nodes.getPtr(fullNodeId(nodeId(1))).?.data.properties);
    try testing.expect(rawValue(node_ref) == null);
}

test "hasValue and writeValue agree on the stored value" {
    var state = testState();
    defer state.deinit(test_allocator);
    var node = Node.init(test_allocator, .text_input);
    try schema.strings.setValue(&node.properties, "typed");
    try put(&state, nodeId(1), null, node);

    const node_ref = try refOf(&state, nodeId(1));
    try testing.expect(try hasValue(node_ref));
    var buffer: [16]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buffer);
    try testing.expect(try writeValue(test_allocator, node_ref, &sink));
    try testing.expectEqualStrings("typed", buffer[0..sink.end]);

    var owned = (try value(test_allocator, node_ref)) orelse return error.ExpectedAValue;
    defer owned.deinit(test_allocator);
    try testing.expectEqualStrings("typed", owned.items);
}

test "hasValue and writeValue agree that a bare node has no value" {
    var state = testState();
    defer state.deinit(test_allocator);
    const bare = Node.init(test_allocator, .button);
    try put(&state, nodeId(1), null, bare);

    const bare_ref = try refOf(&state, nodeId(1));
    try testing.expect(!(try hasValue(bare_ref)));
    var buffer: [16]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buffer);
    try testing.expect(!try writeValue(test_allocator, bare_ref, &sink));
    try testing.expectEqual(@as(usize, 0), sink.end);
    try testing.expect((try value(test_allocator, bare_ref)) == null);
}

test "live reads the stored property, then a parent, then answers off" {
    var state = testState();
    defer state.deinit(test_allocator);
    const root = Node.init(test_allocator, .button);
    try put(&state, nodeId(1), null, root);
    var middle = Node.init(test_allocator, .button);
    try schema.enums.setLive(&middle.properties, .polite);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), middle);
    const leaf = Node.init(test_allocator, .button);
    try put(&state, nodeId(3), parentAndIndex(nodeId(2), 0), leaf);

    try testing.expectEqual(Live.off, try live(try refOf(&state, nodeId(1))));
    try testing.expectEqual(Live.polite, try live(try refOf(&state, nodeId(3))));
}

test "live answers error.TreeCycle on a cyclic parent chain" {
    var state = testState();
    defer state.deinit(test_allocator);
    const first = Node.init(test_allocator, .button);
    try put(&state, nodeId(1), parentAndIndex(nodeId(2), 0), first);
    const second = Node.init(test_allocator, .button);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), second);

    try testing.expectError(error.TreeCycle, live(try refOf(&state, nodeId(1))));
}

test "controls walks the property order from both ends" {
    var state = testState();
    defer state.deinit(test_allocator);
    var owner = Node.init(test_allocator, .button);
    try schema.ids_props.setControls(&owner.properties, &.{ nodeId(2), nodeId(3) });
    try put(&state, nodeId(1), null, owner);
    const first = Node.init(test_allocator, .button);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), first);
    const second = Node.init(test_allocator, .button);
    try put(&state, nodeId(3), parentAndIndex(nodeId(1), 1), second);

    var forward = controls(try refOf(&state, nodeId(1)));
    const one = (try forward.next()) orelse return error.ExpectedTwoControlled;
    try testing.expectEqual(nodeId(2), one.id().local);
    const two = (try forward.next()) orelse return error.ExpectedTwoControlled;
    try testing.expectEqual(nodeId(3), two.id().local);
    try testing.expect((try forward.next()) == null);

    var backward = controls(try refOf(&state, nodeId(1)));
    const last = (try backward.nextBack()) orelse return error.ExpectedTwoControlled;
    try testing.expectEqual(nodeId(3), last.id().local);
    const first_back = (try backward.nextBack()) orelse return error.ExpectedTwoControlled;
    try testing.expectEqual(nodeId(2), first_back.id().local);
    try testing.expect((try backward.nextBack()) == null);
}

test "controls answers error.NoSuchNode for an id the state does not hold" {
    var state = testState();
    defer state.deinit(test_allocator);
    var owner = Node.init(test_allocator, .button);
    try schema.ids_props.setControls(&owner.properties, &.{nodeId(9)});
    try put(&state, nodeId(1), null, owner);

    var it = controls(try refOf(&state, nodeId(1)));
    try testing.expectError(error.NoSuchNode, it.next());
}

test "controls answers null at once for a node with no controls" {
    var state = testState();
    defer state.deinit(test_allocator);
    const owner = Node.init(test_allocator, .button);
    try put(&state, nodeId(1), null, owner);

    var it = controls(try refOf(&state, nodeId(1)));
    try testing.expect((try it.next()) == null);
    try testing.expect((try it.nextBack()) == null);
}

test "the one-line forwards answer what the store holds" {
    var state = testState();
    defer state.deinit(test_allocator);
    var node = Node.init(test_allocator, .button);
    schema.flags.setRequired(&node.flags, true);
    schema.flags.setTouchTransparent(&node.flags, true);
    try schema.strings.setAuthorId(&node.properties, "suite");
    try schema.strings.setHtmlId(&node.properties, "save-button");
    try schema.strings.setClassName(&node.properties, "Button");
    try schema.option.setTextSelection(
        &node.properties,
        .{
            .anchor = .{ .node_id = nodeId(2), .character_index = 0 },
            .focus = .{ .node_id = nodeId(2), .character_index = 1 },
        },
    );
    try put(&state, nodeId(1), null, node);
    const bare = Node.init(test_allocator, .button);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), bare);

    const node_ref = try refOf(&state, nodeId(1));
    try testing.expect(isRequired(node_ref));
    try testing.expect(isTouchTransparent(node_ref));
    try testing.expectEqualStrings("suite", (authorId(node_ref)).?);
    try testing.expectEqualStrings("save-button", (htmlId(node_ref)).?);
    try testing.expect(hasHtmlId(node_ref));
    try testing.expectEqualStrings("Button", (className(node_ref)).?);
    try testing.expect((rawTextSelection(node_ref)) != null);

    const bare_ref = try refOf(&state, nodeId(2));
    try testing.expect(!isRequired(bare_ref));
    try testing.expect(!isTouchTransparent(bare_ref));
    try testing.expect(authorId(bare_ref) == null);
    try testing.expect(htmlId(bare_ref) == null);
    try testing.expect(!hasHtmlId(bare_ref));
    try testing.expect(className(bare_ref) == null);
    try testing.expect(rawTextSelection(bare_ref) == null);
}