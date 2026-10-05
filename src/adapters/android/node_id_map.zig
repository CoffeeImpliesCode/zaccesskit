//! The two-way map between a virtual view id and a tree node.
//!
//! Upstream is `AK/android/src/util.rs:134-158`, the only id map in the four
//! adapters, and it exists because **Android has no object identity**. Every
//! other platform names a node by a pointer the platform itself holds, and
//! casts it back. Android hands the adapter a `jint`, so the adapter has to
//! mint that number itself and remember what it minted.
//!
//! **The shape.** Two maps and a counter. `by_virtual_id` answers the question
//! the platform asks, "which node is virtual view id `n`", and `by_node_id`
//! answers the question the fill asks, "which id does this node carry". The two
//! always hold the same pairs, and every mutation writes both or neither.
//!
//! **The counter only grows.** An id is never reused, because a platform may
//! still be holding one: Android caches a node info per virtual id for the life
//! of a provider, so a number handed out once and reused later would resolve to
//! a different node. That is why this map has no removal operation at all,
//! which is also what `docs/42` section 4.4 records: Android's `node_removed`
//! drops no per-node state.
//!
//! **`values.HOST_VIEW_ID` is not in either map.** `HOST_VIEW_ID` is `-1` and
//! names the host view itself rather than a node of the tree, so no node ever
//! carries it and the counter starts at `first_virtual_id`, which is above it.
//! The adapter compares against `values.HOST_VIEW_ID` where it means "the host
//! view" and comes here for everything else.
//!
//! **Determinism.** Both maps are `std.array_hash_map.Auto`, so iteration order
//! is insertion order. `docs/42` section 5.3.2 records that upstream chose
//! `BTreeMap` for this reason and that a port keeps it, and nothing here
//! iterates anyway: every lookup is by key.
//!
//! **The counter and its bound.** The largest id this map can mint is
//! `std.math.maxInt(JInt)`, the largest number the `i32` Android stores holds.
//! Handing out that last value is fine; the call after it reports
//! `error.VirtualIdsExhausted` rather than wrapping, because a wrapped id
//! would collide with one already in the map. A tree with `2^31` nodes is not a
//! thing that happens, and the error is still the honest answer rather than a
//! silent wrong mapping.
//!
//! **Why the counter is a count and not a `jint`.** The one value above
//! `largest_virtual_id` is a number the counter must be able to hold, because
//! that is the value that means "exhausted". A `jint` counter would have to
//! wrap there, and a wrapped counter is a negative id the guard would then hand
//! out. So the field is an `i64` count and the id it produces is narrowed only
//! after the guard has accepted it.
//!
//! **The allocation rule.** `init` and `getOrCreateJavaId` grow both maps, so
//! neither takes a separate allocator argument: the one `init` was given is
//! the one every later growth uses, which is what `AGENTS.md` section 3 asks
//! for and what keeps the two directions from being grown through two
//! allocators. `deinit` takes the allocator as a parameter because a releasing
//! call reads more clearly with the allocator beside it, and because `node.zig`
//! calls it that way.
//!
//! **No domain loop.** This file has no walk over `Action`, over a node's
//! children or over a Java type, so there is no loop bound to derive. The walks
//! that do have one live in `node.zig`, where the table at the top of its
//! module doc lists them.

const std = @import("std");

const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const values = @import("values.zig");

const FullNodeId = consumer.tree_index.FullNodeId;
const NodeRef = consumer.node_id.NodeRef;
const TreeState = consumer.tree_state.TreeState;

const Allocator = std.mem.Allocator;
const JInt = values.JInt;
const ParentAndIndex = consumer.tree_index.ParentAndIndex;

const testing = std.testing;

/// Everything `NodeIdMap` can fail with.
///
/// `error.OutOfMemory` comes from `std.mem.Allocator` and reaches this module
/// through the two map inserts. The other tag is this module's own.
pub const Error = std.mem.Allocator.Error || error{
    /// The counter would have to hand out a number above
    /// `std.math.maxInt(JInt)`, so no id is left that fits the `jint` Android
    /// stores. Nothing was written, and the counter is unchanged, so a caller
    /// that releases nodes and retries starts from where it stood.
    VirtualIdsExhausted,
};

/// The virtual id to the node it names.
pub const ByVirtualId = std.array_hash_map.Auto(JInt, FullNodeId);

/// The node to the virtual id it carries.
pub const ByNodeId = std.array_hash_map.Auto(FullNodeId, JInt);

/// The first virtual id this map hands out.
///
/// It is `0`, which is above `values.HOST_VIEW_ID` and so cannot collide with
/// the sentinel that names the host view. Upstream's counter starts here too:
/// `HOST_VIEW_ID` is a named constant at `util.rs:52` and not a value the
/// counter ever reaches.
pub const first_virtual_id: JInt = 0;

/// The largest virtual id this map hands out.
///
/// It is `std.math.maxInt(JInt)`, and `getOrCreateJavaId` reports
/// `error.VirtualIdsExhausted` on the call that would exceed it rather than
/// wrapping into a number the map already holds.
pub const largest_virtual_id: JInt = std.math.maxInt(JInt);

/// The two directions of the virtual id map, plus the counter that mints ids.
///
/// A value owns both maps and grows them through the allocator `init` was
/// given. `deinit` releases both and leaves the value in its empty form, so a
/// second `deinit` releases nothing rather than freeing twice, exactly as
/// `consumer.tree.Tree.deinit` does for its own two states.
///
/// The value owns no node. A `NodeRef` reaches this module only to be reduced
/// to its `FullNodeId`, which is two scalars and stays valid for the life of
/// the map whether or not the node it names still exists.
pub const NodeIdMap = struct {
    /// The allocator that grew both maps and the only one any growth uses.
    gpa: Allocator,

    /// The question the platform asks: virtual view id to node.
    by_virtual_id: ByVirtualId = .empty,

    /// The question the fill asks: node to virtual view id.
    by_node_id: ByNodeId = .empty,

    /// The number the next new node will carry. It is a count rather than a
    /// `JInt` so that the one value past `largest_virtual_id` is a number the
    /// counter can hold rather than an overflow, and it only ever grows.
    next_virtual_id: i64 = first_virtual_id,

    /// An empty map with room for `expected_node_count` pairs.
    ///
    /// Both maps are pre-grown here rather than on first insert, because the
    /// caller knows the node count of the tree it has just applied and the fill
    /// then mints one id per node. Growing up front removes every rehash from
    /// the node-info path, which is the one that runs while a platform call is
    /// on the stack.
    ///
    /// `expected_node_count` is a hint and not a limit: a larger tree still
    /// mints every id it needs, and a count of zero is a legal hint that
    /// allocates nothing beyond what the first insert needs.
    pub fn init(gpa: Allocator, expected_node_count: usize) Allocator.Error!NodeIdMap {
        var map: NodeIdMap = .{ .gpa = gpa };
        // The first grow owns the allocation, so `map` has to be released if
        // the second one fails. `errdefer` here, not `defer`, because only a
        // failure needs the release and `init` hands the value over on success.
        errdefer map.deinit(gpa);
        try map.by_virtual_id.ensureTotalCapacity(gpa, expected_node_count);
        try map.by_node_id.ensureTotalCapacity(gpa, expected_node_count);
        return map;
    }

    /// Releases both maps and leaves the value empty.
    ///
    /// The allocator must be the one `init` was given. After the call a read of
    /// any field answers the empty map rather than an address that no longer
    /// holds one, so a second call is harmless.
    pub fn deinit(self: *NodeIdMap, gpa: Allocator) void {
        self.by_virtual_id.deinit(gpa);
        self.by_node_id.deinit(gpa);
        // SAFETY: the two lines above released every buffer this value owned,
        // which is the whole teardown, and nothing after them reads a released
        // field. The reset is what a stale read sees, and it keeps `gpa`, which
        // owns no memory and so has nothing to invalidate.
        self.* = .{ .gpa = gpa };
    }

    /// The node virtual view id `virtual_id` names, or `null` when the map
    /// holds no node under that id.
    ///
    /// A `null` is an ordinary answer and not a failure: Android hands back an
    /// id for a node the application has since dropped, and the adapter answers
    /// such a request with no node info rather than an error.
    ///
    /// `values.HOST_VIEW_ID` always answers `null`, because the host view is
    /// not a node of the tree and is never filed here.
    pub fn getAccesskitId(self: *const NodeIdMap, virtual_id: JInt) ?FullNodeId {
        return self.by_virtual_id.get(virtual_id);
    }

    /// The virtual view id `id` carries, or `null` when the map has never seen
    /// the node.
    ///
    /// The fill uses this where it must decide whether to mint an id or reuse
    /// one, and the adapter uses it to answer a virtual id the platform sends
    /// back with an event.
    pub fn getJavaId(self: *const NodeIdMap, id: FullNodeId) ?JInt {
        return self.by_node_id.get(id);
    }

    /// The virtual view id for `node`, minting one the first time it is asked.
    ///
    /// This is the only call that grows the map, and it grows both directions
    /// or neither: `error.OutOfMemory` leaves the map exactly as it was, so a
    /// later call for the same node mints the id the failed call would have.
    ///
    /// The id is stable for the life of the map. Two calls for one node answer
    /// the same number, and two different nodes never share one.
    pub fn getOrCreateJavaId(self: *NodeIdMap, node: NodeRef) Error!JInt {
        const id = node.id();
        if (self.by_node_id.get(id)) |existing| return existing;
        return self.createFor(id);
    }

    /// Mints the next id for `id` and files it in both directions.
    ///
    /// Split out of `getOrCreateJavaId` so the insert pair and its rollback sit
    /// on one screen: the only failure between the two inserts is
    /// `error.OutOfMemory`, and the rollback is what keeps the two directions
    /// from disagreeing.
    fn createFor(self: *NodeIdMap, id: FullNodeId) Error!JInt {
        // The guard is one past the top rather than equal to it, because
        // `largest_virtual_id` itself is a legal id to mint. Reaching here
        // means every number from `first_virtual_id` up has been taken.
        if (self.next_virtual_id > largest_virtual_id) return error.VirtualIdsExhausted;
        const minted: JInt = @intCast(self.next_virtual_id);
        self.next_virtual_id += 1;

        try self.by_virtual_id.put(self.gpa, minted, id);
        self.by_node_id.put(self.gpa, id, minted) catch |err| {
            // The second insert is the only fallible step after the first one
            // succeeded, so undoing the first here is the whole rollback.
            _ = self.by_virtual_id.swapRemove(minted);
            return err;
        };
        return minted;
    }

    /// How many pairs the map holds, which is also how many nodes it has named.
    ///
    /// The two directions cannot disagree, so this answers both questions with
    /// one number.
    pub fn count(self: *const NodeIdMap) usize {
        return self.by_virtual_id.count();
    }

    /// The id the next new node will carry, without minting it, or `null` once
    /// the counter is past `largest_virtual_id`.
    ///
    /// A test uses this to read the counter without moving it, which is the
    /// only way to see the value that means "exhausted".
    pub fn peekNextVirtualId(self: *const NodeIdMap) ?JInt {
        if (self.next_virtual_id > largest_virtual_id) return null;
        return @intCast(self.next_virtual_id);
    }
};

comptime {
    // The sentinel names the host view, so no node may be filed under it and the
    // counter has to start above it. If `HOST_VIEW_ID` ever moved to a positive
    // value this is the assertion that says the counter no longer clears it.
    if (first_virtual_id <= values.HOST_VIEW_ID) {
        @compileError("the first virtual id must clear the host view sentinel");
    }
    if (largest_virtual_id < first_virtual_id) {
        @compileError("the largest virtual id must not be below the first");
    }
    // `values.HOST_VIEW_ID` is the one number this map refuses to mint, so a
    // test asserts it is out of reach rather than trusting the check above.
    if (@as(JInt, values.HOST_VIEW_ID) == first_virtual_id) {
        @compileError("the host sentinel is mintable");
    }
}

// --- Tests --------------------------------------------------------------------

/// The local id of node `number` in tree 0, which every fixture below uses.
fn fixtureId(number: u64) FullNodeId {
    return FullNodeId.init(.{ .value = number }, .init(0));
}

/// Stores one node under `id`, with `parent` as its parent or with no parent.
fn putNode(
    gpa: Allocator,
    state: *TreeState,
    id: FullNodeId,
    parent: ?FullNodeId,
) std.mem.Allocator.Error!void {
    try state.nodes.put(gpa, id, .{
        .parent_and_index = if (parent) |parent_id|
            ParentAndIndex{ .parent_id = parent_id, .index = 0 }
        else
            null,
        .data = schema.Node.init(gpa, .group),
    });
}

/// A state holding three nodes: a root, its child and an unrelated node.
///
/// Three rather than one because the map must tell two different nodes apart,
/// and a root with a child because the fill mints ids for parents and children
/// alike.
fn stateWithThreeNodes(gpa: Allocator, state: *TreeState) std.mem.Allocator.Error!void {
    const root = fixtureId(1);
    const child = fixtureId(2);
    const other = fixtureId(3);
    try putNode(gpa, state, root, null);
    try putNode(gpa, state, child, root);
    try putNode(gpa, state, other, null);
}

/// The handle to the node `id`, which the fixture has already stored.
fn handleOf(state: *TreeState, id: FullNodeId) error{NodeMissingFromState}!NodeRef {
    return NodeRef.init(state, id) orelse error.NodeMissingFromState;
}

test "an empty map hands out the first id and files it in both directions" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try stateWithThreeNodes(gpa, &state);

    var map = try NodeIdMap.init(gpa, state.nodes.count());
    defer map.deinit(gpa);

    const node = try handleOf(&state, fixtureId(2));
    const minted = try map.getOrCreateJavaId(node);

    try testing.expectEqual(first_virtual_id, minted);
    try testing.expectEqual(@as(usize, 1), map.count());
    try testing.expect(std.meta.eql(fixtureId(2), map.getAccesskitId(minted).?));
    try testing.expectEqual(minted, map.getJavaId(fixtureId(2)).?);
}

test "asking twice for one node answers the same id and grows nothing" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try stateWithThreeNodes(gpa, &state);

    var map = try NodeIdMap.init(gpa, state.nodes.count());
    defer map.deinit(gpa);

    const node = try handleOf(&state, fixtureId(2));
    const first = try map.getOrCreateJavaId(node);
    const second = try map.getOrCreateJavaId(node);

    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(usize, 1), map.count());
}

test "two nodes never share an id and the counter walks upward" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try stateWithThreeNodes(gpa, &state);

    var map = try NodeIdMap.init(gpa, state.nodes.count());
    defer map.deinit(gpa);

    const root = try map.getOrCreateJavaId(try handleOf(&state, fixtureId(1)));
    const child = try map.getOrCreateJavaId(try handleOf(&state, fixtureId(2)));
    const other = try map.getOrCreateJavaId(try handleOf(&state, fixtureId(3)));

    try testing.expect(root < child);
    try testing.expect(child < other);
    try testing.expectEqual(@as(usize, 3), map.count());

    // Each direction resolves the other one's key, which is the invariant the
    // rollback exists to keep.
    try testing.expect(std.meta.eql(fixtureId(1), map.getAccesskitId(root).?));
    try testing.expect(std.meta.eql(fixtureId(2), map.getAccesskitId(child).?));
    try testing.expect(std.meta.eql(fixtureId(3), map.getAccesskitId(other).?));
    try testing.expectEqual(root, map.getJavaId(fixtureId(1)).?);
    try testing.expectEqual(child, map.getJavaId(fixtureId(2)).?);
    try testing.expectEqual(other, map.getJavaId(fixtureId(3)).?);
}

test "an id the map never minted answers null in both directions" {
    const gpa = testing.allocator;
    var map = try NodeIdMap.init(gpa, 0);
    defer map.deinit(gpa);

    try testing.expect(map.getAccesskitId(0) == null);
    try testing.expect(map.getJavaId(fixtureId(9)) == null);
    try testing.expectEqual(@as(usize, 0), map.count());
}

test "the host view sentinel is never minted and never resolves" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try stateWithThreeNodes(gpa, &state);

    var map = try NodeIdMap.init(gpa, state.nodes.count());
    defer map.deinit(gpa);

    const node = try handleOf(&state, fixtureId(2));
    const minted = try map.getOrCreateJavaId(node);

    try testing.expect(minted != values.HOST_VIEW_ID);
    try testing.expect(map.getAccesskitId(values.HOST_VIEW_ID) == null);
    try testing.expectEqual(@as(usize, 1), map.count());
}

test "the same local id in two trees names two nodes and takes two ids" {
    // `FullNodeId` is a local id beside a tree index, so a lookup that ignored
    // the index would file both of these under one id and the platform would
    // see one node where the tree holds two.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    const in_root = fixtureId(7);
    const in_graft = FullNodeId.init(.{ .value = 7 }, .init(1));
    try putNode(gpa, &state, in_root, null);
    try putNode(gpa, &state, in_graft, null);

    var map = try NodeIdMap.init(gpa, state.nodes.count());
    defer map.deinit(gpa);

    const root_id = try map.getOrCreateJavaId(try handleOf(&state, in_root));
    const graft_id = try map.getOrCreateJavaId(try handleOf(&state, in_graft));

    try testing.expect(root_id != graft_id);
    try testing.expect(std.meta.eql(in_root, map.getAccesskitId(root_id).?));
    try testing.expect(std.meta.eql(in_graft, map.getAccesskitId(graft_id).?));
    try testing.expectEqual(@as(usize, 2), map.count());
}

test "peek reports the next id without minting it, and answers null when spent" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try stateWithThreeNodes(gpa, &state);

    var map = try NodeIdMap.init(gpa, state.nodes.count());
    defer map.deinit(gpa);

    try testing.expectEqual(@as(?JInt, first_virtual_id), map.peekNextVirtualId());
    _ = try map.getOrCreateJavaId(try handleOf(&state, fixtureId(1)));
    try testing.expectEqual(@as(?JInt, first_virtual_id + 1), map.peekNextVirtualId());
    try testing.expectEqual(@as(usize, 1), map.count());

    // `null` is the only honest reading of "the counter has walked past the top",
    // and it is the state a caller has to be able to see.
    map.next_virtual_id = @as(i64, largest_virtual_id) + 1;
    try testing.expect(map.peekNextVirtualId() == null);
}

test "the counter reaching its last value reports exhaustion and mints nothing" {
    // The whole failure here is arithmetic, so it is driven by parking the
    // counter on the top id, letting one call take it, and asking for one more.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try stateWithThreeNodes(gpa, &state);

    var map = try NodeIdMap.init(gpa, state.nodes.count());
    defer map.deinit(gpa);

    map.next_virtual_id = largest_virtual_id;
    const node = try handleOf(&state, fixtureId(2));
    try testing.expectEqual(largest_virtual_id, try map.getOrCreateJavaId(node));
    try testing.expectEqual(@as(usize, 1), map.count());

    const other = try handleOf(&state, fixtureId(3));
    try testing.expectError(
        error.VirtualIdsExhausted,
        map.getOrCreateJavaId(other),
    );
    // Nothing was written on the failing call, so the map still answers the one
    // pair it held and neither direction names the node that was refused.
    try testing.expectEqual(@as(usize, 1), map.count());
    try testing.expect(map.getJavaId(fixtureId(3)) == null);
    try testing.expect(map.peekNextVirtualId() == null);
}

test "deinit twice releases nothing the second time" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try stateWithThreeNodes(gpa, &state);

    var map = try NodeIdMap.init(gpa, state.nodes.count());
    _ = try map.getOrCreateJavaId(try handleOf(&state, fixtureId(2)));

    map.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), map.count());
    map.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), map.count());
}

test "every allocation failure in a mint leaves the two directions in step" {
    // `AGENTS.md` section 3 asks for fail-N. The two inserts are the only
    // fallible steps, and the rollback is the only thing standing between a
    // half-written pair and a map that hands the platform one node's info for
    // another node's id.
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try stateWithThreeNodes(gpa, &state);

    try testing.checkAllAllocationFailures(
        gpa,
        mintUnderAnyAllocator,
        .{ &state, fixtureId(2) },
    );
}

/// One mint of one id, under whatever allocator the sweep hands in.
///
/// The sweep passes a `std.testing.FailingAllocator` that fails one allocation,
/// so `error.OutOfMemory` has to leave this function rather than be caught:
/// `checkAllAllocationFailures` reports a swallowed one as a failure.
fn mintUnderAnyAllocator(gpa: Allocator, state: *TreeState, id: FullNodeId) !void {
    var map = try NodeIdMap.init(gpa, 1);
    defer map.deinit(gpa);

    const minted = try map.getOrCreateJavaId(try handleOf(state, id));
    // Reaching this line means every allocation succeeded, so both directions
    // must name the pair the counter just made.
    try testing.expectEqual(minted, map.getJavaId(id).?);
    try testing.expect(std.meta.eql(id, map.getAccesskitId(minted).?));
    try testing.expectEqual(map.by_virtual_id.count(), map.by_node_id.count());
    try testing.expectEqual(@as(usize, 1), map.count());
}
