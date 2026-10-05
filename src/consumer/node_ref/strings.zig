//! The text a node presents to an assistive technology: its label, its
//! description and its URL.
//!
//! Upstream `accesskit_consumer/src/node.rs:719-838`. Every operation is a free
//! function whose first parameter is the `NodeRef`, because
//! `consumer/node_id.zig` declares that struct and no other file in the layer
//! may carry its methods.
//!
//! **Two label operations, and they are not the same one.** `rawLabel` reads
//! the stored `label` property and answers `null` when the node declares none.
//! `writeLabel` reads that property first and, when it holds nothing, walks the
//! nodes `labelledBy` resolves to and joins whatever they contribute with
//! single spaces. `label` is `writeLabel` collected into a buffer the caller
//! owns. The pair `writeLabelDirect` and `writeLabel` is the difference in one
//! line: the first never leaves the node it was called on, the second follows
//! `labelled_by`. Both names exist upstream and both exist here, because
//! `writeLabelDirect` is also the per-contributor read inside the walk, and
//! collapsing the two would make the walk recursive.
//!
//! **A resolved reference borrows from the node it resolved to.** `labelledBy`
//! names other nodes. `labelledLabel` and `rawLabel` therefore return a slice
//! out of the store of the node `labelledNode` returns, not out of the store of
//! the node the caller started from. The next write to *that* node's `label`
//! releases the buffer and the slice dangles. A write to the starting node
//! changes nothing. `labelledNode` exists so that the owner is a value the
//! caller can name rather than a fact it has to remember.
//!
//! **Allocator order.** An allocating free function takes `gpa` first per
//! `AGENTS.md:99`; an allocating method takes the receiver first, because Zig
//! builds the call syntax only in that order. Three entry points here take
//! `gpa`, and all three are free functions, so all three take it first. This
//! file is where the rule is written out, because it is the layer's string
//! module and every module below it follows the same order.
//!
//! `writeLabel` takes `gpa` even though it allocates nothing of its own,
//! because it reaches `writeValue` for a label-role contributor and that
//! reaches the document range, which allocates its ordering keys. Nothing here
//! opens a file, reads a clock or reaches a runtime.
//!
//! **Port record.**
//!
//! * `iterators.rs:537-585`, `LabelledBy`, is declared here. Upstream keeps it
//!   in `iterators.rs`, but `docs/30-port-design.md` section 3.2 gives
//!   `node.rs:719-824` to this module, and `node_ref/strings.zig` is the only
//!   place that builds the value. `iterators/children.zig` records the same
//!   decision at the end of its own range.
//! * `node.rs:834-838`, `placeholder`, is declared here and not in
//!   `node_ref/set_state.zig`. It calls `is_empty_text_input` at `:821-832` and
//!   `is_text_input` at `:562`, both above the line `docs/33` section 1.1
//!   draws at 824, and that line cuts through `is_empty_text_input`. Keeping
//!   `placeholder` here is what leaves one arrow between this module and
//!   `node_ref/set_state.zig`.
//! * `node.rs:1076-1101`, `SpacePrefixingWriter`, is deleted. The wrapper
//!   deferred one space until the first byte a contributor wrote. `hasLabel`
//!   already asks the same question without writing, and `labelNamesThrough`
//!   below asks it once for both callers, so `writeLabel` writes the space
//!   itself when the answer is yes. The bytes are the same and one type fewer.
//! * `node.rs:806-808`, `url`, and `node.rs:802-804`, `has_description`, are
//!   declared here. They are one-line property forwards that belong to the
//!   string family this module owns, and `node_ref/properties.zig` does not
//!   declare them, so this module is the only place they exist.
//!
//! **Interfaces this file assumes**, because a sibling owns each one:
//! `node_ref/properties.zig` supplies `role`; `node_ref/predicates.zig` supplies
//! `descendantLabelFilter` and `isTextInput`; `node_ref/set_state.zig` supplies
//! `hasValue` and `writeValue`; `node_ref/hierarchy.zig` supplies
//! `filteredChildren`; `text/position_inner.zig` supplies `textRuns`; and
//! `consumer/filter.zig` supplies `FilterFn` and `FilterResult`.

const std = @import("std");
const schema = @import("../../schema/root.zig");
const node_id = @import("../node_id.zig");
const filter = @import("../filter.zig");
const tree_index = @import("../tree_index.zig");
const tree_state = @import("../tree_state.zig");
const children_iterator = @import("../iterators/children.zig");
const hierarchy = @import("hierarchy.zig");
const predicates = @import("predicates.zig");
const properties = @import("properties.zig");
const set_state = @import("set_state.zig");
const position_inner = @import("../text/position_inner.zig");

const NodeRef = node_id.NodeRef;
const FullNodeId = tree_index.FullNodeId;
const TreeState = tree_state.TreeState;
const QueryError = tree_state.QueryError;
const FilterResult = filter.FilterResult;
const NodeId = schema.NodeId;
const Role = schema.Role;

// --- labelled_by, node.rs:719-742 ------------------------------------------------

/// Whether a control with no explicit `labelled_by` takes its label from the
/// label and image nodes below it. Upstream `node.rs:723-732`.
fn takesLabelFromDescendants(role: Role) bool {
    return switch (role) {
        .button,
        .check_box,
        .default_button,
        .link,
        .menu_item,
        .menu_item_check_box,
        .menu_item_radio,
        .radio_button,
        => true,
        else => false,
    };
}

/// `predicates.descendantLabelFilter` as the `FilterFn` the subtree walk takes.
///
/// The predicate is private upstream and returns no error, so this adapter is
/// the whole difference between the two shapes: it supplies the context
/// parameter `FilterFn` carries and lifts the answer into `QueryError`.
fn labelledByFilter(_: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    return predicates.descendantLabelFilter(node);
}

/// The explicit `labelled_by` list of one node, read from either end.
///
/// Upstream `LabelledBy::Explicit`, `iterators.rs:539-543`. It borrows the
/// controlling node's property store through `ids` and the state through
/// `tree_state`, so it is valid only while both are.
pub const ExplicitLabelledBy = struct {
    /// Borrows the controlling node's property store.
    ids: []const NodeId,
    /// Where the ids are resolved. Borrowed from the `NodeRef` that built this.
    tree_state: *const TreeState,
    /// The controlling node. Every id is resolved inside this node's own tree,
    /// never in the root tree.
    node_id: FullNodeId,
    /// The index `next` reads next, counted from the front.
    front: usize,
    /// One past the index `nextBack` reads next, so the two cursors meet and
    /// every id is yielded exactly once.
    back: usize,

    /// The next node the list names, or `null` when the front is exhausted.
    ///
    /// **`error.NoSuchNode`** when the state holds no node for the id. Upstream
    /// unwraps the same lookup at `iterators.rs:558`, and a `.unwrap()` in a
    /// port is a named error rather than a panic.
    pub fn next(self: *ExplicitLabelledBy) QueryError!?NodeRef {
        if (self.front >= self.back) return null;
        const local = self.ids[self.front];
        self.front += 1;
        return self.resolve(local);
    }

    /// The next node the list names from the back, or `null` when the back is
    /// exhausted. **`error.NoSuchNode`,** for the reason `next` gives.
    pub fn nextBack(self: *ExplicitLabelledBy) QueryError!?NodeRef {
        if (self.front >= self.back) return null;
        self.back -= 1;
        return self.resolve(self.ids[self.back]);
    }

    /// The node `local` names inside the controlling node's own tree.
    fn resolve(self: *ExplicitLabelledBy, local: NodeId) QueryError!?NodeRef {
        const found = NodeRef.init(self.tree_state, self.node_id.withSameTree(local)) orelse
            return error.NoSuchNode;
        return found;
    }
};

/// The nodes that name one node. Upstream `LabelledBy`, `iterators.rs:537-585`.
///
/// The union has two arms because upstream has two: a subtree walk for a
/// control that declares no ids and takes its label from what is below it, and
/// the explicit id list for every other node.
pub const LabelledBy = union(enum) {
    /// The label and image nodes below the control, in depth-first order.
    from_descendants: children_iterator.FilteredChildrenIterator,
    /// The ids the control declares, in property order.
    explicit: ExplicitLabelledBy,

    /// The next node that names this one, or `null` when the walk ends.
    ///
    /// **`error.NoSuchNode`** when an explicit id names a node the state does
    /// not hold, and **`error.TreeCycle`** when the subtree walk reaches its
    /// bound.
    pub fn next(self: *LabelledBy) QueryError!?NodeRef {
        return switch (self.*) {
            .from_descendants => |*cursor| cursor.next(),
            .explicit => |*cursor| cursor.next(),
        };
    }

    /// The next node that names this one, read from the back of the walk.
    ///
    /// The errors are the ones `next` gives.
    pub fn nextBack(self: *LabelledBy) QueryError!?NodeRef {
        return switch (self.*) {
            .from_descendants => |*cursor| cursor.nextBack(),
            .explicit => |*cursor| cursor.nextBack(),
        };
    }
};

/// The nodes that name `node`, in the order the walk reaches them.
///
/// A node that declares the `labelled_by` property yields exactly the nodes it
/// lists. A control that declares none and has one of the eight roles in
/// `takesLabelFromDescendants` yields the label and image nodes below it
/// instead. Every other node yields nothing.
///
/// Borrows the nodes out of the state, so the invalidation rule of every other
/// `NodeRef` applies: rebuild it after an update.
pub fn labelledBy(node: NodeRef) QueryError!LabelledBy {
    const ids = schema.ids_props.labelledBy(&node.data().properties);
    if (ids.len == 0 and takesLabelFromDescendants(properties.role(node))) {
        return .{ .from_descendants = try hierarchy.filteredChildren(node, .{
            .context = null,
            .filter = labelledByFilter,
        }) };
    }
    return .{ .explicit = .{
        .ids = ids,
        .tree_state = node.tree_state,
        .node_id = node.node_id,
        .front = 0,
        .back = ids.len,
    } };
}

/// The `index`-th node `labelledBy` resolves to, or `null` when the walk is
/// shorter than `index`.
///
/// This is the owner of every slice `labelledLabel` returns, which is why it is
/// a separate operation and not a detail of `labelledLabel`. The walk runs at
/// most `index` times before it stops, so a large `index` costs the length of
/// the labelling list and nothing else.
pub fn labelledNode(node: NodeRef, index: usize) QueryError!?NodeRef {
    var it = try labelledBy(node);
    var seen: usize = 0;
    while (seen < index) : (seen += 1) {
        _ = try it.next() orelse return null;
    }
    return try it.next();
}

/// The stored label of the `index`-th node `labelledBy` resolves to, or `null`
/// when the walk is shorter than `index` or that node declares no label.
///
/// **The slice belongs to the resolved node's store, not to `node`'s store.** A
/// write to the `label` property of the node `labelledNode(node, index)`
/// returns releases the buffer, and this slice then dangles. A write to
/// `node`'s own properties leaves it alone, because this slice never pointed
/// into `node`'s store. A caller that holds the slice across such a write reads
/// freed memory, so copy it first when it must outlive the write.
pub fn labelledLabel(node: NodeRef, index: usize) QueryError!?[]const u8 {
    const owner = try labelledNode(node, index) orelse return null;
    return rawLabel(owner);
}

// --- label, node.rs:744-794 -----------------------------------------------------

/// Whether this node's own text is its `value` rather than its `label`.
///
/// Upstream `label_comes_from_value`, `node.rs:744-746`. A node with the label
/// role carries its text through `value`, so a walk that reads `label` on such a
/// node finds nothing.
pub fn labelComesFromValue(node: NodeRef) bool {
    return properties.role(node) == .label;
}

/// The stored `label` property, with no `labelled_by` fallback and no copy.
///
/// Borrows the store's buffer. The next `setLabel` or `clearLabel` on that node
/// releases it. Returns `null` when the node declares no label, which is a
/// different answer from an empty string.
pub fn rawLabel(node: NodeRef) ?[]const u8 {
    return schema.strings.label(&node.data().properties);
}

/// Whether a contributor named by `labelledBy` has something to say.
///
/// Upstream asks the same question twice, as the `bool` that
/// `write_label_direct` and `write_value` return. Both answers are pure, so
/// this asks without writing and without an allocator. A label-role node
/// answers through `hasValue` and every other node answers through its stored
/// label, which is exactly the pair of branches `writeLabel` takes below.
fn labelNamesThrough(labelled: NodeRef) QueryError!bool {
    return if (labelComesFromValue(labelled))
        try set_state.hasValue(labelled)
    else
        rawLabel(labelled) != null;
}

/// The stored label of `node` alone, written to `writer`.
///
/// Returns whether anything was written. It never follows `labelled_by`, which
/// is the whole difference from `writeLabel`.
///
/// On `error.WriteFailed` the writer holds a prefix of the label and the caller
/// must discard it.
fn writeLabelDirect(node: NodeRef, writer: *std.Io.Writer) std.Io.Writer.Error!bool {
    const text = rawLabel(node) orelse return false;
    try writer.writeAll(text);
    return true;
}

/// The label of `node`: its stored label, or the labels of the nodes
/// `labelledBy` resolves to joined with single spaces.
///
/// Allocates nothing of its own, but it reaches `writeValue` for a label-role
/// contributor, and that reaches the document range, which allocates its
/// ordering keys. So it takes `gpa` first.
///
/// Returns whether anything was written, so a node with no label and no
/// contributor answers `false` and leaves `writer` untouched. A contributor
/// that says nothing contributes no space, so neither a leading nor a trailing
/// space is possible.
///
/// On `error.WriteFailed` the writer holds a prefix of the label and the caller
/// must discard it. On `error.NoSuchNode` or `error.TreeCycle` the walk stopped
/// and the caller must discard the writer too.
pub fn writeLabel(
    gpa: std.mem.Allocator,
    node: NodeRef,
    writer: *std.Io.Writer,
) (QueryError || std.Io.Writer.Error)!bool {
    if (try writeLabelDirect(node, writer)) return true;
    var wrote_one = false;
    var contributors = try labelledBy(node);
    // Bounded by the length of `labelledBy`: one step per contributor, and the
    // walk stops when the walk ends.
    while (try contributors.next()) |labelled| {
        if (!(try labelNamesThrough(labelled))) continue;
        if (wrote_one) try writer.writeByte(' ');
        const wrote_this = if (labelComesFromValue(labelled))
            try set_state.writeValue(gpa, labelled, writer)
        else
            try writeLabelDirect(labelled, writer);
        wrote_one = wrote_one or wrote_this;
    }
    return wrote_one;
}

/// The label of `node` as a buffer the caller owns.
///
/// Allocates, so it takes `gpa` first. A `null` return means `writeLabel` wrote
/// nothing, so there is nothing to release. The caller releases the buffer with
/// the same `gpa`. On any error nothing is allocated.
pub fn label(
    gpa: std.mem.Allocator,
    node: NodeRef,
) (QueryError || std.Io.Writer.Error)!?std.ArrayList(u8) {
    var collecting: std.Io.Writer.Allocating = .init(gpa);
    defer collecting.deinit();
    // `Allocating` reports a failed growth as `error.WriteFailed`, because a
    // `std.Io.Writer` carries one error tag. This collecting writer is the only
    // writer in the chain below, so that tag is exactly `error.OutOfMemory`.
    const wrote = writeLabel(gpa, node, &collecting.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };
    if (!wrote) return null;
    return collecting.toArrayList();
}

/// Whether `node` has a label, without building one.
///
/// A node with a stored label answers `true` at once. Otherwise each node
/// `labelledBy` resolves to is asked whether it has something to say, and the
/// first one that does ends the walk. A node with neither answers `false`.
///
/// The errors are the ones `labelledBy` gives: `error.NoSuchNode` for an id the
/// state does not hold and `error.TreeCycle` for a subtree walk that reached its
/// bound.
pub fn hasLabel(node: NodeRef) QueryError!bool {
    if (rawLabel(node) != null) return true;
    var contributors = try labelledBy(node);
    // Bounded by the length of `labelledBy`: one step per contributor, and the
    // walk stops at the first contributor that has something to say.
    while (try contributors.next()) |labelled| {
        if (try labelNamesThrough(labelled)) return true;
    }
    return false;
}

// --- description and URL, node.rs:796-820 ---------------------------------------

/// A copy of the stored `description` property, or `null` when the node declares
/// none.
///
/// Allocates, so it takes `gpa` first. The caller releases the buffer with the
/// same `gpa`. A `null` return means there is nothing to release, and
/// `error.OutOfMemory` leaves the store exactly as it was.
pub fn description(
    gpa: std.mem.Allocator,
    node: NodeRef,
) std.mem.Allocator.Error!?std.ArrayList(u8) {
    const text = schema.strings.description(&node.data().properties) orelse return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, text);
    return out;
}

/// Whether `node` declares a description. Upstream `node.rs:802-804`.
pub fn hasDescription(node: NodeRef) bool {
    return schema.strings.description(&node.data().properties) != null;
}

/// The stored `url` property. Upstream `node.rs:806-808`.
///
/// Borrows the store's buffer, and the next `setUrl` or `clearUrl` on that node
/// releases it.
pub fn url(node: NodeRef) ?[]const u8 {
    return schema.strings.url(&node.data().properties);
}

/// Whether `node` carries a URL and a role that presents it.
///
/// Upstream `supports_url`, `node.rs:810-819`. Both halves are required, so a
/// link without a URL and a node with a URL but no link role both answer
/// `false`.
pub fn supportsUrl(node: NodeRef) bool {
    return switch (properties.role(node)) {
        .link, .doc_back_link, .doc_biblio_ref, .doc_gloss_ref, .doc_note_ref => url(node) != null,
        else => false,
    };
}

// --- placeholder, node.rs:821-838 -----------------------------------------------

/// Whether `node` is a text input whose only text run is absent or empty.
///
/// Upstream `is_empty_text_input`, `node.rs:821-832`, and private there. Two or
/// more text runs answer `false` whatever they hold, because a control with
/// text already does not show a placeholder.
///
/// `error.TreeCycle` when the run walk reaches its bound.
fn isEmptyTextInput(node: NodeRef) QueryError!bool {
    var runs = try position_inner.textRuns(node);
    const first = (try runs.next()) orelse return true;
    const stored = schema.strings.value(&first.data().properties);
    const first_is_empty = stored == null or stored.?.len == 0;
    return first_is_empty and (try runs.next()) == null;
}

/// The stored `placeholder` property, but only for an empty text input.
///
/// A control that already holds text has no placeholder to show, so this
/// answers `null` for it even when the property is set. Borrows the store's
/// buffer, and the next `setPlaceholder` or `clearPlaceholder` on that node
/// releases it.
///
/// `error.TreeCycle` when the run walk reaches its bound.
pub fn placeholder(node: NodeRef) QueryError!?[]const u8 {
    const text = schema.strings.placeholder(&node.data().properties) orelse return null;
    if (!predicates.isTextInput(node)) return null;
    if (!try isEmptyTextInput(node)) return null;
    return text;
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

/// A mutable handle on a node the state owns. A test needs one to write a
/// property after the node is in the state, because a `NodeRef` hands back only
/// a `*const Node`.
fn writable(state: *TreeState, id: NodeId) !*Node {
    const entry = state.nodes.getPtr(fullNodeId(id)) orelse return error.NodeMissingFromFixture;
    return &entry.data;
}

/// What `writeLabel` writes into `buffer`, as a slice of that buffer.
fn collectLabel(node: NodeRef, buffer: []u8) ![]const u8 {
    var sink = std.Io.Writer.fixed(buffer);
    _ = try writeLabel(test_allocator, node, &sink);
    return buffer[0..sink.end];
}

test "labelledBy yields the nodes the labelled_by property lists" {
    var state = testState();
    defer state.deinit(test_allocator);
    var control = Node.init(test_allocator, .button);
    try schema.ids_props.setLabelledBy(&control.properties, &.{ nodeId(2), nodeId(3) });
    try put(&state, nodeId(1), null, control);
    var first = Node.init(test_allocator, .label);
    try schema.strings.setLabel(&first.properties, "Save");
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), first);
    var second = Node.init(test_allocator, .label);
    try schema.strings.setLabel(&second.properties, "Cancel");
    try put(&state, nodeId(3), parentAndIndex(nodeId(1), 1), second);

    var it = try labelledBy(try refOf(&state, nodeId(1)));
    const one = (try it.next()) orelse return error.ExpectedTwoContributors;
    try testing.expectEqual(nodeId(2), one.id().local);
    const two = (try it.next()) orelse return error.ExpectedTwoContributors;
    try testing.expectEqual(nodeId(3), two.id().local);
    try testing.expect((try it.next()) == null);
}

test "labelledBy walks descendants for a button with no explicit labelled_by" {
    var state = testState();
    defer state.deinit(test_allocator);
    var control = Node.init(test_allocator, .button);
    try schema.ids_props.setChildren(&control.properties, &.{ nodeId(2), nodeId(3) });
    try put(&state, nodeId(1), null, control);
    const filler = Node.init(test_allocator, .paragraph);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), filler);
    const descendant_label = Node.init(test_allocator, .label);
    try put(&state, nodeId(3), parentAndIndex(nodeId(1), 1), descendant_label);

    var it = try labelledBy(try refOf(&state, nodeId(1)));
    const found = (try it.next()) orelse return error.ExpectedTheLabelNode;
    try testing.expectEqual(nodeId(3), found.id().local);
    try testing.expect((try it.next()) == null);
}

test "labelledBy yields nothing for a role that takes no descendant label" {
    var state = testState();
    defer state.deinit(test_allocator);
    var paragraph = Node.init(test_allocator, .paragraph);
    try schema.ids_props.setChildren(&paragraph.properties, &.{nodeId(2)});
    try put(&state, nodeId(1), null, paragraph);
    const descendant_label = Node.init(test_allocator, .label);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), descendant_label);

    var it = try labelledBy(try refOf(&state, nodeId(1)));
    try testing.expect((try it.next()) == null);
}

test "labelledNode answers null past the end of the walk" {
    var state = testState();
    defer state.deinit(test_allocator);
    var control = Node.init(test_allocator, .button);
    try schema.ids_props.setLabelledBy(&control.properties, &.{nodeId(2)});
    try put(&state, nodeId(1), null, control);
    const owner = Node.init(test_allocator, .label);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), owner);

    const control_ref = try refOf(&state, nodeId(1));
    const found = (try labelledNode(control_ref, 0)) orelse return error.ExpectedOneContributor;
    try testing.expectEqual(nodeId(2), found.id().local);
    try testing.expect((try labelledNode(control_ref, 1)) == null);
}

test "labelledLabel borrows the resolved node and a write to it invalidates the slice" {
    var state = testState();
    defer state.deinit(test_allocator);
    var control = Node.init(test_allocator, .button);
    try schema.ids_props.setLabelledBy(&control.properties, &.{nodeId(2)});
    try put(&state, nodeId(1), null, control);
    var owner = Node.init(test_allocator, .label);
    try schema.strings.setLabel(&owner.properties, "Save");
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), owner);

    const control_ref = try refOf(&state, nodeId(1));
    const owner_node = try writable(&state, nodeId(2));

    const borrowed = (try labelledLabel(control_ref, 0)) orelse
        return error.ExpectedTheBorrowedLabel;
    try testing.expectEqualStrings("Save", borrowed);

    // A write to the node the caller started from changes nothing, which is
    // what proves the slice never sat in that node's store.
    try schema.strings.setLabel(&(try writable(&state, nodeId(1))).properties, "Control own label");
    try testing.expectEqualStrings("Save", (try labelledLabel(control_ref, 0)).?);

    // A write to the resolved node releases the buffer the slice pointed at.
    // The stale slice is deliberately not read after this line.
    try schema.strings.setLabel(&owner_node.properties, "Open");
    const fresh = (try labelledLabel(control_ref, 0)) orelse
        return error.ExpectedTheBorrowedLabel;
    try testing.expectEqualStrings("Open", fresh);
    try testing.expect(fresh.ptr != borrowed.ptr);
}

test "labelledLabel answers null when the resolved node declares no label" {
    var state = testState();
    defer state.deinit(test_allocator);
    var control = Node.init(test_allocator, .button);
    try schema.ids_props.setLabelledBy(&control.properties, &.{nodeId(2)});
    try put(&state, nodeId(1), null, control);
    const owner = Node.init(test_allocator, .label);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), owner);

    try testing.expect((try labelledLabel(try refOf(&state, nodeId(1)), 0)) == null);
}

test "labelledLabel answers error.NoSuchNode for an id the state does not hold" {
    var state = testState();
    defer state.deinit(test_allocator);
    var control = Node.init(test_allocator, .button);
    try schema.ids_props.setLabelledBy(&control.properties, &.{nodeId(9)});
    try put(&state, nodeId(1), null, control);

    try testing.expectError(error.NoSuchNode, labelledLabel(try refOf(&state, nodeId(1)), 0));
}

test "labelComesFromValue is true only for the label role" {
    var state = testState();
    defer state.deinit(test_allocator);
    const label_node = Node.init(test_allocator, .label);
    try put(&state, nodeId(1), null, label_node);
    const text_node = Node.init(test_allocator, .text_input);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), text_node);

    try testing.expect(labelComesFromValue(try refOf(&state, nodeId(1))));
    try testing.expect(!labelComesFromValue(try refOf(&state, nodeId(2))));
}

test "rawLabel reads the stored property and clears to null" {
    var state = testState();
    defer state.deinit(test_allocator);
    var label_node = Node.init(test_allocator, .label);
    try schema.strings.setLabel(&label_node.properties, "Save");
    try put(&state, nodeId(1), null, label_node);

    const label_ref = try refOf(&state, nodeId(1));
    const text = rawLabel(label_ref) orelse return error.ExpectedTheStoredLabel;
    try testing.expectEqualStrings("Save", text);

    schema.strings.clearLabel(&(try writable(&state, nodeId(1))).properties);
    try testing.expect(rawLabel(label_ref) == null);
}

test "label collects the stored label into a buffer the caller owns" {
    var state = testState();
    defer state.deinit(test_allocator);
    var control = Node.init(test_allocator, .button);
    try schema.strings.setLabel(&control.properties, "Save");
    try put(&state, nodeId(1), null, control);

    var owned = (try label(test_allocator, try refOf(&state, nodeId(1)))) orelse
        return error.ExpectedALabel;
    defer owned.deinit(test_allocator);
    try testing.expectEqualStrings("Save", owned.items);
}

test "label joins two contributors with one space and skips the silent one" {
    var state = testState();
    defer state.deinit(test_allocator);
    var control = Node.init(test_allocator, .button);
    try schema.ids_props.setLabelledBy(&control.properties, &.{ nodeId(2), nodeId(3), nodeId(4) });
    try put(&state, nodeId(1), null, control);
    // A contributor with the label role speaks through its `value`. Upstream
    // reads the text of a label node from `value` (`node.rs:744-746`), and the
    // schema says the same at `accesskit/src/lib.rs:2099-2101`. The silent
    // contributor declares neither property, so it names nothing and adds no
    // space.
    var first = Node.init(test_allocator, .label);
    try schema.strings.setValue(&first.properties, "Save");
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), first);
    const silent = Node.init(test_allocator, .label);
    try put(&state, nodeId(3), parentAndIndex(nodeId(1), 1), silent);
    var third = Node.init(test_allocator, .label);
    try schema.strings.setValue(&third.properties, "Cancel");
    try put(&state, nodeId(4), parentAndIndex(nodeId(1), 2), third);

    var owned = (try label(test_allocator, try refOf(&state, nodeId(1)))) orelse
        return error.ExpectedALabel;
    defer owned.deinit(test_allocator);
    try testing.expectEqualStrings("Save Cancel", owned.items);
}

test "label answers null for a node with no label and no contributor" {
    var state = testState();
    defer state.deinit(test_allocator);
    const bare = Node.init(test_allocator, .button);
    try put(&state, nodeId(1), null, bare);

    const bare_ref = try refOf(&state, nodeId(1));
    try testing.expect(!(try hasLabel(bare_ref)));
    try testing.expect((try label(test_allocator, bare_ref)) == null);

    var buffer: [16]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buffer);
    try testing.expect(!try writeLabel(test_allocator, bare_ref, &sink));
    try testing.expectEqual(@as(usize, 0), sink.end);
}

test "writeLabelDirect writes the stored label of the node it was called on" {
    var state = testState();
    defer state.deinit(test_allocator);
    var control = Node.init(test_allocator, .button);
    try schema.strings.setLabel(&control.properties, "Save");
    try schema.ids_props.setLabelledBy(&control.properties, &.{nodeId(2)});
    try put(&state, nodeId(1), null, control);
    var owner = Node.init(test_allocator, .label);
    try schema.strings.setLabel(&owner.properties, "Cancel");
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), owner);

    var with_own: [16]u8 = undefined;
    var own_sink = std.Io.Writer.fixed(&with_own);
    try testing.expect(try writeLabelDirect(try refOf(&state, nodeId(1)), &own_sink));
    try testing.expectEqualStrings("Save", with_own[0..own_sink.end]);

    // Node 2 declares its own label, so the direct path writes it. This is the
    // difference from `writeLabel`: `writeLabelDirect` never follows
    // `labelled_by`, and a node that stores a label has one to write.
    var with_owners: [16]u8 = undefined;
    var owners_sink = std.Io.Writer.fixed(&with_owners);
    try testing.expect(try writeLabelDirect(try refOf(&state, nodeId(2)), &owners_sink));
    try testing.expectEqualStrings("Cancel", with_owners[0..owners_sink.end]);

    // Node 3 exists only to have no label and no contributor, which is the one
    // case where the direct path writes nothing and says so.
    const silent = Node.init(test_allocator, .label);
    try put(&state, nodeId(3), parentAndIndex(nodeId(1), 1), silent);
    var without_own: [16]u8 = undefined;
    var bare_sink = std.Io.Writer.fixed(&without_own);
    try testing.expect(!try writeLabelDirect(try refOf(&state, nodeId(3)), &bare_sink));
    try testing.expectEqual(@as(usize, 0), bare_sink.end);
}

test "writeLabel follows labelled_by when the node stores no label" {
    var state = testState();
    defer state.deinit(test_allocator);
    var control = Node.init(test_allocator, .button);
    try schema.ids_props.setLabelledBy(&control.properties, &.{nodeId(2)});
    try put(&state, nodeId(1), null, control);
    // The contributor has the label role, so it speaks through its `value`.
    var owner = Node.init(test_allocator, .label);
    try schema.strings.setValue(&owner.properties, "Save");
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), owner);

    var buffer: [16]u8 = undefined;
    const written = try collectLabel(try refOf(&state, nodeId(1)), &buffer);
    try testing.expectEqualStrings("Save", written);
}

test "writeLabel walks descendants and reads each contributor through its role" {
    var state = testState();
    defer state.deinit(test_allocator);
    // A button with no `labelled_by` takes its label from the label and image
    // nodes below it. A label node speaks through its `value` and an image node
    // speaks through its stored label. `labelComesFromValue` chooses between
    // the two.
    var control = Node.init(test_allocator, .button);
    try schema.ids_props.setChildren(&control.properties, &.{ nodeId(2), nodeId(3) });
    try put(&state, nodeId(1), null, control);
    var label_node = Node.init(test_allocator, .label);
    try schema.strings.setValue(&label_node.properties, "Save");
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), label_node);
    var image = Node.init(test_allocator, .image);
    try schema.strings.setLabel(&image.properties, "floppy disk");
    try put(&state, nodeId(3), parentAndIndex(nodeId(1), 1), image);

    var buffer: [32]u8 = undefined;
    const written = try collectLabel(try refOf(&state, nodeId(1)), &buffer);
    try testing.expectEqualStrings("Save floppy disk", written);
}

test "hasLabel is true through a contributor and false without one" {
    var state = testState();
    defer state.deinit(test_allocator);
    var control = Node.init(test_allocator, .button);
    try schema.ids_props.setLabelledBy(&control.properties, &.{nodeId(2)});
    try put(&state, nodeId(1), null, control);
    var owner = Node.init(test_allocator, .label);
    try schema.strings.setValue(&owner.properties, "Save");
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), owner);
    const bare = Node.init(test_allocator, .button);
    try put(&state, nodeId(3), parentAndIndex(nodeId(1), 1), bare);

    try testing.expect(try hasLabel(try refOf(&state, nodeId(1))));
    try testing.expect(!(try hasLabel(try refOf(&state, nodeId(3)))));
}

test "description copies the stored property and answers null when absent" {
    var state = testState();
    defer state.deinit(test_allocator);
    var node = Node.init(test_allocator, .button);
    try schema.strings.setDescription(&node.properties, "Saves the file");
    try put(&state, nodeId(1), null, node);
    const bare = Node.init(test_allocator, .button);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), bare);

    var owned = (try description(test_allocator, try refOf(&state, nodeId(1)))) orelse
        return error.ExpectedADescription;
    defer owned.deinit(test_allocator);
    try testing.expectEqualStrings("Saves the file", owned.items);
    try testing.expect(hasDescription(try refOf(&state, nodeId(1))));
    try testing.expect((try description(test_allocator, try refOf(&state, nodeId(2)))) == null);
    try testing.expect(!hasDescription(try refOf(&state, nodeId(2))));
}

test "url borrows the store and supportsUrl needs a role that presents it" {
    var state = testState();
    defer state.deinit(test_allocator);
    var link = Node.init(test_allocator, .link);
    try schema.strings.setUrl(&link.properties, "https://example.invalid");
    try put(&state, nodeId(1), null, link);
    const urlless_link = Node.init(test_allocator, .link);
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), urlless_link);
    var paragraph = Node.init(test_allocator, .paragraph);
    try schema.strings.setUrl(&paragraph.properties, "https://example.invalid");
    try put(&state, nodeId(3), parentAndIndex(nodeId(1), 1), paragraph);

    const text = url(try refOf(&state, nodeId(1))) orelse return error.ExpectedAUrl;
    try testing.expectEqualStrings("https://example.invalid", text);
    try testing.expect(url(try refOf(&state, nodeId(2))) == null);
    try testing.expect(supportsUrl(try refOf(&state, nodeId(1))));
    try testing.expect(!supportsUrl(try refOf(&state, nodeId(2))));
    try testing.expect(!supportsUrl(try refOf(&state, nodeId(3))));
}

test "placeholder is null for a text input that already holds text" {
    var state = testState();
    defer state.deinit(test_allocator);
    var input = Node.init(test_allocator, .text_input);
    try schema.strings.setPlaceholder(&input.properties, "Search");
    try schema.ids_props.setChildren(&input.properties, &.{nodeId(2)});
    try put(&state, nodeId(1), null, input);
    var run = Node.init(test_allocator, .text_run);
    try schema.strings.setValue(&run.properties, "already typed");
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), run);

    const input_ref = try refOf(&state, nodeId(1));
    try testing.expect(!(try isEmptyTextInput(input_ref)));
    try testing.expect((try placeholder(input_ref)) == null);
}

test "placeholder survives on an empty text input and not on another role" {
    var state = testState();
    defer state.deinit(test_allocator);
    var input = Node.init(test_allocator, .text_input);
    try schema.strings.setPlaceholder(&input.properties, "Search");
    try put(&state, nodeId(1), null, input);
    var paragraph = Node.init(test_allocator, .paragraph);
    try schema.strings.setPlaceholder(&paragraph.properties, "Search");
    try put(&state, nodeId(2), parentAndIndex(nodeId(1), 0), paragraph);

    const input_ref = try refOf(&state, nodeId(1));
    try testing.expect(try isEmptyTextInput(input_ref));
    const text = (try placeholder(input_ref)) orelse return error.ExpectedAPlaceholder;
    try testing.expectEqualStrings("Search", text);
    try testing.expect((try placeholder(try refOf(&state, nodeId(2)))) == null);
}
