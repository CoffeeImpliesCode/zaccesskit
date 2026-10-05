//! The number this process gave one tree, and the two directions of that
//! assignment.
//!
//! A platform tags every `TreeUpdate` with a `TreeId`, and a platform that
//! grafts trees together sends updates for several trees at once. The consumer
//! therefore gives each `TreeId` a small number of its own and keys its nodes
//! on the pair of a `NodeId` and that number. Upstream
//! `accesskit_consumer/src/tree.rs:13-57`, and `node.rs:29-55` for the id the
//! number is paired with.
//!
//! **Why `TreeIndex` is a type and not a `u32`.** Upstream wraps the number in
//! a `u32` newtype and then never uses the wrapper for anything, so a child
//! index from a `children` list reaches a tree index without a compile error.
//! Three numbers live in this layer and no two of them mean the same thing:
//! `TreeIndex`, `ParentAndIndex.index`, and the `usize` a walk counts with.
//! Keeping the type leaves two operations, `TreeIndex.init` and
//! `TreeIndex.value`, so a caller has to say which number it means.
//!
//! **Why the two maps are `std.array_hash_map.Auto`.** `Auto` preserves
//! insertion order and upstream's `hashbrown::HashMap` does not. `hashbrown`
//! reseeds per process, so upstream reaches a change handler in a different
//! order on every run for the same update. The port makes the order a function
//! of the update instead, and a caller that compares two runs sees a difference
//! that no data caused. `docs/10-accesskit-core.md` rule L7 records the same
//! reason for `NodeMap`, and the `NodeId.hash` doc comment in
//! `src/schema/ids.zig` records it again at the key.
//!
//! **What this module does not do.** It holds no `Node`, no `TreeState` and no
//! `NodeRef`, and it walks nothing. `tree_state.zig` owns the state that holds
//! the maps, `node_id.zig` owns the borrowed node view, and
//! `node_ref/hierarchy.zig` owns the walks over them. This file is the bottom
//! of the consumer layer, so it imports `../schema/` and no consumer module.
//!
//! **Ownership.** A `TreeIndexMap` owns its two maps and their backing arrays.
//! One `deinit` releases both, and the allocator it takes must be the one that
//! grew them. `cloneInto` builds both copies in scratch and swaps on success,
//! so a failed copy leaves the destination as the caller passed it. There is no
//! copy operation: two owners of one pair of maps release it twice.
//!
//! **Why `TreeIndex.init` takes a `u32` and not a `TreeIndex`-shaped name.**
//! A Zig type may not carry a member and a method of one name, so a
//! `TreeIndex` that exposed a `value` field and a `TreeIndex.value` method
//! would not compile. The method keeps the name, because `docs/33` section 8
//! pins `value` as an operation other modules call, and the constructor's
//! parameter is the side that moves: it reads `number`, not `value`. A module
//! that hits the same collision resolves it the same way, and it does not
//! publish the field.
//!
//! **Why the receiver comes first on every method.** Zig builds method-call
//! syntax only when the first parameter is the receiver, so
//! `map.getOrCreateIndex(gpa, id)` reads as a call on a map and a free
//! function spelling reads as a map-shaped name that says nothing about the
//! value it mutates. The allocator follows the receiver because the receiver
//! is the value the operation works on. `getOrCreateIndex` both mutates the map
//! and may add an entry, and the mutation is the caller-visible consequence,
//! so it is a method and not a constructor that returns a new map. `cloneInto`
//! is a method on its destination, because the destination is the value the
//! operation replaces.
//!
//! **What each test pins.** Two of these tests were wrong once, so the subject
//! is written out here rather than left to the assertion.
//!
//! - `TreeIndex carries every u32 through both conversions`: the newtype keeps
//!   the whole `u32`, so a truncating or sign-extending cast fails.
//! - `each tree gets the next number in call order`: a tree gets the count of
//!   the trees before it, not of the calls before it.
//! - `a repeat registration keeps its index and costs none`: a repeat reads the
//!   map and burns no number, which is what upstream's `or_insert_with` does.
//! - `both directions answer for a registered tree and for nothing else`: the
//!   two maps never disagree, and a number nobody holds answers `null`.
//! - `a probe for an unknown tree registers nothing`: `getIndex` is a read and
//!   not a `getOrCreateIndex` in disguise.
//! - `both maps keep the order the trees arrived in`: insertion order, which is
//!   the whole reason the maps are `Auto` and not `hashbrown`.
//! - `a copy answers as the source did and neither follows the other`: the copy
//!   owns its own maps, so a later registration in the source stays there.
//! - `a copy replaces what the destination held`: a **replace**. The
//!   destination held a number the source never hands out, so the copy drops
//!   it, and it takes `next` from the source rather than keeping its own.
//! - `a failed copy leaves the destination as the caller passed it`: scratch
//!   then swap, so `error.OutOfMemory` costs the caller nothing.
//! - `a failed registration leaves the map as it was`: the key `getOrPut`
//!   wrote before the second map is filled comes back out, and the number the
//!   failed call would have taken is still free.
//! - `withSameTree replaces the local id and keeps the number`: the tree half
//!   survives a local-id swap.
//! - `toComponents returns the local id first`: local id first, which is the
//!   reverse of the field order.
//! - `toU128 puts the local id in the high half`: each half is read back on its
//!   own, so a swapped pair fails while still summing to the same 128 bits.

const std = @import("std");

const schema = @import("../schema/root.zig");

const NodeId = schema.NodeId;
const TreeId = schema.TreeId;
const nodeIdFromContent = schema.nodeIdFromContent;
const treeIdFromBytes = schema.treeIdFromBytes;

const assert = std.debug.assert;
const testing = std.testing;

/// The number this process assigned to one tree.
///
/// Every `u32` is an index, so a `TreeIndex` does not prove that a tree was
/// registered. Ask `TreeIndexMap.getId` for that.
pub const TreeIndex = enum(u32) {
    _,

    /// The index carrying `number`, which no other index carries.
    pub fn init(number: u32) TreeIndex {
        return @enumFromInt(number);
    }

    /// The number `self` carries. It is a position in the sequence of
    /// registrations, not a count of the registered trees.
    pub fn value(self: TreeIndex) u32 {
        return @intFromEnum(self);
    }
};

/// A node id namespaced by its tree. Borrows nothing, so a copy is the same node.
pub const FullNodeId = struct {
    /// The id inside `tree_index`'s tree. Two trees may name the same node.
    local: NodeId,
    /// The number `TreeIndexMap` gave this node's tree.
    tree_index: TreeIndex,

    /// The id `local_id` inside the tree `tree_index`.
    pub fn init(local_id: NodeId, tree_index: TreeIndex) FullNodeId {
        return .{ .local = local_id, .tree_index = tree_index };
    }

    /// The same tree, a different local id.
    pub fn withSameTree(self: FullNodeId, local_id: NodeId) FullNodeId {
        return .{ .local = local_id, .tree_index = self.tree_index };
    }

    /// The two halves, local id first. Upstream's tuple at `node.rs:41-43`
    /// returns `(self.1, self.0)`, which is the reverse of the field order.
    pub fn toComponents(self: FullNodeId) struct { local_id: NodeId, tree_index: TreeIndex } {
        return .{ .local_id = self.local, .tree_index = self.tree_index };
    }

    /// `self` read as one unsigned 128-bit integer, the local id in the high
    /// half and the tree number in the low half. Upstream's
    /// `impl From<FullNodeId> for u128` at `node.rs:46-52`, which an adapter
    /// writes into a platform handle. No module under `src/consumer/` calls
    /// it, so a reader does not take it for dead code: the two Unix and Windows
    /// adapters name it, and the C seam needs a flat integer for an AT-SPI
    /// object id.
    pub fn toU128(self: FullNodeId) u128 {
        return (@as(u128, self.local.value) << 64) | @as(u128, self.tree_index.value());
    }
};

/// The parent and this node's index in the parent's `children` list.
pub const ParentAndIndex = struct {
    /// The node whose `children` list holds this node.
    parent_id: FullNodeId,
    /// The position in that list, counted from zero.
    index: usize,
};

/// What each tree was given. Insertion order is the order the trees were first
/// seen, which is a property of the container and not of the key.
pub const TreeIdIndexMap = std.array_hash_map.Auto(TreeId, TreeIndex);
/// Which tree holds each index, in the order the indices were handed out.
pub const TreeIdByIndexMap = std.array_hash_map.Auto(TreeIndex, TreeId);

/// The two directions of the index assignment. Upstream: tree.rs:17-21.
pub const TreeIndexMap = struct {
    /// What a tree was given, in the order the trees were first seen.
    id_to_index: TreeIdIndexMap = .empty,
    /// Which tree holds an index. Every key here has an entry in
    /// `id_to_index`, and `getIndex` and `getId` never disagree.
    index_to_id: TreeIdByIndexMap = .empty,
    /// The index the next unseen tree receives. It rises by one per
    /// registration and by nothing else.
    next: u32 = 0,

    /// The value of a map with no trees registered, which `.{}` also gives.
    /// `tree_state.zig` starts `TreeState.tree_index_map` from it.
    pub const empty: TreeIndexMap = .{};

    /// The index for `id`, assigning the next one the first time `id` is seen.
    ///
    /// A repeat of a registered id costs no index, so the numbers a caller
    /// receives are the count of the trees it registered and not the count of
    /// the calls it made. `error.OutOfMemory` leaves both maps and `next`
    /// exactly as they were, so the index the call would have taken is still
    /// free and a retry gets it.
    ///
    /// The return type is fixed at the allocator's error set, so an exhausted
    /// index is a boundary assertion rather than a tag. The comment at the
    /// assert gives the bound.
    pub fn getOrCreateIndex(
        self: *TreeIndexMap,
        gpa: std.mem.Allocator,
        id: TreeId,
    ) std.mem.Allocator.Error!TreeIndex {
        const slot = try self.id_to_index.getOrPut(gpa, id);
        if (slot.found_existing) return slot.value_ptr.*;

        const assigned = TreeIndex.init(self.next);
        slot.value_ptr.* = assigned;

        // `getOrPut` stored `id` with an undefined value before this point, so
        // a failure below has to take it back out. Leaving it would let
        // `getIndex` answer with an index `getId` does not know.
        errdefer _ = self.id_to_index.orderedRemove(id);
        try self.index_to_id.put(gpa, assigned, id);

        // Upstream's `self.next += 1` at tree.rs:44 wraps in a release build
        // and aborts in a debug one. Reaching the top of the range takes
        // `maxInt(u32)` distinct trees in one process, and `index_to_id` holds
        // a `TreeIndex` and 16 bytes per entry, so the map alone needs 96 GiB
        // before this fires. The bound is memory, so no caller handles it.
        assert(self.next != std.math.maxInt(u32));
        self.next += 1;
        return assigned;
    }

    /// The index `id` was given, or `null` when the tree is not registered.
    /// Registers nothing, so a probe cannot bring a tree into existence.
    /// Upstream `tree.rs:50-52`.
    pub fn getIndex(self: *const TreeIndexMap, id: TreeId) ?TreeIndex {
        return self.id_to_index.get(id);
    }

    /// The tree that holds `index`, or `null` when no tree holds it. An index
    /// that was never handed out is one of those. Upstream `tree.rs:54-56`.
    pub fn getId(self: *const TreeIndexMap, index: TreeIndex) ?TreeId {
        return self.index_to_id.get(index);
    }

    /// Releases both maps and their backing arrays. The value is unusable
    /// afterwards and a second call is a double free. `gpa` must be the
    /// allocator that grew the maps.
    pub fn deinit(self: *TreeIndexMap, gpa: std.mem.Allocator) void {
        self.id_to_index.deinit(gpa);
        self.index_to_id.deinit(gpa);
        // SAFETY: the two maps above were released, which is everything the
        // value owned, and no statement after them reads `self`.
        self.* = undefined;
    }

    /// Replaces `self` with a copy of `source`, and leaves `source` alone. It
    /// replaces and never merges: a tree `self` held and `source` does not name
    /// is gone when this returns.
    ///
    /// Both copies are built before `self` is touched, so `error.OutOfMemory`
    /// leaves `self` as the caller passed it and the caller may retry. On
    /// success `self` releases its old maps and holds the copies. `gpa` must be
    /// the allocator both maps were built with. This is upstream's `clone` at
    /// `tree.rs:25-31` and its `clone_from` at `tree.rs:33-37`, which the
    /// caller at `tree.rs:705` drives by naming the committed map as `self`.
    pub fn cloneInto(
        self: *TreeIndexMap,
        source: *const TreeIndexMap,
        gpa: std.mem.Allocator,
    ) std.mem.Allocator.Error!void {
        var id_to_index = try source.id_to_index.clone(gpa);
        errdefer id_to_index.deinit(gpa);
        var index_to_id = try source.index_to_id.clone(gpa);
        errdefer index_to_id.deinit(gpa);

        self.id_to_index.deinit(gpa);
        self.index_to_id.deinit(gpa);
        self.id_to_index = id_to_index;
        self.index_to_id = index_to_id;
        self.next = source.next;
    }
};

comptime {
    // `#[repr(transparent)] struct TreeIndex(u32)` at tree.rs:14-15, so the
    // integer enum stays one `u32` wide at that width's alignment.
    assert(@sizeOf(TreeIndex) == 4);
    assert(@alignOf(TreeIndex) == 4);

    // `docs/10-accesskit-core.md:410` asks for the size pin because the four
    // padding bytes after `local` exist only while the field order and the two
    // alignments agree. Swapping the fields also gives 16 bytes, so the
    // offsets are what hold the order `tree_state.zig` reads the fields by.
    assert(@sizeOf(FullNodeId) == 16);
    assert(@alignOf(FullNodeId) == 8);
    assert(@offsetOf(FullNodeId, "local") == 0);
    assert(@offsetOf(FullNodeId, "tree_index") == 8);
}

// --- What upstream declares here and this file does not ------------------------
//
// `tree.rs:13` derives `Clone`, `Copy`, `Debug`, `PartialEq`, `Eq`,
// `PartialOrd`, `Ord` and `Hash` on `TreeIndex`. Zig has no derive: a
// four-byte enum is copied by assignment, `==` and `<` are the enum's own
// operators, and `Auto` digests the key with `Wyhash` on its own. Only `Debug`
// has no counterpart at all, because nothing upstream prints a `TreeIndex`: the
// sites that hold one are `tree.rs:43-45`, `tree.rs:371`, `tree.rs:415` and
// `node.rs:48`, and none of them formats it.
//
// `tree.rs:17` derives `Default` on `TreeIndexMap`. The three fields carry
// `.empty` and `0`, so `.empty` and `.{}` give the same value and the derive
// has nothing left to do.
//
// `tree.rs:33-37` is `clone_from`, the half of `Clone` that reuses a
// destination's memory. `cloneInto` covers it: upstream calls it at
// `tree.rs:705` to move the assignment from the next state into the committed
// one, which is one `cloneInto` naming the committed map as the destination.
//
// `tree.rs:18-21` leaves the three fields private to the module. Rule L13 makes
// a Zig field reachable whatever it is written, so the three field comments
// above are what a caller reads instead.

test "TreeIndex carries every u32 through both conversions" {
    // `#[repr(transparent)] struct TreeIndex(u32)` at tree.rs:14-15. A cast
    // that truncates or sign-extends passes the small values and loses this.
    try testing.expectEqual(@as(u32, 0), TreeIndex.init(0).value());
    try testing.expectEqual(@as(u32, 0x8000_0000), TreeIndex.init(0x8000_0000).value());
    try testing.expectEqual(std.math.maxInt(u32), TreeIndex.init(std.math.maxInt(u32)).value());
}

test "each tree gets the next number in call order" {
    // `TreeIndex(self.next)` then `self.next += 1` at tree.rs:43-44. A port
    // that reads `next` after the increment hands the first tree index 1 and
    // never uses 0.
    const gpa = testing.allocator;
    var map: TreeIndexMap = .empty;
    defer map.deinit(gpa);

    const first = try map.getOrCreateIndex(gpa, treeIdFromBytes(.{1} ** 16));
    const second = try map.getOrCreateIndex(gpa, treeIdFromBytes(.{2} ** 16));
    const third = try map.getOrCreateIndex(gpa, treeIdFromBytes(.{3} ** 16));

    try testing.expectEqual(@as(u32, 0), first.value());
    try testing.expectEqual(@as(u32, 1), second.value());
    try testing.expectEqual(@as(u32, 2), third.value());
}

test "a repeat registration keeps its index and costs none" {
    // `entry(id).or_insert_with(closure)` at tree.rs:42-47 runs the closure only
    // when the key is new. A port that reads `next` before the lookup burns an
    // index on every repeat, so the third tree here gets 3.
    const gpa = testing.allocator;
    const one = treeIdFromBytes(.{1} ** 16);
    var map: TreeIndexMap = .empty;
    defer map.deinit(gpa);

    const first = try map.getOrCreateIndex(gpa, one);
    _ = try map.getOrCreateIndex(gpa, treeIdFromBytes(.{2} ** 16));
    const repeated = try map.getOrCreateIndex(gpa, one);

    try testing.expectEqual(first, repeated);

    const third = try map.getOrCreateIndex(gpa, treeIdFromBytes(.{3} ** 16));
    try testing.expectEqual(@as(u32, 2), third.value());
}

test "both directions answer for a registered tree and for nothing else" {
    const gpa = testing.allocator;
    const id = treeIdFromBytes(.{0xab} ** 16);
    var map: TreeIndexMap = .empty;
    defer map.deinit(gpa);

    const index = try map.getOrCreateIndex(gpa, id);

    try testing.expectEqual(index, map.getIndex(id).?);
    try testing.expectEqual(id, map.getId(index).?);
    try testing.expect(map.getIndex(treeIdFromBytes(.{0xcd} ** 16)) == null);
    try testing.expect(map.getId(TreeIndex.init(999)) == null);
}

test "a probe for an unknown tree registers nothing" {
    // `id_to_index.get(&id).copied()` at tree.rs:51 reads the map. A port that
    // routes the probe through `getOrCreateIndex` hands back index 0 for a tree
    // it never saw, and the next real registration loses its number.
    const gpa = testing.allocator;
    const unknown = treeIdFromBytes(.{7} ** 16);
    var map: TreeIndexMap = .empty;
    defer map.deinit(gpa);

    try testing.expect(map.getIndex(unknown) == null);

    const first = try map.getOrCreateIndex(gpa, schema.tree_id_root);

    try testing.expectEqual(@as(u32, 0), first.value());
    try testing.expect(map.getIndex(unknown) == null);
}

test "both maps keep the order the trees arrived in" {
    // `Auto` preserves insertion order and `hashbrown` does not. This is the
    // assertion that holds the container choice, so it walks the keys in the
    // order three registrations made them.
    const gpa = testing.allocator;
    const ids = [_]TreeId{
        treeIdFromBytes(.{3} ** 16),
        treeIdFromBytes(.{1} ** 16),
        treeIdFromBytes(.{2} ** 16),
    };
    var map: TreeIndexMap = .empty;
    defer map.deinit(gpa);

    for (ids) |id| _ = try map.getOrCreateIndex(gpa, id);

    const by_number = [_]TreeIndex{ TreeIndex.init(0), TreeIndex.init(1), TreeIndex.init(2) };

    try testing.expectEqualSlices(TreeId, &ids, map.id_to_index.keys());
    try testing.expectEqualSlices(TreeIndex, &by_number, map.index_to_id.keys());
}

test "a copy answers as the source did and neither follows the other" {
    // Upstream's `clone` at tree.rs:25-31 gives the copy its own maps. A port
    // that moved the headers instead would leave the source empty.
    const gpa = testing.allocator;
    const copied_id = treeIdFromBytes(.{1} ** 16);

    var source: TreeIndexMap = .empty;
    defer source.deinit(gpa);
    const copied = try source.getOrCreateIndex(gpa, copied_id);

    var out: TreeIndexMap = .empty;
    defer out.deinit(gpa);
    try out.cloneInto(&source, gpa);

    try testing.expectEqual(copied, out.getIndex(copied_id).?);
    try testing.expectEqual(copied_id, out.getId(copied).?);

    // A registration in the source after the copy must not reach the copy.
    const added = try source.getOrCreateIndex(gpa, treeIdFromBytes(.{2} ** 16));

    try testing.expect(source.getId(added) != null);
    try testing.expect(out.getId(added) == null);
}

test "a copy replaces what the destination held" {
    // `clone_from` at tree.rs:33-37 is the caller at tree.rs:705: the next
    // state moves into the committed state, and the committed entries the next
    // state does not name must be gone.
    const gpa = testing.allocator;
    const stale_id = treeIdFromBytes(.{9} ** 16);

    var source: TreeIndexMap = .empty;
    defer source.deinit(gpa);
    _ = try source.getOrCreateIndex(gpa, treeIdFromBytes(.{1} ** 16));

    var out: TreeIndexMap = .empty;
    defer out.deinit(gpa);
    _ = try out.getOrCreateIndex(gpa, stale_id);
    const stale = try out.getOrCreateIndex(gpa, treeIdFromBytes(.{8} ** 16));

    try out.cloneInto(&source, gpa);

    // The source handed out index 0 alone, so the copy drops index 1 and every
    // entry the destination held. A port that merged instead leaves `.{ 8 }`
    // behind, and a port that copied without copying `next` reuses index 1.
    try testing.expectEqual(@as(u32, 0), out.getIndex(treeIdFromBytes(.{1} ** 16)).?.value());
    try testing.expect(out.getId(stale) == null);
    try testing.expect(out.getIndex(stale_id) == null);
    try testing.expect(out.getIndex(treeIdFromBytes(.{8} ** 16)) == null);
}

test "a failed copy leaves the destination as the caller passed it" {
    // `docs/33-consumer-interface-contract.md` section 4 states this rule for
    // `cloneInto`. A port that deinitialises the destination first loses the
    // entries the caller still holds.
    const gpa = testing.allocator;
    const held_id = treeIdFromBytes(.{9} ** 16);

    var source: TreeIndexMap = .empty;
    defer source.deinit(gpa);
    _ = try source.getOrCreateIndex(gpa, treeIdFromBytes(.{1} ** 16));

    var out: TreeIndexMap = .empty;
    defer out.deinit(gpa);
    const held = try out.getOrCreateIndex(gpa, held_id);

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const failing_gpa = failing.allocator();
    try testing.expectError(error.OutOfMemory, out.cloneInto(&source, failing_gpa));

    try testing.expectEqual(held, out.getIndex(held_id).?);
    try testing.expect(out.getIndex(treeIdFromBytes(.{1} ** 16)) == null);
}

test "a failed registration leaves the map as it was" {
    // `getOrPut` at tree.rs:42 stores the key with an undefined value before
    // the second map is written, so a failure between the two writes has to
    // take that key back out.
    const id = treeIdFromBytes(.{4} ** 16);
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    const gpa = failing.allocator();

    var map: TreeIndexMap = .empty;
    defer map.deinit(gpa);

    try testing.expectError(error.OutOfMemory, map.getOrCreateIndex(gpa, id));

    try testing.expect(map.getIndex(id) == null);
    try testing.expect(map.getId(TreeIndex.init(0)) == null);

    // The failed call left both maps empty, so the retry takes the same two
    // allocations and now the second one succeeds.
    failing.fail_index = std.math.maxInt(usize);

    const index = try map.getOrCreateIndex(gpa, id);
    try testing.expectEqual(@as(u32, 0), index.value());
    try testing.expectEqual(id, map.getId(index).?);
}

test "withSameTree replaces the local id and keeps the number" {
    // `Self(self.0, local_id)` at node.rs:38 keeps field 0. A port that swaps
    // the two returns an id from a tree the node never lived in.
    const id = FullNodeId.init(nodeIdFromContent(7), TreeIndex.init(3));
    const replaced = id.withSameTree(nodeIdFromContent(9));

    try testing.expectEqual(nodeIdFromContent(9), replaced.local);
    try testing.expectEqual(id.tree_index, replaced.tree_index);
}

test "toComponents returns the local id first" {
    // `(self.1, self.0)` at node.rs:42 returns the local id first, which is the
    // reverse of the field order. A port that reads the fields in order hands
    // a tree number back where a `NodeId` belongs.
    const id = FullNodeId.init(nodeIdFromContent(7), TreeIndex.init(3));
    const parts = id.toComponents();

    try testing.expectEqual(nodeIdFromContent(7), parts.local_id);
    try testing.expectEqual(TreeIndex.init(3), parts.tree_index);
}

test "toU128 puts the local id in the high half" {
    // `(local_id << 64) | tree_index` at node.rs:50.
    const local = nodeIdFromContent(0x0123_4567_89ab_cdef);
    const combined = FullNodeId.init(local, TreeIndex.init(0x89ab_cdef)).toU128();

    try testing.expectEqual(@as(u128, 0x0123_4567_89ab_cdef), combined >> 64);
    try testing.expectEqual(@as(u128, 0x89ab_cdef), combined & 0xffff_ffff);
}
