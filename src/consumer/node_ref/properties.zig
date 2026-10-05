//! The raw property reads on a `NodeRef`, and the two walks that read a
//! property from an ancestor.
//!
//! Upstream range: `accesskit_consumer/src/node.rs:397-560`, plus `node.rs:122`
//! and `node.rs:912`. The closing note names every item that sits outside those
//! lines and why.
//!
//! **This module owns no property accessor.** `schema/props/` owns the eight
//! accessor families and the store itself, so a read here is one call into
//! `schema.strings`, `schema.numbers`, `schema.enums`, `schema.option` or
//! `schema.flags`. There is one implementation of "read the label" in the tree,
//! and it is not this file.
//!
//! **Absent is `null`, and `null` is not a value.** `PropertyId` has 87 tags and
//! no sentinel (`docs/32` section 4). A property that is not set has no entry in
//! the store, so its accessor answers `null`. `null` means the node says nothing
//! about the property, and it never means "the property has its default". The 18
//! flags are the one exception, and the accessor modules state it: a flag has no
//! unset value, so `false` means both "never carried the bit" and "the bit was
//! cleared". Nothing in this module invents a sentinel to stand in for an absent
//! property, and nothing here converts `null` into a default.
//!
//! **Inheritance is a walk, and the walk is bounded.** A raw read asks one node.
//! `fetchInheritedProperty` and `fetchInheritedFlag` start at that node and step
//! to its parent until a value appears or the chain ends. The bound is
//! `treeWalkStepBound(node.tree_state.nodes.count())`, which
//! `consumer/tree_state.zig` declares as bounds 5 to 9 of 9 in `docs/33`
//! section 7. The derivation: every step moves to a different node, the tree
//! holds at most `nodes.count()` of them, so a walk over an acyclic chain
//! examines at most that many nodes and ends by finding no parent. A chain that
//! repeats a node examines `nodes.count()` nodes and still wants to step again,
//! so the count catches the repeat and the walk answers `error.TreeCycle`. There
//! is no depth parameter, because a depth with no derivation is a guess.
//!
//! **The walk reads the state directly, and that is deliberate.**
//! `consumer/node_ref/hierarchy.zig` publishes `parent`, which answers about one
//! node. This walk resolves an ancestor chain over many, and routing it through
//! `parent` would make `properties.zig` depend on `hierarchy.zig` while
//! `hierarchy.zig` takes `isGraft` from this file. The duplication is two lines:
//! read `NodeState.parent_and_index`, then look the id up with
//! `TreeState.nodeById`. `docs/33` section 1.3 already blesses this pattern for
//! the `iterators/` modules, which sit below the module that owns the parent
//! query for the same reason.
//!
//! **Names.** Every read carries upstream's name in `camelCase`, so a reader who
//! knows `accesskit_consumer` finds the same word. The one exception is the
//! `raw` prefix, and it appears only where a store-level read shares its word
//! with a derived reader elsewhere in the layer. `rawIsHidden` is the bit behind
//! `isHidden`, and `rawIsReadOnly` is the bit behind `isReadOnly` in
//! `predicates.zig`. Every other read is unambiguous and carries no prefix,
//! which is why `clipsChildren` and `isModal` have none.
//!
//! **What this module does not do.** It allocates nothing, so no function here
//! takes an allocator and a caller releases nothing after any call. It does not
//! block, so no function here takes `io`. A returned `[]const u8` borrows the
//! store's buffer and is invalidated by the next write to that property. It
//! opens no file, reads no clock and holds no global.

const std = @import("std");

const schema = @import("../../schema/root.zig");
const node_id = @import("../node_id.zig");
const tree_index = @import("../tree_index.zig");
const tree_state = @import("../tree_state.zig");

const FullNodeId = tree_index.FullNodeId;
const NodeId = schema.NodeId;
const NodeRef = node_id.NodeRef;
const Node = schema.Node;
const ParentAndIndex = tree_index.ParentAndIndex;
const QueryError = tree_state.QueryError;
const treeWalkStepBound = tree_state.treeWalkStepBound;

const flags = schema.flags;
const enums = schema.enums;
const numbers = schema.numbers;
const option = schema.option;
const strings = schema.strings;

const testing = std.testing;

/// Reads one flag bit of one node. See `fetchInheritedFlag`.
///
/// A plain function pointer and never a closure, because a capture would hide
/// the sequence of nodes the walk visits. The getter reads the bit through
/// `schema.flags`, so it holds no state of its own and the same answer comes out
/// of it whatever the walk has already seen.
pub const FlagGetter = *const fn (data: *const Node) bool;

/// The role the platform reported for this node, which upstream is the `role`
/// field of `Node` and not a store entry.
///
/// `Role.unknown` means the platform reported nothing better, so it is a value
/// the tree carries and not an absent property.
pub fn role(node: NodeRef) schema.Role {
    return node.data().role;
}

/// Whether this node is a graft node, which upstream is a node carrying a
/// `tree_id`. A graft node points at a subtree root instead of holding children.
pub fn isGraft(node: NodeRef) bool {
    return option.treeId(&node.data().properties) != null;
}

/// The pair `TreeState.locateNode` answers, under a name this module owns.
///
/// The two shapes are structurally identical and deliberately not the same type,
/// because `TreeState.locateNode` writes its result as an anonymous struct and a
/// call site that holds one of each converts field by field.
pub const LocateResult = struct {
    /// The id inside the node's own tree.
    local_id: NodeId,
    /// The tree the node belongs to.
    tree_id: schema.TreeId,
};

/// The local id and the tree id behind `node`, or `null` when
/// `TreeState.tree_index_map` holds no tree index for this handle.
///
/// `null` cannot arrive for a handle from `NodeRef.init`, because that call
/// reads the node out of `TreeState.nodes` and the index map is written before
/// the nodes it indexes. Upstream returns a pair and unwraps at `node.rs:402`;
/// this returns the optional `TreeState.locateNode` already had, so the one
/// case upstream aborts on is a value a caller handles.
pub fn locate(node: NodeRef) ?LocateResult {
    const found = node.tree_state.locateNode(node.id()) orelse return null;
    return .{ .local_id = found.local_id, .tree_id = found.tree_id };
}

/// The human-readable name of the node's role, or `null` when the node states
/// none. Borrows the store's buffer until the next write to `role_description`.
pub fn roleDescription(node: NodeRef) ?[]const u8 {
    return strings.roleDescription(&node.data().properties);
}

/// Whether the node states a `role_description`. An empty string still counts,
/// because the property is present.
pub fn hasRoleDescription(node: NodeRef) bool {
    return roleDescription(node) != null;
}

/// Whether the node is a live region that withholds its updates as one batch.
pub fn isLiveAtomic(node: NodeRef) bool {
    return flags.isLiveAtomic(node.data().flags);
}

/// Whether the node is waiting on an operation and withholds its state.
pub fn isBusy(node: NodeRef) bool {
    return flags.isBusy(node.data().flags);
}

/// The text form of the node's column index, for a node in a grid or table.
pub fn columnIndexText(node: NodeRef) ?[]const u8 {
    return strings.columnIndexText(&node.data().properties);
}

/// The text form of the node's row index, for a node in a grid or table.
pub fn rowIndexText(node: NodeRef) ?[]const u8 {
    return strings.rowIndexText(&node.data().properties);
}

/// The label as a braille display reads it, which can differ from `label`.
pub fn brailleLabel(node: NodeRef) ?[]const u8 {
    return strings.brailleLabel(&node.data().properties);
}

/// Whether the node states a `braille_label`.
pub fn hasBrailleLabel(node: NodeRef) bool {
    return brailleLabel(node) != null;
}

/// The role description as a braille display reads it.
pub fn brailleRoleDescription(node: NodeRef) ?[]const u8 {
    return strings.brailleRoleDescription(&node.data().properties);
}

/// Whether the node states a `braille_role_description`.
pub fn hasBrailleRoleDescription(node: NodeRef) bool {
    return brailleRoleDescription(node) != null;
}

/// Which element in a set is current, for ARIA `aria-current`.
pub fn ariaCurrent(node: NodeRef) ?schema.AriaCurrent {
    return enums.ariaCurrent(&node.data().properties);
}

/// What kind of popup this node opens, or `null` when it opens none.
///
/// A stored value is never `null`, and `null` is not `HasPopup.menu`: the
/// property is absent, so the node opens no popup at all.
pub fn hasPopup(node: NodeRef) ?schema.HasPopup {
    return enums.hasPopup(&node.data().properties);
}

/// Whether this node or an ancestor is hidden, so this node and its descendants
/// are out of the tree a platform presents and out of hit testing.
///
/// Bounded by `treeWalkStepBound`, see the module doc. `false` means the chain
/// ended with no hidden node, which is the ordinary answer for a visible tree,
/// and `error.TreeCycle` means the chain repeated a node, which upstream's
/// `loop` at `node.rs:550` would not survive.
pub fn isHidden(node: NodeRef) QueryError!bool {
    return fetchInheritedFlag(node, hiddenBit);
}

/// The bit behind `isHidden`. The `raw` prefix separates the store's own bit
/// from the walk that consults it, because both answer the same word.
pub fn rawIsHidden(node: NodeRef) bool {
    return hiddenBit(node.data());
}

/// The hierarchical level of this node inside a structure, counted from zero, or
/// `null` when the node states none.
pub fn level(node: NodeRef) ?usize {
    return numbers.level(&node.data().properties);
}

/// Whether this node and its focusable descendants take no input.
pub fn isDisabled(node: NodeRef) bool {
    return flags.isDisabled(node.data().flags);
}

/// Whether the node's own state says it is read only.
///
/// This is the bit and not the answer. `predicates.isReadOnly` is the answer, and
/// the two differ for a role that is read only by default, so they need
/// different names.
pub fn rawIsReadOnly(node: NodeRef) bool {
    return flags.isReadOnly(node.data().flags);
}

/// Whether the node states a selection state, which is not the same as `false`.
pub fn isSelected(node: NodeRef) ?bool {
    return enums.isSelected(&node.data().properties);
}

/// The pressed state of a toggle, or `null` when the node is not a toggle.
pub fn toggled(node: NodeRef) ?schema.Toggled {
    return enums.toggled(&node.data().properties);
}

/// The current value of a range control, as ARIA `aria-valuenow`.
pub fn numericValue(node: NodeRef) ?f64 {
    return numbers.numericValue(&node.data().properties);
}

/// The lowest value a range control accepts.
pub fn minNumericValue(node: NodeRef) ?f64 {
    return numbers.minNumericValue(&node.data().properties);
}

/// The highest value a range control accepts.
pub fn maxNumericValue(node: NodeRef) ?f64 {
    return numbers.maxNumericValue(&node.data().properties);
}

/// The amount one step of a range control changes the value by.
pub fn numericValueStep(node: NodeRef) ?f64 {
    return numbers.numericValueStep(&node.data().properties);
}

/// The amount one page of a range control changes the value by.
pub fn numericValueJump(node: NodeRef) ?f64 {
    return numbers.numericValueJump(&node.data().properties);
}

/// Whether the node clips the children that fall outside its bounds. A consumer
/// uses this to decide whether an off-screen child is reachable at all.
pub fn clipsChildren(node: NodeRef) bool {
    return flags.clipsChildren(node.data().flags);
}

/// The current horizontal scroll offset of a scrollable container.
pub fn scrollX(node: NodeRef) ?f64 {
    return numbers.scrollX(&node.data().properties);
}

/// The leftmost horizontal scroll offset of a scrollable container.
pub fn scrollXMin(node: NodeRef) ?f64 {
    return numbers.scrollXMin(&node.data().properties);
}

/// The rightmost horizontal scroll offset of a scrollable container.
pub fn scrollXMax(node: NodeRef) ?f64 {
    return numbers.scrollXMax(&node.data().properties);
}

/// The current vertical scroll offset of a scrollable container.
pub fn scrollY(node: NodeRef) ?f64 {
    return numbers.scrollY(&node.data().properties);
}

/// The topmost vertical scroll offset of a scrollable container.
pub fn scrollYMin(node: NodeRef) ?f64 {
    return numbers.scrollYMin(&node.data().properties);
}

/// The bottommost vertical scroll offset of a scrollable container.
pub fn scrollYMax(node: NodeRef) ?f64 {
    return numbers.scrollYMax(&node.data().properties);
}

/// The first value `getter` answers for `node` or for an ancestor of it.
///
/// `T` is the property's type, which upstream writes as `fetch_inherited_property
/// <T>` at `node.rs:534`. The walk starts at `node`, tests it, and steps to its
/// parent while the value is `null`. `null` from the return means no node on the
/// chain states the property, which is not the same as a node stating its
/// default.
///
/// The getter is a plain function pointer and never a closure, because a
/// capture would hide the sequence of nodes the walk visits. Bounded by
/// `treeWalkStepBound`, see the module doc. `error.TreeCycle` means the parent
/// chain repeated a node, and `error.NoSuchNode` means `parent_and_index` names
/// a node the state does not hold.
pub fn fetchInheritedProperty(
    comptime T: type,
    node: NodeRef,
    getter: *const fn (data: *const Node) ?T,
) QueryError!?T {
    const bound = treeWalkStepBound(node.tree_state.nodes.count());
    var current = node;
    var step: usize = 0;
    while (step < bound) : (step += 1) {
        if (getter(current.data())) |value| return value;
        current = try ancestorOf(current) orelse return null;
    }
    return error.TreeCycle;
}

/// Whether `getter` answers `true` for `node` or for an ancestor of it.
///
/// The walk is the shape `fetchInheritedProperty` has, and `false` from the
/// return means no node on the chain sets the bit, which is the ordinary outcome
/// for a visible tree.
///
/// Bounded by `treeWalkStepBound`, see the module doc. `error.TreeCycle` and
/// `error.NoSuchNode` mean what they mean in `fetchInheritedProperty`.
pub fn fetchInheritedFlag(node: NodeRef, getter: FlagGetter) QueryError!bool {
    const bound = treeWalkStepBound(node.tree_state.nodes.count());
    var current = node;
    var step: usize = 0;
    while (step < bound) : (step += 1) {
        if (getter(current.data())) return true;
        current = try ancestorOf(current) orelse return false;
    }
    return error.TreeCycle;
}

/// The `hidden` bit, read through `schema.flags`. One function, so the walk and
/// the raw read cannot drift apart.
fn hiddenBit(data: *const Node) bool {
    return flags.isHidden(data.flags);
}

/// The node named by `node`'s `parent_and_index`, or `null` when `node` is a
/// root.
///
/// `error.NoSuchNode` replaces the `.unwrap()` at `node.rs:135`. State invariant
/// I2 says every id in a `children` list has a `NodeState`, so a
/// `parent_and_index` naming no node is a broken tree, and a broken tree is a
/// value the caller handles rather than an abort.
fn ancestorOf(node: NodeRef) QueryError!?NodeRef {
    const link: ?ParentAndIndex = node.state.parent_and_index;
    const parent_id: FullNodeId = if (link) |parent| parent.parent_id else return null;
    return node.tree_state.nodeById(parent_id) orelse error.NoSuchNode;
}

// -- Tests --

/// A tree built for the tests. It owns every node it holds, so `deinit`
/// releases them.
///
/// **Build the whole tree before taking a handle.** A handle borrows an entry of
/// `TreeState.nodes`, and `add` can grow the map, and growing the map moves its
/// entries. `docs/33` section 4 states that rule for a handle a caller holds
/// across an update, and the tests below follow it: every test adds its nodes
/// and then asks `nodeAt` for the handles it needs.
const Fixture = struct {
    gpa: std.mem.Allocator,
    state: tree_state.TreeState,

    fn init(gpa: std.mem.Allocator) Fixture {
        return .{ .gpa = gpa, .state = .{} };
    }

    fn deinit(self: *Fixture) void {
        self.state.deinit(self.gpa);
        // SAFETY: `state.deinit` released every buffer the fixture owned, and
        // no statement after it reads `self`.
        self.* = undefined;
    }

    /// Puts a clone of `source` at `content`, under `parent` or at the root.
    /// `parent` may name a node that is not in the state yet, which is how the
    /// cycle tests close a chain.
    fn add(self: *Fixture, content: u64, parent: ?u64, source: *const Node) !void {
        const id: FullNodeId = fullNodeId(content);
        try self.state.nodes.put(self.gpa, id, .{
            .parent_and_index = if (parent) |parent_content| ParentAndIndex{
                .parent_id = fullNodeId(parent_content),
                .index = 0,
            } else null,
            .data = try Node.clone(self.gpa, source),
        });
    }
};

/// The handle for the node whose local id content is `content`. Take it after
/// the last `add`.
fn nodeAt(fixture: *const Fixture, content: u64) NodeRef {
    return fixture.state.nodeById(fullNodeId(content)).?;
}

fn fullNodeId(content: u64) FullNodeId {
    return FullNodeId.init(schema.nodeIdFromContent(content), .init(0));
}

/// The getter the value walks use. `level` is `usize` and carries no default
/// tag, so `null` and `0` are two different answers.
fn readLevel(data: *const Node) ?usize {
    return numbers.level(&data.properties);
}

/// The value `fetchInheritedProperty` finds for the node at `content`, so a test
/// line stays short enough to read.
fn inheritedLevel(fixture: *const Fixture, content: u64) QueryError!?usize {
    return fetchInheritedProperty(usize, nodeAt(fixture, content), readLevel);
}

/// The flag getter that answers `false` for every node, so a flag walk runs the
/// whole chain and still finds nothing.
fn neverSet(data: *const Node) bool {
    _ = data;
    return false;
}

/// One flag bit, with the setter that stores it and the read this module
/// publishes for it. The sweep sets one bit and checks that exactly one read
/// answers `true`, which is what a swapped pair of reads fails.
const FlagCase = struct {
    store: *const fn (mask: *u32, value: bool) void,
    read: *const fn (node: NodeRef) bool,
};

const flag_cases = [_]FlagCase{
    .{ .store = flags.setHidden, .read = rawIsHidden },
    .{ .store = flags.setDisabled, .read = isDisabled },
    .{ .store = flags.setReadOnly, .read = rawIsReadOnly },
    .{ .store = flags.setBusy, .read = isBusy },
    .{ .store = flags.setLiveAtomic, .read = isLiveAtomic },
    .{ .store = flags.setClipsChildren, .read = clipsChildren },
};

test "a stored zero and an absent property are two different answers" {
    // The rule this module exists to keep: `null` means the node says nothing,
    // so it can never stand in for a stored zero.
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var stated = Node.init(gpa, .list_item);
    defer stated.deinit();
    try numbers.setLevel(&stated.properties, 0);

    var plain = Node.init(gpa, .list_item);
    defer plain.deinit();

    try fixture.add(1, null, &stated);
    try fixture.add(2, null, &plain);

    try testing.expectEqual(@as(?usize, 0), level(nodeAt(&fixture, 1)));
    try testing.expectEqual(@as(?usize, null), level(nodeAt(&fixture, 2)));
}

test "each scroll and number read returns the value stored under its own name" {
    // A read that named the wrong property would answer a neighbour's value, and
    // eleven distinct values is what makes the swap visible.
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var source = Node.init(gpa, .scroll_view);
    defer source.deinit();
    const store = &source.properties;
    try numbers.setScrollX(store, 1);
    try numbers.setScrollXMin(store, 2);
    try numbers.setScrollXMax(store, 3);
    try numbers.setScrollY(store, 4);
    try numbers.setScrollYMin(store, 5);
    try numbers.setScrollYMax(store, 6);
    try numbers.setNumericValue(store, 7);
    try numbers.setMinNumericValue(store, 8);
    try numbers.setMaxNumericValue(store, 9);
    try numbers.setNumericValueStep(store, 10);
    try numbers.setNumericValueJump(store, 11);

    try fixture.add(1, null, &source);
    const node = nodeAt(&fixture, 1);

    try testing.expectEqual(@as(?f64, 1), scrollX(node));
    try testing.expectEqual(@as(?f64, 2), scrollXMin(node));
    try testing.expectEqual(@as(?f64, 3), scrollXMax(node));
    try testing.expectEqual(@as(?f64, 4), scrollY(node));
    try testing.expectEqual(@as(?f64, 5), scrollYMin(node));
    try testing.expectEqual(@as(?f64, 6), scrollYMax(node));
    try testing.expectEqual(@as(?f64, 7), numericValue(node));
    try testing.expectEqual(@as(?f64, 8), minNumericValue(node));
    try testing.expectEqual(@as(?f64, 9), maxNumericValue(node));
    try testing.expectEqual(@as(?f64, 10), numericValueStep(node));
    try testing.expectEqual(@as(?f64, 11), numericValueJump(node));
}

test "each flag read answers the bit it names and not a neighbour's" {
    // A flag has no unset value, so `false` covers both "never carried the bit"
    // and "the bit was cleared". One node per bit is what makes a read that
    // answered a neighbour's bit fail instead of pass.
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var bare = Node.init(gpa, .button);
    defer bare.deinit();
    try fixture.add(0, null, &bare);

    // `flag_cases` is a comptime array, so this sweep is bounded by its length.
    inline for (flag_cases) |entry| {
        try testing.expect(!entry.read(nodeAt(&fixture, 0)));
    }
    inline for (flag_cases, 0..) |entry, index| {
        var source = Node.init(gpa, .button);
        defer source.deinit();
        entry.store(&source.flags, true);
        try fixture.add(index + 1, null, &source);
    }
    inline for (flag_cases, 0..) |entry, index| {
        const node = nodeAt(&fixture, index + 1);
        inline for (flag_cases) |other| {
            try testing.expectEqual(other.read == entry.read, other.read(node));
        }
    }
}

test "the string and enum reads answer the stored value and null when unset" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var bare = Node.init(gpa, .button);
    defer bare.deinit();
    try fixture.add(1, null, &bare);

    const without_values = nodeAt(&fixture, 1);
    try testing.expect(!hasRoleDescription(without_values));
    try testing.expect(!hasBrailleLabel(without_values));
    try testing.expect(!hasBrailleRoleDescription(without_values));
    try testing.expectEqual(@as(?[]const u8, null), rowIndexText(without_values));
    try testing.expectEqual(@as(?[]const u8, null), columnIndexText(without_values));
    try testing.expectEqual(@as(?schema.AriaCurrent, null), ariaCurrent(without_values));
    try testing.expectEqual(@as(?schema.HasPopup, null), hasPopup(without_values));
    try testing.expectEqual(@as(?schema.Toggled, null), toggled(without_values));
    try testing.expectEqual(@as(?bool, null), isSelected(without_values));

    var source = Node.init(gpa, .button);
    defer source.deinit();
    const store = &source.properties;
    try strings.setRoleDescription(store, "push button");
    try strings.setBrailleLabel(store, "push");
    try strings.setBrailleRoleDescription(store, "button");
    try strings.setRowIndexText(store, "row two");
    try strings.setColumnIndexText(store, "column one");
    try enums.setAriaCurrent(store, .page);
    try enums.setHasPopup(store, .listbox);
    try enums.setToggled(store, .mixed);
    try enums.setSelected(store, false);
    try fixture.add(2, null, &source);

    const with_values = nodeAt(&fixture, 2);
    try testing.expect(hasRoleDescription(with_values));
    try testing.expect(hasBrailleLabel(with_values));
    try testing.expect(hasBrailleRoleDescription(with_values));
    try testing.expectEqualStrings("push button", roleDescription(with_values).?);
    try testing.expectEqualStrings("push", brailleLabel(with_values).?);
    try testing.expectEqualStrings("button", brailleRoleDescription(with_values).?);
    try testing.expectEqualStrings("row two", rowIndexText(with_values).?);
    try testing.expectEqualStrings("column one", columnIndexText(with_values).?);
    try testing.expectEqual(@as(?schema.AriaCurrent, .page), ariaCurrent(with_values));
    try testing.expectEqual(@as(?schema.HasPopup, .listbox), hasPopup(with_values));
    try testing.expectEqual(@as(?schema.Toggled, .mixed), toggled(with_values));
    // A stored `false` is a stored value and not an absent property.
    try testing.expectEqual(@as(?bool, false), isSelected(with_values));
}

test "isGraft answers true only for a node carrying a tree id" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var plain = Node.init(gpa, .button);
    defer plain.deinit();
    var graft = Node.init(gpa, .button);
    defer graft.deinit();
    try option.setTreeId(&graft.properties, schema.tree_id_root);

    try fixture.add(1, null, &plain);
    try fixture.add(2, null, &graft);

    try testing.expect(!isGraft(nodeAt(&fixture, 1)));
    try testing.expect(isGraft(nodeAt(&fixture, 2)));
}

test "locate reports the local id and the tree id behind the handle" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var source = Node.init(gpa, .button);
    defer source.deinit();
    try fixture.add(7, null, &source);

    // Upstream unwraps at `node.rs:402`. With no tree index recorded the unwrap
    // would fire, so this is the case that became a value.
    try testing.expect(locate(nodeAt(&fixture, 7)) == null);

    try fixture.state.tree_index_map.index_to_id.put(gpa, .init(0), schema.tree_id_root);
    const found = locate(nodeAt(&fixture, 7)).?;
    try testing.expect(found.local_id.eql(schema.nodeIdFromContent(7)));
    try testing.expect(found.tree_id.eql(schema.tree_id_root));
}

test "the value walk finds a level only the grandparent states" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var grandparent = Node.init(gpa, .list_item);
    defer grandparent.deinit();
    try numbers.setLevel(&grandparent.properties, 3);
    var plain = Node.init(gpa, .list_item);
    defer plain.deinit();

    try fixture.add(1, null, &grandparent);
    try fixture.add(2, 1, &plain);
    try fixture.add(3, 2, &plain);

    // A raw read asks one node, so it does not see the grandparent.
    try testing.expectEqual(@as(?usize, null), level(nodeAt(&fixture, 2)));
    try testing.expectEqual(@as(?usize, null), level(nodeAt(&fixture, 3)));
    try testing.expectEqual(@as(?usize, 3), try inheritedLevel(&fixture, 3));
}

test "the value walk answers null when no node on the chain states the property" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var plain = Node.init(gpa, .list_item);
    defer plain.deinit();

    try fixture.add(1, null, &plain);
    try fixture.add(2, 1, &plain);
    try fixture.add(3, 2, &plain);

    try testing.expectEqual(@as(?usize, null), try inheritedLevel(&fixture, 3));
    try testing.expectEqual(@as(?usize, null), try inheritedLevel(&fixture, 2));
}

test "the flag walk finds the grandparent's hidden bit" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var hidden = Node.init(gpa, .list_item);
    defer hidden.deinit();
    flags.setHidden(&hidden.flags, true);
    var plain = Node.init(gpa, .list_item);
    defer plain.deinit();

    try fixture.add(1, null, &hidden);
    try fixture.add(2, 1, &plain);
    try fixture.add(3, 2, &plain);

    // The raw bits on the child and the parent are still clear, so the walk and
    // the bit read cannot be the same call.
    try testing.expect(!rawIsHidden(nodeAt(&fixture, 3)));
    try testing.expect(!rawIsHidden(nodeAt(&fixture, 2)));
    try testing.expect(try isHidden(nodeAt(&fixture, 3)));
}

test "the flag walk answers false when no ancestor sets the bit" {
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var plain = Node.init(gpa, .list_item);
    defer plain.deinit();

    try fixture.add(1, null, &plain);
    try fixture.add(2, 1, &plain);
    try fixture.add(3, 2, &plain);

    try testing.expect(!try isHidden(nodeAt(&fixture, 3)));
    try testing.expect(!try fetchInheritedFlag(nodeAt(&fixture, 3), neverSet));
}

test "the walk stops before the bound on an acyclic chain" {
    // Three nodes and a bound of three. The value sits on the middle node, so a
    // walk from the leaf takes two of the three steps and never reaches the
    // third. This is the positive half of the cycle test below.
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var stated = Node.init(gpa, .list_item);
    defer stated.deinit();
    try numbers.setLevel(&stated.properties, 4);
    var plain = Node.init(gpa, .list_item);
    defer plain.deinit();

    try fixture.add(1, null, &plain);
    try fixture.add(2, 1, &stated);
    try fixture.add(3, 2, &plain);

    try testing.expectEqual(@as(usize, 3), treeWalkStepBound(fixture.state.nodes.count()));
    try testing.expectEqual(@as(?usize, 4), try inheritedLevel(&fixture, 3));
    try testing.expectEqual(@as(?usize, 4), try inheritedLevel(&fixture, 2));
}

test "the walk reports error.TreeCycle when the parent chain repeats a node" {
    // Three nodes and a bound of three: the walk examines all three and still
    // wants a fourth, so the bound catches the repeat. Without the bound this is
    // upstream's `loop` at `node.rs:539` and it does not return.
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var plain = Node.init(gpa, .list_item);
    defer plain.deinit();

    try fixture.add(1, 3, &plain);
    try fixture.add(2, 1, &plain);
    try fixture.add(3, 2, &plain);

    try testing.expectEqual(@as(usize, 3), treeWalkStepBound(fixture.state.nodes.count()));
    try testing.expectError(error.TreeCycle, inheritedLevel(&fixture, 1));
    try testing.expectError(error.TreeCycle, fetchInheritedFlag(nodeAt(&fixture, 1), neverSet));
    try testing.expectError(error.TreeCycle, isHidden(nodeAt(&fixture, 1)));
}

test "the walk reports error.NoSuchNode when a parent id names no node" {
    // Upstream unwraps at `node.rs:135` and aborts. A broken tree is a value the
    // caller handles, so the unwrap became this tag.
    const gpa = testing.allocator;
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();

    var plain = Node.init(gpa, .list_item);
    defer plain.deinit();

    try fixture.add(1, 99, &plain);

    try testing.expectError(error.NoSuchNode, inheritedLevel(&fixture, 1));
    try testing.expectError(error.NoSuchNode, fetchInheritedFlag(nodeAt(&fixture, 1), neverSet));
    try testing.expectError(error.NoSuchNode, isHidden(nodeAt(&fixture, 1)));
}

// -- The range, and the four moves --

// Every item in `node.rs:397-560` has a counterpart here, and the table lives in
// `docs/30-port-design.md`. Four of them are not in that range:
//
// - `isGraft` at `node.rs:122`. `docs/33` section 8 names this file as its owner
//   and names `node_ref/hierarchy.zig` as the caller, because upstream
//   `child_ids` at `node.rs:171` calls it. The line falls inside the
//   `hierarchy.zig` range, and a function lives with the operation it calls.
// - `isSelected` at `node.rs:912`. Its only callers are `node.rs:622` and
//   `node.rs:684`, both in `predicates.zig`, and `docs/33` section 3 forbids
//   `predicates.zig` importing `set_state.zig`. It is a one-line property
//   forward, so it belongs here.
// - `locate` at `node.rs:401` is in the range and is the one item in it that
//   reads no property. It is here because the range is. Its result type
//   `LocateResult` is this module's, because `TreeState.locateNode` writes an
//   anonymous struct and Zig will not let one struct type stand in for another.
// - `NodeRef::id` at `node.rs:397` is a method, and `node_id.zig` owns the
//   `NodeRef` body, so this file declares no `NodeRef` method at all.
//
// Nothing upstream is deleted. Two signatures change and both are recorded
// above: `locate` drops an `unwrap()` for the optional `TreeState.locateNode`
// already returned, and the two walks return `QueryError` where upstream
// returned a bare `Option` and a bare `bool`. `docs/33` section 7 requires the
// second change, because rule C8 bans the abort that would replace the
// error.
